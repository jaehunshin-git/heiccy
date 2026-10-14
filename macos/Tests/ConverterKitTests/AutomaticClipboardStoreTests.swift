import AppKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ConverterKit

final class AutomaticClipboardStoreTests: XCTestCase {
    private struct Representation: Equatable {
        let type: String
        let data: Data
    }
    private final class MissingData: NSObject, NSPasteboardItemDataProvider {
        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                        provideDataForType type: NSPasteboard.PasteboardType) {}
    }
    private final class CountingData: NSObject, NSPasteboardItemDataProvider {
        let values: [NSPasteboard.PasteboardType: Data]
        var requests: [NSPasteboard.PasteboardType] = []
        init(_ values: [NSPasteboard.PasteboardType: Data]) { self.values = values }
        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                        provideDataForType type: NSPasteboard.PasteboardType) {
            requests.append(type)
            if let data = values[type] { item.setData(data, forType: type) }
        }
    }

    @MainActor private final class Fixture {
        let board = NSPasteboard(name: .init("AutomaticClipboardStoreTests-\(UUID().uuidString)"))
        let files = FileManager()
        let sandbox: URL
        let root: URL
        let store: AutomaticClipboardStore
        init(writer: ((NSPasteboard, [NSPasteboardItem]) -> Bool)? = nil,
             cleanupItemsReader: @escaping (NSPasteboard) -> [NSPasteboardItem]? = { $0.pasteboardItems },
             metadataReader: @escaping (URL) -> stat? = { AutomaticClipboardStoreTests.metadata($0) }) throws {
            sandbox = URL(fileURLWithPath: InputValidator.canonicalPath(FileManager.default.temporaryDirectory), isDirectory: true)
                .appendingPathComponent("AutomaticClipboardStoreTests-\(UUID().uuidString)", isDirectory: true)
            root = sandbox.appendingPathComponent("관리", isDirectory: true)
            try files.createDirectory(at: sandbox, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            store = AutomaticClipboardStore(pasteboard: board, root: root, fileManager: files,
                writer: writer ?? { $0.writeObjects($1) }, cleanupItemsReader: cleanupItemsReader,
                metadataReader: metadataReader)
        }
        func close() {
            try? store.shutdown()
            board.releaseGlobally()
            try? files.removeItem(at: sandbox)
        }
        func source(_ name: String = "원본.heic") throws -> URL {
            let url = sandbox.appendingPathComponent(name)
            try AutomaticClipboardStoreTests.image(.heic).write(to: url)
            return url
        }
        func put(_ items: [NSPasteboardItem]) {
            board.clearContents()
            XCTAssertTrue(board.writeObjects(items))
        }
        func putText(_ text: String = "새 내용") {
            put([AutomaticClipboardStoreTests.item([(.string, Data(text.utf8))])])
        }
        func ready(_ source: URL) throws -> (ClipboardSnapshot, String, [URL], URL) {
            put([AutomaticClipboardStoreTests.item([(.fileURL, Data(source.absoluteString.utf8))])])
            let snapshot = try store.capture()
            let id = UUID().uuidString
            let prepared = try store.prepare(snapshot: snapshot, jobID: id)
            return (snapshot, id, prepared.inputs, prepared.outputDirectory)
        }
        func output(_ directory: URL, _ name: String = "결과.png", type: UTType = .png) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try AutomaticClipboardStoreTests.image(type).write(to: url)
            return url
        }
    }

    private static func metadata(_ url: URL) -> stat? {
        var value = stat()
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path, Darwin.lstat(path, &value) == 0 else { return nil }
            return value
        }
    }

    private static func photosItem(source: URL, raw: Data? = nil,
                                   urlTypes: [NSPasteboard.PasteboardType] = [.fileURL, .URL],
                                   mediaType: Int = 1) throws -> NSPasteboardItem {
        let asset = try PropertyListSerialization.data(fromPropertyList: ["mediaType": mediaType, "mediaSubtypes": 0],
                                                       format: .binary, options: 0)
        var values = urlTypes.map { ($0, Data(source.absoluteString.utf8)) }
        if let raw { values.append((.init(UTType.heic.identifier), raw)) }
        values.append((.init("com.apple.photos.object-reference.asset"), asset))
        return item(values)
    }

    private static func image(_ type: UTType, red: CGFloat = 0.2) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 12, bitsPerComponent: 8,
            bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: red, green: 0.7, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 12))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        guard CGImageDestinationFinalize(destination) else { throw AutomaticClipboardError.invalidImage }
        return data as Data
    }

    private static func item(_ values: [(NSPasteboard.PasteboardType, Data)]) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        for (type, data) in values { XCTAssertTrue(item.setData(data, forType: type)) }
        return item
    }

    @MainActor private func contents(_ board: NSPasteboard) throws -> [[Representation]] {
        try (board.pasteboardItems ?? []).map { item in
            try item.types.map { Representation(type: $0.rawValue, data: try XCTUnwrap(item.data(forType: $0))) }
        }
    }

    // Photos만 소유 입력 URL로 정규화한다. 나머지 항목·표현의 순서와 바이트는 정확히 비교한다.
    private func normalizedPhotosRestore(_ original: [[Representation]], index: Int, input: URL, raw: Data,
                                         privateTypes: [NSPasteboard.PasteboardType] = []) -> [[Representation]] {
        var expected = original
        let removed = ["com.apple.photos.object-reference.asset"] + privateTypes.map(\.rawValue)
        expected[index] = original[index].filter { !removed.contains($0.type) }.map { value in
            if value.type == NSPasteboard.PasteboardType.fileURL.rawValue || value.type == NSPasteboard.PasteboardType.URL.rawValue {
                return Representation(type: value.type, data: Data(input.absoluteString.utf8))
            }
            return value
        }
        if !expected[index].contains(where: { $0.type == UTType.heic.identifier }) {
            expected[index].append(Representation(type: UTType.heic.identifier, data: raw))
        }
        return expected
    }

    @MainActor
    func testMixedItemsDuplicateSourcesLongNameAndExactRestoration() throws {
        let f = try Fixture(); defer { f.close() }
        // 255바이트 원본은 표시·복구용으로 유지하고 내부 이름은 worker 저장 예산에 맞춘다.
        let source = try f.source(String(repeating: "a", count: 250) + ".heic")
        let png = f.sandbox.appendingPathComponent("보존.png")
        try Self.image(.png).write(to: png)
        let document = f.sandbox.appendingPathComponent("문서.txt")
        try Data("문서".utf8).write(to: document)
        let custom = NSPasteboard.PasteboardType("test.heic.caption")
        let oldTIFF = try XCTUnwrap(NSImage(data: Self.image(.png))?.tiffRepresentation)
        f.put([
            Self.item([(.fileURL, Data(source.absoluteString.utf8)), (.URL, Data(source.absoluteString.utf8)),
                       (.tiff, oldTIFF), (.string, Data("설명".utf8)), (custom, Data([0, 1, 255]))]),
            Self.item([(.string, Data("중간 텍스트".utf8))]),
            Self.item([(.fileURL, Data(png.absoluteString.utf8))]),
            Self.item([(.fileURL, Data(document.absoluteString.utf8))]),
            Self.item([(.fileURL, Data(source.absoluteString.utf8))])
        ])
        let original = try contents(f.board)
        let generation = f.board.changeCount
        let snapshot = try f.store.capture()
        XCTAssertEqual(snapshot.changeCount, generation)
        XCTAssertEqual(snapshot.files.map(\.isHEIC), [true, false, false, true])
        XCTAssertEqual(snapshot.targets.map(\.source), [source, source])
        let id = UUID().uuidString
        let prepared = try f.store.prepare(snapshot: snapshot, jobID: id)
        XCTAssertEqual(Set(prepared.inputs).count, 2)
        XCTAssertEqual(snapshot.files.filter(\.isHEIC).map(\.name), [source.lastPathComponent, source.lastPathComponent])
        XCTAssertTrue(prepared.inputs.allSatisfy { $0.lastPathComponent.utf8.count <= 200 })
        XCTAssertEqual(prepared.inputs[0].lastPathComponent, prepared.inputs[1].lastPathComponent)
        XCTAssertEqual(InputValidator.validate(prepared.inputs).accepted.count, 2)
        for input in prepared.inputs { XCTAssertEqual(try Data(contentsOf: input), try Data(contentsOf: source)) }
        XCTAssertEqual(f.board.changeCount, generation)
        let outputs = [try f.output(prepared.outputDirectory), try f.output(prepared.outputDirectory, "둘째.jpeg", type: .jpeg)]
        let own = try f.store.publish(snapshot: snapshot, jobID: id, results: outputs)
        XCTAssertEqual(f.store.ownedChangeCount, own)
        let published = try XCTUnwrap(f.board.pasteboardItems)
        XCTAssertEqual(published.count, 5)
        XCTAssertEqual(published[0].string(forType: .fileURL), outputs[0].absoluteString)
        XCTAssertEqual(published[0].string(forType: .URL), outputs[0].absoluteString)
        XCTAssertEqual(published[0].data(forType: .png), try Data(contentsOf: outputs[0]))
        XCTAssertEqual(published[0].data(forType: custom), Data([0, 1, 255]))
        XCTAssertEqual(published[0].string(forType: .string), "설명")
        XCTAssertEqual(published[4].data(forType: .init(UTType.jpeg.identifier)), try Data(contentsOf: outputs[1]))
        let after = try contents(f.board)
        for index in [1, 2, 3] { XCTAssertEqual(after[index], original[index]) }
        f.store.discard(jobID: id)
        f.store.clipboardDidChange()
        XCTAssertTrue(outputs.allSatisfy { f.files.fileExists(atPath: $0.path) })
        XCTAssertThrowsError(try f.store.capture()) { XCTAssertTrue($0 is AutomaticClipboardError) }
        try f.store.shutdown()
        XCTAssertEqual(try contents(f.board), original)
        XCTAssertTrue(outputs.allSatisfy { !f.files.fileExists(atPath: $0.path) })
        XCTAssertTrue(f.files.fileExists(atPath: source.path))
    }

    @MainActor
    func testMixedFinderHEICAndPhotosJPEGPreserveEveryJPEGRepresentationAndOrder() throws {
        let jpeg = try Self.image(.jpeg)
        let jpegType = NSPasteboard.PasteboardType(UTType.jpeg.identifier)
        let assetType = NSPasteboard.PasteboardType("com.apple.photos.object-reference.asset")
        let asset = try PropertyListSerialization.data(fromPropertyList: ["mediaType": 1, "mediaSubtypes": 0],
                                                       format: .binary, options: 0)
        let dynamic = try XCTUnwrap(UTType(tag: "application/x-heiccy-photos-jpeg-reference", tagClass: .mimeType, conformingTo: nil))
        XCTAssertTrue(dynamic.isDynamic)
        let dynamicType = NSPasteboard.PasteboardType(dynamic.identifier)
        let privateType = NSPasteboard.PasteboardType("com.apple.photos.private-jpeg-reference")
        let captionType = NSPasteboard.PasteboardType("test.heic.jpeg-caption")
        // 생략 후보를 일반 표현 사이에 배치해 복원 후 타입 순서까지 검사한다.
        let jpegValues: [(NSPasteboard.PasteboardType, Data)] = [
            (dynamicType, Data([0, 255, 128, 1])), (.string, Data("Photos JPEG 설명\n두 번째 줄".utf8)),
            (jpegType, jpeg), (privateType, Data("Photos 전용 JPEG 참조".utf8)),
            (assetType, asset), (captionType, Data([255, 0, 17, 128])),
        ]
        for photosFirst in [false, true] {
            let f = try Fixture(); defer { f.close() }
            let source = try f.source()
            let sourceBytes = try Data(contentsOf: source)
            let finder = Self.item([(.fileURL, Data(source.absoluteString.utf8)),
                                    (.URL, Data(source.absoluteString.utf8)), (.string, Data("Finder 설명".utf8))])
            let photos = Self.item(jpegValues)
            f.put(photosFirst ? [photos, finder] : [finder, photos])
            let original = try contents(f.board)
            let photoIndex = photosFirst ? 0 : 1
            let finderIndex = photosFirst ? 1 : 0
            let expectedJPEG = jpegValues.map { Representation(type: $0.0.rawValue, data: $0.1) }
            XCTAssertEqual(original[photoIndex], expectedJPEG)
            let generation = f.board.changeCount
            let snapshot = try f.store.capture()
            XCTAssertEqual(snapshot.targets.map(\.source), [source], "Photos JPEG는 변환 대상이 아닙니다.")
            XCTAssertEqual(snapshot.files.map(\.isHEIC), photosFirst ? [false, true] : [true, false])
            let id = UUID().uuidString
            let p = try f.store.prepare(snapshot: snapshot, jobID: id)
            XCTAssertEqual(p.inputs.count, 1)
            XCTAssertEqual(try Data(contentsOf: p.inputs[0]), sourceBytes)
            XCTAssertEqual(f.board.changeCount, generation)
            XCTAssertEqual(try contents(f.board), original)
            let result = try f.output(p.outputDirectory)
            _ = try f.store.publish(snapshot: snapshot, jobID: id, results: [result])
            let published = try contents(f.board)
            XCTAssertEqual(published.count, 2)
            XCTAssertEqual(published[photoIndex], expectedJPEG, "비변환 JPEG의 asset·dynamic·private·설명 바이트와 순서를 모두 유지해야 합니다.")
            let publishedFinder = try XCTUnwrap(f.board.pasteboardItems?[finderIndex])
            XCTAssertEqual(publishedFinder.string(forType: .fileURL), result.absoluteString)
            XCTAssertEqual(publishedFinder.string(forType: .URL), result.absoluteString)
            XCTAssertEqual(publishedFinder.data(forType: .png), try Data(contentsOf: result))
            XCTAssertEqual(publishedFinder.string(forType: .string), "Finder 설명")
            try f.store.shutdown()
            XCTAssertEqual(try contents(f.board), original)
            XCTAssertEqual(try contents(f.board)[photoIndex], expectedJPEG)
            XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
            XCTAssertFalse(f.files.fileExists(atPath: p.inputs[0].path))
            XCTAssertFalse(f.files.fileExists(atPath: result.path))
        }
    }

    @MainActor
    func testStagingNameByteBudgetPreservesUnicodeAndOriginalDescriptors() throws {
        let f = try Fixture(); defer { f.close() }
        let names = [String(repeating: "a", count: 250) + ".heic",
                     String(repeating: "한", count: 83) + "a.heic",
                     String(repeating: "😀", count: 62) + "ab.heic",
                     "그대로 유지할 짧은 이름.heic"]
        let sources = try names.map { try f.source($0) }
        XCTAssertTrue(names.prefix(3).allSatisfy { $0.utf8.count == 255 })
        f.put(sources.map { Self.item([(.fileURL, Data($0.absoluteString.utf8))]) })
        let snapshot = try f.store.capture()
        XCTAssertEqual(snapshot.files.map(\.name), names)
        XCTAssertEqual(snapshot.targets.map(\.source), sources)
        let id = UUID().uuidString
        let prepared = try f.store.prepare(snapshot: snapshot, jobID: id)
        XCTAssertEqual(prepared.inputs.count, sources.count)
        XCTAssertEqual(Set(prepared.inputs).count, sources.count)
        for (source, input) in zip(sources, prepared.inputs) {
            XCTAssertEqual(input.pathExtension, "heic")
            XCTAssertLessThanOrEqual(input.lastPathComponent.utf8.count, 200)
            XCTAssertFalse(input.lastPathComponent.contains("�"))
            XCTAssertEqual(try Data(contentsOf: input), try Data(contentsOf: source))
        }
        XCTAssertEqual(prepared.inputs.last?.lastPathComponent, names.last)
        XCTAssertEqual(try f.store.prepare(snapshot: snapshot, jobID: id).inputs, prepared.inputs)
        f.store.discard(jobID: id)
        XCTAssertTrue(sources.allSatisfy { f.files.fileExists(atPath: $0.path) })
    }

    @MainActor
    func testRawHEICMaterializesAndPreservesRemoteURLAndNonImageBytes() throws {
        let f = try Fixture(); defer { f.close() }
        let heic = try Self.image(.heic)
        let remote = Data("https://example.com/photo".utf8)
        let rawType = NSPasteboard.PasteboardType(UTType.heic.identifier)
        f.put([Self.item([(rawType, heic), (.png, try Self.image(.png)), (.URL, remote), (.string, Data("제목".utf8))])])
        let original = try contents(f.board)
        let snapshot = try f.store.capture()
        XCTAssertNil(snapshot.files.first?.url)
        XCTAssertTrue(snapshot.files.first?.isHEIC == true)
        XCTAssertEqual(snapshot.files.first?.id, snapshot.targets.first?.id)
        XCTAssertFalse(f.files.fileExists(atPath: snapshot.targets[0].source.path))
        let id = UUID().uuidString
        let prepared = try f.store.prepare(snapshot: snapshot, jobID: id)
        XCTAssertEqual(try Data(contentsOf: prepared.inputs[0]), heic)
        let result = try f.output(prepared.outputDirectory, "사진.jpeg", type: .jpeg)
        _ = try f.store.publish(snapshot: snapshot, jobID: id, results: [result])
        let published = try XCTUnwrap(f.board.pasteboardItems?.first)
        XCTAssertNil(published.data(forType: rawType))
        XCTAssertNil(published.data(forType: .png))
        XCTAssertEqual(published.data(forType: .URL), remote)
        XCTAssertEqual(published.string(forType: .string), "제목")
        XCTAssertEqual(published.string(forType: .fileURL), result.absoluteString)
        XCTAssertEqual(published.data(forType: .init(UTType.jpeg.identifier)), try Data(contentsOf: result))
        try f.store.shutdown()
        XCTAssertEqual(try contents(f.board), original)
    }

    @MainActor
    func testUnsafePhotosPromiseRejectsBeforeAnyItemDataProviderIsRequested() throws {
        // 합성 provider의 요청 횟수만 검사한다. 실제 Photos 약속 수신을 실행하지 않는다.
        let assetType = NSPasteboard.PasteboardType("com.apple.photos.object-reference.asset")
        let rawType = NSPasteboard.PasteboardType(UTType.heic.identifier)
        let asset = try PropertyListSerialization.data(fromPropertyList: ["mediaType": 1, "mediaSubtypes": 0],
                                                       format: .binary, options: 0)
        let raw = try Self.image(.heic)
        for unsafeType in [NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"),
                           NSPasteboard.PasteboardType("com.apple.NSFilePromiseItemMetaData")] {
            for hasEarlierItem in [false, true] {
                let f = try Fixture()
                // 종료 정리의 데이터 조회와 capture 검증을 분리한다. 전체 표현 비교도 provider를 호출하므로 하지 않는다.
                defer { f.putText(); f.close() }
                let libraryURL = f.sandbox.appendingPathComponent("합성.photoslibrary/originals/원본.heic")
                let photosProvider = CountingData([
                    .fileURL: Data(libraryURL.absoluteString.utf8),
                    .URL: Data(libraryURL.absoluteString.utf8),
                    assetType: asset, rawType: raw, unsafeType: Data("합성 약속".utf8),
                ])
                let photos = NSPasteboardItem()
                // 약속 타입이 마지막에 있어도 URL·asset·raw의 provider를 요청하면 안 된다.
                let photosTypes: [NSPasteboard.PasteboardType] = [.fileURL, .URL, assetType, rawType, unsafeType]
                XCTAssertTrue(photos.setDataProvider(photosProvider, forTypes: photosTypes))
                let ordinaryProvider = CountingData([.fileURL: Data(f.sandbox.appendingPathComponent("일반.heic").absoluteString.utf8),
                                                     rawType: raw, .string: Data("보존할 텍스트".utf8)])
                let ordinary = NSPasteboardItem()
                XCTAssertTrue(ordinary.setDataProvider(ordinaryProvider, forTypes: [.fileURL, rawType, .string]))
                f.put(hasEarlierItem ? [ordinary, photos] : [photos])
                XCTAssertTrue(photosProvider.requests.isEmpty)
                XCTAssertTrue(ordinaryProvider.requests.isEmpty)
                let generation = f.board.changeCount
                let originalTypes = try XCTUnwrap(f.board.pasteboardItems).map(\.types)
                let boardTypes = f.board.types

                for _ in 0..<2 {
                    XCTAssertThrowsError(try f.store.capture()) { error in
                        guard case AutomaticClipboardError.unsupportedRepresentation = error else {
                            return XCTFail("데이터 조회 전에 약속 타입을 거절해야 합니다: \(error)")
                        }
                    }
                }

                XCTAssertEqual(photosProvider.requests.filter { $0 == .fileURL || $0 == .URL }.count, 0)
                XCTAssertEqual(photosProvider.requests.filter { $0 == assetType }.count, 0)
                XCTAssertEqual(photosProvider.requests.filter { $0 == rawType }.count, 0)
                XCTAssertTrue(photosProvider.requests.isEmpty, "약속 자체를 포함한 모든 데이터 요청이 0회여야 합니다.")
                XCTAssertTrue(ordinaryProvider.requests.isEmpty, "먼저 놓인 일반 항목의 데이터도 읽으면 안 됩니다.")
                XCTAssertEqual(f.board.changeCount, generation)
                XCTAssertEqual(f.board.types, boardTypes)
                XCTAssertEqual(try XCTUnwrap(f.board.pasteboardItems).map(\.types), originalTypes)
                XCTAssertTrue(photosProvider.requests.isEmpty)
                XCTAssertTrue(ordinaryProvider.requests.isEmpty)
                XCTAssertNil(f.store.ownedChangeCount)
                XCTAssertFalse(f.files.fileExists(atPath: f.root.path))
            }
        }
    }

    @MainActor
    func testUnsafePreviewUsesOnlyDeclaredTypesAndNeverRequestsProviders() throws {
        let assetType = NSPasteboard.PasteboardType("com.apple.photos.object-reference.asset")
        let promiseType = NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url")
        for rawType in [NSPasteboard.PasteboardType(UTType.heic.identifier),
                        NSPasteboard.PasteboardType(UTType.heif.identifier), nil] {
            let f = try Fixture(); defer { f.close() }
            var types: [NSPasteboard.PasteboardType] = [.fileURL, .URL, assetType]
            if let rawType { types.append(rawType) }
            types.append(promiseType)
            let provider = CountingData(Dictionary(uniqueKeysWithValues: types.map { ($0, Data([0, 255])) }))
            let photos = NSPasteboardItem()
            XCTAssertTrue(photos.setDataProvider(provider, forTypes: types))
            f.put([Self.item([(.string, Data("앞선 텍스트".utf8))]), photos])
            let generation = f.board.changeCount
            let originalTypes = try XCTUnwrap(f.board.pasteboardItems).map(\.types)

            let preview = try XCTUnwrap(f.store.previewFiles().first)
            XCTAssertEqual(preview.id, "\(generation)-1")
            XCTAssertEqual(preview.name, "파일 약속 항목 2")
            XCTAssertNil(preview.url)
            XCTAssertEqual(preview.isHEIC, rawType != nil)
            XCTAssertFalse(preview.isVideo, "약속의 asset 데이터로 사진/영상을 추정하지 않습니다.")
            f.store.clipboardDidChange()
            try f.store.shutdown()
            XCTAssertTrue(provider.requests.isEmpty)
            XCTAssertEqual(f.board.changeCount, generation)
            XCTAssertEqual(try XCTUnwrap(f.board.pasteboardItems).map(\.types), originalTypes)
        }
    }

    @MainActor
    func testPhotosLibraryRawSupportsMixedCapturePublicationAndNormalizedRestoration() throws {
        let cases: [(library: String, urlTypes: [NSPasteboard.PasteboardType], escaped: Bool)] = [
            ("합성.photoslibrary", [.fileURL], false),
            ("합성.PHOTOSLIBRARY", [.URL], false),
            ("합성.PhOtOsLiBrArY", [.fileURL, .URL], false),
            ("공백 있는.photoslibrary", [.fileURL, .URL], true),
        ]
        let raw = try Self.image(.heic)
        let privateType = NSPasteboard.PasteboardType("com.apple.photos.private-source-url")
        let dynamic = try XCTUnwrap(UTType(tag: "application/x-heiccy-photos-private-reference", tagClass: .mimeType, conformingTo: nil))
        XCTAssertTrue(dynamic.isDynamic)
        let dynamicType = NSPasteboard.PasteboardType(dynamic.identifier)
        let captionType = NSPasteboard.PasteboardType("test.heic.caption")
        for entry in cases {
            for photosFirst in [false, true] {
                var sourceURL: URL?
                var sourceLookups: [URL] = []
                let f = try Fixture(metadataReader: { url in
                    if url == sourceURL { sourceLookups.append(url); return nil }
                    return Self.metadata(url)
                })
                defer { f.close() }
                let source = f.sandbox.appendingPathComponent(entry.library).appendingPathComponent("originals/합성 원본.heic")
                sourceURL = source
                try f.files.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
                let sourceBytes = Data("raw와 다른 원본 파일".utf8)
                try sourceBytes.write(to: source)
                let photos = try Self.photosItem(source: source, raw: raw, urlTypes: entry.urlTypes)
                if entry.escaped {
                    let escaped = source.absoluteString.replacingOccurrences(of: ".photoslibrary", with: ".photos%6Cibrary")
                    for type in entry.urlTypes { XCTAssertTrue(photos.setString(escaped, forType: type)) }
                }
                XCTAssertTrue(photos.setData(Data("설명".utf8), forType: .string))
                XCTAssertTrue(photos.setData(Data([0, 255, 1]), forType: captionType))
                for type in [privateType, dynamicType] {
                    XCTAssertTrue(photos.setData(Data(source.absoluteString.utf8), forType: type))
                }
                let finderSource = try f.source()
                let finderBytes = try Data(contentsOf: finderSource)
                let finder = Self.item([(.fileURL, Data(finderSource.absoluteString.utf8)),
                                        (.URL, Data(finderSource.absoluteString.utf8)), (.string, Data("Finder 설명".utf8))])
                let text = Self.item([(.string, Data("중간 텍스트".utf8)), (captionType, Data([128, 0, 255]))])
                f.put(photosFirst ? [photos, text, finder] : [finder, text, photos])
                let original = try contents(f.board)
                let generation = f.board.changeCount
                let photosIndex = photosFirst ? 0 : 2
                let conversionIndex = photosFirst ? 0 : 1
                let snapshot = try f.store.capture()
                XCTAssertEqual(snapshot.targets.count, 2)
                XCTAssertEqual(snapshot.files.map(\.isHEIC), [true, true])
                XCTAssertNil(snapshot.files[conversionIndex].url)
                XCTAssertNil(f.store.previewFiles()[conversionIndex].url)
                let id = UUID().uuidString
                let p = try f.store.prepare(snapshot: snapshot, jobID: id)
                XCTAssertEqual(p.inputs.count, 2)
                let input = p.inputs[conversionIndex]
                XCTAssertNotEqual(input, source)
                XCTAssertEqual(try Data(contentsOf: input), raw)
                XCTAssertEqual(f.board.changeCount, generation)
                XCTAssertEqual(try contents(f.board), original)
                let results = [try f.output(p.outputDirectory), try f.output(p.outputDirectory, "둘째.jpeg", type: .jpeg)]
                _ = try f.store.publish(snapshot: snapshot, jobID: id, results: results)
                let published = try XCTUnwrap(f.board.pasteboardItems)
                XCTAssertEqual(published.count, 3)
                let photo = published[photosIndex]
                XCTAssertEqual(photo.string(forType: .fileURL), results[conversionIndex].absoluteString)
                if entry.urlTypes.contains(.URL) { XCTAssertEqual(photo.string(forType: .URL), results[conversionIndex].absoluteString) }
                for type in [NSPasteboard.PasteboardType("com.apple.photos.object-reference.asset"), privateType, dynamicType,
                             NSPasteboard.PasteboardType(UTType.heic.identifier)] {
                    XCTAssertFalse(photo.types.contains(type))
                }
                let resultType: NSPasteboard.PasteboardType = conversionIndex == 0 ? .png : .init(UTType.jpeg.identifier)
                XCTAssertEqual(photo.data(forType: resultType), try Data(contentsOf: results[conversionIndex]))
                XCTAssertNotNil(photo.data(forType: .tiff))
                XCTAssertEqual(photo.data(forType: captionType), Data([0, 255, 1]))
                XCTAssertEqual(photo.string(forType: .string), "설명")
                XCTAssertEqual(try contents(f.board)[1], original[1])
                XCTAssertEqual(try Data(contentsOf: input), raw)
                XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
                try f.store.shutdown()
                XCTAssertEqual(try contents(f.board), normalizedPhotosRestore(original, index: photosIndex, input: input, raw: raw,
                                                                            privateTypes: [privateType, dynamicType]))
                XCTAssertEqual(try Data(contentsOf: input), raw)
                XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
                XCTAssertEqual(try Data(contentsOf: finderSource), finderBytes)
                XCTAssertTrue(sourceLookups.isEmpty)
                f.store.discard(jobID: id)
                try f.store.shutdown()
                XCTAssertTrue(f.files.fileExists(atPath: input.path), "복구된 클립보드가 참조하는 입력은 유지해야 합니다.")
                f.putText()
                f.store.clipboardDidChange()
                XCTAssertFalse(f.files.fileExists(atPath: input.path))
                XCTAssertTrue(results.allSatisfy { !f.files.fileExists(atPath: $0.path) })
            }
        }
    }

    @MainActor
    func testPhotosUnknownMetadataAndMismatchedURLsFailWithoutSourceLookup() throws {
        let raw = try Self.image(.heic)
        let objects: [[String: Any]] = [[:], ["mediaType": 0], ["mediaType": 99], ["mediaType": true],
                                      ["mediaType": 1.5], ["mediaType": "1"]]
        let assets: [Data] = try objects.map {
            try PropertyListSerialization.data(fromPropertyList: $0, format: .binary, options: 0)
        } + [Data([0, 255])]
        for libraryType in [NSPasteboard.PasteboardType.fileURL, .URL] {
            for asset in assets {
                var lookups: [URL] = []
                let f = try Fixture(metadataReader: { lookups.append($0); return nil }); defer { f.close() }
                let source = f.sandbox.appendingPathComponent("미생성.photoslibrary/originals/원본.heic")
                let photos = try Self.photosItem(source: source, raw: raw, urlTypes: [libraryType])
                XCTAssertTrue(photos.setData(asset, forType: .init("com.apple.photos.object-reference.asset")))
                f.put([photos])
                let original = try contents(f.board)
                let generation = f.board.changeCount
                XCTAssertThrowsError(try f.store.capture()) {
                    guard case AutomaticClipboardError.unsupportedRepresentation = $0 else { return XCTFail("잘못된 사진 메타데이터 오류: \($0)") }
                }
                XCTAssertNil(try XCTUnwrap(f.store.previewFiles().first).url)
                try f.store.shutdown()
                XCTAssertTrue(lookups.isEmpty)
                XCTAssertEqual(f.board.changeCount, generation)
                XCTAssertEqual(try contents(f.board), original)
                XCTAssertFalse(f.files.fileExists(atPath: f.root.path))
            }
            let f = try Fixture(metadataReader: { _ in XCTFail("불일치 URL의 파일을 조회하면 안 됩니다."); return nil })
            defer { f.close() }
            let source = f.sandbox.appendingPathComponent("미생성.photoslibrary/originals/원본.heic")
            let photos = try Self.photosItem(source: source, raw: raw, urlTypes: [libraryType])
            let otherType: NSPasteboard.PasteboardType = libraryType == .fileURL ? .URL : .fileURL
            XCTAssertTrue(photos.setString(f.sandbox.appendingPathComponent("다른.heic").absoluteString, forType: otherType))
            f.put([photos])
            let original = try contents(f.board)
            let generation = f.board.changeCount
            XCTAssertThrowsError(try f.store.capture()) {
                guard case AutomaticClipboardError.unsupportedRepresentation = $0 else { return XCTFail("URL 불일치 오류: \($0)") }
            }
            XCTAssertNil(try XCTUnwrap(f.store.previewFiles().first).url)
            try f.store.shutdown()
            XCTAssertEqual(f.board.changeCount, generation)
            XCTAssertEqual(try contents(f.board), original)
        }
    }

    @MainActor
    func testPhotosSimilarPathComponentsRemainSupportedWithoutSourceFileReads() throws {
        let raw = try Self.image(.heic)
        for path in ["합성.photoslibrary.backup/original.heic", "photoslibrary/original.heic", "safe/original.photoslibrary.heic"] {
            var sourceLookups: [URL] = []
            var sourceURL: URL?
            let f = try Fixture(metadataReader: { url in
                if url == sourceURL { sourceLookups.append(url); return nil }
                return Self.metadata(url)
            })
            defer { f.close() }
            let source = f.sandbox.appendingPathComponent(path)
            sourceURL = source
            f.put([try Self.photosItem(source: source, raw: raw)])
            let original = try contents(f.board)
            let snapshot = try f.store.capture()
            let id = UUID().uuidString
            let prepared = try f.store.prepare(snapshot: snapshot, jobID: id)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(prepared.inputs.first)), raw)
            _ = try f.store.publish(snapshot: snapshot, jobID: id, results: [f.output(prepared.outputDirectory)])
            try f.store.shutdown()
            XCTAssertEqual(try contents(f.board), normalizedPhotosRestore(original, index: 0, input: prepared.inputs[0], raw: raw))
            XCTAssertEqual(try Data(contentsOf: prepared.inputs[0]), raw)
            XCTAssertTrue(sourceLookups.isEmpty)
            XCTAssertFalse(f.files.fileExists(atPath: source.path))
        }
    }

    @MainActor
    func testFinderLibraryPathWithoutPhotosMetadataRemainsSupported() throws {
        let f = try Fixture(); defer { f.close() }
        let source = f.sandbox.appendingPathComponent("합성.photoslibrary/originals/원본.heic")
        try f.files.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        let originalBytes = try Self.image(.heic)
        try originalBytes.write(to: source)
        let (snapshot, id, inputs, output) = try f.ready(source)
        let original = try contents(f.board)
        XCTAssertEqual(snapshot.targets.map(\.source), [source])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(inputs.first)), originalBytes)
        _ = try f.store.publish(snapshot: snapshot, jobID: id, results: [f.output(output)])
        try f.store.shutdown()
        XCTAssertEqual(try contents(f.board), original)
        XCTAssertEqual(try Data(contentsOf: source), originalBytes)
    }

    @MainActor
    func testPhotosRawOverridesMissingOrDifferentFileWithoutSourceMetadataLookup() throws {
        for state in ["missing", "different", "dataless"] {
            var sourceLookups: [URL] = []
            var sourceURL: URL?
            let f = try Fixture(metadataReader: { url in
                if url == sourceURL {
                    sourceLookups.append(url)
                    if state == "dataless", var value = Self.metadata(url) {
                        value.st_flags |= UInt32(SF_DATALESS)
                        return value
                    }
                    return nil
                }
                return Self.metadata(url)
            })
            defer { f.close() }
            let source = f.sandbox.appendingPathComponent("합성.photoslibrary/originals/Photos 원본.heic")
            sourceURL = source
            try f.files.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            // 기존 URL의 데이터가 raw와 달라도 Photos 복사 시점의 raw를 입력으로 삼는다.
            let fileBytes = Data("URL의 다른 데이터".utf8)
            if state != "missing" { try fileBytes.write(to: source) }
            let raw = try Self.image(.heic)
            f.put([try Self.photosItem(source: source, raw: raw)])
            let original = try contents(f.board)
            let generation = f.board.changeCount
            let snapshot = try f.store.capture()
            XCTAssertEqual(snapshot.targets.map(\.source), [source])
            XCTAssertEqual(snapshot.files.first?.name, source.lastPathComponent)
            XCTAssertNil(snapshot.files.first?.url, "원본 URL을 썸네일 디코더에 전달하면 안 됩니다.")
            let id = UUID().uuidString
            let prepared = try f.store.prepare(snapshot: snapshot, jobID: id)
            XCTAssertEqual(prepared.inputs.count, 1)
            XCTAssertEqual(try Data(contentsOf: prepared.inputs[0]), raw)
            XCTAssertEqual(f.board.changeCount, generation)
            let output = try f.output(prepared.outputDirectory)
            _ = try f.store.publish(snapshot: snapshot, jobID: id, results: [output])
            XCTAssertEqual(f.board.pasteboardItems?.first?.string(forType: .fileURL), output.absoluteString)
            XCTAssertEqual(f.board.pasteboardItems?.first?.string(forType: .URL), output.absoluteString)
            try f.store.shutdown()
            XCTAssertEqual(try contents(f.board), normalizedPhotosRestore(original, index: 0, input: prepared.inputs[0], raw: raw))
            XCTAssertEqual(try Data(contentsOf: prepared.inputs[0]), raw)
            XCTAssertTrue(sourceLookups.isEmpty, "Photos 원본 URL의 metadata를 읽으면 안 됩니다.")
            if state != "missing" { XCTAssertEqual(try Data(contentsOf: source), fileBytes) }
            else { XCTAssertFalse(f.files.fileExists(atPath: source.path)) }
        }
    }

    @MainActor
    func testPhotosCaptureSkipsUnreadablePrivateAndDynamicProviders() throws {
        let f = try Fixture(); defer { f.close() }
        let source = f.sandbox.appendingPathComponent("합성.photoslibrary/originals/원본.heic")
        let raw = try Self.image(.heic)
        let photos = try Self.photosItem(source: source, raw: raw)
        let dynamic = try XCTUnwrap(UTType(tag: "application/x-heiccy-unreadable-photos-reference", tagClass: .mimeType, conformingTo: nil))
        XCTAssertTrue(dynamic.isDynamic)
        let privateTypes = [NSPasteboard.PasteboardType("com.apple.photos.private-url"),
                            NSPasteboard.PasteboardType(dynamic.identifier)]
        let provider = CountingData([:])
        XCTAssertTrue(photos.setDataProvider(provider, forTypes: privateTypes))
        f.put([photos])
        let generation = f.board.changeCount
        let snapshot = try f.store.capture()
        XCTAssertTrue(provider.requests.isEmpty)
        let id = UUID().uuidString
        let p = try f.store.prepare(snapshot: snapshot, jobID: id)
        XCTAssertEqual(try Data(contentsOf: p.inputs[0]), raw)
        XCTAssertEqual(f.board.changeCount, generation)
        let result = try f.output(p.outputDirectory)
        _ = try f.store.publish(snapshot: snapshot, jobID: id, results: [result])
        for type in privateTypes { XCTAssertFalse(try XCTUnwrap(f.board.pasteboardItems?.first).types.contains(type)) }
        try f.store.shutdown()
        let restored = try XCTUnwrap(f.board.pasteboardItems?.first)
        XCTAssertEqual(restored.string(forType: .fileURL), p.inputs[0].absoluteString)
        XCTAssertEqual(restored.string(forType: .URL), p.inputs[0].absoluteString)
        XCTAssertEqual(restored.data(forType: .init(UTType.heic.identifier)), raw)
        for type in privateTypes + [.init("com.apple.photos.object-reference.asset")] {
            XCTAssertFalse(restored.types.contains(type))
        }
        XCTAssertEqual(try Data(contentsOf: p.inputs[0]), raw)
        XCTAssertTrue(provider.requests.isEmpty, "게시·복구·정리에서도 private provider를 요청하면 안 됩니다.")
    }

    @MainActor
    func testPhotosOnlineExportWithoutRawOwnsCaptureBytesBeforePrepare() throws {
        let f = try Fixture(); defer { f.close() }
        let source = try f.source("내보낸 Photos.heic")
        let bytes = try Data(contentsOf: source)
        f.put([try Self.photosItem(source: source)])
        let original = try contents(f.board)
        let generation = f.board.changeCount
        let snapshot = try f.store.capture()
        XCTAssertEqual(snapshot.targets.map(\.source), [source])
        XCTAssertNil(snapshot.files.first?.url)
        // 캡처 이후 원본이 바뀌어도 복사 당시 바이트를 worker와 종료 복구에 사용한다.
        let changed = try Self.image(.heic, red: 0.8)
        XCTAssertNotEqual(changed, bytes)
        try changed.write(to: source)
        let id = UUID().uuidString
        let p = try f.store.prepare(snapshot: snapshot, jobID: id)
        XCTAssertEqual(try Data(contentsOf: p.inputs[0]), bytes)
        XCTAssertEqual(f.board.changeCount, generation)
        _ = try f.store.publish(snapshot: snapshot, jobID: id, results: [f.output(p.outputDirectory)])
        XCTAssertEqual(try Data(contentsOf: source), changed)
        try f.store.shutdown()
        XCTAssertEqual(try contents(f.board), normalizedPhotosRestore(original, index: 0, input: p.inputs[0], raw: bytes))
        XCTAssertEqual(try Data(contentsOf: p.inputs[0]), bytes)
        XCTAssertEqual(try Data(contentsOf: source), changed)
    }

    @MainActor
    func testPhotosLibraryWithoutRawRejectsBeforeAnyFileLookup() throws {
        for urlType in [NSPasteboard.PasteboardType.fileURL, .URL] {
            var lookups: [URL] = []
            let f = try Fixture(metadataReader: { lookups.append($0); return nil }); defer { f.close() }
            let source = f.sandbox.appendingPathComponent("합성.photoslibrary/originals/원본.heic")
            try f.files.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bytes = try Self.image(.heic)
            try bytes.write(to: source)
            f.put([try Self.photosItem(source: source, urlTypes: [urlType])])
            let original = try contents(f.board)
            let generation = f.board.changeCount
            XCTAssertThrowsError(try f.store.capture()) {
                guard case AutomaticClipboardError.photosOriginalUnavailable = $0 else { return XCTFail("raw 없는 보관함 사진 오류: \($0)") }
            }
            XCTAssertNil(try XCTUnwrap(f.store.previewFiles().first).url)
            try f.store.shutdown()
            XCTAssertTrue(lookups.isEmpty)
            XCTAssertEqual(f.board.changeCount, generation)
            XCTAssertEqual(try contents(f.board), original)
            XCTAssertEqual(try Data(contentsOf: source), bytes)
            XCTAssertFalse(f.files.fileExists(atPath: f.root.path))
        }
    }

    @MainActor
    func testPhotosWithoutRawDoesNotDownloadDatalessOrFollowSymlink() throws {
        for linked in [false, true] {
            var sourceURL: URL?
            var sourceLookups = 0
            let f = try Fixture(metadataReader: { url in
                guard var value = Self.metadata(url) else { return nil }
                if url == sourceURL {
                    sourceLookups += 1
                    if !linked { value.st_flags |= UInt32(SF_DATALESS) }
                }
                return value
            }); defer { f.close() }
            let source = f.sandbox.appendingPathComponent("Photos.heic")
            sourceURL = source
            let target = try f.source("링크 대상.heic")
            let bytes = try Data(contentsOf: target)
            if linked { try f.files.createSymbolicLink(at: source, withDestinationURL: target) }
            else { try Data([0, 255]).write(to: source) }
            f.put([try Self.photosItem(source: source)])
            let original = try contents(f.board)
            let generation = f.board.changeCount
            XCTAssertThrowsError(try f.store.capture()) {
                if linked {
                    guard case AutomaticClipboardError.unsafePath = $0 else { return XCTFail("링크를 따라가면 안 됩니다: \($0)") }
                } else {
                    guard case AutomaticClipboardError.fileUnavailable = $0 else { return XCTFail("dataless 파일을 읽으면 안 됩니다: \($0)") }
                }
            }
            XCTAssertEqual(sourceLookups, 1)
            XCTAssertEqual(f.board.changeCount, generation)
            XCTAssertEqual(try contents(f.board), original)
            XCTAssertEqual(try Data(contentsOf: target), bytes)
            if !linked { XCTAssertEqual(try Data(contentsOf: source), Data([0, 255])) }
            XCTAssertFalse(f.files.fileExists(atPath: f.root.path))
        }
    }

    @MainActor
    func testPhotosWithoutRawRejectsParentSymlinkBeforeLookingUpLibraryChildren() throws {
        for urlTypes in [[NSPasteboard.PasteboardType.fileURL], [.URL], [.fileURL, .URL]] {
            var linkURL: URL?
            var libraryURL: URL?
            var lookups: [URL] = []
            var writes = 0
            let f = try Fixture(writer: { _, _ in writes += 1; return false }, metadataReader: { url in
                lookups.append(url)
                if let linkURL, url.path.hasPrefix(linkURL.path + "/") {
                    XCTFail("부모 링크 아래의 파일·디렉터리를 조회하면 안 됩니다: \(url.path)")
                    return nil
                }
                if let libraryURL, url.path == libraryURL.path || url.path.hasPrefix(libraryURL.path + "/") {
                    XCTFail("링크 대상 Photos 보관함을 조회하면 안 됩니다: \(url.path)")
                    return nil
                }
                return Self.metadata(url)
            }); defer { f.close() }
            let library = f.sandbox.appendingPathComponent("합성.photoslibrary", isDirectory: true)
            libraryURL = library
            let originals = library.appendingPathComponent("originals", isDirectory: true)
            try f.files.createDirectory(at: originals, withIntermediateDirectories: true)
            let originalFile = originals.appendingPathComponent("원본.heic")
            let bytes = try Self.image(.heic)
            try bytes.write(to: originalFile)
            let link = f.sandbox.appendingPathComponent("외부 내보내기", isDirectory: true)
            linkURL = link
            try f.files.createSymbolicLink(at: link, withDestinationURL: library)
            XCTAssertEqual(try XCTUnwrap(Self.metadata(link)).st_mode & S_IFMT, S_IFLNK)
            let source = link.appendingPathComponent("originals/원본.heic")
            XCTAssertFalse(source.pathComponents.contains { $0.hasSuffix(".photoslibrary") })
            f.put([try Self.photosItem(source: source, urlTypes: urlTypes)])
            let original = try contents(f.board)
            let generation = f.board.changeCount
            XCTAssertThrowsError(try f.store.capture()) {
                guard case AutomaticClipboardError.unsafePath = $0 else { return XCTFail("부모 링크를 파일 읽기 전에 거절해야 합니다: \($0)") }
            }
            XCTAssertEqual(lookups.last, link, "최초 심볼릭 링크에서 검사를 멈춰야 합니다.")
            XCTAssertFalse(lookups.contains(source))
            let checkedParents = lookups
            XCTAssertNil(try XCTUnwrap(f.store.previewFiles().first).url)
            try f.store.shutdown()
            XCTAssertEqual(lookups, checkedParents)
            XCTAssertEqual(writes, 0)
            XCTAssertNil(f.store.ownedChangeCount)
            XCTAssertEqual(f.board.changeCount, generation)
            XCTAssertEqual(try contents(f.board), original)
            XCTAssertEqual(try Data(contentsOf: originalFile), bytes)
            XCTAssertFalse(f.files.fileExists(atPath: f.root.path))
        }
    }

    @MainActor
    func testPhotosCorruptRawRejectsEvenWithReadableOriginal() throws {
        let heic = try Self.image(.heic)
        for raw in [Data([0, 255]), Data(heic.prefix(32)), try Self.image(.png)] {
            var sourceURL: URL?
            var lookups = 0
            let f = try Fixture(metadataReader: { url in
                if url == sourceURL { lookups += 1; return nil }
                return Self.metadata(url)
            }); defer { f.close() }
            let source = try f.source()
            sourceURL = source
            let bytes = try Data(contentsOf: source)
            f.put([try Self.photosItem(source: source, raw: raw)])
            let original = try contents(f.board)
            let generation = f.board.changeCount
            XCTAssertThrowsError(try f.store.capture()) {
                guard case AutomaticClipboardError.invalidImage = $0 else { return XCTFail("손상 raw를 거절해야 합니다: \($0)") }
            }
            XCTAssertEqual(lookups, 0)
            XCTAssertEqual(f.board.changeCount, generation)
            XCTAssertEqual(try contents(f.board), original)
            XCTAssertEqual(try Data(contentsOf: source), bytes)
            XCTAssertFalse(f.files.fileExists(atPath: f.root.path))
        }
    }

    @MainActor
    func testPhotosLibraryVideoWithHEICPosterRemainsUnsupported() throws {
        for urlType in [NSPasteboard.PasteboardType.fileURL, .URL] {
            let f = try Fixture(metadataReader: { _ in XCTFail("보관함 동영상 파일 조회 금지"); return nil })
            defer { f.close() }
            let source = f.sandbox.appendingPathComponent("합성.photoslibrary/originals/영상.mov")
            f.put([try Self.photosItem(source: source, raw: Self.image(.heic), urlTypes: [urlType], mediaType: 2)])
            let original = try contents(f.board)
            let generation = f.board.changeCount
            XCTAssertThrowsError(try f.store.capture()) {
                guard case AutomaticClipboardError.unrestorablePhotosLibraryURL = $0 else { return XCTFail("동영상 포스터를 변환하면 안 됩니다: \($0)") }
            }
            let preview = try XCTUnwrap(f.store.previewFiles().first)
            XCTAssertTrue(preview.isVideo)
            XCTAssertFalse(preview.isHEIC)
            XCTAssertNil(preview.url)
            try f.store.shutdown()
            XCTAssertEqual(f.board.changeCount, generation)
            XCTAssertEqual(try contents(f.board), original)
        }
    }

    @MainActor
    func testPhotosAssetReferenceAloneCannotPrepareConversion() throws {
        let f = try Fixture(); defer { f.close() }
        f.put([try Self.photosItem(source: f.sandbox.appendingPathComponent("미제공.heic"), urlTypes: [])])
        let original = try contents(f.board)
        let generation = f.board.changeCount
        let snapshot = try f.store.capture()
        XCTAssertTrue(snapshot.targets.isEmpty)
        XCTAssertThrowsError(try f.store.prepare(snapshot: snapshot, jobID: UUID().uuidString)) {
            guard case AutomaticClipboardError.incompleteResults = $0 else { return XCTFail("asset 참조만으로 입력을 만들면 안 됩니다: \($0)") }
        }
        try f.store.shutdown()
        XCTAssertEqual(f.board.changeCount, generation)
        XCTAssertEqual(try contents(f.board), original)
        XCTAssertFalse(f.files.fileExists(atPath: f.root.path))
    }

    @MainActor
    func testPhotosFailedPublicationRollsBackToOwnedInputAndKeepsReferencedFiles() throws {
        var calls = 0
        let f = try Fixture(writer: { board, items in
            calls += 1
            let written = board.writeObjects(items)
            return calls == 1 ? false : written
        }); defer { f.close() }
        let source = try f.source()
        let sourceBytes = try Data(contentsOf: source)
        let raw = try Self.image(.heic, red: 0.8)
        f.put([try Self.photosItem(source: source, raw: raw), Self.item([(.string, Data("중간 설명".utf8))])])
        let original = try contents(f.board)
        let snapshot = try f.store.capture()
        let id = UUID().uuidString
        let p = try f.store.prepare(snapshot: snapshot, jobID: id)
        let result = try f.output(p.outputDirectory)
        XCTAssertThrowsError(try f.store.publish(snapshot: snapshot, jobID: id, results: [result])) {
            guard case AutomaticClipboardError.writeFailed = $0 else { return XCTFail("게시 실패 오류: \($0)") }
        }
        XCTAssertEqual(calls, 2)
        let expected = normalizedPhotosRestore(original, index: 0, input: p.inputs[0], raw: raw)
        XCTAssertEqual(try contents(f.board), expected)
        XCTAssertEqual(f.store.ownedChangeCount, f.board.changeCount)
        XCTAssertEqual(try Data(contentsOf: p.inputs[0]), raw)
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
        f.store.discard(jobID: id)
        try f.store.shutdown()
        XCTAssertEqual(try contents(f.board), expected)
        XCTAssertEqual(try Data(contentsOf: p.inputs[0]), raw)
        XCTAssertTrue(f.files.fileExists(atPath: result.path))
        f.putText()
        let external = f.board.changeCount
        f.store.clipboardDidChange()
        XCTAssertEqual(f.board.changeCount, external)
        XCTAssertFalse(f.files.fileExists(atPath: p.inputs[0].path))
        XCTAssertFalse(f.files.fileExists(atPath: result.path))
    }

    @MainActor
    func testPhotosRollbackAndShutdownFailureKeepFilesUntilNormalizedRestoreRetry() throws {
        var writingWorks = false
        let f = try Fixture(writer: { board, items in writingWorks && board.writeObjects(items) })
        defer { f.close() }
        let source = f.sandbox.appendingPathComponent("합성.photoslibrary/originals/미생성.heic")
        let raw = try Self.image(.heic)
        f.put([try Self.photosItem(source: source, raw: raw)])
        let original = try contents(f.board)
        let snapshot = try f.store.capture()
        let id = UUID().uuidString
        let p = try f.store.prepare(snapshot: snapshot, jobID: id)
        let result = try f.output(p.outputDirectory)
        XCTAssertThrowsError(try f.store.publish(snapshot: snapshot, jobID: id, results: [result])) {
            guard case AutomaticClipboardError.restoreFailed = $0 else { return XCTFail("롤백 실패 오류: \($0)") }
        }
        f.store.discard(jobID: id)
        XCTAssertThrowsError(try f.store.shutdown()) {
            guard case AutomaticClipboardError.restoreFailed = $0 else { return XCTFail("종료 복구 실패 오류: \($0)") }
        }
        XCTAssertEqual(try Data(contentsOf: p.inputs[0]), raw)
        XCTAssertTrue(f.files.fileExists(atPath: result.path))
        f.store.clipboardDidChange()
        XCTAssertTrue(f.files.fileExists(atPath: result.path))
        writingWorks = true
        try f.store.shutdown()
        XCTAssertEqual(try contents(f.board), normalizedPhotosRestore(original, index: 0, input: p.inputs[0], raw: raw))
        XCTAssertEqual(try Data(contentsOf: p.inputs[0]), raw)
        XCTAssertFalse(f.files.fileExists(atPath: source.path))
        f.putText()
        f.store.clipboardDidChange()
        XCTAssertFalse(f.files.fileExists(atPath: p.inputs[0].path))
        XCTAssertFalse(f.files.fileExists(atPath: result.path))
    }

    @MainActor
    func testPhotosRestoreInputReadErrorDoesNotMutateClipboardOrDeletePublishedFiles() throws {
        var unavailableInput: URL?
        let f = try Fixture(metadataReader: { url in
            guard var value = Self.metadata(url) else { return nil }
            if url == unavailableInput { value.st_flags |= UInt32(SF_DATALESS) }
            return value
        }); defer { f.close() }
        let source = try f.source()
        let sourceBytes = try Data(contentsOf: source)
        let raw = try Self.image(.heic)
        f.put([try Self.photosItem(source: source, raw: raw)])
        let original = try contents(f.board)
        let initial = f.board.changeCount
        let snapshot = try f.store.capture()
        let id = UUID().uuidString
        let p = try f.store.prepare(snapshot: snapshot, jobID: id)
        let result = try f.output(p.outputDirectory)
        unavailableInput = p.inputs[0]
        XCTAssertThrowsError(try f.store.publish(snapshot: snapshot, jobID: id, results: [result])) {
            guard case AutomaticClipboardError.fileUnavailable = $0 else { return XCTFail("복구 입력 조회 오류: \($0)") }
        }
        XCTAssertEqual(f.board.changeCount, initial)
        XCTAssertEqual(try contents(f.board), original)
        unavailableInput = nil
        _ = try f.store.publish(snapshot: snapshot, jobID: id, results: [result])
        let published = try contents(f.board)
        let generation = f.board.changeCount
        unavailableInput = p.inputs[0]
        XCTAssertThrowsError(try f.store.shutdown()) {
            guard case AutomaticClipboardError.fileUnavailable = $0 else { return XCTFail("종료 입력 조회 오류: \($0)") }
        }
        XCTAssertEqual(f.board.changeCount, generation)
        XCTAssertEqual(try contents(f.board), published)
        XCTAssertEqual(try Data(contentsOf: p.inputs[0]), raw)
        XCTAssertTrue(f.files.fileExists(atPath: result.path))
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
        unavailableInput = nil
        try f.store.shutdown()
        XCTAssertEqual(try contents(f.board), normalizedPhotosRestore(original, index: 0, input: p.inputs[0], raw: raw))
        XCTAssertEqual(try Data(contentsOf: p.inputs[0]), raw)
    }

    @MainActor
    func testPhotosForeignClipboardAndCleanupReadErrorPreserveReferencesWithoutMutation() throws {
        var lookupFails = false
        let f = try Fixture(cleanupItemsReader: { lookupFails ? nil : $0.pasteboardItems })
        defer { f.close() }
        let raw = try Self.image(.heic)
        let source = f.sandbox.appendingPathComponent("합성.photoslibrary/originals/미생성.heic")
        f.put([try Self.photosItem(source: source, raw: raw)])
        let snapshot = try f.store.capture()
        let id = UUID().uuidString
        let p = try f.store.prepare(snapshot: snapshot, jobID: id)
        let result = try f.output(p.outputDirectory)
        _ = try f.store.publish(snapshot: snapshot, jobID: id, results: [result])
        // 소유 입력을 외부 프로그램이 다시 복사한 경우에도 종료 복구로 덮어쓰지 않는다.
        f.put([Self.item([(.URL, Data(p.inputs[0].absoluteString.utf8)), (.string, Data("외부 설명".utf8))])])
        let foreign = try contents(f.board)
        let generation = f.board.changeCount
        lookupFails = true
        f.store.clipboardDidChange()
        try f.store.shutdown()
        XCTAssertNil(f.store.ownedChangeCount)
        XCTAssertEqual(f.board.changeCount, generation)
        XCTAssertEqual(try contents(f.board), foreign)
        XCTAssertEqual(try Data(contentsOf: p.inputs[0]), raw)
        XCTAssertTrue(f.files.fileExists(atPath: result.path))
        lookupFails = false
        f.store.clipboardDidChange()
        XCTAssertEqual(try Data(contentsOf: p.inputs[0]), raw)
        XCTAssertEqual(try contents(f.board), foreign)
        f.putText("참조 없는 외부 복사")
        let unreferenced = f.board.changeCount
        lookupFails = true
        f.store.clipboardDidChange()
        XCTAssertTrue(f.files.fileExists(atPath: result.path))
        lookupFails = false
        f.store.clipboardDidChange()
        XCTAssertFalse(f.files.fileExists(atPath: p.inputs[0].path))
        XCTAssertFalse(f.files.fileExists(atPath: result.path))
        XCTAssertEqual(f.board.changeCount, unreferenced)
        XCTAssertEqual(f.board.string(forType: .string), "참조 없는 외부 복사")
    }

    @MainActor
    func testOrdinarySourceMetadataFailureDoesNotFallBackToValidRaw() throws {
        var sourceURL: URL?
        var sourceLookups = 0
        let f = try Fixture(metadataReader: { url in
            if url == sourceURL { sourceLookups += 1; return nil }
            return Self.metadata(url)
        })
        defer { f.close() }
        let source = try f.source()
        sourceURL = source
        let raw = try Data(contentsOf: source)
        f.put([Self.item([(.fileURL, Data(source.absoluteString.utf8)), (.init(UTType.heic.identifier), raw)])])
        let original = try contents(f.board)
        let generation = f.board.changeCount
        XCTAssertThrowsError(try f.store.capture()) {
            guard case AutomaticClipboardError.unsafePath = $0 else { return XCTFail("메타데이터 조회 실패를 거절하지 않았습니다: \($0)") }
        }
        XCTAssertEqual(sourceLookups, 1)
        XCTAssertEqual(f.board.changeCount, generation)
        XCTAssertEqual(try contents(f.board), original)
        XCTAssertEqual(try Data(contentsOf: source), raw)
        XCTAssertFalse(f.files.fileExists(atPath: f.root.path))
    }

    @MainActor
    func testOrdinaryDatalessSourceDoesNotReadFileOrFallBackToValidRaw() throws {
        var sourceURL: URL?
        var sourceLookups = 0
        let f = try Fixture(metadataReader: { url in
            guard var value = Self.metadata(url) else { return nil }
            if url == sourceURL { sourceLookups += 1; value.st_flags |= UInt32(SF_DATALESS) }
            return value
        })
        defer { f.close() }
        let source = f.sandbox.appendingPathComponent("오프라인 원본.heic")
        sourceURL = source
        // 실제 파일 플래그·파일 공급자는 변경하지 않는다. 파일을 읽었다면 invalidImage가 발생한다.
        let fileBytes = Data([1, 2, 3])
        try fileBytes.write(to: source)
        f.put([Self.item([(.fileURL, Data(source.absoluteString.utf8)),
                          (.init(UTType.heic.identifier), try Self.image(.heic))])])
        let original = try contents(f.board)
        let generation = f.board.changeCount
        XCTAssertThrowsError(try f.store.capture()) {
            guard case AutomaticClipboardError.fileUnavailable = $0 else { return XCTFail("dataless 파일을 읽기 전에 거절하지 않았습니다: \($0)") }
        }
        XCTAssertEqual(sourceLookups, 1)
        XCTAssertEqual(f.board.changeCount, generation)
        XCTAssertEqual(try contents(f.board), original)
        XCTAssertEqual(try Data(contentsOf: source), fileBytes)
        XCTAssertFalse(f.files.fileExists(atPath: f.root.path))
    }

    @MainActor
    func testOrdinaryFileAndDifferentRawAreRejectedWithoutChangingOriginal() throws {
        let f = try Fixture(); defer { f.close() }
        let source = try f.source()
        let fileBytes = try Data(contentsOf: source)
        // 색이 다른 유효한 HEIC를 사용해 손상된 raw 거절과 원본 불일치를 구분한다.
        let raw = try Self.image(.heic, red: 0.8)
        XCTAssertNotEqual(raw, fileBytes)
        XCTAssertNotNil(CGImageSourceCreateWithData(raw as CFData, nil))
        f.put([Self.item([(.fileURL, Data(source.absoluteString.utf8)), (.init(UTType.heic.identifier), raw)])])
        let original = try contents(f.board)
        let generation = f.board.changeCount
        XCTAssertThrowsError(try f.store.capture()) {
            guard case AutomaticClipboardError.unsupportedRepresentation = $0 else { return XCTFail("다른 원본 표현을 거절하지 않았습니다: \($0)") }
        }
        XCTAssertEqual(f.board.changeCount, generation)
        XCTAssertEqual(try contents(f.board), original)
        XCTAssertEqual(try Data(contentsOf: source), fileBytes)
    }

    @MainActor
    func testPhotosPreviewAfterMixedCaptureFailureDoesNotExposeOriginalURL() throws {
        let f = try Fixture(); defer { f.close() }
        let source = f.sandbox.appendingPathComponent("물질화되지 않은 Photos.heic")
        f.put([try Self.photosItem(source: source, raw: Self.image(.heic)),
               Self.item([(.init("com.apple.pasteboard.promised-file-url"), Data())])])
        let original = try contents(f.board)
        let generation = f.board.changeCount
        XCTAssertThrowsError(try f.store.capture())
        let preview = try XCTUnwrap(f.store.previewFiles().first)
        XCTAssertEqual(preview.name, source.lastPathComponent)
        XCTAssertTrue(preview.isHEIC)
        XCTAssertNil(preview.url, "전체 캡처가 실패해도 Photos 원본 URL을 썸네일에 전달하면 안 됩니다.")
        XCTAssertEqual(f.board.changeCount, generation)
        XCTAssertEqual(try contents(f.board), original)
    }

    @MainActor
    func testDatalessPreviewAfterCaptureFailureDoesNotExposeOriginalURL() throws {
        var sourceURL: URL?
        let f = try Fixture(metadataReader: { url in
            guard var value = Self.metadata(url) else { return nil }
            if url == sourceURL { value.st_flags |= UInt32(SF_DATALESS) }
            return value
        })
        defer { f.close() }
        let source = try f.source()
        sourceURL = source
        f.put([Self.item([(.fileURL, Data(source.absoluteString.utf8))])])
        let original = try contents(f.board)
        let generation = f.board.changeCount
        XCTAssertThrowsError(try f.store.capture())
        let preview = try XCTUnwrap(f.store.previewFiles().first)
        XCTAssertEqual(preview.name, source.lastPathComponent)
        XCTAssertTrue(preview.isHEIC)
        XCTAssertNil(preview.url, "캡처에서 거절한 dataless 파일을 썸네일에 전달하면 안 됩니다.")
        XCTAssertEqual(f.board.changeCount, generation)
        XCTAssertEqual(try contents(f.board), original)
    }

    @MainActor
    func testPromisesUnreadableExpressionsAndPreviewNeverAlterOriginal() throws {
        let f = try Fixture(); defer { f.close() }
        let source = try f.source()
        let promise = NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url")
        f.put([Self.item([(.fileURL, Data(source.absoluteString.utf8)), (promise, Data("약속".utf8))])])
        let original = try contents(f.board)
        let generation = f.board.changeCount
        XCTAssertThrowsError(try f.store.capture())
        let promisePreview = try XCTUnwrap(f.store.previewFiles().first)
        XCTAssertEqual(promisePreview.name, "파일 약속 항목 1")
        XCTAssertNil(promisePreview.url)
        XCTAssertFalse(promisePreview.isHEIC)
        XCTAssertEqual(f.board.changeCount, generation)
        XCTAssertEqual(try contents(f.board), original)
        let provider = MissingData()
        let missing = Self.item([(.fileURL, Data(source.absoluteString.utf8))])
        XCTAssertTrue(missing.setDataProvider(provider, forTypes: [.init("test.unreadable")]))
        f.put([missing])
        let unreadableGeneration = f.board.changeCount
        XCTAssertThrowsError(try f.store.capture())
        XCTAssertEqual(f.board.changeCount, unreadableGeneration)
        XCTAssertEqual(f.store.previewFiles().map(\.url), [source])
        f.put([Self.item([(.fileURL, Data(source.deletingPathExtension().appendingPathExtension("heif").absoluteString.utf8))])])
        XCTAssertTrue(try f.store.capture().targets.isEmpty)
        f.putText()
        XCTAssertTrue(try f.store.capture().files.isEmpty)
    }

    @MainActor
    func testAllOrNothingRejectsIncompleteInvalidUnreadableAndUnsafeResults() throws {
        let f = try Fixture(); defer { f.close() }
        let source = try f.source()
        f.put([Self.item([(.fileURL, Data(source.absoluteString.utf8))]), Self.item([(.fileURL, Data(source.absoluteString.utf8))])])
        let snapshot = try f.store.capture()
        let id = UUID().uuidString
        let p = try f.store.prepare(snapshot: snapshot, jobID: id)
        let valid = try f.output(p.outputDirectory)
        let invalid = p.outputDirectory.appendingPathComponent("손상.png")
        try Data([1, 2, 3]).write(to: invalid)
        let outside = try f.output(f.sandbox, "외부.png")
        let link = p.outputDirectory.appendingPathComponent("링크.png")
        try f.files.createSymbolicLink(at: link, withDestinationURL: outside)
        let unreadable = try f.output(p.outputDirectory, "읽기불가.png")
        try f.files.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        defer { try? f.files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path) }
        let original = try contents(f.board)
        let generation = f.board.changeCount
        for results in [[], [valid], [valid, valid], [valid, invalid], [valid, outside], [valid, link], [valid, unreadable]] {
            XCTAssertThrowsError(try f.store.publish(snapshot: snapshot, jobID: id, results: results))
            XCTAssertEqual(f.board.changeCount, generation)
            XCTAssertEqual(try contents(f.board), original)
        }
        f.store.discard(jobID: id)
        XCTAssertFalse(f.files.fileExists(atPath: p.outputDirectory.path))
        XCTAssertTrue(f.files.fileExists(atPath: outside.path))
    }

    @MainActor
    func testSourceSystemAliasNSURLAndManagedPathOwnership() throws {
        let f = try Fixture(); defer { f.close() }
        let source = try f.source()
        let aliased = URL(fileURLWithPath: source.path.replacingOccurrences(of: "/private/var/", with: "/var/"))
        f.board.clearContents()
        XCTAssertTrue(f.board.writeObjects([aliased as NSURL]))
        let snapshot = try f.store.capture()
        XCTAssertEqual(snapshot.targets.count, 1)
        let id = UUID().uuidString
        let p = try f.store.prepare(snapshot: snapshot, jobID: id)
        XCTAssertEqual(try Data(contentsOf: p.inputs[0]), try Data(contentsOf: source))
        for bad in ["", "..", "../외부", UUID().uuidString + "/child"] {
            XCTAssertThrowsError(try f.store.prepare(snapshot: snapshot, jobID: bad))
            f.store.discard(jobID: bad)
        }
        let foreignID = UUID().uuidString
        let foreign = f.root.appendingPathComponent(foreignID)
        try f.files.createDirectory(at: foreign, withIntermediateDirectories: false)
        XCTAssertThrowsError(try f.store.prepare(snapshot: snapshot, jobID: foreignID))
        f.store.discard(jobID: foreignID)
        XCTAssertTrue(f.files.fileExists(atPath: foreign.path))
        let jobDirectory = p.outputDirectory.deletingLastPathComponent()
        try f.files.removeItem(at: jobDirectory)
        try f.files.createSymbolicLink(at: jobDirectory, withDestinationURL: f.sandbox)
        f.store.discard(jobID: id)
        XCTAssertTrue(f.files.fileExists(atPath: source.path))
        XCTAssertThrowsError(try f.store.prepare(snapshot: snapshot, jobID: id))
        let sourceLink = f.sandbox.appendingPathComponent("원본링크.heic")
        try f.files.createSymbolicLink(at: sourceLink, withDestinationURL: source)
        f.put([Self.item([(.fileURL, Data(sourceLink.absoluteString.utf8))])])
        XCTAssertThrowsError(try f.store.capture())
    }

    @MainActor
    func testNewGenerationBeforeAndDuringWriteRemainsUntouched() throws {
        let f = try Fixture(writer: { board, _ in
            board.clearContents()
            XCTAssertTrue(board.setString("쓰기 도중 새 복사", forType: .string))
            return false
        }); defer { f.close() }
        let source = try f.source()
        let (snapshot, id, _, output) = try f.ready(source)
        let result = try f.output(output)
        f.putText("쓰기 이전 새 복사")
        let before = f.board.changeCount
        XCTAssertThrowsError(try f.store.publish(snapshot: snapshot, jobID: id, results: [result]))
        XCTAssertEqual(f.board.changeCount, before)
        XCTAssertEqual(f.board.string(forType: .string), "쓰기 이전 새 복사")
        f.store.discard(jobID: id)
        let (next, nextID, _, nextOutput) = try f.ready(source)
        let nextResult = try f.output(nextOutput)
        XCTAssertThrowsError(try f.store.publish(snapshot: next, jobID: nextID, results: [nextResult]))
        let after = f.board.changeCount
        XCTAssertNil(f.store.ownedChangeCount)
        f.store.discard(jobID: nextID)
        XCTAssertTrue(f.files.fileExists(atPath: nextResult.path))
        f.store.clipboardDidChange()
        XCTAssertEqual(f.board.changeCount, after)
        XCTAssertEqual(f.board.string(forType: .string), "쓰기 도중 새 복사")
        XCTAssertFalse(f.files.fileExists(atPath: nextResult.path))
        try f.store.shutdown()
        XCTAssertEqual(f.board.changeCount, after)
    }

    @MainActor
    func testFailedWriteRollsBackExactlyAndAllowsCaptureRetry() throws {
        var calls = 0
        let f = try Fixture(writer: { board, items in
            calls += 1
            if calls == 1 { _ = board.writeObjects(items); return false }
            return board.writeObjects(items)
        }); defer { f.close() }
        let source = try f.source()
        let (snapshot, id, _, output) = try f.ready(source)
        let original = try contents(f.board)
        let result = try f.output(output)
        XCTAssertThrowsError(try f.store.publish(snapshot: snapshot, jobID: id, results: [result])) {
            guard case AutomaticClipboardError.writeFailed = $0 else { return XCTFail("예상한 게시 실패가 아닙니다: \($0)") }
        }
        XCTAssertEqual(try contents(f.board), original)
        XCTAssertEqual(f.store.ownedChangeCount, f.board.changeCount)
        XCTAssertEqual(try f.store.capture().targets.count, 1)
        f.store.discard(jobID: id)
        f.store.clipboardDidChange()
        XCTAssertTrue(f.files.fileExists(atPath: result.path))
        try f.store.shutdown()
        XCTAssertFalse(f.files.fileExists(atPath: result.path))
        XCTAssertEqual(try contents(f.board), original)
    }

    @MainActor
    func testRollbackAndShutdownRestoreFailureProtectExposedFilesUntilSuccessfulRetry() throws {
        var writingWorks = false
        let f = try Fixture(writer: { board, items in writingWorks && board.writeObjects(items) }); defer { f.close() }
        let source = try f.source()
        let (snapshot, id, _, output) = try f.ready(source)
        let original = try contents(f.board)
        let result = try f.output(output)
        XCTAssertThrowsError(try f.store.publish(snapshot: snapshot, jobID: id, results: [result]))
        XCTAssertEqual(f.store.ownedChangeCount, f.board.changeCount)
        f.store.discard(jobID: id)
        f.store.clipboardDidChange()
        XCTAssertTrue(f.files.fileExists(atPath: result.path))
        XCTAssertThrowsError(try f.store.capture())
        XCTAssertThrowsError(try f.store.shutdown())
        XCTAssertTrue(f.files.fileExists(atPath: result.path))
        f.store.clipboardDidChange()
        XCTAssertTrue(f.files.fileExists(atPath: result.path))
        writingWorks = true
        try f.store.shutdown()
        XCTAssertEqual(try contents(f.board), original)
        XCTAssertFalse(f.files.fileExists(atPath: result.path))
    }

    @MainActor
    func testSuccessfulPublishThenShutdownFailureKeepsPublishedFilesAndExternalCopy() throws {
        var writingWorks = true
        let f = try Fixture(writer: { board, items in writingWorks && board.writeObjects(items) }); defer { f.close() }
        let (snapshot, id, _, output) = try f.ready(f.source())
        let result = try f.output(output)
        _ = try f.store.publish(snapshot: snapshot, jobID: id, results: [result])
        writingWorks = false
        XCTAssertThrowsError(try f.store.shutdown())
        f.store.discard(jobID: id)
        f.store.clipboardDidChange()
        XCTAssertTrue(f.files.fileExists(atPath: result.path))
        f.putText("종료 도중 외부 복사")
        let external = f.board.changeCount
        try f.store.shutdown()
        XCTAssertEqual(f.board.changeCount, external)
        XCTAssertEqual(f.board.string(forType: .string), "종료 도중 외부 복사")
        XCTAssertFalse(f.files.fileExists(atPath: result.path))
    }

    @MainActor
    func testItemLookupFailureKeepsFilesUntilUnreferencedClipboardCanBeRead() throws {
        var lookupFails = false
        let f = try Fixture(cleanupItemsReader: { lookupFails ? nil : $0.pasteboardItems })
        defer { f.close() }
        let (snapshot, id, _, output) = try f.ready(f.source())
        let result = try f.output(output)
        _ = try f.store.publish(snapshot: snapshot, jobID: id, results: [result])
        // 새 복사가 같은 결과를 참조하더라도 항목 조회 자체는 실패할 수 있다.
        f.put([Self.item([(.fileURL, Data(result.absoluteString.utf8))])])
        let generation = f.board.changeCount
        XCTAssertFalse(try XCTUnwrap(f.board.types).isEmpty)
        lookupFails = true
        f.store.clipboardDidChange()
        f.store.discard(jobID: id)
        XCTAssertTrue(f.files.fileExists(atPath: result.path))
        try f.store.shutdown()
        XCTAssertTrue(f.files.fileExists(atPath: result.path))
        XCTAssertEqual(f.board.changeCount, generation)
        XCTAssertEqual(f.board.string(forType: .fileURL), result.absoluteString)
        lookupFails = false
        f.store.clipboardDidChange()
        XCTAssertTrue(f.files.fileExists(atPath: result.path))
        f.putText()
        lookupFails = true
        f.store.clipboardDidChange()
        XCTAssertTrue(f.files.fileExists(atPath: result.path), "조회 실패를 참조 부재로 취급하면 안 됩니다.")
        lookupFails = false
        f.store.clipboardDidChange()
        XCTAssertFalse(f.files.fileExists(atPath: result.path))
    }

    @MainActor
    func testUnsafeExternalClipboardKeepsExposedFilesWithoutRequestingAnyProvider() throws {
        for unsafeType in [NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"),
                           NSPasteboard.PasteboardType("com.apple.NSFilePromiseItemMetaData")] {
            let f = try Fixture(); defer { f.close() }
            let source = try f.source()
            let originalSource = try Data(contentsOf: source)
            let (snapshot, id, _, output) = try f.ready(source)
            let result = try f.output(output)
            let resultBytes = try Data(contentsOf: result)
            _ = try f.store.publish(snapshot: snapshot, jobID: id, results: [result])
            let assetType = NSPasteboard.PasteboardType("com.apple.photos.object-reference.asset")
            let rawType = NSPasteboard.PasteboardType(UTType.heic.identifier)
            let promiseTypes: [NSPasteboard.PasteboardType] = [.fileURL, .URL, assetType, rawType, unsafeType]
            let promiseProvider = CountingData([
                .fileURL: Data(result.absoluteString.utf8), .URL: Data(result.absoluteString.utf8),
                assetType: Data([0, 255]), rawType: originalSource, unsafeType: Data("합성 약속".utf8),
            ])
            let promise = NSPasteboardItem()
            XCTAssertTrue(promise.setDataProvider(promiseProvider, forTypes: promiseTypes))
            // 뒤쪽 약속 타입 검사보다 먼저 일반 항목의 provider를 실행해서도 안 된다.
            let ordinaryProvider = CountingData([.fileURL: Data(result.absoluteString.utf8)])
            let ordinary = NSPasteboardItem()
            XCTAssertTrue(ordinary.setDataProvider(ordinaryProvider, forTypes: [.fileURL]))
            f.put([ordinary, promise])
            let generation = f.board.changeCount
            let originalTypes = try XCTUnwrap(f.board.pasteboardItems).map(\.types)

            f.store.clipboardDidChange()
            f.store.discard(jobID: id)
            XCTAssertTrue(f.files.fileExists(atPath: result.path))
            try f.store.shutdown()
            XCTAssertTrue(f.files.fileExists(atPath: result.path))
            XCTAssertEqual(try Data(contentsOf: result), resultBytes)
            XCTAssertTrue(promiseProvider.requests.isEmpty)
            XCTAssertTrue(ordinaryProvider.requests.isEmpty)
            XCTAssertEqual(f.board.changeCount, generation)
            XCTAssertEqual(try XCTUnwrap(f.board.pasteboardItems).map(\.types), originalTypes)

            // 정상 파일 참조는 유지하고, 읽을 수 있는 무관한 새 복사로 바뀌면 기존처럼 정리한다.
            f.put([Self.item([(.fileURL, Data(result.absoluteString.utf8))])])
            f.store.clipboardDidChange()
            XCTAssertTrue(f.files.fileExists(atPath: result.path))
            f.putText()
            let normalGeneration = f.board.changeCount
            f.store.clipboardDidChange()
            XCTAssertFalse(f.files.fileExists(atPath: result.path))
            XCTAssertEqual(f.board.changeCount, normalGeneration)
            XCTAssertEqual(try Data(contentsOf: source), originalSource)
            XCTAssertTrue(promiseProvider.requests.isEmpty)
            XCTAssertTrue(ordinaryProvider.requests.isEmpty)
        }
    }

    @MainActor
    func testCleanupTracksPublicURLFileAndDirectoryAncestorsAndUnknownPromises() throws {
        let f = try Fixture(); defer { f.close() }
        let (snapshot, id, _, output) = try f.ready(f.source())
        let result = try f.output(output)
        _ = try f.store.publish(snapshot: snapshot, jobID: id, results: [result])
        let jobDirectory = output.deletingLastPathComponent()
        for reference in [result, jobDirectory, f.root, f.sandbox] {
            f.put([Self.item([(.URL, Data(reference.absoluteString.utf8))])])
            f.store.clipboardDidChange()
            f.store.discard(jobID: id)
            XCTAssertTrue(f.files.fileExists(atPath: result.path), reference.path)
        }
        f.put([Self.item([(.init("com.apple.pasteboard.promised-file-url"), Data())])])
        f.store.clipboardDidChange()
        XCTAssertTrue(f.files.fileExists(atPath: result.path))
        f.put([Self.item([(.URL, Data("https://example.com/".utf8))])])
        f.store.clipboardDidChange()
        XCTAssertFalse(f.files.fileExists(atPath: result.path))
        XCTAssertEqual(f.board.string(forType: .URL), "https://example.com/")
    }
}

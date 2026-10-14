import AppKit
import Combine
import ConverterKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import HEICConverter

@MainActor private final class FakeWorker: WorkerConnection {
    var onEvent: ((WorkerEvent) -> Void)?
    var onFailure: ((String) -> Void)?
    var requests: [WorkerRequest] = []
    var stopped = false
    func start() throws {}
    func send(_ request: WorkerRequest) throws { requests.append(request) }
    func stop(afterExit: (() -> Void)?) { stopped = true; afterExit?() }
    func emit(_ kind: String, request: WorkerRequest, extra: [String: Any] = [:]) throws {
        var value: [String: Any] = ["protocol_version": 1, "job_id": request.jobID, "event": kind]
        extra.forEach { value[$0] = $1 }
        onEvent?(try WorkerEvent.decode(JSONSerialization.data(withJSONObject: value)))
    }
}

final class AutomaticConversionTests: XCTestCase {
    private struct Representation: Equatable {
        let type: NSPasteboard.PasteboardType
        let data: Data
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

    @MainActor private func contents(_ board: NSPasteboard) throws -> [[Representation]] {
        try XCTUnwrap(board.pasteboardItems).map { item in
            try item.types.map { Representation(type: $0, data: try XCTUnwrap(item.data(forType: $0))) }
        }
    }

    private enum MovieRepresentation: CaseIterable {
        case publicURL, fileURL, movie, quickTimeMovie, filenames
    }

    @MainActor private final class Fixture {
        let name = "heic-auto-model-test-\(UUID().uuidString)"
        let board: NSPasteboard
        let defaults: UserDefaults
        let root: URL
        let worker = FakeWorker()
        let model: AppModel
        let source: URL
        init(settings: AppSettings? = nil) throws {
            board = NSPasteboard(name: .init(name))
            defaults = UserDefaults(suiteName: name)!
            settings?.save(to: defaults)
            root = URL(fileURLWithPath: InputValidator.canonicalPath(FileManager.default.temporaryDirectory), isDirectory: true).appendingPathComponent(name)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            source = root.appendingPathComponent("원본.heic")
            try Self.image(type: .heic).write(to: source)
            model = AppModel(startClipboard: false, pasteboard: board, defaults: defaults,
                             clipboardRoot: root.appendingPathComponent("managed"), worker: worker)
        }
        static func image(type: UTType) throws -> Data {
            let data = NSMutableData()
            let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.setFillColor(CGColor(red: 0.2, green: 0.8, blue: 0.4, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            let encoder = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(encoder, context.makeImage()!, nil)
            XCTAssertTrue(CGImageDestinationFinalize(encoder))
            return data as Data
        }
        func copy(_ urls: [URL]) {
            board.clearContents(); _ = board.writeObjects(urls as [NSURL]); model.pollClipboard()
        }
        func movieItem(_ representation: MovieRepresentation) throws -> NSPasteboardItem {
            let movie = root.appendingPathComponent("합성.mov")
            // 영상 디코딩은 검증 대상이 아니다. 실제 개인 영상 대신 합성 파일만 사용한다.
            try Data("합성 MOV 원본".utf8).write(to: movie)
            let item = NSPasteboardItem()
            switch representation {
            case .publicURL:
                XCTAssertTrue(item.setString(movie.absoluteString, forType: .URL))
            case .fileURL:
                XCTAssertTrue(item.setString(movie.absoluteString, forType: .fileURL))
            case .movie:
                XCTAssertTrue(item.setData(Data("합성 movie 표현".utf8), forType: .init(UTType.movie.identifier)))
            case .quickTimeMovie:
                XCTAssertTrue(item.setData(Data("합성 QuickTime 표현".utf8), forType: .init(UTType.quickTimeMovie.identifier)))
            case .filenames:
                // legacy 타입은 NSPasteboardItem이 거절하므로 아래 named pasteboard API로 설정한다.
                break
            }
            XCTAssertTrue(item.setData(try Data(contentsOf: source), forType: .init(UTType.heic.identifier)))
            XCTAssertTrue(item.setData(Data([0, 255, 1, 128]), forType: .init("io.heic-converter.test.original")))
            return item
        }
        func prepare() throws -> WorkerRequest {
            let request = try XCTUnwrap(worker.requests.last(where: { $0.command == "prepare" }))
            try worker.emit("prepared", request: request, extra: ["files": request.files!, "rejected": [], "total": request.files!.count])
            return request
        }
        func complete(_ request: WorkerRequest, failingAt failedIndex: Int? = nil) throws {
            for (index, path) in request.files!.enumerated() {
                if index == failedIndex {
                    try worker.emit("file_failed", request: request, extra: ["source": path, "index": index+1,
                        "total": request.files!.count, "error": "합성 실패", "error_code": "conversion_error"])
                } else {
                    let output = URL(fileURLWithPath: request.outputDirectory!).appendingPathComponent("\(index).jpeg")
                    try Self.image(type: .jpeg).write(to: output)
                    try worker.emit("file_succeeded", request: request, extra: ["source": path, "destination": output.path,
                        "index": index+1, "total": request.files!.count, "hdr_applied": false])
                }
            }
            try worker.emit("completed", request: request, extra: ["succeeded": request.files!.count-(failedIndex == nil ? 0 : 1),
                "failed": failedIndex == nil ? 0 : 1, "skipped": 0, "total": request.files!.count, "remaining": []])
        }
        func close() {
            model.shutdown(); board.releaseGlobally(); defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: root)
        }
    }

    @MainActor func testMovieRepresentationsTakePrecedenceOverHEICThumbnailWithoutConversion() throws {
        for representation in MovieRepresentation.allCases {
            let f = try Fixture(); defer { f.close() }
            let movie = try f.movieItem(representation)
            f.board.clearContents()
            if representation == .filenames {
                let legacy = NSPasteboard.PasteboardType("NSFilenamesPboardType")
                f.board.declareTypes([legacy] + movie.types, owner: nil)
                XCTAssertTrue(f.board.setPropertyList([f.root.appendingPathComponent("합성.mov").path], forType: legacy))
                XCTAssertEqual(f.board.propertyList(forType: legacy) as? [String],
                               [f.root.appendingPathComponent("합성.mov").path])
                for type in movie.types {
                    XCTAssertTrue(f.board.setData(try XCTUnwrap(movie.data(forType: type)), forType: type))
                }
            } else {
                XCTAssertTrue(f.board.writeObjects([movie]))
            }
            let original = try XCTUnwrap(f.board.pasteboardItems?.first)
            let types = original.types
            let bytes = try types.map { try XCTUnwrap(original.data(forType: $0)) }
            let generation = f.board.changeCount
            var notices: [ClipboardConversionNotice] = []
            let subscription = f.model.$conversionNotice.compactMap { $0 }.sink { notices.append($0) }
            defer { subscription.cancel() }

            f.model.pollClipboard()
            f.model.pollClipboard()

            XCTAssertTrue(f.worker.requests.isEmpty, "\(representation): worker 요청이 없어야 한다")
            XCTAssertFalse(f.model.active, "\(representation)")
            XCTAssertNil(f.model.conversionNotice, "\(representation)")
            XCTAssertTrue(notices.isEmpty, "\(representation): 실패 알림도 발생하면 안 된다")
            XCTAssertEqual(f.board.changeCount, generation, "\(representation)")
            XCTAssertEqual(f.board.pasteboardItems?.count, 1, "\(representation)")
            let preserved = try XCTUnwrap(f.board.pasteboardItems?.first)
            XCTAssertEqual(preserved.types, types, "\(representation)")
            XCTAssertEqual(types.map { preserved.data(forType: $0) }, bytes.map { Optional($0) }, "\(representation)")
        }
    }

    @MainActor func testMixedHEICAndPublicURLMovieConvertsOnlyHEICAndPreservesEveryMovieRepresentation() throws {
        let f = try Fixture(); defer { f.close() }
        let heic = NSPasteboardItem()
        XCTAssertTrue(heic.setString(f.source.absoluteString, forType: .fileURL))
        let movie = try f.movieItem(.publicURL)
        f.board.clearContents(); XCTAssertTrue(f.board.writeObjects([heic, movie]))
        let original = try XCTUnwrap(f.board.pasteboardItems?.last)
        let types = original.types
        let bytes = try types.map { try XCTUnwrap(original.data(forType: $0)) }
        let generation = f.board.changeCount

        f.model.pollClipboard()
        XCTAssertEqual(f.worker.requests.filter { $0.command == "prepare" }.count, 1)
        XCTAssertEqual(f.model.conversionNotice?.heicCount, 1)
        XCTAssertEqual(f.board.changeCount, generation)
        let request = try f.prepare()
        XCTAssertEqual(request.files?.count, 1, "MOV 썸네일은 worker 입력에 포함하면 안 된다")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(request.files?.first))),
                       try Data(contentsOf: f.source))
        try f.complete(request)

        XCTAssertEqual(f.model.conversionNotice?.phase, .completed)
        XCTAssertEqual(f.model.conversionNotice?.completedCount, 1)
        XCTAssertEqual(f.model.conversionNotice?.heicCount, 1)
        XCTAssertEqual(f.board.pasteboardItems?.count, 2)
        XCTAssertNotNil(f.board.pasteboardItems?.first?.data(forType: .init(UTType.jpeg.identifier)))
        let preserved = try XCTUnwrap(f.board.pasteboardItems?.last)
        XCTAssertEqual(preserved.types, types)
        XCTAssertEqual(types.map { preserved.data(forType: $0) }, bytes.map { Optional($0) })
    }

    @MainActor func testPhotosVideoAssetReferencePreservesPosterAndHEICRawWithoutConversion() throws {
        for hasHEICRaw in [false, true] {
            let f = try Fixture(); defer { f.close() }
            let poster = f.root.appendingPathComponent("동영상 포스터.jpeg")
            let jpeg = try Fixture.image(type: .jpeg)
            try jpeg.write(to: poster)
            let item = NSPasteboardItem()
            if !hasHEICRaw {
                XCTAssertTrue(item.setString(poster.absoluteString, forType: .fileURL))
                XCTAssertTrue(item.setData(jpeg, forType: .init(UTType.jpeg.identifier)))
            }
            let assetReference = try PropertyListSerialization.data(
                fromPropertyList: ["mediaType": 2, "mediaSubtypes": 0], format: .binary, options: 0)
            XCTAssertTrue(item.setData(assetReference, forType: .init("com.apple.photos.object-reference.asset")))
            if hasHEICRaw {
                XCTAssertTrue(item.setData(try Data(contentsOf: f.source), forType: .init(UTType.heic.identifier)))
            }
            f.board.clearContents(); XCTAssertTrue(f.board.writeObjects([item]))
            let original = try XCTUnwrap(f.board.pasteboardItems?.first)
            let types = original.types
            let bytes = try types.map { try XCTUnwrap(original.data(forType: $0)) }
            let generation = f.board.changeCount
            var notices: [ClipboardConversionNotice] = []
            let subscription = f.model.$conversionNotice.compactMap { $0 }.sink { notices.append($0) }
            defer { subscription.cancel() }

            f.model.pollClipboard()
            f.model.pollClipboard()

            XCTAssertTrue(f.worker.requests.isEmpty, "HEIC raw: \(hasHEICRaw)")
            XCTAssertFalse(f.model.active)
            XCTAssertNil(f.model.conversionNotice)
            XCTAssertTrue(notices.isEmpty)
            XCTAssertEqual(f.model.clipboardFiles.count, 1)
            let display = try XCTUnwrap(f.model.clipboardFiles.first)
            XCTAssertEqual(display.status, .unsupported)
            XCTAssertNotNil(display.detail)
            let detail = display.detail ?? ""
            XCTAssertTrue(detail.contains("동영상"), detail)
            XCTAssertTrue(detail.contains("클립보드") && detail.contains("유지"), detail)
            XCTAssertEqual(f.board.changeCount, generation)
            XCTAssertEqual(f.board.pasteboardItems?.count, 1)
            let preserved = try XCTUnwrap(f.board.pasteboardItems?.first)
            XCTAssertEqual(preserved.types, types)
            XCTAssertEqual(types.map { preserved.data(forType: $0) }, bytes.map { Optional($0) })
            XCTAssertEqual(try Data(contentsOf: poster), jpeg)
        }
    }

    @MainActor func testPhotosAssetMetadataConvertsOnlyExplicitPhotoAndPreservesUncertainInput() throws {
        func asset(_ metadata: [String: Any]) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: metadata, format: .binary, options: 0)
        }
        let cases: [(name: String, data: Data, shouldPrepare: Bool)] = [
            ("사진", try asset(["mediaType": 1, "mediaSubtypes": 0]), true),
            ("mediaType 누락", try asset(["mediaSubtypes": 0]), false),
            ("알 수 없는 mediaType", try asset(["mediaType": 99]), false),
            ("Boolean mediaType", try asset(["mediaType": true]), false),
            ("손상된 메타데이터", Data([0, 255, 1, 128]), false),
        ]
        for entry in cases {
            let f = try Fixture(); defer { f.close() }
            let heic = try Data(contentsOf: f.source)
            let item = NSPasteboardItem()
            XCTAssertTrue(item.setData(heic, forType: .init(UTType.heic.identifier)))
            XCTAssertTrue(item.setData(entry.data, forType: .init("com.apple.photos.object-reference.asset")))
            f.board.clearContents(); XCTAssertTrue(f.board.writeObjects([item]))
            let original = try XCTUnwrap(f.board.pasteboardItems?.first)
            let types = original.types
            let bytes = try types.map { try XCTUnwrap(original.data(forType: $0)) }
            let generation = f.board.changeCount
            var notices: [ClipboardConversionNotice] = []
            let subscription = f.model.$conversionNotice.compactMap { $0 }.sink { notices.append($0) }
            defer { subscription.cancel() }

            f.model.pollClipboard()
            f.model.pollClipboard()

            if entry.shouldPrepare {
                XCTAssertEqual(f.worker.requests.count, 1, entry.name)
                let request = try XCTUnwrap(f.worker.requests.first)
                XCTAssertEqual(request.command, "prepare", entry.name)
                XCTAssertEqual(request.files?.count, 1, entry.name)
                let input = try XCTUnwrap(request.files?.first)
                XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: input)), heic, entry.name)
                XCTAssertEqual(f.model.clipboardFiles.count, 1, entry.name)
                XCTAssertFalse(try XCTUnwrap(f.model.clipboardFiles.first).isVideo, entry.name)
            } else {
                XCTAssertTrue(f.worker.requests.isEmpty, entry.name)
                XCTAssertFalse(f.model.active, entry.name)
                XCTAssertNil(f.model.conversionNotice, entry.name)
                XCTAssertTrue(notices.isEmpty, "\(entry.name): HEIC 오류 알림도 발생하면 안 된다")
            }
            XCTAssertEqual(f.board.changeCount, generation, entry.name)
            XCTAssertEqual(f.board.pasteboardItems?.count, 1, entry.name)
            let preserved = try XCTUnwrap(f.board.pasteboardItems?.first)
            XCTAssertEqual(preserved.types, types, entry.name)
            XCTAssertEqual(types.map { preserved.data(forType: $0) }, bytes.map { Optional($0) }, entry.name)
        }
    }

    @MainActor func testUnsafePhotosPromisePollingAndShutdownNeverRequestProviderData() throws {
        // 모델의 정리 → capture 거절 → 오류 미리보기 경로를 합성 provider로 검증한다.
        // 실제 Photos 약속 수신이나 운영체제의 클립보드 동작을 재현하지 않는다.
        let assetType = NSPasteboard.PasteboardType("com.apple.photos.object-reference.asset")
        let rawType = NSPasteboard.PasteboardType(UTType.heic.identifier)
        for unsafeType in [NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"),
                           NSPasteboard.PasteboardType("com.apple.NSFilePromiseItemMetaData")] {
            for hasHEIC in [false, true] {
                let f = try Fixture(); defer { f.close() }
                let originalSource = try Data(contentsOf: f.source)
                let libraryURL = f.root.appendingPathComponent("합성.photoslibrary/originals/원본.heic")
                let asset = try PropertyListSerialization.data(fromPropertyList: ["mediaType": 1, "mediaSubtypes": 0],
                                                               format: .binary, options: 0)
                let provider = CountingData([
                    .fileURL: Data(libraryURL.absoluteString.utf8), .URL: Data(libraryURL.absoluteString.utf8),
                    assetType: asset, rawType: originalSource, unsafeType: Data("합성 약속".utf8),
                ])
                var types: [NSPasteboard.PasteboardType] = [.fileURL, .URL, assetType]
                if hasHEIC { types.append(rawType) }
                types.append(unsafeType)
                let photos = NSPasteboardItem()
                XCTAssertTrue(photos.setDataProvider(provider, forTypes: types))
                let text = NSPasteboardItem()
                XCTAssertTrue(text.setString("앞선 텍스트 유지", forType: .string))
                f.board.clearContents(); XCTAssertTrue(f.board.writeObjects([text, photos]))
                let generation = f.board.changeCount
                let originalTypes = try XCTUnwrap(f.board.pasteboardItems).map(\.types)
                let boardTypes = f.board.types
                XCTAssertTrue(provider.requests.isEmpty)
                var notices: [ClipboardConversionNotice] = []
                let subscription = f.model.$conversionNotice.compactMap { $0 }.sink { notices.append($0) }
                defer { subscription.cancel() }

                f.model.pollClipboard()
                f.model.pollClipboard()

                XCTAssertTrue(provider.requests.isEmpty, "폴링 전체에서 URL·asset·raw·약속 provider 요청이 없어야 합니다.")
                XCTAssertTrue(f.worker.requests.isEmpty)
                XCTAssertFalse(f.model.active)
                XCTAssertEqual(f.model.clipboardFiles.count, 1)
                let display = try XCTUnwrap(f.model.clipboardFiles.first)
                XCTAssertEqual(display.name, "파일 약속 항목 2")
                XCTAssertNil(display.url)
                XCTAssertEqual(display.status, .unsupported)
                XCTAssertFalse(display.isVideo)
                XCTAssertEqual(display.detail, AutomaticClipboardError.unsupportedRepresentation.localizedDescription)
                XCTAssertTrue(f.model.message.contains("지원하지 않는 클립보드"))
                if hasHEIC {
                    let notice = try XCTUnwrap(f.model.conversionNotice)
                    XCTAssertEqual(notices.count, 1)
                    XCTAssertEqual(notice.phase, .failed)
                    XCTAssertEqual(notice.sourceChangeCount, generation)
                    XCTAssertEqual(notice.copiedFileCount, 1)
                    XCTAssertEqual(notice.heicCount, 1)
                    XCTAssertEqual(notice.completedCount, 0)
                    XCTAssertTrue(notice.detail?.hasSuffix("전체 원본을 유지했습니다.") == true)
                    XCTAssertTrue(notice.detail?.contains("클립보드 표현") == true)
                } else {
                    XCTAssertNil(f.model.conversionNotice)
                    XCTAssertTrue(notices.isEmpty)
                }
                XCTAssertEqual(f.board.changeCount, generation)
                XCTAssertEqual(f.board.types, boardTypes)
                XCTAssertEqual(try XCTUnwrap(f.board.pasteboardItems).map(\.types), originalTypes)
                XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("managed").path))

                let message = f.model.message
                f.model.shutdown()
                XCTAssertTrue(f.worker.stopped)
                XCTAssertTrue(f.worker.requests.isEmpty)
                XCTAssertTrue(provider.requests.isEmpty)
                XCTAssertEqual(f.model.clipboardFiles.first?.status, .unsupported)
                XCTAssertEqual(f.model.message, message)
                XCTAssertNil(f.model.conversionNotice)
                XCTAssertEqual(f.board.changeCount, generation)
                XCTAssertEqual(f.board.types, boardTypes)
                XCTAssertEqual(try XCTUnwrap(f.board.pasteboardItems).map(\.types), originalTypes)
                XCTAssertEqual(try Data(contentsOf: f.source), originalSource)
            }
        }
    }

    @MainActor func testPhotosLibraryVideoKeepsEntireMixedClipboardThroughShutdown() throws {
        // 합성 입력으로 자동 변경 금지 계약을 검증한다. 실제 Photos의 URL 유실이나 OS 원인을 재현하지 않는다.
        for urlType in [NSPasteboard.PasteboardType.fileURL, .URL] {
            for mediaType in [2] {
                for photosFirst in [false, true] {
                    let f = try Fixture(); defer { f.close() }
                    let raw = try Data(contentsOf: f.source)
                    let source = f.root.appendingPathComponent("합성 보관함.PhOtOsLiBrArY/originals/원본.\(mediaType == 2 ? "mov" : "heic")")
                    try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let sourceBytes = Data("합성 보관함 원본".utf8)
                    try sourceBytes.write(to: source)
                    let photos = NSPasteboardItem()
                    let escaped = source.absoluteString.replacingOccurrences(of: ".PhOtOsLiBrArY", with: ".PhOtOs%4CiBrArY")
                    XCTAssertTrue(photos.setString(escaped, forType: urlType))
                    XCTAssertTrue(photos.setData(raw, forType: .init(UTType.heic.identifier)))
                    let asset = try PropertyListSerialization.data(fromPropertyList: ["mediaType": mediaType, "mediaSubtypes": 0],
                                                                   format: .binary, options: 0)
                    XCTAssertTrue(photos.setData(asset, forType: .init("com.apple.photos.object-reference.asset")))
                    let finder = NSPasteboardItem()
                    XCTAssertTrue(finder.setString(f.source.absoluteString, forType: .fileURL))
                    let text = NSPasteboardItem()
                    XCTAssertTrue(text.setString("유지할 텍스트", forType: .string))
                    XCTAssertTrue(text.setData(Data([0, 255, 1, 128]), forType: .init("io.heic-converter.test.original")))
                    f.board.clearContents()
                    XCTAssertTrue(f.board.writeObjects(photosFirst ? [photos, text, finder] : [finder, text, photos]))
                    let original = try contents(f.board)
                    let generation = f.board.changeCount

                    f.model.pollClipboard()
                    f.model.pollClipboard()

                    XCTAssertTrue(f.worker.requests.isEmpty)
                    XCTAssertFalse(f.model.active)
                    XCTAssertEqual(f.model.clipboardFiles.count, 2)
                    XCTAssertTrue(f.model.clipboardFiles.allSatisfy { $0.status == .unsupported })
                    let display = try XCTUnwrap(photosFirst ? f.model.clipboardFiles.first : f.model.clipboardFiles.last)
                    XCTAssertNil(display.url, "보관함 원본을 썸네일에 전달하면 안 됩니다.")
                    XCTAssertEqual(display.isVideo, mediaType == 2)
                    XCTAssertTrue(f.model.message.contains("Photos 보관함 동영상의 원본을 안전하게 보존할 수 없습니다."))
                    XCTAssertEqual(f.board.changeCount, generation)
                    XCTAssertEqual(try contents(f.board), original)
                    XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("managed").path))

                    let message = f.model.message
                    f.model.shutdown()
                    f.model.pollClipboard()
                    XCTAssertTrue(f.worker.stopped)
                    XCTAssertTrue(f.worker.requests.isEmpty)
                    XCTAssertFalse(f.model.active)
                    XCTAssertTrue(f.model.clipboardFiles.allSatisfy { $0.status == .unsupported })
                    XCTAssertEqual(f.model.message, message)
                    XCTAssertEqual(f.board.changeCount, generation)
                    XCTAssertEqual(try contents(f.board), original)
                    XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
                    XCTAssertEqual(try Data(contentsOf: f.source), raw)
                }
            }
        }
    }

    @MainActor func testRawOnlyPhotosAndNonLibraryPhotosURLStillConvertAndRestoreWithFinderHEIC() throws {
        let f = try Fixture(); defer { f.close() }
        let raw = try Data(contentsOf: f.source)
        let asset = try PropertyListSerialization.data(fromPropertyList: ["mediaType": 1, "mediaSubtypes": 0],
                                                       format: .binary, options: 0)
        let photos = [nil, f.root.appendingPathComponent("합성.photoslibrary.backup/없는 원본.heic")].map { url in
            let item = NSPasteboardItem()
            if let url {
                XCTAssertTrue(item.setString(url.absoluteString, forType: .fileURL))
                XCTAssertTrue(item.setString(url.absoluteString, forType: .URL))
            }
            XCTAssertTrue(item.setData(raw, forType: .init(UTType.heic.identifier)))
            XCTAssertTrue(item.setData(asset, forType: .init("com.apple.photos.object-reference.asset")))
            return item
        }
        let finder = NSPasteboardItem()
        XCTAssertTrue(finder.setString(f.source.absoluteString, forType: .fileURL))
        f.board.clearContents(); XCTAssertTrue(f.board.writeObjects([finder] + photos))
        let original = try contents(f.board)
        let generation = f.board.changeCount
        f.model.pollClipboard()
        XCTAssertEqual(f.board.changeCount, generation)
        let request = try f.prepare()
        XCTAssertEqual(request.files?.count, 3)
        for path in try XCTUnwrap(request.files) {
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), raw)
        }
        try f.complete(request)
        XCTAssertEqual(f.model.clipboardFiles.map(\.status), [.completed, .completed, .completed])
        f.model.shutdown()
        let restored = try XCTUnwrap(f.board.pasteboardItems)
        XCTAssertEqual(restored.count, 3)
        XCTAssertEqual(try contents(f.board)[0], original[0])
        for item in restored.dropFirst() {
            XCTAssertEqual(item.data(forType: .init(UTType.heic.identifier)), raw)
            XCTAssertNil(item.data(forType: .init("com.apple.photos.object-reference.asset")))
        }
        XCTAssertNil(restored[1].string(forType: .fileURL))
        let copied = try XCTUnwrap(restored[2].string(forType: .fileURL).flatMap(URL.init(string:)))
        XCTAssertEqual(try Data(contentsOf: copied), raw)
        XCTAssertEqual(try Data(contentsOf: f.source), raw)
    }

    @MainActor func testPhotosLibraryPhotoPublishesAndRestoresOwnedOriginalWithoutTouchingLibrary() throws {
        for photosFirst in [false, true] {
            let f = try Fixture(); defer { f.close() }
            let raw = try Data(contentsOf: f.source)
            let library = f.root.appendingPathComponent("없는.photoslibrary/originals/사진.heic")
            let photo = NSPasteboardItem()
            XCTAssertTrue(photo.setString(library.absoluteString, forType: .fileURL))
            XCTAssertTrue(photo.setData(raw, forType: .init(UTType.heic.identifier)))
            let asset = try PropertyListSerialization.data(fromPropertyList: ["mediaType": 1, "mediaSubtypes": 512], format: .binary, options: 0)
            XCTAssertTrue(photo.setData(asset, forType: .init("com.apple.photos.object-reference.asset")))
            let text = NSPasteboardItem(); XCTAssertTrue(text.setString("유지할 캡션", forType: .string))
            let finder = NSPasteboardItem(); XCTAssertTrue(finder.setString(f.source.absoluteString, forType: .fileURL))
            f.board.clearContents(); XCTAssertTrue(f.board.writeObjects(photosFirst ? [photo, text, finder] : [finder, text, photo]))
            f.model.pollClipboard()
            let request = try f.prepare()
            XCTAssertEqual(request.files?.count, 2)
            try f.complete(request)
            XCTAssertTrue(f.model.clipboardFiles.allSatisfy { $0.status == .completed })
            XCTAssertEqual(f.model.conversionNotice?.phase, .completed)
            let published = try XCTUnwrap(f.board.pasteboardItems)
            let photoIndex = photosFirst ? 0 : 2
            XCTAssertNil(published[photoIndex].data(forType: .init("com.apple.photos.object-reference.asset")))
            XCTAssertNotNil(published[photoIndex].data(forType: .init(UTType.jpeg.identifier)))
            XCTAssertEqual(published[1].string(forType: .string), "유지할 캡션")
            f.model.shutdown()
            let restored = try XCTUnwrap(f.board.pasteboardItems)
            let owned = try XCTUnwrap(restored[photoIndex].string(forType: .fileURL).flatMap(URL.init(string:)))
            XCTAssertNotEqual(owned, library)
            XCTAssertEqual(try Data(contentsOf: owned), raw)
            XCTAssertEqual(restored[photoIndex].data(forType: .init(UTType.heic.identifier)), raw)
            XCTAssertEqual(restored[1].string(forType: .string), "유지할 캡션")
            XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))
        }
    }

    @MainActor func testAllSuccessPublishesFileAndImageThenRestoresOriginalOnShutdown() throws {
        let f = try Fixture(); defer { f.close() }
        let original = try Data(contentsOf: f.source)
        f.copy([f.source]); let request = try f.prepare(); try f.complete(request)
        XCTAssertFalse(f.model.active)
        XCTAssertEqual(f.model.clipboardFiles.first?.status, .completed)
        let item = try XCTUnwrap(f.board.pasteboardItems?.first)
        let result = try XCTUnwrap(item.string(forType: .fileURL).flatMap(URL.init(string:)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
        XCTAssertNotNil(item.data(forType: .init(UTType.jpeg.identifier)))
        f.model.shutdown()
        XCTAssertEqual(f.board.pasteboardItems?.first?.string(forType: .fileURL), f.source.absoluteString)
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.path))
        XCTAssertEqual(try Data(contentsOf: f.source), original)
    }

    @MainActor func testAnyFailurePreservesEntireClipboard() throws {
        let f = try Fixture(); defer { f.close() }
        let second = f.root.appendingPathComponent("둘째.heic")
        try Data(contentsOf: f.source).write(to: second)
        f.copy([f.source, second]); let count = f.board.changeCount
        let request = try f.prepare(); try f.complete(request, failingAt: 1)
        XCTAssertEqual(f.board.changeCount, count)
        XCTAssertEqual(f.model.clipboardFiles.map(\.status), [.failed, .failed])
        XCTAssertFalse(f.model.active)
    }

    @MainActor func testCopyImmediatelyBeforePublishNeverOverwritesNewText() throws {
        let f = try Fixture(); defer { f.close() }
        f.copy([f.source]); let request = try f.prepare()
        f.board.clearContents(); f.board.setString("새 복사", forType: .string)
        try f.complete(request)
        XCTAssertEqual(f.board.string(forType: .string), "새 복사")
        XCTAssertTrue(f.model.clipboardFiles.isEmpty)
    }

    @MainActor func testRapidCopiesShowOnlyCurrentGenerationAndStartAfterCancellation() throws {
        let f = try Fixture(); defer { f.close() }
        f.copy([f.source]); let first = try f.prepare()
        let second = f.root.appendingPathComponent("현재.heic")
        try Data(contentsOf: f.source).write(to: second)
        f.copy([second])
        XCTAssertEqual(f.model.clipboardFiles.map(\.name), [second.lastPathComponent])
        XCTAssertEqual(f.worker.requests.last?.command, "cancel")
        try f.complete(first)
        let next = try f.prepare(); XCTAssertNotEqual(first.jobID, next.jobID)
        try f.complete(next)
        XCTAssertEqual(f.model.clipboardFiles.first?.status, .completed)
    }

    @MainActor func testDisableWhilePreparingCancelsAndNeverPublishes() throws {
        let f = try Fixture(); defer { f.close() }
        f.copy([f.source]); let count = f.board.changeCount
        f.model.setClipboard(false); let request = try f.prepare()
        XCTAssertEqual(f.worker.requests.last?.command, "cancel")
        try f.complete(request)
        XCTAssertEqual(f.board.changeCount, count)
        XCTAssertEqual(f.model.clipboardFiles.first?.status, .ready)
    }

    @MainActor func testDisableWhileRunningSurvivesCompletedResponse() throws {
        let f = try Fixture(); defer { f.close() }
        f.copy([f.source]); let request = try f.prepare(); let count = f.board.changeCount
        f.model.setClipboard(false); try f.complete(request)
        XCTAssertEqual(f.board.changeCount, count)
        XCTAssertEqual(f.worker.requests.last?.command, "cancel")
    }

    @MainActor func testOwnPublicationIsNotConvertedAgainEvenAfterToggle() throws {
        let f = try Fixture(); defer { f.close() }
        f.copy([f.source]); let request = try f.prepare(); try f.complete(request)
        let count = f.worker.requests.count
        let generation = f.board.changeCount
        let result = try XCTUnwrap(f.model.clipboardFiles.first?.url)
        let resultData = try Data(contentsOf: result)
        let completionMessage = f.model.message
        f.model.pollClipboard(); f.model.setClipboard(false)
        XCTAssertFalse(f.model.clipboardEnabled)
        XCTAssertEqual(f.board.changeCount, generation)
        XCTAssertEqual(f.model.clipboardFiles.first?.status, .completed)
        XCTAssertEqual(f.model.clipboardFiles.first?.url, result)
        XCTAssertEqual(try Data(contentsOf: result), resultData)
        f.model.setClipboard(true)
        XCTAssertEqual(f.worker.requests.count, count)
        XCTAssertEqual(f.model.clipboardFiles.first?.status, .completed)
        XCTAssertEqual(f.model.message, completionMessage)
    }

    @MainActor func testPauseDoesNotPersistAndResumeProcessesCurrentHEIC() throws {
        let f = try Fixture(); defer { f.close() }
        f.model.settings.options.jpegQuality = 75
        let savedData = try XCTUnwrap(f.defaults.data(forKey: "converter.settings"))
        f.model.setClipboard(false); f.copy([f.source])
        XCTAssertFalse(f.model.clipboardEnabled)
        XCTAssertTrue(f.worker.requests.isEmpty)
        XCTAssertEqual(f.model.clipboardFiles.first?.status, .ready)
        XCTAssertEqual(f.defaults.data(forKey: "converter.settings"), savedData)
        XCTAssertTrue(AppSettings.load(from: f.defaults).clipboardEnabled)
        f.model.setClipboard(true)
        XCTAssertTrue(f.model.clipboardEnabled)
        XCTAssertEqual(f.worker.requests.last?.command, "prepare")
        XCTAssertEqual(f.defaults.data(forKey: "converter.settings"), savedData)
    }

    @MainActor func testLegacyDisabledSettingIsIgnoredAndConversionOptionsArePreserved() throws {
        var legacy = AppSettings()
        legacy.clipboardEnabled = false
        legacy.options.jpegQuality = 75
        legacy.options.pngCompression = 4
        legacy.options.metadata = "preserve"
        let f = try Fixture(settings: legacy); defer { f.close() }
        let savedData = try XCTUnwrap(f.defaults.data(forKey: "converter.settings"))

        XCTAssertTrue(f.model.clipboardEnabled)
        XCTAssertFalse(f.model.settings.clipboardEnabled)
        XCTAssertEqual(f.model.settings.options, legacy.options)
        f.copy([f.source])
        let request = try f.prepare()
        XCTAssertEqual(request.options, legacy.options)
        XCTAssertEqual(f.worker.requests.last?.command, "run")
        XCTAssertEqual(f.defaults.data(forKey: "converter.settings"), savedData)

        f.model.setClipboard(false)
        XCTAssertFalse(f.model.clipboardEnabled)
        XCTAssertEqual(f.worker.requests.last?.command, "cancel")
        XCTAssertEqual(f.defaults.data(forKey: "converter.settings"), savedData)
        f.model.settings.options.jpegQuality = 80
        var expected = legacy
        expected.options.jpegQuality = 80
        XCTAssertEqual(AppSettings.load(from: f.defaults), expected)
        let updatedData = try XCTUnwrap(f.defaults.data(forKey: "converter.settings"))
        XCTAssertNotEqual(updatedData, savedData)
        f.model.setClipboard(true)
        XCTAssertTrue(f.model.clipboardEnabled)
        XCTAssertEqual(f.defaults.data(forKey: "converter.settings"), updatedData)
    }

    @MainActor func testResetConversionOptionsPreservesLegacyFieldsAndPausedExecution() throws {
        for conflict in ["overwrite", "skip"] {
            var legacy = AppSettings()
            legacy.clipboardEnabled = false
            legacy.outputDirectory = "/tmp/heic-legacy-output"
            legacy.options.outputFormat = "png"
            legacy.options.jpegQuality = 75
            legacy.options.pngCompression = 3
            legacy.options.metadata = "preserve"
            legacy.options.onConflict = conflict
            let f = try Fixture(settings: legacy); defer { f.close() }
            f.model.setClipboard(false)
            let generation = f.board.changeCount

            f.model.resetConversionOptions()

            var expected = legacy
            expected.options = ConversionOptions()
            expected.options.onConflict = conflict
            XCTAssertEqual(f.model.settings, expected)
            XCTAssertEqual(AppSettings.load(from: f.defaults), expected)
            XCTAssertFalse(f.model.clipboardEnabled)
            XCTAssertEqual(f.board.changeCount, generation)
            XCTAssertTrue(f.worker.requests.isEmpty)
        }
    }

    @MainActor func testNewModelStartsEnabledAfterPreviousExecutionWasPaused() throws {
        let f = try Fixture(); defer { f.close() }
        f.model.settings.options.jpegQuality = 75
        f.model.settings.options.metadata = "preserve"
        let options = f.model.settings.options
        let savedData = try XCTUnwrap(f.defaults.data(forKey: "converter.settings"))
        f.model.setClipboard(false)
        f.copy([f.source])
        let generation = f.board.changeCount
        XCTAssertFalse(f.model.clipboardEnabled)
        XCTAssertTrue(f.worker.requests.isEmpty)
        f.model.shutdown()
        XCTAssertTrue(f.worker.stopped)

        let nextWorker = FakeWorker()
        let nextModel = AppModel(pasteboard: f.board, defaults: f.defaults,
                                 clipboardRoot: f.root.appendingPathComponent("managed"), worker: nextWorker)
        defer { nextModel.shutdown() }
        XCTAssertTrue(nextModel.clipboardEnabled)
        XCTAssertEqual(nextModel.settings.options, options)
        XCTAssertEqual(f.defaults.data(forKey: "converter.settings"), savedData)
        XCTAssertEqual(f.board.changeCount, generation)
        XCTAssertTrue(nextModel.active)
        let request = try XCTUnwrap(nextWorker.requests.last)
        XCTAssertEqual(request.command, "prepare")
        XCTAssertEqual(request.files?.count, 1)
        let stagedInput = try XCTUnwrap(request.files?.first)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: stagedInput)), try Data(contentsOf: f.source))
        XCTAssertEqual(request.options, options)
        try nextWorker.emit("prepared", request: request,
                            extra: ["files": request.files!, "rejected": [], "total": request.files!.count])
        XCTAssertEqual(nextWorker.requests.last?.command, "run")
    }

    @MainActor func testPreparationRejectionDoesNotRunOrPublish() throws {
        let f = try Fixture(); defer { f.close() }
        f.copy([f.source]); let count = f.board.changeCount
        let request = try XCTUnwrap(f.worker.requests.last)
        try f.worker.emit("prepared", request: request, extra: ["files": [], "total": 0,
            "rejected": [["source": request.files![0], "reason": "테스트 거절"]]])
        XCTAssertEqual(f.worker.requests.last?.command, "cancel")
        try f.worker.emit("cancelled", request: request, extra: ["succeeded": 0, "failed": 0,
            "skipped": 0, "total": 0, "remaining": []])
        XCTAssertEqual(f.board.changeCount, count)
        XCTAssertEqual(f.model.clipboardFiles.first?.status, .failed)
    }

    @MainActor func testShutdownDoesNotRestoreOverNewExternalCopy() throws {
        let f = try Fixture(); defer { f.close() }
        f.copy([f.source]); let request = try f.prepare(); try f.complete(request)
        f.board.clearContents(); f.board.setString("사용자 새 내용", forType: .string)
        f.model.shutdown()
        XCTAssertEqual(f.board.string(forType: .string), "사용자 새 내용")
        XCTAssertTrue(f.worker.stopped)
    }

    @MainActor func testRawHEICCancellationResetsPreviewAndReenableUsesNewInput() throws {
        let f = try Fixture(); defer { f.close() }
        let item = NSPasteboardItem()
        item.setData(try Data(contentsOf: f.source), forType: .init(UTType.heic.identifier))
        f.board.clearContents(); XCTAssertTrue(f.board.writeObjects([item])); f.model.pollClipboard()
        let first = try f.prepare()
        let oldPreview = try XCTUnwrap(f.model.clipboardFiles.first?.url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldPreview.path))
        f.model.setClipboard(false); try f.complete(first)
        XCTAssertNil(f.model.clipboardFiles.first?.url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldPreview.path))
        f.model.setClipboard(true)
        let next = try f.prepare()
        XCTAssertNotEqual(f.model.clipboardFiles.first?.url, oldPreview)
        XCTAssertNotEqual(first.jobID, next.jobID)
        try f.complete(next)
        XCTAssertEqual(f.model.clipboardFiles.first?.status, .completed)
    }

    @MainActor func testNoticeCountsOnlyHEICAndReportsSuccessAfterPublication() throws {
        let f = try Fixture(); defer { f.close() }
        let second = f.root.appendingPathComponent("두 번째.heic")
        let document = f.root.appendingPathComponent("보존.txt")
        try Data(contentsOf: f.source).write(to: second)
        try Data("문서".utf8).write(to: document)
        var notices: [ClipboardConversionNotice] = []
        var publicationWasReady = false
        let subscription = f.model.$conversionNotice.compactMap { $0 }.sink { notice in
            notices.append(notice)
            if notice.phase == .completed {
                publicationWasReady = f.board.pasteboardItems?.first?.data(forType: .init(UTType.jpeg.identifier)) != nil
            }
        }
        defer { subscription.cancel() }
        f.copy([f.source, document, second])
        let initial = try XCTUnwrap(f.model.conversionNotice)
        XCTAssertEqual(initial.phase, .preparing)
        XCTAssertEqual(initial.heicCount, 2)
        XCTAssertEqual(initial.copiedFileCount, 3)
        let request = try f.prepare()
        XCTAssertEqual(f.model.conversionNotice?.phase, .converting)
        try f.complete(request)
        XCTAssertEqual(f.model.conversionNotice?.phase, .completed)
        XCTAssertEqual(f.model.conversionNotice?.completedCount, 2)
        XCTAssertTrue(publicationWasReady)
        XCTAssertTrue(notices.allSatisfy { $0.id == initial.id })
        XCTAssertTrue(notices.contains { $0.phase == .converting && $0.completedCount == 1 })
        f.model.pollClipboard()
        XCTAssertEqual(f.model.conversionNotice?.phase, .completed)
    }

    @MainActor func testPartialFailureNeverProducesSuccessNotice() throws {
        let f = try Fixture(); defer { f.close() }
        let second = f.root.appendingPathComponent("실패.heic")
        try Data(contentsOf: f.source).write(to: second)
        var phases: [ClipboardConversionNotice.Phase] = []
        let subscription = f.model.$conversionNotice.compactMap { $0?.phase }.sink { phases.append($0) }
        defer { subscription.cancel() }
        f.copy([f.source, second]); let originalCount = f.board.changeCount
        let request = try f.prepare(); try f.complete(request, failingAt: 1)
        XCTAssertEqual(f.model.conversionNotice?.phase, .failed)
        XCTAssertEqual(f.model.conversionNotice?.heicCount, 2)
        XCTAssertEqual(f.model.conversionNotice?.completedCount, 0)
        XCTAssertFalse(phases.contains(.completed))
        XCTAssertEqual(f.board.changeCount, originalCount)
    }

    @MainActor func testNewCopySuppressesLateNoticeAndPreservesNewAttemptID() throws {
        let f = try Fixture(); defer { f.close() }
        f.copy([f.source]); let first = try f.prepare()
        let previousID = try XCTUnwrap(f.model.conversionNotice?.id)
        let second = f.root.appendingPathComponent("새 복사.heic")
        try Data(contentsOf: f.source).write(to: second)
        f.copy([second, f.source])
        let currentID = try XCTUnwrap(f.model.conversionNotice?.id)
        XCTAssertNotEqual(currentID, previousID)
        try f.complete(first)
        XCTAssertEqual(f.model.conversionNotice?.id, currentID)
        XCTAssertEqual(f.model.conversionNotice?.heicCount, 2)
        XCTAssertEqual(f.model.conversionNotice?.phase, .preparing)
        let next = try f.prepare(); try f.complete(next)
        XCTAssertEqual(f.model.conversionNotice?.id, currentID)
        XCTAssertEqual(f.model.conversionNotice?.phase, .completed)
    }

    @MainActor func testDisableOrNonHEICCopyClearsNoticeAndLateCompletionCannotRestoreIt() throws {
        let f = try Fixture(); defer { f.close() }
        f.copy([f.source]); let first = try f.prepare()
        f.model.setClipboard(false)
        XCTAssertNil(f.model.conversionNotice)
        try f.complete(first)
        XCTAssertNil(f.model.conversionNotice)
        f.model.setClipboard(true); let next = try f.prepare()
        f.board.clearContents(); f.board.setString("일반 텍스트", forType: .string)
        try f.complete(next)
        XCTAssertNil(f.model.conversionNotice)
        XCTAssertEqual(f.board.string(forType: .string), "일반 텍스트")
    }

    @MainActor func testWorkerFailureShowsFailureAndShutdownClearsNotice() throws {
        let f = try Fixture(); defer { f.close() }
        f.copy([f.source]); _ = try f.prepare()
        f.worker.onFailure?("합성 worker 장애")
        XCTAssertEqual(f.model.conversionNotice?.phase, .failed)
        f.model.shutdown()
        XCTAssertNil(f.model.conversionNotice)
    }

    @MainActor func testUnreadableHEICShowsFailureNoticeWithoutStartingWorkerOrChangingClipboard() throws {
        let f = try Fixture(); defer { f.close() }
        let corrupt = f.root.appendingPathComponent("손상.heic")
        try Data([1, 2, 3]).write(to: corrupt)
        f.copy([f.source, corrupt])
        let count = f.board.changeCount
        XCTAssertTrue(f.worker.requests.isEmpty)
        XCTAssertEqual(f.model.conversionNotice?.phase, .failed)
        XCTAssertEqual(f.model.conversionNotice?.heicCount, 2)
        XCTAssertEqual(f.model.conversionNotice?.completedCount, 0)
        f.model.pollClipboard()
        XCTAssertEqual(f.board.changeCount, count)
        XCTAssertEqual(f.board.pasteboardItems?.last?.string(forType: .fileURL), corrupt.absoluteString)
    }
}

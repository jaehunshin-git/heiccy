import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import ConverterKit

final class ClipboardResultStoreTests: XCTestCase {
    private let files = FileManager()
    private let jpegType = NSPasteboard.PasteboardType(UTType.jpeg.identifier)

    /// 시간 지연 없이 대상 작업 폴더 삭제 중 외부 복사를 재현한다.
    private final class ClipboardChangeOnRemoval: NSObject, FileManagerDelegate {
        private let directoryPath: String
        private let changeClipboard: @MainActor () -> Void
        private(set) var fired = false

        init(directory: URL, changeClipboard: @escaping @MainActor () -> Void) {
            self.directoryPath = InputValidator.canonicalPath(directory)
            self.changeClipboard = changeClipboard
            super.init()
        }

        private func willRemove(_ path: String) -> Bool {
            let removalPath = InputValidator.canonicalPath(URL(fileURLWithPath: path))
            if !fired, removalPath == directoryPath || removalPath.hasPrefix(directoryPath + "/") {
                fired = true
                // publish의 동기 삭제는 테스트의 MainActor에서 실행된다.
                MainActor.assumeIsolated { changeClipboard() }
            }
            return true
        }

        func fileManager(_ fileManager: FileManager, shouldRemoveItemAt URL: URL) -> Bool {
            willRemove(URL.path)
        }

        func fileManager(_ fileManager: FileManager, shouldRemoveItemAtPath path: String) -> Bool {
            willRemove(path)
        }
    }

    @MainActor
    private func withStore(_ body: @MainActor (ClipboardResultStore, NSPasteboard, URL, URL) throws -> Void) throws {
        let temporary = URL(fileURLWithPath: InputValidator.canonicalPath(files.temporaryDirectory), isDirectory: true)
        let proposedSandbox = temporary
            .appendingPathComponent("ClipboardResultStoreTests-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: proposedSandbox, withIntermediateDirectories: false)
        // 존재하는 sandbox도 다시 realpath로 확인한 후 root의 기반으로 사용한다.
        let sandbox = URL(fileURLWithPath: InputValidator.canonicalPath(proposedSandbox), isDirectory: true)
        let root = sandbox.appendingPathComponent("결과 임시 폴더", isDirectory: true)
        let board = NSPasteboard(name: NSPasteboard.Name("ClipboardResultStoreTests-\(UUID().uuidString)"))
        let store = ClipboardResultStore(pasteboard: board, root: root, fileManager: files)
        defer {
            store.shutdown()
            board.releaseGlobally()
            try? files.removeItem(at: sandbox)
        }
        XCTAssertEqual(sandbox.path, InputValidator.canonicalPath(sandbox))
        try body(store, board, root, sandbox)
    }

    /// 압축된 실제 이미지 데이터로 검증하며 확장자나 가짜 헤더에 의존하지 않는다.
    private func imageBytes(type: UTType) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 12, bitsPerComponent: 8,
            bytesPerRow: 16 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 12))
        context.setFillColor(CGColor(red: 0.8, green: 0.1, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 2, y: 2, width: 6, height: 4))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    @MainActor
    private func putText(_ text: String, on board: NSPasteboard) {
        board.clearContents()
        XCTAssertTrue(board.setString(text, forType: .string))
    }

    @MainActor
    private func assertPreserved(_ board: NSPasteboard, text: String, changeCount: Int,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(board.changeCount, changeCount, file: file, line: line)
        XCTAssertEqual(board.string(forType: .string), text, file: file, line: line)
    }

    @MainActor
    func testDefaultTemporaryRootUsesCanonicalParentForPublicationAndCleanup() throws {
        try withStore { _, board, _, _ in
            putText("기본 임시 경로 확인", on: board)
            let expected = board.changeCount
            let store = ClipboardResultStore(pasteboard: board, fileManager: files)
            let id = UUID().uuidString
            defer { store.discard(jobID: id); store.shutdown() }
            let directory = try store.prepareDirectory(jobID: id)
            let canonicalTemporary = URL(fileURLWithPath:
                InputValidator.canonicalPath(files.temporaryDirectory), isDirectory: true)
            XCTAssertEqual(directory.path, InputValidator.canonicalPath(directory))
            XCTAssertEqual(Array(directory.pathComponents.prefix(canonicalTemporary.pathComponents.count)),
                           canonicalTemporary.pathComponents)
            XCTAssertEqual(directory.lastPathComponent, id)
            XCTAssertNotNil(UUID(uuidString: directory.deletingLastPathComponent().lastPathComponent))
            assertPreserved(board, text: "기본 임시 경로 확인", changeCount: expected)
            let png = try imageBytes(type: .png)
            let url = directory.appendingPathComponent("기본 임시 경로 이미지.png")
            try png.write(to: url)
            let ownChangeCount = try store.publish(jobID: id, urls: [url], expectedChangeCount: expected)
            XCTAssertEqual(ownChangeCount, expected &+ 1)
            XCTAssertEqual(board.changeCount, ownChangeCount)
            XCTAssertEqual(board.data(forType: .png), png)
            XCTAssertFalse(files.fileExists(atPath: directory.path))
        }
    }

    @MainActor
    func testMixedImagesKeepOriginalBytesAndTIFFWithoutFileURLsAndDeleteOnlyTheirJob() throws {
        try withStore { store, board, _, _ in
            putText("기존 텍스트", on: board)
            let expected = board.changeCount
            let id = UUID().uuidString
            let directory = try store.prepareDirectory(jobID: id)
            let png = try imageBytes(type: .png)
            let jpeg = try imageBytes(type: .jpeg)
            let pngURL = directory.appendingPathComponent("한글 사진 하나.png")
            let jpegURL = directory.appendingPathComponent("한글 사진 둘 공백.jpeg")
            try png.write(to: pngURL)
            try jpeg.write(to: jpegURL)
            let pendingID = UUID().uuidString
            let pending = try store.prepareDirectory(jobID: pendingID)
            let pendingFile = pending.appendingPathComponent("아직 저장 중.png")
            try png.write(to: pendingFile)

            let ownChangeCount = try store.publish(jobID: id, urls: [pngURL, jpegURL], expectedChangeCount: expected)

            XCTAssertEqual(ownChangeCount, expected &+ 1)
            XCTAssertEqual(board.changeCount, ownChangeCount)
            XCTAssertNotEqual(board.changeCount, expected)
            XCTAssertFalse(files.fileExists(atPath: directory.path))
            XCTAssertEqual(try Data(contentsOf: pendingFile), png)
            let items = try XCTUnwrap(board.pasteboardItems)
            XCTAssertEqual(items.count, 2)
            XCTAssertEqual(items[0].data(forType: .png), png)
            XCTAssertEqual(items[1].data(forType: jpegType), jpeg)
            XCTAssertNil(items[0].data(forType: jpegType))
            XCTAssertNil(items[1].data(forType: .png))
            for item in items {
                XCTAssertFalse(item.types.contains(.fileURL))
                XCTAssertNil(item.data(forType: .fileURL))
                let tiff = try XCTUnwrap(item.data(forType: .tiff))
                XCTAssertTrue(try XCTUnwrap(NSImage(data: tiff)).isValid)
                XCTAssertEqual(Set(item.types).subtracting([.png, jpegType, .tiff]), [])
            }
            let images = try XCTUnwrap(board.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage])
            XCTAssertEqual(images.count, 2)
            XCTAssertTrue(images.allSatisfy(\.isValid))
            let fileURLs = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ?? []
            XCTAssertTrue(fileURLs.isEmpty)

            store.shutdown()
            // 앱 종료 후에도 서버가 가진 원문 데이터와 TIFF를 읽을 수 있다.
            let retained = try XCTUnwrap(board.pasteboardItems)
            XCTAssertEqual(retained[0].data(forType: .png), png)
            XCTAssertEqual(retained[1].data(forType: jpegType), jpeg)
            let retainedTIFF = try XCTUnwrap(retained[0].data(forType: .tiff))
            XCTAssertTrue(try XCTUnwrap(NSImage(data: retainedTIFF)).isValid)
            XCTAssertTrue(files.fileExists(atPath: pending.path))
        }
    }

    @MainActor
    func testImageTypeComesFromOriginalDataRatherThanFilename() throws {
        try withStore { store, board, _, _ in
            let id = UUID().uuidString
            let directory = try store.prepareDirectory(jobID: id)
            let png = try imageBytes(type: .png)
            let jpeg = try imageBytes(type: .jpeg)
            let mislabeledPNG = directory.appendingPathComponent("PNG인데 확장자는.jpeg")
            let mislabeledJPEG = directory.appendingPathComponent("JPEG인데 확장자는.png")
            try png.write(to: mislabeledPNG)
            try jpeg.write(to: mislabeledJPEG)
            let ownChangeCount = try store.publish(jobID: id, urls: [mislabeledPNG, mislabeledJPEG], expectedChangeCount: board.changeCount)
            XCTAssertEqual(board.changeCount, ownChangeCount)
            let items = try XCTUnwrap(board.pasteboardItems)
            XCTAssertEqual(items.count, 2)
            XCTAssertEqual(items[0].data(forType: .png), png)
            XCTAssertEqual(items[1].data(forType: jpegType), jpeg)
        }
    }

    @MainActor
    func testReturnedGenerationExcludesExternalCopyDuringDiscardAndProtectsNextJob() throws {
        try withStore { store, board, _, _ in
            putText("복사 요청 시점", on: board)
            let expected = board.changeCount
            let id = UUID().uuidString
            let directory = try store.prepareDirectory(jobID: id)
            let png = try imageBytes(type: .png)
            let url = directory.appendingPathComponent("현재 이미지.png")
            try png.write(to: url)
            let nextID = UUID().uuidString
            let nextDirectory = try store.prepareDirectory(jobID: nextID)
            let nextURL = nextDirectory.appendingPathComponent("예약된 이미지.png")
            try png.write(to: nextURL)

            let observer = ClipboardChangeOnRemoval(directory: directory) {
                self.putText("정리 중 다른 앱에서 복사", on: board)
            }
            let previousDelegate = files.delegate
            files.delegate = observer
            defer { files.delegate = previousDelegate }

            let ownChangeCount = try store.publish(jobID: id, urls: [url], expectedChangeCount: expected)

            XCTAssertTrue(observer.fired, "작업 폴더 삭제 중 외부 복사가 재현되어야 합니다.")
            XCTAssertFalse(files.fileExists(atPath: directory.path))
            XCTAssertEqual(ownChangeCount, expected &+ 1)
            let externalCount = board.changeCount
            XCTAssertNotEqual(externalCount, ownChangeCount)
            assertPreserved(board, text: "정리 중 다른 앱에서 복사", changeCount: externalCount)
            // 다음 예약은 앱 자신의 게시 세대로만 갱신하므로 외부 내용을 덮어쓰지 않는다.
            XCTAssertThrowsError(try store.publish(jobID: nextID, urls: [nextURL], expectedChangeCount: ownChangeCount)) {
                XCTAssertEqual($0.localizedDescription,
                    "변환 중 클립보드가 변경되어 결과를 복사하지 않았습니다. 현재 클립보드 내용은 유지됩니다.")
            }
            assertPreserved(board, text: "정리 중 다른 앱에서 복사", changeCount: externalCount)
            XCTAssertEqual(try Data(contentsOf: nextURL), png)
        }
    }

    @MainActor
    func testExternalClipboardChangeDuringConversionIsPreserved() throws {
        try withStore { store, board, _, _ in
            putText("변환 시작 전", on: board)
            let expected = board.changeCount
            let id = UUID().uuidString
            let directory = try store.prepareDirectory(jobID: id)
            let url = directory.appendingPathComponent("결과.png")
            try imageBytes(type: .png).write(to: url)
            putText("다른 앱에서 새로 복사", on: board)
            let externalCount = board.changeCount
            XCTAssertThrowsError(try store.publish(jobID: id, urls: [url], expectedChangeCount: expected)) {
                XCTAssertEqual($0.localizedDescription,
                    "변환 중 클립보드가 변경되어 결과를 복사하지 않았습니다. 현재 클립보드 내용은 유지됩니다.")
            }
            assertPreserved(board, text: "다른 앱에서 새로 복사", changeCount: externalCount)
            XCTAssertTrue(files.fileExists(atPath: url.path))
            store.discard(jobID: id)
            XCTAssertFalse(files.fileExists(atPath: directory.path))
            assertPreserved(board, text: "다른 앱에서 새로 복사", changeCount: externalCount)
        }
    }

    @MainActor
    func testEmptyResultsPreserveClipboardAndWaitForExplicitDiscard() throws {
        try withStore { store, board, _, _ in
            putText("복사할 결과가 없어도 유지", on: board)
            let expected = board.changeCount
            let id = UUID().uuidString
            let directory = try store.prepareDirectory(jobID: id)
            XCTAssertThrowsError(try store.publish(jobID: id, urls: [], expectedChangeCount: expected)) {
                XCTAssertEqual($0.localizedDescription, "클립보드에 복사할 변환 결과가 없습니다.")
            }
            assertPreserved(board, text: "복사할 결과가 없어도 유지", changeCount: expected)
            XCTAssertTrue(files.fileExists(atPath: directory.path))
            store.discard(jobID: id)
            XCTAssertFalse(files.fileExists(atPath: directory.path))
        }
    }

    @MainActor
    func testCorruptAndUnsupportedImagesRejectEntireBatchBeforeClearingClipboard() throws {
        try withStore { store, board, _, _ in
            putText("검증 실패 전 내용", on: board)
            let expected = board.changeCount
            let id = UUID().uuidString
            let directory = try store.prepareDirectory(jobID: id)
            let png = try imageBytes(type: .png)
            let valid = directory.appendingPathComponent("정상.png")
            let invalid = directory.appendingPathComponent("손상.png")
            try png.write(to: valid)
            let failures = [Data(), Data("이미지가 아닌 텍스트".utf8), Data(png.prefix(24)),
                            try imageBytes(type: .tiff)]
            for bytes in failures {
                try bytes.write(to: invalid)
                XCTAssertThrowsError(try store.publish(jobID: id, urls: [valid, invalid], expectedChangeCount: expected)) {
                    XCTAssertEqual($0.localizedDescription,
                        "변환 결과가 올바른 PNG 또는 JPEG 이미지가 아닙니다. 기존 클립보드 내용은 유지됩니다.")
                }
                assertPreserved(board, text: "검증 실패 전 내용", changeCount: expected)
                XCTAssertTrue(files.fileExists(atPath: valid.path))
            }
        }
    }

    @MainActor
    func testRejectedCopyPreservesPreviouslyPublishedImageBytes() throws {
        try withStore { store, board, _, _ in
            let firstID = UUID().uuidString
            let firstDirectory = try store.prepareDirectory(jobID: firstID)
            let original = try imageBytes(type: .png)
            let firstURL = firstDirectory.appendingPathComponent("앞서 복사한 이미지.png")
            try original.write(to: firstURL)
            let expected = try store.publish(jobID: firstID, urls: [firstURL], expectedChangeCount: board.changeCount)
            let id = UUID().uuidString
            let directory = try store.prepareDirectory(jobID: id)
            let corrupt = directory.appendingPathComponent("손상된 다음 이미지.jpeg")
            try Data("JPEG가 아닌 데이터".utf8).write(to: corrupt)
            for urls in [[URL](), [corrupt]] {
                XCTAssertThrowsError(try store.publish(jobID: id, urls: urls, expectedChangeCount: expected))
                XCTAssertEqual(board.changeCount, expected)
                let retained = try XCTUnwrap(board.pasteboardItems)
                XCTAssertEqual(retained.count, 1)
                XCTAssertEqual(retained[0].data(forType: .png), original)
                let retainedTIFF = try XCTUnwrap(retained[0].data(forType: .tiff))
                XCTAssertTrue(try XCTUnwrap(NSImage(data: retainedTIFF)).isValid)
            }
            XCTAssertTrue(files.fileExists(atPath: corrupt.path))
        }
    }

    @MainActor
    func testInvalidPathsAndSymlinksPreserveClipboardAndExternalFiles() throws {
        try withStore { store, board, root, sandbox in
            putText("경로 검증 전 내용", on: board)
            let expected = board.changeCount
            let id = UUID().uuidString
            let directory = try store.prepareDirectory(jobID: id)
            let png = try imageBytes(type: .png)
            let valid = directory.appendingPathComponent("정상.png")
            try png.write(to: valid)
            let outside = sandbox.appendingPathComponent("외부.png")
            try png.write(to: outside)
            let sibling = root.appendingPathComponent(id + "-other", isDirectory: true)
            try files.createDirectory(at: sibling, withIntermediateDirectories: false)
            let siblingFile = sibling.appendingPathComponent("비슷한 접두사.png")
            try png.write(to: siblingFile)
            let otherJob = try store.prepareDirectory(jobID: UUID().uuidString)
            let otherFile = otherJob.appendingPathComponent("다른 작업.png")
            try png.write(to: otherFile)
            let link = directory.appendingPathComponent("외부 링크.png")
            try files.createSymbolicLink(at: link, withDestinationURL: outside)
            let insideLink = directory.appendingPathComponent("내부 링크.png")
            try files.createSymbolicLink(at: insideLink, withDestinationURL: valid)
            let linkedFolder = directory.appendingPathComponent("상위 링크", isDirectory: true)
            try files.createSymbolicLink(at: linkedFolder, withDestinationURL: sandbox)
            let traversal = directory.appendingPathComponent("../\(sibling.lastPathComponent)/비슷한 접두사.png")
            let encodedPath = try XCTUnwrap(valid.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed))
            let remoteFile = try XCTUnwrap(URL(string: "file://remote-host\(encodedPath)"))
            let invalidURLs = [outside, siblingFile, otherFile, directory, link, insideLink,
                linkedFolder.appendingPathComponent("외부.png"), traversal, remoteFile,
                directory.appendingPathComponent("없는 파일.png"),
                try XCTUnwrap(URL(string: "https://example.com/result.png"))]
            for invalid in invalidURLs {
                XCTAssertThrowsError(try store.publish(jobID: id, urls: [valid, invalid], expectedChangeCount: expected), invalid.absoluteString)
                assertPreserved(board, text: "경로 검증 전 내용", changeCount: expected)
            }
            store.discard(jobID: id)
            XCTAssertFalse(files.fileExists(atPath: directory.path))
            XCTAssertEqual(try Data(contentsOf: outside), png)
            XCTAssertEqual(try Data(contentsOf: siblingFile), png)
            XCTAssertEqual(try Data(contentsOf: otherFile), png)
        }
    }

    @MainActor
    func testUnreadableImageAndUnwritableRootAreRejectedWithoutClipboardChanges() throws {
        try withStore { store, board, root, _ in
            putText("권한 오류 전 내용", on: board)
            let expected = board.changeCount
            let id = UUID().uuidString
            let directory = try store.prepareDirectory(jobID: id)
            let url = directory.appendingPathComponent("권한 없는 이미지.png")
            try imageBytes(type: .png).write(to: url)
            try files.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
            defer { try? files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
            XCTAssertThrowsError(try store.publish(jobID: id, urls: [url], expectedChangeCount: expected)) {
                XCTAssertEqual($0.localizedDescription, "클립보드 결과 파일을 읽을 수 없습니다. 파일과 읽기 권한을 확인하세요.")
            }
            assertPreserved(board, text: "권한 오류 전 내용", changeCount: expected)
            try files.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
            defer { try? files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
            XCTAssertThrowsError(try store.prepareDirectory(jobID: UUID().uuidString))
            assertPreserved(board, text: "권한 오류 전 내용", changeCount: expected)
        }
    }

    @MainActor
    func testInitializationAndShutdownLeaveClipboardAndIncompleteWorkerFolderUntouched() throws {
        try withStore { store, board, root, _ in
            XCTAssertFalse(files.fileExists(atPath: root.path))
            putText("종료 전 내용", on: board)
            let expected = board.changeCount
            let another = ClipboardResultStore(pasteboard: board, root: root, fileManager: files)
            XCTAssertFalse(files.fileExists(atPath: root.path))
            assertPreserved(board, text: "종료 전 내용", changeCount: expected)
            another.shutdown()
            let id = UUID().uuidString
            let directory = try store.prepareDirectory(jobID: id)
            store.shutdown()
            store.shutdown()
            store.discard(jobID: id)
            let lateOutput = directory.appendingPathComponent("종료 중 worker가 저장.png")
            try imageBytes(type: .png).write(to: lateOutput)
            XCTAssertTrue(files.fileExists(atPath: lateOutput.path))
            XCTAssertThrowsError(try store.publish(jobID: id, urls: [lateOutput], expectedChangeCount: expected))
            XCTAssertThrowsError(try store.prepareDirectory(jobID: UUID().uuidString))
            assertPreserved(board, text: "종료 전 내용", changeCount: expected)
        }
    }

    @MainActor
    func testUUIDValidationAndOwnershipPreventAdoptingOrDiscardingForeignDirectories() throws {
        try withStore { store, board, root, _ in
            for invalid in ["", "..", "../outside", "/tmp/outside", UUID().uuidString + "/child"] {
                XCTAssertThrowsError(try store.prepareDirectory(jobID: invalid))
                store.discard(jobID: invalid)
            }
            XCTAssertFalse(files.fileExists(atPath: root.path))
            let id = UUID().uuidString
            let owned = try store.prepareDirectory(jobID: id)
            XCTAssertEqual(try store.prepareDirectory(jobID: id.lowercased()), owned)
            let foreignID = UUID().uuidString
            let foreign = root.appendingPathComponent(foreignID, isDirectory: true)
            try files.createDirectory(at: foreign, withIntermediateDirectories: false)
            XCTAssertThrowsError(try store.prepareDirectory(jobID: foreignID))
            store.discard(jobID: foreignID)
            XCTAssertTrue(files.fileExists(atPath: foreign.path))
            let restarted = ClipboardResultStore(pasteboard: board, root: root, fileManager: files)
            restarted.discard(jobID: id)
            XCTAssertThrowsError(try restarted.prepareDirectory(jobID: id))
            XCTAssertTrue(files.fileExists(atPath: owned.path))
            restarted.shutdown()
            store.discard(jobID: id)
            store.discard(jobID: id)
            XCTAssertFalse(files.fileExists(atPath: owned.path))
            XCTAssertTrue(files.fileExists(atPath: foreign.path))
        }
    }

    @MainActor
    func testExplicitSymlinkRootIsRejectedInsteadOfCanonicalized() throws {
        try withStore { _, board, _, sandbox in
            putText("명시적 심볼릭 링크 거절", on: board)
            let expected = board.changeCount
            let external = sandbox.appendingPathComponent("외부 대상", isDirectory: true)
            try files.createDirectory(at: external, withIntermediateDirectories: false)
            let sentinel = external.appendingPathComponent("보존할 원본.png")
            let original = try imageBytes(type: .png)
            try original.write(to: sentinel)
            let linkedRoot = sandbox.appendingPathComponent("전달한 링크 root", isDirectory: true)
            try files.createSymbolicLink(at: linkedRoot, withDestinationURL: external)
            let store = ClipboardResultStore(pasteboard: board, root: linkedRoot, fileManager: files)
            defer { store.shutdown() }
            let id = UUID().uuidString

            XCTAssertThrowsError(try store.prepareDirectory(jobID: id)) {
                XCTAssertEqual($0.localizedDescription,
                    "클립보드 결과의 임시 경로는 심볼릭 링크가 없는 로컬 폴더여야 합니다.")
            }
            store.discard(jobID: id)
            XCTAssertFalse(files.fileExists(atPath: external.appendingPathComponent(id).path))
            XCTAssertEqual(try Data(contentsOf: sentinel), original)
            assertPreserved(board, text: "명시적 심볼릭 링크 거절", changeCount: expected)
        }
    }

    @MainActor
    func testSymlinkReplacementOfJobOrRootCannotDeleteOrPublishExternalFiles() throws {
        try withStore { store, board, root, sandbox in
            putText("외부 폴더 보호", on: board)
            let expected = board.changeCount
            let id = UUID().uuidString
            let directory = try store.prepareDirectory(jobID: id)
            let external = sandbox.appendingPathComponent("외부 폴더", isDirectory: true)
            try files.createDirectory(at: external, withIntermediateDirectories: false)
            let original = external.appendingPathComponent("원본.png")
            let png = try imageBytes(type: .png)
            try png.write(to: original)
            try files.removeItem(at: directory)
            try files.createSymbolicLink(at: directory, withDestinationURL: external)
            store.discard(jobID: id)
            XCTAssertThrowsError(try store.publish(jobID: id, urls: [directory.appendingPathComponent("원본.png")], expectedChangeCount: expected))
            XCTAssertEqual(try Data(contentsOf: original), png)
            try files.removeItem(at: root)
            try files.createSymbolicLink(at: root, withDestinationURL: external)
            XCTAssertThrowsError(try store.prepareDirectory(jobID: UUID().uuidString))
            store.discard(jobID: id)
            XCTAssertEqual(try Data(contentsOf: original), png)
            assertPreserved(board, text: "외부 폴더 보호", changeCount: expected)
        }
    }
}

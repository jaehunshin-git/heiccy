import AppKit
import Combine
import ConverterKit
import ImageIO
import UniformTypeIdentifiers

/// 일반 클립보드·개인 사진과 분리된 실제 내장 worker의 자동 변환 검증이다.
@MainActor func clipboardConversionSmokeTest(worker: WorkerConnection? = nil,
                                           onNotice: ((ClipboardConversionNotice?) -> Void)? = nil) async -> Bool {
    let name = "heic-auto-worker-smoke-\(UUID().uuidString)"
    let folder = URL(fileURLWithPath: InputValidator.canonicalPath(FileManager.default.temporaryDirectory), isDirectory: true).appendingPathComponent(name)
    let board = NSPasteboard(name: .init(name))
    guard let defaults = UserDefaults(suiteName: name) else { return false }
    let model = AppModel(startClipboard: false, pasteboard: board, defaults: defaults,
                         clipboardRoot: folder.appendingPathComponent("results"), worker: worker)
    let noticeSubscription = model.$conversionNotice.sink { onNotice?($0) }
    defer {
        noticeSubscription.cancel()
        // 실패·시간 초과 경로도 worker가 종료된 다음에만 검증 파일을 삭제한다.
        model.shutdown {
            board.releaseGlobally(); defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: folder)
        }
    }
    func check(_ label: String, _ condition: Bool) -> Bool {
        print("자동 변환 검증 [\(label)]: \(condition ? "성공" : "실패")")
        if !condition { print("상태: \(model.message)") }
        return condition
    }
    func idle() async -> Bool {
        let deadline = Date().addingTimeInterval(30)
        while model.active && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        return check("worker 작업 종료", !model.active)
    }
    func copy(_ urls: [URL], text: String? = nil) -> Bool {
        let items = urls.map { url -> NSPasteboardItem in
            let item = NSPasteboardItem(); item.setString(url.absoluteString, forType: .fileURL); return item
        }
        var all = items
        if let text {
            let item = NSPasteboardItem(); item.setString(text, forType: .string); all.append(item)
        }
        board.clearContents()
        let written = board.writeObjects(all)
        model.pollClipboard()
        return written
    }
    do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = folder.appendingPathComponent("합성 원본.heic")
        let second = folder.appendingPathComponent("합성 둘째.heic")
        let other = folder.appendingPathComponent("보존 문서.txt")
        let context = CGContext(data: nil, width: 24, height: 16, bitsPerComponent: 8, bytesPerRow: 96,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.15, green: 0.65, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 24, height: 16))
        let encoder = CGImageDestinationCreateWithURL(source as CFURL, UTType.heic.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(encoder, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(encoder) else { return false }
        let original = try Data(contentsOf: source)
        try original.write(to: second); try Data("문서".utf8).write(to: other)
        let poster = folder.appendingPathComponent("합성 동영상 미리보기.jpeg")
        let jpegEncoder = CGImageDestinationCreateWithURL(poster as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(jpegEncoder, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(jpegEncoder) else { return false }
        let posterData = try Data(contentsOf: poster)
        let assetType = NSPasteboard.PasteboardType("com.apple.photos.object-reference.asset")
        let assetData = try PropertyListSerialization.data(fromPropertyList: ["mediaType": 2, "mediaSubtypes": 0], format: .binary, options: 0)
        func videoItem(raw: Bool) -> NSPasteboardItem {
            let item = NSPasteboardItem()
            item.setData(assetData, forType: assetType)
            item.setString(poster.absoluteString, forType: .fileURL)
            item.setData(posterData, forType: .init(UTType.jpeg.identifier))
            if raw { item.setData(original, forType: .init(UTType.heic.identifier)) }
            return item
        }
        for raw in [false, true] {
            board.clearContents(); guard board.writeObjects([videoItem(raw: raw)]) else { return false }
            let generation = board.changeCount
            model.pollClipboard()
            guard check("Photos 동영상 미리보기 변환 제외 (HEIC \(raw))", !model.active
                && model.conversionNotice == nil && model.clipboardFiles.first?.isVideo == true
                && board.changeCount == generation && board.pasteboardItems?.first?.data(forType: assetType) == assetData
                && board.pasteboardItems?.first?.data(forType: .init(UTType.jpeg.identifier)) == posterData) else { return false }
        }
        let heicItem = NSPasteboardItem(); heicItem.setString(source.absoluteString, forType: .fileURL)
        let movie = videoItem(raw: true)
        let movieTypes = movie.types
        let movieBytes = movieTypes.map { movie.data(forType: $0) }
        board.clearContents(); guard board.writeObjects([heicItem, movie]) else { return false }
        model.pollClipboard()
        guard await idle(), check("HEIC·Photos 동영상 혼합에서 사진만 변환", model.conversionNotice?.heicCount == 1
            && model.conversionNotice?.completedCount == 1 && board.pasteboardItems?.count == 2
            && board.pasteboardItems?.last?.types == movieTypes
            && movieTypes.map { board.pasteboardItems?.last?.data(forType: $0) } == movieBytes
            && model.clipboardFiles.last?.isVideo == true) else { return false }
        guard copy([source, other, second], text: "혼합 텍스트"), await idle() else { return false }
        let items = try XCTSmokeItems(board)
        let results = [items[0], items[2]].compactMap { $0.string(forType: .fileURL).flatMap(URL.init(string:)) }
        guard check("혼합 순서·텍스트·타파일 보존", items.count == 4
            && items[1].string(forType: .fileURL) == other.absoluteString && items[3].string(forType: .string) == "혼합 텍스트"),
              check("다중 JPEG 파일·이미지 동시 게시", results.count == 2 && results.allSatisfy { $0.pathExtension == "jpeg" || $0.pathExtension == "jpg" }
                && [items[0], items[2]].allSatisfy { $0.data(forType: .init(UTType.jpeg.identifier)) != nil }),
              check("게시 파일 수명", results.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }) else { return false }
        model.pollClipboard()
        guard check("자체 게시 루프 없음", !model.active && model.clipboardFiles.count == 3) else { return false }
        model.setClipboard(false)
        guard check("끄기 후 결과 유지", results.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }) else { return false }
        model.setClipboard(true)
        let corrupt = folder.appendingPathComponent("손상.heic"); try Data([1, 2, 3]).write(to: corrupt)
        guard copy([source, corrupt]) else { return false }
        let failedCount = board.changeCount
        guard await idle(), check("부분 실패 전체 원본 유지", board.changeCount == failedCount
            && board.pasteboardItems?.first?.string(forType: .fileURL) == source.absoluteString),
              check("새 복사 후 이전 결과 정리", results.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }) else { return false }
        // 원본의 길이와 worker 원자 저장용 파일명의 길이는 별도로 검증한다.
        let longNames = [String(repeating: "a", count: 250) + ".heic",
                         String(repeating: "한", count: 83) + "a.heic"]
        let longSources = try longNames.map { filename -> URL in
            guard filename.utf8.count == 255 else { throw WorkerFailure.invalidEvent }
            let url = folder.appendingPathComponent(filename)
            try original.write(to: url)
            return url
        }
        // 같은 경로의 중복도 별도 결과로 만들고 ASCII·한글 255바이트 이름을 두 형식으로 변환한다.
        let longInputs = [longSources[0], longSources[0], longSources[1]]
        for format in ["jpeg", "png"] {
            model.settings.options.outputFormat = format
            guard copy(longInputs), check("255바이트 원본의 표시명 유지 (\(format))",
                model.clipboardFiles.map(\.name) == longInputs.map(\.lastPathComponent)), await idle() else { return false }
            let published = board.pasteboardItems ?? []
            let outputs = published.compactMap { $0.string(forType: .fileURL).flatMap(URL.init(string:)) }
            let outputType = NSPasteboard.PasteboardType(format == "jpeg" ? UTType.jpeg.identifier : UTType.png.identifier)
            guard check("255바이트 이름·중복 원본의 실제 worker 변환 (\(format))",
                model.clipboardFiles.allSatisfy { $0.status == .completed }
                && model.conversionNotice?.phase == .completed && model.conversionNotice?.completedCount == 3
                && published.count == 3 && outputs.count == 3 && Set(outputs).count == 3
                && published.allSatisfy { $0.data(forType: outputType) != nil }) else { return false }
            for url in outputs {
                guard check("긴 원본의 결과 파일 확인 (\(format))",
                    FileManager.default.fileExists(atPath: url.path)
                    && CGImageSourceCreateWithURL(url as CFURL, nil) != nil) else { return false }
            }
            for url in longSources {
                guard try Data(contentsOf: url) == original else { return false }
            }
        }
        model.settings.options.outputFormat = "png"
        guard copy([source]), await idle(), check("PNG 자동 변환", board.pasteboardItems?.first?.data(forType: .png) != nil) else { return false }
        // Photos ⌘C와 같은 raw HEIC + 보관함 URL + asset 참조를 합성한다.
        // 보관함 경로는 존재하지 않아도 raw 데이터로 실제 네이티브 변환이 이뤄져야 한다.
        let libraryURL = folder.appendingPathComponent("미생성.photoslibrary/originals/Photos 원본.heic")
        let photo = NSPasteboardItem()
        photo.setString(libraryURL.absoluteString, forType: .fileURL)
        photo.setString(libraryURL.absoluteString, forType: .URL)
        photo.setData(original, forType: .init(UTType.heic.identifier))
        photo.setData(try PropertyListSerialization.data(fromPropertyList: ["mediaType": 1, "mediaSubtypes": 512],
                                                        format: .binary, options: 0), forType: assetType)
        let caption = NSPasteboardItem(); caption.setString("Photos 캡션 보존", forType: .string)
        board.clearContents()
        guard board.writeObjects([photo, caption]) else { return false }
        model.pollClipboard()
        guard await idle(), check("Photos 직접 복사 실제 PNG 변환", model.clipboardFiles.first?.status == .completed
            && board.pasteboardItems?.first?.data(forType: .png) != nil
            && board.pasteboardItems?.first?.data(forType: assetType) == nil
            && board.pasteboardItems?.last?.string(forType: .string) == "Photos 캡션 보존") else { return false }
        var closed = false
        model.shutdown { closed = true }
        let deadline = Date().addingTimeInterval(10)
        while !closed && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        let sourcePreserved = try Data(contentsOf: source) == original
        guard let restored = board.pasteboardItems?.first,
              let restoredURL = restored.string(forType: .fileURL).flatMap(URL.init(string:)) else { return false }
        let restoredBytes = try Data(contentsOf: restoredURL)
        return check("Photos 정상 종료 원본 HEIC 복구", closed && restoredURL != libraryURL
            && restoredBytes == original && restored.data(forType: .init(UTType.heic.identifier)) == original
            && restored.data(forType: assetType) == nil
            && board.pasteboardItems?.last?.string(forType: .string) == "Photos 캡션 보존")
            && check("보관함 경로 접근 없이 원본 보존", sourcePreserved
                && !FileManager.default.fileExists(atPath: libraryURL.path))
    } catch { print("자동 변환 smoke 오류: \(error.localizedDescription)"); return false }
}

@MainActor private func XCTSmokeItems(_ board: NSPasteboard) throws -> [NSPasteboardItem] {
    guard let items = board.pasteboardItems, items.count == 4 else { throw WorkerFailure.invalidEvent }
    return items
}

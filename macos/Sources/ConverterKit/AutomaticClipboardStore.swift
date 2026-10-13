import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Darwin

public struct ClipboardFile: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let url: URL?
    public let isHEIC: Bool
    public let isVideo: Bool

    public init(id: String, name: String, url: URL?, isHEIC: Bool, isVideo: Bool = false) {
        self.id = id; self.name = name; self.url = url
        self.isHEIC = isHEIC; self.isVideo = isVideo
    }
}

public struct ClipboardTarget: Identifiable, Equatable {
    public let id: String
    /// 파일 입력은 원본 URL, raw 입력은 식별용 예정 URL이다. worker에는 prepare.inputs를 전달한다.
    public let source: URL
}

public struct ClipboardSnapshot {
    public let changeCount: Int
    public let files: [ClipboardFile]
    public let targets: [ClipboardTarget]
    fileprivate let owner: UUID
    fileprivate let token: UUID
    fileprivate let items: [[ClipboardRepresentation]]
    fileprivate let conversions: [ClipboardConversion]
}

fileprivate struct ClipboardRepresentation {
    let type: NSPasteboard.PasteboardType
    let data: Data
}

fileprivate struct ClipboardConversion {
    let itemIndex: Int
    let name: String
    let data: Data
}

public enum AutomaticClipboardError: LocalizedError {
    case selfPublication, clipboardChanged, unsupportedRepresentation, unreadableRepresentation
    case unrestorablePhotosLibraryURL
    case invalidSnapshot, invalidJob, invalidRoot, unsafePath, directoryUnavailable, fileUnavailable
    case invalidImage, incompleteResults, itemUnavailable, writeFailed, restoreFailed, stopped

    public var errorDescription: String? {
        switch self {
        case .selfPublication: return "앱이 게시한 클립보드이므로 다시 변환하지 않습니다."
        case .clipboardChanged: return "클립보드가 변경되어 이전 작업을 게시하거나 복구하지 않았습니다."
        case .unsupportedRepresentation: return "원본을 안전하게 보존할 수 없는 클립보드 표현입니다."
        case .unreadableRepresentation: return "클립보드 표현 전체를 읽을 수 없어 원본을 변경하지 않았습니다."
        case .unrestorablePhotosLibraryURL: return "Photos 보관함 원본 URL은 종료 후 복구를 보장할 수 없습니다. 원본을 내보낸 뒤 Finder에서 복사하세요."
        case .invalidSnapshot: return "이 저장소에서 캡처한 스냅샷이 아닙니다."
        case .invalidJob: return "작업 ID는 UUID여야 하며 이 저장소가 준비한 작업만 사용할 수 있습니다."
        case .invalidRoot: return "임시 경로는 심볼릭 링크가 없는 로컬 전용 폴더여야 합니다."
        case .unsafePath: return "소유한 작업 폴더 안의 일반 파일만 사용할 수 있습니다."
        case .directoryUnavailable: return "임시 폴더를 만들거나 사용할 수 없습니다."
        case .fileUnavailable: return "HEIC 입력 또는 변환 결과 파일을 읽을 수 없습니다."
        case .invalidImage: return "입력 HEIC 또는 결과 PNG/JPEG 이미지 데이터가 올바르지 않습니다."
        case .incompleteResults: return "모든 HEIC 항목의 서로 다른 변환 결과가 필요합니다."
        case .itemUnavailable: return "클립보드 항목을 완전히 구성하지 못했습니다."
        case .writeFailed: return "결과 게시에 실패했습니다. 원본 복구를 시도했습니다."
        case .restoreFailed: return "원본 클립보드를 복구하지 못했습니다. 게시한 임시 파일을 유지합니다."
        case .stopped: return "종료된 클립보드 저장소는 사용할 수 없습니다."
        }
    }
}

/// 항목과 표현의 순서를 유지한다. 임시 파일은 붙여넣기 참조가 사라질 때까지 보유한다.
/// shutdown은 worker를 중지한 다음 호출한다. 초기화는 클립보드와 파일을 변경하지 않는다.
@MainActor public final class AutomaticClipboardStore {
    private typealias Failure = AutomaticClipboardError
    private struct Identity: Equatable {
        let device: UInt64
        let inode: UInt64
    }
    private struct Job {
        let directory: URL
        let identity: Identity
        let snapshot: UUID
        let inputs: [URL]
        let output: URL
        // 실패한 부분 게시도 파일 URL을 노출했을 수 있으므로 보수적으로 보호한다.
        var exposed = false
    }
    private struct Publication {
        let snapshot: ClipboardSnapshot
        let jobID: String
        let changeCount: Int
    }
    private let pasteboard: NSPasteboard
    private let root: URL
    private let files: FileManager
    private let owner = UUID()
    private let writer: (NSPasteboard, [NSPasteboardItem]) -> Bool
    private let cleanupItemsReader: (NSPasteboard) -> [NSPasteboardItem]?
    private let metadataReader: (URL) -> stat?
    private var rootIdentity: Identity?
    private var jobs: [String: Job] = [:]
    private var publication: Publication?
    private var selfGeneration: Int?
    private var stopped = false

    public convenience init(pasteboard: NSPasteboard = .general, root: URL? = nil,
                            fileManager: FileManager = FileManager()) {
        self.init(pasteboard: pasteboard, root: root, fileManager: fileManager,
                  writer: { $0.writeObjects($1) })
    }

    // named pasteboard의 쓰기 실패·외부 복사·정리 시 조회 실패를 검증하기 위한 최소 주입이다.
    internal init(pasteboard: NSPasteboard, root: URL?, fileManager: FileManager,
                  writer: @escaping (NSPasteboard, [NSPasteboardItem]) -> Bool,
                  cleanupItemsReader: @escaping (NSPasteboard) -> [NSPasteboardItem]? = { $0.pasteboardItems },
                  metadataReader: @escaping (URL) -> stat? = { url in
                      var metadata = stat()
                      return url.withUnsafeFileSystemRepresentation { path in
                          guard let path, Darwin.lstat(path, &metadata) == 0 else { return nil }
                          return metadata
                      }
                  }) {
        self.pasteboard = pasteboard
        self.root = root ?? URL(fileURLWithPath: InputValidator.canonicalPath(fileManager.temporaryDirectory),
                                isDirectory: true)
            .appendingPathComponent("io.github.jaehunshin-git.heic-converter/AutomaticClipboard", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        self.files = fileManager
        self.writer = writer
        self.cleanupItemsReader = cleanupItemsReader
        self.metadataReader = metadataReader
    }

    /// 게시 또는 복구로 만든 현재 소유 세대다. 외부 복사가 일어나면 nil이다.
    public var ownedChangeCount: Int? {
        selfGeneration == pasteboard.changeCount ? selfGeneration : nil
    }

    /// 안전성 검사가 실패한 경우에도 이름 표시를 위한 최소 정보만 읽는다. promise를 실행하지 않는다.
    public func previewFiles() -> [ClipboardFile] {
        guard !stopped else { return [] }
        let generation = pasteboard.changeCount
        let result = (pasteboard.pasteboardItems ?? []).enumerated().compactMap { index, item -> ClipboardFile? in
            let id = "\(generation)-\(index)"
            let types = item.types
            if types.contains(where: isUnsafeType) {
                // 약속 항목의 URL·asset·raw는 읽지 않고 선언된 타입만으로 표시한다.
                return ClipboardFile(id: id, name: "파일 약속 항목 \(index + 1)", url: nil,
                                     isHEIC: types.contains(where: isHEICType))
            }
            if let video = videoFile(id: id, index: index, types: types,
                data: { item.data(forType: $0) }) { return video }
            // Photos 메타데이터를 해석할 수 없으면 미리보기를 HEIC 원본으로 간주하지 않는다.
            if item.types.contains(Self.photosAssetType), photosMediaType(item.data(forType: Self.photosAssetType)) != 1 {
                return ClipboardFile(id: id, name: "Photos 항목 \(index + 1)", url: nil, isHEIC: false)
            }
            if item.types.contains(.fileURL), let value = item.string(forType: .fileURL),
               let url = URL(string: value), isLocalURL(url) {
                return ClipboardFile(id: id, name: url.lastPathComponent,
                    url: safePreviewURL(url, isPhotosItem: item.types.contains(Self.photosAssetType)), isHEIC: isHEICExtension(url))
            }
            if let value = item.string(forType: .URL), let url = URL(string: value), isLocalURL(url) {
                return ClipboardFile(id: id, name: url.lastPathComponent,
                    url: safePreviewURL(url, isPhotosItem: item.types.contains(Self.photosAssetType)), isHEIC: isHEICExtension(url))
            }
            if let type = item.types.first(where: { isHEICType($0) }) {
                return ClipboardFile(id: id, name: imageName(index: index, type: type), url: nil, isHEIC: true)
            }
            if let type = item.types.first(where: { isImageType($0) }) {
                return ClipboardFile(id: id, name: imageName(index: index, type: type), url: nil, isHEIC: false)
            }
            return nil
        }
        return pasteboard.changeCount == generation ? result : []
    }

    /// 모든 표현을 즉시 데이터로 보관한다. 읽을 수 없는 표현을 생략한 불완전한 스냅샷은 만들지 않는다.
    public func capture() throws -> ClipboardSnapshot {
        guard !stopped else { throw Failure.stopped }
        let generation = pasteboard.changeCount
        guard generation != publication?.changeCount else { throw Failure.selfPublication }
        let token = UUID()
        guard let originalItems = pasteboard.pasteboardItems else {
            guard pasteboard.types?.isEmpty != false else { throw Failure.unreadableRepresentation }
            return ClipboardSnapshot(changeCount: generation, files: [], targets: [], owner: owner,
                                     token: token, items: [], conversions: [])
        }
        // 약속 타입이 하나라도 있으면 다른 항목을 포함해 어떤 표현 데이터도 요청하지 않는다.
        // Photos URL 문자열 조회도 data provider를 실행할 수 있으므로 이 타입 검사보다 뒤에 둔다.
        if originalItems.contains(where: { $0.types.contains(where: isUnsafeType) }) {
            throw Failure.unsupportedRepresentation
        }
        // raw를 변환할 수 있어도 보관함 URL의 정확한 종료 복구는 보장할 수 없다.
        // 동영상 보존 분기와 다른 항목의 파일 검사보다 먼저 전체 입력을 거절한다.
        // URL 문자열만 검사하며 Photos 보관함의 파일·메타데이터에는 접근하지 않는다.
        if originalItems.contains(where: hasPhotosLibraryURL) {
            throw Failure.unrestorablePhotosLibraryURL
        }
        var saved: [[ClipboardRepresentation]] = []
        var descriptors: [ClipboardFile] = []
        var targets: [ClipboardTarget] = []
        var conversions: [ClipboardConversion] = []
        for (index, item) in originalItems.enumerated() {
            let types = item.types
            guard !types.isEmpty else { throw Failure.unreadableRepresentation }
            var representations: [ClipboardRepresentation] = []
            for type in types {
                guard !isUnsafeType(type) else { throw Failure.unsupportedRepresentation }
                guard let data = item.data(forType: type) else { throw Failure.unreadableRepresentation }
                representations.append(ClipboardRepresentation(type: type, data: data))
            }
            let id = "\(generation)-\(index)"
            let dataForType: (NSPasteboard.PasteboardType) -> Data? = { type in
                representations.first(where: { $0.type == type })?.data
            }
            // 동영상 원본의 선언은 함께 제공된 HEIC/JPEG 포스터보다 우선한다.
            if let video = videoFile(id: id, index: index, types: types, data: dataForType) {
                descriptors.append(video)
                saved.append(representations)
                continue
            }
            let photosPhoto = types.contains(Self.photosAssetType)
                && photosMediaType(dataForType(Self.photosAssetType)) == 1
            if types.contains(Self.photosAssetType), !photosPhoto {
                throw Failure.unsupportedRepresentation
            }
            let raw = representations.filter { isHEICType($0.type) }
            for representation in raw { _ = try heicInputType(representation.data) }
            guard raw.dropFirst().allSatisfy({ $0.data == raw.first?.data }) else { throw Failure.unsupportedRepresentation }
            var source: URL?
            var name: String?
            var input: Data?
            if let url = try sourceFileURL(representations) {
                let heic = isHEICExtension(url)
                // Photos는 파일 URL이 아직 물질화되지 않아 stat/read/썸네일에서 멈출 수 있다.
                // 명시적 사진의 유효 raw HEIC를 복사 시점의 입력으로 삼고 URL은 복구용으로만 둔다.
                let photosRaw = photosPhoto && heic ? raw.first?.data : nil
                descriptors.append(ClipboardFile(id: id, name: url.lastPathComponent,
                    url: photosPhoto ? nil : (heic ? url : safePreviewURL(url, isPhotosItem: false)), isHEIC: heic))
                if heic {
                    let data: Data
                    if let photosRaw {
                        // Photos에서는 raw가 우선한다. URL과 동일 바이트인지 확인하려고 파일을 읽지 않는다.
                        data = photosRaw
                    } else {
                        try validateSource(url)
                        data = try readFile(url)
                        _ = try heicInputType(data)
                        if let rawData = raw.first?.data, rawData != data { throw Failure.unsupportedRepresentation }
                    }
                    source = url; name = url.lastPathComponent; input = data
                } else if !raw.isEmpty {
                    // 한 항목의 파일 URL과 raw 이미지가 서로 다른 원본을 뜻할 수 있다.
                    throw Failure.unsupportedRepresentation
                }
            } else if let representation = raw.first {
                name = imageName(index: index, type: representation.type)
                source = root.appendingPathComponent(token.uuidString).appendingPathComponent("raw-\(index).heic")
                input = representation.data
                descriptors.append(ClipboardFile(id: id, name: name!, url: nil, isHEIC: true))
            } else if let type = types.first(where: { isImageType($0) }) {
                descriptors.append(ClipboardFile(id: id, name: imageName(index: index, type: type), url: nil, isHEIC: false))
            }
            if let source, let input, let name {
                targets.append(ClipboardTarget(id: id, source: source))
                conversions.append(ClipboardConversion(itemIndex: index, name: name, data: input))
            }
            saved.append(representations)
        }
        guard pasteboard.changeCount == generation else { throw Failure.clipboardChanged }
        return ClipboardSnapshot(changeCount: generation, files: descriptors, targets: targets,
                                 owner: owner, token: token, items: saved, conversions: conversions)
    }

    /// 같은 원본의 여러 항목도 고유한 입력으로 만들어 worker의 중복 경로와 출력 이름 충돌을 피한다.
    public func prepare(snapshot: ClipboardSnapshot, jobID: String) throws -> (inputs: [URL], outputDirectory: URL) {
        try validateSnapshot(snapshot)
        let id = try normalizedID(jobID)
        guard !snapshot.targets.isEmpty else { throw Failure.incompleteResults }
        try validateRoot(create: true)
        if let job = jobs[id] {
            guard job.snapshot == snapshot.token, !job.exposed else { throw Failure.invalidJob }
            try validateJob(job)
            try validateDirectory(job.output, writable: true)
            for input in job.inputs { try validateResult(input, directory: job.directory) }
            return (job.inputs, job.output)
        }
        let directory = root.appendingPathComponent(id, isDirectory: true)
        guard attributes(directory) == nil else { throw Failure.invalidJob }
        try createDirectory(directory)
        let identity = try identityOf(directory)
        let inputDirectory = directory.appendingPathComponent("inputs", isDirectory: true)
        let outputDirectory = directory.appendingPathComponent("outputs", isDirectory: true)
        var inputs: [URL] = []
        jobs[id] = Job(directory: directory, identity: identity, snapshot: snapshot.token,
                       inputs: [], output: outputDirectory)
        do {
            try createDirectory(inputDirectory)
            try createDirectory(outputDirectory)
            for (index, conversion) in snapshot.conversions.enumerated() {
                let occurrence = inputDirectory.appendingPathComponent(String(index + 1), isDirectory: true)
                try createDirectory(occurrence)
                let url = occurrence.appendingPathComponent(stagingInputName(conversion.name))
                try conversion.data.write(to: url, options: [.withoutOverwriting])
                try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                inputs.append(url)
            }
            guard pasteboard.changeCount == snapshot.changeCount else { throw Failure.clipboardChanged }
            jobs[id] = Job(directory: directory, identity: identity, snapshot: snapshot.token,
                           inputs: inputs, output: outputDirectory)
            return (inputs, outputDirectory)
        } catch {
            discard(jobID: id)
            throw error
        }
    }

    /// 모든 결과와 원본 복구용 항목을 준비한 뒤 마지막으로 외부 세대를 확인하고 일괄 게시한다.
    public func publish(snapshot: ClipboardSnapshot, jobID: String, results: [URL]) throws -> Int {
        try validateSnapshot(snapshot)
        let id = try normalizedID(jobID)
        guard var job = jobs[id], job.snapshot == snapshot.token, !job.exposed else { throw Failure.invalidJob }
        guard !results.isEmpty, results.count == snapshot.targets.count,
              Set(results.map(\.path)).count == results.count else { throw Failure.incompleteResults }
        try validateRoot(create: false)
        try validateJob(job)
        var replacements: [Int: [ClipboardRepresentation]] = [:]
        for (conversion, url) in zip(snapshot.conversions, results) {
            try validateResult(url, directory: job.output)
            let data = try readFile(url)
            let type = try imageType(data, allowed: [UTType.png.identifier, UTType.jpeg.identifier])
            let target = snapshot.targets[replacements.count]
            var representations = snapshot.items[conversion.itemIndex].filter {
                $0.type != .fileURL && !isImageType($0.type)
            }.map { representation in
                if representation.type == .URL,
                   let value = String(data: representation.data, encoding: .utf8),
                   let original = URL(string: value), isLocalURL(original),
                   InputValidator.canonicalPath(original) == InputValidator.canonicalPath(target.source) {
                    return ClipboardRepresentation(type: .URL, data: Data(url.absoluteString.utf8))
                }
                return representation
            }
            representations.append(ClipboardRepresentation(type: .fileURL, data: Data(url.absoluteString.utf8)))
            representations.append(ClipboardRepresentation(type: NSPasteboard.PasteboardType(type), data: data))
            guard let tiff = NSImage(data: data)?.tiffRepresentation else { throw Failure.invalidImage }
            representations.append(ClipboardRepresentation(type: .tiff, data: tiff))
            replacements[conversion.itemIndex] = representations
        }
        let original = try makeItems(snapshot.items)
        let replacement = try makeItems(snapshot.items.enumerated().map { replacements[$0.offset] ?? $0.element })
        guard pasteboard.changeCount == snapshot.changeCount else { throw Failure.clipboardChanged }
        job.exposed = true
        jobs[id] = job
        let generation = pasteboard.clearContents()
        // clear 직후 외부 변경도 write 직전에 다시 확인한다.
        guard pasteboard.changeCount == generation else { throw Failure.clipboardChanged }
        let success = writer(pasteboard, replacement)
        guard pasteboard.changeCount == generation else { throw Failure.clipboardChanged }
        if !success {
            do {
                selfGeneration = try restore(original, expected: generation)
                publication = nil
            } catch {
                // 현재 세대를 여전히 소유하면 shutdown에서 복구를 재시도한다. 파일을 먼저 삭제하지 않는다.
                if pasteboard.changeCount == selfGeneration || pasteboard.changeCount == generation {
                    publication = Publication(snapshot: snapshot, jobID: id, changeCount: pasteboard.changeCount)
                }
                throw error
            }
            throw Failure.writeFailed
        }
        selfGeneration = generation
        publication = Publication(snapshot: snapshot, jobID: id, changeCount: generation)
        return generation
    }

    /// worker가 완료한 미게시 작업만 삭제한다. 게시를 시도한 폴더는 참조 확인까지 유지한다.
    public func discard(jobID: String) {
        guard let id = try? normalizedID(jobID), let job = jobs[id], !job.exposed else { return }
        if removeJob(job) { jobs.removeValue(forKey: id) }
    }

    /// 세대가 바뀌어도 새 항목이 같은 파일을 참조한다면 유지한다.
    public func clipboardDidChange() {
        let generation = pasteboard.changeCount
        guard generation != selfGeneration else { return }
        if publication?.changeCount != generation { publication = nil }
        selfGeneration = nil
        cleanupUnreferenced()
    }

    /// 원본 복구에 실패하면 현재 참조될 수 있는 게시 파일을 유지하고 throw한다.
    public func shutdown() throws {
        stopped = true
        if let publication, pasteboard.changeCount == publication.changeCount {
            let original = try makeItems(publication.snapshot.items)
            do {
                selfGeneration = try restore(original, expected: publication.changeCount)
                self.publication = nil
            } catch {
                // restore에서 clear한 세대도 여전히 소유하고 있다면 재시도할 수 있게 한다.
                if let own = selfGeneration, pasteboard.changeCount == own {
                    self.publication = Publication(snapshot: publication.snapshot, jobID: publication.jobID, changeCount: own)
                }
                throw error
            }
        } else { publication = nil }
        cleanupUnreferenced()
        for id in Array(jobs.keys) { discard(jobID: id) }
    }

    private func restore(_ original: [NSPasteboardItem], expected: Int) throws -> Int {
        guard pasteboard.changeCount == expected else { throw Failure.clipboardChanged }
        let generation = pasteboard.clearContents()
        selfGeneration = generation
        guard pasteboard.changeCount == generation else { throw Failure.clipboardChanged }
        let success = original.isEmpty || writer(pasteboard, original)
        guard pasteboard.changeCount == generation else { throw Failure.clipboardChanged }
        guard success else { throw Failure.restoreFailed }
        return generation
    }

    private func validateSnapshot(_ snapshot: ClipboardSnapshot) throws {
        guard !stopped else { throw Failure.stopped }
        guard snapshot.owner == owner else { throw Failure.invalidSnapshot }
        guard pasteboard.changeCount == snapshot.changeCount else { throw Failure.clipboardChanged }
        guard snapshot.changeCount != publication?.changeCount else { throw Failure.selfPublication }
    }

    private func makeItems(_ representations: [[ClipboardRepresentation]]) throws -> [NSPasteboardItem] {
        try representations.map { values in
            let item = NSPasteboardItem()
            for value in values {
                guard item.setData(value.data, forType: value.type) else { throw Failure.itemUnavailable }
            }
            return item
        }
    }

    private func isUnsafeType(_ type: NSPasteboard.PasteboardType) -> Bool {
        let name = type.rawValue.lowercased()
        return name.contains("promise") || name == "nsfilenamespboardtype"
            || name.contains("filecontents") || name.contains("file-list")
            || name.contains("bookmark") || name.contains("security-scoped")
    }

    private func isHEICType(_ type: NSPasteboard.PasteboardType) -> Bool {
        type.rawValue == UTType.heic.identifier || type.rawValue == UTType.heif.identifier
            || UTType(type.rawValue)?.conforms(to: .heic) == true
            || UTType(type.rawValue)?.conforms(to: .heif) == true
    }

    private func isImageType(_ type: NSPasteboard.PasteboardType) -> Bool {
        isHEICType(type) || type == .tiff || type == .png || type.rawValue == "NeXT TIFF v4.0 pasteboard type"
            || UTType(type.rawValue)?.conforms(to: .image) == true
    }

    private func isHEICExtension(_ url: URL) -> Bool { url.pathExtension.lowercased() == "heic" }

    private static let photosAssetType = NSPasteboard.PasteboardType("com.apple.photos.object-reference.asset")

    private func isPhotosLibraryURL(_ url: URL) -> Bool {
        url.isFileURL && url.pathComponents.contains {
            ($0 as NSString).pathExtension.caseInsensitiveCompare("photoslibrary") == .orderedSame
        }
    }

    private func hasPhotosLibraryURL(_ item: NSPasteboardItem) -> Bool {
        guard item.types.contains(Self.photosAssetType) else { return false }
        return [NSPasteboard.PasteboardType.fileURL, .URL].contains { type in
            guard let value = item.string(forType: type), let url = URL(string: value) else { return false }
            return isPhotosLibraryURL(url)
        }
    }

    /// Photos의 현재 복사 메타데이터만 읽는다. 사진 보관함 접근이나 원본 내보내기는 요청하지 않는다.
    /// 키가 없거나 형식이 바뀌면 raw 이미지의 자동 변환을 허용하지 않는다.
    private func photosMediaType(_ data: Data?) -> Int? {
        guard let data, let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = object as? [String: Any], let number = dictionary["mediaType"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue == Double(number.intValue) else { return nil }
        return number.intValue
    }

    private func isVideoType(_ type: NSPasteboard.PasteboardType) -> Bool {
        guard let value = UTType(type.rawValue) else { return false }
        return value.conforms(to: .movie) || value.conforms(to: .video)
    }

    private func isVideoURL(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .video)
    }

    private func videoFile(id: String, index: Int, types: [NSPasteboard.PasteboardType],
                           data: (NSPasteboard.PasteboardType) -> Data?) -> ClipboardFile? {
        let photosVideo = photosMediaType(data(Self.photosAssetType)) == 2
        var urls: [URL] = []
        for type in [NSPasteboard.PasteboardType.fileURL, .URL] {
            if let bytes = data(type), let value = String(data: bytes, encoding: .utf8),
               let url = URL(string: value), isLocalURL(url) { urls.append(url) }
        }
        let legacy = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        if let bytes = data(legacy), let paths = try? PropertyListSerialization.propertyList(from: bytes, options: [], format: nil) as? [String] {
            urls.append(contentsOf: paths.map { URL(fileURLWithPath: $0) })
        }
        let movie = urls.first(where: { isVideoURL($0) })
        guard photosVideo || movie != nil || types.contains(where: isVideoType) else { return nil }
        return ClipboardFile(id: id, name: movie?.lastPathComponent ?? "클립보드 동영상 \(index + 1)",
                             url: movie.flatMap {
                                 types.contains(Self.photosAssetType) && isPhotosLibraryURL($0) ? nil : $0
                             }, isHEIC: false, isVideo: true)
    }

    /// 로컬 파일의 public.url 표현도 원본 파일로 취급해 raw 포스터로 우회하지 못하게 한다.
    private func sourceFileURL(_ representations: [ClipboardRepresentation]) throws -> URL? {
        var result: URL?
        for representation in representations where representation.type == .fileURL || representation.type == .URL {
            guard let value = String(data: representation.data, encoding: .utf8), let url = URL(string: value) else {
                throw Failure.unsupportedRepresentation
            }
            guard representation.type == .fileURL || url.isFileURL else { continue }
            guard isLocalURL(url) else { throw Failure.unsupportedRepresentation }
            if let result, InputValidator.canonicalPath(result) != InputValidator.canonicalPath(url) {
                throw Failure.unsupportedRepresentation
            }
            result = url
        }
        return result
    }

    private func imageName(index: Int, type: NSPasteboard.PasteboardType) -> String {
        "클립보드 이미지 \(index + 1).\(isHEICType(type) ? "heic" : (UTType(type.rawValue)?.preferredFilenameExtension ?? "image"))"
    }

    /// worker는 출력 stem에 원자 저장용 접두사·무작위 이름·충돌 번호를 붙인다.
    /// 내부 입력명만 UTF-8 200바이트로 제한하고 원본 표시명과 복구 표현은 그대로 둔다.
    private func stagingInputName(_ original: String) -> String {
        let stem = URL(fileURLWithPath: original).deletingPathExtension().lastPathComponent
        var safeStem = ""
        var byteCount = 0
        for character in stem {
            let length = String(character).utf8.count
            guard byteCount + length <= 195 else { break }
            safeStem.append(character)
            byteCount += length
        }
        // 하나의 결합 문자 자체가 예산보다 길어도 worker가 사용할 유효한 이름을 만든다.
        return "\(safeStem.isEmpty ? "clipboard" : safeStem).heic"
    }

    /// HEIC 보조 이미지와 HDR gain map은 worker가 처리한다. 캡처에서 전체 픽셀을 디코딩하지 않는다.
    private func heicInputType(_ data: Data) throws -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              let type = CGImageSourceGetType(source) as String?,
              [UTType.heic.identifier, UTType.heif.identifier].contains(type),
              CGImageSourceGetCount(source) >= 1,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { throw Failure.invalidImage }
        return type
    }

    private func imageType(_ data: Data, allowed: [String]) throws -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              let type = CGImageSourceGetType(source) as String?, allowed.contains(type),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) != nil,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { throw Failure.invalidImage }
        return type
    }

    private func normalizedID(_ value: String) throws -> String {
        guard let uuid = UUID(uuidString: value), uuid.uuidString.caseInsensitiveCompare(value) == .orderedSame else {
            throw Failure.invalidJob
        }
        return uuid.uuidString
    }

    private func isLocalURL(_ url: URL) -> Bool {
        url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost")
            && url.query == nil && url.fragment == nil
            && !url.pathComponents.contains("..") && !url.pathComponents.contains(".")
    }

    // Foundation attributesOfItem은 xattr 조회를 포함한다. 파일 공급자 경로에는 사용하지 않는다.
    private func attributes(_ url: URL) -> stat? { metadataReader(url) }

    private func identityOf(_ url: URL) throws -> Identity {
        guard let metadata = attributes(url) else { throw Failure.unsafePath }
        return Identity(device: UInt64(UInt32(bitPattern: metadata.st_dev)), inode: UInt64(metadata.st_ino))
    }

    private func createDirectory(_ url: URL) throws {
        do { try files.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { throw Failure.directoryUnavailable }
        try validateDirectory(url, writable: true)
    }

    private func validateRoot(create: Bool) throws {
        guard isLocalURL(root), root.path != "/" else { throw Failure.invalidRoot }
        var ancestor = URL(fileURLWithPath: "/", isDirectory: true)
        for component in root.pathComponents.dropFirst() {
            ancestor.appendPathComponent(component, isDirectory: true)
            if let metadata = attributes(ancestor) {
                guard metadata.st_mode & S_IFMT == S_IFDIR else { throw Failure.invalidRoot }
            } else if create { try createDirectory(ancestor) }
            else { throw Failure.directoryUnavailable }
        }
        try validateDirectory(root, writable: create)
        guard let metadata = attributes(root), metadata.st_uid == getuid(),
              metadata.st_mode & 0o077 == 0 else { throw Failure.invalidRoot }
        let identity = try identityOf(root)
        if let rootIdentity { guard rootIdentity == identity else { throw Failure.invalidRoot } }
        else { rootIdentity = identity }
    }

    private func validateDirectory(_ directory: URL, writable: Bool = false) throws {
        guard let metadata = attributes(directory), metadata.st_mode & S_IFMT == S_IFDIR else {
            throw Failure.unsafePath
        }
        let permissions = metadata.st_mode
        guard permissions & 0o444 != 0, permissions & 0o111 != 0,
              Darwin.access(directory.path, R_OK | X_OK) == 0,
              !writable || (permissions & 0o222 != 0 && Darwin.access(directory.path, W_OK) == 0) else {
            throw Failure.directoryUnavailable
        }
    }

    private func validateJob(_ job: Job) throws {
        try validateRoot(create: false)
        try validateDirectory(job.directory)
        guard try identityOf(job.directory) == job.identity else { throw Failure.unsafePath }
    }

    private func validateSource(_ url: URL) throws {
        guard isLocalURL(url) else { throw Failure.unsafePath }
        // 원본 파일 자체의 링크는 거절하지만 읽기 전용 부모에는 macOS의 /var·/tmp 별칭을 허용한다.
        // 소유 폴더와 출력 경로 검증에는 이 정규화를 적용하지 않는다.
        try validateReadableFile(url)
        let parent = URL(fileURLWithPath: InputValidator.canonicalPath(url.deletingLastPathComponent()), isDirectory: true)
        try validateDirectory(parent)
    }

    private func validateReadableFile(_ url: URL) throws {
        guard let metadata = attributes(url), metadata.st_mode & S_IFMT == S_IFREG else { throw Failure.unsafePath }
        guard metadata.st_flags & UInt32(SF_DATALESS) == 0, metadata.st_mode & 0o444 != 0,
              Darwin.access(url.path, R_OK) == 0 else { throw Failure.fileUnavailable }
    }

    /// 실패 표시와 비HEIC 항목도 썸네일 때문에 Photos 원본이나 오프라인 파일을 읽지 않는다.
    private func safePreviewURL(_ url: URL, isPhotosItem: Bool) -> URL? {
        guard !isPhotosItem, (try? validateReadableFile(url)) != nil else { return nil }
        return url
    }

    private func validateResult(_ url: URL, directory: URL) throws {
        guard isLocalURL(url) else { throw Failure.unsafePath }
        try validateDirectory(directory)
        let base = directory.pathComponents
        let components = url.pathComponents
        guard components.count > base.count, Array(components.prefix(base.count)) == base else { throw Failure.unsafePath }
        var ancestor = directory
        for component in components.dropFirst(base.count).dropLast() {
            ancestor.appendPathComponent(component, isDirectory: true)
            try validateDirectory(ancestor)
        }
        try validateReadableFile(url)
    }

    private func readFile(_ url: URL) throws -> Data {
        // open 전에 dataless를 거절해 다운로드/물질화를 유발하지 않는다.
        try validateReadableFile(url)
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw Failure.fileUnavailable }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_flags & UInt32(SF_DATALESS) == 0 else { throw Failure.fileUnavailable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        do { return try handle.readToEnd() ?? Data() }
        catch { throw Failure.fileUnavailable }
    }

    private func removeJob(_ job: Job) -> Bool {
        guard (try? validateJob(job)) != nil else { return false }
        do { try files.removeItem(at: job.directory); return true }
        catch { return false }
    }

    /// 현재 모든 표현을 읽었을 때만 참조 부재를 판단한다. 파일 약속이 있으면 보수적으로 유지한다.
    private func cleanupUnreferenced() {
        let generation = pasteboard.changeCount
        // nil은 조회 오류다. 타입 목록이 있어도 참조 부재를 증명하지 못한다.
        guard let items = cleanupItemsReader(pasteboard) else { return }
        // 앞선 일반 항목이나 약속보다 먼저 선언된 URL도 provider를 실행할 수 있다.
        // 전체 타입을 먼저 검사하고, 참조 부재를 증명할 수 없으면 노출된 파일을 유지한다.
        guard !items.contains(where: { $0.types.contains(where: isUnsafeType) }) else { return }
        var references: [URL] = []
        for item in items {
            for type in item.types {
                guard !isUnsafeType(type), let data = item.data(forType: type) else { return }
                if type == .fileURL || type == .URL {
                    guard let value = String(data: data, encoding: .utf8), let url = URL(string: value) else { return }
                    if isLocalURL(url) { references.append(url) }
                    else if type == .fileURL || url.isFileURL { return }
                }
            }
        }
        cleanup(excluding: references, expected: generation)
    }

    private func cleanup(excluding references: [URL], expected: Int) {
        for (id, job) in Array(jobs) where job.exposed {
            guard pasteboard.changeCount == expected else { return }
            let referenced = references.contains { url in
                let reference = InputValidator.canonicalPath(url)
                let directory = InputValidator.canonicalPath(job.directory)
                // 작업 폴더 자체 또는 상위 폴더의 참조도 그 안의 게시 파일을 포함한다.
                return reference == directory || reference == "/"
                    || reference.hasPrefix(directory + "/") || directory.hasPrefix(reference + "/")
            }
            if !referenced, removeJob(job) { jobs.removeValue(forKey: id) }
        }
    }
}

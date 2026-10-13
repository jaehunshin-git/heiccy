import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 임시 변환 결과를 파일 참조가 아닌 이미지 데이터로 복사한다.
/// 초기화와 폴더 정리는 클립보드를 읽거나 수정하지 않는다.
@MainActor public final class ClipboardResultStore {
    private enum Failure: LocalizedError {
        case invalidJob, invalidRoot, unsafePath, directoryUnavailable, fileUnavailable
        case emptyResults, invalidImage, itemUnavailable, clipboardChanged, clipboardChangedWhileWriting, writeFailed, stopped

        var errorDescription: String? {
            switch self {
            case .invalidJob: return "클립보드 결과의 작업 ID는 UUID여야 하며, 이 인스턴스가 준비한 작업만 사용할 수 있습니다."
            case .invalidRoot: return "클립보드 결과의 임시 경로는 심볼릭 링크가 없는 로컬 폴더여야 합니다."
            case .unsafePath: return "클립보드 결과는 해당 작업 폴더 안의 일반 파일이어야 합니다. 심볼릭 링크와 외부 경로는 사용할 수 없습니다."
            case .directoryUnavailable: return "클립보드 결과 폴더를 만들거나 사용할 수 없습니다. 폴더와 쓰기 권한을 확인하세요."
            case .fileUnavailable: return "클립보드 결과 파일을 읽을 수 없습니다. 파일과 읽기 권한을 확인하세요."
            case .emptyResults: return "클립보드에 복사할 변환 결과가 없습니다."
            case .invalidImage: return "변환 결과가 올바른 PNG 또는 JPEG 이미지가 아닙니다. 기존 클립보드 내용은 유지됩니다."
            case .itemUnavailable: return "클립보드에 복사할 이미지 데이터를 준비하지 못했습니다. 기존 클립보드 내용은 유지됩니다."
            case .clipboardChanged: return "변환 중 클립보드가 변경되어 결과를 복사하지 않았습니다. 현재 클립보드 내용은 유지됩니다."
            case .clipboardChangedWhileWriting: return "이미지 복사 중 다른 앱이 클립보드를 변경했습니다. 현재 클립보드 내용은 유지됩니다."
            case .writeFailed: return "이미지를 클립보드에 쓰지 못했습니다. 클립보드가 비어 있을 수 있으니 다시 복사하세요."
            case .stopped: return "종료된 클립보드 결과 저장소는 사용할 수 없습니다."
            }
        }
    }

    // Foundation이 /var 별칭을 유지할 수 있으므로 존재하는 임시 폴더를 realpath로 확정한다.
    // 호출자가 넘긴 root에는 적용하지 않아 임의 심볼릭 링크를 계속 거절한다.
    private static let defaultRoot = URL(fileURLWithPath:
        InputValidator.canonicalPath(FileManager.default.temporaryDirectory), isDirectory: true)
        .appendingPathComponent("io.github.jaehunshin-git.heic-converter/ClipboardResults", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    private let pasteboard: NSPasteboard
    private let root: URL
    private let files: FileManager
    private var directories: [String: URL] = [:]
    private var stopped = false

    public init(pasteboard: NSPasteboard = .general, root: URL? = nil, fileManager: FileManager = FileManager()) {
        self.pasteboard = pasteboard
        self.root = root ?? Self.defaultRoot
        self.files = fileManager
    }

    /// 같은 작업의 미발행 폴더는 재사용하되, 기존 폴더를 새 작업의 소유로 인수하지 않는다.
    public func prepareDirectory(jobID: String) throws -> URL {
        guard !stopped else { throw Failure.stopped }
        let id = try normalizedID(jobID)
        try validateRoot(create: true)
        let directory = root.appendingPathComponent(id, isDirectory: true)
        if let owned = directories[id] {
            try validateDirectory(owned, writable: true)
            return owned
        }
        guard attributes(directory) == nil else { throw Failure.invalidJob }
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: false,
                                      attributes: [.posixPermissions: 0o700])
        } catch { throw Failure.directoryUnavailable }
        try validateDirectory(directory, writable: true)
        directories[id] = directory
        return directory
    }

    /// 모든 원문 데이터와 이미지 표현을 준비한 뒤에만 클립보드를 변경한다.
    /// 반환값은 이번 clearContents가 만든 게시 세대다. 정리 중 발생한 외부 변경은 포함하지 않는다.
    public func publish(jobID: String, urls: [URL], expectedChangeCount: Int) throws -> Int {
        guard !stopped else { throw Failure.stopped }
        let id = try normalizedID(jobID)
        guard let directory = directories[id] else { throw Failure.invalidJob }
        guard pasteboard.changeCount == expectedChangeCount else { throw Failure.clipboardChanged }
        guard !urls.isEmpty else { throw Failure.emptyResults }
        try validateRoot(create: false)
        try validateDirectory(directory)
        let items = try urls.map { url in
            try validateResult(url, directory: directory)
            return try imageItem(at: url)
        }
        // 파일 읽기와 이미지 디코딩 도중에 일어난 외부 복사도 보존한다.
        guard pasteboard.changeCount == expectedChangeCount else { throw Failure.clipboardChanged }
        let ownChangeCount = pasteboard.clearContents()
        let written = pasteboard.writeObjects(items)
        guard pasteboard.changeCount == ownChangeCount else { throw Failure.clipboardChangedWhileWriting }
        guard written else { throw Failure.writeFailed }
        // 모든 데이터가 클립보드 서버에 전달됐으므로 파일이 없어도 붙여넣을 수 있다.
        discard(jobID: id)
        return ownChangeCount
    }

    /// worker가 완전히 끝난 작업에 호출한다. 이 인스턴스가 준비한 폴더만 제거한다.
    public func discard(jobID: String) {
        guard !stopped, let id = try? normalizedID(jobID),
              let directory = directories[id] else { return }
        if removeManagedDirectory(directory) { directories.removeValue(forKey: id) }
    }

    /// 종료 중인 worker와의 경합을 피하기 위해 미완료 폴더를 직접 삭제하지 않는다.
    public func shutdown() { stopped = true }

    private func normalizedID(_ jobID: String) throws -> String {
        guard let uuid = UUID(uuidString: jobID), uuid.uuidString.caseInsensitiveCompare(jobID) == .orderedSame else {
            throw Failure.invalidJob
        }
        return uuid.uuidString
    }

    private func isLocalURL(_ url: URL) -> Bool {
        url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost")
            && url.query == nil && url.fragment == nil
            && !url.pathComponents.contains("..") && !url.pathComponents.contains(".")
    }

    private func attributes(_ url: URL) -> [FileAttributeKey: Any]? {
        try? files.attributesOfItem(atPath: url.path)
    }

    /// 상위 경로까지 확인해 심볼릭 링크를 통한 외부 폴더 접근을 거절한다.
    private func validateRoot(create: Bool) throws {
        guard isLocalURL(root), root.path != "/" else { throw Failure.invalidRoot }
        var ancestor = URL(fileURLWithPath: "/", isDirectory: true)
        for component in root.pathComponents.dropFirst() {
            ancestor.appendPathComponent(component, isDirectory: true)
            if let metadata = attributes(ancestor) {
                guard metadata[.type] as? FileAttributeType == .typeDirectory else { throw Failure.invalidRoot }
            } else if create {
                do {
                    try files.createDirectory(at: ancestor, withIntermediateDirectories: false,
                                              attributes: [.posixPermissions: 0o700])
                } catch { throw Failure.directoryUnavailable }
            } else { throw Failure.directoryUnavailable }
        }
        try validateDirectory(root, writable: create)
    }

    private func validateDirectory(_ directory: URL, writable: Bool = false) throws {
        guard let metadata = attributes(directory), metadata[.type] as? FileAttributeType == .typeDirectory else {
            throw Failure.unsafePath
        }
        let permissions = (metadata[.posixPermissions] as? NSNumber)?.intValue ?? 0
        guard permissions & 0o444 != 0, permissions & 0o111 != 0,
              files.isReadableFile(atPath: directory.path), files.isExecutableFile(atPath: directory.path),
              !writable || (permissions & 0o222 != 0 && files.isWritableFile(atPath: directory.path)) else {
            throw Failure.directoryUnavailable
        }
    }

    private func validateResult(_ url: URL, directory: URL) throws {
        guard isLocalURL(url) else { throw Failure.unsafePath }
        // 준비한 경로를 다시 표준화하면 /private가 사라질 수 있다. 검증된 원 경로를 비교한다.
        let base = directory.pathComponents
        let components = url.pathComponents
        guard components.count > base.count, Array(components.prefix(base.count)) == base else { throw Failure.unsafePath }
        var candidate = directory
        for component in components.dropFirst(base.count).dropLast() {
            candidate.appendPathComponent(component, isDirectory: true)
            try validateDirectory(candidate)
        }
        guard let metadata = attributes(url), metadata[.type] as? FileAttributeType == .typeRegular else {
            throw Failure.unsafePath
        }
        let permissions = (metadata[.posixPermissions] as? NSNumber)?.intValue ?? 0
        guard permissions & 0o444 != 0, files.isReadableFile(atPath: url.path) else { throw Failure.fileUnavailable }
    }

    private func imageItem(at url: URL) throws -> NSPasteboardItem {
        let data: Data
        // 메모리 매핑이나 지연 제공자를 사용하지 않아 임시 파일 삭제와 수명을 분리한다.
        do { data = try Data(contentsOf: url) }
        catch { throw Failure.fileUnavailable }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              let sourceType = CGImageSourceGetType(source) else { throw Failure.invalidImage }
        let type: NSPasteboard.PasteboardType
        switch sourceType as String {
        case UTType.png.identifier: type = .png
        case UTType.jpeg.identifier: type = NSPasteboard.PasteboardType(UTType.jpeg.identifier)
        default: throw Failure.invalidImage
        }
        guard CGImageSourceCreateImageAtIndex(source, 0,
                    [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) != nil,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let image = NSImage(data: data), image.isValid else { throw Failure.invalidImage }
        let item = NSPasteboardItem()
        guard item.setData(data, forType: type) else { throw Failure.itemUnavailable }
        if let tiff = image.tiffRepresentation {
            guard item.setData(tiff, forType: .tiff) else { throw Failure.itemUnavailable }
        }
        return item
    }

    private func removeManagedDirectory(_ directory: URL) -> Bool {
        guard (try? validateRoot(create: false)) != nil,
              InputValidator.canonicalPath(directory.deletingLastPathComponent()) == InputValidator.canonicalPath(root) else { return false }
        if attributes(directory) == nil { return !files.fileExists(atPath: directory.path) }
        guard (try? validateDirectory(directory)) != nil else { return false }
        do { try files.removeItem(at: directory); return true }
        catch { return false }
    }
}

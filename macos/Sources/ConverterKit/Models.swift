import Foundation
import Darwin

public struct ConversionOptions: Codable, Equatable {
    public var outputFormat = "jpeg"
    public var jpegQuality = 90
    public var pngCompression = 6
    public var metadata = "safe"
    public var onConflict = "rename"
    public var qualityPreset: QualityPreset {
        get { QualityPreset.nearest(to: jpegQuality) }
        set { jpegQuality = newValue.jpegQuality }
    }
    public var pngCompressionPreset: PNGCompressionPreset {
        get { PNGCompressionPreset.nearest(to: pngCompression) }
        set { pngCompression = newValue.compressionLevel }
    }
    public init() {}
    enum CodingKeys: String, CodingKey {
        case outputFormat = "output_format", jpegQuality = "jpeg_quality"
        case pngCompression = "png_compression", metadata, onConflict = "on_conflict"
    }
}

public struct AppSettings: Codable, Equatable {
    public var options = ConversionOptions()
    public var clipboardEnabled = true
    public var outputDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Pictures/HEIC Converter").path
    public var displayOutputDirectory: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if outputDirectory == home { return "~" }
        if outputDirectory.hasPrefix(home + "/") {
            return "~" + outputDirectory.dropFirst(home.count)
        }
        return outputDirectory
    }
    public init() {}
    public static func load(from defaults: UserDefaults = .standard) -> AppSettings {
        guard let data = defaults.data(forKey: "converter.settings"),
              var value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        let validationDirectories = [
            "/private/tmp/heic-converter-ui-check/converted",
            "/tmp/heic-converter-ui-check/converted",
        ]
        if validationDirectories.contains(value.outputDirectory) {
            value.outputDirectory = Self().outputDirectory
            value.save(to: defaults)
        }
        return value
    }
    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: "converter.settings") }
    }
}

public enum FileStatus: String { case waiting, scheduled, running, succeeded, skipped, failed
    public var label: String {
        switch self {
        case .waiting: return "대기"
        case .scheduled: return "예약"
        case .running: return "변환 중"
        case .succeeded: return "성공"
        case .skipped: return "건너뜀"
        case .failed: return "실패"
        }
    }
    public var finished: Bool { self == .succeeded || self == .skipped }
    public var locked: Bool { self == .scheduled || self == .running }
}

public struct FileItem: Identifiable {
    public let id: String
    public let url: URL
    public var status: FileStatus = .waiting
    public var detail: String?
    public var destination: String?
    public var conversionDestination: ConversionDestination = .files
    public init(url: URL) { self.url = url; self.id = url.path }
}

public struct InputRejection: Equatable {
    public let path: String
    public let reason: String
    public init(path: String, reason: String) { self.path = path; self.reason = reason }
}

public enum InputValidator {
    public static func canonicalPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
    public static func validate(_ urls: [URL], excluding: Set<String> = []) -> (accepted: [URL], rejected: [InputRejection]) {
        var paths = excluding
        var accepted: [URL] = []
        var rejected: [InputRejection] = []
        for url in urls {
            var reason: String?
            var canonical = url.standardizedFileURL
            if !url.isFileURL || (url.host != nil && url.host != "" && url.host != "localhost") {
                reason = "로컬 파일 URL만 지원합니다."
            } else if url.pathExtension.lowercased() != "heic" {
                reason = "확장자가 .heic인 파일만 지원합니다."
            } else {
                do {
                    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                    if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                        reason = "심볼릭 링크는 지원하지 않습니다."
                    } else if attributes[.type] as? FileAttributeType != .typeRegular {
                        reason = "폴더가 아닌 일반 파일을 선택하세요."
                    } else if !FileManager.default.isReadableFile(atPath: url.path) {
                        reason = "파일 읽기 권한이 없습니다."
                    } else {
                        canonical = URL(fileURLWithPath: canonicalPath(canonical))
                        if paths.contains(canonical.path) { reason = "이미 목록에 있는 파일입니다." }
                    }
                } catch { reason = "파일이 없거나 읽을 수 없습니다: \(error.localizedDescription)" }
            }
            if let reason { rejected.append(InputRejection(path: url.path, reason: reason)) }
            else { accepted.append(canonical); paths.insert(canonical.path) }
        }
        return (accepted, rejected)
    }
}

public enum ConversionDestination: String { case files, clipboard }

public struct ConversionJob {
    public let id: String
    public let files: [String]
    public let outputDirectory: String
    public let options: ConversionOptions
    public let destination: ConversionDestination
    public init(id: String = UUID().uuidString, files: [String], settings: AppSettings, destination: ConversionDestination = .files) {
        self.id = id
        self.files = files; outputDirectory = settings.outputDirectory; options = settings.options
        self.destination = destination
    }
}

public struct QueueState {
    public var items: [FileItem] = []
    public private(set) var jobs: [ConversionJob] = []
    public private(set) var activeJob: ConversionJob?
    public init() {}
    public var knownPaths: Set<String> { Set(items.map(\.id)) }
    public var waitingCount: Int { items.filter { $0.status == .waiting || $0.status == .scheduled }.count }
    public mutating func add(_ urls: [URL]) {
        var known = knownPaths
        for url in urls where !known.contains(url.path) { items.append(FileItem(url: url)); known.insert(url.path) }
    }
    public mutating func schedule(paths: [String], settings: AppSettings, destination: ConversionDestination = .files) {
        let selected = items.filter { paths.contains($0.id) && ($0.status == .waiting || $0.status == .failed) }.map(\.id)
        guard !selected.isEmpty else { return }
        for index in items.indices where selected.contains(items[index].id) {
            items[index].status = .scheduled; items[index].detail = nil
            items[index].destination = nil; items[index].conversionDestination = destination
        }
        jobs.append(ConversionJob(files: selected, settings: settings, destination: destination))
    }
    public mutating func next() -> ConversionJob? {
        guard activeJob == nil, !jobs.isEmpty else { return nil }
        activeJob = jobs.removeFirst()
        return activeJob
    }
    public mutating func update(path: String, status: FileStatus, detail: String? = nil, destination: String? = nil) {
        guard let index = items.firstIndex(where: { $0.id == path }) else { return }
        items[index].status = status; items[index].detail = detail; items[index].destination = destination
    }
    public mutating func finish() {
        if let job = activeJob {
            // 완료 항목을 제거한 뒤 같은 파일을 다시 예약했으면 새 작업의 잠금을 유지한다.
            let pendingPaths = Set(jobs.flatMap(\.files))
            for index in items.indices where job.files.contains(items[index].id)
                && items[index].status.locked && !pendingPaths.contains(items[index].id) {
                items[index].status = .waiting
            }
        }
        activeJob = nil
    }
    /// 작업 자체의 오류는 후속 예약과 그 설정 스냅샷에 영향을 주지 않는다.
    public mutating func failCurrentJob(_ message: String) {
        if let job = activeJob {
            let pendingPaths = Set(jobs.flatMap(\.files))
            for index in items.indices where job.files.contains(items[index].id) && items[index].status.locked {
                guard !pendingPaths.contains(items[index].id) else { continue }
                items[index].status = .failed; items[index].detail = message
            }
        }
        activeJob = nil
    }
    public mutating func failActive(_ message: String) {
        failCurrentJob(message)
        // worker 장애 이후 예약 작업은 사용자가 다시 시작할 수 있도록 돌려놓는다.
        jobs.removeAll()
        for index in items.indices where items[index].status == .scheduled { items[index].status = .waiting }
    }
    public mutating func remove(_ path: String) { removeSelected([path]) }
    /// 목록 항목만 제거한다. 실행 중이거나 예약된 항목과 작업 스냅샷은 보존한다.
    public mutating func removeSelected(_ ids: Set<String>) {
        items.removeAll { ids.contains($0.id) && !$0.status.locked }
    }
    public mutating func removeAll() { items.removeAll { !$0.status.locked } }
    public mutating func clearCompleted() { items.removeAll { $0.status.finished } }
}

public struct ClipboardGate {
    public private(set) var lastChange: Int
    public private(set) var denied = false
    public init(changeCount: Int) { lastChange = changeCount }
    public mutating func resume(changeCount: Int) { lastChange = changeCount; denied = false }
    public mutating func shouldRead(changeCount: Int, enabled: Bool, accessDenied: Bool) -> Bool {
        guard enabled, !denied else { return false }
        if accessDenied { denied = true; lastChange = changeCount; return false }
        guard changeCount != lastChange else { return false }
        lastChange = changeCount
        return true
    }
}

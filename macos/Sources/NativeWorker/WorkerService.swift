import Foundation
import CoreFoundation
import Darwin

private enum WorkerServiceError: LocalizedError {
    case validation(String)
    case system(Int32, String)
    case conflict(String)

    var errorDescription: String? {
        switch self {
        case .validation(let message), .conflict(let message): return message
        case .system(let code, let path):
            switch code {
            case ENOENT: return "파일을 찾을 수 없습니다: \(path)"
            case ENOTDIR: return "경로의 상위 항목은 디렉터리여야 합니다: \(path)"
            case EACCES, EPERM: return "경로에 접근할 권한이 없습니다: \(path)"
            case ELOOP: return "심볼릭 링크 경로를 확인할 수 없습니다: \(path)"
            default: return "파일 경로를 확인하지 못했습니다 (코드 \(code)): \(path)"
            }
        }
    }
}

/// JSON의 true와 1.0을 정수로 허용하지 않는다. Python의 type(value) is int와 같다.
private func jsonInteger(_ value: Any?) -> NSNumber? {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID(),
          !["d", "f"].contains(String(cString: number.objCType)) else { return nil }
    return number
}

private struct WorkerOptions {
    let native: NativeOptions
    let onConflict: String

    init(_ values: [String: Any]) throws {
        let allowed: Set<String> = ["output_format", "jpeg_quality", "png_compression", "metadata", "on_conflict"]
        guard Set(values.keys).isSubset(of: allowed) else {
            throw WorkerServiceError.validation("지원하지 않는 변환 옵션입니다.")
        }
        func choice(_ key: String, default fallback: String, choices: Set<String>, message: String) throws -> String {
            guard let value = (values[key] ?? fallback) as? String else {
                throw WorkerServiceError.validation(message)
            }
            let folded = value.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            guard choices.contains(folded) else { throw WorkerServiceError.validation(message) }
            return folded
        }
        func integer(_ key: String, default fallback: Int, range: ClosedRange<Int>, message: String) throws -> Int {
            guard let value = jsonInteger(values[key] ?? fallback),
                  value.doubleValue >= Double(range.lowerBound),
                  value.doubleValue <= Double(range.upperBound) else {
                throw WorkerServiceError.validation(message)
            }
            return value.intValue
        }
        let format = try choice("output_format", default: "jpeg", choices: ["jpeg", "png"],
                                message: "--format 값은 jpeg 또는 png여야 합니다.")
        let metadata = try choice("metadata", default: "safe", choices: ["safe", "preserve", "strip"],
                                  message: "--metadata 값은 safe, preserve, strip 중 하나여야 합니다.")
        onConflict = try choice("on_conflict", default: "rename", choices: ["rename", "skip", "overwrite", "error"],
                                message: "--on-conflict 값은 rename, skip, overwrite, error 중 하나여야 합니다.")
        let quality = try integer("jpeg_quality", default: 90, range: 1...100,
                                  message: "--jpeg-quality 값은 1에서 100 사이여야 합니다.")
        let compression = try integer("png_compression", default: 6, range: 0...9,
                                      message: "--png-compression 값은 0에서 9 사이여야 합니다.")
        native = NativeOptions(outputFormat: format, jpegQuality: quality, pngCompression: compression,
                               metadata: metadata, overwrite: onConflict == "overwrite")
    }
}

/// Path(path)의 점·중복 구분자 제거만 적용한다. ..는 링크 해석 뒤에 처리한다.
private func localPath(_ path: String) throws -> String {
    guard !path.utf8.contains(0) else { throw WorkerServiceError.validation("경로에 NUL 문자를 사용할 수 없습니다.") }
    let parts = path.split(separator: "/").filter { $0 != "." }
    return "/" + parts.joined(separator: "/")
}

private func fileInfo(_ path: String, followingLinks: Bool = true) throws -> stat {
    var info = stat()
    let result = path.withCString {
        Darwin.fstatat(AT_FDCWD, $0, &info, followingLinks ? 0 : AT_SYMLINK_NOFOLLOW)
    }
    guard result == 0 else { throw WorkerServiceError.system(errno, path) }
    return info
}

private func isRegularFile(_ path: String) -> Bool {
    guard let info = try? fileInfo(path) else { return false }
    return info.st_mode & S_IFMT == S_IFREG
}

private func entryExists(_ path: String) -> Bool {
    // lstat는 끊어진 심볼릭 링크도 기존 목적지로 인식한다.
    (try? fileInfo(path, followingLinks: false)) != nil
}

/// fileURLWithPath는 macOS에서 한글을 NFD로 바꾼다. JSON 경로의 원문을 보존한다.
private func pathURL(_ path: String) throws -> URL {
    var components = URLComponents()
    components.scheme = "file"
    components.host = ""
    components.path = path
    guard let url = components.url else { throw WorkerServiceError.validation("로컬 경로를 확인할 수 없습니다: \(path)") }
    return url
}

private func childURL(_ parent: URL, _ name: String) throws -> URL {
    try pathURL((parent.path == "/" ? "" : parent.path) + "/" + name)
}

/// 존재하지 않는 출력 폴더도 /tmp 등의 부모 별칭과 끊어진 링크를 해석한다.
private func resolvedURL(_ path: String) throws -> URL {
    var pending = path.split(separator: "/").map(String.init)[...]
    var resolved: [String] = []
    var links = 0
    while let component = pending.popFirst() {
        if component == "." { continue }
        if component == ".." { if !resolved.isEmpty { resolved.removeLast() }; continue }
        let candidate = "/" + (resolved + [component]).joined(separator: "/")
        do {
            let info = try fileInfo(candidate, followingLinks: false)
            if info.st_mode & S_IFMT == S_IFLNK {
                links += 1
                guard links <= 40 else { throw WorkerServiceError.system(ELOOP, candidate) }
                var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
                let count = candidate.withCString { Darwin.readlink($0, &buffer, buffer.count) }
                guard count >= 0 else { throw WorkerServiceError.system(errno, candidate) }
                guard count < buffer.count else { throw WorkerServiceError.system(ENAMETOOLONG, candidate) }
                let target = String(decoding: buffer.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                if target.hasPrefix("/") { resolved.removeAll() }
                pending = (target.split(separator: "/").map(String.init) + Array(pending))[...]
                continue
            }
        } catch WorkerServiceError.system(let code, _) where code == ENOENT || code == ENOTDIR {
            // Python Path.resolve(strict=False)와 같이 아직 없는 경로도 준비할 수 있다.
        }
        resolved.append(component)
    }
    return try pathURL("/" + resolved.joined(separator: "/"))
}

private func validateFile(_ original: String) throws -> URL {
    let path = try localPath(original)
    let info = try fileInfo(path, followingLinks: false)
    guard info.st_mode & S_IFMT != S_IFLNK else {
        throw WorkerServiceError.validation("심볼릭 링크는 입력할 수 없습니다.")
    }
    guard info.st_mode & S_IFMT == S_IFREG else {
        throw WorkerServiceError.validation("로컬 일반 파일만 입력할 수 있습니다.")
    }
    let name = (path as NSString).lastPathComponent
    guard let dot = name.lastIndex(of: "."), dot != name.startIndex,
          name[name.index(after: dot)...].lowercased() == "heic" else {
        throw WorkerServiceError.validation(".heic 파일만 입력할 수 있습니다.")
    }
    guard Darwin.access(path, R_OK) == 0 else {
        throw WorkerServiceError.system(EACCES, "입력 파일을 읽을 권한이 없습니다: \(path)")
    }
    return try resolvedURL(path)
}

private struct NaturalKey {
    enum Part {
        case text([UInt32])
        case number(String)
    }
    let original: [UInt32]
    let parts: [Part]

    init(_ path: String) {
        let normalized = path.precomposedStringWithCanonicalMapping
        original = normalized.unicodeScalars.map(\.value)
        let folded = normalized.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        var tokens: [Part] = []
        var text: [UInt32] = []
        var digits = ""
        for scalar in folded.unicodeScalars {
            if scalar.properties.numericType == .decimal,
               let value = Character(String(scalar)).wholeNumberValue {
                if digits.isEmpty { tokens.append(.text(text)); text.removeAll() }
                digits.append(String(value))
            } else {
                if !digits.isEmpty {
                    tokens.append(.number(Self.trimZeros(digits))); digits = ""
                }
                text.append(scalar.value)
            }
        }
        if !digits.isEmpty { tokens.append(.number(Self.trimZeros(digits))) }
        tokens.append(.text(text))
        parts = tokens
    }

    private static func trimZeros(_ digits: String) -> String {
        let trimmed = digits.drop(while: { $0 == "0" })
        return trimmed.isEmpty ? "0" : String(trimmed)
    }

    func precedes(_ other: NaturalKey) -> Bool {
        for (left, right) in zip(parts, other.parts) {
            switch (left, right) {
            case (.text(let a), .text(let b)):
                if a != b { return a.lexicographicallyPrecedes(b) }
            case (.number(let a), .number(let b)):
                if a.count != b.count { return a.count < b.count }
                if a != b { return a < b }
            case (.text, .number): return true
            case (.number, .text): return false
            }
        }
        if parts.count != other.parts.count { return parts.count < other.parts.count }
        return original.lexicographicallyPrecedes(other.original)
    }
}

private struct PreparedNativeJob {
    let files: [URL]
    let outputDirectory: URL
    let options: WorkerOptions
    let rejected: [[String: String]]

    init(files: [String], output: String, options: WorkerOptions) throws {
        outputDirectory = try resolvedURL(localPath(output))
        if let info = try? fileInfo(outputDirectory.path), info.st_mode & S_IFMT != S_IFDIR {
            throw WorkerServiceError.validation("출력 경로는 디렉터리여야 합니다: \(try localPath(output))")
        }
        self.options = options
        var accepted: [String: URL] = [:]
        var rejected: [[String: String]] = []
        for source in files {
            do {
                let file = try validateFile(source)
                guard accepted[file.path] == nil else { throw WorkerServiceError.validation("이미 입력한 파일입니다.") }
                accepted[file.path] = file
            } catch {
                rejected.append(["source": (try? localPath(source)) ?? source, "reason": error.localizedDescription])
            }
        }
        self.files = accepted.values.map { ($0, NaturalKey($0.path)) }
            .sorted { $0.1.precedes($1.1) }.map(\.0)
        self.rejected = rejected
    }
}

final class WorkerCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

/// 복제한 stdout만 사용한다. fd 1의 코덱 진단은 main에서 stderr로 보낸다.
final class WorkerJSONOutput: @unchecked Sendable {
    private let output: FileHandle
    private let lock = NSLock()

    init(fileDescriptor: Int32) { output = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true) }

    func send(event: String, jobID: String?, fields: [String: Any]) -> Bool {
        var message = fields
        message["protocol_version"] = 1
        message["job_id"] = jobID.map { $0 as Any } ?? NSNull()
        message["event"] = event
        lock.lock(); defer { lock.unlock() }
        do {
            var data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys, .withoutEscapingSlashes])
            data.append(10)
            try output.write(contentsOf: data)
            return true
        } catch { return false }
    }
}

/// 상태 잠금은 요청·최종 이벤트에만 사용하며 변환 중에도 취소 요청을 읽는다.
final class WorkerService: @unchecked Sendable {
    private let output: WorkerJSONOutput
    private let stateLock = NSLock()
    private let conversionQueue = DispatchQueue(label: "heiccy.worker.conversion")
    private let runningGroup = DispatchGroup()
    private let shutdown = WorkerCancellation()
    private var job: PreparedNativeJob?
    private var jobID: String?
    private var lastFinishedJobID: String?
    private var running = false
    private var inputClosed = false
    private var cancellation = WorkerCancellation()

    init(output: WorkerJSONOutput) { self.output = output }
    var isClosing: Bool { shutdown.isCancelled }

    private func send(_ event: String, _ id: String?, _ fields: [String: Any]) {
        if !output.send(event: event, jobID: id, fields: fields) { shutdown.cancel() }
    }

    private func error(_ id: String?, _ code: String, _ message: String) {
        send("error", id, ["error_code": code, "message": message])
    }

    func handle(_ line: Data) {
        var id: String?
        do {
            guard String(data: line, encoding: .utf8) != nil else {
                throw WorkerServiceError.validation("요청은 UTF-8 JSON이어야 합니다.")
            }
            let parsed: Any
            do { parsed = try JSONSerialization.jsonObject(with: line, options: [.fragmentsAllowed]) }
            catch { throw WorkerServiceError.validation("요청의 JSON 형식이 올바르지 않습니다.") }
            guard let request = parsed as? [String: Any] else {
                throw WorkerServiceError.validation("요청은 JSON 객체여야 합니다.")
            }
            id = request["job_id"] as? String
            guard let id, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WorkerServiceError.validation("비어 있지 않은 job_id가 필요합니다.")
            }
            guard let version = jsonInteger(request["protocol_version"]), version == NSNumber(value: 1) else {
                error(id, "protocol_mismatch", "지원하지 않는 프로토콜 버전입니다.")
                return
            }
            stateLock.lock(); defer { stateLock.unlock() }
            guard !inputClosed, !isClosing else { return }
            switch request["command"] as? String {
            case "prepare":
                guard !running else { error(id, "busy", "이미 실행 중인 작업이 있습니다."); return }
                guard let files = request["files"] as? [String], files.allSatisfy({ !$0.isEmpty }) else {
                    throw WorkerServiceError.validation("files는 로컬 경로 문자열 배열이어야 합니다.")
                }
                guard let output = request["output_directory"] as? String, !output.isEmpty else {
                    throw WorkerServiceError.validation("output_directory 경로가 필요합니다.")
                }
                guard output.hasPrefix("/"), files.allSatisfy({ $0.hasPrefix("/") }) else {
                    throw WorkerServiceError.validation("worker의 입력과 출력은 절대 경로여야 합니다.")
                }
                guard let values = (request["options"] ?? [String: Any]()) as? [String: Any] else {
                    throw WorkerServiceError.validation("options는 JSON 객체여야 합니다.")
                }
                let prepared = try PreparedNativeJob(files: files, output: output, options: WorkerOptions(values))
                job = prepared; jobID = id; cancellation = WorkerCancellation()
                send("prepared", id, ["files": prepared.files.map(\.path), "rejected": prepared.rejected,
                                      "total": prepared.files.count])
            case "run", "cancel":
                let command = request["command"] as? String
                guard let prepared = job, jobID == id else {
                    if command == "cancel", id == lastFinishedJobID { return }
                    error(id, "unknown_job", "준비한 작업을 찾을 수 없습니다.")
                    return
                }
                if command == "cancel" {
                    cancellation.cancel()
                    if !running { cancelPrepared(prepared, id: id) }
                } else if running {
                    error(id, "busy", "이미 실행 중인 작업이 있습니다.")
                } else {
                    running = true
                    let token = cancellation
                    runningGroup.enter()
                    conversionQueue.async { [self] in
                        defer { runningGroup.leave() }
                        runBatch(prepared, id: id, token: token)
                    }
                }
            default:
                throw WorkerServiceError.validation("command는 prepare, run, cancel 중 하나여야 합니다.")
            }
        } catch { self.error(id, "invalid_request", error.localizedDescription) }
    }

    /// EOF는 접수만 닫고 작업을 끝까지 처리한다. 종료 신호만 다음 파일을 중단한다.
    func closeInput(cancel: Bool = false) {
        if cancel { shutdown.cancel() }
        stateLock.lock(); defer { stateLock.unlock() }
        inputClosed = true
        if cancel { cancellation.cancel() }
    }

    func finish() { runningGroup.wait() }

    private func cancelPrepared(_ prepared: PreparedNativeJob, id: String) {
        job = nil; jobID = nil; lastFinishedJobID = id
        send("cancelled", id, ["succeeded": 0, "skipped": 0, "failed": 0,
                               "total": prepared.files.count, "remaining": prepared.files.map(\.path)])
    }

    private func chooseDestination(_ proposed: URL, policy: String, reserved: inout Set<String>) throws -> URL? {
        if !entryExists(proposed.path), !reserved.contains(proposed.path) {
            reserved.insert(proposed.path); return proposed
        }
        switch policy {
        case "skip": return nil
        case "error": throw WorkerServiceError.conflict("이미 출력 파일이 있습니다: \(proposed.path)")
        case "overwrite": reserved.insert(proposed.path); return proposed
        default:
            let parent = proposed.deletingLastPathComponent()
            let stem = proposed.deletingPathExtension().lastPathComponent
            var number = 2
            while true {
                let candidate = try childURL(parent, "\(stem)-\(number).\(proposed.pathExtension)")
                if !entryExists(candidate.path), !reserved.contains(candidate.path) {
                    reserved.insert(candidate.path); return candidate
                }
                number += 1
            }
        }
    }

    private func isAtomicConflict(_ error: Error, destination: URL) -> Bool {
        if let native = error as? NativeConversionError, case .conflict = native { return true }
        // 일반 EEXIST는 실제 목적지가 있을 때만 원자 저장 경합으로 처리한다.
        return systemCode(error) == EEXIST && entryExists(destination.path)
    }

    private func systemCode(_ error: Error) -> Int32? {
        if case WorkerServiceError.system(let code, _) = error { return code }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain { return Int32(exactly: ns.code) }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying !== ns,
           let code = systemCode(underlying) { return code }
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError: return ENOENT
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError: return EACCES
            case NSFileWriteFileExistsError: return EEXIST
            default: break
            }
        }
        return nil
    }

    private func errorCode(_ error: Error, source: URL, output: URL) -> String {
        switch systemCode(error) {
        case ENOTDIR: return isRegularFile(source.path) ? "output_unavailable" : "input_missing"
        case ENOENT: return (try? fileInfo(source.path)) == nil ? "input_missing" : "output_unavailable"
        case EACCES, EPERM: return Darwin.access(source.path, R_OK) == 0 ? "output_permission" : "input_permission"
        case EEXIST:
            // createDirectory가 부모 파일에 대해 반환한 EEXIST는 이름 경합이 아니다.
            if let info = try? fileInfo(output.path), info.st_mode & S_IFMT != S_IFDIR { return "output_unavailable" }
            return "name_conflict"
        default: break
        }
        if let service = error as? WorkerServiceError {
            switch service {
            case .validation: return "invalid_input"
            case .conflict: return "name_conflict"
            case .system: return "conversion_failed"
            }
        }
        if let native = error as? NativeConversionError, case .conflict = native { return "name_conflict" }
        // 코덱의 invalid는 손상된 이미지다. 서비스의 파일 입력 검증 오류와 구분한다.
        return "conversion_failed"
    }

    private func runBatch(_ prepared: PreparedNativeJob, id: String, token: WorkerCancellation) {
        var succeeded = 0, skipped = 0, failed = 0, processed = 0
        var reserved: Set<String> = []
        for (offset, source) in prepared.files.enumerated() {
            if token.isCancelled || shutdown.isCancelled { break }
            let fields: [String: Any] = ["source": source.path, "index": offset + 1, "total": prepared.files.count]
            send("file_started", id, fields)
            do {
                _ = try validateFile(source.path)
                let filename = source.deletingPathExtension().lastPathComponent
                    + (prepared.options.native.outputFormat == "jpeg" ? ".jpeg" : ".png")
                let proposed = try childURL(prepared.outputDirectory, filename)
                while true {
                    guard let destination = try chooseDestination(proposed, policy: prepared.options.onConflict, reserved: &reserved) else {
                        skipped += 1
                        var event = fields; event["reason"] = "같은 이름의 출력 파일이 있습니다."
                        send("file_skipped", id, event)
                        break
                    }
                    let result: NativeConversionResult
                    do {
                        result = try autoreleasepool {
                            try NativeConverter.convert(source: source, destination: destination, options: prepared.options.native)
                        }
                    } catch {
                        reserved.remove(destination.path)
                        guard isAtomicConflict(error, destination: destination) else { throw error }
                        if prepared.options.onConflict == "rename" {
                            continue
                        }
                        if prepared.options.onConflict == "skip" {
                            skipped += 1
                            var event = fields; event["reason"] = "저장 중 같은 이름의 파일이 생성되었습니다."
                            send("file_skipped", id, event)
                            break
                        }
                        throw error
                    }
                    succeeded += 1
                    var event = fields
                    event["destination"] = destination.path
                    event["hdr_applied"] = result.hdrApplied
                    event["sdr_reason"] = result.sdrReason.map { $0 as Any } ?? NSNull()
                    send("file_succeeded", id, event)
                    break
                }
            } catch {
                failed += 1
                var event = fields
                event["error"] = error.localizedDescription
                event["error_code"] = errorCode(error, source: source, output: prepared.outputDirectory)
                send("file_failed", id, event)
            }
            processed = offset + 1
        }
        let remaining = prepared.files.dropFirst(processed).map(\.path)
        let cancelled = !remaining.isEmpty && (token.isCancelled || shutdown.isCancelled)
        // 상태를 먼저 비운 후 잠금 안에서 최종 이벤트를 써 즉시 다음 prepare를 허용한다.
        stateLock.lock(); defer { stateLock.unlock() }
        job = nil; jobID = nil; running = false; lastFinishedJobID = id
        send(cancelled ? "cancelled" : "completed", id,
             ["succeeded": succeeded, "skipped": skipped, "failed": failed,
              "total": prepared.files.count, "remaining": remaining])
    }
}

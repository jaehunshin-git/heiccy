import Foundation

public struct WorkerRequest: Encodable {
    public let protocolVersion = 1
    public let jobID: String
    public let command: String
    public var files: [String]?
    public var outputDirectory: String?
    public var options: ConversionOptions?
    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version", jobID = "job_id", command, files
        case outputDirectory = "output_directory", options
    }
    public init(command: String, job: ConversionJob, outputDirectory: String? = nil) {
        self.command = command; jobID = job.id
        if command == "prepare" { files = job.files; self.outputDirectory = outputDirectory ?? job.outputDirectory; options = job.options }
    }
    public func line() throws -> Data { var data = try JSONEncoder().encode(self); data.append(10); return data }
}

public struct WorkerEvent: Decodable {
    public let protocolVersion: Int
    public let jobID: String
    public let event: String
    public let files: [String]?
    public let rejected: [RejectedFile]?
    public let source: String?
    public let destination: String?
    public let index: Int?
    public let total: Int?
    public let error: String?
    public let errorCode: String?
    public let message: String?
    public let hdrApplied: Bool?
    public let sdrReason: String?
    public let succeeded: Int?
    public let skipped: Int?
    public let failed: Int?
    public let remaining: [String]?
    public struct RejectedFile: Decodable { public let source: String; public let reason: String }
    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version", jobID = "job_id", event, files, rejected, source, destination, index, total, error
        case errorCode = "error_code", message, hdrApplied = "hdr_applied", sdrReason = "sdr_reason"
        case succeeded, skipped, failed, remaining
    }
    public static func decode(_ data: Data) throws -> WorkerEvent {
        let event = try JSONDecoder().decode(Self.self, from: data)
        guard event.protocolVersion == 1 else { throw WorkerFailure.protocolMismatch }
        guard ["prepared", "file_started", "file_succeeded", "file_skipped", "file_failed", "completed", "cancelled", "error"].contains(event.event) else { throw WorkerFailure.invalidEvent }
        guard !event.jobID.isEmpty else { throw WorkerFailure.invalidEvent }
        switch event.event {
        case "prepared":
            guard let files = event.files, let rejected = event.rejected, let total = event.total,
                  total >= 0, total == files.count, Set(files).count == files.count,
                  rejected.allSatisfy({ !$0.source.isEmpty && !$0.reason.isEmpty }) else { throw WorkerFailure.invalidEvent }
        case "file_started", "file_succeeded", "file_skipped", "file_failed":
            guard let source = event.source, !source.isEmpty, let index = event.index,
                  let total = event.total, index > 0, index <= total else { throw WorkerFailure.invalidEvent }
            if event.event == "file_succeeded" {
                guard let destination = event.destination, !destination.isEmpty, event.hdrApplied != nil else { throw WorkerFailure.invalidEvent }
            }
            if event.event == "file_failed" {
                guard event.error != nil, event.errorCode != nil else { throw WorkerFailure.invalidEvent }
            }
        case "completed", "cancelled":
            guard let succeeded = event.succeeded, let skipped = event.skipped, let failed = event.failed,
                  let total = event.total, let remaining = event.remaining,
                  min(succeeded, skipped, failed, total) >= 0,
                  succeeded <= total, skipped <= total - succeeded,
                  failed <= total - succeeded - skipped,
                  remaining.count == total - succeeded - skipped - failed,
                  event.event != "completed" || remaining.isEmpty else { throw WorkerFailure.invalidEvent }
        case "error":
            guard event.errorCode != nil, event.message != nil else { throw WorkerFailure.invalidEvent }
        default: throw WorkerFailure.invalidEvent
        }
        return event
    }
}

public enum WorkerFailure: LocalizedError {
    case stopping, unavailable, protocolMismatch, invalidEvent, exited(Int32)
    public var errorDescription: String? {
        switch self {
        case .stopping: return "이전 worker의 현재 파일 저장과 종료를 기다리고 있습니다. 잠시 후 다시 시작하세요."
        case .unavailable: return "앱에 포함된 변환 worker를 찾을 수 없습니다. 앱을 다시 설치하세요."
        case .protocolMismatch: return "앱과 worker의 프로토콜 버전이 다릅니다. 앱을 다시 설치하세요."
        case .invalidEvent: return "worker의 응답 형식이 올바르지 않습니다."
        case .exited(let code): return "변환 worker가 예기치 않게 종료되었습니다 (코드 \(code))."
        }
    }
}

/// stdout의 분할 읽기와 여러 줄 읽기를 모두 처리한다.
public struct JSONLineBuffer {
    private var buffer = Data()
    public init() {}
    public mutating func append(_ data: Data) throws -> [WorkerEvent] {
        buffer.append(data)
        guard buffer.count <= 8 * 1024 * 1024 else { throw WorkerFailure.invalidEvent }
        var events: [WorkerEvent] = []
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if !line.isEmpty { events.append(try WorkerEvent.decode(line)) }
        }
        return events
    }
}

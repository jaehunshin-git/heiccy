import Foundation
import ConverterKit

@MainActor protocol WorkerConnection: AnyObject {
    var onEvent: ((WorkerEvent) -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    func start() throws
    func send(_ request: WorkerRequest) throws
    func stop(afterExit: (() -> Void)?)
}

@MainActor final class WorkerClient: WorkerConnection {
    var onEvent: ((WorkerEvent) -> Void)?
    var onFailure: ((String) -> Void)?
    private var process: Process?
    private var stopping = false
    private var input: FileHandle?
    private var generation = UUID()
    private var buffer = JSONLineBuffer()
    private var diagnostics = ""
    private var exitCallbacks: [() -> Void] = []
    private let executableOverride: URL?

    init(executableURL: URL? = nil) { executableOverride = executableURL }

    func start() throws {
        if stopping { throw WorkerFailure.stopping }
        if process?.isRunning == true { return }
        guard let executable = executableOverride ?? Bundle.main.resourceURL?.appendingPathComponent("worker/heic-worker") else {
            throw WorkerFailure.unavailable
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw WorkerFailure.unavailable }
        let task = Process()
        task.executableURL = executable
        // 사용자 Python, 셸, PATH 설정을 실행 경로로 사용하지 않는다.
        task.environment = ["PATH": "/usr/bin:/bin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                            "LANG": "en_US.UTF-8"]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        task.standardInput = stdin; task.standardOutput = stdout; task.standardError = stderr
        let token = UUID(); generation = token; buffer = JSONLineBuffer(); diagnostics = ""
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                if data.isEmpty {
                    self.fail("worker의 출력 연결이 종료되었습니다.")
                    return
                }
                do { for event in try self.buffer.append(data) { self.onEvent?(event) } }
                catch { self.fail(error.localizedDescription) }
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.diagnostics = String((self.diagnostics + (String(data: data, encoding: .utf8) ?? "")).suffix(4096))
            }
        }
        try task.run()
        process = task; input = stdin.fileHandleForWriting
    }
    func send(_ request: WorkerRequest) throws {
        guard let input, process?.isRunning == true else { throw WorkerFailure.unavailable }
        try input.write(contentsOf: request.line())
    }
    func fail(_ message: String) { stop(); onFailure?(message) }
    /// 프로세스가 끝날 때까지 파이프를 소비한다. 상태 정리가 끝난 뒤에만 콜백을 전달한다.
    func stop(afterExit: (() -> Void)? = nil) {
        if let afterExit { exitCallbacks.append(afterExit) }
        if stopping { return }
        stopping = true
        generation = UUID()
        try? input?.close(); input = nil
        guard let task = process, task.isRunning else {
            finishStop(process)
            return
        }
        task.terminationHandler = { [weak self] task in
            DispatchQueue.main.async { self?.finishStop(task) }
        }
        // 기존 readabilityHandler는 generation 검사 전에 availableData를 읽는다.
        // 콜백 전달을 막아도 stdout/stderr는 실제 종료까지 계속 비운다.
        task.terminate()
    }

    private func finishStop(_ task: Process?) {
        guard task == nil || process === task else { return }
        (task?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (task?.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process = nil; stopping = false
        let callbacks = exitCallbacks; exitCallbacks.removeAll()
        // 이미 종료된 process도 호출자의 stop() 프레임이 돌아간 다음 전달한다.
        DispatchQueue.main.async { callbacks.forEach { $0() } }
    }
}

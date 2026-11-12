import Foundation
import Darwin

// 프로토콜 전용 fd를 먼저 복제한다. Image I/O 등의 fd 1 진단도 stderr로 보낸다.
let protocolDescriptor = Darwin.dup(STDOUT_FILENO)
guard protocolDescriptor >= 0, Darwin.dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else {
    try? FileHandle.standardError.write(contentsOf: Data("worker 출력 연결을 만들지 못했습니다.\n".utf8))
    exit(1)
}
signal(SIGPIPE, SIG_IGN)
let service = WorkerService(output: WorkerJSONOutput(fileDescriptor: protocolDescriptor))
let signalQueue = DispatchQueue(label: "heiccy.worker.signals")
let terminationSources = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: signalQueue)
    source.setEventHandler { service.closeInput(cancel: true) }
    source.resume()
    return source
}

// 입력은 변환 큐와 독립적으로 소비한다. poll은 SIGTERM 중에도 대기를 끝낼 수 있다.
var pending = Data()
var bytes = [UInt8](repeating: 0, count: 64 * 1024)
while !service.isClosing {
    var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
    let ready = Darwin.poll(&descriptor, 1, 100)
    if ready < 0 {
        if errno == EINTR { continue }
        break
    }
    if ready == 0 { continue }
    if descriptor.revents & Int16(POLLNVAL) != 0 { break }
    let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
    if count < 0 {
        if errno == EINTR || errno == EAGAIN { continue }
        break
    }
    if count == 0 {
        // 마지막 요청에 줄바꿈이 없어도 Python의 stdin 반복과 같이 처리한다.
        if !pending.isEmpty, !service.isClosing { service.handle(pending) }
        break
    }
    pending.append(contentsOf: bytes.prefix(count))
    while let newline = pending.firstIndex(of: 10), !service.isClosing {
        let line = Data(pending[..<newline])
        pending.removeSubrange(...newline)
        service.handle(line)
    }
}
service.closeInput()
service.finish()
terminationSources.forEach { $0.cancel() }

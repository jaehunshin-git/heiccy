import ConverterKit
import Darwin
import Foundation
import XCTest
@testable import HEICConverter

final class WorkerClientTests: XCTestCase {
    @MainActor func testStopBeforeStartDefersCallbackAndAllowsReentrantStart() async throws {
        let fixture = try makeFixture()
        let reply = expectation(description: "종료 콜백에서 시작한 worker의 응답")
        reply.assertForOverFulfill = true
        let job = ConversionJob(files: [], settings: AppSettings())
        var stopReturned = false
        var callbackCount = 0
        fixture.worker.onEvent = { event in
            XCTAssertEqual(event.jobID, job.id)
            XCTAssertEqual(event.event, "prepared")
            reply.fulfill()
        }
        fixture.worker.onFailure = { XCTFail("재진입 후 worker 오류: \($0)") }

        fixture.worker.stop {
            XCTAssertTrue(stopReturned, "stop의 상태 정리가 끝난 뒤 콜백을 전달해야 합니다.")
            callbackCount += 1
            do {
                try fixture.worker.start()
                try fixture.worker.send(WorkerRequest(command: "prepare", job: job))
            } catch { XCTFail("종료 콜백 재진입 실패: \(error)") }
        }
        stopReturned = true

        await fulfillment(of: [reply], timeout: 5)
        XCTAssertEqual(callbackCount, 1)
    }

    @MainActor func testTwoStopsDeliverEachCallbackOnceAndRestartRemainsUsable() async throws {
        let fixture = try makeFixture()
        let initialReply = expectation(description: "첫 worker가 실행 중임을 확인")
        let firstCallback = expectation(description: "첫 번째 종료 콜백")
        let secondCallback = expectation(description: "두 번째 종료 콜백")
        let restartedReply = expectation(description: "첫 콜백에서 재시작한 worker의 응답")
        let subsequentReply = expectation(description: "두 번째 콜백 이후에도 요청 처리 가능")
        for item in [initialReply, firstCallback, secondCallback, restartedReply, subsequentReply] {
            item.assertForOverFulfill = true
        }
        let initialJob = ConversionJob(files: [], settings: AppSettings())
        let restartedJob = ConversionJob(files: [], settings: AppSettings())
        let subsequentJob = ConversionJob(files: [], settings: AppSettings())
        fixture.worker.onFailure = { XCTFail("연속 stop 또는 재시작 후 오류: \($0)") }
        fixture.worker.onEvent = { event in
            XCTAssertEqual(event.event, "prepared")
            switch event.jobID {
            case initialJob.id: initialReply.fulfill()
            case restartedJob.id: restartedReply.fulfill()
            case subsequentJob.id: subsequentReply.fulfill()
            default: XCTFail("다른 세대의 응답: \(event.jobID)")
            }
        }
        try fixture.worker.start()
        try fixture.worker.send(WorkerRequest(command: "prepare", job: initialJob))
        await fulfillment(of: [initialReply], timeout: 5)

        var stopsReturned = false
        var callbacks: [Int] = []
        fixture.worker.stop {
            XCTAssertTrue(stopsReturned)
            callbacks.append(1)
            do {
                try fixture.worker.start()
                try fixture.worker.send(WorkerRequest(command: "prepare", job: restartedJob))
            } catch { XCTFail("첫 종료 콜백에서 재시작 실패: \(error)") }
            firstCallback.fulfill()
        }
        fixture.worker.stop {
            XCTAssertTrue(stopsReturned)
            callbacks.append(2)
            secondCallback.fulfill()
        }
        stopsReturned = true
        await fulfillment(of: [firstCallback, secondCallback, restartedReply], timeout: 5)
        XCTAssertEqual(callbacks, [1, 2])

        // 이전 stop 프레임과 두 콜백이 끝난 뒤에도 새 프로세스가 살아 있어야 합니다.
        try fixture.worker.send(WorkerRequest(command: "prepare", job: subsequentJob))
        await fulfillment(of: [subsequentReply], timeout: 5)
    }

    @MainActor func testCooperativeStopDrainsMoreThan64KiBFromBothPipes() async throws {
        let fixture = try makeFixture(drainingOnExit: true)
        let ready = expectation(description: "출력 배출용 worker 준비")
        let exited = expectation(description: "대량 출력을 모두 기록한 뒤 협력 종료")
        ready.assertForOverFulfill = true
        exited.assertForOverFulfill = true
        let job = ConversionJob(files: [], settings: AppSettings())
        var callbackCount = 0
        fixture.worker.onEvent = { event in
            XCTAssertEqual(event.jobID, job.id)
            XCTAssertEqual(event.event, "prepared")
            ready.fulfill()
        }
        fixture.worker.onFailure = { XCTFail("종료 세대의 출력이나 EOF가 오류로 전달됨: \($0)") }
        try fixture.worker.start()
        try fixture.worker.send(WorkerRequest(command: "prepare", job: job))
        await fulfillment(of: [ready], timeout: 5)

        fixture.worker.stop {
            callbackCount += 1
            do {
                // 이 표식은 두 파이프에 각각 256KiB를 쓴 다음에만 생성됩니다.
                let marker = try String(contentsOf: fixture.exitMarker, encoding: .utf8)
                XCTAssertEqual(marker, "stdout=262144 stderr=262144\n")
            } catch { XCTFail("출력 배출이 완료되기 전에 종료 콜백이 실행됨: \(error)") }
            exited.fulfill()
        }
        await fulfillment(of: [exited], timeout: 10)
        XCTAssertEqual(callbackCount, 1)
    }

    @MainActor private func makeFixture(drainingOnExit: Bool = false) throws -> ShellWorkerFixture {
        let fixture = try ShellWorkerFixture(drainingOnExit: drainingOnExit)
        addTeardownBlock {
            let cleaned = await fixture.cleanUp()
            XCTAssertTrue(cleaned, "검증용 worker 종료 콜백이 완료되지 않았습니다.")
        }
        return fixture
    }
}

/// 개인 파일과 실제 번들 worker를 사용하지 않는 독립 실행 프로세스입니다.
@MainActor private final class ShellWorkerFixture {
    let directory: URL
    let exitMarker: URL
    let worker: WorkerClient
    private let pidFile: URL

    init(drainingOnExit: Bool) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("heic-worker-client-test-\(UUID().uuidString)", isDirectory: true)
        exitMarker = directory.appendingPathComponent("출력 완료.txt")
        pidFile = directory.appendingPathComponent("worker.pid")
        let executable = directory.appendingPathComponent("test-worker.sh")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let shutdown: String
        if drainingOnExit {
            shutdown = """
            finish() {
                trap '' TERM INT
                payload=$(printf '%1024s' '')
                index=0
                while [ "$index" -lt 256 ]; do
                    printf '%s' "$payload" || exit 2
                    index=$((index + 1))
                done
                index=0
                while [ "$index" -lt 256 ]; do
                    printf '%s' "$payload" >&2 || exit 3
                    index=$((index + 1))
                done
                printf 'stdout=262144 stderr=262144\\n' > \(Self.quote(exitMarker.path))
                exit 0
            }
            trap finish TERM
            """
        } else {
            shutdown = """
            finish() { exit 0; }
            trap finish TERM
            """
        }
        let script = """
        #!/bin/sh
        printf '%s\\n' "$$" > \(Self.quote(pidFile.path))
        \(shutdown)
        while IFS= read -r request; do
            job_id=$(printf '%s' "$request" | /usr/bin/sed -n 's/.*"job_id":"\\([^"]*\\)".*/\\1/p')
            printf '{"protocol_version":1,"job_id":"%s","event":"prepared","files":[],"rejected":[],"total":0}\\n' "$job_id"
        done
        finish
        """
        do {
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        worker = WorkerClient(executableURL: executable)
    }

    func cleanUp() async -> Bool {
        var exited = false
        worker.stop { exited = true }
        for _ in 0..<100 {
            if exited { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let cooperativeExit = exited
        // 회귀 시에도 파이프에 막힌 검증용 자식 프로세스만 회수합니다.
        if !exited, let value = try? String(contentsOf: pidFile, encoding: .utf8),
           let pid = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 {
            _ = Darwin.kill(pid, SIGKILL)
            for _ in 0..<100 {
                if exited { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        try? FileManager.default.removeItem(at: directory)
        return cooperativeExit
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

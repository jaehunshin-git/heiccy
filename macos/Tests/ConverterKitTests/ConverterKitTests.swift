import XCTest
@testable import ConverterKit

final class ConverterKitTests: XCTestCase {
    func testQueueSnapshotCancellationAndNewInputs() {
        var queue = QueueState()
        let first = URL(fileURLWithPath: "/tmp/한글 사진.heic")
        let second = URL(fileURLWithPath: "/tmp/second.heic")
        let later = URL(fileURLWithPath: "/tmp/later.heic")
        queue.add([first, second, first])
        XCTAssertEqual(queue.items.count, 2)
        var settings = AppSettings()
        queue.schedule(paths: [first.path, second.path], settings: settings)
        settings.options.jpegQuality = 10
        let job = queue.next()!
        XCTAssertEqual(job.options.jpegQuality, 90)
        XCTAssertNil(queue.next())
        queue.add([later])
        queue.update(path: first.path, status: .succeeded, destination: "/tmp/result.jpg")
        queue.finish()
        XCTAssertEqual(queue.items.map(\.status), [.succeeded, .waiting, .waiting])
        queue.add([first])
        XCTAssertEqual(queue.items.count, 3)
        queue.clearCompleted()
        queue.add([first])
        XCTAssertEqual(queue.items.last?.status, .waiting)
    }
    func testScheduledJobKeepsOptionsAndWorkerFailureReleasesLaterJobs() {
        var queue = QueueState()
        queue.add([URL(fileURLWithPath: "/a.heic"), URL(fileURLWithPath: "/b.heic")])
        var settings = AppSettings()
        queue.schedule(paths: ["/a.heic"], settings: settings)
        _ = queue.next()
        settings.options.outputFormat = "png"
        queue.schedule(paths: ["/b.heic"], settings: settings)
        settings.options.outputFormat = "jpeg"
        XCTAssertEqual(queue.jobs.first?.options.outputFormat, "png")
        queue.remove("/a.heic")
        XCTAssertEqual(queue.items.count, 2)
        queue.failActive("worker 종료")
        XCTAssertEqual(queue.items.map(\.status), [.failed, .waiting])
        XCTAssertTrue(queue.jobs.isEmpty)
        queue.schedule(paths: ["/a.heic"], settings: settings)
        XCTAssertEqual(queue.next()?.files, ["/a.heic"])
    }
    func testJobFailurePreservesLaterSnapshotsAndExistingResults() throws {
        var queue = QueueState()
        queue.add(["/a.heic", "/done.heic", "/rejected.heic", "/b.heic"].map { URL(fileURLWithPath: $0) })
        var settings = AppSettings()
        queue.schedule(paths: ["/a.heic", "/done.heic", "/rejected.heic"], settings: settings)
        _ = queue.next()
        queue.update(path: "/a.heic", status: .running)
        queue.update(path: "/done.heic", status: .succeeded, destination: "/result.jpeg")
        queue.update(path: "/rejected.heic", status: .failed, detail: "준비 단계에서 거절")
        settings.options.outputFormat = "png"
        settings.options.pngCompression = 9
        settings.outputDirectory = "/reserved-output"
        queue.schedule(paths: ["/b.heic"], settings: settings)
        let pending = try XCTUnwrap(queue.jobs.first)
        settings.options.outputFormat = "jpeg"
        settings.outputDirectory = "/later-output"

        queue.failCurrentJob("현재 작업 오류")
        XCTAssertNil(queue.activeJob)
        XCTAssertEqual(queue.items.map(\.status), [.failed, .succeeded, .failed, .scheduled])
        XCTAssertEqual(queue.items[0].detail, "현재 작업 오류")
        XCTAssertEqual(queue.items[1].destination, "/result.jpeg")
        XCTAssertEqual(queue.items[2].detail, "준비 단계에서 거절")
        XCTAssertEqual(queue.jobs.map(\.id), [pending.id])
        let next = try XCTUnwrap(queue.next())
        XCTAssertEqual(next.id, pending.id)
        XCTAssertEqual(next.options.outputFormat, "png")
        XCTAssertEqual(next.options.pngCompression, 9)
        XCTAssertEqual(next.outputDirectory, "/reserved-output")
    }
    func testJobFailureDoesNotUnlockReaddedFileInLaterJob() throws {
        var queue = QueueState()
        let first = URL(fileURLWithPath: "/first.heic")
        let second = URL(fileURLWithPath: "/second.heic")
        queue.add([first, second])
        queue.schedule(paths: [first.path, second.path], settings: AppSettings())
        _ = queue.next()
        queue.update(path: first.path, status: .succeeded)
        queue.remove(first.path); queue.add([first])
        queue.schedule(paths: [first.path], settings: AppSettings())
        let pendingID = try XCTUnwrap(queue.jobs.first?.id)
        queue.failCurrentJob("현재 작업 오류")
        XCTAssertEqual(queue.items.first(where: { $0.id == second.path })?.status, .failed)
        XCTAssertEqual(queue.items.first(where: { $0.id == first.path })?.status, .scheduled)
        XCTAssertEqual(queue.next()?.id, pendingID)
    }
    func testBulkRemovalPreservesLockedJobsAndPhysicalFiles() throws {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sources = (0..<7).map { folder.appendingPathComponent("사진 \($0).heic") }
        for (index, source) in sources.enumerated() { try Data([UInt8(index)]).write(to: source) }
        let result = folder.appendingPathComponent("완료 결과.jpeg")
        try Data([10, 20, 30]).write(to: result)
        var queue = QueueState()
        queue.add(sources)
        var settings = AppSettings()
        queue.schedule(paths: [sources[0].path], settings: settings)
        let activeJob = try XCTUnwrap(queue.next())
        queue.update(path: sources[0].path, status: .running)
        settings.options.outputFormat = "png"
        queue.schedule(paths: [sources[1].path], settings: settings)
        let scheduledJob = try XCTUnwrap(queue.jobs.first)
        queue.update(path: sources[3].path, status: .failed)
        queue.update(path: sources[4].path, status: .succeeded, destination: result.path)
        queue.update(path: sources[5].path, status: .skipped)

        // 선택되지 않은 대기 항목은 유지하고 잠긴 항목은 선택되어도 제거하지 않는다.
        queue.removeSelected(Set(sources.prefix(6).map(\.path)).union(["존재하지 않는 ID"]))
        XCTAssertEqual(queue.items.map(\.id), [sources[0].path, sources[1].path, sources[6].path])
        XCTAssertEqual(queue.items.map(\.status), [.running, .scheduled, .waiting])
        queue.removeAll()
        XCTAssertEqual(queue.items.map(\.id), [sources[0].path, sources[1].path])
        XCTAssertEqual(queue.activeJob?.id, activeJob.id)
        XCTAssertEqual(queue.activeJob?.files, [sources[0].path])
        XCTAssertEqual(queue.jobs.map(\.id), [scheduledJob.id])
        XCTAssertEqual(queue.jobs.first?.files, [sources[1].path])
        XCTAssertEqual(queue.jobs.first?.options.outputFormat, "png")

        queue.finish()
        queue.removeAll()
        XCTAssertEqual(queue.items.map(\.id), [sources[1].path])
        XCTAssertEqual(queue.next()?.id, scheduledJob.id)
        queue.update(path: sources[1].path, status: .failed)
        queue.finish()
        queue.removeAll()
        XCTAssertTrue(queue.items.isEmpty)
        XCTAssertTrue(queue.jobs.isEmpty)
        XCTAssertNil(queue.activeJob)
        for (index, source) in sources.enumerated() {
            XCTAssertEqual(try Data(contentsOf: source), Data([UInt8(index)]))
        }
        XCTAssertEqual(try Data(contentsOf: result), Data([10, 20, 30]))
    }
    func testFinishedFileReaddedToPendingJobKeepsLockAfterOldJobFinishes() throws {
        let first = URL(fileURLWithPath: "/tmp/다시 예약.heic")
        let second = URL(fileURLWithPath: "/tmp/변환 중.heic")
        var queue = QueueState()
        queue.add([first, second])
        var settings = AppSettings()
        queue.schedule(paths: [first.path, second.path], settings: settings)
        let oldJob = try XCTUnwrap(queue.next())
        queue.update(path: first.path, status: .succeeded, destination: "/tmp/이전 결과.jpeg")
        queue.update(path: second.path, status: .running)
        queue.removeSelected([first.path])
        queue.add([first])
        settings.options.outputFormat = "png"
        settings.outputDirectory = "/tmp/새 결과 폴더"
        queue.schedule(paths: [first.path], settings: settings)
        let newJob = try XCTUnwrap(queue.jobs.first)
        XCTAssertNotEqual(oldJob.id, newJob.id)
        settings.options.outputFormat = "jpeg"
        settings.outputDirectory = "/tmp/이후 변경 폴더"

        // 이전 작업 완료는 같은 경로의 새 예약을 대기 상태로 되돌리지 않는다.
        queue.finish()
        XCTAssertEqual(queue.items.first(where: { $0.id == first.path })?.status, .scheduled)
        XCTAssertEqual(queue.items.first(where: { $0.id == second.path })?.status, .waiting)
        queue.removeAll()
        XCTAssertEqual(queue.knownPaths, [first.path])
        XCTAssertEqual(queue.jobs.map(\.id), [newJob.id])
        let activated = try XCTUnwrap(queue.next())
        XCTAssertEqual(activated.id, newJob.id)
        XCTAssertEqual(activated.files, [first.path])
        XCTAssertEqual(activated.options.outputFormat, "png")
        XCTAssertEqual(activated.outputDirectory, "/tmp/새 결과 폴더")
        queue.removeSelected([first.path]); queue.removeAll()
        XCTAssertEqual(queue.knownPaths, [first.path])
        XCTAssertEqual(queue.items.first?.status, .scheduled)
        XCTAssertEqual(queue.activeJob?.id, newJob.id)
    }
    func testClipboardBaselineDenialAndResume() {
        var gate = ClipboardGate(changeCount: 1)
        XCTAssertFalse(gate.shouldRead(changeCount: 1, enabled: true, accessDenied: false))
        XCTAssertTrue(gate.shouldRead(changeCount: 2, enabled: true, accessDenied: false))
        XCTAssertFalse(gate.shouldRead(changeCount: 2, enabled: true, accessDenied: false))
        XCTAssertFalse(gate.shouldRead(changeCount: 3, enabled: false, accessDenied: false))
        gate.resume(changeCount: 3)
        XCTAssertFalse(gate.shouldRead(changeCount: 3, enabled: true, accessDenied: false))
        XCTAssertFalse(gate.shouldRead(changeCount: 4, enabled: true, accessDenied: true))
        XCTAssertFalse(gate.shouldRead(changeCount: 5, enabled: true, accessDenied: false))
        gate.resume(changeCount: 5)
        XCTAssertTrue(gate.shouldRead(changeCount: 6, enabled: true, accessDenied: false))
    }
    func testInputRejectionsAndCanonicalDuplicate() throws {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("한글 사진.HEIC")
        try Data([0]).write(to: source)
        let link = folder.appendingPathComponent("link.heic")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let directory = folder.appendingPathComponent("directory.heic")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let result = InputValidator.validate([source, source, link, directory, folder.appendingPathComponent("gone.heic"), folder.appendingPathComponent("not.heif"), URL(string: "https://example.com/a.heic")!])
        XCTAssertEqual(result.accepted, [URL(fileURLWithPath: InputValidator.canonicalPath(source))])
        XCTAssertEqual(result.rejected.count, 6)
        XCTAssertTrue(result.rejected.contains { $0.reason.contains("심볼릭") })
    }
    func testProtocolSplitLinesVersionAndOptions() throws {
        let job = ConversionJob(files: ["/tmp/한글 사진.heic"], settings: AppSettings())
        let data = try WorkerRequest(command: "prepare", job: job).line()
        let request = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(request["protocol_version"] as? Int, 1)
        XCTAssertEqual(request["files"] as? [String], job.files)
        XCTAssertEqual((request["options"] as? [String: Any])?["jpeg_quality"] as? Int, 90)
        let line = Data("{\"protocol_version\":1,\"job_id\":\"test\",\"event\":\"completed\",\"succeeded\":1,\"skipped\":0,\"failed\":0,\"total\":1,\"remaining\":[]}\n".utf8)
        var buffer = JSONLineBuffer()
        XCTAssertTrue(try buffer.append(line.prefix(12)).isEmpty)
        let events = try buffer.append(line.dropFirst(12) + line)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.first?.succeeded, 1)
        XCTAssertThrowsError(try WorkerEvent.decode(Data("{\"protocol_version\":2,\"job_id\":\"test\",\"event\":\"prepared\"}".utf8)))
        XCTAssertThrowsError(try WorkerEvent.decode(Data("{\"protocol_version\":1,\"job_id\":\"test\",\"event\":\"unknown\"}".utf8)))
        XCTAssertThrowsError(try WorkerEvent.decode(Data("not json".utf8)))
        let overflow = "{\"protocol_version\":1,\"job_id\":\"test\",\"event\":\"completed\",\"succeeded\":\(Int.max),\"skipped\":1,\"failed\":0,\"total\":\(Int.max),\"remaining\":[]}"
        XCTAssertThrowsError(try WorkerEvent.decode(Data(overflow.utf8)))
        XCTAssertThrowsError(try WorkerEvent.decode(Data("{\"protocol_version\":1,\"job_id\":\"test\",\"event\":\"completed\"}".utf8)))
        XCTAssertThrowsError(try WorkerEvent.decode(Data("{\"protocol_version\":1,\"job_id\":\"test\",\"event\":\"prepared\",\"files\":[],\"rejected\":[],\"total\":2}".utf8)))
    }
    func testSettingsPersistWithoutQueueHistory() throws {
        let name = "heic-converter-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var settings = AppSettings()
        XCTAssertTrue(settings.clipboardEnabled)
        XCTAssertEqual(settings.options.jpegQuality, 90)
        XCTAssertEqual(settings.options.pngCompression, 6)
        settings.clipboardEnabled = false; settings.outputDirectory = "/tmp/저장 폴더"
        settings.save(to: defaults)
        XCTAssertEqual(AppSettings.load(from: defaults), settings)
        XCTAssertEqual(defaults.persistentDomain(forName: name)?.keys.count, 1)
    }
}

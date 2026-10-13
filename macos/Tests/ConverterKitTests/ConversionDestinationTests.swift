import XCTest
@testable import ConverterKit

final class ConversionDestinationTests: XCTestCase {
    func testMixedScheduledDestinationsKeepTheirOwnSettingsAndRetryChoice() throws {
        var queue = QueueState()
        let saved = URL(fileURLWithPath: "/tmp/저장.heic")
        let copied = URL(fileURLWithPath: "/tmp/복사.heic")
        queue.add([saved, copied])
        var settings = AppSettings()
        settings.outputDirectory = "/tmp/사용자 저장"
        queue.schedule(paths: [saved.path], settings: settings, destination: .files)
        let saveJob = try XCTUnwrap(queue.next())
        settings.options.outputFormat = "png"
        queue.schedule(paths: [copied.path], settings: settings, destination: .clipboard)
        settings.options.outputFormat = "jpeg"
        settings.outputDirectory = "/tmp/이후 변경"
        queue.failCurrentJob("저장 경로 오류")
        let copyJob = try XCTUnwrap(queue.next())
        XCTAssertEqual(saveJob.destination, .files)
        XCTAssertEqual(saveJob.outputDirectory, "/tmp/사용자 저장")
        XCTAssertEqual(copyJob.destination, .clipboard)
        XCTAssertEqual(copyJob.options.outputFormat, "png")
        queue.failCurrentJob("복사 실패")
        XCTAssertEqual(queue.items.map(\.conversionDestination), [.files, .clipboard])
        XCTAssertEqual(queue.items.map(\.status), [.failed, .failed])
        XCTAssertTrue(queue.items.allSatisfy { $0.destination == nil })
    }

    func testClipboardPrepareUsesTemporaryOutputWithoutChangingSettingsOrJob() throws {
        var settings = AppSettings()
        settings.outputDirectory = "/tmp/사용자 폴더"
        let job = ConversionJob(files: ["/tmp/한글 사진.heic"], settings: settings, destination: .clipboard)
        let request = WorkerRequest(command: "prepare", job: job, outputDirectory: "/tmp/임시 변환")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: request.line()) as? [String: Any])
        XCTAssertEqual(object["output_directory"] as? String, "/tmp/임시 변환")
        XCTAssertEqual(object["files"] as? [String], job.files)
        XCTAssertEqual(job.outputDirectory, settings.outputDirectory)
        XCTAssertEqual(job.destination, .clipboard)
        XCTAssertEqual(WorkerRequest(command: "run", job: job).outputDirectory, nil)
    }
}

import XCTest
@testable import ConverterKit

final class QualityPresetTests: XCTestCase {
    func testPresetSelectionSendsNumericJPEGQualityToWorker() throws {
        for (preset, quality) in [(QualityPreset.low, 60), (.medium, 80), (.high, 90), (.raw, 100)] {
            var settings = AppSettings()
            settings.options.qualityPreset = preset
            let job = ConversionJob(files: ["/tmp/photo.heic"], settings: settings)
            let request = try JSONSerialization.jsonObject(with: WorkerRequest(command: "prepare", job: job).line()) as! [String: Any]
            let options = request["options"] as! [String: Any]
            XCTAssertEqual(options["jpeg_quality"] as? Int, quality)
            XCTAssertEqual(options["output_format"] as? String, "jpeg")
            XCTAssertNil(options["qualityPreset"])
        }
    }

    func testLegacyQualityDisplaysNearestPresetWithoutChangingSavedValue() throws {
        let name = "heic-quality-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var settings = AppSettings()
        settings.options.jpegQuality = 84
        settings.options.pngCompression = 4
        settings.save(to: defaults)
        var loaded = AppSettings.load(from: defaults)
        XCTAssertEqual(loaded.options.qualityPreset, .medium)
        XCTAssertEqual(loaded.options.jpegQuality, 84)
        loaded.save(to: defaults)
        XCTAssertEqual(AppSettings.load(from: defaults).options.jpegQuality, 84)
        loaded.options.qualityPreset = .raw
        loaded.save(to: defaults)
        let selected = AppSettings.load(from: defaults)
        XCTAssertEqual(selected.options.jpegQuality, 100)
        XCTAssertEqual(selected.options.qualityPreset, .raw)
        XCTAssertEqual(selected.options.pngCompression, 4)
    }

    func testNearestPresetBoundariesPreferHigherQualityOnTies() {
        let samples: [(Int, QualityPreset)] = [
            (Int.min, .low), (1, .low), (69, .low), (70, .medium),
            (84, .medium), (85, .high), (94, .high), (95, .raw),
            (100, .raw), (Int.max, .raw),
        ]
        for (quality, expected) in samples {
            XCTAssertEqual(QualityPreset.nearest(to: quality), expected, "JPEG 품질 \(quality)")
        }
    }

    func testScheduledJobKeepsSelectedPresetAfterSettingsChange() {
        var settings = AppSettings()
        settings.options.qualityPreset = .medium
        var queue = QueueState()
        let file = URL(fileURLWithPath: "/tmp/photo.heic")
        queue.add([file])
        queue.schedule(paths: [file.path], settings: settings)
        settings.options.qualityPreset = .raw
        XCTAssertEqual(queue.next()?.options.jpegQuality, 80)
    }
}

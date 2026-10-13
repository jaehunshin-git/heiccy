import XCTest
@testable import ConverterKit

final class FeedbackSettingsTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "heic-feedback-settings-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    func testNewSettingsUsePicturesDirectoryAndBalancedCompression() {
        withDefaults { defaults in
            let settings = AppSettings.load(from: defaults)
            XCTAssertEqual(settings.outputDirectory, FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Pictures/HEIC Converter").path)
            XCTAssertEqual(settings.options.pngCompression, 6)
            XCTAssertEqual(settings.options.pngCompressionPreset, .balanced)
        }
    }

    func testKnownValidationDirectoriesMigrateAndPersistWithoutChangingOtherSettings() throws {
        for path in ["/private/tmp/heic-converter-ui-check/converted", "/tmp/heic-converter-ui-check/converted"] {
            try withDefaults { defaults in
                var original = AppSettings()
                original.outputDirectory = path
                original.clipboardEnabled = false
                original.options.outputFormat = "png"
                original.options.jpegQuality = 84
                original.options.pngCompression = 4
                original.options.metadata = "all"
                original.options.onConflict = "skip"
                original.save(to: defaults)
                let loaded = AppSettings.load(from: defaults)
                XCTAssertEqual(loaded.outputDirectory, AppSettings().outputDirectory)
                XCTAssertEqual(loaded.options, original.options)
                XCTAssertEqual(loaded.clipboardEnabled, original.clipboardEnabled)
                let persisted = try JSONDecoder().decode(AppSettings.self,
                    from: XCTUnwrap(defaults.data(forKey: "converter.settings")))
                XCTAssertEqual(persisted, loaded)
            }
        }
    }

    func testCustomAndExistingDownloadsDirectoriesArePreservedByteForByte() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for path in [home + "/Downloads/HEIC Converter", "/tmp/my-converted",
                     "/private/tmp/heic-converter-ui-check/converted/custom",
                     "/private/tmp/heic-converter-ui-check/converted/", "/Volumes/Photos/Converted"] {
            withDefaults { defaults in
                var original = AppSettings()
                original.outputDirectory = path
                original.options.pngCompression = 7
                original.save(to: defaults)
                let data = defaults.data(forKey: "converter.settings")
                XCTAssertEqual(AppSettings.load(from: defaults), original)
                XCTAssertEqual(defaults.data(forKey: "converter.settings"), data)
            }
        }
    }

    func testDisplayedDirectoryAbbreviatesOnlyTheTrueHomePrefix() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for (path, expected) in [(home, "~"), (home + "/Pictures/HEIC Converter", "~/Pictures/HEIC Converter"),
                                 (home + "-other/Pictures", home + "-other/Pictures"),
                                 ("/Volumes/Photos", "/Volumes/Photos")] {
            var settings = AppSettings()
            settings.outputDirectory = path
            XCTAssertEqual(settings.displayOutputDirectory, expected)
            XCTAssertEqual(settings.outputDirectory, path)
        }
    }

    func testPresetsEncodeNumericCompressionForWorker() throws {
        for (preset, level, label) in [(PNGCompressionPreset.none, 0, "압축 없음"), (.fast, 3, "빠르게"),
                                       (.balanced, 6, "균형"), (.small, 9, "작게")] {
            var settings = AppSettings()
            settings.options.outputFormat = "png"
            settings.options.pngCompressionPreset = preset
            let job = ConversionJob(files: ["/tmp/example.heic"], settings: settings)
            let request = try XCTUnwrap(JSONSerialization.jsonObject(
                with: WorkerRequest(command: "prepare", job: job).line()) as? [String: Any])
            let options = try XCTUnwrap(request["options"] as? [String: Any])
            XCTAssertEqual(options["png_compression"] as? Int, level)
            XCTAssertEqual(options["output_format"] as? String, "png")
            XCTAssertEqual(options["jpeg_quality"] as? Int, 90)
            XCTAssertNil(options["pngCompressionPreset"])
            XCTAssertEqual(preset.label, label)
        }
    }

    func testArbitrarySavedCompressionStaysUnchangedUntilPresetSelection() {
        withDefaults { defaults in
            var settings = AppSettings()
            settings.options.pngCompression = 4
            settings.save(to: defaults)
            var loaded = AppSettings.load(from: defaults)
            XCTAssertEqual(loaded.options.pngCompressionPreset, .fast)
            loaded.save(to: defaults)
            XCTAssertEqual(AppSettings.load(from: defaults).options.pngCompression, 4)
            loaded.options.pngCompressionPreset = .small
            loaded.save(to: defaults)
            XCTAssertEqual(AppSettings.load(from: defaults).options.pngCompression, 9)
        }
    }

    func testNearestCompressionClampsExtremeValuesAndMapsAllLevels() {
        let samples: [(Int, PNGCompressionPreset)] = [
            (Int.min, .none), (0, .none), (1, .none), (2, .fast), (3, .fast), (4, .fast),
            (5, .balanced), (6, .balanced), (7, .balanced), (8, .small), (9, .small), (Int.max, .small),
        ]
        for (level, expected) in samples {
            XCTAssertEqual(PNGCompressionPreset.nearest(to: level), expected, "PNG 압축 \(level)")
        }
    }

    func testDisplayOrderPlacesUncompressedOptionOnTheRight() {
        XCTAssertEqual(PNGCompressionPreset.displayOrder, [.small, .balanced, .fast, .none])
        XCTAssertEqual(PNGCompressionPreset.displayOrder.map(\.compressionLevel), [9, 6, 3, 0])
        XCTAssertEqual(Set(PNGCompressionPreset.displayOrder), Set(PNGCompressionPreset.allCases))
    }

    func testScheduledJobKeepsCompressionAndOutputDirectorySnapshot() {
        var settings = AppSettings()
        settings.options.pngCompression = 4
        settings.outputDirectory = "/Volumes/Photos/First"
        let file = URL(fileURLWithPath: "/tmp/example.heic")
        var queue = QueueState()
        queue.add([file])
        queue.schedule(paths: [file.path], settings: settings)
        settings.options.pngCompressionPreset = .small
        settings.outputDirectory = "/Volumes/Photos/Second"
        let job = queue.next()
        XCTAssertEqual(job?.options.pngCompression, 4)
        XCTAssertEqual(job?.outputDirectory, "/Volumes/Photos/First")
    }
}

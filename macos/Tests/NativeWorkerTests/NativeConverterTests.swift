import XCTest
import Foundation
import ImageIO
import CoreGraphics
@testable import NativeWorker

final class NativeConverterTests: XCTestCase {
    private func withFixture(_ body: (URL, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("입력.heic")
        let pixels = Data(repeating: 90, count: 64 * 32 * 4)
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let image = try XCTUnwrap(CGImage(width: 64, height: 32, bitsPerComponent: 8, bitsPerPixel: 32,
                                         bytesPerRow: 64 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, "public.heic" as CFString, 1, nil))
        CGImageDestinationAddImage(writer, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        try body(directory, source)
    }

    func testNativeJPEGAndPNGPreserveSourceAndDimensions() throws {
        try withFixture { directory, source in
            let original = try Data(contentsOf: source)
            for format in ["jpeg", "png"] {
                let destination = directory.appendingPathComponent("출력.\(format)")
                _ = try NativeConverter.convert(source: source, destination: destination,
                                                 options: NativeOptions(outputFormat: format))
                let decoded = try XCTUnwrap(CGImageSourceCreateWithURL(destination as CFURL, nil))
                let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
                XCTAssertEqual(image.width, 64); XCTAssertEqual(image.height, 32)
            }
            XCTAssertEqual(try Data(contentsOf: source), original)
        }
    }

    func testNoOverwritePreservesExistingFileAndCleansTemporaryOutput() throws {
        try withFixture { directory, source in
            let destination = directory.appendingPathComponent("출력.jpeg")
            let original = Data("기존 파일 보존".utf8)
            try original.write(to: destination)
            XCTAssertThrowsError(try NativeConverter.convert(source: source, destination: destination, options: NativeOptions()))
            XCTAssertEqual(try Data(contentsOf: destination), original)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".heiccy-") })
        }
    }

    func testConflictAndOverwriteNeverModifySymlinkTarget() throws {
        try withFixture { directory, source in
            let target = directory.appendingPathComponent("개인 파일")
            let original = Data("대상 보존".utf8)
            try original.write(to: target)
            let destination = directory.appendingPathComponent("출력.jpeg")
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)
            XCTAssertThrowsError(try NativeConverter.convert(source: source, destination: destination, options: NativeOptions()))
            XCTAssertEqual(try Data(contentsOf: target), original)
            _ = try NativeConverter.convert(source: source, destination: destination, options: NativeOptions(overwrite: true))
            XCTAssertEqual(try Data(contentsOf: target), original)
            XCTAssertNotEqual(try Data(contentsOf: destination), original)
            XCTAssertFalse(try destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink ?? true)
        }
    }

    func testInvalidInputLeavesNoPartialOutput() throws {
        try withFixture { directory, _ in
            let source = directory.appendingPathComponent("손상.heic")
            try Data("손상".utf8).write(to: source)
            let destination = directory.appendingPathComponent("출력.png")
            XCTAssertThrowsError(try NativeConverter.convert(source: source, destination: destination, options: NativeOptions(outputFormat: "png")))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".heiccy-") })
        }
    }
}

import AppKit
import XCTest
@testable import HEICConverter

final class HeiccyIconTests: XCTestCase {
    /// 확정 PNG와 앱 도형을 비교해 얼굴·획·비율이 따로 바뀌는 것을 막는다.
    func testNativeSymbolMatchesApprovedSquareAsset() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root
            .appendingPathComponent("docs/assets/branding/heiccy-logo-square.png"))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        let reference = try XCTUnwrap(bitmap.cgImage)
        let size = 1024
        func context() throws -> CGContext {
            try XCTUnwrap(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                   bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        }
        let approved = try context()
        approved.draw(reference, in: CGRect(x: 0, y: 0, width: size, height: size))
        let native = try context()
        native.translateBy(x: 0, y: CGFloat(size))
        native.scaleBy(x: 1, y: -1)
        native.setFillColor(NSColor.black.cgColor)
        native.addPath(PhotoClipboardIconGeometry.silhouette(in:
            CGRect(x: 188, y: 152, width: 648, height: 720)))
        native.fillPath()
        let expected = try XCTUnwrap(approved.data).assumingMemoryBound(to: UInt8.self)
        let actual = try XCTUnwrap(native.data).assumingMemoryBound(to: UInt8.self)
        var intersection = 0, expectedArea = 0, actualArea = 0
        for pixel in 0..<(size * size) {
            let a = expected[pixel * 4 + 3] >= 128
            let b = actual[pixel * 4 + 3] >= 128
            if a { expectedArea += 1 }
            if b { actualArea += 1 }
            if a && b { intersection += 1 }
        }
        let overlap = Double(2 * intersection) / Double(expectedArea + actualArea)
        XCTAssertGreaterThan(overlap, 0.99, "확정 심볼과 앱의 기하가 일치해야 합니다.")
    }

    func testBothStatesRemainTemplateImagesWithDistinctPauseAppearance() throws {
        let enabled = PhotoClipboardIconGeometry.makeTemplateImage()
        let paused = PhotoClipboardIconGeometry.makeTemplateImage(isPaused: true)
        XCTAssertTrue(enabled.isTemplate)
        XCTAssertTrue(paused.isTemplate)
        XCTAssertEqual(enabled.size, CGSize(width: 16.2, height: 18))
        XCTAssertEqual(paused.size, enabled.size)
        XCTAssertNotEqual(enabled.accessibilityDescription, paused.accessibilityDescription)
        XCTAssertNotEqual(try XCTUnwrap(enabled.tiffRepresentation), try XCTUnwrap(paused.tiffRepresentation))
    }

    func testEmptySizeDoesNotProduceAVisibleSymbol() {
        XCTAssertTrue(PhotoClipboardIconGeometry.silhouette(in: .zero).isEmpty)
    }
}

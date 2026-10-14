import XCTest
import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import CZlib
@testable import NativeWorker

final class PNGCompressionTests: XCTestCase {
    private let signature = Data([137, 80, 78, 71, 13, 10, 26, 10])

    private func temporary(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("png-stream-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func compress(_ raw: Data) throws -> Data {
        var size = compressBound(uLong(raw.count))
        var output = Data(count: Int(size))
        let result = output.withUnsafeMutableBytes { destination in
            raw.withUnsafeBytes { source in
                compress2(destination.bindMemory(to: Bytef.self).baseAddress, &size,
                          source.bindMemory(to: Bytef.self).baseAddress, uLong(raw.count), 6)
            }
        }
        XCTAssertEqual(result, Z_OK)
        output.count = Int(size)
        return output
    }

    private func decompress(_ compressed: Data, count: Int) -> Data {
        var size = uLong(count)
        var raw = Data(count: max(count, 1))
        let result = raw.withUnsafeMutableBytes { destination in
            compressed.withUnsafeBytes { source in
                uncompress(destination.bindMemory(to: Bytef.self).baseAddress, &size,
                           source.bindMemory(to: Bytef.self).baseAddress, uLong(compressed.count))
            }
        }
        XCTAssertEqual(result, Z_OK)
        XCTAssertEqual(Int(size), count)
        raw.count = Int(size)
        return raw
    }

    private func header(width: Int, height: Int, depth: UInt8 = 8, interlace: UInt8 = 0) -> Data {
        var data = Data()
        PNGCompression.appendNumber(UInt32(width), to: &data)
        PNGCompression.appendNumber(UInt32(height), to: &data)
        data.append(contentsOf: [depth, 2, 0, 0, interlace])
        return data
    }

    private func png(header: Data, compressed: Data, split: Int = 257,
                     before: [Data] = [], after: [Data] = []) -> Data {
        var file = signature
        file.append(PNGCompression.chunk("IHDR", header))
        before.forEach { file.append($0) }
        file.append(PNGCompression.chunk("IDAT", Data()))
        for start in stride(from: 0, to: compressed.count, by: split) {
            file.append(PNGCompression.chunk("IDAT", compressed.subdata(in: start..<min(start + split, compressed.count))))
        }
        file.append(PNGCompression.chunk("IDAT", Data()))
        after.forEach { file.append($0) }
        file.append(PNGCompression.chunk("IEND", Data()))
        return file
    }

    private func chunks(_ file: Data) -> [(String, Data, Data)] {
        var result: [(String, Data, Data)] = []
        var offset = 8
        while offset + 12 <= file.count {
            let count = PNGCompression.number(file, offset)
            let end = offset + count + 12
            let type = String(decoding: file[offset + 4..<offset + 8], as: UTF8.self)
            result.append((type, file.subdata(in: offset + 8..<end - 4), file.subdata(in: offset..<end)))
            offset = end
        }
        return result
    }

    private func rawPixels(width: Int, height: Int, depth: Int = 8) -> Data {
        var result = Data()
        var state: UInt64 = 42
        for _ in 0..<height {
            result.append(0)
            for _ in 0..<width * 3 * (depth / 8) {
                state ^= state << 13; state ^= state >> 7; state ^= state << 17
                result.append(UInt8(truncatingIfNeeded: state))
            }
        }
        return result
    }

    func testAllCompressionLevelsRoundTripAndImageIODecodes() throws {
        try temporary { directory in
            let raw = rawPixels(width: 173, height: 257)
            let original = png(header: header(width: 173, height: 257), compressed: try compress(raw))
            let url = directory.appendingPathComponent("normal.png")
            for level in 0...9 {
                try original.write(to: url)
                try PNGCompression.recompress(url, level: level, metadata: "safe")
                let result = try Data(contentsOf: url)
                let records = chunks(result)
                let idat = records.filter { $0.0 == "IDAT" }.reduce(into: Data()) { $0.append($1.1) }
                XCTAssertEqual(decompress(idat, count: raw.count), raw)
                XCTAssertTrue(records.filter { $0.0 == "IDAT" }.allSatisfy { $0.1.count <= 65536 })
                let source = try XCTUnwrap(CGImageSourceCreateWithData(result as CFData, nil))
                let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
                XCTAssertEqual(decoded.width, 173)
                XCTAssertEqual(decoded.height, 257)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["normal.png"])
            }
        }
    }

    func testHDRColorChunksAndMetadataPoliciesPreserveExactBytes() throws {
        try temporary { directory in
            let raw = rawPixels(width: 41, height: 61, depth: 16)
            var cicp = Data([9, 16, 0, 1])
            let color = [PNGCompression.chunk("cICP", cicp), PNGCompression.chunk("cLLI", Data(repeating: 0, count: 8)),
                         PNGCompression.chunk("mDCV", Data(repeating: 0, count: 24))]
            cicp.removeAll() // 청크가 자체 데이터를 보존하는지 확인한다.
            let text = [PNGCompression.chunk("tEXt", Data("Comment\0hello".utf8)),
                        PNGCompression.chunk("iTXt", Data("Comment\0\0\0\0\0hello".utf8)),
                        PNGCompression.chunk("zTXt", Data("Comment\0\0".utf8) + (try compress(Data("hello".utf8))))]
            let exif = PNGCompression.chunk("eXIf", Data([73, 73, 42, 0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
            let original = png(header: header(width: 41, height: 61, depth: 16), compressed: try compress(raw),
                               before: color + [text[0], exif], after: [text[1], text[2]])
            let url = directory.appendingPathComponent("hdr.png")
            for mode in ["safe", "strip", "preserve"] {
                try original.write(to: url)
                try PNGCompression.recompress(url, level: 9, metadata: mode)
                let result = chunks(try Data(contentsOf: url))
                let expected = chunks(original).filter {
                    $0.0 != "IDAT" && !(mode != "preserve" && ["iTXt", "tEXt", "zTXt"].contains($0.0)) &&
                        !(mode == "strip" && $0.0 == "eXIf")
                }
                XCTAssertEqual(result.filter { $0.0 != "IDAT" }.map { $0.2 }, expected.map { $0.2 })
                XCTAssertEqual(decompress(result.filter { $0.0 == "IDAT" }.reduce(into: Data()) { $0.append($1.1) }, count: raw.count), raw)
                XCTAssertEqual(result.first!.1[8], 16)
            }
        }
    }

    func testAdam7ScanlineBoundariesRoundTrip() throws {
        try temporary { directory in
            let width = 17, height = 19
            var raw = Data()
            for (x, y, dx, dy) in [(0,0,8,8),(4,0,8,8),(0,4,4,8),(2,0,4,4),(0,2,2,4),(1,0,2,2),(0,1,1,2)] {
                let columns = (width - x + dx - 1) / dx
                let rows = (height - y + dy - 1) / dy
                for _ in 0..<rows { raw.append(0); raw.append(Data(repeating: 128, count: columns * 3)) }
            }
            let file = png(header: header(width: width, height: height, interlace: 1), compressed: try compress(raw), split: 1)
            let url = directory.appendingPathComponent("interlaced.png")
            try file.write(to: url)
            try PNGCompression.recompress(url, level: 0, metadata: "safe")
            let result = try Data(contentsOf: url)
            let compressed = chunks(result).filter { $0.0 == "IDAT" }.reduce(into: Data()) { $0.append($1.1) }
            XCTAssertEqual(decompress(compressed, count: raw.count), raw)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(result as CFData, nil))
            XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, 0, nil))
        }
    }

    func testMalformedInputsPreserveOriginalAndCleanTemporaryFiles() throws {
        try temporary { directory in
            let raw = rawPixels(width: 11, height: 7)
            let compressed = try compress(raw)
            let ihdr = header(width: 11, height: 7)
            let valid = png(header: ihdr, compressed: compressed)
            var oversized = signature + PNGCompression.chunk("IHDR", ihdr)
            oversized.append(contentsOf: [255, 255, 255, 255, 73, 68, 65, 84, 0, 0, 0, 0])
            var badCRC = valid; badCRC[29] ^= 1
            var badFilter = raw; badFilter[0] = 5
            let emptyIDAT = signature + PNGCompression.chunk("IHDR", ihdr)
                + PNGCompression.chunk("IDAT", Data()) + PNGCompression.chunk("IEND", Data())
            let separatedIDAT = signature + PNGCompression.chunk("IHDR", ihdr)
                + PNGCompression.chunk("IDAT", Data(compressed.prefix(2)))
                + PNGCompression.chunk("tEXt", Data("x\0y".utf8))
                + PNGCompression.chunk("IDAT", Data(compressed.dropFirst(2))) + PNGCompression.chunk("IEND", Data())
            let malformed = [Data(), Data([137]), Data(valid.prefix(32)), Data(valid.dropLast()), oversized, badCRC,
                             emptyIDAT, separatedIDAT, png(header: ihdr, compressed: Data([1,2,3])),
                             png(header: ihdr, compressed: Data(compressed.dropLast())),
                             png(header: ihdr, compressed: try compress(Data(raw.dropLast()))),
                             png(header: ihdr, compressed: try compress(raw + Data([0]))),
                             png(header: ihdr, compressed: try compress(badFilter))]
            let url = directory.appendingPathComponent("invalid.png")
            for (index, original) in malformed.enumerated() {
                try original.write(to: url)
                XCTAssertThrowsError(try PNGCompression.recompress(url, level: 6, metadata: "safe"), "case \(index)")
                XCTAssertEqual(try Data(contentsOf: url), original, "case \(index)")
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["invalid.png"])
            }
            try valid.write(to: url)
            for level in [-1, 10, Int.max] {
                XCTAssertThrowsError(try PNGCompression.recompress(url, level: level, metadata: "safe"))
                XCTAssertEqual(try Data(contentsOf: url), valid)
            }
        }
    }

    func testJPEGFillBytesAcceptedAndMissingScanRejected() throws {
        try temporary { directory in
            let pixels = Data(repeating: 128, count: 8 * 8 * 3)
            let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
            let image = try XCTUnwrap(CGImage(width: 8, height: 8, bitsPerComponent: 8, bitsPerPixel: 24,
                                            bytesPerRow: 24, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil,
                                            shouldInterpolate: false, intent: .defaultIntent))
            let data = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let original = data as Data
            let padded = Data(original.prefix(2)) + Data([255]) + original.dropFirst(2)
            let url = directory.appendingPathComponent("fill.jpeg")
            try padded.write(to: url)
            try JPEGMetadata.strip(url)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let noScan = Data([255,216,255,224,0,2,255,217])
            try noScan.write(to: url)
            XCTAssertThrowsError(try JPEGMetadata.strip(url))
            XCTAssertEqual(try Data(contentsOf: url), noScan)
        }
    }
}

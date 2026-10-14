import Foundation
import ImageIO
import XCTest
@testable import NativeWorker

final class HEIFMetadataTests: XCTestCase {
    func testVersionsFileAndIDATExtentsPreserveOriginalEXIF() throws {
        for version in 0...2 {
            for method in 0...1 where version > 0 || method == 0 {
                let bytes = Self.container(version: version, method: method)
                let properties = try XCTUnwrap(HEIFMetadata.exifProperties(from: bytes))
                try assertOriginalEXIF(properties)
                XCTAssertFalse(String(describing: properties).contains("private-xmp-test"))
                XCTAssertNil(properties[kCGImagePropertyPixelWidth as String])
                XCTAssertNil(properties[kCGImagePropertyProfileName as String])
                // Data의 시작 인덱스가 0이 아닌 입력도 같은 결과를 반환한다.
                var padded = Data([0, 1, 2])
                padded.append(bytes)
                let sliced = try XCTUnwrap(HEIFMetadata.exifProperties(from: padded.dropFirst(3)))
                XCTAssertEqual(NSDictionary(dictionary: properties), NSDictionary(dictionary: sliced))
            }
        }
    }

    func testURLAPI() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".heic")
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.container().write(to: url)
        try assertOriginalEXIF(XCTUnwrap(HEIFMetadata.exifProperties(from: url)))
    }

    func testRemovesXMPInsideEveryStandardIFDWithoutLosingDescriptions() throws {
        for little in [true, false] {
            let bytes = Self.container(tiff: Self.tiff(little: little, xmp: true), offset: 17)
            let properties = try XCTUnwrap(HEIFMetadata.exifProperties(from: bytes))
            try assertOriginalEXIF(properties)
            XCTAssertFalse(String(describing: properties).contains("private-xmp-test"))
            let tiff = try XCTUnwrap(properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any])
            XCTAssertEqual(tiff[kCGImagePropertyTIFFImageDescription as String] as? String, "original-exif-description")
        }
    }

    func testNoEXIFAndEXIFOnlyOnSecondaryImageReturnNil() throws {
        XCTAssertNil(try HEIFMetadata.exifProperties(from: Self.container(includeEXIF: false)))
        XCTAssertNil(try HEIFMetadata.exifProperties(from: Self.container(associatedPrimary: false)))
    }

    func testExplicitErrorsForUnsupportedStorageAndAmbiguousMetadata() throws {
        assertFailure(Self.container(method: 2), contains: "construction_method 2")
        assertFailure(Self.container(reference: 1), contains: "외부 파일")
        assertFailure(Self.container(protection: 1), contains: "보호된")
        assertFailure(Self.container(method: 1, includeIDAT: false), contains: "idat")
        assertFailure(Self.container(includeIREF: false), contains: "iref")
        assertFailure(Self.container(secondEXIF: true), contains: "여러 EXIF")
        assertFailure(Self.container(duplicateMeta: true), contains: "중복")
        assertFailure(Self.container(version: 3), contains: "버전")
        assertFailure(Self.container(width: 9), contains: "정수 폭")
        assertFailure(Self.container(lengthOverride: 0), contains: "길이가 0")
    }

    func testBoundsOffsetsAndOverflowAreRejected() throws {
        assertFailure(Self.container(lengthOverride: UInt64.max), contains: "경계")
        assertFailure(Self.container(method: 1, lengthOverride: 1_000_000), contains: "경계")
        assertFailure(Self.container(baseOverride: UInt64.max), contains: "넘쳤습니다")
        assertFailure(Self.container(offset: UInt32.max, writePadding: false), contains: "시작 오프셋")
        let short = Data([0, 0, 0, 0])
        assertFailure(Self.container(rawItem: short), contains: "시작 오프셋")
        var box = Self.container()
        box.replaceSubrange(0..<4, with: Self.integer(7, 4))
        assertFailure(box, contains: "박스 크기")
        var huge = Self.box("meta", Data(), extended: true)
        huge.replaceSubrange(8..<16, with: Self.integer(UInt64.max, 8))
        assertFailure(huge, contains: "박스 크기")
    }

    func testMalformedTIFFGraphsAndValuesAreRejected() throws {
        var bad = Self.tiff()
        bad.replaceSubrange(4..<8, with: Self.integerLE(0xfffffff0, 4))
        assertFailure(Self.container(tiff: bad), contains: "IFD 오프셋")
        bad = Self.tiff()
        bad.replaceSubrange(8..<10, with: Self.integerLE(0xffff, 2))
        assertFailure(Self.container(tiff: bad), contains: "항목 목록")
        bad = Self.tiff()
        // 첫 Make 태그의 out-of-line 값 오프셋을 파일 밖으로 이동한다.
        bad.replaceSubrange(18..<22, with: Self.integerLE(0xffffff00, 4))
        assertFailure(Self.container(tiff: bad), contains: "태그 값")
        bad = Self.tiff()
        let count = Int(bad[8])
        let next = 10 + count * 12
        bad.replaceSubrange(next..<(next + 4), with: Self.integerLE(8, 4))
        assertFailure(Self.container(tiff: bad), contains: "순환")
        bad = Self.tiff(xmp: true)
        // 보존할 Make 값이 XMP 제거로 수정되는 IFD와 겹치면 안전하게 실패한다.
        bad.replaceSubrange(18..<22, with: Self.integerLE(8, 4))
        assertFailure(Self.container(tiff: bad), contains: "겹칩니다")
    }

    func testPNGCarrierSupportsLargeEXIFAndResourceLimitFailsExplicitly() throws {
        var large = Self.tiff(xmp: true)
        large.append(Data(repeating: 0, count: 70_000 - large.count))
        let properties = try XCTUnwrap(HEIFMetadata.exifProperties(from: Self.container(tiff: large)))
        try assertOriginalEXIF(properties)
        XCTAssertFalse(String(describing: properties).contains("private-xmp-test"))
        var exact = Self.tiff()
        exact.append(Data(repeating: 0, count: 16 * 1_024 * 1_024 - exact.count))
        try assertOriginalEXIF(XCTUnwrap(HEIFMetadata.exifProperties(from: Self.container(tiff: exact))))
        exact.append(0)
        assertFailure(Self.container(tiff: exact), contains: "16MiB")
    }

    func testTruncationsAndDeterministicByteMutationsDoNotCrashOrLeakXMP() throws {
        let original = Self.container(tiff: Self.tiff(xmp: true))
        for length in 0..<original.count {
            do {
                let result = try HEIFMetadata.exifProperties(from: Data(original.prefix(length)))
                XCTAssertFalse(String(describing: result).contains("private-xmp-test"))
            } catch {
                XCTAssertNotNil((error as? LocalizedError)?.errorDescription)
            }
        }
        for offset in stride(from: 0, to: original.count, by: 7) {
            var mutated = original
            mutated[offset] ^= 0xff
            do {
                let result = try HEIFMetadata.exifProperties(from: mutated)
                XCTAssertFalse(String(describing: result).contains("private-xmp-test"))
            } catch {
                XCTAssertNotNil((error as? LocalizedError)?.errorDescription)
            }
        }
    }

    private func assertOriginalEXIF(_ properties: [String: Any], file: StaticString = #filePath,
                                    line: UInt = #line) throws {
        let tiff = try XCTUnwrap(properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any], file: file, line: line)
        XCTAssertEqual(tiff[kCGImagePropertyTIFFMake as String] as? String, "Native test camera", file: file, line: line)
        XCTAssertEqual(tiff[kCGImagePropertyTIFFImageDescription as String] as? String, "original-exif-description", file: file, line: line)
        XCTAssertEqual((properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue, 6, file: file, line: line)
        let exif = try XCTUnwrap(properties[kCGImagePropertyExifDictionary as String] as? [String: Any], file: file, line: line)
        XCTAssertEqual(exif[kCGImagePropertyExifDateTimeOriginal as String] as? String, "2026:10:14 12:34:56", file: file, line: line)
        let gps = try XCTUnwrap(properties[kCGImagePropertyGPSDictionary as String] as? [String: Any], file: file, line: line)
        XCTAssertEqual((gps[kCGImagePropertyGPSLatitude as String] as? NSNumber)?.doubleValue, 37.5, file: file, line: line)
        XCTAssertEqual(gps[kCGImagePropertyGPSLatitudeRef as String] as? String, "N", file: file, line: line)
    }

    private func assertFailure(_ bytes: Data, contains text: String, file: StaticString = #filePath,
                               line: UInt = #line) {
        XCTAssertThrowsError(try HEIFMetadata.exifProperties(from: bytes), file: file, line: line) { error in
            let description = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(description.contains(text), description, file: file, line: line)
        }
    }

    private static func integer(_ value: UInt64, _ width: Int) -> Data {
        Data((0..<width).map { index in
            let shift = (width - index - 1) * 8
            return shift >= 64 ? 0 : UInt8(truncatingIfNeeded: value >> shift)
        })
    }

    private static func integerLE(_ value: UInt64, _ width: Int) -> Data {
        Data(integer(value, width).reversed())
    }

    private static func box(_ type: String, _ payload: Data, extended: Bool = false) -> Data {
        var bytes = integer(extended ? 1 : UInt64(payload.count + 8), 4)
        bytes.append(contentsOf: type.utf8)
        if extended { bytes.append(integer(UInt64(payload.count + 16), 8)) }
        bytes.append(payload)
        return bytes
    }

    private static func fullBox(_ type: String, version: Int = 0, _ payload: Data,
                                extended: Bool = false) -> Data {
        box(type, Data([UInt8(version), 0, 0, 0]) + payload, extended: extended)
    }

    // IFD 영역과 값의 영역을 분리해 tag700 제거 후 기존 값 오프셋을 검증한다.
    private static func tiff(little: Bool = true, xmp: Bool = false) -> Data {
        func number(_ value: UInt64, _ width: Int) -> Data {
            little ? integerLE(value, width) : integer(value, width)
        }
        var bytes = Data(repeating: 0, count: 1_400)
        bytes.replaceSubrange(0..<8, with: Data(little ? [0x49, 0x49] : [0x4d, 0x4d]) + number(42, 2) + number(8, 4))
        var valuePosition = 768
        typealias Entry = (tag: UInt64, type: UInt64, count: UInt64, value: Data)
        func ascii(_ tag: UInt64, _ value: String) -> Entry {
            let data = Data(value.utf8) + Data([0])
            return (tag, 2, UInt64(data.count), data)
        }
        func pointer(_ tag: UInt64, _ value: UInt64) -> Entry { (tag, 4, 1, number(value, 4)) }
        func directory(_ offset: Int, _ entries: [Entry], next: UInt64 = 0) {
            var entries = entries
            if xmp {
                let xml = Data("<x:xmpmeta xmlns:x='adobe:ns:meta/'><rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'><rdf:Description xmlns:dc='http://purl.org/dc/elements/1.1/' dc:description='private-xmp-test'/></rdf:RDF></x:xmpmeta>".utf8)
                entries.append((700, 1, UInt64(xml.count), xml))
            }
            entries.sort { $0.tag < $1.tag }
            var result = number(UInt64(entries.count), 2)
            for entry in entries {
                result.append(number(entry.tag, 2) + number(entry.type, 2) + number(entry.count, 4))
                if entry.value.count <= 4 {
                    result.append(entry.value)
                    result.append(Data(repeating: 0, count: 4 - entry.value.count))
                } else {
                    result.append(number(UInt64(valuePosition), 4))
                    let end = valuePosition + entry.value.count
                    if end > bytes.count { bytes.append(Data(repeating: 0, count: end - bytes.count)) }
                    bytes.replaceSubrange(valuePosition..<end, with: entry.value)
                    valuePosition = end + (end % 2)
                }
            }
            result.append(number(next, 4))
            bytes.replaceSubrange(offset..<(offset + result.count), with: result)
        }
        directory(8, [ascii(271, "Native test camera"), ascii(270, "original-exif-description"),
                      (274, 3, 1, number(6, 2)), pointer(34665, 160), pointer(34853, 256), pointer(330, 512)], next: 384)
        directory(160, [ascii(36867, "2026:10:14 12:34:56"), pointer(40965, 640)])
        let latitude = number(37, 4) + number(1, 4) + number(30, 4) + number(1, 4) + number(0, 4) + number(1, 4)
        directory(256, [(0, 1, 4, Data([2, 3, 0, 0])), ascii(1, "N"), (2, 5, 3, latitude)])
        directory(384, [ascii(305, "original-next-ifd")])
        directory(512, [ascii(305, "original-sub-ifd")])
        directory(640, [ascii(1, "R98")])
        return bytes
    }

    private static func container(version: Int = 2, method: Int = 1, width: Int = 8,
                                  tiff: Data? = nil, offset: UInt32 = 6, writePadding: Bool = true,
                                  rawItem: Data? = nil, reference: UInt64 = 0, protection: UInt64 = 0,
                                  includeEXIF: Bool = true, associatedPrimary: Bool = true,
                                  includeIDAT: Bool = true, includeIREF: Bool = true,
                                  secondEXIF: Bool = false, duplicateMeta: Bool = false,
                                  lengthOverride: UInt64? = nil, baseOverride: UInt64? = nil) -> Data {
        let wide = version >= 2
        let primary: UInt64 = wide ? 70_001 : 1
        let exif: UInt64 = wide ? 70_002 : 2
        let secondary: UInt64 = wide ? 70_003 : 3
        let another: UInt64 = wide ? 70_004 : 4
        let idWidth = wide ? 4 : 2
        func info(_ id: UInt64, _ type: String) -> Data {
            fullBox("infe", version: wide ? 3 : 2,
                    integer(id, idWidth) + integer(type == "Exif" ? protection : 0, 2) + Data(type.utf8) + Data([0]))
        }
        var item = integer(UInt64(offset), 4)
        if writePadding { item.append(Data(repeating: 0x5a, count: Int(offset))) }
        item.append(tiff ?? Self.tiff())
        if let rawItem = rawItem { item = rawItem }
        let cut = min(19, max(1, item.count / 2))
        // 논리적 EXIF를 두 extent로 나누고 사이에 XMP 표식이 있는 무관한 바이트를 넣는다.
        let gap = Data("private-xmp-test".utf8)
        let prefix = Data(repeating: 0xa5, count: 16)
        let storage = prefix + item.prefix(cut) + gap + item.dropFirst(cut)
        var infos = info(primary, "hvc1") + info(secondary, "hvc1")
        var itemCount: UInt64 = 2
        if includeEXIF { infos.append(info(exif, "Exif")); itemCount += 1 }
        if secondEXIF { infos.append(info(another, "Exif")); itemCount += 1 }
        let iinf = fullBox("iinf", version: wide ? 1 : 0, integer(itemCount, wide ? 4 : 2) + infos)
        let pitm = fullBox("pitm", version: wide ? 1 : 0, integer(primary, idWidth))
        func referenceBox(_ id: UInt64) -> Data {
            box("cdsc", integer(id, idWidth) + integer(1, 2) + integer(associatedPrimary ? primary : secondary, idWidth))
        }
        var links = includeEXIF ? referenceBox(exif) : Data()
        if secondEXIF { links.append(referenceBox(another)) }
        let iref = includeIREF ? fullBox("iref", version: wide ? 1 : 0, links) : Data()
        func locations(_ origin: UInt64) -> Data {
            var content = Data([UInt8((width << 4) | width), UInt8(width << 4)])
            let ids = (includeEXIF ? [exif] : []) + (secondEXIF ? [another] : [])
            content.append(integer(UInt64(ids.count), wide ? 4 : 2))
            for id in ids {
                content.append(integer(id, idWidth))
                if version != 0 { content.append(integer(UInt64(method), 2)) }
                content.append(integer(reference, 2))
                content.append(integer(baseOverride ?? origin, width))
                content.append(integer(2, 2))
                content.append(integer(16, width) + integer(lengthOverride ?? UInt64(cut), width))
                content.append(integer(UInt64(16 + cut + gap.count), width) + integer(UInt64(item.count - cut), width))
            }
            return fullBox("iloc", version: version, content)
        }
        func meta(_ origin: UInt64) -> Data {
            let idat = method == 1 && includeIDAT ? box("idat", storage, extended: true) : Data()
            return fullBox("meta", pitm + iinf + iref + locations(origin) + idat, extended: true)
        }
        let ftyp = box("ftyp", Data("heic".utf8) + integer(0, 4) + Data("mif1heic".utf8))
        var metadata = meta(0)
        if method == 0 { metadata = meta(UInt64(ftyp.count + metadata.count + 8)) }
        let mdat = method == 0 ? box("mdat", storage) : Data()
        return ftyp + metadata + (duplicateMeta ? metadata : Data()) + mdat
    }
}

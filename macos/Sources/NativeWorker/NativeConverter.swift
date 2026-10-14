import Foundation
import ImageIO
import CoreImage
import UniformTypeIdentifiers
import Darwin
import CZlib

struct NativeOptions {
    var outputFormat: String = "jpeg"
    var jpegQuality: Int = 90
    var pngCompression: Int = 6
    var metadata: String = "safe"
    var overwrite: Bool = false
}

struct NativeConversionResult {
    let hdrApplied: Bool
    let sdrReason: String?
}

enum NativeConversionError: LocalizedError {
    case invalid(String), conflict(String), io(String)
    var errorDescription: String? {
        switch self {
        case .invalid(let message), .conflict(let message), .io(let message): return message
        }
    }
}

enum NativeConverter {
    // OS 코덱을 사용한다. Python이나 제3자 코덱을 로드하지 않는다.

    static func convert(source: URL, destination: URL, options: NativeOptions) throws -> NativeConversionResult {
        guard let input = CGImageSourceCreateWithURL(source as CFURL, nil),
              CGImageSourceGetCount(input) > 0 else {
            throw NativeConversionError.invalid("HEIC 파일을 읽지 못했습니다: \(source.path)")
        }
        let index = CGImageSourceGetPrimaryImageIndex(input)
        let properties = CGImageSourceCopyPropertiesAtIndex(input, index, nil) as? [String: Any] ?? [:]
        // HEIF 전체 속성은 XMP를 EXIF/TIFF 값으로 합칠 수 있다. 안전 보존에는
        // 원본 EXIF item만 사용해 XMP 유래 민감 정보가 승격되어 남지 않게 한다.
        let metadataProperties = options.metadata == "safe"
            ? (try HEIFMetadata.exifProperties(from: source) ?? [:]) : properties
        let orientation = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.uint32Value ?? 1
        let hasGainMap = CGImageSourceCopyAuxiliaryDataInfoAtIndex(input, index, kCGImageAuxiliaryDataTypeHDRGainMap) != nil
        let hdr = options.outputFormat == "png" && hasGainMap && orientation == 1
        let decode: [CFString: Any] = [kCGImageSourceDecodeRequest: hdr ? kCGImageSourceDecodeToHDR : kCGImageSourceDecodeToSDR,
                                      kCGImageSourceShouldCacheImmediately: true]
        guard let raw = CGImageSourceCreateImageAtIndex(input, index, decode as CFDictionary) else {
            throw NativeConversionError.invalid("HEIC 픽셀을 읽지 못했습니다: \(source.path)")
        }
        let image: CGImage
        if hdr { image = raw }
        else {
            let outputSpace = raw.colorSpace?.model == .rgb
                ? raw.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
            // Pillow와 같이 출력 RGB 색공간에서 알파를 흰 배경에 합성한다.
            let context = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: outputSpace])
            var pixels = CIImage(cgImage: raw).oriented(CGImagePropertyOrientation(rawValue: orientation) ?? .up)
            if options.outputFormat == "jpeg" {
                let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: pixels.extent)
                pixels = pixels.composited(over: white)
            }
            guard let rendered = context.createCGImage(pixels, from: pixels.extent, format: .RGBA8,
                                                       colorSpace: outputSpace) else {
                throw NativeConversionError.invalid("이미지 방향·색상 변환에 실패했습니다.")
            }
            image = rendered
        }
        var outputProperties: [String: Any] = [:]
        if options.metadata != "strip" {
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary] {
                if var values = metadataProperties[key as String] as? [String: Any] {
                    if key == kCGImagePropertyTIFFDictionary {
                        values[kCGImagePropertyTIFFOrientation as String] = 1
                        values["ImageWidth"] = image.width
                        values["ImageLength"] = image.height
                    } else {
                        values[kCGImagePropertyExifPixelXDimension as String] = image.width
                        values[kCGImagePropertyExifPixelYDimension as String] = image.height
                    }
                    values.removeValue(forKey: "GPS")
                    values.removeValue(forKey: "XMP")
                    outputProperties[key as String] = values
                }
            }
            outputProperties[kCGImagePropertyOrientation as String] = 1
            if options.metadata == "preserve", let gps = properties[kCGImagePropertyGPSDictionary as String] {
                outputProperties[kCGImagePropertyGPSDictionary as String] = gps
            }
        }
        if options.outputFormat == "jpeg" {
            outputProperties[kCGImageDestinationLossyCompressionQuality as String] = Double(options.jpegQuality) / 100
            outputProperties[kCGImageDestinationEncodeRequest as String] = kCGImageDestinationEncodeToSDR
        } else if hdr {
            outputProperties[kCGImageDestinationEncodeRequest as String] = kCGImageDestinationEncodeToISOHDR
        }
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        // 최대 길이의 파일명도 임시 이름 길이를 늘리지 않고 저장한다.
        let temporary = parent.appendingPathComponent(".heiccy-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let temporaryFD = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard temporaryFD >= 0 else { throw posixError() }
        close(temporaryFD)
        let format = options.outputFormat == "jpeg" ? UTType.jpeg.identifier : UTType.png.identifier
        guard let output = CGImageDestinationCreateWithURL(temporary as CFURL, format as CFString, 1, nil) else {
            throw NativeConversionError.io("출력 파일을 만들지 못했습니다: \(destination.path)")
        }
        if options.metadata == "preserve", let metadata = CGImageSourceCopyMetadataAtIndex(input, index, nil),
           let mutable = CGImageMetadataCreateMutableCopy(metadata) {
            // 픽셀 방향을 보정한 뒤 XMP에 남은 방향 값도 보정한다.
            CGImageMetadataSetValueWithPath(mutable, nil, "tiff:Orientation" as CFString, 1 as CFNumber)
            CGImageMetadataSetValueWithPath(mutable, nil, "exif:Orientation" as CFString, 1 as CFNumber)
            for (path, value) in [("tiff:ImageWidth", image.width), ("tiff:ImageLength", image.height),
                                  ("exif:PixelXDimension", image.width), ("exif:PixelYDimension", image.height)] {
                CGImageMetadataSetValueWithPath(mutable, nil, path as CFString, value as CFNumber)
            }
            CGImageDestinationAddImageAndMetadata(output, image, mutable, outputProperties as CFDictionary)
        } else {
            CGImageDestinationAddImage(output, image, outputProperties as CFDictionary)
        }
        guard CGImageDestinationFinalize(output) else {
            throw NativeConversionError.io("이미지 저장에 실패했습니다: \(destination.path)")
        }
        if options.outputFormat == "png" {
            if !hdr, options.metadata != "strip", let profile = raw.colorSpace?.copyICCData() {
                try PNGColorProfile.restore(temporary, profile: profile as Data)
            }
            // Image I/O의 필터 옵션과 zlib 압축 수준은 서로 다르다.
            // 픽셀·HDR·메타데이터 청크를 유지하며 IDAT만 요청한 0~9 수준으로 재압축한다.
            try PNGCompression.recompress(temporary, level: options.pngCompression, metadata: options.metadata)
        } else if options.metadata == "strip" {
            try JPEGMetadata.strip(temporary)
        }
        let descriptor = Darwin.open(temporary.path, O_RDONLY)
        guard descriptor >= 0 else { throw posixError() }
        let syncResult = fsync(descriptor)
        let syncError = errno
        close(descriptor)
        if syncResult != 0 && ![EINVAL, ENOTSUP, ENOSYS].contains(syncError) {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(syncError))
        }
        if options.overwrite {
            guard rename(temporary.path, destination.path) == 0 else { throw posixError() }
        } else {
            if renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL)) != 0 {
                let failure = errno
                if failure == EEXIST { throw NativeConversionError.conflict("이미 출력 파일이 있습니다: \(destination.path)") }
                if [ENOTSUP, EINVAL, ENOSYS].contains(failure) {
                    if link(temporary.path, destination.path) != 0 {
                        if errno == EEXIST { throw NativeConversionError.conflict("이미 출력 파일이 있습니다: \(destination.path)") }
                        // 안전한 비덮어쓰기 저장을 지원하지 않는 볼륨에서는 기존 파일을 보존하고 실패한다.
                        throw NativeConversionError.io("이 볼륨은 덮어쓰기 없는 원자적 저장을 지원하지 않습니다. 다른 출력 폴더를 선택하세요.")
                    } else {
                        try? FileManager.default.removeItem(at: temporary)
                    }
                } else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure)) }
            }
        }
        let directoryFD = Darwin.open(parent.path, O_RDONLY)
        if directoryFD >= 0 { _ = fsync(directoryFD); close(directoryFD) }
        let reason: String?
        if hdr { reason = nil }
        else if options.outputFormat == "jpeg" { reason = "JPEG 출력은 SDR로 처리합니다." }
        else if !hasGainMap { reason = "지원하는 Apple HDR 게인 맵이 없습니다." }
        else { reason = "방향 보정이 필요한 입력은 SDR로 처리합니다." }
        return NativeConversionResult(hdrApplied: hdr, sdrReason: reason)
    }

    static func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}

enum JPEGMetadata {
    static func strip(_ url: URL) throws {
        let bytes = try Data(contentsOf: url)
        guard bytes.count > 2, bytes[0] == 0xff, bytes[1] == 0xd8 else {
            throw NativeConversionError.invalid("JPEG 형식이 올바르지 않습니다.")
        }
        var result = Data(bytes.prefix(2)), offset = 2, hasScan = false
        while offset < bytes.count {
            let markerStart = offset
            guard bytes[offset] == 0xff else { throw NativeConversionError.invalid("JPEG marker가 올바르지 않습니다.") }
            while offset < bytes.count && bytes[offset] == 0xff { offset += 1 }
            guard offset < bytes.count else { throw NativeConversionError.invalid("JPEG marker가 잘렸습니다.") }
            let marker = bytes[offset]; offset += 1
            guard marker != 0 && marker != 0xd8 else { throw NativeConversionError.invalid("JPEG marker가 올바르지 않습니다.") }
            if marker == 0xda {
                guard offset + 2 <= bytes.count else { throw NativeConversionError.invalid("JPEG 스캔 헤더가 잘렸습니다.") }
                let size = Int(bytes[offset]) * 256 + Int(bytes[offset + 1])
                guard size >= 2, size <= bytes.count - offset,
                      bytes.suffix(2) == Data([0xff, 0xd9]) else {
                    throw NativeConversionError.invalid("JPEG 스캔 데이터가 불완전합니다.")
                }
                result.append(bytes[markerStart...]); hasScan = true; break
            }
            if marker == 0xd9 { break }
            if marker == 0x01 || (0xd0...0xd7).contains(marker) {
                result.append(bytes[markerStart..<offset]); continue
            }
            guard offset + 2 <= bytes.count else { throw NativeConversionError.invalid("JPEG 길이 필드가 잘렸습니다.") }
            let size = Int(bytes[offset]) * 256 + Int(bytes[offset + 1])
            guard size >= 2, size <= bytes.count - offset else { throw NativeConversionError.invalid("JPEG 메타데이터가 불완전합니다.") }
            // APP1(EXIF/XMP), APP13(IPTC), COM만 제거한다. 색 재현용 ICC(APP2)는 유지한다.
            if marker != 0xe1 && marker != 0xed && marker != 0xfe {
                result.append(bytes[markerStart..<offset + size])
            }
            offset += size
        }
        guard hasScan else { throw NativeConversionError.invalid("JPEG 이미지 스캔이 없습니다.") }
        try result.write(to: url)
    }
}

enum PNGCompression {
    private static let bufferSize = 64 * 1024
    private static let signature = Data([137, 80, 78, 71, 13, 10, 26, 10])

    static func number(_ data: Data, _ offset: Int) -> Int {
        data[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
    }

    static func appendNumber(_ number: UInt32, to data: inout Data) {
        var big = number.bigEndian
        withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }

    /// 생성하는 IDAT payload는 64KiB 이하이며 전체 압축 결과를 보관하지 않는다.
    static func chunk(_ type: String, _ payload: Data) -> Data {
        var result = Data()
        appendNumber(UInt32(payload.count), to: &result)
        let typeBytes = Data(type.utf8)
        result.append(typeBytes)
        result.append(payload)
        var checksum = typeBytes.withUnsafeBytes {
            crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))
        }
        payload.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = min(bufferSize, bytes.count - offset)
                checksum = crc32(checksum, bytes.bindMemory(to: Bytef.self).baseAddress!.advanced(by: offset), uInt(count))
                offset += count
            }
        }
        appendNumber(UInt32(checksum), to: &result)
        return result
    }

    private struct Record {
        let type: String
        let range: Range<Int>
        let payload: Range<Int>
    }

    /// 필터 바이트·행 길이는 스트리밍으로 검증한다. Adam7도 전체 픽셀을 만들지 않는다.
    private struct Scanlines {
        let passes: [(bytes: Int, rows: Int)]
        private var pass = 0
        private var row = 0
        private var remaining = 0
        var isComplete: Bool { pass == passes.count }

        init(header: Data) throws {
            let width = number(header, 0), height = number(header, 4)
            let depth = Int(header[8]), color = Int(header[9])
            let allowed: [Int: Set<Int>] = [0: [1, 2, 4, 8, 16], 2: [8, 16], 3: [1, 2, 4, 8], 4: [8, 16], 6: [8, 16]]
            guard width > 0, height > 0, width <= Int32.max, height <= Int32.max,
                  allowed[color]?.contains(depth) == true, header[10] == 0, header[11] == 0, header[12] <= 1 else {
                throw NativeConversionError.invalid("PNG 이미지 헤더가 올바르지 않습니다.")
            }
            let channels = [0: 1, 2: 3, 3: 1, 4: 2, 6: 4][color]!
            let layouts = header[12] == 0 ? [(0, 0, 1, 1)] :
                [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4),
                 (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
            var result: [(bytes: Int, rows: Int)] = []
            for (x, y, dx, dy) in layouts where width > x && height > y {
                let columns = (width - x + dx - 1) / dx
                let rows = (height - y + dy - 1) / dy
                result.append(((columns * channels * depth + 7) / 8, rows))
            }
            passes = result
        }

        mutating func consume(_ bytes: UnsafeBufferPointer<UInt8>) throws {
            var offset = 0
            while offset < bytes.count {
                guard !isComplete else { throw NativeConversionError.invalid("PNG 스캔라인 데이터가 너무 깁니다.") }
                if remaining == 0 {
                    guard bytes[offset] <= 4 else { throw NativeConversionError.invalid("PNG 필터 값이 올바르지 않습니다.") }
                    remaining = passes[pass].bytes
                    offset += 1
                }
                let count = min(remaining, bytes.count - offset)
                remaining -= count
                offset += count
                if remaining == 0 {
                    row += 1
                    if row == passes[pass].rows { pass += 1; row = 0 }
                }
            }
        }
    }

    private static func records(_ file: Data) throws -> [Record] {
        guard file.count >= 33, file.prefix(8) == signature else {
            throw NativeConversionError.invalid("PNG 형식이 올바르지 않습니다.")
        }
        var records: [Record] = []
        var offset = 8, foundIDAT = false, endedIDAT = false, foundIEND = false, foundPalette = false
        try file.withUnsafeBytes { bytes in
            let base = bytes.bindMemory(to: Bytef.self).baseAddress!
            while offset < file.count {
                guard file.count - offset >= 12 else { throw NativeConversionError.invalid("PNG 청크 헤더가 잘렸습니다.") }
                let size = number(file, offset)
                guard size <= Int32.max, size <= file.count - offset - 12 else {
                    throw NativeConversionError.invalid("PNG 청크가 불완전합니다.")
                }
                let end = offset + size + 12
                let name = file[offset + 4..<offset + 8]
                guard name.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }),
                      file[offset + 6] & 32 == 0 else {
                    throw NativeConversionError.invalid("PNG 청크 종류가 올바르지 않습니다.")
                }
                let type = String(decoding: name, as: UTF8.self)
                var checksum: uLong = 0
                var checked = offset + 4
                while checked < end - 4 {
                    let count = min(bufferSize, end - 4 - checked)
                    checksum = crc32(checksum, base.advanced(by: checked), uInt(count))
                    checked += count
                }
                guard checksum == uLong(number(file, end - 4)) else {
                    throw NativeConversionError.invalid("PNG 청크 CRC가 올바르지 않습니다.")
                }
                if records.isEmpty {
                    guard type == "IHDR", size == 13 else { throw NativeConversionError.invalid("PNG 이미지 헤더가 없습니다.") }
                } else if type == "IHDR" { throw NativeConversionError.invalid("PNG 이미지 헤더가 중복되었습니다.") }
                if type == "IDAT" {
                    guard !endedIDAT else { throw NativeConversionError.invalid("PNG IDAT 청크는 연속해야 합니다.") }
                    foundIDAT = true
                } else if foundIDAT { endedIDAT = true }
                if type == "PLTE" {
                    guard !foundPalette, !foundIDAT, size > 0, size <= 768, size % 3 == 0 else {
                        throw NativeConversionError.invalid("PNG 팔레트가 올바르지 않습니다.")
                    }
                    foundPalette = true
                }
                if type == "IEND" {
                    guard foundIDAT, size == 0, end == file.count else {
                        throw NativeConversionError.invalid("PNG 종료 청크가 올바르지 않습니다.")
                    }
                    foundIEND = true
                }
                if name.first! & 32 == 0, !["IHDR", "PLTE", "IDAT", "IEND"].contains(type) {
                    throw NativeConversionError.invalid("지원하지 않는 PNG 필수 청크입니다.")
                }
                records.append(Record(type: type, range: offset..<end, payload: offset + 8..<end - 4))
                offset = end
            }
        }
        guard foundIDAT, foundIEND else { throw NativeConversionError.invalid("PNG 이미지 데이터 또는 종료 청크가 없습니다.") }
        let color = file[records[0].payload.lowerBound + 9]
        if color == 3, !foundPalette { throw NativeConversionError.invalid("PNG 팔레트가 없습니다.") }
        return records
    }

    static func recompress(_ url: URL, level: Int, metadata: String) throws {
        guard (0...9).contains(level) else { throw NativeConversionError.invalid("PNG 압축 수준은 0에서 9 사이여야 합니다.") }
        let file = try Data(contentsOf: url, options: .alwaysMapped)
        let records = try records(file)
        let ranges = records.filter { $0.type == "IDAT" }.map(\.payload)
        var scanlines = try Scanlines(header: file.subdata(in: records[0].payload))
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".heiccy-png-\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw NativeConverter.posixError() }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? output.close(); try? FileManager.default.removeItem(at: temporary) }
        try output.write(contentsOf: signature)
        try file.withUnsafeBytes { source in
            var wroteIDAT = false
            for record in records {
                if record.type == "IDAT" {
                    if !wroteIDAT {
                        try transcode(source, ranges: ranges, level: level, scanlines: &scanlines, output: output)
                        wroteIDAT = true
                    }
                } else if !((metadata != "preserve" && ["iTXt", "tEXt", "zTXt"].contains(record.type)) ||
                            (metadata == "strip" && record.type == "eXIf")) {
                    var offset = record.range.lowerBound
                    while offset < record.range.upperBound {
                        let count = min(bufferSize, record.range.upperBound - offset)
                        try output.write(contentsOf: Data(bytes: source.baseAddress!.advanced(by: offset), count: count))
                        offset += count
                    }
                }
            }
        }
        try output.synchronize()
        try output.close()
        // 원본 매핑을 수정하지 않는다. 검증·출력 완료 뒤 같은 폴더에서 교체한다.
        guard Darwin.rename(temporary.path, url.path) == 0 else { throw NativeConverter.posixError() }
    }

    private static func transcode(_ source: UnsafeRawBufferPointer, ranges: [Range<Int>], level: Int,
                                  scanlines: inout Scanlines, output: FileHandle) throws {
        var inflater = z_stream(), deflater = z_stream()
        guard inflateInit_(&inflater, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw NativeConversionError.io("PNG 압축 해제 초기화 실패")
        }
        defer { inflateEnd(&inflater) }
        guard deflateInit_(&deflater, Int32(level), ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw NativeConversionError.io("PNG 압축 초기화 실패")
        }
        defer { deflateEnd(&deflater) }
        var decoded = [UInt8](repeating: 0, count: bufferSize)
        var encoded = [UInt8](repeating: 0, count: bufferSize)
        var rangeIndex = 0, position = ranges.first?.lowerBound ?? 0
        var ended = false
        try decoded.withUnsafeMutableBufferPointer { raw in
            try encoded.withUnsafeMutableBufferPointer { compressed in
                while !ended {
                    if inflater.avail_in == 0 {
                        while rangeIndex < ranges.count, position == ranges[rangeIndex].upperBound {
                            rangeIndex += 1
                            if rangeIndex < ranges.count { position = ranges[rangeIndex].lowerBound }
                        }
                        if rangeIndex < ranges.count {
                            let count = min(bufferSize, ranges[rangeIndex].upperBound - position)
                            inflater.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress!.advanced(by: position))
                            inflater.avail_in = uInt(count)
                            position += count
                        } else { inflater.next_in = nil }
                    }
                    let available = inflater.avail_in
                    inflater.next_out = raw.baseAddress!
                    inflater.avail_out = uInt(bufferSize)
                    let status = inflate(&inflater, Z_NO_FLUSH)
                    guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
                        throw NativeConversionError.invalid("PNG 압축 데이터가 올바르지 않습니다.")
                    }
                    let count = bufferSize - Int(inflater.avail_out)
                    guard status == Z_STREAM_END || count > 0 || available != inflater.avail_in else {
                        throw NativeConversionError.invalid("PNG 압축 데이터가 잘렸습니다.")
                    }
                    ended = status == Z_STREAM_END
                    try scanlines.consume(UnsafeBufferPointer(start: raw.baseAddress!, count: count))
                    if ended, !scanlines.isComplete { throw NativeConversionError.invalid("PNG 스캔라인 데이터가 잘렸습니다.") }
                    if count > 0 || ended {
                        deflater.next_in = raw.baseAddress!
                        deflater.avail_in = uInt(count)
                        while true {
                            let available = deflater.avail_in
                            deflater.next_out = compressed.baseAddress!
                            deflater.avail_out = uInt(bufferSize)
                            let status = deflate(&deflater, ended ? Z_FINISH : Z_NO_FLUSH)
                            guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
                                throw NativeConversionError.io("PNG 재압축 실패")
                            }
                            let count = bufferSize - Int(deflater.avail_out)
                            if count > 0 {
                                try output.write(contentsOf: chunk("IDAT", Data(bytes: compressed.baseAddress!, count: count)))
                            }
                            if status == Z_STREAM_END { break }
                            if !ended, deflater.avail_in == 0, deflater.avail_out > 0 { break }
                            guard count > 0 || available != deflater.avail_in else { throw NativeConversionError.io("PNG 재압축이 진행되지 않습니다.") }
                        }
                    }
                }
            }
        }
    }
}

import Foundation
import ImageIO

/// 기본 이미지에 연결된 원본 EXIF만 읽는다. HEIF 소스를 ImageIO에 전달하지 않으므로
/// 별도 XMP 항목의 dc:description 등이 TIFF 속성으로 승격되는 경로가 없다.
enum HEIFMetadata {
    enum ExtractionError: LocalizedError {
        case malformed(String)
        case unsupported(String)
        case decoding(String)

        var errorDescription: String? {
            switch self {
            case .malformed(let reason): return "HEIF EXIF 구조가 손상되었습니다: \(reason)"
            case .unsupported(let reason): return "지원하지 않는 HEIF EXIF 구조입니다: \(reason)"
            case .decoding(let reason): return "원본 EXIF 속성을 읽지 못했습니다: \(reason)"
            }
        }
    }

    static func exifProperties(from url: URL) throws -> [String: Any]? {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw ExtractionError.decoding("입력 파일을 읽을 수 없습니다. \(error.localizedDescription)")
        }
        return try exifProperties(from: data)
    }

    static func exifProperties(from data: Data) throws -> [String: Any]? {
        guard let original = try Container(data: data).exifTIFF() else { return nil }
        let tiff = try validatedTIFFWithoutXMP(original)
        // 픽셀 없는 TIFF는 ImageIO에서 이미지 수 0으로 판별되어 속성이 유실된다.
        // 새로 만든 PNG에는 TIFF의 XMP 태그만 제거한 eXIf를 추가한다. 원본 HEIF나
        // 썸네일은 열지 않으며, 나머지 EXIF 값과 TIFF 기준 상대 오프셋은 유지한다.
        let base = try metadataCarrier.get()
        // PNG 시그니처 8 + IHDR 청크 25 뒤, IDAT 앞에 원본 TIFF를 넣는다.
        // JPEG APP1의 65,527바이트 제한은 적용되지 않는다.
        var png = Data(base.prefix(33))
        png.append(PNGCompression.chunk("eXIf", tiff))
        png.append(base.dropFirst(33))
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(png as CFData, options),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [String: Any] else {
            throw ExtractionError.decoding("원본 TIFF의 ImageIO 해석에 실패했습니다.")
        }
        // 운반용 PNG의 1×1 크기, 색상·프로파일 등은 EXIF가 아니다.
        // 메타데이터 사전은 ImageIO가 해석한 값을 그대로 유지한다.
        let keys = [kCGImagePropertyTIFFDictionary, kCGImagePropertyExifDictionary,
                    kCGImagePropertyExifAuxDictionary, kCGImagePropertyGPSDictionary,
                    kCGImagePropertyIPTCDictionary, kCGImagePropertyOrientation]
        var result: [String: Any] = [:]
        for key in keys {
            if let value = properties[key as String] { result[key as String] = value }
        }
        return result
    }

    // 비정상 입력으로 인한 메모리 소비를 제한한다. 초과 시 누락 없이 명시적으로 실패한다.
    private static let maximumTIFFBytes = 16 * 1_024 * 1_024
    private static let maximumEntries = 100_000

    // 공유되는 것은 메타데이터 없는 운반용 PNG 바이트뿐이다.
    private static let metadataCarrier: Result<Data, ExtractionError> = {
        let pixels = Data([0])
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 8,
                                  bytesPerRow: 1, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else {
            return .failure(.decoding("EXIF 해석용 이미지를 만들 수 없습니다."))
        }
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil) else {
            return .failure(.decoding("EXIF 해석용 PNG를 만들 수 없습니다."))
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            return .failure(.decoding("EXIF 해석용 PNG 인코딩에 실패했습니다."))
        }
        let data = bytes as Data
        guard data.count >= 33, data.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]),
              data[8..<12] == Data([0, 0, 0, 13]), data[12..<16] == Data("IHDR".utf8) else {
            return .failure(.decoding("EXIF 해석용 PNG 헤더가 유효하지 않습니다."))
        }
        return .success(data)
    }()

    private struct Box {
        let type: UInt64
        let payload: Range<Int>
    }

    /// 모든 위치는 Data.startIndex 기준 상대 위치다. Data 슬라이스도 안전하게 읽는다.
    private struct Reader {
        let data: Data
        var position: Int
        let end: Int
        var remaining: Int { end - position }

        init(_ data: Data, _ range: Range<Int>) {
            self.data = data
            position = range.lowerBound
            end = range.upperBound
        }

        mutating func uint(_ width: Int) throws -> UInt64 {
            guard (0...8).contains(width), width <= remaining else {
                throw ExtractionError.malformed("정수 필드가 경계를 벗어났습니다.")
            }
            var value: UInt64 = 0
            for _ in 0..<width {
                value = (value << 8) | UInt64(data[data.startIndex + position])
                position += 1
            }
            return value
        }

        mutating func fullBox(_ versions: ClosedRange<Int>, allowFlags: Bool = false) throws -> Int {
            let version = Int(try uint(1))
            let flags = try uint(3)
            guard versions.contains(version) else {
                throw ExtractionError.unsupported("박스 버전 \(version)")
            }
            guard allowFlags || flags == 0 else {
                throw ExtractionError.unsupported("알 수 없는 FullBox 플래그")
            }
            return version
        }

        mutating func string() throws {
            while remaining > 0 {
                if try uint(1) == 0 { return }
            }
            throw ExtractionError.malformed("문자열 종료 바이트가 없습니다.")
        }

        func finished() throws {
            guard remaining == 0 else {
                throw ExtractionError.malformed("박스에 해석되지 않은 바이트가 남았습니다.")
            }
        }

        mutating func box() throws -> Box {
            let start = position
            var size = try uint(4)
            let type = try uint(4)
            if size == 1 { size = try uint(8) }
            else if size == 0 {
                // BMFF의 크기 0은 파일 끝까지다. 부모 끝을 넘는 중첩 박스는 거부한다.
                size = UInt64(data.count - start)
            }
            if type == 0x75756964 { // uuid의 확장 타입 16바이트
                _ = try uint(8)
                _ = try uint(8)
            }
            guard size >= UInt64(position - start), size <= UInt64(end - start) else {
                throw ExtractionError.malformed("박스 크기가 헤더 또는 부모 경계를 벗어났습니다.")
            }
            let boxEnd = start + Int(size)
            let payload = position..<boxEnd
            position = boxEnd
            return Box(type: type, payload: payload)
        }
    }

    private struct Item {
        let type: UInt64
        let protection: UInt64
    }

    private struct Container {
        let data: Data

        private func boxes(_ range: Range<Int>) throws -> [Box] {
            var reader = Reader(data, range)
            var result: [Box] = []
            while reader.remaining > 0 {
                guard result.count < maximumEntries else {
                    throw ExtractionError.unsupported("박스 수가 안전 한도를 초과합니다.")
                }
                result.append(try reader.box())
            }
            return result
        }

        private func unique(_ type: UInt64, in boxes: [Box]) throws -> Box? {
            let matches = boxes.filter { $0.type == type }
            guard matches.count <= 1 else {
                throw ExtractionError.malformed("중복된 메타데이터 제어 박스가 있습니다.")
            }
            return matches.first
        }

        func exifTIFF() throws -> Data? {
            let top = try boxes(0..<data.count)
            guard let meta = try unique(0x6d657461, in: top) else {
                throw ExtractionError.unsupported("파일 수준 meta 박스가 없습니다.")
            }
            var header = Reader(data, meta.payload)
            _ = try header.fullBox(0...0)
            let children = try boxes(header.position..<header.end)
            guard let iinf = try unique(0x69696e66, in: children) else {
                throw ExtractionError.malformed("iinf 항목 목록이 없습니다.")
            }
            let items = try itemInfo(iinf)
            let exifIDs = Set(items.filter { $0.value.type == 0x45786966 }.map { $0.key })
            guard !exifIDs.isEmpty else { return nil }
            guard let pitm = try unique(0x7069746d, in: children) else {
                throw ExtractionError.malformed("EXIF를 선택할 기본 이미지 pitm이 없습니다.")
            }
            var primaryReader = Reader(data, pitm.payload)
            let primaryVersion = try primaryReader.fullBox(0...1)
            let primary = try primaryReader.uint(primaryVersion == 0 ? 2 : 4)
            try primaryReader.finished()
            guard primary != 0, let primaryItem = items[primary], primaryItem.type != 0x45786966 else {
                throw ExtractionError.malformed("pitm이 유효한 이미지 항목을 가리키지 않습니다.")
            }
            guard let iref = try unique(0x69726566, in: children) else {
                throw ExtractionError.malformed("EXIF 항목의 이미지 연결 iref가 없습니다.")
            }
            let selected = try associatedEXIF(iref, primary: primary, exifIDs: exifIDs, items: items)
            // 썸네일·보조 이미지에만 연결된 EXIF를 기본 이미지에 섞지 않는다.
            guard let id = selected else { return nil }
            guard items[id]?.protection == 0 else {
                throw ExtractionError.unsupported("암호화되거나 보호된 EXIF 항목")
            }
            guard let iloc = try unique(0x696c6f63, in: children) else {
                throw ExtractionError.malformed("EXIF 항목 위치 iloc가 없습니다.")
            }
            let idat = try unique(0x69646174, in: children)
            let ranges = try itemRanges(iloc, id: id, idat: idat)
            let total = try ranges.reduce(UInt64(0)) { try add($0, UInt64($1.count)) }
            guard total >= 4 else { throw ExtractionError.malformed("EXIF 오프셋 필드가 잘렸습니다.") }
            var prefix = Reader(try copy(ranges, start: 0, length: 4), 0..<4)
            let start = try add(4, prefix.uint(4))
            guard start <= total, total - start >= 8 else {
                throw ExtractionError.malformed("EXIF TIFF 시작 오프셋이 경계를 벗어났습니다.")
            }
            guard total - start <= UInt64(maximumTIFFBytes) else {
                throw ExtractionError.unsupported("TIFF가 자원 안전 한도 16MiB를 초과합니다.")
            }
            return try copy(ranges, start: start, length: Int(total - start))
        }

        private func itemInfo(_ box: Box) throws -> [UInt64: Item] {
            var reader = Reader(data, box.payload)
            let version = try reader.fullBox(0...1)
            let count = try reader.uint(version == 0 ? 2 : 4)
            guard count <= UInt64(maximumEntries), count <= UInt64(reader.remaining / 8) else {
                throw ExtractionError.malformed("iinf 항목 수가 범위를 벗어났습니다.")
            }
            var result: [UInt64: Item] = [:]
            for _ in 0..<Int(count) {
                let entry = try reader.box()
                guard entry.type == 0x696e6665 else {
                    throw ExtractionError.malformed("iinf 내부에 infe가 아닌 항목이 있습니다.")
                }
                var info = Reader(data, entry.payload)
                // v0/v1에는 item_type이 없어 EXIF임을 확정할 수 없다.
                let entryVersion = try info.fullBox(2...3, allowFlags: true)
                let id = try info.uint(entryVersion == 2 ? 2 : 4)
                let protection = try info.uint(2)
                let type = try info.uint(4)
                try info.string() // item_name
                if type == 0x6d696d65 { // mime
                    try info.string() // content_type
                    if info.remaining > 0 { try info.string() } // 선택 content_encoding
                } else if type == 0x75726920 { // uri
                    try info.string()
                }
                try info.finished()
                guard id != 0, result[id] == nil else {
                    throw ExtractionError.malformed("항목 ID가 0이거나 중복됩니다.")
                }
                result[id] = Item(type: type, protection: protection)
            }
            try reader.finished()
            return result
        }

        private func associatedEXIF(_ box: Box, primary: UInt64, exifIDs: Set<UInt64>,
                                    items: [UInt64: Item]) throws -> UInt64? {
            var reader = Reader(data, box.payload)
            let version = try reader.fullBox(0...1)
            let width = version == 0 ? 2 : 4
            var matches = Set<UInt64>()
            var seen = Set<UInt64>()
            var references = 0
            while reader.remaining > 0 {
                references += 1
                guard references <= maximumEntries else {
                    throw ExtractionError.unsupported("항목 참조 수가 안전 한도를 초과합니다.")
                }
                let reference = try reader.box()
                guard reference.type == 0x63647363 else { continue } // cdsc
                var link = Reader(data, reference.payload)
                let from = try link.uint(width)
                let count = try link.uint(2)
                guard count > 0, count <= UInt64(link.remaining / width), items[from] != nil,
                      seen.insert(from).inserted else {
                    throw ExtractionError.malformed("cdsc 참조의 개수 또는 출발 항목이 유효하지 않습니다.")
                }
                var targets = Set<UInt64>()
                for _ in 0..<Int(count) {
                    let to = try link.uint(width)
                    guard items[to] != nil, targets.insert(to).inserted, to != from else {
                        throw ExtractionError.malformed("cdsc 참조의 대상 항목이 유효하지 않습니다.")
                    }
                    if to == primary && exifIDs.contains(from) { matches.insert(from) }
                }
                try link.finished()
            }
            guard matches.count <= 1 else {
                throw ExtractionError.unsupported("기본 이미지에 여러 EXIF 항목이 연결되어 있습니다.")
            }
            return matches.first
        }

        private func itemRanges(_ box: Box, id: UInt64, idat: Box?) throws -> [Range<Int>] {
            var reader = Reader(data, box.payload)
            let version = try reader.fullBox(0...2)
            let sizes = try reader.uint(1)
            let baseAndIndex = try reader.uint(1)
            let offsetWidth = Int(sizes >> 4)
            let lengthWidth = Int(sizes & 15)
            let baseWidth = Int(baseAndIndex >> 4)
            let indexWidth = version == 0 ? 0 : Int(baseAndIndex & 15)
            guard [offsetWidth, lengthWidth, baseWidth, indexWidth].allSatisfy({ $0 <= 8 }),
                  version != 0 || baseAndIndex & 15 == 0 else {
                throw ExtractionError.unsupported("iloc 정수 폭 또는 예약 비트가 유효하지 않습니다.")
            }
            let idWidth = version == 2 ? 4 : 2
            let count = try reader.uint(version == 2 ? 4 : 2)
            let minimum = idWidth + (version == 0 ? 0 : 2) + 2 + baseWidth + 2
            guard count <= UInt64(maximumEntries), count <= UInt64(reader.remaining / minimum) else {
                throw ExtractionError.malformed("iloc 항목 수가 범위를 벗어났습니다.")
            }
            var seen = Set<UInt64>()
            var result: [Range<Int>]?
            var extentTotal = 0
            for _ in 0..<Int(count) {
                let itemID = try reader.uint(idWidth)
                guard itemID != 0, seen.insert(itemID).inserted else {
                    throw ExtractionError.malformed("iloc 항목 ID가 0이거나 중복됩니다.")
                }
                let methodField = version == 0 ? 0 : try reader.uint(2)
                guard methodField & 0xfff0 == 0 else {
                    throw ExtractionError.malformed("iloc 저장 방식의 예약 비트가 0이 아닙니다.")
                }
                let method = methodField & 15
                let reference = try reader.uint(2)
                let base = try reader.uint(baseWidth)
                let extentCount = Int(try reader.uint(2))
                let extentWidth = indexWidth + offsetWidth + lengthWidth
                extentTotal += extentCount
                guard extentTotal <= maximumEntries,
                      extentWidth == 0 || extentCount <= reader.remaining / extentWidth else {
                    throw ExtractionError.malformed("iloc extent 수가 범위를 벗어났습니다.")
                }
                var origin = 0
                var limit = data.count
                if itemID == id {
                    guard reference == 0 else {
                        throw ExtractionError.unsupported("외부 파일을 참조하는 EXIF")
                    }
                    switch method {
                    case 0: break // 파일 시작 기준
                    case 1:
                        guard let idat = idat else {
                            throw ExtractionError.malformed("idat 저장 EXIF에 idat 박스가 없습니다.")
                        }
                        origin = idat.payload.lowerBound
                        limit = idat.payload.upperBound
                    default:
                        throw ExtractionError.unsupported("EXIF construction_method \(method)")
                    }
                    guard extentCount > 0, lengthWidth > 0 else {
                        throw ExtractionError.unsupported("EXIF extent의 명시적 길이가 없습니다.")
                    }
                    result = []
                }
                for _ in 0..<extentCount {
                    _ = try reader.uint(indexWidth)
                    let offset = try reader.uint(offsetWidth)
                    let length = try reader.uint(lengthWidth)
                    if itemID == id {
                        guard length > 0 else {
                            throw ExtractionError.unsupported("길이가 0인 EXIF extent")
                        }
                        let relative = try add(base, offset)
                        let available = UInt64(limit - origin)
                        guard relative <= available, length <= available - relative else {
                            throw ExtractionError.malformed("EXIF extent가 파일 또는 idat 경계를 벗어났습니다.")
                        }
                        let start = origin + Int(relative)
                        result?.append(start..<(start + Int(length)))
                    }
                }
            }
            try reader.finished()
            guard let result = result else {
                throw ExtractionError.malformed("선택한 EXIF의 iloc 항목이 없습니다.")
            }
            return result
        }

        private func add(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
            let (value, overflow) = a.addingReportingOverflow(b)
            guard !overflow else { throw ExtractionError.malformed("오프셋 합산이 넘쳤습니다.") }
            return value
        }

        /// 분할 extent를 논리적 순서로 읽으며 필요한 TIFF 범위만 복사한다.
        private func copy(_ ranges: [Range<Int>], start: UInt64, length: Int) throws -> Data {
            var skip = start
            var needed = length
            var output = Data()
            output.reserveCapacity(length)
            for range in ranges {
                if skip >= UInt64(range.count) {
                    skip -= UInt64(range.count)
                    continue
                }
                let begin = range.lowerBound + Int(skip)
                let count = min(needed, range.upperBound - begin)
                output.append(data[(data.startIndex + begin)..<(data.startIndex + begin + count)])
                needed -= count
                skip = 0
                if needed == 0 { return output }
            }
            throw ExtractionError.malformed("EXIF 논리 범위가 extent 경계를 벗어났습니다.")
        }
    }

    /// ImageIO에 넘기기 전에 TIFF 디렉터리·값·표준 하위 IFD의 범위를 검증한다.
    /// 픽셀과 MakerNote 내부의 제조사 전용 구조는 해석하지 않는다.
    private static func validatedTIFFWithoutXMP(_ data: Data) throws -> Data {
        guard data.count >= 8 else { throw ExtractionError.malformed("TIFF 헤더가 잘렸습니다.") }
        let little: Bool
        switch Array(data.prefix(2)) {
        case [0x49, 0x49]: little = true
        case [0x4d, 0x4d]: little = false
        default: throw ExtractionError.malformed("TIFF 바이트 순서 표시가 유효하지 않습니다.")
        }
        func uint(_ offset: Int, _ width: Int) throws -> UInt64 {
            guard offset >= 0, width <= data.count, offset <= data.count - width else {
                throw ExtractionError.malformed("TIFF 정수 필드가 경계를 벗어났습니다.")
            }
            var value: UInt64 = 0
            for index in 0..<width {
                let position = offset + (little ? width - index - 1 : index)
                value = (value << 8) | UInt64(data[data.startIndex + position])
            }
            return value
        }
        guard try uint(2, 2) == 42 else {
            throw ExtractionError.unsupported("표준 EXIF TIFF가 아닌 헤더입니다.")
        }
        let root = try uint(4, 4)
        guard root >= 8 else { throw ExtractionError.malformed("TIFF 기본 IFD가 없습니다.") }
        var pending: [(offset: UInt64, leaving: Bool)] = [(root, false)]
        var active = Set<UInt64>()
        var completed = Set<UInt64>()
        var directories: [Range<Int>] = []
        var externalValues: [Range<Int>] = []
        var replacements: [(range: Range<Int>, bytes: Data)] = []
        var totalEntries = 0
        let sizes: [UInt64] = [0, 1, 1, 2, 4, 8, 1, 1, 2, 4, 8, 4, 8, 4]
        while let visit = pending.popLast() {
            if visit.leaving {
                active.remove(visit.offset)
                completed.insert(visit.offset)
                continue
            }
            if completed.contains(visit.offset) { continue }
            guard active.insert(visit.offset).inserted else {
                throw ExtractionError.malformed("TIFF IFD 연결에 순환이 있습니다.")
            }
            guard active.count + completed.count <= 128 else {
                throw ExtractionError.unsupported("TIFF IFD 수가 안전 한도를 초과합니다.")
            }
            guard visit.offset >= 8, visit.offset <= UInt64(data.count - 2) else {
                throw ExtractionError.malformed("TIFF IFD 오프셋이 경계를 벗어났습니다.")
            }
            let offset = Int(visit.offset)
            let count = Int(try uint(offset, 2))
            totalEntries += count
            guard totalEntries <= maximumEntries else {
                throw ExtractionError.unsupported("TIFF 항목 수가 안전 한도를 초과합니다.")
            }
            guard data.count - offset >= 6, count <= (data.count - offset - 6) / 12 else {
                throw ExtractionError.malformed("TIFF IFD 항목 목록이 잘렸습니다.")
            }
            let directory = offset..<(offset + 6 + count * 12)
            guard !directories.contains(where: { $0.overlaps(directory) }) else {
                throw ExtractionError.malformed("TIFF IFD 디렉터리 영역이 겹칩니다.")
            }
            directories.append(directory)
            pending.append((visit.offset, true))
            var retained = Data()
            var retainedCount = 0
            for index in 0..<count {
                let entry = offset + 2 + index * 12
                let tag = try uint(entry, 2)
                let type = try uint(entry + 2, 2)
                let elements = try uint(entry + 4, 4)
                guard type > 0, type < UInt64(sizes.count) else {
                    throw ExtractionError.unsupported("TIFF 필드 형식 \(type)")
                }
                let bytes = elements * sizes[Int(type)] // UInt32 × 최대 8이므로 넘치지 않는다.
                let value = bytes <= 4 ? UInt64(entry + 8) : try uint(entry + 8, 4)
                guard value <= UInt64(data.count), bytes <= UInt64(data.count) - value else {
                    throw ExtractionError.malformed("TIFF 태그 값이 경계를 벗어났습니다.")
                }
                // 모든 표준 하위 IFD와 다음 IFD에서 tag700을 제거한다. 값의 실제
                // 저장 영역은 옮기지 않으므로 MakerNote 등 원본 상대 오프셋도 유지된다.
                if tag != 700 {
                    retained.append(data[(data.startIndex + entry)..<(data.startIndex + entry + 12)])
                    retainedCount += 1
                    if bytes > 4 { externalValues.append(Int(value)..<(Int(value) + Int(bytes))) }
                }
                if [UInt64(330), 34665, 34853, 40965].contains(tag) {
                    guard (type == 4 || type == 13), elements > 0,
                          tag == 330 || elements == 1 else {
                        throw ExtractionError.malformed("TIFF 하위 IFD 포인터 형식이 유효하지 않습니다.")
                    }
                    guard elements <= 128 else {
                        throw ExtractionError.unsupported("TIFF 하위 IFD 수가 안전 한도를 초과합니다.")
                    }
                    for element in 0..<Int(elements) {
                        let child = try uint(Int(value) + element * 4, 4)
                        if child != 0 { pending.append((child, false)) }
                    }
                }
            }
            let next = try uint(offset + 2 + count * 12, 4)
            if next != 0 { pending.append((next, false)) }
            if retainedCount != count {
                let high = UInt8(retainedCount >> 8)
                let low = UInt8(retainedCount & 0xff)
                var replacement = Data(little ? [low, high] : [high, low])
                replacement.append(retained)
                let nextPosition = offset + 2 + count * 12
                replacement.append(data[(data.startIndex + nextPosition)..<(data.startIndex + nextPosition + 4)])
                // 제거한 항목의 영역도 0으로 채워 IFD 길이와 기존 데이터 위치를 고정한다.
                replacement.append(Data(repeating: 0, count: directory.count - replacement.count))
                replacements.append((directory, replacement))
            }
        }
        // 다른 EXIF 값이 수정할 디렉터리 영역을 데이터로 참조하면 보존이 불가능하다.
        // 이러한 비정상 중첩은 ImageIO에 넘기지 않고 명시적으로 거부한다.
        for replacement in replacements {
            guard !externalValues.contains(where: { $0.overlaps(replacement.range) }) else {
                throw ExtractionError.malformed("XMP 제거 영역과 다른 EXIF 값의 저장 영역이 겹칩니다.")
            }
        }
        var result = Data(data)
        for replacement in replacements {
            let start = result.startIndex + replacement.range.lowerBound
            let end = result.startIndex + replacement.range.upperBound
            result.replaceSubrange(start..<end, with: replacement.bytes)
        }
        return result
    }
}

public enum PNGCompressionPreset: String, CaseIterable, Identifiable {
    case none
    case fast
    case balanced
    case small

    public static let displayOrder: [PNGCompressionPreset] = [.small, .balanced, .fast, .none]

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .none: return "압축 없음"
        case .fast: return "빠르게"
        case .balanced: return "균형"
        case .small: return "작게"
        }
    }
    public var compressionLevel: Int {
        switch self {
        case .none: return 0
        case .fast: return 3
        case .balanced: return 6
        case .small: return 9
        }
    }

    // 기존 수치는 표시할 때만 가까운 단계로 대응시키고, 선택 시에만 변경한다.
    public static func nearest(to level: Int) -> PNGCompressionPreset {
        let bounded = min(9, max(0, level))
        return allCases.min {
            let left = abs($0.compressionLevel - bounded)
            let right = abs($1.compressionLevel - bounded)
            return left == right ? $0.compressionLevel > $1.compressionLevel : left < right
        }!
    }
}

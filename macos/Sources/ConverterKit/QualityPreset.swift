public enum QualityPreset: String, CaseIterable, Identifiable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    case raw = "Raw"

    public var id: String { rawValue }
    public var label: String { rawValue }

    // Raw는 JPEG 최대 품질이며 RAW 파일 형식이나 무손실 출력을 뜻하지 않는다.
    public var jpegQuality: Int {
        switch self {
        case .low: return 60
        case .medium: return 80
        case .high: return 90
        case .raw: return 100
        }
    }

    public static func nearest(to quality: Int) -> QualityPreset {
        let bounded = min(100, max(1, quality))
        return allCases.min {
            let left = abs($0.jpegQuality - bounded)
            let right = abs($1.jpegQuality - bounded)
            return left == right ? $0.jpegQuality > $1.jpegQuality : left < right
        }!
    }
}

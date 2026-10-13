import SwiftUI
import ConverterKit

/// 패널과 돌출부의 소재·외곽선을 하나의 경로로 이어 이음선을 없앤다.
struct PanelOutline: Shape {
    var pointerX: CGFloat

    func path(in rect: CGRect) -> Path {
        let top = rect.minY + PanelPlacement.pointerHeight
        let radius = min(PanelPlacement.cornerRadius, rect.width / 2, (rect.height - PanelPlacement.pointerHeight) / 2)
        let half = PanelPlacement.pointerWidth / 2
        let center = rect.minX + PanelPlacement.pointerCenter(anchorX: pointerX, panelFrame: CGRect(origin: .zero, size: rect.size))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + radius, y: top))
        path.addLine(to: CGPoint(x: center - half - 3, y: top))
        path.addQuadCurve(to: CGPoint(x: center - half + 2, y: top - 2),
                          control: CGPoint(x: center - half, y: top))
        path.addLine(to: CGPoint(x: center - 3, y: rect.minY + 2))
        path.addQuadCurve(to: CGPoint(x: center + 3, y: rect.minY + 2),
                          control: CGPoint(x: center, y: rect.minY - 1))
        path.addLine(to: CGPoint(x: center + half - 2, y: top - 2))
        path.addQuadCurve(to: CGPoint(x: center + half + 3, y: top),
                          control: CGPoint(x: center + half, y: top))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: top))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: top + radius),
                          control: CGPoint(x: rect.maxX, y: top))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
                          control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius),
                          control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: top + radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: top),
                          control: CGPoint(x: rect.minX, y: top))
        path.closeSubpath()
        return path
    }
}

@MainActor final class PanelChromeState: ObservableObject {
    @Published var pointerX: CGFloat = PanelPlacement.defaultSize.width / 2
}

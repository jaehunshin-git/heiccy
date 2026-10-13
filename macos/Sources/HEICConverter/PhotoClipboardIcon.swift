import AppKit
import SwiftUI

/// 확정 heiccy SVG와 같은, 왼쪽 위를 원점으로 하는 공통 벡터 기하.
/// 규격과 원본은 docs/assets/branding/DESIGN.md에 기록한다.
enum PhotoClipboardIconGeometry {
    static let menuBarSize = CGSize(width: 16.2, height: 18)
    static let accessibilityDescription = "클립보드 심볼 — heiccy"
    static let pausedAccessibilityDescription = "heiccy — 자동 변환 일시정지됨"
    static let clipboardWidth: CGFloat = 13.25
    static let strokeWidth: CGFloat = 1.30
    static let eyeRadius: CGFloat = 0.72

    static func lineWidth(in size: CGSize) -> CGFloat {
        strokeWidth * max(0, min(size.width / 18, size.height / 20))
    }

    private static func transform(in rect: CGRect) -> CGAffineTransform {
        let scale = max(0, min(rect.width / 18, rect.height / 20))
        return CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                tx: rect.midX - 9 * scale,
                                ty: rect.midY - 10 * scale)
    }

    /// 브랜드 원본의 외곽·집게를 유지하고 얼굴은 출력 용도에 맞춰 따로 그린다.
    private static func clipboardCenterline(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let left = 9 - clipboardWidth / 2
        let right = 9 + clipboardWidth / 2
        path.move(to: CGPoint(x: 6, y: 3.5))
        path.addLine(to: CGPoint(x: left + 2, y: 3.5))
        path.addQuadCurve(to: CGPoint(x: left, y: 5.5), control: CGPoint(x: left, y: 3.5))
        path.addLine(to: CGPoint(x: left, y: 16.75))
        path.addQuadCurve(to: CGPoint(x: left + 2, y: 18.75), control: CGPoint(x: left, y: 18.75))
        path.addLine(to: CGPoint(x: right - 2, y: 18.75))
        path.addQuadCurve(to: CGPoint(x: right, y: 16.75), control: CGPoint(x: right, y: 18.75))
        path.addLine(to: CGPoint(x: right, y: 5.5))
        path.addQuadCurve(to: CGPoint(x: right - 2, y: 3.5), control: CGPoint(x: right, y: 3.5))
        path.addLine(to: CGPoint(x: 12, y: 3.5))
        path.addLine(to: CGPoint(x: 12, y: 2.25))
        path.addQuadCurve(to: CGPoint(x: 11, y: 1.25), control: CGPoint(x: 12, y: 1.25))
        path.addLine(to: CGPoint(x: 7, y: 1.25))
        path.addQuadCurve(to: CGPoint(x: 6, y: 2.25), control: CGPoint(x: 6, y: 1.25))
        path.closeSubpath()

        path.move(to: CGPoint(x: 6, y: 3.5))
        path.addLine(to: CGPoint(x: 6, y: 4.25))
        path.addQuadCurve(to: CGPoint(x: 7, y: 5.25), control: CGPoint(x: 6, y: 5.25))
        path.addLine(to: CGPoint(x: 11, y: 5.25))
        path.addQuadCurve(to: CGPoint(x: 12, y: 4.25), control: CGPoint(x: 12, y: 5.25))
        path.addLine(to: CGPoint(x: 12, y: 3.5))

        var placement = transform(in: rect)
        return path.copy(using: &placement)!
    }

    private static func smileCenterline(in rect: CGRect, forMenuBar: Bool) -> CGPath {
        let path = CGMutablePath()
        if forMenuBar {
            path.move(to: CGPoint(x: 7, y: 13.1))
            path.addQuadCurve(to: CGPoint(x: 11, y: 13.1), control: CGPoint(x: 9, y: 15.2))
        } else {
            path.move(to: CGPoint(x: 7.85, y: 12.4))
            path.addQuadCurve(to: CGPoint(x: 10.15, y: 12.4), control: CGPoint(x: 9, y: 13.55))
        }
        var placement = transform(in: rect)
        return path.copy(using: &placement)!
    }

    /// 메뉴바에서는 눈과 미소를 키워 1x·2x에서도 세 부분이 분리되도록 한다.
    /// 패널과 큰 로고는 확정된 원본 얼굴을 그대로 사용한다.
    static func silhouette(in rect: CGRect, forMenuBar: Bool = false) -> CGPath {
        let silhouette = CGMutablePath()
        guard rect.width > 0, rect.height > 0 else { return silhouette }
        let scale = min(rect.width / 18, rect.height / 20)
        silhouette.addPath(clipboardCenterline(in: rect).copy(strokingWithWidth: lineWidth(in: rect.size),
                                                             lineCap: .round, lineJoin: .round, miterLimit: 2))
        silhouette.addPath(smileCenterline(in: rect, forMenuBar: forMenuBar)
            .copy(strokingWithWidth: (forMenuBar ? 1.50 : strokeWidth) * scale,
                  lineCap: .round, lineJoin: .round, miterLimit: 2))
        let eyes = CGMutablePath()
        let radius: CGFloat = forMenuBar ? 1.10 : eyeRadius
        let eyeY: CGFloat = forMenuBar ? 10.2 : 10.9
        for x: CGFloat in [6.25, 11.75] {
            eyes.addEllipse(in: CGRect(x: x - radius, y: eyeY - radius,
                                      width: radius * 2, height: radius * 2))
        }
        silhouette.addPath(eyes, transform: transform(in: rect))
        return silhouette
    }

    /// 시스템이 template 이미지의 색을 조절하며, 1x·2x 배율에서 벡터로 그린다.
    static func makeTemplateImage(size: CGSize = menuBarSize, isPaused: Bool = false) -> NSImage {
        let image = NSImage(size: size, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setAllowsAntialiasing(true)
            context.setShouldAntialias(true)
            context.setFillColor(NSColor.black.withAlphaComponent(isPaused ? 0.55 : 1).cgColor)
            context.addPath(silhouette(in: rect, forMenuBar: true))
            context.fillPath()
            if isPaused {
                let placement = transform(in: rect)
                context.saveGState()
                context.concatenate(placement)
                // 옅은 심볼과 진한 일시정지 기호로 상태를 구분한다.
                context.setBlendMode(.clear)
                context.fillEllipse(in: CGRect(x: 9.5, y: 11.5, width: 8, height: 8))
                context.setBlendMode(.normal)
                context.setFillColor(NSColor.black.cgColor)
                context.fill(CGRect(x: 11, y: 13, width: 1.7, height: 5))
                context.fill(CGRect(x: 14, y: 13, width: 1.7, height: 5))
                context.restoreGState()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = isPaused ? pausedAccessibilityDescription : accessibilityDescription
        return image
    }
}

/// 패널에서 사용할 때 크기와 색상만 지정하는 공통 심볼.
struct PhotoClipboardIconShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(PhotoClipboardIconGeometry.silhouette(in: rect))
    }
}

struct PhotoClipboardIcon: View {
    var body: some View {
        PhotoClipboardIconShape()
            .fill(.primary)
            .accessibilityLabel(PhotoClipboardIconGeometry.accessibilityDescription)
            .accessibilityAddTraits(.isImage)
    }
}

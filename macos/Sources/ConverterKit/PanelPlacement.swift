import Foundation
import CoreGraphics

/// AppKit 화면 좌표(아래쪽 원점)에서 메뉴 막대 아이콘 아래의 패널 영역을 계산한다.
public enum PanelPlacement {
    public static let pointerHeight: CGFloat = 12
    public static let pointerWidth: CGFloat = 28
    public static let cornerRadius: CGFloat = 20
    public static let defaultSize = CGSize(width: 320, height: 520 + pointerHeight)
    public static let minimumSize = CGSize(width: 300, height: 520 + pointerHeight)
    public static let emptyHeight: CGFloat = 288 + pointerHeight
    public static let edgeMargin: CGFloat = 8
    public static let anchorGap: CGFloat = 3

    /// 화면 가장자리에서 창이 이동해도 돌출부는 아이콘을 향한다. 모서리와는 겹치지 않는다.
    public static func pointerCenter(anchorX: CGFloat, panelFrame: CGRect) -> CGFloat {
        let inset = min(cornerRadius + pointerWidth / 2 + 4, panelFrame.width / 2)
        return min(max(anchorX - panelFrame.minX, inset), panelFrame.width - inset)
    }

    /// 처음 세 개의 썸네일을 위한 공간을 늘리고 긴 목록은 스크롤로 표시한다.
    public static func preferredHeight(fileCount: Int, stagedCount: Int, settingsExpanded: Bool = false, outputFormat: String = "jpeg") -> CGFloat {
        let rows = min(3, max(0, fileCount))
        let listHeight: CGFloat = rows == 0 ? 0 : 100 + CGFloat(rows - 1) * 64
        let selectionHeight: CGFloat = stagedCount > 0 ? 180 : 0
        // PNG의 추가 설명 높이도 반영해 목록 아래에 불필요한 여백을 남기지 않는다.
        let settingsHeight: CGFloat = settingsExpanded ? (outputFormat == "png" ? 164 : 136) : 0
        return min(800 + pointerHeight, defaultSize.height + listHeight + selectionHeight) + settingsHeight
    }

    public static func frame(anchor: CGRect, visibleFrame: CGRect, size: CGSize) -> CGRect {
        let bounds = availableFrame(anchor: anchor, visibleFrame: visibleFrame)
        let width = min(max(1, size.width), bounds.width)
        let height = min(max(1, size.height), bounds.height)
        let x = min(max(anchor.midX - width / 2, bounds.minX), bounds.maxX - width)
        return CGRect(x: x, y: bounds.maxY - height, width: width, height: height)
    }

    public static func availableFrame(anchor: CGRect, visibleFrame: CGRect) -> CGRect {
        // 작은 화면에서도 inset이 음수 크기를 만들지 않도록 제한한다.
        let horizontalMargin = min(edgeMargin, max(0, (visibleFrame.width - 1) / 2))
        let verticalMargin = min(edgeMargin, max(0, (visibleFrame.height - 1) / 2))
        let left = visibleFrame.minX + horizontalMargin
        let bottom = visibleFrame.minY + verticalMargin
        let top = max(bottom + 1, min(anchor.minY - anchorGap, visibleFrame.maxY))
        return CGRect(x: left, y: bottom,
                      width: max(1, visibleFrame.width - horizontalMargin * 2), height: top - bottom)
    }
}

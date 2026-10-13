import XCTest
import CoreGraphics
@testable import ConverterKit

final class PanelPlacementTests: XCTestCase {
    func testEmptyClipboardContractsDownwardWithoutMovingIconAnchor() {
        let anchor = CGRect(x: 880, y: 878, width: 32, height: 22)
        let visible = CGRect(x: 0, y: 40, width: 1440, height: 838)
        let populated = PanelPlacement.frame(anchor: anchor, visibleFrame: visible, size: PanelPlacement.defaultSize)
        let empty = PanelPlacement.frame(anchor: anchor, visibleFrame: visible,
            size: CGSize(width: populated.width, height: PanelPlacement.emptyHeight))
        XCTAssertLessThan(empty.height, populated.height)
        XCTAssertEqual(empty.maxY, populated.maxY)
        XCTAssertEqual(empty.midX, populated.midX)
        XCTAssertEqual(empty.width, populated.width)
        XCTAssertTrue(visible.contains(empty))
    }

    func testFileHeightGrowsForThumbnailsAndStopsAfterThreeRows() {
        XCTAssertEqual(PanelPlacement.preferredHeight(fileCount: 0, stagedCount: 0), 532)
        XCTAssertEqual(PanelPlacement.preferredHeight(fileCount: 1, stagedCount: 0), 632)
        XCTAssertEqual(PanelPlacement.preferredHeight(fileCount: 2, stagedCount: 0), 696)
        XCTAssertEqual(PanelPlacement.preferredHeight(fileCount: 3, stagedCount: 0), 760)
        XCTAssertEqual(PanelPlacement.preferredHeight(fileCount: 100, stagedCount: 0), 760)
        XCTAssertEqual(PanelPlacement.preferredHeight(fileCount: 0, stagedCount: 5), 712)
        XCTAssertEqual(PanelPlacement.preferredHeight(fileCount: 100, stagedCount: 5), 812)
    }

    func testExpandedSettingsPreserveThumbnailSpace() {
        XCTAssertEqual(PanelPlacement.preferredHeight(fileCount: 0, stagedCount: 0, settingsExpanded: true), 668)
        XCTAssertEqual(PanelPlacement.preferredHeight(fileCount: 1, stagedCount: 0, settingsExpanded: true), 768)
        XCTAssertEqual(PanelPlacement.preferredHeight(fileCount: 3, stagedCount: 0, settingsExpanded: true), 896)
        XCTAssertEqual(PanelPlacement.preferredHeight(fileCount: 100, stagedCount: 5, settingsExpanded: true), 948)
        XCTAssertEqual(PanelPlacement.preferredHeight(fileCount: 0, stagedCount: 0, settingsExpanded: true, outputFormat: "png"), 696)
        XCTAssertEqual(PanelPlacement.preferredHeight(fileCount: 3, stagedCount: 0, settingsExpanded: true, outputFormat: "png"), 924)
        // 펼침 상태를 되돌리면 기존 간결한 높이 정책으로 돌아간다.
        XCTAssertEqual(PanelPlacement.preferredHeight(fileCount: 3, stagedCount: 0, settingsExpanded: false), 760)
    }

    func testExpandedSettingsFitScreenWithoutMovingTopOrChangingWidth() {
        let anchor = CGRect(x: 880, y: 878, width: 32, height: 22)
        let visible = CGRect(x: 0, y: 40, width: 1440, height: 838)
        let compact = PanelPlacement.frame(anchor: anchor, visibleFrame: visible,
            size: CGSize(width: 380, height: PanelPlacement.preferredHeight(fileCount: 3, stagedCount: 0)))
        let expanded = PanelPlacement.frame(anchor: anchor, visibleFrame: visible,
            size: CGSize(width: 380, height: PanelPlacement.preferredHeight(fileCount: 3, stagedCount: 0, settingsExpanded: true)))
        XCTAssertEqual(expanded.maxY, compact.maxY)
        XCTAssertEqual(expanded.width, compact.width)
        XCTAssertGreaterThan(expanded.height, compact.height)
        XCTAssertTrue(visible.contains(expanded))
    }

    func testFileExpansionKeepsTopAndWidthAndFitsSmallScreen() {
        let anchor = CGRect(x: 880, y: 878, width: 32, height: 22)
        let visible = CGRect(x: 0, y: 40, width: 1440, height: 838)
        let empty = PanelPlacement.frame(anchor: anchor, visibleFrame: visible, size: PanelPlacement.defaultSize)
        let populated = PanelPlacement.frame(anchor: anchor, visibleFrame: visible,
            size: CGSize(width: PanelPlacement.defaultSize.width, height: PanelPlacement.preferredHeight(fileCount: 3, stagedCount: 0)))
        XCTAssertEqual(empty.maxY, populated.maxY)
        XCTAssertEqual(empty.width, populated.width)
        XCTAssertGreaterThan(populated.height, empty.height)
        let small = CGRect(x: 0, y: 400, width: 1440, height: 478)
        let constrained = PanelPlacement.frame(anchor: anchor, visibleFrame: small, size: populated.size)
        XCTAssertTrue(small.contains(constrained))
        XCTAssertLessThan(constrained.height, populated.height)
    }

    func testPanelOpensBelowIconAndStaysCentered() {
        let anchor = CGRect(x: 880, y: 878, width: 32, height: 22)
        let visible = CGRect(x: 0, y: 40, width: 1440, height: 838)
        let frame = PanelPlacement.frame(anchor: anchor, visibleFrame: visible,
                                         size: PanelPlacement.defaultSize)
        XCTAssertEqual(frame.size, CGSize(width: 320, height: 532))
        XCTAssertEqual(frame.midX, anchor.midX)
        XCTAssertEqual(frame.maxY, anchor.minY - 3)
        XCTAssertTrue(visible.contains(frame))
    }

    func testBothMenuBarEdgesClampInsideDisplay() {
        let visible = CGRect(x: 0, y: 80, width: 1440, height: 798)
        for iconX in [CGFloat(0), 1410] {
            let anchor = CGRect(x: iconX, y: 878, width: 30, height: 22)
            let frame = PanelPlacement.frame(anchor: anchor, visibleFrame: visible,
                                             size: CGSize(width: 520, height: 650))
            XCTAssertTrue(visible.contains(frame))
            XCTAssertGreaterThanOrEqual(frame.minX, visible.minX + 8)
            XCTAssertLessThanOrEqual(frame.maxX, visible.maxX - 8)
            XCTAssertEqual(frame.maxY, 875)
        }
    }

    func testSecondaryDisplayUsesItsOwnNegativeOriginAndDockBounds() {
        let visible = CGRect(x: -1920, y: -200, width: 1860, height: 1056)
        let anchor = CGRect(x: -220, y: 856, width: 34, height: 24)
        let frame = PanelPlacement.frame(anchor: anchor, visibleFrame: visible,
                                         size: CGSize(width: 520, height: 650))
        XCTAssertTrue(visible.contains(frame))
        XCTAssertEqual(frame.maxX, visible.maxX - 8)
        XCTAssertEqual(frame.maxY, anchor.minY - 3)
    }

    func testSmallDisplayShrinksPanelInsteadOfCoveringMenuBarOrDock() {
        let visible = CGRect(x: 1500, y: 100, width: 420, height: 400)
        let anchor = CGRect(x: 1800, y: 500, width: 30, height: 24)
        let frame = PanelPlacement.frame(anchor: anchor, visibleFrame: visible,
                                         size: CGSize(width: 520, height: 650))
        XCTAssertEqual(frame.size, CGSize(width: 404, height: 389))
        XCTAssertTrue(visible.contains(frame))
        XCTAssertEqual(frame.minY, visible.minY + 8)
    }

    func testResizeKeepsTopAttachedAndNotchedMenuBarRemainsClear() {
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 944)
        let anchor = CGRect(x: 1150, y: 944, width: 34, height: 38)
        let compact = PanelPlacement.frame(anchor: anchor, visibleFrame: visible,
                                           size: CGSize(width: 520, height: 650))
        let expanded = PanelPlacement.frame(anchor: anchor, visibleFrame: visible,
                                            size: CGSize(width: 660, height: 800))
        XCTAssertEqual(compact.maxY, expanded.maxY)
        XCTAssertEqual(compact.midX, expanded.midX)
        XCTAssertLessThan(expanded.maxY, anchor.minY)
    }

    func testPointerFollowsIconWhenPanelIsClampedOrResized() {
        let visible = CGRect(x: -1440, y: 0, width: 1440, height: 878)
        let anchor = CGRect(x: -90, y: 878, width: 50, height: 22)
        let iconX: CGFloat = -78
        for width in [PanelPlacement.minimumSize.width, PanelPlacement.defaultSize.width, 660] {
            let frame = PanelPlacement.frame(anchor: anchor, visibleFrame: visible,
                                            size: CGSize(width: width, height: 532))
            XCTAssertEqual(frame.minX + PanelPlacement.pointerCenter(anchorX: iconX, panelFrame: frame), iconX)
        }
    }

    func testPointerAvoidsRoundedCornersOnTinyScreens() {
        let frame = CGRect(x: 100, y: 0, width: 380, height: 532)
        let margin = PanelPlacement.cornerRadius + PanelPlacement.pointerWidth / 2 + 4
        XCTAssertEqual(PanelPlacement.pointerCenter(anchorX: 100, panelFrame: frame), margin)
        XCTAssertEqual(PanelPlacement.pointerCenter(anchorX: 500, panelFrame: frame), frame.width - margin)
        XCTAssertEqual(PanelPlacement.pointerCenter(anchorX: 500, panelFrame: CGRect(x: 0, y: 0, width: 40, height: 50)), 20)
    }
}

import AppKit

/// 창 없는 상태에서도 상태 메뉴가 키보드 입력을 받을 수 있게 하는 임시 포커스 창.
@MainActor final class KeyboardMenuFocusWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(anchor: NSRect) {
        super.init(contentRect: NSRect(x: anchor.midX, y: anchor.minY - 1, width: 1, height: 1),
                   styleMask: .borderless, backing: .buffered, defer: false)
        alphaValue = 0
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        setAccessibilityElement(false)
    }
}

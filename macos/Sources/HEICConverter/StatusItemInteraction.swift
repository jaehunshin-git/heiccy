import AppKit

enum StatusItemInteraction {
    static func opensMenu(for event: NSEvent?, currentModifiers: NSEvent.ModifierFlags = []) -> Bool {
        // 상태 메뉴의 키보드 활성화는 Control 없는 합성 mouseUp으로 전달될 수 있다.
        // 이벤트에 기록된 키와 실제로 눌린 키를 함께 확인한다.
        event?.type != .leftMouseUp || event?.modifierFlags.contains(.control) == true
            || currentModifiers.contains(.control)
    }

    /// 아이콘을 누르는 중 발생한 포커스 이동은 mouseUp의 토글에 맡긴다.
    static func defersPanelDismissal(buttonFrame: NSRect?, mouseLocation: NSPoint,
                                    pressedMouseButtons: Int, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard let buttonFrame else { return false }
        return pressedMouseButtons & 1 != 0 && !modifiers.contains(.control)
            && buttonFrame.contains(mouseLocation)
    }
}

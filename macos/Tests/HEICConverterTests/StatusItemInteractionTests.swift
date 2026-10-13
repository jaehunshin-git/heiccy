import AppKit
import XCTest
@testable import HEICConverter

final class StatusItemInteractionTests: XCTestCase {
    @MainActor private func mouse(_ type: NSEvent.EventType,
                                  _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: modifiers,
                          timestamp: 0, windowNumber: 0, context: nil,
                          eventNumber: 1, clickCount: 1, pressure: 0)!
    }

    @MainActor func testOnlyOrdinaryLeftMouseUpTogglesPanel() {
        XCTAssertFalse(StatusItemInteraction.opensMenu(for: mouse(.leftMouseUp)))
        XCTAssertTrue(StatusItemInteraction.opensMenu(for: mouse(.rightMouseUp)))
        XCTAssertTrue(StatusItemInteraction.opensMenu(for: mouse(.leftMouseUp, .control)))
        XCTAssertTrue(StatusItemInteraction.opensMenu(for: nil))
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                  timestamp: 0, windowNumber: 0, context: nil, characters: " ",
                                  charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
        XCTAssertTrue(StatusItemInteraction.opensMenu(for: key))
    }

    @MainActor func testControlFromEitherEventOrLiveModifiersOpensMenu() {
        XCTAssertTrue(StatusItemInteraction.opensMenu(for: mouse(.leftMouseUp), currentModifiers: .control))
        XCTAssertTrue(StatusItemInteraction.opensMenu(for: mouse(.leftMouseUp, .control), currentModifiers: []))
        XCTAssertTrue(StatusItemInteraction.opensMenu(for: mouse(.leftMouseUp, .control), currentModifiers: .control))
        XCTAssertTrue(StatusItemInteraction.opensMenu(for: mouse(.leftMouseUp, .control), currentModifiers: .command))
    }

    @MainActor func testLiveModifiersWithoutControlKeepOrdinaryLeftClickToggle() {
        for modifiers: NSEvent.ModifierFlags in [[], .command, .shift, [.command, .shift]] {
            XCTAssertFalse(StatusItemInteraction.opensMenu(for: mouse(.leftMouseUp), currentModifiers: modifiers))
        }
    }

    @MainActor func testRightClickKeyboardAndAccessibilityStillOpenMenuWithLiveModifiers() {
        let right = mouse(.rightMouseUp)
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                  timestamp: 0, windowNumber: 0, context: nil, characters: " ",
                                  charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
        for modifiers: NSEvent.ModifierFlags in [[], .control, .command, .shift] {
            XCTAssertTrue(StatusItemInteraction.opensMenu(for: right, currentModifiers: modifiers))
            XCTAssertTrue(StatusItemInteraction.opensMenu(for: key, currentModifiers: modifiers))
            XCTAssertTrue(StatusItemInteraction.opensMenu(for: nil, currentModifiers: modifiers))
        }
    }

    func testOwnStatusButtonMouseDownKeepsPanelForToggle() {
        let frame = NSRect(x: 100, y: 900, width: 32, height: 22)
        XCTAssertTrue(StatusItemInteraction.defersPanelDismissal(buttonFrame: frame,
            mouseLocation: NSPoint(x: 116, y: 910), pressedMouseButtons: 1, modifiers: []))
        XCTAssertFalse(StatusItemInteraction.defersPanelDismissal(buttonFrame: frame,
            mouseLocation: NSPoint(x: 90, y: 910), pressedMouseButtons: 1, modifiers: []))
        XCTAssertFalse(StatusItemInteraction.defersPanelDismissal(buttonFrame: nil,
            mouseLocation: NSPoint(x: 116, y: 910), pressedMouseButtons: 1, modifiers: []))
    }

    func testKeyboardFocusMoveAndContextClickStillDismissPanel() {
        let frame = NSRect(x: 100, y: 900, width: 32, height: 22)
        let point = NSPoint(x: 116, y: 910)
        for (buttons, modifiers): (Int, NSEvent.ModifierFlags) in [(0, []), (2, []), (1, .control)] {
            XCTAssertFalse(StatusItemInteraction.defersPanelDismissal(buttonFrame: frame,
                mouseLocation: point, pressedMouseButtons: buttons, modifiers: modifiers))
        }
    }
}

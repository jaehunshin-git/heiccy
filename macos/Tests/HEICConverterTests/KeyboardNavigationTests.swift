import AppKit
import XCTest
@testable import HEICConverter

final class KeyboardNavigationTests: XCTestCase {
    @MainActor private final class Document: NSView {
        let documentFlipped: Bool
        init(flipped: Bool) {
            self.documentFlipped = flipped
            super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 1000))
        }
        required init?(coder: NSCoder) { fatalError() }
        override var isFlipped: Bool { documentFlipped }
    }

    @MainActor private func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                        timestamp: 0, windowNumber: 0, context: nil,
                        characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
    }

    @MainActor func testKeyboardScrollReachesBothEndsAndClampsForBothCoordinateSystems() {
        for flipped in [true, false] {
            let scroll = PanelScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
            scroll.documentView = Document(flipped: flipped)
            let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = scroll
            XCTAssertTrue(window.makeFirstResponder(scroll))
            XCTAssertTrue(window.firstResponder === scroll)
            let maximum = 1000 - scroll.contentView.bounds.height
            XCTAssertTrue(scroll.acceptsFirstResponder)
            XCTAssertTrue(scroll.scrollWithKeyboard(key(115)))
            XCTAssertEqual(scroll.contentView.bounds.minY, flipped ? 0 : maximum)
            XCTAssertTrue(scroll.scrollWithKeyboard(key(125)))
            XCTAssertEqual(scroll.contentView.bounds.minY, flipped ? 32 : maximum - 32)
            XCTAssertTrue(scroll.scrollWithKeyboard(key(121)))
            XCTAssertEqual(scroll.contentView.bounds.minY, flipped ? 232 : maximum - 232)
            XCTAssertTrue(scroll.scrollWithKeyboard(key(119)))
            for _ in 0..<5 { XCTAssertTrue(scroll.scrollWithKeyboard(key(125))) }
            XCTAssertEqual(scroll.contentView.bounds.minY, flipped ? maximum : 0)
            XCTAssertTrue(scroll.scrollWithKeyboard(key(116)))
            XCTAssertEqual(scroll.contentView.bounds.minY, flipped ? maximum - 200 : 200)
            XCTAssertTrue(scroll.scrollWithKeyboard(key(115)))
            for _ in 0..<5 { XCTAssertTrue(scroll.scrollWithKeyboard(key(126))) }
            XCTAssertEqual(scroll.contentView.bounds.minY, flipped ? 0 : maximum)
        }
    }

    @MainActor func testScrollDoesNotConsumeShortcutsOrOtherControlsKeys() {
        let scroll = PanelScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        scroll.documentView = Document(flipped: true)
        for modifiers: NSEvent.ModifierFlags in [.command, .control, .option, [.command, .shift]] {
            XCTAssertFalse(scroll.scrollWithKeyboard(key(125, modifiers: modifiers)))
        }
        for code: UInt16 in [48, 53, 49, 36, 35, 18, 43] { // Tab, Escape, Space, Return, P, 1, comma
            XCTAssertFalse(scroll.scrollWithKeyboard(key(code)))
        }
        XCTAssertEqual(scroll.contentView.bounds.minY, 0)
    }
}

import XCTest
@testable import HEICConverter

final class DeferredPanelDismissalTests: XCTestCase {
    @MainActor private final class Harness {
        var pressed = true
        var active = false
        var key = false
        var dismissCount = 0
        var callbacks: [@MainActor () -> Void] = []
        lazy var scheduler = FocusDismissalScheduler(
            shouldWaitForMouseUp: { [unowned self] in pressed },
            shouldDismiss: { [unowned self] in !active || !key },
            dismiss: { [unowned self] in dismissCount += 1 },
            enqueue: { [unowned self] in callbacks.append($0) })

        func drain() {
            let queued = callbacks
            callbacks.removeAll()
            queued.forEach { $0() }
        }
    }

    @MainActor func testWaitsForReleaseAndEnqueuesOnlyOnce() {
        let state = Harness()
        state.scheduler.schedule()
        state.scheduler.poll()
        XCTAssertTrue(state.callbacks.isEmpty)
        XCTAssertEqual(state.dismissCount, 0)
        state.pressed = false
        state.scheduler.poll()
        state.scheduler.poll()
        XCTAssertEqual(state.callbacks.count, 1)
        XCTAssertEqual(state.dismissCount, 0)
        state.drain()
        XCTAssertEqual(state.dismissCount, 1)
    }

    @MainActor func testEitherLostFocusStateDismissesButBothRestoredKeepPanel() {
        for (active, key) in [(false, false), (false, true), (true, false), (true, true)] {
            let state = Harness()
            state.active = active
            state.key = key
            state.pressed = false
            state.scheduler.schedule()
            state.drain()
            XCTAssertEqual(state.dismissCount, active && key ? 0 : 1)
        }
    }

    @MainActor func testCancelWhilePressedPreventsLaterReleaseFromEnqueueing() {
        let state = Harness()
        state.scheduler.schedule()
        state.scheduler.cancel()
        state.pressed = false
        state.scheduler.poll()
        state.drain()
        XCTAssertTrue(state.callbacks.isEmpty)
        XCTAssertEqual(state.dismissCount, 0)
    }

    @MainActor func testCancelAfterQueuedCallbackPreventsDismissal() {
        let state = Harness()
        state.pressed = false
        state.scheduler.schedule()
        XCTAssertEqual(state.callbacks.count, 1)
        state.scheduler.cancel()
        state.drain()
        XCTAssertEqual(state.dismissCount, 0)
    }

    @MainActor func testReplacementScheduleInvalidatesOldQueuedCallback() {
        let state = Harness()
        state.pressed = false
        state.scheduler.schedule()
        state.pressed = true
        state.scheduler.schedule()
        state.drain()
        XCTAssertEqual(state.dismissCount, 0)
        state.pressed = false
        state.scheduler.poll()
        state.drain()
        XCTAssertEqual(state.dismissCount, 1)
    }

    @MainActor func testFocusIsCheckedWhenQueuedCallbackRuns() {
        let state = Harness()
        state.pressed = false
        state.scheduler.schedule()
        state.active = true
        state.key = true
        state.drain()
        XCTAssertEqual(state.dismissCount, 0)

        state.scheduler.schedule()
        state.key = false
        state.drain()
        XCTAssertEqual(state.dismissCount, 1)
    }
}

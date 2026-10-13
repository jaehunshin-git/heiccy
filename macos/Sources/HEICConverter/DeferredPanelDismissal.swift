import Foundation

/// 아이콘을 누르는 동안 보류한 포커스 닫기를 mouseUp 이후에 다시 판단한다.
@MainActor final class FocusDismissalScheduler {
    private let shouldWaitForMouseUp: @MainActor () -> Bool
    private let shouldDismiss: @MainActor () -> Bool
    private let dismiss: @MainActor () -> Void
    private let enqueue: (@escaping @MainActor () -> Void) -> Void
    private var pendingID: UUID?
    private var timer: Timer?

    convenience init(shouldWaitForMouseUp: @escaping @MainActor () -> Bool,
                     shouldDismiss: @escaping @MainActor () -> Bool,
                     dismiss: @escaping @MainActor () -> Void) {
        self.init(shouldWaitForMouseUp: shouldWaitForMouseUp,
                  shouldDismiss: shouldDismiss, dismiss: dismiss,
                  enqueue: { callback in
                      // 버튼의 추적 루프가 끝나고 mouseUp action이 처리된 뒤 실행한다.
                      RunLoop.main.perform(inModes: [.default]) {
                          MainActor.assumeIsolated { callback() }
                      }
                  })
    }

    /// 테스트에서는 default 모드의 콜백 큐를 주입해 취소 경합을 결정적으로 검증한다.
    init(shouldWaitForMouseUp: @escaping @MainActor () -> Bool,
         shouldDismiss: @escaping @MainActor () -> Bool,
         dismiss: @escaping @MainActor () -> Void,
         enqueue: @escaping (@escaping @MainActor () -> Void) -> Void) {
        self.shouldWaitForMouseUp = shouldWaitForMouseUp
        self.shouldDismiss = shouldDismiss
        self.dismiss = dismiss
        self.enqueue = enqueue
    }

    func schedule() {
        cancel()
        pendingID = UUID()
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        poll()
    }

    /// 이미 예약한 콜백도 무효화한다.
    func cancel() {
        pendingID = nil
        timer?.invalidate()
        timer = nil
    }

    /// 타이머와 수동 테스트가 같은 해제 판정을 사용하며 콜백 중복 예약을 막는다.
    func poll() {
        guard let id = pendingID, timer != nil, !shouldWaitForMouseUp() else { return }
        timer?.invalidate()
        timer = nil
        enqueue { [weak self] in
            guard let self, self.pendingID == id else { return }
            self.pendingID = nil
            if self.shouldDismiss() { self.dismiss() }
        }
    }

    deinit { timer?.invalidate() }
}

import AppKit

/// 전역 마우스 입력 없이 앱 이벤트 큐 → 상태 버튼 → 클릭 핸들러를 검증한다.
/// WindowServer의 실제 아이콘 클릭과 별도로 일반 번들 재실행에서 수행한다.
@MainActor func panelStartupSmokeTest(button: NSStatusBarButton, panel: NSPanel,
                                     leftClickCount: () -> Int) async -> Bool {
    var passed = true
    let focusTarget = [NSWorkspace.shared.frontmostApplication,
                       NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first]
        .compactMap { $0 }.first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }

    func check(_ label: String, _ condition: @autoclosure () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        let result = condition()
        print("시작 패널 검증 [\(label)]: \(result ? "성공" : "실패")")
        fflush(stdout)
        if !result { passed = false }
    }

    func click() -> Bool {
        guard let window = button.window else { return false }
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: timestamp, windowNumber: window.windowNumber, context: nil,
            eventNumber: 11001, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
            timestamp: timestamp + 0.001, windowNumber: window.windowNumber, context: nil,
            eventNumber: 11002, clickCount: 1, pressure: 0) else { return false }
        // down의 추적 루프가 up을 기다릴 수 있어 두 이벤트 사이에서 양보하지 않는다.
        NSApp.postEvent(down, atStart: false)
        NSApp.postEvent(up, atStart: false)
        return true
    }

    await check("시작 시 숨김·클릭 전", !panel.isVisible && leftClickCount() == 0)
    let firstClick = click()
    await check("첫 클릭 이벤트 게시", firstClick)
    await check("첫 좌클릭 핸들러 도달", leftClickCount() == 1)
    await check("첫 좌클릭 표시·활성화·key", panel.isVisible && panel.isKeyWindow && NSApp.isActive)
    try? await Task.sleep(for: .milliseconds(150))
    await check("첫 표시 유지", panel.isVisible && panel.isKeyWindow)
    let secondClick = click()
    await check("두 번째 클릭 이벤트 게시", secondClick)
    await check("두 번째 좌클릭 핸들러 도달", leftClickCount() == 2)
    await check("두 번째 좌클릭 숨김", !panel.isVisible)
    try? await Task.sleep(for: .milliseconds(150))
    await check("숨김 후 다시 열리지 않음", !panel.isVisible)
    let thirdClick = click()
    await check("세 번째 클릭 이벤트 게시", thirdClick)
    await check("세 번째 좌클릭 핸들러 도달", leftClickCount() == 3)
    await check("세 번째 좌클릭 다시 표시", panel.isVisible && panel.isKeyWindow && NSApp.isActive)
    if let focusTarget {
        NSApp.yieldActivation(to: focusTarget)
        let activationRequested = focusTarget.activate(options: [])
        await check("외부 앱 포커스 요청", activationRequested)
        await check("외부 앱 이동 시 닫힘", !NSApp.isActive && !panel.isVisible)
    } else { await check("외부 앱 포커스 대상", false) }
    NSApp.activate(ignoringOtherApps: true)
    await check("재활성화 완료", NSApp.isActive)
    try? await Task.sleep(for: .milliseconds(150))
    await check("재활성화 시 숨김 유지", !panel.isVisible)
    return passed
}

import AppKit
import SwiftUI
import Combine
import ConverterKit
import ImageIO
import UniformTypeIdentifiers

final class ClipboardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        // 읽기 전용 목록에는 행별 포커스를 만들지 않고 패널에서도 스크롤 키를 받는다.
        if let scroll = contentView?.firstPanelScrollView(), scroll.scrollWithKeyboard(event) { return }
        super.keyDown(with: event)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation, NSMenuDelegate {
    private static var isKeyboardTest: Bool {
        CommandLine.arguments.contains("--keyboard-test") || Bundle.main.object(forInfoDictionaryKey: "HEICKeyboardTest") as? Bool == true
    }
    private static var isPanelStartupTest: Bool { CommandLine.arguments.contains("--panel-startup-test") }
    private let model: AppModel
    private var statusItem: NSStatusItem!
    private var panel: ClipboardPanel!
    private var settingsWindow: NSWindow?
    private let panelChrome = PanelChromeState()
    private var subscription: AnyCancellable?
    private var clipboardSubscription: AnyCancellable?
    private var noticeSubscription: AnyCancellable?
    private let noticeController = ClipboardNoticeController()
    private var clipboardLayoutScheduled = false
    private var populatedPanelHeight: CGFloat?
    private var isPositioningPanel = false
    private var smokePasteboard: NSPasteboard?
    private var smokeDomain: String?
    private var keyboardFixture: URL?
    private var startupLeftClickCount = 0
    private var statusMenuOpenCount = 0
    private var statusMenuHighlightTitles: [String] = []
    private var statusMenuSmokeWillOpen: (@MainActor (NSMenu) -> Void)?
    private var pendingStatusMenuRequest: UUID?
    private var isPresentingStatusMenu = false
    private var keyboardMenuFocusWindow: KeyboardMenuFocusWindow?
    private lazy var deferredPanelDismissal = FocusDismissalScheduler(
        shouldWaitForMouseUp: { NSEvent.pressedMouseButtons & 1 != 0 },
        shouldDismiss: { [weak self] in
            guard let panel = self?.panel, panel.isVisible else { return false }
            return !NSApp.isActive || !panel.isKeyWindow
        },
        dismiss: { [weak self] in self?.panel.orderOut(nil) })

    private func tracePanel(_ action: String) {
        guard ProcessInfo.processInfo.environment["HEIC_PANEL_TRACE"] == "1" else { return }
        let event = NSApp.currentEvent
        let anchor = anchorGeometry()?.anchor
        let pointerInside = anchor?.contains(NSEvent.mouseLocation) ?? false
        print("패널 추적: pid=\(ProcessInfo.processInfo.processIdentifier) time=\(ProcessInfo.processInfo.systemUptime) \(action) event=\(event?.type.rawValue ?? 0) modifiers=\(event?.modifierFlags.rawValue ?? 0) currentModifiers=\(NSEvent.modifierFlags.rawValue) mode=\(RunLoop.current.currentMode?.rawValue ?? "없음") active=\(NSApp.isActive) visible=\(panel?.isVisible ?? false) key=\(panel?.isKeyWindow ?? false) anchor=\(anchor != nil) pressed=\(NSEvent.pressedMouseButtons) pointerInside=\(pointerInside) frontmost=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)")
        fflush(stdout)
    }

    override init() {
        if CommandLine.arguments.contains("--smoke-test") || Self.isKeyboardTest || Self.isPanelStartupTest {
            let name = "heic-panel-smoke-\(UUID().uuidString)"
            let board = NSPasteboard(name: .init(name))
            smokePasteboard = board; smokeDomain = name
            model = AppModel(startClipboard: false, pasteboard: board,
                             defaults: UserDefaults(suiteName: name)!)
        } else {
            model = AppModel()
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installApplicationMenu()
        // heiccy 클립보드 심볼을 가운데 배치하고 좌우 여백을 확보한다.
        statusItem = NSStatusBar.system.statusItem(withLength: 32)
        if let button = statusItem.button {
            button.image = PhotoClipboardIconGeometry.makeTemplateImage()
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.target = self; button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "왼쪽 클릭: 현재 클립보드 · 오른쪽 클릭: 설정과 종료"
        }
        let initialSize = NSSize(width: PanelPlacement.defaultSize.width, height: PanelPlacement.emptyHeight)
        panel = ClipboardPanel(contentRect: NSRect(origin: .zero, size: initialSize),
                               styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        panel.title = "heiccy"
        panel.identifier = NSUserInterfaceItemIdentifier("HEICConverter.ClipboardPanel")
        panel.level = .floating
        // 포커스 콜백에서 닫는다. 아이콘 mouseDown 때 자동으로 숨기면 mouseUp이 다시 연다.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.minSize = NSSize(width: PanelPlacement.minimumSize.width, height: PanelPlacement.emptyHeight)
        panel.delegate = self
        let content = NSHostingView(rootView: PanelView(model: model, chrome: panelChrome, onClose: { [weak self] in
            self?.panel.orderOut(nil)
        }))
        content.sizingOptions = []
        panel.contentView = content
        panel.setContentSize(initialSize)
        NotificationCenter.default.addObserver(self, selector: #selector(reanchorVisiblePanel),
                                              name: NSApplication.didChangeScreenParametersNotification, object: nil)
        if let button = statusItem.button {
            button.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(reanchorVisiblePanel),
                                                  name: NSView.frameDidChangeNotification, object: button)
        }
        subscription = model.$clipboardEnabled.removeDuplicates().sink { [weak self] enabled in
            guard let button = self?.statusItem.button else { return }
            button.image = PhotoClipboardIconGeometry.makeTemplateImage(isPaused: !enabled)
            button.toolTip = enabled ? "HEIC 자동 변환 중 · 오른쪽 클릭: 일시정지·설정·종료"
                : "자동 변환 일시정지됨 · 오른쪽 클릭: 다시 시작"
            button.setAccessibilityLabel(enabled ? "heiccy · 자동 변환 활성화" : "heiccy · 자동 변환 일시정지됨")
        }
        clipboardSubscription = model.$clipboardFiles.combineLatest(model.$message).sink { [weak self] _ in
            self?.scheduleClipboardLayout()
        }
        noticeSubscription = model.$conversionNotice.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] notice in
            guard let self, self.model.conversionNotice == notice else { return }
            guard let notice, !self.panel.isVisible, let geometry = self.anchorGeometry() else {
                self.noticeController.dismiss()
                return
            }
            self.noticeController.show(notice, anchor: geometry.anchor, visibleFrame: geometry.visibleFrame) { [weak self] in
                guard let self else { return }
                if !self.panel.isVisible { self.togglePanel() }
            }
        }
        // 시작과 복사 감지는 패널을 표시하지 않는다. smoke만 별도 표시 경로를 사용한다.
        if Self.isPanelStartupTest {
            print("시작 패널 검증 PID: \(ProcessInfo.processInfo.processIdentifier)")
            fflush(stdout)
            DispatchQueue.main.async { [self] in waitForSmokeAnchor(until: Date().addingTimeInterval(5)) }
        } else if CommandLine.arguments.contains("--smoke-test") {
            DispatchQueue.main.async { [self] in waitForSmokeAnchor(until: Date().addingTimeInterval(5)) }
        } else if Self.isKeyboardTest {
            DispatchQueue.main.async { [self] in waitForSmokeAnchor(until: Date().addingTimeInterval(5)) }
        }
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        deferredPanelDismissal.cancel()
        let event = NSApp.currentEvent
        let modifiers = NSEvent.modifierFlags
        tracePanel("클릭 핸들러")
        // 일반 좌클릭만 패널을 토글한다. 키보드·접근성 활성화와 Control 클릭은 메뉴로 진입한다.
        if StatusItemInteraction.opensMenu(for: event, currentModifiers: modifiers) {
            let keyboard = event?.type != .leftMouseUp && event?.type != .rightMouseUp
                || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) != true
                    && modifiers.contains(.control))
            requestStatusMenu(keyboard: keyboard)
        } else {
            if Self.isPanelStartupTest { startupLeftClickCount += 1 }
            togglePanel()
        }
    }

    @objc private func openStatusMenu() {
        requestStatusMenu(keyboard: true)
    }

    private func requestStatusMenu(keyboard: Bool) {
        guard statusItem?.button != nil, !isPresentingStatusMenu else { return }
        deferredPanelDismissal.cancel()
        tracePanel("상태 메뉴 열기")
        noticeController.dismiss()
        cancelStatusMenuRequest()
        if keyboard && (!NSApp.isActive || NSApp.keyWindow == nil) {
            // 활성화가 늦게 완료되면 이미 열린 메뉴가 취소되므로 완료 후 표시한다.
            guard let geometry = anchorGeometry() else { return }
            let request = UUID()
            pendingStatusMenuRequest = request
            let focusWindow = KeyboardMenuFocusWindow(anchor: geometry.anchor)
            keyboardMenuFocusWindow = focusWindow
            focusWindow.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            focusWindow.makeKeyAndOrderFront(nil)
            tracePanel("상태 메뉴 포커스 준비")
            waitForStatusMenuActivation(request, until: Date().addingTimeInterval(2))
        } else {
            presentStatusMenu(keyboard: keyboard)
        }
    }

    private func waitForStatusMenuActivation(_ request: UUID, until deadline: Date) {
        guard pendingStatusMenuRequest == request else { return }
        if NSApp.isActive && keyboardMenuFocusWindow?.isKeyWindow == true {
            pendingStatusMenuRequest = nil
            presentStatusMenu(keyboard: true)
        } else if Date() < deadline {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                self?.waitForStatusMenuActivation(request, until: deadline)
            }
        } else {
            cancelStatusMenuRequest()
            tracePanel("상태 메뉴 활성화 시간 초과")
        }
    }

    private func cancelStatusMenuRequest() {
        pendingStatusMenuRequest = nil
        if !isPresentingStatusMenu {
            keyboardMenuFocusWindow?.orderOut(nil)
            keyboardMenuFocusWindow = nil
        }
    }

    private func presentStatusMenu(keyboard: Bool) {
        guard let button = statusItem?.button, !isPresentingStatusMenu else { return }
        isPresentingStatusMenu = true
        statusItem.menu = makeStatusMenu()
        statusItem.menu?.delegate = self
        defer {
            statusItem.menu = nil
            isPresentingStatusMenu = false
            keyboardMenuFocusWindow?.orderOut(nil)
            keyboardMenuFocusWindow = nil
        }
        if keyboard, let menu = statusItem.menu {
            let location = NSPoint(x: button.bounds.minX,
                                   y: button.isFlipped ? button.bounds.maxY : button.bounds.minY)
            menu.popUp(positioning: menu.items.first, at: location, in: button)
        } else {
            button.performClick(nil)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        statusMenuOpenCount += 1
        statusMenuHighlightTitles.removeAll()
        tracePanel("상태 메뉴 표시")
        statusMenuSmokeWillOpen?(menu)
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        guard menu === statusItem?.menu, let item else { return }
        statusMenuHighlightTitles.append(item.title)
        if statusMenuHighlightTitles.count > 16 { statusMenuHighlightTitles.removeFirst() }
        tracePanel("상태 메뉴 항목 선택: \(item.title)")
    }

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        let pause = NSMenuItem(title: model.clipboardEnabled ? "자동 변환 일시정지" : "자동 변환 다시 시작",
                               action: #selector(toggleAutomaticConversion), keyEquivalent: "p")
        pause.keyEquivalentModifierMask = [.command, .shift]
        pause.target = self
        menu.addItem(pause)
        menu.addItem(.separator())
        let clipboard = NSMenuItem(title: "현재 클립보드 보기", action: #selector(showPanel), keyEquivalent: "1")
        clipboard.target = self
        menu.addItem(clipboard)
        let settings = NSMenuItem(title: "설정 열기…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "앱 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp; menu.addItem(quit)
        return menu
    }

    private func installApplicationMenu() {
        let menu = NSMenu()
        let application = NSMenuItem(title: "heiccy", action: nil, keyEquivalent: "")
        application.submenu = makeStatusMenu()
        let close = NSMenuItem(title: "창 닫기", action: #selector(closeCurrentWindow), keyEquivalent: "w")
        close.target = self
        application.submenu?.insertItem(close, at: 4)
        let statusMenu = NSMenuItem(title: "메뉴바 메뉴 열기", action: #selector(openStatusMenu),
                                    keyEquivalent: "\r")
        statusMenu.keyEquivalentModifierMask = .control
        statusMenu.target = self
        application.submenu?.insertItem(statusMenu, at: 5)
        menu.addItem(application)
        NSApp.mainMenu = menu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(closeCurrentWindow) { return NSApp.keyWindow != nil }
        if menuItem.action == #selector(toggleAutomaticConversion) {
            menuItem.title = model.clipboardEnabled ? "자동 변환 일시정지" : "자동 변환 다시 시작"
        }
        return true
    }

    @objc private func closeCurrentWindow() {
        // 닫기 버튼이 없는 패널은 performClose의 경고음 경로를 피하고 숨긴다.
        if NSApp.keyWindow === panel { panel.orderOut(nil) }
        else { NSApp.keyWindow?.performClose(nil) }
    }

    @objc private func toggleAutomaticConversion() {
        model.setClipboard(!model.clipboardEnabled)
    }

    @objc private func openSettings() {
        cancelStatusMenuRequest()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 400),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "heiccy 설정"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func togglePanel() {
        cancelStatusMenuRequest()
        deferredPanelDismissal.cancel()
        if panel.isVisible { panel.orderOut(nil) }
        else { showPanel() }
    }

    @objc private func showPanel() {
        cancelStatusMenuRequest()
        deferredPanelDismissal.cancel()
        tracePanel("표시 요청")
        guard anchorGeometry() != nil else { return }
        model.pollClipboard()
        noticeController.dismiss()
        positionPanel()
        // 처음에는 앱이 비활성 상태이므로 패널을 먼저 화면 앞으로 올린다.
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        tracePanel("표시 반환")
    }

    private func anchorGeometry() -> (anchor: NSRect, visibleFrame: NSRect)? {
        guard let button = statusItem?.button, let window = button.window else { return nil }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        guard anchor.width > 0, anchor.height > 0 else { return nil }
        let center = NSPoint(x: anchor.midX, y: anchor.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) else { return nil }
        let menuBarHeight = max(NSStatusBar.system.thickness, anchor.height, screen.safeAreaInsets.top)
        guard center.y >= screen.frame.maxY - menuBarHeight - 2 else { return nil }
        return (anchor, screen.visibleFrame)
    }

    @objc private func reanchorVisiblePanel() {
        if panel?.isVisible == true { positionPanel() }
        if noticeController.isVisible, let geometry = anchorGeometry() {
            noticeController.reanchor(anchor: geometry.anchor, visibleFrame: geometry.visibleFrame)
        }
    }

    private func scheduleClipboardLayout() {
        guard !clipboardLayoutScheduled else { return }
        clipboardLayoutScheduled = true
        // 같은 복사 감지에서 목록을 비웠다 채우는 중간 상태는 접지 않는다.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.clipboardLayoutScheduled = false
            self.positionPanel()
        }
    }

    private func positionPanel() {
        guard !isPositioningPanel, let geometry = anchorGeometry() else { return }
        isPositioningPanel = true
        defer { isPositioningPanel = false }
        let isEmpty = model.clipboardFiles.isEmpty
        var size = panel.frame.size
        let available = PanelPlacement.availableFrame(anchor: geometry.anchor, visibleFrame: geometry.visibleFrame)
        size.width = min(size.width, available.width)
        let contentHeight = fittedPanelHeight(width: size.width)
        size.height = isEmpty ? PanelPlacement.emptyHeight : max(contentHeight, populatedPanelHeight ?? 0)
        panel.minSize = NSSize(width: min(PanelPlacement.minimumSize.width, available.width),
                               height: min(contentHeight, available.height))
        panel.maxSize = available.size
        let frame = PanelPlacement.frame(anchor: geometry.anchor, visibleFrame: geometry.visibleFrame, size: size)
        let button = statusItem.button!
        let iconRect = button.cell?.imageRect(forBounds: button.bounds) ?? button.bounds
        let iconX = button.window?.convertToScreen(button.convert(iconRect, to: nil)).midX ?? geometry.anchor.midX
        panelChrome.pointerX = PanelPlacement.pointerCenter(anchorX: iconX, panelFrame: frame)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    private func fittedPanelHeight(width: CGFloat) -> CGFloat {
        guard !model.clipboardFiles.isEmpty else { return PanelPlacement.emptyHeight }
        let content = PanelView(model: model, chrome: panelChrome, measuresContent: true)
            .frame(width: width).fixedSize(horizontal: false, vertical: true)
        let hosting = NSHostingView(rootView: content)
        if let appearance = panel?.effectiveAppearance { hosting.appearance = appearance }
        return ceil(hosting.fittingSize.height)
    }

    func windowDidResize(_ notification: Notification) {
        guard !isPositioningPanel else { return }
        if !model.clipboardFiles.isEmpty { populatedPanelHeight = panel.frame.height }
        reanchorVisiblePanel()
    }
    func windowDidResignKey(_ notification: Notification) {
        tracePanel("창 key 상실")
        guard let window = notification.object as? NSWindow, window === panel else { return }
        guard !isPressingStatusButton else {
            tracePanel("아이콘 클릭 중 닫기 보류")
            deferredPanelDismissal.schedule()
            return
        }
        deferredPanelDismissal.cancel()
        panel.orderOut(nil)
    }
    func applicationDidResignActive(_ notification: Notification) {
        cancelStatusMenuRequest()
        tracePanel("앱 비활성화")
        guard !isPressingStatusButton else {
            tracePanel("아이콘 클릭 중 닫기 보류")
            deferredPanelDismissal.schedule()
            return
        }
        deferredPanelDismissal.cancel()
        // 비활성화 중 임시로 숨긴 패널이 앱 재활성화 때 다시 나타나지 않도록 닫는다.
        panel.orderOut(nil)
    }
    private var isPressingStatusButton: Bool {
        StatusItemInteraction.defersPanelDismissal(buttonFrame: anchorGeometry()?.anchor,
            mouseLocation: NSEvent.mouseLocation, pressedMouseButtons: NSEvent.pressedMouseButtons,
            modifiers: NSEvent.modifierFlags)
    }
    func applicationDidBecomeActive(_ notification: Notification) { tracePanel("앱 활성화") }
    func windowDidBecomeKey(_ notification: Notification) { tracePanel("창 key 획득") }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        deferredPanelDismissal.cancel()
        sender.orderOut(nil)
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Finder·Spotlight에서 실행 중인 앱을 다시 열면 마우스 없이 패널로 진입할 수 있다.
        showPanel()
        return false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        cancelStatusMenuRequest()
        deferredPanelDismissal.cancel()
        tracePanel("정상 종료 요청")
        noticeController.dismiss()
        model.shutdown { DispatchQueue.main.async { sender.reply(toApplicationShouldTerminate: true) } }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        cancelStatusMenuRequest()
        deferredPanelDismissal.cancel()
        tracePanel("정상 종료 완료")
        noticeController.dismiss()
        model.shutdown()
        NotificationCenter.default.removeObserver(self)
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        smokePasteboard?.releaseGlobally()
        if let smokeDomain { UserDefaults(suiteName: smokeDomain)?.removePersistentDomain(forName: smokeDomain) }
        if let keyboardFixture {
            try? FileManager.default.removeItem(at: keyboardFixture)
        }
        if Self.isPanelStartupTest {
            print("시작 패널 검증 [정상 종료 완료]: 성공")
            fflush(stdout)
        }
    }

    // 전용 클립보드·설정·합성 파일로 대화형 검증을 준비한다.
    private func prepareKeyboardTest() {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("heic-keyboard-\(UUID().uuidString)")
        keyboardFixture = fixture
        do {
            try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
            let files = try (1...12).map { index -> NSURL in
                let url = fixture.appendingPathComponent("\(index)-키보드 스크롤 검증용 합성 문서.txt")
                try Data("합성 문서".utf8).write(to: url)
                return url as NSURL
            }
            smokePasteboard?.clearContents()
            _ = smokePasteboard?.writeObjects(files)
            model.pollClipboard()
            openSettings()
            showPanel()
            print("키보드 실기: 전용 클립보드·설정, 합성 파일 \(files.count)개, 전체 키보드 접근 \(NSApp.isFullKeyboardAccessEnabled)")
            fflush(stdout)
        } catch { print("키보드 실기 준비 실패: \(error)"); exit(1) }
    }

    private func waitForSmokeAnchor(until deadline: Date) {
        if anchorGeometry() != nil {
            if Self.isPanelStartupTest {
                Task {
                    guard let button = statusItem.button else { return }
                    _ = await panelStartupSmokeTest(button: button, panel: panel,
                        leftClickCount: { [self] in startupLeftClickCount })
                    // terminateLater의 중첩 루프에서 worker 정리의 main queue 콜백이 실행되게 한다.
                    // MainActor Task가 반환한 뒤 AppKit run loop에서 정상 종료를 요청한다.
                    RunLoop.main.perform(inModes: [.default]) { NSApp.terminate(nil) }
                }
            } else if Self.isKeyboardTest { prepareKeyboardTest() }
            else { Task { await runPanelSmokeTest() } }
        }
        else if Date() < deadline {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in waitForSmokeAnchor(until: deadline) }
        } else {
            if Self.isPanelStartupTest {
                print("시작 패널 검증 [메뉴 아이콘 배치 시간 초과]: 실패")
                RunLoop.main.perform(inModes: [.default]) { NSApp.terminate(nil) }
            } else { print("메뉴 아이콘 배치 시간 초과"); exit(1) }
        }
    }

    private func runPanelSmokeTest() async {
        var passed = true
        let focusTarget = [NSWorkspace.shared.frontmostApplication,
                           NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first]
            .compactMap { $0 }.first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        func waitForFocus(_ window: NSWindow) async -> Bool {
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                if NSApp.isActive && window.isKeyWindow { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return false
        }
        func check(_ label: String, _ condition: Bool) {
            print("패널 검증 [\(label)]: \(condition ? "성공" : "실패")")
            if !condition { passed = false }
        }
        check("시작 시 숨김", !panel.isVisible)
        if let button = statusItem.button, let imageRect = button.cell?.imageRect(forBounds: button.bounds) {
            check("메뉴 아이콘 좌우 여백", imageRect.minX - button.bounds.minX >= 4
                && button.bounds.maxX - imageRect.maxX >= 4)
            if let directory = ProcessInfo.processInfo.environment["HEIC_UI_SMOKE_DIR"],
               let bitmap = button.bitmapImageRepForCachingDisplay(in: button.bounds) {
                button.cacheDisplay(in: button.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(
                    to: URL(fileURLWithPath: directory).appendingPathComponent("status-icon.png"))
            }
        } else { check("메뉴 아이콘 좌우 여백", false) }
        togglePanel()
        check("빈 목록 간결한 높이", panel.frame.height == PanelPlacement.emptyHeight)
        if let directory = ProcessInfo.processInfo.environment["HEIC_UI_SMOKE_DIR"], let view = panel.contentView {
            for width in [PanelPlacement.defaultSize.width, PanelPlacement.minimumSize.width] {
                panel.setContentSize(NSSize(width: width, height: PanelPlacement.emptyHeight))
                try? await Task.sleep(nanoseconds: 20_000_000)
                view.layoutSubtreeIfNeeded()
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(
                        to: URL(fileURLWithPath: directory).appendingPathComponent("empty-\(Int(width)).png"))
                }
                model.setClipboard(false)
                try? await Task.sleep(nanoseconds: 20_000_000)
                view.layoutSubtreeIfNeeded()
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(
                        to: URL(fileURLWithPath: directory).appendingPathComponent("empty-disabled-\(Int(width)).png"))
                }
                model.setClipboard(true)
            }
            panel.setContentSize(NSSize(width: PanelPlacement.defaultSize.width, height: PanelPlacement.emptyHeight))
        }
        togglePanel()
        // 사용자 파일 대신 합성된 긴 이름의 비HEIC 항목으로 현재 목록과 스크롤을 확인한다.
        let fixture = URL(fileURLWithPath: InputValidator.canonicalPath(FileManager.default.temporaryDirectory), isDirectory: true)
            .appendingPathComponent("heic-ui-smoke-\(UUID().uuidString)")
        func cleanupFixture() {
            smokePasteboard?.releaseGlobally()
            if let smokeDomain { UserDefaults(suiteName: smokeDomain)?.removePersistentDomain(forName: smokeDomain) }
            try? FileManager.default.removeItem(at: fixture)
        }
        do {
            try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
            // 사진 1~3개를 실제 worker로 변환한 뒤 목록 아래의 빈 공간을 확인한다.
            let context = CGContext(data: nil, width: 24, height: 16, bitsPerComponent: 8, bytesPerRow: 96,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 16))
            let sources = try (1...3).map { index -> URL in
                let url = fixture.appendingPathComponent("합성 사진 \(index).heic")
                guard let encoder = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                CGImageDestinationAddImage(encoder, context.makeImage()!, nil)
                guard CGImageDestinationFinalize(encoder) else { throw CocoaError(.fileWriteUnknown) }
                return url
            }
            var previousHeight: CGFloat = 0
            for count in 1...3 {
                populatedPanelHeight = nil
                smokePasteboard?.clearContents()
                _ = smokePasteboard?.writeObjects(Array(sources.prefix(count)) as [NSURL])
                model.pollClipboard()
                let deadline = Date().addingTimeInterval(30)
                while model.active && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
                try? await Task.sleep(for: .milliseconds(30))
                check("사진 \(count)개 실제 변환", model.clipboardFiles.count == count
                    && model.clipboardFiles.allSatisfy { $0.status == .completed })
                if !panel.isVisible { togglePanel() }
                for width in [PanelPlacement.defaultSize.width, PanelPlacement.minimumSize.width] {
                    panel.setContentSize(NSSize(width: width, height: panel.frame.height))
                    populatedPanelHeight = nil
                    positionPanel()
                    try? await Task.sleep(for: .milliseconds(30))
                    panel.contentView?.layoutSubtreeIfNeeded()
                    func findScroll(in view: NSView) -> NSScrollView? {
                        if let scroll = view as? NSScrollView { return scroll }
                        for child in view.subviews { if let scroll = findScroll(in: child) { return scroll } }
                        return nil
                    }
                    if let view = panel.contentView, let scroll = findScroll(in: view), let document = scroll.documentView {
                        check("사진 \(count)개·폭 \(Int(width)) 목록 아래 여백 없음",
                            abs(scroll.contentView.bounds.height - document.frame.height) <= 1)
                        print("사진 패널 실측: \(count)개 · 폭 \(width) · 높이 \(panel.frame.height)pt")
                        if let directory = ProcessInfo.processInfo.environment["HEIC_UI_SMOKE_DIR"],
                           let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                            view.cacheDisplay(in: view.bounds, to: bitmap)
                            try? bitmap.representation(using: .png, properties: [:])?.write(to:
                                URL(fileURLWithPath: directory).appendingPathComponent("converted-\(count)-\(Int(width)).png"))
                        }
                    } else { check("사진 목록 측정", false) }
                }
                check("파일 수에 따라 높이 증가", panel.frame.height > previousHeight)
                previousHeight = panel.frame.height
            }
            let video = NSPasteboardItem()
            let reference = try PropertyListSerialization.data(fromPropertyList: ["mediaType": 2, "mediaSubtypes": 0], format: .binary, options: 0)
            video.setData(reference, forType: .init("com.apple.photos.object-reference.asset"))
            video.setData(try Data(contentsOf: sources[0]), forType: .init(UTType.heic.identifier))
            smokePasteboard?.clearContents(); _ = smokePasteboard?.writeObjects([video])
            model.pollClipboard()
            check("동영상 표시·자동 변환 제외", !model.active && model.conversionNotice == nil
                && model.clipboardFiles.first?.isVideo == true)
            panel.setContentSize(NSSize(width: PanelPlacement.defaultSize.width, height: panel.frame.height))
            populatedPanelHeight = nil; positionPanel()
            try? await Task.sleep(for: .milliseconds(30))
            if let directory = ProcessInfo.processInfo.environment["HEIC_UI_SMOKE_DIR"],
               let view = panel.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.layoutSubtreeIfNeeded(); view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(
                    to: URL(fileURLWithPath: directory).appendingPathComponent("video-excluded.png"))
            }
            if panel.isVisible { togglePanel() }
            populatedPanelHeight = nil
            let urls = try (1...12).map { index -> URL in
                let url = fixture.appendingPathComponent("\(index)-화면 너비보다 긴 파일 이름과 현재 클립보드 항목 보존 확인.txt")
                try Data("합성 문서".utf8).write(to: url)
                return url
            }
            smokePasteboard?.clearContents()
            _ = smokePasteboard?.writeObjects(urls as [NSURL])
        } catch { check("합성 목록 준비", false) }
        model.pollClipboard()
        check("감지 시 숨김 유지", !panel.isVisible)
        check("현재 다중 파일 목록", model.clipboardFiles.count == 12)
        togglePanel()
        check("패널 토글 호출 표시", panel.isVisible)
        check("파일 목록 콘텐츠 높이", panel.frame.height == fittedPanelHeight(width: panel.frame.width))
        if let geometry = anchorGeometry() {
            check("화면 경계와 돌출부", geometry.visibleFrame.contains(panel.frame)
                && panel.frame.maxY <= geometry.anchor.minY && panelChrome.pointerX > 0)
        } else { check("화면 좌표", false) }
        check("패널 포커스 획득", await waitForFocus(panel))
        check("다른 앱 포커스 이동 요청", focusTarget?.activate(options: [.activateIgnoringOtherApps]) == true)
        let deactivationDeadline = Date().addingTimeInterval(2)
        while (NSApp.isActive || panel.isVisible) && Date() < deactivationDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        check("앱 비활성화 시 패널 닫힘", !NSApp.isActive && !panel.isVisible)
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(for: .milliseconds(200))
        check("재활성화 시 닫힘 유지", !panel.isVisible)
        togglePanel()
        check("포커스 상실 후 메뉴로 다시 열기", await waitForFocus(panel) && panel.isVisible)
        if let directory = ProcessInfo.processInfo.environment["HEIC_UI_SMOKE_DIR"] {
            for width in [PanelPlacement.defaultSize.width, PanelPlacement.minimumSize.width] {
                panel.setContentSize(NSSize(width: width, height: panel.frame.height))
                populatedPanelHeight = nil
                positionPanel()
                panel.contentView?.layoutSubtreeIfNeeded()
                if let view = panel.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(
                        to: URL(fileURLWithPath: directory).appendingPathComponent("panel-\(Int(width)).png"))
                }
            }
        }
        let populatedFrame = panel.frame
        let resizedHeight = populatedFrame.height + 60
        panel.setContentSize(NSSize(width: populatedFrame.width, height: resizedHeight))
        // 다른 파일을 복사할 때 중간의 빈 배열 때문에 높이가 초기화되지 않아야 한다.
        let urls = (smokePasteboard?.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
        check("파일 교체 검증 원본 준비", urls.count == 12)
        smokePasteboard?.clearContents(); _ = smokePasteboard?.writeObjects(urls as [NSURL])
        model.pollClipboard()
        try? await Task.sleep(nanoseconds: 20_000_000)
        check("파일 교체 시 사용자 높이 유지", panel.frame.height == resizedHeight)
        smokePasteboard?.clearContents(); model.pollClipboard()
        try? await Task.sleep(nanoseconds: 20_000_000)
        check("표시 중 빈 목록으로 축소", panel.isVisible && panel.frame.height == PanelPlacement.emptyHeight
            && panel.frame.width == populatedFrame.width && panel.frame.maxY == populatedFrame.maxY)
        smokePasteboard?.clearContents()
        _ = smokePasteboard?.writeObjects(urls as [NSURL]); model.pollClipboard()
        try? await Task.sleep(nanoseconds: 20_000_000)
        check("표시 중 파일 목록 높이 복원", model.clipboardFiles.count == 12
            && panel.isVisible && panel.frame.height == resizedHeight
            && panel.frame.maxY == populatedFrame.maxY)
        togglePanel(); check("패널 토글 호출 숨김", !panel.isVisible)
        let menu = makeStatusMenu()
        check("우클릭 일시정지·패널·설정·종료", menu.items.map(\.title) == ["자동 변환 일시정지", "", "현재 클립보드 보기", "설정 열기…", "", "앱 종료"]
            && menu.items[5].target === NSApp)
        menu.performActionForItem(at: 0)
        check("메뉴에서 자동 변환 일시정지", !model.clipboardEnabled
            && statusItem.button?.image?.accessibilityDescription == PhotoClipboardIconGeometry.pausedAccessibilityDescription)
        let pausedMenu = makeStatusMenu()
        check("일시정지 메뉴는 다시 시작 표시", pausedMenu.items[0].title == "자동 변환 다시 시작")
        pausedMenu.performActionForItem(at: 0)
        check("메뉴에서 자동 변환 다시 시작", model.clipboardEnabled
            && statusItem.button?.image?.accessibilityDescription == PhotoClipboardIconGeometry.accessibilityDescription)
        togglePanel()
        check("설정 전 패널 포커스", await waitForFocus(panel))
        menu.performActionForItem(at: 3)
        if let settingsWindow {
            check("별도 설정 창으로 포커스 이동 시 패널 닫힘",
                  await waitForFocus(settingsWindow) && settingsWindow.isVisible && !panel.isVisible)
        } else { check("별도 설정 창", false) }
        check("기본 키보드 명령과 목록", await runKeyboardSmokeTest())
        if let directory = ProcessInfo.processInfo.environment["HEIC_UI_SMOKE_DIR"],
           let view = settingsWindow?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.layoutSubtreeIfNeeded(); view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(
                to: URL(fileURLWithPath: directory).appendingPathComponent("settings.png"))
        }
        settingsWindow?.orderOut(nil)
        check("메뉴 알림 상호작용", await runNoticeSmokeTest())
        var workerNoticePhases: Set<String> = []
        check("자동 변환 worker", await clipboardConversionSmokeTest { [self] notice in
            guard let notice, let geometry = anchorGeometry() else { noticeController.dismiss(); return }
            workerNoticePhases.insert(String(describing: notice.phase))
            noticeController.show(notice, anchor: geometry.anchor, visibleFrame: geometry.visibleFrame) {}
        })
        check("실제 worker 진행·완료·실패 알림", workerNoticePhases.isSuperset(of: ["preparing", "converting", "completed", "failed"]))
        noticeController.dismiss()
        model.shutdown()
        cleanupFixture()
        exit(passed ? 0 : 1)
    }

    private func runKeyboardSmokeTest() async -> Bool {
        var passed = true
        func check(_ label: String, _ condition: @autoclosure () -> Bool) async {
            let deadline = Date().addingTimeInterval(2)
            while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
            let result = condition()
            print("키보드 검증 [\(label)]: \(result ? "성공" : "실패")")
            if !result { passed = false }
        }
        func press(_ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = [],
                   in target: NSWindow?, followUpKeys: [(String, UInt16)] = []) async {
            guard let window = target else {
                await check("키 \(keyCode) 입력 대상 창", false)
                return
            }
            await check("키 \(keyCode) 입력 전 포커스 준비",
                        NSApp.isActive && window.isVisible && window.isKeyWindow && NSApp.keyWindow === window)
            guard NSApp.isActive && window.isVisible && window.isKeyWindow && NSApp.keyWindow === window else { return }
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                      context: nil, characters: characters, charactersIgnoringModifiers: characters.lowercased(),
                      isARepeat: false, keyCode: keyCode) else {
                await check("키 \(keyCode) 이벤트 생성", false)
                return
            }
            var followUps: [NSEvent] = []
            for (index, key) in followUpKeys.enumerated() {
                guard let followUp = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: event.timestamp + Double(index + 1) * 0.001, windowNumber: window.windowNumber,
                    context: nil, characters: key.0, charactersIgnoringModifiers: key.0,
                    isARepeat: false, keyCode: key.1) else {
                    await check("메뉴 후속 키 \(key.1) 이벤트 생성", false)
                    return
                }
                followUps.append(followUp)
            }
            // 액션을 직접 호출하지 않고 실제 앱 이벤트 큐와 key-equivalent/responder 경로를 통과한다.
            NSApp.postEvent(event, atStart: false)
            // 메뉴의 중첩 추적 루프에서도 방향키·Return·Escape가 진행되도록 양보 없이 게시한다.
            for followUp in followUps { NSApp.postEvent(followUp, atStart: false) }
            // 이벤트 큐에 실행 기회를 준 뒤 각 명령의 실제 결과를 아래 check에서 기다린다.
            try? await Task.sleep(for: .milliseconds(20))
        }
        openSettings()
        await press("1", keyCode: 18, flags: .command, in: settingsWindow)
        await check("설정에서 ⌘1 패널 표시", panel.isVisible && panel.isKeyWindow)
        await press("1", keyCode: 18, flags: .command, in: panel)
        await check("⌘1은 표시된 패널 유지", panel.isVisible)
        let generation = smokePasteboard?.changeCount
        await press("P", keyCode: 35, flags: [.command, .shift], in: panel)
        await check("⌘⇧P 일시정지", !model.clipboardEnabled && smokePasteboard?.changeCount == generation)
        await press("P", keyCode: 35, flags: [.command, .shift], in: panel)
        await check("⌘⇧P 다시 시작", model.clipboardEnabled && smokePasteboard?.changeCount == generation)
        panel.contentView?.layoutSubtreeIfNeeded()
        if let scroll = panel.contentView?.firstPanelScrollView(), let document = scroll.documentView {
            await check("목록이 실제 first responder", panel.makeFirstResponder(scroll) && panel.firstResponder === scroll)
            func isAtBoundary(end: Bool) -> Bool {
                let minimum = document.bounds.minY
                let maximum = max(minimum, document.bounds.maxY - scroll.contentView.bounds.height)
                let expected = end == document.isFlipped ? maximum : minimum
                return abs(scroll.contentView.bounds.minY - expected) <= 1
            }
            await press("\u{F72B}", keyCode: 119, in: panel)
            await check("End 마지막 행까지 스크롤", isAtBoundary(end: true))
            if !isAtBoundary(end: true) {
                print("키보드 목록 진단: flipped=\(document.isFlipped) document=\(document.bounds) clip=\(scroll.contentView.bounds) active=\(NSApp.isActive) key=\(panel.isKeyWindow) responder=\(panel.firstResponder === scroll)")
            }
            await press("\u{F729}", keyCode: 115, in: panel)
            await check("Home 첫 행까지 스크롤", isAtBoundary(end: false))
        } else { await check("스크롤 responder", false) }
        await press("\u{1B}", keyCode: 53, in: panel)
        await check("목록 포커스에서도 Escape 닫기", !panel.isVisible && model.clipboardEnabled
            && smokePasteboard?.changeCount == generation)
        openSettings()
        await press("1", keyCode: 18, flags: .command, in: settingsWindow)
        await press("w", keyCode: 13, flags: .command, in: panel)
        await check("⌘W 패널 숨기기·변환 유지", !panel.isVisible && model.clipboardEnabled)
        openSettings()
        await press("1", keyCode: 18, flags: .command, in: settingsWindow)
        await press(",", keyCode: 43, flags: .command, in: panel)
        await check("⌘, 설정 열기", settingsWindow?.isKeyWindow == true && !panel.isVisible)
        await press("w", keyCode: 13, flags: .command, in: settingsWindow)
        await check("⌘W 설정 닫기·앱 계속 실행", settingsWindow?.isVisible == false && model.clipboardEnabled)
        openSettings()
        await check("상태 메뉴 탐색 전 패널 숨김", !panel.isVisible)
        let menuOpenCount = statusMenuOpenCount
        await press("\r", keyCode: 36, flags: .control, in: settingsWindow,
                    followUpKeys: [("\u{F701}", 125), ("\u{F701}", 125), ("\u{F700}", 126),
                                   ("\u{F701}", 125), ("\u{1B}", 53)])
        await check("Control+Return 실제 상태 메뉴 열기", statusMenuOpenCount == menuOpenCount + 1)
        await check("Escape 후 상태 메뉴 닫힘·열림 횟수 유지",
                    statusItem.menu == nil && statusMenuOpenCount == menuOpenCount + 1)
        // 초기 선택을 가정하지 않고 네 방향키의 실제 highlight 전환을 확인한다.
        let highlights = Array(statusMenuHighlightTitles.suffix(4))
        let navigated = highlights.count == 4 && highlights[0] != highlights[1]
            && highlights[2] == highlights[0] && highlights[3] == highlights[1]
            && highlights.prefix(2).contains("현재 클립보드 보기")
        await check("Down·Down·Up·Down 실제 메뉴 선택 이동", navigated)
        await check("Escape 메뉴 취소는 동작·클립보드 유지",
                    !panel.isVisible && model.clipboardEnabled && smokePasteboard?.changeCount == generation)
        openSettings()
        let selectionOpenCount = statusMenuOpenCount
        if navigated, let index = highlights.prefix(2).firstIndex(of: "현재 클립보드 보기") {
            // 앞선 취소 검사에서 확인한 1회 또는 2회 Down으로 같은 항목을 선택한다.
            let keys: [(String, UInt16)] = Array(repeating: ("\u{F701}", 125), count: index + 1)
                + [("\r", 36)]
            await press("\r", keyCode: 36, flags: .control, in: settingsWindow, followUpKeys: keys)
        } else {
            await check("현재 클립보드 메뉴 선택 입력 준비", false)
        }
        await check("방향키·Return 메뉴 선택은 한 번 열기", statusMenuOpenCount == selectionOpenCount + 1)
        await check("방향키·Return 현재 클립보드 보기 실행",
                    NSApp.isActive && panel.isVisible && panel.isKeyWindow && statusItem.menu == nil
                    && model.clipboardEnabled && smokePasteboard?.changeCount == generation)
        openSettings()
        await check("키보드 검증 후 설정 포커스 복원", NSApp.isActive && settingsWindow?.isKeyWindow == true)
        // 내부 API의 cold 활성화 경로다. 실제 Fn+Control+F8 입력 검증과 구분한다.
        defer {
            statusMenuSmokeWillOpen = nil
            cancelStatusMenuRequest()
        }
        if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder")
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            func prepareColdMenu(_ label: String) async -> Bool {
                cancelStatusMenuRequest()
                panel.orderOut(nil)
                settingsWindow?.orderOut(nil)
                NSApp.yieldActivation(to: finder)
                let requested = finder.activate(options: [])
                await check("\(label) Finder 포커스 요청", requested)
                await check("\(label) 비활성·모든 창 숨김 준비",
                            !NSApp.isActive && NSApp.keyWindow == nil && !panel.isVisible
                            && settingsWindow?.isVisible != true && keyboardMenuFocusWindow == nil
                            && NSWorkspace.shared.frontmostApplication?.processIdentifier == finder.processIdentifier)
                return requested && !NSApp.isActive && NSApp.keyWindow == nil && !panel.isVisible
                    && settingsWindow?.isVisible != true && keyboardMenuFocusWindow == nil
                    && NSWorkspace.shared.frontmostApplication?.processIdentifier == finder.processIdentifier
            }
            func coldMenu(_ label: String, keys: [(String, UInt16)]) async -> [String]? {
                guard await prepareColdMenu(label) else { return nil }
                var readyOnOpen = false
                var keysPosted = false
                let count = statusMenuOpenCount
                statusMenuSmokeWillOpen = { [self] menu in
                    readyOnOpen = NSApp.isActive && keyboardMenuFocusWindow?.isKeyWindow == true
                        && NSApp.keyWindow === keyboardMenuFocusWindow && !panel.isVisible
                        && settingsWindow?.isVisible != true
                    let timestamp = ProcessInfo.processInfo.systemUptime
                    let windowNumber = NSApp.keyWindow?.windowNumber ?? 0
                    let events = keys.enumerated().compactMap { index, key in
                        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                            timestamp: timestamp + Double(index) * 0.001, windowNumber: windowNumber,
                            context: nil, characters: key.0, charactersIgnoringModifiers: key.0,
                            isARepeat: false, keyCode: key.1)
                    }
                    guard events.count == keys.count else { menu.cancelTracking(); return }
                    // 활성화 완료와 menuWillOpen 이후에만 후속 키를 함께 게시한다.
                    for event in events { NSApp.postEvent(event, atStart: false) }
                    keysPosted = true
                }
                defer {
                    statusMenuSmokeWillOpen = nil
                    cancelStatusMenuRequest()
                }
                requestStatusMenu(keyboard: true)
                await check("\(label) 메뉴 한 번 열기", statusMenuOpenCount == count + 1)
                await check("\(label) 열릴 때 활성·helper key·실제 창 숨김", readyOnOpen)
                await check("\(label) 메뉴 열린 뒤 후속 키 게시", keysPosted)
                await check("\(label) 메뉴 반환 후 helper·예약 정리",
                            statusItem.menu == nil && !isPresentingStatusMenu
                            && keyboardMenuFocusWindow == nil && pendingStatusMenuRequest == nil)
                return statusMenuHighlightTitles
            }
            let coldTitles = await coldMenu("콜드 메뉴 Escape",
                keys: [("\u{F701}", 125), ("\u{F701}", 125), ("\u{F700}", 126),
                       ("\u{F701}", 125), ("\u{1B}", 53)])
            let coldHighlights = Array((coldTitles ?? []).suffix(4))
            let coldNavigated = coldTitles != nil && coldHighlights.count == 4
                && coldHighlights[0] != coldHighlights[1] && coldHighlights[2] == coldHighlights[0]
                && coldHighlights[3] == coldHighlights[1]
                && coldHighlights.prefix(2).contains("현재 클립보드 보기")
            await check("콜드 메뉴 Down·Down·Up·Down 실제 선택 이동", coldNavigated)
            await check("콜드 메뉴 Escape는 창·동작·클립보드 유지",
                        !panel.isVisible && settingsWindow?.isVisible != true && model.clipboardEnabled
                        && smokePasteboard?.changeCount == generation && keyboardMenuFocusWindow == nil)
            if coldNavigated, let index = coldHighlights.prefix(2).firstIndex(of: "현재 클립보드 보기") {
                let keys: [(String, UInt16)] = Array(repeating: ("\u{F701}", 125), count: index + 1)
                    + [("\r", 36)]
                _ = await coldMenu("콜드 메뉴 Return", keys: keys)
            } else {
                await check("콜드 메뉴 현재 클립보드 선택 입력 준비", false)
            }
            await check("콜드 메뉴 Return 현재 클립보드 보기 실행",
                        NSApp.isActive && panel.isVisible && panel.isKeyWindow && statusItem.menu == nil
                        && keyboardMenuFocusWindow == nil && model.clipboardEnabled
                        && smokePasteboard?.changeCount == generation)
        } else {
            await check("콜드 메뉴 Finder 포커스 대상", false)
        }
        statusMenuSmokeWillOpen = nil
        cancelStatusMenuRequest()
        openSettings()
        await check("콜드 메뉴 검증 후 설정 포커스 복원", NSApp.isActive && settingsWindow?.isKeyWindow == true)
        return passed
    }

    private func runNoticeSmokeTest() async -> Bool {
        guard let geometry = anchorGeometry() else { return false }
        var passed = true
        func check(_ label: String, _ condition: Bool) {
            print("알림 검증 [\(label)]: \(condition ? "성공" : "실패")")
            if !condition { passed = false }
        }
        let controller = ClipboardNoticeController(completedDuration: 0.25, failureDuration: 0.35)
        defer { controller.dismiss() }
        func notice(_ phase: ClipboardConversionNotice.Phase, id: UUID = UUID()) -> ClipboardConversionNotice {
            ClipboardConversionNotice(id: id, sourceChangeCount: 1, copiedFileCount: 3, heicCount: 2,
                phase: phase, completedCount: phase == .completed ? 2 : (phase == .converting ? 1 : 0),
                detail: phase == .failed ? "변환하지 못했습니다. 전체 원본을 유지했습니다." : nil)
        }
        func show(_ value: ClipboardConversionNotice, onOpen: @escaping () -> Void = {}) {
            controller.show(value, anchor: geometry.anchor, visibleFrame: geometry.visibleFrame, onOpen: onOpen)
        }
        func waitForDismissal() async -> Bool {
            // RunLoop Timer와 Task 재개 순서는 CI 부하에 따라 달라질 수 있다.
            // 임의의 50ms 여유 대신 실제 닫힘을 기다리되 미동작은 시간 제한으로 실패시킨다.
            let deadline = Date().addingTimeInterval(2)
            while controller.isVisible && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            return !controller.isVisible
        }
        func render(_ filename: String) {
            if let directory = ProcessInfo.processInfo.environment["HEIC_UI_SMOKE_DIR"] {
                do { try controller.render(to: URL(fileURLWithPath: directory).appendingPathComponent(filename)) }
                catch { check("알림 렌더링", false) }
            }
        }
        NSApp.deactivate()
        let wasActive = NSApp.isActive
        let keyWindow = NSApp.keyWindow
        let firstID = UUID()
        show(notice(.preparing, id: firstID))
        try? await Task.sleep(nanoseconds: 100_000_000)
        check("포커스 유지·메뉴 아래 배치", controller.isVisible && NSApp.isActive == wasActive
            && NSApp.keyWindow === keyWindow && geometry.visibleFrame.contains(controller.frame)
            && controller.frame.maxY <= geometry.anchor.minY && !panel.isVisible)
        render("notice-preparing.png")
        let preparingFrame = controller.frame
        show(notice(.converting, id: firstID))
        try? await Task.sleep(nanoseconds: 100_000_000)
        render("notice-converting.png")
        let convertingFrame = controller.frame
        show(notice(.completed, id: firstID))
        try? await Task.sleep(nanoseconds: 100_000_000)
        render("notice-completed.png")
        let completedFrame = controller.frame
        check("진행 막대 높이 반영·완료 시 축소", convertingFrame.height > completedFrame.height
            && completedFrame.height > 80)
        check("상태 변경 시 메뉴 기준점 유지", preparingFrame.maxY == convertingFrame.maxY
            && convertingFrame.maxY == completedFrame.maxY)
        let compactNotice = ClipboardConversionNotice(id: UUID(), sourceChangeCount: 1,
            copiedFileCount: 2, heicCount: 2, phase: .completed, completedCount: 2, detail: nil)
        show(compactNotice)
        try? await Task.sleep(nanoseconds: 100_000_000)
        render("notice-heic-only.png")
        check("혼합 파일 개수 행이 없으면 축소", controller.frame.height < completedFrame.height)
        print("알림 실측 높이: 준비 \(preparingFrame.height), 진행 \(convertingFrame.height), 완료 \(completedFrame.height), HEIC만 \(controller.frame.height)pt")
        let secondID = UUID()
        show(notice(.converting, id: secondID))
        try? await Task.sleep(nanoseconds: 300_000_000)
        check("이전 타이머가 새 진행 알림을 닫지 않음", controller.isVisible && controller.currentNotice?.id == secondID)
        controller.dismiss()
        show(notice(.completed, id: secondID))
        check("닫은 작업의 후속 알림 숨김", !controller.isVisible)
        let failureID = UUID()
        show(notice(.failed, id: failureID))
        try? await Task.sleep(nanoseconds: 100_000_000)
        render("notice-failed.png")
        let shortFailureFrame = controller.frame
        show(ClipboardConversionNotice(id: failureID, sourceChangeCount: 1, copiedFileCount: 3,
            heicCount: 2, phase: .failed, completedCount: 0,
            detail: "변환한 파일을 클립보드에 반영하지 못했습니다. 전체 원본을 유지했습니다."))
        try? await Task.sleep(nanoseconds: 50_000_000)
        render("notice-failed-wrapped.png")
        check("두 줄 실패 안내 높이 반영", controller.frame.height > shortFailureFrame.height
            && controller.frame.maxY == shortFailureFrame.maxY)
        print("알림 실측 높이: 짧은 실패 \(shortFailureFrame.height), 두 줄 실패 \(controller.frame.height)pt")
        check("실패 자동 닫힘", await waitForDismissal())
        show(notice(.completed))
        check("완료 자동 닫힘", await waitForDismissal())
        var opened = false
        show(notice(.preparing)) { [self] in opened = true; togglePanel() }
        controller.openDetails()
        check("알림 클릭으로 상세 패널 열기", opened && panel.isVisible && !controller.isVisible)
        if panel.isVisible { togglePanel() }
        return passed
    }
}

/// 합성 HEIC만 사용하여 설치된 번들의 worker와 프로토콜을 실제 변환까지 확인한다.
func smokeTest() -> Int32 {
    guard fileThumbnailSmokeTest() else { return 1 }
    guard let resources = Bundle.main.resourceURL else { return 1 }
    let folder = URL(fileURLWithPath: InputValidator.canonicalPath(FileManager.default.temporaryDirectory), isDirectory: true).appendingPathComponent("heic-smoke-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch { return 1 }
    let source = folder.appendingPathComponent("한글 합성 사진.heic")
    guard let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
          let image = context.makeImage(),
          let encoder = CGImageDestinationCreateWithURL(source as CFURL, UTType.heic.identifier as CFString, 1, nil) else { return 1 }
    CGImageDestinationAddImage(encoder, image, nil)
    guard CGImageDestinationFinalize(encoder) else { return 1 }
    var settings = AppSettings()
    settings.outputDirectory = folder.appendingPathComponent("결과 폴더").path
    let job = ConversionJob(files: [InputValidator.canonicalPath(source)], settings: settings)
    let process = Process()
    process.executableURL = resources.appendingPathComponent("worker/heic-worker")
    process.environment = ["PATH": "/usr/bin:/bin", "HOME": folder.path, "PYTHONUTF8": "1"]
    let input = Pipe(), output = Pipe(), errors = Pipe()
    process.standardInput = input; process.standardOutput = output; process.standardError = errors
    let state = SmokeState(job: job, input: input.fileHandleForWriting)
    output.fileHandleForReading.readabilityHandler = { handle in state.receive(handle.availableData) }
    errors.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
    do {
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: WorkerRequest(command: "prepare", job: job).line())
        _ = state.done.wait(timeout: .now() + 30)
    } catch { fputs("내장 worker 실행 실패: \(error.localizedDescription)\n", stderr) }
    output.fileHandleForReading.readabilityHandler = nil
    errors.fileHandleForReading.readabilityHandler = nil
    try? input.fileHandleForWriting.close()
    if process.isRunning { process.terminate(); process.waitUntilExit() }
    let passed = state.succeeded
    if !passed { fputs("worker smoke 검증 실패: \(state.failure)\n", stderr) }
    if passed { print("내장 worker 합성 HEIC 변환 및 프로토콜 확인 완료") }
    return passed ? 0 : 1
}

final class SmokeState: @unchecked Sendable {
    let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var buffer = JSONLineBuffer()
    private var prepared = false
    private var converted = false
    private var passed = false
    private(set) var failure = "응답 없음 또는 시간 초과"
    private let job: ConversionJob
    private let input: FileHandle
    init(job: ConversionJob, input: FileHandle) { self.job = job; self.input = input }
    var succeeded: Bool { lock.lock(); defer { lock.unlock() }; return passed }
    func receive(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !data.isEmpty else { done.signal(); return }
        do {
            for event in try buffer.append(data) {
                guard event.jobID == job.id else { failure = "작업 ID 불일치"; done.signal(); return }
                switch event.event {
                case "prepared":
                    guard event.files == job.files, event.total == 1, event.rejected?.isEmpty != false else { failure = "준비 결과 불일치: 기대 \(job.files), 실제 \(String(describing: event.files)), \(String(describing: event.rejected))"; done.signal(); return }
                    prepared = true
                    try input.write(contentsOf: WorkerRequest(command: "run", job: job).line())
                case "file_succeeded":
                    guard let destination = event.destination,
                          CGImageSourceCreateWithURL(URL(fileURLWithPath: destination) as CFURL, nil) != nil else { done.signal(); return }
                    converted = true
                case "completed":
                    passed = prepared && converted && event.succeeded == 1 && event.failed == 0
                    done.signal()
                case "error", "file_failed", "cancelled": failure = event.message ?? event.error ?? event.event; done.signal()
                default: break
                }
            }
        } catch { failure = error.localizedDescription; done.signal() }
    }
}

if CommandLine.arguments.contains("--smoke-test") {
    let result = smokeTest()
    if result != 0 { exit(result) }
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}

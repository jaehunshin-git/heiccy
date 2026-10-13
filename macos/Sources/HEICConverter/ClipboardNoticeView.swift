import AppKit
import SwiftUI
import ConverterKit

/// 알림 내용과 닫기 동작을 분리해 실패 알림에서도 상세 패널을 열 수 있다.
struct ClipboardNoticeView: View {
    let notice: ClipboardConversionNotice
    let onOpen: () -> Void
    let onDismiss: () -> Void
    var pointerX: CGFloat = 150
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("heiccy").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("변환 알림 닫기")
                .help("알림 닫기 · 변환은 계속됩니다")
            }
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(headline, systemImage: symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(statusColor)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if notice.copiedFileCount != notice.heicCount {
                        Text("전체 \(notice.copiedFileCount)개 복사 · HEIC \(notice.heicCount)개")
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                    Text(guidance)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    if notice.phase == .converting {
                        ProgressView(value: Double(min(max(0, notice.completedCount), max(1, notice.heicCount))),
                                     total: Double(max(1, notice.heicCount)))
                            .progressViewStyle(.linear)
                            .accessibilityLabel("HEIC 변환 진행률")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([headline, copySummary, guidance, "클릭하여 상세 패널 열기"].joined(separator: ". "))
            .help(notice.detail ?? "클릭하여 현재 클립보드와 변환 상태 보기")
        }
        .padding(.horizontal, 14).padding(.bottom, 14)
        .padding(.top, PanelPlacement.pointerHeight + 8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                ClipboardNoticeMaterial()
            }
        }
        .clipShape(PanelOutline(pointerX: pointerX))
        .overlay {
            PanelOutline(pointerX: pointerX)
                .stroke(Color.primary.opacity(contrast == .increased ? 0.5 : 0.12), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private var headline: String {
        switch notice.phase {
        case .preparing: return "HEIC \(notice.heicCount)개 복사됨"
        case .converting: return "HEIC 변환 중 \(notice.completedCount)/\(notice.heicCount)"
        case .completed: return "HEIC \(notice.heicCount)개 변환 완료"
        case .failed: return "HEIC \(notice.heicCount)개 변환 실패"
        }
    }

    private var copySummary: String {
        let progress = notice.phase == .completed
            ? "\(notice.completedCount)개 변환 완료" : "\(notice.completedCount)개 처리"
        return "전체 \(notice.copiedFileCount)개 복사, HEIC \(notice.heicCount)개, \(progress)"
    }

    private var statusColor: Color {
        switch notice.phase {
        case .completed: return .green
        case .failed: return .orange
        case .preparing, .converting: return .primary
        }
    }

    private var guidance: String {
        switch notice.phase {
        case .preparing: return "복사한 파일을 확인하고 변환을 준비합니다."
        case .converting: return "변환이 끝나면 붙여넣을 수 있습니다."
        case .completed: return "⌘V로 붙여넣을 준비가 되었습니다."
        case .failed:
            let detail = notice.detail?.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.flatMap { $0.isEmpty ? nil : $0 } ?? "상세 패널에서 변환 상태를 확인하세요."
        }
    }

    private var symbol: String {
        switch notice.phase {
        case .preparing: return "doc.on.clipboard"
        case .converting: return "arrow.triangle.2.circlepath"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
}

private struct ClipboardNoticeMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// 알림은 키 창이나 앱 활성 상태를 가져가지 않는다.
private final class ClipboardNoticePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor final class ClipboardNoticeController {
    private var panel: NSPanel
    private var onOpen: (() -> Void)?
    private var closeTimer: Timer?
    private var timerGeneration = UUID()
    private var dismissedID: UUID?
    private let completedDuration: TimeInterval
    private let failureDuration: TimeInterval
    private(set) var currentNotice: ClipboardConversionNotice?

    var isVisible: Bool { panel.isVisible }
    var frame: NSRect { panel.frame }

    init(completedDuration: TimeInterval = 4, failureDuration: TimeInterval = 6) {
        self.completedDuration = max(0, completedDuration)
        self.failureDuration = max(0, failureDuration)
        panel = Self.makePanel()
    }

    private static func makePanel() -> NSPanel {
        let panel = ClipboardNoticePanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 1),
                                         styleMask: [.nonactivatingPanel, .borderless],
                                         backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .none
        panel.isMovable = false
        panel.setAccessibilityLabel("HEIC 복사 및 변환 알림")
        return panel
    }

    func show(_ notice: ClipboardConversionNotice, anchor: NSRect, visibleFrame: NSRect,
              onOpen: @escaping () -> Void) {
        guard dismissedID != notice.id else { return }
        dismissedID = nil
        let previous = currentNotice
        currentNotice = notice
        self.onOpen = onOpen
        reanchor(anchor: anchor, visibleFrame: visibleFrame)
        panel.orderFrontRegardless()
        // 중복 완료 갱신이나 화면 재배치가 자동 닫힘 시점을 계속 연장하지 않는다.
        if previous?.id != notice.id || previous?.phase != notice.phase {
            scheduleDismissal(for: notice)
        }
    }

    func dismiss() {
        if let notice = currentNotice { dismissedID = notice.id }
        cancelDismissal()
        panel.orderOut(nil)
        currentNotice = nil
        onOpen = nil
    }

    func openDetails() {
        guard currentNotice != nil else { return }
        let action = onOpen
        dismiss()
        action?()
    }

    func reanchor(anchor: NSRect, visibleFrame: NSRect) {
        guard let notice = currentNotice else { return }
        let width = min(300, PanelPlacement.availableFrame(anchor: anchor, visibleFrame: visibleFrame).width)
        var view = ClipboardNoticeView(notice: notice, onOpen: { [weak self] in
            self?.openDetails()
        }, onDismiss: { [weak self] in self?.dismiss() })
        // 상태 없는 뷰를 새로 구성해 rootView 차분 갱신의 잔여 표시 캐시를 피한다.
        // 폭을 제한한 실제 콘텐츠의 높이를 측정한 뒤 AppKit에서 패널 크기를 결정한다.
        let hostingView = NSHostingView(rootView: view.frame(width: width).fixedSize(horizontal: false, vertical: true))
        let height = ceil(hostingView.fittingSize.height)
        let frame = PanelPlacement.frame(anchor: anchor, visibleFrame: visibleFrame,
                                         size: NSSize(width: width, height: height))
        view.pointerX = PanelPlacement.pointerCenter(anchorX: anchor.midX, panelFrame: frame)
        hostingView.rootView = view.frame(width: width).fixedSize(horizontal: false, vertical: true)
        hostingView.sizingOptions = []
        hostingView.autoresizingMask = [.width, .height]
        panel.setFrame(frame, display: false)
        hostingView.frame = NSRect(origin: .zero, size: frame.size)
        panel.contentView = hostingView
        hostingView.frame = NSRect(origin: .zero, size: frame.size)
        hostingView.needsLayout = true
        hostingView.layoutSubtreeIfNeeded()
        invalidateDisplay(of: hostingView)
    }

    /// 현재 contentView를 PNG로 저장한다. 호출부에서 상태와 외관을 전환한다.
    func render(to url: URL) throws {
        guard let content = panel.contentView, currentNotice != nil else {
            throw CocoaError(.fileReadUnknown)
        }
        content.needsLayout = true
        content.layoutSubtreeIfNeeded()
        // cacheDisplay 직전에 모든 자식의 표시 영역도 무효화해 전체 내용을 그린다.
        invalidateDisplay(of: content)
        content.display()
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: .atomic)
    }

    private func invalidateDisplay(of view: NSView) {
        view.setNeedsDisplay(view.bounds)
        for child in view.subviews { invalidateDisplay(of: child) }
    }

    private func cancelDismissal() {
        closeTimer?.invalidate()
        closeTimer = nil
        timerGeneration = UUID()
    }

    private func scheduleDismissal(for notice: ClipboardConversionNotice) {
        cancelDismissal()
        let duration: TimeInterval
        switch notice.phase {
        case .preparing, .converting: return
        case .completed: duration = completedDuration
        case .failed: duration = failureDuration
        }
        let generation = timerGeneration
        let timer = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
            // Timer는 main run loop에만 등록하며 콜백도 같은 actor에서 수행한다.
            MainActor.assumeIsolated {
                guard let self, self.timerGeneration == generation,
                      self.currentNotice?.id == notice.id else { return }
                self.dismiss()
            }
        }
        closeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    deinit { closeTimer?.invalidate() }
}

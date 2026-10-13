import AppKit
import SwiftUI
import ConverterKit

struct PanelView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var chrome: PanelChromeState
    var onClose: () -> Void = {}
    // 스크롤 컨테이너 대신 실제 행을 배치해 필요한 패널 높이를 측정한다.
    var measuresContent = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var closeFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header.padding(14)
            Divider().padding(.horizontal, 14)
            HStack {
                Text("현재 클립보드").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(model.clipboardFiles.count)개").font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 8)
            if model.clipboardFiles.isEmpty {
                emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if measuresContent {
                fileRows(Array(model.clipboardFiles.prefix(3)))
            } else {
                OverlayScrollView {
                    fileRows(model.clipboardFiles)
                }
                // 새 클립보드로 바뀌면 첫 행부터 표시하고 상태 갱신 시에는 위치를 유지한다.
                .id(model.clipboardFiles.map(\.id))
            }
            Divider().padding(.horizontal, 14)
            guidance.padding(14)
        }
        .padding(.top, PanelPlacement.pointerHeight)
        .frame(maxWidth: .infinity, maxHeight: measuresContent ? nil : .infinity)
        .background {
            ZStack {
                if reduceTransparency {
                    Color(nsColor: .windowBackgroundColor)
                } else {
                    PanelGlass(opacity: 1)
                    Color(nsColor: .windowBackgroundColor).opacity(contrast == .increased ? 1 : 0.9)
                }
            }
        }
        .clipShape(PanelOutline(pointerX: chrome.pointerX))
        .overlay {
            PanelOutline(pointerX: chrome.pointerX)
                .stroke(contrast == .increased ? Color.primary.opacity(0.5) : Color.white.opacity(colorScheme == .dark ? 0.22 : 0.6), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .controlSize(.regular)
    }

    private func fileRows(_ files: [ClipboardDisplayFile]) -> some View {
        VStack(spacing: 0) {
            ForEach(files, id: \.id) { file in
                ClipboardFileRow(file: file)
                if file.id != files.last?.id { Divider().padding(.leading, 56) }
            }
        }.padding(.horizontal, 14)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            PhotoClipboardIconShape().fill(.black)
                .frame(width: 22, height: 24)
                .frame(width: 34, height: 34)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            HeiccyWordmark()
            Spacer(minLength: 4)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).frame(width: 32, height: 32)
            }
            .buttonStyle(NeutralCloseButtonStyle())
            .accessibilityLabel("패널 숨기기")
            .help("패널 숨기기 · 앱은 계속 실행됩니다")
            .focused($closeFocused).focusEffectDisabled()
            .overlay(Circle().strokeBorder(Color.primary.opacity(closeFocused ? 0.45 : 0), lineWidth: 1.5).allowsHitTesting(false))
            .keyboardShortcut(.escape, modifiers: [])
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            PhotoClipboardIconShape().fill(.secondary).frame(width: 29, height: 32)
                .accessibilityHidden(true)
            Text("클립보드에 표시할 파일이 없습니다").font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text(model.clipboardEnabled ? "Finder에서 HEIC 파일을 복사하세요." : "우클릭 메뉴에서 자동 변환을 다시 시작하세요.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.center).padding(.horizontal, 14).padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private var guidance: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.clipboardEnabled {
                Label("자동 변환 일시정지됨", systemImage: "pause.circle")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Text("준비된 결과 유지 · 우클릭으로 다시 시작")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if !model.message.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        if model.active {
                            ProgressView().controlSize(.small).accessibilityHidden(true)
                        }
                        Text(model.message).font(.caption).lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .help(model.message)
                            .accessibilityLabel(model.message)
                    }
                }
                Text(!model.clipboardFiles.isEmpty && model.clipboardFiles.allSatisfy(\.isVideo)
                     ? "복사한 동영상의 클립보드 내용을 그대로 유지합니다."
                     : "변환 완료 후 ⌘V로 붙여넣으세요. 완료 전에는 원본이 전달될 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ClipboardFileRow: View {
    let file: ClipboardDisplayFile

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if file.isVideo {
                Image(systemName: "video.fill")
                    .font(.system(size: 19)).foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityHidden(true)
            } else if let url = file.url {
                FileThumbnailView(url: url)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 19)).foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(file.name).font(.callout.weight(.medium))
                    .lineLimit(1).truncationMode(.middle)
                    .help(file.name)
                Label(file.isVideo ? "변환 제외" : file.status.label, systemImage: statusIcon)
                    .font(.caption).foregroundStyle(statusColor)
                if let detail = file.detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).help(detail)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(file.name)
        .accessibilityValue([file.status.label, file.detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
    }

    private var statusIcon: String {
        switch file.status {
        case .ready: return "circle.dashed"
        case .converting: return "arrow.triangle.2.circlepath"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .unsupported: return "minus.circle"
        }
    }

    private var statusColor: Color {
        switch file.status {
        case .ready, .unsupported: return .secondary
        case .converting: return .accentColor
        case .completed: return .green
        case .failed: return .red
        }
    }
}

/// 네이티브 오버레이 스크롤바를 사용하여 좌우 여백을 동일하게 유지한다.
private struct OverlayScrollView<Content: View>: NSViewRepresentable {
    var content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = PanelScrollView()
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.focusRingType = .exterior
        scrollView.setAccessibilityLabel("현재 클립보드 파일 목록")
        let hosting = NSHostingView(rootView: hostedContent(context: context))
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = hosting
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            hosting.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            hosting.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])
        return scrollView
    }
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        (scrollView.documentView as? NSHostingView<AnyView>)?.rootView =
            hostedContent(context: context)
    }

    private func hostedContent(context: Context) -> AnyView {
        AnyView(content
            .environment(\.colorScheme, context.environment.colorScheme)
            .environment(\.layoutDirection, context.environment.layoutDirection)
            .environment(\.locale, context.environment.locale)
            .environment(\.isEnabled, context.environment.isEnabled))
    }
}

extension NSView {
    func firstPanelScrollView() -> PanelScrollView? {
        if let scroll = self as? PanelScrollView { return scroll }
        return subviews.lazy.compactMap { $0.firstPanelScrollView() }.first
    }
}

final class PanelScrollView: NSScrollView {
    override var acceptsFirstResponder: Bool { true }
    // 기본 NSScrollView의 문서 뷰 포커스 위임 대신 읽기 전용 목록 자체가 키를 받는다.
    override func becomeFirstResponder() -> Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(rect: bounds).fill() }

    override func keyDown(with event: NSEvent) {
        if !scrollWithKeyboard(event) { super.keyDown(with: event) }
    }

    @discardableResult func scrollWithKeyboard(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let document = documentView else { return false }
        let bounds = contentView.bounds
        let minimum = document.bounds.minY
        let maximum = max(minimum, document.bounds.maxY - bounds.height)
        let direction: CGFloat = document.isFlipped ? 1 : -1
        var y = bounds.minY
        switch event.keyCode {
        case 125: y += direction * 32 // ↓
        case 126: y -= direction * 32 // ↑
        case 121: y += direction * bounds.height // Page Down
        case 116: y -= direction * bounds.height // Page Up
        case 115: y = document.isFlipped ? minimum : maximum // Home
        case 119: y = document.isFlipped ? maximum : minimum // End
        default: return false
        }
        contentView.scroll(to: NSPoint(x: bounds.minX, y: min(maximum, max(minimum, y))))
        reflectScrolledClipView(contentView)
        return true
    }

    // 이 패널은 시스템 선호가 변경돼도 스크롤바 공간을 차감하지 않는다.
    override var scrollerStyle: NSScroller.Style {
        get { super.scrollerStyle }
        set { super.scrollerStyle = .overlay }
    }
}

/// 창 뒤의 화면을 흐리게 하는 macOS 기본 유리 소재를 사용한다.
private struct PanelGlass: NSViewRepresentable {
    var opacity: CGFloat
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.alphaValue = opacity
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) { nsView.alphaValue = opacity }
}

private struct NeutralCloseButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(.secondary)
            .background(Color.primary.opacity(configuration.isPressed ? 0.16 : 0.06), in: Circle())
            .contentShape(Circle())
    }
}

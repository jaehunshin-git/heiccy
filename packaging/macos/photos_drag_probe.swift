// 실제 Photos 드래그의 타입과 자동 변환 저장소의 안전 거절을 관찰한다.
// 파일 약속을 수신하거나 사진·파일을 내보내지 않는다. 원문 데이터는 출력하지 않는다.
// 저장소 루트에서 ConverterKit 소스와 함께 컴파일한다. 사용법은 후속 검증 문서를 따른다.
import AppKit
import Foundation

@MainActor private final class ProbeView: NSView {
    let label = NSTextField(wrappingLabelWithString: "Photos의 테스트 사진을 이 창으로 드래그하세요.\n파일 약속을 실행하지 않고 클립보드 보존 여부를 검사합니다.")

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .URL, .init("public.heic"), .tiff]
            + NSFilePromiseReceiver.readableDraggedTypes.map { .init($0) })
        label.frame = NSRect(x: 24, y: 40, width: 432, height: 100)
        label.font = .systemFont(ofSize: 17)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)은 사용하지 않습니다.") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let board = sender.draggingPasteboard
        let generation = board.changeCount
        let types = (board.pasteboardItems ?? []).map { $0.types.map(\.rawValue) }
        let result: String
        let typesOnly = CommandLine.arguments.contains("--types-only")
        if typesOnly {
            result = "타입 관찰 완료; 원문 데이터나 파일 약속을 요청하지 않음"
        } else {
            let store = AutomaticClipboardStore(pasteboard: board)
            do {
                let snapshot = try store.capture()
                result = snapshot.targets.isEmpty ? "변환 대상 없음" : "지원 입력; 관찰 창에서는 변환하지 않음"
            } catch AutomaticClipboardError.unsupportedRepresentation {
                result = "파일 약속 등 복구할 수 없는 표현을 거절함"
            } catch {
                // 오류에 원문 경로·자산 식별자가 포함될 가능성이 있으므로 타입명만 출력한다.
                result = "입력 거절: \(String(describing: type(of: error)))"
            }
        }
        let unchanged = board.changeCount == generation
        let record: [String: Any] = ["itemTypes": types, "itemCount": types.count,
            "result": result, "generationUnchanged": unchanged,
            "filePromiseReceived": false, "typesOnly": typesOnly]
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print(text); fflush(stdout)
            if let reportFlag = CommandLine.arguments.firstIndex(of: "--report-file"),
               reportFlag + 1 < CommandLine.arguments.count {
                // 지정한 새 파일에 타입만 기록한다. 기존 보고서는 덮어쓰지 않는다.
                try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[reportFlag + 1]), options: .withoutOverwriting)
            }
        }
        label.stringValue = "\(result)\n클립보드 세대 유지: \(unchanged ? "성공" : "실패")"
        // 수신 성공으로 오인하지 않도록 drop을 허용하지 않는다.
        return []
    }
}

@MainActor private final class ProbeDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 80, y: 100, width: 480, height: 190),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Photos 드래그 안전 거절 검증"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentView = ProbeView(frame: NSRect(x: 0, y: 0, width: 480, height: 190))
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main private enum PhotosDragProbe {
    @MainActor static func main() {
        let delegate = ProbeDelegate()
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.run()
    }
}

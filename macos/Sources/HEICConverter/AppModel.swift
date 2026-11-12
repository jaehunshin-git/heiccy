import AppKit
import Combine
import ConverterKit

/// 목록 ID는 경로가 아닌 pasteboard 항목에 속한다. 같은 파일을 여러 번 복사해도 순서를 유지한다.
struct ClipboardDisplayFile: Identifiable {
    let id: String
    var name: String
    var url: URL?
    var status: ClipboardDisplayStatus
    var detail: String?
    var isVideo = false
}

enum ClipboardDisplayStatus {
    case ready, converting, completed, failed, unsupported
    var label: String {
        switch self {
        case .ready: return "준비"
        case .converting: return "변환 중"
        case .completed: return "완료"
        case .failed: return "실패"
        case .unsupported: return "지원 안 함"
        }
    }
}

/// 성공 알림은 변환 결과가 현재 클립보드에 모두 반영된 뒤에만 제공한다.
struct ClipboardConversionNotice: Equatable, Identifiable {
    enum Phase: Equatable { case preparing, converting, completed, failed }
    let id: UUID
    let sourceChangeCount: Int
    let copiedFileCount: Int
    let heicCount: Int
    let phase: Phase
    let completedCount: Int
    let detail: String?
}

@MainActor final class AppModel: ObservableObject {
    @Published var settings: AppSettings { didSet { settings.save(to: settingsStore) } }
    // 자동 변환은 실행마다 켜진다. 저장된 legacy 설정은 실행 상태에 사용하지 않는다.
    @Published private(set) var clipboardEnabled = true
    @Published private(set) var clipboardFiles: [ClipboardDisplayFile] = []
    @Published private(set) var message = "HEIC를 복사하면 자동으로 변환합니다."
    @Published private(set) var active = false
    @Published private(set) var terminating = false
    @Published private(set) var conversionNotice: ClipboardConversionNotice?
    private let worker: WorkerConnection
    private let store: AutomaticClipboardStore
    private let pasteboard: NSPasteboard
    private let settingsStore: UserDefaults
    private var timer: Timer?
    private var observedChange: Int?
    private var publishedChange: Int?
    private var current: ClipboardSnapshot?
    private var pending: ClipboardSnapshot?
    private var work: Work?
    private var stopping = false
    private var shutdownCompletions: [() -> Void] = []
    private var shutdownFinished = false

    private struct Work {
        let snapshot: ClipboardSnapshot
        let job: ConversionJob
        let inputPaths: [String]
        var awaitingPreparation = true
        var invalidated = false
        var cancelSent = false
        var failed = false
        var results: [String: URL] = [:]
    }

    init(startClipboard: Bool = true, pasteboard: NSPasteboard = .general,
         defaults: UserDefaults = .standard, clipboardRoot: URL? = nil,
         worker: WorkerConnection? = nil) {
        self.pasteboard = pasteboard
        settingsStore = defaults
        settings = AppSettings.load(from: defaults)
        store = AutomaticClipboardStore(pasteboard: pasteboard, root: clipboardRoot)
        self.worker = worker ?? WorkerClient()
        self.worker.onEvent = { [weak self] in self?.receive($0) }
        self.worker.onFailure = { [weak self] in self?.workerFailed($0) }
        guard startClipboard else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollClipboard() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        // 시작 시 현재 내용을 표시한다. 복사 감지는 패널을 열거나 포커스를 바꾸지 않는다.
        pollClipboard()
    }

    func resetConversionOptions() {
        var options = ConversionOptions()
        // 설정 창에 없는 legacy 충돌 정책은 기본값 복원으로 바꾸지 않는다.
        options.onConflict = settings.options.onConflict
        settings.options = options
    }

    func setClipboard(_ enabled: Bool) {
        guard !terminating else { return }
        clipboardEnabled = enabled
        if !enabled {
            conversionNotice = nil
            pending = nil
            invalidateWork()
            updateCurrent(status: .ready, detail: nil)
            message = "자동 변환 일시정지됨 · 이미 준비한 결과는 유지합니다."
        } else {
            if publishedChange == pasteboard.changeCount {
                let completedCount = clipboardFiles.filter { $0.status == .completed }.count
                message = "\(completedCount)개 변환 완료 · ⌘V로 붙여넣으세요."
            }
            if publishedChange != pasteboard.changeCount { observedChange = nil }
            pollClipboard()
            if publishedChange != pasteboard.changeCount, let current,
               work == nil || work?.invalidated == true {
                pending = current
                startPending()
            }
        }
    }

    func pollClipboard() {
        guard !terminating else { return }
        let count = pasteboard.changeCount
        guard observedChange != count else { return }
        observedChange = count
        if publishedChange == count { return }
        conversionNotice = nil
        publishedChange = nil
        pending = nil
        invalidateWork()
        store.clipboardDidChange()
        current = nil
        clipboardFiles = []
        FileThumbnailStore.shared.removeAllCachedThumbnails()
        if #available(macOS 15.4, *), pasteboard.accessBehavior == .alwaysDeny {
            message = "클립보드 접근이 거부되었습니다. 시스템 설정에서 접근을 허용하세요."
            // 허용을 바꾸면 같은 세대라도 다시 확인한다.
            observedChange = nil
            return
        }
        do {
            let snapshot = try store.capture()
            guard snapshot.changeCount == pasteboard.changeCount else { observedChange = nil; return }
            current = snapshot
            clipboardFiles = snapshot.files.map {
                ClipboardDisplayFile(id: $0.id, name: $0.name, url: $0.url,
                    status: $0.isVideo ? .unsupported : .ready,
                    detail: $0.isVideo ? "동영상 · 변환 제외 · 클립보드 유지" : nil, isVideo: $0.isVideo)
            }
            if !clipboardEnabled {
                message = "자동 변환 일시정지됨"
            } else if snapshot.targets.isEmpty {
                message = snapshot.files.contains(where: \.isVideo)
                    ? "동영상은 변환하지 않습니다 · 클립보드를 유지합니다."
                    : (snapshot.files.isEmpty ? "클립보드에 HEIC가 없습니다." : "HEIC가 없습니다 · 현재 내용을 유지합니다.")
            } else {
                pending = snapshot
                message = "\(snapshot.targets.count)개 HEIC 변환 준비"
                notify(snapshot, phase: .preparing)
                startPending()
            }
        } catch {
            // 거절된 내용도 이름은 표시한다. 표현을 일부만 읽어서 게시하지 않는다.
            let previewFiles = store.previewFiles()
            let preview = previewFiles.map {
                ClipboardDisplayFile(id: $0.id, name: $0.name, url: $0.url,
                    status: .unsupported, detail: $0.isVideo ? "동영상 · 변환 제외 · 클립보드 유지" : error.localizedDescription,
                    isVideo: $0.isVideo)
            }
            guard pasteboard.changeCount == count else { observedChange = nil; return }
            clipboardFiles = preview
            message = "지원하지 않는 클립보드 · \(error.localizedDescription)"
            let heicCount = previewFiles.filter(\.isHEIC).count
            if clipboardEnabled, heicCount > 0 {
                conversionNotice = ClipboardConversionNotice(id: UUID(), sourceChangeCount: count,
                    copiedFileCount: previewFiles.count, heicCount: heicCount, phase: .failed,
                    completedCount: 0, detail: "\(error.localizedDescription) 전체 원본을 유지했습니다.")
            }
        }
    }

    private func invalidateWork() {
        guard work != nil else { return }
        work?.invalidated = true
        if work?.awaitingPreparation == false { sendCancel() }
    }

    private func sendCancel() {
        guard let work, !work.cancelSent else { return }
        self.work?.cancelSent = true
        do { try worker.send(WorkerRequest(command: "cancel", job: work.job)) }
        catch { workerFailed(error.localizedDescription) }
    }

    private func startPending() {
        guard !terminating, !stopping, work == nil, clipboardEnabled,
              let snapshot = pending else { return }
        pending = nil
        guard snapshot.changeCount == pasteboard.changeCount, !snapshot.targets.isEmpty else { return }
        // 옵션은 복사 세대마다 고정한다. 이름 충돌은 임시 작업 폴더 안에서만 처리한다.
        var jobSettings = settings
        jobSettings.options.onConflict = "rename"
        var job: ConversionJob?
        do {
            // raw HEIC 데이터는 prepare 단계에서 작업 소유의 입력 파일로 물질화한다.
            let placeholder = ConversionJob(files: [], settings: jobSettings, destination: .clipboard)
            job = placeholder
            let prepared = try store.prepare(snapshot: snapshot, jobID: placeholder.id)
            let paths = prepared.inputs.map(\.path)
            // worker 요청 ID와 저장소 소유 ID를 일치시키기 위해 기존 job ID를 유지한다.
            let actual = ConversionJob(id: placeholder.id, files: paths, settings: jobSettings, destination: .clipboard)
            job = actual
            work = Work(snapshot: snapshot, job: actual, inputPaths: paths)
            active = true
            notify(snapshot, phase: .preparing)
            updateCurrent(status: .converting, detail: nil)
            // 메모리 HEIC도 썸네일에 같은 파일 디코더를 사용한다.
            for (target, input) in zip(snapshot.targets, prepared.inputs) {
                if let index = clipboardFiles.firstIndex(where: { $0.id == target.id }), snapshot.files.first(where: { $0.id == target.id })?.url == nil {
                    clipboardFiles[index].url = input
                }
            }
            try worker.start()
            try worker.send(WorkerRequest(command: "prepare", job: actual, outputDirectory: prepared.outputDirectory.path))
            message = "\(snapshot.targets.count)개 HEIC 변환 중 · 완료 전 붙여넣기는 원본을 전달할 수 있습니다."
        } catch {
            if work != nil {
                // 요청 쓰기가 일부만 성공했어도 worker가 입력을 사용할 수 있다.
                // 실제 종료 콜백 전에는 작업 파일을 삭제하지 않는다.
                workerFailed(error.localizedDescription)
            } else {
                if let job { store.discard(jobID: job.id) }
                active = false
                updateCurrent(status: .failed, detail: error.localizedDescription)
                message = "변환 실패 · \(error.localizedDescription)"
                notify(snapshot, phase: .failed, detail: "변환 준비에 실패했습니다. 원본을 유지했습니다.")
            }
        }
    }

    private func receive(_ event: WorkerEvent) {
        guard !terminating, let currentWork = work else { return }
        // 취소와 최종 완료가 교차한 이전 작업의 늦은 응답은 다음 세대에 영향을 주지 않는다.
        guard event.jobID == currentWork.job.id else { return }
        switch event.event {
        case "prepared":
            work?.awaitingPreparation = false
            guard event.files == currentWork.inputPaths, event.rejected?.isEmpty == true else {
                work?.failed = true
                sendCancel()
                return
            }
            if currentWork.invalidated || !clipboardEnabled || pasteboard.changeCount != currentWork.snapshot.changeCount {
                work?.invalidated = true
                sendCancel()
            } else {
                do {
                    notify(currentWork.snapshot, phase: .converting)
                    try worker.send(WorkerRequest(command: "run", job: currentWork.job))
                }
                catch { workerFailed(error.localizedDescription) }
            }
        case "file_succeeded":
            guard let source = event.source, currentWork.inputPaths.contains(source), let destination = event.destination else {
                work?.failed = true; return
            }
            work?.results[source] = URL(fileURLWithPath: destination)
            if !currentWork.invalidated {
                notify(currentWork.snapshot, phase: .converting, completedCount: work?.results.count ?? 0)
            }
        case "file_failed", "file_skipped":
            work?.failed = true
        case "completed", "cancelled":
            finish(event)
        case "error":
            workerFailed(event.message ?? "worker 오류")
        default: break
        }
    }

    private func finish(_ event: WorkerEvent) {
        guard let work else { return }
        let relevant = pasteboard.changeCount == work.snapshot.changeCount && current?.changeCount == work.snapshot.changeCount
        let allSucceeded = event.event == "completed" && !work.failed && event.failed == 0 && event.skipped == 0
            && event.succeeded == work.inputPaths.count && work.results.count == work.inputPaths.count
        if relevant, !work.invalidated, clipboardEnabled, allSucceeded {
            do {
                let results = try work.inputPaths.map { path -> URL in
                    guard let result = work.results[path] else { throw WorkerFailure.invalidEvent }
                    return result
                }
                let count = try store.publish(snapshot: work.snapshot, jobID: work.job.id, results: results)
                observedChange = count; publishedChange = count
                updateCurrent(status: .completed, detail: "붙여넣기 준비됨")
                for (target, result) in zip(work.snapshot.targets, results) {
                    if let index = clipboardFiles.firstIndex(where: { $0.id == target.id }) {
                        clipboardFiles[index].url = result
                        clipboardFiles[index].name = result.lastPathComponent
                    }
                }
                message = "\(results.count)개 변환 완료 · ⌘V로 붙여넣으세요."
                notify(work.snapshot, phase: .completed, completedCount: results.count)
            } catch {
                updateCurrent(status: .failed, detail: error.localizedDescription)
                message = "게시 실패 · \(error.localizedDescription)"
                notify(work.snapshot, phase: .failed, detail: "클립보드 반영에 실패했습니다. 상세 내용을 확인하세요.")
                resetUnpublishedURLs(snapshot: work.snapshot)
                store.discard(jobID: work.job.id)
                // 게시 실패 후 원본 복구도 앱이 만든 세대다. 즉시 재변환하지 않는다.
                if store.ownedChangeCount == pasteboard.changeCount { observedChange = pasteboard.changeCount }
            }
        } else {
            if relevant, clipboardEnabled, !work.invalidated {
                updateCurrent(status: .failed, detail: "전체 원본을 유지했습니다.")
                message = "변환 실패 · 부분 결과를 게시하지 않고 전체 원본을 유지했습니다."
                notify(work.snapshot, phase: .failed, detail: "변환하지 못했습니다. 전체 원본을 유지했습니다.")
            }
            resetUnpublishedURLs(snapshot: work.snapshot)
            store.discard(jobID: work.job.id)
        }
        self.work = nil; active = false
        // 결과를 게시하기 직전 복사한 입력까지 즉시 관찰한다.
        pollClipboard()
        startPending()
    }

    private func resetUnpublishedURLs(snapshot: ClipboardSnapshot) {
        guard current?.changeCount == snapshot.changeCount, publishedChange == nil else { return }
        for file in snapshot.files {
            if let index = clipboardFiles.firstIndex(where: { $0.id == file.id }) {
                clipboardFiles[index].url = file.url
            }
        }
    }

    private func updateCurrent(status: ClipboardDisplayStatus, detail: String?) {
        guard let current else { return }
        let targets = Set(current.targets.map(\.id))
        for index in clipboardFiles.indices where targets.contains(clipboardFiles[index].id) {
            // 이미 게시한 결과는 끄더라도 완료 상태를 유지한다.
            if status == .ready, clipboardFiles[index].status == .completed { continue }
            clipboardFiles[index].status = status
            clipboardFiles[index].detail = detail
        }
    }

    private func workerFailed(_ error: String) {
        guard !stopping else { return }
        stopping = true
        let failedWork = work
        work = nil; active = false
        if failedWork?.snapshot.changeCount == pasteboard.changeCount {
            updateCurrent(status: .failed, detail: error)
            message = "변환 실패 · \(error)"
            if let failedWork, !failedWork.invalidated {
                notify(failedWork.snapshot, phase: .failed, detail: "변환하지 못했습니다. 원본을 유지했습니다.")
            }
        }
        worker.stop { [weak self] in
            guard let self else { return }
            if let failedWork {
                self.resetUnpublishedURLs(snapshot: failedWork.snapshot)
                self.store.discard(jobID: failedWork.job.id)
            }
            self.stopping = false
            self.pollClipboard()
            self.startPending()
        }
    }

    private func notify(_ snapshot: ClipboardSnapshot, phase: ClipboardConversionNotice.Phase,
                        completedCount: Int = 0, detail: String? = nil) {
        guard !terminating, clipboardEnabled, !snapshot.targets.isEmpty,
              current?.changeCount == snapshot.changeCount else { return }
        let boardIsCurrent = pasteboard.changeCount == snapshot.changeCount
        let ownPublication = publishedChange == pasteboard.changeCount
            || (phase == .failed && store.ownedChangeCount == pasteboard.changeCount)
        guard boardIsCurrent || ownPublication else { return }
        let id = conversionNotice.flatMap { $0.sourceChangeCount == snapshot.changeCount ? $0.id : nil } ?? UUID()
        conversionNotice = ClipboardConversionNotice(id: id, sourceChangeCount: snapshot.changeCount,
            copiedFileCount: snapshot.files.count, heicCount: snapshot.targets.count, phase: phase,
            completedCount: completedCount, detail: detail)
    }

    func shutdown(completion: (() -> Void)? = nil) {
        if shutdownFinished { completion?(); return }
        if let completion { shutdownCompletions.append(completion) }
        guard !terminating else { return }
        terminating = true
        conversionNotice = nil
        timer?.invalidate(); timer = nil
        pending = nil
        let jobID = work?.job.id
        work?.invalidated = true
        worker.stop { [self] in
            if let jobID { store.discard(jobID: jobID) }
            do { try store.shutdown() }
            catch { message = "원본 복구 실패 · 임시 파일을 유지했습니다: \(error.localizedDescription)" }
            active = false; work = nil
            FileThumbnailStore.shared.removeAllCachedThumbnails()
            shutdownFinished = true
            let completions = shutdownCompletions; shutdownCompletions.removeAll()
            completions.forEach { $0() }
        }
    }
}

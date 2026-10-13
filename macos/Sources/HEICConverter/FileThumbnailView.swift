import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// 원본과 변환 작업에 영향을 주지 않는 작은 파일 미리보기다.
struct FileThumbnailView: View {
    let url: URL
    var size: CGFloat = 44
    @StateObject private var state = FileThumbnailState()

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.06))
            if state.url == url, let image = state.image {
                Image(decorative: image, scale: 2)
                    .resizable().scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 19)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityHidden(true)
        .task(id: url) {
            await state.load(url)
        }
        .onDisappear {
            state.clear()
            FileThumbnailStore.shared.removeCachedThumbnail(for: url)
        }
    }
}

@MainActor
private final class FileThumbnailState: ObservableObject {
    @Published private(set) var image: CGImage?
    private(set) var url: URL?
    private var generation = UUID()

    func load(_ url: URL) async {
        clear()
        self.url = url
        let current = generation
        let result = await FileThumbnailStore.shared.thumbnail(for: url)
        guard !Task.isCancelled, generation == current else { return }
        image = result
    }

    func clear() {
        generation = UUID()
        url = nil
        image = nil
    }
}

/// 디코딩은 직렬 백그라운드 큐에서 수행하며 디스크 캐시를 만들지 않는다.
/// 공개된 내부 비동기 진입점은 앱 스모크 검사에서도 같은 디코더를 사용하게 한다.
final class FileThumbnailStore: @unchecked Sendable {
    static let shared = FileThumbnailStore()
    static let maximumPixelSize = 96
    private let queue = DispatchQueue(label: "HEICConverter.thumbnails", qos: .utility)
    private let maximumEntries = 96
    private let maximumCost = 4 * 1024 * 1024
    private var entries: [URL: Entry] = [:]
    private var recency: [URL] = []
    private var totalCost = 0

    private struct Fingerprint: Equatable {
        let size: UInt64
        let modified: Date?
        let created: Date?
        let inode: UInt64

        init?(url: URL) {
            guard url.isFileURL,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber else { return nil }
            self.size = size.uint64Value
            modified = attributes[.modificationDate] as? Date
            created = attributes[.creationDate] as? Date
            inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        }
    }

    private struct Entry {
        let fingerprint: Fingerprint
        let image: CGImage
        var cost: Int { image.bytesPerRow * image.height }
    }

    func thumbnail(for url: URL) async -> CGImage? {
        let request = ThumbnailRequest()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                request.attach(continuation)
                queue.async { [self] in
                    guard !request.isCancelled else { return }
                    let result: CGImage? = autoreleasepool {
                        let key = url.standardizedFileURL
                        guard let fingerprint = Fingerprint(url: key) else {
                            remove(key)
                            return nil
                        }
                        if let entry = entries[key], entry.fingerprint == fingerprint {
                            touch(key)
                            return entry.image
                        }
                        remove(key)
                        guard !request.isCancelled,
                              let source = CGImageSourceCreateWithURL(key as CFURL, [
                                kCGImageSourceShouldCache: false,
                              ] as CFDictionary),
                              let image = CGImageSourceCreateThumbnailAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), [
                                kCGImageSourceCreateThumbnailFromImageAlways: true,
                                kCGImageSourceCreateThumbnailWithTransform: true,
                                kCGImageSourceThumbnailMaxPixelSize: Self.maximumPixelSize,
                                kCGImageSourceShouldCacheImmediately: true,
                              ] as CFDictionary),
                              image.width <= Self.maximumPixelSize,
                              image.height <= Self.maximumPixelSize,
                              !request.isCancelled,
                              Fingerprint(url: key) == fingerprint else { return nil }
                        let entry = Entry(fingerprint: fingerprint, image: image)
                        if entry.cost <= maximumCost {
                            while entries.count >= maximumEntries || totalCost + entry.cost > maximumCost {
                                guard let oldest = recency.first else { break }
                                remove(oldest)
                            }
                            entries[key] = entry
                            totalCost += entry.cost
                            touch(key)
                        }
                        return image
                    }
                    request.finish(result)
                }
            }
        } onCancel: {
            request.cancel()
        }
    }

    func removeCachedThumbnail(for url: URL) {
        queue.async { [self] in remove(url.standardizedFileURL) }
    }

    func removeAllCachedThumbnails() {
        queue.async { [self] in
            entries.removeAll()
            recency.removeAll()
            totalCost = 0
        }
    }

    private func touch(_ key: URL) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    private func remove(_ key: URL) {
        if let old = entries.removeValue(forKey: key) { totalCost -= old.cost }
        recency.removeAll { $0 == key }
    }
}

/// 사라진 뷰의 대기를 즉시 끝내고 이미 대기열에 들어간 디코딩도 건너뛴다.
private final class ThumbnailRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var completed = false
    private var continuation: CheckedContinuation<CGImage?, Never>?

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func attach(_ value: CheckedContinuation<CGImage?, Never>) {
        lock.lock()
        if cancelled {
            lock.unlock()
            value.resume(returning: nil)
        } else {
            continuation = value
            lock.unlock()
        }
    }

    func finish(_ image: CGImage?) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let pending = continuation
        continuation = nil
        let result = cancelled ? nil : image
        lock.unlock()
        pending?.resume(returning: result)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        finish(nil)
    }
}

/// 앱 초기화 전에도 실행할 수 있는 합성 HEIC 검사다. 개인 사진은 읽지 않는다.
func fileThumbnailSmokeTest() -> Bool {
    let completion = DispatchSemaphore(value: 0)
    let result = ThumbnailSmokeResult()
    let task = Task.detached {
        result.set(await runThumbnailSmokeTest())
        completion.signal()
    }
    guard completion.wait(timeout: .now() + 15) == .success else {
        task.cancel()
        return false
    }
    return result.value
}

private final class ThumbnailSmokeResult: @unchecked Sendable {
    private let lock = NSLock()
    private var passed = false
    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return passed
    }
    func set(_ value: Bool) {
        lock.lock()
        passed = value
        lock.unlock()
    }
}

private func runThumbnailSmokeTest() async -> Bool {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("heic-thumbnail-check-\(UUID().uuidString)", isDirectory: true)
    let url = directory.appendingPathComponent("synthetic.heic")
    let multiImageURL = directory.appendingPathComponent("primary-second.heic")
    defer {
        FileThumbnailStore.shared.removeCachedThumbnail(for: url)
        FileThumbnailStore.shared.removeCachedThumbnail(for: multiImageURL)
        try? FileManager.default.removeItem(at: directory)
    }
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let context = CGContext(data: nil, width: 256, height: 128, bitsPerComponent: 8,
                                      bytesPerRow: 256 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let destination = CGImageDestinationCreateWithURL(url as CFURL,
                  UTType.heic.identifier as CFString, 1, nil) else { return false }
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 256, height: 128))
        guard let source = context.makeImage() else { return false }
        CGImageDestinationAddImage(destination, source, [kCGImagePropertyOrientation: 6] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return false }
        let original = try Data(contentsOf: url)
        let store = FileThumbnailStore.shared
        guard let image = await store.thumbnail(for: url), image.width == 48, image.height == 96,
              try Data(contentsOf: url) == original,
              let cached = await store.thumbnail(for: url), image === cached else { return false }
        store.removeCachedThumbnail(for: url)
        guard let reloaded = await store.thumbnail(for: url), reloaded !== cached else { return false }
        let cancelled = Task.detached { () -> CGImage? in
            withUnsafeCurrentTask { $0?.cancel() }
            return await store.thumbnail(for: url)
        }
        guard await cancelled.value == nil else { return false }
        try Data("invalid HEIC".utf8).write(to: url, options: .atomic)
        guard await store.thumbnail(for: url) == nil,
              await store.thumbnail(for: directory.appendingPathComponent("missing.heic")) == nil,
              await store.thumbnail(for: URL(string: "https://example.invalid/photo.heic")!) == nil else { return false }
        return await checkPrimaryImageThumbnail(at: multiImageURL)
    } catch {
        return false
    }
}

/// 첫 이미지가 빨강이어도 대표 이미지인 두 번째 파랑을 미리보기해야 한다.
private func checkPrimaryImageThumbnail(at url: URL) async -> Bool {
    guard let context = CGContext(data: nil, width: 256, height: 128, bitsPerComponent: 8,
                                  bytesPerRow: 256 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let destination = CGImageDestinationCreateWithURL(url as CFURL,
              UTType.heic.identifier as CFString, 2, nil) else { return false }
    for index in 0..<2 {
        context.setFillColor(CGColor(red: index == 0 ? 1 : 0, green: 0, blue: index == 1 ? 1 : 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 256, height: 128))
        guard let frame = context.makeImage() else { return false }
        CGImageDestinationAddImage(destination, frame, [kCGImagePropertyPrimaryImage: index == 1] as CFDictionary)
    }
    guard CGImageDestinationFinalize(destination),
          let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          CGImageSourceGetCount(source) == 2,
          CGImageSourceGetPrimaryImageIndex(source) == 1,
          let thumbnail = await FileThumbnailStore.shared.thumbnail(for: url),
          thumbnail.width == 96, thumbnail.height == 48 else { return false }
    var pixel = [UInt8](repeating: 0, count: 4)
    return pixel.withUnsafeMutableBytes { bytes in
        guard let sample = CGContext(data: bytes.baseAddress, width: 1, height: 1,
                                     bitsPerComponent: 8, bytesPerRow: 4,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                        | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
        sample.draw(thumbnail, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return bytes[2] > 200 && bytes[0] < 50 && bytes[1] < 100
    }
}

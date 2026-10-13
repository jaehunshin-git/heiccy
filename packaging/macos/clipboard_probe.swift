// 클립보드 재현 도구. 앱이나 사진 보관함을 실행하지 않는다.
// 스냅샷에는 원문 데이터가 들어가므로 저장소 밖의 비공개 임시 경로를 사용한다.
import AppKit
import Darwin
import Foundation

private struct Representation: Codable, Equatable {
    let type: String
    let data: Data
}

private struct Snapshot: Codable {
    let version: Int
    let changeCount: Int
    let items: [[Representation]]
}

private enum ProbeError: String, Error {
    case usage = "명령과 인자를 확인하십시오."
    case changed = "읽기 또는 쓰기 중 세대가 바뀌었습니다."
    case unreadable = "모든 항목과 타입의 바이트를 읽지 못했습니다."
    case invalidSnapshot = "스냅샷 형식이 올바르지 않습니다."
    case fileRead = "스냅샷 파일을 읽지 못했습니다."
    case fileWrite = "스냅샷을 저장하지 못했습니다. 기존 파일은 덮어쓰지 않습니다."
    case stale = "예상 세대가 현재 세대와 다릅니다. 클립보드를 변경하지 않았습니다."
    case restore = "복구 쓰기 또는 확인에 실패했습니다. 스냅샷 파일을 보존했습니다."
}

private func board(named name: String) -> NSPasteboard {
    switch name {
    case "general": return .general
    case "drag": return NSPasteboard(name: .drag)
    default: return NSPasteboard(name: .init(name))
    }
}

// 지연 제공 데이터도 실제로 읽는다. 읽기 실패나 세대 변경을 부분 성공으로 다루지 않는다.
private func capture(_ board: NSPasteboard) throws -> Snapshot {
    let generation = board.changeCount
    let items: [NSPasteboardItem]
    if let available = board.pasteboardItems {
        items = available
    } else {
        guard board.types?.isEmpty != false else { throw ProbeError.unreadable }
        items = []
    }
    var saved: [[Representation]] = []
    for item in items {
        let types = item.types
        guard !types.isEmpty, Set(types.map(\.rawValue)).count == types.count else {
            throw ProbeError.unreadable
        }
        var representations: [Representation] = []
        for type in types {
            guard board.changeCount == generation else { throw ProbeError.changed }
            guard let data = item.data(forType: type) else { throw ProbeError.unreadable }
            representations.append(Representation(type: type.rawValue, data: data))
        }
        guard item.types == types else { throw ProbeError.changed }
        saved.append(representations)
    }
    guard board.changeCount == generation else { throw ProbeError.changed }
    return Snapshot(version: 1, changeCount: generation, items: saved)
}

private func load(_ path: String) throws -> Snapshot {
    // 심볼릭 링크를 따라가거나 파일 내용을 오류 메시지에 출력하지 않는다.
    let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else { throw ProbeError.fileRead }
    defer { Darwin.close(descriptor) }
    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0,
          metadata.st_mode & S_IFMT == S_IFREG else { throw ProbeError.fileRead }
    var bytes = Data()
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
        let count = buffer.withUnsafeMutableBytes {
            Darwin.read(descriptor, $0.baseAddress, $0.count)
        }
        if count < 0 {
            if errno == EINTR { continue }
            throw ProbeError.fileRead
        }
        if count == 0 { break }
        bytes.append(contentsOf: buffer.prefix(count))
    }
    guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: bytes),
          snapshot.version == 1,
          snapshot.items.allSatisfy({ item in
              !item.isEmpty && item.allSatisfy { !$0.type.isEmpty }
                  && Set(item.map(\.type)).count == item.count
          }) else { throw ProbeError.invalidSnapshot }
    return snapshot
}

private func save(_ snapshot: Snapshot, to path: String, board: NSPasteboard) throws {
    let destination = URL(fileURLWithPath: path).standardizedFileURL
    let temporary = destination.deletingLastPathComponent()
        .appendingPathComponent(".clipboard-probe-\(UUID().uuidString)").path
    let bytes = try JSONEncoder().encode(snapshot)
    let descriptor = Darwin.open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw ProbeError.fileWrite }
    defer {
        Darwin.close(descriptor)
        Darwin.unlink(temporary)
    }
    guard Darwin.fchmod(descriptor, 0o600) == 0 else { throw ProbeError.fileWrite }
    try bytes.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let count = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw ProbeError.fileWrite }
            offset += count
        }
    }
    guard Darwin.fsync(descriptor) == 0 else { throw ProbeError.fileWrite }
    guard board.changeCount == snapshot.changeCount else { throw ProbeError.changed }
    // 완성된 0600 파일만 노출한다. link는 기존 목적지가 있으면 실패하므로 덮어쓰지 않는다.
    guard Darwin.link(temporary, destination.path) == 0 else { throw ProbeError.fileWrite }
    if board.changeCount != snapshot.changeCount {
        Darwin.unlink(destination.path)
        throw ProbeError.changed
    }
}

private struct Difference: Encodable {
    let item: Int
    let missingTypes: [String]
    let mismatchedTypes: [String]
}

// 항목 순서는 비교하지만 한 항목 안의 타입 나열 순서와 캡처 세대 숫자는 비교하지 않는다.
private func differences(_ expected: Snapshot, _ actual: Snapshot) -> [Difference] {
    var differences: [Difference] = []
    for index in 0..<max(expected.items.count, actual.items.count) {
        let left = index < expected.items.count ? expected.items[index] : []
        let right = index < actual.items.count ? actual.items[index] : []
        let original = Dictionary(uniqueKeysWithValues: left.map { ($0.type, $0.data) })
        let current = Dictionary(uniqueKeysWithValues: right.map { ($0.type, $0.data) })
        let missing = original.keys.filter { current[$0] == nil }.sorted()
        let mismatched = current.keys.filter { original[$0] != current[$0] }.sorted()
        if !missing.isEmpty || !mismatched.isEmpty {
            differences.append(Difference(item: index, missingTypes: missing, mismatchedTypes: mismatched))
        }
    }
    return differences
}

private func restore(_ snapshot: Snapshot, to board: NSPasteboard, expected: Int) throws -> Int {
    let items = try snapshot.items.map { representations -> NSPasteboardItem in
        let item = NSPasteboardItem()
        for representation in representations {
            guard item.setData(representation.data, forType: .init(representation.type)) else {
                throw ProbeError.restore
            }
        }
        return item
    }
    guard board.changeCount == expected else { throw ProbeError.stale }
    let generation = board.clearContents()
    guard board.changeCount == generation else { throw ProbeError.changed }
    guard items.isEmpty || board.writeObjects(items) else { throw ProbeError.restore }
    guard board.changeCount == generation else { throw ProbeError.changed }
    let actual = try capture(board)
    guard actual.changeCount == generation, differences(snapshot, actual).isEmpty else {
        throw ProbeError.restore
    }
    guard board.changeCount == generation else { throw ProbeError.changed }
    // 성공·실패 어느 경로에서도 스냅샷 파일을 삭제하지 않는다.
    return generation
}

private func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

private struct Inspection: Encodable {
    struct TypeLength: Encodable { let type: String; let byteLength: Int }
    let itemCount: Int
    let items: [[TypeLength]]
}

private func main() throws -> Int32 {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else { throw ProbeError.usage }
    switch command {
    case "capture":
        guard arguments.count == 3, !arguments[1].isEmpty else { throw ProbeError.usage }
        FileHandle.standardError.write(Data("스냅샷에는 개인정보 원문이 포함됩니다. 저장소 밖 비공개 임시 경로를 사용하십시오.\n".utf8))
        let target = board(named: arguments[1])
        let snapshot = try capture(target)
        try save(snapshot, to: arguments[2], board: target)
        print("captured changeCount=\(snapshot.changeCount)")
    case "compare":
        guard arguments.count == 3, !arguments[1].isEmpty else { throw ProbeError.usage }
        let expected = try load(arguments[2])
        let actual = try capture(board(named: arguments[1]))
        let result = differences(expected, actual)
        if result.isEmpty { print("equal") }
        else { try printJSON(result); return 1 }
    case "inspect":
        guard arguments.count == 2, !arguments[1].isEmpty else { throw ProbeError.usage }
        let snapshot = try capture(board(named: arguments[1]))
        try printJSON(Inspection(itemCount: snapshot.items.count, items: snapshot.items.map {
            $0.map { Inspection.TypeLength(type: $0.type, byteLength: $0.data.count) }
        }))
    case "types":
        guard arguments.count == 2, !arguments[1].isEmpty else { throw ProbeError.usage }
        let target = board(named: arguments[1])
        let generation = target.changeCount
        let items: [NSPasteboardItem]
        if let available = target.pasteboardItems {
            items = available
        } else {
            guard target.types?.isEmpty != false else { throw ProbeError.unreadable }
            items = []
        }
        let values = items.map { $0.types.map(\.rawValue) }
        guard target.changeCount == generation else { throw ProbeError.changed }
        // 데이터 공급자를 요청하지 않는 조사 경로다. 파일 약속과 iCloud 입력에 먼저 사용한다.
        try printJSON(values)
    case "restore":
        guard arguments.count == 4, !arguments[1].isEmpty,
              let expected = Int(arguments[3]), expected >= 0 else { throw ProbeError.usage }
        let snapshot = try load(arguments[2])
        let generation = try restore(snapshot, to: board(named: arguments[1]), expected: expected)
        print("restored changeCount=\(generation)")
    default: throw ProbeError.usage
    }
    return 0
}

do {
    exit(try main())
} catch {
    let message = (error as? ProbeError)?.rawValue ?? "처리에 실패했습니다."
    FileHandle.standardError.write(Data((message + "\n").utf8))
    if let failure = error as? ProbeError, failure == .usage {
        FileHandle.standardError.write(Data("사용법: capture <boardName|general|drag> <snapshotFile> | compare <board> <file> | inspect <board> | types <board> | restore <board> <file> <expectedChangeCount>\n".utf8))
    }
    exit(2)
}

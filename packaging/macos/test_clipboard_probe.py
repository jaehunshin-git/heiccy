"""독립 실행: python3 packaging/macos/test_clipboard_probe.py

Python 표준 라이브러리와 macOS Swift 컴파일러만 사용한다. 모든 데이터·실행 파일은
저장소 밖 임시 폴더에 만들며 UUID named pasteboard만 접근한다. 일반/drag 보드와
앱·Photos 보관함에는 접근하지 않는다. 공급자·probe는 서로 다른 프로세스다.
"""

import hashlib
import json
import select
import stat
import subprocess
import sys
import tempfile
import unittest
import uuid
from pathlib import Path

FIXTURE_SWIFT = r'''
import AppKit
import Darwin
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 3, arguments[1].hasPrefix("heic-probe-test-") else { exit(2) }
let operation = arguments[0]
let board = NSPasteboard(name: .init(arguments[1]))
let marker = arguments[2]

final class Provider: NSObject, NSPasteboardItemDataProvider {
    let board: NSPasteboard
    let changes: Bool
    let marker: String
    init(_ board: NSPasteboard, changes: Bool, marker: String) {
        self.board = board; self.changes = changes; self.marker = marker
    }
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        // types가 공급자를 요청하면 원문 대신 호출 여부만 기록한다.
        FileManager.default.createFile(atPath: marker, contents: Data([1]))
        if changes {
            board.clearContents()
            board.setString("SYNTHETIC-EXTERNAL-COPY", forType: .string)
            item.setData(Data("SYNTHETIC-DELAYED".utf8), forType: type)
        }
    }
}

if operation == "release" { board.releaseGlobally(); exit(0) }
board.clearContents()
if operation == "empty" { print(board.changeCount); exit(0) }
if operation == "unreadable" || operation == "changed" {
    let provider = Provider(board, changes: operation == "changed", marker: marker)
    let item = NSPasteboardItem()
    item.setDataProvider(provider, forTypes: [.init("test.delayed")])
    guard board.writeObjects([item]) else { exit(3) }
    print(board.changeCount); fflush(stdout)
    withExtendedLifetime(provider) { RunLoop.current.run(until: Date().addingTimeInterval(60)) }
    exit(0)
}
guard ["seed", "reverse", "mismatch"].contains(operation) else { exit(2) }
let item = NSPasteboardItem()
// 각 프로세스에서 같은 바이트를 사용하고 사전의 직렬화 순서에 의존하지 않는다.
let asset = Data("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>mediaType</key><integer>1</integer><key>localIdentifier</key><string>SYNTHETIC-PRIVATE-ASSET-ID</string></dict></plist>".utf8)
let entries: [(NSPasteboard.PasteboardType, Data)] = [
    (.string, Data((operation == "mismatch" ? "SYNTHETIC-CHANGED-TEXT" : "SYNTHETIC-PRIVATE-TEXT").utf8)),
    (.fileURL, Data("file:///private/tmp/SYNTHETIC-PRIVATE-URL.heic".utf8)),
    (.init("com.apple.photos.object-reference.asset"), asset),
    (.init("test.bytes"), Data([0, 1, 128, 255]))
]
for (type, data) in (operation == "reverse" ? Array(entries.reversed()) : entries) {
    if operation != "mismatch" || type != .init("test.bytes") { item.setData(data, forType: type) }
}
if operation == "mismatch" { item.setData(Data([9]), forType: .init("test.extra")) }
let second = NSPasteboardItem()
second.setData(Data([4, 0, 255]), forType: .init("test.second"))
guard board.writeObjects([item, second]) else { exit(3) }
print(board.changeCount)
'''

# 실제 named board의 선언 타입은 유지하고 항목 조회만 실패시키는 오류 주입이다.
# 원본 Swift 파일을 변경하지 않고 임시 복사본 앞에 붙여 별도 실행 파일을 컴파일한다.
UNAVAILABLE_ITEMS_SWIFT = r'''
import AppKit
import ObjectiveC

extension NSPasteboard {
    @objc func probeUnavailableItems() -> [NSPasteboardItem]? { nil }
}
let originalItemsMethod = class_getInstanceMethod(NSPasteboard.self, NSSelectorFromString("pasteboardItems"))!
let unavailableItemsMethod = class_getInstanceMethod(NSPasteboard.self, #selector(NSPasteboard.probeUnavailableItems))!
method_exchangeImplementations(originalItemsMethod, unavailableItemsMethod)
'''


@unittest.skipUnless(sys.platform == "darwin", "macOS AppKit이 필요합니다.")
class ClipboardProbeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="heic-clipboard-probe-tests-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.root = Path(cls.temporary.name)
        source = Path(__file__).with_name("clipboard_probe.swift")
        fixture_source = cls.root / "fixture.swift"
        fixture_source.write_text(FIXTURE_SWIFT, encoding="utf-8")
        unavailable_source = cls.root / "unavailable.swift"
        unavailable_source.write_text(
            UNAVAILABLE_ITEMS_SWIFT + source.read_text(encoding="utf-8"), encoding="utf-8"
        )
        cls.probe = cls.root / "clipboard_probe"
        cls.fixture = cls.root / "fixture"
        cls.unavailable_probe = cls.root / "unavailable_probe"
        for swift_source, executable in (
            (source, cls.probe), (fixture_source, cls.fixture),
            (unavailable_source, cls.unavailable_probe),
        ):
            result = subprocess.run(
                ["xcrun", "swiftc", "-module-cache-path", str(cls.root / "module-cache"),
                 str(swift_source), "-o", str(executable)],
                capture_output=True, text=True, timeout=120, check=False,
            )
            if result.returncode:
                raise RuntimeError("독립 Swift 컴파일 실패:\n" + result.stderr)

    def setUp(self):
        self.board = "heic-probe-test-" + uuid.uuid4().hex
        self.folder = self.root / self.board
        self.folder.mkdir(mode=0o700)
        self.marker = self.folder / "provider-requested"
        self.snapshot = self.folder / "snapshot.json"
        self.addCleanup(self.seed, "release")

    def run_command(self, executable, *arguments, status=0):
        # 모든 호출이 테스트 전용 named board를 사용해야 한다.
        self.assertGreaterEqual(len(arguments), 2)
        self.assertEqual(arguments[1], self.board)
        self.assertTrue(self.board.startswith("heic-probe-test-"))
        result = subprocess.run(
            [str(executable), *map(str, arguments)], capture_output=True,
            text=True, timeout=15, check=False,
        )
        output = result.stdout + result.stderr
        for private in (
            "SYNTHETIC-PRIVATE", "SYNTHETIC-CHANGED", "SYNTHETIC-EXTERNAL",
            "SYNTHETIC-DELAYED", "file:///private/tmp/",
        ):
            self.assertNotIn(private, output, "원문이 출력되었습니다.")
        self.assertEqual(result.returncode, status, f"명령 {arguments[0]} 실패: {output}")
        return result

    def seed(self, operation="seed"):
        result = self.run_command(self.fixture, operation, self.board, self.marker)
        return int(result.stdout) if operation != "release" else None

    def probe_command(self, operation, *arguments, status=0, unavailable=False):
        executable = self.unavailable_probe if unavailable else self.probe
        return self.run_command(executable, operation, self.board, *arguments, status=status)

    @staticmethod
    def digest(path):
        return hashlib.sha256(path.read_bytes()).digest()

    def captured(self):
        generation = self.seed()
        result = self.probe_command("capture", self.snapshot)
        self.assertEqual(result.stdout.strip(), f"captured changeCount={generation}")
        return generation

    def assert_equal(self, snapshot=None):
        result = self.probe_command("compare", snapshot or self.snapshot)
        self.assertEqual(result.stdout.strip(), "equal")

    def provider(self, operation):
        process = subprocess.Popen(
            [str(self.fixture), operation, self.board, str(self.marker)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )

        def finish():
            if process.poll() is None:
                process.terminate()
            try:
                process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.communicate(timeout=5)

        self.addCleanup(finish)
        self.assertTrue(select.select([process.stdout], [], [], 10)[0], "공급자 준비 시간 초과")
        self.assertTrue(process.stdout.readline().strip().isdigit(), "공급자 준비 실패")
        return process

    def test_01_inspect_does_not_print_original_data(self):
        """inspect는 타입·길이·항목수만 출력한다."""
        self.seed()
        view = json.loads(self.probe_command("inspect").stdout)
        self.assertEqual(set(view), {"itemCount", "items"})
        self.assertEqual(view["itemCount"], 2)
        self.assertEqual(len(view["items"][0]), 4)
        for item in view["items"]:
            for representation in item:
                self.assertEqual(set(representation), {"type", "byteLength"})

    def test_02_capture_after_supplier_exit_has_private_permissions(self):
        """공급 프로세스 종료 후 캡처하며 스냅샷 권한은 0600이다."""
        self.captured()
        self.assertEqual(stat.S_IMODE(self.snapshot.stat().st_mode), 0o600)
        snapshot = json.loads(self.snapshot.read_text())
        self.assertEqual(len(snapshot["items"]), 2)
        self.assertEqual(len(snapshot["items"][0]), 4)

    def test_03_compare_after_capture_process_exit(self):
        """캡처 프로세스 종료 후 별도 프로세스에서 비교한다."""
        self.captured()
        self.assert_equal()

    def test_04_generation_and_type_order_do_not_affect_equality(self):
        """세대와 한 항목 안의 타입 나열 순서는 동일성 조건이 아니다."""
        old = self.captured()
        self.assertNotEqual(self.seed("reverse"), old)
        self.assert_equal()

    def test_05_existing_snapshot_is_never_overwritten(self):
        """기존 스냅샷을 덮어쓰지 않고 임시 파일도 정리한다."""
        self.captured()
        before = self.digest(self.snapshot)
        self.seed("mismatch")
        self.probe_command("capture", self.snapshot, status=2)
        self.assertEqual(self.digest(self.snapshot), before)
        self.assertFalse(list(self.folder.glob(".clipboard-probe-*")))
        self.assertEqual(stat.S_IMODE(self.snapshot.stat().st_mode), 0o600)

    def test_06_compare_prints_only_missing_or_mismatched_types(self):
        """누락·변경·추가 표현의 타입만 출력한다."""
        self.captured()
        self.seed("mismatch")
        result = self.probe_command("compare", self.snapshot, status=1)
        self.assertEqual(json.loads(result.stdout), [{
            "item": 0, "missingTypes": ["test.bytes"],
            "mismatchedTypes": ["public.utf8-plain-text", "test.extra"],
        }])

    def test_07_stale_restore_preserves_board_generation_and_file(self):
        """오래된 세대의 복구는 현재 내용·세대·스냅샷을 유지한다."""
        stale = self.captured()
        self.seed("mismatch")
        current = self.folder / "current.json"
        self.probe_command("capture", current)
        before = self.digest(self.snapshot)
        self.probe_command("restore", self.snapshot, stale, status=2)
        self.assert_equal(current)
        after = self.folder / "after.json"
        self.probe_command("capture", after)
        self.assertEqual(json.loads(current.read_text()), json.loads(after.read_text()))
        self.assertEqual(self.digest(self.snapshot), before)

    def test_08_restore_survives_process_exit_and_keeps_snapshot(self):
        """복구 프로세스 종료 후 전체 타입·바이트를 비교하고 스냅샷을 유지한다."""
        self.captured()
        before = self.digest(self.snapshot)
        current = self.seed("mismatch")
        result = self.probe_command("restore", self.snapshot, current)
        self.assertTrue(result.stdout.startswith("restored changeCount="))
        self.assert_equal()
        self.assertEqual(self.digest(self.snapshot), before)

    def test_09_invalid_snapshot_never_changes_board(self):
        """손상 스냅샷은 쓰기 전에 거절하며 보드와 파일을 유지한다."""
        current = self.captured()
        invalid = self.folder / "invalid.json"
        invalid.write_text("SYNTHETIC-PRIVATE-INVALID")
        before = self.digest(invalid)
        self.probe_command("restore", invalid, current, status=2)
        self.assert_equal()
        self.assertEqual(self.digest(invalid), before)

    def test_10_empty_board_capture_compare_and_restore(self):
        """빈 보드의 캡처·비교·복구·types를 지원한다."""
        self.seed("empty")
        self.probe_command("capture", self.snapshot)
        self.assert_equal()
        current = self.seed()
        self.probe_command("restore", self.snapshot, current)
        self.assertEqual(json.loads(self.probe_command("inspect").stdout), {"itemCount": 0, "items": []})
        self.assertEqual(json.loads(self.probe_command("types").stdout), [])

    def test_11_unreadable_capture_saves_nothing(self):
        """공급자가 바이트를 주지 않으면 부분 스냅샷을 저장하지 않는다."""
        self.provider("unreadable")
        self.probe_command("capture", self.snapshot, status=2)
        self.assertTrue(self.marker.exists())
        self.assertFalse(self.snapshot.exists())
        self.assertFalse(list(self.folder.glob(".clipboard-probe-*")))

    def test_12_change_during_capture_saves_nothing(self):
        """공급자 호출 중 세대가 바뀌면 스냅샷을 저장하지 않는다."""
        self.provider("changed")
        self.probe_command("capture", self.snapshot, status=2)
        self.assertTrue(self.marker.exists())
        self.assertFalse(self.snapshot.exists())
        self.assertFalse(list(self.folder.glob(".clipboard-probe-*")))

    def test_13_types_never_requests_provider_data(self):
        """types는 공급자를 호출하지 않고 타입 이름만 읽는다."""
        self.provider("unreadable")
        self.assertEqual(json.loads(self.probe_command("types").stdout), [["test.delayed"]])
        self.assertFalse(self.marker.exists())
        # 같은 공급자가 capture에는 호출됨을 확인해 계측 자체도 검증한다.
        self.probe_command("capture", self.snapshot, status=2)
        self.assertTrue(self.marker.exists())

    def test_14_nil_items_with_declared_types_is_unreadable(self):
        """항목 조회 실패를 빈 보드로 간주하지 않으며 공급자도 호출하지 않는다."""
        self.provider("unreadable")
        result = self.probe_command("types", status=2, unavailable=True)
        self.assertIn("모든 항목과 타입의 바이트를 읽지 못했습니다.", result.stderr)
        self.assertFalse(self.marker.exists())
        self.probe_command("capture", self.snapshot, status=2, unavailable=True)
        self.assertFalse(self.snapshot.exists())
        self.assertFalse(self.marker.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)

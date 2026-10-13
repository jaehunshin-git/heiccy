"""일반 LaunchServices 실행 두 번의 패널 검사와 정상 종료를 확인한다.

사용법: python3 packaging/macos/test_panel_startup.py '/경로/heiccy.app'
Python 표준 라이브러리와 macOS 기본 open·ps만 사용한다. 프로세스 조회는
CFBundleExecutable과 실행파일명을 정확히 비교하고 zombie를 제외한다.
다른 번들이어도 실행파일명이 같으면 보수적으로 차단하며 기존 앱을 조작하지 않는다.
내부 합성 control dispatch는 OS 메뉴바 최초 클릭의 활성화 전환과 동등하지 않다.
실제 메뉴바 클릭의 cold-start 회귀는 별도 사용자 실기로 확인해야 한다.
"""

import argparse
import plistlib
import re
import subprocess
import sys
import tempfile
from pathlib import Path

TIMEOUT = 30
PREFIX = "시작 패널 검증"
PID_PATTERN = re.compile(r"시작 패널 검증 PID: ([1-9][0-9]*)")
CHECK_PATTERN = re.compile(r"시작 패널 검증 \[([^\]\r\n]+)\]: (성공|실패)")
TERMINATION_CHECK = ("정상 종료 완료", "성공")
REQUIRED_LABELS = frozenset({
    "시작 시 숨김·클릭 전",
    "첫 좌클릭 핸들러 도달",
    "첫 좌클릭 표시·활성화·key",
    "첫 표시 유지",
    "두 번째 좌클릭 핸들러 도달",
    "두 번째 좌클릭 숨김",
    "숨김 후 다시 열리지 않음",
    "세 번째 좌클릭 핸들러 도달",
    "세 번째 좌클릭 다시 표시",
    "외부 앱 이동 시 닫힘",
    "재활성화 완료",
    "재활성화 시 숨김 유지",
    "정상 종료 완료",
})


def require_not_running(executable_name: str) -> None:
    """실행파일명이 같은 비zombie 프로세스가 있거나 조회가 불확실하면 중단한다."""
    result = subprocess.run(
        ["/bin/ps", "-axo", "pid=,stat=,comm="],
        capture_output=True, text=True, timeout=10, check=False,
    )
    if result.returncode:
        raise RuntimeError("프로세스 목록 조회 실패: 기존 앱을 종료하지 않습니다.")
    pids = []
    for line in result.stdout.splitlines():
        if not line.strip():
            continue
        fields = line.split(maxsplit=2)
        if len(fields) != 3 or not fields[0].isdigit() or int(fields[0]) <= 0:
            raise RuntimeError("프로세스 목록의 형식이 올바르지 않습니다.")
        pid, status, command = fields
        if not status.startswith("Z") and Path(command).name == executable_name:
            pids.append(int(pid))
    if pids:
        raise RuntimeError(
            f"실행파일명이 같은 프로세스가 실행 중입니다(PID: {', '.join(map(str, pids))}). "
            "기존 앱을 종료하거나 다시 열지 않습니다."
        )


def read_log(path: Path) -> str:
    """앱 로그가 생성되기 전의 실패도 처리한다."""
    return path.read_text(encoding="utf-8", errors="replace") if path.exists() else ""


def report_protocol(stdout: str, stderr: str, iteration: int) -> None:
    """정해진 검사 행만 출력하고 리소스 경로나 클립보드 원문은 출력하지 않는다."""
    print(f"일반 실행 {iteration} 검사 로그:", flush=True)
    for line in stdout.splitlines():
        if PID_PATTERN.fullmatch(line) or CHECK_PATTERN.fullmatch(line):
            print(line, flush=True)
    if stderr:
        print("앱 stderr가 기록됐습니다(원문 출력 생략).", file=sys.stderr, flush=True)


def validate_protocol(stdout: str, stderr: str) -> int:
    """검사 실패·잘못된 프로토콜·누락된 정상 종료를 거절하고 PID를 반환한다."""
    if "실패" in stdout or "실패" in stderr:
        raise RuntimeError("앱 로그에 실패가 기록됐습니다.")
    pids = []
    checks = []
    for line in stdout.splitlines():
        if match := PID_PATTERN.fullmatch(line):
            pids.append(int(match[1]))
        elif match := CHECK_PATTERN.fullmatch(line):
            checks.append((match[1], match[2]))
        elif line.startswith(PREFIX):
            raise RuntimeError("시작 패널 검사 로그의 형식이 올바르지 않습니다.")
    if len(pids) != 1:
        raise RuntimeError("각 실행에는 유효한 PID 행이 정확히 하나 필요합니다.")
    if checks.count(TERMINATION_CHECK) != 1:
        raise RuntimeError("정상 종료 완료 성공 marker가 없거나 중복됐습니다.")
    missing = REQUIRED_LABELS - {label for label, _ in checks}
    if missing:
        raise RuntimeError(f"필수 패널 검사 누락: {', '.join(sorted(missing))}")
    if checks[-1] != TERMINATION_CHECK:
        raise RuntimeError("마지막 정상 종료 완료 marker가 없습니다.")
    return pids[0]


def run_once(app: Path, executable_name: str, root: Path, iteration: int) -> int:
    """기존 인스턴스가 없는 상태에서 일반 실행 한 번을 최대 30초 기다린다."""
    require_not_running(executable_name)
    stdout_path = root / f"launch-{iteration}.log"
    stderr_path = root / f"launch-{iteration}.err"
    command = [
        "/usr/bin/open", "--wait-apps",
        "--stdout", str(stdout_path), "--stderr", str(stderr_path),
        str(app), "--args", "--panel-startup-test",
    ]
    try:
        result = subprocess.run(
            command, capture_output=True, text=True, timeout=TIMEOUT, check=False,
        )
    except subprocess.TimeoutExpired as error:
        report_protocol(read_log(stdout_path), read_log(stderr_path), iteration)
        # subprocess는 자신이 시작한 open만 정리한다. 앱에는 신호를 보내지 않는다.
        raise RuntimeError(
            f"일반 실행 {iteration}이 {TIMEOUT}초를 초과했습니다. "
            "앱 자동 종료를 요청하지 않았으며 다음 실행을 중단합니다."
        ) from error
    stdout, stderr = read_log(stdout_path), read_log(stderr_path)
    report_protocol(stdout, stderr, iteration)
    if result.returncode:
        raise RuntimeError(f"일반 실행 {iteration}의 open 종료 코드: {result.returncode}")
    if "실패" in result.stdout or "실패" in result.stderr:
        raise RuntimeError("LaunchServices 실행 로그에 실패가 기록됐습니다.")
    pid = validate_protocol(stdout, stderr)
    # 종료 marker만으로 프로세스 종료를 대신 판정하지 않는다.
    require_not_running(executable_name)
    return pid


def main() -> int:
    """앱 번들을 확인하고 같은 번들의 서로 다른 두 프로세스를 검사한다."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, help="검사할 앱 번들 경로")
    arguments = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("macOS의 로그인된 GUI 세션이 필요합니다.")
    try:
        app = arguments.app.resolve(strict=True)
        if not app.is_dir() or app.suffix != ".app":
            raise ValueError("앱 번들 디렉터리가 필요합니다.")
        with (app / "Contents/Info.plist").open("rb") as source:
            info = plistlib.load(source)
        if not isinstance(info, dict):
            raise ValueError("앱 Info.plist가 사전 형식이 아닙니다.")
        executable_name = info.get("CFBundleExecutable")
        if (not isinstance(executable_name, str) or not executable_name
                or executable_name in {".", ".."}
                or Path(executable_name).name != executable_name):
            raise ValueError("앱 실행파일명이 없거나 올바르지 않습니다.")
        with tempfile.TemporaryDirectory(prefix="heic-panel-startup-") as temporary:
            root = Path(temporary)
            first = run_once(app, executable_name, root, 1)
            second = run_once(app, executable_name, root, 2)
            if first == second:
                raise RuntimeError("두 실행의 PID가 같습니다. 새 프로세스 실행을 확인하지 못했습니다.")
        print(f"시작 패널 재실행 검증: 성공 (PID {first} → {second})", flush=True)
        return 0
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError,
            plistlib.InvalidFileException) as error:
        # 파일 관련 예외에는 경로가 포함될 수 있어 원문을 출력하지 않는다.
        detail = str(error) if isinstance(error, RuntimeError) else type(error).__name__
        print(f"시작 패널 재실행 검증: 실패 · {detail}", file=sys.stderr, flush=True)
        return 1


if __name__ == "__main__":
    sys.exit(main())

"""Resource busy 생성 실패만 제한적으로 재시도하고 진단 출력을 보존합니다."""

import shlex
import subprocess
import sys
import time
from pathlib import Path


def remove_partial(output: Path) -> None:
    """이번 생성 명령에 지정한 일반 파일만 정리합니다."""
    if output.is_symlink() or (output.exists() and not output.is_file()):
        raise ValueError(f"불완전한 DMG 경로가 일반 파일이 아닙니다: {output}")
    output.unlink(missing_ok=True)


def log_output(stdout: bytes | None, stderr: bytes | None) -> None:
    for name, contents in (("stdout", stdout), ("stderr", stderr)):
        print(
            f"hdiutil {name}:\n"
            f"{(contents or b'').decode('utf-8', errors='replace') or '(출력 없음)'}",
            file=sys.stderr,
            flush=True,
        )


def create_dmg(staging: Path, output: Path) -> None:
    """HFS+/UDZO 이미지를 생성하며 같은 오류에만 최대 세 번 시도합니다."""
    if output.exists() or output.is_symlink():
        raise ValueError(f"기존 DMG 경로를 덮어쓸 수 없습니다: {output}")
    command = [
        "hdiutil",
        "create",
        "-verbose",
        "-volname",
        "heiccy",
        "-srcfolder",
        str(staging),
        "-fs",
        "HFS+",
        "-format",
        "UDZO",
        str(output),
    ]
    for attempt in range(1, 4):
        print(
            f"DMG 생성 시도 {attempt}/3: {shlex.join(command)}",
            file=sys.stderr,
            flush=True,
        )
        try:
            result = subprocess.run(
                command,
                check=False,
                capture_output=True,
                timeout=300,
            )
        except subprocess.TimeoutExpired as error:
            print(
                "DMG 생성 300초 제한 초과: 재시도 없이 중단",
                file=sys.stderr,
                flush=True,
            )
            log_output(error.stdout, error.stderr)
            remove_partial(output)
            raise
        print(f"DMG 생성 종료 코드: {result.returncode}", file=sys.stderr, flush=True)
        log_output(result.stdout, result.stderr)
        if result.returncode == 0:
            return
        remove_partial(output)
        # verbose 로그 중간의 문자열이 아니라 최종 실패 진단만 재시도 대상으로 사용.
        errors = [
            line.strip()
            for line in result.stderr.decode("utf-8", errors="replace").splitlines()
            if line.strip()
        ]
        busy = bool(errors) and errors[-1] == "hdiutil: create failed - Resource busy"
        if not busy or attempt == 3:
            result.check_returncode()
        print(
            "Resource busy: 불완전한 DMG 정리 후 2초 뒤 재시도",
            file=sys.stderr,
            flush=True,
        )
        time.sleep(2)


if __name__ == "__main__":
    create_dmg(Path(sys.argv[1]), Path(sys.argv[2]))

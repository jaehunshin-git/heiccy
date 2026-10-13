"""Swift 도구가 추가한 개발 도구 절대 RPATH를 배포 실행 파일에서 제거합니다."""

import re
import subprocess
import sys
from pathlib import Path

from sign_app import is_macho


def main() -> None:
    app = Path(sys.argv[1]).resolve()
    for path in app.rglob("*"):
        if not is_macho(path):
            continue
        commands = subprocess.check_output(["otool", "-l", str(path)], text=True)
        paths = re.findall(
            r"cmd LC_RPATH\s+cmdsize \d+\s+path (.+?) \(offset", commands
        )
        for rpath in paths:
            if rpath.startswith("/") and not rpath.startswith(
                ("/usr/lib", "/System/Library")
            ):
                subprocess.run(
                    ["install_name_tool", "-delete_rpath", rpath, str(path)],
                    check=True,
                    capture_output=True,
                )


if __name__ == "__main__":
    main()

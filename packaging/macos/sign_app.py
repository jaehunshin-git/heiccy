"""모든 Mach-O 실행 코드와 중첩 프레임워크를 안쪽부터 ad-hoc 서명합니다."""

import subprocess
import sys
from pathlib import Path

MACHO_MAGIC = {
    b"\xfe\xed\xfa\xce",
    b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf",
    b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf",
    b"\xbf\xba\xfe\xca",
}


def is_macho(path: Path) -> bool:
    if path.is_symlink() or not path.is_file():
        return False
    with path.open("rb") as source:
        return source.read(4) in MACHO_MAGIC


def main() -> None:
    app = Path(sys.argv[1]).resolve()
    files = sorted(
        (path for path in app.rglob("*") if is_macho(path)),
        key=lambda path: len(path.parts),
        reverse=True,
    )
    for path in files:
        subprocess.run(
            ["codesign", "--force", "--sign", "-", "--timestamp=none", str(path)],
            check=True,
            capture_output=True,
        )
    frameworks = sorted(
        app.rglob("*.framework"), key=lambda path: len(path.parts), reverse=True
    )
    for path in [*frameworks, app]:
        subprocess.run(
            ["codesign", "--force", "--sign", "-", "--timestamp=none", str(path)],
            check=True,
            capture_output=True,
        )
    print(
        f"Mach-O {len(files)}개, 프레임워크 {len(frameworks)}개와 앱 ad-hoc 서명 완료"
    )


if __name__ == "__main__":
    main()

"""Swift 네이티브 앱의 MIT 라이선스와 시스템 프레임워크 고지를 수집한다."""

import sys
from pathlib import Path

PROJECT_LICENSE = "HEIC-Converter-MIT.txt"
NOTICE_FILE = "THIRD-PARTY-NOTICES.txt"
NATIVE_NOTICE = """heiccy 네이티브 macOS 앱 라이선스 고지

heiccy 앱과 heic-worker는 프로젝트의 MIT License를 따릅니다.
저작권 고지와 라이선스 전문은 HEIC-Converter-MIT.txt에 있습니다.

앱은 macOS가 제공하는 Apple 시스템 프레임워크와 시스템 라이브러리
(Swift, zlib 등)를 사용합니다. 이미지 변환은 ImageIO·CoreGraphics·Core Image를 사용합니다.
이 시스템 구성 요소는 macOS에서 로드하며 앱 번들에 재배포하지 않습니다.
시스템 구성 요소에는 각 구성 요소의 해당 이용 조건이 적용됩니다.

앱 번들에는 제3자 라이브러리를 포함하지 않습니다.
Python 런타임, Pillow, pillow-heif, PyObjC, PyInstaller 및
libheif, libde265, x265 등의 별도 코덱을 포함하지 않습니다.
이 고지는 네이티브 앱에만 적용되며 별도 PyPI 배포의 의존성과 구분됩니다.
"""


def collect(destination: Path) -> None:
    """설치된 Python 패키지 조회 없이 앱에 필요한 두 고지만 작성한다."""
    if destination.is_symlink():
        raise ValueError("라이선스 경로는 링크가 아닌 디렉터리여야 합니다.")
    destination.mkdir(parents=True, exist_ok=True)
    allowed = {PROJECT_LICENSE, NOTICE_FILE}
    for path in destination.iterdir():
        if path.name not in allowed or path.is_symlink() or not path.is_file():
            raise ValueError(f"네이티브 앱에 불필요하거나 안전하지 않은 고지: {path}")
    root = Path(__file__).resolve().parents[2]
    (destination / PROJECT_LICENSE).write_bytes((root / "LICENSE").read_bytes())
    (destination / NOTICE_FILE).write_text(NATIVE_NOTICE, encoding="utf-8")


def main() -> None:
    collect(Path(sys.argv[1]))


if __name__ == "__main__":
    main()

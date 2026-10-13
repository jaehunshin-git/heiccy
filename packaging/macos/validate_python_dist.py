"""wheel/sdist 허용 목록, 버전과 영어 PyPI 메타데이터를 확인합니다."""

import email
import re
import sys
import tarfile
import zipfile
from email import policy
from pathlib import Path

# 영문 설명에 인용된 실제 UI 문자열만 허용한다. 코드 블록이나 한국어 문서 링크가
# 있다는 이유로 해당 행 전체를 허용하지 않는다. 새 인용은 이 목록과 검사를 함께 검토한다.
UI_QUOTES = ("“클립보드 감지 켜짐”", "“클립보드 감지 꺼짐”", "`한국어`")
TUI_LANGUAGE_PROMPT = "? Language / 언어 English"
HANGUL = re.compile(
    r"[\u1100-\u11ff\u3130-\u318f\ua960-\ua97f\uac00-\ud7af\ud7b0-\ud7ff]"
)


def metadata(contents: bytes) -> None:
    # Core Metadata의 본문은 UTF-8이다. bytes 기반 email 파서는 charset이 없는
    # 본문의 한글을 대체 문자로 바꾸므로 원문을 먼저 엄격하게 디코딩한다.
    parts = re.split(r"\r?\n\r?\n", contents.decode("utf-8"), maxsplit=1)
    assert len(parts) == 2, "메타데이터에 본문이 없습니다."
    headers, description = parts
    message = email.message_from_string(headers, policy=policy.default)
    assert message["Version"] == "0.3.0"
    summary = message["Summary"] or ""
    assert summary and summary.isascii(), summary
    assert "HEIC" in description and "install" in description.lower()
    korean_lines = []
    for line in description.splitlines():
        remaining = "" if line == TUI_LANGUAGE_PROMPT else line
        for quote in UI_QUOTES:
            remaining = remaining.replace(quote, "")
        if HANGUL.search(remaining):
            korean_lines.append(line)
    assert not korean_lines, korean_lines


def main() -> None:
    directory = Path(sys.argv[1])
    wheels = list(directory.glob("heic_converter_tui-0.3.0-*.whl"))
    sources = list(directory.glob("heic_converter_tui-0.3.0.tar.gz"))
    assert len(wheels) == len(sources) == 1
    forbidden = {
        "input",
        "output",
        ".DS_Store",
        ".git",
        ".venv",
        "macos",
        "packaging",
        "docs",
    }
    with zipfile.ZipFile(wheels[0]) as wheel:
        for name in wheel.namelist():
            path = Path(name)
            assert not (set(path.parts) & forbidden), name
            assert path.parts[0] == "heic_converter" or path.parts[0].endswith(
                ".dist-info"
            ), name
        metadata(
            wheel.read(
                next(name for name in wheel.namelist() if name.endswith("/METADATA"))
            )
        )
    allowed = {
        "src",
        "tests",
        "pyproject.toml",
        "README.pypi.md",
        "LICENSE",
        "PKG-INFO",
        ".gitignore",
    }
    with tarfile.open(sources[0]) as source:
        for item in source.getmembers():
            path = Path(item.name)
            assert len(path.parts) > 1 and path.parts[1] in allowed, item.name
            assert not (set(path.parts) & forbidden), item.name
        info = next(
            item for item in source.getmembers() if item.name.endswith("/PKG-INFO")
        )
        stream = source.extractfile(info)
        assert stream is not None
        metadata(stream.read())
    print("wheel/sdist 버전 0.3.0, 허용 목록과 영어 PyPI 설명 검증 완료")


if __name__ == "__main__":
    main()

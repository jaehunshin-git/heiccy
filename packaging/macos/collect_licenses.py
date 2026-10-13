"""번들에 포함되는 Python 런타임과 의존성의 라이선스 고지 수집입니다."""

import importlib.metadata
import shutil
import sys
from pathlib import Path

RUNTIME_DISTRIBUTIONS = (
    "Pillow",
    "pillow-heif",
    "pyobjc-core",
    "pyobjc-framework-Cocoa",
    "pyobjc-framework-Quartz",
    "pyinstaller",
    "altgraph",
    "macholib",
)

CODEC_SOURCES = (
    (
        "libheif",
        "1.20.2",
        "https://github.com/strukturag/libheif/tree/v1.20.2",
        "https://github.com/strukturag/libheif/tree/v1.18.1",
    ),
    (
        "libde265",
        "1.0.16",
        "https://github.com/strukturag/libde265/tree/v1.0.16",
        "https://github.com/strukturag/libde265/tree/v1.0.15",
    ),
    (
        "x265",
        "4.1+1-1d117be",
        "https://github.com/Multicorewareinc/x265/tree/1d117bed4747758b51bd2c124d738527e30392cb",
        "https://bitbucket.org/multicoreware/x265_git/src/Release_3.4",
    ),
)


def corrected_bundled_notice(contents: str, version: str, info: dict) -> str:
    """고정 wheel의 오래된 링크를 실제 코덱 버전의 공식 소스로 보정한다."""
    expected = {
        "libheif": "1.20.2",
        "HEIF": "x265 HEVC encoder (4.1+1-1d117be)",
        "AVIF": "",
        "encoders": {"x265": "x265 HEVC encoder (4.1+1-1d117be)", "mask": "mask"},
        "decoders": {"libde265": "libde265 HEVC decoder, version 1.0.16"},
    }
    if version != "1.1.1" or info != expected:
        raise RuntimeError(
            f"코덱 소스 고지를 새 wheel과 대조해야 합니다: {version}, {info}"
        )
    for name, codec_version, source, previous in CODEC_SOURCES:
        if contents.count(previous) != 2 or contents.count(f"Name: {name}\n") != 1:
            raise RuntimeError(f"{name}의 upstream 고지 형식이 변경되었습니다.")
        contents = contents.replace(previous, source).replace(
            f"Name: {name}\n", f"Name: {name}\nVersion: {codec_version}\n"
        )
    # 1.1.1에는 AVIF/libaom이 없다. upstream의 이전 wheel용 항목을 제외한다.
    if "\nName: libaom\n" not in contents:
        raise RuntimeError("고정 wheel의 upstream libaom 고지 형식이 변경되었습니다.")
    contents = contents.split("\nName: libaom\n", maxsplit=1)[0].rstrip() + "\n"
    return (
        "heiccy: pillow-heif 1.1.1의 실제 코덱 버전과 공식 소스에 맞게\n"
        "upstream LICENSES_bundled.txt의 버전·소스 링크를 보정했습니다.\n\n" + contents
    )


def main() -> None:
    destination = Path(sys.argv[1])
    notices = ["heiccy 내장 런타임 및 제3자 라이선스 고지\n"]
    for name in RUNTIME_DISTRIBUTIONS:
        package = importlib.metadata.distribution(name)
        notices.append(f"{package.metadata['Name']} {package.version}\n")
        files = package.files or []
        matches = [
            item
            for item in files
            if any(
                token in item.name.lower() for token in ("license", "copying", "notice")
            )
        ]
        bundled_notice_found = False
        for index, item in enumerate(matches):
            source = Path(package.locate_file(item))
            if source.is_file():
                target = destination / f"{name}-{index}-{source.name}"
                if name == "pillow-heif" and source.name == "LICENSES_bundled.txt":
                    from pillow_heif import libheif_info

                    target.write_text(
                        corrected_bundled_notice(
                            source.read_text(encoding="utf-8"),
                            package.version,
                            libheif_info(),
                        ),
                        encoding="utf-8",
                    )
                    bundled_notice_found = True
                else:
                    target.write_bytes(source.read_bytes())
        if name == "pillow-heif" and not bundled_notice_found:
            raise RuntimeError(
                "pillow-heif wheel의 코덱 라이선스 고지를 찾을 수 없습니다."
            )
    supplied = Path(__file__).with_name("licenses")
    for source in supplied.iterdir():
        if source.is_file():
            shutil.copyfile(source, destination / source.name)
    # Python 독립 배포에는 PSF 고지 및 함께 배포된 라이브러리 고지가 포함된다.
    runtime = (
        Path(sys.base_prefix)
        / f"lib/python{sys.version_info.major}.{sys.version_info.minor}"
    )
    for name in ("LICENSE.txt", "LICENSE", "PYTHON.json"):
        source = runtime / name
        if source.is_file() and name != "PYTHON.json":
            (destination / f"Python-{name}").write_bytes(source.read_bytes())
    if not any(destination.glob("Python-LICENSE*")):
        raise RuntimeError("고정 Python 런타임의 라이선스 파일을 찾을 수 없습니다.")
    (destination / "THIRD-PARTY-NOTICES.txt").write_text("\n".join(notices))


if __name__ == "__main__":
    main()

"""앱 허용 목록, 버전, arm64 코드, 로더 경로와 서명을 검증합니다."""

import plistlib
import re
import subprocess
import sys
from pathlib import Path

from sign_app import is_macho


def output(*arguments: str) -> str:
    result = subprocess.run(arguments, check=True, capture_output=True, text=True)
    return result.stdout + result.stderr


def validate(app: Path) -> None:
    app = app.resolve()
    root = Path(__file__).resolve().parents[2]
    # 앱 버전은 Python/PyPI 버전과 독립적으로 관리한다.
    source_info = plistlib.loads((root / "packaging/macos/Info.plist").read_bytes())
    version = source_info["CFBundleShortVersionString"]
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    assert info["CFBundleIdentifier"] == "io.github.jaehunshin-git.heic-converter"
    assert info["CFBundleName"] == info["CFBundleDisplayName"] == "heiccy"
    assert (
        info["CFBundleShortVersionString"]
        == info["CFBundleVersion"]
        == version
        == source_info["CFBundleVersion"]
    )
    assert info["LSMinimumSystemVersion"] == "15.0" and info["LSUIElement"] is True
    allowed = {"Info.plist", "PkgInfo", "MacOS", "Resources", "_CodeSignature"}
    assert {path.name for path in (app / "Contents").iterdir()} <= allowed
    resources = app / "Contents/Resources"
    assert {path.name for path in resources.iterdir()} == {
        "AppIcon.icns",
        "Licenses",
        "worker",
    }
    assert {path.name for path in (app / "Contents/MacOS").iterdir()} == {
        "HEICConverter"
    }
    forbidden = {"input", "output", ".git", ".DS_Store", ".venv", ".venv-app-build"}
    native_count = 0
    bundled_names = {item.name for item in app.rglob("*") if item.is_file()}
    for path in app.rglob("*"):
        assert not (set(path.relative_to(app).parts) & forbidden), path
        if path.is_symlink():
            assert path.resolve().is_relative_to(app), f"번들 밖 심볼릭 링크: {path}"
        if not is_macho(path):
            continue
        native_count += 1
        architecture = output("lipo", "-archs", str(path)).strip()
        assert architecture == "arm64", (path, architecture)
        output("codesign", "--verify", "--strict", str(path))
        signature = output("codesign", "--display", "--verbose=2", str(path))
        assert "Signature=adhoc" in signature, path
        dependencies = output("otool", "-L", str(path)).splitlines()[1:]
        for line in dependencies:
            dependency = line.strip().split(" (", 1)[0]
            assert dependency.startswith(
                (
                    "@rpath/",
                    "@loader_path/",
                    "@executable_path/",
                    "/usr/lib/",
                    "/System/Library/",
                )
            ), (path, dependency)
            if dependency.startswith("@loader_path/"):
                target = path.parent / dependency.removeprefix("@loader_path/")
                assert target.resolve().is_relative_to(app) and target.exists(), (
                    path,
                    target,
                )
            if dependency.startswith("@rpath/"):
                assert Path(dependency).name in bundled_names, (path, dependency)
        load_commands = output("otool", "-l", str(path))
        for minimum in re.findall(
            r"(?:cmd LC_BUILD_VERSION[\s\S]*?minos |cmd LC_VERSION_MIN_MACOSX[\s\S]*?version )(\d+\.\d+(?:\.\d+)?)",
            load_commands,
        ):
            # LC_BUILD_VERSION/LC_VERSION_MIN_MACOSX: 모든 코드의 최소 OS도 확인한다.
            assert tuple(int(part) for part in minimum.split(".")) <= (15, 0, 0), (
                path,
                minimum,
            )
        for match in re.finditer(
            r"cmd LC_RPATH\s+cmdsize \d+\s+path (.+?) \(offset", load_commands
        ):
            rpath = match.group(1)
            assert rpath.startswith(
                ("@loader_path", "@executable_path", "/System/Library", "/usr/lib")
            ), (path, rpath)
    assert native_count > 5, "네이티브 런타임/코덱 누락"
    output("codesign", "--verify", "--deep", "--strict", str(app))
    print(
        f"앱 버전 {version}, Mach-O {native_count}개 arm64/로더 경로/ad-hoc 서명 검증 완료"
    )


if __name__ == "__main__":
    validate(Path(sys.argv[1]))

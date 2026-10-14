"""앱 허용 목록, 버전, arm64 코드, 로더 경로와 서명을 검증합니다."""

import os
import plistlib
import re
import subprocess
import sys
from pathlib import Path

from collect_licenses import NATIVE_NOTICE, NOTICE_FILE, PROJECT_LICENSE
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
    assert info["CFBundleExecutable"] == "HEICConverter"
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
    worker = resources / "worker/heic-worker"
    executable = app / "Contents/MacOS/HEICConverter"
    assert {path.name for path in (resources / "worker").iterdir()} == {
        "heic-worker"
    }, "네이티브 worker 외 런타임/코덱 파일을 포함할 수 없습니다."
    licenses = resources / "Licenses"
    assert {path.name for path in licenses.iterdir()} == {
        PROJECT_LICENSE,
        NOTICE_FILE,
    }, "네이티브 앱 라이선스 고지가 누락되거나 불필요한 고지가 있습니다."
    assert (licenses / PROJECT_LICENSE).read_bytes() == (root / "LICENSE").read_bytes()
    assert (licenses / NOTICE_FILE).read_text(encoding="utf-8") == NATIVE_NOTICE
    native_paths = {executable, worker}
    for path in native_paths:
        assert is_macho(path) and os.access(path, os.X_OK), (
            "실행 가능한 네이티브 Mach-O가 필요합니다.",
            path,
        )
    allowed_directories = {
        "Contents",
        "Contents/MacOS",
        "Contents/Resources",
        "Contents/Resources/worker",
        "Contents/Resources/Licenses",
        "Contents/_CodeSignature",
    }
    allowed_files = {
        "Contents/Info.plist",
        "Contents/PkgInfo",
        "Contents/MacOS/HEICConverter",
        "Contents/Resources/worker/heic-worker",
        "Contents/Resources/AppIcon.icns",
        f"Contents/Resources/Licenses/{PROJECT_LICENSE}",
        f"Contents/Resources/Licenses/{NOTICE_FILE}",
        "Contents/_CodeSignature/CodeResources",
    }
    forbidden = {"input", "output", ".git", ".DS_Store", ".venv", ".venv-app-build"}
    native_count = 0
    for path in app.rglob("*"):
        assert not (set(path.relative_to(app).parts) & forbidden), path
        if path.is_symlink():
            assert path.resolve().is_relative_to(app), f"번들 밖 심볼릭 링크: {path}"
            raise AssertionError(f"네이티브 앱 번들에 심볼릭 링크를 허용하지 않습니다: {path}")
        relative = path.relative_to(app).as_posix()
        assert (path.is_dir() and relative in allowed_directories) or (
            path.is_file() and relative in allowed_files
        ), f"네이티브 앱 허용 목록 밖 파일/런타임/코덱: {path}"
        if not is_macho(path):
            continue
        assert path in native_paths, f"예상하지 못한 실행 코드: {path}"
        native_count += 1
        architecture = output("lipo", "-archs", str(path)).strip()
        assert architecture == "arm64", (path, architecture)
        output("codesign", "--verify", "--strict", str(path))
        signature = output("codesign", "--display", "--verbose=2", str(path))
        assert "Signature=adhoc" in signature, path
        load_commands = output("otool", "-l", str(path))
        rpaths = re.findall(
            r"cmd LC_RPATH\s+cmdsize \d+\s+path (.+?) \(offset", load_commands
        )
        dependencies = output("otool", "-L", str(path)).splitlines()[1:]
        for line in dependencies:
            dependency = line.strip().split(" (", 1)[0]
            assert not any(
                token in dependency.lower()
                for token in (
                    "python",
                    "pillow",
                    "pyobjc",
                    "pyinstaller",
                    "libheif",
                    "libde265",
                    "x265",
                    "libaom",
                )
            ), (path, "Python/별도 런타임/코덱 의존성 금지", dependency)
            assert ".." not in Path(dependency).parts, (path, dependency)
            assert dependency.startswith(
                (
                    "@rpath/",
                    "@loader_path/",
                    "@executable_path/",
                    "/usr/lib/",
                    "/System/Library/",
                )
            ), (path, dependency)
            if dependency.startswith(("@loader_path/", "@executable_path/")):
                prefix, suffix = dependency.split("/", 1)
                base = path.parent if prefix == "@loader_path" else executable.parent
                target = base / suffix
                assert target.resolve().is_relative_to(app) and target.exists(), (
                    path,
                    target,
                )
            if dependency.startswith("@rpath/"):
                # Swift 라이브러리는 macOS의 dyld 공유 캐시에서 로드할 수 있다.
                assert re.fullmatch(r"@rpath/libswift[\w]+\.dylib", dependency), (
                    path,
                    dependency,
                )
                assert "/usr/lib/swift" in rpaths, (path, dependency, rpaths)
        for minimum in re.findall(
            r"(?:cmd LC_BUILD_VERSION[\s\S]*?minos |cmd LC_VERSION_MIN_MACOSX[\s\S]*?version )(\d+\.\d+(?:\.\d+)?)",
            load_commands,
        ):
            # LC_BUILD_VERSION/LC_VERSION_MIN_MACOSX: 모든 코드의 최소 OS도 확인한다.
            assert tuple(int(part) for part in minimum.split(".")) <= (15, 0, 0), (
                path,
                minimum,
            )
        for rpath in rpaths:
            assert ".." not in Path(rpath).parts, (path, rpath)
            if rpath.startswith(("@loader_path", "@executable_path")):
                prefix, _, suffix = rpath.partition("/")
                assert prefix in {"@loader_path", "@executable_path"}, (path, rpath)
                base = path.parent if prefix == "@loader_path" else executable.parent
                target = base / suffix
                assert target.resolve().is_relative_to(app) and target.is_dir(), (
                    path,
                    rpath,
                )
            else:
                assert rpath.startswith(("/System/Library/", "/usr/lib/")), (
                    path,
                    rpath,
                )
    assert native_count == 2, "앱과 네이티브 worker 두 실행 파일이 필요합니다."
    output("codesign", "--verify", "--deep", "--strict", str(app))
    print(
        f"앱 버전 {version}, Mach-O {native_count}개 arm64/로더 경로/ad-hoc 서명 검증 완료"
    )


if __name__ == "__main__":
    validate(Path(sys.argv[1]))

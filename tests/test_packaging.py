"""PyPI 배포 메타데이터와 네이티브 앱 패키징을 검증한다."""

import importlib.util
import io
import os
import plistlib
import subprocess
import sys
import tarfile
import tomllib
import zipfile
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]


def load_script(name):
    path = ROOT / "packaging" / "macos" / f"{name}.py"
    if not path.is_file():
        pytest.skip(
            "sdist에는 macOS 앱 빌드 스크립트가 포함되지 않습니다.",
            allow_module_level=True,
        )
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


validator = load_script("validate_python_dist")
licenses = load_script("collect_licenses")


def package_metadata(body, *, newline="\n", summary="Local HEIC converter"):
    return (
        f"Metadata-Version: 2.4{newline}"
        f"Version: 0.3.0{newline}"
        f"Summary: {summary}{newline}"
        f"Description-Content-Type: text/markdown{newline}{newline}{body}"
    ).encode()


@pytest.mark.parametrize("newline", ["\n", "\r\n"])
def test_pypi_readme_passes_english_metadata_validation(newline):
    validator.metadata(
        package_metadata((ROOT / "README.pypi.md").read_text(), newline=newline)
    )


@pytest.mark.parametrize(
    "body",
    [
        "HEIC install\n한국어로 작성한 설명입니다.",
        "HEIC install\n[README.ko.md](README.ko.md) 한국어 설명",
        "HEIC install\n```text\n한국어 설명\n```",
        "HEIC install\nChoose `한국어` 먼저 선택하세요.",
        "HEIC install\n“클립보드 감지 켜짐” 한국어 설명",
        "HEIC install\n? Language / 언어 English 추가 설명",
        "HEIC install\n한글",
        "HEIC install\nㅎㅏㄴㄱㅡㄹ",
    ],
)
def test_korean_prose_cannot_hide_in_links_quotes_or_code(body):
    with pytest.raises(AssertionError):
        validator.metadata(package_metadata(body))


def test_encoded_korean_summary_is_rejected():
    with pytest.raises(AssertionError):
        validator.metadata(
            package_metadata("HEIC install", summary="=?utf-8?b?7ZWc6riA?=")
        )


def test_invalid_utf8_is_rejected_without_replacement():
    with pytest.raises(UnicodeDecodeError):
        validator.metadata(package_metadata("HEIC install") + b"\xff")


@pytest.mark.parametrize("bad_archive", ["wheel", "sdist"])
def test_archive_entrypoint_rejects_korean_description(
    tmp_path, monkeypatch, bad_archive
):
    english = package_metadata("HEIC install instructions")
    korean = package_metadata("HEIC install\n한국어 설명")
    wheel = tmp_path / "heic_converter_tui-0.3.0-py3-none-any.whl"
    with zipfile.ZipFile(wheel, "w") as archive:
        archive.writestr(
            "heic_converter_tui-0.3.0.dist-info/METADATA",
            korean if bad_archive == "wheel" else english,
        )
    with tarfile.open(tmp_path / "heic_converter_tui-0.3.0.tar.gz", "w:gz") as archive:
        contents = korean if bad_archive == "sdist" else english
        info = tarfile.TarInfo("heic_converter_tui-0.3.0/PKG-INFO")
        info.size = len(contents)
        archive.addfile(info, io.BytesIO(contents))
    monkeypatch.setattr(sys, "argv", ["validate_python_dist.py", str(tmp_path)])
    with pytest.raises(AssertionError):
        validator.main()


def test_native_notices_need_no_installed_runtime_packages(tmp_path, monkeypatch):
    import importlib.metadata

    def unexpected_lookup(*args, **kwargs):
        raise AssertionError("앱 고지 생성에 Python 패키지 조회가 필요하면 안 됩니다.")

    monkeypatch.setattr(importlib.metadata, "distribution", unexpected_lookup)
    destination = tmp_path / "Licenses"
    licenses.collect(destination)
    assert {path.name for path in destination.iterdir()} == {
        "HEIC-Converter-MIT.txt", "THIRD-PARTY-NOTICES.txt"
    }
    assert (destination / licenses.PROJECT_LICENSE).read_bytes() == (
        ROOT / "LICENSE"
    ).read_bytes()
    contents = (destination / licenses.NOTICE_FILE).read_text(encoding="utf-8")
    assert contents == licenses.NATIVE_NOTICE
    assert "MIT License" in contents and "Apple 시스템 프레임워크" in contents
    assert "ImageIO" in contents and "CoreGraphics" in contents
    assert "앱 번들에는 제3자 라이브러리를 포함하지 않습니다." in contents
    assert "Python 런타임" in contents and "포함하지 않습니다." in contents
    # 같은 내용으로 재수집해도 제3자 고지가 추가되면 안 된다.
    before = {path.name: path.read_bytes() for path in destination.iterdir()}
    licenses.collect(destination)
    assert before == {path.name: path.read_bytes() for path in destination.iterdir()}


@pytest.mark.parametrize("name", ["Python-LICENSE.txt", "x265-COPYING", "unexpected"])
def test_native_notice_collection_rejects_stale_runtime_notices(tmp_path, name):
    destination = tmp_path / "Licenses"
    destination.mkdir()
    stale = destination / name
    stale.write_text("preserve")
    with pytest.raises(ValueError, match="불필요"):
        licenses.collect(destination)
    assert stale.read_text() == "preserve"


@pytest.mark.parametrize("linked_directory", [False, True])
def test_native_notice_collection_rejects_symlinks(tmp_path, linked_directory):
    destination = tmp_path / "Licenses"
    outside = tmp_path / "outside"
    outside.mkdir()
    sentinel = outside / licenses.PROJECT_LICENSE
    sentinel.write_text("preserve")
    if linked_directory:
        destination.symlink_to(outside, target_is_directory=True)
    else:
        destination.mkdir()
        (destination / licenses.PROJECT_LICENSE).symlink_to(sentinel)
    with pytest.raises(ValueError):
        licenses.collect(destination)
    assert sentinel.read_text() == "preserve"


@pytest.fixture
def native_app(tmp_path, monkeypatch):
    monkeypatch.syspath_prepend(str(ROOT / "packaging/macos"))
    validation = load_script("validate_app")
    app = tmp_path / "heiccy.app"
    contents = app / "Contents"
    for directory in ("MacOS", "Resources/worker", "Resources/Licenses"):
        (contents / directory).mkdir(parents=True)
    (contents / "Info.plist").write_bytes(
        (ROOT / "packaging/macos/Info.plist").read_bytes()
    )
    (contents / "Resources/AppIcon.icns").write_bytes(b"icon")
    licenses.collect(contents / "Resources/Licenses")
    for name in ("MacOS/HEICConverter", "Resources/worker/heic-worker"):
        path = contents / name
        path.write_bytes(b"\xcf\xfa\xed\xfe" + b"native fixture")
        path.chmod(0o755)
    calls = []

    def output(*arguments):
        calls.append(arguments)
        if arguments[0] == "lipo":
            return "arm64\n"
        if arguments[:2] == ("codesign", "--display"):
            return "Signature=adhoc\n"
        if arguments[:2] == ("otool", "-L"):
            return (
                f"{arguments[-1]}:\n"
                "\t/System/Library/Frameworks/ImageIO.framework/Versions/A/ImageIO (version)\n"
                "\t/usr/lib/libSystem.B.dylib (version)\n"
                "\t@rpath/libswiftCore.dylib (version)\n"
            )
        if arguments[:2] == ("otool", "-l"):
            return (
                "cmd LC_BUILD_VERSION\nminos 15.0\n"
                "cmd LC_RPATH\ncmdsize 32\npath /usr/lib/swift (offset 12)\n"
                "cmd LC_RPATH\ncmdsize 32\npath @loader_path (offset 12)\n"
            )
        assert arguments[0] == "codesign"
        return ""

    monkeypatch.setattr(validation, "output", output)
    return app, validation, calls


def test_native_app_requires_two_signed_arm64_executables(native_app):
    app, validation, calls = native_app
    validation.validate(app)
    expected = {
        str(app / "Contents/MacOS/HEICConverter"),
        str(app / "Contents/Resources/worker/heic-worker"),
    }
    assert {call[-1] for call in calls if call[0] == "lipo"} == expected
    assert {call[-1] for call in calls if call[:2] == ("codesign", "--display")} == expected
    assert ("codesign", "--verify", "--deep", "--strict", str(app)) in calls


@pytest.mark.parametrize(
    "name",
    [
        "Resources/worker/Python.framework/Versions/3.12/Python",
        "Resources/worker/_internal/libpython3.12.dylib",
        "Resources/worker/PIL/__init__.py",
        "Resources/worker/libheif.dylib",
        "Resources/worker/libde265.dylib",
        "Resources/worker/libx265.dylib",
        "Resources/worker/innocent.data",
        "Resources/Licenses/Python-LICENSE.txt",
        "_CodeSignature/hidden.pyc",
        "input/photo.heic",
    ],
)
def test_native_app_rejects_unexpected_runtime_codec_or_private_files(native_app, name):
    app, validation, _ = native_app
    path = app / "Contents" / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"fixture")
    with pytest.raises(AssertionError):
        validation.validate(app)


@pytest.mark.parametrize("change", ["missing", "script", "non-executable", "symlink"])
def test_worker_must_be_real_native_executable(native_app, change):
    app, validation, _ = native_app
    worker = app / "Contents/Resources/worker/heic-worker"
    if change == "missing":
        worker.unlink()
    elif change == "script":
        worker.write_text("#!/usr/bin/python3\n")
    elif change == "non-executable":
        worker.chmod(0o644)
    else:
        worker.unlink()
        worker.symlink_to(app / "Contents/MacOS/HEICConverter")
    with pytest.raises(AssertionError):
        validation.validate(app)


@pytest.mark.parametrize("target", ["Info.plist", "license", "notice", "icon"])
def test_native_app_rejects_wrong_metadata_licenses_and_unexpected_code(native_app, target):
    app, validation, _ = native_app
    contents = app / "Contents"
    if target == "Info.plist":
        path = contents / target
        info = plistlib.loads(path.read_bytes())
        info["CFBundleExecutable"] = "python"
        path.write_bytes(plistlib.dumps(info))
    elif target == "license":
        (contents / "Resources/Licenses" / licenses.PROJECT_LICENSE).write_text("MIT")
    elif target == "notice":
        (contents / "Resources/Licenses" / licenses.NOTICE_FILE).write_text("Python runtime")
    else:
        (contents / "Resources/AppIcon.icns").write_bytes(b"\xcf\xfa\xed\xfe")
    with pytest.raises(AssertionError):
        validation.validate(app)


@pytest.mark.parametrize(
    "tool,response",
    [
        ("lipo", "x86_64"),
        ("lipo", "arm64 x86_64"),
        ("signature", "Signature=Developer ID"),
        ("dependency", "/opt/homebrew/lib/libheif.dylib"),
        ("dependency", "/System/Library/Frameworks/Python.framework/Python"),
        ("dependency", "/usr/lib/libpython3.12.dylib"),
        ("dependency", "/usr/lib/libheif.dylib"),
        ("dependency", "@rpath/libheif.dylib"),
        ("dependency", "@rpath/unknown.dylib"),
        ("dependency", "@loader_path/missing.dylib"),
        ("dependency", "@executable_path/missing.dylib"),
        ("dependency", "/usr/lib/../../opt/hidden.dylib"),
        ("load", "cmd LC_BUILD_VERSION\nminos 15.1\n"),
        ("load", "cmd LC_VERSION_MIN_MACOSX\nversion 16.0\n"),
        ("rpath", "/opt/homebrew/lib"),
        ("rpath", "/usr/library/spoofed"),
        ("rpath", "@loader_path/../../../../outside"),
        ("rpath", "@loader_path-malformed"),
        ("rpath", "/usr/lib/../local/lib"),
        ("load", "cmd LC_BUILD_VERSION\nminos 15.0\n"),
    ],
)
def test_native_app_rejects_unsafe_architecture_signature_and_loader(
    native_app, monkeypatch, tool, response
):
    app, validation, _ = native_app
    original = validation.output
    worker = str(app / "Contents/Resources/worker/heic-worker")

    def output(*arguments):
        result = original(*arguments)
        if arguments[-1] != worker:
            return result
        if tool == "lipo" and arguments[0] == "lipo":
            return response
        if tool == "signature" and arguments[:2] == ("codesign", "--display"):
            return response
        if tool == "dependency" and arguments[:2] == ("otool", "-L"):
            return f"{worker}:\n\t{response} (version)\n"
        if tool in {"load", "rpath"} and arguments[:2] == ("otool", "-l"):
            if tool == "load":
                return response
            return result + f"cmd LC_RPATH\ncmdsize 32\npath {response} (offset 12)\n"
        return result

    monkeypatch.setattr(validation, "output", output)
    with pytest.raises(AssertionError):
        validation.validate(app)


def test_native_app_stops_on_failed_signature_verification(native_app, monkeypatch):
    app, validation, _ = native_app
    original = validation.output

    def output(*arguments):
        if arguments[:2] == ("codesign", "--verify"):
            raise subprocess.CalledProcessError(1, arguments)
        return original(*arguments)

    monkeypatch.setattr(validation, "output", output)
    with pytest.raises(subprocess.CalledProcessError):
        validation.validate(app)


def test_pypi_description_and_sdist_use_dedicated_readme():
    config = tomllib.loads((ROOT / "pyproject.toml").read_text())
    project = config["project"]
    assert project["name"] == "heic-converter-tui"
    assert project["version"] == "0.3.0"
    assert project["scripts"] == {"heic-converter": "heic_converter.cli:run"}
    assert project["readme"] == "README.pypi.md"
    assert project["urls"] == {
        "Repository": "https://github.com/jaehunshin-git/heiccy",
        "Homepage": "https://github.com/jaehunshin-git/heiccy",
        "Issues": "https://github.com/jaehunshin-git/heiccy/issues",
    }
    assert config["tool"]["hatch"]["build"]["targets"]["sdist"]["only-include"] == [
        "src", "tests", "pyproject.toml", "README.pypi.md", "LICENSE",
    ]


def test_pypi_readme_links_to_public_repository_without_app_installation():
    readme = (ROOT / "README.pypi.md").read_text()
    assert "https://github.com/jaehunshin-git/heiccy" in readme
    assert "https://github.com/jaehunshin-git/heic-converter-tui" not in readme
    assert "](LICENSE)" not in readme
    assert "](docs/" not in readme
    assert ".dmg" not in readme.lower()
    assert ".app" not in readme.lower()


@pytest.mark.parametrize("name", ["README.pypi.md", "README.md", "README.ko.md", "input/photo.heic"])
def test_sdist_description_allowlist(tmp_path, monkeypatch, name):
    contents = package_metadata((ROOT / "README.pypi.md").read_text())
    with zipfile.ZipFile(tmp_path / "heic_converter_tui-0.3.0-py3-none-any.whl", "w") as archive:
        archive.writestr("heic_converter_tui-0.3.0.dist-info/METADATA", contents)
    with tarfile.open(tmp_path / "heic_converter_tui-0.3.0.tar.gz", "w:gz") as archive:
        for filename, body in [("PKG-INFO", contents), (name, b"fixture")]:
            info = tarfile.TarInfo(f"heic_converter_tui-0.3.0/{filename}")
            info.size = len(body)
            archive.addfile(info, io.BytesIO(body))
    monkeypatch.setattr(sys, "argv", ["validate_python_dist.py", str(tmp_path)])
    if name == "README.pypi.md":
        validator.main()
    else:
        with pytest.raises(AssertionError):
            validator.main()


@pytest.fixture
def macos_build(tmp_path):
    """실제 산출물은 건드리지 않고 전체 셸 흐름과 실패 중단을 실행한다."""
    root = tmp_path / "공백 있는 저장소"
    packaging = root / "packaging/macos"
    packaging.mkdir(parents=True)
    source = (ROOT / "packaging/macos/build.sh").read_text()
    # 절대 경로의 macOS 도구도 격리된 가짜 실행 파일로 대체한다.
    for command in ("open", "pgrep"):
        source = source.replace(f"/usr/bin/{command}", command)
    source = source.replace("/usr/libexec/PlistBuddy", "PlistBuddy")
    (packaging / "build.sh").write_text(source)
    (packaging / "create_dmg.py").write_text(
        (ROOT / "packaging/macos/create_dmg.py").read_text()
    )
    (packaging / "Info.plist").write_text("fixture")
    (root / "LICENSE").write_text("fixture")
    binary = tmp_path / "bin"
    binary.mkdir()
    log = tmp_path / "commands.log"

    def command(name, body):
        path = binary / name
        path.write_text(f"#!/bin/bash\nset -eu\n{body}\n")
        path.chmod(0o755)

    command("uname", 'if [[ "$1" == -s ]]; then echo Darwin; else echo arm64; fi')
    command("stat", 'id -u')
    command("launchctl", 'exit "${GUI_STATUS:-0}"')
    command("open", 'echo "Finder open" >> "$BUILD_TEST_LOG"')
    command("pgrep", 'echo "Finder ready" >> "$BUILD_TEST_LOG"')
    command("uv", ':')
    command("sw_vers", ':')
    command("PlistBuddy", 'echo 0.3.0')
    command("swift", 'printf "swift %s\\n" "$*" >> "$BUILD_TEST_LOG"\necho "$BUILD_TEST_SWIFT"')
    command("iconutil", 'touch "${@: -1}"')
    command(
        "hdiutil",
        'printf "hdiutil %s\\n" "$*" >> "$BUILD_TEST_LOG"\n'
        'count_file="$BUILD_TEST_LOG.attempts"\n'
        'count=$(cat "$count_file" 2>/dev/null || echo 0)\n'
        'count=$((count + 1)); echo "$count" > "$count_file"\n'
        'if [[ "$count" -le "${DMG_BUSY_ATTEMPTS:-0}" ]]; then\n'
        '  echo partial > "${@: -1}"\n'
        '  echo "hdiutil: create failed - Resource busy" >&2; exit 1\nfi\n'
        'if [[ "${DMG_STATUS:-0}" != 0 ]]; then exit "$DMG_STATUS"; fi\n'
        'touch "${@: -1}"',
    )
    swift = tmp_path / "swift-bin"
    swift.mkdir()
    app = swift / "HEICConverter"
    app.write_text('#!/bin/bash\necho "app smoke $*" >> "$BUILD_TEST_LOG"\n')
    app.chmod(0o755)
    worker = swift / "heic-worker"
    worker.write_text("native worker fixture")
    worker.chmod(0o755)
    environment = root / ".venv-app-build/bin"
    environment.mkdir(parents=True)
    python = environment / "python"
    python.write_text(
        '#!/bin/bash\nset -eu\n'
        'if [[ "$1" == -c || "$1" == -m ]]; then exit 0; fi\n'
        'if [[ "$1" == packaging/macos/create_dmg.py ]]; then\n'
        '  exec "$BUILD_TEST_PYTHON" "$@"\nfi\n'
        'if [[ "$1" == packaging/* ]]; then\n'
        '  echo "$1" >> "$BUILD_TEST_LOG"; exit 0\nfi\n'
        'exec "$BUILD_TEST_PYTHON" "$@"\n'
    )
    python.chmod(0o755)
    env = {
        **os.environ,
        "PATH": f"{binary}:/usr/bin:/bin",
        "BUILD_TEST_LOG": str(log),
        "BUILD_TEST_SWIFT": str(swift),
        "BUILD_TEST_PYTHON": sys.executable,
    }
    return root, env, log


@pytest.mark.parametrize("dmg_status", [0, 9])
def test_full_build_prepares_gui_and_creates_hfs_dmg(macos_build, dmg_status):
    root, env, log = macos_build
    preserved = []
    for directory in ("build/macos", "dist/macos", "input", "output"):
        path = root / directory / "keep.txt"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("preserve")
        preserved.append(path)
    checksum = root / "dist/macos/heiccy-0.3.0-arm64.dmg.sha256"
    checksum.write_text("previous checksum")
    result = subprocess.run(
        ["/bin/bash", str(root / "packaging/macos/build.sh")],
        env={**env, "DMG_STATUS": str(dmg_status)},
        capture_output=True, text=True, timeout=15,
    )
    assert (result.returncode == 0) is (dmg_status == 0), result.stderr
    assert all(path.read_text() == "preserve" for path in preserved)
    commands = log.read_text()
    assert commands.index("Finder ready") < commands.index("app smoke --smoke-test")
    assert "-fs HFS+ -format UDZO" in commands
    assert "swift build --package-path macos --configuration release --arch arm64" in commands
    assert "packaging/macos/test_native_worker.py" in commands
    assert commands.index("packaging/macos/smoke_worker.py") < commands.index(
        "packaging/macos/test_native_worker.py"
    )
    assert (root / "dist/macos/heiccy.app/Contents/Resources/worker/heic-worker").read_text() == (
        "native worker fixture"
    )
    assert not (root / "build/macos/frozen").exists()
    # 성공 fixture에서는 실제 hdiutil 대신 빈 이미지를 해시한다.
    if dmg_status == 0:
        assert "packaging/macos/validate_dmg.py" in commands
        assert (root / "dist/macos/heiccy.app").is_dir()
        assert (root / "build/macos/dmg-root/heiccy.app").is_dir()
        assert "-volname heiccy" in commands
        assert checksum.exists()
        assert checksum.read_text() != "previous checksum"
    else:
        assert "packaging/macos/validate_dmg.py" not in commands
        assert not checksum.exists()


@pytest.mark.parametrize("busy_attempts", [1, 3])
def test_build_retries_only_busy_creation_before_checksum(macos_build, busy_attempts):
    root, env, log = macos_build
    result = subprocess.run(
        ["/bin/bash", str(root / "packaging/macos/build.sh")],
        env={**env, "DMG_BUSY_ATTEMPTS": str(busy_attempts)},
        capture_output=True, text=True, timeout=15, check=False,
    )
    assert (result.returncode == 0) is (busy_attempts == 1), result.stderr
    commands = log.read_text()
    assert commands.count("hdiutil create") == min(busy_attempts + 1, 3)
    checksum = root / "dist/macos/heiccy-0.3.0-arm64.dmg.sha256"
    assert checksum.exists() is (busy_attempts == 1)
    assert ("packaging/macos/validate_dmg.py" in commands) is (busy_attempts == 1)
    if busy_attempts == 3:
        assert not (root / "dist/macos/heiccy-0.3.0-arm64.dmg").exists()


def test_build_stops_without_gui_before_build_or_finder(macos_build):
    root, env, log = macos_build
    result = subprocess.run(
        ["/bin/bash", str(root / "packaging/macos/build.sh")],
        env={**env, "GUI_STATUS": "1"},
        capture_output=True, text=True, timeout=15,
    )
    assert result.returncode != 0
    assert "GUI 세션" in result.stderr
    assert not log.exists()


@pytest.mark.parametrize(
    "directory", ["build", "build/macos", "dist", "dist/macos", ".venv-app-build"]
)
def test_build_rejects_linked_output_parent_without_deleting(macos_build, directory):
    root, env, log = macos_build
    target = root / directory
    # fixture의 기존 경로는 옮겨 두고 외부 디렉터리로 연결한다.
    if target.exists():
        target.rename(target.with_name(target.name + "-original"))
    target.parent.mkdir(parents=True, exist_ok=True)
    outside = root.parent / "external"
    outside.mkdir()
    sentinel = outside / "keep.txt"
    sentinel.write_text("preserve")
    target.symlink_to(outside, target_is_directory=True)
    result = subprocess.run(
        ["/bin/bash", str(root / "packaging/macos/build.sh")],
        env=env, capture_output=True, text=True, timeout=15,
    )
    assert result.returncode != 0
    assert "링크가 아닌 디렉터리" in result.stderr
    assert sentinel.read_text() == "preserve"
    assert not log.exists()

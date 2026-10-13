"""배포 메타데이터 언어와 고정 wheel의 코덱 소스 고지를 검증합니다."""

import importlib.util
import io
import os
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


CODEC_INFO = {
    "libheif": "1.20.2",
    "HEIF": "x265 HEVC encoder (4.1+1-1d117be)",
    "AVIF": "",
    "encoders": {"x265": "x265 HEVC encoder (4.1+1-1d117be)", "mask": "mask"},
    "decoders": {"libde265": "libde265 HEVC decoder, version 1.0.16"},
}


def upstream_notice():
    return "\n".join(
        ["License for binary wheels: GPLv2."]
        + [
            f"Name: {name}\nLicense: {'GPLv2' if name == 'x265' else 'LGPLv3'}\n"
            f"  For details, see {previous}/COPYING\n  Source code: {previous}\n"
            for name, _, _, previous in licenses.CODEC_SOURCES
        ]
        + ["Name: libaom\nLicense: BSD 3-Clause\nSource code: obsolete\n"]
    )


def test_notice_points_to_actual_codec_sources_and_preserves_license_terms():
    result = licenses.corrected_bundled_notice(upstream_notice(), "1.1.1", CODEC_INFO)
    for name, version, source, previous in licenses.CODEC_SOURCES:
        assert f"Name: {name}\nVersion: {version}\n" in result
        assert f"Source code: {source}\n" in result
        assert f"For details, see {source}/COPYING\n" in result
        assert previous not in result
    assert result.count("License: LGPLv3") == 2
    assert "License: GPLv2" in result
    assert "Name: libaom" not in result


@pytest.mark.parametrize("codec", ["libheif", "HEIF", "decoders", "AVIF", "encoders"])
def test_changed_codec_build_requires_notice_review(codec):
    changed = {**CODEC_INFO, codec: "unexpected"}
    with pytest.raises(RuntimeError, match="대조"):
        licenses.corrected_bundled_notice(upstream_notice(), "1.1.1", changed)


def test_changed_wheel_version_requires_notice_review():
    with pytest.raises(RuntimeError, match="대조"):
        licenses.corrected_bundled_notice(upstream_notice(), "1.2.0", CODEC_INFO)


def test_changed_upstream_notice_fails_instead_of_shipping_old_links():
    with pytest.raises(RuntimeError, match="형식"):
        licenses.corrected_bundled_notice(
            upstream_notice().replace("v1.18.1", "v1.19.0"), "1.1.1", CODEC_INFO
        )


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
    command("swift", 'echo "$BUILD_TEST_SWIFT"')
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
    worker = root / "build/macos/frozen/worker"
    worker.mkdir(parents=True)
    (worker / "heic-worker").write_text("fixture")
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

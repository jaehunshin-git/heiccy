"""실제 파일과 CLI로 원본 산출물, 두 OS 출처와 공개 소스 연결을 검증한다."""

import copy
import hashlib
import importlib.util
import json
import plistlib
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SHA = "a" * 40
PUBLIC_SHA = "b" * 40
VERSION = "1.0.0"


def load_script(name):
    path = ROOT / "packaging/release" / f"{name}.py"
    if not path.is_file():
        pytest.skip("sdist에는 릴리스 스크립트가 포함되지 않습니다.")
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def validator():
    return load_script("verify_release")


def write_plist(path, version=VERSION):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(plistlib.dumps({"CFBundleShortVersionString": version}))


def write_asset(path, contents):
    path.write_bytes(contents)
    digest = hashlib.sha256(contents).hexdigest()
    Path(f"{path}.sha256").write_text(f"{digest}  {path.name}\n")


@pytest.fixture
def artifacts(tmp_path, validator):
    plist = tmp_path / "Info.plist"
    write_plist(plist)
    directories = {}
    for runner in validator.RUNNERS:
        directory = tmp_path / runner
        directory.mkdir()
        # OS별 DMG 해시가 달라도 성공해야 한다. 게시 대상은 반드시 15 원본이다.
        write_asset(directory / f"heiccy-{VERSION}-arm64.dmg", runner.encode())
        write_asset(
            directory / f"heiccy-codec-sources-{VERSION}.tar.gz", b"codec fixture"
        )
        validator.create_manifest(
            directory,
            plist,
            runner=runner,
            source_repository="internal/build",
            source_commit=SHA,
            source_ref=f"refs/tags/macos-v{VERSION}",
            run_id="123",
            run_attempt="1",
        )
        directories[runner] = directory
    return directories, plist


def verify(validator, artifacts, **changes):
    directories, plist = artifacts
    arguments = {
        "tag": f"macos-v{VERSION}",
        "source_repository": "internal/build",
        "source_commit": SHA,
        "run_id": "123",
        "run_attempt": "1",
    }
    arguments.update(changes)
    return validator.verify_release(directories, plist, **arguments)


def manifest_path(artifacts, runner="macos-15"):
    return artifacts[0][runner] / f"release-manifest-{runner}.json"


def test_two_os_pass_selects_identical_macos_15_files(validator, artifacts):
    before = {
        path: path.read_bytes()
        for directory in artifacts[0].values()
        for path in directory.iterdir()
    }
    result = verify(validator, artifacts)
    assert result["public_tag"] == "v1.0.0"
    assert Path(result["dmg"]).read_bytes() == b"macos-15"
    assert Path(result["codec_sources"]).name == "heiccy-codec-sources-1.0.0.tar.gz"
    assert Path(result["manifest_26"]) == manifest_path(artifacts, "macos-26")
    assert all(path.read_bytes() == contents for path, contents in before.items())


@pytest.mark.parametrize("runner", ["macos-15", "macos-26"])
@pytest.mark.parametrize(
    "name", ["heiccy-1.0.0-arm64.dmg", "heiccy-codec-sources-1.0.0.tar.gz"]
)
def test_tampered_assets_fail_for_either_os(validator, artifacts, runner, name):
    (artifacts[0][runner] / name).write_bytes(b"tampered")
    with pytest.raises(ValueError, match="SHA-256 불일치"):
        verify(validator, artifacts)


@pytest.mark.parametrize(
    "contents",
    [
        "0" * 64 + "  heiccy-1.0.0-arm64.dmg\n",
        hashlib.sha256(b"macos-15").hexdigest() + "  ../heiccy-1.0.0-arm64.dmg\n",
        hashlib.sha256(b"macos-15").hexdigest() + "  heiccy-1.0.0-arm64.dmg\nextra\n",
    ],
)
def test_checksum_hash_filename_and_extra_lines_rejected(
    validator, artifacts, contents
):
    (artifacts[0]["macos-15"] / "heiccy-1.0.0-arm64.dmg.sha256").write_text(contents)
    with pytest.raises(ValueError, match="체크섬"):
        verify(validator, artifacts)


@pytest.mark.parametrize(
    "tag", ["v1.0.0", "v0.3.0", "macos-v0.3.0", "macos-v1.0.0-extra"]
)
def test_python_and_mismatched_tags_never_release(validator, artifacts, tag):
    with pytest.raises(ValueError, match="태그와 앱 버전"):
        verify(validator, artifacts, tag=tag)


@pytest.mark.parametrize(
    "field,value",
    [
        ("source_commit", "c" * 40),
        ("source_repository", "other/repo"),
        ("run_id", "124"),
        ("run_attempt", "2"),
    ],
)
def test_different_source_or_ci_run_rejected(validator, artifacts, field, value):
    with pytest.raises(ValueError, match="불일치"):
        verify(validator, artifacts, **{field: value})


@pytest.mark.parametrize(
    "path,value",
    [
        (("schema_version",), True),
        (("schema_version",), 2),
        (("app_version",), "0.3.0"),
        (("app_version",), "01.0.0"),
        (("source_commit",), "short"),
        (("source_commit",), "A" * 40),
        (("artifact",), []),
        (("codec_sources",), None),
        (("provenance",), "bad"),
        (("artifact", "name"), "../heiccy-1.0.0-arm64.dmg"),
        (("artifact", "name"), "heiccy-0.3.0-arm64.dmg"),
        (("artifact", "sha256"), "g" * 64),
        (("codec_sources", "name"), "heiccy-codec-sources-0.3.0.tar.gz"),
        (("codec_sources", "sha256"), 123),
        (("provenance", "runner"), "macos-26"),
        (("provenance", "architecture"), "x86_64"),
        (("provenance", "workflow"), ".github/workflows/other.yml"),
        (("provenance", "source_ref"), "refs/tags/v1.0.0"),
        (("provenance", "run_attempt"), 1),
    ],
)
def test_malformed_or_forged_manifest_fails(validator, artifacts, path, value):
    target = manifest_path(artifacts)
    manifest = json.loads(target.read_text())
    section = manifest
    for key in path[:-1]:
        section = section[key]
    section[path[-1]] = value
    target.write_text(json.dumps(manifest))
    with pytest.raises(ValueError):
        verify(validator, artifacts)


@pytest.mark.parametrize(
    "contents", [b"{", b"[]", b"null", b"\xff", b'{"a": 1, "a": 2}']
)
def test_malformed_json_rejected(validator, artifacts, contents):
    manifest_path(artifacts).write_bytes(contents)
    with pytest.raises(ValueError):
        verify(validator, artifacts)


@pytest.mark.parametrize("field", ["source_commit", "codec_sources", "provenance"])
def test_missing_manifest_fields_rejected(validator, artifacts, field):
    target = manifest_path(artifacts)
    manifest = json.loads(target.read_text())
    del manifest[field]
    target.write_text(json.dumps(manifest))
    with pytest.raises(ValueError, match="필드"):
        verify(validator, artifacts)


def test_missing_second_os_fails(validator, artifacts):
    manifest_path(artifacts, "macos-26").unlink()
    with pytest.raises(ValueError):
        verify(validator, artifacts)
    directories = copy.copy(artifacts[0])
    directories.pop("macos-26")
    with pytest.raises(ValueError, match="두 OS"):
        verify(validator, (directories, artifacts[1]))


@pytest.mark.parametrize(
    "extra", ["extra.dmg", "extra.dmg.sha256", "heiccy-codec-sources-2.0.0.tar.gz"]
)
def test_ambiguous_asset_names_fail(validator, artifacts, extra):
    (artifacts[0]["macos-15"] / extra).write_bytes(b"extra")
    with pytest.raises(ValueError, match="중복"):
        verify(validator, artifacts)


@pytest.mark.parametrize(
    "name", ["heiccy-1.0.0-arm64.dmg", "release-manifest-macos-15.json"]
)
def test_symlink_assets_fail(validator, artifacts, tmp_path, name):
    path = artifacts[0]["macos-15"] / name
    outside = tmp_path / "outside"
    path.rename(outside)
    path.symlink_to(outside)
    with pytest.raises(ValueError, match="일반"):
        verify(validator, artifacts)


def test_manifest_creation_refuses_overwrite(validator, artifacts):
    directories, plist = artifacts
    with pytest.raises(FileExistsError):
        validator.create_manifest(
            directories["macos-15"],
            plist,
            runner="macos-15",
            source_repository="internal/build",
            source_commit=SHA,
            source_ref="refs/tags/macos-v1.0.0",
            run_id="123",
            run_attempt="1",
        )


def test_cli_prepares_notes_outputs_and_public_provenance(
    validator, artifacts, tmp_path
):
    script = ROOT / "packaging/release/verify_release.py"
    directories, plist = artifacts
    notes = tmp_path / "notes"
    notes.mkdir()
    (notes / "v1.0.0.md").write_text("# heiccy 1.0.0\n한국어 릴리스 노트\n")
    output, body = tmp_path / "output", tmp_path / "body.md"
    command = [
        sys.executable,
        str(script),
        "verify",
        "--plist",
        str(plist),
        "--macos-15",
        str(directories["macos-15"]),
        "--macos-26",
        str(directories["macos-26"]),
        "--tag",
        "macos-v1.0.0",
        "--source-repository",
        "internal/build",
        "--source-commit",
        SHA,
        "--run-id",
        "123",
        "--run-attempt",
        "1",
        "--output",
        str(output),
        "--notes-output",
        str(body),
        "--notes-directory",
        str(notes),
    ]
    result = subprocess.run(
        command, capture_output=True, text=True, timeout=10, check=False
    )
    assert result.returncode == 0, result.stderr
    assert "public_tag=v1.0.0\n" in output.read_text()
    assert "비공개 빌드 저장소의 SHA" in body.read_text()
    assert SHA in body.read_text()
    record = tmp_path / "release-source.json"
    result = subprocess.run(
        [
            sys.executable,
            str(script),
            "provenance",
            "--manifest-15",
            str(manifest_path(artifacts)),
            "--manifest-26",
            str(manifest_path(artifacts, "macos-26")),
            "--public-commit",
            PUBLIC_SHA,
            "--output",
            str(record),
        ],
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    data = json.loads(record.read_text())
    assert data["source_commit"] == SHA
    assert data["public_source_commit"] == PUBLIC_SHA
    assert data["public_repository"] == "jaehunshin-git/heiccy"
    assert len(data["build_manifests"]) == 2
    output.unlink()
    body.unlink()
    (directories["macos-26"] / "heiccy-1.0.0-arm64.dmg").write_bytes(b"tampered")
    result = subprocess.run(
        command, capture_output=True, text=True, timeout=10, check=False
    )
    assert result.returncode == 1
    assert "릴리스 검증 실패" in result.stderr
    assert not output.exists() and not body.exists()


def test_actual_exporter_snapshot_interoperates(validator, tmp_path):
    exporter = load_script("export_public")
    source = tmp_path / "source"
    source.mkdir()
    # 실제 exporter의 필수 허용 목록으로 작은 Git 저장소를 만든다.
    for name in exporter.REQUIRED:
        target = source / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("공개 테스트 파일\n")
    write_plist(source / "packaging/macos/Info.plist")
    (source / "pyproject.toml").write_text(
        '[project]\nname = "fixture"\nversion = "0.3.0"\nreadme = "README.pypi.md"\n'
    )
    (source / "docs/releases").mkdir()
    (source / "docs/releases/v1.0.0.md").write_text("# 릴리스\n")
    (source / "uv.lock").write_text("version = 1\n")
    for arguments in [
        ["init", "--initial-branch=main"],
        ["add", "."],
        [
            "-c",
            "user.name=테스트",
            "-c",
            "user.email=test@example.invalid",
            "-c",
            "commit.gpgsign=false",
            "commit",
            "-m",
            "테스트 스냅샷",
        ],
    ]:
        subprocess.run(
            ["git", "-C", str(source), *arguments],
            check=True,
            capture_output=True,
            timeout=10,
        )
    commit = subprocess.check_output(
        ["git", "-C", str(source), "rev-parse", "HEAD"], text=True, timeout=10
    ).strip()
    destination = tmp_path / "public"
    exporter.export_snapshot(destination, commit, source_root=source)
    validator.verify_snapshot(destination, source_commit=commit, version=VERSION)
    with pytest.raises(ValueError, match="소스 SHA 불일치"):
        validator.verify_snapshot(destination, source_commit=SHA, version=VERSION)
    lock = destination / "uv.lock"
    lock.write_text("version = 2\n")
    with pytest.raises(ValueError, match="공개 소스 SHA-256 불일치: uv.lock"):
        validator.verify_snapshot(destination, source_commit=commit, version=VERSION)
    lock.write_text("version = 1\n")
    workflows = destination / ".github/workflows"
    workflows.mkdir()
    (workflows / "internal.yml").write_text("name: 내부\n")
    with pytest.raises(ValueError, match="이슈 템플릿만"):
        validator.verify_snapshot(destination, source_commit=commit, version=VERSION)

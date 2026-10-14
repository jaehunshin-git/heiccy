"""과거 공개 baseline만 검사하며 새 개발 파일과 SOURCE.json을 구분해 보존한다."""

import copy
import hashlib
import importlib.util
import json
import os
import plistlib
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "packaging/release/verify_source_snapshot.py"
BASELINE = "77908397ffb24dc1881ea1f0ebfc5d9d9c977852"
LEGACY_SHA = "872025c8d334616260697e1eea6c23f863642e43"
SOURCE_DIGEST = "a7a0540e23df27f39e4ed8ab5f49e0927210534998ffeeae49a52018cacad786"
if not SCRIPT.is_file():
    pytest.skip(
        "sdist에는 스냅샷 검증 도구가 포함되지 않습니다.", allow_module_level=True
    )


@pytest.fixture
def checker():
    spec = importlib.util.spec_from_file_location("source_snapshot", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def git(root, *arguments):
    """임시 테스트 저장소에서만 커밋을 만들며 사용자 설정·훅은 사용하지 않는다."""
    environment = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    environment.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
    return (
        subprocess.run(
            [
                "git",
                "-C",
                str(root),
                "-c",
                f"core.hooksPath={root / 'empty-hooks'}",
                "-c",
                "commit.gpgsign=false",
                "-c",
                "tag.gpgsign=false",
                "-c",
                "user.name=스냅샷 테스트",
                "-c",
                "user.email=fixture@example.invalid",
                *arguments,
            ],
            env=environment,
            capture_output=True,
            check=True,
            timeout=10,
        )
        .stdout.decode()
        .strip()
    )


def commit(root):
    git(root, "add", ".")
    git(root, "commit", "-m", "테스트 기준 스냅샷")
    return git(root, "rev-parse", "HEAD")


@pytest.fixture
def archive_factory(tmp_path, checker, monkeypatch):
    """임시 이력으로 실패 경계를 검사하며 실제 baseline 상수는 별도 테스트로 고정한다."""

    def make(*, change=None, raw_source=None, link=False):
        root = tmp_path / "공개 저장소"
        root.mkdir()
        git(root, "init", "--initial-branch=main")
        files = {
            "README.md": b"baseline\n",
            "packaging/macos/Info.plist": plistlib.dumps(
                {"CFBundleShortVersionString": "1.0.0"}
            ),
            "pyproject.toml": b'[project]\nversion = "0.3.0"\n',
            "packaging/release/export_public.py": b"legacy exporter\n",
            "tests/test_public_export.py": b"legacy tests\n",
        }
        for name, contents in files.items():
            target = root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(contents)
        if link:
            target = root / "README.md"
            target.unlink()
            target.symlink_to("pyproject.toml")
            files["README.md"] = b"pyproject.toml"
        metadata = {
            "source_commit": LEGACY_SHA,
            "app_version": "1.0.0",
            "py_version": "0.3.0",
            "files": {
                name: hashlib.sha256(body).hexdigest() for name, body in files.items()
            },
        }
        if change is not None:
            change(metadata)
        (root / "SOURCE.json").write_bytes(
            raw_source
            if raw_source is not None
            else (json.dumps(metadata, ensure_ascii=False, indent=2) + "\n").encode()
        )
        baseline = commit(root)
        monkeypatch.setattr(checker, "BASELINE_COMMIT", baseline)
        return root, baseline

    return make


def test_actual_baseline_preserves_original_source_bytes_and_131_files(checker):
    source = ROOT / "SOURCE.json"
    before = source.read_bytes()
    assert checker.BASELINE_COMMIT == BASELINE
    assert hashlib.sha256(before).hexdigest() == SOURCE_DIGEST
    result = checker.verify_archive_snapshot(ROOT)
    assert result["baseline_commit"] == BASELINE
    assert result["source_commit"] == LEGACY_SHA
    assert result["file_count"] == 131
    assert result["app_version"] == "1.0.0" and result["py_version"] == "0.3.0"
    assert "packaging/release/export_public.py" in result["files"]
    assert "tests/test_public_export.py" in result["files"]
    assert not (ROOT / "packaging/release/export_public.py").exists()
    assert not (ROOT / "tests/test_public_export.py").exists()
    assert source.read_bytes() == before


def test_cli_uses_only_stdlib_and_reports_archive_baseline():
    result = subprocess.run(
        [sys.executable, "-I", str(SCRIPT), str(ROOT)],
        capture_output=True,
        text=True,
        timeout=15,
    )
    assert result.returncode == 0, result.stderr
    assert "131개 파일" in result.stdout and BASELINE in result.stdout


def test_new_history_worktree_changes_and_retired_files_do_not_break_archive(
    checker, archive_factory
):
    root, baseline = archive_factory()
    source = root / "SOURCE.json"
    before = source.read_bytes()
    (root / "README.md").write_text("새 개발 내용\n")
    (root / "packaging/macos/Info.plist").write_bytes(
        plistlib.dumps({"CFBundleShortVersionString": "2.0.0"})
    )
    (root / "pyproject.toml").write_text('[project]\nversion = "0.4.0"\n')
    (root / "packaging/release/export_public.py").unlink()
    (root / "tests/test_public_export.py").unlink()
    workflows = root / ".github/workflows"
    workflows.mkdir(parents=True)
    (workflows / "macos.yml").write_text("name: 새 CI\n")
    head = commit(root)
    assert head != baseline
    (root / "README.md").write_text("커밋 후 작업트리 변경\n")
    (root / "AGENTS.md").write_text("새 개발 안내\n")
    status = git(root, "status", "--porcelain")
    result = checker.verify_archive_snapshot(root)
    assert result["file_count"] == 5 and result["app_version"] == "1.0.0"
    assert git(root, "rev-parse", "HEAD") == head
    assert git(root, "status", "--porcelain") == status
    assert source.read_bytes() == before


@pytest.mark.parametrize("change", ["whitespace", "hash", "source-sha"])
def test_source_json_byte_changes_fail_without_rewriting(
    checker, archive_factory, change
):
    root, _ = archive_factory()
    source = root / "SOURCE.json"
    original = source.read_bytes()
    if change == "whitespace":
        changed = original + b"\n"
    else:
        metadata = json.loads(original)
        if change == "hash":
            metadata["files"]["README.md"] = "0" * 64
        else:
            metadata["source_commit"] = "b" * 40
        changed = json.dumps(metadata).encode()
    source.write_bytes(changed)
    with pytest.raises(ValueError, match="보존 바이트 불일치"):
        checker.verify_archive_snapshot(root)
    assert source.read_bytes() == changed


def test_source_json_symlink_is_rejected(checker, archive_factory, tmp_path):
    root, _ = archive_factory()
    source = root / "SOURCE.json"
    outside = tmp_path / "outside.json"
    source.rename(outside)
    before = outside.read_bytes()
    source.symlink_to(outside)
    with pytest.raises(ValueError, match="일반 파일"):
        checker.verify_archive_snapshot(root)
    assert outside.read_bytes() == before


def test_baseline_file_digest_mismatch_fails(checker, archive_factory):
    def change(metadata):
        metadata["files"]["README.md"] = "0" * 64

    root, _ = archive_factory(change=change)
    with pytest.raises(ValueError, match="baseline 소스 SHA-256 불일치: README.md"):
        checker.verify_archive_snapshot(root)


@pytest.mark.parametrize(
    "name",
    [
        "",
        "/README.md",
        "../README.md",
        "src/../README.md",
        "./README.md",
        "src//file.py",
        ".git/config",
        "SOURCE.json",
        "src\\file.py",
        "line\nfeed",
    ],
)
def test_unsafe_manifest_paths_are_rejected(checker, archive_factory, name):
    def change(metadata):
        metadata["files"][name] = "0" * 64

    root, _ = archive_factory(change=change)
    with pytest.raises(ValueError, match="경로"):
        checker.verify_archive_snapshot(root)


@pytest.mark.parametrize("digest", ["short", "A" * 64, "g" * 64, 123, None])
def test_malformed_hashes_are_rejected(checker, archive_factory, digest):
    def change(metadata):
        metadata["files"]["README.md"] = digest

    root, _ = archive_factory(change=change)
    with pytest.raises(ValueError, match="해시"):
        checker.verify_archive_snapshot(root)


def test_committed_symlink_is_not_treated_as_file(checker, archive_factory):
    root, _ = archive_factory(link=True)
    with pytest.raises(ValueError, match="baseline의 일반 파일"):
        checker.verify_archive_snapshot(root)


@pytest.mark.parametrize(
    "change", ["missing-blob", "missing-version", "app-version", "py-version"]
)
def test_archive_requires_files_and_matching_versions(checker, archive_factory, change):
    def mutate(metadata):
        if change == "missing-blob":
            metadata["files"]["missing.py"] = "0" * 64
        elif change == "missing-version":
            del metadata["files"]["pyproject.toml"]
        else:
            metadata[change.replace("-", "_")] = "2.0.0"

    root, _ = archive_factory(change=mutate)
    with pytest.raises(ValueError, match="일반 파일|버전"):
        checker.verify_archive_snapshot(root)


@pytest.mark.parametrize(
    "contents", [b"{", b"[]", b"null", b"\xff", b'{"files": {}, "files": {}}']
)
def test_malformed_and_duplicate_json_are_rejected(checker, archive_factory, contents):
    root, _ = archive_factory(raw_source=contents)
    with pytest.raises(ValueError):
        checker.verify_archive_snapshot(root)


def test_git_replace_cannot_change_archive_blobs(checker, archive_factory):
    root, baseline = archive_factory()
    original = (root / "README.md").read_bytes()
    (root / "README.md").write_text("대체 객체의 변경 내용\n")
    replacement = commit(root)
    git(root, "replace", baseline, replacement)
    assert git(root, "show", f"{baseline}:README.md").encode() != original
    assert checker.verify_archive_snapshot(root)["file_count"] == 5


def test_environment_cannot_redirect_git_repository(
    checker, archive_factory, monkeypatch
):
    root, _ = archive_factory()
    for name in ("GIT_DIR", "GIT_WORK_TREE", "GIT_OBJECT_DIRECTORY", "GIT_COMMON_DIR"):
        monkeypatch.setenv(name, str(root / "does-not-exist"))
    assert checker.verify_archive_snapshot(root)["file_count"] == 5


@pytest.mark.parametrize("baseline", ["missing", "annotated-tag"])
def test_missing_history_or_tag_object_is_not_accepted(
    checker, archive_factory, monkeypatch, baseline
):
    root, sha = archive_factory()
    if baseline == "annotated-tag":
        git(root, "tag", "-a", "fixture", "-m", "태그 객체", sha)
        value = git(root, "rev-parse", "fixture")
    else:
        value = "a" * 40
    monkeypatch.setattr(checker, "BASELINE_COMMIT", value)
    with pytest.raises(ValueError, match="baseline"):
        checker.verify_archive_snapshot(root)


def test_subdirectory_is_not_a_snapshot_root(checker, archive_factory):
    root, _ = archive_factory()
    with pytest.raises(ValueError, match="저장소 루트"):
        checker.verify_archive_snapshot(root / "tests")


def test_metadata_validation_does_not_accept_legacy_source_as_public_baseline(
    checker, archive_factory
):
    root, baseline = archive_factory()
    metadata = copy.deepcopy(checker.verify_archive_snapshot(root))
    assert metadata["source_commit"] == LEGACY_SHA
    assert metadata["baseline_commit"] == baseline
    assert metadata["source_commit"] != metadata["baseline_commit"]

"""실제 임시 Git 커밋으로 공개 내보내기의 경계와 복구를 검증합니다."""

import hashlib
import importlib.util
import json
import plistlib
import subprocess
import sys
import tempfile
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "packaging/release/export_public.py"
if not SCRIPT.is_file():
    pytest.skip(
        "sdist에는 공개 스냅샷 도구가 포함되지 않습니다.", allow_module_level=True
    )
spec = importlib.util.spec_from_file_location("export_public", SCRIPT)
exporter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(exporter)


def git(root, *arguments):
    return subprocess.run(
        ["git", "-C", str(root), *arguments],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()


def write(root, name, body):
    path = root / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(body if isinstance(body, bytes) else body.encode())
    return path


def commit(root):
    git(root, "add", "-A", "-f")
    git(root, "commit", "-m", "테스트 스냅샷")
    return git(root, "rev-parse", "HEAD")


@pytest.fixture
def source(tmp_path):
    root = tmp_path / "소스 저장소"
    root.mkdir()
    git(root, "init")
    git(root, "config", "user.name", "공개 테스트")
    git(root, "config", "user.email", "fixture@example.invalid")
    for name in exporter.REQUIRED:
        write(root, name, f"커밋 파일: {name}\n")
    write(
        root,
        "pyproject.toml",
        '[project]\nversion = "0.3.0"\nreadme = "README.pypi.md"\n',
    )
    write(
        root,
        "packaging/macos/Info.plist",
        plistlib.dumps(
            {
                "CFBundleShortVersionString": "1.0.0",
            }
        ),
    )
    for name in (
        "uv.lock",
        ".gitignore",
        "src/heic_converter/cli.py",
        "tests/test_cli.py",
        "macos/Package.swift",
        "macos/Sources/App/main.swift",
        "macos/Tests/App/Test.swift",
        "packaging/release/export_public.py",
        "packaging/release/verify_release.py",
        "docs/releases/1.0.0.md",
        "docs/assets/branding/DESIGN.md",
        "docs/assets/branding/index.html",
    ):
        write(root, name, f"공개 파일: {name}\n")
    write(root, "packaging/macos/build.sh", "#!/bin/sh\n").chmod(0o755)
    excluded = (
        "AGENTS.md",
        ".github/workflows/private.yml",
        ".github/ISSUE_TEMPLATE/private.yml",
        "input/photo.heic",
        "output/photo.jpeg",
        "docs/internal.md",
        "docs/macos-build-release.md",
        "secrets/token.txt",
        "src/.env",
        "src/secret.txt",
        "src/__pycache__/cached.pyc",
        "src/photo.jpeg",
        "tests/personal-photo.png",
        "tests/.DS_Store",
        "packaging/macos/.venv/private.txt",
        "macos/.build/debug/App",
        "macos/.swiftpm/settings.json",
    )
    for name in excluded:
        write(root, name, "공개하면 안 되는 파일")
    return root, commit(root), excluded


def test_exports_only_commit_blobs_and_maps_templates(source, tmp_path):
    root, sha, excluded = source
    write(root, "README.md", "작업 트리에서 변경한 비공개 내용")
    write(root, "src/heic_converter/untracked.py", "untracked 비공개 내용")
    destination = tmp_path / "공개 저장소"
    result = exporter.export_snapshot(destination, sha, source_root=root)
    assert (destination / "README.md").read_text() == "커밋 파일: README.md\n"
    assert not (destination / "src/heic_converter/untracked.py").exists()
    assert not (destination / ".git").exists()
    assert all(not (destination / name).exists() for name in excluded)
    assert not (destination / "packaging/release/public-issues").exists()
    for name in (
        "docs/third-party-sources.md",
        "packaging/release/collect_codec_sources.py",
    ):
        assert (destination / name).read_bytes() == git_blob(root, sha, name)
    for name in ("config.yml", "bug.yml", "feature.yml"):
        assert (destination / ".github/ISSUE_TEMPLATE" / name).read_bytes() == git_blob(
            root, sha, f"packaging/release/public-issues/{name}"
        )
    assert (destination / "packaging/macos/build.sh").stat().st_mode & 0o111
    manifest = json.loads((destination / "SOURCE.json").read_text())
    assert result == manifest
    assert manifest["source_commit"] == sha
    assert manifest["app_version"] == "1.0.0"
    assert manifest["py_version"] == "0.3.0"
    files = {
        path.relative_to(destination).as_posix()
        for path in destination.rglob("*")
        if path.is_file()
    }
    assert files == set(manifest["files"]) | {"SOURCE.json"}
    assert all(
        hashlib.sha256((destination / name).read_bytes()).hexdigest() == digest
        for name, digest in manifest["files"].items()
    )


def git_blob(root, sha, name):
    return subprocess.run(
        ["git", "-C", str(root), "show", f"{sha}:{name}"],
        check=True,
        capture_output=True,
    ).stdout


@pytest.mark.parametrize("value", ["HEAD", "a" * 39, "g" * 40, "0" * 40])
def test_requires_existing_full_commit_sha(source, tmp_path, value):
    root, _, _ = source
    destination = tmp_path / "public"
    with pytest.raises((ValueError, subprocess.CalledProcessError)):
        exporter.export_snapshot(destination, value, source_root=root)
    assert not destination.exists()


def test_rejects_tag_object_sha_even_if_it_resolves_to_commit(source, tmp_path):
    root, sha, _ = source
    git(root, "tag", "-a", "snapshot", "-m", "태그 객체", sha)
    tag_sha = git(root, "rev-parse", "snapshot")
    with pytest.raises(ValueError, match="일치"):
        exporter.export_snapshot(tmp_path / "public", tag_sha, source_root=root)


@pytest.mark.parametrize("name", ["src/link", "docs/private-link"])
def test_rejects_all_committed_symlinks_including_excluded_paths(
    source, tmp_path, name
):
    root, _, _ = source
    path = root / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.symlink_to("../README.md")
    sha = commit(root)
    with pytest.raises(ValueError, match="symlink/submodule"):
        exporter.export_snapshot(tmp_path / "public", sha, source_root=root)
    assert not (tmp_path / "public").exists()


def test_rejects_submodule_without_reading_it(source, tmp_path):
    root, sha, _ = source
    git(root, "update-index", "--add", "--cacheinfo", f"160000,{sha},private-submodule")
    git(root, "commit", "-m", "submodule 테스트")
    with pytest.raises(ValueError, match="symlink/submodule"):
        exporter.export_snapshot(
            tmp_path / "public", git(root, "rev-parse", "HEAD"), source_root=root
        )


@pytest.mark.parametrize(
    "missing",
    [
        "README.pypi.md",
        "docs/build.md",
        "docs/compatibility.md",
        "docs/releases/1.0.0.md",
        "packaging/macos/Info.plist",
    ],
)
def test_missing_required_files_preserve_existing_destination(
    source, tmp_path, missing
):
    root, sha, _ = source
    destination = tmp_path / "public"
    exporter.export_snapshot(destination, sha, source_root=root)
    before = (destination / "SOURCE.json").read_bytes()
    (root / missing).unlink()
    with pytest.raises(ValueError, match="필수|릴리스"):
        exporter.export_snapshot(destination, commit(root), sync=True, source_root=root)
    assert (destination / "SOURCE.json").read_bytes() == before


def test_sync_preserves_git_and_replaces_deleted_public_files(source, tmp_path):
    root, sha, _ = source
    destination = tmp_path / "public"
    exporter.export_snapshot(destination, sha, source_root=root)
    git(destination, "init")
    git(destination, "config", "user.name", "공개 테스트")
    git(destination, "config", "user.email", "fixture@example.invalid")
    public_sha = commit(destination)
    original_config = (destination / ".git/config").read_bytes()
    (destination / ".git/sentinel").write_text("이력 보존")
    (root / "tests/test_cli.py").unlink()
    write(root, "README.md", "새 커밋")
    new_sha = commit(root)
    write(root, "README.md", "커밋 이후 변경")
    exporter.export_snapshot(destination, new_sha, sync=True, source_root=root)
    assert (destination / ".git/config").read_bytes() == original_config
    assert (destination / ".git/sentinel").read_text() == "이력 보존"
    assert git(destination, "rev-parse", "HEAD") == public_sha
    assert (
        git_blob(destination, public_sha, "README.md")
        == b"\xec\xbb\xa4\xeb\xb0\x8b \xed\x8c\x8c\xec\x9d\xbc: README.md\n"
    )
    assert (destination / "README.md").read_text() == "새 커밋"
    assert not (destination / "tests/test_cli.py").exists()
    assert not list(tmp_path.glob(".public-*"))


def test_sync_refuses_unknown_destination_files(source, tmp_path):
    root, sha, _ = source
    destination = tmp_path / "public"
    destination.mkdir()
    sentinel = write(destination, "private.txt", "보존")
    with pytest.raises(ValueError, match="허용 목록 밖"):
        exporter.export_snapshot(destination, sha, sync=True, source_root=root)
    assert sentinel.read_text() == "보존"


@pytest.mark.parametrize("place", ["root", "ancestor", "tracked", "build-root"])
def test_refuses_destructive_source_paths(source, place):
    root, sha, _ = source
    destination = {
        "root": root,
        "ancestor": root.parent,
        "tracked": root / "src",
        "build-root": root / "build",
    }[place]
    with pytest.raises(ValueError):
        exporter.export_snapshot(destination, sha, sync=True, source_root=root)
    assert git(root, "rev-parse", "HEAD") == sha


def test_allows_build_subdirectory_but_not_tracked_build_destination(source):
    root, sha, _ = source
    exporter.export_snapshot(root / "build/public", sha, source_root=root)
    assert (root / "build/public/SOURCE.json").exists()
    write(root, "build/tracked/keep.txt", "보존")
    git(root, "add", "-f", "build/tracked/keep.txt")
    with pytest.raises(ValueError, match="tracked"):
        exporter.export_snapshot(
            root / "build/tracked", sha, sync=True, source_root=root
        )
    assert (root / "build/tracked/keep.txt").read_text() == "보존"


@pytest.mark.parametrize("place", ["destination", "parent", "inside"])
def test_refuses_destination_links(source, tmp_path, place):
    root, sha, _ = source
    real = tmp_path / "real"
    real.mkdir()
    link = tmp_path / "link"
    link.symlink_to(real, target_is_directory=True)
    if place == "destination":
        destination = link
    elif place == "parent":
        destination = link / "public"
    else:
        destination = tmp_path / "public"
        destination.mkdir()
        (destination / "README.md").symlink_to(root / "README.md")
    with pytest.raises(ValueError, match="symlink"):
        exporter.export_snapshot(destination, sha, sync=True, source_root=root)
    assert not (real / "SOURCE.json").exists()


def test_nonempty_destination_requires_sync(source, tmp_path):
    root, sha, _ = source
    destination = tmp_path / "public"
    destination.mkdir()
    write(destination, "README.md", "보존")
    with pytest.raises(ValueError, match="비어"):
        exporter.export_snapshot(destination, sha, source_root=root)
    assert (destination / "README.md").read_text() == "보존"


def test_failed_swap_restores_existing_files_and_git(source, tmp_path, monkeypatch):
    root, sha, _ = source
    destination = tmp_path / "public"
    exporter.export_snapshot(destination, sha, source_root=root)
    git(destination, "init")
    sentinel = write(destination, ".git/sentinel", "보존")
    before = (destination / "SOURCE.json").read_bytes()
    original = Path.rename

    def fail_stage(path, target):
        if path.name.startswith(".public-export-") and target == destination:
            raise OSError("교체 실패 테스트")
        return original(path, target)

    monkeypatch.setattr(Path, "rename", fail_stage)
    with pytest.raises(OSError, match="교체 실패"):
        exporter.export_snapshot(destination, sha, sync=True, source_root=root)
    assert sentinel.read_text() == "보존"
    assert (destination / "SOURCE.json").read_bytes() == before
    assert not list(tmp_path.glob(".public-*"))


def test_cli_reads_its_repository_commit_and_accepts_empty_destination(
    source, tmp_path
):
    root, _, _ = source
    write(root, "packaging/release/export_public.py", SCRIPT.read_bytes())
    sha = commit(root)
    destination = tmp_path / "cli-public"
    destination.mkdir()
    result = subprocess.run(
        [
            sys.executable,
            str(root / "packaging/release/export_public.py"),
            str(destination),
            "--source-commit",
            sha,
            "--sync",
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr
    assert json.loads((destination / "SOURCE.json").read_text())["source_commit"] == sha


def test_git_replace_does_not_change_selected_commit_contents(source, tmp_path):
    root, sha, _ = source
    original = git_blob(root, sha, "README.md")
    write(root, "README.md", "대체 커밋 내용")
    replacement = commit(root)
    git(root, "replace", sha, replacement)
    destination = tmp_path / "public"
    exporter.export_snapshot(destination, sha, source_root=root)
    assert (destination / "README.md").read_bytes() == original


def test_rejects_external_non_temporary_destination(source):
    root, sha, _ = source
    destination = Path.home() / "heiccy-export-must-not-be-created"
    with pytest.raises(ValueError, match="시스템 임시"):
        exporter.export_snapshot(destination, sha, source_root=root)


def test_rejects_system_temporary_root(source):
    root, sha, _ = source
    with pytest.raises(ValueError):
        exporter.export_snapshot(
            Path(tempfile.gettempdir()).resolve(), sha, sync=True, source_root=root
        )


def test_selected_commit_tracked_build_path_cannot_be_overwritten(source):
    root, _, _ = source
    write(root, "build/public/README.md", "원본 추적 파일")
    sha = commit(root)
    git(root, "rm", "--cached", "-r", "build/public")
    with pytest.raises(ValueError, match="tracked"):
        exporter.export_snapshot(
            root / "build/public", sha, sync=True, source_root=root
        )
    assert (root / "build/public/README.md").read_text() == "원본 추적 파일"


@pytest.mark.parametrize(
    "missing",
    ["docs/third-party-sources.md", "packaging/release/collect_codec_sources.py"],
)
def test_codec_source_notice_and_collector_are_required(source, tmp_path, missing):
    root, _, _ = source
    (root / missing).unlink()
    sha = commit(root)
    with pytest.raises(ValueError, match="필수"):
        exporter.export_snapshot(tmp_path / "public", sha, source_root=root)


def test_exported_manifest_integrates_with_release_verifier(source, tmp_path):
    root, sha, _ = source
    verifier_path = ROOT / "packaging/release/verify_release.py"
    if not verifier_path.is_file():
        pytest.skip("릴리스 verifier가 없는 checkout입니다.")
    verifier_spec = importlib.util.spec_from_file_location(
        "public_export_verifier", verifier_path
    )
    verifier = importlib.util.module_from_spec(verifier_spec)
    verifier_spec.loader.exec_module(verifier)
    destination = tmp_path / "public"
    exporter.export_snapshot(destination, sha, source_root=root)
    verifier.verify_snapshot(destination, source_commit=sha, version="1.0.0")

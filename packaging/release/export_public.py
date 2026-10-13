"""지정한 Git 커밋의 허용 파일만 공개 스냅샷으로 내보냅니다."""

import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import tempfile
import tomllib
from pathlib import Path, PurePosixPath

FILES = {
    "README.md",
    "README.ko.md",
    "README.pypi.md",
    "LICENSE",
    "pyproject.toml",
    "uv.lock",
    ".gitignore",
    "macos/Package.swift",
    "packaging/release/export_public.py",
    "packaging/release/verify_release.py",
    "packaging/release/collect_codec_sources.py",
    "docs/build.md",
    "docs/compatibility.md",
    "docs/third-party-sources.md",
}
PREFIXES = (
    "src/",
    "tests/",
    "macos/Sources/",
    "macos/Tests/",
    "packaging/macos/",
    "packaging/release/public-issues/",
    "docs/releases/",
    "docs/assets/branding/",
)
REQUIRED = {
    "README.md",
    "README.ko.md",
    "README.pypi.md",
    "LICENSE",
    "pyproject.toml",
    "packaging/macos/Info.plist",
    "docs/build.md",
    "docs/compatibility.md",
    "docs/third-party-sources.md",
    "packaging/release/collect_codec_sources.py",
    "packaging/release/public-issues/config.yml",
    "packaging/release/public-issues/bug.yml",
    "packaging/release/public-issues/feature.yml",
}
FORBIDDEN = {
    "AGENTS.md",
    "input",
    "output",
    ".DS_Store",
    "__pycache__",
    "node_modules",
    "build",
    "dist",
    "cache",
    "caches",
    "secrets",
    "credentials",
}


def git(root: Path, *arguments: str) -> bytes:
    return subprocess.run(
        ["git", "--no-replace-objects", "-C", str(root), *arguments],
        check=True,
        capture_output=True,
    ).stdout


def allowed(name: str) -> bool:
    path = PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts:
        return False
    if any(
        part in FORBIDDEN or (part.startswith(".") and part != ".gitignore")
        for part in path.parts
    ):
        return False
    if re.search(r"(secret|credential|private[-_]?key)", path.name, re.IGNORECASE):
        return False
    if path.suffix.lower() in {
        ".heic",
        ".heif",
        ".mov",
        ".mp4",
        ".key",
        ".pem",
        ".p12",
        ".pyc",
        ".pyo",
    }:
        return False
    if not name.startswith("docs/assets/branding/") and path.suffix.lower() in {
        ".jpeg",
        ".jpg",
        ".png",
        ".gif",
        ".webp",
        ".tiff",
        ".tif",
        ".pdf",
        ".hwp",
        ".hwpx",
    }:
        return False
    return name in FILES or name.startswith(PREFIXES)


def public_name(name: str) -> str:
    prefix = "packaging/release/public-issues/"
    if name.startswith(prefix):
        return ".github/ISSUE_TEMPLATE/" + name.removeprefix(prefix)
    return name


def check_no_links(path: Path) -> None:
    for parent in (path, *path.parents):
        if parent.is_symlink():
            raise ValueError(f"목적지 또는 부모가 symlink입니다: {parent}")
    if path.exists():
        for entry in path.rglob("*"):
            if entry.is_symlink():
                raise ValueError(f"목적지 내부 symlink는 허용하지 않습니다: {entry}")
            if not entry.is_file() and not entry.is_dir():
                raise ValueError(f"목적지 특수 파일은 허용하지 않습니다: {entry}")


def check_destination(
    destination: Path,
    root: Path,
    sync: bool,
    source_commit: str | None = None,
) -> None:
    check_no_links(destination)
    if (
        destination == Path(destination.anchor)
        or destination == root
        or root.is_relative_to(destination)
    ):
        raise ValueError("루트 또는 소스 저장소의 상위 경로에는 내보낼 수 없습니다.")
    temporary_roots = {
        Path(tempfile.gettempdir()).resolve(),
        Path("/tmp").resolve(),
        Path("/var/tmp").resolve(),
    }
    if destination in temporary_roots:
        raise ValueError("임시 디렉터리 루트에는 내보낼 수 없습니다.")
    if destination.is_relative_to(root):
        build = root / "build"
        if destination == build or not destination.is_relative_to(build):
            raise ValueError("소스 저장소 안에서는 build 하위 목적지만 허용합니다.")
        tracked = git(root, "ls-files", "-z").decode().split("\0")
        if source_commit is not None:
            tracked += (
                git(root, "ls-tree", "-r", "--name-only", "-z", source_commit)
                .decode()
                .split("\0")
            )
        relative = destination.relative_to(root).as_posix()
        if any(
            name == relative
            or name.startswith(relative + "/")
            or relative.startswith(name + "/")
            for name in tracked
            if name
        ):
            raise ValueError("소스의 tracked 경로와 겹치는 목적지는 허용하지 않습니다.")
    elif not any(destination.is_relative_to(path) for path in temporary_roots):
        raise ValueError("소스 저장소 밖에서는 시스템 임시 디렉터리 하위만 허용합니다.")
    if destination.exists():
        if not destination.is_dir():
            raise ValueError("목적지는 디렉터리여야 합니다.")
        if not sync and any(destination.iterdir()):
            raise ValueError(
                "기존 목적지는 비어 있어야 합니다. 갱신에는 --sync를 사용하세요."
            )
        if (destination / ".git").exists() and not (destination / ".git").is_dir():
            raise ValueError("목적지 .git은 독립 저장소 디렉터리여야 합니다.")
        if sync:
            mapped = {public_name(name) for name in REQUIRED}
            for entry in destination.rglob("*"):
                relative = entry.relative_to(destination).as_posix()
                if relative == ".git" or relative.startswith(".git/") or entry.is_dir():
                    continue
                original = relative.replace(
                    ".github/ISSUE_TEMPLATE/", "packaging/release/public-issues/", 1
                )
                if (
                    relative != "SOURCE.json"
                    and relative not in mapped
                    and not allowed(original)
                ):
                    raise ValueError(
                        f"기존 목적지에 공개 허용 목록 밖의 파일이 있습니다: {relative}"
                    )


def snapshot(root: Path, commit: str) -> tuple[dict[str, tuple[bytes, str]], dict]:
    if not re.fullmatch(r"[0-9a-fA-F]{40}", commit):
        raise ValueError("source-commit은 전체 40자리 SHA여야 합니다.")
    resolved = git(root, "rev-parse", "--verify", commit + "^{commit}").decode().strip()
    if resolved != commit.lower():
        raise ValueError("source-commit이 실제 커밋 SHA와 일치하지 않습니다.")
    blobs = {}
    for record in git(root, "ls-tree", "-r", "-z", resolved).split(b"\0"):
        if not record:
            continue
        header, raw_name = record.split(b"\t", 1)
        mode, kind, oid = header.decode().split()
        name = raw_name.decode("utf-8")
        if mode not in {"100644", "100755"} or kind != "blob":
            raise ValueError(
                f"symlink/submodule 또는 특수 Git 항목은 허용하지 않습니다: {name}"
            )
        if allowed(name):
            blobs[name] = (git(root, "cat-file", "blob", oid), mode)
    missing = REQUIRED - blobs.keys()
    if missing:
        raise ValueError(f"필수 공개 파일이 없습니다: {sorted(missing)}")
    if not any(
        name.startswith("docs/releases/") and name.endswith(".md") for name in blobs
    ):
        raise ValueError("docs/releases/에 릴리스 Markdown 문서가 필요합니다.")
    project = tomllib.loads(blobs["pyproject.toml"][0].decode())["project"]
    if project.get("readme") != "README.pypi.md":
        raise ValueError("PyPI readme는 README.pypi.md여야 합니다.")
    app_version = plistlib.loads(blobs["packaging/macos/Info.plist"][0])[
        "CFBundleShortVersionString"
    ]
    manifest = {
        "source_commit": resolved,
        "app_version": app_version,
        "py_version": project["version"],
        "files": {
            public_name(name): hashlib.sha256(body).hexdigest()
            for name, (body, _) in sorted(blobs.items())
        },
    }
    return blobs, manifest


def export_snapshot(
    destination: Path,
    source_commit: str,
    *,
    sync: bool = False,
    source_root: Path | None = None,
) -> dict:
    root = Path(
        git(
            source_root or Path(__file__).resolve().parents[2],
            "rev-parse",
            "--show-toplevel",
        )
        .decode()
        .strip()
    ).resolve()
    destination = Path(os.path.abspath(destination))
    check_destination(destination, root, sync)
    blobs, manifest = snapshot(root, source_commit)
    check_destination(destination, root, sync, manifest["source_commit"])
    destination.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(
        tempfile.mkdtemp(prefix=f".{destination.name}-export-", dir=destination.parent)
    )
    backup = None
    try:
        for name, (body, mode) in blobs.items():
            target = stage / public_name(name)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(body)
            target.chmod(0o755 if mode == "100755" else 0o644)
        (stage / "SOURCE.json").write_text(
            json.dumps(manifest, indent=2, ensure_ascii=False) + "\n"
        )
        for name, digest in manifest["files"].items():
            if hashlib.sha256((stage / name).read_bytes()).hexdigest() != digest:
                raise ValueError(f"내보낸 파일의 해시가 일치하지 않습니다: {name}")
        check_destination(destination, root, sync, manifest["source_commit"])
        if destination.exists():
            backup = Path(
                tempfile.mkdtemp(
                    prefix=f".{destination.name}-previous-", dir=destination.parent
                )
            )
            backup.rmdir()
            destination.rename(backup)
            if (backup / ".git").exists():
                (backup / ".git").rename(stage / ".git")
        try:
            stage.rename(destination)
        except BaseException:
            if backup is not None:
                if (stage / ".git").exists():
                    (stage / ".git").rename(backup / ".git")
                backup.rename(destination)
                backup = None
            raise
        if backup is not None:
            shutil.rmtree(backup)
            backup = None
    finally:
        if stage.exists():
            shutil.rmtree(stage)
        # 교체 중 예외가 나면 기존 목적지를 복구한다.
        if backup is not None and not destination.exists():
            backup.rename(destination)
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path, metavar="DEST")
    parser.add_argument("--source-commit", required=True, metavar="SHA")
    parser.add_argument(
        "--sync", action="store_true", help="기존 공개 파일 교체 및 .git 보존"
    )
    args = parser.parse_args()
    try:
        result = export_snapshot(args.destination, args.source_commit, sync=args.sync)
    except (ValueError, OSError, subprocess.CalledProcessError, KeyError) as error:
        parser.exit(1, f"공개 스냅샷 생성 실패: {error}\n")
    print(f"공개 스냅샷 생성 완료: {args.destination} ({result['source_commit']})")


if __name__ == "__main__":
    main()

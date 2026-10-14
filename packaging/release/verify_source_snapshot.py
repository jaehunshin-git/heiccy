"""SOURCE.json의 과거 export 기록을 원래 공개 baseline 커밋에서 검증한다.

현재 작업트리의 파일 목록·해시와 비교하지 않는다. 퇴역한 exporter와 테스트도
baseline의 Git 객체에서 읽으며, SOURCE.json의 바이트는 변경을 허용하지 않는다.
새 앱 릴리스의 출처 검증은 verify_release.py가 담당한다. 표준 라이브러리와
읽기 전용 Git 명령만 사용하며 fetch·checkout·export를 실행하지 않는다.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import subprocess
import tomllib
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[2]
BASELINE_COMMIT = "77908397ffb24dc1881ea1f0ebfc5d9d9c977852"
VERSION = r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def matches(value: object, pattern: str) -> bool:
    return isinstance(value, str) and re.fullmatch(pattern, value) is not None


def unique_keys(pairs: list[tuple[str, object]]) -> dict:
    result = {}
    for key, value in pairs:
        require(key not in result, f"SOURCE.json 중복 필드: {key}")
        result[key] = value
    return result


def git(directory: Path, *arguments: str) -> bytes:
    """외부 Git 환경 변수와 replace 객체가 baseline 선택을 바꾸지 못하게 한다."""
    environment = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    environment["GIT_NO_LAZY_FETCH"] = "1"
    try:
        return subprocess.run(
            ["git", "--no-replace-objects", "-C", str(directory), *arguments],
            env=environment,
            check=True,
            capture_output=True,
            timeout=10,
        ).stdout
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        raise ValueError(
            "공개 baseline Git 객체를 읽을 수 없습니다. 전체 이력이 있는 checkout이 필요합니다."
        ) from error


def verify_archive_snapshot(directory: Path) -> dict:
    """보존된 SOURCE.json과 baseline의 일반 파일 해시·버전을 확인한다."""
    require(matches(BASELINE_COMMIT, r"[0-9a-f]{40}"), "잘못된 baseline SHA입니다.")
    require(
        git(directory, "rev-parse", "--show-toplevel").decode().strip()
        == str(directory.resolve()),
        "스냅샷 검증 경로는 저장소 루트여야 합니다.",
    )
    require(
        git(directory, "cat-file", "-t", BASELINE_COMMIT).strip() == b"commit",
        "baseline은 Git 커밋이어야 합니다.",
    )
    archive = git(directory, "show", f"{BASELINE_COMMIT}:SOURCE.json")
    source = directory / "SOURCE.json"
    require(
        source.is_file() and not source.is_symlink(),
        "SOURCE.json은 링크가 아닌 일반 파일이어야 합니다.",
    )
    require(source.read_bytes() == archive, "SOURCE.json의 보존 바이트 불일치")
    try:
        metadata = json.loads(archive, object_pairs_hook=unique_keys)
    except (UnicodeError, json.JSONDecodeError) as error:
        raise ValueError("잘못된 SOURCE.json입니다.") from error
    require(
        isinstance(metadata, dict)
        and set(metadata) == {"source_commit", "app_version", "py_version", "files"},
        "SOURCE.json 필드 구성이 올바르지 않습니다.",
    )
    require(
        matches(metadata["source_commit"], r"[0-9a-f]{40}"),
        "과거 내부 소스 SHA가 올바르지 않습니다.",
    )
    for field in ("app_version", "py_version"):
        require(matches(metadata[field], VERSION), f"잘못된 {field}입니다.")
    files = metadata["files"]
    require(isinstance(files, dict) and bool(files), "소스 해시 목록이 없습니다.")
    entries = {}
    for record in git(directory, "ls-tree", "-r", "-z", BASELINE_COMMIT).split(b"\0"):
        if record:
            header, name = record.split(b"\t", 1)
            mode, kind, _ = header.split()
            entries[name.decode("utf-8")] = (mode, kind)
    versions = {}
    for name, digest in files.items():
        relative = PurePosixPath(name)
        require(
            bool(name)
            and not relative.is_absolute()
            and relative.as_posix() == name
            and not any(part in {"..", ".git"} for part in relative.parts)
            and "\\" not in name
            and not any(ord(character) < 32 for character in name)
            and name != "SOURCE.json",
            "소스 해시 목록의 경로가 올바르지 않습니다.",
        )
        require(matches(digest, r"[0-9a-f]{64}"), "소스 해시가 올바르지 않습니다.")
        require(
            entries.get(name) in {(b"100644", b"blob"), (b"100755", b"blob")},
            f"baseline의 일반 파일이 필요합니다: {name}",
        )
        contents = git(directory, "show", f"{BASELINE_COMMIT}:{name}")
        require(
            hashlib.sha256(contents).hexdigest() == digest,
            f"baseline 소스 SHA-256 불일치: {name}",
        )
        if name in {"packaging/macos/Info.plist", "pyproject.toml"}:
            versions[name] = contents
    require(
        set(versions) == {"packaging/macos/Info.plist", "pyproject.toml"},
        "baseline의 앱·Python 버전 파일이 필요합니다.",
    )
    require(
        plistlib.loads(versions["packaging/macos/Info.plist"]).get(
            "CFBundleShortVersionString"
        )
        == metadata["app_version"],
        "baseline 앱 버전 불일치",
    )
    project = tomllib.loads(versions["pyproject.toml"].decode("utf-8")).get("project")
    require(
        isinstance(project, dict) and project.get("version") == metadata["py_version"],
        "baseline Python 버전 불일치",
    )
    return {"baseline_commit": BASELINE_COMMIT, "file_count": len(files), **metadata}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", nargs="?", type=Path, default=ROOT)
    args = parser.parse_args()
    try:
        result = verify_archive_snapshot(args.directory)
    except (ValueError, OSError, plistlib.InvalidFileException) as error:
        parser.exit(1, f"과거 스냅샷 검증 실패: {error}\n")
    print(
        f"과거 스냅샷 검증 완료: {result['file_count']}개 파일, "
        f"공개 baseline {result['baseline_commit']}"
    )


if __name__ == "__main__":
    main()

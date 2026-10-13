"""heiccy 1.0.0의 공식 코덱 소스를 해시 검증해 별도 배포 archive로 묶는다.

소스의 존재·무결성을 확인하며 upstream wheel의 동일 재빌드를 증명하지 않는다.
다운로드 자료는 dist 아래에만 저장하고 소스 archive를 추출·실행하지 않는다.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import os
import re
import tarfile
import tempfile
import urllib.request
from dataclasses import asdict, dataclass
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[2]
VERSION = "1.0.0"
BASENAME = f"heiccy-codec-sources-{VERSION}"
MAX_DOWNLOAD = 128 * 1024 * 1024
MAX_EXPANDED = 512 * 1024 * 1024
MAX_MEMBERS = 100_000
WHEEL = {
    "filename": "pillow_heif-1.1.1-cp312-cp312-macosx_11_0_arm64.whl",
    "sha256": "9b31fd9b5b3c3f056f98f806e2ffe0f54710700045e28f68568753e56101d2ca",
    "note": "검토 대상 wheel 식별값이며 소스에서 이 wheel을 재현했다는 증명이 아니다.",
}


@dataclass(frozen=True)
class Source:
    name: str
    version: str
    filename: str
    url: str
    sha256: str
    archive_root: str
    required_files: tuple[str, ...]


# 다운로드 전에 확정한 허용 목록. 해시 변경은 소스와 라이선스 재검토를 요구한다.
SOURCES = (
    Source(
        "pillow-heif", "1.1.1", "pillow-heif-1.1.1.tar.gz",
        "https://codeload.github.com/bigcat88/pillow_heif/tar.gz/refs/tags/v1.1.1",
        "30002bb1dabc6c020369defcc2dfb5879b0c0621e999668976e232326d3f4452",
        "pillow_heif-1.1.1",
        ("LICENSE.txt", "LICENSES_bundled.txt", "setup.py", "pyproject.toml",
         "libheif/build_libs.py", "libheif/x265_cmake_1.patch",
         "libheif/x265_cmake_2.patch", ".github/workflows/wheels-pillow_heif.yml"),
    ),
    Source(
        "libheif", "1.20.2", "libheif-1.20.2.tar.gz",
        "https://github.com/strukturag/libheif/releases/download/v1.20.2/libheif-1.20.2.tar.gz",
        "68ac9084243004e0ef3633f184eeae85d615fe7e4444373a0a21cebccae9d12a",
        "libheif-1.20.2",
        ("COPYING", "CMakeLists.txt", "libheif/api/libheif/heif.h"),
    ),
    Source(
        "libde265", "1.0.16", "libde265-1.0.16.tar.gz",
        "https://github.com/strukturag/libde265/releases/download/v1.0.16/libde265-1.0.16.tar.gz",
        "b92beb6b53c346db9a8fae968d686ab706240099cdd5aff87777362d668b0de7",
        "libde265-1.0.16",
        ("COPYING", "CMakeLists.txt", "libde265/de265.h", "libde265/COPYING"),
    ),
    Source(
        "x265", "4.1+1-1d117be",
        "x265-1d117bed4747758b51bd2c124d738527e30392cb.tar.gz",
        "https://codeload.github.com/Multicorewareinc/x265/tar.gz/"
        "1d117bed4747758b51bd2c124d738527e30392cb",
        "ddb45be97924ab3d5da78e9c436418a12f812ae856cf3547e29e2bd69edcdf82",
        "x265-1d117bed4747758b51bd2c124d738527e30392cb",
        ("COPYING", "source/CMakeLists.txt", "source/x265.h", "source/common/version.cpp",
         "x265Version.txt"),
    ),
    # upstream build_libs.py는 이 배포 tarball을 사용한다. exact commit과 함께 보존한다.
    Source(
        "x265-upstream-release", "4.1+1-1d117be", "x265_4.1.tar.gz",
        "https://bitbucket.org/multicoreware/x265_git/downloads/x265_4.1.tar.gz",
        "a31699c6a89806b74b0151e5e6a7df65de4b49050482fe5ebf8a4379d7af8f29",
        "x265_4.1",
        ("COPYING", "source/CMakeLists.txt", "source/x265.h", "source/common/version.cpp",
         "x265Version.txt"),
    ),
)


def sha256(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def regular_file(path: Path) -> None:
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"일반 파일이 필요합니다: {path}")


def safe_directory(path: Path) -> Path:
    """상위 디렉터리의 링크도 거부하며 기존 파일을 디렉터리로 덮어쓰지 않는다."""
    path = Path(os.path.abspath(path))
    for component in (*reversed(path.parents), path):
        if component.is_symlink() or (component.exists() and not component.is_dir()):
            raise ValueError(f"링크가 아닌 디렉터리가 필요합니다: {component}")
    path.mkdir(parents=True, exist_ok=True)
    return path


def validate_pins(sources: tuple[Source, ...]) -> None:
    names, filenames = set(), set()
    for source in sources:
        if source.name in names or source.filename in filenames:
            raise ValueError("소스 허용 목록에 중복 항목이 있습니다.")
        names.add(source.name)
        filenames.add(source.filename)
        if not source.url.startswith(("https://github.com/", "https://codeload.github.com/",
                                      "https://bitbucket.org/multicoreware/x265_git/downloads/")):
            raise ValueError(f"공식 HTTPS 소스 URL이 필요합니다: {source.name}")
        if not re.fullmatch(r"[0-9a-f]{64}", source.sha256):
            raise ValueError(f"고정 SHA-256이 필요합니다: {source.name}")
        if not re.fullmatch(r"[A-Za-z0-9_.-]+\.tar\.gz", source.filename):
            raise ValueError("소스 파일명은 단일 tar.gz 파일이어야 합니다.")
        if not re.fullmatch(r"[A-Za-z0-9_.-]+", source.archive_root):
            raise ValueError("소스 archive의 최상위 경로가 잘못되었습니다.")
        for name in source.required_files:
            safe_member_name(f"{source.archive_root}/{name}", source.archive_root)


def verify_hash(path: Path, expected: str) -> None:
    regular_file(path)
    if path.stat().st_size > MAX_DOWNLOAD:
        raise ValueError(f"다운로드 크기 제한 초과: {path.name}")
    actual = sha256(path)
    if actual != expected:
        raise ValueError(f"SHA-256 불일치: {path.name}, 예상 {expected}, 실제 {actual}")


def download(source: Source, cache: Path, *, offline: bool = False) -> Path:
    target = cache / source.filename
    if target.exists() or target.is_symlink():
        verify_hash(target, source.sha256)
        return target
    if offline:
        raise ValueError(f"검증할 캐시 파일이 없습니다: {source.filename}")
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=cache, delete=False) as output:
            temporary = Path(output.name)
            request = urllib.request.Request(source.url, headers={"User-Agent": "heiccy-source-collector/1.0"})
            with urllib.request.urlopen(request, timeout=60) as response:
                if not response.geturl().startswith("https://"):
                    raise ValueError("HTTPS가 아닌 다운로드 redirect는 허용하지 않습니다.")
                size = 0
                while chunk := response.read(1024 * 1024):
                    size += len(chunk)
                    if size > MAX_DOWNLOAD:
                        raise ValueError(f"다운로드 크기 제한 초과: {source.name}")
                    output.write(chunk)
        verify_hash(temporary, source.sha256)
        if target.exists() or target.is_symlink():
            raise ValueError(f"다운로드 중 대상 파일이 생겼습니다: {target}")
        temporary.replace(target)
        return target
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def safe_member_name(name: str, root: str) -> str:
    stripped = name.rstrip("/")
    parts = stripped.split("/")
    if (not stripped or "\\" in name or any(ord(c) < 32 for c in name)
            or any(p in ("", ".", "..") for p in parts)
            or PurePosixPath(stripped).is_absolute() or parts[0] != root):
        raise ValueError(f"허용되지 않은 tar 경로: {name!r}")
    return stripped


def inspect_archive(path: Path, source: Source) -> dict:
    """해시 검증 후 tar를 읽는다. 추출 없이 경로·종류·크기·핵심 파일을 확인한다."""
    verify_hash(path, source.sha256)
    required = {f"{source.archive_root}/{name}": name for name in source.required_files}
    verified, seen, files = {}, set(), 0
    expanded = 0
    try:
        with tarfile.open(path, "r:gz") as archive:
            for index, member in enumerate(archive, 1):
                if index > MAX_MEMBERS:
                    raise ValueError("tar 항목 수 제한 초과")
                name = safe_member_name(member.name, source.archive_root)
                if name in seen:
                    raise ValueError(f"tar 중복 경로: {name}")
                seen.add(name)
                # 공식 고정 archive에는 링크가 없다. 내부 링크도 명시적으로 거부한다.
                if (member.type not in (tarfile.REGTYPE, tarfile.AREGTYPE, tarfile.DIRTYPE)
                        or member.sparse is not None or member.mode & 0o7000):
                    raise ValueError(f"tar 링크·특수 파일·특권 모드 금지: {name}")
                if member.size < 0 or (member.isdir() and member.size):
                    raise ValueError(f"tar 항목 크기 오류: {name}")
                expanded += member.size
                if expanded > MAX_EXPANDED:
                    raise ValueError("tar 비압축 크기 제한 초과")
                if not member.isfile():
                    continue
                files += 1
                with archive.extractfile(member) as stream:
                    digest = hashlib.sha256()
                    read_size = 0
                    while chunk := stream.read(1024 * 1024):
                        read_size += len(chunk)
                        digest.update(chunk)
                    if read_size != member.size:
                        raise ValueError(f"tar 파일 내용이 잘렸습니다: {name}")
                if name in required:
                    if not member.size:
                        raise ValueError(f"필수 소스가 비어 있습니다: {name}")
                    verified[required[name]] = digest.hexdigest()
    except (tarfile.TarError, EOFError, OSError) as error:
        raise ValueError(f"소스 tar를 읽을 수 없습니다: {path.name}") from error
    if set(verified) != set(source.required_files):
        raise ValueError(f"필수 소스 누락: {source.name}, {sorted(set(source.required_files) - set(verified))}")
    return {"members": len(seen), "regular_files": files,
            "expanded_bytes": expanded, "required_file_sha256": verified}


def json_bytes(value: dict) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode("utf-8")


def compare_x265_sources(commit_archive: Path, release_archive: Path) -> dict:
    """검사한 두 x265 archive의 파일 경로·내용을 대조한다. 루트 이름은 제외한다."""
    def fingerprints(path: Path) -> dict:
        result = {}
        with tarfile.open(path, "r:gz") as archive:
            for member in archive:
                if member.isfile():
                    with archive.extractfile(member) as stream:
                        result[member.name.split("/", 1)[1]] = hashlib.file_digest(stream, "sha256").hexdigest()
        return result

    commit, release = fingerprints(commit_archive), fingerprints(release_archive)
    changed = sorted(name for name in commit.keys() & release.keys() if commit[name] != release[name])
    if commit.keys() != release.keys() or changed != ["x265Version.txt"]:
        raise ValueError("x265 commit 및 upstream 배포 소스의 차이가 예상과 다릅니다.")
    return {"comparison": "최상위 디렉터리를 제외한 일반 파일 경로와 SHA-256 대조",
            "changed_files": changed, "regular_files": len(commit),
            "note": "재빌드에는 버전 메타데이터가 올바른 x265_4.1.tar.gz를 사용한다."}


def add_bytes(archive: tarfile.TarFile, name: str, contents: bytes) -> None:
    info = tarfile.TarInfo(name)
    info.size = len(contents)
    info.mode = 0o644
    info.mtime = 0
    archive.addfile(info, io.BytesIO(contents))


def replace_file(path: Path, contents: bytes) -> None:
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise ValueError(f"일반 산출물 파일이 필요합니다: {path}")
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as output:
        temporary = Path(output.name)
        try:
            output.write(contents)
            output.flush()
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)


def build_bundle(output_dir: Path, *, offline: bool = False) -> Path:
    validate_pins(SOURCES)
    output_dir = safe_directory(output_dir)
    cache = safe_directory(output_dir / "build-inputs/codec-sources")
    records, paths = [], []
    for source in SOURCES:
        path = download(source, cache, offline=offline)
        record = {**asdict(source), "archive_bytes": path.stat().st_size,
                  "inspection": inspect_archive(path, source)}
        records.append(record)
        paths.append((source, path))
        print(f"소스 검증 완료: {source.name} {source.version}", flush=True)
    by_name = {source.name: path for source, path in paths}
    comparison = None
    if "x265" in by_name and "x265-upstream-release" in by_name:
        comparison = compare_x265_sources(by_name["x265"], by_name["x265-upstream-release"])
    manifest = json_bytes({
        "schema_version": 1, "app_version": VERSION, "bundle": f"{BASENAME}.tar.gz",
        "scope": "pillow-heif 및 HEVC 코덱 원본·upstream 패치·빌드 자료",
        "wheel_reference": WHEEL, "sources": records,
        "x265_source_comparison": comparison,
        "limitations": "소스 수집 및 archive 안전검사 완료. wheel 동일 재빌드·법률 준수 증명이 아님.",
    })
    target = output_dir / f"{BASENAME}.tar.gz"
    if target.is_symlink() or (target.exists() and not target.is_file()):
        raise ValueError(f"일반 산출물 파일이 필요합니다: {target}")
    with tempfile.NamedTemporaryFile(dir=output_dir, delete=False) as output:
        temporary = Path(output.name)
        try:
            # 외부 tar/gzip 메타데이터를 고정해 같은 입력으로 같은 source bundle을 만든다.
            with gzip.GzipFile(fileobj=output, mode="wb", filename="", mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode="w", format=tarfile.USTAR_FORMAT) as archive:
                    add_bytes(archive, f"{BASENAME}/sources-manifest.json", manifest)
                    add_bytes(archive, f"{BASENAME}/third-party-sources.md",
                              (ROOT / "docs/third-party-sources.md").read_bytes())
                    add_bytes(archive, f"{BASENAME}/collect_codec_sources.py", Path(__file__).read_bytes())
                    for source, path in paths:
                        # 검사 후의 캐시 변경을 다시 감지한다. 실행 중 같은 경로를 수정하지 않는다.
                        contents = path.read_bytes()
                        if hashlib.sha256(contents).hexdigest() != source.sha256:
                            raise ValueError(f"묶기 직전 소스 변경: {source.name}")
                        add_bytes(archive, f"{BASENAME}/sources/{source.filename}", contents)
            output.flush()
            temporary.replace(target)
        finally:
            temporary.unlink(missing_ok=True)
    replace_file(output_dir / f"{BASENAME}.manifest.json", manifest)
    replace_file(Path(f"{target}.sha256"), f"{sha256(target)}  {target.name}\n".encode())
    return target


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output_dir", nargs="?", type=Path, default=ROOT / "dist/macos")
    parser.add_argument("--version", choices=(VERSION,), default=VERSION,
                        help="사전 검토한 앱 버전만 허용")
    parser.add_argument("--offline", action="store_true", help="캐시만 사용하고 해시를 다시 검증")
    arguments = parser.parse_args()
    output = Path(os.path.abspath(arguments.output_dir))
    if not output.is_relative_to(ROOT / "dist"):
        parser.error("소스 archive와 build inputs는 이 저장소의 dist 아래에만 저장합니다.")
    result = build_bundle(output, offline=arguments.offline)
    print(f"소스 archive 생성 완료: {result}")


if __name__ == "__main__":
    main()

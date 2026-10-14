"""CI의 원본 DMG와 빌드 출처를 검증하고 공개 draft 준비 정보를 만든다.

manifest는 두 OS의 독립 빌드 기록이며 서명된 증명서는 아니다. 같은 Actions
실행에서 받은 파일만 허용하고, 업로드 후 이미지와 체크섬의 변조를 검출한다.
새 릴리스는 heiccy의 동일 공개 커밋과 macos-vVERSION 태그를 사용한다.
SOURCE.json은 과거 export 기록이며 새 릴리스의 출처로 사용하지 않는다.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import re
from pathlib import Path

PUBLIC_REPOSITORY = "jaehunshin-git/heiccy"
WORKFLOW = ".github/workflows/macos.yml"
RUNNERS = ("macos-15", "macos-26")
VERSION = r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def matches(value: object, pattern: str) -> bool:
    return isinstance(value, str) and re.fullmatch(pattern, value) is not None


def unique_keys(pairs: list[tuple[str, object]]) -> dict:
    result = {}
    for key, value in pairs:
        require(key not in result, f"JSON 중복 필드: {key}")
        result[key] = value
    return result


def read_json(path: Path) -> dict:
    require(
        path.is_file() and not path.is_symlink(), f"일반 JSON 파일이 필요합니다: {path}"
    )
    try:
        value = json.loads(
            path.read_text(encoding="utf-8"), object_pairs_hook=unique_keys
        )
    except (UnicodeError, json.JSONDecodeError) as error:
        raise ValueError(f"잘못된 JSON 파일: {path}") from error
    require(isinstance(value, dict), f"JSON 객체가 필요합니다: {path}")
    return value


def version_from_plist(path: Path) -> str:
    with path.open("rb") as stream:
        version = plistlib.load(stream).get("CFBundleShortVersionString")
    require(matches(version, VERSION), "앱 버전은 major.minor.patch 형식이어야 합니다.")
    return version


def validate_manifest(manifest: dict) -> None:
    require(
        set(manifest)
        == {
            "schema_version",
            "app_version",
            "source_repository",
            "source_commit",
            "artifact",
            "codec_sources",
            "provenance",
        },
        "manifest 필드 구성이 올바르지 않습니다.",
    )
    require(
        type(manifest["schema_version"]) is int and manifest["schema_version"] == 1,
        "지원하지 않는 manifest 버전입니다.",
    )
    require(matches(manifest["app_version"], VERSION), "잘못된 앱 버전입니다.")
    require(
        matches(manifest["source_commit"], r"[0-9a-f]{40}"), "잘못된 소스 SHA입니다."
    )
    require(
        manifest["source_repository"] == PUBLIC_REPOSITORY,
        "소스 저장소 불일치: 새 릴리스는 jaehunshin-git/heiccy만 허용합니다.",
    )
    artifact = manifest["artifact"]
    require(
        isinstance(artifact, dict) and set(artifact) == {"name", "sha256"},
        "잘못된 artifact 필드입니다.",
    )
    require(
        artifact["name"] == f"heiccy-{manifest['app_version']}-arm64.dmg",
        "DMG 파일명과 앱 버전이 일치하지 않습니다.",
    )
    require(matches(artifact["sha256"], r"[0-9a-f]{64}"), "잘못된 SHA-256입니다.")
    sources = manifest["codec_sources"]
    require(
        isinstance(sources, dict) and set(sources) == {"name", "sha256"},
        "잘못된 codec_sources 필드입니다.",
    )
    require(
        sources["name"] == f"heiccy-codec-sources-{manifest['app_version']}.tar.gz",
        "코덱 소스 파일명과 앱 버전이 일치하지 않습니다.",
    )
    require(
        matches(sources["sha256"], r"[0-9a-f]{64}"), "잘못된 코덱 소스 SHA-256입니다."
    )
    provenance = manifest["provenance"]
    require(
        isinstance(provenance, dict)
        and set(provenance)
        == {
            "runner",
            "architecture",
            "workflow",
            "source_ref",
            "run_id",
            "run_attempt",
        },
        "잘못된 provenance 필드입니다.",
    )
    require(provenance["runner"] in RUNNERS, "지원하지 않는 빌드 OS입니다.")
    require(provenance["architecture"] == "arm64", "arm64 빌드만 허용합니다.")
    require(provenance["workflow"] == WORKFLOW, "빌드 워크플로가 다릅니다.")
    require(matches(provenance["source_ref"], r"refs/[^\s]+"), "잘못된 소스 ref입니다.")
    for field in ("run_id", "run_attempt"):
        require(matches(provenance[field], r"[1-9][0-9]*"), f"잘못된 {field}입니다.")


def sha256(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def verify_pair(directory: Path, artifact: dict) -> tuple[Path, Path]:
    require(
        directory.is_dir() and not directory.is_symlink(),
        "일반 산출물 경로가 필요합니다.",
    )
    image = directory / artifact["name"]
    checksum = directory / f"{image.name}.sha256"
    for path in (image, checksum):
        require(
            path.is_file() and not path.is_symlink(),
            f"일반 산출물 파일이 필요합니다: {path}",
        )
    require(image.stat().st_size > 0, "빈 산출물은 허용하지 않습니다.")
    require(sha256(image) == artifact["sha256"], "산출물 SHA-256 불일치")
    try:
        contents = checksum.read_text(encoding="utf-8")
    except UnicodeError as error:
        raise ValueError("잘못된 체크섬 인코딩입니다.") from error
    require(
        contents
        in {
            f"{artifact['sha256']}  {image.name}\n",
            f"{artifact['sha256']} *{image.name}\n",
        },
        "체크섬의 SHA-256 또는 파일명이 다릅니다.",
    )
    return image, checksum


def verify_files(directory: Path, manifest: dict) -> tuple[Path, Path]:
    image, checksum = verify_pair(directory, manifest["artifact"])
    require(
        set(directory.glob("*.dmg")) == {image}, "DMG 파일이 누락되거나 중복되었습니다."
    )
    require(
        set(directory.glob("*.dmg.sha256")) == {checksum},
        "체크섬 파일이 누락되거나 중복되었습니다.",
    )
    sources, sources_checksum = verify_pair(directory, manifest["codec_sources"])
    require(
        set(directory.glob("heiccy-codec-sources-*.tar.gz")) == {sources},
        "코덱 소스 파일이 누락되거나 중복되었습니다.",
    )
    require(
        set(directory.glob("heiccy-codec-sources-*.tar.gz.sha256"))
        == {sources_checksum},
        "코덱 소스 체크섬이 누락되거나 중복되었습니다.",
    )
    return image, checksum


def create_manifest(
    directory: Path,
    plist: Path,
    *,
    runner: str,
    source_repository: str,
    source_commit: str,
    source_ref: str,
    run_id: str,
    run_attempt: str,
) -> Path:
    version = version_from_plist(plist)
    image = directory / f"heiccy-{version}-arm64.dmg"
    sources = directory / f"heiccy-codec-sources-{version}.tar.gz"
    require(image.is_file() and not image.is_symlink(), "빌드한 DMG가 없습니다.")
    require(
        sources.is_file() and not sources.is_symlink(), "코덱 소스 번들이 없습니다."
    )
    manifest = {
        "schema_version": 1,
        "app_version": version,
        "source_repository": source_repository,
        "source_commit": source_commit,
        "artifact": {"name": image.name, "sha256": sha256(image)},
        "codec_sources": {"name": sources.name, "sha256": sha256(sources)},
        "provenance": {
            "runner": runner,
            "architecture": "arm64",
            "workflow": WORKFLOW,
            "source_ref": source_ref,
            "run_id": run_id,
            "run_attempt": run_attempt,
        },
    }
    validate_manifest(manifest)
    verify_files(directory, manifest)
    target = directory / f"release-manifest-{runner}.json"
    # 재실행에서도 기존 파일이나 링크를 덮어쓰지 않는다.
    with target.open("x", encoding="utf-8") as stream:
        stream.write(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    return target


def verify_release(
    directories: dict[str, Path],
    plist: Path,
    *,
    tag: str,
    source_repository: str,
    source_commit: str,
    run_id: str,
    run_attempt: str,
) -> dict[str, str]:
    version = version_from_plist(plist)
    require(tag == f"macos-v{version}", "macOS 태그와 앱 버전이 다릅니다.")
    require(source_repository == PUBLIC_REPOSITORY, "소스 저장소 불일치")
    require(set(directories) == set(RUNNERS), "두 OS의 산출물이 모두 필요합니다.")
    result = {"version": version, "public_tag": tag}
    for runner in RUNNERS:
        directory = directories[runner]
        path = directory / f"release-manifest-{runner}.json"
        manifest = read_json(path)
        validate_manifest(manifest)
        require(manifest["app_version"] == version, "manifest 앱 버전 불일치")
        require(
            manifest["source_repository"] == source_repository, "소스 저장소 불일치"
        )
        require(manifest["source_commit"] == source_commit, "소스 SHA 불일치")
        expected = {
            "runner": runner,
            "architecture": "arm64",
            "workflow": WORKFLOW,
            "source_ref": f"refs/tags/{tag}",
            "run_id": run_id,
            "run_attempt": run_attempt,
        }
        require(manifest["provenance"] == expected, "빌드 provenance 불일치")
        image, checksum = verify_files(directory, manifest)
        result[f"manifest_{runner.removeprefix('macos-')}"] = str(path)
        if runner == "macos-15":
            sources = directory / manifest["codec_sources"]["name"]
            result.update(
                dmg=str(image),
                checksum=str(checksum),
                codec_sources=str(sources),
                codec_checksum=str(directory / f"{sources.name}.sha256"),
            )
    return result


def create_provenance(
    manifest_15: Path,
    manifest_26: Path,
    *,
    public_commit: str,
    output: Path,
) -> None:
    """두 OS가 같은 공개 커밋·태그·Actions 실행을 빌드한 기록을 첨부한다."""
    require(matches(public_commit, r"[0-9a-f]{40}"), "잘못된 공개 커밋 SHA입니다.")
    manifests = [read_json(manifest_15), read_json(manifest_26)]
    for manifest in manifests:
        validate_manifest(manifest)
    version = manifests[0]["app_version"]
    tag = f"macos-v{version}"
    for runner, manifest in zip(RUNNERS, manifests, strict=True):
        require(manifest["source_commit"] == public_commit, "공개 커밋과 빌드 SHA 불일치")
        require(manifest["app_version"] == version, "두 빌드의 앱 버전 불일치")
        expected = {
            "runner": runner,
            "architecture": "arm64",
            "workflow": WORKFLOW,
            "source_ref": f"refs/tags/{tag}",
            "run_id": manifests[0]["provenance"]["run_id"],
            "run_attempt": manifests[0]["provenance"]["run_attempt"],
        }
        require(manifest["provenance"] == expected, "빌드 provenance 불일치")
    record = {
        "schema_version": 1,
        "public_repository": PUBLIC_REPOSITORY,
        "public_source_commit": public_commit,
        "source_commit": public_commit,
        "app_version": version,
        "public_tag": tag,
        "published_runner": "macos-15",
        "build_manifests": manifests,
    }
    with output.open("x", encoding="utf-8") as stream:
        stream.write(json.dumps(record, ensure_ascii=False, indent=2) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    create = commands.add_parser("manifest", help="OS별 manifest 생성")
    create.add_argument("--directory", type=Path, required=True)
    create.add_argument("--runner", choices=RUNNERS, required=True)
    verify = commands.add_parser("verify", help="두 OS의 릴리스 산출물 검증")
    for runner in RUNNERS:
        verify.add_argument(f"--{runner}", type=Path, required=True)
    verify.add_argument("--tag", required=True)
    verify.add_argument("--output", type=Path, required=True)
    verify.add_argument("--notes-output", type=Path, required=True)
    verify.add_argument("--notes-directory", type=Path, default=Path("docs/releases"))
    for command in (create, verify):
        command.add_argument(
            "--plist", type=Path, default=Path("packaging/macos/Info.plist")
        )
        for field in ("source-repository", "source-commit", "run-id", "run-attempt"):
            command.add_argument(f"--{field}", required=True)
    create.add_argument("--source-ref", required=True)
    provenance = commands.add_parser(
        "provenance", help="동일 공개 커밋과 두 OS 빌드의 연결 기록"
    )
    provenance.add_argument("--manifest-15", type=Path, required=True)
    provenance.add_argument("--manifest-26", type=Path, required=True)
    provenance.add_argument("--public-commit", required=True)
    provenance.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.command == "provenance":
            create_provenance(
                args.manifest_15,
                args.manifest_26,
                public_commit=args.public_commit,
                output=args.output,
            )
        elif args.command == "manifest":
            create_manifest(
                args.directory,
                args.plist,
                runner=args.runner,
                source_repository=args.source_repository,
                source_commit=args.source_commit,
                source_ref=args.source_ref,
                run_id=args.run_id,
                run_attempt=args.run_attempt,
            )
        else:
            result = verify_release(
                {runner: getattr(args, runner.replace("-", "_")) for runner in RUNNERS},
                args.plist,
                tag=args.tag,
                source_repository=args.source_repository,
                source_commit=args.source_commit,
                run_id=args.run_id,
                run_attempt=args.run_attempt,
            )
            notes = (args.notes_directory / f"v{result['version']}.md").read_text(
                encoding="utf-8"
            )
            require(bool(notes.strip()), "릴리스 노트가 비어 있습니다.")
            notes += (
                "\n\n빌드 출처\n\n"
                f"- 공개 소스 저장소: https://github.com/{PUBLIC_REPOSITORY}\n"
                f"- 공개 source_commit: `{args.source_commit}`\n"
                f"- 앱 태그: `{result['public_tag']}` (위 공개 커밋과 동일)\n"
                f"- 빌드 실행: `{args.run_id}`, 시도: `{args.run_attempt}`\n"
                "- macOS 15와 26 검증을 통과한 macOS 15 arm64 DMG 원본입니다.\n"
                "- 라이선스 완전성 확인과 다운로드 검증 후 수동 공개할 draft입니다.\n"
            )
            args.notes_output.parent.mkdir(parents=True, exist_ok=True)
            args.notes_output.write_text(notes, encoding="utf-8")
            with args.output.open("a", encoding="utf-8") as stream:
                for name, value in result.items():
                    require(
                        "\n" not in value and "\r" not in value,
                        "출력값에 줄바꿈이 있습니다.",
                    )
                    stream.write(f"{name}={value}\n")
    except (ValueError, OSError, plistlib.InvalidFileException) as error:
        parser.exit(1, f"릴리스 검증 실패: {error}\n")


if __name__ == "__main__":
    main()

"""실제 파일과 CLI로 원본 산출물, 두 OS 출처와 공개 소스 연결을 검증한다."""

import copy
import hashlib
import importlib.util
import json
import os
import plistlib
import re
import subprocess
import sys
import textwrap
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SHA = "a" * 40
REPOSITORY = "jaehunshin-git/heiccy"
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
            source_repository=REPOSITORY,
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
        "source_repository": REPOSITORY,
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
    assert result["public_tag"] == "macos-v1.0.0"
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
    "tag",
    [
        "v1.0.0",
        "v0.3.0",
        "pypi-v0.3.0",
        "pypi-v1.0.0",
        "macos-v0.3.0",
        "macos-v1.0.0-extra",
    ],
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
        (("source_repository",), "internal/build"),
        (("source_repository",), "other/repo"),
        (("source_repository",), REPOSITORY + "\n"),
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
            source_repository=REPOSITORY,
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
        REPOSITORY,
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
    assert "public_tag=macos-v1.0.0\n" in output.read_text()
    assert "공개 source_commit" in body.read_text()
    assert "macos-v1.0.0" in body.read_text()
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
            SHA,
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
    assert data["public_source_commit"] == SHA
    assert data["public_repository"] == "jaehunshin-git/heiccy"
    assert data["public_tag"] == "macos-v1.0.0"
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


def provenance(validator, artifacts, output, **changes):
    arguments = {"public_commit": SHA, "output": output}
    arguments.update(changes)
    validator.create_provenance(
        manifest_path(artifacts), manifest_path(artifacts, "macos-26"), **arguments
    )


def test_public_commit_cannot_differ_from_build(validator, artifacts, tmp_path):
    output = tmp_path / "release-source.json"
    with pytest.raises(ValueError, match="공개 커밋과 빌드 SHA 불일치"):
        provenance(validator, artifacts, output, public_commit="b" * 40)
    assert not output.exists()


@pytest.mark.parametrize("runner", ["macos-15", "macos-26"])
@pytest.mark.parametrize(
    "field,value",
    [
        ("source_repository", "internal/build"),
        ("source_commit", "b" * 40),
        ("app_version", "0.3.0"),
        ("runner", "macos-15"),
        ("source_ref", "refs/tags/v1.0.0"),
        ("source_ref", "refs/pull/1/merge"),
        ("run_id", "124"),
        ("run_attempt", "2"),
    ],
)
def test_provenance_rejects_forged_builds(
    validator, artifacts, tmp_path, runner, field, value
):
    if field == "runner":
        value = "macos-26" if runner == "macos-15" else "macos-15"
    target = manifest_path(artifacts, runner)
    manifest = json.loads(target.read_text())
    section = manifest if field in manifest else manifest["provenance"]
    section[field] = value
    target.write_text(json.dumps(manifest))
    output = tmp_path / "release-source.json"
    with pytest.raises(ValueError):
        provenance(validator, artifacts, output)
    assert not output.exists()


def test_matching_foreign_repository_is_still_rejected(validator, artifacts):
    for runner in validator.RUNNERS:
        target = manifest_path(artifacts, runner)
        manifest = json.loads(target.read_text())
        manifest["source_repository"] = "other/repo"
        target.write_text(json.dumps(manifest))
    with pytest.raises(ValueError, match="소스 저장소 불일치"):
        verify(validator, artifacts, source_repository="other/repo")


def test_provenance_refuses_overwrite_and_symlink(validator, artifacts, tmp_path):
    output = tmp_path / "release-source.json"
    provenance(validator, artifacts, output)
    before = output.read_bytes()
    with pytest.raises(FileExistsError):
        provenance(validator, artifacts, output)
    assert output.read_bytes() == before
    link = tmp_path / "link.json"
    link.symlink_to(output)
    with pytest.raises(FileExistsError):
        provenance(validator, artifacts, link)
    assert output.read_bytes() == before


@pytest.fixture
def workflow():
    path = ROOT / ".github/workflows/macos.yml"
    if not path.is_file():
        pytest.skip("sdist에는 Actions 워크플로가 포함되지 않습니다.")
    return path.read_text()


def workflow_step(workflow, name):
    match = re.search(
        rf"^      - name: {re.escape(name)}\n(.*?)(?=^      - |\Z)",
        workflow,
        re.MULTILINE | re.DOTALL,
    )
    assert match is not None
    return textwrap.dedent(match[1].split("        run: |\n", 1)[1])


def test_workflow_pr_permissions_and_release_boundary(workflow):
    validate, release = workflow.split("  release:\n", 1)
    assert "pull_request:\n" in validate
    assert "pull_request_target" not in workflow
    assert "secrets." not in workflow and "HEICCY_RELEASE_TOKEN" not in workflow
    assert "contents: write" not in validate
    assert "permissions:\n  contents: read\n" in validate
    assert "    permissions:\n      contents: read\n" in validate
    assert "    permissions:\n      contents: write\n      actions: read\n" in release
    assert workflow.count("contents: write") == 1
    assert "environment: public-release" in release
    assert "needs: validate" in release
    for condition in (
        "github.repository == 'jaehunshin-git/heiccy'",
        "github.event_name == 'push'",
        "startsWith(github.ref, 'refs/tags/macos-v')",
        "needs.validate.result == 'success'",
        "vars.HEICCY_RELEASE_ENABLED == 'true'",
    ):
        assert condition in release
    checkouts = re.findall(
        r"- (?:name:.*\n\s+)?uses: actions/checkout@[^\n]+\n(.*?)(?=^      - )",
        workflow,
        re.MULTILINE | re.DOTALL,
    )
    assert len(checkouts) == 2
    assert all("persist-credentials: false" in checkout for checkout in checkouts)
    assert "export_public" not in workflow
    assert not re.search(
        r"\bgit\s+(?:[^\n]*\s)?(?:commit|push|tag|config|add)\b", workflow
    )
    assert "twine" not in workflow and "pypa/gh-action-pypi-publish" not in workflow
    assert "tags: ['macos-v*', 'pypi-v*']" in validate
    assert not re.search(r"\$\{\{\s*github\.event\.(?:pull_request|issue)", workflow)
    assert release.count("github-token: ${{ github.token }}") == 2
    assert release.count("run-id: ${{ github.run_id }}") == 2
    assert release.count("repository: ${{ github.repository }}") == 2


@pytest.fixture
def mocked_cli(tmp_path):
    """워크플로의 실제 shell을 실행하되 Git·GitHub 원격 쓰기는 모의 도구로 막는다."""
    binary = tmp_path / "bin"
    binary.mkdir()
    log = tmp_path / "commands.jsonl"
    stub = f"#!{sys.executable}\n" + textwrap.dedent("""\
        import json
        import os
        import sys
        from pathlib import Path
        name = Path(sys.argv[0]).name
        with open(os.environ["MOCK_LOG"], "a") as stream:
            stream.write(json.dumps([name, *sys.argv[1:]]) + "\\n")
        if name == "git" and sys.argv[1:4] == ["ls-remote", "--exit-code", "--tags"]:
            print(os.environ["MOCK_REFS"])
            sys.exit(0 if os.environ["MOCK_REFS"] else 2)
        if name == "gh" and sys.argv[1] == "api":
            print(os.environ.get("MOCK_RELEASES", ""))
            sys.exit(0)
        if name == "gh" and sys.argv[1:3] == ["release", "create"]:
            sys.exit(0)
        sys.exit("예상하지 못한 원격 명령입니다.")
    """)
    for name in ("git", "gh"):
        target = binary / name
        target.write_text(stub)
        target.chmod(0o755)
    environment = {
        **os.environ,
        "PATH": f"{binary}{os.pathsep}{os.environ['PATH']}",
        "MOCK_LOG": str(log),
        "SOURCE_REPOSITORY": REPOSITORY,
        "SOURCE_COMMIT": SHA,
        "SOURCE_TAG": f"macos-v{VERSION}",
        "PUBLIC_TAG": f"macos-v{VERSION}",
        "GH_TOKEN": "fixture-token",
    }
    return environment, log


@pytest.mark.parametrize("annotated", [False, True])
@pytest.mark.parametrize(
    "change", ["none", "moved", "missing", "existing-draft", "wrong-tag"]
)
def test_remote_tag_and_draft_guard(workflow, mocked_cli, tmp_path, annotated, change):
    environment, log = mocked_cli
    tag = "refs/tags/macos-v1.0.0"
    refs = f"{SHA}\t{tag}"
    if annotated:
        refs = f"{'b' * 40}\t{tag}\n{SHA}\t{tag}^{{}}"
    if change == "moved":
        refs = refs.replace(SHA, "c" * 40)
    if change == "missing":
        refs = ""
    if change == "wrong-tag":
        environment["PUBLIC_TAG"] = "macos-v1.0.1"
    environment["MOCK_REFS"] = refs
    environment["MOCK_RELEASES"] = (
        "macos-v1.0.0"
        if change == "existing-draft"
        else "macos-v1.0.00\n$(touch escaped)"
    )
    result = subprocess.run(
        [
            "bash",
            "-c",
            workflow_step(workflow, "원격 태그 커밋 확인과 기존 draft 덮어쓰기 거부"),
        ],
        cwd=tmp_path,
        env=environment,
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert (result.returncode == 0) == (change == "none"), result.stderr
    assert not (tmp_path / "escaped").exists()
    if log.exists():
        commands = [json.loads(line) for line in log.read_text().splitlines()]
        assert all(command[1] in {"ls-remote", "api"} for command in commands)


def test_draft_creation_uses_existing_tag_and_same_commit(
    workflow, mocked_cli, tmp_path
):
    environment, log = mocked_cli
    for field in (
        "DMG",
        "CHECKSUM",
        "CODEC_SOURCES",
        "CODEC_CHECKSUM",
        "MANIFEST_15",
        "MANIFEST_26",
    ):
        environment[field] = f"fixture {field}"
    result = subprocess.run(
        ["bash", "-c", workflow_step(workflow, "검증한 원본의 draft 생성")],
        cwd=tmp_path,
        env=environment,
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert result.returncode == 0, result.stderr
    commands = [json.loads(line) for line in log.read_text().splitlines()]
    assert len(commands) == 1
    command = commands[0]
    assert command[:4] == ["gh", "release", "create", "macos-v1.0.0"]
    assert command[command.index("--repo") + 1] == REPOSITORY
    assert command[command.index("--target") + 1] == SHA
    assert "--draft" in command and "--verify-tag" in command
    assert "--clobber" not in command
    assert "fixture DMG" in command and "fixture CODEC_SOURCES" in command

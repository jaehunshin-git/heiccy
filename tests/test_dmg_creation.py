"""DMG 생성의 제한된 재시도, 진단 보존과 출력 보호 계약을 검증합니다."""

import importlib.util
import subprocess
import time
from pathlib import Path

import pytest

BUSY = b"hdiutil: create failed - Resource busy\n"


@pytest.fixture
def creator(monkeypatch):
    directory = Path(__file__).resolve().parents[1] / "packaging/macos"
    path = directory / "create_dmg.py"
    if not path.is_file():
        pytest.skip("sdist에는 macOS 패키징 스크립트가 포함되지 않습니다.")
    monkeypatch.syspath_prepend(str(directory))
    spec = importlib.util.spec_from_file_location("create_dmg", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def paths(tmp_path):
    staging = tmp_path / "공백 있는 스테이징"
    staging.mkdir()
    (staging / "heiccy.app").mkdir()
    output = tmp_path / "공백 있는 출력.dmg"
    return staging, output


@pytest.fixture
def sleeps(creator, monkeypatch):
    calls = []
    monkeypatch.setattr(time, "sleep", calls.append)
    # 구현이 직접 가져온 sleep을 사용해도 실제 대기는 하지 않는다.
    if hasattr(creator, "sleep"):
        monkeypatch.setattr(creator, "sleep", calls.append)
    return calls


def expected_command(staging, output):
    return [
        "hdiutil", "create", "-verbose", "-volname", "heiccy",
        "-srcfolder", str(staging), "-fs", "HFS+", "-format", "UDZO",
        str(output),
    ]


def assert_call(command, kwargs, staging, output):
    assert command == expected_command(staging, output)
    assert kwargs == {"check": False, "capture_output": True, "timeout": 300}


def assert_no_checksum(output):
    assert not Path(f"{output}.sha256").exists()


def test_success_preserves_bytes_logs_and_space_containing_arguments(
    creator, paths, monkeypatch, sleeps, capsys
):
    staging, output = paths
    calls = []
    stdout, stderr = b"creation progress\n", b"creation notice\n"

    def run(command, **kwargs):
        assert_call(command, kwargs, staging, output)
        calls.append(command)
        output.write_bytes(b"complete image")
        return subprocess.CompletedProcess(command, 0, stdout, stderr)

    monkeypatch.setattr(creator.subprocess, "run", run)
    assert creator.create_dmg(staging, output) is None
    assert len(calls) == 1
    assert sleeps == []
    assert output.read_bytes() == b"complete image"
    assert_no_checksum(output)
    captured = capsys.readouterr()
    log = captured.out + captured.err
    assert stdout.decode() in log
    assert stderr.decode() in log


@pytest.mark.parametrize("busy_attempts", [1, 2])
def test_resource_busy_retries_then_succeeds_after_removing_partial_output(
    creator, paths, monkeypatch, sleeps, capsys, busy_attempts
):
    staging, output = paths
    calls = []
    sibling = output.with_name("다른 이미지.dmg")
    sibling.write_bytes(b"preserve sibling")

    def run(command, **kwargs):
        assert_call(command, kwargs, staging, output)
        assert not output.exists()
        assert_no_checksum(output)
        calls.append(command)
        output.write_bytes(b"partial" if len(calls) <= busy_attempts else b"complete")
        code = 16 if len(calls) <= busy_attempts else 0
        return subprocess.CompletedProcess(
            command, code, f"attempt {len(calls)}\n".encode(), BUSY if code else b""
        )

    monkeypatch.setattr(creator.subprocess, "run", run)
    assert creator.create_dmg(staging, output) is None
    assert len(calls) == busy_attempts + 1
    assert sleeps == [2] * busy_attempts
    assert output.read_bytes() == b"complete"
    assert sibling.read_bytes() == b"preserve sibling"
    assert_no_checksum(output)
    captured = capsys.readouterr()
    log = captured.out + captured.err
    for attempt in range(1, busy_attempts + 2):
        assert f"attempt {attempt}" in log
    assert "hdiutil: create failed - Resource busy" in log


def test_resource_busy_exhausts_exactly_three_attempts_and_preserves_last_error(
    creator, paths, monkeypatch, sleeps, capsys
):
    staging, output = paths
    calls = []

    def run(command, **kwargs):
        assert_call(command, kwargs, staging, output)
        assert not output.exists()
        calls.append(command)
        output.write_bytes(b"partial")
        return subprocess.CompletedProcess(
            command, 16, f"attempt {len(calls)}\n".encode(), BUSY
        )

    monkeypatch.setattr(creator.subprocess, "run", run)
    with pytest.raises(subprocess.CalledProcessError) as failure:
        creator.create_dmg(staging, output)
    assert len(calls) == 3
    assert sleeps == [2, 2]
    assert failure.value.returncode == 16
    assert failure.value.cmd == expected_command(staging, output)
    assert failure.value.stdout == b"attempt 3\n"
    assert failure.value.stderr == BUSY
    assert not output.exists()
    assert_no_checksum(output)
    captured = capsys.readouterr()
    log = captured.out + captured.err
    for attempt in range(1, 4):
        assert f"attempt {attempt}" in log
    assert BUSY.decode() in log


@pytest.mark.parametrize(
    "stderr",
    [
        b"hdiutil: create failed - Permission denied\n",
        BUSY + b"hdiutil: create failed - Input/output error\n",
        b"Resource busy\n",
        b"hdiutil: attach failed - Resource busy\n",
        b"hdiutil: create failed - Resource busy elsewhere\n",
        b"invalid diagnostic: \xff\n",
    ],
)
def test_other_errors_do_not_retry_and_keep_raw_diagnostics(
    creator, paths, monkeypatch, sleeps, capsys, stderr
):
    staging, output = paths
    calls = []
    stdout = b"progress: \xff\n"

    def run(command, **kwargs):
        assert_call(command, kwargs, staging, output)
        calls.append(command)
        output.write_bytes(b"partial")
        return subprocess.CompletedProcess(command, 7, stdout, stderr)

    monkeypatch.setattr(creator.subprocess, "run", run)
    with pytest.raises(subprocess.CalledProcessError) as failure:
        creator.create_dmg(staging, output)
    assert len(calls) == 1
    assert sleeps == []
    assert failure.value.returncode == 7
    assert failure.value.cmd == expected_command(staging, output)
    assert failure.value.stdout == stdout
    assert failure.value.stderr == stderr
    assert not output.exists()
    assert_no_checksum(output)
    captured = capsys.readouterr()
    log = captured.out + captured.err
    assert stdout.decode(errors="replace") in log
    assert stderr.decode(errors="replace") in log


def test_timeout_propagates_same_exception_without_retry_and_cleans_partial_file(
    creator, paths, monkeypatch, sleeps
):
    staging, output = paths
    calls = []
    error = subprocess.TimeoutExpired(
        expected_command(staging, output), 300, output=b"partial log\xff", stderr=BUSY
    )

    def run(command, **kwargs):
        assert_call(command, kwargs, staging, output)
        calls.append(command)
        output.write_bytes(b"partial")
        raise error

    monkeypatch.setattr(creator.subprocess, "run", run)
    with pytest.raises(subprocess.TimeoutExpired) as failure:
        creator.create_dmg(staging, output)
    assert failure.value is error
    assert failure.value.stdout == b"partial log\xff"
    assert failure.value.stderr == BUSY
    assert len(calls) == 1
    assert sleeps == []
    assert not output.exists()
    assert_no_checksum(output)


@pytest.mark.parametrize("kind", ["file", "directory", "symlink", "dangling_symlink"])
def test_existing_output_is_rejected_before_subprocess_and_preserved(
    creator, paths, monkeypatch, sleeps, kind
):
    staging, output = paths
    target = output.with_name("보존 대상")
    target.write_bytes(b"preserve target")
    if kind == "file":
        output.write_bytes(b"existing image")
    elif kind == "directory":
        output.mkdir()
        (output / "keep.txt").write_bytes(b"preserve directory")
    else:
        output.symlink_to(target if kind == "symlink" else target.with_name("없는 대상"))

    def run(*args, **kwargs):
        pytest.fail("기존 출력이 있으면 hdiutil을 실행하면 안 됩니다.")

    monkeypatch.setattr(creator.subprocess, "run", run)
    with pytest.raises(ValueError, match="[가-힣]"):
        creator.create_dmg(staging, output)
    assert sleeps == []
    assert target.read_bytes() == b"preserve target"
    if kind == "file":
        assert output.read_bytes() == b"existing image"
    elif kind == "directory":
        assert (output / "keep.txt").read_bytes() == b"preserve directory"
    else:
        assert output.is_symlink()
        assert output.readlink() == (
            target if kind == "symlink" else target.with_name("없는 대상")
        )
    assert_no_checksum(output)


@pytest.mark.parametrize("kind", ["directory", "symlink", "dangling_symlink"])
def test_failed_attempt_never_removes_directory_or_symlink_or_retries(
    creator, paths, monkeypatch, sleeps, kind
):
    staging, output = paths
    target = output.with_name("외부 파일")
    target.write_bytes(b"preserve target")
    calls = []

    def run(command, **kwargs):
        assert_call(command, kwargs, staging, output)
        calls.append(command)
        if kind == "directory":
            output.mkdir()
            (output / "keep.txt").write_bytes(b"preserve directory")
        else:
            output.symlink_to(target if kind == "symlink" else target.with_name("없는 대상"))
        return subprocess.CompletedProcess(command, 16, b"partial log\n", BUSY)

    monkeypatch.setattr(creator.subprocess, "run", run)
    with pytest.raises(ValueError, match="[가-힣]"):
        creator.create_dmg(staging, output)
    assert len(calls) == 1
    assert sleeps == []
    assert target.read_bytes() == b"preserve target"
    if kind == "directory":
        assert (output / "keep.txt").read_bytes() == b"preserve directory"
    else:
        assert output.is_symlink()
        assert output.readlink() == (
            target if kind == "symlink" else target.with_name("없는 대상")
        )
    assert_no_checksum(output)

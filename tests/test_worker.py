"""JSONL 프로토콜의 출력 격리, 종료, 오류와 취소를 검증합니다."""

import io
import json
import subprocess
import sys
import threading

from heic_converter import worker
from heic_converter.core import convert_image
from heic_converter.service import run_batch


def request(command, **fields):
    return json.dumps({"protocol_version": 1, "job_id": "job-한글", "command": command, **fields})


def events(output):
    return [json.loads(line) for line in output.getvalue().splitlines()]


def test_process_eof_waits_for_conversion_and_stdout_is_json(tmp_path, heic_factory):
    source = heic_factory(tmp_path / "한글 공백.heic")
    data = request("prepare", files=[str(source)], output_directory=str(tmp_path / "out"))
    data += "\n" + request("run") + "\n"
    process = subprocess.run([sys.executable, "-m", "heic_converter.worker"], input=data,
                             capture_output=True, text=True, timeout=20, check=False)
    assert process.returncode == 0, process.stderr
    records = [json.loads(line) for line in process.stdout.splitlines()]
    assert [record["event"] for record in records] == [
        "prepared", "file_started", "file_succeeded", "completed",
    ]
    assert all(record["protocol_version"] == 1 and record["job_id"] == "job-한글" for record in records)
    assert records[2]["hdr_applied"] is False and records[2]["sdr_reason"]
    assert records[-1]["succeeded"] == 1 and records[-1]["remaining"] == []


def test_parent_path_error_does_not_block_cancel_or_eof(tmp_path, heic_factory):
    source = heic_factory(tmp_path / "source.heic")
    output = tmp_path / "output"
    output.mkdir()
    process = subprocess.Popen([sys.executable, "-m", "heic_converter.worker"],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True)
    try:
        process.stdin.write(request("prepare", files=[str(source)], output_directory=str(output)) + "\n")
        process.stdin.flush()
        records = [json.loads(process.stdout.readline())]
        assert records[0]["event"] == "prepared"
        output.rmdir()
        output.write_bytes(b"parent replaced by a file")
        process.stdin.write(request("run") + "\n")
        process.stdin.flush()
        records.append(json.loads(process.stdout.readline()))
        assert records[-1]["event"] == "file_started"
        process.stdin.write(request("cancel") + "\n")
        process.stdin.close()
        process.wait(timeout=10)
        records.extend(json.loads(line) for line in process.stdout.read().splitlines())
        assert process.returncode == 0, process.stderr.read()
        assert [record["event"] for record in records] == [
            "prepared", "file_started", "file_failed", "completed",
        ]
        assert records[2]["error_code"] == "output_unavailable"
        assert records[-1]["failed"] == 1
        assert output.read_bytes() == b"parent replaced by a file"
    finally:
        if process.poll() is None:
            process.kill()
        process.wait(timeout=5)
        if not process.stdin.closed:
            process.stdin.close()
        process.stdout.close()
        process.stderr.close()


def test_protocol_rejects_malformed_version_unknown_job_and_invalid_options(tmp_path):
    output = io.StringIO()
    session = worker.Worker(output)
    for line in ["{", "[]", request("run"),
                 json.dumps({"protocol_version": 2, "job_id": "job-한글", "command": "prepare"}),
                 request("prepare", files=[], output_directory=str(tmp_path), options={"jpeg_quality": True})]:
        session.handle(line)
    assert [event["error_code"] for event in events(output)] == [
        "invalid_request", "invalid_request", "unknown_job", "protocol_mismatch", "invalid_request",
    ]


def test_cancel_during_conversion_finishes_file_then_stops(tmp_path, heic_factory, monkeypatch):
    files = [heic_factory(tmp_path / f"{i}.heic") for i in range(2)]
    started = threading.Event()
    release = threading.Event()

    def blocking_converter(*args, **kwargs):
        started.set()
        assert release.wait(5)
        return convert_image(*args, **kwargs)

    def blocking_batch(*args, **kwargs):
        return run_batch(*args, converter=blocking_converter, **kwargs)

    monkeypatch.setattr(worker, "run_batch", blocking_batch)
    output = io.StringIO()
    session = worker.Worker(output)
    session.handle(request("prepare", files=[str(path) for path in files], output_directory=str(tmp_path / "out")))
    session.handle(request("run"))
    assert started.wait(5)
    session.handle(request("prepare", files=[], output_directory=str(tmp_path)))
    session.handle(request("cancel"))
    release.set()
    session.finish()
    records = events(output)
    assert any(record.get("error_code") == "busy" for record in records)
    assert records[-1]["event"] == "cancelled"
    assert records[-1]["succeeded"] == 1 and records[-1]["remaining"] == [str(files[1])]
    assert (tmp_path / "out" / "0.jpeg").is_file()
    assert not (tmp_path / "out" / "1.jpeg").exists()
    session.handle(request("run"))
    assert events(output)[-1]["error_code"] == "unknown_job"


def test_prepared_cancel_and_rejected_files_are_reported(tmp_path):
    output = io.StringIO()
    session = worker.Worker(output)
    session.handle(request("prepare", files=[str(tmp_path / "missing.heic")], output_directory=str(tmp_path / "out")))
    session.handle(request("cancel"))
    records = events(output)
    assert len(records[0]["rejected"]) == 1 and records[0]["total"] == 0
    assert records[1]["event"] == "cancelled"


def test_app_termination_signal_finishes_current_file_and_stops_next(tmp_path, heic_factory):
    import signal

    files = [heic_factory(tmp_path / f"{index}.heic") for index in range(2)]
    # 신호를 보내는 동안 실제 저장이 진행 중임을 보장하는 합성 지연입니다.
    script = """
import time
from heic_converter import worker
from heic_converter.service import run_batch
from heic_converter.core import convert_image

def convert(*args, **kwargs):
    time.sleep(0.3)
    return convert_image(*args, **kwargs)

def batch(*args, **kwargs):
    return run_batch(*args, converter=convert, **kwargs)

worker.run_batch = batch
worker.main()
"""
    with subprocess.Popen([sys.executable, "-c", script], stdin=subprocess.PIPE,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as process:
        process.stdin.write(request("prepare", files=[str(path) for path in files],
                                    output_directory=str(tmp_path / "out")) + "\n")
        process.stdin.write(request("run") + "\n")
        process.stdin.flush()
        assert json.loads(process.stdout.readline())["event"] == "prepared"
        assert json.loads(process.stdout.readline())["event"] == "file_started"
        process.send_signal(signal.SIGTERM)
        output, diagnostic = process.communicate(timeout=10)
        assert process.returncode == 0, diagnostic
        records = [json.loads(line) for line in output.splitlines()]
        assert [record["event"] for record in records] == ["file_succeeded", "cancelled"]
        assert records[-1]["succeeded"] == 1 and records[-1]["remaining"] == [str(files[1])]
        assert (tmp_path / "out" / "0.jpeg").is_file()
        assert not (tmp_path / "out" / "1.jpeg").exists()
        assert not list((tmp_path / "out").glob(".*"))


def test_python_and_native_diagnostics_do_not_pollute_json_stdout(tmp_path):
    script = """
import os
from heic_converter import worker
original = worker.Worker.handle

def diagnostic(self, line):
    print("Python 진단")
    os.write(1, b"native diagnostic\\n")
    return original(self, line)

worker.Worker.handle = diagnostic
worker.main()
"""
    process = subprocess.run(
        [sys.executable, "-c", script],
        input=request("prepare", files=[], output_directory=str(tmp_path)) + "\n",
        capture_output=True, text=True, timeout=10, check=False,
    )
    assert process.returncode == 0
    assert json.loads(process.stdout)["event"] == "prepared"
    assert "Python 진단" in process.stderr and "native diagnostic" in process.stderr


def test_worker_does_not_resolve_input_against_working_directory(tmp_path):
    output = io.StringIO()
    session = worker.Worker(output)
    session.handle(request("prepare", files=["relative.heic"], output_directory=str(tmp_path)))
    session.handle(request("prepare", files=[], output_directory="relative-output"))
    assert all(record["error_code"] == "invalid_request" for record in events(output))
    assert session.job is None


def test_late_cancel_of_completed_job_does_not_disturb_next_job(tmp_path, heic_factory):
    source = heic_factory(tmp_path / "photo.heic")
    output = io.StringIO()
    session = worker.Worker(output)
    session.handle(request("prepare", files=[str(source)], output_directory=str(tmp_path / "first")))
    session.handle(request("run"))
    session.finish()
    assert events(output)[-1]["event"] == "completed"
    session.handle(request("prepare", job_id="next-job", files=[str(source)],
                           output_directory=str(tmp_path / "next")))
    before_cancel = output.getvalue()
    session.handle(request("cancel"))
    assert output.getvalue() == before_cancel
    assert not session.cancel.is_set()
    session.handle(request("run", job_id="next-job"))
    session.finish()
    assert events(output)[-1]["event"] == "completed"
    assert events(output)[-1]["succeeded"] == 1
    assert (tmp_path / "next" / "photo.jpeg").is_file()
    # 종료 ID는 직전 작업 하나만 기억하며 실제 잘못된 요청은 계속 보고합니다.
    session.handle(request("cancel"))
    assert events(output)[-1]["error_code"] == "unknown_job"


def test_repeated_cancel_is_idempotent_but_reused_active_id_can_be_cancelled(tmp_path):
    output = io.StringIO()
    session = worker.Worker(output)
    session.handle(request("prepare", files=[], output_directory=str(tmp_path)))
    session.handle(request("cancel"))
    before_repeat = output.getvalue()
    session.handle(request("cancel"))
    assert output.getvalue() == before_repeat
    session.handle(request("prepare", files=[], output_directory=str(tmp_path)))
    session.handle(request("cancel"))
    assert [record["event"] for record in events(output)] == [
        "prepared", "cancelled", "prepared", "cancelled",
    ]
    session.handle(request("cancel", job_id="unknown-job"))
    assert events(output)[-1]["error_code"] == "unknown_job"

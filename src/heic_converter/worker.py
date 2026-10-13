"""표준 입출력을 사용하는 버전 1 JSONL 변환 worker입니다."""

from __future__ import annotations

import contextlib
import json
import os
import signal
import sys
import threading
from collections.abc import Mapping
from pathlib import Path
from typing import TextIO

from .service import (
    PreparedJob,
    ValidationError,
    options_from_mapping,
    prepare_files,
    run_batch,
)

PROTOCOL_VERSION = 1


class Worker:
    """입력 스레드를 막지 않고 한 작업씩 처리하는 프로토콜 세션입니다."""

    def __init__(self, output: TextIO) -> None:
        self.output = output
        self.write_lock = threading.Lock()
        self.state_lock = threading.Lock()
        self.job: PreparedJob | None = None
        self.job_id: str | None = None
        self.last_finished_job_id: str | None = None
        self.thread: threading.Thread | None = None
        self.cancel = threading.Event()

    def send(self, event: str, job_id: str | None, fields: Mapping[str, object]) -> None:
        """동시 출력에서도 JSON 한 줄 단위를 보존합니다."""
        message = {"protocol_version": PROTOCOL_VERSION, "job_id": job_id, "event": event, **fields}
        with self.write_lock:
            self.output.write(json.dumps(message, ensure_ascii=False) + "\n")
            self.output.flush()

    def error(self, job_id: str | None, code: str, message: str) -> None:
        self.send("error", job_id, {"error_code": code, "message": message})

    def handle(self, line: str) -> None:
        """요청 한 줄을 검증하고 준비·실행·취소 명령을 처리합니다."""
        job_id = None
        try:
            request = json.loads(line)
            if not isinstance(request, dict):
                raise ValidationError("요청은 JSON 객체여야 합니다.")
            job_id = request.get("job_id")
            if not isinstance(job_id, str) or not job_id.strip():
                raise ValidationError("비어 있지 않은 job_id가 필요합니다.")
            version = request.get("protocol_version")
            if type(version) is not int or version != PROTOCOL_VERSION:
                self.error(job_id, "protocol_mismatch", "지원하지 않는 프로토콜 버전입니다.")
                return
            command = request.get("command")
            with self.state_lock:
                if command == "prepare":
                    if self.thread is not None:
                        self.error(job_id, "busy", "이미 실행 중인 작업이 있습니다.")
                        return
                    files = request.get("files")
                    output = request.get("output_directory")
                    values = request.get("options", {})
                    if not isinstance(files, list) or not all(isinstance(p, str) and p for p in files):
                        raise ValidationError("files는 로컬 경로 문자열 배열이어야 합니다.")
                    if not isinstance(output, str) or not output:
                        raise ValidationError("output_directory 경로가 필요합니다.")
                    if not Path(output).is_absolute() or any(not Path(path).is_absolute() for path in files):
                        raise ValidationError("worker의 입력과 출력은 절대 경로여야 합니다.")
                    if not isinstance(values, dict):
                        raise ValidationError("options는 JSON 객체여야 합니다.")
                    self.job = prepare_files(
                        [Path(path) for path in files], Path(output), options_from_mapping(values),
                    )
                    self.job_id = job_id
                    self.cancel.clear()
                    self.send("prepared", job_id, {
                        "files": [str(path) for path in self.job.files],
                        "rejected": [{"source": item.source, "reason": item.reason} for item in self.job.rejected],
                        "total": len(self.job.files),
                    })
                elif command in {"run", "cancel"}:
                    if self.job is None or self.job_id != job_id:
                        # 완료 이벤트와 교차한 이전 작업의 취소는 다음 작업에 영향을 주지 않습니다.
                        if command == "cancel" and job_id == self.last_finished_job_id:
                            return
                        self.error(job_id, "unknown_job", "준비한 작업을 찾을 수 없습니다.")
                    elif command == "cancel":
                        self.cancel.set()
                        if self.thread is None:
                            self.last_finished_job_id = job_id
                            self.send("cancelled", job_id, {
                                "succeeded": 0, "skipped": 0, "failed": 0,
                                "total": len(self.job.files),
                                "remaining": [str(path) for path in self.job.files],
                            })
                            self.job = None
                    elif self.thread is not None:
                        self.error(job_id, "busy", "이미 실행 중인 작업이 있습니다.")
                    else:
                        self.thread = threading.Thread(target=self._run, args=(self.job, job_id))
                        self.thread.start()
                else:
                    raise ValidationError("command는 prepare, run, cancel 중 하나여야 합니다.")
        except (ValueError, TypeError, OSError) as exc:
            self.error(job_id if isinstance(job_id, str) else None, "invalid_request", str(exc))

    def _run(self, job: PreparedJob, job_id: str) -> None:
        try:
            def emit(event: str, fields: Mapping[str, object]) -> None:
                if event in {"completed", "cancelled"}:
                    # 최종 이벤트를 받은 클라이언트가 즉시 다음 prepare를 보낼 수 있습니다.
                    with self.state_lock:
                        self.job = None
                        self.thread = None
                        self.last_finished_job_id = job_id
                        self.send(event, job_id, fields)
                else:
                    self.send(event, job_id, fields)
            run_batch(job, emit=emit, cancel=self.cancel)
        except Exception as exc:  # noqa: BLE001 - worker 오류도 JSON 계약으로 전달합니다.
            with self.state_lock:
                self.job = None
                self.thread = None
                self.error(job_id, "worker_failed", str(exc))

    def finish(self) -> None:
        """입력 EOF는 현재 작업의 안전한 저장과 집계가 끝날 때까지 기다립니다."""
        with self.state_lock:
            thread = self.thread
        if thread is not None:
            thread.join()


def main() -> None:
    """stdout을 JSON 전용으로 확보하고 라이브러리 진단은 stderr로 보냅니다."""
    # Python print뿐 아니라 네이티브 코덱이 fd 1에 남기는 진단도 분리합니다.
    stdout_fd = sys.stdout.fileno()
    output = os.fdopen(os.dup(stdout_fd), "w", encoding="utf-8", buffering=1)
    worker = Worker(output)
    def stop(_signum: int, _frame: object) -> None:
        # 앱 종료 시에도 현재 파일의 원자 저장을 마친 뒤 자식 프로세스를 정리합니다.
        worker.cancel.set()
        raise SystemExit(0)

    previous = {number: signal.signal(number, stop) for number in (signal.SIGTERM, signal.SIGINT)}
    try:
        sys.stdout.flush()
        os.dup2(sys.stderr.fileno(), stdout_fd)
        with contextlib.redirect_stdout(sys.stderr):
            try:
                for line in sys.stdin:
                    worker.handle(line)
            finally:
                worker.finish()
    finally:
        os.dup2(output.fileno(), stdout_fd)
        output.close()
        for number, handler in previous.items():
            signal.signal(number, handler)


if __name__ == "__main__":
    main()

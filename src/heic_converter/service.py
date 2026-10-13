"""CLI와 앱이 공유하는 입력 검증 및 순차 변환 서비스입니다."""

from __future__ import annotations

import os
import stat
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from pathlib import Path
from threading import Event
from typing import cast

from .core import (
    ConflictMode,
    ConversionResult,
    MetadataMode,
    OutputConflictError,
    OutputFormat,
    choose_destination,
    convert_image,
    discover_heic_files,
    is_relative_to,
    natural_sort_key,
    output_suffix,
    plan_output_path,
)


class ValidationError(ValueError):
    """사용자가 수정할 수 있는 작업 입력 오류입니다."""


@dataclass(frozen=True)
class ConversionOptions:
    """작업 생성 시 고정하는 변환 옵션입니다."""

    output_format: OutputFormat = "jpeg"
    jpeg_quality: int = 90
    png_compression: int = 6
    metadata: MetadataMode = "safe"
    on_conflict: ConflictMode = "rename"

    def __post_init__(self) -> None:
        for name, allowed, label in (
            ("output_format", {"jpeg", "png"}, "--format 값은 jpeg 또는 png여야 합니다."),
            ("metadata", {"safe", "preserve", "strip"},
             "--metadata 값은 safe, preserve, strip 중 하나여야 합니다."),
            ("on_conflict", {"rename", "skip", "overwrite", "error"},
             "--on-conflict 값은 rename, skip, overwrite, error 중 하나여야 합니다."),
        ):
            value = getattr(self, name)
            if not isinstance(value, str) or value.casefold() not in allowed:
                raise ValidationError(label)
            object.__setattr__(self, name, value.casefold())
        for name, low, high, label in (
            ("jpeg_quality", 1, 100, "--jpeg-quality 값은 1에서 100 사이여야 합니다."),
            ("png_compression", 0, 9, "--png-compression 값은 0에서 9 사이여야 합니다."),
        ):
            value = getattr(self, name)
            if type(value) is not int or not low <= value <= high:
                raise ValidationError(label)


@dataclass(frozen=True)
class RejectedInput:
    """파일 목록에서 제외한 입력과 사용자에게 표시할 이유입니다."""

    source: str
    reason: str


@dataclass(frozen=True)
class PreparedJob:
    """검증한 파일 목록과 옵션을 보관하는 불변 작업입니다."""

    files: tuple[Path, ...]
    output_directory: Path
    options: ConversionOptions
    source_root: Path | None = None
    rejected: tuple[RejectedInput, ...] = ()


@dataclass(frozen=True)
class BatchResult:
    """완료한 파일의 집계와 취소 때문에 실행하지 않은 파일입니다."""

    succeeded: int
    skipped: int
    failed: int
    remaining: tuple[Path, ...]
    cancelled: bool

    @property
    def exit_code(self) -> int:
        """기존 CLI의 부분 실패 코드를 유지합니다."""
        return 130 if self.cancelled else (1 if self.failed else 0)


def _output_directory(path: Path) -> Path:
    destination = path.expanduser().resolve()
    if destination.exists() and not destination.is_dir():
        raise ValidationError(f"출력 경로는 디렉터리여야 합니다: {path}")
    return destination


def prepare_directory(
    input_path: Path,
    output_path: Path,
    options: ConversionOptions,
    *,
    recursive: bool = False,
) -> PreparedJob:
    """CLI의 디렉터리 구조와 출력 하위 폴더 제외 계약을 유지합니다."""
    source = input_path.expanduser().resolve()
    if not source.exists():
        raise ValidationError(f"입력 경로를 찾을 수 없습니다: {input_path}")
    if not source.is_dir():
        raise ValidationError(f"입력 경로는 디렉터리여야 합니다: {input_path}")
    destination = _output_directory(output_path)
    if source == destination:
        raise ValidationError("출력 디렉터리는 입력 디렉터리와 달라야 합니다.")
    excluded = destination if is_relative_to(destination, source) else None
    files = discover_heic_files(source, recursive=recursive, excluded_directory=excluded)
    if not files:
        raise ValidationError(f"입력 디렉터리에서 .heic 파일을 찾지 못했습니다: {input_path}")
    return PreparedJob(tuple(files), destination, options, source)


def _validate_file(path: Path) -> Path:
    expanded = path.expanduser().absolute()
    # macOS의 /tmp 같은 시스템 디렉터리 별칭은 허용하고 입력 파일의 링크만 제외합니다.
    if expanded.is_symlink():
        raise ValidationError("심볼릭 링크는 입력할 수 없습니다.")
    info = expanded.stat()
    if not stat.S_ISREG(info.st_mode):
        raise ValidationError("로컬 일반 파일만 입력할 수 있습니다.")
    if expanded.suffix.casefold() != ".heic":
        raise ValidationError(".heic 파일만 입력할 수 있습니다.")
    if not os.access(expanded, os.R_OK):
        raise PermissionError("입력 파일을 읽을 권한이 없습니다.")
    return expanded.resolve()


def prepare_files(
    files: list[Path], output_path: Path, options: ConversionOptions,
) -> PreparedJob:
    """명시한 로컬 HEIC 파일을 검증하고 결과를 한 폴더에 모읍니다."""
    destination = _output_directory(output_path)
    accepted: set[Path] = set()
    rejected: list[RejectedInput] = []
    for source in files:
        try:
            path = _validate_file(source)
            if path in accepted:
                raise ValidationError("이미 입력한 파일입니다.")
            accepted.add(path)
        except (OSError, ValidationError) as exc:
            rejected.append(RejectedInput(str(source), str(exc)))
    ordered = sorted(accepted, key=natural_sort_key)
    return PreparedJob(tuple(ordered), destination, options, rejected=tuple(rejected))


def _error_code(error: Exception, source: Path) -> str:
    if isinstance(error, NotADirectoryError):
        return "input_missing" if not source.is_file() else "output_unavailable"
    if isinstance(error, FileNotFoundError):
        return "input_missing" if not source.exists() else "output_unavailable"
    if isinstance(error, PermissionError):
        return "input_permission" if not os.access(source, os.R_OK) else "output_permission"
    if isinstance(error, FileExistsError):
        return "name_conflict"
    if isinstance(error, ValidationError):
        return "invalid_input"
    return "conversion_failed"


def run_batch(
    job: PreparedJob,
    *,
    emit: Callable[[str, Mapping[str, object]], None] | None = None,
    cancel: Event | None = None,
    converter: Callable[..., ConversionResult] = convert_image,
) -> BatchResult:
    """파일별 오류를 격리하고 현재 저장 완료 뒤 취소를 적용합니다."""
    send = emit or (lambda _event, _fields: None)
    cancellation = cancel or Event()
    succeeded = skipped = failed = processed = 0
    reserved: set[Path] = set()
    options = job.options
    for index, source in enumerate(job.files, start=1):
        if cancellation.is_set():
            break
        fields: dict[str, object] = {"source": str(source), "index": index, "total": len(job.files)}
        send("file_started", fields)
        try:
            _validate_file(source)
            proposed = (
                plan_output_path(source, job.source_root, job.output_directory, options.output_format)
                if job.source_root else
                job.output_directory / source.with_suffix(output_suffix(options.output_format)).name
            )
            while True:
                destination = choose_destination(proposed, options.on_conflict, reserved=reserved)
                if destination is None:
                    skipped += 1
                    send("file_skipped", {**fields, "reason": "같은 이름의 출력 파일이 있습니다."})
                    break
                try:
                    result = converter(
                        source, destination, output_format=options.output_format,
                        jpeg_quality=options.jpeg_quality, png_compression=options.png_compression,
                        metadata=options.metadata, overwrite=options.on_conflict == "overwrite",
                    )
                except FileExistsError as exc:
                    reserved.discard(destination)
                    # 원자적 결과 저장에서 발생한 목적지 충돌만 재시도합니다.
                    # 기존 converter의 일반 FileExistsError는 실제 목적지로 확인합니다.
                    if not isinstance(exc, OutputConflictError) and not (
                        destination.exists() or destination.is_symlink()
                    ):
                        raise
                    if options.on_conflict == "rename":
                        continue
                    if options.on_conflict == "skip":
                        skipped += 1
                        send("file_skipped", {**fields, "reason": "저장 중 같은 이름의 파일이 생성되었습니다."})
                        break
                    raise
                except Exception:
                    reserved.discard(destination)
                    raise
                succeeded += 1
                send("file_succeeded", {
                    **fields, "destination": str(destination),
                    "hdr_applied": result.hdr_applied, "sdr_reason": result.sdr_reason,
                })
                break
        except Exception as exc:  # noqa: BLE001 - 파일 단위 오류를 격리합니다.
            failed += 1
            send("file_failed", {**fields, "error": str(exc), "error_code": _error_code(exc, source)})
        processed = index
    remaining = job.files[processed:]
    result = BatchResult(succeeded, skipped, failed, remaining, bool(remaining and cancellation.is_set()))
    send("cancelled" if result.cancelled else "completed", {
        "succeeded": succeeded, "skipped": skipped, "failed": failed,
        "total": len(job.files), "remaining": [str(path) for path in remaining],
    })
    return result


def options_from_mapping(values: Mapping[str, object]) -> ConversionOptions:
    """JSON 요청에서도 동일한 옵션 검증을 사용합니다."""
    allowed = {"output_format", "jpeg_quality", "png_compression", "metadata", "on_conflict"}
    if set(values) - allowed:
        raise ValidationError("지원하지 않는 변환 옵션입니다.")
    return ConversionOptions(**cast(dict, dict(values)))

"""한국어 명령줄 인터페이스입니다."""

from __future__ import annotations

import sys
from pathlib import Path
from typing import cast

import typer
from rich.console import Console

from .core import (
    ConflictMode,
    MetadataMode,
    OutputFormat,
    convert_image,
)
from .service import ConversionOptions, ValidationError, prepare_directory, run_batch
from .tui import TuiConfig, collect_tui_config

app = typer.Typer(
    add_completion=False,
    help="HEIC 이미지를 JPEG 또는 PNG로 일괄 변환합니다.",
    no_args_is_help=False,
    context_settings={"help_option_names": []},
)
console = Console()
error_console = Console(stderr=True)


def _show_help(context: typer.Context, _: typer.CallbackParam, value: bool) -> None:
    """한국어 설명을 포함한 도움말을 표시합니다."""

    if value:
        typer.echo(context.get_help())
        context.exit()


def _invalid(message: str) -> None:
    """사용자 입력 오류를 표시하고 종료 코드 2로 끝냅니다."""

    error_console.print(f"[red]오류:[/red] {message}")
    raise typer.Exit(code=2)


def _resolve_format(value: str | None) -> OutputFormat:
    """출력 형식을 검증합니다."""

    if value is None:
        _invalid("비대화형 실행에서는 --format jpeg 또는 --format png가 필요합니다.")
    normalized = value.casefold()
    if normalized not in {"jpeg", "png"}:
        _invalid("--format 값은 jpeg 또는 png여야 합니다.")
    return cast(OutputFormat, normalized)


def _terminal_supports_tui() -> bool:
    """입력과 출력이 모두 실제 터미널에 연결되었는지 확인합니다."""

    return sys.stdin.isatty() and sys.stdout.isatty()


def _validate_option_values(
    *,
    jpeg_quality: int,
    png_compression: int,
    metadata: str,
    on_conflict: str,
) -> tuple[str, str]:
    """공통 옵션을 검증하고 정규화된 정책 값을 반환합니다."""

    try:
        options = ConversionOptions(
            jpeg_quality=jpeg_quality, png_compression=png_compression,
            metadata=metadata, on_conflict=on_conflict,
        )
    except ValidationError as exc:
        _invalid(str(exc))
    return options.metadata, options.on_conflict


def _open_tui(
    *,
    input_path: Path,
    output_path: Path,
    output_format: str | None,
    jpeg_quality: int,
    png_compression: int,
    recursive: bool,
    metadata: str,
    on_conflict: str,
) -> TuiConfig:
    """대화형 TUI를 열고 취소 시 종료 코드 130으로 끝냅니다."""

    config = collect_tui_config(
        input_path=input_path,
        output_path=output_path,
        output_format=cast(OutputFormat | None, output_format),
        jpeg_quality=jpeg_quality,
        png_compression=png_compression,
        recursive=recursive,
        metadata=cast(MetadataMode, metadata.casefold()),
        on_conflict=cast(ConflictMode, on_conflict.casefold()),
    )
    if config is None:
        raise typer.Exit(code=130)
    return config


@app.command()
def main(
    input_path: Path = typer.Option(
        Path("./input"), "--input", "-i", help="입력 HEIC 디렉터리"
    ),
    output_path: Path = typer.Option(
        Path("./output"), "--output", "-o", help="출력 디렉터리"
    ),
    output_format: str | None = typer.Option(
        None, "--format", "-f", help="출력 형식: jpeg 또는 png"
    ),
    jpeg_quality: int = typer.Option(
        90, "--jpeg-quality", help="JPEG 품질(1~100)"
    ),
    png_compression: int = typer.Option(
        6, "--png-compression", help="PNG 압축 수준(0~9)"
    ),
    recursive: bool = typer.Option(False, "--recursive", help="하위 디렉터리를 포함"
    ),
    metadata: str = typer.Option(
        "safe", "--metadata", help="메타데이터: safe, preserve, strip"
    ),
    on_conflict: str = typer.Option(
        "rename", "--on-conflict", help="충돌 처리: rename, skip, overwrite, error"
    ),
    help_: bool = typer.Option(
        False,
        "--help",
        "-h",
        is_eager=True,
        callback=_show_help,
        help="도움말을 표시하고 종료합니다.",
    ),
) -> None:
    """입력 경로의 HEIC 파일을 변환합니다."""

    metadata_value, conflict_value = _validate_option_values(
        jpeg_quality=jpeg_quality,
        png_compression=png_compression,
        metadata=metadata,
        on_conflict=on_conflict,
    )
    if output_format is None and _terminal_supports_tui():
        tui_config = _open_tui(
            input_path=input_path,
            output_path=output_path,
            output_format=output_format,
            jpeg_quality=jpeg_quality,
            png_compression=png_compression,
            recursive=recursive,
            metadata=metadata,
            on_conflict=on_conflict,
        )
        input_path = tui_config.input_path
        output_path = tui_config.output_path
        output_format = tui_config.output_format
        jpeg_quality = tui_config.jpeg_quality
        png_compression = tui_config.png_compression
        recursive = tui_config.recursive
        metadata = tui_config.metadata
        on_conflict = tui_config.on_conflict

    output_format = _resolve_format(output_format)
    metadata_value = metadata.casefold()
    conflict_value = on_conflict.casefold()

    try:
        options = ConversionOptions(
            output_format=output_format, jpeg_quality=jpeg_quality,
            png_compression=png_compression, metadata=metadata_value,
            on_conflict=conflict_value,
        )
        job = prepare_directory(input_path, output_path, options, recursive=recursive)
    except ValidationError as exc:
        _invalid(str(exc))
    console.print(f"발견한 HEIC 파일: {len(job.files)}개")

    def show_event(event: str, fields: object) -> None:
        values = cast(dict, fields)
        if event == "file_succeeded":
            console.print(f"변환: {values['source']} → {values['destination']}")
        elif event == "file_skipped":
            console.print(f"건너뜀: {values['source']}")
        elif event == "file_failed":
            error_console.print(f"[red]실패:[/red] {values['source']} — {values['error']}")

    result = run_batch(job, emit=show_event, converter=convert_image)
    console.print(f"요약: 성공 {result.succeeded}개, 건너뜀 {result.skipped}개, 실패 {result.failed}개")
    if result.exit_code:
        raise typer.Exit(code=result.exit_code)


def run() -> None:
    """설치형 콘솔 스크립트의 진입점입니다."""

    app()

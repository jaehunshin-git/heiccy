"""Arrow-key terminal UI for collecting HEIC conversion settings."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any, Literal, cast

from .core import ConflictMode, MetadataMode, OutputFormat

try:
    import questionary
except ModuleNotFoundError:  # Keep public APIs importable before installation.
    questionary: Any | None = None

UiLanguage = Literal["ko", "en"]


@dataclass(frozen=True)
class TuiConfig:
    """Settings confirmed in the interactive UI."""

    input_path: Path
    output_path: Path
    output_format: OutputFormat
    jpeg_quality: int
    png_compression: int
    recursive: bool
    metadata: MetadataMode
    on_conflict: ConflictMode


_TEXT: dict[UiLanguage, dict[str, str]] = {
    "ko": {
        "title": "HEIC 이미지 변환 설정",
        "welcome": "↑/↓ 방향키로 선택하고 Enter로 확정합니다. Ctrl+C로 언제든 취소합니다.",
        "language": "언어 / Language",
        "input": "입력 디렉터리 경로",
        "output": "출력 디렉터리 경로",
        "format": "출력 형식",
        "jpeg_quality": "JPEG 품질",
        "png_compression": "PNG 압축 수준",
        "recursive": "하위 디렉터리도 변환할까요?",
        "metadata": "메타데이터 처리",
        "conflict": "같은 이름의 출력 파일이 있을 때",
        "confirm": "이 설정으로 변환을 시작할까요?",
        "input_instruction": "Enter로 다음 단계로 이동",
        "select_instruction": "↑/↓ 방향키로 이동 · Enter로 선택",
        "missing_input": "입력 디렉터리 경로를 입력하세요.",
        "input_not_found": "입력 디렉터리를 찾을 수 없습니다.",
        "input_not_directory": "입력 경로는 디렉터리여야 합니다.",
        "missing_output": "출력 디렉터리 경로를 입력하세요.",
        "output_not_directory": "출력 경로에 이미 파일이 있습니다. 디렉터리 경로를 입력하세요.",
        "summary": "설정 요약",
        "summary_input": "입력 디렉터리",
        "summary_output": "출력 디렉터리",
        "summary_format": "출력 형식",
        "summary_recursive": "하위 디렉터리 포함",
        "summary_metadata": "메타데이터",
        "summary_conflict": "파일 충돌 처리",
        "yes": "예",
        "no": "아니요",
        "unselected": "미선택",
        "jpeg_detail": "JPEG 품질 {value}",
        "png_detail": "PNG 압축 {value}",
        "cancelled": "변환을 취소했습니다.",
    },
    "en": {
        "title": "HEIC conversion settings",
        "welcome": "Use the ↑/↓ arrow keys to choose, Enter to confirm, and Ctrl+C to cancel at any time.",
        "language": "Language / 언어",
        "input": "Input directory path",
        "output": "Output directory path",
        "format": "Output format",
        "jpeg_quality": "JPEG quality",
        "png_compression": "PNG compression level",
        "recursive": "Include subdirectories?",
        "metadata": "Metadata handling",
        "conflict": "When an output file has the same name",
        "confirm": "Start conversion with these settings?",
        "input_instruction": "Press Enter to continue",
        "select_instruction": "Use ↑/↓ to move · Enter to select",
        "missing_input": "Enter an input directory path.",
        "input_not_found": "Input directory not found.",
        "input_not_directory": "The input path must be a directory.",
        "missing_output": "Enter an output directory path.",
        "output_not_directory": "The output path is an existing file. Enter a directory path.",
        "summary": "Configuration summary",
        "summary_input": "Input directory",
        "summary_output": "Output directory",
        "summary_format": "Output format",
        "summary_recursive": "Include subdirectories",
        "summary_metadata": "Metadata",
        "summary_conflict": "File conflict handling",
        "yes": "Yes",
        "no": "No",
        "unselected": "Not selected",
        "jpeg_detail": "JPEG quality {value}",
        "png_detail": "PNG compression {value}",
        "cancelled": "Conversion cancelled.",
    },
}


def _questionary() -> Any:
    """Return the UI library or raise an actionable installation error."""

    if questionary is None:
        message = "The interactive UI requires questionary>=2.0.1."
        raise RuntimeError(message)
    return questionary


def _input_directory_validator(value: str, language: UiLanguage = "ko") -> bool | str:
    """Validate that an input value points to an existing directory."""

    text = _TEXT[language]
    path = Path(value).expanduser()
    if not value.strip():
        return text["missing_input"]
    if not path.exists():
        return text["input_not_found"]
    if not path.is_dir():
        return text["input_not_directory"]
    return True


def _output_directory_validator(value: str, language: UiLanguage = "ko") -> bool | str:
    """Validate that an output value is a new or existing directory."""

    text = _TEXT[language]
    path = Path(value).expanduser()
    if not value.strip():
        return text["missing_output"]
    if path.exists() and not path.is_dir():
        return text["output_not_directory"]
    return True


def _ask_text(
    message: str, default: Path, validator: Any, instruction: str
) -> str | None:
    """Display a text input prompt."""

    answer = _questionary().text(
        message,
        default=str(default),
        validate=validator,
        instruction=instruction,
    ).ask()
    return cast(str | None, answer)


def _ask_select(
    message: str, choices: list[tuple[str, Any]], default: Any, instruction: str
) -> Any:
    """Display an arrow-key selection prompt."""

    ui = _questionary()
    menu_choices = [
        ui.Choice(title, value=value) for title, value in choices
    ]
    prompt = ui.select(
        message,
        choices=menu_choices,
        default=default,
        instruction=instruction,
        style=ui.Style([("highlighted", "reverse")]),
    )

    # Questionary는 select의 default를 초기 커서 위치와 고정 선택 상태에 동시에
    # 사용한다. 고정 상태를 비워야 현재 커서 행의 배경 강조가 방향키를 따라간다.
    application = getattr(prompt, "application", None)
    layout = getattr(application, "layout", None)
    if layout is not None:
        for control in layout.find_all_controls():
            selected_options = getattr(control, "selected_options", None)
            if isinstance(selected_options, list):
                selected_options.clear()

    return prompt.ask()


def _metadata_choices(language: UiLanguage) -> list[tuple[str, MetadataMode]]:
    """Return localized metadata policy choices with stable internal values."""

    if language == "ko":
        return [
            ("안전하게 유지 (권장) — GPS 등 민감 정보는 제거", "safe"),
            ("원본 유지 — 가능한 메타데이터를 보존", "preserve"),
            ("모두 제거 — 메타데이터를 저장하지 않음", "strip"),
        ]
    return [
        ("Keep safely (recommended) — remove sensitive data such as GPS", "safe"),
        ("Preserve original — retain metadata where possible", "preserve"),
        ("Strip all — do not write metadata", "strip"),
    ]


def _conflict_choices(language: UiLanguage) -> list[tuple[str, ConflictMode]]:
    """Return localized output-conflict choices with stable internal values."""

    if language == "ko":
        return [
            ("이름 변경 (권장) — 번호를 붙여 새 파일 생성", "rename"),
            ("건너뛰기 — 기존 파일 유지", "skip"),
            ("덮어쓰기 — 기존 파일 교체", "overwrite"),
            ("오류로 기록 — 충돌을 알림", "error"),
        ]
    return [
        ("Rename (recommended) — create a numbered filename", "rename"),
        ("Skip — keep the existing file", "skip"),
        ("Overwrite — replace the existing file", "overwrite"),
        ("Record an error — report the conflict", "error"),
    ]


def _display_value(
    language: UiLanguage, value: MetadataMode | ConflictMode
) -> str:
    """Return a concise localized display label for a selected policy."""

    values = {
        "ko": {
            "safe": "안전하게 유지",
            "preserve": "원본 유지",
            "strip": "모두 제거",
            "rename": "이름 변경",
            "skip": "건너뛰기",
            "overwrite": "덮어쓰기",
            "error": "오류로 기록",
        },
        "en": {
            "safe": "Keep safely",
            "preserve": "Preserve original",
            "strip": "Strip all",
            "rename": "Rename",
            "skip": "Skip",
            "overwrite": "Overwrite",
            "error": "Record an error",
        },
    }
    return values[language][value]


def _print_summary(config: TuiConfig, language: UiLanguage) -> None:
    """Print a localized summary for review before conversion starts."""

    text = _TEXT[language]
    format_label = config.output_format.upper() if config.output_format else text["unselected"]
    detail_template = "jpeg_detail" if config.output_format == "jpeg" else "png_detail"
    detail_value = config.jpeg_quality if config.output_format == "jpeg" else config.png_compression
    detail = text[detail_template].format(value=detail_value)
    print(f"\n{text['summary']}")
    print(f"  {text['summary_input']}: {config.input_path}")
    print(f"  {text['summary_output']}: {config.output_path}")
    print(f"  {text['summary_format']}: {format_label} ({detail})")
    print(f"  {text['summary_recursive']}: {text['yes'] if config.recursive else text['no']}")
    print(f"  {text['summary_metadata']}: {_display_value(language, config.metadata)}")
    print(f"  {text['summary_conflict']}: {_display_value(language, config.on_conflict)}")


def _cancel(language: UiLanguage | None) -> None:
    """Print a localized cancellation message, or a bilingual message before selection."""

    message = _TEXT[language]["cancelled"] if language else "Cancelled / 변환을 취소했습니다."
    print(message)


def collect_tui_config(
    input_path: Path = Path("./input"),
    output_path: Path = Path("./output"),
    output_format: OutputFormat | None = None,
    jpeg_quality: int = 90,
    png_compression: int = 6,
    recursive: bool = False,
    metadata: MetadataMode = "safe",
    on_conflict: ConflictMode = "rename",
) -> TuiConfig | None:
    """Collect interactive settings in Korean or English; return ``None`` if cancelled."""

    language: UiLanguage | None = None
    try:
        print("\nHEIC Converter TUI")
        selected_language = _ask_select(
            "언어 / Language",
            [("한국어", "ko"), ("English", "en")],
            "ko",
            "↑/↓ / Arrow keys · Enter",
        )
        if selected_language is None:
            _cancel(None)
            return None
        language = cast(UiLanguage, selected_language)
        text = _TEXT[language]
        print(f"\n{text['title']}")
        print(f"{text['welcome']}\n")

        input_answer = _ask_text(
            text["input"],
            input_path,
            lambda value: _input_directory_validator(value, language),
            text["input_instruction"],
        )
        if input_answer is None:
            _cancel(language)
            return None

        output_answer = _ask_text(
            text["output"],
            output_path,
            lambda value: _output_directory_validator(value, language),
            text["input_instruction"],
        )
        if output_answer is None:
            _cancel(language)
            return None

        selected_format = _ask_select(
            text["format"],
            [("JPEG", "jpeg"), ("PNG", "png")],
            output_format or "jpeg",
            text["select_instruction"],
        )
        if selected_format is None:
            _cancel(language)
            return None
        format_value = cast(OutputFormat, selected_format)

        quality_value = jpeg_quality
        compression_value = png_compression
        if format_value == "jpeg":
            quality_choices = (
                [
                    ("최고 품질 (100)", 100),
                    ("매우 높음 (95)", 95),
                    ("높음 (90)", 90),
                    ("균형 (85)", 85),
                    ("작은 파일 (80)", 80),
                ]
                if language == "ko"
                else [
                    ("Highest quality (100)", 100),
                    ("Very high (95)", 95),
                    ("High (90)", 90),
                    ("Balanced (85)", 85),
                    ("Smaller file (80)", 80),
                ]
            )
            selected_quality = _ask_select(
                text["jpeg_quality"],
                quality_choices,
                jpeg_quality if jpeg_quality in {100, 95, 90, 85, 80} else 90,
                text["select_instruction"],
            )
            if selected_quality is None:
                _cancel(language)
                return None
            quality_value = cast(int, selected_quality)
        else:
            compression_choices = (
                [
                    ("압축 없음 (0)", 0),
                    ("낮음 (3)", 3),
                    ("기본 (6)", 6),
                    ("최대 (9)", 9),
                ]
                if language == "ko"
                else [
                    ("No compression (0)", 0),
                    ("Low (3)", 3),
                    ("Default (6)", 6),
                    ("Maximum (9)", 9),
                ]
            )
            selected_compression = _ask_select(
                text["png_compression"],
                compression_choices,
                png_compression if png_compression in {0, 3, 6, 9} else 6,
                text["select_instruction"],
            )
            if selected_compression is None:
                _cancel(language)
                return None
            compression_value = cast(int, selected_compression)

        recursive_choices = (
            [("예 — 하위 디렉터리 포함", True), ("아니요 — 현재 디렉터리만", False)]
            if language == "ko"
            else [("Yes — include subdirectories", True), ("No — current directory only", False)]
        )
        recursive_value = _ask_select(
            text["recursive"], recursive_choices, recursive, text["select_instruction"]
        )
        if recursive_value is None:
            _cancel(language)
            return None

        metadata_value = _ask_select(
            text["metadata"],
            _metadata_choices(language),
            metadata,
            text["select_instruction"],
        )
        if metadata_value is None:
            _cancel(language)
            return None

        conflict_value = _ask_select(
            text["conflict"],
            _conflict_choices(language),
            on_conflict,
            text["select_instruction"],
        )
        if conflict_value is None:
            _cancel(language)
            return None

        config = TuiConfig(
            input_path=Path(input_answer).expanduser(),
            output_path=Path(output_answer).expanduser(),
            output_format=format_value,
            jpeg_quality=quality_value,
            png_compression=compression_value,
            recursive=cast(bool, recursive_value),
            metadata=cast(MetadataMode, metadata_value),
            on_conflict=cast(ConflictMode, conflict_value),
        )
        _print_summary(config, language)
        should_start = _ask_select(
            text["confirm"],
            [("시작", True), ("취소", False)]
            if language == "ko"
            else [("Start", True), ("Cancel", False)],
            True,
            text["select_instruction"],
        )
        if should_start is not True:
            _cancel(language)
            return None
        return config
    except (KeyboardInterrupt, EOFError):
        _cancel(language)
        return None

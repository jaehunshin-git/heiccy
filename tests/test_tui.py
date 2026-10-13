"""대화형 터미널 UI의 설정 수집 계약을 검증합니다."""

from __future__ import annotations

from types import SimpleNamespace
from typing import Any

import pytest

from heic_converter import tui
from heic_converter.tui import TuiConfig


class _Answer:
    """questionary 질문 객체가 돌려주는 최소 응답 인터페이스입니다."""

    def __init__(self, value: Any) -> None:
        self.value = value

    def ask(self) -> Any:
        """주입된 응답을 실제 터미널 없이 반환합니다."""

        return self.value


class _QuestionaryStub:
    """질문 메시지별 응답을 돌려주는 questionary 대역입니다."""

    def __init__(self, answers: dict[str, Any]) -> None:
        self.answers = {
            message: iter(value) if isinstance(value, list) else iter((value,))
            for message, value in answers.items()
        }
        self.calls: list[tuple[str, str, dict[str, Any]]] = []

    def _answer(self, message: str) -> Any:
        try:
            return next(self.answers[message])
        except KeyError as error:
            raise AssertionError(f"예상하지 못한 질문입니다: {message}") from error
        except StopIteration as error:
            raise AssertionError(f"질문의 응답이 부족합니다: {message}") from error

    def text(self, message: str, **kwargs: Any) -> _Answer:
        """텍스트 질문의 사전 주입 응답을 반환합니다."""

        self.calls.append(("text", message, kwargs))
        return _Answer(self._answer(message))

    def select(self, message: str, **kwargs: Any) -> _Answer:
        """선택 질문의 사전 주입 응답을 반환합니다."""

        self.calls.append(("select", message, kwargs))
        return _Answer(self._answer(message))

    class Choice:
        """선택지 생성만 허용하는 최소 Choice 대역입니다."""

        def __init__(self, title: str, value: Any) -> None:
            self.title = title
            self.value = value

    @staticmethod
    def Style(rules: list[tuple[str, str]]) -> list[tuple[str, str]]:
        """스타일 규칙을 그대로 보관하는 최소 Style 대역입니다."""

        return rules


def patch_questionary(monkeypatch, answers: dict[str, Any]) -> _QuestionaryStub:
    """메시지별 응답을 제공하는 questionary 대역을 설치합니다."""

    stub = _QuestionaryStub(answers)
    monkeypatch.setattr(
        tui,
        "questionary",
        SimpleNamespace(
            text=stub.text,
            select=stub.select,
            Choice=stub.Choice,
            Style=stub.Style,
        ),
    )
    return stub


def test_select_highlight_follows_cursor(monkeypatch):
    """기본값의 고정 강조를 없애고 현재 커서 행만 역상으로 강조합니다."""

    questionary = tui._questionary()
    real_select = questionary.select
    captured_prompt: list[Any] = []

    def select_without_terminal(*args: Any, **kwargs: Any) -> Any:
        prompt = real_select(*args, **kwargs)
        monkeypatch.setattr(prompt, "ask", lambda: "png")
        captured_prompt.append(prompt)
        return prompt

    monkeypatch.setattr(questionary, "select", select_without_terminal)

    assert (
        tui._ask_select(
            "형식",
            [("JPEG", "jpeg"), ("PNG", "png")],
            "jpeg",
            "방향키로 이동",
        )
        == "png"
    )

    prompt = captured_prompt[0]
    selection_control = next(
        control
        for control in prompt.application.layout.find_all_controls()
        if hasattr(control, "selected_options")
    )
    assert selection_control.selected_options == []
    assert ("class:highlighted", "JPEG") in selection_control._get_choice_tokens()

    selection_control.select_next()

    assert ("class:highlighted", "PNG") in selection_control._get_choice_tokens()
    highlighted = prompt.application.style.get_attrs_for_style_str("class:highlighted")
    assert highlighted.reverse is True


def test_collects_all_jpeg_settings(tmp_path, monkeypatch):
    """JPEG를 선택하면 품질을 포함한 전체 설정을 확정합니다."""

    source = tmp_path / "input"
    source.mkdir()
    destination = tmp_path / "output"
    patch_questionary(
        monkeypatch,
        {
            "언어 / Language": "ko",
            "입력 디렉터리 경로": str(source),
            "출력 디렉터리 경로": str(destination),
            "출력 형식": "jpeg",
            "JPEG 품질": 85,
            "하위 디렉터리도 변환할까요?": True,
            "메타데이터 처리": "preserve",
            "같은 이름의 출력 파일이 있을 때": "overwrite",
            "이 설정으로 변환을 시작할까요?": True,
        },
    )

    config = tui.collect_tui_config(png_compression=3)

    assert config == tui.TuiConfig(
        input_path=source,
        output_path=destination,
        output_format="jpeg",
        jpeg_quality=85,
        png_compression=3,
        recursive=True,
        metadata="preserve",
        on_conflict="overwrite",
    )


def test_collects_png_compression_when_png_is_selected(tmp_path, monkeypatch):
    """PNG를 선택하면 JPEG 품질 대신 PNG 압축 수준을 수집합니다."""

    source = tmp_path / "input"
    source.mkdir()
    destination = tmp_path / "output"
    patch_questionary(
        monkeypatch,
        {
            "언어 / Language": "ko",
            "입력 디렉터리 경로": str(source),
            "출력 디렉터리 경로": str(destination),
            "출력 형식": "png",
            "PNG 압축 수준": 9,
            "하위 디렉터리도 변환할까요?": False,
            "메타데이터 처리": "safe",
            "같은 이름의 출력 파일이 있을 때": "rename",
            "이 설정으로 변환을 시작할까요?": True,
        },
    )

    config = tui.collect_tui_config(jpeg_quality=95)

    assert config == tui.TuiConfig(
        input_path=source,
        output_path=destination,
        output_format="png",
        jpeg_quality=95,
        png_compression=9,
        recursive=False,
        metadata="safe",
        on_conflict="rename",
    )


def test_english_selection_localizes_every_tui_prompt_and_summary(
    tmp_path, monkeypatch, capsys
):
    """영어를 고르면 언어 선택 뒤의 질문·안내·요약이 모두 영어가 됩니다."""

    source = tmp_path / "input"
    source.mkdir()
    destination = tmp_path / "output"
    stub = patch_questionary(
        monkeypatch,
        {
            "언어 / Language": "en",
            "Input directory path": str(source),
            "Output directory path": str(destination),
            "Output format": "png",
            "PNG compression level": 9,
            "Include subdirectories?": True,
            "Metadata handling": "strip",
            "When an output file has the same name": "skip",
            "Start conversion with these settings?": True,
        },
    )

    config = tui.collect_tui_config(jpeg_quality=95)

    assert config == tui.TuiConfig(
        input_path=source,
        output_path=destination,
        output_format="png",
        jpeg_quality=95,
        png_compression=9,
        recursive=True,
        metadata="strip",
        on_conflict="skip",
    )
    assert [message for _, message, _ in stub.calls] == [
        "언어 / Language",
        "Input directory path",
        "Output directory path",
        "Output format",
        "PNG compression level",
        "Include subdirectories?",
        "Metadata handling",
        "When an output file has the same name",
        "Start conversion with these settings?",
    ]
    assert all(
        call[2]["instruction"] == "Use ↑/↓ to move · Enter to select"
        for call in stub.calls
        if call[0] == "select" and call[1] != "언어 / Language"
    )
    assert stub.calls[1][2]["instruction"] == "Press Enter to continue"
    metadata_choices = next(
        call[2]["choices"] for call in stub.calls if call[1] == "Metadata handling"
    )
    assert [choice.title for choice in metadata_choices] == [
        "Keep safely (recommended) — remove sensitive data such as GPS",
        "Preserve original — retain metadata where possible",
        "Strip all — do not write metadata",
    ]
    summary = capsys.readouterr().out
    assert "HEIC conversion settings" in summary
    assert "Configuration summary" in summary
    assert "File conflict handling: Skip" in summary
    assert "HEIC 이미지 변환 설정" not in summary


def test_returns_none_when_language_selection_is_cancelled(monkeypatch, capsys):
    """첫 언어 선택을 취소하면 다른 질문 없이 취소됩니다."""

    stub = patch_questionary(monkeypatch, {"언어 / Language": None})

    assert tui.collect_tui_config() is None
    assert [message for _, message, _ in stub.calls] == ["언어 / Language"]
    assert "Cancelled / 변환을 취소했습니다." in capsys.readouterr().out


def test_english_validation_errors_and_cancellation_are_localized(
    tmp_path, monkeypatch, capsys
):
    """영어 선택 뒤에는 검증 오류와 취소 메시지도 영어로 표시됩니다."""

    source = tmp_path / "input"
    source.mkdir()
    patch_questionary(
        monkeypatch,
        {
            "언어 / Language": "en",
            "Input directory path": str(source),
            "Output directory path": str(tmp_path / "output"),
            "Output format": "jpeg",
            "JPEG quality": 90,
            "Include subdirectories?": False,
            "Metadata handling": "safe",
            "When an output file has the same name": "rename",
            "Start conversion with these settings?": False,
        },
    )

    assert tui._input_directory_validator("", "en") == "Enter an input directory path."
    assert tui.collect_tui_config() is None
    output = capsys.readouterr().out
    assert "Conversion cancelled." in output
    assert "변환을 취소했습니다." not in output


def test_input_directory_validator_rejects_missing_path_and_regular_file(tmp_path):
    """입력값은 존재하는 디렉터리여야 합니다."""

    regular_file = tmp_path / "image.heic"
    regular_file.touch()

    assert tui._input_directory_validator(str(tmp_path / "missing")) is not True
    assert tui._input_directory_validator(str(regular_file)) is not True
    assert tui._input_directory_validator(str(tmp_path)) is True


def test_output_directory_validator_rejects_existing_file(tmp_path):
    """출력 경로에 기존 파일이 있으면 디렉터리로 사용하지 않습니다."""

    regular_file = tmp_path / "output"
    regular_file.touch()

    assert tui._output_directory_validator(str(regular_file)) is not True
    assert tui._output_directory_validator(str(tmp_path / "new-output")) is True


def test_returns_none_when_a_middle_question_is_cancelled(tmp_path, monkeypatch):
    """설정 수집 중 어느 질문에서든 취소하면 즉시 None을 반환합니다."""

    source = tmp_path / "input"
    source.mkdir()
    patch_questionary(
        monkeypatch,
        {
            "언어 / Language": "ko",
            "입력 디렉터리 경로": str(source),
            "출력 디렉터리 경로": str(tmp_path / "output"),
            "출력 형식": "jpeg",
            "JPEG 품질": None,
        },
    )

    assert tui.collect_tui_config() is None


def test_returns_none_when_final_confirmation_is_cancelled(tmp_path, monkeypatch):
    """최종 확인에서 취소를 고르면 확정된 설정을 반환하지 않습니다."""

    source = tmp_path / "input"
    source.mkdir()
    patch_questionary(
        monkeypatch,
        {
            "언어 / Language": "ko",
            "입력 디렉터리 경로": str(source),
            "출력 디렉터리 경로": str(tmp_path / "output"),
            "출력 형식": "jpeg",
            "JPEG 품질": 90,
            "하위 디렉터리도 변환할까요?": False,
            "메타데이터 처리": "safe",
            "같은 이름의 출력 파일이 있을 때": "rename",
            "이 설정으로 변환을 시작할까요?": False,
        },
    )

    assert tui.collect_tui_config() is None


def test_cli_uses_tui_configuration_when_format_is_missing(
    tmp_path, heic_factory, monkeypatch
):
    """TTY에서 형식을 생략하면 TUI 설정으로 실제 변환합니다."""

    from typer.testing import CliRunner

    from heic_converter import cli

    source = tmp_path / "input"
    destination = tmp_path / "output"
    source.mkdir()
    heic_factory(source / "tui.heic")
    config = TuiConfig(
        input_path=source,
        output_path=destination,
        output_format="png",
        jpeg_quality=90,
        png_compression=9,
        recursive=False,
        metadata="safe",
        on_conflict="rename",
    )
    monkeypatch.setattr(cli, "_terminal_supports_tui", lambda: True)
    monkeypatch.setattr(cli, "collect_tui_config", lambda **_: config)

    result = CliRunner().invoke(cli.app, [])

    assert result.exit_code == 0, result.output
    assert (destination / "tui.png").is_file()


def test_cli_returns_130_when_tui_is_cancelled(monkeypatch):
    """TUI에서 취소하면 변환 없이 표준 취소 종료 코드를 반환합니다."""

    from typer.testing import CliRunner

    from heic_converter import cli

    monkeypatch.setattr(cli, "_terminal_supports_tui", lambda: True)
    monkeypatch.setattr(cli, "collect_tui_config", lambda **_: None)

    result = CliRunner().invoke(cli.app, [])

    assert result.exit_code == 130
    assert result.output == ""


@pytest.mark.parametrize("terminal_error", [KeyboardInterrupt, EOFError])
def test_tui_turns_terminal_interrupts_into_cancellation(monkeypatch, terminal_error):
    """Ctrl+C와 EOF는 예외를 노출하지 않고 취소 결과로 정규화합니다."""

    def interrupted(*_, **__):
        raise terminal_error

    monkeypatch.setattr(tui, "_ask_select", interrupted)

    assert tui.collect_tui_config() is None


@pytest.mark.parametrize(
    ("stdin_is_tty", "stdout_is_tty", "expected"),
    [(True, True, True), (False, True, False), (True, False, False), (False, False, False)],
)
def test_tui_requires_both_terminal_input_and_output(
    monkeypatch, stdin_is_tty, stdout_is_tty, expected
):
    """입력 또는 출력이 파이프이면 TUI를 열지 않습니다."""

    from heic_converter import cli

    monkeypatch.setattr(cli.sys, "stdin", SimpleNamespace(isatty=lambda: stdin_is_tty))
    monkeypatch.setattr(cli.sys, "stdout", SimpleNamespace(isatty=lambda: stdout_is_tty))

    assert cli._terminal_supports_tui() is expected


def test_explicit_format_never_opens_tui_on_a_terminal(
    tmp_path, heic_factory, monkeypatch
):
    """형식을 지정한 자동화 명령은 TTY에서도 TUI 없이 실행됩니다."""

    from typer.testing import CliRunner

    from heic_converter import cli

    source = tmp_path / "input"
    destination = tmp_path / "output"
    source.mkdir()
    heic_factory(source / "explicit.heic")
    monkeypatch.setattr(cli, "_terminal_supports_tui", lambda: True)

    def unexpected_tui(**_):
        raise AssertionError("명시적 --format 실행에서 TUI가 열렸습니다.")

    monkeypatch.setattr(cli, "collect_tui_config", unexpected_tui)

    result = CliRunner().invoke(
        cli.app,
        ["--input", str(source), "--output", str(destination), "--format", "jpeg"],
    )

    assert result.exit_code == 0, result.output
    assert (destination / "explicit.jpeg").is_file()

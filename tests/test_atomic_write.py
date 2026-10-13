"""출력 저장이 기존 파일을 예기치 않게 덮어쓰지 않는지 검증합니다."""

from __future__ import annotations

import errno
from pathlib import Path

import pytest

from heic_converter.core import convert_image


def test_atomic_save_requires_explicit_overwrite(tmp_path, heic_factory):
    source = heic_factory(tmp_path / "source.heic")
    destination = tmp_path / "result.jpeg"
    destination.write_bytes(b"existing file")

    with pytest.raises(FileExistsError):
        convert_image(source, destination, output_format="jpeg")

    assert destination.read_bytes() == b"existing file"
    assert not list(tmp_path.glob(".result.*.jpeg"))


def test_atomic_save_replaces_only_when_overwrite_is_enabled(tmp_path, heic_factory):
    source = heic_factory(tmp_path / "source.heic")
    destination = tmp_path / "result.png"
    destination.write_bytes(b"existing file")

    result = convert_image(
        source,
        destination,
        output_format="png",
        overwrite=True,
    )

    assert result.destination == Path(destination)
    assert destination.read_bytes().startswith(b"\x89PNG\r\n\x1a\n")


def test_atomic_save_falls_back_when_filesystem_has_no_hard_links(
    tmp_path, heic_factory, monkeypatch
):
    from heic_converter import core

    source = heic_factory(tmp_path / "source.heic")
    destination = tmp_path / "result.png"

    monkeypatch.setattr(core, "_try_macos_exclusive_rename", lambda *_: False)

    def unsupported_link(*_):
        raise OSError(errno.ENOTSUP, "hard links are unavailable")

    monkeypatch.setattr(core.os, "link", unsupported_link)

    result = convert_image(source, destination, output_format="png")

    assert result.destination == destination
    assert destination.read_bytes().startswith(b"\x89PNG\r\n\x1a\n")
    assert not list(tmp_path.glob(".result.*.png"))

"""입력 탐색의 작지만 중요한 공개 core 계약 테스트."""

from __future__ import annotations

from pathlib import Path

import pytest


def discover(input_dir: Path, *, recursive: bool, excluded_directory: Path | None = None) -> list[Path]:
    """구현 교체에 강하도록 탐색 결과만 공개 함수에서 읽는다."""
    try:
        from heic_converter.core import discover_heic_files
    except ModuleNotFoundError:
        pytest.fail("`heic_converter.core.discover_heic_files` 공개 함수를 구현하세요.", pytrace=False)
    return list(discover_heic_files(input_dir, recursive=recursive, excluded_directory=excluded_directory))


def test_discovery_accepts_uppercase_extensions_and_uses_natural_filename_order(tmp_path):
    for name in ("photo10.HEIC", "photo2.heic", "photo1.HeIc", "ignore.heif", "ignore.jpg"):
        (tmp_path / name).write_bytes(b"")

    found = discover(tmp_path, recursive=False)

    assert [path.name for path in found] == ["photo1.HeIc", "photo2.heic", "photo10.HEIC"]


def test_discovery_only_descends_when_requested_and_excludes_an_output_tree(tmp_path):
    nested = tmp_path / "album"
    output = tmp_path / "converted"
    nested.mkdir()
    output.mkdir()
    (tmp_path / "root.heic").write_bytes(b"")
    (nested / "inside.heic").write_bytes(b"")
    (output / "stale.heic").write_bytes(b"")

    assert [path.name for path in discover(tmp_path, recursive=False)] == ["root.heic"]
    assert [path.relative_to(tmp_path) for path in discover(tmp_path, recursive=True, excluded_directory=output)] == [
        Path("album/inside.heic"),
        Path("root.heic"),
    ]


def test_discovery_excludes_symbolic_links(tmp_path):
    outside = tmp_path.parent / "outside.heic"
    outside.write_bytes(b"outside")
    (tmp_path / "alias.heic").symlink_to(outside)

    assert discover(tmp_path, recursive=False) == []

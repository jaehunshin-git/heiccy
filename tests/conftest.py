"""HEIC 변환 CLI의 공개 계약을 검증하기 위한 공용 도우미입니다."""

from __future__ import annotations

from pathlib import Path
from typing import Literal

import pytest


def cli_app():
    """공개 Typer 앱을 늦게 가져와, 수집 단계의 오류를 읽기 쉽게 만든다."""
    try:
        from heic_converter.cli import app
    except ModuleNotFoundError:
        pytest.fail(
            "공개 CLI `heic_converter.cli:app`을 가져올 수 없습니다. "
            "패키지와 앱을 구현하거나 테스트 환경에 설치하세요.",
            pytrace=False,
        )
    return app


def run_cli(*arguments: str):
    """파일 시스템 의존 CLI를 격리된 Typer 러너로 실행한다."""
    try:
        from typer.testing import CliRunner
    except ModuleNotFoundError:
        pytest.fail("CLI 계약 테스트에는 Typer가 필요합니다.", pytrace=False)
    return CliRunner().invoke(cli_app(), list(arguments))


@pytest.fixture
def heic_factory():
    """작은 실제 HEIC 파일을 만든다.

    테스트 환경의 libheif가 HEIC 인코딩을 제공하지 않으면, 디코더만으로는
    신뢰할 수 있는 입력을 만들 수 없으므로 관련 사례를 건너뛴다.
    """
    pillow = pytest.importorskip("PIL", reason="이미지 결과를 검증하려면 Pillow가 필요합니다.")
    pillow_heif = pytest.importorskip("pillow_heif", reason="HEIC 테스트 입력에는 pillow-heif가 필요합니다.")
    from PIL import Image

    pillow_heif.register_heif_opener()

    def make(
        path: Path,
        *,
        mode: Literal["RGB", "RGBA"] = "RGB",
        color: tuple[int, ...] | None = None,
        exif: bytes | None = None,
        icc_profile: bytes | None = None,
    ) -> Path:
        image = Image.new(mode, (12, 8), color or ((31, 97, 173, 96) if mode == "RGBA" else (31, 97, 173)))
        save_options = {}
        if exif is not None:
            save_options["exif"] = exif
        if icc_profile is not None:
            save_options["icc_profile"] = icc_profile
        try:
            image.save(path, format="HEIF", **save_options)
        except Exception as error:  # noqa: BLE001 - 코덱별 예외 형식이 일정하지 않습니다.
            pytest.skip(f"이 환경의 pillow-heif/libheif는 HEIC 인코딩을 지원하지 않습니다: {error}")
        return path

    # importorskip의 반환값을 의도적으로 사용하지 않으며, Pillow 가용성을 먼저 확인한다.
    assert pillow is not None
    return make


def open_image(path: Path):
    """Pillow로 결과 파일을 완전히 읽어 손상된 출력도 잡아낸다."""
    from PIL import Image

    with Image.open(path) as image:
        image.load()
        return image.copy(), image.format

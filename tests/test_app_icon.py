"""브랜딩 원본과 macOS 아이콘 패키징의 연결을 검증합니다."""

import importlib.util
import subprocess
import sys
from pathlib import Path

import pytest
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "packaging/macos/create_icon.py"
if not SCRIPT.is_file():
    pytest.skip("sdist에는 macOS 빌드 스크립트가 없습니다.", allow_module_level=True)

spec = importlib.util.spec_from_file_location("create_icon", SCRIPT)
icons = importlib.util.module_from_spec(spec)
spec.loader.exec_module(icons)


def test_source_pixels_and_transparency_survive_all_iconset_sizes(tmp_path):
    source = tmp_path / "source.png"
    image = Image.new("RGBA", (1024, 1024))
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle((96, 96, 928, 928), radius=180, fill="white")
    draw.rectangle((400, 400, 624, 624), fill="black")
    image.save(source)
    destination = tmp_path / "AppIcon.iconset"

    icons.create_iconset(source, destination)

    expected = {
        f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png": size * scale
        for size in (16, 32, 128, 256, 512)
        for scale in (1, 2)
    }
    assert {path.name for path in destination.iterdir()} == set(expected)
    for name, pixels in expected.items():
        with Image.open(destination / name) as resized:
            assert resized.size == (pixels, pixels)
            assert resized.mode == "RGBA"
            assert resized.getpixel((0, 0))[3] == 0
            white = resized.getpixel((pixels // 2, pixels // 4))
            assert min(white[:3]) >= 250
            assert white[3] == 255
            assert max(resized.getpixel((pixels // 2, pixels // 2))[:3]) < 15
    with Image.open(destination / "icon_512x512@2x.png") as largest:
        assert largest.tobytes() == image.tobytes()


@pytest.mark.parametrize(
    ("size", "mode", "format", "message"),
    [
        ((512, 512), "RGBA", "PNG", "1024×1024 RGBA"),
        ((1024, 1024), "RGB", "PNG", "1024×1024 RGBA"),
        ((1024, 1024), "RGB", "JPEG", "PNG여야"),
    ],
)
def test_invalid_artwork_does_not_create_an_iconset(
    tmp_path, size, mode, format, message
):
    source = tmp_path / "invalid.png"
    Image.new(mode, size).save(source, format=format)
    destination = tmp_path / "AppIcon.iconset"

    with pytest.raises(ValueError, match=message):
        icons.create_iconset(source, destination)
    assert not destination.exists()


def test_missing_source_cli_reports_the_path(tmp_path):
    source = tmp_path / "missing.png"
    destination = tmp_path / "AppIcon.iconset"
    result = subprocess.run(
        [sys.executable, str(SCRIPT), str(destination), "--source", str(source)],
        capture_output=True,
        text=True,
        timeout=15,
        check=False,
    )
    assert result.returncode != 0
    assert "원본 PNG가 없습니다" in result.stderr
    assert str(source) in result.stderr
    assert "Traceback" not in result.stderr
    assert not destination.exists()


def test_default_source_is_the_approved_artwork_from_any_working_directory(tmp_path):
    destination = tmp_path / "AppIcon.iconset"
    result = subprocess.run(
        [sys.executable, str(SCRIPT), str(destination)],
        cwd=tmp_path,
        capture_output=True,
        text=True,
        timeout=15,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    with Image.open(icons.SOURCE) as source:
        assert source.mode == "RGBA"
        assert source.getpixel((0, 0))[3] == 0
        visible = [
            pixel
            for _, pixel in source.getcolors(maxcolors=1024 * 1024)
            if pixel[3] == 255
        ]
        assert (0, 0, 0, 255) in visible
        assert (255, 255, 255, 255) in visible
        assert all(red == green == blue for red, green, blue, _ in visible)
        with Image.open(destination / "icon_512x512@2x.png") as packaged:
            assert packaged.tobytes() == source.tobytes()

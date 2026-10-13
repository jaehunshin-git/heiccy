"""HEIC 디렉터리 변환 명령의 사용자 관점 계약 테스트."""

from __future__ import annotations

from pathlib import Path

import pytest
from conftest import open_image, run_cli
from rich.text import Text


def invoke(input_dir: Path, output_dir: Path, *extra: str):
    """공통 필수 옵션을 넣어 CLI 호출 의도를 각 테스트에서 분명히 한다."""
    return run_cli("--input", str(input_dir), "--output", str(output_dir), *extra)


@pytest.mark.parametrize("force_color", [False, True])
def test_help_lists_the_public_options(monkeypatch, force_color):
    if force_color:
        monkeypatch.setenv("FORCE_COLOR", "1")
    else:
        monkeypatch.delenv("FORCE_COLOR", raising=False)
    result = run_cli("--help")

    assert result.exit_code == 0, result.output
    # Rich는 색상 환경에서 옵션 문자열 중간에도 ANSI 스타일 코드를 삽입합니다.
    visible_help = Text.from_ansi(result.output).plain
    for option in ("--input", "--output", "--format", "--jpeg-quality", "--png-compression", "--recursive", "--metadata", "--on-conflict"):
        assert option in visible_help


@pytest.mark.parametrize(
    ("requested_format", "suffix", "pillow_format"),
    [("jpeg", ".jpeg", "JPEG"), ("png", ".png", "PNG")],
)
def test_converts_one_heic_to_the_requested_real_image_format(tmp_path, heic_factory, requested_format, suffix, pillow_format):
    source = tmp_path / "input"
    destination = tmp_path / "output"
    source.mkdir()
    heic_factory(source / "portrait.HEIC")

    result = invoke(source, destination, "--format", requested_format)

    target = destination / f"portrait{suffix}"
    assert result.exit_code == 0, result.output
    assert target.is_file()
    image, actual_format = open_image(target)
    assert actual_format == pillow_format
    assert image.size == (12, 8)


def test_jpeg_uses_the_jpeg_extension_not_jpg(tmp_path, heic_factory):
    source = tmp_path / "input"
    destination = tmp_path / "output"
    source.mkdir()
    heic_factory(source / "camera.heic")

    result = invoke(source, destination, "--format", "jpeg")

    assert result.exit_code == 0, result.output
    assert (destination / "camera.jpeg").is_file()
    assert not (destination / "camera.jpg").exists()


def test_png_preserves_transparency_while_jpeg_flattens_it_safely(tmp_path, heic_factory):
    source = tmp_path / "input"
    source.mkdir()
    heic_factory(source / "alpha.heic", mode="RGBA")

    png_output = tmp_path / "png"
    png_result = invoke(source, png_output, "--format", "png")
    assert png_result.exit_code == 0, png_result.output
    png, _ = open_image(png_output / "alpha.png")
    assert "A" in png.getbands()

    jpeg_output = tmp_path / "jpeg"
    jpeg_result = invoke(source, jpeg_output, "--format", "jpeg")
    assert jpeg_result.exit_code == 0, jpeg_result.output
    jpeg, _ = open_image(jpeg_output / "alpha.jpeg")
    assert jpeg.mode == "RGB"


def test_uses_the_primary_frame_in_a_multi_image_heic(tmp_path):
    from PIL import Image
    from pillow_heif import register_heif_opener

    register_heif_opener()
    source = tmp_path / "input"
    destination = tmp_path / "output"
    source.mkdir()
    first = Image.new("RGB", (2, 2), (255, 0, 0))
    primary = Image.new("RGB", (2, 2), (0, 0, 255))
    try:
        first.save(
            source / "multi.heic",
            format="HEIF",
            save_all=True,
            append_images=[primary],
            primary_index=1,
        )
    except Exception as error:  # noqa: BLE001 - 코덱별 예외 형식이 일정하지 않습니다.
        pytest.skip(f"다중 이미지 HEIC 인코딩을 지원하지 않습니다: {error}")

    result = invoke(source, destination, "--format", "png")

    assert result.exit_code == 0, result.output
    converted, _ = open_image(destination / "multi.png")
    red, green, blue = converted.convert("RGB").getpixel((0, 0))
    assert blue > 240 and red < 10 and green < 10


@pytest.mark.parametrize(("requested_format", "suffix"), [("jpeg", ".jpeg"), ("png", ".png")])
def test_normalizes_orientation_and_keeps_capture_date(
    tmp_path, heic_factory, requested_format, suffix
):
    from PIL import Image

    source = tmp_path / "input"
    destination = tmp_path / "output"
    source.mkdir()
    exif = Image.Exif()
    exif[274] = 6
    exif[306] = "2026:09:08 12:00:00"
    heic_factory(source / "rotated.heic", exif=exif.tobytes())

    result = invoke(source, destination, "--format", requested_format)

    assert result.exit_code == 0, result.output
    converted, _ = open_image(destination / f"rotated{suffix}")
    assert converted.size == (8, 12)
    assert converted.getexif().get(274) == 1
    assert converted.getexif().get(306) == "2026:09:08 12:00:00"


@pytest.mark.parametrize("quality", [1, 95])
def test_accepts_jpeg_quality_range(tmp_path, heic_factory, quality):
    source = tmp_path / "input"
    source.mkdir()
    heic_factory(source / "photo.heic")

    result = invoke(source, tmp_path / "output", "--format", "jpeg", "--jpeg-quality", str(quality))

    assert result.exit_code == 0, result.output


@pytest.mark.parametrize("compression", [0, 9])
def test_accepts_png_compression_range(tmp_path, heic_factory, compression):
    source = tmp_path / "input"
    source.mkdir()
    heic_factory(source / "photo.heic")

    result = invoke(source, tmp_path / "output", "--format", "png", "--png-compression", str(compression))

    assert result.exit_code == 0, result.output


def test_nested_files_require_recursive_and_keep_their_relative_path(tmp_path, heic_factory):
    source = tmp_path / "input"
    nested = source / "2026" / "trip"
    nested.mkdir(parents=True)
    heic_factory(source / "top.heic")
    heic_factory(nested / "deep.heic")

    flat_result = invoke(source, tmp_path / "flat", "--format", "jpeg")
    assert flat_result.exit_code == 0, flat_result.output
    assert (tmp_path / "flat" / "top.jpeg").is_file()
    assert not (tmp_path / "flat" / "2026" / "trip" / "deep.jpeg").exists()

    recursive_output = tmp_path / "recursive"
    recursive_result = invoke(source, recursive_output, "--format", "jpeg", "--recursive")
    assert recursive_result.exit_code == 0, recursive_result.output
    assert (recursive_output / "top.jpeg").is_file()
    assert (recursive_output / "2026" / "trip" / "deep.jpeg").is_file()


@pytest.mark.parametrize("policy", ["safe", "preserve", "strip"])
def test_accepts_each_metadata_policy(tmp_path, heic_factory, policy):
    source = tmp_path / "input"
    source.mkdir()
    heic_factory(source / "photo.heic")

    result = invoke(source, tmp_path / policy, "--format", "jpeg", "--metadata", policy)

    assert result.exit_code == 0, result.output


def test_metadata_modes_handle_gps_capture_date_and_icc_when_available(tmp_path, heic_factory):
    """HEIC 인코더가 EXIF/ICC를 보존하는 환경에서만 메타데이터 정책을 깊게 검증한다."""
    from PIL import Image, ImageCms

    source = tmp_path / "input"
    source.mkdir()
    exif = Image.Exif()
    exif[306] = "2026:01:02 03:04:05"  # DateTime
    exif[34853] = {1: "N", 2: (37, 1), 3: "E", 4: (127, 1)}  # GPSInfo
    icc = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
    heic_factory(source / "location.heic", exif=exif.tobytes(), icc_profile=icc)

    # 일부 libheif 빌드는 저장은 성공해도 EXIF를 드롭한다. 그 경우에는 이 입력을
    # 메타데이터 계약의 근거로 삼을 수 없으므로 테스트를 건너뛴다.
    with Image.open(source / "location.heic") as input_image:
        input_exif = input_image.getexif()
        if not (input_exif.get(306) and input_exif.get(34853) and input_image.info.get("icc_profile")):
            pytest.skip("현재 HEIC 인코더가 EXIF GPS/촬영일/ICC를 모두 보존하지 않습니다.")

    safe_result = invoke(source, tmp_path / "safe", "--format", "jpeg", "--metadata", "safe")
    preserve_result = invoke(source, tmp_path / "preserve", "--format", "jpeg", "--metadata", "preserve")
    strip_result = invoke(source, tmp_path / "strip", "--format", "jpeg", "--metadata", "strip")
    assert safe_result.exit_code == preserve_result.exit_code == strip_result.exit_code == 0

    with Image.open(tmp_path / "safe" / "location.jpeg") as safe:
        safe_exif = safe.getexif()
        assert safe_exif.get(306) == "2026:01:02 03:04:05"
        assert not safe_exif.get(34853)
        assert safe.info.get("icc_profile")
    with Image.open(tmp_path / "preserve" / "location.jpeg") as preserved:
        preserved_exif = preserved.getexif()
        assert preserved_exif.get(306) == "2026:01:02 03:04:05"
        assert preserved_exif.get(34853)
        assert preserved.info.get("icc_profile")
    with Image.open(tmp_path / "strip" / "location.jpeg") as stripped:
        assert not stripped.getexif()
        assert not stripped.info.get("icc_profile")


@pytest.mark.parametrize("policy", ["skip", "overwrite", "error", "rename"])
def test_conflict_policy_has_the_promised_effect(tmp_path, heic_factory, policy):
    source = tmp_path / "input"
    destination = tmp_path / "output"
    source.mkdir()
    heic_factory(source / "duplicate.heic", color=(9, 190, 12))
    destination.mkdir()
    existing = destination / "duplicate.jpeg"
    existing.write_bytes(b"original destination must stay recognizable")

    result = invoke(source, destination, "--format", "jpeg", "--on-conflict", policy)

    if policy == "error":
        assert result.exit_code != 0
        assert existing.read_bytes() == b"original destination must stay recognizable"
    elif policy == "skip":
        assert result.exit_code == 0, result.output
        assert existing.read_bytes() == b"original destination must stay recognizable"
    elif policy == "overwrite":
        assert result.exit_code == 0, result.output
        _, actual_format = open_image(existing)
        assert actual_format == "JPEG"
    else:
        assert result.exit_code == 0, result.output
        assert existing.read_bytes() == b"original destination must stay recognizable"
        renamed = destination / "duplicate-2.jpeg"
        assert renamed.is_file()
        assert open_image(renamed)[1] == "JPEG"


def test_rename_retries_without_overwriting_a_file_created_during_conversion(
    tmp_path, heic_factory, monkeypatch
):
    from heic_converter import cli as cli_module

    source = tmp_path / "input"
    destination = tmp_path / "output"
    source.mkdir()
    heic_factory(source / "race.heic")
    original_convert = cli_module.convert_image
    first_call = True

    def convert_with_race(source_path, destination_path, **options):
        nonlocal first_call
        if first_call:
            first_call = False
            destination_path.parent.mkdir(parents=True, exist_ok=True)
            destination_path.write_bytes(b"created by another process")
            raise FileExistsError(destination_path)
        return original_convert(source_path, destination_path, **options)

    monkeypatch.setattr(cli_module, "convert_image", convert_with_race)

    result = invoke(source, destination, "--format", "jpeg", "--on-conflict", "rename")

    assert result.exit_code == 0, result.output
    assert (destination / "race.jpeg").read_bytes() == b"created by another process"
    assert open_image(destination / "race-2.jpeg")[1] == "JPEG"


def test_output_subdirectory_is_excluded_from_recursive_input_discovery(tmp_path, heic_factory):
    source = tmp_path / "input"
    destination = source / "converted"
    destination.mkdir(parents=True)
    heic_factory(source / "keep.heic")
    # 출력 아래의 손상 HEIC를 입력으로 다시 읽으면 전체 작업이 부분 실패해야 한다.
    (destination / "do-not-read.heic").write_bytes(b"not a HEIC file")

    result = invoke(source, destination, "--format", "jpeg", "--recursive")

    assert result.exit_code == 0, result.output
    assert (destination / "keep.jpeg").is_file()


def test_a_corrupt_file_reports_partial_failure_but_keeps_successful_outputs(tmp_path, heic_factory):
    source = tmp_path / "input"
    destination = tmp_path / "output"
    source.mkdir()
    heic_factory(source / "01-good.heic")
    (source / "02-broken.heic").write_bytes(b"definitely not a HEIC image")

    result = invoke(source, destination, "--format", "jpeg")

    assert result.exit_code != 0
    assert (destination / "01-good.jpeg").is_file()
    assert "02-broken" in result.output


def test_invalid_input_and_option_values_fail_with_nonzero_exit_code(tmp_path):
    missing = tmp_path / "does-not-exist"
    result = invoke(missing, tmp_path / "output")
    assert result.exit_code != 0

    empty = tmp_path / "empty"
    empty.mkdir()
    format_result = invoke(empty, tmp_path / "format", "--format", "webp")
    assert format_result.exit_code == 2
    quality_result = invoke(empty, tmp_path / "quality", "--format", "jpeg", "--jpeg-quality", "101")
    assert quality_result.exit_code == 2
    compression_result = invoke(empty, tmp_path / "compression", "--format", "png", "--png-compression", "10")
    assert compression_result.exit_code == 2


def test_empty_directory_and_single_file_input_are_usage_errors(tmp_path, heic_factory):
    empty = tmp_path / "empty"
    empty.mkdir()

    empty_result = invoke(empty, tmp_path / "output", "--format", "jpeg")
    assert empty_result.exit_code == 2

    single = heic_factory(tmp_path / "single.heic")
    single_result = invoke(single, tmp_path / "single-output", "--format", "png")
    assert single_result.exit_code == 2

"""HDR PNG에 원본 메타데이터 정책을 적용하는 경로를 검증합니다."""

import struct
import sys
import zlib
from types import SimpleNamespace

import pytest
from PIL import Image

from heic_converter.core import _copy_hdr_png_with_metadata, _save_hdr_png


@pytest.mark.parametrize(
    ("primary_index", "image_count", "expected_indices"),
    [(0, 2, [0]), (1, 2, [1]), (-1, 2, []), (2, 2, []), (2**64 - 1, 2, []), (0, 0, [])],
)
def test_native_hdr_decode_uses_valid_primary_index(
    tmp_path, monkeypatch, primary_index, image_count, expected_indices
):
    source = object()
    decoded_indices = []

    def decode(image_source, index, options):
        assert image_source is source
        assert options == {"decode-request": "HDR"}
        decoded_indices.append(index)
        # 디코딩 실패를 모사해 인덱스 선택 이후의 기존 오류 처리도 확인합니다.
        return None

    quartz = SimpleNamespace(
        CGImageSourceCreateWithURL=lambda url, options: source,
        CGImageSourceGetPrimaryImageIndex=lambda image_source: primary_index,
        CGImageSourceGetCount=lambda image_source: image_count,
        CGImageSourceCreateImageAtIndex=decode,
        kCGImageSourceDecodeRequest="decode-request",
        kCGImageSourceDecodeToHDR="HDR",
    )
    foundation = SimpleNamespace(NSURL=SimpleNamespace(fileURLWithPath_=lambda path: path))
    monkeypatch.setitem(sys.modules, "Quartz", quartz)
    monkeypatch.setitem(sys.modules, "Foundation", foundation)
    message = "HDR 이미지를 읽지 못했습니다" if expected_indices else "대표 이미지 인덱스가 유효하지 않습니다"
    output = tmp_path / "result.png"
    with pytest.raises(ValueError, match=message):
        _save_hdr_png(tmp_path / "synthetic.heic", output, {})
    assert decoded_indices == expected_indices
    assert not output.exists() and not list(tmp_path.glob("*.native.png"))


@pytest.mark.parametrize("metadata", ["safe", "preserve", "strip"])
def test_hdr_png_metadata_copy_preserves_16bit_samples_and_pq_chunks(tmp_path, metadata):
    # Pillow 재인코딩으로 8비트가 되거나 HDR 색상 정보가 사라지는 회귀를 검출합니다.
    samples = (0x0123, 0x4567, 0x89AB)
    pixels = b"\x00" + struct.pack(">3H", *samples)  # 필터 없음, RGB 16비트 한 픽셀
    ihdr = struct.pack(">IIBBBBB", 1, 1, 16, 2, 0, 0, 0)
    cicp = bytes([9, 16, 0, 1])  # BT.2020 / PQ / RGB / full-range
    idat = zlib.compress(pixels)
    exif = Image.Exif()
    exif[306] = "2026:01:02 03:04:05"
    exif[34853] = {1: "N", 2: (37, 1)}

    def chunk(kind, data):
        return (
            struct.pack(">I", len(data)) + kind + data
            + struct.pack(">I", zlib.crc32(kind + data))
        )

    native = tmp_path / "native-16bit-pq.png"
    native.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"cICP", cicp)
        + chunk(b"eXIf", exif.tobytes()[6:])
        + chunk(b"IDAT", idat)
        + chunk(b"IEND", b"")
    )
    original = native.read_bytes()
    safe_exif = Image.Exif()
    safe_exif[306] = exif[306]
    options = {
        "safe": {"exif": safe_exif.tobytes()},
        "preserve": {"exif": exif.tobytes(), "xmp": b"<x:xmpmeta />"},
        "strip": {},
    }
    output = tmp_path / f"{metadata}-16bit-pq.png"
    _copy_hdr_png_with_metadata(native, output, options[metadata])
    assert native.read_bytes() == original
    content = output.read_bytes()
    assert content[:8] == original[:8]
    chunks = {}
    offset = 8
    while offset < len(content):
        length = struct.unpack_from(">I", content, offset)[0]
        kind = content[offset + 4:offset + 8]
        data = content[offset + 8:offset + 8 + length]
        crc = struct.unpack_from(">I", content, offset + 8 + length)[0]
        assert crc == zlib.crc32(kind + data)
        assert kind not in chunks
        chunks[kind] = data
        offset += 12 + length
    assert offset == len(content)
    assert chunks[b"IHDR"] == ihdr and chunks[b"cICP"] == cicp
    assert chunks[b"IDAT"] == idat
    decoded = zlib.decompress(chunks[b"IDAT"])
    assert decoded[0] == 0 and struct.unpack(">3H", decoded[1:]) == samples
    with Image.open(output) as image:
        image.load()
        assert image.size == (1, 1)
        assert bool(image.getexif().get(34853)) == (metadata == "preserve")
        assert image.getexif().get(306) == (None if metadata == "strip" else exif[306])
        assert bool(image.info.get("xmp")) == (metadata == "preserve")


def test_hdr_png_metadata_keeps_profile_and_obeys_policy(tmp_path):
    native = tmp_path / "native.png"
    original_exif = Image.Exif()
    original_exif[306] = "2026:01:02 03:04:05"
    original_exif[34853] = {1: "N", 2: (37, 1)}
    Image.new("RGB", (2, 2), (12, 34, 56)).save(
        native, icc_profile=b"test-profile", exif=original_exif.tobytes()
    )

    safe_exif = Image.Exif()
    safe_exif[306] = "2026:01:02 03:04:05"
    safe = tmp_path / "safe.png"
    _copy_hdr_png_with_metadata(native, safe, {"exif": safe_exif.tobytes()})
    with Image.open(safe) as image:
        assert image.info["icc_profile"] == b"test-profile"
        assert image.getexif().get(306) == "2026:01:02 03:04:05"
        assert not image.getexif().get(34853)
        assert not image.info.get("xmp")
        assert image.getpixel((0, 0)) == (12, 34, 56)

    preserved = tmp_path / "preserved.png"
    _copy_hdr_png_with_metadata(
        native,
        preserved,
        {"exif": original_exif.tobytes(), "xmp": b"<x:xmpmeta />"},
    )
    with Image.open(preserved) as image:
        assert image.getexif().get(34853)
        assert image.info["xmp"] == b"<x:xmpmeta />"

    stripped = tmp_path / "stripped.png"
    _copy_hdr_png_with_metadata(native, stripped, {})
    with Image.open(stripped) as image:
        assert image.info["icc_profile"] == b"test-profile"
        assert not image.getexif()
        assert not image.info.get("xmp")


def test_conversion_reports_sdr_reason_for_jpeg_and_missing_gain_map(tmp_path, heic_factory):
    from heic_converter.core import convert_image

    source = heic_factory(tmp_path / "sdr.heic")
    jpeg = convert_image(source, tmp_path / "sdr.jpeg", output_format="jpeg")
    png = convert_image(source, tmp_path / "sdr.png", output_format="png")
    assert not jpeg.hdr_applied and "JPEG" in jpeg.sdr_reason
    assert not png.hdr_applied and "게인 맵" in png.sdr_reason


def test_hdr_branch_reports_application_and_sdr_fallback_conditions(tmp_path, heic_factory, monkeypatch):
    from heic_converter import core

    source = heic_factory(tmp_path / "gain-map.heic")
    original_open = core.Image.open
    orientation = 1
    supported = True
    native_calls = []

    def open_with_gain_map(*args, **kwargs):
        opened = original_open(*args, **kwargs)
        opened.info["aux"] = {core._APPLE_HDR_GAIN_MAP: [1]}
        opened.getexif()[274] = orientation
        return opened

    def save_native(_source, destination, metadata):
        native_calls.append(metadata)
        Image.new("RGB", (2, 2)).save(destination, format="PNG", icc_profile=b"hdr-profile")

    monkeypatch.setattr(core.Image, "open", open_with_gain_map)
    monkeypatch.setattr(core, "_supports_hdr_png", lambda: supported)
    monkeypatch.setattr(core, "_save_hdr_png", save_native)
    hdr = core.convert_image(source, tmp_path / "hdr.png", output_format="png", metadata="strip")
    assert hdr.hdr_applied and hdr.sdr_reason is None
    assert native_calls == [{}]
    with original_open(tmp_path / "hdr.png") as image:
        assert image.info["icc_profile"] == b"hdr-profile"
    orientation = 6
    rotated = core.convert_image(source, tmp_path / "rotated.png", output_format="png")
    assert not rotated.hdr_applied and "방향" in rotated.sdr_reason
    orientation = 1
    supported = False
    unsupported = core.convert_image(source, tmp_path / "unsupported.png", output_format="png")
    assert not unsupported.hdr_applied and "macOS 15" in unsupported.sdr_reason
    assert len(native_calls) == 1

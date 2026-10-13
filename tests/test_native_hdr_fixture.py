"""개인 사진 없이 합성 Apple 게인 맵으로 실제 ImageIO HDR 출력을 검증합니다."""

import io
import sys

import pytest
from PIL import Image, ImageCms
from pillow_heif import register_heif_opener

from heic_converter.core import _APPLE_HDR_GAIN_MAP, _supports_hdr_png, convert_image

pytestmark = pytest.mark.skipif(
    sys.platform != "darwin" or not _supports_hdr_png(),
    reason="네이티브 HDR 인코더는 macOS 15 이상에서 검증합니다.",
)


@pytest.fixture
def synthetic_hdr_heic(tmp_path):
    import Quartz as quartz
    from Foundation import NSURL

    # ImageIO의 게인 맵 통계 계산에 충분한 크기와 변화를 가진 입력을 합성합니다.
    base = tmp_path / "기본 이미지.png"
    exif = Image.Exif()
    exif[34853] = {1: "N", 2: (37, 1)}
    profile = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
    Image.new("RGB", (256, 256), (60, 100, 180)).save(
        base, exif=exif.tobytes(), icc_profile=profile
    )
    source = quartz.CGImageSourceCreateWithURL(
        NSURL.fileURLWithPath_(str(base)), None
    )
    path = tmp_path / "합성 HDR 사진.heic"
    destination = quartz.CGImageDestinationCreateWithURL(
        NSURL.fileURLWithPath_(str(path)), "public.heic", 1, None
    )
    assert destination is not None
    quartz.CGImageDestinationAddImageFromSource(destination, source, 0, None)
    metadata = quartz.CGImageMetadataCreateMutable()
    registered, error = quartz.CGImageMetadataRegisterNamespaceForPrefix(
        metadata, "http://ns.apple.com/HDRGainMap/1.0/", "HDRGainMap", None
    )
    assert registered and error is None
    assert quartz.CGImageMetadataSetValueWithPath(
        metadata, None, "HDRGainMap:HDRGainMapVersion", "65536"
    )
    assert quartz.CGImageMetadataSetValueWithPath(
        metadata, None, "HDRGainMap:HDRGainMapHeadroom", "2.0"
    )
    quartz.CGImageDestinationAddAuxiliaryDataInfo(
        destination,
        quartz.kCGImageAuxiliaryDataTypeHDRGainMap,
        {
            quartz.kCGImageAuxiliaryDataInfoData: bytes(
                32 + (x + y) % 192 for y in range(128) for x in range(128)
            ),
            quartz.kCGImageAuxiliaryDataInfoDataDescription: {
                "Width": 128,
                "Height": 128,
                "BytesPerRow": 128,
                "PixelFormat": 0x4C303038,  # kCVPixelFormatType_OneComponent8
            },
            quartz.kCGImageAuxiliaryDataInfoMetadata: metadata,
        },
    )
    assert quartz.CGImageDestinationFinalize(destination)
    return path


@pytest.fixture
def synthetic_nonzero_primary_hdr_heic(synthetic_hdr_heic, tmp_path):
    import Quartz as quartz
    from Foundation import NSURL

    # 첫 프레임은 크기가 다른 SDR 이미지이며, 두 번째 HDR 프레임만 대표로 지정합니다.
    first = tmp_path / "첫 SDR 이미지.png"
    Image.new("RGB", (128, 96), (210, 30, 10)).save(first)
    first_source = quartz.CGImageSourceCreateWithURL(
        NSURL.fileURLWithPath_(str(first)), None
    )
    hdr_source = quartz.CGImageSourceCreateWithURL(
        NSURL.fileURLWithPath_(str(synthetic_hdr_heic)), None
    )
    assert first_source is not None and hdr_source is not None
    gain_map = quartz.CGImageSourceCopyAuxiliaryDataInfoAtIndex(
        hdr_source, 0, quartz.kCGImageAuxiliaryDataTypeHDRGainMap
    )
    assert gain_map is not None
    path = tmp_path / "두 번째 이미지가 대표인 합성 HDR.heic"
    destination = quartz.CGImageDestinationCreateWithURL(
        NSURL.fileURLWithPath_(str(path)),
        "public.heic",
        2,
        {quartz.kCGImagePropertyPrimaryImage: 1},
    )
    assert destination is not None
    quartz.CGImageDestinationAddImageFromSource(destination, first_source, 0, None)
    # 재인코딩 시 EXIF 원본 바이트가 사라져도 메타데이터 정책을 검증할 수 있게
    # 유효한 합성 GPS를 대표 이미지의 속성으로 명시합니다.
    quartz.CGImageDestinationAddImageFromSource(
        destination,
        hdr_source,
        0,
        {
            quartz.kCGImagePropertyGPSDictionary: {
                quartz.kCGImagePropertyGPSLatitude: 37.0,
                quartz.kCGImagePropertyGPSLatitudeRef: "N",
                quartz.kCGImagePropertyGPSLongitude: 127.0,
                quartz.kCGImagePropertyGPSLongitudeRef: "E",
            }
        },
    )
    # 보조 데이터는 마지막으로 추가한 이미지에 연결합니다.
    quartz.CGImageDestinationAddAuxiliaryDataInfo(
        destination, quartz.kCGImageAuxiliaryDataTypeHDRGainMap, gain_map
    )
    assert quartz.CGImageDestinationFinalize(destination)
    return path


def _assert_hdr_png_encoding(path):
    assert path.read_bytes()[24] == 16  # IHDR bit depth
    with Image.open(path) as image:
        image.load()
        if image.info.get("icc_profile"):
            profile = ImageCms.ImageCmsProfile(io.BytesIO(image.info["icc_profile"]))
            assert "PQ" in ImageCms.getProfileDescription(profile)
        else:
            # macOS 15는 ISO HDR 색상을 ICC 대신 PNG cICP로 기록할 수 있습니다.
            # PNG3의 RGB/full-range 및 SMPTE ST 2084(PQ) 전달 함수를 검증합니다.
            chunks = {}
            content = path.read_bytes()
            offset = 8
            while offset < len(content):
                size = int.from_bytes(content[offset:offset + 4], "big")
                kind = content[offset + 4:offset + 8]
                chunks[kind] = content[offset + 8:offset + 8 + size]
                offset += 12 + size
            assert b"cICP" in chunks, list(chunks)
            assert len(chunks[b"cICP"]) == 4
            assert chunks[b"cICP"][1:] == bytes([16, 0, 1]), chunks[b"cICP"]


def test_actual_multi_image_fixture_has_nonzero_hdr_primary(
    synthetic_nonzero_primary_hdr_heic, tmp_path
):
    import Quartz as quartz
    from Foundation import NSURL

    source = quartz.CGImageSourceCreateWithURL(
        NSURL.fileURLWithPath_(str(synthetic_nonzero_primary_hdr_heic)), None
    )
    assert source is not None
    assert quartz.CGImageSourceGetCount(source) == 2
    primary = quartz.CGImageSourceGetPrimaryImageIndex(source)
    assert primary == 1 and primary != 0
    assert quartz.CGImageSourceCopyAuxiliaryDataInfoAtIndex(
        source, 0, quartz.kCGImageAuxiliaryDataTypeHDRGainMap
    ) is None
    assert quartz.CGImageSourceCopyAuxiliaryDataInfoAtIndex(
        source, primary, quartz.kCGImageAuxiliaryDataTypeHDRGainMap
    ) is not None
    register_heif_opener()
    with Image.open(synthetic_nonzero_primary_hdr_heic) as image:
        assert image.n_frames == 2 and image.tell() == primary
        assert image.size == (256, 256)
        assert image.info["aux"][_APPLE_HDR_GAIN_MAP]
        assert image.getexif().get(34853)
        image.seek(0)
        assert image.size == (128, 96)
        assert not image.info.get("aux", {}).get(_APPLE_HDR_GAIN_MAP)

    # 코어를 거치지 않고 대표 인덱스로 실제 HDR 디코딩과 인코딩도 검증합니다.
    hdr = quartz.CGImageSourceCreateImageAtIndex(
        source,
        primary,
        {quartz.kCGImageSourceDecodeRequest: quartz.kCGImageSourceDecodeToHDR},
    )
    assert hdr is not None
    assert (quartz.CGImageGetWidth(hdr), quartz.CGImageGetHeight(hdr)) == (256, 256)
    reference = tmp_path / "대표 이미지 HDR.png"
    destination = quartz.CGImageDestinationCreateWithURL(
        NSURL.fileURLWithPath_(str(reference)), "public.png", 1, None
    )
    assert destination is not None
    quartz.CGImageDestinationAddImage(
        destination,
        hdr,
        {quartz.kCGImageDestinationEncodeRequest: quartz.kCGImageDestinationEncodeToISOHDR},
    )
    assert quartz.CGImageDestinationFinalize(destination)
    _assert_hdr_png_encoding(reference)


@pytest.mark.parametrize("metadata", ["safe", "preserve", "strip"])
def test_actual_hdr_png_uses_nonzero_primary_image(
    synthetic_nonzero_primary_hdr_heic, tmp_path, metadata
):
    original = synthetic_nonzero_primary_hdr_heic.read_bytes()
    output = tmp_path / f"multi-{metadata}.png"
    result = convert_image(
        synthetic_nonzero_primary_hdr_heic,
        output,
        output_format="png",
        metadata=metadata,
    )
    assert result.hdr_applied and result.sdr_reason is None
    assert synthetic_nonzero_primary_hdr_heic.read_bytes() == original
    assert not list(tmp_path.glob("*.native.png"))
    with Image.open(output) as image:
        image.load()
        assert image.size == (256, 256), "대표 HDR 이미지 대신 첫 SDR 이미지가 출력되었습니다."
        assert bool(image.getexif().get(34853)) == (metadata == "preserve")
        if metadata == "strip":
            assert not image.getexif() and not image.info.get("xmp")
    _assert_hdr_png_encoding(output)


@pytest.mark.parametrize("metadata", ["safe", "preserve", "strip"])
def test_actual_hdr_png_preserves_profile_and_metadata_policy(
    synthetic_hdr_heic, tmp_path, metadata
):
    original = synthetic_hdr_heic.read_bytes()
    output = tmp_path / f"{metadata}.png"
    result = convert_image(
        synthetic_hdr_heic, output, output_format="png", metadata=metadata
    )
    assert result.hdr_applied and result.sdr_reason is None
    assert synthetic_hdr_heic.read_bytes() == original
    _assert_hdr_png_encoding(output)
    with Image.open(output) as image:
        image.load()
        assert image.size == (256, 256)
        assert bool(image.getexif().get(34853)) == (metadata == "preserve")
        if metadata == "strip":
            assert not image.getexif() and not image.info.get("xmp")
    assert not list(tmp_path.glob("*.native.png"))


def test_actual_hdr_source_jpeg_reports_sdr(synthetic_hdr_heic, tmp_path):
    result = convert_image(
        synthetic_hdr_heic, tmp_path / "result.jpeg", output_format="jpeg"
    )
    assert not result.hdr_applied
    assert "JPEG" in result.sdr_reason

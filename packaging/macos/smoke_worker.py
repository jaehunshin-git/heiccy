"""재배포 사진 없이 합성 HEIC로 독립 worker의 JPEG/PNG 변환을 검증합니다."""

import io
import json
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageCms
from pillow_heif import from_pillow


def synthetic_hdr(directory: Path) -> Path:
    """합성 SDR 및 Apple 게인 맵으로 실제 PyObjC HDR 경로를 검사합니다."""
    import Quartz as quartz
    from Foundation import NSURL

    base = directory / "hdr-base.png"
    exif = Image.Exif()
    exif[34853] = {1: "N", 2: (37, 1)}
    profile = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
    Image.new("RGB", (256, 256), (60, 100, 180)).save(
        base,
        exif=exif.tobytes(),
        icc_profile=profile,
    )
    source = quartz.CGImageSourceCreateWithURL(NSURL.fileURLWithPath_(str(base)), None)
    path = directory / "합성 HDR 사진.heic"
    destination = quartz.CGImageDestinationCreateWithURL(
        NSURL.fileURLWithPath_(str(path)),
        "public.heic",
        1,
        None,
    )
    assert destination is not None
    quartz.CGImageDestinationAddImageFromSource(destination, source, 0, None)
    metadata = quartz.CGImageMetadataCreateMutable()
    registered, error = quartz.CGImageMetadataRegisterNamespaceForPrefix(
        metadata,
        "http://ns.apple.com/HDRGainMap/1.0/",
        "HDRGainMap",
        None,
    )
    assert registered and error is None
    for key, value in (("HDRGainMapVersion", "65536"), ("HDRGainMapHeadroom", "2.0")):
        assert quartz.CGImageMetadataSetValueWithPath(
            metadata, None, f"HDRGainMap:{key}", value
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
                "PixelFormat": 0x4C303038,
            },
            quartz.kCGImageAuxiliaryDataInfoMetadata: metadata,
        },
    )
    assert quartz.CGImageDestinationFinalize(destination)
    return path


def smoke(worker: Path) -> None:
    worker = worker.resolve()
    with tempfile.TemporaryDirectory(prefix="heic 앱 검증 ") as temporary:
        directory = Path(temporary).resolve()
        source = directory / "합성 입력.HEIC"
        from_pillow(Image.new("RGB", (24, 16), "#3868b5")).save(source)
        environment = {
            "PATH": "/usr/bin:/bin",
            "HOME": str(directory),
            "TMPDIR": str(directory),
            "LANG": "en_US.UTF-8",
        }
        for output_format in ("jpeg", "png"):
            destination = directory / output_format
            job = f"packaged-{output_format}"
            requests = [
                {
                    "protocol_version": 1,
                    "job_id": job,
                    "command": "prepare",
                    "files": [str(source)],
                    "output_directory": str(destination),
                    "options": {"output_format": output_format, "metadata": "safe"},
                },
                {"protocol_version": 1, "job_id": job, "command": "run"},
            ]
            result = subprocess.run(
                [str(worker)],
                input="".join(json.dumps(request) + "\n" for request in requests),
                capture_output=True,
                text=True,
                env=environment,
                timeout=60,
                check=False,
            )
            assert result.returncode == 0, result.stderr
            events = [json.loads(line) for line in result.stdout.splitlines()]
            assert any(event.get("event") == "file_succeeded" for event in events), (
                events
            )
            assert any(event.get("event") == "completed" for event in events), events
            assert not any(
                event.get("event") in {"file_failed", "error"} for event in events
            ), events
            image_path = destination / f"합성 입력.{output_format}"
            with Image.open(image_path) as converted:
                assert converted.size == (24, 16)
                assert converted.format == output_format.upper()
            assert all(event.get("protocol_version") == 1 for event in events), events
        hdr_source = synthetic_hdr(directory)
        original = hdr_source.read_bytes()
        hdr_output = directory / "hdr"
        requests = [
            {
                "protocol_version": 1,
                "job_id": "packaged-hdr",
                "command": "prepare",
                "files": [str(hdr_source)],
                "output_directory": str(hdr_output),
                "options": {"output_format": "png", "metadata": "safe"},
            },
            {"protocol_version": 1, "job_id": "packaged-hdr", "command": "run"},
        ]
        result = subprocess.run(
            [str(worker)],
            input="".join(json.dumps(item) + "\n" for item in requests),
            capture_output=True,
            text=True,
            env=environment,
            timeout=60,
            check=False,
        )
        assert result.returncode == 0, result.stderr
        events = [json.loads(line) for line in result.stdout.splitlines()]
        successful = next(
            item for item in events if item.get("event") == "file_succeeded"
        )
        assert successful["hdr_applied"] and successful["sdr_reason"] is None, events
        assert any(item.get("event") == "completed" for item in events), events
        png = hdr_output / "합성 HDR 사진.png"
        content = png.read_bytes()
        assert content[24] == 16
        with Image.open(png) as image:
            assert image.size == (256, 256)
            if image.info.get("icc_profile"):
                profile = ImageCms.ImageCmsProfile(
                    io.BytesIO(image.info["icc_profile"])
                )
                assert "PQ" in ImageCms.getProfileDescription(profile)
            else:
                chunks = {}
                offset = 8
                while offset < len(content):
                    size = int.from_bytes(content[offset : offset + 4], "big")
                    chunks[content[offset + 4 : offset + 8]] = content[
                        offset + 8 : offset + 8 + size
                    ]
                    offset += 12 + size
                assert chunks[b"cICP"][1:] == bytes([16, 0, 1]), chunks
            assert not image.getexif().get(34853)
        assert hdr_source.read_bytes() == original
        assert source.is_file()
    print(
        "사용자 Python 없는 PATH/HOME에서 합성 HEIC JPEG/PNG 및 16비트 PQ HDR worker 변환 검증 완료"
    )


if __name__ == "__main__":
    smoke(Path(sys.argv[1]))

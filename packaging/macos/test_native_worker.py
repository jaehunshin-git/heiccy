"""합성 HEIC만 사용하는 네이티브 worker JSONL/변환 통합 검사.

실행: .venv-app-build/bin/python packaging/macos/test_native_worker.py /절대/경로/heic-worker
모든 입력·출력과 충돌 대상은 임시 폴더에서 생성하고 종료 시 삭제한다.
실패는 FAIL, fixture/경합을 입증할 수 없는 경우는 SKIP으로 별도 집계한다.
strip은 앱 정책에 따라 유효한 ICC 색상 프로필 보존을 허용한다. GPS/EXIF/XMP 및 JPEG의 빈 EXIF APP1은 허용하지 않는다.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import queue
import re
import shutil
import struct
import subprocess
import tempfile
import threading
import time
import traceback
import zlib
from collections import Counter
from pathlib import Path

from PIL import Image, ImageCms, ImageDraw, ImageStat
from pillow_heif import from_bytes, register_heif_opener

CAMERA = "heiccy synthetic Camera"
DATE = "2026:01:02 03:04:05"
PRIVATE_XMP = "HEICCY_PRIVATE_XMP_729184"
ICC_MARKER = "heiccy source"
TERMINAL = {"completed", "cancelled", "error"}
register_heif_opener()


def require(condition, message):
    if not condition:
        raise AssertionError(message)


class Unavailable(Exception):
    """환경이나 경합 때문에 해당 검사 자체를 입증하지 못한 경우."""


def request(command, job="job-한글 공백", **fields):
    return {"protocol_version": 1, "job_id": job, "command": command, **fields}


def prepare(files, output, **options):
    return request("prepare", files=[str(p) for p in files],
                   output_directory=str(output), options=options)


def parse_line(line):
    record = json.loads(line)
    require(isinstance(record, dict), f"JSON 객체가 아닌 stdout: {record!r}")
    require(type(record.get("protocol_version")) is int
            and record["protocol_version"] == 1, f"응답 버전: {record}")
    require(record.get("event") in {
        "prepared", "file_started", "file_succeeded", "file_skipped",
        "file_failed", "completed", "cancelled", "error",
    }, f"알 수 없는 응답: {record}")
    require(record.get("job_id") is None or isinstance(record["job_id"], str),
            f"응답 job_id: {record}")
    return record


class Client:
    """stdin을 최종 이벤트까지 열어 두는 시간 제한 JSONL 클라이언트."""

    def __init__(self, worker, directory, timeout=60):
        self.worker, self.directory, self.timeout = worker, directory, timeout
        self.environment = {"PATH": "/usr/bin:/bin", "HOME": str(directory),
                            "TMPDIR": str(directory), "LANG": "en_US.UTF-8"}
        self.records = []
        self.lines = queue.Queue()

    def __enter__(self):
        self.diagnostic = tempfile.TemporaryFile(mode="w+t", encoding="utf-8")
        try:
            self.process = subprocess.Popen(
                [str(self.worker)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=self.diagnostic, text=True, encoding="utf-8", bufsize=1,
                env=self.environment, cwd=self.directory,
            )
        except BaseException:
            self.diagnostic.close()
            raise
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()
        return self

    def _read(self):
        try:
            for line in self.process.stdout:
                self.lines.put(line)
        finally:
            self.lines.put(None)

    def send(self, value):
        self.process.stdin.write((value if isinstance(value, str)
                                  else json.dumps(value, ensure_ascii=False)) + "\n")
        self.process.stdin.flush()

    def next(self, timeout=None):
        try:
            line = self.lines.get(timeout=self.timeout if timeout is None else timeout)
        except queue.Empty as exc:
            raise AssertionError(f"응답 시간 초과; 마지막 이벤트: {self.records[-3:]}") from exc
        require(line is not None, f"최종 응답 전 stdout EOF: {self.records[-3:]}")
        record = parse_line(line)
        self.records.append(record)
        return record

    def until_terminal(self, first=None):
        records = [] if first is None else [first]
        deadline = time.monotonic() + self.timeout
        while not records or records[-1]["event"] not in TERMINAL:
            remaining = deadline - time.monotonic()
            require(remaining > 0, "최종 이벤트 시간 초과")
            records.append(self.next(remaining))
        return records

    def finish(self):
        self.process.stdin.close()
        self.process.wait(timeout=self.timeout)
        self.reader.join(timeout=5)
        require(not self.reader.is_alive(), "stdout reader 종료 시간 초과")
        while not self.lines.empty():
            line = self.lines.get_nowait()
            if line is not None:
                self.records.append(parse_line(line))
        self.diagnostic.seek(0)
        require(self.process.returncode == 0,
                f"worker 종료 {self.process.returncode}: {self.diagnostic.read()[-4000:]}")

    def __exit__(self, *_):
        if self.process.poll() is None:
            self.process.kill()
        self.process.wait(timeout=5)
        if not self.process.stdin.closed:
            self.process.stdin.close()
        self.reader.join(timeout=5)
        self.process.stdout.close()
        self.diagnostic.close()


def eof_job(worker, directory, files, output, **options):
    """완전한 prepare/run 페이로드 뒤 EOF도 Python처럼 작업을 완료해야 한다."""
    payload = "".join(json.dumps(item, ensure_ascii=False) + "\n" for item in
                      [prepare(files, output, **options), request("run")])
    result = subprocess.run(
        [str(worker)], input=payload, capture_output=True, text=True, encoding="utf-8",
        env={"PATH": "/usr/bin:/bin", "HOME": str(directory), "TMPDIR": str(directory),
             "LANG": "en_US.UTF-8"}, cwd=directory, timeout=90, check=False,
    )
    require(result.returncode == 0, f"종료 {result.returncode}: {result.stderr[-4000:]}")
    records = [parse_line(line) for line in result.stdout.splitlines()]
    require(records and records[0]["event"] == "prepared", f"prepared 누락: {records}")
    require(all(r.get("job_id") == "job-한글 공백" for r in records), records)
    return records


def batch(records, files, counts, *, terminal="completed"):
    require(not any(r["event"] == "error" for r in records), records)
    final = records[-1]
    require(final["event"] == terminal, f"최종 이벤트: {final}")
    for name in ("succeeded", "skipped", "failed", "total"):
        require(type(final.get(name)) is int, f"집계 타입: {final}")
    require(tuple(final[k] for k in ("succeeded", "skipped", "failed")) == counts,
            f"집계 기대 {counts}, 실제 {final}")
    require(final["total"] == len(files), final)
    starts = [r for r in records if r["event"] == "file_started"]
    results = [r for r in records if r["event"] in
               {"file_succeeded", "file_skipped", "file_failed"}]
    require(len(starts) == len(results) == sum(counts), f"파일별 이벤트 수: {records}")
    require([r["source"] for r in starts] == [str(p) for p in files[:sum(counts)]],
            f"처리 순서: {starts}")
    stream = [r for r in records if r["event"].startswith("file_")]
    require(len(stream) == 2 * len(starts), stream)
    for index, (start, result) in enumerate(zip(starts, results, strict=True), 1):
        require(stream[2 * index - 2:2 * index] == [start, result], stream)
        for r in (start, result):
            require(type(r.get("index")) is int and r["index"] == index
                    and type(r.get("total")) is int and r["total"] == len(files), r)
        require(start["source"] == result["source"], result)
        if result["event"] == "file_succeeded":
            require(type(result.get("hdr_applied")) is bool, result)
            require(result.get("sdr_reason") is None if result["hdr_applied"]
                    else isinstance(result.get("sdr_reason"), str)
                    and bool(result["sdr_reason"]), result)
            require(Path(result["destination"]).is_absolute(), result)
        elif result["event"] == "file_failed":
            require(isinstance(result.get("error"), str) and result["error"], result)
            require(isinstance(result.get("error_code"), str), result)
        else:
            require(isinstance(result.get("reason"), str) and result["reason"], result)
    expected_remaining = [str(p) for p in files[sum(counts):]]
    require(final.get("remaining") == expected_remaining, final)
    require(terminal == "cancelled" or sum(counts) == len(files), final)


def pattern(size=(160, 96), alpha=False):
    image = Image.new("RGBA" if alpha else "RGB", size)
    draw = ImageDraw.Draw(image)
    w, h = size
    colors = [(220, 35, 20), (20, 190, 45), (25, 45, 215), (235, 195, 25)]
    boxes = [(0, 0, w // 2 - 1, h // 2 - 1), (w // 2, 0, w - 1, h // 2 - 1),
             (0, h // 2, w // 2 - 1, h - 1), (w // 2, h // 2, w - 1, h - 1)]
    for index, (box, color) in enumerate(zip(boxes, colors, strict=True)):
        draw.rectangle(box, fill=color + ((0 if index == 0 else 128 if index == 1 else 255),)
                       if alpha else color)
    return image


def tagged_profile():
    data = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
    original = "sRGB built-in".encode("utf-16-be")
    replacement = ICC_MARKER.encode("utf-16-be")
    require(len(original) == len(replacement) and data.count(original) == 1,
            "ICC fixture 설명 위치를 찾지 못했습니다")
    return data.replace(original, replacement)


def xmp(orientation):
    return (f'<x:xmpmeta xmlns:x="adobe:ns:meta/">'
            '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
            '<rdf:Description xmlns:tiff="http://ns.adobe.com/tiff/1.0/" '
            'xmlns:dc="http://purl.org/dc/elements/1.1/" '
            f'tiff:Orientation="{orientation}" dc:description="{PRIVATE_XMP}"/>'
            '</rdf:RDF></x:xmpmeta>').encode()


def fixture(path, *, orientation=1, metadata=False, size=(160, 96), alpha=False):
    import Quartz as quartz
    from Foundation import NSURL

    image = pattern(size, alpha)
    exif = Image.Exif()
    exif[274] = orientation
    if metadata:
        exif[271] = CAMERA
        exif[306] = DATE
        exif[34665] = {36867: DATE}
        exif[34853] = {1: "N", 2: (37.0, 0.0, 0.0),
                       3: "E", 4: (127.0, 0.0, 0.0)}
    # from_pillow의 사전 방향 변환을 피하고 원본 픽셀을 직접 전달한다.
    encoded = from_bytes(image.mode, image.size, image.tobytes())
    if metadata:
        encoded[0].info["icc_profile"] = tagged_profile()
    encoded.save(path, quality=100, chroma="444", exif=exif.tobytes(),
                 xmp=xmp(orientation) if metadata else None)
    native = quartz.CGImageSourceCreateWithURL(NSURL.fileURLWithPath_(str(path)), None)
    require(native is not None, "ImageIO가 합성 HEIC를 읽지 못했습니다")
    props = quartz.CGImageSourceCopyPropertiesAtIndex(native, 0, None)
    require(props.get(quartz.kCGImagePropertyOrientation, 1) == orientation,
            f"fixture 방향을 ImageIO로 입증하지 못했습니다: {props}")
    with Image.open(path) as decoded:
        decoded.load()
        if metadata:
            require(decoded.getexif().get(271) == CAMERA, "fixture Camera 누락")
            require(decoded.getexif().get_ifd(34853), "fixture GPS 누락")
            require(PRIVATE_XMP.encode() in decoded.info.get("xmp", b""), "fixture XMP 누락")
            require(ICC_MARKER.encode("utf-16-be") in decoded.info.get("icc_profile", b""),
                    "fixture ICC 누락")
        # pillow-heif는 HEIF의 회전·반전을 적용하고 EXIF Orientation을 1로 정규화한다.
        expected = decoded.copy()
    return expected


def opened(path, output_format):
    with Image.open(path) as image:
        require(image.format == output_format.upper(), f"출력 형식: {image.format}")
        image.load()
        return image.copy()


def pixels(actual, expected, tolerance=18):
    require(actual.size == expected.size, f"크기 {actual.size} != {expected.size}")
    actual, expected = actual.convert("RGB"), expected.convert("RGB")
    w, h = expected.size
    for x, y in ((w // 4, h // 4), (3 * w // 4, h // 4),
                 (w // 4, 3 * h // 4), (3 * w // 4, 3 * h // 4)):
        box = (x - 3, y - 3, x + 4, y + 4)
        a = ImageStat.Stat(actual.crop(box)).mean
        e = ImageStat.Stat(expected.crop(box)).mean
        require(max(abs(v - r) for v, r in zip(a, e, strict=True)) <= tolerance,
                f"비대칭 모서리 ({x},{y}): 실제 {a}, Pillow 기준 {e}")


def png_chunks(path):
    content = path.read_bytes()
    require(content.startswith(b"\x89PNG\r\n\x1a\n"), "PNG signature")
    chunks, offset = [], 8
    while offset < len(content):
        require(offset + 12 <= len(content), "잘린 PNG 헤더")
        length = struct.unpack_from(">I", content, offset)[0]
        kind = content[offset + 4:offset + 8]
        data = content[offset + 8:offset + 8 + length]
        require(offset + 12 + length <= len(content), f"잘린 PNG {kind}")
        crc = struct.unpack_from(">I", content, offset + 8 + length)[0]
        require(crc == zlib.crc32(kind + data), f"PNG CRC {kind}")
        chunks.append((kind, data))
        offset += length + 12
    require(chunks and chunks[0][0] == b"IHDR" and chunks[-1] == (b"IEND", b""),
            "PNG IHDR/IEND")
    return chunks


def jpeg_segments(path):
    content = path.read_bytes()
    require(content.startswith(b"\xff\xd8"), "JPEG SOI")
    segments, offset = [], 2
    while offset < len(content):
        require(content[offset] == 255, "잘못된 JPEG marker")
        while content[offset] == 255:
            offset += 1
        marker = content[offset]
        offset += 1
        if marker in (0xDA, 0xD9):
            break
        if marker == 0x01 or 0xD0 <= marker <= 0xD7:
            continue
        length = int.from_bytes(content[offset:offset + 2], "big")
        require(length >= 2 and offset + length <= len(content), "잘린 JPEG segment")
        segments.append((marker, content[offset + 2:offset + length]))
        offset += length
    return segments


def assert_metadata(path, output_format, mode):
    import Quartz as quartz
    from Foundation import NSURL

    with Image.open(path) as image:
        image.load()
        exif = image.getexif()
        info = dict(image.info)
        camera = exif.get(271)
        date = exif.get_ifd(34665).get(36867) if exif.get(34665) else exif.get(36867)
        gps = exif.get_ifd(34853) if exif.get(34853) else {}
        source = quartz.CGImageSourceCreateWithURL(NSURL.fileURLWithPath_(str(path)), None)
        props = quartz.CGImageSourceCopyPropertiesAtIndex(source, 0, None)
        metadata = quartz.CGImageSourceCopyMetadataAtIndex(source, 0, None)
        packet = quartz.CGImageMetadataCreateXMPData(metadata, None) if metadata else None
        native_xmp = bytes(packet) if packet else b""
        all_metadata = repr((dict(exif), info, dict(props))).encode() + native_xmp
        if mode == "strip":
            require(not exif, f"strip EXIF가 남음: {dict(exif)}")
            require(not gps and not props.get(quartz.kCGImagePropertyGPSDictionary),
                    "strip GPS가 남음")
            require(not any(info.get(k) for k in ("xmp", "XML:com.adobe.xmp")),
                    "strip XMP가 남음")
            require(CAMERA.encode() not in all_metadata and PRIVATE_XMP.encode() not in all_metadata,
                    "strip 원본 Camera/XMP가 남음")
            if info.get("icc_profile"):
                ImageCms.ImageCmsProfile(io.BytesIO(info["icc_profile"]))
            if output_format == "jpeg":
                require(not any(marker == 0xE1 for marker, _ in jpeg_segments(path)),
                        "strip JPEG APP1(EXIF/XMP/빈 IFD)이 남음")
        else:
            require(camera == CAMERA, f"원본 EXIF Camera 누락: {dict(exif)}")
            require(date == DATE, f"원본 EXIF 촬영 시각 누락: {date!r}")
            require(exif.get(274, 1) == 1, f"EXIF 방향 미정규화: {exif.get(274)}")
            icc = info.get("icc_profile", b"")
            require(icc and ICC_MARKER.encode("utf-16-be") in icc,
                    "safe/preserve 원본 ICC 누락")
            ImageCms.ImageCmsProfile(io.BytesIO(icc))
            if mode == "safe":
                require(not gps and not props.get(quartz.kCGImagePropertyGPSDictionary),
                        "safe GPS가 남음")
                require(not info.get("xmp") and not info.get("XML:com.adobe.xmp")
                        and not exif.get(700), "safe XMP가 남음")
                require(PRIVATE_XMP.encode() not in path.read_bytes()
                        and PRIVATE_XMP.encode() not in all_metadata,
                        "safe XMP 비공개 표식이 EXIF/출력에 유출됨")
            else:
                require(gps.get(1) == "N" and tuple(gps.get(2, ())) == (37.0, 0.0, 0.0),
                        f"preserve GPS 값 누락: {gps}")
                require(PRIVATE_XMP.encode() in all_metadata, "preserve XMP 표식 누락")
                orientation_values = re.findall(
                    rb'tiff:Orientation(?:\s*=\s*["\x27](\d+)["\x27]|>(\d+)<)',
                    native_xmp + info.get("xmp", b""))
                require(all((a or b) == b"1" for a, b in orientation_values),
                        f"preserve XMP 방향 미정규화: {orientation_values}")
        if output_format == "png":
            kinds = [kind for kind, _ in png_chunks(path)]
            if mode in {"safe", "strip"}:
                require(not set(kinds) & {b"iTXt", b"tEXt", b"zTXt"},
                        f"{mode} PNG 텍스트 메타데이터: {kinds}")
            if mode == "strip":
                require(b"eXIf" not in kinds, "strip PNG eXIf가 남음")


def no_temporary(output):
    require(not any(p.name.startswith(".") for p in output.iterdir()),
            f"원자 저장 임시 파일이 남음: {list(output.iterdir())}")


def hdr_fixture(directory):
    """기존 게인 맵 fixture에 ImageIO/Pillow 양쪽에서 유효한 GPS를 넣는다."""
    import Quartz as quartz
    from Foundation import NSURL
    from smoke_worker import synthetic_hdr

    base = synthetic_hdr(directory)
    source = quartz.CGImageSourceCreateWithURL(NSURL.fileURLWithPath_(str(base)), None)
    primary = quartz.CGImageSourceGetPrimaryImageIndex(source)
    gain_map = quartz.CGImageSourceCopyAuxiliaryDataInfoAtIndex(
        source, primary, quartz.kCGImageAuxiliaryDataTypeHDRGainMap)
    require(gain_map is not None, "합성 HDR 게인 맵 누락")
    path = directory / "유효 GPS HDR.heic"
    destination = quartz.CGImageDestinationCreateWithURL(
        NSURL.fileURLWithPath_(str(path)), "public.heic", 1, None)
    require(destination is not None, "HDR fixture encoder 생성 실패")
    quartz.CGImageDestinationAddImageFromSource(destination, source, primary, {
        quartz.kCGImagePropertyGPSDictionary: {
            quartz.kCGImagePropertyGPSLatitude: 37.0,
            quartz.kCGImagePropertyGPSLatitudeRef: "N",
            quartz.kCGImagePropertyGPSLongitude: 127.0,
            quartz.kCGImagePropertyGPSLongitudeRef: "E",
        },
    })
    quartz.CGImageDestinationAddAuxiliaryDataInfo(
        destination, quartz.kCGImageAuxiliaryDataTypeHDRGainMap, gain_map)
    require(quartz.CGImageDestinationFinalize(destination), "HDR fixture 저장 실패")
    native = quartz.CGImageSourceCreateWithURL(NSURL.fileURLWithPath_(str(path)), None)
    props = quartz.CGImageSourceCopyPropertiesAtIndex(native, 0, None)
    gps = props.get(quartz.kCGImagePropertyGPSDictionary, {})
    require(gps.get(quartz.kCGImagePropertyGPSLatitude) == 37.0
            and gps.get(quartz.kCGImagePropertyGPSLongitude) == 127.0,
            f"HDR fixture ImageIO GPS 누락: {gps}")
    with Image.open(path) as image:
        gps = image.getexif().get_ifd(34853)
        require(gps.get(1) == "N" and gps.get(3) == "E"
                and tuple(gps.get(2, ())) == (37.0, 0.0, 0.0)
                and tuple(gps.get(4, ())) == (127.0, 0.0, 0.0),
                f"HDR fixture Pillow GPS 누락: {gps}")
    return path


class Suite:
    def __init__(self, worker, root, verbose=False):
        self.worker, self.root, self.verbose = worker, root, verbose
        self.counts = Counter()
        self.number = 0

    def check(self, name, function):
        self.number += 1
        directory = self.root / f"check-{self.number:03d}"
        directory.mkdir()
        start = time.monotonic()
        try:
            function(directory)
        except Unavailable as exc:
            self.counts["SKIP"] += 1
            print(f"SKIP {name}: {exc}", flush=True)
        except Exception as exc:
            self.counts["FAIL"] += 1
            print(f"FAIL {name}: {type(exc).__name__}: {exc}", flush=True)
            if self.verbose:
                traceback.print_exc()
        else:
            self.counts["PASS"] += 1
            print(f"PASS {name} ({time.monotonic() - start:.2f}s)", flush=True)

    def normal(self, directory, output_format):
        source = directory / "한글 공백.HEIC"
        expected = fixture(source)
        original = source.read_bytes()
        output = directory / "out"
        records = eof_job(self.worker, directory, [source], output, output_format=output_format)
        batch(records, [source], (1, 0, 0))
        require([r["event"] for r in records] ==
                ["prepared", "file_started", "file_succeeded", "completed"], records)
        require(records[0]["files"] == [str(source)] and records[0]["rejected"] == [], records)
        pixels(opened(output / f"한글 공백.{output_format}", output_format), expected)
        require(source.read_bytes() == original, "원본 변경")
        no_temporary(output)

    def invalid(self, directory, update, expected_code="invalid_request"):
        value = prepare([], directory / "out")
        if isinstance(update, dict):
            value.update(update)
        else:
            value = update
        with Client(self.worker, directory) as client:
            client.send(value)
            response = client.next()
            require(response["event"] == "error" and response.get("error_code") == expected_code,
                    response)
            if isinstance(value, dict) and isinstance(value.get("job_id"), str):
                require(response["job_id"] == value["job_id"], response)
            client.send(prepare([], directory / "recovery"))
            require(client.next()["event"] == "prepared", "오류 후 복구 실패")
            client.send(request("run"))
            batch(client.until_terminal(), [], (0, 0, 0))
            client.finish()
            require(not (directory / "out").exists(), "잘못된 요청이 출력 폴더를 생성함")

    def rejected(self, directory):
        first, second = directory / "사진 10.HEIC", directory / "사진 2.heic"
        fixture(first)
        shutil.copyfile(first, second)
        link = directory / "링크.heic"
        link.symlink_to(first)
        unsupported = directory / "other.heif"
        unsupported.write_bytes(b"synthetic")
        missing = directory / "missing.heic"
        files = [first, second, first, link, unsupported, directory, missing]
        output = directory / "out"
        with Client(self.worker, directory) as client:
            client.send(prepare(files, output))
            response = client.next()
            require(response["event"] == "prepared" and response["total"] == 2, response)
            require(response["files"] == [str(second), str(first)], response)
            rejected = response["rejected"]
            require([r["source"] for r in rejected] == [str(p) for p in files[2:]], rejected)
            require(all(isinstance(r.get("reason"), str) and r["reason"] for r in rejected), rejected)
            require(not output.exists(), "prepare가 출력 폴더를 생성함")
            client.send(request("run"))
            batch(client.until_terminal(), [second, first], (2, 0, 0))
            client.finish()

    def partial(self, directory, delete=False):
        sources = [directory / f"{i}.heic" for i in range(1, 4)]
        fixture(sources[0])
        sources[1].write_bytes(b"synthetic corrupt HEIC")
        shutil.copyfile(sources[0], sources[2])
        output = directory / "out"
        with Client(self.worker, directory) as client:
            client.send(prepare(sources, output))
            require(client.next()["total"] == 3, "prepare가 corrupt 입력을 잘못 제외함")
            if delete:
                sources[0].unlink()
            originals = {p: p.read_bytes() for p in sources if p.exists()}
            client.send(request("run"))
            records = client.until_terminal()
            batch(records, sources, (1 if delete else 2, 0, 2 if delete else 1))
            failures = [r["error_code"] for r in records if r["event"] == "file_failed"]
            require(failures == (["input_missing", "conversion_failed"] if delete
                                 else ["conversion_failed"]), failures)
            client.finish()
            require(all(p.read_bytes() == data for p, data in originals.items()), "원본 변경")
            opened(output / "3.jpeg", "jpeg")
            no_temporary(output)

    def conflict(self, directory, policy, duplicate=False, dangling=False):
        source = directory / "same.heic"
        fixture(source)
        sources = [source]
        output = directory / "out"
        output.mkdir()
        target = output / "same.jpeg"
        sentinel = b"synthetic existing output must survive"
        if duplicate:
            folder = directory / "nested"
            folder.mkdir()
            other = folder / source.name
            shutil.copyfile(source, other)
            sources = [other, source]  # 전체 경로의 자연 정렬 결과도 검증한다.
        elif dangling:
            target.symlink_to(directory / "missing-target")
        else:
            target.write_bytes(sentinel)
        originals = {p: p.read_bytes() for p in sources}
        records = eof_job(self.worker, directory, sources, output, on_conflict=policy)
        ordered = [Path(p) for p in records[0]["files"]]
        require(set(ordered) == set(sources), records[0])
        counts = {"rename": (len(sources), 0, 0),
                  "skip": (1, 1, 0) if duplicate else (0, 1, 0),
                  "error": (1, 0, 1) if duplicate else (0, 0, 1),
                  "overwrite": (len(sources), 0, 0)}[policy]
        batch(records, ordered, counts)
        if policy == "error":
            require([r["error_code"] for r in records if r["event"] == "file_failed"]
                    == ["name_conflict"], records)
        expected_names = {"same.jpeg", "same-2.jpeg"} if policy == "rename" else {"same.jpeg"}
        require({p.name for p in output.iterdir()} == expected_names, list(output.iterdir()))
        if dangling and policy != "overwrite":
            require(target.is_symlink(), "출력 링크가 변경됨")
        elif not duplicate and policy != "overwrite":
            require(target.read_bytes() == sentinel, "기존 출력이 변경됨")
        if counts[0]:
            opened(output / ("same-2.jpeg" if policy == "rename" else "same.jpeg"), "jpeg")
        require(not (directory / "missing-target").exists(), "symlink 대상에 출력됨")
        require(all(p.read_bytes() == data for p, data in originals.items()), "원본 변경")
        no_temporary(output)

    def orientation(self, directory, orientation, output_format, mode="safe", *, metadata=True):
        source = directory / "orientation.heic"
        expected = fixture(source, orientation=orientation, metadata=metadata)
        original = source.read_bytes()
        output = directory / "out"
        records = eof_job(self.worker, directory, [source], output,
                          output_format=output_format, metadata=mode)
        batch(records, [source], (1, 0, 0))
        target = output / f"orientation.{output_format}"
        pixels(opened(target, output_format), expected)
        if metadata:
            assert_metadata(target, output_format, mode)
        require(source.read_bytes() == original, "원본 변경")
        no_temporary(output)

    def compression(self, directory):
        source = directory / "compression.heic"
        expected = fixture(source, size=(768, 512))
        original = source.read_bytes()
        targets = []
        for level in (0, 9):
            output = directory / f"level-{level}"
            records = eof_job(self.worker, directory, [source], output,
                              output_format="png", png_compression=level, metadata="strip")
            batch(records, [source], (1, 0, 0))
            target = output / "compression.png"
            png_chunks(target)
            pixels(opened(target, "png"), expected)
            targets.append(target)
        require(opened(targets[0], "png").tobytes() == opened(targets[1], "png").tobytes(),
                "PNG 압축 레벨이 픽셀을 바꿈")
        sizes = [p.stat().st_size for p in targets]
        require(sizes[0] > sizes[1], f"PNG 0이 9보다 크지 않음: {sizes}")
        require(source.read_bytes() == original, "원본 변경")

    def alpha(self, directory, output_format):
        source = directory / "alpha.heic"
        decoded = fixture(source, alpha=True)
        if "A" not in decoded.getbands() or decoded.getchannel("A").getextrema() != (0, 255):
            raise Unavailable("HEIC fixture가 투명도를 보존하지 못함")
        original = source.read_bytes()
        output = directory / "out"
        records = eof_job(self.worker, directory, [source], output, output_format=output_format)
        batch(records, [source], (1, 0, 0))
        image = opened(output / f"alpha.{output_format}", output_format)
        if output_format == "jpeg":
            expected = Image.new("RGB", decoded.size, "white")
            expected.paste(decoded.convert("RGBA"), mask=decoded.getchannel("A"))
            pixels(image, expected)
            require(min(image.convert("RGB").getpixel((40, 24))) >= 245,
                    "완전 투명 JPEG 영역이 흰색이 아님")
        else:
            require("A" in image.getbands(), "PNG alpha 누락")
            for point in ((40, 24), (120, 24), (40, 72), (120, 72)):
                require(abs(image.getpixel(point)[3] - decoded.getpixel(point)[3]) <= 2,
                        f"PNG alpha 변경: {point}")
        require(source.read_bytes() == original, "원본 변경")

    def cancellation(self, directory):
        source = directory / "000.heic"
        fixture(source, size=(1600, 1024))
        files = [source]
        for index in range(1, 32):
            target = directory / f"{index:03d}.heic"
            shutil.copyfile(source, target)
            files.append(target)
        originals = {p: hashlib.sha256(p.read_bytes()).digest() for p in files}
        output = directory / "out"
        with Client(self.worker, directory, timeout=90) as client:
            client.send(prepare(files, output, output_format="png", png_compression=9))
            require(client.next()["event"] == "prepared", "prepared 누락")
            client.send(request("run"))
            first = client.next()
            require(first["event"] == "file_started", first)
            client.send(request("cancel"))  # EOF나 신호가 아니라 실제 열린 stdin 명령.
            records = client.until_terminal(first)
            final = records[-1]
            require(final["event"] == "cancelled" and final.get("remaining"),
                    f"실행 중 stdin 취소가 적용되지 않음: {final}")
            counts = tuple(final.get(k) for k in ("succeeded", "skipped", "failed"))
            require(counts[0] >= 1 and counts[1:] == (0, 0), final)
            batch(records, files, counts, terminal="cancelled")
            require(not client.process.stdin.closed and client.process.poll() is None,
                    "최종 이벤트 전에 stdin/worker가 종료됨")
            for record in records:
                if record["event"] == "file_succeeded":
                    opened(Path(record["destination"]), "png")
            require(len(list(output.iterdir())) == counts[0], "취소 후 추가 파일/임시 파일")
            client.send(prepare([source], directory / "recovery"))
            require(client.next()["event"] == "prepared", "취소 후 다음 작업 준비 실패")
            client.send(request("run"))
            batch(client.until_terminal(), [source], (1, 0, 0))
            client.finish()
        require(all(hashlib.sha256(p.read_bytes()).digest() == digest
                    for p, digest in originals.items()), "취소가 원본을 변경함")
        no_temporary(output)

    def late_collision(self, directory, policy):
        source = directory / "late.heic"
        fixture(source, size=(2400, 1600))
        original = source.read_bytes()
        output = directory / "out"
        output.mkdir()
        target = output / "late.png"
        sentinel = b"synthetic concurrent creator"
        observed = threading.Event()
        stop = threading.Event()
        errors = []

        def watch():
            # 이름 계획 이후 임시 저장이 실제 시작된 것을 보고 충돌을 주입한다.
            # 관찰 불가능한 구현/너무 빠른 저장은 경합 검증 성공으로 간주하지 않는다.
            while not stop.is_set():
                try:
                    if any(p.name.startswith(".") for p in output.iterdir()):
                        with target.open("xb") as file:
                            file.write(sentinel)
                        observed.set()
                        return
                except FileExistsError:
                    return
                except Exception as exc:
                    errors.append(exc)
                    return
                stop.wait(0.001)

        watcher = threading.Thread(target=watch, daemon=True)
        watcher.start()
        try:
            records = eof_job(self.worker, directory, [source], output,
                              output_format="png", png_compression=9, on_conflict=policy)
        finally:
            stop.set()
            watcher.join(timeout=5)
        require(not errors, f"경합 관찰자 오류: {errors}")
        require(source.read_bytes() == original, "원본 변경")
        if not observed.is_set():
            raise Unavailable("원자 저장 임시 파일을 관찰하지 못해 늦은 충돌 미입증")
        counts = {"rename": (1, 0, 0), "skip": (0, 1, 0),
                  "error": (0, 0, 1), "overwrite": (1, 0, 0)}[policy]
        batch(records, [source], counts)
        if policy == "overwrite":
            opened(target, "png")
        else:
            require(target.read_bytes() == sentinel, "늦게 생성한 파일이 덮어써짐")
            if policy == "rename":
                opened(output / "late-2.png", "png")
        if policy == "error":
            require(next(r for r in records if r["event"] == "file_failed")["error_code"]
                    == "name_conflict", records)
        no_temporary(output)

    def hdr(self, directory, mode, output_format="png"):
        import Quartz as quartz
        from Foundation import NSURL

        if not hasattr(quartz, "kCGImageDestinationEncodeToISOHDR"):
            raise Unavailable("macOS ImageIO에 ISO HDR 인코딩 기능이 없음")
        source = hdr_fixture(directory)
        native = quartz.CGImageSourceCreateWithURL(NSURL.fileURLWithPath_(str(source)), None)
        primary = quartz.CGImageSourceGetPrimaryImageIndex(native)
        require(quartz.CGImageSourceCopyAuxiliaryDataInfoAtIndex(
            native, primary, quartz.kCGImageAuxiliaryDataTypeHDRGainMap), "HDR fixture 게인 맵 누락")
        original = source.read_bytes()
        output = directory / "out"
        records = eof_job(self.worker, directory, [source], output,
                          output_format=output_format, metadata=mode)
        batch(records, [source], (1, 0, 0))
        successful = next(r for r in records if r["event"] == "file_succeeded")
        target = output / source.with_suffix(f".{output_format}").name
        image = opened(target, output_format)
        require(image.size == (256, 256), image.size)
        if output_format == "png":
            require(successful["hdr_applied"] and successful["sdr_reason"] is None, successful)
            chunks = dict(png_chunks(target))
            require(chunks[b"IHDR"][8] == 16, "HDR PNG가 16비트가 아님")
            if image.info.get("icc_profile"):
                profile = ImageCms.ImageCmsProfile(io.BytesIO(image.info["icc_profile"]))
                require("PQ" in ImageCms.getProfileDescription(profile), "HDR ICC가 PQ가 아님")
            else:
                require(chunks.get(b"cICP", b"")[1:] == bytes([16, 0, 1]),
                        f"HDR PQ cICP 누락: {chunks.get(b'cICP')}")
        else:
            require(not successful["hdr_applied"] and "JPEG" in successful["sdr_reason"], successful)
        require(bool(image.getexif().get(34853)) == (mode == "preserve"), "HDR GPS 정책 불일치")
        if mode == "strip":
            require(not image.getexif() and not image.info.get("xmp"), "HDR strip EXIF/XMP가 남음")
        require(source.read_bytes() == original, "HDR 원본 변경")
        no_temporary(output)

    def group(self, directory, cases):
        """관련 하위 검사를 하나의 필수 시나리오로 묶는다."""
        for index, (name, function) in enumerate(cases, 1):
            child = directory / f"case-{index}"
            child.mkdir()
            try:
                function(child)
            except AssertionError as exc:
                raise AssertionError(f"{name}: {exc}") from exc

    def run(self):
        self.check("01 JPEG 및 EOF 완료", lambda d: self.normal(d, "jpeg"))
        self.check("02 PNG 및 EOF 완료", lambda d: self.normal(d, "png"))
        malformed = [
            ("잘린 JSON", "{", "invalid_request"),
            ("JSON 배열", "[]", "invalid_request"),
            ("unknown run", {"command": "run"}, "unknown_job"),
            ("bool protocol", {"protocol_version": True}, "protocol_mismatch"),
            ("bool quality", {"options": {"jpeg_quality": True}}, "invalid_request"),
            ("bool compression", {"options": {"png_compression": False}}, "invalid_request"),
            ("범위 밖 quality", {"options": {"jpeg_quality": 101}}, "invalid_request"),
            ("알 수 없는 옵션", {"options": {"unknown": 1}}, "invalid_request"),
            ("상대 입력", {"files": ["relative.heic"]}, "invalid_request"),
        ]
        self.check("03 malformed 요청/옵션/bool 정수 및 복구", lambda d: self.group(d, [
            (name, lambda c, v=value, e=code: self.invalid(c, v, e))
            for name, value, code in malformed
        ]))
        self.check("04 symlink/중복/missing 거부와 자연 정렬", self.rejected)
        self.check("05 corrupt/삭제 부분 실패와 원본 보존", lambda d: self.group(d, [
            ("corrupt", self.partial), ("삭제", lambda c: self.partial(c, True)),
        ]))
        self.check("06 rename/skip/error/overwrite 및 동일 이름", lambda d: self.group(d, [
            (f"{policy} duplicate={duplicate}",
             lambda c, p=policy, same=duplicate: self.conflict(c, p, duplicate=same))
            for policy in ("rename", "skip", "error", "overwrite")
            for duplicate in (False, True)
        ]))
        self.check("07 비대칭 컬러 EXIF 방향 1~8/반전", lambda d: self.group(d, [
            (f"PNG 방향 {orientation}",
             lambda c, o=orientation: self.orientation(c, o, "png", metadata=False))
            for orientation in range(1, 9)
        ] + [("JPEG 회전", lambda c: self.orientation(c, 6, "jpeg", metadata=False)),
             ("JPEG 반전", lambda c: self.orientation(c, 2, "jpeg", metadata=False))]))
        for number, mode in ((8, "safe"), (9, "preserve"), (10, "strip")):
            self.check(f"{number:02d} {mode} Camera/GPS/XMP/ICC 및 방향", lambda d, m=mode: self.group(d, [
                (output_format, lambda c, f=output_format: self.orientation(c, 6, f, m))
                for output_format in ("jpeg", "png")
            ]))
        self.check("11 투명 HEIC JPEG 흰색 배경", lambda d: self.alpha(d, "jpeg"))
        self.check("12 PNG 압축 0/9 유효성/크기/픽셀", self.compression)
        self.check("13 live stdin 취소 및 세션 재사용", self.cancellation)
        self.check("14 늦은 저장 충돌 rename", lambda d: self.late_collision(d, "rename"))
        self.check("15 HDR16/PQ 메타데이터 및 JPEG SDR", lambda d: self.group(d, [
            (mode, lambda c, m=mode: self.hdr(c, m))
            for mode in ("safe", "preserve", "strip")
        ] + [("JPEG SDR", lambda c: self.hdr(c, "safe", "jpeg"))]))
        print(f"검사 {self.number}: PASS={self.counts['PASS']} FAIL={self.counts['FAIL']} "
              f"SKIP={self.counts['SKIP']} (SKIP은 검증 성공이 아님)", flush=True)
        return 1 if self.counts["FAIL"] else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("worker", type=Path, help="검사할 네이티브 heic-worker 실행 파일")
    parser.add_argument("--verbose", action="store_true", help="실패 traceback 표시")
    args = parser.parse_args()
    worker = args.worker.expanduser().resolve()
    if not worker.is_file() or not os.access(worker, os.X_OK):
        parser.error(f"실행 가능한 worker가 없습니다: {worker}")
    with tempfile.TemporaryDirectory(prefix="heiccy native 합성 검사 ") as temporary:
        return Suite(worker, Path(temporary).resolve(), args.verbose).run()


if __name__ == "__main__":
    raise SystemExit(main())

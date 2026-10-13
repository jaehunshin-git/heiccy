"""소스 수집의 해시 gate, tar 안전검사와 재현 가능한 묶음을 검증한다."""

import hashlib
import importlib.util
import io
import json
import sys
import tarfile
from dataclasses import replace
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "packaging/release/collect_codec_sources.py"
if not SCRIPT.is_file():
    pytest.skip("Python sdist에는 macOS 릴리스 패키징 코드가 포함되지 않습니다.", allow_module_level=True)
SPEC = importlib.util.spec_from_file_location("codec_sources", SCRIPT)
collector = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = collector
SPEC.loader.exec_module(collector)


def source_tar(tmp_path, entries):
    path = tmp_path / "source.tar.gz"
    with tarfile.open(path, "w:gz") as archive:
        for name, kind, contents in entries:
            info = tarfile.TarInfo(name)
            info.type = kind
            info.mode = 0o644
            if kind == tarfile.REGTYPE:
                info.size = len(contents)
                archive.addfile(info, io.BytesIO(contents))
            else:
                if kind in (tarfile.SYMTYPE, tarfile.LNKTYPE):
                    info.linkname = contents.decode()
                archive.addfile(info)
    source = collector.Source(
        "fixture", "1.0", path.name, "https://github.com/official/source.tar.gz",
        hashlib.sha256(path.read_bytes()).hexdigest(), "root", ("COPYING",),
    )
    return path, source


VALID = [("root/COPYING", tarfile.REGTYPE, b"fixture license\n")]


def test_hash_mismatch_prevents_tar_parsing(tmp_path, monkeypatch):
    path, source = source_tar(tmp_path, VALID)
    source = replace(source, sha256="0" * 64)

    def forbidden(*args, **kwargs):
        pytest.fail("해시 불일치 tar는 파싱하지 않아야 합니다.")

    monkeypatch.setattr(collector.tarfile, "open", forbidden)
    with pytest.raises(ValueError, match="SHA-256 불일치"):
        collector.inspect_archive(path, source)


def test_corrupted_cache_fails_without_redownload(tmp_path, monkeypatch):
    path, source = source_tar(tmp_path, VALID)
    path.write_bytes(b"corrupted")
    monkeypatch.setattr(collector.urllib.request, "urlopen", lambda *a, **k: pytest.fail("캐시를 덮어쓰면 안 됩니다."))
    with pytest.raises(ValueError, match="SHA-256 불일치"):
        collector.download(source, tmp_path)


def test_download_hash_mismatch_does_not_publish_or_leave_partial(tmp_path, monkeypatch):
    _, source = source_tar(tmp_path, VALID)
    cache = tmp_path / "cache"
    cache.mkdir()

    class Response(io.BytesIO):
        def geturl(self):
            return source.url

    monkeypatch.setattr(collector.urllib.request, "urlopen", lambda *a, **k: Response(b"wrong download"))
    with pytest.raises(ValueError, match="SHA-256 불일치"):
        collector.download(source, cache)
    assert list(cache.iterdir()) == []


def test_x265_content_change_cannot_be_described_as_metadata_only(tmp_path):
    original_dir, changed_dir = tmp_path / "original", tmp_path / "changed"
    original_dir.mkdir()
    changed_dir.mkdir()
    original, _ = source_tar(original_dir, [*VALID,
        ("root/x265Version.txt", tarfile.REGTYPE, b"4.0"),
        ("root/source/x265.h", tarfile.REGTYPE, b"original code"),
    ])
    changed, _ = source_tar(changed_dir, [*VALID,
        ("root/x265Version.txt", tarfile.REGTYPE, b"4.1"),
        ("root/source/x265.h", tarfile.REGTYPE, b"changed code"),
    ])
    with pytest.raises(ValueError, match="차이가 예상과 다릅니다"):
        collector.compare_x265_sources(original, changed)


@pytest.mark.parametrize("name", [
    "../escape", "/root/absolute", "root/../escape", "root/a/../../escape",
    "root//file", "root/./file", "root\\file", "other/COPYING", "root/line\nfeed",
])
def test_unsafe_tar_paths_rejected(tmp_path, name):
    path, source = source_tar(tmp_path, [*VALID, (name, tarfile.REGTYPE, b"bad")])
    with pytest.raises(ValueError, match="tar 경로"):
        collector.inspect_archive(path, source)
    assert not (tmp_path.parent / "escape").exists()


@pytest.mark.parametrize(("kind", "target"), [
    (tarfile.SYMTYPE, b"../../escape"), (tarfile.SYMTYPE, b"COPYING"),
    (tarfile.LNKTYPE, b"root/COPYING"), (tarfile.CHRTYPE, b""),
    (tarfile.BLKTYPE, b""), (tarfile.FIFOTYPE, b""),
])
def test_links_and_special_files_rejected(tmp_path, kind, target):
    path, source = source_tar(tmp_path, [*VALID, ("root/link", kind, target)])
    with pytest.raises(ValueError, match="링크·특수 파일"):
        collector.inspect_archive(path, source)


def test_duplicate_members_rejected(tmp_path):
    path, source = source_tar(tmp_path, VALID * 2)
    with pytest.raises(ValueError, match="중복 경로"):
        collector.inspect_archive(path, source)


def test_missing_or_empty_required_file_rejected(tmp_path):
    path, source = source_tar(tmp_path, [("root/README", tarfile.REGTYPE, b"readme")])
    with pytest.raises(ValueError, match="필수 소스 누락"):
        collector.inspect_archive(path, source)
    path, source = source_tar(tmp_path, [("root/COPYING", tarfile.REGTYPE, b"")])
    with pytest.raises(ValueError, match="필수 소스가 비어"):
        collector.inspect_archive(path, source)


def test_expansion_limit_rejected(tmp_path, monkeypatch):
    path, source = source_tar(tmp_path, VALID)
    monkeypatch.setattr(collector, "MAX_EXPANDED", 2)
    with pytest.raises(ValueError, match="비압축 크기 제한"):
        collector.inspect_archive(path, source)


def test_cache_symlink_rejected(tmp_path):
    path, source = source_tar(tmp_path, VALID)
    other = tmp_path / "original.tar.gz"
    path.rename(other)
    path.symlink_to(other)
    with pytest.raises(ValueError, match="일반 파일"):
        collector.download(source, tmp_path, offline=True)


def test_output_ancestor_symlink_rejected(tmp_path):
    real = tmp_path / "real"
    real.mkdir()
    link = tmp_path / "link"
    link.symlink_to(real, target_is_directory=True)
    with pytest.raises(ValueError, match="디렉터리"):
        collector.safe_directory(link / "child")
    assert not (real / "child").exists()


@pytest.mark.parametrize("change", [
    {"url": "http://github.com/source"}, {"url": "https://example.com/source"},
    {"filename": "../source.tar.gz"}, {"sha256": "unknown"},
    {"archive_root": "../root"}, {"required_files": ("../COPYING",)},
])
def test_invalid_pins_rejected(tmp_path, change):
    _, source = source_tar(tmp_path, VALID)
    with pytest.raises(ValueError):
        collector.validate_pins((replace(source, **change),))


def test_bundle_contains_verified_original_and_identical_manifest(tmp_path, monkeypatch):
    original, source = source_tar(tmp_path, VALID)
    output = tmp_path / "output"
    cache = output / "build-inputs/codec-sources"
    cache.mkdir(parents=True)
    (cache / source.filename).write_bytes(original.read_bytes())
    monkeypatch.setattr(collector, "SOURCES", (source,))
    bundle = collector.build_bundle(output, offline=True)
    first_digest = collector.sha256(bundle)
    with tarfile.open(bundle) as archive:
        assert len(archive.getmembers()) == 4
        prefix = collector.BASENAME
        inner = archive.extractfile(f"{prefix}/sources-manifest.json").read()
        sidecar = (output / f"{prefix}.manifest.json").read_bytes()
        assert inner == sidecar
        record = json.loads(inner)["sources"][0]
        assert record["sha256"] == source.sha256
        assert record["inspection"]["required_file_sha256"]["COPYING"] == hashlib.sha256(VALID[0][2]).hexdigest()
        assert archive.extractfile(f"{prefix}/sources/{source.filename}").read() == original.read_bytes()
    checksum = Path(f"{bundle}.sha256").read_text()
    assert checksum == f"{first_digest}  {bundle.name}\n"
    collector.build_bundle(output, offline=True)
    assert collector.sha256(bundle) == first_digest


def test_failed_collection_preserves_existing_bundle(tmp_path, monkeypatch):
    _, source = source_tar(tmp_path, VALID)
    output = tmp_path / "output"
    output.mkdir()
    bundle = output / f"{collector.BASENAME}.tar.gz"
    bundle.write_bytes(b"existing result")
    monkeypatch.setattr(collector, "SOURCES", (source,))
    with pytest.raises(ValueError, match="캐시 파일이 없습니다"):
        collector.build_bundle(output, offline=True)
    assert bundle.read_bytes() == b"existing result"

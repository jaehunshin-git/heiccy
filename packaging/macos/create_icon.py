"""확정된 앱 아이콘 PNG에서 ICNS용 크기별 이미지를 생성합니다."""

import argparse
from pathlib import Path

from PIL import Image

SOURCE = (
    Path(__file__).resolve().parents[2] / "docs/assets/branding/heiccy-app-icon.png"
)


def create_iconset(source: Path, destination: Path) -> None:
    if not source.is_file():
        raise FileNotFoundError(f"앱 아이콘 원본 PNG가 없습니다: {source}")
    with Image.open(source) as image:
        if image.format != "PNG":
            raise ValueError(f"앱 아이콘 원본은 PNG여야 합니다: {source}")
        if image.size != (1024, 1024) or image.mode != "RGBA":
            raise ValueError(
                "앱 아이콘 원본은 1024×1024 RGBA PNG여야 합니다: "
                f"{source} ({image.width}×{image.height}, {image.mode})"
            )
        image.load()
        destination.mkdir(parents=True, exist_ok=True)
        for size in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                pixels = size * scale
                suffix = "@2x" if scale == 2 else ""
                resized = image.resize((pixels, pixels), Image.Resampling.LANCZOS)
                resized.save(destination / f"icon_{size}x{size}{suffix}.png")


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path, help="ICNS용 iconset 저장 경로")
    parser.add_argument(
        "--source", type=Path, default=SOURCE, help="1024×1024 RGBA 앱 아이콘 PNG"
    )
    args = parser.parse_args(argv)
    try:
        create_iconset(args.source, args.destination)
    except (OSError, ValueError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()

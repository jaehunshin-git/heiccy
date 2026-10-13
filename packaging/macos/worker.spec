# 앱 런타임은 이 명시적 진입점과 import된 모듈만 수집한다.
from pathlib import Path

from PyInstaller.utils.hooks import collect_all

root = Path(SPECPATH).parents[1]
datas, binaries, hiddenimports = [], [], []
for package in ("pillow_heif", "objc", "Foundation", "Quartz"):
    collected_data, collected_binaries, collected_imports = collect_all(package)
    datas += collected_data
    binaries += collected_binaries
    hiddenimports += collected_imports
analysis = Analysis(
    [str(root / "packaging/macos/worker_entry.py")],
    pathex=[str(root / "src")],
    binaries=binaries,
    datas=datas,
    hiddenimports=hiddenimports,
    excludes=["tkinter", "pytest", "ruff", "build", "hatchling"],
    noarchive=False,
)
pyz = PYZ(analysis.pure)
executable = EXE(
    pyz,
    analysis.scripts,
    [],
    exclude_binaries=True,
    name="heic-worker",
    console=True,
    target_arch="arm64",
    codesign_identity="-",
)
collection = COLLECT(
    executable, analysis.binaries, analysis.datas,
    name="worker",
)

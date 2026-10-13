#!/bin/bash
# 고정한 arm64 환경에서 앱, DMG와 체크섬을 조립한다.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    echo '앱 빌드는 Apple Silicon macOS에서만 지원합니다.' >&2
    exit 1
fi
export MACOSX_DEPLOYMENT_TARGET=15.0
PYTHON_VERSION=3.12.12
BUILD="$ROOT/build/macos"
DIST="$ROOT/dist/macos"
APP="$DIST/heiccy.app"
ENVIRONMENT="$ROOT/.venv-app-build"
# 상위 링크를 따라 저장소 밖의 산출물을 지우거나 덮어쓰지 않는다.
for directory in "$ROOT/build" "$BUILD" "$ROOT/dist" "$DIST" "$ENVIRONMENT"; do
    if [[ -L "$directory" || ( -e "$directory" && ! -d "$directory" ) ]]; then
        echo "빌드 경로는 링크가 아닌 디렉터리여야 합니다: $directory" >&2
        exit 1
    fi
done
# 패널 smoke는 WindowServer와 포커스를 넘겨받을 외부 앱이 필요하다.
if [[ "$(stat -f '%u' /dev/console)" != "$(id -u)" ]] || ! launchctl print "gui/$(id -u)" >/dev/null 2>&1; then
    echo '패널 smoke에는 현재 사용자의 로그인된 GUI 세션이 필요합니다.' >&2
    exit 1
fi
uv python install "$PYTHON_VERSION"
uv venv --allow-existing --python "$PYTHON_VERSION" "$ENVIRONMENT"
uv pip sync --python "$ENVIRONMENT/bin/python" --require-hashes packaging/macos/requirements.lock
PYTHON="$ENVIRONMENT/bin/python"
"$PYTHON" -c 'import platform, sys; assert platform.machine() == "arm64"; assert sys.version_info[:3] == (3, 12, 12)'
# Apple Events나 접근성 권한 없이 Finder를 시작해 포커스 대상을 확보한다.
"$PYTHON" - <<'PY'
import os
import subprocess
import time

subprocess.run(["/usr/bin/open", "-a", "Finder"], check=True, timeout=15)
deadline = time.monotonic() + 15
while subprocess.run(
    ["/usr/bin/pgrep", "-u", str(os.getuid()), "-x", "Finder"],
    stdout=subprocess.DEVNULL, check=False, timeout=5,
).returncode != 0:
    if time.monotonic() >= deadline:
        raise RuntimeError("패널 smoke의 포커스 대상 Finder가 실행되지 않았습니다.")
    time.sleep(0.2)
PY
mkdir -p "$BUILD" "$DIST"
"$PYTHON" -m PyInstaller --noconfirm --clean --workpath "$BUILD/pyinstaller" --distpath "$BUILD/frozen" packaging/macos/worker.spec
swift build --package-path macos --configuration release --arch arm64
# 복사 범위는 세 개의 빌드 산출물과 아래 명시한 파일로 한정한다.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Licenses"
SWIFT_BIN="$(swift build --package-path macos --configuration release --arch arm64 --show-bin-path)"
cp "$SWIFT_BIN/HEICConverter" "$APP/Contents/MacOS/HEICConverter"
cp packaging/macos/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp -R "$BUILD/frozen/worker" "$APP/Contents/Resources/worker"
cp LICENSE "$APP/Contents/Resources/Licenses/HEIC-Converter-MIT.txt"
"$PYTHON" packaging/macos/collect_licenses.py "$APP/Contents/Resources/Licenses"
"$PYTHON" packaging/macos/create_icon.py "$BUILD/AppIcon.iconset"
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
"$PYTHON" packaging/macos/normalize_app.py "$APP"
"$PYTHON" packaging/macos/sign_app.py "$APP"
"$PYTHON" packaging/macos/validate_app.py "$APP"
"$PYTHON" packaging/macos/smoke_worker.py "$APP/Contents/Resources/worker/heic-worker"
"$PYTHON" - "$APP/Contents/MacOS/HEICConverter" <<'PY'
import subprocess
import sys

subprocess.run([sys.argv[1], "--smoke-test"], check=True, timeout=90)
PY
# 일반 LaunchServices 실행 → 실제 상태 버튼 분기 → 정상 종료를 새 프로세스 두 개로 검증한다.
"$PYTHON" packaging/macos/test_panel_startup.py "$APP"
STAGING="$BUILD/dmg-root"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/$(basename "$APP")"
ln -s /Applications "$STAGING/Applications"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' packaging/macos/Info.plist)"
if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "잘못된 앱 버전: $APP_VERSION" >&2
    exit 1
fi
DMG="$DIST/heiccy-$APP_VERSION-arm64.dmg"
rm -f "$DMG"
echo 'DMG 생성 환경:'
sw_vers
uname -m
# APFS 생성 정지를 피하고, hdiutil이 멈추면 체크섬/설치 검증으로 진행하지 않는다.
"$PYTHON" - "$STAGING" "$DMG" <<'PY'
import subprocess
import sys

subprocess.run(
    ["hdiutil", "create", "-verbose", "-volname", "heiccy",
     "-srcfolder", sys.argv[1], "-fs", "HFS+", "-format", "UDZO", sys.argv[2]],
    check=True, timeout=300,
)
PY
(cd "$DIST" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
"$PYTHON" packaging/macos/validate_dmg.py "$DMG"
echo "검증 완료: $DMG"

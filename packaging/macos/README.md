# macOS 앱 빌드와 패키징

macOS 앱의 표시 이름은 **heiccy**다. Apple Silicon arm64, macOS 15 이상이 대상이며 앱 버전은 1.0.0이다. 실행 시 사용자의 Python, Homebrew, uv 또는 pip를 호출하지 않는다. Swift 실행 파일이 `Contents/Resources/worker/heic-worker`를 `Process`로 직접 실행한다.

## 고정 환경

빌드에는 Xcode Command Line Tools 또는 Xcode의 Swift 도구와 uv 0.11.11이 필요하다. `build.sh`가 CPython 3.12.12와 `.venv-app-build`를 생성한다. `requirements-pins.txt`에 모든 직접·전이 의존성 버전을 고정했고 `requirements.lock`은 배포 파일 SHA-256을 함께 고정한다. 빌드 시 `uv pip sync --require-hashes`로 잠금 파일을 적용한다. 앱 빌드 도구는 기존 CLI 기본 설치 의존성에 추가하지 않는다.

의존성을 갱신할 때 고정 버전 목록을 편집한 뒤 같은 arm64 Python 환경에서 잠금 파일을 다시 생성한다.

```sh
uv pip compile --python .venv-app-build/bin/python \
  --python-platform aarch64-apple-darwin --generate-hashes \
  packaging/macos/requirements-pins.txt -o packaging/macos/requirements.lock
bash packaging/macos/build.sh
```

`requirements.in`은 주요 도구의 선정 버전을 기록한 참고 목록이며 실제 설치에는 전체 버전과 해시가 고정된 `requirements.lock`만 사용한다.

## 조립 및 검증

앱 아이콘은 [확정 원본 PNG](../../docs/assets/branding/heiccy-app-icon.png)를 사용한다. `create_icon.py`가 16·32·128·256·512pt의 1x·2x PNG를 생성하고 `iconutil`로 `AppIcon.icns`를 만든다. 글꼴과 심볼 기하, 흰 타일의 규격은 [디자인 기준](../../docs/assets/branding/DESIGN.md)을 따른다.

1. PyInstaller onedir에 Python, Pillow, pillow-heif, PyObjC의 objc/Foundation/Quartz와 필요한 네이티브 코덱을 수집한다.
2. Swift Package의 arm64 릴리스 실행 파일을 빌드하고 `Info.plist`, 생성 아이콘과 라이선스 고지를 명시적으로 복사한다. 프로젝트 루트나 사진 폴더 전체를 복사하지 않는다.
3. Mach-O 파일과 중첩 프레임워크, 앱을 안쪽부터 무료 ad-hoc 서명한다. PyInstaller의 기본 runtime 서명은 무료 ad-hoc 환경에서 Python 라이브러리 로드에 실패할 수 있어 모든 코드를 hardened runtime 없이 다시 서명한다.
4. 모든 Mach-O의 arm64 아키텍처, 상대 로더 경로, 최소 OS 버전과 ad-hoc 서명, 앱 버전과 허용 목록을 검사한다.
5. 임시 폴더에 합성한 HEIC를 사용해 사용자 Python이 없는 PATH에서 JPEG와 PNG 변환을 확인한다. 합성 Apple 게인 맵 HEIC의 내장 PyObjC HDR 경로도 실행해 16비트 PNG와 PQ ICC 또는 cICP, safe GPS 제거, 원본 보존을 검증한다. 앱 `--smoke-test`도 내장 worker 연결을 확인한다.
6. `heiccy.app`과 `/Applications` 심볼릭 링크만 담은 `heiccy` 볼륨의 DMG를 만들고 SHA-256을 생성한다. 읽기 전용으로 마운트하고 실제 볼륨 이름이 `heiccy`인지 확인한 뒤 임시 설치 복사본의 앱과 worker를 다시 실행한다.

산출물은 다음과 같다. 앱 표시 이름과 패널 이름은 `heiccy`이며, 내부 실행 파일 `HEICConverter`와 번들 ID `io.github.jaehunshin-git.heic-converter`는 유지한다. PyPI 패키지·CLI 이름과 기존 `~/Pictures/HEIC Converter` 출력 폴더도 유지한다.

- `dist/macos/heiccy.app`
- `dist/macos/heiccy-1.0.0-arm64.dmg`
- `dist/macos/heiccy-1.0.0-arm64.dmg.sha256`

별도 검증은 다음 명령으로 재실행할 수 있다.

```sh
.venv-app-build/bin/python packaging/macos/validate_app.py 'dist/macos/heiccy.app'
.venv-app-build/bin/python packaging/macos/test_panel_startup.py 'dist/macos/heiccy.app'
.venv-app-build/bin/python packaging/macos/validate_dmg.py dist/macos/heiccy-1.0.0-arm64.dmg
.venv-app-build/bin/python -m build --no-isolation
.venv-app-build/bin/python packaging/macos/validate_python_dist.py dist
```

wheel과 sdist는 버전 0.3.0, 지정 경로 허용 목록, 영어 Summary와 README.pypi.md 본문을 검사한다. Hatch가 자동 포함하는 루트 `.gitignore`와 `PKG-INFO`는 sdist 허용 목록에 포함한다. 사진, 개발 환경, Swift 앱 소스와 패키징 소스는 Python 배포 파일에 포함하지 않는다.

## 설치와 배포

DMG를 열고 heiccy를 Applications로 드래그한다. 첫 실행이 차단되면 한 번 실행을 시도한 뒤 시스템 설정 → 개인정보 보호 및 보안 → 확인 없이 열기로 허용한다. ad-hoc 서명과 DMG는 Developer ID 서명·공증이나 Gatekeeper 신뢰를 제공하지 않는다. 이 버전은 Developer ID 서명과 공증을 수행하지 않는다.

`.github/workflows/macos.yml`은 macOS 15·26에서 검증합니다. 개발 태그 `macos-v<앱 버전>` 실행은 두 OS 성공 후 공개 `heiccy` 저장소에 소스 사본과 `v<앱 버전>` 초안 릴리스를 만듭니다. 공개 게시와 설치 확인 후에만 개발 저장소를 Private로 전환합니다. Python 태그 `v<Python 버전>`은 별도이며 앱 배포가 PyPI 업로드를 실행하지 않습니다. 게시 인증과 복구 절차는 개발 저장소의 `docs/macos-build-release.md`에서 관리합니다.

자동 smoke 검증은 설치한 worker의 실제 변환과 앱의 프로토콜 연결을 확인한다. 이름 있는 pasteboard에서 자동 변환·혼합 항목 보존·부분 실패·끄기·정상 종료 복구와 패널/설정 창도 smoke로 확인한다. Photos·Finder·카카오톡의 실제 붙여넣기와 접근 권한 검증은 별도로 수행한다. 로컬 OS에서 성공한 결과를 macOS 15 실기 검증으로 기록하지 않는다.

## 새 실행 직후 패널 검증

`build.sh`는 기존 앱 smoke 뒤 `test_panel_startup.py`로 일반 LaunchServices 실행과
정상 종료를 두 번 확인한다. named pasteboard·별도 설정에서 상태 버튼의 실제
클릭 핸들러를 통과하며 첫 표시·반복 토글·포커스 이동을 검사한다.
같은 실행파일명의 앱이 이미 실행 중이면 중복 실행 없이 실패하므로 빌드 전에 정상 종료한다.
합성 이벤트가 WindowServer의 실제 메뉴바 입력을 대신하지는 않는다.
실제 클릭 결과와 선택적 계측은 [이슈 #11 기록](../../docs/macos-issue11-panel-startup.md)을 따른다.

## 이슈 #7 후속 검증 범위

[PR #9 준비 기록](../../docs/macos-issue7-pr-readiness.md)은 2026-10-11 당시의 결과와
미검증 항목을 보존한다. 당시 Python 코어를 수정하지 않았다는 범위는 그 기록에 한정한다.
현재 후속 범위에는 Photos 입력 보호와 Python 코어의 네이티브 HDR 대표 이미지 선택
수정이 포함되며 CLI/TUI와 기존 SDR fallback 정책, PyPI 버전 0.3.0은 유지한다.

Photos 자산 참조 메타데이터(`com.apple.photos.object-reference.asset`)와
`.photoslibrary` 내부 파일 URL이 함께 있는 입력은 정상 종료 후
전체 표현의 복구를 보장할 수 없어 지원하지 않는다. raw HEIC가 있어도 전체 입력을
거절하며 보관함 파일을 조회하거나 썸네일로 열지 않는다. 보관함 URL 없는 raw HEIC
단독 입력은 계속 지원한다. 파일 약속은 공급자에게 표현 데이터를 요청하기 전에
전체 항목의 타입 검사로 거절한다.

사용자가 미다운로드로 지정한 실제 iCloud 사진의 드래그에서는 파일 약속과
`public.jpeg`, 일반 복사에서는 HEIC 없는 JPEG raw를 관찰했다. 드래그 타입 관찰은
공급자 요청 없이 수행했으며 다운로드 상태를 독립적으로 검증한 결과가 아니다.
일반 복사 JPEG는 앱 실행·정상 종료 후 전체 표현의 타입·바이트·세대 보존을 확인했다.

소스 회귀 테스트는 실제 생성한 합성 다중 HEIC의 대표 인덱스가 1임을 확인하고
`CGImageSourceGetPrimaryImageIndex`에 따른 16비트·PQ HDR PNG 및 메타데이터 정책을
검증한다. 이 결과를 기존 앱/DMG의 동일 조건 검증이나 새 릴리스로 간주하지 않는다.
최신 테스트 수, 앱/DMG 후속 검증과 카카오톡 실기 결과는
[남은 검증 후속 기록](../../docs/macos-issue7-remaining-validation.md)을 따른다.

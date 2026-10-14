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

DMG 생성의 최종 오류가 `hdiutil: create failed - Resource busy`인 경우에만 최대 총
3회, 2초 간격으로 재시도한다. 각 시도의 로그와 종료 코드를 보존하고 실패한 DMG 파일만
정리한다. 다른 오류·300초 타임아웃·재시도 소진은 빌드를 중단하며 검증 실패는 재시도하지
않는다. 이전 체크섬은 생성 전에 제거하고 성공 후 다시 만든다.

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

개발·빌드·배포의 단일 원본은 공개 `jaehunshin-git/heiccy`입니다. 기존 private는
기록 보존용이며 소스 사본을 export해 별도 공개 커밋을 만드는 절차를 신규 배포에
사용하지 않습니다. private Git 이력·내부 문서·개인 파일을 복사하지 않습니다.

신규 앱 태그는 `macos-vVERSION`, Python 태그는 `pypi-vVERSION`이며 버전과
배포 시점은 독립적입니다. 과거 문서의 앱 `vVERSION`은 이전 snapshot 배포 표기이며 2026-10-13 전환 점검에서 원격 앱 태그·릴리스는 없었습니다. 앱 배포는
PyPI 업로드를 실행하지 않습니다. `.github/workflows/macos.yml`에서 같은 공개
SHA를 macOS 15·26에서 검증하고 macOS 15 산출물을 게시 대상으로 선택하도록
전환합니다. 새 manifest는 같은 공개 저장소·같은 공개 SHA·해당 workflow 실행과
산출물 해시를 기록합니다.

`SOURCE.json`은 초기 공개 snapshot 기록으로 불변입니다. baseline
`77908397ffb24dc1881ea1f0ebfc5d9d9c977852`의 Git blob 기준 검사기를
`packaging/release/verify_source_snapshot.py`로 검증하며 현재 작업 트리의
해시로 갱신하지 않습니다. 새 manifest의 출처를 초기 snapshot의 private SHA와
혼동하지 않습니다.

앱 draft release job은 기본 disabled입니다. `HEICCY_RELEASE_ENABLED` 변수와
`public-release` environment를 게이트로 사용하고 해당 job의 `contents: write`
권한을 가진 `github.token`으로 같은 저장소에 draft를 만듭니다. PAT는 사용하지
않으며 태그 생성·push, 게이트 활성화와 실제 릴리스 생성·공개 게시에는 별도 승인이
필요합니다. CI·snapshot 검사기·manifest·릴리스 게이트의 이번 전환 검증과 GitHub
실기/e2e는 pending입니다. [빌드 안내](../../docs/build.md)와
[단일 저장소 운영](../../docs/repository-operations.md)을 참고하세요.

설치 파일은 릴리스가 공개된 뒤 제공하며, CI artifact를 받아 검증한 결과는
GitHub Releases의 공개 게시나 비인증 다운로드 검증 완료를 뜻하지 않습니다.

자동 smoke 검증은 설치한 worker의 실제 변환과 앱의 프로토콜 연결을 확인한다. 이름 있는 pasteboard에서 자동 변환·혼합 항목 보존·부분 실패·끄기·정상 종료 복구와 패널/설정 창도 smoke로 확인한다. Photos·Finder·카카오톡의 실제 붙여넣기와 접근 권한 검증은 별도로 수행한다. 로컬 OS에서 성공한 결과를 macOS 15 실기 검증으로 기록하지 않는다.

## 새 실행 직후 패널 검증

`build.sh`는 기존 앱 smoke 뒤 `test_panel_startup.py`로 일반 LaunchServices 실행과
정상 종료를 두 번 확인한다. named pasteboard·별도 설정에서 상태 버튼의 실제
클릭 핸들러를 통과하며 첫 열기·숨김·클립보드 보존을 검사한다. 이 자동 검증을
물리적 메뉴바 조작·아이콘 가독성·사용자의 기존 설정 승계 확인과 구분한다.

Photos 자산 참조·보관함 URL과 파일 약속의 지원 범위 및 수신 앱 제한은
[클립보드 호환성](../../docs/compatibility.md)을 따른다. 지원하는 HEIC HDR 원본은
ImageIO로 대표 이미지를 선택해 16비트 PNG로 변환하며 일반 원본은 SDR 경로를
사용한다. 패키지명·명령과 Python 버전은 앱 배포와 독립적으로 유지한다.

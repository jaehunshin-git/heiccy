# heiccy 소스 빌드

공개 저장소는 릴리스별 소스 사본을 제공하며, 설치 파일은 해당 릴리스가 공개된 뒤
제공합니다. 개발 기준 커밋과
공개 파일별 SHA-256은 `SOURCE.json`에 기록합니다. 공개 커밋과 개발 커밋의 SHA는
서로 다르며, 이 파일로 대응 관계를 확인합니다. 과거 내부 이슈·PR·Git 이력은
이전하지 않습니다. 사용자 버그와 기능 요청은 공개 저장소의 이슈로 접수합니다.

## 요구 환경

- Apple Silicon arm64, macOS 15 이상
- macOS SDK를 포함한 Xcode 또는 Command Line Tools
- 테스트 실행에는 XCTest를 포함한 Xcode
- `uv` 0.11.11, 앱 worker Python 3.12.12

```bash
uv sync --group dev
uvx ruff==0.14.4 check src tests scripts packaging/macos packaging/release
uv run pytest
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test --package-path macos
bash packaging/macos/build.sh
```

빌드는 로그인된 GUI 세션에서 실행합니다. worker와 패널·DMG 설치본 검증을
수행하므로 실행 중 Finder가 열리거나 앱 포커스가 바뀔 수 있습니다.
의존성은 `packaging/macos/requirements.lock`의 버전과 해시로 고정합니다.
실행 앱은 사용자의 Python·Homebrew·uv·pip에 의존하지 않습니다.

소스 기여자는 `bash scripts/install_git_hooks.sh`로 커밋 메시지 검사 훅을
설치할 수 있습니다. 규칙·기존 훅 설정·해제 방법은
[Git 훅 안내](commit-message-hooks.md)를 참고하세요. 개발용 훅은 공개 소스에
포함하며 PyPI 배포에는 포함하지 않습니다.

## 산출물

- `dist/macos/heiccy.app`
- `dist/macos/heiccy-1.0.0-arm64.dmg`
- `dist/macos/heiccy-1.0.0-arm64.dmg.sha256`

```bash
cd dist/macos
shasum -a 256 -c heiccy-1.0.0-arm64.dmg.sha256
```

앱 버전은 `packaging/macos/Info.plist`, Python 패키지 버전은 `pyproject.toml`에서
독립적으로 관리합니다. 앱 번들 ID와 `converter.settings` 키를 유지합니다.
공개 앱 태그는 `v1.0.0`부터 사용합니다. CI는 같은 개발 커밋을 macOS 15·26에서
검증하고 macOS 15에서 만든 DMG를 게시 대상으로 선택합니다. 두 OS의 DMG는
각자 빌드되므로 서로 같은 바이트일 필요는 없으며, 게시 파일은 선택한 CI 산출물과
SHA-256이 같아야 합니다. `release-manifest-macos-15.json`·`release-manifest-macos-26.json`에 해당 파일과 커밋을 기록합니다.

## 서명과 라이선스

현재 앱은 ad-hoc 서명이고 Developer ID 서명·Apple 공증을 적용하지 않습니다.
첫 실행이 차단되면 [Apple 안내](https://support.apple.com/ko-kr/102445)를 따릅니다.
Developer ID 도입에는 Apple Developer Program, Developer ID Application 인증서,
공증 인증 정보와 hardened runtime·번들 의존성 재검증이 필요합니다.

프로젝트 소스는 MIT이며, 내장 Python·라이브러리·코덱은 각각의 라이선스를
따릅니다. 앱의 `Contents/Resources/Licenses`에 전문과 고지가 포함됩니다.
pillow-heif 바이너리 wheel에는 GPL/LGPL 구성 요소가 있으므로 DMG 배포 시
해당 버전의 대응 소스와 빌드 정보 제공 범위를 별도로 확인해야 합니다.

## Python 패키지

이름 `heic-converter-tui`와 명령 `heic-converter`는 유지합니다. PyPI 설명은
영문 `README.pypi.md`를 사용합니다. 앱 전용 배포는 PyPI에 업로드하지 않습니다.

```bash
uv build
.venv-app-build/bin/python packaging/macos/validate_python_dist.py dist
```

sdist는 명시된 허용 목록만 포함합니다. `input/`·`output/`의 사진과 개인 파일은
어떤 배포에도 포함하지 않습니다. 이미 게시된 Python 버전은 덮어쓰지 않습니다.

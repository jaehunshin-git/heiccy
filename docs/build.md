# heiccy 소스 빌드

공개 소스에서 macOS 앱·DMG와 Python 패키지를 빌드하고 검증하는 안내입니다.
소스 기여와 제출 절차는 [기여 안내](../CONTRIBUTING.md)를 참고하세요.
초기 소스 기록 보존과 새 릴리스 manifest의 출처 규칙은
[저장소 운영](repository-operations.md)에서 확인할 수 있습니다.

## 요구 환경

- Apple Silicon arm64, macOS 15 이상
- macOS SDK를 포함한 Xcode 또는 Command Line Tools
- 테스트 실행에는 XCTest를 포함한 Xcode
- `uv` 0.11.11, 앱 worker Python 3.12.12

```bash
uv sync --group dev
uvx ruff==0.14.4 check --config pyproject.toml src tests scripts packaging/macos packaging/release
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
[Git 훅 안내](../.github/commit-message-hooks.md)를 참고하세요. 개발용 훅은 공개 소스에
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
신규 앱 태그는 `macos-vVERSION`, PyPI 태그는 `pypi-vVERSION`을 사용하며 과거 문서의
앱 `vVERSION`은 이전 snapshot 배포 표기입니다. `.github/workflows/macos.yml`은 같은 공개
SHA를 macOS 15·26에서 검증하고 macOS 15의 DMG를 게시 대상으로 선택하도록
전환합니다. 두 OS의 DMG는 독립 빌드이므로 서로 같은 바이트일 필요는 없지만 게시
파일은 선택한 CI 산출물과 SHA-256이 같아야 합니다.
`release-manifest-macos-15.json`·`release-manifest-macos-26.json`의 저장소는
`jaehunshin-git/heiccy`, 소스 SHA는 동일한 실제 공개 빌드 SHA, workflow는
`.github/workflows/macos.yml`이어야 합니다. private에서 소스 사본을 export해
별도 공개 커밋을 만드는 절차는 신규 배포에 사용하지 않습니다.

앱 draft release는 기본 disabled입니다. `HEICCY_RELEASE_ENABLED` 변수와
`public-release` environment를 게이트로 사용하고, 해당 job만 `contents: write`
권한을 가진 `github.token`을 사용합니다. PAT는 사용하지 않습니다. 실제 태그
생성·push, 게이트 활성화와 릴리스 생성·공개 게시는 별도 승인이 필요합니다.
실행별 CI 결과·배포 승인과 미검증 항목은 해당 이슈·PR에서 기록합니다.
실제 CI context는 승인된 push·PR 실행 이후 확인한 이름만 strict required checks로
등록합니다. 환경 이름만으로 승인 보호가 설정됐다고 간주하지 않습니다.

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

PyPI 배포는 앱 릴리스와 별도로 진행합니다.

1. CLI/TUI 변경이 배포 대상일 때만 `pyproject.toml`의 Python 버전과 관련 잠금
   정보를 갱신합니다. 앱 버전·태그와 같게 맞출 필요는 없습니다.
2. 영어 `README.pypi.md`·Summary를 검토하고 Python 테스트·wheel/sdist 허용 목록
   검증을 통과시킵니다. 설치 명령 `heic-converter`를 확인합니다.
3. 승인된 PR이 main에 반영된 커밋에 별도 `pypi-v<Python 버전>` 태그를 만듭니다.
   해당 태그의 CI는 검증만 실행하며 앱 draft와 PyPI 업로드를 실행하지 않습니다.
4. PyPI 업로드를 별도로 승인받은 뒤 해당 버전의 wheel/sdist 두 파일만
   `uv publish`로 업로드합니다. DMG·코덱 소스·과거 버전 파일은 업로드 대상이 아닙니다.
   인증 정보는 저장소나 로그에 넣지 않습니다.
5. 게시된 PyPI 버전·영문 설명·설치 명령을 확인합니다. 같은 버전의 덮어쓰기나
   앱 배포를 통한 Python 버전 게시를 하지 않습니다.

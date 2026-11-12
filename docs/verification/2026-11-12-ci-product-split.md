# 최신 CI 실패 수정과 앱 저장소 분리 검증

검증일은 2026-11-12, 로컬 환경은 Apple Silicon arm64·macOS 27.3·Xcode다.
현재 작업 브랜치는 `chore/1-single-repository`, 변경 전 HEAD는 `fbbaee5`다.
이 문서는 로컬 작업 결과이며 이슈 #1 종료·main 반영·원격 CI 성공을 뜻하지 않는다.

## ICC 보존 수정

[기존 CI](https://github.com/jaehunshin-git/heiccy/actions/runs/38527551920)의
macOS 15·26은 각각 네이티브 통합 검사 15개 중 13개 통과·2개 실패다.
입력 fixture 검증 뒤 JPEG `safe`·`preserve`의 원본 ICC 보존 검사에서 실패했다.
기존 worker는 로컬 macOS 27.3에서 15개 모두 통과해 원격 증상을 직접 재현하지
못했다. 원격 OS에서 Image I/O의 정확한 손실 지점은 아직 확인되지 않았다.

JPEG 출력의 ICC 보존을 Image I/O에만 맡기던 경로를 수정했다. SDR 렌더링의
출력 색공간과 같은 ICC를 JPEG APP2에 명시적으로 기록한다. 기존 ICC 조각만
교체하고 EXIF·XMP·비ICC APP2·압축 이미지 데이터는 유지한다. `strip`의
개인정보 제거 경로와 기존 임시 파일·원자적 출력 계약은 유지한다.

통합 검사는 ICC 표식 포함 여부에서 원본 ICC 전체 바이트 일치로 강화했고,
Display P3의 JPEG·PNG·방향·픽셀 검사를 추가했다. ICC APP2 분할·손상 입력·
재적용에 관한 XCTest도 추가했다.

## 제품별 정리

Python 공개 저장소 `heic-converter-tui`의 `main`·`5ffff37`은 작업 전후 clean이다.
삭제 전 Python 소스 6개와 담당 저장소 파일의 바이트 일치를 확인했다.
이 저장소의 중복 `src/heic_converter`·제품 테스트·PyPI 설명·배포 검사기·
`uv.lock`과 Python 패키징 설정을 제거했다. `pyproject.toml`에는 앱 도구의
Ruff·pytest 설정만 유지한다.

앱 CI에서 `pypi-v*` 트리거·wheel/sdist 빌드·업로드를 제거했다. 앱 검증용
Pillow·pillow-heif·Quartz와 제출·Git 훅·릴리스 테스트는 유지한다. 한국어·영어
README·빌드 문서·운영 지침·공개 버그 양식·검사기를 앱 제품 범위로 맞췄다.
초기 `SOURCE.json`·개발 이슈 템플릿 5종·릴리스 게이트는 변경하지 않았다.

## 실행한 검증

명령은 별도 표시가 없으면 현재 heiccy 작업 폴더에서 실행했다. Python 도구는
`packaging/macos/requirements.lock`의 해시 고정 환경을 사용한다.

| 검증 | 명령 | 결과 |
| --- | --- | --- |
| 앱 도구·운영 회귀 | `.venv-app-build/bin/python -m pytest -q` | 414개 통과 |
| Swift 빌드 | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path macos` | 빌드 통과, 이 도구의 테스트 실행은 0개여서 아래 별도 실행 |
| ConverterKit XCTest | `xcrun xctest macos/.build/out/Products/Debug/ConverterKitTests.xctest` | 89개 통과 |
| 앱 XCTest | `xcrun xctest macos/.build/out/Products/Debug/HEICConverterTests.xctest` | 48개 통과 |
| NativeWorker XCTest | `xcrun xctest macos/.build/out/Products/Debug/NativeWorkerTests.xctest` | 21개 통과 |
| 클립보드 독립 프로세스 | `.venv-app-build/bin/python packaging/macos/test_clipboard_probe.py` | 14개 통과 |
| 앱·DMG 전체 | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash packaging/macos/build.sh` | 네이티브 통합 16개 통과, 패널 재실행·DMG 체크섬·볼륨·임시 설치본 앱/worker 통과 |
| 초기 소스 보존 | `.venv-app-build/bin/python packaging/release/verify_source_snapshot.py` | baseline 131개 통과 |
| Python 정적 검사 | `.venv-app-build/bin/ruff check tests scripts packaging` | 통과 |
| Actions 문법 | `actionlint` 1.7.12로 두 workflow 검사 | 통과 |
| README Markdown | `npx --yes markdownlint-cli2@0.23.3` | 통과 |
| 변경·문서 경로 | `git diff --check`, Markdown 상대 링크 존재 확인 | 통과 |

CI도 XCTest 개별 번들 구성에서 ConverterKit·앱·NativeWorker 세 번들을 모두
실행하도록 정리했다. 0개 실행 로그를 Swift 테스트 통과 근거로 사용하지 않는다.

Python 담당 저장소에서는 `uv sync --locked --group dev`,
`uv run --locked ruff check src tests scripts`, `uv run --locked pytest`가
통과했다. Python 제품 회귀는 271개 통과다. `uv build --out-dir
/tmp/heiccy-audit-python-dist`와 `uv run --locked python
scripts/validate_python_dist.py /tmp/heiccy-audit-python-dist`로 버전 0.3.0의
wheel/sdist 허용 목록·영문 메타데이터 검증도 통과했다.

## 독립 리뷰와 미검증 경계

제품 분리·문서 리뷰는 gpt-6.1-terra, 최종 ICC 수정 리뷰는 gpt-6.1-sol이
읽기 전용으로 수행했다. 삭제된 패키징 명령을 가리키던 문서 두 곳을 수정했고
재확인에서 추가 중대 발견은 없었다.

위 로컬 검증을 마친 시점에는 커밋·push·이슈 수정·PR·merge·태그·릴리스 게이트
변경·배포를 수행하지 않았다. 이후 승인된 커밋·push의 원격 CI 결과는 해당
Actions 실행에서 확인한다.
macOS 15·26 원격 CI 재실행, main 반영, 실제 Photos·수신 메신저별 붙여넣기와
공개 다운로드는 이번 검증에 포함하지 않는다. Developer ID 서명·공증은 기존
미적용 상태다. 원격 CI를 성공으로 보고하려면 승인된 push 이후 해당 SHA의
두 OS 실행 결과를 다시 확인해야 한다.

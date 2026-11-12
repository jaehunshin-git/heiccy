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

## 승인된 push 이후의 원격 진단

`2947a39`·`d03cd4d`를 push한
[첫 CI 실행](https://github.com/jaehunshin-git/heiccy/actions/runs/43129791239)은
두 OS 모두 네이티브 통합 14개 통과·2개 실패다. Display P3 검사는 통과했지만
기존 사용자 ICC의 JPEG `safe`·`preserve` 실패는 유지됐다.

진단을 추가한 `20faae4`·`61b8f49` 중 최신 커밋의
[원격 실행](https://github.com/jaehunshin-git/heiccy/actions/runs/43130685909)도
같은 두 검사에서 실패했다. macOS 15에서 확인한 원본 ICC는 588바이트의
`heiccy source` 프로필이고, 기본·SDR 디코딩과 출력 JPEG의 ICC는 모두
3,144바이트의 `sRGB IEC61966-2.1` 프로필이며 SHA-256도 서로 같다.
즉 JPEG 저장 이전의 ImageIO 디코딩 단계에서 프로파일이 정규화됐다.
`CGColorSpace.copyICCData()`만으로 원본 ICC를 복원할 수 있다는 가정은
원격 증거로 반박됐다.

후속 수정은 기본 이미지에 연결된 원본 HEIF `colr` ICC를 읽어, SDR 렌더링의
목표 색공간과 저장할 프로파일을 함께 선택하는 방향이다. 기존 bounds 검사를
가진 HEIF 판독기를 재사용하고 EXIF 유무와 ICC 추출을 분리한다. 이 단계의
검증·원격 결과는 완료 후 아래에 기록한다.

### 원본 ICC 추출 후속 수정의 로컬 검증

기본 이미지의 `prof`·`rICC` 원문을 기존 HEIF Reader로 추출하고, 유효한 SDR
RGB 프로필로 렌더링한 뒤 동일 바이트를 JPEG·PNG에 기록하도록 수정했다.
`nclx`만 있는 입력과 HDR·확장 범위 프로필은 기존 색공간 경로를 사용한다.
HDR 출력에 SDR 프로필을 재부착하지 않는다.

CG 색공간 생성만으로 ICC 유효성을 보장할 수 없다는 독립 리뷰의 실제 손상
프로필 재현을 반영했다. 선언 길이·서명·RGB 헤더·태그 목록과 데이터 경계를
검사한 뒤 색공간을 생성한다. 기본 이미지 연결·버전·넓은 인덱스·essential bit·
다른 이미지 배제·모호한 중복·손상·Data slice 회귀 검사를 추가했다.

현재 작업 폴더에서 Swift 빌드와 NativeWorker XCTest 26개, worker 통합
16개가 통과했다. `build.sh` 전체 실행도 통과하여 앱·패널 재실행·DMG 체크섬·
마운트·설치 복사본 worker/앱을 다시 확인했다. gpt-6.1-sol의 최종 독립 리뷰에서
앞선 손상 ICC 지적 해소와 추가 correctness 발견 없음을 확인했다.
이 후속 수정의 macOS 15·26 원격 성공 여부는 승인된 push 후 CI에서 확인한다.

### 원본 ICC 수정의 원격 결과와 PR 전 최종 검토

후속 커밋 `04a2450`의
[CI 실행 43132150186](https://github.com/jaehunshin-git/heiccy/actions/runs/43132150186)은
macOS 15·26 모두 성공했다. 두 OS에서 기존 `safe`·`preserve` ICC 실패를
포함한 네이티브 통합 16개, 앱·DMG·설치본 검증과 산출물 업로드가 통과했다.
릴리스 job은 기본 게이트에 따라 건너뛰었으며 실제 배포 성공을 의미하지 않는다.

main 대비 전체 변경의 최종 독립 검토는 앱 동작(gpt-6-astra)과 운영·CI 경계
(gpt-6.1-sol)로 나눠 수행했다. 앱 범위에서 차단할 발견은 없었다. 운영 검토에서는
앱 전용 artifact가 최상위에 파일을 담는데 릴리스 검증 명령이 다운로드 경로 뒤
`/macos`를 추가하는 불일치를 발견했다. 실제 업로드 ZIP 구조로 확인했다.

두 검증 경로에서 불필요한 하위 폴더를 제거했다. 실제 workflow shell과 release
CLI를 실행하는 회귀 검사에서 수정 전에는 누락된 manifest 오류가 재현됐고,
수정 후 릴리스 테스트 90개가 통과했다. 독립 재검토에서도 지적 해소를 확인했다.
권한·게이트·릴리스 게시 동작은 변경하지 않았으며 실제 태그 릴리스 e2e는
미실행이다. 이 경로 보완 이후 CI 결과는 제출한 PR의 실행에서 확인한다.

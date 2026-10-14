## 📌 Summary

heiccy를 개발·문서·협업·빌드·배포의 단일 원본으로 전환한다. 두 macOS CI와 공개 제출 검증을 준비하고 같은 공개 커밋의 앱 draft 흐름으로 변경했다. 앱의 변환 엔진을 Swift·macOS Image I/O로 전환했고 Python CLI/TUI는 유지했다. 기존 비공개 저장소와 초기 SOURCE.json은 보존했다.

Closes #1

## 📄 Tasks

- [x] macOS 15·26 Python/Swift/앱/DMG 및 Python 배포 허용 목록 CI 이전
- [x] 같은 저장소·커밋·macos-v 앱 태그의 기본 비활성 draft 흐름 구현
- [x] 초기 SOURCE.json baseline 검증 및 퇴역 exporter·관련 테스트 정리
- [x] 공개 버그·제안·운영 이슈와 Summary/Tasks/To Reviewer PR 양식 정비
- [x] 개발 원문 5종 바이트·SHA 일치 복원, 공개 제안 proposal 보존, 공통 8종 validator/helper 및 scoped 회귀 검증
- [x] 공통 제출 검사·생성 도우미·trusted metadata 이벤트 검증 구현
- [x] 승인 0명·PR 필수·삭제/force push 금지·우회 없음 main 기본 ruleset 적용
- [x] 실제 성공 검사에서 strict 필수 검사를 준비하는 도우미 구현
- [x] README·AGENTS·빌드·독립 배포·Git 훅·운영 한계 문서 정리

- [x] Swift 네이티브 worker, 앱 런타임·외부 코덱 제거와 실제 앱·DMG 검증

## 🔍 To Reviewer

PR 메타데이터 검사는 trusted base 코드만 실행하며 fork 코드에 secret을 제공하지 않는다. 본문 편집 시 head status를 pending부터 갱신하고 최신 데이터를 다시 읽는다. 큐/API/merge 사이 편집의 원자적 차단은 GitHub 플랫폼상 보장하지 못한다.

현재 main에 새 검사 코드가 없으므로 이 최초 PR의 trusted 자동 검사는 unavailable이다. 로컬 형식 검사·수동 검토와 macOS CI를 확인해야 하며 merge는 별도 지시 후 수행한다. 실제 검사 실행 전에는 strict 필수 검사를 등록하지 않는다. 후속 PR에서 metadata 검사·실패 차단을 확인한다.

SOURCE.json은 초기 기록 그대로이며 현재 작업 트리와 일치시키지 않는다. 앱·PyPI 버전과 태그·업로드는 독립적이다. 기존 훅 설치·복원 코드와 영문 PyPI 설명·메타데이터는 그대로다.

## ✅ Validation

로컬 macOS 27.2에서 다음 검증을 수행했다. 아래 516개 통과 등을 포함한 결과는
2026-10-13의 복원 보완 전 기록이며 이번 보완 결과로 소급하지 않는다.

- CI 고정 Python 환경의 pytest: 516개 통과(Click API deprecation 경고 2개), 기존 commit-msg 설치·실제 차단·복원 포함
- 고정 Ruff 0.14.4와 저장소 pyproject.toml 설정: 전체 검사 통과
- Xcode Swift build/test: 빌드 및 XCTest 76개 통과
- 클립보드 probe 독립 프로세스: 14개 통과
- 앱 조립·Mach-O 44개·내장 worker·패널 smoke: 통과
- 별도 DMG 조립·체크섬·임시 설치본 앱/worker 검증: 통과
- Python wheel/sdist 0.3.0 허용 목록·영어 Summary/설명: 통과
- 초기 baseline 131개 파일과 SOURCE.json 원본 바이트 검증: 통과
- actionlint 1.7.12, 문서 링크, git diff --check, 개인 사진·빌드 산출물 제외 검사: 통과
- 이슈 #1 실제 제목·본문·라벨과 템플릿 형식: 통과
- Active main 기본 ruleset API 적용 후 재조회: 일치

자세한 검증 기록과 남은 작업은 [이슈 #1](https://github.com/jaehunshin-git/heiccy/issues/1)에 보존했다.

### 2026-10-14 템플릿복원 보완

추가 검증 결과는 다음과 같다.

- 개발 원문 feature/fix/docs/init/refactor 5종의 바이트·SHA 일치 확인 통과
- 공개 제안 proposal, 공개 bug, 운영 task와 개발 5종 총 8종 validator/helper 지원. 원문 제목·emoji 라벨·필수 Description/Tasks·선택 ETC·required true·blank false 유지
- 제출 검사·ruleset 관련 **85개 scoped 테스트 통과**. 개발 5종 정상·누락·label·title·placeholder·gh 자동 라벨 검증과 실제 placeholder 블록 원문 거부 포함
- 고정 Ruff 전체 검사 통과. 새 전체 pytest는 실행하지 않았으며 기존 516개는 이전 결과로 유지
- GitHub emoji 라벨 5종을 기존 이름·색·설명 그대로 생성하고 재조회 일치 확인

### 원격 CI

커밋 1fa66be712ad03208d32ddafa2009400d476fc9c의 [macOS CI](https://github.com/jaehunshin-git/heiccy/actions/runs/38489571367)에서 Apple Silicon macos-15·macos-26이 모두 성공했다. 앱 draft job은 조건에 따라 skipped였고 실제 배포는 수행하지 않았다. 이후 README·문서 정리 변경의 원격 CI는 별도로 확인하며 이 실행 결과를 후속 변경 검증으로 사용하지 않는다.

## ⚠️ Unverified

- 과거 Python 빌드의 시작 패널 대기는 기존 앱 정상 종료와 네이티브 전체 build.sh 성공으로 해소했다. 실제 Photos 직접 복사·JPEG 게시·원본 HEIC 복구는 아래 검증을 완료했으며, 수신 메신저별 붙여넣기는 미검증이다.
- 외부 fork, PR/이슈 편집 이벤트·UI와 실제 merge 차단은 PR 지시 및 기본 브랜치 반영 이후 확인한다.
- 실제 macOS 검사 이름을 확인했지만 required status checks·strict 최신화는 아직 미적용이다. 첫 PR에서는 trusted 기본 브랜치 metadata 검사가 unavailable이다.
- public pull_request_target의 Actions event policy, public-release 보호 설정과 배포 활성화는 아직 검증·설정하지 않았다.
- 실제 앱/PyPI 태그·draft 생성·업로드·공개 릴리스·비인증 다운로드는 수행하지 않았다. 서명·공증은 기존 ad-hoc 상태를 유지한다.

- 템플릿복원 보완의 변경 범위는 기존 29개에 proposal/fix/docs/init/refactor 5개가 추가된 총 34개이며 동일 baseline에서 최종 변경 파일 34개를 확인했다.
- 복원 양식과 8종 검사의 원격 기본 브랜치 적용 및 Actions 실기는 pending이다. 작업 브랜치 커밋·push와 이슈 #1의 init 양식 갱신은 추가 지시로 승인됐다. PR 생성·merge는 별도 지시가 필요하며 기존 이슈 일괄 수정·권한 변경은 없다.


### 네이티브 앱 전환 검증

Swift 네이티브 worker로 전환해 앱에서 Python 런타임·Pillow·외부 코덱을 제거했다.
CLI/TUI Python 구현과 PyPI 배포 메타데이터는 유지했다. 새 manifest는 스키마 2와
`engine: swift-imageio`를 사용한다.

- Swift XCTest 141개, 네이티브 worker 핵심 통합 15개 모두 통과
- JPEG/PNG·HDR16/PQ·방향·반전·EXIF/GPS/XMP/ICC·알파·압축·취소·충돌·원본 보존 검증 통과
- 전체 build.sh·새 실행 직후 패널·DMG 체크섬과 임시 설치 복사본 worker/앱 검증 통과
- 앱 46.35 MB → 2.85 MB, DMG 20.49 MB → 0.92 MB
- PyPI wheel/sdist·SOURCE baseline·Ruff·actionlint·README 린트·링크 검사 통과

로컬 macOS 27.2 결과이며 네이티브 변경의 macOS 15·26 원격 CI는 미실행이다.
과거 Python worker 검증을 네이티브 검증으로 사용하지 않는다.
네이티브 최초 검증 시점에는 기존 설치 앱을 정상 종료했고 교체하지 않았다.
원격 CI와 PR·merge·배포 상태는 PR 제출 시 다시 확인한다.


### Photos 직접 복사 개선

Photos 사진의 raw HEIC와 보관함 URL 조합을 지원한다. 변환 결과에서 Photos 전용 참조를
제거하고, 정상 종료와 게시 실패 시에는 앱 소유의 원본 HEIC 사본으로 복구한다.
보관함 URL을 파일·realpath로 조회하지 않고 raw를 우선하며, raw 없는 보관함 입력은
원본 데이터가 있는 사진을 다시 복사하도록 안내한다. 변환하지 않는 항목은 원문 표현을 유지한다.

현재 로컬에서 실제 Photos 입력의 JPEG 파일·이미지 게시, 별도 프로세스의 이미지 읽기,
정상 종료 후 원본 HEIC 바이트·파일 복구를 확인했다. 합성 Photos 입력을 포함한 내장
worker smoke와 전체 앱·DMG 빌드도 통과했다. 최종 Swift 회귀 155개와 Photos 저장소 회귀 38개를 통과했다.
최종 앱은 2.90 MB, DMG는 0.93 MB다. 수신 메신저별 실제 붙여넣기와 macOS 15·26 원격 CI는 미검증이다.

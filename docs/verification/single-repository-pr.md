## 📌 Summary

heiccy를 개발·문서·협업·빌드·배포의 단일 원본으로 전환한다. 두 macOS CI와 공개 제출 검증을 준비하고 같은 공개 커밋의 앱 draft 흐름으로 변경했다. 기존 비공개 저장소와 초기 SOURCE.json은 보존했다.

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

자세한 기록은 docs/verification/single-repository-transition.md에 작성했다.

### 2026-10-14 템플릿복원 보완

추가 검증 결과는 다음과 같다.

- 개발 원문 feature/fix/docs/init/refactor 5종의 바이트·SHA 일치 확인 통과
- 공개 제안 proposal, 공개 bug, 운영 task와 개발 5종 총 8종 validator/helper 지원. 원문 제목·emoji 라벨·필수 Description/Tasks·선택 ETC·required true·blank false 유지
- 제출 검사·ruleset 관련 **85개 scoped 테스트 통과**. 개발 5종 정상·누락·label·title·placeholder·gh 자동 라벨 검증과 실제 placeholder 블록 원문 거부 포함
- 고정 Ruff 전체 검사 통과. 새 전체 pytest는 실행하지 않았으며 기존 516개는 이전 결과로 유지
- GitHub emoji 라벨 5종을 기존 이름·색·설명 그대로 생성하고 재조회 일치 확인

## ⚠️ Unverified

- 전체 build.sh는 시작 패널 검사에서 실행 중인 설치 앱 보호 장치에 의해 중단됐다. 기존 앱 정상 종료 허용 또는 사용자 종료 이후 시작 검사를 재실행한다. 별도 DMG 검증 성공이 전체 build.sh 성공을 뜻하지 않는다.
- heiccy macOS 15·26 Actions, 외부 fork, PR/이슈 편집 이벤트·UI와 실제 merge 차단은 push·PR 승인 및 기본 브랜치 반영 이후 확인한다.
- 실제 검사 이름과 출처 확인 전 required status checks·strict 최신화는 미적용이다. 첫 PR에서는 trusted 기본 브랜치 metadata 검사가 unavailable이다.
- public pull_request_target의 Actions event policy, public-release 보호 설정과 배포 활성화는 아직 검증·설정하지 않았다.
- 실제 앱/PyPI 태그·draft 생성·업로드·공개 릴리스·비인증 다운로드는 수행하지 않았다. 서명·공증은 기존 ad-hoc 상태를 유지한다.

- 템플릿복원 보완의 변경 범위는 기존 29개에 proposal/fix/docs/init/refactor 5개가 추가된 총 34개이며 동일 baseline에서 최종 변경 파일 34개를 확인했다.
- 복원 양식과 8종 검사의 원격 기본 브랜치 적용 및 Actions 실기는 pending이다. 작업 브랜치 커밋·push와 이슈 #1의 init 양식 갱신은 추가 지시로 승인됐다. PR 생성·merge는 별도 지시가 필요하며 기존 이슈 일괄 수정·권한 변경은 없다.

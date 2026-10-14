# 단일 저장소 운영 전환 검증 기록

2026-10-13, [전환 이슈 #1](https://github.com/jaehunshin-git/heiccy/issues/1).
아래 검증은 커밋·push 이전에 수행한 기록이다. 2026-10-14 추가 지시로
`chore/1-single-repository` 브랜치의 커밋·push와 이슈 #1의 init 양식 갱신을 진행한다.
PR 생성·merge·태그·실제 GitHub/PyPI 릴리스는 별도 지시가 필요하다. PR 본문은
[single-repository-pr.md](single-repository-pr.md)에 준비했으며 아직 제출하지 않았다.

## 작업 전 현재 상태

- heiccy 공개·기존 저장소 비공개, 모두 archive되지 않았으며 기존 저장소의 열린 PR은 0개였다.
- heiccy main은 원격 `77908397ffb24dc1881ea1f0ebfc5d9d9c977852`와 일치했다.
- heiccy ruleset·전통적 main 보호·Actions는 없었다. 소유자만 관리자/쓰기 권한을 가졌다.
- SOURCE.json의 131개 파일은 공개 체크아웃에서 모두 해시가 일치했다. 기존 로컬 저장소와는 이슈 템플릿 3개가 달랐고 나머지 128개는 일치했다.
- 원격 태그·릴리스·Actions 변수·배포 environment는 없었다. Actions 기본 토큰 권한은 read이며 PR 승인 권한도 꺼져 있었다.

## 변경 파일

| 범위 | 파일과 변경 |
| --- | --- |
| CI | `.github/workflows/macos.yml` 추가: macOS 15·26 Python/Swift/앱/DMG/배포 허용 목록 검증 유지, 공개 fork PR은 읽기 권한으로 검증 |
| 제출 자동화 | `.github/workflows/submission.yml` 추가: trusted base의 메타데이터 검사, 현재 head의 commit status와 이슈 invalid-format 라벨 갱신 |
| 템플릿 | 공개 `bug.yml`·운영 `task.yml` 유지, 공개 제안을 `proposal.yml`로 보존, 개발 `feature.yml`·`fix.yml`·`docs.yml`·`init.yml`·`refactor.yml` 원문 복원. PR 양식 추가, config.yml의 blank_issues_enabled: false 유지 |
| main 보호 | `.github/rulesets/main.json`, `scripts/configure_main_ruleset.py` 추가. 실제 성공 검사에서만 strict 설정을 준비·적용 |
| 공통 검사·생성 | `scripts/check_submission.py`, `scripts/submission_rules.json`, `scripts/create_submission.py`, `scripts/validate_github_metadata.py` 추가 |
| 출처·릴리스 | `packaging/release/verify_release.py` 수정, `verify_source_snapshot.py` 추가. 같은 공개 SHA·앱 태그를 연결하고 SOURCE.json은 baseline에서 검증 |
| 퇴역 | `packaging/release/export_public.py`, `tests/test_public_export.py` 삭제. 현재 참조를 확인했으며 과거 기록은 baseline Git blob과 SOURCE.json에 보존 |
| 회귀 검사 | `tests/test_release.py` 수정, `tests/test_source_snapshot.py`, `tests/test_submission.py`, `tests/test_ruleset.py` 추가 |
| 개발·운영 문서 | `AGENTS.md`, `docs/repository-operations.md` 추가; `README.md`, `README.ko.md`, `docs/build.md`, `docs/commit-message-hooks.md`, `packaging/macos/README.md` 수정 |
| 검증·검토 문서 | 이 검증 기록과 `docs/verification/single-repository-pr.md` 추가 |

복원 보완 전 변경은 삭제 파일을 포함해 29개였다. 2026-10-14 보완은
`proposal.yml`·`fix.yml`·`docs.yml`·`init.yml`·`refactor.yml` 5개 추가로 총 34개
범위이며 최종 변경 목록 34개를 확인했다. `README.pypi.md`,
`pyproject.toml`, `uv.lock`, `SOURCE.json`, 기존 commit-msg 훅·검사기·설치기는 수정하지 않았다.

## 검증 결과

아래 516개 통과 등을 포함한 결과는 2026-10-13의 복원 보완 전 기록이다.
2026-10-14 템플릿복원 보완의 검증 결과로 소급하지 않는다.

로컬 OS는 `sw_vers`의 macOS **27.2**다. 이 결과를 macOS 15·26 CI 결과로 사용하지 않는다.

| 검사 | 결과 |
| --- | --- |
| `PYTHONPATH=src .venv-app-build/bin/python -m pytest -q` | CI 고정 환경에서 516개 통과. 기존 Click API deprecation 경고 2개. 제출 정상/실패 입력, placeholder·필수 항목·라벨·이슈 연결, PR 본문 편집 시 성공→pending→실패, stale head/본문, 이슈 수정 후 표시 해제, 기존 실제 Git 훅 설치·차단·복원 포함 |
| 고정 Ruff 0.14.4 + `--config pyproject.toml` | src/tests/scripts/packaging/macos/packaging/release 전체 통과 |
| Xcode Swift build/test | 빌드 통과, XCTest 76개 통과. 기존 SDK deprecated 경고는 남음 |
| 클립보드 probe 독립 프로세스 | 14개 통과 |
| 앱 조립·서명·worker·패널 smoke | Mach-O 44개 arm64/로더 경로/ad-hoc 서명, 내장 worker의 JPEG/PNG·16비트 HDR, 앱 worker 연결·자동 변환 smoke 통과 |
| 전체 `build.sh` | 앱 smoke 이후 시작 패널 검사에서 중단. 기존 설치 앱이 실행 중이라 보호 장치가 거부했으며 기존 앱을 종료하거나 검사기를 우회하지 않음 |
| 별도 DMG 조립·검증 | create_dmg.py + validate_dmg.py 통과. SHA-256, Applications 링크, 임시 설치 복사본 앱/worker 실행 검증. 전체 build.sh 성공을 뜻하지 않음 |
| Python 배포 | wheel/sdist 0.3.0 빌드 및 허용 목록·영어 Summary/README.pypi.md 검사 통과 |
| 과거 출처 | baseline 131개 파일 검증 통과. SOURCE.json SHA-256 `a7a0540e23df27f39e4ed8ab5f49e0927210534998ffeeae49a52018cacad786` 보존 |
| Actions 문법 | actionlint 1.7.12로 두 workflow 통과 |
| 문서·변경 범위 | 상대 링크, git diff --check, 사진·개인 빌드 경로 제외, 토큰/개인키 패턴 검사 통과 |
| 생성된 이슈 #1 | 실제 제목·본문·라벨 재조회 및 공통 로컬 형식 검사 통과 |

테스트에서 사용하는 임시 저장소의 커밋·태그는 회귀 fixture이며 작업 저장소·기존
비공개 저장소의 Git 이력을 수정하지 않았다. 두 저장소의 HEAD를 유지했고 기존 저장소는
깨끗한 main이다. 빌드 산출물·가상환경·로그는 Git 변경 목록에 포함되지 않는다.

## ruleset 적용 상태

[main ruleset 24993268](https://github.com/jaehunshin-git/heiccy/settings/rules/24993268)을
실제 적용하고 API로 재조회했다.

- 대상 main, Enforcement Active
- PR 필수, 승인 수 0명, review thread resolution 필수
- branch 삭제·force push 차단, bypass 대상 없음
- Code owner·마지막 push 타인 승인·추가 unattributed 변경 승인 요구 없음
- 다른 사용자 쓰기 권한 추가 없음
- **required status checks와 strict 최신화는 아직 미적용**: 승인된 push·PR과 실제 검사 실행이 먼저 필요하다.

PR 없이 main을 갱신하는 일반 경로는 현재 기본 ruleset이 제한한다. CI·본문 형식 실패로
머지를 차단하는 상태까지 완료했다고 보고하지 않는다. 실제 검사 후 등록해야 한다.

## 규칙·자동 차단·플랫폼 한계

| 구분 | 내용 |
| --- | --- |
| 규칙으로 요구 | 경로에 관계없이 템플릿 읽기·필수 제목/라벨/본문 작성·placeholder 제거·로컬 검사·생성 후 재조회, 형식 실패 우회 금지 |
| 현재 자동 차단 | 호출된 commit-msg 훅, 생성 도우미의 검증 실패 시 gh 호출 중단, Active main 기본 보호 |
| main 반영·검사 등록 후 자동 적용 | PR 생성/편집/push의 최신 status 검사와 실패 시 일반 merge 차단, 이슈 생성/편집 후 invalid-format 표시·해제 |
| 플랫폼상 완전 차단 불가 | 웹 Issue Forms의 필수 항목은 CLI/API 생성 전 차단이 아님. gh create는 Git 훅을 호출하지 않음. 이슈 자동 검증은 생성 후 표시이며 본문을 고치거나 종료하지 않음. PR 편집 이벤트의 큐·API·merge 사이 시간차는 atomic하게 없앨 수 없음. pending 기록 자체가 상태 API 장애로 실패하면 이전 성공 상태가 남을 수도 있음. 관리자에 의한 ruleset 자체 수정도 영구 차단할 수 없음 |

PR 검사는 fork 코드·의존성을 실행하지 않고 저장소 secret을 사용하지 않는다. 최소
쓰기 권한을 가진 github.token은 상태/라벨 기록에만 사용한다. 본문·제목은 Python 데이터로
읽으며 셸 코드에 삽입하지 않는다. 현재 GitHub에 workflow를 올리지 않았으므로 위 자동
metadata 검증의 실제 이벤트·UI·fork 실기는 미검증이다.

## 남은 작업

- 실행 중인 설치 앱의 정상 종료가 허용되거나 사용자가 종료한 뒤 시작 패널 검사를 다시 실행한다.
- 별도 지시 후 커밋·작업 브랜치 push·템플릿 형식 PR 생성 및 생성 후 본문 확인을 진행한다.
- 첫 PR의 macOS 15·26 CI 성공을 확인하고 `configure_main_ruleset.py --ci-only`로 실제 두 검사부터 strict 필수로 등록한다. main에 trusted metadata 코드가 없으므로 최초 PR의 자동 형식 검사는 unavailable이며 로컬 검사·수동 검토를 수행한다.
- 첫 merge는 별도 지시를 받은 뒤 진행한다. 다음 PR에서 trusted metadata 검사, 실제 본문/제목 편집 후 실패 및 복구, 외부 fork 경계를 확인한다.
- 실제 성공한 macOS 두 검사와 PR 형식 검사 이름·Actions 출처를 확인한 뒤 configure_main_ruleset.py로 strict 필수 검사를 등록한다. 실패 상태의 일반 merge 차단도 실제 PR에서 확인한다.
- main 반영 후 이슈 편집으로 invalid-format 추가·해제를 확인한다. 기존 이슈 일괄 수정·종료는 하지 않는다.
- public pull_request_target의 적용 가능한 Actions event policy를 확인한다. GitHub의 2026-11-02 기본 차단 정책 변경에 대비해 필요한 explicit allow를 검토한다. [공식 안내](https://docs.github.com/en/actions/reference/security/securely-using-pull_request_target)
- 앱 배포 승인 후 macos-v 태그, 배포 변수와 public-release 보호 설정, 두 OS CI·manifest 확인, draft 생성·검토·수동 공개·비인증 다운로드를 검증한다. 현재 변수·environment가 없어 release job은 꺼져 있다.
- PyPI는 별도 승인 후 Python 버전·pypi-v 태그·영어 배포 파일을 확인하고 업로드한다. 패키지명 heic-converter-tui·명령 heic-converter를 유지한다.
- Developer ID 서명·Apple 공증은 이번 작업에 포함하지 않았으며 기존 ad-hoc 상태다.

## 2026-10-14 템플릿복원 보완

기존 private의 개발 5종 `feature.yml`·`fix.yml`·`docs.yml`·`init.yml`·`refactor.yml`을
원문 바이트 그대로 복원했다. 공개 기능 제안은 `proposal.yml`로 이름을 바꿔
보존하고 공개 버그·운영 task 양식은 유지한다. 개발 양식의 제목·emoji 라벨·필수
Description/Tasks·선택 ETC 및 `required: true`, config의 blank false는 보존한다.
공통 schema·CLI·gh helper·Actions는
`bug|proposal|feature|fix|docs|init|refactor|task` 이슈 8종을 지원한다.
아래 결과는 통합 담당자가 실제 실행·재조회하고 확인했다.

| 이번 보완 검증 | 상태 |
| --- | --- |
| 원문 5개와 복원 파일의 바이트·SHA 일치 | 통과 |
| 개발 5종 정상 및 필수 항목 누락·label·title·placeholder 거부 | scoped 회귀 검사 통과, 실제 placeholder 블록 원문 거부 포함 |
| gh helper의 템플릿 자동 라벨 및 전 8종 공통 검사 | 로컬 scoped 회귀 검사 통과. Actions 원격 실기는 pending |
| 이번 회귀 테스트 수·정적 검사 결과 | 제출 검사·ruleset 관련 85개 scoped 테스트 통과, 고정 Ruff 전체 통과. 새 전체 pytest 미실행, 기존 516개는 이전 결과 유지 |
| 최종 변경 목록 34개 범위 | 동일 baseline에서 34개 확인 통과, 기존 29개에 신규 5개 추가 |
| 원격 emoji 라벨 5종 | 기존 이름·색·설명 그대로 생성 후 재조회 일치 확인 |
| 원격 기본 브랜치 템플릿·8종 검사 적용 | pending, 작업 브랜치 push 이후에도 PR·merge가 필요 |

추가 지시에 따라 이슈 #1을 복원된 init 양식으로 갱신한다. 기존 이슈 일괄 수정·권한 변경은 하지 않는다.
기존 ruleset readback·이슈 #1 검사와 516개 통과 결과는 과거 증거로 보존하며 이번
보완 성공을 뜻하지 않는다.

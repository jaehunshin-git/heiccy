# 단일 저장소 운영

이슈 #1은 개발·협업·빌드·배포의 원본을 `jaehunshin-git/heiccy` 하나로 전환한다.
기존 private 저장소는 기록을 보존하며 신규 개발·배포 원본으로 사용하지 않는다.
과거 private Git 이력, 내부 문서·이슈·PR 및 개인 파일을 복사하지 않는다.
명시적으로 승인된 개발 이슈 템플릿 5종은 원문 바이트 그대로 복원한다.
이 문서는 운영 정책과 구현 요구를 정의한다. 문서 작성만으로 원격 설정이나
자동 검증이 활성화된 것은 아니다. 승인된 push·PR 이후 GitHub 실기/e2e 검증은 **pending**이다.

## 문서와 제품의 경계

`README.md`는 영어, `README.ko.md`와 신규 운영 문서는 한국어로 유지한다.
PyPI 설명 `README.pypi.md`와 배포 메타데이터는 영어를 유지한다.
macOS 앱과 PyPI CLI/TUI는 같은 저장소에 있지만 버전·태그·배포 시점은 독립적이다.
앱 변경만으로 PyPI 업로드를 실행하지 않는다.

| 대상 | 버전 원본 | 신규 태그 |
| --- | --- | --- |
| macOS 앱 | `packaging/macos/Info.plist` | `macos-vVERSION` |
| PyPI `heic-converter-tui` | `pyproject.toml` | `pypi-vVERSION` |
| 과거 앱 태그 표기 | 이전 snapshot 배포 문서 | `vVERSION`이며 2026-10-13 전환 점검에서 원격 앱 태그·릴리스 없음 |

기존 태그를 이동·삭제·재작성하지 않는다. 태그 생성과 push, 실제 릴리스 생성·게이트
활성화·게시에는 각각 사용자 승인이 필요하다. 커밋·push·PR 생성·merge도 승인 범위를
확인한다. 2026-10-14 추가 지시로 이슈 #1의 작업 브랜치 커밋·push와 init 양식으로 본문 갱신은 승인됐다. PR 생성·merge·태그·릴리스 권한은 별도다.

## 초기 snapshot과 새 manifest

`SOURCE.json`은 초기 공개 snapshot의 출처·파일별 해시 기록이다. 내용을 갱신하지
않고 baseline `77908397ffb24dc1881ea1f0ebfc5d9d9c977852`의 Git blob을 기준으로
검증한다. 그 안의 `source_commit`은 초기 이전 시점의 과거 개발 SHA이며 현재 heiccy
HEAD나 새 release SHA와 같을 필요가 없다. 현재 작업 트리의 문서가 변경됐다는 이유로
초기 기록의 해시를 다시 만들지 않는다.

`packaging/release/verify_source_snapshot.py`가 이 baseline을 검증한다. snapshot 파일 자체의 불변성과 기록된 파일의 baseline blob 해시를 확인하며,
현재 작업 트리 전체를 초기 snapshot과 일치시키는 용도로 사용하지 않는다.
로컬 검증에서 131개 파일의 baseline 해시와 불변 기록을 확인했다. CI 연결은 구현했으며 원격 실행 확인은 pending이다.

새 릴리스는 private에서 export하거나 별도 공개 커밋을 만드는 절차를 사용하지 않는다.
manifest의 `source_repository`는 `jaehunshin-git/heiccy`, `source_commit`은 실제 공개
빌드 SHA이고 provenance의 workflow는 `.github/workflows/macos.yml`이어야 한다.
두 OS manifest는 같은 저장소·같은 공개 SHA·해당 Actions 실행을 가리켜야 한다.
DMG·체크섬·대응 코덱 소스는 그 실행에서 생성한 산출물과 해시를 확인한다.
manifest는 서명된 증명서가 아니며 초기 `SOURCE.json`을 대체하거나 갱신하지 않는다.

## 앱 CI와 draft release 게이트

`.github/workflows/macos.yml`에서 macOS 15·26 빌드·검증을 수행하고 macOS 15 산출물을
게시 대상으로 선택하도록 전환한다. OS별 독립 빌드의 DMG 바이트는 서로 같을 필요가
없지만 게시 파일은 선택한 산출물의 SHA-256과 같아야 한다.

릴리스 job은 기본 disabled다. `HEICCY_RELEASE_ENABLED` 저장소 변수의 명시적 활성화와
`public-release` environment를 게이트로 사용한다. environment 이름만으로 수동 승인
보호가 설정됐다고 간주하지 않으며 실제 보호 설정은 별도로 확인한다.
해당 job만 `contents: write`를 부여받은 `github.token`으로 같은 저장소의 **draft**
release를 만든다. 전용 PAT나 private 저장소 게시 secret을 사용하지 않는다.
게이트를 열고 draft를 생성하는 실행 및 공개 게시에는 별도 승인이 필요하다.
변수·environment·토큰 권한·기본 비활성화의 실제 동작 검증은 pending이다.

현재 앱은 ad-hoc 서명이며 Developer ID 서명과 Apple 공증은 적용하지 않는다.
CI artifact 검증, 로컬 설치·메뉴바 조작, 공개 release 다운로드 검증을 각각 기록한다.
기존 빌드·서명·패키징 안내는 [빌드 안내](build.md)와
[macOS 패키징 안내](../packaging/macos/README.md)를 따른다.

## 이슈·PR 생성 정책

생성 전에 해당 템플릿 파일을 실제로 읽는다. 웹 폼, CLI, API 모두 같은 제목 prefix,
labels, 필수 섹션과 내용 규칙을 따른다. 공개 버그·기능 제안 양식과 운영 task 양식을 유지하며 개발 5종을 원문대로 복원한다.

| 형식 | 템플릿 | 제목·labels 및 내용 |
| --- | --- | --- |
| 버그 | `.github/ISSUE_TEMPLATE/bug.yml` | `[버그]`, 사용 구성 요소·실행 환경·재현 방법, 템플릿의 선택 추가 정보 |
| 공개 기능 제안 (`proposal`) | `.github/ISSUE_TEMPLATE/proposal.yml` | `[제안]`, `enhancement`, 해결하고 싶은 문제·제안하는 동작, 선택 대안 |
| 기능 개발 (`feature`) | `.github/ISSUE_TEMPLATE/feature.yml` | `[feat]`, `✨ feature`, 필수 📄 Description·✅ Tasks, 선택 📎 ETC |
| 버그 수정 (`fix`) | `.github/ISSUE_TEMPLATE/fix.yml` | `[fix]`, `🐛 bug`, 필수 📄 Description·✅ Tasks, 선택 📎 ETC |
| 문서 작업 (`docs`) | `.github/ISSUE_TEMPLATE/docs.yml` | `[docs]`, `📝 docs`, 필수 📄 Description·✅ Tasks, 선택 📎 ETC |
| 환경 세팅 (`init`) | `.github/ISSUE_TEMPLATE/init.yml` | `[init]`, `🧹 chore`, 필수 📄 Description·✅ Tasks, 선택 📎 ETC |
| 리팩토링 (`refactor`) | `.github/ISSUE_TEMPLATE/refactor.yml` | `[refactor]`, `♻️ refactor`, 필수 📄 Description·✅ Tasks, 선택 📎 ETC |
| 개발·운영 작업 | `.github/ISSUE_TEMPLATE/task.yml` | `[작업]`, `enhancement`, Description·Tasks·완료 기준·검증 계획·제약 및 참고 |
| PR | `.github/PULL_REQUEST_TEMPLATE.md` | Summary·Tasks·To Reviewer·Validation·Unverified, `Closes #번호` 등 관련 이슈 연결 |

labels는 실제 템플릿 정의를 따른다. 필수 항목은 빈칸이나 안내용 placeholder로 남기지
않는다. `해당 없음`은 템플릿에서 허용하는 항목에만 이유와 함께 쓴다. PR의 Validation은
실행 환경·명령·결과를, Unverified는 미실행 또는 pending 검증과 이유를 명시한다.

실제 제출 본문을 파일로 생성한 뒤 다시 읽고 공통 검사기를 실행한다. 현재
검사기·helper 인터페이스는 다음과 같으며 각각의 `--help`로 옵션을 확인했다.
이슈 #1은 실제 생성된 제목·본문·라벨을 읽어 공통 검사로 검증했다. 공통 검사기·생성 도우미는 로컬 회귀 검증을 통과했고 원격 자동 검사는 기본 브랜치 반영 후 활성화된다.

```sh
python3 scripts/check_submission.py --kind issue --template task --title '[작업] 단일 저장소 운영 전환' --body-file /path/to/issue-body.md --label enhancement
python3 scripts/check_submission.py --kind pr --title 'chore: 단일 저장소 운영 전환' --body-file /path/to/pr-body.md
```

`--kind`는 `issue|pr`, 이슈의 `--template`은 `bug|proposal|feature|fix|docs|init|refactor|task`다.
로컬 `scripts/create_submission.py` helper도 `--kind`, `--title`, `--body-file`,
`--template`, `--label`의 같은 validation 옵션을 받아 검사 후 승인된 제출을 수행한다.
이슈에 `--template`을 지정하고 템플릿 labels를 `--label`로 전달한다.
title/labels를 웹 폼과 다르게 제출하지 않는다.
검사 실패를 직접 `gh`/API 호출로 우회하지 않는다. `gh issue create`·`gh pr create`는
Git 커밋이 아니므로 `commit-msg` 훅이 실행되지 않는다.

## 최초 PR과 원격 Actions 정책

최초 PR의 base인 main에는 새 workflow와 scripts가 없으므로 trusted 메타데이터
검사는 **unavailable**이다. PR head에 추가된 코드를 privileged 이벤트에서 실행해
이 공백을 우회하지 않는다. 최초 PR은 로컬 공통 checker·수동검증과 macOS CI 결과를
확인하고, 미실행 항목을 명시한 뒤 **별도 merge 승인**을 받는다. 현재 macOS CI의
실제 실행 확인과 최초 merge는 pending이다.

최초 merge로 trusted base에 workflow·scripts가 들어간 뒤 후속 대상 이벤트부터
자동 검사를 적용한다. 최초 PR이 자동 검사를 통과했다고 소급해 기록하지 않는다.
자동 적용에는 아래 Actions event policy가 실행을 허용하는지도 확인해야 한다.

2026-10-13 확인한 GitHub 공식 문서에 따르면 public 저장소에 적용 가능한 기존 event
policy가 없으면 `pull_request_target`을 차단하는 default policy가 추가된다. 현재는
실행을 계속하는 evaluate 모드이며, 안내된 영향 대상 저장소에는 **2026-11-02**부터
enforce 예정이다. 계속 사용할 경우 적용 가능한 Actions event policy에서 이 이벤트를
**explicit allow**해야 한다. 기존 event policy가 있으면 default가 이를 대체하지 않는다.
[GitHub 공식 정책 안내](https://docs.github.com/en/actions/reference/security/securely-using-pull_request_target)

heiccy 및 적용 가능한 상위 정책의 실제 설정과 policy insights는 아직 확인하지 않았다.
현재 workflow 실행이 가능하다는 사실만으로 enforce 이후 허용까지 보장하지 않는다.
원격 정책 확인, explicit allow 필요 여부 판단과 승인된 설정 변경은 **pending**이다.
문서 작업에서 정책이나 ruleset을 변경하지 않는다.

## GitHub 메타데이터 자동 검사 요구

PR 검사는 `pull_request_target`에서 **trusted base SHA**에 있는 공통 검사기와 필요한
규칙·템플릿을 사용한다. PR head의 코드·스크립트·의존성을 실행하거나 fork 코드에
secret을 전달하지 않는다. `statuses: write`로 PR **head SHA**에 명시적인 commit status
`PR 형식 검증`을 기록한다. base SHA의 상태를 PR 결과로 보고하지 않는다.

이벤트는 `opened`, `reopened`, `edited`, `synchronize`, `ready_for_review`,
`labeled`, `unlabeled`를 처리한다. 각 실행은 이벤트 본문을 그대로 신뢰하지 않고 최신
live PR의 제목·본문·labels·head를 조회한다. PR별 처리를 순차화하고
`cancel-in-progress: false`를 사용한다. GitHub 큐가 모든 중간 이벤트를 순서대로
보존한다고 가정하지 않으며, 실행할 때마다 최신 live 상태를 기준으로 검사한다.

최신 head에 먼저 pending 상태를 기록하고 검증 후 failure/success로 전환한다.
결과를 쓰기 전에 메타데이터를 다시 조회하고 stale head와 변경된 제목·본문·labels를
검사한다. 변경을 발견하면 이전 검사 결과를 최신 PR의 성공으로 기록하지 않고 최신
상태를 다시 검증한다. 오래된 이벤트의 성공이 새로운 실패를 덮어쓰지 않도록 한다.
이 동작과 race 방어의 실기 검증은 pending이다.

이슈는 `opened`, `edited`, `labeled`, `unlabeled`에서 공통 검증을 수행한다.
형식 위반 시 `invalid-format` label로 표시하고 올바르게 수정되면 제거한다.
기존 이슈를 일괄 변경하지 않는다. invalid-format의 추가·제거 재진입에서도 최신
title/body/labels를 조회하고 멱등적으로 처리해야 한다. 자동 표시는 생성 후 처리이며
형식이 잘못된 이슈의 최초 생성을 막는 기능은 아니다.

## main ruleset과 강제 범위

main ruleset은 ID `24993268`로 아래 기본 보호를 적용하고 API 재조회로 확인했다. 필수 상태 검사와 strict 설정은 실제 원격 실행 이후 등록한다.

- active, PR 필수, 필수 승인 수 0
- PR 대화 해결 필수
- branch 삭제와 force push 차단
- bypass 대상 없음
- required status checks는 실제 실행한 CI context만 등록하고 strict 적용

승인 수 0은 PR 자체가 불필요하다는 뜻이 아니다. 승인된 push와 PR에서 실제 CI가
실행된 후 context 이름과 head SHA의 상태를 확인해 required checks로 등록한다.
`PR 형식 검증`도 trusted base에 검사기가 존재하고 실기 실행이 확인된 뒤 등록한다.
아직 실행되지 않은 예정 이름을 strict required checks로 등록하지 않는다.
현재 실제 CI 실행·context 등록·merge 차단 확인은 pending이다.

| 계층 | 요구·자동 차단 범위 | 남는 한계 |
| --- | --- | --- |
| 문서 정책 | 생성 전 템플릿 읽기·본문 재확인·검사 통과 의무 | 문서 자체가 CLI/API 호출을 차단하지 않음 |
| 로컬 helper | 제출 전 공통 검사로 형식 실패 차단 | 직접 CLI/API 호출은 기술적으로 가능하지만 정책상 금지 |
| commit-msg | 호출된 로컬 커밋의 메시지 검사 | gh 생성은 호출하지 않으며 Git 내부 경로·훅 우회 한계 존재 |
| 이슈 자동 검사 | 생성·편집 후 invalid-format 표시와 수정 시 제거 | 초기 생성 전 강제 검사 불가, 처리 전 시간차 존재 |
| PR status + ruleset | 실행된 검사 결과와 strict required checks로 merge 차단 | 메타데이터 편집 이벤트 처리 전 시간차 및 플랫폼 race 존재 |
| 저장소 관리 권한 | bypass 없는 ruleset 운영 | 관리자가 ruleset 자체를 편집하는 행위까지 영구 차단할 수 없음 |

제출 직전·직후 재조회와 status pending 전환으로 race를 줄이지만, workflow가 queue에서
아직 시작하지 않았거나 pending 기록 전인 동안 메타데이터가 편집되면 이전 성공 status가
남아 있을 수 있다. head SHA가 그대로인 title/body/labels 편집은 그 SHA의 기존 성공
status를 즉시 무효화하지 못한다. API 조회·검사·재조회·status 기록·merge 사이에도
메타데이터가 바뀔 수 있다. GitHub 상태 API 장애로 pending 기록 자체가 실패하면
이전 성공 상태도 즉시 무효화하지 못한다.

메타데이터와 commit status, merge는 하나의 atomic 검사·갱신 트랜잭션이 아니므로
이 race를 완전히 차단할 수 없다. PR별 직렬화와 stale head·메타데이터 guard도 queue
시작 전이나 마지막 API 검사 이후의 편집·merge까지 보장하지 않는다. strict required
checks를 적용해도 모든 메타데이터 변경 순간을 atomic하게 보호한다고 주장하지 않는다.
웹 폼의 required 설정만으로 CLI/API 형식 우회를 막을 수 없고 관리자에 의한 ruleset
수정도 별도 권한 관리와 기록이 필요하다.

## 검증 상태와 후속 확인

문서 편집 검증과 구현 코드 검증, 원격 GitHub 실기를 구분한다. 검증 evidence report는
통합 담당자가 실제 결과에 근거해 작성하며 이 문서에서 성공 증거를 대신 만들지 않는다.

- 공통 검사기·helper의 CLI 옵션·실패 시 제출 중단·생성 후 재조회: 로컬 회귀 검증 통과. 이슈 #1 실제 본문 검사 통과
- 초기 snapshot 검사기·제출 검사기·생성 도우미·metadata 상태 갱신의 로컬 회귀 검증: 통과
- GitHub PR/이슈 자동 검사 연결·일반 merge 차단 실기: pending
- 적용 가능한 Actions event policy·policy insights 확인 및 필요한 explicit allow 설정: pending, 변경은 별도 승인 필요
- 최초 PR의 trusted 메타데이터 검사: unavailable. 로컬 수동검증·macOS CI 확인 후 별도 merge 승인 필요
- 최초 merge 후 후속 이벤트의 trusted base 자동 검사 적용 확인: pending
- 승인된 push·PR 이후 실제 CI context 확인과 strict 등록: pending
- title/body/label 변경, stale head, 최신 메타데이터 재조회 및 merge 차단 실기/e2e: pending
- invalid-format 자동 추가·수정 시 제거와 기존 이슈 비변경 확인: pending
- draft release 기본 disabled·게이트·권한·manifest 대응 확인: pending
- 실제 릴리스 태그 생성·push, draft 생성·공개 게시·비인증 다운로드 검증: 미실행, 별도 승인 필요

기존 서명·공증 미적용 기록과 과거 검증은 보존한다. 과거 결과를 이번 전환의 GitHub
실기/e2e 성공으로 재사용하지 않는다.

## 실제 성공 검사에서 strict 설정 등록

`.github/rulesets/main.json`은 현재 적용한 기본 보호다. 필수 검사 등록은
승인된 PR의 실제 macOS 두 검사와 현재 head의 `PR 형식 검증`이 최근 7일 안에
성공한 뒤 진행한다. 설정 도우미는 검사 이름·GitHub Actions 출처·최신 성공 결과를
읽으며 예전 성공 뒤에 최신 실패가 있으면 등록하지 않는다.

```sh
# 실제 PR 번호로 설정을 검토한다. 기본 실행은 읽기 전용이다.
python3 scripts/configure_main_ruleset.py --pr 2
# 준비한 설정을 승인된 범위에서 적용하고 다시 읽어 확인한다.
python3 scripts/configure_main_ruleset.py --pr 2 --apply
```

예시 번호 2는 아직 존재하는 PR을 뜻하지 않는다. 첫 전환 PR에는 trusted 기본
브랜치의 자동 검사가 없으므로 위 도우미의 전체 등록도 성공하지 않는다. 첫 PR에서는 실제 macOS 두 검사 성공을 확인한 뒤 `--ci-only`로 해당 검사만 strict
필수로 등록할 수 있다. 로컬 제출 검사와 필수 macOS 검사 확인 후 별도 지시로 머지하고,
후속 PR에서 trusted 형식 검사를 실행해 전체 strict 설정을 등록한다. 전체 필수 검사 보호의 완성 시점을 명시하며 상시 bypass 권한을 추가하지 않는다.
`--ci-only`는 이미 등록된 PR 형식 검사 등 다른 필수 검사를 제거하지 못한다.

최초 전환 PR의 macOS 검사 등록 예시는 다음과 같다. 실제 실행이 없거나 최신 검사가
실패했다면 설정 도우미가 거부한다. 기본 실행은 설정 검토만 하며 GitHub를 수정하지 않는다.

```sh
python3 scripts/configure_main_ruleset.py --pr 2 --ci-only
python3 scripts/configure_main_ruleset.py --pr 2 --ci-only --apply
```

## 기존 개발 양식 이전과 전환 이슈

기존 개발 `feature.yml`·`fix.yml`·`docs.yml`·`init.yml`·`refactor.yml`은 원문 바이트
그대로 이전했다. 공개 기능 제안은 `proposal.yml`, 공개 버그는 `bug.yml`, 추가 운영
양식은 `task.yml`로 유지한다. 원문 제목·이모지 라벨·필수 Description/Tasks·선택 ETC와
required 설정, config의 blank false를 보존한다. 템플릿 안내용 placeholder는 실제
제출 본문에 남기지 않는다.

공통 검사기·생성 도우미·Actions는 이슈 8종을 지원한다. 관련 85개 회귀 검사와
고정 Ruff 검사를 통과했고 원문 5개 파일의 바이트·SHA를 확인했다. 원격 이모지 라벨도
같은 이름·색·설명으로 이전한 뒤 재조회했다. 기존 전체 테스트 516개 결과는 양식 복원
이전의 검증이며, 복원 후에는 관련 회귀 검사를 실행했다.

2026-10-14 추가 지시에 따라 작업 브랜치의 커밋·push와 이슈 #1 갱신을 진행한다.
이슈 #1은 복원한 `init.yml`의 `[init]` 제목, `🧹 chore` 라벨, Description·Tasks·ETC
형식을 사용한다. 작업 항목과 완료 기준은 Tasks 안에 체크리스트로 기록하고 검증 결과·
미검증 항목·권한 제약은 ETC에 기록한다. 기존 이슈를 일괄 수정하지 않는다.

변경 파일은 삭제를 포함해 34개다. 작업 브랜치에 push해도 기본 브랜치의 이슈 선택
화면과 trusted metadata 자동 검사는 PR 반영 전까지 갱신되지 않는다. PR 생성·merge·
태그·실제 배포는 별도 지시가 필요하다.

# AGENTS.md

## 공개 저장소와 작업 범위

- 개발·이슈·PR·빌드·배포의 단일 원본은 `jaehunshin-git/heiccy`다. 기존 private 저장소는 과거 기록 보존용이며 신규 개발이나 배포 원본으로 사용하지 않는다.
- private Git 이력, 내부 이슈·PR·문서 및 개인 파일을 복사하지 않는다. 공개에 필요한 일반 규칙과 명시적으로 승인된 개발 이슈 템플릿 5종만 이전한다. 템플릿은 원문 바이트를 보존하며 내부 문서 이전으로 범위를 넓히지 않는다.
- 작업 전 현재 브랜치, 변경 파일과 적용 지침을 확인한다. 다른 작업자의 변경을 덮어쓰지 않는다.
- 커밋, push, PR 생성, merge, 태그 생성·push와 릴리스 게이트 변경·게시는 각각 사용자 승인 범위를 확인한다. 승인 없는 원격 변경을 수행하지 않는다.
- `gh`는 샌드박스 밖에서 실행한다. 개인 인증 정보나 전용 PAT를 저장소·로그·배포 파일에 넣지 않는다.

## 문서와 배포 파일

- 신규 운영 문서는 한국어로 작성한다. `README.md`는 한국어, `README.en.md`는 영어를 유지한다.
- PyPI 설명 `README.pypi.md`와 `pyproject.toml`의 `description` 등 배포 메타데이터는 영어로 유지한다. 앱 README와 CLI/TUI 배포 설명의 범위를 구분한다.
- CLI/TUI 기능 변경 시 관련 README를 함께 검토한다. 공개 링크는 `https://github.com/jaehunshin-git/heiccy`를 사용한다.
- `LICENSE`는 영어로 유지하고 한국어 README에 이용 조건을 요약한다. 한국어 전문을 추가하면 `LICENSE.ko.md`가 참고 번역임을 명시한다.
- `input/`·`output/`의 사진과 개인 파일은 Git과 모든 배포에서 제외한다. sdist는 `pyproject.toml`의 `only-include` 허용 목록을 따른다.
- sdist 설명은 `README.pypi.md`만 포함한다. 앱 README·앱 빌드 파일·`docs/`를 추가하지 않고 PyPI 설명의 문서 링크는 공개 절대 URL을 사용한다.
- wheel의 `METADATA`, sdist의 `PKG-INFO`에서 영어 Summary·본문과 허용 목록을 검증한다. 게시된 PyPI 버전은 덮어쓰지 않는다.

## 이슈와 PR 제출 전 필수 절차

1. **생성 전에 해당 템플릿 파일을 실제로 읽는다.** 공개 사용자 버그는 `.github/ISSUE_TEMPLATE/bug.yml`, 기능 제안은 `proposal.yml`, 개발 작업은 `feature.yml`·`fix.yml`·`docs.yml`·`init.yml`·`refactor.yml`, 운영 작업은 `task.yml`, PR은 `.github/PULL_REQUEST_TEMPLATE.md`를 읽는다. 파일이 없거나 구현이 pending이면 임의 형식으로 제출하지 않는다.
2. 템플릿의 제목 prefix·labels·섹션·필수 항목을 그대로 따른다. CLI/API로 생성할 때도 웹 폼과 같은 title/labels를 사용한다. 공개 버그·제안 양식과 원문 개발 5종을 보존하고 운영 작업 이슈는 `[작업]` 제목과 `enhancement` label을 사용한다.
3. 필수 항목의 빈칸, 안내용 placeholder, 내용 없는 체크리스트를 남기지 않는다. `해당 없음`은 템플릿이 허용하는 항목에만 사용하고 이유를 적는다. 작업 이슈는 Description, Tasks, 완료 기준, 검증 계획, 제약 및 참고를 작성한다.
4. PR은 Summary, Tasks, To Reviewer, Validation, Unverified를 작성하고 `Closes #번호` 등으로 관련 이슈를 연결한다. 수행한 검증과 미실행·pending 검증을 구분한다. 미검증 항목이 없다는 설명도 템플릿이 허용하는 방식과 이유를 따른다.
5. **실제로 제출할 본문 파일을 만든 뒤 다시 읽고**, 아래 공통 로컬 검사기로 제목과 본문을 검사한다. 실패하면 내용을 수정하고 재검사한다. 형식 실패를 우회하거나 검사 없이 직접 `gh`/API로 제출하지 않는다.
6. 승인을 받은 제출에는 `scripts/create_submission.py`의 동일 검증 옵션을 사용한다. 생성 후 GitHub의 실제 제목·본문·라벨을 다시 읽고 검사한다. 실패하면 본문을 수정하고 재검증하며 제출 성공으로 보고하지 않는다. `gh issue create`·`gh pr create`는 Git `commit-msg` 훅을 실행하지 않는다.

아래는 현재 검사기 인터페이스다. 검사기와 helper의 `--help`로 옵션을 확인했다.
운영 전환 이슈 #1은 최초 task 형식에서 복원된 init 형식으로 갱신한다. 원격 자동 검증은 기본 브랜치 반영 후 활성화된다.

```sh
python3 scripts/check_submission.py --kind issue --template init --title '[init] 단일 저장소 운영 전환' --body-file /path/to/issue-body.md --label '🧹 chore'
python3 scripts/check_submission.py --kind pr --title 'chore: 단일 저장소 운영 전환' --body-file /path/to/pr-body.md
```

이슈의 `--template`은 `bug|proposal|feature|fix|docs|init|refactor|task` 중 해당 형식을 지정한다. helper도
`--kind issue|pr`, `--title`, `--body-file`, `--template`, `--label` 옵션을 동일하게 사용한다.
`--template`은 이슈에 지정하며 `--label`로 템플릿의 labels를 전달한다.
필수 항목을 충족하는 것과 실제 제출 권한은 별개다.

## 기존 개발 양식 보존

- 기존 개발 `feature.yml`·`fix.yml`·`docs.yml`·`init.yml`·`refactor.yml`은 원문 바이트 그대로 보존한다. 공개 기능 제안은 `proposal.yml`, 공개 버그는 `bug.yml`, 추가 운영 양식은 `task.yml`로 유지한다.
- 개발 양식의 제목·이모지 라벨·필수 Description/Tasks·선택 ETC와 config의 `blank_issues_enabled: false`를 유지한다.
- 양식·검증 규칙·문서를 함께 갱신한다. 원문 placeholder는 템플릿 안내에만 두고 실제 제출 본문에서는 제거한다.
- 기본 브랜치에 반영되기 전에는 GitHub 웹 양식과 기본 브랜치의 자동 검사가 활성화됐다고 보고하지 않는다.

## 커밋 훅과 main 보호

- `.githooks/commit-msg`, `scripts/check_commit_message.py`, `scripts/install_git_hooks.sh`의 검사·이전 설정 복원 동작을 유지한다. 설치는 [훅 안내](.github/commit-message-hooks.md)를 따른다.
- 개인 전역 Git hooksPath 및 userhooks 파일을 덮어쓰지 않는다. 기존 훅은 읽고 역할을 확인하며 명시적 교체 승인 없이 `--replace`를 사용하지 않는다.
- 형식 실패를 `--no-verify`, 훅 비활성화 또는 직접 제출로 우회하지 않는다.
- main ruleset은 active, PR 필수, 승인 수 0, 대화 해결 필수, 삭제·force push 차단, bypass 없음으로 운영한다. 초기 설정 적용과 API 재조회는 완료했으며 실제 실패 검사로 merge를 차단하는 원격 검증은 pending이다.
- required CI contexts는 승인된 push·PR의 실제 실행에서 확인한 이름만 strict로 등록한다. 예정된 context를 미리 등록하거나 미실행 CI를 통과로 기록하지 않는다.
- 최초 PR 시점의 main에는 새 workflow·scripts가 없어 trusted 메타데이터 검사는 unavailable이다. 최초 PR은 로컬 수동검증과 macOS CI 결과를 확인한 뒤 별도 merge 승인을 받는다. 최초 merge 후 base에 검사 코드가 들어가면 후속 이벤트부터 자동 적용하며 첫 PR이 자동 검사됐다고 기록하지 않는다.
- public `pull_request_target`의 Actions event policy를 확인하고 필요한 explicit allow 설정은 별도 승인 후 진행한다. 현재 default policy는 evaluate이며 영향 대상은 2026-11-02 enforce 예정이다. 원격 정책 확인·변경은 pending이며 [공식 안내](https://docs.github.com/en/actions/reference/security/securely-using-pull_request_target)를 따른다.
- workflow queue 시작 전 및 API 검사 사이의 메타데이터 편집·merge race는 atomic하게 완전 차단할 수 없다. pending 전환·재조회·직렬화의 한계를 운영 문서대로 보고한다.

## 출처와 독립 배포

- 앱 태그는 `macos-vVERSION`, PyPI 태그는 `pypi-vVERSION`이며 버전과 배포 시점은 독립적이다. 과거 문서의 앱 `vVERSION` 표기는 이전 snapshot 배포 방식이며, 2026-10-13 전환 점검에서 원격 앱 태그·릴리스는 없었다.
- `SOURCE.json`은 초기 공개 snapshot 기록으로 불변이다. baseline `77908397ffb24dc1881ea1f0ebfc5d9d9c977852`의 Git blob 기준 검증을 사용하며 현재 작업 트리 해시로 갱신하지 않는다.
- 새 release manifest는 같은 공개 저장소의 같은 빌드 SHA와 `.github/workflows/macos.yml` 실행 및 산출물 해시를 기록한다. 초기 snapshot의 private SHA를 새 빌드 출처로 쓰지 않는다.
- draft release는 기본 disabled다. `HEICCY_RELEASE_ENABLED`, `public-release` environment와 해당 job의 `contents: write` 권한을 가진 `github.token`을 사용하며 PAT를 도입하지 않는다. 태그 생성·push와 실제 릴리스 동작은 별도 승인 후 수행한다.
- Developer ID 서명·Apple 공증은 기존 미적용 상태를 유지해 기록한다. 빌드 성공을 실기·공개 다운로드 검증 완료로 보고하지 않는다.
- 구현 요구, 로컬 검증 결과, GitHub 실기/e2e의 pending을 구분한다. 기여 절차는 [기여 안내](CONTRIBUTING.md), 세부 운영 계약과 플랫폼 한계는 [저장소 운영](docs/repository-operations.md)을 따른다.

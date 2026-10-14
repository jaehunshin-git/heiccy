# 커밋 메시지 검사 훅

프로젝트의 Commit
Instructions를 저장소 규칙으로 관리한다. 개인 `~/.codex/config.toml`은 설치와 검사 시
읽지 않는다. 위반은 경고가 아니라 비정상 종료로 커밋을 차단하며, 메시지를 자동 수정하지
않는다. 오류에는 행 번호, 원인, 명사형 수정 예시를 표시한다.

## 설치와 실행 환경

소스 체크아웃과 Git, Python 3.11 이상이 필요하다. 외부 Python 패키지는 필요 없다.
터미널과 Git GUI 모두 훅 프로세스의 `PATH`에서 `python3`를 찾을 수 있어야 한다.
필요하면 `COMMIT_MESSAGE_PYTHON`에 Python 실행 파일의 절대 경로를 설정한다.
이 변수는 인자 없는 실행 파일 경로이며 가상환경 활성화는 필수가 아니다.

```sh
bash scripts/install_git_hooks.sh
# 예: GUI에도 같은 환경 변수를 전달해야 하는 사용자 지정 Python
COMMIT_MESSAGE_PYTHON=/opt/homebrew/bin/python3 bash scripts/install_git_hooks.sh
```

설치기는 훅의 실행 권한을 설정하고 저장소 로컬 `core.hooksPath`를 `.githooks`로
연결한다. 설치 파일의 위치로 저장소를 찾으므로 다른 디렉터리에서도 절대 경로로 실행할
수 있다. 개인의 전역 설정과 전역 userhooks 파일은 수정하거나 덮어쓰지 않는다.
Git clone만으로 훅은 활성화되지 않으므로 새 체크아웃에서 설치가 필요하다.

기존 hooksPath가 있으면 자동으로 덮어쓰지 않는다. 기존 훅의 역할을 확인한 뒤 명시적으로
교체하거나, 기존 commit-msg 훅에서 검사기를 호출하도록 직접 통합한다. 자동 체이닝은
제공하지 않는다. 기본 `.git/hooks`의 훅도 hooksPath 설치 후 호출되지 않으므로 기존
훅이 있으면 함께 검토한다.

```sh
bash scripts/install_git_hooks.sh --replace
bash scripts/install_git_hooks.sh --uninstall
```

교체 시 이전 로컬 경로를 `commitMessageHooks.installState` Git 설정에 보관한다.
해제는 이 설치 기록과 현재 경로가 일치할 때만 이전 로컬 값을 복원한다. 기존 전역 경로를
가린 경우 로컬 값을 제거해 전역 경로를 다시 상속한다. 설치 후 다른 도구가 hooksPath를
변경하거나 보관 기록이 손상된 경우 설치·해제를 중단하고 설정을 그대로 유지한다.
보관 기록이 없는 임의의 hooksPath는 해제하지 않는다.

## worktree 적용 범위

기본 `--local` 설정은 같은 저장소의 모든 linked worktree가 공유한다. 경로를 절대 경로가
아닌 `.githooks`로 설정하므로 각 worktree의 현재 체크아웃에 있는 훅·검사기·규칙을 사용한다.
훅 파일이 없는 이전 브랜치에는 Git이 훅을 실행하지 않는다. 설치 전에 다른 worktree의
브랜치에도 훅 파일이 있는지 확인한다. 브랜치를 바꿀 때도 해당 브랜치의 규칙을 사용한다.

worktree별 설정을 이미 사용하는 저장소에서는 다음 명령으로 현재 worktree만 설치하거나
해제한다. 설치기가 `extensions.worktreeConfig`를 자동 활성화하지는 않는다. 이 기능을
새로 켜려면 Git의 기존 `core.bare`·`core.worktree` 설정 이전 요건을 먼저 확인한다.

```sh
bash scripts/install_git_hooks.sh --worktree
bash scripts/install_git_hooks.sh --worktree --uninstall
```

더 높은 우선순위의 command 또는 worktree hooksPath가 기본 설치 경로를 가리면 설치를
거부한다. 다른 worktree에 사용자 지정 worktree 설정이 있으면 공유 로컬 설정보다 그
worktree 설정이 우선한다.

## 검사 규칙

```text
fix(macos): 클립보드 복원 조건 수정

- 종료 시 원본 클립보드 복원
- 새로운 복사 감지 시 이전 결과 게시 차단

Refs: #15
```

- 제목은 `<type>(<scope>): <한국어 요약>`이며 scope는 선택 사항이다.
- type은 영어 소문자이며 `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `build`,
  `ci`, `chore`, `perf`, `revert`를 기본 허용한다.
- scope는 괄호 안의 비어 있지 않은 한 토큰이다. 실제 모듈/기능/패키지와의 대응은 리뷰
  대상이며 문자열 일치로 차단하지 않는다.
- 본문은 선택 사항이다. 있으면 제목 다음에 빈 줄을 둔다. 본문과 footer도 빈 줄로 구분한다.
- breaking change는 제목에서 `feat(api)!: API 응답 구조 변경`처럼 표시하거나
  `BREAKING CHANGE: API 응답 구조 변경` footer를 사용한다. 규격의 동의어
  `BREAKING-CHANGE:`도 허용하며 영어 대문자 토큰을 유지한다. 설명은 한국어 명사형이다.
- 이슈 참조는 필수가 아니다. 사용하면 footer에 `Refs: #123` 또는 `Closes: #123`을 쓴다.
  여러 번호는 `Refs: #15, #123` 또는 `Refs: #15 #123`으로 작성한다.
- `Co-authored-by:`·`Signed-off-by:`는 `이름 <메일주소>` 형식의 메타데이터로 검사한다.
  기타 footer는 토큰을 제외한 설명에 한국어·명사형 규칙을 적용한다.
- 제목 길이 제한은 없다.

## 명사형 판별과 한국어 분석의 한계

허용 type, 허용 명사형 종결, 차단 서술형 종결은
`scripts/commit_message_rules.json`에서 관리한다. 자연어 설명의 마지막 한국어 단어가
`추가`, `수정`, `개선`, `복원`, `차단` 등 허용 명사로 끝나거나 `줄임`, `막음`, `수정함`
등 받침 ㅁ의 명사화 형태로 끝나면 통과한다. `수정했습니다`, `추가합니다`, `개선했다`,
`변경됩니다`, `좋아요` 등 서술형 종결은 제목·본문·footer에서 모두 차단한다. 알려지지
않은 종결도 차단하므로 검토된 명사와 회귀 사례를 규칙 파일과 테스트에 함께 추가한다.

본문의 같은 문단에 있는 줄은 이어진 문장으로 검사하고, 목록 항목과 문장 구분 기호는
별도로 검사하며 문단 중간 줄의 서술형 종결도 차단한다. 인라인 백틱 코드와 짝이 맞는
작은따옴표·큰따옴표·곡선 따옴표 인용은 (여러 줄 인용 포함)
자연어 검사에서 제외한다. 인용 주변의 설명은 여전히 한국어 명사형이어야 한다.
닫힌 백틱/물결표 코드 블록은 내용의 언어·종결을 검사하지 않으며 닫히지 않은 코드 블록은
차단한다. 인라인 코드의 양쪽 백틱 개수도 같아야 한다. `>` 블록 인용과 네 칸/탭 들여쓰기
코드도 자연어 검사에서 제외한다. breaking change 등의 설명 footer에는 코드 예시를
함께 쓸 수 있지만 한국어 명사형 설명이 반드시 필요하다. 이슈/작성자 footer 뒤에는
자연어·인용·코드를 추가하지 않는다.

이는 형태소 분석기나 실제 언어 판별 모델이 아니다. 인용과 코드를 제거한 자연어에 한글
음절이 포함됐는지 확인할 뿐, 한국어가 주된 언어인지 보증하지 않는다. NFC 정규화로
분해된 한글도 검사한다. API·패키지명·식별자 혼용은 허용하지만, 뒤에 기술 용어를 붙여
서술형 위반을 숨길 수는 없다. 규칙 목록과 받침 기반 판별에는 새로운 명사 차단, 문장
안쪽의 서술형 누락, 명사처럼 보이는 비문 통과 가능성이 있다. 의미와 scope는 리뷰로
확인하고 오탐·누락은 재현 메시지와 테스트로 보완한다. 서술형 위반을 경고로 낮추지 않는다.

Git 기본 편집기가 덧붙인 주석은 Git의 `stripspace --strip-comments`로 검사 대상에서
제외하며 사용자 지정 `core.commentChar`·`core.commentString`도 따른다. 편집기에서
`commit.cleanup=scissors`의 구분선 뒤 내용은 검사에서 제외한다. 그 외 설정에서는
구분선 뒤 내용이 실제 diff 형식일 때만 제외하며 `verbatim`에서는 원문을 검사한다.
구분선만으로 보존할 자연어 본문을 검사에서 숨길 수는 없다. 기본 설정에서 `-m`·`-F`의
문자 그대로의 주석과 `commit.cleanup=whitespace`·`verbatim` 등의 보존 설정에서는
주석도 검사한다. `commit.cleanup=strip`을 명시하면 `-m`·`-F`에서도 주석을 제외한다.
명령줄의 별도 `--cleanup` 옵션은 훅에 전달되지 않으므로 기본 설정과 다른 보존 동작이
필요하면 저장소의 `commit.cleanup`을 명시한다. 메시지 파일 자체를 다시 쓰지는 않는다.

## 자동 메시지 정책

| 메시지 | 처리 |
| --- | --- |
| Git 자동 `Merge ...` | 영문 제목 예외 없음. `git merge -m 'chore: 기능 브랜치 통합' ...`처럼 직접 작성 |
| Git 자동 `Revert "..."` 및 영문 본문 | 검사기에 들어오면 차단. `git revert --no-commit <commit>` 후 한국어 `revert: 기능 변경 복원`으로 일반 커밋 권장 |
| `fixup! <대상 제목>` | prefix 한 개만 제외하고 대상 제목·추가 본문·footer 검사 |
| `squash! <대상 제목>` | prefix 한 개만 제외하고 대상 제목·추가 본문·footer 검사 |
| 중첩 prefix 또는 `amend!` | 허용하지 않음. 일반 규칙에 맞게 메시지 작성 |

실제 Git 2.54.0 (Apple Git-157)에서 `git revert --no-edit`가 `commit-msg`를 호출하지
않는 동작을 확인했다. 이 경로의 자동 커밋은 이 훅만으로 차단할 수 없다. `rebase` 등
Git 내부 커밋 생성 경로도 훅 호출을 보장하지 않으며, 강제 검증에는 별도 CI가 필요하다.
검사기를 직접 호출하면 영문 revert 메시지는 예외 없이 차단된다.

규칙 도입 전의 영문 커밋을 대상으로 한 fixup/squash 자동 제목도 차단한다. 대상 제목을
한국어 규칙에 맞게 바꾼 경우 Git autosquash의 제목 일치가 달라질 수 있으므로 rebase
목록을 직접 검토한다. 이미 자동 merge/revert 커밋이 훅에서 차단된 경우 Git 상태를 확인하고
한국어 규칙에 맞는 메시지로 커밋을 완료하거나 해당 작업을 abort한다. 단순히 `Merge`,
`Revert`, `fixup!` 문자열이 있다는 이유로 메시지 전체 검사를 건너뛰지 않는다.

## 직접 검사와 검증

```sh
python3 scripts/check_commit_message.py /path/to/COMMIT_EDITMSG
python3 scripts/check_commit_message.py --rules scripts/commit_message_rules.json /path/to/message
uv run pytest tests/test_commit_message.py
uvx --from ruff==0.14.4 ruff check --config pyproject.toml src tests scripts packaging/macos
```

직접 검사 명령은 Git 편집기 주석 제거 없이 원문을 검사한다. 정상 종료는 0, 규칙 위반은 1,
파일·규칙·실행 환경 오류는 2이다. 테스트는 정상/실패 메시지, 본문·breaking change,
인용·코드·규칙 확장, 실제 Git 커밋 생성과 차단, 자동 merge/fixup/squash와 revert의 훅 호출 한계,
주석 처리, 기존 hooksPath 복원과 linked worktree를 임시 저장소에서 검증한다.
개발용 scripts·훅·문서는 PyPI 허용 목록에 추가하지 않으며 sdist에서는 해당 테스트를 건너뛴다.

로컬 훅은 기술적으로 `git commit --no-verify`로 우회할 수 있지만 저장소 정책은 형식
실패를 훅 비활성화나 우회로 제출하는 것을 금지한다. 원격 강제 범위는 실제로 실행해
등록한 CI status와 main ruleset을 기준으로 판단한다. 이번 단일 저장소 전환의 GitHub
실기/e2e 확인과 실제 CI context의 strict 등록은 pending이다.

## 이슈·PR 검사는 커밋 훅과 별도

`gh issue create`·`gh pr create`와 API 제출은 Git 커밋이 아니므로 `commit-msg`를
실행하지 않는다. 훅 설치만으로 이슈·PR 형식 검사가 활성화됐다고 보고하지 않는다.
생성 전 해당 템플릿을 실제로 읽고 제목·labels·필수 항목을 동일하게 작성한다.
본문을 실제 제출 파일로 만든 뒤 다시 읽고 공통 검사기로 검사한다. 빈 필수 항목과
placeholder를 남기지 않으며 `해당 없음`은 허용된 항목에만 이유와 함께 쓴다.

현재 검사기와 helper의 인터페이스는 다음과 같으며 두 CLI의 `--help`로 확인했다.
이슈 #1의 공통 checker 통과는 사용자 전달 결과이고 실제 제출·원격 자동 검증은 pending이다.

```sh
python3 scripts/check_submission.py --kind issue --template task --title '[작업] 단일 저장소 운영 전환' --body-file /path/to/issue-body.md --label enhancement
python3 scripts/check_submission.py --kind pr --title 'chore: 단일 저장소 운영 전환' --body-file /path/to/pr-body.md
```

이슈의 `--template`은 `bug|proposal|feature|fix|docs|init|refactor|task`이고 `scripts/create_submission.py` helper도
`--kind`, `--title`, `--body-file`, `--template`, `--label`의 같은 validation 옵션을
사용한다. 이슈에 `--template`을 지정하고 템플릿 labels를 `--label`로 전달한다.
검사 실패를 직접 CLI/API 호출로 우회하지 않는다.
제출 승인과 형식 통과는 별개이며 실제 제출은 승인 범위 안에서만 수행한다.
PR의 Summary·Tasks·To Reviewer·Validation·Unverified 및 `Closes #번호` 연결,
trusted base 검사기의 `PR 형식 검증` status, 이슈의 invalid-format 표시와 main
ruleset·플랫폼 race 한계는 [단일 저장소 운영](repository-operations.md)을 따른다.
기존 commit-msg 검사기와 installer의 설정 보관·복원 동작은 유지한다.

참고 규격: [Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/),
[Git hooks](https://git-scm.com/docs/githooks),
[Git commit](https://git-scm.com/docs/git-commit),
[Git worktree](https://git-scm.com/docs/git-worktree).

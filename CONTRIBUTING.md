# 기여 안내

개발·이슈·PR·빌드·배포는 공개 저장소 `jaehunshin-git/heiccy`에서 진행합니다.
작업 전에 현재 브랜치, 변경 파일과 `AGENTS.md`를 확인하고 다른 작업자의 변경을 보존하세요.
빌드·검증 방법은 [빌드 안내](docs/build.md), 배포·보호 정책은 [저장소 운영](docs/repository-operations.md)을 따릅니다.

## 이슈 선택

생성 전에 아래 해당 템플릿 파일을 실제로 읽으세요. 웹·CLI·API 모두 같은 제목 접두사,
라벨과 필수 섹션을 사용합니다. 템플릿이 없으면 임의 형식으로 제출하지 않습니다.

| 용도 | 템플릿 | 제목 접두사 | 라벨 |
| --- | --- | --- | --- |
| 사용자 버그 신고 | [bug.yml](.github/ISSUE_TEMPLATE/bug.yml) | `[버그]` | `bug` |
| 공개 기능 제안 | [proposal.yml](.github/ISSUE_TEMPLATE/proposal.yml) | `[제안]` | `enhancement` |
| 기능 개발 | [feature.yml](.github/ISSUE_TEMPLATE/feature.yml) | `[feat]` | `✨ feature` |
| 버그 수정 | [fix.yml](.github/ISSUE_TEMPLATE/fix.yml) | `[fix]` | `🐛 bug` |
| 문서 작업 | [docs.yml](.github/ISSUE_TEMPLATE/docs.yml) | `[docs]` | `📝 docs` |
| 환경 세팅 | [init.yml](.github/ISSUE_TEMPLATE/init.yml) | `[init]` | `🧹 chore` |
| 리팩토링 | [refactor.yml](.github/ISSUE_TEMPLATE/refactor.yml) | `[refactor]` | `♻️ refactor` |
| 개발·운영 작업 | [task.yml](.github/ISSUE_TEMPLATE/task.yml) | `[작업]` | `enhancement` |

버그에는 사용 구성 요소·실행 환경·재현 방법을, 제안에는 해결하고 싶은 문제·제안하는 동작을 작성합니다.
개발 5종은 📄 Description·✅ Tasks가 필수이고 📎 ETC는 선택입니다.
운영 작업에는 📄 Description·✅ Tasks·🎯 완료 기준·🧪 검증 계획·📎 제약 및 참고를 작성합니다.
필수 항목에 빈칸, 안내용 placeholder나 내용 없는 체크리스트를 남기지 마세요.
`해당 없음`은 템플릿이 허용한 항목에서만 구체적인 이유와 함께 사용합니다.
사진 원본·개인정보·인증 정보가 포함된 파일이나 로그를 첨부하지 않습니다.

## PR과 제출 검증

[PR 템플릿](.github/PULL_REQUEST_TEMPLATE.md)을 읽고 Summary·Tasks·To Reviewer·Validation·Unverified를 작성합니다.
제목은 Conventional Commits 형식을 따르고 Summary에 `Closes #번호` 등으로 관련 이슈를 연결합니다.
Validation에는 실행 환경·명령·결과를, Unverified에는 미실행 검증과 이유를 적습니다.
미검증 항목이 없을 때도 템플릿이 허용하는 표현과 근거를 작성합니다.

1. 실제 제출할 본문 파일을 만든 뒤 다시 읽습니다.
2. 공통 검사기로 제목·본문·라벨을 검사하고 실패하면 수정 후 재검사합니다.
3. 제출 권한을 확인하고 같은 옵션의 `scripts/create_submission.py`로 생성합니다.
4. 생성 후 GitHub의 실제 제목·본문·라벨을 다시 읽고 검사합니다. 불일치나 실패가 있으면 수정·재검증합니다.

저장소 루트에서 실행하는 검사 예시입니다. 본문 파일은 선택한 템플릿을 충족해야 합니다.

```sh
python3 scripts/check_submission.py --kind issue --template task --title '[작업] 배포 안내 정비' --body-file /path/to/issue-body.md --label enhancement
python3 scripts/check_submission.py --kind pr --title 'docs: 배포 안내 정비' --body-file /path/to/pr-body.md
```

생성 도우미도 `--kind issue|pr`, `--title`, `--body-file`, `--template`, `--label`을 사용합니다.
이슈는 8종 중 해당 `--template`과 템플릿의 라벨을 `--label`로 전달합니다.
도우미는 제출 전 검사와 생성 후 재조회를 수행합니다. 형식 실패를 직접 `gh`/API 호출로 우회하지 않습니다.
`gh issue create`·`gh pr create`는 Git `commit-msg` 훅을 실행하지 않습니다.

## 커밋과 권한

[커밋 메시지 훅 안내](.github/commit-message-hooks.md)에 따라 설치·복원합니다.
개인 전역 `core.hooksPath`와 userhooks 파일을 보존하고 기존 훅의 역할을 먼저 확인하세요.
명시적 교체 승인 없이 `--replace`를 사용하지 않으며 `--no-verify`나 훅 비활성화로 실패를 우회하지 않습니다.
커밋·push·PR 생성·merge·태그 생성·push·릴리스 게이트 변경·게시의 승인 범위를 각각 확인합니다.
`gh`는 샌드박스 밖에서 실행하며 인증 정보나 전용 PAT를 저장소·로그·배포 파일에 넣지 않습니다.

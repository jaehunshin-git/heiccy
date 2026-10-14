# 단일 저장소 운영

개발·이슈·PR·빌드·배포의 단일 원본은 `jaehunshin-git/heiccy`입니다.
기존 private 저장소는 과거 기록 보존용이며 신규 개발이나 배포 원본으로 사용하지 않습니다.
private Git 이력·내부 이슈·PR·문서·개인 파일을 복사하지 않습니다.
이 문서는 지속적인 운영 정책입니다. 원격 설정과 검증 결과는 실제 상태를 조회해 해당 이슈·PR에 기록합니다.
기여·제출 절차는 [기여 안내](../CONTRIBUTING.md), 훅 설치·복원은 [훅 안내](../.github/commit-message-hooks.md)를 따릅니다.

## 문서와 배포 범위

`README.md`는 한국어 사용자 안내, `README.en.md`는 영어 안내로 유지하고 신규 운영 문서는 한국어로 작성합니다.
PyPI 설명 `README.pypi.md`와 `pyproject.toml`의 배포 메타데이터는 영어로 유지합니다.
`LICENSE`는 영어로 유지하고 한국어 README에 이용 조건을 요약합니다. 한국어 전문을 추가하면 참고 번역임을 명시합니다.
`input/`·`output/`의 사진과 개인 파일은 Git과 모든 배포에서 제외합니다.
sdist는 `pyproject.toml`의 `only-include` 허용 목록을 따르고 설명은 `README.pypi.md`만 포함합니다.
앱 README·앱 빌드 파일·`docs/`를 sdist에 추가하지 않으며 PyPI 문서 링크는 공개 절대 URL을 사용합니다.
wheel의 `METADATA`와 sdist의 `PKG-INFO`에서 영어 Summary·본문과 허용 목록을 검증합니다. 게시한 PyPI 버전은 덮어쓰지 않습니다.

macOS 앱과 PyPI CLI/TUI의 버전·태그·배포 시점은 독립적입니다. 앱 변경만으로 PyPI 업로드를 실행하지 않습니다.

| 대상 | 버전 원본 | 태그 |
| --- | --- | --- |
| macOS 앱 | `packaging/macos/Info.plist` | `macos-vVERSION` |
| PyPI `heic-converter-tui` | `pyproject.toml` | `pypi-vVERSION` |

기존 태그를 이동·삭제·재작성하지 않습니다. 커밋·push·PR 생성·merge·태그 생성·push와 릴리스 게이트 변경·게시는 각각 승인 범위를 확인합니다.

## 출처와 산출물

`SOURCE.json`은 초기 공개 snapshot 기록으로 불변입니다. `packaging/release/verify_source_snapshot.py`로
baseline `77908397ffb24dc1881ea1f0ebfc5d9d9c977852`의 Git blob을 검증합니다.
기록된 과거 `source_commit`을 현재 HEAD와 일치시키거나 작업 트리 변경에 맞춰 해시를 갱신하지 않습니다.
새 릴리스는 같은 공개 저장소에서 빌드하며 private SHA를 새 빌드 출처로 사용하지 않습니다.

새 manifest의 `source_repository`는 `jaehunshin-git/heiccy`, `source_commit`은 실제 공개 빌드 SHA입니다.
provenance는 `.github/workflows/macos.yml`과 해당 Actions 실행을 가리켜야 합니다.
macOS 15·26 manifest는 같은 공개 저장소·같은 SHA·같은 실행을 기록하고 DMG·체크섬·대응 코덱 소스의 해시를 검증합니다.
두 OS의 DMG 바이트가 같을 필요는 없으며 게시 파일은 선택한 macOS 15 산출물의 SHA-256과 일치해야 합니다.
manifest는 서명된 증명서가 아니며 초기 `SOURCE.json`을 대체하지 않습니다.

## CI와 릴리스 게이트

`.github/workflows/macos.yml`은 macOS 15·26에서 빌드·검증합니다. 빌드 job은 `contents: read`를 사용하며
인증 정보를 checkout에 남기지 않습니다. 전용 PAT나 private 저장소 게시 secret을 도입하지 않습니다.
릴리스 job은 기본 disabled이며 다음 조건을 모두 충족해야 합니다.

- 공개 저장소에서 `macos-vVERSION` 태그의 push로 실행하고 두 OS 검증이 성공해야 합니다.
- 저장소 변수 `HEICCY_RELEASE_ENABLED`를 명시적으로 `true`로 설정하고 `public-release` environment를 사용합니다.
- environment의 실제 보호 설정을 별도로 확인합니다. 이름만으로 수동 승인 보호가 생기지는 않습니다.
- 릴리스 job에만 `contents: write`를 부여한 `github.token`을 사용합니다.
- 태그·빌드 SHA의 일치와 main 포함 여부, 두 manifest와 모든 배포 해시를 검증합니다.

PR·브랜치·수동 실행·`pypi-vVERSION`은 앱 릴리스 job을 실행하지 않습니다.
기존 태그에 draft만 생성하고 기존 릴리스·draft를 덮어쓰지 않습니다. 게이트 활성화·draft 생성·공개 게시의 권한을 각각 확인합니다.
Developer ID 서명·Apple 공증 미적용을 배포 안내에 명시하고 CI artifact 검증·로컬 설치·메뉴바 조작·공개 다운로드 검증을 구분합니다.
빌드·서명·패키징 방법은 [빌드 안내](build.md)와 [macOS 패키징 안내](../packaging/macos/README.md)를 따릅니다.

## 제출 형식과 자동 검사

이슈 8종은 `bug|proposal|feature|fix|docs|init|refactor|task`입니다. 제목·라벨·필수 항목과 제출 전후 검사는 [기여 안내](../CONTRIBUTING.md)를 따릅니다.
개발 5종은 원문 바이트·제목·이모지 라벨·필수 Description/Tasks·선택 ETC를 보존하고 `blank_issues_enabled: false`를 유지합니다.
양식·공통 검사 규칙·문서를 함께 관리합니다. 기본 브랜치 반영 전에 웹 양식이나 자동 검사가 활성화됐다고 보고하지 않습니다.
웹 폼의 required 설정은 CLI/API 우회를 차단하지 않습니다. 로컬 도우미를 거치지 않는 제출은 기술적으로 가능하더라도 정책상 금지합니다.
`gh`의 이슈·PR 생성은 `commit-msg` 훅을 실행하지 않으므로 공통 제출 검사가 필요합니다.

PR 자동 검사는 `pull_request_target`에서 trusted base SHA의 검사기·규칙·템플릿만 사용합니다.
PR head의 코드·의존성을 실행하거나 fork 코드에 secret을 전달하지 않습니다. 적용 가능한 Actions event policy의 허용 여부를 확인하고 설정 변경은 별도로 승인받습니다.
main에 workflow·검사 코드가 없는 최초 PR의 trusted 자동 검사는 unavailable입니다.
이 경우 로컬 공통 검사·수동검증과 실제 macOS CI 결과를 확인한 뒤 별도 merge 승인을 받습니다.
trusted base에 코드가 들어간 후 후속 이벤트부터 적용하며 최초 PR이 자동 검사됐다고 소급 기록하지 않습니다.

## 메타데이터 상태와 한계

PR 생성·재개·편집·head 갱신·리뷰 준비·라벨 변경 이벤트마다 최신 live PR의 제목·본문·라벨·head를 조회합니다.
`statuses: write`로 PR head SHA에 `PR 형식 검증`을 기록하며 base SHA의 상태를 PR 결과로 보고하지 않습니다.
먼저 pending을 기록하고 검사 후 failure/success로 전환합니다. 결과 기록 전후에 live fingerprint를 다시 비교합니다.
fingerprint는 제목·본문·라벨·head SHA·base ref·PR 상태를 포함하며 자동 관리하는 `invalid-format` 라벨은 제외합니다.
변경된 head나 메타데이터가 발견되면 성공으로 처리하지 않고 최신 head를 pending으로 돌려 재검증합니다.
PR별 직렬화와 `cancel-in-progress: false`를 사용하되 큐가 모든 중간 이벤트를 순서대로 보존한다고 가정하지 않습니다.

이슈는 생성·편집·재개·라벨 변경 후 최신 내용을 검사해 `invalid-format`을 추가하고 올바르게 수정되면 제거합니다.
라벨 갱신의 재진입은 멱등적으로 처리하며 기존 이슈를 일괄 변경하지 않습니다. 이는 생성 후 표시이며 최초 생성을 차단하지 않습니다.

워크플로가 큐에서 시작하기 전이나 pending 기록 전에는 이전 성공 상태가 남을 수 있습니다.
head가 그대로인 메타데이터 편집은 기존 성공 상태를 즉시 무효화하지 못하며 상태 API 오류로 pending 기록이 실패해도 같은 한계가 있습니다.
API 조회·검사·재조회·상태 기록·merge는 하나의 atomic 트랜잭션이 아닙니다.
직렬화·fingerprint 비교·strict required checks로도 마지막 조회 이후 편집·merge race를 완전히 차단하지 못합니다.

## main 보호와 필수 검사 등록

main ruleset의 운영 정책은 active, PR 필수, 필수 승인 수 0, 대화 해결 필수, 삭제·force push 차단, bypass 없음입니다.
승인 수 0이어도 PR은 필요합니다. 실제 설정은 API로 재조회하며 관리자의 ruleset 편집까지 영구 차단할 수는 없습니다.
필수 검사는 실제 최근 실행에서 확인한 이름과 GitHub Actions 출처만 strict로 등록합니다. 예정된 이름이나 미실행 CI를 등록하지 않습니다.
`scripts/configure_main_ruleset.py --pr 실제번호`는 설정 검토용이며 승인된 적용에만 `--apply`를 사용하고 적용 후 재조회합니다.
도우미는 PR merge SHA의 macOS 두 검사와 현재 head의 `PR 형식 검증`이 최근 7일 안에 성공했는지 확인합니다.
예전 성공 뒤 최신 실패를 성공으로 재사용하지 않습니다. 최초 PR에서 trusted 검사가 없으면 실제 macOS 성공에 한해 `--ci-only`로 등록합니다.
`--ci-only`로 기존의 다른 필수 검사를 제거하지 않습니다. 후속 trusted 검사 성공 후 전체 strict 설정을 등록하고 merge 차단 동작을 별도로 검증합니다.

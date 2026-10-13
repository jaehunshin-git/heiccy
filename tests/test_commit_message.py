"""한국어 커밋 규칙과 실제 Git 훅의 통과/차단 계약 검증."""

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import unicodedata
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "check_commit_message.py"
if not SCRIPT.is_file():
    pytest.skip("sdist에는 개발용 Git 훅이 포함되지 않습니다.", allow_module_level=True)
spec = importlib.util.spec_from_file_location("commit_message", SCRIPT)
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


@pytest.mark.parametrize(
    "message",
    [
        "fix(macos): 클립보드 복원 조건 수정",
        "feat: API 응답 처리 개선",
        "feat(api)!: API 응답 구조 변경",
        "chore: 아주 " + "긴 " * 100 + "제목 추가",
        "docs(존재하지않는모듈): 개발 안내 추가",
        "fix: 오류 수정\n\n검증 조건 추가\n누락 항목 제거\n\nRefs: #15\nCloses: #123",
        "feat: API 개선\n\nBREAKING CHANGE: API 응답 구조 변경",
        "feat: API 개선\n\nBREAKING-CHANGE: API 응답 구조 변경",
        "feat: API 개선\n\nBREAKING CHANGE: API 응답\n구조 변경",
        "feat: API 개선\n\nBREAKING CHANGE: API 구조 변경\n\nCloses: #15",
        "fix: 오류 수정\n\n- 검증 조건 추가\n- 누락 항목 제거",
        "fix: 오류 수정\n\n조건 추가. 누락 제거.",
        'docs: "수정했습니다" 인용 예시 추가',
        "docs: `수정했습니다` 차단 예시 추가",
        "docs: 오류 예시 추가\n\n```python\nprint('수정했습니다')\n```",
        "docs: 오류 예시 추가\n\n~~~text\nEnglish example\n~~~",
        "fix: 출력 형식 변경 JPEG",
        "fix: pillow.heif 응답 처리 개선",
        "fix: 한글.py 파일 처리 개선",
        'fix: 오류 수정\n\n"기능을 추가합니다\n오류를 수정했습니다" 문구 제거',
        "docs: ``단일 ` 백틱`` 예시 추가",
        "docs: 오류 예시 추가\n\n> 오류가 발생했습니다\n\n오류 처리 개선",
        'docs: 오류 예시 추가\n\n    raise ValueError("invalid")',
        'feat!: 구조 변경\n\nBREAKING CHANGE: API 응답 구조 변경\n\n```json\n{"version": 2}\n```',
        "fix: 제목 줄임",
        "fix: 새 요청 막음",
        "fix: 설정 수정함",
        "fixup! fix(macos): 클립보드 복원 조건 수정",
        "squash! feat: API 응답 처리 개선\n\n검증 조건 추가",
        "fix: 오류 수정\n\nCo-authored-by: 이름 <name@example.com>",
        "fix: 오류 수정\n\nReviewed-by: 검증 결과 확인",
        "fix: 오류 수정\n\nRefs: #15, #123",
        "fix: 오류 수정\r\n\r\n검증 추가\r\n",
    ],
)
def test_valid_messages(message):
    assert checker.check_message(message) == []


@pytest.mark.parametrize(
    "message",
    [
        "fix: 클립보드 복원 조건을 수정했습니다",
        "feat: 기능을 추가합니다",
        "perf: 처리 속도를 개선했다",
        "Fix: 클립보드 복원 조건 수정",
        "fix 클립보드 복원 조건 수정",
        "unknown: 오류 수정",
        "fix(): 오류 수정",
        "fix(two words): 오류 수정",
        "fix: ",
        "",
        "\nfix: 오류 수정",
        "fix: fix clipboard",
        "fix: 한글 added",
        "fix: 기능을 추가합니다 API",
        "fix: 기능을 추가합니다.오류 수정",
        "fix: 기능을 추가합니다!API 응답 처리 개선",
        "fix: 기능을 추가합니까?API 응답 처리 개선",
        "fix: 기능을 추가합니다.API 응답 처리 개선",
        "fix: 오류 수정 `기능을 추가합니다``",
        "fix: 오류 수정\n\nBREAKING CHANGE:\n```\n코드 전용\n```",
        "fix: 오류 수정\n본문 추가",
        "fix: 오류 수정\n\n오류를 수정했습니다",
        "fix: 오류 수정\n\n기능을 추가합니다\n누락 제거",
        "feat: API 개선\n\nBREAKING CHANGE: 구조를 변경합니다\n검증 추가",
        "fix: 오류 수정\n\n조건을 추가합니다. 누락 제거",
        "fix: 오류 수정\n\n- 기능을 추가합니다\n- 문서 추가",
        "feat: API 개선\n\nBREAKING CHANGE: API 구조를 변경합니다",
        "feat: API 개선\n\nBREAKING CHANGE: API 구조를\n변경했습니다",
        "feat: API 개선\n\nBREAKING CHANGE: English description",
        "feat: API 개선\n\nBREAKING CHANGE: ",
        "feat: API 개선\n\nbreaking change: API 구조 변경",
        "feat: API 개선\n\nBreaking-Change: API 구조 변경",
        "fix: 오류 수정\n\nRefs #15",
        "fix: 오류 수정\n\nRefs: 15",
        "fix: 오류 수정\n\nCloses: #0",
        "fix: 오류 수정\n\ncloses: #15",
        "fix: 오류 수정\n\n검증 추가\nRefs: #15",
        "fix: 오류 수정\n\nRefs: #15\n기능을 추가합니다",
        "fix: 오류 수정\n\nReviewed-by: 기능을 추가합니다",
        "fix: 오류 수정\n\nCo-authored-by: 기능을 추가합니다",
        "fix: 오류 수정\n\n```\n닫지 않은 블록",
        "fix: 오류 수정\n\nRefs: #15\n\n```\ncode\n```",
        "Merge branch 'feature' into main",
        'Revert "fix: 오류 수정"\n\nThis reverts commit ' + "a" * 40 + ".",
        "fixup! English subject",
        "fixup! fix: 기능을 추가합니다",
        "squash! fix: 오류 수정\n\n기능을 추가합니다",
        "fixup! fixup! fix: 오류 수정",
        "amend! fix: 오류 수정",
        "fix: 낯선종결",
        "fix: 기능이 좋아요",
    ],
)
def test_invalid_messages(message):
    assert checker.check_message(message)


def test_rules_are_extensible_and_nfc_is_supported(tmp_path):
    rules = checker.load_rules()
    rules["types"].append("release")
    rules["noun_endings"].append("연동")
    path = tmp_path / "rules.json"
    path.write_text(json.dumps(rules), encoding="utf-8")
    message = unicodedata.normalize("NFD", "release: 외부 API 연동")
    assert checker.check_message(message, checker.load_rules(path)) == []


def test_cli_failure_reports_location_and_preserves_file(tmp_path):
    path = tmp_path / "메시지 파일"
    contents = "fix: 오류 수정\n\n기능을 추가합니다\n"
    path.write_text(contents, encoding="utf-8")
    result = subprocess.run(
        [sys.executable, str(SCRIPT), str(path)],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 1
    assert (
        "3행" in result.stderr
        and "차단" in result.stderr
        and "수정 예시" in result.stderr
    )
    assert path.read_text(encoding="utf-8") == contents


@pytest.mark.parametrize(
    "kind", ["missing_message", "invalid_utf8", "broken_rules", "non_object_rules"]
)
def test_cli_input_errors_fail_closed(tmp_path, kind):
    path = tmp_path / "message"
    rules = tmp_path / "rules.json"
    arguments = [sys.executable, str(SCRIPT), str(path)]
    if kind == "invalid_utf8":
        path.write_bytes(b"\xff")
    elif kind in ("broken_rules", "non_object_rules"):
        path.write_text("fix: 오류 수정", encoding="utf-8")
        rules.write_text(
            '{"types": []}' if kind == "broken_rules" else "[]", encoding="utf-8"
        )
        arguments += ["--rules", str(rules)]
    result = subprocess.run(arguments, capture_output=True, text=True, check=False)
    assert result.returncode == 2 and "검사 실패" in result.stderr
    assert "Traceback" not in result.stderr


def git(repo, *arguments, **kwargs):
    return subprocess.run(
        ["git", "-C", str(repo), *arguments],
        capture_output=True,
        text=True,
        check=False,
        **kwargs,
    )


def install(repo, *arguments, cwd=None):
    return subprocess.run(
        ["bash", str(repo / "scripts/install_git_hooks.sh"), *arguments],
        cwd=cwd,
        capture_output=True,
        text=True,
        check=False,
    )


@pytest.fixture
def repository(tmp_path, monkeypatch):
    for name in list(os.environ):
        if name.startswith("GIT_"):
            monkeypatch.delenv(name)
    monkeypatch.setenv("GIT_CONFIG_GLOBAL", os.devnull)
    monkeypatch.setenv("GIT_CONFIG_NOSYSTEM", "1")
    monkeypatch.setenv("COMMIT_MESSAGE_PYTHON", sys.executable)
    repo = tmp_path / "공백 있는 저장소"
    repo.mkdir()
    assert git(repo, "init", "-b", "main").returncode == 0
    git(repo, "config", "user.email", "test@example.com")
    git(repo, "config", "user.name", "검증")
    shutil.copytree(
        ROOT / "scripts", repo / "scripts", ignore=shutil.ignore_patterns("__pycache__")
    )
    shutil.copytree(ROOT / ".githooks", repo / ".githooks")
    result = install(repo, cwd=tmp_path)
    assert result.returncode == 0, result.stderr
    return repo


def test_real_git_commits_are_accepted_or_blocked(repository):
    repo = repository
    assert git(repo, "commit", "--allow-empty", "-m", "fix: 오류 수정").returncode == 0
    before = git(repo, "rev-parse", "HEAD").stdout
    for message in (
        "fix: 기능을 추가합니다",
        "fix: 오류 수정\n\n기능을 추가합니다",
        "feat: API 개선\n\nBREAKING CHANGE: 구조를 변경합니다",
    ):
        result = git(repo, "commit", "--allow-empty", "-m", message)
        assert result.returncode != 0 and "차단" in result.stderr
        assert git(repo, "rev-parse", "HEAD").stdout == before
    assert git(repo, "commit", "--allow-empty", "--fixup", "HEAD").returncode == 0
    assert (
        git(
            repo, "commit", "--allow-empty", "--squash", "HEAD~1", "-m", "검증 추가"
        ).returncode
        == 0
    )


def test_literal_comment_prose_is_checked_for_m_commits(repository):
    result = git(
        repository,
        "commit",
        "--allow-empty",
        "-m",
        "fix: 오류 수정\n\n# 기능을 추가합니다",
    )
    assert result.returncode != 0 and "차단" in result.stderr


@pytest.mark.parametrize("verbose", [False, True])
def test_git_editor_comments_follow_custom_comment_character(
    repository, tmp_path, verbose
):
    editor = tmp_path / "editor.py"
    editor.write_text(
        "import sys\nfrom pathlib import Path\n"
        "p = Path(sys.argv[1])\n"
        "p.write_text('fix: 오류 수정\\n' + p.read_text(), encoding='utf-8')\n",
        encoding="utf-8",
    )
    git(repository, "config", "core.commentChar", ";")
    env = dict(os.environ, GIT_EDITOR=f'{sys.executable} "{editor}"')
    arguments = ["commit", "--allow-empty"]
    if verbose:
        (repository / "sample.txt").write_text(
            "English file content\n", encoding="utf-8"
        )
        git(repository, "add", "sample.txt")
        arguments.append("--verbose")
    result = git(repository, *arguments, env=env)
    assert result.returncode == 0, result.stderr
    assert (
        git(repository, "log", "-1", "--format=%B").stdout.strip() == "fix: 오류 수정"
    )


def test_automatic_merge_requires_korean_title(repository):
    repo = repository
    assert (
        git(repo, "commit", "--allow-empty", "-m", "chore: 초기 설정").returncode == 0
    )
    git(repo, "switch", "-c", "feature")
    assert git(repo, "commit", "--allow-empty", "-m", "feat: 기능 추가").returncode == 0
    git(repo, "switch", "main")
    assert git(repo, "commit", "--allow-empty", "-m", "fix: 오류 수정").returncode == 0
    result = git(repo, "merge", "--no-edit", "feature")
    assert result.returncode != 0 and "제목 형식" in result.stderr
    assert git(repo, "commit", "-m", "chore: 기능 브랜치 통합").returncode == 0


def test_revert_no_commit_then_normal_commit_is_checked(repository):
    repo = repository
    tracked = repo / "sample.txt"
    tracked.write_text("before\n", encoding="utf-8")
    git(repo, "add", "sample.txt")
    assert git(repo, "commit", "-m", "chore: 초기 설정").returncode == 0
    tracked.write_text("after\n", encoding="utf-8")
    git(repo, "add", "sample.txt")
    assert git(repo, "commit", "-m", "feat: 기능 추가").returncode == 0
    assert git(repo, "revert", "--no-commit", "HEAD").returncode == 0
    result = git(repo, "commit", "-m", 'Revert "feat: 기능 추가"')
    assert result.returncode != 0 and "제목 형식" in result.stderr
    assert git(repo, "commit", "-m", "revert: 기능 변경 복원").returncode == 0


def test_installation_restores_custom_path_and_protects_changed_config(repository):
    repo = repository
    assert install(repo, "--uninstall").returncode == 0
    git(repo, "config", "core.hooksPath", "custom hooks")
    assert install(repo).returncode != 0
    assert (
        git(repo, "config", "--get", "core.hooksPath").stdout.strip() == "custom hooks"
    )
    assert install(repo, "--replace").returncode == 0
    assert install(repo).returncode == 0
    assert install(repo, "--uninstall").returncode == 0
    assert (
        git(repo, "config", "--get", "core.hooksPath").stdout.strip() == "custom hooks"
    )
    assert install(repo, "--replace").returncode == 0
    git(repo, "config", "core.hooksPath", "new hooks")
    assert install(repo, "--uninstall").returncode != 0
    assert git(repo, "config", "--get", "core.hooksPath").stdout.strip() == "new hooks"


def test_linked_worktree_uses_own_checkout_hook(repository, tmp_path):
    repo = repository
    git(repo, "add", "scripts", ".githooks")
    assert git(repo, "commit", "-m", "chore: 개발 훅 추가").returncode == 0
    linked = tmp_path / "연결된 worktree"
    assert git(repo, "worktree", "add", "-b", "linked", str(linked)).returncode == 0
    assert (
        git(linked, "commit", "--allow-empty", "-m", "fix: 오류 수정").returncode == 0
    )
    assert (
        git(
            linked, "commit", "--allow-empty", "-m", "fix: 기능을 추가합니다"
        ).returncode
        != 0
    )
    rules = linked / "scripts/commit_message_rules.json"
    changed = json.loads(rules.read_text(encoding="utf-8"))
    changed["types"].append("release")
    rules.write_text(json.dumps(changed), encoding="utf-8")
    assert (
        git(linked, "commit", "--allow-empty", "-m", "release: 버전 변경").returncode
        == 0
    )
    assert (
        git(repo, "commit", "--allow-empty", "-m", "release: 버전 변경").returncode != 0
    )


def test_worktree_only_install_requires_explicit_config(repository, tmp_path):
    repo = repository
    assert install(repo, "--uninstall").returncode == 0
    assert install(repo, "--worktree").returncode != 0
    git(repo, "add", "scripts", ".githooks")
    assert git(repo, "commit", "-m", "chore: 개발 훅 추가").returncode == 0
    linked = tmp_path / "linked"
    assert git(repo, "worktree", "add", "-b", "linked", str(linked)).returncode == 0
    git(repo, "config", "extensions.worktreeConfig", "true")
    assert install(linked, "--worktree").returncode == 0
    assert (
        git(
            linked, "commit", "--allow-empty", "-m", "fix: 기능을 추가합니다"
        ).returncode
        != 0
    )
    assert git(repo, "config", "--get", "core.hooksPath").returncode == 1
    assert install(linked, "--worktree", "--uninstall").returncode == 0


@pytest.mark.parametrize(
    ("cleanup", "editing", "accepted"),
    [
        ("strip", False, True),
        ("default", False, False),
        ("default", True, True),
        ("whitespace", True, False),
        ("verbatim", True, False),
    ],
)
def test_git_cleanup_config(repository, monkeypatch, cleanup, editing, accepted):
    monkeypatch.chdir(repository)
    monkeypatch.setenv("GIT_EDITOR", "editor" if editing else ":")
    git(repository, "config", "commit.cleanup", cleanup)
    raw = "fix: 오류 수정\n\n# 기능을 추가합니다\n"
    result = checker.check_message(checker.git_editor_message(raw))
    assert (not result) == accepted


def test_scissors_cleanup_preserves_prose_before_cut(repository, monkeypatch):
    monkeypatch.chdir(repository)
    monkeypatch.setenv("GIT_EDITOR", "editor")
    git(repository, "config", "commit.cleanup", "scissors")
    raw = "fix: 오류 수정\n\n# ------------------------ >8 ------------------------\ndiff --git a/file b/file"
    assert checker.check_message(checker.git_editor_message(raw)) == []
    bad = raw.replace("오류 수정", "기능을 추가합니다")
    assert checker.check_message(checker.git_editor_message(bad))


def test_revert_hook_invocation_is_not_assumed(repository):
    repo = repository
    tracked = repo / "sample.txt"
    tracked.write_text("before\n", encoding="utf-8")
    git(repo, "add", "sample.txt")
    assert git(repo, "commit", "-m", "chore: 초기 설정").returncode == 0
    tracked.write_text("after\n", encoding="utf-8")
    git(repo, "add", "sample.txt")
    assert git(repo, "commit", "-m", "feat: 기능 추가").returncode == 0
    result = git(repo, "revert", "--no-edit", "HEAD")
    if result.returncode == 0:
        # Git sequencer가 훅을 생략하는 버전에서도 메시지 자체의 예외는 없음.
        assert checker.check_message(git(repo, "log", "-1", "--format=%B").stdout)
    else:
        assert "제목 형식" in result.stderr


@pytest.mark.parametrize("cleanup", ["default", "strip", "whitespace", "verbatim"])
def test_scissors_marker_cannot_hide_preserved_prose(repository, monkeypatch, cleanup):
    monkeypatch.chdir(repository)
    monkeypatch.setenv("GIT_EDITOR", "editor")
    git(repository, "config", "commit.cleanup", cleanup)
    raw = "fix: 오류 수정\n\n# ------------------------ >8 ------------------------\n기능을 추가합니다"
    assert checker.check_message(checker.git_editor_message(raw))


def test_diff_marker_cannot_hide_prose_after_diff(repository, monkeypatch):
    monkeypatch.chdir(repository)
    monkeypatch.setenv("GIT_EDITOR", "editor")
    raw = "fix: 오류 수정\n\n# ------------------------ >8 ------------------------\ndiff --git a/file b/file\n기능을 추가합니다"
    assert checker.check_message(checker.git_editor_message(raw))

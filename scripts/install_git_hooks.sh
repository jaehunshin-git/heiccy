#!/bin/sh
# 호출한 cwd 대신 이 설치 파일이 속한 체크아웃을 기준으로 설정한다.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
python=${COMMIT_MESSAGE_PYTHON:-python3}
if ! command -v "$python" >/dev/null 2>&1; then
    printf '%s\n' '오류: Python을 찾을 수 없습니다. COMMIT_MESSAGE_PYTHON에 Python 3.11 이상 실행 파일을 지정하세요.' >&2
    exit 2
fi
exec "$python" - "$script_dir" "$@" <<'PYTHON'
import json
import os
from pathlib import Path
import subprocess
import sys

if sys.version_info < (3, 11):
    print("오류: Python 3.11 이상이 필요합니다.", file=sys.stderr)
    sys.exit(2)

HELP = """사용법: scripts/install_git_hooks.sh [--replace] [--worktree]
        scripts/install_git_hooks.sh --uninstall [--worktree]

기본 설치는 저장소 로컬 core.hooksPath를 .githooks로 설정합니다.
linked worktree들은 이 설정을 공유하며 각 체크아웃의 훅을 사용합니다.
  --replace    기존 사용자 지정 hooksPath를 교체하고 이전 로컬 값을 보관
  --uninstall  설치 상태를 검증하고 이전 로컬 값을 복원
  --worktree   현재 worktree 설정만 변경 (worktreeConfig가 이미 활성화되어야 함)
  -h, --help   도움말 표시
COMMIT_MESSAGE_PYTHON으로 Python 3.11 이상 실행 파일을 선택할 수 있습니다.
"""


def fail(message):
    raise RuntimeError(message)


def main():
    script_dir = Path(sys.argv[1])
    args = sys.argv[2:]
    if "--help" in args or "-h" in args:
        print(HELP, end="")
        return
    allowed = {"--replace", "--uninstall", "--worktree"}
    if any(arg not in allowed for arg in args) or len(set(args)) != len(args):
        fail("알 수 없거나 중복된 옵션입니다. --help를 확인하세요.")
    uninstall = "--uninstall" in args
    if uninstall and "--replace" in args:
        fail("--uninstall과 --replace는 함께 사용할 수 없습니다.")

    def git(*arguments, optional=False):
        result = subprocess.run(
            ["git", "-C", str(script_dir), *arguments],
            capture_output=True, text=True,
        )
        if result.returncode and not (optional and result.returncode == 1):
            fail("Git 명령을 실행할 수 없습니다: " + result.stderr.strip())
        return result.stdout.rstrip("\n")

    root = Path(git("rev-parse", "--show-toplevel")).resolve()
    if root != script_dir.parent.resolve():
        fail("설치 파일은 저장소 루트의 scripts 디렉터리에 있어야 합니다.")
    scope = "--worktree" if "--worktree" in args else "--local"
    if scope == "--worktree":
        enabled = git("config", "--type=bool", "--get", "extensions.worktreeConfig", optional=True)
        if enabled != "true":
            fail("--worktree는 extensions.worktreeConfig가 활성화된 저장소에서만 사용할 수 있습니다.")

    def values(key):
        # NUL 구분자로 공백이나 줄바꿈이 있는 기존 경로도 그대로 보존한다.
        result = subprocess.run(
            ["git", "-C", str(root), "config", scope, "--no-includes", "--null", "--get-all", key],
            capture_output=True, text=True,
        )
        if result.returncode == 1:
            return []
        if result.returncode:
            fail("Git 설정을 읽을 수 없습니다: " + result.stderr.strip())
        return result.stdout[:-1].split("\0")

    def write_values(key, entries):
        result = subprocess.run(
            ["git", "-C", str(root), "config", scope, "--unset-all", key],
            capture_output=True, text=True,
        )
        if result.returncode not in (0, 5):
            fail("Git 설정을 해제할 수 없습니다: " + result.stderr.strip())
        for value in entries:
            git("config", scope, "--add", key, value)

    path_key = "core.hooksPath"
    state_key = "commitMessageHooks.installState"
    old_paths, old_states = values(path_key), values(state_key)
    effective = git("config", "--show-scope", "--get", path_key, optional=True)
    effective_scope, separator, effective_path = effective.partition("\t")
    if effective_scope == "command" or (scope == "--local" and effective_scope == "worktree"):
        fail("더 높은 우선순위의 hooksPath 설정이 있습니다. 해당 설정을 먼저 확인하세요. worktree 설정에는 --worktree를 사용하세요.")
    if not separator:
        effective_path = None

    state = None
    if old_states:
        try:
            if len(old_states) != 1:
                raise ValueError
            state = json.loads(old_states[0])
            if (not isinstance(state, dict) or set(state) != {"version", "target", "previous"}
                    or state["version"] != 1 or state["target"] != ".githooks"
                    or not isinstance(state["previous"], list)
                    or not all(isinstance(value, str) and "\0" not in value for value in state["previous"])):
                raise ValueError
        except (ValueError, TypeError):
            fail("보관된 설치 상태가 올바르지 않습니다. 설정을 변경하지 않았습니다.")
        if old_paths != [".githooks"] or effective_path != ".githooks":
            fail("설치 이후 hooksPath가 변경되었습니다. 자동 변경 또는 복원을 중단합니다.")

    if uninstall:
        if state is None:
            fail("이 설치기로 설치한 기록이 없습니다. hooksPath를 해제하지 않았습니다.")
        new_paths, new_states = state["previous"], []
    else:
        hook = root / ".githooks" / "commit-msg"
        checker = root / "scripts" / "check_commit_message.py"
        if not hook.is_file() or not checker.is_file():
            fail(".githooks/commit-msg와 scripts/check_commit_message.py가 모두 필요합니다.")
        if state is None and "--replace" not in args:
            if any(value != ".githooks" for value in old_paths) or effective_path not in (None, ".githooks"):
                fail("기존 사용자 지정 hooksPath가 있습니다. 교체하려면 --replace를 지정하세요.")
        hook.chmod(hook.stat().st_mode | 0o111)
        if state is not None:
            print("이미 설치되어 있습니다: .githooks (" + scope + ")")
            return
        new_paths = [".githooks"]
        new_states = [json.dumps({"version": 1, "target": ".githooks", "previous": old_paths})]

    try:
        write_values(path_key, new_paths)
        write_values(state_key, new_states)
        if values(path_key) != new_paths or values(state_key) != new_states:
            fail("변경한 설정을 확인할 수 없습니다.")
        if not uninstall and git("config", "--get", path_key, optional=True) != ".githooks":
            fail("설치 경로보다 우선하는 설정이 있어 훅을 활성화할 수 없습니다.")
    except RuntimeError:
        write_values(path_key, old_paths)
        write_values(state_key, old_states)
        raise
    if uninstall:
        print("훅 설치를 해제하고 이전 설정을 복원했습니다 (" + scope + ").")
    else:
        print("커밋 메시지 훅을 설치했습니다: .githooks (" + scope + ")")
    if scope == "--local":
        print("이 로컬 설정은 저장소의 모든 linked worktree에 공통으로 적용됩니다.")


try:
    main()
except (RuntimeError, OSError) as error:
    print("오류: " + str(error), file=sys.stderr)
    sys.exit(2)
PYTHON

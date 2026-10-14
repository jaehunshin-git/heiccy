"""제출 형식, 편집 재검증, 상태 갱신과 생성 전 실패 중단을 검증한다."""

import copy
import importlib
import json
import re
import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace
from urllib.error import HTTPError

import pytest

ROOT = Path(__file__).resolve().parents[1]
if not (ROOT / "scripts/check_submission.py").is_file():
    pytest.skip(
        "sdist에는 제출 검사 도구를 포함하지 않습니다.", allow_module_level=True
    )
sys.path.insert(0, str(ROOT / "scripts"))
checker = importlib.import_module("check_submission")
metadata = importlib.import_module("validate_github_metadata")
creator = importlib.import_module("create_submission")

PR_BODY = """## 📌 Summary
단일 저장소에서 개발과 배포를 관리하도록 운영 절차를 변경한다.
Closes #1

## 📄 Tasks
- [x] CI와 제출 형식 검증 추가

## 🔍 To Reviewer
외부 PR의 코드가 권한 있는 작업에서 실행되지 않는지 검토한다.

## ✅ Validation
Python 회귀 테스트와 정적 검사를 로컬 macOS에서 통과했다.

## ⚠️ Unverified
heiccy Actions 실기는 push와 PR 생성 승인 이후 검증한다.
"""
ISSUE_BODY = """### 📄 Description
단일 저장소에서 개발 원본과 빌드 출처를 관리한다.
### ✅ Tasks
- [ ] macOS 두 OS 검증을 이전한다.
### 🎯 완료 기준
- [ ] 정상·실패 본문 및 편집 후 재검증을 통과한다.
### 🧪 검증 계획
로컬 회귀 테스트와 원격 Actions 실행으로 확인한다.
### 📎 제약 및 참고
커밋과 push는 검증 결과를 보고하고 승인 후 진행한다.
"""
PR_TITLE = "chore: 단일 저장소 운영 전환"
ISSUE_TITLE = "[작업] 단일 저장소 운영 전환"
SHA = "a" * 40
DEVELOPMENT_TEMPLATES = ["feature", "fix", "docs", "init", "refactor"]
DEVELOPMENT_BODY = """### 📄 Description
개발 환경과 검증 절차를 저장소 안에서 관리하도록 개선한다.
### ✅ Tasks
- [ ] 필요한 코드와 문서를 정리하고 회귀 검사를 실행한다.
### 📎 ETC
_No response_
"""


def test_valid_pr_and_issue():
    assert checker.check_submission("pr", PR_TITLE, PR_BODY) == []
    assert (
        checker.check_submission(
            "issue", ISSUE_TITLE, ISSUE_BODY, labels=["enhancement"]
        )
        == []
    )


@pytest.mark.parametrize(
    "mutation",
    [
        lambda b: b.replace("## ✅ Validation", "## 다른 내용"),
        lambda b: b.replace(
            "Python 회귀 테스트와 정적 검사를 로컬 macOS에서 통과했다.", ""
        ),
        lambda b: b.replace(
            "Python 회귀 테스트와 정적 검사를 로컬 macOS에서 통과했다.", "TODO"
        ),
        lambda b: b.replace(
            "Python 회귀 테스트와 정적 검사를 로컬 macOS에서 통과했다.",
            "TODO: 검증 결과 추가",
        ),
        lambda b: b.replace("CI와 제출 형식 검증 추가", "수행한 작업을 작성하세요."),
        lambda b: b.replace("Closes #1", "Closes #"),
        lambda b: b.replace("Closes #1", "Closes #이슈번호"),
        lambda b: b.replace("Closes #1", "Closes #0"),
        lambda b: b.replace("Closes #1", "Closes other/repo#1"),
        lambda b: b.replace("Closes #1", "```\nCloses #1\n```"),
        lambda b: b.replace("Closes #1", "<!-- Closes #1 -->"),
        lambda b: b + "\n## 📄 Tasks\n- [x] 중복 작업 본문 추가\n",
        lambda b: b.replace("## 📌 Summary", "<!--\n## 📌 Summary").replace(
            "## 📄 Tasks", "-->\n## 📄 Tasks"
        ),
        lambda b: b.replace(
            "Python 회귀 테스트와 정적 검사를 로컬 macOS에서 통과했다.",
            "해당 없음: 아직 작업 시작 전이라 검증할 내용이 없다.",
        ),
    ],
)
def test_invalid_pr_fails(mutation):
    assert checker.check_submission("pr", PR_TITLE, mutation(PR_BODY))


@pytest.mark.parametrize(
    "title", ["", "전환", "chore: TODO", "chore: ", PR_TITLE + "\n추가"]
)
def test_invalid_title_fails(title):
    assert checker.check_submission("pr", title, PR_BODY)


def test_unverified_not_applicable_requires_reason():
    body = PR_BODY.replace(
        "heiccy Actions 실기는 push와 PR 생성 승인 이후 검증한다.",
        "해당 없음: 변경 범위를 로컬과 원격 환경에서 모두 검증했다.",
    )
    assert checker.check_submission("pr", PR_TITLE, body) == []
    assert checker.check_submission(
        "pr",
        PR_TITLE,
        body.replace(
            "해당 없음: 변경 범위를 로컬과 원격 환경에서 모두 검증했다.", "해당 없음"
        ),
    )


def test_public_issue_forms_are_supported():
    bug = "### 사용 구성 요소\nmacOS 앱\n### 실행 환경\nmacOS 26 arm64 앱 1.0.0\n### 재현 방법\nHEIC를 복사한 뒤 변환 완료 이전에 붙여넣으면 원본이 붙는다.\n### 추가 정보\n_No response_"
    feature = "### 해결하고 싶은 문제\n여러 파일을 변환할 때 진행 상황을 확인하기 어렵다.\n### 제안하는 동작\n전체 파일 개수와 현재 완료된 파일 수를 표시한다.\n### 현재 사용하는 대안\n_No response_"
    assert (
        checker.check_submission("issue", "[버그] 패널 표시 문제", bug, labels=["bug"])
        == []
    )
    assert (
        checker.check_submission(
            "issue", "[제안] 진행 개수 표시", feature, labels=["enhancement"]
        )
        == []
    )
    assert checker.check_submission("issue", "[버그] 패널 표시 문제", bug, labels=[])


@pytest.mark.parametrize(
    "reason,valid",
    [
        ("해당 없음", False),
        ("해당 없음: 별도로 사용하는 대안이 없어 현재 수동으로 변환한다.", True),
    ],
)
def test_optional_not_applicable_needs_reason(reason, valid):
    body = (
        "### 해결하고 싶은 문제\nHEIC 변환 진행 상황을 확인하기 어렵다.\n### 제안하는 동작\n전체 개수와 완료된 개수를 표시한다.\n### 현재 사용하는 대안\n"
        + reason
    )
    errors = checker.check_submission(
        "issue", "[제안] 진행 개수 표시", body, labels=["enhancement"]
    )
    assert bool(errors) is not valid


def test_body_is_data_and_placeholder_discussion_is_allowed(tmp_path):
    marker = tmp_path / "executed"
    body = PR_BODY.replace(
        "외부 PR의 코드", f"$(touch {marker}) `rm -rf /` 외부 PR의 코드"
    )
    body += "\nplaceholder 잔존 본문이 실패하는지 확인했다.\n"
    assert checker.check_submission("pr", PR_TITLE, body) == []
    assert not marker.exists()


class FakeGitHub:
    def __init__(self, snapshots, *, issues=None):
        self.snapshots = snapshots
        self.issues = issues or {1: {"title": "전환 이슈"}}
        self.calls = []
        self.statuses = []
        self.gets = 0

    def api(self, method, path, data=None):
        self.calls.append((method, path, data))
        if method == "GET" and path == "pulls/2":
            index = min(self.gets, len(self.snapshots) - 1)
            self.gets += 1
            return copy.deepcopy(self.snapshots[index])
        if method == "GET" and path == "issues/1":
            if self.snapshots and "head" not in self.snapshots[0]:
                index = min(self.gets, len(self.snapshots) - 1)
                self.gets += 1
                return copy.deepcopy(self.snapshots[index])
            if 1 not in self.issues:
                raise HTTPError("https://api.github.com", 404, "not found", {}, None)
            return copy.deepcopy(self.issues[1])
        return None

    def status(self, sha, state, description):
        self.statuses.append((sha, state, description))


def pr(body=PR_BODY):
    return {
        "title": PR_TITLE,
        "body": body,
        "head": {"sha": SHA},
        "base": {"ref": "main"},
        "labels": [],
        "state": "open",
    }


def test_pr_edit_overwrites_success_with_failure():
    client = FakeGitHub([pr()])
    assert metadata.validate_pr(client, 2) == []
    assert [s[1] for s in client.statuses] == ["pending", "success"]
    client.snapshots = [pr(PR_BODY.replace("Closes #1", ""))]
    client.gets = 0
    assert metadata.validate_pr(client, 2)
    assert [s[1] for s in client.statuses] == [
        "pending",
        "success",
        "pending",
        "failure",
    ]
    assert {s[0] for s in client.statuses} == {SHA}


@pytest.mark.parametrize("after_publish", [False, True])
@pytest.mark.parametrize("change_head", [False, True])
def test_stale_success_is_not_kept(after_publish, change_head):
    changed = pr(PR_BODY.replace("Closes #1", ""))
    if change_head:
        changed["head"]["sha"] = "b" * 40
    client = FakeGitHub([pr(), pr(), changed] if after_publish else [pr(), changed])
    assert metadata.validate_pr(client, 2)
    assert client.statuses[-1][1] == "pending"
    assert client.statuses[-1][0] == changed["head"]["sha"]
    if not after_publish:
        assert all(s[1] != "success" for s in client.statuses)


def test_non_issue_link_and_api_failure_never_pass():
    client = FakeGitHub([pr()], issues={1: {"pull_request": {}}})
    assert metadata.validate_pr(client, 2)
    assert client.statuses[-1][1] == "failure"
    client = FakeGitHub([pr()])
    original = client.api

    def broken(method, path, data=None):
        if path == "issues/1":
            raise HTTPError("https://api.github.com", 500, "server error", {}, None)
        return original(method, path, data)

    client.api = broken
    with pytest.raises(HTTPError):
        metadata.validate_pr(client, 2)
    assert client.statuses[-1][1] == "error"


def test_issue_edit_adds_and_removes_only_invalid_label():
    invalid = {
        "title": ISSUE_TITLE,
        "body": "빈 본문",
        "labels": [{"name": "enhancement"}],
    }
    client = FakeGitHub([invalid])
    assert metadata.validate_issue(client, 1)
    assert client.calls[-1] == (
        "POST",
        "issues/1/labels",
        {"labels": ["invalid-format"]},
    )
    corrected = {
        "title": ISSUE_TITLE,
        "body": ISSUE_BODY,
        "labels": [{"name": "enhancement"}, {"name": "invalid-format"}],
    }
    client.snapshots, client.gets = [corrected], 0
    assert metadata.validate_issue(client, 1) == []
    assert client.calls[-1] == ("DELETE", "issues/1/labels/invalid-format", None)
    # 자동 라벨 이벤트에서는 두 번째 수정 요청을 만들어 루프를 만들지 않는다.
    corrected["labels"] = [{"name": "enhancement"}]
    client.snapshots, client.gets, client.calls = [corrected], 0, []
    assert metadata.validate_issue(client, 1) == []
    assert all(method == "GET" for method, _, _ in client.calls)


def test_local_validation_failure_never_calls_gh(tmp_path):
    path = tmp_path / "body.md"
    path.write_text("빈 본문")
    args = SimpleNamespace(
        kind="issue", title=ISSUE_TITLE, body_file=path, template="task", label=None
    )
    calls = []
    with pytest.raises(ValueError):
        creator.create(args, run=lambda *a, **k: calls.append(a))
    assert calls == []


def test_creator_reads_back_actual_submission(tmp_path):
    path = tmp_path / "body.md"
    path.write_text(ISSUE_BODY)
    args = SimpleNamespace(
        kind="issue", title=ISSUE_TITLE, body_file=path, template="task", label=None
    )
    calls = []

    def run(command, **kwargs):
        calls.append(command)
        if command[1:3] == ["repo", "view"]:
            data = {"nameWithOwner": "jaehunshin-git/heiccy"}
        elif command[1:3] == ["issue", "view"]:
            data = {
                "title": ISSUE_TITLE,
                "body": ISSUE_BODY,
                "labels": [{"name": "enhancement"}],
            }
        else:
            return subprocess.CompletedProcess(
                command, 0, stdout="https://github.com/jaehunshin-git/heiccy/issues/1\n"
            )
        return subprocess.CompletedProcess(command, 0, stdout=json.dumps(data))

    assert creator.create(args, run=run).endswith("/issues/1")
    assert [c[1:3] for c in calls] == [
        ["repo", "view"],
        ["issue", "create"],
        ["issue", "view"],
    ]


def test_workflow_only_trusted_code_and_no_secrets():
    workflow = (ROOT / ".github/workflows/submission.yml").read_text()
    for event in ["opened", "reopened", "edited", "synchronize"]:
        assert event in workflow
    assert "ref: ${{ github.event.pull_request.base.sha }}" in workflow
    assert "persist-credentials: false" in workflow
    assert "head.sha" not in workflow and "secrets." not in workflow
    assert "cancel-in-progress: false" in workflow
    assert "name: PR 메타데이터 처리" in workflow
    assert f"name: {metadata.CONTEXT}\n" not in workflow


def test_rule_and_form_contracts():
    for rule in checker.RULES["issues"].values():
        form = (ROOT / rule["template"]).read_text()
        title = re.search(r"(?m)^title: ([\"'])(.*?)\1$", form)
        assert title is not None and title[2] == rule["title_prefix"]
        for heading in rule["required"]:
            chunk = form.split(f"label: {heading}\n", 1)[1].split("  - type:", 1)[0]
            assert "required: true" in chunk
        assert all(
            label in form.split("labels:", 1)[1].splitlines()[0]
            for label in rule["labels"]
        )
    assert (
        "blank_issues_enabled: false"
        in (ROOT / ".github/ISSUE_TEMPLATE/config.yml").read_text()
    )
    assert checker.check_submission(
        "pr", PR_TITLE, (ROOT / checker.RULES["pr"]["template"]).read_text()
    )


@pytest.mark.parametrize("template", DEVELOPMENT_TEMPLATES)
def test_imported_development_forms_pass_and_select_by_title(template):
    rule = checker.RULES["issues"][template]
    title = rule["title_prefix"] + "단일 저장소 검증 절차 정리"
    assert checker.select_issue_template(title) == template
    assert (
        checker.check_submission(
            "issue", title, DEVELOPMENT_BODY, labels=rule["labels"]
        )
        == []
    )
    assert (
        checker.check_submission(
            "issue", title, DEVELOPMENT_BODY, template=template, labels=rule["labels"]
        )
        == []
    )


@pytest.mark.parametrize("template", DEVELOPMENT_TEMPLATES)
@pytest.mark.parametrize("mutation", ["missing", "placeholder", "labels", "title"])
def test_imported_form_invalid_inputs_fail(template, mutation):
    rule = checker.RULES["issues"][template]
    title = rule["title_prefix"] + "단일 저장소 검증 절차 정리"
    body, labels = DEVELOPMENT_BODY, rule["labels"]
    if mutation == "missing":
        body = body.replace("### 📄 Description", "### 다른 내용")
    elif mutation == "placeholder":
        source = (ROOT / rule["template"]).read_text()
        original = checker.template_placeholders(source)[0]
        body = body.replace(
            "개발 환경과 검증 절차를 저장소 안에서 관리하도록 개선한다.", original
        )
    elif mutation == "labels":
        labels = ["enhancement"]
    else:
        title = "[다른 형식] 단일 저장소 검증 절차 정리"
    assert checker.check_submission(
        "issue", title, body, template=template, labels=labels
    )


@pytest.mark.parametrize("template", DEVELOPMENT_TEMPLATES)
def test_imported_original_block_and_etc_placeholders_fail(template):
    rule = checker.RULES["issues"][template]
    values = checker.template_placeholders((ROOT / rule["template"]).read_text())
    assert len(values) == 3
    assert values[1].count("- [ ]") == 3
    title = rule["title_prefix"] + "단일 저장소 검증 절차 정리"
    for value in values[1:]:
        body = DEVELOPMENT_BODY.replace("_No response_", value)
        assert checker.check_submission("issue", title, body, labels=rule["labels"])


@pytest.mark.parametrize("template", DEVELOPMENT_TEMPLATES)
def test_creator_assigns_imported_labels_and_reads_back(template, tmp_path):
    rule = checker.RULES["issues"][template]
    title = rule["title_prefix"] + "단일 저장소 검증 절차 정리"
    body_file = tmp_path / "body.md"
    body_file.write_text(DEVELOPMENT_BODY)
    args = SimpleNamespace(
        kind="issue", title=title, body_file=body_file, template=template, label=None
    )
    calls = []

    def run(command, **kwargs):
        calls.append(command)
        if command[1:3] == ["repo", "view"]:
            result = {"nameWithOwner": checker.RULES["repository"]}
        elif command[1:3] == ["issue", "view"]:
            result = {
                "title": title,
                "body": DEVELOPMENT_BODY,
                "labels": [{"name": name} for name in rule["labels"]],
            }
        else:
            return subprocess.CompletedProcess(
                command, 0, stdout="https://github.com/jaehunshin-git/heiccy/issues/2\n"
            )
        return subprocess.CompletedProcess(command, 0, stdout=json.dumps(result))

    assert creator.create(args, run=run).endswith("/issues/2")
    create = calls[1]
    assert create[create.index("--label") + 1] == rule["labels"][0]
    assert calls[2][1:3] == ["issue", "view"]

"""미실행·과거 성공을 strict 필수 검사로 등록하지 않는 계약을 검증한다."""

import copy
import importlib
import sys
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
if not (ROOT / "scripts/configure_main_ruleset.py").is_file():
    pytest.skip(
        "sdist에는 ruleset 설정기를 포함하지 않습니다.", allow_module_level=True
    )
sys.path.insert(0, str(ROOT / "scripts"))
configurator = importlib.import_module("configure_main_ruleset")
NOW = datetime.now(UTC).isoformat()
OLD = (datetime.now(UTC) - timedelta(days=8)).isoformat()


def fixture_data():
    return {
        "pulls/2": {
            "state": "open",
            "base": {"ref": "main"},
            "merge_commit_sha": "a" * 40,
            "head": {"sha": "b" * 40},
        },
        f"commits/{'a' * 40}/check-runs?per_page=100": {
            "check_runs": [
                {
                    "name": name,
                    "id": identifier,
                    "conclusion": "success",
                    "completed_at": NOW,
                    "app": {"slug": "github-actions", "id": 15368},
                }
                for identifier, name in enumerate(
                    sorted(configurator.EXPECTED), start=1
                )
            ]
        },
        f"commits/{'b' * 40}/status?per_page=100": {
            "statuses": [
                {
                    "context": configurator.STATUS,
                    "id": 3,
                    "state": "success",
                    "updated_at": NOW,
                    "creator": {"login": "github-actions[bot]"},
                }
            ]
        },
        "rulesets": [{"name": configurator.NAME, "id": 24993268}],
        "rulesets/24993268": {"rules": []},
    }


def test_live_successful_contexts_required_and_strict_no_bypass():
    data = fixture_data()
    payload, identifier = configurator.prepare(2, api=data.__getitem__)
    assert identifier == 24993268
    assert payload["bypass_actors"] == []
    assert payload["enforcement"] == "active"
    rule = payload["rules"][-1]
    assert rule["type"] == "required_status_checks"
    assert rule["parameters"]["strict_required_status_checks_policy"] is True
    assert {c["context"] for c in rule["parameters"]["required_status_checks"]} == {
        *configurator.EXPECTED,
        configurator.STATUS,
    }
    assert {
        c["integration_id"] for c in rule["parameters"]["required_status_checks"]
    } == {15368}
    pr_rule = next(r for r in payload["rules"] if r["type"] == "pull_request")
    assert pr_rule["parameters"]["required_approving_review_count"] == 0
    for flag in [
        "require_code_owner_review",
        "require_last_push_approval",
        "require_extra_approval_for_unattributed_changes",
    ]:
        assert pr_rule["parameters"][flag] is False


@pytest.mark.parametrize(
    "field,value",
    [
        ("conclusion", "failure"),
        ("conclusion", "skipped"),
        ("completed_at", OLD),
    ],
)
def test_check_requires_recent_success(field, value):
    data = fixture_data()
    data[f"commits/{'a' * 40}/check-runs?per_page=100"]["check_runs"][0][field] = value
    with pytest.raises(ValueError):
        configurator.prepare(2, api=data.__getitem__)


def test_no_checks_cannot_register_guessed_names():
    data = fixture_data()
    data[f"commits/{'a' * 40}/check-runs?per_page=100"]["check_runs"] = []
    with pytest.raises(ValueError, match="실행되지 않은 검사"):
        configurator.prepare(2, api=data.__getitem__)


def test_first_pr_can_require_actual_ci_before_metadata_exists():
    data = fixture_data()
    del data[f"commits/{'b' * 40}/status?per_page=100"]
    payload, _ = configurator.prepare(2, api=data.__getitem__, ci_only=True)
    checks = payload["rules"][-1]["parameters"]["required_status_checks"]
    assert {check["context"] for check in checks} == configurator.EXPECTED
    assert payload["rules"][-1]["parameters"]["strict_required_status_checks_policy"]


def test_ci_only_cannot_remove_metadata_requirement():
    data = fixture_data()
    data["rulesets/24993268"]["rules"] = [
        {
            "type": "required_status_checks",
            "parameters": {
                "required_status_checks": [{"context": configurator.STATUS}],
            },
        }
    ]
    with pytest.raises(ValueError, match="기존 필수 검사"):
        configurator.prepare(2, api=data.__getitem__, ci_only=True)


@pytest.mark.parametrize("which", ["check", "status"])
def test_latest_failure_overrides_old_success(which):
    data = fixture_data()
    if which == "check":
        items = data[f"commits/{'a' * 40}/check-runs?per_page=100"]["check_runs"]
        newer = copy.deepcopy(items[0])
        newer.update(id=100, conclusion="failure")
    else:
        items = data[f"commits/{'b' * 40}/status?per_page=100"]["statuses"]
        newer = copy.deepcopy(items[0])
        newer.update(id=100, state="pending")
    items.append(newer)
    with pytest.raises(ValueError):
        configurator.prepare(2, api=data.__getitem__)


@pytest.mark.parametrize(
    "change",
    [
        lambda d: d[f"commits/{'b' * 40}/status?per_page=100"].update(statuses=[]),
        lambda d: d[f"commits/{'b' * 40}/status?per_page=100"]["statuses"][0].update(
            updated_at=OLD
        ),
        lambda d: d[f"commits/{'b' * 40}/status?per_page=100"]["statuses"][0].update(
            creator={"login": "other-bot"}
        ),
        lambda d: d[f"commits/{'a' * 40}/check-runs?per_page=100"]["check_runs"][
            0
        ].update(app={"slug": "other-app", "id": 7}),
        lambda d: d["pulls/2"]["base"].update(ref="other"),
    ],
)
def test_untrusted_or_missing_current_results_cannot_apply(change):
    data = fixture_data()
    change(data)
    with pytest.raises(ValueError):
        configurator.prepare(2, api=data.__getitem__)

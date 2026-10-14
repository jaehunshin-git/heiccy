"""실제 성공한 PR 검사를 확인해 strict main ruleset을 준비·적용한다."""

from __future__ import annotations

import argparse
import json
import subprocess
from datetime import UTC, datetime, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "jaehunshin-git/heiccy"
NAME = "main 단일 저장소 운영"
EXPECTED = {"Apple Silicon macos-15", "Apple Silicon macos-26"}
STATUS = "PR 형식 검증"


def gh_api(path: str, *, method: str = "GET", payload=None):
    command = ["gh", "api", f"repos/{REPOSITORY}/{path}", "--method", method]
    if payload is not None:
        command.extend(["--input", "-"])
    result = subprocess.run(
        command,
        input=None if payload is None else json.dumps(payload),
        text=True,
        capture_output=True,
        check=True,
    )
    return json.loads(result.stdout)


def recent(value: str) -> bool:
    return datetime.fromisoformat(value) > datetime.now(UTC) - timedelta(days=7)


def prepare(
    pr_number: int, api=gh_api, *, ci_only: bool = False
) -> tuple[dict, int | None]:
    pr = api(f"pulls/{pr_number}")
    if pr["base"]["ref"] != "main" or pr["state"] != "open":
        raise ValueError("열린 main 대상 PR이 필요합니다.")
    sha = pr.get("merge_commit_sha")
    if not sha:
        raise ValueError("실제 PR merge commit과 실행된 macOS 검사가 필요합니다.")
    checks = api(f"commits/{sha}/check-runs?per_page=100")["check_runs"]
    contexts = []
    # 최신 check만 선택하며 예전 성공 뒤의 최신 실패를 통과로 사용하지 않는다.
    for name in sorted(EXPECTED):
        matches = sorted(
            (check for check in checks if check["name"] == name),
            key=lambda check: check["id"],
            reverse=True,
        )
        if not matches:
            raise ValueError(f"실행되지 않은 검사: {name}")
        check = matches[0]
        if check["conclusion"] != "success" or not recent(check["completed_at"]):
            raise ValueError(f"최근 성공한 검사가 필요합니다: {name}")
        if check["app"]["slug"] != "github-actions":
            raise ValueError("필수 CI의 출처가 GitHub Actions가 아닙니다.")
        contexts.append(
            {"context": check["name"], "integration_id": check["app"]["id"]}
        )
    if not ci_only:
        add_metadata_context(pr, api, contexts)
    payload = json.loads((ROOT / ".github/rulesets/main.json").read_text())
    payload["rules"].append(
        {
            "type": "required_status_checks",
            "parameters": {
                "required_status_checks": contexts,
                "strict_required_status_checks_policy": True,
                "do_not_enforce_on_create": False,
            },
        }
    )
    rulesets = api("rulesets")
    ids = [ruleset["id"] for ruleset in rulesets if ruleset["name"] == NAME]
    if len(ids) > 1:
        raise ValueError(
            "같은 이름의 ruleset이 여러 개라 적용 대상을 결정할 수 없습니다."
        )
    identifier = ids[0] if ids else None
    if ci_only and identifier is not None:
        current = api(f"rulesets/{identifier}")
        required = {
            check["context"]
            for rule in current["rules"]
            if rule["type"] == "required_status_checks"
            for check in rule["parameters"]["required_status_checks"]
        }
        if not required.issubset(EXPECTED):
            raise ValueError("CI 단독 등록으로 기존 필수 검사를 제거할 수 없습니다.")
    return payload, identifier


def add_metadata_context(pr: dict, api, contexts: list[dict]) -> None:
    statuses = api(f"commits/{pr['head']['sha']}/status?per_page=100")["statuses"]
    matches = sorted(
        (status for status in statuses if status["context"] == STATUS),
        key=lambda status: status["id"],
        reverse=True,
    )
    if (
        not matches
        or matches[0]["state"] != "success"
        or not recent(matches[0]["updated_at"])
    ):
        raise ValueError("현재 PR head의 실제 성공한 PR 형식 검사가 필요합니다.")
    if matches[0]["creator"]["login"] != "github-actions[bot]":
        raise ValueError("PR 형식 상태의 출처가 GitHub Actions가 아닙니다.")
    contexts.append(
        {"context": STATUS, "integration_id": contexts[0]["integration_id"]}
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pr", type=int, required=True)
    parser.add_argument(
        "--ci-only", action="store_true", help="최초 PR의 실제 macOS 검사만 strict 등록"
    )
    parser.add_argument(
        "--apply", action="store_true", help="검증한 설정을 실제 GitHub에 적용"
    )
    args = parser.parse_args()
    try:
        payload, identifier = prepare(args.pr, ci_only=args.ci_only)
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        if args.apply:
            result = gh_api(
                "rulesets" if identifier is None else f"rulesets/{identifier}",
                method="POST" if identifier is None else "PUT",
                payload=payload,
            )
            actual = gh_api(f"rulesets/{result['id']}")
            for key in [
                "name",
                "target",
                "enforcement",
                "bypass_actors",
                "conditions",
                "rules",
            ]:
                if actual[key] != payload[key]:
                    raise ValueError(f"적용 후 ruleset 검증 실패: {key}")
            print(f"ruleset 적용·재조회 완료: {actual['id']}")
    except (ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(error)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

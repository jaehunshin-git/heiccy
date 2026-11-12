"""신뢰하는 기본 브랜치에서 GitHub 이슈·PR 메타데이터만 검증한다."""

from __future__ import annotations

import json
import os
import re
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from check_submission import RULES, check_submission, related_issues

CONTEXT = "PR 형식 검증"
INVALID_LABEL = "invalid-format"


class GitHub:
    def __init__(self, repository: str, token: str):
        if repository != RULES["repository"]:
            raise ValueError("대상 저장소가 heiccy가 아닙니다.")
        self.repository = repository
        self.token = token

    def api(self, method: str, path: str, data=None):
        request = Request(
            f"https://api.github.com/repos/{self.repository}/{path}",
            method=method,
            data=None if data is None else json.dumps(data).encode(),
            headers={
                "Authorization": f"Bearer {self.token}",
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
                "Content-Type": "application/json",
            },
        )
        with urlopen(request, timeout=30) as response:
            raw = response.read()
            return json.loads(raw) if raw else None

    def status(self, sha: str, state: str, description: str):
        if re.fullmatch(r"[0-9a-f]{40}", sha) is None:
            raise ValueError("잘못된 PR head SHA입니다.")
        self.api(
            "POST",
            f"statuses/{sha}",
            {
                "context": CONTEXT,
                "state": state,
                "description": description[:140],
                "target_url": f"https://github.com/{self.repository}/actions/runs/{os.environ['GITHUB_RUN_ID']}",
            },
        )


def fingerprint(item: dict, kind: str) -> tuple:
    parts = (
        item["title"],
        item.get("body") or "",
        tuple(
            sorted(
                label["name"]
                for label in item.get("labels", [])
                if label["name"] != INVALID_LABEL
            )
        ),
    )
    if kind == "pr":
        parts += (item["head"]["sha"], item["base"]["ref"], item["state"])
    return parts


def validate_pr(client: GitHub, number: int) -> list[str]:
    """이벤트 본문 대신 최신 내용을 다시 읽고 상태를 갱신한다."""
    path = f"pulls/{number}"
    current = client.api("GET", path)
    sha = current["head"]["sha"]
    client.status(sha, "pending", "현재 PR 제목·본문 재검증 중")
    try:
        errors = check_submission("pr", current["title"], current.get("body") or "")
        if current["base"]["ref"] != "main":
            errors.append("대상 브랜치는 main이어야 합니다.")
        for issue in related_issues(current.get("body") or ""):
            try:
                linked = client.api("GET", f"issues/{issue}")
                if "pull_request" in linked:
                    errors.append(f"#{issue}는 이슈가 아니라 PR입니다.")
            except HTTPError as error:
                if error.code == 404:
                    errors.append(f"관련이슈 #{issue}가 존재하지 않습니다.")
                else:
                    raise
        latest = client.api("GET", path)
        if fingerprint(latest, "pr") != fingerprint(current, "pr"):
            client.status(
                latest["head"]["sha"], "pending", "검증 중 PR 변경: 다음 재검증 대기"
            )
            return ["검증 중 PR이 변경되어 성공 결과를 게시하지 않았습니다."]
        client.status(
            sha,
            "failure" if errors else "success",
            "형식 미준수: " + "; ".join(errors)
            if errors
            else "제목·필수 본문·관련 이슈 검증 통과",
        )
        # 최종 기록 직후에도 확인해 오래된 성공 결과를 신속히 무효화한다.
        latest = client.api("GET", path)
        if fingerprint(latest, "pr") != fingerprint(current, "pr"):
            client.status(
                latest["head"]["sha"], "pending", "본문/제목 변경으로 재검증 필요"
            )
            return ["결과 게시 중 PR이 변경되어 pending으로 되돌렸습니다."]
        return errors
    except Exception:
        client.status(sha, "error", "메타데이터 검증 오류: 성공으로 처리하지 않습니다.")
        raise


def validate_issue(client: GitHub, number: int) -> list[str]:
    path = f"issues/{number}"
    current = client.api("GET", path)
    if "pull_request" in current:
        raise ValueError("이슈 검증에 PR 번호를 사용할 수 없습니다.")
    labels = [label["name"] for label in current["labels"]]
    errors = check_submission(
        "issue", current["title"], current.get("body") or "", labels=labels
    )
    latest = client.api("GET", path)
    if fingerprint(latest, "issue") != fingerprint(current, "issue"):
        return ["검증 중 이슈가 변경되어 라벨을 변경하지 않았습니다."]
    if errors and INVALID_LABEL not in labels:
        client.api("POST", f"{path}/labels", {"labels": [INVALID_LABEL]})
    elif not errors and INVALID_LABEL in labels:
        client.api("DELETE", f"{path}/labels/{INVALID_LABEL}")
    return errors


def main() -> int:
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    client = GitHub(os.environ["GITHUB_REPOSITORY"], os.environ["GH_TOKEN"])
    if "pull_request" in event:
        errors = validate_pr(client, int(event["pull_request"]["number"]))
    elif "issue" in event:
        errors = validate_issue(client, int(event["issue"]["number"]))
    else:
        raise ValueError("이슈·PR 이벤트가 필요합니다.")
    summary = Path(os.environ["GITHUB_STEP_SUMMARY"])
    # 제목·본문을 로그나 Actions 명령으로 직접 출력하지 않는다.
    summary.write_text(
        "형식 검증 실패\n\n" + "\n".join(f"- {e}" for e in errors)
        if errors
        else "형식 검증 통과\n",
        encoding="utf-8",
    )
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())

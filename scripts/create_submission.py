"""템플릿을 읽고 로컬 검증한 뒤 gh로 생성하며 실제 제출 내용을 재확인한다."""

from __future__ import annotations

import json
import subprocess

from check_submission import (
    ROOT,
    RULES,
    argument_parser,
    check_submission,
    select_issue_template,
)


def create(args, run=subprocess.run) -> str:
    body = args.body_file.read_text(encoding="utf-8")
    template = args.template or select_issue_template(args.title)
    if args.kind == "issue" and template not in RULES["issues"]:
        raise ValueError("제목에 맞는 이슈 템플릿이 필요합니다.")
    rule = RULES["issues"][template] if args.kind == "issue" else RULES["pr"]
    # 실제 제출자가 선택한 원본 양식을 읽어 검토할 수 있도록 표시한다.
    print((ROOT / rule["template"]).read_text(encoding="utf-8"))
    labels = list(dict.fromkeys((args.label or []) + rule.get("labels", [])))
    errors = check_submission(
        args.kind, args.title, body, template=template, labels=labels
    )
    if errors:
        raise ValueError("\n".join(errors))
    repo = run(
        ["gh", "repo", "view", "--json", "nameWithOwner"],
        cwd=ROOT,
        check=True,
        text=True,
        capture_output=True,
    )
    if json.loads(repo.stdout)["nameWithOwner"] != RULES["repository"]:
        raise ValueError("현재 저장소가 heiccy가 아닙니다.")
    command = [
        "gh",
        args.kind,
        "create",
        "--repo",
        RULES["repository"],
        "--title",
        args.title,
        "--body-file",
        str(args.body_file.resolve()),
    ]
    for label in labels:
        command.extend(["--label", label])
    if args.kind == "pr":
        branch = run(
            ["git", "branch", "--show-current"],
            cwd=ROOT,
            check=True,
            text=True,
            capture_output=True,
        ).stdout.strip()
        if not branch or branch == "main":
            raise ValueError("PR 생성은 작업 브랜치에서 실행해야 합니다.")
        command.extend(["--base", "main", "--head", branch])
    result = run(command, cwd=ROOT, check=True, text=True, capture_output=True)
    url = result.stdout.strip()
    actual = json.loads(
        run(
            [
                "gh",
                args.kind,
                "view",
                url,
                "--repo",
                RULES["repository"],
                "--json",
                "title,body,labels",
            ],
            cwd=ROOT,
            check=True,
            text=True,
            capture_output=True,
        ).stdout
    )
    errors = check_submission(
        args.kind,
        actual["title"],
        actual["body"],
        template=template,
        labels=[label["name"] for label in actual["labels"]],
    )
    if actual["title"] != args.title or actual["body"].rstrip() != body.rstrip():
        errors.append("생성된 제목·본문이 로컬 검증 원본과 다릅니다.")
    if errors:
        raise ValueError(f"생성 후 재확인 실패 ({url}): " + "; ".join(errors))
    return url


def main() -> int:
    args = argument_parser().parse_args()
    try:
        print(create(args))
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(error)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

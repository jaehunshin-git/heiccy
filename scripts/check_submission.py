"""이슈·PR의 공통 제출 형식을 검사한다. 외부 입력을 코드로 실행하지 않는다."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RULES = json.loads((Path(__file__).with_name("submission_rules.json")).read_text())
EMPTY = {"", "_No response_", "No response", "없음", "N/A", "NA", "-", "해당 없음"}
PLACEHOLDER = re.compile(
    r"(?im)^\s*(?:[-*]\s*)?(?:\[[ xX]\]\s*)?(?:TODO|TBD|placeholder|\.\.\.|예시)\s*$"
    r"|\b(?:TODO|TBD)\b|(?:작성|입력|교체)(?:해\s*주세요|해주세요|하세요)"
    r"|#(?:이슈번호|issue_number)|<[^>\n]*(?:내용|번호|여기에|description|issue)[^>\n]*>"
)
PR_TITLE = re.compile(
    r"(?:feat|fix|docs|style|refactor|test|build|ci|chore|perf|revert)"
    r"(?:\([\w./-]+\))?!?: \S.{3,}",
    re.UNICODE,
)


def visible_markdown(body: str) -> str:
    """주석·인용·코드의 가짜 섹션/이슈 연결을 제외한다."""
    body = re.sub(r"<!--[\s\S]*?(?:-->|\Z)", "", body)
    lines = []
    fence = None
    for line in body.splitlines():
        match = re.match(r"^\s{0,3}(`{3,}|~{3,})", line)
        if match:
            marker = match[1]
            if fence is None:
                fence = marker
            elif marker[0] == fence[0] and len(marker) >= len(fence):
                fence = None
            continue
        if fence is None and not re.match(r"^\s*(?:>| {4}|\t)", line):
            lines.append(line)
    return "\n".join(lines)


def parse_sections(body: str, level: int) -> tuple[dict[str, str], list[str]]:
    parts = re.split(rf"^{('#' * level)} (.+?)\s*$", body, flags=re.MULTILINE)
    sections = {}
    errors = []
    for index in range(1, len(parts), 2):
        name, value = parts[index : index + 2]
        if name in sections:
            errors.append(f"중복 섹션: {name}")
        sections[name] = value.strip()
    return sections, errors


def related_issues(body: str) -> list[int]:
    repo = re.escape(RULES["repository"])
    pattern = (
        rf"(?im)^\s*(?:[-*]\s*)?(?:close[sd]?|fix(?:es|ed)?|resolve[sd]?)\s*:?[ \t]+"
        rf"(?:#|{repo}#|https://github\.com/{repo}/issues/)([1-9][0-9]*)\b"
    )
    return [int(value) for value in re.findall(pattern, visible_markdown(body))]


def select_issue_template(title: str) -> str | None:
    return next(
        (
            key
            for key, rule in RULES["issues"].items()
            if title.startswith(rule["title_prefix"])
        ),
        None,
    )


def template_placeholders(text: str) -> list[str]:
    """이 저장소 양식의 단일 행·블록 placeholder 원문을 읽는다."""
    values = []
    for match in re.finditer(r"(?m)^([ ]*)placeholder:[ \t]*(.*)$", text):
        value = match[2].strip()
        if value in {"|", "|-", "|+"}:
            lines = []
            for line in text[match.end() :].splitlines()[1:]:
                if line.strip() and len(line) - len(line.lstrip()) <= len(match[1]):
                    break
                lines.append(line.strip())
            value = "\n".join(lines).strip()
        else:
            value = value.strip("\"'")
        if value:
            values.append(value)
    return values


def check_submission(
    kind: str,
    title: str,
    body: str,
    *,
    template: str | None = None,
    labels: list[str] | None = None,
) -> list[str]:
    errors = []
    if kind == "issue":
        template = template or select_issue_template(title)
        if template not in RULES["issues"]:
            return ["지원하는 이슈 제목 접두사·템플릿이 필요합니다."]
        rule = RULES["issues"][template]
        prefix = rule["title_prefix"]
        if not title.startswith(prefix) or len(title[len(prefix) :].strip()) < 4:
            errors.append(f"제목은 {prefix} 뒤에 구체적인 작업/문제를 적어야 합니다.")
        if labels is None or not set(rule["labels"]).issubset(labels):
            errors.append(f"필수 라벨 누락: {', '.join(rule['labels'])}")
    elif kind == "pr":
        rule = RULES["pr"]
        if PR_TITLE.fullmatch(title) is None:
            errors.append(
                "PR 제목은 Conventional Commits 형식과 구체적인 설명이 필요합니다."
            )
    else:
        return ["지원하지 않는 제출 종류입니다."]
    # 템플릿이 존재하는 체크아웃에서만 제출하도록 한다.
    template_path = ROOT / rule["template"]
    if not template_path.is_file():
        errors.append(f"템플릿 파일 없음: {rule['template']}")
    elif any(
        re.sub(r"\s+", " ", value).strip() in re.sub(r"\s+", " ", body).strip()
        for value in template_placeholders(template_path.read_text(encoding="utf-8"))
    ):
        errors.append("선택한 템플릿의 placeholder 원문이 본문에 남아 있습니다.")
    title_content = re.sub(r"^(?:[^:]+: |\[[^]]+\] )", "", title)
    if "\n" in title or PLACEHOLDER.search(title_content):
        errors.append("제목에 줄바꿈 또는 미작성 안내가 남아 있습니다.")
    if PLACEHOLDER.search(body):
        errors.append("본문에 placeholder 또는 템플릿 안내가 남아 있습니다.")
    clean = visible_markdown(body)
    sections, duplicates = parse_sections(clean, 3 if kind == "issue" else 2)
    errors.extend(duplicates)
    for heading in rule["required"]:
        value = sections.get(heading, "")
        if value in EMPTY or len(re.sub(r"[\s#*_`\[\]-]", "", value)) < 5:
            errors.append(f"필수 섹션 미작성: {heading}")
        elif value.startswith("해당 없음"):
            if heading not in rule["allow_not_applicable"]:
                errors.append(f"해당 없음이 허용되지 않는 섹션: {heading}")
            elif len(re.sub(r"^[\s:—-]+", "", value[len("해당 없음") :])) < 5:
                errors.append(f"해당 없음의 구체적인 이유 필요: {heading}")
        if heading in rule["checklists"] and not re.search(
            r"(?m)^- \[[ xX]\] \S.{4,}", value
        ):
            errors.append(f"실제 작업 체크리스트 필요: {heading}")
    for heading, value in sections.items():
        if heading in rule.get("optional", []) and value.startswith("해당 없음"):
            if (
                heading not in rule["allow_not_applicable"]
                or len(re.sub(r"^[\s:—-]+", "", value[len("해당 없음") :])) < 5
            ):
                errors.append(f"해당 없음의 허용 여부와 구체적인 이유 필요: {heading}")
        if heading not in rule["required"] and heading not in rule.get("optional", []):
            errors.append(f"허용하지 않은 섹션: {heading}")
        elif value not in EMPTY and PLACEHOLDER.search(value):
            errors.append(f"미작성 안내가 남은 섹션: {heading}")
    if (
        kind == "issue"
        and template == "bug"
        and sections.get("사용 구성 요소") not in {"macOS 앱", "CLI/TUI"}
    ):
        errors.append("사용 구성 요소는 macOS 앱 또는 CLI/TUI여야 합니다.")
    if kind == "pr" and not related_issues(sections.get("📌 Summary", "")):
        errors.append("Summary에 heiccy 이슈를 연결하는 Closes #번호가 필요합니다.")
    return list(dict.fromkeys(errors))


def argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kind", choices=["issue", "pr"], required=True)
    parser.add_argument("--title", required=True)
    parser.add_argument("--body-file", type=Path, required=True)
    parser.add_argument("--template", choices=list(RULES["issues"]))
    parser.add_argument("--label", action="append", default=None)
    return parser


def main() -> int:
    args = argument_parser().parse_args()
    errors = check_submission(
        args.kind,
        args.title,
        args.body_file.read_text(),
        template=args.template,
        labels=args.label,
    )
    for error in errors:
        print(error)
    if not errors:
        print("제출 형식 검증 통과")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())

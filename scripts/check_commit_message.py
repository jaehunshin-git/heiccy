"""저장소의 한국어 Conventional Commits 규칙 검사기 (Python 3.11+)."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import unicodedata
from pathlib import Path

RULES_PATH = Path(__file__).with_name("commit_message_rules.json")
HEADER = re.compile(r"([a-z]+)(?:\(([^()\s:]+)\))?(!)?: (\S.*)")
HANGUL = re.compile(r"[가-힣]")
FOOTER = re.compile(r"([A-Za-z][A-Za-z-]*|BREAKING CHANGE): (.*)")
ISSUES = re.compile(r"#[1-9]\d*(?:,? #[1-9]\d*)*")
IDENTITY = re.compile(r"[^<>\n]+ <[^<>\s]+@[^<>\s]+>")
INLINE = re.compile(
    r"(?<!`)(`+)(?!`).*?(?<!`)\1(?!`)|\"[^\"]*\"|'[^']*'|“[^”]*”|‘[^’]*’"
)
EXAMPLE = "fix(macos): 클립보드 복원 조건 수정"


def load_rules(path: Path = RULES_PATH) -> dict:
    """빈 목록이나 잘못된 설정 때문에 검사가 조용히 해제되지 않도록 확인."""
    rules = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(rules, dict):
        raise TypeError("규칙 파일에는 JSON 객체 필요")
    for key in ("types", "noun_endings", "declarative_endings"):
        values = rules.get(key)
        if (
            not isinstance(values, list)
            or not values
            or any(not isinstance(value, str) or not value for value in values)
        ):
            raise ValueError(f"규칙 {key}에는 비어 있지 않은 문자열 목록 필요")
    if any(not re.fullmatch(r"[a-z]+", value) for value in rules["types"]):
        raise ValueError("허용 type에는 영어 소문자만 사용 가능")
    return rules


def prose_errors(text: str, line: int, rules: dict) -> list[str]:
    """인용/코드를 제외한 각 자연어 문장의 종결 검사."""
    prose = INLINE.sub("", text).strip()
    if "`" in prose:
        return [f"{line}행: 인라인 코드 백틱 개수 불일치 또는 닫히지 않은 백틱"]
    if not HANGUL.search(prose):
        return [f"{line}행: 자연어 설명에 한국어 필요 (예: API 응답 처리 개선)"]
    errors = []
    # 파일명 마침표 보호와 무관하게, 서술형 바로 뒤의 문장부호는 종결로 검사.
    for word in re.findall(r"([가-힣]+)[.!?。！？]", prose):
        if any(word.endswith(ending) for ending in rules["declarative_endings"]):
            errors.append(
                f"{line}행: 서술형 종결 '{word}' 차단 "
                "(명사형 예: 기능 추가 / 처리 속도 개선)"
            )
    for sentence in re.split(
        r"(?<=[가-힣])(?:\.(?![A-Za-z0-9])|[!?。！？])+|[.!?。！？]+(?:\s+|$)", prose
    ):
        sentence = sentence.strip().rstrip(".,!?。！？:;)]}*_")
        if not sentence:
            continue
        words = sentence.split()
        # 뒤따르는 API/패키지명을 제외해도 자연어 설명 자체는 명사형 필요.
        while words and not HANGUL.search(words[-1]):
            words.pop()
        if not words:
            errors.append(
                f"{line}행: 자연어 문장에 한국어 필요 (예: API 응답 처리 개선)"
            )
            continue
        last = words[-1].rstrip(".,!?。！？:;)]}*_")
        if any(last.endswith(ending) for ending in rules["declarative_endings"]):
            errors.append(
                f"{line}행: 서술형 종결 '{last}' 차단 "
                "(명사형 예: 기능 추가 / 처리 속도 개선)"
            )
        elif any(last.endswith(ending) for ending in rules["noun_endings"]):
            continue
        elif last[-1] in "가나다라마바사아자차카타파하":
            errors.append(f"{line}행: 명사형 종결 확인 불가 '{last}' (예: 기능 추가)")
        elif (ord(last[-1]) - 0xAC00) % 28 == 16:
            # 명사화 어미 -음/-ㅁ: 줄임, 막음, 검증함, 수정됨 등.
            continue
        else:
            errors.append(
                f"{line}행: 명사형 종결 확인 불가 '{last}'. "
                "명사형으로 수정하거나 commit_message_rules.json의 noun_endings 보완 필요"
            )
    return list(dict.fromkeys(errors))


def check_message(message: str, rules: dict | None = None) -> list[str]:
    """메시지를 변경하지 않고 위반 위치와 수정 안내 반환."""
    rules = rules if rules is not None else load_rules()
    lines = unicodedata.normalize("NFC", message).splitlines()
    if not lines or not lines[0].strip():
        return [f"1행: 비어 있는 제목. 예: {EXAMPLE}"]
    title = lines[0]
    for prefix in ("fixup! ", "squash! "):
        if title.startswith(prefix):
            title = title[len(prefix) :]
            break
    match = HEADER.fullmatch(title)
    if not match:
        return [
            f"1행: 제목 형식 위반. <type>(<scope>): <한국어 요약> 필요. 예: {EXAMPLE}"
        ]
    errors = []
    if match[1] not in rules["types"]:
        errors.append(
            f"1행: 허용되지 않은 type '{match[1]}'. 허용: {', '.join(rules['types'])}"
        )
    errors.extend(prose_errors(match[4], 1, rules))
    if len(lines) > 1 and lines[1].strip():
        errors.append("2행: 제목과 본문/footer 사이에 빈 줄 필요")

    pending: list[str] = []
    pending_line = 0
    fence: str | None = None
    in_footer = False
    footer_value = False
    footer_description = False

    def flush() -> None:
        if pending:
            # 줄바꿈으로 나뉜 설명의 서술형을 뒤의 정상 명사로 숨기지 못하도록 검사.
            unquoted = INLINE.sub(
                lambda match: "\n" * match[0].count("\n"), "\n".join(pending)
            ).splitlines()
            for offset, part in enumerate(unquoted[:-1]):
                errors.extend(
                    error
                    for error in prose_errors(part, pending_line + offset, rules)
                    if "서술형 종결" in error
                )
            errors.extend(prose_errors(" ".join(pending), pending_line, rules))
            pending.clear()

    for number, original in enumerate(lines[2:], 3):
        stripped = original.strip()
        fence_match = re.match(r"^(`{3,}|~{3,})(.*)$", stripped)
        if fence:
            if (
                fence_match
                and fence_match[1][0] == fence[0]
                and (len(fence_match[1]) >= len(fence) and not fence_match[2].strip())
            ):
                fence = None
            continue
        if fence_match:
            flush()
            if in_footer and not footer_value:
                errors.append(f"{number}행: footer 뒤 코드 블록 배치 불가")
            fence = fence_match[1]
            continue
        if not stripped:
            flush()
            continue
        if original.startswith(("    ", "\t")) or stripped.startswith(">"):
            flush()
            if in_footer and not footer_value:
                errors.append(
                    f"{number}행: 이슈/작성자 footer 뒤 인용 또는 코드 배치 불가"
                )
            continue
        trailer = FOOTER.fullmatch(stripped)
        if trailer:
            flush()
            if footer_value and not footer_description:
                errors.append(f"{number}행: 이전 footer에 한국어 명사형 설명 필요")
            if not in_footer and lines[number - 2].strip():
                errors.append(f"{number}행: 본문과 footer 사이에 빈 줄 필요")
            in_footer = True
            token, value = trailer.groups()
            footer_value = False
            footer_description = False
            if token in ("Refs", "Closes"):
                if not ISSUES.fullmatch(value):
                    errors.append(
                        f"{number}행: 이슈 footer 형식 위반 (예: {token}: #123)"
                    )
            elif token in ("Co-authored-by", "Signed-off-by"):
                if not IDENTITY.fullmatch(value):
                    errors.append(
                        f"{number}행: 작성자 footer 형식 위반 (예: {token}: 이름 <mail@example.com>)"
                    )
            else:
                if token.lower().replace(
                    "-", " "
                ) == "breaking change" and token not in (
                    "BREAKING CHANGE",
                    "BREAKING-CHANGE",
                ):
                    errors.append(
                        f"{number}행: BREAKING CHANGE 토큰은 영어 대문자 필요"
                    )
                if token.lower() in ("refs", "closes"):
                    errors.append(f"{number}행: 이슈 토큰은 Refs 또는 Closes 필요")
                footer_value = True
                pending_line = number
                if value:
                    pending.append(value)
                    footer_description = True
            continue
        if re.match(r"(?i)^(refs|closes|breaking[ -]change)\b", stripped):
            flush()
            errors.append(
                f"{number}행: footer 형식 위반 (예: Refs: #123 / BREAKING CHANGE: API 응답 구조 변경)"
            )
            continue
        if in_footer and not footer_value:
            errors.append(
                f"{number}행: 이슈/작성자 footer 뒤에는 새 footer만 배치 가능"
            )
        bullet = re.match(r"^(?:[-*+] |\d+[.)] )(.*)", stripped)
        if bullet:
            flush()
            stripped = bullet[1]
        if not pending:
            pending_line = number
        pending.append(stripped)
        if in_footer and footer_value:
            footer_description = True
    flush()
    if footer_value and not footer_description:
        errors.append("footer: 한국어 명사형 설명 필요")
    if fence:
        errors.append("본문: 닫히지 않은 코드 블록. 종료 fence 필요")
    return errors


def git_editor_message(message: str) -> str:
    """Git 기본 편집기의 주석 제거. -m/-F에서는 주석도 검사."""
    import os

    editing = os.environ.get("GIT_EDITOR") != ":"
    cleanup = subprocess.run(
        ["git", "config", "--get", "commit.cleanup"],
        capture_output=True,
        text=True,
        check=False,
    ).stdout.strip()
    if editing and cleanup != "verbatim":
        # verbose diff/scissors는 Git이 최종 커밋 메시지에서 절단하는 구간.
        for key in ("core.commentString", "core.commentChar"):
            comment = subprocess.run(
                ["git", "config", "--get", key],
                capture_output=True,
                text=True,
                check=False,
            ).stdout.strip()
            if comment:
                break
        comment = "#" if comment in ("", "auto") else comment
        marker = f"{comment} ------------------------ >8 ------------------------"
        lines = message.splitlines()
        cut = next((i for i, line in enumerate(lines) if line == marker), len(lines))
        tail = lines[cut + 1 :]
        # 임의의 구분선만으로 자연어 본문을 검사 대상에서 제외하지 않는다.
        diff_lines = [line for line in tail if line and not line.startswith(comment)]
        verbose_diff = (
            bool(diff_lines)
            and diff_lines[0].startswith("diff --git ")
            and all(
                line.startswith(
                    (
                        "diff --git ",
                        "index ",
                        "--- ",
                        "+++ ",
                        "@@ ",
                        "+",
                        "-",
                        " ",
                        "\\",
                        "new file mode ",
                        "deleted file mode ",
                        "old mode ",
                        "new mode ",
                        "similarity index ",
                        "rename from ",
                        "rename to ",
                        "Binary files ",
                    )
                )
                for line in diff_lines
            )
        )
        if cleanup == "scissors" or verbose_diff:
            message = "\n".join(lines[:cut])
    if cleanup != "strip" and not (editing and cleanup in ("", "default")):
        return message
    result = subprocess.run(
        ["git", "stripspace", "--strip-comments"],
        input=message,
        capture_output=True,
        text=True,
        check=True,
    )
    return result.stdout


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("message_file", type=Path, help="검사할 UTF-8 커밋 메시지 파일")
    parser.add_argument(
        "--rules", type=Path, default=RULES_PATH, help="저장소 규칙 JSON 경로"
    )
    parser.add_argument(
        "--git-context", action="store_true", help="Git 기본 편집기 주석 처리"
    )
    args = parser.parse_args()
    try:
        message = args.message_file.read_text(encoding="utf-8")
        if args.git_context:
            message = git_editor_message(message)
        errors = check_message(message, load_rules(args.rules))
    except (OSError, TypeError, ValueError, subprocess.SubprocessError) as error:
        print(f"커밋 메시지 검사 실패: {error}", file=sys.stderr)
        return 2
    if errors:
        print("커밋 메시지 규칙 위반으로 커밋 차단:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        print(
            f"수정 예시: {EXAMPLE}\n규칙 안내: docs/commit-message-hooks.md",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

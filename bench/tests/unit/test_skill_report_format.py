"""Guard the detect-only report line format in SKILL.md against template drift.

WU4's report parser depends on the "Confirmed but not fixed" section emitting a
structured, ``·``-separated line. If the template ever loses that structure this
test fails in CI before the parser silently mis-reads a future report.
"""

import json
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
SKILL_MD = REPO_ROOT / "SKILL.md"
SECTION_HEADER = "## Confirmed but not fixed (detect-only or below severity floor)"
JSON_BLOCK_SECTION = "## Findings (machine-readable)"
JSON_FENCE_OPEN = "```json"
JSON_FENCE_CLOSE = "```"
REQUIRED_JSON_KEYS = {"bug_id", "severity", "category", "file", "line", "fixed", "rationale"}

# Tokens the structured line MUST contain (bare angle-bracket placeholders in the
# template). file:line is checked as the joined token to pin the colon form.
REQUIRED_TOKENS = ["<BUG-ID>", "<severity>", "<category>", "<file>:<line>"]


def _section_window(text: str, header: str) -> str:
    """Return the lines under ``header`` up to the next ``## `` header or EOF.

    Scoping the assertion to this window keeps the test honest if sections are
    reordered or another section happens to share token names (e.g. the "Fixed"
    line at SKILL.md:191 uses a similar but distinct format).
    """
    lines = text.splitlines()
    try:
        start = next(i for i, line in enumerate(lines) if line.strip() == header)
    except StopIteration as exc:  # pragma: no cover - failure path asserted below
        raise AssertionError(f"SKILL.md is missing the section header: {header!r}") from exc
    window: list[str] = []
    for line in lines[start + 1 :]:
        if line.startswith("## "):
            break
        window.append(line)
    return "\n".join(window)


def test_skill_md_exists() -> None:
    assert SKILL_MD.is_file(), f"expected SKILL.md at {SKILL_MD}"


def test_detect_only_section_uses_structured_line() -> None:
    text = SKILL_MD.read_text(encoding="utf-8")
    window = _section_window(text, SECTION_HEADER)

    structured = [
        line
        for line in window.splitlines()
        if "·" in line and all(token in line for token in REQUIRED_TOKENS)
    ]
    assert structured, (
        "expected a structured '·'-separated line under "
        f"{SECTION_HEADER!r} containing {REQUIRED_TOKENS}; section window was:\n{window}"
    )


def test_detect_only_section_has_no_unstructured_placeholder() -> None:
    """The old free-form placeholder must be gone so the parser has one shape."""
    window = _section_window(SKILL_MD.read_text(encoding="utf-8"), SECTION_HEADER)
    assert "<one line per item>" not in window


def _find_json_block_in_skill_md(text: str) -> "str | None":
    """Extract the fenced JSON from the machine-readable section in SKILL.md.

    Returns the raw JSON string, or None if the section or fence is absent.
    """
    lines = text.splitlines()
    section_start = next(
        (i for i, line in enumerate(lines) if line.strip() == JSON_BLOCK_SECTION),
        -1,
    )
    if section_start < 0:
        return None
    fence_start = next(
        (
            i
            for i in range(section_start + 1, len(lines))
            if lines[i].strip() == JSON_FENCE_OPEN
        ),
        -1,
    )
    if fence_start < 0:
        return None
    fence_lines: list[str] = []
    for line in lines[fence_start + 1 :]:
        if line.strip() == JSON_FENCE_CLOSE:
            break
        fence_lines.append(line)
    return "\n".join(fence_lines)


def test_skill_md_has_machine_readable_section() -> None:
    text = SKILL_MD.read_text(encoding="utf-8")
    assert JSON_BLOCK_SECTION in text, (
        f"SKILL.md is missing the machine-readable section header: {JSON_BLOCK_SECTION!r}"
    )


def test_skill_md_machine_readable_section_has_json_fence() -> None:
    text = SKILL_MD.read_text(encoding="utf-8")
    raw = _find_json_block_in_skill_md(text)
    assert raw is not None, (
        f"SKILL.md's {JSON_BLOCK_SECTION!r} section has no {JSON_FENCE_OPEN!r} fence"
    )


def test_skill_md_json_example_is_valid_json() -> None:
    text = SKILL_MD.read_text(encoding="utf-8")
    raw = _find_json_block_in_skill_md(text)
    assert raw is not None
    try:
        json.loads(raw)
    except json.JSONDecodeError as exc:
        raise AssertionError(
            f"SKILL.md machine-readable JSON example is not valid JSON: {exc}"
        ) from exc


def test_skill_md_json_example_has_required_keys() -> None:
    text = SKILL_MD.read_text(encoding="utf-8")
    raw = _find_json_block_in_skill_md(text)
    assert raw is not None
    items = json.loads(raw)
    assert isinstance(items, list) and items, "JSON example must be a non-empty array"
    example = items[0]
    missing = REQUIRED_JSON_KEYS - set(example.keys())
    assert not missing, (
        f"SKILL.md JSON example is missing required keys: {sorted(missing)}"
    )

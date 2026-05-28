"""Guard the detect-only report line format in SKILL.md against template drift.

WU4's report parser depends on the "Confirmed but not fixed" section emitting a
structured, ``·``-separated line. If the template ever loses that structure this
test fails in CI before the parser silently mis-reads a future report.
"""

from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
SKILL_MD = REPO_ROOT / "SKILL.md"
SECTION_HEADER = "## Confirmed but not fixed (detect-only or below severity floor)"

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

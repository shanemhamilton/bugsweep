"""Parse a bugsweep ``report.md`` into normalized :class:`Finding` records.

The scorer is keyed on the report's "Confirmed but not fixed" section and reads
two structured shapes that the released skill and the baseline arm produce
naturally:

* **Bullet form** (the WU1 SKILL.md prerequisite; preserved for compatibility) ::

      - <BUG-ID> · <severity> · <category> · <file>:<line> · <cause>

* **H3 form** (the as-released skill's natural output) ::

      ### <BUG-ID> · <severity> · <category> · `<file>:<line>`
      **<cause-on-the-next-non-blank-line>**

The H3 form has the cause on the bold line immediately following the header, the
``file:line`` token wrapped in backticks, and an optional architectural-tier
qualifier on the category (e.g. ``architectural (T2)`` → ``architectural``).

The section header is matched by **prefix** (``## Confirmed but not fixed``)
rather than the exact WU1-prerequisite string, because claude paraphrases the
parenthetical. Malformed lines are skipped (never crash); a missing header
yields ``[]``.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Iterator, Sequence

#: Prefix-matched so claude's natural paraphrase ("(detect-only)" vs the WU1
#: header's "(detect-only or below severity floor)") still anchors the section.
SECTION_HEADER_PREFIX = "## Confirmed but not fixed"
FIELD_SEPARATOR = "·"  # U+00B7 MIDDLE DOT.
BULLET_PREFIX = "- "
H3_PREFIX = "### "
H2_PREFIX = "## "  # ends the section (and does NOT match H3 — different length).
BOLD_DELIM = "**"
BACKTICK = "`"
BULLET_FIELD_COUNT = 5  # bullet: bug · sev · cat · file:line · cause
H3_FIELD_COUNT = 4  # h3:     bug · sev · cat · `file:line`
CATEGORY_QUALIFIER_DELIM = " ("  # strip suffixes like " (T2)" / " (T7)".


@dataclass(frozen=True)
class Finding:
    """One parsed detection from a report's detect-only section."""

    bug_id: str
    severity: str
    category: str
    file: str
    line: int
    rationale: str


def parse_report(text_or_path: str | Path) -> list[Finding]:
    """Parse ``text_or_path`` (raw report text or a path) into findings.

    Returns ``[]`` when the section header is absent or empty. Lines that do not
    match either structured shape are skipped, not raised on.
    """
    text = _read_text(text_or_path)
    section = _section_lines(text)
    return list(_iter_findings(section))


def _read_text(text_or_path: str | Path) -> str:
    if isinstance(text_or_path, Path):
        return text_or_path.read_text(encoding="utf-8")
    candidate = Path(text_or_path)
    if "\n" not in text_or_path and candidate.is_file():
        return candidate.read_text(encoding="utf-8")
    return text_or_path


def _section_lines(text: str) -> list[str]:
    """Return lines under the (prefix-matched) section header until the next H2."""
    lines = text.splitlines()
    start = _find_section_start(lines)
    if start < 0:
        return []
    window: list[str] = []
    for line in lines[start + 1 :]:
        if line.startswith(H2_PREFIX):
            break
        window.append(line)
    return window


def _find_section_start(lines: Sequence[str]) -> int:
    """Index of the first line whose strip matches the prefix as a whole token."""
    for i, line in enumerate(lines):
        stripped = line.strip()
        if not stripped.startswith(SECTION_HEADER_PREFIX):
            continue
        # Require the prefix to be followed by end-of-line or whitespace, so a
        # hypothetical "## Confirmed but not fixedXXX" doesn't anchor the parse.
        rest = stripped[len(SECTION_HEADER_PREFIX) :]
        if rest == "" or rest.startswith(" "):
            return i
    return -1


def _iter_findings(lines: Sequence[str]) -> Iterator[Finding]:
    for i, raw in enumerate(lines):
        line = raw.strip()
        if FIELD_SEPARATOR not in line:
            continue
        finding: Finding | None = None
        if line.startswith(BULLET_PREFIX):
            finding = _parse_bullet(line)
        elif line.startswith(H3_PREFIX):
            cause = _next_cause_line(lines, i + 1)
            finding = _parse_h3(line, cause)
        if finding is not None:
            yield finding


def _parse_bullet(line: str) -> Finding | None:
    body = line[len(BULLET_PREFIX) :].strip()
    parts = [p.strip() for p in body.split(FIELD_SEPARATOR)]
    if len(parts) != BULLET_FIELD_COUNT:
        return None
    bug_id, severity, category, file_line, rationale = parts
    file_and_line = _split_file_line(_first_location(file_line))
    if file_and_line is None:
        return None
    file, line_no = file_and_line
    return Finding(
        bug_id=bug_id,
        severity=severity,
        category=_clean_category(category),
        file=file,
        line=line_no,
        rationale=rationale,
    )


def _parse_h3(line: str, cause: str) -> Finding | None:
    body = line[len(H3_PREFIX) :].strip()
    parts = [p.strip() for p in body.split(FIELD_SEPARATOR)]
    if len(parts) != H3_FIELD_COUNT:
        return None
    bug_id, severity, category, file_line = parts
    file_and_line = _split_file_line(_first_location(file_line))
    if file_and_line is None:
        return None
    file, line_no = file_and_line
    return Finding(
        bug_id=bug_id,
        severity=severity,
        category=_clean_category(category),
        file=file,
        line=line_no,
        rationale=cause,
    )


def _next_cause_line(lines: Sequence[str], start: int) -> str:
    """First non-blank line after ``start`` (strip surrounding ``**`` if bold)."""
    for line in lines[start:]:
        stripped = line.strip()
        if not stripped:
            continue
        if (
            stripped.startswith(BOLD_DELIM)
            and stripped.endswith(BOLD_DELIM)
            and len(stripped) > 2 * len(BOLD_DELIM)
        ):
            return stripped[len(BOLD_DELIM) : -len(BOLD_DELIM)].strip()
        return stripped
    return ""


def _clean_category(category: str) -> str:
    """Strip qualifier suffixes like ``" (T2)"`` from architectural categories."""
    idx = category.find(CATEGORY_QUALIFIER_DELIM)
    return category[:idx] if idx >= 0 else category


def _first_location(field: str) -> str:
    """Return the first backtick-quoted location from a file-line field.

    The released skill lists several locations for one bug, e.g.
    ``\`a.mjs:4\` + \`b.mjs:24\`` (and a same-file shorthand ``\`a.mjs:24\` +
    \`:29\``). The file-overlap gate keys on a single file, so the first quoted
    location is canonical. Bullet-form fields are unquoted and pass through
    (stripped) unchanged.
    """
    open_idx = field.find(BACKTICK)
    if open_idx == -1:
        return field.strip()
    close_idx = field.find(BACKTICK, open_idx + 1)
    if close_idx == -1:
        return field[open_idx + 1 :].strip()
    return field[open_idx + 1 : close_idx].strip()


def _split_file_line(token: str) -> tuple[str, int] | None:
    """Split a ``file:line`` token; accept ``N`` or ``N-M`` (span) — for a span,
    canonicalize to the first line. ``rpartition`` keeps path-internal colons.
    """
    if ":" not in token:
        return None
    file, _, line_str = token.rpartition(":")
    # Spans like "24-43" are common in the released skill's report for bugs that
    # cover a range; pin the canonical line at the start of the range.
    if "-" in line_str:
        line_str = line_str.split("-", 1)[0]
    try:
        return file, int(line_str)
    except ValueError:
        return None

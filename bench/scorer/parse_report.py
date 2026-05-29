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
        if line.startswith(BULLET_PREFIX):
            yield from _parse_bullet(line)
        elif line.startswith(H3_PREFIX):
            cause = _next_cause_line(lines, i + 1)
            yield from _parse_h3(line, cause)


def _parse_bullet(line: str) -> list[Finding]:
    body = line[len(BULLET_PREFIX) :].strip()
    parts = [p.strip() for p in body.split(FIELD_SEPARATOR)]
    if len(parts) != BULLET_FIELD_COUNT:
        return []
    bug_id, severity, category, file_line, rationale = parts
    return _findings_for_locations(bug_id, severity, category, file_line, rationale)


def _parse_h3(line: str, cause: str) -> list[Finding]:
    body = line[len(H3_PREFIX) :].strip()
    parts = [p.strip() for p in body.split(FIELD_SEPARATOR)]
    if len(parts) != H3_FIELD_COUNT:
        return []
    bug_id, severity, category, file_line = parts
    return _findings_for_locations(bug_id, severity, category, file_line, cause)


def _findings_for_locations(
    bug_id: str, severity: str, category: str, file_line: str, rationale: str
) -> list[Finding]:
    """One Finding per cited location (same bug_id, severity, category, cause)."""
    clean_category = _clean_category(category)
    return [
        Finding(
            bug_id=bug_id,
            severity=severity,
            category=clean_category,
            file=file,
            line=line_no,
            rationale=rationale,
        )
        for file, line_no in _locations(file_line)
    ]


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


def _backtick_tokens(field: str) -> list[str]:
    """Return the contents of every backtick-quoted span in ``field``.

    An unterminated final backtick yields the remainder after it. A field with
    no backticks yields ``[]`` (the bullet form is unquoted — see ``_locations``).
    """
    tokens: list[str] = []
    i = 0
    while True:
        open_idx = field.find(BACKTICK, i)
        if open_idx == -1:
            break
        close_idx = field.find(BACKTICK, open_idx + 1)
        if close_idx == -1:
            tokens.append(field[open_idx + 1 :].strip())
            break
        tokens.append(field[open_idx + 1 : close_idx].strip())
        i = close_idx + 1
    return tokens


def _locations(field: str) -> list[tuple[str, int]]:
    """Parse every ``file:line`` location from a (possibly multi-location) field.

    The released skill cites several locations for one bug, e.g.
    "`a.mjs:4` + `b.mjs:24`", and a same-file shorthand "`a.mjs:24` + `:29`"
    where the bare ":line" inherits the previous location's file. Each
    location becomes its own :class:`Finding` (same ``bug_id``); the file-overlap
    gate then localizes the bug if ANY cited file matches ground truth,
    independent of the order the skill lists them.

    NOTE: because one multi-location bug yields several same-``bug_id`` findings,
    a future precision track MUST group findings by ``bug_id`` so the bug counts
    once. The detection track is unaffected (it asks only whether SOME finding
    passes the gate). Malformed or fileless-and-unanchored tokens are skipped.
    """
    tokens = _backtick_tokens(field) or [field.strip()]
    out: list[tuple[str, int]] = []
    prev_file = ""
    for token in tokens:
        split = _split_file_line(token)
        if split is None:
            continue
        file, line_no = split
        if not file:
            if not prev_file:
                continue  # a `:line` shorthand with nothing to inherit.
            file = prev_file
        prev_file = file
        out.append((file, line_no))
    return out


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

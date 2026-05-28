"""Parse a bugsweep ``report.md`` into normalized :class:`Finding` records.

The skill emits confirmed-but-unfixed detections as structured ``·``-separated
lines under a fixed header. The baseline arm emits the same line shape. This
module is keyed only on that header, so it reads both arms identically:

    - <BUG-ID> · <severity> · <category> · <file>:<line> · <cause>

Malformed lines are skipped (never crash); a missing header yields ``[]``.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

SECTION_HEADER = "## Confirmed but not fixed (detect-only or below severity floor)"
FIELD_SEPARATOR = "·"  # U+00B7 MIDDLE DOT — the structured-line separator.
EXPECTED_FIELD_COUNT = 5
LINE_BULLET_PREFIX = "-"
FILE_LINE_SPLIT_MAXSPLIT = 1


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
    """Parse ``text_or_path`` (raw report text or a path to it) into findings.

    Returns ``[]`` when the section header is absent or the report is empty.
    Lines that do not match the structured shape are skipped, not raised on.
    """
    text = _read_text(text_or_path)
    section = _section_lines(text)
    findings: list[Finding] = []
    for line in section:
        finding = _parse_line(line)
        if finding is not None:
            findings.append(finding)
    return findings


def _read_text(text_or_path: str | Path) -> str:
    if isinstance(text_or_path, Path):
        return text_or_path.read_text(encoding="utf-8")
    candidate = Path(text_or_path)
    # Treat the argument as a path only when it actually resolves to a file;
    # otherwise it is the report text itself (which may be empty/multi-line).
    if "\n" not in text_or_path and candidate.is_file():
        return candidate.read_text(encoding="utf-8")
    return text_or_path


def _section_lines(text: str) -> list[str]:
    """Return the lines under :data:`SECTION_HEADER` up to the next ``## `` header."""
    lines = text.splitlines()
    try:
        start = next(
            i for i, line in enumerate(lines) if line.strip() == SECTION_HEADER
        )
    except StopIteration:
        return []
    window: list[str] = []
    for line in lines[start + 1 :]:
        if line.startswith("## "):
            break
        window.append(line)
    return window


def _parse_line(raw: str) -> Finding | None:
    line = raw.strip()
    if not line.startswith(LINE_BULLET_PREFIX) or FIELD_SEPARATOR not in line:
        return None
    body = line[len(LINE_BULLET_PREFIX) :].strip()
    parts = [part.strip() for part in body.split(FIELD_SEPARATOR)]
    if len(parts) != EXPECTED_FIELD_COUNT:
        return None
    bug_id, severity, category, file_line, rationale = parts
    file_and_line = _split_file_line(file_line)
    if file_and_line is None:
        return None
    file, line_no = file_and_line
    return Finding(
        bug_id=bug_id,
        severity=severity,
        category=category,
        file=file,
        line=line_no,
        rationale=rationale,
    )


def _split_file_line(token: str) -> tuple[str, int] | None:
    """Split a ``file:line`` token; ``rsplit`` once so paths keep any earlier colons."""
    if ":" not in token:
        return None
    file, _, line_str = token.rpartition(":")
    try:
        return file, int(line_str)
    except ValueError:
        return None

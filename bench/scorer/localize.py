"""File-overlap gate plus line/category evidence for a single finding.

The HARD gate is file overlap: a finding's (path-normalized) file must be one
of the ground-truth files. ``line_close`` (the finding's line within ±window of
any ground-truth hunk) and ``category_match`` are evidence the scorer reports
but does NOT gate on, so a correct file with a far line or a broader category
still passes the gate.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import PurePosixPath
from typing import Any, Mapping, Sequence

DEFAULT_WINDOW = 10

# Specific finding lenses that count as compatible with a broad case category.
# Categories are evidence only, so this map is intentionally permissive: any
# security-flavored lens is compatible with the broad "security" case category.
_CATEGORY_COMPATIBILITY: dict[str, frozenset[str]] = {
    "security": frozenset(
        {
            "sql-injection",
            "path-traversal",
            "ssrf",
            "xss",
            "command-injection",
            "auth",
            "authorization",
            "missing-authorization",
            "deserialization",
            "csrf",
            "open-redirect",
            "secrets",
        }
    ),
}


@dataclass(frozen=True)
class GateResult:
    """Outcome of gating one finding against a case's ground truth."""

    passed: bool
    line_close: bool
    category_match: bool


def gate(
    finding: Mapping[str, Any],
    ground_truth: Mapping[str, Any],
    window: int = DEFAULT_WINDOW,
) -> GateResult:
    """Gate ``finding`` against ``ground_truth``; pure, path-normalizing.

    ``passed`` is True iff the finding's file overlaps the ground-truth files.
    ``line_close`` and ``category_match`` are evidence, never gates.
    """
    finding_file = _normalize_path(str(finding.get("file", "")))
    gt_files = {_normalize_path(str(path)) for path in ground_truth.get("files", [])}
    passed = bool(finding_file) and finding_file in gt_files

    line_close = _is_line_close(finding, ground_truth, window)
    category_match = _is_category_match(finding, ground_truth)
    return GateResult(
        passed=passed, line_close=line_close, category_match=category_match
    )


def _normalize_path(path: str) -> str:
    """Normalize a repo-relative path: strip ``./``, collapse ``//``, trim slashes.

    Uses :class:`PurePosixPath` (never ``os.path``) so behavior is identical on
    every platform; case is preserved as-is.
    """
    stripped = path.strip()
    if not stripped:
        return ""
    normalized = str(PurePosixPath(stripped))
    # PurePosixPath keeps a single leading slash (absolute); drop it so an
    # accidentally-absolute finding path matches a repo-relative ground truth.
    return normalized.lstrip("/")


def _is_line_close(
    finding: Mapping[str, Any],
    ground_truth: Mapping[str, Any],
    window: int,
) -> bool:
    line = finding.get("line")
    if not isinstance(line, int):
        return False
    hunks: Sequence[Mapping[str, Any]] = ground_truth.get("hunks", [])
    for hunk in hunks:
        start = int(hunk["start"]) - window
        end = int(hunk["end"]) + window
        if start <= line <= end:
            return True
    return False


def _is_category_match(
    finding: Mapping[str, Any],
    ground_truth: Mapping[str, Any],
) -> bool:
    finding_category = str(finding.get("category", "")).strip()
    case_category = str(ground_truth.get("category", "")).strip()
    if not finding_category or not case_category:
        return False
    if finding_category == case_category:
        return True
    compatible = _CATEGORY_COMPATIBILITY.get(case_category, frozenset())
    return finding_category in compatible

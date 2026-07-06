"""Normalize raw off-the-shelf static-analyzer output into one hit shape (bugsweep-042).

Why this exists: ``scripts/analyzers.sh`` runs whichever analyzers are installed
(semgrep, gosec, bandit, ...) against the repo and writes each tool's RAW,
tool-specific JSON to disk. That raw JSON is **untrusted input** — this module
never executes it, only parses it — and every tool has a different schema. This
is the pure, tool-agnostic reduction that turns "N different JSON dialects" into
one normalized, deduped, capped, deterministically-ordered hit list:

    {tool, rule_id, severity, file, line, message}

``severity`` is normalized to the closed set ``critical|high|medium|low`` (see
``_SEVERITY_MAP`` below for the per-tool mapping). Consumers:

* ``prompts/hunt.md`` — the Hunter reads ``analyzer-hits.json`` as candidate
  SEEDS (locations to prioritize investigating), never as pre-confirmed
  findings — every seed still requires full independent verification.
* ``prompts/referee.md`` — a finding whose file/line matches a hit here is
  recorded as ``corroborated_by:<tool>`` supporting evidence; corroboration
  RAISES confidence but its absence must NOT lower it, and a hit alone never
  confirms a finding by itself (the full Hunter -> Skeptic -> Referee gauntlet
  still applies).

Design mirrors ``bench/scorer/run_summary.py``: a pure function, no
subprocess, no network, never raises on malformed/missing per-tool input —
degrade to "this tool contributed zero hits", never fail the reduction.
"""

from __future__ import annotations

from typing import Any, Callable

#: Hits are capped and ordered by this rank (index 0 = kept first on cap / tie-break).
_SEVERITY_ORDER: tuple[str, ...] = ("critical", "high", "medium", "low")
_SEVERITY_RANK: dict[str, int] = {name: i for i, name in enumerate(_SEVERITY_ORDER)}
_DEFAULT_MAX_HITS = 200

#: Per-tool raw severity token (uppercased) -> normalized bugsweep severity.
#: Anything not listed here (including a missing/unrecognized token) falls back
#: to "low" — never invent a higher severity than the tool actually reported.
_SEMGREP_SEVERITY_MAP: dict[str, str] = {
    "ERROR": "critical",
    "WARNING": "medium",
    "INFO": "low",
}
_GOSEC_SEVERITY_MAP: dict[str, str] = {
    "HIGH": "high",
    "MEDIUM": "medium",
    "LOW": "low",
}
_BANDIT_SEVERITY_MAP: dict[str, str] = {
    "HIGH": "high",
    "MEDIUM": "medium",
    "LOW": "low",
}


def _normalize_severity(raw: Any, mapping: dict[str, str]) -> str:
    token = str(raw).strip().upper() if raw is not None else ""
    return mapping.get(token, "low")


def _as_int_or_none(value: Any) -> int | None:
    if isinstance(value, bool):  # bool is an int subclass; never treat as a line number
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        stripped = value.strip()
        if stripped.lstrip("-").isdigit():
            return int(stripped)
    return None


def _parse_semgrep(raw: Any) -> list[dict[str, Any]]:
    if not isinstance(raw, dict):
        return []
    results = raw.get("results")
    if not isinstance(results, list):
        return []
    hits: list[dict[str, Any]] = []
    for r in results:
        if not isinstance(r, dict):
            continue
        extra = r.get("extra") if isinstance(r.get("extra"), dict) else {}
        hits.append(
            {
                "tool": "semgrep",
                "rule_id": r.get("check_id"),
                "severity": _normalize_severity(extra.get("severity"), _SEMGREP_SEVERITY_MAP),
                "file": r.get("path"),
                "line": _as_int_or_none((r.get("start") or {}).get("line")),
                "message": extra.get("message"),
            }
        )
    return hits


def _parse_gosec(raw: Any) -> list[dict[str, Any]]:
    if not isinstance(raw, dict):
        return []
    issues = raw.get("Issues")
    if not isinstance(issues, list):
        return []
    hits: list[dict[str, Any]] = []
    for r in issues:
        if not isinstance(r, dict):
            continue
        hits.append(
            {
                "tool": "gosec",
                "rule_id": r.get("rule_id"),
                "severity": _normalize_severity(r.get("severity"), _GOSEC_SEVERITY_MAP),
                "file": r.get("file"),
                "line": _as_int_or_none(r.get("line")),
                "message": r.get("details"),
            }
        )
    return hits


def _parse_bandit(raw: Any) -> list[dict[str, Any]]:
    if not isinstance(raw, dict):
        return []
    results = raw.get("results")
    if not isinstance(results, list):
        return []
    hits: list[dict[str, Any]] = []
    for r in results:
        if not isinstance(r, dict):
            continue
        hits.append(
            {
                "tool": "bandit",
                "rule_id": r.get("test_id"),
                "severity": _normalize_severity(r.get("issue_severity"), _BANDIT_SEVERITY_MAP),
                "file": r.get("filename"),
                "line": _as_int_or_none(r.get("line_number")),
                "message": r.get("issue_text"),
            }
        )
    return hits


#: One parser per supported tool. Adding a new analyzer to scripts/analyzers.sh's
#: detection table only requires a matching entry here — same "easily extensible
#: table" pattern the bead asks the shell side to follow.
_PARSERS: dict[str, Callable[[Any], list[dict[str, Any]]]] = {
    "semgrep": _parse_semgrep,
    "gosec": _parse_gosec,
    "bandit": _parse_bandit,
}


def _dedup_key(hit: dict[str, Any]) -> tuple[Any, ...]:
    return (hit["tool"], hit["rule_id"], hit["file"], hit["line"], hit["message"])


def normalize_hits(
    raw_by_tool: dict[str, Any],
    max_hits: int = _DEFAULT_MAX_HITS,
) -> list[dict[str, Any]]:
    """Reduce ``{tool_name: raw_tool_json}`` into one normalized hit list.

    Pure function: never raises. A tool with no parser, or whose payload
    doesn't match its expected shape, silently contributes zero hits — this
    is a best-effort enhancement layer (see analyzers.sh header), not a
    contract any single tool's output must satisfy.

    Output is:
      * deduped on (tool, rule_id, file, line, message);
      * ordered by severity (critical > high > medium > low) then by
        (tool, rule_id, file, line) for a fully deterministic tie-break;
      * capped at ``max_hits``, keeping the highest-severity hits first.
    """
    hits: list[dict[str, Any]] = []
    seen: set[tuple[Any, ...]] = set()

    for tool_name, raw in (raw_by_tool or {}).items():
        parser = _PARSERS.get(tool_name)
        if parser is None:
            continue
        for hit in parser(raw):
            key = _dedup_key(hit)
            if key in seen:
                continue
            seen.add(key)
            hits.append(hit)

    def _sort_key(hit: dict[str, Any]) -> tuple[Any, ...]:
        rank = _SEVERITY_RANK.get(hit["severity"], len(_SEVERITY_ORDER))
        return (
            rank,
            str(hit.get("tool") or ""),
            str(hit.get("rule_id") or ""),
            str(hit.get("file") or ""),
            hit.get("line") if hit.get("line") is not None else -1,
        )

    hits.sort(key=_sort_key)

    cap = max_hits if isinstance(max_hits, int) and max_hits >= 0 else _DEFAULT_MAX_HITS
    return hits[:cap]

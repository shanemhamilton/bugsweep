"""Bounded, content-bound source evidence for human precision review."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any, Mapping

MAX_EXCERPT_LINES = 120
MAX_EXCERPT_BYTES = 12_000


def build_packet(
    *,
    candidate_id: str,
    source_path: str,
    source: str,
    source_sha256: str,
    excerpt_start: int,
    excerpt_end: int,
    trigger: Mapping[str, Any] | None,
    repro: Mapping[str, Any] | None,
) -> dict[str, Any]:
    """Build review evidence; invalid or unavailable evidence is unverified."""
    reasons: list[str] = []
    actual_sha = hashlib.sha256(source.encode("utf-8")).hexdigest()
    lines = source.splitlines(keepends=True)
    if not candidate_id or not source_path:
        reasons.append("missing_identity")
    if source_sha256 != actual_sha:
        reasons.append("source_sha256_mismatch")
    if excerpt_start < 1 or excerpt_end < excerpt_start or excerpt_end > len(lines):
        reasons.append("invalid_excerpt_range")
        excerpt = ""
    else:
        excerpt = "".join(lines[excerpt_start - 1 : excerpt_end])
        if excerpt_end - excerpt_start + 1 > MAX_EXCERPT_LINES or len(excerpt.encode()) > MAX_EXCERPT_BYTES:
            reasons.append("excerpt_too_large")
    if not trigger or not trigger.get("kind"):
        reasons.append("missing_trigger")
    if repro is not None and (not repro.get("path") or not repro.get("sha256")):
        reasons.append("invalid_repro")
    return {
        "schema_version": 1,
        "candidate_id": candidate_id,
        "status": "verified" if not reasons else "unverified",
        "reasons": reasons,
        "source": {
            "path": source_path,
            "sha256": source_sha256,
            "excerpt_start": excerpt_start,
            "excerpt_end": excerpt_end,
            "excerpt": excerpt,
        },
        "trigger": dict(trigger or {}),
        "repro": dict(repro) if repro else None,
    }


def verify_packet(
    packet: Mapping[str, Any], *, trusted_source: str | None = None,
    trusted_excerpt: Mapping[str, Any] | None = None,
    expected_candidate_id: str | None = None, expected_source_path: str | None = None,
) -> list[str]:
    """Verify packet claims against coordinator-supplied source, never its status."""
    reasons = list(packet.get("reasons", []))
    source = packet.get("source")
    if not isinstance(source, Mapping):
        return [*reasons, "missing_source"]
    if expected_candidate_id is not None and packet.get("candidate_id") != expected_candidate_id:
        reasons.append("candidate_id_mismatch")
    if expected_source_path is not None and source.get("path") != expected_source_path:
        reasons.append("finding_source_path_mismatch")
    excerpt = source.get("excerpt")
    if not isinstance(excerpt, str) or len(excerpt.encode()) > MAX_EXCERPT_BYTES:
        reasons.append("invalid_excerpt")
    path, digest = source.get("path"), source.get("sha256")
    if not isinstance(path, str) or not path or path.startswith("/") or ".." in path.split("/") or not isinstance(digest, str) or len(digest) != 64 or any(char not in "0123456789abcdef" for char in digest):
        reasons.append("missing_source_identity")
    trigger = packet.get("trigger")
    if not isinstance(trigger, Mapping) or not isinstance(trigger.get("kind"), str) or not trigger["kind"] or not isinstance(trigger.get("value"), str) or not trigger["value"]:
        reasons.append("invalid_trigger")
    if trusted_source is None and trusted_excerpt is None:
        reasons.append("trusted_source_unavailable")
    elif trusted_source is not None and isinstance(excerpt, str):
        lines = trusted_source.splitlines(keepends=True)
        start, end = source.get("excerpt_start"), source.get("excerpt_end")
        if not isinstance(start, int) or not isinstance(end, int) or start < 1 or end < start or end > len(lines):
            reasons.append("invalid_excerpt_range")
        else:
            if hashlib.sha256(trusted_source.encode("utf-8")).hexdigest() != digest:
                reasons.append("trusted_source_sha256_mismatch")
            if "".join(lines[start - 1 : end]) != excerpt:
                reasons.append("trusted_excerpt_mismatch")
    elif isinstance(trusted_excerpt, Mapping):
        if source.get("path") != trusted_excerpt.get("path") or source.get("sha256") != trusted_excerpt.get("source_sha256") or source.get("excerpt_start") != trusted_excerpt.get("start_line") or source.get("excerpt_end") != trusted_excerpt.get("end_line") or not isinstance(excerpt, str) or excerpt.splitlines() != str(trusted_excerpt.get("text", "")).splitlines():
            reasons.append("trusted_excerpt_mismatch")
    if packet.get("status") != "verified":
        reasons.append("unverified_status")
    return list(dict.fromkeys(reasons))


def load_packets(path: Path) -> dict[str, dict[str, Any]]:
    """Read a bounded JSONL packet export; bad lines stay unavailable upstream."""
    if not path.is_file():
        return {}
    packets: dict[str, dict[str, Any]] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        try:
            packet = json.loads(line)
        except json.JSONDecodeError:
            continue
        candidate_id = str(packet.get("candidate_id", "")) if isinstance(packet, dict) else ""
        if candidate_id and candidate_id not in packets:
            packets[candidate_id] = packet
    return packets

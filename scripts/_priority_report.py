#!/usr/bin/env python3
"""Render the deterministic priority portion of a Bugsweep report."""

from __future__ import annotations

import json
import os
import stat
import sys
from pathlib import Path
from typing import Any


def _load(path: Path) -> dict[str, Any]:
    try:
        flags = (
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_NONBLOCK", 0)
        )
        fd = os.open(path, flags)
        try:
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                return {}
            raw = os.read(fd, 4 * 1024 * 1024 + 1)
        finally:
            os.close(fd)
        if len(raw) > 4 * 1024 * 1024:
            return {}
        value = json.loads(raw)
    except (OSError, ValueError):
        return {}
    return value if isinstance(value, dict) else {}


def _code(value: object) -> str:
    # JSON string escaping converts every control/newline/bidi code point to a
    # visible escape. Backticks need an explicit escape because JSON permits
    # them literally and they could otherwise break the Markdown code span.
    raw = str(value or "")[:4096]
    return json.dumps(raw, ensure_ascii=True)[1:-1].replace("`", "\\u0060")


def main() -> int:
    if len(sys.argv) != 2:
        return 2
    priority = _load(Path(sys.argv[1])).get("priority")
    if not isinstance(priority, dict):
        return 0

    print("## Priority focus (deterministic)")
    if priority.get("available") is not True:
        reason = _code(priority.get("degraded_reason") or "priority_context_unavailable")
        print(f"- Unavailable: {reason}.")
        print()
        return 0

    raw_application = priority.get("application")
    application = raw_application if isinstance(raw_application, dict) else {}
    if priority.get("application_available") is True:
        print(
            "- Applied: "
            f"{_code(application.get('promoted_batch_count', 0))} promoted batches / "
            f"{_code(application.get('added_file_count', 0))} added files; "
            f"{_code(application.get('skipped_candidate_count', 0))} "
            "candidates budget-limited or unmapped."
        )
    else:
        reason = _code(priority.get("application_reason") or "priority_application_unavailable")
        print(f"- Application unavailable: {reason}.")
    raw_health = priority.get("signal_health")
    health = raw_health if isinstance(raw_health, dict) else {}
    health_keys = ("accepted", "expired", "inactive", "malformed", "unmapped", "overmatched")
    print(
        "- Signal health: "
        + ", ".join(f"{key}={_code(health.get(key, 0))}" for key in health_keys)
        + "."
    )

    targets = priority.get("top_targets")
    if isinstance(targets, list):
        for target in targets[:10]:
            if not isinstance(target, dict):
                continue
            codes = target.get("reason_codes")
            code_text = (
                ",".join(_code(item) for item in codes[:20]) if isinstance(codes, list) else ""
            )
            print(
                f"- `{_code(target.get('file'))}` — {_code(target.get('lane'))} "
                f"score={_code(target.get('priority_score', 0))}; reasons={code_text or 'none'}; "
                f"outcome={_code(target.get('outcome'))}."
            )

    unmapped = priority.get("unmapped_focus_signals")
    if isinstance(unmapped, list):
        for item in unmapped[:10]:
            if not isinstance(item, dict):
                continue
            print(
                "- Unmapped signal: "
                f"{_code(item.get('source'))}:{_code(item.get('id'))} "
                f"component={_code(item.get('component')) or 'unknown'} "
                f"flow={_code(item.get('flow')) or 'unknown'}."
            )

    yields = priority.get("signal_yield")
    if isinstance(yields, list) and yields:
        print("- Historical attributed yield:")
        for item in yields[:10]:
            if not isinstance(item, dict):
                continue
            print(
                f"  - {_code(item.get('reason'))}: "
                f"attributed={_code(item.get('attributed', 0))}, "
                f"confirmed={_code(item.get('confirmed', 0))}, "
                f"rate={_code(item.get('confirmation_rate', 0))}."
            )
    print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

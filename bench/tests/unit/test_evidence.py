"""Source evidence packets must be bounded and content-bound."""

import hashlib
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from bench.scorer.evidence import build_packet, load_packets, verify_packet


def test_packet_binds_bounded_source_trigger_and_repro() -> None:
    source = "one\ntwo\nthree\n"
    packet = build_packet(
        candidate_id="c1",
        source_path="src/app.py",
        source=source,
        source_sha256=hashlib.sha256(source.encode()).hexdigest(),
        excerpt_start=2,
        excerpt_end=2,
        trigger={"kind": "request", "value": "/search?q=x"},
        repro={"path": "repro.json", "sha256": "a" * 64},
    )
    assert packet["status"] == "verified"
    assert packet["source"]["excerpt"] == "two\n"
    assert verify_packet(packet, trusted_source=source, expected_candidate_id="c1") == []


def test_forged_verified_packet_cannot_self_authenticate() -> None:
    packet = {"candidate_id": "c1", "status": "verified", "reasons": [], "source": {"path": "a.py", "sha256": "a" * 64, "excerpt_start": 1, "excerpt_end": 1, "excerpt": "forged\n"}, "trigger": {}}
    assert verify_packet(packet, trusted_source="real\n", expected_candidate_id="c1")


def test_wrong_source_digest_is_unverified_without_judging() -> None:
    packet = build_packet(
        candidate_id="c1",
        source_path="src/app.py",
        source="code\n",
        source_sha256="0" * 64,
        excerpt_start=1,
        excerpt_end=1,
        trigger={"kind": "request", "value": "x"},
        repro=None,
    )
    assert packet["status"] == "unverified"
    assert "source_sha256_mismatch" in packet["reasons"]


def test_packet_rejects_oversized_excerpt() -> None:
    source = "x\n" * 300
    packet = build_packet(
        candidate_id="c1",
        source_path="src/app.py",
        source=source,
        source_sha256=hashlib.sha256(source.encode()).hexdigest(),
        excerpt_start=1,
        excerpt_end=300,
        trigger={"kind": "request", "value": "x"},
        repro=None,
    )
    assert packet["status"] == "unverified"
    assert "excerpt_too_large" in packet["reasons"]


def test_load_packets_keeps_first_packet_for_each_candidate(tmp_path) -> None:
    first = build_packet(candidate_id="c1", source_path="a.py", source="x\n", source_sha256=hashlib.sha256(b"x\n").hexdigest(), excerpt_start=1, excerpt_end=1, trigger={"kind": "x"}, repro=None)
    duplicate = {**first, "status": "unverified"}
    path = tmp_path / "precision-evidence.jsonl"
    path.write_text(__import__("json").dumps(first) + "\n" + __import__("json").dumps(duplicate) + "\n")
    assert load_packets(path)["c1"]["status"] == "verified"

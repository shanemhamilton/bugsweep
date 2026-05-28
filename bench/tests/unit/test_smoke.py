"""Smoke test confirming the pytest + coverage scaffolding resolves.

This trivial test exists so ``pytest`` exits 0 at the repo root before the
scorer package (WU4) lands. It also keeps ``bench/tests/unit`` importable.
"""


def test_smoke() -> None:
    """The harness Python toolchain is wired up and collectable."""
    assert True

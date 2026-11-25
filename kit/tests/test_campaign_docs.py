#!/usr/bin/env python3
"""Consistency checks for the canonical campaign documentation."""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CAMPAIGN = (ROOT / "game/CAMPAIGN.md").read_text()
MAKEFILE = (ROOT / "Makefile").read_text()


def test_route_stages_are_documented() -> None:
    for stage in ("opening", "dungeon", "palace", "first_town", "world"):
        assert stage in CAMPAIGN


def test_world_handoff_is_documented() -> None:
    assert "world_a" in CAMPAIGN and "640,480" in CAMPAIGN


def test_derived_values_are_labeled() -> None:
    assert "derived" in CAMPAIGN.lower()
    assert "1280x960" in CAMPAIGN


def test_save_fields_are_documented() -> None:
    for field in ("reserves", "route checkpoint", "extras"):
        assert field in CAMPAIGN


def test_make_check_is_present() -> None:
    assert "check: canonical-assets" in MAKEFILE
    assert "test_check_journey_package.py" in MAKEFILE


if __name__ == "__main__":
    tests = [(name, fn) for name, fn in sorted(globals().items()) if name.startswith("test_") and callable(fn)]
    failed = 0
    for name, fn in tests:
        try:
            fn()
        except Exception as exc:  # noqa: BLE001
            failed += 1
            print("FAIL %s: %s: %s" % (name, type(exc).__name__, exc))
        else:
            print("ok   %s" % name)
    print("\n%d passed, %d failed" % (len(tests) - failed, failed))
    sys.exit(1 if failed else 0)

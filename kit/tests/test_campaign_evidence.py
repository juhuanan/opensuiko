#!/usr/bin/env python3
"""Evidence boundaries for derived canonical content."""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIRST_TOWN = ROOT / "game/assets/campaign/opening/first_town"


def test_no_first_town_choice_commands() -> None:
    for path in FIRST_TOWN.glob("*.json"):
        data = json.loads(path.read_text())
        for program in data.get("programs", []):
            kinds = {command.get("kind") for command in program.get("commands", [])}
            assert "choice" not in kinds and "branch_choice" not in kinds, (path.name, program.get("id"))


def test_opening_battles_reference_va2_not_vaa() -> None:
    data = json.loads((ROOT / "game/assets/campaign/opening/opening_battles.json").read_text())
    serialized = json.dumps(data)
    assert "VA2" in serialized
    assert "VAA" not in serialized


def test_world_travel_exporter_is_scoped_to_b_and_c() -> None:
    text = (ROOT / "kit/tools/export_world_travel.py").read_text()
    assert "region_b" in text and "region_c" in text
    assert "region_a" not in text


def test_campaign_documents_the_derived_patrol() -> None:
    text = (ROOT / "game/CAMPAIGN.md").read_text()
    assert "Derived world patrol" in text
    assert "not recovered source behavior" in text


def test_canonical_field_rooms_use_source_scenery_and_event_doors() -> None:
    package = json.loads((ROOT / "kit/work/build/canonical/room.json").read_text())
    events = json.loads((ROOT / "kit/work/build/canonical/battle/field_events.json").read_text())
    field_rooms = {binding['room'] for binding in events['rooms']}
    for room in package["rooms"]:
        if room['id'] in field_rooms:
            assert not room.get("exits"), room["id"]
            assert room['scenery_atlas'] == f"field/{room['id']}.png", room['id']


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

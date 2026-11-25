#!/usr/bin/env python3
"""Idempotence and schema tests for the canonical tooling."""
from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "kit/tools"))
import check_journey_package as checker  # noqa: E402

CANONICAL = ROOT / "kit/work/build/canonical"


def _mutated(mutator) -> list[str]:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "package"
        shutil.copytree(CANONICAL, root)
        mutator(root)
        return checker.check(root)


def _expect(mutator, needle: str) -> None:
    errors = _mutated(mutator)
    assert any(needle in error for error in errors), errors


def test_profile_export_is_idempotent() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        candidate = Path(tmp) / "package"
        shutil.copytree(CANONICAL / "battle", candidate / "battle")
        for name in ("journey.json", "room.json"):
            shutil.copy2(CANONICAL / name, candidate / name)
        atlas = candidate / "battle/actors.png"
        before = hashlib.sha256(atlas.read_bytes()).hexdigest()
        result = subprocess.run(
            [sys.executable, str(ROOT / "kit/tools/export_opening_profiles.py"),
             "--out", str(candidate), "--work", str(Path(tmp) / "work")],
            capture_output=True, text=True,
        )
        assert result.returncode == 0, result.stdout + result.stderr
        assert before == hashlib.sha256(atlas.read_bytes()).hexdigest()
        assert "already present" in result.stdout


def test_luc_counter_strike_has_its_source_poses() -> None:
    from export_opening_profiles import reaction_animations

    actors = json.loads((CANONICAL / "battle/unites.json").read_text())
    clips = reaction_animations(actors)["luc"]
    assert {7, 8, 9, 11} <= clips
    trial = json.loads((CANONICAL / "battle/trial.json").read_text())
    graphic = next(row for row in trial["unite_graphics"] if row["id"] == "luc" and row.get("record") is None)
    assert {6, 7, 8} <= {pose["id"] for pose in graphic["poses"]}


def test_bad_journey_schema() -> None:
    def mutate(root: Path) -> None:
        journey = json.loads((root / "journey.json").read_text())
        journey["schema"] = "wrong"
        (root / "journey.json").write_text(json.dumps(journey))
    _expect(mutate, "journey.json schema")


def test_bad_clip_direction() -> None:
    def mutate(root: Path) -> None:
        package = json.loads((root / "room.json").read_text())
        package["player_clips"][0]["direction"] = "left"
        (root / "room.json").write_text(json.dumps(package))
    _expect(mutate, "down/up/left/right order")


def test_bad_draw_depth() -> None:
    def mutate(root: Path) -> None:
        package = json.loads((root / "room.json").read_text())
        package["rooms"][0]["draws"][0]["depth"] = "near"
        (root / "room.json").write_text(json.dumps(package))
    _expect(mutate, "draw depth is not an integer")


def test_canonical_requires_world_segment() -> None:
    def mutate(root: Path) -> None:
        package = json.loads((root / "room.json").read_text())
        package["rooms"] = [room for room in package["rooms"] if room["id"] != "world_a"]
        (root / "room.json").write_text(json.dumps(package))
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "package"
        shutil.copytree(CANONICAL, root)
        mutate(root)
        errors = checker.check(root, canonical=True)
        assert any("world_a" in error for error in errors), errors


def test_canonical_start_room() -> None:
    def mutate(root: Path) -> None:
        package = json.loads((root / "room.json").read_text())
        package["start_room"] = "va1_room_0"
        (root / "room.json").write_text(json.dumps(package))
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "package"
        shutil.copytree(CANONICAL, root)
        mutate(root)
        errors = checker.check(root, canonical=True)
        assert any("does not start" in error for error in errors), errors


def test_canonical_room_set() -> None:
    def mutate(root: Path) -> None:
        package = json.loads((root / "room.json").read_text())
        package["rooms"] = [room for room in package["rooms"] if room["id"] != "va1_room_2"]
        (root / "room.json").write_text(json.dumps(package))
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "package"
        shutil.copytree(CANONICAL, root)
        mutate(root)
        errors = checker.check(root, canonical=True)
        assert any("missing rooms" in error for error in errors), errors


def test_canonical_patrol_contract() -> None:
    def mutate(root: Path) -> None:
        journey = json.loads((root / "journey.json").read_text())
        journey["encounters"] = [entry for entry in journey["encounters"] if entry["id"] != "world_patrol"]
        (root / "journey.json").write_text(json.dumps(journey))
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "package"
        shutil.copytree(CANONICAL, root)
        mutate(root)
        errors = checker.check(root, canonical=True)
        assert any("world patrol" in error for error in errors), errors


def test_world_collision_uses_source_threshold() -> None:
    package = json.loads((CANONICAL / "room.json").read_text())
    world = next(room for room in package["rooms"] if room["id"] == "world_a")
    assert world["walkable"].count("1") == 5849
    assert world["walkable"].count("0") == 13351


def test_canonical_audio_files() -> None:
    def mutate(root: Path) -> None:
        (root / "audio/palace.wav").unlink()
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "package"
        shutil.copytree(CANONICAL, root)
        mutate(root)
        errors = checker.check(root, canonical=True)
        assert any("audio/palace.wav" in error for error in errors), errors


def test_required_file_list() -> None:
    result = subprocess.run([str(ROOT / ".venv/bin/python"), str(ROOT / "kit/tools/check_journey_package.py"), "--list-required"], capture_output=True, text=True, check=True)
    names = result.stdout.split()
    assert "room.json" in names and "party/catalogue.json" in names


def test_missing_bindings() -> None:
    def mutate(root: Path) -> None:
        (root / "party/ownership_bindings.json").unlink()
    _expect(mutate, "missing party/ownership_bindings.json")


if __name__ == "__main__":
    if not CANONICAL.is_dir():
        print("SKIP: canonical package has not been generated")
        sys.exit(0)
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

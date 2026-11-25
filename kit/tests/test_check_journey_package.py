#!/usr/bin/env python3
"""Mutation tests for the canonical package checker."""
from __future__ import annotations

import json
import shutil
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "kit/tools"))
import check_journey_package as checker  # noqa: E402
from room_battle_package import PATH as ROOM_BATTLE_PATH  # noqa: E402

CANONICAL = ROOT / "kit/work/build/canonical"


def _mutated(mutator) -> list[str]:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "package"
        shutil.copytree(CANONICAL, root)
        mutator(root)
        return checker.check(root)


def _load(root: Path, name: str) -> dict:
    return json.loads((root / name).read_text())


def _save(root: Path, name: str, value: dict) -> None:
    (root / name).write_text(json.dumps(value))


def _expect(mutator, needle: str) -> None:
    errors = _mutated(mutator)
    assert any(needle in error for error in errors), errors


def _legacy_dialogue(package, kind):
    fixture = json.loads((ROOT / 'game/tests/fixtures/journey_room.json').read_bytes())
    row = next(row for room in fixture['rooms'] for row in room.get(kind, []))
    room = next(room for room in package['rooms'] if room['id'] == package['start_room'])
    row.update(x=package['start_x'], y=package['start_y'])
    if kind == 'events':
        row.update(w=8, h=8)
    room[kind].append(row)
    return row


def test_shared_strike_package_requires_reactions_for_encountered_enemies() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / 'battle').mkdir()
        trial = {'encounters': [{'enemies': ['covered', 'missing', 'missing']},
                                {'enemies': ['missing', 'incomplete']}]}
        _save(root, 'battle/trial.json', trial)
        _save(root, 'battle/unites.json', {'counter': {'party_melee': []}})
        _save(root, 'battle/spells.json', {'hurt_poses': [
            {'id': 'covered', 'entry': 0, 'impact_offset': [0, 0], 'white_entry': 0,
             'knockout': {'entry': 0, 'duration': 1}},
            {'id': 'incomplete', 'entry': 0, 'impact_offset': [0, 0],
             'knockout': {'entry': 0, 'duration': 1}},
        ]})
        failures = [error for error in checker.check(root) if 'MissingCounterKnockout' in error]
        assert failures == [
            "battle/spells.json: MissingCounterKnockout for enemy 'incomplete'",
            "battle/spells.json: MissingCounterKnockout for enemy 'missing'",
        ]
        _save(root, 'battle/unites.json', {'counter': {'melee': {}}})
        assert not any('MissingCounterKnockout' in error for error in checker.check(root))


def test_battlefield_tiles_are_relative_to_the_bound_atlas_region() -> None:
    from PIL import Image

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / 'battle').mkdir()
        Image.new('RGB', (64, 32)).save(root / 'battle/ground.png')
        field = dict(id='ridge', ground_atlas=dict(x=32, y=0, w=32, h=32), ground=dict(tiles=[0]))
        encounter = dict(id='test', battlefield='ridge')
        trial = dict(battlefields=[field], encounters=[encounter])
        errors = []
        checker.check_battlefield_assets(root, trial, errors)
        assert not errors, errors

        field['ground']['tiles'][0] = 1
        encounter['battlefield'] = 'missing'
        checker.check_battlefield_assets(root, trial, errors)
        assert errors == [
            'battle encounter test references unknown battlefield missing',
            'battlefield ridge tile is outside its ground atlas region',
        ], errors


def test_invalid_room_battle_resource_fails_package_check() -> None:
    def mutate(root: Path) -> None:
        _save(root, ROOM_BATTLE_PATH, {'schema': 'suikoden-battle-field-events/3', 'rooms': []})

    _expect(mutate, f'{ROOM_BATTLE_PATH}: rooms must contain at least one binding')


def test_movement_encounter_candidates_must_match_packaged_enemy_levels() -> None:
    def bind(root: Path, adjustment: int) -> None:
        room = _load(root, 'room.json')['rooms'][0]['id']
        trial = _load(root, 'battle/trial.json')
        levels = {enemy['id']: enemy['level'] for enemy in trial['enemies']}
        encounter = trial['encounters'][0]
        level_sum = sum(levels[enemy] for enemy in encounter['enemies'])
        journey = _load(root, 'journey.json')
        journey['field_encounters'] = dict(schema='suikoden-field-movement-encounters/1', rooms=[
            dict(room=room, rate=2, counter_threshold=60,
                 candidates=[dict(id=encounter['id'], enemy_level_sum=level_sum + adjustment)]),
        ])
        _save(root, 'journey.json', journey)

    assert _mutated(lambda root: bind(root, 0)) == []
    _expect(lambda root: bind(root, 1), 'invalid movement encounter level sum')


def test_room_battle_portrait_must_fit_field_atlas() -> None:
    def mutate(root: Path) -> None:
        room = _load(root, 'room.json')['rooms'][0]['id']
        _save(root, ROOM_BATTLE_PATH, dict(schema='suikoden-battle-field-events/4', rooms=[
            dict(room=room, dialogue=dict(schema='suikoden-field-dialogue/8', images=[
                dict(id='test_portrait', atlas_rect=dict(x=99999, y=0, w=64, h=64)),
            ])),
        ]))

    _expect(mutate, "portrait 'test_portrait' is outside the field atlas")


def test_invalid_walkable_character() -> None:
    def mutate(root: Path) -> None:
        package = _load(root, "room.json")
        package["rooms"][0]["walkable"] = "2" + package["rooms"][0]["walkable"][1:]
        _save(root, "room.json", package)
    _expect(mutate, "walkable contains characters")


def test_duplicate_room_id() -> None:
    def mutate(root: Path) -> None:
        package = _load(root, "room.json")
        package["rooms"].append(dict(package["rooms"][0]))
        _save(root, "room.json", package)
    _expect(mutate, "room IDs are not unique")


def test_unwalkable_start() -> None:
    def mutate(root: Path) -> None:
        package = _load(root, "room.json")
        room = next(item for item in package["rooms"] if item["id"] == package["start_room"])
        index = (package["start_y"] // 8) * (room["width"] // 8) + package["start_x"] // 8
        room["walkable"] = room["walkable"][:index] + "0" + room["walkable"][index + 1:]
        _save(root, "room.json", package)
    _expect(mutate, "start position is not walkable")


def test_exit_spawn_outside_destination() -> None:
    def mutate(root: Path) -> None:
        package = _load(root, "room.json")
        next(room for room in package["rooms"] if room.get("exits"))["exits"][0]["spawn_x"] = 99999
        _save(root, "room.json", package)
    _expect(mutate, "exit spawn is outside")


def test_empty_npc_page() -> None:
    def mutate(root: Path) -> None:
        package = _load(root, "room.json")
        npc = _legacy_dialogue(package, "npcs")
        npc["pages"] = [""]
        _save(root, "room.json", package)
    _expect(mutate, "has an empty page")


def test_missing_ui_font() -> None:
    def mutate(root: Path) -> None:
        (root / "ui.json").unlink()
    _expect(mutate, "missing ui.json")


def test_bad_ui_window_role() -> None:
    def mutate(root: Path) -> None:
        ui = _load(root, "ui.json")
        ui["window"][0]["role"] = "top_left"
        _save(root, "ui.json", ui)
    _expect(mutate, "duplicate window role")


def test_overlong_dialogue_page() -> None:
    def mutate(root: Path) -> None:
        package = _load(root, "room.json")
        npc = _legacy_dialogue(package, "npcs")
        npc["pages"] = ["\n".join("line" for _ in range(9))]
        _save(root, "room.json", package)
    _expect(mutate, "more than 8 lines")


def test_bad_attack_frame() -> None:
    def mutate(root: Path) -> None:
        trial = _load(root, "battle/trial.json")
        trial["party"][0]["attack"][0]["pose"]["rect"]["w"] = 99999
        _save(root, "battle/trial.json", trial)
    _expect(mutate, "attack frame")


def test_source_ranged_attack_requires_programs_resource_and_valid_art() -> None:
    sprite = {"rect": {"x": 0, "y": 0, "w": 8, "h": 8}}
    trial = {"unite_graphics": [{"id": "eileen", "poses": [{"sprite": sprite}]}]}
    binding = {"id": "eileen", "attack_program": "a", "return_program": "b", "hurt_program": "c"}
    library = {"counter": {"ranged": {"attackers": [binding]}},
               "programs": {"programs": [{"id": name} for name in ("a", "b", "c")]},
               "animations": {"resources": [{"id": "eileen"}]}}
    assert checker.ranged_attackers(trial, library, (8, 8)) == {"eileen"}
    library["programs"]["programs"].pop()
    assert not checker.ranged_attackers(trial, library, (8, 8))
    library["programs"]["programs"].append({"id": "c"})
    assert not checker.ranged_attackers(trial, library, (7, 8))
    library["animations"]["resources"].clear()
    assert not checker.ranged_attackers(trial, library, (8, 8))


def test_missing_party_catalogue() -> None:
    def mutate(root: Path) -> None:
        (root / "party/catalogue.json").unlink()
    _expect(mutate, "missing party/catalogue.json")


def test_bad_catalogue_schema() -> None:
    def mutate(root: Path) -> None:
        catalogue = _load(root, "party/catalogue.json")
        catalogue["schema"] = "wrong"
        _save(root, "party/catalogue.json", catalogue)
    _expect(mutate, "wrong schema or character count")


def test_bad_ted_binding() -> None:
    def mutate(root: Path) -> None:
        bindings = _load(root, "party/ownership_bindings.json")
        bindings["ted"]["rune_id"] = "wrong"
        _save(root, "party/ownership_bindings.json", bindings)
    _expect(mutate, "Ted ownership binding is incomplete")


def test_placeholder_room_title() -> None:
    def mutate(root: Path) -> None:
        package = _load(root, "room.json")
        package["rooms"][0]["title"] = "Placeholder room"
        _save(root, "room.json", package)
    _expect(mutate, "placeholder text")


def test_placeholder_journey_title() -> None:
    def mutate(root: Path) -> None:
        journey = _load(root, "journey.json")
        journey["title"] = "TODO"
        _save(root, "journey.json", journey)
    _expect(mutate, "placeholder text")


def test_placeholder_npc_page() -> None:
    def mutate(root: Path) -> None:
        package = _load(root, "room.json")
        npc = _legacy_dialogue(package, "npcs")
        npc["pages"] = ["Lorem ipsum dolor sit amet"]
        _save(root, "room.json", package)
    _expect(mutate, "placeholder text")


def test_placeholder_npc_name() -> None:
    def mutate(root: Path) -> None:
        package = _load(root, "room.json")
        npc = _legacy_dialogue(package, "npcs")
        npc["name"] = "TBD"
        _save(root, "room.json", package)
    _expect(mutate, "placeholder text")


def test_encounter_outside_room() -> None:
    def mutate(root: Path) -> None:
        journey = _load(root, "journey.json")
        journey["encounters"][0]["x"] = 99999
        _save(root, "journey.json", journey)
    _expect(mutate, "outside its room")


def test_duplicate_encounter_flags() -> None:
    def mutate(root: Path) -> None:
        journey = _load(root, "journey.json")
        journey["encounters"].append(dict(journey["encounters"][0], id="duplicate"))
        _save(root, "journey.json", journey)
    _expect(mutate, "flags are not unique")


def test_encounter_with_no_walkable_cell() -> None:
    def mutate(root: Path) -> None:
        package = _load(root, "room.json")
        journey = _load(root, "journey.json")
        room = next(room for room in package["rooms"] if room["id"] == journey["encounters"][0]["room"])
        room["walkable"] = "0" * len(room["walkable"])
        _save(root, "room.json", package)
    _expect(mutate, "covers no walkable cell")


def test_misaligned_encounter() -> None:
    def mutate(root: Path) -> None:
        journey = _load(root, "journey.json")
        journey["encounters"][0]["x"] += 1
        _save(root, "journey.json", journey)
    _expect(mutate, "not cell-aligned")


def test_encounter_zero_size() -> None:
    def mutate(root: Path) -> None:
        journey = _load(root, "journey.json")
        journey["encounters"][0]["w"] = 0
        _save(root, "journey.json", journey)
    _expect(mutate, "invalid size")


def test_overlong_dialogue_line() -> None:
    def mutate(root: Path) -> None:
        package = _load(root, "room.json")
        npc = _legacy_dialogue(package, "npcs")
        npc["pages"] = ["x" * 61]
        _save(root, "room.json", package)
    _expect(mutate, "exceeds 60 characters")


def test_placeholder_event_page() -> None:
    def mutate(root: Path) -> None:
        package = _load(root, "room.json")
        event = _legacy_dialogue(package, "events")
        event["pages"] = ["TODO event"]
        _save(root, "room.json", package)
    _expect(mutate, "placeholder text")


def test_missing_initial_party_profile() -> None:
    def mutate(root: Path) -> None:
        trial = _load(root, "battle/trial.json")
        trial["initial_party"] = list(trial["initial_party"]) + ["missing_member"]
        _save(root, "battle/trial.json", trial)
    _expect(mutate, "has no profile")


def test_movies_manifest_must_keep_media_gate() -> None:
    def mutate(root: Path) -> None:
        _save(root, "video/movies.json", {
            "schema": "suikoden-movies/1",
            "decoder": "kit/tools/str_decode.py",
            "media_accepted": True,
            "movies": [
                {"id": "logo", "frames": 114, "fps": 15, "duration_ms": 7600, "media_accepted": False},
                {"id": "opening", "frames": 1647, "fps": 15, "duration_ms": 109800, "media_accepted": False},
                {"id": "attract", "frames": 1688, "fps": 15, "duration_ms": 112533, "media_accepted": False},
            ],
        })
    _expect(mutate, "media_accepted must remain false")


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

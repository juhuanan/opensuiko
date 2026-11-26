#!/usr/bin/env python3
"""Check the runtime, platform, and build-tool import boundaries."""
import re
from collections.abc import Iterator
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GAME = ROOT / "game"
RUNTIME = GAME / "src"

# Keep the external API at these adapters. Draw-list models such as world_view
# and war_view are headless and can be consumed on either side of this boundary.
RAYLIB_FILES = frozenset("""
    audio_player.zig battle_effect_palette.zig battle_ground_view.zig
    battle_spell_view.zig battle_trial_view.zig battle_world_view.zig
    controller_platform.zig dice_view.zig field_view.zig item_overload_view.zig
    journey_frame.zig journey_frame/atlas_checks.zig journey_frame/input.zig
    journey_frame/render.zig journey_frame/resources.zig journey_main.zig
    menu_view.zig movie_player.zig party_view.zig raylib_app.zig settings_platform.zig
    side_game_view.zig title_view.zig ui.zig war_audio_platform.zig
    war_mode.zig war_view_platform.zig
""".split())
OPENING_ASSEMBLY = frozenset({
    'campaign/opening_export.zig', 'campaign/opening_package.zig', 'campaign/opening_launch.zig',
})

# Skip comments and quoted literals so source examples cannot introduce a dependency.
IMPORT_TOKEN = re.compile(r'''//[^\n]*|\\\\[^\n]*|"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'|@import\b|[()]''')


def imports(source: Path) -> Iterator[str]:
    tokens = (token for token in IMPORT_TOKEN.findall(source.read_text()) if not token.startswith(('//', '\\\\')))
    for token in tokens:
        if token == '@import':
            opening, name, closing = next(tokens, ''), next(tokens, ''), next(tokens, '')
            assert opening == '(' and name.startswith('"') and closing == ')', f'{source}: expected literal Zig import'
            yield name[1:-1]


def registered_modules() -> dict[str, Path]:
    registry = (GAME / 'build.zig').read_text()
    entries = re.findall(r'^\s*\.\{\s*"([^"]+)",\s*"((?:src|assets)/[^"]+\.zig)"', registry, re.MULTILINE)
    entries += re.findall(r'\br\.addData\("([^"]+)",\s*"([^"]+\.zig)"\)', registry)
    modules = {name: GAME / path for name, path in entries}
    for alias, module in re.findall(r'\br\.bind\("([^"]+)",\s*"([^"]+)"\)', registry):
        modules[alias] = modules[module]
    return modules


def dependency_paths(entry: Path, modules: dict[str, Path]) -> Iterator[tuple[Path, ...]]:
    """Yield one import chain from entry to each reachable source or raylib."""
    pending = [(entry,)]
    seen = {entry}
    while pending:
        chain = pending.pop()
        for name in imports(chain[-1]):
            if name in {'std', 'builtin'} or name.endswith('.zon'):
                continue
            if name == 'raylib':
                target = GAME / 'raylib'
            elif name.endswith('.zig'):
                target = (chain[-1].parent / name).resolve()
            else:
                assert name in modules, f'{chain[-1]}: unresolved Zig module {name!r}'
                target = modules[name]
            if target in seen:
                continue
            seen.add(target)
            path = (*chain, target)
            yield path
            if name != 'raylib':
                pending.append(path)


def show_chain(chain: tuple[Path, ...]) -> str:
    return ' -> '.join(str(path.relative_to(ROOT)) for path in chain)


def test_raylib_imports_stay_in_platform_adapters() -> None:
    for source in sorted(RUNTIME.rglob('*.zig')):
        if 'raylib' in imports(source):
            assert source.relative_to(RUNTIME).as_posix() in RAYLIB_FILES, f'{source}: raylib belongs in platform adapters'


def test_headless_runtime_cannot_reach_the_platform() -> None:
    modules = registered_modules()
    platform = {RUNTIME / name for name in RAYLIB_FILES} | {GAME / 'raylib'}
    for name in ('engine', 'journey_boot', 'field', 'battle', 'event_runtime'):
        for chain in dependency_paths(modules[name], modules):
            assert chain[-1] not in platform, show_chain(chain)


def test_runtime_cannot_reach_build_tools() -> None:
    modules = registered_modules()
    assembly = {RUNTIME / name for name in OPENING_ASSEMBLY}
    for name in ('journey_boot', 'journey_frame', 'journey_persistence', 'war_mode'):
        for chain in dependency_paths(modules[name], modules):
            target = chain[-1]
            assert target not in assembly and not target.is_relative_to(RUNTIME / 'compiler'), show_chain(chain)
    # The launcher also dispatches export mode. That path may reach the opening
    # assembler, while the disc compiler remains its own executable.
    for chain in dependency_paths(RUNTIME / 'journey_main.zig', modules):
        assert not chain[-1].is_relative_to(RUNTIME / 'compiler'), show_chain(chain)


def test_launcher_has_no_runtime_merge_fallback() -> None:
    text = (RUNTIME / "journey_main.zig").read_text()
    assert "mergeOpeningRooms" not in text
    assert "opening/scene.json" not in text


def test_launcher_uses_export_mode_only_for_export() -> None:
    text = (RUNTIME / "journey_main.zig").read_text()
    assert text.count("opening_export") == 3  # import + export mode call
    assert "--export-opening" in text


def test_menus_use_the_source_window_not_the_prototype_panel() -> None:
    menu = (ROOT / "game/src/menu_view.zig").read_text()
    title = (ROOT / "game/src/title_view.zig").read_text()
    assert "context.window(rect.x, rect.y, rect.w, rect.h)" in menu
    assert "ui.panel" not in menu
    assert "context.window(40, 54, 560, 370)" in title


def test_party_catalogue_is_separate_from_roster() -> None:
    session = (ROOT / "game/src/party_session/session.zig").read_text()
    catalogue = (ROOT / "game/src/party_session/catalogue.zig").read_text()
    assert "pub const Catalogue" not in session
    assert "pub const Catalogue" in catalogue
    assert '@import("catalogue.zig")' in session


def test_party_rules_do_not_depend_on_battle_state() -> None:
    modules = registered_modules()
    for name in ('party_session', 'recruitment', 'opening_party', 'item_ledger'):
        for chain in dependency_paths(modules[name], modules):
            assert chain[-1] != modules['battle'], show_chain(chain)


def test_roster_changes_and_battle_retry_do_not_import_save_code() -> None:
    for name in ('journey_roster.zig', 'journey_battle.zig'):
        assert 'journey_save.zig' not in imports(RUNTIME / name)


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
    raise SystemExit(1 if failed else 0)

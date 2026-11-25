#!/usr/bin/env python3
"""Runtime must not depend on the build-time opening package assembler."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RUNTIME = ROOT / "game/src"


def test_engine_does_not_import_export_code() -> None:
    for name in ("journey.zig", "field.zig", "engine.zig"):
        text = (RUNTIME / name).read_text()
        assert "campaign/export" not in text
        assert "opening_package" not in text


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

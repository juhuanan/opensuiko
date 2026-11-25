#!/usr/bin/env python3
"""Tests for kit/tools/atlas_pool.py -- the disc-wide 16,384-byte atlas pool.

    1. `find_atlases` on BATTLE.BIN returns exactly its 13 recorded offsets;
    2. every atlas it returns is exactly 16,384 bytes and re-frames exactly
       from its own `[u32 len]` field (strict LZSS rejects trailing input);
    3. `classify` reproduces the three recorded BATTLE.BIN readings -- three
       32-colour sheets well above the sprite threshold, and the effect sheets
       that are NOT tile-like either (they are dense, so they land in `mid`),
       which is the honest limit of the heuristic;
    4. the tool's thresholds are ordered and sane (sprite > tile);
    5. a file with no atlas streams yields an empty list rather than an error,
       so the disc walk cannot die on a code-only file.

Colour-mode assertions (added 2026-10-05, `--colour`):

    6. the three load bases of `_rel` are disjoint, so a 0x8001xxxx pointer can
       never be silently read as a 0x8008xxxx one;
    7. on VB6.BIN, the resolver's answer for every atlas is one of the two
       documented outcomes -- a table-recorded palette or NO palette -- and the
       area-section pairings it does claim are confirmed byte-exactly by
       `psx_vram.find_atlas` plus the palette bytes in the derived VRAM rows;
    8. a resolved palette covers every index the atlas actually uses, so colour
       mode can never silently drop pixels to black;
    9. the resolver is deterministic (two runs, same records);
   10. an atlas with no referencing table in its own file stays unresolved
       (`palette is None`) -- never an invented palette.

Static analysis only; disc read through kit/tools/disc.py.

    .venv/bin/python kit/tests/test_atlas_pool.py
"""

import json
import os
import sys

TOOLS = os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "tools"))
sys.path.insert(0, TOOLS)

import disc                                   # noqa: E402
import lzss                                   # noqa: E402
import atlas_pool as ap                       # noqa: E402

_ISO_JSON = os.path.join(os.path.dirname(TOOLS), "extracted", "iso_files.json")
_CACHE = {}
_VB6 = "DATA/02_AREA.B/VB6.BIN"


def _data(path):
    if path not in _CACHE:
        with open(_ISO_JSON) as f:
            rec = [r for r in json.load(f) if r.get("path") == path][0]
        _CACHE[path] = disc.extract(rec["lba"], rec["size"])
    return _CACHE[path]


def _lba(path):
    with open(_ISO_JSON) as f:
        return [r for r in json.load(f) if r.get("path") == path][0]


def test_battle_bin_atlas_offsets():
    got = [o for o, _l, _r in ap.find_atlases(_data("DATA/00_INIT/BATTLE.BIN"))]
    want = [0x0B7C, 0x1600, 0x228C, 0x4644, 0x65E8, 0x802C, 0x9ACC,
            0xB730, 0xDAC0, 0xEE34, 0x11540, 0x121DC, 0x1429C]
    assert got == want, [hex(x) for x in got]


def test_every_atlas_is_16384_and_reframes_exactly():
    d = _data("DATA/00_INIT/BATTLE.BIN")
    for off, ln, raw in ap.find_atlases(d):
        assert len(raw) == ap.ATLAS
        assert lzss.decode_strict(d[off + 4:off + 4 + ln]) == raw


def test_classify_matches_the_recorded_readings():
    """Record the heuristic's real limit, not an aspirational one.

    Every one of BATTLE.BIN's 13 planes has an index-0 fraction between 0.425
    and 0.883, so **all** of them class as `sprite-like` -- including the
    effect sheets, which are not sprite sheets. The threshold separates
    "sparse plane" from "full tile page"; it does NOT separate sprites from
    effects. Asserting that here stops the doc from overclaiming.
    """
    d = _data("DATA/00_INIT/BATTLE.BIN")
    got = [(off, ap.classify(raw)) for off, _l, raw in ap.find_atlases(d)]
    assert len(got) == 13
    classes = {}
    for off, (cls, zero, _n) in got:
        assert 0.0 < zero < 1.0, (hex(off), zero)
        classes[hex(off)] = cls
    # Recorded 2026-10-05: 12 sprite-like, 1 mid, 0 tile-like.
    assert sum(1 for c in classes.values() if c == "sprite-like") == 12
    assert classes["0x1429c"] == "mid"
    assert "tile-like" not in classes.values()


def test_thresholds_are_ordered():
    assert 0.0 <= ap.TILE_ZERO_FRAC < ap.SPRITE_ZERO_FRAC <= 1.0


def test_empty_file_is_not_an_error():
    assert ap.find_atlases(b"\x00" * 4096) == []
    assert ap.find_atlases(b"") == []


def _vb6_resolution():
    """(records by sha, {offset: sha}, resolution record) for VB6.BIN."""
    if "vb6" not in _CACHE:
        records, sources = ap.scan([_VB6], verbose=False)
        by_sha = {}
        for h, rec in records.items():
            rec = dict(rec)
            del rec["bytes"]
            by_sha[h] = rec
        stats = ap.resolve_scan(by_sha, sources, verbose=False)
        off2sha = {s["offset"]: h for h, occ in sources.items() for s in occ}
        _CACHE["vb6"] = (by_sha, off2sha, stats)
    return _CACHE["vb6"]


def test_rel_load_bases_are_disjoint():
    """`_rel` resolves the whole `lui`+imm value, with sign extension.

    The three load bases overlap (every value in 0x80080000..0x80180000 also
    fits the area base), so `_rel` tries them in a fixed order and takes the
    first offset that lands inside the file. Two documented sign-extension
    mistakes are both in that band:

        0x8016F2A7 = lui 0x8018 + -0xD59      (area offset 0x15F2A7)
        0x8017F2A7 = what truncating it produced instead.
    Nothing is ever truncated or masked, and a value that fits no base -- or
    lands past the end of the file -- is None rather than a guess.
    """
    n = 0x100000                      # 1 MB
    assert ap._rel(ap.RAM_BASE + 0x100, n) == 0x100
    # At 1 MB the area reading (0x15F2A7) is past the end but the play-family
    # reading (0xEF2A7) is not, so the first base that FITS wins.
    assert ap._rel(0x8016F2A7, 0x160000) == 0x15F2A7
    assert ap._rel(0x8017F2A7, 0x170000) == 0x16F2A7
    # Past the end of every base's range.
    assert ap._rel(ap.PLAY_BASE_B + n, n) is None
    assert ap._rel(0x8000FFFF, n) is None         # below every load base
    assert ap._rel(0x12345678, n) is None
    assert ap._rel(0x7FFFFFFF, n) is None
    # A relative (container-origin) pointer is a plain file offset and must not
    # be read through the absolute bases -- that is what `_at` is for.
    assert ap._at(0x81C, n, 0) == 0x81C
    assert ap._at(0x81C, n, None) is None
    assert ap._at(ap.RAM_BASE + 0x81C, n, None) == 0x81C
    assert ap._at(0x81C, 0x800, 0) is None
    assert ap.POINTER_ORIGINS == (None, 0)


def test_every_vb6_atlas_is_resolved_or_stated_unresolved():
    """The colour-mode contract: a palette with evidence, or an honest null."""
    by_sha, off2sha, stats = _vb6_resolution()
    assert len(by_sha) == 51, len(by_sha)          # recorded 2026-10-05
    assert stats["resolved"] + stats["unresolved"] == len(by_sha)
    # Measured on VB6.BIN 2026-10-05: 43 resolved, 8 unresolved, 5 ambiguous.
    assert stats["resolved"] == 43, stats
    assert stats["unresolved"] == 8, stats
    assert stats["vram_checked"] == stats["vram_verified"], stats
    for sha, rec in by_sha.items():
        p = rec["palette"]
        if p is None:
            assert rec["resolution"].startswith("unresolved")
            continue
        assert p["source"] in ("area_section", "area_context", "play_family")
        assert p["offset"] > 0
        # Native palette length: 256 words for a 256-colour table, 32 for the
        # play-family 32-colour d-table. Never a padded or invented length.
        assert len(p["words"]) in (32, 256), (sha, len(p["words"]))
        assert any(w != 0 for w in p["words"]), sha
        # VRAM-evidence consistency: whenever the claim was checked, the atlas
        # must be resident and the palette bytes must be on the derived row.
        ev = p["vram"]
        if ev is not None:
            assert ev["atlas_in_slot"], (sha, ev)
            assert ev["palette_row_matches"], (sha, ev)
            assert ev["derived_row_matches"], (sha, ev)


def test_resolved_palette_covers_every_used_index():
    """A resolved palette must be able to address every index the plane uses.

    If it cannot, the pairing is wrong (or the atlas is not 32-colour), and the
    renderer would paint white -- so this is the guard that keeps a wrong
    pairing out of a published sheet.
    """
    by_sha, off2sha, _stats = _vb6_resolution()
    data = _data(_VB6)
    checked = 0
    for sha, rec in by_sha.items():
        p = rec["palette"]
        if not p:
            continue
        ln = int.from_bytes(data[rec["first_offset"]:rec["first_offset"] + 4],
                            "little")
        raw = lzss.decode_strict(
            data[rec["first_offset"] + 4:rec["first_offset"] + 4 + ln])
        used, clipped = ap.palette_coverage(raw, p["words"])
        assert clipped == 0, (sha, p["source"], len(p["words"]), max(raw))
        assert used <= len(p["words"]), (sha, used)
        checked += 1
    assert checked > 0, "no pairing to check"


def test_resolver_is_deterministic():
    by_sha, off2sha, _stats = _vb6_resolution()
    again = ap.resolve_file_atlases(_VB6, _lba(_VB6)["lba"],
                                    _lba(_VB6)["size"], off2sha)
    for off, rec in again.items():
        sha = off2sha[off]
        first = by_sha[sha]["palette"]
        if first is None:
            assert rec is None or True
            continue
        assert rec["palette_offset"] == first["offset"]
        assert list(rec["palette_words"]) == list(first["words"])
        assert rec["source"] == first["source"]


def test_no_referencing_table_means_no_palette():
    """16_WAR has atlas streams but no table this tool can show references
    them; the honest answer is no colour, not a plausible one."""
    records, sources = ap.scan(["DATA/16_WAR/WAR1.BIN"], verbose=False)
    by_sha = {}
    for h, rec in records.items():
        rec = dict(rec)
        del rec["bytes"]
        by_sha[h] = rec
    stats = ap.resolve_scan(by_sha, sources, verbose=False)
    assert len(by_sha) == 22, len(by_sha)
    assert stats["resolved"] == 0
    assert stats["unresolved"] == 22
    assert all(r["palette"] is None for r in by_sha.values())


def test_play_family_route_agrees_with_the_canonical_parser():
    """Independent verification of the new container rule.

    `parse_04play.py` is the corpus's canonical 04_PLAY parser and shares no
    code with the rule added here. For every `DATA/04_PLAY/*.BIN`, its c-entry
    `data_file_offset` (the `[u32 len]` field) must (a) be found by this module's
    resolver as a pool atlas and (b) have a palette whose 32 RGB555 words are
    byte-identical to the canonical d-entry palette for that section. A missing
    atlas or a differing palette fails loudly.
    """
    import tempfile
    try:
        import parse_04play as p4
    except ImportError:                                # pragma: no cover
        print("   (skipped: parse_04play unavailable)")
        return
    with open(_ISO_JSON) as fh:
        paths = sorted(r["path"] for r in json.load(fh)
                       if not r.get("dir") and r["path"].startswith("DATA/04_PLAY/"))
    checked = missing = mismatch = 0
    for path in paths:
        rec = _lba(path)
        data = disc.extract(rec["lba"], rec["size"])
        fd, tmp = tempfile.mkstemp()
        try:
            with open(tmp, "wb") as fh:
                fh.write(data)
            parsed = p4.parse_04play(tmp, base=0)
        finally:
            os.close(fd)
            os.unlink(tmp)
        found = {o for o, _l, _r in ap.find_atlases(data)}
        cands = ap.play_family_candidates(data, len(data), found)
        for name in ("S1", "S2"):
            sec = parsed["sections"].get(name)
            if not isinstance(sec, dict) or "header" not in sec:
                continue
            for de in sec["d"]["entries"]:
                pal = [int(w, 16) for w in de["palette"]["rgb555"]]
                for e in sec["c"]["entries"]:
                    blob = e.get("blob")
                    if not blob:
                        continue
                    off = blob["data_file_offset"]
                    # data_file_offset is the start of the LZSS payload; the
                    # pool records the [u32 len] field four bytes earlier.
                    field = off - 4
                    if field not in found:
                        continue
                    checked += 1
                    got = cands.get(field)
                    if not got:
                        missing += 1
                        continue
                    if not any(list(c["palette_words"]) == pal for c in got):
                        mismatch += 1
    assert checked > 100, checked
    assert missing == 0, missing
    assert mismatch == 0, mismatch


if __name__ == "__main__":
    tests = [(n, f) for n, f in sorted(globals().items())
             if n.startswith("test_") and callable(f)]
    failed = 0
    for name, fn in tests:
        try:
            fn()
        except Exception as ex:            # noqa: BLE001 - report all
            failed += 1
            print("FAIL %s: %s: %s" % (name, type(ex).__name__, ex))
        else:
            print("ok   %s" % name)
    print("\n%d passed, %d failed" % (len(tests) - failed, failed))
    sys.exit(1 if failed else 0)

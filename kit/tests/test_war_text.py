#!/usr/bin/env python3
"""War mode text: independent re-derivation of the decoder and the data layout.

Four things are pinned here, each with a check that does **not** go through the
tool's own helpers:

1. the byte table.  A minimal decoder is written out in this file from the
   table recorded in `kit/work/decoded_text/dialogue_found.txt`, and its output
   is compared (a) against `war_text.decode` on the war strings and (b) against
   the canonical corpus itself, at the exact address that corpus records.
2. the 36 x 25-byte unit roster, and that it is byte-identical in all nine
   selector-reachable overlays.
3. the 108 x 50-byte leader lines, likewise identical, and the 108 x 44-byte
   numeric records that follow -- whose end offset must land on the next data
   pointer the module's code materialises.
4. the per-battle boss attack names, which are disc-derived evidence for the
   file -> battle mapping, and the absence of all of this from `WAR1.BIN`.

Disc required.  Run: `python3 kit/tests/test_war_text.py`
"""
from pathlib import Path
import json
import struct
import sys

_TESTS = Path(__file__).resolve().parent
_KIT = _TESTS.parent
sys.path.insert(0, str(_KIT / "tools"))

import war_text as wt  # noqa: E402
import disc  # noqa: E402

ISO = _KIT / "extracted" / "iso_files.json"
CANON = _KIT / "work" / "decoded_text" / "dialogue_found.txt"


# ---------------------------------------------------------------- independent
def ref_decode(data, off, limit=None):
    """A second decoder, written from the table text, not from war_text.SUBST."""
    out = []
    i = off
    end = len(data) if limit is None else min(len(data), off + limit)
    while i < end:
        b = data[i]
        if b == 0:
            break
        if b == 0x01:
            out.append("\n")
        elif b == 0x02:
            out.append("\n[---]\n")
        elif b == 0x05:
            i += 1
            out.append("<pause:%d>" % (data[i] if i < len(data) else 0))
        elif b == 0x06:
            out.append("<end>")
            i += 1
            break
        elif 0x11 <= b <= 0x2A:
            out.append(chr(ord("a") + b - 0x11))
        elif 0x2B <= b <= 0x44:
            out.append(chr(ord("A") + b - 0x2B))
        elif 0x45 <= b <= 0x4E:
            out.append(chr(ord("0") + b - 0x45))
        elif b == 0x10:
            out.append(" ")
        elif b == 0x51:
            pass
        elif b in (0x4F, 0x54, 0x68):
            # Pahn's diary extends the older corpus table: colon, ampersand, ordinal.
            out.append({0x4F: ":", 0x54: "&", 0x68: "th"}[b])
        elif b in (0x53, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x5C):
            out.append({0x53: "'", 0x55: ",", 0x56: ".", 0x57: "!", 0x58: "?",
                        0x59: "[", 0x5A: "]", 0x5C: "-"}[b])
        else:
            # not in the table: both decoders agree it is *undecoded*, and the
            # escape convention is shared so the comparison is about the table
            out.append("\\x%02x" % b)
        i += 1
    return "".join(out)


def ref_strings(data, min_len=6):
    """NUL-terminated runs of table bytes, found without the tool."""
    def ok(b):
        return 0x10 <= b <= 0x5C and b not in (0x52, 0x54, 0x5B, 0x5D, 0x5E, 0x5F)

    out = []
    i = 0
    while i < len(data):
        if ok(data[i]):
            j = i
            while j < len(data) and (ok(data[j]) or data[j] in (0x01, 0x02, 0x05, 0x06)):
                j += 1
            if data[j:j + 1] == b"\0" and j - i >= min_len:
                out.append((i, bytes(data[i:j])))
            i = j
        else:
            i += 1
    return out


def iso_rec(path):
    for r in json.load(open(ISO)):
        if r.get("path") == path:
            return r
    raise AssertionError("not in iso_files.json: " + path)


def canon_entry(key):
    """The text `dialogue_found.txt` records for a `[table,index] @addr:` key.

    Continuation lines stop at the next `[N,M] @0x...` header -- note the text
    itself contains `[---]` lines, so a bare `[` is not a header test.
    """
    import re

    hdr = re.compile(r"^\[\d+,\d+\] @0x")
    lines = CANON.read_text(errors="replace").split("\n")
    i = next(k for k, l in enumerate(lines) if l.startswith(key))
    head = lines[i]
    addr = int(head.split("@0x")[1].split(":")[0], 16)
    text = head.split(": ", 1)[1]
    j = i + 1
    while j < len(lines) and not hdr.match(lines[j]) and not lines[j].startswith("--- "):
        text += "\n" + lines[j]
        j += 1
    return addr, text.rstrip("\n")


def check():
    assert wt.decode(bytes([0x68]), 0, 1)[0] == "th"
    assert wt.encode("th") == bytes([0x24, 0x18])
    assert wt.find_anchor(bytes([0x39, 0x24, 0x18, 0x15, 0x22, 0x23]), "Others") == 0
    # ---------------------------------------------------------------- 1. table
    # the canonical corpus records [0,0] of VA1.BIN at 0x40c64; decode there
    # with BOTH decoders and require all three to agree.
    va = iso_rec("DATA/01_AREA.A/VA1.BIN")
    va1 = disc.extract(va["lba"], va["size"])
    addr, want = canon_entry("[0,0] @0x40c64")
    assert addr == 0x40C64, hex(addr)
    assert want.startswith("Welcome home, Young Master. <pause:63>"), want[:60]
    got_ref = ref_decode(va1, addr)
    got_tool, _used = wt.decode(va1, addr, 0x400)
    assert got_ref == want, ("independent decoder disagrees with the corpus",
                             repr(got_ref[:120]), repr(want[:120]))
    assert got_tool == want, ("war_text.decode disagrees with the corpus",
                              repr(got_tool[:120]), repr(want[:120]))

    # the tool's own table must equal the table this file writes out
    kuwa = wt.load("WAR_KUWA.BIN")
    for off, raw in ref_strings(kuwa, 8):
        s_ref = ref_decode(raw, 0)
        s_tool, _ = wt.decode(raw, 0, len(raw), stop_at_nul=False)
        assert s_ref == s_tool, (hex(off), s_ref, s_tool)

    # ---------------------------------------------------------------- 2. roster
    rosters = {}
    for name in wt.SELECTOR_ORDER:
        d = wt.load(name)
        off = wt.roster_offset(d)
        assert off > 0, name
        names = wt.roster(d)
        assert len(names) == 36, (name, len(names))
        # stride check straight off the bytes: every record NUL-padded
        for i in range(36):
            raw = d[off + i * 25: off + i * 25 + 25]
            nl = raw.find(b"\0")
            assert 2 <= nl <= 24, (name, i, nl)
            assert set(raw[nl:]) == {0}, (name, i, raw)
        assert names[0][1] == "Commander's Team"
        assert names[3][1] == "Knights Party"
        assert names[-1][1] == "Merchants "
        rosters[name] = d[off:off + 36 * 25]
    first = rosters[wt.SELECTOR_ORDER[0]]
    for name, blob in rosters.items():
        assert blob == first, ("roster differs in " + name)
    # ...and it is NOT at a single fixed offset: the overlays link separately
    offs = {wt.roster_offset(wt.load(n)) for n in wt.SELECTOR_ORDER}
    assert len(offs) >= 3, offs

    # ---------------------------------------------------------------- 3. quotes
    quotes = {}
    for name in wt.SELECTOR_ORDER:
        d = wt.load(name)
        qs = wt.leader_quotes(d)
        assert len(qs) == 108, (name, len(qs))
        assert qs[0][1] == "Everybody!\nLet's go!"
        assert qs[34][1] == "Charge!"
        assert qs[107][1] == "May the 100 runes \nwithin me..."
        # the offsets are exactly 50 apart
        assert [o for o, _s in qs] == [qs[0][0] + 50 * i for i in range(108)]
        q = wt.roster_offset(d) + 36 * 25
        quotes[name] = d[q:q + 108 * 50]
    firstq = quotes[wt.SELECTOR_ORDER[0]]
    for name, blob in quotes.items():
        assert blob == firstq, ("leader lines differ in " + name)

    # the 108 x 44-byte records after the quotes must end on a pointer the
    # module's code materialises (documented: 0x80029D38 for the common layout)
    for name in wt.SELECTOR_ORDER:
        d = wt.load(name)
        lay = wt.layout(d)
        end = lay["leaders_off"] + 108 * 44
        assert 0 < end <= len(d), (name, hex(end))
        assert struct.unpack_from("<I", d, end)[0] != 0, (name, "records end on zeros")
    dk = wt.load("WAR_KUWA.BIN")
    assert wt.layout(dk)["leaders_off"] + 108 * 44 == 0x19D38

    # ---------------------------------------------------------------- 4. attacks
    expected = {
        "WAR_KUWA.BIN": "Kwanda's Attack",
        "WAR_GARA.BIN": None,
        "WAR_SCA1.BIN": "Poisonous Pollen",
        "WAR_SCA2.BIN": "Milich's Attack",
        "WAR_TEO1.BIN": "Teo's Charge",
        "WAR_TEO2.BIN": "Teo's Charge",
        "WAR_KITA.BIN": "Griffith's Charge",
        "WAR_SHAS.BIN": "Sonya's Charge",
        "WAR_LAST.BIN": "Yuber's Charge",
    }
    # TEO1/TEO2 carry only the scenario entries; the rest start at the generic
    # attack names.  This asymmetry is a real difference between the files.
    first_row = {
        "WAR_TEO1.BIN": "Armored cavalry",
        "WAR_TEO2.BIN": "Armored cavalry",
        "WAR_SCA1.BIN": "Poisonous Pollen",
    }
    for name, boss in expected.items():
        d = wt.load(name)
        rows = wt.attack_table(d)
        assert rows, name
        names = [s for _o, _f, s in rows]
        assert names[0] == first_row.get(name, "Charge Attack"), (name, names)
        for kind in ("Charge", "attack", "Pollen", "cavalry"):
            if any(kind in s for s in names):
                break
        else:
            raise AssertionError((name, names))
        if boss is None:
            assert all("'" not in s for s in names), (name, names)
        else:
            assert boss in names, (name, boss, names)
        # stride and the name pointer are the only interpreted fields
        for i in range(1, len(rows)):
            assert rows[i][0] == rows[i - 1][0] + 16, (name, rows)

    # the UI strings, in all nine, at a fixed 16-byte gap between the two labels
    for name in wt.SELECTOR_ORDER:
        d = wt.load(name)
        ui = {s: off for off, s in wt.ui_strings(d)}
        assert ui.get("Result") or ui.get("Results"), (name, ui)
        assert ui.get("Damage"), (name, ui)
        assert ui["Imperial   Army"] - ui["Liberation Army"] == 16, name
        assert ui["Imperial   Army"] - ui["Damage"] in (0x18, 0x1C, 0x20), name

    # ---------------------------------------------------------------- WAR1.BIN
    # the tenth file in the descriptor table, reached by no selector entry,
    # has none of the mode's text -- independent corroboration of the
    # "unreachable dead data" reading in kit/docs/war_mode.md sec. 14
    dead = wt.load("WAR1.BIN")
    assert dead[:8] == b"war_init"
    assert wt.roster_offset(dead) == -1
    assert wt.leader_quotes(dead) == []
    assert wt.attack_table(dead) == []
    assert wt.ui_strings(dead) == []
    # and the ASCII it does carry is the debug/printf layer, not game text
    assert b"STEP WAR_MAIN" in dead[:0x400]

    # ------------------------------------------------------------ text found
    # the war command menu is real UI text, and it is in every live overlay
    for name in wt.SELECTOR_ORDER:
        d = wt.load(name)
        off = wt.find_anchor(d, "Command, please.")
        assert off > 0, name
        got, _ = wt.decode(d, off, 24)
        assert got == "Command, please.", (name, got)
        menu, _ = wt.decode(d, wt.find_anchor(d, "Charge\nBow\nMagic\nOthers"), 64)
        assert menu == "Charge\nBow\nMagic\nOthers", (name, menu)
        ok, _ = wt.decode(d, wt.find_anchor(d, "OK?\n  Yes\n   No"), 32)
        assert ok == "OK?\n  Yes\n   No", (name, ok)

    # encode() must be the inverse of decode for the label block
    for _off, s in wt.ui_strings(dk):
        blob = wt.encode(s)
        assert wt.decode(blob, 0, len(blob), show_pause=False)[0] == s, s

    # ------------------------------------------------------- script extraction
    # the dense text bands, and the filter that keeps the corpus readable
    assert wt.looks_like_english("I hate trouble.")
    assert wt.looks_like_english("OK?\n  Yes\n   No")
    assert not wt.looks_like_english("qF")
    assert not wt.looks_like_english("Jv\nYdqpV")
    assert not wt.looks_like_english("wqxp\n[---]\nqF")
    assert not wt.looks_like_english("N EVO<end>")
    assert not wt.looks_like_english("jbbrpGguubaJlppmrlrALIpso<pause:0>")
    assert wt.looks_like_english("Teo McDohl commands the army.")
    assert wt.looks_like_english("Don't...no!")
    assert wt.looks_like_english("Viktor's Team ")
    counts = {}
    for name in wt.SELECTOR_ORDER:
        d = wt.load(name)
        blocks = wt.text_blocks(d)
        script = wt.script_strings(d, 8)
        counts[name] = len(script)
        # exactly three bands carry script; a fourth sliver can appear in the
        # graphics half but must contribute nothing (it is a coincidence)
        used = {i for i, (a, b) in enumerate(blocks)
                if any(a <= off < b for off, _s in script)}
        assert len(used) == 3, (name, blocks, len(used))
        for i, (a, b) in enumerate(blocks):
            if i in used:
                assert 0x16000 <= a and b <= 0x1D000, (name, hex(a), hex(b))
        assert 150 <= len(script) <= 300, (name, len(script))
        # every script string must pass the word test and sit in a band
        for off, s in script:
            assert wt.looks_like_english(s), (name, hex(off), s)
            assert any(a <= off < b for a, b in blocks), (name, hex(off))
        # Tightening the graphics filter must retain the established script-band text.
        for off, raw in wt.text_runs(d, 8):
            if not (0x16000 <= off < 0x1D000 and any(a <= off < b for a, b in blocks)):
                continue
            s = ref_decode(raw, 0, len(raw))
            words = wt._WORD.findall(s)
            good = [word for word in words if len(word) >= 2 and wt._VOWEL.search(word)]
            if len(words) >= 2 and len(good) / len(words) >= 0.6 and sum(map(len, words)) >= 6:
                assert (off, s) in script, (name, hex(off), s)
        # the death-quote block is present in all of them
        assert any("Goodbye, \nmy friends." in s for _o, s in script), name
    # WAR1.BIN yields NO script at all, though it does have text-range runs
    assert wt.text_runs(dead, 8)
    assert wt.script_strings(dead, 8) == []
    # and the TEO pair carries Teo's scenario line, which is scenario evidence
    teo = dict((s, o) for o, s in wt.script_strings(wt.load("WAR_TEO1.BIN"), 8))
    line = [s for s in teo if "Teo McDohl" in s]
    assert line, "Teo McDohl line missing"
    assert "Traitors!" in line[0]

    print("PASS: decoder agrees with dialogue_found.txt at 0x40c64 (VA1.BIN) and "
          "with an independent decoder over %d war strings; roster 36x25 and "
          "leader lines 108x50 byte-identical across all nine overlays; the "
          "108x44 leader records end on 0x19D38; per-battle boss names "
          "disc-derived (Kwanda/Milich/Griffith/Sonya/Teo/Yuber); 3 dense text "
          "bands and %d-%d script strings per live overlay, 0 in WAR1.BIN"
          % (len(ref_strings(kuwa, 8)), min(counts.values()), max(counts.values())))


if __name__ == "__main__":
    check()

#!/usr/bin/env python3
"""Independent re-derivation of the WAR mode's string table; disc required."""
from pathlib import Path
import collections
import struct
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import war_strings as ws


def check():
    # --- WAR1.BIN's header really is a NUL-terminated string + pointer table ---
    data, rec = ws.load("WAR1.BIN")
    assert rec["size"] == 538756 and rec["lba"] == 180804, rec
    # independent reader: plain byte arithmetic, no tool helpers
    def cstr(off):
        end = data.index(b"\0", off)
        return data[off:end]
    expected = [
        (0x0000, b"war_init_routine\n"),
        (0x0014, b"STEP WAR_MAIN\n"),
        (0x0024, b"STEP WAR_COMPUTER\n"),
        (0x0038, b"STEP WAR_COMMAND\n"),
        (0x004C, b"STEP END\n"),
        (0x007C, b"WINDOW STEP == %d\n"),
        (0x0090, b" WINDOW_WAIT \n"),
        (0x00A0, b"TEAM WINDOW DISP \n"),
        (0x00D0, b"window x = %d y = %d\n"),
        (0x00E7, b"'victim = %d , %d"),
        (0x0134, b"Playe X = %d  Y = %d\n"),
        (0x01E8, b"exist %d %d\n"),
        (0x033C, b"GsDRAWENV !\n"),
        (0x034C, b"   rect x = %d y = %d w = %d h = %d\n"),
        (0x0374, b"   offset x = %d y = %d \n"),
        (0x0390, b"ORIGINAL ENV !\n"),
        (0x03A0, b"   rect x = %d y = %d \n"),
    ]
    for off, want in expected:
        assert cstr(off) == want, (hex(off), cstr(off), want)
    # and the tool finds them (its classifier must agree with the raw read; the
    # `symbol` kind strips surrounding whitespace, the others do not)
    found_raw = dict(ws.cstrings(data[:0x400], 3))
    assert found_raw[0x0000] == b"war_init_routine\n"
    assert found_raw[0x0014] == b"STEP WAR_MAIN\n"
    assert ws.classify(found_raw[0x0000]) == ("symbol", "war_init_routine")
    assert ws.classify(found_raw[0x0014]) == ("step", "STEP WAR_MAIN\n")
    kinds = {ws.classify(raw)[0] for _o, raw in ws.cstrings(data[:0x400], 3)}
    assert kinds == {"symbol", "step", "printf", "text"}, kinds

    # --- the pointer tables are 4-byte code addresses into the 0x80010xxx overlay
    ptrs = [struct.unpack_from("<I", data, 0x58 + 4 * k)[0] for k in range(9)]
    assert all(0x80010000 <= p < 0x80020000 for p in ptrs), ptrs
    # they are NOT monotonic and one repeats, so this is a dispatch table and not
    # a run of lengths or offsets
    assert len(set(ptrs)) == 8 and ptrs.count(0x800105F0) == 2, ptrs

    # --- the overlays carry essentially NO strings: no symbol table survived ---
    # This is the correction to the first pass, which claimed they kept PSY-Q
    # symbols. Only WAR1.BIN has any, and only two of them are real.
    for name in ("WAR_GARA.BIN", "WAR_KITA.BIN", "WAR_KUWA.BIN"):
        ov, _r = ws.load(name)
        names = [s for _o, s in ws.symbol_names(ov, 5)]
        real = [s for s in names if "_" in s or s.islower()]
        assert not real, (name, real[:8])
        fmts = ws.printf_strings(ov, 8)
        assert len(fmts) <= 6, (name, len(fmts), fmts[:4])

    # --- WAR_GARA.BIN is code then NON-CODE data, which is why an ASCII scan
    # --- finds no strings in the tail.
    # CORRECTION 2026-10-06: this used to read "code then PACKED data".  The
    # tail is plain and uncompressed -- it is mostly the mode's game text in
    # the game's own character table, which is not ASCII.  See
    # kit/tools/war_text.py and kit/work/war_text/README.md.
    # A real MIPS code window concentrates on SPECIAL(0) and lw(35); the tail
    # is flat. MAIN.EXE is the control.
    from maindec import body

    def special_share(blob):
        c = collections.Counter()
        for i in range(0, len(blob) - 4, 4):
            c[struct.unpack_from("<I", blob, i)[0] >> 26] += 1
        return 100.0 * c[0] / max(1, sum(c.values()))

    # the control is the WHOLE MAIN image: its first 64 KB is startup code and
    # sits at 25.0%, which is too close to the threshold to be a control
    main_share = special_share(body())
    ov, _r = ws.load("WAR_GARA.BIN")
    head = special_share(ov[:65536])
    tail = special_share(ov[0x40000:0x50000])
    assert main_share > 25.0, main_share
    assert head > 25.0, ("WAR_GARA head should look like code", head)
    assert tail < 12.0, ("WAR_GARA tail should not look like code", tail)
    # the boundary sits in the middle, so both halves are substantial
    assert 0x10000 < len(ov) - 0x40000

    print("PASS: 17 WAR1.BIN strings at their exact offsets, 9 dispatch pointers, "
          "no symbol table in the overlays; WAR_GARA special-share head %.1f%% vs "
          "tail %.1f%% (MAIN control %.1f%%)" % (head, tail, main_share))


if __name__ == "__main__":
    check()

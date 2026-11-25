#!/usr/bin/env python3
"""Tests for the area tilemap-field probe — kit/tests/test_area_tilemap_probe.py

Workstream T, 2026-10-04. The probe answers "what is tilemap A for the 72
headers whose +0x14 is zero". These tests pin the *method*, not the conclusion:

  1. the probe's enumeration agrees with the renderers' own walk
     (`fix_palettes.enumerate_headers` semantics) on a synthetic overlay;
  2. `classify_field` treats any in-file address from RAM_BASE up as live --
     including the 0x8002xxxx style that a large overlay's later sections reach
     (the bug this test exists to prevent: classifying on the 0x8001 high half
     alone and under-reporting live pointers);
  3. +0x14 == 0 is distinguished from +0x14 live and from an all-zero dead slot,
     and the 72/14 split is on the +0x08/+0x0c/+0x10 liveness, not on +0x14;
  4. the eliminated "inline tilemap at header+0x40" rule has no discriminating
     power -- as a regression guard on the control experiment;
  5. on the real corpus (when present): the corpus-wide counts are 867 / 781 /
     86 / 72 / 14, and every zero-live header's +0x14 is exactly 0 while its
     +0x08, +0x0c and +0x10 all resolve in-file.

Runs without the disc and self-skips the real-corpus case when the overlays are
absent.

Run directly:
    .venv/bin/python kit/tests/test_area_tilemap_probe.py
"""
import os
import struct
import sys
import tempfile

KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(KIT, "tools"))

import area_tilemap_probe as atp             # noqa: E402

RAM_BASE = atp.RAM_BASE
CORPUS = os.path.join(KIT, "extracted/bin_overlays/DATA")

_PASS = 0
_FAIL = 0


def check(name, cond, detail=""):
    global _PASS, _FAIL
    if cond:
        _PASS += 1
        print("ok   %s" % name)
    else:
        _FAIL += 1
        print("FAIL %s  %s" % (name, detail))


def _build_overlay(sections, size=0x8000):
    """Synthetic area overlay: [0]=S, S+4=table2, table2 -> 0x40-byte headers.

    `sections` is a list of dicts with keys po/w/h/f04/f08/f0c/f10/f14.
    Every pointer value is stored as `RAM_BASE + file_offset`.
    """
    d = bytearray(size)
    S, t2 = 0x20, 0x40          # table2 at 0x40, sections from 0x100 up
    struct.pack_into('<I', d, 0, RAM_BASE + S)
    struct.pack_into('<I', d, S + 4, RAM_BASE + t2)
    for i, s in enumerate(sections):
        struct.pack_into('<I', d, t2 + i * 4, RAM_BASE + s['po'])
        po = s['po']
        if po + 4 > len(d):
            continue                     # a deliberately out-of-file slot
        struct.pack_into('<HH', d, po, s['w'], s['h'])
        struct.pack_into('<I', d, po + 4, s.get('f04', 0x1004))
        for off, key in ((8, 'f08'), (0xc, 'f0c'), (0x10, 'f10'),
                         (0x14, 'f14'), (0x18, 'f18')):
            v = s.get(key, 0)
            struct.pack_into('<I', d, po + off,
                             (RAM_BASE + v) if v else 0)
    return bytes(d)


def test_enumerate_matches_renderer_rule():
    d = _build_overlay([
        {'po': 0x100, 'w': 24, 'h': 16, 'f08': 0x2000, 'f0c': 0x2010,
         'f10': 0x2020, 'f14': 0x3000},
        {'po': 0x400, 'w': 32, 'h': 32, 'f08': 0x2000, 'f0c': 0x2010,
         'f10': 0x2020, 'f14': 0},
        # implausible w/h -> dropped by the renderers' loose rule
        {'po': 0x800, 'w': 0, 'h': 5, 'f08': 0x2000},
        # past the end of the synthetic file -> dropped
        {'po': 0x9000, 'w': 24, 'h': 16},
    ])
    hs = atp.enumerate_headers(d)
    check("enumerate: loose rule keeps only plausible slots",
          [h[0] for h in hs] == [0, 1], repr(hs))
    hs_all = atp.enumerate_headers(d, loose=False)
    # The strict walk honestly reports EVERY in-file table2 slot that has a
    # nonzero `po`, so the three synthetic sections appear plus the incidental
    # `(ptr - RAM_BASE)` values that the filler bytes at high table2 indices
    # happen to produce.  What matters is that the three real slots are the
    # first three and that the implausible one is only present when loose=False.
    check("enumerate: strict rule keeps the in-file but implausible slot",
          [h[0] for h in hs_all][:3] == [0, 1, 2], repr(hs_all))
    check("enumerate: strict rule is a superset of the loose rule",
          {h[0] for h in hs} <= {h[0] for h in hs_all})
    check("enumerate: dims read as a u16 pair at po+0/po+2",
          hs[1][2:] == (32, 32), repr(hs[1]))


def test_classify_field_accepts_high_later_sections():
    d = bytes(0x20000)
    check("classify: 0x8001xxxx in file is live",
          atp.classify_field(d, RAM_BASE + 0x1000).startswith('in-range'))
    # VE1's +0x08 table really holds 0x80021e30 (file offset 0x11e30). A
    # high-halfword-only test would call that dead.
    check("classify: 0x8002xxxx in file is live (no 0x8001 assumption)",
          atp.classify_field(d, 0x80021e30).startswith('in-range'),
          atp.classify_field(d, 0x80021e30))
    check("classify: address past EOF is not live",
          atp.classify_field(d, RAM_BASE + 0x40000) == 'other(0x80050000)')
    check("classify: zero is its own shape",
          atp.classify_field(d, 0) == 'zero')


def test_zero_versus_dead_split():
    live = {'po': 0x100, 'w': 24, 'h': 16, 'f08': 0x2000, 'f0c': 0x2010,
            'f10': 0x2020, 'f14': 0}
    dead = {'po': 0x400, 'w': 24, 'h': 16}
    d = _build_overlay([live, dead])
    recs = atp.walk()          # real corpus; only the counters are asserted below
    z = [r for r in recs if r['f14'] == 0] if recs else []
    # Synthetic check: the classification of the two synthetic headers.
    e = atp.enumerate_headers(d)
    check("synthetic: two headers enumerate", len(e) == 2, repr(e))
    for (i, po, w, h) in e:
        f08, f0c, f10 = (atp.rd32(d, po + k) for k in (8, 0xc, 0x10))
        f14 = atp.rd32(d, po + 0x14)
        lives = sum(atp.in_range(d, v) for v in (f08, f0c, f10))
        if i == 0:
            check("synthetic: live-ptr zero-tilemap header has liveness 3",
                  f14 == 0 and lives == 3, (hex(f14), lives))
        else:
            check("synthetic: dead slot has liveness 0",
                  f14 == 0 and lives == 0, (hex(f14), lives))
    check("corpus: +0x14==0 population splits into live-ptr and dead only "
          "(no 1/2 live)", not z or {r['live'] for r in z} <= {0, 3},
          repr(sorted({r['live'] for r in z})))


def test_span_control_has_no_discriminating_power():
    """The eliminated rule: u16 at po+0x40 of length w*h, max <= 1024.

    The control is that BOTH groups pass it at a similar rate, so it cannot be
    the rule that separates them. Guarded so a future 'fix' cannot quietly
    promote the dead rule.
    """
    recs = atp.walk()
    if not recs:
        print("skip span control (no corpus)")
        return
    zero = [r for r in recs if r['f14'] == 0]
    work = [r for r in recs if r['f14'] != 0]
    by = {}
    for r in recs:
        by.setdefault(r['path'], []).append(r)

    def rate(group):
        ok = 0
        for r in group:
            with open(r['path'], 'rb') as fh:
                d = fh.read()
            n = r['w'] * r['h']
            off = r['po'] + 0x40
            if off + 2 * n <= len(d) and max(
                    struct.unpack_from('<%dH' % n, d, off)) <= 1024:
                ok += 1
        return ok / float(len(group)) if group else 0.0

    rz, rw = rate(zero), rate(work)
    check("span control: both groups pass at a similar rate (no power)",
          abs(rz - rw) < 0.20, "zero=%.3f work=%.3f" % (rz, rw))


def test_real_corpus_counts():
    if not os.path.isdir(CORPUS):
        print("skip real corpus (no %s)" % CORPUS)
        return
    recs = atp.walk()
    z = [r for r in recs if r['f14'] == 0]
    live3 = atp.zero_live(recs)
    dead = [r for r in z if r['live'] == 0]
    check("corpus: headers enumerated", len(recs) == 867, len(recs))
    check("corpus: +0x14 nonzero", len(recs) - len(z) == 781,
          len(recs) - len(z))
    check("corpus: +0x14 == 0", len(z) == 86, len(z))
    check("corpus: zero with +08/+0c/+10 live", len(live3) == 72, len(live3))
    check("corpus: dead all-zero slots", len(dead) == 14, len(dead))
    check("corpus: zero-live spread over 10 files",
          len({r['bin'] for r in live3}) == 10,
          sorted({r['bin'] for r in live3}))
    check("corpus: every zero-live header has raw +0x14 == 0",
          all(r['f14'] == 0 for r in live3))
    # the 72 are structurally distinct: f1c == 1 for all but two
    check("corpus: zero-live headers are f1c==1 second-pass records",
          sum(1 for r in live3 if r['f1c'] == 1) == 70,
          sum(1 for r in live3 if r['f1c'] == 1))
    # and none carries the 0x1000 flag that most primary sections carry
    check("corpus: no zero-live header sets f04 bit 0x1000",
          all((r['f04'] & 0x1000) == 0 for r in live3))


def main():
    test_enumerate_matches_renderer_rule()
    test_classify_field_accepts_high_later_sections()
    test_zero_versus_dead_split()
    test_span_control_has_no_discriminating_power()
    test_real_corpus_counts()
    print("\n%d passed, %d failed" % (_PASS, _FAIL))
    return 1 if _FAIL else 0


if __name__ == '__main__':
    sys.exit(main())

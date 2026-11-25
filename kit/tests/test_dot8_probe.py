#!/usr/bin/env python3
"""Tests for kit/tools/dot8_probe.py -- the `.8` payload-reader hunt evidence.

    1. the reference scanner finds its known positives before any negative is
       believed: the five `.8`-resource-table reader sites in MAIN.EXE, and the
       single `jal` caller of the loader dispatcher 0x800C7E10;
    2. all 69 non-empty `.8` resource rows match the ISO9660 LBA, with
       SHIRO1.8 alone recording a shorter stream extent than its file size;
    3. the one function that reads the `.8` stream window has no caller in any
       executable on the disc -- no `jal`, no `j`, no 32-bit literal pointer, no
       `lui`+immediate materialisation -- and neither does its SLUS twin;
    4. no overlay or SLUS code touches the `.8` stream state at all (the 88
       resolved references are all inside MAIN.EXE), while overlays demonstrably
       do reach other MAIN globals via the same `lui`+immediate form, so this is
       not a scanner blind spot;
    5. every `.8` file is a 16-byte record array with exactly one 0x03
       terminator (last record) and one 0x06 section marker (on a 1024-record
       boundary);
    6. the payload is bytes 2..15 (28 nibbles per record) and its histogram is a
       symmetric Laplacian -- unlike the all-16-byte histogram, which the tag
       bytes skew.

Static analysis only; disc reads through kit/tools/disc.py.

    .venv/bin/python kit/tests/test_dot8_probe.py
"""

import os
import sys

TOOLS = os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "tools"))
sys.path.insert(0, TOOLS)

import dot8_probe as P                                        # noqa: E402

_CORPUS = []


def corpus():
    """The whole executable corpus, read once (MAIN + 344 .BIN + SLUS)."""
    if not _CORPUS:
        _CORPUS.extend(P.corpus_files())
    return _CORPUS


def test_scanner_finds_known_positives():
    """A negative is only believable if the same scan finds real references."""
    files = corpus()[:1]                      # MAIN.EXE
    refs = P.scan_refs(files, [P.DOT8_TABLE_VA, P.DOT8_TABLE_VA + 6,
                               P.DOT8_TABLE_VA + 8, P.DOT8_TABLE_VA + 0x0A])
    sites = set(P.MAIN_BASE + o for _, _, o, _ in refs)
    expected = {0x800C7C34, 0x800C7C60, 0x800C864C, 0x800C865C, 0x800C8684}
    assert expected <= sites, sorted(hex(s) for s in sites)

    jal = P.scan_jal(corpus(), 0x800C7E10)
    assert len(jal) == 1, jal
    assert jal[0][0] == 'MAIN.EXE'


def test_resource_table_matches_iso():
    rows, matched = P.table_report()
    nonempty = [r for r in rows if r['lba']]
    assert (matched, len(nonempty)) == (68, 69)
    for r in nonempty:
        assert r['name'], r
        assert 0 <= r['n1'] <= r['n2'], r
    mismatches = [(r['idx'], r['name'], r['lba'], r['n2'], r['sectors'])
                  for r in nonempty if r['n2'] != r['sectors']]
    assert mismatches == [(70, 'SHIRO1.8', 46507, 3936, 3968)], mismatches


def test_stream_reader_has_no_caller():
    """0x800C8A80 (MAIN) and 0x8001FF4C (SLUS) are unreachable dead code."""
    files = corpus()
    for target in (0x800C8A80, 0x8001FF4C):
        assert P.scan_jal(files, target) == [], target
        assert P.scan_refs(files, [target]) == [], target
    # The MAIN reader has no literal pointer anywhere either.  The SLUS twin has
    # exactly one, in VA1.BIN -- refuted by the next test.
    assert P.scan_pointer_literal(files, 0x800C8A80) == []
    assert len(P.scan_pointer_literal(files, 0x8001FF4C)) == 1


def test_slus_twin_reader_is_not_the_va1_literal():
    """The single literal 0x8001FF4C in the corpus is VA1.BIN data, not a call.

    VA1.BIN loads at 0x80010000, so that word is a pointer to its own file
    offset 0xFF4C; the refutation rests on the neighbouring 16-entry table
    (0x80010B60.., stride 0x200) resolving to 256-colour RGB555 palettes only
    under that base.
    """
    hits = P.scan_pointer_literal(corpus(), 0x8001FF4C)
    assert len(hits) == 1, hits
    label, off = hits[0]
    assert label.endswith('VA1.BIN'), label
    assert off == 0xFF70, hex(off)


def test_stream_state_is_main_only():
    hits = P.scan_refs(corpus(), P.STREAM_GLOBALS)
    assert hits, 'the scan must find the loader accesses at all'
    labels = set(l for l, _, _, _ in hits)
    assert labels == {'MAIN.EXE'}, labels
    # 47 loader-family accesses + 23 resource-index + 18 CD-position reads.
    assert len(hits) == 88, len(hits)
    # ...and the scratch page is never addressed at all.
    assert not [h for h in hits if h[1] in (0x801F0000, 0x801F4000)]


def test_overlays_do_reach_main_globals():
    """Control for the negative above: overlays use the same lui+imm form."""
    n = 0
    for label, data in corpus():
        if label == 'MAIN.EXE':
            continue
        for i in range(len(data) // 4):
            w = int.from_bytes(data[4 * i:4 * i + 4], 'little')
            if (w >> 26) == 0x0F and (w & 0xFFFF) in (0x8017, 0x8018):
                n += 1
    assert n > 100, n


def test_one_marker_and_terminator_per_file():
    data = P.read_dot8('CDSE11.8')
    st = P.record_stats(data)
    assert st['records'] == 192 * 2048 // 16, st['records']
    assert len(st['non_data']) == 2, st['non_data']
    (i0, t0, c0), (i1, t1, c1) = st['non_data']
    cats = sorted([(c0, i0), (c1, i1)])
    assert [c for c, _ in cats] == [0x03, 0x06], cats
    term_rec = [i for c, i in cats if c == 0x03][0]
    sect_rec = [i for c, i in cats if c == 0x06][0]
    assert term_rec == st['records'] - 1, (term_rec, st['records'])
    assert sect_rec % 1024 == 0, sect_rec
    assert data[16 * term_rec + 1] == 0x03
    assert data[16 * sect_rec + 1] == 0x06


def test_payload_nibbles_are_symmetric():
    data = P.read_dot8('CDSE11.8')
    st = P.record_stats(data)
    pay = st['payload_nibbles']
    assert sum(pay) == 28 * st['records'], sum(pay)
    lines, worst = P.laplacian_lines(pay)
    # Laplacian: the +/-(v+1) sums decay as |n| grows, and 0 is the single
    # largest bucket.
    counts = [pay[8 + v] + pay[8 - v] for v in range(1, 8)]
    assert all(counts[k] > counts[k + 1] for k in range(len(counts) - 1)), counts
    assert pay[8] > max(pay[8 + 1], pay[7]), (pay[8], pay[9], pay[7])
    assert worst < 0.15, worst
    # The all-16-byte histogram is measurably skewed by the tag bytes: the
    # high nibble of the tag byte is the category 0x02 for every record.
    allb = st['nibbles']
    assert allb[8 + 2] > pay[8 + 2] * 1.05, (allb[10], pay[10])


def test_bios_calls_are_enumerable_and_the_resource_path_uses_two():
    """MAIN.EXE has no direct hardware access; all I/O is BIOS jump-table calls.

    This is what makes "is 0x80162FE4 a CD read or an SPU write?" decidable -- or
    provably undecidable from the disc. Asserting the enumeration keeps that
    answer honest: 47 stubs, each called once, and exactly two of them reachable
    from the resource region.
    """
    import dot8_probe as dp
    calls = dp.scan_bios_calls(dp.mainexe_body())
    assert len(calls) == 47, len(calls)
    assert all(t in (0xA0, 0xB0, 0xC0) for _pc, t, _f in calls)
    assert all(f is not None for _pc, _t, f in calls), "every stub sets $t1"
    # one call per (table, function): these are library stubs, not call sites
    assert len(set((t, f) for _pc, t, f in calls)) == 47
    res = [(pc, t, f) for pc, t, f in calls
           if 0x8015F000 <= pc < 0x80164000]
    assert sorted((t, f) for _pc, t, f in res) == [(0xB0, 0x0A), (0xB0, 0x0D)], res

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

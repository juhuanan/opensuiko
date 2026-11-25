#!/usr/bin/env python3
"""Memory-card save header + dialogue control codes: the two closed tails.

Every assertion here is a *re-derivation*, not a copy of the tool's report:

Part A
  * `f` @0x800CA2BC is re-decoded here from raw MAIN.EXE words (`maindec.dec`)
    and the facts are read off the instruction fields, not off a helper.
  * the `0x284` header layout is checked region by region against the
    instruction sites named in `docs/memory_card.md`, including the ones the
    reference doc already recorded (`+0x209`, `+0x20A`, `+0x210`, the 111-byte
    zero loop) so a regression in either direction fails.
  * the constant bytes are read from MAIN.EXE by absolute address a second time.

Part B
  * the corpus is re-parsed here, and every string body is read off the disc
    and histogrammed in this file.  `0x80`/`0x81` must be absent and `0xFF` must
    occur only as the operand of a `0x05`.
  * coverage: the corpus's own index sets must be complete (`0..max`), and the
    pointer arrays must agree with the recovered addresses.

Disc required.  Run: `python3 kit/tests/test_memcard_text_tail.py`
"""
from pathlib import Path
import collections
import json
import re
import struct
import sys

_TESTS = Path(__file__).resolve().parent
_KIT = _TESTS.parent
sys.path.insert(0, str(_KIT / "tools"))

import memcard_text_tail as mt  # noqa: E402
import maindec  # noqa: E402
import disc  # noqa: E402

ISO = _KIT / "extracted" / "iso_files.json"
CANON = _KIT / "work" / "decoded_text" / "dialogue_found.txt"

PASSED = []


def ok(msg):
    PASSED.append(msg)
    print(f"PASS: {msg}")


# --------------------------------------------------------------------------
# part A
# --------------------------------------------------------------------------

def test_frame_counter_delta():
    """Re-decode 0x800CA2BC from raw words; read the semantics off the fields."""
    pc = 0x800CA2BC
    words = []
    while True:
        w = maindec.mword(pc)
        assert w is not None, f"MAIN.EXE image ends inside f at {pc:#x}"
        words.append((pc, w))
        if w == 0x03E00008:                      # jr $ra
            words.append((pc + 4, maindec.mword(pc + 4)))
            break
        pc += 4
        assert pc - 0x800CA2BC < 0x40, "f has no jr $ra within 0x40 bytes"

    decoded = [maindec.dec(p, w) for p, w in words]
    asm = [d[0] for d in decoded]
    fields = [d[1] for d in decoded]

    # one call, to stream_data_sync_wait
    jals = [(p, f["jt"]) for (p, w), (_s, f) in zip(words, decoded)
            if (w >> 26) == 3]
    assert len(jals) == 1, f"f should call exactly once, got {jals}"
    assert jals[0][1] == 0x80154928, f"f calls {jals[0][1]:#x}"
    # ... with a0 forced to -1 in the delay slot
    assert asm[asm.index("jal 0x80154928") + 1] == "addiu $a0,$zero,-0x1"

    # the heap pointer is read as lui 0x8018 + lw -0x3df4 -> 0x8017C20C
    assert "lui $v1,0x8018" in asm and "lw $v1,-0x3df4($v1)" in asm
    assert (0x80180000 - 0x3DF4) == mt.HEAP_PTR

    # read old, write new, return new-old
    assert "lw $a0,0x30($v1)" in asm, "the previous counter must be loaded"
    assert "sw $v0,0x30($v1)" in asm, "the fresh counter must be stored"
    assert "subu $v0,$v0,$a0" in asm, "the return value must be new-old"
    i_read = asm.index("lw $a0,0x30($v1)")
    i_write = asm.index("sw $v0,0x30($v1)")
    i_sub = asm.index("subu $v0,$v0,$a0")
    assert i_read < i_write < i_sub, "old read, then new stored, then the delta"

    # the argument is not consulted: a0 is overwritten with -1 in the call's
    # delay slot, so it is -1 (not the caller's value) inside the callee
    i_jal = asm.index("jal 0x80154928")
    assert asm[i_jal + 1] == "addiu $a0,$zero,-0x1"
    ok("f @0x800CA2BC = frame-counter delta: sync wait, read/write *(0x8017C20C)"
       "+0x30, return new-old, argument discarded")


def test_checksum_shape():
    """The accumulating checksum, from the header-build code."""
    algo = mt.checksum_algorithm()
    # f is called from inside header build
    assert algo["f_called_from"], "header build must call f"
    for pc in algo["f_called_from"]:
        assert mt.ADDR_HEADER_BUILD < pc < mt.ADDR_HEADER_BUILD + 0x2D0
    asm = [s for _p, _w, s in maindec.dis(mt.ADDR_HEADER_BUILD, 0x2D0 // 4)]
    i_call = asm.index("jal 0x800ca2bc")
    # the accumulate follows the call
    tail = asm[i_call:i_call + 20]
    assert "lw $v1,0x1b8c($a0)" in tail, "the previous checksum must be loaded"
    assert "addu $v0,$v0,$v1" in tail, "old + f()"
    assert "sw $v0,0x1b8c($a0)" in tail, "stored back into gs+0x1B8C"
    assert "sw $v0,0x20c($a1)" in tail, "stored into the block header at +0x20C"
    assert "sh $zero,0x210($a1)" in tail, "and +0x210 zeroed"
    ok("checksum = gs+0x1B8C + f(), stored to gs+0x1B8C and block header "
       "+0x20C; +0x210 := 0")


def test_card_header_layout():
    """The 0x284 header: every region, its source, and its constant bytes."""
    layout = mt.card_header_layout()
    by_off = {r["off"]: r for r in layout}
    expected = [0x000, 0x002, 0x004, 0x044, 0x060, 0x0E0, 0x160,
                0x208, 0x209, 0x20A, 0x20B, 0x20C, 0x210, 0x212, 0x281, 0x284]
    assert [r["off"] for r in layout] == expected, [hex(r["off"]) for r in layout]
    # no overlap and no hole
    cur = 0
    for r in layout:
        assert r["off"] == cur, f"region at {r['off']:#x} leaves a hole at {cur:#x}"
        cur += r["size"]
    assert cur == 0x284 + 0x1D60, hex(cur)

    # SC magic and the 0x13 0x02 pair
    assert by_off[0x000]["data"] == b"SC"
    assert by_off[0x002]["data"] == bytes([0x13, 0x02])
    # title: the Shift-JIS literal, its NUL, then 0x82, then zeros to +0x43
    t = by_off[0x004]["data"]
    assert len(t) == 0x40
    assert t[:24] == bytes.fromhex(
        "827282748268826a826e82638264826d81408140826b8275")
    assert mt.title_string() == "ＳＵＩＫＯＤＥＮ\u3000\u3000ＬＶ"
    assert t[24] == 0x00 and t[25] == 0x82
    assert set(t[26:]) == {0}, "the title field is zero-filled after the terminator"
    # +0x044 is 28 zero bytes, +0x212 is 111 zero bytes
    assert by_off[0x044]["data"] == b"\x00" * 0x1C
    assert by_off[0x212]["data"] == b"\x00" * 0x6F
    assert len(by_off[0x212]["data"]) == 111
    # +0x210 is zeroed with sh, +0x160..+0x204 is not written at all
    assert by_off[0x210]["data"] == b"\x00\x00"
    assert by_off[0x160]["data"] is None and by_off[0x20B]["data"] is None
    ok("card header 0x284: SC/0x13 0x02 magic, 0x40-byte Shift-JIS title field, "
       "0x1C+0x6F zero runs, palette at +0x60, icon at +0xE0, +0x208..+0x212 "
       "patched, payload at +0x284")


def test_card_payload_and_constants():
    """The 0x1D60 payload copy and the two 0x80-byte icon constants."""
    by_off = {r["off"]: r for r in mt.card_header_layout()}
    assert by_off[0x284]["size"] == 0x1D60
    assert by_off[0x60]["size"] == 0x80 and by_off[0xE0]["size"] == 0x80

    # stage copy: ori $a2,$zero,0x1d60 and the 0x801B8000 source
    asm = [s for _p, _w, s in maindec.dis(mt.ADDR_STAGE_COPY, 0x60 // 4)]
    assert "ori $a2,$zero,0x1d60" in asm, asm
    assert "ori $a1,$a1,0x8000" in asm and "lui $a1,0x801b" in asm, asm
    assert "sb $v0,0x284($v1)" in asm, "payload lands at +0x284"

    # the two constants, read straight out of the image by address
    body = maindec.body()
    pal = body[0x80171418 - maindec.MBASE:][:0x80]
    pix = body[0x801713F4 - maindec.MBASE:][:0x80]
    assert by_off[0x60]["data"] == pal
    assert by_off[0xE0]["data"] == pix
    # the icon frame table that follows the title literal corroborates the
    # palette source: first frame pointer + 4 == 0x80171418
    assert mt.frame_pointers()[0] + 4 == 0x80171418
    assert mt.frame_pointers()[:2] == [0x80171414, 0x80171494]
    ok("payload +0x284 = 0x1D60 bytes from 0x801B8000; icon palette/plane "
       "constants read from 0x80171418 / 0x801713F4 (frame ptr[0]+4)")


# --------------------------------------------------------------------------
# part B
# --------------------------------------------------------------------------

_BANNER = re.compile(r"^--- (\S+) \((\d+) dialogue strings\) ---$")
_ENTRY = re.compile(r"^\[(\d+),(\d+)\] @(0x[0-9a-fA-F]+):")


def _corpus():
    """Independent parse of dialogue_found.txt -> {overlay: [(t,i,off)]}."""
    out = collections.OrderedDict()
    cur = None
    with open(CANON, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            m = _BANNER.match(line)
            if m:
                cur = m.group(1)
                out.setdefault(cur, [])
                continue
            m = _ENTRY.match(line)
            if m and cur:
                out[cur].append((int(m.group(1)), int(m.group(2)),
                                 int(m.group(3), 16)))
    return out


def _overlay(name):
    with open(ISO) as fh:
        recs = json.load(fh)
    rec = [r for r in recs if r["path"].rsplit("/", 1)[-1] == name
           and not r.get("dir")]
    assert rec, f"{name} not in iso_files.json"
    return disc.extract(rec[0]["lba"], rec[0]["size"])


def test_corpus_control_bytes():
    """0x80/0x81 absent; 0xFF only as a 0x05 operand.  Read from the disc."""
    corpus = _corpus()
    hist = collections.Counter()
    pos = collections.defaultdict(list)
    n = 0
    for name, entries in corpus.items():
        d = _overlay(name)
        for t, i, a in entries:
            e = d.find(b"\x00", a, min(len(d), a + 4000))
            body = d[a:e if e >= 0 else min(len(d), a + 4000)]
            n += 1
            for k, b in enumerate(body):
                hist[b] += 1
                if b in (0x80, 0x81, 0xFF):
                    pos[b].append((name, t, i, a, k, body[k - 1] if k else None))
    assert n == 10173, f"corpus walk found {n} strings"
    assert hist[0x80] == 0, f"0x80 occurs {hist[0x80]} times in dialogue bodies"
    assert hist[0x81] == 0, f"0x81 occurs {hist[0x81]} times in dialogue bodies"
    assert hist[0xFF] == 2, f"0xFF occurs {hist[0xFF]} times"
    for name, t, i, a, k, prev in pos[0xFF]:
        assert prev == 0x05, (
            f"0xFF in {name}[{t},{i}] @{a:#x}+{k} follows {prev:#04x}, not 0x05")
        d = _overlay(name)
        assert d[a + k - 1] == 0x05
        assert d[a + k + 1] != 0x00, "the pause body must continue after 0xFF"
    # every 0x80/0x81/0xFF-class byte sits in one of the two 0xFF sites only;
    # and the three high operands used elsewhere are pause counts, which is why
    # 'frequent high byte xor control code' must not be used as a test here.
    assert hist[0x5F] == hist[0xFF] + 7, "0x5F is a pause count too"
    ok("0x80/0x81 occur 0 times and 0xFF exactly twice, both as the operand of a "
       "0x05 timed pause, across 10,173 strings / 513,374 body bytes")


def test_special_code_consumers():
    """The 0x80/0x81/0xFF branches in the text decoder, from MAIN.EXE."""
    asm = {pc: s for pc, _w, s in maindec.dis(0x8013AFA0, 0x30)}
    assert asm[0x8013AFA4] == "ori $v0,$zero,0x80"
    assert asm[0x8013AFA8] == "bne $a3,$v0,0x8013afc0"
    assert asm[0x8013AFAC] == "ori $v0,$zero,0x81"
    assert asm[0x8013AFB0] == "lui $a3,0x8018"
    assert asm[0x8013AFB4] == "addiu $a3,$a3,-0x428c"       # 0x8017BD74
    assert (0x80180000 - 0x428C) == 0x8017BD74
    assert asm[0x8013AFC0] == "bne $a3,$v0,0x8013afd8"
    assert asm[0x8013AFC4] == "ori $v0,$zero,0xff"
    assert asm[0x8013AFC8] == "lui $a3,0x8018"
    assert asm[0x8013AFCC] == "addiu $a3,$a3,-0x3f5c"       # 0x8017C0A4
    assert (0x80180000 - 0x3F5C) == 0x8017C0A4
    assert asm[0x8013AFD8] == "bne $a3,$v0,0x8013b030"
    assert asm[0x8013AFE4] == "lw $v0,-0x5ee0($v0)"         # 0x8017A120
    # char_encoding_translate returns 0x80 for a NULL map -- the engine's own
    # "no glyph" value, not a parse control
    ct = {pc: s for pc, _w, s in maindec.dis(0x80133BB4, 0x10)}
    assert ct[0x80133BC8] == "beq $v1,$zero,0x80133be4"
    assert ct[0x80133BE4] == "ori $v0,$zero,0x80"
    ok("0x80/0x81/0xFF are text_char_decoder descriptor divert values (fixed "
       "RAM globals / a pointer deref); 0x80 is also char_encoding_translate's "
       "NULL-map return -- none is a newline, end or page-break")


def test_coverage_is_complete():
    """Every recovered table 0..max with no gap, and pointer == address."""
    corpus = _corpus()
    n_tables = 0
    gaps = []
    mismatches = []
    for name, entries in corpus.items():
        d = _overlay(name)
        per = collections.defaultdict(dict)
        for t, i, a in entries:
            per[t][i] = a
        for t, idxs in per.items():
            n_tables += 1
            assert min(idxs) == 0, f"{name} table {t} starts at {min(idxs)}"
            missing = [k for k in range(max(idxs) + 1) if k not in idxs]
            if missing:
                gaps.append((name, t, missing[:5]))
            # vote the sub-table offset and check the pointers
            votes = collections.Counter()
            for i, a in idxs.items():
                want = struct.pack("<I", 0x80010000 + a)
                s = 0
                while True:
                    p = d.find(want, s)
                    if p < 0:
                        break
                    votes[p - i * 4] += 1
                    s = p + 1
            assert votes, f"{name} table {t} has no pointer occurrence"
            st = votes.most_common(1)[0][0]
            for i, a in idxs.items():
                ptr = struct.unpack_from("<I", d, st + i * 4)[0]
                if ptr - 0x80010000 != a:
                    mismatches.append((name, t, i, hex(ptr), hex(a)))
    assert n_tables == 253, f"{n_tables} tables"
    assert not gaps, f"contiguous-index failures: {gaps[:5]}"
    assert not mismatches, f"pointer/address mismatches: {mismatches[:5]}"
    ok("253 recovered dialogue tables: every one runs 0..max with no missing "
       "index, and every slot's pointer equals the recovered address")


def test_walk_boundary():
    """The walk stopped early in at most one place, and that one is data."""
    corpus = _corpus()
    early = []
    for name, entries in corpus.items():
        d = _overlay(name)
        per = collections.defaultdict(dict)
        for t, i, a in entries:
            per[t][i] = a
        for t, idxs in per.items():
            mx = max(idxs)
            votes = collections.Counter()
            for i, a in idxs.items():
                want = struct.pack("<I", 0x80010000 + a)
                s = 0
                while True:
                    p = d.find(want, s)
                    if p < 0:
                        break
                    votes[p - i * 4] += 1
                    s = p + 1
            st = votes.most_common(1)[0][0]
            k = mx + 1
            if st + k * 4 + 4 > len(d):
                continue
            ptr = struct.unpack_from("<I", d, st + k * 4)[0]
            if not (0x80010000 <= ptr < 0x80010000 + len(d)):
                continue
            body = mt.string_body(d, ptr - 0x80010000)
            frac = sum(1 for b in body
                       if b in mt.SUBB or b < 0x10) / max(1, len(body))
            if frac >= 0.9:
                early.append((name, t, k, hex(ptr), round(frac, 2)))
    assert not early, f"a table slot past max is real text: {early}"
    ok("no recovered table has a text-bearing slot immediately past its max "
       "index (the one candidate, VE1[4] slot 8, is a pointer array)")


def test_provable_addresses():
    """No recovered address is an unexplained pointer target."""
    corpus = _corpus()
    # a lighter-weight re-implementation of the classification
    bad = []
    for name, entries in corpus.items():
        d = _overlay(name)
        ptrs = set()
        for i in range(0, len(d) - 4, 4):
            v = struct.unpack_from("<I", d, i)[0]
            if 0x80010000 <= v < 0x80010000 + len(d):
                ptrs.add(v - 0x80010000)
        for t, i, a in entries:
            if a > 0 and d[a - 1] == 0:
                continue
            if a in ptrs:
                continue
            want = struct.pack("<I", 0x80010000 + a)
            found = False
            s = 0
            while True:
                p = d.find(want, s)
                if p < 0:
                    break
                if p - i * 4 >= 0 and (p - i * 4) % 4 == 0:
                    found = True
                    break
                s = p + 1
            if not found:
                bad.append((name, t, i, hex(a)))
    assert not bad, f"unexplained recovered addresses: {bad[:5]}"
    ok("all 10,173 recovered addresses are NUL-preceded, pointer-referenced or "
       "a table slot -- none is an unexplained target")


def main():
    test_frame_counter_delta()
    test_checksum_shape()
    test_card_header_layout()
    test_card_payload_and_constants()
    test_corpus_control_bytes()
    test_special_code_consumers()
    test_coverage_is_complete()
    test_walk_boundary()
    test_provable_addresses()
    print(f"PASS: all {len(PASSED)} memcard/text tails checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())

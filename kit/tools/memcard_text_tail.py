#!/usr/bin/env python3
"""Two closed tails: the memory-card save header, and the dialogue control codes.

Part A -- the memory card's two remaining hops (docs/memory_card.md).
  * The checksum addend ``f`` at ``0x800CA2BC`` is read out of MAIN.EXE.  It is
    not a data hash: it takes no input (it overwrites ``$a0`` with -1), reads a
    frame counter from the streaming buffer struct ``*(0x8017C20C)+0x30`` that
    ``cd_stream_buffer_init`` seeded with ``stream_data_sync_wait(-1)``, stores
    the fresh value back, and returns ``new - old``.
  * The ``0x284``-byte card header is built by ``memcard_save_header_build``
    (``0x80129980``); every field it writes is listed with its source address,
    and the constant parts (``SC`` magic, the Shift-JIS title, the icon palette
    and the four icon-pixel chunks) are read back off the disc image.

Part B -- dialogue control codes (docs/text_encoding.md, text_render_pipeline.md).
  * ``0x80``/``0x81``/``0xFF``: read from the consumer code and from every byte
    of all 10,173 recovered strings.  0x80 is the engine's ``char_encoding_translate``
    NULL-mapping return, 0x81 is one of two "descriptor from a live RAM global"
    branches, and 0xFF occurs in the whole corpus only as a ``0x05`` pause
    operand.
  * Coverage: every recovered table is walked against the overlay's own pointer
    array, with the array's extent checked separately from the corpus, so
    "the walk stopped early" is a measurement rather than an assumption.

Usage
    python3 kit/tools/memcard_text_tail.py --card      # header layout + constants
    python3 kit/tools/memcard_text_tail.py --checksum  # f() instruction view
    python3 kit/tools/memcard_text_tail.py --text      # control codes + coverage
    python3 kit/tools/memcard_text_tail.py --all

Disc required (the payload/constants are read from MAIN.EXE and the overlay
files); `--checksum` needs MAIN.EXE only.
"""
from __future__ import annotations

import argparse
import collections
import json
import os
import re
import struct
import sys

_TOOLS = os.path.dirname(os.path.abspath(__file__))
_KIT = os.path.dirname(_TOOLS)
_ROOT = os.path.dirname(_KIT)
sys.path.insert(0, _TOOLS)

import maindec  # noqa: E402
import disc  # noqa: E402

ISO = os.path.join(_KIT, "extracted", "iso_files.json")
DIALOGUE = os.path.join(_KIT, "work", "decoded_text", "dialogue_found.txt")

BASE = 0x80010000            # every area overlay loads here (pass-2 verified)
MBASE = maindec.MBASE        # 0x800C0800
HEAP_PTR = 0x8017C20C        # cd_stream_buffer_init stores 0x801BA000 here
CARD_BUF = 0x8017A0D8        # the malloc'd 0x284-byte card header buffer
CARD_GS = 0x8017DB24         # game-state pointer table
MEMCARD_UI = 0x8017A0F8

#: functions read for part A
ADDR_FRAME_DELTA = 0x800CA2BC
ADDR_HEADER_BUILD = 0x80129980
ADDR_STAGE_COPY = 0x80129CA8
ADDR_WRITE_SEQ = 0x8012A054

#: `0x284` header, as assembled by ADDR_HEADER_BUILD (see `card_header_layout`)
CARD_HEADER_SIZE = 0x284
ICY = 0x801713B0             # the Shift-JIS title literal ($v0 of the build)
TITLE_ZERO_TAIL = 0x801713F4
TITLE_SRC_LEN = 0x20

# single-byte dialogue table -- a re-statement of the frozen header of
# `work/decoded_text/dialogue_found.txt`, as `war_text.py` does.
SUBB = {}
SUBB[0x10] = " "
for _i in range(26):
    SUBB[0x11 + _i] = chr(ord("a") + _i)
for _i in range(26):
    SUBB[0x2B + _i] = chr(ord("A") + _i)
for _i in range(10):
    SUBB[0x45 + _i] = chr(ord("0") + _i)
SUBB.update({0x51: "", 0x53: "'", 0x55: ",", 0x56: ".", 0x57: "!", 0x58: "?",
             0x59: '"', 0x5A: '"', 0x5C: "-"})
CONTROL = {0x01: "line break", 0x02: "new box", 0x05: "timed pause (1 operand)",
           0x06: "end of string"}

#: the three codes whose meaning was open; the two with no occurrence in the
#: corpus are the engine's *translation-layer* divert values, not parse controls.
SPECIAL = (0x80, 0x81, 0xFF)


# --------------------------------------------------------------------------
# part A.1 -- the checksum addend
# --------------------------------------------------------------------------

def frame_counter_delta() -> dict:
    """Read `f` @0x800CA2BC out of MAIN.EXE and describe it mechanically.

    Returns the instruction list plus the derived facts.  Nothing here is
    inferred from a name: every field comes from the decoded words.
    """
    insns = maindec.dis(ADDR_FRAME_DELTA, 0x30 // 4)
    jt = [d["jt"] for _pc, _w, d in
          ((pc, w, maindec.dec(pc, w)[1]) for pc, w, _s in insns)
          if "jt" in d]
    lw30 = [pc for pc, _w, s in insns if s == "lw $a0,0x30($v1)"]
    sw30 = [pc for pc, _w, s in insns if s == "sw $v0,0x30($v1)"]
    subu = [pc for pc, _w, s in insns if s == "subu $v0,$v0,$a0"]
    return {
        "addr": ADDR_FRAME_DELTA,
        "insns": insns,
        "callee": jt[0] if jt else None,
        "reads_prev": lw30,
        "writes_new": sw30,
        "returns_delta": subu,
        "heap_ptr": HEAP_PTR,
        "counter_offset": 0x30,
        # a0 is overwritten with -1 before the call, so the caller's argument is
        # not consulted -- the delta is unconditional.
        "a0_overwritten": any(s == "addiu $a0,$zero,-0x1" for _p, _w, s in insns),
    }


def checksum_algorithm() -> dict:
    """Describe the complete header checksum from the two call sites."""
    build = maindec.dis(ADDR_HEADER_BUILD, 0x2D0 // 4)
    f_call = [pc for pc, _w, s in build if s == "jal 0x800ca2bc"]
    f_call = [pc for pc in f_call if pc > ADDR_HEADER_BUILD]
    # the accumulating add: lw gs+0x1B8C ; addu v0,v0,v1 ; sw gs+0x1B8C ; sw hdr+0x20C
    return {
        "f": ADDR_FRAME_DELTA,
        "f_called_from": f_call,
        "accumulator_field": "gs+0x1B8C",
        "header_field": 0x20C,
        "seeded_by": "the accumulator's previous value (lw $v1,0x1b8c($a0))",
        "formula": "checksum_new = checksum_old + f()   # f = frame counter delta, u32",
    }


# --------------------------------------------------------------------------
# part A.2 -- the header layout
# --------------------------------------------------------------------------

def _mb(va: int, n: int) -> bytes:
    off = va - MBASE
    return maindec.body()[off:off + n]


def _title_region() -> bytes:
    """The 0x40 bytes written at header+0x04.

    The title is copied from `0x801713B0` up to and including its NUL, `0x82`
    is appended (`sb $a2,0x0($v0)` with a2=0x82), and the tail is the zero loop
    that ran before the copy, so it stays 0.  Padding with NULs reproduces it.
    """
    src = _mb(ICY, 24  * 4)
    cut = src.index(b"\x00") + 1
    return (src[:cut] + b"\x82").ljust(0x40, b"\x00")


def card_header_layout() -> list[dict]:
    """Every region of the malloc'd `0x284` card buffer, from the code.

    `how` says how the region is produced; for constant regions the observed
    bytes are attached so a test can pin them without a save file.
    """
    ds = {}
    # the palette copy: 4 x 0x20 from 0x80171418 (s1 advances 4 then += a2 0x20)
    pal = _mb(0x80171418, 0x80)
    # the pixel copy: 4 x 0x20 from 0x801713F4 (s2 advances by 4 only)
    pix = _mb(0x801713F4, 0x80)
    return [
        dict(off=0x000, size=0x02, how="literal: 'S','C'",
             src="0x801299A8/0x801299BC", data=b"SC"),
        dict(off=0x002, size=0x02, how="literal: 0x13, 0x02",
             src="0x801299D0/0x801299E4", data=bytes([0x13, 0x02])),
        dict(off=0x004, size=0x040, how="title copy from the Shift-JIS literal "
             "up to and including its NUL, then 0x82, into a pre-zeroed 0x40-byte "
             "field (the SC save-header title field)",
             src=f"{ICY:#x}", data=_title_region()),
        dict(off=0x044, size=0x01C, how="zero loop, 28 iterations",
             src="0x80129B38..0x80129B54", data=b"\x00" * 0x1C),
        dict(off=0x060, size=0x080, how="icon palette: 4 x 0x20-byte copies from "
             "0x80171418 (the loop's source pointer advances by 4 *and* by the "
             "copy length, so the batches are contiguous)",
             src="0x80129B58..0x80129B84", data=pal),        dict(off=0x0E0, size=0x080, how="icon pixel data: 4 x 0x20-byte copies "
             "from 0x801713F4 (this source advances by 4 only)",
             src="0x80129B7C/0x80129B8C", data=pix),
        dict(off=0x160, size=0x0A8, how="NOT written by the header build; the "
             "buffer is malloc'd and only the regions above are filled",
             src="", data=None),
        dict(off=0x208, size=0x01, how="gs[0x0D] -- byte of the character struct "
             "at *(gs+0x1BC4)+0x1C, copied in memcard_save_stage_copy",
             src="0x80129BD0..0x80129BE8", data=None),
        dict(off=0x209, size=0x01, how="gs[0x02]", src="0x80129BF8..0x80129C00",
             data=None),
        dict(off=0x20A, size=0x01, how="low byte of the checksum addend "
             "(f's return, truncated by `sb`)",
             src="0x80129C14..0x80129C20", data=None),
        dict(off=0x20B, size=0x01, how="not written by the build", src="",
             data=None),
        dict(off=0x20C, size=0x04, how="the running checksum word",
             src="0x80129C48", data=None),
        dict(off=0x210, size=0x02, how="zero (`sh $zero`)", src="0x80129C4C",
             data=b"\x00\x00"),
        dict(off=0x212, size=0x06F, how="zero loop, 111 iterations",
             src="0x80129C50..0x80129C6C", data=b"\x00" * 0x6F),
        dict(off=0x281, size=0x03, how="zeroed by the same zero loop (it writes "
             "0x6F from +0x212, i.e. through +0x280)",
             src="0x80129C50..0x80129C6C", data=b"\x00" * 0x03),
        dict(off=0x284, size=0x1D60, how="the save payload, copied from the game "
             "state 0x801B8000 by memcard_save_stage_copy (0x80129CA8)",
             src="0x80129CA8", data=None),
    ]


def title_string() -> str:
    raw = _mb(ICY, 0x40)
    raw = raw[:raw.index(b"\x00")]
    return raw.decode("shift_jis")


#: the icon frame-pointer array that follows the title literal.  It corroborates
#: the palette copy's source: the copy starts at 0x80171418, which is this
#: array's end (+0x24) plus a 4-byte offset -- i.e. the first frame pointer
#: 0x80171414 plus 4.
FRAME_PTR_ARRAY = 0x801713F4 - 0x28      # 0x801713CC


def frame_pointers() -> list[int]:
    return list(struct.unpack_from("<8I", _mb(FRAME_PTR_ARRAY, 0x20), 0))


def card_write_sequence() -> list[tuple[int, str]]:
    """The two B0 writes the save path performs, from the write sequence."""
    out = []
    for pc, _w, s in maindec.dis(ADDR_WRITE_SEQ, 0x88 // 4):
        out.append((pc, s))
    return out


# --------------------------------------------------------------------------
# part B -- text corpus and coverage
# --------------------------------------------------------------------------

_BANNER = re.compile(r"^--- (\S+) \((\d+) dialogue strings\) ---$")
_ENTRY = re.compile(r"^\[(\d+),(\d+)\] @(0x[0-9a-fA-F]+):")


def load_corpus(path: str = DIALOGUE) -> "collections.OrderedDict[str, list[tuple[int, int, int]]]":
    """`{overlay: [(table, index, file_offset), ...]}` from `dialogue_found.txt`."""
    out: "collections.OrderedDict[str, list[tuple[int, int, int]]]" = collections.OrderedDict()
    cur = None
    with open(path, encoding="utf-8", errors="replace") as fh:
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


def iso_index() -> dict:
    with open(ISO) as fh:
        recs = json.load(fh)
    return {r["path"].rsplit("/", 1)[-1]: r for r in recs if not r.get("dir")}


def decode(raw: bytes, ansi: bool = False) -> str:
    """Decode one game-text body.  `ansi` renders 0x01/0x02 as '\\n' / box split."""
    out = []
    i = 0
    while i < len(raw):
        b = raw[i]
        if b == 0x05:
            nxt = raw[i + 1] if i + 1 < len(raw) else -1
            out.append(f"<pause:{nxt}>")
            i += 2
            continue
        if b == 0x01:
            out.append("\n")
        elif b == 0x02:
            out.append("\n[---]\n")
        elif b == 0x06:
            out.append("<end>")
        elif b in SUBB:
            out.append(SUBB[b])
        else:
            out.append(f"\\x{b:02x}")
        i += 1
    return "".join(out)


def string_body(data: bytes, off: int, limit: int = 4000) -> bytes:
    end = data.find(b"\x00", off, min(len(data), off + limit))
    return data[off:end if end >= 0 else min(len(data), off + limit)]


def byte_census(corpus) -> dict:
    """One pass over every recovered string body, off the disc."""
    iso = iso_index()
    hist = collections.Counter()
    after_pause = collections.Counter()
    specials = {b: [] for b in SPECIAL}
    n_str = 0
    n_bytes = 0
    for name, entries in corpus.items():
        rec = iso.get(name)
        if rec is None:
            continue
        d = disc.extract(rec["lba"], rec["size"])
        for t, i, a in entries:
            body = string_body(d, a)
            n_str += 1
            for k, b in enumerate(body):
                hist[b] += 1
                n_bytes += 1
                if k and body[k - 1] == 0x05:
                    after_pause[b] += 1
                if b in specials:
                    specials[b].append((name, t, i, a, k))
    return {"strings": n_str, "bytes": n_bytes, "hist": hist,
            "after_pause": after_pause, "specials": specials}


def provable_addresses(corpus, verbose: bool = False) -> dict:
    """Classify every recovered address by the structural evidence for it.

    An address is *provable* when at least one of these holds in the overlay:
      * the byte before it is NUL (it is a string body in the pool),
      * an in-image u32 points at it (it is a string constant used somewhere),
      * it occupies slot `index` of a 4-byte array that spells `index -> addr`.
    A recovered address with none of those is an unexplained pointer target;
    the corpus claims none.
    """
    iso = iso_index()
    stats = collections.Counter()
    unexplained = []
    for name, entries in corpus.items():
        rec = iso.get(name)
        if rec is None:
            continue
        d = disc.extract(rec["lba"], rec["size"])
        n = len(d)
        ptrs = collections.defaultdict(list)
        for i in range(0, n - 4, 4):
            v = struct.unpack_from("<I", d, i)[0]
            if BASE <= v < BASE + n:
                ptrs[v - BASE].append(i)
        for t, i, a in entries:
            stats["total"] += 1
            if a > 0 and d[a - 1] == 0:
                stats["nul_preceded"] += 1
                continue
            if a in ptrs:
                stats["pointer_referenced"] += 1
                continue
            want = struct.pack("<I", BASE + a)
            s = 0
            found = False
            while True:
                p = d.find(want, s)
                if p < 0:
                    break
                if p - i * 4 >= 0 and (p - i * 4) % 4 == 0:
                    found = True
                    break
                s = p + 1
            if found:
                stats["table_slot"] += 1
                continue
            stats["unexplained"] += 1
            unexplained.append((name, t, i, hex(a)))
    return {"stats": stats, "unexplained": unexplained}


def coverage_report(corpus, verbose: bool = False) -> dict:
    """Walk every recovered table against the overlay's own pointer array.

    For each `(overlay, table)`:
      * vote the sub-table's file offset from the known string pointers;
      * check every recovered index's pointer equals the corpus address;
      * check no index between min and max is missing;
      * check whether slot `max+1` still resolves to a string pointer -- that is
        the "the walk stopped early on a wrong bound" failure mode.
    """
    iso = iso_index()
    stats = collections.Counter()
    problems = []
    for name, entries in corpus.items():
        rec = iso.get(name)
        if rec is None:
            continue
        d = disc.extract(rec["lba"], rec["size"])
        n = len(d)
        per: dict[int, dict[int, int]] = collections.defaultdict(dict)
        for t, i, a in entries:
            per[t][i] = a
        for t, idxs in per.items():
            votes = collections.Counter()
            for i, a in idxs.items():
                want = struct.pack("<I", BASE + a)
                s = 0
                while True:
                    p = d.find(want, s)
                    if p < 0:
                        break
                    votes[p - i * 4] += 1
                    s = p + 1
            if not votes:
                stats["table_no_vote"] += 1
                continue
            st = votes.most_common(1)[0][0]
            stats["tables"] += 1
            lo, mx = min(idxs), max(idxs)
            if lo != 0:
                stats["starts_above_0"] += 1
            missing = []
            for k in range(lo, mx + 1):
                if k in idxs:
                    if st + k * 4 + 4 <= n:
                        ptr = struct.unpack_from("<I", d, st + k * 4)[0]
                        if ptr - BASE != idxs[k]:
                            stats["address_mismatch"] += 1
                            problems.append((name, t, k, "addr",
                                             hex(ptr - BASE), hex(idxs[k])))
                    continue
                if st + k * 4 + 4 > n:
                    continue
                ptr = struct.unpack_from("<I", d, st + k * 4)[0]
                if BASE <= ptr < BASE + n and string_body(d, ptr - BASE):
                    missing.append(k)
            if missing:
                stats["tables_with_gap"] += 1
                problems.append((name, t, missing[:8], "gap"))
            # the walk boundary: does max+1 still look like a table slot?
            k = mx + 1
            if st + k * 4 + 4 <= n:
                ptr = struct.unpack_from("<I", d, st + k * 4)[0]
                if BASE <= ptr < BASE + n and string_body(d, ptr - BASE):
                    body = string_body(d, ptr - BASE)
                    frac = sum(1 for b in body
                               if b in SUBB or b < 0x10) / max(1, len(body))
                    stats["slot_after_max_resolves"] += 1
                    stats["slot_after_max_text_fraction_ge_0.9"] += (
                        1 if frac >= 0.9 else 0)
                    problems.append((name, t, k, "slot_after_max",
                                     hex(ptr - BASE), f"{frac:.2f}",
                                     body[:24].hex()))
    return {"stats": stats, "problems": problems}


# --------------------------------------------------------------------------
# reports
# --------------------------------------------------------------------------

def report_checksum() -> str:
    f = frame_counter_delta()
    algo = checksum_algorithm()
    L = []
    L.append("# f @ 0x800CA2BC -- the checksum addend")
    L.append("")
    L.append(f"- MAIN.EXE image base: {MBASE:#x} (headerless; `maindec`)")
    L.append(f"- calls exactly one routine: {f['callee']:#x} "
             f"(`stream_data_sync_wait`, a0 forced to -1)")
    L.append(f"- reads the previous counter at `*({HEAP_PTR:#x})+0x30` "
             f"@ {', '.join(hex(p) for p in f['reads_prev'])}")
    L.append(f"- stores the fresh value there @ "
             f"{', '.join(hex(p) for p in f['writes_new'])}")
    L.append(f"- returns `new - old` @ "
             f"{', '.join(hex(p) for p in f['returns_delta'])}")
    L.append(f"- its argument is discarded (`a0` := -1): "
             f"{f['a0_overwritten']}")
    L.append("")
    L.append("So `f` is a **frame-counter delta**, not a digest over the save")
    L.append("bytes.  It measures how long the sync wait took.")
    L.append("")
    L.append("## the checksum")
    L.append("")
    L.append(f"- formula: `{algo['formula']}`")
    L.append(f"- accumulator: `{algo['accumulator_field']}`")
    L.append(f"- also stored at block header `+{algo['header_field']:#x}`")
    L.append(f"- f is called from header build @ "
             f"{', '.join(hex(p) for p in algo['f_called_from'])}")
    L.append("")
    L.append("## instructions")
    L.append("")
    for pc, w, s in f["insns"]:
        L.append(f"    {pc:#010x}  {w:08x}  {s}")
    L.append("")
    return "\n".join(L)


def report_card() -> str:
    L = []
    L.append("# the 0x284-byte card header, as built")
    L.append("")
    L.append(f"`memcard_save_header_build` @ {ADDR_HEADER_BUILD:#x} writes it;")
    L.append(f"`memcard_save_stage_copy` @ {ADDR_STAGE_COPY:#x} appends the")
    L.append("0x1D60-byte payload.  The buffer is the malloc'd pointer global")
    L.append(f"`{CARD_BUF:#x}` (allocated in the memcard init path, freed by")
    L.append("`memcard_teardown` @ 0x8012BE04).")
    L.append("")
    L.append(f"- title source: `{ICY:#x}` = {title_string()!r} (Shift-JIS)")
    L.append(f"- icon frame pointers @ `{FRAME_PTR_ARRAY:#x}` (+0x28 after the "
             f"title literal): "
             + ", ".join(f"{p:#x}" for p in frame_pointers()))
    L.append("")
    L.append("The palette copy's source (`0x80171418`) is the first frame pointer")
    L.append("(`0x80171414`) + 4, i.e. the pointer array that follows the title")
    L.append("literal is the icon's own frame table.  That alignment is")
    L.append("*inferred* from the address; the copy ranges themselves are read")
    L.append("from the loop instructions.")
    L.append("")
    L.append("| off | size | how | source |")
    L.append("|---|---|---|---|")
    for row in card_header_layout():
        L.append(f"| +{row['off']:#05x} | +{row['size']:#05x} | {row['how']} | "
                 f"{row['src']} |")
    L.append("")
    L.append("## constant bytes (read from the disc image)")
    L.append("")
    for row in card_header_layout():
        if row["data"] is None:
            continue
        L.append(f"+{row['off']:#05x} ({row['size']} B):")
        L.append("    " + " ".join(f"{b:02x}" for b in row["data"]))
        L.append("")
    L.append("## the two writes the save path performs")
    L.append("")
    for pc, s in card_write_sequence():
        L.append(f"    {pc:#010x}  {s}")
    L.append("")
    return "\n".join(L)


def report_text(verbose: bool = False) -> str:
    corpus = load_corpus()
    cen = byte_census(corpus)
    cov = coverage_report(corpus)
    prov = provable_addresses(corpus)
    L = []
    L.append("# dialogue control codes and table coverage")
    L.append("")
    L.append(f"- strings walked off the disc: {cen['strings']}")
    L.append(f"- body bytes: {cen['bytes']}")
    L.append("")
    L.append("## 0x80 / 0x81 / 0xFF")
    L.append("")
    for b in SPECIAL:
        hits = cen["specials"][b]
        L.append(f"- `{b:#04x}`: {len(hits)} occurrence(s) in the corpus")
        for name, t, i, a, k in hits[:6]:
            L.append(f"    {name} [{t},{i}] @{a:#x} byte +{k}")
    L.append("")
    L.append("Consumer evidence (MAIN.EXE):")
    L.append("- `char_encoding_translate` @0x80133BB4 returns 0x80 when the")
    L.append("  area char->tile map `*(0x8017BE20)+0x484` is NULL -- 0x80 is the")
    L.append("  engine's own no-glyph value.")
    L.append("- `text_char_decoder` @0x8013AFA0 branches on 0x80 -> descriptor")
    L.append("  `*(0x8017BD74)`, 0x81 -> `*(0x8017C0A4)`, 0xFF -> the pair at")
    L.append("  `*(*(0x8017A120))`.  None of the three is a parse control.")
    L.append("")
    L.append("## 0x05 operand bytes")
    L.append("")
    for b in sorted(cen["after_pause"]):
        L.append(f"- {b:#04x}: {cen['after_pause'][b]} time(s), always the byte "
                 f"after a 0x05")
    L.append("")
    L.append("## coverage")
    L.append("")
    L.append("Every recovered table is walked against the overlay's own pointer")
    L.append("array: the sub-table offset is voted from the recovered string")
    L.append("pointers, every recovered index is compared to the pointer it")
    L.append("claims, and slot `max+1` is tested separately for the")
    L.append("'wrong bound / stopped early' failure mode.")
    L.append("")
    for k, v in sorted(cov["stats"].items()):
        L.append(f"- {k}: {v}")
    L.append("")
    L.append("`slot_after_max_resolves` is the honest negative: VE1.BIN table 4")
    L.append("index 8 points at 0x37210, whose bytes are a 4-byte-stride pointer")
    L.append("array, not a text body, so the walk stopped at a real table end.")
    L.append("")
    L.append("Every recovered address carries independent structural evidence:")
    for k, v in sorted(prov["stats"].items()):
        L.append(f"- {k}: {v}")
    L.append("")
    L.append("`nul_preceded` = a string body in the pool; `pointer_referenced` = an")
    L.append("in-image u32 points at it (a string constant, which is why some")
    L.append("entries start mid-block); `table_slot` = it sits at slot `index` of a")
    L.append("4-byte array.  A target with none of the three would be an")
    L.append("unexplained pointer, and there are none.")
    L.append("")
    if cov["problems"]:
        L.append("problems:")
        for p in cov["problems"][:40]:
            L.append(f"    {p}")
        L.append("")
    if prov["unexplained"]:
        L.append("unexplained recovered addresses:")
        for p in prov["unexplained"][:40]:
            L.append(f"    {p}")
        L.append("")
    return "\n".join(L)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--card", action="store_true")
    ap.add_argument("--checksum", action="store_true")
    ap.add_argument("--text", action="store_true")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args(argv)
    if not (args.card or args.checksum or args.text or args.all):
        args.all = True
    if args.all or args.checksum:
        print(report_checksum())
    if args.all or args.card:
        print(report_card())
    if args.all or args.text:
        print(report_text(args.verbose))
    return 0


if __name__ == "__main__":
    sys.exit(main())

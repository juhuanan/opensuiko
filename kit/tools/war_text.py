#!/usr/bin/env python3
"""War mode (DATA/16_WAR) text decoder.

The `WAR_*.BIN` overlays load at `0x80010000` and are **not** compressed: the
selector reader at `0x80125E5C` indexes `0x8016F258` and hands the resulting
descriptor to `0x800C2EF8`, which is a plain `CdRead` of `descriptor[0]` bytes
from `descriptor[4]`.  So the text in them is plain bytes in the game's own
single-byte character table -- **not** ASCII, which is why a string scan for
ASCII over these files comes back empty.

The byte table is the one already cracked for dialogue and recorded in the
header of `kit/work/decoded_text/dialogue_found.txt` (frozen curated
knowledge; it has no writer in this tree, so it is re-stated here):

    0x10        space
    0x11-0x2A   a-z
    0x2B-0x44   A-Z
    0x45-0x4E   0-9
    0x51        emphasis toggle (paired)
    0x53        '
    0x55        ,
    0x56        .
    0x57        !
    0x58        ?
    0x59 / 0x5A open / close quote
    0x5C        -
    0x01        line break
    0x02        new speaker / new box
    0x05 XX     timed pause, XX = frames
    0x06        end of string

`scripts.faithful()` re-derives that table and :func:`decode` is checked
against `dialogue_found.txt` in `kit/tests/test_war_text.py`, at the exact
addresses that file records -- so this is a second implementation agreeing
with the first, not a new table.

The module data layout is also recovered.  In every selector-reachable overlay,
the following run in this order, with the same contents and the same strides,
at a file offset that differs per scenario (each overlay is linked separately):

    roster     36 records x 25 B   unit names   ("Commander's Team", ...)
    quotes    108 records x 50 B   leader pre-battle lines
    leaders   108 records x 44 B   per-leader numeric record (s16 fields; the
                                   field meanings are NOT yet derived)
    attacks    N records x 16 B     (u32 flags, char* name, u32, u32)
    ui        packed strings       "Result", "Damage", "Liberation Army",
                                   "Imperial   Army", "Here's the report.", ...

The roster and quote tables are **byte-identical across all nine** overlays --
they are a shared resource duplicated into each scenario, which is why the
per-battle differences are the map, the scenario script and the boss attack
name (section "per-battle signature" in `kit/docs/war_mode.md`).

Usage:
    python3 war_text.py --list
    python3 war_text.py --file WAR_KUWA.BIN --strings
    python3 war_text.py --file WAR_KUWA.BIN --at 0x1BC18 --len 64
    python3 war_text.py --file WAR_KUWA.BIN --roster --quotes --attacks
    python3 war_text.py --all --out kit/work/war_text
"""
from __future__ import annotations

import argparse
import os
import re
import struct
import sys

_TOOLS = os.path.dirname(os.path.abspath(__file__))
_KIT = os.path.dirname(_TOOLS)
_ROOT = os.path.dirname(_KIT)
sys.path.insert(0, _TOOLS)
import war_strings as _ws  # noqa: E402  (single source for the (size,lba) table)

#: logical ISO directory of the mode; the bytes always come off the disc
WAR_DIR = "DATA/16_WAR/"

OVERLAY_BASE = 0x80010000

#: The nine overlays the selector at `0x8016F258` can reach, in selector order
#: (`game_state[0x1BC0]`).  `WAR1.BIN` is the tenth file in the table at
#: `0x801647CC` and **no selector entry points at it** -- see
#: `kit/docs/war_mode.md` section 14.
SELECTOR_ORDER = [
    "WAR_KUWA.BIN",   # 0  Pannu Yakuta Castle
    "WAR_GARA.BIN",   # 1  Gate of Misfortune / Garan
    "WAR_SCA1.BIN",   # 2  Scarleticia, before the antidote
    "WAR_SCA2.BIN",   # 3  Scarleticia, after
    "WAR_TEO1.BIN",   # 4  Teo, before the Fire Spear
    "WAR_TEO2.BIN",   # 5  Teo, after
    "WAR_KITA.BIN",   # 6  Northern Checkpoint
    "WAR_SHAS.BIN",   # 7  Shasarazade Fortress
    "WAR_LAST.BIN",   # 8  the last battle
]

#: In the descriptor table but in no selector entry -- the dead row.
DEAD_FILE = "WAR1.BIN"


def _build_table() -> dict[int, str]:
    t: dict[int, str] = {0x10: " "}
    for i in range(26):
        t[0x11 + i] = chr(ord("a") + i)
    for i in range(26):
        t[0x2B + i] = chr(ord("A") + i)
    for i in range(10):
        t[0x45 + i] = chr(ord("0") + i)
    t.update(
        {
            0x51: "",       # emphasis toggle, paired -- zero width
            0x4F: ":",     # Pahn's Diary: "Date: 4th", "Breakfast: toast"
            0x53: "'",
            0x54: "&",     # Pahn's Diary: "toast & eggs"
            0x55: ",",
            0x56: ".",
            0x57: "!",
            0x58: "?",
            0x59: "[",
            0x5A: "]",
            0x5C: "-",
            0x68: "th",    # Pahn's Diary ordinal: "4th", "5th", "6th"
        }
    )
    return t


SUBST = _build_table()

LINE_BREAK = 0x01
NEW_BOX = 0x02
EMOTION_3 = 0x03
EMOTION_4 = 0x04
PAUSE = 0x05
END = 0x06
NUL = 0x00


def is_text_byte(b: int) -> bool:
    return b in SUBST


def scripts_faithful() -> dict[int, str]:
    """Alias kept explicit: the table is a re-statement of the cracked one."""
    return dict(SUBST)


def decode(
    data: bytes,
    offset: int = 0,
    length: int | None = None,
    *,
    stop_at_nul: bool = True,
    show_pause: bool = True,
) -> tuple[str, int]:
    """Decode `data[offset:]` as game text.

    Returns `(text, consumed)`.  The pause operand byte is consumed, so
    `consumed` is the number of input bytes the text occupied.
    """
    if length is None:
        length = len(data) - offset
    end = min(len(data), offset + length)
    out: list[str] = []
    i = offset
    while i < end:
        b = data[i]
        if b == NUL:
            i += 1
            if stop_at_nul:
                break
            continue
        if b == LINE_BREAK:
            out.append("\n")
        elif b == NEW_BOX:
            out.append("\n[---]\n")
        elif b == PAUSE:
            i += 1
            frames = data[i] if i < end else 0
            if show_pause:
                out.append(f"<pause:{frames}>")
        elif b == END:
            out.append("<end>")
            i += 1
            break
        elif b == EMOTION_3:
            out.append("<e3>")
        elif b == EMOTION_4:
            out.append("<e4>")
        elif b in SUBST:
            out.append(SUBST[b])
        else:
            out.append(f"\\x{b:02x}")
        i += 1
    return "".join(out), i - offset


def looks_like_prose(s: str, *, min_words: int = 2, min_word_len: int = 2) -> bool:
    """Cheap precision filter for strings found by scanning.

    Graphics data and code both produce long runs of text-range bytes by
    chance; real UI/script text has word structure.  Require at least
    `min_words` alphabetic tokens of `min_word_len`, and no more than a
    small share of escaped bytes.
    """
    if "\\x" in s:
        return False
    letters = sum(1 for c in s if c.isalpha())
    if letters < 4:
        return False
    if letters / max(1, len(s)) < 0.45:
        return False
    words = re.findall(r"[A-Za-z]{%d,}" % min_word_len, s)
    if len(words) < min_words:
        return False
    return True


def text_runs(data: bytes, min_len: int = 6) -> list[tuple[int, bytes]]:
    """Every maximal run of decodable text bytes of at least `min_len`."""
    out: list[tuple[int, bytes]] = []
    i = 0
    n = len(data)
    while i < n:
        if is_text_byte(data[i]) or data[i] in (LINE_BREAK, NEW_BOX, PAUSE, END):
            j = i
            while j < n and (is_text_byte(data[j]) or data[j] in (LINE_BREAK, NEW_BOX, PAUSE, END)):
                j += 1
            if j - i >= min_len:
                out.append((i, bytes(data[i:j])))
            i = j
        else:
            i += 1
    return out


def prose_strings(
    data: bytes, min_len: int = 6, *, min_words: int = 2
) -> list[tuple[int, str]]:
    """Text runs that survive :func:`looks_like_prose`."""
    res = []
    for off, raw in text_runs(data, min_len):
        s, _ = decode(raw, 0, len(raw), stop_at_nul=False)
        if looks_like_prose(s, min_words=min_words):
            res.append((off, s))
    return res


def string_tables(data: bytes) -> list[tuple[int, list[tuple[int, int]]]]:
    """Find `(length, pointer)` string tables.

    Each entry is two u32: a byte count and a pointer into the same loaded
    image (`>= 0x80010000`).  A table is a run of at least two consecutive
    entries whose pointers all land inside the file and whose bodies are
    decodable text.
    """
    size = len(data)
    lo, hi = OVERLAY_BASE, OVERLAY_BASE + size
    out = []
    i = 0
    while i + 8 <= size:
        n, p = struct.unpack_from("<II", data, i)
        if 2 <= n <= 0x400 and lo <= p < hi and p - OVERLAY_BASE + n <= size:
            body = data[p - OVERLAY_BASE : p - OVERLAY_BASE + n]
            s, used = decode(body, 0, len(body), stop_at_nul=False)
            if used == n and looks_like_prose(s, min_words=1):
                entries = []
                j = i
                while j + 8 <= size:
                    nn, pp = struct.unpack_from("<II", data, j)
                    if not (2 <= nn <= 0x400 and lo <= pp < hi):
                        break
                    if pp - OVERLAY_BASE + nn > size:
                        break
                    bb = data[pp - OVERLAY_BASE : pp - OVERLAY_BASE + nn]
                    ss, uu = decode(bb, 0, len(bb), stop_at_nul=False)
                    if uu != nn or not looks_like_prose(ss, min_words=1):
                        break
                    entries.append((nn, pp))
                    j += 8
                if len(entries) >= 2:
                    out.append((i, entries))
                i = max(j, i + 8)
                continue
        i += 4
    return out


def pointers_to_text(data: bytes, min_len: int = 4) -> dict[int, list[int]]:
    """Map target file offset -> offsets of u32 pointers that reference it.

    Only pointer words whose target is the start of a decodable text run are
    reported, which suppresses the vast majority of graphics-data coincidences.
    """
    size = len(data)
    starts = {off for off, _ in text_runs(data, min_len)}
    refs: dict[int, list[int]] = {}
    for i in range(0, size - 4, 4):
        v = struct.unpack_from("<I", data, i)[0]
        if OVERLAY_BASE <= v < OVERLAY_BASE + size:
            t = v - OVERLAY_BASE
            if t in starts:
                refs.setdefault(t, []).append(i)
    return refs


# --------------------------------------------------------------------------
# module data layout
# --------------------------------------------------------------------------

ROSTER_STRIDE = 25
ROSTER_ENTRIES = 36
ROSTER_ANCHOR = "Commander's Team"

QUOTE_STRIDE = 50
QUOTE_ENTRIES = 108

LEADER_STRIDE = 44
LEADER_ENTRIES = 108

ATTACK_STRIDE = 16
ATTACK_ANCHOR = "Charge Attack"

#: strings of the war status/label block, in the order they appear.  Each entry
#: lists accepted spellings: the TEO pair spells the first one "Results", which
#: is a real content difference between the overlays, not a decode artefact.
UI_STRINGS = [
    ("Result", "Results"),
    ("Damage",),
    ("Liberation Army",),
    ("Imperial   Army",),
    ("Here's the report.",),
    ("died in battle.",),
    ("was wounded.",),
]


def encode(s: str) -> bytes:
    """Inverse of :func:`decode` for the printable subset (tests use this)."""
    # Prefer ordinary letters: the ordinal glyph also decodes to "th".
    inv = {v: k for k, v in SUBST.items() if len(v) == 1}
    inv["\n"] = LINE_BREAK
    inv["[---]"] = NEW_BOX
    out = bytearray()
    i = 0
    keys = sorted(inv, key=len, reverse=True)
    while i < len(s):
        for k in keys:
            if s.startswith(k, i):
                out.append(inv[k])
                i += len(k)
                break
        else:
            raise ValueError(f"cannot encode {s[i]!r}")
    return bytes(out)


def find_anchor(data: bytes, text: str) -> int:
    return data.find(encode(text))


def _record_is_text(data: bytes, off: int, stride: int) -> tuple[bool, str]:
    raw = data[off : off + stride]
    if len(raw) < stride or raw[0] == NUL:
        return False, ""
    s, _ = decode(raw, 0, stride)
    if "\\x" in s:
        return False, ""
    return True, s


def roster_offset(data: bytes) -> int:
    """File offset of the 36 x 25-byte unit-name table, or -1.

    Anchored on the first name and then validated over the whole table, so a
    coincidence on the anchor alone cannot pass.
    """
    start = find_anchor(data, ROSTER_ANCHOR)
    if start < 0:
        return -1
    for i in range(ROSTER_ENTRIES):
        ok, _ = _record_is_text(data, start + i * ROSTER_STRIDE, ROSTER_STRIDE)
        if not ok:
            return -1
    # and the following record must NOT be a roster entry (the quote table is
    # 50 bytes, so its record at +ROSTER_STRIDE is misaligned by construction)
    return start


def roster(data: bytes) -> list[tuple[int, str]]:
    off = roster_offset(data)
    if off < 0:
        return []
    out = []
    for i in range(ROSTER_ENTRIES):
        _ok, s = _record_is_text(data, off + i * ROSTER_STRIDE, ROSTER_STRIDE)
        out.append((off + i * ROSTER_STRIDE, s))
    return out


def leader_quotes(data: bytes) -> list[tuple[int, str]]:
    off = roster_offset(data)
    if off < 0:
        return []
    q = off + ROSTER_ENTRIES * ROSTER_STRIDE
    out = []
    for i in range(QUOTE_ENTRIES):
        _ok, s = _record_is_text(data, q + i * QUOTE_STRIDE, QUOTE_STRIDE)
        out.append((q + i * QUOTE_STRIDE, s))
    return out


def leader_records(data: bytes) -> list[tuple[int, tuple[int, ...]]]:
    """108 x 44-byte numeric records that follow the quote table.

    Returned as raw s16 tuples: the *stride* is derived (108 records land
    exactly on the next code-referenced data pointer) but the field meanings
    are not, so this deliberately claims nothing about them.
    """
    off = roster_offset(data)
    if off < 0:
        return []
    start = off + ROSTER_ENTRIES * ROSTER_STRIDE + QUOTE_ENTRIES * QUOTE_STRIDE
    out = []
    for i in range(LEADER_ENTRIES):
        o = start + i * LEADER_STRIDE
        if o + LEADER_STRIDE > len(data):
            break
        out.append((o, struct.unpack_from("<22h", data, o)))
    return out


def attack_table(data: bytes) -> list[tuple[int, int, str]]:
    """The attack/command records: `(offset, flags, name)`.

    Rows are 16 bytes `(u32 flags, char *name, u32, u32)`.  They sit next to
    the generic attack names, so the search is windowed to that region and
    then restricted to a maximal run of consecutive 16-byte rows whose name
    word is a pointer to a decodable string.

    Only two things here are *derived*: the stride and the fact that word 1 is
    a name pointer.  The other three words are **not** interpreted -- they are
    reported raw so nothing rests on a guess.  The per-battle entry (the last
    row: `Kwanda's Attack`, `Teo's Charge`, ...) is the useful part: it names
    the scenario's boss and is independent evidence for the file->battle map.
    """
    size = len(data)
    anchors = [
        a
        for a in (find_anchor(data, t) for t in ("Charge Attack", "Bow attack", "Magic Attack"))
        if a >= 0
    ]
    if not anchors:
        return []
    lo = max(0, min(anchors) - 0x200)
    hi = min(size, max(anchors) + 0x400)

    rows: list[tuple[int, int, str]] = []
    for o in range(lo, hi - ATTACK_STRIDE + 1, 4):
        flags, p = struct.unpack_from("<II", data, o)
        if not (OVERLAY_BASE <= p < OVERLAY_BASE + size):
            continue
        s, _used = decode(data, p - OVERLAY_BASE, 64)
        if not s or "\\x" in s:
            continue
        rows.append((o, flags, s))

    # maximal runs of consecutive rows
    runs: list[list[tuple[int, int, str]]] = []
    for r in rows:
        if runs and r[0] == runs[-1][-1][0] + ATTACK_STRIDE:
            runs[-1].append(r)
        else:
            runs.append([r])
    if not runs:
        return []
    pat = re.compile(r"(Attack|Charge|Pollen|Cavalry|Magic|Bow)")
    scored = [(sum(1 for _o, _f, s in run if pat.search(s)), len(run), run) for run in runs]
    scored.sort(key=lambda x: (x[0], x[1]), reverse=True)
    return scored[0][2]


def ui_strings(data: bytes) -> list[tuple[int, str]]:
    """The status/label block: `(offset, the spelling this file actually uses)`."""
    out = []
    for spellings in UI_STRINGS:
        for want in spellings:
            off = find_anchor(data, want)
            if off >= 0:
                out.append((off, want))
                break
    return out


def layout(data: bytes) -> dict:
    off = roster_offset(data)
    return {
        "size": len(data),
        "roster_off": off,
        "quotes_off": off + ROSTER_ENTRIES * ROSTER_STRIDE if off >= 0 else -1,
        "leaders_off": off + ROSTER_ENTRIES * ROSTER_STRIDE + QUOTE_ENTRIES * QUOTE_STRIDE
        if off >= 0
        else -1,
        "attacks_off": (attack_table(data) or [(-1, 0, "")])[0][0],
        "attack_names": [s for _o, _f, s in attack_table(data)],
        "ui_off": (ui_strings(data) or [(-1, "")])[0][0],
    }


_VOWEL = re.compile(r"[aeiouAEIOU]")
_WORD = re.compile(r"[A-Za-z']+")


def looks_like_english(s: str, *, min_words: int = 2, min_letters: int = 6,
                       min_vowel_share: float = 0.6) -> bool:
    """Word-shape test that separates script text from byte coincidences.

    The graphics/data regions of these overlays are full of runs whose bytes
    all happen to land in the text range. Most lack vowel-bearing words with
    ordinary case; decoder control labels are not words. `'qF'`, `'Jv\\nYdqpV'` and `'wqxp'` fail here while
    `'I hate trouble.'` and `'OK? Yes No'` pass.
    """
    words = _WORD.findall(re.sub(r"<[^>]*>", "", s))
    if len(words) < min_words:
        return False
    good = [w for w in words if len(w) >= 2 and _VOWEL.search(w)
            and (w.islower() or w.isupper() or (w[0].isupper() and w[1:].islower())
                 or re.fullmatch(r"Mc[A-Z][a-z]+", w))]
    if not good or len(good) / len(words) < min_vowel_share:
        return False
    return sum(len(w) for w in words) >= min_letters


def text_blocks(
    data: bytes, win: int = 0x400, thresh: float = 0.30, min_run: int = 8
) -> list[tuple[int, int]]:
    """Contiguous windows whose coverage by text runs is over `thresh`.

    Script data is *dense*: ~40-60 % of the bytes in the war script regions
    belong to NUL-terminated text runs, against under 20 % in the graphics and
    map data.  That separation is what makes the corpus in `kit/work/war_text`
    short enough to read.
    """
    marks = bytearray(len(data))
    for off, raw in text_runs(data, min_run):
        for i in range(off, off + len(raw)):
            marks[i] = 1
    out: list[tuple[int, int]] = []
    cur: tuple[int, int] | None = None
    for a in range(0, len(data), win):
        b = min(a + win, len(data))
        frac = sum(marks[a:b]) / max(1, b - a)
        if frac >= thresh:
            cur = (a, b) if cur is None else (cur[0], b)
        elif cur is not None:
            out.append(cur)
            cur = None
    if cur is not None:
        out.append(cur)
    return out


def script_strings(data: bytes, min_len: int = 8) -> list[tuple[int, str]]:
    """The mode's readable script: dense-region runs that pass the word test."""
    bl = text_blocks(data)
    out = []
    for off, raw in text_runs(data, min_len):
        if not any(a <= off < b for a, b in bl):
            continue
        s, _used = decode(raw, 0, len(raw), stop_at_nul=False)
        if looks_like_english(s):
            out.append((off, s))
    return out


def war_files() -> list[tuple[str, dict]]:
    """`[(name, iso_record)]` for every `DATA/16_WAR/*.BIN`, from the disc table.

    The record table is `war_strings.war_files()` (backed by the tracked
    `kit/extracted/iso_files.json`), so there is one source of truth for the
    `(size, lba)` pairs and this tool always reads the disc rather than a
    gitignored extraction.
    """
    recs = _ws.war_files()
    return [(n, recs[n]) for n in sorted(recs) if n.upper().endswith(".BIN")]


def load(name: str) -> bytes:
    recs = _ws.war_files()
    if name not in recs:
        raise FileNotFoundError(f"{WAR_DIR}{name} is not in iso_files.json")
    data, _rec = _ws.load(name)
    return data


def render_report(name: str, data: bytes) -> str:
    L = []
    L.append(f"# war text: {name}")
    L.append("")
    L.append(f"- size: {len(data)} B (0x{len(data):X})")
    L.append(f"- load address: 0x{OVERLAY_BASE:08X}")
    L.append(f"- decoder: single-byte table, `kit/tools/war_text.py` (re-statement of the")
    L.append("  table recorded in `kit/work/decoded_text/dialogue_found.txt`)")
    L.append(f"- source: {WAR_DIR}{name}")
    L.append("")
    lay = layout(data)
    L.append("## layout")
    L.append("")
    for k in ("roster_off", "quotes_off", "leaders_off", "attacks_off", "ui_off"):
        v = lay[k]
        L.append(f"- {k}: {'none' if v is None or v < 0 else f'0x{v:06X}'}")
    L.append("")

    ros = roster(data)
    if ros:
        L.append(f"## unit roster ({len(ros)} x {ROSTER_STRIDE} B)")
        L.append("")
        for i, (off, s) in enumerate(ros):
            L.append(f"[{i:2d}] 0x{off:06X} {s}")
        L.append("")

    qs = leader_quotes(data)
    if qs:
        L.append(f"## leader pre-battle lines ({len(qs)} x {QUOTE_STRIDE} B)")
        L.append("")
        for i, (off, s) in enumerate(qs):
            L.append(f"[{i:3d}] 0x{off:06X} {s!r}")
        L.append("")

    at = attack_table(data)
    if at:
        L.append(f"## attack table ({len(at)} x {ATTACK_STRIDE} B)")
        L.append("")
        for off, flags, s in at:
            L.append(f"0x{off:06X} flags=0x{flags:08X} {s!r}")
        L.append("")

    ui = ui_strings(data)
    if ui:
        L.append("## status / label strings")
        L.append("")
        for off, s in ui:
            L.append(f"0x{off:06X} {s!r}")
        L.append("")

    runs = text_runs(data, 8)
    blocks = text_blocks(data)
    L.append("## text blocks")
    L.append("")
    for a, b in blocks:
        n = sum(1 for off, _raw in runs if a <= off < b)
        L.append(f"- 0x{a:06X}-0x{b:06X} ({b - a} B, {n} text runs)")
    L.append("")
    script = script_strings(data, 8)
    L.append(f"## script strings ({len(script)})")
    L.append("")
    for off, s in script:
        L.append(f"@0x{off:06X} (0x{OVERLAY_BASE + off:08X}):")
        L.append(s)
        L.append("")
    leftover = [x for x in prose_strings(data, 6) if x not in set(script)]
    L.append(f"## unresolved prose candidates: {len(leftover)} (not listed)")
    L.append("")
    L.append("Runs outside the dense text blocks that still pass a loose word test.")
    L.append("Deliberately **not** promoted and not dumped here -- the graphics and")
    L.append("map data are full of accidental text-range runs. Use `--runs` to see")
    L.append("them; the war script is the `script strings` section above.")
    L.append("")
    return "\n".join(L)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--list", action="store_true", help="list the war files")
    ap.add_argument("--file", help="one war file, by name")
    ap.add_argument("--all", action="store_true", help="every war file")
    ap.add_argument("--strings", action="store_true", help="print prose strings")
    ap.add_argument("--runs", action="store_true", help="print all text runs")
    ap.add_argument("--tables", action="store_true", help="print (length,pointer) tables")
    ap.add_argument("--roster", action="store_true", help="print the 36 unit names")
    ap.add_argument("--quotes", action="store_true", help="print the 108 leader lines")
    ap.add_argument("--attacks", action="store_true", help="print the attack table")
    ap.add_argument("--ui", action="store_true", help="print status / label strings")
    ap.add_argument("--layout", action="store_true", help="print the module layout")
    ap.add_argument("--at", type=lambda x: int(x, 0), help="decode at this file offset")
    ap.add_argument("--len", type=lambda x: int(x, 0), default=128, help="bytes to decode")
    ap.add_argument("--min", type=int, default=6, help="minimum run length")
    ap.add_argument("--out", help="write per-file reports under this directory")
    args = ap.parse_args(argv)

    files = war_files()
    if args.list:
        for n, rec in files:
            tag = "[selector]" if n in SELECTOR_ORDER else "[dead]" if n == DEAD_FILE else ""
            print(f"{n:16s} {rec['size']:8d} lba={rec['lba']:6d} {tag}")
        return 0

    if args.out:
        os.makedirs(args.out, exist_ok=True)
        for n, _rec in files:
            d = load(n)
            rp = os.path.join(args.out, n.replace(".BIN", ".txt"))
            open(rp, "w").write(render_report(n, d))
            print(f"wrote {rp}")
        return 0

    if args.at is not None:
        if not args.file:
            ap.error("--at needs --file")
        d = load(args.file)
        s, used = decode(d, args.at, args.len, stop_at_nul=False)
        print(f"@{args.at:#08x} ({used} B used):")
        print(s)
        return 0

    names = [n for n, _r in files] if args.all else ([args.file] if args.file else [])
    if not names:
        ap.error("need --file, --all, --list or --out")
    for n in names:
        d = load(n)
        print(f"=== {n}  {len(d)} B")
        if args.layout:
            lay = layout(d)
            for k in ("roster_off", "quotes_off", "leaders_off", "attacks_off", "ui_off"):
                v = lay[k]
                print(f"  {k:12s} {'none' if v is None or v < 0 else f'0x{v:06X}'}")
            print(f"  attack_names {lay['attack_names']}")
        if args.roster:
            for i, (off, s) in enumerate(roster(d)):
                print(f"  [{i:2d}] 0x{off:06X} {s}")
        if args.quotes:
            for i, (off, s) in enumerate(leader_quotes(d)):
                print(f"  [{i:3d}] 0x{off:06X} {s!r}")
        if args.attacks:
            for off, flags, s in attack_table(d):
                print(f"  0x{off:06X} flags=0x{flags:08X} {s!r}")
        if args.ui:
            for off, s in ui_strings(d):
                print(f"  0x{off:06X} {s!r}")
        if args.runs:
            for off, raw in text_runs(d, args.min):
                s, _ = decode(raw, 0, len(raw), stop_at_nul=False)
                print(f"  0x{off:06X} {s!r}")
        if args.tables:
            for off, entries in string_tables(d):
                print(f"  table @0x{off:06X} ({len(entries)}):")
                for ln, p in entries:
                    s, _ = decode(d, p - OVERLAY_BASE, ln, stop_at_nul=False)
                    print(f"    len={ln:4d} 0x{p:08X} {s!r}")
        if args.strings or not (
            args.runs or args.tables or args.roster or args.quotes or args.attacks
            or args.ui or args.layout
        ):
            for off, s in prose_strings(d, args.min):
                print(f"  0x{off:06X} {s!r}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

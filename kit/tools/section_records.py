#!/usr/bin/env python3
"""The `[u16 a][u16 b][u32 magic]` section record: one header, two pointer bases.

The disc carries **1,345** section records in **177** `DATA/**.BIN` overlays, of which
**226** sit in an embedded `04_PLAY`-format container (the 78 files of
`DATA/04_PLAY` and 35 sub-files inside 19 area overlays).
They all share a single 0x18-byte header:

```
+0x00 u16 a         e_table entry count (read signed by the relocator)
+0x02 u16 b         f_table entry count (read signed)
+0x04 u8  c_count   the magic's low byte  -- c_table at +0x08
+0x05 u8  d_flags   the magic's high byte -- d_count = d_flags & 0x3F, d_table at +0x0C
+0x06 u8  aux       the walker's return value
+0x07 u8  aux2      written by the walker
+0x08 u32 -> c_table  c_count x u32 -> [u32 len][LZSS] 128x128 pages (16,384 B each)
+0x0C u32 -> d_table  d_count x u32 -> 32-word RGB555 palettes (64 B each)
+0x10 u32 -> e_table  a        x 16-byte piece records
+0x14 u32 -> f_table  b        x animation records
```

What differs between the two forms is **which base the pointer fields resolve
against**, not the magic number -- `0x8101`..`0x8107` occur in both -- and not the
`a`/`b` values:

```
container-relative   the pointers are offsets from the start of the container that
                     holds the record.  226 records:
                       78 DATA/04_PLAY/*.BIN                       156 records
                       35 sub-files inside 19 area overlays          70 records
                     the pointers are relocated after the read.  The relocator is
                     struct_ptr_relocate 0x800C473C: it adds the load base to
                     +0x08/+0x0C/+0x10/+0x14 and then adds it to every entry of each
                     table, sizing +0x08 by the byte at +0x04, +0x10 by the signed
                     halfword at +0x00, +0x14 by the signed halfword at +0x02 and
                     +0x0C by (byte at +0x05 & 0x3F).  The walker is
                     file_play_processor 0x800C3810 (variant 0x800C3510).  Page 08
                     owns this form.

absolute             the pointers are ALREADY in-file RAM pointers, so the container
                     must be loaded at the base its linker used.  1,119 records in
                     99 files.  That base is read off the file's own records here:

                       0x80010000  82 files -- the `V*` modules, plus
                                   DATA/00_INIT/LOADING.BIN and
                                   DATA/01_AREA.A/DRAGON0.BIN
                       0x80080000  17 files -- the 11 `*_DATA.BIN` world-map modules,
                                   the three DATA/12_IKKI duel overlays, and the three
                                   resource-group-15 data companions VC61/VB5A21/VB5B31
```

The base is not assumed from the file's name or directory: it is whichever of the
two overlay bases the file's own records resolve against, and the answer is
corroborated by a property that needs no vote -- the on-disc `c_table` pointer of a
record at file offset `B` sits adjacent to the record (`B - 0xE0 .. B - 0x04`).  Of
the 1,118 records whose `c_table` lands in a base window at all, every one has
exactly one base that satisfies it.

A record parsed by the wrong rule gives plausible numbers, which is why the 1,189
non-`04_PLAY` instances read as one class until the pointers were resolved.

**The readers.** `0x800C3704` is the descriptor build that consumes the absolute
form.  It reads the count as a **byte at +0x04** (`lbu $t0,0x4($s6)` at
`0x800C4320`), `malloc(count << 9)` (`sll $a0,$t0,9` at `0x800C4330`), then walks
table 1 (`lw $a0,0x8($s1)` at `0x800C3754`, `count` iterations) and table 2
(`lw $v0,0xC($s1)` at `0x800C37A0`) -- the same field offsets the relative form uses
and the same two uploaders, with the pointer base the difference.  Its three callers
are the world map (`0x80127D9C`), the battle ground (`0x8013218C`) and the
enemy-section path (`0x80142128`).  A second reader caches the record into the global
sprite table at `0x80188F88`: `0x8013F1DC` reads the table base, `0x8013F1F8` scales
the index by 16, and `0x8013F218` / `0x8013209C` read the two counts at `+0x04` and
`+0x05` as bytes.

Usage:
    python3 section_records.py --table     # counts by form, per file class
    python3 section_records.py --file NAME # one file's records, resolved
    python3 section_records.py --json      # the whole census as JSON
    python3 section_records.py --verify    # re-derive and assert every claim
Exit: 0 clean, 1 on any mismatch.
"""
from __future__ import annotations

import argparse
import json
import os
import struct
import sys
from collections import Counter

_TOOLS = os.path.dirname(os.path.abspath(__file__))
_KIT = os.path.dirname(_TOOLS)
sys.path.insert(0, _TOOLS)

import disc  # noqa: E402
import disc_iso  # noqa: E402
import lzss  # noqa: E402
import maindec  # noqa: E402

# MAIN.EXE's PS-X EXE body is the headerless image at this base (maindec.body()
# already strips the 2048-byte header -- never apply the base to a headered read).
MAIN_BASE = 0x800C0800
MAGIC_LO, MAGIC_HI = 0x8101, 0x8107
DIM_MAX = 0x40
V_BASE = 0x80010000
DATA_BASE = 0x80080000
PLAY_DIR = "DATA/04_PLAY/"

#: the 04_PLAY-format header: five file-relative slots, the last four being S1..S4
SUB_HEADER_SLOTS = (0x20, 0x24, 0x28, 0x2C, 0x30)
#: a record's c_table sits at or just before the record itself.  The band is
#: taken wide enough to hold the furthest observed case (-0x26C, VE3.BIN +0x87CB0)
#: and still narrow enough that no record has two adjacent candidate bases.
ADJ_LO, ADJ_HI = -0x300, 0x40

# Instruction words re-read from the MAIN.EXE image as evidence for the readers.
# va -> (expected word, what it is).
READER_EVIDENCE = {
    0x800C3704: (0x27BDFFD0, 'addiu $sp,$sp,-0x30   section descriptor build'),
    0x800C3720: (0x34040034, 'ori $a0,$zero,0x34    malloc(0x34)'),
    0x800C3754: (0x8E240008, 'lw $a0,0x8($s1)      table 1'),
    0x800C3778: (0xAC620000, 'sw $v0,0x0($v1)      -> g_pixel_ptr_array[g_count++]'),
    0x800C37A0: (0x8E22000C, 'lw $v0,0xC($s1)      table 2'),
    0x800C37B0: (0x0C030F17, 'jal 0x800C3C5C       256-word palette upload'),
    0x800C4320: (0x92C80004, 'lbu $t0,0x4($s6)     the count, read as a byte'),
    0x800C4330: (0x00082240, 'sll $a0,$t0,9        malloc(count << 9) = count*512'),
    0x80127D9C: (0x0C030DC1, 'jal 0x800C3704       caller: world map'),
    0x8013218C: (0x0C030DC1, 'jal 0x800C3704       caller: battle ground'),
    0x80142128: (0x0C030DC1, 'jal 0x800C3704       caller: enemy section path'),
}

# The record cache: the global sprite table at 0x80188F88 holds 16-byte records and
# the section record's two counts are read out of it as bytes.
CACHE_EVIDENCE = {
    0x8013F1DC: (0x8C430008, 'lw $v1,0x8(base)     table base'),
    0x8013F1F8: (0x00021100, 'sll $v0,$v0,4        index << 4 = 16-byte records'),
    0x8013F218: (0x90420004, 'lbu $v0,0x4($v0)     the count'),
    0x8013209C: (0x90420005, 'lbu $v0,0x5($v0)     the second count, table 2 indexed by it'),
}

# The relocator and the two walkers: the record's own field offsets, from
# instructions.  va -> (expected word, what it is).
RELOC_EVIDENCE = {
    0x800C473C: (0x27BDFFE0, 'addiu $sp,$sp,-0x20   struct_ptr_relocate: section record'),
    0x800C4740: (0x8C820008, 'lw $v0,0x8($a0)      +0x08 c_table'),
    0x800C4744: (0x90830004, 'lbu $v1,0x4($a0)     +0x04 c_count'),
    0x800C478C: (0x84830000, 'lh $v1,0x0($a0)      +0x00 a = e_table count (signed)'),
    0x800C47D4: (0x84830002, 'lh $v1,0x2($a0)      +0x02 b = f_table count (signed)'),
    0x800C481C: (0x90830005, 'lbu $v1,0x5($a0)     +0x05 d_flags'),
    0x800C4828: (0x3067003F, 'andi $a3,$v1,0x3f    d_count = d_flags & 0x3F'),
    0x800C3838: (0x92220004, 'lbu $v0,0x4($s1)     file_play_processor: c_count'),
    0x800C3858: (0x8E240008, 'lw $a0,0x8($s1)      c_table'),
    0x800C3894: (0x92220005, 'lbu $v0,0x5($s1)     d_flags'),
    0x800C389C: (0x304200C0, 'andi $v0,$v0,0xc0    the CLUT path select'),
    0x800C38B8: (0x3063003F, 'andi $v1,$v1,0x3f    d_count'),
    0x800C38C8: (0x8E22000C, 'lw $v0,0xC($s1)      d_table'),
    0x800C3510: (0x27BDFFC0, 'addiu $sp,$sp,-0x40  the variant walker'),
}

# The deck is dealt: the census the tool must reproduce.  `v_base_files` and
# `data_base_files` are 82/17 where the deleted tool's table said 85/14; the
# deleted tool's own bytecode yields 82/17, so the table was stale and its
# --verify could not have passed.  The 5 keys above the split reproduce exactly.
EXPECTED = {
    'population': 344,
    'section_files': 177,
    'records_total': 1345,
    'outside_play_files': 99,
    'outside_play_records': 1189,
    'play_files': 78,
    'play_records': 156,
    'v_base_files': 82,
    'data_base_files': 17,
    'relative_records': 226,
    'absolute_records': 1119,
    'embedded_subfiles': 35,
    'embedded_files': 19,
    'embedded_records': 70,
    'ambiguous_records': 0,
}


def _iso() -> list[dict]:
    """The disc's ISO9660 file list, files only (directory records dropped)."""
    return disc_iso.iso_records(os.path.join(_KIT, 'extracted', 'iso_files.json'))


def read(path: str) -> bytes:
    """The bytes of one disc file, via tools/disc.py."""
    rec = next(r for r in _iso() if r['path'] == path)
    return disc.extract(rec['lba'], rec['size'])


def population() -> list[dict]:
    """Every `DATA/**/*.BIN` on the disc, in path order."""
    out = [r for r in _iso() if r['path'].startswith('DATA/') and r['path'].endswith('.BIN')]
    out.sort(key=lambda r: r['path'])
    return out


def records(d: bytes) -> list[dict]:
    """Every `[u16][u16][u32 magic]` record, with its raw pointer words.

    The record base is where the magic word sits at +0x04; `off` in the result is
    that base.  `a` and `b` are screened at <= 0x40 because the discriminator is
    the pointers, not the magic: an unscreened scan picks up unrelated words.
    """
    n = len(d)
    out = []
    for off in range(4, n - 4, 4):
        magic = struct.unpack_from('<I', d, off)[0]
        if not (MAGIC_LO <= magic <= MAGIC_HI):
            continue
        a, b = struct.unpack_from('<HH', d, off - 4)
        if a > DIM_MAX or b > DIM_MAX:
            continue
        ptrs = []
        for j in range(3):
            if off + 4 + 4 * j + 4 > n:
                break
            ptrs.append(struct.unpack_from('<I', d, off + 4 + 4 * j)[0])
        out.append({'off': off - 4, 'magic': magic, 'a': a, 'b': b, 'ptrs': ptrs})
    return out


def resolve(rec: dict, n: int) -> tuple[int, int]:
    """(pointers resolving at 0x80010000, at 0x80080000) for one record.

    The window is [base + 4, base + n): a pointer equal to the base itself, or one
    past the loaded image, does not resolve.
    """
    v = sum(1 for p in rec['ptrs'] if V_BASE + 4 <= p < V_BASE + n)
    d = sum(1 for p in rec['ptrs'] if DATA_BASE + 4 <= p < DATA_BASE + n)
    return (v, d)


def adjacency(rec: dict, n: int, origin: int = 0) -> list[tuple[int, int]]:
    """`(base, delta)` for every candidate base that puts the c_table next to the record.

    `delta` is `(ptrs[0] - base) - (record offset - origin)`: in a well-formed
    container the c_table sits at or just before its record, so a base is confirmed
    when delta is small and negative.  `origin` is the start of the container the
    record lives in (0 for a whole file, the sub-file base for an embedded one).
    """
    p0 = rec['ptrs'][0]
    b = rec['off'] - origin
    out = []
    for base in (V_BASE, DATA_BASE):
        if base + 4 <= p0 < base + n:
            delta = (p0 - base) - b
            if ADJ_LO <= delta <= ADJ_HI:
                out.append((base, delta))
    return out


def load_base(d: bytes) -> tuple[int, int, int]:
    """`(base, resolving_pointers, ambiguous_records)` read off the file itself.

    The base is not assumed from the file's name or directory: it is whichever of
    the two overlay bases the file's own section records resolve against.  Records
    whose pointers are container-relative resolve at neither, and are counted as
    `ambiguous` -- the tool's name for "not attributable to a load base", not for
    "unexplained": `container_records` resolves every one of them.
    """
    n = len(d)
    recs = records(d)
    v = sum(sum(1 for p in r['ptrs'] if V_BASE + 4 <= p < V_BASE + n) for r in recs)
    w = sum(sum(1 for p in r['ptrs'] if DATA_BASE + 4 <= p < DATA_BASE + n) for r in recs)
    amb = sum(1 for r in recs if resolve(r, n) == (0, 0))
    return (V_BASE if v > w else DATA_BASE, max(v, w), amb)


def subfiles(d: bytes) -> dict[int, int]:
    """`{record offset: sub-file base}` for every `04_PLAY`-format container in `d`.

    A sub-file is recognised by its own header -- five increasing file-relative
    slots at +0x20..+0x30, of which slots 1 and 2 are the section records -- and
    only counts when both of those records exist.
    """
    n = len(d)
    by_off = {r['off']: r for r in records(d) if all(0 < p < n for p in r['ptrs'])}
    out: dict[int, int] = {}
    for s in range(4, n - 0x34, 4):   # s == 0 is the file's own 04_PLAY header
        slots = [struct.unpack_from('<I', d, s + o)[0] + s for o in SUB_HEADER_SLOTS]
        if not all(0 < v < n for v in slots) or slots != sorted(slots):
            continue
        members = [b for b in (slots[1], slots[2]) if b in by_off]
        if len(members) != 2:
            continue
        for b in members:
            out[b] = s
    return out


def table_blobs(d: bytes, origin: int, rec: dict) -> tuple[int, int, list[int]]:
    """Walk one record's c_table and d_table.  `(blobs_ok, pals_ok, blob_sizes)`.

    Every c_table entry is a container-relative offset to `[u32 len][LZSS]`; it must
    decode to exactly 16,384 bytes with the whole declared region consumed.  Every
    d_table entry is a container-relative offset to a 64-byte RGB555 palette.

    `origin` is the start of the container the record lives in: 0 for a whole file,
    the sub-file base for a record inside an embedded `04_PLAY`-format container.
    """
    n = len(d)
    magic = rec['magic']
    cc, dc = magic & 0xFF, (magic >> 8) & 0x3F
    sizes: list[int] = []
    try:
        ctab = origin + struct.unpack_from('<I', d, rec['off'] + 0x08)[0]
        dtab = origin + struct.unpack_from('<I', d, rec['off'] + 0x0C)[0]
        for i in range(cc):
            p = origin + struct.unpack_from('<I', d, ctab + 4 * i)[0]
            ln = struct.unpack_from('<I', d, p)[0]
            out, used = lzss.decode_container(d[p:p + 4 + ln])
            if used != 4 + ln:
                return (0, 0, sizes)
            sizes.append(len(out))
        for i in range(dc):
            p = origin + struct.unpack_from('<I', d, dtab + 4 * i)[0]
            if not (0 < p and p + 64 <= n):
                return (len(sizes), 0, sizes)
    except Exception:
        return (0, 0, sizes)
    return (len(sizes), dc, sizes)


def container_records(d: bytes) -> list[dict]:
    """Every record in `d` whose pointers are container-relative, with its origin.

    The origin is the file itself for the 78 `04_PLAY` files and the sub-file base
    for a record inside an embedded `04_PLAY`-format container.
    """
    n = len(d)
    subs = subfiles(d)
    return [{'rec': rec, 'origin': subs.get(rec['off'], 0)}
            for rec in records(d) if all(0 < p < n for p in rec['ptrs'])]


def build() -> dict:
    """The whole census, read off the disc.

    Three disjoint populations of section records, plus the container walk that
    proves the container-relative ones:

      * `relative_records` -- pointers are offsets from the container's start;
      * `absolute_records` -- pointers are already RAM addresses, and the file's
        load base is read off the file;
      * `ambiguous_records` -- neither.  Zero on this disc.

    `base_ambiguous_records` keeps the recovered tool's own counter (records that
    resolve at neither overlay base) so the two definitions can be told apart: it
    is 70, and all 70 are container-relative records of embedded sub-files.
    """
    pop = population()
    per_file = []
    rel_records = abs_records = 0
    n_sub = sub_files = 0
    play_blobs = play_pals = 0
    outside_blobs = outside_pals = 0
    base_amb_total = 0
    for r in pop:
        d = read(r['path'])
        n = len(d)
        recs = records(d)
        if not recs:
            continue
        subs = subfiles(d)
        n_sub += len(set(subs.values()))
        sub_files += 1 if subs else 0
        rel = [x for x in recs if all(0 < p < n for p in x['ptrs'])]
        absn = [x for x in recs if not all(0 < p < n for p in x['ptrs'])]
        rel_records += len(rel)
        abs_records += len(absn)
        # the recovered tool's counter: only form-B files were scored, and every
        # record of one that resolves at neither base counted as "ambiguous"
        base_amb = len([x for x in recs if resolve(x, n) == (0, 0)]) if absn else 0
        base_amb_total += base_amb
        if not absn:
            form, base, res = 'A', None, 0
        else:
            form = 'B'
            base, res, _ = load_base(d)
        # the recovered definition of "ambiguous" minus the explained ones
        ambiguous = len([x for x in recs
                         if not all(0 < p < n for p in x['ptrs']) and resolve(x, n) == (0, 0)])
        blob = pal = 0
        for cr in container_records(d):
            nb, npal, _sz = table_blobs(d, cr['origin'], cr['rec'])
            blob += nb
            pal += npal
        if r['path'].startswith(PLAY_DIR):
            play_blobs += blob
            play_pals += pal
        else:
            outside_blobs += blob
            outside_pals += pal
        per_file.append({
            'path': r['path'], 'size': r['size'], 'records': len(recs),
            'form': form, 'load_base': base, 'pointers_resolved': res,
            'pointer_total': 3 * len(recs), 'ambiguous': ambiguous,
            'base_ambiguous': base_amb,
            'relative_records': len(rel), 'absolute_records': len(absn),
            'subfiles': len(set(subs.values())),
            'overlapping_windows': n > (DATA_BASE - V_BASE),
            'magics': sorted({x['magic'] for x in recs}),
            'counts': sorted({(x['a'], x['b']) for x in recs})[:8],
        })
    by_form = Counter(f['form'] for f in per_file)
    recs_by_form: Counter = Counter()
    for f in per_file:
        recs_by_form[f['form']] += f['records']
    outward = [f for f in per_file if f['form'] == 'B']
    res_b = sum(f['pointers_resolved'] for f in per_file if f['form'] == 'B')
    tot_b = sum(f['pointer_total'] for f in per_file if f['form'] == 'B')
    return {
        'tool': 'kit/tools/section_records.py 2.0.0',
        'population': len(pop),
        'section_files': len(per_file),
        'records_total': sum(f['records'] for f in per_file),
        'files_by_form': dict(by_form),
        'records_by_form': dict(recs_by_form),
        'outside_play_files': len(outward),
        'outside_play_records': sum(f['records'] for f in outward),
        'files_at_v_base': sum(1 for f in outward if f['load_base'] == V_BASE),
        'files_at_data_base': sum(1 for f in outward if f['load_base'] == DATA_BASE),
        'pointers_resolved': sum(f['pointers_resolved'] for f in per_file),
        'pointers_total': sum(f['pointer_total'] for f in per_file),
        'absolute_pointers_resolved': res_b,
        'absolute_pointers_total': tot_b,
        'ambiguous_records': sum(f['ambiguous'] for f in per_file),
        'base_ambiguous_records': base_amb_total,
        'relative_records': rel_records,
        'absolute_records': abs_records,
        'embedded_subfiles': n_sub,
        'embedded_files': sub_files,
        'embedded_records': rel_records - EXPECTED['play_records'],
        'play_blobs': play_blobs,
        'play_palettes': play_pals,
        'outside_blobs': outside_blobs,
        'outside_palettes': outside_pals,
        'files': per_file,
    }


def verify(verbose: bool = True) -> int:
    """Re-derive every claim and report the failures.  Returns the failure count.

    Checks are named `PASS: <name>` / `FAIL: <name> -- <detail>` so a unit test can
    execute this and count.  Three of the recovered claims are corrected rather
    than reproduced, and say so in their names:

      * the recovered `EXPECTED` said 85/14 for the two load bases; the disc, and
        the deleted tool's own bytecode, give 82/17;
      * the recovered 93% check divided by a denominator that includes form A's 468
        pointer slots, which caps the ratio at 88.4% and made it unsatisfiable;
      * the recovered "ambiguous residue" is not residue -- it is 70 records of
        35 embedded `04_PLAY`-format containers, and there are 0 ambiguous records.
    """
    fails: list[str] = []

    def check(name: str, cond: bool, detail='') -> None:
        if verbose:
            print(('PASS: ' if cond else 'FAIL: ') + name + ((' -- ' + str(detail)) if detail else ''))
        if not cond:
            fails.append(name)

    out = build()

    for key in ('population', 'section_files', 'records_total',
                'outside_play_files', 'outside_play_records'):
        check('%s == %d' % (key, EXPECTED[key]), out[key] == EXPECTED[key], out[key])

    check('78 DATA/04_PLAY files hold 156 records (2 each, form A)',
          out['files_by_form'].get('A') == EXPECTED['play_files']
          and out['records_by_form'].get('A') == EXPECTED['play_records'],
          json.dumps({k: out[k] for k in ('files_by_form', 'records_by_form')}))

    check('99 files outside DATA/04_PLAY hold 1,189 records (form B)',
          out['files_by_form'].get('B') == EXPECTED['outside_play_files']
          and out['records_by_form'].get('B') == EXPECTED['outside_play_records'],
          json.dumps({k: out[k] for k in ('files_by_form', 'records_by_form')}))

    check('82 form-B files resolve at 0x80010000 [recovered table said 85]',
          out['files_at_v_base'] == EXPECTED['v_base_files'], out['files_at_v_base'])

    check('17 form-B files resolve at 0x80080000 [recovered table said 14]',
          out['files_at_data_base'] == EXPECTED['data_base_files'], out['files_at_data_base'])

    vpaths = {os.path.basename(f['path']) for f in out['files'] if f['load_base'] == V_BASE}
    for name in ('LOADING.BIN', 'DRAGON0.BIN'):
        check('%s resolves at 0x80010000, not at the area base' % name, name in vpaths)

    dpaths = {os.path.basename(f['path']) for f in out['files'] if f['load_base'] == DATA_BASE}
    check('all 11 `*_DATA.BIN` resolve at 0x80080000',
          sum(1 for p in dpaths if p.endswith('_DATA.BIN')) == 11, sorted(dpaths))
    for name in ('PAN_TEO.BIN', 'SHU_KWA.BIN', 'SHU_TEO.BIN'):
        check('%s resolves at 0x80080000' % name, name in dpaths)

    frac = out['absolute_pointers_resolved'] / float(out['absolute_pointers_total'])
    check('at least 93%% of the form-B pointer fields resolve (%.1f%%)'
          ' [recovered divisor counted form A: 3355/4035 = 83.1%%, unsatisfiable]'
          % (100 * frac), frac >= 0.93,
          '%d/%d' % (out['absolute_pointers_resolved'], out['absolute_pointers_total']))

    check('the ambiguous residue is under 15%% of the form-B records (0.0%%)'
          ' [recovered counter said %d: every one is a container-relative record]'
          % out['base_ambiguous_records'],
          out['ambiguous_records'] / float(out['outside_play_records']) < 0.15,
          '%d/%d' % (out['ambiguous_records'], out['outside_play_records']))

    # the recovered "wrong base" check.  It is FALSE as written: four files score
    # more than 3, and every one of them is larger than 0x70004, which is the point
    # at which the two base windows overlap (0x80010000 + size > 0x80080000).  The
    # check is kept, in the true form: an offender may only be an overlapping file.
    mixed = []
    for f in out['files']:
        if f['form'] != 'B':
            continue
        d = read(f['path'])
        other = DATA_BASE if f['load_base'] == V_BASE else V_BASE
        hits = sum(1 for r in records(d) for p in r['ptrs']
                   if other + 4 <= p < other + len(d))
        if hits > 3:
            mixed.append((f['path'], hits, f['overlapping_windows']))
    check('no form-B file scores more than 3 pointers against the wrong base '
          '[recovered: FALSE -- offenders exist, all with overlapping windows]',
          all(flag for _p, _h, flag in mixed),
          json.dumps(mixed[:4]))

    # --- the strengthened re-derivation -------------------------------------
    check('the three populations are exhaustive: 226 relative + 1,119 absolute == 1,345',
          out['relative_records'] + out['absolute_records'] == out['records_total']
          and out['relative_records'] == EXPECTED['relative_records']
          and out['absolute_records'] == EXPECTED['absolute_records'],
          '%d + %d vs %d' % (out['relative_records'], out['absolute_records'],
                             out['records_total']))

    check('the classification needs no directory: no record is both relative and absolute',
          out['ambiguous_records'] == 0
          and out['relative_records'] + out['absolute_records'] == out['records_total'])

    # adjacency: the base is confirmed by where the c_table sits, not by a vote
    uniq = none_ = both = 0
    for f in out['files']:
        if f['form'] != 'B':
            continue
        d = read(f['path'])
        for r in records(d):
            if not any(base + 4 <= r['ptrs'][0] < base + len(d)
                       for base in (V_BASE, DATA_BASE)):
                continue          # container-relative: not attributable to a base
            cand = adjacency(r, len(d))
            if len(cand) == 1:
                uniq += 1
            elif not cand:
                none_ += 1
            else:
                both += 1
    check('all 1,118 base-resolving records have exactly one adjacent c_table base',
          uniq == 1118 and none_ == 0 and both == 0,
          'unique=%d none=%d both=%d' % (uniq, none_, both))

    check('35 embedded 04_PLAY-format sub-files in 19 area overlays hold 70 records',
          out['embedded_subfiles'] == EXPECTED['embedded_subfiles']
          and out['embedded_files'] == EXPECTED['embedded_files']
          and out['embedded_records'] == EXPECTED['embedded_records'],
          '%d sub-files in %d files, %d records'
          % (out['embedded_subfiles'], out['embedded_files'], out['embedded_records']))

    # every relative record's c/d tables, walked
    bad = []
    for f in out['files']:
        d = read(f['path'])
        for cr in container_records(d):
            rec, origin = cr['rec'], cr['origin']
            nb, npal, sizes = table_blobs(d, origin, rec)
            if any(sz != 16384 for sz in sizes) or not npal:
                bad.append((f['path'], hex(rec['off']), hex(origin), sizes, npal))
    check('every container-relative c_table entry is [u32 len][LZSS] -> 16,384 B, '
          'full consumption', not bad, json.dumps(bad[:4]))
    check('the 78 DATA/04_PLAY files hold 234 128x128 pages (three per file)',
          out['play_blobs'] == 234, out['play_blobs'])
    check('the 19 area overlays hold 105 more such pages in embedded sub-files',
          out['outside_blobs'] == 105, out['outside_blobs'])
    check('every container-relative d_table entry is a 64-byte palette in-container',
          out['play_palettes'] + out['outside_palettes'] == EXPECTED['relative_records'],
          out['play_palettes'] + out['outside_palettes'])

    check('the resource-group companions VC61 / VB5A21 / VB5B31 resolve at 0x80080000',
          all(n in dpaths for n in ('VC61.BIN', 'VB5A21.BIN', 'VB5B31.BIN')))

    # --- instructions -------------------------------------------------------
    main = maindec.body()

    def w(va: int) -> int:
        return struct.unpack_from('<I', main, va - MAIN_BASE)[0]

    bad = [(hex(va), '%08X' % w(va), '%08X' % v[0]) for va, v in READER_EVIDENCE.items()
           if w(va) != v[0]]
    check('all %d form-B reader instruction words match' % len(READER_EVIDENCE), not bad,
          json.dumps(bad))

    bad = [(hex(va), '%08X' % w(va), '%08X' % v[0]) for va, v in CACHE_EVIDENCE.items()
           if w(va) != v[0]]
    check('all %d record-cache reader instruction words match' % len(CACHE_EVIDENCE), not bad,
          json.dumps(bad))

    bad = [(hex(va), '%08X' % w(va), '%08X' % v[0]) for va, v in RELOC_EVIDENCE.items()
           if w(va) != v[0]]
    check('all %d section-record relocator/walker instruction words match'
          % len(RELOC_EVIDENCE), not bad, json.dumps(bad))

    check('0x800C4320 reads +0x04 as a byte and 0x800C4330 sizes the table by it '
          '(malloc(count << 9))',
          w(0x800C4320) == 0x92C80004 and w(0x800C4330) == 0x00082240)

    check('the three callers of 0x800C3704 are 0x80127D9C / 0x8013218C / 0x80142128',
          all(w(a) == 0x0C030DC1 for a in (0x80127D9C, 0x8013218C, 0x80142128)))

    return len(fails)


def cmd_table() -> int:
    out = build()
    print('section records: %d in %d files (%d in the population)'
          % (out['records_total'], out['section_files'], out['population']))
    print('  container-relative  %3d records  (offsets from the container start, '
          'relocated by 0x800C473C)' % out['relative_records'])
    print('       78 DATA/04_PLAY files            %4d records  (%d 128x128 pages)'
          % (out['records_by_form'].get('A', 0), out['play_blobs']))
    print('       35 sub-files inside 19 overlays  %4d records' % out['embedded_records'])
    print('  absolute RAM ptrs   %3d records in %3d files  (pre-relocated)'
          % (out['absolute_records'], out['files_by_form'].get('B', 0)))
    print('  pointer fields resolved: %d/%d (%.1f%%) over form B; ambiguous records %d'
          % (out['absolute_pointers_resolved'], out['absolute_pointers_total'],
             100.0 * out['absolute_pointers_resolved'] / out['absolute_pointers_total'],
             out['ambiguous_records']))
    print()
    print('absolute records split by load base -- the discriminator:')
    for base, name in ((V_BASE, '0x80010000  V* + LOADING + DRAGON0'),
                       (DATA_BASE, '0x80080000  *_DATA + 3 duel + 3 companions')):
        fs = [f for f in out['files'] if f['form'] == 'B' and f['load_base'] == base]
        print('  %-40s %3d files  %4d records'
              % (name, len(fs), sum(f['absolute_records'] for f in fs)))
    print()
    print('the 10 densest absolute-record files:')
    for f in sorted((f for f in out['files'] if f['form'] == 'B'),
                    key=lambda f: -f['records'])[:10]:
        print('  %-42s %3d records @0x%08X  %s'
              % (f['path'], f['records'], f['load_base'], [hex(m) for m in f['magics']]))
    return 0


def cmd_file(name: str) -> int:
    pop = population()
    hit = [r for r in pop if r['path'] == name or os.path.basename(r['path']) == name]
    if not hit:
        print('no such overlay: %s' % name)
        return 1
    for r in hit:
        d = read(r['path'])
        base, res, amb = load_base(d)
        if all(0 < p < len(d) for x in records(d) for p in x['ptrs']):
            print('%s  %d bytes  container-relative, no load base  '
                  '(%d records, all pointers are container offsets)'
                  % (r['path'], len(d), len(records(d))))
        else:
            print('%s  %d bytes  load base 0x%08X  (%d pointers, %d not attributable)'
                  % (r['path'], len(d), base, res, amb))
        subs = subfiles(d)
        for rec in records(d):
            v, w_ = resolve(rec, len(d))
            origin = subs.get(rec['off'])
            if origin is not None or all(0 < p < len(d) for p in rec['ptrs']):
                tag = 'relative(%s)' % (hex(origin) if origin else 'file')
            else:
                tag = 'absolute'
            print('  +0x%06X magic=%04X a=%2d b=%2d  ptrs=%s  v=%d d=%d  %s'
                  % (rec['off'], rec['magic'], rec['a'], rec['b'],
                     [hex(p) for p in rec['ptrs']], v, w_, tag))
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument('--table', '--census', dest='table', action='store_true',
                   help='counts by form')
    g.add_argument('--file', help="one file's records, resolved")
    g.add_argument('--json', action='store_true', help='the census as JSON')
    g.add_argument('--verify', action='store_true', help='re-derive and assert')
    args = ap.parse_args(argv)
    if args.verify:
        n = verify()
        print('section_records --verify: %s' % ('PASS' if n == 0 else '%d FAIL' % n))
        return 1 if n else 0
    if args.table:
        return cmd_table()
    if args.file:
        return cmd_file(args.file)
    print(json.dumps(build(), indent=1))
    return 0


if __name__ == '__main__':
    sys.exit(main())

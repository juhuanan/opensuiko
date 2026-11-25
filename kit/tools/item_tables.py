#!/usr/bin/env python3
"""MAIN.EXE's item, equipment, weapon, rune, unite and spell tables, as data.

This is the index the manual's page 15 needs: for each table, its address, its
entry count, its entry size and its field layout, with an address per term.  A
"term" is a field; every field below carries the address of the instruction
that reads or writes it, so a claim here is checkable against the image.

Every address is a PlayStation virtual address in `MAIN.EXE`, the headerless
image at base `0x800C0800` (``disc.extract(...)[2048:]``).  The header strip is
load-bearing: with the 2048-byte PS-X header left on, every address reads 0x800
low (`main_item_tables.py` and `character_table.py` both did it the other way
once; `AGENTS.md` section 5).

## The item-id space, and the discriminator between the two readings

There are two ways to read this data and only one of them is right, so it is
stated once here rather than argued on every field.

* **Reading A (right).** `0x80167658` is an array of **pointers**, indexed by a
  16-bit **item id**.  Word `[0]` is zero; words `[1]..[179]` point at 179
  records laid out consecutively from `0x80168780` to `0x8016A0E0`.  Every
  screen indexes it the same way -- `sll id,2` then a load from `0x80167658`
  (shop `0x800D2CC0`, blacksmith `0x800D65C0`, item menus `0x800CB748`,
  equipment `0x800CC0B8`, appraiser `0x800CF37C`) -- and the price field is read
  at `+0x18` of the pointed-to record (`0x800D2CDC`).
* **Reading B (wrong).** `0x80168780` is a free-standing table of 40-byte
  equipment rows, and `0x80169798` a free-standing table of 36-byte item rows.

Reading B fits the *values*: each reading's stride is the same for every row in
its own run.  What settles it is the **allocation size** of the pointer array,
not the values.  `0x80167658` is a contiguous 181-word array: word 0 is zero,
words 1..179 are in-range pointers, and word 180 (`0x8016D18C`) begins a
*different* table (33 pointers to unit records).  The 179 pointers visit the
records in a non-ascending order -- e.g. item 24 is `0x80168B18`, item 25 is
`0x801686CC`, item 26 is `0x801686F0`, item 27 is `0x80168BE0` -- chosen so
that each record size is whichever of 0x28 (equipment) or 0x24 (item)
that record needs.  No single stride walks the record region in id order.  The
pointer array is therefore the id space, and the records number 179 -- not the
"58 equipment" plus "66 items" of reading B.

## The tables

| table | address | entries | entry | fields read at |
|---|---|---|---|---|
| item id -> record | `0x80167658` | 181 words (1..179 used) | `u32` | `sll id,2`; load |
| item records | `0x80168780`..`0x8016A0E0` | 179 | 0x24 (item) or 0x28 (equipment) | name `+0x00`, price `+0x18`, class `+0x1C`, kind `+0x1E` |
| equipment classes | item `+0x1C` low byte | 4 | `u8` | `& 0xE0` at `0x800CF3A0` |
| equipment class kinds | item `+0x1E` | - | `u16` | one byte per class, `& 0x7F` at `0x800CF3C0` |
| per-class handler table | `0x80167928` | 58 | 8 bytes | two code words at `+0x00`/`+0x04` |
| player weapons | `0x80166000` | 65 | 0x58 = 3 x 0x1C | tier names `+0x00`/`+0x1C`/`+0x38`, tier power `+0x15` |
| blacksmith weapon ids | `0x80165890` | 80 words (1..79 used) | `u32` | `sll id,2`; load (`0x800D65C4`) |
| blacksmith weapon records | `0x80165B30` | 79 | 0x58 | id 1..14 character weapons, id 15.. = `0x80166000 + (id-15)*0x58` |
| sharpen level cost | `0x8016AF2C` | 16 | `u32` | `[level]`, clamped at `0x800D65E0` |
| sharpen attack bonus | `0x801659D0` | 80 x 32 bytes (1..79 used) | `u16[16]` | `[id*0x20 + (level-1)*2]` (`0x800D6720`) |
| rune names | `0x8016A0E4` | 33 | `u32` | pointers; name 0 is `Soul Eater` |
| rune records | `0x8016A1B0` | 31 | 0x24 | name `+0x00`, class `+0x14`, kind `+0x18`, **spell ids `+0x1C..+0x1E`** |
| rune name pointers | `0x8016A0E4` | 33 (31 runes + `??????` + `True Holy Rune`) | `u32` | `*(0x8016A0E4 + n*4)` (`0x800C96A4`) |
| rune attach/detach handler kinds | `0x8016AB68` | 8 | `u32` | `[kind]`, `[0] = 0` (`0x800CE798`) |
| spell names | `0x8016D340` | 33 | `u32` | `*(0x8016D340 + (sid-1)*4)` |
| unite attacks | `0x8016CD0C` | 32 | 0x24 | name `+0x00` (14 bytes), flags `+0x16` (`u16`), member count `+0x18`, unite id `+0x19`, member character ids `+0x1A` |
| unite attack pointers | `0x8016D18C` | 33 words (1..32 used) | `u32` | `[id]`; the array bounds the unite table |

Field addresses are `0x...` values given per table in the JSON that `--json`
writes; `--verify` re-derives every one of them from the disc.

Usage:
    python3 item_tables.py --items
    python3 item_tables.py --weapons
    python3 item_tables.py --runes
    python3 item_tables.py --unites
    python3 item_tables.py --verify
    python3 item_tables.py --json kit/work/item_tables.json
"""
from __future__ import annotations

import argparse
import json
import os
import struct
import sys

_TOOLS = os.path.dirname(os.path.abspath(__file__))
_KIT = os.path.dirname(_TOOLS)
sys.path.insert(0, _TOOLS)
import disc  # noqa: E402
import war_text as _wt  # noqa: E402

MAIN_BASE = 0x800C0800
MAIN_NAME = "MAIN.EXE"

#: the item-id -> record pointer array, and the record region it bounds
ITEM_PTR = 0x80167658
ITEM_PTR_FIRST = 1
ITEM_PTR_LAST = 179
ITEM_REGION_LO = 0x801686CC          # the lowest record the id array names
ITEM_REGION_HI = 0x8016A0E0          # first byte past the last record

#: per-record fields (offsets from the record start)
NAME_OFF = 0x00
ITEM_PRICE_OFF = 0x18
ITEM_CLASS_OFF = 0x1C                # u16; the low byte is the class (masked 0xE0)
ITEM_KIND_OFF = 0x1E                 # u16; the sub-kind inside the class
ITEM_STRIDE_ITEM = 0x24
ITEM_STRIDE_EQUIP = 0x28

#: party inventory, in the game-state block
GS_PARTY_COUNT = 0x20                # lbu at 0x800CA518, guard sltiu 7
GS_PARTY_ITEMS = 0x21                # sb at 0x800CA52C, indexed by the count
GS_WAREHOUSE = 0x90                  # warehouse storage, indexed by item id

#: character item list, inside the 0x50-byte record at gs+0x294
CHAR_ITEM_COUNT_OFF = 0x1F           # lbu at 0x800CA398
CHAR_ITEM_ENTRY_OFF = 0x20           # + i*4
CHAR_ITEM_MAX = 8                    # sltiu 9 at 0x800CA3A0

EQUIP_CLASS_MASK = 0xE0              # andi at 0x800CF3A0 -- the class nibble
EQUIP_MASK = 0x8016AE00              # 5 u16, the shop builder's kind masks
EQUIP_SLOT = 0x8016AE0C              # 5 u16, 1..5
ITEM_CLASS_HANDLERS = 0x80167928     # 58 x 8, indexed by the class byte

WEAPON_TABLE = 0x80166000            # 65 x 0x58, player weapons
WEAPON_STRIDE = 0x58
WEAPON_SUBS = (0x00, 0x1C, 0x38)     # the three tier sub-records
WEAPON_TIER_POWER = 0x15
WEAPON_BLACKSMITH_PTR = 0x80165890   # 80 words: [0] = 77, [1..79] pointers
WEAPON_BLACKSMITH_LAST = 79
WEAPON_CHAR_REGION = 0x80165B30      # id 1..14
WEAPON_CHAR_COUNT = 14
SHARPEN_LEVEL_TABLE = 0x8016AF2C     # 16 u32, [0] = 0
SHARPEN_BONUS = 0x801659D0           # 80 x 0x20; [id*0x20 + (level-1)*2]

#: The rune-name pointer array, indexed directly by a rune slot id: `[0]` is
#: `Soul Eater` (its record is the one at `0x8016A168`), `[1]..[30]` are the 31
#: records of `RUNE_TABLE`, `[31]` is a `??????` placeholder and `[32]` is
#: `True Holy Rune`.  The byte at
#: `0x8016A0E0`, immediately before the array, is 31 -- the `RUNE_TABLE` count.
RUNE_NAME_PTR = 0x8016A0E4
RUNE_NAME_COUNT = 33
RUNE_NAME_COUNT_WORD = 0x8016A0E0
RUNE_NAME_LIMIT = 0x14
RUNE_TABLE = 0x8016A1B0              # 31 x 0x24
RUNE_STRIDE = 0x24
RUNE_CLASS_OFF = 0x14
RUNE_KIND_OFF = 0x18
RUNE_SPELL_OFF = 0x1B                # four spell-id bytes, one per spell slot
RUNE_SPELL_BYTES = 4
RUNE_EFFECT_KINDS = 0x8016AB68       # 8 code pointers, [0] = 0

SPELL_NAME_PTR = 0x8016D340          # 33 pointers to spell names

UNITE_TABLE = 0x8016CD0C             # 32 x 0x24
UNITE_STRIDE = 0x24
UNITE_COUNT = 32
#: The name is a fixed-width `0x14`-byte literal at `+0x00` (`literal_at`); the
#: longest, `Lepant family attack`, fills the field with no terminator.  The
#: fields below are the ones the matcher at `0x800F91C0` consumes: `+0x16` is a
#: `u16` flag word (read with `lhu` at `0x800F588C`, tested with `andi 0x2` at
#: `0x800EDA08`), `+0x18` is the member **count** (`lbu $t3,0x18($v1)` at
#: `0x800F9210`, used as the loop bound at `0x800F928C`), `+0x19` is the unite
#: attack's id (`lbu 0x19` at `0x800F5914`, indexing the pointer table at
#: `0x8016D2D0`) and `+0x1A` begins one **character id** per member
#: (`lbu $a3,0x1a($v0)` at `0x800F9238`).  There is no element byte.
UNITE_NAME_OFF = 0x00
UNITE_NAME_LIMIT = 0x14
UNITE_FLAGS_OFF = 0x16
UNITE_MEMBER_COUNT_OFF = 0x18
UNITE_MEMBER_ID_OFF = 0x19
UNITE_MEMBERS_OFF = 0x1A              # one character id per member
UNITE_SLOTS_MAX = 10
UNITE_PTR = 0x8016D18C               # 33 words: [0] = 0, [1..32] records
UNITE_ACTION_PTR = 0x8016D2D0        # indexed by the +0x19 unite id

_IMG = None


def image() -> bytes:
    """`MAIN.EXE` with the 2048-byte PS-X header stripped."""
    global _IMG
    if _IMG is None:
        with open(os.path.join(_KIT, "data", "catalogs", "extracted", "iso_files.json"), encoding="utf-8") as f:
            rec = next(r for r in json.load(f) if r.get("path") == MAIN_NAME)
        _IMG = disc.extract(rec["lba"], rec["size"])[2048:]
    return _IMG


def word(addr: int) -> int:
    return struct.unpack_from("<I", image(), addr - MAIN_BASE)[0]


def half(addr: int) -> int:
    return struct.unpack_from("<H", image(), addr - MAIN_BASE)[0]


def byte(addr: int) -> int:
    return image()[addr - MAIN_BASE]


def name_at(addr: int, limit: int = 0x1C) -> str | None:
    """The NUL-terminated game-text name at `addr`, or None if it is not one."""
    img = image()
    o = addr - MAIN_BASE
    if o < 0 or o >= len(img) or not _wt.is_text_byte(img[o]):
        return None
    j = o
    while j < o + limit and j < len(img) and _wt.is_text_byte(img[j]):
        j += 1
    if j >= o + limit or j >= len(img) or img[j] != 0 or j - o < 3:
        return None
    text, _used = _wt.decode(img, o, j - o)
    return text if text and text[0].isalnum() else None


def literal_at(addr: int, n: int) -> str | None:
    """A fixed-width game-text literal: exactly `n` bytes, NUL- or space-padded.

    The unite names use this shape -- the longest, `Lepant family attack`, fills
    all `0x14` bytes with no terminator, so a NUL-terminated read cannot see it.
    """
    img = image()
    o = addr - MAIN_BASE
    if o < 0 or o + n > len(img):
        return None
    text, _used = _wt.decode(img, o, n)
    text = text.split("\0")[0].rstrip()
    if len(text) < 3 or not text[0].isalnum():
        return None
    if any(ord(c) < 0x20 or ord(c) > 0x7E for c in text):
        return None
    return text


# --------------------------------------------------------------------------
# the tables
# --------------------------------------------------------------------------

def item_pointers() -> list[int | None]:
    """The id -> record pointer array, in id order (index 0 is id 1)."""
    out = []
    for i in range(ITEM_PTR_LAST):
        v = word(ITEM_PTR + 4 * (i + 1))
        out.append(v if ITEM_REGION_LO <= v < ITEM_REGION_HI else None)
    return out


def item_entry_stride(i: int, ptrs: list[int | None] | None = None) -> int:
    """The byte size of item id `i+1`: the next pointer minus this one."""
    if ptrs is None:
        ptrs = item_pointers()
    if i + 1 < len(ptrs) and ptrs[i + 1] is not None:
        return ptrs[i + 1] - ptrs[i]
    return ITEM_REGION_HI - ptrs[i]


def items() -> list[dict]:
    """The 179 item records, in item-id order, with the fields the code reads."""
    ptrs = item_pointers()
    out = []
    for i, p in enumerate(ptrs):
        stride = item_entry_stride(i, ptrs)
        out.append({
            "id": i + 1,
            "addr": p,
            "stride": stride,
            "name": name_at(p, 0x18),
            "price": word(p + ITEM_PRICE_OFF),
            "class": byte(p + ITEM_CLASS_OFF),
            "kind": half(p + ITEM_KIND_OFF),
        })
    return out


def acquisition_message(item_id: int) -> bytes:
    """NUL-terminated game text built by opcode 49 FE/FF (MAIN 0x8013B9D8).

    Ordinary names are capped at 21 encoded bytes; antique-class items use
    the shared message instead. Keep encoded line breaks for the text decoder.
    """
    if type(item_id) is not int or not 1 <= item_id <= ITEM_PTR_LAST:
        raise ValueError(f"Invalid source item id: {item_id!r}")
    img = image()

    def string_at(addr: int) -> bytes:
        offset = addr - MAIN_BASE
        if not 0 <= offset < len(img):
            raise ValueError(f"Item message pointer outside MAIN.EXE: {addr:#x}")
        return img[offset:img.index(0, offset)]

    record = word(ITEM_PTR + 4 * item_id)
    if not ITEM_REGION_LO <= record < ITEM_REGION_HI:
        raise ValueError(f"Item record outside MAIN.EXE item region: {record:#x}")
    if half(record + ITEM_CLASS_OFF) & 0x7000:
        message = string_at(word(0x80171C20))
    else:
        offset = record - MAIN_BASE
        name = img[offset:offset + 21].split(b"\0", 1)[0]
        message = name + string_at(word(0x80171C1C))
    return message + b"\0"


def equipment_classes() -> list[dict]:
    """The four item classes the records sort into, by the class byte at `+0x1C`.

    The class byte is the record's low byte at `+0x1C`; the code reads it as a
    halfword and masks with `0xE0` (`0x800CF38C` `lhu`, `0x800CF3A0` `andi`).
    Within a class the records are ordered by ascending price and the names read
    as a slot sequence (Bandanna / Headband / Pointed hat .. for `0x80`,
    Robe / Tunic / Leather coat .. for `0xA0`).

    Which slot each `+0x1E` kind value maps to is **not** claimed here: the
    table at `0x8016A8C6` that the equipment screen consults does not reproduce
    the class bytes under a reading that fits both its stride and its values, so
    the mapping is left to `kit/work/extract_item_tables.jsonl`.
    """
    out = []
    for cls, label in ((0x80, "head"), (0xA0, "body"), (0xC0, "shield"),
                       (0xE0, "feet_or_accessory")):
        ids = [it["id"] for it in items() if it["class"] == cls]
        out.append({"class": cls, "label": label, "count": len(ids),
                    "ids": ids,
                    "first": items()[ids[0] - 1]["name"],
                    "last": items()[ids[-1] - 1]["name"],
                    "kinds": sorted({it["kind"] for it in items() if it["class"] == cls})})
    return out


def item_class_handlers() -> list[tuple[int, int]]:
    """The 58 eight-byte rows indexed by `item+0x1F`: a pair of code words."""
    return [(word(ITEM_CLASS_HANDLERS + 8 * i), word(ITEM_CLASS_HANDLERS + 8 * i + 4))
            for i in range(58)]


def weapons() -> list[dict]:
    """The 65 player weapons, each with its three tier sub-records."""
    out = []
    for i in range(65):
        base = WEAPON_TABLE + WEAPON_STRIDE * i
        tiers = []
        for k, off in enumerate(WEAPON_SUBS):
            a = base + off
            tiers.append({"tier": k + 1, "off": off, "name": name_at(a, 0x1C),
                          "power": byte(a + WEAPON_TIER_POWER)})
        out.append({"id": i + 1, "addr": base, "names": [t["name"] for t in tiers],
                    "tiers": tiers})
    return out


def blacksmith_weapons() -> list[dict]:
    """The blacksmith's weapon ids: 79 pointers, 14 character + 65 player."""
    out = []
    for i in range(1, WEAPON_BLACKSMITH_LAST + 1):
        v = word(WEAPON_BLACKSMITH_PTR + 4 * i)
        out.append({"id": i, "addr": v, "name": name_at(v, 0x1C),
                    "power": byte(v + WEAPON_TIER_POWER),
                    "sharpen_cost": byte(v + 0x54)})
    return out


def sharpen_table() -> list[dict]:
    """Per weapon id, the 16 halfword attack bonuses the blacksmith can apply."""
    return [{"id": i,
             "addr": SHARPEN_BONUS + 0x20 * i,
             "levels": [half(SHARPEN_BONUS + 0x20 * i + 2 * k) for k in range(16)]}
            for i in range(1, WEAPON_BLACKSMITH_LAST + 1)]


def rune_names() -> list[str | None]:
    """The 32 rune names; the array is indexed directly by a rune's slot id."""
    return [literal_at(word(RUNE_NAME_PTR + 4 * i), RUNE_NAME_LIMIT)
            for i in range(RUNE_NAME_COUNT)]


def runes() -> list[dict]:
    """The 31 rune records.

    `class` is the word at `+0x14`, `kind` the word at `+0x18`, and
    `spell_ids` the four bytes at `+0x1B`..`+0x1E` -- one spell id per spell
    slot, zero for a rune that casts nothing.
    """
    out = []
    for i in range(31):
        a = RUNE_TABLE + RUNE_STRIDE * i
        out.append({"index": i, "addr": a, "name": name_at(a, 0x14),
                    "class": word(a + RUNE_CLASS_OFF),
                    "kind": word(a + RUNE_KIND_OFF),
                    "spell_ids": [byte(a + RUNE_SPELL_OFF + b)
                                   for b in range(RUNE_SPELL_BYTES)]})
    return out


def spell_names() -> list[str | None]:
    """The 33 spell names; the rune records' spell ids are 1-based into this."""
    return [name_at(word(SPELL_NAME_PTR + 4 * i), 0x18) for i in range(33)]


def _trim(vals: list[int]) -> list[int]:
    """Drop the zero tail of a member list -- the slot count is an upper bound."""
    while vals and vals[-1] == 0:
        vals = vals[:-1]
    return vals


def unites() -> list[dict]:
    """The 32 unite attacks: name, flags, member count, member ids and unite id.

    The name is a fixed-width `0x14`-byte literal (`literal_at`), not a
    NUL-terminated string: the longest names fill the whole field.  The member
    ids are character ids, and the field layout is the one the matcher at
    `0x800F91C0` consumes; `kit/tools/q_residue.py --verify` re-derives it.
    """
    out = []
    for i in range(UNITE_COUNT):
        a = UNITE_TABLE + UNITE_STRIDE * i
        n = byte(a + UNITE_MEMBER_COUNT_OFF)
        slots = [byte(a + UNITE_MEMBERS_OFF + k) for k in range(UNITE_SLOTS_MAX)]
        out.append({"index": i, "addr": a,
                    "name": literal_at(a + UNITE_NAME_OFF, UNITE_NAME_LIMIT),
                    "name_addr": a + UNITE_NAME_OFF,
                    "flags_addr": a + UNITE_FLAGS_OFF,
                    "count_addr": a + UNITE_MEMBER_COUNT_OFF,
                    "members_addr": a + UNITE_MEMBERS_OFF,
                    "unite_id_addr": a + UNITE_MEMBER_ID_OFF,
                    "flags": half(a + UNITE_FLAGS_OFF),
                    "members": _trim(slots[:n]) if n <= UNITE_SLOTS_MAX else None,
                    "member_count": n,
                    "unite_id": byte(a + UNITE_MEMBER_ID_OFF)})
    return out


def item_id_space() -> dict:
    """The evidence that settles the item-id space: the pointer array's bounds."""
    ptrs = item_pointers()
    return {
        "array": f"{ITEM_PTR:#010x}",
        "word_before": f"{word(ITEM_PTR - 4):#010x}",
        "word_0": f"{word(ITEM_PTR):#010x}",
        "first_used_index": ITEM_PTR_FIRST,
        "last_used_index": ITEM_PTR_LAST,
        "used": sum(1 for p in ptrs if p is not None),
        "word_after": f"{word(ITEM_PTR + 4 * (ITEM_PTR_LAST + 1)):#010x}",
        "record_region": [f"{ITEM_REGION_LO:#010x}", f"{ITEM_REGION_HI:#010x}"],
        "ascending": all(a < b for a, b in zip(ptrs, ptrs[1:]) if a and b),
    }


# --------------------------------------------------------------------------
# verification
# --------------------------------------------------------------------------

def verify() -> list[str]:
    """Re-derive every claim from the image.  Returns a list of failures."""
    bad: list[str] = []

    def check(cond, msg):
        if not cond:
            bad.append(msg)

    img = image()
    check(struct.unpack_from("<I", img, 0)[0] != 0x50422D5358, "image still has a PS-X header")

    # ---- the pointer array bounds the item-id space
    sp = item_id_space()
    check(int(sp["word_0"], 16) != 0, "item pointer word 0 is zero")
    check(sp["used"] == ITEM_PTR_LAST, f"{sp['used']} item pointers, expected {ITEM_PTR_LAST}")
    check(not (ITEM_REGION_LO <= int(sp["word_after"], 16) < ITEM_REGION_HI),
          "the word after the item pointers is itself an item record (array is not bounded)")
    check(not sp["ascending"],
          "the item pointers are ascending -- the id space would then be a plain stride")

    # ---- the records: ids 1..179, and the region is exactly consumed
    its = items()
    check(len(its) == 179, f"{len(its)} item records, expected 179")
    check(its[0]["addr"] == 0x80168780, f"item 1 at {its[0]['addr']:#x}")
    check(its[-1]["name"] == "Mathiu's letter", f"item 179 is {its[-1]['name']!r}")
    check(its[-1]["addr"] + its[-1]["stride"] == ITEM_REGION_HI,
          "the last item record does not end at 0x8016A0E0")
    check(its[24]["addr"] == ITEM_REGION_LO, f"item 25 at {its[24]['addr']:#x}")
    jumps = [(a["id"], b["id"]) for a, b in zip(its, its[1:])
             if abs(b["addr"] - a["addr"]) not in (ITEM_STRIDE_ITEM, ITEM_STRIDE_EQUIP)]
    check(jumps == [(24, 25), (26, 27), (66, 67), (70, 71), (73, 74)],
          f"unexpected address jumps between ids: {jumps}")
    prev = None
    for it in its:
        if prev is not None and ITEM_REGION_LO <= it["addr"] < ITEM_REGION_HI \
                and ITEM_REGION_LO <= prev["addr"] < ITEM_REGION_HI \
                and abs(it["addr"] - prev["addr"]) in (ITEM_STRIDE_ITEM, ITEM_STRIDE_EQUIP):
            check(True, "")

        prev = it
        check(it["name"] is not None, f"item {it['id']} has no name at {it['addr']:#x}")
        if it["name"] is not None:
            check(img[it["addr"] - MAIN_BASE + len(_wt.encode(it["name"]))] == 0,
                  f"item {it['id']} name is not NUL-terminated inside its record")

    # ---- the fixed anchor records the shop / blacksmith / appraiser read
    by_id = {i["id"]: i for i in its}
    for iid, nm, price in ((1, "Bandanna", 50), (25, "Medicine", 100),
                           (26, "Antitoxin", 200), (114, "Failure urn", 20),
                           (179, "Mathiu's letter", 0)):
        check(by_id[iid]["name"] == nm, f"item {iid} is {by_id[iid]['name']!r}, expected {nm!r}")
        check(by_id[iid]["price"] == price,
              f"item {iid} price {by_id[iid]['price']}, expected {price}")

    # ---- equipment: the class byte splits the records into four runs, each a
    #      named slot sequence with ascending prices
    cls = equipment_classes()
    check([c["class"] for c in cls] == [0x80, 0xA0, 0xC0, 0xE0],
          f"equipment classes {[hex(c['class']) for c in cls]}")
    check([c["count"] for c in cls] == [8, 16, 4, 30],
          f"equipment class counts {[c['count'] for c in cls]}")
    check(cls[0]["first"] == "Bandanna" and cls[0]["last"] == "Horned helmet",
          f"head run {cls[0]['first']!r}..{cls[0]['last']!r}")
    check(cls[1]["first"] == "Robe" and cls[1]["last"] == "Windspun armor",
          f"body run {cls[1]['first']!r}..{cls[1]['last']!r}")
    check(cls[2]["first"] == "Wooden shield" and cls[2]["last"] == "Earth shield",
          f"shield run {cls[2]['first']!r}..{cls[2]['last']!r}")
    check(cls[3]["first"] == "Wooden shoes" and cls[3]["last"] == "Gold necklace",
          f"feet/accessory run {cls[3]['first']!r}..{cls[3]['last']!r}")
    for c in cls:
        col = [by_id[i]["price"] for i in c["ids"]]
        runs = 1
        for x, y in zip(col, col[1:]):
            if y < x:
                runs += 1
        # every class reads as a small number of ascending price runs, never as
        # one unsorted column
        check(runs <= 8, f"class {c['class']:#x} price column has {runs} runs")
        check(col[0] < col[-1], f"class {c['class']:#x} prices do not rise")
    check([by_id[i]["price"] for i in cls[0]["ids"]] ==
          sorted(by_id[i]["price"] for i in cls[0]["ids"]),
          "the head class is not a single ascending price run")

    # ---- weapons: 65, and the tier-2 power is above tier-1 in all 65
    ws = weapons()
    check(len(ws) == 65, f"{len(ws)} weapons, expected 65")
    rises = sum(1 for w in ws if w["tiers"][1]["power"] > w["tiers"][0]["power"])
    check(rises == 65, f"tier-2 power rises in {rises}/65 weapons")
    check(sum(1 for w in ws if w["tiers"][2]["power"] == 0) == 65,
          "tier-3 power is not uniformly zero -- the tier-3 sub-record is not what is claimed")
    check(ws[0]["names"] == ["Wind Rod", "Gale Rod", "Gust Rod"], ws[0]["names"])
    check(ws[-1]["names"] == ["Star Dragon Sword", "Black Dragon Sword", "King Dragon Sword"],
          ws[-1]["names"])

    # ---- blacksmith: id 15 is weapon 1, and its ids are the 14 + 65 split
    bs = blacksmith_weapons()
    check(len(bs) == 79, f"{len(bs)} blacksmith weapon ids, expected 79")
    check(bs[0]["addr"] == WEAPON_CHAR_REGION, f"blacksmith id 1 at {bs[0]['addr']:#x}")
    check(bs[14]["addr"] == WEAPON_TABLE, f"blacksmith id 15 at {bs[14]['addr']:#x}")
    for k in range(1, WEAPON_BLACKSMITH_LAST - WEAPON_CHAR_COUNT):
        check(bs[WEAPON_CHAR_COUNT + k]["addr"] == WEAPON_TABLE + WEAPON_STRIDE * k,
              f"blacksmith id {WEAPON_CHAR_COUNT + 1 + k} is not weapon {k + 1}")
    lv = [word(SHARPEN_LEVEL_TABLE + 4 * i) for i in range(16)]
    check(lv[0] == 0 and lv[1:] == sorted(lv[1:]) and lv[-1] == 0x11170,
          f"sharpen level table {[hex(v) for v in lv]}")
    sh = sharpen_table()
    check(all(len(s["levels"]) == 16 for s in sh), "a sharpen row is not 16 halfwords")

    # ---- runes: 31 records; the spell-bearing runes carry three 1-based spell
    #      ids, and every other rune's three slots are zero
    rn = runes()
    check(len(rn) == 31, f"{len(rn)} rune records, expected 31")
    check(rn[0]["name"] == "Fire Rune" and rn[-1]["name"] == "Thunder Rune",
          f"rune ends are {rn[0]['name']!r} .. {rn[-1]['name']!r}")
    casting = [r for r in rn if any(r["spell_ids"])]
    check(len(casting) == 11, f"{len(casting)} runes carry spell ids, expected 11")
    for r in casting:
        check(all(1 <= b <= 33 for b in r["spell_ids"]),
              f"rune {r['name']!r} spell ids {r['spell_ids']}")
        check(all(b != 0 for b in r["spell_ids"]),
              f"rune {r['name']!r} has a zero in its spell ids")
    check(rn[0]["spell_ids"] == [1, 2, 3, 4], f"Fire Rune spells {rn[0]['spell_ids']}")
    check(rn[5]["spell_ids"] == [5, 6, 7, 8], f"Resurrection Rune spells {rn[5]['spell_ids']}")
    check(rn[26]["spell_ids"] == [2, 3, 4, 0x1D],
          f"Rage Rune spells {rn[26]['spell_ids']}")
    check(all(not any(r["spell_ids"]) for r in rn[6:26]),
          "a passive rune (index 6..25) carries spell ids")
    names33 = spell_names()
    check(names33[0] == "Flaming Arrows", f"spell 1 is {names33[0]!r}")
    check(names33[32] == "Guardian of Earth", f"spell 33 is {names33[32]!r}")
    for r in casting:
        for b in r["spell_ids"]:
            check(names33[b - 1] is not None,
                  f"rune {r['name']!r} spell id {b} has no name")
    kinds = [word(RUNE_EFFECT_KINDS + 4 * i) for i in range(8)]
    check(kinds[0] == 0, f"rune effect kind 0 is {kinds[0]:#x}, expected 0")
    check(all(0x800C0800 <= k < 0x80180000 for k in kinds[1:]),
          f"rune effect kinds are not code pointers: {[hex(k) for k in kinds]}")
    names32 = rune_names()
    check(len(names32) == 33, f"{len(names32)} rune names")
    check(names32[0] == "Soul Eater", f"rune name 0 is {names32[0]!r}")
    check(names32[1] == "Fire Rune" and names32[30] == "Thunder Rune",
          f"rune names 1/30 are {names32[1]!r}/{names32[30]!r}")
    check(names32[32] == "True Holy Rune", f"rune name 32 is {names32[32]!r}")
    check(byte(0x8016A18C) == 0x58, "rune name 31's placeholder glyph changed")
    check(word(RUNE_NAME_COUNT_WORD) == 31,
          f"the count word before the rune names is {word(RUNE_NAME_COUNT_WORD)}")

    # ---- unite attacks: 32 records and a 33-word id array that bounds them
    un = unites()
    check(len(un) == UNITE_COUNT, f"{len(un)} unite records, expected {UNITE_COUNT}")
    check(word(UNITE_PTR) == 0, f"unite pointer word 0 is {word(UNITE_PTR):#x}")
    check(not (0x8016CD0C <= word(UNITE_PTR + 4 * (UNITE_COUNT + 1)) < 0x8016D18C),
          "the unite pointer array is not bounded by a non-pointer word")
    check(word(UNITE_PTR + 4 * UNITE_COUNT) == UNITE_TABLE + UNITE_STRIDE * (UNITE_COUNT - 1),
          "the last unite pointer does not name the last record")
    for i, u in enumerate(un):
        check(word(UNITE_PTR + 4 * (i + 1)) == u["addr"],
              f"unite id {i + 1} pointer does not name record {u['addr']:#x}")
        check(u["name"] is not None, f"unite {i} at {u['addr']:#x} has no name")
        check(1 <= u["member_count"] <= 4,
              f"unite {i} member count {u['member_count']}")
        check(len(u["members"]) == u["member_count"],
              f"unite {i} has {len(u['members'])} members for a count of "
              f"{u['member_count']}")
        # character id 0 is Eileen, so a member id of zero is legal
        check(all(0 <= m <= 109 for m in u["members"]),
              f"unite {i} member {u['members']} out of the character-id range")
        check(u["flags"] & 1, f"unite {i} flags {u['flags']:#x} lack bit 0")
        check(0 <= u["unite_id"] <= 0xFF, f"unite {i} id {u['unite_id']}")
    check(un[0]["name"] == "Talisman attack", f"unite 0 is {un[0]['name']!r}")
    check(un[-1]["name"] == "Master pupil attack", f"unite 31 is {un[-1]['name']!r}")
    check([u["name"] for u in un] == [
        "Talisman attack", "Fisherman attack", "Wild arrow attack", "Elf attack",
        "Pirate attack", "Blacksmith attack", "Bumpy attack", "Pretty boy attack",
        "Pretty girl attack", "Beauty attack", "Flash attack", "Kobold attack",
        "Dragon Knight attack", "Fatal attack", "Trick attack", "Warriors attack",
        "Couple attack", "Bandit attack", "Carpenter attack", "Wild arrow attack",
        "Wild arrow attack", "Blacksmith attack", "Blacksmith attack",
        "Blacksmith attack", "Blacksmith attack", "Beauty attack",
        "Kobold \\x5b 1 attack", "Beat'em up attack", "Ninja attack",
        "Martial arts attack", "Lepant family attack", "Master pupil attack"],
        "the unite name list does not reproduce")
    check(un[0]["member_count"] == 2, f"unite 0 count {un[0]['member_count']}")
    check(un[0]["members"] == [6, 2], f"unite 0 members {un[0]['members']}")
    check(un[0]["unite_id"] == 1, f"unite 0 id {un[0]['unite_id']}")
    check(un[16]["members"] == [0, 30],
          f"Couple attack members {un[16]['members']} (Eileen is character id 0)")
    check(un[31]["members"] == [8, 91],
          f"Master pupil members {un[31]['members']} (Hero + Kai)")
    check({u["flags"] for u in un} == {1, 3}, "the +0x16 flag set changed")
    for i, u in enumerate(un):
        check(u["member_count"] == byte(u["count_addr"]),
              f"unite {i} count address does not hold its count")
        check(u["members_addr"] == u["count_addr"] + 2,
              f"unite {i} member ids are not two past the count")
        check(u["unite_id_addr"] == u["count_addr"] + 1,
              f"unite {i} unite id is not one past the count")
        check(len(u["members"]) == u["member_count"],
              f"unite {i} member list is not exactly the count long")

    return bad


# --------------------------------------------------------------------------
# cli
# --------------------------------------------------------------------------

def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--items", action="store_true", help="the 179 item records")
    ap.add_argument("--equipment", action="store_true", help="the five equipment slots")
    ap.add_argument("--weapons", action="store_true", help="the 65 player weapons")
    ap.add_argument("--blacksmith", action="store_true", help="the blacksmith weapon ids")
    ap.add_argument("--runes", action="store_true", help="the 31 rune records")
    ap.add_argument("--spells", action="store_true", help="the 33 spell names")
    ap.add_argument("--unites", action="store_true", help="the 32 unite attacks")
    ap.add_argument("--lone-runes", action="store_true",
                    help="the two rune names that carry no record of their own")
    ap.add_argument("--verify", action="store_true")
    ap.add_argument("--json")
    args = ap.parse_args(argv)

    if args.verify:
        bad = verify()
        for b in bad:
            print("FAIL:", b)
        if bad:
            print(f"FAIL: {len(bad)} check(s)")
            return 1
        print("PASS: item tables -- the pointer array bounds the id space at 179 "
              "records, the record region is exactly consumed, 65 weapons with a "
              "tier-2 power rise, 31 runes with in-range spell ids, 33 spell names, "
              "and 32 unite attacks each named by the id array")
        return 0

    if args.items:
        for it in items():
            print(f"  [{it['id']:3d}] 0x{it['addr']:08X} +{it['stride']:#04x} "
                  f"{str(it['name'])[:26]:28s} price={it['price']:7d} "
                  f"class={it['class']:#04x} kind={it['kind']:#06x}")
        return 0
    if args.equipment:
        for c in equipment_classes():
            print(f"  class {c['class']:#04x} {c['label']:18s} n={c['count']:3d} "
                  f"kinds={[hex(k) for k in c['kinds']]} {c['first']!r} .. {c['last']!r}")
        return 0
    if args.weapons:
        for w in weapons():
            print(f"  [{w['id']:2d}] 0x{w['addr']:08X} " +
                  " / ".join(f"{t['name']}:{t['power']}" for t in w["tiers"]))
        return 0
    if args.blacksmith:
        for w in blacksmith_weapons():
            print(f"  [{w['id']:2d}] 0x{w['addr']:08X} {str(w['name'])[:24]:26s} "
                  f"power={w['power']} cost={w['sharpen_cost']:#x}")
        return 0
    if args.runes:
        for r in runes():
            print(f"  [{r['index']:2d}] 0x{r['addr']:08X} {str(r['name'])[:22]:24s} "
                  f"class={r['class']:#010x} kind={r['kind']:#010x} spells={r['spell_ids']}")
        return 0
    if args.spells:
        for i, n in enumerate(spell_names()):
            print(f"  [{i + 1:2d}] {n}")
        return 0
    if args.unites:
        for u in unites():
            print(f"  [{u['index']:2d}] 0x{u['addr']:08X} {str(u['name'])[:24]:26s} "
                  f"flags={u['flags']:#06x} members={u['members']} "
                  f"unite_id={u['unite_id']}")
        return 0
    if args.lone_runes:
        for i, n in enumerate(rune_names()):
            print(f"  [{i:2d}] {n}")
        return 0

    if args.json:
        data = {
            "item_id_space": item_id_space(),
            "items": items(),
            "equipment_classes": equipment_classes(),
            "item_class_handlers": item_class_handlers(),
            "weapons": weapons(),
            "blacksmith_weapons": blacksmith_weapons(),
            "sharpen": sharpen_table(),
            "rune_names": rune_names(),
            "runes": runes(),
            "spell_names": spell_names(),
            "unites": unites(),
        }
        with open(args.json, "w") as f:
            json.dump(data, f, indent=1)
        print(f"wrote {args.json}")
        return 0

    print(__doc__.split("Usage:")[0])
    return 0


if __name__ == "__main__":
    sys.exit(main())

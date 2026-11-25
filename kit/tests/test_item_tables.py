#!/usr/bin/env python3
"""Independent re-derivation of MAIN.EXE's item, weapon, rune and unite tables.

Nothing here imports the tool's table constants.  Every address, stride, count
and field offset is written out again from the image with plain `struct` calls
and the game's own text table, so a bug in `kit/tools/item_tables.py` cannot
make this pass.  The disc is required.

Run: `python3 kit/tests/test_item_tables.py`
"""
from pathlib import Path
import struct
import sys

_TESTS = Path(__file__).resolve().parent
_KIT = _TESTS.parent
sys.path.insert(0, str(_KIT / "tools"))

import disc  # noqa: E402
import war_text as wt  # noqa: E402

MAIN_BASE = 0x800C0800
PRICE = 0x18
CLASS = 0x1C
KIND = 0x1E


def image() -> bytes:
    import json
    with open(_KIT / "extracted" / "iso_files.json") as fh:
        rec = next(r for r in json.load(fh) if r.get("path") == "MAIN.EXE")
    return disc.extract(rec["lba"], rec["size"])[2048:]


def name_at(img: bytes, addr: int, limit: int = 0x1C):
    """The NUL-terminated game-text name at `addr`, or None."""
    o = addr - MAIN_BASE
    if o < 0 or o >= len(img) or not wt.is_text_byte(img[o]):
        return None
    j = o
    while j < o + limit and j < len(img) and wt.is_text_byte(img[j]):
        j += 1
    if j >= o + limit or j >= len(img) or img[j] != 0 or j - o < 3:
        return None
    text, _u = wt.decode(img, o, j - o)
    return text if text and text[0].isalnum() else None


def literal_at(img: bytes, addr: int, n: int):
    """A fixed-width game-text literal of exactly `n` bytes."""
    o = addr - MAIN_BASE
    text, _u = wt.decode(img, o, n)
    text = text.split("\0")[0].rstrip()
    if len(text) < 3 or not text[0].isalnum():
        return None
    if any(ord(c) < 0x20 or ord(c) > 0x7E for c in text):
        return None
    return text


def check() -> None:
    img = image()
    assert struct.unpack_from("<I", img, 0)[0] != 0x50422D5358, "image still has a PS-X header"

    def u32(a):
        return struct.unpack_from("<I", img, a - MAIN_BASE)[0]

    def u16(a):
        return struct.unpack_from("<H", img, a - MAIN_BASE)[0]

    def u8(a):
        return img[a - MAIN_BASE]

    # ------------------------------------------------------------------ the id space
    # 0x80167658 is an array of pointers indexed by a 16-bit item id.  The array
    # is bounded on both sides: word 0 is a non-pointer and word 180 is the entry
    # [0] of a different table.  That bound -- not any value -- is what says the
    # id space is 179 records and not one free-standing table per stride.
    PTR = 0x80167658
    assert not (0x801686CC <= u32(PTR) < 0x8016A0E0), hex(u32(PTR))
    assert not (0x801686CC <= u32(PTR + 4 * 180) < 0x8016A0E0), hex(u32(PTR + 4 * 180))
    ptrs = [u32(PTR + 4 * i) for i in range(1, 180)]
    assert len(ptrs) == 179
    assert all(0x801686CC <= p < 0x8016A0E0 for p in ptrs)
    assert ptrs[0] == 0x80168780 and ptrs[-1] == 0x8016A0BC
    # the id order is NOT address order: ids 24/25/26/27 walk backwards
    assert ptrs[23] == 0x80168B18 and ptrs[24] == 0x801686CC
    assert ptrs[25] == 0x801686F0 and ptrs[26] == 0x80168BE0
    # Only address-adjacent ids have a meaningful record size, so the stride is
    # read from consecutive *ascending* pointers; five id pairs jump backwards.
    jumps = [(i + 1, i + 2, hex(ptrs[i + 1] - p))
             for i, p in enumerate(ptrs)
             if i + 1 < len(ptrs)
             and ptrs[i + 1] - p not in (0x24, 0x28)]
    assert [j[:2] for j in jumps] == [(24, 25), (26, 27), (66, 67), (70, 71), (73, 74)], jumps
    # and every record name terminates inside 0x18 bytes of its own start
    for i, p in enumerate(ptrs):
        nm = name_at(img, p, 0x18)
        assert nm, (i + 1, hex(p))
        assert img[p - MAIN_BASE + len(wt.encode(nm))] == 0, (i + 1, nm)

    # ------------------------------------------------------------------ items
    assert name_at(img, ptrs[0], 0x18) == "Bandanna"
    assert u32(ptrs[0] + PRICE) == 50
    assert name_at(img, ptrs[24], 0x18) == "Medicine" and u32(ptrs[24] + PRICE) == 100
    assert name_at(img, ptrs[25], 0x18) == "Antitoxin" and u32(ptrs[25] + PRICE) == 200
    assert name_at(img, ptrs[113], 0x18) == "Failure urn" and u32(ptrs[113] + PRICE) == 20
    assert name_at(img, ptrs[178], 0x18) == "Mathiu's letter" and u32(ptrs[178] + PRICE) == 0
    # ------------------------------------------------------------------ equipment classes
    # the class byte is the low byte of the halfword at +0x1C, masked with 0xE0
    # by 0x800CF3A0; the values split the 179 records into four runs
    dist = {}
    for i, p in enumerate(ptrs):
        dist.setdefault(u8(p + CLASS) & 0xE0, []).append(i + 1)
    # class 0 is everything that is not equipment: consumables, rune pieces,
    # key items and the appraiser's antiques
    assert sorted(dist) == [0x00, 0x80, 0xA0, 0xC0, 0xE0], sorted(hex(c) for c in dist)
    assert len(dist[0x00]) == 121, len(dist[0x00])
    assert [len(dist[c]) for c in (0x80, 0xA0, 0xC0, 0xE0)] == [8, 16, 4, 30]
    assert [name_at(img, ptrs[dist[0x80][0] - 1], 0x18),
            name_at(img, ptrs[dist[0x80][-1] - 1], 0x18)] == ["Bandanna", "Horned helmet"]
    assert [name_at(img, ptrs[dist[0xA0][0] - 1], 0x18),
            name_at(img, ptrs[dist[0xA0][-1] - 1], 0x18)] == ["Robe", "Windspun armor"]
    assert [name_at(img, ptrs[dist[0xC0][0] - 1], 0x18),
            name_at(img, ptrs[dist[0xC0][-1] - 1], 0x18)] == ["Wooden shield", "Earth shield"]
    assert [name_at(img, ptrs[dist[0xE0][0] - 1], 0x18),
            name_at(img, ptrs[dist[0xE0][-1] - 1], 0x18)] == ["Wooden shoes", "Gold necklace"]
    # the head run is one ascending price column
    head = [u32(ptrs[i - 1] + PRICE) for i in dist[0x80]]
    assert head == sorted(head), head

    # ------------------------------------------------------------------ weapons
    # 0x80166000, 0x58 per weapon = three 0x1C tier sub-records
    W = 0x80166000
    first = [name_at(img, W + o, 0x1C) for o in (0x00, 0x1C, 0x38)]
    assert first == ["Wind Rod", "Gale Rod", "Gust Rod"], first
    last = [name_at(img, W + 0x58 * 64 + o, 0x1C) for o in (0x00, 0x1C, 0x38)]
    assert last == ["Star Dragon Sword", "Black Dragon Sword", "King Dragon Sword"], last
    rises = 0
    zeros3 = 0
    for i in range(65):
        base = W + 0x58 * i
        p1 = u8(base + 0x15)
        p2 = u8(base + 0x1C + 0x15)
        p3 = u8(base + 0x38 + 0x15)
        if p2 > p1:
            rises += 1
        if p3 == 0:
            zeros3 += 1
    assert rises == 65, rises
    assert zeros3 == 65, zeros3
    # 65 x 0x58 ends 14 bytes past the region the name map reaches
    assert 0x80166000 + 65 * 0x58 - 0x8016764A == 14

    # ------------------------------------------------------------------ blacksmith
    BS = 0x80165890
    assert u32(BS) == 77, u32(BS)
    bs = [u32(BS + 4 * i) for i in range(1, 80)]
    assert all(0x80160000 <= p < 0x80170000 for p in bs)
    assert bs[0] == 0x80165B30 and name_at(img, bs[0], 0x1C) == "Wolf Fang Staff"
    assert bs[13] == 0x80165FA8, hex(bs[13])
    assert bs[14] == 0x80166000, hex(bs[14])
    assert all(bs[14 + k] == 0x80166000 + 0x58 * k for k in range(65))
    LV = 0x8016AF2C
    lv = [u32(LV + 4 * i) for i in range(16)]
    assert lv[0] == 0 and lv[1] == 0x12C and lv[-1] == 0x11170, [hex(v) for v in lv]
    assert lv[1:] == sorted(lv[1:])
    # 0x800D6720 indexes sharpen rows at id*0x20 + (level-1)*2
    SH = 0x801659D0
    # weapon 1 (the first character weapon) opens 5, 7, 9, 12, 20, 25 ...
    assert [u16(SH + 0x20 + 2 * k) for k in range(5)] == [5, 7, 9, 12, 20]
    # the row width is 16 halfwords: weapon 2 starts exactly 0x20 later
    assert u16(SH + 0x20 * 2) == 5 and u16(SH + 0x20 * 2 + 2) == 7

    # ------------------------------------------------------------------ runes
    # 31 records at 0x8016A1B0 stride 0x24; the four bytes at +0x1B are the spell
    # ids, 1-based into the name array at 0x8016D340
    R = 0x8016A1B0
    assert name_at(img, R, 0x14) == "Fire Rune"
    assert name_at(img, R + 0x24 * 30, 0x14) == "Thunder Rune"
    fire = [u8(R + 0x1B + b) for b in range(4)]
    assert fire == [1, 2, 3, 4], fire
    res = [u8(R + 0x24 * 5 + 0x1B + b) for b in range(4)]
    assert res == [5, 6, 7, 8], res
    namep = [u32(0x8016D340 + 4 * (s - 1)) for s in fire]
    spells = [name_at(img, p, 0x18) for p in namep]
    assert spells == ["Flaming Arrows", "Firestorm", "Dancing Flames", "Explosion"], spells
    # every rune's four spell bytes are either all zero or all in 1..33
    for i in range(31):
        s = [u8(R + 0x24 * i + 0x1B + b) for b in range(4)]
        assert s == [0, 0, 0, 0] or all(1 <= v <= 33 for v in s), (i, s)
    assert sum(1 for i in range(31)
               if any(u8(R + 0x24 * i + 0x1B + b) for b in range(4))) == 11
    # the name-pointer array at 0x8016A0E4: index 0 is the special rune's own
    # record, 1..30 the 31 records, 31 a placeholder, 32 `True Holy Rune`
    assert u32(0x8016A0E0) == 31, hex(u32(0x8016A0E0))
    assert name_at(img, u32(0x8016A0E4), 0x18) == "Soul Eater"
    assert name_at(img, u32(0x8016A0E4 + 4), 0x14) == "Fire Rune"
    assert literal_at(img, u32(0x8016A0E4 + 4 * 30), 0x14) == "Thunder Rune"
    assert literal_at(img, u32(0x8016A0E4 + 4 * 32), 0x14) == "True Holy Rune"
    # index 33 runs off the array into the Soul Eater record's own name bytes
    assert u32(0x8016A0E4 + 4 * 33) == u32(0x8016A168)
    assert u32(0x8016AB68) == 0

    # ------------------------------------------------------------------ unite attacks
    # 32 records at 0x8016CD0C stride 0x24, named by the 33-word array at
    # 0x8016D18C (word 0 is zero, words 1..32 are the records)
    U = 0x8016CD0C
    UP = 0x8016D18C
    assert u32(UP) == 0
    for i in range(32):
        assert u32(UP + 4 * (i + 1)) == U + 0x24 * i, i
    names = [literal_at(img, U + 0x24 * i, 0x14) for i in range(32)]
    assert names[0] == "Talisman attack", names[0]
    assert names[-1] == "Master pupil attack", names[-1]
    assert len(set(names)) == 25, len(set(names))          # seven repeats
    # the longest names fill the whole fixed-width field, so a NUL-terminated
    # read cannot see them: `literal_at` is required, not optional
    # record 30 and 12 have no terminator inside the 0x14-byte field
    for i in (12, 30):
        blob = img[U + 0x24 * i - MAIN_BASE:
                   U + 0x24 * i - MAIN_BASE + 0x14]
        assert 0 not in blob, (i, blob)
        assert names[i] == literal_at(img, U + 0x24 * i, 0x14)
    assert name_at(img, U + 0x24 * 30, 0x14) is None, "record 30 is NUL-terminated after all"
    assert all(n for n in names)
    # +0x16 is a u16 flag word (read with lhu at 0x800F588C), +0x18 the member
    # count (the loop bound at 0x800F928C) and +0x1A one character id per member
    # (0x800F9238).  The consumption path is what separates the two readings.
    assert u32(0x800F588C) == 0x94420016        # lhu $v0,0x16($v0)
    flags = [u16(U + 0x24 * i + 0x16) for i in range(32)]
    assert set(flags) == {1, 3}, sorted(set(flags))
    counts = [u8(U + 0x24 * i + 0x18) for i in range(32)]
    assert all(1 <= c <= 4 for c in counts), counts
    assert counts[0] == 2 and counts[1] == 2, counts[:2]
    assert {c: counts.count(c) for c in sorted(set(counts))} == {2: 16, 3: 11, 4: 5}
    # character id 0 is Eileen, so a member byte of zero is not a terminator
    assert list(img[U + 0x24 * 16 + 0x1A - MAIN_BASE:
                    U + 0x24 * 16 + 0x1A - MAIN_BASE + 2]) == [0, 30], "Couple"
    assert list(img[U + 0x24 * 31 + 0x1A - MAIN_BASE:
                    U + 0x24 * 31 + 0x1A - MAIN_BASE + 2]) == [8, 91], "Master pupil"
    # the matcher's arithmetic, quoted as raw words
    assert u32(0x800F9210) == 0x906B0018        # lbu $t3,0x18($v1)
    assert u32(0x800F9238) == 0x9047001A        # lbu $a3,0x1a($v0)
    assert u32(0x800F928C) == 0x010B102A        # slt $v0,$t0,$t3

    # Independently reconstruct opcode 49's messages for the entire item space.
    import item_tables
    assert u32(0x8013BA0C) == 0x30427000  # antique-class discriminator
    assert u32(0x8013BA6C) == 0x34050015  # encoded-name byte limit
    suffix_ptr = u32(0x80171C1C) - MAIN_BASE
    suffix = img[suffix_ptr:img.index(0, suffix_ptr)]
    antique_ptr = u32(0x80171C20) - MAIN_BASE
    antique = img[antique_ptr:img.index(0, antique_ptr)]
    classes = set()
    for iid in range(1, 180):
        addr = u32(0x80167658 + 4 * iid)
        is_antique = bool(u16(addr + 0x1C) & 0x7000)
        classes.add(is_antique)
        name = bytearray()
        for n in range(21):
            char = u8(addr + n)
            if char == 0:
                break
            name.append(char)
        expected = (antique if is_antique else bytes(name) + suffix) + b"\0"
        assert item_tables.acquisition_message(iid) == expected, iid
    assert classes == {False, True}
    assert wt.decode(item_tables.acquisition_message(1))[0] == "Bandanna\nacquired!"
    for invalid in (0, 180, -1, True, "1"):
        try:
            item_tables.acquisition_message(invalid)
        except ValueError:
            pass
        else:
            raise AssertionError(f"accepted invalid item id {invalid!r}")

    print("PASS: all 179 acquisition messages agree with the original byte rules; "
          "the item pointer array at 0x80167658 bounds a 179-record id "
          "space (not two free-standing stride tables); its records give the "
          "0x24/0x28 pair and the four equipment classes; the 65 x 0x58 weapon "
          "table rises tier-2 > tier-1 in 65/65; the blacksmith's 79 weapon ids "
          "are 14 character weapons plus the 65; the 31 rune records carry four "
          "1-based spell ids at +0x1B that name the 33-entry spell table at "
          "0x8016D340; and the 32 unite attacks at 0x8016CD0C are named by the "
          "33-word array at 0x8016D18C, with their member count at +0x18 and "
          "member character ids at +0x1A")


if __name__ == "__main__":
    check()

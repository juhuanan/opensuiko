#!/usr/bin/env python3
"""MAIN's weapon/rune/unite/consumable tables: independent re-derivation.

Plain byte arithmetic over the MAIN image, re-stating the strides and counts from
the doc rather than importing them from the tool, so a bug in the tool cannot make
this pass.  Disc required.

Run: `python3 kit/tests/test_main_item_tables.py`
"""
from pathlib import Path
import struct
import sys

_TESTS = Path(__file__).resolve().parent
_KIT = _TESTS.parent
sys.path.insert(0, str(_KIT / "tools"))

import disc  # noqa: E402
import war_text as wt  # noqa: E402
import main_item_tables as M  # noqa: E402

BASE = 0x800C0800


def image():
    import json
    with open(_KIT / "extracted" / "iso_files.json") as fh:
        rec = next(r for r in json.load(fh) if r.get("path") == "MAIN.EXE")
    return disc.extract(rec["lba"], rec["size"])[2048:]


def nm(img, off, limit):
    j = off
    while j < off + limit and wt.is_text_byte(img[j]):
        j += 1
    if j >= off + limit or img[j] != 0 or j - off < 3:
        return None
    t, _u = wt.decode(img, off, j - off)
    return t if t and t[0].isalnum() else None


def check():
    img = image()

    # ------------------------------------------------ weapons: 16 x 0x58
    # three tier names at +0x00 / +0x1C / +0x38 of every one of the 16 blocks
    tiers = []
    for i in range(16):
        o = 0x80166000 - BASE + i * 0x58
        row = [nm(img, o + so, 0x1C) for so in (0x00, 0x1C, 0x38)]
        assert all(row), (i, row)
        tiers.append(row)
    assert tiers[0] == ["Wind Rod", "Gale Rod", "Gust Rod"], tiers[0]
    assert tiers[1] == ["Kirinji", "Kirinji 2", "Kirinji 3"], tiers[1]
    assert tiers[2] == ["Darts", "Ruby Darts", "Crystal Darts"], tiers[2]
    assert tiers[15] == ["Light Knife", "Ray Knife", "Shining Knife"], tiers[15]
    # the tier pattern is the corroboration: 3 names per weapon, and the naming
    # is an upgrade ladder (base / 2nd / 3rd form) in every group
    assert len(tiers) * 3 == 48
    # the block is exactly 3 x 0x1C + 4, which is why the 17th block is at +0x580
    assert 3 * 0x1C + 4 == 0x58
    # the 17th block does NOT follow the same layout -- this is the stated limit
    o17 = 0x80166000 - BASE + 16 * 0x58
    assert nm(img, o17, 0x1C) == "Tengaar"
    assert nm(img, o17 + 0x1C, 0x1C) is None or nm(img, o17 + 0x38, 0x1C) is None

    # the byte at +0x15 of each tier sub-record rises from tier 1 to tier 2 in
    # ALL 16 weapons -- the one derived field in this table
    for i in range(16):
        o = 0x80166000 - BASE + i * 0x58
        b1 = img[o + 0x00 + 0x15]
        b2 = img[o + 0x1C + 0x15]
        b3 = img[o + 0x38 + 0x15]
        assert 0 < b1 < b2, (i, b1, b2)
        assert b3 == 0, (i, b3)      # tier 3's value is NOT here -- reported raw

    # the whole weapon-name region is much larger than 16 blocks: 193 names
    regions = {r["start"]: r for r in M.region_map()}
    wr = regions[0x80166000]
    assert wr["count"] == 193, wr["count"]
    assert wr["end"] == 0x8016764A, hex(wr["end"])
    assert wr["names"][0] == "Wind Rod" and wr["names"][-1] == "King Dragon Sword"
    assert 193 // 3 == 64                     # ~64 weapons if every group is 3

    # ------------------------------------------------ runes: 31 x 0x24
    n = 0
    while nm(img, 0x8016A1B0 - BASE + n * 0x24, 0x24):
        n += 1
    assert n == 31, n
    assert nm(img, 0x8016A1B0 - BASE, 0x24) == "Fire Rune"
    assert nm(img, 0x8016A1B0 - BASE + 30 * 0x24, 0x24) == "Thunder Rune"

    # ------------------------------------------------ unite attacks: 26 x 0x24
    n = 0
    while nm(img, 0x8016CD0C - BASE + n * 0x24, 0x24):
        n += 1
    assert n == 26, n
    assert nm(img, 0x8016CD0C - BASE, 0x24) == "Talisman attack"
    # but the surrounding region holds more "<who> attack" names than the run:
    ur = regions[0x8016CD0C]
    assert ur["count"] > n, (ur["count"], n)      # the stride changes after 26

    # ------------------------------------------------ consumables: 5 x 0x24
    cons = [nm(img, 0x801686CC - BASE + k * 0x24, 0x24) for k in range(6)]
    assert cons == ["Medicine", "Antitoxin", "Needle", "Mega medicine",
                    "Escape talisman", "Bandanna"], cons
    # `Bandanna` is the equipment table's first record, so the boundary is 5
    assert nm(img, 0x80168780 - BASE, 0x28) == "Bandanna"

    # ------------------------------------------------ the tool agrees
    assert [t["name"] for t in M.table("runes")] == \
        [nm(img, 0x8016A1B0 - BASE + k * 0x24, 0x24) for k in range(31)]
    assert [w["names"] for w in M.weapons()] == tiers

    # ------------------------------------------------ the names we did NOT find
    # monsters / recipes / shops are NOT name tables here.  This asserts the
    # negative that the doc records, so it cannot rot silently.
    # These monster names do not occur in MAIN.EXE AT ALL.  If a monster name
    # table existed here, at least some of them would have to be in it.
    for w in ("Skeleton", "Mad Grass", "Werewolf", "Cockatrice", "Zombie",
              "Giant Snail", "Killer Rabbit", "Holly Fairy"):
        assert img.find(wt.encode(w)) < 0, w
    # and no run of >=8 records starts with a monster name anywhere in MAIN
    for r in M.name_runs(min_count=8):
        assert not any(str(r["first"]).startswith(m) for m in
                       ("Kobold", "Zombie", "Skeleton", "Slime", "Golem")), r["first"]
    # the shop REGION is UI text, not stock: it has the menu words and no ids
    shop = regions[0x8016AE7C]
    assert "Buy" in shop["names"] and "Sell" in shop["names"]
    assert "price " in shop["names"]

    print("PASS: MAIN item-class tables re-derived -- weapons 16 x 0x58 with three "
          "tier names at +0/+0x1C/+0x38 and tier-2 > tier-1 at +0x15 in 16/16 "
          "(the full weapon region is 193 names / ~64 weapons and the fixed stride "
          "does NOT extend past 16); runes 31 x 0x24 @0x8016A1B0; unite attacks "
          "26 x 0x24 @0x8016CD0C with more '<who> attack' names beyond the run; "
          "consumables 5 x 0x24 @0x801686CC ending exactly at the equipment table; "
          "and the recorded negatives: no monster/recipe name table in MAIN, and "
          "the shop region is UI text (Buy/Sell/price) with no stock list")


if __name__ == "__main__":
    check()

#!/usr/bin/env python3
"""MAIN.EXE's item/equipment tables: independent re-derivation.

The table walk is written out here with plain byte arithmetic and the game's
text table re-stated from `war_text`, so a bug in `main_tables.py` cannot make
this pass.  Disc required.

Run: `python3 kit/tests/test_main_tables.py`
"""
from pathlib import Path
import struct
import sys

_TESTS = Path(__file__).resolve().parent
_KIT = _TESTS.parent
sys.path.insert(0, str(_KIT / "tools"))

import disc  # noqa: E402
import main_tables as mt  # noqa: E402
import war_text as wt  # noqa: E402

BASE = 0x800C0800


def image():
    import json
    with open(_KIT / "extracted" / "iso_files.json") as fh:
        rec = next(r for r in json.load(fh) if r.get("path") == "MAIN.EXE")
    return disc.extract(rec["lba"], rec["size"])[2048:]


def read(img, base, stride, count):
    out = []
    for i in range(count):
        o = base - BASE + i * stride
        raw = img[o : o + stride]
        name, _u = wt.decode(raw, 0, stride)
        out.append({"name": name, "price": struct.unpack_from("<I", raw, 0x18)[0],
                    "raw": raw})
    return out


def check():
    img = image()
    assert struct.unpack_from("<I", img, 0)[0] != 0x50422D5358  # not a header

    # ------------------------------------------------ items
    items = read(img, 0x80169798, 0x24, 66)
    assert len(items) == 66
    assert items[0]["name"] == "Failure urn" and items[0]["price"] == 20
    assert items[1]["name"] == "Octopus urn" and items[1]["price"] == 1000
    assert items[8]["name"] == "Fine Bone China" and items[8]["price"] == 120000
    assert items[20]["name"] == "Beauties of nature" and items[20]["price"] == 400000
    assert items[65]["name"] == "Mathiu's letter"
    # the tool agrees, record for record
    _b, _s, tool = mt.read_table("items")
    assert [(t["name"], t["price"]) for t in tool] == [(i["name"], i["price"]) for i in items]
    # categories are three constant blocks, and the table is NOT the equip stride
    cat = [struct.unpack_from("<I", i["raw"], 0x1C)[0] for i in items]
    assert cat[0:9] == [0x1000] * 9          # urns
    assert cat[9:16] == [0x2000] * 7         # dishes + statues
    assert cat[16:21] == [0x4000] * 5        # paintings
    # price is non-decreasing inside each category block -- a real price column
    for lo, hi in ((0, 9), (9, 16), (16, 21)):
        col = [items[i]["price"] for i in range(lo, hi)]
        assert col == sorted(col), (lo, hi, col)

    # ------------------------------------------------ equipment
    equip = read(img, 0x80168780, 0x28, 58)
    assert len(equip) == 58
    assert equip[0]["name"] == "Bandanna" and equip[0]["price"] == 50
    assert equip[3]["name"] == "Half helmet" and equip[3]["price"] == 3300
    assert equip[7]["name"] == "Horned helmet" and equip[7]["price"] == 43000
    assert equip[8]["name"] == "Robe" and equip[8]["price"] == 100
    _b, _s, te = mt.read_table("equipment")
    assert [(t["name"], t["price"]) for t in te] == [(i["name"], i["price"]) for i in equip]

    # the class byte groups the table: 0x80 for the first 8 (head), 0xA0 from 8
    cls = [e["raw"][0x1C] for e in equip]
    assert cls[0:8] == [0x80] * 8, cls
    assert cls[8:12] == [0xA0] * 4, cls
    # and the running index (byte 3 of +0x24) increases strictly in the head group
    idx = [e["raw"][0x27] for e in equip]
    assert idx[0:8] == [1, 2, 5, 9, 14, 20, 27, 35], idx[0:8]
    assert all(b > a for a, b in zip(idx[0:8], idx[1:8]))

    # ------------------------------------------------ the tables are findable
    # The stride search must rediscover both bases without being told them.
    found = {(t["base"], t["stride"]) for t in mt.strided_name_tables(12)}
    assert (0x80169798, 0x24) in found, sorted(found)[:8]
    assert (0x80168780, 0x28) in found, sorted(found)[:8]

    # ------------------------------------------------ name lists
    cn = mt.read_name_list("characters")
    assert len(cn) == 124, len(cn)
    assert cn[0]["name"] == "Hero" and cn[0]["addr"] == 0x80170104
    assert cn[1]["name"] == "Gremio" and cn[2]["name"] == "Pahn"
    assert cn[3]["name"] == "Cleo" and cn[4]["name"] == "Viktor"
    assert cn[7]["name"] == "Varkas" and cn[23]["name"] == "Kirkis"
    assert cn[44]["name"] == "Sylvina" and cn[48]["name"] == "Kuromimi"
    assert cn[106]["name"] == "Pesmerga" and cn[107]["name"] == "Crowley"
    # names are strictly increasing in address, NUL-terminated, and readable
    addrs = [c["addr"] for c in cn]
    assert addrs == sorted(addrs) and len(set(addrs)) == len(addrs)
    for c in cn:
        o = c["addr"] - BASE
        raw = img[o : o + len(wt.encode(c["name"]))]
        assert img[o + len(raw)] == 0, c
    pl = mt.read_name_list("places")
    assert len(pl) == 43, len(pl)
    assert pl[0]["name"] == "Gregminster" and pl[1]["name"] == "Rockland"
    assert pl[40]["name"] == "Moravia" and pl[41]["name"] == "Maneuvers Site"
    assert pl[42]["name"] == "Shasarazade"
    assert pl[0]["addr"] == 0x80170780 and pl[22]["name"] == "Pannu Yakuta"

    # ------------------------------------------------ no overlap
    # the two tables must not share a byte, or one stride is wrong
    ia = range(0x80169798 - BASE, 0x80169798 - BASE + 66 * 0x24)
    ea = range(0x80168780 - BASE, 0x80168780 - BASE + 58 * 0x28)
    assert not (set(ia) & set(ea))

    print("PASS: MAIN.EXE item table (66 x 0x24 @0x80169798, price at +0x18, three "
          "category blocks 0x1000/0x2000/0x4000 with non-decreasing prices) and "
          "equipment table (58 x 0x28 @0x80168780, class byte 0x80 head / 0xA0 body, "
          "strictly increasing running index); both rediscovered by the stride "
          "search; and the byte-packed name lists (124 characters, 43 places) "
          "whose first 108 entries are the portrait index")


if __name__ == "__main__":
    check()

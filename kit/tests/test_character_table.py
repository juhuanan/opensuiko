#!/usr/bin/env python3
"""The 78-record character stat template: independent re-derivation.

Everything here is plain byte arithmetic over `SLUS_002.92`'s image, including a
fresh search for the table, so a bug in `character_table.py` cannot make this
pass.  Disc required.

Run: `python3 kit/tests/test_character_table.py`
"""
from pathlib import Path
import struct
import sys

_TESTS = Path(__file__).resolve().parent
_KIT = _TESTS.parent
sys.path.insert(0, str(_KIT / "tools"))

import disc  # noqa: E402
import character_table as ct  # noqa: E402
import face_portraits as fp  # noqa: E402

EXE = "SLUS_002.92"
STRIDE = 0x50
#: the roster id sequence `game_state_struct.md` recorded from save files
ID_SEQ = [8, 2, 6, 1, 108, 35, 109, 3, 32, 14, 4, 36]


def image():
    import json
    with open(_KIT / "extracted" / "iso_files.json") as fh:
        rec = next(r for r in json.load(fh) if r.get("path") == EXE)
    return disc.extract(rec["lba"], rec["size"])[2048:]


def check():
    img = image()

    # ------------------------------------------------ the table, found afresh
    # search for the roster id sequence at the stride, with NO offset supplied
    hits = []
    for a in range(0, len(img) - STRIDE * len(ID_SEQ)):
        if all(img[a + STRIDE * k] == v and img[a + STRIDE * k + 1] == 0
               and img[a + STRIDE * k + 2] == 0 and img[a + STRIDE * k + 3] == 0
               for k, v in enumerate(ID_SEQ)):
            hits.append(a)
    assert len(hits) >= 1, "the roster id sequence must locate the table"
    off = hits[0]
    assert off == ct.IMAGE_OFF == 0x33274, (hex(off), hex(ct.IMAGE_OFF))

    # ------------------------------------------------ ids and the cross-check
    ids = [struct.unpack_from("<I", img, off + i * STRIDE)[0] for i in range(78)]
    assert ids[:12] == ID_SEQ, ids[:12]
    assert len(set(ids)) == 78, "ids must be distinct"

    # the 78 ids are EXACTLY the 04_PLAY one-byte id set -- two independent
    # extractions of the same space, which is what anchors both
    sprite = fp.sprite_names()
    assert set(ids) == set(sprite), (
        sorted(set(ids) - set(sprite)), sorted(set(sprite) - set(ids)))

    # every record is named from its own sprite file's header
    recs = ct.records()
    assert len(recs) == 78
    for r in recs:
        assert r["name"], r
        assert r["name"] == sprite[r["id"]][0]
    assert ct.by_id()[8]["name"] == "Hero"
    assert ct.by_id()[35]["name"] == "Viktor"
    assert ct.by_id()[1]["name"] == "Cleo"

    # ------------------------------------------------ the fields that are proven
    for r in recs:
        raw = img[r["off"] : r["off"] + STRIDE]
        # +0x04 == +0x06 in every record, and the range is 13..35
        assert struct.unpack_from("<H", raw, 4)[0] == struct.unpack_from("<H", raw, 6)[0]
        assert 13 <= struct.unpack_from("<H", raw, 4)[0] <= 35
        # +0x08, +0x0A, +0x40..+0x43 are zero
        assert struct.unpack_from("<H", raw, 8)[0] == 0
        assert struct.unpack_from("<H", raw, 0x0A)[0] == 0
        assert raw[0x40:0x44] == b"\0" * 4
        # +0x0C is the constant 0x0100
        assert struct.unpack_from("<H", raw, 0x0C)[0] == 0x0100
        # Six stats, a zero initial status word, six growth bytes, then1E/count.
        assert raw[0x16:0x18] == b"\0\0"
        assert max(raw[0x10:0x16]) <= 30
        assert max(raw[0x18:0x20]) <= 13      # block B is all 8 bytes, no pad
    assert all(r["level"]==1 and r["spell_charges"]==[0]*4 for r in recs)

    # Decode every field independently from the newly searched source address.
    for i,row in enumerate(recs):
        raw=img[off+80*i:off+80*(i+1)]
        assert (row['hp_max'],row['hp_current'])==struct.unpack_from('<HH',raw,4)
        assert row['spell_index0']==raw[8] and row['spell_charges']==list(raw[9:13])
        assert row['level']==raw[13] and row['experience']==int.from_bytes(raw[14:16],'little')
        assert row['stats']==list(raw[16:22]) and row['status']==raw[22] and row['opaque_17']==raw[23]
        assert row['growth']==list(raw[24:30]) and row['opaque_1e']==raw[30]
        assert row['inventory_count']==raw[31]<=9 and len(row['inventory'])==9
        rebuilt=b''.join(struct.pack('<HBB',item['id'],item['slot_flags'],item['uses']) for item in row['inventory'])
        assert rebuilt==raw[32:68]
        assert [row[k] for k in ['weapon_id','weapon_level','element_type']]==list(raw[68:71])
        assert row['element_coefficients']==list(raw[71:76])
        assert [row['rune_id'],row['rune_locked']]==list(raw[76:78])
        assert row['opaque_tail']==list(raw[78:80])
    hero=ct.by_id()[8]
    assert hero['inventory_count']==5
    assert [(x['id'],x['slot_flags'],x['uses']) for x in hero['inventory'][:5]]==[(1,1,0),(10,2,0),(32,4,0),(28,5,0),(25,0,6)]
    assert ct.by_id()[6]['rune_id']==8 and ct.by_id()[6]['rune_locked']==1

    # ------------------------------------------------ the two index spaces
    # The table is keyed by CHARACTER ID (the 04_PLAY space), NOT by the portrait
    # index.  Bridging is by unique name only, and must not be done by arithmetic.
    assert ct.portrait_index(8) == 0          # id 8  Hero   -> portrait 0
    assert ct.portrait_index(35) == 4         # id 35 Viktor -> portrait 4
    assert ct.portrait_index(1) == 3          # id 1  Cleo   -> portrait 3
    # and the two spaces genuinely differ: the list index 8 is not the id-8 name
    chars = fp.character_names()
    assert chars[8] == "Sydonia" and ct.by_id()[8]["name"] == "Hero"
    assert chars[35] == "Milia" and ct.by_id()[35]["name"] == "Viktor"
    # a missing or ambiguous name yields None rather than a guess
    assert ct.portrait_index(9999) is None

    # ------------------------------------------------ the ids are not the rows
    # the table is ordered by roster, not by id: row 0 is id 8
    assert ids[0] == 8 and ids != sorted(ids)

    print("PASS: SLUS_002.92 image 0x33274 = 78 x 0x50 character stat template, "
          "relocated by searching for the roster id sequence; ids == the 78 "
          "04_PLAY ids exactly; +0x04==+0x06 in 78/78 with range 13..35; "
          "four spell tiers09..0C, level0D, nine inventory slots20..43 and all scalar fields agree with fresh source bytes; keyed by CHARACTER ID "
          "with the portrait index bridged by unique name (8 Hero->0, 35 Viktor->4)")


if __name__ == "__main__":
    check()

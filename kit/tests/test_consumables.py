#!/usr/bin/env python3
"""Static checks of the basic item descriptors, field handlers and shop sales."""
from hashlib import sha256
from itertools import product
import json
from pathlib import Path
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
import maindec as main
import export_shop
from mipsdec import sx16
from test_canonical_start import assert_main_words

FIXTURE = ROOT / 'game/tests/fixtures/consumables.json'
ITEMS = [('medicine', 25, 0x800D0B74, 0x800F0708, 100, 6),
         ('mega_medicine', 72, 0x800D0CD8, 0x800F07AC, 500, 3),
         ('antitoxin', 26, 0x800D0C08, 0x800F0850, 0, 4),
         ('needle', 71, 0x800D0C60, 0x800F0920, 0, 4)]


def check_field_sources():
    # Pin the checked HP/condition branches, positive result use decrement,
    # and removal/compaction path, including the instructions between anchors.
    for start, end, digest in (
        (0x800CC164, 0x800CC288, '9c50ce4d9f8787f0cafeeb149a0395e74e5e5a040393230d5caff2464add077d'),
        (0x800D0B74, 0x800D0C08, '46a2aa2a90cc464b2d384bd2c2ce6864f4a5ca0ed7aa2ca50d6ecf4e8d745be1'),
        (0x800D0C08, 0x800D0C60, '7aedd5a3b028a7d3d1a6b7fdb337404b199e37f7ab5aa07c7a7b76fba0c0ac77'),
        (0x800D0C60, 0x800D0CD8, '401fccee61bccd80bc1788232dc14a3b82326c449e5de6b17a4bcacf0753c108'),
        (0x800D0CD8, 0x800D0D60, 'fa9fc968a22a4028d940ea0ea239b80e8adc0be93aa0a102e82def1a7fa2ba9b'),
        (0x800CA408, 0x800CA50C, '80b0dc579003fc770c4cd42ab54bb34c63f3575c8be8177e428e143810a73f56'),
    ):
        assert sha256(main.body()[start-main.MBASE:end-main.MBASE]).hexdigest() == digest, hex(start)

    heals = {'medicine': sx16(main.mword(0x800D0BB0)), 'mega_medicine': sx16(main.mword(0x800D0D10))}
    poison = main.mword(0x800D0C2C) & 0xFFFF
    # The two priority branches test a bit; the final branch only clears it.
    balloon_order = (main.mword(0x800D0C8C) & 0xFFFF, main.mword(0x800D0C98) & 0xFFFF,
                     ~main.mword(0x800D0CAC) & 0xFFFF)
    return heals, poison, balloon_order


def field_vectors():
    heals, poison, balloons = check_field_sources()
    balloon_mask = sum(balloons)
    rows = []
    for (item, _, _, _, _, _), hp, status, uses in product(ITEMS, (35, 700), range(16), (1, 2)):
        status |= 0x40  # Unrelated recovery bit.
        if item == 'antitoxin':
            cleared = poison
        elif item == 'needle':
            cleared = next((bit for bit in balloons if status & bit), 0)
        else:
            cleared = 0
        after = status & ~cleared
        hp_after = min(hp + heals.get(item, 0), 700)
        changed = hp_after != hp or after != status
        rows.append(dict(id=item, hp_before=hp, max_hp=700,
                         status_before='poisoned' if status & poison else 'healthy',
                         balloons_before=(status & balloon_mask).bit_count(), uses_before=uses,
                         hp_after=hp_after, status_after='poisoned' if after & poison else 'healthy',
                         balloons_after=(after & balloon_mask).bit_count(),
                         uses_after=uses - int(changed), changed=changed))
    # More than one source bit pattern can describe the same balloon count.
    return list({tuple(row.values()): row for row in rows}.values())


class ConsumablesTests(unittest.TestCase):
    def test_descriptors_independent_of_exporter(self):
        catalog = {row['id']: row for row in export_shop.consumables()[0]}
        prices = dict(medicine=100, mega_medicine=500, antitoxin=200, needle=200)
        kinds = dict(medicine=1, mega_medicine=4, antitoxin=2, needle=3)
        for item, number, handler, callback, heal, uses in ITEMS:
            pointer = main.mword(0x80167658 + number * 4)
            fields = struct.unpack_from('<IHBBI', main.body(), pointer-main.MBASE + 24)
            self.assertEqual(fields, (prices[item], 14, uses, kinds[item], callback))
            self.assertEqual((catalog[item]['price'], catalog[item]['uses'], catalog[item]['heal_hp']),
                             (prices[item], uses, heal))
            self.assertEqual(main.mword(0x80167928 + fields[3] * 4), handler)

    def test_field_effects_and_consumption_from_source(self):
        self.assertEqual(check_field_sources(), ({'medicine': 100, 'mega_medicine': 500}, 1, (8, 4, 2)))
        self.assertEqual(field_vectors(), json.loads(FIXTURE.read_text()))

    def test_battle_callbacks_and_cure_eligibility(self):
        assert_main_words({
            # Healers skip both launches without action flag 8.
            0x800F075C: (0x30420008, 0x14400003, 0x02002021, 0x0803C1E6, 0x2402FFFF),
            0x800F0800: (0x30420008, 0x14400003, 0x02002021, 0x0803C20F, 0x2402FFFF),
            # Cures also read the selected target's status and require their effect bit.
            0x800F08A8: (0x30420008, 0x10400016),
            0x800F0978: (0x30420008, 0x10400016),
            0x800F08C8: (0x9442004A, 0, 0x30420001, 0x1040000A, 0x02002021),
            0x800F0998: (0x9442004A, 0, 0x3042000E, 0x1040000A, 0x02002021),
        })
        for user_call, target, effect in (
            (0x800F0778, 0x8016C2F0, 9), (0x800F081C, 0x8016C314, 9),
            (0x800F08E4, 0x8016C390, 11), (0x800F09B4, 0x8016C3B8, 12),
        ):
            # Launch the shared user script on the actor, then the item script on the target.
            assert_main_words({user_call - 8: (
                0x3C068017, 0x24C6C1C0, 0x0C038E08, 0x02002821, 0x02202021,
                0x3C068017, 0x24C60000 | (target & 0xFFFF), 0x0C038E08, 0x02002821,
            )})
            script = struct.unpack_from('<20H', main.body(), target-main.MBASE)
            at = script.index(35)
            self.assertEqual(script[at:at + 3], (35, 0, effect))

    def test_battle_healing_amounts(self):
        assert_main_words({
            0x800F21C4: (0x96030042, 0x0040A021, 0x34020001, 0x10620012, 0x34020008,
                         0x28620002, 0x10400005, 0, 0x10600008, 0x34020004),
            0x800F2214: (0x0803C88F, 0x2402FF9C),
            0x800F2228: (0x0803C88F, 0x2402FE0C),
            0x800F223C: (0xAE820164,),
        })

    def test_sale_requires_full_bundle_and_pays_half_base_price(self):
        # Caller refuses before the commit path when the quote is zero.
        assert_main_words({
            0x800D3BA0: (0x0C035552, 0x00469821, 0x10400014, 0x00101080),
            0x800D5574: (0x8CA40018, 0x94A7001C, 0x000417C2, 0x00822021, 0x30E20080,
                         0x14400006, 0x00042043, 0x80C30023, 0x90A2001E, 0, 0x14620008),
            0x800D55C0: (0x00002021, 0x03E00008, 0x00801021),
            0x800D3BCC: (0x30427000, 0x14400006, 0, 0x82620002, 0, 0x30420080, 0x14400005,
                         0, 0x8C620018, 0, 0x1440000D),
            0x800D4034: (0x8C650048, 0x8C82001C, 0x00051880, 0x00431021, 0x94500020,
                         0x0C032902, 0x00108080),
            0x800D40A8: (0x8C420018, 0x8CA6004C, 0x00021FC2, 0x00431021, 0x8CA30050,
                         0x00021043, 0xACA60008, 0x00431021, 0xACA20050),
        })
        check_field_sources()  # The same remove-and-compact helper serves sale and depletion.


if __name__ == '__main__':
    if '--write-fixture' in sys.argv:
        vectors = field_vectors()
        FIXTURE.write_text(json.dumps(vectors, indent=2) + '\n')
        print(f'Wrote {len(vectors)} source-checked semantic item vectors')
    else:
        unittest.main()

#!/usr/bin/env python3
"""Static callback operand and consumer checks for expanded magic."""
from pathlib import Path
import hashlib
import struct
import sys
import unittest
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'kit/tools'))
import journey_magic
import maindec as main
from mipsdec import jtarget
from test_entity_predicates import assert_words

# Effect call sites, distinct from export's semantic rule table.
CALLS=[(1,0x800FF160,0,100),(2,0x800FFCA8,0,150),(3,0x80100BC8,0,400),
       (4,0x80101AB0,0,700),(14,0x80109978,4,400),(16,0x8010ACD0,4,500),
       (17,0x8010C6D4,3,150),(18,0x8010D3B4,3,100),(19,0x8010E050,3,600),
       (20,0x8010EF30,3,1000),(22,0x80113488,2,300),(24,0x80111CD4,2,700)]

class MagicExpansionTests(unittest.TestCase):
    def assert_span(self, start, end, digest):
        image = main.body()
        self.assertEqual(hashlib.sha256(image[start - main.MBASE:end - main.MBASE]).hexdigest(), digest)

    def test_inline_actor_operands_do_not_hide_the_later_recovery_command(self):
        import journey_battle
        data = bytearray(100)
        struct.pack_into('<I', data, 32, 40)
        struct.pack_into('<I', data, 40, 64)
        struct.pack_into('<9H', data, 64, 42, 3, 0, 1, 4, 40, 7, 100, 0)
        self.assertEqual(journey_battle.script(data, 0),
                         [(42, (3, 0, 1, 4)), (40, (7, 100)), (0, ())])
        struct.pack_into('<h', data, 66, -1)
        with self.assertRaises(ValueError): journey_battle.script(data, 0)

    def test_export_includes_every_complete_source_rule_and_preserves_existing_indices(self):
        import json
        import spell_rules
        systems = json.loads((ROOT/'game/tests/fixtures/journey_battle.json').read_text())['systems']
        before = [spell['id'] for spell in systems['spells']]
        journey_magic.export(systems)
        self.assertEqual([spell['id'] for spell in systems['spells']], before)
        _, rules = spell_rules.build()
        self.assertEqual(len(systems['spells']), 33)
        by_id = {spell['id']: spell for spell in systems['spells']}
        for rule in rules['spells']:
            if rule['status'] != 'supported':
                self.assertNotIn(rule['id'], by_id)
                continue
            spell = by_id[rule['id']]
            self.assertEqual(spell['name'], rule['name'])
            self.assertEqual(spell['allies'], rule['target_side'] == 'ally')
            self.assertEqual(spell['group'], rule['selection'] != 'single')
            self.assertEqual(spell['field_use'], rule['field_use'])
        rune_ids = [rune['id'] for rune in systems['runes']]
        proof = journey_magic.bind_story_rune(systems)
        journey_magic.bind_story_rune(systems)
        self.assertEqual([rune['id'] for rune in systems['runes']], rune_ids + ['soul_eater'])
        rune = systems['runes'][-1]
        self.assertEqual(rune['allowed_members'], ['hero'])
        self.assertEqual([systems['spells'][index]['id'] for index in rune['spells']],
                         ['spell_25', 'spell_26', 'spell_27', 'spell_28'])
        self.assertEqual(proof['offset'], main.EXE_HEADER + 0x8016A168 - main.MBASE)

    def test_general_cure_removes_accuracy_and_rune_block_without_recovery_or_protection(self):
        self.assert_span(0x801204EC, 0x8012055C, 'ec24462758e14c310cb1e433dab9bb635fa2e5d4f1b81990198bc69e74371e45')
        self.assert_span(0x800E0778, 0x800E0824, '2ece867e7b84a30a81e291e5e05b8d30891e40341716d30ce2ef669165bc8303')
        calls = [main.mword(pc + 4) for pc in range(0x801204EC, 0x8012055C, 4)
                 if main.mword(pc) == 0x0C0381DE]
        self.assertEqual(calls, [0x34050000 | status for status in range(6, 0, -1)] + [0x00002821])
        assert_words({
            # A resident effect gets a clear request, and its class mask is cleared.
            0x800E07C0: (0x8C6230A0, 0, 0x14400003, 0x34020001, 0x08038207, 0x00001021, 0xAC6230A8),
            0x800E0810: (0x00042027, 0x00A42824, 0xA465004A),
        })
        masks = struct.unpack_from('<9H', main.body(), 0x8016BAA8 - main.MBASE)
        self.assertEqual(masks, (1, 2, 4, 8, 16, 32, 128, 64, 32768))
        self.assertEqual(0x80FF & ~sum(masks[:len(calls)]), 0x8040)

    def test_actual_damage_callback_operands_and_all_element_coefficients(self):
        for native,pc,element,power in CALLS:
            # The callback stores the power as argument five and puts the element in a1.
            assert_words({pc: (0x34020000 | power, 0xAFA20010),
                          pc + 12: ((0x34050000 | element) if element else 0x00002821,)})
            call = main.mword(pc + 20)
            self.assertEqual((call >> 26, jtarget(pc + 20, call)), (3, 0x80125B28))
            self.assertEqual(journey_magic.DAMAGE[native],(journey_magic.ELEMENTS[element],power))
        self.assert_span(0x80125B28, 0x80125C94, 'e6f9d7fe36ede9ef681cfef158fda258378879f2ad34c970220f0a15026a5063')
        assert_words({
            # Add half MGC, then read the selected coefficient and use its branch.
            0x80125B84: (0x94630B6C,),
            0x80125B90: (0x00031842, 0x02238821),
            0x80125C10: (0x00541021, 0x90430020, 0x34020001, 0x1062000F),
            0x80125C2C: (0x1060FFEE,),
            0x80125C3C: (0x34020002, 0x10620008, 0x001117C2, 0x34020003, 0x10620008),
            0x80125C60: (0x00111040, 0x02228821, 0x0804971D, 0x00111043, 0x00001021),
        })

    def test_rain_kindness_group_loop_excludes_knockouts_and_cures(self):
        self.assert_span(0x80107B00, 0x80107B50, 'a22c3f49aee354cd40cef4b5435172cd8d5a41bf272378825b3a6d6f3b72a4cf')
        assert_words({
            # Iterate slots one through party count, stepping by 84 bytes. Skip inactive slots.
            0x8010766C: (0x8C57001C,),
            0x80107B00: (0x1AE00013, 0x34100001, 0x34110054),
            0x80107B1C: (0x90420B85, 0, 0x14400006, 0x26310054),
            0x80107B2C: (0x02002021, 0x0C038595, 0x2405FED4, 0x0C04813B, 0x02002021),
            0x80107B40: (0x26100001, 0x02F0102A, 0x1040FFF0),
        })

    def test_fog_and_clay_transform_the_additive_bonus_columns(self):
        self.assert_span(0x80106638, 0x80106678, 'b3bf6f1b018cefefa7fdd5e53284db970a14dcfea6d29dee0fd098c2cb119c98')
        assert_words({
            # Scale signed bonuses by 4/5 for Fog and 3/2 for Clay, truncating toward zero.
            0x80106638: (0x86420036, 0x34030005, 0x00021080, 0x0043001A),
            0x8010666C: (0x00001012, 0, 0xA6420036),
            0x801108B4: (0x84640042, 0, 0x00041040, 0x00441021, 0x000227C2, 0x00441021, 0x00021043, 0xA4620042),
            # Initialize all eight bonus columns to zero, then add them to working stats on refresh.
            0x800DE7A0: (0x00A01821, 0xA4600034, 0x24840001, 0x28820008, 0x1440FFFC, 0x24630002),
            0x800F7024: (0x94820024, 0x94830034, 0x24A50001, 0x00431021, 0xA4820024, 0x28A20008, 0x1440FFF9, 0x24840002),
        })

    def test_copper_flesh_blocks_hp_changes_and_expires_after_three_boundaries(self):
        self.assert_span(0x800E04DC, 0x800E0624, 'dadb7e712a2de33c185b3a2feaeea60bdc28aa6ca9a8ca128d68752b07c8f5b9')
        self.assert_span(0x800E1654, 0x800E16F8, '61ea502264f4bf4e7524b03093807ac2f494d9bb628d687c2a8d725ece791ae4')
        self.assertEqual(main.mword(0x800C11B4 + 4 * 8), 0x800E05DC)
        self.assertEqual(struct.unpack_from('<H', main.body(), 0x8016BAB8 - main.MBASE), (0x8000,))
        assert_words({
            0x800E05F4: (0x34020002, 0xA062004C),
            0x800E060C: (0x94250000, 0x9464004A, 0x2402FFFF, 0x00852025, 0x080381DA, 0xA464004A),
            # The incoming amount is replaced by zero regardless of sign when mask 8000 is set.
            0x800E1698: (0x00A08021,),
            0x800E16E0: (0x9462004A, 0, 0x30428000, 0x10400002, 0, 0x00008021),
            # Skip inactive protection. Remove on entry at zero, after two decrement-only boundaries.
            0x800F65B8: (0x9602004A, 0, 0x30428000, 0x1040000B, 0, 0x9202004C, 0,
                         0x14400003, 0x02202021, 0x0C0381DE, 0x34050008, 0x9202004C, 0, 0x2442FFFF, 0xA202004C),
        })

if __name__=='__main__':unittest.main()

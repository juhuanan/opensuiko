#!/usr/bin/env python3
"""Static stat-refresh and actor-selection checks with retained arithmetic vectors."""
import hashlib
import json
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
import battle_formulas as formulas
import maindec as main

FIXTURES = ROOT / 'game/tests/fixtures'


class BattleStatSource(unittest.TestCase):
    def pins(self, expected):
        for pc, word in expected.items():
            self.assertEqual(main.mword(pc), word, hex(pc))

    def span(self, start, end, digest):
        self.assertEqual(hashlib.sha256(main.body()[start-main.MBASE:end-main.MBASE]).hexdigest(), digest)

    def test_actor_and_persistent_record_layouts(self):
        layout = formulas.participant_layout()
        self.assertEqual(layout['slot_array']['stride'], 140)
        self.assertEqual(layout['battle_slot_array']['stride'], 84)
        self.assertEqual(layout['battle_slot_fields']['formation']['off'], 0x44)
        self.assertEqual(layout['battle_slot_fields']['flags']['off'], 0x4A)
        self.assertEqual(layout['battle_slot_fields']['counter']['owner'], 'actor_array_A')
        self.assertEqual(layout['char_record_array']['owner'], 'game_state')
        self.assertEqual(layout['char_record_fields']['level']['off'], 13)
        self.assertEqual(layout['char_record_fields']['stats_base']['off'], 16)
        self.assertEqual(layout['char_context_fields']['record_pointer']['off'], 28)

    def test_spawn_refresh_modifiers_and_physical_readers(self):
        self.span(0x800F6DA8, 0x800F7080, 'ae3285d7956c1d72785145f2db9f8731b3ef5af1b38f550e56b641b411fafe44')
        self.pins({
            # Spawn copies six halfwords into the battle record. The party branch calls its own helper.
            0x800DF0D0: 0x94A20014, 0x800DF0D4: 0x24A50002, 0x800DF0DC: 0xA4620014,
            0x800DF0E0: 0x28820006, 0x800DF0E4: 0x1440FFFA, 0x800DF0E8: 0x24630002,
            0x800F6EB4: 0x8C44001C, 0x800F6EB8: 0x0C0353B0, 0x800F6EBC: 0x26450024,
            # Refresh copies the six base columns, then seeds additional attack and defense columns.
            0x800F6F20: 0x94620014, 0x800F6F28: 0xA4620024, 0x800F6F2C: 0x28A20006,
            0x800F6F30: 0x1440FFFB, 0x800F6F34: 0x24630002, 0x800F6F38: 0x96020024,
            0x800F6F3C: 0x96030028, 0x800F6F44: 0xA6020030, 0x800F6F4C: 0xA6030032,
            # Eight unsigned halfword additions truncate on store. Combat uses the final pair.
            0x800F7024: 0x94820024, 0x800F7028: 0x94830034, 0x800F7030: 0x00431021,
            0x800F7034: 0xA4820024, 0x800F7038: 0x28A20008, 0x800F703C: 0x1440FFF9,
            0x800F7040: 0x24840002, 0x800F7050: 0x1040FFF2, 0x800F7054: 0x24C60054,
            0x800F7EF4: 0x94630030, 0x800F7EF8: 0x94420032,
        })

    def test_selector_operands_branches_and_store_scope(self):
        start, end = 0x800F4698, 0x800F4834
        self.span(start, end, 'f2580441ef41803cf928ce97ac67ce43d7cee5ee490cd464c2fd6d0bdae8ded0')
        self.pins({
            0x800F46C4: 0x8C620024, 0x800F46C8: 0x00009021, 0x800F46D4: 0x3415000A,
            0x800F46D8: 0x247400DC, 0x800F46DC: 0x24730B94, 0x800F46E0: 0x92630046,
            0x800F46E8: 0x1460003F, 0x800F46F0: 0x92820005, 0x800F46F8: 0x10400007,
            0x800F4708: 0x16400037, 0x800F4714: 0x2412FFFF, 0x800F4718: 0x1E400016,
            0x800F4724: 0x02209021, 0x800F4728: 0x0055001A, 0x800F4750: 0x00002010,
            0x800F4754: 0x9663002A, 0x800F475C: 0x00031080, 0x800F4760: 0x00431021,
            0x800F4764: 0x00021040, 0x800F4768: 0x2442FFFB, 0x800F4770: 0x0044B021,
            0x800F477C: 0x0055001A, 0x800F47A4: 0x00002010, 0x800F47A8: 0x9663002A,
            0x800F47B0: 0x00031080, 0x800F47B4: 0x00431021, 0x800F47B8: 0x00021040,
            0x800F47BC: 0x2442FFFB, 0x800F47C0: 0x00448021, 0x800F47C4: 0x02D0102A,
            0x800F47C8: 0x10400007, 0x800F47D8: 0x14400003, 0x800F47E0: 0x02209021,
            0x800F47F0: 0x2694008C, 0x800F47FC: 0x0051102A, 0x800F4800: 0x1040FFB7,
            0x800F4804: 0x26730054, 0x800F4808: 0x02401021,
        })
        calls = []
        for pc in range(start, end, 4):
            word = main.mword(pc)
            opcode = word >> 26
            if opcode in (40, 41, 42, 43, 46):
                self.assertEqual((word >> 21) & 31, 29, hex(pc))
            if opcode == 3:
                calls.append(((pc + 4) & 0xF0000000) | ((word & 0x3FFFFFF) << 2))
        self.assertEqual(calls, [0x80147E38, 0x80147E38, 0x800F8680])

    def test_retained_priority_vectors_agree_with_static_arithmetic(self):
        rows = json.loads((FIXTURES / 'world_order_picker.json').read_text())
        keys = {(tuple(row['speeds']), tuple(row['rolls']), row['acted'], row['locks']) for row in rows}
        self.assertEqual(len(rows), 576)
        self.assertEqual(len(keys), len(rows))
        for row in rows:
            unacted = 7 & ~row['acted']
            ready = [actor for actor in range(3) if unacted & ~row['locks'] & (1 << actor)]
            scores = [10 * row['speeds'][actor] - 5 + roll % 10 for actor, roll in zip(ready, row['rolls'])]
            if scores:
                choice = {'actor': ready[scores.index(max(scores))]}
            else:
                choice = {'no_ready': {}} if unacted else {'round_end': {}}
            self.assertEqual((row['choice'], row['draws']), (choice, len(ready)), row)

        speeds = json.loads((FIXTURES / 'battle_math.json').read_text())['speed']
        self.assertEqual(len(speeds), 4)
        for row in speeds:
            scores = [10 * speed - 5 + roll % 10 for speed, roll in zip(row['speeds'], row['rolls'], strict=True)]
            self.assertEqual(row['chosen'], scores.index(max(scores)), row)


if __name__ == '__main__':
    unittest.main()

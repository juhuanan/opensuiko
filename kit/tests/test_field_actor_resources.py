"""Actual VAA construction, retained descriptor identity and main sprite clocks."""
from pathlib import Path
import json
import sys
import unittest

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'kit/tools'))
import area_scene
import export_field_actor_resources as export
from export_first_room import source
from test_canonical_start import assert_main_words
from test_opening_events import assert_span


def original():
    for start, end, digest in (
        (0x8012ED84, 0x8012F3AC, '76d0eb0d2fe784020445c3ecb1f4747ec4934b43d22bab82fd9660fb322324dd'),
        (0x801346A8, 0x801347CC, '4a96a40443056e6059a3b13f5f3b719f06e8b655936b04a2ae95e91489f6441f'),
        (0x80134470, 0x801345DC, '617e176bc485950a55c12bf3009004715105f5e6ad1aa46a4dabf9f88c3fc315'),
        (0x8012EA40, 0x8012EB38, 'b4fe9b6f36baabb036e45936961d0717423ff10478b84241371c45a1ab235bda'),
        (0x8013CCF0, 0x8013CE08, 'ac42e3088a2ea4f08b1728552d84e08d460e96f4ca9c05f2f5461b46ca90cd64'),
        (0x800C3DAC, 0x800C3E9C, '99d24935552902ee742eb7012d3b6cc71145c7baaff87a6ea906ab14467e4b1c'),
        (0x800C3E9C, 0x800C3EF0, 'b5da084898012b31776ae3b131c61deff51eabb177140f794f0951f5084dbdcc'),
    ):
        assert_span(start, end, digest)
    assert_main_words({
        # Variant changes restart the retained object and run one clock update for frame zero.
        0x8013C7D0: (0x0C030F6B, 0x02002821),
        0x8013C7EC: (0x90830002, 0x34020001, 0x10620008, 0x34020003, 0x10620006, 0, 0x0C031091),
        # The stationary field pass emits first, then updates an active non-idle frame.
        0x8013077C: (0x0C04BE99, 0x02A02821),
        0x801308AC: (0x0C04BE88, 0x02002021, 0x14400007, 0x34020001, 0x92430002),
        0x80130900: (0x0C031091, 0x02402021),
        0x800C4268: (0x2442FFFF, 0xA0820003),
    })
    raw, _ = source('/VAA.BIN')
    room = area_scene.room_record(raw, 2)
    section = area_scene.section_off(raw, room['section'])
    bindings = area_scene.character_bindings(raw, section)

    def descriptor(character, variant):
        context = bindings[character]['context']
        table = area_scene.ptr_at(raw, context + 20)
        return area_scene.ptr_at(raw, table + 4 * variant)

    rows = []
    for flag in (0, 32, 64):
        initial = []
        transition = None
        for entity in area_scene.entities(raw, room):
            cursor = entity['stream_offsets'][0]
            if not entity['flags'] & 0x101 or cursor is None:
                continue
            if raw[cursor] != 6:
                assert raw[cursor:cursor + 2] == bytes((8, 0)) and raw[cursor + 3] == 6
                if flag & raw[cursor + 2]:
                    initial.append(dict(slot=255, attached=False, x=0, y=0, speed=0, flags=0,
                                        variant=None, frame=None, remaining=None))
                    continue
                cursor += 3
            variant = raw[cursor + 2] & 3
            clip = descriptor(entity['id'], variant)
            frame = int(raw[clip] > 1)
            row = dict(slot=len(initial), attached=True, x=entity['x_half'] * 8, y=entity['y_half'] * 8,
                       speed=(entity['flags'] >> 2) & 1, flags=(0, 1, 0, 2)[variant], variant=variant,
                       frame=frame, remaining=raw[clip + 5 + 2 * frame] or 256)
            initial.append(row)
            if entity['index'] == 22:
                assert row['slot'] == 12 and entity['id'] == 110
                clip = descriptor(entity['id'], 3)
                duration = raw[clip + 5] or 256
                assert raw[clip + 1] & 1 and duration > 2
                selected = dict(row, flags=row['flags'] | 2, variant=3, frame=0, remaining=duration - 1)
                transition = dict(selected=selected, emitted=selected, after=dict(selected, remaining=duration - 2))
        assert len(initial) == 14
        rows.append(dict(construction_flag=flag, current_flag=flag ^ 64, initial=initial, teo_transition=transition))
    return rows


class Resources(unittest.TestCase):
    def test_export_current(self):
        packet,proof=export.export()
        self.assertEqual(packet,json.loads((ROOT/'game/assets/field_ordinary_actors.json').read_text()))
        self.assertEqual(proof,json.loads((ROOT/'kit/data/reports/field_ordinary_actors.json').read_text()))

    def test_actual_constructor_lookup_and_retained_identity(self):
        self.assertEqual(original(),json.loads((ROOT/'game/tests/fixtures/field_ordinary_actors.json').read_text()))


if __name__=='__main__':unittest.main()

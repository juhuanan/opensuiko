#!/usr/bin/env python3
"""Flash's source columns and wash, independent of live scene admission."""
import json
from pathlib import Path
import struct
import sys
import unittest

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
import battle_drops
import disc
import unite_scene_flash
from spell_scene_player import Player


class FlashScene(unittest.TestCase):
    def test_source_columns_and_wash_in_both_consumers(self):
        exe = disc.extract(17976, 757760)
        base, size = struct.unpack_from('<II', exe, 24)
        image = exe[2048:2048 + size]
        def word(address):
            return struct.unpack_from('<I', image, address - base)[0]
        for address, expected in {
            0x800FBFF4: 0xAC620054, 0x800FC048: 0x8E420064,
            0x800FC050: 0x2442C040, 0x800FC098: 0x0C03E4E4,
            0x800FC09C: 0xAC400054, 0x800FC0FC: 0x8E43001C,
            0x800FC108: 0xAC620050, 0x800FC118: 0x0C047415,
            0x8011D07C: 0x10600033, 0x8011D098: 0x00021302,
        }.items():
            self.assertEqual(word(address), expected, hex(address))
        program = unite_scene_flash.program()
        fixture = json.loads((ROOT / 'game/tests/fixtures/flash_scene_program.json').read_text())
        self.assertEqual(program, fixture)
        scene = dict(id='flash', name='Flash', program=program)
        player = Player(dict(entries=[], unite_scenes=[scene]), 'flash', Image.new('RGBA', (1, 1)), unite=True)
        for update in (0, 1, 32, 63, 64, 128, 129, 161, 191, 192):
            frame = player.frame(update, (0, 0, 0), (0, 0, 0))
            commands = frame['commands']
            self.assertEqual(len(commands), 30 if 1 <= update <= 63 else 1 if 64 <= update <= 191 else 0)
            if 1 <= update <= 63:
                gap = (0x190000 - update * 0x3200) >> 12
                for column, origin in enumerate(((0, -30, -40), (0, 10, -40), (0, 30, -40))):
                    for segment in range(10):
                        angle = 96 * update - 409 * segment
                        end = angle - (409 - gap)
                        vertices = []
                        for point, turn in (((0, 0, 0), angle), ((0, 0, 0), end),
                                            ((800, 0, -100), angle), ((800, 0, -100), end)):
                            world = battle_drops.transform(point, (0, 0, turn), (4096, 4096, 4096), origin)
                            vertices.append(battle_drops.projected(world, frame['camera'])[:2])
                        self.assertEqual(commands[column * 10 + segment]['vertices'], vertices)
            elif 64 <= update <= 191:
                expected = 255 if update <= 128 else (0xFF000 - 0x3FC0 * (update - 128)) >> 12
                self.assertEqual(commands[0]['colors'], [[expected] * 3] * 4)


if __name__ == '__main__':
    unittest.main()

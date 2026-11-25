#!/usr/bin/env python3
"""BonBon actor ordering and local signal clocks from raw source data."""
from pathlib import Path
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
import maindec
from export_first_room import source


class BonbonSourceMotion(unittest.TestCase):
    def test_raw_script_and_vm_before_movement(self):
        raw, origin = source('/A_DATA.BIN')
        self.assertEqual(origin['sha256'], '1739375bf8292fbfdbf0eba749035a772448dc060e68a1d102db2ec66d882045')
        base = 0x80080000
        record = 0x8009F3FC - base
        table = struct.unpack_from('<I', raw, record + 40)[0] - base
        attack = struct.unpack_from('<I', raw, table + 4)[0] - base
        returning = struct.unpack_from('<I', raw, table + 16)[0] - base
        self.assertEqual((table + base, attack + base, returning + base), (0x8009F154, 0x8009F194, 0x8009F1DC))
        lengths = {0: 1, 3: 2, 9: 2, 15: 3, 16: 3, 21: 1, 23: 9, 26: 3, 34: 2}

        def read(offset):
            result = []
            while True:
                op = struct.unpack_from('<H', raw, offset)[0]
                length = lengths[op]
                args = struct.unpack_from('<' + 'h' * (length - 1), raw, offset + 2)
                result.append((op, args))
                if op == 0:
                    return result
                offset += 2 * length

        script = read(attack)
        self.assertEqual(script, [(15, (0, 1)), (15, (1, 8)), (34, (1292,)), (34, (1363,)),
            (23, (2, 12, 0, 0, -24, 3, 0, 3)), (3, (2,)), (26, (0, 1)), (3, (1,)),
            (21, ()), (26, (0, 2)), (3, (1,)), (26, (0, 4)), (0, ())])
        self.assertEqual(read(returning)[1], (23, (3, 30, 0, 0, 0, 0, 0, -8)))
        words = {
            0x800E0A74: 0x0C038AA7, 0x800E0A7C: 0x0C038D63,
            0x800E35F8: 0x0040F809, 0x800E360C: 0x14430018,
            0x800E3684: 0x87020010, 0x800E3774: 0x2442FFFF, 0x800E3778: 0xA7020010,
            0x800E45E4: 0x84820010, 0x800E45EC: 0x1C400005,
            0x800E396C: 0x2442FFFF, 0x800E3970: 0xA4820012, 0x800E3978: 0x1C400007,
        }
        for address, word in words.items():
            self.assertEqual(maindec.mword(address), word, hex(address))
        # Descriptor dispatch installs both counters before the first actor update.
        movement = script[4][1][1]
        timer = script[5][1][0]
        stage, flags = 0, {}
        for update in range(1, 32):
            if stage == 0:
                timer -= 1
                if timer == 0:
                    flags[script[6][1][1]] = update
                    timer = script[7][1][0]
                    stage = 1
            elif stage == 1:
                timer -= 1
                if timer == 0:
                    stage = 2
            if stage == 2 and movement == 0:
                flags[script[9][1][1]] = update
                timer = script[10][1][0]
                stage = 3
            elif stage == 3:
                timer -= 1
                if timer == 0:
                    flags[script[11][1][1]] = update
                    break
            movement = max(0, movement - 1)
        self.assertEqual(flags, {1: 2, 2: 13, 4: 14})


if __name__ == '__main__':
    unittest.main()

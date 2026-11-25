#!/usr/bin/env python3
"""Static source witnesses for weapon-piece identity, selection and stat effects."""
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "kit/tools"))
import maindec
from war_text import decode


class WeaponPieceSource(unittest.TestCase):
    def test_item_names(self):
        expected = ("Fire rune piece", "Water rune piece", "Wind rune piece", "Thunder rune piece", "Earth rune piece")
        for item_id, name in zip(range(57, 62), expected):
            descriptor = maindec.mword(0x80167658 + item_id * 4)
            self.assertEqual(decode(maindec.body(), descriptor - maindec.MBASE)[0], name)

    def test_selection_commit_and_stat_instructions(self):
        words = {
            0x800D71A0: 0x90830046,  # existing weapon element
            0x800D71C4: 0x14430015,  # different element requests replacement
            0x800D71E4: 0x90420046,  # selected element's count
            0x800D71EC: 0x2C420009,  # matching element capped at nine
            0x800D7530: 0xA0400046,  # clear other element counts
            0x800D753C: 0xA0440046,  # commit selected element
            0x800D7554: 0x24420001,  # increment selected count
            0x800D75A4: 0x0C032902,  # remove the source owner's item
            0x800D4F54: 0x90A40005,  # wind count
            0x800D4F60: 0x00441021,  # times three into defense
            0x800D4F70: 0x90A20007,  # earth count
            0x800D4F78: 0x00021040,  # times two into skill
        }
        for address, expected in words.items():
            self.assertEqual(maindec.mword(address), expected, hex(address))


if __name__ == "__main__":
    unittest.main()

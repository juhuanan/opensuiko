#!/usr/bin/env python3
"""Static source checks for spell counters, item uses and rune/weapon fields."""
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
import maindec as M
import growth_rules as GR
from test_canonical_start import assert_main_words
from test_rune_preparation import RunePreparationTests, assert_span


def magic_capacity_vectors():
    assert_span(0x800CA60C, 0x800CA66C, 'f5a794b04475ec1950161a1d51091722633c6c188a11fe7ee010f3d45f290972')
    assert_main_words({
        # Clear counter 0, read MGC, and scan a 9-byte tier backwards.
        0x800CA60C: (0xA0800008, 0x34060001, 0x3C078017, 0x24E7A60C, 0x90880014,
                     0x34030008, 0x24E50008, 0x90A20000, 0, 0x0048102A, 0x14400004),
        0x800CA648: (0x00861021, 0x24630001, 0xA0430008, 0x24C60001, 0x28C20005, 0x1440FFF0, 0x24E70009),
    })
    raw = M.body()
    thresholds = [raw[start-M.MBASE:start-M.MBASE+9] for start in range(0x8016A60C, 0x8016A630, 9)]
    assert all(len(row) == 9 and list(row) == sorted(row) for row in thresholds)
    return [[sum(value < magic for value in row) for row in thresholds] for magic in range(256)]


def check():
    assert GR.RECORD['status'][:2] == (0x16, 1)
    expected = json.loads((ROOT / 'game/tests/fixtures/magic_capacity.json').read_text())
    assert magic_capacity_vectors() == expected
    for start, end, digest in [
        (0x800F5344, 0x800F5398, '55d10a66b2f2a1e52cc143b44d11e42f2088b3f2fb2afd2b18d1d10b6aed3139'),
        (0x800D9A98, 0x800D9BCC, '5115ff2c70df3a2eb8e987fd1943cbaaec7bdefe64c21941f879df0a3c138af7'),
    ]:
        assert_span(start, end, digest)
    assert_main_words({
        # Resolve the selected actor's record, then decrement only a nonzero tier byte.
        0x800F535C: (0x8C620F84, 0, 0x8C42001C, 0, 0x00451821, 0x90620008, 0,
                     0x10400005, 0, 0x90620008, 0, 0x2442FFFF, 0xA0620008),
        # An item uses a signed byte and calls removal only when decrementing to zero.
        0x800F50D8: (0x24420020,),
        0x800F5268: (0x82620003, 0, 0x18400009, 0x00401821, 0x2462FFFF, 0xA2620003,
                     0x00021600, 0x14400005, 0x00121880, 0x02A02021, 0x0C032902, 0x02C02821),
        # A matching rune's shop row is enabled only when its lock byte is zero.
        0x800D9AC8: (0x8E23001C, 0x8C500024, 0x9072004C),
        0x800D9B08: (0x34030001, 0x34040004, 0x3C018017, 0x2421B080, 0x00240821,
                     0x84220000, 0, 0x14520011, 0, 0x8E22001C, 0, 0x9042004D, 0, 0x1440000B),
        0x800D9B6C: (0x24630001, 0x2862001F, 0x1440FFE6, 0x24840004),
        # The blacksmith selects the price by current level and commits a one-byte increment.
        0x800D65B8: (0x90860044, 0x90850045),
        0x800D66C4: (0x3C018017, 0x2421AF2C, 0x00230821, 0x8C230000, 0, 0x00431023,
                     0xAC820040, 0x8CE3001C, 0, 0x90620045, 0, 0x24420001, 0xA0620045),
        0x800CA3A0: (0x2C420009,),
        0x800CA3B8: (0xA062001F,),
        0x800CA3CC: (0x00021080,),
        0x800CA3E4: (0xB862001C,),
        0x800D480C: (0x3062007F,),
        0x800D4818: (0x30620080,),
        0x800CFEA4: (0xA0640022,),
        0x80138D30: (0xA4620006,),
        0x80138D3C: (0xA4400016,),
        0x80138D44: (0x0C032983,),
        0x800DEDB0: (0x90420016, 0xA2550044, 0xA642004A),
    })
    # Reuse the independent source checks for selected-record rune stores and
    # the attached inventory calls.
    RunePreparationTests().test_attach_uses_owner_slot_and_detach_returns_the_mapped_crystal()
    print('PASS: 256 retained magic-capacity vectors and static charge, rune, weapon and item consumers')


if __name__ == '__main__':
    check()

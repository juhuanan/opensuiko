#!/usr/bin/env python3
"""Static source checks for the VB6 inn setup, payment and refill."""
import hashlib
import json
from pathlib import Path
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
import export_inn
import maindec as M
from export_first_room import source
from mipsdec import sx16
from test_canonical_start import assert_main_words

BASE = 0x80010000
FIXTURE = ROOT / 'game/tests/fixtures/inn_transactions.json'


def inn_rate():
    data, _ = source('/VB6.BIN')

    def ptr(offset):
        return struct.unpack_from('<I', data, offset)[0] - BASE

    root = ptr(0)
    rooms = ptr(root + 8)
    inn = ptr(rooms + 7 * 16)
    stream = ptr(inn + 2 * 24 + 20)
    assert (root, stream) == (0x120C, 0x35A9C)
    assert data[0x35AB7:0x35ABB] == bytes((0x43, 6, 1, 0xFD))
    arguments = ptr(root + 0x10)
    context = ptr(arguments + 0x0C + 4 * data[0x35AB9])
    rate = ptr(context)
    assert (context, rate, ptr(context + 4)) == (0x34474, 0x34454, 0x34330)
    first, second = data[rate:rate + 2]
    assert (first, second) == (100, 1)
    return first * second


def source_vectors():
    image = M.body()
    for start, end, digest in [
        (0x801397D0, 0x801398F8, '4486426086f33e1aef083a4a726cf0ef0a873ac1b5aa809e997b93807e9b4905'),
        (0x800D9DEC, 0x800D9E90, '36a6b93559f91b664ab0982001b97616a6e8ddcc683525bbb1716fe08856eecf'),
        (0x800D9F2C, 0x800DA008, '3a27f2fe5f8738e9f89565c05873829f38ece1a60d01dce3e8706f28f2d0466d'),
        (0x800CA60C, 0x800CA66C, 'f5a794b04475ec1950161a1d51091722633c6c188a11fe7ee010f3d45f290972'),
    ]:
        assert hashlib.sha256(image[start - M.MBASE:end - M.MBASE]).hexdigest() == digest, hex(start)
    assert M.mword(0x80171718 + 0x43 * 4) == 0x801397D0
    assert_main_words({
        # Selected service and its argument pointer use separate context fields.
        0x801397F4: (0xA06204E0,),
        0x801398B4: (0x90620000, 0x8C830010, 0x00021080, 0x00431021, 0x8C42000C, 0, 0xACA20494),
        # Multiply the two rate bytes and then multiply by party count.
        0x800D9DF4: (0x8C820000, 0x3C018018, 0xAC249EC0, 0x90430000, 0x90420001, 0, 0x00620018),
        0x800D9E1C: (0x90420003, 0x00001812, 0, 0, 0x00620018, 0x00001012, 0, 0, 0x3C018018, 0xAC229ED0),
        # Insufficient funds return the failure callback before any debit or party stores.
        0x800D9F44: (0x8CA59ED0, 0x8C86001C, 0, 0x00C5102A, 0x10400005, 0x00C51023,
                     0x3C02800E, 0x2442A064, 0x080367FE, 0, 0x90830003, 0xAC82001C),
        # The paid path copies maximum HP into current HP unconditionally,
        # including at zero HP. It clears both status bytes and refills charges.
        0x800D9F8C: (0x9042000E, 0, 0x00021080, 0x00431021, 0x8C441B9C, 0, 0x8C83001C, 0,
                     0x94620004, 0, 0xA4620006, 0x8C82001C, 0, 0xA4400016, 0x8C84001C, 0x0C032983, 0x26100001),
        0x800D9FDC: (0x90420003, 0, 0x0202102A, 0x1440FFE4, 0, 0x3C02800E, 0x2442A008),
        # Refill scans backward and takes the last threshold strictly below stat.
        0x800CA60C: (0xA0800008, 0x34060001, 0x3C078017, 0x24E7A60C, 0x90880014, 0x34030008,
                     0x24E50008, 0x90A20000, 0, 0x0048102A, 0x14400004),
        0x800CA64C: (0x24630001, 0xA0430008, 0x24C60001, 0x28C20005, 0x1440FFF0, 0x24E70009),
    })
    rate = inn_rate()
    address = ((M.mword(0x800CA614) & 0xFFFF) << 16) + sx16(M.mword(0x800CA618))
    tiers = sx16(M.mword(0x800CA658)) - 1
    width = sx16(M.mword(0x800CA660))
    assert (address, tiers, width) == (0x8016A60C, 4, 9)
    thresholds = [image[address - M.MBASE + tier * width:address - M.MBASE + (tier + 1) * width]
                  for tier in range(tiers)]
    assert all(list(row) == sorted(row) for row in thresholds)
    maximum = [sum(value < 50 for value in row) for row in thresholds]
    rows = []
    for count in range(1, 7):
        cost = count * rate
        for money in (0, cost - 1, cost, cost + 1, 999999):
            rested = money >= cost
            rows.append({'party_size': count, 'money_before': money,
                         'money_after': money - cost if rested else money,
                         'rested': rested, 'max_rune_charges': maximum})
    return rows


class InnExportTests(unittest.TestCase):
    def test_export_preserves_accepted_content(self):
        with self.assertRaisesRegex(ValueError, 'accepted tree'):
            export_inn.write(ROOT / 'kit/work/accepted/first_room')

    def test_semantic_metadata_is_current(self):
        export_inn.write(ROOT / 'game/assets', verify=True)
        values = export_inn.export()
        self.assertEqual(values['inn.json']['price_per_member'], inn_rate())
        self.assertEqual(values['inn.json']['choices'], ['Stay', "Don't stay"])

    def test_export_and_zig_vectors_against_source_consumers(self):
        rows = source_vectors()
        self.assertEqual(len(rows), 30)
        self.assertEqual(json.loads(FIXTURE.read_text()), rows)


if __name__ == '__main__':
    if '--write-fixture' in sys.argv:
        FIXTURE.write_text(json.dumps(source_vectors(), indent=2) + '\n')
        print('Wrote 30 static inn transaction vectors')
    else:
        unittest.main()

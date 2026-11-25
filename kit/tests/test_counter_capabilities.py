#!/usr/bin/env python3
"""Static producer/consumer checks for the ordinary counter capability inputs."""
import json
from pathlib import Path
import struct
import sys
import unittest

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'kit/tools'))
import character_table
import export_physical_runes
from export_first_room import source
import maindec


class CounterCapabilities(unittest.TestCase):
    def test_party_weapon_pointer_producer_and_counter_reader_agree(self):
        for pc,word in {
            0x800DEDC4:0x8E22001C,0x800DEDD0:0x90420044,
            0x800DEDE0:0x00021080,0x800DEDE8:0x24215890,
            0x800DEDF0:0x8C220000,0x800DEDFC:0xAE820004,
            0x800F793C:0x00681821,0x800F7954:0x8C630004,
            0x800F7964:0x90620056,0x800F796C:0x30420001,
            0x800F78F8:0x8CC2001C,0x800F7900:0x24420001,
            0x800F7904:0x0044102A,0x800F7950:0x94420026,
            0x800F7958:0x30420001,
        }.items():self.assertEqual(maindec.mword(pc),word,hex(pc))

    def test_all_78_weapon_flags_match_the_independent_character_weapon_catalogue(self):
        rows=json.loads((ROOT/'game/assets/profiles/character_weapons.json').read_text())['characters']
        by_id={row['id']:row for row in rows}
        records=character_table.records()
        self.assertEqual(len(records),78)
        for record in records:
            address=maindec.mword(0x80165890+4*record['weapon_id'])
            value=maindec.body()[address-maindec.MBASE+0x56]
            self.assertIn(value,(1,2,3))
            self.assertEqual(by_id[record['id']]['range'],value)
            self.assertEqual(bool(value&1),by_id[record['id']]['range_name'] in ('short','medium'))

    def test_current_enemy_flags_keep_both_positive_counter_capabilities(self):
        capable=[]
        rows=export_physical_runes.recipient_resources()
        self.assertEqual(len(rows),13)
        for resource,proof in rows:
            raw,_=source('/'+proof['source']['file'].split('/')[-1])
            flags=struct.unpack_from('<H',raw,proof['record_source_offset']+0x26)[0]
            if flags&1:capable.append(resource['id'])
        self.assertEqual(capable,['red_soldier_ant','kobold_type_1'])


if __name__=='__main__':unittest.main()

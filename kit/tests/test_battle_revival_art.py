#!/usr/bin/env python3
"""Static clip and independent VRAM checks for the shared Buddha actor export."""
from pathlib import Path
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT/'kit/tools'), str(ROOT/'kit/tests')]
import character_table
import export_battle_trial as actors
from export_first_room import Atlas, source
import journey_battle
from test_export_unite_review import vram_pose


class RevivalArt(unittest.TestCase):
    def test_all_78_source_character_clips_match_headers_and_independent_vram_pixels(self):
        records = character_table.records()
        self.assertEqual(len(records),78)
        checked = 0
        for record in records:
            with self.subTest(character=record['name']):
                raw,origin = source('/'+record['sprite_file'])
                section = struct.unpack_from('<I',raw,36)[0]
                atlas = Atlas()
                exported = journey_battle.revival_art(raw,atlas)
                table = struct.unpack_from('<I',raw,section+20)[0]
                for name,index in (('down',3),('recovery',2)):
                    pointer = struct.unpack_from('<I',raw,table+index*4)[0]
                    count,flags = raw[pointer:pointer+2]
                    if name == 'down': self.assertEqual((count,flags),(1,1))
                    clip = exported[name]
                    self.assertEqual((clip['advances'],clip['loop']),(bool(flags&1),bool(flags&2)))
                    pairs = [tuple(raw[pointer+4+2*i:pointer+6+2*i]) for i in range(count)]
                    self.assertEqual([(f['source_pose'],f['ticks']) for f in clip['frames']],[(pose,t or 256) for pose,t in pairs])
                    self.assertTrue(clip['frames'])
                    for frame in clip['frames']:
                        expected,ax,ay = vram_pose(raw,section,frame['source_pose'],packet=True)
                        r = frame['pose']['rect']
                        actual = atlas.image.crop((r['x'],r['y'],r['x']+r['w'],r['y']+r['h']))
                        self.assertEqual((actual.size,frame['pose']['anchor_x'],frame['pose']['anchor_y']),(expected.size,ax,ay))
                        self.assertEqual(actual.tobytes(),expected.tobytes())
                        self.assertIsNotNone(actual.getchannel('A').getbbox())
                checked += 1
        self.assertEqual(checked,78)


if __name__=='__main__':unittest.main()

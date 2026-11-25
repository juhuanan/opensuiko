#!/usr/bin/env python3
"""Drops source witnesses, independent geometry vectors and preview raster checks."""
import json
from pathlib import Path
import struct
import sys
import unittest

import numpy as np
from PIL import Image
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'kit/tools'))
import battle_drops as drops
import battle_drops_preview as preview
import disc
import maindec


class DropsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        data=disc.extract(17976,757760)
        cls.base, size=struct.unpack_from('<II',data,24)
        cls.image=data[2048:2048+size]
        cls.vectors=json.loads((ROOT/'game/tests/fixtures/drops_geometry.json').read_text())
        cls.scene=drops.Scene(cls.vectors['draws'])

    def word(self,pc):return struct.unpack_from('<I',self.image,pc-self.base)[0]

    def test_frame_vectors_are_reproducible_and_native_compared(self):
        self.assertEqual(self.vectors,drops.geometry_vectors())

    def test_focus_offset_is_rebuilt_by_rtps_before_subtracting_camera_focus(self):
        # First RTPS stores SXY2 directly into scene+132C, destroying the old value.
        self.assertEqual(self.word(0x800E1598),0x0C053D71)
        self.assertEqual(self.word(0x800E159C),0x24A5132C)
        store=self.word(0x8014F5D4)
        self.assertEqual((store>>26,(store>>21)&31,(store>>16)&31,store&65535),(0x3A,5,14,0))
        self.assertEqual(self.word(0x800E15B4),0x0C053D71)
        self.assertEqual(self.word(0x800E15B8),0x24841270)
        self.assertEqual(self.word(0x800E15D8),0x00641823)
        block=drops.camera_at(60)
        focus=drops.projected(block[:3],block)
        self.assertEqual(focus[:2],[160,120])
        self.assertNotEqual(drops.projected((0,0,0),block)[:2],[160,120])

    def test_animation_loop_is_three_five_update_pieces_with_reset_before_draw(self):
        animation=self.scene.effect['animations'][3]
        off=animation['source_offset']
        # Raw F records specify advancement and exact piece/duration pairs.
        self.assertEqual(list(self.scene.data[off:off+10]),[3,1,1,0,8,5,9,5,10,5])
        for elapsed,expected in [(1,8),(4,8),(5,9),(9,9),(10,10),(14,10),(15,8)]:
            frame=self.scene.frame(96+elapsed,(120,50,0),(112,0,0))
            self.assertEqual(frame['commands'][0]['texture'],self.scene.pieces[expected][0])
        # Wrapper animates immediately before drawing, not at a generic global clock.
        self.assertEqual(self.word(0x80105A14),0x34070001)
        self.assertEqual(self.word(0x80123428),0x32310001)
        self.assertEqual(self.word(0x8010603C),0x0C048E38)
        self.assertEqual(self.word(0x8010605C),0x0C048DC8)

    def test_visibility_and_healing_boundaries(self):
        for update,caster,target in [(0,False,False),(1,True,False),(95,True,False),(96,False,False),(97,False,True),(305,False,True),(306,False,False)]:
            p=drops.parameters(update)
            self.assertEqual((p['caster_visible'],p['targets_visible']),(caster,target))
            frame=self.scene.frame(update,(120,50,0),(112,0,0))
            self.assertEqual(frame['healed'],update==306)
        self.assertEqual(drops.parameters(186)['column_top'],-5)
        self.assertEqual(drops.parameters(246)['column_top'],-185)
        self.assertEqual(self.scene.frame(306,(0,0,0),(0,0,0))['commands'],[])

    def test_auxiliary_fan_column_and_wash_have_positive_source_consumers(self):
        for pc,expected in {0x80105AEC:0x3407017B,0x80105B58:0x0C048222,
                            0x80105B5C:0x2407FFFB,0x80105E20:0x2463FFFD,
                            0x80106084:0x0C0481ED,0x80106090:0x0C0475E8,
                            0x801060A8:0x0C0481ED,0x801060B4:0x0C0482D6,
                            0x801060C0:0x0C047415}.items():
            self.assertEqual(self.word(pc),expected,hex(pc))
        self.assertEqual(drops.parameters(64)['wash'],[0,32,64])
        self.assertEqual(drops.parameters(306)['wash'],[0,0,0])
        frame=self.scene.frame(220,(120,50,0),(112,0,0))
        color=[c for c in frame['commands'] if c['kind']=='color']
        self.assertEqual(len(color),64)
        self.assertEqual(color[0]['colors'],[[0,0,0],[127,127,127],[127,127,127]])
        self.assertEqual(color[1]['colors'],[[0,0,0],[0,0,0],[0,0,80],[0,0,80]])

    def test_random_inputs_are_bounded_and_independent_per_object(self):
        with self.assertRaises(ValueError):drops.Scene([0]*17)
        with self.assertRaises(ValueError):drops.Scene([32768]*18)
        for draws in ([0]*18,[32767]*18):
            scene=drops.Scene(draws)
            for update in (1,96,97,186,246,305,306):
                frame=scene.frame(update,(120,50,0),(112,0,0))
                self.assertLessEqual(len(frame['commands']),71)
                self.assertTrue(all(np.isfinite(c['vertices']).all() for c in frame['commands']))

    def test_additive_quad_has_no_double_bright_diagonal(self):
        raster=preview.Raster()
        texture=np.full((4,4,4),[10,20,30,255],dtype=np.uint8)
        points=[[20,20],[24,20],[20,24],[24,24]]
        raster.quad(points,texture=texture,additive=True)
        self.assertTrue(np.all(raster.rgb[20:24,20:24]==[10,20,30]))
        raster.quad(points,texture=texture,additive=True,intensity=64)
        self.assertTrue(np.all(raster.rgb[20:24,20:24]==[15,30,45]))


if __name__=='__main__':unittest.main()

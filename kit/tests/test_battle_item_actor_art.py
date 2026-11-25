#!/usr/bin/env python3
"""Static item clips/timing and independent VRAM pixels; no original execution."""
import copy
import json
from pathlib import Path
import struct
import sys
import unittest

ROOT=Path(__file__).resolve().parents[2]
sys.path[:0]=[str(ROOT/'kit/tools'),str(ROOT/'kit/tests')]
import character_table
import journey_battle
import maindec
import preparation
from export_first_room import Atlas,source
from export_world_travel import medicine_timings
from test_export_unite_review import vram_pose

SELECTED=(('idle',0),('prepare',13),('hold',14),('recover',15))


class ItemActorArt(unittest.TestCase):
    def test_all_78_item_clips_match_original_flags_frames_and_independent_vram_pixels(self):
        colors=0
        for record in character_table.records():
            with self.subTest(character=record['name']):
                raw,_=source('/'+record['sprite_file'])
                section=struct.unpack_from('<I',raw,36)[0]
                dt,et,ft=struct.unpack_from('<III',raw,section+12)
                atlas=Atlas();clips=journey_battle.named_actor_art(raw,atlas,SELECTED)
                palettes=set()
                for name,index in SELECTED:
                    offset=struct.unpack_from('<I',raw,ft+4*index)[0]
                    count,flags=raw[offset:offset+2]
                    if name=='idle':self.assertEqual((count,flags),(1,1))
                    expected=[(p,t or 256) for p,t in struct.iter_unpack('BB',raw[offset+4:offset+4+count*2])]
                    clip=clips[name]
                    self.assertEqual((clip['advances'],clip['loop']),(bool(flags&1),bool(flags&2)))
                    self.assertEqual([(f['source_pose'],f['ticks']) for f in clip['frames']],expected)
                    for frame in clip['frames']:
                        image,ax,ay=vram_pose(raw,section,frame['source_pose'],packet=True)
                        r=frame['pose']['rect'];actual=atlas.image.crop((r['x'],r['y'],r['x']+r['w'],r['y']+r['h']))
                        self.assertEqual((actual.size,frame['pose']['anchor_x'],frame['pose']['anchor_y']),(image.size,ax,ay))
                        self.assertEqual(actual.tobytes(),image.tobytes())
                        self.assertIsNotNone(image.getchannel('A').getbbox())
                        e=struct.unpack_from('<I',raw,et+4*frame['source_pose'])[0]
                        palettes.update(raw[e+14+8*i] for i in range(raw[e]))
                for palette in palettes:
                    offset=struct.unpack_from('<I',raw,dt+4*palette)[0]
                    values=struct.unpack_from('<32H',raw,offset)
                    self.assertTrue(all(value&32768 for value in values if value))
                    colors+=sum(value!=0 for value in values)
        self.assertEqual(colors,2418)

    def test_all_78_source_timings_follow_common_scripts_and_independent_duration_counters(self):
        raw_main=maindec.body()
        self.assertEqual(struct.unpack_from('<21H',raw_main,0x8016C194-maindec.MBASE),
            (15,0,1,4,13,5,4,14,5,26,0,8,3,60,4,15,5,16,0,1,0))
        self.assertEqual(struct.unpack_from('<14H',raw_main,0x8016C1C0-maindec.MBASE),
            (15,0,1,3,60,4,15,5,4,0,16,0,1,0))
        for pc,word in {0x800F2294:0x34630004,0x800F28C0:0x34420004,
                        0x800F29D0:0x2442FFFF,0x800F2930:0x2402FE00,
                        0x800F08D4:0x1040000A,0x800F08E0:0x24C6C1C0,
                        0x800F09A4:0x1040000A,0x800F09B0:0x24C6C1C0}.items():
            self.assertEqual(maindec.mword(pc),word)
        records=character_table.records();ids=[preparation.stable_id(r['name']) for r in records]
        timings=medicine_timings(ids)
        for record,timing in zip(records,timings,strict=True):
            raw,_=source('/'+record['sprite_file']);s=struct.unpack_from('<I',raw,36)[0]
            ft=struct.unpack_from('<I',raw,s+20)[0];durations=[]
            for animation in (13,14,15):
                f=struct.unpack_from('<I',raw,ft+4*animation)[0]
                self.assertEqual(raw[f+1],1)
                counter=0
                for i in range(raw[f]):
                    remaining=raw[f+5+i*2] or 256
                    while remaining:
                        counter+=1;remaining-=1
                durations.append(counter)
            self.assertEqual(durations[1],1)
            start=durations[0]+2
            self.assertEqual(timing,dict(id=preparation.stable_id(record['name']),target_start=start,
                pending_tick=start+31,impact_tick=start+32,target_release=start+64,
                owner_release=start+59+durations[2]))

    def test_append_preserves_existing_art_and_other_fields_and_repeated_export(self):
        atlas=Atlas();marker=atlas.image.crop((0,0,8,8));marker.paste((19,47,83,255),(0,0,8,8))
        atlas.add(marker)
        content=dict(party=[dict(id='hero',retained=17),dict(id='gremio',retained=23)],retained={'value':9})
        proof=journey_battle.append_item_art(content,atlas)
        self.assertEqual(atlas.image.crop((0,0,8,8)).tobytes(),marker.tobytes())
        self.assertEqual(content['retained'],{'value':9})
        self.assertEqual([p['retained'] for p in content['party']],[17,23])
        self.assertEqual([p['id'] for p in proof],['hero','gremio'])
        before=copy.deepcopy(content);position=(atlas.x,atlas.y,atlas.row_height)
        self.assertEqual(journey_battle.append_item_art(content,atlas),[])
        self.assertEqual(content,before)
        self.assertEqual((atlas.x,atlas.y,atlas.row_height),position)

    def test_current_native_profiles_have_named_clips_and_matching_source_timing(self):
        for name,count in (('journey_battle.json',7),('blacksmith_battle.json',44)):
            packet=json.loads((ROOT/'game/tests/fixtures'/name).read_text())
            self.assertEqual(packet['schema'],'suikoden-battle-trial/33')
            self.assertEqual(len(packet['party']),count)
            self.assertEqual(packet['medicine_timings'],medicine_timings([p['id'] for p in packet['party']]))
            for profile in packet['party']:
                self.assertEqual(set(profile['item_art']),{'idle','prepare','hold','recover'})
                self.assertTrue(all(frame['source_pose'] is not None for clip in profile['item_art'].values() for frame in clip['frames']))


if __name__=='__main__':unittest.main()

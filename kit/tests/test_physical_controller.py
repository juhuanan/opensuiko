#!/usr/bin/env python3
"""Independent static clocks for physical owner/recipient programs and Hate's mailbox join."""
import json
from pathlib import Path
import struct
import sys
import unittest

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'kit/tools'))
from export_first_room import source
import character_table
import maindec
import preparation
from test_physical_rune_export import independent_stream

FIXTURE=ROOT/'game/tests/fixtures/physical_controller_vectors.json'


class UnboundedAnimation(ValueError):
    def __init__(self,animation,at):self.animation=animation;self.at=at


def clock(raw,operations,waits=None,section=None,base=0,initial_highlights=0):
    if section is None:section=struct.unpack_from('<I',raw,36)[0]
    table=struct.unpack_from('<I',raw,section+20)[0]-base
    elapsed=selected=selected_at=move_end=0;signals={};release=None;values={};highlights=initial_highlights
    for row in operations:
        op,args=row['op'],row['args']
        if op==4:selected,selected_at=args[0],elapsed
        elif op==5:
            f=struct.unpack_from('<I',raw,table+4*selected)[0]-base
            if not raw[f+1]&1:continue
            if raw[f+1]&2:raise UnboundedAnimation(selected,elapsed)
            elapsed=max(elapsed,selected_at+sum(raw[f+5+2*i] or 256 for i in range(max(1,raw[f]))))
        elif op==3:elapsed+=max(1,args[0])
        elif op==30:values[args[0]]=elapsed;elapsed+=1
        # A move installed at dispatch gets its first integration on update1;
        # its wait is polled before integration, so completion is observed one later.
        elif op in (23,33):move_end=elapsed+max(1,args[1])+(elapsed==0)
        elif op==22:move_end=elapsed+args[0]+(elapsed==0)
        elif op==21:elapsed=max(elapsed,move_end)
        elif op==26:signals[tuple(args)]=elapsed
        elif op==28:elapsed=max(elapsed,(waits or {})[tuple(args)])
        elif op==29:
            if args!=[0,2]:raise ValueError('unbound recipient wait')
            elapsed=max(elapsed,signals[(0,2)]+1)
        elif op in (15,16) and args[0]==0:
            before=highlights
            highlights=highlights|args[1] if op==15 else highlights&~args[1]
            if before and not highlights:release=elapsed
        elif op not in (0,1,2,6,8,9,13,14,15,16,17,18,19,20,24,25,27,34,35,38,39,40,42,43):
            raise ValueError('unbound physical clock opcode '+str(op))
    return dict(complete=elapsed,signals=signals,release=release,values=values)


def reference():
    records=character_table.records();main=maindec.body();rows=[]
    import area_encounter_tables as encounters
    enemy=source('/A_DATA.BIN')[0]
    _,_,directory,_=encounters.chain(enemy)
    enemies=struct.unpack_from('<I',enemy,directory-encounters.BASE+12)[0]-encounters.BASE
    record=struct.unpack_from('<I',enemy,enemies+4)[0]-encounters.BASE
    enemy_section=struct.unpack_from('<I',enemy,record+44)[0]-encounters.BASE
    names={'boar':'PAN','shrike':'KAS','falcon':'VRE','hate':'BEL','trick':'JUP'}
    for identifier,filename in [*names.items(),('clone',None)]:
        if filename:
            raw,_=source('/'+filename+'.BIN');table=struct.unpack_from('<I',raw,32)[0]
            owner=independent_stream(raw,struct.unpack_from('<I',raw,table+13*4)[0],table)
            recipient=independent_stream(raw,struct.unpack_from('<I',raw,table+14*4)[0],table)
            members=[r for r in records if r['sprite_file'].split('/')[-1]==filename+'.BIN']
        else:
            owner=independent_stream(main,0x8016C83C-maindec.MBASE)
            recipient=independent_stream(main,0x8016C908-maindec.MBASE)
            members=records
        waits=None;birth=None
        if identifier=='hate':
            split=next(i for i,r in enumerate(owner) if r==dict(op=30,args=[1]))
            # Mailbox1 is written in the actor sweep; the primary initializer sees it next update.
            birth=clock(raw,owner[:split+1])['values'][1]+1
            auxiliary=independent_stream(raw,struct.unpack_from('<I',raw,table+15*4)[0],table)
            child=clock(raw,auxiliary)
            waits={(0,mask):birth+child['signals'][(1,mask)] for mask in (1,2)}
        for member in members:
            actor=source('/'+member['sprite_file'])[0]
            try:own=clock(actor,owner,waits)
            except UnboundedAnimation as blocked:
                if (identifier,member['name'],blocked.animation)!=('clone','Kanak',5):raise
                rows.append(dict(technique=identifier,member=preparation.stable_id(member['name']),
                                 blocked_animation=blocked.animation,blocked_at=blocked.at))
                continue
            # Every exported enemy hurt clip is one update, unlike some party hurt clips.
            target=clock(enemy,recipient,section=enemy_section,base=encounters.BASE,initial_highlights=8)
            signal=waits[(0,2)]-1 if waits else own['signals'][(0,2)]
            rows.append(dict(technique=identifier,member=preparation.stable_id(member['name']),owner_signal=signal,
                controller_release=own['signals'][(0,4)]+1,owner_complete=own['complete'],
                recipient_contact=target['signals'][(0,2)],recipient_release=target['release'],auxiliary_birth=birth))
    return dict(schema='suikoden-physical-controller-vectors/1',cases=rows)


class PhysicalController(unittest.TestCase):
    def test_static_source_controller_dispatch_and_damage_consumers(self):
        for pc,expected in {0x800F7384:0x8E220050,0x800F7394:0x0040F809,
                            0x800F8730:0x30420002,0x800F8778:0xA4400040,
                            0x800F877C:0x0C038E08,0x800F87FC:0x30420004,
                            0x800F8810:0xAC600014,0x800F88E0:0x3042FFFD,
                            0x800F8E18:0x1462005E,0x800F8E58:0x34050012,
                            0x800F8F40:0x0C038E08,0x800F8F50:0xA6420042,
                            0x800E209C:0x00021042,0x800E20A0:0x30420001,
                            0x800E20CC:0x30420001,0x800E20D0:0x00021040,
                            0x800E2AF4:0x30620001,0x800E2AF8:0x10400003,
                            0x800E2B04:0xA0800002,0x800E3C10:0x30420002,
                            0x800E35F8:0x0040F809,0x800E3714:0x8F0D002C}.items():
            self.assertEqual(maindec.mword(pc),expected,hex(pc))
        # Result callbacks run before the same primary pass commits pending HP.
        for pc,expected in {0x800E16E8:0x30428000,0x800E16F4:0x00008021,
                            0x800E177C:0xA462004E,0x800F7374:0x00000000,
                            0x800F73F0:0x8464004E,0x800F7460:0xA460004E,
                            0x800F7468:0xA4620012}.items():self.assertEqual(maindec.mword(pc),expected,hex(pc))
        self.assertEqual(reference(),json.loads(FIXTURE.read_text()))

    def test_kanak_looping_clone_wait_is_retained_as_an_unresolved_source_case(self):
        member=next(r for r in character_table.records() if r['name']=='Kanak')
        raw=source('/'+member['sprite_file'])[0]
        section=struct.unpack_from('<I',raw,36)[0];ft=struct.unpack_from('<I',raw,section+20)[0]
        frame=struct.unpack_from('<I',raw,ft+5*4)[0]
        self.assertEqual(raw[frame:frame+8],bytes.fromhex('0203020004030503'))
        owner=independent_stream(maindec.body(),0x8016C83C-maindec.MBASE)
        with self.assertRaises(UnboundedAnimation) as blocked:clock(raw,owner)
        self.assertEqual((blocked.exception.animation,blocked.exception.at),(5,35))


if __name__=='__main__':
    if '--write' in sys.argv:FIXTURE.write_text(json.dumps(reference(),separators=(',',':'))+'\n')
    else:unittest.main()

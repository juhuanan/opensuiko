#!/usr/bin/env python3
import json
import struct
import sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'kit/tools'))
import battle_unite_camera
import maindec
import disc

# The ordinary battle boot and confirmed command route reach the first round's launch.
assert [maindec.mword(pc) for pc in (0x800DEB44, 0x800DEB64, 0x800DEB74, 0x800F6A84,
                                   0x800F6A94, 0x800F6A9C, 0x800F6AAC, 0x800F6C70,
                                   0x800F6CB0, 0x800F6CC0, 0x800F709C)] == [
    0xAC600004, 0x244264F0, 0xAC220000, 0x24639E90,
    0xAC230000, 0x24636C34, 0xAC230000, 0x0040F809,
    0x24426DA8, 0xAC220000, 0xAC620004,
]
assert (maindec.mword(0x800C1404), maindec.mword(0x800C1410)) == (0x800F6CA8, 0x800F6CA8)

# Both the round launcher and the post-action return read the same block table.
for start, delay in ((0x800F70D4, 30), (0x800F406C, 20)):
    assert [maindec.mword(start + 4 * i) for i in range(5)] == [
        0x00031080 if delay == 30 else 0x00021080, 0x3C018017, 0x2421C018, 0x00220821, 0x8C240000,
    ]
    call = 0x800F70F0 if delay == 30 else 0x800F4080
    assert (maindec.mword(call), maindec.mword(call + 4)) == (0x0C03D844, 0x34050000 | delay)
# Reject a locked candidate first. Cross-side dispatch then waits for completion.
assert [maindec.mword(pc) for pc in (0x800F4008, 0x800F4010, 0x800F4034, 0x800F403C,
                                   0x800F4044, 0x800F404C, 0x800F4060, 0x800F4064, 0x800F4068,
                                   0x800F4090, 0x800F40A0)] == [
    0x0C03E181, 0x14400005, 0x8C830030, 0x10620005,
    0x8C820044, 0x14400016, 0xAC800030, 0xAC800044, 0xAC830008,
    0x244240FC, 0xAC220000,
]
assert [maindec.mword(0x8016C018 + 4 * i) for i in range(3)] == [0x8016BF88, 0x8016BFB8, 0x8016BFE8]
for source, focus_x, pitch, angle, scale in ((0x8016BF88, -32, -704, 640, 2816),
                                          (0x8016BFB8, 0, -768, 608, 4096),
                                          (0x8016BFE8, 0, -864, 800, 5376)):
    offset = source - maindec.MBASE
    expected = (focus_x, 0, 0, pitch, 0, angle, 0, 0, 1024, scale, scale, scale)
    assert struct.unpack_from('<12i', maindec.body(), offset) == tuple(value << 12 for value in expected)

rows=json.loads((ROOT/'kit/data/reports/battle_unite_camera.json').read_text())
assert rows == battle_unite_camera.report()
assert len(rows)==32
assert sum(r['outcome'] == 'proven' for r in rows) == 32
catalogue = json.loads(battle_unite_camera.CATALOGUE.read_text())['records']
import unite_catalogue
from unittest.mock import patch

# Position-vector loads must not masquerade as actor scripts, even at the same offset.
for index in (2,19,20):
    assert unite_catalogue.resource_script_loads(catalogue[index]) == [
        dict(call=0x800F9C68,load=0x800F9C5C,script=10),
        dict(call=0x800F9C9C,load=0x800F9C98,script=10),
    ]
    assert [m['scripts'] for m in catalogue[index]['recovery_source']['members']] == [[10],[10]]
assert maindec.mword(0x800F9F94)==0x8E26002C
assert maindec.mword(0x800F9F9C)==0x0C048DC8
# A nearby pointer is insufficient if another writer or call intervenes.
for middle in (0,0x00003021,0x0C048DC8,0x10400001):
    words={0x80001000:0x8C460028,0x80001004:middle,0x80001008:0x0C038E08,0x8000100C:0}
    with patch.object(unite_catalogue,'word',side_effect=words.__getitem__),patch.object(unite_catalogue,'function_end',return_value=0x80001010):
        actual=unite_catalogue.resource_script_loads(dict(handler=0x80001000,callback_chain=[]))
        assert actual==([dict(call=0x80001008,load=0x80001000,script=10)] if middle==0 else [])
for row, record in zip(rows, catalogue, strict=True):
    assert maindec.mword(0x8016D2D0 + 4*row['unite_id']) == row['initializer']
    assert row['member_scripts']
    assert [script['id'] for script in row['member_scripts']] == record['members']
    for member,selection in zip(row['member_scripts'],record['recovery_source']['members'],strict=True):
        assert member['id']==selection['member']
        assert [s['script'] for s in member['scripts']]==selection['scripts']
        assert all(s['source_offset']>0 and s['byte_length']>0 and s['operations'] for s in member['scripts'])
assert rows[0]['initializer'] == 0x800F9758
assert rows[1]['initializer'] == 0x800F9920
for index,start,update,calls in ((0,0x800F9758,0x800F98A0,(0x800F97E8,0x800F981C)),(1,0x800F9920,0x800F9A68,(0x800F99B0,0x800F99E4))):
    startup=rows[index]['primary_startup']
    assert (startup['selection'],startup['initializer'],startup['first_actor_sweep'],startup['first_callback'])==(0,1,1,2)
    assert startup['units']=='primary_coordinator_updates' and startup['native_mapping']=='selection_clock_verified' and startup['vm_playback']=='pair_primary_and_return_bound'
    for pc in calls:
        assert maindec.mword(pc)==0x0C038E08 and maindec.mword(pc-4)==0x8C460024 and maindec.mword(pc+4)==0x02602821
    instructions=[maindec.mword(pc) for pc in range(start,update,4)]
    assert sum(word==0x0C038E08 for word in instructions)==2
    assert sum(word>>26==0 and word&63==9 for word in instructions)==0
    for member in rows[index]['member_scripts']:
        origin=member['source'];raw=disc.extract(origin['lba'],origin['size'])
        section=struct.unpack_from('<I',raw,36)[0]
        table=struct.unpack_from('<I',raw,section+20)[0]
        clip=struct.unpack_from('<I',raw,table+4*4)[0]
        assert raw[clip+1]&1
        assert raw[clip+4:clip+8]==bytes((0,1,3 if member['id']==6 else 1,13 if index==0 else 11))
    changed=bytearray(maindec.body());changed[start-maindec.MBASE+100]^=1
    try:battle_unite_camera.pair_startup(catalogue[index],battle_unite_camera.Image(bytes(changed),maindec.MBASE))
    except ValueError:pass
    else:raise AssertionError('changed pair initializer accepted')
print('ok   pair initializer dispatches both actors before its first animation/VM sweep; callback starts next primary pass')
assert {row['index'] for row in rows if 'primary_startup' in row}=={0,1,3,4,7,10,11,12,14,18,26,27,29,30,31}
for index in (*battle_unite_camera.STARTUP_ONLY_RECORDS, 30):
    assert rows[index]['primary_startup']['first_actor_sweep']==1
    changed=bytearray(maindec.body());changed[catalogue[index]['handler']-maindec.MBASE+100]^=1
    try:battle_unite_camera.pair_startup(catalogue[index],battle_unite_camera.Image(bytes(changed),maindec.MBASE))
    except ValueError:pass
    else:raise AssertionError('changed startup-only initializer accepted')

# Flash's owner signal gates the entire effect controller, not an ordinary hit.
flash = rows[10]['controller_research']
assert flash['trigger'] == dict(actor='command_owner', signal=16, held_until_completion=True)
assert flash['phase_updates'] == [64,64,64]
assert flash['damage'] == dict(phase=2, zero_based_update=32, count=3, numerator=20)
assert flash['return_at_completed_updates'] == 192 and len(flash['columns']) == 3
assert flash['column_origins'] == [[0,-30,-40],[0,10,-40],[0,30,-40]]
assert {k:v for k,v in flash['column_draws'].items() if k != 'segment_gaps'} == dict(phase=0,first_update=0,last_update=62,angle_step=96,
    angle_argument='signed_state_0x68_shift_right_12_after_decrement')
value = (maindec.mword(0x800FBE48) & 0xffff) << 16
step = (maindec.mword(0x800FBFCC) & 0xffff) - 0x10000
expected = []
for _ in range(63):
    value += step
    expected.append(value >> 12)
assert flash['column_draws']['segment_gaps'] == expected
assert (expected[0],expected[-1]) == (396,203)
for column, slot in zip(flash['columns'], (0,4,8), strict=True):
    assert (column['slot'],column['segments'],column['semitransparent'],column['blend']) == (slot,10,True,'additive')
    assert column['lower'] == dict(radius=800,height=-100,color=[16,16,16])
    assert column['upper'] == dict(radius=0,height=0,color=[80,80,80])
assert flash['admission'] == 'source_research_only'
for member in rows[10]['member_scripts']:
    operations = member['scripts'][0]['operations']
    assert any(op['op'] == 26 and op['args'] == [0,16] for op in operations)
    assert not any(op['op'] == 27 and op['args'][0] == 0 and op['args'][1] & 16 for op in operations)
for pc, words in {
    0x800FBD30: [0xAE00000C,0xAE000010,0x2402FFD8,0xAE020014],
    0x800FBD44: [0xAFB4001C,0xAFB40020,0xAFB40024,0xAFB30028,0xAFB3002C,0xAFB30030],
    0x800FBD74: [0x3404000A,0x8E07000C,0x34050001,0x0C048228,0x34060001],
    0x800FBD94: [0x34050320,0x00003021,0x0C048222,0x2407FF9C],
    0x800FBE48: [0x3C020019,0xAE020068,0xAE050064],
    0x800FBDF0: [0x2402FFE2,0x8E030000,0x00000000,0xAC620020,0x8E030004,0x3402000A,0xAC620020,0x8E030008,0x34040001,0x3402001E,0x0C0473D3,0xAC620020],
    0x800FBF38: [0x96020040,0x80A40B89,0x30420010,0x10400076],
    0x800FBFC4: [0x8E420068,0x8E430020,0x2442CE00,0xAE420068],
    0x800FBFD4: [0x24630001,0xAE430020,0x28630040],
    0x800FC020: [0x24420001,0xAE420020,0x28420040],
    0x800FC048: [0x8E420064,0x8E430020,0x2442C040,0xAE420064],
    0x800FC058: [0x34020020,0x14620004,0x34050003,0x34060014,0x0C03E57A],
    0x800FC078: [0x24420001,0xAE420020,0x28420040],
    0x800FC08C: [0x8E42001C,0x2645002C,0x26460048,0x0C03E4E4],
    0x800FC0D0: [0x94620040,0x00000000,0x24420060,0xA4620040,0x8E450068,0x8E240000,0x0C048512,0x00052B03],
    0x801214A8: [0x8EC3001C,0x00021080,0x00561021,0x8C57000C,0xAFA30060,0x8EC20020,0x00000000,0xAFA20064,0x8EC20024],
}.items():
    assert [maindec.mword(pc+4*i) for i in range(len(words))] == words, hex(pc)
phase = counter = 0
damage = []
for update in range(192):
    if phase == 2 and counter == 32: damage.append(update)
    counter += 1
    if counter == 64: phase, counter = phase+1, 0
assert damage == [160] and (phase,counter) == (3,0)
changed=bytearray(maindec.body());changed[0x800FC064-maindec.MBASE]^=1
try:battle_unite_camera.flash_controller_research(catalogue[10],rows[10]['member_scripts'],battle_unite_camera.Image(bytes(changed),maindec.MBASE))
except ValueError:pass
else:raise AssertionError('changed Flash callback accepted')
changed=bytearray(maindec.body());changed[0x8011D08C-maindec.MBASE]^=1
try:battle_unite_camera.flash_controller_research(catalogue[10],rows[10]['member_scripts'],battle_unite_camera.Image(bytes(changed),maindec.MBASE))
except ValueError:pass
else:raise AssertionError('changed Flash wash helper accepted')
for address,word in {0x8016BB48:0x800E557C,0x800E5634:0x24420006,
    0x800E5638:0xAC62000C,0x800E5640:0x2402FFFF,0x800E3898:0x10400006,
    0x800E38AC:0x08038E21,0x800E37F4:0x0040F809}.items():
    assert maindec.mword(address)==word
for index in (11,12,18):
    assert rows[index]['initializer']==0x800F9758
    assert rows[index]['primary_startup']==rows[0]['primary_startup']
    assert catalogue[index]['recovery_source']['return_script']==0x8016D214
    assert len(rows[index]['member_scripts'])==2
    assert all([s['script'] for s in member['scripts']]==[9] for member in rows[index]['member_scripts'])

# Matcher starts with clear signals; damage consumes hit2, and the return helper
# consumes script-produced ready4 without manufacturing it at impact.
for address,word in {0x800F9300:0xA4E00040,0x800F9374:0xA4600040,
    0x800F954C:0x94640040,0x800F9558:0x3084FFFD,0x800F9560:0xA4640040,
    0x800F93F4:0x30420004,0x800F9414:0x0C038E08,0x800F9444:0x3063FFFB}.items():
    assert maindec.mword(address)==word

with_camera=[r for r in rows if r['members']]
assert [r['index'] for r in with_camera]==[1,2,19,20]
fisherman=with_camera[0]
assert fisherman['index']==1
assert fisherman['name']=='Fisherman attack'
assert fisherman['members']==[{'id':32,'name':'Tai Ho','ops':[{'script':9,'op':20,'args':[2,20,0,0,0]}]}]
for row in with_camera[1:]:
    assert len(row['members'])==1 and row['members'][0]['name']=='Kirkis'
    assert row['members'][0]['ops']==[dict(script=10,op=20,args=[0,20,0,0,0]),dict(script=10,op=19,args=[20,3328,3328,3328]),dict(script=10,op=17,args=[20,-768,0,640])]
print('ok   32 selected-script inventories; Fisherman and Wild arrow camera streams')

# Independent fixed instruction windows: thunks install initializers, which
# install the callbacks containing the actual combined-damage consumer.
for pc, words in {
    0x800FABAC: [0x3c038010, 0x2463abe4, 0xac830018],
    0x800FB1E4: [0x3c038010, 0x2463b210, 0xac830018],
    0x800FC610: [0x3c038010, 0x2463c64c, 0xac830018],
    0x800FAED8: [0x34050002, 0x34060014, 0x0c03e57a],
    0x800FCB50: [0x34050003, 0x34060004, 0x0c03e57a],
}.items():
    assert [maindec.mword(pc + 4*i) for i in range(len(words))] == words
assert maindec.mword(0x800FB314) == 0x34050002
assert maindec.mword(0x800FB31C) == 0x34060014
assert maindec.mword(0x800FB32C) == 0x0c03e57a
# Four group update loops revisit their helper for successive enemy indices.
for pc, expected in [(0x800F9E7C, 0x1040ffe4), (0x800FCB68, 0x1040fff9),
                     (0x800FB824, 0x1040ffea), (0x800FE338, 0x1040fff9)]:
    assert maindec.mword(pc) == expected, hex(pc)

# Independent cursor walk of the selected resource and MAIN return scripts.
import actor_script
import hashlib

# Raw stream cursor and byte hashes are independent of the report's script reader.
# Setter, first-pair consumer, updater and wait consumer establish count-zero timing.
for pc,expected in {
    0x800E2068:0x90420000,0x800E2074:0xA0820001,
    0x800E2090:0x90420001,0x800E20C0:0x90420001,
    0x800E2104:0x0C038847,
    0x800E2164:0x92820002,0x800E2168:0x24630004,
    0x800E2178:0x90440000,0x800E217C:0x90420001,0x800E2184:0xA2820003,
    0x800E2AC0:0x2442FFFF,0x800E2AC4:0xA0820003,
    0x800E2AD8:0x90830001,0x800E2ADC:0x24420001,0x800E2AE0:0x0043102A,
    0x800E2AF4:0x30620001,0x800E2B08:0x00621024,0x800E2B10:0xAC820008,
    0x800E3C10:0x30420002,0x800E3C14:0x14400005,
}.items():
    assert maindec.mword(pc)==expected,hex(pc)
for row in rows:
    for member in row['member_scripts']:
        source=member['source'];raw=disc.extract(source['lba'],source['size'])
        table=struct.unpack_from('<I',raw,32)[0]
        section=struct.unpack_from('<I',raw,36)[0]
        frame_table=struct.unpack_from('<I',raw,section+20)[0]
        durations=[];flags=[];zero_count=[];pairs=[]
        for index in range(struct.unpack_from('<H',raw,section+2)[0]):
            frame=struct.unpack_from('<I',raw,frame_table+4*index)[0]
            count=raw[frame]
            if count==0:
                zero_count.append(dict(animation=index,source_offset=frame,first_pair=list(raw[frame+4:frame+6])))
            durations.append(sum(raw[frame+5+2*k] or 256 for k in range(count or 1)))
            flags.append(raw[frame+1])
            pairs.append([dict(pose=raw[frame+4+2*k],updates=raw[frame+5+2*k] or 256) for k in range(count or 1)])
        assert member['zero_count_animations']==zero_count
        requested=sorted({op['args'][0] for stream in member['scripts'] for op in stream['operations'] if op['op']==4})
        pose_count=struct.unpack_from('<H',raw,section)[0]
        assert member['animation_art']['pose_count']==pose_count
        assert member['animation_art']['animations']==[dict(id=index,flags=flags[index],frames=pairs[index],
            unresolved_poses=sorted({f['pose'] for f in pairs[index] if f['pose']>=pose_count})) for index in requested]
        for selected in member['scripts']:
            start=struct.unpack_from('<I',raw,table+4*selected['script'])[0];cursor=start;operations=[]
            clock=animation_end=movement_end=0;ticks=[];looping=False
            for _ in range(256):
                op=struct.unpack_from('<H',raw,cursor)[0]
                length=1 if op in (0,1,2) else actor_script.OP_LEN_HW[op]
                if op==42:length=2+struct.unpack_from('<H',raw,cursor+2)[0]
                args=list(struct.unpack_from('<'+'h'*(length-1),raw,cursor+2))
                operations.append(dict(op=op,args=args));cursor+=2*length
                ticks.append(clock)
                if op==4:
                    animation_end=clock+durations[args[0]] if flags[args[0]]&1 else clock
                    looping=flags[args[0]]&3==3
                elif op==5:
                    assert not looping,'selected stream waits on a looping animation'
                    clock=max(clock,animation_end)
                elif op==30:clock+=1
                elif op==3:clock+=args[0]
                elif op in (23,33):movement_end=clock+(max(1,args[1]) if op==33 else args[1])
                elif op==21:clock=max(clock,movement_end)
                if op in (0,1,2):break
            else:raise AssertionError('unterminated selected Unite stream')
            assert selected['source_offset']==start and selected['byte_length']==cursor-start
            assert selected['operations']==operations
            assert selected['sha256']==hashlib.sha256(raw[start:cursor]).hexdigest()
            timing=selected['local_timing']
            assert timing==dict(status='actor_local_wait_clocks',duration=clock,operation_ticks=ticks)
            paired_events={14:{2:98,4:143},80:{2:98,4:153},19:{2:96,4:96},29:{2:90,4:90},20:{2:64,4:135},95:{2:64,4:135}}
            if row['index'] in (11,12,18) and selected['script']==9:
                actual={args[1]:at for at,operation in zip(ticks,operations,strict=True) if (args:=operation['args']) and operation['op']==26 and args[0]==0}
                assert actual==paired_events[member['id']]
                if row['index']==18:
                    installer=next(i for i,op in enumerate(operations) if op==dict(op=35,args=[0,4]))
                    animation=next(i for i,op in enumerate(operations) if op==dict(op=4,args=[5]))
                    assert installer<animation and ticks[installer]==ticks[animation]
            requests=[]
            for at,operation in zip(ticks,operations,strict=True):
                op,args=operation['op'],operation['args']
                if op not in (17,18,19,20):continue
                if op==20:
                    mode,updates,x,y,z=args
                    requests.append(dict(at=at,updates=updates,channel='focus',binding=['absolute','actor','target'][mode],target_q12=[x,y,z if mode==0 else 0]))
                else:
                    updates,*vector=args
                    requests.append(dict(at=at,updates=updates,channel={17:'angles',18:'translation',19:'scale'}[op],binding='absolute',target_q12=[v*4096 for v in vector]))
            assert selected['camera_requests']==requests


streams=[s for row in rows for member in row['member_scripts'] for s in member['scripts']]
assert len(streams)==96
assert all(s['local_timing']['status']=='actor_local_wait_clocks' for s in streams)
assert rows[1]['member_scripts'][0]['scripts'][0]['local_timing']['operation_ticks'][12]==62
assert [m['scripts'][0]['local_timing']['duration'] for m in rows[2]['member_scripts']]==[176,176]
assert rows[2]['member_scripts'][0]['scripts'][0]['local_timing']['operation_ticks'][8:11]==[2,2,2]
assert [m['scripts'][0]['local_timing']['duration'] for m in rows[0]['member_scripts']]==[136,131]
# Each return starts from that member's flag, with no all-members-ready prepass.
for pc,expected in {
    0x800F93CC:0x8E040000,0x800F93EC:0x94420040,
    0x800F93F4:0x30420004,0x800F93F8:0x10400016,
    0x800F9414:0x0C038E08,0x800F9444:0x3063FFFB,
    0x800F9450:0xAE420000,0x800F945C:0x0234102A,
    0x800F9460:0x1440FFDA,
    0x800F9728:0x8C820000,0x800F9730:0x14400002,
    0x800F9738:0x00003021,0x800F9744:0x1440FFF8,
    0x800F974C:0x00C01021,0x800F98E0:0x0C03E5C6,
    0x800F98FC:0x02202021,0x800F9900:0x0C030B70,
    0x800F9904:0xAC400018,
}.items():assert maindec.mword(pc)==expected,hex(pc)
import journey_battle
for flags in ([3],[2]):
    if flags==[3]:
        try:journey_battle.script_events([[(0,10)]],[(4,(0,)),(5,())],flags)
        except journey_battle.UnresolvedActorClock:pass
        else:raise AssertionError('looping animation wait must remain unresolved')
    else:assert journey_battle.script_events([[(0,10)]],[(4,(0,)),(5,())],flags)['duration']==0
print('ok   96 dispatched stream clocks; count-zero first pairs and camera boundaries')

# Spawned actors select either the current resource table or the MAIN shared table.
for pc,expected in {0x800E4CD8:0x84560006,0x800E4CDC:0x32820001,
                    0x800E4CEC:0x8E150008,0x800E4CF0:0x8C440030,
                    0x800E4D08:0x26B5C208,0x800E4D30:0xAE150008,
                    0x800E4D34:0x00161080,0x800E4D3C:0x8C420000,
                    0x800E4D44:0xAE02000C}.items():
    assert maindec.mword(pc)==expected,hex(pc)
dependency_count=0
for row in rows:
    for member in row['member_scripts']:
        roots=[]
        for stream in member['scripts']:
            for index,op in enumerate(stream['operations']):
                if op['op']==24:
                    flags,_,script,*_=op['args']
                    roots.append(dict(script=stream['script'],operation=index,child=f"{'member' if flags&1 else 'shared'}:{script}"))
        assert roots==member['auxiliary_spawns']
        definitions={s['id']:s for s in member['auxiliary_scripts']}
        reachable={r['child'] for r in roots}
        for selected in member['auxiliary_scripts']:
            dependency_count+=1
            origin=selected['source'];raw=disc.extract(origin['lba'],origin['size'])
            if selected['resource']=='member':
                assert origin==member['source']
                table=struct.unpack_from('<I',raw,32)[0];adjustment=0
            else:
                assert origin['lba']==17976 and origin['size']==757760
                base=struct.unpack_from('<I',raw,24)[0];adjustment=2048-base;table=0x8016C208+adjustment
            start=struct.unpack_from('<I',raw,table+4*selected['script'])[0]+adjustment
            cursor=start;ops=[]
            for _ in range(256):
                op=struct.unpack_from('<H',raw,cursor)[0]
                count=1 if op in (0,1,2) else actor_script.OP_LEN_HW[op]
                if op==42:count=2+struct.unpack_from('<H',raw,cursor+2)[0]
                args=list(struct.unpack_from('<'+'h'*(count-1),raw,cursor+2));cursor+=2*count
                ops.append(dict(op=op,args=args))
                if op in (0,1,2):break
            else:raise AssertionError('unterminated auxiliary stream')
            assert selected['source_offset']==start and selected['byte_length']==cursor-start
            assert selected['sha256']==hashlib.sha256(raw[start:cursor]).hexdigest()
            assert selected['operations']==ops
            links=[]
            for index,operation in enumerate(ops):
                if operation['op']==24:
                    flags,_,script,*_=operation['args']
                    resource=selected['resource'] if flags&1 else 'shared'
                    links.append(dict(operation=index,child=f'{resource}:{script}'))
            assert selected['spawns']==links
            reachable.update(link['child'] for link in links)
        assert reachable==set(definitions)
assert dependency_count==9
assert {r['index'] for r in rows if any(m['auxiliary_scripts'] for m in r['member_scripts'])}=={3,6,8,17,28,30}
assert all(not a['unresolved_poses'] for row in rows for m in row['member_scripts'] for a in m['animation_art']['animations'])
print('ok   selected animation references and nine auxiliary spawn dependencies')

def has_recovery(data, cursor):
    found = False
    for _ in range(128):
        op = struct.unpack_from('<H', data, cursor)[0]
        if op in (0, 1, 2): return found
        count = actor_script.OP_LEN_HW.get(op)
        if op == 42:
            operands = struct.unpack_from('<h', data, cursor + 2)[0]
            assert operands >= 0
            count = 2 + operands
        assert count and cursor + 2*count <= len(data)
        if op == 40:
            found |= struct.unpack_from('<HH', data, cursor + 2) == (7, 100)
        cursor += 2*count
    raise AssertionError('unterminated source script')

expected_recovery = {1: [True, True], 2: [True, True], 8: [False, False, True],
                     10: [True, True, True], 19: [True, True], 20: [True, True],
                     27: [True, False]}
catalogue_records = json.loads(battle_unite_camera.CATALOGUE.read_text())['records']
for row in rows:
    assert row['recovery'] == expected_recovery.get(row['index'], [False]*len(row['member_scripts']))
    facts = catalogue_records[row['index']]['recovery_source']
    pointer = facts['return_script']
    shared = pointer is not None and has_recovery(maindec.body(), pointer-maindec.MBASE)
    for expected, member in zip(row['recovery'], facts['members'], strict=True):
        source = member['source']
        data = disc.extract(source['lba'], source['size'])
        table = struct.unpack_from('<I', data, 32)[0]
        actual = shared
        for script in member['scripts']:
            offset = struct.unpack_from('<I', data, table + 4*script)[0]
            actual |= has_recovery(data, offset)
        assert actual == expected

# Independent raw f-table reader: no image compositor or producer clock helper.
sequence = catalogue_records[31]['sequence']
assert sequence['finish_delay'] == 40
master = rows[31]['sweep_research']
assert master['target_queue'] == dict(eligibility='active and unlocked at initializer', order='ascending enemy slots',
                                      claim_signal=16, impact_signal=2, target_rechecked_at_impact=True)
assert master['entries'] == [dict(member=0, setup=10, strike=11), dict(member=1, setup=10, strike=11)]
assert master['finish_delay'] == 40 and master['admission'] == 'source_research_only'
footprint = master['footprint']
assert footprint['mode'] == 'axis_aligned_packet' and footprint['initial_angles'] == [0, 0, 0]
assert footprint['source_block_count'] == 35
kai_flash = next(member for member in rows[10]['member_scripts'] if member['id'] == 91)['scripts'][0]
assert kai_flash['script'] == 9 and kai_flash['sha256'] == '0016b067cf96d8438a84b11368c38707c155424777ed27a59ec8a6a0c5a1bc61'
for pc, expected in {0x800E1F2C: 0xA660001C, 0x800E1F30: 0xA660001A,
                     0x800E1F34: 0xA6600018, 0x800E0A54: 0x8E110084,
                     0x800E0B9C: 0x0C03895B, 0x800E3A94: 0x0C038811,
                     0x8016BB80: 0x800F14B4, 0x800F157C: 0x0C03878F,
                     0x800F17E4: 0x0C03895B}.items():
    assert maindec.mword(pc) == expected, hex(pc)
for address in (0x800E1F2C, 0x800E3A94, 0x800F157C, 0x800F17E4, 0x800FBE20):
    changed = bytearray(maindec.body())
    changed[address - maindec.MBASE] ^= 1
    try:
        battle_unite_camera.master_pupil_footprint(rows[31]['member_scripts'], battle_unite_camera.Image(bytes(changed), maindec.MBASE))
    except ValueError:
        pass
    else:
        raise AssertionError('changed Master pupil footprint source accepted')
changed = bytearray(maindec.body())
first = 0x8016BABC + 4*4 - maindec.MBASE
second = 0x8016BABC + 4*5 - maindec.MBASE
changed[first:first+4], changed[second:second+4] = changed[second:second+4], changed[first:first+4]
try:
    battle_unite_camera.master_pupil_footprint(rows[31]['member_scripts'], battle_unite_camera.Image(bytes(changed), maindec.MBASE))
except ValueError:
    pass
else:
    raise AssertionError('swapped Master pupil opcode handlers accepted')
changed = bytearray(maindec.body())
changed[0x800FE944 - maindec.MBASE] ^= 1
try:
    battle_unite_camera.master_pupil_schedule(catalogue_records[31], rows[31]['member_scripts'], battle_unite_camera.Image(bytes(changed), maindec.MBASE))
except ValueError:
    pass
else:
    raise AssertionError('changed Master pupil callback accepted')
for pc, expected in {0x800FE72C: 0x90420045, 0x800FE734: 0x1440000C,
                     0x800FE754: 0x90420005, 0x800FE75C: 0x14400002,
                     0x800FE764: 0xACA6003C, 0x800FE8BC: 0x94620040,
                     0x800FE8C4: 0x30420010, 0x800FE8DC: 0x8E22003C,
                     0x800FE8E4: 0x1448001A, 0x800FE914: 0x8C46002C,
                     0x800FE91C: 0x0C038E08, 0x800FE944: 0xA0500049,
                     0x800FE94C: 0xAE20003C, 0x800FE954: 0x28620007,
                     0x800FE9B0: 0x3042FFEF, 0x800FE9F8: 0x30420002,
                     0x800FEA20: 0x80440049, 0x800FEA24: 0x3406000A,
                     0x800FEA28: 0x0C03E57A, 0x800FEA58: 0x3063FFFD,
                     0x800FEA8C: 0x28620028}.items():
    assert maindec.mword(pc) == expected
for member, expected in zip(sequence['members'], [(54, 92, 117, 46), (48, 94, 119, 46)], strict=True):
    source = member['source']
    data = disc.extract(source['lba'], source['size'])
    section = struct.unpack_from('<I', data, 36)[0]
    count = struct.unpack_from('<H', data, section + 2)[0]
    table = struct.unpack_from('<I', data, section + 20)[0]
    ticks = []
    for i in range(count):
        offset = struct.unpack_from('<I', data, table + 4*i)[0]
        ticks.append(sum(data[offset + 5 + 2*j] or 256 for j in range(data[offset])))
    assert ticks == member['animation_ticks']
    assert tuple(member[k] for k in ('setup_ready', 'impact', 'ready', 'retreat')) == expected
    scripts = struct.unpack_from('<I', data, 32)[0]
    for script_id, event in [(10, 16), (11, 2), (11, 16)]:
        cursor = struct.unpack_from('<I', data, scripts + 4*script_id)[0]
        clock = animation_end = movement_end = 0
        while True:
            op = struct.unpack_from('<H', data, cursor)[0]
            assert op not in (0, 1, 2), 'missing source event'
            length = actor_script.OP_LEN_HW[op]
            args = struct.unpack_from('<' + 'h'*(length-1), data, cursor+2)
            if op == 4: animation_end = clock + ticks[args[0]]
            elif op == 30: clock += 1
            elif op == 3: clock += args[0]
            elif op == 5: clock = max(clock, animation_end)
            elif op in (23, 33): movement_end = clock + args[1]
            elif op == 21: clock = max(clock, movement_end)
            elif op == 26 and args == (0, event): break
            cursor += 2*length
        key = 'setup_ready' if script_id == 10 else 'impact' if event == 2 else 'ready'
        assert clock == member[key]
print('ok   Master pupil shared queue pins and independent actor-local clocks')

# The legacy imported pairs must retain their distinct clocks through native fixtures.
for pc,expected in {0x800F3EC0:0x0C03D1A6,0x800F3ED8:0x00402821,
                    0x800F3EE0:0xAC853420,0x800F4054:0x8C833420,
                    0x800F4068:0xAC830008,0x800F4568:0x8C440008,
                    0x800F456C:0x8C420018,0x800F4574:0x0040F809,
                    0x800F94B0:0x00809821,0x800F94F8:0x94420040,
                    0x800F9500:0x30420002}.items():
    assert maindec.mword(pc)==expected,hex(pc)
from mips_writers import dst_reg_of_word
for start,call in ((0x800F98A0,0x800F98C0),(0x800F9A68,0x800F9A88)):
    assert all(dst_reg_of_word(pc,maindec.mword(pc))!=4 for pc in range(start,call,4))

expected_pairs={6:(67,149,189),2:(75,144,177),32:(82,107,143),38:(82,107,143)}
expected_ready={6:136,2:131,32:91,38:91}
native_ids={6:'pahn',2:'gremio',32:'tai_ho',38:'yam_koo'}
for row in rows[:2]:
    pointer=catalogue_records[row['index']]['recovery_source']['return_script']
    for member in row['member_scripts']:
        source=member['source'];data=disc.extract(source['lba'],source['size'])
        section=struct.unpack_from('<I',data,36)[0];frames=struct.unpack_from('<I',data,section+20)[0]
        clock=animation_end=movement_end=selected_at=0;impact=return_start=ready=None;selected_pairs=[];timed_poses=[]
        for raw,start in ((data,member['scripts'][0]['source_offset']),(maindec.body(),pointer-maindec.MBASE)):
            cursor=start
            for _ in range(256):
                op=struct.unpack_from('<H',raw,cursor)[0]
                if op in (0,1,2):break
                count=actor_script.OP_LEN_HW[op]
                args=struct.unpack_from('<'+'h'*(count-1),raw,cursor+2)
                previous_clock=clock
                if op==4:
                    f=struct.unpack_from('<I',data,frames+4*args[0])[0]
                    assert data[f]>0 and data[f+1]==1
                    selected_at=clock
                    selected_pairs=[(data[f+4+2*k],data[f+5+2*k] or 256) for k in range(data[f])]
                    animation_end=clock+sum(data[f+5+2*k] or 256 for k in range(data[f]))
                elif op==5:clock=max(clock,animation_end)
                elif op==30:clock+=1
                elif op==3:clock+=args[0]
                elif op==23:
                    movement_end=clock+args[1]
                    if args[0]==3:return_start=clock
                elif op==21:clock=max(clock,movement_end)
                elif op==26 and args==(0,2):impact=clock
                elif op==26 and args==(0,4):ready=clock
                for local in range(previous_clock,clock):
                    elapsed=local-selected_at;pose=selected_pairs[-1][0]
                    for candidate,duration in selected_pairs:
                        if elapsed<duration:pose=candidate;break
                        elapsed-=duration
                    timed_poses.append(pose)
                cursor+=2*count
            else:raise AssertionError('unterminated pair track')
        expected=expected_pairs[member['id']]
        assert (impact,return_start,clock)==expected
        assert ready==expected_ready[member['id']]
        assert len(timed_poses)==clock
        for filename in ('journey_battle.json','battle_canonical.json','opening_trial.json'):
            content=json.loads((ROOT/'game/tests/fixtures'/filename).read_text())
            profile=next(p for p in content['party'] if p['id']==native_ids[member['id']])
            track=next(s['track'] for s in profile['unite_scenes'] if s['record']==row['index'])
            motion=track['motion']
            assert tuple(motion[k] for k in ('impact_tick','return_start','duration'))==expected,(filename,profile['id'])
            assert sum(f['ticks'] for f in track['attack'])==clock
            assert motion['ready_tick']==ready
            assert [f['source_pose'] for f in track['attack'] for _ in range(f['ticks'])]==timed_poses
print('ok   independent Talisman/Fisherman tracks, command-owner hit gate and three native fixtures')

assert journey_battle.script_at(b'\x00\x00',0)==[(0,())]
for cursor in (-1,2):
    try:journey_battle.script_at(b'\x00\x00',cursor)
    except ValueError:pass
    else:raise AssertionError('out-of-source script cursor accepted')
# Cast/return exports and catalogue recovery must read MAIN from disc, not the scratch dump.
with patch.object(actor_script,'decode',side_effect=AssertionError('scratch MAIN decoder reached')):
    packet,_=unite_catalogue.collect()
    assert packet==json.loads(battle_unite_camera.CATALOGUE.read_text())
    member=rows[0]['member_scripts'][0];origin=member['source']
    raw=disc.extract(origin['lba'],origin['size'])
    animations,_,_=battle_unite_camera.animation_frames(raw)
    poses,_,_=journey_battle.trial.section_art(raw,struct.unpack_from('<I',raw,36)[0])
    with patch.object(journey_battle.trial,'pack_pose',return_value={'test_pose':True}):
        profile=journey_battle.export_tracks(raw,poses,animations,None,'talisman')
    assert tuple(profile['unite_motion'][key] for key in ('impact_tick','return_start','duration'))==(67,149,189)
print('ok   source exports regenerate with the scratch MAIN decoder disabled')

# Record-keyed tracks retain distinct decoded inputs without falling back to another record.
import copy
sample=dict(unite_attack=[{'test':'first'}],unite_motion={'test':1},unite_camera=[])
journey_battle.bind_unite_scene(sample,0)
sample.update(unite_attack=[{'test':'second'}],unite_motion={'test':2},unite_camera=[])
journey_battle.bind_unite_scene(sample,27)
assert [x['record'] for x in sample['unite_scenes']]==[0,27]
assert [x['track']['motion']['test'] for x in sample['unite_scenes']]==[1,2]
for record in (0,-1,32,False):
    before=copy.deepcopy(sample)
    try:journey_battle.bind_unite_scene(sample,record)
    except ValueError:pass
    else:raise AssertionError('invalid/duplicate scene record accepted')
    assert sample==before


# Independently pinned member-list argument, member read, descriptor read and selector store.
# Columns: initializer, list base, member ordinal, script, and those four instruction addresses.
reaction_routes = [
    (0x800F9758,0,1,15,0x800F97B8,0x800F982C,0x800F9858,0x800F9880),
    (0x800F9920,0,1,15,0x800F9980,0x800F99F4,0x800F9A20,0x800F9A48),
    (0x800F9AE8,72,0,15,0x800F9B40,0x800F9C0C,0x800F9C58,0x800F9C64),
    (0x800FA064,0,0,16,0x800FA0C4,0x800FA0D0,0x800FA0F8,0x800FA114),
    (0x800FA20C,0,0,15,0x800FA26C,0x800FA278,0x800FA2A0,0x800FA2BC),
    (0x800FA3B8,4,0,15,0x800FA3F8,0x800FA408,0x800FA434,0x800FA45C),
    (0x800FA658,4,0,15,0x800FA6B8,0x800FA6CC,0x800FA718,0x800FA724),
    (0x800FC198,0,2,15,0x800FC1F8,0x800FC204,0x800FC22C,0x800FC248),
    (0x800FDAFC,0,2,16,0x800FDB5C,0x800FDB68,0x800FDBAC,0x800FDBBC),
    (0x800FBCB4,44,2,15,0x800FBD2C,0x800FBE60,0x800FBE8C,0x800FBEB4),
    (0x800FB9E4,0,1,15,0x800FBA44,0x800FBA84,0x800FBAB0,0x800FBAD8),
    (0x800FB428,60,1,12,0x800FB474,0x800FB570,0x800FB5B4,0x800FB5C0),
    (0x800FB070,4,0,16,0x800FB0DC,0x800FB140,0x800FB18C,0x800FB198),
    (0x800FD09C,0,1,15,0x800FD104,0x800FD158,0x800FD184,0x800FD1AC),
    (0x800FD2FC,0,1,12,0x800FD35C,0x800FD368,0x800FD3AC,0x800FD3B8),
    (0x800FD7A4,0,0,16,0x800FD804,0x800FD814,0x800FD854,0x800FD864),
    (0x800FE680,4,0,15,0x800FE6CC,0x800FE78C,0x800FE7CC,0x800FE7D8),
]
null_routes={0x800FC438:0x800FC5A8,0x800FA9F4:0x800FAA7C,0x800FCD1C:0x800FCDB8,
             0x800FDE20:0x800FDF58,0x800FE3A8:0x800FE444}
from mips_writers import writer_of
by_initializer={route[0]:route for route in reaction_routes}
shared=next(s for m in rows[17]['member_scripts'] for s in m['auxiliary_scripts'] if s['id']=='shared:0')
for row,record in zip(rows,catalogue_records,strict=True):
    reaction=row['target_reaction'];binding=reaction['binding'];initializer=binding['initializer']
    if initializer in null_routes:
        assert binding==dict(kind='null_shared_helper_reaction',initializer=initializer,store=null_routes[initializer])
        assert maindec.mword(binding['store'])==0xAC20A018
        assert record['gate']=='target_active' and 'operations' not in reaction
        continue
    _,base,ordinal,script,arg,load,descriptor,store=by_initializer[initializer]
    assert (binding['member_list_offset'],binding['member_index'],binding['script'],binding['store'])==(base,ordinal,script,store)
    assert binding['member']==record['members'][ordinal]
    a,b,c,d=[maindec.mword(pc) for pc in (arg,load,descriptor,store)]
    if a>>26==9:
        assert (a>>16)&31==5 and a&65535==base
        state_register=(a>>21)&31
    else:
        assert a>>26==0 and a&63==33 and (a>>11)&31==5 and (a>>16)&31==0
        state_register=(a>>21)&31
        if base:
            alias=writer_of(arg,state_register,reader=maindec.mword)
            assert alias is not None
            w=maindec.mword(alias[0]);assert w>>26==9 and w&65535==base
            state_register=(w>>21)&31
    assert b>>26==35 and (b>>21)&31==state_register and b&65535==base+4*ordinal
    assert c>>26==35 and c&65535==4*script
    assert d>>26==43 and d&65535==0xA018 and (d>>16)&31==(c>>16)&31
    table_load=writer_of(descriptor,(c>>21)&31,reader=maindec.mword)
    assert table_load is not None
    w=maindec.mword(table_load[0]);assert w>>26==35 and w&65535==8
    origin=reaction['source'];raw=disc.extract(origin['lba'],origin['size'])
    provider=next(m for m in row['member_scripts'] if m['id']==binding['member'])
    assert origin==provider['source'] and reaction['animation_context']=='recipient'
    table=struct.unpack_from('<I',raw,32)[0];start=struct.unpack_from('<I',raw,table+4*script)[0]
    cursor=start;clock=movement_end=0;ticks=[];ops=[];roots=[]
    for _ in range(256):
        op=struct.unpack_from('<H',raw,cursor)[0]
        count=1 if op in (0,1,2) else actor_script.OP_LEN_HW[op]
        if op==42:count=2+struct.unpack_from('<H',raw,cursor+2)[0]
        args=list(struct.unpack_from('<'+'h'*(count-1),raw,cursor+2));cursor+=2*count
        ops.append(dict(op=op,args=args));ticks.append(clock)
        assert op!=5,'recipient animation wait must not use provider durations'
        if op==30:clock+=1
        elif op==3:clock+=args[0]
        elif op in (23,33):movement_end=clock+(max(1,args[1]) if op==33 else args[1])+(clock==0)
        elif op==22:movement_end=clock+args[0]+(clock==0)
        elif op==21:clock=max(clock,movement_end)
        elif op==24:
            assert args[0]==0 and args[2]==0
            roots.append(dict(script=script,operation=len(ops)-1,child='shared:0'))
        if op in (0,1,2):break
    else:raise AssertionError('unterminated Unite target reaction')
    assert reaction['source_offset']==start and reaction['byte_length']==cursor-start
    assert reaction['sha256']==hashlib.sha256(raw[start:cursor]).hexdigest()
    assert reaction['operations']==ops
    assert reaction['local_timing']==dict(status='actor_local_wait_clocks',duration=clock,operation_ticks=ticks)
    assert reaction['auxiliary_spawns']==roots
    assert reaction['auxiliary_scripts']==([shared] if roots else [])
assert sum(r['target_reaction']['binding']['kind']=='member_resource' for r in rows)==26
assert rows[0]['target_reaction']['local_timing']['duration']==38
assert rows[1]['target_reaction']['local_timing']['duration']==22
for record,row in zip(catalogue_records,rows):
    reaction=row['target_reaction']; facts=record['target_reaction_source']
    assert facts['binding']==reaction['binding']
    if reaction['binding']['kind']=='null_shared_helper_reaction':
        assert record['target_reaction_updates'] is None
    else:
        assert record['target_reaction_updates']==reaction['local_timing']['duration']
        for key in ('source_offset','byte_length','sha256'):
            assert facts[key]==reaction[key]


# Mutating a member or descriptor read must change the extracted binding, not a lookup table.
for pc,word,key,expected in ((0x800F982C,0x8E230000,'member',6),(0x800F9858,0x8C650040,'script',16)):
    data=bytearray(maindec.body());struct.pack_into('<I',data,pc-maindec.MBASE,word)
    binding=battle_unite_camera.reaction_binding(catalogue_records[0],battle_unite_camera.Image(bytes(data),maindec.MBASE))
    assert binding[key]==expected
for pc,word in ((0x800F97B8,0x26250001),(0x800F9798,0x34040004),(0x800F9880,0xAC25A01C)):
    data=bytearray(maindec.body());struct.pack_into('<I',data,pc-maindec.MBASE,word)
    try:battle_unite_camera.reaction_binding(catalogue_records[0],battle_unite_camera.Image(bytes(data),maindec.MBASE))
    except ValueError:pass
    else:raise AssertionError('unqualified reaction binding accepted')
print('ok   all32 shared-helper reaction selectors, source bytes, local clocks and binding mutations')

# Logic/callbacks precede actor animation, VM flag writes and movement in the outer frame.
for pc,expected in {0x800DE0E0:0x0040F809,0x800DE1C8:0x0C03800D,
                    0x800E0044:0x0C03826F,0x800E0A74:0x0C038AA7,
                    0x800E0A7C:0x0C038D63,0x800E35F8:0x0040F809,
                    0x800E3638:0x0040F809,0x800E5050:0x01031825,
                    0x800E5054:0xA4A30040,0x800F95AC:0x8CC6A018,
                    0x800F95B4:0x0C038E08,0x800F96BC:0x8CC6A018,
                    0x800F96C4:0x10C00003,0x800F96CC:0x0C038E08}.items():
    assert maindec.mword(pc)==expected,hex(pc)
for flag_tick,damage_tick in ((67,68),(75,76),(82,83)):
    ready=False;hit=None
    for frame in range(1,100):
        if ready and hit is None:hit=frame
        if frame==flag_tick:ready=True
    assert hit==damage_tick
print('ok   callback consumes Unite hit flags on the following outer frame')
# Fisherman's callback uses the same return-start completion handoff as Talisman.
for pc,expected in {0x800F9A9C:0x0C03E4E4,0x800F9AA8:0x0C03E5C6,
                    0x800F9AC8:0x0C030B70,0x800F9ACC:0xAC400018}.items():
    assert maindec.mword(pc)==expected,hex(pc)
assert max(expected_ready[m] for m in (6,2))+1==137
assert max(expected_ready[m] for m in (32,38))+1==92
print('ok   Talisman/Fisherman controller handoff and source pose/return-ready clocks')

# Camera integrator precedes actor-script setters; focus operands are already Q12.
for pc,expected in {0x800E003C:0x0C0383A8,0x800E0044:0x0C03826F,
  0x800E44C4:0xACA812C4,0x800E44C8:0xACA912C8,0x800E44D0:0xACAA12CC,
  0x800E450C:0x01031821,0x800E4518:0xACA012CC,0x800E4520:0xACA212C8,
  0x800E4544:0x004B001A,0x800E45A4:0xA46B1324,
  0x800E40EC:0x00021300,0x800E422C:0x00021300,0x800E436C:0x00021300,
  0x800E12F4:0x84821324,0x800E1308:0xA4821324,0x800E1330:0x00431021,
  0x800E1354:0x8C6212C4,0x800E135C:0xAC621294}.items():
    assert maindec.mword(pc)==expected,hex(pc)
assert sum(len(stream['camera_requests']) for stream in streams)==10
for mode,binding in enumerate(('absolute','actor','target')):
    actual=journey_battle.camera_requests([],[(3,(1,)),(20,(mode,20,1,-3,7))])
    assert actual==[dict(at=1,updates=20,channel='focus',binding=binding,target_q12=[1,-3,7 if mode==0 else 0])]
for args in ((3,20,0,0,0),(0,0,0,0,0),(0,-1,0,0,0)):
    try:journey_battle.camera_requests([],[(3,(1,)),(20,args)])
    except ValueError:pass
    else:raise AssertionError('invalid camera request accepted')
print('ok   ten normalized camera requests, raw Q12 units and integrator-before-actor phase')

# Teardown stops the descriptor: shared0 ends before the adjacent shared4 descriptor.
for pc,expected in {0x800E39EC:0xA0400002,0x800E3A0C:0xA2000003,
  0x800E3A34:0x00001021,0x800E3A40:0xAE03000C,0x800E3A44:0x00001021,
  0x800E3640:0x14520004,0x800E3668:0xA4500006,
  0x800E0A50:0x92020003,0x800E0A58:0x10400059}.items():
    assert maindec.mword(pc)==expected,hex(pc)
assert journey_battle.script_at(bytes.fromhex('0200ffff'),0)==[(2,())]
assert maindec.mword(0x8016C208+4*4)-maindec.mword(0x8016C208)==12
assert shared['byte_length']==12 and [op['op'] for op in shared['operations']]==[25,5,2]
print('ok   shared impact descriptor ends at teardown; adjacent movement is excluded')

# The gate's actor argument is not universally the first member or the command owner.
callback_gates={0,1,3,11,12,18}
member_gates={4:0,5:3,7:2,8:1,13:1,21:3,22:3,23:3,24:3,26:1,27:1,28:1}
for row in rows:
    gate=row['hit_gate']
    record=catalogue_records[row['index']]
    expected_actor=(dict(kind='command_owner',member=None) if row['index'] in callback_gates else
                    dict(kind='member',member=member_gates[row['index']]) if row['index'] in member_gates else None)
    assert record['hit_actor']==expected_actor
    assert record['hit_gate_source']==gate
    if row['index'] in callback_gates:
        assert gate['kind']=='callback_actor'
    elif row['index'] in member_gates:
        index=member_gates[row['index']]
        assert gate['kind']=='member' and gate['member_index']==index and gate['member']==row['member_scripts'][index]['id']
    else:
        assert gate==dict(kind='target_active')
for pc,word in {0x800F92FC:0xACC80000,0x800F9310:0x24C60004,
                0x800F94F8:0x94420040,0x800F9500:0x30420002,
                0x800FA350:0x8E240000,0x800FA5DC:0x8E440010,
                0x800FA5E8:0x26500004,0x800FC398:0x8E640008,
                0x800FDDB0:0x8E240004,0x800FBC44:0x8E240004,
                0x800FD214:0x8E240004,0x800FD6E8:0x8E840004,
                0x800FDA8C:0x8E240004}.items():
    assert maindec.mword(pc)==word,hex(pc)
mutated=bytearray(maindec.body())
struct.pack_into('<I',mutated,0x800FA5DC-maindec.MBASE,0x8E440000)
try:battle_unite_camera.hit_gate_binding(catalogue_records[5],battle_unite_camera.Image(bytes(mutated),maindec.MBASE))
except ValueError:pass
else:raise AssertionError('out-of-list hit actor accepted')
print('ok   six callback-actor, twelve fixed-member and fourteen target-active hit selectors')


# Independent callback counter arithmetic and raw resource-pointer walks.
blacksmiths={5,21,22,23,24}
assert {r['index'] for r in rows if r['callback_schedule'] is not None}==blacksmiths
for pc,word in {0x800FA3FC:0xAE000000,0x800FA4A0:0x3402002D,
                0x800FA4A4:0x00C2001A,0x800FA4CC:0x00003812,0x800FA4D0:0x00002810,
                0x800FA4F8:0x14A00012,0x800FA500:0x28C20088,0x800FA504:0x1040000F,
                0x800FA510:0x8C440004,0x800FA538:0x8C460024,0x800FA540:0x02802821,
                0x800FA550:0x24420001,0x800FA554:0xAE420000,
                0x800FA580:0x30420002,0x800FA584:0x10400012,
                0x800FA594:0x8C46003C,0x800FA59C:0x02802021,
                0x800FA5C8:0x3063FFFD,0x800FA5CC:0xA4430040,
                0x800FA5D0:0x2A220003,0x800FA5D4:0x1440FFE0,0x800FA5D8:0x26100004,
                0x800FA5DC:0x8E440010,0x800FA5EC:0x0C03E522,
                0x800FA600:0x0C03E4E4,0x800FA60C:0x0C03E5C6}.items():
    assert maindec.mword(pc)==word,hex(pc)
expected_dispatches=[]
for counter in range(200):
    quotient,remainder=divmod(counter,45)
    if remainder==0 and counter<136:
        expected_dispatches.append(dict(member=quotient,script=9,callback_counter=counter))
for row in rows:
    if row['index'] not in blacksmiths:continue
    schedule=row['callback_schedule']
    assert schedule['dispatches']==expected_dispatches
    assert schedule['counter_origin']=='first_callback'
    assert schedule['combined_damage_member']==3 and schedule['return_dispatch']=='each_member_ready_flag'
    assert [a['member'] for a in schedule['assists']]==[0,1,2]
    for assist in schedule['assists']:
        provider=row['member_scripts'][assist['member']]
        assert assist['source']==provider['source']
        assert assist['script']==15 and assist['trigger']=='hit_flag'
        assert assist['clear_hit_flag'] and not assist['commits_damage']
        assert assist['reaction_record']==row['index']
        raw=disc.extract(assist['source']['lba'],assist['source']['size'])
        table=struct.unpack_from('<I',raw,32)[0]
        start=struct.unpack_from('<I',raw,table+60)[0]
        cursor=start;operations=[]
        for _ in range(256):
            opcode=struct.unpack_from('<H',raw,cursor)[0]
            count=1 if opcode in (0,1,2) else actor_script.OP_LEN_HW[opcode]
            operands=list(struct.unpack_from('<'+'h'*(count-1),raw,cursor+2))
            cursor+=count*2;operations.append(dict(op=opcode,args=operands))
            if opcode in (0,1,2):break
        else:raise AssertionError('unterminated Blacksmith assist descriptor')
        assert assist['source_offset']==start and assist['byte_length']==cursor-start
        assert assist['sha256']==hashlib.sha256(raw[start:cursor]).hexdigest()
        assert operations==row['target_reaction']['operations']
        assert assist['sha256']=='dcfb27de5694de4505f355f51fc29d0a3016b48af5015df3233060b114d5c885'
for address,value in ((0x800FA4A0,0x3402002E),(0x800FA500,0x28C20087),
                      (0x800FA594,0x8C460038),(0x800FA5D0,0x2A220004),
                      (0x800FA5CC,0xA4400040)):
    modified=bytearray(maindec.body());struct.pack_into('<I',modified,address-maindec.MBASE,value)
    row=rows[5]
    try:battle_unite_camera.blacksmith_schedule(catalogue_records[5],row['member_scripts'],row['target_reaction'],battle_unite_camera.Image(bytes(modified),maindec.MBASE))
    except ValueError:pass
    else:raise AssertionError(f'invalid Blacksmith callback accepted at {address:#x}')
print('ok   all five Blacksmith stagger schedules, fifteen byte-identical assist descriptors and callback mutations')


def blacksmith_reference_clocks(raw, primary_script=9, return_source=0x8016D214, events_out=None):
    section=struct.unpack_from('<I',raw,36)[0]
    frames=struct.unpack_from('<I',raw,section+20)[0]
    scripts=struct.unpack_from('<I',raw,32)[0]
    primary=struct.unpack_from('<I',raw,scripts+primary_script*4)[0]
    clock=animation_end=movement_end=0;events={};trail=[];offsets=[];trail_pose=None
    streams=[(raw,primary)]
    if return_source is not None:streams.append((maindec.body(),return_source-maindec.MBASE))
    for data,start in streams:
        cursor=start
        for _ in range(256):
            opcode=struct.unpack_from('<H',data,cursor)[0]
            assert opcode in (0,3,4,5,9,13,14,15,16,17,19,20,21,23,24,26,30,34,35,38,39,40,43)
            count=1 if opcode==0 else actor_script.OP_LEN_HW[opcode]
            args=struct.unpack_from('<'+'h'*(count-1),data,cursor+2);cursor+=count*2
            if opcode==4:
                animation=struct.unpack_from('<I',raw,frames+args[0]*4)[0]
                assert raw[animation+1]&3!=3
                duration=sum(raw[animation+5+2*i] or 256 for i in range(raw[animation] or 1))
                animation_end=clock+duration if raw[animation+1]&1 else clock
            elif opcode==3:clock+=args[0]
            elif opcode==5:clock=max(clock,animation_end)
            elif opcode==23:movement_end=clock+args[1]
            elif opcode==21:clock=max(clock,movement_end)
            elif opcode==26:events[args[1]]=clock
            elif opcode==35:
                assert args==(0,4)
                trail.append(clock)
                trail_pose=raw[animation+4]
            elif opcode==30:
                if args==(99,):trail.append(clock)
                clock+=1
            elif opcode==43:
                assert args[0] in (0,2) and clock<movement_end
                offsets.append(dict(start=clock,updates=movement_end-clock,target=args[0]==2,value=list(args[1:])))
            if opcode==0:break
        else:raise AssertionError('unterminated Blacksmith primary/return descriptor')
    if events_out is not None:events_out.update(events)
    return events.get(2),events.get(4),clock,trail,trail_pose,offsets

expected_clocks={70:(73,77,123),72:(73,77,123),69:(73,77,123),71:(74,78,124),5:(72,77,126)}
for row in rows:
    schedule=row['callback_schedule']
    if schedule is None:continue
    assert schedule['return_source']==0x8016D214
    for index,member in enumerate(row['member_scripts']):
        raw=disc.extract(member['source']['lba'],member['source']['size'])
        hit,ready,end,trail,trail_pose,offsets=blacksmith_reference_clocks(raw)
        assert (hit,ready,end)==expected_clocks[member['id']]
        assert trail==[14,44]
        assert schedule['member_clocks'][index]==dict(member=index,start_after=45*index,
            local_hit_flag=hit,local_ready_flag=ready,local_track_end=end,
            trail_start=trail[0],trail_stop=trail[1],trail_animation=5,trail_pose=trail_pose)
        assert trail_pose==4
        animations,_,_=battle_unite_camera.animation_frames(raw)
        operations=journey_battle.script(raw,9)+journey_battle.script_at(maindec.body(),0x8016D214-maindec.MBASE)
        assert journey_battle.screen_offsets(animations,operations)==offsets
        assert offsets==[dict(start=34,updates=10,target=True,value=[0,0]),
                         dict(start=91 if member['id']==71 else 90,updates=20,target=False,value=[0,0])]
print('ok   twenty Blacksmith primary/return clocks from independent raw instruction and F-table walks')

# The descriptor installs a real eight-node helper, not a timing-only marker.
for row in rows:
    if row['index'] not in blacksmiths:continue
    trail=row['callback_schedule']['trail']
    assert trail['source']==struct.unpack_from('<I',maindec.body(),0x8016BB80-maindec.MBASE)[0]==0x800F14B4
    assert (trail['nodes'],trail['ring_updates'])==(8,8)
    assert trail['callback_phase']=='actor_vm_tail' and trail['invocation']==0x800E37F4
    assert trail['capture']=='actor_screen_position_and_flags'
    assert trail['pose']=='allocation_animation_first_pair'
    assert trail['position_phase']=='before_current_actor_projection'
    assert trail['blend']=='average'
    assert trail['initial_slots']=='allocation_actor_screen_position'
    assert (trail['first_draw_after_enable'],trail['last_draw_before_stop'],trail['cleanup_after_stop'])==(1,1,1)
    assert maindec.mword(0x800E37DC)==0x8C420054
    assert maindec.mword(0x800E37F4)==0x0040F809
    assert trail['full_ring_rgb_newest_first']==[
        [255,255,255],[218,218,255],[182,182,255],[145,145,255],
        [109,109,255],[72,72,255],[36,36,255],[0,0,255]]
    assert (trail['stop_value'],trail['teardown_value'])==(99,100)
    assert trail['playback']=='source_inventory_only'
for address,value in ((0x8016BB80,0),(0x800F1668,0x2A220007),
                      (0x800F17E8,0xA0600006),(0x800F1958,0)):
    changed=bytearray(maindec.body());struct.pack_into('<I',changed,address-maindec.MBASE,value)
    try:battle_unite_camera.blacksmith_trail(battle_unite_camera.Image(bytes(changed),maindec.MBASE))
    except ValueError:pass
    else:raise AssertionError('changed Blacksmith trail accepted')
print('ok   Blacksmith eight-node blue trail, local descriptor lifetime and changed-helper guards')

# Allocation sets animation pair zero; the complete helper call set contains
# no later animation updater. Projection runs after the VM/helper call.
calls=[]
for address in range(0x800F14B4,0x800F1994,4):
    word=maindec.mword(address)
    if word>>26==3:calls.append((address,(address&0xF0000000)|((word&0x3FFFFFF)<<2)))
    assert word&0xFC00003F != 9  # no indirect callee hidden in this helper
assert calls==[(0x800F1550,0x800C2D30),(0x800F157C,0x800E1E3C),
               (0x800F17E4,0x800E256C),(0x800F18BC,0x800E256C),
               (0x800F191C,0x800E2B3C),(0x800F194C,0x800C2DC0)]
for address,expected in {0x800F1578:0x90450000,0x800E1F50:0x0C038811,
                         0x800E206C:0xA0800002,0x800E2104:0x0C038847,
                         0x800E2178:0x90440000,0x800E21A4:0xAE820024,
                         0x800E25A0:0x8E530024,0x800F16DC:0xACA30008,
                         0x800E0A7C:0x0C038D63,0x800E0B54:0x0C038209,
                         0x800E0954:0xAE050008,0x800F1514:0x10620064,
                         0x800F1524:0x1060000A,0x800F15A8:0xAC430008,
                         0x800F16A0:0x0803C657,0x800F18FC:0x96020042,
                         0x800E2254:0x00002821,0x800E2294:0x0C052AC3,
                         0x800E2994:0x30420004,0x800E299C:0x34050001,
                         0x800E29DC:0x0C052B7A}.items():
    assert maindec.mword(address)==expected
print('ok   allocation pose4 retained; screen-position capture precedes current projection')


# One existing track compiler handles all Blacksmith resource/record bindings.
from export_first_room import Atlas
from export_battle_trial import section_art
cast_ops=journey_battle.script_at(maindec.body(),0x8016C194-maindec.MBASE)
return_ops=journey_battle.script_at(maindec.body(),0x8016D214-maindec.MBASE)
blacksmith_atlas=Atlas();compiled={}
for row in rows:
    if row['callback_schedule'] is None:continue
    for member in row['member_scripts']:
        if member['id'] in compiled:continue
        raw=disc.extract(member['source']['lba'],member['source']['size'])
        operations=journey_battle.script(raw,9)
        selected=sorted({args[0] for op,args in operations+cast_ops+return_ops if op==4})
        poses,animations,_=section_art(raw,struct.unpack_from('<I',raw,36)[0],animation_indices=selected)
        with patch.object(journey_battle,'script_at',wraps=journey_battle.script_at) as reader:
            track=journey_battle.export_tracks(raw,poses,animations,blacksmith_atlas,'blacksmith')
        assert reader.call_args.args[1]==0x8016D214-maindec.MBASE
        motion=track['unite_motion'];expected=expected_clocks[member['id']]
        assert (motion['impact_tick'],motion['ready_tick'],motion['duration'])==expected
        assert sum(f['ticks'] for f in track['unite_attack'])==expected[2]
        assert all(f['source_pose'] is not None for f in track['unite_attack'])
        compiled[member['id']]=track
for row in rows:
    if row['callback_schedule'] is None:continue
    for ordinal,member in enumerate(row['member_scripts']):
        track=copy.deepcopy(compiled[member['id']]);journey_battle.bind_unite_scene(track,row['index'],45*ordinal,reaction_on_hit=ordinal<3)
        assert track['unite_scenes'][0]['track'].get('start_after',0)==45*ordinal
        assert track['unite_scenes'][0]['track'].get('reaction_on_hit',False)==(ordinal<3)
        assert track['unite_scenes'][0]['record']==row['index']
        assert track['unite_scenes'][0]['track']['motion']['duration']==expected_clocks[member['id']][2]
try:journey_battle.export_tracks(b'',[],[],None,'unknown-unite')
except ValueError:pass
else:raise AssertionError('unbound return family accepted')
print('ok   shared member compiler binds all twenty Blacksmith tracks from five distinct resources')

for invalid in (-1,True,900,1001):
    track=copy.deepcopy(compiled[70]);before=copy.deepcopy(track)
    try:journey_battle.bind_unite_scene(track,5,invalid)
    except ValueError:pass
    else:raise AssertionError('invalid member start accepted')
    assert track==before

track=copy.deepcopy(compiled[70]);before=copy.deepcopy(track)
try:journey_battle.bind_unite_scene(track,5,reaction_on_hit=1)
except ValueError:pass
else:raise AssertionError('invalid reaction binding accepted')
assert track==before

# Offset baseline writer, owner/self selectors, Q12 destination and signed-byte
# interpolation consumers are separate from the exporter's script clock walk.
for address,expected in {0x800DEF00:0x80460004,0x800DEF1C:0x8C43000C,
                        0x800DEF20:0x00061080,0x800DEF28:0x8C510000,
                        0x800DED2C:0xA6000074,0x800DED30:0xA6000076,
                        0x800DF088:0x9622003C,0x800DF090:0xA6020074,
                        0x800DF094:0x9622003E,0x800DF09C:0xA6020076,
                        0x800E5780:0x84430074,0x800E5784:0x84420076,
                        0x800E57BC:0xAC430038,0x800E57D0:0xAC45003C,
                        0x800E3698:0x830C0078,0x800E36A4:0x0082001A,
                        0x800E36E4:0x0062001A,0x800E3784:0xA30C0078,
                        0x800E3790:0xA30B0079,0x800E37B8:0xA3020078,
                        0x800E37C0:0xA3030079}.items():
    assert maindec.mword(address)==expected
for operations in ([(43,(2,0,0))],[(23,(2,10,0,0,0,0,0,0)),(43,(1,0,0))]):
    try:journey_battle.screen_offsets([],operations)
    except ValueError:pass
    else:raise AssertionError('unbound screen offset accepted')
for address,value in ((0x800E5780,0x84430076),(0x800E36A4,0x0082001B)):
    changed=bytearray(maindec.body());struct.pack_into('<I',changed,address-maindec.MBASE,value)
    row=rows[5]
    try:battle_unite_camera.blacksmith_schedule(catalogue_records[5],row['member_scripts'],row['target_reaction'],battle_unite_camera.Image(bytes(changed),maindec.MBASE))
    except ValueError:pass
    else:raise AssertionError('changed screen-offset semantics accepted')
print('ok   screen-offset baseline/writer/consumer bindings and invalid-source guards')

# The primary slot's reader and writer address the same entry even though the
# dispatcher passes index+1. This is a source address calculation, not execution.
def source_s16(value):
    return value-65536 if value&32768 else value
read_base=0x80180000+source_s16(maindec.mword(0x800DE0D0)&65535)
write_base=0x80180000+source_s16(maindec.mword(0x800F43B4)&65535)
for index in range(4):
    assert read_base+4*index==write_base+4*(index+1)
for address,expected in {0x800DE0D8:0x8C220000,0x800DE0E0:0x0040F809,
                        0x800DE0E4:0x26040001,0x800DE1C8:0x0C03800D,
                        0x800F436C:0x0C03D5E4,0x800F4384:0x1060000F,
                        0x800F4390:0x24424550,0x800F43BC:0xAC220000,
                        0x800F5914:0x90420019,0x800F592C:0x8C230000,
                        0x800F593C:0xAC830018,0x800F456C:0x8C420018,
                        0x800F4574:0x0040F809,0x800F4580:0x1043000C,
                        0x800FA448:0x2402FFFF,0x800FA450:0x2463A478,
                        0x800FA454:0xAC830018}.items():
    assert maindec.mword(address)==expected
for row in rows:
    if row['index'] not in blacksmiths:continue
    startup=row['callback_schedule']['startup']
    assert startup['units']=='primary_coordinator_updates'
    assert (startup['selection'],startup['initializer'],startup['first_callback'])==(0,1,2)
    assert startup['initializer_to_callback']==1
    assert startup['entry']==maindec.mword(0x8016D2D0+4*row['unite_id'])==0x800FA3B8
    assert startup['callback']==0x800FA478 and startup['native_mapping']=='selection_clock_verified'
# Each coordinator/wrapper invocation has one indirect dispatch. The initializer
# installs its successor and returns pending; it does not recurse into the wrapper.
for start,end,expected in ((0x800DE0B0,0x800DE1EC,[0x800DE0E0]),
                           (0x800F4550,0x800F45C8,[0x800F4574]),
                           (0x800FA3B8,0x800FA478,[]),
                           (0x800F91C0,0x800F9390,[]),
                           (0x800F96F8,0x800F9718,[])):
    assert [pc for pc in range(start,end,4) if maindec.mword(pc)>>26==0 and maindec.mword(pc)&63==9]==expected
for address,value in ((0x800F4580,0),(0x800FA448,0x00001021),
                      (0x800F593C,0xAC830014),(0x800F4390,0x244244D8)):
    changed=bytearray(maindec.body());struct.pack_into('<I',changed,address-maindec.MBASE,value)
    try:battle_unite_camera.blacksmith_startup(catalogue_records[5],battle_unite_camera.Image(bytes(changed),maindec.MBASE))
    except ValueError:pass
    else:raise AssertionError('changed Blacksmith startup accepted')
print('ok   Blacksmith primary-slot selection/init/callback stages and changed-source guards')

# Three-member callbacks select explicit assist variants and retain their source order.
for index,selected,after in ((4,[],False),(7,[0,1],False),(26,[0],True)):
    assist=rows[index]['direct_assists']
    assert [a['member'] for a in assist['assists']]==selected
    assert assist['after_damage']==after
    assert all(a['variant']==1 and a['reaction']['local_timing']['duration']==22 for a in assist['assists'])
    image=battle_unite_camera.Image()
    changed=bytearray(image.data)
    changed[rows[index]['update']-image.base+12]^=1
    image.data=bytes(changed)
    try:battle_unite_camera.direct_assists(catalogue[index],rows[index]['member_scripts'],image)
    except ValueError:pass
    else:raise AssertionError('Modified direct callback accepted')

# Independent raw stream/F-table clocks above put all Elf births at66. The first
# child poll shares that update, so the pinned48-poll miss lifetime ends at113.
for member in rows[3]['member_scripts']:
    script=member['scripts'][0]
    assert [(tick,op['args']) for tick,op in zip(script['local_timing']['operation_ticks'],script['operations']) if op['op']==24]==[(66,[11,17,9,-20,0,-20])]

# Elf dispatch selects script11 before sweep1; its callback uses the command owner.
for pc,word in {0x800FA140:0x8C46002C,0x800FA148:0x0C038E08,
                0x800FA1A4:0x34050003,0x800FA1A8:0x34060014,0x800FA1AC:0x0C03E522}.items():
    assert maindec.mword(pc)==word,hex(pc)
for member in rows[3]['member_scripts']:
    raw=disc.extract(member['source']['lba'],member['source']['size'])
    hit,ready,end,trail,pose,offsets=blacksmith_reference_clocks(raw,11)
    assert (hit,ready,end,trail)==(None,151,173,[2,22])
changed=bytearray(maindec.body());changed[0x800FA1AC-maindec.MBASE]^=1
try:battle_unite_camera.direct_assists(catalogue[3],rows[3]['member_scripts'],battle_unite_camera.Image(bytes(changed),maindec.MBASE))
except ValueError:pass
else:raise AssertionError('Changed Elf damage callback accepted')

phase=rows[28]['phase_schedule']
assert phase['entries']==[dict(member=0,script=13),dict(member=1,script=10),dict(member=2,script=10)]
assert phase['transition']==dict(trigger_member=0,signal=16,dispatches=[dict(member=1,script=11),dict(member=2,script=11)])
assert phase['embedded_returns'] and phase['admission']=='native_vm_scene_bound_visual_acceptance_pending'
for address,word in {0x800FD850:0x8C460034,0x800FD898:0x8C460028,0x800FD8CC:0x8C460028,
    0x800FD85C:0xAC20A020,0x800FD970:0x30420010,0x800FD9A4:0x8C46002C,
    0x800FD9D8:0x8C46002C,0x800FDA0C:0x3063FFEF,0x800F940C:0x10C00003}.items():
    assert maindec.mword(address)==word,hex(address)
assert phase['assist']['callback']['slot']==8
assert [c['state'] for c in phase['assist']['callback']['cases']]==[0,1,2,3,5,7,99]
assert phase['assist']['auxiliary_scripts'][0]['operations']==[dict(op=5,args=[]),dict(op=2,args=[])]
for address in (0x800FD7A4,0x800FD9A8,0x800F3544,0x800C125C,0x800E003C,0x800E37F4,0x800E1330,0x800E1354,0x8016C23C,0x8016C200,0x8016BABC,0x800E38F0):
    changed=bytearray(maindec.body());changed[address-maindec.MBASE]^=1
    try:battle_unite_camera.ninja_phase_schedule(catalogue[28],rows[28]['member_scripts'],battle_unite_camera.Image(bytes(changed),maindec.MBASE),phase['source'])
    except ValueError:pass
    else:raise AssertionError(f'Changed Ninja source accepted at {address:#x}')

# A second decoder walks Kasumi15 directly, independently of journey_battle's
# descriptor reader and clock helper. This selected callback path adds no waits.
raw=disc.extract(phase['assist']['source']['lba'],phase['assist']['source']['size'])
table=struct.unpack_from('<I',raw,32)[0]
cursor=struct.unpack_from('<I',raw,table+15*4)[0]
operand_counts={0:0,3:1,4:1,14:1,15:2,16:2,21:0,23:8,24:6,26:2,30:1,35:2,38:0,39:0}
decoded=[];ticks=[];clock=movement_end=0
while True:
    op=struct.unpack_from('<H',raw,cursor)[0]
    count=operand_counts[op]
    args=struct.unpack_from('<'+'h'*count,raw,cursor+2)
    decoded.append(dict(op=op,args=list(args)));ticks.append(clock)
    cursor+=2+2*count
    if op==0:break
    if op==3:clock+=args[0]
    elif op==23:movement_end=clock+args[1]
    elif op==21:clock=max(clock,movement_end)
    elif op==30:clock+=1
assert decoded==phase['assist']['operations']
assert phase['assist']['local_timing']==dict(status='actor_local_wait_clocks',duration=134,operation_ticks=ticks)
assert ticks==[0,0,0,0,0,10,10,30,60,61,61,61,101,102,102,102,102,117,118,133,133,134]
binding=phase['assist']['recipient_binding']
assert binding['terminal']=='retain_current_pose_and_absolute_position_until_replaced'
assert binding['camera_preserves']=='focus_target_and_xy_velocity'
assert binding['motions']==[
    dict(at=10,updates=20,binding='absolute',destination_q12=[0,0,-400*4096],velocity_q12=[0,0,-8*2048]),
    dict(at=61,updates=40,binding='absolute',destination_q12=[0,0,0],velocity_q12=[0,0,0])]
assert binding['flip']==dict(start=61,stop=117,angles=[0,2048,2048],
    screen_offset='recipient_current_attachment_y_minus_anchor_y',offset_arithmetic='signed_byte_wrap',reset_offsets=[0,0])
assert binding['callback_states']==[dict(at=t,state=s) for t,s in ((61,0),(101,1),(102,2),(103,3),(104,4),(117,99))]
# Inspect all100 entries, including idle states. No5/7 is selected by this script.
active={0:0x800F35B0,1:0x800F35F0,2:0x800F3608,3:0x800F35F8,
        5:0x800F3634,7:0x800F375C,99:0x800F3830}
assert [maindec.mword(0x800C125C+4*i) for i in range(100)]==[active.get(i,0x800F3868) for i in range(100)]
for address,word in {0x800F35C8:0x90C30007,0x800F35CC:0x90C40005,
    0x800F35D4:0x00641823,0x800F35D8:0xA0430079,0x800F35DC:0x34030800,
    0x800F35E0:0xA4A3001C,0x800F35EC:0xA443001A,
    0x800F35FC:0xAD0212FC,0x800F3604:0xA5021324,
    0x800F384C:0xA0400078,0x800F3850:0xA0400079,
    0x800F3854:0xA460001C,0x800F3860:0xA460001A,0x800F3864:0xAC400054}.items():
    assert maindec.mword(address)==word,hex(address)
positive=maindec.mword(0x800F35F4)&65535
negative=(maindec.mword(0x800F35F8)&65535)-65536
assert (positive,negative)==(5*4096,-5*4096)
assert binding['camera_pulses']==[dict(at=t,channel='focus',delta_q12=[0,0,v],updates=1) for t,v in ((101,positive),(103,negative))]
# Timer1 integrates on the next update, timer0 then restores the existing target.
focus=target=timer=delta=0;observed={}
for tick in range(101,107):
    if timer:timer-=1;focus+=delta
    else:focus=target
    observed[tick]=focus
    if tick in (101,103):delta=positive if tick==101 else negative;timer=1
assert observed=={101:0,102:20480,103:0,104:-20480,105:0,106:0}
assert binding['impact']==dict(at=102,animation=0,child=13,offset=[5,5,0],centered=False)
print('ok   independent Ninja recipient clocks, absolute jumps, flip, camera pulses and uncentered impact')

for record in (2,19,20):
    row=rows[record];group=row['group_schedule']
    assert group['damage_member']==1 and group['assist_member']==0 and group['reaction_group']
    assert group['startup']['first_actor_sweep']==1 and group['admission']=='native_vm_scene_bound_visual_acceptance_pending'
    assert len(group['constructors']['objects'])==10 and not group['constructors']['blocked']
    assert [o['indices'] for o in group['constructors']['objects']]==[[m,i] for m in range(2) for i in range(5)]
    for member,fan in zip(row['member_scripts'],group['fans'],strict=True):
        assert fan['rolls']==[340,170,0,-170,-340] and fan['velocity_q12']==[-49152,0,0]
        assert fan['node_angles']==[0,0,400] and fan['anchor_z']==-40 and fan['trigger_signal']==16
        raw=disc.extract(member['source']['lba'],member['source']['size'])
        section=struct.unpack_from('<I',raw,36)[0];table=struct.unpack_from('<I',raw,section+20)[0]
        frame=struct.unpack_from('<I',raw,table+17*4)[0]
        assert raw[frame:frame+6]==bytes((1,1,1,0,10,1))
        events={}
        hit,ready,end,trail,_,_=blacksmith_reference_clocks(raw,10,0x8016D258,events)
        assert events[16]==(66 if member["id"]==4 else 81 if member["id"]==51 else 86)
        expected=(86,176,198) if member['id']==4 else (101,164,186) if member['id']==51 else (106,176,198)
        assert (hit,ready,end)==expected and trail==[2,22]
    for address in (0x800F9B98,0x800F9E68,0x8012346C,0x80123894,0x800E2870):
        changed=bytearray(maindec.body());changed[address-maindec.MBASE]^=1
        try:battle_unite_camera.wild_arrow_schedule(catalogue[record],row['member_scripts'],battle_unite_camera.Image(bytes(changed),maindec.MBASE))
        except ValueError:pass
        else:raise AssertionError(f'Changed Wild Arrow source accepted at {address:#x}')
for address,word in {0x800F9B90:0x34050011,0x800F9B94:0x34060030,0x800F9BE4:0x2A420005,
    0x800F9BF4:0x2A620002,0x800F9E18:0x10620016,0x800F9E20:0x16540010,
    0x800F9E50:0x8C46003C,0x800F9E64:0x34050002,0x800F9E68:0x3406000A,
    0x800F9E6C:0x0C03E57A,0x800F9EAC:0x3042FFFD,0x800F9F00:0x30420010,
    0x800F9F7C:0x00431021,0x800F9F9C:0x0C048DC8}.items():assert maindec.mword(address)==word,hex(address)
print('ok   all three Wild Arrow controllers, ten fan constructors, raw clocks and changed-source refusal')

kasumi=rows[28]['member_scripts'][0]['scripts'][0]
assert kasumi['local_timing']['duration']==192
assert [(t,o['args']) for t,o in zip(kasumi['local_timing']['operation_ticks'],kasumi['operations']) if o['op']==9]==[(159,[0])]
assert [(t,o['args']) for t,o in zip(kasumi['local_timing']['operation_ticks'],kasumi['operations']) if o['op']==26]==[(57,[0,2]),(159,[0,16]),(159,[0,4])]
for member in rows[28]['member_scripts'][1:]:
    staging,attack=member['scripts']
    assert (staging['script'],staging['local_timing']['duration'])==(10,24)
    assert (attack['script'],attack['local_timing']['duration'])==(11,87)
    assert [(t,o['args'][0:3]) for t,o in zip(attack['local_timing']['operation_ticks'],attack['operations']) if o['op']==24]==[(25,[11,17 if member['id']==55 else 19,9])]
    assert [(t,o['args']) for t,o in zip(attack['local_timing']['operation_ticks'],attack['operations']) if o['op']==26]==[(65,[0,4])]

# Opcode9 requests coordinator completion for the current actor and keeps pumping.
for pc,word in {0x8016BAE0:0x800E3C34,0x800E3C48:0x1482000F,
                0x800E3C84:0xAC430030,0x800E3CA8:0x24630004,
                0x800E3CAC:0xAC43000C,0x800E3CB4:0x2402FFFF}.items():
    assert maindec.mword(pc)==word,hex(pc)


assert json.loads((ROOT/'game/tests/fixtures/wild_arrow_projection.json').read_text())==battle_unite_camera.wild_arrow_projection_vectors()
# Ordinary-node branch uses node XYZ, not the auxiliary writer's flag4/camera angles.
for pc,word in {0x800E26EC:0x8E420018,0x800E26F4:0x1440000F,0x800E26FC:0x8642001C,
                0x800E2704:0x1440000B,0x800E2734:0x96420018,0x800E2754:0x9642001C,
                0x800E2870:0x24420001,0x800E28F0:0x24420001,0x800E2934:0x24420001,
                0x800E295C:0x24420001,0x800E29EC:0x29420005,0x800E2A00:0x28A2017C}.items():
    assert maindec.mword(pc)==word,hex(pc)
print('ok   ordinary-node rotated branch, inclusive corners, depth clamp and independent arrow projection vectors')


phase=rows[6]['phase_schedule']
assert phase['entries']==[dict(member=0,script=10),dict(member=1,script=9,start_after=80)]
assert phase['transition']==dict(trigger_member=1,signal=2,dispatches=[dict(member=0,script=11)])
assert phase['damage_member']==0 and phase['damage_signal']==16 and phase['assist']==dict(member=0,variant=0)
assert phase['admission']=='native_vm_scene_bound_visual_acceptance_pending'
for member,script,expected in ((0,11,(None,68,90)),(1,9,(63,120,166))):
    origin=rows[6]['member_scripts'][member]['source'];raw=disc.extract(origin['lba'],origin['size']);events={}
    hit,ready,end,*_=blacksmith_reference_clocks(raw,script,events_out=events)
    assert (hit,ready,end)==expected
    assert phase['clocks'][member]['events']=={str(k):v for k,v in events.items()}
# First animation polling shares its dispatch sweep; motion finishes after its timer's sweep.
assert 81+phase['clocks'][1]['events']['2']==144
assert 144+phase['clocks'][0]['events']['16']+1==165
assert 144+phase['clocks'][0]['events']['4']+1==213
assert 80+phase['clocks'][1]['complete']==246
for pc,word in {0x800FA71C:0x8C660028,0x800FA72C:0x02602821,0x800FA7AC:0x34020050,
    0x800FA7B0:0x24630001,0x800FA7B4:0x1462000E,0x800FA7E4:0x8C460024,
    0x800FA818:0x30420002,0x800FA84C:0x8C46002C,0x800FA8B0:0x30420002,
    0x800FA924:0x30420010,0x800FA934:0x3406000F,0x800FA938:0x0C03E57A,0x800FA968:0x3042FFEF}.items():
    assert maindec.mword(pc)==word,hex(pc)
for address in (0x800FA71C,0x800FA7AC,0x800FA84C,0x800FA924):
    changed=bytearray(maindec.body());changed[address-maindec.MBASE]^=1
    try:battle_unite_camera.bumpy_phase_schedule(catalogue[6],rows[6]['member_scripts'],battle_unite_camera.Image(bytes(changed),maindec.MBASE))
    except ValueError:pass
    else:raise AssertionError('Changed Bumpy callback accepted')
# Required Humphrey pose8's UV endpoint reaches a third, unavailable page; retain refusal.
import export_battle_sprite_sections as section_decoder
origin=rows[6]['member_scripts'][1]['source'];raw=disc.extract(origin['lba'],origin['size'])
section=struct.unpack_from('<I',raw,36)[0];table=struct.unpack_from('<I',raw,section+16)[0];pose=struct.unpack_from('<I',raw,table+8*4)[0]
assert raw[section+4]==2 and list(raw[pose+8:pose+16])==[0,0,1,140,32,63,0,0]
try:section_decoder.decode_section(raw,section,character_id='humphrey')
except section_decoder.SectionError as error:assert error.code=='unavailable_adjacent_page'
else:raise AssertionError('Unknown Humphrey edge samples were silently filled')
print('ok   Bumpy counter, phases, separate signals, independent clocks, source mutation refusal and Humphrey sampling boundary')

footprint=section_decoder.decode_section(raw,section,character_id='humphrey',axis_aligned_packet=True)
assert footprint.poses[8].image.size==(32,64)
assert footprint.poses[8].pieces[0].width==32 and footprint.poses[8].pieces[0].height==63
assert all(p.cross_page_samples==0 for pose in footprint.poses for p in pose.pieces)
assert all(footprint.poses[8].image.getpixel((x,63))==(0,0,0,0) for x in range(32))
# Ordinary actor node draw and unrotated spans are separate from rotated child draws.
for pc,word in {0x800E0B9C:0x0C03895B,0x800E0BB8:0x0C039B4E,
    0x800E270C:0xA6270008,0x800E2714:0xA6230010,0x800E2720:0x00C41021,
    0x800E23F0:0x92620004,0x800E2400:0xA2420014}.items():assert maindec.mword(pc)==word,hex(pc)
print('ok   Humphrey unrotated packet texel footprint fits its supplied pages without endpoint padding')

changed=bytearray(raw);changed[pose+15]=1
try:section_decoder.decode_section(bytes(changed),section,axis_aligned_packet=True)
except section_decoder.SectionError as error:assert error.code=='unsupported_packet_footprint'
else:raise AssertionError('Flipped packets require their own endpoint footprint')
for pc,word in {0x800E1F2C:0xA660001C,0x800E1F30:0xA660001A,0x800E1F34:0xA6600018,
               0x800E26F4:0x1440000F,0x800E2704:0x1440000B}.items():assert maindec.mword(pc)==word,hex(pc)

sonya=rows[25]['member_scripts'][2]['source'];sonya_raw=disc.extract(sonya['lba'],sonya['size'])
sonya_section=struct.unpack_from('<I',sonya_raw,36)[0]
try:section_decoder.decode_section(sonya_raw,sonya_section,character_id='sonya')
except section_decoder.SectionError as error:assert error.code=='unavailable_adjacent_page'
else:raise AssertionError('Sonya inclusive endpoint reached no expected page boundary')
sonya_packet=section_decoder.decode_section(sonya_raw,sonya_section,character_id='sonya',axis_aligned_packet=True)
assert all(not piece.flip_x and not piece.flip_y and piece.cross_page_samples==0 for pose in sonya_packet.poses for piece in pose.pieces)
print('ok   Sonya unflipped body uses the same zero-node-angle packet writer; all endpoint-excluded texels fit supplied pages')

fatal=rows[13]['phase_schedule']
assert fatal['entries']==[dict(member=0,script=9,deferred_entry=True),dict(member=1,script=9)]
assert fatal['transition']==dict(trigger_member=1,signal=16,dispatches=[dict(member=0,script=9)])
assert fatal['damage_member']==1 and fatal['damage_signal']==2
for index,expected in ((0,(64,135,180)),(1,(251,271,317))):
    member=rows[13]['member_scripts'][index]
    raw=disc.extract(member['source']['lba'],member['source']['size']);events={}
    hit,ready,end,*_=blacksmith_reference_clocks(raw,events_out=events)
    assert (hit,ready,end)==expected
    assert fatal['clocks'][index]['events']=={str(k):v for k,v in events.items()}
    if index==1:assert events[16]==60
assert 60+1==61 and 60+64+1==125 and 251+1==252 and 271+1==272
for pc,word in {0x800FBA48:0x8E240004,0x800FBA70:0x8C460024,0x800FBA74:0x0C038E08,
    0x800FBB30:0x8E250000,0x800FBB5C:0x30420002,0x800FBB70:0x8C46003C,
    0x800FBBAC:0x8E220004,0x800FBBD4:0x30420010,0x800FBBE0:0x8E240000,
    0x800FBC08:0x8C460024,0x800FBC0C:0x0C038E08,0x800FBC3C:0x3063FFEF,
    0x800FBC44:0x8E240004,0x800FBC48:0x34050002,0x800FBC4C:0x34060014}.items():
    assert maindec.mword(pc)==word,hex(pc)
for address in (0x800FBA48,0x800FBB5C,0x800FBBD4,0x800FBC44):
    changed=bytearray(maindec.body());changed[address-maindec.MBASE]^=1
    try:battle_unite_camera.fatal_phase_schedule(catalogue[13],rows[13]['member_scripts'],battle_unite_camera.Image(bytes(changed),maindec.MBASE))
    except ValueError:pass
    else:raise AssertionError('Changed Fatal initializer/controller accepted')
print('ok   Fatal starts only Kamandol; flag16 starts Gen; independent clocks and changed-source refusal')

for index,expected in ((0,[(15,35)]),(1,[(15,35),(194,214)])):
    member=rows[13]['member_scripts'][index]
    raw=disc.extract(member['source']['lba'],member['source']['size']);events={}
    _,_,_,raw_trails,_,_=blacksmith_reference_clocks(raw,events_out=events)
    animations,_,_=battle_unite_camera.animation_frames(raw)
    operations=battle_unite_camera.journey_battle.script(raw,9)
    trails=battle_unite_camera.journey_battle.trail_bindings(animations,operations)
    assert list(zip(raw_trails[::2],raw_trails[1::2]))==expected
    assert [(t['start'],t['stop']) for t in trails]==expected
    section=struct.unpack_from('<I',raw,36)[0];frames=struct.unpack_from('<I',raw,section+20)[0]
    first=struct.unpack_from('<I',raw,frames+5*4)[0]
    assert raw[first+4]==4
    assert all(t['pose']==4 and t['animation']==5 for t in trails)
    unfinished=[(op,args) for op,args in operations if not (op==30 and args==(99,))]
    try:battle_unite_camera.journey_battle.trail_bindings(animations,unfinished)
    except ValueError:pass
    else:raise AssertionError('Unterminated or overlapping trail accepted')
print('ok   repeated Kamandol trail lifetimes match independent raw clocks; unfinished lifetimes refuse')

# Beauty's table thunk, asynchronous readiness and actual initializer are distinct.
beauties=[rows[i]['scene_controller'] for i in (9,25)]
assert beauties[0]['contract']==beauties[1]['contract']
contract=beauties[0]['contract']
assert contract['startup']['ready_poll']=='asynchronous'
assert contract['trigger']==dict(member=0,signal=16,retained=True)
assert contract['graphics']['count']==30 and contract['graphics']['animation']==13
assert beauties[0]['constructors']['count']==30
assert beauties[0]['constructors']['slots']==list(range(0,120,4))
assert beauties[0]['constructors']['dynamic_parameters']==['sway_age']
# The third constructor parameter is the initial sway age, not a wait or animation warmup.
assert maindec.mword(0x801234A4)==0xAC550024
assert maindec.mword(0x800FCC74)==0x0C054204 and maindec.mword(0x800FCC78)==0x00042140
assert maindec.mword(0x800FCC98)==0x24420001
for pc,word in {0x800FC420:0x0C03E445,0x800F9130:0x0C030E81,0x800F9180:0x0C030CE8,
    0x800F9188:0x14400009,0x800F91AC:0xAC620018,0x800FC470:0x8ED6A01C,
    0x800FC480:0x8EF7A00C,0x800FC4AC:0x0C051F8E,0x800FC4CC:0x0C051F8E,
    0x800FC504:0x0C048CED,0x800FC518:0x0C048C15,0x800FC530:0x0C048E38,
    0x800FC6B0:0x30420010,0x800FC8B0:0x8C46003C,0x800FCB50:0x34050003,
    0x800FCB54:0x34060004,0x800FCB58:0x0C03E57A,0x800FCBB4:0x0C038E08,
    0x800FCCAC:0xAE02003C,0x800FCCB0:0xAE020038,0x800FCCB8:0xAE020034}.items():
    assert maindec.mword(pc)==word,hex(pc)
counts=[maindec.mword(pc)&65535 for pc in (0x800FC7FC,0x800FC9D0,0x800FCB2C)]
assert [phase['updates'] for phase in contract['phases']]==counts+[1]==[64,128,32,1]
signed_imm=lambda pc:struct.unpack('<h',struct.pack('<H',maindec.mword(pc)&65535))[0]
assert contract['phases'][0]['translation_delta'][0]==signed_imm(0x800FC748)==-2
assert contract['phases'][0]['scale_accumulator_delta']==(maindec.mword(0x800FC750)&65535)<<16
assert contract['phases'][0]['node_scale_delta']==signed_imm(0x800FC774)==64
assert contract['phases'][2]['node_scale_delta']==signed_imm(0x800FCABC)==-128
assert contract['phases'][0]['wave_rgb_q12_delta']==[signed_imm(p) for p in (0x800FC798,0x800FC7B0,0x800FC7C8)]
assert contract['phases'][2]['wave_rgb_q12_delta']==[signed_imm(p) for p in (0x800FCAE0,0x800FCAF8,0x800FCB10)]
assert 1365+counts[0]*64+counts[2]*-128==1365
sphere=battle_unite_camera.Image();start=0x80123054
calls=[(pc,(pc&0xF0000000)|((sphere.word(pc)&0x3FFFFFF)<<2)) for pc in range(start,sphere.end(start),4) if sphere.word(pc)>>26==3]
assert len([pc for pc,target in calls if target==0x80147E38])==3
assert contract['graphics']['initial_draws_per_particle']==2+3==5
# Independently walk the raw member clocks and the recipient's complete descriptor.
for row in (rows[9],rows[25]):
    for index,member in enumerate(row['member_scripts']):
        raw=disc.extract(member['source']['lba'],member['source']['size']);events={}
        hit,ready,end,*_=blacksmith_reference_clocks(raw,10,events_out=events)
        assert row['scene_controller']['clocks'][index]['events']=={str(k):v for k,v in events.items()}
        assert row['scene_controller']['clocks'][index]['duration']==ready
    source=row['scene_controller']['recipient_source'];raw=disc.extract(source['source']['lba'],source['source']['size'])
    cursor=source['source_offset'];clock=move_end=0;colours=[];status=[]
    while True:
        op=struct.unpack_from('<H',raw,cursor)[0];count=1 if op==0 else actor_script.OP_LEN_HW[op]
        args=struct.unpack_from('<'+'h'*(count-1),raw,cursor+2);cursor+=2*count
        if op==3:clock+=args[0]
        elif op==22:move_end=clock+args[0]
        elif op==21:clock=max(clock,move_end)
        elif op==41:colours.append((clock,args))
        elif op==40:status.append((clock,args))
        if op==0:break
    assert cursor-source['source_offset']==source['byte_length']
    assert colours==[(3,(192,64,64)),(131,(128,128,128))]
    assert status==[(133,(5,30))]
    assert contract['recipient']['source_clock']['tint_on']==colours[0][0]
    assert contract['recipient']['source_clock']['tint_restore']==colours[1][0]
    assert contract['recipient']['source_clock']['status_attempt']==status[0][0]
    assert contract['recipient']['status']['failure_percent']==30
    assert struct.unpack_from('<H',maindec.body(),0x8016BAA8-maindec.MBASE+2*5)[0]==0x20
    for address in (0x800FC420,0x800FC504,0x800FC798,0x800FCB58,0x80123054):
        changed=bytearray(maindec.body());changed[address-maindec.MBASE]^=1
        try:battle_unite_camera.beauty_scene_controller(catalogue[row['index']],row['member_scripts'],battle_unite_camera.Image(bytes(changed),maindec.MBASE))
        except ValueError:pass
        else:raise AssertionError('Changed Beauty controller/helper accepted')
print('ok   shared Beauty phases constructors wave scales RNG order and recipient tint/sleep contract; CD readiness remains explicit')

assert contract['camera']['updates']==(maindec.mword(0x800FC71C)&65535)==60
raw_camera=struct.unpack_from('<12i',maindec.body(),0x8016CC1C-maindec.MBASE)
assert sum((contract['camera'][key] for key in ('focus_q12','angles_q12','translation_q12','scale_q12')),[])==list(raw_camera)
assert raw_camera==(-655360,0,0,-3145728,0,1441792,0,0,4194304,20971520,20971520,20971520)
assert maindec.mword(0x800FC718)==0x0C03D844
assert maindec.mword(0x80123084)==0xAE82001C and contract['graphics']['enabled_after_sphere']
print('ok   Beauty camera block is Q12, requested for60 updates on rise entry; sphere placement enables particles')

# Enemy opcode40 bypasses the party-only Turtle/slot branch and writes the class bit.
for pc,word in {0x800E6B08:0x0050102A,0x800E6B0C:0x10400026,0x800E6B14:0x0C051F8E,
    0x800E6B98:0x14400057,0x800E6BA0:0x08039B3B,0x800E6CEC:0x0C038137,
    0x800E0500:0x0046102A,0x800E0504:0x10400008,0x800E0520:0x0803817F,
    0x800E060C:0x94250000,0x800E0610:0x9464004A,0x800E0618:0x00852025,
    0x800E061C:0x080381DA,0x800E0620:0xA464004A}.items():assert maindec.mword(pc)==word,hex(pc)
assert rows[9]['scene_controller']['contract']['recipient']['status']['duplicates']=='existing Sleep bit stays set; probability draw is still consumed'
print('ok   enemy Sleep draws before its direct class-bit OR; party slot/rune checks are on the other branch')

pretty=rows[8]['phase_schedule']
assert [[s['script'] for s in m['scripts']] for m in rows[8]['member_scripts']]==[[9],[11,12],[10]]
assert pretty['entries']==[dict(member=0,script=9),dict(member=1,script=11),dict(member=2,script=10)]
assert pretty['transition']==dict(trigger_member=2,signal=16,dispatches=[dict(member=1,script=12)])
assert pretty['embedded_returns'] and pretty['damage_member']==1 and pretty['damage_signal']==2
original_word=unite_catalogue.word
with patch.object(unite_catalogue,'word',side_effect=lambda pc:0x8E240000 if pc==0x800FDCD4 else original_word(pc)):
    try:unite_catalogue.recovery_facts(catalogue[8])
    except ValueError:pass
    else:raise AssertionError('Recovery producer accepted script12 with a different member owner')
# The callback loads member-list+4 for a0, then that actor's resource+0x30 for a2.
for pc,word in {0x800FDCD4:0x8E240004,0x800FDCF4:0x8C420008,0x800FDCFC:0x8C460030,
                0x800FDD00:0x0C038E08,0x800FDD38:0x8E250000,0x800FDD74:0x8C46003C,
                0x800FDD78:0x0C038E08,0x800FDDB0:0x8E240004,0x800FDDB8:0x34060019,
                0x800FDDBC:0x0C03E522}.items():assert maindec.mword(pc)==word,hex(pc)
for ordinal,script,expected in ((0,9,(58,160,181)),(1,11,(None,None,24)),(1,12,(None,79,101)),(2,10,(57,159,192))):
    member=rows[8]['member_scripts'][ordinal]
    raw=disc.extract(member['source']['lba'],member['source']['size'])
    hit,ready,end,*_=blacksmith_reference_clocks(raw,script,return_source=None)
    assert (hit,ready,end)==expected
for address in (0x800FDCD4,0x800FDCFC,0x800FDD74,0x800FDDB0):
    changed=bytearray(maindec.body());changed[address-maindec.MBASE]^=1
    try:battle_unite_camera.pretty_girl_phase_schedule(catalogue[8],rows[8]['member_scripts'],battle_unite_camera.Image(bytes(changed),maindec.MBASE),pretty['source'])
    except ValueError:pass
    else:raise AssertionError('Changed Pretty Girl member/recipient dispatch accepted')
print('ok   Pretty Girl Tengaar12 resource owner, independent member clocks, shared callback8 recipient and changed-source refusal')

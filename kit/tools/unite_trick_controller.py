"""Static Trick wave, member scripts and Juppo animation19 provenance."""
import hashlib
import json
from pathlib import Path
import struct

import battle_unite_camera as source
import journey_battle
import spell_scene_objects

ROOT=Path(__file__).resolve().parents[2]
REPORT=ROOT/'kit/data/reports/unite_trick_controller.json'
SPANS=((0x800FB428,0x800FB63C,'d4020fe4ee4c51c5b4cabdf1dddb91fc9299604c65363614c24c53ca1c8e1405'),
       (0x800FB63C,0x800FB9E4,'7f984be4f4eaf9fd049fc504aa5321cda0305655fc1f5c0c7f775faaf518b063'),
       (0x800E1E3C,0x800E2044,'b7b84caf8e8fb8775f27d3de428b4e20d5b3b030fa4bcad1f78a03cb6af4e875'),
       (0x801233B4,0x801234D0,'445f9fd3169761fa1175ba0a4bdecc702f320f2d55c351013670c9e2d6db1fd8'),
       (0x801238E0,0x80123974,'14c0ab74e12d9417dda9582dea1a69d9d492195d57c5fa23dac394acaf42cee6'),
       (0x80123720,0x801238E0,'4dc2c2da15c8ef6b434a85494b643cc7376d609f97ec430262c0dd5adbdc851a'),
       (0x800E2A9C,0x800E2B3C,'06b9cb36a60c6d68316d7857e00c513706c8e62b6291da96a5d237e7e3884616'))
STREAMS={('/MEG.BIN',11):'a7ea85161cc94f258eb777b9157d55f039075432db7f30b611f8e8bbe9091a3b',
         ('/JUP.BIN',11):'bfe4731cb97e48db356cc347799c47c2bb1c770baf0e5c5ade3336121068f4e6',
         ('/JUP.BIN',12):'5a83cb9e2aed0531ae326684624aad709f4a0d4d84648b43208711280b5d2221'}


def descriptor(path,index):
    raw,origin=source.field.source(path)
    table=struct.unpack_from('<I',raw,32)[0]
    offset=struct.unpack_from('<I',raw,table+4*index)[0]
    ops=journey_battle.script(raw,index)
    length=sum(2+2*len(args) for _,args in ops)
    digest=hashlib.sha256(raw[offset:offset+length]).hexdigest()
    if digest!=STREAMS[(path,index)]:raise ValueError('Trick descriptor changed')
    animations,flags,_=source.animation_frames(raw)
    return dict(script=index,source=origin,source_offset=offset,byte_length=length,sha256=digest,
                operations=[dict(op=op,args=list(args)) for op,args in ops],
                clocks=journey_battle.script_events(animations if index==11 else [],ops,flags if index==11 else None,initial_movement_wait=index!=11))


def build(image=None):
    import export_spell_scenes
    image=image or source.Image()
    blocks=[]
    for start,end,digest in SPANS:
        if image.end(start)!=end or hashlib.sha256(image.data[start-image.base:end-image.base]).hexdigest()!=digest:
            raise ValueError('Trick controller changed')
        blocks.append(dict(address=start,size=end-start,sha256=digest))
    sine_offset=0x801765BC-image.base
    sine_hash=hashlib.sha256(image.data[sine_offset:sine_offset+2050]).hexdigest()
    if sine_hash!='bab3b71ba7f79dfb2b5cebb71f8382a79606a958d72031bc11b88066c36033bd':
        raise ValueError('Trick sine table changed')
    members=source.report()[14]['member_scripts']
    if [m['id'] for m in members]!=[76,39]:raise ValueError('Trick participants changed')
    objects=spell_scene_objects.constructors(dict(initializer=SPANS[0][0],preparation=[],state_global=0x8017A010),image)
    expected=[(19,2*i,1,0,4096,4*i) for i in range(8)]
    if objects['blocked'] or [(o['animation'],o['delay'],o['looping'],o['enabled'],o['size'],o['slot']) for o in objects['objects']]!=expected:
        raise ValueError('Trick constructors changed')
    ys=[100*4096-(i*200*4096)//7 for i in range(8)]
    if any(o['initial']!={8:-300*4096,76:32,4:y} for o,y in zip(objects['objects'],ys,strict=True)):
        raise ValueError('Trick initial coordinates changed')
    raw,origin=source.field.source('/JUP.BIN')
    section=struct.unpack_from('<I',raw,36)[0]
    frames=struct.unpack_from('<I',raw,section+20)[0]
    offset=struct.unpack_from('<I',raw,frames+4*19)[0]
    if hashlib.sha256(raw[offset:offset+8]).hexdigest()!='4e0b9a38feb66760d2a7a588306befdae381f5d7b0500bce16d7dbd1d129123b':
        raise ValueError('Trick wave animation changed')
    poses=struct.unpack_from('<I',raw,section+16)[0]
    frame_rows=[dict(pose=raw[offset+4+2*i],updates=raw[offset+5+2*i] or 256) for i in range(raw[offset])]
    heights=[-(abs(export_spell_scenes.effect_sine(i*128))*30//4096) for i in range(50)]
    entries=[dict(id=i,source_offset=struct.unpack_from('<I',raw,poses+4*i)[0]) for i in sorted({f['pose'] for f in frame_rows})]
    return dict(schema='suikoden-unite-trick-controller/1',record=14,source_blocks=blocks,
                sine_source=dict(file='MAIN.EXE',image_address=0x801765BC,byte_length=2050,sha256=sine_hash),
                members=[dict(id=76,entry=descriptor('/MEG.BIN',11)),dict(id=39,entry=descriptor('/JUP.BIN',11))],
                art=dict(source=origin,section_offset=section,animation=19,animation_offset=offset,
                         animation_flags=raw[offset+1],loop_override=True,frames=frame_rows,poses=entries,
                         binding='member1 actor graphic source section; actor array base includes +0x50'),
                objects=dict(count=8,delays=list(range(0,16,2)),initial_y_q12=ys,initial_z_q12=-300*4096,
                             rise_q12=76800,settle='clamp and mark settled only when next Z is strictly positive',flags=32),
                trigger=dict(member=1,signal=16,retained_until_returns=True),
                phases=[dict(name='rise',updates=64,start_sound=0x513),
                        dict(name='sweep',updates=50,delta_x=-8,heights=heights,sound=0x81B,sound_period=16),
                        dict(name='fall',updates=64,delta_z=-5)],
                targets=dict(order='ascending occupied enemy slots',position='current X Q12 shifted arithmetically by12',
                             crossing='updated wave X strictly less than target X',once=True,
                             inactive='callback marks crossing even when the shared damage helper skips an inactive target'),
                damage=dict(count=2,multiplier=10,divisor=10,recipient=descriptor('/JUP.BIN',12)),
                completion=dict(return_program='common/unite_return',return_dispatch_after=178,
                                clear_signal16=True,cleanup='same callback after both return dispatch markers; actor returns continue',recovery=False),
                admission='normal_journey_candidate_media_pending',
                unresolved=['campaign acquisition','broader overlap','human visual/audio acceptance'])


if __name__=='__main__':
    import argparse
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--check',action='store_true');args=parser.parse_args()
    payload=json.dumps(build(),indent=2)+'\n'
    if args.check:
        if REPORT.read_text()!=payload:raise SystemExit('Trick report is stale')
    else:REPORT.write_text(payload)
    print('Checked Trick contract' if args.check else 'Wrote Trick contract')

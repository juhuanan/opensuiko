"""Compile VAA-room2's audience into named actions; no original pointers in runtime data."""
from pathlib import Path
import json
import struct

import character_table
from parse_04play import Parser
import area_scene as scene
import event_script_decode
import maindec
import war_text
from export_first_room import source

ROOT = Path(__file__).resolve().parents[2]
DIRECTIONS = ('up', 'right', 'down', 'left')


def actor(selector):
    if selector == 128: return 'hero'
    if selector == 64: return 'audience_double'
    if selector < 64: return f'scene_actor_{selector}'
    raise ValueError(f'unsupported audience actor {selector}')


def track(data):
    if not data or data[-1] != 5 or len(data)%2 != 1:
        raise ValueError('unterminated audience actor track')
    result=[]
    for i in range(0,len(data)-1,2):
        op,value=data[i:i+2]
        if op < 4: result.append(dict(kind='move', direction=DIRECTIONS[op], cells=value))
        elif op == 4 and value != 255: result.append(dict(kind='set_motion', motion=value))
        elif op == 7 and value: result.append(dict(kind='advance', cells=value))
        elif op == 6: result.append(dict(kind='hold', updates=value * 5) if value else dict(kind='hop'))
        else: raise ValueError(f'unsupported audience actor track action {op}/{value}')
    result.append(dict(kind='finish'))
    return result


def text(data, offset):
    tokens=[]
    for _ in range(4096):
        code=data[offset];offset+=1
        if code == 0: return tokens,offset
        if code in (1,3): token=dict(kind='newline')
        elif code == 2: token=dict(kind='page')
        elif code in (4,5):
            token=dict(kind={4:'pace',5:'countdown'}[code],value=data[offset]);offset+=1
        elif code == 6:
            if data[offset] != 0: raise ValueError('unsupported audience nested string')
            token=dict(kind='player_name');offset+=1
        elif code in war_text.SUBST: token=dict(kind='glyph',text=war_text.SUBST[code])
        else: raise ValueError(f'unsupported audience text control {code}')
        tokens.append(token)
    raise ValueError('unterminated audience text')


def actor_bindings(data,number,flags):
    actors=[];proof=[]
    for entry in scene.entities(data,scene.room_record(data,number)):
        if not entry['flags'] & 0x101:continue
        predicate=entry['stream_offsets'][0]
        if predicate is None:continue  # Source null predicate aliases the preceding slot.
        cursor=predicate;attached=True
        for _ in range(16):
            op=data[cursor];cursor+=1
            if op==6:break
            if op not in (7,8):raise ValueError('unsupported palace actor classifier')
            index,mask=data[cursor:cursor+2];cursor+=2
            attached &= bool(flags[index]&mask) == (op==7)
        else:raise ValueError('unterminated palace actor classifier')
        # The setup pair is metadata byte then orientation; the metadata is not alwaysFF.
        slot=len(actors)
        actors.append(dict(id=f'scene_actor_{slot}',graphic=f"palace_character_{entry['id']}",
                           x=entry['x_half']*8,y=entry['y_half']*8,motion=(entry['flags']>>2)&1,
                           variant=data[cursor+1]&3,attached=attached,auto_animate=bool(entry['flags']&0x200)))
        proof.append(dict(actor=actors[-1]['id'],entity=entry['index'],native_character=entry['id'],classifier=predicate))
    return actors,proof


def animation_timings(data,actors):
    bindings={}
    for room in (2,1):
        section=scene.section_off(data,scene.room_record(data,room)['section'])
        for native_id,binding in scene.character_bindings(data,section).items():bindings.setdefault(native_id,binding)
    result=[]
    for native_id,binding in sorted(bindings.items()):
        context=binding['context'];table=scene.ptr_at(data,context+20);clips=[]
        for variant in range(4):
            descriptor=scene.ptr_at(data,table+4*variant)
            clips.append(dict(flags=data[descriptor+1],ticks=[data[descriptor+5+2*i] or 256 for i in range(data[descriptor])],
                bounds=[dict(width=data[sheet+2],height=data[sheet+3]) for i in range(data[descriptor])
                        for sheet in (scene.descriptor_sheet(data,context,variant,i)['sheet'],)]))
        result.append(dict(graphic=f'palace_character_{native_id}',clips=clips))
    hero,_=source('/SHU.BIN');parser=Parser(hero,0xB0000000);parser.parse_header()
    section=parser.parse_section('S2',parser.u32(0x28))
    result.append(dict(graphic='hero',clips=[dict(flags=hero[e['target_file_offset']+1],
        ticks=[duration or 256 for _,duration in e['sequence']['pairs']],
        bounds=[dict(width=hero[sheet+2],height=hero[sheet+3]) for index,_ in e['sequence']['pairs']
                for sheet in (section['e']['entries'][index]['target_file_offset'],)]) for e in section['f']['entries']]))
    return result


def export():
    data,proof=source('/VAA.BIN')
    entry=scene.entities(data,scene.room_record(data,2))[22]
    start=entry['stream_offsets'][2]
    rows=[]
    for row in event_script_decode.decode_stream(data,start):
        rows.append(row)
        if row[1] == 253: break
    if not rows or rows[-1][1] != 253 or len(rows)!=201: raise ValueError('audience extent changed')
    index={offset:i for i,(offset,_,_,_) in enumerate(rows)}
    commands=[];evidence=[];tracks=[];texts={}
    root=scene.ptr_at(data,0)
    textroot=scene.ptr_at(data,root+20)
    room=scene.room_record(data,2)
    for offset,op,args,note in rows:
        if 'truncat' in note.lower(): raise ValueError('truncated audience instruction')
        command={}
        if op == 0x10: command=dict(kind='align_hero',x=args[0]*8,y=args[1]*8)
        elif op == 0x11: command=dict(kind='actor_transition',actor=actor(args[0]),transition=maindec.mword(0x80171B98+4*args[1]))
        elif op in (0x0B,0x17): command=dict(kind='open_box',box=0 if op==11 else 1,actor=actor(args[0]))
        elif op == 0x12:
            pointer=maindec.mword(0x80170588+4*args[1]) if args[1]!=8 else None
            name=war_text.decode(maindec.body(),pointer-maindec.MBASE)[0] if pointer else ''
            command=dict(kind='speaker',box=args[0],image=args[1],name=name)
        elif op in (0x04,0x1C):
            box=args[0]
            if op == 4:
                table=scene.ptr_at(data,room['record_off']+12);pointer=scene.ptr_at(data,table+4*args[1]);id=f'room_text_{args[1]}'
            else:
                table=scene.ptr_at(data,textroot+4*args[1]);pointer=scene.ptr_at(data,table+4*args[2]);id=f'area_text_{args[1]}_{args[2]}'
            tokens,end=text(data,pointer);texts[id]=dict(id=id,tokens=tokens)
            command=dict(kind='text',box=box,text=id)
            evidence.append(dict(text=id,offset=pointer,end=end))
        elif op == 2: command=dict(kind='wait_confirm')
        elif op in (0x0C,0x18): command=dict(kind='close_box',box=0 if op==12 else 1)
        elif op == 0x32:
            id=f'audience_track_{len(tracks)}';tracks.append(dict(id=id,actor=actor(args[0]),commands=track(args[1:])))
            command=dict(kind='queue_track',track=id)
        elif op == 0x33: command=dict(kind='wait_tracks')
        elif op == 0x0A: command=dict(kind='delay',updates=args[0]*5)
        elif op == 0x41: command=dict(kind='cue',cue=struct.unpack_from('<H',maindec.body(),0x80171C2C-maindec.MBASE+2*args[0])[0])
        elif op == 8:
            dx,dy=[struct.unpack_from('<i',maindec.body(),address-maindec.MBASE+4*args[0])[0] for address in (0x80171860,0x80171870)]
            command=dict(kind='pan',dx=dx,dy=dy,updates=args[1]*4)
        elif op == 0x4D:
            command=dict(kind={0:'next_variant',1:'previous_variant',2:'wait_variant',3:'set_variant'}[args[0]],actor=actor(args[1]))
            if args[0] == 3: command['variant']=args[2]
        elif op == 7:
            if args[1] not in (0,1,2): raise ValueError('unsupported audience descriptor mode')
            command=dict(kind={0:'actor_motion',1:'actor_x',2:'actor_y'}[args[1]],actor=actor(args[0]),value=args[2])
        elif op == 0x3A: command=dict(kind='release_actor',actor=actor(args[0]))
        elif op == 0x34:
            if args != bytes.fromhex('01 08 00 17 2d'): raise ValueError('unsupported audience double')
            command=dict(kind='create_double',actor='audience_double',character='hero',x=args[3]*8,y=args[4]*8)
        elif op == 5:
            if args != bytes((0,2,1)): raise ValueError('unsupported audience choice')
            command=dict(kind='choice',box=1,options=2)
        elif op in (0x2E,0x2F):
            label=args[-1];base=offset+1+len(args)
            destination=data.index(label,base)
            if destination not in index: raise ValueError('audience branch lands inside an instruction')
            command=dict(kind='jump' if op==46 else 'branch_choice',target=index[destination] if op==47 else index[destination]+1)
            if op==47 and args[0]!=0x82: raise ValueError('unsupported audience switch')
        elif op in (0xFB,0xFC): command=dict(kind='label')
        elif op == 0x39: command=dict(kind='free_double')
        elif op == 0x1D: command=dict(kind='follow_character',character='teo')
        elif op == 9:
            if args != bytes((0,64)): raise ValueError('unsupported audience story write')
            command=dict(kind='complete_audience')
        elif op == 0x46: command=dict(kind='wait_boxes')
        elif op == 0xFD: command=dict(kind='finish')
        else: raise ValueError(f'unsupported audience opcode {op:#x}')
        commands.append(command)
        evidence.append(dict(command=len(commands)-1,offset=offset,opcode=op,operands=args.hex()))
    initial=character_table.image()[0x32FE0+0x190:0x32FE0+0x280]
    actors,bindings=actor_bindings(data,2,initial)
    config=character_table.image()[0x32FE0+0x1B90]
    pace=maindec.body()[0x80171885-maindec.MBASE+4*config]
    # The opening root/field consumers reach mode0 VSync once per update.
    assert maindec.mword(0x800C2860)==0xAC400024
    assert ((maindec.mword(0x800C28B4)&0x3FFFFFF)<<2|0x80000000)==0x80154928
    runtime=dict(nominal_updates_per_second=60,default_text_pace=pace,animations=animation_timings(data,actors),actors=actors,schema='suikoden-opening-audience/2',id='palace_audience',commands=commands,tracks=tracks,texts=list(texts.values()))
    return runtime,dict(schema='suikoden-opening-audience-evidence/1',source=proof,timing=dict(wait_mode=0,nominal_ntsc_updates_per_second=60,root='MAIN800C2854..800C28BC',field='MAIN801319C4',reference='https://psx.arthus.net/sdk/Psy-Q/DOCS/TECHNOTE/scee_dev.pdf#page=45',scope='Nominal opening software cadence; hardware stalls and exact oscillator frequency are not emulated.'),actor_bindings=bindings,entity=entry['index'],start=start,end=rows[-1][0]+1,instructions=evidence,
        scope='Lossless named command/text/track export; interpretation, actor bindings, presentation and original cadence require their own checks.')


if __name__ == '__main__':
    runtime,evidence=export()
    (ROOT/'game/assets/opening_audience.json').write_text(json.dumps(runtime,indent=2)+'\n')
    (ROOT/'kit/data/reports/opening_audience.json').write_text(json.dumps(evidence,indent=2)+'\n')
    print(f"Exported {len(runtime['commands'])} audience commands, {len(runtime['tracks'])} actor tracks, {len(runtime['texts'])} tokenized texts; no media promotion")

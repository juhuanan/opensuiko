#!/usr/bin/env python3
"""Disc-derived normal/boss/result battle streams; no playback or accepted promotion."""
import argparse
import hashlib
import json
from pathlib import Path
from export_opening_audio import ROOT,export_resource
from dot8_audio import resources
import maindec


def encounter_music(flags):
    # Omitted normal metadata preserves existing content/save identities.
    return {'music':'boss'} if flags&0x40000000 else {}


def export(output):
    output=Path(output).resolve();accepted=(ROOT/'kit/work/accepted').resolve()
    if output==accepted or accepted in output.parents:raise ValueError('candidate output cannot be accepted staging')
    for pc,word in {0x800DE084:0x0C030C41,0x800DE088:0x34040071,
                    0x800DE094:0x0C030C41,0x800DE098:0x34040070,
                    0x800C52BC:0x0C031BC1,0x800C52C0:0x34040001,
                    0x800C52CC:0x0C031BC1,0x800C52D0:0x34040002,
                    0x800E81BC:0x0C030C41,0x800E81C0:0x3404041F,
                    0x800C6F40:0x3404041D,0x800C6F50:0x3404041E}.items():
        if maindec.mword(pc)!=word:raise ValueError(f'battle audio source changed at {pc:#x}')
    rows={r['index']:r for r in resources()};output.mkdir(parents=True,exist_ok=True)
    tracks=[];origins=[]
    for name,index in (('battle',29),('boss',30),('victory',31)):
        track,proof=export_resource(output,name,rows[index])
        track['sha256']=hashlib.sha256((output/track['path']).read_bytes()).hexdigest()
        tracks.append(track);origins.append(proof)
    result=dict(schema='suikoden-battle-audio/1',tracks=tracks)
    (output/'battle.json').write_text(json.dumps(result,indent=2)+'\n')
    files={name:hashlib.sha256((output/name).read_bytes()).hexdigest() for name in ('battle.json','battle.wav','boss.wav','victory.wav')}
    (output/'battle_provenance.json').write_text(json.dumps(dict(schema='suikoden-battle-audio-proof/1',status='candidate; listening and promotion pending',sources=origins,files=files,scope='Normal, boss and result stream identity, rates, volume and loop boundaries; SFX, defeat music and exact source transitions remain separate.'),indent=2)+'\n')
    return result



def validate(folder,packet):
    """Validate the portable interface and each decoded file before packaging."""
    folder=Path(folder)
    if not isinstance(packet,dict) or packet.get('schema')!='suikoden-battle-audio/1' or not isinstance(packet.get('tracks'),list) or len(packet['tracks'])!=3:raise ValueError('invalid battle audio schema/count')
    seen=set()
    for track in packet['tracks']:
        if not isinstance(track,dict):raise ValueError('invalid battle audio track')
        name=track.get('id')
        if name not in ('battle','boss','victory') or name in seen or track.get('path')!=name+'.wav':raise ValueError('invalid battle audio identity/path')
        seen.add(name)
        if any(type(track.get(key)) is not int for key in ('sample_rate','frames','loop_start_frame','volume')):raise ValueError('invalid battle audio dimensions')
        if not isinstance(track.get('sha256'),str) or len(track['sha256'])!=64 or any(c not in '0123456789abcdef' for c in track['sha256']):raise ValueError('invalid battle audio hash')
        if not (8000<=track['sample_rate']<=48000 and 0<track['frames']<=48000*600 and 0<=track['loop_start_frame']<track['frames'] and 0<=track['volume']<=127):raise ValueError('invalid battle audio dimensions')
        path=folder/track['path']
        if path.is_symlink() or not path.resolve().is_relative_to(folder.resolve()) or hashlib.sha256(path.read_bytes()).hexdigest()!=track['sha256']:raise ValueError('battle audio hash/path mismatch')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',type=Path,default=ROOT/'kit/work/build/battle_review/audio')
    args=parser.parse_args();packet=export(args.out)
    print(f"Exported {len(packet['tracks'])} battle stream candidates without playback")

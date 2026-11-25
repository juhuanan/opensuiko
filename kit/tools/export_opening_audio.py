"""Private palace stream candidates; no playback, media acceptance or promotion."""
from pathlib import Path
import hashlib
import json
import sys
import wave
from disc import extract
from dot8_audio import resources, pcm, VERSION, CHUNK

ROOT=Path(__file__).resolve().parents[2]


def export_resource(output,name,row):
    """One source stream, shared by the opening and battle candidate writers."""
    output=Path(output)
    size=row['end_sector']*2048
    data=extract(row['lba'],size)
    decoded=pcm(data)
    frames=size//(CHUNK*2)*(CHUNK//16*28)
    loop=row['loop_sector']//16*(CHUNK//16*28)
    assert len(decoded)==frames*4 and 0<=loop<frames
    filename=name+'.wav'
    with wave.open(str(output/filename),'wb') as stream:
        stream.setnchannels(2);stream.setsampwidth(2);stream.setframerate(row['rate']);stream.writeframes(decoded)
    track=dict(id=name,path=filename,sample_rate=row['rate'],frames=frames,loop_start_frame=loop,volume=row['volume'])
    proof=dict(id=name,**row,source_offset=0,source_bytes=size,decoder=VERSION,pcm_sha256=hashlib.sha256(decoded).hexdigest())
    return track,proof


def export(output):
    output=Path(output).resolve()
    accepted=(ROOT/'kit/work/accepted').resolve()
    if output==accepted or accepted in output.parents:raise ValueError('candidate output cannot be accepted staging')
    output.mkdir(parents=True,exist_ok=True)
    rows={r['index']:r for r in resources()}
    tracks=[];proof=[]
    for name,index in (('palace',4),('audience',34)):
        track,origin=export_resource(output,name,rows[index]);tracks.append(track);proof.append(origin)
    document=dict(schema='suikoden-opening-audio/1',tracks=tracks)
    (output/'audio.json').write_text(json.dumps(document,indent=2)+'\n')
    files={name:hashlib.sha256((output/name).read_bytes()).hexdigest() for name in ('audio.json','palace.wav','audience.wav')}
    (output/'provenance.json').write_text(json.dumps(dict(schema='suikoden-opening-audio-proof/1',status='candidate; listening acceptance and promotion pending',sources=proof,files=files,scope='Stream selection, nominal sample rate, source volume and CD loop boundary. UI/exit SFX, exact device/fader timing and SPU pitch quantization remain outside this candidate.'),indent=2)+'\n')
    return document


if __name__=='__main__':
    result=export(ROOT/'kit/work/build/opening/audio')
    print(f"Exported {len(result['tracks'])} private palace audio candidates")

"""First VAA audience conversation for the shared field host; no new decoder/art."""
from pathlib import Path
import hashlib
import json
import struct

import area_scene
import opening_audience
import export_field_scene_contexts as contexts
from export_first_room import source
from export_opening_scene import portrait_payload

ROOT=Path(__file__).resolve().parents[2]


def export():
    raw,origin=source('/VAA.BIN');script,_=opening_audience.export()
    section=area_scene.section_off(raw,area_scene.room_record(raw,2)['section'])
    speaker=script['commands'][4]
    assert speaker['kind']=='speaker' and speaker['image']==110
    record=area_scene.character_bindings(raw,section)[speaker['image']]['record']
    image_offset,palette_offset=(area_scene.ptr_at(raw,record+offset)for offset in (4,8))
    plane,palette,length=portrait_payload(raw,image_offset,palette_offset)
    shared=json.loads((ROOT/'game/assets/field_dialogue.json').read_text())
    text=next(t for t in script['texts']if t['id']=='room_text_0')
    messenger=next(t for t in script['texts']if t['id']=='area_text_0_0')
    arrival=next(t for t in script['texts']if t['id']=='area_text_0_1')
    assert set(t['kind']for t in text['tokens'])=={'glyph','newline','page','player_name','countdown'}
    assert set(t['kind']for t in messenger['tokens'])=={'glyph','newline','player_name','countdown'}
    packet=dict(schema='suikoden-field-dialogue/6',anchors=[dict(program='vaa_room2_audience',command=3,box=0,actor='scene_actor_12'),dict(program='vaa_room2_audience',command=10,box=1,actor='scene_actor_10'),dict(program='vaa_room2_audience',command=22,box=1,actor='scene_actor_10')],
        texts=[dict(id='vaa_prefix_teo',tokens=[dict(kind='glyph',text=c)for c in speaker['name']]+[dict(kind='newline')]),text,messenger,arrival],
        prefixes=[dict(program='vaa_room2_audience',command=4,box=0,text=0,image=0)],
        images=[dict(id='teo_portrait',character=110,domain='area_custom',resource='vaa_room2_character_110',width=64,height=64,plane_sha256=hashlib.sha256(plane).hexdigest(),palette_sha256=hashlib.sha256(struct.pack('<256H',*palette)).hexdigest())],
        descriptor_changes=[],configuration=shared['configuration'],default_speed=shared['default_speed'],allow_pages=True,allow_substitution=True)
    packet=contexts.identified(packet)
    proof=dict(source=origin,script_start=0x50D80,first_conversation_commands=list(range(3,8)),following_unimplemented=dict(command=28,kind='cue',cue=1058),
        box=dict(raw_layout=12,producer='MAIN8013B490/8013B0C8',actor='scene_actor_12',source_entity=22,world_anchor=dict(x=472,y=600)),
        portrait=dict(record=record,image_offset=image_offset,palette_offset=palette_offset,compressed_bytes=length,decoder='existing export_opening_scene.portrait_payload / lzss.decode_strict'),
        text_id=text['id'],body_pages=1+sum(t['kind']=='page'for t in text['tokens']),messenger_box=dict(raw_layout=10,producer='MAIN8013B404/8013B0C8',actor='scene_actor_10',source_entity=14,world_anchor=dict(x=360,y=608),text_id=messenger['id']),return_box=dict(raw_layout=10,producer='MAIN8013B404/8013B0C8',actor='scene_actor_10',world_anchor=dict(x=120,y=608),text_id=arrival['id']),media_accepted=False,promoted=False)
    return packet,proof


if __name__=='__main__':
    packet,proof=export()
    for path,value in ((ROOT/'game/assets/vaa_field_dialogue.json',packet),(ROOT/'kit/data/reports/vaa_field_dialogue.json',proof)):
        path.write_text(json.dumps(value,indent=2)+'\n')

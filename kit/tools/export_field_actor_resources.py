"""Bind accepted ordinary identities to existing VAA constructor/resource data."""
from pathlib import Path
import hashlib
import json

import area_scene
import export_field_actor_bindings as binder
import opening_audience
from export_first_room import source

ROOT=Path(__file__).resolve().parents[2]


def export():
    path=ROOT/'game/assets/scenes/bindings/field_actor_bindings.json'
    accepted=json.loads(path.read_text());binder.validate_packet(accepted)
    scene=next(s for s in accepted['scenes']if s['id']=='vaa_room2')
    raw,origin=source('/VAA.BIN')
    actors,origins=opening_audience.actor_bindings(raw,2,bytearray(240))
    animations=opening_audience.animation_timings(raw,actors)
    section=area_scene.section_off(raw,area_scene.room_record(raw,2)['section'])
    resources=area_scene.character_bindings(raw,section)
    rows=[];provenance=[]
    for identity,actor,proof in zip(scene['scene_actors'],actors,origins,strict=True):
        assert identity['stable_actor_id']==actor['id'] and identity['source_order']==proof['entity']
        assert identity['baseline_compact_index']==int(actor['id'].rsplit('_',1)[1])
        assert identity['source_character_id']==proof['native_character']
        resource=resources[proof['native_character']]
        assert next(a for a in animations if a['graphic']==actor['graphic'])
        conditions=identity['classification']['terms']
        assert identity['classification']['pointer_state']=='present'
        assert all(t['kind']in ('story_mask_set','story_mask_clear')for t in conditions)
        rows.append(dict(id=actor['id'],entity=proof['entity'],slot=identity['baseline_compact_index'],resource=identity['resource_id'],graphic=actor['graphic'],x=actor['x'],y=actor['y'],speed=actor['motion'],variant=actor['variant'],auto_animate=actor['auto_animate'],conditions=conditions))
        provenance.append(dict(actor=actor['id'],source_entity=proof['entity'],classifier=proof['classifier'],character=proof['native_character'],context=resource['context']))
    packet=dict(schema='suikoden-field-ordinary-actors/1',scene='vaa_room2',binding_sha256=accepted['content_sha256'],population_sha256=scene['population_content_id'],event_sha256=scene['event_content_id'],actors=rows)
    packet['content_sha256']=hashlib.sha256(json.dumps(packet,sort_keys=True,separators=(',',':')).encode()).hexdigest()
    return packet,dict(source=origin,binding_file_sha256=hashlib.sha256(path.read_bytes()).hexdigest(),binding_content_sha256=accepted['content_sha256'],resources=provenance,constructor=['0x8012ED84','0x801346A8','0x80134470','0x801344C4','0x8012EA40'],scope='Ordinary source identities and construction-time resource/timing binding. No pixel export or media acceptance; source conditions are retained for explicit construction snapshots, not current-story reclassification.')


if __name__=='__main__':
    packet,proof=export()
    for path,value in ((ROOT/'game/assets/field_ordinary_actors.json',packet),(ROOT/'kit/data/reports/field_ordinary_actors.json',proof)):
        path.write_text(json.dumps(value,indent=2)+'\n')

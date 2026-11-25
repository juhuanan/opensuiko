"""Qualify the two existing source contexts for the shared field host; no new IR."""
from pathlib import Path
import hashlib
import json

ROOT=Path(__file__).resolve().parents[2]


def identified(value):
    value=dict(value)
    value['content_sha256']=hashlib.sha256(json.dumps(value,sort_keys=True,separators=(',',':')).encode()).hexdigest()
    return value


def export():
    rows=[]
    for room,content,population,dialogue,queue in (
        ('vb6_kobold_village','events/vb6_room6_field_host.json','scenes/population/vb6_room6.json','field_dialogue.json',True),
        ('vaa_room_2','events/vaa_audience_choice.json','scenes/population/vaa_room2.json',None,False)):
        event=json.loads((ROOT/'game/assets'/content).read_text())
        actors=json.loads((ROOT/'game/assets'/population).read_text())
        text=json.loads((ROOT/'game/assets'/dialogue).read_text()) if dialogue else json.loads((ROOT/'game/assets/vaa_field_dialogue.json').read_text())
        context=dict(schema='suikoden-field-scene-context/1',room=room,
            event_id=event['id'],event_sha256=event['content_sha256'],
            population_id=actors['id'],population_sha256=actors['content_sha256'],
            dialogue_sha256=text['content_sha256'],dialogue_counts=[len(text[key])for key in ('anchors','texts','prefixes','images','descriptor_changes')],
            party_queue=queue)
        if not queue:
            context['ordinary_sha256']=json.loads((ROOT/'game/assets/field_ordinary_actors.json').read_text())['content_sha256']
        rows.append(identified(context))
    return rows


if __name__=='__main__':
    for name,row in zip(('vb6_field_context.json','vaa_field_context.json'),export()):
        (ROOT/'game/assets'/name).write_text(json.dumps(row,indent=2)+'\n')

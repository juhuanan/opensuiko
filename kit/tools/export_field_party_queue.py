"""Named room6 temporary-party tracks; addresses stay in Python provenance."""
from pathlib import Path
import hashlib
import json

import maindec

ROOT = Path(__file__).resolve().parents[2]


def graphics():
    from export_first_room import source
    from parse_04play import Parser
    import character_table
    from preparation import stable_id
    records=character_table.by_id()
    resources=[];sources=[]
    for character in (2,6,35,38):
        record=records[character]
        raw,origin=source('/04_PLAY/'+record['sprite_file'])
        parser=Parser(raw,0);parser.parse_header();section=parser.parse_section('S2',parser.u32(0x28))
        assert raw[0]==character and len(section['f']['entries'])==4
        clips=[]
        for entry in section['f']['entries']:
            pairs=entry['sequence']['pairs']
            clips.append(dict(flags=raw[entry['target_file_offset']+1],
                ticks=[duration or 256 for _,duration in pairs],
                bounds=[dict(width=raw[sheet+2],height=raw[sheet+3])for index,_ in pairs
                        for sheet in (section['e']['entries'][index]['target_file_offset'],)]))
        resources.append(dict(character=character,id=stable_id(record['name']),clips=clips))
        sources.append(dict(character=character,source=origin,section=section['file_offset'],
            animations=[entry['target_file_offset']for entry in section['f']['entries']]))
    result=dict(schema='suikoden-field-party-graphics/1',resources=resources)
    result['content_sha256']=hashlib.sha256(json.dumps(result,sort_keys=True,separators=(',',':')).encode()).hexdigest()
    return result,dict(sources=sources,producer='export_field_party_queue.graphics; existing parse_04play S2 model',
        content_sha256=result['content_sha256'],
        consumers=['0x8013A770','0x8013A808','0x8012EA40','0x8013CCF0','0x8013C7A4','0x8013096C','0x800C3DAC','0x800C4244'],
        source_cases=32,reference='kit/tests/test_field_party_queue.py:graphics_vectors',
        decode='Each canonical strict stream is fully consumed and its16384-byte plane agrees with original800C3144. Original alignment reads/outputs are measured separately from the fixed128x128 uploaded plane.',
        scope='Four construction-owned loaded-party resources only. Full8013096C captures main emission before interpolation and moving/idle-to1-or3 clocks through spread/return/four facings. Shadows, missingKirkis4, other actors and human media acceptance remain separate.',
        media_accepted=False,promoted=False)


def export():
    body = maindec.body()
    direction = ('down', 'up', 'left', 'right')
    mapping = tuple(maindec.mword(0x80171B98+4*i) for i in range(4))
    assert mapping == (1, 3, 0, 2)
    tracks, provenance = [], []
    for phase, table in (('spread', 0x80171A78), ('return', 0x80171B38)):
        for facing in range(4):
            for follower in range(5):
                pointer = maindec.mword(table+facing*20+follower*4)
                offset, commands = pointer-maindec.MBASE, []
                for _ in range(16):
                    opcode = body[offset]; offset += 1
                    if opcode == 5:
                        commands.append(dict(kind='finish')); break
                    assert opcode < 4
                    count = body[offset]; offset += 1
                    commands.append(dict(kind='move', direction=direction[mapping[opcode]], cells=count))
                else:
                    raise AssertionError('unterminated party track')
                name = f'{phase}_{direction[facing]}_{follower}'
                tracks.append(dict(id=name, actor='party_follower', commands=commands))
                provenance.append(dict(id=name, pointer=pointer, bytes=body[pointer-maindec.MBASE:offset].hex()))
    result = dict(schema='suikoden-field-party-queue/1', anchor=dict(x=216, y=200), tracks=tracks)
    result['content_sha256'] = hashlib.sha256(json.dumps(result, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    return result, dict(source=dict(file='MAIN.EXE', lba=maindec.EXE_LBA, size=maindec.EXE_SIZE,
        header_bytes=maindec.EXE_HEADER, image_sha256=hashlib.sha256(body).hexdigest()),
        producer='kit/tools/export_field_party_queue.py', content_sha256=result['content_sha256'], tracks=provenance,
        consumers=['0x8013A808', '0x8013C4E4', '0x8013C5F4', '0x8013E7E0', '0x8013CCF0', '0x8013AE4C', '0x8013C6F4'],
        scope='Room6 anchor216/200 only; all six logical party sizes/four facings,48 spread/return cases and836 source-consumer updates independently agree with the named model. Only allocation/graphics boundaries are substituted; original terrain/collision, queue and descriptor-transition instructions run.',
        ownership='Temporary descriptors are not recruited members or accepted drawable actors.', media_accepted=False, promoted=False)


if __name__ == '__main__':
    packet, proof = export()
    (ROOT/'game/assets/field_party_queue.json').write_text(json.dumps(packet, indent=2)+'\n')
    (ROOT/'kit/data/reports/field_party_queue.json').write_text(json.dumps(proof, indent=2)+'\n')
    packet, proof = graphics()
    (ROOT/'game/assets/field_party_graphics.json').write_text(json.dumps(packet, indent=2)+'\n')
    (ROOT/'kit/data/reports/field_party_graphics.json').write_text(json.dumps(proof, indent=2)+'\n')

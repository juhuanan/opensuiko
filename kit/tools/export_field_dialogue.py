"""Scoped box anchors for the existing room6 arrival, not a general actor resolver."""
from pathlib import Path
import hashlib
import json

import area_scene
import event_script_decode
import maindec
import opening_audience
import character_table
from parse_04play import Parser
from export_opening_scene import portrait_payload, dialogue_font_art
import struct
from export_first_room import source

ROOT = Path(__file__).resolve().parents[2]


def export():
    raw, origin = source('/VB6.BIN')
    entity = area_scene.entities(raw, area_scene.room_record(raw, 6))[5]
    instructions = list(event_script_decode.decode_stream(raw, entity['stream_offsets'][2], max_insns=28))
    base = json.loads((ROOT/'game/assets/events/vb6_room6_arrival.json').read_text())
    program = base['programs'][0]
    anchors, evidence = [], []
    for index, command in enumerate(program['commands']):
        if command['kind'] != 'open_box': continue
        offset, opcode, operands, _ = instructions[index]
        assert opcode == (11 if command['box'] == 0 else 23)
        assert operands == bytes((command['layout'],)) and operands[0] in (64,65)
        anchors.append(dict(program=program['id'], command=index, box=command['box'],
                            follower=operands[0]-64))
        evidence.append(dict(command=index, offset=offset, opcode=opcode, operands=operands.hex()))
    assert anchors == [dict(program=program['id'], command=i, box=b, follower=f) for i,b,f in ((4,0,1),(11,1,0),(18,0,1))]
    descriptor_changes=[]
    for index,command in enumerate(program['commands']):
        if command['kind'] != 'descriptor_flags':continue
        offset,opcode,operands,_=instructions[index]
        assert opcode==17 and operands[0]==command['selector']
        assert operands[0] in (64,65) and operands[1]<4
        direction=maindec.mword(0x80171B98+4*operands[1])
        assert direction==command['parameter']
        descriptor_changes.append(dict(program=program['id'],command=index,follower=operands[0]-64,
            direction=('down','up','left','right')[direction]))
    image_code = 4
    section = area_scene.section_off(raw,area_scene.room_record(raw,6)['section'])
    custom = area_scene.ptr_at(raw,section+0x34)
    custom_ids=[]
    for i in range(128):
        record = area_scene.ptr_at(raw,custom+4*i)
        if record is None:break
        custom_ids.append(area_scene.u32(raw,record))
    else:raise AssertionError('unterminated custom image list')
    assert image_code not in custom_ids and 2 not in custom_ids
    image = maindec.body()
    rank = next(i+1 for i in range(109) if image[0x80170095-maindec.MBASE+i] == image_code)
    name_pointer = maindec.mword(0x80170588+rank*4)
    end = image.index(0,name_pointer-maindec.MBASE)
    name = image[name_pointer-maindec.MBASE:end]
    prefix, _ = opening_audience.text(name+b'\x03\0',0)
    assert ''.join(t.get('text','') for t in prefix) == 'Kirkis'
    texts = [dict(id='vb6_prefix_kirkis',tokens=prefix)]
    root = area_scene.ptr_at(raw,0)
    tables = area_scene.ptr_at(raw,root+0x14)
    text_sources = []
    for command in program['commands']:
        if command['kind'] != 'text': continue
        table = area_scene.ptr_at(raw,tables+command['table']*4)
        pointer = area_scene.ptr_at(raw,table+command['index']*4)
        tokens,end = opening_audience.text(raw,pointer)
        texts.append(dict(id=command['text'],tokens=tokens))
        text_sources.append(dict(id=command['text'],offset=pointer,end=end))
    gremio,portrait_source=source('/04_PLAY/GRE.BIN')
    assert gremio[0]==2
    header=Parser(gremio,0).parse_header()
    image_offset,palette_offset=[header['slots'][i]['raw_file_offset'] for i in (3,4)]
    plane,palette,compressed=portrait_payload(gremio,image_offset,palette_offset)
    gremio_name_rank=next(i+1 for i in range(109) if image[0x80170095-maindec.MBASE+i]==2)
    gremio_name_offset=maindec.mword(0x80170588+gremio_name_rank*4)-maindec.MBASE
    gremio_tokens,_=opening_audience.text(image[gremio_name_offset:image.index(0,gremio_name_offset)]+b'\x03\0',0)
    assert ''.join(t.get('text','') for t in gremio_tokens)=='Gremio'
    texts.append(dict(id='vb6_prefix_gremio',tokens=gremio_tokens))
    image_resource=dict(id='gremio_portrait',character=2,width=64,height=64,
        plane_sha256=hashlib.sha256(plane).hexdigest(),palette_sha256=hashlib.sha256(struct.pack('<256H',*palette)).hexdigest())
    configuration = [dict(normal_pace=image[0x80171885-maindec.MBASE+4*i],
                          pressed_pace=image[0x80171884-maindec.MBASE+4*i]) for i in range(3)]
    boot_image = character_table.image()
    default_speed = boot_image[0x32FE0+0x1B90]
    assert default_speed == 1 and configuration == [dict(normal_pace=a,pressed_pace=b) for a,b in ((1,0),(3,1),(5,2))]
    packet = dict(schema='suikoden-field-dialogue/5', anchors=anchors,texts=texts,descriptor_changes=descriptor_changes,
        configuration=configuration,default_speed=('fast','normal','slow')[default_speed],
        images=[image_resource],prefixes=[dict(program=program['id'],command=index,box=0,text=0,absent_character=image_code) for index in (5,19)]+[
            dict(program=program['id'],command=12,box=1,text=4,image=0)])
    packet['content_sha256'] = hashlib.sha256(json.dumps(packet,sort_keys=True,separators=(',',':')).encode()).hexdigest()
    proof = dict(source=origin, main_image_sha256=hashlib.sha256(maindec.body()).hexdigest(),
        producer='kit/tools/export_field_dialogue.py', source_content_sha256=base['content_sha256'],
        content_sha256=packet['content_sha256'], instructions=evidence,
        name_lookup=dict(character=image_code,rank=rank,pointer=name_pointer),text_sources=text_sources,
        descriptor_changes=dict(consumers=['0x8013CE08','0x8013CCF0','0x8013C7A4'],
            source_cases=64,raw_to_ir_parameters=[dict(command=10,raw=3,ir=2),dict(command=17,raw=1,ir=3)],
            scope='Only the already constructed temporary party descriptors used by arrival commands10/17; no ordinary actor construction/resolver. Direction changes flags and the logical sprite variant; animation/render attachment remains separate.'),
        matching_image=dict(source=portrait_source,image_offset=image_offset,palette_offset=palette_offset,
            name_lookup=dict(character=2,rank=gremio_name_rank,pointer=gremio_name_offset+maindec.MBASE),
            compressed_bytes=compressed,resource=image_resource,decoder='Existing export_opening_scene.portrait_payload / lzss.decode_strict',
            consumers=['0x8013AE80','0x8013FB58','0x8013F584','0x8013F4B8','0x800C3144','0x8013F37C'],
            scope='Loaded-party character2 only; original matching lookup, full decompressor and image descriptor agree with existing Python extraction. Logical request state, no media/render acceptance.'),
        body_queue=dict(source_cases=6,source_updates=159,reference='kit/tests/test_field_dialogue.py:body_queue_vectors',
            consumers=['0x8013F110','0x8013F0C0','0x8013B8CC','0x8013B7A0','0x8013F9B0','0x8013F888','0x8013F960','0x8013F6F8'],
            configuration=configuration,default_speed_source=dict(file='SLUS_002.92',image_offset=0x32FE0+0x1B90,
                image_sha256=hashlib.sha256(boot_image).hexdigest(),value=default_speed),
            preconditions='Open30x5 box; source first body text; no concurrent field/actor work; page, held-scroll and substitutions are not covered.',
            contract='Producer stages after the glyph pass; first glyph on next update. Active body gates the VM. Pressed reveal runs on the next glyph pass; completion clears the gate before the next wait-for-accept tick.'),
        consumers=['0x8013B490','0x8013B404','0x8013B0C8','0x8013AFA0','0x8013B2F4','0x8013E220','0x80145A1C'],
        contract='Existing temporary party descriptor only; world anchor is descriptor cell position+(8,-24). Presentation must supply the source camera separately. Open/close duration20; reuse proven opening_audience.Box transition/interpolation.',
        unsupported=['paged/substituted body streams and held page-scroll timing','ordinary/other actor anchors','other matching resources/speaker prefixes','box sound dispatch and media acceptance'],media_accepted=False,promoted=False)
    return packet, proof


def export_art(output):
    """Candidate UI only; logical image IDs come from the existing dialogue contract."""
    output=Path(output).resolve()
    if (ROOT/'kit/work/accepted').resolve() in (output,*output.parents):
        raise ValueError('candidate export cannot write accepted content')
    from PIL import Image
    from export_first_room import Atlas, hero_clips
    from export_field_party_queue import graphics
    from psx_vram import rgb555_to_rgb888
    packet, proof = export()
    atlas = Atlas()
    glyphs, window, font_proof = dialogue_font_art(atlas)
    raw, origin = source('/04_PLAY/GRE.BIN')
    header = Parser(raw, 0).parse_header()
    image_offset, palette_offset = [header['slots'][i]['raw_file_offset'] for i in (3,4)]
    plane, palette, _ = portrait_payload(raw, image_offset, palette_offset)
    resource = packet['images'][0]
    assert raw[0] == resource['character']
    assert hashlib.sha256(plane).hexdigest() == resource['plane_sha256']
    assert hashlib.sha256(struct.pack('<256H', *palette)).hexdigest() == resource['palette_sha256']
    image = Image.new('RGBA', (64,64))
    image.putdata([(*rgb555_to_rgb888(palette[index]), 0 if palette[index] == 0 else 255) for index in plane])
    art = dict(schema='suikoden-field-dialogue-art/1', atlas='atlas.png',
        content_sha256=packet['content_sha256'], glyphs=glyphs, window=window,
        portraits=[dict(image=0, id=resource['id'], rect=atlas.add(image),
                        plane_sha256=resource['plane_sha256'], palette_sha256=resource['palette_sha256'])])
    actor_graphics, actor_proof=graphics()
    art['followers']=[];clip_proofs=[]
    for resource,actor_source in zip(actor_graphics['resources'],actor_proof['sources'],strict=True):
        actor_raw,actor_origin=source('/04_PLAY/'+Path(actor_source['source']['file']).name)
        clips,clip_proof=hero_clips(actor_raw,atlas)
        assert actor_raw[0]==resource['character']
        art['followers'].append(dict(character=resource['character'],id=resource['id'],content_sha256=actor_graphics['content_sha256'],clips=clips))
        clip_proofs.append(dict(character=resource['character'],source=actor_origin,art=clip_proof))
    output.mkdir(parents=True, exist_ok=True)
    atlas.save(output/'atlas.png')
    art['atlas_sha256']=hashlib.sha256((output/'atlas.png').read_bytes()).hexdigest()
    (output/'ui.json').write_text(json.dumps(art,indent=2)+'\n')
    (output/'provenance.json').write_text(json.dumps(dict(
        exporter='export_field_dialogue.py/1', dialogue=proof['content_sha256'],
        font=font_proof, portrait=dict(source=origin,image_offset=image_offset,palette_offset=palette_offset,
            decoder='export_opening_scene.portrait_payload / lzss.decode_strict'),
        follower=dict(source=actor_proof,art=clip_proofs,decoder='existing export_first_room.hero_clips / parse_04play S2 / lzss.decode_strict'),
        status='candidate; human media acceptance and promotion pending',
        files={name:hashlib.sha256((output/name).read_bytes()).hexdigest() for name in ('atlas.png','ui.json')}),indent=2)+'\n')
    return art


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('--art-output', type=Path, help='Generate candidate UI there instead of rewriting tracked contracts')
    args = parser.parse_args()
    if args.art_output:
        export_art(args.art_output)
    else:
        packet, proof = export()
        (ROOT/'game/assets/field_dialogue.json').write_text(json.dumps(packet,indent=2)+'\n')
        (ROOT/'kit/data/reports/field_dialogue.json').write_text(json.dumps(proof,indent=2)+'\n')

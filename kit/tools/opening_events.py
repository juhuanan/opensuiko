"""Compile only the two proven VAA-room2 initialization streams into named actions."""
from pathlib import Path
import json
import struct
import area_scene
import character_table
import event_script_decode
import maindec
from export_first_room import source

ROOT = Path(__file__).resolve().parents[2]
ACTORS = (0, 1, 2, 3, 7, 8, 9)


def compile_stream(data, start):
    commands, spans = [], []
    for offset, opcode, operands, note in event_script_decode.decode_stream(data, start):
        if 'truncat' in note.lower():
            raise ValueError('truncated opening command')
        if opcode == 0x41:
            cue = struct.unpack_from('<H', maindec.body(), 0x80171C2C-maindec.MBASE+2*operands[0])[0]
            if cue != 0x81: raise ValueError('unsupported opening cue')
            command = dict(kind='select_cue', cue=cue)
        elif opcode == 0x3A:
            if operands[0] not in ACTORS: raise ValueError('unsupported descriptor')
            command = dict(kind='release_actor', actor=f'descriptor_{operands[0]}')
        elif opcode in (0x30, 0x31, 0xFD):
            command = dict(kind={0x30:'continue_tick', 0x31:'yield_tick', 0xFD:'end_stream'}[opcode])
        else:
            raise ValueError(f'unsupported opening opcode {opcode:#x}')
        commands.append(command)
        spans.append(dict(offset=offset, opcode=opcode, operands=operands.hex()))
        if opcode == 0xFD: return commands, spans
    raise ValueError('unterminated opening stream')


def export():
    data, proof = source('/VAA.BIN')
    entries = area_scene.entities(data, area_scene.room_record(data, 2))
    initialization = [entry['index'] for entry in entries if entry['flags'] & 0x10]
    if initialization != [23,24]: raise ValueError('unsupported initialization entry/order')
    programs, provenance = [], []
    for index in (23, 24):
        entry = entries[index]
        if not entry['flags'] & 0x10: raise ValueError('not an initialization entry')
        predicate, stream = entry['stream_offsets'][1:]
        if data[predicate] == 6: condition = 'always'
        elif data[predicate:predicate+4] == bytes.fromhex('07 00 40 06'): condition = 'story_0006'
        else: raise ValueError('unsupported opening predicate')
        commands, spans = compile_stream(data, stream)
        id = f'vaa_room2_init_{index}'
        programs.append(dict(id=id, condition=condition, commands=commands))
        provenance.append(dict(id=id, entity=index, predicate=predicate, stream=stream, instructions=spans))
    image = character_table.image()
    initial = bool(image[0x32FE0+0x190] & 0x40)
    runtime = dict(schema='suikoden-opening-events/2', room='vaa_room_2',
                   initial_flags=dict(story_0006=initial), programs=programs,
                   initialization_order=[p['id'] for p in programs])
    _, boot = source('SLUS_002.92')
    evidence = dict(schema='suikoden-opening-event-evidence/1', source=proof, boot=boot,
        boot_flag_image_offset=0x32FE0+0x190, flag=dict(id='story_0006',bank='scenario',byte_index=0,mask=64),
        programs=provenance, omitted_entities=[e['index'] for e in entries if e['index'] not in (23,24)],
        consumers=['MAIN:0x801318C8','MAIN:0x801318D4','MAIN:0x8013F2A4','MAIN:0x80132B80','MAIN:0x8013DB6C','MAIN:0x8013D6CC','MAIN:0x8013E028','MAIN:0x8013E17C',
                   'MAIN:0x80139930','MAIN:0x80142440','MAIN:0x8013C82C'],
        scope='Selected streams and one-pump-per-eligible-entry initialization pass only; ordinary event selection, first feasible story path, actor/resource mapping, text objects and cue playback remain outside this export.')
    return runtime, evidence


if __name__ == '__main__':
    runtime, evidence = export()
    for path, value in ((ROOT/'game/assets/opening_events.json', runtime),
                        (ROOT/'kit/data/reports/opening_events.json', evidence)):
        path.write_text(json.dumps(value, indent=2)+'\n')
    print('Exported two canonical-room initialization programs; other paths unsupported.')

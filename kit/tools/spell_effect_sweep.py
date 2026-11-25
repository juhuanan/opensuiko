#!/usr/bin/env python3
"""Inventory every named battle spell effect initializer by section."""
import hashlib
import json
import struct
from pathlib import Path

import battle_bin
import maindec

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'kit/data/reports/spell_effect_sweep.json'
TABLE = ROOT / 'kit/data/reports/battle_camera_setup_table.md'


def initializers():
    for line in TABLE.read_text().splitlines():
        if not line.startswith('| 0x'):
            continue
        cells = [c.strip() for c in line.strip('|').split('|')]
        if len(cells) < 4 or not cells[1].startswith('0x') or not cells[3] or cells[3] == '-':
            continue
        yield cells[3], int(cells[1], 16)


def graphics_bindings(initializer,constructor=0x801233b4):
    from spell_scene_source import Image,Analysis,analyze
    facts,_=analyze(initializer);image=Image();bindings=[]
    for entry in [initializer]+facts['preparation']:
        analysis=Analysis(image,entry,cut_backedges=True)
        for site,event in analysis.events('call'):
            if event[1]!=constructor:continue
            owner,animation=event[2][:2]
            if isinstance(owner,tuple) and owner[0]=='member' and owner[1]==('stack',):
                stores=[(pc,e[2]) for pc,e in analysis.events('store') if pc<site and e[1]==owner]
                values={value for _,value in stores}
                if len(values)==1:
                    def reachable_without(avoid):
                        pending=[analysis.entry];seen=set()
                        while pending:
                            pc=pending.pop()
                            if pc in seen or pc==avoid:continue
                            if pc==site:return True
                            seen.add(pc);pending.extend(analysis.edges.get(pc,()))
                        return False
                    if any(not reachable_without(pc) for pc,_ in stores):owner=values.pop()
            if not isinstance(owner,tuple) or len(owner)!=2 or owner[0]!='global' or not 0x800AA004<=owner[1]<=0x800AA020 or (owner[1]-0x800AA000)%4:raise ValueError(f'unresolved spell graphics binding at {site:#x}')
            row=dict(site=site,section=(owner[1]-0x800AA000)//4)
            if constructor==0x80122aac:
                if image.word(0x80122B10)!=0x34050002:raise ValueError('screen-wave piece binding changed')
                row['piece']=2
            else:row['animation']=animation
            bindings.append(row)
    if not bindings and constructor==0x801233b4:raise ValueError(f'no graphics constructor in initializer chain {initializer:#x}')
    return bindings


def section_for(initializer):
    return graphics_bindings(initializer)[0]['section']


def phase_animations(initializer):
    return list(dict.fromkeys(binding['animation'] for binding in graphics_bindings(initializer) if isinstance(binding['animation'],int)))


def entries(section):
    data = section['_data']
    pointer = lambda off: struct.unpack_from('<I', data, off)[0] - battle_bin.LOAD_BASE
    pieces, animations = [], []
    for i in range(section['a_e_count']):
        off = pointer(section['tables']['e'] + 4 * i)
        count = data[off]
        pieces.append(dict(id=f'piece_{i}', source_offset=off, header=list(data[off:off + 8]),
                           entries=[list(data[off + 8 + 8 * j:off + 16 + 8 * j]) for j in range(count)]))
    for i in range(section['b_f_count']):
        off = pointer(section['tables']['f'] + 4 * i)
        count = data[off]
        animations.append(dict(id=f'animation_{i}', source_offset=off,
                               frames=[dict(piece=f'piece_{data[off + 4 + 2 * j]}',
                                            ticks=data[off + 5 + 2 * j] or 256)
                                       for j in range(count)]))
    return pieces, animations


def build():
    sections, atlases, errors, data = battle_bin.parse()
    if errors:
        raise ValueError(errors)
    for section in sections:
        section['_data'] = data
    palette = next(a for a in atlases if a['offset'] == sections[1]['atlas_offsets'][9])
    source = dict(blob_offset=palette['offset'], decoded_sha256=hashlib.sha256(palette['atlas']).hexdigest(),
                  upload_rect_words=[896, 384, 64, 128], bank_rect_words=[928, 384, 32, 128],
                  slot_offset_formula='128*(slot//2) + 64 + 32*(slot%2)')
    effects = []
    for name, initializer in initializers():
        graphics=graphics_bindings(initializer);waves=graphics_bindings(initializer,0x80122aac)
        sid=graphics[0]['section']
        pieces, animations = entries(sections[sid])
        effects.append(dict(name=name, initializer=f'0x{initializer:08X}', section=sid,
                            phase_animations=list(dict.fromkeys(b['animation'] for b in graphics if isinstance(b['animation'],int))),graphics_bindings=graphics,screen_wave_bindings=waves,auxiliary_sections=list(dict.fromkeys(b['section'] for b in graphics+waves if b['section']!=sid)),
                            pieces=pieces, animations=animations, palette_source=source))
    return dict(schema='suikoden-spell-effect-sweep/2', ready_for_runtime=False,
                source=dict(file=battle_bin.DISC_PATH, decoder=battle_bin.DECODER_ID,
                            sha256=hashlib.sha256(data).hexdigest()), effects=effects)


if __name__ == '__main__':
    value = build()
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(value, indent=2) + '\n')
    print(f'{len(value["effects"])} spell effects inventoried')

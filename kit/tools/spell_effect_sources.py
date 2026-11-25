#!/usr/bin/env python3
"""Inventory two source spell graphics and their embedded packed palette bank."""
import argparse
import hashlib
import json
from pathlib import Path
import struct

import battle_bin
import maindec

ROOT = Path(__file__).resolve().parents[2]
DEFAULT = ROOT / 'kit/data/reports/spell_effect_sources.json'
EFFECTS = ((1, 'flaming_arrows', 1, 0x800FEB14), (9, 'drops_of_kindness', 3, 0x801058D4))


def drops_choreography():
    """Static update facts; phase ticks exclude loading, teardown and frame-driver alignment."""
    def immediate(pc, expected):
        word = maindec.mword(pc)
        value = word & 65535
        if value != expected:
            raise ValueError(f'Drops instruction immediate changed at {pc:#x}')
        return value
    counts = [immediate(pc, value) for pc, value in
              [(0x80105D08, 64), (0x80105D44, 32), (0x80105DE0, 90),
               (0x80105E38, 60), (0x80105EE4, 60)]]
    # Source dispatch jump-table order is distinct from linear code order.
    cases = [maindec.mword(0x800C151C + 4*i) for i in range(5)]
    if cases != [0x80105C64, 0x80105D0C, 0x80105D68, 0x80105DF4, 0x80105E60]:
        raise ValueError('Drops phase dispatcher changed')
    phases, start = [], 0
    for i, ticks in enumerate(counts):
        phases.append(dict(id=i, start_update=start, updates=ticks,
                           caster_visible=i < 2, target_objects_visible=i >= 2,
                           hide_caster_on_last_update=i == 1,
                           hide_target_objects_on_last_update=i == 4,
                           source_callback=f'0x{cases[i]:08X}'))
        start += ticks
    return dict(schema='suikoden-effect-choreography/1',
                initializer='0x801058D4', updater='0x80105BC8',
                phases=phases, update_count=start,
                tick_convention='Zero-based callback updates; transitions affect the current draw. Last update disables target objects before drawing.',
                camera=dict(phase=0, block='0x8016D97C', transition_updates=immediate(0x80105C88, 60)),
                caster=dict(animation=0, node_scale_initial=1,
                            node_scale_delta=[immediate(0x80105CB4, 64), immediate(0x80105D24, 128), 0, 0, 0],
                            draw_translation=[0, 0, -70]),
                target_objects=dict(count=immediate(0x80105A98, 6), animation=3,
                                    local_position=dict(x=20, y=0, z='-(random % 100)'),
                                    node_scale='2048 + random % 4096',
                                    initial_rotation='random % 4096',
                                    rotation_delta_per_visible_update=immediate(0x80106038, 32),
                                    wrapper_scale_shift=12,
                                    wrapper_scale_initial=[1, 1, 16777216],
                                    wrapper_scale_xy_delta=[0, 0, 186413, 0, -279620]),
                intensity=dict(initial=0, shift=12, output_bits=8,
                               delta_per_phase=[8192, -16384, 5779, 0, -8669]),
                heal=dict(phase=4, on_phase_completion=True),
                ready_for_runtime=False,
                unresolved=['Human acceptance of the composed review scene.',
                            'Native windowed pixel comparison and PS1 subpixel raster precision.'])


def report():
    sections, atlases, errors, data = battle_bin.parse()
    if errors:
        raise ValueError(errors)
    # Spell setup 801205FC queues section 1 at slots 30..39, including its CLUTs.
    offsets = sections[1]['atlas_offsets']
    if len(offsets) != 10 or any(s['atlas_offsets'] != offsets for s in sections[1:]):
        raise ValueError('spell sections no longer share the ten-page pool')
    palette_blob = next(a for a in atlases if a['offset'] == offsets[9])
    palette_source = dict(blob_offset=palette_blob['offset'],
                          compressed_size=palette_blob['compressed_len'],
                          decoded_size=len(palette_blob['atlas']),
                          decoded_sha256=hashlib.sha256(palette_blob['atlas']).hexdigest(),
                          texture_slot=39, upload_rect_words=[896, 384, 64, 128],
                          bank_rect_words=[928, 384, 32, 128],
                          slot_count=256, colours_per_slot=16, colour_format='psx_rgb555',
                          decoded_row_stride_bytes=128, decoded_bank_x_bytes=64,
                          slot_offset_formula='128*(slot//2) + 64 + 32*(slot%2)')
    effects = []
    pointer = lambda off: struct.unpack_from('<I', data, off)[0] - battle_bin.LOAD_BASE
    for native_id, id, section_id, initializer in EFFECTS:
        section = sections[section_id]
        pieces, animations = [], []
        for i in range(section['a_e_count']):
            off = pointer(section['tables']['e'] + 4*i)
            if off < 0 or off + 8 > len(data):
                raise ValueError('effect piece header outside source')
            count = data[off]
            if off < 0 or off + 8 + 8*count > len(data):
                raise ValueError('effect piece outside source')
            pieces.append(dict(id=f'piece_{i}', source_offset=off,
                               header=list(data[off:off+8]),
                               entries=[list(data[off+8+8*j:off+16+8*j]) for j in range(count)]))
        for i in range(section['b_f_count']):
            off = pointer(section['tables']['f'] + 4*i)
            if off < 0 or off + 4 > len(data):
                raise ValueError('effect animation header outside source')
            count = data[off]
            if off < 0 or off + 4 + 2*count > len(data):
                raise ValueError('effect animation outside source')
            frames = [dict(piece=f'piece_{data[off+4+2*j]}', ticks=data[off+5+2*j] or 256) for j in range(count)]
            if any(int(f['piece'].removeprefix('piece_')) >= len(pieces) for f in frames):
                raise ValueError('effect animation references missing piece')
            animations.append(dict(id=f'animation_{i}', source_offset=off, frames=frames))
        effects.append(dict(id=id, native_spell_id=native_id, section=section_id,
                            initializer=f'0x{initializer:08X}', texture_mode='indexed4',
                            palette_selection='packed_16_colour_slots',
                            palette_source=palette_source, pieces=pieces, animations=animations,
                            choreography=drops_choreography() if native_id == 9 else None))
    lba, size = battle_bin.battle_bin_lba()
    return dict(schema='suikoden-spell-effect-source-report/3', ready_for_runtime=False,
                source=dict(file=battle_bin.DISC_PATH, lba=lba, size=size,
                            sha256=hashlib.sha256(data).hexdigest(), decoder=battle_bin.DECODER_ID,
                            main_image_sha256=hashlib.sha256(maindec.body()).hexdigest()),
                effects=effects, decoded_blob_count=len(atlases),
                blockers=['Export complete cast/impact/lifetime sequences and sampled piece geometry.',
                          'Obtain user acceptance of composed image/audio previews.'])


def write(path=DEFAULT, verify=False):
    path = Path(path)
    if (ROOT / 'kit/work/accepted').resolve() in (path.resolve(), *path.resolve().parents):
        raise ValueError('source report cannot promote accepted content')
    value = report()
    encoded = json.dumps(value, indent=2) + '\n'
    if verify:
        if not path.is_file() or path.read_text() != encoded:
            raise ValueError('spell effect source report is stale')
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(encoded)
    return value


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, default=DEFAULT)
    parser.add_argument('--verify', action='store_true')
    args = parser.parse_args()
    value = write(args.out, args.verify)
    print(f"{len(value['effects'])} source effects inventoried; embedded palette located; choreography/media gates remain")

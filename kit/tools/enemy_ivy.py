#!/usr/bin/env python3
"""Static Ivy/Mad Ivy vine controller and source art; never admits an encounter."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import lzss
import maindec

from export_first_room import ROOT, source
from export_physical_runes import stream
from export_battle_trial import section_art

REPORT = ROOT / 'kit/data/reports/enemy_ivy.json'
SOURCES = (
    ('mad_ivy', 'D', 0x22ac0, 0x5c0, 0xea4, 0x19f8, 0x1c38,
     'a655e264fee0d6fad457d881b543f9477f7c61b9c1bc6e3fd11ec8c2d1107390',
     '65b02752ced3ddce7c8d9c3a85aa794b33064932e7a970b9ff56430ee793e545'),
    ('ivy', 'F', 0x21014, 0x370, 0xc54, 0x17a8, 0x19e8,
     'be7aac69f3c5a8c17e609cbf6fea358e8a004ad93630625897678d1e92230209',
     '7360e7d5c4c8964e9c9e88ddf5023e7bbcca347fa1a955ff33ed1380c5b444f2'),
)
CURVE_HASH = 'fe4c9c94183208ab15c80da608712cb059459b59e3aba5b64a5ed5f323217a5c'


def build():
    main, main_origin = source('MAIN.EXE')
    base = struct.unpack_from('<I', main, 24)[0]
    normalizer = []
    for start, end, expected in (
        (0x8014f068, 0x8014f100, '9883e018cc26fbdda9088813a114767ef2b364667a383f30b10b701793f78be0'),
        (0x8017242c, 0x801725ac, '45ca1b7b619b33961c03c82243b8baf59fc50c49b4d7eefc94b76edbd417a5c8'),
    ):
        offset = maindec.EXE_HEADER + start - base
        actual = hashlib.sha256(main[offset:offset+end-start]).hexdigest()
        if actual != expected:
            raise ValueError('Ivy segment normalizer changed')
        normalizer.append(dict(offset=offset, size=end-start, sha256=actual))
    actors = []
    for identifier, region, record, init, update, curve, end, init_hash, update_hash in SOURCES:
        raw, origin = source('/' + region + '_DATA.BIN')
        pointer = lambda offset: struct.unpack_from('<I', raw, offset)[0] - 0x80080000
        blocks = []
        for start, stop, expected in ((init, update, init_hash), (update, curve, update_hash), (curve, end, CURVE_HASH)):
            actual = hashlib.sha256(raw[start:stop]).hexdigest()
            if actual != expected:
                raise ValueError(f'{identifier} vine source changed at {start:#x}')
            blocks.append(dict(offset=start, size=stop-start, sha256=actual))
        table = pointer(record + 40)
        if pointer(table + 9*4) != init:
            raise ValueError('Ivy local slot9 initializer changed')
        scripts = []
        for slot in (1, 2, 4):
            operations, spans = stream(raw, origin, pointer(table + slot*4), table, 0x80080000)
            scripts.append(dict(slot=slot, operations=operations, spans=spans))
        if dict(op=35, args=[1, 9]) not in scripts[0]['operations']:
            raise ValueError('Ivy attack no longer invokes local slot9')
        section = pointer(record + 44)
        poses, _, details = section_art(raw, section, 0x80080000, animation_indices=[0, 10, 11, 12], selected_poses_only=True)
        pages = []
        for index in range(raw[section+4]):
            blob = pointer(pointer(section+8) + 4*index)
            size = struct.unpack_from('<I', raw, blob)[0]
            pages.append(dict(offset=blob+4, size=size, sha256=hashlib.sha256(raw[blob+4:blob+4+size]).hexdigest()))
        art = []
        for role, pose in (('idle', 0), ('vine', 7), ('leaf_even', 6), ('leaf_odd', 8)):
            image, x, y = poses[pose]
            art.append(dict(role=role, pose=pose, path=f'{identifier}/{role}.png', width=image.width,
                            height=image.height, anchor=[x, y], rgba_sha256=hashlib.sha256(image.tobytes()).hexdigest()))
            if role.startswith('leaf_'):
                descriptor = pointer(pointer(section + 16) + 4*pose)
                art[-1]['destination_extent'] = list(raw[descriptor+12:descriptor+14])
        actors.append(dict(id=identifier, source=origin, record_offset=record, section_offset=section,
                           blocks=blocks, scripts=scripts, art=art, graphics=details, compressed_pages=pages,
                           decoder=f'lzss.py v{lzss.__version__} decode_strict; export_battle_trial.py section_art'))
    return dict(schema='suikoden-enemy-ivy/1', producer='enemy_ivy.py v1', status='static_source_candidate',
                actors=actors, units='world Q12; curve terms truncate independently with signed32 wrapping',
                segment_normalizer=dict(source=main_origin, blocks=normalizer, input='nonnegative squared screen length Q12',
                                        normalized_table_formula='floor(sqrt((64+index)<<18)), index=0..191',
                                        basis='truncate signed32(dx<<24)/root; truncate signed32(-dy<<24)/root'),
                controller=dict(segments=12, launch_updates=10, arc_height=60, held_x_step=-4,
                                stages=dict(initialize=0, extend=1, hold=2, hide=99, destroy=100),
                                leaf_samples_even=[10, 8, 6], leaf_samples_odd=[9, 7, 5],
                                leaf_depth='front ordering-table bucket',
                                start='executing actor current position', target='selected recipient home position',
                                segment_quad=[[0, 0], [16, 0], [0, 8], [16, 8]],
                                quantize_world_before_projection=True),
                scope='Shared effect clock, curve and source art. Native scene composition, encounter admission, '
                      'camera/material/audio review and campaign placement remain separate.')


def export_art(output, report):
    output = Path(output).resolve()
    if ROOT / 'kit/work/accepted' in (output, *output.parents):
        raise ValueError('Ivy candidate art must not write accepted staging')
    for actor in report['actors']:
        raw, origin = source('/' + actor['source']['file'].split('/')[-1])
        if origin != actor['source']:
            raise ValueError('Ivy art source changed')
        poses, _, _ = section_art(raw, actor['section_offset'], 0x80080000,
                                 animation_indices=[0, 10, 11, 12], selected_poses_only=True)
        for art in actor['art']:
            target = output / art['path']
            target.parent.mkdir(parents=True, exist_ok=True)
            poses[art['pose']][0].save(target)
    output.mkdir(parents=True, exist_ok=True)
    (output / 'ivy.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--art-out', type=Path)
    args = parser.parse_args()
    report = build()
    encoded = json.dumps(report, indent=2) + '\n'
    if args.check:
        if REPORT.read_text() != encoded:
            raise SystemExit('Ivy source report is stale')
    else:
        REPORT.write_text(encoded)
    if args.art_out:
        export_art(args.art_out, report)
    print('Checked Ivy source report' if args.check else 'Wrote Ivy source report')

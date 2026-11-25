#!/usr/bin/env python3
"""Static IC descriptors and duel script schedules; no emulator or runtime inputs."""
import argparse
import hashlib
import json
from pathlib import Path
import struct

import ikki_clut_trace as cluts
import ikki_palettes as source
from war_text import decode as decode_text

POSE_SIZE = (112, 96)
OP_LENGTHS = (1, 1, 9, 2, 2, 1, 2, 1, 1, 2, 4, 1, 4, 2, 2)
OP_NAMES = ('hold', 'wait_motion', 'motion', 'select_action', 'wait_ticks',
            'wait_animation', 'signal', 'flash', 'normal_palette', 'wait_signal',
            'attachment_offset', 'hide', 'spawn_effect', 'sound', 'combat_flags')


def word(data, offset):
    if not 0 <= offset <= len(data) - 4:
        raise ValueError(f'word outside overlay: {offset:#x}')
    return struct.unpack_from('<I', data, offset)[0]


def pointer(data, offset):
    target = word(data, offset) - source.OVERLAY_BASE
    if not 0 <= target < len(data):
        raise ValueError(f'pointer outside overlay: {target:#x}')
    return target


def materialized(data, offset):
    """The observed lui/addiu idiom, including signed low halfword."""
    hi, lo = word(data, offset), word(data, offset + 4)
    assert hi >> 26 == 15 and lo >> 26 == 9
    assert (hi >> 16) & 31 == (lo >> 21) & 31 == (lo >> 16) & 31
    low = (lo & 65535) - (65536 if lo & 32768 else 0)
    return ((hi & 65535) << 16) + low - source.OVERLAY_BASE


def read_script(data, offset):
    commands = []
    for _ in range(256):
        if not 0 <= offset <= len(data) - 2:
            raise ValueError('script outside overlay')
        op = struct.unpack_from('<H', data, offset)[0]
        if op >= len(OP_LENGTHS):
            raise ValueError(f'unknown script opcode {op} at {offset:#x}')
        args = list(struct.unpack_from('<' + 'h' * OP_LENGTHS[op], data, offset))[1:]
        commands.append({'offset': offset, 'op': op, 'name': OP_NAMES[op], 'args': args})
        offset += 2 * OP_LENGTHS[op]
        if op == 0:
            return commands
    raise ValueError('unterminated script')


def extract():
    overlays = []
    clut_records = cluts.trace()
    for name in source.OVERLAYS:
        data = source.overlay(name)
        families = []
        for r in (r for r in clut_records if r['overlay'].endswith('/' + name)):
            ctx = int(r['context_offset'], 16)
            ne, nf = struct.unpack_from('<HH', data, ctx)
            etab, ftab = pointer(data, ctx + 16), pointer(data, ctx + 20)
            poses, animations = [], []
            for i in range(ne):
                off = pointer(data, etab + 4 * i)
                header = list(data[off:off + 8])
                pieces = []
                for k in range(header[0]):
                    p = list(data[off + 8 + 8 * k:off + 16 + 8 * k])
                    if len(p) != 8 or p[2] >= data[ctx + 4]:
                        raise ValueError('invalid draw piece')
                    u, v, w, h = (p[3] & 15) * 8, (p[3] >> 4) * 8, p[4] + 1, p[5] + 1
                    if u + w > 128 or v + h > 128 or p[7] & ~2:
                        raise ValueError('draw piece outside supported IC plane')
                    pieces.append({'offset_xy': p[:2], 'page': p[2], 'uv': [u, v],
                                   'size': [w, h], 'palette_delta': p[6],
                                   'flip_x': bool(p[7] & 2), 'raw': p})
                poses.append({'id': i, 'offset': off, 'header': header,
                              'anchor': header[4:6], 'pieces': pieces})
            for i in range(nf):
                off = pointer(data, ftab + 4 * i)
                count, flags, extra, reserved = data[off:off + 4]
                steps = [list(data[off + 4 + 2 * k:off + 6 + 2 * k]) for k in range(count)]
                if any(e >= ne or duration == 0 for e, duration in steps):
                    raise ValueError('invalid animation step')
                animations.append({'id': i, 'offset': off, 'count': count,
                                   'flags': flags, 'active': bool(flags & 1),
                                   'loop': bool(flags & 2), 'extra': extra,
                                   'reserved': reserved, 'steps': steps,
                                   'total_ticks': sum(d for _, d in steps)})
            families.append({'family': r['family'], 'context_offset': ctx,
                             'pose_table_offset': etab, 'animation_table_offset': ftab,
                             'palette': {k: v for k, v in r.items() if not k.startswith('_')},
                             'poses': poses, 'animations': animations})
        dtab = materialized(data, 0x37E8)
        directions = [list(data[pointer(data, dtab + 4 * i):pointer(data, dtab + 4 * i) + 8])
                      for i in range(10)]
        script_tables = [materialized(data, p) for p in (0x7A20, 0x7A50)]
        menu_table = materialized(data, 0x76C0)
        choice_names = [decode_text(data, pointer(data, menu_table + 4 * i))[0] for i in range(3)]
        matrix = materialized(data, 0x7948)
        outcomes = [word(data, matrix + 4 * i) for i in range(9)]
        assert outcomes == list(range(1, 10))
        rounds = []
        for outcome in range(1, 10):
            scripts = [read_script(data, pointer(data, table + outcome * 4)) for table in script_tables]
            rounds.append({'outcome_id': outcome, 'player_choice': choice_names[(outcome - 1) // 3],
                           'opponent_choice': choice_names[(outcome - 1) % 3], 'scripts': scripts})
        idle = read_script(data, materialized(data, 0x1B84))
        death = read_script(data, materialized(data, 0x7C24))
        overlays.append({'overlay': source.OVERLAY_DIR + name,
                         'lba': source._rec(source.OVERLAY_DIR + name)['lba'],
                         'size': len(data), 'sha256': hashlib.sha256(data).hexdigest(),
                         'families': families, 'choice_names': choice_names, 'choice_matrix_offset': matrix,
                         'direction_table_offset': dtab,
                         'directions': directions, 'script_tables': script_tables,
                         'idle_script': idle, 'death_script': death, 'rounds': rounds})
    return {'format': 'IC animation metadata v1', 'tick_unit': 'one duel update call',
            'preview_hz': 60, 'overlays': overlays}


def select(state, animation):
    if not animation['steps']:
        raise ValueError('empty descriptor is not reachable through the action map')
    state.update(animation=animation, frame=0, timer=animation['steps'][0][1]
                 if animation['steps'] else 0, active=animation['active'], pose=None)
    if animation['steps']:
        state['pose'] = animation['steps'][0][0]


def tick_animation(state):
    """0x800862F8: byte decrement, stop on last frame, or loop."""
    if not state['active']:
        return
    state['timer'] = (state['timer'] - 1) & 255
    if state['timer']:
        return
    animation = state['animation']
    if state['frame'] + 1 < animation['count']:
        state['frame'] += 1
    elif animation['loop']:
        state['frame'] = 0
    else:
        state['active'] = False
    # The engine rebuilds/reloads even after disabling playback.
    if animation['steps']:
        state['pose'], state['timer'] = animation['steps'][state['frame']]


def schedule(overlay, outcome, direction=2, limit=1000):
    """Evaluate only the temporal command semantics, with the camera direction fixed.

    This is a static scheduling model, not machine execution. Motion duration is
    evaluated; world positions, camera changes, child art, audio and combat damage
    are excluded. The trace explicitly includes signal and flash events.
    """
    scripts = overlay['rounds'][outcome - 1]['scripts']
    actors, events, runs, signals = [], [], [], set()
    for family in overlay['families']:
        state = {'pc': 0, 'poll': False, 'wait': 0, 'motion': 0, 'action': 0,
                 'flash': False, 'visible': True}
        select(state, family['animations'][overlay['directions'][0][direction]])
        actors.append(state)

    def advance(actor, tick):
        state, script = actors[actor], scripts[actor]
        for _ in range(256):
            cmd = script[state['pc']]
            op, args = cmd['op'], cmd['args']
            blocked = False
            if op == 0:
                return
            if op == 1:
                blocked = state['motion'] > 0
            elif op == 2:
                state['motion'] = args[1]
            elif op == 3:
                state['action'] = args[0]
                animation = overlay['families'][actor]['animations'][overlay['directions'][args[0]][direction]]
                select(state, animation)
            elif op == 4:
                if not state['poll']:
                    state['wait'] = args[0]
                    blocked = True
                else:
                    state['wait'] -= 1
                    blocked = state['wait'] > 0
            elif op == 5:
                blocked = state['active']
            elif op == 6:
                blocked = not state['poll']
                if not blocked:
                    signals.add(args[0])
            elif op == 7:
                state['flash'] = True
            elif op == 8:
                state['flash'] = False
            elif op == 9:
                blocked = args[0] not in signals
            elif op == 11:
                state['visible'] = False
                blocked = not state['poll']
            elif op not in (10, 12, 13, 14):
                raise ValueError('unsupported temporal opcode')
            if blocked:
                state['poll'] = True
                return
            events.append({'tick': tick, 'actor': actor, **cmd})
            state['pc'] += 1
            state['poll'] = False
        raise ValueError('script did not yield')

    # 0x80086660 starts each script synchronously, actor 0 before actor 1.
    for actor in range(2):
        advance(actor, -1)
    for tick in range(limit):
        # 0x80081FAC executes all scripts before 0x800820A0 updates sprites.
        for actor in range(2):
            advance(actor, tick)
            if actors[actor]['motion'] > 0:
                actors[actor]['motion'] -= 1
        for state in actors:
            tick_animation(state)
        sample = [{'action': st['action'], 'pose': st['pose'],
                   'flash': st['flash'], 'visible': st['visible']} for st in actors]
        if runs and runs[-1]['actors'] == sample:
            runs[-1]['ticks'] += 1
        else:
            runs.append({'start_tick': tick, 'ticks': 1, 'actors': sample})
        if all(scripts[a][st['pc']]['op'] == 0 and not st['active'] and not st['motion']
               for a, st in enumerate(actors)):
            return {'direction': direction, 'render_runs': runs, 'events': events,
                    'updates_to_quiescence': tick + 1}
    raise ValueError('round did not reach a holding pose')


def export(out):
    report = extract()
    for overlay in report['overlays']:
        for outcome in overlay['rounds']:
            outcome['schedule'] = schedule(overlay, outcome['outcome_id'])
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, indent=2) + '\n')
    return report


def pose_image(pages, family, pose_id):
    from PIL import Image

    image = Image.new('RGBA', POSE_SIZE)
    if pose_id is None:
        return image
    pose = family['poses'][pose_id]
    for piece in pose['pieces']:
        page = pages[f"IC_{family['family']}_{piece['page']}.BIN"]
        u, v = piece['uv']
        w, h = piece['size']
        tile = page.crop((u, v, u + w, v + h))
        if piece['flip_x']:
            tile = tile.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
        x, y = piece['offset_xy']
        image.alpha_composite(tile, (56 + x - pose['anchor'][0], 72 + y - pose['anchor'][1]))
    return image


def previews(report, out):
    from PIL import Image, ImageDraw

    pages, _ = cluts.normal_page_images()
    out.mkdir(parents=True, exist_ok=True)
    families = {f['family']: f for ov in report['overlays'] for f in ov['families']}

    # All source rectangles, reconstructed at their descriptor anchors.
    sheet = Image.new('RGB', (8 * 224, 7 * 212 * 4), (36, 36, 36))
    draw = ImageDraw.Draw(sheet)
    for family_index, family in enumerate(('KWA', 'PAN', 'SHU', 'TEO')):
        for pose in families[family]['poses']:
            x, y = (pose['id'] % 8) * 224, (family_index * 7 + pose['id'] // 8) * 212
            tile = pose_image(pages, families[family], pose['id']).resize((224, 192), Image.Resampling.NEAREST)
            sheet.paste(tile, (x, y + 20), tile)
            draw.text((x + 6, y + 3), f"{family} E{pose['id']} ({len(pose['pieces'])} pieces)", fill='white')
    sheet.save(out / 'descriptor_poses_candidate.png')

    def save_runs(states, durations, filename, label):
        frames = []
        for state in states:
            image = Image.new('RGB', (224 * len(state), 212), (36, 36, 36))
            draw = ImageDraw.Draw(image)
            for k, (family, pose_id) in enumerate(state):
                tile = pose_image(pages, families[family], pose_id).resize((224, 192), Image.Resampling.NEAREST)
                image.paste(tile, (k * 224, 20), tile)
            draw.text((5, 3), label, fill='white')
            frames.append(image)
        frames[0].save(out / filename, save_all=True, append_images=frames[1:],
                       duration=durations, loop=0, disposal=2)

    for ov in report['overlays']:
        for family_record in ov['families']:
            family = family_record['family']
            sequence = family_record['animations'][48]['steps']
            delays = [max(10, round(d * 100 / 60) * 10) for _, d in sequence]
            # ponytail: GIF has 10 ms resolution; metadata retains exact ticks.
            delays[-1] = 1000  # presentation pause on the indefinitely held terminal pose
            overlay_name = Path(ov['overlay']).stem
            save_runs([[(family, e)] for e, _ in sequence], delays,
                      f'{overlay_name}_{family}_death_candidate.gif',
                      f'{overlay_name}/{family} F48 — preview repeats')
    sequence = families['SHU']['animations'][32]['steps']
    save_runs([[('SHU', e)] for e, _ in sequence] * 4,
              [max(10, round(d * 100 / 60) * 10) for _, d in sequence] * 4,
              'SHU_strike_loop_candidate.gif', 'SHU F32 — 2 ticks per pose; GIF timing rounded')
    for ov in report['overlays']:
        timing = ov['rounds'][1]['schedule']  # Attack against Defend
        states, delays = [], []
        for run in timing['render_runs']:
            states.append([(family['family'], actor['pose'])
                           for family, actor in zip(ov['families'], run['actors'])])
            first, end = run['start_tick'], run['start_tick'] + run['ticks']
            delays.append(round(end * 100 / 60) * 10 - round(first * 100 / 60) * 10)
        save_runs(states, delays, Path(ov['overlay']).stem + '_attack_defend_candidate.gif',
                  'Attack vs Defend — in place; 60 Hz preview; normal colours only')
    (out / 'README.md').write_text(
        'Disc-derived descriptor preview candidates; user image gate pending.\n'
        'Normal colours were already accepted. These previews add geometry/sequence composition.\n'
        'Death F48 is a descriptor-order preview including the initial built pose, not a full engine-frame capture.\n'
        'It is a one-shot; GIF repeats for viewing and adds a 1-second terminal hold.\n'
        'SHU F32 is a genuine 4-update loop. GIF rounds delays to 10 ms; JSON preserves ticks.\n'
        'Camera projection, movement, drop shadows, effect palette/blending and audio are omitted.\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, default=Path(__file__).resolve().parents[1] / 'work' / 'ikki_animations.json')
    parser.add_argument('--previews', type=Path)
    args = parser.parse_args()
    result = export(args.out)
    if args.previews:
        previews(result, args.previews)
    for ov in result['overlays']:
        print(ov['overlay'], [(f['family'], len(f['poses']), len(f['animations'])) for f in ov['families']],
              [r['schedule']['updates_to_quiescence'] for r in ov['rounds']])

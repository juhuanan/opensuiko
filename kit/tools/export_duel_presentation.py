#!/usr/bin/env python3
"""Pack the existing Python-decoded IC sprites and gauges for the journey duel view."""
import argparse
import hashlib
import json
from pathlib import Path

from PIL import Image

from export_duels import COMMANDS, DUEL_IDS, ROOT
from ikki_animations import POSE_SIZE, extract, pose_image, schedule
from ikki_clut_trace import normal_page_images
from ikki_sky_bt_clut import embedded_images, gauge_band_rows

CELLS_PER_ROW = 16
STAGE_X = (222, 394)
STAGE_Y = 50
DIRECTION = 2


def pack_poses(overlays, gauge_page):
    families = {family['family']: family for overlay in overlays for family in overlay['families']}
    pages, _ = normal_page_images()
    width, height = POSE_SIZE
    pose_count = sum(len(family['poses']) for family in families.values())
    rows = (pose_count + CELLS_PER_ROW) // CELLS_PER_ROW
    gauge_y = rows * height
    atlas = Image.new('RGBA', (CELLS_PER_ROW * width, gauge_y + gauge_page.height))
    atlas.paste(gauge_page, (0, gauge_y))
    cells = {None: dict(x=0, y=0, w=width, h=height)}
    for name, family in sorted(families.items()):
        for pose in family['poses']:
            index = len(cells)
            x, y = index % CELLS_PER_ROW * width, index // CELLS_PER_ROW * height
            atlas.paste(pose_image(pages, family, pose['id']), (x, y))
            cells[name, pose['id']] = dict(x=x, y=y, w=width, h=height)
    return atlas, cells, gauge_y


def frame(cells, family, pose, side, ticks, *, flash=False, visible=True):
    rect = cells[family, pose] if pose is not None else cells[None]
    return dict(rect=rect, ticks=ticks, x=STAGE_X[side] - rect['w'] // 2, y=STAGE_Y,
                mirror=bool(side), flash=flash, visible=visible)


def exchange_clips(overlay, match, cells):
    outcome = 1 + 3 * COMMANDS.index(match['player']) + COMMANDS.index(match['opponent'])
    trace = schedule(overlay, outcome, direction=DIRECTION)
    if trace['updates_to_quiescence'] != match['updates']:
        raise ValueError(f"duel clock changed for {match['id']}")
    clips = [[], []]
    for run in trace['render_runs']:
        for side, (actor, sample) in enumerate(zip(overlay['families'], run['actors'], strict=True)):
            clips[side].append(frame(cells, actor['family'], sample['pose'], side, run['ticks'],
                                     flash=sample['flash'], visible=sample['visible']))
    return clips


def export(output):
    output = output.resolve()
    accepted = (ROOT / 'kit/work/accepted').resolve()
    if output == accepted or accepted in output.parents:
        raise ValueError('duel presentation is a candidate')
    rules = json.loads((ROOT / 'game/assets/duels.json').read_bytes())
    matches = {match['id']: match for match in rules['duels']}
    overlays = extract()['overlays']
    sources = [Path(overlay['overlay']).name for overlay in overlays]
    pages = [embedded_images(name)[2][0] for name in sources]
    gauge_page = pages[0]
    if any(page.tobytes() != gauge_page.tobytes() for page in pages[1:]):
        raise ValueError('duel overlays disagree on the shared gauge pixels')
    atlas, cells, gauge_y = pack_poses(overlays, gauge_page)
    scenes = []
    for overlay, overlay_name in zip(overlays, sources, strict=True):
        identity = DUEL_IDS[overlay_name]
        idle, defeat = [], []
        for side, actor in enumerate(overlay['families']):
            name = actor['family']
            idle_id = overlay['directions'][0][DIRECTION]
            idle.append([frame(cells, name, pose, side, ticks)
                         for pose, ticks in actor['animations'][idle_id]['steps']])
            defeat.append([frame(cells, name, pose, side, ticks)
                           for pose, ticks in actor['animations'][48]['steps']])
        exchanges = [dict(id=match['id'], clips=exchange_clips(overlay, match, cells))
                     for match in matches[identity]['exchanges']]
        gauges = [dict(x=0, y=gauge_y + row, w=128, h=32) for row in gauge_band_rows(overlay_name)]
        scenes.append(dict(id=identity, idle=idle, defeat=defeat, exchanges=exchanges, gauges=gauges))
    output.mkdir(parents=True, exist_ok=True)
    atlas.save(output / 'atlas.png')
    digest = hashlib.sha256((output / 'atlas.png').read_bytes()).hexdigest()
    packet = dict(schema='suikoden-duel-presentation/1', atlas_sha256=digest, scenes=scenes,
                  art_origin='disc-extracted-duel-art/1')
    (output / 'presentation.json').write_text(json.dumps(packet, separators=(',', ':')) + '\n')
    return packet


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    packet = export(args.output)
    print(f"Packed {len(packet['scenes'])} disc-extracted IC duel scenes in {args.output}")

#!/usr/bin/env python3
"""Diagnostic strips only; phase selection and truncation are not choreography."""
import json
import sys
from pathlib import Path

from PIL import Image

import battle_bin
from spell_effect_entries import entry_image

ROOT = Path(__file__).resolve().parents[2]
SWEEP = ROOT / 'kit/data/reports/spell_effect_sweep.json'
OUT = ROOT / 'kit/work/build/battle_review/effects'


def main():
    sections, atlases, errors, data = battle_bin.parse()
    if errors:
        raise SystemExit(errors)
    blobs = {a['offset']: a['atlas'] for a in atlases}
    sweep = json.loads(SWEEP.read_text())
    blob_offset = sweep['effects'][0]['palette_source']['blob_offset']
    atlas = blobs[blob_offset]
    OUT.mkdir(parents=True, exist_ok=True)
    manifest = []
    for index, effect in enumerate(sweep['effects']):

        pieces = {p['id']: p for p in effect['pieces']}

        def piece_image(pid):
            piece = pieces[pid]
            ax, ay = piece['header'][4], piece['header'][5]
            out = Image.new('RGBA', (128, 128), (0, 0, 0, 0))
            for entry in piece['entries']:
                image = entry_image(blobs[sections[effect['section']]['atlas_offsets'][entry[2]]], atlas, entry)
                out.alpha_composite(image, (64 + entry[0] - ax, 64 + entry[1] - ay))
            return out

        def strip(animation):
            frames = []
            for frame in animation['frames']:
                frames += [piece_image(frame['piece'])] * min(frame['ticks'], 30)
            frames = frames[:40]
            out = Image.new('RGBA', (128 * len(frames), 128), (0, 0, 0, 0))
            for frame_index, image in enumerate(frames):
                out.alpha_composite(image, (128 * frame_index, 0))
            return out, len(frames)

        phases = effect['phase_animations']
        cast_anim = effect['animations'][phases[0] if phases else 0]
        burst_anim = effect['animations'][phases[len(phases) // 2] if phases else max(len(effect['animations']) // 2, 1)]
        impact_anim = effect['animations'][phases[-1] if phases else len(effect['animations']) - 1]
        cast, cast_frames = strip(cast_anim)
        burst, burst_frames = strip(burst_anim)
        impact, impact_frames = strip(impact_anim)
        cast.save(OUT / f'{index}_cast.png')
        burst.save(OUT / f'{index}_burst.png')
        impact.save(OUT / f'{index}_impact.png')
        manifest.append(dict(index=index, name=effect['name'], cast_frames=cast_frames,
                             burst_frames=burst_frames, impact_frames=impact_frames,
                             burst_animation=burst_anim['id']))
    (OUT / 'effects.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'{len(manifest)} spell effect strips')


if __name__ == '__main__':
    main()

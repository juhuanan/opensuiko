"""Compare exported room draws against the independent source scene compositor."""
import argparse
import hashlib
import json
from pathlib import Path

from PIL import Image

import area_scene
from export_first_room import frame_table, source


def frame_at(durations, elapsed):
    if not durations or any(type(duration) is not int or duration <= 0 for duration in durations):
        raise ValueError('invalid scenery animation durations')
    tick = elapsed % sum(durations)
    for index, duration in enumerate(durations):
        if tick < duration:
            return index
        tick -= duration
    raise ValueError('empty scenery animation')


def verify(package_dir, room_sources):
    package = json.loads((package_dir / 'room.json').read_bytes())
    rooms = {room['id']: room for room in package['rooms']}
    sources, results = {}, []
    for identifier, provenance in room_sources.items():
        proof = provenance['source']
        filename = proof['file']
        if filename not in sources:
            sources[filename] = source(filename)
        data, origin = sources[filename]
        if any(origin[key] != proof[key] for key in ('lba', 'size', 'sha256')):
            raise ValueError(f'{identifier}: source identity differs')
        room = rooms[identifier]
        record = area_scene.room_record(data, provenance['room'])
        section = area_scene.section_off(data, record['section'])
        vram, _ = area_scene.load_scene_materials(data, section, origin)
        durations = frame_table(data, section)
        primitives, _ = area_scene.scenery_primitives(data, section, vram, source_meta=origin)
        static_frames = {primitive['type']: 0 for primitive in primitives}
        # Sample every animation boundary, including vertices absent at frame0.
        times = {0}
        for ticks in durations.values():
            elapsed = 0
            for duration in ticks:
                times.add(elapsed)
                elapsed += duration
        atlas = Image.open(package_dir / room['scenery_atlas']).convert('RGBA')
        for elapsed in sorted(times):
            frames = static_frames | {kind: frame_at(ticks, elapsed) for kind, ticks in durations.items()}
            expected, _, _ = area_scene.scene_compose(data, provenance['room'], vram, npcs=False, frames_by_type=frames)
            actual = Image.new('RGBA', expected.size, (0, 0, 0, 255))
            for draw in sorted(room['draws'], key=lambda draw: draw['depth']):
                if draw.get('hidden_by') or draw.get('room_conditions') or draw.get('prop') is not None:
                    raise ValueError(f'{identifier}: conditional scenery requires a state witness')
                if draw.get('frames'):
                    draw = draw['frames'][frame_at([frame['ticks'] for frame in draw['frames']], elapsed)]
                rect = draw['rect']
                image = atlas.crop((rect['x'], rect['y'], rect['x'] + rect['w'], rect['y'] + rect['h']))
                actual.alpha_composite(image, (draw['x'], draw['y']))
            if actual.tobytes() != expected.tobytes():
                raise ValueError(f'{identifier}: scenery differs at tick{elapsed}')
        results.append({'room': identifier, 'samples': len(times), 'source': origin,
                        'scenery_sha256': hashlib.sha256((package_dir / room['scenery_atlas']).read_bytes()).hexdigest()})
    return {'schema': 'suikoden-field-scenery-verification/1', 'rooms': results,
            'scope': 'source scenery, depth and animation boundaries; excludes actors, gameplay state and human media acceptance'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('package', type=Path)
    parser.add_argument('sources', type=Path, help='manifest with room_sources provenance')
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    result = verify(args.package, json.loads(args.sources.read_bytes())['room_sources'])
    if args.report:
        args.report.write_text(json.dumps(result, indent=2) + '\n')
    print(f"Verified {len(result['rooms'])} rooms, {sum(row['samples'] for row in result['rooms'])} source scenery samples")


if __name__ == '__main__':
    main()

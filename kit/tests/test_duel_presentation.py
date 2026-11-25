#!/usr/bin/env python3
"""Verify the generated duel candidate and its paired display clocks."""
import json
from pathlib import Path
import sys
from tempfile import TemporaryDirectory

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
from check_journey_package import check_duel_presentation, rect_ok
from export_duel_presentation import export
from ikki_animations import extract, pose_image, schedule
from ikki_clut_trace import normal_page_images
from ikki_sky_bt_clut import embedded_images


def test_candidate():
    with TemporaryDirectory() as temp:
        root = Path(temp)
        output = root / 'duel'
        second = root / 'repeat'
        packet = export(output)
        assert export(second) == packet
        assert (output / 'atlas.png').read_bytes() == (second / 'atlas.png').read_bytes()
        assert (output / 'presentation.json').read_bytes() == (second / 'presentation.json').read_bytes()
        errors = []
        check_duel_presentation(root, errors)
        assert not errors, errors
        atlas = Image.open(output / 'atlas.png')
        pages, _ = normal_page_images()
        match_rules = json.loads((ROOT / 'game/assets/duels.json').read_bytes())['duels']
        band_rows = ((64, 32), (96, 0), (96, 32))
        for scene, rules, overlay, rows in zip(packet['scenes'], match_rules, extract()['overlays'], band_rows, strict=True):
            assert scene['id'] == rules['id']
            assert 'backdrop' not in scene
            gauge_page, _ = embedded_images(Path(overlay['overlay']).name)[2]
            for gauge, row, fill_x in zip(scene['gauges'], rows, (4, 9), strict=True):
                assert rect_ok(gauge, *atlas.size)
                x, y = gauge['x'], gauge['y']
                packed = atlas.crop((x, y, x + 128, y + 32))
                assert packed.tobytes() == gauge_page.crop((0, row, 128, row + 32)).tobytes()
                assert packed.getchannel('A').crop((fill_x, 21, fill_x + 115, 27)).getextrema() == (0, 0)
            for side, fighter in enumerate(overlay['families']):
                idle = scene['idle'][side][0]
                pose = fighter['animations'][overlay['directions'][0][2]]['steps'][0][0]
                rect = idle['rect']
                x, y, w, h = (rect[key] for key in ('x', 'y', 'w', 'h'))
                sprite = atlas.crop((x, y, x + w, y + h))
                assert sprite.getchannel('A').getextrema() == (0, 255)
                assert sprite.tobytes() == pose_image(pages, fighter, pose).tobytes()
                assert sum(f['ticks'] for f in scene['defeat'][side]) == rules['fighters'][side]['defeat_updates']
            for outcome, (visual, rule) in enumerate(zip(scene['exchanges'], rules['exchanges'], strict=True), 1):
                assert visual['id'] == rule['id']
                trace = schedule(overlay, outcome)
                for side, clip in enumerate(visual['clips']):
                    frames = [frame for frame in clip for _ in range(frame['ticks'])]
                    assert len(frames) == rule['updates']
                    sampled_flags = [(frame['flash'], frame['visible']) for frame in frames]
                    traced_flags = [(run['actors'][side]['flash'], run['actors'][side]['visible'])
                                    for run in trace['render_runs'] for _ in range(run['ticks'])]
                    assert sampled_flags == traced_flags
                    for frame in clip:
                        assert frame['mirror'] == bool(side)
                        assert rect_ok(frame['rect'], *atlas.size)
                        assert rect_ok({**frame['rect'], 'x': frame['x'], 'y': frame['y']}, 616, 154)
        legacy = {key: value for key, value in packet.items() if key != 'art_origin'}
        (output / 'presentation.json').write_text(json.dumps(legacy))
        errors.clear()
        check_duel_presentation(root, errors)
        assert errors == ['duel presentation: missing or unsupported duel art origin']
        (output / 'presentation.json').write_text(json.dumps({**packet, 'art_origin': 'authored-duel-art/1'}))
        errors.clear()
        check_duel_presentation(root, errors)
        assert errors == ['duel presentation: authored preview art is excluded from runtime packages']
        errors.clear()
        packet['scenes'][0]['gauges'][0]['x'] = atlas.width
        (output / 'presentation.json').write_text(json.dumps(packet))
        check_duel_presentation(root, errors)
        assert errors == ['duel presentation: invalid gauge bands']
        errors.clear()
        (output / 'atlas.png').write_bytes(b'corrupt atlas')
        check_duel_presentation(root, errors)
        assert errors == ['duel presentation: atlas checksum mismatch']


if __name__ == '__main__':
    test_candidate()
    print('PASS: deterministic atlas, source fighter and gauge pixels, paired clocks, origin and checksum gates')

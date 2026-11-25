"""Export the VB6 village's source-order population metadata; not artwork."""
from pathlib import Path
import json

from export_scene_population import compile_room

ROOT = Path(__file__).resolve().parents[2]


def export():
    return compile_room('/VB6.BIN', 0, 'vb6_room0')


def write():
    packet, proof = export()
    for path, value in (
        (ROOT / 'game/assets/scenes/population/vb6_room0.json', packet),
        (ROOT / 'kit/data/reports/vb6_room0_population.json', proof),
    ):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value, indent=2) + '\n')


if __name__ == '__main__':
    write()

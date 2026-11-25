#!/usr/bin/env python3
"""Gate the static battle camera call-site inventory."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
REPORT = ROOT / 'kit/data/reports/battle_camera_sites.json'


def main():
    rows = json.loads(REPORT.read_text())
    assert len(rows) == 104, len(rows)
    assert len({row['block'] for row in rows}) == 50  # includes the unresolved dynamic bucket
    assert sum(row['function'].startswith('battle_') for row in rows) == 97
    assert len(rows) - 97 == 7
    by_site = {row['site']: row for row in rows}
    assert by_site['0x800FEE2C']['block'] == '0x8016D3DC'
    assert by_site['0x800FEE2C']['frames'] == 60
    assert by_site['0x800FEFF8']['frames'] == 32
    assert by_site['0x800FF9AC']['frames'] == 90
    assert by_site['0x800FC718']['frames'] == 60
    assert by_site['0x800FF9AC']['block'] == '0x8016D52C'
    assert by_site['0x800FC718']['block'] == '0x8016CC1C'
    assert by_site['0x800FEE2C']['action'] == 'Flaming Arrows'
    assert by_site['0x800FF9AC']['action'] == 'Firestorm'
    assert by_site['0x80100588']['action'] == 'Dancing Flames'
    assert by_site['0x80101524']['action'] == 'Explosion'
    assert by_site['0x80105C90']['action'] == 'Drops of Kindness'
    assert by_site['0x8011073C']['action'] == 'Clay Guardian'
    assert by_site['0x80113F6C']['action'] == 'Deadly Fingertips'
    assert not any(row['action'].startswith('unknown') for row in rows)
    assert by_site['0x80102308']['action'] == 'Final Flame'
    assert by_site['0x80108390']['action'] == 'Mother Ocean'
    assert by_site['0x801199FC'].get('inferred') is None
    print(f'ok   {len(rows)} battle camera sites, 50 blocks')


if __name__ == '__main__':
    main()

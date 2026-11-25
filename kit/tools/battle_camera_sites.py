#!/usr/bin/env python3
"""List every MAIN.EXE call site of the battle camera setter 0x800F6110.

Resolves the static camera block argument from the preceding lui/addiu pair and
the frame count from ori a1. Dynamic callers are reported as unresolved.
"""
import bisect
import csv
import json
import struct
from pathlib import Path

import maindec

ROOT = Path(__file__).resolve().parents[2]
LABELS = ROOT / 'kit/data/catalogs/function_labels.csv'
TARGET = 0x800F6110
INSTALLERS = {'battle_action_driver_branch_a': '0x800FB428'}
OWNERSHIP = ROOT / 'kit/data/reports/battle_camera_ownership.json'
INFERRED = {}
SPELL_RANGES = [
    (0x800FEAEC, 0x800FF428, 'Flaming Arrows'),
    (0x800FF428, 0x80100140, 'Firestorm'),
    (0x80100140, 0x80101130, 'Dancing Flames'),
    (0x80101130, 0x80101E88, 'Explosion'),
    (0x80101E88, 0x80102DC0, 'Final Flame'),
    (0x80102DC0, 0x80103824, 'Scolding'),
    (0x80103824, 0x80104468, 'Yell'),
    (0x80104468, 0x8010508C, 'Scream'),
    (0x8010508C, 0x801058AC, 'Charm Arrow'),
    (0x801058AC, 0x80106178, 'Drops of Kindness'),
    (0x80106178, 0x801068CC, 'Fog of Deception'),
    (0x801068CC, 0x8010726C, 'Water of Kindness'),
    (0x8010726C, 0x80107FB4, 'Rain of Kindness'),
    (0x80107FB4, 0x80108B58, 'Mother Ocean'),
    (0x80108B58, 0x801093EC, 'Wind of Sleep'),
    (0x801093EC, 0x80109D98, 'The Shredding'),
    (0x80109D98, 0x8010A67C, 'Healing Wind'),
    (0x8010A67C, 0x8010B044, 'Storm'),
    (0x8010B044, 0x8010C118, 'Shining Wind'),
    (0x8010C118, 0x8010CBD8, 'Angry Blow'),
    (0x8010CBD8, 0x8010D848, 'Rainstorm'),
    (0x8010D848, 0x8010E4CC, 'Raging Blow'),
    (0x8010E4CC, 0x8010F418, 'Ball of Lightning'),
    (0x8010F418, 0x80110438, 'Thunder God'),
    (0x80110438, 0x80110CC8, 'Clay Guardian'),
    (0x80110CC8, 0x801116D0, 'Copper Flesh'),
    (0x801116D0, 0x80112048, 'Earthquake'),
    (0x80112048, 0x80112A8C, 'Guardian of Earth'),
    (0x80112A8C, 0x80113A68, 'Voice of Earth'),
    (0x80113A68, 0x801148AC, 'Deadly Fingertips'),
    (0x801148AC, 0x80115654, 'Black Shadow'),
    (0x80115654, 0x80116638, 'Hell'),
    (0x80116638, 0x80120000, 'Judgment'),
]


def labels():
    rows = []
    with LABELS.open() as fh:
        for row in csv.reader(fh):
            if not row or not row[0].startswith('0x'):
                continue
            try:
                rows.append((int(row[0], 16), row[1], row[2] if len(row) > 2 else ''))
            except (ValueError, IndexError):
                continue
    rows.sort()
    return [r[0] for r in rows], rows


def block(pc):
    high = None
    for p, w, text in maindec.dis(pc - 48, 14):
        if 'lui $a0,0x' in text:
            high = int(text.split('lui $a0,0x', 1)[1], 16) << 16
        if 'addiu $a0,$a0,' in text and high is not None:
            value = int(text.split('addiu $a0,$a0,', 1)[1], 16)
            return (high + value) & 0xFFFFFFFF
        if 'lw $a0' in text:
            return None
    return None


def frames(pc):
    for p, w, text in maindec.dis(pc - 48, 14):
        if 'ori $a1,$zero,0x' in text:
            return int(text.split('ori $a1,$zero,0x', 1)[1], 16)
    return None


def family(values):
    if values is None:
        return 'dynamic'
    x, angle, scale = values[0], values[5], values[9]
    if x == 80 and scale == 4864:
        return 'party_close'
    if x == -80 and scale == 4864:
        return 'enemy_close'
    if x == -160 and angle == 352 and scale == 5120:
        return 'effect_close'
    if angle == 640:
        return 'wide_default'
    if scale >= 5888:
        return 'special_zoom'
    if x < 0:
        return 'enemy_wide'
    return 'other'


def action(site, function=''):
    if function == 'battle_action_driver_branch_a':
        return 'setup'
    if function.startswith(('global_', 'event_')) or 'setup' in function:
        return 'setup'
    for start, end, name in SPELL_RANGES:
        if start <= site < end:
            if not name.startswith('unknown'):
                return name
            break
    if any(tag in function for tag in ('init', 'reset', 'alloc', 'struct', 'merge', 'packet', 'flag_scan')):
        return 'setup'
    return 'state:' + function


def purpose(site, function):
    if function == 'battle_action_driver_branch_a':
        return 'participant_substruct_setup'
    if 'participant' in function:
        return 'participant_setup'
    if site < 0x800F9000:
        return 'battle_setup'
        return 'participant_substruct_setup'
    if 'participant' in function:
        return 'participant_setup'
    if any(tag in function for tag in ('setup_driver', 'state_alloc', 'dispatcher_r_setup')):
        return 'action_setup'
    return ''


def block_values(address):
    off = address - maindec.MBASE
    body = maindec.body()
    if off < 0 or off + 48 > len(body):
        return None
    return [struct.unpack_from('<i', body, off + 4 * i)[0] >> 12 for i in range(12)]


def owners():
    if not OWNERSHIP.exists():
        return {}
    result = {}
    for row in json.loads(OWNERSHIP.read_text()):
        for handler in row['handlers']:
            result[int(handler['handler'], 16)] = row['wrapper']
    return result


def driver_ranges():
    if not OWNERSHIP.exists():
        return []
    rows = []
    for row in json.loads(OWNERSHIP.read_text()):
        rows.append((int(row['driver'], 16), row['wrapper']))
    rows.sort()
    return rows


def range_owner(site, function, rows):
    if function.startswith(('global_', 'event_')) or any(tag in function for tag in ('setup', 'init', 'reset', 'alloc', 'struct', 'merge', 'packet', 'flag_scan')):
        return None
    found = None
    for index, (driver, wrapper) in enumerate(rows):
        if driver <= site and (index + 1 == len(rows) or site < rows[index + 1][0]):
            found = wrapper
    return found


def main():
    addrs, rows = labels()
    owner_by_handler = owners()
    drivers = driver_ranges()
    body = maindec.body()
    out = []
    for i in range(0, len(body) - 4, 4):
        word = struct.unpack_from('<I', body, i)[0]
        pc = maindec.MBASE + i
        if (word >> 26) == 3 and ((pc & 0xF0000000) | ((word & 0x3FFFFFF) << 2)) == TARGET:
            at = bisect.bisect_right(addrs, pc) - 1
            out.append(dict(site=f'0x{pc:08X}', function=rows[at][1],
                            function_address=f'0x{rows[at][0]:08X}',
                            role=rows[at][2], action=action(pc, rows[at][1]),
                            block=None if block(pc) is None else f'0x{block(pc):08X}',
                            frames=frames(pc),
                            values=None if block(pc) is None else block_values(block(pc)),
                            family=family(None if block(pc) is None else block_values(block(pc))),
                            inferred=INFERRED.get(rows[at][1]),
                            owner=owner_by_handler.get(rows[at][0]),
                            installer=INSTALLERS.get(rows[at][1]),
                            purpose=purpose(pc, rows[at][1]),
                            range_owner=range_owner(pc, rows[at][1], drivers)))
    print(json.dumps(out, indent=2))


if __name__ == '__main__':
    main()

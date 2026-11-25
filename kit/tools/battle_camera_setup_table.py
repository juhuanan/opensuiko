#!/usr/bin/env python3
"""Render the wrapper -> driver -> dispatcher -> camera-site setup table."""
import json
import struct
from pathlib import Path

import maindec

ROOT = Path(__file__).resolve().parents[2]
OWNERSHIP = ROOT / 'kit/data/reports/battle_camera_ownership.json'
SITES = ROOT / 'kit/data/reports/battle_camera_sites.json'
SCAN_START = 0x8016D600
SCAN_END = 0x8016EC00


def decode(data, address):
    out = []
    for c in data[address - maindec.MBASE:address - maindec.MBASE + 24]:
        if c == 0:
            break
        if c == 0x10:
            out.append(' ')
        elif 0x11 <= c <= 0x2A:
            out.append(chr(ord('a') + c - 0x11))
        elif 0x2B <= c <= 0x44:
            out.append(chr(ord('A') + c - 0x2B))
        elif 0x45 <= c <= 0x4E:
            out.append(str(c - 0x45))
    return ''.join(out)


def source_name(wrapper):
    body = maindec.body()
    needle = struct.pack('<I', wrapper)
    for off in range(SCAN_START - maindec.MBASE, SCAN_END - maindec.MBASE, 2):
        if body[off:off + 4] != needle:
            continue
        best = ''
        i = off - 1
        while i > off - 64:
            while i > off - 64 and not (body[i] == 0x10 or 0x11 <= body[i] <= 0x4E):
                i -= 1
            end = i + 1
            while i > off - 64 and (body[i] == 0x10 or 0x11 <= body[i] <= 0x4E):
                i -= 1
            candidate = decode(body, maindec.MBASE + i + 1)[:end - i - 1]
            if len(candidate) >= 2:
                best = candidate
                break
        if len(best) >= 2:
            return best
    return ''

def main():
    rows = json.loads(OWNERSHIP.read_text())
    sites = json.loads(SITES.read_text())
    by_owner = {}
    by_range = {}
    inferred = {}
    for site in sites:
        owner = site.get('owner')
        if owner:
            by_owner.setdefault(owner, []).append(site['site'])
        elif site.get('range_owner'):
            by_range.setdefault(site['range_owner'], []).append(site['site'] + '*')
        if site.get('inferred'):
            inferred.setdefault(owner, set()).add(site['inferred'])
    print('| wrapper | driver | dispatcher | action | name source | sites (range*) |')
    print('|---|---|---|---|---|---|')
    for row in rows:
        wrapper = row['wrapper']
        name = source_name(int(wrapper, 16))
        source = 'setup table' if name else 'unnamed'
        if not name:
            candidates = inferred.get(wrapper, set())
            if len(candidates) == 1:
                name = next(iter(candidates))
                source = 'inferred'
        handlers = ', '.join(handler['handler'] for handler in row['handlers']) or '-'
        sites_text = ', '.join(sorted(by_owner.get(wrapper, []) + by_range.get(wrapper, []))) or '-'
        print(f"| {wrapper} | {row['driver']} | {handlers} | {name or '-'} | {source} | {sites_text} |")
    print()
    print('## Unassigned camera sites')
    print()
    print('| site | function | label | family |')
    print('|---|---|---|---|')
    for site in sites:
        if site.get('owner') or site.get('range_owner'):
            continue
        print(f"| {site['site']} | {site['function']} | {site['action']} | {site['family']} |")


if __name__ == '__main__':
    main()

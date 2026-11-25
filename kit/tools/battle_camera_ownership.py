#!/usr/bin/env python3
"""Map battle setup wrappers to registered drivers and installed dispatchers."""
import json
import re
import struct
from pathlib import Path

import maindec

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'kit/data/reports/battle_camera_ownership.json'
SETUP = 0x801205FC


def signed(text):
    match = re.search(r'-?0x[0-9a-f]+', text)
    return int(match.group(0), 0) if match else None


def dis(pc, count):
    return list(maindec.dis(pc, count))


def wrappers():
    body = maindec.body()
    found = set()
    for off in range(0x8016D600 - maindec.MBASE, 0x8016EC00 - maindec.MBASE, 4):
        value = struct.unpack_from('<I', body, off)[0]
        if 0x800F0000 <= value < 0x80130000:
            found.add(value)
    out = []
    for pc in sorted(found):
        high = None
        driver = None
        calls = False
        for _, _, text in dis(pc, 16):
            if 'lui $a0,0x' in text:
                high = int(text.split('lui $a0,0x', 1)[1], 16) << 16
            elif 'addiu $a0,$a0,' in text and high is not None:
                driver = (high + signed(text)) & 0xFFFFFFFF
            if f'jal 0x{SETUP:08x}' in text:
                calls = True
                break
        if calls and driver:
            out.append((pc, driver))
    return out


def installs(driver):
    out = []
    values = {}
    for pc, _, text in dis(driver, 0x500 // 4):
        match = re.match(r'lui \$(\w+),0x([0-9a-f]+)', text)
        if match:
            values[match.group(1)] = int(match.group(2), 16) << 16
            continue
        match = re.match(r'addiu \$(\w+),\$(\w+),(-?0x[0-9a-f]+)', text)
        if match:
            dst, src, imm = match.group(1), match.group(2), int(match.group(3), 0)
            if src == dst and src in values:
                values[dst] = (values[src] + imm) & 0xFFFFFFFF
            continue
        match = re.match(r'sw \$(\w+),0x14\((\$\w+)\)', text)
        if match:
            reg, base = match.group(1), match.group(2)
            if base != '$sp' and reg in values:
                value = values[reg]
                if 0x800F0000 <= value < 0x80130000:
                    out.append((pc, value))
    return out


def record_fields(wrapper):
    body = maindec.body()
    needle = struct.pack('<I', wrapper)
    for off in range(0x8016D600 - maindec.MBASE, 0x8016EC00 - maindec.MBASE, 2):
        if body[off:off + 4] == needle:
            return [struct.unpack_from('<H', body, off + i)[0] for i in range(4, 0x20, 2)]
    return []


def main():
    rows = []
    for wrapper, driver in wrappers():
        rows.append(dict(wrapper=f'0x{wrapper:08X}', driver=f'0x{driver:08X}',
                         fields=[f'0x{value:04X}' for value in record_fields(wrapper)],
                         handlers=[dict(site=f'0x{pc:08X}', handler=f'0x{handler:08X}')
                                   for pc, handler in installs(driver)]))
    print(json.dumps(rows, indent=2))


if __name__ == '__main__':
    main()

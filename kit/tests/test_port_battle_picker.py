#!/usr/bin/env python3
"""Check the retained picker fixture against static branches and a row model."""
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
VECTORS = ROOT / "game/tests/fixtures/battle_picker.json"
sys.path.insert(0, str(ROOT / 'kit/tools'))
import maindec as main

COMMAND_ARMS = (0x800EAB14, 0x800EAC74, 0x800EAC8C, 0x800EACE0, 0x800EAD10)


def check_picker_source():
    start, end = 0x800EA934, 0x800EAE90
    code = main.body()[start-main.MBASE:end-main.MBASE]
    assert hashlib.sha256(code).hexdigest() == '83d38361833ee2159c71e35e739a5dc80c9c30873b815d45263128a10fdb791c'
    # Confirmation precedes cancellation. Exact repeated direction excludes up+down.
    for pc, word in {
        0x800EAA58: 0x30620041, 0x800EAA5C: 0x104000B2, 0x800EAA94: 0xA0430047,
        0x800EAAFC: 0x242111EC, 0x800EAB0C: 0x00400008,
        0x800EAC4C: 0x2442B628, 0x800EAC80: 0x2442BA48, 0x800EACC4: 0x2442C7A8,
        0x800EAD04: 0x2442BB0C, 0x800EAD1C: 0x2442D560,
        0x800EAD28: 0x30620024, 0x800EAD2C: 0x10400009, 0x800EAD38: 0x2442AE90,
        0x800EAD48: 0xAC220000, 0x800EAD60: 0x30435000,
        0x800EAD64: 0x34021000, 0x800EAD68: 0x10620005,
        0x800EAD6C: 0x34024000, 0x800EAD70: 0x1062002A,
        0x800EAD94: 0x2442FFFF, 0x800EADA0: 0x34020004,
        0x800EADC0: 0x804231AC, 0x800EADE8: 0xAC640008,
        0x800EAE04: 0x804231AC, 0x800EAE0C: 0x1040FFF1,
        0x800EAE30: 0x24420001, 0x800EAE38: 0x28420005, 0x800EAE44: 0xAC600008,
        0x800EAE60: 0x804231AC, 0x800EAE68: 0x1040FFEE,
    }.items():
        assert main.mword(pc) == word, hex(pc)
    assert tuple(main.mword(0x800C11EC + index * 4) for index in range(5)) == COMMAND_ARMS


def vectors():
    check_picker_source()
    rows = []
    for mask in range(1, 32):
        enabled = [choice for choice in range(5) if mask & (1 << choice)]
        for index, choice in enumerate(enabled):
            for flags in range(16):
                if flags & 4:
                    selected, result = choice, choice + 1
                elif flags & 8:
                    selected, result = choice, 6
                else:
                    step = int(bool(flags & 2)) - int(bool(flags & 1))
                    selected, result = enabled[(index + step) % len(enabled)], 0
                rows.append([mask, choice, flags, selected, result])
    assert len(rows) == 1280
    return rows


if __name__ == "__main__":
    expected = vectors()
    if sys.argv[1:] == ["--write"]:
        VECTORS.parent.mkdir(parents=True, exist_ok=True)
        VECTORS.write_text("[\n" + ",\n".join(json.dumps(row) for row in expected) + "\n]\n")
    else:
        assert not sys.argv[1:], "usage: test_port_battle_picker.py [--write]"
        assert json.loads(VECTORS.read_text()) == expected, "Zig conformance vectors are stale"
    print("PASS: 1280 retained Zig picker vectors agree with statically checked input and selection rules")

#!/usr/bin/env python3
"""Static cursor paths for eight retrying overlay callbacks."""
import json
from pathlib import Path
import struct
import sys

KIT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(KIT / 'tools'))
from disc import extract
import event_script_reachability as R
from mipsdec import jtarget, sx16

BASE = 0x80010000

# Source, selector, script offset, body span, outer-state branch offset, operand count.
CALLBACKS = [
    ('VB7D', 0, 0xC70C, 0x34C8, 0x3DE0, 0x34E8, 3),
    ('VAD', 7, 0x4CC24, 0x426C, 0x491C, 0x42CC, 4),
    ('VAD', 14, 0x4CD0F, 0x6434, 0x7410, 0x6470, 2),
    ('VAD', 13, 0x4CC2A, 0x7BB4, 0x8560, 0x7BDC, 3),
    ('VAD', 15, 0x4CE0E, 0x9290, 0xAC90, 0x92D0, 2),
    ('VAD', 28, 0x4CD39, 0xAC90, 0xC784, 0xACD8, 3),
    ('VAD', 1, 0x4CCE9, 0xC818, 0xCF34, 0xC87C, 5),
    ('VAD', 2, 0x4CDE3, 0xCF34, 0xE5A0, 0xCF90, 8),
]

# Cursor update instructions. Some are in jump delay slots and use a shared store.
UPDATES = {
    0x34C8: ('35a8 35ec 3630 3d80 3da4 3dc8',
             '3844 3868 388c 38b0 38d4 3d20 3d44'),
    0x426C: ('4390 43cc 4458 4480 451c 4540 4564 45c0 4680',
             '4834 4858 487c 48a0 48c4 48e8'),
    0x6434: ('655c 65a0 69f4 6a18 738c 73b0', '7304 7328 734c 7370'),
    0x7BB4: ('7d14 7d70 7e00 7f54 7f78 7f9c 84f8 851c 8540',
             '7e8c 7eb0 7ed4 7ef8 7f1c 842c 8450 8474 8498 84bc'),
    0x9290: ('9530 9574 95b8 9dec 9e10 9e34 ab9c abc0 ac10 ac34 ac58',
             '9cfc 9d20 9d58 9d7c 9da0 aac4 aae8 ab20 ab44 ab68'),
    0xAC90: ('ad8c add0 ae14 c714 c738 c75c', 'af04 af28 af4c af70 af94 c6b4 c6d8'),
    0xC818: ('c948 c984 ca10 ca38 ca7c cadc cb00 cb24 cb94 cbb8 cc44 cc6c',
             'ce24 ce48 ce6c ce90 ceb4 ced8 cefc'),
    0xCF34: ('d074 d0c0 e450 e474 e498 e4bc e4e0 e504 e528 e54c',
             'd5d4 d5f8 d61c d640 d664 d688 d6ac d6d0 e410 e434'),
}
TABLES = {
    0x3920: (0xC4, (0x3928, 0x39C4, 0x3AB0, 0x3AF0, 0x3BA8, 0x3C4C)),
    0x6A54: (0xF4, (0x6D48, 0x6E44, 0x6A5C, 0x6AA4, 0x6BBC, 0x7154)),
    0x9EFC: (0x10C, (0x9F04, 0xA0A0, 0xA11C, 0xA5C4, 0xA6AC, 0xA7B0)),
    0xAFC8: (0x124, (0xAFD0, 0xC4C4, 0xC5DC, 0xC474, 0xB240, 0xB570, 0xBB70, 0xBFF0)),
    0xD714: (0x17C, (0xD71C, 0xDBD0, 0xDD8C, 0xDFB8, 0xE254)),
}
PHASE_JUMPS = {0x34C8: 0x3920, 0x6434: 0x6A54, 0x9290: 0x9EFC, 0xAC90: 0xAFC8, 0xCF34: 0xD714}


def word(data, offset):
    return struct.unpack_from('<I', data, offset)[0]


def branch(data, pc, mask):
    instruction = word(data, pc)
    assert instruction >> 16 == mask, hex(pc)
    return pc + 4 + 4 * sx16(instruction)


def jump(data, pc):
    instruction = word(data, pc)
    assert instruction >> 26 == 2, hex(pc)
    return jtarget(BASE + pc, instruction) - BASE


def dispatch(data, pc):
    if pc in (0x42CC, 0xC87C):
        assert word(data, pc - 8) in (0x90420000, 0x90620000)
        return pc + 8, branch(data, pc, 0x1440)
    state = 6 if pc == 0x7BDC else 3
    selector_load = word(data, pc - 8)
    assert selector_load & 0xFC1FFFFF == (0x90000000 | (state << 16))
    assert word(data, pc - 4) == 0x34020001
    active = branch(data, pc, 0x1002 | (state << 5))
    assert word(data, pc + 8) == (0x28420002 | (state << 21))
    large = branch(data, pc + 12, 0x1040)
    begin = branch(data, pc + 20, 0x1000 | (state << 5))
    invalid = jump(data, pc + 28)
    assert word(data, large) == 0x34020002
    cleanup = branch(data, large + 4, 0x1002 | (state << 5))
    assert jump(data, large + 12) == invalid
    return begin, active, cleanup, invalid


def cursor_updates(data, start, end):
    updates = {}
    for pc in range(start, end, 4):
        instruction = word(data, pc)
        if instruction not in (0x24420001, 0x2442FFFF):
            continue
        after = word(data, pc + 4)
        before = word(data, pc - 4)
        if before >> 26 == 2:
            after = word(data, jump(data, pc - 4))
        elif after >> 26 == 2:
            after = word(data, pc + 8)
        if after not in (0xAC620000, 0xACA20000):
            continue
        cell = (after >> 21) & 31
        load = 0x8C020000 | (cell << 21)
        load_pc = next((off for off in range(pc - 4, pc - 20, -4) if word(data, off) == load), None)
        assert load_pc is not None, hex(pc)
        assert any(word(data, off) & 0xFC1FFFFF == (0x8C000004 | (cell << 16))
                   for off in range(load_pc - 4, load_pc - 32, -4)), hex(pc)
        updates[pc] = sx16(instruction)
    increments, decrements = UPDATES[start]
    expected = {int(pc, 16): delta
                for group, delta in ((increments, 1), (decrements, -1))
                for pc in group.split()}
    assert updates == expected, hex(start)
    return updates


def exits(data, start, end, entry, updates, choices):
    """Walk static branches with cursor deltas as edge weights. Calls return to their fallthrough."""
    pending = [(entry, 0)]
    seen, results = set(), set()
    while pending:
        pc, delta = pending.pop()
        if (pc, delta) in seen:
            continue
        assert start <= pc < end and -16 <= delta <= 16, (hex(entry), hex(pc), delta)
        seen.add((pc, delta))
        delta += updates.get(pc, 0)
        instruction = word(data, pc)
        op = instruction >> 26
        special = instruction & 63
        transfer = op in range(1, 8) or (op == 0 and special in (8, 9))
        if transfer:
            delta += updates.get(pc + 4, 0)
        if instruction == 0x03E00008:
            results.add(delta)
            continue
        if instruction == 0x00400008:
            table, expected = TABLES[pc]
            assert struct.unpack_from('<5I', data, pc - 20) == (
                0x3C018001, 0x24210000 | table, 0x00220821, 0x8C220000, 0)
            targets = tuple(word(data, table + 4*i) - BASE for i in range(len(expected)))
            assert targets == expected, hex(pc)
        elif op == 2:
            targets = (jump(data, pc),)
        elif op == 3 or (op == 0 and special == 9):
            targets = (pc + 8,)
        elif op in (1, 4, 5, 6, 7):
            assert op != 1 or (instruction >> 16) & 31 in (0, 1), hex(pc)
            targets = (pc + 4 + 4 * sx16(instruction), pc + 8)
        else:
            assert not transfer, hex(pc)
            targets = (pc + 4,)
        if pc in choices:
            targets = (targets[choices[pc]],)
        pending.extend((target, delta) for target in targets)
    return results


def check_special_branches(data):
    # The optional FF byte and the corresponding saved flag are read in four tails.
    for pc, opcode in {
        0x9500: 0xA0208E8C, 0x9510: 0x340200FF, 0x9514: 0x14620008, 0x9524: 0xA0258E8C,
        0x9D2C: 0x90638E8C, 0x9D30: 0x34020001, 0x9D34: 0x1462000A,
        0x9DCC: 0x90428E8C, 0x9DD4: 0x14430007,
        0xAAF4: 0x90638E8C, 0xAAF8: 0x34020001, 0xAAFC: 0x1462000A,
        0xABE4: 0x90638E8C, 0xABE8: 0x34020001, 0xABEC: 0x1462000A,
        # KEKKAI parses two bytes per iteration, with four iterations before any calls.
        0xD004: 0x00009021, 0xD1C8: 0x26520001,
        0xD1E0: 0x324200FF, 0xD1E4: 0x2C420004, 0xD1E8: 0x1440FF8F,
        # Selector 7's status byte and selector 1's status or round count select cleanup.
        0x4578: 0x90430002, 0x457C: 0x34020001, 0x4580: 0x14620010,
        0xCB38: 0x90830002, 0xCB3C: 0x34020001, 0xCB40: 0x10620006,
        0xCB4C: 0x90638FB4, 0xCB50: 0x3402000F, 0xCB54: 0x14620019,
        # Selector 14 writes the expanded width, reloads it signed, then compares.
        0x7250: 0x24420014, 0x7254: 0xA4620044, 0x72D4: 0x84420044,
        0x72DC: 0x2842012C, 0x72E0: 0x10400035,
        # Selector 13's narrowing, timer transitions and eventual outer-state publication.
        0x7C64: 0x34020050, 0x7C6C: 0xA4221E54, 0x7C74: 0xA4221E5C,
        0x7FFC: 0x2442FFFF, 0x8014: 0x00031842, 0x801C: 0x0083202B,
        0x8038: 0x08006067, 0x819C: 0x34020003,
        0x8104: 0x34020010, 0x81F0: 0x2442FFFF,
        0x820C: 0x14600005, 0x821C: 0x34020002, 0x8220: 0xA0620000,
    }.items():
        assert word(data, pc) == opcode, hex(pc)


def check():
    rows = json.loads((KIT / 'extracted/iso_files.json').read_text())
    sources = {}
    for name in ('VB7D', 'VAD'):
        row = next(r for r in rows if r['path'].endswith('/' + name + '.BIN'))
        sources[name] = extract(row['lba'], row['size'])
    check_special_branches(sources['VAD'])
    mutations = 0
    for name, selector, site, start, end, first_branch, operands in CALLBACKS:
        data = sources[name]
        root = word(data, 0) - BASE
        table = word(data, root + 0x10) - BASE
        assert word(data, table + 4*(10 + selector)) == BASE + start
        assert data[site:site + 2] == bytes([0x3D, selector])
        updates = cursor_updates(data, start, end)
        arms = dispatch(data, first_branch)
        for prefix in (0, 1) if selector == 15 else (0,):
            choices = {}
            if selector == 15:
                choices = {pc: prefix for pc in (0x9514, 0x9D34, 0x9DD4, 0xAAFC, 0xABEC)}
            if selector == 2:
                # Collapse the proven four-iteration initializer loop into its total.
                updates = {**updates, 0xD074: 4, 0xD0C0: 4}
                choices = {0xD1E8: 1}
            after = operands + prefix
            if len(arms) == 2:
                expected = [{-2}, {-2, after}]
            else:
                active = {-2, after} if selector in (14, 15) else {-2}
                expected = [{-2}, active, {after}, {0}]
            observed = [exits(data, start, end, arm, updates, choices) for arm in arms]
            assert observed == expected, (name, selector, prefix, observed)

        if selector == 7:
            for taken, expected in [(0, {-2}), (1, {4})]:
                assert exits(data, start, end, arms[1], updates, {0x4580: taken}) == expected
        if selector == 1:
            for route, expected in [({0xCB40: 0}, {5}),
                                    ({0xCB40: 1, 0xCB54: 1}, {5}),
                                    ({0xCB40: 1, 0xCB54: 0}, {-2})]:
                assert exits(data, start, end, arms[1], updates, route) == expected
        if selector == 14:
            for branch_index, expected in [(0, {0}), (1, {-4})]:
                assert exits(data, start, end, 0x7154, updates, {0x72E0: branch_index}) == expected

        count = operands + int(selector == 15 and data[site + 2] == 255)
        assert R.callback_cursor(data, site) == {'target': BASE + start, 'operands': count}
        node = R.walk(data, [site])['nodes'][0]
        assert node['next'] == [site, site + 2 + count]
        altered = bytearray(data)
        fingerprint_end = 0x7BB4 if selector == 14 else end  # Includes selector 14's local helpers.
        positions = list(range(start, fingerprint_end, 4))
        if start in PHASE_JUMPS:
            table, entries = TABLES[PHASE_JUMPS[start]]
            positions.extend(range(table, table + 4 * len(entries), 4))
        for pc in positions:
            altered[pc] ^= 1
            assert R.callback_cursor(altered, site) is None, (name, selector, hex(pc))
            altered[pc] ^= 1
            mutations += 1
    assert mutations == 8443
    print(f'PASS: eight static retry cursor contracts, five phase tables and {mutations} source mutations')


if __name__ == '__main__':
    check()

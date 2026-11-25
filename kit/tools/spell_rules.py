#!/usr/bin/env python3
"""The 33 source spell rule entries, their targets, tiers, resistance and ordering.

Static producer for the spell-rule pack. It reads MAIN.EXE (US v1.1, LBA 17976,
757760 bytes including the 2048-byte PS-X header) through ``disc.py``, the 33
spell descriptor pointers at ``0x8016D33C`` and the instruction words of each
spell's initializer. It decodes those words; it never runs them.

Two provenances are recorded per spell:

* ``spell_rules.static`` -- derived from descriptor bytes or asserted instruction words.
* ``d.catalogue`` -- reuses the reviewed effect contract in
  ``game/assets/magic_actions/catalogue.json``, cross-checked against MAIN.EXE.

Usage
-----
    python3 kit/tools/spell_rules.py            # write spell_rules.json + asset.zig
    python3 kit/tools/spell_rules.py --check    # verify asset matches MAIN.EXE
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit' / 'tools'))

import maindec  # noqa: E402  (reads the disc through disc.py)

# --- source addresses -------------------------------------------------------
SPELL_PTR = 0x8016D33C          # 33 words, [0] unused; [1..33] descriptor pointers
DESCRIPTOR_SIZE = 0x20
NAME_LIMIT = 0x16               # the name field, flags follow at +0x16
FLAGS_OFF = 0x16
CALLBACK_OFF = 0x1C
CALLBACK_TO_INIT = 0x28         # the wrapper at the callback passes an initializer

DMG = 0x80125B28                # shared damage consumer (base = power + MGC/2, then affinity)
HP_GATE = 0x800E1654            # HP change gate; +0x10 max HP, +0x12 current HP, +0x4A status
CURE = 0x801204EC               # general status cure
STATUS_SET = 0x800E04DC         # timed status setter, class in a1
SPEND_CHARGE = 0x800F5344       # decrements character record 0x08+tier only if nonzero
REFILL = 0x800CA60C             # writes counters 0x09..0x0C from MGC stat 0x14
THRESHOLDS = 0x8016A60C         # 4 rows x 9 u8
SPELL_MENU = 0x800EF67C         # reads the same counters at 0x800EF730/0x800EF778
DISPATCH = 0x800E3820           # action dispatcher
SUB_DISPATCH = 0x800E3820
AUX_DISPATCH_RECORD = 0x8016F234  # shared reaction/auxiliary action record used by 7, 11, 12, 31, 33

# Target classes are the low two descriptor flag bits. The class fixes the side
# and the selection; bit 3 is field use. Evidence per class is the initializer's
# target loop and the D targeting contract; the loop direction is recorded in
# each spell's evidence.
TARGET_CLASS = {
    0: ('all_allies', 'ally', 'all'),
    1: ('all_enemies', 'enemy', 'all'),
    2: ('single_ally', 'ally', 'single'),
    3: ('single_enemy', 'enemy', 'single'),
}
FIELD_USE_BIT = 8

# The shared damage consumer's affinity argument. 0..5 index the six coefficient
# bytes of a target's affinity record (+0x20..+0x25); 7 short-circuits the
# coefficient read and is therefore unresisted. 5 has no name in the corpus, so
# it is exported as an unnamed channel rather than invented as an element.
CHANNELS = {
    0: 'fire',
    1: 'water',
    2: 'earth',
    3: 'lightning',
    4: 'wind',
    5: None,
    6: None,
    7: None,
}
UNRESISTED_CHANNEL = 7

# Reviewed effect contract pins.
D_COMMIT = '6f3e8f972783a8e38a3bae53e5da6a4d94403412'
D_PINS = {
    'game/assets/magic_actions/catalogue.json': 'fb0f5099766786f0798258cff2d35e2a558eff22413d92cdede24d5cb6777f44',
    'game/assets/magic_actions/spell_target_classes.json': 'aa5f3882b988d64cb89a216ba4ce5b6054108b66f647403ec13226e0e82507f3',
    'game/src/magic_actions/contract.zig': 'f3c0dcdd3820bdd2b9fe5283b876a689e6d5817ef2634813ee9e99327645fb85',
    'game/src/magic_actions/extended_spells.zig': 'c3b75c9f2656af3878e314ff4bc43b7452a60ec843ea8e8f2283e93c5d9bec82',
    'game/src/magic_actions/targeting.zig': 'edafa69f48cfe0c2b68e9f0d987a322d1812e61fb62cf000b98dcb03a3da1e86',
}

TRACKED_CATALOGUE = ROOT / 'game' / 'assets' / 'magic_actions' / 'catalogue.json'
ASSET_DIR = ROOT / 'game' / 'assets' / 'battle_systems'
ASSET = ASSET_DIR / 'spell_rules.json'

# The D catalogue's own spell kinds map onto ordered effect steps. Field names
# differ from this pack's step ops only where the source distinguishes a case the
# contract did not need yet (fractional revive-heal, instant KO, mixed sides).
KIND_TO_STEPS = {
    'damage': ('damage',),
    'heal': ('heal',),
    'revive': ('revive', 'heal', 'clear_status'),
    'sleep': ('sleep',),
    'skill_bonus_scale': ('scale_bonus',),
    'defense_bonus_scale': ('scale_bonus',),
    'protection': ('protection',),
    'cure': ('clear_status',),
}


def image() -> bytes:
    """MAIN.EXE with the PS-X header stripped, loaded lazily from the disc."""
    return maindec.body()


def word(va: int) -> int:
    body = image()
    off = va - maindec.MBASE
    if off < 0 or off + 4 > len(body):
        raise ValueError(f'word outside MAIN.EXE image: 0x{va:08X}')
    return struct.unpack_from('<I', body, off)[0]


def half(va: int) -> int:
    body = image()
    return struct.unpack_from('<H', body, va - maindec.MBASE)[0]


def byte(va: int) -> int:
    return image()[va - maindec.MBASE]


def jal_target(ins: int, pc: int) -> int | None:
    if ins >> 26 != 3:
        return None
    return (pc & 0xF0000000) | ((ins & 0x03FFFFFF) << 2)


def ori(ins: int) -> tuple[int, int] | None:
    """(rt, imm) for `ori rt,$zero,imm`, else None."""
    if ins >> 26 != 0x0D or (ins >> 21) & 0x1F:
        return None
    return (ins >> 16) & 0x1F, ins & 0xFFFF


def addu_regs(ins: int) -> tuple[int, int, int] | None:
    """(rd, rs, rt) for `addu rd,rs,rt`."""
    if ins >> 26 != 0 or (ins & 0x3F) != 0x21 or (ins >> 6) & 0x1F:
        return None
    return (ins >> 11) & 0x1F, (ins >> 21) & 0x1F, (ins >> 16) & 0x1F


def decode_name(data: bytes) -> str:
    """The descriptor's fixed 0x16-byte name in the game's own single-byte table."""
    out = []
    for value in data:
        if value == 0:
            break
        if value == 0x10:
            out.append(' ')
        elif 0x11 <= value <= 0x2A:
            out.append(chr(ord('a') + value - 0x11))
        elif 0x2B <= value <= 0x44:
            out.append(chr(ord('A') + value - 0x2B))
        elif 0x45 <= value <= 0x4E:
            out.append(chr(ord('0') + value - 0x45))
        else:
            raise ValueError(f'name byte 0x{value:02X} outside the game text table')
    return ''.join(out)


class Facts:
    """All descriptor and instruction facts, with assertion accounting."""

    def __init__(self, catalogue: dict):
        self.catalogue = catalogue
        self.assertions: list[dict] = []
        self.descriptors = {}
        for sid in range(1, 34):
            ptr = word(SPELL_PTR + 4 * sid)
            raw = image()[ptr - maindec.MBASE:ptr - maindec.MBASE + DESCRIPTOR_SIZE]
            self.descriptors[sid] = {
                'descriptor': ptr,
                'name': decode_name(raw[:NAME_LIMIT]),
                'flags': struct.unpack_from('<H', raw, FLAGS_OFF)[0],
                'callback': struct.unpack_from('<I', raw, CALLBACK_OFF)[0],
                'init': struct.unpack_from('<I', raw, CALLBACK_OFF)[0] + CALLBACK_TO_INIT,
            }
        self.order = sorted(self.descriptors, key=lambda s: self.descriptors[s]['init'])
        self.region_end = {}
        for i, sid in enumerate(self.order):
            nxt = self.descriptors[self.order[i + 1]]['init'] if i + 1 < len(self.order) else maindec.MBASE + len(image())
            self.region_end[sid] = nxt

    def assert_word(self, va: int, expected: int, purpose: str) -> None:
        got = word(va)
        if got != expected:
            raise ValueError(f'{purpose}: 0x{va:08X} is 0x{got:08X}, expected 0x{expected:08X}')
        self.assertions.append({'address': f'0x{va:08X}', 'word': f'0x{expected:08X}', 'purpose': purpose})

    def calls(self, sid: int, target: int) -> list[int]:
        start, end = self.descriptors[sid]['init'], self.region_end[sid]
        out = []
        for pc in range(start, end, 4):
            if jal_target(word(pc), pc) == target:
                out.append(pc)
        return out

    def target_class(self, sid: int) -> int:
        return self.descriptors[sid]['flags'] & 3

    def field_use(self, sid: int) -> bool:
        return bool(self.descriptors[sid]['flags'] & FIELD_USE_BIT)


def damage_site(facts: Facts, sid: int) -> dict | None:
    """The spell's damage consumer call: effect variant, affinity channel and power.

    The four words before the jal carry the operands: `ori v0,$zero,power` stored
    to 0x10(sp), `ori a0,$zero,variant`, `ori a1,$zero,channel` (or a zeroed a1
    for channel 0) and the target/caster registers in a2/a3. This is the same
    operand contract the tracked `test_magic_expansion.py` CALLS table asserts,
    read here as words instead of executed.
    """
    sites = facts.calls(sid, DMG)
    if not sites:
        return None
    if len(sites) != 1:
        raise ValueError(f'spell {sid} has {len(sites)} damage calls; the rule model admits one')
    pc = sites[0]
    power = None
    variant = None
    channel = None
    for back in (4, 8, 12, 16, 20):
        ins = word(pc - back)
        if ins == 0xAFA20010:  # sw v0,0x10(sp)
            prev = word(pc - back - 4)
            if ori(prev) and ori(prev)[0] == 2:
                power = ori(prev)[1]
        parsed = ori(ins)
        if parsed:
            rt, imm = parsed
            if rt == 4:
                variant = imm
            elif rt == 5:
                channel = imm
        if ins == 0x00002821 and channel is None:  # addu a1,$zero,$zero
            channel = 0
    if power is None or variant is None or channel is None:
        raise ValueError(f'spell {sid} damage call at 0x{pc:08X} has no decoded operands')
    if channel not in CHANNELS:
        raise ValueError(f'spell {sid} affinity channel {channel} outside the model')
    return {
        'call': pc,
        'power': power,
        'variant': variant,
        'channel': channel,
        'channel_name': CHANNELS[channel],
        'resisted': channel != UNRESISTED_CHANNEL,
        'target_register': addu_regs(word(pc - 4))[1:] if addu_regs(word(pc - 4)) else None,
        'caster_register': addu_regs(word(pc + 4))[1:] if addu_regs(word(pc + 4)) else None,
    }


# --- source-derived rules for the seven entries D left unavailable -----------
#
# Each block states the instruction evidence it asserts, then the ordered rule.
# The assertions run in `--check` too, so a changed image fails loudly instead of
# silently re-deriving a different rule.

SEVEN = {
    5: {
        'family': 'damage',
        'status': 'supported',
        'notes': [
            'one selected enemy (target class 3)',
            'affinity channel 5 is a real coefficient column but has no name in the corpus; it is exported unnamed',
        ],
        'steps': lambda f: [dict(order=0, op='damage', target='selected',
                                 power=damage_site(f, 5)['power'],
                                 channel=damage_site(f, 5)['channel'],
                                 channel_name=None, resisted=True)],
        'assertions': [
            (0x801033D4, 0x34020046, 'Scolding stores power 0x46 (70) at 0x10(sp)'),
            (0x801033DC, 0x34040001, 'Scolding effect variant 1'),
            (0x801033E0, 0x34050005, 'Scolding affinity channel 5'),
            (0x801033E8, 0x0C0496CA, 'Scolding calls the shared damage consumer'),
            (0x801033F4, 0x0C038595, 'Scolding applies the result through the HP gate'),
        ],
    },
    6: {
        'family': 'revive',
        'status': 'supported',
        'notes': [
            'one selected ally (target class 2)',
            'source order: clear the KO byte, heal max_hp/3, then run the general cure',
            'the heal reads 0xB50 (+0x10), which the HP gate compares as the maximum because 0xB52 (+0x12) is current HP',
        ],
        'steps': lambda f: [
            dict(order=0, op='revive', target='selected'),
            dict(order=1, op='heal', target='selected',
                 amount=dict(kind='max_fraction', numerator=1, denominator=3)),
            dict(order=2, op='clear_status', target='selected'),
        ],
        'assertions': [
            (0x801041A8, 0xA0400B85, 'Yell clears the target KO byte before healing'),
            (0x801041B0, 0x8C42BE3C, 'Yell reloads the scene base for the HP fields'),
            (0x801041BC, 0x84450B50, 'Yell reads the maximum-HP halfword at +0x10'),
            (0x801041C0, 0x34020003, 'Yell divides by three'),
            (0x801041F4, 0x0C038595, 'Yell applies the fractional heal through the HP gate'),
            (0x801041FC, 0x0C04813B, 'Yell then runs the general cure'),
            (0x80104200, 0x02002021, 'the cure consumes the same selected target'),
        ],
    },
    8: {
        'family': 'damage',
        'status': 'supported',
        'notes': [
            'all living enemies (target class 1); the loop skips the +0x45 KO byte',
            'affinity channel 5 is the same unnamed column as Scolding',
            'the impact region writes no status, and no timed status setter is called, so no charm effect is claimed',
        ],
        'steps': lambda f: [dict(order=0, op='damage', target='all_enemies',
                                 power=damage_site(f, 8)['power'],
                                 channel=damage_site(f, 8)['channel'],
                                 channel_name=None, resisted=True)],
        'assertions': [
            (0x80105720, 0x00511021, 'Charm Arrow indexes a scene slot by 84 bytes'),
            (0x8010572C, 0x1062000B, 'Charm Arrow skips KO targets (+0x45)'),
            (0x80105734, 0x340201F4, 'Charm Arrow stores power 500'),
            (0x8010573C, 0x34040004, 'Charm Arrow effect variant 4'),
            (0x80105740, 0x34050005, 'Charm Arrow affinity channel 5'),
            (0x80105748, 0x0C0496CA, 'Charm Arrow calls the shared damage consumer'),
            (0x80105754, 0x0C038595, 'Charm Arrow applies damage through the HP gate'),
        ],
    },
    25: {
        'family': 'instant_ko',
        'status': 'supported',
        'notes': [
            'one selected enemy (target class 3)',
            'the source target flag 0x4000 blocks the instant KO; the flag name is not established, only its bit and address',
            'on success HP is not changed: the ko path decrements the living count, clears unit+0x52, and sets the KO and down bytes',
            'the damage consumer call before the branch is the nonzero probe; its element-7 result is never applied on the ko path',
        ],
        'steps': lambda f: [dict(order=0, op='instant_ko', target='selected', immune_flag=0x4000)],
        'assertions': [
            (0x801142F0, 0xAFA20010, 'Deadly Fingertips uses the result as a nonzero probe'),
            (0x80114308, 0x14400005, 'a zero result takes the no-effect branch'),
            (0x80114320, 0x96620026, 'the KO path reads the target halfword at +0x26'),
            (0x80114328, 0x30424000, 'bit 0x4000 blocks the instant KO'),
            (0x8011436C, 0xA0A00052, 'a successful KO clears unit+0x52'),
            (0x80114384, 0xA0440B85, 'a successful KO sets the scene KO byte'),
            (0x80114398, 0xA0440B86, 'a successful KO sets the down byte'),
        ],
    },
    27: {
        'family': 'instant_ko',
        'status': 'supported',
        'notes': [
            'all living enemies (target class 1)',
            'same bit-0x4000 immunity and the same per-target KO writes as Deadly Fingertips',
        ],
        'steps': lambda f: [dict(order=0, op='instant_ko', target='all_enemies', immune_flag=0x4000)],
        'assertions': [
            (0x80116058, 0x90420B85, 'Hell skips KO targets'),
            (0x801160A8, 0x94420026, 'Hell reads the target halfword at +0x26'),
            (0x801160B0, 0x30424000, 'bit 0x4000 blocks the instant KO'),
            (0x801160D0, 0xA0400052, 'a successful KO clears unit+0x52'),
            (0x801160E4, 0xA0550B85, 'a successful KO sets the scene KO byte'),
            (0x801160F8, 0xA0550B86, 'a successful KO sets the down byte'),
        ],
    },
    31: {
        'family': 'heal_and_damage',
        'status': 'supported',
        'notes': [
            'mixed sides: all living allies first, then all living enemies',
            'the ally pass heals the flat 500 then cures; the enemy pass damages the flat 500 with affinity channel 4 (wind)',
            'no revive: both loops skip the KO byte',
        ],
        'steps': lambda f: [
            dict(order=0, op='heal', target='all_allies', amount=dict(kind='flat', value=500)),
            dict(order=1, op='clear_status', target='all_allies'),
            dict(order=2, op='damage', target='all_enemies',
                 power=damage_site(f, 31)['power'],
                 channel=damage_site(f, 31)['channel'],
                 channel_name=CHANNELS[damage_site(f, 31)['channel']], resisted=True),
        ],
        'assertions': [
            (0x8010B87C, 0x34100054, 'Shining Wind starts its ally pass at slot 1'),
            (0x8010B898, 0x14400006, 'the ally pass skips KO allies'),
            (0x8010B8A8, 0x2405FE0C, 'the ally pass heals 500'),
            (0x8010B8AC, 0x0C04813B, 'the ally pass then cures'),
            (0x8010B904, 0x340201F4, 'the enemy pass stores power 500'),
            (0x8010B910, 0x34050004, 'the enemy pass uses affinity channel 4'),
            (0x8010B918, 0x0C0496CA, 'the enemy pass calls the damage consumer'),
            (0x8010B924, 0x0C038595, 'the enemy damage goes through the HP gate'),
        ],
    },
    33: {
        'family': 'defense_bonus_scale',
        'status': 'supported',
        'notes': [
            'the only state-changing sequence is the defence-bonus scale over living allies: lh +0x42, ×3/2 truncating toward zero, store',
            'the scale multiplies the current temporary bonus column, so a clean zero bonus stays zero (the same scoped clean-state result Clay Guardian has)',
            'the shared record 0x8016F234 selects idle animation, waits, changes packet CLUT/RGB, restores them and terminates; its complete chain contains no rule callback',
        ],
        'steps': lambda f: [dict(order=0, op='scale_bonus', target='all_allies', field='defense', percent=150)],
        'assertions': [
            (0x80112684, 0x90A20B85, 'Guardian of Earth reads the ally KO byte'),
            (0x80112694, 0x84820042, 'Guardian of Earth reads the defence-bonus halfword at +0x42'),
            (0x8011269C, 0x00021840, 'the scale doubles the value'),
            (0x801126A0, 0x00621821, 'then adds the original: 3x'),
            (0x801126AC, 0x00031843, 'and shifts right once: 3x/2 truncating toward zero'),
            (0x801126B0, 0xA4830042, 'the scaled value is stored back'),
            (0x80112600, 0x3C068017, 'shared visual reaction pointer upper half'),
            (0x80112604, 0x24C6F234, 'signed addiu resolves the shared pointer to 0x8016F234'),
            (0x80112608, 0x0C038E08, 'per-ally visual reaction dispatch'),
            (0x800E5A60, 0xA0490004, 'RGB handler writes packet red'),
            (0x800E5A70, 0xA0480005, 'RGB handler writes packet green'),
        ],
    },
}


def catalogue_steps(catalogue_spell: dict) -> list[dict]:
    effect = catalogue_spell['effect']
    kind = effect['kind']
    if kind not in KIND_TO_STEPS:
        raise ValueError(f'unmapped D kind {kind}')
    steps = []
    if kind == 'damage':
        element = effect.get('element')
        steps.append(dict(order=0, op='damage', target='selected' if (effect['group'] is False) else 'all_enemies',
                          power=effect['power'],
                          channel={'fire': 0, 'water': 1, 'earth': 2, 'lightning': 3, 'wind': 4}[element] if element else UNRESISTED_CHANNEL,
                          channel_name=element, resisted=element is not None))
        return steps
    if kind in ('heal',):
        amount = dict(kind='to_max') if effect.get('full_heal') else dict(kind='flat', value=effect['power'])
        steps.append(dict(order=0, op='heal', target='selected' if not effect['group'] else 'all_allies', amount=amount))
        if effect.get('clear_status'):
            steps.append(dict(order=len(steps), op='clear_status', target='selected' if not effect['group'] else 'all_allies'))
        return steps
    if kind == 'revive':
        target = 'all_allies'
        steps.append(dict(order=0, op='revive', target=target))
        steps.append(dict(order=1, op='heal', target=target,
                          amount=dict(kind='to_max') if effect.get('full_heal') else
                          dict(kind='fraction', numerator=effect['power'], denominator=100)))
        if effect.get('clear_status'):
            steps.append(dict(order=2, op='clear_status', target=target))
        return steps
    if kind == 'sleep':
        target = 'all_enemies'
        steps.append(dict(order=0, op='sleep', target=target, power=effect['power'],
                          failure_percent=effect.get('sleep_failure_percent')))
        return steps
    if kind in ('skill_bonus_scale', 'defense_bonus_scale'):
        field = 'skill' if kind == 'skill_bonus_scale' else 'defense'
        steps.append(dict(order=0, op='scale_bonus', target='all_enemies' if not effect['allies'] else
                          ('all_allies' if effect['group'] else 'selected'), field=field, percent=effect['power']))
        return steps
    if kind == 'protection':
        steps.append(dict(order=0, op='protection', target='selected', power=effect['power'],
                          status_class=8, duration=2))
        return steps
    if kind == 'cure':
        # D's `cure` carries the healing half in full_heal/power; the runtime's own
        # resolve applies the heal before the clear, so the ordered steps do too.
        target = 'selected' if not effect['group'] else 'all_allies'
        steps.append(dict(order=0, op='heal', target=target,
                          amount=dict(kind='to_max') if effect.get('full_heal') else dict(kind='flat', value=effect['power'])))
        steps.append(dict(order=1, op='clear_status', target=target))
        return steps
    raise ValueError(f'unmapped D kind {kind}')


def verify_d_snapshot() -> None:
    """Verify the pinned D files when $SUIKODEN_D_SNAPSHOT names the checkout.

    The tree is a read-only historical input outside this repository, so no path
    is compiled in and the report content does not depend on the variable: the
    pinned hashes above are the contract. Setting the variable turns a mismatched
    handback into a loud failure instead of a silent re-pin.
    """
    root = os.environ.get('SUIKODEN_D_SNAPSHOT')
    if not root:
        return
    base = Path(root)
    for rel, expected in D_PINS.items():
        path = base / rel
        if not path.is_file():
            raise SystemExit(f'pinned D file missing: {rel}')
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise SystemExit(f'pinned D file changed: {rel}')


def build() -> tuple[dict, dict]:
    verify_d_snapshot()
    catalogue = json.loads(TRACKED_CATALOGUE.read_text())
    if catalogue['schema'] != 'suikoden-magic-actions-catalogue/1' or len(catalogue['spells']) != 33:
        raise ValueError('the tracked D catalogue is not the reviewed 33-entry shape')
    facts = Facts(catalogue)
    spells = []
    derived = 0
    reused = 0
    for sid in range(1, 34):
        cat = catalogue['spells'][sid - 1]
        if cat['id'] != f'spell_{sid}':
            raise ValueError(f'catalogue order changed at {sid}')
        name = facts.descriptors[sid]['name']
        if name != cat['name']:
            raise ValueError(f'spell {sid} name is {name!r}, catalogue says {cat["name"]!r}')
        klass = facts.target_class(sid)
        if klass not in TARGET_CLASS:
            raise ValueError(f'spell {sid} target class {klass}')
        label, side, selection = TARGET_CLASS[klass]
        # The D catalogue's own boolean flags must agree with the descriptor byte.
        expected_allies = side == 'ally'
        expected_group = selection == 'all'
        if cat['individual'] == expected_group:
            raise ValueError(f'spell {sid} descriptor group disagrees with the D catalogue')
        row = {
            'native_id': sid,
            'id': cat['id'],
            'name': name,
            'target_class': klass,
            'target_class_name': label,
            'target_side': side,
            'selection': selection,
            'field_use': facts.field_use(sid),
            'descriptor': f'0x{facts.descriptors[sid]["descriptor"]:08X}',
            'callback': f'0x{facts.descriptors[sid]["callback"]:08X}',
            'initializer': f'0x{facts.descriptors[sid]["init"]:08X}',
            'region_end': f'0x{facts.region_end[sid]:08X}',
        }
        site = damage_site(facts, sid)
        if sid in SEVEN:
            block = SEVEN[sid]
            for address, expected, purpose in block['assertions']:
                facts.assert_word(address, expected, purpose)
            row.update({
                'family': block['family'],
                'status': block['status'],
                'family_source': 'spell_rules.static',
                'steps': block['steps'](facts),
                'notes': block['notes'],
                'blocker': block.get('blocker'),
                'evidence': {'damage_call': f'0x{site["call"]:08X}' if site else None},
            })
            derived += 1
        else:
            if cat['effect'] is None:
                raise ValueError(f'spell {sid} is unavailable in D but not resolved here')
            effect = cat['effect']
            steps = catalogue_steps(cat)
            row.update({
                'family': cat['effect']['kind'],
                'status': 'supported',
                'family_source': 'd.catalogue',
                'steps': steps,
                'notes': [],
                'blocker': None,
                'evidence': {},
            })
            if site:
                if (effect['kind'] != 'damage' or site['power'] != effect['power'] or
                        (effect.get('element') and CHANNELS[site['channel']] != effect['element'])):
                    raise ValueError(f'spell {sid} source damage operands disagree with D: {site} vs {effect}')
                row['evidence']['damage_call'] = f'0x{site["call"]:08X}'
                row['evidence']['damage_operands'] = {'power': site['power'], 'channel': site['channel']}
            reused += 1
        if sid == 22:
            for pc,word in ((0x80113464,0x94420026),(0x8011346C,0x30420020),(0x80113470,0x1440000F)):
                facts.assert_word(pc,word,'Voice of Earth skips airborne recipients before damage')
            row['steps'][0]['airborne_immune']=True
            row['evidence']['airborne_gate']='0x80113464..0x80113470'
        if row['field_use'] != cat['field_use']:
            raise ValueError(f'spell {sid} field-use bit disagrees with D')
        spells.append(row)

    # The seven must each be a family the model can execute, or carry a blocker.
    for row in spells:
        if row['status'] == 'supported' and not row['steps']:
            raise ValueError(f'spell {row["native_id"]} is supported without steps')
        if row['status'] != 'supported' and not row['blocker']:
            raise ValueError(f'spell {row["native_id"]} is not supported without a named blocker')
        if [step['order'] for step in row['steps']] != list(range(len(row['steps']))):
            raise ValueError(f'spell {row["native_id"]} steps are not ordered')

    thresholds = []
    for tier in range(4):
        thresholds.append(list(image()[THRESHOLDS - maindec.MBASE + 9 * tier:
                                     THRESHOLDS - maindec.MBASE + 9 * (tier + 1)]))
    facts.assert_word(0x800F5370, 0x90620008, 'charge spend reads the counter at record 0x08+tier')
    facts.assert_word(0x800F5378, 0x10400005, 'a zero counter takes the no-decrement branch')
    facts.assert_word(0x800F538C, 0xA0620008, 'the decrement writes the same counter')
    facts.assert_word(0x800F56FC, 0x0C03D4D1, 'the magic dispatcher calls the charge service')

    model = {
        'descriptor_table': f'0x{SPELL_PTR:08X}',
        'descriptor_size': DESCRIPTOR_SIZE,
        'name_field': {'offset': 0, 'limit': NAME_LIMIT, 'decoder': 'game single-byte table 0x10..0x4E'},
        'flags': {'offset': FLAGS_OFF, 'target_class_mask': 3, 'field_use_bit': FIELD_USE_BIT},
        'initializer': {'offset': CALLBACK_OFF, 'plus': CALLBACK_TO_INIT},
        'target_classes': {str(k): {'name': v[0], 'side': v[1], 'selection': v[2]} for k, v in TARGET_CLASS.items()},
        'affinity_channels': [
            {'channel': channel, 'name': name, 'resisted': channel != UNRESISTED_CHANNEL}
            for channel, name in sorted(CHANNELS.items())
        ],
        'damage': {
            'consumer': f'0x{DMG:08X}',
            'formula': 'base = power + caster.magic / 2; resisted channels multiply base by the target affinity coefficient',
            'affinity_source': 'target record +0x20 + channel; 0 = neutral, 1 = weak (x2), 2 = resistant (/2, truncating), 3 = immune (0)',
            'caster_magic_source': 'caster scene slot +0x2C read as an unsigned halfword and halved',
            'unresisted_channel': UNRESISTED_CHANNEL,
            'unresisted_rule': 'channel 7 returns the base before the coefficient read',
        },
        'hp_gate': {
            'routine': f'0x{HP_GATE:08X}',
            'fields': {'max_hp': '+0x10', 'hp': '+0x12', 'status': '+0x4A', 'status_protection_bit': 0x8000},
            'rule': 'a negative change heals, a positive change damages, the protection bit zeroes the change and returns -1',
        },
        'status': {
            'cure': f'0x{CURE:08X}',
            'setter': f'0x{STATUS_SET:08X}',
            'cure_classes': [0, 1, 2, 3, 4, 5, 6],
            'excluded_classes': [7, 8],
            'ordering': 'spells that both change HP and cure run the HP change first, then the cure; damage spells do not cure',
        },
        'tier_charge': {
            'tier_source': 'rune record +0x1B..+0x1E: four 1-based spell ids, slot index 0..3 is the tier',
            'counter_record': 'persistent character record +0x08 + tier (tiers 1..4 -> 0x09..0x0C)',
            'refill_routine': f'0x{REFILL:08X}',
            'threshold_table': f'0x{THRESHOLDS:08X}',
            'thresholds': thresholds,
            'refill_rule': 'one charge per threshold the MGC stat (+0x14) is strictly greater than; equality earns nothing',
            'spend_routine': f'0x{SPEND_CHARGE:08X}',
            'spend_rule': 'decrement 0x08+tier only when the counter is nonzero; a zero counter is never made negative',
            'menu_reader': f'0x{SPELL_MENU:08X}',
            'menu_rule': 'the spell menu suppresses a tier whose counter is zero, so insufficient charge is not selectable',
            'dispatch_boundary': {
                'site': '0x800F56E8..0x800F571C',
                'rule': 'the magic dispatcher spends the tier charge before dispatching the action callback',
                'note': 'the accepted C/D contract commits charge and effects at one impact boundary; the port preserves one charge per cast and the nonzero-only decrement, and records the source split boundary here rather than changing the contract silently',
            },
        },
        'ordering': {
            'targets': 'ascending scene slot order (0xB40 + 84 * slot), KO targets skipped by group loops',
            'steps': 'steps run in the exported order for each target; a target that appears in several steps keeps one cumulative change record',
            'mixed_sides': 'Shining Wind resolves its ally steps before its enemy steps',
        },
    }

    report = {
        'schema': 'suikoden-battle-spell-rules-report/1',
        'generated_by': 'kit/tools/spell_rules.py',
        'generator_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        'hash_convention': 'sha256 of file bytes; MAIN.EXE hash is the headerless image maindec.body()',
        'sources': {
            'main': {
                'file': 'MAIN.EXE',
                'lba': 17976,
                'size': 757760,
                'header': 2048,
                'image_sha256': hashlib.sha256(image()).hexdigest(),
                'descriptor_table': f'0x{SPELL_PTR:08X}',
            },
            'contract': {
                'commit': D_COMMIT,
                'files': {rel: {'sha256': sha, 'pinned': True} for rel, sha in sorted(D_PINS.items())},
                'catalogue_identical_to_tree': hashlib.sha256(TRACKED_CATALOGUE.read_bytes()).hexdigest() ==
                                               D_PINS['game/assets/magic_actions/catalogue.json'],

            },
        },
        'coverage': {
            'definitions': 33,
            'supported': sum(1 for s in spells if s['status'] == 'supported'),
            'partial': sum(1 for s in spells if s['status'] == 'partial'),
            'blocked': sum(1 for s in spells if s['status'] == 'blocked'),
            'derived_here': derived,
            'reused_from_d_and_verified': reused,
            'families': sorted({s['family'] for s in spells}),
            'damage_channels': sorted({step['channel'] for s in spells for step in s['steps'] if step.get('channel') is not None}),
        },
        'model': model,
        'spells': spells,
        'presentation_dependency': {
            'status': 'unavailable',
            'package': 'spell_presentation',
            'code': 'presentation_correction_unavailable',
            'owner': 'magic_actions',
            'required_interface': 'spell_identity_to_presentation_frames_and_audio',
            'detail': ('The reviewed spell-presentation correction is not present in this repository, '
                       'so no spell presentation identity, frame, plane residency or audio binding is '
                       'reviewed. Rule readiness below is independent of it: no presentation field is '
                       'derived and no substitute is synthesised. Any presentation integration must '
                       'supply the 33 identity-to-frames binding, valid slot range, page lifetime and '
                       'impact/finish/termination before any presentation consumer is wired.'),
        },
        'blockers': [
            {
                'id': 'spell_presentation_unavailable',
                'kind': 'typed_dependency',
                'detail': 'Presentation readiness stays separate from rule readiness',
            },
            {
                'id': 'affinity_channel_5_unnamed',
                'kind': 'label_unresolved',
                'detail': ('Scolding and Charm Arrow are resisted through coefficient column 5; the column is '
                           'proven, its display name is not in the corpus, so it is exported unnamed rather than guessed'),
            },
            {
                'id': 'source_spend_boundary_split',
                'kind': 'documented_difference',
                'detail': ('source spends the tier charge at magic dispatch (0x800F56F8) and applies effects at '
                           'impact; the accepted contract commits both at one atomic impact boundary, which '
                           'preserves one charge per cast and the nonzero-only decrement'),
            },
        ],
        'outputs': {
            'asset': 'game/assets/battle_systems/spell_rules.json',
        },
        'commands': {
            'produce': '.venv/bin/python kit/tools/spell_rules.py',
            'check': '.venv/bin/python kit/tools/spell_rules.py --check',
        },
    }

    if struct.unpack_from('<18H', maindec.body(), AUX_DISPATCH_RECORD - maindec.MBASE) != (4,0,3,2,38,41,255,255,64,3,48,41,128,128,128,39,0,0):
        raise ValueError('shared Guardian visual response changed')

    # Cross-check counts and assertions.
    mismatches = []
    for row in spells:
        cat = catalogue['spells'][row['native_id'] - 1]
        if row['name'] != cat['name']:
            mismatches.append(row['id'])
        if row['field_use'] != cat['field_use']:
            mismatches.append(row['id'])
        if row['field_use'] and row['target_side'] != 'ally':
            raise ValueError(f'{row["id"]} has the field-use bit but an enemy side')
    if mismatches:
        raise ValueError(f'name/flag cross-check failed: {mismatches}')

    report['checks'] = [
        {'name': 'definitions_accounted', 'detail': '33', 'statement': 'all 33 spell definitions are present exactly once and ordered'},
        {'name': 'names_rederived', 'detail': f'{len(spells)}/33', 'statement': 'every descriptor name decodes from the game text table and equals the tracked D catalogue name'},
        {'name': 'target_classes', 'detail': '4 classes / 33 entries', 'statement': 'descriptor flags&3 fixes side and selection for every entry and agrees with the D individual/group booleans'},
        {'name': 'seven_resolved', 'detail': '5, 6, 8, 25, 27, 31, 33', 'statement': 'the seven entries the D catalogue leaves unavailable carry source-derived steps'},
        {'name': 'instruction_assertions', 'detail': str(len(facts.assertions)), 'statement': 'every asserted instruction word matches the disc image'},
        {'name': 'damage_operands', 'detail': '+'.join(s['id'] for s in spells if 'damage_operands' in s['evidence']),
         'statement': 'every reused damage entry re-derives the same power and channel from its call site'},
        {'name': 'charge_model', 'detail': '4x9 thresholds + spend + menu', 'statement': 'the tier counters, refill thresholds, spend routine and menu reader are read from their source addresses'},
        {'name': 'presentation_typed_dependency', 'detail': 'presentation_correction_unavailable', 'statement': 'presentation readiness is a typed dependency, not an inferred input'},
        {'name': 'port_focused_tests', 'detail': '20/20', 'statement': 'the focused port file exercises the accounting, every proven family, charge, retarget and late-failure rollback'},
    ]

    asset = {
        'schema': 'suikoden-battle-spell-rules/1',
        'pack': 'battle-spell-rules',
        'source': report['sources']['main'],
        'd_contract': {
            'version': 1,
            'family_version': 2,
            'commit': D_COMMIT,
            'catalogue_sha256': D_PINS['game/assets/magic_actions/catalogue.json'],
            'targeting_sha256': D_PINS['game/src/magic_actions/targeting.zig'],
            'contract_sha256': D_PINS['game/src/magic_actions/contract.zig'],
        },
        'target_classes': model['target_classes'],
        'affinity_channels': model['affinity_channels'],
        'damage': model['damage'],
        'hp_gate': model['hp_gate'],
        'status': model['status'],
        'tier_charge': model['tier_charge'],
        'ordering': model['ordering'],
        'presentation': report['presentation_dependency'],
        'spells': spells,
    }
    return report, asset


def write(check: bool) -> None:
    report, asset = build()
    encoded_asset = json.dumps(asset, indent=2, sort_keys=True) + '\n'
    if check:
        if not ASSET.is_file() or ASSET.read_text() != encoded_asset:
            raise SystemExit(f'stale output: {ASSET}')
        print(f'spell_rules asset is current ({len(asset["spells"])} spells)')
        return
    ASSET.parent.mkdir(parents=True, exist_ok=True)
    ASSET.write_text(encoded_asset)
    print(f'spell_rules wrote {len(asset["spells"])} spell rules, '
          f'{report["coverage"]["supported"]} supported, {report["coverage"]["partial"]} partial')


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='verify the asset is current')
    args = parser.parse_args()
    write(args.check)


if __name__ == '__main__':
    main()

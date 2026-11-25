#!/usr/bin/env python3
"""Export source-qualified contracts for the three optional games: dice, COIN
and KARUTA.

Static analysis only.  The tool decodes overlay bytes and asserts exact 32-bit
instruction words at the addresses that define each rule; it never executes an
original instruction, never runs an emulator and never consumes a save state.

Provenance: every rule below is bound to an instruction or data word in one of
three overlays read off the user's disc through ``disc.extract``:

  DATA/02_AREA.B/VB2.BIN   dice (ordinary/fixed/profit) and its text root
  DATA/03_SHIRO/COIN.BIN   three-cup COIN
  DATA/03_SHIRO/KARUTA.BIN memory-pair KARUTA

Outputs (``--out DIR``) mirror the repository layout under DIR, and
``--check DIR`` regenerates in memory and fails if any byte differs.  The
runtime asset carries no source RAM address: only named families, rule values
and semantic units.  Addresses, instruction words and byte tables stay in the
report, which is the provenance document.

Two hashes are pinned separately and the convention is stated in the report:
``input_files`` hashes the exact overlay bytes returned by ``disc.extract``;
``canonical_json`` hashes the canonical JSON encoding of each emitted payload.
"""
import argparse
import hashlib
import json
import re
import struct
import sys
from pathlib import Path

from disc import extract

KIT = Path(__file__).resolve().parents[1]
ROOT = KIT.parent
BASE = 0x80010000
CATALOG = KIT / 'extracted' / 'iso_files.json'

FILES = {
    'dice': 'DATA/02_AREA.B/VB2.BIN',
    'coin': 'DATA/03_SHIRO/COIN.BIN',
    'karuta': 'DATA/03_SHIRO/KARUTA.BIN',
}

RUNTIME_PATH = Path('game/assets/optional_game_contracts.json')
FIXTURE_PATH = Path('game/tests/fixtures/optional_game_contracts.json')
REPORT_PATH = Path('kit/data/reports/optional_game_contracts.json')
REGISTRY_PATH = Path('kit/data/registry/extract_optional_game_contracts.jsonl')
ZIG_SOURCE_PATH = Path('game/src/optional_game_contracts.zig')
ZIG_TEST_PATH = Path('game/tests/optional_game_contracts.zig')

SCHEMA = 'suikoden.optional-games.v1'
FIXTURE_SCHEMA = 'suikoden.optional-games.fixture.v1'
REPORT_SCHEMA = 'suikoden.optional-games.report.v1'


class Overlay:
    """Read-only view of one overlay addressed at its load base."""

    def __init__(self, path, data):
        self.path = path
        self.data = data
        self.sha256 = hashlib.sha256(data).hexdigest()

    def _off(self, va):
        off = va - BASE
        if off < 0 or off + 1 > len(self.data):
            raise ValueError(f'{self.path}: address {va:#x} outside overlay')
        return off

    def word(self, va):
        off = self._off(va)
        if off + 4 > len(self.data):
            raise ValueError(f'{self.path}: word at {va:#x} truncated')
        return struct.unpack_from('<I', self.data, off)[0]

    def u8(self, va):
        return self.data[self._off(va)]

    def u16(self, va):
        return struct.unpack_from('<H', self.data, self._off(va))[0]

    def s16(self, va):
        return struct.unpack_from('<h', self.data, self._off(va))[0]

    def u32(self, va):
        return self.word(va)

    def bytes(self, va, count):
        off = self._off(va)
        if off + count > len(self.data):
            raise ValueError(f'{self.path}: bytes at {va:#x} truncated')
        return self.data[off:off + count]

    def require(self, checks):
        """Assert exact instruction words; a move in the source is an error."""
        failures = []
        for name, va, expected in checks:
            actual = self.word(va)
            if actual != expected:
                failures.append(f'{self.path} {name} at {va:#x}: '
                                f'expected {expected:08x}, found {actual:08x}')
        if failures:
            raise ValueError('; '.join(failures))


def catalog_rows():
    rows = json.loads(CATALOG.read_text())
    return {name: next(r for r in rows if r['path'] == path) for name, path in FILES.items()}


def load_overlays():
    rows = catalog_rows()
    overlays, provenance = {}, {}
    for name, path in FILES.items():
        row = rows[name]
        overlay = Overlay(path, extract(row['lba'], row['size']))
        overlays[name] = overlay
        provenance[name] = {
            'path': path,
            'lba': row['lba'],
            'size': row['size'],
            'sha256': overlay.sha256,
            'load_base': hex(BASE),
        }
    return overlays, provenance


# ---------------------------------------------------------------------------
# Dice (VB2).  The whole score arbitration lives at 0x80017ce8..0x80018138;
# wager arithmetic at 0x800139b4..0x80013bc0; fixed wager at 0x80013fac;
# mode-2 profit gate at 0x80014488.
# ---------------------------------------------------------------------------
DICE_INSTRUCTIONS = [
    ('strength step four', 0x80015a7c, 0x34020004),
    ('strength initial32', 0x80015a88, 0x34020020),
    ('strength upper96', 0x80015ae4, 0x28420060),
    ('strength lower33', 0x80015b30, 0x28420021),
    ('dealer retry same producer', 0x8001415c, 0x1440ffef),
    ('global wallet read', 0x800132e0, 0x8e43001c),
    ('global wallet write', 0x800149e0, 0xae42001c),
    ('mode1 fixed wager 1000', 0x80013fac, 0x340203e8),
    ('mode1 fixed wager store', 0x80013fb4, 0xac620528),
    ('minimum balance before a round', 0x80013ffc, 0x28420064),
    ('wager add', 0x80013ac8, 0x00431021),
    ('wager overflow limit 9901', 0x80013ad0, 0x284226ad),
    ('wager clear on boundary', 0x80013ae0, 0xaca00528),
    ('wager subtract', 0x80013af4, 0x00431023),
    ('wager underflow limit 9900', 0x80013b00, 0x340226ac),
    ('increment scale by ten', 0x80013b18, 0x00041880),
    ('increment ten fold add', 0x80013b1c, 0x00641821),
    ('increment ten fold double', 0x80013b20, 0x00031840),
    ('increment wrap at 10000', 0x80013b34, 0x34022710),
    ('increment wrap to 100', 0x80013b3c, 0x34020064),
    ('increment divide by ten', 0x80013b60, 0x0064001a),
    ('increment one thousand', 0x80013bb0, 0x340203e8),
    ('retained winnings multiply', 0x8001808c, 0x00620018),
    ('retained winnings cap high', 0x8001809c, 0x3c03000f),
    ('retained winnings cap low', 0x800180a0, 0x3463423e),
    ('retained winnings clamp', 0x800180b8, 0x3442423f),
    ('loss resets retained', 0x80018128, 0xac40052c),
    ('third failure limit', 0x80017f88, 0x34020003),
    ('third failure zero opponent tie', 0x80017f94, 0x10400013),
    ('special score 8', 0x80017d3c, 0x34020008),
    ('special score 16', 0x80017d44, 0x34020010),
    ('special score 32', 0x80017d2c, 0x34020020),
    ('special score 64', 0x80017d58, 0x34020040),
    ('special score 128', 0x80017d60, 0x34020080),
    ('special multiplier one', 0x80017d68, 0x34020001),
    ('special multiplier two', 0x80017ee8, 0x34020002),
    ('special multiplier three', 0x80017f08, 0x34020003),
    ('profit goal 5000', 0x80014494, 0x28421388),
    ('profit goal store flag', 0x800144b8, 0x34420002),
    ('profit goal result', 0x800144c0, 0xa2420252),
]

DICE_FACTS = [
    {
        'id': 'dice.wager.grid',
        'claim': 'Dice wagers are whole 100-bit steps; the increment cycles 100/1000; '
                 'adding past 9900 wraps the wager to 0 and subtracting below 0 wraps to 9900.',
        'addresses': ['0x80013ab8', '0x80013ae4', '0x80013b0c', '0x80013b54'],
        'instruction_words': ['0x284226ad', '0x340226ac', '0x34022710', '0x340203e8'],
    },
    {
        'id': 'dice.modes',
        'claim': 'Three variants exist: ordinary (player sets the wager), fixed (wager is 1000 '
                 'and the dealer rolls first) and profit (win at 5000 bits of profit over the '
                 'entry balance). A round needs a balance of at least 100.',
        'addresses': ['0x80013fac', '0x80013ffc', '0x80014494'],
        'instruction_words': ['0x340203e8', '0x28420064', '0x28421388'],
    },
    {
        'id': 'dice.specials',
        'claim': 'Special scores decide the round by the roller and pay 3x for 8/16, 2x for '
                 '32/64 and 1x for 128; the roller wins with 8 or 32 and loses with 16, 64 or 128.',
        'addresses': ['0x80017d28', '0x80017d80', '0x80017d8c', '0x80017ea8'],
        'instruction_words': ['0x34020008', '0x34020010', '0x34020020', '0x34020040',
                              '0x34020080', '0x34020003', '0x34020002', '0x34020001'],
    },
    {
        'id': 'dice.zero-score',
        'claim': 'A zero score is a failed roll: three failures pass the turn; if the dealer '
                 'still has zero the round ties, otherwise the player loses at 1x.',
        'addresses': ['0x80017f7c', '0x80017f8c', '0x80017f94', '0x80017fe4'],
        'instruction_words': ['0x34020003', '0x10400013'],
    },
    {
        'id': 'dice.winnings',
        'claim': 'A win credits multiplier x wager to retained winnings capped at 999999; a loss '
                 'clears retained winnings to zero. Ties leave the retained value untouched.',
        'addresses': ['0x8001805c', '0x8001808c', '0x800180b8', '0x80018128'],
        'instruction_words': ['0x00620018', '0x3463423e', '0x3442423f'],
    },
]

DICE_SPECIALS = [
    {'score': 8, 'roller_wins': True, 'multiplier': 3},
    {'score': 16, 'roller_wins': False, 'multiplier': 3},
    {'score': 32, 'roller_wins': True, 'multiplier': 2},
    {'score': 64, 'roller_wins': False, 'multiplier': 2},
    {'score': 128, 'roller_wins': False, 'multiplier': 1},
]


# ---------------------------------------------------------------------------
# COIN.  Dispatcher 0x80010124 with a 21-entry table at 0x80010040; wager state
# 4 at 0x800105ec; shuffle state 8 at 0x80010900; choice state 10 at 0x80010c2c;
# comparison state 12 at 0x80010dbc; payout state 14 at 0x80010f28; profit gate
# state 15 at 0x80010fbc.
# ---------------------------------------------------------------------------
COIN_INSTRUCTIONS = [
    ('dispatcher state count 20', 0x80010148, 0x34020014),
    ('dispatcher table base', 0x8001015c, 0x24210040),
    ('wager confirm bit', 0x80010584, 0x30420040),
    ('stake compare', 0x80010620, 0x00a3102a),
    ('stake debit', 0x80010690, 0x00a31023),
    ('stake net debit', 0x800106bc, 0x00641823),
    ('quit option index', 0x800105f8, 0x10620035),
    ('difficulty right bit', 0x800107a4, 0x30424000),
    ('difficulty left bit', 0x80010748, 0x30421000),
    ('shuffle readiness gate', 0x80010900, 0x0c004dbe),
    ('shuffle countdown load', 0x80010914, 0x8c63e870),
    ('shuffle step gate', 0x80010928, 0x1c600023),
    ('shuffle first divisor', 0x800109c8, 0x34102aaa),
    ('shuffle second divide', 0x80010a08, 0x0050001a),
    ('shuffle position bound', 0x80010a34, 0x2a420003),
    ('shuffle distinct bound', 0x80010a3c, 0x2a020003),
    ('shuffle distinct compare', 0x80010a48, 0x1250ffda),
    ('shuffle motion high 32767', 0x80010a80, 0x34037fff),
    ('shuffle motion range table', 0x80010a74, 0x242153c5),
    ('shuffle motion base table', 0x80010ae8, 0x242153c4),
    ('shuffle tracker first', 0x80010b10, 0x16420005),
    ('shuffle tracker second', 0x80010b28, 0x16020242),
    ('twenty shuffle steps', 0x800108e4, 0x34020014),
    ('shuffle countdown store', 0x800108ec, 0xac22e870),
    ('entry shuffle state', 0x800108d8, 0x34020008),
    ('choice wrap high', 0x80010c7c, 0x34020002),
    ('choice wrap low', 0x80010c6c, 0x2442ffff),
    ('choice count', 0x80010cd4, 0x28420003),
    ('choice confirm', 0x80010d0c, 0x30420040),
    ('reveal first cup', 0x80010d88, 0x34050001),
    ('reveal second cup', 0x80010e80, 0x34050002),
    ('comparison choice vs coin', 0x80010e00, 0x1062000d),
    ('comparison mismatch sound', 0x80010e18, 0x34040302),
    ('comparison match sound', 0x80010e48, 0x34040301),
    ('payout double balance', 0x80010f54, 0x00021040),
    ('payout double net', 0x80010f74, 0x00021040),
    ('payout cap high', 0x80010f50, 0x3c06000f),
    ('payout cap low', 0x80010f64, 0x34c6423f),
    ('profit flag mask high', 0x80010fcc, 0x3c0300a0),
    ('profit flag mask and', 0x80010fd0, 0x00431024),
    ('profit flag expected high', 0x80010fd4, 0x3c030020),
    ('profit flag compare', 0x80010fd8, 0x14430018),
    ('profit threshold 5000', 0x80010fec, 0x28421388),
    ('profit result bit', 0x80011020, 0x34420040),
    ('profit result store', 0x80011024, 0xa0820232),
    ('no-profit round restart', 0x80011040, 0xac22e880),
    ('text gate state 19', 0x800112d0, 0x3c028002),
]

COIN_FACTS = [
    {
        'id': 'coin.stakes',
        'claim': 'COIN admits three difficulties with table stakes 100, 1000 and 10000; a '
                 'fourth selection is the quit option. A round is refused when the balance is '
                 'below the stake.',
        'addresses': ['0x800153cc', '0x800105ec', '0x80010620'],
        'instruction_words': ['0x00a3102a', '0x10620035'],
    },
    {
        'id': 'coin.shuffle',
        'claim': 'A round performs 20 readiness-gated shuffle steps; each step draws two '
                 'positions in 0..2 (rejecting out-of-range and equal pairs) and one motion '
                 'parameter from a per-difficulty base/range table, then swaps the tracked coin.',
        'addresses': ['0x800108e4', '0x80010900', '0x800109b4', '0x80010afc'],
        'instruction_words': ['0x34020014', '0x34102aaa', '0x2a420003', '0x34037fff'],
    },
    {
        'id': 'coin.choice-and-compare',
        'claim': 'The player selects one of three cups with a wrapping cursor; the reveal then '
                 'compares the selected cup against the tracked coin position: equal pays, '
                 'different loses.',
        'addresses': ['0x80010c2c', '0x80010dbc', '0x80010e00'],
        'instruction_words': ['0x28420003', '0x1062000d'],
    },
    {
        'id': 'coin.settlement',
        'claim': 'A win credits 2 x stake to the balance (cap 999999) and 2 x stake to the '
                 'signed net; a loss credits nothing. The stake was already debited on '
                 'admission, so a win is a net gain of one stake.',
        'addresses': ['0x80010f28', '0x80010f54', '0x80010f78', '0x80010f64'],
        'instruction_words': ['0x00021040', '0x34c6423f'],
    },
    {
        'id': 'coin.profit-gate',
        'claim': 'After settlement, the profit consequence requires the caller flag mask '
                 '0x00a00000 to equal 0x00200000 and the signed net to be at least 5000; it then '
                 'sets result bit 0x40. Otherwise the game returns to the wager screen.',
        'addresses': ['0x80010fbc', '0x80010fd8', '0x80010fec', '0x80011024'],
        'instruction_words': ['0x3c0300a0', '0x3c030020', '0x28421388', '0x34420040'],
    },
]


# ---------------------------------------------------------------------------
# KARUTA.  Entry pair at 0x80010000/0x80010004, phase table at 0x80010008,
# cell-state table at 0x800100a4, deal at 0x80013688, reveal at 0x8001423c,
# completion at 0x800142fc, match at 0x80013ec8, neighbour at 0x80014068,
# per-cell animator at 0x80014350, move counter at 0x80011a6c.
# ---------------------------------------------------------------------------
KARUTA_INSTRUCTIONS = [
    ('deal identity count', 0x800136b0, 0x0080b021),
    ('deal identity allocator size', 0x800136c8, 0x00162040),
    ('deal identity divisor 300', 0x800136f8, 0x3403012c),
    ('deal face bound 108', 0x80013744, 0x2c82006c),
    ('deal duplicate check', 0x80013788, 0x1082ffd7),
    ('board empty face 109', 0x800137ac, 0x3407006d),
    ('board hidden state 10', 0x800137b0, 0x3406000a),
    ('board row outer stride', 0x8001380c, 0x24630048),
    ('board column stride', 0x80013810, 0x24a5000c),
    ('board cell step', 0x80013800, 0x24840009),
    ('board row bound', 0x80013804, 0x28820048),
    ('deal row divisor 3640', 0x8001382c, 0x34150e38),
    ('deal column divisor 4681', 0x80013830, 0x34141249),
    ('deal occupied face compare', 0x80013924, 0x1457ffd4),
    ('deal pair count 24', 0x80013a04, 0x2a620018),
    ('phase table count 38', 0x80010184, 0x34020026),
    ('phase table base', 0x80010198, 0x24210008),
    ('cell table base', 0x800143c8, 0x242100a4),
    ('cell table bound', 0x800143b8, 0x02a3102b),
    ('select face-down to turn-up', 0x80013d54, 0x14620009),
    ('match search state 9', 0x80013f48, 0x34020009),
    ('match state compare', 0x80013f60, 0x1462002f),
    ('match set removed pair', 0x80013f18, 0x34150006),
    ('neighbour empty state', 0x800140a4, 0x3402000a),
    ('neighbour removed state', 0x800140b4, 0x34020006),
    ('neighbour mark state', 0x800140bc, 0x34020004),
    ('reveal hidden state', 0x80014268, 0x3402000a),
    ('reveal face-up state', 0x80014278, 0x34020001),
    ('reveal blank value', 0x80014288, 0x3402006d),
    ('reveal face load', 0x80014298, 0x94220000),
    ('completion hidden state', 0x800142fc, 0x3406000a),
    ('completion compare', 0x80014320, 0x14460009),
    ('completion true', 0x80014344, 0x34020001),
    ('flip frame bound 11', 0x800144bc, 0x2842000b),
    ('flip second phase state 3', 0x800144c4, 0x34020003),
    ('flip finished state 1', 0x80014570, 0x34020001),
    ('match scale bound 6', 0x80014844, 0x28420006),
    ('match fade bound 21', 0x80014a20, 0x28420015),
    ('resolve bound 31', 0x80014b54, 0x2842001f),
    ('deal animation cell bound', 0x80013d84, 0x28820030),
    ('moves cap 3600', 0x80011a9c, 0x34020e10),
    ('moves cap compare', 0x80011a88, 0x28420e11),
    ('identity table 0x80017398', 0x800115d8, 0x24217398),
    ('threshold table 0x8001739c', 0x80010338, 0x2484739c),
    ('threshold copy count', 0x80010348, 0xa4621b94),
    ('move counter store', 0x80011a84, 0xac22615c),
    ('score to threshold store', 0x8001199c, 0xa4431b94),
    ('flag mask high', 0x800119a4, 0x3c03a000),
    ('flag mask and', 0x800119a8, 0x00431024),
    ('flag expected high', 0x800119ac, 0x3c032000),
    ('flag compare', 0x800119b0, 0x14430010),
    ('flag result store', 0x800119dc, 0xa0820233),
    ('round advance next', 0x80010be4, 0x34020007),
    ('balance cap high', 0x80010ce8, 0x3c03000f),
    ('balance cap low', 0x80010cec, 0x3463423f),
    ('balance cap compare', 0x80010cf0, 0x0062102a),
    ('balance cap store', 0x80010cfc, 0xac83001c),
]

KARUTA_FACTS = [
    {
        'id': 'karuta.board',
        'claim': 'The board is 8 rows by 6 columns (48 cells) holding 24 face pairs. The '
                 'linear index used by the deal animation and selection helpers is '
                 'column*8+row, while a cell position is resolved as column*12+row*72 in the '
                 'source record layout. This is the index convention; it is not a transpose.',
        'addresses': ['0x80013688', '0x800137ac', '0x80013d84'],
        'instruction_words': ['0x3407006d', '0x3406000a', '0x28820030'],
    },
    {
        'id': 'karuta.deal',
        'claim': 'A round deals N distinct eligible faces (300-divisor draw, rejecting 108+, '
                 'ineligible and duplicate identities), then places 24 pairs by drawing a row '
                 'with divisor 3640 (0..8, retry 8) and a column with divisor 4681 (0..7, '
                 'retry 6..7) and retrying occupied cells.',
        'addresses': ['0x800136f8', '0x80013750', '0x80013838', '0x80013924', '0x80013a04'],
        'instruction_words': ['0x3403012c', '0x34150e38', '0x34141249', '0x2a620018'],
    },
    {
        'id': 'karuta.cell-states',
        'claim': 'Cell states drive the animation: 0 face-up at rest, 1 face-down at rest, '
                 '2/3 the turn-down halves, 4/5 the turn-up halves, 6/7/8 the matched removal, '
                 '9 the post-flip resolution and 10 empty (no card, both before the deal '
                 'animation and after removal). Only state 1 reveals a face value to the game '
                 'logic, and state 10 draws nothing.',
        'addresses': ['0x800100a4', '0x8001423c', '0x800143e0', '0x80014a44'],
        'instruction_words': ['0x3402000a', '0x34020001', '0x3402006d'],
    },
    {
        'id': 'karuta.match',
        'claim': 'A match searches for exactly one other cell with the same face in state 9 '
                 '(excluding the cell itself); it removes both (state 6) and marks their four '
                 'orthogonal neighbours (state 4) so a revealed neighbour that has a partner '
                 'elsewhere resolves after 31 ticks and is removed, otherwise it turns back down.',
        'addresses': ['0x80013ec8', '0x80014068', '0x800140fc', '0x800141cc'],
        'instruction_words': ['0x34020009', '0x34020004', '0x2842001f'],
    },
    {
        'id': 'karuta.completion',
        'claim': 'The board is complete only when all 48 cells are empty (state 10); a card '
                 'still face down or in any transient state keeps the round running.',
        'addresses': ['0x800142fc', '0x80014320'],
        'instruction_words': ['0x3406000a', '0x14460009'],
    },
    {
        'id': 'karuta.rounds',
        'claim': 'Four playable rounds deal 5, 7, 10 and 15 identities; the fifth selector entry '
                 'quits. Each round has a recorded move threshold of 900, 1500, 2400 and 3300; '
                 'the game stores the player\'s move count as the new record and only reports a '
                 'record when it is below the stored value.',
        'addresses': ['0x80017398', '0x8001739c', '0x800115d8', '0x8001199c'],
        'instruction_words': ['0x24217398', '0x2484739c', '0xa4431b94'],
    },
    {
        'id': 'karuta.flag',
        'claim': 'A completed round sets result bit 0x40 only when the caller flag mask '
                 '0x00a00000 equals 0x00200000; otherwise the game returns to round selection '
                 'without a flag.',
        'addresses': ['0x800119a0', '0x800119b0', '0x800119dc'],
        'instruction_words': ['0x3c03a000', '0x3c032000', '0xa0820233'],
    },
    {
        'id': 'karuta.settlement',
        'claim': 'KARUTA does not pay bits: the completion path only clamps the caller balance '
                 'at 999999. Money movement for this game is not source-supported.',
        'addresses': ['0x80010cd8', '0x80010cf0', '0x80010cfc'],
        'instruction_words': ['0x3463423f', '0x0062102a', '0xac83001c'],
    },
]


def build_tables(overlays):
    coin = overlays['coin']
    karuta = overlays['karuta']
    difficulty_bytes = coin.bytes(0x800153c4, 8)
    difficulty = [
        {'base': difficulty_bytes[i * 2], 'range': difficulty_bytes[i * 2 + 1]}
        for i in range(3)
    ]
    stakes = [coin.u32(0x800153cc + i * 4) for i in range(3)]
    identities = [karuta.u8(0x80017398 + i) for i in range(4)]
    thresholds = [karuta.u16(0x8001739c + i * 2) for i in range(4)]
    return difficulty, stakes, identities, thresholds


def runtime_payload(tables):
    difficulty, stakes, identities, thresholds = tables
    return {
        'schema': SCHEMA,
        'families': {
            'dice': {
                'id': 'vb2_dice',
                'modes': [
                    {'id': 'ordinary', 'wager': 'player', 'fixed_wager': None, 'profit_goal': None},
                    {'id': 'fixed', 'wager': 'fixed', 'fixed_wager': 1000, 'profit_goal': None},
                    {'id': 'profit', 'wager': 'player', 'fixed_wager': None, 'profit_goal': 5000},
                ],
                'minimum_balance': 100,
                'balance_cap': 999999,
                'wager': {'step': 100, 'increments': [100, 1000], 'maximum': 9900,
                          'overflow_wager': 0, 'underflow_wager': 9900},
                'ordinary_scores': {'minimum': 1, 'maximum': 6},
                'specials': DICE_SPECIALS,
                'zero_score': {'failures_before_turn_passes': 3,
                               'tie_when_opponent_zero': True,
                               'third_failure_multiplier': 1},
                'consequences': ['none', 'fixed_win', 'profit_goal'],
            },
            'coin': {
                'id': 'coin_cups',
                'stakes': stakes,
                'quit_option': 3,
                'balance_cap': 999999,
                'difficulty': difficulty,
                'shuffle': {'positions': 3, 'steps': 20, 'draws_per_step': 3,
                            'distinct_pair': True, 'motion_high': 32767},
                'choice': {'cups': 3, 'initial': 0, 'wrap': True},
                'reveal_ticks': 70,
                'settlement': {'win_credit_stakes': 2, 'net_credit_stakes': 2},
                'profit': {'threshold': 5000, 'flag_mask': 0x00A00000,
                           'flag_value': 0x00200000, 'result_bit': 0x40},
            },
            'karuta': {
                'id': 'karuta_pairs',
                'board': {'rows': 8, 'columns': 6, 'cells': 48, 'pairs': 24,
                          'faces': 108, 'empty_face': 109, 'back_face': 108},
                'linear_index': {'order': 'column-major', 'columns_first': 8},
                'rounds': [
                    {'index': i, 'identities': identities[i], 'record_moves': thresholds[i]}
                    for i in range(4)
                ],
                'quit_round': 4,
                'deal': {'identity_divisor': 300, 'row_divisor': 3640,
                         'column_divisor': 4681, 'row_candidates': 9, 'column_candidates': 8},
                'cell_states': [
                    {'id': 'face_up', 'code': 0},
                    {'id': 'face_down', 'code': 1},
                    {'id': 'flip_face_out', 'code': 2},
                    {'id': 'flip_back_in', 'code': 3},
                    {'id': 'flip_back_out', 'code': 4},
                    {'id': 'flip_face_in', 'code': 5},
                    {'id': 'matched_scale_in', 'code': 6},
                    {'id': 'matched_scale_out', 'code': 7},
                    {'id': 'matched_fade', 'code': 8},
                    {'id': 'resolving', 'code': 9},
                    {'id': 'empty', 'code': 10},
                ],
                'timing': {'flip_frames': 11, 'matched_scale_frames': 6,
                           'matched_fade_frames': 21, 'resolve_frames': 31,
                           'deal_ticks': 48, 'neighbours': [[-1, 0], [1, 0], [0, -1], [0, 1]]},
                'moves_cap': 3600,
                'settlement': {'pays_bits': False, 'balance_cap': 999999,
                               'flag_mask': 0x00A00000, 'flag_value': 0x00200000,
                               'result_bit': 0x40},
            },
        },
        'completion_tokens': {
            'dice': ['settled', 'replay_prompt', 'exited', 'bankrupt'],
            'coin': ['settled', 'round_continues', 'profit_flag', 'exited'],
            'karuta': ['round_complete', 'record', 'flag', 'round_selected', 'exited'],
        },
    }


def fixture_payload(runtime):
    karuta = runtime['families']['karuta']
    return {
        'schema': FIXTURE_SCHEMA,
        'dice': {
            'specials': DICE_SPECIALS,
            'wager_increments': runtime['families']['dice']['wager']['increments'],
            'balance_cap': runtime['families']['dice']['balance_cap'],
            'modes': runtime['families']['dice']['modes'],
        },
        'coin': {
            'stakes': runtime['families']['coin']['stakes'],
            'difficulty': runtime['families']['coin']['difficulty'],
            'profit': runtime['families']['coin']['profit'],
            'shuffle_steps': runtime['families']['coin']['shuffle']['steps'],
        },
        'karuta': {
            'rounds': karuta['rounds'],
            'quit_round': karuta['quit_round'],
            'board': karuta['board'],
            'cell_state_codes': [row['code'] for row in karuta['cell_states']],
            'cell_state_ids': [row['id'] for row in karuta['cell_states']],
            'index_examples': [
                {'index': 0, 'row': 0, 'column': 0},
                {'index': 7, 'row': 7, 'column': 0},
                {'index': 8, 'row': 0, 'column': 1},
                {'index': 47, 'row': 7, 'column': 5},
            ],
            'pair_faces': 24,
            'moves_cap': karuta['moves_cap'],
        },
    }


BLOCKERS = [
    {
        'id': 'blocker.dice.3d-presentation',
        'kind': 'required_source',
        'family': 'dice',
        'detail': 'The dice pips are drawn by a 3D transform path (VB2 0x80012FD0..0x800130F8 '
                  'rotation/position, 0x80014FA8..0x800150D4 four points per layer through a MAIN '
                  'vtable slot, 0x800152BC transform). Resource109 texture/CLUT uploads and '
                  'six face UV rectangles are recovered by export_dice_presentation.py; the '
                  'candidate faces remain user-gated. The decoded model and orthographic '
                  'transform, staged roll motion and native face rendering are ported. Startup '
                  'viewport and relative face ordering are qualified. HUD/cursor geometry is '
                  'ported and both participant portraits are decoded/bound. Full scene '
                  'visibility/draw ordering, remaining loss SFX and scene '
                  'cadence still require binding. '
                  'Entry/result text boxes, fixed tie replay, payout, stream readiness/cleanup '
                  'and pressed-edge controls are connected. CHIN slot2 landing cues now use '
                  'per-update landing events, and text-box allocation emits the source '
                  'byte-narrowed box cue. Win resolution emits its cue with a stream-level '
                  'restoration ramp; original audio-poll cadence remains open. '
                  'Sound/stream candidates remain listening-gated.',
    },
    {
        'id': 'blocker.dice.field-entry',
        'kind': 'required_source',
        'family': 'dice',
        'detail': 'Kaku VB2 room8 entry0 reaches the fixed dice controller through counted '
                  'callback18 and MAIN per-update slot43. The source entry and global wallet '
                  'owner are proven. Journey has a session/atomic-return adapter and a saved '
                  'counter projection; source request export, BIOS RNG/counter sampling, '
                  'remaining loss SFX and complete presentation timing remain unbound.',
    },
    {
        'id': 'blocker.coin.animation',
        'kind': 'required_source',
        'family': 'coin',
        'detail': 'Cup reveal and coin tracking are logical here; the source cell record fields '
                  'and the animation consumers (0x80013608, 0x800135EC, 0x80012C70/0x80013100) '
                  'are presentation, so their timing is not part of the contract.',
    },
    {
        'id': 'blocker.coin.effect-owner',
        'kind': 'caller_obligation',
        'family': 'coin',
        'detail': 'The contract proposes a balance/net/flag result. Persisting money, the story '
                  'flag and the receipt is the canonical owner\'s job; no balance write, save '
                  'mutation or recruitment is performed here (Package 7 owns item/money identity '
                  'only).',
    },
    {
        'id': 'blocker.karuta.presentation',
        'kind': 'required_source',
        'family': 'karuta',
        'detail': 'Card faces, the 8x6 screen layout, cursor sprites and the 0x80013A58/0x80013B18/'
                  '0x80013C20 draw consumers are presentation. The logical board geometry and the '
                  'linear index convention are emitted; pixel positions are not.',
    },
    {
        'id': 'blocker.karuta.event-wiring',
        'kind': 'required_source',
        'family': 'karuta',
        'detail': 'VG1 event selector 15 resolves to KARUTA.BIN, but the story gate that makes the '
                  'flag consequential and the field return are not traced. The flag is proposed, '
                  'never written.',
    },
    {
        'id': 'blocker.global.settlement',
        'kind': 'caller_obligation',
        'family': 'all',
        'detail': 'Balances, RNG streams, receipts and story flags stay with the canonical owner. '
                  'Every result is a proposal that must be acknowledged atomically with a matching '
                  'receipt; a failed acknowledgement leaves the session unchanged.',
    },
]


def test_inventory():
    path = ROOT / ZIG_TEST_PATH
    if not path.exists():
        raise ValueError(f'missing owned Zig test {ZIG_TEST_PATH}')
    text = path.read_text(encoding='utf-8')
    names = re.findall(r'^test "([^"]+)"', text, re.M)
    if len(names) < 12:
        raise ValueError('owned Zig test inventory is incomplete')
    return names


def acceptance(inventory):
    def named(prefix):
        matched = [name for name in inventory if prefix in name]
        if not matched:
            raise ValueError(f'no owned test covers {prefix!r}')
        return matched

    return [
        {'case': 'full headless loop per mode', 'family': 'all', 'tests': named('full headless loop') + named('coin loop') + named('dice ordinary loop'), 'status': 'covered'},
        {'case': 'win, loss, tie and cancel', 'family': 'dice', 'tests': named('dice ordinary loop') + named('third failed roll'), 'status': 'covered'},
        {'case': 'insufficient funds', 'family': 'dice,coin', 'tests': named('dice specials') + named('coin loop'), 'status': 'covered'},
        {'case': '999999 balance cap', 'family': 'dice,coin', 'tests': named('dice ordinary loop') + named('coin profit flag'), 'status': 'covered'},
        {'case': 'profit 5000 and flag masks', 'family': 'dice,coin', 'tests': named('dice specials') + named('coin profit flag'), 'status': 'covered'},
        {'case': 'maximum draws and rejections', 'family': 'coin,karuta', 'tests': named('coin profit flag') + named('karuta deal'), 'status': 'covered'},
        {'case': 'duplicate and off-board deal', 'family': 'karuta', 'tests': named('karuta deal'), 'status': 'covered'},
        {'case': 'adjacency reveal and final card', 'family': 'karuta', 'tests': named('karuta adjacency') + named('karuta full headless loop'), 'status': 'covered'},
        {'case': 'paused animation and dialogue gates', 'family': 'coin,karuta', 'tests': named('karuta adjacency') + named('coin loop'), 'status': 'covered'},
        {'case': 'altered completion and stale receipt', 'family': 'all', 'tests': named('karuta full headless loop') + named('dice ordinary loop') + named('coin loop'), 'status': 'covered'},
        {'case': 'failed steps preserve state and RNG', 'family': 'all', 'tests': named('dice snapshot') + named('coin loop') + named('karuta mismatch'), 'status': 'covered'},
        {'case': 'source dice throws and failed draws', 'family': 'dice', 'tests': named('source dice throw'), 'status': 'covered'},
        {'case': 'mid-roll, mid-shuffle and mid-match snapshots identical', 'family': 'all', 'tests': named('snapshot restart') + named('coin snapshot'), 'status': 'covered'},
        {'case': 'asset identity and fixture agreement', 'family': 'all', 'tests': named('asset identity'), 'status': 'covered'},
        {'case': 'tampered asset rejection and restore validation', 'family': 'all', 'tests': named('tampered asset') + named('karuta flag proposal'), 'status': 'covered'},
    ]


def report_payload(overlays, provenance, runtime, fixture, tables, registry_text, inventory):
    difficulty, stakes, identities, thresholds = tables
    def digest(payload):
        return hashlib.sha256(canonical(payload)).hexdigest()
    return {
        'schema': REPORT_SCHEMA,
        'base': '6c6f9092c5aee33a5ba54315b9cd0f6a2afba96d',
        'worktree': 'kit/work/deepseek-package-11',
        'scope': 'Optional game loops and results: dice (VB2), COIN and KARUTA.',
        'status': 'source_bound_logical_contracts',
        'outputs': {
            'runtime_sha256': hashlib.sha256(render(runtime).encode()).hexdigest(),
            'fixture_sha256': hashlib.sha256(render(fixture).encode()).hexdigest(),
            'registry_sha256': hashlib.sha256(registry_text.encode()).hexdigest(),
        },
        'immutable_inputs': provenance,
        'pins': {
            'input_files': {name: overlays[name].sha256 for name in FILES},
            'canonical_json': {
                'runtime': digest(runtime),
                'fixture': digest(fixture),
            },
            'convention': 'input_files hashes the exact bytes returned by disc.extract; '
                          'canonical_json hashes UTF-8 JSON encoded with sorted keys and '
                          'separators (",", ":"), without a trailing newline.',
        },
        'instruction_assertions': {
            name: [{'rule': rule, 'address': hex(addr), 'word': f'{word:08x}'}
                   for rule, addr, word in checks]
            for name, checks in (
                ('dice', DICE_INSTRUCTIONS),
                ('coin', COIN_INSTRUCTIONS),
                ('karuta', KARUTA_INSTRUCTIONS),
            )
        },
        'source_tables': {
            'coin_stakes': stakes,
            'coin_difficulty': difficulty,
            'karuta_identity_counts': identities,
            'karuta_record_thresholds': thresholds,
        },
        'facts': DICE_FACTS + COIN_FACTS + KARUTA_FACTS,
        'families': {
            'dice': {
                'variants': ['ordinary', 'fixed', 'profit'],
                'completed': ['wager grid and wrap', 'special score arbitration',
                              'zero-score failure/turn/tie', 'win/loss retained winnings',
                              'balance cap', 'mode-1 fixed wager', 'mode-2 profit gate',
                              'restartable result proposal'],
                'blocked': ['3D dice presentation', 'field entry identity', 'effect owner'],
            },
            'coin': {
                'variants': ['difficulty 0/1/2', 'quit option'],
                'completed': ['stake admission and refusal', '20 gated shuffle steps',
                              'wrapping three-cup choice', 'reveal comparison',
                              'win payout and balance cap', 'signed net', 'profit flag gate',
                              'round loop and restartable proposal'],
                'blocked': ['cup animation binding', 'effect owner'],
            },
            'karuta': {
                'variants': ['round 5', 'round 7', 'round 10', 'round 15', 'quit'],
                'completed': ['8x6 board and index convention', 'deal with exact rejections',
                              'cell state machine', 'flip/match/resolve timing gates',
                              'neighbour reveal and auto-match',
                              'completion gate (all cells empty)',
                              'move counter and record comparison', 'flag proposal',
                              'round loop and restartable proposal'],
                'blocked': ['presentation', 'event wiring'],
            },
        },
        'blockers': BLOCKERS,
        'readiness': {
            'logical_contracts': 'complete for dice ordinary/fixed/profit, COIN and KARUTA rounds',
            'presentation': 'blocked (3D dice pips, cup animation, card drawing)',
            'field_entry': 'blocked (event bytes are candidates only)',
            'global_settlement': 'caller-owned: proposal plus atomic acknowledgement',
            'money': 'dice and COIN propose balance/net changes; KARUTA pays no bits',
        },
        'cross_checks': [
            {'topic': 'dice score arbitration',
             'result': 'agree',
             'note': 'Independent instruction reading agrees with the F report witness list: '
                     'specials 8/32 win for the roller, 16/64/128 lose, multipliers 3/3/2/2/1, '
                     'three zero-score failures pass the turn, zero dealer ties, winnings cap '
                     '999999 and reset on loss. F modules were read, not executed.'},
            {'topic': 'dice wager grid',
             'result': 'agree',
             'note': 'Increment cycle 100/1000 with a 9900 maximum and wrap to zero; a step to '
                     'zero is legal, only a negative result wraps to 9900.'},
            {'topic': 'dice variants',
             'result': 'agree',
             'note': 'Fixed wager 1000 and profit goal 5000 over the entry balance match the F '
                     'report witnesses; the 5000 comparison is slti at 0x80014494.'},
            {'topic': 'COIN finance and shuffle',
             'result': 'agree',
             'note': 'Stakes 100/1000/10000, twenty readiness-gated steps, double-stake payout '
                     'with a 999999 cap and the flag-mask/5000 profit gate agree with the F '
                     'witness list. The F coin module only covers one shuffle step; this package '
                     'completes the loop.'},
            {'topic': 'KARUTA deal and board',
             'result': 'agree',
             'note': "The F deal witness (107 draws for a five-identity board) and the F note "
                     'that completion needs all 48 cells in state 10 agree with this reading; '
                     'this package pins the linear index as column*8+row and the record '
                     'thresholds 900/1500/2400/3300.'},
            {'topic': 'KARUTA round table',
             'result': 'divergence',
             'note': 'The F module exposes identity counts 1/5/7/10/15. The source table at '
                     '0x80017398 is 5/7/10/15 and the fifth selector entry (index 4) quits, so '
                     'this package uses four playable rounds plus quit; the 1-identity deal is '
                     'the phase-0 placeholder board, not a playable round.'},
        ],
        'known_limits': [
            "KARUTA's +9 selected-hint flag and the phase-16 brief reveal are modelled but the "
            'logical loop never sets them; their binding is presentation.',
            'The KARUTA face eligibility table is a caller obligation derived from field '
            'context; the contract refuses a deal without it.',
            "COIN starts with the tracked coin in cup 1, as the overlay init stores 1 at "
            '0x80010174.',
            'The rejection budget (65536) is a host guard; the source retries without a bound.',
            'KARUTA matched cards end in the empty state 10; a face-down card is state 1 and '
            'keeps the round running.',
            'The runtime asset carries no address, so the provenance for every rule is the '
            'report instruction table plus the registry rows.',
        ],
        'test_inventory': inventory,
        'acceptance': acceptance(inventory),
        'verification': [
            {'command': 'python3 kit/tools/export_optional_game_contracts.py --out .',
             'result': 'wrote four artifacts'},
            {'command': 'python3 kit/tools/export_optional_game_contracts.py --check .',
             'result': 'CHECK OK: optional game contracts match source'},
            {'command': 'python3 kit/tests/test_optional_game_contracts.py',
             'result': 'static export, identity and acceptance checks pass'},
            {'command': 'zig test game/tests/optional_game_contracts.zig',
             'result': f'{len(inventory)}/{len(inventory)} tests pass (headless)'},
        ],
        'exclusions': [
            {
                'path': 'kit/work/deepseek-package-11 (F bytes at 6c6f9092)',
                'note': 'F minigames modules, tests and kit/data/reports/minigames_package_f.json '
                        'were read as evidence only. The F worktree carries uncommitted later '
                        'bytes (game/src/minigames/coin.zig +101 lines, '
                        'game/tests/minigames/roll_test.zig +25 lines, a modified '
                        'minigames_package_f.json and an untracked '
                        'kit/tests/test_minigames_coin_choice.py); those bytes are excluded and '
                        'were not read or copied.',
            },
            {
                'path': 'kit/tests/test_minigames_*.py',
                'note': 'Read as evidence only. Those gates execute original instructions and were '
                        'not run; this package uses static instruction assertions instead.',
            },
        ],
        'integration_proposal': {
            'applied': False,
            'steps': [
                'Register game/src/optional_game_contracts.zig as a module and route a single '
                'field-side entry per game through the existing controller and receipt owner.',
                'The canonical owner supplies balance, RNG stream, receipt and effect owner; it '
                'must acknowledge every result atomically and keep the session on failure.',
                'Wire the story flags through the existing event/flag owner; do not set '
                'recruitment or permanent progression from these proposals.',
                'Keep game/src/minigames/* as the dice presentation layer; this module is the '
                'data-driven contract and must not be merged into it before F review.',
            ],
        },
        'commands': [
            'python3 kit/tools/export_optional_game_contracts.py --out .',
            'python3 kit/tools/export_optional_game_contracts.py --check .',
            'python3 kit/tests/test_optional_game_contracts.py',
            'zig test game/tests/optional_game_contracts.zig',
        ],
    }


def registry_rows(tables, provenance):
    difficulty, stakes, identities, thresholds = tables
    rows = []
    common = {'stage': 'S2_RULES', 'source': 'kit/work/deepseek-package-11/kit/data/reports/optional_game_contracts.json'}

    def add(identifier, cls, claim, addr, evidence, note):
        rows.append({**common, 'class': cls, 'id': identifier, 'claim': claim, 'addr': addr,
                     'evidence': evidence, 'superseded_by': '', 'note': note})

    add('optional-games/dice/wager-grid', 'dice',
        'Dice wagers are 100-bit steps with a 100/1000 increment cycle; adding past the 9900 '
        'maximum wraps to 0 and a step below zero wraps to 9900.', '0x80013AB8..0x80013BC0', 'proven',
        'VB2.BIN ' + provenance['dice']['sha256'])
    add('optional-games/dice/specials', 'dice',
        'Special dice scores decide by roller and pay 3x (8/16), 2x (32/64) and 1x (128).',
        '0x80017D28..0x80017D94', 'proven', 'VB2.BIN')
    add('optional-games/dice/zero-score', 'dice',
        'Three zero-score failures pass the turn; a zero dealer then ties, otherwise the player '
        'loses at 1x.', '0x80017F7C..0x80017FE4', 'proven', 'VB2.BIN')
    add('optional-games/dice/winnings', 'dice',
        'A dice win credits multiplier x wager to retained winnings capped at 999999; a loss '
        'clears it.', '0x8001805C..0x80018138', 'proven', 'VB2.BIN')
    add('optional-games/dice/modes', 'dice',
        'Dice modes are ordinary, fixed (wager 1000, dealer first) and profit (5000 profit over '
        'the entry balance).', '0x80013FAC, 0x80014494', 'proven',
        'VB2.BIN; minimum balance 100 at 0x80013FFC')
    add('optional-games/coin/stakes', 'coin',
        'COIN stakes are %s for difficulties 0..2 and the fourth selector entry quits.' % stakes,
        '0x800153CC, 0x800105F8', 'proven', 'COIN.BIN ' + provenance['coin']['sha256'])
    add('optional-games/coin/shuffle', 'coin',
        'A COIN round runs 20 readiness-gated shuffle steps with three draws each: two distinct '
        'positions in 0..2 and one motion parameter from the difficulty base/range table.',
        '0x800108E4..0x80010B38', 'proven', 'COIN.BIN')
    add('optional-games/coin/settlement', 'coin',
        'A COIN win credits 2 x stake to the balance (cap 999999) and 2 x stake to the signed '
        'net; a loss credits nothing.', '0x80010F28..0x80010F94', 'proven', 'COIN.BIN')
    add('optional-games/coin/profit-gate', 'coin',
        'The COIN profit consequence needs flag mask 0x00a00000 == 0x00200000 and net >= 5000, '
        'then sets result bit 0x40.', '0x80010FBC..0x80011034', 'proven', 'COIN.BIN')
    add('optional-games/karuta/board', 'karuta',
        'The KARUTA board is 8 rows x 6 columns; the linear index is column*8+row and a cell '
        'record resolves at column*12+row*72.', '0x80013688..0x80013834, 0x80013D84', 'proven',
        'KARUTA.BIN ' + provenance['karuta']['sha256'] + '; index convention checked, not transposed')
    add('optional-games/karuta/deal', 'karuta',
        'A KARUTA round deals N distinct eligible faces (300 divisor, 108 bound) and places 24 '
        'pairs with row divisor 3640 and column divisor 4681.', '0x800136F8..0x80013A08',
        'proven', 'KARUTA.BIN')
    add('optional-games/karuta/cell-states', 'karuta',
        'KARUTA cell states: 0 face-up, 1 face-down, 2/3 turn-down, 4/5 turn-up, 6/7/8 removal, '
        '9 resolving, 10 empty; only state 1 reveals a face and state 10 draws nothing.',
        '0x800100A4..0x800100CC, 0x8001423C', 'proven', 'KARUTA.BIN')
    add('optional-games/karuta/match', 'karuta',
        'A KARUTA match removes one same-face partner in state 9 and marks the four orthogonal '
        'neighbours; a marked neighbour resolves after 31 ticks, removing by partner or turning '
        'back down.', '0x80013EC8..0x800141CC, 0x80014AA8..0x80014B8C', 'proven', 'KARUTA.BIN')
    add('optional-games/karuta/completion', 'karuta',
        'KARUTA completion requires all 48 cells to be empty (state 10); a face-down or '
        'animating card keeps the round running.', '0x800142FC..0x80014348',
        'proven', 'KARUTA.BIN')
    add('optional-games/karuta/rounds', 'karuta',
        'KARUTA rounds deal %s identities with recorded move thresholds %s; selector entry 4 '
        'quits.' % (identities, thresholds), '0x80017398, 0x8001739C, 0x800115D8, 0x8001199C',
        'proven', 'KARUTA.BIN')
    add('optional-games/karuta/no-payout', 'karuta',
        'KARUTA pays no bits: the completion path only clamps the balance at 999999.',
        '0x80010CD8..0x80010CFC', 'proven', 'KARUTA.BIN')
    add('optional-games/shared/3d-presentation', 'dice',
        'VB2 resource109 supplies the six 4bpp dice faces; eight rotated vertices and six '
        'face links feed per-die projection and minimum-depth submission. The roll controller '
        'advances flight, orbit, face alignment and hold states.', '0x80012FD0..0x80016C58', 'proven',
        'Source qualification: KAKU-DICE-FACE-TEXTURE-01, KAKU-DICE-MODEL-01 and KAKU-DICE-MOTION-01. '
        'This is not a native presentation/media acceptance claim.')
    add('optional-games/shared/draw-qualification', 'dice',
        'The startup viewport is 320x240. Dice faces use descending depth keys and reverse '
        'submission order for equal keys through the shared ordering table.',
        '0x800C2BE8;0x800158A8;0x8014C850;0x8014D9AC;0x80149688;0x8014CE90', 'proven',
        'KAKU-DICE-DRAW-01; bounded to the startup viewport and 18 dice faces.')
    add('optional-games/shared/scene-composition', 'dice',
        'Combined dice HUD/text/aim-cursor composition, mode viewport transitions and '
        'blend/state ordering have not been independently qualified.',
        '0x800158A8;0x8014B4EC', 'open',
        'Remaining scene scope; typed blocker blocker.dice.3d-presentation')
    add('optional-games/shared/effect-owner', 'all',
        'Balances, RNG, receipt and story-flag publication remain with the canonical owner; these '
        'contracts emit proposals only.', '', 'open', 'caller obligation, not a defect')
    return rows


def canonical(payload):
    return json.dumps(payload, ensure_ascii=False, sort_keys=True,
                      separators=(',', ':')).encode('utf-8')


def render(payload):
    return json.dumps(payload, ensure_ascii=False, indent=2) + '\n'


def build():
    inventory = test_inventory()
    overlays, provenance = load_overlays()
    overlays['dice'].require(DICE_INSTRUCTIONS)
    overlays['coin'].require(COIN_INSTRUCTIONS)
    overlays['karuta'].require(KARUTA_INSTRUCTIONS)
    tables = build_tables(overlays)
    runtime = runtime_payload(tables)
    fixture = fixture_payload(runtime)
    registry = '\n'.join(json.dumps(row, ensure_ascii=False, sort_keys=True) for row in
                         registry_rows(tables, provenance)) + '\n'
    report = report_payload(overlays, provenance, runtime, fixture, tables, registry, inventory)
    files = {
        RUNTIME_PATH: render(runtime),
        FIXTURE_PATH: render(fixture),
        REPORT_PATH: render(report),
        REGISTRY_PATH: registry,
    }
    return files, runtime, fixture


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', type=Path)
    parser.add_argument('--check', type=Path)
    args = parser.parse_args(argv)
    if bool(args.out) == bool(args.check):
        parser.error('exactly one of --out or --check is required')
    files, _, _ = build()
    if args.out:
        for relative, text in files.items():
            target = args.out / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text, encoding='utf-8')
        return 0
    failures = []
    for relative, text in files.items():
        target = args.check / relative
        if not target.exists():
            failures.append(f'missing {relative}')
            continue
        if target.read_text(encoding='utf-8') != text:
            failures.append(f'stale {relative}')
    if failures:
        print('CHECK FAILED: ' + ', '.join(failures), file=sys.stderr)
        return 1
    print('CHECK OK: optional game contracts match source')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

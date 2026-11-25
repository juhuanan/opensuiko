#!/usr/bin/env python3
"""Static sequence clock evidence and an independent audio-update schedule."""
from fractions import Fraction
from hashlib import sha256
from itertools import product
from pathlib import Path
import random
import sys

KIT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(KIT / 'tools'), str(KIT / 'tools/seq')]
from disc import extract
import maindec as M
import render_seq as R
from test_canonical_start import assert_main_words


def check_clock_paths():
    spans = (
        (0x80159F68, 0x8015A0E8, 'e933517561a5e88511157ae126f92ce2469037708fab68f0fe5636cde7da3dc5'),
        (0x8015B3F8, 0x8015B50C, 'c406968493fcfe8f4d84072f548bdf934d5f191f6faf530656ded38570cfc3c2'),
        (0x8015D148, 0x8015D248, '0e4c48d8421153ebf4af10cbd9cfcc64f13a49aaaf8eceed1ff4b7ffc76c96aa'),
        (0x8015B5F8, 0x8015B70C, 'e9d989b7bcf840869577df31b13aa34b830449285ec3f53ecee156b3f64df66f'),
        (0x8015E8A8, 0x8015E8D4, '01f4fea74c3a076ac2a724f565f34d9dd151ebb21f3300780f69477dc9d3f6a5'),
    )
    for start, end, digest in spans:
        assert sha256(M.body()[start-M.MBASE:end-M.MBASE]).hexdigest() == digest, hex(start)

    assert_main_words({
        # Startup selects manual mode, timing mode 0 and 50 Hz only for video selector 1.
        0x800C55C8: (0x0C0567DA, 0x34041000),
        0x80159F68: (0x30821000, 0x10400008, 0x34020001, 0x3C018018, 0xAC22BE30,
                     0x30820FFF, 0x3C018018, 0xAC22C17C),
        0x800C22E0: (0x8015A094,),
        0x8015A094: (0x3C038018, 0x8C63AAC8, 0, 0x10600008, 0x34020001,
                     0x14620007, 0x3402003C, 0x34020032, 0x3C018018, 0xAC22DA38),
        0x8015A0C4: (0x3402003C, 0x3C018018, 0xAC22DA38),
        # Startup and tempo changes use the same threshold, slow stores and tie-down rounding.
        0x8015B428: (0x00041900, 0x00643823, 0x00072880, 0x00003012, 0x00061080,
                     0x00461021, 0x00021040, 0x0045102B, 0x1040000E),
        0x8015B450: (0x00441021, 0x00021900, 0x00621823, 0x000318C0, 0x0066001B),
        0x8015B478: (0xA603006E, 0x08056D43, 0xA6030070),
        0x8015B4EC: (0x2402FFFF, 0xA602006E, 0x00071040, 0x0043102B, 0x10400003,
                     0xA6040070, 0x24820001, 0xA6020070),
        0x8015D0D4: (0x34020051, 0x14C200B1, 0x3C060393),
        0x8015D16C: (0xAE06008C, 0x00003012, 0x00061080,
                     0x00461021, 0x00021040, 0x0045102B, 0x1040000E),
        0x8015D18C: (0x00441021, 0x00021900, 0x00621823, 0x000318C0, 0x0066001B),
        0x8015D1B4: (0xA603006E, 0x08057492, 0xA6030070),
        0x8015D228: (0x2402FFFF, 0xA602006E, 0x00071040, 0x0043102B, 0x10400003,
                     0xA6040070, 0x24820001, 0xA6020070),
        # The scheduler waits above the step, dispatches zero delays, and tests the live budget.
        0x8015E8BC: (0x0C056D7E, 0x00052C03),
        0x8015B650: (0x86220070, 0x8E230088, 0, 0x00622023, 0x18800010, 0x00403021),
        0x8015B668: (0x8623006E, 0, 0x18600004, 0x00601021, 0x2442FFFF, 0x08056DBB, 0xA622006E),
        0x8015B684: (0x14600005, 0, 0x8E220088, 0xA626006E,
                     0x08056DBA, 0x2442FFFF, 0x08056DBB, 0xAE240088),
        0x8015B6BC: (0x0C056DC3, 0x00122C03, 0x8E220088, 0, 0x1040FFFB, 0x00132403,
                     0x86230070, 0x02028021, 0x0203102A, 0x1440FFF6, 0x02031023, 0xAE220088),
    })


def timing(ppqn, bpm, rate):
    assert bpm == int(bpm)
    tenths_per_update = Fraction(ppqn*int(bpm), 6*rate)
    if tenths_per_update < 1:
        countdown = int(100/tenths_per_update)
        return countdown, countdown
    numerator, denominator = tenths_per_update.as_integer_ratio()
    return -1, (2*numerator+denominator-1)//(2*denominator)


def reference_updates(ticks, tempos, ppqn, rate):
    """Calculate consecutive dispatch groups, skipping complete waiting intervals."""
    slow, step = timing(ppqn, tempos[0][1], rate)
    tempo_index = 1
    pending = ticks[0]*10
    update = 0
    used = None
    updates = []
    for index, tick in enumerate(ticks):
        if used is None:
            excess = pending-step
            if excess > 0:
                if slow >= 0:
                    update += excess*(step+1)
                    pending = step
                else:
                    waits = (excess+step-1)//step
                    update += waits
                    pending -= waits*step
            used = pending
        updates.append(update)
        while tempo_index < len(tempos) and tempos[tempo_index][0] <= tick:
            slow, step = timing(ppqn, tempos[tempo_index][1], rate)
            tempo_index += 1
        if index+1 < len(ticks):
            gap = (ticks[index+1]-tick)*10
            used += gap
            if gap and used >= step:
                pending = used-step
                used = None
                update += 1
    return updates


def compare(ticks, tempos, ppqn, rate):
    expected = reference_updates(ticks, tempos, ppqn, rate)
    actual = R.schedule_ticks(ticks, tempos, ppqn, rate)
    assert [actual[tick] for tick in ticks] == expected, (ticks[0], ppqn, rate)
    return expected[-1]


def check():
    check_clock_paths()
    inputs = tuple(product((50, 60, 120), (1, 3, 9, 24, 480, 960), (1, 41, 83, 120, 999)))
    for rate, ppqn, bpm in inputs:
        expected = timing(ppqn, bpm, rate)
        if expected[1] > 32767:
            try:
                R.clock_parameters(ppqn, bpm, rate)
            except ValueError:
                pass
            else:
                raise AssertionError('wrapped timing accepted')
        else:
            assert R.clock_parameters(ppqn, bpm, rate) == expected
    assert timing(9, 60, 60) == (-1, 1)  # Exactly 1.5 rounds down.
    assert R.clock_parameters(9, 60, 60) == (-1, 1)

    rng = random.Random(0x15B5F8)
    for _ in range(300):
        ppqn = rng.choice((2, 24, 480))
        rate = rng.choice((50, 60))
        bpm = rng.choice((1, 41, 120))
        ticks = [rng.randrange(30)]
        for _ in range(14):
            ticks.append(ticks[-1]+rng.randrange(4))
        change = rng.choice(sorted(set(ticks)))
        tempos = [(0, bpm), (change, rng.choice((1, 83, 999)))]
        compare(ticks, tempos, ppqn, rate)

    data = extract(22410, 71162)
    ends = ((2940, 5820), (3434, 6805), (3136, 6299), (8850, 17701))
    dispatches = 0
    for score, (start, end) in enumerate(R.TRACKS):
        for passes, last_update in enumerate(ends[score], 1):
            _, tempos, ppqn, _, stats = R.parse_track(data[start:end], loop_passes=passes)
            ticks = stats['event_ticks']
            assert stats['loop_bounded'] and stats['loop_rewinds'] == passes-1
            assert compare(ticks, tempos, ppqn, 60) == last_update
            dispatches += len(ticks)
    assert dispatches == 55289
    print(f'PASS: static clock writers and scheduler, {len(inputs)} timing vectors, '
          f'300 synthetic schedules and {dispatches:,} score dispatches')


if __name__ == '__main__':
    check()

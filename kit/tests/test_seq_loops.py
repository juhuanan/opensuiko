#!/usr/bin/env python3
"""Static loop cursor checks and independent playback event comparisons."""
from hashlib import sha256
from pathlib import Path
import sys

KIT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(KIT / 'tools'), str(KIT / 'tools/seq')]
from disc import extract
import maindec as M
import pqes_clean as P
import render_seq as R
from test_canonical_start import assert_main_words


def check_cursor_paths():
    spans = (
        (0x8015B70C, 0x8015B9BC, '281b915a8b9e3752ef0f1f3021eedb55fb4202f15c6176654180e1fabaa1cd34'),
        (0x8015C4CC, 0x8015C614, 'c0901c7d1839276e82caa28ba6001e6cb2e5737d01f928406d778846bfa210f4'),
        (0x8015D3BC, 0x8015D478, '92537b40ddc7e292822a696c16eba459557760552d5bfc0930492eced3f9b421'),
    )
    for start, end, digest in spans:
        assert sha256(M.body()[start-M.MBASE:end-M.MBASE]).hexdigest() == digest, hex(start)
    assert_main_words({
        0x800C2358 + 4*6: (0x8015BC10,),
        0x800C2358 + 4*99: (0x8015BE2C,),
        0x8015BC20: (0x0C0571C3, 0x02403021),
        0x8015BE3C: (0x0C057133, 0x02403021),
        # Data entry sets the count once after the marker.
        0x8015C7A8: (0x92430027, 0x34020001, 0x1462000A, 0, 0x92420010, 0,
                     0x14400006, 0x02202021, 0x02002821, 0x34020001, 0xA2560028, 0x0805732B, 0xA2420010),
        # Mark saves the cursor after the incoming VLQ advances it.
        0x8015C54C: (0x0C0574EF, 0xA2020027, 0x8E030004, 0xAE020088, 0x08057180, 0xAE03000C),
        # Zero count falls through. Finite count decrements and keeps the outgoing delay.
        0x8015C564: (0x92020028, 0, 0x14400003, 0xA2060016, 0x0805717D, 0xA2000010),
        0x8015C57C: (0x2C42007F, 0x1040000F, 0),
        0x8015C590: (0x2442FFFF, 0x0C0574EF, 0xA2020028, 0x92030028, 0, 0x10600004,
                     0xAE020088, 0x8E02000C, 0x08057180, 0xAE020004),
        # Infinite count restores the cursor and zeroes the outgoing delay.
        0x8015C5C0: (0x0C0574EF, 0, 0x8E02000C, 0xAE000088, 0x08057180, 0xAE020004),
        0x8015D404: (0x24620001, 0xACA20004, 0x90640000),
        0x8015D438: (0x24620001, 0xACA20004, 0x90630000),
    })


def header():
    return b'pQES'+(1).to_bytes(4,'big')+(480).to_bytes(2,'big')+(500000).to_bytes(3,'big')+b'\x02\x02'


def compare_playback(blob, raw, bound, outgoing_delay):
    events = raw['voice_events']
    start, = (i for i, event in enumerate(events) if event[1] == 11 and event[3:] == (99, 20))
    end, = (i for i, event in enumerate(events) if event[1] == 11 and event[3:] == (99, 30))
    body_start = events[start+1][0]
    marker_channel = events[start][2]
    count, = (event[4] for event in events[start+1:end] if event[1:4] == (11, marker_channel, 6))
    infinite = count == 127
    passes = bound if infinite else min(bound, max(1, count))
    bounded = infinite or passes < count
    stride = events[end][0] - body_start + (0 if infinite else outgoing_delay)

    quotient, remainder = divmod(60_000_000, raw['tempo'])
    tempo_events = [(tick, int(bpm)) for tick, bpm in raw['tempos'][1:]]
    expected_tempo = [(0, quotient + (remainder * 2 > raw['tempo']))]
    expected_tempo.extend((tick, bpm) for tick, bpm in tempo_events if tick < body_start)
    body_tempos = [(tick, bpm) for tick, bpm in tempo_events if body_start <= tick <= events[end][0]]
    expected_events = events[:start+1]
    for repeat in range(passes):
        shift = repeat * stride
        expected_events.extend((tick+shift, *event) for tick, *event in events[start+1:end+1])
        expected_tempo.extend((tick+shift, bpm) for tick, bpm in body_tempos)
    last_shift = (passes-1) * stride
    expected_tick = events[end][0] + last_shift
    if not bounded:
        expected_events.extend((tick+last_shift, *event) for tick, *event in events[end+1:])
        expected_tempo.extend((tick+last_shift, bpm) for tick, bpm in tempo_events if tick > events[end][0])
        expected_tick = raw['last_tick'] + last_shift

    _, actual_tempo, _, _, stats = R.parse_track(blob, loop_passes=bound)
    assert stats['voice_events'] == expected_events, (count, bound)
    assert actual_tempo == expected_tempo, (count, bound)
    assert (stats['last_tick'], stats['loop_rewinds'], stats['loop_bounded']) == (expected_tick, passes-1, bounded)
    return stats


def check():
    check_cursor_paths()
    for count in range(128):
        # Incoming delay 7 is skipped on rewind. Finite rewinds keep outgoing delay 13.
        stream = bytes([0,0xB0,99,20,7,6,count,0,0xC0,3,0,0xB0,7,55,
                        0,0x90,60,90,0,0xFF,0x51,6,0x1A,0x80,
                        4,0x90,60,0,0,0xFF,0x51,9,0x27,0xC0,
                        2,0xB0,99,30,13,0xC0,4,0,0xFF,0x2F,0])
        blob = header()+stream
        raw = P.parse_track(blob)
        assert raw['err'] is None and raw['bytes_used'] == raw['bytes_total']
        for bound in (1, 2, 3):
            compare_playback(blob, raw, bound, outgoing_delay=13)

    data = extract(22410, 71162)
    ends = ((47040, 93121), (52800, 104641), (34559, 69118), (133940, 267880))
    total = 0
    for score, (start, end) in enumerate(P.TRACKS):
        blob = data[start:end]
        raw = P.parse_track(blob)
        assert raw['err'] is None and raw['bytes_used'] == raw['bytes_total']
        for bound, end_tick in enumerate(ends[score], start=1):
            # These four loops all force outgoing delay to zero.
            stats = compare_playback(blob, raw, bound, outgoing_delay=0)
            assert stats['last_tick'] == end_tick and stats['loop_bounded']
            if score == 0:
                assert raw['voice_events'][-1] == (47050,9,7,41,0)
                assert (47050,9,7,41,0) not in stats['voice_events']
            total += len(stats['voice_events'])

    for invalid in (0, -1, 1.5):
        try:
            R.parse_track(header()+b'\0\xff\x2f\0', loop_passes=invalid)
        except ValueError:
            pass
        else:
            raise AssertionError('invalid loop bound accepted')
    print(f'PASS: static loop cursor and delay paths, 384 synthetic comparisons, '
          f'{total} playback channel events across four fully consumed scores')


if __name__ == '__main__':
    check()

#!/usr/bin/env python3
"""Disc header/meta tempo rules, independent extraction and clock consumers."""
import json
from pathlib import Path
import struct
import sys

KIT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(KIT / 'tools'), str(KIT / 'tools/seq')]
import disc
import pqes_clean as P
import render_seq as R


def check():
    files = json.loads((KIT / 'extracted/iso_files.json').read_text())
    rec = next(r for r in files if r['path'] == 'DATA/00_INIT/SEQ.BIN')
    data = disc.extract(rec['lba'], rec['size'])
    main = disc.extract(17976, 757760)[2048:]
    anchors = {
        0x8015B2EC: 0x1062000D, 0x8015B2F0: 0x3C060393,
        0x8015B324: 0x34C68700, 0x8015B330: 0x90E30008,
        0x8015B33C: 0x90E20009, 0x8015B34C: 0xA602004A,
        0x8015B358: 0x90A20000, 0x8015B364: 0x90A40001,
        0x8015B370: 0x90A30002, 0x8015B374: 0x00021400,
        0x8015B378: 0x00042200, 0x8015B384: 0x00C2001A,
        0x8015B390: 0x0007000D, 0x8015B3AC: 0x00003012,
        0x8015B3B0: 0x00001810, 0x8015B3B8: 0x00021042,
        0x8015B3BC: 0x0043102A, 0x8015B3C0: 0x10400003,
        0x8015B3C4: 0x24C20001, 0x8015B3CC: 0xAE020084,
        0x8015B3D0: 0xAE060084, 0x8015B3EC: 0xAE03008C,
        0x8015B990: 0x0C05741A, 0x8015D0D4: 0x34020051,
        0x8015D0D8: 0x14C200B1, 0x8015D0DC: 0x3C060393,
        0x8015D0E4: 0x34C68700, 0x8015D0F0: 0x90A20000,
        0x8015D0FC: 0x90A40001, 0x8015D108: 0x90A30002,
        0x8015D10C: 0x00021400, 0x8015D110: 0x00042200,
        0x8015D11C: 0x00C2001A, 0x8015D128: 0x0007000D,
        0x8015D144: 0x00003012, 0x8015D16C: 0xAE06008C,
        0x8015D150: 0x00460018, 0x8015D158: 0x8C84DA38,
        0x8015D1B4: 0xA603006E, 0x8015D1BC: 0xA6030070,
        0x8015D1C4: 0x8E02008C, 0x8015D1E0: 0x0045001B,
        0x8015D22C: 0xA602006E, 0x8015D23C: 0xA6040070,
        0x8015B650: 0x86220070, 0x8015B654: 0x8E230088,
        0x8015B65C: 0x00622023, 0x8015B668: 0x8623006E,
        0x8015B6BC: 0x0C056DC3,
    }
    for va, word in anchors.items():
        assert struct.unpack_from('<I', main, va - 0x800C0800)[0] == word, hex(va)

    header_mpqn = [500000, 521739, 717703, 525854]
    for song, (start, end) in enumerate(P.TRACKS):
        blob = data[start:end]
        assert int.from_bytes(blob[10:13], 'big') == header_mpqn[song]
        independent = P.parse_track(blob)
        assert independent['err'] is None
        assert independent['bytes_used'] == independent['bytes_total'] == len(blob) - 15
        _, tempos, ppqn, bpm, _ = R.parse_track(blob)
        assert ppqn == independent['ppqn'] == 480
        assert len(tempos) == len(independent['tempos'])
        # Derive integer tempo using the separate parser's exact encoded values.
        for index, ((tick, encoded_bpm), actual) in enumerate(zip(independent['tempos'], tempos)):
            mpqn = round(60_000_000 / encoded_bpm)
            quotient = 60_000_000 // mpqn
            remainder = 60_000_000 - quotient * mpqn
            expected = quotient + (index == 0 and remainder > mpqn // 2)
            assert actual == (tick, expected)
        if song == 0:
            assert tempos == [(0, 120)]
        if song == 2:
            assert [b for _, b in tempos] == [84, 81, 78, 73, 69, 41, 83]
            assert bytes.fromhex('ff 51 16 02 03') in blob  # 1,442,307 us/quarter
            assert bpm == 84

    assert R._tempo_bpm(1_600_000, initial=True) == 37  # exact half rounds down
    assert R._tempo_bpm(1_599_999, initial=True) == 38
    header = b'pQES' + (1).to_bytes(4, 'big') + (480).to_bytes(2, 'big')
    for blob in (header + bytes(3) + b'\x02\x02\x00\xff\x2f\x00',
                 header + (500000).to_bytes(3, 'big') + b'\x02\x02\x00\xff\x51\x00\x00\x00'):
        try:
            R.parse_track(blob)
        except ValueError as exc:
            assert 'tempo' in str(exc)
        else:
            raise AssertionError('zero tempo silently acquired a fallback')
    print(f'PASS: {len(anchors)} raw tempo/clock anchors, four independently consumed SEQs, '
          'header rounding/meta truncation and zero-tempo rejection')


if __name__ == '__main__':
    check()

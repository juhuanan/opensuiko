#!/usr/bin/env python3
"""Static SEQ bend dispatch, per-voice pitch and two parser checks."""
from hashlib import sha256
import json
from pathlib import Path
import math
import struct
import sys
sys.path[:0]=[str(Path(__file__).resolve().parents[1]/'tools'),
             str(Path(__file__).resolve().parents[1]/'tools/seq')]
import maindec as M
from test_canonical_start import assert_main_words
from disc import extract
import pqes_clean as P
import render_seq as R

TABLE=tuple(math.floor(4096*2**(i/192)) for i in range(192))


def check_bend(note,center,shift,bend,down,up):
    original_note=note
    delta=bend-64
    if delta>0:
        whole,fraction=divmod(delta*up,63)
        note+=whole;fine=2*fraction
    elif delta<0:
        value=delta*down;whole=-(abs(value)//64)
        note+=whole-1;fine=2*(value-64*whole)+127
    else:fine=0
    adjusted_note=note
    fraction=(shift+fine)//8
    note+=int(fraction>=16)
    fraction-=16*int(fraction>=16)
    n=note+60-center;q=n//12
    assert n>=0 and 0<=fraction<16
    value=TABLE[(n%12)*16+fraction]
    expected=((value<<(q-5)) if q>5 else (value>>(5-q)))&65535
    assert R.pitch_register(adjusted_note,center,shift,fine)==expected
    assert R.bend_register(original_note,dict(center=center,shift=shift,pbmin=down,pbmax=up),bend)==expected
    return expected


def check_source():
    for start, end, digest in (
        (0x80157054, 0x8015726C, 'e531e97229bcfaf2ba06630c3baec5d686d691e40a5c8657ab9467492f2c58d8'),
        (0x8015726C, 0x8015735C, '9a7aab1e3264180032a91f6be40868d79762466cabcdc28bb59d026cf34915a4'),
        (0x80155C88, 0x80155E44, '38d34942eaeae6ce7a2d8ccfc75434e66686044e98f2af90be32a6ad08cfa41b'),
        (0x8015B70C, 0x8015B9BC, '281b915a8b9e3752ef0f1f3021eedb55fb4202f15c6176654180e1fabaa1cd34'),
        (0x8015CFB8, 0x8015D068, '3b90c09b12650fda3ea2d8f5e7e21c8b4f228502abeafcca2534e7efc9205e4c'),
    ):
        assert sha256(M.body()[start-M.MBASE:end-M.MBASE]).hexdigest() == digest, hex(start)
    assert_main_words({
        # Owner, bank and program mismatches bypass the pitch and dirty stores.
        0x8015708C: (0x2421A572, 0x00280821, 0x84220000, 0x00052C03, 0x1445006E, 0x00001021),
        0x801570A8: (0x2421A57A, 0x00280821, 0x84230000, 0x00061400, 0x00021403, 0x14620066, 0x00001021),
        0x801570C8: (0x2421A576, 0x00280821, 0x84230000, 0x00071400, 0x00021403, 0x1462005E, 0x00001021),
        # The original note is read, and up/down ranges are separate tone bytes.
        0x80157100: (0x2421A570, 0x00280821, 0x94250000),
        0x80157134: (0x9042000D,),
        0x80157144: (0x3C028208, 0x34422083),
        0x80157198: (0x9042000C,),
        0x801571B0: (0x2482003F, 0x00021183),
        0x80157210: (0x0C055751, 0x30A5FFFF, 0x00101900, 0x3C018018, 0x2421A3D4, 0x00230821, 0xA4220000),
        0x80157240: (0x34630004, 0x3C018018, 0x2421A550, 0x00300821, 0xA0230000, 0x34020001),
        # Visit each configured voice, summing only its return value.
        0x801572F8: (0x0C055C15, 0xAFA20010, 0x00021400, 0x00021403, 0x02228821, 0x26020001),
        0x8015731C: (0x9063C0E4, 0x00021403, 0x0043102A, 0x1440FFEC, 0x00102400, 0x02201021),
        # The event dispatcher reads one byte before either branch. Explicit E0
        # advances again past LSB. Running E0 already consumed LSB on entry.
        0x8015B76C: (0x8E270004, 0, 0x24E20001, 0xAE220004, 0x90F00000),
        0x8015B7C4: (0x340200E0, 0x10C2002B),
        0x8015B880: (0x8E220004, 0x340300E0, 0xA2230011, 0x24420001, 0x0C0573EE, 0xAE220004),
        0x8015B8F4: (0x340200E0, 0x1062001E),
        0x8015B974: (0x02802021, 0x0C0573EE, 0x02402821),
        0x8015D014: (0x8E030004, 0x8605004C, 0x24620001, 0xAE020004, 0x92020012,
                     0x90670000, 0x00501021, 0x9046002C, 0x0C055C9B),
    })


def check_ordinary_pitch():
    from vab_tones import parse_header, parse_programs, find_tone_table

    listing = json.loads((Path(__file__).resolve().parents[1] / 'extracted/iso_files.json').read_text())
    cases = 0
    for bank in ('ORCH', 'HNK1', 'HNK2'):
        row = next(r for r in listing if r['path'].endswith('/' + bank + '.VA'))
        data = extract(row['lba'], row['size'])
        ps, ts, vs = parse_header(data)
        attrs, _ = parse_programs(data, ps)
        _, _, programs = find_tone_table(data, ts, ps, vs, attrs)
        for tones in programs:
            for tone in tones:
                for note in range(128):
                    relative = note + 60 - tone['center']
                    octave = math.trunc(relative / 12)
                    index = (relative - 12 * octave) * 16 + min(tone['shift'] // 8, 15)
                    entry, = struct.unpack_from('<H', M.body(), 0x80178424 - M.MBASE + 2 * index)
                    level = entry * (1 << (octave - 5)) if octave >= 5 else entry // (1 << (5 - octave))
                    assert R.pitch_register(note, tone['center'], tone['shift']) == level % 65536
                    cases += 1
    assert cases == 6912
    return cases


def check():
    check_source()
    cases = 0
    for bend in range(128):
        for down, up in ((0, 0), (2, 2), (12, 24)):
            for shift in (0, 7, 64, 120, 124):
                check_bend(60, 60, shift, bend, down, up)
                cases += 1

    data = extract(22410, 71162)
    header = data[P.TRACKS[0][0]:P.TRACKS[0][0] + 15]
    dispatch = 0
    for running in (False, True):
        for low in range(128):
            for high in (0, 64, 127):
                stream = bytes((0, 0xE3, 17, 64, 0)) + (b'' if running else bytes((0xE3,)))
                blob = header + stream + bytes((low, high, 0, 0xFF, 0x2F, 0))
                expected = [(0, 3, 17, 64), (0, 3, low, high)]
                parsed = P.parse_track(blob)
                assert parsed['err'] is None and parsed['bytes_used'] == parsed['bytes_total']
                assert parsed['bends'] == R.parse_track(blob)[4]['bends'] == expected
                dispatch += 1
    ordinary = check_ordinary_pitch()
    counts=[]
    for start,end in P.TRACKS:
        independent=P.parse_track(data[start:end]);actual=R.parse_track(data[start:end])[4]
        assert independent['err'] is None and independent['bytes_used']==independent['bytes_total']
        assert independent['bends']==actual['bends']
        assert independent['voice_events']==actual['voice_events']
        first_note=next(i for i,event in enumerate(actual['voice_events']) if event[1]==9 and event[4])
        controls=[i for i,event in enumerate(actual['voice_events']) if event[1]==11 and event[3] in (7,10)]
        assert all(actual['voice_events'][i][0]==0 for i in controls)
        assert sum(i>=first_note for i in controls)==(0,0,1,9)[len(counts)]
        counts.append(len(actual['bends']))
    print(f'PASS: static bend dispatch and stores, {ordinary} ordinary pitches, {cases} bend calculations, '
          f'{dispatch} parser cases and four disc score bend counts {counts}')


if __name__=='__main__':check()

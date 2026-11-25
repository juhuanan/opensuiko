#!/usr/bin/env python3
"""Static checks of the live S1 source, piece walker and counted timer."""
from hashlib import sha256
from pathlib import Path
import struct
import sys
import tempfile
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from disc import extract
import parse_04play as P
import play_sprite_geometry as G
import q_art
import maindec as M
from test_canonical_start import assert_main_words
from export_assets import parse_play04


def check_timer():
    start, end = 0x800E2AA4, 0x800E2B3C
    assert sha256(M.body()[start-M.MBASE:end-M.MBASE]).hexdigest() == (
        'f806732448b65d965e140d5e579348e9828bf089eea1871f542af69e38a1fbe8')
    assert_main_words({
        0x800E2AAC: (0x30420002, 0x1040001E),
        0x800E2AB8: (0x90820003, 0, 0x2442FFFF, 0xA0820003, 0x304200FF, 0x14400017),
        0x800E2AD4: (0x90820002, 0x90830001, 0x24420001, 0x0043102A, 0x1440000B),
        0x800E2AF4: (0x30620001, 0x10400003, 0x2402FFFD, 0x08038AC9, 0xA0800002),
        0x800E2B08: (0x00621024, 0x08038AC9, 0xAC820008),
        0x800E2B14: (0x90820002, 0, 0x24420001, 0xA0820002, 0x0C038847, 0),
    })
    play = M.mword(0x800E2AAC) & 0xFFFF
    loop = M.mword(0x800E2AF4) & 0xFFFF
    countdown_mask = M.mword(0x800E2AC8) & 0xFFFF
    decrement = (M.mword(0x800E2AC0) & 0xFFFF) - 65536
    stop_mask = (M.mword(0x800E2AFC) & 0xFFFF) - 65536

    # Evaluate the proven byte countdown and separately check the first expiry.
    cases = 0
    for count in range(6):
        for position in range(max(count, 1)):
            for duration in (0, 1, 2, 10, 255):
                for flags in range(8):
                    remaining = duration
                    first_expiry = None
                    for update in range(1, 257):
                        if flags & play:
                            remaining = (remaining + decrement) & countdown_mask
                            if remaining == 0:
                                first_expiry = update
                                break
                    assert first_expiry == ((duration or 256) if flags & 2 else None)
                    if first_expiry is None:
                        assert remaining == duration
                    else:
                        next_pair = position+1
                        if next_pair < count:
                            actual = next_pair, flags
                        elif flags & loop:
                            actual = 0, flags
                        else:
                            actual = position, flags & stop_mask
                        at_end = position == max(0, count-1)
                        expected_position = position+1
                        if at_end:
                            expected_position = 0 if flags & 1 else position
                        expected_flags = flags ^ 2 if at_end and not flags & 1 else flags
                        assert actual == (expected_position, expected_flags)
                    cases += 1
    return cases


def check():
    main=extract(17976,757760)[2048:]
    def word(pc):return struct.unpack_from('<I',main,pc-0x800C0800)[0]
    anchors={
        0x800C4AA0:0x8CC40004,0x800C4AAC:0x0C0311CF,
        0x800C4AB0:0xACC40004,
        0x800DECA0:0x8E240024,0x800DECA4:0x0C030D40,
        0x800DECC4:0x8E240024,0x800DECC8:0x0C03878F,
        0x800DECCC:0x00002821,0x800DECD0:0xAE020084,
        0x800E1E74:0x34040034,0x800E1E7C:0xAE700030,
        0x800E1E84:0x8E030014,0x800E1E90:0x8C420000,
        0x800E1E98:0x90550002,0x800E1EB0:0x001080C0,
        0x800E1EBC:0xAE620028,0x800E1EC8:0xAE62002C,
        0x800E1F50:0x0C038811,
        0x800E204C:0x8C820030,0x800E2054:0x8C420014,
        0x800E2060:0x8C420000,0x800E2068:0x90420000,
        0x800E206C:0xA0800002,0x800E2074:0xA0820001,
        0x800E2090:0x90420001,0x800E209C:0x00021042,
        0x800E20A0:0x30420001,0x800E20CC:0x30420001,
        0x800E20D0:0x00021040,0x800E20FC:0x30420004,
        0x800E2104:0x0C038847,
        0x800E214C:0x8E830030,0x800E2154:0x8C630014,
        0x800E2168:0x24630004,0x800E216C:0xAE830020,
        0x800E2170:0x00021040,0x800E2178:0x90440000,
        0x800E217C:0x90420001,0x800E2184:0xA2820003,
        0x800E2188:0x8C620010,0x800E2198:0x8C820000,
        0x800E21A4:0xAE820024,0x800E21A8:0x905E0000,
        0x800E21CC:0x001510C0,0x800E21D8:0x24420008,
        0x800E21DC:0x00439821,0x800E21E4:0x92620002,
        0x800E22D8:0x92620003,0x800E234C:0x92630004,
        0x800E236C:0x92630005,0x800E2434:0x26B50001,
        0x800E243C:0x1440FF63,0x800E2440:0x26D60028,
        0x800E0A54:0x8E110084,0x800E0A74:0x0C038AA7,
        0x800E0A78:0x02202021,
    }
    for pc,expected in anchors.items():assert word(pc)==expected,hex(pc)
    sequences=pairs=zeros=pieces=subs=0
    exceptional=[]
    ail=None
    for row in G.play_files():
        data=extract(row['lba'],row['size'])
        section=struct.unpack_from('<I',data,0x24)[0]
        a,b=struct.unpack_from('<HH',data,section)
        etab,ftab=struct.unpack_from('<II',data,section+16)
        parser=P.Parser(data,0)
        parsed=parser._parse_f_table('S1',ftab,b)
        for i,e in enumerate(parsed['entries']):
            offset=struct.unpack_from('<I',data,ftab+4*i)[0]
            n,flags,capacity,reserved=data[offset:offset+4]
            expected=[list(data[offset+4+2*j:offset+6+2*j]) for j in range(n)]
            assert e['sequence']==dict(frame_count=n,flags=flags,draw_capacity=capacity,
                                       reserved=reserved,pairs=expected)
            assert bytes.fromhex(e['raw_hex'])==data[offset:offset+4+2*n]
            sequences+=1;pairs+=n;zeros+=n==0
            for draw,duration in expected:
                assert duration>0
                if draw>=a:exceptional.append((Path(row['path']).stem,i,draw,a))
        es=parser._parse_e_table('S1',etab,a)
        oracle=q_art.piece_records(data,0,etab,a)
        for e,o in zip(es['entries'],oracle,strict=True):
            rec=e['record'];assert rec['sub_piece_count']==o['count']
            pieces+=1;subs+=o['count']
            for p,q in zip(rec['sub_pieces'],o['sub_pieces'],strict=True):
                assert list(p.values())==list(bytes.fromhex(q['raw']))
        if Path(row['path']).name=='AIL.BIN':ail=data
    assert (sequences,pairs,zeros,pieces,subs)==(1342,2513,107,947,955)
    assert exceptional==[('CRE',22,16,16),('JUP',22,15,15),('ODE',18,11,11),
                         ('SID',21,13,13),('TED',18,11,11)]
    cases = check_timer()
    # Counts remain a read boundary, including corrupt headers.
    corrupt=bytearray(32);struct.pack_into('<I',corrupt,0,16);corrupt[16]=255
    for method in ('_parse_f_table','_parse_e_table'):
        try:getattr(P.Parser(corrupt,0),method)('S1',0,1)
        except P.ParseError:pass
        else:raise AssertionError('unbounded count accepted: '+method)
    with tempfile.TemporaryDirectory(prefix='suikoden-s1-consumer-') as td:
        source=Path(td)/'AIL.BIN';source.write_bytes(ail)
        recipe=parse_play04(source)
        assert P.parse_04play(source)['header']['slots'][1]['relocated_by_game']
        anims=recipe['S1']['anims']
        assert anims['entries'][0]['sequence']['pairs']==[[0,1]]
        assert anims['entries'][4]['sequence']['pairs']==[]
        assert 'open' not in anims['parse_confidence']
    print(f'PASS: {len(anchors)} live source/selector/walker anchors;1342 S1 sequences, '
          f'2513 pairs,947 piece records/955 sub-pieces; {cases} static timer boundary cases; '
          '107 zero counts and5 out-of-range references retained explicitly')

if __name__=='__main__':check()

#!/usr/bin/env python3
"""Sequence-open slots and bank-load records independently matched to ISO files."""
import contextlib
from hashlib import sha256
import io
import json
from pathlib import Path
import struct
import sys
KIT=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(KIT/'tools'),str(KIT/'tools/seq')]
from disc import extract
import maindec as M
import pqes_clean as P
import render_seq as R
from test_canonical_start import assert_words
from vab_tones import parse_header, PROG_OFF, PROG_SIZE, TONE_BASE, TONE_STRIDE


def lifecycle(main,by):
    # Pin the paths from the header size loop through selection, transfer and close.
    spans = (
        (0x8015AD20, 0x8015B168, '650813f0ec683a9069c3f64e1e22eb6fd4415b6ace413fc77a795edfeaa9db42'),
        (0x80159A80, 0x80159B54, '83f76aebc59c07823ff8c3fa47418239d33e02abde4c358a62aa9ce2e8145137'),
        (0x800C7830, 0x800C78B8, '21be93e8a3d5257a42eb480d8d5062857a92dcca431b69ae144d51d3141bbfe7'),
        (0x80154B1C, 0x80154C8C, '29e4e0ed6e2c2bd37e6d95d2ec8896d74f571a2580f0c29166488343868936b5'),
        (0x80163524, 0x801635B0, '679ba6e5245571951b0e1eaa984950885583311ab39ee6b4e3a1578514dc9f37'),
        (0x80161D18, 0x80161DA0, '2af6c8dadcac5aa57a4ef27776e4c429e15facf04eb9b584c0c1c4595910489a'),
        (0x80161A70, 0x80161D18, 'b9f0031a2c536f62a8970cd636ad33f07c95659e08bc65c75adb0102abf54491'),
        (0x8015F170, 0x8015F200, '6449f0382e725ba0bad41d013498535a0bbf56916e329218d64ae73abbbb7ea5'),
    )
    for start, end, digest in spans:
        assert sha256(main[start-M.MBASE:end-M.MBASE]).hexdigest() == digest, hex(start)
    assert_words(main, M.MBASE, {
        # VAB version >= 5 uses eight-byte units. Header writes status 2.
        0x8015AF94: (0x94C30000, 0x28420005, 0x14400002, 0x00031080, 0x000310C0),
        0x8015B124: (0xAC300000, 0x34030002, 0x3C018018, 0x2421C16C, 0x00220821, 0xA0230000),
        # Body requires status 2 and the sequence selector requires status 1.
        0x80154B64: (0x90230000, 0x34020002, 0x1462001B),
        0x80159AA8: (0x90230000, 0x34020001, 0x14620026, 0x2402FFFF),
        # Clamp to bytes remaining, pass that length to DMA, then subtract it.
        0x80154BF8: (0x0070102B, 0x10400002, 0, 0x00608021),
        0x80154C14: (0x0C058D49, 0x02002821),
        0x80154C28: (0x00501023, 0x3C018018, 0xAC228418, 0x1440000C, 0x2402FFFE),
        0x80154C4C: (0x34030001, 0x3C018018, 0xAC208418, 0x3C018018, 0x2421C16C, 0x00220821, 0xA0230000),
        0x800C78A0: (0x3C050001, 0x0C0552C7, 0x34A5D800),
        # DMA4 BCR packs ceil(length / 64) in its high half and 16 words in its low half.
        0x80161D60: (0x34040003, 0x02202821, 0x0C05869C, 0x02003021),
        0x80161CA0: (0x00041982, 0x3082003F, 0x0002102B, 0x3C048018, 0x8C8487B8, 0x00621821),
        0x80161CD4: (0x00021400, 0x34420010, 0xAC620000),
        0x80178770: (0x1F8010C4,),
        0x8015F1D0: (0xA0200000,),
        0x80164E14: (0x11010, 0x45D10, 0x60600),
    })

    oversized = {}
    for i in range(47):
        _, _, va_size, va_lba, _, _, requested, vb_lba = struct.unpack_from(
            '<8I', main, 0x80164834-M.MBASE+32*i)
        va = extract(va_lba, va_size)
        programs, _, samples = parse_header(va)
        assert struct.unpack_from('<I', va, 4)[0] >= 5
        assert 0 < programs <= 128 and samples < 256
        assert sum(va[off] > 0 for off in range(PROG_OFF, TONE_BASE, PROG_SIZE)) == programs
        sizes = struct.unpack_from(f'<{samples+1}H', va, TONE_BASE + programs*TONE_STRIDE)
        declared = sum(sizes)*8
        assert 0 < declared == by[vb_lba]['size'] <= requested, i

        # Compare caller chunks trimmed by the SDK with the ISO-size boundaries.
        cap = 0x1D800
        transfers = []
        remaining = declared
        for offset in range(0, requested, cap):
            logical = min(cap, requested-offset, remaining)
            transfers.append(logical)
            remaining -= logical
            if remaining == 0:
                break
        full, tail = divmod(by[vb_lba]['size'], cap)
        assert transfers == [cap]*full + ([tail] if tail else []), i
        assert remaining == 0
        padding = sum(-length % 64 for length in transfers)
        assert sum(transfers) + padding == (declared + 63)//64*64
        if requested != declared:
            oversized[i+0x21] = (declared, requested, padding)
        if i+0x21 == 0x25:
            assert 0x45D10 + declared == 0x60600 and padding == 16
    assert oversized == {
        0x38: (26720, 30496, 32), 0x3D: (12528, 19568, 16),
        0x41: (25760, 35856, 32), 0x44: (9712, 18384, 16),
    }


def check():
    main=M.body()
    anchors={
        0x800C75B8:0x0C057C5C,0x800C76C0:0x24214E14,
        0x800C787C:0x0C0552C7,0x80154BFC:0x10400002,
        0x80154C14:0x0C058D49,0x8015B124:0xAC300000,
        0x800C73A8:0x0C056D4B,0x800C73AC:0x34050001,
        0x800C73C8:0x0C056D4B,0x800C73CC:0x24843DC4,
        0x800C73E4:0x34050002,0x800C73E8:0x34048630,
        0x800C73EC:0x0C056D4B,0x800C7410:0x0C056D4B,
        0x800C7408:0x34050002,0x800C740C:0x3404AD96,
        0x8015B5C4:0x0C056C81,0x8015B5C8:0x00052C03,
        0x8015B244:0xA605004C,0x8015BF6C:0x8644004C,
        0x8015BF78:0x0C0576A0,0x8015BFA4:0x8644004C,
        0x8015BFAC:0x0C057598,0x8015D6A4:0x0C0566A0,
        0x800C759C:0x24634834,0x800C75A0:0x2442FFDF,
        0x800C75A4:0x00021140,0x800C76B0:0x90450001,
        0x800C76CC:0x0C056B2E,0x8015ACCC:0x0C056B48,
        0x8015AE6C:0xAC260000,0x800C2358:0x8015BBF8,
        0x8015BBCC:0x90720000,0x8015BC0C:0xA692004C,
    }
    for va,word in anchors.items():
        assert struct.unpack_from('<I',main,va-0x800C0800)[0]==word,hex(va)
    files=json.loads((KIT/'data/catalogs/extracted/iso_files.json').read_text())
    by_lba={r['lba']:r for r in files if not r.get('dir')}
    seq=next(r for r in files if r['path']=='DATA/00_INIT/SEQ.BIN')
    data=extract(seq['lba'],seq['size'])
    starts=[0,0x3DC4,0x8630,0xAD96]
    assert starts==[s for s,_ in P.TRACKS]
    assert all(data[s:s+4]==b'pQES' for s in starts)
    for start,end in P.TRACKS:
        blob=data[start:end]
        independent=P.parse_track(blob)
        assert independent['err'] is None
        assert independent['bytes_used']==independent['bytes_total']==len(blob)-15
        actual=R.parse_track(blob)[4]['controls']
        assert actual==independent['controls']
        assert not any(cc==0 for _,_,cc,_ in actual)

    rec=struct.unpack_from('<4I',main,0x80164824-0x800C0800)
    assert rec[2:]==(seq['size'],seq['lba'])
    routing={}
    size_deltas={}
    for i in range(47):
        off=0x80164834-0x800C0800+i*32
        header_slot=main[off+1]
        body_slot=main[off+17]
        _,_,va_size,va_lba,_,_,vb_size,vb_lba=struct.unpack_from('<8I',main,off)
        va,vb=by_lba[va_lba],by_lba[vb_lba]
        assert va['size']==va_size
        if vb['size']!=vb_size:
            size_deltas[i+0x21]=vb_size-vb['size']
        assert va['path'].endswith('.VA') and vb['path']==va['path'][:-3]+'.VB'
        assert header_slot==body_slot
        routing[i+0x21]=(header_slot,Path(va['path']).stem)
    assert size_deltas=={0x38:3776,0x3D:7040,0x41:10096,0x44:8672}
    assert routing[0x25]==(1,'ORCH')
    assert routing[0x26]==(2,'HNK1') and routing[0x27]==(2,'HNK2')
    assert routing[0x28]==(2,'A00')
    assert R.BANKS=={0:'ORCH',1:'ORCH'}
    for song in (2,3):
        try: R.render_song(song,b'',{},None,write=False)
        except ValueError as exc: assert 'slot 2' in str(exc)
        else: raise AssertionError('unproven bank assignment accepted')
    # The CLI must reject the all-song default before touching any audio output.
    from unittest.mock import patch
    with patch.object(R, 'render_song', side_effect=AssertionError('render called before context check')):
        with contextlib.redirect_stderr(io.StringIO()):
            try: R.main([])
            except SystemExit as exc: assert exc.code==2
            else: raise AssertionError('CLI silently picked a slot-2 bank')
    lifecycle(main,by_lba)
    print('PASS: static bank lifecycle and DMA paths, four physical sequences, 47 VA/VB records; '
          'dynamic slot-2 context required before rendering')

if __name__=='__main__':
    check()

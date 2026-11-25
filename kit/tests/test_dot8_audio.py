#!/usr/bin/env python3
"""Positive .8 byte-format, CD producer and SPU DMA consumer checks."""
from hashlib import sha256
from pathlib import Path
from collections import Counter
import struct
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from dot8_audio import resources, channel_bytes, CHUNK, pcm
from disc import extract
from test_canonical_start import assert_main_words
from test_spu_adpcm import make_block, reference_decode
import maindec as M


def check_source_paths():
    spans = (
        (0x800C7A24, 0x800C7E10, '3f2b68ca183b03e6e2ba91a134c4e679898ffdff16417d6d848978b3aa1b7635'),
        (0x800C8760, 0x800C87E4, '6493f91f1a83c2491ebe3a500757e9f3ff2409c7fd6fe45c4f6fa1d030b5ea18'),
        (0x800C8140, 0x800C8278, 'e44a872535c990d193af651d7fa92f785c5b6b4b5436883642f92340457702bf'),
        (0x800C8468, 0x800C85C4, '3c4a27eed9548fa66125194743b9e2b0f1a1fbe0c99284a447d603eba5a4b01d'),
        (0x800C85C4, 0x800C86F0, '4b973af93624b932f94a3f208a098f67c782a7ec845f7dab79a1f9c7db53bb8a'),
        (0x80162FE4, 0x80163044, '6e26c50131769121686165d2feecb1866511fcc3b0854bd9b5753cf3dea90544'),
        (0x80161D18, 0x80161DA0, '2af6c8dadcac5aa57a4ef27776e4c429e15facf04eb9b584c0c1c4595910489a'),
        (0x80161C80, 0x80161D18, '474d894b497a8858960de00027c5b57472b13864e4112eb39cb4e30f052eadbe'),
    )
    for start, end, digest in spans:
        assert sha256(M.body()[start-M.MBASE:end-M.MBASE]).hexdigest() == digest, hex(start)
    assert_main_words({
        # Voices 22/23, indexed rate field, and common source buffer.
        0x800C7A90: (0x3C020040, 0x3C018018, 0xAC229D10, 0x3C020080, 0x3C018018, 0xAC229D50),
        0x800C7AC8: (0x00031040, 0x00431021, 0x00021080, 0x3C018016, 0x24214E6C,
                     0x00220821, 0x94230000, 0x3402AC44, 0x00031B00, 0x0062001A),
        0x800C7BD0: (0x3C018018, 0xA4239D64, 0x3C018018, 0xA4239D24),
        0x800C7CA0: (0x1462000E, 0),
        0x800C7CB0: (0x3C018018, 0xA4209D58, 0x3C018018, 0xA4209D1A, 0x000211C0,
                     0x3C018018, 0xA4229D18, 0x3C018018, 0xA4229D5A),
        0x800C7CE8: (0x00021180, 0x3C018018, 0xA4229D58, 0x3C018018, 0xA4229D5A,
                     0x3C018018, 0xA4229D1A, 0x3C018018, 0xA4229D18),
        0x800C7D1C: (0x3C02801F, 0x3C018018, 0xAC229DD0),
        # 16 sectors of 512 words fill the CD buffer before the ready byte is set.
        0x800C8770: (0x0C054673, 0x34050200),
        0x800C87A0: (0x24420800, 0x3C018018, 0xAC229DD8, 0x34020010, 0x14620008),
        0x800C87C8: (0x34020001, 0x3C018018, 0xA0229D00),
        # The four channel paths write frame flags and upload the selected half.
        0x800C8198: (0xA0440001, 0x24630010, 0x28624000, 0x1440FFF8),
        0x800C81B4: (0x34041010, 0x34030006, 0x0C058BEA, 0xA0430001,
                     0x3C048018, 0x8C849DD0, 0x0C058BF9, 0x34054000, 0x34020004, 0x3C018018, 0xA0229C04),
        0x800C8220: (0xA0444001, 0x24630010, 0x28624000, 0x1440FFF8, 0x34020006),
        0x800C823C: (0x34049010, 0x0C058BEA, 0xA0624001, 0x3C048018, 0x8C849DD0,
                     0x34054000, 0x0C058BF9, 0x24844000, 0x34020005, 0x3C018018, 0xA0229C04),
        0x800C84C4: (0xA044FFF1, 0x24630010, 0x28624000, 0x1440FFF8),
        0x800C84E0: (0x34045010, 0x34030003, 0x0C058BEA, 0xA0433FF1, 0x3C048018,
                     0x8C849DD0, 0x0C058BF9, 0x34054000, 0x34020009, 0x3C018018, 0xA0229C04),
        0x800C85F4: (0xA044FFF1, 0x24630010, 0x28624000, 0x1440FFF8, 0x34020003),
        0x800C8610: (0x3404D010, 0x0C058BEA, 0xA0627FF1, 0x3C048018, 0x8C849DD0,
                     0x34054000, 0x0C058BF9, 0x24844000),
        0x800C86D4: (0x3402000A, 0x3C018018, 0xA0229C04),
        # Descriptor, address and block count route through DMA4.
        0x8016300C: (0x0C058746, 0x02002821),
        0x80161D4C: (0x34040002, 0x0C05869C, 0x00A22804, 0x0C05869C, 0x34040001,
                     0x34040003, 0x02202821, 0x0C05869C, 0x02003021),
        0x80161AE8: (0xA46201A6,),
        0x80161CC0: (0xACA40000,),
        0x80161CD4: (0x00021400, 0x34420010, 0xAC620000),
        0x80161CF0: (0x34C60201,),
        0x80161D08: (0xAC460000,),
        0x80178768: (0x1F801C00, 0x1F8010C0, 0x1F8010C4, 0x1F8010C8),
    })
    assert CHUNK == 0x4000
    assert CHUNK*2 == 16*0x800
    assert (CHUNK//64 << 16) | 16 == 0x01000010


def check():
    check_source_paths()
    rows = resources(); cases = 0
    unique = {r['path']: r for r in rows}
    counts = Counter(); total = 0
    for row in unique.values():
        data = extract(row['lba'], row['size'])
        assert len(data) % (CHUNK * 2) == 0
        assert all(h >> 4 <= 4 and h & 15 <= 12 for h in data[::16]), row['path']
        flags = Counter(data[1::16]); counts.update(flags); total += len(data)
        assert flags[6] == flags[3] == 1 and set(flags) == {2, 3, 6}
        assert data[-15] == 3
        assert data[1::16].index(6) % (CHUNK // 16) == 0
        cases += 1
    assert total == 288423936 and counts == {2:18026362, 6:67, 3:67}
    assert len(rows) == 69
    for row in rows:
        address = 0x80164E68 + 12*row['index']
        record = struct.unpack_from('<I4H', M.body(), address-M.MBASE)
        assert record == tuple(row[field] for field in ('lba', 'rate', 'loop_sector', 'end_sector', 'volume'))
    assert M.mword(0x80164E68 + 12*67) == 0

    row = next(r for r in rows if r['index'] == 29)
    raw = extract(row['lba'], 4*CHUNK)
    assert channel_bytes(raw) == (raw[:CHUNK]+raw[2*CHUNK:3*CHUNK],
                                  raw[CHUNK:2*CHUNK]+raw[3*CHUNK:])

    # Exercise interleaving and predictor carry with generated, distinct inputs.
    chunks = [make_block(9, 1, [index, 0, 8, 0]*7)*(CHUNK//16) for index in (1, 2, 3, 4)]
    synthetic = b''.join(chunks)
    left = reference_decode(chunks[0]+chunks[2])
    right = reference_decode(chunks[1]+chunks[3])
    assert pcm(synthetic) == b''.join(struct.pack('<hh', a, b) for a, b in zip(left, right))
    try:
        channel_bytes(synthetic[:-16])
    except ValueError:
        pass
    else:
        raise AssertionError('accepted partial channel chunk')
    print(f'PASS: static .8 stream and DMA paths, {cases} files, {len(rows)} records, '
          f'{total//16:,} source blocks and synthetic stereo decode')


if __name__ == '__main__':
    check()

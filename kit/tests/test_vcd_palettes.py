#!/usr/bin/env python3
"""Static VCD room, palette upload and tile material checks."""
from collections import Counter
from hashlib import sha256
from pathlib import Path
import struct
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from area_tile_materials import load_room_materials
from export_first_room import source
import maindec as M
from psx_vram import PsxVram, clut_base, clut_encode, rgb555_to_rgb888
from test_canonical_start import assert_main_words

BASE = 0x80010000


def check_source_paths():
    spans = (
        (0x80132044, 0x80132280, 'e1b351dab6bbf73e31faf583cd56e290a2d874739b93f9fc98bac459d0f89839'),
        (0x800C36A4, 0x800C36D4, 'a381e61647339ddd95654f18a8c438caac3a61d2f3997101855e6e22d29298cf'),
        (0x800C3704, 0x800C3800, '42b99baa1e5cf53f783b715a34cd95719c02485b71f0b00062e94c3bdcc04a66'),
        (0x800C3C5C, 0x800C3CC8, '66c67c5485c665926ca606c9ba17d5854730076841868ec95376651e72445dc6'),
        (0x800C42F0, 0x800C4514, '50657a87221d1dd6d4d68de68271542fb2bdb31b8cb7d906645b2011e1def6fa'),
        (0x800C4514, 0x800C4594, '48b272af5ece67ba8a6afe10040226ae7c7fd5f0c3c4f32dae7cbcd0474b9abe'),
        (0x8014ABD4, 0x8014ABEC, '879cc65128f4db04b58c281f0867c888d51875da3e7ff5bbb309a1595a4f2457'),
    )
    for start, end, digest in spans:
        assert sha256(M.body()[start-M.MBASE:end-M.MBASE]).hexdigest() == digest, hex(start)
    assert_main_words({
        # Select and publish the room's section, then install its continuation.
        0x80132080: (0x00021100, 0x00431021, 0x8C430000, 0x3C018018, 0xAC22BFC0,
                     0x3C018018, 0xAC23BF98, 0x90420005, 0x8C830004, 0x00021080, 0x00431021, 0x8C430000),
        0x801320C4: (0xAC23AAE4,),
        0x8013216C: (0x0C030E79, 0x00002021),
        0x800C39E4: (0x3C018018, 0xA0249038, 0x03E00008, 0),
        0x8013218C: (0x0C030DC1, 0, 0x3C018018, 0xAC22AF70, 0x0C030DB5),
        0x80132244: (0x3C018018, 0xAC20B7FC, 0x00111880, 0x3C028013, 0x24422280,
                     0x3C018018, 0x2421DA90, 0x00230821, 0xAC220000),
        # The queue and palette banks follow distinct pointer tables.
        0x800C36B0: (0xAC209028,),
        0x800C371C: (0x0C030B4C, 0x34040034),
        0x800C372C: (0x0C030E8D, 0xA2220006, 0x92230004, 0xA2220007),
        0x800C3A34: (0x3C028018, 0x80429038, 0x03E00008, 0),
        0x800C3750: (0x8C639028, 0x8E240008, 0x24620001, 0x3C018018, 0xAC229028,
                     0x00101080, 0x00441021, 0x8C420000, 0x00031880, 0x00651821, 0xAC620000),
        0x800C37A0: (0x8E22000C, 0x00101880, 0x00621821, 0x8C640000, 0x0C030F17, 0x26100001),
        0x800C37B8: (0x92220005, 0, 0x0202102A, 0x1440FFF6),
        # 256 halfwords at (0, 480 + counter), with the original source pointer.
        0x800C3C60: (0x34020100, 0xA7A20014, 0x34020001, 0xA7A20016),
        0x800C3C7C: (0x00802821, 0xA7A00010, 0x27A40010),
        0x800C3C90: (0x244201E0, 0x0C052164, 0xA7A20012),
        0x800C3CA8: (0x24420001, 0x3C018018, 0xA0229038),
        # Each page creates 64 eight-byte records. The selector supplies the CLUT row.
        0x800C37CC: (0x0C0310BC, 0x02202021, 0x02202021, 0x02402821, 0x0C031145, 0x00403021),
        0x800C4320: (0x92C80004, 0, 0xAFA80018, 0x0C030B4C, 0x00082240),
        0x800C4400: (0x8EC30010, 0x24C60140, 0x00151080, 0x00431021, 0x8C510000),
        0x800C4498: (0x92620000, 0x26940008, 0x92C50007, 0x26730001, 0x26100001,
                     0x24A501E0, 0x0C052AF5, 0x00452821, 0xA622FFFE, 0xA6200000, 0x2A020040),
        0x800C4530: (0xACA60008, 0xA4A20004, 0x8C830014),
        0x800C4594: (0xACA00030, 0x03E00008, 0xACA3000C),
    })


def check():
    check_source_paths()
    data, origin = source('/VCD.BIN')
    assert (origin['file'], origin['lba'], origin['size']) == ('DATA/06_AREA.C/VCD.BIN', 99400, 86288)

    def word(address):
        return struct.unpack_from('<I', data, address-BASE)[0]

    root = word(BASE)
    room = word(root+8)
    section = word(word(root+4)+4*data[room-BASE+5])
    assert (root, room, section) == (0x80010024, 0x80023BE0, 0x80012518)
    header = section-BASE
    assert data[header+4:header+8] == bytes((3, 15, 0, 0))
    ctable, dtable, etable, tilemap = (word(section+offset) for offset in (8, 12, 16, 20))
    assert (ctable, dtable, etable) == (0x800124C4, 0x800124DC, 0x800124D0)

    vram = PsxVram()
    palette_words = []
    for i in range(data[header+5]):
        offset = word(dtable+4*i)-BASE
        assert offset == 0x3C+i*512
        raw = data[offset:offset+512]
        vram.upload_rect(0, 480+i, 256, 1, raw)
        colors = struct.unpack('<256H', raw)
        assert tuple(vram.get_word(x, 480+i) for x in range(256)) == colors
        palette_words.append(colors)

    blobs, tile_palettes, meta = load_room_materials(data, header)
    assert meta['tilemap_offset'] == tilemap-BASE
    width, height = struct.unpack_from('<HH', data, header)
    assert set(tile_palettes) == set(struct.unpack_from(f'<{width*height}H', data, tilemap-BASE))
    selectors = []
    for page, (offset, _) in enumerate(blobs):
        assert offset == word(ctable+4*page)-BASE
        source_selectors = word(etable+4*page)-BASE
        raw = data[source_selectors:source_selectors+64]
        assert len(raw) == 64 and max(raw) < len(palette_words)
        assert meta['selectors'][str(page)] == list(raw)
        selectors.extend(raw)
    assert Counter(selectors) == {0: 12, 10: 180}
    for code, index in enumerate(selectors):
        clut = clut_encode(0, 480+index)
        assert clut == (480+index)*64 and clut_base(clut) == (0, 480+index)
        if code in tile_palettes:
            colors = [rgb555_to_rgb888(value) for value in palette_words[index]]
            assert tile_palettes[code] == colors

    print('PASS: static VCD room path, 15 palette uploads, 192 CLUT selectors, and three queued pages')


if __name__ == '__main__':
    check()

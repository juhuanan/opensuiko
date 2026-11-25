#!/usr/bin/env python3
"""Independent disc extraction and instruction witnesses for the IC CLUT chain."""
import hashlib
from pathlib import Path
import struct
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import disc
from ikki_clut_trace import trace


def main():
    expected = {
        ('PAN_TEO.BIN', 'PAN'): (161871, 140104, 0x11528, 0x10F40),
        ('PAN_TEO.BIN', 'TEO'): (161871, 140104, 0x10F28, 0x10940),
        ('SHU_KWA.BIN', 'SHU'): (161940, 138612, 0x11634, 0x10F6C),
        ('SHU_KWA.BIN', 'KWA'): (161940, 138612, 0x11C34, 0x1164C),
        ('SHU_TEO.BIN', 'SHU'): (162008, 138712, 0x11698, 0x10FD0),
        ('SHU_TEO.BIN', 'TEO'): (162008, 138712, 0x109B8, 0x103D0),
    }
    records = trace()
    assert len(records) == len(expected)
    for r in records:
        lba, size, ctx, palette = expected[(Path(r['overlay']).name, r['family'])]
        b = disc.extract(lba, size)
        u32 = lambda off: int.from_bytes(b[off:off + 4], 'little')
        assert u32(u32(ctx + 12) - 0x80080000) == 0x80080000 + palette
        # Overlay init selects the load group through a signed lui/lw address.
        assert u32(0x104C) == 0x3C038009
        low = u32(0x1050) & 0xFFFF
        group_table = 0x80090000 + (low - 65536 if low & 32768 else low)
        assert u32(group_table - 0x80080000) == r['group']
        assert int(r['context_offset'], 16) == ctx
        assert int(r['palette_offset'], 16) == palette
        assert r['_palette'] == b[palette:palette + 64]
        assert r['palette_sha256'] == hashlib.sha256(b[palette:palette + 64]).hexdigest()
        assert struct.unpack_from('<H', b, palette + 4)[0] == 0x8421  # dark outline
        for off, instruction in {
            0x3870: 0x8C420154,  # shared registration / CLUT upload
            0x5644: 0x91110007,  # context[7] -> row
            0x5688: 0x34040100,  # GetClut x=256
            0x5690: 0x262501E0,  # GetClut y=480+row
            0x5694: 0x0060F809,  # jalr
            0x574C: 0xA4C8000E,  # POLY_FT4 clut, separate from tpage at +0x16
        }.items():
            assert u32(off) == instruction, (r['overlay'], hex(off))
    raw = disc.extract(17976, 757760)
    base = int.from_bytes(raw[0x18:0x1c], 'little')
    word = lambda va: int.from_bytes(raw[2048 + va - base:2052 + va - base], 'little')
    for va, instruction in {
        0x8016575C: 0x800C3500,  # vtable +0x154
        0x800C35C0: 0xA2230007,  # store allocated row in context[7]
        0x800C35D4: 0x8E22000C,  # palette pointer table
        0x800C35E4: 0x0C030F32,  # calls 0x800C3CC8
        0x800C3CD0: 0x34020100, 0x800C3CD8: 0x34020020,
        0x800C3D00: 0x244201E0, 0x800C3D04: 0x0C052164,
        0x8014ABD4: 0x00051180,  # GetClut: y << 6
        0x8014ABD8: 0x00042103,  # x >> 4
    }.items():
        assert word(va) == instruction, hex(va)
    print('IC CLUT chain: 6 independent extractions and writer/draw witnesses PASS')


if __name__ == '__main__':
    main()

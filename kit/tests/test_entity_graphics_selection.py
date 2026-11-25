#!/usr/bin/env python3
"""Entity descriptor graphics selectors and the separate image/CLUT loader."""
from hashlib import sha256
from pathlib import Path
import struct
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from disc import extract
import maindec as M
from test_canonical_start import assert_main_words


def check_object_variants():
    spans = (
        (0x800C3D38, 0x800C3D8C, '3a182477371d2ee580267e5878fd957907cc5eaf87128ce614a07351f5a6e5d1'),
        (0x800C3DAC, 0x800C3EF0, '1079af804304cf1e06ae1fb4b224335014d0c0e2220ce619b60fc6006bb394d5'),
        (0x800E1E3C, 0x800E2044, 'b7b84caf8e8fb8775f27d3de428b4e20d5b3b030fa4bcad1f78a03cb6af4e875'),
        (0x800E2044, 0x800E211C, 'b5d45cf5bbdddf7394886a9f1037d041b70cbed421d50f97ef9b42e272174cf3'),
        (0x801343B4, 0x80134470, '8c330c1efbb53885eaf671ca9e79d6bba7395fd8757527d26439dbe5910ddae7'),
        (0x800C3F80, 0x800C3FD0, 'cbc4d47a4ae058ab0363086a72a10eb67adbd4e45a650152f0187c5b0dc5a8b5'),
        (0x800C4180, 0x800C420C, '8e82bc82727ec892ae3aabe4cd0b0eb5d458c2e24ad60428fcc471cb220f2a72'),
    )
    for start, end, digest in spans:
        assert sha256(M.body()[start-M.MBASE:end-M.MBASE]).hexdigest() == digest, hex(start)
    assert_main_words({
        # Field allocation and variant lookup through the resource-local F table.
        0x800C3D54: (0x0C030B4C, 0x3404001C, 0x00408821, 0xAE300014,
                     0x02202021, 0x0C030F6B, 0x02402821),
        0x800C3DB4: (0x8C820014, 0xA0850000, 0x8C420014, 0x00052880, 0x00A21021,
                     0x8C420000, 0x8C830014, 0x90420000, 0xA0800002, 0xA0800003, 0xA0820001),
        0x800C3E04: (0x00021042, 0x30420001, 0x00C23025, 0xAC860004),
        0x800C3E38: (0x30420001, 0x00021400, 0x00C23025, 0xAC860004),
        0x800C3E74: (0x00021082, 0x30420001, 0x00021440, 0x00C23025, 0x0C030FA7, 0xAC860004),
        # Battle allocation, including two buffers of 40 bytes per F-header capacity.
        0x80165608+0x204: (0x800E1E3C,),
        0x800E1E70: (0x0C030B4C, 0x34040034, 0x00409821, 0xAE700030),
        0x800E1E84: (0x8E030014, 0x000C1080, 0x00431021, 0x8C420000, 0x0000B021, 0x90550002),
        0x800E1EA4: (0xAE750004, 0x00158080, 0x02158021, 0x001080C0, 0x0C030B4C,
                     0x02002021, 0xAE620028, 0x0C030B4C, 0x02002021, 0xAE62002C),
        0x800E1F50: (0x0C038811, 0xAE620008),
        0x800E204C: (0x8C820030, 0xA0850000, 0x8C420014, 0x00052880, 0x00A21021,
                     0x8C420000, 0x8C830030, 0x90420000, 0xA0800002, 0xA0800003, 0xA0820001),
        0x800E209C: (0x00021042, 0x30420001, 0x00621825, 0xAC830008),
        0x800E20CC: (0x30420001, 0x00021040, 0x00621825, 0xAC830008),
        0x800E20FC: (0x30420004, 0x00621825, 0x0C038847, 0xAC830008),
        # 0xFF ticks the existing middle child. Room mode 1 overwrites its draw attributes.
        0x801343D0: (0x8E04000C, 0, 0x10800020, 0x340200FF, 0x14A20005, 0,
                     0x0C031091, 0, 0x0804D100, 0, 0x0C030F6B, 0),
        0x80134400: (0x8E040008, 0x3C058017, 0x8CA51594, 0x0C0310BA, 0),
        0x80134420: (0x90430007, 0x8E11000C, 0x34020001, 0x14620005,
                     0x02202021, 0x0C0310BA, 0x340500A0, 0x34020002, 0xA2220019),
        0x80134444: (0x8E040010, 0x0C0310BA, 0x34050022, 0x8E030010, 0x34020001, 0xA0620019),
        0x800C42E8: (0x03E00008, 0xA0850018),
        # RGB modulation and two consumer draw branches.
        0x800C3FBC: (0x92420018, 0, 0xA3A20026, 0xA3A20025, 0xA3A20024),
        0x800C4180: (0x92420019, 0, 0x30420001, 0x10400012, 0x2402FD56, 0xA7A2002E),
        0x800C41A0: (0x92430000, 0x34020003, 0x1462000B, 0, 0x92240004),
        0x800C41CC: (0x000418C3, 0x00431023, 0xA7A20014),
        0x800C41D8: (0x92420019, 0, 0x30420002, 0x10400004, 0x27A40010,
                     0x3C024100, 0xAFA20010, 0xA7BE002E),
        0x800C4204: (0x0C053239,),
    })

    # Compare the source's shifts and masks for every possible F flag byte.
    def shamt(address):
        return M.mword(address) >> 6 & 31

    for flags in range(256):
        field = ((flags >> shamt(0x800C3E04)) & 1)
        field |= (flags & 1) << shamt(0x800C3E3C)
        field |= ((flags >> shamt(0x800C3E74)) & 1) << shamt(0x800C3E7C)
        battle = ((flags >> shamt(0x800E209C)) & 1)
        battle |= (flags & 1) << shamt(0x800E20D0)
        battle |= flags & (M.mword(0x800E20FC) & 0xFFFF)
        assert field == sum(mask for bit, mask in enumerate((0x10000, 0x1, 0x20000)) if flags & (1 << bit))
        assert battle == sum(mask for bit, mask in enumerate((2, 1, 4)) if flags & (1 << bit))


def check():
    exe = extract(17976, 757760)
    base = struct.unpack_from('<I', exe, 0x18)[0]

    def word(pc):
        return struct.unpack_from('<I', exe, pc - base + 2048)[0]

    anchors = {
        0x8013ACE8:0xAC22C0BC,0x8013AD1C:0xAC22C050,
        0x8013AD58:0x00031080,0x8013AD5C:0x00431021,
        0x8013AD9C:0x90850002,0x8013ADAC:0x0C030F4E,
        0x8013A854: 0xAC22AF94,
        0x8013A934: 0x0C04E9DC, 0x8013A93C: 0xAE22FFF4,
        0x8013A940: 0x0C04E9DC, 0x8013A948: 0xAE22FFF8,
        0x8013A94C: 0x0C04E9DC, 0x8013A954: 0xAE22FFFC,
        0x8013AB5C: 0x0C04E9DC, 0x8013AB64: 0xAE22FFF4,
        0x8013AB68: 0x0C04E9DC, 0x8013AB70: 0xAE22FFF8,
        0x8013AB74: 0x0C04E9DC, 0x8013AB7C: 0xAE22FFFC,
        0x8013A7B8: 0x8C431B9C, 0x8013A7C0: 0x90620000,
        0x8013A7C8: 0x14440006, 0x8013A7D0: 0x8C640028,
        0x8013A7D4: 0x0C030F4E, 0x800C3D60: 0xAE300014,
        0x8012F198: 0x0C04D1AA, 0x8012F1C0: 0xAC620008,
        0x8012F1CC: 0x0C04D1AA, 0x8012F1F4: 0xAC62000C,
        0x8012F200: 0x0C04D1AA, 0x8012F228: 0xAC620010,
        0x801346B8: 0x8C420034, 0x801346F8: 0x8C420020,
        0x80134704: 0x8C440004, 0x80134708: 0x0C04D11C,
        0x80134784: 0x8C640028, 0x80134498: 0xAE300014,
        0x8013B040: 0x8C84AF94, 0x8013B05C: 0x8C63DAA0,
        0x8013B06C: 0x90E20000, 0x8013B098: 0x90E20001,
        0x8013B134: 0x0C03136D,
        0x8013F598: 0x8C420034, 0x8013F5D4: 0x8C620000,
        0x8013F5E4: 0x8C640004, 0x8013F5F4: 0x8C650008,
        0x8013F674: 0x8C64002C, 0x8013F678: 0x8C650030,
        0x8013F680: 0x0C04FD2E, 0x8013F4E4: 0x0C030C51,
        0x8013F4FC: 0x0C04FCDF,
        0x8013F39C: 0x24420380, 0x8013F3A4: 0x34020180,
        0x8013F3AC: 0x34020020, 0x8013F3B4: 0x34020040,
        0x8013F3CC: 0x261001FE, 0x8013F3D4: 0x34020100,
        0x8013F3DC: 0x34020001, 0x8013F4A0: 0x0C053239,
    }
    anchors.update({
        0x8012EEE0:0x00022040,0x8012EEE4:0x00822021,
        0x8012EEEC:0x000420C0,0x8012EEFC:0xAC22DAA0,
        0x8012EF04:0x000420C0,0x8012EF0C:0x8E94BF98,
        0x8012EF20:0xAC20DBFC,0x8012EF28:0xAC730484,
        0x8012EF38:0x26900008,0x8012EF3C:0x26710004,
        0x8012EF40:0x9602FFFC,0x8012EF48:0x30420101,
        0x8012EF54:0x8E040004,0x8012EF58:0x0C04F638,
        0x8012EF60:0x304300FF,0x8012EF64:0x146000E0,
        0x8012F278:0xA2620000,0x8012F2D0:0xAE240000,
        0x8012F2DC:0x26730008,0x8012F2E4:0x26310008,
        0x8012F2E8:0x14620007,0x8012F300:0x0804BCE6,
        0x8012F308:0x14620023,0x8012F334:0xA0550014,
        0x8012F358:0xAC400008,0x8012F35C:0xAC40000C,
        0x8012F360:0xAC400010,0x8012F364:0xA2750000,
        0x8012F36C:0xAE200000,0x8012F380:0x24420001,
        0x8012F388:0xAC22DBFC,0x8012F39C:0x26100018,
    })
    anchors.update({
        0x800C3DB4:0x8C820014,0x800C3DBC:0x8C420014,
        0x800C3DC0:0x00052880,0x800C3DC8:0x8C420000,
        0x800C3DD0:0x90420000,0x800C3DDC:0xA0820001,
        0x800C3E9C:0x8C830014,0x800C3EA4:0x8C630014,
        0x800C3EB0:0x8C430000,0x800C3EB8:0x24630004,
        0x800C3EC0:0x00021040,0x800C3EC8:0x90450001,
        0x800C3ECC:0x90420000,0x800C3ED4:0xA0850003,
        0x800C3ED8:0x8C630010,0x800C3EEC:0xAC820010,
        0x800C4260:0x90820003,0x800C426C:0xA0820003,
        0x800C427C:0x90820002,0x800C4280:0x90830001,
        0x800C42CC:0xA0820002,0x800C42D0:0x0C030FA7,
    })
    anchors.update({
        0x800C49E4:0x8C501B9C,0x800C4A14:0xAE03001C,
        0x800C4AB4:0x8E040028,0x800C4ABC:0x02242021,
        0x800C4AC0:0x0C0311CF,0x800C4AC4:0xAE040028,
        0x800C47D0:0x8C820014,0x800C47D4:0x84830002,
        0x800C47DC:0x00A21021,0x800C47E4:0xAC820014,
        0x800C47F4:0x8C620000,0x800C47FC:0x00A21021,
        0x800C4800:0xAC620000,0x800C4810:0x1440FFF5,
    })
    # Complete lookup body: pointer equality, not a tag-byte dispatch.
    lookup = [
        0x3C028018,0x2442BD74,0x1482000C,0x27BDFFF8,
        0x3C028018,0x2442DBD8,0x0804BE29,0,
        0x3C028018,0x8C42BE20,0,0x8C430484,
        0x000510C0,0x0804BE29,0x00431021,0x3C028018,
        0x8C42DBFC,0,0x1840000B,0x00002821,
        0x00403021,0x3C038018,0x8C63DAA0,0,
        0x1064FFEF,0,0x24A50001,0x00A6102A,
        0x1440FFFA,0x24630018,0x00001021,0x03E00008,
        0x27BD0008,
    ]
    assert [word(pc) for pc in range(0x8012F828,0x8012F8AC,4)] == lookup
    for pc, expected in anchors.items():
        assert word(pc) == expected, hex(pc)
    # The producer's s1 is record+14, so its three pointer stores resolve to
    # exactly the same+08/+0C/+10 fields used by area entities.
    for start in (0x8013A93C, 0x8013AB64):
        offsets = [(word(start + i * 12) & 65535) - 65536 + 0x14 for i in range(3)]
        assert offsets == [8, 12, 16]
    assert [word(pc) & 65535 for pc in (0x8012F1C0, 0x8012F1F4, 0x8012F228)] == [8, 12, 16]
    assert (word(0x8013F3AC) & 65535) * (word(0x8013F3B4) & 65535) * 2 == 4096
    assert (word(0x8013F3D4) & 65535) * (word(0x8013F3DC) & 65535) * 2 == 512
    # Disc offsets are read directly, independently of G.probe's section walk.
    import play_sprite_geometry as G
    sequences = pairs = 0
    for row in G.play_files():
        data = extract(row['lba'], row['size'])
        section = struct.unpack_from('<I', data, 0x28)[0]
        draw_count, sequence_count = struct.unpack_from('<HH', data, section)
        table = struct.unpack_from('<I', data, section+0x14)[0]
        parsed = G.probe(Path(row['path']).name, data)['sections'][1]
        assert (parsed['name'], parsed['sec_off'], parsed['f_tab'], parsed['a'], parsed['b']) == (
            'S2', section, table, draw_count, sequence_count)
        assert sequence_count==4
        for index in range(sequence_count):
            pointer = struct.unpack_from('<I', data, table+4*index)[0]
            count = data[pointer]
            assert count==4 and pointer+4+2*count<=len(data)
            for step in range(count):
                draw, duration = data[pointer+4+2*step:pointer+6+2*step]
                assert draw<draw_count and 0<duration<256
                pairs += 1
            sequences += 1
    assert (sequences,pairs)==(312,1248)
    check_object_variants()
    print(f'PASS: static constructor and draw paths, 256 F flag bytes; {len(anchors)} descriptor/character/image/CLUT anchors; '
          'complete33-word entity-pointer lookup; 312 S2 sequences/1248 timed pairs; image/CLUT uploads')


if __name__ == '__main__':
    check()

#!/usr/bin/env python3
"""Static controller, tone routing, ADSR and reverb-register contracts."""
from collections import Counter
from hashlib import sha256
import json
from pathlib import Path
import struct
import sys

KIT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(KIT / 'tools'), str(KIT / 'tools/seq')]
from disc import extract
import maindec as M
import pqes_clean as P
import render_seq as R
from reverb import disc_preset
from spu import Envelope
from test_canonical_start import assert_main_words
import vab_tones as V


def check_controller_paths():
    spans = (
        (0x8015B9BC, 0x8015BAD4, '53709ac1298bc1b597e9560f747a906134e27facd44a52ae919a51307b904e2b'),
        (0x8015BB50, 0x8015BEEC, 'dfef02f20f99432411ffabe9abf4615c892d0b8bf0a3bc054613c52cfa4c8c1e'),
        (0x8015C398, 0x8015C4CC, 'f6715a44bf47dc149e16fb67f09f7108010c8efdecf5302b61afbe0fcf247de9'),
        (0x80155548, 0x80155618, '17073457e60222d19449f3fb54b2d533ec506411af0e86012a4151dd9c13ae3b'),
        (0x80157720, 0x80157BE0, 'f676377bdbf5fdb3c08e5f2da830dc455881b29746a0a8b21e44cf8c510e25fb'),
        (0x8015A654, 0x8015A6F8, '0b5f3decd9681bebb12a505b79206e2d630b53067b5f238c84c66a7ea4043f28'),
        (0x8015A708, 0x8015A7A0, '1e53c3ed1fc23ca56a0e882303db2a8a759022cefaacfdfddc4bb399d161aa69'),
        (0x80160040, 0x80160550, 'c1797cc4e64cf816b76c97396fb86d16734d0aaf686ea670e8b073541b7e64c6'),
    )
    for start, end, digest in spans:
        assert sha256(M.body()[start-M.MBASE:end-M.MBASE]).hexdigest() == digest, hex(start)

    handlers = {6: 0x8015BC10, 7: 0x8015BC30, 10: 0x8015BCAC, 64: 0x8015BDAC,
                91: 0x8015BDF8, 98: 0x8015BE0C, 99: 0x8015BE2C}
    assert_main_words({0x800C2358 + 4*cc: (branch,) for cc, branch in handlers.items()})
    assert_main_words({
        # Nonzero note-on scales velocity and remembers it. Zero velocity routes to note-off.
        0x8015BA20: (0x8442004E, 0x322900FF, 0x01220018, 0x00001812, 0x3C028102, 0x34420409,
                     0x00620018, 0x00001010, 0x00431021, 0x00021183, 0x00031FC3, 0x00435823),
        0x8015BA58: (0x906A0017, 0x10400017, 0x00C03821, 0x1120000E, 0x00052200, 0x01042025),
        0x8015BA88: (0xAFA20010, 0x0C055DC8, 0xAFAA0014, 0x322200FF, 0x08056EAF, 0xA60200A8),
        0x8015BAB4: (0x0C055EF8, 0x30E700FF),
        # CC7 and CC10 update volume/pan for the current sequence, bank and program.
        0x8015BC3C: (0xA452004E, 0x868200A8, 0, 0x02420018),
        0x8015BC74: (0x8685004C, 0x9066002C, 0x90620017, 0x00902025, 0xAFA20010),
        0x8015BC98: (0x0C056118, 0x00E83823),
        0x8015BCBC: (0xA0D20017, 0x868300A8, 0x8442004E, 0, 0x00620018),
        0x8015BCF4: (0x8685004C, 0x90C6002C, 0x00902025, 0xAFB20010),
        0x8015BD14: (0x0C056118, 0x00E33823),
        # CC64 stores one global halfword. Voice setup adds it to the next ADSR2.
        0x8015BDAC: (0x2E420040, 0x10400005, 0, 0x0C0576E3, 0, 0x08056FAB, 0x00152400, 0x0C05769B),
        0x8015DA6C: (0x34020002, 0x3C018018, 0xA422BDD4, 0x03E00008, 0),
        0x8015DB8C: (0x3C018018, 0xA420BDD4, 0x03E00008, 0),
        0x80156AB0: (0x3C018018, 0xA420BDD4),
        0x80155578: (0x84A30000, 0x94420010, 0x00031840, 0x3C018018, 0x2421A3D8, 0x00230821, 0xA4220000),
        0x801555B4: (0x84A30000, 0x94420012, 0x3C048018, 0x9484BDD4, 0x00031840, 0x00441021,
                     0x3C018018, 0x2421A3DA, 0x00230821, 0xA4220000),
        0x8015560C: (0xA0220000,),
        # CC98's callback is conditional on marker 40 and a non-null slot.
        0x8015BC20: (0x0C0571C3, 0x02403021),
        0x8015BE1C: (0x0C0570E6, 0x02403021),
        0x8015BE3C: (0x0C057133, 0x02403021),
        0x8015C44C: (0x34020028, 0x14620012),
        0x8015C460: (0x3C028018, 0x2442AFB0, 0x00041980, 0x00621821, 0x00121400, 0x00022C03,
                     0x00051080, 0x00431021, 0x8C420000, 0, 0x10400003, 0, 0x0040F809, 0x30C600FF),
        # Inclusive tone range, no-match bypass, and allocation loop past a failed slot.
        0x80157884: (0x90820006, 0x3C038018, 0x9063C146, 0, 0x0062102B, 0x1440000E, 0,
                     0x90820007, 0, 0x0043102B, 0x14400009, 0x30C200FF),
        0x801578C4: (0x90840016, 0x01031821, 0xA0440000, 0xA0650000),
        0x801578F8: (0x104000AB, 0x00008821),
        0x80157988: (0x90620001, 0, 0xA202FFFC),
        0x801579A8: (0x0C055323, 0xA202FFFB),
        0x801579C4: (0x10600073, 0xA6020002),
        0x80157B94: (0x26310001, 0x322200FF, 0x0052102B, 0x1440FF5A, 0x322300FF),
    })

    # Same signed multiply-high quotient used by the three controller paths and the depth wrapper.
    for address in (0x8015BA30, 0x8015BC50, 0x8015BCD4, 0x8015A708):
        multiplier = ((M.mword(address) & 0xFFFF) << 16) | (M.mword(address+4) & 0xFFFF)
        assert multiplier == 0x81020409
    multiplier -= 1 << 32
    products = {velocity*volume for velocity in range(128) for volume in range(128)}
    products.update(value*32767 for value in range(128))
    for product in products:
        multiply_high = product*multiplier >> 32
        assert (multiply_high+product) >> 6 == product//127

    data = extract(22410, 71162)
    assert P.TRACKS == R.TRACKS
    for start, end in P.TRACKS:
        blob = data[start:end]
        independent = P.parse_track(blob)
        assert independent['err'] is None
        assert independent['bytes_used'] == independent['bytes_total'] == len(blob)-15
        controls = independent['controls']
        assert controls == R.parse_track(blob)[4]['controls']
        assert not any(cc in (64, 91) for _, _, cc, _ in controls)
        assert [(cc, value) for _, _, cc, value in controls if cc in (6, 98, 99)] == [
            (99, 20), (6, 127), (99, 30)]


def check_tones():
    files = json.loads((KIT / 'data/catalogs/extracted/iso_files.json').read_text())
    notes_checked = layered = 0
    release_codes = Counter()
    for bank in V.BANKS:
        row, = (item for item in files if item['path'].endswith('/'+bank+'.VA'))
        va = extract(row['lba'], row['size'])
        programs, tones, samples = V.parse_header(va)
        attrs, _ = V.parse_programs(va, programs)
        _, _, parsed = V.find_tone_table(va, tones, programs, samples, attrs)
        for block in range(programs):
            start = 0x820 + block*512
            owner = int.from_bytes(va[start+20:start+22], 'little')
            count = va[0x20+16*owner]
            raw = [va[start+32*i:start+32*(i+1)] for i in range(count)]
            assert 0 < count == len(parsed[owner])
            for note in range(128):
                source = [(i, tone[22], tone[1]) for i, tone in enumerate(raw)
                          if not (note < tone[6] or tone[7] < note)]
                decoded = [(i, tone['vag']+1, tone['mode']) for i, tone in enumerate(parsed[owner])
                           if tone['min'] <= note <= tone['max']]
                assert source == decoded, (bank, owner, note)
                notes_checked += 1
                layered += len(source) > 1
            for tone, decoded in zip(raw, parsed[owner]):
                adsr1, adsr2 = struct.unpack_from('<HH', tone, 16)
                assert (adsr1, adsr2) == (decoded['adsr1'], decoded['adsr2'])
                release_codes[adsr2 & 63] += 1
    assert (notes_checked, layered) == (4224, 48)
    assert release_codes == {0:19,4:2,7:3,9:3,10:4,11:3,12:6,13:4,14:3,32:1,44:2,45:4}

    for code in release_codes:
        shift = code & 31
        cycle, delta = 1 << max(0, shift-11), -8*(1 << max(0, 11-shift))
        level, expected = 32767, 0
        while level > 0:
            level = max(0, level+((delta*level) >> 15 if code & 32 else delta))
            expected += cycle
        envelope = Envelope(0, code)
        envelope.level = 32767
        envelope.key_off()
        actual = 0
        while envelope.level > 0:
            envelope.step()
            actual += 1
        assert actual == expected, (code, actual, expected)
        if code == 45:
            assert actual == 44528


def check_reverb():
    assert_main_words({
        0x800C55FC: (0x0C056995, 0x34040003),
        0x8015A68C: (0xAC22AF9C,),
        0x8015A6AC: (0xAC22AFA0,),
        0x8015A6CC: (0x2484AF9C, 0x0C058010, 0),
        0x8015BDF8: (0x02402021, 0x0C0569C2, 0x00802821),
        0x8015A718: (0x000433C0, 0x00C43023, 0x00C30018),
        0x8015A730: (0x00053BC0, 0x00E53823, 0x00E30018),
        0x8015A768: (0xA422AFA4,),
        0x8015A784: (0xA422AFA6, 0x0C058010),
        0x80160428: (0xA4430184,),
        0x8016045C: (0xA4430186,),
        0x801604B4: (0x0C058154, 0x27A40010),
        0x801604D8: (0x340400D1, 0x3C058018, 0x8CA587E4, 0x0C058782, 0x00003021),
        0x80161E08: (0x14C00008, 0x00041040, 0x3C038018, 0x8C638768, 0, 0x00431021, 0xA4450000),
        0x80178768: (0x1F801C00,),
        0x80160550: (0x8C850000, 0, 0x2CA60001),
        0x80160A18: (0x03E00008, 0),
    })

    # Decode each unrolled mask test and its source and MMIO halfword offsets.
    pc = 0x8016055C
    for index in range(32):
        if index < 16:
            gate = (0x14C00003, 0x30A20000 | (1 << index), 0x10400006, 0)
        elif index < 31:
            gate = (0x14C00004, 0x3C020000 | (1 << (index-16)), 0x00A21024, 0x10400006, 0)
        else:
            gate = (0x14C00003, 0, 0x04A10006, 0)
        upload = (0x3C038018, 0x8C638768, 0x94820004+2*index, 0, 0xA46201C0+2*index)
        assert_main_words({pc: gate + upload})
        pc += 4*(len(gate)+len(upload))
    assert pc == 0x80160A18

    work_starts = (0xFFFE, 0xFB28, 0xFC18, 0xF6F8, 0xF204, 0xEA44, 0xE128, 0xCFF8, 0xCFF8, 0xF880)
    assert_main_words({0x80178C3C: work_starts})
    for kind, work_start in enumerate(work_starts):
        offset = 0x80178C8C-M.MBASE+68*kind
        mask, *registers = struct.unpack_from('<I32H', M.body(), offset)
        assert mask == 0
        assert disc_preset(kind) == (registers, work_start)
    studio_medium = tuple(int(value, 16) for value in (
        '00B1 007F 70F0 4FA8 BCE0 4510 BEF0 B4C0 '
        '5280 4EC0 0904 076B 0824 065F 07A2 0616 '
        '076C 05ED 05EC 042E 050F 0305 0462 02B7 '
        '042F 0265 0264 01B2 0100 0080 8000 8000').split())
    assert disc_preset(3) == (list(studio_medium), 0xF6F8)


def check():
    check_controller_paths()
    check_tones()
    check_reverb()
    print('PASS: static controller, tone and ADSR paths, 4,224 note ranges, 12 release codes, '
          '32 reverb writes, 10 presets and four fully consumed scores')


if __name__ == '__main__':
    check()

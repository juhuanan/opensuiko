#!/usr/bin/env python3
"""Static source checks of sound cues, sequence requests and bank residency."""
from hashlib import sha256
import json
from pathlib import Path
import struct
import sys

KIT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(KIT / 'tools'), str(KIT / 'tools/seq')]
from disc import extract
import maindec as M
import render_seq as R
from test_canonical_start import assert_main_words, assert_words


def check_callers(by_name):
    assert_main_words({
        0x80165608 + 0xAC: (0x800C3104,),
        0x80165608 + 0x22C: (0x800C30E4,),
        0x800C310C: (0x0C0313F8, 0),
    })
    modules = (
        ('VB2.BIN', 0x80010000, (
            (0x80014830, 0x800148B8, '690055e3c4cbc421dcb864fc2cde1781eb436235c8e0f7231116812e5b6b17d5', (0x26, 0x27, 0x33)),
            (0x80014904, 0x8001498C, '76bf5fe9812ec9060d6fe9bac6a91f2c80644707973275099c3c223efae46aac', (0x203, 0x204, 0x40C)),
        )),
        ('VB5B1.BIN', 0x80010000, (
            (0x800150F8, 0x80015180, 'fbc5150e6a233d95511e3f834fb5862fda9ca652c5ebda4454782f0f6e3f98f9', (0x26, 0x27, 0x33)),
            (0x800151CC, 0x80015254, '2e08a0bfa2fa8734d3d5e5c7dc3e8d91aece175449f706361ea51a6cd83a311b', (0x203, 0x204, 0x40C)),
        )),
        ('BATH.BIN', 0x80080000, (
            (0x80080E48, 0x80080F10, 'ace6dc42a90614f26fe7d42c9e4e14a439a98cda87507f979e70969cd4541497', (0x15, 0x11, 0x26, 0x27)),
            (0x80080F10, 0x80080F9C, '135a582d67ce5f4069fc5e687c58e98e368acc0fcc69d64b7442dc83fb201ce2', (0x203, 0x204)),
        )),
        ('BOOKS.BIN', 0x80080000, (
            (0x800809C8, 0x80080A48, '8a4ddc7709936356bdabdeca2e1cd7a05a89174514826f0077be75c68f0ecef1', (0x26, 0x27)),
            (0x80080A48, 0x80080AD4, 'd8bce120455b4d1d86eb1ec5ee8242c3dc7c86f4909d725ec9b1568f3af4a848', (0x203, 0x204)),
        )),
        ('WALL.BIN', 0x80080000, (
            (0x80080870, 0x800808E0, 'c6f8d043a59ec496bb5bd6416bb4a51e0c212f569a475d905e6313444db27b0b', (0x203, 0x204)),
        )),
    )
    for name, base, spans in modules:
        file = by_name[name]
        image = extract(file['lba'], file['size'])
        assert base <= struct.unpack_from('<I', image)[0] < base + len(image), name
        for start, end, digest, expected in spans:
            body = image[start-base:end-base]
            assert sha256(body).hexdigest() == digest, (name, hex(start))
            words = tuple(word for (word,) in struct.iter_unpack('<I', body))
            assert words.count(0x2C420003) == 1  # gs+0x34 recruitment tier < 3.
            commands = [words[i + 1] for i in range(2, len(words) - 1)
                        if words[i-2] == 0x8C4200AC and words[i] == 0x0040F809]
            assert commands == [0x34040000 | command for command in expected], (name, hex(start))
        if name in ('VB2.BIN', 'VB5B1.BIN'):
            for start, *_ in spans:
                assert_words(image, base, {start + 0x0C: (0x90420542, 0, 0x14400016)})
        elif name in ('BATH.BIN', 'BOOKS.BIN'):
            wait = spans[1][0]
            assert_words(image, base, {
                wait - 0x20: (0x3C028008, 0x24420000 | (wait & 0xFFFF), 0xAE020000),
                wait + 0x1C: (0x8C42022C, 0, 0x0040F809),
                wait + 0x2C: (0x14400062 if name == 'BATH.BIN' else 0x14400023,),
            })
        else:
            assert_words(image, base, {0x80080884: (0x90620037, 0, 0x10400014)})


def check_requests():
    for start, end, digest in (
        (0x800C4FE0, 0x800C50E8, 'faed2b57b2f619bda85bca9a978fc18ba4425ccb1a0d822900eb40bf9a87b277'),
        (0x800C512C, 0x800C53C0, '9fd55a4a7462f4a8f968f80b8ee6fece3b6fca458293bcc807bb2ed3f8731b02'),
        (0x800C60D0, 0x800C6168, '067c508091f3c64d6a1c2e15a4df059873a91ace9b56802bc429108364452ba2'),
        (0x800C6174, 0x800C6268, '870a748c4d5b3c60d5a18256eaf8d28702770970cb1520ed60481bdf01a0e64a'),
        (0x800C6288, 0x800C6374, '3f021af33a4f36050b763a38af91c6c510732b5010083c95e6e90e4b8c37a717'),
        (0x800C70A4, 0x800C7228, '8f353cf033442edf740b6f5eb41fe194f142dc5547e18c516f55c82858271156'),
        (0x800C8B70, 0x800C8C74, 'f499f59b16c7d19b0b06244615b66f7943e8790336a5cadbc8e220cc334814d4'),
        (0x80159B8C, 0x80159BBC, '3de1a1cd5c0a69292e4063c5e05b888142b373cbbe51862e56962346b5568b96'),
        (0x80157F00, 0x80157F98, '117954e5a6d16095eb75360ba638fc257e099181948987117db7a6cc9be2b510'),
        (0x8015DC9C, 0x8015DCD4, '3076d4a1e089e1deffac79a96eac2bf3b0a26692d266dba2301058a431277ffe'),
        (0x8015DB9C, 0x8015DC9C, 'ab48aa3dc47dec2aa22cf5e4e75500c102991d2750468f26bfcb2233f94d197f'),
        (0x8015E0C8, 0x8015E0F0, '63d571d9e3b768427be3a2f29846fe49b5d85879ef6fd678560c4f7b3ecbbbf0'),
        (0x8015DF5C, 0x8015E0C8, '86c97227371d23d94aff448fb6cb3b6b097df2daa0f3acaa0f6b16569ca1fda7'),
        (0x80158190, 0x801582D0, '288466ede919a7b063a6a4535e223e52a9e66eadc97b8d263791b735d46309c5'),
        (0x80159888, 0x80159A80, '59909794716844862be938161df884e55f5c825c97a35d54defeee7756250829'),
        (0x8015A708, 0x8015A7A0, '1e53c3ed1fc23ca56a0e882303db2a8a759022cefaacfdfddc4bb399d161aa69'),
    ):
        assert sha256(M.body()[start-M.MBASE:end-M.MBASE]).hexdigest() == digest, hex(start)
    assert_main_words({
        # High byte selects request class. The queue separately selects actions 1, 4 and 7.
        0x800C0800: (0x800C501C, 0x800C50D4, 0x800C5030),
        0x800C5020: (0x0C03144B,),
        0x800C5034: (0x0C031834,),
        0x800C0D54: (0x800C8BBC,),
        0x800C0D60: (0x800C8BEC,),
        0x800C0D6C: (0x800C8C2C,),
        0x800C8BBC: (0x0C03185D,),
        0x800C8BEC: (0x0C0318A2,),
        0x800C8C2C: (0x0C031D2C,),
        # Repeat cue bypasses queueing. Alternate music stops before the old score and new start.
        0x800C60DC: (0x24429BF1, 0xA0440000, 0x90430000, 0x3C028018, 0x90429BF0, 0, 0x1062001B),
        0x800C6128: (0x90429BEB, 0, 0x10400003, 0, 0x0C031C29, 0x34040005),
        0x800C6144: (0x90429BF0, 0, 0x10400003, 0, 0x0C031C29, 0x34040004, 0x0C031C29, 0x34040001),
        # Start commits both sequence channels, sets the play bit, and retires the request.
        0x800C6200: (0x24219C78,),
        0x800C620C: (0x0C0566E3, 0x00A03021),
        0x800C6230: (0x34050001, 0x0C057727, 0x00003021),
        0x800C624C: (0xA0229BF0, 0x0C031C6C),
        0x80157F4C: (0xA4650074,),
        0x80157F60: (0xA4660076,),
        0x8015DC40: (0x34420001, 0xAC620090, 0x95050074, 0x95060076, 0x34020001, 0xA5000048, 0x0C055FC0, 0xA102002B),
        # Stop covers owners 0..3 and leaves other owners and sampled envelopes alone.
        0x800C6290: (0x0C057832, 0x00002021, 0x0C057832, 0x34040001,
                     0x0C057832, 0x34040002, 0x0C057832, 0x34040003),
        0x800C62B4: (0xA0209BF0, 0x0C031C6C),
        0x8015E0D8: (0x0C0577D7,),
        0x8015E00C: (0x0C056064, 0xAC620090),
        0x801581CC: (0x2421A572, 0x00230821, 0x84220000, 0, 0x14490033),
        0x80158230: (0xA0200000,),
        # Immediate B0 resets voices. B1 restores the stored level and resets reverb depth.
        0x800C0888 + 4 * (0xB0 - 1): (0x800C52DC, 0x800C52EC),
        0x800C52DC: (0x0C0318B4,),
        0x800C52EC: (0x0C0318C9,),
        0x800C62F4: (0x34050028, 0x0C0566E3, 0x34060028, 0x0C056622, 0x00002021, 0x34040046, 0x0C0569C2, 0x34050046),
        0x800C6338: (0x84A59C14,),
        0x800C6350: (0x0C0566E3, 0x00A03021, 0x34040028, 0x0C0569C2, 0x34050028),
        0x801599D8: (0x2421A57F, 0x00220821, 0xA0200000),
        0x80159964: (0xA4820006,),
        0x80159A28: (0xA423DCDC, 0x00031827, 0x00431024, 0x3C018018, 0xA422AAD0),
        0x80159A4C: (0xA424DCE0, 0x00042027, 0x00441024, 0x3C018018, 0xA422AAD4),
    })
    levels = tuple(M.mword(pc) & 0xFFFF for pc in (0x800C61BC, 0x800C61DC, 0x800C61D0, 0x800C61D0))
    assert levels == R.START_LEVELS == (127, 100, 88, 88)


def check_bank_records(by_lba):
    for start, end, digest in (
        (0x800C7438, 0x800C74B0, 'ff5e906cee3f1b02aff8c3ec5ccc352a05d9b1a75e042c691f99db03ac44e943'),
        (0x800C74B0, 0x800C760C, '7dd4d100123ace69fce7901a58c59f4c857736c9fad9bb99ae3c83d28e75ae4b'),
        (0x8015F170, 0x8015F200, '6449f0382e725ba0bad41d013498535a0bbf56916e329218d64ae73abbbb7ea5'),
        (0x80162608, 0x80162688, 'd010917025be9cdd7a3b58e46cb086d6c73a14690d9459dbfec21f751b6dfcb1'),
        (0x801635B0, 0x801636DC, '62f2760b5f0313aa89a4362327badf37b86d710220fc1adb3cc73e5fbea8faef'),
    ):
        assert sha256(M.body()[start-M.MBASE:end-M.MBASE]).hexdigest() == digest, hex(start)
    assert_main_words({
        # Requests 0x21..0x4F enter the bank gate. Three independent busy flags refuse.
        0x800C5398: (0x3042FFFF, 0x2C42002F, 0x10400003, 0x00102400, 0x0C031D0E, 0x00042403),
        0x800C743C: (0x90429BEB,),
        0x800C7450: (0x14400012,),
        0x800C745C: (0x90429BF3, 0, 0x1440000D),
        0x800C7470: (0x26319C00, 0x92220000, 0, 0x14400007, 0, 0x0C031C29, 0x34040007),
        0x800C7490: (0xA0309CD8, 0x34020001, 0xA2220000),
        # State 1 looks up the paired record and closes its slot before the CD request.
        0x800C0B74: (0x800C7500,),
        0x800C7500: (0x0C031D62,),
        0x800C759C: (0x24634834, 0x2442FFDF, 0x00021140),
        0x800C75B0: (0xAC22AAF0, 0x90440001, 0x0C057C5C, 0),
        0x800C75CC: (0x8C44000C, 0x0C0546B5, 0x27A50010),
        0x800C75D8: (0x34040002, 0x00402821, 0x0C0324F1),
        0x800C75EC: (0x14400003, 0x34020002, 0x3C018018, 0xA0229C00),
        # Close frees the owned bank allocation and then clears slot residency and count.
        0x8015F1B8: (0x8C240000, 0x0C058982, 0),
        0x8015F1D0: (0xA0200000,),
        0x8015F1E0: (0x2442FFFF, 0x3C018018, 0xA422DC54),
        0x80162624: (0x3C028000, 0x00824025),
        0x80162658: (0x0805899B, 0xACA80000),
        0x8016266C: (0x0C058D6C,),
    })
    banks = {}
    for request in range(0x21, 0x50):
        offset = 0x80164834 - M.MBASE + 32 * (request - 0x21)
        hdr, _, va_size, va_lba, body, _, _, vb_lba = struct.unpack_from('<8I', M.body(), offset)
        assert hdr & 0xFF == 1 and body & 0xFF == 2 and hdr >> 8 == body >> 8
        va, vb = by_lba[va_lba], by_lba[vb_lba]
        assert va['size'] == va_size and va['path'].endswith('.VA')
        assert vb['path'] == va['path'][:-3] + '.VB'
        banks[request] = hdr >> 8, Path(va['path']).stem
    assert (banks[0x25], banks[0x26], banks[0x27], banks[0x33]) == (
        (1, 'ORCH'), (2, 'HNK1'), (2, 'HNK2'), (2, 'B00'))


def check():
    files = json.loads((KIT / 'data/catalogs/extracted/iso_files.json').read_text())
    files = [row for row in files if not row.get('dir')]
    check_callers({Path(row['path']).name: row for row in files})
    check_requests()
    check_bank_records({row['lba']: row for row in files})
    print('PASS: five static field cue callers, four sequence levels, 47 paired banks, stop/free and B0/B1 paths')


if __name__ == '__main__':
    check()

#!/usr/bin/env python3
"""Battle command picker: bounded raw MAIN instructions and independent input model."""
from pathlib import Path
import hashlib
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
import maindec as M
import growth_rules as GR
import q_residue as Q
from test_port_battle_picker import check_picker_source

UI,SCENE,CHAR,STATS,CURSOR,BOXES,DRAW=range(0x80200000,0x80270000,0x10000)
SLOT=3


def fixture(state=1,choice=0,keys=0,direction=0,mask=31):
    from test_vb2_dice_states import OverlayInstructions

    c=OverlayInstructions(b'');m=c.mem
    m.sw(0x80179FE8,UI);m.sw(0x8017BE3C,SCENE);m.sw(0x8017C20C,DRAW)
    m.sw(0x8017BE4C,keys);m.sw(0x8017C000,direction)
    m.sw(UI+4,state);m.sw(UI+8,choice);m.sw(UI+0x18,2);m.sw(UI+0x10,0)
    m.sw(UI+0x31C0,0);m.sw(UI+0x31A4,2);m.sw(UI+0x31A8,CHAR);m.sw(CHAR+0x1C,STATS)
    m.sb(STATS+0x4C,1);m.sw(UI+0x31E4,CURSOR)
    for i in range(8):
        m.sw(UI+0x31C4+4*i,BOXES+256*i)
        m.sh(BOXES+256*i+0x20,1);m.sb(BOXES+256*i+8,12);m.sb(BOXES+256*i+9,6)
    for i in range(5):m.sb(UI+0x31AC+i,bool(mask&(1<<i)))
    for i,actor in enumerate([1,2]):m.sw(UI+0x1C+4*i,actor);m.sw(UI+0xB4+4*i,1)
    for i,target in enumerate([3,4]):m.sw(UI+0x38+4*i,target)
    m.sw(SCENE+0x1C,2);m.sw(SCENE+0x24,4);m.sw(SCENE+0x2C,2)
    for i in range(1,5):
        b=SCENE+0xB40+84*i;m.sb(b+0x44,i);m.sb(b+0x47,0xFF);m.sb(b+0x49,4)
        m.sw(SCENE+0xF84+12*i,CHAR)
    # Explicit presentation services; controller branches and writes run unchanged.
    for pc in [0x800C3104,0x80144620,0x801455B8,0x80145644,0x80146DFC,
               0x80146BB4,0x8014712C,0x80146D8C,0x800F0210,0x800F0364,
               0x800F0374,0x800EE90C,0x800EEA98,0x800EF35C,0x800EE818,
               0x800EEF58,0x800F0388,0x800F67DC]:c.hooks[pc]=0
    c.r[4]=SLOT
    return c


def invoke(c,pc):
    c.r[4]=SLOT;c.r[31]=0xFFFFFFFC
    assert c.run(pc)==0xFFFFFFFF


def check():
    check_picker_source()
    for start, end, digest in (
        (0x800E9E90, 0x800EA16C, '7b7840aa3f7144a34b6d770b1890b147d5cfbd65aece8373b67394b24a8f8886'),
        (0x800EA510, 0x800EA934, '21cc5dccd627bb6f2369a68480923ecb9ac9c5526dede13615e6f65f707fb008'),
        (0x800EEDD0, 0x800EEF58, '8002cd4f82b22dc23b7160c3b11e3c7a174f05492052e242450ea01e33dadf3a'),
        (0x800EF35C, 0x800EF40C, 'da664c08dbe65f7bd69e9edd4e747c5dbf7bf040f7b389973684c331709aede9'),
        (0x800EF40C, 0x800EF67C, '9c7823319be1d779f014fa699e26fe7daff37ffcbcdbd47eb64fd0ba28cfe136'),
        (0x800EB628, 0x800EB9CC, '982a2e1519b085c6514bc1df0483a6156b6b8433a34552cf4e804fc4e64b7891'),
        (0x800EBA48, 0x800EBB0C, '8ef75e200ccc2a0e269ab5829d58b87c13ec525b06aa39b78834fa03c8ab2d0e'),
        (0x800F428C, 0x800F42D4, 'de5508f32a2916631b25c68824bdf2f3470593ab6b10173b9c8e4d9ad6d6fc0a'),
    ):
        assert hashlib.sha256(M.body()[start-M.MBASE:end-M.MBASE]).hexdigest() == digest, hex(start)

    for pc, word in {
        # Parent callback, context allocation, eight boxes, cursor and party-order writer.
        0x800F6A80: 0x3C03800F, 0x800F6A84: 0x24639E90, 0x800F6A8C: 0x2421DA94,
        0x800F6A94: 0xAC230000, 0x800F6B54: 0x3C03800F, 0x800F6B58: 0x24639E90,
        0x800F6B60: 0x2421DA94, 0x800F6B68: 0xAC230000, 0x800F6C68: 0x8C220000,
        0x800F6C70: 0x0040F809, 0x800E9EB4: 0x340431E8, 0x800E9EB8: 0x0C030B4C,
        0x800E9EDC: 0xAC229FE8, 0x800E9F3C: 0x0C051465, 0x800E9F58: 0xAC6231C4,
        0x800E9F5C: 0x2A020008, 0x800E9F78: 0x0C05106C, 0x800E9F90: 0xAC8231E4,
        0x800E9FD0: 0x90A30044, 0x800E9FE0: 0xAC86001C, 0x800E9FE4: 0x90A20045,
        0x800E9FF4: 0x94A2004A, 0x800E9FFC: 0x30420020, 0x800EA00C: 0xAC8000B4,
        0x800EA010: 0xAC8900B4, 0x800EA104: 0x0C030B4C, 0x800EA108: 0x34041770,
        0x800EA114: 0x34041770, 0x800EA118: 0x0C030B4C, 0x800EA138: 0x2442A16C,
        # Iterator skips unavailable members, restores an enabled prior row and opens input.
        0x800EA4B0: 0x2442A510, 0x800EA5F4: 0xAC830010, 0x800EA604: 0x10400080,
        0x800EA610: 0x8C4200B4, 0x800EA618: 0x1446FFF3, 0x800EA66C: 0x0C03BB08,
        0x800EA684: 0x0C03BB74, 0x800EA84C: 0x2442B1DC, 0x800EA8A4: 0x80620047,
        0x800EA8B4: 0xAC800008, 0x800EA8D0: 0x804231AC, 0x800EA8E0: 0xAC720008,
        0x800EA8F8: 0x2442A934, 0x800EA988: 0x96030020, 0x800EA990: 0x30620001,
        # Availability uses target count, status masks and separate spell/item/Unite lists.
        0x800EEDF8: 0x8C8331A4, 0x800EEE00: 0x1860000C, 0x800EEE28: 0x30420060,
        0x800EEE38: 0xA08031AC, 0x800EEE3C: 0xA08231AC, 0x800EEE50: 0x0C03BD9F,
        0x800EEE54: 0xA05231AD, 0x800EEE88: 0x304200E0, 0x800EEE9C: 0xA07231AE,
        0x800EEEA0: 0x0C03BD03, 0x800EEEC8: 0xA06231AF, 0x800EEED0: 0x0C03BC41,
        0x800EEEF0: 0xA06231B0, 0x800EEF2C: 0xAC8231B4,
        0x800EF428: 0x9042001F, 0x800EF458: 0x94420020, 0x800EF470: 0x9442001C,
        0x800EF478: 0x30420004, 0x800EF484: 0xAC850080, 0x800EF490: 0xAC82005C,
        # Text comes from the game glyph string. Disabled rows call the shading helper.
        0x800EF398: 0x3C058017, 0x800EF39C: 0x24A5BD60, 0x800EF3A0: 0x0C051AED,
        0x800EF3B8: 0x804231AC, 0x800EF3C0: 0x14400007, 0x800EF3D8: 0x0C051C4B,
        0x800EF3DC: 0x02003021, 0x800EF3E4: 0x2A020005,
        # Target and Defend callbacks return to the command iterator.
        0x800EAB28: 0x1840004B, 0x800EAC5C: 0x34040505, 0x800EACA8: 0x9042004C,
        0x800EACB0: 0x10400007, 0x800EACD4: 0x34040505, 0x800EB840: 0xA0430049,
        0x800EB88C: 0x2463A510, 0x800EB910: 0x34040504, 0x800EB92C: 0x2463A934,
        0x800EBA88: 0xACA331C0, 0x800EBAA0: 0x90420001, 0x800EBAE4: 0x2442A510,
        # Execution consumes the same saved command through its own table.
        0x800F4134: 0x24A60B40, 0x800F42A4: 0x80430047, 0x800F42BC: 0x242113EC,
        0x800F42CC: 0x00400008, 0x800CA86C: 0x3C048018, 0x800CA870: 0x8C849E48,
        0x800EEC4C: 0x90630044, 0x800EEC74: 0x90630056,
    }.items():
        assert M.mword(pc) == word, hex(pc)
    assert [M.mword(0x800C13EC + 4 * i) for i in range(5)] == [
        0x800F42D4, 0x800F439C, 0x800F430C, 0x800F433C, 0x800F436C,
    ]
    assert GR.RECORD['weapon'][:3] == (0x44, 1, 0x800EEC4C)
    assert GR.RECORD['rune'][0] == 0x4C
    hero = Q.character_runes()[0]
    assert hero['id'] == 8 and hero['weapon'] == 1 and 'portrait' not in hero
    assert M.mword(0x80165890 + 4 * hero['weapon']) == 0x80165B30

    alphabet = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'
    text = M.body()[0x8016BD60-M.MBASE:0x8016BD80-M.MBASE].split(bytes(1), 1)[0]
    labels = [''.join(alphabet[byte - 0x11] for byte in row) for row in text.split(bytes([1]))]
    assert labels == ['Attack', 'Defend', 'Rune', 'Item', 'Unite']
    print('PASS: static picker constructor, availability, text, input, submenu and execution contracts')


if __name__ == '__main__':
    check()

#!/usr/bin/env python3
"""Old icon lead: rectangle constructor, per-frame tint and OT consumers."""
from pathlib import Path
import struct
import sys
KIT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(KIT/'tools'))
from disc import extract


def check():
    main=extract(17976,757760)[2048:]
    # Independent library constructor for the same three-word untextured packet.
    for va,w in {0x8014AF50:0x34020003,0x8014AF54:0xA0820003,
                 0x8014AF58:0x34020060,0x8014AF60:0xA0820007}.items():
        assert struct.unpack_from('<I',main,va-0x800C0800)[0]==w
    anchors={0x80081BC4:0x00111900,0x80081BD4:0x34020003,
        0x80081BD8:0xA0620003,0x80081BDC:0x34020062,
        0x80081BE0:0xA0620007,0x80081BF0:0x2402FF60,
        0x80081BF4:0xA4620008,0x80081BF8:0x2402FF88,
        0x80081BFC:0xA462000A,0x80081C00:0x34020140,
        0x80081C04:0xA462000C,0x80081C08:0x340200F0,
        0x80081C0C:0xA462000E,0x80081C1C:0x34050002,
        0x80081C2C:0x8C42006C,0x80081C60:0x8C630110,
        0x80081C68:0x0060F809,0x80081C70:0x2A220002,
        0x80081D04:0x91020004,0x80081D10:0x244200F8,
        0x80081D14:0xA1020004,0x80081D18:0xA1020006,
        0x80081D1C:0xA1020005,0x80081D2C:0x2C420009,
        0x80081D88:0xAD020000,0x80081DA4:0xACA20000,
        0x80081DC0:0xAD230000,0x80081DE0:0xAC620000}
    for lba,size in ((161871,140104),(161940,138612),(162008,138712)):
        data=extract(lba,size)
        for va,w in anchors.items():
            assert struct.unpack_from('<I',data,va-0x80080000)[0]==w,hex(va)
        def imm(va):return struct.unpack_from('<I',data,va-0x80080000)[0]&65535
        def signed(n):return n-65536 if n&32768 else n
        packet=dict(words=imm(0x80081BD4),command=imm(0x80081BDC),
                    x=signed(imm(0x80081BF0)),y=signed(imm(0x80081BF8)),
                    width=imm(0x80081C00),height=imm(0x80081C08))
        assert packet==dict(words=3,command=0x62,x=-160,y=-120,width=320,height=240)
        assert packet['command']&~2==0x60
    print('PASS: MAIN rectangle constructor and28 initializer/update/OT anchors in3 overlays; '
          '320x240 flat fade rectangle, not an icon texture packet')

if __name__=='__main__':check()

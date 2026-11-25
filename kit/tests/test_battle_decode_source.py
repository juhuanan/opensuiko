#!/usr/bin/env python3
"""Battle action H's registered outer entry and exact disc-backed decode source."""
from pathlib import Path
import struct
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from disc import extract
import battle_bin as B
import lzss


def check():
    main=extract(17976,757760)[2048:]
    def word(pc):return struct.unpack_from('<I',main,pc-0x800C0800)[0]
    anchors={
        0x800C9D10:0x3C048016,0x800C9D14:0x24843D64,
        0x800C9D18:0x3C05800A,0x800C9D20:0x34A5A000,
        0x80105094:0x3C048010,0x80105098:0x248450B4,
        0x8010509C:0x0C04817F,0x80120614:0xAC24A090,
        0x8012068C:0x8C42A090,0x80120694:0xAC620014,
        0x801050B4:0x3C02800B,0x801050B8:0x8C42A008,
        0x801050CC:0x8C420008,0x801050D4:0x8C500020,
        0x801050DC:0x8E110000,0x801050E0:0x3404403C,
        0x801050E4:0x0C030B4C,0x801050E8:0x26100004,
        0x801050F0:0xAC22A038,0x801050F4:0x02002821,
        0x801050F8:0x24460014,0x801050FC:0x0C030C51,
        0x80105100:0x02202021,0x80105114:0x24635130,
        0x80105118:0xAC830014,0x8016D978:0x8010508C,
    }
    for pc,expected in anchors.items():assert word(pc)==expected,hex(pc)
    # Both the signed RAM address and the extra C-table dereference matter.
    source_root=((word(0x801050B4)&65535)<<16)+(word(0x801050B8)&65535)-65536
    assert source_root==0x800AA008
    data=extract(18698,91451)
    section=struct.unpack_from('<I',data,source_root-0x800AA000)[0]-0x800AA000
    ctable=struct.unpack_from('<I',data,section+8)[0]-0x800AA000
    source=struct.unpack_from('<I',data,ctable+0x20)[0]-0x800AA000
    assert (section,ctable,source)==(0x3788,0x3760,0x121DC)
    size=struct.unpack_from('<I',data,source)[0]
    assert size==8377 and source+4+size<=len(data)
    plane=lzss.decode_strict(data[source+4:source+4+size])
    assert len(plane)==16384 and 0x14+len(plane)<=0x403C
    sections,atlases,errors,raw=B.parse()
    assert raw==data and not errors and sections[2]['atlas_offsets'][8]==source
    match=[a for a in atlases if a['offset']==source]
    assert len(match)==1
    # The parser's own container decode must agree with strict payload decode.
    assert match[0]['atlas']==plane
    print(f'PASS: {len(anchors)} boot/callback/decode anchors; BATTLE section2 C[8], '
          '8377 compressed bytes ->16384 bytes, independent parser agrees')

if __name__=='__main__':check()

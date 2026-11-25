#!/usr/bin/env python3
"""04_PLAY queue -> canonical decoder -> unchanged upload source and texels."""
from pathlib import Path
import json
import struct
import sys
KIT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(KIT/'tools'))
from disc import extract
import lzss
import maindec as M
import parse_04play as P
from mips_writers import dst_reg_of_word
from psx_vram import PsxVram,texpage_encode,TP_8BIT


def check():
    anchors={
        0x800DECA0:0x8E240024,0x800DECA4:0x0C030D40,
        0x800C3538:0x92220004,0x800C3558:0x8E240008,
        0x800C3570:0x8C420000,0x800C357C:0xAC620000,
        0x800C3858:0x8E240008,0x800C387C:0xAC620000,
        0x800C36E0:0x8CA59028,0x800C36E8:0x24848F88,
        0x800C36EC:0x0C030CD1,0x800C36F0:0x34064000,
        0x800C3350:0xAC248F58,0x800C3358:0xAC258F60,
        0x800C3370:0xAC228F78,0x800C3408:0x8C420000,
        0x800C342C:0x8C440000,0x800C3430:0x8E460000,
        0x800C3438:0x0C030C51,0x800C343C:0x24450004,
        0x800C3A48:0x00803821,0x800C3A58:0x80849030,
        0x800C3AEC:0x34020040,0x800C3AF4:0x34020080,
        0x800C3B18:0x00E02821,0x800C3B20:0x0C052164,
    }
    for pc,w in anchors.items():assert M.mword(pc)==w,hex(pc)
    # This is the complete interval after the decoder return through upload.
    assert [M.mword(pc) for pc in range(0x800C3440,0x800C3460,4)]==[
        0x92020000,0,0x12220002,0,0xA2110000,0x8E440000,0x0C030E91,0]
    # Audit every memory access/call in the complete uploader, including its
    # zero-pointer branch and counter update. Source a3 is never dereferenced.
    calls=[]
    for pc in range(0x800C3A44,0x800C3B54,4):
        w=M.mword(pc);op=w>>26;rs=(w>>21)&31;rt=(w>>16)&31
        if op in (32,33,34,35,36,37,38):
            assert (pc,w) in [(0x800C3A58,0x80849030),
                               (0x800C3B2C,0x90429030),
                               (0x800C3B44,0x8FBF0018)],hex(pc)
        if op in (40,41,42,43,46):
            assert rs==29 or (pc,w)==(0x800C3B3C,0xA0229030),hex(pc)
        if op==3:calls.append((pc,((pc+4)&0xF0000000)|((w&0x3FFFFFF)<<2)))
        if dst_reg_of_word(pc,w)==7:
            assert (pc,w)==(0x800C3A48,0x00803821)
    assert calls==[(0x800C3B20,0x80148590)]
    rows=json.loads((KIT/'extracted/iso_files.json').read_text())
    files=pages=texels=0;vram=PsxVram()
    for row in rows:
        if not row['path'].startswith('DATA/04_PLAY/') or not row['path'].endswith('.BIN'):continue
        data=extract(row['lba'],row['size']);parser=P.Parser(data,0);files+=1
        for si,key in [(1,'S1'),(2,'S2')]:
            header=struct.unpack_from('<I',data,0x20+4*si)[0]
            parsed=parser.parse_section(key,header)
            count=data[header+4];table=struct.unpack_from('<I',data,header+8)[0]
            assert count==parsed['c']['count']
            for i in range(count):
                off=struct.unpack_from('<I',data,table+4*i)[0]
                assert off==parsed['c']['entries'][i]['target_file_offset']
                size=struct.unpack_from('<I',data,off)[0]
                plane,used=lzss.decode_container(data[off:off+4+size])
                assert used==4+size and len(plane)==64*128*2
                vram.upload_rect(320,256,64,128,plane)
                tpage=texpage_encode(320,256,TP_8BIT)
                sampled=bytes(vram.sample_texel(tpage,x,y) for y in range(128) for x in range(128))
                assert sampled==plane,(row['path'],key,i)
                pages+=1;texels+=len(plane)
    assert (files,pages)==(78,234)
    print(f'PASS: {len(anchors)} source/queue/decode/upload anchors; complete post-decode interval '
          f'and uploader access audit; {pages} pages/{texels} unchanged sampled texels')

if __name__=='__main__':check()

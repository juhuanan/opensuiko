#!/usr/bin/env python3
"""Independent upload sources, loop palettes and texture-local UV residency."""
import hashlib
from pathlib import Path
import struct
import sys
KIT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(KIT/'tools'))
from disc import extract
import lzss
import ikki_sky_bt_clut as K
from psx_vram import PsxVram,texpage_encode


def check():
    cases={'PAN_TEO.BIN':(161871,140104,[0xDAA8,0xE8E0,0xA564],[0xE6E0,0xF404]),
           'SHU_KWA.BIN':(161940,138612,[0xCEB0,0xF630,0xA590],[0xD8D4,0x1016C]),
           'SHU_TEO.BIN':(162008,138712,[0xCF14,0xE970,0xA5F4],[0xD938,0xF494])}
    anchors={0x800818E0:0x00008821,0x800818EC:0x00118080,
        0x8008192C:0xA7A20010,0x80081930:0x34020180,
        0x80081938:0x34020020,0x80081940:0x34130040,
        0x8008196C:0x34020280,0x80081974:0x262201C0,
        0x8008197C:0x34120100,0x80081984:0x34020001,
        0x8008199C:0x8C250000,0x800819A0:0x8C420070,
        0x800819C8:0x26310001,0x800819D4:0x2A220002,
        0x800819D8:0x1440FFC2,0x80081A14:0x34020340,
        0x80081A1C:0xA7B20012,0x80081A20:0xA7B30014,
        0x80081A24:0x34020080,0x80088668:0xA213000D,
        0x80088678:0x340200C0,0x8008867C:0xA202001D,
        0x80088700:0x34040001,0x80088B68:0xA202000D,
        0x80088BF8:0xA2020025,0x80088C78:0x34040001}
    for name,(lba,size,offsets,paloffs) in cases.items():
        data=extract(lba,size)
        for va,word in anchors.items():
            assert struct.unpack_from('<I',data,va-0x80080000)[0]==word,(name,hex(va))
        got=K.embedded_uploads(name)
        assert [p['offset'] for p in got['pages']]==offsets
        assert [p['offset'] for p in got['palettes']]==paloffs
        band_offset = {'PAN_TEO.BIN':0xAE84, 'SHU_KWA.BIN':0xAEB0,
                       'SHU_TEO.BIN':0xAF14}[name]
        for va, expected in {0x80081A5C:0x8C4200E0,0x80081A64:0x0040F809,
                             0x80081A68:0x34040011,0x80081A80:0x8C42018C,
                             0x80081A84:0x3C048009,0x80081A8C:0x0040F809}.items():
            assert struct.unpack_from('<I',data,va-0x80080000)[0]==expected
        palette = data[band_offset:band_offset+512]
        assert got['band_palette']=={'offset':band_offset,'rect':[0,497,256,1],
                                     'sha256':hashlib.sha256(palette).hexdigest()}
        vram=PsxVram()
        rects=[(640,384,32,64),(704,384,32,64),(832,256,64,128)]
        for off,rect,row in zip(offsets,rects,got['pages']):
            length=int.from_bytes(data[off:off+4],'little')
            payload=data[off+4:off+4+length]
            # Independent extraction uses bare strict payload, not producer framing.
            plane=lzss.decode_strict(payload)
            assert len(plane)==rect[2]*rect[3]*2
            assert row['used']==4+length and row['rect']==list(rect)
            assert row['sha256']==hashlib.sha256(plane).hexdigest()
            vram.upload_rect(*rect,plane)
            width=rect[2]*2
            tpage=texpage_encode(rect[0],256,1)
            local_v=rect[1]-256
            for y in range(rect[3]):
                for x in range(width):
                    assert vram.sample_texel(tpage,x,y+local_v)==plane[y*width+x]
        vram.upload_rect(0,497,256,1,palette)
        for index in range(256):
            assert vram.get_word(index,497)==struct.unpack_from('<H',palette,2*index)[0]
        for i,(off,row) in enumerate(zip(paloffs,got['palettes'])):
            block=data[off:off+512]
            assert row['rect']==[640,448+i,256,1]
            assert row['sha256']==hashlib.sha256(block).hexdigest()
            vram.upload_rect(640,448+i,256,1,block)
            for k in range(256):
                assert vram.get_word(640+k,448+i)==int.from_bytes(block[k*2:k*2+2],'little')
        # Read the consumer argument/UV tables via their full signed encodings.
        def table(pc):
            imm=int.from_bytes(data[pc-0x80080000:pc-0x80080000+2],'little')
            return 0x10000+(imm-65536 if imm&32768 else imm)
        clut=table(0x800886A0)
        assert struct.unpack_from('<4I',data,clut)==(640,448,640,449)
        banduv=table(0x80088B40)
        uv=struct.unpack_from('<16I',data,banduv)
        expected_uv={'PAN_TEO.BIN':(0,64,128,64,0,96,128,96,0,32,128,32,0,64,128,64),
                     'SHU_KWA.BIN':(0,96,128,96,0,128,128,128,0,0,128,0,0,32,128,32),
                     'SHU_TEO.BIN':(0,96,128,96,0,128,128,128,0,32,128,32,0,64,128,64)}
        assert uv==expected_uv[name]
        assert all(0<=uv[i]<=128 and 0<=uv[i+1]<=128 for i in range(0,16,2))
    print('PASS: 32 raw anchors across3 overlays; 9 independent embedded decodes, '
          '9 palette rows (including band497) and73728 direct/VRAM texels agree')

if __name__=='__main__':check()

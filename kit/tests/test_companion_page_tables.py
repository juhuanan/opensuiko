#!/usr/bin/env python3
"""Companion section headers and page pointers, independently extracted."""
import json
from pathlib import Path
import struct
import sys
KIT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(KIT/'tools'))
from disc import extract
import lzss
import section_records as S


def check():
    files=json.loads((KIT/'extracted/iso_files.json').read_text())
    def read(name):
        r=next(r for r in files if r['path'].endswith('/'+name+'.BIN'))
        return extract(r['lba'],r['size'])
    cases=[('VB5A21','VB5A2',0x1ACC,[0x1AC4,0x1AC8],[0x1AE4,0x2A70]),
           ('VB5B31','VB5B3',0x930,[0x92C],[0x948])]
    for companion,owner,header,sites,pages in cases:
        data,code=read(companion),read(owner)
        assert code[0x70000:0x70000+len(data)]==data
        record=next(r for r in S.records(data) if r['off']==header)
        assert record['magic']&255==len(sites)
        assert record['ptrs'][0]==0x80080000+sites[0]
        count=data[header+4]
        table=int.from_bytes(data[header+8:header+12],'little')-0x80080000
        pointers=[int.from_bytes(data[table+4*i:table+4*i+4],'little')-0x80080000 for i in range(count)]
        assert pointers==pages and [table+4*i for i in range(count)]==sites
        for page in pointers:
            size=int.from_bytes(data[page:page+4],'little')
            blob=data[page:page+4+size]
            output,used=lzss.decode_container(blob)
            assert used==len(blob) and len(output)==16384
        print(f'PASS: {companion}: {count} page pointers in absolute section; '
              'full decode consumption and complete owner-overlay copy agree')

def check_selection():
    import maindec
    import q_art
    from event_script_reachability import walk
    files=json.loads((KIT/'extracted/iso_files.json').read_text())
    def read(name):
        row=next(r for r in files if r['path'].endswith('/'+name+'.BIN'))
        return extract(row['lba'],row['size'])
    def word(data,offset):
        return struct.unpack_from('<I',data,offset)[0]
    base=0x80010000
    def pointer(data,offset):
        result=word(data,offset)-base
        assert 0<=result<len(data)
        return result
    # Independent room/entry/section selection, without the heuristic room probe.
    a=read('VB5A2')
    root=pointer(a,0);rooms=pointer(a,root+8)
    room=rooms+4*16;assert room==0x3FB08 and a[room+4:room+6]==bytes([23,8])
    entries=pointer(a,room);entry=entries+15*24
    assert entry==0x410F0 and word(a,entry+4)&0x101
    stream=pointer(a,entry+20);assert stream==0x40870
    graph=walk(a,[stream])
    assert any(n['offset']==0x40899 and n.get('opcode')==0x47 for n in graph['nodes'])
    assert a[0x40899:0x4089C]==bytes.fromhex('4700fd')
    sections=pointer(a,root+4);section=pointer(a,sections+4*a[room+5])
    assert section==0xAA28
    resources=pointer(a,section+32)
    selected=pointer(a,resources+4*(word(a,section+28)+0))
    assert selected==0x6DA34
    roster=pointer(a,selected+12);assert word(a,roster)==1
    stats=pointer(a,roster+4)
    assert stats==0x712D4 and pointer(a,stats+44)==0x71ACC
    selectors=pointer(a,selected+8);encounter=pointer(a,selectors+4)
    assert word(a,selectors)==1 and a[encounter+4:encounter+10]==bytes([1,0,0,0,0,0])
    # Custom graphics ID0x17 is the sixteenth custom ID, hence resource slot16.
    b=read('VB5B3');root=pointer(b,0);rooms=pointer(b,root+8)
    assert rooms==0x2E0F4 and b[rooms+4:rooms+6]==bytes([130,0])
    entries=pointer(b,rooms)
    assert [i for i in range(b[rooms+4]) if struct.unpack_from('<H',b,entries+24*i+6)[0]==0x17]==list(range(79,88))
    assert all(struct.unpack_from('<H',b,entries+24*i+4)[0]&0x101 for i in range(79,88))
    section=pointer(b,pointer(b,root+4)+4*b[rooms+5]);assert section==0xA35C
    ids=pointer(b,section+52);custom=[]
    for i in range(21):
        if not word(b,ids+4*i):break
        custom.append(word(b,pointer(b,ids+4*i)))
    assert custom.index(0x17)==15
    resources=pointer(b,section+32)
    assert pointer(b,resources+4+4*15)==0x70930
    custom_record=pointer(b,ids+4*15)
    image=pointer(b,custom_record+4);palette=pointer(b,custom_record+8)
    assert (custom_record,image,palette)==(0x31464,0x718D4,0x329E0)
    image_size=word(b,image)
    decoded,used=lzss.decode_container(b[image:image+4+image_size])
    assert len(decoded)==4096 and used==4+image_size
    companion=read('VB5B31')
    assert companion[image-0x70000:image-0x70000+4+image_size]==b[image:image+4+image_size]

    # The animation-selected E piece supplies the page delta; compare q_art's
    # separate extraction, including both pages of the battle section.
    for data,header,expected in [(a,0x71ACC,{0,1}),(b,0x70930,{0})]:
        count=struct.unpack_from('<H',data,header)[0];et=pointer(data,header+16)
        raw=[]
        for i in range(count):
            piece=pointer(data,et+4*i)
            raw.extend(data[piece+10+8*k] for k in range(data[piece]))
        independent=q_art.piece_records(data,base,et,count)
        assert raw==[p['slot_delta'] for e in independent for p in e['sub_pieces']]
        assert set(raw)==expected and max(raw)<data[header+4]
    anchors={
        0x80132080:0x00021100,0x80132088:0x8C430000,
        0x8013209C:0x90420005,0x801320A0:0x8C830004,
        0x801320AC:0x8C430000,0x801320C4:0xAC23AAE4,
        0x801394F4:0x90630000,0x801394F8:0x8CA2001C,
        0x80139500:0x00622021,0x80139558:0x00041080,
        0x8013957C:0x8CA30020,0x80139588:0x8C430000,
        0x80139594:0x0C04B2EF,0x80139598:0xAC431BB4,
        0x800DDFCC:0x8C831BB4,0x800DDFE0:0xAC23C100,
        0x800DEF1C:0x8C43000C,0x800DEF28:0x8C510000,
        0x800DEFA0:0x8E24002C,0x800DEFA4:0x0C030D40,
        0x800DEFBC:0x8E24002C,0x800DEFC0:0x0C03878F,
        0x801346B8:0x8C420034,0x801346DC:0x8C420000,
        0x801346E4:0x1446000C,0x801346F8:0x8C420020,
        0x80134704:0x8C440004,0x80134708:0x0C04D11C,
        0x80134498:0xAE300014,0x801345C4:0x0C030FA7,
        0x800C3ED8:0x8C630010,0x800C3EE4:0x8C420000,
        0x8013F5D4:0x8C620000,0x8013F5E4:0x8C640004,
        0x8013F5F4:0x8C650008,0x8013F4E4:0x0C030C51,
        0x800C3538:0x92220004,0x800C3558:0x8E240008,
        0x800C356C:0x00441021,0x800C3570:0x8C420000,
        0x800C357C:0xAC620000,0x800C358C:0x1440FFF0,
        0x800E21D8:0x24420008,0x800E21E4:0x92620002,
    }
    for pc,w in anchors.items():assert maindec.mword(pc)==w,hex(pc)
    print(f'PASS: companion selection: script47/encounter1 and graphicsID0x17; '
          f'{len(anchors)} producer/consumer anchors; independent E-page deltas0/1 and0')


if __name__=='__main__':
    check()
    check_selection()

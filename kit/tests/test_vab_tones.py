#!/usr/bin/env python3
"""Independent physical-block extraction checks compact logical program routing."""
import json
from pathlib import Path
import struct
import sys
import tempfile
KIT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(KIT/'tools'), str(KIT/'tools/seq')]
from disc import extract
import vab_tones as V
import render_seq as R


def check():
    main = extract(17976,757760)[2048:]
    anchors = {
        0x80159B24:0x00051100, 0x80159B28:0x00441021,
        0x80159B3C:0x90430008, 0x80159B48:0xA023C14B,
        0x801589E8:0x00031900, 0x801589F8:0x00021140,
        0x80158A10:0x94440016, 0x80158A90:0x10800009,
        0x80155484:0x9463C15C, 0x8015548C:0x30620001,
        0x8015549C:0x2442FFFF, 0x801554A8:0x00021043,
        0x801554C4:0x9442000C, 0x801554D4:0x2442FFFF,
        0x801554E0:0x00021043, 0x801554FC:0x9442000E,
        0x80155510:0xA4220000,
    }
    for va,word in anchors.items():
        assert struct.unpack_from('<I',main,va-0x800C0800)[0]==word,hex(va)
    files = json.loads((KIT/'extracted/iso_files.json').read_text())
    fields = ('vag','center','shift','min','max','vol','pan','prior','adsr1','adsr2')
    for bank in V.BANKS:
        rec = next(r for r in files if r['path'].endswith('/'+bank+'.VA'))
        va = extract(rec['lba'],rec['size'])
        ps,ts,vs = V.parse_header(va)
        progs,_ = V.parse_programs(va,ps)
        _,_,actual = V.find_tone_table(va,ts,ps,vs,progs)
        # Extract physical blocks by their embedded owner, not program rank.
        expected = [[] for _ in range(128)]
        for block in range(ps):
            start = 0x820+block*512
            owner = int.from_bytes(va[start+20:start+22],'little')
            count = va[32+owner*16]
            for k in range(count):
                e = va[start+k*32:start+(k+1)*32]
                assert actual[owner][k]['mode']==e[1]
                assert int.from_bytes(e[20:22],'little') == owner
                expected[owner].append(dict(vag=int.from_bytes(e[22:24],'little')-1,
                    center=e[4],shift=e[5],min=e[6],max=e[7],vol=e[2],pan=e[3],prior=e[0],
                    adsr1=int.from_bytes(e[16:18],'little'),adsr2=int.from_bytes(e[18:20],'little')))
        assert [{k:t[k] for k in fields} for tl in actual for t in tl] == [t for tl in expected for t in tl]
        assert [[{k:t[k] for k in fields} for t in tl] for tl in actual] == expected
        assert sum(map(len,actual)) == ts
        artifact = dict(ps=ps,ts=ts,vs=vs,tones={str(i):tl for i,tl in enumerate(expected) if tl})
        assert json.loads((KIT/'work'/f'{bank}_tones.json').read_text()) == artifact
        vbrec=next(r for r in files if r['path'].endswith('/'+bank+'.VB'))
        assert R.BANK_SOURCES[bank]==((rec['lba'],rec['size']),(vbrec['lba'],vbrec['size']))
        body=extract(vbrec['lba'],vbrec['size'])
        for bad_va,bad_vb in ((va,body[:-16]),(va,body+b'\0'*16),
                             (va[:0x820+ps*512]+b'\1\0'+va[0x822+ps*512:],body)):
            try:R.parse_vab_bytes(bad_va,bad_vb)
            except ValueError:pass
            else:raise AssertionError('incomplete/extra bank data was accepted')
        with tempfile.TemporaryDirectory(prefix='suikoden-tones-') as tmp:
            a,b = Path(tmp)/(bank+'.VA'),Path(tmp)/(bank+'.VB')
            a.write_bytes(va);b.write_bytes(extract(vbrec['lba'],vbrec['size']))
            _,programs,_=R.parse_vab(a,b)
            assert len(programs)==128
            for program,tones in enumerate(programs):
                for tone,raw in zip(tones,actual[program]):
                    assert {k:v for k,v in tone.items() if k not in ('bank_vol','program_vol','program_pan')}==raw
                    assert (tone['bank_vol'],tone['program_vol'],tone['program_pan'])==(va[0x18],va[0x21+16*program],va[0x24+16*program])
                assert len(tones)==len(actual[program])
        for off in (0x820+20,0x820+22):
            bad=bytearray(va);struct.pack_into('<H',bad,off,65535)
            try: V.find_tone_table(bad,ts,ps,vs,progs)
            except ValueError: pass
            else: raise AssertionError('invalid owner/sample accepted')
        print(f'PASS: {bank}: {ps} occupied programs, {ts} tones, independent extraction and renderer agree')

if __name__=='__main__':
    check()

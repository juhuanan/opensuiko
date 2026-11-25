#!/usr/bin/env python3
"""Independent image extraction and fixed-byte/relocation controls for R027."""
from pathlib import Path
import copy
import hashlib
import json
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
import character_table as CT
import maindec as M
import gte_library_provenance as G


def check():
    manifest=json.loads(G.MANIFEST.read_text());report=G.verify(manifest)
    assert report=={'MAIN':{'object_matches':16,'covered_cluster_bytes':12736,'gte_words':604},
                    'SLUS':{'object_matches':12,'covered_cluster_bytes':8672,'gte_words':310}}
    bodies={'MAIN':M.body(),'SLUS':CT.image()};controls=0;symbols={}
    for row in manifest['matches']:
        base=manifest['modules'][row['module']]['base'];offset=row['address']-base
        block=bodies[row['module']][offset:offset+row['size']]
        excluded={i for start,size in row['wildcard_runs'] for i in range(start,start+size)}
        # Independent extraction uses byte indices, not the producer's run slicing.
        fixed=bytes(v for i,v in enumerate(block) if i not in excluded)
        assert hashlib.sha256(fixed).hexdigest()==row['fixed_sha256']
        changed=bytearray(block);i=next(i for i in range(len(block)) if i not in excluded)
        changed[i]^=1;assert not G.matches(changed,row);controls+=1
        if excluded:
            changed=bytearray(block);changed[min(excluded)]^=1
            assert G.matches(changed,row);controls+=1
        for label in row['labels']:
            if not label['name'].startswith(('text_','loc_')):
                symbols.setdefault((row['module'],label['name']),set()).add(row['address']+label['offset'])
    for name,address in [('RotMatrix',0x8014FCB4),('TransMatrix',0x8014F3C8),
                         ('ScaleMatrix',0x8014F3EC),('SetRotMatrix',0x8014F510),
                         ('SetTransMatrix',0x8014F5A0),('FlushCache',0x8014FA14)]:
        assert symbols[('MAIN',name)]=={address}
    assert symbols[('SLUS','RotMatrix')]=={0x8002CD10}
    assert symbols[('SLUS','FlushCache')]=={0x8002CC80}
    # The scene-specific caller is independently linked to the identified SDK entries.
    assert M.mword(0x800E14C8)==0x00021303
    for pc,name in [(0x800E1518,'RotMatrix'),(0x800E1530,'TransMatrix'),
                    (0x800E1548,'ScaleMatrix'),(0x800E1558,'SetRotMatrix'),
                    (0x800E1568,'SetTransMatrix')]:
        word=M.mword(pc);assert word>>26==3
        assert {((pc+4)&0xF0000000)|((word&0x3FFFFFF)<<2)}==symbols[('MAIN',name)]
    missing=copy.deepcopy(manifest)
    missing['matches']=[r for r in missing['matches'] if not(r['module']=='SLUS' and r['object']=='C68.OBJ')]
    try:G.verify(missing)
    except ValueError as exc:assert 'uncovered cluster' in str(exc)
    else:raise AssertionError('uncovered BIOS import accepted')
    for runs in [[[-1,1]],[[1,0]],[[1,2],[2,1]],[[0,100000]]]:
        try:G.fixed_bytes(b'abcd',runs)
        except ValueError:pass
        else:raise AssertionError('bad mask accepted')
    print(f'PASS:28 SDK object matches,914 GTE words,independent image extraction,{controls} byte/relocation controls and complete cluster coverage')


if __name__=='__main__':check()

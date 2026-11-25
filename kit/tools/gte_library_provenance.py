#!/usr/bin/env python3
"""Verify fixed PsyQ object fingerprints against disc images plus curated knowledge.

The tracked manifest contains labels, relocation masks and hashes, never SDK code.
--catalog-dir additionally audits it against the pinned external JSON catalogues.
An unmatched routine is never classified as game-owned by this tool.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct

from disc import extract

MANIFEST=Path(__file__).resolve().parents[1]/'work/gte_library_matches.json'


def fixed_bytes(block,runs):
    out=bytearray();end=0
    for start,size in runs:
        if size<=0 or start<end or start+size>len(block):
            raise ValueError('invalid relocation mask')
        out.extend(block[end:start]);end=start+size
    out.extend(block[end:])
    return bytes(out)


def matches(block,row):
    if len(block)!=row['size']:
        return False
    fixed=fixed_bytes(block,row['wildcard_runs'])
    return len(fixed)==row['fixed_bytes'] and hashlib.sha256(fixed).hexdigest()==row['fixed_sha256']


def images(manifest):
    result={}
    for name,source in manifest['modules'].items():
        raw=extract(source['lba'],source['file_size'])
        if raw[:8]!=b'PS-X EXE':raise ValueError(f'{name}: missing EXE header')
        base,size=struct.unpack_from('<II',raw,0x18)
        if base!=source['base'] or size>len(raw)-2048:
            raise ValueError(f'{name}: image bounds changed')
        result[name]=raw[2048:2048+size]
    return result


def verify_catalogues(manifest,directory):
    catalogues={};bodies=images(manifest)
    for name,source in manifest['sources'].items():
        raw=(directory/source['cache_name']).read_bytes()
        if hashlib.sha256(raw).hexdigest()!=source['sha256']:
            raise ValueError(f'{name}: reference catalogue hash changed')
        blob=hashlib.sha1(f'blob {len(raw)}\0'.encode()+raw).hexdigest()
        if blob!=source['git_blob_sha1']:raise ValueError(f'{name}: Git blob identity changed')
        catalogues[name]={row['name']:row for row in json.loads(raw)}
    for row in manifest['matches']:
        ref=catalogues[row['library']][row['object']];tokens=ref['sig'].split()
        mask={i for start,size in row['wildcard_runs'] for i in range(start,start+size)}
        if mask!={i for i,t in enumerate(tokens) if t=='??'}:
            raise ValueError('catalogue relocation mask differs')
        fixed=bytes(int(t,16) for t in tokens if t!='??')
        if (len(tokens)!=row['size'] or hashlib.sha256(fixed).hexdigest()!=row['fixed_sha256']
                or ref['labels']!=row['labels']):
            raise ValueError('catalogue object metadata differs')
        pattern=b''.join(b'.' if t=='??' else re.escape(bytes([int(t,16)])) for t in tokens)
        found=[m.start()+manifest['modules'][row['module']]['base']
               for m in re.finditer(pattern,bodies[row['module']],re.DOTALL) if m.start()%4==0]
        if found!=[row['address']]:raise ValueError('catalogue object match is not unique')


def verify(manifest=None):
    if manifest is None:manifest=json.loads(MANIFEST.read_text())
    if manifest['schema']!='suikoden-gte-library-provenance/1':raise ValueError('unsupported manifest')
    sources=images(manifest);counts={}
    for name,source in manifest['modules'].items():
        body=sources[name];base=source['base'];covered=set()
        rows=[r for r in manifest['matches'] if r['module']==name]
        for row in rows:
            offset=row['address']-base
            if offset<0 or not matches(body[offset:offset+row['size']],row):
                raise ValueError(f'{name} {row["object"]}: object fingerprint differs')
            if any(not 0<=label['offset']<row['size'] for label in row['labels']):
                raise ValueError('label outside object')
            covered.update(range(row['address'],row['address']+row['size']))
        lo,hi=source['cluster_start'],source['cluster_end']
        if not set(range(lo,hi))<=covered:raise ValueError(f'{name}: uncovered cluster bytes')
        gte=0
        for pc in range(lo,hi,4):
            word=struct.unpack_from('<I',body,pc-base)[0];op=word>>26;rs=word>>21&31
            gte+=op in [50,58] or (op==18 and (rs in [0,2,4,6] or rs>=16))
        counts[name]={'object_matches':len(rows),'covered_cluster_bytes':hi-lo,'gte_words':gte}
    return counts


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--catalog-dir',type=Path,help='optional pinned external catalogue audit')
    parser.add_argument('--json',action='store_true')
    args=parser.parse_args();manifest=json.loads(MANIFEST.read_text())
    if args.catalog_dir:verify_catalogues(manifest,args.catalog_dir)
    result=verify(manifest)
    print(json.dumps(result,indent=2) if args.json else f'PASS: PsyQ object provenance {result}')

#!/usr/bin/env python3
"""Generate per-file WAR overlay label CSVs: war_<name>_labels.csv
Columns: address,name,kind,notes
"""
import json, struct

BASE = 0x80010000
WAR_DIR = '/home/hatch/workspace/suikoden/kit/extracted/bin_overlays/DATA/16_WAR/'
OUT = '/home/hatch/workspace/suikoden/kit/work/overlays/'
FILES = ['WAR_GARA.BIN','WAR_KITA.BIN','WAR_KUWA.BIN','WAR_LAST.BIN','WAR_SCA1.BIN',
         'WAR_SCA2.BIN','WAR_SHAS.BIN','WAR_TEO1.BIN','WAR_TEO2.BIN']

nclusters = json.load(open(OUT + 'war_norm.json'))
names = json.load(open(OUT + 'war_names.json'))
cdata = json.load(open(OUT + 'war_cluster.json'))

# cluster hash -> list of (file, addr)
clust_of = {}
for h, members in nclusters.items():
    for fn, a, nn in members:
        clust_of[(fn, a)] = h

for fn in FILES:
    slug = fn.replace('WAR_', '').replace('.BIN', '').lower()
    rows = []
    for ahex in sorted(cdata['files'][fn]['funcs'].keys(), key=lambda x: int(x, 16)):
        h = clust_of.get((fn, ahex))
        if h and h in names:
            nm, nt = names[h]
        else:
            nm, nt = ('war_unnamed_' + ahex[2:], 'no cluster name')
        # disambiguate duplicate names within a file by appending address
        # (shared stubs appear at many addresses)
        dup_count = sum(1 for r in rows if r[1] == nm)
        if dup_count > 0:
            # rename the first occurrence too, for consistency
            for i, r in enumerate(rows):
                if r[1] == nm and '_0x' not in r[1]:
                    rows[i] = (r[0], f"{nm}_{r[0]}", r[2], r[3])
            nm = f"{nm}_{ahex}"
        # sanitize notes (no commas/newlines for CSV)
        nt = nt.replace(',', ';').replace('\n', ' ')
        rows.append((ahex, nm, 'F', nt))
    # dispatch table D-labels (34 slots at 0x80010000)
    data = open(WAR_DIR + fn, 'rb').read()
    words = struct.unpack('<%dI' % (len(data) // 4), data)
    for i in range(34):
        tgt = words[i]
        rows.append((hex(BASE + i * 4), f'war_dispatch_slot{i}', 'D',
                     f'slot {i} -> {hex(tgt)}'))
    rows.sort(key=lambda r: int(r[0], 16))
    path = OUT + f'war_{slug}_labels.csv'
    with open(path, 'w') as f:
        f.write('address,name,kind,notes\n')
        for a, nm, k, nt in rows:
            f.write(f'{a},{nm},{k},{nt}\n')
    print(f'{path}: {len(rows)} rows ({sum(1 for r in rows if r[2]=="F")} F, {sum(1 for r in rows if r[2]=="D")} D)')

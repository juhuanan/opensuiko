#!/usr/bin/env python3
"""Generic labeler for overlays without the event engine.
Usage: generic_label.py <bin_path> <base_hex> <prefix> <out_csv>
"""
import sys, os, re, csv, subprocess
workdir = os.path.dirname(__file__)
bin_path, base_hex, prefix, out_csv = sys.argv[1:5]
base = int(base_hex, 16)

def run_tool(name, *args):
    r = subprocess.run([sys.executable, os.path.join(workdir, name), bin_path, base_hex] + list(args),
                       capture_output=True, text=True, cwd=workdir)
    return r.stdout

print("dump...", file=sys.stderr)
dump_out = run_tool('dump.py')
print("tablescan...", file=sys.stderr)
table_out = run_tool('tablescan.py')
print("strxref...", file=sys.stderr)
str_out = run_tool('strxref.py', '6')

funcs = []
for line in dump_out.split('\n'):
    m = re.match(r'FUNC (0x[0-9a-f]+) n=\s*(\d+)', line)
    if m:
        funcs.append((int(m.group(1),16), int(m.group(2))))

# Tables
tables = []
cur_addr, cur_tgts = None, []
for line in table_out.split('\n'):
    m = re.match(r'TABLE at (0x[0-9a-f]+) n=(\d+)', line)
    if m:
        if cur_addr: tables.append((cur_addr, cur_tgts))
        cur_addr, cur_tgts = int(m.group(1),16), []
    m2 = re.match(r'\s*-> (0x[0-9a-f]+)', line)
    if m2 and cur_addr: cur_tgts.append(int(m2.group(1),16))
if cur_addr: tables.append((cur_addr, cur_tgts))
func_addrs = set(a for a,_ in funcs)

labels = []
labeled = set()
def L(addr, name, kind, notes):
    if addr in labeled: return
    labeled.add(addr)
    labels.append((addr, name, kind, notes))

# Real tables: file-start or >=2 FUNC targets
for taddr, tgts in tables:
    if taddr < base + 0x200:
        L(taddr, '%s_table_%x' % (prefix, taddr), 'D', '%d-entry table.' % len(tgts))
    else:
        hits = sum(1 for t in tgts if t in func_addrs)
        if hits >= 2 and len(tgts) >= 3:
            L(taddr, '%s_table_%x' % (prefix, taddr), 'D', '%d-entry (%d FUNC targets).' % (len(tgts), hits))

# String refs -> name functions
for line in str_out.split('\n'):
    m = re.match(r"(0x[0-9a-f]+) '(.+)'", line)
    if m:
        saddr, sstr = int(m.group(1),16), m.group(2)
        clean = re.sub(r'[^a-zA-Z0-9_]', '_', sstr)[:25].strip('_')
        # Find the ref func from next lines (handled below)
        pass

# Parse strxref properly
cur_sstr = None
for line in str_out.split('\n'):
    m = re.match(r"(0x[0-9a-f]+) '(.+)'", line)
    if m:
        cur_sstr = m.group(2)
    m2 = re.match(r'\s*ref @(0x[0-9a-f]+) in func (0x[0-9a-f]+)', line)
    if m2 and cur_sstr:
        faddr = int(m2.group(2),16)
        clean = re.sub(r'[^a-zA-Z0-9_]', '_', cur_sstr)[:25].strip('_')
        if clean:
            L(faddr, '%s_%s' % (prefix, clean), 'F', "Refs string '%s'." % cur_sstr[:40])
            cur_sstr = None  # only first

# Remaining functions
for addr, size in funcs:
    if addr in labeled: continue
    if size <= 4:
        L(addr, '%s_ret_%x' % (prefix, addr), 'F', '%d-insn trivial.' % size)
    else:
        L(addr, '%s_func_%x' % (prefix, addr), 'F', '%d-insn.' % size)

with open(out_csv, 'w', newline='') as f:
    w = csv.writer(f); w.writerow(['address','name','kind','notes'])
    for addr, name, kind, notes in sorted(labels):
        w.writerow(['0x%08x'%addr, name, kind, notes])
print('wrote', len(labels), file=sys.stderr)

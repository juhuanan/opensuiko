#!/usr/bin/env python3
"""Auto-label area overlays (VF/VG/VH/VI/VS pattern).
Usage: auto_label.py <bin_path> <base_hex> <prefix> <out_csv>
"""
import sys, os, re, csv, struct, subprocess
sys.path.insert(0, os.path.dirname(__file__))

bin_path = sys.argv[1]
base = int(sys.argv[2], 16)
prefix = sys.argv[3]
out_csv = sys.argv[4]

# Run the analysis tools
workdir = os.path.dirname(__file__)
def run_tool(name, *args):
    r = subprocess.run([sys.executable, os.path.join(workdir, name), bin_path, '0x%08x'%base] + list(args),
                       capture_output=True, text=True, cwd=workdir)
    return r.stdout

print("Running dump.py...", file=sys.stderr)
dump_out = run_tool('dump.py')
print("Running tablescan.py...", file=sys.stderr)
table_out = run_tool('tablescan.py')
print("Running strxref.py...", file=sys.stderr)
str_out = run_tool('strxref.py', '6')

# Parse FUNCs
funcs = []  # (addr, n, end)
for line in dump_out.split('\n'):
    m = re.match(r'FUNC (0x[0-9a-f]+) n=\s*(\d+) end=\s*(0x[0-9a-f]+)', line)
    if m:
        funcs.append((int(m.group(1),16), int(m.group(2)), int(m.group(3),16)))
funcs.sort()

# Parse tables
tables = []  # (addr, [targets])
cur_addr = None
cur_targets = []
for line in table_out.split('\n'):
    m = re.match(r'TABLE at (0x[0-9a-f]+) n=(\d+)', line)
    if m:
        if cur_addr is not None:
            tables.append((cur_addr, cur_targets))
        cur_addr = int(m.group(1),16)
        cur_targets = []
    m2 = re.match(r'\s*-> (0x[0-9a-f]+)', line)
    if m2 and cur_addr is not None:
        cur_targets.append(int(m2.group(1),16))
if cur_addr is not None:
    tables.append((cur_addr, cur_targets))

# Build TRUE entry map: table target -> (table_addr, idx)
true_entries = {}
for taddr, tgts in tables:
    for i, t in enumerate(tgts):
        if t not in true_entries:
            true_entries[t] = (taddr, i)

# Parse strxref: string addr -> (string, [(ref_addr, func_addr)])
strings = {}
cur_str = None
for line in str_out.split('\n'):
    m = re.match(r"(0x[0-9a-f]+) '(.+)'", line)
    if m:
        cur_str = (int(m.group(1),16), m.group(2))
        strings[cur_str[0]] = (cur_str[1], [])
    m2 = re.match(r'\s*ref @(0x[0-9a-f]+) in func (0x[0-9a-f]+)', line)
    if m2 and cur_str:
        strings[cur_str[0]][1].append((int(m2.group(1),16), int(m2.group(2),16)))

# Engine template (sizes in order)
engine_template = [
    (106, 'evt_script_cond_check', '4-way script-byte compare vs char struct.'),
    (95, 'evt_pc_walker', 'pc--in/pc-loop/pc--out debug; PC engine.'),
    (442, 'evt_init_alloc48', 'Big init; alloc 0x48 via game-state+0x48.'),
    (33, 'evt_cc_halfword_step', 'Frameless cc helper.'),
    (417, 'evt_cc_dispatch', 'CC engine: cc--in/cc-first/cc-second/cc-syono/cc-syoari.'),
    (156, 'evt_init_variant_a', 'Init variant.'),
    (170, 'evt_init_variant_b', 'Init variant.'),
    (62, 'evt_script_byte_loop_a', 'Script-byte reader loop; vtable+56.'),
    (62, 'evt_script_byte_loop_b', 'Script-byte reader loop; vtable+56.'),
    (57, 'evt_script_byte_loop_c', 'Script-byte reader loop; vtable+56.'),
    (245, 'evt_mid_245', '245-insn; vtable+48/+52.'),
    (37, 'evt_bgset_pre', 'Bgset preamble.'),
    (98, 'evt_bgset', 'bgset--in/bgset--flg-%d.'),
    (294, 'evt_late_294', '294-insn; vtable+48/+52/+76.'),
    (178, 'evt_late_178', '178-insn; vtable+48/+52/+116/+456.'),
    (129, 'evt_late_129', '129-insn; vtable+456.'),
]

labels = []
labeled_addrs = set()
def L(addr, name, kind, notes):
    if addr in labeled_addrs:
        return
    labeled_addrs.add(addr)
    labels.append((addr, name, kind, notes))

# Match engine
engine_addrs = set()
idx = 0
for i, (exp_size, name, desc) in enumerate(engine_template):
    if idx < len(funcs) and funcs[idx][1] == exp_size:
        dump_addr = funcs[idx][0]
        # Check if there's a TRUE entry (8 bytes before) referenced by a table
        true_addr = dump_addr
        if (dump_addr - 8) in true_entries:
            true_addr = dump_addr - 8
            note_extra = " TRUE entry (dump 0x%08x off by 8)." % dump_addr
        else:
            note_extra = ""
        L(true_addr, name, 'F', desc + note_extra)
        engine_addrs.add(dump_addr)
        idx += 1
    else:
        print(f"WARNING: engine template mismatch at {i} (expected size {exp_size})", file=sys.stderr)
        break

# Find ctx_store (3-insn function, usually after evt_late_129)
# It's a 3-insn function that does *(ctx) = $a0. Look for small functions not in engine.
# Actually, let's find it via table references or by size.
for addr, n, end in funcs:
    if n <= 4 and addr not in engine_addrs:
        # Check if it's the ctx store by looking at instructions
        # For now, label as potential ctx store if it's tiny
        pass

# Label tables: ONLY file-start tables (first 256 bytes) to avoid false positives
for taddr, tgts in tables:
    if taddr >= base + 0x100:
        continue
    if len(tgts) >= 2:
        is_engine = any(t in [f[0] for f in funcs[:20]] or (t+8) in [f[0] for f in funcs[:20]] for t in tgts[:3])
        kind = 'engine' if is_engine else 'scenario'
        L(taddr, '%s_table_%x' % (prefix, taddr), 'D', '%d-entry %s function table.' % (len(tgts), kind))
        for i, t in enumerate(tgts):
            containing = None
            for faddr, fn, fend in funcs:
                if faddr < t <= fend:
                    containing = faddr
                    break
                elif faddr == t:
                    containing = None
                    break
            if containing:
                L(t, '%s_scn_%x_%02d' % (prefix, containing, i), 'F',
                  'Mid-function case %d in %s (table 0x%08x[%d]).' % (i, '0x%08x'%containing, taddr, i))

# Label string refs (distinctive scenario functions)
for saddr, (sstr, refs) in strings.items():
    if 'pc--' in sstr or 'cc--' in sstr or 'bgset' in sstr:
        continue  # engine strings, already covered
    # Get unique func addrs
    for ref_addr, func_addr in refs:
        # Find a good name from the string
        clean = re.sub(r'[^a-zA-Z0-9_]', '_', sstr)[:30].strip('_')
        L(func_addr, '%s_str_%s' % (prefix, clean), 'F', "References string '%s' at 0x%08x." % (sstr, saddr))
        break  # only first ref per string

# Label remaining (non-engine) functions as scenario
scn_idx = 0
for addr, n, end in funcs:
    if addr in engine_addrs:
        continue
    # Skip if already labeled (as a case or string ref)
    if any(l[0] == addr for l in labels):
        continue
    L(addr, '%s_scn_%d' % (prefix, scn_idx), 'F', '%d-insn scenario function.' % n)
    scn_idx += 1

# Label string table at file start
if strings:
    min_saddr = min(strings.keys())
    if min_saddr < base + 0x200:
        L(min_saddr, '%s_str_table' % prefix, 'D', 'File-start debug strings.')

# Write CSV
with open(out_csv, 'w', newline='') as f:
    w = csv.writer(f)
    w.writerow(['address','name','kind','notes'])
    # Sort by address, F before D at same address
    for addr, name, kind, notes in sorted(labels, key=lambda x: (x[0], x[2])):
        w.writerow(['0x%08x'%addr, name, kind, notes])

print(f"Wrote {len(labels)} labels to {out_csv}", file=sys.stderr)

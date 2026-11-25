#!/usr/bin/env python3
"""analyze2.py — rich per-function static summaries for Suikoden PS1 overlay blobs.
Usage: analyze2.py <bin> <base_hex> <out_md> [--diff <other_bin>]
Writes a markdown report: sanity, strings, dispatch/jump tables, per-function
summaries (calls, vtable offsets, string refs, absolute refs, branch tables,
loop/div/bit hints). With --diff, appends a word-diff vs another same-base bin
mapped onto this file's functions.
"""
import sys, struct, re
from collections import Counter, defaultdict
from capstone import Cs, CS_ARCH_MIPS, CS_MODE_MIPS32, CS_MODE_LITTLE_ENDIAN

path, base_s, out = sys.argv[1], sys.argv[2], sys.argv[3]
diff_path = None
if '--diff' in sys.argv:
    diff_path = sys.argv[sys.argv.index('--diff') + 1]
base = int(base_s, 16)
data = open(path, 'rb').read()
nwords = len(data) // 4
words = struct.unpack('<%dI' % nwords, data)

def va(off): return base + off
def off(a): return a - base
def in_range(a): return base <= a < base + len(data)

md = Cs(CS_ARCH_MIPS, CS_MODE_MIPS32 | CS_MODE_LITTLE_ENDIAN)
md.detail = True
insns = {}
# per-word decode: capstone's disasm generator halts at the first invalid
# word, so decode each word independently (data blobs are full of them)
for o in range(0, len(data) - 3, 4):
    try:
        for ins in md.disasm(data[o:o+4], base + o, count=1):
            insns[ins.address] = ins
            break
    except Exception:
        pass
def get(a): return insns.get(a)
def word_at(a):
    o = off(a)
    if 0 <= o < len(data) - 3 and o % 4 == 0:
        return words[o // 4]
    return None

REG = {f'${i}': i for i in range(32)}
REG.update({'$zero':0,'$at':1,'$v0':2,'$v1':3,'$a0':4,'$a1':5,'$a2':6,'$a3':7,
            '$t0':8,'$t1':9,'$t2':10,'$t3':11,'$t4':12,'$t5':13,'$t6':14,'$t7':15,
            '$s0':16,'$s1':17,'$s2':18,'$s3':19,'$s4':20,'$s5':21,'$s6':22,'$s7':23,
            '$t8':24,'$t9':25,'$k0':26,'$k1':27,'$gp':28,'$sp':29,'$fp':30,'$ra':31})
def regno(name): return REG.get(name.strip(), -1)
def imm16(w): return (w & 0xFFFF) - 0x10000 if (w & 0x8000) else (w & 0xFFFF)
def jtarget(a, w): return ((a + 4) & 0xF0000000) | ((w & 0x3FFFFFF) << 2)

# ---------------- strings ----------------
def find_strings():
    # Suikoden overlays mix ASCII debug strings with Shift-JIS game text.
    # Pull ASCII tokens out of the byte soup rather than whole runs.
    out = []
    i = 0
    n = len(data)
    while i < n:
        if 32 <= data[i] < 127:
            j = i
            while j < n and 32 <= data[j] < 127: j += 1
            run = data[i:j]
            # whole-run candidate if it looks like a real message
            try: txt = run.decode('ascii')
            except: txt = ''
            if len(run) >= 6 and j < n and data[j] == 0 and re.search(r'[a-z]{2,}', txt):
                out.append((va(i), txt))
            else:
                for m in re.finditer(rb'[A-Za-z_][A-Za-z0-9_]{3,}|%[0-9]*[dxXsu]|--[a-z]+--[a-z%]+', run):
                    tok = m.group(0).decode('ascii')
                    if re.search(r'[a-zA-Z]{2}', tok):
                        out.append((va(i + m.start()), tok))
            i = j
        i += 1
    # de-dup, keep order
    seen = set(); res = []
    for a, s in out:
        if (a, s) not in seen: seen.add((a, s)); res.append((a, s))
    return res
strings = find_strings()
str_at = dict(strings)

# ---------------- seeds ----------------
seeds = set()
for i, w in enumerate(words):
    op = w >> 26
    if op == 9:  # addiu
        rs, rt = (w >> 21) & 31, (w >> 16) & 31
        im = imm16(w)
        if rs == 29 and rt == 29 and im < 0 and -im % 8 == 0 and -im < 0x2000:
            seeds.add(va(i * 4))
for i, w in enumerate(words):
    op = w >> 26
    if op in (2, 3):
        t = ((base & 0xF0000000) | ((w & 0x3FFFFFF) << 2))
        if in_range(t) and t % 4 == 0:
            seeds.add(t)

# ---------------- descent ----------------
def descend(entry):
    seen, stack = set(), [entry]
    while stack:
        a = stack.pop()
        while True:
            if a in seen: break
            ins = get(a)
            if ins is None: break
            seen.add(a)
            w = word_at(a); op = (w >> 26) if w is not None else -1
            m = ins.mnemonic
            if m == 'jr': break
            if m == 'j' or op == 2:
                # record only; do NOT descend into tail calls (keeps bodies separate)
                if get(a + 4) is not None: seen.add(a + 4)
                a += 8; continue
            if m == 'jal' or op == 3:
                # jal: delay slot at a+4 executes; resume at a+8
                if get(a + 4) is not None: seen.add(a + 4)
                a += 8; continue
            taken = None
            if m in ('beq','bne','beql','bnel','bgez','bgezal','bgtz','blez','bltz','bltzal',
                     'bc1t','bc1f','bc1tl','bc1fl','bnez','beqz'):
                taken = a + 4 + (imm16(w) << 2)
            if taken is not None and in_range(taken) and taken not in seen:
                stack.append(taken)
            a += 4
    return sorted(seen)

bodies = {}
prologue_seeds = set()
for i, w in enumerate(words):
    op = w >> 26
    if op == 9:
        rs, rt = (w >> 21) & 31, (w >> 16) & 31
        im = imm16(w)
        if rs == 29 and rt == 29 and im < 0 and -im % 8 == 0 and -im < 0x2000:
            prologue_seeds.add(va(i * 4))
for s in sorted(prologue_seeds):
    b = descend(s)
    if b: bodies[s] = b
# jal-target seeds become functions only if outside all prologue bodies
covered = set()
for b in bodies.values(): covered.update(b)
for s in sorted(seeds - prologue_seeds):
    if s in covered: continue
    b = descend(s)
    if b:
        bodies[s] = b
        covered.update(b)
addr2func = {}
for f, b in bodies.items():
    for a in b: addr2func.setdefault(a, f)

# ---------------- per-function analysis ----------------
VTABLE_NAMES = {0:'debug_printf',72:'malloc',108:'gpu_drawmode_word_build',112:'gpu_loadimage_wrap',
 124:'bytecode_interpreter',128:'num_to_cmd_and_interpret',132:'text_decode_stream',
 140:'gpu_texpage_word_build',144:'vt144',152:'tile_grid_packet_init',156:'sprite_obj_update',
 160:'sprite_obj_teardown',172:'queue_command_to_dispatcher',180:'sprite_flag_set_state',
 184:'free',192:'tile_grid_cursor_clamp',196:'tile_grid_subcmd_dispatch',224:'vt224',236:'vt236',
 240:'vt240',244:'vt244',288:'debug_printf_b',352:'obj_field_copy_6half',368:'dialogue_data_access_wrap',
 372:'dialogue_line_counter_inc',396:'vt396',400:'vt400',408:'vt408',420:'sprite_init_vt420',
 480:'menu_item_renderer_field_entry',492:'sprite_layout_apply',540:'sprite_bytecode_interpret_driver',
 544:'dialogue_data_table_read',548:'menu_item_bytecode_renderer',552:'menu_item_attr_kind_dispatch',
 576:'menu_item_key_search',584:'ui_quad_elem_alloc',588:'sprite_quad_packet_build',592:'sprite_obj_free',
 596:'sprite_render_dispatch',600:'sprite_flag_clear_bit11',604:'sprite_center_init_wrap',
 608:'sprite_attr_scale_compute',612:'struct_halfword_zero_1416',616:'sprite_dim_scale_helper',
 620:'buffer_pattern_fill_rect',624:'sprite_attr_scale_store',628:'sprite_text_struct_alloc',
 660:'vt660'}

def analyze_func(f, body):
    body_set = set(body)
    jal_in, jal_out = [], []
    vt = Counter()
    strrefs, absrefs = [], []
    jtables = []
    n_branch = 0; n_div = 0; n_mult = 0; n_srl = 0; n_break = 0
    back_branch = False; jr_nonra = []
    tail_j = []
    cop1 = 0
    consts = Counter()
    # forward lui tracking: addr -> {reg: hi}
    # simpler: per-insn scan, track lui-defined regs with expiry
    lui_map = {}  # reg -> (hi, set_addr)
    prev_was_jr_setup = None
    for idx, a in enumerate(body):
        ins = get(a); w = word_at(a); m = ins.mnemonic; op = w >> 26
        ops = [o.strip() for o in ins.op_str.split(',')] if ins.op_str else []
        if m in ('beq','bne','beql','bnel','bgez','bgezal','bgtz','blez','bltz','bltzal','bnez','beqz','bc1t','bc1f','bc1tl','bc1fl'):
            n_branch += 1
            t = a + 4 + (imm16(w) << 2)
            if t < a: back_branch = True
        if m == 'div' or m == 'divu': n_div += 1
        if m in ('mult','multu'): n_mult += 1
        if m == 'srl': n_srl += 1
        if m == 'break': n_break += 1
        if ins.mnemonic.startswith('lwc1') or ins.mnemonic.startswith('swc1') or m in ('add.s','mul.s','div.s'): cop1 += 1
        # constants of interest
        for tok in re.findall(r'0x[0-9a-fA-F]+', ins.op_str):
            v = int(tok, 16)
            if v in (0x1000, 0xfff, 0x7ff, 0x800, 0x100, 0x2000, 0x4000): consts[v] += 1
        if m == 'lui' and len(ops) >= 2:
            r = regno(ops[0]); lui_map[r] = (int(ops[1], 16) & 0xFFFF, a)
        elif m in ('addiu','ori','xori') and len(ops) >= 3:
            rd = regno(ops[0]); rs = regno(ops[1])
            if rs in lui_map:
                hi, _ = lui_map[rs]
                addr = ((hi << 16) + imm16(w)) & 0xFFFFFFFF
                if m == 'ori': addr = (hi << 16) | (w & 0xFFFF)
                if addr in str_at: strrefs.append((a, addr, str_at[addr]))
                else: absrefs.append((a, addr, 'addiu/ori'))
            if rd in lui_map and rd != rs: del lui_map[rd]
        elif m in ('lw','sw','lh','lhu','lb','lbu','sb','sh') and len(ops) >= 2:
            mo = re.match(r'(-?0x[0-9a-fA-F]+|-?\d+)\((\$\w+)\)', ops[1])
            if mo:
                rb = regno(mo.group(2))
                if rb in lui_map:
                    hi, _ = lui_map[rb]
                    addr = ((hi << 16) + imm16(w)) & 0xFFFFFFFF
                    if addr in str_at: strrefs.append((a, addr, str_at[addr]))
                    else: absrefs.append((a, addr, m))
            if m in ('lw',) and len(ops) >= 2:
                pass
        elif m in ('addu','add','subu','sub','and_','and','or','nor','xor','sll','srl','sra','slt','sltu','move'):
            if ops and regno(ops[0]) in lui_map and not (len(ops) > 1 and regno(ops[1]) in lui_map):
                # only clear if dest overwritten without lui-source... keep simple: clear dest unless it's a lui-chain
                pass
        # any write to a lui-tracked reg that isn't lui kills it (approx: dest reg of r-type)
        if m not in ('lui',) and ops:
            d = regno(ops[0])
            if d in lui_map and m in ('lw','lh','lhu','lb','lbu','addiu','ori','xori','addu','add','subu','sub','and','andi','or','ori','xor','xori','nor','sll','srl','sra','slt','slti','sltu','sltiu','mult','div','move'):
                # keep only if this very insn used it as source with lui (handled above); drop otherwise
                # check if source also the same reg for addiu handled; drop now
                if not (m in ('addiu','ori','xori') and len(ops) >= 3 and regno(ops[1]) == d):
                    # re-add via chaining would need hi; drop
                    lui_map.pop(d, None)
        if m == 'jal' or op == 3:
            t = jtarget(a, w)
            if in_range(t): jal_in.append((a, t))
            else: jal_out.append((a, t))
        if m == 'j' or op == 2:
            t = jtarget(a, w)
            if in_range(t) and t not in body_set: tail_j.append((a, t))
        if m == 'jalr' and ops:
            r = regno(ops[0])
            # look back for lw r, off(base) with non-sp base
            for b2 in range(a - 4, max(a - 48, body[0] - 4), -4):
                i2 = get(b2); w2 = word_at(b2)
                if i2 is None or w2 is None: continue
                if i2.mnemonic == 'lw':
                    o2 = [o.strip() for o in i2.op_str.split(',')]
                    mo = re.match(r'(-?0x[0-9a-fA-F]+|-?\d+)\((\$\w+)\)', o2[1]) if len(o2) > 1 else None
                    if mo and regno(o2[0]) == r and regno(mo.group(2)) not in (29,):
                        vt[imm16(w2) & 0xFFFF if False else (int(mo.group(1), 0))] += 1
                        break
                if i2.mnemonic in ('addu','add','move') and i2.op_str.split(',')[0].strip() == ops[0]:
                    break
        if m == 'jr' and ops and regno(ops[0]) != 31:
            jr_nonra.append((a, ops[0]))
            # verification-driven table resolution: try every (lui-hi, lw-lo)
            # pair in the window; accept if >=3 consecutive in-range code words
            rx = regno(ops[0])
            tbl = None; ncases = 0
            lw_los = []
            lui_his = []
            for b2 in range(a - 4, max(a - 200, body[0] - 4), -4):
                i2 = get(b2)
                if i2 is None: continue
                if i2.mnemonic == 'lw':
                    o2 = [o.strip() for o in i2.op_str.split(',')]
                    if len(o2) > 1 and regno(o2[0]) == rx:
                        mo = re.match(r'(-?0x[0-9a-fA-F]+|-?\d+)\((\$\w+)\)', o2[1])
                        if mo: lw_los.append(int(mo.group(1), 0))
                elif i2.mnemonic == 'lui':
                    o2 = [o.strip() for o in i2.op_str.split(',')]
                    if len(o2) > 1: lui_his.append(int(o2[1], 16))
            for hi in lui_his:
                if tbl: break
                for lo in lw_los:
                    cand = ((hi << 16) + (lo if lo < 0x8000 else lo - 0x10000)) & 0xFFFFFFFF
                    if not in_range(cand): continue
                    n = 0
                    for k in range(24):
                        wv = word_at(cand + k * 4)
                        if wv is None or not in_range(wv) or wv % 4: break
                        n += 1
                    if n >= 3:
                        tbl, ncases = cand, n
                        break
            jtables.append((a, ops[0], tbl, ncases))
    return dict(jal_in=jal_in, jal_out=jal_out, vt=vt, strrefs=strrefs, absrefs=absrefs,
                jtables=jtables, n_branch=n_branch, n_div=n_div, n_mult=n_mult, n_srl=n_srl,
                n_break=n_break, back_branch=back_branch, jr_nonra=jr_nonra, tail_j=tail_j,
                cop1=cop1, consts=consts, size=len(body))

L = []
L.append(f"# {path} base={hex(base)} size={len(data)}")
# sanity
lui_c = Counter()
for w in words:
    if (w >> 26) == 0x0F: lui_c[w & 0xFFFF] += 1
inseg = [((base & 0xF0000000) | ((w & 0x3FFFFFF) << 2)) for w in words if (w >> 26) in (2,3)]
inseg = [t for t in inseg if in_range(t)]
L.append(f"top lui: {[(hex(k),c) for k,c in lui_c.most_common(6)]}")
L.append(f"j/jal in-seg: {len(inseg)} range {hex(min(inseg))}-{hex(max(inseg))}" if inseg else "no in-seg targets")
# file-start words: karuta-style overlay dispatch tables live at offset 0
L.append("\n## file-start words (possible dispatch table):")
for i in range(0, min(48, nwords)):
    w = words[i]
    tag = ""
    if in_range(w) and w % 4 == 0: tag = " -> CODE?"
    elif w == 0: tag = " (0)"
    L.append(f"  {hex(va(i*4))}: {hex(w)}{tag}")
    if i >= 11 and all(words[j] == 0 or not (in_range(words[j]) and words[j] % 4 == 0) for j in range(i-3, i+1)):
        L.append("  ... (stopping: no more code pointers)"); break
# dispatch table at start?
dtable = []
for i in range(0, min(256, nwords)):
    w = words[i]
    if in_range(w) and w % 4 == 0: dtable.append((va(i*4), w))
    elif dtable and len(dtable) >= 4: break
    elif not (in_range(w) and w % 4 == 0): dtable = []
if len(dtable) >= 4:
    L.append(f"\n## possible dispatch table at {hex(dtable[0][0])} ({len(dtable)} slots):")
    for a, t in dtable[:48]: L.append(f"  {hex(a)} -> {hex(t)}")
L.append(f"\n## strings ({len(strings)}):")
for a, s in strings:
    refs = sum(1 for f,b in bodies.items() for (ra,aa,ss) in analyze_func(f,b)['strrefs'] if aa == a) if False else 0
    L.append(f"  {hex(a)}: {s[:90]}")
L.append(f"\n## functions: {len(bodies)}")
order = sorted(bodies)
info = {f: analyze_func(f, bodies[f]) for f in order}
for f in order:
    i = info[f]; b = bodies[f]
    L.append(f"\n### F {hex(f)} size={i['size']} end={hex(b[-1])} branches={i['n_branch']}" +
             (f" div={i['n_div']}" if i['n_div'] else "") + (f" mult={i['n_mult']}" if i['n_mult'] else "") +
             (f" srl={i['n_srl']}" if i['n_srl'] else "") + (f" break={i['n_break']}" if i['n_break'] else "") +
             (f" loop" if i['back_branch'] else "") + (f" cop1" if i['cop1'] else "") +
             (f" consts={dict(i['consts'])}" if i['consts'] else ""))
    if i['jal_in']:
        L.append("  calls: " + ", ".join(hex(t) for _, t in i['jal_in'][:24]) + (" ..." if len(i['jal_in']) > 24 else ""))
    if i['jal_out']:
        L.append("  calls-ext: " + ", ".join(hex(t) for _, t in i['jal_out'][:12]))
    if i['vt']:
        L.append("  vtable: " + ", ".join(f"+{o}({VTABLE_NAMES.get(o & 0xFFFF,'?')})x{c}" for o, c in sorted(i['vt'].items())[:20]))
    if i['absrefs'] or i['strrefs']:
        seen = set()
        for ra, aa, k in i['absrefs']:
            if aa not in seen:
                tag = "data" if base <= aa < base + len(data) else k
                L.append(f"  ref {hex(aa)} [{tag}]"); seen.add(aa)
            if len(seen) > 16: break
        for ra, aa, s in i['strrefs']:
            if aa not in seen: L.append(f"  str {hex(aa)}: {s[:80]}"); seen.add(aa)
    for ja, r, tbl, ncases in i['jtables']:
        extra = ""
        if tbl and in_range(tbl):
            cases = []
            for k in range(ncases):
                wv = word_at(tbl + k*4)
                if wv is None or not in_range(wv) or wv % 4: break
                cases.append(hex(wv))
            extra = f" table={hex(tbl)} cases={len(cases)}: " + " ".join(cases[:12])
        L.append(f"  jumptable via {r} @{hex(ja)}{extra}")
    if i['tail_j']:
        L.append("  tailj: " + ", ".join(hex(t) for _, t in i['tail_j'][:6]))
    if i['jr_nonra'] and not i['jtables']:
        L.append("  jr-indirect: " + ", ".join(f"{r}@{hex(a)}" for a, r in i['jr_nonra'][:4]))

# global decompressor-quarry scan
L.append("\n## quarry scan (bit-reader / LZSS shapes)")
for f in order:
    i = info[f]; b = bodies[f]
    flags = []
    if i['n_srl'] >= 3 and i['back_branch']: flags.append(f"srlx{i['n_srl']}+loop")
    if i['consts'].get(0x1000) or i['consts'].get(0xfff): flags.append(f"winconsts={dict(i['consts'])}")
    # lbu+sb copy loop heuristic
    n_lbu = sum(1 for a in b if get(a) and get(a).mnemonic == 'lbu')
    n_sb = sum(1 for a in b if get(a) and get(a).mnemonic == 'sb')
    if n_lbu >= 2 and n_sb >= 2 and i['back_branch'] and i['size'] > 40:
        flags.append(f"lbu/sb-copy-loop({n_lbu}/{n_sb})")
    # flag-bit counter: li reg,8 / li reg,16 near srl loop
    has_li8 = any(get(a) and get(a).mnemonic == 'addiu' and get(a).op_str.startswith('$') is False for a in b)
    if flags: L.append(f"  {hex(f)}: " + "; ".join(flags))

if diff_path:
    d2 = open(diff_path, 'rb').read()
    w2 = struct.unpack('<%dI' % (len(d2)//4), d2)
    L.append(f"\n## diff vs {diff_path}")
    diffs = []
    for i in range(min(nwords, len(w2))):
        if words[i] != w2[i]: diffs.append(i*4)
    L.append(f"word diffs: {len(diffs)}")
    byfunc = defaultdict(list)
    for d in diffs:
        a = va(d)
        fn = addr2func.get(a)
        byfunc[fn].append(a)
    for fn in sorted(byfunc, key=lambda x: (x is None, x or 0)):
        ds = byfunc[fn]
        tag = hex(fn) if fn else "data?"
        L.append(f"  {tag}: {len(ds)} diffs, e.g. {', '.join(hex(x) for x in ds[:8])}")
        if fn and len(ds) <= 40:
            for x in ds[:20]:
                o = off(x)//4
                L.append(f"    {hex(x)}: {hex(words[o])} -> {hex(w2[o])}")

open(out, 'w').write("\n".join(L) + "\n")
print("wrote", out, "funcs:", len(bodies))

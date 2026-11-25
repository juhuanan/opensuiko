import csv, re

IKKI = '/home/hatch/workspace/suikoden/kit/extracted/bin_overlays/DATA/12_IKKI/'
OUT = '/home/hatch/workspace/suikoden/kit/work/overlays/'

pan = {}
for r in csv.DictReader(open(OUT + 'pan_teo_labels.csv')):
    pan[int(r['address'], 16)] = (r['name'], r['kind'].strip(), r['notes'].strip())

# addresses in SHU_KWA/TEO that match pan_teo functions 1:1 (same address, same mnemonics)
MATCHED = [
    0x8008009c, 0x800805ec, 0x80080e98, 0x8008102c, 0x800813c0, 0x80081ac4,
    0x80081b24, 0x80081cd8, 0x80081ef4, 0x80082134, 0x80082244, 0x80082930,
    0x80082b30, 0x80082dbc, 0x80082e44, 0x800836c0, 0x80083a50, 0x80083ab8,
    0x80083e30, 0x80083fe8, 0x800843f8, 0x80084634, 0x800849c8, 0x80084db4,
    0x80084e48, 0x80084f00, 0x80085260, 0x80085268, 0x80085434, 0x800854f0,
    0x80085888, 0x80085c10, 0x80085d44, 0x800862f8, 0x8008638c, 0x800864e4,
    0x80086660, 0x80086974, 0x80086ba4, 0x80086c30, 0x80086dd8, 0x80086e74,
    0x80086f4c, 0x8008702c, 0x800870a0, 0x80087110, 0x800872d0, 0x800875e0,
    0x8008784c, 0x80087898, 0x80087b18, 0x80087be0, 0x80087c7c, 0x80087e58,
    0x80088030, 0x8008820c, 0x800883e0, 0x8008847c, 0x80088538, 0x80088754,
    0x80088994,
]

PHASES = [
    (0x800801ac, 'shu_duel_phase_1', 'staged phase 2 of 9: 3-state phase, same shape as duel_step_0 (duplicate choreography block)'),
    (0x800802bc, 'shu_duel_phase_2', 'staged phase 3 of 9: 5-state phase (t0=0..4): t0=0 sets frame counter 0x3c + duel_copy_params($a1=0x5a), increments step id; t0=1..4 countdown/branch states'),
    (0x800804dc, 'shu_duel_phase_3', 'staged phase 4 of 9: 3-state phase, same shape as duel_step_0'),
    (0x80080788, 'shu_duel_phase_5', 'staged phase 6 of 9: 150-insn 3-state phase ($v1 dispatch), calls duel_copy_params; unique choreography'),
    (0x800809ec, 'shu_duel_phase_6', 'staged phase 7 of 9: 124-insn 5-state phase ($a3 dispatch: 0,1,2,3,4), calls duel_copy_params; unique choreography'),
    (0x80080be8, 'shu_duel_phase_7', 'staged phase 8 of 9: 169-insn 5-state phase ($a2 dispatch), calls duel_copy_params; unique choreography'),
]
# phases 1, 5, 9 of the 9-phase sequence reuse pan_teo names (same shape):
# 0x8008009c = duel_step_0 (phase 1), 0x800805ec = duel_step_3 (phase 5), 0x80080e98 = duel_step_8 (phase 9)

EXTRA_F = [
    (0x8008223c, 'shu_actor_flag_dispatch_b', '444-insn: loads $a1=*ovl+state, dispatches on word+12 & 0xaa bit mask (0x20/0x80 cases); vtable+376/+384/+388/+408/+412/+416; variant of duel_actor_flag_dispatch with preloaded $a1'),
    (0x80082dc4, 'shu_free_field16_c', 'prologue; vtable+184 (free) x3 of *(arg+0x10); free-field variant (cf duel_free_field16)'),
    (0x80083a58, 'shu_vtable288_wrap_b', 'prologue; vtable+0x120 call with computed args; purpose not fully read'),
    (0x800878a0, 'shu_vtable144_wrap3', 'prologue; vtable+0x90 jalr call; thin wrapper'),
    (0x800879e8, 'shu_actor_step_caller', 'prologue; jalr $v0 then calls duel_actor_step_call 0x80086660 x2; actor-step driver variant'),
]

# pan_teo D labels to reuse (same file-start addresses)
D_REUSE = [0x80080004, 0x80080024, 0x80080038, 0x8008004c, 0x80080060,
           0x8008007c, 0x80080088, 0x80081688, 0x800816ec, 0x8008178c,
           0x8008186c, 0x80081900, 0x80087320, 0x80087364, 0x8008741c,
           0x80087524]


def build(tag, state_note):
    rows = ['address,name,kind,notes']
    # reused pan_teo functions
    for a in MATCHED:
        name, kind, note = pan[a]
        assert kind == 'F', (hex(a), kind)
        # strip PAN-specific addresses from note? keep, but flag per-duel offsets
        rows.append(f'{hex(a)},{name},F,"{note} [{tag}: code identical to PAN_TEO (0 mnemonic diffs); {state_note}]"')
    # phases
    for a, name, note in PHASES:
        rows.append(f'{hex(a)},{name},F,"{note}; {tag} state layout: {state_note}"')
    # extra functions
    for a, name, note in EXTRA_F:
        rows.append(f'{hex(a)},{name},F,"{note}"')
    # D labels
    for a in D_REUSE:
        name, kind, note = pan[a]
        assert kind == 'D', (hex(a), kind)
        rows.append(f'{hex(a)},{name},D,"{note}"')
    # per-duel state anchor (in the notes of every F row already; no extra D row to avoid dupes)
    return rows


kwa_state = 'step-id word at ovl+0x1CFC, frame counter at ovl+0x1D04, counter at ovl+0x1D6C (PAN_TEO: +0x22D0/+0x22D8/+0x2340)'
teo_state = 'step-id word at ovl+0x1D60, frame counter at ovl+0x1D68, counter at ovl+0x1DD0 (PAN_TEO: +0x22D0/+0x22D8/+0x2340)'

kwa_rows = build('SHU_KWA', kwa_state)
teo_rows = build('SHU_TEO', teo_state)
open(OUT + 'shu_kwa_labels.csv', 'w').write('\n'.join(kwa_rows) + '\n')
open(OUT + 'shu_teo_labels.csv', 'w').write('\n'.join(teo_rows) + '\n')
print('kwa:', len(kwa_rows) - 1, 'teo:', len(teo_rows) - 1)

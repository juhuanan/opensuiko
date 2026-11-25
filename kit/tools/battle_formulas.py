#!/usr/bin/env python3
"""The battle arithmetic of Suikoden (PS1, SLUS_002.92 v1.1), as data.

Every entry carries the instruction address it was read from.  The values are
**disc-derived**: MAIN.EXE (PS-X EXE, t_addr 0x800C0800) read through
`tools/disc.py`; SLUS_002.92 (t_addr 0x80010000) for the character template.
Nothing here comes from an emulator, a save state or a VRAM capture.

The two record layouts the formulas index are stated once and reused:

    battle participant base         0x8017BE3C -> *(0x8017BE3C)      (the sole
                                    writer is battle_participant_alloc
                                    @0x800DDF98, `malloc(0x342C)`)
    participant slot array          base + 0x50,  stride 0x8C (140)
    participant battle-slot array   base + 0xB40, stride 0x54 (84)
    participant actor array         base + 0xF84, stride 0x0C
    game-state character-context array  gs + 0x1B9C, stride0x04 (pointers)

    battle slot (0x54 = 84 bytes), shared party/enemy array at base+0xB40
      +0x00..0x0F character name bytes; actorA+0 separately holds the ID
      +0x44 u8 formation/selection index
      +0x10  i16  HP maximum          (copied from the char record, 0x800DED6C)
      +0x12  i16  HP current          (0x800DED74) -- the damage routine at
                                      0x800E1654 stores the remainder here
      +0x24  8 x i16  **working stat vector**, index 0..7 (0x800F6F20 copies
                  base +0x14..+0x1E into +0x24..+0x2E; 0x800F7024 adds the
                  equipment bonuses at +0x34..+0x40 into it)
      +0x30  u16  attack input: working PWR plus attack modifier
                  (enemy initialization800F6F44, modifier add800F7024..7034)
      +0x32  u16  defence input: working DEF plus defence modifier
                  (enemy initialization800F6F4C, same modifier pass)
      +0x40/+0x42 u16 attack/defence modifier columns during stat refresh
                  (the action counter is in actorA+0x42, a different array)
      +0x46  u8   acting/anim state byte; distinct from persistent element+0x46
      +0x47  u8   action category; Defend == 1 makes the computed damage halve
                  (0x800F7FF4 -> 0x800F8000)
      +0x4A  u16  status flags (bit 0x8000 cancels, bit 0x20 is a poison-like
                  roll gated on a 0..99 random < 50, 0x800F6F6C)
      +0x4E  u16  accumulated damage applied this action (0x800E176C/177C)
      +0x50  ptr  next handler (state machine)

    persistent character record (0x50 bytes;78 new-game templates):
      +0x00 u32 id; +0x04/+0x06 u16 maximum/current HP
      +0x09..0x0C u8 spell charges; +0x0D u8 level; +0x0E u16 EXP
      +0x10..0x15 u8 PWR/SKL/DEF/SPD/MGC/LUK; +0x18..0x1D growth
      +0x1F inventory count; +0x20..0x43 nine four-byte item entries
      +0x44 weapon; +0x45 weapon level; +0x46 element; +0x4C rune
    A character context caches this record's pointer at context+0x1C.
    Enemy records are a different layout: level+0x10, HP+0x12,
    six base halfwords+0x14..0x1E, rewards+0x34..0x3B. Camera parameter
    blocks are separate again; equal record sizes do not establish identity.

**What is NOT here.**  No per-level stat-growth routine that reads the SLUS
template was found, and section 8 of the doc records the evidence for that
negative together with the counter-reading that the template's +0x02..+0x0E is
a *camera/animation* accessor, not a stat block (0x800E62B0 / 0x800E6638 /
0x800E6730 all compute frame steps for a camera or sprite from those fields).
The values in the template and in a real character record look alike because
the two share the 0x50 record shape; the *consumers* are provably different.

Usage:
    python3 battle_formulas.py --json
    python3 battle_formulas.py --formula physical_damage
"""
from __future__ import annotations

import argparse
import json
import os
import sys

_TOOLS = os.path.dirname(os.path.abspath(__file__))
_KIT = os.path.dirname(_TOOLS)
sys.path.insert(0, _TOOLS)

# ---------------------------------------------------------------------------
# Addresses
# ---------------------------------------------------------------------------
MAIN_BASE = 0x800C0800
SLUS_BASE = 0x80010000

PARTICIPANT_PTR = 0x8017BE3C          # -> battle participant struct
PARTICIPANT_MAGIC = 0x342C            # malloc size, 0x800DDF98
PARTICIPANT_ALLOC = 0x800DDF98

SLOT_ARRAY_OFF = 0x50                 # 0x800E62DC
SLOT_STRIDE = 0x8C                    # == 140, the (n*9-n)*4*... shift chain
BATTLE_SLOT_STRIDE = 0x54             #84-byte combat working records
BATTLE_SLOT_ARRAY_OFF = 0xB40         # 0x800E169C / 0x800F7EE8 / 0x800F7D9C
ACTOR_ARRAY_OFF = 0xF84               # 0x800DEC3C / 0x800F7F0C
CHAR_REC_ARRAY_OFF = 0x1B9C           # 0x800DEC30
PARTICIPANT_COUNT = 0x1C              # lw +0x1c(participant)
PARTICIPANT_ACTIVE_COUNT = 0x24       # lw +0x24(participant), enemies = +0x1c+1

# battle-slot field offsets
BS_CHARA_BYTE = 0x00
BS_FORMATION = 0x44
BS_HP_MAX = 0x10
BS_HP_CUR = 0x12
BS_STATS = 0x24                       # 8 x i16 working stat vector
BS_ATK = 0x30                         #PWR plus attack modifier
BS_DEF = 0x32                         #DEF plus defence modifier
BS_FLAGS = 0x4A
BS_COUNTER = 0x42                    #actorA, not the battle working record
BS_STATE = 0x46
BS_TARGETCLASS = 0x47
BS_STATFLAGS = 0x4A
BS_ACCUM = 0x4E

# char-record field offsets
CR_ID = 0x00
CR_LEVEL = 0x0D
CR_STATS_BASE = 0x10                  #six byte-sized persistent stats
CR_SUBSTRUCT = 0x1C                  #character CONTEXT caches persistent record here

# RNG
BIOS_RAND = 0x80147E38                # A0 0x2F trampoline; (seed>>16)&0x7FFF
RAND_MOD_127 = 0x8013879C             # bios_rand() / 127
RAND_MAX = 0x7FFF

# ---------------------------------------------------------------------------
# The four derived formulas
# ---------------------------------------------------------------------------
FORMULAS = {
    "physical_damage": {
        "name": "physical_damage",
        "routine": 0x800F7E90,
        "evidence": "proven",
        "summary": (
            "damage = f(attacker_stat[3] - target_stat[3]) with a two-branch "
            "random variance, then party-target Defend and party-attacker element modifiers; the caller "
            "multiplies the result by 3 and applies it as HP damage."
        ),
        "site": [
            ("victim_is_party_bytewise", 0x800F7E90),
            ("other_stat_minuend", 0x800F7EF8),
            ("self_stat_minuend", 0x800F7EF4),
            ("difference", 0x800F7F00),
            ("branch_lt_10", 0x800F7F04),
            ("branch_lt_10_rand", 0x800F7F10),
            ("branch_lt_10_mod4", 0x800F7F28),
            ("branch_ge_10_rand", 0x800F7F3C),
            ("branch_ge_10_mod_d", 0x800F7F44),
            ("branch_ge_10_halve_sra", 0x800F7F78),
            ("branch_ge_10_div5", 0x800F7F80),
            ("branch_ge_10_mflo", 0x800F7FAC),
            ("branch_ge_10_add", 0x800F7FB4),
            ("target_class_penalty_load", 0x800F7FEC),
            ("target_class_1_halve", 0x800F8000),
            ("element_table_scan", 0x800F8048),
            ("affinity_load", 0x800F80B4),
            ("affinity_table_base", 0x800F8120),
            ("master_multiplier_div20", 0x800F80F4),
            ("master_multiplier_mul", 0x800F812C),
            ("master_multiplier_add", 0x800F813C),
            ("clamp_min_1", 0x800F8148),
            ("caller_applies_x3_sll", 0x800F3A68),
            ("hp_apply", 0x800E1654),
        ],
        "code": {
            "d_lt_10": "damage = (d + 1) - (rand() % 4)              # d < 10",
            "d_ge_10": (
                "damage = d + trunc((d//2 - rand()%d)/5)  # d >= 10"
            ),
            "target_class_1": "damage = trunc(damage/2)  # party target chose Defend",
            "master_multiplier": (
                "damage += trunc(damage/20) * element_bonus"
                "        # after element match, when attacker persistent+0x46 is1 or3"
            ),
            "element_match": (
                "if attacker_is_party and element_index_valid and element_match_flag == 1:"
                " damage += trunc(damage/2)  # before element_bonus"
            ),
            "clamp": "damage = max(damage, 1)",
            "caller": "hp_damage_apply(target, damage * 3)",
        },
        "inputs": {
            "d": "u16 [attacker battle slot +0x30] - u16 [target battle slot +0x32]"
                 "  (0x800F7EF4 / 0x800F7EF8)",
            "attack word +0x30": "working PWR plus attack modifier; enemy base copied "
                                 "at0x800F6F44, modifiers added at0x800F7024..7034",
            "defence word +0x32": "working DEF plus defence modifier; enemy base copied "
                                  "at0x800F6F4C, same modifier pass",
            "rand": "0x80147E38, uniform 0..32767",
            "element_match_flag": "target actor metadata+0x20+element index",
            "element_bonus": "attacker persistent record+0x46+element_type",
            "element_type": "attacker persistent record+0x46",
        },
    },
    "magic_damage": {
        "name": "magic_damage",
        "routine": 0x800F8174,
        "evidence": "proven",
        "summary": (
            "shared variance on first actor B+0x2C minus second actor B+0x2C; "
            "the tail selects resistance through31 target-rune entries."
        ),
        "site": [
            ("first_actor_stat", 0x800F81E4),
            ("second_actor_stat", 0x800F81DC),
            ("difference", 0x800F81EC),
            ("branch_lt_10", 0x800F81F0),
            ("branch_lt_10_rand", 0x800F81FC),
            ("branch_lt_10_mod4", 0x800F8214),
            ("branch_ge_10_rand", 0x800F8228),
            ("branch_ge_10_tail", 0x800F82A0),
            ("jump_table_base", 0x800C1414),
            ("jump_table_bound", 0x800F82A8),
            ("jump_table_dispatch", 0x800F82D0),
            ("element_halve", 0x800F8324),
        ],
        "code": {
            "same_as": "shared variance on first actor B+0x2C minus second actor B+0x2C",
            "jump_table": (
                "s1 = 1..7 selected from the 31-entry table at 0x800C1414 by "
                "target rune id-1; default arms retain incoming s1; if (a2 & 0xFF) == s1 or s1 == 7:"
                " damage = trunc(damage/2)"
            ),
        },
        "inputs": {
            "d": ("u16 [first actor +0x2C] - u16 [second actor +0x2C]; "
                  "0x800F81DC loads second,0x800F81E4 first, then subu"),
            "a2": "spell element operand (low byte compared with selected or incoming s1)",
        },
    },
    "hit_chance": {
        "name": "hit_chance",
        "routine": 0x800F7D5C,
        "evidence": "proven",
        "summary": (
            "one roll decides whether the action lands at all, before any "
            "damage is computed.  A speed difference is clamped into "
            "[60, 99] and compared against rand() % 100."
        ),
        "site": [
            ("other_spd_load", 0x800F7DA8),
            ("self_spd_load", 0x800F7DAC),
            ("other_minus_0x50", 0x800F7DB0),
            ("difference", 0x800F7DB4),
            ("clamp_low_60", 0x800F7DB8),
            ("clamp_high_99", 0x800F7DC4),
            ("rand", 0x800F7E3C),
            ("mod_100", 0x800F7E48),
            ("compare", 0x800F7E78),
            ("miss_branch_at_caller", 0x800F4F0C),
        ],
        "code": {
            "formula": (
                "p = clamp(stat[1]_self - (stat[1]_other - 0x50), 60, 99);"
                " hit = (rand() % 100) < p"
            ),
            "miss_path": "0x800F4F0C bne -> 0x800F4F7C on a miss roll",
        },
        "inputs": {
            "stat[1]": "i16 at battle slot +0x26 (the working stat vector's index 1)",
            "0x50": "80, subtracted from the *other* side's speed",
            "rand": "0x80147E38, 0..32767; 32767 % 100 == 67, so the modulo "
                    "covers 0..99",
        },
    },
    "turn_order": {
        "name": "turn_order",
        "routine": 0x800E9744,
        "evidence": "proven",
        "summary": (
            "turn order is the party's own slot list, compared against a "
            "counter -- not a sort of any kind.  What IS computed per "
            "participant is a weight: a clamped level difference mapped "
            "through a signed table and averaged over the participant's "
            "member count, floored at 5."
        ),
        "routine_offsets": [
            ("stride_loop_start", 0x800E9774),
            ("slot_list_base", 0x800E9778),
            ("slot_byte_load", 0x800E97F4),
            ("match_against_counter", 0x800E980C),
            ("char_record_load", 0x800E981C),
            ("level_byte", 0x800E9828),
            ("other_level_byte", 0x800E982C),
            ("level_difference", 0x800E9834),
            ("clamp_low", 0x800E9838),
            ("clamp_high", 0x800E984C),
            ("scale_by_4", 0x800E9858),
            ("weight_table_base", 0x800E9768),
            ("accumulate", 0x800E986C),
            ("divide_by_count", 0x800E98A0),
            ("floor_at_5", 0x800E98D0),
            ("poison_state_double", 0x800E98FC),
        ],
        "code": {
            # CORRECTED 2026-10-07: this is the EXP AWARD, not a turn-order
            # weight.  See kit/docs/exp_award.md and battle_formulas.md section 5.
            "per_participant_exp_award": (
                "sum = 0; for each PRESENT enemy e: "
                "dl = clamp(enemy_level(e) - char_level(i), -14, 15); "
                "sum += XP[dl]; "
                "award = max(5, sum // party_count); "
                "if record(i)+0x4C == 0x16: award *= 2"
            ),
            "table": "0x8016BDC8 + 4*dl (dl in -14..15) = the 30 STATIC disc words "
                     "1,2,3,5,7,10,15,20,30,50,70,90,120,160,200,400,900,1600,"
                     "2600,3900,5100,6000,6900,7500,8000,8500,9000,9300,9700,10000",
            "poison_state": (
                "if the other's char-record element byte (rec_sub+0x4C) == 0x16"
                " then weight *= 2"
            ),
            "slot_list": (
                "0x8018AAFC is the per-participant 'which party slot answers "
                "me' list, read as a signed byte at 0x800E97F4"
            ),
        },
        "inputs": {
            "char_level": "u8 char record +0x0D (0x800E982C)",
            "enemy_level": "u8 enemy record +0x10 (0x800E9828), via G+0x1344[id]",
            "count": "lw *(0x8017BE3C)+0x1C (party count, no +1)",
        },
        "runtime_only": ["0x8018AAFC"],   # 0x8016BDC8 is STATIC disc data, not runtime
    },
    "hp_damage_apply": {
        "name": "hp_damage_apply",
        "routine": 0x800E1654,
        "evidence": "proven",
        "summary": (
            "the state-machine handler that turns an incoming damage value into "
            "the HP remainder: clamp a heal to hp_max, accumulate into +0x4E, "
            "and RETURN the post-damage HP.  The routine itself does not store "
            "hp_cur -- the phase driver that calls it does."
        ),
        "site": [
            ("status_flag_test", 0x800E16E8),
            ("cancel_on_bit8000", 0x800E16F4),
            ("zero_damage_returns", 0x800E16F8),
            ("hp_max_load", 0x800E1700),
            ("hp_cur_load", 0x800E1704),
            ("overkill_clamp", 0x800E1768),
            ("accumulate_load", 0x800E176C),
            ("accumulate_store", 0x800E177C),
        ],
        "code": {
            "clamp": (
                "if flags[+0x4A] & 0x8000: damage = 0;"
                " if hp_max < (hp_cur - damage): damage = hp_cur - hp_max"
                "   # only ever fires for a heal"
            ),
            "accumulate": "slot[+0x4E] += damage",
            "return": "hp_cur - damage in $v0 (may be negative; the caller owns "
                      "the clamp to 0)",
        },
    },
    "stat_vector_setup": {
        "name": "stat_vector_setup",
        "routine": 0x800F6F18,
        "evidence": "proven",
        "summary": (
            "Enemy refresh copies six base halfwords from battle-slot+14 into+24, "
            "initializes attack/defence from PWR/DEF, then adds eight modifier halfwords."
        ),
        "site": [
            ("base_copy_load", 0x800F6F20),
            ("base_copy_store", 0x800F6F28),
            ("base_copy_step", 0x800F6F34),
            ("bonus_add_load", 0x800F7024),
            ("bonus_add_store", 0x800F7034),
            ("atk_word_self_load", 0x800F6F38),
            ("atk_word_other_load", 0x800F6F3C),
            ("atk_store_30", 0x800F6F44),
            ("def_store_32", 0x800F6F4C),
        ],
        "code": {
            "base": ("for i in 0..5: slot[0x24+2i] = rec[0x14+2i]  "
                     "(0x800F6F20 lhu / 0x800F6F28 sh / 0x800F6F2C slti 6 / "
                     "0x800F6F34 addiu 2 -- SIX slots, not eight)"),
            "bonus": ("for i in 0..7: slot[0x24+2i] += slot[0x34+2i]  "
                      "(0x800F7024 lhu / 0x800F7034 sh -- the equipment run)"),
            "derived": ("slot[0x30] = slot[0x24] (0x800F6F44); "
                        "slot[0x32] = slot[0x28] (0x800F6F4C).  Both of these "
                        "sit INSIDE the 8-word vector, so this step overwrites "
                        "stats 6 and 7 with stats 0 and 2 before the modifier pass."),
        },
    },
    "attack_power_range": {
        # Keep the existing CLI key; this routine selects an actor, not damage operands.
        "name": "turn_actor_selection",
        "routine": 0x800F4698,
        "evidence": "proven",
        "summary": "Selects the next eligible actor by10*working SPD-5+rand()%10; "
                   "returns the actor index, preserving the first on equal priorities.",
        "site": [
            ("loop_head", 0x800F46E0),
            ("skip_if_state_46", 0x800F46E8),
            ("rand", 0x800F4720),
            ("mod_10", 0x800F4728),
            ("speed_load_first", 0x800F4754),
            ("speed_load_candidate", 0x800F47A8),
            ("times_10_sll2", 0x800F475C),
            ("times_10_addu", 0x800F4760),
            ("times_10_sll1", 0x800F4764),
            ("minus_5", 0x800F4768),
        ],
        "code": {"priority": "10*working_stat[3]-5+rand()%10",
                 "result": "selected actor index;0 or-1 sentinel when none selected"},
    },
}

# ---------------------------------------------------------------------------
# The negative: no per-level stat growth was found reading the SLUS template
# ---------------------------------------------------------------------------
GROWTH_NEGATIVE = {
    "evidence": "superseded",
    "current": "Per-level growth is derived in growth_rules.py; legacy claim below is history.",
    "claim": (
        "The SLUS_002.92 character template's +0x10 / +0x18 byte blocks are NOT "
        "level-growth data, and no level-up routine reading the template was "
        "found."
    ),
    "evidence": "refuted",
    "template_addr": 0x80043274,
    "consumers_found": [
        {
            "addr": 0x800E62B0,
            "reads": "[+0x02]=divisor, [+0x04],[+0x06],[+0x08]",
            "does": (
                "weapon::target_pos recompute.  d[i] = base[i] + "
                "(t[i]<<12 - base[i]) * level / T where "
                "T = sum_{k=level..1} k = level(level+1)/2 (loop 0x800E632C..)"
            ),
        },
        {
            "addr": 0x800E6638,
            "reads": "[+0x02]=divisor, [+0x04],[+0x06],[+0x08],[+0x0A]",
            "does": (
                "camera init: state[0x12C4..0x12CC] = t[2..4] << 12 (Q12), then "
                "per-frame delta = (state[0x12C4+i] - state[0x1294+i]) / t[1] "
                "-> state[0x12F4+i]"
            ),
        },
        {
            "addr": 0x800E6730,
            "reads": "[+0x02]=divisor, [+0x04],[+0x06],[+0x08]",
            "does": "sprite/camera step: step[i] = ((t[i]<<12) + pos.a - pos.b) / t[1]",
        },
    ],
    "why_this_is_a_negative": (
        "Three independent consumers read +0x02 as a divisor and +0x04..+0x0A as "
        "Q12 coordinates; none of them touches +0x10 or +0x18.  A growth table "
        "read by a level-up routine would have a `sw ...` consumer that writes "
        "stats; there is none.  Regenerating by the template's own record shape "
        "(the persistent table at gs+0x294 uses 0x50 too) is what made the "
        "template look like stats."
    ),
    "blocker": (
        "Where a real character's stats-at-level-N come from is still open.  The "
        "battle slot's stats arrive from the char-record array (0x800DED50 reads "
        "rec+0x01..+0x08 into slot+0xB94, and 0x800DED6C/74 copy rec+0x04/+0x06 "
        "into slot +0x10/+0x12), so the source is the persistent 0x50 table at "
        "gs+0x294.  The routine that WRITES that table as levels change was not "
        "located: the table's base is regenerated at runtime (lw from "
        "0x8017DB24, the game-state pointer), so no absolute address literal "
        "for it exists in the code; a static scan for its address finds "
        "nothing.  It needs either the level-up event path or the boot/save-load "
        "copier to be walked."
    ),
}


def participant_layout() -> dict:
    """The offsets every formula above indexes, with the instruction that fixes each."""
    return {
        "participant_ptr": {"addr": PARTICIPANT_PTR, "site": 0x800DDFD8},
        "participant_malloc": {"addr": PARTICIPANT_ALLOC, "size": PARTICIPANT_MAGIC},
        "slot_array": {"base_off": SLOT_ARRAY_OFF, "stride": SLOT_STRIDE,
                       "site": 0x800E62DC},
        "battle_slot_array": {"base_off": BATTLE_SLOT_ARRAY_OFF,
                             "stride": BATTLE_SLOT_STRIDE, "site": 0x800F7EE8},
        "actor_array": {"base_off": ACTOR_ARRAY_OFF, "stride": 0x0C,
                        "site": 0x800DEC3C},
        "char_record_array": {"owner": "game_state", "base_off": CHAR_REC_ARRAY_OFF, "stride": 0x04,
                              "site": 0x800DEC30},
        "participant_count": {"off": PARTICIPANT_COUNT, "site": 0x800E9760},
        "battle_slot_fields": {
            "chara_byte": {"owner": "actor_array_A", "off": BS_CHARA_BYTE, "site": 0x800DEF5C},
            "formation": {"off": BS_FORMATION, "site": 0x800DF0F8},
            "hp_max": {"off": BS_HP_MAX, "site": 0x800DED6C},
            "hp_cur": {"off": BS_HP_CUR, "site": 0x800DED74},
            "stats": {"off": BS_STATS, "site": 0x800F6F28},
            "atk_word": {"off": BS_ATK, "site": 0x800F6F44},
            "def_word": {"off": BS_DEF, "site": 0x800F6F4C},
            "flags": {"off": BS_FLAGS, "site": 0x800E16E0},
            "counter": {"owner": "actor_array_A", "off": BS_COUNTER, "site": 0x800F3A30},
            "state": {"off": BS_STATE, "site": 0x800F6E20},
            "target_class": {"off": BS_TARGETCLASS, "site": 0x800F7FEC},
            "stat_flags": {"off": BS_STATFLAGS, "site": 0x800E16E0},
            "accum_damage": {"off": BS_ACCUM, "site": 0x800E177C},
        },
        "enemy_record_fields": {
            "name_codes": {"off": 0x00, "size": 16, "site": 0x800DF0AC},
            "level": {"off": 0x10, "size": 1, "site": 0x800E9828},
            "formation_footprint": {"off": 0x11, "size": 1, "site": 0x800F7828},
            "hp": {"off": 0x12, "size": 2, "site": 0x800DF0B4},
            "stats": {"off": 0x14, "size": 12, "order": ["PWR","SKL","DEF","SPD","MGC","LUK"], "site": 0x800DF0D0},
            "element_coefficients": {"off": 0x20, "size": 6, "site": 0x80125C14},
            "features": {"off": 0x26, "size": 2, "site": 0x800F4AD0},
            "actor_script_table": {"off": 0x28, "size": 4, "site": 0x800DF0A0},
            "sprite_section": {"off": 0x2C, "size": 4, "site": 0x800DEFBC},
            "decision_callback": {"off": 0x30, "size": 4, "site": 0x800F41E4},
            "encoded_money": {"off": 0x34, "size": 2, "site": 0x800E99F0},
            "item_rate_pairs": {"off": 0x36, "size": 6, "site": 0x800E9AC0},
            "script_pixel_offsets": {"off": 0x3C, "size": 4, "site": 0x800DF088},
        },
        "char_record_fields": {
            "id": {"off": CR_ID, "site": 0x80043274},
            "level": {"off": CR_LEVEL, "site": 0x800E982C},
            "stats_base": {"off": CR_STATS_BASE, "site": 0x800D4ED8},
        },
        "char_context_fields": {
            "record_pointer": {"off": CR_SUBSTRUCT, "site": 0x800DEC88},
        },
    }


# ---------------------------------------------------------------------------
# Plain-Python evaluations, for tests and for a port
# ---------------------------------------------------------------------------
def bios_rand(seed: int) -> tuple[int, int]:
    """A0 0x2F as documented for this SCPH-1001 BIOS: returns (value, new_seed)."""
    seed = (seed * 1103515245 + 12345) & 0xFFFFFFFF
    return (seed >> 16) & RAND_MAX, seed


def sra(value: int, shift: int) -> int:
    """MIPS `sra`: arithmetic shift, floor-rounded (rounds toward -inf)."""
    return value >> shift


def mips_mod(a: int, b: int) -> int:
    """MIPS `div` + `mfhi`: the REMAINDER TRUNCATES TOWARD ZERO.

    Python's `%` floors toward -inf, so `-20 % 4` is 0 in both but `-19 % 4` is
    -3 here and 1 in Python. Every formula below goes through this helper; the
    one place it matters is the `d < 10` branch, where `d` can be negative.
    """
    if b == 0:
        raise ZeroDivisionError("mips_mod")
    q = abs(a) // abs(b)
    if (a < 0) != (b < 0):
        q = -q
    return a - q * b


def hit_roll(spd_self: int, spd_other: int, rand_raw: int) -> bool:
    """0x800F7D5C.  rand_raw is a bios_rand() result (0..32767)."""
    diff = spd_self - (spd_other - 0x50)
    if diff < 0x3C:
        diff = 0x3C
    if diff >= 0x64:
        diff = 0x63
    return (rand_raw % 100) < diff


def mips_div(a: int, b: int) -> int:
    """Signed integer quotient, truncating toward zero."""
    return (a-mips_mod(a,b))//b


def physical_damage(atk_word: int, def_word: int, rand_raw: int,
                    element_type: int = 0, target_action: int = 0,
                    element_index_valid: bool = False, element_match_flag: int = 0,
                    element_bonus: int = 0, target_is_party: bool = True,
                    attacker_is_party: bool = True) -> int:
    """0x800F7E90, returning the value the caller then multiplies by 3.

    `atk_word` is the attacker's battle-slot +0x30 and `def_word` is the
    target's battle-slot +0x32 (the loads are `lhu` at 0x800F7EF4 / 0x800F7EF8
    and the subtraction is `subu` at 0x800F7F00, so both operands are
    zero-extended halfwords: pass the unsigned 0..0xFFFF values and this
    reproduces the engine exactly). Enemy words are initialized from PWR/DEF
    at0x800F6F44/0x800F6F4C and receive the modifier pass at0x800F7024..7034.
    The unrelated speed-priority selector is0x800F4698.

    rand_raw is the FIRST bios_rand() result this call consumes (0..32767).
    element_type is attacker persistent record+0x46; element_bonus comes from
    that record+0x46+element_type. element_match_flag is target actor metadata
    +0x20+resolved element index. These are separate fields, applied in order.
    """
    d = (atk_word & 0xFFFF) - (def_word & 0xFFFF)
    if d < 10:
        d = (d + 1) - mips_mod(rand_raw, 4)
    else:
        rem = mips_mod(rand_raw, d)  # d >= 10 here, so no div-by-zero
        d += mips_div(d//2-rem,5)
    if target_is_party and target_action == 1:
        d = mips_div(d,2)
    if attacker_is_party:
        if element_index_valid and element_match_flag == 1:
            d += mips_div(d,2)
        if element_type in (1,3):
            d += mips_div(d,20)*element_bonus
    if d <= 0:
        d = 1
    return d


def magic_damage(stat_self: int, stat_other: int, rand_raw: int,
                 element: int = 0, element_index: int = 0) -> int:
    """0x800F8174: shared variance on B+0x2C, followed by the rune-selector halve.

    0x800F81DC loads the second argument's stat into a1; 0x800F81E4 loads
    the first argument's stat into v0. The subtraction is self minus other.
    Only the low bytes of the element and resolved selector participate.
    """
    d = (stat_self & 0xFFFF) - (stat_other & 0xFFFF)
    if d < 10:
        d = (d + 1) - mips_mod(rand_raw, 4)
    else:
        d += mips_div(d//2-mips_mod(rand_raw,d),5)
    if (element_index & 255) in (7, element & 255):
        d = mips_div(d,2)
    if d <= 0:
        d = 1
    return d


def hp_apply(hp_cur: int, hp_max: int, damage: int, status_flags: int = 0) -> int:
    """0x800E1654: returns the value the routine leaves in $v0 (see the note).

    The clamp is NOT `min(damage, hp_cur)`.  The exact instructions are:

        0x800E1750  lh  $a1,0x12($v1)      a1 = hp_cur
        0x800E1754  lh  $a0,0x10($v1)      a0 = hp_max
        0x800E1758  subu $v0,$a1,$s0       v0 = hp_cur - damage
        0x800E175C  slt  $v0,$a0,$v0       v0 = (hp_max < hp_cur - damage)
        0x800E1760  beq  $v0,$zero,skip
        0x800E1768  subu $s0,$a1,$a0       damage = hp_cur - hp_max

    so the clamp only ever *reduces* the damage, and only when
    `hp_max < hp_cur - damage`, i.e. when the incoming damage is *negative*
    (a heal that would push hp_cur past hp_max).  A positive damage larger than
    hp_cur leaves the function's $v0 NEGATIVE; the real HP is not stored here at
    all -- this routine is a state-machine handler that reports the remainder,
    and the HP write lives in the phase driver.  Model the RETURN VALUE, not a
    stored field.
    """
    if status_flags & 0x8000:
        damage = 0
    cur = hp_cur - damage
    if hp_cur < hp_max and hp_max < cur:
        damage = hp_cur - hp_max        # heal clamped to the max
    return hp_cur - damage


def growth_divisor(level: int) -> int:
    """0x800E632C..0x800E6344: T = sum_{k=level..1} k (order irrelevant)."""
    return level * (level + 1) // 2


def growth_value(v0: int, v1: int, level: int) -> int:
    """0x800E6368-0x800E6400 generalised.

    This is what 0x800E62B0 computes, and it is an interpolation across a step
    count -- not a per-character stat table.  Kept because the shape is what a
    level-scaled quantity in this engine looks like.

    The divisor is T = level(level+1)/2 and the numerator subtracts the
    triangular *partial* sum that the loop at 0x800E632C..0x800E6340 builds, so
    the closed form is the midpoint plus a level-proportional ramp:

        result = (v0 + v1)//2 + ((v1 - v0) * level) // (2*T)
    """
    t = growth_divisor(level)
    if t == 0:
        return v0
    return (v0 + v1) // 2 + ((v1 - v0) * level) // (2 * t)


def as_json() -> dict:
    return {
        "provenance": {
            "main_exe_base": hex(MAIN_BASE),
            "slus_base": hex(SLUS_BASE),
            "rng": hex(BIOS_RAND),
        },
        "layouts": participant_layout(),
        "formulas": FORMULAS,
        "growth": GROWTH_NEGATIVE,
    }


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--formula")
    args = ap.parse_args(argv)

    if args.json:
        json.dump(as_json(), sys.stdout, indent=1)
        print()
        return 0
    if args.formula:
        f = FORMULAS.get(args.formula)
        if f is None:
            print(f"unknown formula: {args.formula}", file=sys.stderr)
            return 2
        print(json.dumps(f, indent=1))
        return 0
    for key, f in FORMULAS.items():
        print(f"{key:22} 0x{f['routine']:08X}  {f['evidence']}")
        print(f"    {f['summary']}")
    print()
    print(f"growth: {GROWTH_NEGATIVE['evidence']} -- {GROWTH_NEGATIVE['claim']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

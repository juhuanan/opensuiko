#!/usr/bin/env python3
"""Gate for the per-battle EXP award in kit/tools/exp_award.py.

Every assertion is one of

  * an **instruction word** read out of MAIN.EXE (the encoding is the fact --
    the immediates are compared, never a fitted number),
  * an **exhaustive image scan** whose result set is asserted exactly (so the
    negative "no other writer of the pool exists" is re-derived, not trusted),
  * a **complete static source span** and an independent arithmetic model
    compared with the award helper over synthetic battles,
  * a **disc byte** (the XP table, the enemy records of the per-area overlays),
  * or a **behavioural property** the user's own memory of play states
    (large when underlevelled -> a floor of 5 when far ahead, monotone
    non-increasing, never 0).

Nothing here is asserted because a document says so.

Run:  .venv/bin/python kit/tests/test_exp_award.py
"""
from __future__ import annotations

from hashlib import sha256
import os
import struct
import sys

_TOOLS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools")
sys.path.insert(0, os.path.abspath(_TOOLS))

import disc  # noqa: E402
import enemy_sprites as ES  # noqa: E402
import exp_award as EA  # noqa: E402
import growth_rules as GR  # noqa: E402
import maindec  # noqa: E402
from war_text import decode  # noqa: E402

PASS = 0


def ok(cond, msg):
    global PASS
    assert cond, "FAIL: " + msg
    PASS += 1
    print(f"PASS: {msg}")


def simm(w):
    v = w & 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def rs(w):
    return (w >> 21) & 0x1F


def rt(w):
    return (w >> 16) & 0x1F


def rd(w):
    return (w >> 11) & 0x1F


# ---------------------------------------------------------------------------
# 1. the address chain: the call site, the table base, the block pointer
# ---------------------------------------------------------------------------
def test_call_site():
    jals = []
    for va in range(EA.MAIN_BASE, EA.MAIN_END, 4):
        w = maindec.mword(va)
        if w is not None and (w >> 26) == 3:
            tgt = ((va + 4) & 0xF0000000) | ((w & 0x03FFFFFF) << 2)
            if tgt == EA.AWARD_FN:
                jals.append(va)
    ok(jals == [EA.AWARD_CALL],
       "0x800E9744 has exactly ONE call site in MAIN.EXE, `jal` at 0x800E8244 "
       "(re-derived by scanning every jal/j target)")

    # the handler that contains 0x800E8244 is registered at 0x800DE178
    lui, addiu = maindec.mword(0x800DE178), maindec.mword(0x800DE17C)
    ok((lui >> 26) == 0x0F and (lui & 0xFFFF) == 0x800F and simm(addiu) == -0x7E74,
       "0x800DE178 is `lui $v1,0x800f` / `addiu $v1,$v1,-0x7e74` -- the battle-result "
       "handler that computes the award is registered through this pair")
    handler = ((lui & 0xFFFF) << 16) + simm(addiu)
    ok(handler == 0x800E818C and handler <= EA.AWARD_CALL < 0x800E82CC,
       "that pair resolves to 0x800E818C (sign-extended, not the displayed 0x800f818c) "
       "and the single `jal 0x800E9744` at 0x800E8244 lies inside it")



def test_result_phase():
    # Positive producer -> combat completion -> reward initialization chain.
    anchors = {
        0x800DEB64:0x244264F0,0x800DEB74:0xAC220000,
        0x800DEB7C:0x2442E0B0,0x800DEB8C:0xAC220000,
        0x800F652C:0x24740B40,0x800F653C:0x24700B94,
        0x800F6540:0x9602004A,0x800F6548:0x30420008,
        0x800F654C:0x1040000B,0x800F6538:0x34120001,
        0x800F6564:0xA2120045,0x800F6568:0xA2120046,
        0x800E2DD8:0x24830B40,0x800E2DF0:0x34020001,
        0x800E2DF4:0xA0620045,
        0x800F74DC:0xAC80002C,0x800F7510:0x90620045,
        0x800F7518:0x14400005,0x800F752C:0xAC82002C,
        0x800F7550:0x8C62002C,0x800F7558:0x10400005,
        0x800F7570:0xAC600038,0x800F7578:0xAC621264,
        0x800F75A8:0x244278B0,0x800F75AC:0x0803DDD2,
        0x800F774C:0x2421DA90,0x800F7754:0xAC220000,
        0x800F78C0:0x34020001,0x800F78CC:0x2484FFFF,
        0x800F78D0:0x04800002,0x800F78D8:0x2402FFFF,
        0x800F78DC:0x03E00008,
        0x800DE0C8:0x00109080,0x800DE0D0:0x2421DA94,
        0x800DE0E0:0x0040F809,0x800DE0F8:0x1062002C,
        0x800DE0FC:0x34020001,0x800DE100:0x1462002A,
        0x800DE13C:0x0C03796B,0x800DE150:0x8C620034,
        0x800DE158:0x1440000B,0x800DE160:0x8C620038,
        0x800DE168:0x14400008,0x800DE170:0x2622FFFC,
        0x800DE184:0xAC430000,
        0x800DE5D4:0x90830045,0x800DE5DC:0x14600005,
        0x800DE5F0:0xA4620006,
        0x800E81B0:0x24500B40,0x800E820C:0x26040054,
        0x800E8210:0x90820045,0x800E822C:0xACA2000C,
        0x800E8244:0x0C03A5D1,
    }
    for pc, expected in anchors.items():
        assert maindec.mword(pc) == expected, hex(pc)
    # Terminal delay changes state/timer only; it preserves raised actor flags.
    stores = [maindec.mword(pc) for pc in range(0x800F78B0,0x800F78E4,4)
              if maindec.mword(pc)>>26 in (40,41,43)]
    ok(stores == [0xACA33428,0xACA41264],
       'combat completion timer preserves participant flags before returning 1')
    ok(all(maindec.mword(pc)==word for pc,word in anchors.items()),
       '%d raw status-writer, combat-completion, parent-callback and reward-entry anchors' % len(anchors))


def test_xp_table():
    lui, addiu = maindec.mword(0x800E9764), maindec.mword(0x800E9768)
    ok((lui >> 26) == 0x0F and (lui & 0xFFFF) == 0x8017 and rt(lui) == 17,
       "0x800E9764 is `lui $s1,0x8017`")
    ok((addiu >> 26) == 0x09 and rs(addiu) == 17 and (addiu & 0xFFFF) == 0xBDC8,
       "0x800E9768 is `addiu $s1,$s1,0xBDC8` (raw immediate 0xBDC8)")
    ok(simm(0xBDC8) == -0x4238,
       "the raw 0xBDC8 sign-extends to -0x4238, so the base is 0x80170000 - 0x4238 "
       "(AGENTS.md section 5)")
    ok(EA.XP_TABLE == 0x8016BDC8,
       "the XP table base is 0x8016BDC8 (NOT the corpus's 0x8017BDC8)")
    ok(EA.XP_TABLE < EA.MAIN_END,
       "0x8016BDC8 lies inside the MAIN.EXE image 0x800C0800..0x80179000, so the "
       "entries are disc data")

    tbl = EA.xp_table()
    want = [1, 2, 3, 5, 7, 10, 15, 20, 30, 50, 70, 90, 120, 160,
            200, 400, 900, 1600, 2600, 3900, 5100, 6000, 6900, 7500,
            8000, 8500, 9000, 9300, 9700, 10000]
    ok(tbl == want,
       "the 30 words at 0x8016BDC8 + 4*dl for dl = -14..+15 are the monotone "
       "1..10000 run (read straight from the image, index 0 = 0x8016BD90 = 1)")
    ok(all(tbl[k] < tbl[k + 1] for k in range(len(tbl) - 1)),
       "the table is STRICTLY INCREASING in dl -- the corpus's 'non-monotone tail' "
       "was its own 14-entry shift, not the data")
    ok(EA.XP_TABLE_LO == 0x8016BD90 and EA.XP_TABLE_HI == 0x8016BE08,
       "the table body spans 0x8016BD90..0x8016BE07, i.e. it ends exactly where the "
       "HP growth table starts")
    ok(GR.hp_table()[0] == maindec.mword(0x8016BE08) == 835,
       "0x8016BE08 is the HP growth table's first word (835, growth_rules), so the "
       "XP table occupies all 30 words of the run without overlap")
    ok(EA.XP_TABLE_HI == GR.HP_TABLE_VA == 0x8016BE08,
       "exp_award's table end and growth_rules' HP table base are the same address -- "
       "the two derivations abut without a gap")


def test_xp_table_is_referenced_once():
    xrefs = EA.address_xrefs(EA.XP_TABLE)
    ok(xrefs == [0x800E9764],
       "0x8016BDC8 is built from a lui/addiu pair at EXACTLY one site in the whole "
       "image: 0x800E9764")
    pat = struct.pack("<I", EA.XP_TABLE)
    ok(maindec.body().find(pat) < 0,
       "no raw 32-bit pointer literal to 0x8016BDC8 exists anywhere in the image, "
       "so no pointer table installs it either")
    ok(maindec.mword(0x800E9864) == 0x8C420000,
       "0x800E9864 is `lw $v0,0x0($v0)` -- the one consumer of the table")


# ---------------------------------------------------------------------------
# 2. the index: two levels, one subtraction, two clamps
# ---------------------------------------------------------------------------
def test_clamp_and_index():
    ok(maindec.mword(0x800E9828) == 0x90440010,
       "0x800E9828 is `lbu $a0,0x10($v0)` -- the ENEMY record's level byte")
    ok(maindec.mword(0x800E982C) == 0x9062000D,
       "0x800E982C is `lbu $v0,0xd($v1)` -- the character record's level byte, the "
       "same +0x0D growth_rules proves")
    ok(maindec.mword(0x800E9834) == 0x00822023,
       "0x800E9834 is `subu $a0,$a0,$v0` -- enemy_level - char_level")
    ok(maindec.mword(0x800E9838) == 0x2882FFF2 and simm(maindec.mword(0x800E9838)) == -14,
       "0x800E9838 is `slti $v0,$a0,-0xe` -- the low clamp edge is dl = -14")
    ok(maindec.mword(0x800E9848) == 0x2404FFF2,
       "0x800E9848 is `addiu $a0,$zero,-0xe` -- the low clamp value")
    ok(maindec.mword(0x800E9840) == 0x28820010,
       "0x800E9840 is `slti $v0,$a0,0x10` -- 16, i.e. the high edge is dl = 15")
    ok(maindec.mword(0x800E9854) == 0x3404000F,
       "0x800E9854 is `ori $a0,$zero,0xf` -- the high clamp value")
    ok(maindec.mword(0x800E9858) == 0x00041080 and maindec.mword(0x800E985C) == 0x00511021,
       "0x800E9858/5C are `sll $v0,$a0,2` / `addu $v0,$v0,$s1` -- word index into the "
       "table base")
    # property: the clamp over the whole byte domain
    ok(all(EA.diff_index(el, cl) == max(-14, min(15, el - cl))
           for el in range(256) for cl in range(256)),
       "diff_index() equals clamp(enemy_level - char_level, -14, 15) over all 65536 "
       "(enemy, char) byte pairs")


def test_enemy_level_field_is_read_twice():
    # a second, independent consumer of enemy_record+0x10 as a level: the cumulative
    # enemy-level sum G+0x126C, divided by the enemy count in the result screen.
    ok(maindec.mword(0x800DEF30) == 0x92220010,
       "0x800DEF30 is `lbu $v0,0x10($s1)` in the enemy spawn -- the same field, "
       "accumulated into G+0x126C")
    ok(maindec.mword(0x800DEF2C) == 0x8CA3126C and maindec.mword(0x800DEF3C) == 0xACA2126C,
       "0x800DEF2C/3C are `lw $v1,0x126c($a1)` / `sw $v0,0x126c($a1)` -- a running sum "
       "of that byte")
    ok(maindec.mword(0x800F848C) == 0x8CA2126C and maindec.mword(0x800F8490) == 0x8CA40020,
       "0x800F848C/90 divide that sum by G+0x20 (the encounter's enemy count), which is "
       "only meaningful if +0x10 is a level")


def test_enemy_records_off_the_disc():
    """The level field, cross-checked against every enemy record of every area."""
    iso = os.path.join(os.path.dirname(_TOOLS), "extracted", "iso_files.json")
    import json
    with open(iso) as f:
        rows = [r for r in json.load(f) if not r.get("dir")]
    files = [r for r in rows if r["path"].endswith("_DATA.BIN") and r["size"] > 16]
    ok(len(files) == 11, "eleven per-area `*_DATA.BIN` overlays")
    total, levels, bad = 0, set(), 0
    for r in files:
        d = disc.extract(r["lba"], r["size"])
        secs, _ = ES.parse_sections(d)
        for t in ES.find_enemy_tables(d, secs):
            for ro in t["record_offsets"]:
                total += 1
                lv = d[ro + 0x10]
                levels.add(lv)
                hp = struct.unpack_from("<H", d, ro + 0x12)[0]
                if not (1 <= lv <= 99 and hp > 0):
                    bad += 1
    ok(total >= 30 and bad == 0,
       "all %d enemy records in the 11 area overlays have +0x10 in 1..99 and a "
       "non-zero u16 HP at +0x12 -- the award's enemy level is disc data, not a guess"
       % total)
    ok(len(levels) >= 5,
       "those records carry %d distinct +0x10 values, so the level-difference index is "
       "actually exercised" % len(levels))


# ---------------------------------------------------------------------------
# 3. the write: which slot, and who else writes it
# ---------------------------------------------------------------------------
def test_slot_address():
    ok(maindec.mword(0x800E9798) == 0x27070004,
       "0x800E9798 is `addiu $a3,$t8,0x4` with $t8 = *(0x80179FD0), so $a3 = B + 4*1")
    ok(maindec.mword(0x800E990C) == 0x24E70004 and maindec.mword(0x800E9910) == 0x25CE0004,
       "0x800E990C/10 advance $a3 and $t6 by 4 per participant -- $a3 = B + 4*i")
    ok(maindec.mword(0x800E9870) == 0xAD230010 and simm(maindec.mword(0x800E9870)) == 0x10,
       "0x800E9870 is `sw $v1,0x10($t1)` with $t1 = $a3, so the slot is B + 0x10 + 4*i")
    ok(maindec.mword(0x800E97C8) == 0x00E04821,
       "0x800E97C8 is `addu $t1,$a3,$zero` -- the accumulator's destination")


def test_pool_is_exclusive():
    loads = EA.block_loads()
    ok(len(loads) == 62 and min(loads) >= 0x800E818C and max(loads) <= 0x800E9C24,
       "the ONLY instructions that obtain the battle context are the 62 loads of "
       "*(0x80179FD0), all inside 0x800E818C..0x800E9C24")
    sites = sorted(p["site"] for p in EA.pool_writers())
    expect = sorted(EA.POOL_TOUCH_WHITELIST) + sorted(EA.NON_POOL_STORES)
    ok(sites == sorted(set(expect)),
       "the image's stores at a pool-slot immediate with a non-stack base are exactly "
       "the 7 whitelisted pool sites plus the 3 bases that are other structs "
       "(0x800E87EC sprite primitive, 0x800E9100/0x800E9110 game-state gold)")
    for site in sorted(EA.POOL_TOUCH_WHITELIST):
        ok(maindec.mword(site) is not None,
           "whitelisted pool site 0x%08X resolves to an instruction word" % site)
    ok(sites.count(0x800E9870) == 1 and 0x800E9870 in EA.POOL_TOUCH_WHITELIST,
       "the award's own slot write is in the whitelist")
    # the jal argument check: the band passes B to one helper only
    ok(maindec.mword(0x800E9580) == 0x24A52238,
       "0x800E9580 (the delay slot of `jal 0x800D4EC0` at 0x800E957C) is `addiu $a1,$a1,0x2238` -- the single B-derived pointer handed to "
       "a callee in the band (the status text buffer), so no helper can write the pool")


def test_consumer_matches():
    ok(maindec.mword(0x800E89B4) == 0x8CA2002C,
       "0x800E89B4 is `lw $v0,0x2c($a1)` -- the victory sequence's participant index")
    ok(maindec.mword(0x800E89BC) == 0x00021080 and maindec.mword(0x800E89C0) == 0x00451021,
       "0x800E89BC/C0 scale it by 4 and add the block pointer")
    ok(maindec.mword(0x800E89C8) == 0x8C420010,
       "0x800E89C8 is `lw $v0,0x10($v0)` -- reading exactly the slot the award writes")
    ok(maindec.mword(0x800E89C4) == 0x9483000E and maindec.mword(0x800E89D0) == 0x00621821,
       "0x800E89C4/D0 add it to the record's u16 EXP at +0x0E")
    ok(simm(maindec.mword(0x800E89D4)) == 0x3E8,
       "0x800E89D4 is `slti $v1,$v1,0x3e8` -- the slot's value is EXP because it is "
       "tested against the flat 1000 per level")
    ok(maindec.mword(0x800E88F0) == 0xAC65002C and maindec.mword(0x800E8C34) == 0xAC83002C,
       "0x800E88F0 sets B+0x2C (the pool index) and 0x800E8C34 increments it -- the "
       "index runs 1..party_count")


# ---------------------------------------------------------------------------
# 4. the rule executes
# ---------------------------------------------------------------------------
def test_min_and_doubling():
    ok(maindec.mword(0x800E9898) == 0x8D43001C,
       "0x800E9898 is `lw $v1,0x1c($t2)` -- the divisor is G+0x1C, the party count")
    ok(maindec.mword(0x800E98A0) == 0x0043001A and maindec.mword(0x800E98C8) == 0x00001012,
       "0x800E98A0/C8 are `div $v0,$v1` / `mflo $v0` -- one division, truncating")
    ok(maindec.mword(0x800E98D4) == 0x28420005 and maindec.mword(0x800E98DC) == 0x34020005,
       "0x800E98D4/DC are `slti $v0,$v0,5` / `ori $v0,$zero,5` -- the FLOOR is 5")
    ok(maindec.mword(0x800E98E0) == 0xACE20010,
       "0x800E98E0 stores the floor back into the slot")
    ok(maindec.mword(0x800E98EC) == 0x9043004C and simm(maindec.mword(0x800E98F0)) == 0x16,
       "0x800E98EC/F0 read record+0x4C and compare against 0x16")
    ok(maindec.mword(0x800E9904) == 0x00021040 and maindec.mword(0x800E9908) == 0xAC620010,
       "0x800E9904/08 are `sll $v0,$v0,1` / `sw $v0,0x10($v1)` -- the doubling is "
       "applied AFTER the floor, to the slot value")


def test_static_award_matches_helper():
    """Check the complete award body and compare the helper with raw-table arithmetic."""
    start, end = 0x800E9744, 0x800E9940
    body = maindec.body()
    ok(sha256(body[start-EA.MAIN_BASE:end-EA.MAIN_BASE]).hexdigest() ==
       '288522d1e3fbe7deb0ab767a163d1e0dba02b22ea1325e1da2e7ce417ec1acab',
       'the complete original award body matches the verified static span')
    for pc, word in {
        0x800E979C: 0x91A20045, 0x800E97A4: 0x10400003, 0x800E97B0: 0xACE00010,
        0x800E97F4: 0x80440000, 0x800E97FC: 0x1080001D, 0x800E9804: 0x8D020000,
        0x800E980C: 0x14500019, 0x800E986C: 0x00621821, 0x800E9888: 0x0046102A,
        0x800E988C: 0x1040FFD0,
    }.items():
        assert maindec.mword(pc) == word, hex(pc)

    xp = struct.unpack_from('<30I', body, 0x8016BD90 - EA.MAIN_BASE)

    def expected(levels, runes, enemies, disabled=None):
        awards = [0]
        for i, (level, rune) in enumerate(zip(levels, runes, strict=True)):
            if disabled and disabled[i]:
                awards.append(0)
                continue
            total = sum(xp[min(29, max(0, enemy - level + 14))] for enemy in enemies)
            awards.append(max(5, total // len(levels)) * (2 if rune == 0x16 else 1))
        return awards

    cases = []
    # systematic: solo party, one enemy, every level difference
    for el in (1, 5, 10, 20, 50, 99):
        for cl in range(1, 100):
            cases.append(([cl], [0], [el]))
    # party sizes and several enemies, the doubling class, out-of-action slots
    for n in (1, 2, 3, 6):
        for m in (0, 1, 3, 6):
            cases.append(([3 + 7 * i for i in range(n)],
                          [0x16 if i % 2 else 3 for i in range(n)],
                          [1 + 13 * j for j in range(m)]))
    cases.append(([40, 40, 40], [0, 0, 0], []))
    cases.append(([5], [0x16], [9]))
    for levels, runes, enemies in cases:
        assert EA.award_pool(levels, runes, enemies) == expected(levels, runes, enemies), (levels, runes, enemies)
    ok(len(cases) == 612, 'independent raw-table arithmetic agrees for 612 award cases')

    for mask in range(8):
        disabled = [bool(mask & (1 << i)) for i in range(3)]
        actual = EA.award_pool([20, 20, 20], [0x16, 0, 0x16], [50], out_of_action=disabled)
        assert actual == expected([20, 20, 20], [0x16, 0, 0x16], [50], disabled), mask
    ok(True, 'out-of-action slots are zero for every three-member mask')
    ok(EA.award_pool([20, 20], [0, 0], [50]) == [0, 5000, 5000],
       'one eligible enemy contributes once, and the divisor uses the full party count')


# ---------------------------------------------------------------------------
# 5. the behavioural curve the user remembers
# ---------------------------------------------------------------------------
def test_behavioural_curve():
    el = 10
    solo = [EA.pool_entry(lv, 0, [el], 1) for lv in range(1, 100)]
    ok(solo[0] == 7500,
       "a level-1 solo character against a level-10 enemy is awarded 7500 EXP -- more "
       "than two levels at 1000 each (the 'levelling super quickly' memory)")
    ok(solo[9] == 200,
       "at the enemy's own level (10) the award is 200")
    ok(solo[18] == 10,
       "nine levels ABOVE the enemy (19 vs 10) the award is exactly 10 -- the user's "
       "'about 10 EXP' lands here")
    ok(all(solo[k] >= solo[k + 1] for k in range(len(solo) - 1)),
       "the award is monotone non-increasing in the character's level across 1..99")
    ok(all(v >= 5 for v in solo),
       "the award is never 0 and never negative for an in-action participant")
    ok(solo[-1] == 5 and solo[30] == 5,
       "once the character is 10+ levels above the enemy the award sits on the floor "
       "of 5 -- the plateau ('and then stopping')")
    ok(min(solo) == 5 and max(solo) == 7500,
       "the whole curve runs 5 .. 7500, i.e. it front-loads and then stops")
    # the doubling class doubles the floor too -- 10 is the floor for such a character
    ok(EA.pool_entry(99, 0x16, [10], 1) == 2 * EA.pool_entry(99, 0, [10], 1) == 10,
       "the 0x16 class doubles the value AFTER the floor, so its plateau is 10")
    # the party division
    ok(EA.pool_entry(1, 0, [10], 3) == 7500 // 3,
       "the sum is divided by the party count (7500/3 = 2500 for a 3-member party)")
    ok(EA.pool_entry(1, 0, [10, 10, 10], 6) == 3 * 7500 // 6,
       "several enemies sum before the division (three level-10 enemies, party of 6)")
    # the level cap is a different mechanism
    ok(EA.pool_entry(99, 0, [99], 1) == 200,
       "at the level cap the pool is still computed and still drained -- the 99 cap is "
       "a separate mechanism from the award floor")


# ---------------------------------------------------------------------------
# 6. the rule as data
# ---------------------------------------------------------------------------
def test_json_shape():
    j = EA.as_json()
    ok(j["terms"]["xp_table"]["entries"] == EA.xp_table(),
       "--json carries the table as it was read from the image")
    ok(j["terms"]["pool_slot"]["write"] == hex(EA.POOL_SLOT_WRITE),
       "--json carries an address per term")
    ok(j["audit"]["xp_table_xrefs"] == [hex(0x800E9764)],
       "--json carries the single xref as an audit result")
    pointer = maindec.mword(0x8016A0E0 + 4 * 0x16)
    name, _ = decode(maindec.body(), pointer - maindec.MBASE, length=20)
    ok(j['terms']['doubling']['rune_name'] == name == 'Fortune Rune',
       'the doubling rune name agrees with its disc table record')
    ok(EA.address_xrefs(EA.PRESENT_FLAG_BASE) ==
       [0x800E2E68, 0x800E99D4, 0x801143B8, 0x80116118],
       "the present-flag array base 0x8017AAF8 is built from `lui 0x8018` + `-0x5508` at "
       "exactly four sites, the same sign-extension shape as the XP table")
    ok(EA.address_xrefs(EA.PRESENT_FLAG_BASE + 4) == [0x800E9774],
       "the award routine itself builds the second word (0x8017AAFC = the array base + "
       "4) as its `t0` start -- word 1 is enemy slot 0, word j+1 is enemy slot j")
    ok(0x800E9870 in [p["site"] for p in EA.pool_writers()],
       "the audit reports the award's own slot write")


def main():
    for fn in (test_call_site, test_result_phase, test_xp_table, test_xp_table_is_referenced_once,
               test_clamp_and_index, test_enemy_level_field_is_read_twice,
               test_enemy_records_off_the_disc,
               test_slot_address, test_pool_is_exclusive, test_consumer_matches,
               test_min_and_doubling, test_static_award_matches_helper,
               test_behavioural_curve, test_json_shape):
        fn()
    print("PASS: %d assertions -- the per-battle EXP award is derived" % PASS)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

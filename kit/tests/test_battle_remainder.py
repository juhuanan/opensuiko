#!/usr/bin/env python3
"""Gate for `kit/tools/battle_remainder.py`.

Run directly (pytest is not installed):

    .venv/bin/python kit/tests/test_battle_remainder.py

Every assertion here is a claim the producer derived from disc bytes and
instruction encodings; nothing is fitted, and nothing asserts a negative
without also asserting the search that produced it.
"""
import os
import struct
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_KIT = os.path.dirname(_HERE)
sys.path.insert(0, os.path.join(_KIT, "tools"))

import battle_remainder as br   # noqa: E402
from mipsdec import dec         # noqa: E402

PASS = 0


def check(cond, msg):
    global PASS
    assert cond, msg
    PASS += 1
    print(f"PASS: {msg}")


def main() -> int:
    img = br.maindec.body()

    # ---------------------------------------------------------------- item 1
    # The address is a `lui` sign-extension.  Assert BOTH the encoding and the
    # resulting address, so a future editor cannot "fix" the number without
    # breaking the arithmetic.
    lui, addiu = br.mword(0x800E9764), br.mword(0x800E9768)
    check((lui >> 26) & 0x3F == 0x0F and (lui & 0xFFFF) == 0x8017,
          "0x800E9764 is `lui $s1,0x8017`")
    check((addiu >> 26) & 0x3F == 0x09 and (addiu & 0xFFFF) == 0xBDC8,
          "0x800E9768 is `addiu $s1,$s1,-0x4238` (raw imm 0xBDC8)")
    check(br.s16(0xBDC8) == -0x4238,
          "sign-extending 0xBDC8 gives -0x4238, not a positive offset")
    check(br.weight_table_base() == 0x8016BDC8,
          "the table base is 0x8016BDC8 (0x80170000 - 0x4238)")
    check(br.weight_table_base() != br.WEIGHT_WRONG_ADDR,
          "the table is NOT at 0x8017BDC8 (that reading forgot the sign)")
    check(br.weight_table_is_static(),
          "0x8016BDC8 lies inside the MAIN.EXE image 0x800C0800..0x80179000")
    check(0x8017BDC8 >= br.MAIN_END,
          "0x8017BDC8 is above the image end, which is why the old reading called it BSS")

    wt = br.weight_table()
    check(len(wt) == 30, "the table has exactly 30 entries for dl in [-14,15]")
    check(all(isinstance(v, int) for v in wt), "the entries are signed i32 reads")
    # The table is read as a signed word at 0x800E9864 after `4*dl + base`
    # (0x800E9858/5C), so dl = -14 is the word 56 bytes BELOW the base built at
    # 0x800E9764/68.  Re-read it the same way straight from the image to prove
    # the producer did not transform it.  (Corrected 2026-10-07: reading from the
    # base upward shifted every entry by 14 and ran the tail into the HP growth
    # table at 0x8016BE08 -- see kit/docs/exp_award.md, which identifies this
    # table as the per-battle EXP award.)
    lo = br.weight_table_base() + 4 * br.WEIGHT_DL_MIN
    raw = [struct.unpack_from("<i", img, lo - br.MAIN_BASE + 4 * k)[0]
           for k in range(30)]
    check(raw == wt, "the table is a plain signed-word read of the image, unmodified")
    check(raw[0] == 1 and raw[14] == 200 and raw[29] == 10000,
          "dl -14 -> 1, dl 0 -> 200, dl +15 -> 10000 (the entries are monotone in dl)")
    check(all(raw[k] < raw[k + 1] for k in range(29)),
          "the 30 entries are STRICTLY INCREASING in dl -- there is no non-monotone tail")
    check(lo + 4 * 30 == 0x8016BE08,
          "the table body ends exactly where the HP growth table starts (0x8016BE08), "
          "so it does not collide with the participant pointer 0x8017BE3C")
    check(br.weight_at(-14) == raw[0] and br.weight_at(15) == raw[29],
          "weight_at() maps dl -14..15 onto index 0..29")
    try:
        br.weight_at(-15)
        check(False, "weight_at(-15) must raise")
    except ValueError:
        check(True, "weight_at() refuses a dl outside the proven clamp")

    # The *other* array the same routine reads, and its writer.
    pwa = br.participant_weight_array()
    check(pwa["addr"] == 0x80179FD0,
          "the participant weight array is 0x80179FD0 (0x80180000 - 0x6030)")
    check(pwa["writer_site"] == br.weight_writer_site() == 0x800E81B8,
          "its writer is the `sw` at 0x800E81B8")
    w = br.mword(0x800E81A8)
    check((w >> 26) & 0x3F == 0x0D and (w & 0xFFFF) == 0x2258,
          "0x800E81A8 is `ori $a0,$zero,0x2258` - the malloc size")
    check(br.mword(0x800E81AC) == 0x0C030B4C,
          "0x800E81AC is `jal 0x800C2D30` (the allocator)")

    # ---------------------------------------------------------------- item 2
    check(br.direct_callers(br.MAGIC_DAMAGE) == [],
          "0x800F8174 has ZERO direct jal/j call sites in MAIN.EXE")
    lit = br.literal_pointer_sites(br.MAGIC_DAMAGE)
    check(lit == [br.MAGIC_DAMAGE_PTR_SLOT],
          "0x800F8174 occurs exactly once in MAIN, as data at 0x8016B7D8")

    run = br.library_run()
    check(run["base"] == br.LIB_TABLE_BASE == 0x8016B680,
          "the pointer run starts at 0x8016B680")
    check(run["count"] == 87, "the run holds 87 code pointers")
    idx = [e for e in run["entries"] if e["slot"] == br.MAGIC_DAMAGE_PTR_SLOT]
    check(len(idx) == 1 and idx[0]["index"] == 86,
          "the magic-damage slot is index 86 of that run")

    loads = br.library_run_loads()
    check(loads == [],
          "NO instruction in MAIN.EXE reads any address in the 87-entry run")
    stores = br.stores_into_library_run()
    check(stores == [],
          "NO instruction in MAIN.EXE writes into the 87-entry run")
    # MAIN installs the library into the scene; overlay code reads it.
    store_site = br.mword(br.LIB_TABLE_STORE_SITE)
    check((store_site >> 26) & 0x3F == 0x2B and (store_site & 0xFFFF) == 0x1258,
          "0x800DDFC0 is `sw $v1,0x1258($v0)` - the library base into the scene")
    reads_1258 = br.participant_1258_reads()
    check(reads_1258 == [],
          "MAIN has no immediate-offset LOAD of scene+0x1258")
    check(br.vad_magic_caller()['call'] == 0x8001302C,
          "VAD reads scene+0x1258 and calls magic damage through slot+0x158")
    # every 0x1258 memory op in the image is that one store
    allops = [br.MAIN_BASE + i * 4 for i in range((br.MAIN_END - br.MAIN_BASE) // 4)
              if (struct.unpack_from("<I", img, i * 4)[0] & 0xFFFF) == 0x1258]
    check(allops == [br.LIB_TABLE_STORE_SITE],
          "0x1258 appears exactly once in the image, at the store site")

    jt = br.magic_jump_table()
    check(len(jt) == 31, "the magic-damage jump table has 31 words")
    check(br.mword(br.MAGIC_JUMP_BOUND) == 0x3402001E,
          "0x800F82A8 is `ori $v0,$zero,0x1e` - the table bound")
    check(br.mword(br.MAGIC_JUMP_DISPATCH) == 0x00400008,
          "0x800F82D0 is `jr $v0` - the dispatch")
    distinct = br.magic_jump_distinct_targets()
    check(len(distinct) == 8, "the 31-entry table names 8 distinct code targets")
    check(all(0x800C0800 <= d["target"] < br.MAIN_END for d in distinct),
          "every jump-table arm is real code inside the image")

    # ---------------------------------------------------------------- item 3
    pals = br.battle_bin_palettes()
    check(len(pals) == 3 and all(len(p) == 32 for p in pals),
          "BATTLE.BIN section 0 carries three 32-word palettes")
    check(br.BATTLE_SECTION0_PALETTES == (0x20, 0x60, 0xA0),
          "those palettes are at file 0x20/0x60/0xa0")
    check(10 == br.BATTLE_PLANE_COUNT - 3,
          "10 of the 13 planes therefore have no palette in the file")

    # ---------------------------------------------------------------- item 4
    wh = br.w_header()
    check(wh["magic"] == br.W_HEADER_MAGIC == b"LNK\x02",
          "W_HEADER.BIN begins with the LNK\\x02 magic")
    check(wh["size"] == 67 and wh["lba"] == 183803,
          "W_HEADER.BIN is 67 bytes at LBA 183803")
    check(br.w_header_record_is_war_table_entry(),
          "W_HEADER is WAR resource record: size 67 @0x8016481C, LBA 183803 @0x80164820")
    syms = br.w_header_symbols()
    check([s["name"] for s in syms] == ["header", "war", "war_loop"],
          "the three symbol names decode from the bytecode")
    check([s["value"] for s in syms] == [0x5462, 0x5463, 0x5464],
          "their values are 0x5462/0x5463/0x5464")
    check(all(s["base"] == 0x80000 for s in syms),
          "the bytecode's base field is 0x80000")
    # The decisive independent check: 0x5464 is a real prologue in WAR1.BIN.
    tgt = br.warrior_symbol_is_real_code()
    check(tgt["war_loop"]["word"] == 0x27BDFFE0,
          "0x5464 is `addiu $sp,$sp,-0x20` - a real function prologue in WAR1.BIN")
    check(tgt["war_loop"]["overlay_offset"] == 0x5464,
          "war_loop's offset is 0x5464 in the WAR overlay")
    check(tgt["header"]["overlay_offset"] == 0x5462 and
          tgt["war"]["overlay_offset"] == 0x5463,
          "header/war are 0x5462/0x5463")

    # ---------------------------------------------------------------- item 5
    # Follow the per-area random roll, selected encounter, queued mode, and
    # battle-side read. Each word is re-read from the MAIN image.
    flow = br.encounter_requester()
    check(flow["evidence"] == "proven",
          "the field-frame random encounter requester is statically connected")
    check(flow["field_update_call"] == "0x8013295c" and
          flow["validator"] == "0x8012cc40",
          "the field update enters area_transition_validator")
    check(flow["rate_roll"] == "0x8012ccd0" and
          br.mword(0x801387AC) == 0x3403007F and
          br.mword(0x801387B0) == 0x0043001A and
          br.mword(0x801387D8) == 0x00001012 and
          br.mword(0x8012CCDC) == 0x9063159D and
          br.mword(0x8012CCE0) == 0x304200FF and
          br.mword(0x8012CCE4) == 0x0043102B,
          "the validator compares the low byte of rand()/127 against the per-area rate")
    check(flow["picker_call"] == "0x8012cd08" and
          flow["picker"] == "0x80126228" and
          br.mword(0x80126250) == 0x0C051F8E,
          "the selector helper chooses a candidate using BIOS rand")
    check(flow["selector_store"] == "0x801263e8" and
          br.mword(0x801263E8) == 0xAC731BC0,
          "the selected candidate index is stored at gs+0x1BC0")
    check(flow["queued_flag_store"] == "0x8012cd24" and
          br.mword(0x8012CD24) == 0xA0620037,
          "successful selection sets area_state+0x37 bit 0")
    check(flow["mode_3_store"] == "0x80131f18" and
          flow["encounter_pointer_store"] == "0x80131f30" and
          br.mword(0x80131F18) == 0xAC821BBC and
          br.mword(0x80131F30) == 0xAC831BB4,
          "the field transition queues mode 3 and its encounter pointer")
    check(flow["battle_consumer"] == "0x800de020" and
          br.mword(0x800DE020) == 0x8C421BC0,
          "battle participant setup consumes gs+0x1BC0")
    check(any(row["site"] == br.ENCOUNTER_SELECTOR_STORE
              for row in flow["selector_writer_candidates"]),
          "the selector store appears in the raw immediate writer census")

    print(f"\n{PASS} assertions passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())

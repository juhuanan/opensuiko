#!/usr/bin/env python3
"""Pin historical framing and separate area-table instruction measurements.

The positive .8 SPU ADPCM consumer proof is test_dot8_audio.py. These CPU
measurements do not establish the absence of a hardware audio decoder.
"""
from __future__ import annotations

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "kit", "tools"))

import q_dot8  # noqa: E402


def main() -> int:
    r = q_dot8.report()
    fails: list[str] = []

    def need(cond, msg):
        if not cond:
            fails.append(msg)

    # ---- framing: 16, not 24 -------------------------------------------
    need(r["files"]["count"] == 67,
         f"expected 67 `.8` files, found {r['files']['count']}")
    need(r["files"]["all_form1_data"], "a `.8` file is not Form 1 Data")
    fr = r["framing"]
    need(fr["stride16"]["fraction"] > 0.9999,
         f"16-byte framing marks {fr['stride16']['fraction']:.4%}, expected ~100%")
    need(fr["non_marker_records"] == 134,
         f"expected 134 non-0x02 records (67 x 0x03 terminator + 67 x 0x06 "
         f"marker), found {fr['non_marker_records']}")
    need(fr["stride24"]["fraction"] < 0.55,
         f"24-byte framing marks {fr['stride24']['fraction']:.4%}; the framing is "
         "not discriminated")

    # ---- Q1: the only transformer takes 24-byte input, 16-byte output ---
    q1 = {e["name"]: e for e in r["q1_transformer_8013751C"]}
    need(q1["malloc_size"]["word"] == 0x00042100,
         "0x80137540 is not `sll $a0,$a0,4` (the count*16 allocation)")
    need(q1["count_load"]["word"] == 0x9044045C,
         "0x80137538 is not `lbu $a0,0x45c($v0)` (the record count)")
    need(q1["in_stride_a"]["word"] == 0x26310018,
         f"0x80137688 input stride is {q1['in_stride_a']['word']:#010x}, not 0x18")
    need(q1["in_stride_b"]["word"] == 0x26730018,
         f"0x80137694 input stride is {q1['in_stride_b']['word']:#010x}, not 0x18")
    need(q1["out_stride_a"]["word"] == 0x26100010,
         f"0x80137674 output stride is {q1['out_stride_a']['word']:#010x}, not 0x10")
    # the count the allocation is sized from is a TILE count, not a record count
    need(q1["count_is_tile_increment"]["word"] == 0xA062045C,
         "0x8012EEB8 is not the tile scan incrementing [0x8017BE20]+0x45C")
    need(q1["count_is_install_clear"]["word"] == 0xA060045C,
         "0x801314E8 is not the scene install clearing [0x8017BE20]+0x45C")
    need(q1["count_is_teardown_clear"]["word"] == 0xA040045C,
         "0x801378C8 is not the drawlist-A teardown clearing the count")
    # the 16-byte entry selector at scene install
    q3 = {e["va"]: e for e in r["q3_e0e1_consumer"]}
    need(q3[0x80132080]["word"] == 0x00021100,
         "0x80132080 is not `sll $v0,$v0,4` (the 16-byte entry stride)")

    # ---- Q2: no nibble sign-extend, no k*17 table, reader unreachable ----
    q2 = r["q2_nibble"]
    need(q2["sll28_sra28_pairs"] == 0,
         "a `sll 28`/`sra 28` nibble sign-extend exists in MAIN.EXE")
    need(q2["k17_tables"] == [],
         f"a k*17 -> k byte table exists at {q2['k17_tables']}")
    need(q2["window_reader"]["branch_or_call_targets"] == 0,
         "the `.8` window reader 0x800C8A80 has a branch or call target")
    need(q2["window_reader"]["prev_insn"]["word"] == 0x03E00008,
         "0x800C8A78 is not `jr $ra`; the reader is not fall-through-free")
    need(q2["window_reader"]["listing"][0]["word"] == 0x3C028018,
         "0x800C8A80 is not `lui $v0,0x8018` (the reader prologue)")
    need(q2["window_reader"]["listing"][1]["word"] == 0x90429BF3,
         "0x800C8A84 is not `lbu $v0,-0x640d($v0)` (the resource-index guard)")

    # ---- Q3: bytes 14-15 have a consumer --------------------------------
    need(q3[0x80131588]["word"] == 0x9042000E,
         "0x80131588 is not `lbu $v0,0xe(p)` -- the record byte-14 read")
    need(q3[0x80131590]["word"] == 0x00021080,
         "0x80131590 is not `sll $v0,$v0,2` (the word-table index scale)")
    need(q3[0x80131598]["word"] == 0x8C421B9C,
         "0x80131598 is not `lw $v0,0x1b9c(...)`")
    need(q3[0x801315A0]["word"] == 0xAC620004,
         "0x801315A0 does not store the fetched word to area struct +0x04")
    need(q3[0x801315AC]["word"] == 0x24630004,
         "0x801315AC is not `addiu $v1,$v1,4` (the area-struct stride)")
    need(q3[0x800C9654]["word"] == 0xAC851B9C,
         "0x800C9654 does not fill the 0x1B9C word table")
    need(q3[0x800C9658]["word"] == 0x24A55000,
         "0x800C9658 does not advance the table fill by 0x5000")
    need(q3[0x800C9660]["word"] == 0x2A420006,
         "0x800C9660 is not `slti $v0,$s2,0x6` (six table entts)")

    # ---- the misattributed consumer: PAN_TEO reads a different record ----
    pn = {e["va"]: e for e in r["panteo"]["sites"]}
    need(pn[0x80084FF0]["word"] == 0x94820008,
         "0x80084FF0 is not `lhu $v0,0x8($a0)` (PAN_TEO X read)")
    need(pn[0x80084F88]["word"] == 0x26310010,
         "0x80084F88 is not a 16-byte stride; PAN_TEO's record source moved")

    if fails:
        print("FAIL: q_dot8 invariant broken:")
        for f in fails:
            print(f"  - {f}")
        return 1
    print("PASS:67 .8 SPU-block framing measurements; separate area24→16 "
          "transformer and party byte14 index instructions; historical "
          "CPU nibble scans reproduced (not a missing-decoder proof)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

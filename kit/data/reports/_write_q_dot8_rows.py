#!/usr/bin/env python3
"""One-off writer for kit/work/extract_q_dot8.jsonl (the q_dot8 registry rows)."""
import json, os

ROWS = [
 dict(stage="Q_DOT8_FRAMING", **{"class": "8area"},
  claim="Every `.8` file is a flat array of 16-byte records: byte 0 is the primitive tag (low byte = the PS1 GPU primitive command), byte 1 is 0x02 on every record but two, bytes 2-15 are the payload. Measured over all 67 files (18,026,496 records): 18,026,362 carry byte 1 = 0x02; the 134 others are exactly one 0x03 terminator (the last record of each file) and one 0x06 block marker (on a 16 KiB boundary) per file. The 24-byte reading of the same bytes marks only 6,112,858 of 12,017,641 records (50.9%), so the framing is discriminated by consumption, not by value range.",
  addr="", evidence="proven",
  source="kit/tools/q_dot8.py --json; kit/tests/test_q_dot8.py",
  superseded_by="", note="Counts recomputed from the disc in this campaign. The 0x02 byte-1 stamp is also written by the loader at 0x800C8184/0x800C8198; the 0x06 marker is disc data."),
 dict(stage="Q_DOT8_Q1", **{"class": "8area"},
  claim="MAIN.EXE's only record transformer in this family, 0x8013751C, allocates count*16 bytes (lbu count at [0x8017BE20]+0x45C, `sll $a0,$a0,4` at 0x80137540, malloc 0x800C2D30) and walks its INPUT at a 24-byte stride (`addiu $s1,$s1,0x18` at 0x80137688, `addiu $s3,$s3,0x18` at 0x80137694) while writing 16 bytes per iteration (`addiu $s0,$s0,0x10` at 0x80137674, `addiu $s2,$s2,0x10` at 0x80137668). Allocation size and input stride together exclude it as the `.8` 16-byte-record parser. Its input table has a 0x18 stride at the consumer 0x8012ED84 (`addiu $s0,$s0,0x18` at 0x8012EEC8).",
  addr="0x8013751C", evidence="proven",
  source="kit/tools/q_dot8.py --json; kit/tests/test_q_dot8.py",
  superseded_by="", note="Dump-site words recorded by the tool. Resolves the brief's '16-byte input buffer' reading: the input stride is 24; the 16 belongs to the output buffer and its allocation."),
 dict(stage="Q_DOT8_Q1", **{"class": "8area"},
  claim="The count field [0x8017BE20]+0x45C that sizes the 0x8013751C allocation is a TILE-entry count, not a record count: it has exactly three writers, and they are the tile-entry scan incrementing it when an entry's +0x04 word passes the 0x60 mask (0x8012EEB8), the area-scene install clearing it (0x801314E8), and the drawlist-A teardown clearing it (0x801378C8). No other site in MAIN.EXE writes the field.",
  addr="0x8012EEB8", evidence="proven",
  source="kit/tools/q_dot8.py --json; kit/tests/test_q_dot8.py",
  superseded_by="", note="Second, independent relation excluding 0x8013751C as the `.8` parser: the allocation's size operand is owned by the tile system."),
 dict(stage="Q_DOT8_Q1", **{"class": "8area"},
  claim="[0x8017BF98] is set once, at 0x80132098, to word0 of the 16-byte section entry `p = area->0x08 + game_state[1]*16`; the same routine stores `p` itself to [0x8017BFC0] (`sll $v0,$v0,4` at 0x80132080, `lw $v1,0x0($v0)` at 0x80132088). The entry selector is the game_state[1] byte read at 0x80132078.",
  addr="0x80132098", evidence="proven",
  source="kit/tools/q_dot8.py --json; kit/tests/test_q_dot8.py",
  superseded_by="", note="The 16-byte entry stride here and the 24-byte consumer are two different tables; the corpus conflated them under one address."),
 dict(stage="Q_DOT8_Q1", **{"class": "8area"},
  claim="No raw-`.8` 16-byte-record parser exists in MAIN.EXE. The reader of the `.8` load window, 0x800C8A80, is the only function that loads the window pointer [0x80179DD0] and consumes a record byte; it treats the stream as 4-bit fields, reading one nibble per call at a 4-byte stride. It is unreachable: 0 jal, 0 j, 0 branch targets, 0 literal pointers across the image, and the instruction at 0x800C8A78 immediately before it is `jr $ra`, so nothing falls through into it.",
  addr="0x800C8A80", evidence="proven",
  source="kit/tools/q_dot8.py --json; kit/tests/test_q_dot8.py",
  superseded_by="", note="Independent re-derivation of the 2026-10-05 unreachability result, which was correct; only its motivation (the `.8`-is-XA premise) was wrong."),
 dict(stage="Q_DOT8_Q2", **{"class": "8area"},
  claim="MAIN.EXE contains no nibble sign-extend (`sll r,r,28` followed by `sra r,r,28`) and no 256-byte `k*17 -> k` table; both are absent by whole-image scan. The only 4-bit consumer in the engine is the unreachable scalar window reader 0x800C8A80, which folds nibbles >= 9 with 16-x and scales by the per-resource word at 0x80179C0C before `srl $v0,$v0,3`. The `.8` payload's four-bit fields therefore have no decoder in this build: the 16-byte records enter the load window and are not read back.",
  addr="0x800C8A80", evidence="proven",
  source="kit/tools/q_dot8.py --json; kit/tests/test_q_dot8.py",
  superseded_by="", note="The seven prior scans' negative is reproduced inside the same tool that answers Q1 and Q3, so the negative and the positives share one instrument."),
 dict(stage="Q_DOT8_Q3", **{"class": "8area"},
  claim="Record BYTE 14 is consumed as an index: at area-scene install, 0x80131588 does `lbu $v0,0xe(p)` (a byte load, not a halfword) on each of six consecutive 16-byte records (p = [0x8017C164] + i), scales by 4 (`sll $v0,$v0,2` at 0x80131590), loads a word from `[0x8017DB24]+0x1B9C+index*4` (`lw $v0,0x1b9c($v0)` at 0x80131598), and stores it into the area struct at +0x04, advancing 4 bytes per iteration (0x801315A0/0x801315AC, bound `slti $v0,$a0,0x6`). Byte 15 is not read by this path.",
  addr="0x80131588", evidence="proven",
  source="kit/tools/q_dot8.py --json; kit/tests/test_q_dot8.py",
  superseded_by="", note="The fetched words are u32 pointer values from the game-state table (the table the loader docs call the file-slot table at 0x801B9B9C), so byte 14 is a load-time slot selector, not an OT sort key and not a packed texpage/CLUT. The scale of four over a 1024-byte table bounds the index to 256 slots."),
 dict(stage="Q_DOT8_Q3", **{"class": "8area"},
  claim="The word table indexed by record byte 14 at [0x8017DB24]+0x1B9C is filled at start-up by 0x800C9654: six iterations, each `sw $a1,0x1b9c($a0)` then `addiu $a1,$a1,0x5000`, `addiu $a0,$a0,4`, bound `slti $v0,$s2,0x6`.",
  addr="0x800C9654", evidence="proven",
  source="kit/tools/q_dot8.py --json; kit/tests/test_q_dot8.py",
  superseded_by="", note="Entry 0 is 0x801BA000 and each step is 0x5000, so every byte-14 index resolves to a live buffer address; the table is a per-load pointer block, not content."),
 dict(stage="Q_DOT8_Q3", **{"class": "8area"},
  claim="The PAN_TEO renderer 0x80084F00 walks its records at a 16-byte stride (`addiu $s1,$s1,0x10` at 0x80084F88) and reads X at +0x8, Y at +0xA and a signed halfword at +0xC (0x80084FF0, 0x80085004, 0x800850A8). Its records have a different field layout from the `.8` record (whose bytes 0-1 are the tag and whose payload is 4-bit fields), so it is not the consumer that fixes `.8` parsing.",
  addr="0x80084F00", evidence="proven",
  source="kit/tools/q_dot8.py --json; kit/tests/test_q_dot8.py",
  superseded_by="", note="The brief's premise that this renderer consumes `.8` records is what made Q1 look like a missing decoder; the two record formats are distinct."),
]

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
out = os.path.join(ROOT, "kit", "work", "extract_q_dot8.jsonl")
with open(out, "w") as fh:
    for r in ROWS:
        fh.write(json.dumps(r, ensure_ascii=False) + "\n")
print("wrote", out, len(ROWS), "rows")

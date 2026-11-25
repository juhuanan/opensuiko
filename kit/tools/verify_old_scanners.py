#!/usr/bin/env python3
"""verify_old_scanners.py -- reproduce the OLD scanner false positives.

Counterexample evidence for `kit/docs/scanner_pointer_invalidation.md`.
It extracts `gs_scan.py` and `scan_structptr.py` **as of a pinned pre-fix
revision** into a temp directory, feeds each a synthetic instruction window by
patching its own code source (`gs_scan._load`, `scan_structptr.word_at`/`size`),
and prints the records it emits. The point is that the old code emits a
**confident false positive**, which is what the fixed scanners must not do and
what the counterexample tests pin.

The revision is pinned rather than read from HEAD, because once the fix is
committed HEAD *is* the fixed code and this harness would silently start testing
the wrong thing.

Usage:
    python3 kit/tools/verify_old_scanners.py [REV]

REV defaults to PRE_FIX_REV below. Any revision whose `kit/tools/gs_scan.py` is
still pre-fix will do; the harness prints the SHA it resolved so a report can
state exactly what it measured. Exit 0 means both false positives reproduced
(that is the expected, documented outcome), 1 means they did not.
"""
import os
import subprocess
import sys
import tempfile

TOOLS = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(TOOLS))

# The last revision before the pointer-invalidation fix landed. Pinned on
# purpose: see the module docstring.
PRE_FIX_REV = "398c738"

SCANNERS = ("gs_scan.py", "scan_structptr.py")

GP, S0, V0, T0 = 28, 16, 2, 8


def enc_r(op, rs, rt, imm):
    return ((op << 26) | (rs << 21) | (rt << 16) | (imm & 0xFFFF)) & 0xFFFFFFFF


def lui(rt, imm):       return enc_r(0x0F, 0, rt, imm)
def lw(rt, rs, off):    return enc_r(0x23, rs, rt, off)


def resolve(rev):
    return subprocess.run(["git", "rev-parse", rev], cwd=REPO, capture_output=True,
                          text=True, check=True).stdout.strip()


def stage_old_tools(rev):
    """Temp tools dir: the pinned scanners, symlinks to everything else current."""
    d = tempfile.mkdtemp(prefix="oldscan_")
    for name in os.listdir(TOOLS):
        if name.endswith(".py") and name not in SCANNERS:
            os.symlink(os.path.join(TOOLS, name), os.path.join(d, name))
    for name in SCANNERS:
        src = subprocess.run(["git", "show", "%s:kit/tools/%s" % (rev, name)],
                             cwd=REPO, capture_output=True, text=True,
                             check=True).stdout
        with open(os.path.join(d, name), "w") as f:
            f.write(src)
    return d


def run_old_gs_scan(tools_dir):
    """P2 pattern B, then the clobber the old code fails to invalidate.

        lw   s0,-0x24DC($gp)   seed: gs = {s0: offset 0}
        lw   s0,0(s0)          records gs+0x0, then `continue`s -- the defect
        nop                    keeps the next load out of the delay slot
        lw   v0,4(s0)          old code still tracks s0 -> FALSE gs+0x4
    """
    at = 10
    words = [0] * 700                     # the P2 sweep needs > 610 words
    words[at + 0] = lw(S0, GP, 0xDB24)    # simm(0xDB24) == -0x24DC
    words[at + 1] = lw(S0, S0, 0)
    words[at + 2] = 0
    words[at + 3] = lw(V0, S0, 4)

    sys.path.insert(0, tools_dir)
    sys.modules.pop("gs_scan", None)
    import gs_scan as old

    old._STATE.clear()
    old._STATE.update(body=b"\x00" * (4 * len(words)), W=words, funcs=[], faddrs=[])
    old._load = lambda: old._STATE        # bypass the disc read
    return old.scan()


def run_old_structptr(tools_dir):
    """Struct-pointer load, then a clobber of the tracked register.

        lui t0,0x800B         base_is_800B0000 -> true
        lw  s0,0xFC(t0)       struct pointer -> tracked={s0}
        lui s0,0x800A         CLOBBER of the tracked register (old code ignores it)
        lw  v0,0x340(s0)      old code still tracks s0 -> FALSE struct+0x340
    """
    code = [lui(T0, 0x800B), lw(S0, T0, 0x00FC), lui(S0, 0x800A), lw(V0, S0, 0x0340)]

    sys.path.insert(0, tools_dir)
    sys.modules.pop("scan_structptr", None)
    import scan_structptr as old

    mem = {old.BASE + 4 * i: w for i, w in enumerate(code)}
    old.word_at = lambda va: mem.get(va)
    old.size = lambda: 4 * len(code)

    out = []
    old.print = lambda *a, **k: out.append(" ".join(str(x) for x in a))
    old.scan()
    return out


def main(argv):
    rev = resolve(argv[0] if argv else PRE_FIX_REV)
    tools = stage_old_tools(rev)
    print("pre-fix revision: %s" % rev)
    print("staged old scanners in: %s\n" % tools)

    print("=== OLD gs_scan on the synthetic window ===")
    recs = run_old_gs_scan(tools)
    for r in recs:
        print("   ", r)
    gs_false = [r for r in recs if str(r[-1]) == "gs+0x4"]
    print("   -> %d record(s); FALSE 'gs+0x4' reproduced: %s"
          % (len(recs), bool(gs_false)))

    print("\n=== OLD scan_structptr on the synthetic window ===")
    lines = run_old_structptr(tools)
    for ln in lines:
        print("   ", ln)
    sp_false = [ln for ln in lines if "struct+0x340" in ln]
    print("   -> %d record(s); FALSE 'struct+0x340' reproduced: %s"
          % (len(lines), bool(sp_false)))

    ok = bool(gs_false) and bool(sp_false)
    print("\n%s" % ("Both documented false positives reproduced on the pre-fix code."
                    if ok else
                    "EXPECTED FALSE POSITIVES NOT REPRODUCED -- investigate."))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

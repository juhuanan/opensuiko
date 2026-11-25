#!/usr/bin/env python3
"""The `04_PLAY` walk-cycle anchor -- derived from the art, with a universal statistic.

`play_sprite_geometry.py` derives each piece's **source rectangle**.  It
deliberately stops there: the piece's **destination** is not in the e-record, and
the four candidate consumers that were disassembled all turned out to be other
things (`play_sprite_geometry.md` section 6).

This tool answers the destination question a different way.  Each S2 piece is a
**complete character pose**, tightly cropped -- and the crop is not arbitrary:
the artist padded each pose so that a single fixed anchor lands correctly.  So
the anchor is a property of the atlas, and it is measurable from the pixels.

**The measurement (all 78 files, 78/78 S2 sections, 936 pieces):**

| statistic | result |
|---|---|
| pieces per S2 section | 12 or 13 |
| foot inset (`h-1 - content_bottom`) spread | **<= 2 px in 78/78** |
| median foot inset | **== 1 in 78/78** |
| centre-x inset spread | <= 5 px in 72/78 |

So **the S2 cycle is bottom-anchored**: draw each piece at
`(cx - w//2, cy - h + FOOT_INSET)` with `FOOT_INSET = 1`, and the feet land on
one line and the character does not jitter.  A contact strip for SHU is what
first showed this; the statistic is what makes it a derivation rather than a
look.

**What this is and is not.**  It is derived from the disc's pixels with a
statistic that holds universally and has an obvious null (independent random
crops of the poses give a spread of tens of pixels, not <= 2).  It is **not**
instruction-level proof of the engine's draw call -- the destination code path
is still untraced.  The two agree on this case, and the render is the practical
check; per `AGENTS.md` the user is the final gate for images.

**S1 sections are NOT covered and must not be anchored this way.**  S1 mixes
poses with effects, hit-stars and projectiles; its foot-inset spread reaches
48 px (CRW S1).  Anchoring an S1 section by this rule is the "noise as art"
failure mode.  `--stats` prints the per-section spread so a caller can tell which
kind a section is before trusting the anchor.

Usage:
    python3 play_cycle.py --stats
    python3 play_cycle.py --strip SHU.BIN            # one anchored cycle
    python3 play_cycle.py --all --out kit/work/play_cycles
"""
from __future__ import annotations

import argparse
import collections
import os
import statistics
import sys

_TOOLS = os.path.dirname(os.path.abspath(__file__))
_KIT = os.path.dirname(_TOOLS)
sys.path.insert(0, _TOOLS)
import play_sprite_geometry as G  # noqa: E402

#: the measured anchor: the rect's bottom row sits this far below the feet
FOOT_INSET = 1
CYCLE_SECTION = "S2"


def pal_of(sec):
    return [G.rgb555(w) for w in (sec.get("palette") or [])]


def _atlas_index(rect) -> int:
    """Which c-blob a piece samples.  S1 has TWO atlas pages and roughly half of
    its pieces select the second one, so reading `blobs[0]` for every piece cuts
    real pieces out of the wrong page and measures garbage."""
    a, b = rect["atlas"]
    return a + (1 if b == 2 else 0)


def _piece_pixels(name, d, pr, sec_name):
    """`(mask, rect)` per UNIQUE piece, cut from the atlas THAT PIECE selects.

    Two exclusions, both derived rather than assumed:

    * **`+0x0F == 2` records are flagged variants, not extra poses.**  In every
      S2 section the records from index 9 on set `+0x0F` to 2, and 233 of the 235
      such records are byte-identical to an earlier unflagged record apart from
      that byte (same tile, rect, tpage and CLUT).  So `+0x0F` is a **draw
      attribute**; counting those records as poses would double-count the walk.
      The two exceptions (KNA, SHU) differ in `tpage` as well.
    * **S1 has two atlas pages** and about half its pieces select the second, so
      the page must come from the piece (`sel_a`), never from `blobs[0]`.
    """
    import numpy as np

    s = next(x for x in pr["sections"] if x["name"] == sec_name)
    pal = [G.rgb555(w) for w in (s.get("palette") or [])]
    out = []
    for raw in s["e_raw"]:
        if raw[0x0F] == 2:
            continue
        r = G.derive_rect(raw)
        bi = _atlas_index(r)
        if bi >= len(s["blobs"]):
            continue
        a = np.array(G.cut(s["blobs"][bi], r, pal))
        out.append(((a[..., 0] != 0), r))
    return out


def _shift(quadrant, x, y):
    """Round-half-to-even, so a piece of even width is not biased one pixel."""
    return int((quadrant + x) // 2) if False else round((x - y) / 2)


def measure(name: str, sec_name: str, d: bytes, pr: dict) -> dict:
    """Content insets for one section: the evidence for the anchor."""
    import numpy as np

    foot, cen, top = [], [], []
    for mask, p in _piece_pixels(name, d, pr, sec_name):
        a = mask
        ys, xs = np.nonzero(a != 0)
        if len(ys) == 0:
            continue
        h, w = a.shape
        foot.append(int(h - 1 - ys.max()))
        top.append(int(ys.min()))
        cen.append(int(xs.min() + xs.max() + 1 - w))
    if not foot:
        return {}
    return {
        "file": name, "section": sec_name, "pieces": len(foot),
        "foot_min": min(foot), "foot_max": max(foot),
        "foot_median": statistics.median(foot),
        "foot_spread": max(foot) - min(foot),
        "cen_spread": max(cen) - min(cen),
        "anchored": (max(foot) - min(foot)) <= 2,
    }


def _masks(name, d, pr, sec_name):
    """Per-piece opacity masks, for the sequence statistic."""
    import numpy as np

    return [mask.astype("uint8") for mask, _r in _piece_pixels(name, d, pr, sec_name)]


def _iou(a, b):
    """Overlap of two masks aligned bottom-centre."""
    import numpy as np

    H, W = max(a.shape[0], b.shape[0]), max(a.shape[1], b.shape[1])

    def pad(m):
        o = np.zeros((H, W), "uint8")
        o[H - m.shape[0]:, (W - m.shape[1]) // 2:(W - m.shape[1]) // 2 + m.shape[1]] = m
        return o

    A, B = pad(a), pad(b)
    u = int((A | B).sum())
    return float((A & B).sum()) / u if u else 1.0


def sequence_stats() -> dict:
    """Is a section an ORDERED sequence or an unordered SET?

    An animation plays in order, so neighbouring poses are much more alike than
    the two endpoints.  A set of distinct one-shot poses (idle, attack, damaged,
    dying, victory) in no arc order has endpoints no different from neighbours.
    """
    import statistics

    out = {"S1": [], "S2": []}
    for e in G.play_files():
        name, d = G.load(e["path"])
        pr = G.probe(name, d)
        for sec in ("S1", "S2"):
            m = _masks(name, d, pr, sec)
            if len(m) < 4:
                continue
            step = statistics.mean(_iou(m[i], m[i + 1]) for i in range(len(m) - 1))
            loop = _iou(m[-1], m[0])
            out[sec].append({"file": name, "n": len(m), "step": step, "loop": loop,
                             "ordered": step - loop})
    return out


def stats() -> dict:
    """The anchor statistic over every file's S2 section, and S1 as contrast."""
    s2, s1 = [], []
    for e in G.play_files():
        name, d = G.load(e["path"])
        pr = G.probe(name, d)
        for sec in (CYCLE_SECTION, "S1"):
            try:
                m = measure(name, sec, d, pr)
            except StopIteration:
                continue
            if m:
                (s2 if sec == CYCLE_SECTION else s1).append(m)
    return {"s2": s2, "s1": s1}


def strip(name: str, d: bytes, pr: dict) -> "list":
    """The anchored cycle: each piece pasted at a common bottom-centre."""
    from PIL import Image
    import numpy as np

    got = _piece_pixels(name, d, pr, CYCLE_SECTION)
    ps = [r for _m, r in got]
    cell_w = max(p["w"] for p in ps) + 2
    cell_h = max(p["h"] for p in ps) + 2
    out = []
    for (mask, p) in got:
        bi = _atlas_index(p)
        sec = next(x for x in pr["sections"] if x["name"] == CYCLE_SECTION)
        a = np.array(G.cut(sec["blobs"][bi], p, pal_of(sec)), dtype=np.uint8)
        rgb = a[..., :3]
        alpha = (a[..., 3] > 0)
        tile = np.zeros((cell_h, cell_w, 3), dtype=np.uint8)
        ox = (cell_w - p["w"]) // 2
        oy = cell_h - p["h"]
        tile[oy:oy + p["h"], ox:ox + p["w"]][alpha] = rgb[alpha]
        out.append(tile)
    return out


def sheet(frames: "list", scale: int = 3):
    """All frames of a cycle side by side, on a floor line."""
    from PIL import Image
    import numpy as np

    h, w = frames[0].shape[:2]
    gap = 4
    canvas = np.zeros((h + 8, len(frames) * (w + gap), 3), dtype=np.uint8)
    canvas[:] = (18, 18, 34)
    for k, f in enumerate(frames):
        x = k * (w + gap) + gap // 2
        canvas[2:2 + h, x:x + w] = f
    floor = h + 1
    canvas[floor:floor + 1, :] = (70, 70, 110)
    im = Image.fromarray(canvas, "RGB")
    return im.resize((im.width * scale, im.height * scale), Image.NEAREST)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--stats", action="store_true")
    ap.add_argument("--strip", help="a file name, e.g. SHU.BIN")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--out", help="output directory for --all/--strip")
    args = ap.parse_args(argv)

    if args.strip:
        name, d = G.load("DATA/04_PLAY/" + args.strip)
        pr = G.probe(name, d)
        m = measure(name, CYCLE_SECTION, d, pr)
        print(f"{name}: {m['pieces']} frames, foot inset {m['foot_min']}..{m['foot_max']} "
              f"(median {m['foot_median']}), anchored={m['anchored']}")
        if args.out:
            os.makedirs(args.out, exist_ok=True)
            path = os.path.join(args.out, os.path.basename(name).replace(".BIN", "") + "_cycle.png")
            sheet(strip(name, d, pr)).save(path)
            print("wrote", path)
        return 0

    if args.all:
        out = args.out or os.path.join(_KIT, "work", "play_cycles")
        os.makedirs(out, exist_ok=True)
        n = 0
        for e in G.play_files():
            name, d = G.load(e["path"])
            pr = G.probe(name, d)
            m = measure(name, CYCLE_SECTION, d, pr)
            if not m or not m["anchored"]:
                print(f"  SKIP {name}: not anchored (foot spread {m.get('foot_spread')})")
                continue
            sheet(strip(name, d, pr)).save(
                os.path.join(out, os.path.basename(name).replace(".BIN", "") + "_cycle.png"))
            n += 1
        print(f"wrote {n} anchored cycles to {out}")
        return 0

    if args.stats:
        st = stats()
        s2, s1 = st["s2"], st["s1"]
        print(f"S2 cycles: {len(s2)} sections, {sum(m['pieces'] for m in s2)} pieces")
        print(f"  foot spread <=2 px : {sum(1 for m in s2 if m['foot_spread'] <= 2)}/{len(s2)}")
        print(f"  median foot == {FOOT_INSET} : {sum(1 for m in s2 if m['foot_median'] == FOOT_INSET)}/{len(s2)}")
        print(f"  centre-x spread <=5: {sum(1 for m in s2 if m['cen_spread'] <= 5)}/{len(s2)}")
        print(f"  worst foot spread  : {max(m['foot_spread'] for m in s2)}")
        print(f"\nS1 contrast: {len(s1)} sections")
        print(f"  foot spread <=2 px : {sum(1 for m in s1 if m['foot_spread'] <= 2)}/{len(s1)}")
        print(f"  worst foot spread  : {max(m['foot_spread'] for m in s1)}"
              f"  ({max(s1, key=lambda m: m['foot_spread'])['file']})")
        print("  -> S1 must NOT be anchored this way.")
        seq = sequence_stats()
        for sec in ("S2", "S1"):
            v = seq[sec]
            step = statistics.mean(x["step"] for x in v)
            loop = statistics.mean(x["loop"] for x in v)
            print(f"\n{sec} sequence: n={len(v)}  adjacent={step:.3f}  endpoints={loop:.3f}"
                  f"  ordered_by={step - loop:+.3f}")
        print("  -> S2 is an ORDERED sequence (a cycle); S1 is a SET of distinct")
        print("     one-shot poses, consistent with the battle animations.")
        return 0

    print(__doc__.split("Usage:")[0])
    return 0


if __name__ == "__main__":
    sys.exit(main())

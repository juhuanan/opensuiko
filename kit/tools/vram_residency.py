#!/usr/bin/env python3
"""Which disc atlas sits in which VRAM slot -- byte-exact, against ALL atlases.

WHY
---
`docs/battle_vram_residency.md` matched the **234 distinct atlases that
live inside 04_PLAY-format containers** against the existing capture
`kit/work/vram_raw.bin` and found 14 slots byte-exact. But the disc-wide pool
(`atlas_pool.py`, `docs/atlas_pool.md`) holds **2,006 distinct**
16,384-byte atlases, of which only 339 streams (234 distinct) are inside a
container. The other ~1,767 had never been matched against VRAM. This tool
matches all of them and reports the complete residency map plus what is *not*
explained.

THE READING (and the trap)
--------------------------
A 128x128 8-bit index plane occupies 64 consecutive VRAM words per row: the
**low byte of a word is the left pixel of the pair, the high byte the right
one**. So the plane for the slot whose top-left word is `(x, y)` is
`vram_raw[y:y+128, x:x+64].tobytes()` -- the byte order *interleaves* lo/hi
within each word, it is NOT "low bytes = left half".

Getting this wrong is silent: taking the low bytes of the whole row as the left
half produces a plane that matches nothing (measured: 0 matches), while the
interleaved reading reproduces the 14 known container slots exactly. That
reproduction is a test (`test_vram_residency.py`).

SLOT GEOMETRY
-------------
* x is enumerated at every multiple of **32 words = 64 pixels**. That is not
  arbitrary: the PSX texpage attribute encodes its X base in units of 64 pixels,
  so 32 words is exactly the set of legal texture-page origins.
* y is enumerated at **every row** from 0 (the texpage has no Y base; U/V carry
  the vertical offset), so a sheet can sit at any row.
* A slot is 64 words wide, 128 rows tall.

PROVENANCE
----------
Disc bytes only, through `disc.py` + `lzss.decode_strict` (canonical decoder)
or `overlay_sprites.py` (the container parser). The capture is used strictly as
a *measuring instrument*; nothing here is promoted into `kit/work/assets_zig`,
and no oracle pixel is ever described as disc-derived.

Usage:
    vram_residency.py                      # full report on stdout
    vram_residency.py --json OUT           # ... and dump the report as JSON
    vram_residency.py --x-step 64          # coarser slot grid
    vram_residency.py --captures           # only list candidate VRAM captures
Exit: 0 clean, 1 on a structural problem (missing/short capture, bad manifest).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import disc                                    # noqa: E402
import lzss                                    # noqa: E402
import overlay_sprites as ov                   # noqa: E402

try:
    import numpy as np
except ImportError:                            # pragma: no cover
    sys.exit("numpy required (kit/requirements.txt)")

_TOOLS = os.path.dirname(os.path.abspath(__file__))
_KIT = os.path.dirname(_TOOLS)

VRAM_W, VRAM_H = 1024, 512
VRAM_BYTES = VRAM_W * VRAM_H * 2               # 1,048,576
ATLAS_PX = ATLAS_BYTES = 128 * 128             # 16,384
SLOT_WORDS = 64                                # 128 px per row
SLOT_ROWS = 128
SLOT_PX = 128                                  # a slot is 128x128 pixels
X_STEP_WORDS = 32                              # PSX texpage X base unit (64 px)

DEFAULT_VRAM = os.path.join(_KIT, "work", "cache", "oracles", "vram_raw.bin")
DEFAULT_POOL = os.path.join(_KIT, "work", "atlas_pool", "manifest.json")
DEFAULT_OVERLAY_MANIFEST = os.path.join(_KIT, "work", "overlay_sprites",
                                        "manifest.json")
ISO_JSON = os.path.join(_KIT, "extracted", "iso_files.json")

# The pool's own sprite/content heuristic, reused so the two tools cannot
# disagree about what "sprite-like" means.
SPRITE_ZERO_FRAC = 0.40
TILE_ZERO_FRAC = 0.05

# What a slot must look like to count as a 32-colour index plane: every byte is
# a CLUT index in 0..31. (Necessary, not sufficient: a dark 16-bit direct-colour
# word can also have both bytes <= 31 -- see the report's honesty section.)
INDEX32_MAX = 31


# --------------------------------------------------------------------------
# VRAM capture
# --------------------------------------------------------------------------

def load_vram(path=None):
    """The capture as a (512, 1024) uint16 array. Loud about a wrong size."""
    path = path or DEFAULT_VRAM
    if not os.path.isfile(path):
        raise FileNotFoundError("no VRAM capture at %s" % path)
    size = os.path.getsize(path)
    if size != VRAM_BYTES:
        raise ValueError("%s is %d bytes, expected %d (1024x512x2)"
                         % (path, size, VRAM_BYTES))
    with open(path, "rb") as f:
        raw = f.read()
    return np.frombuffer(raw, dtype="<u2").reshape(VRAM_H, VRAM_W)


def slot_plane(vram, x, y):
    """The 16,384 index bytes of the slot at word (x, y).

    Low byte of each word = left pixel of the pair (see module docstring).
    """
    return vram[y:y + SLOT_ROWS, x:x + SLOT_WORDS].tobytes()


def enumerate_slots(vram, x_step=X_STEP_WORDS):
    """Every legal slot: x a multiple of `x_step` words, y every row from 0."""
    if x_step <= 0:
        raise ValueError("x_step must be a positive word step")
    for x in range(0, VRAM_W - SLOT_WORDS + 1, x_step):
        for y in range(0, VRAM_H - SLOT_ROWS + 1):
            yield x, y


def plane_stats(plane):
    """Byte statistics of one slot/atlas plane. Index planes have max <= 31."""
    a = np.frombuffer(plane, dtype=np.uint8)
    zero = float((a == 0).mean())
    klass = ("sprite-like" if zero > SPRITE_ZERO_FRAC
             else "tile-like" if zero < TILE_ZERO_FRAC else "mid")
    return {"max_byte": int(a.max()),
            "bytes_over_31": int((a > 31).sum()),
            "zero_fraction": round(zero, 4),
            "distinct_indices": int(len(np.unique(a))),
            "class": klass}


# --------------------------------------------------------------------------
# the disc-wide atlas pool (re-decoded, never trusted from the manifest)
# --------------------------------------------------------------------------

def iso_index():
    with open(ISO_JSON) as f:
        return {r["path"]: r for r in json.load(f) if not r.get("dir")}


def load_pool(path=None):
    """The pool manifest as {sha1: record}."""
    path = path or DEFAULT_POOL
    with open(path) as f:
        man = json.load(f)
    out = {}
    for rec in man["atlases"]:
        out[rec["sha1"]] = rec
    return out, man


def decode_pool(pool, fetch):
    """Re-decode every pool atlas from its (file, offset) through disc + lzss.

    Returns (index, problems): `index` maps sha1 -> record with 'plane' bytes;
    `problems` lists every entry whose re-decode disagrees with the manifest
    (wrong length or wrong SHA-1). Never silently trusted.
    """
    index, problems = {}, []
    for sha1, rec in pool.items():
        try:
            data = fetch(rec["first_file"])
            off = rec["first_offset"]
            ln = int(np.frombuffer(data[off:off + 4], dtype="<u4")[0])
            plane = lzss.decode_strict(data[off + 4:off + 4 + ln])
        except Exception as exc:               # noqa: BLE001 - reported
            problems.append({"sha1": sha1, "file": rec["first_file"],
                             "offset": rec["first_offset"], "error": str(exc)})
            continue
        got = hashlib.sha1(plane).hexdigest()
        if len(plane) != ATLAS_BYTES or got != sha1:
            problems.append({"sha1": sha1, "file": rec["first_file"],
                             "offset": rec["first_offset"],
                             "error": "re-decode %d B sha1 %s" % (len(plane), got)})
            continue
        index[sha1] = dict(rec, plane=plane)
    return index, problems


def nibble_closure(plane):
    """Diagnostic: is this plane's byte set closed under its own nibbles?

    4-bit (16-colour) texture data read as 8-bit bytes produces a byte set that
    is exactly {hi<<4|lo} over a small nibble alphabet -- e.g. two-level 4bpp
    data gives {0, 1, 16, 17}. An 8-bit CLUT-indexed plane has no such
    constraint. This is reported, not asserted.
    """
    a = np.frombuffer(plane, dtype=np.uint8)
    vals = sorted({int(v) for v in np.unique(a)})
    nib = set()
    for v in vals:
        nib.add(v >> 4)
        nib.add(v & 0x0F)
    closure = {(hi << 4) | lo for hi in nib for lo in nib}
    return {"byte_values": vals[:16], "distinct_bytes": len(vals),
            "nibble_alphabet": sorted(nib),
            "is_nibble_closure": set(vals) == closure}


def is_constant(plane):
    """One distinct byte value in the whole plane -> matches any blank slot."""
    return len(set(plane)) == 1


# --------------------------------------------------------------------------
# container atlases (via overlay_sprites.py -- the independent enumeration)
# --------------------------------------------------------------------------

def container_sources(fetch, overlay_manifest=None, scan_play=True):
    """Every 04_PLAY-format container atlas on the disc, keyed by atlas SHA-1.

    Container *locations* are seeded from the recorded overlay manifest, but
    every location is re-discovered with `overlay_sprites.find_containers` and
    every atlas is re-decoded live with `overlay_sprites.decode_container`; the
    78 `DATA/04_PLAY/*.BIN` files are parsed directly. Returns
    (sources, stats) with sources[sha1] = [{file, container, section, blob}].
    """
    iso = iso_index()
    files = sorted(p for p in iso
                   if p.startswith("DATA/04_PLAY/") and p.endswith(".BIN"))
    seeded = []
    overlay_manifest = overlay_manifest or DEFAULT_OVERLAY_MANIFEST
    if overlay_manifest and os.path.isfile(overlay_manifest):
        with open(overlay_manifest) as f:
            man = json.load(f)
        seeded = sorted({c["file"] for c in man.get("containers", [])})
    files = files + [f for f in seeded if f not in files and f in iso]

    sources, stats = {}, {"files_scanned": 0, "containers": 0, "atlases": 0,
                          "errors": [], "seeded_files": len(seeded)}
    workdir = tempfile.mkdtemp(prefix="vram_residency_")
    try:
        for path in files:
            data = fetch(path)
            stats["files_scanned"] += 1
            for c in ov.find_containers(data):
                cs = c["offset"]
                label = "%s+0x%x" % (path, cs)
                stats["containers"] += 1
                try:
                    _parsed, atlases, _notes = ov.decode_container(data, cs,
                                                                   workdir)
                except Exception as exc:       # noqa: BLE001 - reported
                    stats["errors"].append({"container": label, "error": str(exc)})
                    continue
                for a in atlases:
                    stats["atlases"] += 1
                    h = hashlib.sha1(a["atlas"]).hexdigest()
                    sources.setdefault(h, []).append(
                        {"file": path, "container": label,
                         "section": a["section"], "blob": a["blob"]})
    finally:
        for name in os.listdir(workdir):
            try:
                os.unlink(os.path.join(workdir, name))
            except OSError:
                pass
        os.rmdir(workdir)
    return sources, stats


# --------------------------------------------------------------------------
# the residency scan
# --------------------------------------------------------------------------

def scan_slots(vram, index, x_step=X_STEP_WORDS):
    """Match every slot against every atlas. Returns (matches, degenerate).

    `degenerate` is a slot whose plane equals a *constant* atlas (an all-blank
    plane matches every blank slot); such a hit is byte-exact but carries no
    residency information, so it is reported separately and never counted as an
    explained slot.
    """
    matches, degenerate = [], []
    for x, y in enumerate_slots(vram, x_step):
        h = hashlib.sha1(slot_plane(vram, x, y)).hexdigest()
        rec = index.get(h)
        if rec is None:
            continue
        hit = {"x": x, "y": y, "sha1": h, "class": rec["class"],
               "first_file": rec["first_file"],
               "first_offset": rec["first_offset"],
               "occurrences": rec.get("occurrences", 1),
               "files": rec.get("files", [rec["first_file"]])}
        if is_constant(rec["plane"]):
            degenerate.append(hit)
        else:
            matches.append(hit)
    return matches, degenerate


def coverage_mask(matches):
    """Word-level mask of VRAM explained by at least one byte-exact match."""
    m = np.zeros((VRAM_H, VRAM_W), dtype=np.uint8)
    for hit in matches:
        x, y = hit["x"], hit["y"]
        m[y:y + SLOT_ROWS, x:x + SLOT_WORDS] = 1
    return m


def unexplained(vram, index, covered, x_step=X_STEP_WORDS):
    """Slots that match nothing and are not fully inside an explained region.

    Categories, all byte-exact-first:
      * `index_planes` -- reads as a 32-colour index plane (every byte <= 31)
        with sprite-like sparsity (zero fraction > 0.40) and some content;
        split by whether every non-zero pixel of the window lies inside a
        matched rectangle (`pixel_explained`) or not (`unexplained_pixels` > 0).
      * `other_sprite_like` -- sprite-like by the pool heuristic but containing
        bytes > 31, so it cannot be the same class as the matched sheets.
      * `blank` -- no non-zero pixel.
    """
    out = {"index_planes": [], "other_sprite_like": [], "blank": 0,
           "covered_slots": 0, "unmatched_slots": 0}
    for x, y in enumerate_slots(vram, x_step):
        win = covered[y:y + SLOT_ROWS, x:x + SLOT_WORDS]
        plane = slot_plane(vram, x, y)
        if hashlib.sha1(plane).hexdigest() in index:
            continue
        out["unmatched_slots"] += 1
        if win.all():
            out["covered_slots"] += 1
            continue
        s = plane_stats(plane)
        if s["distinct_indices"] == 1:
            out["blank"] += 1
            continue
        if s["zero_fraction"] <= SPRITE_ZERO_FRAC:
            continue
        if s["bytes_over_31"] == 0:
            pix = np.repeat(win, 2, axis=1)
            a = np.frombuffer(plane, dtype=np.uint8).reshape(SLOT_ROWS, SLOT_PX)
            nz_unc = int(((a != 0) & (pix == 0)).sum())
            out["index_planes"].append(
                dict(x=x, y=y, zero_fraction=s["zero_fraction"],
                     distinct_indices=s["distinct_indices"],
                     word_coverage=round(float(win.mean()), 4),
                     unexplained_pixels=nz_unc,
                     nibble_closure=nibble_closure(plane)))
        else:
            out["other_sprite_like"].append(
                dict(x=x, y=y, zero_fraction=s["zero_fraction"],
                     distinct_indices=s["distinct_indices"],
                     bytes_over_31=s["bytes_over_31"],
                     word_coverage=round(float(win.mean()), 4)))
    return out


# --------------------------------------------------------------------------
# candidate VRAM captures (answer: is there a battle-state capture?)
# --------------------------------------------------------------------------

def find_vram_captures(root):
    """Files in the tree that could be a VRAM capture.

    A raw PSX VRAM capture is exactly 1,048,576 bytes (1024x512x2). Also lists
    files whose name suggests a capture/state regardless of size, so a
    differently-sized or differently-named one cannot hide.
    """
    exact, named = [], []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in (".git", "__pycache__")]
        for fn in filenames:
            p = os.path.join(dirpath, fn)
            if os.path.islink(p):
                continue  # Compatibility aliases are not additional captures.
            try:
                size = os.path.getsize(p)
            except OSError:
                continue
            rel = os.path.relpath(p, root)
            if size == VRAM_BYTES:
                exact.append({"path": rel, "size": size})
            low = fn.lower()
            if any(k in low for k in ("vram", "savestate", "save_state")):
                named.append({"path": rel, "size": size})
    exact.sort(key=lambda r: r["path"])
    named.sort(key=lambda r: r["path"])
    return {"exact_1MiB": exact, "named": named}


# --------------------------------------------------------------------------
# the report
# --------------------------------------------------------------------------

def analyse(vram_path=None, pool_path=None, overlay_manifest=None,
            x_step=X_STEP_WORDS, want_containers=True, root=None):
    root = root or os.path.dirname(_KIT)
    vram = load_vram(vram_path)
    vram_file = vram_path or DEFAULT_VRAM
    with open(vram_file, "rb") as f:
        vram_sha1 = hashlib.sha1(f.read()).hexdigest()

    cache = {}
    iso = iso_index()

    def fetch(path):
        if path not in cache:
            rec = iso[path]
            cache[path] = disc.extract(rec["lba"], rec["size"])
        return cache[path]

    pool, pool_man = load_pool(pool_path)
    index, problems = decode_pool(pool, fetch)

    matches, degenerate = scan_slots(vram, index, x_step)
    covered = coverage_mask(matches)
    matched_sha1 = {h["sha1"] for h in matches}

    report = {
        "vram": {"path": os.path.relpath(vram_file, root),
                 "bytes": VRAM_BYTES, "sha1": vram_sha1},
        "geometry": {"vram_words": [VRAM_W, VRAM_H], "slot_words": SLOT_WORDS,
                     "slot_px": SLOT_PX, "x_step_words": x_step,
                     "x_step_px": x_step * 2,
                     "slots_enumerated": sum(1 for _ in enumerate_slots(vram, x_step))},
        "pool": {"manifest": pool_man.get("tool", "atlas_pool.py"),
                 "distinct": len(pool), "re_decoded": len(index),
                 "problems": problems[:20], "problem_count": len(problems)},
        "matches": {"non_degenerate": len(matches),
                    "distinct_atlases": len(matched_sha1),
                    "degenerate_blank": len(degenerate),
                    "covered_words": int(covered.sum()),
                    "covered_pct": round(100.0 * covered.sum() / covered.size, 2),
                    "slots": sorted(matches, key=lambda h: (h["x"], h["y"]))},
        "unexplained": unexplained(vram, index, covered, x_step),
        "captures": find_vram_captures(root),
    }

    if want_containers:
        sources, cstats = container_sources(fetch, overlay_manifest)
        # label every matched atlas with the containers it came from
        for hit in report["matches"]["slots"]:
            hit["container_sources"] = sources.get(hit["sha1"], [])
        con_index = {h: index[h] for h in sources if h in index}
        con_matches, con_degen = scan_slots(vram, con_index, x_step)
        report["containers"] = {
            "stats": cstats,
            "distinct_atlases": len(sources),
            "atlases_in_pool": len(set(sources) & set(index)),
            "atlases_not_in_pool": sorted(set(sources) - set(index))[:10],
            "slots_matched": sorted([(h["x"], h["y"]) for h in con_matches]),
            "slots_matched_count": len(con_matches),
            "degenerate_blank": len(con_degen),
        }
    return report


def _fmt_report(rep):
    L = []
    a = L.append
    g = rep["geometry"]
    a("VRAM capture      : %s  (%d bytes, sha1 %s)"
      % (rep["vram"]["path"], rep["vram"]["bytes"], rep["vram"]["sha1"][:16]))
    a("slot geometry     : %dx%d word slots, x step %d words (%d px), %d slots"
      % (g["slot_words"], g["slot_px"], g["x_step_words"], g["x_step_px"],
         g["slots_enumerated"]))
    p = rep["pool"]
    a("atlas pool        : %d distinct, %d re-decoded from disc, %d problems"
      % (p["distinct"], p["re_decoded"], p["problem_count"]))
    m = rep["matches"]
    a("byte-exact matches: %d slots, %d distinct atlases "
      "(+%d degenerate blank-slot hits excluded)"
      % (m["non_degenerate"], m["distinct_atlases"], m["degenerate_blank"]))
    a("explained region  : %d words of %d (%.2f%% of VRAM)"
      % (m["covered_words"], VRAM_W * VRAM_H, m["covered_pct"]))
    if "containers" in rep:
        c = rep["containers"]
        a("containers        : %d containers / %d atlases / %d distinct, "
          "%d in pool, %d slots matched (prior claim: 14)"
          % (c["stats"]["containers"], c["stats"]["atlases"],
             c["distinct_atlases"], c["atlases_in_pool"],
             c["slots_matched_count"]))
    u = rep["unexplained"]
    ip = u["index_planes"]
    bad = [r for r in ip if r["unexplained_pixels"] > 0]
    nib = [r for r in bad if r["nibble_closure"]["is_nibble_closure"]]
    a("unexplained       : %d unmatched slots; %d read as 32-colour sprite-like"
      " index planes" % (u["unmatched_slots"], len(ip)))
    a("                    %d of those have NO non-zero pixel outside an"
      " explained rectangle" % (len(ip) - len(bad)))
    a("                    %d have >=1 unexplained non-zero pixel"
      " (max %d px); %d of those have a nibble-closed byte set"
      " (4bpp-style, not an 8-bit plane)"
      % (len(bad), max([r["unexplained_pixels"] for r in bad], default=0),
         len(nib)))
    a("                    %d sprite-like with bytes>31 (a different data class);"
      " %d blank; %d fully covered"
      % (len(u["other_sprite_like"]), u["blank"], u["covered_slots"]))
    a("")
    a("residency map (slot -> atlas):")
    for hit in m["slots"]:
        src = hit.get("container_sources") or []
        labs = ", ".join("%s %s.c%d" % (os.path.basename(s["file"]), s["section"],
                                        s["blob"]) for s in src)
        a("  x=%4d y=%4d  %-11s %s+0x%-6x occ=%-2d in %d file(s)  %s"
          % (hit["x"], hit["y"], hit["class"], hit["first_file"],
             hit["first_offset"], hit["occurrences"], len(hit["files"]),
             labs or "no container"))
    cap = rep["captures"]
    a("")
    a("VRAM captures in tree: %d file(s) of exactly 1 MiB -> %s"
      % (len(cap["exact_1MiB"]), [r["path"] for r in cap["exact_1MiB"]]))
    a("                     %d file(s) named vram/savestate" % len(cap["named"]))
    return "\n".join(L)


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--vram", default=None)
    ap.add_argument("--pool", default=None)
    ap.add_argument("--overlay-manifest", default=None)
    ap.add_argument("--x-step", type=int, default=X_STEP_WORDS)
    ap.add_argument("--no-containers", action="store_true")
    ap.add_argument("--captures", action="store_true",
                    help="only list candidate VRAM captures and exit")
    ap.add_argument("--json", default=None, help="write the full report here")
    args = ap.parse_args(argv)

    root = os.path.dirname(_KIT)
    if args.captures:
        caps = find_vram_captures(root)
        print("files of exactly %d bytes (a raw PSX VRAM capture):" % VRAM_BYTES)
        for r in caps["exact_1MiB"]:
            print("  %s" % r["path"])
        print("files named vram/savestate:")
        for r in caps["named"]:
            print("  %s (%d bytes)" % (r["path"], r["size"]))
        return 0

    rep = analyse(args.vram, args.pool, args.overlay_manifest, args.x_step,
                  want_containers=not args.no_containers, root=root)
    if rep["pool"]["problem_count"]:
        print("POOL RE-DECODE PROBLEMS: %d" % rep["pool"]["problem_count"])
        for pr in rep["pool"]["problems"][:5]:
            print("  %s" % pr)
    print(_fmt_report(rep))
    if args.json:
        with open(args.json, "w") as f:
            json.dump(rep, f, indent=1)
        print("\njson: %s" % args.json)
    return 1 if rep["pool"]["problem_count"] else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

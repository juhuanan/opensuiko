#!/usr/bin/env python3
"""build_area_cluts.py -- deterministic area-CLUT registry builder.

The 26 area files (VB5*/VB7*/VB9 in DATA/02_AREA.B, MEL_SEL.BIN in
DATA/03_SHIRO, VE5.BIN in DATA/08_AREA.E) each carry a byte-identical
512-byte RGB555 CLUT. This tool locates it in the disc-extracted files
and writes the registry + palette swatches.

Method (fully disc-derived, no VRAM oracle):
  * Reference pattern = DATA/02_AREA.B/VB5AB.BIN bytes [0x34:0x34+512].
    VB5AB's header documents a palette bank at 0x34 ("8 x 512B RGB555
    palettes", docs/vb5_structure.md); pal 0 is the shared area
    CLUT. (The ad-hoc original used a VRAM capture as the search pattern;
    this rebuild takes the pattern from the disc file itself — the
    registry values are identical either way since every occurrence is
    byte-exact.)
  * Candidate set = every *.BIN under kit/extracted/bin_overlays/DATA/**
    (sorted). Files kept = those containing >= 1 byte-exact occurrence.
  * LBA provenance = kit/extracted/overlay_lba_table.json (static_table),
    the disc file table extracted from the image. Missing LBA = loud error.
  * rgb555 words are read from the disc file at the first occurrence
    offset; all occurrences across all files must be byte-identical
    (distinct_cluts counts distinct 512B patterns; expected 1).

Writes:
  kit/work/area_atlas/area_cluts.json
  kit/work/area_atlas/cluts/clut_<path_underscored>.png  (26 swatches,
    16x16 palette grid @16x scale = 256x256 RGB)

Usage:
  build_area_cluts.py [--data DIR] [--lba JSON] [--out DIR]

Exit 0 on success; non-zero with a clear message on any failure.
"""
import sys, os, glob, json, struct

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from psx_vram import rgb555_to_rgb888

try:
    from PIL import Image, ImageDraw
except ImportError:
    sys.exit("PIL required: pip install pillow")

REF_FILE = os.path.join("02_AREA.B", "VB5AB.BIN")  # relative to datadir
REF_OFF = 0x34
REF_LEN = 512
N_WORDS = 256


def find_all(data, pat):
    offs = []
    i = 0
    while True:
        i = data.find(pat, i)
        if i < 0:
            return offs
        offs.append(i)
        i += 1  # allow overlapping framings; offsets recorded exactly


def main(argv):
    kitdir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    datadir = os.path.join(kitdir, "extracted", "bin_overlays", "DATA")
    lba_path = os.path.join(kitdir, "extracted", "overlay_lba_table.json")
    outdir = os.path.join(kitdir, "work", "area_atlas")
    i = 0
    while i < len(argv):
        if argv[i] == "--data":
            datadir = argv[i + 1]; i += 2
        elif argv[i] == "--lba":
            lba_path = argv[i + 1]; i += 2
        elif argv[i] == "--out":
            outdir = argv[i + 1]; i += 2
        else:
            sys.exit("unknown arg: %s" % argv[i])

    ref_path = os.path.join(datadir, REF_FILE)
    with open(ref_path, "rb") as f:
        f.seek(REF_OFF)
        pattern = f.read(REF_LEN)
    if len(pattern) != REF_LEN:
        sys.exit("reference read failed: %s @0x%x" % (ref_path, REF_OFF))
    print("reference pattern: DATA/%s @0x%x (%d bytes)" % (REF_FILE, REF_OFF,
                                                           REF_LEN))

    with open(lba_path) as f:
        lba_table = json.load(f)["static_table"]["entries"]
    lba_by_path = {e["path"]: e["lba"] for e in lba_table}

    candidates = sorted(glob.glob(os.path.join(datadir, "**", "*.BIN"),
                                  recursive=True))
    print("scanning %d files..." % len(candidates))
    entries = []
    distinct = set()
    for path in candidates:
        with open(path, "rb") as f:
            data = f.read()
        offs = find_all(data, pattern)
        if not offs:
            continue
        # LBA-table keys are "DATA/..." paths, so resolve against the PARENT of
        # whatever --data root was selected. This used to be hardcoded to
        # kit/extracted/bin_overlays, which silently made --data unusable for a
        # freshly bootstrapped source tree (milestone 5, 2026-10-04).
        rel = os.path.relpath(path, os.path.dirname(os.path.abspath(datadir)))
        rel = rel.replace(os.sep, "/")
        if rel not in lba_by_path:
            sys.exit("no LBA for %s in overlay_lba_table.json" % rel)
        for o in offs:
            distinct.add(data[o:o + REF_LEN])
        words = struct.unpack("<%dH" % N_WORDS, data[offs[0]:offs[0] + REF_LEN])
        entries.append({
            "file": rel,
            "disc_lba": str(lba_by_path[rel]),
            "file_size": len(data),
            "clut_offsets": offs,
            "rgb555": ["%04x" % w for w in words],
        })
        print("  hit  %-32s lba=%-6d offsets=%s" % (
            rel, lba_by_path[rel], offs))

    registry = {
        "source": ("disc-derived: reference pattern = DATA/02_AREA.B/VB5AB.BIN"
                    " offset 0x34 (palette bank pal 0), byte-exact %dB RGB555"
                    " occurrence searched across all DATA/** files; every"
                    " value below read from the disc file at clut_offsets"
                    % REF_LEN),
        "count": len(entries),
        "distinct_cluts": len(distinct),
        "entries": entries,
    }
    os.makedirs(outdir, exist_ok=True)
    with open(os.path.join(outdir, "area_cluts.json"), "w") as f:
        json.dump(registry, f, indent=1)
        f.write("\n")

    swatchdir = os.path.join(outdir, "cluts")
    os.makedirs(swatchdir, exist_ok=True)
    for e in entries:
        words = [int(w, 16) for w in e["rgb555"]]
        img = Image.new("RGB", (256, 256))
        d = ImageDraw.Draw(img)
        for idx, w in enumerate(words):
            x0, y0 = (idx % 16) * 16, (idx // 16) * 16
            d.rectangle([x0, y0, x0 + 15, y0 + 15],
                        fill=rgb555_to_rgb888(w))
        sname = "clut_" + e["file"].replace("/", "_").replace(".", "_") + ".png"
        img.save(os.path.join(swatchdir, sname))
    print("----\n%d files, %d distinct CLUT pattern(s)" % (len(entries),
                                                          len(distinct)))
    print("wrote %s/area_cluts.json + %d swatches" % (outdir, len(entries)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

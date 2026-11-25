#!/usr/bin/env python3
"""make_contacts.py -- deterministic contact-sheet generator for 04_PLAY sprites.

Reads:
  kit/work/dump_sprites/<BASE>.BIN/frames.json + the frame PNGs
    (output of kit/tools/dump_sprites.py; every pixel disc-derived)
  kit/work/character_names.json
    (curated 3-letter-code -> character name map; keys starting with '_'
    are schema metadata and are ignored)

Writes:
  kit/work/contacts/<BASE>.BIN.png  (one per 04_PLAY file)

Layout (deterministic, documented):
  * Frames from every section in frames.json order (S1, S2), each section's
    frames in lexicographic PNG-filename order.  (The lost ad-hoc original
    used lexicographic order too, verified by template-matching
    work/contacts/ANT.BIN.png and AIL.BIN.png on 2026-10-02; it appears to
    have used an S1-only subset rule that could not be recovered, so this
    tool uses the full, explicit rule: all sections, all frames.)
  * 6 frames per row. Cell size = (max frame w + 4) x (max frame h + 4),
    2 px outer margin, frames centered in their cell.
  * Background (20,20,24,255) — same dark backdrop as the ad-hoc sheets.
  * Title bar on top: "<BASE>.BIN -- <name>" (or "unnamed"), drawn with
    PIL's built-in default bitmap font (ImageFont.load_default()),
    deterministic for a given Pillow version (built against 10.2.0).

Usage:
  make_contacts.py [--sprites DIR] [--names JSON] [--out DIR]
  (defaults: kit/work/dump_sprites, kit/work/character_names.json,
   kit/work/contacts)

Exit 0 if every sheet was written; 1 if any file errored (nothing silent).
"""
import sys, os, glob, json

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    sys.exit("PIL required: pip install pillow")

BG = (20, 20, 24, 255)
FG = (220, 220, 225, 255)
COLS = 6
MARGIN = 2
CELL_PAD = 4


def load_names(path):
    with open(path) as fh:
        data = json.load(fh)
    return {k: v for k, v in data.items() if not k.startswith('_')}


def make_sheet(base, spritedir, names, outdir):
    fdir = os.path.join(spritedir, base)
    fm_path = os.path.join(fdir, "frames.json")
    with open(fm_path) as f:
        fm = json.load(f)
    frames = []
    for sec_name in fm["sections"]:
        for fr in sorted(fm["sections"][sec_name]["frames"],
                         key=lambda r: r["png"]):
            p = os.path.join(fdir, fr["png"])
            img = Image.open(p).convert("RGBA")
            frames.append(img)
    if not frames:
        raise ValueError("%s: no frames in frames.json" % base)
    max_w = max(i.width for i in frames)
    max_h = max(i.height for i in frames)
    cell_w, cell_h = max_w + CELL_PAD, max_h + CELL_PAD
    rows = (len(frames) + COLS - 1) // COLS

    font = ImageFont.load_default()
    entry = names.get(base, {})
    name = entry.get("name") if isinstance(entry, dict) else None
    title = "%s -- %s" % (base, name if name else "unnamed")
    draw_tmp = ImageDraw.Draw(Image.new("RGBA", (8, 8)))
    tb = draw_tmp.textbbox((0, 0), title, font=font)
    title_h = (tb[3] - tb[1]) + 2 * MARGIN

    W = MARGIN * 2 + COLS * cell_w
    H = MARGIN * 2 + title_h + rows * cell_h
    sheet = Image.new("RGBA", (W, H), BG)
    d = ImageDraw.Draw(sheet)
    d.text((MARGIN, MARGIN), title, font=font, fill=FG)
    y0 = MARGIN + title_h + MARGIN
    for i, img in enumerate(frames):
        r, c = divmod(i, COLS)
        cx = MARGIN + c * cell_w
        cy = y0 + r * cell_h
        x = cx + (cell_w - img.width) // 2
        y = cy + (cell_h - img.height) // 2
        sheet.alpha_composite(img, (x, y))
    out = os.path.join(outdir, base + ".png")
    sheet.save(out)
    return len(frames)


def main(argv):
    kitdir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    spritedir = os.path.join(kitdir, "work", "dump_sprites")
    names_path = os.path.join(kitdir, "work", "character_names.json")
    outdir = os.path.join(kitdir, "work", "contacts")
    i = 0
    while i < len(argv):
        if argv[i] == "--sprites":
            spritedir = argv[i + 1]; i += 2
        elif argv[i] == "--names":
            names_path = argv[i + 1]; i += 2
        elif argv[i] == "--out":
            outdir = argv[i + 1]; i += 2
        else:
            sys.exit("unknown arg: %s" % argv[i])
    names = load_names(names_path)
    fdirs = sorted(glob.glob(os.path.join(spritedir, "*.BIN")))
    if not fdirs:
        sys.exit("no sprite dirs found in %s" % spritedir)
    os.makedirs(outdir, exist_ok=True)
    errors = []
    for fdir in fdirs:
        base = os.path.basename(fdir)
        try:
            n = make_sheet(base, spritedir, names, outdir)
            print("ok   %-12s %d frames" % (base, n))
        except Exception as ex:
            errors.append(base)
            print("ERROR %-12s %s: %s" % (base, type(ex).__name__, ex))
    print("----\n%d/%d sheets ok" % (len(fdirs) - len(errors), len(fdirs)))
    if errors:
        print("errored:", ", ".join(errors))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

"""Build a browsable HTML index of composed area scenes.

Review helper for `kit/docs/area_scene_rendering_plan.md`. Reads a scene render
output directory plus its sidecar JSONL and writes `index.html` with one section
per area, a thumbnail grid, and each room's composition status -- so a human can
scan the whole corpus for defects instead of opening files one at a time.

Composition status matters as much as the picture: a sidecar line saying
`rendered` only means a PNG was written. `composition.composed` says whether the
scene layers actually composed, and `composition.unresolved` lists what did not.
Both are surfaced here, because a base-only render and a fully composed one look
superficially similar in a thumbnail grid.

PNGs written here are review scratch. Nothing is promoted.

    python kit/tools/area_scene_index.py --scenes DIR --sidecar FILE.jsonl \
        --out DIR/index.html [--thumb-width 256] [--only-unresolved]
"""
from __future__ import annotations

import argparse
import html
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)


def load_sidecar(path):
    rows = []
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def status_of(row):
    """(label, css class, detail) for one sidecar row."""
    comp = row.get('composition') or {}
    if row.get('status') != 'rendered':
        return (row.get('status') or '?', 'skip', row.get('reason') or '')
    if not comp.get('composed'):
        if comp.get('companion_of'):
            return ('companion of room %s' % comp['companion_of'], 'comp',
                    comp.get('reason') or '')
        return ('base only', 'base', comp.get('reason') or 'no room record uses this section')
    # `unresolved` is BOOKKEEPING, not damage: every entry is an entity the renderer
    # declined to guess about (mostly zero-coordinate event stubs and superseded
    # mutually-exclusive variants). It says nothing about how the room looks, so a
    # composed room is 'ok' regardless and the count is shown as information.
    n = len(comp.get('unresolved') or [])
    return ('composed' + (' (%d entity notes)' % n if n else ''), 'ok',
            comp.get('scope', ''))


def build(scenes, sidecar, out, thumb_width=256, only_unresolved=False):
    rows = load_sidecar(sidecar)
    try:
        from PIL import Image
    except Exception:
        Image = None
    by_area = {}
    for row in rows:
        area = row.get('area') or row.get('bin') or '?'
        by_area.setdefault(area, []).append(row)
    outdir = os.path.dirname(os.path.abspath(out))
    thumbs = os.path.join(outdir, 'thumbs')
    os.makedirs(thumbs, exist_ok=True)
    parts = ["""<!doctype html><meta charset="utf-8">
<title>Suikoden area scenes -- review index</title>
<style>
 body{background:#16161a;color:#ddd;font:13px/1.4 -apple-system,Segoe UI,sans-serif;margin:16px}
 h1{font-size:18px} h2{font-size:15px;margin:22px 0 8px;border-bottom:1px solid #333;padding-bottom:4px}
 .sum{color:#9c9} .grid{display:flex;flex-wrap:wrap;gap:8px}
 .card{background:#1e1e24;border:1px solid #2c2c34;border-radius:5px;padding:5px;width:%dpx}
 .card img{display:block;width:100%%;image-rendering:pixelated;border-radius:3px}
 .cap{font-size:11px;color:#aaa;margin-top:4px;word-break:break-all}
 .ok{color:#8d8}.base{color:#fc6}.gap{color:#f9c}.skip{color:#888}
 .card.ok{border-color:#2f4f2f}.card.base{border-color:#5a4520}.card.gap{border-color:#5a4a20}
</style>
""" % (thumb_width + 12)]
    total = composed = 0
    companions = others = 0
    for area in sorted(by_area):
        rows_a = by_area[area]
        shown = []
        for row in sorted(rows_a, key=lambda r: (r.get('bin') or '', r.get('header_index') or 0)):
            label, cls, detail = status_of(row)
            if only_unresolved and cls not in ('base', 'skip', 'comp'):
                continue
            if row.get('status') == 'rendered':
                total += 1
                if cls in ('ok', 'gap'):
                    composed += 1
                elif cls == 'comp':
                    companions += 1
                elif cls == 'base':
                    others += 1
            shown.append((row, label, cls, detail))
        if not shown:
            continue
        parts.append('<h2>%s <span class="sum">(%d)</span></h2><div class="grid">'
                     % (html.escape(area), len(shown)))
        for row, label, cls, detail in shown:
            src = row.get('output')
            thumb = None
            if src:
                # the sidecar path is relative to the repo or the build root; the
                # image itself is found beside the sidecar's outdir
                base = os.path.basename(src)
                cand = os.path.join(outdir, area, base)
                if not os.path.exists(cand):
                    cand = os.path.join(outdir, base)
                if os.path.exists(cand) and Image is not None:
                    rel = os.path.join('thumbs', area + '__' + base)
                    if not os.path.exists(os.path.join(outdir, rel)):
                        im = Image.open(cand)
                        sc = thumb_width / float(im.width)
                        im = im.resize((thumb_width, max(1, int(im.height * sc))), Image.NEAREST)
                        im.save(os.path.join(outdir, rel))
                    thumb = rel
            room = html.escape(row.get('room') or '?')
            cap = ('<div class="cap"><b>%s</b><br><span class="%s">%s</span>'
                   % (room, cls, html.escape(label)))
            if detail:
                cap += '<br>%s' % html.escape(str(detail)[:120])
            if row.get('width'):
                cap += '<br>%dx%d prims=%s' % (row['width'], row['height'],
                                               (row.get('composition') or {}).get('primitives_total', '-'))
            cap += '</div>'
            if thumb:
                parts.append('<div class="card %s"><a href="%s"><img src="%s"></a>%s</div>'
                             % (cls, html.escape(os.path.relpath(
                                 os.path.join(outdir, area, os.path.basename(src)), outdir)),
                                html.escape(thumb), cap))
            else:
                parts.append('<div class="card %s">%s</div>' % (cls, cap))
        parts.append('</div>')
    head = ('<h1>Suikoden area scenes -- review index</h1>'
            '<p class="sum">%d rendered SECTIONS across %d areas: %d are composed rooms, '
            '%d are companion sections (a room\'s secondary layer -- they look sparse and '
            'dark by nature), %d uncategorised. '
            'Green = composed room, '
            'blue = companion section (a room\'s secondary layer, not a room), '
            'orange = base tilemap only. A \'note\' is an entity the renderer declined to '
            'guess about (a zero-coordinate event stub, or a superseded mutually-exclusive '
            'variant) -- it is bookkeeping, not visible damage.</p>'
            % (total, len(by_area), composed, companions, others))
    with open(out, 'w') as fh:
        fh.write(parts[0] + head + '\n'.join(parts[1:]) + '\n')
    return total, composed, len(by_area)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--scenes', required=True, help='scene render output directory')
    ap.add_argument('--sidecar', required=True, help='its sidecar JSONL')
    ap.add_argument('--out', required=True, help='index.html to write')
    ap.add_argument('--thumb-width', type=int, default=256)
    ap.add_argument('--only-unresolved', action='store_true')
    args = ap.parse_args(argv)
    t, c, a = build(args.scenes, args.sidecar, args.out, args.thumb_width,
                    args.only_unresolved)
    print('index: %s' % args.out)
    print('%d rendered sections, %d composed rooms, %d areas' % (t, c, a))
    return 0


if __name__ == '__main__':
    sys.exit(main())

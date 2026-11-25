"""HTML index of ROOM RECORDS, built from an existing scene render directory.

The corpus renderer (`fix_palettes.py`) enumerates SECTION HEADERS, so it produces
`<bin>_h<section>.png` and its sidecar is keyed by section slot. That under-reports
rooms: 1177 room records point at those sections (several can share one), and a
section-keyed view cannot show which room a picture belongs to, what its flags are,
or whether it is a real room, a companion, or content itself.

This tool enumerates room records instead and links each to whatever image the
renderer produced for its section. It is a viewer, not a renderer.

Two checks are BUILT IN rather than left until a user reports a blank page, because
both classes of defect reached the user this session:
  * every emitted src/href is verified to exist, and the tool fails loudly if not;
  * thumbnails have a minimum width relative to the source, so a 640x768 room is
    never shown as an unreadable smear.

    python kit/tools/area_room_index.py --scenes DIR --out DIR/rooms.html
"""
from __future__ import annotations

import argparse
import glob
import html
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import area_scene as sc  # noqa: E402
import area_animate as aa  # noqa: E402

MIN_THUMB = 360          # never show a room smaller than this many px wide
AREAS = {
    '01A': '01_AREA.A', '02B': '02_AREA.B', '06C': '06_AREA.C', '07D': '07_AREA.D',
    '08E': '08_AREA.E', '09F': '09_AREA.F', '10G': '10_AREA.G', '11H': '11_AREA.H',
    '13I': '13_AREA.I', '14S': '14_AREA.S', '15Z': '15_AREA.Z',
}


def collect_pngs(root):
    out = {}
    for dirpath, _dirs, files in os.walk(root):
        for f in files:
            if f.endswith('.png'):
                out.setdefault(f, os.path.join(dirpath, f))
    return out


def build(scenes, out_path, thumb_width=400):
    from PIL import Image
    images = collect_pngs(scenes)
    outdir = os.path.dirname(os.path.abspath(out_path))
    thumbs = os.path.join(outdir, 'room_thumbs')
    os.makedirs(thumbs, exist_ok=True)
    cards, missing = [], 0
    for area, folder in sorted(AREAS.items()):
        for path in sorted(glob.glob('kit/extracted/bin_overlays/DATA/%s/*.BIN' % folder)):
            with open(path, 'rb') as fh:
                data = fh.read()
            base = os.path.basename(path)[:-4]
            try:
                recs = sc.room_records(data)
            except Exception:
                continue
            for r in recs:
                sec = sc.section_off(data, r['section'])
                if sec is None or sec + 4 > len(data):
                    w = h = 0
                else:
                    w, h = sc.u16(data, sec), sc.u16(data, sec + 2)
                png = images.get('%s_h%d.png' % (base, r['section']))
                thumb = None
                if png:
                    name = '%s_r%d_s%d.png' % (base, r['index'], r['section'])
                    tp = os.path.join(thumbs, name)
                    if not os.path.exists(tp):
                        im = Image.open(png)
                        tw = min(max(MIN_THUMB, min(thumb_width, im.width)), im.width)
                        im.resize((tw, max(1, int(im.height * tw / im.width))),
                                  Image.NEAREST).save(tp)
                    thumb = os.path.relpath(tp, outdir)
                else:
                    missing += 1
                # A room whose byte8 sets a moving-overlay bit CANNOT be judged from a
                # static render: the game scrolls that layer (one step every 10 frames
                # for bit 1, or pins it to the camera for bit 5). The user reported
                # several such rooms as "glitched" -- VB5CA sec 0 appears under seven
                # different byte8 values, all glitched -- and that is expected, not a
                # defect. Labelled so a reviewer is not asked to judge a picture that
                # cannot be right.
                anim = int(r['byte8']) & 0x32
                # Frames the scenery in this room actually has. Before area_animate.py
                # existed every gallery drew frame 0, so an animated room was
                # indistinguishable from a static one. Reported here so the rooms worth
                # animating can be found without guessing.
                try:
                    _ft = aa.frame_table(data, sec)
                except Exception:
                    _ft = {}
                maxf = max([len(v) for v in _ft.values()] or [0])
                cards.append({'area': area, 'bin': base, 'slot': r['index'],
                              'section': r['section'], 'w': w, 'h': h,
                              'anim': anim, 'maxframes': maxf,
                              'nframe_objs': len(_ft),
                              'ents': r['entity_count'], 'byte7': r['byte7'],
                              'byte8': r['byte8'], 'byte9': r['byte9'],
                              'thumb': thumb, 'png': os.path.relpath(png, outdir) if png else None})
    cards.sort(key=lambda c: (c['area'], c['bin'], c['section'], c['slot']))
    with open(out_path, 'w') as fh:
        fh.write('<!doctype html><meta charset="utf-8"><title>Area rooms</title>')
        fh.write('<style>body{background:#16161a;color:#ddd;font:13px/1.45 '
                 '-apple-system,Segoe UI,sans-serif;margin:18px}'
                 'h2{font-size:14px;color:#ffd27f;border-bottom:1px solid #333;padding-bottom:4px}'
                 '.g{display:flex;flex-wrap:wrap;gap:10px}'
                 '.c{background:#1e1e24;border:1px solid #2c2c34;border-radius:4px;padding:6px;width:412px}'
                 '.c img{display:block;width:100%;image-rendering:pixelated;border-radius:3px}'
                 '.none{color:#e88;font-size:12px;padding:40px 0;text-align:center}'
                 '.cap{font-size:12px;color:#bbb;margin-top:4px}.anim{color:#fc6}</style>')
        fh.write('<h1>Area rooms: %d room records</h1>' % len(cards))
        fh.write('<p>Enumerated by ROOM RECORD (not by section). %d have no rendered image. '
                 'Several rooms can share one section &mdash; they are state variants. '
                 'Thumbnails are at least %dpx wide so buildings are visible.</p>'
                 % (missing, MIN_THUMB))
        cur = None
        for c in cards:
            if c['area'] != cur:
                if cur is not None:
                    fh.write('</div>')
                cur = c['area']
                fh.write('<h2>%s</h2><div class=g>' % cur)
            fh.write('<div class=c>')
            if c['thumb']:
                fh.write('<a href="%s"><img src="%s" loading="lazy"></a>'
                         % (html.escape(c['png']), html.escape(c['thumb'])))
            else:
                fh.write('<div class=none>no rendered image<br>(section %d)</div>' % c['section'])
            fh.write('<div class=cap><b>%s</b> slot %d sec %d &middot; %dx%d tiles &middot; '
                     'ents %d<br>b7=%#04x b8=%#04x b9=%d'
                     % (c['bin'], c['slot'], c['section'], c['w'], c['h'], c['ents'],
                        c['byte7'], c['byte8'], c['byte9']))
            if c.get('anim'):
                fh.write('<br><span class=anim>moving overlay (b8&%#04x) &mdash; a static '
                         'render cannot be right here</span>' % c['anim'])
            if c.get('nframe_objs'):
                fh.write('<br><span class=anim>%d animated object(s), up to %d frames '
                         '&mdash; render with kit/tools/area_animate.py</span>'
                         % (c['nframe_objs'], c['maxframes']))
            fh.write('</div></div>')
        if cur is not None:
            fh.write('</div>')
    # ---- BAKED-IN CHECK: every emitted reference must resolve ----
    import re
    with open(out_path) as fh:
        txt = fh.read()
    refs = re.findall(r'(?:src|href)="([^"]+)"', txt)
    bad = [x for x in refs if not x.startswith('http') and not os.path.exists(os.path.join(outdir, x))]
    if bad:
        raise SystemExit('LINK CHECK FAILED: %d of %d references missing, e.g. %s'
                         % (len(bad), len(refs), bad[:3]))
    return len(cards), missing, len(refs)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--scenes', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--thumb-width', type=int, default=400)
    a = ap.parse_args(argv)
    n, m, refs = build(a.scenes, a.out, a.thumb_width)
    print('rooms: %d | no image: %d | refs checked: %d ALL RESOLVE' % (n, m, refs))
    return 0


if __name__ == '__main__':
    sys.exit(main())

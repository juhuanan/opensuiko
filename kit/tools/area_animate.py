"""Render a room as an animated GIF using the game's own per-object frame timing.

The frame machinery was decoded long ago -- `descriptor[0]` is the frame count and
`descriptor+4+2k` is each frame's `(sheet, duration)` -- and `scene_compose` has
carried a `frame=` parameter the whole time. It was simply never exercised, so
8,721 scenery objects (16.7%) were drawn frozen at frame 0 in every gallery.

This tool simulates ticks rather than stepping one global frame index, because
**each object advances independently**: an object shows frame k for `duration[k]`
ticks, then moves to frame k+1. Objects in the same room have different frame
counts (2, 3, 4, 8...) and different durations (3, 4, 6, 7, 8, 11), so a single
global counter would desynchronise them. Simulating time is the only faithful
model.

It composites its own draw list from per-object frames, so it does NOT change
`scene_compose`'s behaviour for any existing caller.

    python kit/tools/area_animate.py --file VB9 --room 0 --out anim.gif
"""
from __future__ import annotations

import argparse
import glob
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import area_scene as sc  # noqa: E402
from psx_vram import rgb555_to_rgb888  # noqa: E402


def load_bin(name):
    hits = glob.glob(os.path.join(
        os.path.dirname(HERE), 'extracted/bin_overlays/DATA/*/%s.BIN' % name))
    if not hits:
        return (None, None)
    with open(hits[0], 'rb') as fh:
        return (fh.read(), name)


def frame_table(data, sec):
    """{type: [duration, ...]} for every scenery type this section places."""
    ctxs = sc.contexts(data, sec)
    if not ctxs or ctxs[0].get('offset') is None:
        return {}
    dtab = sc.ptr_at(data, ctxs[0]['offset'] + 0x14)
    if not isinstance(dtab, int):
        return {}
    out = {}
    for t in sorted({s['type'] for s in sc.scenery_records(data, sec)}):
        desc = sc.ptr_at(data, dtab + 4 * t)
        if not isinstance(desc, int):
            continue
        n = sc.u8(data, desc)
        if n < 2:
            continue
        out[t] = [max(1, sc.u8(data, desc + 5 + 2 * k)) for k in range(n)]
    return out


def frame_at(durations, tick):
    """The frame index an object shows at `tick`, cycling through its durations."""
    total = sum(durations)
    t = tick % total
    for i, d in enumerate(durations):
        if t < d:
            return i
        t -= d
    return len(durations) - 1


def render(data, room, name, out_path, scale=2, max_frames=64, hz=60.0,
           max_pixels=600000):
    """Full room animated at the game's real rate.

    The rate is now known from the engine, not assumed. `0x800C4244` decrements the
    timer (obj+3) once per CALL, and it is called from the per-object update -- 20
    sites, including the scenery emitter at 0x8012f600. So one tick == one frame ==
    1/60 s, and `descriptor+4+2k`'s duration is measured in frames.

    Frames are emitted as RUNS, not as a fixed tick step. Sampling every N ticks
    produces duplicate consecutive images, and Pillow's GIF writer coalesces those
    and loses their delays -- which makes the result play FASTER than the data says.
    Grouping equal states and giving each run its true duration avoids that
    entirely, so the GIF is the right length as well as the right shape.
    """
    from PIL import Image
    rec = sc.room_record(data, room)
    sec = sc.section_off(data, rec['section'])
    vram, _ = sc.load_scene_materials(data, sec, {'file': name})
    table = frame_table(data, sec)
    if not table:
        raise SystemExit('%s room %d places no multi-frame object' % (name, room))

    # The room's cycle is the LCM of its objects' cycles -- they only realign there.
    def lcm(a, b):
        x, y = a, b
        while y:
            x, y = y, x % y
        return a // x * b
    period = 1
    for d in table.values():
        period = lcm(period, sum(d))
    if period > 600:                       # keep the GIF finite on pathological rooms
        period = max(sum(d) for d in table.values()) * 4

    runs = []                              # [(state, run_length_in_ticks), ...]
    for tick in range(period):
        state = tuple(frame_at(d, tick) for _, d in sorted(table.items()))
        if runs and runs[-1][0] == state:
            runs[-1][1] += 1
        else:
            runs.append([state, 1])
    if len(runs) > 1 and runs[0][0] == runs[-1][0]:   # stitch the wrap
        runs[0][1] += runs[-1][1]
        runs.pop()
    if len(runs) > max_frames:
        stride = len(runs) // max_frames + 1
        runs = runs[::stride]

    types = sorted(table)
    imgs, delays = [], []
    for state, run in runs:
        fbt = {t: state[i] for i, t in enumerate(types)}
        img, _p, _m = sc.scene_compose(data, room, vram, source_meta={'file': name},
                                       npcs=True, frames_by_type=fbt)
        img = img.convert('RGB')
        if scale != 1:
            img = img.resize((img.width * scale, img.height * scale), 0)
        imgs.append(img)
        # Pillow's `duration` is in MILLISECONDS, not centiseconds. Passing
        # centiseconds here made every GIF play 10x too fast -- which is what the
        # user saw as "the orb looks a little fast". Integer milliseconds, minimum
        # 20 so no decoder silently clamps the frame away.
        delays.append(max(20, int(round(run * 1000.0 / hz))))
    if len(imgs) == 1:
        raise SystemExit('%s room %d has no frame variation' % (name, room))
    # Cap total pixels. The user could see an oversized GIF's frames but their viewer
    # would not open it as an animation, so a render nobody can play is not a render.
    if imgs:
        w, h = imgs[0].size
        over = (w * h) / float(max_pixels)
        if over > 1.0:
            f = 1.0 / (over ** 0.5)
            imgs = [i.resize((max(1, int(i.width * f)), max(1, int(i.height * f))), 0)
                    for i in imgs]
    # optimize=True lets the writer store DELTA rectangles for the frames after the
    # first, which is where almost all the size was: a room's background is static
    # between frames and only a few objects move. disposal=1 ("leave in place") is
    # what delta frames require. The VA1 GIF went from 32 MB to well under 1 MB.
    for i in imgs:
        i.thumbnail((4096, 4096))
    imgs[0].save(out_path, save_all=True, append_images=imgs[1:],
                 duration=delays, loop=0, optimize=True, disposal=1)
    return table, period, len(imgs), imgs[0].size, delays


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--file', required=True)
    ap.add_argument('--room', type=int, required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--scale', type=int, default=2)
    ap.add_argument('--max-frames', type=int, default=64)
    ap.add_argument('--max-pixels', type=int, default=600000,
                    help='downscale the GIF if it would exceed this; a viewer that '
                         'cannot open the file cannot show the animation')
    ap.add_argument('--hz', type=float, default=60.0,
                    help='Nominal object-update rate for GIF timing, default 60. '
                         'The audio catch-up callback does not establish the object-update '
                         'rate; see archive/docs/seq_tick_cadence.md.')
    a = ap.parse_args(argv)
    data, name = load_bin(a.file)
    if data is None:
        raise SystemExit('no such file: %s' % a.file)
    table, period, n, size, delays = render(data, a.room, name, a.out,
                                            a.scale, a.max_frames, a.hz)
    print('objects: %s' % {t: len(d) for t, d in sorted(table.items())})
    print('cycle %d ticks (%.3f s at %.0f Hz), %d gif frames, %s px -> %s'
          % (period, period / a.hz, a.hz, n, size, a.out))
    print('delays (ms): %s  total %.2f s'
          % (delays, sum(delays) / 1000.0))
    return 0


if __name__ == '__main__':
    sys.exit(main())

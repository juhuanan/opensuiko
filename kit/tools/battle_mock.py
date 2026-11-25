#!/usr/bin/env python3
"""Battle scene COMPOSITION MOCK — all three ingredients, one image.

WHAT THIS IS
------------
A composition mock that has become mostly-derived. It answers "can we render a
standard RPG battle yet, and what does the art look like together" with an image
rather than a status table:

  camera       the ENGINE's own: the GTE rotation matrix from the battle camera
               block's three angles via a literal port of `0x8014FCB4`, the GTE
               translation from the block's C words, the columns scaled by D,
               `view = R*v + TR`, `Sx = H*view.x/view.z`, `Sy = H*view.y/view.z`,
               `H = 1024`, `OFX/OFY = 0`. See the block comment at the top of the
               constants for the full call chain.
  positions    both spawn readers: the party writer `0x800DEBE8` in MAIN.EXE
               (formation table `0x8016B81C` entries 1-6 + the (+128, 0) origin)
               and the enemy writer `0x800DEE44` (the area's encounter descriptor,
               `positions = *(*(encounter+0x14))`, origin (-128, 0)).
  background   the battle's OWN ground tileset -- `directory[0]` of the area's
               battle resource table, a 128x128 page (4x4 grid of 32x32 tiles)
               with `c_count` pages concatenating -- assembled through the 16x16
               tilemap and ray-cast onto the world plane z = 0, with the battle's
               scenery atlas (`directory[1]`) behind the grid's far edge.
  enemies      the area's own enemy roster (`enemy_sprites.find_enemy_tables`
               + `parse_sections`), each drawn from its sprite section with its
               own on-disc palette
  party        `DATA/04_PLAY` `S1.c[1]` -- the sheet proven byte-exact against
               VRAM in `battle_vram_residency.md` -- for the six
               characters that capture identified as the resident party

WHAT IS *NOT* FAITHFUL, stated on the image itself:
  * **The per-quad shade.** The floor's geometry, extent, spacing, height field
    and tilemap are all disc bytes, but `0x800E7FD4` shades each quad through a
    GTE normal-colour call (`0x8014FB44`) whose light matrix is set up by
    `0x8014EA50` and is not decoded. The terrain is therefore drawn UNLIT rather
    than with an invented light. This is the last fitted-free gap in the floor.
  * **The scenery.** `directory[1]`'s trees/rocks are placed as ACTORS by
    `0x800DF144` at `scene+0xFD8`; that placement is not modelled, so the mock
    shows bare terrain.
  * **The encounter index.** `game_state[0x1BC0]` selects which of the area's
    encounter descriptors is used and is mode-dependent; the mock takes it as a
    parameter (default 1) and prints the roster so a gap is visible as a gap.
  * **One sprite per actor.** Multi-frame sheets are reduced to their largest
    connected component so the mock shows an actor and not a whole sheet; that
    reduction is a display heuristic, not the e-record slicing (which is open).
  * **Character identity.** The party is a fixed six chosen from the VRAM
    capture's resident set, not read from a save, so WHICH character occupies
    which of the six proven slots is not modelled. The user allowed a standard
    six; the six-byte battle-order array at `game_state+0x0E` is the real input.

Usage:
    battle_mock.py --area 08_AREA.E --out kit/work/battle_mock
Exit: 0 on success.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import struct
import sys
from functools import lru_cache

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import disc                                     # noqa: E402
import lzss                                     # noqa: E402
import enemy_sprites as es                      # noqa: E402
from psx_vram import rgb555                     # noqa: E402

try:
    import numpy as np
    from PIL import Image, ImageDraw
except ImportError:  # pragma: no cover
    sys.exit("numpy + PIL required")

_TOOLS = os.path.dirname(os.path.abspath(__file__))
_KIT = os.path.dirname(_TOOLS)
_ISO_JSON = os.path.join(_KIT, "extracted", "iso_files.json")

SCREEN = (320, 240)
# Reference-driven check: the user's PSX screenshots are uniform -- the PARTY is
# bottom-right and the ENEMIES are upper-left. That is now DERIVED rather than
# asserted: feeding the proven spawn positions through the proven camera puts the
# six party members at screen x 192-291 / y 144-205 and the enemies at x 76-149 /
# y 76-106 on a 320x240 frame. The old file took the sides from the screenshots
# because it could not get this out of the code; it can now.
# --- the camera, exactly as 0x800E14C0 builds it ---------------------------
# The engine does NOT hand-roll a basis. It builds the GTE's rotation matrix and
# translation vector and lets the GTE project. The chain, read end to end:
#
#   0x800E14C0  the frame's camera setup: a three-iteration loop over the 12
#               words, each shifted right by 12 (so the block is Q12):
#                  scene+0x1270 (3 halfwords) <- words 0-2   (position)
#                  scene+0x1276 (3 halfwords) <- words 3-5   (THE ANGLES)
#                  scene+0x127C (3 words)     <- words 6-8   (C, the GTE TR)
#                  scene+0x1288 (3 words)     <- words 9-11  (D, the scale)
#   0x800E1518  jal 0x8014FCB4(scene+0x1276, 0x8017AF44)   build the matrix
#   0x800E1530  jal 0x8014F3C8(matrix, scene+0x127C)       matrix+0x14..0x1C = C
#   0x800E1548  jal 0x8014F3EC(matrix, scene+0x1288)       ScaleMatrix by D
#   0x800E1558  jal 0x8014F510(matrix)                     ctc2 ctrl 0..4  = R
#   0x800E1568  jal 0x8014F5A0(matrix)                     ctc2 ctrl 5,6,7 = TR
#
# `0x8014FCB4` masks every angle with `& 0x0FFF` and indexes a 4096-entry
# (s16 sin, s16 cos) pair table at **0x801725BC**, so the angle unit is the
# 12-bit turn (0x1000 = a full turn) and the fixed-point unit is 4096. It is
# ported literally below, truncating `>> 12` at each step exactly as the MIPS
# does. The port returns the identity for (0,0,0), exact quarter turns for a
# single 0x400 angle, and an orthonormal det=+1 matrix otherwise -- which is what
# identifies it. Matrix and TR come from the same place, and the world->screen
# law is the GTE's:
#
#   view = R * v + TR          Sx = H * view.x / view.z
#                              Sy = H * view.y / view.z
#
# with `H` = 1024 (`0x800DE938` -> `0x8014EFB4`) and `OFX/OFY = (0,0)`
# (`0x800DE930`). The three angles are Euler rotations about X, Y and Z; the
# builder emits the world->view matrix, so a POSITIVE angle turns the world.
#
# The camera BLOCKS, read straight out of MAIN.EXE (raw words >> 12):
#
#              position      angles         C           D
#   field      (0,0,0)       (-768,0,640)   (0,0,1024)  (4096,4096,4096)
#   battle s0  (80,0,0)      (-768,0,608)   (0,0,1024)  (4864,4864,4864)
#   battle s1  (112,0,0)     (-768,0,608)   (0,0,1024)  (3840,3840,3840)
#
# ** CORRECTION 2026-10-06. An earlier revision of this file divided the block by
#    0x10000 instead of 0x1000 and recorded PITCH_UNITS = -48 / ROLL_UNITS = 38,
#    i.e. a pitch of -4.22 degrees. The real pitch is -768 units = -67.5 degrees,
#    a normal 3/4 view, and the engine composes THREE Euler angles rather than a
#    pitch plus a roll about the forward axis. The retired names are PITCH_UNITS,
#    ROLL_UNITS, CAM_TR, GROUND_DROP, CAM_H, camera_basis(), formation() and
#    area_slot_table(). **
#
# The ground plane is z = 0 with world **-Z up**: the actor's +0x68/+0x6C/+0x70
# are X / depth / height, and the flying-enemy flag (stats+0x26 & 0x20)
# SUBTRACTS 10 units from z (`0x800DF054`, `-0xA000` = -10 * 4096) to raise the
# actor above the floor. The state-1 camera solves to world (713, 528, -366)
# looking at the origin -- 366 units up and about 25 degrees down.
# EVERY camera block the battle installs. Enumerated by scanning MAIN for
# `lui/addiu a0,<block> ; jal 0x800F6110` and keeping the call sites inside the
# battle state machine `0x80104808` and the battle driver `0x800F64F0`:
#
#   key  block       call site    pos        angles         C          D
#   0    0x8016D6BC  0x8010488C   (80,0,0)   (-768,0,608)   (0,0,1024) 4864  1.1875
#   1    0x8016D77C  0x80104900   (112,0,0)  (-768,0,608)   (0,0,1024) 3840  0.9375
#   2    0x8016D7AC  0x80104A94   (112,0,0)  (-768,0,352)   (0,0,1024) 3840  0.9375
#   3    0x8016D80C  0x80105458   (-160,0,0) (-768,0,352)   (0,0,1024) 5120  1.25
#   4    0x8016B878  0x800F6BD0   (0,0,0)    (-768,0,608)   (0,0,1024) 4096  1.0
#                    0x800F759C   (the battle DRIVER's own default)
#
# ** The earlier reading had only blocks 0 and 1. States 2-4 RE-YAW the camera
#    from 608 to 352 -- 53.4 degrees to 30.9 -- and state 3 also swings it to
#    x = -160, so the settled battle may not be block 1 at all. ** Which state a
#    finished battle rests in is not decoded; `--cam` selects one and the caller
#    is the judge. Projections for area A's three-slime encounter (reference has
#    the party at x 150-260 / y 110-200 and the foes at x 40-135 / y 85-140):
#
#   key  party x/y          foes x/y
#   0    203..333 152..233  31..122  67..88
#   1    192..291 144..205  57..129  77..95
#   2    239..325 126..187  35..88   84..111
#   3    269..384 128..214  -6..66   74..109
#   4    195..301 147..211  50..128  74..94
BATTLE_CAM_BLOCKS = {0: 0x8016D6BC, 1: 0x8016D77C, 2: 0x8016D7AC,
                     3: 0x8016D80C, 4: 0x8016B878}
# WHICH BLOCK A SETTLED BATTLE USES IS NOW READ, NOT PICKED.
#
# `0x80104808` is the battle state machine. It indexes a 6-entry jump table
# (`0x800C1504`, states 0-5) on `[0x8017A038][0x120]`, and each state installs a
# camera ON ENTRY, guarded by a flag at `[0x124]` that the shared advance code
# `0x80104AC8` sets:
#
#     80104ac8  ori  $v0,$zero,1
#     80104acc  sw   $v0,0x124($s3)     ; "install the camera on entry"
#     80104ad0  addiu $v1,$v1,0x1
#     80104ad8  sw   $v1,0x120($s3)     ; next state
#
# Scanning the whole machine for `jal 0x800F6110` gives EXACTLY THREE installs:
#
#     state 0  0x8010488C  -> 0x8016D6BC   60 frames
#     state 1  0x80104900  -> 0x8016D77C   60 frames
#     state 3  0x80104A94  -> 0x8016D7AC   80 frames
#
# States 2, 4 and 5 install NO camera at all. And state 4 is the state that runs
# forever: its tail reloads its own index and writes it back --
#
#     80104d84  lw   $v0,0x120($s3)
#     80104d88  sw   $zero,0x11c($s3)   ; reset its 0x40-frame timer
#     80104d94  sw   $v0,0x120($s3)     ; ... and re-enter state 4
#
# -- so the camera in the steady state is whatever was installed LAST, which is
# **block 2, 0x8016D7AC** (pos (112,0,0), angles (-768,0,352), D 3840), installed
# by state 3 and still interpolating over its 80 frames while state 3 only lasts
# 60. Block 4 (`0x8016B878`) is not in the state machine at all: its callers
# `0x800F6BD0`/`0x800F759C` are in the battle DRIVER `0x800F64F0`, and block 3
# (`0x8016D80C`) is installed from `0x80105458`, past the machine's epilogue.
#
# ** OPEN: under block 2 the party projects to x 239-325, i.e. partly off the
#    right edge, which the reference does not show. So the SCROLL (`scene[0x132C]`,
#    which accumulates the camera sweep) must be non-zero once the battle settles,
#    and that accumulation is not derived yet. The default is set to what the state
#    machine says; the framing is the part still to close. **
BATTLE_CAM_STATE = 2
PROJ_H = 1024.0             # the GTE projection plane distance, as the SCENE
                            # render sets it: 0x800DE938 does
                            #   jal 0x8014EFB4 (set H) with $4 = 0x400 = 1024,
                            # right after 0x800DE930 sets OFX/OFY = (0,0).
                            # The 1000 at 0x8014F93C is only the RESET value.
# `scene[0x132C]`/`scene[0x132E]` are added to the projected position before it is
# packed (0x800E0824). They have exactly ONE writer, 0x800E15E0/0x800E1600:
#   scene[0x132C] += ([0x8017BEA4] >> 12) - arg
# i.e. they ACCUMULATE the camera's motion rather than being set to a constant,
# and the same scene-render setup that sets H ZEROES the accumulators
# (0x800DE908-0x800DE920). A fresh scene therefore starts at scroll 0, and (0,0)
# is CORRECT for a stationary battle camera -- this is not an unread value.
SCROLL = (0.0, 0.0)

SIN_COS_TABLE = 0x801725BC  # 4096 (s16 sin, s16 cos) pairs; MAIN file 0xB1DBC


@lru_cache(maxsize=1)
def _sin_cos():
    """The engine's (sin, cos) pair table, read from MAIN.EXE at 0x801725BC."""
    import struct as _s
    im = mainexe_image()
    off = SIN_COS_TABLE - 0x800C0800
    raw = _s.unpack_from("<%dh" % (2 * 4096), im, off)
    return raw[0::2], raw[1::2]


def sin_cos_lookup(theta):
    """(sin, cos) of a 12-bit-turn angle, using 0x8014FCB4's own sign fold.

    A non-negative angle reads the table at `theta & 0xFFF`; a negative one reads
    it at `(-theta) & 0xFFF` and negates the SINE only, because cosine is even.
    Both branches are in the disassembly (`0x8014FCBC` / `0x8014FCF8`), so this
    is the engine's fold and not `math.sin`.
    """
    sin_t, cos_t = _sin_cos()
    if theta >= 0:
        i = theta & 0xFFF
        return sin_t[i], cos_t[i]
    i = (-theta) & 0xFFF
    return -sin_t[i], cos_t[i]


def rot_matrix(angles):
    """Literal port of `0x8014FCB4(angles, matrix)`: 3 angles -> 9 halfwords.

    Every `>> 12` below is a MIPS `sra` on a 32-bit register and truncates, so
    the intermediate roundings are reproduced rather than folded together. The
    result is row-major: `m[0..2]` is RT11/RT12/RT13, i.e. the GTE's row 0.
    """
    t3, t0 = sin_cos_lookup(angles[0])       # s0, c0
    t6, t1 = sin_cos_lookup(angles[1])       # s1, c1
    t4 = -t6                                 # the routine keeps both signs of s1
    t5, t2 = sin_cos_lookup(angles[2])       # s2, c2
    m = [0] * 9
    m[2] = t6
    m[5] = (-(t1 * t3)) >> 12
    m[8] = (t1 * t0) >> 12
    m[0] = (t2 * t1) >> 12
    m[1] = (-(t5 * t1)) >> 12
    t8 = (t2 * t4) >> 12
    m[3] = ((t5 * t0) >> 12) - ((t8 * t3) >> 12)
    m[6] = ((t5 * t3) >> 12) + ((t8 * t0) >> 12)
    t8b = (t5 * t4) >> 12
    m[4] = ((t2 * t0) >> 12) + ((t8b * t3) >> 12)
    m[7] = ((t2 * t3) >> 12) - ((t8b * t0) >> 12)
    return m


def scale_matrix(m, d):
    """`0x8014F3EC(matrix, vec)`: each COLUMN scaled by the matching component.

    `m[i][j] = (m[i][j] * d[j]) >> 12`, element by element, exactly as the
    routine's packed-halfword multiply-accumulate does it. For both battle blocks
    D is uniform, so this is a uniform 4864/4096 = 1.1875 (state 0) or
    3840/4096 = 0.9375 (state 1) applied to the rotation -- note that it scales
    the matrix and NOT the translation, so it is a real magnification.
    """
    return [(m[i * 3 + j] * d[j]) >> 12 for i in range(3) for j in range(3)]


def camera_block(state=BATTLE_CAM_STATE):
    """The twelve interpreted (raw >> 12) words of a battle camera block."""
    import struct as _s
    va = BATTLE_CAM_BLOCKS[state]
    im = mainexe_image()
    return [_s.unpack_from("<i", im, va - 0x800C0800 + 4 * i)[0] >> 12
            for i in range(12)]


def battle_camera(state=BATTLE_CAM_STATE):
    """`(R, TR, block)` for a battle camera state, straight from disc bytes."""
    b = camera_block(state)
    return scale_matrix(rot_matrix(b[3:6]), b[9:12]), tuple(b[6:9]), b


def battle_scale_q12(state=BATTLE_CAM_STATE):
    """`(D[0] << 10) / C[2]` -- the actor size, CONSTANT per camera.

    `0x800E0824` computes this once per frame and stores it in the sprite's
    +0x0E/+0x10; it is not 1/depth, which is why both sides come out the same
    size. 4864 for state 0, 3840 for state 1, 4096 (1.0) on the field.
    """
    b = camera_block(state)
    return (b[9] << 10) // b[8]


def project_point(p, state=BATTLE_CAM_STATE, H=PROJ_H, size=SCREEN):
    """world -> `(screen_x, screen_y, depth)`, the engine's own law.

    The GTE adds TR to the rotated point in one 44-bit accumulator and then
    shifts right by 12, which is what the `(TR << 12) + sum(...) >> 12` below
    reproduces. OFX/OFY are 0, so the projection origin is the frame centre.
    """
    R, TR, _b = battle_camera(state)
    view = [((TR[i] << 12) + sum(R[i * 3 + j] * p[j] for j in range(3))) >> 12
            for i in range(3)]
    if view[2] <= 1:
        return None
    return (size[0] / 2.0 + H * view[0] / view[2],
            size[1] / 2.0 + H * view[1] / view[2], float(view[2]))


def camera_world_position(state=BATTLE_CAM_STATE):
    """The eye, by inverting `view = R*v + TR` at view = 0."""
    import numpy as np
    R, TR, _b = battle_camera(state)
    return np.linalg.solve(np.array(R, dtype=float).reshape(3, 3) / 4096.0,
                           -np.array(TR, dtype=float))

# The six characters the existing VRAM capture shows resident, and the sheet
# each one is resident AS (docs/battle_vram_residency.md, corrected by
# battle_vram_residency_full.md). CRE/KAM/TAI/VIC contribute
# S1.c[0]+S1.c[1]+S2.c[0]; SHU and GRE contribute S2.c[0] ONLY -- so drawing
# them from S1.c[1] would show a sheet the capture never had. VIC is the
# character embedded in VA1.BIN; an earlier note here said CRO, which was
# wrong (the container's ATLAS SET matches VIC.BIN exactly, and matches no
# other file).
PARTY = (("CRE", "S1", 1), ("KAM", "S1", 1), ("TAI", "S1", 1),
         ("VIC", "S1", 1), ("SHU", "S2", 0), ("GRE", "S2", 0))


def character_name(char):
    """Character name for a 04_PLAY stem from kit/work/character_names.json.

    That file is curated knowledge with an explicit confidence field per entry,
    so an unknown name is reported as the code rather than invented.
    """
    path = os.path.join(_KIT, "work", "character_names.json")
    if not os.path.exists(path):
        return char
    with open(path) as f:
        names = json.load(f)
    rec = names.get("%s.BIN" % char) or {}
    return rec.get("name") or char


def enemy_stat_line(d, record_offset):
    """(level, formation_footprint, hp) from the64-byte enemy source record."""
    return (d[record_offset + 0x10], d[record_offset + 0x11],
            struct.unpack_from("<H", d, record_offset + 0x12)[0])


def tag_of(area_path):
    """Unique per data file: area dir + file stem (02_AREA.B has B and J)."""
    parts = area_path.split("/")
    return "%s_%s" % (parts[-2], parts[-1].replace("_DATA.BIN", ""))


def disc_path(path):
    with open(_ISO_JSON) as f:
        for r in json.load(f):
            if r.get("path") == path:
                return r
    raise SystemExit("%s not in the ISO listing" % path)


def largest_component(atlas, palette, min_px=64):
    """Largest non-zero connected component of a 128x128 index plane, as RGBA.

    RETIRED FROM THE RENDER PATH 2026-10-06, and kept only because two tests
    exercise it as a primitive. It is the WRONG crop: the sheets are packed, so
    adjacent poses touch and the largest component spans two of them -- KAM came
    out 44 px wide (two characters), and area A's slime came out as a pair of
    slimes. `party_pose()` and `enemy_pose()` crop the disc's own pose CELL
    instead, which needs no segmentation. Do not wire this back into `build()`.
    """
    a = np.frombuffer(atlas, dtype=np.uint8).reshape(128, 128)
    mask = a != 0
    if not mask.any():
        return None
    lab = np.zeros(mask.shape, np.int32)
    cur = 0
    best = (0, None)
    ys, xs = np.nonzero(mask)
    for y0, x0 in zip(ys, xs):
        if lab[y0, x0]:
            continue
        cur += 1
        stack = [(y0, x0)]
        lab[y0, x0] = cur
        pts = []
        while stack:
            y, x = stack.pop()
            pts.append((y, x))
            for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                ny, nx = y + dy, x + dx
                if 0 <= ny < 128 and 0 <= nx < 128 and mask[ny, nx] \
                        and not lab[ny, nx]:
                    lab[ny, nx] = cur
                    stack.append((ny, nx))
        if len(pts) > best[0]:
            best = (len(pts), pts)
    pr = [tuple(w) if isinstance(w, (tuple, list)) else rgb555(w)
          for w in palette]
    if best[0] < min_px:
        ys, xs = np.nonzero(mask)
        sel = list(zip(ys, xs))
    else:
        sel = best[1]
    ys = [p[0] for p in sel]
    xs = [p[1] for p in sel]
    y0, y1, x0, x1 = min(ys), max(ys), min(xs), max(xs)
    img = Image.new("RGBA", (x1 - x0 + 1, y1 - y0 + 1))
    px = img.load()
    keep = set(sel)
    for y, x in sel:
        idx = int(a[y, x])
        if idx >= len(pr):
            continue
        px[x - x0, y - y0] = pr[idx] + (255,)
    return img


def party_pose(char, section="S1", blob_index=1, row=None, col=None):
    """One COMPLETE pose of a 04_PLAY character, cropped on the e-record's cell.

    The e-record's `(w, h)` is the CELL size, not a bounding box: every one of
    SHU's and GRE's e-records is `(24, 48)`, and the atlas's own column bands put
    their poses on a 24-pixel pitch; CRE's are `(32, 64)` and its pitch is exactly
    32. So the atlas is a grid of `w x h` cells and each cell holds one pose.

    That matters because the sheets are PACKED: adjacent poses touch, so a
    connected-component crop merges them (KAM's biggest blob came out 44 px wide,
    two characters side by side). Cropping the cell needs no segmentation at all.

    `row`/`col` select the cell and each may stand alone (`--pose-row 1` means "the
    densest cell in row 1"). The default is the densest cell of the whole atlas,
    which is always a complete BODY pose -- row 1 is not a safe default, because
    for CRE it holds a lying pose and a large star effect and the densest cell
    there is the effect, not the character. **Which pose the ACTION SCRIPT chooses
    for a given moment is not decoded** (`0x800E358C` and its handlers drive the
    animation); the standing poses are conventionally row 0 and the back views row
    1, so the choice is exposed rather than guessed.
    """
    raw, pal = party_sheet(char, section, blob_index)
    import numpy as np
    a = np.frombuffer(raw, dtype=np.uint8).reshape(128, 128)
    cw, ch = _party_cell_size(char, section)
    cols, rows = 128 // cw, 128 // ch

    def cell(r, c):
        m = a[r * ch:(r + 1) * ch, c * cw:(c + 1) * cw]
        ys, xs = np.nonzero(m)
        if not len(ys):
            return None
        # TIGHT-CROPPED to the cell's opaque content. The cell has bottom padding
        # (CRE 5 rows, KAM 4, SHU/GRE 3), and anchoring the CELL's bottom edge at
        # the projected point therefore FLOATS the character by that much. Cropping
        # to the content puts the feet where the projection says they are.
        y0, y1, x0, x1 = int(ys.min()), int(ys.max()), int(xs.min()), int(xs.max())
        img = Image.new("RGBA", (x1 - x0 + 1, y1 - y0 + 1))
        px = img.load()
        for y, x in zip(ys, xs):
            idx = int(m[y, x])
            if idx < len(pal):
                px[x - x0, y - y0] = tuple(pal[idx]) + (255,)
        return img

    # `row` alone means "the densest cell IN that row", which is how the body
    # poses and the weapon/effect cells are told apart
    rs = range(rows) if row is None else [row % rows]
    cs = range(cols) if col is None else [col % cols]
    if row is None and col is None:
        rs, cs = range(rows), range(cols)
    best, best_n = None, -1
    for r in rs:
        for c in cs:
            m = a[r * ch:(r + 1) * ch, c * cw:(c + 1) * cw]
            n = int((m != 0).sum())
            if n > best_n:
                best, best_n = cell(r, c), n
    return best


_CELL_CACHE = {}


def _party_cell_size(char, section="S1"):
    """`(w, h)` of a 04_PLAY character's pose cell, from its first e-record."""
    key = (char, section)
    if key not in _CELL_CACHE:
        import tempfile
        from parse_04play import parse_04play
        r = disc_path("DATA/04_PLAY/%s.BIN" % char)
        d = disc.extract(r["lba"], r["size"])
        with tempfile.TemporaryDirectory() as td:
            p = os.path.join(td, "c.bin")
            with open(p, "wb") as f:
                f.write(d)
            parsed = parse_04play(p)
        rec = parsed["sections"][section]["e"]["entries"][0]["record"]
        _CELL_CACHE[key] = (int(rec["w"]), int(rec["h"]))
    return _CELL_CACHE[key]


def party_sheet(char, section="S1", blob_index=1):
    """The resident sheet's atlas + its 32-word palette for a 04_PLAY char."""
    r = disc_path("DATA/04_PLAY/%s.BIN" % char)
    d = disc.extract(r["lba"], r["size"])
    import tempfile
    from parse_04play import parse_04play
    with tempfile.TemporaryDirectory() as td:
        p = os.path.join(td, "c.bin")
        with open(p, "wb") as f:
            f.write(d)
        parsed = parse_04play(p)
    s1 = parsed["sections"][section]
    blob = s1["c"]["entries"][blob_index]["blob"]
    raw = lzss.decode_strict(d[blob["data_file_offset"]:
                               blob["data_file_offset"] + blob["data_len"]])
    pal = s1["d"]["entries"][0]["palette"]["rgb888"]
    return raw, [tuple(c) for c in pal]



# --- the two standard-battle spawn readers, in MAIN.EXE and in the area file --


def party_world_positions(im=None):
    """The six standard-battle party world positions, out of MAIN.EXE.

    `0x800DEBE8` is the party spawn and it is NOT field-only: the mode dispatcher
    tests `slti v0,v1,4` at `0x800C9A74`, so mode 3 does not take the branch to
    `0x800C9ADC` and `j 0x800C9ABC` installs `0x800DDF98`, the standard scene
    route. The battle transition `0x801285A4` stores mode 3 at `0x801285FC`. The
    scene's own setup calls this spawn at `0x800DE7FC`.

    The routine:
      * starts at actor index 1             (`0x800DEC28`, dest `scene+0xDC`)
      * walks the table at 0x8016B81C from ENTRY 1, +6 per actor
                                            (`0x800DEC50`, `0x800DEDCC`)
      * adds the origin at 0x8016B80C/0x8016B810 = (+128, 0)
      * stores `(x+ox) << 12`, `(y+oy) << 12`, `z << 12` into +0x68/+0x6C/+0x70
        (`0x800DECFC`, `0x800DED20`, `0x800DED38`), and the identical home copies
        at +0x5C/+0x60/+0x64 (`0x800DED00`/`0x800DED24`/`0x800DED3C`) -- the spawn
        position IS the home position.

    Entry 0 is skipped. The six positions before `<< 12` are the staggered 2x3
    cluster the reference screenshots show: two columns of three, each column
    internally staggered in depth.

        actor 1 (120, 50, 0)   actor 4 (192, 75, 0)
        actor 2 (112,  0, 0)   actor 5 (178, 25, 0)
        actor 3 (120,-50, 0)   actor 6 (178,-25, 0)

    Character identity follows the six-byte battle-order array at
    `game_state+0x0E` (`0x800DEC68` reads the byte at `game_state[0x0D+i]` and
    indexes the pointer table at `game_state+0x1B9C`), not the entry order.
    """
    im = mainexe_image() if im is None else im
    ox, oy = struct.unpack_from("<2i", im, SIDE_ORIGIN_POS - 0x800C0800)
    out = []
    for actor in range(1, 7):
        t = struct.unpack_from("<3h", im,
                               FORMATION_TABLE - 0x800C0800 + 6 * actor)
        out.append((t[0] + ox, t[1] + oy, t[2]))
    return out


def area_encounters(d):
    """The area's standard-battle encounter descriptors, by POINTER CHASE.

    The chain, and the dereference the earlier reading missed:

        D          = *(0x80080000)                    the area descriptor
        resources  = *(D + 0x0C)                      the battle resource table
        directory  = *resources                       the standard battle dir
        selectors  = *(directory + 0x08)              [count, encounter ptrs...]
        encounter  = *(selectors + 4*game_state[1BC0])
        aux        = *(encounter + 0x14)              0x800DEEA8
        positions  = *aux                             0x800DEEB4  <-- the miss
        scene[0x1348] = positions                     0x800DEEC0

    `0x800DEE44` then visits all SIX roster slots: the enemy id is the byte at
    `encounter+4+slot` (`0x800DEEF4`) and a zero skips the actor while the
    position offset STILL advances by 6 (`0x800DF114`), so a roster gap leaves a
    gap in the formation rather than pulling the later enemies forward. For a
    nonzero slot `k`:

        worldX = (s16(positions + 6k + 0) - 128) << 12   origin 0x8016B814
        worldY =  s16(positions + 6k + 2)        << 12   origin 0x8016B818 = 0
        worldZ =  s16(positions + 6k + 4)        << 12

    and `worldZ -= 0xA000` when `enemy_stats[0x26] & 0x20` (`0x800DF044`-
    `0x800DF064`) -- ten world units UP, because world -Z is up. So these really
    are world coordinates and the triple's second field is not a screen offset.

    Returns `[dict(index, offset, positions, roster, slots)]`, where `slots[k]`
    is `(enemy_id, (x, y, z))` or None for an empty roster slot.
    """
    def word(off):
        if not 0 <= off <= len(d) - 4:
            raise ValueError("word outside the area file at %#x" % off)
        return struct.unpack_from("<I", d, off)[0]

    def ptr(off):
        v = word(off) - WORLD_BASE
        if not 0 <= v < len(d):
            raise ValueError("pointer at %#x leaves the area file" % off)
        return v

    descriptor = ptr(0)
    directory = ptr(ptr(descriptor + 0x0C))
    selectors = ptr(directory + 0x08)
    count = word(selectors)
    if not 1 <= count <= 255:
        raise ValueError("implausible encounter count %d in this area" % count)
    stats_table = ptr(directory + 0x0C)
    out = []
    for index in range(1, count + 1):
        enc = ptr(selectors + 4 * index)
        positions = ptr(ptr(enc + 0x14))
        roster = list(d[enc + 4:enc + 10])
        slots = []
        for k, enemy_id in enumerate(roster):
            if not enemy_id:
                slots.append(None)
                continue
            t = struct.unpack_from("<3h", d, positions + 6 * k)
            stats = ptr(stats_table + 4 * enemy_id)
            flags = struct.unpack_from("<H", d, stats + 0x26)[0]
            slots.append((enemy_id,
                          (t[0] - 128, t[1], t[2] - (10 if flags & 0x20 else 0))))
        out.append(dict(index=index, offset=enc, positions=positions,
                        roster=roster, slots=slots))
    return out


# --- the engine's own camera transform ------------------------------------
# `0x800E0824` is the routine that turns an actor's world position into a screen
# position, and it says exactly how:
#
#   v0 = A[i][0x68] >> 12 ; v0 = A[i][0x6C] >> 12 ; v0 = A[i][0x70] >> 12
#   GTE RTPS( sp+0x10, sp+0x18, sp+0x20, sp+0x24 )       # world -> screen
#   s0 = A[i][0x84]
#   [s0+0x0C] = v0                                       # the projected depth
#   scale_y = (scene[0x1288] << 10) / scene[0x1284]      # <-- PERSPECTIVE SCALE
#   scale_x = (scene[0x128c] << 10) / scene[0x1284]
#   [s0+0x0E] = scale_y ; [s0+0x10] = scale_x
#   x = (A[i][0x78] * scale_x >> 12) + projected_x + scene[0x132C]   # + SCROLL
#   [s0+0x08] = (old & 7) | ((x & 0x1FFF) << 3)          # packed 13-bit X
#   ... same for y from A[i][0x79], projected_y, scene[0x132E]
#
# So an actor is drawn at the projection of its world position, offset by the
# SCROLL, and sized by the camera's constant `(D[0] << 10) / C[2]` -- NOT by
# 1/depth, which is what this comment claimed before 2026-10-06 and what made the
# mock scale the two sides differently.
#
# The battle state machine `0x80104808` calls the camera setter
# `0x800F6110(block, frames)` with two blocks of its own:
#   state 0 (0x8010486C): 0x8016D6BC, 60 frames
#   state 1 (0x801048E8): 0x8016D77C, 60 frames
# Their values, and the projection law, are documented at the top of this file;
# `battle_camera()` reads them out of MAIN.EXE rather than repeating them.
# NO SIZE TRIM. `0x800E0824` stores `scale = (scene[0x1288] << 10) / scene[0x1284]`
# in the sprite object's +0x0E/+0x10 and the renderer multiplies the sprite's OWN
# pixels by it, so the drawn size is `sprite_pixels * (D[0] << 10) / C[2] / 4096`:
# 1.1875 on state 0, 0.9375 on state 1, 1.0 on the field. There used to be a
# `SPRITE_SIZE_TRIM = 0.55` here, a fudge left over from the 16x camera error --
# it drew the whole battle at about half size. Measured against the reference
# screenshots, removing it is what makes a party member ~51 px tall, as in the
# game, instead of ~28.


# --- the BATTLE ground tileset -------------------------------------------
# The battle does NOT use the world map's pages (that was the user's correction).
# `game_state[0x1BB4] = *(descriptor + 0x0C)` is the battle's resource table
# (`0x80128600`), and its table's FIRST entry is a directory whose own entry 0 is
# the terrain atlas: a 128x128 8-bit page holding an 8x8 grid of 16x16 tiles,
# with a 256-colour palette at a per-section d-table. Index 0 is transparent.
#
# Verified for six areas (E, F, A, Z, H, G): entry 0 is always that terrain
# atlas, and it is never one of the five pages at `S+0x08` -- which is why the
# earlier mock, built on `S+0x08`, was showing world-map art on the battlefield.
WORLD_BASE = 0x80080000


def battle_ground_atlas(d, entry=0, palette=0):
    """(raw, palette words, meta) for a 128x128 page in the battle's directory.

    `entry` 0 is the ground tileset (an 8x8 grid of 16x16 terrain tiles) and
    entry 1 is the scenery atlas (trees/shrubs, 14 colour variants). Both are
    reached the way the game reaches them: `game_state[0x1BB4] =
    *(descriptor+0x0C)` at `0x80128600`, then the table's first entry is this
    directory. Neither is one of the five pages at `S+0x08`.
    """
    import struct as _s
    n = len(d)
    to_file = lambda p: (p - WORLD_BASE) if (p and 0 <= p - WORLD_BASE < n) else None
    Dp = to_file(_s.unpack_from("<I", d, 0)[0])
    if Dp is None:
        return None
    tbl = to_file(_s.unpack_from("<I", d, Dp + 0x0C)[0])
    if tbl is None:
        return None
    dirp = to_file(_s.unpack_from("<I", d, tbl)[0])
    if dirp is None:
        return None
    t = to_file(_s.unpack_from("<I", d, dirp + 4 * entry)[0])
    if t is None or t + 0x10 > n:
        return None
    c_count, d_flags = d[t + 4], d[t + 5]
    a_count, b_count = _s.unpack_from("<HH", d, t)
    ct = to_file(_s.unpack_from("<I", d, t + 0x08)[0])
    dt = to_file(_s.unpack_from("<I", d, t + 0x0C)[0])
    ft = to_file(_s.unpack_from("<I", d, t + 0x14)[0])
    if ct is None or dt is None:
        return None
    # EVERY c-entry is a 128x128 page, and they CONCATENATE into the tile bank:
    # C has c_count = 2 and its tilemap's values run to exactly 31, i.e. 2 pages x
    # 16 tiles. Tiles are 32x32 (a 4x4 grid per page), which is what the map's
    # 0..15-per-page values require -- reading them as 8x8 16x16 tiles puts two
    # thirds of every field on the bank's blank filler.
    pages = []
    for ci in range(max(1, c_count)):
        cp = to_file(_s.unpack_from("<I", d, ct + 4 * ci)[0])
        if cp is None or cp + 8 > n:
            break
        ln = _s.unpack_from("<I", d, cp)[0]
        if not (0 < ln < n - cp - 4):
            break
        try:
            raw = lzss.decode_strict(d[cp + 4:cp + 4 + ln])
        except Exception:
            break
        if len(raw) != 16384:
            break
        pages.append(raw)
    if not pages:
        return None
    raw = pages[0]
    # THE PALETTES ARE POINTERS, NOT INLINE WORDS. Reading the d-table as colour
    # words is what made the ground look like noise: the table at `d_table` holds
    # `d_count` RAM pointers, one per palette; the palette SIZE comes from the
    # flags (0x80 => 32 words, else 256), not from the pointer spacing.
    d_count = max(1, d_flags & 0x3F)
    ptrs = []
    for pi in range(d_count):
        if dt + 4 * pi + 4 > n:
            break
        po = to_file(_s.unpack_from("<I", d, dt + 4 * pi)[0])
        if po is not None:
            ptrs.append(po)
    if not ptrs:
        return None
    # The palette size comes from the flags, the same convention the enemy
    # sections use: bit 0x80 => 32-word (4-bit) palettes, otherwise 256-word
    # (8-bit). The pointer SPACING is not reliable -- area F's ground has gaps of
    # both 512 and 2048 bytes -- so it is not used.
    stride = 32 if (d_flags & 0x80) else 256
    pi = min(palette, len(ptrs) - 1)
    po = ptrs[pi]
    if po + 2 * stride > n:
        return None
    pal = [_s.unpack_from("<H", d, po + 2 * k)[0] for k in range(stride)]
    # f_table (+0x14) is the TILEMAP: `a` x `b` u16 tile indices (the header's
    # a/b are 16/16 for every ground section, and f_table is exactly a*b*2 = 512
    # bytes). That is what places the bank's 16x16 tiles on the battlefield --
    # tiling the raw 8x8 bank page instead is what made the ground look like a
    # mess.
    tilemap = None
    if ft is not None and a_count and b_count and ft + 2 * a_count * b_count <= n:
        tilemap = [_s.unpack_from("<H", d, ft + 2 * k)[0]
                   for k in range(a_count * b_count)]
    return pages, pal, (t, c_count, d_flags, pi, a_count, b_count, tilemap)


# --- the engine's own actor layout ----------------------------------------
# `0x800DECE0` ff. is the placement loop, and it is explicit:
#
#   800dece0  lh   $2, 0x0($23)          ; the formation entry's x
#   800dece8  lw   $3, 0xb80c($3)        ; [0x8016B80C] = the side origin x
#   800decf4  addu $2, $2, $3            ; x = entry.x + side origin x
#   800decf8  sll  $2, $2, 12            ; << 12  (12.12 fixed point)
#   800decfc  sw   $2, 0x68($16)         ; actor[0x68] = world X
#   ... and the same shape for Y (origin [0x8016B810]) and Z ([0x8016B814]).
#
# --- battle formation data, MAIN.EXE 0x8016B81C ---------------------------
# 10 slots x (s16 x, y, z), plus the side origins at 0x8016B80C (=+128, 0) and
# 0x8016B814 (=-128, 0). The table serves BOTH the field follow formation and
# the standard battle party spawn; the two spawn readers are `party_world_positions`
# (MAIN.EXE `0x800DEBE8`) and `area_encounters` (the area's own enemy table).
# The table's own values are quoted in battle_actor_handlers.md.
FORMATION_TABLE = 0x8016B81C
SIDE_ORIGIN_POS = 0x8016B80C       # (+128, 0)  the party side
SIDE_ORIGIN_NEG = 0x8016B814       # (-128, 0)  the enemy side


def mainexe_image():
    """MAIN.EXE's headerless image at base 0x800C0800."""
    import disc
    import json as _json
    with open(os.path.join(_KIT, "extracted", "iso_files.json")) as listing:
        recs = {x["path"]: x for x in _json.load(listing) if not x.get("dir")}
    r = recs["MAIN.EXE"]
    return disc.extract(r["lba"], r["size"])[2048:]


def enemy_pose(d, section, atlas_index=0, row=None, col=None):
    """One enemy pose, cropped on the e-record's cell size.

    An AREA enemy section's e-table is an array of `a_e_count` 32-bit RAM pointers
    to 16-byte records; the first record's **bytes 2 and 3 are the pose cell's
    width and height**, and bytes 12-13 are `(W-1, H-1)`, which is what confirms
    the reading. Cross-checked against each atlas's own empty-column pitch:

        area A enemy 0   bytes 2-3 = 0x20 0x20 (32, 32)   pitch 32
        area A enemy 2   bytes 2-3 = 0x28 0x28 (40, 40)   pitch 40
        area A enemy 3   bytes 2-3 = 0x40 0x40 (64, 64)   pitch 64
        area E enemy 0   bytes 2-3 = 0x28 0x40 (40, 64)   pitch 40

    Cropping the cell avoids the packing problem: adjacent poses TOUCH, so the
    old connected-component crop drew two monsters as one (area A's slime came out
    as a pair). `row`/`col` override the default, which is the densest cell.
    """
    import numpy as np
    off = section["e_table"]
    n = section["a_e_count"]
    if not n:
        return None
    cell_w = cell_h = None
    for k in range(n):
        ptr = struct.unpack_from("<I", d, off + 4 * k)[0]
        o = ptr - WORLD_BASE
        if not 0 <= o <= len(d) - 16:
            continue
        w, h = d[o + 2], d[o + 3]
        # bytes 12-13 must be (W-1, H-1); that is the corroboration that pins the
        # reading, and it also rejects the records whose first two fields are not a
        # cell size. W need not divide 128 -- area E's enemy 0 is 40 wide, i.e.
        # three cells across with 8 columns unused.
        if 8 <= w <= 128 and 8 <= h <= 128 and (d[o + 12], d[o + 13]) == (w - 1, h - 1):
            cell_w, cell_h = w, h
            break
    if cell_w is None:
        return None
    atlases = section["atlases"]
    if not atlases:
        return None
    raw = atlases[min(atlas_index, len(atlases) - 1)]["atlas"]
    a = np.frombuffer(raw, dtype=np.uint8).reshape(128, 128)
    pal = section["palettes"][0]
    pal = [tuple(c) if isinstance(c, (tuple, list)) else rgb555(c) for c in pal]
    cols, rows = max(1, 128 // cell_w), max(1, 128 // cell_h)

    def cell(r, c):
        m = a[r * cell_h:(r + 1) * cell_h, c * cell_w:(c + 1) * cell_w]
        ys, xs = np.nonzero(m)
        if not len(ys):
            return None
        # tight-cropped for the same reason as `party_pose`: area E's enemy 2 has
        # 7 rows of empty cell below its feet, and anchoring the CELL floats it
        y0, y1, x0, x1 = int(ys.min()), int(ys.max()), int(xs.min()), int(xs.max())
        img = Image.new("RGBA", (x1 - x0 + 1, y1 - y0 + 1))
        px = img.load()
        for y, x in zip(ys, xs):
            idx = int(m[y, x])
            if idx < len(pal):
                px[x - x0, y - y0] = pal[idx] + (255,)
        return img

    rs = range(rows) if row is None else [row % rows]
    cs = range(cols) if col is None else [col % cols]
    best, best_n = None, -1
    for r in rs:
        for c in cs:
            m = a[r * cell_h:(r + 1) * cell_h, c * cell_w:(c + 1) * cell_w]
            cnt = int((m != 0).sum())
            if cnt > best_n:
                best, best_n = cell(r, c), cnt
    return best


def shadow(canvas, cx, base_y, w):
    """The flat dark ellipse the PARTY stands on -- and only the party.

    THE ENEMIES DO NOT GET ONE. Both PSX references agree: in the slime battle the
    three slimes sit on bare ground with no shadow, and a tight zoom on the orange
    humanoid enemy shows its boots directly on the dirt (the dark patches around it
    are terrain, with dirt texture visible through them). The party, zoomed the
    same way, stands on an unmistakable flat ellipse roughly 1.7x its own width.

    Why is not decoded. The actor draw loop runs party actors 1..`scene[0x1C]` and
    then the enemies to `scene[0x24]`, so a shadow emitted only in the party branch
    would produce exactly this; the party sheets also carry effect-like cells that
    the enemy sheets do not. Until one of those is pinned, the party-only split is
    read off the references and is a labelled choice.

    Size is read off the reference too: the ellipse is about 1.7x the character's
    width and a third as tall, centred on the feet.
    """
    rx = max(8, int(w * 0.85))
    ry = max(4, int(rx * 0.30))
    ov = Image.new("RGBA", (rx * 2 + 2, ry * 2 + 2), (0, 0, 0, 0))
    dr = ImageDraw.Draw(ov)
    dr.ellipse((1, 1, rx * 2, ry * 2), fill=(0, 0, 0, 170))
    canvas.paste(ov, (int(cx - rx), int(base_y - ry)), ov)

def blend_dither(tex, factor=2):
    """Box-downsample a page to undo the source's ORDERED DITHER.

    The ground pages are dithered on purpose -- 8-bit confirmed, 4-bit readings
    are worse -- and the PS1's composite output blended that into smooth tones.
    A raw framebuffer does not, which is why the ground reads as speckle here and
    looked smooth on a TV. This is a DISPLAY APPROXIMATION, not a decode: it is
    applied to the texture, and the flag `--no-smooth` turns it off to see the
    raw art.
    """
    w, h = tex.size
    return tex.resize((max(1, w // factor), max(1, h // factor)),
                      Image.BOX)


GROUND_QUADS = 16           # the floor is 16x16 quads over a 17x17 vertex grid
GROUND_SPAN = 1024.0        # world units across the whole grid (the two 0x400s)
GROUND_EDGE_PAD = 64.0      # the builder's extra -0x40, i.e. half a tile
# No placeholder left in the ground path: the grid size, the span, the padding,
# the height field and the tilemap are all read from the area file, and the
# projection is the engine's own camera. The one thing NOT reproduced is the
# engine's per-quad SHADE (see `render_ground`).


def battle_ground_mesh(d):
    """`(vertices, across, down, tiles)` for the battle floor, from the area file.

    Every number here comes out of MAIN.EXE and the area DATA file:

      0x800DE6A0  jal 0x800E79E8      upload directory[0], the GROUND TILESET
      0x800DE6B0  a3 = 0x400          X span 1024
      0x800DE6A8  [sp+0x10] = 0x400   Y span 1024
      0x800DE6D8  directory[4]        the HEIGHT MAP (`0x8017C100` + 0x10)
      0x800DE6E4  jal 0x800E7784      build the vertex grid

    and `0x800E7784` fills it with a 16-byte record per vertex:

      800e7830  sh   $t1, 0x0($a0)    vertex+0 = X
      800e7834  sh   $t3,-0x2($v1)    vertex+2 = Y
      800e783c  lhu  $v0, 0x0($t2)    read the height map
      800e784c  sh   $v0, 0x0($v1)    vertex+4 = Z   <-- the HEIGHT, not zero

    So the floor is a HEIGHT FIELD, not a plane, and the Z comes straight from
    `directory[4]` with no `<< 12`: it is already in the same world units as X
    and Y. The grid is 17x17 vertices at step `span/16 = 64`, starting at
    `-span/2 - 0x40 = -576`, i.e. X and Y in [-576, +448] -- a 1024-unit patch
    whose CENTRE is (-64, -64) and not the origin.

    Dimensions and the tilemap come from the ground section's own header
    (`a`, `b`, `c_count`, `d_flags`) and its `+0x14` table. Area E's section is at
    file 0x16404 with `10 00 10 00 01 06` = 16x16 tiles, one page, flags 6, and
    its height map at 0x1BF74 is 289 `s16` in [-24, +16].

    Returns `(verts, a, b, tiles)` with `verts` row-major `(x, y, z)` and `tiles`
    the `a*b` cell indices into the concatenated 32x32 tile bank.
    """
    n = len(d)

    def u(off):
        if not 0 <= off <= n - 4:
            raise ValueError("word outside the area file at %#x" % off)
        return struct.unpack_from("<I", d, off)[0]

    def ptr(off):
        v = u(off) - WORLD_BASE
        if not 0 <= v < n:
            raise ValueError("pointer at %#x leaves the area file" % off)
        return v

    directory = ptr(ptr(ptr(0) + 0x0C))
    section = ptr(directory)                 # directory[0] = the ground tileset
    height = ptr(directory + 0x10)           # directory[4] = the height map
    a, b, c_count, d_flags = struct.unpack_from("<hhBB", d, section)
    if not (1 <= a <= 64 and 1 <= b <= 64):
        raise ValueError("implausible ground grid %dx%d" % (a, b))
    tiles = list(struct.unpack_from("<%dH" % (a * b), d, ptr(section + 0x14)))
    step_x = GROUND_SPAN / float(a)
    step_y = GROUND_SPAN / float(b)
    start_x = -GROUND_SPAN / 2.0 - GROUND_EDGE_PAD
    start_y = -GROUND_SPAN / 2.0 - GROUND_EDGE_PAD
    verts = []
    for row in range(b + 1):
        for col in range(a + 1):
            # the builder reads the height map SEQUENTIALLY, so the index is
            # row-major over the (a+1) x (b+1) vertex grid
            z = struct.unpack_from(
                "<h", d, height + 2 * (row * (a + 1) + col))[0]
            # the engine stores these as s16, so they are integers
            verts.append((int(round(start_x + col * step_x)),
                          int(round(start_y + row * step_y)), int(z)))
    return verts, a, b, tiles


def render_ground(terrain, verts, across, down, tiles, size=SCREEN,
                  state=BATTLE_CAM_STATE, H=PROJ_H, screen_offset=(0, 0)):
    """Rasterize the battle floor the way `0x800E7DC0` does: textured QUADS.

    `0x800E7DC0` projects the 17x17 vertex grid with RTPS in one pass, then in a
    second pass emits one quad per cell -- 16x16 of them -- taking each cell's
    page, CLUT and UV from the section's tilemap and adding the scene scroll to
    the projected corners.

    This rasterizes the same quads with perspective-correct UVs (interpolating
    `1/w`, `u/w` and `v/w` across each triangle, which is what the hardware's
    interpolators do) and a depth buffer, so the height field self-occludes
    correctly.

    NOT REPRODUCED: the engine's per-quad flat SHADE. `0x800E7FD4` calls
    `0x8014FB44` with the four corner heights, and that routine is a GTE
    normal-colour (NCDS-family) operation whose light matrix and far colour are
    set up by `0x8014EA50`; neither is decoded, so the terrain is drawn UNLIT
    here rather than with an invented light.
    """
    import numpy as np
    w, h = size
    src = np.asarray(terrain.convert("RGB"), dtype=np.uint8)
    sw, sh = terrain.size
    cell_x = sw / float(across)
    cell_y = sh / float(down)
    out = np.zeros((h, w, 3), dtype=np.uint8)
    zbuf = np.zeros((h, w), dtype=np.float64)     # 1/depth: larger is nearer
    filled = np.zeros((h, w), dtype=bool)

    projected = [project_point(v, state, H, size) for v in verts]
    projected = [(p[0] + screen_offset[0], p[1] + screen_offset[1], p[2]) if p else None for p in projected]

    def tri(p, uv):
        """Rasterize one triangle with `p` = [(sx, sy, depth)] and `uv` per corner."""
        if any(q is None or q[2] <= 1.0 for q in p):
            return
        (x0, y0, d0), (x1, y1, d1), (x2, y2, d2) = p
        minx = max(0, int(min(x0, x1, x2)))
        maxx = min(w - 1, int(max(x0, x1, x2)) + 1)
        miny = max(0, int(min(y0, y1, y2)))
        maxy = min(h - 1, int(max(y0, y1, y2)) + 1)
        if minx > maxx or miny > maxy:
            return
        det = ((y1 - y2) * (x0 - x2) + (x2 - x1) * (y0 - y2))
        if abs(det) < 1e-9:
            return
        xs = np.arange(minx, maxx + 1) + 0.5
        ys = np.arange(miny, maxy + 1) + 0.5
        gx, gy = np.meshgrid(xs, ys)
        l0 = ((y1 - y2) * (gx - x2) + (x2 - x1) * (gy - y2)) / det
        l1 = ((y2 - y0) * (gx - x2) + (x0 - x2) * (gy - y2)) / det
        l2 = 1.0 - l0 - l1
        inside = (l0 >= -1e-6) & (l1 >= -1e-6) & (l2 >= -1e-6)
        if not inside.any():
            return
        iw = l0 / d0 + l1 / d1 + l2 / d2
        with np.errstate(divide="ignore", invalid="ignore"):
            u = (l0 * uv[0][0] / d0 + l1 * uv[1][0] / d1
                 + l2 * uv[2][0] / d2) / iw
            v = (l0 * uv[0][1] / d0 + l1 * uv[1][1] / d1
                 + l2 * uv[2][1] / d2) / iw
        iu = np.clip(u.astype(np.int64), 0, sw - 1)
        iv = np.clip(v.astype(np.int64), 0, sh - 1)
        sub = (slice(miny, maxy + 1), slice(minx, maxx + 1))
        nearer = inside & (iw > zbuf[sub])
        if not nearer.any():
            return
        colours = src[iv[nearer], iu[nearer]]
        block = out[sub]
        block[nearer] = colours
        zbuf[sub][nearer] = iw[nearer]
        filled[sub] |= nearer

    for row in range(down):
        for col in range(across):
            tile = tiles[row * across + col] if row * across + col < len(tiles) else 0
            page, in_page = tile // 16, tile % 16
            # the tilemap indexes the CONCATENATED bank: 16 tiles per page, laid
            # out 4x4 within a page (`0x800E7C88` U = (tile & 0xf) * 32). The
            # assembled atlas in build() already concatenates the pages, so a cell
            # maps straight to its 32-pixel rect there.
            u0, v0 = col * cell_x, row * cell_y
            u1, v1 = (col + 1) * cell_x, (row + 1) * cell_y
            c00 = projected[row * (across + 1) + col]
            c10 = projected[row * (across + 1) + col + 1]
            c11 = projected[(row + 1) * (across + 1) + col + 1]
            c01 = projected[(row + 1) * (across + 1) + col]
            tri([c00, c10, c11], [(u0, v0), (u1, v0), (u1, v1)])
            tri([c00, c11, c01], [(u0, v0), (u1, v1), (u0, v1)])
    return Image.fromarray(out, "RGB"), Image.fromarray(
        (filled * 255).astype(np.uint8), "L")


def bm_blocks():
    """The keys of every battle camera block, for a CLI `choices=` list."""
    return sorted(BATTLE_CAM_BLOCKS)


def build(area_path, page_index=1, enemy_index=None, ground_page=0,
          backdrop_page=1, smooth=True, encounter_index=1,
          pose_row=None, pose_col=None, cam=None):
    state = BATTLE_CAM_STATE if cam is None else cam
    r = disc_path(area_path)
    d = disc.extract(r["lba"], r["size"])
    sections, _err = es.parse_sections(d)
    tables = es.find_enemy_tables(d, sections)
    bg = es.parse_background(d)
    if bg is None or not bg["pages"]:
        raise SystemExit("no battle background descriptor in %s" % area_path)

    def page_image(i):
        pg = bg["pages"][min(i, len(bg["pages"]) - 1)]
        im = Image.new("RGB", (128, 128))
        pal = [rgb555(w) for w in bg["cluts"][0]["words"]]
        q = im.load()
        for k, idx in enumerate(pg["atlas"]):
            q[k % 128, k // 128] = pal[idx]
        return im

    # The five pages are DISTINCT textures, not five copies of one tileset:
    # rendered with CLUT 0 (the only correct palette -- see
    # enemy_sprites.md 4), area F's page 1 is dense foliage and its
    # page 0 is sand/dirt. That is exactly the user's two PSX references: a
    # TERRAIN ground and a separate FOLIAGE/rock backdrop band. The default
    # pairing below is therefore ground=0, backdrop=1; which page serves which
    # role per area is NOT decoded, so it is an option and it is labelled.
    # THE GROUND IS THE BATTLE'S OWN TILESET, not the world map's pages. The
    # battle's resource table is `game_state[0x1BB4] = *(descriptor+0x0C)`
    # (`0x80128600`); its first entry is a directory whose entry 0 is a 128x128
    # 8-bit page holding an 8x8 grid of 16x16 terrain tiles with a 256-colour
    # palette. Verified for six areas (E, F, A, Z, H, G). The five pages at
    # `S+0x08` are world-map art -- using them on the battlefield was wrong.
    bga = battle_ground_atlas(d)
    tilemap, AW, BH = None, 0, 0
    if bga is not None:
        pages, bpal, meta = bga
        pr = [rgb555(w) for w in bpal]
        # index 0 is a REAL colour in a ground page (the palettes start at
        # black), so nothing is skipped.
        banks = []
        for raw in pages:
            im = Image.new("RGB", (128, 128))
            q = im.load()
            for k, idx in enumerate(raw):
                q[k % 128, k // 128] = pr[idx]
            banks.append(im)
        tilemap = meta[6]
        AW, BH = meta[4], meta[5]
        if tilemap and AW and BH:
            # f_table is the TILEMAP: AW x BH cells, each a tile index into the
            # concatenated 32x32 bank (16 tiles per page). This is the field's own
            # ground texture; tiling the raw bank page instead is what made it a
            # mess.
            terrain = Image.new("RGB", (AW * 32, BH * 32))
            for j, v in enumerate(tilemap):
                pg, ti = v // 16, v % 16
                if pg >= len(banks):
                    continue
                sx, sy = (ti % 4) * 32, (ti // 4) * 32
                terrain.paste(banks[pg].crop((sx, sy, sx + 32, sy + 32)),
                              ((j % BH) * 32, (j // BH) * 32))

            if smooth:
                terrain = blend_dither(terrain, 2)
            ground_src = ("battle ground @%#07x: %dx%d tilemap of 32px tiles over "
                          "%d page(s), palette %d/%d%s"
                          % (meta[0], AW, BH, len(banks), meta[3], meta[2] & 0x3F,
                             ", dither blended" if smooth else ", raw dither"))
        else:
            terrain = banks[0]
            ground_src = "battle ground bank @%#07x (no tilemap)" % meta[0]
    else:
        terrain = page_image(ground_page)
        ground_src = "world-map page %d (FALLBACK -- no battle tileset found)" % ground_page
    # THERE IS NO BACKDROP. `0x800E09BC` emits exactly one geometry builder before
    # the actors, MAIN.EXE contains no GP0/GP1 port writes at all, and all 47
    # ordering-table emitters are ground / actor pieces / UI / menu primitives -- so
    # there is no sky quad to draw and nothing is invented to fill the gap. The
    # band above the horizon is the FAR CELLS OF THE FLOOR GRID (area F raises them
    # by up to 106 units and paints them as rock). `directory[1]`, the scenery
    # atlas, is not a background either: `0x800DF144` places its entries as ACTORS
    # at `scene+0xFD8` with 12.12 positions; that placement is not modelled yet.
    backdrop = None
    bmask = None
    backdrop_src = ("none (MAIN has no backdrop; scenery is placed as actors by "
                    "0x800DF144, not modelled)")
    # The battle floor is the engine's own geometry: the area's ground tileset
    # through its own 16x16 tilemap, on a 16x16 QUAD grid over a 17x17 vertex
    # grid carrying a per-vertex HEIGHT FIELD. See battle_ground_mesh.md.
    # There is no separate backdrop layer -- see the note above -- and the terrain
    # is drawn UNLIT because the engine's per-quad GTE NCDS at 0x8014FB44 is not
    # decoded.
    # THE FLOOR: the engine's own height field, rasterized as its 16x16 quads.
    mesh = battle_ground_mesh(d)
    if mesh is not None and tilemap and AW and BH:
        verts, gw, gh, gtiles = mesh
        ground, gmask = render_ground(terrain, verts, gw, gh, gtiles,
                                      state=state)
    else:
        ground = terrain.convert("RGB").resize(SCREEN)
        gmask = Image.new("L", SCREEN, 255)
    # NO BACKDROP. `0x800E09BC` emits exactly one geometry builder before the
    # actors, MAIN.EXE contains no GP0/GP1 port writes at all (a scan for
    # 0x1F801810/0x1F801814/0x1F8010A0/0x1F8010A8 returns zero hits), and all 47
    # ordering-table emitters are ground, actor pieces, UI or menu primitives --
    # so there is no sky quad to draw and nothing is invented to fill the gap.
    # The scenery atlas (`directory[1]`) is NOT a background either: `0x800DF144`
    # places its entries as ACTORS at `scene+0xFD8` with 12.12 positions taken
    # from the records themselves. That placement is not modelled yet.
    canvas = Image.new("RGB", SCREEN, (0, 0, 0))
    canvas.paste(ground, (0, 0), gmask)

    # The area's enemy art, keyed by ENEMY ID -- not by position in a list.
    #
    # `0x800DEF20` indexes the stats table by the roster byte: `enemy_id` selects
    # `stats_table + 4*enemy_id` (`0x800DEF20`/`0x800DEF28`), and that pointer is
    # exactly the enemy table's record number `enemy_id - 1`. Verified for area E:
    # ids 1-4 resolve to file 0x1EC7C / 0x2240C / 0x20C4C / 0x25608, the table's
    # records 0-3 in order. Zipping the art against the ROSTER instead of keying it
    # by id drew one distinct enemy per slot, so a party of three identical
    # monsters came out as three different ones -- the stats labels gave it away.
    enemy_art = {}
    for t in tables[:1]:
        for idx, (so, ro) in enumerate(zip(t["section_offsets"],
                                          t["record_offsets"])):
            if enemy_index is not None and idx != enemy_index:
                continue
            sec = next(s for s in sections if s["header_offset"] == so)
            img = enemy_pose(d, sec)
            if img is not None:
                enemy_art[idx] = {"image": img, "stat": enemy_stat_line(d, ro),
                                  "roster_index": idx}
    # THE PLACEMENT IS NOW THE ENGINE'S OWN, and none of it is a reconstruction.
    #
    # Party: `0x800DEBE8` (MAIN.EXE), six spawns at table 0x8016B81C entries 1-6
    # plus the (+128, 0) origin. See `party_world_positions`.
    PARTY_SLOTS = party_world_positions()
    # Enemies: `0x800DEE44`, positions = *(*(encounter + 0x14)), six ROSTER SLOTS
    # of which a zero id leaves a FORMATION GAP -- the offset still advances by 6
    # per slot, so the later enemies are not pulled forward. The encounter is
    # selected by `game_state[0x1BC0]`, which is a MODE-DEPENDENT index and is not
    # statically known here, so it is `encounter_index` and its value is printed.
    encounters = area_encounters(d)
    encounter_index = min(max(encounter_index, 1), len(encounters))
    enc = encounters[encounter_index - 1]
    ENEMY_ROSTER = enc["roster"]
    # one entry per roster slot as (enemy_id, world), gaps included as None, so
    # the formation keeps its shape AND each slot can pick its own art
    ENEMY_SLOTS = list(enc["slots"])

    # The earlier reading -- "the table at 0x8016B81C is the FIELD follow
    # formation, and the battle's layout is a separate resource selected through
    # 0x8016F258" -- was WRONG, and so was excluding `scene+0x1348`. Mode 3
    # reaches 0x800DDF98 (`0x800C9A74` `slti` falls through to `j 0x800C9ABC`),
    # which calls these spawns at 0x800DE7FC/0x800DE804, and 0x800DEEB4 does the
    # second dereference that makes `scene+0x1348` the ENEMY position table. The
    # area's 12-triple run is two ADJACENT ALTERNATIVE ENEMY formations, not a
    # party half and an enemy half. Kept as an error record.

    def place(world):
        """world -> (screen_x, screen_y_feet, pixel_scale), or None if behind."""
        pr = project_point(world, state=state, H=PROJ_H, size=SCREEN)
        if pr is None:
            return None
        sx, sy, depth = pr
        return (sx + SCROLL[0], sy + SCROLL[1], depth)

    # The engine's size law, once per camera: `(D[0] << 10) / C[2]` as a Q12
    # multiplier on the sprite's own pixels. NOT 1/depth.
    REL = battle_scale_q12(state) / 4096.0

    enemy_at = []
    enemy_drawn = []
    for slot in ENEMY_SLOTS:
        # walk the SLOTS, not a list: the slot carries the ENEMY ID that picks the
        # art, and a gap stays a gap, exactly as 0x800DF114 leaves it.
        if slot is None:
            continue
        enemy_id, wp = slot
        item = enemy_art.get(enemy_id - 1)
        if item is None:
            continue
        img = item["image"]
        pl = place(wp)
        if pl is None:
            continue
        sx, sy, depth = pl
        rel = REL
        w = max(1, int(img.width * rel))
        h = max(1, int(img.height * rel))
        ex, ey = int(sx - w / 2), int(sy - h)
        # NO shadow for an enemy -- see `shadow()`
        canvas.paste(img.resize((w, h), Image.NEAREST), (ex, ey),
                     img.resize((w, h), Image.NEAREST))
        enemy_at.append((ex, ey, w, h))
        enemy_drawn.append(item)

    # party: the six resident characters, S1.c[1], drawn far-to-near so the nearer
    # column overlaps the further one
    party_imgs = []
    for ch, sec, bi in PARTY:
        img = party_pose(ch, sec, bi, row=pose_row, col=pose_col)
        if img is not None:
            party_imgs.append((ch, img))
    order = sorted(range(len(party_imgs)),
                   key=lambda i: project_point(PARTY_SLOTS[i], state=state)[2]
                   if i < len(PARTY_SLOTS)
                   and project_point(PARTY_SLOTS[i], state=state)
                   else 0.0, reverse=True)
    party_at = []
    for i in order:
        ch, img = party_imgs[i]
        wp = PARTY_SLOTS[i] if i < len(PARTY_SLOTS) else PARTY_SLOTS[-1]
        pl = place(wp)
        if pl is None:
            continue
        sx, sy, depth = pl
        rel = REL
        w = max(1, int(img.width * rel))
        h = max(1, int(img.height * rel))
        ex, ey = int(sx - w / 2), int(sy - h)
        shadow(canvas, sx, sy, w)
        canvas.paste(img.resize((w, h), Image.NEAREST), (ex, ey),
                     img.resize((w, h), Image.NEAREST))
        party_at.append((ch, ex, ey, w, h))

    dr = ImageDraw.Draw(canvas)
    for item, (ex, ey, w, h) in zip(enemy_drawn, enemy_at):
        lvl, _footprint, hp = item["stat"]
        ly = ey + h + 2
        if ly > SCREEN[1] - 30:
            ly = ey - 10
        dr.text((ex, ly), "L%d HP%d" % (lvl, hp),
                fill=(255, 235, 150))
    for ch, lx, ly, _w, h in party_at:
        ty = ly + h + 2
        if ty > SCREEN[1] - 30:
            ty = ly - 10
        dr.text((lx, ty), character_name(ch)[:5], fill=(160, 220, 255))
    dr.rectangle([0, 0, SCREEN[0] - 1, 11], fill=(0, 0, 0))
    dr.text((3, 1), "camera + spawns + floor = MAIN.EXE/area data | no backdrop in MAIN",
            fill=(255, 210, 90))
    dr.rectangle([0, SCREEN[1] - 24, SCREEN[0] - 1, SCREEN[1] - 1],
                 fill=(0, 0, 0))
    dr.text((3, SCREEN[1] - 23),
            "area %s | ground = %s | backdrop = %s"
            % (tag_of(area_path), ground_src, backdrop_src),
            fill=(255, 200, 140))
    dr.text((3, SCREEN[1] - 12),
            "encounter %d roster %s | party 6 from 0x8016B81C | %d/%d sheets "
            "| floor %dx%d quads, pitch %.0f | cam %d"
            % (encounter_index, ENEMY_ROSTER, len(enemy_drawn), len(party_imgs),
               GROUND_QUADS, GROUND_QUADS, GROUND_SPAN / GROUND_QUADS,
               state),
            fill=(150, 150, 165))
    return canvas


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--area", default="DATA/08_AREA.E/E_DATA.BIN")
    ap.add_argument("--page", type=int, default=1)
    ap.add_argument("--enemy", type=int, default=None,
                    help="feature only this roster entry (0-based)")
    ap.add_argument("--all-enemies", action="store_true",
                    help="one image per roster entry")
    ap.add_argument("--all-encounters", action="store_true",
                    help="one image per encounter descriptor in the area, i.e. "
                         "one per possible standard battle")
    ap.add_argument("--strongest", action="store_true",
                    help="one image of the highest-level entry per roster (HP breaks ties)")
    ap.add_argument("--out", default=os.path.join(_KIT, "work", "battle_mock"))
    ap.add_argument("--no-smooth", dest="smooth", action="store_false",
                    help="show the raw ordered dither instead of the blended "
                         "approximation of the PS1's composite output")
    ap.add_argument("--cam", type=int, default=None, choices=sorted(bm_blocks()),
                    help="which battle camera block to use -- all five are on "
                         "disc and which state a settled battle rests in is not "
                         "decoded, so this is the caller's call")
    ap.add_argument("--pose-row", type=int, default=None,
                    help="party pose cell row in the 04_PLAY sheet (default: the "
                         "densest cell; pose selection is not decoded)")
    ap.add_argument("--pose-col", type=int, default=None,
                    help="party pose cell column in the 04_PLAY sheet")
    ap.add_argument("--encounter", type=int, default=1,
                    help="which of the area's encounter descriptors to use; this "
                         "is `game_state[0x1BC0]`, mode-dependent and not "
                         "statically known, so it defaults to 1")
    args = ap.parse_args(argv)
    os.makedirs(args.out, exist_ok=True)
    tag = tag_of(args.area)
    if args.strongest:
        r = disc_path(args.area)
        d = disc.extract(r["lba"], r["size"])
        sections, _e = es.parse_sections(d)
        tables = es.find_enemy_tables(d, sections)
        made = 0
        for t in tables[:1]:
            strong = es.strongest_entries(d, [t], sections)
            for e in strong:
                try:
                    idx = t["section_offsets"].index(e["section"])
                except ValueError:
                    continue
                img = build(args.area, args.page, enemy_index=idx, smooth=args.smooth,
                      encounter_index=args.encounter, cam=args.cam,
                      pose_row=args.pose_row, pose_col=args.pose_col)
                path = os.path.join(
                    args.out, "battle_mock_%s_strongest%d.png" % (tag, idx))
                img.resize((SCREEN[0] * 2, SCREEN[1] * 2),
                           Image.NEAREST).save(path)
                print("wrote %s" % path)
                made += 1
        if not made:
            print("no highest-level entry in %s" % args.area)
        return 0
    if args.all_encounters:
        r = disc_path(args.area)
        d = disc.extract(r["lba"], r["size"])
        n = len(area_encounters(d))
        for i in range(1, n + 1):
            img = build(args.area, args.page, enemy_index=args.enemy,
                        smooth=args.smooth, encounter_index=i, cam=args.cam)
            path = os.path.join(
                args.out, "battle_mock_%s_enc%02d.png" % (tag, i))
            img.resize((SCREEN[0] * 2, SCREEN[1] * 2), Image.NEAREST).save(path)
            print("wrote %s" % path)
        return 0
    if args.all_enemies:
        r = disc_path(args.area)
        d = disc.extract(r["lba"], r["size"])
        sections, _e = es.parse_sections(d)
        tables = es.find_enemy_tables(d, sections)
        n = tables[0]["count"] if tables else 1
        for i in range(n):
            img = build(args.area, args.page, enemy_index=i, smooth=args.smooth,
                      encounter_index=args.encounter, cam=args.cam,
                      pose_row=args.pose_row, pose_col=args.pose_col)
            path = os.path.join(args.out, "battle_mock_%s_e%d.png" % (tag, i))
            img.resize((SCREEN[0] * 2, SCREEN[1] * 2), Image.NEAREST).save(path)
            print("wrote %s" % path)
        return 0
    img = build(args.area, args.page, enemy_index=args.enemy,
                smooth=args.smooth, encounter_index=args.encounter, cam=args.cam,
                      pose_row=args.pose_row, pose_col=args.pose_col)
    path = os.path.join(args.out, "battle_mock_%s.png" % tag)
    img.resize((SCREEN[0] * 2, SCREEN[1] * 2), Image.NEAREST).save(path)
    print("wrote %s" % path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

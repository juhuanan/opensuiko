#!/usr/bin/env python3
"""Tests for kit/tools/battle_mock.py -- the battle scene composition mock.

    1. `largest_component` returns a crop no larger than the atlas and reports
       one component, and an all-zero plane returns None rather than an image;
    2. the crop really is a subset of the source: every non-transparent pixel
       of the crop matches a non-zero index pixel of the atlas;
    3. `party_sheet` resolves all six resident characters and each returns an
       atlas of exactly 16,384 bytes plus a 32-entry palette -- the property the
       'no palette guess' claim in the doc rests on;
    4. `build` produces a 320x240 image for an area, and its first enemy comes
       from that area's roster table rather than from an arbitrary section.

Requires a disc. Static analysis only.

    .venv/bin/python kit/tests/test_battle_mock.py
"""

import os
import sys

TOOLS = os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "tools"))
sys.path.insert(0, TOOLS)

import numpy as np                              # noqa: E402
import battle_mock as bm                        # noqa: E402
import enemy_sprites as es                      # noqa: E402

AREA = "DATA/08_AREA.E/E_DATA.BIN"


def test_largest_component_shapes():
    atlas = np.zeros((128, 128), np.uint8)
    atlas[10:20, 30:40] = 5          # 100 px component
    atlas[100:104, 100:104] = 7      # 16 px component
    img = bm.largest_component(atlas.tobytes(), [(0, 0, 0)] + [(9, 9, 9)] * 31)
    assert img is not None
    assert (img.width, img.height) == (10, 10), (img.width, img.height)
    blank = bm.largest_component(bytes(128 * 128), [(0, 0, 0)] * 32)
    assert blank is None


def test_crop_is_a_subset_of_the_source():
    atlas = np.zeros((128, 128), np.uint8)
    atlas[5:25, 5:25] = 3
    img = bm.largest_component(atlas.tobytes(), [(0, 0, 0)] + [(1, 2, 3)] * 31)
    px = img.load()
    opaque = sum(1 for y in range(img.height) for x in range(img.width)
                 if px[x, y][3])
    assert opaque == 400, opaque


def test_party_sheets_resolve_and_are_16384_bytes():
    """Each entry is (character, resident SECTION, blob index).

    SHU and GRE are resident as S2.c[0] only, so asking for S1.c[1] for them is
    a different sheet than the capture showed -- this asserts the pairing the
    corrected residency doc states.
    """
    assert len(bm.PARTY) == 6
    for ch, sec, bi in bm.PARTY:
        assert sec in ("S1", "S2"), (ch, sec)
        raw, pal = bm.party_sheet(ch, sec, bi)
        assert len(raw) == es.ATLAS, (ch, len(raw))
        assert len(pal) == 32, (ch, len(pal))
        assert max(raw) < len(pal), (ch, max(raw))
    assert ("VIC", "S1", 1) in bm.PARTY, "the VA1-embedded character is VIC"
    for ch in ("SHU", "GRE"):
        assert (ch, "S2", 0) in bm.PARTY, ch


def test_build_produces_a_screen_and_uses_the_roster():
    img = bm.build(AREA, page_index=1)
    assert img.size == bm.SCREEN, img.size
    r = bm.disc_path(AREA)
    import disc
    d = disc.extract(r["lba"], r["size"])
    sections, _e = es.parse_sections(d)
    tables = es.find_enemy_tables(d, sections)
    assert tables, "area E has no roster table"
    # every roster section resolves inside this file
    for so in tables[0]["section_offsets"]:
        assert any(s["header_offset"] == so for s in sections)


def test_spawns_put_the_party_bottom_right_and_enemies_upper_left():
    """The layout the reference screenshots show, now DERIVED rather than asserted.

    Project the six party spawns (`party_world_positions`, MAIN.EXE `0x800DEBE8`)
    and area E's encounter-1 enemy spawns (`area_encounters`, MAIN.EXE `0x800DEE44`
    over `positions = *(*(encounter+0x14))`) through the camera the engine builds
    (`battle_camera`) on the state-1 block. The party must sit right of centre and
    below it, the enemies left of centre and above it, and all of them inside the
    320x240 frame.

    CORRECTION 2026-10-06: this test used to check a hand-written
    `to_screen(x, y)` linear map over the raw formation table, because the real
    transform had not been decoded. The map is gone and so is the guess it
    encoded.
    """
    import json as _json
    sys.path.insert(0, os.path.join(bm._KIT, "tools"))
    import disc
    party = bm.party_world_positions()
    assert party == [(120, 50, 0), (112, 0, 0), (120, -50, 0),
                     (192, 75, 0), (178, 25, 0), (178, -25, 0)], party
    for p in party:
        pr = bm.project_point(p)
        assert pr is not None, p
        assert pr[0] > bm.SCREEN[0] / 2.0, (p, pr)
        assert pr[1] > bm.SCREEN[1] / 2.0, (p, pr)
        assert 0 <= pr[1] < bm.SCREEN[1], (p, pr)
    # KNOWN OPEN ITEM, pinned so it cannot be quietly forgotten: under block 2 --
    # the camera the state machine actually settles on -- the party's sixth member
    # projects PAST the 320px right edge (x ~325). The reference does not show
    # that, so the scroll (`scene[0x132C]`, which accumulates the camera sweep) must
    # be non-zero once the battle settles. When that is derived this assertion
    # should move to `0 <= pr[0] < SCREEN[0]`.
    outside = [p for p in party if not 0 <= bm.project_point(p)[0] < bm.SCREEN[0]]
    assert len(outside) == 1 and outside[0] == (178, -25, 0), outside
    # NOT a uniform rectangle: the two columns are staggered and each column's
    # three members differ in depth. Do not "tidy" these into a grid.
    xs = sorted({p[0] for p in party})
    assert xs == [112, 120, 178, 192], xs
    assert len({p[1] for p in party}) == 6, party

    with open(os.path.join(bm._KIT, "extracted", "iso_files.json")) as fh:
        recs = {x["path"]: x for x in _json.load(fh) if not x.get("dir")}
    r = recs["DATA/08_AREA.E/E_DATA.BIN"]
    d = disc.extract(r["lba"], r["size"])
    enc = bm.area_encounters(d)[0]
    assert enc["roster"] == [3, 3, 3, 1, 0, 0], enc["roster"]
    placed = 0
    for slot in enc["slots"]:
        if slot is None:
            continue
        pr = bm.project_point(slot[1])
        assert pr is not None, slot
        assert pr[0] < bm.SCREEN[0] / 2.0, (slot, pr)
        assert pr[1] < bm.SCREEN[1] / 2.0 + 1.0, (slot, pr)
        placed += 1
    assert placed == 4, placed
    # a zero roster id leaves a GAP: the position offset still advances by 6
    # (0x800DF114), so slots 4 and 5 stay empty rather than collapsing
    assert enc["slots"][4] is None and enc["slots"][5] is None


def test_the_five_pages_are_distinct_textures():
    """`S+0x08`'s five pages are five DIFFERENT textures, not five copies.

    This is what makes "page 1 is the foliage backdrop, page 0 is the ground" a
    statement about the disc rather than about one page reused. Asserted over
    every area data file with a descriptor.
    """
    import json as _json
    import disc as _disc
    import enemy_sprites as _es
    with open(os.path.join(bm._KIT, "extracted", "iso_files.json")) as f:
        recs = {x["path"]: x for x in _json.load(f) if not x.get("dir")}
    checked = 0
    for name in sorted(n for n in recs if n.endswith("_DATA.BIN")):
        r = recs[name]
        d = _disc.extract(r["lba"], r["size"])
        if len(d) < 8:
            continue
        bg = _es.parse_background(d)
        if not bg or len(bg["pages"]) != 5:
            continue
        sigs = {bytes(p["atlas"]) for p in bg["pages"]}
        assert len(sigs) == 5, (name, len(sigs))
        # CLUT 0 is the only correct palette; assert it exists for them
        assert bg["cluts"], name
        checked += 1
    assert checked >= 10, checked

def test_battle_floor_is_the_engines_height_field_grid():
    """The floor is NOT a plane and NOT the world map.

    `0x800DE6B0`/`0x800DE6A8` pass `0x400` for the X and Y span, `0x800DE6D8` reads
    `directory[4]` as a HEIGHT MAP, and `0x800E7784` builds a 17x17 vertex grid at
    step 64 starting at -576 -- storing `X` at +0, `Y` at +2 and the height map's
    `s16` at +4 (`0x800E783C` reads it, `0x800E784C` writes it). `0x800E7DC0`
    then emits 16x16 textured quads over those vertices.

    So the extent, the spacing, the tilemap AND a per-vertex Z all come from the
    area file. Area F's height map is a ramp from -114 to +92, which is what makes
    its far edge read as an elevated backdrop; area E's only spans -24..+16.
    """
    import json as _json
    sys.path.insert(0, os.path.join(bm._KIT, "tools"))
    import disc
    with open(os.path.join(bm._KIT, "extracted", "iso_files.json")) as fh:
        recs = {x["path"]: x for x in _json.load(fh) if not x.get("dir")}

    def load(name):
        r = recs[name]
        return disc.extract(r["lba"], r["size"])

    assert bm.GROUND_QUADS == 16
    assert bm.GROUND_SPAN == 1024.0
    assert bm.GROUND_EDGE_PAD == 64.0
    for name, lo, hi in (("DATA/08_AREA.E/E_DATA.BIN", -24, 16),
                         ("DATA/09_AREA.F/F_DATA.BIN", -150, 106),
                         ("DATA/01_AREA.A/A_DATA.BIN", -24, 16)):
        d = load(name)
        verts, across, down, tiles = bm.battle_ground_mesh(d)
        assert (across, down) == (16, 16), (name, across, down)
        assert len(verts) == 17 * 17, (name, len(verts))
        assert len(tiles) == 16 * 16, (name, len(tiles))
        xs = sorted({v[0] for v in verts})
        ys = sorted({v[1] for v in verts})
        assert xs[0] == -576 and xs[-1] == 448, (name, xs[0], xs[-1])
        assert ys[0] == -576 and ys[-1] == 448, (name, ys[0], ys[-1])
        assert len(xs) == 17 and len(ys) == 17
        assert xs[1] - xs[0] == 64, "step 64 = span 1024 / 16"
        zs = [v[2] for v in verts]
        assert (min(zs), max(zs)) == (lo, hi), (name, min(zs), max(zs))
        assert any(z != 0 for z in zs), "the floor is a height field, not a plane"
    # area A's height map is byte-identical to area E's -- a real property of the
    # disc, not a copy bug, and worth pinning so a future read notices
    e = bm.battle_ground_mesh(load("DATA/08_AREA.E/E_DATA.BIN"))[0]
    a = bm.battle_ground_mesh(load("DATA/01_AREA.A/A_DATA.BIN"))[0]
    assert e == a, "areas E and A share a height map"
    # and the render really consumes it: a mesh whose Z is flattened must project
    # to different pixels, or the height field is being ignored
    verts, gw, gh, tiles = bm.battle_ground_mesh(load("DATA/09_AREA.F/F_DATA.BIN"))
    flat = [(x, y, 0) for (x, y, _z) in verts]
    assert [bm.project_point(v)[1] for v in verts] != \
           [bm.project_point(v)[1] for v in flat], "Z must reach the projection"


def test_the_eye_is_above_the_floor_and_looks_down_at_it():
    """Inverting `view = R*v + TR` at view = 0 gives the eye.

    World -Z is up, so the eye must have z NEGATIVE -- it is above the floor --
    and the state-1 block puts it at (713, 528, -366): 366 units up, looking down
    about 25 degrees at the world origin. This is the check that would catch an
    axis convention flipped anywhere in the camera path.
    """
    for state, distance in ((0, 329.0), (1, 416.6)):
        eye = bm.camera_world_position(state)
        assert eye[2] < 0, (state, eye)
        assert abs(abs(eye[2]) - distance) < 2.0, (state, eye)
        assert eye[0] > 0 and eye[1] > 0, (state, eye)
    # the origin projects to the frame centre, because OFX/OFY are 0 and the eye
    # looks straight at it
    origin = bm.project_point((0, 0, 0))
    assert origin is not None
    assert abs(origin[0] - bm.SCREEN[0] / 2.0) < 1.5, origin
    assert abs(origin[1] - bm.SCREEN[1] / 2.0) < 1.5, origin
    # a point further from the camera in the view direction is drawn higher
    near = bm.project_point((120, 50, 0))
    far = bm.project_point((-88, 0, 0))
    assert far[2] > near[2], (near, far)
    assert far[1] < near[1], (near, far)


def test_poses_are_cropped_on_the_e_record_cell_not_a_connected_blob():
    """The sheets are PACKED, so `largest_component` merges touching poses.

    The e-record carries the pose cell size. For 04_PLAY, `parse_04play` reads it
    (`CRE` `(32, 64)`, `SHU`/`GRE` `(24, 48)`) and the atlas's own empty-column
    pitch agrees: CRE's profile repeats every 32, SHU's and GRE's every 24.

    For AREA enemy sections the e-table is an array of RAM pointers to 16-byte
    records, and the record's **bytes 2-3 are `(W, H)`** with bytes 12-13 as
    `(W-1, H-1)`. Each of these was cross-checked against that atlas's own
    empty-column pitch, which is why the reading is trusted:

        area A enemy 0  (32, 32)  pitch 32
        area A enemy 2  (40, 40)  pitch 40
        area A enemy 3  (64, 64)  pitch 64
        area E enemy 0  (40, 64)  pitch 40

    The bug this guards: KAM was drawn as TWO characters side by side, and area
    A's single slime as two slimes, because the crop was the biggest blob.
    """
    import json as _json
    sys.path.insert(0, os.path.join(bm._KIT, "tools"))
    import disc
    import enemy_sprites as _es
    with open(os.path.join(bm._KIT, "extracted", "iso_files.json")) as fh:
        recs = {x["path"]: x for x in _json.load(fh) if not x.get("dir")}

    def load(name):
        r = recs[name]
        return disc.extract(r["lba"], r["size"])

    # the 04_PLAY cell sizes come from each character's first e-record
    assert bm._party_cell_size("CRE") == (32, 64)
    assert bm._party_cell_size("KAM") == (32, 64)
    assert bm._party_cell_size("SHU", "S2") == (24, 48)
    assert bm._party_cell_size("GRE", "S2") == (24, 48)
    for ch, sec, bi in bm.PARTY:
        img = bm.party_pose(ch, sec, bi)
        assert img is not None, ch
        cw, chh = bm._party_cell_size(ch, sec)
        # the pose is TIGHT-CROPPED inside its cell, so that the sprite's bottom
        # edge is the character's feet and not the cell's padding
        assert img.width <= cw and img.height <= chh, (ch, img.size, (cw, chh))
        # and it must not be the cell's full height unless the content fills it
        assert img.height >= chh - 16, (ch, img.size)
        # the old blob crop went WIDER than the cell for the merged ones
        raw, pal = bm.party_sheet(ch, sec, bi)
        blob = bm.largest_component(raw, pal, min_px=24)
        if ch in ("KAM", "VIC"):
            assert img.width < blob.width, (ch, img.size, blob.size)

    d = load("DATA/08_AREA.E/E_DATA.BIN")
    sections, _e = _es.parse_sections(d)
    table = _es.find_enemy_tables(d, sections)[0]
    want = {0: (40, 64), 1: (64, 64), 2: (64, 64), 3: (64, 64)}
    for idx, (so, _ro) in enumerate(zip(table["section_offsets"],
                                        table["record_offsets"])):
        sec = next(x for x in sections if x["header_offset"] == so)
        ptr = int.from_bytes(d[sec["e_table"]:sec["e_table"] + 4], "little")
        o = ptr - 0x80080000
        assert (d[o + 2], d[o + 3]) == want[idx], (idx, d[o + 2], d[o + 3])
        # bytes 12-13 corroborate the reading and are not used by the crop
        assert (d[o + 12], d[o + 13]) == (d[o + 2] - 1, d[o + 3] - 1)
        img = bm.enemy_pose(d, sec)
        assert img is not None, idx
        assert img.width <= want[idx][0] and img.height <= want[idx][1]
        assert img.width >= 8 and img.height >= 8, (idx, img.size)
    # area A's slime is ONE 32x32 cell, not a merged pair
    da = load("DATA/01_AREA.A/A_DATA.BIN")
    sa, _e = _es.parse_sections(da)
    ta = _es.find_enemy_tables(da, sa)[0]
    sec = next(x for x in sa if x["header_offset"] == ta["section_offsets"][0])
    slime = bm.enemy_pose(da, sec)
    assert slime.width <= 32 and slime.height <= 32


def test_every_battle_camera_block_is_enumerated_and_orthonormal():
    """The battle installs FIVE camera blocks, not two.

    Found by scanning MAIN for `lui/addiu a0,<block> ; jal 0x800F6110` and keeping
    the call sites inside the battle state machine `0x80104808` and the battle
    driver `0x800F64F0`:

        0x8016D6BC @0x8010488C  pos (80,0,0)   ang (-768,0,608)  D 4864
        0x8016D77C @0x80104900  pos (112,0,0)  ang (-768,0,608)  D 3840
        0x8016D7AC @0x80104A94  pos (112,0,0)  ang (-768,0,352)  D 3840
        0x8016D80C @0x80105458  pos (-160,0,0) ang (-768,0,352)  D 5120
        0x8016B878 @0x800F6BD0  pos (0,0,0)    ang (-768,0,608)  D 4096

    States 2-4 RE-YAW the camera from 608 to 352, so block 1 is not necessarily
    the settled battle -- which is why `--cam` exists rather than a guess.
    """
    assert sorted(bm.BATTLE_CAM_BLOCKS) == [0, 1, 2, 3, 4]
    assert bm.BATTLE_CAM_STATE == 2, "the state machine's last install"
    want = {0: ([80, 0, 0], [-768, 0, 608], 4864),
            1: ([112, 0, 0], [-768, 0, 608], 3840),
            2: ([112, 0, 0], [-768, 0, 352], 3840),
            3: ([-160, 0, 0], [-768, 0, 352], 5120),
            4: ([0, 0, 0], [-768, 0, 608], 4096)}
    for k, (pos, ang, d) in want.items():
        b = bm.camera_block(k)
        assert b[0:3] == pos, (k, b[0:3])
        assert b[3:6] == ang, (k, b[3:6])
        assert b[9] == d and b[6:9] == [0, 0, 1024], (k, b[6:12])
        assert bm.battle_scale_q12(k) == d * 1024 // 1024
        # every block must give an orthonormal det +1 rotation
        m = bm.rot_matrix(b[3:6])
        rows = [[m[r * 3 + c] / 4096.0 for c in range(3)] for r in range(3)]
        for row in rows:
            assert abs(sum(v * v for v in row) ** 0.5 - 1.0) < 0.005, (k, rows)
    # blocks 2 and 3 share a yaw and differ in position, so they are not aliases
    assert bm.camera_block(2)[0:6] != bm.camera_block(3)[0:6]
    # and the alternate yaw really moves the scene: the same encounter projects to
    # different pixels under block 1 and block 2
    enc = None
    a1 = bm.project_point((120, 50, 0), 1)
    a2 = bm.project_point((120, 50, 0), 2)
    assert abs(a1[0] - a2[0]) > 20, (a1, a2)


def test_poses_are_grounded_and_only_the_party_gets_a_shadow():
    """Two things the reference screenshots settled.

    GROUNDING: a pose cell has empty rows below the feet (CRE 5, KAM 4, SHU/GRE 3,
    area E's enemy 2 seven), so anchoring the CELL's bottom edge at the projected
    point floats the character by that much. `party_pose`/`enemy_pose` tight-crop to
    the opaque content, so the drawn sprite's bottom row IS the feet.

    SHADOW: only the PARTY has one. In the reference the three slimes sit on bare
    ground and the orange humanoid enemy's boots sit directly on the dirt, while a
    party member stands on a flat dark ellipse about 1.7x its own width. So the
    enemy path must not draw one.
    """
    import json as _json
    sys.path.insert(0, os.path.join(bm._KIT, "tools"))
    import disc
    import enemy_sprites as _es
    import inspect
    import numpy as _np
    with open(os.path.join(bm._KIT, "extracted", "iso_files.json")) as fh:
        recs = {x["path"]: x for x in _json.load(fh) if not x.get("dir")}

    # every pose is tight: the bottom row has content, and the left/right edges too
    for ch, sec, bi in bm.PARTY:
        img = bm.party_pose(ch, sec, bi)
        a = _np.asarray(img)[:, :, 3] != 0
        assert a[-1].any(), ("bottom row empty", ch)
        assert a[:, 0].any() and a[:, -1].any(), ("side column empty", ch)
        assert a[0].any(), ("top row empty", ch)

    # and the cell really did have padding to remove, or the crop proves nothing
    padding = {}
    for ch, sec, bi in bm.PARTY:
        img = bm.party_pose(ch, sec, bi)
        padding[ch] = bm._party_cell_size(ch, sec)[1] - img.height
    assert max(padding.values()) >= 3, padding

    # the enemy source must not call shadow(); the party source must
    src = inspect.getsource(bm.build)
    enemy_part = src[src.index("enemy_at = []"):src.index("party_imgs = []")]
    party_part = src[src.index("party_imgs = []"):]
    assert "shadow(canvas" not in enemy_part, "enemies must not get a shadow"
    assert "shadow(canvas" in party_part, "the party must get a shadow"

    # the slime sheet carries no ellipse piece to draw even if we wanted one
    da = _disc_load(recs, "DATA/01_AREA.A/A_DATA.BIN")
    sa, _e = _es.parse_sections(da)
    ta = _es.find_enemy_tables(da, sa)[0]
    sec = next(x for x in sa if x["header_offset"] == ta["section_offsets"][0])
    assert bm.enemy_pose(da, sec) is not None


def _disc_load(recs, name):
    import disc
    r = recs[name]
    return disc.extract(r["lba"], r["size"])


def test_sprites_are_drawn_at_the_engines_size_with_no_trim():
    """`0x800E0824` stores `(D[0] << 10) / C[2]` and the renderer multiplies the
    sprite's OWN pixels by it -- there is no size fudge factor.

    `SPRITE_SIZE_TRIM = 0.55` lived here and drew the whole battle at about half
    size; it was a fudge from the 16x camera error. Against the reference
    screenshots, removing it is what makes a party member ~51 px tall, as in the
    game, instead of ~28. Assert the trim is gone and the only factor is the
    camera's.
    """
    assert not hasattr(bm, "SPRITE_SIZE_TRIM")
    assert bm.battle_scale_q12(1) / 4096.0 == 0.9375
    assert bm.battle_scale_q12(0) / 4096.0 == 1.1875
    # a party pose cell drawn at the state-1 scale is the size the reference shows
    cw, chh = bm._party_cell_size("CRE")
    assert (cw * 0.9375, chh * 0.9375) == (30.0, 60.0)
    assert 45 <= chh * 0.9375 <= 65, "a party member is roughly 50 px tall"


def test_sprite_scale_is_the_cameras_constant_not_one_over_depth():
    """`0x800E0824` computes `(D[0] << 10) / C[2]` ONCE per frame and stores it in
    the sprite's +0x0E/+0x10. There is no depth term in it, so both sides are
    drawn the same size -- which is why the reference frames show a party member
    at the same scale as the monster it is farther from.

    CORRECTION 2026-10-06: an earlier revision of the mock claimed `1/depth` and
    this test asserted the proportionality. It is wrong and the assertion is
    replaced. The RATIOS recorded before (1.1875 / 0.9375 / 1.0 against the
    field's 1.0) were always right; both operands were 16x too small, and they
    cancel in this particular formula.
    """
    assert bm.battle_scale_q12(0) == 4864
    assert bm.battle_scale_q12(1) == 3840
    assert bm.battle_scale_q12(0) / 4096.0 == 1.1875
    assert bm.battle_scale_q12(1) / 4096.0 == 0.9375
    for state in sorted(bm.BATTLE_CAM_BLOCKS):
        b = bm.camera_block(state)
        assert bm.battle_scale_q12(state) == (b[9] << 10) // b[8], state
    # the same law on the FIELD's default block gives exactly 1.0
    import struct as _s
    im = bm.mainexe_image()
    field = [_s.unpack_from("<i", im, 0x8016B7DC - 0x800C0800 + 4 * i)[0] >> 12
             for i in range(12)]
    assert field[3:6] == [-768, 0, 640], field
    assert (field[9] << 10) // field[8] == 4096
    # and the size really is independent of depth: the law takes no depth at all
    import inspect
    assert list(inspect.signature(bm.battle_scale_q12).parameters) == ["state"]
    assert inspect.signature(bm.project_point).parameters["H"].default == bm.PROJ_H


def test_no_duplicate_top_level_definitions_in_battle_mock():
    """A source-level guard, because this bit three times.

    Successive edits inserted a rewritten `perspective_ground`/`shadow` while an
    older copy remained below it, so the module silently kept USING THE STALE
    FUNCTION -- and one of those stale renders was read as a successful result
    before it was caught. Assert one definition per name.
    """
    import collections
    import re
    path = os.path.join(bm._KIT, "tools", "battle_mock.py")
    with open(path) as f:
        src = f.read()
    names = collections.Counter(re.findall(r"^def ([A-Za-z_][A-Za-z0-9_]*)",
                                           src, re.M))
    dupes = {n: c for n, c in names.items() if c > 1}
    assert not dupes, dupes

def test_battle_palette_table_is_pointers_not_inline_words():
    """Reading the d-table as inline colour words is what made the ground noise.

    The d-table holds `d_count` RAM POINTERS, one per palette, and the spacing
    between them gives the palette size. Asserted structurally: the pointers must
    be in-file, strictly increasing and evenly spaced. Reading them as colours
    fails all three.
    """
    import struct
    import json as _json
    sys.path.insert(0, os.path.join(bm._KIT, "tools"))
    import disc
    with open(os.path.join(bm._KIT, "extracted", "iso_files.json")) as fh:
        recs = {x["path"]: x for x in _json.load(fh) if not x.get("dir")}
    checked = 0
    for name in ("DATA/01_AREA.A/A_DATA.BIN", "DATA/08_AREA.E/E_DATA.BIN",
                 "DATA/09_AREA.F/F_DATA.BIN", "DATA/11_AREA.H/H_DATA.BIN"):
        r = recs[name]
        d = disc.extract(r["lba"], r["size"])
        n = len(d)
        W = bm.WORLD_BASE
        to_file = lambda p: (p - W) if (p and 0 <= p - W < n) else None
        Dp = to_file(struct.unpack_from("<I", d, 0)[0])
        tbl = to_file(struct.unpack_from("<I", d, Dp + 0x0C)[0])
        dirp = to_file(struct.unpack_from("<I", d, tbl)[0])
        for entry in (0, 1):
            t = to_file(struct.unpack_from("<I", d, dirp + 4 * entry)[0])
            if t is None:
                continue
            dt = to_file(struct.unpack_from("<I", d, t + 0x0C)[0])
            dc = d[t + 5] & 0x3F
            ptrs = [to_file(struct.unpack_from("<I", d, dt + 4 * k)[0])
                    for k in range(dc)]
            ptrs = [p for p in ptrs if p is not None]
            if len(ptrs) < 2:
                continue
            # The catch for the "read as colours" bug is that real entries are
            # monotone in-file RAM pointers; colour words are neither, and land
            # in the thousands. Spacing is NOT asserted: area F's ground has gaps
            # of both 512 and 2048 bytes, so the size comes from the flags.
            assert ptrs == sorted(ptrs), (name, entry, ptrs[:4])
            assert all(p < n for p in ptrs), (name, entry)
            assert all(0 < p for p in ptrs), (name, entry)
            checked += 1
    assert checked >= 4, checked

def test_ground_tilemap_indexes_a_32px_bank_of_all_pages():
    """The tilemap must land inside the bank, on real tiles.

    Two wrong readings are excluded by construction here, and both were real:
      * reading the map's values as 8x8 16x16 tiles puts ~66% of every field on
        the bank's blank filler (area E: 0.660 mean index-0 fraction);
      * ignoring that `c_count` pages concatenate leaves map values out of range
        (area C's map runs to exactly 31, i.e. 2 pages x 16 tiles).
    With 32x32 tiles over all pages every cell lands in range, and the share of
    cells landing on a blank (>50% index 0) tile is zero.
    """
    import struct
    import json as _json
    sys.path.insert(0, os.path.join(bm._KIT, "tools"))
    import disc
    with open(os.path.join(bm._KIT, "extracted", "iso_files.json")) as fh:
        recs = {x["path"]: x for x in _json.load(fh) if not x.get("dir")}
    checked = 0
    for name in ("DATA/01_AREA.A/A_DATA.BIN", "DATA/02_AREA.B/B_DATA.BIN",
                 "DATA/06_AREA.C/C_DATA.BIN", "DATA/07_AREA.D/D_DATA.BIN",
                 "DATA/08_AREA.E/E_DATA.BIN", "DATA/09_AREA.F/F_DATA.BIN",
                 "DATA/10_AREA.G/G_DATA.BIN", "DATA/11_AREA.H/H_DATA.BIN"):
        r = recs[name]
        d = disc.extract(r["lba"], r["size"])
        got = bm.battle_ground_atlas(d)
        if got is None:
            continue
        pages, pal, meta = got
        _t, c_count, _flags, _pi, a_count, b_count, tilemap = meta
        if not tilemap:
            continue
        assert a_count == 16 and b_count == 16, (name, a_count, b_count)
        assert len(tilemap) == a_count * b_count
        # every value must address a real 32x32 tile in the concatenated bank
        assert max(tilemap) < len(pages) * 16, (name, max(tilemap), len(pages))
        blank = 0
        for v in tilemap:
            raw = pages[v // 16]
            ti = v % 16
            tx, ty = (ti % 4) * 32, (ti // 4) * 32
            px = [raw[yy * 128 + xx]
                  for yy in range(ty, ty + 32) for xx in range(tx, tx + 32)]
            if sum(1 for x in px if x == 0) / len(px) > 0.5:
                blank += 1
        assert blank == 0, (name, blank, len(tilemap))
        checked += 1
    assert checked >= 6, checked

def test_dither_blend_halves_and_smooths_but_is_opt_out():
    """The ground pages carry an ordered dither on purpose.

    A raw framebuffer shows it as speckle; the PS1's composite output blended it.
    `blend_dither` is the display approximation, so it must (a) halve the
    dimensions and (b) reduce the per-pixel variance, and (c) be switchable off
    so the raw art stays inspectable.
    """
    import random
    from PIL import Image as _Image
    random.seed(7)
    src = _Image.new("RGB", (64, 64))
    q = src.load()
    for y in range(64):
        for x in range(64):
            v = 255 if (x + y) % 2 else 0        # a hard checkerboard "dither"
            q[x, y] = (v, v, v)
    out = bm.blend_dither(src, 2)
    assert out.size == (32, 32), out.size

    def var(im):
        px = list(im.convert("L").getdata())
        m = sum(px) / len(px)
        return sum((p - m) ** 2 for p in px) / len(px)
    assert var(out) < var(src) / 10.0, (var(out), var(src))
    # and it is opt-out, not unconditional
    import inspect
    assert inspect.signature(bm.build).parameters["smooth"].default is True

def test_camera_angle_unit_is_the_12_bit_turn_from_the_code():
    """`0x8014FCB4` masks each camera angle with 0x0FFF and indexes the
    (s16 sin, s16 cos) PAIR table at 0x801725BC, so 0x1000 is a full turn and the
    table is the engine's own -- not `math.sin`.

    The table is read from MAIN.EXE, so these are disc bytes: the quarter turn is
    exactly (4096, 0) and the half turn exactly (0, -4096).
    """
    assert bm.sin_cos_lookup(0) == (0, 4096)
    assert bm.sin_cos_lookup(0x400) == (4096, 0)
    assert bm.sin_cos_lookup(0x800) == (0, -4096)
    # a negative angle takes the routine's OWN fold: it reads the table at
    # (-theta) & 0xFFF and negates the sine only, because cosine is even
    assert bm.sin_cos_lookup(-0x400) == (-4096, 0)
    assert bm.sin_cos_lookup(-0x800) == (0, -4096)
    # every angle the two battle blocks carry is a legal 12-bit turn
    for state in sorted(bm.BATTLE_CAM_BLOCKS):
        for a in bm.camera_block(state)[3:6]:
            assert -2048 <= a < 2048, a


def test_camera_angles_are_the_blocks_words_3_to_5():
    """`0x800E1518` calls `0x8014FCB4(scene+0x1276, ...)`, and `scene+0x1276` is
    filled from the block's words 3/4/5 by the three-iteration loop at
    `0x800E14C0`. So words 3/4/5 ARE the camera's three Euler angles.

    The values below are the CORRECTED ones. An earlier revision divided the
    block by 0x10000 instead of 0x1000 -- `raw >> 16` reproduces its (-48, 0, 38)
    exactly -- and so recorded a -4.22 degree pitch. The block is Q12 (`sra $2,$2,12`
    at `0x800E14C8`), so word 3 is -768 units = -67.5 degrees and the view is a
    normal 3/4 one. The retired names PITCH_UNITS / ROLL_UNITS / CAM_TR /
    GROUND_DROP / CAM_H / camera_basis() are gone; a positive angle turns the world.
    """
    assert bm.camera_block(0)[:6] == [80, 0, 0, -768, 0, 608]
    assert bm.camera_block(1)[:6] == [112, 0, 0, -768, 0, 608]
    assert bm.camera_block(0)[6:] == [0, 0, 1024, 4864, 4864, 4864]
    assert bm.camera_block(1)[6:] == [0, 0, 1024, 3840, 3840, 3840]
    assert abs(-768 / 4096.0 * 360.0 - (-67.5)) < 1e-9
    # the FALLBACK check that would have caught the 16x error: raw >> 16 gives the
    # wrong numbers and raw >> 12 gives these
    assert (-768 * 4096) >> 12 == -768, "the block is Q12"
    assert (-768 * 4096) >> 16 == -48, "and the old reading is a 16x misread of it"
    # the literal port of 0x8014FCB4: identity at zero, orthonormal det +1 else
    assert bm.rot_matrix((0, 0, 0)) == [4096, 0, 0, 0, 4096, 0, 0, 0, 4096]
    # A single exact quarter turn about each axis is a signed permutation, and the
    # SIGN is the convention: 0x8014FCB4 emits the WORLD->VIEW matrix, so angle 0
    # is Rx(-theta) here (the camera turns one way, the world appears to turn the
    # other). Pinning the sign is the point -- a flipped camera is otherwise easy
    # to mistake for a camera that works.
    assert bm.rot_matrix((0x400, 0, 0)) == [4096, 0, 0, 0, 0, -4096, 0, 4096, 0]
    assert bm.rot_matrix((-0x400, 0, 0)) == [4096, 0, 0, 0, 0, 4096, 0, -4096, 0]
    assert bm.rot_matrix((0, 0x400, 0)) == [0, 0, 4096, 0, 4096, 0, -4096, 0, 0]
    assert bm.rot_matrix((0, 0, 0x400)) == [0, -4096, 0, 4096, 0, 0, 0, 0, 4096]
    for state in (0, 1):
        m = bm.rot_matrix(bm.camera_block(state)[3:6])
        rows = [[m[r * 3 + c] / 4096.0 for c in range(3)] for r in range(3)]
        for row in rows:
            assert abs(sum(v * v for v in row) ** 0.5 - 1.0) < 0.005, (state, rows)
        det = (rows[0][0] * (rows[1][1] * rows[2][2] - rows[1][2] * rows[2][1])
               - rows[0][1] * (rows[1][0] * rows[2][2] - rows[1][2] * rows[2][0])
               + rows[0][2] * (rows[1][0] * rows[2][1] - rows[1][1] * rows[2][0]))
        assert abs(det - 1.0) < 0.01, (state, det)
    # ScaleMatrix multiplies each COLUMN by the matching D component
    assert bm.scale_matrix([4096, 0, 0, 0, 4096, 0, 0, 0, 4096], [2048, 4096, 8192]) \
        == [2048, 0, 0, 0, 4096, 0, 0, 0, 8192]


def test_enemy_art_is_keyed_by_the_roster_id_not_by_list_position():
    """`0x800DEF20` indexes the stats table by the roster byte: `enemy_id` selects
    `stats_table + 4*enemy_id`, which IS the enemy table's record `enemy_id - 1`.
    Verified for area E: ids 1-4 resolve to the table's records 0-3 in order.

    The bug this guards: the loaded art was a LIST zipped against the roster slots
    by position, so a party of three identical monsters drew three DIFFERENT ones
    (the stats labels gave it away) and a five-enemy encounter drew four.
    """
    import json as _json
    sys.path.insert(0, os.path.join(bm._KIT, "tools"))
    import disc
    import enemy_sprites as _es
    with open(os.path.join(bm._KIT, "extracted", "iso_files.json")) as fh:
        recs = {x["path"]: x for x in _json.load(fh) if not x.get("dir")}
    r = recs["DATA/08_AREA.E/E_DATA.BIN"]
    d = disc.extract(r["lba"], r["size"])

    def u(off):
        return int.from_bytes(d[off:off + 4], "little")

    def ptr(off):
        return u(off) - 0x80080000

    stats_table = ptr(ptr(ptr(ptr(0) + 12)) + 0x0C)
    sections, _e = _es.parse_sections(d)
    table = _es.find_enemy_tables(d, sections)[0]
    assert len(table["record_offsets"]) == 4
    for enemy_id in range(1, 5):
        assert ptr(stats_table + 4 * enemy_id) == table["record_offsets"][enemy_id - 1]
    stats = [bm.enemy_stat_line(d, off) for off in table["record_offsets"]]
    assert stats == [(38, 0, 350), (40, 1, 200), (37, 0, 300), (39, 1, 400)]

    encounter = bm.area_encounters(d)[10]
    assert encounter["roster"] == [3, 3, 3, 4, 4, 0]
    drawn = [stats[slot[0] - 1] for slot in encounter["slots"] if slot]
    assert drawn == [(37, 0, 300)] * 3 + [(39, 1, 400)] * 2, drawn
    # and a five-slot encounter really does yield five drawn actors, not four
    assert len(drawn) == 5
    # every encounter's roster must be addressable by id, or a slot silently
    # disappears from the render
    for enc in bm.area_encounters(d):
        for slot in enc["slots"]:
            assert slot is None or 1 <= slot[0] <= len(stats), (enc["index"], slot)


def test_area_encounters_are_a_pointer_chase_not_a_shape_scan():
    """`positions = *(*(encounter + 0x14))` -- the SECOND dereference at
    `0x800DEEB4`, published into `scene+0x1348` at `0x800DEEC0`.

    Missing it is why an earlier revision excluded `scene+0x1348` entirely and
    fell back to scanning the area file for a run of twelve triples that LOOKED
    like a formation. That run is real but it is two ADJACENT ALTERNATIVE ENEMY
    formations (area E: 0x15FE4 for encounters 1/9/10/11 and 0x16008 for 2-8), not
    a party half and an enemy half. Scanning for a shape cannot tell you which is
    which; chasing the pointer can.
    """
    import json as _json
    sys.path.insert(0, os.path.join(bm._KIT, "tools"))
    import disc
    with open(os.path.join(bm._KIT, "extracted", "iso_files.json")) as fh:
        recs = {x["path"]: x for x in _json.load(fh) if not x.get("dir")}

    def load(name):
        r = recs[name]
        return disc.extract(r["lba"], r["size"])

    d = load("DATA/08_AREA.E/E_DATA.BIN")

    def u(off):
        return int.from_bytes(d[off:off + 4], "little")

    def ptr(off):
        return u(off) - 0x80080000

    directory = ptr(ptr(ptr(0) + 12))
    selectors = ptr(directory + 8)
    assert (directory, selectors, u(selectors)) == (0x161b8, 0x16188, 11)
    encs = bm.area_encounters(d)
    assert len(encs) == 11
    for index, enc in enumerate(encs, 1):
        expected = 0x15FE4 if index in (1, 9, 10, 11) else 0x16008
        assert enc["positions"] == expected, (index, hex(enc["positions"]))
        # the standalone re-derivation in tests/test_battle_placement.py walks the
        # same chain with plain byte arithmetic; this cross-checks the producer
        assert ptr(ptr(ptr(selectors + 4 * index) + 20)) == expected
    first = encs[0]
    assert first["roster"] == [3, 3, 3, 1, 0, 0], first["roster"]
    assert [s[1] for s in first["slots"] if s] == \
        [(-88, 0, 0), (-88, -50, 0), (-88, 50, 0), (-168, 0, 0)]
    # the two formations are ADJACENT in the file, 36 bytes apart -- which is the
    # whole reason a shape scan found a 12-triple run
    assert 0x16008 - 0x15FE4 == 36
    # a roster id whose stats carry 0x20 is raised 10 world units, because world
    # -Z is up (`0x800DF054` subtracts 0xA000)
    raised = [s for e in encs for s in e["slots"] if s and s[1][2] == -10]
    assert raised, "no flying enemy found in area E"
    # pointer-chase coverage: the eight primary areas, 77 encounters / 18 tables
    total = 0
    positions = set()
    for directory_name, letter in [("01_AREA.A", "A"), ("02_AREA.B", "B"),
                                   ("06_AREA.C", "C"), ("07_AREA.D", "D"),
                                   ("08_AREA.E", "E"), ("09_AREA.F", "F"),
                                   ("10_AREA.G", "G"), ("11_AREA.H", "H")]:
        got = bm.area_encounters(load("DATA/%s/%s_DATA.BIN"
                                      % (directory_name, letter)))
        total += len(got)
        positions.update(e["positions"] for e in got)
        for e in got:
            # the descriptor's own count must agree with its nonzero roster bytes
            assert sum(1 for x in e["roster"] if x) == len(
                [s for s in e["slots"] if s]), (letter, e["roster"])
    assert (total, len(positions)) == (77, 18), (total, len(positions))


if __name__ == "__main__":
    tests = [(n, f) for n, f in sorted(globals().items())
             if n.startswith("test_") and callable(f)]
    failed = 0
    for name, fn in tests:
        try:
            fn()
        except Exception as ex:            # noqa: BLE001 - report all
            failed += 1
            print("FAIL %s: %s: %s" % (name, type(ex).__name__, ex))
        else:
            print("ok   %s" % name)
    print("\n%d passed, %d failed" % (len(tests) - failed, failed))
    sys.exit(1 if failed else 0)

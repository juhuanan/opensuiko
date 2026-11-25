#!/usr/bin/env python3
"""psx_vram.py — miniature offline PS1 VRAM model for asset-extraction replay.

Pure Python, no emulator, no runtime. Models exactly the VRAM operations the
Suikoden static pipeline needs:

  * 1024 x 512 array of 16-bit words (1 MB), little-endian like the hardware.
  * Rectangular upload  (LoadImage passthrough @0x80148590).
  * Texture sampling    (texpage addressing for 4-bit / 8-bit / 16-bit modes).
  * CLUT lookup         (4-bit: 16 entries, 8-bit: 256 entries).
  * RGB555 -> RGB888 conversion.
  * Provenance + sha256 on every upload (disc file / section / blob -> VRAM
    rect), with a verify path (upload log + VRAM region hash).
  * Strided atlas search (the VRAM-oracle residency path): rows uploaded by
    LoadImage are 2048 bytes apart in the 1 MB image, so a naive
    contiguous-bytes search misses resident atlases; find_atlas() is the
    canonical replacement for the ad-hoc strided search script.
  * texpage/CLUT value encoders (exact inverses of the decoders).

What it is NOT: a GPU emulator. No drawing commands, no blending, no
framebuffer double-buffering, no DMA timing. It replays *uploads* (the only
VRAM writes the 04_PLAY pipeline performs) and *samples* (what the sprite
packet builder reads), which is the complete surface needed to verify a
disc -> decode -> upload -> sample pipeline offline.

Reference: PS1 GPU texpage / CLUT encoding per nocash PSX docs, verified
against Suikoden MAIN.EXE disassembly (tile_grid_blit @0x800C3A44,
palette uploaders @0x800C3C5C/@0x800C3CC8).
"""

import hashlib
import json
import struct

VRAM_W = 1024
VRAM_H = 512

# Texpage color modes (bits 7-8)
TP_4BIT = 0
TP_8BIT = 1
TP_16BIT = 2


def rgb555_to_rgb888(w):
    """PS1 15-bit color word -> (r, g, b) 8-bit tuple. Bit 15 (semi-transparency
    flag / mask bit) is ignored for color.

    Uses the linear rescale (c*255)//31 — NOT the bit-replication variant
    (c<<3)|(c>>2). The two agree at 0 and 31 and differ by at most 1 LSB
    elsewhere; the linear form is the pipeline's established convention
    (dump_sprites.py renders all published PNGs with it), so the VRAM model
    uses it to keep disc -> decode -> upload -> sample byte-identical with
    the dumper.
    """
    r = (w & 0x1F)
    g = ((w >> 5) & 0x1F)
    b = ((w >> 10) & 0x1F)
    return (r * 255 // 31, g * 255 // 31, b * 255 // 31)


rgb555 = rgb555_to_rgb888


def texpage_base(texpage):
    """Decode a PS1 TEX PAGE value -> (base_x, base_y, color_mode).

    base_x = (bits 0-3) * 64, base_y = (bit 4) * 256,
    color_mode = (bits 7-8): 0 = 4-bit, 1 = 8-bit, 2 = 16-bit.
    """
    bx = (texpage & 0xF) * 64
    by = 256 if (texpage & 0x10) else 0
    mode = (texpage >> 7) & 0x3
    return bx, by, mode


def texpage_encode(bx, by, mode):
    """Inverse of texpage_base: (base_x, base_y, color_mode) -> texpage word.

    Only the base/mode bits are set (bits 0-4, 7-8); the remaining GPU bits
    (e.g. semi-transparency) are left clear.
    """
    assert bx % 64 == 0 and 0 <= bx < VRAM_W, f"bad texpage base_x {bx}"
    assert by in (0, 256), f"bad texpage base_y {by}"
    assert mode in (TP_4BIT, TP_8BIT, TP_16BIT), f"bad mode {mode}"
    return ((bx // 64) & 0xF) | (0x10 if by == 256 else 0) | ((mode & 0x3) << 7)


def clut_base(clut):
    """Decode a PS1 CLUT value -> (x, y) of CLUT entry 0 in VRAM.

    x = (bits 0-5) * 16, y = bits 6-14.
    """
    return (clut & 0x3F) * 16, (clut >> 6) & 0x1FF


def clut_encode(cx, cy):
    """Inverse of clut_base: (x, y) of CLUT entry 0 -> CLUT word."""
    assert cx % 16 == 0 and 0 <= cx < VRAM_W, f"bad clut x {cx}"
    assert 0 <= cy < 512, f"bad clut y {cy}"
    return ((cx // 16) & 0x3F) | ((cy & 0x1FF) << 6)


def make_provenance(source_file, section=None, blob_index=None, kind=None,
                    **extra):
    """Build a provenance record for an upload.

    source_file: disc file the bytes came from (e.g. "CRE.BIN").
    section:     container section ("S1"/"S2").
    blob_index:  c-blob index within the section.
    kind:        "atlas" (16,384 B c-blob) or "clut" (d32 palette), etc.
    extra:       any further free-form fields.

    Deterministic: no timestamps, no ordering dependence.
    """
    rec = {"source_file": source_file}
    if section is not None:
        rec["section"] = section
    if blob_index is not None:
        rec["blob_index"] = blob_index
    if kind is not None:
        rec["kind"] = kind
    rec.update(extra)
    return rec


class PsxVram:
    """1024x512x16-bit VRAM. All coordinates are absolute VRAM pixels."""

    def __init__(self, raw=None):
        if raw is not None:
            assert len(raw) == VRAM_W * VRAM_H * 2, "raw must be 1 MB"
            self.words = bytearray(raw)
        else:
            self.words = bytearray(VRAM_W * VRAM_H * 2)
        # Upload log: one dict per upload_rect call, in call order.
        # {"x","y","w","h","bytes","sha256","provenance"} — deterministic,
        # no timestamps.
        self.uploads = []

    # -- raw word access -------------------------------------------------
    def _idx(self, x, y):
        assert 0 <= x < VRAM_W and 0 <= y < VRAM_H, f"VRAM oob ({x},{y})"
        return (y * VRAM_W + x) * 2

    def get_word(self, x, y):
        i = self._idx(x, y)
        return struct.unpack_from('<H', self.words, i)[0]

    def set_word(self, x, y, w):
        struct.pack_into('<H', self.words, self._idx(x, y), w & 0xFFFF)

    # -- uploads (LoadImage) ---------------------------------------------
    def upload_rect(self, x, y, w, h, data, provenance=None):
        """Copy w*h 16-bit words from bytes `data` into VRAM at (x, y).

        Mirrors tile_grid_blit @0x800C3A44 -> LoadImage @0x80148590: a raw
        word copy, no pixel-format conversion. `data` must hold >= w*h words;
        short buffers raise (the game would read stale heap — model that
        explicitly with upload_rect_padded if you need it).

        Every upload is logged in self.uploads with the VRAM rect, the
        sha256 of the uploaded region bytes, and the caller-supplied
        provenance record (see make_provenance). Returns the log record.
        """
        need = w * h * 2
        assert len(data) >= need, f"upload_rect needs {need} B, got {len(data)}"
        src = bytes(data[:need])
        for row in range(h):
            dst = self._idx(x, y + row)
            s = row * w * 2
            self.words[dst:dst + w * 2] = src[s:s + w * 2]
        rec = {
            "x": x, "y": y, "w": w, "h": h,
            "bytes": need,
            "sha256": hashlib.sha256(src).hexdigest(),
            "provenance": provenance,
        }
        self.uploads.append(rec)
        return rec

    def upload_rect_padded(self, x, y, w, h, data, pad=0x0000, provenance=None):
        """Like upload_rect, but a short `data` is zero-padded to w*h words.

        The game really uploads stale heap bytes past a short decode; use
        this only when you explicitly want defined padding instead.
        """
        need = w * h * 2
        buf = bytearray(data[:need])
        if len(buf) < need:
            buf += bytes([pad & 0xFF, (pad >> 8) & 0xFF]) * ((need - len(buf)) // 2)
        return self.upload_rect(x, y, w, h, bytes(buf), provenance=provenance)

    # -- upload log / verification ---------------------------------------
    def region_hash(self, x, y, w, h):
        """sha256 of the w*h-word VRAM region, reassembled row-by-row.

        Equals the sha256 recorded at upload time iff the region has not
        been modified since the upload.
        """
        hh = hashlib.sha256()
        for row in range(h):
            i = self._idx(x, y + row)
            hh.update(self.words[i:i + w * 2])
        return hh.hexdigest()

    def verify_upload(self, rec):
        """True iff the VRAM region named by an upload log record still
        holds exactly the bytes that were uploaded."""
        return self.region_hash(rec["x"], rec["y"], rec["w"], rec["h"]) == \
            rec["sha256"]

    def verify_all(self):
        """[(record, ok), ...] for every logged upload, in upload order."""
        return [(rec, self.verify_upload(rec)) for rec in self.uploads]

    def upload_log_json(self):
        """Deterministic JSON dump of the upload log (no timestamps)."""
        return json.dumps(self.uploads, indent=2, sort_keys=True)

    # -- texture sampling --------------------------------------------------
    def sample_texel(self, texpage, u, v):
        """Raw texel at texture-local (u, v): for 16-bit the RGB555 word;
        for 4/8-bit the palette *index* (use sample_color for looked-up RGB).

        NOTE: texpage base_x is in 16-bit WORDS while u is in pixels, so the
        word column is bx + u//div (div = 4 for 4-bit, 2 for 8-bit) — NOT
        (bx+u)//div, which is only correct when bx == 0.
        """
        bx, by, mode = texpage_base(texpage)
        if mode == TP_16BIT:
            return self.get_word(bx + u, by + v)
        div = 4 if mode == TP_4BIT else 2
        w = self.get_word(bx + u // div, by + v)
        if mode == TP_4BIT:
            return (w >> ((u % 4) * 4)) & 0xF
        return (w >> ((u % 2) * 8)) & 0xFF

    def sample_color(self, texpage, clut, u, v):
        """RGB888 color of texture-local pixel (u, v).

        16-bit: direct RGB555. 4/8-bit: index -> CLUT entry -> RGB555.
        CLUT is ignored for 16-bit (hardware behavior).
        """
        bx, by, mode = texpage_base(texpage)
        if mode == TP_16BIT:
            return rgb555_to_rgb888(self.get_word(bx + u, by + v))
        idx = self.sample_texel(texpage, u, v)
        cx, cy = clut_base(clut)
        return rgb555_to_rgb888(self.get_word(cx + idx, cy))

    def sample_piece(self, texpage, clut, u, v, w, h, transparent_index=None):
        """Render one e-record piece (u, v, w, h).

        Without transparent_index: h rows of (r, g, b) tuples, sampled
        through texpage + CLUT. With transparent_index set (4/8-bit modes
        only): RGBA rows where texels whose palette index equals
        transparent_index come out (0,0,0,0) and all others (r,g,b,255).
        That models a textured primitive drawn with transparency enabled —
        the hardware treats palette index 0 as transparent in that case,
        which is the 04_PLAY dumper's documented index-0 assumption.
        16-bit texpages have no palette index, so transparent_index is
        ignored for them.
        """
        bx, by, mode = texpage_base(texpage)
        use_alpha = transparent_index is not None and mode != TP_16BIT
        cx, cy = clut_base(clut) if use_alpha else (0, 0)
        rows = []
        for dy in range(h):
            row = []
            for dx in range(w):
                if use_alpha:
                    idx = self.sample_texel(texpage, u + dx, v + dy)
                    if idx == transparent_index:
                        row.append((0, 0, 0, 0))
                    else:
                        r, g, b = rgb555_to_rgb888(
                            self.get_word(cx + idx, cy))
                        row.append((r, g, b, 255))
                else:
                    row.append(self.sample_color(texpage, clut, u + dx, v + dy))
            rows.append(row)
        return rows

    # -- persistence -------------------------------------------------------
    def to_bytes(self):
        return bytes(self.words)

    @classmethod
    def from_file(cls, path):
        with open(path, 'rb') as f:
            return cls(f.read())


# -- strided atlas search (VRAM-oracle residency path) ----------------------
#
# LoadImage uploads rows STRIDED across 2048-byte VRAM rows (1024 words/row),
# so a 16,384-byte atlas never appears as contiguous bytes in the 1 MB image
# (the naive contiguous search missed 0/78). These helpers check/search under
# the true strided layout. Canonical replacement for the ad-hoc
# kit/work/vram_residency_strided_20261002.py core.

def atlas_matches_at(vram, atlas, x, y, words_w=64, rows_h=128):
    """Byte-exact check: does `atlas` (words_w*2*rows_h bytes) sit in VRAM at
    (x, y) under the LoadImage strided layout?"""
    if len(atlas) != words_w * 2 * rows_h:
        return False
    if x < 0 or y < 0 or x + words_w > VRAM_W or y + rows_h > VRAM_H:
        return False
    rb = words_w * 2
    for r in range(rows_h):
        dst = ((y + r) * VRAM_W + x) * 2
        s = r * rb
        if vram.words[dst:dst + rb] != atlas[s:s + rb]:
            return False
    return True


def find_atlas(vram, atlas, words_w=64, rows_h=128, flood_cap=20000,
               anchor_rows=3):
    """Strided anchor-row search for `atlas` in a full 1 MB VRAM image.

    Algorithm (ported from the verified ad-hoc search): rank atlas rows by
    distinct-byte count, anchor on the best `anchor_rows` rows, find each
    anchor's byte offsets in the VRAM image (capped at `flood_cap` hits per
    anchor; a flooded anchor is skipped for the next-best row), prefilter
    candidates with two spread rows, then byte-verify survivors strided.
    Returns the sorted list of (x, y) hits; [] when absent (or when every
    tried anchor flooded).
    """
    need = words_w * 2 * rows_h
    if len(atlas) != need:
        raise ValueError("atlas is %d bytes, want %d" % (len(atlas), need))
    hay = vram.words
    rb = words_w * 2
    ranked = sorted(
        ((len(set(atlas[r * rb:(r + 1) * rb])), r) for r in range(rows_h)),
        reverse=True)
    for _, ar in ranked[:anchor_rows]:
        anchor = bytes(atlas[ar * rb:(ar + 1) * rb])
        cands, s, flooded = [], 0, False
        while True:
            i = hay.find(anchor, s)
            if i < 0:
                break
            cands.append(i)
            s = i + 1
            if len(cands) >= flood_cap:
                flooded = True
                break
        if flooded:
            continue  # try the next-best anchor row
        pre = [(ar + 43) % rows_h, (ar + 86) % rows_h]
        hits = []
        for f in cands:
            f0 = f - ar * 2048
            if f0 < 0 or f0 % 2:
                continue
            w0 = f0 // 2
            x0, y0 = w0 % VRAM_W, w0 // VRAM_W
            if x0 + words_w > VRAM_W or y0 + rows_h > VRAM_H:
                continue
            if any(hay[f0 + r * 2048:f0 + r * 2048 + rb] !=
                   atlas[r * rb:(r + 1) * rb] for r in pre):
                continue
            hits.append((x0, y0))
        out = [xy for xy in hits
               if atlas_matches_at(vram, atlas, xy[0], xy[1], words_w, rows_h)]
        if out:
            return sorted(out)
        return []  # anchor workable, nothing verified -> absent
    return []  # every tried anchor flooded


if __name__ == '__main__':
    # Smoke test: upload pattern, sample it back in all three modes.
    v = PsxVram()
    rec = v.upload_rect(320, 0, 64, 128, bytes(range(256)) * 64,
                        provenance=make_provenance("SMOKE.BIN", section="S1",
                                                   blob_index=0, kind="atlas"))
    assert v.get_word(320, 0) == 0x0100, hex(v.get_word(320, 0))
    # 16-bit direct: texpage 0x0105 -> base (320,0), 16-bit mode
    assert texpage_base(0x0105) == (320, 0, TP_16BIT)
    assert v.sample_color(0x0105, 0, 0, 0) == rgb555_to_rgb888(0x0100)
    # texpage decode sanity: 0x391b -> (704, 256), 16-bit
    assert texpage_base(0x391b) == (704, 256, TP_16BIT)
    # CLUT decode sanity: 0x0c17 -> (368, 48)
    assert clut_base(0x0c17) == (368, 48)
    # encoders invert the decoders
    assert texpage_encode(320, 256, TP_8BIT) == 0x95
    assert texpage_base(texpage_encode(320, 256, TP_8BIT)) == (320, 256, TP_8BIT)
    assert clut_encode(368, 48) == 0x0C17
    assert clut_base(clut_encode(368, 48)) == (368, 48)
    # provenance + hash recording
    assert rec["sha256"] == hashlib.sha256(bytes(range(256)) * 64).hexdigest()
    assert rec["provenance"]["source_file"] == "SMOKE.BIN"
    assert (rec["x"], rec["y"], rec["w"], rec["h"]) == (320, 0, 64, 128)
    assert v.verify_upload(rec)
    assert all(ok for _, ok in v.verify_all())
    v.set_word(320, 0, v.get_word(320, 0) ^ 0xFFFF)  # tamper
    assert not v.verify_upload(rec)
    assert not all(ok for _, ok in v.verify_all())
    # strided atlas search: contiguous find misses, strided find hits
    v2 = PsxVram()
    atlas = bytes((r * 3 + c * 5) & 0xFF for r in range(128) for c in range(128))
    v2.upload_rect(320, 256, 64, 128, atlas)
    assert v2.to_bytes().find(atlas) == -1
    assert (320, 256) in find_atlas(v2, atlas)
    assert atlas_matches_at(v2, atlas, 320, 256)
    assert not atlas_matches_at(v2, atlas, 320, 257)
    # 8-bit transparency sampling
    v3 = PsxVram()
    v3.upload_rect(0, 0, 1, 1, b"\x05\x00")
    v3.upload_rect(16, 0, 16, 1,
                   struct.pack("<16H", *([0] * 5 + [0x7FFF] + [0] * 10)))
    piece = v3.sample_piece(texpage_encode(0, 0, TP_8BIT), clut_encode(16, 0),
                            0, 0, 2, 1, transparent_index=0)
    assert piece[0][0] == (255, 255, 255, 255), piece[0][0]
    assert piece[0][1] == (0, 0, 0, 0), piece[0][1]
    print("psx_vram smoke test OK")

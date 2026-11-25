#!/usr/bin/env python3
"""Export disc-derived water-region and normal-boat candidates, without promotion."""
import argparse
import hashlib
import json
from pathlib import Path
import struct

from PIL import Image

from export_first_room import source, section_clips
from parse_04play import Parser
import lzss
import maindec
import psx_vram as gpu
import world_map_render as world

ROOT = Path(__file__).resolve().parents[2]
REPORT = ROOT / 'kit/data/reports/crossing_art.json'


class Atlas:
    def __init__(self):
        self.image = Image.new('RGBA', (256, 352))
        self.count = 0

    def add(self, image):
        if self.count >= 12 or image.height != 16 or image.width not in (16, 24):
            raise ValueError('unsupported normal-boat pose')
        rect = dict(x=self.count % 10 * 24, y=320 + self.count // 10 * 16,
                    w=image.width, h=image.height)
        self.image.alpha_composite(image, (rect['x'], rect['y']))
        self.count += 1
        return rect


def build():
    raw, origin = source('/J_DATA.BIN')
    main, main_origin = source('MAIN.EXE')
    if origin['sha256'] != 'cc9a5fa6d406cc611986572ba78c665626f9620b65bdc1202e6f8f06b85c2ba1' or main_origin['sha256'] != '439a166609dab8cde26249bd7661a835e4d55e79bb37a964761c981524e89d95':
        raise ValueError('unsupported crossing-art source identity')
    base = struct.unpack_from('<I', main, 0x18)[0]
    anchors = {0x80126800: 0x90A20277, 0x80126808: 0x30420020,
               0x8012680C: 0x1040000A, 0x80127EA4: 0x0C0499FD,
               0x80127EAC: 0x14400005, 0x80127EB0: 0x34100004,
               0x80127EC0: 0x24500001, 0x80127EC4: 0x8E22000C,
               0x80127EC8: 0x00108080, 0x80127ECC: 0x02021021,
               0x80128118: 0x0C049D94, 0x80128128: 0x0C049DE1,
               0x80128130: 0x0C049CC7, 0x80128138: 0x0C049AF3,
               0x80127460: 0x0C031091, 0x8012776C: 0x0C031091,
               0x80127564: 0x0C030F6B, 0x800C4268: 0x2442FFFF,
               **{0x8016F33C + 4 * i: clip for i, clip in enumerate((1, 3, 0, 2))}}
    for address, expected in anchors.items():
        if struct.unpack_from('<I', main, 2048 + address - base)[0] != expected or maindec.mword(address) != expected:
            raise ValueError(f'crossing selection/animation source changed at {address:#x}')
    source_words = {f'{address:#010x}': f'{word:#010x}' for address, word in anchors.items()}
    pointer = lambda off: struct.unpack_from('<I', raw, off)[0] - world.AREA_BASE
    resource_table = pointer(pointer(0) + 12)
    section_offset = pointer(resource_table + 2 * 4)
    if struct.unpack_from('<HHBB', raw, section_offset) != (12, 4, 1, 0x81):
        raise ValueError('normal boat section changed')
    normalized = bytearray(raw)
    for field, count in zip((8, 12, 16, 20), (1, 1, 12, 4), strict=True):
        table = pointer(section_offset + field)
        for offset in [section_offset + field, *(table + i * 4 for i in range(count))]:
            struct.pack_into('<I', normalized, offset, pointer(offset))
    parser = Parser(bytes(normalized), world.AREA_BASE)
    section = parser.parse_section('normal_boat', section_offset)
    if parser.errors:
        raise ValueError(parser.errors)
    atlas = Atlas()
    clips, sprite_proof = section_clips(raw, section, atlas)
    poses = [None] * 12
    anchors = [None] * 12
    for clip, source_clip in zip(clips, section['f']['entries'], strict=True):
        if source_clip['sequence']['pairs'] != [[i, 9] for i in ([0, 1, 2, 1] if clip['direction'] == 'down' else
                                                              [3, 4, 5, 4] if clip['direction'] == 'up' else
                                                              [6, 7, 8, 7] if clip['direction'] == 'left' else [9, 10, 11, 10])]:
            raise ValueError('normal boat animation changed')
        for frame, (index, _) in zip(clip['frames'], source_clip['sequence']['pairs'], strict=True):
            poses[index] = frame['rect']
            anchors[index] = dict(x=frame['anchor_x'], y=frame['anchor_y'])

    # Independent direct descriptor reads and VRAM sampling verify the shared sprite renderer.
    ct, dt, et = [pointer(section_offset + n) for n in (8, 12, 16)]
    compressed = pointer(ct)
    length = struct.unpack_from('<I', raw, compressed)[0]
    plane = lzss.decode_strict(raw[compressed + 4:compressed + 4 + length])
    if len(plane) != 16384:
        raise ValueError('invalid normal boat page')
    palette_at = pointer(dt)
    vram = gpu.PsxVram()
    vram.upload_rect(0, 0, 64, 128, plane)
    vram.upload_rect(512, 256, 32, 1, raw[palette_at:palette_at + 64])
    page, clut = gpu.texpage_encode(0, 0, gpu.TP_8BIT), gpu.clut_encode(512, 256)
    checked = 0
    for index, rect in enumerate(poses):
        off = pointer(et + index * 4)
        count, _, width, height, ax, ay = raw[off:off + 6]
        x, y, slot, tile, pw, ph, palette, flags = raw[off + 8:off + 16]
        if (count, width, height, ax, ay) != (1, rect['w'], rect['h'], anchors[index]['x'], anchors[index]['y']) or (x, y, slot, palette, pw, ph) != (0, 0, 0, 0, width, height) or flags & ~3:
            raise ValueError('normal boat descriptor parsers disagree')
        for py in range(height):
            for px in range(width):
                u = (tile & 15) * 8 + (width - 1 - px if flags & 2 else px)
                v = (tile >> 4) * 8 + (height - 1 - py if flags & 1 else py)
                texel = vram.sample_texel(page, u, v)
                word = vram.get_word(512 + texel, 256)
                expected = (*vram.sample_color(page, clut, u, v), 255 if word else 0)
                if atlas.image.getpixel((rect['x'] + px, rect['y'] + py)) != expected:
                    raise ValueError('boat pixels disagree with independent VRAM sampling')
                checked += 1

    terrain = world.parse_worldmap(raw)
    tiles = []
    for index in range(320):
        bank, tile, palette = world.tile_of(terrain, index)
        tx, ty = tile % 8 * 16, tile // 8 * 16
        clut_at = terrain['clut_offsets'][palette]
        rect = dict(x=index % 16 * 16, y=index // 16 * 16, w=16, h=16)
        for y in range(16):
            for x in range(16):
                value = terrain['pages'][bank][(ty + y) * 128 + tx + x]
                word = struct.unpack_from('<H', raw, clut_at + value * 2)[0]
                atlas.image.putpixel((rect['x'] + x, rect['y'] + y), (*world.rgb555(word), 255 if word else 0))
        tiles.append(rect)
    packet = dict(schema='suikoden-crossing-art/1', region='region_j', atlas='travel/crossing.png', atlas_width=256,
                  atlas_height=352, cells=list(terrain['codes']), tiles=tiles, poses=poses, anchors=anchors,
                  clips=[[dict(pose=i, ticks=t or 256) for i, t in clip['sequence']['pairs']] for clip in section['f']['entries']],
                  direction_clips=[maindec.mword(0x8016f33c + 4 * i) for i in range(4)],
                  initial_clip=0, initial_water_tile=10, hero_x=160, hero_y=128)
    proof = dict(schema='suikoden-crossing-art-proof/1', source=origin, main=main_origin,
                 decoder=f'parse_04play.Parser; export_first_room.section_clips; lzss.py {lzss.__version__}; world_map_render',
                 boat=dict(resource=2, **sprite_proof, compressed=compressed, compressed_bytes=length,
                           decoded_bytes=len(plane), decoded_sha256=hashlib.sha256(plane).hexdigest(), verified_pixels=checked),
                 terrain=dict(pages=terrain['page_offsets'], palettes=terrain['clut_offsets'], tilemap=terrain['tilemap_off']),
                 source_words=source_words,
                 status='candidate; image acceptance and promotion pending',
                 verification='direct header/descriptor parsing and offline VRAM upload/sample agree on every boat pixel; no emulator/oracle art',
                 scope='normal boat resource and region9 materials; source selector/animation anchors agree across full-header and headerless reads; prior-region water-phase carry and scene acceptance remain open')
    return packet, atlas.image, proof


def export(output):
    output = Path(output).resolve()
    if (ROOT / 'kit/work/accepted').resolve() in (output, *output.parents):
        raise ValueError('candidate art cannot enter accepted staging')
    packet, image, proof = build()
    output.mkdir(parents=True, exist_ok=True)
    image.save(output / 'crossing.png')
    packet['atlas_sha256'] = hashlib.sha256((output / 'crossing.png').read_bytes()).hexdigest()
    (output / 'crossing.json').write_text(json.dumps(packet, separators=(',', ':')) + '\n')
    poses = image.crop((0, 320, 256, 352)).resize((1024, 128), Image.Resampling.NEAREST)
    poses.save(output / 'boat_review.png')
    proof['atlas_sha256'] = packet['atlas_sha256']
    REPORT.write_text(json.dumps(proof, indent=2) + '\n')
    return packet


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, default=ROOT / 'kit/work/build/review/crossing')
    args = parser.parse_args()
    export(args.out)
    print('Exported water-region materials and 12 independently verified normal-boat poses; candidate only')

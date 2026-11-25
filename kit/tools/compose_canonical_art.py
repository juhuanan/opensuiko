#!/usr/bin/env python3
"""Add source-rendered VAA/VA1/VA2 room art, glyphs, portraits and actor clips to canonical assets."""
from __future__ import annotations

import hashlib
import argparse
import json
import struct
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "kit/tools"))
import area_scene  # noqa: E402
import export_opening_scene as eos  # noqa: E402
import system_glyphs  # noqa: E402
import lzss  # noqa: E402
import str_decode  # noqa: E402
import export_title_screen  # noqa: E402
import export_opening_field_package  # noqa: E402
from export_first_room import area_room_walkable_grid, source as disc_source  # noqa: E402
from psx_vram import rgb555_to_rgb888  # noqa: E402
from room_battle_package import SCENERY_CONDITIONS_SCHEMA, PROP_SCHEMA, WHEEL_MAP_SCHEMA, SCENERY_DRAW_SCHEMA, bind_field_rooms  # noqa: E402

OPENING_PORTRAIT_CODES = (
    1, 2, 3, 4, 6, 9, 10, 12, 14, 16, 19, 21, 25, 26, 27, 28, 31, 32, 35, 36, 38, 46, 70, 75,
    103, 105, 108, 109, 110, 111, 112, 113, 114, 117, 118,
)
PORTRAIT_NAMES = {
    1: "cleo", 2: "gremio", 3: "camille", 4: "kirkis", 6: "pahn", 9: "sylvina", 10: "sonya",
    12: "varkas", 14: "kuromimi", 16: "kasim", 19: "futch", 21: "humphrey", 25: "kwanda",
    26: "luc", 27: "mathiu", 28: "milich", 31: "sydonia", 32: "tai_ho", 35: "viktor", 36: "valeria", 38: "yam_koo",
    46: "marie", 70: "maas", 75: "stallion", 103: "marco", 105: "chandler",
    108: "ted", 109: "odessa", 110: "teo", 111: "barbarosa", 112: "windy", 113: "kraze",
    114: "kanaan", 117: "ain_gide", 118: "leknaat",
}

ALL_OPENING_ROOMS = tuple(
    (fn.lstrip("/"), rn, rid)
    for _, fn, rn, rid, _ in export_opening_field_package.AREA_ENTRIES
)

FIELD_ROOMS = tuple(
    (fn.lstrip("/"), rn, rid, title)
    for _, fn, rn, rid, title in export_opening_field_package.AREA_ENTRIES
)


class RectPacker:
    """Shelf packer inside disjoint free rectangles of canonical/atlas.png."""

    def __init__(self, atlas: Image.Image, regions: list[tuple[int, int, int, int]]) -> None:
        self.atlas = atlas
        self.regions = list(regions)
        self.region_idx = 0
        self.x = self.regions[0][0]
        self.y = self.regions[0][1]
        self.row_h = 0
        self.cache: dict[tuple[tuple[int, int], bytes], dict] = {}

    def add(self, image: Image.Image, *, dedup: bool = True) -> dict:
        key = (image.size, image.tobytes())
        if dedup and key in self.cache:
            return dict(self.cache[key])
        w, h = image.size
        while self.region_idx < len(self.regions):
            rx0, ry0, rx1, ry1 = self.regions[self.region_idx]
            if self.x + w > rx1:
                self.x = rx0
                self.y += self.row_h
                self.row_h = 0
            if self.y + h <= ry1 and self.x + w <= rx1:
                rect = {"x": self.x, "y": self.y, "w": w, "h": h}
                self.atlas.paste(image, (self.x, self.y))
                self.x += w + 1
                self.row_h = max(self.row_h, h + 1)
                if dedup:
                    self.cache[key] = rect
                return dict(rect)
            self.region_idx += 1
            if self.region_idx < len(self.regions):
                nx0, ny0, _, _ = self.regions[self.region_idx]
                self.x, self.y, self.row_h = nx0, ny0, 0
        raise ValueError(f"canonical atlas free regions exhausted adding {w}x{h}")


def _extract_missing_glyphs(canonical: Path, packer: RectPacker) -> None:
    ui_path = canonical / "ui.json"
    ui = json.loads(ui_path.read_text())
    existing = {g["character"] for g in ui.get("glyphs", [])}
    missing_codes = [(79, ":"), (84, "&")]
    if all(ch in existing for _, ch in missing_codes):
        return
    vram = system_glyphs.replay()
    page = eos.texpage_encode(960, 0, 0)
    for code, ch in missing_codes:
        if ch in existing:
            continue
        index = code - 17 + 26
        u, v = (index & 15) * 8 + 128, ((index >> 4) * 12 - 128) & 255
        img = Image.new("RGBA", (8, 12))
        px = []
        for y in range(12):
            for x in range(8):
                ci = vram.sample_texel(page, (u + x) & 255, (v + y) & 255)
                word = vram.get_word(1008 + ci, 504)
                px.append((*rgb555_to_rgb888(word), 0 if word == 0 else 255))
        img.putdata(px)
        ui["glyphs"].append({"character": ch, "rect": packer.add(img, dedup=False), "advance": 8})
    ui_path.write_text(json.dumps(ui, indent=2) + "\n")


def _render_idle_pose(data: bytes, bind: dict, vram, variant: int) -> dict | None:
    dtab = area_scene.ptr_at(data, bind["context"] + 20)
    desc = area_scene.ptr_at(data, dtab + variant * 4) if dtab is not None else None
    if desc is None:
        return None
    count = data[desc]
    if not 0 < count <= 64:
        return None
    idle = 1 if count > 1 else 0
    info = area_scene.descriptor_sheet(data, bind["context"], variant, idle)
    if info is None:
        return None
    sheet = info["sheet"]
    width, height, ax, ay = data[sheet + 2 : sheet + 6]
    pieces = [data[sheet + 8 + 8 * i : sheet + 16 + 8 * i] for i in range(data[sheet])]
    width = max([width] + [p[0] + p[4] for p in pieces])
    height = max([height] + [p[1] + p[5] for p in pieces])
    if not (0 < width <= 128 and 0 < height <= 128):
        return None
    image = Image.new("RGBA", (width, height))
    for i in range(data[sheet]):
        x, y, cell, uv, w, h, palette, flags = data[sheet + 8 + 8 * i : sheet + 16 + 8 * i]
        if palette >= len(bind["palette_offsets"]) or flags & ~3:
            return None
        slot = bind["atlas_slot"] + cell
        gx, gy, fold = area_scene.atlas_slot_geometry(slot)
        u, v = (uv & 15) * 8, fold + (uv >> 4) * 8
        clut_x = bind.get("clut_x", area_scene.NPC_CLUT_X)
        piece = Image.new("RGBA", (w, h))
        for py in range(h):
            for px in range(w):
                texel = vram.sample_texel(area_scene._texpage(gx, (slot % 20) // 10), (u + px) & 255, (v + py) & 255)
                word = vram.get_word(clut_x + (texel & 31), bind["clut_row"] + palette)
                piece.putpixel((px, py), (*rgb555_to_rgb888(word), 0 if word == 0 else 255))
        if flags & 2:
            piece = piece.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
        if flags & 1:
            piece = piece.transpose(Image.Transpose.FLIP_TOP_BOTTOM)
        image.alpha_composite(piece, (x, y))
    return {"image": image, "anchor_x": min(ax, width), "anchor_y": min(ay, height), "ticks": info["duration"] or 256}


def room_art(data, bin_name, room_index, room_id, title, output):
    rec = area_scene.room_record(data, room_index)
    sec = area_scene.section_off(data, rec["section"])
    gw, gh, walkable = area_room_walkable_grid(data, sec, bin_name, room_index)
    from export_first_room import Atlas
    atlas = Atlas()
    draws, _ = eos.room_draws(data, room_index, atlas, {'file': bin_name}, bind_scenery=True)
    metadata = {'composed': True, 'room_record': room_index, 'primary_section': sec,
                'decoder': f'export_opening_scene.room_draws; area_scene.map_layer_image; lzss.py/{lzss.__version__}',
                'producer_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                'scope': 'source map layers, scenery depth and animation; actor art and event admission remain separate'}
    room = {'id': room_id, 'title': title, 'width': gw * 8, 'height': gh * 8,
            'walkable': walkable, 'draws': draws, 'npcs': [], 'exits': [], 'events': [],
            'scenery_atlas': f"field/{room_id}.png"}
    from field_scenery import bind_existing_template_draws, export_model, room_relocations, room_templates
    templates = room_templates(data, room_index)
    relocations = room_relocations(data, room_index)
    room['scenery_model'] = export_model(data, room_index, templates, relocations)
    bind_existing_template_draws(data, room_index, templates, draws, relocations)
    if bin_name.lstrip('/') == 'VB3.BIN' and room_index == 28:
        from export_scripted_travel import kouan_wheel
        wheel = kouan_wheel()
        if hashlib.sha256(data).hexdigest() != wheel['source']['sha256']:
            raise ValueError('wheel map source differs from qualified room')
        expected = wheel['geometry']['projection']['map_pixels']
        if len(draws) < 2 or [draws[1]['rect']['w'], draws[1]['rect']['h']] != expected:
            raise ValueError('wheel companion map is not the separate secondary draw')
        room['wheel_map'] = 1
        metadata.update(source=wheel['source'], secondary_draw=1,
                        secondary_section=area_scene.section_off(data, rec['byte9']),
                        projection=wheel['geometry']['projection'])
    (output / 'field').mkdir(parents=True, exist_ok=True)
    atlas.save(output / room['scenery_atlas'])
    return room, metadata


def bind_scenery_prop(candidate, room, data, proof):
    """Append a source-created prop to the room's scenery atlas."""
    prop_id = max((draw['prop'] for draw in room['draws'] if draw.get('prop') is not None), default=-1) + 1
    if prop_id >= 64:
        raise ValueError('room scenery prop capacity exceeded')
    sec = area_scene.section_off(data, area_scene.room_record(data, int(room['id'].rsplit('_', 1)[1]))['section'])
    record = area_scene.scenery_record(data, proof['record_offset'], proof['record_index'])
    raw = bytes(record[key] for key in ('x_half', 'y_half', 'type', 'order', 'b4'))
    if raw.hex() != proof['record_bytes']:
        raise ValueError('scenery prop proof disagrees with source record')
    x, y = record['x_half'], record['y_half']
    vram, _ = area_scene.load_scene_materials(data, sec)
    pieces, meta = area_scene.scenery_primitives(data, sec, vram, object_records=[record])
    if meta['unresolved'] or len(pieces) != proof['descriptor']['vertices'] or any(p['semi_transparent'] for p in pieces):
        raise ValueError('unsupported scenery prop pieces')
    sheet = proof['descriptor']['sheet']
    width, height = data[sheet + 2:sheet + 4]
    image = Image.new('RGBA', (width, height))
    for index, piece in enumerate(pieces):
        literal = data[proof['descriptor']['sheet'] + 8 + index * 8:proof['descriptor']['sheet'] + 16 + index * 8]
        vx, vy, _, _, w, h, _, flip = literal
        if (piece['left'], piece['top'], piece['w'], piece['h'], piece['flags']) != (x * 8 + vx, y * 8 + vy, w, h, flip):
            raise ValueError('independent scenery prop geometry disagrees')
        # Independent packed-word sampling checks the shared texpage/CLUT consumer.
        gx, _ = piece['atlas_vram']
        page_y = (piece['slot'] % 20 // 10) * 256
        u, v = piece['uv']
        for py in range(h):
            for px in range(w):
                tx, ty = (u + px) & 255, (v + py) & 255
                offset = ((page_y + ty) * 1024 + gx + tx // 2) * 2
                texel = struct.unpack_from('<H', vram.words, offset)[0] >> ((tx & 1) * 8) & 255
                color = struct.unpack_from('<H', vram.words, (piece['clut_row'] * 1024 + texel) * 2)[0]
                if color != piece['words'][py][px]:
                    raise ValueError('independent scenery prop texels disagree')
        image.alpha_composite(area_scene._prim_to_tile(piece, rgb555_to_rgb888), (vx, vy))
    path = candidate / room['scenery_atlas']
    original = Image.open(path).convert('RGBA')
    atlas = Image.new('RGBA', (original.width, original.height + image.height))
    atlas.paste(original, (0, 0)); atlas.paste(image, (0, original.height))
    atlas.save(path)
    room['draws'].append({'rect': {'x': 0, 'y': original.height, 'w': width, 'h': height},
                          'x': x * 8, 'y': y * 8, 'depth': proof['depth'], 'prop': prop_id, 'frames': []})
    return {'source': proof, 'rgba_sha256': hashlib.sha256(image.tobytes()).hexdigest(),
            'pixels': image.width * image.height, 'verification': f'independent literal geometry and packed-word texture/CLUT sampling agree with all{len(pieces)} primitives/{width * height} pixels; shared strict material decoder',
            'media_accepted': False}


def compose_window_audio(candidate):
    """Supply the common source window cue required by extended field programs."""
    import tempfile
    from export_dice_audio import export_sounds
    import export_battle_sfx as sfx
    from export_common import atomic_write, serialize

    candidate = candidate.resolve()
    if (ROOT / 'kit/work/accepted').resolve() in (candidate, *candidate.parents):
        raise ValueError('candidate window audio cannot enter accepted staging')
    output = candidate / 'audio/sfx'
    manifest = output / 'battle_sfx.json'
    if any(path.is_symlink() for path in (candidate / 'audio', output, manifest)):
        raise ValueError('candidate sound paths cannot redirect')
    packet = json.loads(manifest.read_bytes()) if manifest.exists() else None
    if packet is not None:
        sfx.validate(output, packet)
        if any(cue['id'] == 0x501 for cue in packet['cues']):
            return
    with tempfile.TemporaryDirectory(prefix='suikoden-window-cue-') as scratch:
        stage = Path(scratch)
        source = export_sounds(stage, common_cues=(0x501,))
        cue, = [row for row in source['cues'] if row['id'] == 0x501]
        if packet is None:
            packet = {**source, 'cues': []}
        packet['cues'].append(cue)
        packet['sources'] = [*packet.get('sources', []), *[row for row in source['sources'] if row not in packet.get('sources', [])]]
        atomic_write(output / cue['path'], (stage / cue['path']).read_bytes())
        sfx.validate(output, packet)
        atomic_write(manifest, serialize(packet))


def compose_crossing_audio(candidate):
    """Bind verified dock/passage cues and field streams in a private candidate."""
    import tempfile
    import export_battle_sfx as sfx
    from export_dice_audio import export_sounds, export_verified_resource, export_founding_xa
    from dot8_audio import resources
    from export_scripted_travel import outputs
    from export_common import atomic_write, serialize

    candidate = candidate.resolve()
    if (ROOT / "kit/work/accepted").resolve() in (candidate, *candidate.parents):
        raise ValueError("dock audio cannot enter accepted staging")
    output = candidate / "audio/sfx"
    for directory in (candidate / "audio", output):
        if directory.is_symlink():
            raise ValueError("candidate audio must not redirect to another tree")
    manifest = output / "battle_sfx.json"
    if manifest.is_symlink():
        raise ValueError("candidate sound manifest cannot be a symlink")
    packet = json.loads(manifest.read_bytes()) if manifest.exists() else {
        "schema": "suikoden-battle-sfx/4", "sample_rate": 44100, "cues": [], "sources": [], "unsupported": []}
    packet.setdefault("sources", [])
    if packet["cues"]:
        sfx.validate(output, packet)
    travel, _ = outputs()
    dock = travel["dock_arrival"]
    requested = {dock["audio"]["command"]["cue"], dock["audio"]["window_cue"]}
    if requested != {0x501, 0x52a}:
        raise ValueError("dock sound inventory changed")
    passage_sounds = [request for door in travel["ruins_passages"]["doors"]
                      for request in door["audio_requests"] if request["kind"] == "sound"]
    if not passage_sounds or {request["request"] for request in passage_sounds} != {0x508}:
        raise ValueError("ruins passage sound inventory changed")
    requested.add(0x508)
    founding_sounds = [request for request in travel['hq_passages']['founding']['audio_requests']
                       if request['kind'] in ('sound', 'timed_sound')]
    if {request['request'] for request in founding_sounds} != {0x50b, 0x813}:
        raise ValueError('founding sound inventory changed')
    requested.update(request['request'] for request in founding_sounds)
    with tempfile.TemporaryDirectory(prefix="suikoden-dock-sounds-") as scratch:
        stage = Path(scratch)
        upstream = export_sounds(stage, common_cues=sorted(requested))
        selected = [cue for cue in upstream["cues"] if cue["id"] in requested]
        if {cue["id"] for cue in selected} != requested:
            raise ValueError("verified producer omitted a dock cue")
        existing = {cue["id"]: cue for cue in packet["cues"]}
        for cue in selected:
            if cue["id"] in existing and existing[cue["id"]] != cue:
                raise ValueError("dock cue conflicts with existing candidate audio")
            existing[cue["id"]] = cue
        packet["schema"] = "suikoden-battle-sfx/5"
        packet["cues"] = sorted(existing.values(), key=lambda cue: cue["id"])
        packet["status"] = "candidate; dry; listening and promotion pending"
        for bank in upstream["sources"]:
            if bank["request"] != 0x4b and bank not in packet["sources"]:
                packet["sources"].append(bank)
        output.mkdir(parents=True, exist_ok=True)
        for cue in selected:
            path = output / cue["path"]
            if path.is_symlink():
                raise ValueError("candidate cue cannot be a symlink")
            atomic_write(path, (stage / cue["path"]).read_bytes())
        sfx.validate(output, packet)
        atomic_write(manifest, serialize(packet))
        main, main_origin = disc_source('MAIN.EXE')
        if main_origin['sha256'] != travel['main']['sha256']:
            raise ValueError('field music source identity changed')
        base = struct.unpack_from('<I', main, 24)[0]
        records = {row['index']: row for row in resources()}
        tracks, origins = [], []
        for name, index in (('area_b', 12), ('ruins', 14), ('lakeshore', 57), ('headquarters', 3)):
            row = records[index]
            direct = struct.unpack_from('<I4H', main, 2048 + 0x80164e68 - base + index * 12)
            if direct != tuple(row[key] for key in ('lba', 'rate', 'loop_sector', 'end_sector', 'volume')):
                raise ValueError('field music descriptor readers disagree')
            track, origin = export_verified_resource(stage, name, row)
            tracks.append(track)
            origins.append(origin)
        legacy_entry_audio = {'schema': 'suikoden-field-audio/2', 'tracks': list(tracks)}
        field_manifest = candidate / 'audio/field.json'
        previous_audio = json.loads(field_manifest.read_bytes()) if field_manifest.exists() else None
        legacy_audio = {'schema': 'suikoden-field-audio/1', 'tracks': tracks[:3]}
        xa_request, = [request for request in travel['hq_passages']['founding']['audio_requests'] if request['kind'] == 'cd_xa']
        founding_xa, xa_origin = export_founding_xa(stage, xa_request)
        tracks.append(founding_xa)
        legacy_founding_audio = {'schema': 'suikoden-field-audio/3', 'tracks': list(tracks)}
        row = records[travel['krin_plan']['music']['request'] - 0x400]
        direct = struct.unpack_from('<I4H', main, 2048 + 0x80164e68 - base + row['index'] * 12)
        if direct != tuple(row[key] for key in ('lba', 'rate', 'loop_sector', 'end_sector', 'volume')):
            raise ValueError('Krin music descriptor readers disagree')
        track, origin = export_verified_resource(stage, 'infiltration', row)
        tracks.append(track)
        origins.append(origin)
        legacy_infiltration_audio = {'schema': 'suikoden-field-audio/4', 'tracks': list(tracks)}
        row = records[travel['kouan_mansion_doors']['stream']['resource_index']]
        direct = struct.unpack_from('<I4H', main, 2048 + 0x80164e68 - base + row['index'] * 12)
        if direct != tuple(row[key] for key in ('lba', 'rate', 'loop_sector', 'end_sector', 'volume')):
            raise ValueError('mansion stream descriptor readers disagree')
        track, origin = export_verified_resource(stage, 'mansion', row)
        tracks.append(track)
        origins.append(origin)
        legacy_mansion_audio = {'schema': 'suikoden-field-audio/5', 'tracks': list(tracks)}
        wheel_request, = [request for request in travel['kouan_wheel']['music'] if request['selector'] == 84]
        row = records[wheel_request['request'] - 0x400]
        direct = struct.unpack_from('<I4H', main, 2048 + 0x80164e68 - base + row['index'] * 12)
        if direct != tuple(row[key] for key in ('lba', 'rate', 'loop_sector', 'end_sector', 'volume')):
            raise ValueError('wheel stream descriptor readers disagree')
        track, origin = export_verified_resource(stage, 'wheel', row)
        tracks.append(track)
        origins.append(origin)
        field_audio = {'schema': 'suikoden-field-audio/6', 'tracks': tracks}
        if field_manifest.is_symlink() or previous_audio not in (None, legacy_audio, legacy_entry_audio, legacy_founding_audio, legacy_infiltration_audio, legacy_mansion_audio, field_audio):
            raise ValueError('field music manifest conflicts with candidate')
        for track in tracks:
            path = candidate / 'audio' / track['path']
            if path.is_symlink() or (path.exists() and hashlib.sha256(path.read_bytes()).hexdigest() != track['sha256']):
                raise ValueError('field music conflicts with candidate')
        for track in tracks:
            atomic_write(candidate / 'audio' / track['path'], (stage / track['path']).read_bytes())
        atomic_write(field_manifest, serialize(field_audio))
    report = {"schema": "suikoden-dock-audio/11", "source": dock["source"],
              "audio": dock["audio"], "fixed_box": dock["fixed_box"], "cues": selected,
              "passage_source": travel["ruins_passages"]["source"], "passage_sounds": passage_sounds,
              "founding_source": travel['hq_passages']['source'], "founding_sounds": founding_sounds,
              "founding_xa": founding_xa, "founding_xa_provenance": xa_origin,
              "field_audio": field_audio, "stream_sources": origins,
              "headquarters_entry": travel['hq_passages']['entry_music'],
              "music_dispatch": "MAIN80142440 suppresses the cached command, caches201..445, and clears it for14/15; global stop800C5530 requests stream target0/four passes of one unit and waits through800C50E4/800C8B70",
              "queued_stop": {"request": 0x14, "target": 0, "passes_per_poll": 4, "step": 1,
                              "waits_for_completion": False,
                              "source": "MAIN800C51F8..800C5244 queues the same fade/stop as15 and returns through800C5398 without its readiness loop",
                              "callers": [request for door in travel['ruins_passages']['doors']
                                          for request in door['audio_requests'] if request['kind'] == 'queued_stop']},
              "banks": packet["sources"], "verification": upstream["independent_verification"],
              "decoder": "export_dice_audio.export_sounds/export_verified_resource; export_battle_sfx; existing SPU ADPCM decoders",
              "poll_order": upstream["poll_order"], "stream_restore": upstream["win_stream_restore"],
              "limitations": "dry cue candidates; stream playback, original loader-poll cadence and listening remain unqualified",
              "media_accepted": False, "promoted": False}
    atomic_write(ROOT / "kit/data/reports/dock_audio.json", serialize(report))
    return manifest


def bind_kouan_rooms(candidate, original):
    from export_common import atomic_write, serialize
    from export_scripted_travel import kouan_mansion_approach, kouan_ladder
    package_path = candidate / 'room.json'
    package = json.loads(package_path.read_text())
    if (candidate / 'field').is_symlink():
        raise ValueError('candidate field output must not redirect to another tree')
    data, origin = disc_source('/VB3.BIN')
    if origin != original['source']:
        raise ValueError('Kouan room source identity changed')
    records = []
    for number in original['rooms']:
        room_id = f'vb3_room_{number}'
        room, metadata = room_art(data, 'VB3.BIN', number, room_id, {0: 'Kouan', 2: 'Kouan Inn', 11: 'Lepant mansion entrance', 12: 'Lepant mansion', 13: 'Lepant mansion', 14: 'Lepant mansion ladder', 15: 'Lepant mansion', 20: 'Lepant mansion'}[number], candidate)
        prop_source = kouan_mansion_approach()['prop'] if number == 0 else kouan_ladder()['prop'] if number == 14 else None
        prop = bind_scenery_prop(candidate, room, data, prop_source) if prop_source else None
        existing = next((entry for entry in package['rooms'] if entry['id'] == room_id), None)
        if existing is None:
            package['rooms'].append(room)
        elif existing != room:
            if number != 0 or existing != {**room, 'draws': room['draws'][:1]}:
                raise ValueError('existing Kouan room differs from regenerated source data')
            existing.update(room)
        records.append({'room': room_id, 'source': origin, 'composition': metadata, 'prop': prop,
                        'scenery_sha256': hashlib.sha256((candidate / room['scenery_atlas']).read_bytes()).hexdigest()})
    world = next(room for room in package['rooms'] if room['id'] == 'world_b')
    entrance = {**original['world_point']['hero_rect'], 'room': 'vb3_room_0',
                'spawn_x': original['world_point']['spawn_pixels'][0], 'spawn_y': original['world_point']['spawn_pixels'][1]}
    existing = [entry for entry in world['exits'] if entry['room'] == 'vb3_room_0']
    if existing and existing != [entrance]:
        raise ValueError('existing Kouan world entrance differs from source point')
    if not existing:
        world['exits'].append(entrance)
    package['schema'] = SCENERY_DRAW_SCHEMA
    atomic_write(package_path, serialize(package))
    return records


def compose_crossing_party(candidate, art_manifest):
    """Append verified dock/founding S2 sprites to a private candidate atlas."""
    import character_table
    import maindec
    import psx_vram as gpu
    from export_first_room import hero_clips, section_clips
    from parse_04play import Parser
    from export_opening_field_package import SPEAKER_NAMES
    from export_scripted_travel import outputs
    from preparation import stable_id
    from export_common import atomic_write, serialize
    from io import BytesIO

    candidate = candidate.resolve()
    if (ROOT / "kit/work/accepted").resolve() in (candidate, *candidate.parents):
        raise ValueError("party candidates cannot enter accepted staging")
    base_path = ROOT / "kit/work/build/canonical/atlas.png"
    base_hash = hashlib.sha256(base_path.read_bytes()).hexdigest()
    atlas_path = candidate / "atlas.png"
    if (candidate / "travel").is_symlink():
        raise ValueError("candidate travel output must not redirect to another tree")
    previous_path = candidate / "travel/party_art.json"
    current_hash = hashlib.sha256(atlas_path.read_bytes()).hexdigest()
    if current_hash != base_hash:
        previous = json.loads(previous_path.read_text()) if previous_path.exists() else {}
        if previous.get("atlas_sha256") != current_hash or previous.get("source_atlas_sha256") != base_hash:
            raise ValueError("candidate atlas does not match the canonical base or previous party export")
    base = Image.open(base_path).convert("RGBA")
    if base.width != 4096 or base.height + 163 > 4096:
        raise ValueError("candidate atlas needs space for the dock party row")
    atlas = Image.new("RGBA", (base.width, base.height + 163))
    atlas.paste(base, (0, 0))
    packer = RectPacker(atlas, [(0, base.height, base.width, base.height + 49), (0, base.height + 114, base.width, atlas.height), (0, base.height + 49, base.width, base.height + 114)])
    travel, _ = outputs()
    main, main_origin = disc_source("MAIN.EXE")
    main_base = struct.unpack_from("<I", main, 0x18)[0]
    consumers = {0x800c40fc: 0x92220004, 0x800c4104: 0xa7a20018,
                 0x800c4108: 0x92230005, 0x800c411c: 0xa7a3001a,
                 0x800c4128: 0x30420002, 0x800c4158: 0x30420001}
    for address, expected in consumers.items():
        if maindec.mword(address) != expected or struct.unpack_from("<I", main, 2048 + address - main_base)[0] != expected:
            raise ValueError("party field extent/reflection consumer changed")
    characters = travel["dock_arrival"]["source_party_order"][1:]
    if characters != [2, 1, 35, 3]:
        raise ValueError("dock party graphics order changed")
    area, area_origin = disc_source("/VB5.BIN")
    section = area_scene.section_off(area, area_scene.room_record(area, 0)["section"])
    bindings = area_scene.character_bindings(area, section)
    headquarters, headquarters_origin = disc_source("/VB5A2.BIN")
    if headquarters_origin != travel['hq_passages']['founding']['terminal_handoff']['destination']:
        raise ValueError("headquarters party-art source disagrees with founding destination")
    headquarters_bindings = area_scene.character_bindings(headquarters, area_scene.section_off(headquarters, area_scene.room_record(headquarters, 0)['section']))
    founding, founding_origin = disc_source('/VB7.BIN')
    if founding_origin != travel['hq_passages']['source']:
        raise ValueError('founding actor source identity changed')
    founding_bindings = area_scene.character_bindings(founding, area_scene.section_off(founding, area_scene.room_record(founding, 4)['section']))
    kouan, kouan_origin = disc_source('/VB3.BIN')
    if kouan_origin != travel['kouan']['source']:
        raise ValueError('Kouan sprite source identity changed')
    kouan_bindings = area_scene.character_bindings(kouan, area_scene.section_off(kouan, area_scene.room_record(kouan, 2)['section']))
    town_bindings = area_scene.character_bindings(kouan, area_scene.section_off(kouan, area_scene.room_record(kouan, 0)['section']))
    mansion_bindings = area_scene.character_bindings(kouan, area_scene.section_off(kouan, area_scene.room_record(kouan, 20)['section']))
    wheel_bindings = area_scene.character_bindings(kouan, area_scene.section_off(kouan, area_scene.room_record(kouan, 28)['section']))
    for character in (15, 30, 44):
        left, right = town_bindings[character]['context'], kouan_bindings[character]['context']
        for field, count in ((8, 1), (12, 1), (16, 12), (20, 4)):
            lt, rt = area_scene.ptr_at(kouan, left + field), area_scene.ptr_at(kouan, right + field)
            for index in range(count):
                lp, rp = area_scene.ptr_at(kouan, lt + index * 4), area_scene.ptr_at(kouan, rt + index * 4)
                if field == 8:
                    def plane_at(offset):
                        length = struct.unpack_from('<I', kouan, offset)[0]
                        return lzss.decode_strict(kouan[offset + 4:offset + 4 + length])
                    agree = plane_at(lp) == plane_at(rp)
                else:
                    size = 64 if field == 12 else 8 + kouan[lp] * 8 if field == 16 else 4 + kouan[lp] * 2
                    agree = kouan[lp:lp + size] == kouan[rp:rp + size]
                if not agree:
                    raise ValueError('town and inn character graphics disagree')
    participants = [entity for entity in area_scene.entities(area, area_scene.room_record(area, 0))
                    if entity["id"] and entity["flags"] & 0x101]
    if [(e["index"], e["id"], e["x_half"], e["y_half"]) for e in participants] != [(2, 32, 255, 255), (3, 38, 14, 33)]:
        raise ValueError("dock ordinary actor order or starting coordinates changed")
    for entity in participants:
        classifier = entity["stream_offsets"][0]
        expected = bytes.fromhex("08 0c 20 06 ff 00") if entity["id"] == 32 else bytes.fromhex("06 ff 00")
        if area[classifier:classifier + len(expected)] != expected:
            raise ValueError("dock actor classification or initial facing changed")
    actors, sources = [], []
    for character in characters + [32, 38, 26, 27, 118, 15, 44, 121, 125, 30, 129, 47, 39, 8, 200]:
        if character in (27, 118, 44, 121, 125, 30, 129, 47, 200):
            sprite_data, origin, sprite_bindings = (kouan, kouan_origin, town_bindings if character in (44, 121, 125, 30) else wheel_bindings if character == 200 else kouan_bindings) if character in (44, 121, 125, 30, 129, 47, 200) else (founding, founding_origin, founding_bindings)
            record = {'name': travel['kouan_giovanni']['choreography']['dialogues'][0]['speaker_name'] if character == 44 else SPEAKER_NAMES.get(character, f'kouan_character_{character}')}
            section = sprite_bindings[character]['context']
            normalized = bytearray(sprite_data)
            for field, count in ((8, 1), (12, 1), (16, 12), (20, 4)):
                table = area_scene.ptr_at(sprite_data, section + field)
                for offset in (section + field, *(table + i * 4 for i in range(count))):
                    struct.pack_into('<I', normalized, offset, area_scene.ptr_at(sprite_data, offset))
            raw = bytes(normalized)
            parser = Parser(raw, area_scene.RAM_BASE)
            parsed = parser.parse_section('founding_actor', section)
            if parser.errors:
                raise ValueError(parser.errors)
            clips, proof = section_clips(sprite_data, parsed, packer)
        else:
            record = character_table.by_id()[character]
            raw, origin = disc_source("/04_PLAY/" + record["sprite_file"])
            if raw[0] != character:
                raise ValueError("party character binding disagrees with sprite header")
            clips, proof = hero_clips(raw, packer)
            section = struct.unpack_from("<I", raw, 0x28)[0]
        if struct.unpack_from("<HHBB", raw, section) != (13 if character == 8 else 12, 4, 1, 0x81):
            raise ValueError("unsupported dock party S2 layout")
        ct, dt, et, ft = struct.unpack_from("<4I", raw, section + 8)
        compressed, palette_at = (struct.unpack_from("<I", raw, table)[0] for table in (ct, dt))
        length = struct.unpack_from("<I", raw, compressed)[0]
        plane = lzss.decode_strict(raw[compressed + 4:compressed + 4 + length])
        if len(plane) != 16384:
            raise ValueError("invalid dock party page")
        vram = gpu.PsxVram()
        vram.upload_rect(0, 0, 64, 128, plane)
        palette = raw[palette_at:palette_at + 64]
        vram.upload_rect(512, 256, 32, 1, palette)
        page, clut = gpu.texpage_encode(0, 0, gpu.TP_8BIT), gpu.clut_encode(512, 256)
        poses = {}
        for direction, clip in enumerate(clips):
            off = struct.unpack_from("<I", raw, ft + direction * 4)[0]
            if raw[off:off + 2] != bytes((4, 1 if character == 200 else 3)) or clip.get("flags", 3) != raw[off + 1] or len(clip["frames"]) != 4:
                raise ValueError("unsupported party clip lifecycle")
            for index, frame in enumerate(clip["frames"]):
                pose, duration = raw[off + 4 + index * 2:off + 6 + index * 2]
                geometry = {key: frame[key] for key in ("rect", "anchor_x", "anchor_y")}
                if frame["ticks"] != (duration or 256) or (pose in poses and poses[pose] != geometry):
                    raise ValueError("independent party animation read disagrees")
                poses[pose] = geometry
        if set(poses) != set(range(12)):
            raise ValueError("party clip coverage changed")
        checked, sampled_sizes = 0, set()
        for index, frame in sorted(poses.items()):
            off = struct.unpack_from("<I", raw, et + index * 4)[0]
            count, _, width, height, ax, ay = raw[off:off + 6]
            x, y, slot, tile, pw, ph, pal, flags = raw[off + 8:off + 16]
            rect = frame["rect"]
            if (count, width, height, ax, ay) != (1, rect["w"], rect["h"], frame["anchor_x"], frame["anchor_y"]) or (width, height, slot, pal) != (24, 48, 0, 0) or not (0 < pw and 0 < ph and x + pw <= width and y + ph <= height) or flags & ~3:
                raise ValueError("independent party descriptor read disagrees")
            sampled_sizes.add((pw, ph))
            for py in range(height):
                for px in range(width):
                    expected = (0, 0, 0, 0)
                    if x <= px < x + pw and y <= py < y + ph:
                        u = (tile & 15) * 8 + (pw - 1 - (px - x) if flags & 2 else px - x)
                        v = (tile >> 4) * 8 + (ph - 1 - (py - y) if flags & 1 else py - y)
                        texel = vram.sample_texel(page, u, v)
                        word = struct.unpack_from("<H", palette, texel * 2)[0]
                        expected = (*vram.sample_color(page, clut, u, v), 255 if word else 0)
                    if atlas.getpixel((rect["x"] + px, rect["y"] + py)) != expected:
                        raise ValueError("party pixels disagree with independent VRAM sampling")
                    checked += 1
        embedded = ({'source': origin, 'context': section,
                     'verification': 'embedded area S2; section parser and independent descriptor/pixel reads agree'}
                    if character in (27, 118, 44, 121, 125, 30, 129, 47) else None)
        if character in (1, 2, 27, 35, 26, 32, 38, 15, 39):
            embedded_data, embedded_origin, embedded_bindings = ((kouan, kouan_origin, mansion_bindings) if character == 39 else (kouan, kouan_origin, kouan_bindings) if character == 15 else
                                                                 (headquarters, headquarters_origin, headquarters_bindings) if character in (1, 2, 27, 35) else
                                                                 (founding, founding_origin, founding_bindings) if character == 26 else (area, area_origin, bindings))
            context = embedded_bindings[character]["context"]
            for field, count in ((8, 1), (12, 1), (16, 12), (20, 4)):
                area_table = area_scene.ptr_at(embedded_data, context + field)
                play_table = struct.unpack_from("<I", raw, section + field)[0]
                for index in range(count):
                    ap = area_scene.ptr_at(embedded_data, area_table + index * 4)
                    pp = struct.unpack_from("<I", raw, play_table + index * 4)[0]
                    if field == 8:
                        length = struct.unpack_from("<I", embedded_data, ap)[0]
                        agree = lzss.decode_strict(embedded_data[ap + 4:ap + 4 + length]) == plane
                    else:
                        size = 64 if field == 12 else (8 + embedded_data[ap] * 8 if field == 16 else 4 + embedded_data[ap] * 2)
                        agree = embedded_data[ap:ap + size] == raw[pp:pp + size]
                    if not agree:
                        raise ValueError("embedded field character differs from normal S2 graphics")
            embedded = {"source": embedded_origin, "context": context,
                        "verification": "decoded plane, palette, all12 draw records and all4 animation records agree"}
            if character in (32, 38):
                entity = next(e for e in participants if e["id"] == character)
                embedded.update(entity=entity['index'], ordinary_slot=participants.index(entity), initial_facing='down',
                                initial_pixels=[entity['x_half'] * 8, entity['y_half'] * 8])
        actors.append({"character": character, "id": stable_id(record["name"]), "clips": clips})
        sources.append({"character": character, "source": origin, "section": section, "palette": palette_at,
                        "sprite_records": proof, "plane_sha256": hashlib.sha256(plane).hexdigest(),
                        "palette_sha256": hashlib.sha256(palette).hexdigest(), "independent_pixels": checked,
                        "sampled_sizes": sorted(sampled_sizes), "embedded": embedded})
    krin_raw, krin_origin = disc_source('/04_PLAY/' + character_table.by_id()[15]['sprite_file'])
    image_at, palette_at = struct.unpack_from('<II', krin_raw, 44)
    plane, palette, compressed = eos.portrait_payload(krin_raw, image_at, palette_at)
    plane_hash = hashlib.sha256(plane).hexdigest()
    palette_hash = hashlib.sha256(struct.pack('<256H', *palette)).hexdigest()
    embedded_image = area_scene.ptr_at(kouan, kouan_bindings[15]['record'] + 4)
    embedded_palette = area_scene.ptr_at(kouan, kouan_bindings[15]['record'] + 8)
    embedded_plane, embedded_clut, _ = eos.portrait_payload(kouan, embedded_image, embedded_palette)
    if plane != embedded_plane or palette != embedded_clut:
        raise ValueError('Krin normal portrait differs from its inn resource')
    expected = next(row for row in travel['founded_passages']['mathiu_briefing']['party_callback']['portraits']['portraits'] if row['source_character'] == 15)
    if plane_hash != expected['admit_plane_sha256'] or palette_hash != expected['palette_sha256']:
        raise ValueError('Krin portrait disagrees with independent FACE/palette extraction')
    portrait = Image.new('RGBA', (64, 64))
    portrait.putdata([(*rgb555_to_rgb888(palette[index]), 0 if palette[index] == 0 else 255) for index in plane])
    portrait_record = {'id': 'portrait_015_krin', 'character': 15, 'width': 64, 'height': 64,
                       'plane_sha256': plane_hash, 'palette_sha256': palette_hash, 'rect': packer.add(portrait)}
    import face_portraits
    giovanni_image = area_scene.ptr_at(kouan, town_bindings[44]['record'] + 4)
    giovanni_palette = area_scene.ptr_at(kouan, town_bindings[44]['record'] + 8)
    giovanni_plane, giovanni_clut, giovanni_compressed = eos.portrait_payload(kouan, giovanni_image, giovanni_palette)
    page, cell, palette_index = struct.unpack_from('<3B', headquarters, 0x6d878 + 44 * 3)
    face_raw, face_origin = disc_source(face_portraits.face_records()[page]['path'])
    palette_pointer = struct.unpack_from('<I', headquarters, 0x6d854 + palette_index * 4)[0] - area_scene.RAM_BASE
    if (giovanni_plane != face_portraits.page_cells(face_portraits.decode_page(face_raw))[cell]
            or struct.pack('<256H', *giovanni_clut) != headquarters[palette_pointer:palette_pointer + 512]):
        raise ValueError('Giovanni embedded portrait differs from separate FACE/selector extraction')
    image = Image.new('RGBA', (64, 64))
    image.putdata([(*rgb555_to_rgb888(giovanni_clut[index]), 0 if giovanni_clut[index] == 0 else 255) for index in giovanni_plane])
    giovanni_portrait = {'id': 'portrait_044_giovanni', 'character': 44, 'width': 64, 'height': 64,
                        'plane_sha256': hashlib.sha256(giovanni_plane).hexdigest(),
                        'palette_sha256': hashlib.sha256(struct.pack('<256H', *giovanni_clut)).hexdigest(), 'rect': packer.add(image)}
    juppo_raw, juppo_origin = disc_source('/04_PLAY/' + character_table.by_id()[39]['sprite_file'])
    juppo_image, juppo_palette = struct.unpack_from('<II', juppo_raw, 44)
    juppo_plane, juppo_clut, juppo_compressed = eos.portrait_payload(juppo_raw, juppo_image, juppo_palette)
    juppo_embedded_image = area_scene.ptr_at(kouan, mansion_bindings[39]['record'] + 4)
    juppo_embedded_palette = area_scene.ptr_at(kouan, mansion_bindings[39]['record'] + 8)
    if eos.portrait_payload(kouan, juppo_embedded_image, juppo_embedded_palette)[:2] != (juppo_plane, juppo_clut):
        raise ValueError('Juppo normal and embedded portraits disagree')
    juppo_page, juppo_cell, palette_index = struct.unpack_from('<3B', headquarters, 0x6d878 + 39 * 3)
    juppo_face, juppo_face_origin = disc_source(face_portraits.face_records()[juppo_page]['path'])
    juppo_palette_pointer = struct.unpack_from('<I', headquarters, 0x6d854 + palette_index * 4)[0] - area_scene.RAM_BASE
    if juppo_plane != face_portraits.page_cells(face_portraits.decode_page(juppo_face))[juppo_cell] or struct.pack('<256H', *juppo_clut) != headquarters[juppo_palette_pointer:juppo_palette_pointer + 512]:
        raise ValueError('Juppo portrait disagrees with independent FACE/selector extraction')
    image = Image.new('RGBA', (64, 64))
    image.putdata([(*rgb555_to_rgb888(juppo_clut[index]), 0 if juppo_clut[index] == 0 else 255) for index in juppo_plane])
    juppo_portrait = {'id': 'portrait_039_juppo', 'character': 39, 'width': 64, 'height': 64,
                      'plane_sha256': hashlib.sha256(juppo_plane).hexdigest(),
                      'palette_sha256': hashlib.sha256(struct.pack('<256H', *juppo_clut)).hexdigest(), 'rect': packer.add(image)}
    if atlas.crop((0, 0, base.width, base.height)).tobytes() != base.tobytes():
        raise ValueError("party export changed existing atlas pixels")
    from export_opening_profiles import write_trial
    trial_path = candidate / 'battle/trial.json'
    trial = json.loads(trial_path.read_text())
    write_trial(trial_path, trial)
    juppo_profile = next((profile for profile in trial['party'] if profile['id'] == 'juppo'), None)
    if juppo_profile is None or juppo_profile.get('rune') != 'trick' or not juppo_profile.get('rune_locked'):
        raise ValueError('Juppo candidate must retain his locked seed rune')
    kouan_rooms = bind_kouan_rooms(candidate, travel['kouan'])
    png = BytesIO()
    atlas.save(png, format="PNG")
    atomic_write(atlas_path, png.getvalue())
    atlas_hash = hashlib.sha256(png.getvalue()).hexdigest()
    art = json.loads(art_manifest.read_text())
    art["schema"] = "suikoden-canonical-field-art/2"
    art['portraits']['15'] = portrait_record
    art['portraits']['44'] = giovanni_portrait
    art['portraits']['39'] = juppo_portrait
    # shortcut: extend this early-party bank before later recruits can revisit the uncompleted scene.
    art["party_actors"] = {"vb5_room_0": actors[:4], "vb3_room_20": [actor for actor in actors if actor["character"] in (2, 1, 35, 3, 26, 32, 38)]}
    art["actor_clips"] = {}
    for actor in actors[4:]:
        room = 'vb3_room_28' if actor['character'] in (8, 200) else 'vb3_room_20' if actor['character'] == 39 else 'vb3_room_0' if actor['character'] in (44, 121, 125, 30) else 'vb3_room_2' if actor['character'] in (15, 129, 47) else 'vb5_room_0' if actor['character'] in (32, 38) else 'vb7_room_4'
        key = f"{room}_character_{actor['character']:03d}"
        art["character_clips"][key] = [clip["frames"][clip["idle_frame"]] for clip in actor["clips"]]
        art["actor_clips"][key] = actor["clips"]
    for actor in actors:
        if actor['character'] in (15, 44, 121, 125, 30, 129, 47, 39, 8, 200):
            continue
        key = f"vb7_room_4_character_{actor['character']:03d}"
        art['character_clips'][key] = [clip['frames'][clip['idle_frame']] for clip in actor['clips']]
        art['actor_clips'][key] = actor['clips']
    for actor in actors:
        if actor['character'] not in (1, 2, 27, 35):
            continue
        key = f"vb5a2_room_0_character_{actor['character']:03d}"
        art['character_clips'][key] = [clip['frames'][clip['idle_frame']] for clip in actor['clips']]
        art['actor_clips'][key] = actor['clips']
    for actor in actors:
        if actor['character'] not in (15, 30, 44):
            continue
        for room in ('vb3_room_0', 'vb3_room_2'):
            key = f"{room}_character_{actor['character']:03d}"
            art['character_clips'][key] = [clip['frames'][clip['idle_frame']] for clip in actor['clips']]
            art['actor_clips'][key] = actor['clips']
    viktor = next(actor for actor in actors if actor['character'] == 35)
    art['character_clips']['vb3_room_0_character_035'] = [clip['frames'][clip['idle_frame']] for clip in viktor['clips']]
    art['actor_clips']['vb3_room_0_character_035'] = viktor['clips']
    art["party_atlas_sha256"] = atlas_hash
    output = candidate / "travel"
    output.mkdir(exist_ok=True)
    manifest = output / "field_art.json"
    atomic_write(manifest, serialize(art))
    report = {"schema": "suikoden-field-party-art/10", "room": "vb5_room_0", "characters": characters, "ordinary_characters": [32, 38],
              'kouan_juppo': {'source': juppo_origin, 'image_offset': juppo_image, 'palette_offset': juppo_palette,
                               'compressed_bytes': juppo_compressed, 'face_source': juppo_face_origin, 'face_page': juppo_page, 'face_cell': juppo_cell,
                               'embedded_image_offset': juppo_embedded_image, 'embedded_palette_offset': juppo_embedded_palette, **juppo_portrait},
              "kouan_giovanni": {'source': kouan_origin, 'sprite_context': town_bindings[44]['context'],
                                 'portrait': {'offset': giovanni_image, 'palette_offset': giovanni_palette, 'compressed_bytes': giovanni_compressed,
                                              'face_source': face_origin, 'face_page': page, 'face_cell': cell, 'selector_source': headquarters_origin,
                                              'selector_palette_offset': palette_pointer, **giovanni_portrait}},
              "kouan": {'rooms': kouan_rooms, 'character': 15, 'portrait': {'source': krin_origin, 'image_offset': image_at, 'palette_offset': palette_at, 'compressed_bytes': compressed,
                                                                                      'embedded_source': kouan_origin, 'embedded_image_offset': embedded_image, 'embedded_palette_offset': embedded_palette, **portrait_record}},
              "founding_characters": {'room': 'vb7_room_4', 'characters': [actor['character'] for actor in actors if actor['character'] not in (15, 44, 121, 125, 30, 129, 47, 39, 8, 200)],
                                      'scope': 'candidate clips only; source selectors and full scene binding remain separate'},
              "headquarters_characters": {'room': 'vb5a2_room_0', 'characters': [1, 2, 27, 35], 'reuses_existing_pixels': True,
                                          'scope': 'normal S2 banks match embedded headquarters data; Mathiu briefing/party callback execution remains unfinished'},
              "main": main_origin, "source_words": {f"{a:#010x}": f"{w:#010x}" for a, w in consumers.items()},
              "source_atlas_sha256": base_hash, "atlas_sha256": atlas_hash, "sources": sources,
              "decoder": f"export_first_room.hero_clips; parse_04play S2; lzss.py/{lzss.__version__}",
              "verification": f"direct descriptor/animation reads and offline VRAM sampling agree on all{len(actors) * 12} poses/{sum(entry['independent_pixels'] for entry in sources)} pixels; Krin and Giovanni portraits agree with separate FACE/selector extraction",
              "producer_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              "media_accepted": False, "promoted": False}
    atomic_write(previous_path, serialize(report))
    atomic_write(ROOT / "kit/data/reports/dock_party_art.json", serialize(report))
    return manifest


def export_crossing_rooms(output):
    from export_opening_field_package import build_package
    from export_scripted_travel import RUINS_ROOMS, HQ_ROOMS, FOUNDED_ROOMS, KOUAN_ROOMS, hq_founding
    import export_crossing_art
    import world_map_render
    output = output.resolve()
    if (ROOT / "kit/work/accepted").resolve() in (output, *output.parents):
        raise ValueError("candidate rooms cannot enter accepted staging")
    output.mkdir(parents=True, exist_ok=True)
    rooms, proof = [], []
    specs = [
            ("VB5I0.BIN", "vb5i0_room_0", "Castle arrival", (128, 344)),
            ("VB5.BIN", "vb5_room_0", "Castle ruins", (136, 344)),
            *(("VB5.BIN", f"vb5_room_{room}", "Castle caverns", None) for room in RUINS_ROOMS if room != 0),
            *(("VB7.BIN", f"vb7_room_{room}", "Castle headquarters", (80, 88) if room == 4 else None) for room in HQ_ROOMS),
            *((file[1:], f'{file[1:-4].lower()}_room_{room}', 'Castle headquarters',
               (80, 224) if (file, room) == ('/VB5A2.BIN', 0) else None)
              for file, indices in FOUNDED_ROOMS.items() for room in indices),
            *(("VB3.BIN", f'vb3_room_{room}', {0: 'Kouan', 2: 'Kouan Inn', 11: 'Lepant mansion entrance', 12: 'Lepant mansion', 13: 'Lepant mansion', 14: 'Lepant mansion ladder', 15: 'Lepant mansion', 20: 'Lepant mansion'}[room],
               {0: (232, 592), 2: (248, 208), 11: (280, 128), 12: (32, 56), 13: (72, 232), 14: (112, 24), 15: (184, 208), 20: (600, 240)}[room]) for room in KOUAN_ROOMS)]
    handoff = hq_founding()['terminal_handoff']
    for name, room_id, title, spawn in specs:
        room_index = int(room_id.rsplit('_', 1)[1])
        data, origin = disc_source("/" + name)
        if name == "VB5A2.BIN" and room_index == 0 and (origin != handoff['destination'] or list(spawn) != handoff['spawn_pixels']):
            raise ValueError("founded headquarters source handoff disagrees with room export")
        room, meta = room_art(data, name, room_index, room_id, title, output)
        width = room["width"] // 8
        if spawn is not None and room["walkable"][(spawn[1] // 8) * width + spawn[0] // 8] != "1":
            raise ValueError(f"source spawn is blocked in {room_id}")
        rooms.append(room)
        proof.append({"room": room_id, "source": origin, "source_room": room_index,
                      "section": area_scene.section_off(data, area_scene.room_record(data, room_index)['section']), "spawn_pixels": list(spawn) if spawn is not None else None,
                      "scenery_sha256": hashlib.sha256((output / room["scenery_atlas"]).read_bytes()).hexdigest(),
                      "composition": meta})
    water = export_crossing_art.export(output / "travel")
    raw, water_origin = disc_source("/J_DATA.BIN")
    header = int.from_bytes(raw[:4], "little") - world_map_render.AREA_BASE
    threshold = int.from_bytes(raw[header + 4:header + 6], "little")
    rooms.append({"id": "world_j", "title": "Lake Toran", "width": 1280, "height": 960,
                  "walkable": "".join("1" if code >= threshold else "0" for code in water["cells"]),
                  "boat_walkable": "".join("1" if code < 21 else "0" for code in water["cells"]),
                  "draws": [], "npcs": [], "exits": [], "events": []})
    # No portraits or field characters occur in the two-entry arrival module.
    art = output / "field_art.json"
    art.write_text(json.dumps({"portraits": {}, "character_clips": {}}) + "\n")
    events = build_package(art, rooms=(("/VB5I0.BIN", 0, "vb5i0_room_0"),))
    programs = events["rooms"][0]["content"]["programs"]
    if len(programs) != 2 or {p["entry"] for p in programs} != {"initialization", "ordinary"}:
        raise ValueError("initial island programs were not bound")
    (output / "room.json").write_text(json.dumps({"schema": SCENERY_DRAW_SCHEMA, "rooms": rooms}, indent=2) + "\n")
    (output / "field_events.json").write_text(json.dumps(events, separators=(",", ":")) + "\n")
    report = {"schema": "suikoden-initial-island-rooms/3", "rooms": proof,
              "founding_destination": handoff,
              "world": {"room": "world_j", "source": water_origin, "terrain_threshold": threshold,
                        "scope": "scripted crossing bypasses these masks; Journey separately owns normal boat steering with the source boat mask; conditional maelstrom feedback remains unbound"},
              "decoder": f"lzss.py/{lzss.__version__}; area_scene.compose_scene_image; export_first_room.area_room_walkable_grid",
              "producer_sha256": {name: hashlib.sha256((ROOT / "kit/tools" / name).read_bytes()).hexdigest()
                                  for name in ("compose_canonical_art.py", "area_scene.py", "export_first_room.py", "export_opening_field_package.py", "export_scripted_travel.py")},
              "room_table_sha256": hashlib.sha256((output / "room.json").read_bytes()).hexdigest(),
              "events": {"rooms": len(events["rooms"]), "programs": len(programs),
                         "sha256": hashlib.sha256((output / "field_events.json").read_bytes()).hexdigest()},
              "status": "candidate only; source rooms load in the private package; native traversal and image acceptance remain pending",
              "scope": "33 island, cavern, headquarters and Kouan room candidates; exact source arrivals are retained; both island programs are included here; --include-crossing separately binds the dock, founding/morning scenes, headquarters doors, Mathiu briefing, departure and Kouan entry/inn/greeting, both Krin plan choices and mansion approach/return ladder-chamber passages and Juppo scene; chests, ghost bank selection, mansion interior progression, Kirkis recruitment and connected scene execution remain unfinished"}
    (ROOT / "kit/data/reports/initial_island_rooms.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Exported {len(rooms)} crossing/castle room candidates and both island programs; unaccepted")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    crossing = parser.add_mutually_exclusive_group()
    crossing.add_argument("--crossing-rooms", type=Path, help="export only initial island/ruins candidates to this directory")
    crossing.add_argument("--crossing-party", type=Path, help="append verified first-dock party sprites to this private candidate")
    crossing.add_argument("--crossing-audio", type=Path, help="bind verified crossing cues and field streams without playback")
    args = parser.parse_args()
    if args.crossing_audio:
        print(f"Bound dock and passage audio candidates: {compose_crossing_audio(args.crossing_audio)}")
        return 0
    if args.crossing_rooms:
        return export_crossing_rooms(args.crossing_rooms)
    if args.crossing_party:
        prior = args.crossing_party / 'travel/field_art.json'
        manifest = compose_crossing_party(args.crossing_party, prior if prior.exists() else ROOT / "kit/work/build/opening/canonical_field_art.json")
        report = json.loads((manifest.parent / 'party_art.json').read_text())
        print(f"Exported{len(report['sources']) * 12} independently checked field poses; candidate metadata: {manifest}")
        return 0
    canonical = ROOT / "kit/work/build/canonical"
    area_cache: dict[str, bytes] = {}
    source_proofs: dict[str, dict] = {}
    for path, filename, *_ in export_opening_field_package.AREA_DESCRIPTORS:
        raw, origin = disc_source(path)
        area_cache[filename.lstrip("/")] = raw
        source_proofs[filename.lstrip("/")] = origin

    package = json.loads((canonical / "room.json").read_text())
    package["schema"] = SCENERY_CONDITIONS_SCHEMA
    atlas_path = canonical / "atlas.png"
    opening = Image.open(atlas_path).convert("RGBA")
    atlas = Image.new("RGBA", (4096, 3572))
    atlas.paste(opening, (0, 0))

    world_px, world_py = 2816, 1908
    import world_map_render
    plane = world_map_render.load_plane("DATA/01_AREA.A/A_DATA.BIN")
    source_data, _ = disc_source(plane["path"])
    threshold = int.from_bytes(source_data[plane["d_off"] + 4 : plane["d_off"] + 6], "little")
    world = world_map_render.compose(plane).resize((1280, 960))
    atlas.paste(world, (world_px, world_py))
    world_draw = {
        "rect": {"x": world_px, "y": world_py, "w": 1280, "h": 960},
        "x": 0, "y": 0, "depth": -1000, "hidden_by": None, "frames": [],
    }
    if not any(room["id"] == "world_a" for room in package["rooms"]):
        package["rooms"].append({
            "id": "world_a", "title": "World map", "width": 1280, "height": 960,
            "walkable": "".join("1" if code in (0x4C, 0xA1) or code >= threshold else "0" for code in plane["codes"]),
            "draws": [world_draw], "exits": [], "npcs": [], "events": [],
        })
    else:
        next(room for room in package["rooms"] if room["id"] == "world_a")["draws"] = [world_draw]

    # Ensure every opening room in the slice has its disc scenery PNG and grid.
    (canonical / "field").mkdir(parents=True, exist_ok=True)
    rooms_by_id = {room["id"]: room for room in package["rooms"]}
    for world_id, data_path, title, bridge_codes in (
        ("world_b", "DATA/02_AREA.B/B_DATA.BIN", "Toran region", ()),
        ("world_c", "DATA/06_AREA.C/C_DATA.BIN", "Region C", ()),
        ("world_d", "DATA/07_AREA.D/D_DATA.BIN", "Region D", ()),
        ("world_e", "DATA/08_AREA.E/E_DATA.BIN", "Region E", ()),
        ("world_f", "DATA/09_AREA.F/F_DATA.BIN", "Region F", ()),
        ("world_g", "DATA/10_AREA.G/G_DATA.BIN", "Region G", ()),
        ("world_h", "DATA/11_AREA.H/H_DATA.BIN", "Region H", ()),
        ("world_k", "DATA/07_AREA.D/K_DATA.BIN", "Region K", ()),
        ("world_z", "DATA/15_AREA.Z/Z_DATA.BIN", "Region Z", (0x4C, 0xA1)),
    ):
        plane_w = world_map_render.load_plane(data_path)
        w_data, _ = disc_source(plane_w["path"])
        thresh_w = int.from_bytes(w_data[plane_w["d_off"] + 4 : plane_w["d_off"] + 6], "little")
        world_w_img = world_map_render.compose(plane_w).resize((1280, 960))
        world_w_rel = f"field/{world_id}.png"
        world_w_img.convert("RGBA").save(canonical / world_w_rel)
        world_w_obj = {
            "id": world_id,
            "title": title,
            "width": 1280,
            "height": 960,
            "walkable": "".join("1" if code in bridge_codes or code >= thresh_w else "0" for code in plane_w["codes"]),
            "draws": [{
                "rect": {"x": 0, "y": 0, "w": 1280, "h": 960},
                "x": 0,
                "y": 0,
                "depth": -1000,
                "hidden_by": None,
                "frames": [],
            }],
            "npcs": [],
            "exits": [],
            "events": [],
            "scenery_atlas": world_w_rel,
        }
        if world_id == 'world_k':
            from export_world_points import bind_river_navigation
            bind_river_navigation(world_w_obj, plane_w['codes'])
        if world_id in rooms_by_id:
            rooms_by_id[world_id].update(world_w_obj)
        else:
            package["rooms"].append(world_w_obj)
            rooms_by_id[world_id] = world_w_obj

    import export_crossing_art
    water = export_crossing_art.export(canonical / "travel")
    raw_j, _ = disc_source("/J_DATA.BIN")
    header_j = int.from_bytes(raw_j[:4], "little") - world_map_render.AREA_BASE
    threshold_j = int.from_bytes(raw_j[header_j + 4 : header_j + 6], "little")
    world_j_obj = {
        "id": "world_j",
        "title": "Lake Toran",
        "width": 1280,
        "height": 960,
        "walkable": "".join("1" if code >= threshold_j else "0" for code in water["cells"]),
        "boat_walkable": "".join("1" if code < 21 else "0" for code in water["cells"]),
        "draws": [],
        "npcs": [],
        "exits": [],
        "events": [],
    }
    if "world_j" in rooms_by_id:
        rooms_by_id["world_j"].update(world_j_obj)
    else:
        package["rooms"].append(world_j_obj)
        rooms_by_id["world_j"] = world_j_obj

    for bin_name, ri, room_id, title in FIELD_ROOMS:
        data = area_cache[bin_name]
        room_obj, _ = room_art(data, bin_name, ri, room_id, title, canonical)
        if room_id in rooms_by_id:
            rooms_by_id[room_id].update(room_obj)
        else:
            package["rooms"].append(room_obj)
            rooms_by_id[room_id] = room_obj

    # Pack missing glyphs ('&', ':'), portraits, and idle NPC actor clips into unused atlas bands.
    glyph_packer = RectPacker(atlas, [(2240, 1908, 2816, 1940)])
    _extract_missing_glyphs(canonical, glyph_packer)
    packer = RectPacker(atlas, [(1664, 2869, 4096, 3572), (2240, 1940, 2816, 2804)])

    portraits: dict[str, dict] = {}
    shu_raw, _ = disc_source("04_PLAY/SHU.BIN")
    shu_ioff, shu_poff = struct.unpack_from("<II", shu_raw, 44)
    plane, pal, _ = eos.portrait_payload(shu_raw, shu_ioff, shu_poff)
    pimg = Image.new("RGBA", (64, 64))
    pimg.putdata([(*rgb555_to_rgb888(pal[idx]), 0 if pal[idx] == 0 else 255) for idx in plane])
    portraits["8"] = {
        "id": "portrait_008_hero",
        "character": 8,
        "width": 64,
        "height": 64,
        "plane_sha256": hashlib.sha256(plane).hexdigest(),
        "palette_sha256": hashlib.sha256(struct.pack("<256H", *pal)).hexdigest(),
        "rect": packer.add(pimg),
    }

    character_clips: dict[str, list[dict]] = {}
    for bin_name, ri, room_id in ALL_OPENING_ROOMS:
        data = area_cache[bin_name]
        rec = area_scene.room_record(data, ri)
        sec = area_scene.section_off(data, rec["section"])
        vram, mat_meta = area_scene.load_scene_materials(data, sec)
        slot_start = mat_meta["atlas_base"] + sum(
            len(c["atlases"]) for c in mat_meta["contexts"] if not c.get("is_32_colour")
        )
        binds, _ = area_scene.load_npc_contexts(data, sec, vram, slot_start)
        for cid, bind in sorted(binds.items()):
            if str(cid) not in portraits and cid in OPENING_PORTRAIT_CODES:
                ioff = area_scene.ptr_at(data, bind["record"] + 4)
                poff = area_scene.ptr_at(data, bind["record"] + 8)
                if ioff and poff:
                    plane, pal, _ = eos.portrait_payload(data, ioff, poff)
                    pimg = Image.new("RGBA", (64, 64))
                    pimg.putdata([(*rgb555_to_rgb888(pal[idx]), 0 if pal[idx] == 0 else 255) for idx in plane])
                    portraits[str(cid)] = {
                        "id": f"portrait_{cid:03d}_{PORTRAIT_NAMES[cid]}",
                        "character": cid,
                        "width": 64,
                        "height": 64,
                        "plane_sha256": hashlib.sha256(plane).hexdigest(),
                        "palette_sha256": hashlib.sha256(struct.pack("<256H", *pal)).hexdigest(),
                        "rect": packer.add(pimg),
                    }
            if bind.get("context") is None:
                continue
            poses = []
            for variant in range(4):
                pose = _render_idle_pose(data, bind, vram, variant)
                if pose is None:
                    break
                poses.append({
                    "rect": packer.add(pose["image"]),
                    "anchor_x": pose["anchor_x"],
                    "anchor_y": pose["anchor_y"],
                    "ticks": pose["ticks"],
                })
            if len(poses) == 4:
                character_clips[f"{room_id}_character_{cid:03d}"] = poses

    art_manifest = ROOT / "kit/work/build/opening/canonical_field_art.json"
    art_manifest.parent.mkdir(parents=True, exist_ok=True)
    art_manifest.write_text(json.dumps({
        "schema": "suikoden-canonical-field-art/1",
        "decoder": f"lzss.py/{lzss.__version__}; area_scene.compose_scene_image; compose_canonical_art._render_idle_pose",
        "producer_sha256": {name: hashlib.sha256((ROOT / "kit/tools" / name).read_bytes()).hexdigest()
                            for name in ("compose_canonical_art.py", "export_opening_scene.py", "export_first_room.py", "area_scene.py", "field_scenery.py", "lzss.py")},
        "room_sources": {room: {"source": source_proofs[name], "room": number}
                         for name, number, room in ALL_OPENING_ROOMS},
        "portraits": portraits, "character_clips": character_clips,
    }, indent=2) + "\n")

    atlas.save(atlas_path)
    from export_world_points import bind_world_points
    bind_world_points(package)
    compose_window_audio(canonical)
    (canonical / "room.json").write_text(json.dumps(package, indent=2) + "\n")
    str_decode.export_runtime_videos(str(canonical / "video"))
    export_title_screen.export(canonical / "title")
    authored = ROOT / "game/assets/campaign/opening/field_rooms"
    if authored.exists():
        bind_field_rooms(canonical, authored)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

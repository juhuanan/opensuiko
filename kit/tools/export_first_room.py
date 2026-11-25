#!/usr/bin/env python3
"""Private VB6 inn/village/shop candidate: decoded PNG + semantic JSON, no PS1 VM.

Three rooms, conversations, a persistent exit event and mattress access are supported.
Sources are read through disc.py; accepted content is never written by this command.
"""
from pathlib import Path
import argparse
import hashlib
import json
import struct
import tempfile

from PIL import Image, ImageDraw
import area_scene as scene
from disc import extract
from lzss import decode_strict
from parse_04play import Parser, PARSER_VERSION
from psx_vram import rgb555_to_rgb888
from war_text import decode
from area_animate import frame_table

ROOT = Path(__file__).resolve().parents[2]
ROOM_IDS = {7: "vb6_inn", 0: "vb6_village", 9: "vb6_shop"}
DIRECTIONS = ("down", "up", "left", "right")


def source(suffix):
    rows = json.loads((ROOT / "kit/data/catalogs/extracted/iso_files.json").read_text())
    row, = [r for r in rows if r["path"].endswith(suffix)]
    data = extract(row["lba"], row["size"])
    return data, {"file": row["path"], "lba": row["lba"], "size": len(data),
                  "sha256": hashlib.sha256(data).hexdigest()}


def collision_sources(data, sec, object_records=None):
    records = scene.scenery_records(data, sec) if object_records is None else object_records
    if not records:
        return []
    ctx = scene.contexts(data, sec)[0]["offset"]
    objects = []
    for record in records:
        sheet = scene.descriptor_sheet(data, ctx, record["type"])["sheet"]
        width, height = data[sheet + 2:sheet + 4]
        start = sheet + 8 + data[sheet] * 8
        mask = data[start:start + (width // 8) * (height // 8)]
        if len(mask) != (width // 8) * (height // 8) or set(mask) - {0, 1, 2, 3}:
            raise ValueError("unsupported scenery collision mask")
        objects.append({**record, "sheet": sheet, "width": width // 8,
                        "height": height // 8, "mask": mask})
    return objects


def terrain_query(data, sec, x, y):
    """Four 8px cells under a 16px footprint; MAIN 8012E08C."""
    width = scene.u16(data, sec)
    tiles = scene.ptr_at(data, sec + 0x14)
    packed = scene.ptr_at(data, sec + 0x30)
    result = 0
    for bit, (dx, dy) in enumerate(((0, 0), (1, 0), (0, 1), (1, 1))):
        cx, cy = x + dx, y + dy
        code = scene.u16(data, tiles + 2 * ((cy // 2) * width + cx // 2))
        nibble = (data[packed + code // 2] >> (4 * ((code + 1) & 1))) & 15
        solid = (nibble >> ((cy & 1) * 2 + (cx & 1))) & 1
        result |= solid << bit
    return result


def scenery_query(objects, x, y, height=0):
    """Ground-level query, preserving first contributing object (8012E308)."""
    result, surface = 0, 0
    for index, obj in enumerate(objects):
        if (obj["b4"] not in (height, height + 1) or obj["order"] in (0, 1)
                or not obj["x_half"] - 1 <= x < obj["x_half"] + obj["width"]
                or not obj["y_half"] - 1 <= y < obj["y_half"] + obj["height"]
                or result & 255):
            continue
        result = 0
        for bit, (dx, dy) in enumerate(((0, 0), (1, 0), (0, 1), (1, 1))):
            ox, oy = x + dx - obj["x_half"], y + dy - obj["y_half"]
            if 0 <= ox < obj["width"] and 0 <= oy < obj["height"]:
                value = obj["mask"][oy * obj["width"] + ox]
                result |= (1 << (8 + bit)) | ((value & 1) << bit) | ((value & 2) << (3 + bit))
        surface = 0 if result & 15 else index + 1
    return result, surface


def walkable_grid(data, sec, object_records=None):
    """Bake the native ground-footprint result into simple origin occupancy."""
    width, height = scene.u16(data, sec) * 2, scene.u16(data, sec + 2) * 2
    objects = collision_sources(data, sec, object_records=object_records)
    cells = []
    for y in range(height):
        for x in range(width):
            if x == width - 1 or y == height - 1:
                cells.append("0")
                continue
            terrain = terrain_query(data, sec, x, y)
            query, surface = scenery_query(objects, x, y)
            solid = combine_ground(terrain, query, surface, 0)
            cells.append("1" if solid == 0 else "0")
    return width, height, "".join(cells)


def combine_ground(terrain, query, surface, level):
    """Native collision combination (MAIN 8012DB9C)."""
    low, upper, coverage = query & 15, (query >> 4) & 15, (query >> 8) & 15
    if level == 0:
        if surface and (upper & ~low):
            return low | (terrain & ~coverage)
        return (low & ~upper) | terrain
    if surface:
        return (low & coverage) | (terrain & ~coverage)
    return low | (terrain & ~coverage)


def support_after_step(objects, query, surface, level, support=None):
    """Accepted-step level/index writes at MAIN8012DF34..8012DFA0."""
    if surface:
        if query & 0xf0:
            support = (surface - 1) & 255
            level = objects[support]['b4']
    elif not query:
        level = 0
    return level, support


def area_room_walkable_grid(data, sec, area_name, room_num, object_records=None):
    """Bake reachable support levels for the spiral stairs and static bridges (8012DF34)."""
    width, height, grid = walkable_grid(data, sec, object_records=object_records)
    key = (area_name.rsplit("/", 1)[-1], room_num)
    spiral = key == ("VA4.BIN", 6)
    bridges = {
        ("VA8.BIN", 2): (65, 39), ("VA8.BIN", 4): (49, 39),
        ("VC1.BIN", 7): (7, 40), ("VC2.BIN", 0): (40, 92),
    }
    if not spiral and key not in bridges:
        return width, height, grid
    from collections import deque
    objects = collision_sources(data, sec, object_records=object_records)
    cells = list(grid)
    vis = set()
    q = deque()
    # Bridge origins come from the southern room transitions.
    origins = [(x, 9) for x in range(width) if cells[9 * width + x] == "1"] if spiral else [bridges[key]]
    max_y = 10 if spiral else height - 2
    for x, y in origins:
        vis.add((x, y, 0))
        q.append((x, y, 0))
    while q:
        x, y, lvl = q.popleft()
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            nx, ny = x + dx, y + dy
            if not (0 <= nx < width - 1 and 0 <= ny <= max_y):
                continue
            terrain = terrain_query(data, sec, nx, ny)
            query, surface = scenery_query(objects, nx, ny, lvl)
            if combine_ground(terrain, query, surface, lvl) != 0:
                continue
            nl, _ = support_after_step(objects, query, surface, lvl)
            if (nx, ny, nl) not in vis:
                vis.add((nx, ny, nl))
                q.append((nx, ny, nl))
                cells[ny * width + nx] = "1"
    return width, height, "".join(cells)


def mattress_access(data, sec):
    """User-requested bed access from the sides; ground draw depth stays unchanged."""
    beds = sorted((s for s in scene.scenery_records(data, sec) if s["type"] == 20),
                  key=lambda s: (s["y_half"], s["x_half"]))
    expected = [(x, y) for y in (12, 20) for x in (2, 8, 14)]
    if [(b["x_half"], b["y_half"]) for b in beds] != expected:
        raise ValueError("inn bed layout changed; review the authored mattress access")
    names = ("upper_left", "upper_middle", "upper_right", "lower_left", "lower_middle", "lower_right")
    return [{"id": f"inn_bed_{name}", "x": b["x_half"] * 8,
             "y": b["y_half"] * 8 + 8, "w": 24, "h": 24}
            for name, b in zip(names, beds, strict=True)]


# shortcut: block the raised inn step until surface-attached actor drawing is implemented.
def inn_frontage_blockers(data, sec):
    """Derive ground-only frontage blockers from the inn's final mask row."""
    inn, = [obj for obj in collision_sources(data, sec) if obj["type"] == 4]
    y = inn["y_half"] + inn["height"] - 1
    if y + 1 != scene.GROUND_DEPTH_ORIGIN - inn["order"]:
        raise ValueError("village inn frontage depth changed")
    blocked = []
    for x in range(inn["x_half"] - 1, inn["x_half"] + inn["width"]):
        query, _ = scenery_query([inn], x, y)
        if query & 0xF0 and not query & 0x0F:
            blocked.append({"x": x * 8, "y": y * 8})
    if not blocked:
        raise ValueError("village inn raised frontage changed")
    return blocked, {"object": inn["offset"], "sheet": inn["sheet"],
                     "origins": blocked,
                     "provenance": "authored ground-only collision restriction; original query results remain unchanged",
                     "reason": "raised front strip requires surface-attached drawing, outside this runtime slice"}


class Atlas:
    def __init__(self):
        self.image = Image.new("RGBA", (2048, 4096))
        self.x = self.y = self.row_height = 0

    def add(self, image):
        w, h = image.size
        if self.x + w > self.image.width:
            self.x = 0
            self.y += self.row_height
            self.row_height = 0
        if w > self.image.width or self.y + h > self.image.height:
            raise ValueError("first-room atlas capacity exceeded")
        rect = {"x": self.x, "y": self.y, "w": w, "h": h}
        self.image.paste(image, (self.x, self.y))
        self.x += w + 1
        self.row_height = max(self.row_height, h + 1)
        return rect

    def save(self, path):
        self.image.crop((0, 0, self.image.width, self.y + self.row_height)).save(path)


def hero_clips(data, atlas):
    parser = Parser(data, 0xB0000000)
    parser.parse_header()
    section = parser.parse_section("S2", parser.u32(0x28))
    return section_clips(data, section, atlas)


def section_clips(data, section, atlas):
    palettes = section["d"]["entries"]
    if len(palettes) != 1:
        raise ValueError("Hero S2 requires one palette")
    po = palettes[0]["target_file_offset"]
    palette = struct.unpack_from("<32H", data, po)
    planes = []
    for entry in section["c"]["entries"]:
        blob = entry["blob"]
        start, length = blob["data_file_offset"], blob["data_len"]
        plane = decode_strict(data[start:start + length])
        if len(plane) != 16384:
            raise ValueError("Hero atlas is not 128x128")
        planes.append(plane)
    poses = []
    for entry in section["e"]["entries"]:
        off = entry["target_file_offset"]
        w, h, ax, ay = data[off + 2:off + 6]
        image = Image.new("RGBA", (w, h))
        for piece in entry["record"]["sub_pieces"]:
            plane = planes[piece["slot_delta"]]
            tile = piece["tile"]
            # Field800C3EF0 uses raw extents; S1 battle quads interpret these as size-minus-one.
            pw, ph = piece["width_minus_one"], piece["height_minus_one"]
            ox, oy = (tile & 15) * 8, (tile >> 4) * 8
            if ox + pw > 128 or oy + ph > 128 or piece["palette_delta"] != 0:
                raise ValueError("unsupported Hero sprite sampling")
            if piece["x_offset"] + pw > w or piece["y_offset"] + ph > h:
                raise ValueError("Hero piece exceeds pose bounds")
            part = Image.new("RGBA", (pw, ph))
            for py in range(ph):
                for px in range(pw):
                    index = plane[(oy + py) * 128 + ox + px]
                    if index >= len(palette):
                        raise ValueError("Hero index outside palette")
                    word = palette[index]
                    part.putpixel((px, py), (*rgb555_to_rgb888(word), 0 if word == 0 else 255))
            flags = piece["flags"]
            if flags & ~3:
                raise ValueError("unsupported Hero reflection flags")
            if flags & 2:
                part = part.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
            if flags & 1:
                part = part.transpose(Image.Transpose.FLIP_TOP_BOTTOM)
            image.alpha_composite(part, (piece["x_offset"], piece["y_offset"]))
        poses.append({"rect": atlas.add(image), "anchor_x": ax, "anchor_y": ay})
    clips = []
    for direction, entry in zip(DIRECTIONS, section["f"]["entries"], strict=True):
        pairs = entry["sequence"]["pairs"]
        flags = entry["sequence"]["flags"]
        if flags & ~3:
            raise ValueError("unsupported field clip flags")
        clips.append({"direction": direction, "idle_frame": 1 if len(pairs) > 1 else 0,
                      **({'flags': flags} if flags != 3 else {}), "frames": [
            {**poses[index], "ticks": duration or 256} for index, duration in pairs]})
    return clips, {"section": section["file_offset"], "palette": po,
                   "poses": [e["target_file_offset"] for e in section["e"]["entries"]],
                   "animations": [e["target_file_offset"] for e in section["f"]["entries"]]}


def doorway(data, room, index, expected_prefix):
    entry = scene.entities(data, scene.room_record(data, room))[index]
    predicate, stream = entry["stream_offsets"][1:]
    p = data[predicate:predicate + 7]
    if p[0] != 11 or p[3] != 12 or p[6] not in (4, 6):
        raise ValueError("unsupported doorway predicate")
    direction = None
    if p[6] == 4:
        if data[predicate + 7:predicate + 9] != bytes((0, 6)):
            raise ValueError("unsupported doorway input condition")
        direction = "up"  # MAIN80171708[0] = 0x1000, the up input mask.
    if data[stream:stream + len(expected_prefix)] != expected_prefix:
        raise ValueError("doorway script changed")
    cursor = stream + len(expected_prefix)
    op, target, x, y, end = data[cursor:cursor + 5]
    if op != 3 or end != 253 or target not in ROOM_IDS:
        raise ValueError("unsupported doorway destination")
    return {"x": p[1] * 8, "y": p[4] * 8, "w": (p[2] - p[1] + 1) * 8,
            "h": (p[5] - p[4] + 1) * 8, "room": ROOM_IDS[target],
            "spawn_x": x * 8, "spawn_y": y * 8, "direction": direction}, {"entry": entry["offset"],
            "predicate": predicate, "stream": stream}


def village_content(data):
    rec = scene.room_record(data, 0)
    entries = scene.entities(data, rec)
    table = scene.ptr_at(data, rec["record_off"] + 12)
    npcs, proof = [], []
    for index, name, layout, text_index in ((8, "elf_witness", 1, 0), (9, "forest_villager", 2, 1)):
        entry = entries[index]
        classification, predicate, stream = entry["stream_offsets"]
        if (data[classification] != 6 or data[predicate:predicate + 2] != b"\x05\x06"
                or data[stream:stream + 8] != bytes((11, layout, 4, 0, text_index, 2, 12, 253))):
            raise ValueError("village NPC needs a new visibility/dialogue contract")
        text_offset = scene.ptr_at(data, table + text_index * 4)
        text, _ = decode(data, text_offset)
        if any(token in text for token in ("<", "\\x")):
            raise ValueError("unsupported village dialogue control")
        npcs.append({"id": name, "name": "Villager", "x": entry["x_half"] * 8,
                     "y": entry["y_half"] * 8, "pages": [p.strip() for p in text.split("[---]")]})
        proof.append({"id": name, "entry": entry["offset"], "entity": index,
                      "classification": classification, "predicate": predicate,
                      "stream": stream, "text_index": text_index, "text_offset": text_offset})
    entry = entries[1]
    predicate, stream = entry["stream_offsets"][1:]
    if (data[predicate:predicate + 7] != bytes.fromhex("0b 1c 25 0c 2d 2d 06")
            or data[stream:stream + 9] != bytes.fromhex("09 27 10 03 fb 01 56 55 fd")):
        raise ValueError("village south exit needs a new event contract")
    event = {"id": "village_south_exit", "name": "Village south exit",
             "x": data[predicate + 1] * 8, "y": data[predicate + 4] * 8,
             "w": (data[predicate + 2] - data[predicate + 1] + 1) * 8,
             "h": (data[predicate + 5] - data[predicate + 4] + 1) * 8,
             "flag": "village_south_exit_reached",
             "pages": ["You reached the village's south exit.\nProgress recorded.\nWorld travel is not available yet."]}
    event_proof = {"entry": entry["offset"], "predicate": predicate, "stream": stream,
                   "persistent_write": {"opcode": 9, "index": 39, "mask": 16,
                                        "consumer": "0x8013CBBC"},
                   "port_choices": ["named flag records the original persistent write without claiming its wider story meaning",
                                    "one-time authored message replaces the unimplemented world-map transition",
                                    "the message is port-authored text, not disc dialogue"]}
    return npcs, event, {"npcs": proof, "event": event_proof,
                          "excluded_entity": 7, "exclusion_reason": "conditional elf scene requires additional story and party state"}


def export(output):
    output = Path(output)
    if ROOT / "kit/work/accepted" in (output.resolve(), *output.resolve().parents):
        raise ValueError("export candidates outside the accepted tree")
    output.mkdir(parents=True, exist_ok=True)
    data, area_source = source("/VB6.BIN")
    hero, hero_source = source("/SHU.BIN")
    atlas = Atlas()
    clips, hero_proof = hero_clips(hero, atlas)
    package = {"schema": "suikoden-room/4", "atlas": "atlas.png", "cell_size": 8,
               "start_room": "vb6_inn", "start_x": 248, "start_y": 208,
               "step_ticks": 6, "interaction_offsets": [
                   {"x": 0, "y": 16}, {"x": 0, "y": -8},
                   {"x": -8, "y": 0}, {"x": 16, "y": 0}],
               "player_clips": clips, "rooms": []}
    proof = {"schema": "suikoden-room-provenance/1", "sources": [area_source, hero_source],
             "decoder": "lzss.py v2.0.0 strict", "container_parser": PARSER_VERSION,
             "scene_parser": "area_scene.py", "hero": hero_proof, "rooms": [],
             "port_choices": ["six 60Hz ticks per 8px step", "fixed NPC poses",
                 "service rules are separate semantic exports embedded in the executable",
                 "ground level only", "ground actor depth uses the independently checked native Y rule",
                 "village return doorway omits visual/party setup prefix",
                 "NPC occupancy uses fixed source positions; NPC movement is outside this slice",
                 "user-requested mattress access: six authored origin rectangles override base occupancy; native ground draw depth is retained",
                 "village inn raised front strip is blocked for this ground-only actor renderer",
                 "village entity7's conditional elf scene and remaining doorways omitted"]}
    village_npcs, village_event, village_proof = village_content(data)
    proof["village"] = village_proof
    for number, room_id in ROOM_IDS.items():
        rec = scene.room_record(data, number)
        sec = scene.section_off(data, rec["section"])
        if frame_table(data, sec):
            raise ValueError("animated scenery needs clips before exporting this room")
        vram, materials = scene.load_scene_materials(data, sec, area_source)
        preview, prims, meta = scene.scene_compose(data, number, vram,
                                                npc_entities={8, 9} if number == 0 else None)
        if meta["scenery"]["unresolved"] or meta["npc"]["unresolved"]:
            raise ValueError(f"unresolved scene {number}")
        preview.save(output / f"{room_id}_review.png")
        depth_origin = scene.GROUND_DEPTH_ORIGIN
        draws = []
        for key, section in (("primary", sec), ("secondary", scene.section_off(data, rec["byte9"]))):
            layer = meta[key]
            codes = struct.unpack_from(f'<{layer["w"] * layer["h"]}H', data, layer["offset"])
            mats = scene.load_map_materials(data, section, set(codes))
            image, _ = scene.map_layer_image(data, layer["offset"], layer["w"], layer["h"], mats, rgb555_to_rgb888,
                                             semi_transparent=key == "secondary")
            draws.append({"rect": atlas.add(image), "x": 0, "y": 0,
                          "depth": depth_origin - layer["tag"]})
        for p in prims:
            image = scene._prim_to_tile(p, rgb555_to_rgb888)
            if image is not None:
                draws.append({"rect": atlas.add(image), "x": p["left"], "y": p["top"],
                              "depth": depth_origin - p["tag"]})
        width, height, walkable = walkable_grid(data, sec)
        door, door_proof = doorway(data, number, 2 if number == 0 else 0,
                                   bytes.fromhex("11 80 00 0e 0a 02") if number == 0 else b"")
        room = {"id": room_id, "title": {7: "VB6 inn", 0: "VB6 village", 9: "VB6 item shop"}[number],
                "width": width * 8, "height": height * 8, "walkable": walkable,
                "draws": draws, "npcs": [], "exits": [door]}
        if number == 7:
            # shortcut: fixed NPC poses; add actor movement/state when the story slice needs it.
            entries = scene.entities(data, rec)
            if any(data[e["stream_offsets"][0]] != 6 for e in (entries[1], entries[3])):
                raise ValueError("conditional NPCs need explicit state selection")
            proxy = entries[2]
            stream = proxy["stream_offsets"][2]
            if data[stream:stream + 6] != bytes.fromhex("17 00 1c 01 01 2c"):
                raise ValueError("innkeeper greeting script changed")
            tables = scene.ptr_at(data, scene.root(data) + 20)
            table = scene.ptr_at(data, tables + 4)
            text_offset = scene.ptr_at(data, table + 44 * 4)
            text, _ = decode(data, text_offset)
            if any(token in text for token in ("<", "\\x")):
                raise ValueError("unhandled dialogue control")
            room["npcs"] = [{"id": "innkeeper", "name": "Innkeeper", "x": proxy["x_half"] * 8,
                "y": proxy["y_half"] * 8, "pages": [p.strip() for p in text.split("[---]")]}]
            patron = entries[3]
            patron_stream = patron["stream_offsets"][2]
            if data[patron_stream:patron_stream + 8] != bytes.fromhex("0b 01 04 00 02 02 0c fd"):
                raise ValueError("patron dialogue script changed")
            local_table = scene.ptr_at(data, rec["record_off"] + 12)
            patron_text = scene.ptr_at(data, local_table + 2 * 4)
            text, _ = decode(data, patron_text)
            if any(token in text for token in ("<", "\\x")):
                raise ValueError("unhandled patron dialogue control")
            room["npcs"].append({"id": "patron", "name": "Patron", "x": patron["x_half"] * 8,
                                 "y": patron["y_half"] * 8, "pages": [p.strip() for p in text.split("[---]")]})
            # The visible innkeeper and patron occupy the same 8px origins as source entities.
            for e in (entries[1], entries[3]):
                for cy in (e["y_half"] - 1, e["y_half"]):
                    for cx in (e["x_half"] - 1, e["x_half"], e["x_half"] + 1):
                        offset = cy * width + cx
                        walkable = walkable[:offset] + "0" + walkable[offset + 1:]
            room["walkable"] = walkable
            access = mattress_access(data, sec)
            cells = list(walkable)
            for surface in access:
                for cy in range(surface["y"] // 8, (surface["y"] + surface["h"]) // 8):
                    for cx in range(surface["x"] // 8, (surface["x"] + surface["w"]) // 8):
                        cells[cy * width + cx] = "1"
            room["walkable"] = "".join(cells)
            proof["mattress_access"] = {"provenance": "authored port behavior requested by user; not an original-game collision claim",
                                       "source": "six type20 bed positions", "regions": access}
            proof["dialogue"] = {"entry": proxy["offset"], "script": stream,
                                  "table": 1, "index": 44, "text_offset": text_offset}
            proof["patron_dialogue"] = {"entry": patron["offset"], "script": patron_stream,
                                       "room_text_index": 2, "text_offset": patron_text}
        elif number == 0:
            shop_door, shop_door_proof = doorway(data, 0, 4, bytes.fromhex("11 80 00 0e 0a 02"))
            room["exits"].append(shop_door)
            proof["shop_entrance"] = shop_door_proof
            room["npcs"] = village_npcs
            room["events"] = [village_event]
            cells = list(walkable)
            for npc in village_npcs:
                for cy in (npc["y"] // 8 - 1, npc["y"] // 8):
                    for cx in (npc["x"] // 8 - 1, npc["x"] // 8, npc["x"] // 8 + 1):
                        cells[cy * width + cx] = "0"
            frontage, proof["inn_frontage"] = inn_frontage_blockers(data, sec)
            for origin in frontage:
                cells[origin["y"] // 8 * width + origin["x"] // 8] = "0"
            room["walkable"] = "".join(cells)
        else:
            entries = scene.entities(data, rec)
            merchant, proxy = entries[1:3]
            if data[merchant["stream_offsets"][0]] != 6 or data[proxy["stream_offsets"][2]:proxy["stream_offsets"][2] + 4] != bytes.fromhex("43 02 00 fd"):
                raise ValueError("shopkeeper service changed")
            context = scene.ptr_at(data, scene.ptr_at(data, scene.root(data) + 16) + 12)
            greeting_offset = scene.ptr_at(data, context + 4)
            greeting, _ = decode(data, greeting_offset)
            room["npcs"] = [{"id": "shopkeeper", "name": "Shopkeeper", "x": proxy["x_half"] * 8,
                             "y": proxy["y_half"] * 8, "pages": [greeting]}]
            cells = list(walkable)
            for cy in (merchant["y_half"] - 1, merchant["y_half"]):
                for cx in (merchant["x_half"] - 1, merchant["x_half"], merchant["x_half"] + 1):
                    cells[cy * width + cx] = "0"
            room["walkable"] = "".join(cells)
            proof["shop"] = {"visible_entity": merchant, "interaction_proxy": proxy,
                              "context_offset": context, "greeting_offset": greeting_offset,
                              "omissions": ["entry3 scripted actor sequence"]}
        package["rooms"].append(room)
        proof["rooms"].append({"room": number, "record": rec, "section": sec,
                               "composition": meta, "materials": materials, "doorway": door_proof})
    atlas.save(output / "atlas.png")
    for name, value in (("room.json", package), ("provenance.json", proof)):
        (output / name).write_text(json.dumps(value, indent=2) + "\n")
    sheet = Image.new("RGB", (512, 260), (24, 28, 36))
    draw = ImageDraw.Draw(sheet)
    for row, clip in enumerate(clips):
        draw.text((4, row * 64 + 24), clip["direction"], fill="white")
        for col, frame in enumerate(clip["frames"]):
            r = frame["rect"]
            image = atlas.image.crop((r["x"], r["y"], r["x"] + r["w"], r["y"] + r["h"]))
            sheet.paste(image, (100 + col * 88, row * 64), image)
    sheet.save(output / "hero_review.png")
    animated = []
    for phase in range(4):
        image = Image.new("RGB", (512, 128), (24, 28, 36))
        draw = ImageDraw.Draw(image)
        for column, clip in enumerate(clips):
            draw.text((column * 128 + 40, 8), clip["direction"], fill="white")
            frame = clip["frames"][phase]
            r = frame["rect"]
            pose = atlas.image.crop((r["x"], r["y"], r["x"] + r["w"], r["y"] + r["h"]))
            image.paste(pose, (column * 128 + 56 - frame["anchor_x"], 88 - frame["anchor_y"]), pose)
        animated.append(image)
    durations = [round(frame["ticks"] * 1000 / 60) for frame in clips[0]["frames"]]
    animated[0].save(output / "hero_walk_review.gif", save_all=True, append_images=animated[1:],
                     duration=durations, loop=0, disposal=2)
    return package


def restore_reviewed(output):
    """Restore only the exact package already accepted in the tracked receipt."""
    receipt = json.loads((ROOT / "game/assets/first_room_review.json").read_text())
    content = {}
    for name, expected in receipt["runtime_files"].items():
        if name not in ("room.json", "atlas.png", "provenance.json"):
            raise ValueError("unsupported review-receipt filename")
        value = (Path(output) / name).read_bytes()
        if hashlib.sha256(value).hexdigest() != expected:
            raise ValueError(f"{name} differs from the reviewed package; retain as a candidate")
        content[name] = value
    if set(content) != {"room.json", "atlas.png", "provenance.json"}:
        raise ValueError("incomplete review receipt")
    accepted = ROOT / "kit/work/accepted/first_room"
    if accepted.exists():
        if any(not (accepted / name).is_file() or (accepted / name).read_bytes() != value for name, value in content.items()):
            raise ValueError("existing accepted package differs; refusing to overwrite it")
        return accepted
    accepted.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".first_room-", dir=accepted.parent) as tmp:
        staging = Path(tmp) / "package"
        staging.mkdir()
        for name, value in content.items():
            (staging / name).write_bytes(value)
        (staging / "review.json").write_text(json.dumps(receipt, indent=2) + "\n")
        staging.rename(accepted)
    return accepted


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=ROOT / "kit/work/build/first_room")
    parser.add_argument("--restore-reviewed", action="store_true", help="restore only bytes matching the existing user review receipt")
    args = parser.parse_args()
    if args.restore_reviewed:
        print(f"Reviewed package restored: {restore_reviewed(args.out)}")
    else:
        result = export(args.out)
        print(f'Exported {len(result["rooms"])} rooms to {args.out}; candidate only')

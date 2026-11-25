#!/usr/bin/env python3
"""Export disc-derived region and area field BGM WAVs and room routing manifest."""
from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path
import struct
import sys

ROOT = Path(__file__).resolve().parents[2]
TOOLS = ROOT / "kit/tools"
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

import area_scene  # noqa: E402
from dot8_audio import CHUNK, resources  # noqa: E402
from export_first_room import source as disc_source  # noqa: E402
import export_opening_audio  # noqa: E402
import maindec  # noqa: E402
from jukebox_music import AUTHORED, attach_playlist, playlist_indices  # noqa: E402

SCHEMA = "suikoden-region-bgm/1"

REGION_FALLBACK = {
    "a": 5,   # AREAA_1.8
    "b": 12,  # AREAB_1.8
    "c": 15,  # AREAC_1.8
    "d": 18,  # AREAD_1.8
    "e": 22,  # AREAE_1.8
    "f": 25,  # AREAF_1.8
    "g": 26,  # AREAG_1.8
    "h": 27,  # AREAI_1.8
    "i": 27,  # AREAI_1.8
    "j": 12,  # AREAB_1.8
    "k": 18,  # AREAD_1.8
    "s": 5,   # AREAA_1.8
    "z": 4,   # SHIRO1.8
}


def export(output: Path) -> dict:
    """Export disc region BGM tracks into <output>/bgm and write region_bgm.json."""
    import export_opening_field_package as fpkg

    output = Path(output).resolve()
    accepted = (ROOT / "kit/work/accepted").resolve()
    if output == accepted or accepted in output.parents:
        raise ValueError("candidate output cannot be accepted staging")
    output.mkdir(parents=True, exist_ok=True)
    bgm_dir = output / "bgm"
    bgm_dir.mkdir(parents=True, exist_ok=True)

    rows = {r["index"]: r for r in resources()}
    main_b = maindec.body()
    tbl = 0x80171C2C - maindec.MBASE

    sel_to_bgm: dict[int, int] = {}
    for sel in range(256):
        req = struct.unpack_from("<H", main_b, tbl + sel * 2)[0]
        idx = req - 0x400
        if 0x401 <= req <= 0x445 and idx in rows:
            path = rows[idx]["path"]
            if "CDSE" not in path and idx <= 28:
                sel_to_bgm[sel] = idx

    cache: dict[str, bytes] = {}
    area_counts: dict[str, Counter[int]] = {}
    area_rooms: dict[str, list[str]] = {}
    for fname, rnum, rid in fpkg.OPENING_ROOMS:
        area = rid.split("_room_")[0]
        area_rooms.setdefault(area, []).append(rid)
        if area in ("vaa", "va1"):
            continue
        if fname not in cache:
            cache[fname] = disc_source(fname)[0]
        data = cache[fname]
        for ent in area_scene.entities(data, area_scene.room_record(data, rnum)):
            for slot in (0, 2):
                off = ent["stream_offsets"][slot]
                if off is None or off >= len(data):
                    continue
                try:
                    ops = fpkg.decode_stream(data, off)
                except Exception:
                    continue
                for _, op, opnd, _ in ops:
                    if op == 0x41 and opnd and opnd[0] in sel_to_bgm:
                        area_counts.setdefault(area, Counter())[sel_to_bgm[opnd[0]]] += 1

    room_assignments: list[dict[str, str]] = []
    needed_indices: set[int] = set()

    for area in sorted(area_rooms):
        if area in ("vaa", "va1"):
            continue
        reg = area[1] if len(area) >= 2 else "a"
        idx = (
            area_counts[area].most_common(1)[0][0]
            if area in area_counts
            else REGION_FALLBACK.get(reg, 5)
        )
        needed_indices.add(idx)
        tid = f"track_{idx:02d}"
        for rid in area_rooms[area]:
            room_assignments.append({"room": rid, "track": tid})

    for reg, idx in sorted(REGION_FALLBACK.items()):
        if reg in ("a", "i", "s"):
            continue
        needed_indices.add(idx)
        room_assignments.append({"room": f"world_{reg}", "track": f"track_{idx:02d}"})

    tracks: list[dict] = []
    needed_indices.update(playlist_indices())
    for idx in sorted(needed_indices.difference(AUTHORED)):
        row = rows[idx]
        tid = f"track_{idx:02d}"
        rel_path = f"bgm/{tid}.wav"
        wav_path = bgm_dir / f"{tid}.wav"
        size = row["end_sector"] * 2048
        frames = size // (CHUNK * 2) * (CHUNK // 16 * 28)
        loop = row["loop_sector"] // 16 * (CHUNK // 16 * 28)
        expected_bytes = frames * 4 + 44
        if wav_path.is_file() and wav_path.stat().st_size == expected_bytes:
            track = {
                "id": tid,
                "path": rel_path,
                "sample_rate": row["rate"],
                "frames": frames,
                "loop_start_frame": loop,
                "volume": row["volume"],
                "source_index": idx,
                "source_path": row["path"],
            }
        else:
            exported, _ = export_opening_audio.export_resource(bgm_dir, tid, row)
            exported["path"] = rel_path
            exported["source_index"] = idx
            exported["source_path"] = row["path"]
            track = exported
        tracks.append(track)

    manifest = {
        "schema": SCHEMA,
        "tracks": tracks,
        "rooms": sorted(room_assignments, key=lambda r: r["room"]),
    }
    attach_playlist(output, manifest)
    (output / "region_bgm.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "out",
        nargs="?",
        type=Path,
        default=ROOT / "kit/work/build/canonical/audio",
    )
    args = parser.parse_args()
    manifest = export(args.out)
    print(f"Exported {len(manifest['tracks'])} region BGM tracks for {len(manifest['rooms'])} rooms")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

"""Compact candidate actor atlases without changing sampled pixels or pose geometry."""
import copy
import hashlib
import json
from pathlib import Path

from PIL import Image
from export_first_room import Atlas, ROOT


def repack(content, image):
    if image.mode != 'RGBA' or not 0 < image.width <= 4096 or not 0 < image.height <= 4096:
        raise ValueError('invalid actor atlas dimensions or pixel format')
    result = copy.deepcopy(content)
    poses = []
    rectangles = {}

    def visit(value):
        if isinstance(value, list):
            for child in value:
                visit(child)
        elif isinstance(value, dict):
            if {'rect', 'anchor_x', 'anchor_y'} <= value.keys():
                rect = value['rect']
                if not isinstance(rect, dict) or set(rect) != {'x', 'y', 'w', 'h'} or any(type(rect[k]) is not int for k in rect):
                    raise ValueError('invalid actor pose rectangle')
                x, y, w, h = key = tuple(rect[k] for k in ('x', 'y', 'w', 'h'))
                if x < 0 or y < 0 or w <= 0 or h <= 0 or x+w > image.width or y+h > image.height:
                    raise ValueError('actor pose rectangle outside atlas')
                poses.append((value, key))
                rectangles.setdefault(key, None)
            for child in value.values():
                visit(child)

    visit(result)
    if not poses:
        raise ValueError('actor atlas has no pose references')
    bitmaps = {}
    for key in rectangles:
        x, y, w, h = key
        pixels = image.crop((x, y, x+w, y+h))
        identity = (w, h, pixels.tobytes())
        if identity not in bitmaps:
            bitmaps[identity] = dict(image=pixels, sha256=hashlib.sha256(identity[2]).hexdigest())
        rectangles[key] = bitmaps[identity]
    atlas = Atlas()
    atlas.image = Image.new('RGBA', (image.width, 4096))
    try:
        for bitmap in sorted(bitmaps.values(), key=lambda row: (-row['image'].height, -row['image'].width, row['sha256'])):
            bitmap['rect'] = atlas.add(bitmap['image'])
    except ValueError:
        # Overlapping source rectangles can require more space as separate bitmaps.
        return result, image.copy(), None
    height = max(row['rect']['y']+row['rect']['h'] for row in bitmaps.values())
    if height >= image.height:
        return result, image.copy(), None
    packed = atlas.image.crop((0, 0, image.width, height))
    for pose, key in poses:
        pose['rect'] = dict(rectangles[key]['rect'])
    proof = dict(producer='battle_actor_atlas.py v1', input_size=list(image.size), output_size=list(packed.size),
        input_rgba_sha256=hashlib.sha256(image.tobytes()).hexdigest(),
        output_rgba_sha256=hashlib.sha256(packed.tobytes()).hexdigest(),
        pose_references=len(poses), source_rectangles=len(rectangles), unique_bitmaps=len(bitmaps),
        rectangles=[dict(source=dict(zip(('x', 'y', 'w', 'h'), key)), destination=row['rect'], rgba_sha256=row['sha256'])
                    for key, row in sorted(rectangles.items())])
    return result, packed, proof


def compact_package(folder, stage):
    folder = Path(folder).resolve()
    accepted = (ROOT/'kit/work/accepted').resolve()
    if accepted in (folder, *folder.parents):
        raise ValueError('actor atlas packing cannot write accepted staging')
    if any((folder/name).is_symlink() for name in ('trial.json', 'actors.png', 'provenance.json')):
        raise ValueError('actor atlas candidate contains a symlink')
    content = json.loads((folder/'trial.json').read_text())
    if content['atlas'] != 'actors.png':
        raise ValueError('unsupported actor atlas path')
    proof_path = folder/'provenance.json'
    provenance = json.loads(proof_path.read_text())
    with Image.open(folder/'actors.png') as source:
        content, image, proof = repack(content, source.convert('RGBA'))
    if proof is None:
        return None
    proof['stage'] = stage
    provenance.setdefault('actor_atlas_packing', []).append(proof)
    image.save(folder/'actors.png')
    (folder/'trial.json').write_text(json.dumps(content, separators=(',', ':'))+'\n')
    proof_path.write_text(json.dumps(provenance, indent=2)+'\n')
    return proof

"""Bind an existing regional battlefield candidate to matching Journey formations."""

import json
from pathlib import Path

from PIL import Image

from bundle_macos import digest
from check_journey_package import check_battlefield_assets, rect_ok
from export_first_room import Atlas


def append(candidate: Path, source: Path) -> None:
    """Import resources into an unpublished assembly directory."""
    manifest = json.loads((source / 'manifest.json').read_text())
    files = manifest.get('files')
    if manifest.get('schema') != 'suikoden-world-actor-manifest/1' or not isinstance(files, dict):
        raise ValueError('unsupported battlefield source manifest')
    names = ('trial.json', 'ground.png', 'actors.png', 'provenance.json')
    for name in names:
        path = source / name
        if not path.is_file() or path.is_symlink() or digest(path) != files.get(name):
            raise ValueError(f'battlefield source hash/path mismatch: {name}')
    region = json.loads((source / 'provenance.json').read_text())
    if region.get('schema') != 'suikoden-world-actor-proof/1':
        raise ValueError('unsupported battlefield source provenance')
    field_id = region.get('region')
    if not isinstance(field_id, str) or not 1 <= len(field_id) <= 128:
        raise ValueError('invalid region id in battlefield source')
    overlay = json.loads((source / 'trial.json').read_text())
    if not overlay.get('ground') or overlay.get('battlefields'):
        raise ValueError(f'{field_id}: source must have one regional ground layout')

    battle = candidate / 'battle'
    trial = json.loads((battle / 'trial.json').read_text())
    if trial['schema'] not in ('suikoden-battle-trial/43', 'suikoden-battle-trial/44', 'suikoden-battle-trial/45', 'suikoden-battle-trial/46'):
        raise ValueError('battlefield import requires battle trial schema 43 through 46')
    fields = trial.setdefault('battlefields', [])
    if any(entry['id'] == field_id for entry in fields):
        raise ValueError(f'duplicate battlefield {field_id}')
    proven = {entry['id']: entry for entry in overlay['encounters']}
    if not proven or len(proven) != len(overlay['encounters']) or set(proven) != set(region['encounters']):
        raise ValueError(f'{field_id}: battlefield source encounter inventory disagrees')
    matches = [entry for entry in trial['encounters'] if entry['id'] in proven]
    if len(matches) != len(proven) or {entry['id'] for entry in matches} != set(proven):
        raise ValueError(f'{field_id}: battlefield source encounters are missing from Journey')
    identity = ('enemies', 'source_slots', 'positions', 'enemy_rows')
    for entry in matches:
        if entry.get('battlefield') is not None or any(entry[key] != proven[entry['id']][key] for key in identity):
            raise ValueError(f'{field_id}: incompatible Journey formation {entry["id"]}')

    with Image.open(battle / 'ground.png') as current, Image.open(source / 'ground.png') as terrain:
        w, h = terrain.size
        if not w <= current.width <= 4096 or current.height + h > 4096 or any(side % 32 for side in current.size + terrain.size):
            raise ValueError(f'{field_id}: ground does not fit the shared atlas')
        ground = Image.new('RGBA', (current.width, current.height + h))
        ground.paste(current.convert('RGBA'), (0, 0))
        ground.paste(terrain.convert('RGBA'), (0, current.height))
        rect = dict(x=0, y=current.height, w=w, h=h)

    scenery = overlay['scenery']
    if scenery:
        if overlay.get('atlas') != 'actors.png' or trial.get('atlas') != 'actors.png':
            raise ValueError(f'{field_id}: unsupported scenery atlas path')
        with Image.open(battle / 'actors.png') as current, Image.open(source / 'actors.png') as regional:
            if current.width > 4096:
                raise ValueError(f'{field_id}: scenery does not fit the shared actor atlas')
            atlas = Atlas()
            atlas.image = Image.new('RGBA', (current.width, 4096))
            atlas.image.paste(current.convert('RGBA'), (0, 0))
            atlas.y = current.height
            for entry in scenery:
                sprite = entry['sprite']
                crop = sprite['rect']
                if not rect_ok(crop, *regional.size):
                    raise ValueError(f'{field_id}: scenery rectangle outside its source atlas')
                x, y, w, h = (crop[key] for key in ('x', 'y', 'w', 'h'))
                sprite['rect'] = atlas.add(regional.crop((x, y, x + w, y + h)).convert('RGBA'))
        atlas.save(battle / 'actors.png')

    for entry in matches:
        entry['battlefield'] = field_id
    fields.append(dict(id=field_id, ground=overlay['ground'], ground_atlas=rect, scenery=scenery))
    if trial['schema'] == 'suikoden-battle-trial/43':
        trial['schema'] = 'suikoden-battle-trial/44'
    ground.save(battle / 'ground.png')
    errors = []
    check_battlefield_assets(candidate, trial, errors)
    if errors:
        raise ValueError('; '.join(errors))
    (battle / 'trial.json').write_text(json.dumps(trial, separators=(',', ':')) + '\n')
    proof_path = battle / 'provenance.json'
    proof = json.loads(proof_path.read_text())
    proof.setdefault('battlefield_sources', []).append(dict(
        id=field_id, source=region['source'], manifest_sha256=digest(source / 'manifest.json'),
        inputs={name: files[name] for name in names},
        encounters=[entry['id'] for entry in matches]))
    proof_path.write_text(json.dumps(proof, indent=2) + '\n')

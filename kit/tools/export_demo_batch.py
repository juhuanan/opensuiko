#!/usr/bin/env python3
"""Export the twelve-demo systems suite; authored balance, decoded source art/tables."""
from pathlib import Path
import argparse
import copy
import json
import struct
import tempfile

from PIL import Image
import character_table
import exp_award
import growth_rules
import item_tables
import maindec
import q_residue
import export_battle_trial as trial
from export_first_room import ROOT, Atlas, source


def export(output, roster_override=None):
    output = Path(output).resolve()
    if ROOT / 'kit/work/accepted' in (output, *output.parents):
        raise ValueError('demo export cannot write accepted content')
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='suikoden-batch-export-') as temporary:
        legacy = Path(temporary)
        content = trial.export(legacy)
        origin = json.loads((legacy / 'provenance.json').read_text())
        atlas = Atlas()
        with Image.open(legacy / 'actors.png') as image:
            atlas.image.paste(image, (0, 0))
            atlas.y = image.height + 1
        for filename in ('floor.png', 'ground.png'):
            (output / filename).write_bytes((legacy / filename).read_bytes())
    _, template_origin = source('SLUS_002.92')
    origin['sources'].append(template_origin)
    records = {r['id']: r for r in character_table.records()}
    roster = [(8, 'hero', 'Hero', 100, 35, 23, 28, 24),
              (2, 'gremio', 'Gremio', 120, 31, 27, 24, 20),
              (6, 'pahn', 'Pahn', 150, 41, 28, 22, 18),
              (35, 'viktor', 'Viktor', 155, 44, 26, 21, 20),
              (3, 'camille', 'Camille', 105, 33, 24, 29, 26),
              (32, 'tai_ho', 'Tai Ho', 110, 36, 24, 28, 27)]
    if roster_override is not None: roster = roster_override
    for index, (native_id, stable_id, name, hp, attack, defense, skill, speed) in enumerate(roster):
        record = records[native_id]
        if index >= 2:
            data, provenance = source('/' + record['sprite_file'])
            origin['sources'].append(provenance)
            poses, animations, proof = trial.section_art(data, struct.unpack_from('<I', data, 36)[0])
            frames, motion = trial.attack_schedule(data, poses, animations, atlas)
            content['party'].append(dict(id=stable_id, name=name, max_hp=hp, level=5,
                stats=dict(attack=attack, defense=defense, skill=skill, speed=speed),
                sprite=trial.pack_pose(atlas, poses[animations[0][0][0]]),
                foot_offset_y=trial.foot_offset_y(poses[animations[0][0][0]]), attack=frames, motion=motion))
            origin['party'].append(dict(id=stable_id, **proof, idle_animation=0, attack_scripts=[1, 4]))
        profile = next(p for p in content['party'] if p['id'] == stable_id)
        profile['growth'] = record['growth']
        weapon_address = maindec.mword(0x80165890 + 4 * record['weapon_id'])
        range_code = maindec.body()[weapon_address - maindec.MBASE + 0x56]
        profile['weapon_range'] = {1: 'short', 2: 'long', 3: 'medium'}[range_code]
        origin.setdefault('weapon_ranges', {})[stable_id] = dict(
            weapon_id=record['weapon_id'], record_address=weapon_address, range_code=range_code,
            character_template_image_offset=record['off'])
        profile['stats']['magic'] = [35, 17, 9, 16, 33, 14][index]
        profile['stats']['luck'] = 20
    area = source('/A_DATA.BIN')[0]
    placements = trial.battle_placement.area_encounters(area)
    _, _, _, selectors = trial.encounters.chain(area)
    _, selected = trial.encounters.selectors_table(area, selectors)
    for encounter, source_number in zip(content['encounters'], (1, 2, 5)):
        address = selected[source_number - 1]
        flags = struct.unpack_from('<I', area, address - trial.encounters.BASE + 12)[0]
        encounter['escape_allowed'] = not bool(flags & 0x80000000)
        origin.setdefault('encounter_exit', []).append(dict(id=encounter['id'], record_address=address, flags=flags, gate='MAIN.EXE:0x800F8474..0x800F8488'))
        encounter['enemy_rows'] = ['front' if slot['slot'] < 3 else 'back'
                                   for slot in placements['encounters'][source_number - 1]['slots']]
    for index in range(6):
        encounter = copy.deepcopy(content['encounters'][index % 3])
        encounter['id'] = f'endurance_{index+4}'
        encounter['title'] = f'Endurance {index+4}: ' + encounter['title']
        content['encounters'].append(encounter)
    content['schema'] = 'suikoden-battle-trial/5'
    content['party_positions'] = content['formation_slots']
    # Leave headroom for every character's return leap in all six formation slots.
    content['camera']['focal_length'] *= 0.9
    content['sprite_scale'] *= 0.9
    origin['presentation']['framing_zoom'] = 0.72
    origin['presentation']['scale'] = 2
    data, _ = source('/A_DATA.BIN')
    _, _, directory, _ = trial.encounters.chain(data)
    ground, _ = trial.ground_tiles(data, directory)
    vertices, across, down, tiles = trial.visuals.battle_ground_mesh(data)
    pixels, mask = trial.visuals.render_ground(ground, vertices, across, down, tiles, H=trial.visuals.PROJ_H * 0.72, screen_offset=(0, 17))
    background = Image.new('RGB', trial.visuals.SCREEN)
    background.paste(pixels, (0, 0), mask)
    background.save(output / 'floor.png')
    for enemy in content['enemies']:
        enemy['stats']['magic'] = 9 if enemy['id'] == 'bonbon' else 0
        enemy['stats']['luck'] = 12 if enemy['id'] == 'bonbon' else 14
    names = item_tables.spell_names()
    specs = [(1, 'damage', False, False, 45), (2, 'damage', False, True, 30),
             (9, 'heal', True, False, 80), (11, 'heal', True, True, 80),
             (30, 'revive', True, False, 50), (15, 'cure', True, False, 80),
             (13, 'sleep', False, True, 2)]
    spells = [dict(id=f'spell_{i}', name=names[i-1], kind=kind, allies=allies,
                   group=group, power=power) for i, kind, allies, group, power in specs]
    spell_indices = {spec[0]: i for i, spec in enumerate(specs)}
    source_runes = item_tables.runes()
    runes = [dict(id=r['name'].removesuffix(' Rune').lower().replace(' ', '_'), name=r['name'],
                  spell_names=[names[s-1] if s else '-' for s in r['spell_ids']],
                  spells=[spell_indices.get(s) for s in r['spell_ids']]) for r in source_runes]
    for profile, entry in zip(content['party'], roster):
        native_rune = records[entry[0]]['rune_id']
        pointer = maindec.mword(0x8016A0E0 + 4 * native_rune) if native_rune else None
        profile['rune'] = next((rune['id'] for r, rune in zip(source_runes, runes) if r['addr'] == pointer), None)
        if native_rune and profile['rune'] is None:
            raise ValueError('initial rune is outside the exported rune records')
    thresholds = [list(maindec.body()[0x8016A60C - maindec.MBASE + i*9:0x8016A60C - maindec.MBASE + (i+1)*9]) for i in range(4)]
    gear = []
    for item in item_tables.items()[:2]:
        offset = item['addr'] - maindec.MBASE + 32
        bonuses = list(struct.unpack_from('<8b', maindec.body(), offset))
        gear.append(dict(id=item['name'].lower(), name=item['name'], bonuses=bonuses))
    unite = q_residue.unites()[0]
    assert unite['members'] == [6, 2] and unite['flags'] == 3
    content['systems'] = dict(spells=spells, runes=runes, magic_thresholds=thresholds, equipment=gear, stat_growth=growth_rules.stat_table(),
        hp_growth=growth_rules.hp_table(), experience=exp_award.xp_table(),
        unite=dict(name=unite['name'], members=['pahn', 'gremio'], power=2))
    origin['schema'] = 'suikoden-demo-batch-provenance/1'
    origin['exporter'] = 'export_demo_batch.py v7 + export_battle_trial.py v5'
    origin['rules'] = dict(character_templates='SLUS_002.92 template via character_table.py',
        weapon_ranges='MAIN.EXE weapon metadata +0x56, target builder 0x800EEC20; explicit short/medium/long and front/back rows',
        equipment='MAIN.EXE item records +32: eight signed equipment modifiers',
        growth='MAIN.EXE stat/HP tables via growth_rules.py; 1000 EXP per level',
        experience='MAIN.EXE level-difference table via exp_award.py',
        spells='MAIN.EXE spell names via item_tables.py; effect definitions below are prototype policies',
        runes='MAIN.EXE rune table: four ordered spell IDs per rune; initial character rune from SLUS template; spell menu 0x800EF67C independently checked',
        magic_capacity='MAIN.EXE 0x8016A60C: four nine-byte strict thresholds, refill 0x800CA60C',
        escape='MAIN.EXE 0x800EEF58 root labels and 0x800F8464 decision; relative average levels, encounter sign lock, rand%100 >= 51 against stronger enemies',
        talisman_damage='MAIN.EXE 0x800F98B8..C0 count2/multiplier20; 0x800F9488 sums both physical results, scales /10 and commits once',
        unite=unite)
    origin['port_choices'] = [
        'Six authored level-five profiles and repeatable scenario presets; source character identities and growth rates.',
        'Rune effect powers and poison tick remain prototype balance. Rune ownership/spell tiers and MGC-based capacity follow source rules. Rune demos explicitly assign a rune and raised MGC to named casters; other members retain template rune ownership.',
        'Talisman uses decoded Pahn/Gremio participants and individual target policy; twice-summed damage follows the source helper, while synchronized normal attack tracks remain prototype presentation.',
        'Run/Let go follows original relative-level and random decision rules; Bribe remains disabled and Free Will uses authored legal basic attacks.',
        'Two decoded headgear items are supplied by the test rack; full equipment restrictions, inventory varieties and rune attachment are deferred.',
        'Reward drop is an authored guaranteed Medicine for the demonstration, not an asserted native drop table.',
        'Source S1 art/timing, ground, scenery and camera are inherited from trial provenance; cast/status overlays are drawn prototype UI.',
        'Party foot_offset_y is derived from opaque idle pixels; flat ellipses follow the ground with perspective scaling, as port presentation rather than recovered original shadow geometry.',
        'This candidate suite never reads or writes field saves or accepted packages.']
    atlas.save(output / 'actors.png')
    for filename, value in [('trial.json', content), ('provenance.json', origin)]:
        (output / filename).write_text(json.dumps(value, indent=2) + '\n')
    return content


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, default=ROOT / 'kit/work/build/demo_batch')
    args = parser.parse_args()
    result = export(args.out)
    print(f'Exported twelve-demo candidate: {len(result["party"])} party members; no promotion')

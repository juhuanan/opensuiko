#!/usr/bin/env python3
"""Combine a canonical candidate and current battle export without changing either."""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile

from PIL import Image
import append_battlefield
from export_first_room import ROOT
import export_first_room
import battle_unite_camera
import bundle_macos
import character_table
import check_journey_package
import export_battle_sfx
import export_defeat_audio
import export_battle_audio
import export_battle_sprite_sections
import export_battle_trial
import export_opening_profiles
import export_party_ranged_actors
import export_physical_runes
import export_unite_review
import preparation
from room_battle_package import PATH as ROOM_BATTLE_PATH, bind_field_rooms, bind_room_events, object_rows

FIELD_ENCOUNTER_GROUPS = 'suikoden-field-encounter-groups/1'


def add_party_melee_assets(candidate):
    """Reuse source programs and matching atlas pixels for ordinary melee."""
    actors_path=candidate/'battle/unites.json';trial_path=candidate/'battle/trial.json'
    actors=json.loads(actors_path.read_text());trial=json.loads(trial_path.read_text())
    if 'party_melee' in actors['counter']:raise ValueError('party melee bindings already present')
    melee,proof=export_party_ranged_actors.build(melee=True,include_later=True)
    export_physical_runes.merge_libraries(actors,melee)
    actors['counter']['party_melee']=dict(attackers=melee['bindings'],dodges=melee['dodges'],critical_camera=melee['critical_camera'])
    supported={row['id'] for row in melee['bindings']+actors['counter']['ranged']['attackers']}
    missing={row['id'] for row in trial['party']}-supported
    if missing:raise ValueError('unbound source party basic attacks: '+', '.join(sorted(missing)))
    actors['schema']='suikoden-unite-actors/32' if actors.get('commander') is not None else 'suikoden-unite-actors/31'
    import export_spell_scenes
    required={instruction['command']['child']['animation'] for program in melee['programs']['programs'] for instruction in program['instructions'] if instruction.get('command',{}).get('child',{}).get('resource')=='shared_impacts'}
    impacts=export_spell_scenes.append_shared_impacts(candidate/'battle',required)
    spell_proof_path=candidate/'battle/spells.provenance.json'
    spell_proof=json.loads(spell_proof_path.read_text());spell_proof['party_melee_impacts']=impacts
    spell_proof_path.write_text(json.dumps(spell_proof,indent=2)+'\n')
    overlay=__import__('export_world_travel').battle_export('c')
    profiles=__import__('export_world_battle').c_actor_profiles(overlay,actors,trial['unite_graphics'])
    if {p['id'] for p in profiles}!={p['id'] for p in overlay['enemies']}:raise ValueError('incomplete C actor catalogue')
    if {p['id'] for p in profiles}&{p['id'] for p in trial['enemies']}:raise ValueError('duplicate C actor catalogue')
    trial['enemies'].extend(profiles)
    trial['encounters'].extend(copy.deepcopy(overlay['encounters']))
    trial['round_start']=copy.deepcopy(overlay['round_start'])
    ids={p['id'] for p in trial['party']+trial['enemies']}
    targets={p['id'] for p in trial['enemies']}
    roots=[(row['id'],row[role+'_program']) for row in melee['bindings'] if row['id'] in ids for role in ('attack','return')]
    roots.extend((target,row[role+'_program']) for row in melee['bindings'] if row['id'] in ids for target in targets for role in ('hurt','critical_hurt'))
    roots.extend((row['id'],row['response_program']) for row in melee['dodges'] if row['id'] in ids)
    origin=json.loads((candidate/'battle/provenance.json').read_text())['counter_actor_programs']
    resources={row['id']:row for row in origin['resources']}
    for row in proof['characters']+proof['targets']:resources.setdefault(row['id'],row['resource'])
    resources['shared_impacts']=proof['shared']
    atlas_path=candidate/'battle/actors.png'
    with Image.open(atlas_path) as previous:
        atlas=export_first_room.Atlas();atlas.image=Image.new('RGBA',(4096,4096));atlas.image.paste(previous,(0,0));atlas.y=previous.height
    graphics,graphic_proof=export_physical_runes.graphics(actors,dict(resources=list(resources.values())),atlas,ids & {r['id'] for r in actors['animations']['resources']}-{'shared_impacts'},roots,existing_graphics=trial['unite_graphics'])
    for graphic in graphics:
        current=next((g for g in trial['unite_graphics'] if g['id']==graphic['id'] and g.get('record') is None),None)
        if current is None:trial['unite_graphics'].append(graphic);continue
        poses={pose['id']:pose for pose in current['poses']}
        for pose in graphic['poses']:
            if pose['id'] not in poses:current['poses'].append(pose);continue
            for key,value in pose.items():
                if key=='sprite':key='ordinary'
                poses[pose['id']][key]=value
    atlas.save(atlas_path)
    actors_path.write_text(json.dumps(actors,separators=(',',':'))+'\n')
    trial_path.write_text(json.dumps(trial,separators=(',',':'))+'\n')
    return dict(actors=proof,graphics=graphic_proof,impacts=impacts,region_c=dict(source=export_first_room.source('/C_DATA.BIN')[1],encounters=[row['id'] for row in overlay['encounters']]))


def add_ranged_assets(candidate):
    actors_path = candidate / 'battle/unites.json'
    actors = json.loads(actors_path.read_text())
    ranged, proof = export_party_ranged_actors.build()
    if actors['schema'] != 'suikoden-unite-actors/19' or 'ranged' in actors['counter']:
        raise ValueError('unsupported battle actor library for ranged bindings')
    export_physical_runes.merge_libraries(actors, ranged)
    actors['schema'] = 'suikoden-unite-actors/21'
    actors['counter']['ranged'] = dict(attackers=ranged['bindings'], dodges=ranged['dodges'], critical_camera=ranged['critical_camera'])
    actors_path.write_text(json.dumps(actors, separators=(',', ':')) + '\n')
    trial_path = candidate / 'battle/trial.json'
    trial = json.loads(trial_path.read_text())
    selected = {'cleo', 'ted'}
    target_ids = {row['id'] for row in trial['enemies'] if row.get('dodges_attacks')}
    if not target_ids <= {row['id'] for row in ranged['dodges']}:
        raise ValueError('missing opening battle enemy dodge')
    atlas_path = candidate / 'battle/actors.png'
    with Image.open(atlas_path) as image:
        previous = image.convert('RGBA')
    if previous.width > 4096 or previous.height >= 4096:
        raise ValueError('opening ranged graphics exceed the runtime atlas')
    atlas = export_first_room.Atlas()
    atlas.image = Image.new('RGBA', (4096, 4096))
    atlas.image.paste(previous, (0, 0))
    atlas.y = previous.height + 1
    resources = {'resources': [row['resource'] for row in proof['characters'] + proof['targets']]}
    roots = [(row['id'], row[key]) for row in ranged['bindings'] if row['id'] in selected
             for key in ('attack_program', 'return_program')]
    roots += [(row['id'], row['response_program']) for row in ranged['dodges'] if row['id'] in target_ids]
    graphics, graphic_proof = export_physical_runes.graphics(ranged, resources, atlas, selected | target_ids, roots)
    existing = {row['id']: row for row in trial['unite_graphics'] if row.get('record') is None}
    for graphic in graphics:
        if graphic['id'] not in existing:
            trial['unite_graphics'].append(graphic)
        else:
            poses = {row['id'] for row in existing[graphic['id']]['poses']}
            existing[graphic['id']]['poses'].extend(row for row in graphic['poses'] if row['id'] not in poses)
    atlas.save(atlas_path)
    trial_path.write_text(json.dumps(trial, indent=2) + '\n')
    return actors, ranged['bindings'], proof, graphic_proof


def flash_attack(identifier, atlas):
    seed = next(row for row in character_table.records() if preparation.stable_id(row['name']) == identifier)
    raw, origin = export_first_room.source('/' + seed['sprite_file'])
    import journey_battle
    operations = journey_battle.script(raw, 1) + journey_battle.script(raw, 4)
    selected = sorted({0, *(args[0] for op, args in operations if op == 4)})
    poses, animations, _ = export_battle_trial.section_art(raw, struct.unpack_from('<I', raw, 36)[0], animation_indices=selected, selected_poses_only=True, axis_aligned_packet=identifier in ('humphrey','sonya'))
    attack, motion = export_battle_trial.attack_schedule(raw, poses, animations, atlas)
    return attack, motion, origin


def add_flash_assets(candidate, review, proof):
    """Add the source-qualified Flash scene and its review profiles."""
    members = ('liukan', 'fukien', 'kai')
    source = Path(review) / 'record_10'
    source_trial = json.loads((source / 'trial.json').read_text())
    source_actors = json.loads((source / 'unites.json').read_text())
    source_spells = json.loads((source / 'spells.json').read_text())
    trial_path = candidate / 'battle/trial.json'
    actors_path = candidate / 'battle/unites.json'
    spells_path = candidate / 'battle/spells.json'
    spells_proof_path = candidate / 'battle/spells.provenance.json'
    trial = json.loads(trial_path.read_text())
    actors = json.loads(actors_path.read_text())
    spells = json.loads(spells_path.read_text())
    spells_proof = json.loads(spells_proof_path.read_text())
    source_spells_proof = json.loads((Path(review) / 'shared/provenance.json').read_text())
    if (actors['schema'] != 'suikoden-unite-actors/21' or spells['schema'] != 'suikoden-spell-scenes/46'
            or source_actors['schema'] not in ('suikoden-unite-actors/22', 'suikoden-unite-actors/23', 'suikoden-unite-actors/24', 'suikoden-unite-actors/26', 'suikoden-unite-actors/27', 'suikoden-unite-actors/28', 'suikoden-unite-actors/29') or source_spells['schema'] not in ('suikoden-spell-scenes/47', 'suikoden-spell-scenes/48', 'suikoden-spell-scenes/49', 'suikoden-spell-scenes/50', 'suikoden-spell-scenes/51')):
        raise ValueError('unsupported battle schemas for Flash')
    if set(members) & {profile['id'] for profile in trial['party']}:
        raise ValueError('Flash member profile already present')
    if set(members) & {graphic['id'] for graphic in trial['unite_graphics']}:
        raise ValueError('Flash member graphics already present')
    binding = next(row for row in source_actors['unites'] if row['record'] == 10)
    current = next(row for row in actors['unites'] if row['record'] == 10)
    if {key: value for key, value in binding.items() if key not in ('dispatch_after', 'controller')} != current:
        raise ValueError('Flash source actor binding differs')
    for member in binding['members']:
        for name in (*member['programs'], binding['return_program']):
            actual = next(row for row in actors['programs']['programs'] if row['id'] == name)
            expected = next(row for row in source_actors['programs']['programs'] if row['id'] == name)
            if actual != expected:
                raise ValueError('Flash actor program differs: ' + name)
        actual = next(row for row in actors['animations']['resources'] if row['id'] == member['id'])
        expected = next(row for row in source_actors['animations']['resources'] if row['id'] == member['id'])
        clips = {clip['id']: clip for clip in actual['clips']}
        if any(clips.get(clip['id']) != clip for clip in expected['clips']):
            raise ValueError('Flash actor animations differ: ' + member['id'])
    actors['unites'][actors['unites'].index(current)] = binding
    actors['schema'] = 'suikoden-unite-actors/22'

    scene = next(row for row in source_spells['unite_scenes'] if row['id'] == 'flash')
    if any(row['id'] == 'flash' for row in spells['unite_scenes']):
        raise ValueError('Flash scene already present')
    if any(sample.get('piece') is not None for track in scene['program']['tracks'] for sample in track):
        raise ValueError('Flash scene needs a spell atlas binding')
    spells['unite_scenes'].append(scene)
    spells['schema'] = 'suikoden-spell-scenes/47'
    extra = next(row for row in source_spells_proof['extra_unite_scenes'] if row['id'] == 'flash')
    if spells_proof.get('extra_unite_scenes'):
        raise ValueError('unexpected existing extra Unite scene provenance')
    spells_proof['extra_unite_scenes'] = [extra]

    atlas_path = candidate / 'battle/actors.png'
    with Image.open(atlas_path) as image:
        previous = image.convert('RGBA')
    if previous.width > 4096 or previous.height >= 4096:
        raise ValueError('Flash graphics exceed the runtime atlas')
    atlas = export_first_room.Atlas()
    atlas.image = Image.new('RGBA', (4096, 4096))
    atlas.image.paste(previous, (0, 0))
    atlas.y = previous.height + 1
    with Image.open(source / 'actors.png') as image:
        source_image = image.convert('RGBA')
    rectangles = {}

    def relocate(value):
        if isinstance(value, list):
            for item in value:
                relocate(item)
        elif isinstance(value, dict):
            if 'rect' in value and 'anchor_x' in value and 'anchor_y' in value:
                rect = value['rect']
                key = tuple(rect[name] for name in ('x', 'y', 'w', 'h'))
                x, y, w, h = key
                if x < 0 or y < 0 or w <= 0 or h <= 0 or x + w > source_image.width or y + h > source_image.height:
                    raise ValueError('Flash source sprite is outside its atlas')
                if key not in rectangles:
                    rectangles[key] = atlas.add(source_image.crop((x, y, x + w, y + h)))
                value['rect'] = rectangles[key]
            else:
                for item in value.values():
                    relocate(item)

    attacks = []
    for identifier in members:
        profile = copy.deepcopy(next(row for row in source_trial['party'] if row['id'] == identifier))
        if profile['attack'] or profile['motion'] is not None:
            raise ValueError('Flash review profile unexpectedly admits ordinary attacks')
        graphic = copy.deepcopy(next(row for row in source_trial['unite_graphics'] if row['id'] == identifier))
        relocate(profile)
        relocate(graphic)
        # shortcut: this source attack track omits actor-script camera and sound events until full actor binding.
        profile['attack'], profile['motion'], origin = flash_attack(identifier, atlas)
        attacks.append(dict(id=identifier, source=origin, scripts=[1, 4], decoder='export_battle_trial.attack_schedule',
                            limitation='Source frame/motion track; camera and sound events require complete actor binding.'))
        trial['party'].append(profile)
        trial['unite_graphics'].append(graphic)
        trial['medicine_timings'].append(next(row for row in source_trial['medicine_timings'] if row['id'] == identifier))
    for kind in ('equipment', 'runes'):
        source_rows = {row['id']: row for row in source_trial['systems'][kind]}
        for row in trial['systems'][kind]:
            if row.get('allowed_members') is None or row['id'] not in source_rows:
                continue
            allowed = source_rows[row['id']].get('allowed_members') or []
            row['allowed_members'].extend(identifier for identifier in members if identifier in allowed and identifier not in row['allowed_members'])
    preparation.bind_weapon_elements(trial)
    atlas.save(atlas_path)
    trial_path.write_text(json.dumps(trial, separators=(',', ':')) + '\n')
    actors_path.write_text(json.dumps(actors, separators=(',', ':')) + '\n')
    spells_path.write_text(json.dumps(spells, separators=(',', ':')) + '\n')
    spells_proof_path.write_text(json.dumps(spells_proof, indent=2) + '\n')
    return dict(status='candidate; full ordinary attack bindings and media review remain open',
                members=[row for row in proof['members'] if row['id'] in members],
                source_actor_programs_sha256=proof['actor_programs']['sha256'], attacks=attacks, atlas_rectangles=len(rectangles),
                controller=next(row for row in source_actors['unites'] if row['record'] == 10)['controller'])


def add_master_assets(candidate, review, proof):
    """Merge source-checked Master–Pupil bindings without replacing existing pixels."""
    source = Path(review) / 'record_31'
    source_trial = json.loads((source / 'trial.json').read_text())
    source_actors = json.loads((source / 'unites.json').read_text())
    source_spells = json.loads((source / 'spells.json').read_text())
    source_actor_proof = json.loads((Path(review) / 'actor_programs/provenance.json').read_text())
    footprint = source_actor_proof['master_pupil_controller']['footprint']
    if footprint['mode'] != 'axis_aligned_packet' or footprint['initial_angles'] != [0, 0, 0]:
        raise ValueError('Master pupil source footprint is not qualified')
    trial_path = candidate / 'battle/trial.json'
    actors_path = candidate / 'battle/unites.json'
    trial = json.loads(trial_path.read_text())
    actors = json.loads(actors_path.read_text())
    spells = json.loads((candidate / 'battle/spells.json').read_text())
    if actors['schema'] != 'suikoden-unite-actors/22' or source_actors['schema'] not in ('suikoden-unite-actors/23', 'suikoden-unite-actors/24', 'suikoden-unite-actors/26', 'suikoden-unite-actors/27', 'suikoden-unite-actors/28', 'suikoden-unite-actors/29'):
        raise ValueError('unsupported battle schemas for Master pupil')
    binding = next(row for row in source_actors['unites'] if row['record'] == 31)
    current = next(row for row in actors['unites'] if row['record'] == 31)
    original = {key: value for key, value in binding.items() if key != 'dispatch_after'}
    original['return_program'] = None
    original['members'] = [{key: value for key, value in member.items() if key not in ('entry_program', 'loop_program')} for member in binding['members']]
    if current != original:
        raise ValueError('Master pupil actor binding differs')
    for member in binding['members']:
        for name in (*member['programs'], binding['return_program']):
            if next(row for row in actors['programs']['programs'] if row['id'] == name) != next(row for row in source_actors['programs']['programs'] if row['id'] == name):
                raise ValueError('Master pupil actor program differs: ' + name)
        actual = next(row for row in actors['animations']['resources'] if row['id'] == member['id'])
        expected = next(row for row in source_actors['animations']['resources'] if row['id'] == member['id'])
        clips = {clip['id']: clip for clip in actual['clips']}
        if any(clips.get(clip['id']) != clip for clip in expected['clips']):
            raise ValueError('Master pupil actor animations differ: ' + member['id'])
    if next(row for row in spells['unite_reactions'] if row['record'] == 31) != next(row for row in source_spells['unite_reactions'] if row['record'] == 31):
        raise ValueError('Master pupil recipient reaction differs')
    atlas_path = candidate / 'battle/actors.png'
    with Image.open(atlas_path) as image:
        previous = image.convert('RGBA')
    with Image.open(source / 'actors.png') as image:
        source_image = image.convert('RGBA')
    if previous.width > 4096 or previous.height >= 4096:
        raise ValueError('Master pupil graphics exceed the runtime atlas')
    atlas = export_first_room.Atlas()
    atlas.image = Image.new('RGBA', (4096, 4096))
    atlas.image.paste(previous, (0, 0))
    atlas.y = previous.height + 1
    rectangles = {}

    def pixels(image, sprite):
        rect = sprite['rect']
        x, y, w, h = (rect[key] for key in ('x', 'y', 'w', 'h'))
        if x < 0 or y < 0 or w <= 0 or h <= 0 or x + w > image.width or y + h > image.height:
            raise ValueError('Master pupil sprite is outside its atlas')
        return image.crop((x, y, x + w, y + h))

    def relocate(sprite):
        rect = sprite['rect']
        key = tuple(rect[name] for name in ('x', 'y', 'w', 'h'))
        if key not in rectangles:
            rectangles[key] = atlas.add(pixels(source_image, sprite))
        sprite['rect'] = rectangles[key]

    for identifier in ('hero', 'kai'):
        if not any(row['id'] == identifier for row in trial['party']):
            raise ValueError('Master pupil member profile missing')
        original = next(row for row in trial['unite_graphics'] if row['id'] == identifier)
        incoming = next(row for row in source_trial['unite_graphics'] if row['id'] == identifier)
        existing = {pose['id']: pose for pose in original['poses']}
        for source_pose in incoming['poses']:
            pose = copy.deepcopy(source_pose)
            destination = existing.get(pose['id'])
            if destination is None:
                destination = {'id': pose['id']}
                original['poses'].append(destination)
            for key in ('sprite', 'white', 'trail'):
                if key not in pose:
                    continue
                samples = pose[key] if key == 'trail' else [pose[key]]
                if key in destination:
                    prior = destination[key] if key == 'trail' else [destination[key]]
                    if len(prior) != len(samples) or any(
                        (a['anchor_x'], a['anchor_y']) != (b['anchor_x'], b['anchor_y']) or
                        pixels(previous, a).size != pixels(source_image, b).size or
                        pixels(previous, a).tobytes() != pixels(source_image, b).tobytes()
                        for a, b in zip(prior, samples, strict=True)
                    ):
                        raise ValueError(f'Master pupil {identifier} pose {pose["id"]} {key} differs')
                    continue
                for sprite in samples:
                    relocate(sprite)
                destination[key] = pose[key]
    actors['unites'][actors['unites'].index(current)] = binding
    actors['schema'] = 'suikoden-unite-actors/23'
    atlas.save(atlas_path)
    trial_path.write_text(json.dumps(trial, separators=(',', ':')) + '\n')
    actors_path.write_text(json.dumps(actors, separators=(',', ':')) + '\n')
    return dict(status='candidate; rotated nodes and media review remain open',
                members=[row for row in proof['members'] if row['id'] in ('hero', 'kai')],
                footprint=footprint, source_actor_programs_sha256=proof['actor_programs']['sha256'], atlas_rectangles=len(rectangles))


def add_couple_assets(candidate, review, proof, include_warriors=False):
    """Add Couple's qualified source scripts, palettes and fixed impact."""
    source = Path(review) / 'record_16'
    trial_path, actors_path, spells_path = (candidate / 'battle' / name for name in ('trial.json', 'unites.json', 'spells.json'))
    trial, actors, spells = (json.loads(path.read_text()) for path in (trial_path, actors_path, spells_path))
    source_trial, source_actors, source_spells = (json.loads((source / name).read_text()) for name in ('trial.json', 'unites.json', 'spells.json'))
    if (trial['schema'], actors['schema'], spells['schema']) != ('suikoden-battle-trial/33', 'suikoden-unite-actors/23', 'suikoden-spell-scenes/47') or source_trial['schema'] != 'suikoden-battle-trial/34' or source_actors['schema'] not in ('suikoden-unite-actors/24', 'suikoden-unite-actors/26', 'suikoden-unite-actors/27', 'suikoden-unite-actors/28', 'suikoden-unite-actors/29') or source_spells['schema'] not in ('suikoden-spell-scenes/48', 'suikoden-spell-scenes/49', 'suikoden-spell-scenes/50', 'suikoden-spell-scenes/51'):
        raise ValueError('unsupported battle schemas for Couple')
    members = ('eileen', 'lepant', 'tengaar', 'hix') if include_warriors else ('eileen', 'lepant')
    if set(members) & ({row['id'] for row in trial['party']} | {row['id'] for row in trial['unite_graphics']}):
        raise ValueError('Couple members already present')
    binding = next(row for row in source_actors['unites'] if row['record'] == 16)
    current = next(row for row in actors['unites'] if row['record'] == 16)
    original = {key: value for key, value in binding.items() if key not in ('dispatch_after', 'damage_member', 'impact_effect', 'transition')}
    original['members'] = [{key: value for key, value in member.items() if key != 'entry_program'} for member in binding['members']]
    if current != original:
        raise ValueError('Couple actor binding differs')
    for member in binding['members']:
        for name in (*member['programs'], binding['return_program']):
            if next(row for row in actors['programs']['programs'] if row['id'] == name) != next(row for row in source_actors['programs']['programs'] if row['id'] == name):
                raise ValueError('Couple actor program differs: ' + name)
        actual = next(row for row in actors['animations']['resources'] if row['id'] == member['id'])
        expected = next(row for row in source_actors['animations']['resources'] if row['id'] == member['id'])
        clips = {clip['id']: clip for clip in actual['clips']}
        if any(clips.get(clip['id']) != clip for clip in expected['clips']):
            raise ValueError('Couple actor animations differ: ' + member['id'])
    if next(row for row in spells['unite_reactions'] if row['record'] == 16) != next(row for row in source_spells['unite_reactions'] if row['record'] == 16):
        raise ValueError('Couple recipient reaction differs')
    if include_warriors:
        if source_actors['schema'] not in ('suikoden-unite-actors/26', 'suikoden-unite-actors/27', 'suikoden-unite-actors/28', 'suikoden-unite-actors/29'):
            raise ValueError('Warriors controller is missing')
        warriors = next(row for row in source_actors['unites'] if row['record'] == 15)
        prior = next(row for row in actors['unites'] if row['record'] == 15)
        original = {key: value for key, value in warriors.items() if key not in ('dispatch_after', 'controller')}
        original['return_program'] = prior['return_program']
        if original != prior:
            raise ValueError('Warriors actor binding differs')
        for member in warriors['members']:
            for name in (*member['programs'], warriors['return_program']):
                if next(row for row in actors['programs']['programs'] if row['id'] == name) != next(row for row in source_actors['programs']['programs'] if row['id'] == name):
                    raise ValueError('Warriors actor program differs: ' + name)
            actual = next(row for row in actors['animations']['resources'] if row['id'] == member['id'])
            expected = next(row for row in source_actors['animations']['resources'] if row['id'] == member['id'])
            if actual['pose_count'] != expected['pose_count']:
                raise ValueError('Warriors actor pose count differs')
            clips = {clip['id']: clip for clip in actual['clips']}
            for clip in expected['clips']:
                if clip['id'] in clips and clips[clip['id']] != clip:
                    raise ValueError('Warriors actor animation differs')
                if clip['id'] not in clips: actual['clips'].append(clip)
            actual['clips'].sort(key=lambda row: row['id'])
        reaction = lambda packet: next(row for row in packet['unite_reactions'] if row['record'] == 15 and row.get('variant') == 1)
        if reaction(spells) != reaction(source_spells):
            raise ValueError('Warriors recipient reaction differs')
        warriors_scene = next(row for row in source_spells['unite_scenes'] if row['id'] == 'warriors')
        if any(row['id'] == 'warriors' for row in spells['unite_scenes']):
            raise ValueError('Warriors scene already present')
    impact = next(row for row in source_spells['unite_impacts'] if row['id'] == 6)
    if any(row['id'] == 6 for row in spells['unite_impacts']):
        raise ValueError('Couple impact already present')
    with Image.open(candidate / 'battle/spell_effects.png') as old, Image.open(source / 'spell_effects.png') as new:
        for frame in impact['frames']:
            index = frame['entry']
            old_entry, new_entry = spells['entries'][index], source_spells['entries'][index]
            if old_entry != new_entry:
                raise ValueError('Couple impact atlas entry differs')
            x, y, w, h = (old_entry[key] for key in ('x', 'y', 'w', 'h'))
            if old.crop((x, y, x+w, y+h)).tobytes() != new.crop((x, y, x+w, y+h)).tobytes():
                raise ValueError('Couple impact atlas pixels differ')
        if include_warriors:
            pieces = {sample['piece'] for track in warriors_scene['program']['tracks'] for sample in track if sample.get('piece') is not None}
            for piece in pieces:
                if spells['pieces'][piece] != source_spells['pieces'][piece]:
                    raise ValueError('Warriors effect pieces differ')
                for index in spells['pieces'][piece]:
                    old_entry, new_entry = spells['entries'][index], source_spells['entries'][index]
                    if old_entry != new_entry:
                        raise ValueError('Warriors effect atlas entry differs')
                    x, y, w, h = (old_entry[key] for key in ('x', 'y', 'w', 'h'))
                    if old.crop((x, y, x+w, y+h)).tobytes() != new.crop((x, y, x+w, y+h)).tobytes():
                        raise ValueError('Warriors effect atlas pixels differ')
    atlas_path = candidate / 'battle/actors.png'
    with Image.open(atlas_path) as image:
        previous = image.convert('RGBA')
    with Image.open(source / 'actors.png') as image:
        source_image = image.convert('RGBA')
    if previous.width > 4096 or previous.height >= 4096:
        raise ValueError('Couple graphics exceed the runtime atlas')
    atlas = export_first_room.Atlas()
    atlas.image = Image.new('RGBA', (4096, 4096))
    atlas.image.paste(previous, (0, 0))
    atlas.y = previous.height + 1
    rectangles = {}

    def relocate(value):
        if isinstance(value, list):
            for item in value: relocate(item)
        elif isinstance(value, dict):
            if 'rect' in value and 'anchor_x' in value and 'anchor_y' in value:
                rect = value['rect']
                key = tuple(rect[name] for name in ('x', 'y', 'w', 'h'))
                x, y, w, h = key
                if x < 0 or y < 0 or w <= 0 or h <= 0 or x+w > source_image.width or y+h > source_image.height:
                    raise ValueError('Couple source sprite is outside its atlas')
                if key not in rectangles:
                    rectangles[key] = atlas.add(source_image.crop((x, y, x+w, y+h)))
                value['rect'] = rectangles[key]
            else:
                for item in value.values(): relocate(item)

    attacks = []
    ranged, ranged_proof = export_party_ranged_actors.build()
    ranged_members = {'eileen', 'tengaar'} if include_warriors else {'eileen'}
    roots = [(row['id'], row[key]) for row in ranged['bindings'] if row['id'] in ranged_members for key in ('attack_program', 'return_program')]
    if len(roots) != 2 * len(ranged_members):
        raise ValueError('ranged member bindings missing')
    resources = {'resources': [row['resource'] for row in ranged_proof['characters'] + ranged_proof['targets']]}
    ranged_graphics, ranged_art_proof = export_physical_runes.graphics(ranged, resources, atlas, ranged_members, roots)
    for identifier in members:
        profile = copy.deepcopy(next(row for row in source_trial['party'] if row['id'] == identifier))
        graphic = copy.deepcopy(next(row for row in source_trial['unite_graphics'] if row['id'] == identifier))
        if profile['attack'] or profile['motion'] is not None:
            raise ValueError('Couple review profile unexpectedly admits ordinary attacks')
        relocate(profile)
        relocate(graphic)
        if identifier in ranged_members:
            incoming = next(row for row in ranged_graphics if row['id'] == identifier)
            existing = {row['id']: row for row in graphic['poses']}
            for pose in incoming['poses']:
                destination = existing.get(pose['id'])
                if destination is None:
                    graphic['poses'].append(pose)
                    continue
                destination['ordinary'] = pose['sprite']
                if 'pieces' in pose:
                    if 'pieces' in destination: raise ValueError('ranged projectile poses overlap')
                    destination['pieces'] = pose['pieces']
            attacks.append(dict(id=identifier, source='ranged actor programs', graphics=ranged_art_proof))
        else:
            # shortcut: source attack track omits actor-script camera and sound events until full actor binding.
            profile['attack'], profile['motion'], origin = flash_attack(identifier, atlas)
            attacks.append(dict(id=identifier, source=origin, scripts=[1, 4], decoder='export_battle_trial.attack_schedule'))
        trial['party'].append(profile)
        trial['unite_graphics'].append(graphic)
        trial['medicine_timings'].append(next(row for row in source_trial['medicine_timings'] if row['id'] == identifier))
    for kind in ('equipment', 'runes'):
        source_rows = {row['id']: row for row in source_trial['systems'][kind]}
        for row in trial['systems'][kind]:
            if row.get('allowed_members') is None or row['id'] not in source_rows: continue
            allowed = source_rows[row['id']].get('allowed_members') or []
            row['allowed_members'].extend(identifier for identifier in members if identifier in allowed and identifier not in row['allowed_members'])
    preparation.bind_weapon_elements(trial)
    actors['unites'][actors['unites'].index(current)] = binding
    actors['schema'] = 'suikoden-unite-actors/26' if include_warriors else 'suikoden-unite-actors/24'
    trial['schema'] = 'suikoden-battle-trial/34'
    spells['unite_impacts'].append(impact)
    if include_warriors:
        actors['unites'][actors['unites'].index(prior)] = warriors
        spells['unite_scenes'].append(warriors_scene)
    spells['schema'] = 'suikoden-spell-scenes/48'
    atlas.save(atlas_path)
    for path, payload in ((trial_path, trial), (actors_path, actors), (spells_path, spells)):
        path.write_text(json.dumps(payload, separators=(',', ':')) + '\n')
    spells_proof_path = candidate / 'battle/spells.provenance.json'
    spells_proof = json.loads(spells_proof_path.read_text())
    spells_proof['couple_impact'] = json.loads((Path(review) / 'shared/provenance.json').read_text())['couple_impact']
    if include_warriors:
        spells_proof['warriors_effect'] = json.loads((Path(review) / 'shared/provenance.json').read_text())['warriors_effect']
    spells_proof_path.write_text(json.dumps(spells_proof, indent=2) + '\n')
    return dict(status='candidate; KO, overlap, audio and media review remain open',
                members=[row for row in proof['members'] if row['id'] in members], attacks=attacks,
                source_actor_programs_sha256=proof['actor_programs']['sha256'], atlas_rectangles=len(rectangles))



def add_martial_assets(candidate, review, proof):
    """Merge the source queue scene while preserving Pahn's existing action art."""
    source = Path(review)/'record_29'
    trial_path, actors_path, spells_path = (candidate/'battle'/name for name in ('trial.json','unites.json','spells.json'))
    trial, actors, spells = (json.loads(path.read_text()) for path in (trial_path, actors_path, spells_path))
    source_trial, source_actors, source_spells = (json.loads((source/name).read_text()) for name in ('trial.json','unites.json','spells.json'))
    if trial['schema'] != 'suikoden-battle-trial/34' or actors['schema'] != 'suikoden-unite-actors/26' or spells['schema'] not in ('suikoden-spell-scenes/48','suikoden-spell-scenes/49', 'suikoden-spell-scenes/50') or source_actors['schema'] not in ('suikoden-unite-actors/27','suikoden-unite-actors/28', 'suikoden-unite-actors/29') or source_spells['schema'] not in ('suikoden-spell-scenes/49','suikoden-spell-scenes/50', 'suikoden-spell-scenes/51'):
        raise ValueError('unsupported battle schemas for Martial arts')
    binding = source_actors['unites'][29]
    prior = actors['unites'][29]
    members = ('eikei','pahn','morgan')
    if tuple(m['id'] for m in binding['members']) != members or tuple(m['id'] for m in prior['members']) != members or prior.get('target_queue') is not None:
        raise ValueError('Martial arts member binding differs')
    if any(p['id'] in ('eikei','morgan') for p in trial['party']) or not any(p['id']=='pahn' for p in trial['party']):
        raise ValueError('Martial arts party profiles differ')
    programs = {p['id']:p for p in actors['programs']['programs']}
    incoming = {p['id']:p for p in source_actors['programs']['programs']}
    for member, setup in zip(binding['members'],('eikei/unite_9','pahn/unite_11','morgan/unite_9'),strict=True):
        if incoming[member['entry_program']]['instructions'] != programs[setup]['instructions'] or incoming[member['loop_program']]['instructions'] != programs['eikei/unite_10']['instructions']:
            raise ValueError('Martial arts source actor instructions differ')
        for name in (*member['programs'],binding['return_program']):
            if name in programs and programs[name] != incoming[name]:
                raise ValueError('Martial arts program conflicts: '+name)
            programs[name] = incoming[name]
        actual = next(r for r in actors['animations']['resources'] if r['id']==member['id'])
        expected = next(r for r in source_actors['animations']['resources'] if r['id']==member['id'])
        if {k:v for k,v in actual.items() if k!='clips'} != {k:v for k,v in expected.items() if k!='clips'}:
            raise ValueError('Martial arts animation resource differs')
        clips = {clip['id']:clip for clip in actual['clips']}
        for clip in expected['clips']:
            if clip['id'] in clips and clips[clip['id']] != clip:
                raise ValueError('Martial arts animation conflicts')
            clips[clip['id']] = clip
        actual['clips'] = [clips[key] for key in sorted(clips)]
    recipients = [r for r in source_spells['unite_reactions'] if r['record']==29]
    if [r.get('variant',0) for r in recipients] != [1,2] or any(r['record']==29 for r in spells['unite_reactions']):
        raise ValueError('Martial arts recipient stages differ')
    with Image.open(candidate/'battle/spell_effects.png') as old, Image.open(source/'spell_effects.png') as new:
        animations = {impact['animation'] for reaction in recipients for impact in reaction['impacts']}
        for animation in animations:
            clip = next(c for c in spells['unite_impacts'] if c['id']==animation)
            source_clip = next(c for c in source_spells['unite_impacts'] if c['id']==animation)
            if [f['ticks'] for f in clip['frames']] != [f['ticks'] for f in source_clip['frames']]:
                raise ValueError('Martial arts impact animation differs')
            for frame, source_frame in zip(clip['frames'], source_clip['frames'], strict=True):
                entry = spells['entries'][frame['entry']]
                source_entry = source_spells['entries'][source_frame['entry']]
                if {k:v for k,v in entry.items() if k not in ('x','y')} != {k:v for k,v in source_entry.items() if k not in ('x','y')}:
                    raise ValueError('Martial arts impact entry differs')
                x,y,w,h = (entry[key] for key in ('x','y','w','h'))
                sx,sy = (source_entry[key] for key in ('x','y'))
                if old.crop((x,y,x+w,y+h)).tobytes() != new.crop((sx,sy,sx+w,sy+h)).tobytes():
                    raise ValueError('Martial arts impact pixels differ')
    atlas_path = candidate/'battle/actors.png'
    with Image.open(atlas_path) as image: previous = image.convert('RGBA')
    with Image.open(source/'actors.png') as image: source_image = image.convert('RGBA')
    atlas = export_first_room.Atlas()
    atlas.image = Image.new('RGBA',(4096,4096))
    if previous.width > 4096 or previous.height >= 4096:
        raise ValueError('Martial arts graphics exceed runtime atlas')
    atlas.image.paste(previous,(0,0)); atlas.y = previous.height+1
    rectangles = {}
    def relocate(value):
        if isinstance(value,list):
            for item in value: relocate(item)
        elif isinstance(value,dict):
            if 'rect' in value and 'anchor_x' in value and 'anchor_y' in value:
                rect=value['rect']; key=tuple(rect[k] for k in ('x','y','w','h')); x,y,w,h=key
                if x<0 or y<0 or w<=0 or h<=0 or x+w>source_image.width or y+h>source_image.height:
                    raise ValueError('Martial arts source sprite is outside its atlas')
                if key not in rectangles: rectangles[key]=atlas.add(source_image.crop((x,y,x+w,y+h)))
                value['rect']=rectangles[key]
            else:
                for item in value.values(): relocate(item)
    import export_counter_actors
    resource_proof=json.loads((Path(review)/'actor_programs/provenance.json').read_text())
    roots=export_counter_actors.graphic_roots(actors['counter'])
    if actors.get('enemy_magic'):
        roots.extend((identifier,actors['enemy_magic']['recipient_program']) for identifier in ('eikei','morgan'))
    ordinary,ordinary_proof=export_physical_runes.graphics(dict(actors,techniques=actors.get('physical',[])),resource_proof,atlas,{'eikei','morgan'},roots)
    if any(g['id'] in ('eikei','morgan') and g.get('record') is None for g in trial['unite_graphics']):
        raise ValueError('Martial arts ordinary member graphics already present')
    trial['unite_graphics'].extend(ordinary)
    attacks=[]
    for identifier in members:
        graphic=copy.deepcopy(next(g for g in source_trial['unite_graphics'] if g['id']==identifier))
        relocate(graphic)
        graphic['record']=29
        trial['unite_graphics'].append(graphic)
        if identifier=='pahn': continue
        profile=copy.deepcopy(next(p for p in source_trial['party'] if p['id']==identifier))
        relocate(profile)
        # shortcut: bind the source ordinary track until these members have full actor-script attacks.
        profile['attack'],profile['motion'],origin=flash_attack(identifier,atlas)
        attacks.append(dict(id=identifier,source=origin,scripts=[1,4],decoder='export_battle_trial.attack_schedule'))
        trial['party'].append(profile)
        trial['medicine_timings'].append(next(r for r in source_trial['medicine_timings'] if r['id']==identifier))
    for kind in ('equipment','runes'):
        source_rows={r['id']:r for r in source_trial['systems'][kind]}
        for row in trial['systems'][kind]:
            if row.get('allowed_members') is None or row['id'] not in source_rows: continue
            allowed=source_rows[row['id']].get('allowed_members') or []
            row['allowed_members'].extend(id for id in ('eikei','morgan') if id in allowed and id not in row['allowed_members'])
    preparation.bind_weapon_elements(trial)
    actors['programs']['programs']=[programs[name] for name in sorted(programs)]
    actors['unites'][29]=binding
    actors['schema']='suikoden-unite-actors/27'
    trial['schema']='suikoden-battle-trial/35'
    spells['unite_reactions'].extend(recipients)
    spells['schema']='suikoden-spell-scenes/49'
    atlas.save(atlas_path)
    for path,payload in ((trial_path,trial),(actors_path,actors),(spells_path,spells)):
        path.write_text(json.dumps(payload,separators=(',',':'))+'\n')
    source_proof=json.loads((Path(review)/'shared/provenance.json').read_text())
    spells_proof_path=candidate/'battle/spells.provenance.json'
    spells_proof=json.loads(spells_proof_path.read_text())
    spells_proof['martial_recipients']=source_proof['martial_recipients']
    spells_proof_path.write_text(json.dumps(spells_proof,indent=2)+'\n')
    return dict(status='candidate; KO, overlap and human media acceptance remain open',
                members=[r for r in proof['members'] if r['id'] in members],attacks=attacks,ordinary_graphics=ordinary_proof,
                source_actor_programs_sha256=proof['actor_programs']['sha256'],atlas_rectangles=len(rectangles))


def add_beat_assets(candidate, review, proof):
    """Merge Beat'em up without replacing Pahn's other action crops."""
    source=Path(review)/'record_27'
    paths=[candidate/'battle'/name for name in ('trial.json','unites.json','spells.json')]
    trial,actors,spells=[json.loads(p.read_text()) for p in paths]
    source_trial,source_actors,source_spells=[json.loads((source/name).read_text()) for name in ('trial.json','unites.json','spells.json')]
    if (trial['schema'],actors['schema'],spells['schema'])!=('suikoden-battle-trial/35','suikoden-unite-actors/27','suikoden-spell-scenes/49') or source_actors['schema'] not in ('suikoden-unite-actors/28','suikoden-unite-actors/29') or source_spells['schema'] not in ('suikoden-spell-scenes/50','suikoden-spell-scenes/51'):
        raise ValueError('unsupported battle schemas for Beat em up')
    binding=source_actors['unites'][27]
    if [m['id'] for m in binding['members']]!=['pahn','ronnie'] or actors['unites'][27].get('beat_child') is not None or any(p['id']=='ronnie' for p in trial['party']):
        raise ValueError('Beat em up member binding differs')
    export_physical_runes.merge_libraries(actors,source_actors)
    recipients=[r for r in source_spells['unite_reactions'] if r['record']==27]
    if [r.get('variant',0) for r in recipients]!=[1,0]:raise ValueError('Beat em up recipient stages differ')
    with Image.open(candidate/'battle/spell_effects.png') as old, Image.open(source/'spell_effects.png') as new:
        for animation in {i['animation'] for r in recipients for i in r['impacts']}:
            clip=next(c for c in spells['unite_impacts'] if c['id']==animation)
            incoming=next(c for c in source_spells['unite_impacts'] if c['id']==animation)
            if [f['ticks'] for f in clip['frames']]!=[f['ticks'] for f in incoming['frames']]:raise ValueError('Beat em up impact clock differs')
            for frame,other in zip(clip['frames'],incoming['frames'],strict=True):
                entry,expected=spells['entries'][frame['entry']],source_spells['entries'][other['entry']]
                if {k:v for k,v in entry.items() if k not in ('x','y')}!={k:v for k,v in expected.items() if k not in ('x','y')}:raise ValueError('Beat em up impact geometry differs')
                x,y,w,h=(entry[k] for k in ('x','y','w','h'));sx,sy=(expected[k] for k in ('x','y'))
                if old.crop((x,y,x+w,y+h)).tobytes()!=new.crop((sx,sy,sx+w,sy+h)).tobytes():raise ValueError('Beat em up impact pixels differ')
    atlas_path=candidate/'battle/actors.png'
    with Image.open(atlas_path) as image:previous=image.convert('RGBA')
    with Image.open(source/'actors.png') as image:incoming_image=image.convert('RGBA')
    if previous.width>4096 or previous.height>=4096:raise ValueError('Beat em up atlas exceeds runtime bounds')
    atlas=export_first_room.Atlas();atlas.image=Image.new('RGBA',(4096,4096));atlas.image.paste(previous,(0,0));atlas.y=previous.height+1
    rectangles={}
    def relocate(value):
        if isinstance(value,list):
            for item in value:relocate(item)
        elif isinstance(value,dict):
            if 'rect' in value and 'anchor_x' in value and 'anchor_y' in value:
                r=value['rect'];key=tuple(r[k] for k in ('x','y','w','h'));x,y,w,h=key
                if x<0 or y<0 or w<=0 or h<=0 or x+w>incoming_image.width or y+h>incoming_image.height:raise ValueError('Beat em up source sprite is outside atlas')
                if key not in rectangles:rectangles[key]=atlas.add(incoming_image.crop((x,y,x+w,y+h)))
                value['rect']=rectangles[key]
            else:
                for item in value.values():relocate(item)
    import export_counter_actors
    resources=json.loads((Path(review)/'actor_programs/provenance.json').read_text())
    roots=export_counter_actors.graphic_roots(actors['counter'])
    if actors.get('enemy_magic'):roots.append(('ronnie',actors['enemy_magic']['recipient_program']))
    ordinary,ordinary_proof=export_physical_runes.graphics(dict(actors,techniques=actors.get('physical',[])),resources,atlas,{'ronnie'},roots)
    def graphic_signature(value):
        if isinstance(value,list):return [graphic_signature(v) for v in value]
        if isinstance(value,dict):
            if 'rect' in value and 'anchor_x' in value and 'anchor_y' in value:
                x,y,w,h=(value['rect'][k] for k in ('x','y','w','h'))
                return (value['anchor_x'],value['anchor_y'],w,h,atlas.image.crop((x,y,x+w,y+h)).tobytes())
            return {k:graphic_signature(v) for k,v in value.items()}
        return value
    for graphic in ordinary:
        existing=next((g for g in trial['unite_graphics'] if g['id']==graphic['id'] and g.get('record') is None),None)
        if existing is None:trial['unite_graphics'].append(graphic)
        elif graphic_signature(existing)!=graphic_signature(graphic):raise ValueError('Beat em up ordinary graphics conflict')
    for identifier in ('pahn','ronnie'):
        graphic=copy.deepcopy(next(g for g in source_trial['unite_graphics'] if g['id']==identifier and g.get('record') is None))
        relocate(graphic);graphic['record']=27;trial['unite_graphics'].append(graphic)
    profile=copy.deepcopy(next(p for p in source_trial['party'] if p['id']=='ronnie'))
    relocate(profile)
    # shortcut: use the source ordinary track until Ronnie has a full attack actor binding.
    profile['attack'],profile['motion'],attack_source=flash_attack('ronnie',atlas)
    trial['party'].append(profile)
    trial['medicine_timings'].append(next(r for r in source_trial['medicine_timings'] if r['id']=='ronnie'))
    for kind in ('equipment','runes'):
        rows={r['id']:r for r in source_trial['systems'][kind]}
        for row in trial['systems'][kind]:
            if row.get('allowed_members') is not None and 'ronnie' in (rows.get(row['id'],{}).get('allowed_members') or []) and 'ronnie' not in row['allowed_members']:row['allowed_members'].append('ronnie')
    preparation.bind_weapon_elements(trial)
    attachments={p['id']:p['source_attachment'] for p in source_spells['hurt_poses']}
    for pose in spells['hurt_poses']:
        offset=attachments[pose['id']]
        if [((v+128)%256)-128 for v in offset]!=pose['impact_offset']:raise ValueError('Beat em up attachment differs')
        pose['source_attachment']=offset
    actors['unites'][27]=binding;actors['schema']='suikoden-unite-actors/28'
    spells['unite_reactions']=[r for r in spells['unite_reactions'] if r['record']!=27]+recipients
    spells['schema']='suikoden-spell-scenes/50'
    atlas.save(atlas_path)
    for path,payload in zip(paths,(trial,actors,spells),strict=True):path.write_text(json.dumps(payload,separators=(',',':'))+'\n')
    proof_path=candidate/'battle/spells.provenance.json';spell_proof=json.loads(proof_path.read_text())
    spell_proof['beat_recipients']=json.loads((Path(review)/'shared/provenance.json').read_text())['beat_recipients']
    proof_path.write_text(json.dumps(spell_proof,indent=2)+'\n')
    return dict(status='candidate; acquisition, overlap and human media acceptance remain open',
                members=[r for r in proof['members'] if r['id'] in ('pahn','ronnie')],ordinary_graphics=ordinary_proof,
                attack=dict(id='ronnie',source=attack_source,scripts=[1,4]),atlas_rectangles=len(rectangles),source_actor_programs_sha256=proof['actor_programs']['sha256'])


def add_trick_assets(candidate, review, proof):
    """Add Meg/Juppo and the wave while preserving all existing atlas rectangles."""
    source = Path(review) / 'record_14'
    paths = [candidate/'battle'/name for name in ('trial.json','unites.json')]
    trial, actors = [json.loads(path.read_text()) for path in paths]
    incoming = json.loads((source/'trial.json').read_text())
    source_actors = json.loads((source/'unites.json').read_text())
    binding = source_actors['unites'][14]
    members = ('meg','juppo')
    if (trial['schema'],actors['schema'],source_actors['schema']) != ('suikoden-battle-trial/35','suikoden-unite-actors/28','suikoden-unite-actors/29'):
        raise ValueError('unsupported battle schemas for Trick')
    if tuple(m['id'] for m in binding['members']) != members or binding.get('wave_heights') is None or actors['unites'][14].get('dispatch_after') is not None or any(p['id'] in members for p in trial['party']):
        raise ValueError('Trick member binding differs')
    export_physical_runes.merge_libraries(actors,source_actors)
    atlas_path = candidate/'battle/actors.png'
    with Image.open(atlas_path) as image: previous = image.convert('RGBA')
    with Image.open(source/'actors.png') as image: source_image = image.convert('RGBA')
    if previous.width > 4096 or previous.height >= 4096: raise ValueError('Trick atlas exceeds runtime bounds')
    atlas = export_first_room.Atlas()
    atlas.image = Image.new('RGBA',(4096,4096)); atlas.image.paste(previous,(0,0)); atlas.y = previous.height+1
    rectangles = {}
    def relocate(value):
        if isinstance(value,list):
            for item in value: relocate(item)
        elif isinstance(value,dict):
            if 'rect' in value and 'anchor_x' in value and 'anchor_y' in value:
                key = tuple(value['rect'][k] for k in ('x','y','w','h')); x,y,w,h = key
                if x < 0 or y < 0 or w <= 0 or h <= 0 or x+w > source_image.width or y+h > source_image.height: raise ValueError('Trick sprite outside source atlas')
                if key not in rectangles: rectangles[key] = atlas.add(source_image.crop((x,y,x+w,y+h)))
                value['rect'] = rectangles[key]
            else:
                for item in value.values(): relocate(item)
    import export_counter_actors
    resources = json.loads((Path(review)/'actor_programs/provenance.json').read_text())
    roots = export_counter_actors.graphic_roots(actors['counter'])
    if actors.get('enemy_magic'): roots.extend((m,actors['enemy_magic']['recipient_program']) for m in members)
    ranged = {r['id']:r for r in actors['counter']['ranged']['attackers']}
    for identifier in members:
        if identifier not in ranged: raise ValueError('Trick member has no source ranged attack')
        roots.extend((identifier,ranged[identifier][role+'_program']) for role in ('attack','return','hurt','critical_hurt'))
    ordinary, ordinary_proof = export_physical_runes.graphics(dict(actors,techniques=actors.get('physical',[])),resources,atlas,set(members),roots)
    def signature(value):
        if isinstance(value,list): return [signature(v) for v in value]
        if isinstance(value,dict):
            if 'rect' in value and 'anchor_x' in value and 'anchor_y' in value:
                x,y,w,h = (value['rect'][k] for k in ('x','y','w','h'))
                return value['anchor_x'],value['anchor_y'],w,h,atlas.image.crop((x,y,x+w,y+h)).tobytes()
            return {k:signature(v) for k,v in value.items()}
        return value
    for graphic in ordinary:
        existing = next((g for g in trial['unite_graphics'] if g['id']==graphic['id'] and g.get('record') is None),None)
        if existing is None: trial['unite_graphics'].append(graphic)
        else:
            poses = {p['id']:p for p in existing['poses']}
            for pose in graphic['poses']:
                if pose['id'] in poses:
                    if signature(poses[pose['id']]) != signature(pose): raise ValueError('Trick ordinary graphic conflicts')
                else: existing['poses'].append(pose)
    attacks = []
    for identifier in members:
        graphic = copy.deepcopy(next(g for g in incoming['unite_graphics'] if g['id']==identifier and g.get('record') is None))
        relocate(graphic); graphic['record'] = 14; trial['unite_graphics'].append(graphic)
        profile = copy.deepcopy(next(p for p in incoming['party'] if p['id']==identifier)); relocate(profile)
        profile['attack'],profile['motion'] = [],None
        trial['party'].append(profile); attacks.append(copy.deepcopy(ranged[identifier]))
        trial['medicine_timings'].append(next(r for r in incoming['medicine_timings'] if r['id']==identifier))
    for kind in ('equipment','runes'):
        rows = {r['id']:r for r in incoming['systems'][kind]}
        for row in trial['systems'][kind]:
            for identifier in members:
                if row.get('allowed_members') is not None and identifier in (rows.get(row['id'],{}).get('allowed_members') or []) and identifier not in row['allowed_members']: row['allowed_members'].append(identifier)
    preparation.bind_weapon_elements(trial)
    actors['unites'][14] = binding; actors['schema'] = 'suikoden-unite-actors/29'
    atlas.save(atlas_path)
    for path,payload in zip(paths,(trial,actors),strict=True): path.write_text(json.dumps(payload,separators=(',',':'))+'\n')
    return dict(status='candidate; acquisition, overlap and human media acceptance remain open',
                members=[r for r in proof['members'] if r['id'] in members],ordinary_graphics=ordinary_proof,
                attacks=attacks,atlas_rectangles=len(rectangles),source_actor_programs_sha256=proof['actor_programs']['sha256'])


def add_unite_member_assets(candidate, review, proof):
    """Import all remaining qualified member data without changing party ownership."""
    import journey_battle
    import export_counter_actors
    import item_tables
    import maindec
    source = Path(review)/'record_10'
    trial_path = candidate/'battle/trial.json'
    trial = json.loads(trial_path.read_text())
    actors = json.loads((candidate/'battle/unites.json').read_text())
    existing = {row['id']:row for row in trial['party']}
    selected = [row for row in actors['unites'] if any(member['id'] not in existing for member in row['members'])]
    members = {member['id'] for row in selected for member in row['members']}
    added = sorted(members-existing.keys())
    if not added: return dict(records=[],members=[],atlas_rectangles=0)
    incoming = json.loads((source/'trial.json').read_text())
    source_actors = json.loads((source/'unites.json').read_text())
    for row in selected:
        if row != source_actors['unites'][row['record']]: raise ValueError('Unite member batch binding differs')
    with Image.open(candidate/'battle/actors.png') as image: previous=image.convert('RGBA')
    with Image.open(source/'actors.png') as image: source_image=image.convert('RGBA')
    if previous.width>4096 or previous.height>=4096: raise ValueError('Unite member atlas exceeds runtime bounds')
    atlas=export_first_room.Atlas()
    atlas.image=Image.new('RGBA',(4096,4096));atlas.image.paste(previous,(0,0));atlas.y=previous.height+1
    rectangles={}
    def relocate(value):
        if isinstance(value,list):
            for entry in value: relocate(entry)
        elif isinstance(value,dict):
            if 'rect' in value and 'anchor_x' in value and 'anchor_y' in value:
                key=tuple(value['rect'][k] for k in ('x','y','w','h'));x,y,w,h=key
                if min(x,y)<0 or min(w,h)<=0 or x+w>source_image.width or y+h>source_image.height: raise ValueError('Unite member sprite outside source atlas')
                if key not in rectangles: rectangles[key]=atlas.add(source_image.crop((x,y,x+w,y+h)))
                value['rect']=rectangles[key]
            else:
                for entry in value.values(): relocate(entry)
    seeds={preparation.stable_id(row['name']):row for row in character_table.records()}
    rune_names={row['addr']:row['name'] for row in item_tables.runes()}
    rune_ids={row['name']:row['id'] for row in trial['systems']['runes']}
    ranged={row['id']:row for row in actors['counter']['ranged']['attackers']}
    attacks=[]
    for identifier in added:
        profile=copy.deepcopy(next(row for row in incoming['party'] if row['id']==identifier))
        relocate(profile)
        seed=seeds[identifier]
        profile['rune']=rune_ids[rune_names[maindec.mword(0x8016A0E0+4*seed['rune_id'])]] if seed['rune_id'] else None
        if identifier in ranged: profile['attack'],profile['motion']=[],None
        else:
            profile['attack'],profile['motion'],origin=flash_attack(identifier,atlas)
            attacks.append(dict(id=identifier,source=origin,scripts=[1,4],sampling='axis_aligned_packet' if identifier in ('humphrey','sonya') else 'inclusive'))
        trial['party'].append(profile);existing[identifier]=profile
        trial['medicine_timings'].append(next(row for row in incoming['medicine_timings'] if row['id']==identifier))
    programs={row['id']:row for row in actors['programs']['programs']}
    resources={row['id']:row for row in actors['animations']['resources']}
    graphics={row['id']:row for row in incoming['unite_graphics'] if row.get('record') is None}
    for row in selected:
        record=row['record']
        requests={member['id']:{0} for member in row['members']}
        pending=[(member['id'],name) for member in row['members'] for name in list(member['programs'])+([row['return_program']] if row['return_program'] else [])]
        visited=set()
        while pending:
            identifier,name=pending.pop()
            if (identifier,name) in visited: continue
            visited.add((identifier,name))
            for instruction in programs[name]['instructions']:
                command=instruction.get('command',{})
                if 'animation' in command and identifier in requests: requests[identifier].add(command['animation'])
                if 'child' in command:
                    child=command['child']
                    if child['resource'] not in requests and child['resource']!='shared_impacts': raise ValueError('Unbound Unite child resource')
                    if child['resource'] in requests: requests[child['resource']].add(child['animation'])
                    pending.append((child['resource'],child['program']))
        for member in row['members']:
            identifier=member['id']
            if member.get('fan'): requests[identifier].add(member['fan']['animation'])
            poses={frame['pose'] for clip in resources[identifier]['clips'] if clip['id'] in requests[identifier] for frame in clip['frames']}
            graphic=copy.deepcopy(graphics[identifier]);graphic['record']=record
            graphic['poses']=[pose for pose in graphic['poses'] if pose['id'] in poses]
            if not poses <= {pose['id'] for pose in graphic['poses']}: raise ValueError(f'Unite member batch pose missing: record{record} {identifier} {poses-{pose["id"] for pose in graphic["poses"]}}')
            if any(g['id']==identifier and g.get('record')==record for g in trial['unite_graphics']): raise ValueError('Unite member batch already bound')
            relocate(graphic);trial['unite_graphics'].append(graphic)
            destination=existing[identifier]
            for scene in next(p for p in incoming['party'] if p['id']==identifier).get('unite_scenes',[]):
                if scene['record']!=record or any(s['record']==record for s in destination.get('unite_scenes',[])): continue
                scene=copy.deepcopy(scene);relocate(scene);destination.setdefault('unite_scenes',[]).append(scene)
    resource_proof=json.loads((Path(review)/'actor_programs/provenance.json').read_text())
    roots=export_counter_actors.graphic_roots(actors['counter'])
    if actors.get('enemy_magic'): roots.extend((identifier,actors['enemy_magic']['recipient_program']) for identifier in members)
    reactions,reaction_proof=export_physical_runes.graphics(dict(actors,techniques=[]),resource_proof,atlas,members-set(added),roots)
    for identifier in added:
        if identifier in ranged: roots.extend((identifier,ranged[identifier][role+'_program']) for role in ('attack','return','hurt','critical_hurt'))
    ordinary,ordinary_proof=export_physical_runes.graphics(dict(actors,techniques=actors.get('physical',[])),resource_proof,atlas,set(added),roots)
    ordinary.extend(reactions);ordinary_proof.extend(reaction_proof)
    for graphic in ordinary:
        current=next((g for g in trial['unite_graphics'] if g['id']==graphic['id'] and g.get('record') is None),None)
        if current is None: trial['unite_graphics'].append(graphic)
        else:
            poses={pose['id']:pose for pose in current['poses']}
            def signature(value):
                if isinstance(value,list): return [signature(v) for v in value]
                if isinstance(value,dict):
                    if 'rect' in value and 'anchor_x' in value and 'anchor_y' in value:
                        x,y,w,h=(value['rect'][k] for k in ('x','y','w','h'))
                        return value['anchor_x'],value['anchor_y'],w,h,atlas.image.crop((x,y,x+w,y+h)).tobytes()
                    return {k:signature(v) for k,v in value.items()}
                return value
            for pose in graphic['poses']:
                if pose['id'] not in poses: current['poses'].append(pose);continue
                prior=poses[pose['id']]
                for key,value in pose.items():
                    if key=='sprite' and ('ordinary' in prior or signature(prior['sprite'])!=signature(value)): key='ordinary'
                    if key in prior and signature(prior[key])!=signature(value): raise ValueError(f'Unite batch ordinary graphic conflicts: {graphic["id"]} pose{pose["id"]} {key}')
                    prior[key]=value
    for kind in ('equipment','runes'):
        source_rows={row['id']:row for row in incoming['systems'][kind]}
        for row in trial['systems'][kind]:
            if row.get('allowed_members') is None: continue
            row['allowed_members'].extend(identifier for identifier in added if identifier in (source_rows[row['id']].get('allowed_members') or []) and identifier not in row['allowed_members'])
    payload=json.dumps(trial,separators=(',',':'))+'\n'
    if len(payload.encode())>1024*1024: raise ValueError('Unite member batch exceeds battle content limit')
    atlas.save(candidate/'battle/actors.png');trial_path.write_text(payload)
    return dict(records=[row['record'] for row in selected],added_members=added,members=[row for row in proof['members'] if row['id'] in members],
        source_actor_programs_sha256=proof['actor_programs']['sha256'],
        attacks=attacks,ordinary_graphics=ordinary_proof,atlas_rectangles=len(rectangles),
        policy='Source member catalogue and scene bindings only; initial party, recruitment and media acceptance unchanged')


def compile_field_encounter_groups(packet, package, trial):
    """Expand shared room settings into Journey's ordered per-room bindings."""
    if set(packet) - {'schema', 'groups', 'suppress_when', 'clear_suppression_on_world_entry'}:
        raise ValueError('unknown field encounter group packet fields')
    level_sums = check_journey_package.movement_encounter_level_sums(trial)
    rooms = []
    for index, group in enumerate(object_rows(packet.get('groups'), 'field encounter groups')):
        if set(group) != {'rooms', 'rate', 'counter_threshold', 'encounters'}:
            raise ValueError(f'invalid fields in field encounter group {index}')
        room_ids, encounter_ids = group['rooms'], group['encounters']
        if not isinstance(room_ids, list) or not room_ids or not all(isinstance(room, str) for room in room_ids):
            raise ValueError(f'invalid rooms in field encounter group {index}')
        if not isinstance(encounter_ids, list) or not encounter_ids or not all(isinstance(encounter, str) for encounter in encounter_ids):
            raise ValueError(f'invalid candidates in field encounter group {index}')
        candidates = []
        for encounter in encounter_ids:
            if encounter not in level_sums:
                raise ValueError(f'unknown movement encounter {encounter!r} in field encounter group {index}')
            candidates.append(dict(id=encounter, enemy_level_sum=level_sums[encounter]))
        rooms.extend(dict(room=room, rate=group['rate'], counter_threshold=group['counter_threshold'],
                          candidates=candidates) for room in room_ids)
    result = {key: packet[key] for key in ('suppress_when', 'clear_suppression_on_world_entry') if key in packet}
    result.update(schema='suikoden-field-movement-encounters/3', rooms=rooms)
    errors = []
    check_journey_package.check_movement_encounters({'field_encounters': result}, package, trial, errors)
    if errors:
        raise ValueError('invalid grouped field encounters: ' + '; '.join(errors))
    return result


def bind_field_content(candidate, field_encounters, room_events, *, field_rooms=None):
    """Install explicit field inputs into the unpublished assembly directory."""
    inputs = {}
    if field_rooms is not None:
        inputs['field_rooms'] = bind_field_rooms(candidate, field_rooms)
    if field_encounters is not None:
        source = Path(field_encounters).read_bytes()
        packet = json.loads(source)
        if not isinstance(packet, dict):
            raise ValueError('field encounter packet must be a JSON object')
        if packet.get('schema') == FIELD_ENCOUNTER_GROUPS:
            package = json.loads((candidate / 'room.json').read_text())
            trial = json.loads((candidate / 'battle/trial.json').read_text())
            packet = compile_field_encounter_groups(packet, package, trial)
        path = candidate / 'journey.json'
        journey = json.loads(path.read_text())
        journey['field_encounters'] = packet
        path.write_text(json.dumps(journey, indent=2) + '\n')
        inputs['field_encounters'] = hashlib.sha256(source).hexdigest()
    if room_events:
        sources = [Path(room_events)] if isinstance(room_events, (str, Path)) else [Path(source) for source in room_events]
        inputs[ROOM_BATTLE_PATH] = bind_room_events(candidate, sources)
    return inputs


def build_sound_library(base, candidate, actors, reactions):
    manifest_path = Path(bundle_macos.SFX_MANIFEST)
    sounds = export_battle_sfx.export(actors, candidate / manifest_path.parent, reactions=reactions)
    inherited = base / manifest_path
    if not inherited.is_file():
        return sounds

    raw = inherited.read_bytes()
    previous = json.loads(raw)
    cues = {cue['id']: cue for cue in sounds['cues']}
    playback_fields = ('path', 'frames', 'sha256', 'bank', 'program', 'note',
                       'retrigger', 'tone_index', 'occupied_updates', 'pitch_delta')
    for cue in previous['cues']:
        identifier = cue['id']
        replacement = cues.get(identifier)
        if replacement is None:
            cues[identifier] = cue
        elif any(replacement.get(key) != cue.get(key) for key in playback_fields) or replacement.get('restore_stream', False) != cue.get('restore_stream', False):
            raise ValueError(f'conflicting base and battle sound {identifier:#06x}')

    if sounds['schema'] != 'suikoden-battle-sfx/5' and previous['schema'] in ('suikoden-battle-sfx/2', 'suikoden-battle-sfx/3', 'suikoden-battle-sfx/4', 'suikoden-battle-sfx/5'):
        sounds['schema'] = previous['schema']
    sounds['cues'] = [cues[identifier] for identifier in sorted(cues)]
    sounds['unsupported'] = [entry for entry in sounds['unsupported'] if entry['id'] not in cues]
    sounds['base_manifest_sha256'] = hashlib.sha256(raw).hexdigest()
    (candidate / manifest_path).write_text(json.dumps(sounds, indent=2) + '\n')
    return sounds


def assemble(base, battle, output, binary, battlefield_sources=(), *, field_encounters=None, room_events=None, field_rooms=None):
    base, battle, output, binary = (Path(value).resolve() for value in (base, battle, output, binary))
    battlefield_sources = tuple(Path(source).resolve() for source in battlefield_sources)
    if field_rooms is not None:
        field_rooms = Path(field_rooms).resolve()
    accepted = (ROOT / 'kit/work/accepted').resolve()
    if accepted in (output, *output.parents) or output.exists():
        raise ValueError('output must be a new candidate outside accepted staging')
    inputs = (base, battle, *battlefield_sources) + ((field_rooms,) if field_rooms is not None else ())
    if any(output in (source, *source.parents) or source in output.parents for source in inputs):
        raise ValueError('output must not overlap an input package')
    if any(path.is_symlink() for path in base.rglob('*')):
        raise ValueError('canonical source contains a symlink')
    errors = check_journey_package.check(base, canonical=True)
    if errors:
        raise ValueError('invalid canonical source: ' + '; '.join(errors))
    manifest = bundle_macos.checked_content(battle)
    names = {name for name in manifest['files'] if name.startswith('battle/')}
    required = {'battle/trial.json', 'battle/actors.png', 'battle/floor.png', 'battle/ground.png',
                'battle/provenance.json', 'battle/unites.json', 'battle/spells.json',
                'battle/spell_effects.png', 'battle/spells.provenance.json'}
    if not required <= names:
        raise ValueError('current battle export is incomplete')
    battle_actors = json.loads((battle / 'battle/unites.json').read_text())
    actor_schema = battle_actors.get('schema')
    spell_schema = json.loads((battle / 'battle/spells.json').read_text()).get('schema')
    if (actor_schema, spell_schema) not in (('suikoden-unite-actors/19', 'suikoden-spell-scenes/46'),
                                             ('suikoden-unite-actors/23', 'suikoden-spell-scenes/47'),
                                             ('suikoden-unite-actors/24', 'suikoden-spell-scenes/48'),
                                             ('suikoden-unite-actors/25', 'suikoden-spell-scenes/48'),
                                             ('suikoden-unite-actors/26', 'suikoden-spell-scenes/48'),
                                             ('suikoden-unite-actors/26', 'suikoden-spell-scenes/49'),
                                             ('suikoden-unite-actors/27', 'suikoden-spell-scenes/49'),
                                             ('suikoden-unite-actors/28', 'suikoden-spell-scenes/50'),
                                             ('suikoden-unite-actors/29', 'suikoden-spell-scenes/50'),
                                             ('suikoden-unite-actors/29', 'suikoden-spell-scenes/51'),
                                             ('suikoden-unite-actors/30', 'suikoden-spell-scenes/51'),
                                             ('suikoden-unite-actors/31', 'suikoden-spell-scenes/52'),
                                             ('suikoden-unite-actors/32', 'suikoden-spell-scenes/52'),
                                             ('suikoden-unite-actors/34', 'suikoden-spell-scenes/52'),
                                             ('suikoden-unite-actors/35', 'suikoden-spell-scenes/52'),
                                             ('suikoden-unite-actors/36', 'suikoden-spell-scenes/52'),
                                             ('suikoden-unite-actors/37', 'suikoden-spell-scenes/52'),
                                             ('suikoden-unite-actors/38', 'suikoden-spell-scenes/52'),
                                             ('suikoden-unite-actors/39', 'suikoden-spell-scenes/52'),
                                             ('suikoden-unite-actors/40', 'suikoden-spell-scenes/52')):
        raise ValueError('battle export uses an incompatible schema; regenerate the current journey export')
    trial = json.loads((battle / 'battle/trial.json').read_text())
    errors = []
    check_journey_package.check_strike_reactions(battle, trial, battle_actors, errors)
    if errors:
        raise ValueError('invalid battle export: ' + '; '.join(errors))
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='battle-package-', dir=output.parent) as temporary:
        temporary = Path(temporary)
        candidate = temporary / 'package'
        shutil.copytree(base, candidate, ignore=lambda path, names: {'battle', 'manifest.json'} & set(names) if Path(path) == base else set())
        for name in sorted(names):
            destination = candidate / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(battle / name, destination)
        if ROOM_BATTLE_PATH not in names and (base / ROOM_BATTLE_PATH).is_file():
            shutil.copyfile(base / ROOM_BATTLE_PATH, candidate / ROOM_BATTLE_PATH)
        work = temporary / 'profiles'
        if export_opening_profiles.export(candidate, work):
            raise ValueError('opening battle profiles could not be exported')
        report_path = work / 'report.json'
        report = json.loads(report_path.read_text()) if report_path.is_file() else {'status': 'opening profiles already present'}
        additions_path = work / 'opening_additions.json'
        if additions_path.is_file():
            report['runtime_art'] = json.loads(additions_path.read_text())
        if actor_schema == 'suikoden-unite-actors/19':
            actors, ranged_bindings, ranged_proof, graphic_proof = add_ranged_assets(candidate)
            flash_work = temporary / 'flash'
            flash_review = export_unite_review.export(flash_work, include_flash=True, include_master=True,
                                                       base=battle, scenario_records=(10, 31))
            flash_proof = add_flash_assets(candidate, flash_work, flash_review)
            master_proof = add_master_assets(candidate, flash_work, flash_review)
        else:
            existing_proof = json.loads((candidate / 'battle/provenance.json').read_text())
            ranged_bindings = existing_proof['party_ranged_bindings']
            ranged_proof = existing_proof['party_ranged_actors']
            graphic_proof = existing_proof['party_ranged_graphics']
            flash_proof = existing_proof['flash']
            master_proof = existing_proof['master_pupil']
        actors = json.loads((candidate / 'battle/unites.json').read_text())
        proof_path = candidate / 'battle/provenance.json'
        proof = json.loads(proof_path.read_text())
        proof['opening_profile_additions'] = report
        proof['party_ranged_actors'] = ranged_proof
        proof['party_ranged_bindings'] = ranged_bindings
        proof['party_ranged_graphics'] = graphic_proof
        proof['flash'] = flash_proof
        proof['master_pupil'] = master_proof
        if actor_schema in ('suikoden-unite-actors/24', 'suikoden-unite-actors/25', 'suikoden-unite-actors/26', 'suikoden-unite-actors/27', 'suikoden-unite-actors/28', 'suikoden-unite-actors/29', 'suikoden-unite-actors/30', 'suikoden-unite-actors/31', 'suikoden-unite-actors/32'):
            proof['couple'] = existing_proof['couple']
        if actor_schema in ('suikoden-unite-actors/26','suikoden-unite-actors/27', 'suikoden-unite-actors/28', 'suikoden-unite-actors/29', 'suikoden-unite-actors/30', 'suikoden-unite-actors/31', 'suikoden-unite-actors/32'):
            proof['warriors'] = existing_proof['warriors']
        if actor_schema in ('suikoden-unite-actors/27','suikoden-unite-actors/28', 'suikoden-unite-actors/29', 'suikoden-unite-actors/30', 'suikoden-unite-actors/31', 'suikoden-unite-actors/32'):
            proof['martial_arts'] = existing_proof['martial_arts']
        if actor_schema in ('suikoden-unite-actors/28','suikoden-unite-actors/29', 'suikoden-unite-actors/30', 'suikoden-unite-actors/31', 'suikoden-unite-actors/32'):
            proof['beat_em_up'] = existing_proof['beat_em_up']
        if actor_schema in ('suikoden-unite-actors/29','suikoden-unite-actors/30', 'suikoden-unite-actors/31', 'suikoden-unite-actors/32'):
            proof['trick'] = existing_proof['trick']
        proof_path.write_text(json.dumps(proof, indent=2) + '\n')
        for source in battlefield_sources:
            append_battlefield.append(candidate, source)
        import battle_actor_atlas
        battle_actor_atlas.compact_package(candidate/'battle','canonical_opening_profiles')
        field_inputs = bind_field_content(candidate, field_encounters, room_events, field_rooms=field_rooms)
        reactions = json.loads((candidate / 'battle/spells.json').read_text()).get('unite_reactions', [])
        sounds = build_sound_library(base, candidate, actors, reactions)
        export_battle_audio.export(candidate / 'audio')
        export_defeat_audio.export(candidate / 'audio')
        (candidate / 'provenance.json').write_text(json.dumps(dict(
            schema='suikoden-battle-review-proof/1', status='candidate; media acceptance pending',
            canonical_inputs={name: hashlib.sha256((base / name).read_bytes()).hexdigest()
                              for name in ('room.json', 'journey.json', 'atlas.png', 'ui.json',
                                           'party/catalogue.json', 'party/ownership_bindings.json')},
            battle_manifest_sha256=hashlib.sha256((battle / 'manifest.json').read_bytes()).hexdigest(),
            sound_cues=len(sounds['cues']), unsupported_sounds=sounds['unsupported'],
            **({'field_inputs': field_inputs} if field_inputs else {}),
            scope='Existing canonical candidate plus current battle export and its source ranged and Unite bindings; rotated nodes, broader ordinary attacks and media review remain open; no promotion.'), indent=2) + '\n')
        files = {path.relative_to(candidate).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
                 for path in sorted(candidate.rglob('*')) if path.is_file()}
        (candidate / 'manifest.json').write_text(json.dumps(dict(
            schema='suikoden-journey-manifest/1', status='candidate', files=files), indent=2) + '\n')
        bundle_macos.checked_content(candidate)
        errors = check_journey_package.check(candidate, canonical=True)
        if errors:
            raise ValueError('invalid combined candidate: ' + '; '.join(errors))
        subprocess.run([str(binary), '--check-content', str(candidate)], check=True)
        os.replace(candidate, output)
    return output


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', type=Path, default=ROOT / 'kit/work/build/canonical')
    parser.add_argument('--battle', type=Path, default=ROOT / 'kit/work/build/journey')
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--binary', type=Path, default=ROOT / 'game/zig-out/bin/suikoden-journey')
    parser.add_argument('--battlefield-source', type=Path, action='append', default=[],
                        help='bind an existing regional world-battle candidate; repeat for each region')
    parser.add_argument('--field-encounters', type=Path, help='grouped field encounter input or movement encounter packet for journey.json')
    parser.add_argument('--field-rooms', type=Path, help='directory containing authored room rows in room.json and their field atlases')
    parser.add_argument('--room-events', type=Path, action='append',
                        help='room event packet for battle/field_events.json; repeat for more rooms')
    args = parser.parse_args()
    candidate = assemble(args.base, args.battle, args.out, args.binary, args.battlefield_source,
                         field_encounters=args.field_encounters, room_events=args.room_events, field_rooms=args.field_rooms)
    print(f'Verified battle review candidate: {candidate}')

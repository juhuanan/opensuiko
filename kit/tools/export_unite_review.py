#!/usr/bin/env python3
"""Batch source-qualified Unite families for isolated native review."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import shutil
import struct
import tempfile

from PIL import Image
import battle_unite_camera
import character_table
import export_battle_trial as actors
import export_first_room as field
import export_journey
import export_battle_sprite_sections
import export_unite_programs
import export_spell_scenes
import journey_battle
import lzss
import maindec
import preparation
import battle_bin
from spell_effect_entries import entry_image

ROOT = Path(__file__).resolve().parents[2]
ASSETS = ('actors.png', 'floor.png', 'ground.png', 'spell_effects.png', 'spells.json', 'unites.json')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def child_graphics(bundle, proof, atlas):
    """Select member graphic poses from VM children and controller constructors."""
    requested={}
    programs={p['id']:p for p in bundle['programs']['programs']}
    for controller in proof.get('group_controllers',[]):
        binding=next(u for u in bundle['unites'] if u['record']==controller['record'])
        for fan in controller['fans']:
            resource=binding['members'][fan['member']]['id']
            requested.setdefault(resource,set()).add(fan['animation'])
    for program in programs.values():
        for instruction in program['instructions']:
            child=instruction.get('command',{}).get('child')
            if child is None or not child['draw_record']:continue
            selected=requested.setdefault(child['resource'],set())
            selected.add(child['animation'])
            selected.update(i['command']['animation'] for i in programs[child['program']]['instructions'] if 'animation' in i.get('command',{}))
    graphics=[];sources=[]
    for identifier,selected in sorted(requested.items()):
        resource=next(r for r in proof['resources'] if r['id']==identifier)
        origin=resource['source']
        raw,actual=field.source('/'+origin['file'].split('/')[-1])
        if actual!=origin:raise ValueError('Child graphic source identity changed')
        section=resource['section_offset'];base=resource['pointer_base']
        poses,animations,art=actors.section_art(raw,section,base,animation_indices=sorted(selected),selected_poses_only=True)
        table=struct.unpack_from('<I',raw,section+16)[0]-base
        entries=[];bindings=[]
        for pose in sorted({p for animation in selected for p,t in animations[animation]}):
            header=struct.unpack_from('<I',raw,table+4*pose)[0]-base
            # shortcut: one-piece child poses; export individual pieces before binding multi-piece children.
            if raw[header]!=1:raise ValueError('Child pose requires per-piece export')
            x,y,_,_,wm,hm,_,_=raw[header+8:header+16]
            image,ax,ay=poses[pose]
            sprite=actors.pack_pose(atlas,(image.crop((x,y,x+wm+1,y+hm+1)),ax-x,ay-y))
            entries.append(dict(id=pose,sprite=sprite))
            bindings.append(dict(id=pose,source_offset=header,piece_offset=header+8,sprite=sprite))
        graphics.append(dict(id=identifier,poses=entries))
        sources.append(dict(id=identifier,source=origin,section=section,pointer_base=base,animations=sorted(selected),poses=bindings))
    return graphics,sources


def pending_controller_art(output, rows):
    """Export source textures for inventoried controllers without admitting a live scene."""
    output=Path(output).resolve()
    accepted=(ROOT/'kit/work/accepted').resolve()
    if accepted in (output,*output.parents):raise ValueError('Controller art cannot promote accepted content')
    controllers={}
    for row in rows:
        if 'scene_controller' in row:controllers.setdefault(row['scene_controller']['id'],[]).append(row)
    if not controllers:return []
    sections,atlases,errors,data=battle_bin.parse()
    if errors:raise ValueError(errors)
    blobs={a['offset']:a['atlas'] for a in atlases}
    palette=blobs[sections[1]['atlas_offsets'][9]]
    lba,size=battle_bin.battle_bin_lba();result=[]
    for identifier,variants in sorted(controllers.items()):
        controller=dict(variants[0]['scene_controller']);controller.pop('clocks')
        if any(row['scene_controller']['contract']!=controller['contract'] for row in variants):raise ValueError('Conflicting shared controller contract')
        directory=output/'pending_controllers'/identifier;directory.mkdir(parents=True,exist_ok=True)
        atlas=field.Atlas();entries=[];animations=[]
        for kind in ('graphics','wave'):
            request=controller['contract'][kind];section=sections[request['section']]
            source=struct.unpack_from('<I',data,section['tables']['f']+4*request['animation'])[0]-battle_bin.LOAD_BASE
            count,flags,_,_=data[source:source+4]
            if count==0 or flags!=1:raise ValueError('Unbound controller animation descriptor')
            frames=[];pieces={}
            for pose,updates in struct.iter_unpack('BB',data[source+4:source+4+count*2]):
                if pose not in pieces:
                    header=struct.unpack_from('<I',data,section['tables']['e']+4*pose)[0]-battle_bin.LOAD_BASE
                    ids=[]
                    for index in range(data[header]):
                        offset=header+8+index*8;piece=list(data[offset:offset+8])
                        image=entry_image(blobs[section['atlas_offsets'][piece[2]]],palette,piece)
                        ids.append(len(entries));entries.append(dict(rect=atlas.add(image),dx=piece[0]-data[header+4],dy=piece[1]-data[header+5],
                            source_offset=offset,source_entry=piece,page_offset=section['atlas_offsets'][piece[2]],rgba_sha256=hashlib.sha256(image.tobytes()).hexdigest()))
                    pieces[pose]=ids
                frames.append(dict(entries=pieces[pose],updates=updates or 256))
            animations.append(dict(id=kind,section=request['section'],animation=request['animation'],source_offset=source,flags=flags,frames=frames))
        atlas.save(directory/'effects.png')
        packet=dict(schema='suikoden-unite-controller-art/1',id=identifier,status='source_art_candidate',ready_for_runtime=False,
            atlas='effects.png',entries=entries,animations=animations,source=dict(file=battle_bin.DISC_PATH,lba=lba,size=size,
            sha256=hashlib.sha256(data).hexdigest(),decoder=battle_bin.DECODER_ID,palette_page_offset=sections[1]['atlas_offsets'][9]),
            controller=controller,variants=[dict(record=row['index'],members=[m['id'] for m in row['member_scripts']],clocks=row['scene_controller']['clocks']) for row in variants],scope='Shared source textures and controller contract only; no live binding or media acceptance')
        (directory/'controller.json').write_text(json.dumps(packet,indent=2)+'\n')
        result.append(dict(id=identifier,records=controller['records'],path=str((directory/'controller.json').relative_to(output)),
            files={name:digest(directory/name) for name in ('controller.json','effects.png')},ready_for_runtime=False))
    return result


def export(output, include_flash=False, include_master=False, base=None, scenario_records=None, include_couple=False, include_warriors=False, include_martial=False, include_beat=False, extra_hurt_ids=(), include_trick=False):
    output = Path(output).resolve()
    accepted = (ROOT / 'kit/work/accepted').resolve()
    if accepted in (output, *output.parents):
        raise ValueError('Unite review cannot promote accepted content')
    if base is not None:
        source_battle = (Path(base) / 'battle').resolve()
        if output in (source_battle, *source_battle.parents) or source_battle in output.parents:
            raise ValueError('Unite review output overlaps its base battle')
    all_rows=battle_unite_camera.report()
    rows = [row for row in all_rows
            if ('primary_startup' in row and row['index'] not in battle_unite_camera.STARTUP_ONLY_RECORDS) or row['callback_schedule'] is not None or ('phase_schedule' in row and row['phase_schedule']['admission']=='native_vm_scene_bound_visual_acceptance_pending') or 'group_schedule' in row or 'scene_controller' in row or 'family_schedule' in row or (include_flash and row['index']==10) or (include_master and row['index']==31) or (include_couple and row['index']==16) or (include_warriors and row['index']==15) or (include_martial and row['index']==29) or (include_beat and row['index']==27) or (include_trick and row['index']==14)]
    if len(rows) != 25 + int(include_flash) + int(include_master) + int(include_couple) + int(include_warriors) + int(include_martial) + int(include_beat) + int(include_trick):
        raise ValueError('Incomplete qualified Unite families')
    if scenario_records is not None:
        scenario_records = set(scenario_records)
        if not scenario_records <= {row['index'] for row in rows}:
            raise ValueError('Unite scenario is not qualified')
    output.mkdir(parents=True, exist_ok=True)
    _,program_proof=export_unite_programs.export(output/'actor_programs',include_flash=include_flash,include_master=include_master,include_couple=include_couple,include_warriors=include_warriors,include_martial=include_martial,include_beat=include_beat,include_trick=include_trick)
    bundle=json.loads((output/'actor_programs/unites.json').read_text())
    records = {row['id']: row for row in character_table.records()}
    with tempfile.TemporaryDirectory(prefix='suikoden-unite-base-', dir=output.parent) as temporary:
        episode = Path(temporary) / 'episode'
        if base is None:
            _, _, content = export_journey.export(episode, include_unites=False)
        else:
            package = episode / 'battle'
            shutil.copytree(Path(base) / 'battle', package)
            content = json.loads((package / 'trial.json').read_text())
        if any(enemy.get('action_policy') in ('source_melee','source_magic','source_projectile','source_commander','source_rabbit','source_ninja') for enemy in content['enemies']):
            raise ValueError('Standalone Unite review base requires enemy actor bindings; use an isolated base')
        bindings = {preparation.stable_id(r['name']): r['id'] for r in records.values()}
        native_ids = [bindings[p['id']] for p in content['party']]
        package = episode / 'battle'
        base_proof = json.loads((package / 'provenance.json').read_text())
        enemy_data, enemy_source = field.source('/A_DATA.BIN')
        enemy_offsets = []
        for enemy in content['enemies']:
            source = next(row for row in base_proof['enemies'] if row['id'] == enemy['id'])
            offset = source['record_offset'] + 60
            enemy['effect_offset'] = list(struct.unpack_from('<hh', enemy_data, offset))
            enemy_offsets.append(dict(id=enemy['id'], source_offset=offset, value=enemy['effect_offset']))
        atlas = field.Atlas()
        with Image.open(package / 'actors.png') as image:
            atlas.image = Image.new('RGBA', (image.width, 4096))
            atlas.image.paste(image, (0, 0))
            atlas.y = image.height + 1
            base_atlas = dict(width=image.width, height=image.height,
                rgba_sha256=hashlib.sha256(image.convert('RGBA').tobytes()).hexdigest())
        by_id = {profile['id']: profile for profile in content['party']}
        member_ids = sorted({member['id'] for row in rows for member in row['member_scripts']})
        tracks, sources, added = {}, [], set()
        vm_graphics = []
        cast = journey_battle.script_at(maindec.body(), 0x8016C194 - maindec.MBASE)
        _, templates = field.source('SLUS_002.92')
        for native_id in member_ids:
            seed = records[native_id]
            identifier = preparation.stable_id(seed['name'])
            raw, origin = field.source('/' + seed['sprite_file'])
            coordinators = [row for row in rows if any(member['id'] == native_id for member in row['member_scripts'])]
            coordinator = coordinators[0]
            member = next(m for m in coordinator['member_scripts'] if m['id']==native_id)
            primary_scripts = sorted({s['script'] for row in coordinators for m in row['member_scripts'] if m['id']==native_id for s in m['scripts']})
            if include_beat and native_id==13:primary_scripts=sorted(set(primary_scripts)|{9,10,11})
            primary = primary_scripts[0]
            phased = any('phase_schedule' in row for row in coordinators)
            vm_only = primary != 9 or (phased and all('phase_schedule' in row for row in coordinators)) or all('family_schedule' in row for row in coordinators) or any(row['index'] in (10,15,16) for row in coordinators) or all(row['index'] in (14,27,29) for row in coordinators)
            family = 'blacksmith' if coordinator['callback_schedule'] is not None else 'fisherman' if coordinator['initializer'] in (0x800F9920,0x800F9AE8) else 'talisman'
            return_ids = {bundle['unites'][row['index']]['return_program'] for row in coordinators}
            returning = []
            for identifier_return in sorted(value for value in return_ids if value is not None):
                address = {'common/unite_return':0x8016D214,'common/fisherman_return':0x8016D258}[identifier_return]
                returning += journey_battle.script_at(maindec.body(), address - maindec.MBASE)
            operations = cast + returning
            for script in (1, 4, *primary_scripts):
                operations += journey_battle.script(raw, script)
            selected = {0, *(args[0] for op, args in operations if op == 4)}
            if (include_martial and native_id in (66,6,52)) or (include_beat and native_id in (6,13)) or (include_trick and native_id in (76,39)):
                resource = next(r for r in bundle['animations']['resources'] if r['id'] == identifier)
                selected.update(clip['id'] for clip in resource['clips'])
            packet_footprint = native_id in (10,21) or (include_master and native_id == 8) or ((include_master or include_flash) and native_id == 91)
            if vm_only:
                decoded = export_battle_sprite_sections.decode_section(raw,struct.unpack_from('<I',raw,36)[0],character_id=identifier,axis_aligned_packet=packet_footprint)
                if any(piece.outside_samples for pose in decoded.poses for piece in pose.pieces):
                    raise ValueError('Unbound neighboring page for Unite member')
                poses=[(pose.image,pose.anchor_x,pose.anchor_y) for pose in decoded.poses]
                source_animations,_,_=battle_unite_camera.animation_frames(raw)
                animations=[source_animations[index] if index in selected else [] for index in range(len(source_animations))]
                proof=dict(section=decoded.section_offset,sampling='axis_aligned_packet' if packet_footprint else 'inclusive',poses=[pose.source_offset for pose in decoded.poses],
                           animations=[animation.source_offset if animation.index in selected else None for animation in decoded.animations])
            else:
                poses, animations, proof = actors.section_art(
                    raw, struct.unpack_from('<I', raw, 36)[0], animation_indices=sorted(selected))
            if identifier not in by_id:
                attack, motion = ([], None) if vm_only else actors.attack_schedule(raw, poses, animations, atlas)
                weapon = maindec.mword(0x80165890 + 4 * seed['weapon_id'])
                range_code = maindec.body()[weapon - maindec.MBASE + 0x56]
                profile = dict(id=identifier, name=seed['name'], max_hp=seed['hp_max'],
                    level=seed['level'], growth=seed['growth'],
                    stats=dict(zip(('attack', 'skill', 'defense', 'speed', 'magic', 'luck'), seed['stats'], strict=True)),
                    sprite=actors.pack_pose(atlas, poses[animations[0][0][0]]),
                    foot_offset_y=actors.foot_offset_y(poses[animations[0][0][0]]),
                    attack=attack, motion=motion, rune=None,
                    weapon_range={1: 'short', 2: 'long', 3: 'medium'}[range_code])
                by_id[identifier] = profile
                content['party'].append(profile)
                native_ids.append(native_id)
                added.add(identifier)
            tracks[native_id] = journey_battle.export_tracks(raw, poses, animations, atlas, None if vm_only else family)
            primary_ops=journey_battle.script(raw,primary)
            trails=journey_battle.trail_bindings(animations,primary_ops) if any(op==35 and args==(0,4) for op,args in primary_ops) else []
            entries=[dict(id=pose,sprite=actors.pack_pose(atlas,poses[pose])) for pose in sorted({p for animation in selected for p,t in animations[animation]})]
            frozen_bindings={}
            for script in primary_scripts:
                script_ops=journey_battle.script(raw,script)
                if not any(op==35 and args==(0,4) for op,args in script_ops):continue
                initial_animation=18 if include_beat and native_id==13 and script==11 else 0
                for binding in journey_battle.trail_bindings(animations,script_ops,initial_animation=initial_animation):
                    frozen_bindings.setdefault(binding['pose'],(script_ops,binding))
            for frozen,(script_ops,binding) in sorted(frozen_bindings.items()):
                trail=journey_battle.export_trail(raw,poses,animations,atlas,script_ops,binding)
                next(entry for entry in entries if entry['id']==frozen)['trail']=trail['poses']
            if any(op==38 for op,args in operations):
                white=struct.unpack_from('<32H',maindec.body(),0x8016B8A8-maindec.MBASE)
                white_poses,_,_=actors.section_art(raw,struct.unpack_from('<I',raw,36)[0],palette_override=white,animation_indices=sorted(selected),selected_poses_only=True,axis_aligned_packet=(include_master and native_id == 8) or ((include_master or include_flash) and native_id == 91))
                for entry in entries:entry['white']=actors.pack_pose(atlas,white_poses[entry['id']])
                proof['white_palette']=dict(source='MAIN.EXE',lba=maindec.EXE_LBA,address=0x8016B8A8,words=32,sha256=hashlib.sha256(struct.pack('<32H',*white)).hexdigest())
            if any(op==42 and args==(3,0,1,4) for op,args in operations):
                variants=[]
                for row in (1,2,3):
                    palette=struct.unpack_from('<32H',maindec.body(),0x8016B8A8-maindec.MBASE+64*row)
                    variant,_,_=actors.section_art(raw,struct.unpack_from('<I',raw,36)[0],palette_override=palette,animation_indices=sorted(selected),selected_poses_only=True,axis_aligned_packet=packet_footprint)
                    variants.append(variant)
                for entry in entries:entry['flash']=[actors.pack_pose(atlas,variant[entry['id']]) for variant in variants]
                proof['flash_palettes']=dict(source='MAIN.EXE',lba=maindec.EXE_LBA,address=0x8016B8A8,rows=[1,2,3])
            vm_graphics.append(dict(id=identifier,poses=entries))
            sources.append(dict(id=identifier, native_id=native_id, source=origin,
                template_source=templates, template_image_offset=seed['off'],
                template_file_offset=2048 + seed['off'], decoder=f'lzss.py v{lzss.__version__}',
                art_decoder='export_battle_sprite_sections.py / suikoden-battle-sprite-sections/1' if vm_only else 'export_battle_trial.py section_art',
                selected_animations=sorted(selected), art=proof,
                primary_script=primary,vm_only=vm_only,
                trails=trails))
            if len(sources[-1]['trails'])==1:sources[-1]['trail']=sources[-1]['trails'][0]
            if len(primary_scripts)>1:sources[-1]['primary_scripts']=primary_scripts
        for row in rows:
            schedule = row['callback_schedule']
            assists = {item['member'] for item in (schedule or row.get('direct_assists',{})).get('assists',[])}
            dispatches = schedule['dispatches'] if schedule else [dict(member=index,callback_counter=0) for index in range(len(row['member_scripts']))]
            for dispatch, member in zip(dispatches, row['member_scripts'], strict=True):
                profile = by_id[preparation.stable_id(records[member['id']]['name'])]
                profile.update(copy.deepcopy({key:value for key,value in tracks[member['id']].items()
                                              if row['index'] not in (14,27,29) or not key.startswith('unite_')}))
                profile['unite_scenes'] = [scene for scene in profile.get('unite_scenes',[]) if scene['record'] != row['index']]
                if row['member_scripts'][0]['scripts'][0]['script']==9 and 'phase_schedule' not in row and row['index'] not in (10,14,27,29):
                    journey_battle.bind_unite_scene(profile, row['index'], dispatch['callback_counter'],
                        reaction_on_hit=dispatch['member'] in assists)
        preparation_proof = preparation.export(content, native_ids)
        for profile in content['party']:
            if profile['id'] in added:
                profile['stats']['attack'] += profile['weapon']['powers'][profile['weapon']['initial_level'] - 1]
        content['unite_graphics'],graphic_sources=child_graphics(bundle,program_proof,atlas)
        for graphic in vm_graphics:
            destination=next((value for value in content['unite_graphics'] if value['id']==graphic['id']),None)
            if destination is None:content['unite_graphics'].append(graphic)
            else:
                if {pose['id'] for pose in graphic['poses']} & {pose['id'] for pose in destination['poses']}:
                    raise ValueError('Conflicting member/child pose binding')
                destination['poses'].extend(graphic['poses'])
        item_art = journey_battle.append_item_art(content, atlas)
        content['schema'] = 'suikoden-battle-trial/34' if include_couple else 'suikoden-battle-trial/33'
        # Review-only living targets keep all four reactions visible without changing canonical balance.
        for enemy in content['enemies']:
            enemy['max_hp'] = 5000
        atlas.save(package / 'actors.png')
        (package / 'trial.json').write_text(json.dumps(content, separators=(',', ':')) + '\n')
        origin = dict(schema='suikoden-unite-review-battle-provenance/1',
            producer='export_unite_review.py v27', members=sources, child_graphics=graphic_sources, item_actor_art=item_art, preparation=preparation_proof,
            base_atlas=base_atlas,
            enemy_offsets=dict(source=enemy_source, records=enemy_offsets),
            controllers=[dict(record=r['index'], schedule=r['callback_schedule']) for r in rows if r['callback_schedule'] is not None],
            families=[dict(record=r['index'], schedule=r['family_schedule']) for r in rows if 'family_schedule' in r],
            pairs=[dict(record=r['index'],startup=r['primary_startup']) for r in rows if 'primary_startup' in r],
            base_episode=base_proof,
            review_overrides=dict(enemy_max_hp=5000, unbound_ordinary_attacks=[member['id'] for member in sources if member['vm_only']], party_selection='per-record review roster'),
            timing_scope='Source startup and native VM startup mapping are qualified for the selected records; broader engine hooks, KO behavior and media acceptance remain unqualified.')
        (package / 'provenance.json').write_text(json.dumps(origin, indent=2) + '\n')
        shared = output / 'shared'
        extra_scenes=[]
        if include_flash:
            import unite_scene_flash
            extra_scenes=[dict(id='flash',name='Flash Attack',program=unite_scene_flash.program(),blocker=None)]
        export_spell_scenes.export(package, shared, extra_hurt_ids=extra_hurt_ids, extra_unite_scenes=extra_scenes, include_couple=include_couple, include_warriors=include_warriors, include_martial=include_martial,include_beat=include_beat)
        shutil.copyfile(output / 'actor_programs/unites.json', shared / 'unites.json')
        scenarios = []
        for row in rows:
            if scenario_records is not None and row['index'] not in scenario_records:
                continue
            directory = output / f"record_{row['index']:02d}"
            directory.mkdir(exist_ok=True)
            scenario = copy.deepcopy(content)
            members = [preparation.stable_id(records[m['id']]['name']) for m in row['member_scripts']]
            scenario['initial_party'] = members + [id for id in content['initial_party'] if id not in members][:6-len(members)]
            scenario['encounters'][0]['title'] = row['name'] + ': ' + ', '.join(records[m['id']]['name'] for m in row['member_scripts'])
            payload = json.dumps(scenario, separators=(',', ':')) + '\n'
            if len(payload.encode()) > 1024 * 1024:
                raise ValueError('Unite review exceeds native content limit')
            (directory / 'trial.json').write_text(payload)
            for name in ASSETS:
                shutil.copyfile(shared / name, directory / name)
            scenarios.append(dict(record=row['index'], directory=directory.name,
                members=members, files={name: digest(directory / name) for name in ('trial.json', *ASSETS)}))
        proof = dict(schema='suikoden-unite-review/1', status='candidate', producer='export_unite_review.py v27',
            members=sources, child_graphics=graphic_sources, scenarios=scenarios, preparation=preparation_proof,
            actor_programs=dict(path='actor_programs/provenance.json',sha256=digest(output / 'actor_programs/provenance.json')),
            review_overrides=dict(enemy_max_hp=5000, unbound_ordinary_attacks=[member['id'] for member in sources if member['vm_only']], party_selection='source participants plus unreserved episode members'),
            timing_scope='Source startup and native VM startup mapping are qualified for the selected records; broader engine hooks, KO behavior and GPU/media remain unqualified.',
            trail_scope='Fixed allocation pose, eight retained screen snapshots and premodulated RGB555 tint variants; half-background blending. GPU/media and projection fidelity remain unqualified.',
            scope='Real member art and recipient effects; native/window/media review and knockout tails remain separate.')
        proof['pending_controllers']=pending_controller_art(output,all_rows) if scenario_records is None else []
        (output / 'provenance.json').write_text(json.dumps(proof, indent=2) + '\n')
    return proof


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, default=ROOT / 'kit/work/build/unite_review')
    parser.add_argument('--include-flash', action='store_true')
    parser.add_argument('--include-master', action='store_true')
    parser.add_argument('--include-couple', action='store_true')
    parser.add_argument('--include-warriors', action='store_true')
    parser.add_argument('--include-martial', action='store_true')
    parser.add_argument('--include-beat', action='store_true')
    parser.add_argument('--include-trick', action='store_true')
    args = parser.parse_args()
    result = export(args.out, include_flash=args.include_flash, include_master=args.include_master, include_couple=args.include_couple, include_warriors=args.include_warriors, include_martial=args.include_martial,include_beat=args.include_beat,include_trick=args.include_trick)
    print(f"Exported {len(result['scenarios'])} Unite review scenarios; candidate only")

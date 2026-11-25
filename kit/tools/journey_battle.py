"""Semantic rules and timed actor tracks used by the connected episode export."""
import struct
import actor_script
import maindec
import journey_magic
import export_battle_trial as trial


def script(data, index, table=None, base=0):
    table = struct.unpack_from('<I', data, 32)[0] if table is None else table-base
    cursor = struct.unpack_from('<I', data, table + 4 * index)[0]-base
    return script_at(data, cursor)


def script_at(data, cursor):
    if not 0 <= cursor < len(data):
        raise ValueError('actor script outside source')
    result = []
    for _ in range(512):
        op = struct.unpack_from('<H', data, cursor)[0]
        if op in (0, 1, 2): return result + [(op, ())]
        if op == 36:
            # A tail dispatch ends this contiguous stream; its caller resolves the table slot.
            return result + [(op, struct.unpack_from('<h', data, cursor + 2))]
        length = actor_script.OP_LEN_HW.get(op)
        if op == 42:
            count = struct.unpack_from('<h', data, cursor + 2)[0]
            if count < 0: raise ValueError('negative inline actor operand count')
            length = 2 + count
        if not length: raise ValueError('unsupported connected actor script')
        args = struct.unpack_from('<' + 'h' * (length - 1), data, cursor + 2)
        result.append((op, args))
        if op in (0, 1): return result
        cursor += 2 * length
    raise ValueError('unterminated connected actor script')


def bonbon_motion(data, record):
    table = struct.unpack_from('<I', data, record+40)[0]
    clock = pending_end = 0
    stages = []
    impact = ready = None
    for index in (1,4):
        for op,args in script(data,index,table,0x80080000):
            if op == 23:
                mode,duration,x,y,z,vx,vy,vz=args
                if mode not in (2,3) or duration<2:raise ValueError('unsupported BonBon motion')
                stages.append(dict(start=clock,home=mode==3,leap=dict(ticks=duration,acceleration_step=1/4096,
                    offset=dict(zip('xyz',(x,y,z))),velocity=dict(zip('xyz',(vx/2,vy/2,vz/2))))))
                pending_end=clock+duration
            elif op == 3:clock+=args[0]
            elif op == 21:clock=max(clock,pending_end)
            elif op == 26:
                if args==(0,2):impact=clock
                elif args==(0,4):ready=clock
            elif op not in (0,9,15,16,34):raise ValueError('unsupported BonBon attack operation')
    if len(stages)!=2 or stages[0]['home'] or not stages[1]['home'] or impact is None or ready is None:
        raise ValueError('missing BonBon attack phases')
    return dict(approach_start=stages[0]['start'],approach=stages[0]['leap'],impact_tick=impact,
                ready_tick=ready,return_start=stages[1]['start'],retreat=stages[1]['leap'],duration=clock)


class UnresolvedActorClock(ValueError):
    pass


def script_events(animations, operations, animation_flags=None, *, initial_movement_wait=False):
    """Actor-local clocks; recipient dispatch polls an initial move before integration."""
    clock = selected = selected_at = pending_end = 0
    events = {}
    operation_ticks = []
    instant = {0, 1, 6, 8, 9, 13, 14, 15, 16, 17, 18, 19, 20, 24, 25, 26, 27, 34, 35, 38, 39, 40, 41, 42, 43}
    for op, args in operations:
        operation_ticks.append(clock)
        if op == 4:
            selected, selected_at = args[0], clock
        elif op in (23, 33):
            pending_end = clock + (max(1,args[1]) if op == 33 else args[1]) + (initial_movement_wait and clock == 0)
        elif op == 22:
            pending_end = clock + args[0] + (initial_movement_wait and clock == 0)
        elif op == 30:
            # The mailbox write returns pending on entry and advances on the next poll.
            clock += 1
        elif op == 3:
            clock += max(1,args[0])
        elif op == 21:
            clock = max(clock, pending_end)
        elif op == 5:
            if animation_flags is not None:
                if not animation_flags[selected] & 1:
                    continue
                if animation_flags[selected] & 2:
                    raise UnresolvedActorClock(f'animation {selected} loops without a completion flag')
            if not animations[selected]:
                raise UnresolvedActorClock(f'animation {selected} has no exported frame durations')
            clock = max(clock, selected_at + sum(t or 256 for _, t in animations[selected]))
        elif op == 2:
            break
        elif op == 26 and args[0] == 0:
            events[args[1]] = clock
        elif op not in instant:
            raise ValueError(f'unsupported actor clock opcode {op}')
    return dict(duration=clock, events=events, operation_ticks=operation_ticks)



def camera_requests(animations, operations, animation_flags=None):
    """Normalize selected actor camera requests; focus operands already carry Q12 units."""
    clocks = script_events(animations, operations, animation_flags)
    requests = []
    for at, (op, args) in zip(clocks['operation_ticks'], operations, strict=True):
        if op not in (17, 18, 19, 20):
            continue
        if op == 20:
            mode, updates, x, y, z = args
            if mode not in (0, 1, 2):
                raise ValueError('unsupported actor camera focus binding')
            binding = ('absolute', 'actor', 'target')[mode]
            vector = [x, y, z if mode == 0 else 0]
            channel = 'focus'
        else:
            updates, x, y, z = args
            vector = [value * 4096 for value in (x, y, z)]
            channel = {17:'angles', 18:'translation', 19:'scale'}[op]
            binding = 'absolute'
        if not 1 <= at <= 1000 or not 1 <= updates <= 1000:
            raise ValueError('invalid actor camera request clock')
        requests.append(dict(at=at, updates=updates, channel=channel, binding=binding, target_q12=vector))
    return requests


def track(poses, animations, atlas, operations):
    """Advance animation and movement clocks together, then export ordinary timed poses."""
    clock = selected = selected_at = 0
    pending_end = 0
    frames, stages = [], []
    packed = {}
    impact = None
    for op, args in operations:
        if op == 4: selected, selected_at = args[0], clock
        elif op == 23:
            mode, duration, x, y, z, vx, vy, vz = args
            assert mode in (2, 3) and duration >= 2
            stages.append(dict(start=clock, home=mode == 3,
                leap=dict(ticks=duration, acceleration_step=1/4096, offset=dict(zip('xyz', (x, y, z))), velocity=dict(zip('xyz', (vx/2, vy/2, vz/2))))))
            pending_end = clock + duration
        elif op == 26 and args in ((0, 2), (0, 8)): impact = clock
        ticks = 1 if op == 30 else args[0] if op == 3 else max(0, pending_end - clock) if op == 21 else max(0, sum(t or 256 for _, t in animations[selected]) - (clock-selected_at)) if op == 5 else 0
        if op not in (0,1,3,4,5,9,13,14,15,16,20,21,23,26,30,34,35,40,43): raise ValueError('unsupported timed actor operation')
        if not 0 <= ticks <= 1000: raise ValueError('invalid actor wait')
        for _ in range(ticks):
            elapsed = clock-selected_at
            pose_index = animations[selected][-1][0]
            for e, duration in animations[selected]:
                if elapsed < (duration or 256): pose_index = e; break
                elapsed -= duration or 256
            if pose_index not in packed: packed[pose_index] = trial.pack_pose(atlas, poses[pose_index])
            pose = packed[pose_index]
            if frames and frames[-1]['source_pose'] == pose_index and frames[-1]['ticks'] < 256: frames[-1]['ticks'] += 1
            else: frames.append(dict(pose=pose, ticks=1, source_pose=pose_index))
            clock += 1
    return frames, stages, impact, clock


def screen_offsets(animations, operations):
    """Lower qualified opcode43 targets while their movement counter is active."""
    clocks = script_events(animations, operations)
    end = 0
    result = []
    for at, (op, args) in zip(clocks['operation_ticks'], operations, strict=True):
        if op == 23:
            end = at + args[1]
        elif op == 43:
            mode, x, y = args
            if mode not in (0, 2) or at >= end:
                raise ValueError('Unbound Unite screen offset operation')
            result.append(dict(start=at, updates=end-at, target=mode == 2, value=[x, y]))
    return result


def trail_bindings(animations, operations, *, initial_animation=0):
    """Each shared blue trail retains the allocation pose until its own mailbox stop."""
    clocks = script_events(animations, operations)['operation_ticks']
    result=[];selected=initial_animation;mailbox=None;active=None
    for at,(op,args) in zip(clocks,operations,strict=True):
        if op==4:selected=args[0]
        elif op==30:
            mailbox=args[0]
            if active is not None:
                if mailbox!=99:raise ValueError('Unbound Unite trail lifetime')
                active['stop']=at;result.append(active);active=None
        elif op==35:
            if args!=(0,4) or mailbox!=0 or active is not None:
                raise ValueError('Unbound Unite trail lifetime')
            active=dict(start=at,animation=selected,pose=animations[selected][0][0])
    if active is not None or not result:raise ValueError('Unbound Unite trail lifetime')
    # The callback sees the final animation selected in its installation pass.
    for binding in result:
        for at,(op,args) in zip(clocks,operations,strict=True):
            if at>binding['start']:break
            if op==4:binding.update(animation=args[0],pose=animations[args[0]][0][0])
    return result


def trail_binding(animations, operations):
    bindings=trail_bindings(animations,operations)
    if len(bindings)!=1:raise ValueError('Unbound Unite trail lifetime')
    return bindings[0]


def export_trail(data, poses, animations, atlas, operations, trail=None):
    """Bake the shared blue ring's fixed allocation pose with RGB555 modulation."""
    if trail is None:trail = trail_binding(animations, operations)
    return dict(start=trail['start'],stop=trail['stop'],poses=export_blue_poses(data,poses,atlas,trail['pose']))


def export_blue_poses(data, poses, atlas, pose_index, section=None, base=0):
    """Pack the frozen eight-age palette shared by member and child actors."""
    from battle_unite_camera import blacksmith_trail, Image
    binding = blacksmith_trail(Image(maindec.body(), maindec.MBASE))
    section = struct.unpack_from('<I', data, 36)[0]-base if section is None else section
    palettes, entries = (value-base for value in struct.unpack_from('<II', data, section + 12))
    entry = struct.unpack_from('<I', data, entries + pose_index * 4)[0]-base
    for palette in {data[entry + 8 + piece * 8 + 6] for piece in range(data[entry])}:
        address = struct.unpack_from('<I', data, palettes + palette * 4)[0]-base
        if any(word != 0 and not word & 0x8000 for word in struct.unpack_from('<32H', data, address)):
            raise ValueError('Mixed opaque/semitransparent Unite trail requires per-pixel blending')
    source_pose = poses[pose_index]
    tinted = []
    for factors in binding['full_ring_rgb_newest_first']:
        image = source_pose[0].copy()
        for y in range(image.height):
            for x in range(image.width):
                pixel = image.getpixel((x, y))
                channels = [min(31, (pixel[axis] >> 3) * factors[axis] // 128) for axis in range(3)]
                image.putpixel((x, y), (*[(v << 3) | (v >> 2) for v in channels], pixel[3]))
        tinted.append(trial.pack_pose(atlas, (image, *source_pose[1:])))
    return tinted


def export_tracks(data, poses, animations, atlas, unite=None):
    returns = {'talisman': 0x8016D214, 'fisherman': 0x8016D258, 'blacksmith': 0x8016D214}
    if unite is not None and unite not in returns:
        raise ValueError('Unbound Unite return descriptor')
    cast_ops = script_at(maindec.body(), 0x8016C194-maindec.MBASE)
    cast, _, impact, _ = track(poses, animations, atlas, cast_ops)
    result = dict(cast=cast, cast_impact=impact, revival_art=revival_art(data, atlas))
    if unite:
        operations = script(data, 9)
        _, stages, impact, ready = track(poses, animations, atlas, operations)
        return_script = returns[unite]
        return_ops = script_at(maindec.body(), return_script-maindec.MBASE)
        # Each member enters the shared return from its own ready flag.
        all_frames, all_stages, _, duration = track(poses, animations, atlas, operations + return_ops)
        retreat = all_stages[-1]
        assert retreat['home'] and all(not s['home'] for s in stages)
        result.update(unite_camera=camera_requests(animations,operations), unite_attack=all_frames, unite_motion=dict(
            approach_start=stages[0]['start'], approach=stages[0]['leap'], stages=stages,
            impact_tick=impact, ready_tick=ready, return_start=retreat['start'], retreat=retreat['leap'], duration=duration))
        result['unite_trail'] = export_trail(data, poses, animations, atlas, operations)
        if unite == 'blacksmith':
            result['unite_offsets'] = screen_offsets(animations, operations + return_ops)
    return result


def revival_art(data, atlas):
    """Named clips selected by the common KO/revival descriptor, not a sprite grid."""
    return named_actor_art(data, atlas, (('down',3),('recovery',2)))


def named_actor_art(data, atlas, selected):
    section = struct.unpack_from('<I', data, 36)[0]
    poses,animations,_ = trial.section_art(data,section,animation_indices=[index for _,index in selected],selected_poses_only=True,axis_aligned_packet=True)
    table = struct.unpack_from('<I', data, section+20)[0]
    clips = {}
    packed = {}
    for name,index in selected:
        pointer = struct.unpack_from('<I', data, table+index*4)[0]
        flags = data[pointer+1]
        if not animations[index]: raise ValueError('Missing actor animation')
        frames = []
        for pose,updates in animations[index]:
            if poses[pose] is None: raise ValueError('Missing actor pose')
            if pose not in packed:packed[pose]=trial.pack_pose(atlas,poses[pose])
            frames.append(dict(pose=packed[pose],ticks=updates or 256,source_pose=pose))
        clips[name] = dict(advances=bool(flags&1),loop=bool(flags&2),frames=frames)
    return clips


def append_item_art(content, atlas):
    """Append source item clips without moving any existing atlas entry."""
    import character_table
    import preparation
    from export_first_room import source
    records={preparation.stable_id(row['name']):row for row in character_table.records()}
    proof=[]
    selected=(('idle',0),('prepare',13),('hold',14),('recover',15))
    for profile in content['party']:
        if 'item_art' in profile:continue
        raw,origin=source('/'+records[profile['id']]['sprite_file'])
        profile['item_art']=named_actor_art(raw,atlas,selected)
        section=struct.unpack_from('<I',raw,36)[0];table=struct.unpack_from('<I',raw,section+20)[0]
        proof.append(dict(id=profile['id'],source=origin,section=section,
            animations={name:dict(index=index,source_offset=struct.unpack_from('<I',raw,table+4*index)[0]) for name,index in selected},
            decoder='export_battle_trial.section_art; axis_aligned_packet; lzss.decode_strict v2.0.0'))
    from export_world_travel import medicine_timings
    content['medicine_timings']=medicine_timings([profile['id'] for profile in content['party']])
    return proof


def append_physical_profiles(content, atlas, packet):
    """Complete innate technique-owner catalogue data without changing the owned party."""
    import copy
    import character_table
    import preparation
    from export_first_room import source
    records = {preparation.stable_id(row['name']): row for row in character_table.records()}
    existing = {profile['id'] for profile in content['party']}
    requested = {member for binding in packet['techniques'] if binding['id'] != 'clone' for member in binding['members']}
    profiles, native_ids, proof = [], [], []
    cast = script_at(maindec.body(), 0x8016C194 - maindec.MBASE)
    _, templates = source('SLUS_002.92')
    for identifier in sorted(requested - existing):
        seed = records[identifier]
        raw, origin = source('/' + seed['sprite_file'])
        operations = cast + script(raw, 1) + script(raw, 4)
        selected = sorted({0, *(args[0] for op, args in operations if op == 4)})
        section = struct.unpack_from('<I', raw, 36)[0]
        poses, animations, art = trial.section_art(raw, section, animation_indices=selected, selected_poses_only=True)
        attack, motion = trial.attack_schedule(raw, poses, animations, atlas)
        weapon = maindec.mword(0x80165890 + 4 * seed['weapon_id'])
        rune = next(row for row in preparation.rune_bindings() if row['rune']==seed['rune_id'])
        rune_id = next(row['id'] for row in content['systems']['runes'] if row.get('crystal')==rune['id'])
        profile = dict(id=identifier, name=seed['name'], max_hp=seed['hp_max'],
            level=seed['level'], growth=seed['growth'],
            stats=dict(zip(('attack','skill','defense','speed','magic','luck'), seed['stats'], strict=True)),
            sprite=trial.pack_pose(atlas, poses[animations[0][0][0]]),
            foot_offset_y=trial.foot_offset_y(poses[animations[0][0][0]]),
            attack=attack, motion=motion, rune=rune_id,
            weapon_range={1:'short',2:'long',3:'medium'}[maindec.body()[weapon-maindec.MBASE+0x56]])
        profile.update(export_tracks(raw, poses, animations, atlas))
        profiles.append(profile); native_ids.append(seed['id'])
        proof.append(dict(id=identifier, native_id=seed['id'], source=origin,
            template_source=templates, template_image_offset=seed['off'], template_file_offset=2048+seed['off'],
            selected_animations=selected, art=art, scripts=[1,4], initial_rune_byte=seed['rune_id'],
            decoder='export_battle_trial.section_art; lzss.decode_strict v2.0.0',
            policy='Catalogue data only; not initially owned or recruited'))
    if not profiles:
        return []
    added = dict(party=profiles, systems=copy.deepcopy(content['systems']))
    preparation_proof = preparation.export(added, native_ids)
    for profile in profiles:
        profile['stats']['attack'] += profile['weapon']['powers'][profile['weapon']['initial_level']-1]
    for kind in ('equipment','runes'):
        incoming = {row['id']:row for row in added['systems'][kind]}
        for row in content['systems'][kind]:
            if row.get('allowed_members') is None:
                continue
            row['allowed_members'].extend(member for member in incoming[row['id']]['allowed_members'] if member not in row['allowed_members'])
    content['party'].extend(profiles)
    item_proof = append_item_art(content, atlas)
    for entry in proof:
        entry['preparation'] = next(row for row in preparation_proof['characters'] if row['character']==entry['id'])
        entry['item_art'] = next(row for row in item_proof if row['id']==entry['id'])
    return proof


def bind_unite_scene(profile, record, start_after=0, reaction_on_hit=False):
    """Key a decoded member track by record and dispatch offset in actor updates."""
    scenes = profile.get('unite_scenes', [])
    if type(record) is not int or not 0 <= record < 32 or any(s['record'] == record for s in scenes):
        raise ValueError('Invalid or duplicate Unite scene record')
    if 'unite_attack' not in profile or 'unite_motion' not in profile:
        raise ValueError('Missing decoded Unite member track')
    if type(start_after) is not int or not 0 <= start_after <= 1000 or (start_after and start_after + profile['unite_motion']['duration'] > 1000):
        raise ValueError('Invalid Unite member dispatch offset')
    if type(reaction_on_hit) is not bool:
        raise ValueError('Invalid Unite hit-reaction binding')
    profile['unite_scenes'] = scenes
    scenes.append(dict(record=record, track=dict(attack=profile.pop('unite_attack'),
        motion=profile.pop('unite_motion'), camera=profile.pop('unite_camera', []))))
    if start_after:
        scenes[-1]['track']['start_after'] = start_after
    if reaction_on_hit:
        scenes[-1]['track']['reaction_on_hit'] = True
    if 'unite_offsets' in profile:
        scenes[-1]['track']['screen_offsets'] = profile.pop('unite_offsets')
    if 'unite_trail' in profile:
        scenes[-1]['track']['trail'] = profile.pop('unite_trail')


ENEMY_IDS = {'bonbon': 1, 'wild_boar': 4, 'crow': 3, 'red_soldier_ant': 5, 'mosquito': 2}

def append_later_enemies(battle, atlas, species=None):
    """Export qualified species and whole source formations; do not add field triggers."""
    from export_physical_runes import LATER_ENEMIES
    from export_first_room import source
    from export_battle_audio import encounter_music
    from export_shop import consumables
    import item_tables
    import preparation
    import journey_magic
    species=LATER_ENEMIES if species is None else species
    names={row['id']:preparation.stable_id(row['name']) for row in item_tables.items()}
    appraised={row['id']:bool(item_tables.half(row['addr']+28)&0x7000) for row in item_tables.items()}
    uses={row['id']:row['uses'] for row in consumables()[0]}
    proof=[];formations=[];skipped=[]
    for region in sorted({r for r,_,_ in species}):
        raw,origin=source('/'+region.upper()+'_DATA.BIN')
        _,_,directory,selectors=trial.encounters.chain(raw)
        table=struct.unpack_from('<I',raw,directory-trial.encounters.BASE+12)[0]
        sections,errors=trial.enemy_sprites.parse_sections(raw)
        if errors:raise ValueError(errors)
        by_offset={s['header_offset']:s for s in sections}
        ids={native:identifier for r,native,identifier in species if r==region}
        for native,identifier in ids.items():
            if any(e['id']==identifier for e in battle['enemies']):raise ValueError('duplicate later enemy')
            profile,row=trial.enemy_profile(raw,table,native,identifier,atlas,by_offset)
            record=raw[row['record_offset']:row['record_offset']+64]
            profile['stats']['magic'],profile['stats']['luck']=struct.unpack_from('<2H',record,28)
            flags=struct.unpack_from('<H',record,38)[0]
            if flags&0x8000:raise ValueError('unqualified forced enemy rejection')
            profile.update(affinities={element:('neutral','weak','resistant','immune')[record[32+i]] for i,element in enumerate(journey_magic.ELEMENTS)},
                other_affinity=('neutral','weak','resistant','immune')[record[37]],
                death_immune=bool(flags&0x4000),airborne=bool(flags&32),dodges_attacks=bool(flags&4),unavoidable_attack=bool(flags&8),
                target_policy='front_first',action_policy='source_melee')
            profile['fire_affinity']=profile['affinities']['fire']
            profile['drops']=[]
            for item,rate in zip(record[54:60:2],record[55:60:2],strict=True):
                if item and item not in names:raise ValueError('unknown later enemy drop')
                name=names[item] if item else None
                profile['drops'].append(dict(item=name,uses=uses.get(name,0),rate=rate,identified=not appraised.get(item,False)))
            battle['enemies'].append(profile)
            proof.append(dict(**row,source=origin,feature_bits=flags,decision_callback=hex(struct.unpack_from('<I',record,48)[0])))
        _,selected=trial.encounters.selectors_table(raw,selectors)
        supported={row['id'] for row in battle['enemies']}
        extra_supported=(('b',1,'killer_rabbit'),('b',3,'beast_commander'),('d',1,'holly_fairy'),('d',3,'creeper'),('e',1,'whip_wolf'),('e',2,'sorcerer'),('f',2,'shadow_man'),('f',3,'mirage_f'),('g',1,'dagon'),('g',3,'siren'),('h',2,'mirage_h'),('h',3,'earth_golem'),('z',1,'ninja_master'))
        ids={native:identifier for r,native,identifier in (*LATER_ENEMIES,*extra_supported,*species) if r==region and identifier in supported}
        existing={row['id'] for row in battle['encounters']}
        for entry in trial.battle_placement.area_encounters(raw)['encounters']:
            identifier=f'area_{region}_{entry["index"]}'
            if identifier in existing:continue
            if not (set(entry['roster'])-{0})<=set(ids):
                skipped.append(identifier);continue
            roster=[ids[native] for native in entry['roster'] if native]
            levels=[next(e['level'] for e in battle['enemies'] if e['id']==id) for id in roster]
            award=trial.exp_award.award_pool([5]*6,[0]*6,levels)[1]
            offset=selected[entry['index']-1]-trial.encounters.BASE
            flags=struct.unpack_from('<I',raw,offset+12)[0]
            battle['encounters'].append(dict(id=identifier,title=' / '.join(dict.fromkeys(next(e['name'] for e in battle['enemies'] if e['id']==id) for id in roster)),
                enemies=roster,experience_per_member=award,escape_allowed=not bool(flags&0x80000000),**encounter_music(flags),
                positions=[trial.world_position(slot['world']) for slot in entry['slots']],source_slots=[slot['slot'] for slot in entry['slots']],
                enemy_rows=['front' if slot['slot']<3 else 'back' for slot in entry['slots']]))
            formations.append(dict(id=identifier,source=origin,source_offset=offset))
    return dict(species=proof,formations=formations,unsupported_formations=skipped,
        scope='Source species and whole qualified rosters; diagnostic catalogue only. Regional field admission, scenery/media and campaign placement remain separate.')

def export_rules(battle, area, enemy_table):
    spells = battle['systems']['spells']
    # Static callback contracts: test_journey_battle.py; native behavior: game/tests/journey.zig.
    specs = {1:dict(power=100,element='fire'), 2:dict(power=150,element='fire'),
             9:dict(power=999,full_heal=True,clear_status=True),
             11:dict(power=300,clear_status=True),
             30:dict(power=100,group=True,full_heal=True,clear_status=True),
             15:dict(power=999,full_heal=True,clear_status=True),
             13:dict(power=1,sleep_failure_percent=30)}
    for spell in spells: spell.update(specs[int(spell['id'].removeprefix('spell_'))])
    journey_magic.export(battle['systems'])
    battle['systems']['sleep_recovery_percent']=50
    for enemy in battle['enemies']:
        index = ENEMY_IDS[enemy['id']]
        address=struct.unpack_from('<I', area, enemy_table-0x80080000+4*index)[0]
        raw=area[address-0x80080000:address-0x80080000+64]
        enemy['affinities']={element:('neutral','weak','resistant','immune')[raw[0x20+i]] for i,element in enumerate(journey_magic.ELEMENTS)}
        enemy['fire_affinity']=enemy['affinities']['fire']
        enemy['other_affinity']=('neutral','weak','resistant','immune')[raw[0x25]]
        enemy['target_policy']='any_row' if index == 3 else 'front_first'
        enemy['action_policy']='ant_double_strike' if index == 5 else 'attack'
        flags = struct.unpack_from('<H', raw, 38)[0]
        enemy['death_immune']=bool(flags & 0x4000)
        enemy['airborne']=bool(flags & 0x20)
        if flags & 0x8002: raise ValueError('enemy parry/forced-rejection path requires separate implementation')
        enemy['dodges_attacks'] = bool(flags & 4)
        enemy['unavoidable_attack'] = bool(flags & 8)

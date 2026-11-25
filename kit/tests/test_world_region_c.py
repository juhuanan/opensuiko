"""Static C-region exports checked against point/collision consumers and a second sprite decoder."""
from pathlib import Path
import json
import struct
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
import export_world_travel as travel
import export_world_art as art
import world_map_render as world
from export_first_room import source
from export_battle_trial import section_art
from test_worldmap_points import collision_offsets, kobold_connection_cases


def archer_case(paired=False, retaliate=False, continuation=None, presentation=False, miss=False, retained_offset=False, initial_hp=None, attacker=0, first_target=0, attack_power=180):
    """Complete original C actor/projectile/target/coordinator, with I/O boundaries only."""
    from legacy_world_travel_fixture import rabbit_fixture, rabbit_driver, arm_character, coordinator_snapshot
    from legacy_instruction_fixture import call
    from test_battle_picker import SCENE
    import battle_mock
    import battle_placement
    raw, _ = source('/C_DATA.BIN')
    _, proof = travel.export('c')
    record = next(row['stats_offset'] for row in proof['enemy_records'] if row['local_id'] == 2)
    assert attacker in (0, 1) and first_target in (0, 1)
    assert not retaliate or paired
    count = 2 if paired else 1
    last_actor = 6 + count
    c, parent, _ = rabbit_fixture(raw, actor=last_actor, record=record)
    memory, original_read, images = c.mem, c.read, []

    def character_read(address, size):
        for base, data in images:
            if base <= address and address + size <= base + len(data):
                return sum(memory.b.get(address + k, data[address + k - base]) << (8 * k) for k in range(size))
        return original_read(address, size)

    c.read = character_read
    arm_character(c, 1, 'SHU', images, scripts=True)
    if paired:
        arm_character(c, 2, 'GRE', images, scripts=True)
        if initial_hp is not None:
            for index, code in enumerate(('PAN', 'VIC', 'YAM', 'TAI'), 3):
                arm_character(c, index, code, images, scripts=True)
        parent = SCENE + 0x50 + 140 * 7
        memory.sw(parent + 8, struct.unpack_from('<I', raw, record + 40)[0])
        call(c, 0x800e1e3c, struct.unpack_from('<I', raw, record + 44)[0], 0)
        memory.sw(parent + 0x84, c.r[2])
        call(c, 0x800e7468, c.r[2]); memory.sw(parent + 0x88, c.r[2])
        memory.sb(parent + 3, 1)
        memory.sb(SCENE + 0x50 + 140 * 8, 2)
        memory.sw(SCENE + 8, 7)
    rabbit_driver(c, parent)
    memory.sb(parent, 2)
    memory.sw(0x80400008, 0x80080000 + record)
    memory.sw(SCENE + 0x20, count); memory.sw(SCENE + 0x2c, count)
    for index in range(1, last_actor + 1):
        slot = SCENE + 0xb40 + 84 * index
        memory.sb(slot + 0x46, 0); memory.sb(slot + 0x47, 1)
        memory.sh(slot + 0x2a, 60 if index >= 7 else 0)
    hero = SCENE + 0xb40 + 84
    for actor_index in range(7, last_actor + 1):
        enemy = SCENE + 0xb40 + 84 * actor_index
        for index, value in enumerate(struct.unpack_from('<6H', raw, record + 20)):
            memory.sh(enemy + 0x14 + 2 * index, value)
            memory.sh(enemy + 0x24 + 2 * index, value)
        memory.sh(enemy + 0x30, 140); memory.sh(enemy + 0x32, 42)
        memory.sh(enemy + 0x10, 120); memory.sh(enemy + 0x12, 120)
    homes = battle_mock.party_world_positions() + [slot['world'] for slot in battle_placement.area_encounters(raw)['encounters'][0]['slots'][:count]]
    for index, home in enumerate(homes, 1):
        actor = SCENE + 0x50 + 140 * index
        for axis, value in enumerate(home):
            memory.sw(actor + 0x5c + 4 * axis, (value * 4096) & 0xffffffff)
            memory.sw(actor + 0x68 + 4 * axis, (value * 4096) & 0xffffffff)
    if retaliate:
        striking = SCENE + 0xb40 + 84 * (attacker + 1)
        memory.sb(striking + 0x47, 0); memory.sb(striking + 0x49, 7 + first_target)
        for offset, value in ((0x10, 100 if miss else 300), (0x12, 100 if miss else 300), (0x30, attack_power), (0x26, 255), (0x32, 40), (0x2a, 24), (0x2e, 0)):
            memory.sh(striking + offset, value)
    if initial_hp is not None:
        assert paired and len(initial_hp) == 6
        for index, hp in enumerate(initial_hp, 1):
            memory.sh(SCENE + 0xb40 + 84 * index + 0x12, hp)
            maximum = SCENE + 0xb40 + 84 * index + 0x10
            memory.sh(maximum, max(hp, memory.rh(maximum)))
    if retained_offset:
        assert paired and miss and not retaliate
        for index in (1,2):
            actor=SCENE+0x50+140*index
            memory.sb(actor+0x79,254);memory.sw(actor+0x3C,(-2*4096)&0xffffffff)
    c.external_call = lambda pc: super(type(c), c).external_call(pc)
    del c.hooks[0x800e1654]

    def numbers(cpu):
        cpu.r[31] = 0x800e1b50
        return cpu.r[2]

    def icon(cpu):
        cpu.r[31] = 0x800e0750
        return 0

    c.hooks[0x800e1780] = numbers; c.hooks[0x800e0748] = icon
    c.hooks[0x800f6110] = 0; c.hooks[0x800f74a8] = 0xffffffff
    frame, draws, rows = [0], [], []

    def draw(cpu):
        # Supply a real accuracy roll, retaining all other game consumers and their order.
        value=99 if miss and cpu.r[31]==0x800F7E44 and cpu.r[7]>6 else 51
        draws.append([frame[0], value])
        return value

    c.hooks[0x80147e38] = draw
    if initial_hp is not None and any(hp < (300 if index == 0 and retaliate else 100) // 4 for index, hp in enumerate(initial_hp)):
        call(c, 0x800E09BC)
        assert not draws
    pose_maps={}
    if presentation:
        assert paired
        for index,data,base,section in [(index,data,base,struct.unpack_from('<I',data,36)[0]) for index,(base,data) in enumerate(images,1)]+[(7,raw,0x80080000,struct.unpack_from('<I',raw,record+44)[0]-0x80080000)]:
            pose_count=struct.unpack_from('<H',data,section)[0]
            table=struct.unpack_from('<I',data,section+16)[0]-(0x80080000 if data is raw else 0)
            pose_maps[index]={struct.unpack_from('<I',data,table+4*i)[0]+(base if data is not raw else 0):i for i in range(pose_count)}
        pose_maps[8]=pose_maps[7]
    def visual(index,poses):
        actor=SCENE+0x50+140*index;graphic=memory.rw(actor+0x84)
        signed=lambda value:value-0x100000000 if value&0x80000000 else value
        return dict(position=dict(zip(('x','y','z'),[signed(memory.rw(actor+0x68+4*axis))/4096 for axis in range(3)])),
                    pose=poses[memory.rw(graphic+0x24)],offset=[value-256 if value&128 else value for value in (memory.rb(actor+0x78),memory.rb(actor+0x79))],visible=bool(memory.rb(actor+3)))
    def sample(tick):
        row=dict(tick=tick,
                    enemy_hp=[memory.rh(SCENE + 0xb40 + 84 * index + 0x12) for index in range(7, last_actor + 1)],
                    enemy_down=[bool(memory.rb(SCENE + 0xb40 + 84 * index + 0x45)) for index in range(7, last_actor + 1)],
                    party_hp=[memory.rh(SCENE + 0xb40 + 84 * index + 0x12) for index in range(1, 7)],
                    actor_locks=[bool(memory.rb(SCENE + 0x50 + 140 * index + 5)) for index in range(1, last_actor + 1)],
                    coordinator=coordinator_snapshot(c, True), draws=len(draws))
        if initial_hp is not None:
            row['party_down'] = [bool(memory.rb(SCENE + 0xb40 + 84 * index + 0x45)) for index in range(1, 7)]
            slots = [memory.rb(SCENE + 0xb40 + 84 * index + 0x44) - 1 for index in range(1, 7)]
            row['formation'] = [slots.index(slot) for slot in range(6)]
            if presentation:
                row['party_visuals'] = [visual(index, pose_maps[index]) for index in range(1, 7)]
        if presentation:
            row['visuals']=[visual(index,pose_maps[index]) for index in (1,2,7,8)]
            row['projectiles']=[]
            for index in (18,19):
                actor=SCENE+0x50+140*index;graphic=memory.rw(actor+0x84)
                if memory.rb(actor+3) and graphic and memory.rw(graphic+0x24) in pose_maps[7]:
                    row['projectiles'].append(dict(owner=memory.rb(actor+4)-1,**visual(index,pose_maps[7])))
        return row

    for tick in range(1, 601):
        frame[0] = tick
        call(c, 0x800de0b0, 0)
        rows.append(sample(tick))
        if memory.rw(0x8017da94) == 0x800f74a8:
            break
    if not miss and initial_hp is None:
        assert len(rows) == (319 if retaliate else 129 if paired else 126) and len(draws) == (27 if retaliate else 24 if paired else 19)
        assert next(row['tick'] for row in rows if row['party_hp'][0] < (300 if retaliate else 100)) == 56
        assert next(row['tick'] for row in rows if not row['actor_locks'][0]) == 92
        assert next(row['tick'] for row in rows if not row['actor_locks'][6]) == 116
        assert rows[-1]['party_hp'][0] == (200 if retaliate else 50)
    if retaliate and not miss and initial_hp is None:
        assert next(row['tick'] for row in rows if row['enemy_hp'][0] == 0) == 189
        assert next(row['tick'] for row in rows if row['enemy_down'][0]) == 225
        assert next(row['tick'] for row in rows if row['tick'] >= 117 and not row['actor_locks'][0]) == 245
        assert next(row['tick'] for row in rows if row['tick'] >= 117 and not row['actor_locks'][6]) == 318
    if paired and not miss and initial_hp is None:
        assert next(row['tick'] for row in rows if row['party_hp'][1] < 100) == 59
        assert next(row['tick'] for row in rows if row['tick'] >= 4 and not row['actor_locks'][1]) == 95
        assert next(row['tick'] for row in rows if row['tick'] >= 4 and not row['actor_locks'][7]) == 119
        assert rows[-1]['party_hp'][1] == 50
    if continuation is not None:
        continuation.update(machine=c, frame=frame, draws=draws, sample=sample)
    section = struct.unpack_from('<I', raw, record + 44)[0] - 0x80080000
    pieces = struct.unpack_from('<I', raw, section + 16)[0] - 0x80080000
    pose = struct.unpack_from('<I', raw, pieces)[0] - 0x80080000
    piece_count, _, width, height, anchor_x, anchor_y = raw[pose:pose + 6]
    for index in range(piece_count):
        x, y, _, _, w, h, _, _ = raw[pose + 8 + index * 8:pose + 16 + index * 8]
        width, height = max(width, x + w + 1), max(height, y + h + 1)
    hp, attack, skill, defense, speed, magic, luck = struct.unpack_from('<7H', raw, record + 18)
    profile = dict(id='kobold_type_2', name='Kobold', level=raw[record + 16], max_hp=hp,
                   stats=dict(attack=attack, skill=skill, defense=defense, speed=speed, magic=magic, luck=luck),
                   sprite=dict(rect=dict(x=0, y=0, w=width, h=height), anchor_x=anchor_x, anchor_y=anchor_y),
                   attack=[], action_policy='front_projectile', target_policy='front_first', dodges_attacks=True,
                   front_projectile=dict(impact_tick=56, target_release_tick=92, owner_release_tick=116))
    result=dict(schema='suikoden-c-archer-source/2', enemy='kobold_type_2', enemy_count=count, profile=profile, retaliation=retaliate,
                sources=[source('/C_DATA.BIN')[1], source('MAIN.EXE')[1]],
                source_record=record, source_scripts=struct.unpack_from('<I', raw, record + 40)[0] - 0x80080000,
                conditions=('C formation1; first archer selected; Hero300HP/180ATK/255SKL/24SPD targets slot0, others100HP Defend;40DEF; all draws51; not canonical startup' if retaliate else 'C formation1 source slots; first archer already selected; six supplied Defend commands; party100HP/40DEF; all draws51; not canonical startup'),
                rows=rows, draws=draws, impact_tick=56, target_release_tick=92,
                owner_release_tick=116, round_gate=len(rows))
    if miss:
        result.pop('target_release_tick')
        result.update(misses=True,conditions='C formation1; first archer selected; six100HP/40DEF members; Hero180ATK/255SKL/24SPD attacks slot0 only when retaliation is true; enemy accuracy draws99, all other draws51; explicit prototype party',target_release_ticks=[114,119][:count])
        assert rows[-1]['party_hp']==(initial_hp if initial_hp is not None else [100]*6)
        assert next(row['tick'] for row in rows if not row['actor_locks'][0])==114
        if paired:
            assert next(row['tick'] for row in rows if row['tick']>=4 and not row['actor_locks'][1])==122
    if attack_power != 180:
        result['attack_power'] = attack_power
    if first_target != 0:
        result['first_target'] = first_target
    if attacker != 0:
        result['attacker'] = attacker
        result['initial_max_hp'] = [memory.rh(SCENE + 0xb40 + 84 * index + 0x10) for index in range(1, 7)]
        result['conditions'] = 'C formation1; first archer selected; Gremio300HP/180ATK/255SKL/24SPD Attack slot0, other five Defend;40DEF; all draws51; explicit prototype party'.replace('slot0', 'slot' + str(first_target)).replace('180ATK', str(attack_power) + 'ATK')
    if initial_hp is not None:
        result['initial_hp'] = initial_hp
        if first_target != 0:
            result['conditions'] += '; first requested target slot=' + str(first_target)
        result['conditions'] += '; initial party HP=' + repr(initial_hp) + '; no Sacrificial Buddha'
        result['sources'].extend(source('/' + code + '.BIN')[1] for code in ('SHU', 'GRE', 'PAN', 'VIC', 'YAM', 'TAI'))
    if retained_offset:
        result['retained_reaction_offset']=True
        result['conditions']+='; both targets retain source earlier-hit screen offset(0,-2) and its Q12 motion-offset destination'
    return result


def archer_two_round_case(presentation=False, miss=False, initial_hp=None, attacker=0, first_target=0):
    """Continue the same formation through original reset, command launch and both KOs."""
    from legacy_instruction_fixture import call
    from test_battle_picker import SCENE
    import character_table
    import maindec as main
    context = {}
    first = archer_case(True, True, context, presentation=presentation,miss=miss,initial_hp=initial_hp,attacker=attacker,first_target=first_target)
    c, frame, draws, sample = (context[key] for key in ('machine', 'frame', 'draws', 'sample'))
    memory = c.mem
    records = {row['id']: row for row in character_table.records()}
    stats = []
    # Original round preparation reads persistent members; this explicit party is a test precondition.
    for index, native in enumerate((8, 2, 6, 35, 38, 32), 1):
        record = 0x80420000 + 128 * index
        seed = records[native]
        weapon = main.mword(0x80165890 + 4 * seed['weapon_id'])
        curve = main.body()[weapon - main.MBASE + 0x54]
        power = int.from_bytes(main.body()[0x801659D0 - main.MBASE + 32 * curve + 2 * (seed['weapon_level'] - 1):][:2], 'little')
        memory.sw(record, native)
        memory.sh(record + 4, memory.rh(SCENE + 0xB40 + 84 * index + 0x10))
        memory.sh(record + 6, first['rows'][-1]['party_hp'][index - 1])
        memory.sb(record + 0x0D, 14)
        for column, value in enumerate((180 - power if index == attacker + 1 else 10, 255 if index == attacker + 1 else 20, 40, 24 if index == attacker + 1 else 0, 50, 0)):
            memory.sb(record + 0x10 + column, value)
        memory.sb(record + 0x44, seed['weapon_id']); memory.sb(record + 0x45, seed['weapon_level'])
        memory.sb(record + 0x4C, 0); memory.sb(record + 9, 1)
        call(c, 0x800D4EC0, record, SCENE + 0xB40 + 84 * index + 0x24)
        stats.append([memory.rh(SCENE + 0xB40 + 84 * index + 0x24 + 2 * column) for column in range(8)])
    memory.sw(SCENE + 4, 1); memory.sw(SCENE + 0x133C, 0)
    del c.hooks[0x800F74A8]
    call(c, 0x800DE0B0, 0)
    assert memory.rw(0x8017DA94) == 0x800F64F0
    classifier = sample(len(first['rows']) + 1); classifier['coordinator']['stage'] = 'round_setup'
    call(c, 0x800DE0B0, 0)
    assert memory.rw(0x8017DA94) == 0x800F6C34 and memory.rw(0x8017DA98) == 0x800E9E90
    reset = dict(party_hp=[memory.rh(SCENE + 0xB40 + 84 * i + 0x12) for i in range(1, 7)],
                 acted=[bool(memory.rb(SCENE + 0xB40 + 84 * i + 0x46)) for i in range(1, 9)], draws=len(draws))
    c.hooks[0x800E9E90] = 0xFFFFFFFF
    for _ in range(14):
        call(c, 0x800DE0B0, 0)
    for index in range(1, 9):
        memory.sb(SCENE + 0xB40 + 84 * index + 0x47, int(index != attacker + 1))
        memory.sb(SCENE + 0xB40 + 84 * index + 0x49, 8 - first_target if index == attacker + 1 else 0)
    frame[0] = 0; memory.sw(0x8017DA94, 0x800F6DA8)
    call(c, 0x800DE0B0, 0)
    launch = sample(0)
    assert launch['draws'] == first['rows'][-1]['draws'] + 1 and launch['coordinator']['remaining'] == 30
    c.hooks[0x800F74A8] = 0xFFFFFFFF
    second = []
    for tick in range(1, 601):
        frame[0] = tick; call(c, 0x800DE0B0, 0); second.append(sample(tick))
        if memory.rw(0x8017DA94) == 0x800F74A8:
            break
    assert second[-1]['enemy_hp'] == [0, 0] and second[-1]['enemy_down'] == [True, True]
    if attacker == 0:
        assert second[-1]['party_hp'][0] == 100
    if initial_hp is None:
        assert len(second) == 350 and len(draws) == (54 if miss else 57)
    import exp_award
    from test_enemy_rewards import fixture as reward_fixture, reward
    raw = source('/C_DATA.BIN')[0]
    record = raw[first['source_record']:first['source_record'] + 64]
    money, item = reward(reward_fixture([record, record], [51] * 4, runes=(0,) * 6))
    awards = exp_award.exec_award_pool([14] * 6, [0] * 6, [record[16]] * 2, out_of_action=[hp == 0 for hp in second[-1]['party_hp']])[1:]
    assert money == 300 and item == 0 and awards == [1700 if hp else 0 for hp in second[-1]['party_hp']]
    return dict(first, schema='suikoden-c-archer-two-round-source/1', stats=stats,
                classifier=classifier, reset=reset, menu_updates=14, launch=launch, second=second, draws=draws,
                rewards=dict(money=money, experience=awards, item=item, source_routines=['0x800E9744', '0x800E9940'], supplied_draws=[51] * 4))


def archer_trace(name):
    return json.loads((ROOT / 'game/tests/fixtures' / f'{name}.json').read_text())


def check():
    assert travel.export()[0] == json.loads((ROOT / 'game/assets/world_b.json').read_text())
    assert travel.battle_export() == json.loads((ROOT / 'game/assets/world_b_battle.json').read_text())
    exported_battle = travel.battle_export('c')
    assert exported_battle == json.loads((ROOT / 'game/assets/world_c_battle.json').read_text())
    assert [profile['id'] for profile in exported_battle['enemies'] if profile['action_policy'] == 'front_projectile'] == ['kobold_type_2']
    assert art.build()[0] == json.loads((ROOT / 'game/assets/world_art_b.json').read_text())
    data, proof = travel.export('c')
    assert data == json.loads((ROOT / 'game/assets/world_c.json').read_text())
    assert proof == json.loads((ROOT / 'kit/data/reports/world_travel_c.json').read_text())
    assert len(data['walkable']) == 19200 and len(data['encounters']) == 8
    assert data['return_camera'] == dict(x=59, y=38)
    assert data['field_room'] == 'vb6_kobold_village'
    assert len(kobold_connection_cases()) == 4
    # Three different source records display "Kobold"; no identity is collapsed by text.
    kobolds = [enemy for enemy in data['enemies'] if enemy['name'] == 'Kobold']
    assert len(kobolds) == len({enemy['id'] for enemy in kobolds}) == 3
    levels = {enemy['id']: enemy['level'] for enemy in data['enemies']}
    for encounter in data['encounters']:
        assert encounter['enemy_level_sum'] == sum(levels[enemy] for enemy in encounter['enemies'] if enemy)
    raw, _ = source('/C_DATA.BIN')
    # The complete ordinary selector agrees with A after direct-jump relocation.
    from test_enemy_policies import verify_front_selector
    callbacks = {record['local_id']: record['decision_callback'] for record in proof['enemy_records']}
    assert callbacks[1] == callbacks[4] == '0x80080018'
    verify_front_selector(raw, 0x18)
    decisions = 1  # Static source equivalence; native gates own decision execution.
    # Independently follow the enemy directory and read each raw record, not producer helpers.
    u32 = lambda offset: int.from_bytes(raw[offset:offset + 4], 'little')
    pointer = lambda offset: u32(offset) - 0x80080000
    directory = pointer(pointer(pointer(0) + 12))
    table = pointer(directory + 12)
    stable = {1: 'kobold_type_1', 2: 'kobold_type_2', 3: 'kobold_type_3', 4: 'strong_arm'}
    for native, identifier in stable.items():
        offset = pointer(table + 4 * native)
        profile = next(profile for profile in exported_battle['enemies'] if profile['id'] == identifier)
        words = [int.from_bytes(raw[offset + i:offset + i + 2], 'little') for i in range(18, 32, 2)]
        assert [profile['max_hp']] + [profile['stats'][key] for key in ('attack', 'skill', 'defense', 'speed', 'magic', 'luck')] == words
        assert profile['level'] == raw[offset + 16]
        reward = int.from_bytes(raw[offset + 52:offset + 54], 'little', signed=True)
        assert profile['money'] == ((abs(reward) // 10) * (-1 if reward < 0 else 1) * 100 if reward & 1 else reward)
        assert [drop['rate'] for drop in profile['drops']] == [raw[offset + 55 + 2 * index] for index in range(3)]
        for drop in profile['drops']:
            assert drop['uses'] == (6 if drop['item'] == 'medicine' else 0)
        assert (profile['action_policy'] == 'front_projectile') == (native == 2)
    for name, updates, draws, surviving_hp in (
            ('world_c_archer', 126, 19, [120]),
            ('world_c_archer_pair', 129, 24, [120, 120]),
            ('world_c_archer_retaliation', 319, 27, [0, 120]),
            ('world_c_archer_two_round', 319, 57, [0, 120])):
        trace = archer_trace(name)
        assert trace['source_record'] == pointer(table + 4 * 2)
        assert (len(trace['rows']), len(trace['draws']), trace['rows'][-1]['enemy_hp']) == (updates, draws, surviving_hp)
    two_rounds = archer_trace('world_c_archer_two_round')
    assert len(two_rounds['second']) == 350 and two_rounds['second'][-1]['enemy_hp'] == [0, 0]
    assert two_rounds['rewards']['experience'] == [1700] * 6
    plane = world.parse_worldmap(raw)
    threshold = struct.unpack_from('<H', raw, pointer(0) + 4)[0]
    assert threshold == 217  # B's207 cannot be reused for this region.
    collision_offsets()
    assert data['walkable'] == ''.join('1' if code >= threshold else '0' for code in plane['codes'])
    rendered, image, provenance = art.build('c')
    assert rendered == json.loads((ROOT / 'game/assets/world_art_c.json').read_text())
    poses, _, _ = section_art(raw, provenance['foot']['section'], 0x80080000)
    for i, rect in enumerate(rendered['poses']):
        assert poses[i][0].crop((0, 0, 16, 16)).tobytes() == image.crop((rect['x'], rect['y'], rect['x'] + 16, rect['y'] + 16)).tobytes()
    print(f'PASS: C-region source return and all 19,200 terrain cells, {decisions} static front-selector comparison, four retained archer traces, eight encounter candidates and 36 independently decoded foot poses')


if __name__ == '__main__':
    check()

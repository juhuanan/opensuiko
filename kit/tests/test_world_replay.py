"""Isolated native replay bootstrap/process checks. Never opens graphics or audio."""
from pathlib import Path
import argparse
import copy
import hashlib
import json
import subprocess
import tempfile
import os
import shutil
from collections import deque

ROOT = Path(__file__).resolve().parents[2]
EXE = ROOT / 'game/zig-out/bin/suikoden-journey'
FIELD = ROOT / 'kit/work/build/journey'
ART = ROOT / 'kit/work/build/world-travel-art'


def service_walk(package, story, recovery=False, points=None, forest=False, recruitment=False, interactions=False):
    """Plan field inputs through exported rooms and acknowledge their one-time dialog."""
    rooms = {room['id']: room for room in package['rooms']}
    room_id, position = 'vb6_village', (264, 344)
    steps = [] if recovery else [{'buttons': {'direction': 'up'}}, {}]
    seen = copy.deepcopy(story)

    def contains(rect, point):
        return rect['x'] <= point[0] < rect['x']+rect['w'] and rect['y'] <= point[1] < rect['y']+rect['h']

    def walk(target=None, destination=None):
        nonlocal room_id, position
        room = rooms[room_id]
        selected = next((edge for edge in room['exits'] if edge['room'] == destination), None) if destination else None
        assert destination is None or selected is not None
        previous = {position: None}; queue = deque([position]); found = None
        while queue and found is None:
            point = queue.popleft()
            if target == point:
                found = point; break
            for direction, dx, dy in (('up', 0, -8), ('down', 0, 8), ('left', -8, 0), ('right', 8, 0)):
                at = point[0]+dx, point[1]+dy
                if at in previous or not (0 <= at[0] < room['width'] and 0 <= at[1] < room['height']):continue
                if room['walkable'][(at[1]//8)*(room['width']//8)+at[0]//8] != '1':continue
                exits = [edge for edge in room['exits'] if contains(edge, at)]
                goal = selected is not None and selected in exits and selected.get('direction') in (None, direction)
                if (exits and not goal) or any(event['id'] == 'village_south_exit' and contains(event, at) for event in room.get('events', [])):continue
                previous[at] = point, direction
                if goal:found = at; break
                queue.append(at)
        assert found is not None, (room_id, position, target, destination)
        path = []; point = found
        while previous[point] is not None:
            prior, direction = previous[point]; path.append((direction, point)); point = prior
        for direction, point in reversed(path):
            steps.extend([{'buttons': {'direction': direction}}]*4)
            for event in room.get('events', []):
                if contains(event, point) and not seen.get(event['flag']) and (event.get('requires') is None or seen.get(event['requires'])):
                    seen[event['flag']] = True
                    steps.extend([{'buttons': {'confirm': True}}]*len(event['pages']))
        if selected:
            room_id = destination; position = selected['spawn_x'], selected['spawn_y']
        else:position = found

    def buttons(**values):steps.append({'buttons': values})

    def graph_walk(target):
        nonlocal room_id, position
        start = (room_id, *position)
        previous = {start: None}; queue = deque([start])
        while queue and target not in previous:
            node = queue.popleft(); room = rooms[node[0]]
            for direction, dx, dy in (('up', 0, -8), ('down', 0, 8), ('left', -8, 0), ('right', 8, 0)):
                at = node[1] + dx, node[2] + dy
                if not (0 <= at[0] < room['width'] and 0 <= at[1] < room['height']):continue
                if room['walkable'][(at[1]//8)*(room['width']//8)+at[0]//8] != '1':continue
                nxt = (node[0], *at)
                if any(event['id'] in ('village_south_exit', 'kobold_world_exit') and contains(event, at) for event in room.get('events', [])) and nxt != target:continue
                for edge in room['exits']:
                    if contains(edge, at) and edge.get('direction') in (None, direction):
                        nxt = edge['room'], edge['spawn_x'], edge['spawn_y']; break
                if nxt not in previous:
                    previous[nxt] = node, direction; queue.append(nxt)
        assert target in previous, ('no exported route', start, target)
        route = []; node = target
        while previous[node] is not None:
            prior, direction = previous[node]; route.append((direction, node)); node = prior
        for direction, node in reversed(route):
            steps.extend([{'buttons': {'direction': direction}}] * 4)
            steps.append({})  # Run the arrival predicate before the next movement input.
            if points is not None and node[0] != previous[node][0][0]:
                points.setdefault('entered_' + node[0],len(steps))
            for event in rooms[node[0]].get('events', []):
                if event['id'] == 'kobold_world_exit':continue  # Replaced by the source handoff.
                if contains(event, node[1:]) and not seen.get(event['flag']) and (event.get('requires') is None or seen.get(event['requires'])):
                    seen[event['flag']] = True
                    steps.extend([{'buttons': {'confirm': True}}] * len(event['pages']))
        room_id, position = target[0], target[1:]


    if interactions:
        def talk(npc_id):
            room = rooms[room_id]
            npc = next(npc for npc in room['npcs'] if npc['id'] == npc_id)
            for direction, offset in zip(('down', 'up', 'left', 'right'), package['interaction_offsets']):
                at = npc['x'] - offset['x'], npc['y'] - offset['y']
                if not (0 <= at[0] < room['width'] and 0 <= at[1] < room['height']): continue
                if room['walkable'][(at[1]//8)*(room['width']//8)+at[0]//8] != '1': continue
                graph_walk((room_id, *at)); buttons(direction=direction, confirm=True)
                for _ in npc['pages']: buttons(confirm=True)
                if npc_id == 'forest_villager': seen['heard_forest_warning'] = True
                if npc.get('hidden_by') is not None: seen[npc['hidden_by']] = True
                if points is not None: points[npc_id] = len(steps)
                return
            raise AssertionError(f'no valid NPC approach: {npc_id}')
        talk('forest_villager')
        graph_walk(('vb6_forest_paths', 144, 160))
        talk('forest_chest_needle'); talk('forest_chest_water')
        graph_walk(('vb6_village', 264, 352))
        if points is not None: points['village_return'] = len(steps)
        steps.extend([{'buttons': {'direction': 'down'}}] * 4)
        return steps

    if recruitment:
        walk(destination='vb6_blacksmith'); walk(target=(184, 112))
        buttons(direction='up')
        for _ in range(8): buttons(confirm=True)
        walk(destination='vb6_village'); walk(target=(264, 352))
        steps.extend([{'buttons': {'direction': 'down'}}] * 4)
        return steps

    if forest:
        graph_walk(('vb6_kobold_village', 360, 176))
        return steps

    if recovery:
        walk(destination='vb6_inn'); walk(target=(288,112))
        buttons(direction='up',confirm=True);buttons(confirm=True);buttons(cancel=True)
        if points is not None:points['cancelled']=len(steps)
        buttons(direction='up',confirm=True);buttons(confirm=True);buttons(confirm=True)
        if points is not None:points['paid']=len(steps)
        # shortcut: retain the existing prototype rest fade until original inn driver timing is integrated.
        steps.extend([{}]*60)
        walk(destination='vb6_village')
    walk(destination='vb6_shop'); walk(target=(184, 128))
    buttons(direction='up', confirm=True); buttons(confirm=True); steps.append({})
    buttons(confirm=True); buttons(confirm=True); buttons(navigation='right'); buttons(confirm=True)
    buttons(cancel=True); buttons(cancel=True)
    if recovery:
        walk(destination='vb6_village');walk(target=(264,352))
        steps.extend([{'buttons':{'direction':'down'}}]*4)
        return steps
    walk(destination='vb6_village'); walk(destination='vb6_blacksmith'); walk(target=(184, 112))
    buttons(direction='up', confirm=True); buttons(confirm=True); steps.append({})
    buttons(confirm=True); buttons(navigation='right'); buttons(confirm=True)
    buttons(cancel=True); buttons(cancel=True)
    walk(destination='vb6_village')
    return steps


def run(*args, success=True, executable=EXE, cwd=ROOT):
    result = subprocess.run([str(executable), *map(str, args)], cwd=cwd,
                            stdin=subprocess.DEVNULL, capture_output=True,
                            text=True, timeout=120)
    if success:
        assert result.returncode == 0, result.stderr
    else:
        assert result.returncode != 0, result.stdout
    return result


def state_rows(result):
    return [row for line in result.stdout.splitlines() if line.startswith('{')
            if (row := json.loads(line))['kind'] == 'diagnostic-world-replay']

def primary_save(directory):
    # Auxiliary recruitment checks have nested slots; select the actual app root.
    saves = [path for path in Path(directory).rglob('journey-slot.json') if path.parent.name == 'Suikoden Zig']
    assert len(saves) == 1, saves
    return saves[0]


def progress_checks(root, packet_path, expected, points, battle_art=None):
    for count in points:
        directory = root/f'progress-{packet_path.stem}-{count}'; directory.mkdir()
        extra=() if battle_art is None else (battle_art,)
        written = run('--check-world-replay-progress', FIELD, ART, packet_path, directory, count,*extra)
        record = json.loads((directory/'world-replay-progress.json').read_text())
        assert record['completed_steps'] == count
        assert record['state_digest'] == state_rows(written)[-1]['simulation_digest']
        resumed = run('--check-world-replay-progress', FIELD, ART, packet_path, directory, 'resume',*extra)
        assert state_rows(resumed)[-1] == expected
    return directory


def supplied_packet(checkpoint):
    checkpoint=copy.deepcopy(checkpoint)
    # Harness-only provided ownership/position. This is not canonical New Game.
    # The existing journey schema serializes fixed u8 vectors as JSON strings.
    checkpoint.update(room='vb6_village', x=264, y=360, facing='down',
                      levels=''.join(chr(99) for _ in range(6)))
    steps = ([{'buttons': {'direction': 'up'}}, {}]
             + [{'buttons': {'direction': 'down'}}]*8
             + [{'buttons': {'direction': 'down'}}]*80
             + [{}, {'buttons': {'navigation': 'down'}}, {'buttons': {'confirm': True}}]
             + [{}]*200 + [{'buttons': {'confirm': True}}])
    packet = dict(schema='suikoden-world-replay/1', checkpoint=checkpoint,
                  prototype_retry_seed=0x5355494B4F44454E, update_hz=60,
                  draws=[0, 4095], steps=steps)
    return packet


def roc_party_commands(checkpoint):
    profiles={p['id']:p for p in json.loads((FIELD/'battle/trial.json').read_text())['party']}
    commands=[{'buttons':{'confirm':True}},{'buttons':{'confirm':True}}]
    for index,member in enumerate(checkpoint['party'][1:],1):
        if not (index>=3 and profiles[member['id']]['weapon_range']=='short'):commands.append({'buttons':{'navigation':'down'}})
        commands.append({'buttons':{'confirm':True}})
    return commands


def roc_loop_checks(root, packet, battle_art=None, frames=None, cover=False, cover_knockout=False):
    """Normal commands from the supplied world checkpoint; no native window."""
    extra=() if battle_art is None else (battle_art,) if frames is None else (battle_art,frames)
    case=copy.deepcopy(packet)
    checkpoint=case['checkpoint']
    checkpoint['levels']=''.join(chr(14) for _ in range(6))
    checkpoint['experience']=[0]*6
    checkpoint['formation']=''.join(chr(i) for i in range(6))
    for member,stats in zip(checkpoint['party'],checkpoint['stats']):
        member.update(hp=100,max_hp=100,status='healthy');stats.update(speed=0,defense=40)
    checkpoint['stats'][0].update(attack=180,skill=9999,luck=0,speed=24)
    commands=roc_party_commands(checkpoint)
    prefix=case['steps'][:90]+[{}, {'buttons':{'confirm':True}}]+commands+[{'buttons':{'confirm':True}},{}]
    case['draws']=[0,3*(32767//8)]+[51]*29+[0,0]
    path=root/'roc-loop.json'
    reference=json.loads((ROOT/'game/tests/fixtures/world_roc_loop.json').read_text())
    for tick in (1,49,50,62,145,146,218,254,274,347,348):
        case['steps']=prefix+[{}]*(tick-1);path.write_text(json.dumps(case))
        row=state_rows(run('--check-world-replay',FIELD,ART,path,*extra))[-1]
        sample=reference['samples'][tick-1]
        if frames is not None:(Path(frames)/f'battle-{tick}-state.json').write_text(json.dumps(row,indent=2)+'\n')
        assert row['mode']=='battle' and row['battle_ticks']==tick,(tick,row['battle_ticks'])
        assert row['party'][0]['hp']==sample['hero_hp'] and row['battle_enemy_hp']==[sample['enemy_hp']]
        assert row['battle_enemy_inactive']==[bool(sample['enemy_down'])]
        assert row['draws']==sample['draws']+9
        assert row['money']==checkpoint['money'] and row['experience']==checkpoint['experience']
    case['steps']=prefix+[{}]*379;path.write_text(json.dumps(case))
    victory=state_rows(run('--check-world-replay',FIELD,ART,path,*extra))[-1]
    assert victory['battle_phase']=='victory' and victory['draws']==33
    assert victory['money']==checkpoint['money']+70 and victory['experience']==[33]*6,(victory['money'],victory['experience'])
    # The selected real Roc drop is Feather, inserted once in the first available bag.
    before=checkpoint['party'][0]['inventory']['slots'];after=victory['party'][0]['inventory']['slots']
    count=sum(slot is not None for slot in before)
    assert after[:count]==before[:count] and after[count]['id']=='feather' and after[count+1:]==before[count+1:]
    expected_party=copy.deepcopy(checkpoint['party']);expected_party[0]['hp']=16;expected_party[0]['inventory']['slots'][count]=after[count]
    assert victory['party']==expected_party
    for key in ('random','runes','formation','stats','loadouts','storage','reserves','levels','weapon_levels','save_name'):
        assert victory[key]==checkpoint[key],key
    case['steps'] += [{}]*4+[{'buttons':{'confirm':True}},{}]
    path.write_text(json.dumps(case));final=state_rows(run('--check-world-replay',FIELD,ART,path,*extra))[-1]
    assert final['mode']=='world' and final['camera']==victory['camera'] and final['remaining']==0
    for key in ('party','money','experience','levels','random','formation','loadouts','runes','storage','reserves','draws'):
        assert final[key]==victory[key],key
    progress_checks(root,path,final,tuple(len(prefix)+tick-1 for tick in (49,62,146,254,347,380)),battle_art)
    if frames is not None:(Path(frames)/'battle-380-state.json').write_text(json.dumps(victory,indent=2)+'\n')
    if battle_art is not None:
        assert victory['presentation_available'] and victory['battle_frame'] is not None
        from PIL import Image
        changed=root/'changed-battle-art';changed.mkdir()
        for name in ('scene.json','actors.png','floor.png'):shutil.copy2(Path(battle_art)/name,changed/name)
        with Image.open(changed/'actors.png') as source:
            image=source.convert('RGBA')
        pixel=next((x,y) for y in range(image.height) for x in range(image.width) if image.getpixel((x,y))[3]==255)
        color=image.getpixel(pixel);image.putpixel(pixel,(color[0]^1,*color[1:]));image.save(changed/'actors.png')
        directory=max(root.glob('progress-roc-loop-*'),key=lambda p:json.loads((p/'world-replay-progress.json').read_text())['completed_steps'])
        preserved={p.name:p.read_bytes() for p in directory.iterdir() if p.is_file()}
        assert 'ReplaySourceMismatch' in run('--check-world-replay-progress',FIELD,ART,path,directory,'resume',changed,success=False).stderr
        assert preserved=={p.name:p.read_bytes() for p in directory.iterdir() if p.is_file()}

    if cover:
        assert battle_art is not None
        first_end=len(prefix)+379;stages=(100,58,16) if cover_knockout else (100,)
        path=root/('four-rocs-cover.json' if cover_knockout else 'two-rocs-cover.json')
        references=json.loads((ROOT/'game/tests/fixtures/world_roc_cover.json').read_text())
        for stage,guard_hp in enumerate(stages):
            first=final;returned=list(case['steps']);initial_draws=first['draws'];lethal=guard_hp<=42
            assert first['party'][1]['hp']==guard_hp
            reference=next(row for row in references if row['hero_hp']==16 and row['hp']==guard_hp and not row['protected'] and not row.get('flagged',False))
            case['draws'] += [0,3*(32767//8)]+[51]*(7+len(reference['draws']))+[0,0]
            if stage==0:walking=[{'buttons':{'direction':'down'}}]*80+[{'buttons':{'direction':'up'}}]*16
            else:walking=[{'buttons':{'direction':'up' if stage==1 else 'down'}}]*80
            entered=returned+walking+[{}];case['steps']=entered;path.write_text(json.dumps(case))
            second=state_rows(run('--check-world-replay',FIELD,ART,path,*extra))[-1]
            assert second['mode']=='battle' and second['battle_phase']=='battle_menu' and second['party']==first['party'] and second['draws']==initial_draws+2, (stage,second['mode'],second['camera'],second['remaining'],second['travel_counter'])
            launch=entered+[{}, {'buttons':{'confirm':True}}]+commands+[{'buttons':{'confirm':True}},{}]
            ticks=(1,5,10,11,12,22,49,61,62,63,72,73,145,146,218,274,348,380) if stage==len(stages)-1 else (49,62,73,380)
            for tick in ticks:
                case['steps']=launch+[{}]*(tick-1);path.write_text(json.dumps(case));row=state_rows(run('--check-world-replay',FIELD,ART,path,*extra))[-1]
                assert row['mode']=='battle' and row['battle_ticks']==tick
                if tick<=348:
                    expected=reference['samples'][tick-1]
                    assert row['party'][0]['hp']==16 and row['party'][1]['hp']==expected['guard_hp'] and row['draws']==initial_draws+9+expected['draws']
                    assert row['money']==first['money'] and row['experience']==first['experience']
                    for index,key in ((0,'hero'),(1,'guard'),(6,'roc')):
                        actual=next((q for q in row['battle_frame']['quads'] if q['actor']==index),None)
                        assert (actual is not None)==expected[key]['visible']
                        if actual is not None:assert actual['position']==expected[key]['position'] and actual['pose_index']==expected[key]['pose']
                    if tick<145:
                        assert row['battle_action']['protector_down']==expected['guard_down']
                        assert row['battle_action']['ward_released']==(tick>=73)
                else:
                    expected_xp=[value+(0 if lethal and index==1 else 33) for index,value in enumerate(first['experience'])]
                    assert row['battle_phase']=='victory' and row['draws']==len(case['draws']) and row['money']==first['money']+70 and row['experience']==expected_xp
                if frames is not None and stage==len(stages)-1:(Path(frames)/f'battle-{tick}-state.json').write_text(json.dumps(row,indent=2)+'\n')
            victory=row
            assert [member['hp'] for member in victory['party']]==[16,max(0,guard_hp-42),100,100,100,100]
            assert victory['party'][1]['status']==('unconscious' if lethal else 'healthy')
            assert victory['party'][1]['inventory']==first['party'][1]['inventory'] and victory['party'][2:]==first['party'][2:]
            before=first['party'][0]['inventory']['slots'];after=victory['party'][0]['inventory']['slots'];count=next((i for i,slot in enumerate(before) if slot is None),len(before))
            assert after[:count]==before[:count] and after[count]['id']=='feather' and after[count+1:]==before[count+1:]
            case['steps'] += [{'buttons':{'confirm':True}},{}];path.write_text(json.dumps(case));final=state_rows(run('--check-world-replay',FIELD,ART,path,*extra))[-1]
            assert final['mode']=='world' and final['camera']==victory['camera']
            for key in ('party','money','experience','levels','random','formation','loadouts','runes','storage','reserves','draws'):assert final[key]==victory[key],key
            if stage==1:third_end=len(launch)+379
        if cover_knockout:
            assert final['draws']==119 and final['money']==checkpoint['money']+280 and final['experience']==[132,99,132,132,132,132]
        points=(first_end,third_end if cover_knockout else len(entered),len(launch)+48,len(launch)+61,len(launch)+72,len(launch)+379)
        progress_checks(root,path,final,points,battle_art)
    return len(case['steps'])


def roc_two_round_checks(root,packet,battle_art,frames=None):
    reference=json.loads((ROOT/'game/tests/fixtures/world_roc_two_round.json').read_text())[0]
    case=copy.deepcopy(packet);checkpoint=case['checkpoint'];checkpoint['levels']=''.join(chr(14) for _ in range(6));checkpoint['experience']=[0]*6
    capacity=json.loads((ROOT/'game/tests/fixtures/inn_transactions.json').read_text())[0]['max_rune_charges']
    for index,(member,stats,source_stats) in enumerate(zip(checkpoint['party'],checkpoint['stats'],reference['stats'])):
        member.update(hp=100,max_hp=100,status='healthy',rune_charges=[1,0,0,0],max_rune_charges=capacity)
        stats.update(attack=source_stats[6],skill=source_stats[1],defense=source_stats[7],speed=source_stats[3],magic=source_stats[4],luck=source_stats[5])
    checkpoint['formation']=''.join(chr(i) for i in range(6))
    case['draws']=[0,3*(32767//8)]+[51]*7+[r['value'] for r in reference['first']['draws']]+[r['value'] for r in reference['second']['draws']]+[0,0]
    path=root/'roc-two-rounds.json';extra=(battle_art,)
    first_frames=second_frames=None
    if frames is not None:
        first_frames=Path(frames)/'first';second_frames=Path(frames)/'second'
        first_frames.mkdir(parents=True,exist_ok=True);second_frames.mkdir(parents=True,exist_ok=True)
    prefix=case['steps'][:90]+[{}, {'buttons':{'confirm':True}}]+roc_party_commands(checkpoint)+[{'buttons':{'confirm':True}},{}]
    def check(row,expected,offset):
        assert row['battle_ticks']==expected['tick'] and row['battle_enemy_hp']==[expected['enemy_hp']]
        assert row['party'][0]['hp']==expected['hero_hp'] and row['party'][1]['hp']==expected['guard_hp'] and row['draws']==offset+expected['draws'], (expected['tick'],row['party'][0]['hp'],expected['hero_hp'],row['party'][1]['hp'],expected['guard_hp'],row['draws'],offset+expected['draws'])
        for key,value in expected['coordinator'].items():assert row['battle_coordinator'][key]==value,(expected['tick'],key,row['battle_coordinator'][key],value)
        for index,key in ((0,'hero'),(1,'guard'),(6,'roc')):
            actual=next((q for q in row['battle_frame']['quads'] if q['actor']==index),None)
            assert (actual is not None)==expected[key]['visible']
            if actual is not None:assert actual['position']==expected[key]['position'] and actual['pose_index']==expected[key]['pose']
        assert row['money']==checkpoint['money'] and row['experience']==checkpoint['experience']
        for member,initial in zip(row['party'],checkpoint['party']):
            assert member['inventory']==initial['inventory'] and member['rune_charges']==initial['rune_charges']
    for tick in (1,49,145,146,218,253,254,264,274,275,276):
        case['steps']=prefix+[{}]*(tick-1);path.write_text(json.dumps(case));row=state_rows(run('--check-world-replay',FIELD,ART,path,battle_art,*(() if first_frames is None else (first_frames,))))[-1]
        expected=reference['classifier'] if tick==276 else reference['first']['samples'][tick-1]
        check(row,expected,31 if tick==276 else 9)
        if first_frames is not None:(first_frames/f'battle-{tick}-state.json').write_text(json.dumps(row,indent=2)+'\n')
    menu=prefix+[{}]*276;case['steps']=menu;path.write_text(json.dumps(case));row=state_rows(run('--check-world-replay',FIELD,ART,path,*extra))[-1]
    assert row['battle_phase']=='battle_menu' and row['battle_round']==2 and row['battle_enemy_hp']==[48] and row['draws']==31
    assert row['battle_coordinator'] is None and row['money']==checkpoint['money'] and row['experience']==[0]*6
    launch=menu+[{}, {'buttons':{'confirm':True}}]+roc_party_commands(checkpoint)+[{'buttons':{'confirm':True}},{}]
    assert len(launch)-len(menu)==reference['menu_updates']+1
    case['steps']=launch;path.write_text(json.dumps(case));row=state_rows(run('--check-world-replay',FIELD,ART,path,*extra))[-1]
    check(row,reference['launch'],31);assert row['battle_round_camera_choice']==0
    for tick in (1,5,29,30,31,32,80,93,104,176,177,249,285,305,378,379,411):
        case['steps']=launch+[{}]*tick;path.write_text(json.dumps(case));row=state_rows(run('--check-world-replay',FIELD,ART,path,battle_art,*(() if second_frames is None else (second_frames,))))[-1]
        if tick<=379:check(row,reference['second']['samples'][tick-1],31)
        else:
            assert row['battle_phase']=='victory' and row['money']==checkpoint['money']+70 and row['experience']==[33]*6 and row['draws']==59
        if second_frames is not None:(second_frames/f'battle-{tick}-state.json').write_text(json.dumps(row,indent=2)+'\n')
    victory=row;expected=copy.deepcopy(checkpoint['party']);expected[0]['hp']=16;expected[1]['hp']=58
    bag=expected[0]['inventory']['slots'];slot=next(i for i,item in enumerate(bag) if item is None);bag[slot]=dict(id='feather',uses=0,identified=True)
    assert victory['party']==expected
    for key in ('random','runes','formation','stats','loadouts','storage','reserves','levels','weapon_levels'):assert victory[key]==checkpoint[key],key
    case['steps'] += [{'buttons':{'confirm':True}},{}];path.write_text(json.dumps(case));final=state_rows(run('--check-world-replay',FIELD,ART,path,*extra))[-1]
    assert final['mode']=='world' and final['party']==victory['party'] and final['camera']==victory['camera']
    for key in ('money','experience','random','draws','formation','runes','loadouts','stats','storage','reserves'):assert final[key]==victory[key],key
    progress_checks(root,path,final,(len(prefix)+217,len(prefix)+274,len(menu),len(launch)-1,len(launch),len(launch)+31,len(launch)+79,len(launch)+411),battle_art)
    return len(case['steps'])



def roc_long_battle_checks(root,packet,battle_art):
    reference=json.loads((ROOT/'game/tests/fixtures/world_roc_long_battle.json').read_text())
    case=copy.deepcopy(packet);checkpoint=case['checkpoint'];checkpoint['levels']=''.join(chr(14) for _ in range(6));checkpoint['experience']=[0]*6
    checkpoint['formation']=''.join(chr(i) for i in range(6))
    capacity=json.loads((ROOT/'game/tests/fixtures/inn_transactions.json').read_text())[0]['max_rune_charges']
    for index,(member,stats,source_stats) in enumerate(zip(checkpoint['party'],checkpoint['stats'],reference['stats'])):
        hp=reference['initial_hp'] if index==0 else 100
        member.update(hp=hp,max_hp=hp,status='healthy',rune_charges=[0]*4,max_rune_charges=capacity)
        stats.update(attack=source_stats[6],skill=source_stats[1],defense=source_stats[7],speed=source_stats[3],magic=source_stats[4],luck=source_stats[5])
    case['draws']=[0,3*(32767//8)]+[51]*7+[r['value'] for r in reference['first']['draws']]+[r['value'] for round in reference['rounds'] for r in round['draws']]+[0,0]
    path=root/'roc-long-battle.json';prefix=case['steps'][:90]+[{}, {'buttons':{'confirm':True}}]+roc_party_commands(checkpoint)+[{'buttons':{'confirm':True}},{}]
    points=[];offset=9
    tracks=[reference['first']]+reference['rounds']
    for round_index,track in enumerate(tracks):
        for tick in sorted({1,49,80,145,176,218,249,len(track['samples'])}):
            if tick>len(track['samples']):continue
            case['steps']=prefix+[{}]*(tick if round_index else tick-1);path.write_text(json.dumps(case))
            actual=state_rows(run('--check-world-replay',FIELD,ART,path,battle_art))[-1];expected=track['samples'][tick-1]
            assert actual['battle_round']==round_index+1 and actual['battle_ticks']==tick
            assert actual['party'][0]['hp']==expected['hero_hp'] and actual['party'][1]['hp']==expected['guard_hp'] and actual['battle_enemy_hp']==[expected['enemy_hp']]
            assert actual['draws']==offset+expected['draws']
            for key,value in expected['coordinator'].items():assert actual['battle_coordinator'][key]==value,(round_index,tick,key)
            for index,visual in zip((0,1,6),expected['visuals']):
                quad=next((q for q in actual['battle_frame']['quads'] if q['actor']==index),None)
                assert (quad is not None)==visual['visible']
                if quad is not None:assert quad['pose_index']==visual['pose'] and quad['position']==visual['position']
            assert actual['money']==checkpoint['money'] and actual['experience']==[0]*6
        prefix += [{}]*(len(track['samples']) if round_index else len(track['samples'])-1)
        points.extend((len(prefix)-1,len(prefix)))
        offset+=len(track['draws'])
        if round_index<len(tracks)-1:
            prefix += [{},{}]+[{}, {'buttons':{'confirm':True}}]+roc_party_commands(checkpoint)+[{'buttons':{'confirm':True}},{}]
    case['steps']=prefix+[{}]*32;path.write_text(json.dumps(case));victory=state_rows(run('--check-world-replay',FIELD,ART,path,battle_art))[-1]
    assert victory['battle_phase']=='victory' and victory['battle_round']==4 and victory['party'][0]['hp']==663
    assert victory['draws']==offset+2 and victory['money']==checkpoint['money']+70 and victory['experience']==[33]*6
    case['steps'] += [{}]*4+[{'buttons':{'confirm':True}},{}];path.write_text(json.dumps(case));final=state_rows(run('--check-world-replay',FIELD,ART,path,battle_art))[-1]
    assert final['mode']=='world' and final['party']==victory['party'] and final['camera']==victory['camera']
    for key in ('money','experience','random','draws','formation','runes','loadouts','stats','storage','reserves'):assert final[key]==victory[key],key
    points.extend((len(case['steps'])-7,len(case['steps'])-1))
    progress_checks(root,path,final,tuple(points),battle_art)
    return len(case['steps'])


def roc_medicine_checks(root,packet,battle_art,frames=None):
    reference=json.loads((ROOT/'game/tests/fixtures/world_medicine.json').read_text())['roc']
    case=copy.deepcopy(packet);checkpoint=case['checkpoint'];checkpoint['levels']=''.join(chr(14) for _ in range(6));checkpoint['experience']=[0]*6
    checkpoint['formation']=''.join(chr(i) for i in range(6))
    for member,stats in zip(checkpoint['party'],checkpoint['stats']):
        member.update(hp=100,max_hp=100,status='healthy',rune_charges=[0,0,0,0]);stats.update(speed=0,defense=40)
    checkpoint['stats'][0].update(attack=180,skill=9999,luck=0,speed=24)
    checkpoint['party'][1]['inventory']['slots']=[dict(id='medicine',uses=6,identified=True)]+[None]*8
    case['draws']=[0,3*(32767//8)]+[51]*29+[0,0]
    path=root/'roc-medicine.json';extra=(battle_art,)+(() if frames is None else (frames,))
    prefix=case['steps'][:90]+[{}, {'buttons':{'confirm':True}}]+[{'buttons':{'confirm':True}}]*2
    prefix += [{'buttons':{'navigation':'down'}}]*2+[{'buttons':{'confirm':True}}]*2
    # Cancel target selection and the item list; neither owns a charge or HP change.
    for button,phase in (({'cancel':True},'item'),({'cancel':True},'command')):
        prefix.append({'buttons':button});case['steps']=prefix;path.write_text(json.dumps(case));row=state_rows(run('--check-world-replay',FIELD,ART,path,battle_art))[-1]
        assert row['battle_phase']==phase and row['party']==checkpoint['party'] and row['draws']==2
    prefix += [{'buttons':{'confirm':True}}]*2+[{'buttons':{'navigation':'up'}},{'buttons':{'confirm':True}}]
    prefix += roc_party_commands(checkpoint)[4:] # Hero/Gremio commands were entered above; Pahn and rear members Defend.
    prefix += [{'buttons':{'confirm':True}},{}]
    for tick in (1,49,145,146,167,168,169,180,197,198,199,200,231,232,235,247,307,343,363,436,437):
        case['steps']=prefix+[{}]*(tick-1);path.write_text(json.dumps(case));row=state_rows(run('--check-world-replay',FIELD,ART,path,*extra))[-1];expected=reference['samples'][tick-1]
        assert row['battle_ticks']==tick and row['party'][0]['hp']==expected['hero_hp'] and row['battle_enemy_hp']==[expected['enemy_hp']],(tick,row['battle_ticks'],row['battle_phase'])
        assert row['party'][1]['inventory']['slots'][0]['uses']==expected['uses'] and row['draws']==expected['draws']+9
        assert row['money']==checkpoint['money'] and row['experience']==checkpoint['experience']
        for key,value in expected['coordinator'].items():assert row['battle_coordinator'][key]==value,(tick,key)
        for index,key in ((0,'hero'),(1,'guard'),(6,'roc')):
            quad=next((q for q in row['battle_frame']['quads'] if q['actor']==index),None)
            assert (quad is not None)==expected[key]['visible']
            if quad is not None:assert quad['position']==expected[key]['position'] and quad['pose_index']==expected[key]['pose'],(tick,key)
        assert sum(q['medicine_particle'] for q in row['battle_frame']['quads'])==len(expected['particles'])
        if frames is not None:(Path(frames)/f'battle-{tick}-state.json').write_text(json.dumps(row,indent=2)+'\n')
    case['steps']=prefix+[{}]*468;path.write_text(json.dumps(case));victory=state_rows(run('--check-world-replay',FIELD,ART,path,*extra))[-1]
    assert victory['battle_phase']=='victory' and victory['money']==checkpoint['money']+70 and victory['experience']==[33]*6 and victory['draws']==33
    expected=copy.deepcopy(checkpoint['party']);expected[1]['inventory']['slots'][0]['uses']=5
    count=sum(slot is not None for slot in expected[0]['inventory']['slots']);drop=victory['party'][0]['inventory']['slots'][count];assert drop['id']=='feather';expected[0]['inventory']['slots'][count]=drop
    assert victory['party']==expected
    case['steps'] += [{}]*4+[{'buttons':{'confirm':True}},{}];path.write_text(json.dumps(case));final=state_rows(run('--check-world-replay',FIELD,ART,path,battle_art))[-1]
    assert final['mode']=='world' and final['remaining']==0 and final['camera']==victory['camera']
    assert final['battle_medicine'] is None
    for key in ('party','money','experience','levels','random','draws','formation','runes','loadouts','stats','storage','reserves','story','weapon_levels','save_name'):assert final[key]==victory[key],key
    progress_checks(root,path,final,tuple(len(prefix)+tick-1 for tick in (146,168,180,199,200,232,247,469)),battle_art)
    return len(case['steps'])



def roc_party_medicine_checks(root,packet,battle_art,actor,target):
    """Normal menus exercise self-use and a back-row user/target before continuing the fight."""
    case=copy.deepcopy(packet);checkpoint=case['checkpoint'];checkpoint['levels']=''.join(chr(14) for _ in range(6));checkpoint['experience']=[0]*6
    checkpoint['formation']=''.join(chr(i) for i in range(6))
    capacity=json.loads((ROOT/'game/tests/fixtures/inn_transactions.json').read_text())[0]['max_rune_charges']
    for index,(member,stats) in enumerate(zip(checkpoint['party'],checkpoint['stats'])):
        hp=300 if index==0 and actor!=0 else 100
        member.update(hp=hp,max_hp=hp,status='healthy',rune_charges=[0]*4,max_rune_charges=capacity)
        stats.update(speed=0,defense=40,magic=50)
    checkpoint['stats'][0].update(attack=180,skill=9999,luck=0,speed=24)
    if target!=0:checkpoint['party'][target]['hp']=16
    checkpoint['party'][actor]['inventory']['slots']=[dict(id='medicine',uses=6,identified=True)]+[None]*8
    case['draws']=[0,3*(32767//8)]+[51]*512
    path=root/f'roc-medicine-{actor}-{target}.json'
    case['steps']=case['steps'][:90]+[{}, {'buttons':{'confirm':True}}]
    def current():
        path.write_text(json.dumps(case));return state_rows(run('--check-world-replay',FIELD,ART,path,battle_art))[-1]
    for _ in range(64):
        row=current();phase=row['battle_phase']
        if phase=='confirm_round':break
        if phase=='command':
            wanted='item' if row['battle_actor']==actor else 'defend'
            button={'confirm':True} if row['battle_command']==wanted else {'navigation':'down'}
        elif phase=='item':button={'confirm':True}
        elif phase=='item_target':button={'confirm':True} if row['battle_selection']==target else {'navigation':'down'}
        else:raise AssertionError(phase)
        case['steps'].append({'buttons':button})
    else:raise AssertionError('ordinary command selection did not finish')
    case['steps'].append({'buttons':{'confirm':True}});commands=copy.deepcopy(case['steps'])
    for _ in range(30):
        case['steps'] += [{}]*8;row=current()
        if row['battle_medicine'] is not None:break
    else:raise AssertionError('queued Medicine did not dispatch')
    dispatch=len(case['steps'])-row['battle_medicine']['ticks']+1
    reference=next(r for r in json.loads((ROOT/'game/tests/fixtures/world_medicine_party.json').read_text()) if r['actor']==actor and r['target']==target)
    timing=row['battle_medicine']['timing'];before_hp=16;amount=min(100,checkpoint['party'][target]['max_hp']-before_hp)
    points=[]
    for tick in sorted({1,timing['target_start'],timing['pending_tick'],timing['impact_tick'],timing['target_release'],len(reference['samples'])}):
        case['steps']=commands+[{}]*(dispatch-len(commands)+tick-1);row=current();expected=reference['samples'][tick-1]
        assert row['battle_medicine']['ticks']==tick and row['party'][actor]['inventory']['slots'][0]['uses']==5
        assert row['party'][target]['hp']==before_hp+(amount if tick>=timing['impact_tick'] else 0)
        for index,key in ((actor,'owner'),(target,'target')):
            quad=next(q for q in row['battle_frame']['quads'] if q['actor']==index)
            if index==actor or tick>=timing['target_start']:assert quad['pose_index']==expected[key]['pose'],(actor,target,tick,key)
        points.append(len(case['steps']))
    case['steps']=commands+[{}]*400;row=current()
    assert row['battle_phase']=='battle_menu' and row['battle_round']==2 and row['battle_enemy_hp']==[110]
    assert row['money']==checkpoint['money'] and row['experience']==[0]*6
    case['steps'] += [{'buttons':{'confirm':True}}]+roc_party_commands(checkpoint)+[{'buttons':{'confirm':True}},{}]
    launch=copy.deepcopy(case['steps']);case['steps'] += [{}]*379;row=current()
    assert row['battle_enemy_hp']==[0] and row['money']==checkpoint['money']
    case['draws']=case['draws'][:row['draws']]+[0,0]
    case['steps']=launch+[{}]*411;victory=current()
    assert victory['battle_phase']=='victory' and victory['money']==checkpoint['money']+70 and victory['experience']==[33]*6
    assert victory['party'][actor]['inventory']['slots'][0]['uses']==5
    assert victory['party'][0]['hp']==(16 if actor==0 else 174)
    case['steps'] += [{}]*4+[{'buttons':{'confirm':True}},{}];final=current()
    assert final['mode']=='world' and final['party']==victory['party'] and final['battle_medicine'] is None
    progress_checks(root,path,final,tuple(points),battle_art)
    return len(case['steps'])


def roc_recovery_checks(root,packet,battle_art):
    """Existing source-priced services close the post-KO loop through ordinary inputs."""
    supplied=copy.deepcopy(packet)
    for member in supplied['checkpoint']['party']:member['rune_charges']=[0]*4
    assert roc_loop_checks(root,supplied,battle_art,cover=True,cover_knockout=True)==1937
    path=root/'four-rocs-cover.json';case=json.loads(path.read_text())
    before=state_rows(run('--check-world-replay',FIELD,ART,path,battle_art))[-1]
    assert before['party'][1]['hp']==0 and all(member['rune_charges']==[0]*4 for member in before['party'])
    # Normal high chance draws avoid extra battles on the return walk; no suppression flag.
    path=root/'roc-recovery.json';prior=len(case['steps']);case['steps'] += [{'buttons':{'direction':'up'}}]*200;case['draws'] += [32767]*32
    path.write_text(json.dumps(case));rows=state_rows(run('--check-world-replay',FIELD,ART,path,battle_art))
    entered=next(row for row in rows if row['steps']>prior and row['mode']=='field')
    assert entered['field_room']=='vb6_village' and entered['field_position']==dict(x=264,y=344) and entered['party']==before['party']
    case['steps']=case['steps'][:entered['steps']];case['draws']=case['draws'][:entered['draws']]
    points={};case['steps'] += service_walk(json.loads((FIELD/'room.json').read_text()),entered['story'],recovery=True,points=points)
    samples={}
    for key,count in (('cancelled',points['cancelled']),('before_payment',points['paid']-1),('paid',points['paid'])):
        probe=dict(case,steps=case['steps'][:entered['steps']+count]);path.write_text(json.dumps(probe))
        samples[key]=state_rows(run('--check-world-replay',FIELD,ART,path,battle_art))[-1]
    paid=samples['paid'];inn=json.loads((ROOT/'game/assets/inn.json').read_text());cost=6*inn['price_per_member']
    restored=copy.deepcopy(before['party'])
    for member in restored:member.update(hp=member['max_hp'],status='healthy',balloons=0,rune_charges=member['max_rune_charges'])
    assert paid['field_room']=='vb6_inn' and paid['party']==restored and paid['money']==before['money']-cost and paid['draws']==entered['draws']
    for key in ('cancelled','before_payment'):
        assert samples[key]['party']==before['party'] and samples[key]['money']==before['money'] and samples[key]['draws']==entered['draws']
    path.write_text(json.dumps(case));rows=state_rows(run('--check-world-replay',FIELD,ART,path,battle_art))
    final=rows[-1];rules=json.loads((ROOT/'game/assets/items.json').read_text());medicine=rules['medicine']
    bag=restored[0]['inventory']['slots'];slot=next(i for i,item in enumerate(bag) if item is None);bag[slot]=dict(id='medicine',uses=medicine['uses'],identified=True)
    assert final['mode']=='world' and final['camera']==dict(x=86,y=85) and final['remaining']==0 and final['travel_counter']==0
    assert final['party']==restored and final['money']==before['money']-cost-medicine['price'] and final['draws']==entered['draws']
    for key in ('experience','levels','stats','random','formation','weapon_levels','loadouts','runes','storage','reserves'):assert final[key]==before[key],key
    recovered=len(case['steps']);initial_draws=final['draws']
    case['draws'] += [0,3*(32767//8)]+[51]*29+[0,0]
    entry=case['steps']+[{'buttons':{'direction':'down'}}]*80+[{}];case['steps']=entry;path.write_text(json.dumps(case))
    row=state_rows(run('--check-world-replay',FIELD,ART,path,battle_art))[-1]
    assert row['mode']=='battle' and row['battle_phase']=='battle_menu' and row['party']==final['party'] and row['draws']==initial_draws+2
    launch=entry+[{}, {'buttons':{'confirm':True}}]+roc_party_commands(dict(party=final['party']))+[{'buttons':{'confirm':True}},{}]
    case['steps']=launch+[{}]*379;path.write_text(json.dumps(case));victory=state_rows(run('--check-world-replay',FIELD,ART,path,battle_art))[-1]
    expected=copy.deepcopy(restored);expected[0]['hp']=16;slot=next(i for i,item in enumerate(expected[0]['inventory']['slots']) if item is None);expected[0]['inventory']['slots'][slot]=dict(id='feather',uses=0,identified=True)
    assert victory['battle_phase']=='victory' and victory['party']==expected and victory['money']==final['money']+70 and victory['draws']==initial_draws+33
    assert victory['experience']==[165,132,165,165,165,165]
    case['steps'] += [{'buttons':{'confirm':True}},{}];path.write_text(json.dumps(case));returned=state_rows(run('--check-world-replay',FIELD,ART,path,battle_art))[-1]
    assert returned['mode']=='world' and returned['party']==victory['party'] and returned['money']==victory['money']
    progress_checks(root,path,returned,(entered['steps'],paid['steps']-1,paid['steps'],recovered,len(launch)+48,len(launch)+379),battle_art)
    return len(case['steps'])


def roc_defeat_checks(root,packet,battle_art,frames=None):
    """Two normal-input encounters: persistent low HP, then terminal ordinary defeat."""
    extra=(battle_art,) if frames is None else (battle_art,frames)
    case=copy.deepcopy(packet);checkpoint=case['checkpoint'];checkpoint['levels']=''.join(chr(14) for _ in range(6));checkpoint['experience']=[900,0,0,0,0,0]
    checkpoint['formation']=''.join(chr(i) for i in range(6))
    for index,(member,stats) in enumerate(zip(checkpoint['party'],checkpoint['stats'])):
        member.update(hp=100 if index==0 else 0,max_hp=100,status='healthy' if index==0 else 'unconscious');stats.update(speed=0,defense=40)
    checkpoint['stats'][0].update(attack=180,skill=9999,luck=0,speed=24)
    # First world gate, nine first-battle draws, real Feather, next world gate, five final-battle draws.
    case['draws']=[0,3*(32767//8)]+[51]*9+[0,0,0,3*(32767//8)]+[51]*5
    commands=[{}, {'buttons':{'confirm':True}}, {'buttons':{'confirm':True}}, {'buttons':{'confirm':True}}, {'buttons':{'confirm':True}}, {}]
    first_launch=case['steps'][:90]+commands
    first_end=first_launch+[{}]*379;path=root/'two-rocs.json';case['steps']=first_end;path.write_text(json.dumps(case))
    first=state_rows(run('--check-world-replay',FIELD,ART,path,*extra))[-1]
    assert first['battle_phase']=='victory' and first['money']==checkpoint['money']+70 and first['draws']==13
    assert [member['hp'] for member in first['party']]==[16,0,0,0,0,0]
    assert first['experience']==[933,0,0,0,0,0]
    returned=first_end+[{'buttons':{'confirm':True}}];case['steps']=returned;path.write_text(json.dumps(case))
    world=state_rows(run('--check-world-replay',FIELD,ART,path,*extra))[-1]
    assert world['mode']=='world' and world['party']==first['party'] and world['draws']==13
    entered=returned+[{'buttons':{'direction':'down'}}]*80+[{'buttons':{'direction':'up'}}]*16+[{}];case['steps']=entered;path.write_text(json.dumps(case))
    second=state_rows(run('--check-world-replay',FIELD,ART,path,*extra))[-1]
    assert second['mode']=='battle' and second['battle_phase']=='battle_menu' and second['battle_enemy_hp']==[110],{key:second[key] for key in ('mode','battle_phase','battle_enemy_hp','draws','camera','remaining','travel_counter')}
    assert second['party']==first['party'] and second['draws']==15
    launch=entered+commands
    reference=next(row for row in json.loads((ROOT/'game/tests/fixtures/world_roc_knockout.json').read_text()) if row['hp']==16 and row['alone'])
    for tick in (1,48,49,61,62,145,146,147):
        case['steps']=launch+[{}]*(tick-1);path.write_text(json.dumps(case));row=state_rows(run('--check-world-replay',FIELD,ART,path,*extra))[-1]
        assert row['mode']=='battle' and row['battle_ticks']==tick
        if tick<=146:
            expected=reference['samples'][tick-1]
            assert row['party'][0]['hp']==expected['hero_hp'] and row['draws']==17+expected['draws']
            actual=next(q for q in row['battle_frame']['quads'] if q['actor']==0)
            assert actual['pose_index']==expected['hero']['pose'] and actual['position']==expected['hero']['position']
            if tick<145:assert row['battle_action']['target_down']==expected['hero_down']
        else:assert row['battle_phase']=='defeat' and row['draws']==20
        for key in ('money','experience','runes','loadouts','stats','random','storage','reserves','formation','weapon_levels'):
            assert row[key]==first[key],key
        assert row['party'][0]['inventory']==first['party'][0]['inventory'] and row['party'][1:]==first['party'][1:]
        if frames is not None:(Path(frames)/f'battle-{tick}-state.json').write_text(json.dumps(row,indent=2)+'\n')
    defeated=row;terminal=len(case['steps'])
    case['steps'] += [{'buttons':{'confirm':True}}, {'buttons':{'cancel':True}}, {'buttons':{'menu':True}}, {'buttons':{'direction':'down','confirm':True}}, {}]
    path.write_text(json.dumps(case));final=state_rows(run('--check-world-replay',FIELD,ART,path,*extra))[-1]
    assert final['mode']=='battle' and final['battle_phase']=='defeat' and final['battle_coordinator'] is None
    assert all(member['hp']==0 and member['status']=='unconscious' for member in final['party'])
    for key in ('party','money','experience','random','draws','camera','remaining','runes','loadouts','stats','storage','reserves','formation','battle_ticks','battle_presentation_tick','battle_frame'):
        assert final[key]==defeated[key],key
    points=(len(first_end),len(returned),len(entered),len(launch)+48,len(launch)+61,terminal)
    progress_checks(root,path,final,points,battle_art)
    return len(case['steps'])


def verify(write_candidate=False):
    with tempfile.TemporaryDirectory(prefix='suikoden-world-replay-') as temporary:
        root = Path(temporary)
        isolated = root / 'isolated'; isolated.mkdir()
        run('--check-persistence', isolated, 'write')
        checkpoint = json.loads(primary_save(isolated).read_text())
        packet=supplied_packet(checkpoint);checkpoint=packet['checkpoint'];steps=packet['steps']
        path = root / 'replay.json'
        path.write_text(json.dumps(packet, indent=2)+'\n')
        original = path.read_bytes()
        before = {p.relative_to(isolated): p.read_bytes() for p in isolated.rglob('*') if p.is_file()}
        first = run('--check-world-replay', FIELD, ART, path)
        second = run('--check-world-replay', FIELD, ART, path)
        assert first.stdout == second.stdout
        rows = [json.loads(line) for line in first.stdout.splitlines() if line.startswith('{')]
        assert all(row['kind'] == 'diagnostic-world-replay' for row in rows)
        assert rows[0]['mode'] == rows[-1]['mode'] == 'world'
        assert rows[0]['steps'] == 0 and rows[-1]['steps'] == len(steps)
        assert rows[0]['draws'] == 0 and rows[-1]['draws'] == 2
        assert any(row['mode'] == 'field' for row in rows)
        assert any(row['mode'] == 'battle' and not row['presentation_available'] for row in rows)
        for row in rows:
            for key in ('party', 'money', 'levels', 'experience', 'stats', 'random', 'formation', 'weapon_levels', 'loadouts', 'runes', 'storage', 'reserves', 'save_name'):
                assert row[key] == checkpoint[key], (key, checkpoint[key], row[key])
        # Encounter admission must not require an enemy action just to choose Let go.
        for index in (0, 2, 3, 4, 5, 6, 7):
            variant = copy.deepcopy(packet); variant['draws'][1] = index*(32767//8)
            variant_path = root/'roster.json'; variant_path.write_text(json.dumps(variant))
            roster_rows = state_rows(run('--check-world-replay', FIELD, ART, variant_path))
            assert any(row['mode']=='battle' for row in roster_rows)
            assert roster_rows[-1]['mode']=='world' and roster_rows[-1]['draws']==2
            for key in ('party', 'money', 'levels', 'formation', 'runes', 'storage', 'reserves', 'random'):
                assert roster_rows[-1][key] == rows[-1][key], (index,key)
        assert rows[0]['story'] == rows[-1]['story']
        assert rows[-1]['elapsed_ticks'] == checkpoint['elapsed_ticks'] + len(steps)
        assert path.read_bytes() == original
        assert before == {p.relative_to(isolated): p.read_bytes() for p in isolated.rglob('*') if p.is_file()}
        services = copy.deepcopy(packet)
        services['steps'] = service_walk(json.loads((FIELD/'room.json').read_text()), checkpoint['story'])
        services['draws'] = []
        service_path = root/'services.json'; service_path.write_text(json.dumps(services))
        service_result = run('--check-world-replay', FIELD, ART, service_path)
        service_rows = [json.loads(line) for line in service_result.stdout.splitlines() if line.startswith('{')]
        final = service_rows[-1]
        assert final['mode'] == 'field' and final['field_room'] == 'vb6_village' and final['service_menu'] == 'closed'
        assert final['draws'] == 0
        assert final['story']['forest_elf_seen'] and final['story']['village_south_exit_reached']
        rules = json.loads((ROOT/'game/assets/items.json').read_text())
        battle = json.loads((FIELD/'battle/trial.json').read_text())
        hero = next(profile for profile in battle['party'] if profile['id'] == checkpoint['party'][0]['id'])
        levels = list(map(ord, checkpoint['weapon_levels'])); price = hero['weapon']['upgrade_costs'][levels[0]]; levels[0] += 1
        assert final['weapon_levels'] == ''.join(map(chr, levels))
        expected_party = copy.deepcopy(checkpoint['party'])
        slots = expected_party[0]['inventory']['slots']; slot = slots.index(None)
        slots[slot] = dict(id='medicine', uses=rules['medicine']['uses'], identified=True)
        assert final['party'] == expected_party
        assert final['money'] == checkpoint['money'] - rules['medicine']['price'] - price
        for key in ('levels', 'experience', 'stats', 'random', 'formation', 'loadouts', 'runes', 'storage', 'reserves', 'save_name'):
            assert final[key] == checkpoint[key], key
        assert final['elapsed_ticks'] == checkpoint['elapsed_ticks'] + len(services['steps'])
        # File checkpoints reconstruct prefixes of the supplied diagnostic input only.
        progress = progress_checks(root, path, rows[-1], (0, 1, 2, 5, 10, 29, 90, 91, 93, 293))
        menu_points = tuple(i+1 for i, step in enumerate(services['steps']) if step.get('buttons', {}).get('navigation') == 'right')
        assert len(menu_points) == 2
        progress_checks(root, service_path, final, menu_points)
        pair = root/'progress-backup'; pair.mkdir()
        run('--check-world-replay-progress', FIELD, ART, path, pair, 29)
        run('--check-world-replay-progress', FIELD, ART, path, pair, 90)
        primary, backup = pair/'world-replay-progress.json', pair/'world-replay-progress.json.bak'
        good = primary.read_bytes(); previous = backup.read_bytes()
        corrupt = json.loads(good); corrupt['state_digest'] = '0'*64
        primary.write_text(json.dumps(corrupt))
        recovered = run('--check-world-replay-progress', FIELD, ART, path, pair, 'resume')
        messages = [json.loads(line) for line in recovered.stdout.splitlines() if line.startswith('{')]
        assert messages[0]['source'] == 'backup' and messages[0]['completed_steps'] == 29
        assert state_rows(recovered)[-1] == rows[-1]
        # Saving after corruption keeps the independently replay-validated backup.
        run('--check-world-replay-progress', FIELD, ART, path, pair, 93)
        assert backup.read_bytes() == previous
        primary.write_text('{"schema":"future"}\n')
        protected = primary.read_bytes()
        assert 'UnsupportedReplayProgress' in run('--check-world-replay-progress', FIELD, ART, path, pair, 90, success=False).stderr
        assert 'UnsupportedReplayProgress' in run('--check-world-replay-progress', FIELD, ART, path, pair, 'resume', success=False).stderr
        assert primary.read_bytes() == protected and backup.read_bytes() == previous
        primary.write_bytes(good)
        if os.geteuid() != 0:
            pair.chmod(0o555)
            try:
                run('--check-world-replay-progress', FIELD, ART, path, pair, 93, success=False)
                assert primary.read_bytes() == good and backup.read_bytes() == previous
            finally:pair.chmod(0o755)
        different = copy.deepcopy(packet); different['update_hz'] = 59
        other = root/'different.json'; other.write_text(json.dumps(different))
        assert 'ReplaySourceMismatch' in run('--check-world-replay-progress', FIELD, ART, other, pair, 'resume', success=False).stderr
        assert 'ReplaySourceMismatch' in run('--check-world-replay-progress', FIELD, ART, other, pair, 29, success=False).stderr
        assert primary.read_bytes() == good and backup.read_bytes() == previous
        # A copied app process, outside the repository, resumes the same bound input.
        contents = root/'WorldReplay.app/Contents'
        packed = contents/'MacOS/WorldReplay'; packed.parent.mkdir(parents=True)
        shutil.copy2(EXE, packed)
        field_copy = contents/'Resources/field'; art_copy = contents/'Resources/world'
        for directory, names, source in ((field_copy, ('room.json', 'journey.json', 'atlas.png', 'battle/trial.json'), FIELD), (art_copy, ('scene.json', 'world.png'), ART)):
            for name in names:
                target = directory/name; target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source/name, target)
        packaged_result = run('--check-world-replay-progress', field_copy, art_copy, path, pair, 'resume', executable=packed, cwd=isolated)
        assert state_rows(packaged_result)[-1] == rows[-1]
        bad = root / 'bad.json'
        bad.write_text('{"schema":"future"}\n')
        assert 'UnsupportedWorldReplay' in run('--check-world-replay', FIELD, ART, bad, success=False).stderr
        invalid = copy.deepcopy(packet); invalid['checkpoint']['room'] = 'vb6_inn'
        bad.write_text(json.dumps(invalid))
        assert 'ReplayRequiresVillageExitCheckpoint' in run('--check-world-replay', FIELD, ART, bad, success=False).stderr
        invalid = copy.deepcopy(packet); invalid['draws'] = []
        bad.write_text(json.dumps(invalid))
        assert 'RandomInputExhausted' in run('--check-world-replay', FIELD, ART, bad, success=False).stderr
        invalid = copy.deepcopy(packet); invalid['steps'] = [{'buttons': {'menu': True}}]
        bad.write_text(json.dumps(invalid))
        menu_rows = state_rows(run('--check-world-replay', FIELD, ART, bad))
        assert menu_rows[-1]['world_menu'] is True
        roc_steps=roc_loop_checks(root,packet)
        bound_root=root/'bound-battle';bound_root.mkdir()
        battle_art=ROOT/'kit/work/build/world-battle-art'
        bound_roc_steps=roc_loop_checks(bound_root,packet,battle_art)
        bound_packet=bound_root/'roc-loop.json'
        bound_result=run('--check-world-replay',FIELD,ART,bound_packet,battle_art)
        bound_packaged=run('--check-world-replay',FIELD,ART,bound_packet,battle_art,executable=packed,cwd='/')
        assert bound_result.stdout==bound_packaged.stdout
        defeat_root=root/'defeat-battle';defeat_root.mkdir()
        defeat_steps=roc_defeat_checks(defeat_root,packet,battle_art)
        defeat_packet=defeat_root/'two-rocs.json'
        assert run('--check-world-replay',FIELD,ART,defeat_packet,battle_art).stdout==run('--check-world-replay',FIELD,ART,defeat_packet,battle_art,executable=packed,cwd='/').stdout

        cover_root=root/'cover-battle';cover_root.mkdir()
        cover_steps=roc_loop_checks(cover_root,packet,battle_art,cover=True)
        cover_packet=cover_root/'two-rocs-cover.json'
        assert run('--check-world-replay',FIELD,ART,cover_packet,battle_art).stdout==run('--check-world-replay',FIELD,ART,cover_packet,battle_art,executable=packed,cwd='/').stdout

        cover_ko_root=root/'cover-ko-battle';cover_ko_root.mkdir()
        cover_ko_steps=roc_loop_checks(cover_ko_root,packet,battle_art,cover=True,cover_knockout=True)
        cover_ko_packet=cover_ko_root/'four-rocs-cover.json'
        assert run('--check-world-replay',FIELD,ART,cover_ko_packet,battle_art).stdout==run('--check-world-replay',FIELD,ART,cover_ko_packet,battle_art,executable=packed,cwd='/').stdout

        recovery_root=root/'recovery-loop';recovery_root.mkdir()
        recovery_steps=roc_recovery_checks(recovery_root,packet,battle_art)
        recovery_packet=recovery_root/'roc-recovery.json'
        assert run('--check-world-replay',FIELD,ART,recovery_packet,battle_art).stdout==run('--check-world-replay',FIELD,ART,recovery_packet,battle_art,executable=packed,cwd='/').stdout

        party_medicine_steps=[]
        for actor,target in ((0,0),(4,5)):
            party_root=root/f'party-medicine-{actor}-{target}';party_root.mkdir()
            party_medicine_steps.append(roc_party_medicine_checks(party_root,packet,battle_art,actor,target))
            party_packet=party_root/f'roc-medicine-{actor}-{target}.json'
            assert run('--check-world-replay',FIELD,ART,party_packet,battle_art).stdout==run('--check-world-replay',FIELD,ART,party_packet,battle_art,executable=packed,cwd='/').stdout
        long_root=root/'long-battle';long_root.mkdir()
        long_steps=roc_long_battle_checks(long_root,packet,battle_art)
        long_packet=long_root/'roc-long-battle.json'
        assert run('--check-world-replay',FIELD,ART,long_packet,battle_art).stdout==run('--check-world-replay',FIELD,ART,long_packet,battle_art,executable=packed,cwd='/').stdout
        rounds_root=root/'two-round-battle';rounds_root.mkdir()
        rounds_steps=roc_two_round_checks(rounds_root,packet,battle_art)
        rounds_packet=rounds_root/'roc-two-rounds.json'
        assert run('--check-world-replay',FIELD,ART,rounds_packet,battle_art).stdout==run('--check-world-replay',FIELD,ART,rounds_packet,battle_art,executable=packed,cwd='/').stdout

        medicine_root=root/'medicine-battle';medicine_root.mkdir()
        medicine_steps=roc_medicine_checks(medicine_root,packet,battle_art)
        medicine_packet=medicine_root/'roc-medicine.json'
        assert run('--check-world-replay',FIELD,ART,medicine_packet,battle_art).stdout==run('--check-world-replay',FIELD,ART,medicine_packet,battle_art,executable=packed,cwd='/').stdout

        # One actual Rabbit projectile, with source-bounded timing and a back-row target.
        projectile = copy.deepcopy(packet)
        for member, stats in zip(projectile['checkpoint']['party'], projectile['checkpoint']['stats']):
            member.update(hp=100, max_hp=100, status='healthy'); stats.update(speed=0, defense=40)
        projectile['draws'] = [0,4*(32767//8)] + [0]*12 + [32767,32767,100]
        profiles = {profile['id']:profile for profile in json.loads((FIELD/'battle/trial.json').read_text())['party']}
        defend_steps = []
        for index,member in enumerate(projectile['checkpoint']['party']):
            position = projectile['checkpoint']['formation'][index]
            position = ord(position) if isinstance(position,str) else position
            # Rear short-range members already select Defend because Attack is disabled.
            if not (position>=3 and profiles[member['id']]['weapon_range']=='short'):
                defend_steps.append({'buttons': {'navigation': 'down'}})
            defend_steps.append({'buttons': {'confirm': True}})
        attack_steps = (steps[:90] + [{}, {'buttons': {'confirm': True}}] + defend_steps
                        + [{'buttons': {'confirm': True}}, {}])
        for tick in (1,63,64,94,117):
            projectile['steps'] = attack_steps + [{}]*(tick-1); bad.write_text(json.dumps(projectile))
            row = state_rows(run('--check-world-replay',FIELD,ART,bad))[-1]
            assert row['mode']=='battle' and row['battle_phase']=='resolving', (tick,row['mode'],row['battle_phase'])
            assert row['battle_ticks']==tick and row['draws']==16+int(tick>=64)
            expected = copy.deepcopy(projectile['checkpoint']['party'])
            if tick>=64:expected[4]['hp']-=27
            assert row['party']==expected
            if tick<117:
                assert row['battle_action']['projectile'] and row['battle_action']['target']==4
                assert row['battle_action']['projectile_alive']==(tick<94)
            else:assert row['battle_action'] is None
            for key in ('money','runes','storage','reserves','formation','random'):
                assert row[key]==projectile['checkpoint'][key],key
        # Ordinary fallback: one rejected scan waits a frame, then launches without rerolling priorities.
        ordinary = copy.deepcopy(projectile)
        ordinary['draws'] = [0,4*(32767//8)] + [0]*12 + [0,0,0,0] + [0,32767,99,100]
        ordinary['steps'] = attack_steps; bad.write_text(json.dumps(ordinary))
        waiting = state_rows(run('--check-world-replay',FIELD,ART,bad))[-1]
        assert waiting['battle_pending_actor']==6 and waiting['battle_action'] is None
        assert waiting['battle_ticks']==0 and waiting['draws']==18
        assert waiting['party']==ordinary['checkpoint']['party']
        for tick in (1,78,79,99,134):
            ordinary['steps'] = attack_steps + [{}]*tick; bad.write_text(json.dumps(ordinary))
            row = state_rows(run('--check-world-replay',FIELD,ART,bad))[-1]
            assert row['battle_pending_actor'] is None and row['battle_ticks']==tick
            assert row['draws']==21+int(tick>=79)
            expected = copy.deepcopy(ordinary['checkpoint']['party'])
            if tick>=79:expected[0]['hp']-=27
            assert row['party']==expected
            if tick<134:
                action=row['battle_action'];assert action['target']==0 and not action['projectile']
                assert action['damage_at_impact'] and not action['critical'] and action['returning']==(tick>=99)
            else:assert row['battle_action'] is None
            for key in ('money','runes','storage','reserves','formation','random'):
                assert row[key]==ordinary['checkpoint'][key],key
        protected = copy.deepcopy(ordinary);protected['checkpoint']['party'][0]['hp']=24
        for tick in (1,78,79,124,125,134,135):
            protected['steps']=attack_steps+[{}]*tick;bad.write_text(json.dumps(protected))
            row=state_rows(run('--check-world-replay',FIELD,ART,bad))[-1]
            assert row['party'][0]['hp']==24 and row['party'][1]['hp']==(73 if tick>=79 else 100)
            assert row['battle_ticks']==tick and row['draws']==21+int(tick>=79)
            if tick<135:
                action=row['battle_action'];assert action['target']==0 and action['protector']==1
                assert action['protector_released']==(tick>=124) and action['ward_returning']==(tick>=125)
            else:assert row['battle_action'] is None
        lethal=copy.deepcopy(protected);lethal['checkpoint']['party'][1]['hp']=20
        for tick in (78,79,123,124,125,134,135):
            lethal['steps']=attack_steps+[{}]*tick;bad.write_text(json.dumps(lethal))
            row=state_rows(run('--check-world-replay',FIELD,ART,bad))[-1]
            assert row['party'][0]['hp']==24 and row['party'][1]['hp']==(0 if tick>=79 else 20)
            assert row['party'][1]['status']==('unconscious' if tick>=79 else 'healthy')
            assert row['draws']==21+int(tick>=79)
            if tick<135:
                action=row['battle_action'];assert action['protector']==1 and action['protector_down']==(tick>=124)
                assert action['protector_released']==(tick>=124) and action['ward_returning']==(tick>=125)
            else:assert row['battle_action'] is None
        # Gremio has no present relationship protector: low HP must not blanket-refuse.
        unprotected = copy.deepcopy(projectile)
        unprotected['checkpoint']['party'][1]['hp']=24
        unprotected['draws']=[0,4*(32767//8)]+[0]*12+[0,0,32767,99,100]
        unprotected['steps']=attack_steps+[{}]*78;bad.write_text(json.dumps(unprotected))
        row=state_rows(run('--check-world-replay',FIELD,ART,bad))[-1]
        assert row['battle_ticks']==79 and row['battle_action']['target']==1
        assert row['party'][1]['hp']==0 and row['draws']==19
        # Existing attack commands clear the three front enemies before the Commander gets its turn.
        commander=copy.deepcopy(projectile)
        for stats in commander['checkpoint']['stats'][:3]:stats.update(attack=500,skill=9999,speed=9999)
        commander['draws']=[0,0]+[32767]*200
        commands=[]
        for index in range(3):
            commands.append({'buttons':{'confirm':True}})
            commands.extend([{'buttons':{'navigation':'right'}}]*index)
            commands.append({'buttons':{'confirm':True}})
        for index in range(3,6):
            position=projectile['checkpoint']['formation'][index]
            position=ord(position) if isinstance(position,str) else position
            if not (position>=3 and profiles[projectile['checkpoint']['party'][index]['id']]['weapon_range']=='short'):commands.append({'buttons':{'navigation':'down'}})
            commands.append({'buttons':{'confirm':True}})
        commander_start=steps[:90]+[{}, {'buttons':{'confirm':True}}]+commands+[{'buttons':{'confirm':True}},{}]
        elapsed=sum(profiles[member['id']]['motion']['duration']+1 for member in commander['checkpoint']['party'][:3])
        selected_draws=None
        for tick in (1,24,84,85,101,119,120,129,130):
            commander['steps']=commander_start+[{}]*(elapsed+tick-1);bad.write_text(json.dumps(commander))
            row=state_rows(run('--check-world-replay',FIELD,ART,bad))[-1]
            assert row['mode']=='battle' and row['battle_phase']=='resolving' and row['battle_ticks']==tick,(tick,row['battle_phase'],row['battle_ticks'],row['battle_action'])
            if selected_draws is None:selected_draws=row['draws']
            assert row['draws']==selected_draws+int(tick>=120)
            assert row['party']==commander['checkpoint']['party']
            assert row['battle_asleep'][0]==int(tick>=120) and not any(row['battle_asleep'][1:])
            if tick<130:
                action=row['battle_action'];assert action['kind']=='status_attack' and action['actor']==9 and action['target']==0
                assert action['auxiliary_alive']==(24<=tick<85) and action['target_reacting']==(tick>=85) and action['owner_released']==(tick>=101)
            else:assert row['battle_action'] is None
        # Two normal kills leave one Squirrel for the rear Commander's overlapping order.
        order=copy.deepcopy(projectile);order['draws']=[0,0]+[32767]*200
        for stats in order['checkpoint']['stats'][:2]:stats.update(attack=500,skill=9999,speed=9999)
        commands=[]
        for index in range(2):
            commands.append({'buttons':{'confirm':True}});commands.extend([{'buttons':{'navigation':'right'}}]*index);commands.append({'buttons':{'confirm':True}})
        for index in range(2,6):
            position=order['checkpoint']['formation'][index];position=ord(position) if isinstance(position,str) else position
            if not (position>=3 and profiles[order['checkpoint']['party'][index]['id']]['weapon_range']=='short'):commands.append({'buttons':{'navigation':'down'}})
            commands.append({'buttons':{'confirm':True}})
        order_start=steps[:90]+[{}, {'buttons':{'confirm':True}}]+commands+[{'buttons':{'confirm':True}},{}]
        elapsed=sum(profiles[member['id']]['motion']['duration']+1 for member in order['checkpoint']['party'][:2])
        cases=json.loads((ROOT/'game/tests/fixtures/world_commander_dispatch.json').read_text())
        reference=next(case for case in cases if case['mode']=='normal' and case['draws'][0]['value']==32767)
        selected_draws=None
        for tick in (1,12,71,72,117,119,142,143,144,147,150,153,154,156,157,199,200):
            order['steps']=order_start+[{}]*(elapsed+tick-1);bad.write_text(json.dumps(order))
            row=state_rows(run('--check-world-replay',FIELD,ART,bad))[-1]
            assert row['mode']=='battle' and row['battle_phase']=='resolving' and row['battle_ticks']==tick,(tick,row['battle_phase'],row['battle_ticks'],row['battle_action'])
            if selected_draws is None:selected_draws=row['draws']
            sample=reference['samples'][tick-1]
            assert row['draws']==selected_draws+sample['draws']
            coordinator=row['battle_coordinator']
            assert {key:coordinator[key] for key in sample['coordinator']}==sample['coordinator'],(tick,coordinator,sample)
            assert coordinator['elapsed']==tick and coordinator['dispatch_count']==sample['dispatch_count'] and coordinator['last_dispatched']==sample['last_dispatched']
            expected=copy.deepcopy(order['checkpoint']['party'])
            expected[2]['hp']=sample['hp']
            assert row['party']==expected
            assert row['battle_accuracy_reduced'][2]==(tick>=119) and not any(row['battle_accuracy_reduced'][:2]+row['battle_accuracy_reduced'][3:])
            if tick<199:
                action=row['battle_action'];child=action['ordered'];assert action['kind']=='group_order' and action['actor']==9 and child['actor']==8 and action['target']==2
                assert child['started']==(tick>=12) and child['returning']==(tick>=118) and child['target_released']==(tick>=153)
                assert action['owner_released']==(tick>=142) and action['target_reacting']==(117<=tick<153)
            else:assert row['battle_action'] is None
        progress_checks(root,bad,row,tuple(len(order['steps'])-200+tick for tick in (72,144,199)))
        # Gremio's existing Double-beat setup leaves Hero's attack queued at a defeated target.
        overlap=copy.deepcopy(projectile);overlap['draws']=[0,0]+[32767]*400
        overlap['checkpoint']['stats'][0].update(attack=50,skill=9999,luck=0,speed=2)
        overlap['checkpoint']['stats'][1].update(attack=500,skill=9999,speed=9999)
        rules=json.loads((FIELD/'battle/trial.json').read_text())['systems']
        overlap['checkpoint']['runes'][1]=next(i for i,rune in enumerate(rules['runes']) if rune['id']=='double-beat')
        commands=[{'buttons':{'confirm':True}},{'buttons':{'confirm':True}}]*2
        for index in range(2,6):
            position=overlap['checkpoint']['formation'][index];position=ord(position) if isinstance(position,str) else position
            if not (position>=3 and profiles[overlap['checkpoint']['party'][index]['id']]['weapon_range']=='short'):commands.append({'buttons':{'navigation':'down'}})
            commands.append({'buttons':{'confirm':True}})
        overlap_start=steps[:90]+[{}, {'buttons':{'confirm':True}}]+commands+[{'buttons':{'confirm':True}},{}]
        motion=profiles['gremio']['motion'];elapsed=motion['ready_tick']+motion['duration']+1
        reference=next(case for case in json.loads((ROOT/'game/tests/fixtures/world_party_overlap.json').read_text()) if case['mode']=='routed')
        selected_draws=None;overlap_path=root/'overlap.json'
        for tick in (1,72,144,153,199,200,203,212,213,271,272,296,308,328,329):
            overlap['steps']=overlap_start+[{}]*(elapsed+tick-1);overlap_path.write_text(json.dumps(overlap))
            row=state_rows(run('--check-world-replay',FIELD,ART,overlap_path))[-1]
            assert row['battle_ticks']==tick and row['battle_phase']=='resolving',(tick,row['battle_ticks'],row['battle_phase'])
            sample=reference['samples'][tick-1]
            if selected_draws is None:selected_draws=row['draws']
            assert row['draws']==selected_draws+sample['draws']
            assert {key:row['battle_coordinator'][key] for key in sample['coordinator']}==sample['coordinator'],(tick,row['battle_coordinator'],sample)
            assert row['battle_enemy_hp'][:3]==[0,0,sample['victim_hp']]
            expected=copy.deepcopy(overlap['checkpoint']['party']);expected[2]['hp']=sample['hp'];assert row['party']==expected
            strike=row['battle_party_strike']
            if 200<=tick<328:
                assert strike['actor']==0 and strike['target']==8 and strike['ticks']==tick-199
                assert strike['returning']==(tick>=296) and strike['target_released']==(tick>=308)
            else:assert strike is None
        progress_checks(root,overlap_path,row,tuple(len(overlap['steps'])-329+tick for tick in (144,200,272,308)))
        # The same routed Attack can now kill the last Squirrel without ending a live Commander's battle.
        knockout=copy.deepcopy(overlap);knockout['checkpoint']['stats'][0]['attack']=150
        reference=next(case for case in json.loads((ROOT/'game/tests/fixtures/world_party_knockout.json').read_text()) if case['mode']=='routed')
        selected_draws=None;knockout_path=root/'knockout.json'
        for tick in (1,144,199,200,271,272,295,296,307,308,327,328,400,401,402):
            knockout['steps']=overlap_start+[{}]*(elapsed+tick-1);knockout_path.write_text(json.dumps(knockout))
            row=state_rows(run('--check-world-replay',FIELD,ART,knockout_path))[-1]
            assert row['battle_ticks']==tick and row['battle_phase']=='resolving' and row['mode']=='battle'
            sample=reference['samples'][tick-1]
            if selected_draws is None:selected_draws=row['draws']
            assert row['draws']==selected_draws+sample['draws']
            assert {key:row['battle_coordinator'][key] for key in sample['coordinator']}==sample['coordinator']
            assert row['battle_enemy_hp'][:3]==[0,0,sample['victim_hp']] and row['battle_enemy_hp'][3]>0
            assert row['battle_enemy_inactive']==[True,True,sample['victim_down'],False]
            expected=copy.deepcopy(knockout['checkpoint']['party']);expected[2]['hp']=sample['hp'];assert row['party']==expected
            assert row['money']==knockout['checkpoint']['money'] and row['experience']==knockout['checkpoint']['experience']
            strike=row['battle_party_strike']
            if 200<=tick<401:
                assert strike['actor']==0 and strike['target']==8 and strike['ticks']==tick-199
                assert strike['target_down']==(tick>=308) and strike['owner_released']==(tick>=328) and not strike['target_released']
            else:assert strike is None
        progress_checks(root,knockout_path,row,tuple(len(knockout['steps'])-402+tick for tick in (272,308,328,401,402)))
        knockout['steps'].append({});knockout_path.write_text(json.dumps(knockout))
        round_two=state_rows(run('--check-world-replay',FIELD,ART,knockout_path))[-1]
        assert round_two['battle_phase']=='battle_menu' and round_two['battle_round']==2 and round_two['battle_coordinator'] is None
        assert round_two['money']==row['money'] and round_two['experience']==row['experience']
        # Select a critical only at Hero's original critical draw, preserving the routed command setup.
        critical_case=copy.deepcopy(overlap);critical_path=root/'critical.json'
        reference=next(case for case in json.loads((ROOT/'game/tests/fixtures/world_party_critical.json').read_text()) if case['mode']=='routed')
        critical_case['steps']=overlap_start+[{}]*elapsed;critical_path.write_text(json.dumps(critical_case))
        prefix=state_rows(run('--check-world-replay',FIELD,ART,critical_path))[-1];assert prefix['battle_ticks']==1
        selected_draws=prefix['draws'];launch=200
        critical_case['draws'][selected_draws+reference['samples'][launch-2]['draws']+1]=24
        for tick in (1,144,199,200,201,271,272,295,296,297,298,301,304,307,308,327,328,338):
            critical_case['steps']=overlap_start+[{}]*(elapsed+tick-1);critical_path.write_text(json.dumps(critical_case))
            row=state_rows(run('--check-world-replay',FIELD,ART,critical_path))[-1]
            sample=reference['samples'][tick-1]
            assert row['battle_ticks']==tick and row['battle_phase']=='resolving'
            assert row['draws']==selected_draws+sample['draws']
            assert {key:row['battle_coordinator'][key] for key in sample['coordinator']}==sample['coordinator']
            assert row['battle_enemy_hp'][:3]==[0,0,sample['victim_hp']]
            assert row['money']==critical_case['checkpoint']['money'] and row['experience']==critical_case['checkpoint']['experience']
            expected=copy.deepcopy(critical_case['checkpoint']['party']);expected[2]['hp']=sample['hp'];assert row['party']==expected
            strike=row['battle_party_strike']
            if 200<=tick<328:
                assert strike['critical'] and strike['actor']==0 and strike['target']==8 and strike['ticks']==tick-199
                assert strike['returning']==(tick>=296) and strike['target_released']==(tick>=308)
            else:assert strike is None
        progress_checks(root,critical_path,row,tuple(len(critical_case['steps'])-338+tick for tick in (200,201,272,296,308,328)))
        # With no living front row, the ordinary decision skips immediately without a fake animation.
        skipped = copy.deepcopy(projectile)
        for member in skipped['checkpoint']['party'][:3]:member.update(hp=0,status='unconscious')
        skipped_defends=[]
        for index in range(3,6):
            if index!=3:skipped_defends.append({'buttons':{'navigation':'down'}})
            skipped_defends.append({'buttons':{'confirm':True}})
        skipped['steps'] = steps[:90]+[{}, {'buttons':{'confirm':True}}]+skipped_defends+[{'buttons':{'confirm':True}},{}]
        skipped['draws'] = [0,4*(32767//8)]+[0]*10;bad.write_text(json.dumps(skipped))
        row=state_rows(run('--check-world-replay',FIELD,ART,bad))[-1]
        assert row['battle_phase']=='resolving' and row['battle_action'] is None and row['battle_pending_actor'] is None
        assert row['draws']==12 and row['party']==skipped['checkpoint']['party']
        # Exercise the live world root against the same owned party, with motion suspended.
        live = copy.deepcopy(packet); live['draws'] = []
        live['checkpoint']['party'][0]['hp'] = 1
        live_steps = ([{'buttons': {'direction': 'down'}}, {'buttons': {'menu': True}}]
                      + [{'buttons': {'confirm': True}}]*4 + [{}]*10
                      + [{'buttons': {'menu': True}}, {}])
        live_states = []
        for count in (2, 16, 18):
            live['steps'] = live_steps[:count]; bad.write_text(json.dumps(live))
            live_states.append(state_rows(run('--check-world-replay', FIELD, ART, bad))[-1])
        opened, used, resumed = live_states
        assert opened['world_menu'] and used['world_menu'] and not resumed['world_menu']
        assert opened['remaining'] == 14 and resumed['remaining'] == 13
        for key in ('camera', 'remaining', 'visual_counter', 'water', 'travel_counter', 'draws'):
            assert opened[key] == used[key], key
        assert used['party'][0]['hp'] == used['party'][0]['max_hp']
        assert used['party'][0]['inventory']['slots'][0]['uses'] == opened['party'][0]['inventory']['slots'][0]['uses'] - 1
        for key in ('formation', 'loadouts', 'runes', 'levels', 'money', 'reserves', 'storage', 'random'):
            assert opened[key] == used[key] == resumed[key], key
        assert used['party'] == resumed['party']
        assert path.read_bytes() == original
        assert before == {p.relative_to(isolated): p.read_bytes() for p in isolated.rglob('*') if p.is_file()}
        if write_candidate:
            output = ROOT / 'kit/work/build/world-travel-replay'; output.mkdir(exist_ok=True)
            (output/'replay.json').write_bytes(original)
            receipt = dict(schema='suikoden-world-replay-review/1', status='candidate',
                           origin='Isolated existing prototype persistence harness; explicitly diagnostic ownership, levels and source village-exit position.',
                           executable_sha256=hashlib.sha256(EXE.read_bytes()).hexdigest(),
                           replay_sha256=hashlib.sha256(original).hexdigest(),
                           field_manifest_sha256=hashlib.sha256((FIELD/'manifest.json').read_bytes()).hexdigest(),
                           world_provenance_sha256=hashlib.sha256((ART/'provenance.json').read_bytes()).hexdigest(),
                           headless_processes_agree=True, steps=len(steps), draws=2,
                           service_steps=len(services['steps']), services_checked=['item_shop', 'blacksmith'],
                           replay_progress_points=12, progress_backup_checked=True, future_progress_protected=True,
                           progress_packaged_restart_checked=True, live_world_menu_checked=True, all_eight_rosters_released=True, rabbit_projectile_checked=True, rabbit_ordinary_checked=True, settled_protection_checked=True, nonlethal_interception_checked=True, lethal_interception_checked=True, commander_solo_status_checked=True, commander_single_squirrel_order_checked=True, commander_coordinator_checked=True, commander_coordinator_restart_points=3, hero_attack_lock_retry_checked=True, hero_attack_restart_points=4, hero_attack_knockout_checked=True, hero_attack_knockout_restart_points=5, hero_critical_checked=True, hero_critical_restart_points=6, roc_loop_checked=True, roc_loop_steps=roc_steps, roc_loop_restart_points=6, roc_presentation_checked=True, roc_presentation_restart_points=6, roc_presentation_packaged_checked=True, roc_media_progress_binding_checked=True, roc_defeat_checked=True, roc_defeat_steps=defeat_steps, roc_defeat_restart_points=6, roc_defeat_packaged_checked=True, roc_cover_checked=True, roc_cover_steps=cover_steps, roc_cover_restart_points=6, roc_cover_packaged_checked=True, roc_cover_knockout_checked=True, roc_cover_knockout_steps=cover_ko_steps, roc_cover_knockout_restart_points=6, roc_cover_knockout_packaged_checked=True, world_recovery_checked=True, world_recovery_steps=recovery_steps, world_recovery_restart_points=6, world_recovery_packaged_checked=True, inn_cost=600, resupply_cost=100, medicine_party_checked=True, medicine_party_cases=2, medicine_party_steps=party_medicine_steps, medicine_party_restart_points=12, medicine_party_packaged_checked=True, medicine_checked=True, medicine_steps=medicine_steps, medicine_restart_points=8, medicine_packaged_checked=True, roc_long_battle_checked=True, roc_long_battle_steps=long_steps, roc_long_battle_restart_points=10, roc_long_battle_packaged_checked=True, roc_two_rounds_checked=True, roc_two_rounds_steps=rounds_steps, roc_two_rounds_restart_points=8, roc_two_rounds_packaged_checked=True, battle_art_sha256=hashlib.sha256((battle_art/'scene.json').read_bytes()).hexdigest(),
                           native_launched=False, media_accepted=False, promoted=False)
            (output/'receipt.json').write_text(json.dumps(receipt, indent=2)+'\n')
        print(f'PASS:one Roc survives the first round at48HP and continues through source reset/camera draw/30-update wait to one final victory across {rounds_steps} normal inputs; HP/charges/inventory, eight restores/copied process and world return agree.')
        print(f'PASS:sustainable loop across {recovery_steps} normal inputs carries four-victory KO to VB6, cancels without mutation, pays600 for source recovery/charge refill, buys one100-bit Medicine, re-enters for a fifth exact victory and returns; six restores/copied process agree.')
        print(f'PASS:four Roc victories across {cover_ko_steps} normal inputs carry Gremio100/58/16/0HP, preserve Hero16HP, skip inactive Gremio EXP, grant four exact rewards and return without revival; six restores/copied process agree.')
        print(f'PASS:two Roc victories across {cover_steps} normal inputs preserve16HP, Gremio cover redirects42damage with source62/73 releases, two exact rewards and six more restores/copied process agree.')
        print(f'PASS:two Roc encounters across {defeat_steps} normal inputs preserve16HP and first-victory ownership, then terminal ordinary defeat without rewards/retry/world return; six restores and a copied process agree.')
        print(f'PASS:single source Roc loop covers {roc_steps} normal-input updates, attack/reaction/death locks, exactly-once money/EXP/Feather, world return and six prefix restores.')
        print(f'PASS:2 isolated native processes agree through {len(steps)} supplied updates, source village/world transitions and actual Let go; all supplied ownership retained.')
        print(f'PASS:{len(services["steps"])} routed field updates visit the item shop and blacksmith, buy Medicine, sharpen once and return with exact ownership/costs and no RNG draws.')
        print('PASS:12 separate-process prefix restores preserve full simulation hashes across movement, callbacks, battle and service menus; backup recovery, failed writes, future-version and source binding checks pass.')
        print('PASS:Rabbit ordinary retry preserves the actor/priority draws, forces the source hit after its accuracy roll, impacts79/returns99/finishes134, and skips an empty front row; unprotected low-HP Gremio takes damage, Gremio intercepts for low-HP Hero with lock release124/ward return125/completion135; lethal interception reaches0HP at79, clears its hurt lock and takes the down pose124, and completes both returns135 without extra RNG.')
        print('PASS:normal attack commands remove three front enemies, then Commander runs its solo status action: auxiliary24/85, hurt85, owner101, sleep roll120 and target completion130; no HP or inventory damage.')
        print('PASS:two normal kills leave one ordered Squirrel: launch12, damage117, return118, accuracy-reduction check119, owner release142, target153 and ally199; Defend dispatch144/147/150/156 overlaps the return, original cache/completion/lock gates and exact RNG costs agree, round ready200; three separate-process restores retain full coordinator state.')
        print('PASS:queued Hero Attack retargets after Gremio Double-beat kills, waits through Squirrel return199 without attack RNG, starts200, impacts272, returns296 and releases328; round ready329 and four separate-process restores agree.')
        print('PASS:Hero kills the routed Squirrel at272, inactive/death starts308, Hero releases328, death releases401 and round is ready402; the living Commander keeps battle active with no premature XP/money, five restores and round2 handoff pass.')
        print('PASS:Hero critical starts200, applies source triple physical damage272, signals completion296 before owner release328, permits Defend298/301/304/307 and reaches round338; exact RNG and six restores agree.')
        print('PASS:Rabbit projectile targets the fifth member, applies one defended damage roll on update64, releases its auxiliary on94 and completes on117; ownership/costs stay exact.')
        print('PASS:all eight B encounter formations reach Let go and return without executing an unsupported enemy action.')
        print('PASS:live world Item menu consumes one Medicine use in shared ownership, freezes travel/visual/RNG state and resumes interpolation; prototype service/save commands stay hidden.')
        print('PASS:future schema, invalid entry and exhausted draws fail before window startup; replay and isolated saves remain unchanged. No graphics/audio device.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Run headless world travel and battle replay checks.')
    parser.add_argument('--write-candidate', action='store_true',
                        help='Run the retained prototype recipe for an earlier replay executable.')
    if parser.parse_args().write_candidate:
        verify(write_candidate=True)
    else:
        subprocess.run(['make', 'build', 'ZIG_BUILD_ARGS=-Doptimize=ReleaseSafe test-world --summary all'],
                       cwd=ROOT, check=True)

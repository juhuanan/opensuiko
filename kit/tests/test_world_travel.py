"""Compare Region B travel and battle exports with static source records."""
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))

import export_world_travel as export
from export_first_room import source
from test_worldmap_points import check as check_world_points


def verify_battle_export(travel):
    document=export.battle_export()
    assert document==json.loads((ROOT/'game/assets/world_b_battle.json').read_text())
    # Independent byte arithmetic, not the producer's struct/pointer helpers.
    import item_tables
    import preparation
    raw,_=source('/B_DATA.BIN')
    u=lambda off:int.from_bytes(raw[off:off+4],'little')
    p=lambda off:u(off)-0x80080000
    directory=p(p(p(0)+12));table=p(directory+12);selectors=p(directory+8)
    supported=[]
    for index in range(1,9):
        descriptor=p(selectors+4*index)
        ids=[raw[descriptor+4+slot] for slot in range(6) if raw[descriptor+4+slot]]
        if all(u(p(table+4*native)+48)==0x8008006C for native in ids):supported.append(index)
    assert supported==[2,3,4,6]
    assert export.export()[1]['battle_overlay']['supported_encounters']==supported
    names={row['id']:preparation.stable_id(row['name']) for row in item_tables.items()}
    for native in range(1,5):
        offset=p(table+4*native)
        name=export.war_text.decode(raw[offset:offset+16],length=16)[0]
        profile=next(row for row in document['enemies'] if row['name']==name)
        assert profile['level']==raw[offset+16]
        actual=[int.from_bytes(raw[offset+n:offset+n+2],'little') for n in range(18,32,2)]
        assert [profile['max_hp']]+[profile['stats'][k] for k in ('attack','skill','defense','speed','magic','luck')]==actual
        supported = profile['id'] in ('flying_squirrel','roc')
        assert profile['action_policy'] == ('roc' if profile['id']=='roc' else 'attack' if supported else 'rabbit' if profile['id']=='killer_rabbit' else 'commander')
        if supported:assert u(offset+48)==0x8008006C
        if profile['id']=='killer_rabbit':
            assert int.from_bytes(raw[offset+38:offset+40],'little')==12
            assert profile['unavoidable_attack'] and profile['dodges_attacks']
        reward=int.from_bytes(raw[offset+52:offset+54],'little',signed=True)
        expected_money=(abs(reward)//10 * (-1 if reward<0 else 1))*100 if reward&1 else reward
        assert profile['money']==expected_money
        for i,drop in enumerate(profile['drops']):
            item,rate=raw[offset+54+i*2:offset+56+i*2]
            assert drop['item']==(names[item] if item else None) and drop['rate']==rate
    for i,entry in enumerate(document['encounters'],1):
        desc=p(selectors+4*i);positions=p(p(desc+20))
        slots=[s for s in range(6) if raw[desc+4+s]]
        assert entry['source_slots']==slots
        assert entry['enemies']==[v for v in travel['encounters'][i-1]['enemies'] if v]
        for index,slot in enumerate(slots):
            xyz=[int.from_bytes(raw[positions+slot*6+k:positions+slot*6+k+2],'little',signed=True) for k in (0,2,4)]
            xyz[0]-=128
            stats=p(table+4*raw[desc+4+slot])
            if int.from_bytes(raw[stats+38:stats+40],'little')&32:xyz[2]-=10
            assert list(entry['positions'][index].values())==xyz
    # Escape source contracts live in test_battle_exit.py; native demo_batch tests own the decisions.
    # Check the entire selector statically; native gates own decision execution.
    from test_enemy_policies import verify_front_selector
    verify_front_selector(raw, 0x6c)


def check():
    travel, proof = export.export()
    assert travel == json.loads((ROOT / 'game/assets/world_b.json').read_text())
    assert proof == json.loads((ROOT / 'kit/data/reports/world_travel.json').read_text())
    verify_battle_export(travel)
    check_world_points()
    print('PASS: Region B source travel, four enemy profiles, eight encounter rosters and static front selector')


if __name__ == '__main__':
    check()

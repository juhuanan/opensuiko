"""Check retained C party-command overlap and retargeting traces."""
from collections import defaultdict
from pathlib import Path
import json
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))

def party_case(targets=(0, 1), attack=180, remaining_attack=False, miss=False, commands=None):
    from test_battle_picker import SCENE
    from test_world_region_c import archer_case
    import legacy_instruction_fixture as instructions

    original = instructions.call
    configured = False
    tick = 0
    events, acted = [], []
    initial_stats = []

    def drive(machine, pc, *args):
        nonlocal configured, tick
        if pc == 0x800DE0B0:
            tick += 1
            if not configured:
                memory = machine.mem
                for member, target in enumerate(targets):
                    slot = SCENE + 0xB40 + 84 * (member + 1)
                    memory.sb(slot + 0x47, 0)
                    memory.sb(slot + 0x49, 7 + target)
                    for offset, value in ((0x30, attack), (0x26, 255), (0x2A, 24), (0x2E, 0)):
                        memory.sh(slot + offset, value)
                if remaining_attack:
                    for member in (2, 4, 5):
                        slot = SCENE + 0xB40 + 84 * (member + 1)
                        memory.sb(slot + 0x47, 0)
                        memory.sb(slot + 0x49, 7)
                        for offset, value in ((0x30, attack), (0x26, 255), (0x2A, 24), (0x2E, 0)):
                            memory.sh(slot + offset, value)
                if commands is not None:
                    assert len(commands) == 6
                    for member, target in enumerate(commands):
                        slot = SCENE + 0xB40 + 84 * (member + 1)
                        memory.sb(slot + 0x47, 1 if target is None else 0)
                        if target is not None:
                            memory.sb(slot + 0x49, 7 + target)
                for member in range(6):
                    slot = SCENE + 0xB40 + 84 * (member + 1)
                    initial_stats.append({name: memory.rh(slot + offset) for name, offset in (
                        ('attack', 0x30), ('defense', 0x32), ('skill', 0x26),
                        ('speed', 0x2A), ('magic', 0x2C), ('luck', 0x2E))})
                word = machine.word

                def observe(address):
                    if address == 0x800F835C:
                        events.append(dict(tick=tick, kind='command', actor=machine.r[4] - 1))
                    if address == 0x800F7E90:
                        events.append(dict(tick=tick, kind='physical', actor=machine.r[4] - 1, target=machine.r[5] - 1))
                    return word(address)

                machine.word = observe
                configured = True
        result = original(machine, pc, *args)
        if pc == 0x800DE0B0:
            acted.append([bool(machine.mem.rb(SCENE + 0xB40 + 84 * (member + 1) + 0x46)) for member in range(6)])
        return result

    instructions.call = drive
    try:
        context = {}
        result = archer_case(True, True, continuation=context, presentation=True,
                             initial_hp=[300, 300, 100, 100, 100, 100], miss=miss)
    finally:
        instructions.call = original
    assert len(acted) == len(result['rows']) and configured
    assert context['machine'].mem.rw(0x8017DA94) == 0x800F74A8
    for row, flags in zip(result['rows'], acted):
        row['party_acted'] = flags
        row['party_impacts'] = [dict(actor=event['actor'], target=event['target']) for event in events
                                if event['tick'] == row['tick'] and event['kind'] == 'physical' and event['actor'] < 6]
    result.update(schema='suikoden-c-party-actions-source/1',
                  conditions='C formation1; first archer selected; Hero/Gremio300HP/40DEF, other four100HP/40DEF; supplied commands/stats; enemy accuracy99 when misses requested, other draws51; not canonical startup',
                  initial_stats=initial_stats, initial_max_hp=[300, 300, 100, 100, 100, 100],
                  commands=([dict(actor=member, target=target) for member, target in enumerate(commands) if target is not None]
                            if commands is not None else [dict(actor=member, target=target) for member, target in enumerate(targets)] +
                           ([dict(actor=member, target=0) for member in (2, 4, 5)] if remaining_attack else [])),
                  source_events=events)
    return result


def check():
    cases = {}
    for name, targets, attack, remaining, miss, updates, draws, hp in (
            ('distinct', (0, 1), 180, False, False, 319, 30, [0, 0]),
            ('same', (0, 0), 180, False, False, 421, 30, [0, 0]),
            ('same_nonlethal', (0, 0), 60, False, False, 347, 30, [86, 120]),
            ('all_commands', (0, 1), 180, True, False, 426, 37, [0, 0]),
            ('all_nonlethal', (0, 1), 60, True, False, 577, 46, [52, 103]),
            ('distinct_misses', (0, 1), 180, False, True, 319, 28, [0, 0])):
        case = json.loads((ROOT / f'game/tests/fixtures/world_c_party_{name}.json').read_text())
        assert (len(case['rows']), len(case['draws']), case['rows'][-1]['enemy_hp']) == (updates, draws, hp)
        commands = dict(enumerate(targets))
        if remaining:
            commands.update(dict.fromkeys((2, 4, 5), 0))
        assert case['commands'] == [dict(actor=actor, target=target) for actor, target in commands.items()]
        assert all(case['initial_stats'][actor]['attack'] == attack for actor in commands)
        assert any(value == 99 for _, value in case['draws']) == miss
        dispatched = set()
        impacts = defaultdict(list)
        last_tick = 0
        for event in case['source_events']:
            tick, actor = event['tick'], event['actor']
            assert 1 <= tick <= updates and tick >= last_tick
            last_tick = tick
            if event['kind'] == 'command':
                assert actor in commands and actor not in dispatched
                dispatched.add(actor)
            else:
                assert event['kind'] == 'physical'
                if actor < 6:
                    assert actor in dispatched and event['target'] in (6, 7)
                    impacts[tick].append(dict(actor=actor, target=event['target']))
        for tick, row in enumerate(case['rows'], 1):
            assert row['tick'] == tick and row['party_impacts'] == impacts.get(tick, [])
        cases[name] = case
    impacts = cases['distinct_misses']['rows'][188]['party_impacts']
    assert impacts == [dict(actor=0, target=6), dict(actor=1, target=7)]
    return cases


if __name__ == '__main__':
    cases = check()
    print(f"PASS: {len(cases)} retained ordinary-party traces, with command order, retargeting and simultaneous impacts")

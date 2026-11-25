#!/usr/bin/env python3
"""Inventory source loader coverage separately from the authored runtime episode."""
import argparse
import hashlib
import json
import re
import struct
from collections import Counter, defaultdict
from pathlib import Path

from event_script_reachability import build as script_graph, loader_source_census
from field_encounter_inventory import inventory as field_encounters
from export_journey import ROOMS as JOURNEY_ROOMS
from export_first_room import ROOM_IDS
from room_battle_package import room_battle_requests
import canonical_start
ROOMS = ROOM_IDS | JOURNEY_ROOMS

ROOT = Path(__file__).resolve().parents[2]
DEFAULT = ROOT / "kit/data/reports/campaign_coverage.json"
ENCOUNTER_CALLBACKS = ('round_callback', 'command_setup_callback', 'initialization_callback', 'teardown_callback')



def next_world_connection():
    """The existing forest's opposite world edge, separate from runtime coverage."""
    import maindec
    import area_scene
    from export_first_room import source
    data,origin=source('/VB6.BIN')
    entity=area_scene.entities(data,area_scene.room_record(data,6))[1]
    predicate,stream=entity['stream_offsets'][1:]
    assert data[predicate:predicate+4]==bytes.fromhex('0b2d2d06')
    assert data[stream:stream+6]==bytes.fromhex('03fb023b26fd')
    region,index=2,6
    table=maindec.mword(0x80170064+4*region)
    entry=maindec.body()[table-maindec.MBASE+14*index:][:14]
    assert entry[:2]==bytes((0,6))
    x,y=struct.unpack_from('<2H',entry,2)
    descriptor=maindec.mword(maindec.mword(0x8016F67C+4*region)+4*index)
    assert (maindec.mword(descriptor),maindec.mword(descriptor+4))==(origin['size'],origin['lba'])
    return dict(id='kobold_forest_region_c',runtime_state='active; explicit B/forest/C travel, source return point, active-region direct saves and fresh-process C continuation pass; C formation1 shared eligible-party ordinary commands and hit/miss/Gremio-knockout/low-HP continuation/rewards/return/restart pass with candidate presentation; broader C combat and media acceptance remain unfinished',
        source=origin,field_room='vb6_kobold_village',source_room=6,source_entity=1,
        source_predicate_offset=predicate,source_exit_offset=stream,
        exit=dict(region='region_c',camera_cells=dict(x=data[stream+3],y=data[stream+4])),
        return_entrance=dict(id='region_c_kobold_village',source_point=index,source_table=hex(table),source_descriptor=hex(descriptor),camera_cells=dict(x=x,y=y),field_room='vb6_kobold_village',spawn_pixels=dict(x=entry[6]*8,y=entry[7]*8)),
        next_required=['C formation1 ordinary fight and its candidate presentation are checked; direct Gremio KO/formation promotion/XP/persistence is checked; shared five-member ordinary commands are checked; finish other layouts and party rune/item/unite/critical/miss commands, Sacrificial Buddha/protection/low-HP interception','extend the other seven C formations with their own source policies/presentation; preserve unsupported selection boundaries','conditional Kobold population and forest event/battle orchestration','consolidated native visual/input review when requested'],
        evidence=['kit/tests/test_worldmap_points.py kobold_connection_cases','kit/tests/test_world_region_c.py','game/tests/world_session_save.zig B forest C route','kit/tests/test_world_session.py connected_c_restart','game/assets/world_c.json','game/assets/world_art_c.json','kit/tests/test_journey_export.py','game/tests/fixtures/journey_room.json'])



def next_recruitment_event():
    """The existing blacksmith's source candidate; not a player-facing unlock."""
    import area_scene
    from export_first_room import source
    data,origin=source('/VB6.BIN');entity=area_scene.entities(data,area_scene.room_record(data,10))[3]
    predicate,stream=entity['stream_offsets'][1:]
    assert data[predicate:predicate+8]==bytes.fromhex('114614ff01050600')
    assert data[0x35D19:0x35D21]==bytes.fromhex('45464b0046114215')
    from war_text import decode
    from event_script_decode import switch_2f_targets
    import maindec
    root=area_scene.root(data);strings=area_scene.ptr_at(data,root+20);dialogue={}
    for name,group,index in (('introduction',2,1),('choices',2,2),('accepted',2,3),('declined',2,4)):
        table=area_scene.ptr_at(data,strings+4*group);offset=area_scene.ptr_at(data,table+4*index)
        dialogue[name]=dict(source_offset=offset,text=decode(data,offset)[0])
    assert dialogue['choices']['text'].splitlines()==['Recruit',"Don't recruit"]
    branches=switch_2f_targets(data,0x35CF0)
    assert branches=={0:0x35CF3,1:0x35D22}
    cue=struct.unpack_from('<H',maindec.body(),0x80171C2C-maindec.MBASE+150*2)[0]
    assert maindec.mword(0x80141B7C)==0x34420010 and maindec.mword(0x80132CE8)==0x38420010
    return dict(id='maas_blacksmith',character='maas',native_id=70,source=origin,source_room=10,source_entity=3,
        source_predicate_offset=predicate,source_event_offset=stream,
        dialogue_evidence=dialogue,source_choice_targets=branches,join_cue=cue,scene_refresh=dict(source_selector=21,source_flags_offset=0x1B6,mask=16,after_event_completion=True,preserve_position=True),
        eligibility=dict(minimum_recruitment_tier=1,recruit_flags_mask=3,recruit_flags_value=0,interaction_required=True),
        join_growth=dict(level_advances=17,level_cap=99,rng_draws_per_effective_level=7,final_normalization='source spell-charge refill'),
        runtime_state='active; episode dialogue, decline service and atomic owned join/save implemented; canonical tier producer, actor/cue scheduling and world roster integration remain',
        next_required=['canonical progression must establish recruitment tier and castle name; prototype startup remains tier0','source actor/cue scheduling and native review','world roster integration, actual active/reserve selection access and small-party/forced-member rules'],
        evidence=['kit/tests/test_campaign_coverage.py test_maas_candidate_eligibility_retains_recruit_flags_and_tier','kit/tests/test_campaign_coverage.py test_maas_join_growth_uses_original_event_amount_and_preserves_other_records'])


def report():
    census = loader_source_census()
    fixture = ROOT / "game/tests/fixtures"
    room_bytes = (fixture / "journey_room.json").read_bytes()
    rooms = json.loads(room_bytes)["rooms"]
    config = json.loads((fixture / "journey.json").read_text())
    if set(ROOMS.values()) | {"world_a"} != {room["id"] for room in rooms}:
        raise ValueError("episode fixture and source room mapping disagree")
    source = next(row for row in census["overlays"] if row["file"].endswith("/VB6.BIN"))
    by_id = {room["id"]: room for room in rooms}
    return dict(
        schema="suikoden-campaign-coverage/1",
        scope="Inventory of the checked physical mode-2 loader domain and current episode; not a complete campaign-order or event-feasibility proof.",
        source_inventory=census,
        summary=dict(
            physical_loader_slots=len(census["slots"]),
            distinct_loader_overlays=len(census["overlays"]),
            candidate_entity_entries=sum(row["candidate_entries"] for row in census["overlays"]),
            possible_script_sites=sum(row["possible_sites"] for row in census["overlays"]),
            unresolved_frontiers=sum(len(row["frontier"]) for row in census["overlays"]),
            runtime_source_overlays=1,
            runtime_rooms=len(rooms),
            runtime_source_rooms=len(ROOMS),
            runtime_authored_world_rooms=1,
            canonical_chapters_complete=0,
        ),
        runtime_episode=dict(
            status="authored vertical-slice candidate",
            source_file=source["file"], source_lba=source["lba"], source_size=source["size"],
            semantic_room_sha256=hashlib.sha256(room_bytes).hexdigest(),
            rooms=[dict(id=id, source_room=number, title=by_id[id]["title"], state="implemented; media review separate") for number, id in sorted(ROOMS.items())] + [dict(id="world_a", source_room=None, source_file=None, title=by_id["world_a"]["title"], state="authored prototype world surface; canonical progression remains unfinished")],
            encounter_triggers=[dict(id=row["id"], room=row["room"], completion_flag=row["flag"]) for row in config["encounters"]],
            evidence=["game/src/journey.zig", "game/tests/journey.zig", "kit/tests/test_journey_export.py"],
        ),
        canonical_start_evidence=canonical_start.export(),
        next_world_connection=next_world_connection(),
        next_recruitment_event=next_recruitment_event(),
        campaign_progression=dict(
            state="not yet mapped into canonical chapter blocks",
            completed_blocks=[],
            required_evidence=[
                "first feasible story entry and name/movie handoff",
                "mandatory event reachability and chapter entry/exit story predicates",
                "duel, war, world-travel and cinematic handoffs",
                "recruitment windows and optional/ending branches",
                "resolution or explicit containment of script frontiers in required paths",
            ],
        ),
    )


def write(path=DEFAULT, verify=False):
    value = report()
    encoded = json.dumps(value, indent=2) + "\n"
    path = Path(path)
    if verify:
        if not path.is_file() or path.read_text() != encoded:
            raise ValueError("campaign coverage inventory is stale")
    else:
        if (ROOT / "kit/work/accepted").resolve() in (path.resolve(), *path.resolve().parents):
            raise ValueError("knowledge report must not write accepted assets")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(encoded)
    return value


def battle_request_sites(callers, entries):
    filenames = sorted({Path(request['file']).name for request in callers})
    overlays = {overlay['file']: overlay for overlay in script_graph(filenames)['overlays']}
    sites = []
    for request in callers:
        offset = int(request['offset'], 0)
        overlay = overlays[request['file']]
        predecessors = defaultdict(list)
        for node in overlay['nodes']:
            for successor in node['next']:
                predecessors[successor].append(node['offset'])
        reachable = {offset}
        pending = [offset]
        while pending:
            for parent in predecessors[pending.pop()]:
                if parent not in reachable:
                    reachable.add(parent)
                    pending.append(parent)
        roots = [dict(room=root['room'], entity=root['entry'], stream=root['offset'])
                 for root in overlay['entries'] if root['offset'] in reachable]
        root_contexts = {(root['room'], root['stream']) for root in roots}
        graph_entries = [entry['id'] for entry in entries
                         if request['form'] == 'encounter_index'
                         and (entry['room'], entry['stream']) in root_contexts
                         and (entry['source_file'], entry['request_offset'], entry['selector'])
                         == (request['file'], offset, int(request['selector'], 0))]
        sites.append(dict(file=request['file'], offset=request['offset'], mode=request['mode'],
                          form=request['form'], graph_entries=graph_entries, candidate_roots=roots))
    return sites


def boss_sources(outcomes):
    """Resolve boss decisions, knockout slots and encounter-level controls."""
    from area_scene import RAM_BASE
    from export_first_room import source
    from mipsdec import jtarget
    from spell_scene_source import Analysis, Image, field, member
    import maindec

    anchors = {
        0x800DDFB8: 0x3C038017, 0x800DDFBC: 0x2463B680, 0x800DDFC0: 0xAC431258,
        0x800F41E4: 0x8C820030, 0x800F41EC: 0x0040F809, 0x800F41F0: 0x00A02021,
        0x800F426C: 0x8C42000C, 0x800F4280: 0x244245C8,
        0x800F45E0: 0x8C82000C, 0x800F45E8: 0x0040F809, 0x800F45F0: 0x14400009,
        0x800F4600: 0x24423E98, 0x800F4610: 0xAC220000,
        0x800F3EAC: 0x8C621264, 0x800F3EB4: 0x2442FFFF, 0x800F3EB8: 0x1C400047,
        0x800F3EBC: 0xAC621264, 0x800F3EC0: 0x0C03D1A6,
        0x800F3ED4: 0x8C831330, 0x800F3EE0: 0xAC853420, 0x800F3EE4: 0x8C821334,
        0x800DEB44: 0xAC600004, 0x800F708C: 0x8C620004, 0x800F7094: 0x24420001,
        0x800F709C: 0xAC620004, 0x800DECAC: 0x92230000, 0x800DECC0: 0xA2030000,
        0x800DE2FC: 0x0040F809, 0x800DE310: 0x8C540038,
        0x800E0C7C: 0x86620012, 0x800E0C8C: 0x92020005, 0x800E0C9C: 0x0C038B6B,
        0x800E2DF4: 0xA0620045, 0x800E2E58: 0xAC82002C,
        0x800F7510: 0x90620045, 0x800F7558: 0x10400005,
    }
    imports = {0: (0x80147E38, 'random'), 4: (0x800E3820, 'actor_script'),
               0x124: (0x80147D78, 'debug_print')}
    if any(maindec.mword(pc) != word for pc, word in anchors.items()) or any(
        maindec.mword(0x8016B680 + slot) != address for slot, (address, _) in imports.items()
    ):
        raise ValueError('boss action scheduler or renderer table changed')

    scene = ('argument', 'scene')
    registers = [None] * 32
    registers[0], registers[4], registers[29] = 0, scene, ('stack',)
    initial = tuple(registers)
    renderer = member(scene, 0x1258)

    sources = {}
    images = {}
    for encounter in outcomes['battles']:
        for boss_id in encounter['boss_ids']:
            path = encounter['source']
            if sources.setdefault(boss_id, path) != path:
                raise ValueError(f'boss record spans multiple overlays: {boss_id}')
            if path not in images:
                raw, origin = source(path)
                if (origin['lba'], origin['size'], origin['sha256']) != (
                    encounter['source_lba'], encounter['source_size'], encounter['source_sha256']
                ):
                    raise ValueError(f'boss overlay provenance changed: {path}')
                images[path] = Image(raw, RAM_BASE)

    traces, knockouts = {}, {}
    for boss in outcomes['bosses']:
        path = sources[boss['id']]
        image = images[path]
        record = int(boss['record_va'], 0)
        entry = int(boss['callback'], 0)
        if (image.word(record + 0x24) >> 16, image.word(record + 0x28), image.word(record + 0x30)) != (
            boss['feature_mask'], int(boss['actor_script'], 0), entry
        ):
            raise ValueError(f'boss record provenance changed: {boss["id"]}')
        knockouts[boss['id']] = boss_knockout(image, int(boss['actor_script'], 0))
        trace = traces.setdefault((path, entry), dict(source=path, entry=hex(entry), boss_ids=[], actions=[]))
        trace['boss_ids'].append(boss['id'])
        if trace['actions']:
            continue
        if (image.word(entry), image.word(entry + 4)) != (0x27BDFFD0, 0xAFBF002C):
            raise ValueError(f'boss callback prologue changed: {path}:{entry:#x}')

        pending = [entry]
        visited = {entry}
        for address in pending:
            analysis = Analysis(image, address, initial=initial)
            branches = analysis.events('branch')
            tails = [target for _, event in branches for target in event[-2:]]
            tails.extend(jtarget(pc, word) for pc in analysis.records if (word := image.word(pc)) >> 26 == 2)
            returns = analysis.events('indirect')
            if any(not address <= target < analysis.end for target in tails) or [pc for pc, _ in returns] != [analysis.end - 8]:
                raise ValueError(f'unresolved boss callback control flow: {path}:{address:#x}')
            action = dict(entry=hex(address), end_exclusive=hex(analysis.end), branches=len(branches),
                          calls=[], continuations=[], action_delays=[])
            for pc, (_, target, arguments) in analysis.events('call'):
                slot = field(target, renderer)
                if slot not in imports:
                    raise ValueError(f'unresolved boss renderer call: {path}:{pc:#x}')
                destination, kind = imports[slot]
                call = dict(site=hex(pc), renderer_slot=hex(slot), target=hex(destination), kind=kind)
                if kind == 'actor_script':
                    if not isinstance(arguments[2], int):
                        raise ValueError(f'unresolved boss action descriptor: {path}:{pc:#x}')
                    call['descriptor'] = hex(arguments[2] & 0xffffffff)
                action['calls'].append(call)
            for pc, (_, destination, value) in analysis.events('store'):
                offset = field(destination, scene)
                if offset == 0x0C:
                    if not isinstance(value, int):
                        raise ValueError(f'unresolved boss action continuation: {path}:{pc:#x}')
                    target = value & 0xffffffff
                    action['continuations'].append(dict(site=hex(pc), target=hex(target)))
                    if target not in visited:
                        pending.append(target)
                        visited.add(target)
                elif offset == 0x1264:
                    if not isinstance(value, int):
                        raise ValueError(f'unresolved boss action delay: {path}:{pc:#x}')
                    action['action_delays'].append(dict(site=hex(pc), updates=value))
            trace['actions'].append(action)
    finishes = {}
    for battle in outcomes['battles']:
        if battle['boss_ids']:
            image = images[battle['source']]
            finishes[battle['id']] = [boss_encounter_finish(image, int(row['encounter_va'], 0))
                                      for row in battle['encounters']]
    return list(traces.values()), knockouts, finishes


def boss_knockout(image, table):
    """Read the ordinary knockout slot and follow a replacement table when present."""
    import maindec

    expected = 'a70d4a1637045d39c0f6da75a68a0611cc0ab1de2ac8aaa612233a1ff6373608'
    if (maindec.mword(0x800E2E1C) != 0x8C46001C or maindec.mword(0x8016BB7C) != 0x800F1018
            or maindec.mword(0x8016BABC + 35 * 4) != 0x800E557C):
        raise ValueError('ordinary boss knockout consumer changed')
    def shared_dissolve(descriptor):
        offset = descriptor - image.base
        return (offset >= 0 and hashlib.sha256(image.data[offset:offset + 66]).hexdigest() == expected)

    descriptor = image.word(table + 7 * 4)
    if shared_dissolve(descriptor):
        return dict(descriptor=hex(descriptor), kind='shared_dissolve', waits=[1, 90, 1])
    offset = descriptor - image.base
    raw = image.data[offset:offset + 8]
    if offset < 0 or raw != struct.pack('<4H', 35, 1, 10, 0) or maindec.mword(0x800E55D4) != 0x8C650008:
        raise ValueError(f'unqualified boss knockout descriptor: {descriptor:#x}')
    callback = image.word(table + 10 * 4)
    require_boss_words(image, {
        0x80017FB0: 0x3402003C, 0x80017FB8: 0xAC220664, 0x80017FE0: 0xA0430005,
        0x80017FE4: 0x3C038001, 0x80017FE8: 0x24637FF8, 0x80017FEC: 0xAC430054,
        0x80018030: 0xACC3002C, 0x8001803C: 0x94430010, 0x80018044: 0xA0400045,
        0x80018048: 0xA4430012, 0x80018060: 0x2444FFFF, 0x80018064: 0x3402001E,
        0x80018068: 0x1082000D, 0x8001806C: 0xAC640000, 0x80018070: 0x14800030,
        0x80018094: 0xA0400005, 0x8001809C: 0xAC400054,
        0x80018104: 0x3C038007, 0x80018108: 0x2463B3A0, 0x8001810C: 0xAC430008,
    })
    if callback != 0x80017FB0:
        raise ValueError('Crystal Core knockout callback changed')
    replacement = 0x8006B3A0
    final_descriptor = image.word(replacement + 7 * 4)
    if not shared_dissolve(final_descriptor):
        raise ValueError('Crystal Core replacement knockout descriptor changed')
    return dict(descriptor=hex(descriptor), kind='restore_hp_and_switch_table', callback=hex(callback),
                continuation='0x80017ff8', countdown=60, rebind_at_remaining=30,
                replacement_table=hex(replacement),
                later_knockout=dict(descriptor=hex(final_descriptor), kind='shared_dissolve', waits=[1, 90, 1]))


def require_boss_words(image, anchors):
    for address, word in anchors.items():
        if image.word(address) != word:
            raise ValueError(f'boss finishing control changed at {address:#x}')


def boss_encounter_finish(image, descriptor):
    """Read the four auxiliary pointers and verify the known controls they install."""
    auxiliary = image.word(descriptor + 0x14)
    callbacks = tuple(image.word(auxiliary + step) for step in range(4, 20, 4))
    row = dict(encounter=hex(descriptor),
               callbacks={name: hex(address) if address else None
                          for name, address in zip(ENCOUNTER_CALLBACKS, callbacks, strict=True)})
    if callbacks == (0, 0, 0, 0):
        return dict(row, kind='ordinary_live_count', reward_gate='both_result_flags_clear')
    if callbacks == (0x80010178, 0, 0, 0x80010214):
        require_boss_words(image, {
            0x80010178: 0x8C820004, 0x80010180: 0x28420006, 0x80010184: 0x14400021,
            0x8001018C: 0xAC801330, 0x80010190: 0xAC801334, 0x80010194: 0x34020001,
            0x8001019C: 0xAC820034, 0x800101C4: 0x94430004, 0x800101CC: 0xA4430006,
        })
        return dict(row, kind='round_end_without_rewards', round_at_least=6, restores_party_hp=True)
    if callbacks == (0x80012F28, 0, 0, 0x80012EE0):
        require_boss_words(image, {
            0x80012F48: 0x9443009E, 0x80012F4C: 0x94440064, 0x80012F50: 0x34638000,
            0x80012F54: 0xA4440066, 0x80012F58: 0xA443009E,
            0x80012F04: 0x94620004, 0x80012F0C: 0xA4620006, 0x80012F1C: 0xAC800038,
        })
        return dict(row, kind='restores_boss_hp_and_clears_defeat_on_teardown', restores_party_hp=True)
    if callbacks == (0x800151F4, 0, 0, 0):
        require_boss_words(image, {
            0x80015200: 0x8CC43420, 0x80015204: 0x34030023, 0x80015220: 0x80420050,
            0x80015228: 0x10430003, 0x80015240: 0xACC21334, 0x80015274: 0x24C6DCFC,
            0x80015278: 0x0040F809, 0x80015534: 0xAE831334,
            0x80015894: 0x34024004, 0x80015898: 0xA4820026, 0x800158B4: 0xA440004A,
            0x800158B8: 0x34020002, 0x800158BC: 0xA0820020, 0x800158C0: 0xA0820021,
            0x800158C4: 0xA0820022, 0x800158C8: 0xA0820023, 0x800158CC: 0xA0820024,
            0x800158D0: 0x34020001, 0x800158D4: 0xA0820025, 0x800159D8: 0xAE601330,
            0x800159E0: 0xAE601334,
        })
        return dict(row, kind='weakening_on_actor_selection', actor_id=35, phase_handlers=['0x80015294', '0x80015568'],
                    feature_mask_after=0x4004, element_coefficients_after=[2, 2, 2, 2, 2, 1])
    if callbacks == (0, 0, 0x80018198, 0x80018454):
        return dict(row, kind='knockout_phase_switch', first_phase='restore_hp_and_switch_table')
    raise ValueError(f'unqualified boss encounter controls: {descriptor:#x}')


def dragon_ordinary_finish(data, encounter, request_offset):
    """Verify the VC6 Dragon's shared HP-zero path and its field continuation."""
    import maindec

    anchors = {
        # Active and unlocked at zero HP. Start slot 7 and publish ordinary defeat.
        0x800E0C6C: 0x92620045, 0x800E0C7C: 0x86620012, 0x800E0C84: 0x1C400009,
        0x800E0C8C: 0x92020005, 0x800E0C94: 0x1440000E, 0x800E0C9C: 0x0C038B6B,
        0x800E2DF4: 0xA0620045, 0x800E2DF8: 0xA0620046, 0x800E2E14: 0x8C420008,
        0x800E2E1C: 0x8C46001C, 0x800E2E24: 0x0C038E08, 0x800E2E54: 0x2442FFFF,
        0x800E2E58: 0xAC82002C, 0x800E2E74: 0xAC220000,
        # The descriptor's mode-0 helper selects the common dissolve callback.
        0x8016BABC + 35 * 4: 0x800E557C, 0x800E5608: 0x24A5BB70, 0x800E5618: 0x00081080,
        0x800E5620: 0x8C440000, 0x800E5630: 0xAC640054, 0x8016BB70 + 3 * 4: 0x800F1018,
        0x800F10A4: 0x34020063, 0x800F10A8: 0x10620089,
        0x800F1470: 0xA2E00003, 0x800F1474: 0xA2E00005, 0x800F147C: 0xAEE00054,
        # Recount by inactivity, wait until the completion delay goes negative, then qualify rewards.
        0x800F74DC: 0xAC80002C, 0x800F7510: 0x90620045, 0x800F7558: 0x10400005,
        0x800F7570: 0xAC600038, 0x800F7574: 0x3402001E, 0x800F7578: 0xAC621264,
        0x800F75A8: 0x244278B0, 0x800F78C0: 0x34020001, 0x800F78CC: 0x2484FFFF,
        0x800F78D0: 0x04800002, 0x800F78D8: 0x2402FFFF, 0x800DE100: 0x1462002A,
        0x800DE150: 0x8C620034,
        0x800DE158: 0x1440000B, 0x800DE160: 0x8C620038, 0x800DE168: 0x14400008,
        0x800DE17C: 0x2463818C, 0x800DE184: 0xAC430000,
        # The field script writes its story bit before the battle request.
        0x80171718 + 9 * 4: 0x8013CBBC, 0x8013CBF8: 0x00431025, 0x8013CC00: 0xA0820190,
    }
    if any(maindec.mword(pc) != word for pc, word in anchors.items()):
        raise ValueError('Dragon ordinary knockout or reward route changed')

    slots = encounter['slots']
    callbacks = struct.unpack_from('<4I', data, encounter['auxiliary_offset'] + 4)
    if len(slots) != 1 or slots[0]['flags'] != 0x4004 or any(callbacks):
        raise ValueError('VC6 Dragon roster or encounter callbacks changed')
    base = 0x80010000
    table, = struct.unpack_from('<I', data, slots[0]['stats_offset'] + 0x28)
    descriptor, = struct.unpack_from('<I', data, table - base + 7 * 4)
    script = (15, 0, 1, 30, 0, 35, 0, 3, 14, 1, 4, 3, 6, 1, 3, 90, 8, 0, 6, 0, 3, 1, 30, 99, 16, 0, 1, 0)
    if table != 0x80080674 or descriptor != 0x80080764 or struct.unpack_from(
        '<28H', data, descriptor - base
    ) != script:
        raise ValueError('VC6 Dragon knockout descriptor changed')
    if data[request_offset - 3:request_offset + 3] != bytes((9, 35, 32, 0x47, 0, 0xFD)):
        raise ValueError('VC6 Dragon field transition changed')

    return dict(trigger='ordinary_hp_zero_unlocked', descriptor=hex(descriptor),
                effect_callback='0x800f1018', knockout_pose=3, waits=[90, 1], cleanup_state=99,
                completion=dict(kind='live_count', remaining_enemies=0, ready_after_updates=31,
                                reward_gate='both_result_flags_clear'),
                field=dict(before_request=dict(offset=request_offset - 3, story_byte=35, mask=32),
                           after_request=dict(offset=request_offset + 2, opcode=0xFD)))


def script_encounters(entries, outcomes):
    """Follow a normal field request through its room section's directory table."""
    import area_scene
    import battle_placement
    import maindec
    from export_first_room import source
    from war_text import decode

    anchors = {
        0x8013209C: 0x90420005, 0x801320A0: 0x8C830004, 0x801320C4: 0xAC23AAE4,
        0x801394DC: 0x8CA5AAE4, 0x801394F8: 0x8CA2001C, 0x80139500: 0x00622021,
        0x80139558: 0x00041080, 0x8013957C: 0x8CA30020, 0x80139588: 0x8C430000,
        0x80139598: 0xAC431BB4,
        0x8013E090: 0x10620012, 0x8013E0E8: 0x30420003, 0x8013E0EC: 0x10400009,
        0x8013E108: 0xAC22AF84, 0x8013E118: 0xA0201C28,
        0x800EE24C: 0x0C03E119, 0x800EE268: 0xAC430014, 0x800EB550: 0x8C910014,
        0x800EB5FC: 0x02201021,
        0x800F6D7C: 0xAC830034, 0x800F6D84: 0xAC800038, 0x800DE158: 0x1440000B,
        0x800DE2EC: 0x8C420010, 0x800DE2F4: 0x10400003, 0x800DE2FC: 0x0040F809,
        0x800DE310: 0x8C540038, 0x800DE480: 0x12820009, 0x800DE4A4: 0xAC651BBC,
        0x800DEED0: 0x8C840004, 0x800DEEE4: 0xAC641334, 0x800F3EEC: 0x0040F809,
        0x800DEB50: 0x8C420008, 0x800DEB58: 0xAC62133C, 0x800F6A08: 0x0040F809,
        0x800DEA98: 0x8C42000C, 0x800DEAA8: 0x0040F809,
    }
    if any(maindec.mword(pc) != word for pc, word in anchors.items()):
        raise ValueError('normal scripted battle directory consumer changed')

    catalogue = {(row['source'], row['section'], row['entry']): row for row in outcomes['battles']}
    names = {row['id']: row['name'] for row in outcomes['enemies']}
    overlays = {path: source(path) for path in sorted({row['source_file'] for row in entries})}
    result = {}
    battlefield_by_directory = {}
    battlefields = {}
    base = area_scene.RAM_BASE
    for row in entries:
        path = row['source_file']
        data, origin = overlays[path]
        offset, selector = row['offset'], row['selector']
        if selector >= 0xFE or offset + 2 >= len(data) or data[offset:offset + 2] != bytes((0x47, selector)):
            raise ValueError(f'normal battle request changed: {row["id"]}')
        room = area_scene.room_record(data, row['room'])
        section = room['section']
        header = area_scene.section_off(data, section)
        index = area_scene.u32(data, header + 0x1C) + selector
        table = area_scene.ptr_at(data, header + 0x20)
        address = area_scene.u32(data, table + index * 4)
        directory = area_scene.to_file(data, address)
        known = catalogue.get((path, section, index))
        binding = dict(section=section, entry=index, directory=hex(address), battlefield=None,
                       after_request=dict(offset=offset + 2, opcode=data[offset + 2]),
                       outcome=known['id'] if known else None, encounters=[])
        result[row['id']] = binding
        companion = None
        if directory is None and path == 'DATA/06_AREA.C/VC6.BIN':
            from resource_groups import groups

            # VC6's callback loads the first file in group 15 at the shared area data base.
            load = struct.unpack_from('<8I', data, 0x108)
            if load != (0x8C82003C, 0x3C03801C, 0x8C639BC4, 0x8C440000,
                        0x8C620010, 0, 0x0040F809, 0x3C058008):
                raise ValueError('VC6 companion load callback changed')
            load_base = (load[-1] & 0xffff) << 16
            if load_base != battle_placement.AREA_BASE or base + len(data) != load_base:
                raise ValueError('VC6 companion load range changed')
            record = groups()[15]['files'][0]
            extra, companion = source(record['path'])
            if (record['size'], record['lba']) != (companion['size'], companion['lba']):
                raise ValueError('VC6 companion file descriptor changed')
            data += extra
            directory = area_scene.to_file(data, address)
            if directory is None or address < load_base:
                raise ValueError('VC6 battle directory is outside its companion')
            binding['directory_source'] = dict(companion, load_address=hex(load_base))
        if directory is None:
            if known:
                raise ValueError(f'catalogued battle directory is outside its overlay: {known["id"]}')
            continue
        directory_key = (path, directory)
        if directory_key not in battlefield_by_directory:
            geometry = battle_placement.directory_battlefield(data, directory, base)
            ground, scenery = geometry['ground'], geometry['scenery']
            offsets = [ground['section_offset'], ground['height_map_offset']]
            if scenery:
                offsets.extend([scenery['section_offset'], scenery['records_offset']])
            key = ':'.join([Path(path).stem, *(f'{offset:x}' for offset in offsets)])
            profile = battlefields.setdefault(key, dict(id=key, source=origin, directories=[], **geometry))
            profile['directories'].append(hex(address))
            battlefield_by_directory[directory_key] = key
        binding['battlefield'] = battlefield_by_directory[directory_key]
        _, encounters = battle_placement.directory_encounters(data, directory, base)
        if known and (int(known['directory_va'], 0) != address or len(known['encounters']) != len(encounters)):
            raise ValueError(f'battle outcome directory mismatch: {known["id"]}')
        for i, encounter in enumerate(encounters):
            descriptor = encounter['descriptor_offset']
            flags = area_scene.u32(data, descriptor + 0x0C)
            callback_addresses = struct.unpack_from('<4I', data, encounter['auxiliary_offset'] + 4)
            callbacks = {name: hex(address) if address else None for name, address in zip(ENCOUNTER_CALLBACKS, callback_addresses)}
            described = dict(address=hex(base + descriptor), escape_allowed=flags & 0x80000000 == 0,
                             archive='boss' if flags & 0x40000000 else 'standard', **callbacks, **encounter)
            if known:
                checked = known['encounters'][i]
                if (int(checked['encounter_va'], 0), checked['flags'], checked['roster_slots']) != (
                    base + descriptor, flags, [slot['enemy_id'] for slot in encounter['slots']]
                ):
                    raise ValueError(f'battle outcome encounter mismatch: {known["id"]}')
                described['enemy_names'] = [names[enemy] for enemy in checked['enemy_ids']]
            elif companion is not None:
                described['enemy_names'] = []
                for slot in encounter['slots']:
                    stats = slot['stats_offset']
                    described['enemy_names'].append(decode(data[stats:stats + 16], length=16)[0])
                    slot['actor_script_table'] = hex(area_scene.u32(data, stats + 0x28))
                    slot['decision_callback'] = hex(area_scene.u32(data, stats + 0x30))
                if (section, index) == (13, 2):
                    described['ordinary_finish'] = dragon_ordinary_finish(data, encounter, offset)
            binding['encounters'].append(described)
    return result, list(battlefields.values())


def regional_battlefields():
    """Read the default directories selected by the standard field driver."""
    import area_encounter_tables
    import battle_placement
    import maindec
    from export_first_room import source

    anchors = {
        0x80128600: 0x8E22000C, 0x80128608: 0x8C440000, 0x80128614: 0xAC641BB4,
        0x800DDFCC: 0x8C831BB4, 0x800DDFE0: 0xAC23C100,
        0x800DE694: 0x8C42C100, 0x800DE69C: 0x8C440000, 0x800DE6A0: 0x0C039E7A,
        0x800DE6D8: 0x8C420010, 0x800DE6E4: 0x0C039DE1,
        0x800DF180: 0x8C550014, 0x800DF228: 0x8C440004, 0x800DF230: 0x14800005,
        0x800DF264: 0x86A20000, 0x800DF280: 0x86250008,
        0x800E7A24: 0x92A30004, 0x800E7A60: 0x92A20005, 0x800E7C3C: 0x8EA30010,
    }
    if any(maindec.mword(pc) != word for pc, word in anchors.items()):
        raise ValueError('standard battlefield selection or resource consumer changed')

    result = []
    base = area_encounter_tables.BASE
    for area in area_encounter_tables.area_data_files():
        data, origin = source(area['path'])
        descriptor = battle_placement.pointer(data, 0, base)
        resources = battle_placement.pointer(data, descriptor + 12, base)
        address = battle_placement.word(data, resources)
        if address == 0:
            continue
        _, _, directory, selectors = area_encounter_tables.chain(data)
        encounter_count = battle_placement.word(data, selectors - base)
        geometry = battle_placement.directory_battlefield(data, directory - base, base)
        result.append(dict(source=origin, directory=hex(directory), encounter_count=encounter_count, **geometry))
    return result


def opening_battle_admissions(opening):
    import area_scene
    import maindec
    from event_script_decode import decode_stream, switch_2f_targets
    from export_first_room import source
    from export_scene_population import decode_predicate

    raw, origin = source(opening['source']['file'])
    if origin != opening['source']:
        raise ValueError('opening battle admission source changed')
    result = {}
    for entry in opening['entries']:
        if entry['source_file'] != origin['file']:
            raise ValueError(f'opening battle entry source changed: {entry["id"]}')
        room = area_scene.room_record(raw, entry['room'])
        entity = area_scene.entities(raw, room)[entry['entity']]
        section = area_scene.section_off(raw, room['section'])
        images = area_scene.ptr_at(raw, section + 0x34)
        if images is None:
            raise ValueError(f'missing opening battle image list: {entry["id"]}')
        custom_images = set()
        for i in range(128):
            address = area_scene.u32(raw, images + 4 * i)
            if address == 0:
                break
            image = area_scene.to_file(raw, address)
            if image is None or not area_scene.in_file(raw, image, 12):
                raise ValueError(f'invalid opening battle image pointer: {address:#x}')
            if area_scene.u32(raw, image + 4) != 0:
                custom_images.add(area_scene.u32(raw, image))
        else:
            raise ValueError(f'unterminated opening battle image list: {entry["id"]}')
        _, selection, stream = entity['stream_offsets']
        predicate, proof = decode_predicate(raw, selection, 'event', coordinate_ranges=True)
        story, coordinates = [], {}
        for term in proof['terms'][:-1]:
            opcode, operands = term['opcode'], term['operands']
            if opcode in (7, 8):
                story.append(dict(byte_index=operands[0], mask=operands[1], required='set' if opcode == 7 else 'clear'))
            elif opcode in (11, 12) and operands[0] <= operands[1]:
                axis = 'x' if opcode == 11 else 'y'
                if axis in coordinates:
                    raise ValueError(f'duplicate opening battle coordinate predicate: {entry["id"]}')
                coordinates[axis] = operands
            else:
                raise ValueError(f'unresolved opening battle predicate: {entry["id"]}')
        pre_effect = entry['pre_effect_offset']
        wait, opcode, byte_index, mask = raw[pre_effect - 1:pre_effect + 3]
        write = dict(kind='story_or', byte_index=byte_index, mask=mask)
        if (stream != entry['stream'] or story != entry['guard'] or set(coordinates) != {'x', 'y'} or
            pre_effect + 3 != entry['trigger_offset'] or (wait, opcode) != (0x46, 0x09) or write != entry['pre_effect']):
            raise ValueError(f'opening battle admission changed: {entry["id"]}')
        lead_in = []
        for offset, opcode, operands, note in decode_stream(raw, stream, max_insns=64):
            if offset > entry['trigger_offset'] or 'UNKNOWN' in note or 'TRUNCATED' in note:
                break
            site = dict(offset=offset, opcode=opcode)
            if opcode == 0x10:
                site['motion'] = dict(kind='align_hero', x=8 * operands[0], y=8 * operands[1])
            elif opcode == 0x08:
                selector, duration = operands
                if selector >= 4 or duration == 0:
                    raise ValueError(f'unresolved camera pan at {offset:#x}')
                deltas = [maindec.mword(address + 4 * selector) for address in (0x80171860, 0x80171870)]
                dx, dy = [(word ^ 0x80000000) - 0x80000000 for word in deltas]
                site['motion'] = dict(kind='pan', dx=dx, dy=dy, updates=duration * 4)
            elif opcode == 0x0A:
                site['motion'] = dict(kind='timer', updates=operands[0] * 5)
            elif opcode == 0x12:
                slot, code = operands
                if slot > 1 or code not in (8, 0x7c):
                    raise ValueError(f'unresolved opening battle speaker at {offset:#x}')
                site['speaker'] = dict(slot=slot, code=code,
                                       name_pointer=maindec.mword(0x80170588 + 4 * code) if code == 0x7c else None,
                                       image_lookup='custom' if code in custom_images else 'active_party')
            elif opcode == 0x2F:
                targets = switch_2f_targets(raw, offset)
                site['ui_mode_targets'] = targets
                alternate = decode_stream(raw, targets[1], max_insns=4)
                if [row[1] for row in alternate] != [0xFC, 0x4D, 0x10, 0xFD] or alternate[1][2][0] != 0:
                    raise ValueError(f'unresolved opening battle alternate at {targets[1]:#x}')
                x, y = alternate[2][2]
                site['alternate_actions'] = [
                    dict(kind='advance_tile_variant', descriptor=alternate[1][2][1]),
                    dict(kind='align_hero', x=8 * x, y=8 * y),
                ]
            elif opcode == 0x05:
                initial, count, _ = operands
                if (initial, count) != (0, 2):
                    raise ValueError(f'unresolved opening battle choice at {offset:#x}')
                site['choice'] = dict(initial_row=initial, rows=count, result='ui_mode')
            lead_in.append(site)
            if offset == entry['trigger_offset']:
                break
        if not lead_in or lead_in[-1] != dict(offset=entry['trigger_offset'], opcode=0x47):
            raise ValueError(f'opening battle approach does not reach the request: {entry["id"]}')
        result[entry['id']] = dict(predicate_offset=selection, story=story, inclusive_half_cells=coordinates,
                                   event_selection=predicate, pre_effect=write, lead_in=lead_in)
    return result


def battle_field_owners(entries):
    import area_scene
    from export_first_room import source
    from export_scene_population import decode_predicate

    overlays = {path: source(path)[0] for path in sorted({entry['source_file'] for entry in entries})}
    owners = {}
    for entry in entries:
        raw = overlays[entry['source_file']]
        entities = area_scene.entities(raw, area_scene.room_record(raw, entry['room']))
        records = []
        for number in entry['entity_ids']:
            entity = entities[number]
            _, selection, stream = entity['stream_offsets']
            if stream != entry['stream']:
                raise ValueError(f'battle owner stream changed: {entry["id"]} entity {number}')
            predicate, _ = decode_predicate(raw, selection, 'event', coordinate_ranges=True)
            unsupported = sorted({term['semantics'] for term in predicate['terms'] if term['kind'] == 'unsupported'})
            records.append(dict(entity=number, predicate_offset=selection, event_selection=predicate,
                                initialization=bool(entity['flags'] & 0x10), unsupported_terms=unsupported))
        owners[entry['id']] = records
    return owners


def battle_report(journey, combat, room_requests=()):
    assets = ROOT / 'game/assets'
    outcomes = json.loads((assets / 'battle_systems/outcomes.json').read_text())
    graph = json.loads((assets / 'campaign/middle/battle_graph.json').read_text())
    opening = json.loads((assets / 'campaign/opening/opening_battles.json').read_text())
    opening_ids = {(row['source_file'], row['room'], row['stream'], row['trigger_offset']): row['id']
                   for row in opening['entries']}
    encounters = {row['id']: row for row in combat['encounters']}
    battlefield_bindings = [dict(encounter=row['id'], battlefield=row['battlefield'])
                            for row in encounters.values() if row.get('battlefield') is not None]
    movement_bindings = (journey.get('field_encounters') or {}).get('rooms', [])
    formations = {row['id']: row for row in graph['formations']}
    source_encounters, scripted_fields = script_encounters(graph['entries'], outcomes)
    field_owners = battle_field_owners(graph['entries'])
    regional_fields = regional_battlefields()
    movement = field_encounters()

    entries = []
    for row in graph['entries']:
        identity = (row['source_file'], row['room'], row['stream'], row['offset'])
        formation = formations[row['formation_id']]
        match = re.fullmatch(r'area_([a-z])\.encounter\.(\d+)', formation['id'])
        runtime_id = f'area_{match[1]}_{int(match[2])}' if match else None
        candidate = encounters.get(runtime_id)
        placement_matches = candidate is not None and (
            candidate.get('source_slots') == [slot['slot'] for slot in formation['slots']]
            and [[point[axis] for axis in ('x', 'y', 'z')] for point in candidate['positions']]
            == [slot['world'] for slot in formation['slots']]
        )
        entries.append(dict(id=row['id'], source_file=row['source_file'], room=row['room'],
                            stream=row['stream'], request_offset=row['offset'], selector=row['selector'],
                            opening_entry=opening_ids.get(identity), legacy_layout_probe=formation['id'],
                            matching_layout_probe=runtime_id if placement_matches else None,
                            source_encounter=source_encounters[row['id']],
                            field_owners=field_owners[row['id']],
                            runtime_state=row['runtime_state']))

    callbacks, knockouts, finishes = boss_sources(outcomes)
    battles = [dict(id=row['id'], source=row['source'], section=row['section'], entry=row['entry'],
                    archive=row['archive'], boss_ids=row['boss_ids'], end_trigger=row['end_trigger'],
                    escape_allowed=row['escape_allowed'], source_finish=finishes.get(row['id'], []))
               for row in outcomes['battles']]
    bosses = [dict(id=row['id'], name=row['name'], mechanics=row['mechanics'],
                   feature_mask=row['feature_mask'], callback=row['callback'],
                   callback_kind='direct_overlay_entry', actor_script=row['actor_script'], knockout=knockouts[row['id']],
                   encounters=[fight['id'] for fight in battles if row['id'] in fight['boss_ids']])
              for row in outcomes['bosses']]
    return dict(
        schema='suikoden-campaign-battle-coverage/11',
        scope='Normal field requests and battlefields follow original directory pointers. Boss sources include decisions, ordinary knockout descriptors and verified encounter controls alongside the retained runtime outcome catalogue. Packaged room requests identify commands bound to owners.',
        summary=dict(source_entries=len(entries),
                     opening_entries_matched=sum(row['opening_entry'] is not None for row in entries),
                     legacy_layout_probe_matches=sum(row['matching_layout_probe'] is not None for row in entries),
                     source_entries_with_encounter=sum(bool(row['source_encounter']['encounters']) for row in entries),
                     source_entries_allowing_escape=sum(any(encounter['escape_allowed'] for encounter in row['source_encounter']['encounters']) for row in entries),
                     field_owner_records=sum(len(records) for records in field_owners.values()),
                     field_owner_records_with_unsupported_terms=sum(bool(owner['unsupported_terms']) for records in field_owners.values() for owner in records),
                     scripted_battlefields=len(scripted_fields), regional_battlefields=len(regional_fields),
                     movement_field_rooms=movement['summary']['room_status'].get('resolved', 0),
                     movement_field_directories=movement['summary']['directories'],
                     source_only_entries=sum(row['runtime_state'] == 'source_only' for row in entries),
                     outcome_records=len(battles), boss_records=len(bosses), boss_action_callbacks=len(callbacks),
                     boss_outcomes_with_unproven_end=sum(bool(row['boss_ids']) and row['end_trigger'] == 'unproven' for row in battles),
                     boss_source_finish_kinds=dict(Counter(row['kind'] for entries in finishes.values() for row in entries)),
                     runtime_field_triggers=len(journey['encounters']),
                     runtime_room_battle_requests=len(room_requests),
                     runtime_movement_field_rooms=len(movement_bindings),
                     runtime_encounters_with_battlefield=len(battlefield_bindings)),
        source_entries=entries, request_sites=battle_request_sites(outcomes['callers'], entries), outcomes=battles,
        opening_admissions=opening_battle_admissions(opening),
        bosses=bosses, boss_action_callbacks=callbacks,
        scripted_battlefields=scripted_fields, regional_battlefields=regional_fields,
        field_movement_encounters=movement,
        boss_end_trigger_evidence=outcomes['boss_contract']['end_trigger_evidence'],
        runtime_field_triggers=[dict(id=row['id'], room=row['room'], encounter=row['encounter'])
                                for row in journey['encounters']],
        runtime_room_battle_requests=list(room_requests),
        runtime_movement_field_rooms=movement_bindings,
        runtime_battlefield_bindings=battlefield_bindings,
        runtime_boss_music_encounters=sorted(row['id'] for row in encounters.values() if row.get('music') == 'boss'),
    )


def battle_package_report(root: Path):
    journey = json.loads((root / 'journey.json').read_text())
    if journey['battle'] != 'battle/trial.json':
        raise ValueError('unexpected battle path in journey.json')
    combat = json.loads((root / 'battle/trial.json').read_text())
    field = json.loads((root / 'room.json').read_text())
    room_requests = room_battle_requests(root, {row['id'] for row in field['rooms']},
                                         {row['id'] for row in combat['encounters']})
    return battle_report(journey, combat, room_requests)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=DEFAULT)
    parser.add_argument("--verify", action="store_true")
    parser.add_argument("--battle-package", type=Path, help="report scripted and boss battle coverage for a Journey package")
    args = parser.parse_args()
    if args.battle_package is None:
        result = write(args.out, args.verify)
        print(json.dumps(result["summary"], sort_keys=True))
    else:
        if args.verify or args.out != DEFAULT:
            parser.error("--battle-package writes to stdout")
        try:
            report = battle_package_report(args.battle_package)
        except (OSError, ValueError) as error:
            parser.error(str(error))
        print(json.dumps(report, indent=2))

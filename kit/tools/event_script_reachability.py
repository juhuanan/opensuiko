#!/usr/bin/env python3
"""Static entry-rooted script graph; unresolved edges are explicit, never resynced.

This is a possible-path graph, not an execution trace. Room candidates use the
existing bounded probe. Switch edges assume valid mode indices; classifier and
wait-state feasibility, mutable pointers and external streams remain unproved.
Only independently checked callback bodies have cursor continuations.
Output is analysis metadata, never an accepted script or asset package.
"""
from collections import deque
import hashlib
import json
from pathlib import Path
import struct
import sys

from area_entity_probe import room_records, room_source_bound, ENTITY_SIZE, RAM_BASE
from build_script_corpus import CLUSTERS, data_ranges, load_dialogue
from disc import extract
from event_script_decode import decode_stream, switch_2f_targets

KIT = Path(__file__).resolve().parents[1]

# Exact bodies, not overlay names or reused RAM addresses, identify these contracts.
CALLBACK_CURSORS = {
    0x80012258: (0x23EC, None, False, '9baa95d3aed5ab3f7cc4ce23935d1544124ad41375aafe80b57225c1eafc2810'),
    0x8001243C: (0x2498, 0, True, 'f6193b34624d0fcaa4c134d00f074865a0493b497afd093e85b51f87763b8476'),
    0x80010188: (0xAA0, 3, True, 'edee8b240558354883a8d92563ae92f56d8be4bcf3af15e3116618b7ed06b867'),
    0x800134C8: (0x3DE0, 3, True, '9a239c1d5dfd6536b34b42a205a3ab944bb4d543c716484143d95bf82c5decaa'),
    0x8001426C: (0x491C, 4, True, '3b77a7430adec57f973a3007bf029122b7d43d66be929f629742fe94980b9607'),
    0x800157A0: (0x5934, None, False, '0e33a63dba4ba4e645a4f9e1175989c404819841b8850f7248306319297369a8'),
    0x80015934: (0x5984, 1, False, '16cc6fd7825c65d9fe55a3907080e35f83032337f33e878d50edbd8e14ce6451'),
    0x80016434: (0x7BB4, 2, True, '164fa50a301ebb7f7969fbc4c646972afd7a05f119e07c9ce8979de302255018'),
    0x80017BB4: (0x8560, 3, True, 'b7fcf35d25311641be415bac23ed99f3ab8058804de765e4e0b0ebb3bf41f7eb'),
    0x80019290: (0xAC90, 'ff_prefix', True, '6ccca875253cb31c9cfe0be36f790489923665983015fb56672ba50d14c839f5'),
    0x8001AC90: (0xC784, 3, True, '4b8595ae86fc76a5b678b7dc1211906967d6ad38ebeb254458d797a0bd78fc95'),
    0x8001C818: (0xCF34, 5, True, '3c852514de4dd8afd5cd2ebdb3f2fe3948770b70b5141e7da0ed0ba4903513f3'),
    0x8001CF34: (0xE5A0, 8, True, '2710d6b11d01bb654bff2ef81daccf9023ca87a2ef7d7e592e2fbf25c1317f29'),
    0x8001031C: (0x3C0, 1, False, 'c5bc6995c47d9d573251dc42849561972cc8567ff45e846f4e4d3f79d7abc307'),  # VE4 0x01
    0x80010440: (0x5CC, 1, False, '34afd93c05d447e9678e7195032850c88d065811f906f84d2b7e507b277d053a'),  # VE4 0x03
    0x80012F30: (0x39F0, 4, True, 'f11096333e202918131353c8ea05cd519bea68d38f959c2ec59bfc0257375b9a'),  # VE4 0x06
    0x80010D54: (0x1404, 4, True, '840131d690322aee14453f0e4d395ae73903793607815b98b2b1ba9d0c55382a'),  # VF4 0x07
    0x80016DCC: (0x7778, 3, True, 'c28513621d78014e4faff24fed8c1593249ee20410d09eb96d5781dd7494170c'),  # VF4 0x0d
    0x80012F1C: (0x3EF8, 2, True, '77a7ac831832e1048f555b0975e8d5402c0486f938d86281fb2df1d8b0788ce9'),  # VF4 0x0e
    0x800153CC: (0x6DCC, 'ff_prefix', True, 'a137eb16e7b05c523846149a0b3ea2667bd4c3a5bccc4bf272e460a1d30d641f'),  # VF4 0x0f
    0x80011C14: (0x2008, 3, True, '6387da18a002b68529478cc33d6868786fdbad9025b412e992c706397795e0c2'),  # VF4 0x10
    0x80012288: (0x241C, None, False, 'a4b646391910c281058aceb1c9de76d3234cd0362599a94d591ac0e1e4f81cc5'),  # VF4 0x12
    0x8001241C: (0x246C, 1, False, '6a148ffea3c46b569053821218b6f2c9231be141b44f8feeb6409197b3bd0bf2'),  # VF4 0x13
    0x8001246C: (0x24C8, 0, True, 'c9019d935bbeb0ee81d301a6c989de2dc41bb965910ec511ea648a3e916d1fcf'),  # VF4 0x14
    0x800124C8: (0x2544, 0, True, 'f2522c567906972bfe6d6b6ea494111d88df4fc8ac06a58591e087cde94e1ef8'),  # VF4 0x15
    0x80017AE4: (0x9CC0, 6, True, '9beb3e922af3e0cf0037b521623bbc57d00d2e649bc81f6e193dfdec87e851bd'),  # VF4 0x19
    0x80010540: (0xC48, 6, True, '1b481bebb77d780bf0e936d8056a3014992f9f54104c1c8a5c6647d2d28f36e4'),  # VA9 0x05
    0x80010CDC: (0x138C, 4, True, '3e2a51db798ada1b48f847d8bb60fcc201ae04f884f93f862f8db66ab2e055d7'),  # VA9 0x07
    0x800119B4: (0x1AB4, 3, False, 'e8f5642125cf248d188c97e52c955f06b3b7bf4c809b8e434df4d27e1528b322'),  # VA9 0x0b
    0x80011AB4: (0x1B9C, 2, False, '5c69d2dac8f7394393b171ed6fbd74a0813e4938d11a429aba5ef64e85ff42e4'),  # VA9 0x0c
    0x80012EA4: (0x3850, 3, True, '79722ef1733e44d296ec5c26d06e6323a1aec5425ec99bf56389424139d35ae5'),  # VA9 0x0d
    0x80011B9C: (0x1F90, 3, True, '847631c05ab12003818c00026f28a6cc4550e935a390cbad8ff2053d108553ac'),  # VA9 0x10
    0x80013850: (0x5344, 3, True, '54dc232ffa8edbed98972ca33d998fa53308943579844e0206cac49ce854c750'),  # VA9 0x1c
    0x80011420: (0x169C, 2, True, '7d6408bd64d1226f230d6541ef39ae4be72187e742ab8ebc9f2f1607991d3583'),  # VS1 0x08
    0x8001169C: (0x194C, 0, True, '1173c9c5a74f40dc1992ff90ce07bd43ee3e6d9f2c9ae6ca80cd320339f3cd9c'),  # VS1 0x09
    0x80011C30: (0x2024, 3, True, '28a57117d935ef06b067352b4e493006d01b544420c3a7c8b1b92a124ec89d2e'),  # VS1 0x10
}

# These phase tables are outside the callback instruction spans.
CALLBACK_PHASE_TABLES = {
    0x800134C8: (0xC4, 0xDC, '75bbf481be98ea0235260bd5c34076a4032499eb17223d10f18300d685f8a259'),
    0x80016434: (0xF4, 0x10C, 'af628a0c1b2f4576a04171016732294db6aafd3dd7903c08d1f195a855058a58'),
    0x80019290: (0x10C, 0x124, '2998f18c56b2b9054f41494fc28cc35c972cb59dcb8499ed9e746624d043ea85'),
    0x8001AC90: (0x124, 0x144, 'a3fb511f51eff2030040f77148987895bc200319c26bae633ba6609d6dfaab6e'),
    0x8001CF34: (0x17C, 0x190, 'bd1c581c033f44f401380d90e90c81cd160b7cf415ea401c3571b2d6a4c9242d'),
}

# Reused overlay addresses can have different bodies. Each immediate contract
# names its complete function including the return's delay instruction.
RETRY_CURSORS = (
    (0x80013070, 0x3F24, 6, '77e3ac0e52595c4ad1d23ff92a055f8a74dfea6406baacf894dd8067057c8a98'),
    (0x80012F1C, 0x3EF8, 2, '6158483722b2cca5d82c2949b3e104b3a02dbc99541527529c25fffd9333bf7e'),
    (0x80017AE4, 0x9CC0, 6, 'b76f05e8c1738139f659959c1f169865005057bb77dfde7d6fafacec12f494f1'),
    (0x80014650, 0x5110, 4, '4d82d72777bbb74423795adcdef30d30b06fa5c19f3601839543a82d23ac9718'),
    (0x80010D08, 0x13B8, 4, '77af2fdadf7b09f77fa40af8be5e9f84b52597fa7a00d4caa29c685ab282ceb9'),
    (0x80015110, 0x5ABC, 3, 'ed4f309007dd822b07ee07cd96a3bd1fd7b86bdc0dba6b07c893da12a4632ac2'),
)

IMMEDIATE_CURSORS = (
    (0x80010314, 0x394, 1, '905b24769c3165d92eecb2a38ff4a12e818ecf0e292a8a90113fa438f3897bda'),
    (0x80010394, 0x520, 1, '2e1b56943a0fe02668343287b21fd4597fa9ec1eea511b4fefb54a1bf60983a3'),
    (0x80012008, 0x20A4, 0, '4a58b88b966105ab8d6208a19423ce2a2e01a5afd710616d5caeb89eee700ed6'),
    (0x800103A0, 0x420, 1, '16e6c355db0da16c0d6c9fe77313a83f58e641a3810ceb6ba41dc2c39e775afa'),
    (0x80010270, 0x314, 1, 'a16f1584bea11bda9a5badd9e72fd3dc9dbb0322331545b277df9eb218cc71c1'),
    (0x80010270, 0x314, 1, '20491b720f37578281865e3d5ad59c28b7447803140aca5d16d4f789952d4c35'),
    (0x800102A8, 0x34C, 1, '804517bd716e0b754f156cb1ff2cbd2fc1b09bce8150cd60566cc7372152133e'),
    (0x80012158, 0x21F0, 2, '2fda691507df11ef921c4b81f68ee7feb77c1b0b65bc4e1ebfa08b8841a16526'),
    (0x80012158, 0x21F0, 2, 'ec292259d6334612bed20415a45d0e60dc8d24cec6e0d99254232fe97c2b9999'),
    (0x800121E4, 0x227C, 2, '43ba5dcae8b7137048b4c2b73b95186e7bc6d0ae0c716000e7d80086505d1612'),
    (0x80011FFC, 0x2094, 2, '0c6e7abdf01d641deccb6c21c9ea9009d6f78655d14504f9a34044fe30d9011e'),
    (0x80012190, 0x2204, 1, '168ad8130830962727032e81683012495e472859013bcbd2675c1e0df7ba44a1'),
    (0x80011994, 0x1A94, 3, '9e60c8abd8e1ddbb9828cdb7c813e7c2811656250f8684b63bf5772d2bfa7265'),
)


def callback_cursor(data, pc):
    """Resolve the actual import slot; unknown/mutated sources remain frontiers."""
    def pointer(off):
        if not 0 <= off <= len(data) - 4:
            raise ValueError('callback pointer outside source')
        return struct.unpack_from('<I', data, off)[0] - RAM_BASE
    if pc + 1 >= len(data):
        return None
    try:
        table = pointer(pointer(0) + 0x10)
        target = pointer(table + 4 * (10 + data[pc + 1])) + RAM_BASE
    except ValueError:
        return None
    start = target - RAM_BASE
    contract = CALLBACK_CURSORS.get(target)
    if contract is not None:
        end, operands, retry, digest = contract
        if hashlib.sha256(data[start:end]).hexdigest() != digest:
            contract = None
    if contract is None:
        for address, end, operands, digest in RETRY_CURSORS:
            if target == address and hashlib.sha256(data[start:end]).hexdigest() == digest:
                contract = (end, operands, True, digest)
                break
    if contract is None:
        for address, end, operands, digest in IMMEDIATE_CURSORS:
            if target == address and hashlib.sha256(data[start:end]).hexdigest() == digest:
                contract = (end, operands, False, digest)
                break
    if contract is None:
        return None
    phase_table = CALLBACK_PHASE_TABLES.get(target)
    if phase_table is not None:
        first, last, digest = phase_table
        if hashlib.sha256(data[first:last]).hexdigest() != digest:
            return None
    end, operands, retry, _ = contract
    if operands is None:
        # This initializer consumes control, count, then count bytes; it never rewinds.
        count = data[pc + 3] if pc + 3 < len(data) else 0
        operands = 2 + count
    elif operands == 'ff_prefix':
        operands = 2 + int(pc + 2 < len(data) and data[pc + 2] == 0xFF)
    contract = {'target': target, 'operands': operands}
    if not retry:
        contract['retry'] = False
    return contract


def entry_roots(data):
    """Potential selected entries; the classifier/flags are retained, not guessed."""
    # shortcut: room candidates use the bounded probe; derive a consumer-backed
    # room limit before treating a wider overlay population as exhaustive.
    entries = []
    for room in room_records(data):
        start = room['ent_off']
        if start is None or start + ENTITY_SIZE * room['count'] > len(data):
            continue
        for i in range(room['count']):
            off = start + i * ENTITY_SIZE
            classifier, stream = struct.unpack_from('<II', data, off + 16)
            entries.append({'room': room['index'], 'entry': i, 'record': off,
                            'flags': struct.unpack_from('<H', data, off + 4)[0],
                            'classifier': classifier, 'stream': stream,
                            'offset': stream - RAM_BASE,
                            'selection_mode': 'initialization' if struct.unpack_from('<H', data, off + 4)[0] & 0x10 else 'ordinary',
                            'unconditional_classifier': 0 <= classifier - RAM_BASE < len(data) and data[classifier - RAM_BASE] == 6})
    return entries


def successors(data, pc, op, args):
    """Instruction-derived byte targets for valid switch modes; no state pruning."""
    end = pc + 1 + len(args)
    if op == 0x14:
        return [pc + 1 + args[0]]
    if op == 0x23:
        return [pc + 1 - args[0]]
    if op == 0x15:
        n = args[0]
        if not n:
            raise ValueError('zero switch count')
        return sorted({pc + n + displacement for displacement in (1, *args[1:])})
    if op == 0x2F:
        return sorted(set(switch_2f_targets(data, pc).values()))
    if op == 0x2D:
        found = data.rfind(bytes(args), 0, pc + 1)
        if found < 0:
            raise ValueError('backward label not found in source')
        return [found + 1]
    if op == 0x2E:
        return [data.index(bytes(args), pc + 2) + 1]
    # Wait handlers can retry themselves; their eventual fallthrough is included.
    # No claim is made that a wait's exit predicate is reachable in game state.
    return [end]


def walk(data, roots, contexts=()):
    pending = deque(sorted(set(roots)))
    nodes, frontier = {}, []
    while pending:
        pc = pending.popleft()
        if pc in nodes:
            continue
        row = {'offset': pc, 'next': []}
        nodes[pc] = row
        if not 0 <= pc < len(data):
            row['stop'] = 'outside source file'
        elif any(lo <= pc < hi for lo, hi, _ in contexts):
            row['stop'] = next(label for lo, hi, label in contexts if lo <= pc < hi)
        else:
            op = data[pc]
            row['opcode'] = op
            if op == 0x3D:
                contract = callback_cursor(data, pc)
                if contract is not None:
                    row['callback'] = contract
                    row['end'] = pc + 2 + contract['operands']
                    if row['end'] > len(data):
                        row['stop'] = 'truncated overlay callback operands'
                    else:
                        # Effect completion is conditional; counted initializers advance immediately.
                        row['next'] = ([pc] if contract.get('retry', True) else []) + [row['end']]
                        pending.extend(row['next'])
                else:
                    row['stop'] = ('overlay callback continuation unresolved' if pc + 1 < len(data)
                                   else 'truncated overlay callback selector')
            elif op in (3, 0xFD):
                # The tick's inline exits bypass its normal handler re-loop path.
                # FD retries while text is busy, otherwise clears the active flag.
                row['stop'] = 'inline wait/stream exit'
            else:
                _, _, args, note = decode_stream(data, start=pc, max_insns=1)[0]
                row['end'] = pc + 1 + len(args)
                if any(t in note for t in ('UNKNOWN', 'TRUNCATED', 'truncated', 'NULL')):
                    row['stop'] = note
                else:
                    try:
                        row['next'] = successors(data, pc, op, args)
                    except ValueError as exc:
                        row['stop'] = str(exc)
                    else:
                        pending.extend(row['next'])
        if 'stop' in row and row['stop'] != 'inline wait/stream exit':
            frontier.append({'offset': pc, 'reason': row['stop']})
    return {'nodes': [nodes[p] for p in sorted(nodes)], 'frontier': frontier,
            'inline_exits': sum(r.get('stop') == 'inline wait/stream exit'
                                for r in nodes.values())}


def build(names):
    files = json.loads((KIT / 'extracted/iso_files.json').read_text())
    dialogue = load_dialogue()
    reports = []
    for name in names:
        rec = next(r for r in files if r['path'].rsplit('/', 1)[-1] == name)
        data = extract(rec['lba'], rec['size'])
        entries = entry_roots(data)
        graph = walk(data, [e['offset'] for e in entries],
                     data_ranges(data, name, dialogue))
        reports.append({'file': rec['path'], 'lba': rec['lba'], 'size': rec['size'],
                        'room_source_bound': room_source_bound(data),
                        'entries': entries, **graph})
    return {'schema': 'suikoden-static-script-graph/1',
            'scope': 'bounded room candidates, entry+0x14 pointers, valid-mode '
                     'switch paths; classifier/wait feasibility and inline exit '
                     'continuations are not solved; only exact independently checked '
                     'callback bodies have explicit retry/completion or immediate counted edges; no resync',
            'overlays': reports}


def first_room_stream_candidate(data):
    """A referenced stream can suggest a room bound; it does not prove one."""
    start = room_source_bound(data)['start']
    if start is None or not 0 <= start <= len(data) - 16:
        return None
    entries = struct.unpack_from('<I', data, start)[0] - RAM_BASE
    count = data[start + 4]
    if not count or not 0 <= entries <= len(data) - count * ENTITY_SIZE:
        return None
    candidates = []
    for index in range(count):
        field = entries + index * ENTITY_SIZE + 12
        target = struct.unpack_from('<I', data, field)[0] - RAM_BASE
        if start < target < len(data):
            candidates.append((target, index, field))
    if not candidates:
        return None
    target, index, field = min(candidates)
    if (target - start) % 16:
        return None
    return {'status': 'inferred, not a canonical bound', 'offset': target,
            'room_slots': (target - start) // 16, 'entry_index': index,
            'pointer_field_offset': field}


def source_summary():
    """Diagnostic coverage of the39 catalogued windows, not every game scene."""
    reports = []
    for graph in build(list(CLUSTERS))['overlays']:
        bound = graph['room_source_bound']
        record = {
            'file': graph['file'], 'lba': graph['lba'], 'size': graph['size'],
            'room_source_bound': bound,
            'physical_room_records': ((bound['upper_bound'] - bound['start']) // 16
                                      if bound['upper_bound'] is not None else None),
            'candidate_entries': len(graph['entries']), 'possible_sites': len(graph['nodes']),
            'inline_exits': graph['inline_exits'],
            'dialogue_sites': sum(n.get('opcode') == 0x1C for n in graph['nodes']),
            'frontier': graph['frontier'],
        }
        if bound['upper_bound'] is None:
            record['first_room_stream_candidate'] = first_room_stream_candidate(
                extract(graph['lba'], graph['size']))
        reports.append(record)
    return {'schema': 'suikoden-script-source-census/1',
            'scope': '39 previously catalogued overlays, not a whole-game census; following-text '
                     'bounds are physical candidate intervals, not selectable-room counts; '
                     'other sources retain the64-record/four-gap heuristic; mode/wait '
                     'feasibility and unknown callback continuations remain unresolved',
            'overlays': reports}


def loader_file_slots():
    """Resolve bounded mode-2 file-table slots without scanning room scripts."""
    import maindec as main
    from area_data_select import MASTER_TABLE, REGION_ENTRIES, master_records

    low = main.mword(0x80130F58) & 0xFFFF
    table = ((main.mword(0x80130F54) & 0xFFFF) << 16) + (low - 65536 if low & 32768 else low)
    starts = [main.mword(table + 4*i) for i in range(REGION_ENTRIES)]
    boundaries = sorted(set(starts)) + [table]
    files = json.loads((KIT / 'extracted/iso_files.json').read_text())
    by_record = {MASTER_TABLE + 8*i: next(r for r in files if r['lba'] == lba and r['size'] == size)
                 for i, (size, lba) in enumerate(master_records())}
    slots, sources = [], {}
    for region, start in enumerate(starts):
        end = boundaries[boundaries.index(start) + 1]
        if not main.MBASE <= start < end <= table or (end - start) % 4:
            raise ValueError('invalid physical mode-2 table interval')
        for index, address in enumerate(range(start, end, 4)):
            descriptor = main.mword(address)
            slot = {'region': region, 'index': index, 'address': address, 'descriptor': descriptor}
            if descriptor:
                if descriptor not in by_record:
                    raise ValueError(f'mode-2 reference outside master table at {address:#x}')
                source = by_record[descriptor]
                slot['file'] = source['path']
                sources[source['path']] = source
            slots.append(slot)
    return table, slots, sources


def loader_source_census():
    """Physical mode-2 table references, including sources outside CLUSTERS."""
    import maindec as main
    from data_overlays import id_registry, load_groups
    table, slots, sources = loader_file_slots()
    files = json.loads((KIT / 'extracted/iso_files.json').read_text())
    graphs = build([path.rsplit('/', 1)[-1] for path in sorted(sources)])['overlays']
    reports = []
    for graph in graphs:
        name = graph['file'].rsplit('/', 1)[-1]
        reports.append({
            'file': graph['file'], 'lba': graph['lba'], 'size': graph['size'],
            'in_window_catalogue': name in CLUSTERS,
            'room_source_bound': graph['room_source_bound'],
            'candidate_entries': len(graph['entries']), 'possible_sites': len(graph['nodes']),
            'frontier': graph['frontier'],
            'source_frontier': ('no entries from the shared room probe; inspect header/loader contract'
                                if not graph['entries'] else
                                'room extent unresolved' if graph['room_source_bound']['upper_bound'] is None else None),
        })
    referenced = set(sources)
    roles = {r['path']: '04_PLAY character container' for r in id_registry()}
    roles.update({r['path']: 'group15 data companion' for r in load_groups()[15]['files']})
    return {'schema': 'suikoden-script-loader-census/1',
            'scope': 'physical intervals between the12 mode-2 table starts and their pointer table; '
                     'nonnull references have static loader and ISO checks, not campaign feasibility; '
                     'room probes and possible-path graphs retain their existing bounds; '
                     'other loaders, mutable cursors and out-of-domain region/index values are not closed',
            'main': {'lba': main.EXE_LBA, 'size': main.EXE_SIZE, 'header_bytes': main.EXE_HEADER,
                     'image_base': main.MBASE, 'pointer_table': table},
            'slots': slots, 'overlays': reports,
            'other_v_files': [{'file': r['path'], 'resource_role': roles.get(r['path'], 'unresolved')}
                             for r in files if r['path'].rsplit('/', 1)[-1].startswith('V')
                              and r['path'].endswith('.BIN') and r['path'] not in referenced]}


if __name__ == '__main__':
    report = (source_summary() if sys.argv[1:] == ['--census'] else
              loader_source_census() if sys.argv[1:] == ['--loader-census'] else
              build(sys.argv[1:] or list(CLUSTERS)))
    print(json.dumps(report, indent=2))

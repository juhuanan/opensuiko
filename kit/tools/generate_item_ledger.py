#!/usr/bin/env python3
"""Generate item identities, ledger and integrity pins from disc + runtime admission.

Run without flags to regenerate; --verify checks every output without writing.
The curated admission file owns enum order and reviewed policy, not source fields.
This tool represents admitted identities; it does not implement item effects.
"""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import struct

import disc
import item_tables
from preparation import stable_id

ROOT = Path(__file__).resolve().parents[2]
ADMISSION = 'kit/data/curated/item_runtime_admission.json'
ITEMS = 'game/src/items.zig'
LEDGER = 'game/assets/campaign_policies/item_shared_ledger.json'
CATALOGUE = 'game/src/item_ledger/catalogue.zig'
REPORT = 'kit/data/reports/item_identity_generation.json'
MENU = 'game/assets/combat_systems/menu_lists.json'
VOCABULARY = 'game/src/combat_systems/menu/vocabulary.zig'
PROGRESSION = 'game/assets/campaign/middle/item_progression.json'
MIDDLE_ASSETS = 'game/assets/campaign/middle.zig'
BEGIN = '// BEGIN GENERATED ITEM IDENTITIES\n'
END = '// END GENERATED ITEM IDENTITIES\n'
CATEGORIES = ('equipment_head', 'equipment_body', 'equipment_shield', 'equipment_feet_or_accessory',
              'consumable', 'stat_rune_piece', 'key_tool', 'weapon_fragment', 'appraised_decoration', 'key_item')
OWNERSHIP = ('personal_equipment', 'usable_bundle', 'usable_tool', 'weapon_attachment', 'appraisal', 'shared_key')
OPERATIONS = ('shared_acquire', 'shared_remove', 'shared_query', 'transfer_check', 'consume_preview')
FRAGMENTS = ('fire', 'water', 'wind', 'thunder', 'earth')
REASONS = (None, 'no_items_enum_member', 'appraisal_state_unsupported', 'use_count_mismatch', 'ambiguous_name')
EFFECTS = ('shared_acquire', 'shared_remove', 'deposit_identified')
STATUSES = ('bound', 'bound_to_storage_owner', 'blocked')


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode()


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def derive_items(admission):
    source = item_tables.items()
    if [row['id'] for row in source] != list(range(1, 180)):
        raise ValueError('MAIN item identity table differs from US v1.1')
    admitted = admission['runtime_source_ids']
    if (not admitted or any(type(i) is not int or not 1 <= i <= len(source) for i in admitted)
            or len(set(admitted)) != len(admitted)):
        raise ValueError('invalid or duplicate runtime admission')
    fragments = {row['source_item_id']: row['element'] for row in admission['weapon_fragments']}
    if len(fragments) != 5 or set(fragments.values()) != set(FRAGMENTS):
        raise ValueError('invalid reviewed weapon-fragment identities')
    labels = Counter(row['name'] for row in source)
    items = []
    for row in source:
        label = row['name']
        if not label or any(ord(c) < 32 for c in label):
            raise ValueError(f'invalid source item name: {row["id"]}')
        identity = stable_id(label)
        duplicate = labels[label] > 1
        if duplicate:
            identity += f'__source_{row["id"]}'
        flags = item_tables.half(row['addr'] + item_tables.ITEM_CLASS_OFF)
        kind = row['kind']
        equipment = flags & 0xE0
        tier = {0: 0, 0x1000: 1, 0x2000: 2, 0x4000: 3}.get(flags & 0x7000)
        if tier is None:
            raise ValueError('unknown appraisal family')
        usable = bool(flags & 8)
        fragment = fragments.get(row['id'])
        if equipment:
            category = {0x80: 'equipment_head', 0xA0: 'equipment_body', 0xC0: 'equipment_shield',
                        0xE0: 'equipment_feet_or_accessory'}.get(equipment)
            if category is None:
                raise ValueError('unknown equipment class')
            ownership = 'personal_equipment'
        elif tier:
            category, ownership = 'appraised_decoration', 'appraisal'
        elif fragment:
            category, ownership = 'weapon_fragment', 'weapon_attachment'
        elif usable:
            handler = kind >> 8
            if not 1 <= handler <= 13:
                raise ValueError('item use handler is outside the source code table')
            category, ownership = ('consumable', 'usable_bundle') if handler <= 4 else (
                ('stat_rune_piece', 'usable_bundle') if handler <= 10 else ('key_tool', 'usable_tool'))
        else:
            category, ownership = 'key_item', 'shared_key'
        slot = category.removeprefix('equipment_') if equipment else None
        items.append(dict(id=identity, source_item_id=row['id'], label=label,
                          category=category, ownership=ownership, price=row['price'],
                          max_uses=(kind & 255) if usable else 0,
                          usable=usable, requires_target=bool(flags & 2), battle_usable=bool(flags & 4),
                          appraisal_tier=tier, equipment_slot=slot,
                          equipment_type_mask=(kind & 255) if equipment else 0,
                          weapon_fragment=fragment, duplicate_label=duplicate,
                          supported_operations=list(OPERATIONS[:4]) + (['consume_preview'] if usable else []),
                          controller=dict(kind='items_enum', tag=identity) if row['id'] in admitted else
                                     dict(kind='unbound', reason='no_items_enum_member')))
    if len({row['id'] for row in items}) != len(items):
        raise ValueError('source identity collision')
    return source, items


def metadata_digest(items):
    rows = [{key: value for key, value in item.items() if key != 'controller'} for item in items]
    return sha256((json.dumps(rows, sort_keys=True, separators=(',', ':')) + '\n').encode())


def identity_digest(packet):
    """Version1 semantic wire digest; the native catalogue independently checks it."""
    data = bytearray(struct.pack('<H', len(packet['items'])))
    def byte(value):
        data.extend(struct.pack('<B', value))
    def text(value, width=1):
        raw = value.encode()
        data.extend(len(raw).to_bytes(width, 'little'))
        data.extend(raw)
    for item in packet['items']:
        data.extend(struct.pack('<HBBI', item['source_item_id'], CATEGORIES.index(item['category']) + 1,
                                OWNERSHIP.index(item['ownership']) + 1, item['price']))
        byte(item['max_uses'])
        byte(sum(int(item[key]) << shift for shift, key in enumerate(
            ('usable', 'requires_target', 'battle_usable', 'duplicate_label'))))
        byte(item['equipment_type_mask'])
        byte(item['appraisal_tier'])
        byte(FRAGMENTS.index(item['weapon_fragment']) + 1 if item['weapon_fragment'] else 0)
        controller = item['controller']
        byte(int(controller['kind'] == 'items_enum')); byte(REASONS.index(controller.get('reason')))
        text(controller.get('tag', ''))
        text(item['id'])
        text(item['label'], 2)
        byte(len(item['supported_operations']))
        for operation in item['supported_operations']:
            byte(OPERATIONS.index(operation) + 1)
    byte(packet['engine']['shared_capacity'])
    byte(len(packet['engine']['source_operations']))
    for operation in packet['engine']['source_operations']:
        byte(EFFECTS.index(operation['effect']) + 1)
        byte(STATUSES.index(operation['status']) + 1)
    byte(len(packet['categories']))
    for category in packet['categories']:
        byte(CATEGORIES.index(category['id']) + 1)
        data.extend(struct.pack('<H', category['count']))
    byte(len(packet['bindings']['degraded_runtime_tags']))
    for tag in packet['bindings']['degraded_runtime_tags']:
        text(tag)
    value = 0xCBF29CE484222325
    for part in data:
        value = ((value ^ part) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return f'{value:016x}'


def enum_tags(source):
    start = source.index('pub const Id = enum {')
    fields = source[start:].split('    pub fn ', 1)[0]
    tags = re.findall(r'^    ([a-z][a-z0-9_]*),$', fields, re.M)
    if not tags:
        raise ValueError('cannot locate existing runtime enum order')
    return tags


def enum_source(items):
    lines = [BEGIN.rstrip(), '// Generated by kit/tools/generate_item_ledger.py; edit the admission input.',
             'pub const Id = enum {']
    lines.extend(f'    {row["id"]},' for row in items)
    lines.extend(['    pub fn sourceId(self: Id) u16 {', '        return switch (self) {'])
    lines.extend(f'            .{row["id"]} => {row["source_item_id"]},' for row in items)
    lines.extend(['        };', '    }'])
    lines.extend(['    pub fn name(self: Id) []const u8 {', '        return switch (self) {'])
    lines.extend(f'            .{row["id"]} => {json.dumps(row["label"], ensure_ascii=False)},' for row in items)
    lines.extend(['        };', '    }', '    pub fn maxUses(self: Id) u16 {', '        return switch (self) {'])
    for uses in dict.fromkeys(row['max_uses'] for row in items if row['max_uses']):
        names = ', '.join('.' + row['id'] for row in items if row['max_uses'] == uses)
        lines.append(f'            {names} => {uses},')
    lines.extend(['            else => 0,', '        };', '    }'])
    for method, predicate in [('equipment', lambda row: row['equipment_slot'] is not None),
                              ('weaponPiece', lambda row: row['weapon_fragment'] is not None),
                              ('decoration', lambda row: row['appraisal_tier'] > 0)]:
        names = ', '.join('.' + row['id'] for row in items if predicate(row))
        lines.extend([f'    pub fn {method}(self: Id) bool {{', '        return switch (self) {'])
        if names:
            lines.append(f'            {names} => true,')
        lines.extend(['            else => false,', '        };', '    }'])
    lines.extend(['};', END.rstrip(), ''])
    return '\n'.join(lines)


def build_outputs(admission_bytes, items_source, catalogue_source):
    admission = json.loads(admission_bytes)
    if admission['schema'] != 'suikoden-item-runtime-admission/1':
        raise ValueError('unsupported runtime admission schema')
    source, items = derive_items(admission)
    if metadata_digest(items) != admission['identity_metadata_sha256']:
        raise ValueError('disc-derived identities differ from the reviewed metadata fingerprint')
    ordered = [items[i - 1] for i in admission['runtime_source_ids']]
    tags = [row['id'] for row in ordered]
    current = enum_tags(items_source)
    if tags[:len(current)] != current:
        raise ValueError('runtime enum admission must preserve the existing prefix; append new identities')
    catalogue = json.loads((ROOT / 'kit/data/catalogs/extracted/iso_files.json').read_text())
    main, = [row for row in catalogue if row['path'] == 'MAIN.EXE']
    raw = disc.extract(main['lba'], main['size'])
    provenance = dict(admission['source'])
    if sha256(raw) != provenance['main_file_sha256'] or sha256(item_tables.image()) != provenance['main_image_sha256']:
        raise ValueError('MAIN.EXE differs from the reviewed US v1.1 source')
    counts = Counter(row['category'] for row in items)
    owners = {row['category']: row['ownership'] for row in items}
    duplicates = [dict(label=label, source_item_ids=[row['source_item_id'] for row in items if row['label'] == label])
                  for label, count in Counter(row['label'] for row in items).items() if count > 1]
    bound = len(ordered)
    blockers = [dict(code='controller_identity_unbound', detail=f'{len(items) - bound} reviewed source identities have no runtime items.Id representation; shared-ledger operations on them fail with a typed error. All{counts["appraised_decoration"]} source appraisal identities retain complete unidentified state.'),
                *admission['blockers']]
    packet = dict(schema='suikoden-item-shared-ledger/1', source=provenance, items=items,
                  categories=[dict(id=category, ownership=owners[category], count=counts[category]) for category in CATEGORIES],
                  engine=admission['engine'],
                  bindings=dict(items_enum_bound=bound, unbound=len(items) - bound, runtime_tags=bound,
                                degraded_runtime_tags=[], unbound_treatment='typed_failure_without_runtime_identity'),
                  blockers=blockers, identities=dict(stable_id_policy='lower_snake_case; duplicate labels get __source_<item id>',
                      duplicate_label_groups=duplicates, trailing_space_labels=[row['id'] for row in items if row['label'].endswith(' ')],
                      weapon_fragments=[dict(element=row['weapon_fragment'], id=row['id'], source_item_id=row['source_item_id'])
                                        for row in items if row['weapon_fragment']]))
    packet['source']['identity_digest'] = identity_digest(packet)
    payload = json_bytes(packet)
    generated = enum_source(ordered)
    start = items_source.index(BEGIN) if BEGIN in items_source else items_source.index('pub const Id = enum {')
    end = items_source.index(END, start) + len(END) if END in items_source else items_source.index('pub const Stack =', start)
    output_items = items_source[:start] + generated + ('\n' if END not in items_source else '') + items_source[end:]
    pins = dict(expected_asset_sha256=sha256(payload), expected_identity_digest=packet['source']['identity_digest'])
    for name, value in pins.items():
        catalogue_source, changed = re.subn(rf'(pub const {name} = ")[^"]+(";)', rf'\g<1>{value}\2', catalogue_source)
        if changed != 1:
            raise ValueError('cannot update native item pin: ' + name)
    vocabulary = json.loads((ROOT / MENU).read_bytes())
    vocabulary['source']['items_source']['sha256'] = sha256(output_items.encode())
    vocabulary['capacities']['admitted_items'] = bound
    vocabulary['items'] = [dict(id=row['id'], label=row['label'], uses=row['max_uses'],
                               kind=admission['menu_kind_overrides'].get(str(row['source_item_id']),
                                   'consumable' if row['category'] == 'consumable' else 'item'),
                               source_records=[row['source_item_id']], ambiguous=row['duplicate_label'])
                           for row in ordered]
    vocabulary['long_labels']['item'] = [dict(id=row['id'], label=row['label'], cells=len(row['label']))
                                        for row in sorted(ordered, key=lambda row: (-len(row['label']), row['id']))[:8]]
    vocabulary['long_labels']['max_item_cells'] = max(len(row['label']) for row in ordered)
    blocked = next(row for row in vocabulary['blocked'] if row['id'] == 'source_item_records_without_port_identity')
    blocked.update(count=len(items) - bound,
                   detail=f'{len(items) - bound} pointer-indexed source descriptors have no stable items.Id; a menu must not invent a label for them.')
    vocabulary_source, changed = re.subn(r'pub const admitted_items: u16 = [0-9]+;',
                                        f'pub const admitted_items: u16 = {bound};', (ROOT / VOCABULARY).read_text())
    if changed != 1:
        raise ValueError('cannot update native menu identity count')
    progression = json.loads((ROOT / PROGRESSION).read_bytes())
    if progression['item_source']['path'] != LEDGER:
        raise ValueError('unexpected chapter item source')
    progression['item_source']['sha256'] = sha256(payload)
    progression['content_sha256'] = ''
    progression['content_sha256'] = sha256((json.dumps(progression, sort_keys=True, separators=(',', ':')) + '\n').encode())
    progression_bytes = json_bytes(progression)
    middle_source, changed = re.subn(r'(pub const item_progression = struct \{.*?pub const asset_sha256 = ")[^"]+(";)',
                                     rf'\g<1>{sha256(progression_bytes)}\2', (ROOT / MIDDLE_ASSETS).read_text(), flags=re.S)
    if changed != 1:
        raise ValueError('cannot update chapter item packet pin')
    outputs = {ITEMS: output_items.encode(), LEDGER: payload, CATALOGUE: catalogue_source.encode(),
               MENU: json_bytes(vocabulary), VOCABULARY: vocabulary_source.encode(),
               PROGRESSION: progression_bytes, MIDDLE_ASSETS: middle_source.encode()}
    report = dict(schema='suikoden-item-identity-generation/1', generator='kit/tools/generate_item_ledger.py',
                  admission_sha256=sha256(admission_bytes),
                  output_sha256={path: sha256(data) for path, data in outputs.items()},
                  helpers_sha256={name: sha256((ROOT / 'kit/tools' / name).read_bytes())
                                  for name in ('generate_item_ledger.py', 'item_tables.py', 'war_text.py', 'disc.py')},
                  source=dict(file=main['path'], lba=main['lba'], size=main['size'],
                              sha256=sha256(raw), image_sha256=sha256(item_tables.image()),
                              decoder='item_tables.py + war_text.py; PS-X header excluded from image addresses'),
                  enum_order=tags, identities=len(items), bound=bound, unbound=len(items) - bound,
                  ledger_sha256=sha256(payload), identity_digest=packet['source']['identity_digest'],
                  identity_metadata_sha256=metadata_digest(items),
                  records=[dict(source_item_id=row['id'], file_offset=2048 + row['addr'] - item_tables.MAIN_BASE,
                                size=row['stride']) for row in source])
    outputs[REPORT] = json_bytes(report)
    return outputs


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--verify', action='store_true', help='check generated outputs without writing')
    args = parser.parse_args()
    outputs = build_outputs((ROOT / ADMISSION).read_bytes(), (ROOT / ITEMS).read_text(), (ROOT / CATALOGUE).read_text())
    stale = [path for path, data in outputs.items() if not (ROOT / path).is_file() or (ROOT / path).read_bytes() != data]
    if args.verify:
        if stale:
            raise SystemExit('Stale item generation: ' + ', '.join(stale))
    else:
        for path in stale:
            (ROOT / path).parent.mkdir(parents=True, exist_ok=True)
            (ROOT / path).write_bytes(outputs[path])
    print(f'Item generation {"verified" if args.verify else "complete"}: 179 identities; {len(json.loads((ROOT / ADMISSION).read_bytes())["runtime_source_ids"])} admitted; {len(stale)} outputs {"stale" if args.verify else "updated"}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

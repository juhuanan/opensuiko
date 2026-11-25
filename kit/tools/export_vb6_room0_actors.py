"""Export village actor identities and animation metadata without pixels."""
import hashlib
import json
from pathlib import Path

import area_scene as scene
import opening_audience
from export_first_room import source, collision_sources, scenery_query

ROOT = Path(__file__).resolve().parents[2]


def identity(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def export():
    raw, origin = source('/VB6.BIN')
    population = json.loads((ROOT / 'game/assets/scenes/population/vb6_room0.json').read_text())
    event = json.loads((ROOT / 'game/assets/events/vb6_room0_initializer.json').read_text())
    candidates = [e for e in population['entities'] if e['population_candidate'] and e['classification']['pointer_state'] == 'present']
    actors, source_actors = opening_audience.actor_bindings(raw, 0, bytearray(240))
    assert [e['source_order'] for e in candidates] == [7, 8, 9]
    assert [e['entity'] for e in source_actors] == [7, 8, 9]
    assert len(actors) == len(candidates)
    bindings = dict(schema='suikoden-vb6-room0-actor-bindings/1',
                    population_sha256=population['content_sha256'],
                    event_sha256=event['content_sha256'],
                    slots=[dict(slot=i, actor=e['id'], resource=e['resource_id'],
                                source_character_id=e['source_character_id'])
                           for i, e in enumerate(candidates)])
    bindings['content_sha256'] = identity(bindings)
    rows = []
    for slot, (entity, actor, proof) in enumerate(zip(candidates, actors, source_actors, strict=True)):
        assert proof['native_character'] == entity['source_character_id']
        assert actor['x'] == entity['position']['x'] and actor['y'] == entity['position']['y']
        rows.append(dict(id=entity['id'], entity=entity['source_order'], slot=slot,
                         resource=entity['resource_id'], graphic=f"vb6_room0_character_{entity['source_character_id']:03d}",
                         x=actor['x'], y=actor['y'], speed=actor['motion'], variant=actor['variant'],
                         auto_animate=actor['auto_animate'], conditions=entity['classification']['terms']))
    packet = dict(schema='suikoden-field-ordinary-actors/1', scene='vb6_room0',
                  binding_sha256=bindings['content_sha256'], population_sha256=population['content_sha256'],
                  event_sha256=event['content_sha256'], actors=rows)
    packet['content_sha256'] = identity(packet)
    section = scene.section_off(raw, scene.room_record(raw, 0)['section'])
    resources = scene.character_bindings(raw, section)
    animations = []
    for native_id in sorted({row['source_character_id'] for row in bindings['slots']}):
        context = resources[native_id]['context']
        table = scene.ptr_at(raw, context + 20)
        clips = []
        for variant in range(4):
            descriptor = scene.ptr_at(raw, table + 4 * variant)
            clips.append(dict(flags=raw[descriptor + 1],
                ticks=[raw[descriptor + 5 + 2 * i] or 256 for i in range(raw[descriptor])],
                bounds=[dict(width=raw[sheet + 2], height=raw[sheet + 3])
                        for i in range(raw[descriptor])
                        for sheet in (scene.descriptor_sheet(raw, context, variant, i)['sheet'],)]))
        animations.append(dict(graphic=f'vb6_room0_character_{native_id:03d}', clips=clips))
    timing = dict(schema='suikoden-field-ordinary-animations/1', scene='vb6_room0', animations=animations)
    objects = collision_sources(raw, section)
    ground_rows = []
    for actor in rows:
        query, surface = scenery_query(objects, actor['x'] // 8, actor['y'] // 8, 0)
        if surface:
            raise ValueError('village actor has unsupported initial surface')
        ground_rows.append(dict(actor=actor['id'], x=actor['x'], y=actor['y'], query=query))
    ground = dict(schema='suikoden-vb6-room0-initial-ground/1', scene='vb6_room0',
                  actors_sha256=packet['content_sha256'], actors=ground_rows)
    ground['content_sha256'] = identity(ground)
    proof = dict(schema='suikoden-vb6-room0-actor-proof/1', source=origin,
                 bindings_sha256=bindings['content_sha256'], actors_sha256=packet['content_sha256'],
                 source_actors=source_actors, resources=[resources[k] for k in sorted({136, 148})],
                 scope='Source actor identity and timing metadata only; pixels and live field construction remain unreviewed.')
    return bindings, packet, timing, proof, ground


def write():
    outputs = export()
    for path, value in zip((ROOT / 'game/assets/scenes/bindings/vb6_room0.json',
                            ROOT / 'game/assets/field_ordinary_actors_vb6_room0.json',
                            ROOT / 'game/assets/field_ordinary_animations_vb6_room0.json',
                            ROOT / 'kit/data/reports/vb6_room0_actors.json',
                            ROOT / 'game/assets/field_vb6_room0_initial_ground.json'), outputs, strict=True):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value, indent=2) + '\n')


if __name__ == '__main__':
    write()

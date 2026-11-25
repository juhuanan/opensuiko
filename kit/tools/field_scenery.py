"""Export decoded scenery definitions for the native field-instance owner."""
import argparse
import sys
from pathlib import Path

import area_scene as scene
from export_common import atomic_write, serialize
from export_first_room import collision_sources, combine_ground, scenery_query, source, terrain_query, walkable_grid


def validate_model(model):
    fields = {'schema', 'columns', 'rows', 'initial_count', 'terrain', 'objects'}
    if not isinstance(model, dict) or set(model) != fields or model['schema'] != 'suikoden-field-scenery/1':
        raise ValueError('invalid field scenery model')
    columns, rows, count = (model[key] for key in ('columns', 'rows', 'initial_count'))
    if (any(type(value) is not int for value in (columns, rows, count))
            or not 2 <= columns <= 256 or not 2 <= rows <= 256
            or not isinstance(model['objects'], list) or not 0 <= count <= min(1024, len(model['objects']))
            or len(model['objects']) > 1280 or not isinstance(model['terrain'], str)
            or len(model['terrain']) != columns * rows or any(value not in '0123456789abcdef' for value in model['terrain'])):
        raise ValueError('invalid field scenery dimensions or terrain')
    for obj in model['objects']:
        if (not isinstance(obj, dict) or set(obj) != {'x', 'y', 'width_cells', 'height_cells', 'layer', 'collides', 'mask'}
                or any(type(obj[key]) is not int for key in ('x', 'y', 'width_cells', 'height_cells', 'layer'))
                or any(not 0 <= obj[key] <= 2040 or obj[key] % 8 for key in ('x', 'y'))
                or any(not 0 <= obj[key] <= 255 for key in ('width_cells', 'height_cells', 'layer'))
                or type(obj['collides']) is not bool or not isinstance(obj['mask'], str)
                or len(obj['mask']) != obj['width_cells'] * obj['height_cells']
                or any(value not in '0123' for value in obj['mask'])):
            raise ValueError('invalid field scenery object')


def export_model(data, room, templates=(), relocations=()):
    """Keep static definitions first, then referenced templates in source order."""
    record = scene.room_record(data, room)
    if record is None:
        raise ValueError('unknown scenery room')
    section = scene.section_off(data, record['section'])
    records = scene.scenery_records(data, section)
    initial_count = len(records)
    for template in sorted(set(templates)):
        record = scene.scenery_template(data, section, template)
        records.append(dict(record, index=len(records)))
    for index, x, y in relocations:
        records.append(dict(records[index], index=len(records), x_half=x, y_half=y))
    columns, rows = scene.u16(data, section) * 2, scene.u16(data, section + 2) * 2
    terrain = ''.join(format(terrain_query(data, section, x, y), 'x')
                      if x < columns - 1 and y < rows - 1 else 'f'
                      for y in range(rows) for x in range(columns))
    objects = [dict(x=obj['x_half'] * 8, y=obj['y_half'] * 8,
                    width_cells=obj['width'], height_cells=obj['height'], layer=obj['b4'],
                    collides=obj['order'] not in (0, 1),
                    mask=''.join(str(value) for value in obj['mask']))
               for obj in collision_sources(data, section, object_records=records)]
    model = dict(schema='suikoden-field-scenery/1', columns=columns, rows=rows,
                 initial_count=initial_count, terrain=terrain, objects=objects)
    validate_model(model)
    return model


def reference(data, room, templates, states):
    """Re-derive native conformance samples with the established Python queries."""
    templates = sorted(set(templates))
    model = export_model(data, room, templates)
    section = scene.section_off(data, scene.room_record(data, room)['section'])
    samples = []
    for sample in states:
        records = scene.scenery_records(data, section)
        for object_id in sample['appended']:
            if type(object_id) is not int or not model['initial_count'] <= object_id < len(model['objects']):
                raise ValueError('unknown reference scenery template')
            record = scene.scenery_template(data, section, templates[object_id - model['initial_count']])
            records.append(dict(record, index=len(records)))
        for index in sample['staged']:
            if type(index) is not int or not 0 <= index < len(records):
                raise ValueError('unknown reference scenery instance')
            records[index] = dict(records[index], x_half=255, y_half=255)
        objects = collision_sources(data, section, object_records=records)
        width, height, ground = walkable_grid(data, section, object_records=records)
        upper = ''.join('1' if x < width - 1 and y < height - 1 and
                        combine_ground(terrain_query(data, section, x, y), *scenery_query(objects, x, y, 1), 1) == 0 else '0'
                        for y in range(height) for x in range(width))
        samples.append(dict(staged=sample['staged'], appended=sample['appended'], ground=ground, upper=upper))
    return dict(model=model, samples=samples)


def room_templates(data, room):
    """Collect sorted 0x3E scenery template indices referenced by room initializers."""
    from event_script_decode import decode_stream
    record = scene.room_record(data, room)
    if record is None:
        raise ValueError('unknown scenery room')
    templates = set()
    for entity in scene.entities(data, record):
        pc = entity['stream_offsets'][2]
        if pc is None or not (entity['flags'] & 0x10):
            continue
        for _, opcode, args, _ in decode_stream(data, start=pc, max_insns=64):
            if opcode == 0x3E:
                templates.add(args[0])
            if opcode in (0x31, 0xFD):
                break
    return tuple(sorted(templates))


def room_relocations(data, room):
    """Resolve the qualified alternate doorway from its room-entry script."""
    if room != 5:
        return ()
    entities = scene.entities(data, scene.room_record(data, room))
    if len(entities) <= 4 or entities[4]['stream_offsets'][2] != 0x5BEF8:
        return ()
    stream = data[0x5BEF8:0x5BF02]
    if stream != bytes.fromhex('30 40 fe 01 14 02 0f 00 31 fd'):
        raise ValueError('Alternate doorway initializer changed')
    return (tuple(stream[3:6]),)


def room_model(data, room):
    return export_model(data, room, room_templates(data, room), room_relocations(data, room))


def bind_existing_template_draws(data, room, templates, draws, relocations=()):
    """Reuse atlas pieces when a template shares a static object's room-local descriptor."""
    if not templates and not relocations:
        return
    record = scene.room_record(data, room)
    section = scene.section_off(data, record['section'])
    static = scene.scenery_records(data, section)
    by_object = {}
    for draw in draws:
        if (object_id := draw.get('scenery_object')) is not None:
            by_object.setdefault(object_id, []).append(draw)
    donors = {}
    for obj in static:
        pieces = by_object.get(obj['index'])
        if pieces and all(draw.get('hidden_by') is None and draw.get('room_conditions') is None for draw in pieces):
            donors.setdefault(obj['type'], obj)
    template_objects = [scene.scenery_template(data, section, i) for i in sorted(set(templates))]
    bindings = [(obj, donors.get(obj['type'])) for obj in template_objects]
    for index, x, y in relocations:
        donor = static[index]
        if donor['index'] not in by_object:
            raise ValueError('Relocated scenery has no source draw')
        bindings.append((dict(donor, x_half=x, y_half=y), donor))
    for object_id, (obj, donor) in enumerate(bindings, len(static)):
        if object_id in by_object:
            continue
        if donor is None:
            continue
        dx = (obj['x_half'] - donor['x_half']) * 8
        dy = (obj['y_half'] - donor['y_half']) * 8
        depth = scene.GROUND_DEPTH_ORIGIN - scene.scenery_tag(obj['order'], record)
        for draw in by_object[donor['index']]:
            bound = dict(draw, x=draw['x'] + dx, y=draw['y'] + dy, depth=depth, scenery_object=object_id)
            if draw.get('frames'):
                bound['frames'] = [dict(frame, x=frame['x'] + dx, y=frame['y'] + dy) for frame in draw['frames']]
            draws.append(bound)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('file', help='disc path or unique file suffix')
    parser.add_argument('room', type=int)
    parser.add_argument('--template', type=int, action='append', default=[])
    parser.add_argument('--out', type=Path)
    args = parser.parse_args()
    data, origin = source(args.file)
    payload = serialize(dict(source=origin, room=args.room, model=export_model(data, args.room, args.template)))
    if args.out and args.out != Path('-'):
        atomic_write(args.out, payload)
    else:
        sys.stdout.buffer.write(payload)


if __name__ == '__main__':
    main()

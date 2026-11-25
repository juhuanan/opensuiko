#!/usr/bin/env python3
"""Export static regional/point sound commands; do not infer retained bank state."""
import argparse
import hashlib
import json
from pathlib import Path
import struct

import maindec


WINDOWS = (
    (0x80127a4c, 0x80127af0, 'cb087742df37d5a78c737f0680c0332e73f4cc9057a2e9c307bf4400d9b6dfb9'),
    (0x801311f4, 0x8013127c, '6a7a4fe071141c273e1ce29851747e5d45e834487710d46d8399a27cdecf1c36'),
    (0x800c512c, 0x800c53c0, '9fd55a4a7462f4a8f968f80b8ee6fece3b6fca458293bcc807bb2ed3f8731b02'),
    (0x800c7438, 0x800c7948, '90871b5f517352ca5414bdc5ec9ee6ea61b3687a0edbd391c300e4c5d3a2c063'),
    (0x800c50e4, 0x800c512c, 'fb4e1dfb4ac4a341bfb75b1d3aa936a5fd7244dcebd31723ba23b4cd245d78a4'),
)


def build():
    image = maindec.body()

    def read(address, size):
        offset = address - maindec.MBASE
        if offset < 0 or offset + size > len(image):
            raise ValueError('sound context outside MAIN image')
        return image[offset:offset + size]

    for start, end, digest in WINDOWS:
        if hashlib.sha256(read(start, end-start)).hexdigest() != digest:
            raise ValueError('sound context consumer changed')

    def command(value):
        result = dict(command=value, bank=None)
        if 0x21 <= value < 0x50:
            address = 0x80164834 + 32*(value-0x21)
            row = read(address, 32)
            if row[1] != 2 or row[17] != 2:
                raise ValueError('regional command does not load slot 2')
            _, _, va_size, va_lba, _, _, vb_size, vb_lba = struct.unpack('<8I', row)
            result['bank'] = dict(id=f'field_bank_{value:02x}', va_lba=va_lba,
                                  va_size=va_size, vb_lba=vb_lba, vb_size=vb_size)
        return result

    regions = []
    for region in range(12):
        default_address = 0x8016f364 + 2*region
        default = command(struct.unpack('<h', read(default_address, 2))[0])
        table = struct.unpack('<I', read(0x80170064+4*region, 4))[0]
        points = []
        for index in range(64):
            address = table + 14*index
            record = read(address, 14)
            if record[0] == 8:
                break
            points.append(dict(point=index, source_address=address+10,
                               **command(struct.unpack_from('<h', record, 10)[0])))
        else:
            raise ValueError('sound point table has no terminator')
        regions.append(dict(region=region, default_source_address=default_address,
                            default=default, points=points))
    entries = [struct.unpack('<I', read(0x800c0b70+4*index, 4))[0] for index in range(9)]
    if entries != [0x800c74ec, 0x800c7500, 0x800c7510, 0x800c7520, 0x800c7530,
                   0x800c7540, 0x800c7550, 0x800c7560, 0x800c7570]:
        raise ValueError('sound bank state dispatch changed')
    loader = dict(first_command=0x21, end_command=0x50, descriptor_stride=32,
                  busy_flags=[0x80179beb, 0x80179bf3, 0x80179c00],
                  pending_command=0x80179cd8, state=0x80179c00,
                  descriptor=0x8017aaf0, chunk_bytes=0x1d800,
                  states=[dict(id=index, entry=entry) for index, entry in enumerate(entries)],
                  scope='Admission requires all three busy bytes zero. Header and body '
                        'use their own descriptor slot byte; state8 polls transfer completion '
                        'before returning idle or selecting another body chunk. A command '
                        'request or field cached-command write is not proof of completion.')
    return dict(schema='suikoden-battle-sound-context/2', regions=regions, loader=loader,
                provenance=dict(file='MAIN.EXE', lba=maindec.EXE_LBA,
                                size=maindec.EXE_SIZE, decoder='battle_sound_context.py/2',
                                image_sha256=hashlib.sha256(image).hexdigest(),
                                consumers=[dict(start=a, end=b, sha256=h) for a, b, h in WINDOWS]),
                scope='Ordinary world initialization and field-entry commands only. '
                      'Non-bank commands do not establish an empty bank. Special entry modes, '
                      'later script changes and battle handoff need separate qualification.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    packet = build()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(packet, indent=2)+'\n')

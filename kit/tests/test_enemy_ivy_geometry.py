"""Independent signed packet math for the source Ivy strip and leaf writers."""
import json
import math
from pathlib import Path
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'kit/tools'))
from export_first_room import source


def signed(value, bits=32):
    return (value + 2**(bits-1)) % 2**bits - 2**(bits-1)


def quotient(a, b):
    return (1 if a >= 0 else -1) * (abs(a)//b)


def root_reference(value, table):
    if value == 0:return 0
    leading = 32-value.bit_length()
    even = leading-leading%2
    exponent = (19-even)//2
    normalized = value*2**(even-24) if even >= 24 else value//2**(24-even)
    calibrated = table[normalized-64]
    return calibrated*2**exponent if exponent >= 0 else calibrated//2**(-exponent)


def basis_reference(delta, table):
    x, y = delta
    squared = signed((x*x+y*y)*4096)
    if squared <= 0:return None
    root = root_reference(squared, table)
    return [signed(quotient(signed(v*2**24), root), 16) for v in (x, -y, y, x)]


def quad_reference(points, block, index, anchor, extent, table):
    if index >= 18 or block['c'][2] <= 0:return None
    bias = quotient(signed(block['d'][0]*2**14), signed(block['c'][2]*4096))
    vertices = []
    if index < 12:
        basis = basis_reference([b-a for a, b in zip(points[index][:2], points[index+1][:2])], table)
        if basis is None:return None
        matrix = [basis[0], basis[1], 0, basis[2], basis[3], 0, 0, 0, 4096]
        matrix = [signed(signed(v*block['d'][i%3])//4096, 16) for i, v in enumerate(matrix)]
        for x, y in ((0, 0), (16, 0), (0, 8), (16, 8)):
            view = [(block['c'][axis]*4096 + sum(a*b for a, b in zip(matrix[3*axis:3*axis+3], (x, y, 0))))//4096 for axis in range(3)]
            local = [max(-1024, min(1023, 1024*v//max(512, view[2]))) for v in view[:2]]
            vertices.append([signed(points[index][0]+local[0]+bias, 16), signed(points[index][1]+local[1], 16)])
        depth = points[index][2]//4*4
    else:
        group, position = divmod(index-12, 3)
        sample = (10, 8, 6, 9, 7, 5)[index-12]
        scale = [quotient(signed(v*1024), block['c'][2]) for v in block['d'][:2]]
        for x, y in ((0, 0), (extent[0], 0), (0, extent[1]), tuple(extent)):
            vertices.append([signed(points[sample][0]+bias+quotient(signed((x-anchor[0])*scale[0]), 4096), 16),
                             signed(points[sample][1]+quotient(signed((y-anchor[1])*scale[1]), 4096), 16)])
        depth = 0
    return dict(vertices=vertices, depth=depth)


def vectors():
    main, _ = source('MAIN.EXE')
    base = struct.unpack_from('<I', main, 24)[0]
    table = struct.unpack_from('<192h', main, 2048+0x8017242c-base)
    inputs = sorted({0, 1, 4095, 4096, 4097, 0x7fffffff,
                     *(v for n in range(31) for v in (2**n-1, 2**n, min(0x7fffffff, 2**n+1))),
                     *(v << 18 for v in range(64, 256))})
    deltas = [[0, 0], [800, 800]] + [[x, y] for x in (-31, -13, -1, 0, 1, 13, 31) for y in (-19, 0, 19)]
    cases = []
    for c, d, points in (
        ([0, 0, 1024], [4864]*3, [[100+11*k, 180-k*k//3, 1024+3*k] for k in range(13)]),
        ([3, -7, 768], [3840, 5120, 4096], [[-80-7*k, 40+9*k, 800+k] for k in range(13)]),
        ([0, 0, 1024], [3840]*3, [[160, 120, 1024] for k in range(13)]),
    ):
        block = dict(position=[0]*3, angles=[0]*3, c=c, d=d)
        parts = []
        for i in range(19):
            anchor = [1, 3] if i < 12 else ([7, 8] if i < 15 else [7, 0])
            extent = [16, 8] if i < 12 else [15, 15]
            parts.append(dict(index=i, anchor=anchor, extent=extent, expected=quad_reference(points, block, i, anchor, extent, table)))
        cases.append(dict(block=block, points=points, parts=parts))
    return dict(schema='suikoden-ivy-geometry-witness/1',
                roots=[dict(input=v, expected=root_reference(v, table)) for v in inputs],
                bases=[dict(delta=v, expected=basis_reference(v, table)) for v in deltas], quads=cases)


class IvyGeometryTests(unittest.TestCase):
    def test_native_geometry_witness_is_current(self):
        self.assertEqual(vectors(), json.loads((ROOT/'game/tests/fixtures/ivy_geometry.json').read_text()))

    def test_leaf_bucket_samples_extents_and_degenerate_segment_are_distinct(self):
        packet = vectors()
        self.assertEqual(packet['bases'][0]['expected'], None)
        for row in packet['quads']:
            for part in row['parts'][12:18]:self.assertEqual(part['expected']['depth'], 0)
            self.assertIsNone(row['parts'][18]['expected'])
        self.assertTrue(all(p['expected'] is None for p in packet['quads'][2]['parts'][:12]))
        self.assertTrue(all(p['expected'] is not None for p in packet['quads'][2]['parts'][12:18]))


if __name__ == '__main__':unittest.main()

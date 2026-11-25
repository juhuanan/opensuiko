#!/usr/bin/env python3
"""Indexed script-flag aliases into the persistent character array.

The source census uses the existing bounded room/possible-path graph and tracked
dialogue exclusions. It cannot prove campaign occurrence or global absence.
"""
import json

import data_overlays as D
import event_script_reachability as E


def aliases():
    return [{'id': target - 0x280, 'row': row, 'offset': off, 'gs_offset': target}
            for row in range(78) for off in (0x17, 0x1E, 0x4E, 0x4F)
            for target in [0x294 + 80*row + off] if 0x280 <= target <= 0x37F]


def source_census():
    loader = E.loader_source_census()
    graphs = E.build([r['file'].rsplit('/', 1)[-1] for r in loader['overlays']])['overlays']
    sites, frontiers = [], []
    for graph in graphs:
        data = D.read(graph['file'])
        for node in graph['nodes']:
            off = node['offset']
            if node.get('opcode') == 0x16 and node.get('end') == off + 3:
                sites.append({'file': graph['file'], 'offset': off,
                              'id': data[off + 1], 'bits': data[off + 2]})
        frontiers.extend({'file': graph['file'], **f} for f in graph['frontier'])
    return {'scope': 'mode-2 loader sources; bounded room candidates and possible paths; '
                     'tracked dialogue/data exclusions; unresolved callbacks, room extents, '
                     'other loaders and mutable cursors prevent a global operand-domain claim',
            'sources': len(graphs), 'aliases': aliases(), 'opcode16_sites': sites,
            'graph_frontiers': frontiers,
            'source_frontiers': [{'file': r['file'], 'reason': r['source_frontier']}
                                 for r in loader['overlays'] if r['source_frontier']]}


if __name__ == '__main__':
    print(json.dumps(source_census(), indent=2))

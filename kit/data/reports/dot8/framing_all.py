import os, sys
TOOLS = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))), 'kit', 'tools')
sys.path.insert(0, TOOLS)
import dot8_probe as P
out = []
for r in P._iso_listing():
    if not r['path'].endswith('.8'):
        continue
    d = P.read_dot8(r['path'].split('/')[-1])
    st = P.record_stats(d)
    nd = st['non_data']
    cats = sorted((c, i) for i, t, c in nd)
    out.append((r['path'].split('/')[-1], st['records'], cats))
for name, n, cats in out:
    print('%-14s records=%7d  non-0x02: %s' % (name, n, ' '.join('%02x@%d' % (c, i) for c, i in cats)))
print('files=%d records=%d non-0x02=%d' % (len(out), sum(n for _, n, _ in out), sum(len(c) for _, _, c in out)))

import os, struct, glob, sys
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
def targets():
    fs = sorted(glob.glob(os.path.join(ROOT,'kit','extracted','bin_overlays','DATA','**','*.BIN'), recursive=True))
    fs += [os.path.join(ROOT,'kit','work','mainexe_code.bin')]
    return fs
def scan(vals, files=None):
    files = files or targets()
    pats = {v: struct.pack('<I', v) for v in vals}
    res = {v: [] for v in vals}
    for f in files:
        d = open(f,'rb').read()
        for v,p in pats.items():
            i = d.find(p)
            while i >= 0:
                res[v].append((f, i))
                i = d.find(p, i+1)
    return res

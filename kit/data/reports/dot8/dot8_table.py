"""Read the 67-entry .8 resource table out of MAIN.EXE (on-disc bytes, no
relocation involved: it is a static table) and match entries to ISO .8 files
by LBA. Field layout established from the loader code at 0x800C85C4/0x800C7C14:
  +0 u32 lba ; +4 u16 X ; +6 u16 n1 ; +8 u16 n2 ; +0xA u16 Y
(the loader reads +0 with lw, +6/+8 with lhu, and byte +0xA as the per-area
scale written to 0x80179C0C)."""
import json, os, struct, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mx

TABLE_VA = 0x80164E68
ENTRIES = 70
STRIDE = 12

def entries():
    out = []
    for i in range(ENTRIES):
        o = TABLE_VA + STRIDE*i - mx.BASE
        lba = struct.unpack_from('<I', mx.BODY, o)[0]
        X, n1, n2, Y = struct.unpack_from('<HHHH', mx.BODY, o+4)
        out.append(dict(idx=i, lba=lba, X=X, n1=n1, n2=n2, Y=Y))
    return out

def iso_names():
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
    d = json.load(open(os.path.join(root, 'kit', 'extracted', 'iso_files.json')))
    return {r['lba']: r for r in d if not r.get('dir') and r['path'].endswith('.8')}

"""Build the source-art strip used by the native battle review.

Review aid only. Reads the exported effect metadata and recovered palette; no
accepted-tree writes.
"""
import json,sys
from pathlib import Path
from PIL import Image
ROOT = Path(__file__).resolve().parents[2];sys.path.insert(0,str(ROOT/'kit/tools'));import battle_bin
s,a,e,d=battle_bin.parse();blobs=[x for x in a if 1 in x['sections']]
EFFECT = int(sys.argv[2]) if len(sys.argv) > 2 else 0
with open(ROOT/'kit/data/reports/spell_effect_sources.json') as fh:
    rep=json.load(fh)['effects'][EFFECT]
by={p['id']:p for p in rep['pieces']}
def entry_img(en):
 from spell_effect_entries import entry_image
 return entry_image(blobs[en[2]]['atlas'], blobs[9]['atlas'], en)

def img(pid):
 p=by[pid];w=max([e[0]+e[4]+1 for e in p['entries']]+[p['header'][2],1]);h=max([e[1]+e[5]+1 for e in p['entries']]+[p['header'][3],1])
 piece=Image.new('RGBA',(w,h),(0,0,0,0))
 for en in p['entries']:
  piece.alpha_composite(entry_img(en),(en[0],en[1]))
 out=Image.new('RGBA',(128,128),(0,0,0,0));out.alpha_composite(piece,((128-w)//2,(128-h)//2));return out

MODE = sys.argv[1] if len(sys.argv) > 1 else "impact"
if MODE == "drops_cast":
 seq = []
 for f in rep["animations"][0]["frames"]: seq += [f["piece"]] * f["ticks"]
 seq = (seq * 20)[:20]; out_name = "source_drops_cast.png"
elif MODE == "drops_impact":
 seq = []
 for f in rep["animations"][3]["frames"]: seq += [f["piece"]] * f["ticks"]
 seq = (seq * 3)[:20]; out_name = "source_drops_impact.png"
elif MODE == "cast":
 seq = ["piece_0"] * 20; out_name = "source_cast.png"
elif MODE == "projectile":
 seq = []
 for f in rep["animations"][8]["frames"]: seq += [f["piece"]] * f["ticks"]
 seq = (seq * 20)[:20]; out_name = "source_projectile.png"
else:
 seq = []
 for f in rep["animations"][7]["frames"]: seq += [f["piece"]] * f["ticks"]
 seq = seq[:34]; out_name = "source_flaming.png"
frames = [img(pid) for pid in seq]
out = Image.new("RGBA", (128 * len(frames), 128), (0, 0, 0, 0))
for i, im in enumerate(frames): out.alpha_composite(im, (128 * i, 0))
out.save(ROOT / "kit/work/build/battle_review" / out_name); print(MODE, len(frames))

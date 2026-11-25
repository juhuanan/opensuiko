"""Headless source-palette effect preview.

Renders one exported Flaming Arrows animation with the embedded BATTLE palette
and corrected piece x/y crops. Review aid only; not runtime and not promoted.
"""
import argparse, json,sys
from pathlib import Path
from PIL import Image,ImageDraw
ROOT = Path(__file__).resolve().parents[2];sys.path.insert(0,str(ROOT/'kit/tools'))
import battle_mock as bm, battle_bin
with open(ROOT/'kit/work/build/canonical/battle/trial.json') as fh:
    T=json.load(fh)
atlas=Image.open(ROOT/'kit/work/build/canonical/battle/actors.png').convert('RGBA')
floor=Image.open(ROOT/'kit/work/build/canonical/battle/floor.png').convert('RGBA')
s,a,e,d=battle_bin.parse(); blobs=[x for x in a if 1 in x['sections']]
ACTION = int(sys.argv[1]) if len(sys.argv) > 1 else 7
EFFECT = int(sys.argv[2]) if len(sys.argv) > 2 else 0
with open(ROOT/'kit/data/reports/spell_effect_sources.json') as fh:
    ALL = json.load(fh)
rep = ALL['effects'][EFFECT]
piece_by={p['id']:p for p in rep['pieces']}
def entry_img(en):
 from spell_effect_entries import entry_image
 return entry_image(blobs[en[2]]['atlas'], blobs[9]['atlas'], en)

def piece_img(pid):
 p=piece_by[pid];w=max([e[0]+e[4]+1 for e in p['entries']]+[p['header'][2],1]);h=max([e[1]+e[5]+1 for e in p['entries']]+[p['header'][3],1])
 out=Image.new('RGBA',(w,h),(0,0,0,0))
 for en in p['entries']:
  out.alpha_composite(entry_img(en),(en[0],en[1]))
 return out

std=bm.camera_block(0);fin=[-160,0,0,-768,0,608,0,0,1024,5120,5120,5120]
def lerp(a,b,t):return [round(a[i]+(b[i]-a[i])*t) for i in range(12)]
def proj(p,b):
 R=bm.scale_matrix(bm.rot_matrix(b[3:6]),b[9:12]);TR=tuple(b[6:9])
 v=[((TR[i]<<12)+sum(R[i*3+j]*p[j] for j in range(3)))>>12 for i in range(3)]
 if v[2]<=1:return None
 return (320+1179.648*v[0]/v[2],240+1179.648*v[1]/v[2])
def sprite(im,prof,pt,scale):
 r=prof['sprite'];x=int(pt[0]-r['anchor_x']*scale);y=int(pt[1]-r['anchor_y']*scale)
 w=max(1,int(r['rect']['w']*scale));h=max(1,int(r['rect']['h']*scale))
 im.alpha_composite(atlas.crop((r['rect']['x'],r['rect']['y'],r['rect']['x']+r['rect']['w'],r['rect']['y']+r['rect']['h'])).resize((w,h),Image.Resampling.NEAREST),(x,y))
# animation 7 frame list, expand ticks
seq=[]
for f in rep['animations'][ACTION]['frames']: seq += [piece_by[f['piece']]]*f['ticks']
frames=[]
for i in range(70):
 b=lerp(std,fin,min(max((i-10)/20,0),1))
 im=Image.new('RGBA',(640,480),(0,0,0,255));im.alpha_composite(floor.crop((0,36,320,168)).resize((640,336),Image.Resampling.NEAREST),(0,38))
 enemy=proj(tuple(T['encounters'][0]['positions'][0][k] for k in 'xyz'),b)
 targets=[]
 for k,p0 in enumerate(T['encounters'][0]['positions']):
  q=proj((p0['x'],p0['y'],p0['z']),b);targets.append(q)
  if q:sprite(im,T['enemies'][k],q,2.0)
 for k,p0 in enumerate(T['party_positions'][:len(T['initial_party'])]):
  q=proj((p0['x'],p0['y'],p0['z']),b)
  if q:sprite(im,T['party'][k],q,2.0)
 if enemy and i>=16:
  p=seq[min(max(i-16,0),len(seq)-1)]
  pi=piece_img(p['id']); pi=pi.resize((pi.width*2,pi.height*2),Image.Resampling.NEAREST)
  im.alpha_composite(pi,(int(enemy[0]-p['header'][4]*2),int(enemy[1]-p['header'][5]*2)))
 c=Image.new('RGB',(640,520),(8,10,16));c.paste(im.convert('RGB'),(0,0));dr=ImageDraw.Draw(c);dr.text((12,492),f'SOURCE PALETTE — {ALL["effects"][EFFECT]["id"]} animation {ACTION} preview',fill=(255,220,120));dr.text((12,506),f'frame {i}',fill=(190,200,215));frames.append(c)
frames[0].save(ROOT/f'kit/work/build/battle_review/{ALL["effects"][EFFECT]["id"]}_source_palette_{ACTION}.gif',save_all=True,append_images=frames[1:],duration=100,loop=0,optimize=False);print('ok')

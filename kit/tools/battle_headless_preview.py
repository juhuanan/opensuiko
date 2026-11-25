"""Software-only battle review preview.

The raylib snapshot harness needs a WindowServer session.  When that is not
available this tool uses the canonical battle scene, the source camera
projection and placeholder VFX shapes to produce a review GIF.  It is a review
aid, not the native renderer and not source art.
"""
import json, math, sys
from pathlib import Path
from PIL import Image, ImageDraw
ROOT = Path(__file__).resolve().parents[2]
import sys; sys.path.insert(0,str(ROOT/'kit/tools')); import battle_mock as bm
ACTION = sys.argv[1] if len(sys.argv) > 1 else "firestorm"
with open(ROOT/'kit/work/build/canonical/battle/trial.json') as fh:
    T=json.load(fh)
atlas=Image.open(ROOT/'kit/work/build/canonical/battle/actors.png').convert('RGBA')
floor=Image.open(ROOT/'kit/work/build/canonical/battle/floor.png').convert('RGBA')
rot=bm.rot_matrix
std=bm.camera_block(0)
fin=[-160,0,0,-768,0,608,0,0,1024,5120,5120,5120] if ACTION == "firestorm" else std
def proj(p,b):
 R=bm.scale_matrix(rot(b[3:6]),b[9:12]); TR=tuple(b[6:9])
 v=[((TR[i]<<12)+sum(R[i*3+j]*p[j] for j in range(3)))>>12 for i in range(3)]
 if v[2]<=1: return None
 return (320+1179.648*v[0]/v[2],240+1179.648*v[1]/v[2],v[2])
def lerp(a,b,t): return [round(a[i]+(b[i]-a[i])*t) for i in range(12)]
def sprite(img,rect,pt,scale):
 x=int(pt[0]-rect['anchor_x']*scale); y=int(pt[1]-rect['anchor_y']*scale)
 w=max(1,int(rect['rect']['w']*scale)); h=max(1,int(rect['rect']['h']*scale))
 part=atlas.crop((rect['rect']['x'],rect['rect']['y'],rect['rect']['x']+rect['rect']['w'],rect['rect']['y']+rect['rect']['h']))
 img.alpha_composite(part.resize((w,h),Image.Resampling.NEAREST),(x,y))
frames=[]
party_pos=T['party_positions']; enemy_pos=T['encounters'][0]['positions']
for i in range(76):
 b=lerp(std,fin,min(max((i-16)/20,0),1))
 img=Image.new('RGBA',(640,480),(0,0,0,255))
 img.alpha_composite(floor.crop((0,36,320,168)).resize((640,336),Image.Resampling.NEAREST),(0,38))
 # actors
 pts=[]
 for k,p0 in enumerate(enemy_pos):
  p=(p0['x'],p0['y'],p0['z'])
  q=proj(p,b); pts.append(q)
  if q: sprite(img,T['enemies'][k]['sprite'],q,2.0)
 for k,p0 in enumerate(party_pos[:len(T['initial_party'])]):
  p=(p0['x'],p0['y'],p0['z'])
  q=proj(p,b); pts.append(q)
  if q: sprite(img,T['party'][k]['sprite'],q,2.0)
 caster=pts[len(enemy_pos)] if len(pts)>len(enemy_pos) else None
 target=(pts[len(enemy_pos)] if ACTION == "heal" and len(pts) > len(enemy_pos) else (pts[0] if pts else None))
 d=ImageDraw.Draw(img,'RGBA')
 if i>=16 and caster and target:
  tick=i-16; impact=20; ps=max(0,impact-8)
  color=(255,180,40,255) if ACTION in ("firestorm","unite") else (120,210,255,255)
  glow=(220,45,20,230) if ACTION in ("firestorm","unite") else (30,90,220,230)
  if ACTION == "unite":
   for k in range(8):
    a=k*math.pi/4
    d.ellipse((target[0]+math.cos(a)*26-3,target[1]-30+math.sin(a)*16-3,target[0]+math.cos(a)*26+3,target[1]-30+math.sin(a)*16+3),fill=(255,210,80,255))
  elif ACTION == "status":
   if tick<impact:
    cx,cy=caster[0],caster[1]-70
    for k in range(8):
     a=k*math.pi/4; d.ellipse((cx+math.cos(a)*18-2,cy+math.sin(a)*18-2,cx+math.cos(a)*18+2,cy+math.sin(a)*18+2),fill=(210,120,255,255))
   else:
    for k in range(8):
     a=k*math.pi/4; d.ellipse((target[0]+math.cos(a)*26-3,target[1]-30+math.sin(a)*16-3,target[0]+math.cos(a)*26+3,target[1]-30+math.sin(a)*16+3),fill=(210,120,255,255))
  elif ACTION == "heal":
   if tick<impact:
    cx,cy=caster[0],caster[1]-70
    d.ellipse((cx-16,cy-16,cx+16,cy+16),outline=(120,210,255,255),width=2)
   else:
    for k in range(5):
     dx=k*10-20; rise=(k*11+tick)%28
     d.ellipse((target[0]+dx-5,target[1]-20-rise-5,target[0]+dx+5,target[1]-20-rise+5),fill=(160,255,170,255))
  elif tick<ps:
   cx,cy=caster[0],caster[1]-70
   for k in range(8):
    a=k*math.pi/4; d.ellipse((cx+math.cos(a)*18-2,cy+math.sin(a)*18-2,cx+math.cos(a)*18+2,cy+math.sin(a)*18+2),fill=color)
  elif tick<impact:
   f=(tick-ps)/max(1,impact-ps); x=caster[0]+(target[0]-caster[0])*f; y=caster[1]+(target[1]-caster[1])*f-34
   d.ellipse((x-7,y-7,x+7,y+7),fill=glow); d.ellipse((x-3,y-3,x+3,y+3),fill=color)
  else:
   for k in range(5):
    dx=k*9-18; h=18+((k*7+tick)%15)
    d.polygon([(target[0]+dx-7,target[1]-30),(target[0]+dx,target[1]-30-h),(target[0]+dx+7,target[1]-30)],fill=color)
   d.ellipse((target[0]-30,target[1]-60,target[0]+30,target[1]),outline=glow,width=2)
 canvas=Image.new('RGB',(640,520),(8,10,16)); canvas.paste(img.convert('RGB'),(0,0))
 dd=ImageDraw.Draw(canvas); dd.text((12,492),f'HEADLESS SOFTWARE PREVIEW — {ACTION} placeholder',fill=(255,230,120)); dd.text((12,506),f'phase {max(0,i-16)}/59',fill=(190,200,215)); frames.append(canvas)
frames[0].save(ROOT/f'kit/work/build/battle_review/{ACTION}_headless.gif',save_all=True,append_images=frames[1:],duration=100,loop=0,optimize=False)
print('ok')

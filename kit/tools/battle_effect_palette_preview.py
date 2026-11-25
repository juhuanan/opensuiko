"""Render effect pieces with the recovered BATTLE embedded palette.

Review aid only. Uses the palette_source schema-2 mapping from
spell_effect_sources.json. Does not promote or modify accepted art.
"""
import json,sys,numpy as np
from pathlib import Path
from PIL import Image,ImageDraw
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'kit/tools'));import battle_bin
s,a,e,d=battle_bin.parse(); blobs=[x for x in a if 1 in x['sections']]
def rgb(w):return ((w&31)*255//31,((w>>5)&31)*255//31,((w>>10)&31)*255//31)
def slot_pal(atlas,slot):
 off=128*(slot//2)+64+32*(slot%2)
 return [rgb(int(w)) for w in np.frombuffer(atlas[off:off+32],dtype='<u2')]
with open(ROOT/'kit/data/reports/spell_effect_sources.json') as fh:
    rep=json.load(fh)
eff=rep['effects'][0]
def entry_img(en):
 page,u,w,h,pal=en[2],(en[3]&0xf)*8,en[4]+1,en[5]+1,en[6]
 cols=slot_pal(blobs[9]['atlas'],pal);raw=blobs[page]['atlas'];im=Image.new('RGBA',(256,128));px=im.load()
 for k in range(16384):
  b=raw[k];x=(2*k)%256;y=(2*k)//256
  if b&15:px[x,y]=cols[b&15]+(255,)
  if x+1<256 and b>>4:px[x+1,y]=cols[b>>4]+(255,)
 return im.crop((u,0,min(256,u+w),min(128,h)))
def page_img(piece):
 w=max([e[0]+e[4]+1 for e in piece['entries']]+[piece['header'][2],1]);h=max([e[1]+e[5]+1 for e in piece['entries']]+[piece['header'][3],1])
 out=Image.new('RGBA',(w,h),(0,0,0,0))
 for en in piece['entries']:
  out.alpha_composite(entry_img(en),(en[0],en[1]))
 return out

W=180;H=150;cols=8;rows=(len(eff['pieces'])+cols-1)//cols
out=Image.new('RGB',(cols*W,rows*H),(20,20,24));dr=ImageDraw.Draw(out)
for i,p in enumerate(eff['pieces']):
 im=page_img(p)
 tile=im.resize((min(128,im.width*2),min(128,im.height*2)),Image.Resampling.NEAREST)
 x=(i%cols)*W;y=(i//cols)*H;out.paste(tile.convert('RGB'),(x+2,y+2),tile)
 dr.text((x+2,y+H-30),f'{p["id"]}',fill=(255,220,120));dr.text((x+2,y+H-15),f'{len(p["entries"])} entries',fill=(170,170,180))
out.save(ROOT/'kit/work/build/battle_review/flaming_real_palette_pieces.png');print('ok')

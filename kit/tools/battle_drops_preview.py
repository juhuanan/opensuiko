#!/usr/bin/env python3
"""Render the Drops review scene without opening a native window."""
import argparse
import json
import shutil
import subprocess
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw
import battle_drops as drops

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'kit/work/build/battle_review/drops'


class Raster:
    def __init__(self,bounds=(0,19,320,168)):
        self.rgb = np.zeros((240, 320, 3), dtype=np.uint16)
        self.coverage = np.zeros((240,320),dtype=bool)
        self.bounds=bounds

    def triangle(self, vertices, colors=None, texture=None, uv=None, additive=False, intensity=128, subtractive=False):
        v = np.asarray(vertices, dtype=float)
        cross = lambda a,b: a[...,0]*b[...,1]-a[...,1]*b[...,0]
        area = cross(v[1]-v[0],v[2]-v[0])
        if abs(area) < 1e-6: return
        if area < 0:
            v = v[[0,2,1]]
            if colors is not None: colors = np.asarray(colors)[[0,2,1]]
            if uv is not None: uv = np.asarray(uv)[[0,2,1]]
            area = -area
        x0,y0 = np.maximum(np.floor(v.min(axis=0)).astype(int), self.bounds[:2])
        x1,y1 = np.minimum(np.ceil(v.max(axis=0)).astype(int), self.bounds[2:])
        if x0 >= x1 or y0 >= y1: return
        y,x = np.mgrid[y0:y1,x0:x1]
        p = np.stack((x+.5,y+.5), axis=-1)
        weights, mask = [], np.ones(x.shape, dtype=bool)
        for a,b in ((v[1],v[2]),(v[2],v[0]),(v[0],v[1])):
            edge = cross(b-a,p-a)
            delta = b-a
            inclusive = delta[1] < 0 or (delta[1] == 0 and delta[0] > 0)
            mask &= (edge >= -1e-8) if inclusive else (edge > 1e-8)
            weights.append(edge/area)
        if not mask.any(): return
        weights = np.stack(weights,axis=-1)
        if texture is not None:
            coords = weights @ np.asarray(uv)
            sx = np.clip(np.floor(coords[...,0]).astype(int),0,texture.shape[1]-1)
            sy = np.clip(np.floor(coords[...,1]).astype(int),0,texture.shape[0]-1)
            sampled = texture[sy,sx]
            mask &= sampled[...,3] != 0
            color = np.minimum(sampled[...,:3].astype(np.uint16)*intensity//128,255)
        else:
            color = np.clip(weights @ np.asarray(colors),0,255).astype(np.uint16)
        dst = self.rgb[y0:y1,x0:x1]
        if additive: color = np.minimum(dst+color,255)
        if subtractive:color=np.maximum(dst.astype(np.int32)-color,0)
        dst[mask] = color[mask]
        self.coverage[y0:y1,x0:x1][mask]=True

    def quad(self, vertices, texture=None, colors=None, additive=False, intensity=128, subtractive=False, uv=None):
        uv = uv if uv is not None else None if texture is None else np.array([[0,0],[texture.shape[1],0],[0,texture.shape[0]],[texture.shape[1],texture.shape[0]]])
        for ids in ([0,1,2],[1,3,2]):
            self.triangle(np.asarray(vertices)[ids], None if colors is None else np.asarray(colors)[ids],
                          texture, None if uv is None else uv[ids], additive, intensity, subtractive)

    def command(self, command, textures, background=None):
        vertices = command['vertices']
        additive=command.get('blend','additive')=='additive'
        subtractive=command.get('blend')=='subtractive'
        if len(vertices)==2:
            a,b=np.array(vertices[0]),np.array(vertices[1]);steps=max(1,int(np.max(np.abs(b-a))))
            line=np.rint(a+(b-a)*np.linspace(0,1,steps+1)[:,None]).astype(int)
            mask=(line[:,0]>=0)&(line[:,0]<320)&(line[:,1]>=19)&(line[:,1]<168)
            line=np.unique(line[mask],axis=0);color=np.asarray(command['colors'][0])
            previous=self.rgb[line[:,1],line[:,0]].astype(np.int32)
            self.rgb[line[:,1],line[:,0]]=np.clip(previous+color if additive else previous-color if subtractive else color,0,255)
            return
        if command['kind']=='background':
            if background is None:raise ValueError('background warp requires its captured scene surface')
            uv=np.asarray(command['background_uv'])
            if len(vertices)==3:self.triangle(vertices,texture=background,uv=uv,intensity=command['intensity'])
            else:self.quad(vertices,texture=background,uv=uv,intensity=command['intensity'])
            return
        texture = textures[command['texture']] if command['kind'] == 'texture' else None
        colors = command.get('colors')
        if len(vertices) == 3:
            self.triangle(vertices,colors,texture,additive=additive,subtractive=subtractive)
        else:
            self.quad(vertices,texture,colors,additive,command.get('intensity',128),subtractive)


def crop(image, pose):
    r=pose['rect']
    return np.asarray(image)[r['y']:r['y']+r['h'],r['x']:r['x']+r['w']]


class Preview:
    def __init__(self, package, scene=None, knockouts=False):
        self.knockouts=knockouts
        self.content=json.loads((package/'trial.json').read_text())
        self.atlas=Image.open(package/self.content['atlas']).convert('RGBA')
        self.ground=np.asarray(Image.open(package/'ground.png').convert('RGBA'))
        by_id={p['id']:p for p in self.content['party']}
        self.party=[by_id[key] for key in self.content['initial_party']]
        self.positions=[tuple(p[k] for k in 'xyz') for p in self.content['party_positions'][:len(self.party)]]
        self.encounter=max(self.content['encounters'],key=lambda e:len(e['enemies'])) if scene and scene.program.get('group') else self.content['encounters'][0]
        # Explicit reproducible presentation input, not an emulator capture.
        seed=17; self.draws=[]
        for _ in range(18):
            seed=(1103515245*seed+12345)&0xffffffff
            self.draws.append((seed>>16)&32767)
        self.scene=scene or drops.Scene(self.draws)
        native=self.scene.effect['native_spell_id']
        rule=next((s for s in json.loads((ROOT/'game/assets/battle_systems/spell_rules.json').read_text())['spells'] if s['id']==f'spell_{native}'),None)
        self.instant_knockout=bool(rule and any(step['op']=='instant_ko' for step in rule['steps']))
        definition=next((s for s in (self.content.get('systems') or {}).get('spells',[]) if s['id']==f'spell_{native}'),None)
        self.allies=definition['allies'] if definition else native in (9,11,12,21,23,30,33)
        self.healing=(definition['kind'] in ('heal','revive','cure') if definition else native in (9,11)) or bool(getattr(self.scene,'program',{}).get('party_reaction'))
        self.impact=self.scene.program['impact'] if scene else 306
        self.spell_name=self.scene.effect.get('name','Drops of Kindness')
        self.last_frame=None
        self.ground_cache={}

    def ground_image(self,block,minimum_depth=0):
        key=(tuple(block),minimum_depth)
        if key not in self.ground_cache:
            raster=Raster(bounds=(0,0,320,240)) if minimum_depth else Raster()
            ground=self.content['ground'];cols=ground['across'];vertices=[drops.projected(tuple(v[k] for k in 'xyz'),block) for v in ground['vertices']]
            jobs=[]
            for y in range(ground['down']):
                for x in range(cols):
                    i=y*(cols+1)+x;corners=[vertices[j] for j in (i,i+1,i+cols+1,i+cols+2)]
                    if min(v[2] for v in corners)<=1:continue
                    if minimum_depth:
                        from spell_scene_warp import ground_depth
                        if ground_depth(corners[0][2])<minimum_depth:continue
                    tile=ground['tiles'][y*cols+x];across=self.ground.shape[1]//32
                    tx,ty=(tile%across)*32,(tile//across)*32
                    jobs.append((sum(v[2] for v in corners),[v[:2] for v in corners],self.ground[ty:ty+32,tx:tx+32]))
            for _,points,texture in sorted(jobs,key=lambda item:-item[0]):raster.quad(points,texture=texture)
            self.ground_cache[key]=np.dstack((raster.rgb,raster.coverage.astype(np.uint16)*255)) if minimum_depth else raster.rgb.copy()
        return self.ground_cache[key]

    def draw_job(self,raster,kind,job,backgrounds):
        if kind=='actor':
            if job.get('visible',True):raster.quad(job['vertices'],texture=job['texture'],intensity=job.get('intensity',128),subtractive=job.get('subtractive',False))
        else:raster.command(job,self.scene.textures,backgrounds[job['depth']] if job['kind']=='background' else None)

    def capture_background(self,block,jobs,minimum_depth,backgrounds):
        ground=self.ground_image(block,minimum_depth)
        capture=Raster(bounds=(0,0,320,240));capture.rgb[:]=ground[:,:,:3];capture.coverage[:]=ground[:,:,3]!=0
        for depth,kind,job in jobs:
            if depth>=minimum_depth:self.draw_job(capture,kind,job,backgrounds)
        return np.dstack((capture.rgb,capture.coverage.astype(np.uint16)*255))

    def actor(self, profile, position, block, update=0, casting=False, reacting=False, party_reaction=False):
        pose=profile['sprite']
        if casting and 0 < update < self.impact and profile.get('cast'):
            t=min(update-1,profile.get('cast_impact',1)-1)
            for frame in profile['cast']:
                pose=frame['pose']
                if t<frame['ticks']:break
                t-=frame['ticks']
        motion=getattr(self.scene,'program',{}).get('actor_motion')
        if motion and motion.get('exclude_airborne') and profile.get('airborne'):reacting=False
        actor_transform=None
        if motion and reacting:
            from spell_scene_warp import actor_sample
            actor_transform=actor_sample(motion,position,update)
            if actor_transform:position=[v>>12 for v in actor_transform['position']]
        point=drops.projected(position,block)
        scale=drops.trunc(block[9]<<10,block[8])/4096
        if actor_transform:scale*=actor_transform['size']/4096
        texture=crop(self.atlas,pose)
        reaction=(self.scene.reaction(update,profile['id'],party=True) if party_reaction else self.scene.reaction(update,profile['id'])) if reacting and hasattr(self.scene,'reaction') else None
        if self.knockouts and reacting and self.instant_knockout and update>=self.impact:
            reaction=dict(offset=[0,0],entry=None,visible=False)
        elif self.knockouts and reacting:reaction=self.scene.knockout(update,profile['id']) or reaction
        if reaction:
            for axis in range(2):point[axis]+=drops.trunc(reaction['offset'][axis]*drops.trunc(block[9+axis]<<10,block[8]),4096)
            if reaction['entry'] is not None:
                entry=self.scene.packet['entries'][reaction['entry']]
                pose=dict(rect=dict(w=entry['w'],h=entry['h']),anchor_x=-entry['dx'],anchor_y=-entry['dy'])
                texture=self.scene.textures[reaction['entry']]
        r=pose['rect']; x=point[0]-pose['anchor_x']*scale; y=point[1]-pose['anchor_y']*scale
        return (point[2]//4,dict(vertices=[[x,y],[x+r['w']*scale,y],[x,y+r['h']*scale],[x+r['w']*scale,y+r['h']*scale]], texture=texture,intensity=reaction.get('intensity',128) if reaction else 128,subtractive=reaction.get('blend')=='subtractive' if reaction else False,visible=reaction.get('visible',True) if reaction else True))

    def render(self, update):
        target=self.positions[1]
        center=(0,0)
        if not self.allies:
            p=self.encounter['positions'][0];target=tuple(p[k] for k in 'xyz')
            profile=next(p for p in self.content['enemies'] if p['id']==self.encounter['enemies'][0])
            pose=profile['sprite'];center=(pose['rect']['w']//2-pose['anchor_x'],pose['rect']['h']//2-pose['anchor_y'])
        targets=[]
        if hasattr(self.scene,'program'):
            for identifier,p in zip(self.encounter['enemies'],self.encounter['positions']):
                enemy=next(e for e in self.content['enemies'] if e['id']==identifier)
                pose=enemy['sprite'];mid=[pose['rect']['w']//2-pose['anchor_x'],pose['rect']['h']//2-pose['anchor_y']]
                hurt=next((h for h in self.scene.packet.get('hurt_poses',[]) if h['id']==identifier),None)
                if hurt:mid=hurt.get('center' if self.scene.program.get('center_after_reaction',True) else 'idle_center',mid)
                targets.append(dict(position=[p[k] for k in 'xyz'],center=mid))
            if not self.allies:center=targets[0]['center']
            idle=tuple(hurt.get('idle_center',center)) if not self.allies and (hurt:=next((h for h in self.scene.packet.get('hurt_poses',[]) if h['id']==self.encounter['enemies'][0]),None)) else center
            height=next((h['sprite_height'] for h in self.scene.packet.get('hurt_poses',[]) if not self.allies and h['id']==self.encounter['enemies'][0] and 'sprite_height' in h),profile['sprite']['rect']['h'] if not self.allies else 0)
            frame=self.scene.frame(update,self.positions[0],target,center,targets=targets,target_idle_center=idle,target_height=height)
        else:frame=self.scene.frame(update,self.positions[0],target)
        self.last_frame=frame
        block=frame['camera']; raster=Raster()
        raster.rgb[:]=self.ground_image(block)
        jobs=[]
        for entry in self.content['scenery']:
            point=drops.projected(tuple(entry['position'][k] for k in 'xyz'),block)
            pose=entry['sprite'];r=pose['rect'];scale=block[9]/4096
            x,y=point[0]-pose['anchor_x']*scale,point[1]-pose['anchor_y']*scale
            jobs.append((point[2]//4,'actor',dict(vertices=[[x,y],[x+r['w']*scale,y],[x,y+r['h']*scale],[x+r['w']*scale,y+r['h']*scale]],texture=crop(self.atlas,pose))))
        for profile,position in zip(self.party,self.positions):
            depth,actor=self.actor(profile,position,block,update,casting=profile==self.party[0],reacting=(self.allies and (profile==self.party[1] or getattr(self.scene,'program',{}).get('group'))) or bool(getattr(self.scene,'program',{}).get('party_reaction')),party_reaction=bool(getattr(self.scene,'program',{}).get('party_reaction')));jobs.append((depth,'actor',actor))
        for slot,(index,p) in enumerate(zip(self.encounter['enemies'],self.encounter['positions'])):
            profile=next(p for p in self.content['enemies'] if p['id']==index)
            depth,actor=self.actor(profile,tuple(p[k] for k in 'xyz'),block,update,reacting=not self.allies and (slot==0 or getattr(self.scene,'program',{}).get('group')));jobs.append((depth,'actor',actor))
        # OT insertion is last-in-first-out within a depth bucket.
        for command in frame['commands']: jobs.append((command['depth'],'effect',command))
        jobs=sorted(reversed(jobs),key=lambda item:-item[0]);backgrounds={}
        for depth in sorted({c['depth'] for c in frame['commands'] if c['kind']=='background'},reverse=True):
            surface=np.zeros((256,512,4),dtype=np.uint16)
            surface[:240,:320]=self.capture_background(block,jobs,depth+2,backgrounds)
            backgrounds[depth]=surface
        for _,kind,job in jobs:self.draw_job(raster,kind,job,backgrounds)
        if frame.get('wash_blend','additive')=='subtractive':raster.rgb[19:168]=np.maximum(raster.rgb[19:168].astype(np.int32)-np.asarray(frame['wash']),0)
        else:raster.rgb[19:168]=np.minimum(raster.rgb[19:168]+np.asarray(frame['wash'],dtype=np.uint16),255)
        im=Image.fromarray(raster.rgb.astype('uint8')).resize((640,480),Image.Resampling.NEAREST)
        d=ImageDraw.Draw(im)
        d.rectangle((0,0,639,36),fill=(9,13,26));d.text((16,12),self.spell_name,fill=(235,240,255))
        d.rectangle((0,336,639,479),fill=(12,20,42));d.line((0,337,639,337),fill=(120,155,210),width=2)
        healed=self.healing and update>=self.impact
        for i,p in enumerate(self.party):
            x,y=18+(i%3)*210,350+(i//3)*58
            d.text((x,y),p['name'],fill=(240,240,245))
            maximum=p['max_hp']
            hp=maximum if not self.healing or i!=1 or healed else 35
            d.text((x,y+17),f'HP  {hp:3d} / {maximum}',fill=(120,255,170) if i==1 and healed else (220,225,240))
            d.rectangle((x,y+34,x+160,y+38),fill=(40,55,80));d.rectangle((x,y+34,x+160*hp//maximum,y+38),fill=(70,190,135))
        if healed:
            at=drops.projected(self.positions[1],block)
            d.text((at[0]*2-24,at[1]*2-135),f'+{self.party[1]["max_hp"]-35} HP',fill=(120,255,170),stroke_width=1,stroke_fill=(0,0,0))
        return im


def export_native(preview, package, output):
    output.mkdir(parents=True,exist_ok=True)
    base=preview.atlas
    atlas=Image.new('RGBA',(base.width,base.height+65))
    atlas.paste(base,(0,0))
    entries=[]; x=0
    for piece in (0,8,9,10):
        index=preview.scene.pieces[piece][0]
        image=Image.fromarray(preview.scene.textures[index])
        atlas.paste(image,(x,base.height))
        en=preview.scene.entries[index]
        entries.append(dict(x=x,y=base.height,w=en['width'],h=en['height'],dx=en['dx'],dy=en['dy']))
        x+=image.width+1
    atlas.save(output/'actors.png')
    for name in ('floor.png','ground.png'):shutil.copyfile(package/name,output/name)
    content=json.loads((package/'trial.json').read_text())
    content['party'][0]['rune']='water'
    (output/'trial.json').write_text(json.dumps(content,indent=2)+'\n')
    (output/'drops.json').write_text(json.dumps(dict(schema='suikoden-drops-art/1',entries=entries),indent=2)+'\n')
    (output/'provenance.json').write_text(json.dumps(dict(**preview.scene.proof(),scene_sources=json.loads((package/'provenance.json').read_text()),scenario='Review fixture: Hero equipped with Water. No canonical save or accepted package modified.'),indent=2)+'\n')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package',type=Path,default=ROOT/'kit/work/build/canonical/battle')
    parser.add_argument('--out',type=Path,default=OUT)
    args=parser.parse_args()
    if (ROOT/'kit/work/accepted').resolve() in (args.out.resolve(),*args.out.resolve().parents):raise ValueError('review output cannot promote accepted assets')
    args.out.mkdir(parents=True,exist_ok=True)
    preview=Preview(args.package)
    export_native(preview,args.package,args.out/'native')
    samples={0,32,64,95,97,140,186,220,246,275,305,306}
    frames=[]; contact=[]; geometry=[]
    sequence=args.out/'frames';sequence.mkdir(exist_ok=True)
    for update in sorted(set(range(0,307,3))|samples):
        im=preview.render(update)
        geometry.append(preview.last_frame)
        if update%3==0:
            im.save(sequence/f'frame_{len(frames):04d}.png')
            frames.append(im)
        if update in samples:
            im.save(args.out/f'update_{update:03d}.png')
            labeled=im.copy();ImageDraw.Draw(labeled).text((430,12),f'Update {update:03d}',fill=(255,210,100));contact.append(labeled)
        if update%30==0:print(f'Drops update {update}/306',flush=True)
    timeline=[frames[0]]*10+frames+[frames[-1]]*20
    timeline[0].save(args.out/'drops_of_kindness.gif',save_all=True,append_images=timeline[1:],duration=50,loop=0,optimize=False)
    assert len(frames)==103
    if encoder:=shutil.which('ffmpeg'):
        subprocess.run([encoder,'-hide_banner','-loglevel','error','-y','-framerate','20','-i',str(sequence/'frame_%04d.png'),'-vf','tpad=start_mode=clone:start_duration=0.5:stop_mode=clone:stop_duration=1','-c:v','libx264','-crf','14','-pix_fmt','yuv420p','-movflags','+faststart',str(args.out/'drops_of_kindness.mp4')],check=True)
    sheet=Image.new('RGB',(640*3,480*4))
    for i,im in enumerate(contact):sheet.paste(im,((i%3)*640,(i//3)*480))
    sheet.save(args.out/'contact_sheet.png')
    (args.out/'scene.json').write_text(json.dumps(dict(**preview.scene.proof(),frames=geometry),indent=2)+'\n')
    print(args.out/'drops_of_kindness.gif')


if __name__=='__main__': main()

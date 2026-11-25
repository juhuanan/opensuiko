"""Independent software consumer of the portable spell scene export."""
import battle_drops as math_source


class Player:
    def __init__(self, packet, spell_id, atlas, seed=17, party=(), targets=(), target=(0,0,0), unite=False):
        self.packet=packet;self.spell=next(s for s in packet['unite_scenes' if unite else 'spells'] if s['id']==spell_id)
        self.program=self.spell['program']
        if self.program is None:raise ValueError(self.spell['blocker'])
        self.seed=seed;self.elapsed=0;self.flicker_phase=0;self.target=target;self.last_landing=0;self.last_landing_emitter=0;self.noise_scale=0
        self.party=list(party);self.targets=list(targets)
        per_party=self.program.get('initial_draws_per_party',0)
        if len(self.party)>6 or per_party and not self.party:raise ValueError('invalid spell party bindings')
        self.draws=[self.random() for _ in range(self.program['initial_draws']+per_party*len(self.party))]
        self.draw_count=len(self.draws)
        self.particles=[dict(phase=0,base_z=0,spark_height=0,node_rotation=0,size_override=0,history=[dict(position=[0]*3,visible=False) for _ in range(10)],landed=False,spark_angle=0,center=[0,0],age=0,pulse_life=0,pulse_size=1,splash_age=0,splash_active=False,splash_position=[0]*3,pending=False,spawn_scale=[4096]*3,head=[0]*3,tail=[0]*3,velocity=[0]*3,life=0,active=False) for _ in range(max(50,max((e.get('particle_start',0)+e['count'] for e in self.emitters()),default=0)))]
        for emitter in self.emitters():
            if emitter.get('kind')=='seeded_spheres':
                for i,p in enumerate(self.particles_for(emitter)):
                    p['age']=self.draws[5*i]%emitter['initial_warmup'];p['phase']=self.draws[5*i+1]%emitter['initial_phase']
                    self.hemisphere(p,emitter,self.draws[5*i+2:5*i+5]);p['base_z']=p['head'][2]
            if emitter.get('kind')=='inward_points':
                for p,scale in zip(self.particles_for(emitter),emitter['point_initial_scales'],strict=True):p['spawn_scale']=[scale]*3
            if emitter.get('kind')=='scheduled_sprites' or emitter.get('kind')=='cycling_sprites' and emitter.get('initial_delays',True):
                for i,p in enumerate(self.particles_for(emitter)):p.update(pending=True,life=self.draws[emitter.get('initial_delay_draw',0)+i*emitter.get('delay_stride',1)]%emitter['delay_modulus']+emitter.get('delay_bias',0))
        for emitter in self.emitters():
            if emitter.get('kind')=='falling_trails':
                for p in self.particles_for(emitter):p['pending']=True
        self.textures=[]
        import numpy as np
        for e in packet['entries']:self.textures.append(np.asarray(atlas.crop((e['x'],e['y'],e['x']+e['w'],e['y']+e['h']))))
        self.coverage=self.program['erosion']['levels'].copy() if self.program.get('erosion') else []
        self.effect=dict(native_spell_id=None if unite else int(spell_id.split('_')[1]),id=spell_id,name=self.spell['name'])

    def emitters(self):
        return [self.program['emitter']] if self.program.get('emitter') else self.program.get('emitters',[])

    def particles_for(self,emitter):
        start=emitter.get('particle_start',0)
        return self.particles[start:start+emitter['count']]

    def emitter_for(self,index):
        return next(e for e in self.emitters() if e.get('particle_start',0)<=index<e.get('particle_start',0)+e['count'])

    def reaction(self,update,actor,party=False):
        reaction=self.program.get('party_reaction' if party else 'reaction')
        if not reaction or update<reaction['start'] or update>=self.program['duration']:return None
        age=update-reaction['start']
        if age>=len(reaction['offsets']) or reaction.get('active_samples') and not reaction['active_samples'][age]:return None
        pose=next((p for p in self.packet.get('hurt_poses',[]) if p['id']==actor),None)
        entry=pose['entry'] if pose else None
        frames=reaction.get('flash_frames',[])
        variant=frames[age] if age<len(frames) else None
        if pose and variant==3:
            if (update+self.flicker_phase)%2==0:entry=pose.get('white_entry',entry)
        elif pose and variant is not None and variant>=4:
            if pose.get('shock_entries'):entry=pose['shock_entries'][variant-4]
        elif pose and variant is not None and pose.get('flash_entries'):entry=pose['flash_entries'][variant]
        return dict(offset=reaction['offsets'][min(age,len(reaction['offsets'])-1)],entry=entry,intensity=reaction.get('tints',[[128]*3]*len(reaction['offsets']))[age],animation=reaction.get('animation',1))

    def knockout(self,update,actor):
        pose=next((p for p in self.packet.get('hurt_poses',[]) if p['id']==actor),None)
        ko=pose.get('knockout') if pose else None
        if not ko:return None
        reaction=self.program.get('reaction')
        start=max(self.program['impact'],reaction['start']+reaction.get('release',len(reaction['offsets'])) if reaction else 0)
        age=update-start
        if age<0:return None
        overlap=reaction and start<reaction['start']+len(reaction['offsets'])
        return dict(entry=ko['entry'] if age else pose['entry'] if overlap else None,offset=reaction['offsets'][start-reaction['start']] if overlap else [0,0],visible=age<ko['duration']-2,intensity=max(0,128-2*max(0,age-2)),blend='opaque' if age<2 else 'subtractive')

    def random(self):
        self.seed=(1103515245*self.seed+12345)&0xffffffff
        return (self.seed>>16)&32767

    def next(self):self.draw_count+=1;return self.random()

    def circle(self,p,radius,roots):
        x=self.next()%(2*(radius-1))+1-radius;extent=roots[radius*radius-x*x]
        y=self.next()%(2*extent)-extent
        for axis,v in enumerate((x,y,0)):p['head'][axis]=(math_source.trunc(v*p['spawn_scale'][axis],4096)<<12)|(p['head'][axis]&4095)
        p['active']=True

    def hemisphere(self,p,e,values=None):
        a,b,c=values if values is not None else (self.next(),self.next(),self.next())
        r=e['radius'];x=a%(2*(r-1))+1-r;edge=e['roots'][r*r-x*x]
        y=b%(2*edge)-edge;z=-(c%(e['roots'][r*r-x*x-y*y]+1))
        for axis,v in enumerate((x,y,z)):p['head'][axis]=(math_source.trunc(v*p['spawn_scale'][axis],4096)<<12)|(p['head'][axis]&4095)
        p['active']=True

    def sample_scale(self,sample):
        return [v+(self.noise_scale if sample.get('noise_scale') else 0) for v in sample.get('scale',[4096]*3)]

    def spawn_cycle(self,p,e):
        height=self.next()%e['height_range'] if e.get('height_range') else 0
        z=-math_source.trunc(height*p['spawn_scale'][2],4096)
        self.circle(p,e['radius'],e['roots']);p['head'][2]=(z<<12)|(p['head'][2]&4095)
        p['age']=0;p['life']=0;p['pending']=False

    def advance(self,update):
        if update<self.elapsed:raise ValueError('scene updates must advance monotonically')
        for e in self.emitters():
            if e and e.get('strike_at'):
                slots=[t.get('formation_slot',i) for i,t in enumerate(self.targets)]
                if not 1<=len(slots)<=6 or len(set(slots))!=len(slots) or any(not 0<=slot<min(6,e['count']) for slot in slots) or any(abs(v)>32767 for t in self.targets for v in t['position']+t['center']):raise ValueError('invalid spell target slots')
            if e and e.get('target_height') and any(abs(v)>32767 for v in self.target):raise ValueError('invalid spell target position')
        while self.elapsed<update:
            self.elapsed+=1
            if (e:=self.program.get('erosion')) and e['start']<=self.elapsed<e['stop']:
                if sum(self.coverage)<e['minimum_weight']:self.coverage[:]=[0]*len(self.coverage)
                else:
                    removed=0
                    while removed<e['budget']:
                        cell=self.next()%len(self.coverage)
                        if not self.coverage[cell]:continue
                        self.coverage[cell]=int(e['lower_present'][cell]) if self.coverage[cell]==2 else 0
                        removed+=1
                import numpy as np
                colors=np.array(e['colors'],dtype=np.uint8)
                for i,(cell,upper) in enumerate(zip(e['view_cells'],e['view_upper'])):
                    if (self.coverage[cell]!=2 if upper else not self.coverage[cell] or not e['lower_present'][cell]):colors[i,3]=0
                en=self.packet['entries'][e['entry']];self.textures[e['entry']]=colors.reshape(en['h'],en['w'],4)
            for emitter_index,e in enumerate(self.emitters()):
                if not e['start']<=self.elapsed<=e['stop']:continue
                radius=e['radius']
                if e.get('kind')=='ballistic_sprites':
                    if self.elapsed>=e['stop']:continue
                    particles=self.particles_for(e)
                    for node,at in zip(particles,e['spawn_at']):
                        if self.elapsed!=at:continue
                        height=self.next()%e['height_range'] if e.get('height_range') else 0
                        self.circle(node,radius,e['roots'])
                        node['head'][2]=(-height<<12)|(node['head'][2]&4095);node['velocity']=[e.get('velocity_x',0),0,e.get('velocity_z',0)];node['age']=0
                    for node in particles:
                        if not node['active']:continue
                        if not e.get('landing_z') and node['head'][2]>>12<e['min_z']:node['active']=False;continue
                        node['age']+=1;node['velocity'][2]+=e.get('gravity',0)
                        node['head']=[v+d for v,d in zip(node['head'],node['velocity'])]
                        if e.get('landing_z') and node['head'][2]>>12>=e['landing_z']:
                            node.update(active=False,splash_active=True,splash_age=0,splash_position=node['head'].copy());self.last_landing=self.elapsed;self.last_landing_emitter=emitter_index
                    for node in particles:
                        if node['splash_active']:
                            node['splash_age']+=1
                            if node['splash_age']>=len(self.program['tracks'][e['spark_track']]):node['splash_active']=False
                    continue
                if e.get('kind')=='bouncing_sprites':
                    if self.elapsed>=e['stop']:continue
                    particles=self.particles_for(e)
                    for node,at in zip(particles,e['spawn_at']):
                        if self.elapsed==at:
                            self.circle(node,radius,e['roots']);node['head'][2]=e['min_z']<<12;node['velocity']=[e['velocity_x'],0,0]
                    for index,node in enumerate(particles):
                        if not node['active']:continue
                        if node['head'][2]>>12>0:
                            node['head'][2]=0;node['velocity'][2]=math_source.trunc(-node['velocity'][2],e['bounce_divisor'])
                            if index%e['focus_stride']==0:self.last_landing=self.elapsed;self.last_landing_emitter=emitter_index
                            if not node['splash_active']:node.update(splash_age=0,splash_active=True,splash_position=node['head'].copy())
                        else:node['velocity'][2]+=e['gravity']
                        node['node_rotation']=(node['node_rotation']-self.next()%e['spin_modulus'])&65535
                        node['head']=[v+speed for v,speed in zip(node['head'],node['velocity'])];node['age']+=1
                        if node['head'][0]>>12<e['min_x']:node['active']=False
                    for node in particles:
                        if node['splash_active']:
                            node['splash_age']+=1
                            if node['splash_age']>=len(self.program['tracks'][e['spark_track']]):node['splash_active']=False
                    continue
                if e.get('kind') in ('orbiting_sprites','drifting_sprites'):
                    if self.elapsed>=e['stop']:continue
                    particles=self.particles_for(e)
                    if self.elapsed<=e['spawn_stop']:
                        for index,p in enumerate(particles):
                            if (self.elapsed!=e['spawn_at'][index]) if e['kind']=='orbiting_sprites' else p['active']:continue
                            height=e.get('spawn_height_min',0)+self.next()%e['height_range']
                            self.circle(p,radius,e['roots']);p['head'][2]=(-height<<12)|(p['head'][2]&4095);p['age']=0
                            if e['kind']=='drifting_sprites':
                                p['velocity']=[e['velocity_min']+self.next()%e['velocity_range'],0,e['velocity_min']+self.next()%e['velocity_range']]
                                p['life']=self.next()%e['life_max']
                    for p in particles:
                        if not p['active']:continue
                        if e['kind']=='drifting_sprites':
                            if not p['life'] or p['head'][2]>>12>0:p['active']=False;continue
                            p['head']=[v+speed for v,speed in zip(p['head'],p['velocity'])]
                        p['age']+=1
                        if e['kind']=='orbiting_sprites' and p['age']>=e['life_max']:p['active']=False
                    continue
                if e.get('kind')=='falling_trails':
                    if self.elapsed>=e['stop']:continue
                    particles=self.particles_for(e)
                    for p,at in zip(particles,e['spawn_at']):
                        if self.elapsed<=e['spawn_stop'] and (p['pending'] and self.elapsed==at or not p['pending'] and not p['active']):
                            self.circle(p,radius,e['roots']);p['head'][2]=e['min_z']<<12;p['pending']=False;p['age']=0
                    for p in particles:
                        if p['active']:
                            p['head'][2]+=e['velocity_z'];p['age']+=1
                            if p['head'][2]>=0:
                                self.last_landing=self.elapsed;self.last_landing_emitter=emitter_index;p['active']=False;p['splash_position']=p['head'].copy()
                                if not p['splash_active']:p['splash_age']=0
                                p['splash_active']=True
                        p['history'][0]=dict(position=p['head'].copy(),visible=p['active'])
                        for trail in range(e['trail_count']-1,0,-1):p['history'][trail]=dict(p['history'][trail-1])
                        if p['splash_active']:
                            p['splash_age']+=1
                            if p['splash_age']>=len(self.program['tracks'][e['spark_track']]):p['splash_active']=False
                    continue
                if e.get('kind')=='cycling_sprites':
                    if self.elapsed>=e['stop']:continue
                    particles=self.particles_for(e)
                    if self.elapsed<=e['spawn_stop']:
                        for p in particles:
                            if p['pending'] and self.elapsed-e['start']==p['life']:
                                self.spawn_cycle(p,e)
                                if e.get('focus_on_first'):self.last_landing=self.elapsed;self.last_landing_emitter=emitter_index
                        for p in particles:
                            if not p['pending'] and not p['active']:
                                self.spawn_cycle(p,e)
                                if e.get('repeat_size_range'):p['size_override']=e['repeat_size_min']+self.next()%e['repeat_size_range']
                                if e.get('focus_kick'):self.last_landing=self.elapsed;self.last_landing_emitter=emitter_index
                    for p in particles:
                        if p['active']:
                            p['spawn_scale']=self.program['tracks'][e['scale_track']][self.elapsed].get('scale',[4096]*3)
                            p['age']+=1
                            if p['age']>=e['life_max']:p['active']=False
                    continue
                if e.get('kind')=='seeded_spheres':
                    particles=self.particles_for(e)
                    if self.elapsed>=e['stop']:
                        for p in particles:p['active']=False
                        continue
                    for p in particles:
                        if not p['active'] and self.elapsed<=e['spawn_stop']:
                            self.hemisphere(p,e);p['age']=0
                        if not p['active']:continue
                        p['head'][2]=p['base_z']+e['oscillation'][p['phase']%len(e['oscillation'])]
                        p['phase']+=1;p['spawn_scale']=self.program['tracks'][e['scale_track']][self.elapsed].get('scale',[4096]*3)
                        p['age']+=1
                        if p['age']>=e['life_max']:
                            if self.elapsed<=e['loop_stop']:p['age']=0
                            else:p['active']=False
                    continue
                if e.get('kind')=='spherical_sprites':
                    if self.elapsed>=e['stop']:continue
                    for p in self.particles_for(e):
                        if not p['active']:
                            self.circle(p,radius,e['roots'])
                            x,y=[v>>12 for v in p['head'][:2]]
                            extent=e['roots'][radius*radius-x*x-y*y]+1
                            p['head'][2]=-(self.next()%extent)<<12
                            p['life']=self.next()%e['life_max']
                        p['active']=p['life']>0
                        if p['active']:
                            p['spawn_scale']=self.program['tracks'][e['scale_track']][self.elapsed].get('scale',[4096]*3)
                            p['age']+=1
                    continue
                if e.get('kind')=='scheduled_pulses':
                    if self.elapsed>=e['stop']:continue
                    for event in e['pulse_spawns']:
                        if event['at']!=self.elapsed:continue
                        particle=self.particles[e.get('particle_start',0)+event['index']];height=self.next()%e['height_range']
                        self.circle(particle,radius,e['roots']);particle['head'][2]=(-height<<12)|(particle['head'][2]&4095)
                        particle['splash_position']=particle['head'].copy();particle['pulse_life']=e['pulse_life'];particle['pulse_size']=1
                    for particle in self.particles_for(e):
                        if not particle['pulse_life']:continue
                        particle['pulse_size']=particle['pulse_size']+e['pulse_grow'] if particle['pulse_life']>e['pulse_fade_at'] else max(1,particle['pulse_size']-e['pulse_shrink'])
                        particle['pulse_life']-=1
                        if not particle['pulse_life']:particle['pulse_size']=1;particle['active']=False
                    continue
                if e.get('kind')=='lightning_bolts':
                    if self.elapsed>=e['stop']:continue
                    for index,(p,at) in enumerate(zip(self.particles_for(e),e['spawn_at'])):
                        if self.elapsed!=at:continue
                        if e.get('fixed_positions'):p['head']=e['fixed_positions'][index].copy();p['active']=True
                        else:
                            self.circle(p,radius,e['roots']);p['head'][2]=(e['min_z']<<12)|(p['head'][2]&4095)
                            if e.get('spawn_override') is not None:p['head']=e['spawn_override'].copy()
                    if self.elapsed<=e.get('repeat_until',0):
                        for p,at in zip(self.particles_for(e),e['spawn_at']):
                            if at!=e['start'] or p['active'] or p['splash_active']:continue
                            self.circle(p,radius,e['roots']);p['head'][2]=(e['min_z']<<12)|(p['head'][2]&4095)
                    if self.elapsed==e.get('strike_at',0):
                        for i,target in enumerate(self.targets):
                            p=self.particles[e.get('particle_start',0)+target.get('formation_slot',i)]
                            self.circle(p,e['strike_radius'],e['roots'])
                            p['head']=[target['position'][0]*4096,target['position'][1]*4096,p['head'][2]&4095];p['center']=target['center']
                    if e.get('fixed_positions') and e.get('spark_turn_at',0)>0 and e['spark_turn_at']<=self.elapsed<=e['spark_turn_stop']:
                        for p in self.particles_for(e)[e['persistent_from']:]:
                            angle=(self.elapsed-e['spark_turn_at']+1)*e['spark_turn_step'];p['spark_angle']=min(e['spark_turn_limit'],angle)
                            if angle>e['spark_turn_limit']:p['splash_active']=False
                    for p in self.particles_for(e):
                        if self.elapsed>=e['flight_stop']:p['active']=False
                        if not p['active']:continue
                        if not p['landed']:p['head'][2]+=e['velocity_z']
                        if not p['landed'] and p['head'][2]>>12>(self.target[2] if e.get('target_height') else 0):
                            self.last_landing=self.elapsed;self.last_landing_emitter=emitter_index
                            p['head'][2]=(p['head'][2]&4095)|((self.target[2] if e.get('target_height') else 0)<<12);p['splash_position']=p['head'].copy();p['splash_active']=True;p['spark_height']=0
                            p['life']=e['spark_life_min']+(self.next()%e['spark_life_range'] if e['spark_life_range'] else 0)
                            p['pulse_life']=e['pulse_life'];p['pulse_size']=1
                            if e.get('contact_holds'):p['landed']=True;p['age']+=1
                            else:p['active']=False
                        else:p['age']+=1
                    for index,p in enumerate(self.particles_for(e)):
                        persistent=bool(e.get('fixed_positions')) and index>=e['persistent_from']
                        if e.get('spark_stop') and self.elapsed>=e['spark_stop']:p['splash_active']=False
                        if p['splash_active']:
                            if not persistent and p['life']>0:p['life']-=1
                            if not p['life']:
                                if not e.get('spark_velocity_z'):p['splash_active']=False
                                else:
                                    if p['spark_height']>>12<e['spark_min_z']:p['splash_active']=False
                                    p['spark_height']+=e['spark_velocity_z']
                            if p['splash_active']:p['splash_age']+=1
                        if p['pulse_life']:
                            p['pulse_size']=p['pulse_size']+e['pulse_grow'] if p['pulse_life']>e['pulse_fade_at'] else max(1,p['pulse_size']-e['pulse_shrink'])
                            p['pulse_life']-=1
                            if not p['pulse_life']:p['pulse_size']=1
                    continue
                if e.get('kind')=='falling_lines':
                    if self.elapsed>=e['stop']:continue
                    if self.elapsed<=e['spawn_stop']:
                        for p in self.particles_for(e):
                            if p['active']:continue
                            self.circle(p,radius,e['roots'])
                            p['head'][2]=(e['min_z']<<12)|(p['head'][2]&4095)
                            trail=e['trail_min']+self.next()%e['trail_range']
                            p['tail']=[p['head'][0],p['head'][1],((e['min_z']-trail)<<12)|(p['tail'][2]&4095)]
                            p['velocity'][2]=e['velocity_z']+(self.next()%e['speed_range'])*4096
                            self.next()
                    for p in self.particles_for(e):
                        if p['head'][2]>>12>0:
                            p['splash_position']=p['head'].copy()
                            if not p['splash_active']:p['splash_age']=0
                            p['splash_active']=True;p['active']=False
                        if p['active']:
                            for axis in range(3):p['head'][axis]+=p['velocity'][axis];p['tail'][axis]+=p['velocity'][axis]
                        if p['splash_active']:
                            p['splash_age']+=1
                            if p['splash_age']>=len(self.program['tracks'][e['splash_track']]):p['splash_active']=False
                    continue
                if e.get('kind')=='scheduled_sprites':
                    if self.elapsed>=e['stop']:continue
                    if self.elapsed<=e['spawn_stop']:
                        for p in self.particles_for(e):
                            if p['pending'] and p['life']==e['spawn_clock'][self.elapsed]:
                                p['pending']=False;self.circle(p,e['radius'],e['roots'])
                        for p in self.particles_for(e):
                            if not p['pending'] and not p['active']:self.circle(p,e['repeat_radius'],e['roots'])
                    for p in self.particles_for(e):
                        if not p['active']:continue
                        if p['head'][2]>>12<e['min_z']:p['active']=False
                        p['head'][2]+=e['velocity_z'];p['spawn_scale']=self.program['tracks'][e['scale_track']][self.elapsed].get('scale',[4096]*3)
                    continue
                if e.get('kind')=='rising_sprites':
                    if self.elapsed>=e['stop']:continue
                    if self.elapsed<=e['spawn_stop']:
                        for p in self.particles_for(e):
                            if p['active']:continue
                            self.circle(p,radius,e['roots'])
                            p['life']=self.next()%e['life_max'];p['active']=True
                    for p in self.particles_for(e):
                        if p['life']==0 or p['head'][2]>>12<e['min_z']:p['active']=False;continue
                        p['spawn_scale']=self.program['tracks'][e['scale_track']][self.elapsed].get('scale',[4096]*3)
                        p['head'][2]+=e['velocity_z'];p['life']-=1
                    continue
                if e.get('kind')=='rising_lines':
                    if self.elapsed>=e['stop']:continue
                    particles=self.particles_for(e)
                    if self.elapsed<=e['spawn_stop']:
                        for p in particles:
                            p['spawn_scale']=self.program['tracks'][e['scale_track']][self.elapsed].get('scale',[4096]*3)
                            if p['active']:continue
                            x=self.next()%(2*(radius-1))+1-radius;extent=e['roots'][radius*radius-x*x];y=self.next()%(2*extent)-extent
                            p['head']=[(v<<12)|(p['head'][axis]&4095) for axis,v in enumerate((x,y,0))];p['active']=True
                            trail=e['trail_min']+self.next()%e['trail_range']
                            for axis in range(2):p['tail'][axis]=(p['head'][axis]&~4095)|(p['tail'][axis]&4095)
                            p['tail'][2]=(-trail<<12)|(p['tail'][2]&4095)
                            p['velocity']=[0,0,e['velocity_z']-(self.next()%e['speed_range'])*4096];p['life']=self.next()%e['life_max']
                    for p in particles:
                        if not p['life'] or p['head'][2]>>12<e['min_z']:p['active']=False;continue
                        p['life']-=1;p['head']=[v+d for v,d in zip(p['head'],p['velocity'])];p['tail']=[v+d for v,d in zip(p['tail'],p['velocity'])]
                    continue
                if e.get('kind')=='inward_points':
                    if self.elapsed>=e['stop']:continue
                    for p in self.particles_for(e):
                        if not p['active'] and self.elapsed<=e['spawn_stop']:
                            x=self.next()%(2*(radius-1))+1-radius;extent=e['roots'][radius*radius-x*x]
                            y=self.next()%(2*extent)-extent;z=-e['roots'][radius*radius-x*x-y*y]
                            speed=128+self.next()%64;p['life']=self.next()%120
                            p['head']=[(math_source.trunc(v*p['spawn_scale'][0],4096)<<12)|(p['head'][axis]&4095) for axis,v in enumerate((x,y,z))]
                            p['velocity']=[-v*speed for v in (x,y,z)];p['active']=True
                        if not p['life'] or abs(p['head'][0]>>12)<5:p['active']=False;continue
                        p['life']-=1;p['head']=[v+d for v,d in zip(p['head'],p['velocity'])]
                        p['spawn_scale']=self.program['tracks'][e['scale_track']][self.elapsed].get('scale',[4096]*3)
                    continue
                for p in self.particles_for(e):
                    if not p['active']:
                        if e.get('spawn_stop') and self.elapsed>e['spawn_stop']:continue
                        x=self.next()%(2*(radius-1))+1-radius
                        extent=e['roots'][radius*radius-x*x]
                        y=self.next()%(2*extent)-extent
                        z=-e['roots'][radius*radius-x*x-y*y]
                        speed=128+self.next()%64;p['life']=self.next()%100
                        for axis,v in enumerate((x,y,z)):
                            p['head'][axis]=(v<<12)|(p['head'][axis]&4095)
                            p['tail'][axis]=(math_source.trunc(v*5,6)<<12)|(p['tail'][axis]&4095)
                            p['velocity'][axis]=-v*speed
                        p['active']=True
                    if self.elapsed==e['stop'] or p['life']==0 or abs(p['tail'][0]>>12)<5:
                        p['active']=False;continue
                    p['life']-=1
                    for axis in range(3):
                        p['head'][axis]+=p['velocity'][axis];p['tail'][axis]+=p['velocity'][axis]

            noise=self.program.get('scale_noise')
            if noise:
                if noise['start']<=self.elapsed<noise['stop']:self.noise_scale+=self.next()%noise['modulus']+noise['bias']
                for emitter in self.emitters():
                    if emitter.get('kind')=='cycling_sprites' and self.elapsed<self.program['duration']:
                        for particle in self.particles_for(emitter):
                            if not particle['pending']:particle['spawn_scale']=self.sample_scale(self.program['tracks'][emitter['scale_track']][self.elapsed])

    @staticmethod
    def transition(a,b,n,duration):return [((y<<12) if n>=duration else (x<<12)+math_source.trunc((y-x)<<12,duration)*n)>>12 for x,y in zip(a,b)]

    def camera(self,update):
        initial=[v>>12 for v in math_source.block_at(0x8016B878)]
        previous=None;start=initial
        for event in self.program['cameras']:
            if update<event['at']:break
            target=sum((event['target'][k] for k in ('position','angles','c','d')),[])
            if previous:
                start=self.transition(start,previous[0],event['at']-previous[1],previous[2])
            previous=(target,event['at'],event['updates'])
        result=self.transition(start,previous[0],update-previous[1]+1,previous[2]) if previous else initial
        focus=self.program.get('focus_samples',[])
        if update<len(focus) and focus[update] is not None:result[:3]=focus[update]
        if update and self.last_landing==update:result[2]+=self.emitters()[self.last_landing_emitter].get('focus_kick',0)
        return result

    def variation(self,term):
        return term.get('bias',0)+(self.draws[term['draw']]%term['modulus'])*term.get('multiplier',1) if term else 0

    def frame(self,update,caster,target,target_center=(0,0),targets=(),target_idle_center=None,target_height=0):
        if targets:self.targets=list(targets)
        targets=self.targets
        self.target=target;self.advance(update);block=self.camera(update);commands=[]
        if self.program.get('reaction_center_switch') and update<self.program['reaction']['start'] and target_idle_center is not None:target_center=target_idle_center
        scale=math_source.trunc(block[9]<<10,block[8]);program=self.program
        def origin(anchor):
            if anchor=='caster':return caster
            if anchor in ('target','each_target'):return target
            return (0,0,0) if anchor in ('world','screen') else (120,target[1],0)
        for obj in program['objects']:
            emitter=self.emitter_for(obj['particle_index']) if 'particle_index' in obj else None
            animated_sprite='particle_index' in obj and emitter.get('kind') in ('spherical_sprites','seeded_spheres','cycling_sprites','orbiting_sprites','drifting_sprites')
            falling='particle_index' in obj and emitter.get('kind')=='falling_lines'
            lightning='particle_index' in obj and emitter.get('kind') in ('lightning_bolts','scheduled_pulses','falling_trails','bouncing_sprites','ballistic_sprites')
            part=obj.get('particle_part','primary')
            if 'particle_index' in obj:
                particle=self.particles[obj['particle_index']]
                visible=particle['history'][obj['trail_index']]['visible'] if 'trail_index' in obj else (particle['active'] if part=='primary' else particle['splash_active'] if part=='spark' else particle['pulse_life']>0) if lightning else particle['splash_active' if falling else 'active']
                if not visible or update>=emitter['stop']:continue
            if obj['anchor']=='party_member' and obj['member_index']>=len(self.party):continue
            start=obj.get('start',0)
            if update<start:continue
            age=(particle['age'] if part=='primary' else particle['splash_age'] if part=='spark' else 0) if lightning else particle['age'] if animated_sprite else self.particles[obj['particle_index']]['splash_age'] if falling else update-start+(1 if start else 0);track=program['tracks'][obj['track']]
            sample_index=update if 'piece_track' in obj else age
            if sample_index>=len(track):continue
            sample=track[sample_index];piece=(program['tracks'][obj['piece_track']][age].get('piece') if age<len(program['tracks'][obj['piece_track']]) else None) if 'piece_track' in obj else sample.get('piece')
            if piece is None or not sample.get('visible',True):continue
            recipients=targets if obj['anchor']=='each_target' and targets else [dict(position=origin(obj['anchor']),center=target_center)]
            for recipient in recipients:
                base=[(self.party[obj['member_index']]['position'] if obj['anchor']=='party_member' else recipient['position'])[i]+(obj.get('origin',[0]*3)[i] if not obj.get('origin_until') or update<obj['origin_until'] else 0) for i in range(3)];center=particle['center'] if lightning and emitter.get('strike_at') else recipient['center']
                local=[(sample.get('position',[0]*3)[i]+((particle['history'][obj['trail_index']]['position'][i] if 'trail_index' in obj else particle['splash_position' if falling or lightning and part!='primary' else 'head'][i]) if 'particle_index' in obj else obj.get('position',[0]*3)[i])+(self.variation(obj.get('random_z'))+(particle['spark_height'] if lightning and part=='spark' else 0) if i==2 else 0))>>12 for i in range(3)]
                if flight:=obj.get('flight'):
                    steps=min(max(age-flight['start']+1,0),flight['updates']);initial=sample.get('position',[0]*3)
                    delta=[((target[i]-caster[i])<<12)-initial[i]-(target_height*flight.get('target_height_q12',0) if i==2 else 0) for i in range(3)]
                    local=[math_source.short((initial[i]+math_source.trunc(delta[i],flight['updates'])*steps)>>12) for i in range(3)]
                angles=sample.get('angles',[0]*3).copy();angles[2]+=self.variation(obj.get('random_angle'))
                world=math_source.transform(local,angles,self.sample_scale(sample),base)
                anchor=[160+world[0],120+world[1],obj['screen_depth']*4] if obj['anchor']=='screen' else math_source.projected(world,block)
                if obj.get('center_on_target'):
                    for i in range(2 if obj.get('center_y',True) else 1):anchor[i]+=center[i]
                size=math_source.trunc(scale*(particle['size_override'] if 'particle_index' in obj and particle.get('size_override') else ((particle['pulse_size'] if lightning and part=='pulse' else sample.get('size',4096))+self.variation(obj.get('random_size')))),4096)
                for entry_id in self.packet['pieces'][piece]:
                    if offsets:=sample.get('quad_offsets'):
                        corners=[]
                        for offset in offsets:
                            projected=math_source.projected(offset,block,centered=False)
                            corners.append([math_source.short(anchor[axis]+projected[axis]) for axis in range(2)])
                        commands.append(dict(kind='texture',texture=entry_id,vertices=corners,intensity=sample.get('tint',[128]*3),blend=obj.get('blend','opaque'),depth=max(0,min(65535,anchor[2]))>>2))
                        continue
                    en=self.packet['entries'][entry_id];x,y,w,h=[en[k] for k in ('dx','dy','w','h')]
                    node_angles=sample.get('node_angles',[0,0,1]).copy();node_angles[2]+=self.variation(obj.get('random_node_angle'))
                    node_angles=[v+self.variation(term) for v,term in zip(node_angles,obj.get('random_node_angles',[None]*3))]
                    if 'particle_index' in obj and emitter.get('kind')=='bouncing_sprites' and part=='primary':node_angles[2]+=particle['node_rotation']
                    if lightning and part=='spark':node_angles[1]+=particle['spark_angle']
                    matrix=math_source.math_source.scale_matrix(math_source.math_source.rot_matrix(node_angles),[size]*3)
                    corners=[]
                    for px,py in ((x,y),(x+w,y),(x,y+h),(x+w,y+h)):
                        view=[((1024<<12 if axis==2 else 0)+matrix[3*axis]*px+matrix[3*axis+1]*py)>>12 for axis in range(3)]
                        corners.append([anchor[axis]+max(-1024,min(1023,view[axis]*1024//max(512,view[2]))) for axis in range(2)])
                    commands.append(dict(kind='texture',texture=entry_id,vertices=corners,intensity=sample.get('tint',[127]*3),blend=obj.get('blend','additive'),depth=max(5,min(379,anchor[2]//4))))
        for mesh in program['meshes']:
            if not mesh['start']<=update<mesh['stop']:continue
            sample=program['tracks'][mesh['track']][update];count=mesh['segments'];base=[origin(mesh['anchor'])[i]+mesh.get('origin',[0]*3)[i] for i in range(3)];lower=[];upper=[]
            if not sample.get('visible',True):continue
            if mesh['kind']=='strip':
                base=[base[i]+((sample.get('position',[0]*3)[i]+(target[i]-caster[i])*sample.get('target_weight',[0]*3)[i])>>12) for i in range(3)];anchor=math_source.projected(base,block)
                edges=mesh['strip_edges'][0 if len(mesh['strip_edges'])==1 else update]
                for i in range(count):
                    points=[]
                    for vertex in (edges[i][0],edges[i+1][0],edges[i][1],edges[i+1][1]):
                        projected=math_source.projected(vertex,block,centered=False);points.append([anchor[j]+projected[j] for j in range(2)])
                    commands.append(dict(kind='color',vertices=points,colors=[sample.get('tint',[127]*3)]*2+[mesh['inner']]*2,depth=mesh.get('depth',max(1,min(509,anchor[2]//4))),blend=mesh.get('blend','additive')))
                continue
            shape=mesh['shape_samples'][update] if mesh.get('shape_samples') else mesh
            segment_gap=mesh['segment_gaps'][update] if mesh.get('segment_gaps') else mesh.get('segment_gap',0)
            for i in range(count):
                angle=-(4096//count)*i
                if mesh['kind']=='band':
                    sign=1 if i<count//2 else -1;angles=sample.get('angles',[0]*3).copy()
                    angles[1]+=sign*mesh['opening'][update];angles[2]+=angle
                    lower.append(math_source.projected(math_source.transform((0,mesh['radius'],0),angles,self.sample_scale(sample),base),block))
                    angles[1]+=sign*mesh['spread'][update]
                    upper.append(math_source.projected(math_source.transform((0,mesh['radius'],0),angles,self.sample_scale(sample),base),block))
                else:
                    lower.append(math_source.projected(math_source.transform((shape['radius'],0,shape.get('base_height',mesh.get('base_heights',[0]*(update+1))[update])),[mesh.get('angles',[0]*3)[j]+(sample.get('angles',[0]*3)[j] if mesh.get('animated_angles') else 0)+(angle if j==2 else 0) for j in range(3)],self.sample_scale(sample),base),block))
                    if mesh['kind']=='column':upper.append(math_source.projected(math_source.transform((shape.get('top_radius',shape['radius']),0,shape['height'] if 'height' in shape else mesh['heights'][update]),[mesh.get('angles',[0]*3)[j]+(sample.get('angles',[0]*3)[j] if mesh.get('animated_angles') else 0)+(angle if j==2 else 0) for j in range(3)],self.sample_scale(sample),base),block))
            for i in range(count):
                j=(i+1)%count
                if mesh['kind']=='fan':points=[math_source.projected(base,block)[:2],lower[i][:2],lower[j][:2]];colors=[mesh['inner'],mesh['outer'],mesh['outer']];depth=mesh.get('depth',379)
                elif segment_gap:
                    angle=-(4096//count)*i-(4096//count-segment_gap)
                    angles=[mesh.get('angles',[0]*3)[axis]+(sample.get('angles',[0]*3)[axis] if mesh.get('animated_angles') else 0)+(angle if axis==2 else 0) for axis in range(3)]
                    end_lower=math_source.projected(math_source.transform((shape['radius'],0,shape.get('base_height',mesh.get('base_heights',[0]*(update+1))[update])),angles,self.sample_scale(sample),base),block)
                    end_upper=math_source.projected(math_source.transform((shape.get('top_radius',shape['radius']),0,shape['height'] if 'height' in shape else mesh['heights'][update]),angles,self.sample_scale(sample),base),block)
                    points=[upper[i][:2],end_upper[:2],lower[i][:2],end_lower[:2]];colors=[shape['inner']]*2+[shape['outer']]*2
                    depth=mesh.get('depth',max(1,min(378,sum(v[2] for v in (upper[i],end_upper,lower[i],end_lower))//16)))
                else:points=[upper[i][:2],upper[j][:2],lower[i][:2],lower[j][:2]];colors=[shape['inner']]*2+[shape['outer']]*2;depth=mesh.get('depth',max(1,min(509,lower[i][2]//4 if mesh['kind']=='band' else sum(v[2] for v in (upper[i],upper[j],lower[i],lower[j]))//16)))
                commands.append(dict(kind='color',vertices=points,colors=colors,depth=depth,blend=mesh.get('blend','additive')))
        for screen in program.get('screen_washes',[]):
            if update<len(screen['colors']) and screen['colors'][update] is not None:
                commands.append(dict(kind='color',vertices=[[0,0],[320,0],[0,240],[320,240]],colors=[screen['colors'][update]]*4,depth=screen['depth'],blend=screen['blend']))
        for e in self.emitters():
            if e.get('kind')=='inward_points' and e['start']<=update<e['stop']:
                for p in self.particles_for(e):
                    if p['active']:
                        q=math_source.projected([math_source.short(v+(p['head'][i]>>12)) for i,v in enumerate(e['origin'])],block)
                        commands.append(dict(kind='color',vertices=[q[:2],[q[0]+1,q[1]],[q[0],q[1]+1],[q[0]+1,q[1]+1]],colors=[e['color']]*4,depth=0,blend='opaque'))
            if e and e.get('kind','inward_lines') in ('inward_lines','falling_lines','rising_lines') and e['start']<=update<e['stop']:
                for p in self.particles_for(e):
                    if not p['active']:continue
                    base=e.get('origin',[0]*3) if e.get('kind')=='falling_lines' or e.get('anchor')=='world' else caster
                    head=[base[i]+(p['head'][i]>>12) for i in range(3)];tail=[base[i]+(p['tail'][i]>>12) for i in range(3)]
                    if e.get('kind')=='rising_lines':
                        head=math_source.transform([v>>12 for v in p['head']],[0]*3,p['spawn_scale'],target)
                        tail=math_source.transform([v>>12 for v in p['tail']],[0]*3,p['spawn_scale'],target)
                    if e.get('model_track') is not None:
                        sample=program['tracks'][e['model_track']][update]
                        head=math_source.transform([v>>12 for v in p['head']],sample.get('angles',[0]*3),self.sample_scale(sample),base)
                        tail=math_source.transform([v>>12 for v in p['tail']],sample.get('angles',[0]*3),self.sample_scale(sample),base)
                    a=math_source.projected(head,block);b=math_source.projected(tail,block)
                    commands.append(dict(kind='color',vertices=[a[:2],b[:2]],colors=[e['color']]*2,depth=max(1,min(509,b[2]//4)),blend='additive' if e.get('kind')=='falling_lines' else 'opaque'))
        for warp in program.get('background_warps',[]):
            from spell_scene_warp import commands as warp_commands
            commands.extend(warp_commands(warp,block,update,target if warp.get('anchor')=='target' else (0,0,0)))
        for layer in program.get('screen_layers',[]):
            if update>=len(layer['samples']) or layer['samples'][update] is None:continue
            sample=layer['samples'][update]
            for _ in range(layer.get('copies',1)):
                for entry,vertices in zip(layer['entries'],sample['vertices'],strict=True):commands.append(dict(kind='texture',texture=entry,vertices=vertices,intensity=sample.get('rgb',[sample['tint']]*3),depth=0,blend=layer.get('blend','additive')))
        return dict(update=update,camera=block,commands=commands,wash=program['wash'][min(update,len(program['wash'])-1)],wash_blend=program['wash_blend'],healed=update==program['impact'],draw_count=self.draw_count)


def beauty_vectors(packet,atlas):
    """Cross-consumer witnesses for the shared Unite VFX component, not scene admission."""
    cases=[]
    for seed in (0,17,32767):
        player=Player(packet,'beauty',atlas,seed=seed,unite=True)
        for update in (0,1,2,7,32,60,61,63,64,65,66,96,111,128,191,192,193,223,224,225):
            frame=player.frame(update,(0,0,0),(0,0,0));commands=frame['commands']
            selected=sorted({0,min(29,len(commands)-1),len(commands)//2,len(commands)-1}) if commands else []
            cases.append(dict(seed=seed,update=update,draw_count=player.draw_count,camera=frame['camera'],count=len(commands),
                particles=[{key:p[key].copy() if isinstance(p[key],list) else p[key] for key in ('age','phase','base_z','active','head','spawn_scale')} for p in player.particles[:30]],
                commands=[dict(index=i,texture=commands[i].get('texture'),vertices=commands[i]['vertices'],
                    depth=commands[i]['depth'],tint=commands[i]['intensity'],blend=commands[i]['blend']) for i in selected]))
    return dict(schema='suikoden-beauty-vfx-vectors/1',scope='Shared VFX component only; no live controller admission or visual acceptance',cases=cases)


def geometry_vectors(packet,atlas):
    """Portable consumer witnesses, checked independently by the Zig player."""
    cases=[]
    for spell,target in [('spell_1',(-120,40,0)),('spell_2',(-128,0,0)),('spell_3',(-128,0,0)),('spell_4',(-128,0,0)),('spell_5',(-128,0,0)),('spell_6',(112,0,0)),('spell_7',(112,0,0)),('spell_8',(-128,0,0)),('spell_9',(112,0,0)),('spell_10',(-128,0,0)),('spell_11',(112,0,0)),('spell_12',(112,0,0)),('spell_13',(-128,0,0)),('spell_14',(-120,40,0)),('spell_15',(112,0,0)),('spell_16',(-120,40,0)),('spell_17',(-120,40,0)),('spell_18',(-128,0,0)),('spell_19',(-120,40,45)),('spell_20',(-120,40,0)),('spell_21',(112,0,0)),('spell_22',(-120,40,0)),('spell_23',(112,0,0)),('spell_24',(-128,0,0)),('spell_25',(-152,-28,45)),('spell_28',(-120,40,45)),('spell_29',(-128,0,0)),('spell_30',(112,0,0)),('spell_31',(-128,0,0)),('spell_32',(-128,0,0)),('spell_33',(112,0,0))]:
        party=[dict(position=[112,40,0]),dict(position=[128,-40,0])] if spell in ('spell_7','spell_11','spell_12','spell_30') else []
        player=Player(packet,spell,atlas,party=party)
        boundaries=[player.program['impact'],player.program['duration']]+player.program.get('emitter',{}).get('spawn_at',[])
        boundaries += [at for emitter in player.program.get('emitters',[]) for at in emitter.get('spawn_at',[])]
        if spell=='spell_29':boundaries += [97,98,192,193,208,212,213,229,373,392,393,395,487,488,489,535,583,584,585,586]
        if spell=='spell_32':boundaries += [252,268,269,356,357,393,397,404,405,406,420,421,483]
        boundaries += [value for mesh in player.program['meshes'] for value in (mesh['start'],mesh['stop'])]
        for update in sorted(set([0,1,32,64,65,95,96,97,128,129,118,119,120,121,122,123,124,125,126,127,130,131,132,133,134,135,136,137,138,139,140,159,160,161,176,177,178,183,188,189,190,191,194,195,196,197,198,200,201,202,204,205,223,224,235,236,239,240,241,267,279,280,303,304,209,210,244,272,273,288,289,320,321,351,352,293,335,336,192,222,223,224,225,234,246,253,254,255,257,258,259,277,283,294,295,305,306,318,319,337,338,344,345,346,347,368,369,372,396,407,408,409,432,433,434,435,247,295,296,365,366,367,426,427,429,430,431,447,448,449]+boundaries)):
            if update>player.program['duration']:continue
            targets=[dict(position=[-128,40,0],center=[3,-9]),dict(position=[-144,-40,0],center=[-5,-13])] if spell=='spell_2' else [dict(formation_slot=0,position=[-120,36,0],center=[3,-9]),dict(formation_slot=2,position=[-152,-28,45],center=[-11,-15])] if spell=='spell_18' else []
            centers=dict(target_height=33) if spell=='spell_5' else dict(target_center=[3,-9],target_idle_center=[-5,-13]) if spell=='spell_17' else {}
            frame=player.frame(update,(120,50,0),target,targets=targets,**centers)
            commands=frame['commands'];subset=sorted(set([0,len(commands)//2,len(commands)-1]+(list(range(min(12,len(commands)))) if spell in ('spell_5','spell_17','spell_18','spell_19','spell_20','spell_21','spell_23','spell_25','spell_30','spell_33') else []))) if commands else []
            cases.append(dict(**centers,**({'party':party} if party else {}),spell=spell,update=update,caster=[120,50,0],target=list(target),targets=targets,draw_count=player.draw_count,camera=frame['camera'],wash=frame['wash'],count=len(commands),commands=[dict(index=i,texture=commands[i].get('texture'),vertices=commands[i]['vertices'],depth=commands[i]['depth']) for i in subset]))
    player=Player(packet,'spell_14',atlas);caster=[-64,-80,12];target=[192,96,45]
    for update in (145,150,164,180,192):
        frame=player.frame(update,caster,target);commands=frame['commands']
        subset=sorted(set([0,len(commands)//2,len(commands)-1])) if commands else []
        cases.append(dict(spell='spell_14',update=update,caster=caster,target=target,targets=[],draw_count=player.draw_count,camera=frame['camera'],wash=frame['wash'],count=len(commands),commands=[dict(index=i,texture=commands[i].get('texture'),vertices=commands[i]['vertices'],depth=commands[i]['depth']) for i in subset]))
    return dict(seed=17,cases=cases)

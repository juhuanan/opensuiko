"""Shared three-ring sampler and Voice of Earth's imported playback program.

No framebuffer or oracle pixels are exported. Playback samples the port's
distant-ground pass; human visual acceptance remains a separate gate.
"""
import argparse
import hashlib
import json
from pathlib import Path

import battle_drops as math_source
import spell_scene_source as source

SPANS = (
    (0x80112AB4, 0x80112CA8, '5f2e9856610a5c881d4477338941c38c8c40f3bbb2b7c978e4d658bf1cda088a'),
    (0x80112CA8, 0x801136F4, '5873c26389fcf351566ae84507b472a99da9c4be728bbe11065519585fa089e3'),
    (0x8011DDD4, 0x8011E07C, '3e18ed6701799f5f704b13b552a27f7214b7b9a6f70c5d47decf43fc4c88338d'),
    (0x8011E0EC, 0x801204EC, '3fc3e4d11dc99f0e73ee1f4432dfcdbcbad4ef3d048a96145c0f7b208e8078c5'),
    (0x8011CE64, 0x8011CEF8, '5a3eae856995a8e596beaa70712155a07779c2b443c902f8f7a58f082cc85d69'),
    (0x8011D548, 0x8011D760, '52449a3f29de02b3ed48ff6989a5dac36fe7fa16f5c2939131ba38c252bf8620'),
    (0x8011D7A0, 0x8011DDD4, '39fadbef5aa453d038c7be871352372ff4c594e57448b2e8399c8b62cf333179'),
    (0x800E4738, 0x800E4974, '5b768463b9a0481cc308d9c9f6f0d62638a5d27ad2ab78e5795024c1b4d5437e'),
    (0x800E3710, 0x800E37C4, '6db2ea2f2dce39fcd6c0b67b0b4cf2ea436bd5d38ddc79b0b1bc1b3c4f182449'),
    (0x8016E520, 0x8016E5A4, '4ecc3da628d68a1ce7aaec3266e1ec8aeeb2e13314ebed5adb11d89d7c4015be'),
)


CONSUMERS = ((22,0x80112AB4,0x80112CA8),(25,0x80113A90,0x80113E98),
             (26,0x801148D4,0x80114CA8),(27,0x8011567C,0x80115A7C))

def voice_state(update):
    if not isinstance(update, int) or not 0 <= update <= 322:
        raise ValueError('invalid Voice of Earth update')
    from export_spell_scenes import effect_sine
    n = min(max(update - 128, 0), 64)
    phase_scale = 1 + min(n, 49) * 349525 - max(n - 49, 0) * 1048576
    root_scale = 1 if update >= 192 else phase_scale
    ring_scale = root_scale
    if update >= 257:
        k = min(update - 256, 64)
        ring_scale += 524288 * (min(k, 16) - min(max(k - 16, 0), 16))
    radii = [120, 152, 184]
    if update >= 193:
        count = min(update - 192, 64)
        radii = [40 + math_source.trunc(20 * effect_sine(count * 64), 4096),
                 80 + math_source.trunc(20 * effect_sine((count + 32) * 64), 4096), 120]
        if update >= 257:
            change = 2 * (min(update - 256, 16) - min(max(update - 272, 0), 16))
            radii[1] += change; radii[2] += change
    actor_scale = 4096 - 85 * min(max(update - 144, 0), 48) + 85 * min(max(update - 256, 0), 49)
    # The phase clock is incremented before the common draw tail.
    shake_age = min(max(update - 128, 0), 191)
    shake_delta = 682 * min(n, 49) - 512 * min(max(update - 256, 0), 64)
    active = 129 <= update < 320
    return dict(update=update, caster_visible=0 < update < 97,
                caster_size=1 + 64 * min(update, 64), caster_angle=1 + 64 * min(update, 64),
                caster_tint=(2 * min(update, 64) - 4 * min(max(update - 64, 0), 32)) & 255,
                ring_active=active, ring_scale=ring_scale >> 12,
                warp_active=active, warp_scale=(phase_scale >> 12) if 129 <= update <= 192 else 4096,
                warp_radii=radii, warp_twist=0,
                wash=min(update, 64) - min(max(update - 256, 0), 64),
                actor_scale=actor_scale, actor_inbound=update == 145, actor_return=update == 273,
                camera_pulse_delta_q12=shake_delta if active and shake_age % 2 == 0 else None,
                camera_pulse_duration=1 if active and shake_age % 2 == 0 else None,
                damage=update == 320, cleanup=update == 322)


def ring_vertices(segments, radii, scale, origin, angles=(0, 0, 0), twist=0):
    """UV and destination world rings, before camera projection and page selection."""
    if (not isinstance(segments, int) or not 3 <= segments <= 64 or len(radii) != 3 or
            len(origin) != 3 or len(angles) != 3 or not isinstance(twist, int) or abs(twist) > 32767 or
            any(not isinstance(v, int) or abs(v) > 32767 for v in (*radii, *origin, *angles)) or
            not isinstance(scale, int) or not 0 <= scale <= 65536):
        raise ValueError('invalid screen-sampling rings')
    step = 4096 // segments
    uv_radii = [math_source.trunc(radii[2], 3), math_source.trunc(2 * radii[2], 3), radii[2]]
    uv = []; destination = []
    for layer in range(3):
        uv_ring = []; destination_ring = []
        for i in range(segments):
            uv_ring.append(math_source.transform((0, uv_radii[layer], 0), (0, 0, -step * i), (scale,) * 3, origin))
            rotated = (*angles[:2], angles[2] - (2 - layer) * twist - step * i)
            destination_ring.append(math_source.transform((0, radii[layer], 0), rotated, (scale,) * 3, origin))
        uv.append(uv_ring); destination.append(destination_ring)
    return dict(center=list(origin), uv=uv, destination=destination,
                faces=[dict(layer=layer, indices=[i, (i + 1) % segments]) for layer in range(3) for i in range(segments)])



def parabolic_path(start, end, updates, velocity):
    """Actor move equations: position first, acceleration second, exact final snap."""
    if (not isinstance(updates,int) or not 2 <= updates <= 1024 or
            any(len(v) != 3 for v in (start,end,velocity)) or
            any(not isinstance(v,int) or abs(v) > 32767*4096 for v in (*start,*end,*velocity))):
        raise ValueError('invalid parabolic move')
    steps=updates*(updates-1)//2
    acceleration=[math_source.trunc(b-a-v*updates,steps) for a,b,v in zip(start,end,velocity)]
    path=[list(start)]
    for t in range(1,updates):
        p=[a+v*t+d*(t*(t-1)//2) for a,v,d in zip(start,velocity,acceleration)]
        if any(not -(1<<31) <= v < 1<<31 for v in p):raise ValueError('parabolic move exceeds signed word')
        path.append(p)
    return path+[list(end)]

def voice_profile(image=None):
    image = image or source.Image()
    for start, stop, digest in SPANS:
        if hashlib.sha256(image.data[start-image.base:stop-image.base]).hexdigest() != digest:
            raise ValueError('Voice of Earth or shared warp source changed; requalify')
    guards = {0x800DF184:0x24B10050, 0x800DF210:0xAE200068, 0x800DF218:0xAE20006C, 0x800DF220:0xAE200070,
              0x800E7F54:0x8622000C, 0x800E7F5C:0x2453017C, 0x800E7F70:0x288201FE,
              0x800E7F7C:0x340401FD, 0x800DE0E0:0x0040F809,
              0x800DE1C8:0x0C03800D, 0x800E003C:0x0C0383A8, 0x800E0044:0x0C03826F,
              0x800E0C64:0x0C038D63, 0x8014F5EC:0x00021083}
    if any(image.word(pc) != word for pc, word in guards.items()):
        raise ValueError('screen-sampling ground order or reserved actor changed')
    for _, initializer, updater in CONSUMERS:
        init_calls={event[1] for _,event in source.Analysis(image,initializer,cut_backedges=True).events('call')}
        update_calls={event[1] for _,event in source.Analysis(image,updater,cut_backedges=True).events('call')}
        if not {0x8011DDD4,0x8011CE64} <= init_calls or 0x8011E0EC not in update_calls:
            raise ValueError('shared screen-sampling consumer changed')
    facts, analysis = source.analyze(0x80112AB4, image)
    if [p['updates'] for p in source.timeline(facts, analysis)] != [64, 64, 64, 64, 64, 1, 1]:
        raise ValueError('unresolved Voice of Earth phases')
    return dict(schema='suikoden-voice-earth-warp/3', producer='spell-scene-warp/3', runtime_ready=True,
                sampler_status='headless_verified', blockers=[],visual_acceptance='pending',
                consumers=[dict(spell=f'spell_{spell}',initializer=a,updater=b) for spell,a,b in CONSUMERS],
                source=dict(file='MAIN.EXE', lba=17976, size=757760, image_base=image.base,
                            spans=[dict(start=a, stop=b, sha256=h) for a,b,h in SPANS]),
                phases=[64,64,64,64,64,1,1], impact=320, release=322, initial_draws=0,
                cameras=[dict(at=1,updates=60,block=0x8016E260),dict(at=65,updates=60,block=0x8016E410)],
                schedule='Action callback800DE0E0 precedes camera update800E003C and actor update800E0044. A duration1 focus pulse applies on the same callback update and restores the unchanged target on the next. Actor movement likewise takes its first step on145/273.',
                sampler=dict(origin=[-120,0,0], segments=24, texture_mode='direct16', texture_origin=[640,256],
                             viewport=[320,240], enter_depth=510, restore_depth=381, draw_depth=380,
                             source_ground_depth=[380,509], capture_ground_depth=[382,509],
                             vertex_color=[127]*3, blend='opaque',
                             mapping='UV rings use outer_radius/3,2*outer_radius/3,outer_radius and zero model angles. Destination rings use three separate radii and Z angles base-2*twist,base-twist,base. Close the last segment to vertex0, not another truncated angle step.',
                             page='For each triangle/quad choose the smallest projected source X, truncate toward zero to a64-word boundary, then wrap UV components to unsigned8. V adds120. Resolve pages before port sampling; do not interpolate across a wrapped page boundary.'),
                ring=dict(segments=24,radius=120,origin=[-120,0,0],depth=380,center_color=[255]*3,rim_color=[255]*3,blend='subtractive'),
                target=dict(excluded_flag=32, exclude_ko=True, inbound_at=145,return_at=273,
                            inbound_snap=176,return_snap=304,
                            movement='Initial Q12 velocity is operand<<11; acceleration truncates (destination-current-velocity*updates)/(updates*(updates-1)/2). Add velocity to position before acceleration; snap exactly to the destination on the final update.',
                            inbound=dict(frames=32,destination=[-120,0,0],velocity_q12=[0,0,-16384]),
                            returning=dict(frames=32,destination='home',velocity_q12=[0,0,-32768]),
                            scale='Subtract85 on145..192, hold16 through256, add85 on257..305, retaining4181 afterward.'),
                samples=[voice_state(u) for u in range(323)])



def voice_geometry(profile=None):
    profile=profile or voice_profile()
    count=profile['sampler']['segments'];samples=[]
    for state in profile['samples']:
        if not state['warp_active']:samples.append(None);continue
        rings=ring_vertices(count,state['warp_radii'],state['warp_scale'],profile['sampler']['origin'],twist=state['warp_twist'])
        samples.append(dict(source=[rings['center']]+[v for ring in rings['uv'] for v in ring],
                            destination=[rings['center']]+[v for ring in rings['destination'] for v in ring]))
    faces=[]
    for layer in range(3):
        for i in range(count):
            a=1+layer*count+i;b=1+layer*count+(i+1)%count
            faces.append(dict(indices=[0,a,b,0] if layer==0 else [a-count,b-count,a,b],count=3 if layer==0 else 4))
    return dict(depth=profile['sampler']['draw_depth'],samples=samples,faces=faces)



def ground_depth(projected_z):
    return max(380,min(509,380+(max(0,min(65535,int(projected_z)))>>2)))

def commands(warp,block,update,translation=(0,0,0)):
    if update>=len(warp['samples']) or warp['samples'][update] is None:return []
    mesh=warp['samples'][update];result=[]
    for face in warp['faces']:
        ids=face['indices'][:face['count']]
        uv=[math_source.projected([math_source.short(v+translation[a]) for a,v in enumerate(mesh['source'][i])],block) for i in ids]
        vertices=[math_source.projected([math_source.short(v+translation[a]) for a,v in enumerate(mesh['destination'][i])],block)[:2] for i in ids]
        tile=math_source.trunc(min(p[0] for p in uv),64)*64
        result.append(dict(kind='background',vertices=vertices,background_uv=[[tile+(p[0]-tile)%256,p[1]%256] for p in uv],
                           blend='opaque',intensity=[127]*3,depth=warp['depth']))
    return result


def geometry_fixture(updates=(0,128,129,130,160,177,191,192,193,224,256,272,288,319,320,322)):
    import export_spell_scenes as export
    import spell_effect_sweep
    from spell_scene_player import Player
    profile=voice_profile();geometry=voice_geometry(profile)
    effect=next(e for e in spell_effect_sweep.build()['effects'] if e['name']=='Voice of Earth')
    cameras=export.source_cameras(effect);focus=cameras[-1]['target']['position']
    program=dict(initial_draws=0,cameras=cameras,focus_samples=[None if s['camera_pulse_delta_q12'] is None else [focus[0],focus[1],focus[2]+(s['camera_pulse_delta_q12']>>12)] for s in profile['samples']])
    from PIL import Image
    player=Player(dict(entries=[],spells=[dict(id='spell_22',name='Voice of Earth',program=program)]),'spell_22',Image.new('RGBA',(1,1)))
    cases=[]
    for update in updates:
        block=player.camera(update)
        cases.append(dict(update=update,block={k:block[i*3:i*3+3] for i,k in enumerate(('position','angles','c','d'))},commands=commands(geometry,block,update)))
    return dict(warp=geometry,cases=cases)


def voice_program(effect,pieces):
    if int(effect['initializer'],16)!=0x80112AB4:return None
    import export_spell_scenes as export
    profile=voice_profile();rows=profile['samples'];cameras=export.source_cameras(effect)
    focus=cameras[-1]['target']['position']
    caster=[export.sample(pieces[0] if s['caster_visible'] else None,position=[0,0,-70*4096],size=s['caster_size'],node_angles=[0,0,s['caster_angle']],tint=[s['caster_tint']]*3) for s in rows]
    disc=[export.sample(None,scale=[s['ring_scale']]*3) for s in rows]
    offsets=([[-5,0]]*5+[[0,0]]*5+[[5,0]]*5)*2
    offsets=offsets[1:]+[[0,0]]*3
    return dict(group=True,center_after_reaction=False,impact=320,duration=322,initial_draws=0,
                tracks=[caster,disc],objects=[dict(anchor='caster',track=0)],cameras=cameras,
                focus_samples=[None if s['camera_pulse_delta_q12'] is None else [focus[0],focus[1],focus[2]+(s['camera_pulse_delta_q12']>>12)] for s in rows],
                meshes=[dict(kind='fan',anchor='world',origin=[-120,0,0],track=1,start=129,stop=320,radius=120,segments=24,angles=[0,0,1024],inner=[255]*3,outer=[255]*3,depth=380,blend='subtractive')],
                background_warps=[voice_geometry(profile)],wash=[[s['wash']]*3 for s in rows],wash_blend='subtractive',
                reaction=dict(start=273,release=32,animation=1,offsets=offsets,flash_frames=[3]*32),
                actor_motion=dict(start=145,returning=273,updates=32,destination=[-120,0,0],velocity=[0,0,-16384],return_velocity=[0,0,-32768],size_delta=[s['actor_scale']-4096 for s in rows],exclude_airborne=True,exclude_protected=True))


def actor_sample(motion,home,update,origin=None,return_origin=None,size_base=4096):
    if update<motion['start']:return None
    destination=[v*4096 for v in motion['destination']]
    returning=update>=motion['returning'];at=motion['returning'] if returning else motion['start']
    start=(return_origin or destination) if returning else (origin or [v*4096 for v in home])
    end=[v*4096 for v in home] if returning else destination
    path=parabolic_path(start,end,motion['updates'],motion['return_velocity'] if returning else motion['velocity'])
    return dict(position=path[min(update-at+1,motion['updates'])],size=size_base+motion['size_delta'][update])

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--geometry-out',type=Path,help='explicitly regenerate the native conformance fixture')
    args=parser.parse_args();args.out.parent.mkdir(parents=True,exist_ok=True)
    args.out.write_text(json.dumps(voice_profile(),indent=2)+'\n')
    if args.geometry_out:
        args.geometry_out.parent.mkdir(parents=True,exist_ok=True)
        args.geometry_out.write_text(json.dumps(geometry_fixture(),separators=(',',':'))+'\n')


if __name__=='__main__':main()

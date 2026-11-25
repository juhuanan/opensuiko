#!/usr/bin/env python3
"""Unite initializers, member scripts and camera operations from existing sources."""
import json
import hashlib
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import character_table
import export_first_room as field
import journey_battle
import maindec
from unite_catalogue import resource_script_loads, reaction_binding, hit_gate_binding
from spell_scene_source import Image

ROOT = Path(__file__).resolve().parents[2]
CATALOGUE = ROOT / 'game/assets/battle_systems/unite_catalogue.json'
STARTUP_ONLY_RECORDS = frozenset((10, 14, 27, 29, 31))
OPS = {17, 18, 19, 20}



def pair_startup(record, image):
    """Prove the initializer's first actor pass in primary invocation units."""
    expected = {
        0x800F9758: (0x800F9758,0x800F98A0,'4779c8982e4106ceac972d7561224a45b9a9439b3a4e0d97a388d1acd844509d'),
        0x800F9920: (0x800F9920,0x800F9A68,'6266a122b20f35b1902aea1e0424d70b06a40cb5b8be7ebb8f11af10ead62c99'),
        0x800FA064: (0x800FA064,0x800FA18C,'16e28826985ff4b9a4dc03340e3c4aa68b2521b136a699f6701462dcb641b3e1'),
        0x800FA20C: (0x800FA20C,0x800FA334,'09c48d55dc893a63bc0b47e8385441edc92787495c674d4bb455eabe07687e45'),
        0x800FC198: (0x800FC198,0x800FC2C0,'9ab3de7e9b8d7930fcd232364ce9c59c1715bc33b1e67d791a8f21bbaca163aa'),
        0x800FD09C: (0x800FD09C,0x800FD1D0,'9ef8be9f946b5d7daa582c84630386a7062d680e9da9688cf625a8e21f3e158b'),
        0x800FB9E4: (0x800FB9E4,0x800FBAF8,'af740df2980b108d2a0a1f4399e3681614bba885d98291e81c7c757feddf8cc9'),
        0x800FA658: (0x800FA658,0x800FA764,'fee1c1a00ad44c78b2aec2f6258806a0cda3555fc8d334996722fd6f8f8f1176'),
        0x800F9AE8: (0x800F9AE8,0x800F9CE8,'e9827b48bfab934b15a6a27b98ac32cb2004fce2fcffb049c7985c4779d17ec6'),
        0x800FBCB4: (0x800FBCB4,0x800FBEE0,'84e91a400f67e1cf8a0b52745905976d26d4af4b2dc0c16d9c3b845a691afb59'),
        0x800FB428: (0x800FB428,0x800FB63C,'d4020fe4ee4c51c5b4cabdf1dddb91fc9299604c65363614c24c53ca1c8e1405'),
        0x800FD2FC: (0x800FD2FC,0x800FD42C,'902bce8802ed6446f6c5553fbc182eb5c4f3f78527e9d5a6983cee04f5ee46ee'),
        0x800FDE20: (0x800FDE20,0x800FE000,'27835ae25cba041016e4f09dfd30957e197425ec5d0315743f63471a795a760c'),
        0x800FE680: (0x800FE680,0x800FE84C,'d52535dd1b5b94030c36a5a11bb4ee1d93412ff6111d8bc55a6cb38a1bb38b1e'),
        0x800FE3A8: (0x800FE3A8,0x800FE4FC,'7dc3bf30a9aa0082dfbfeb96125a480ebafa2513c3347fcfa816c4ab187ca819'),
    }
    start, update, digest = expected[record['handler']]
    if record['handler'] != start or record['update'] != update or image.end(start) != update:
        raise ValueError('Unbound pair initializer')
    data = image.data[start-image.base:update-image.base]
    if hashlib.sha256(data).hexdigest() != digest:
        raise ValueError('Pair initializer changed')
    for address, word in {0x800DE0E0:0x0040F809,0x800DE1C8:0x0C03800D,
        0x800F438C:0x3C02800F,0x800F4390:0x24424550,0x800F43BC:0xAC220000,
        0x800F4574:0x0040F809,0x800F4580:0x1043000C,
        0x800E3890:0x0040F809,0x800E3898:0x10400006,0x800E38AC:0x08038E21,
        0x800E0A74:0x0C038AA7,0x800E0A7C:0x0C038D63}.items():
        if image.word(address) != word:raise ValueError(f'Pair startup changed at {address:#x}')
    if image.word(0x8016D2D0+4*record['unite_id']) != start:
        raise ValueError('Pair initializer table changed')
    return dict(units='primary_coordinator_updates',selection=0,initializer=1,
        first_actor_sweep=1,first_callback=2,dispatch='selected_primary_before_first_actor_sweep',
        initializer_sha256=digest,native_mapping='selection_clock_verified',vm_playback='pair_primary_and_return_bound',
        native_gate='game/tests/battle_systems/unite_playback.zig: live qualified Unite batches retain source clocks and independent member ownership',
        scope='Qualified primary/return VM programs drive native poses, positions, signals, camera requests, recovery and retained trail rendering; audio output, other families and visual acceptance remain unfinished.')


def wild_arrow_schedule(record, members, image):
    import spell_scene_objects
    start,end=0x800F9CE8,0x800FA064
    digest='820b2afc5557c5f34a0b847f5042065a90dd2ce41c7558447f5b96f458cfeabe'
    if record['update']!=start or image.end(start)!=end or hashlib.sha256(image.data[start-image.base:end-image.base]).hexdigest()!=digest:
        raise ValueError('Wild Arrow controller changed')
    startup=pair_startup(record,image)
    startup.update(native_mapping='selection_clock_verified',vm_playback='group_primary_return_and_fans_bound',
                   native_gate='game/tests/battle_systems/unite_batches.zig: Wild Arrow scenes bind source profiles group damage fans and returns for every owner',scope='Normal native dispatch with complete member art and source profiles is headless verified; KO, audio, overlapping actions and visual acceptance remain unfinished')
    helpers=[]
    for address,stop,sha in (
        (0x801233B4,0x801234D0,'445f9fd3169761fa1175ba0a4bdecc702f320f2d55c351013670c9e2d6db1fd8'),
        (0x80123720,0x801238E0,'4dc2c2da15c8ef6b434a85494b643cc7376d609f97ec430262c0dd5adbdc851a'),
        (0x800E256C,0x800E2A9C,'4b3ca11a11d75980116f6ee71ab7a276804260f6c74624b14bb12667d67f3ca2')):
        if image.end(address)!=stop or hashlib.sha256(image.data[address-image.base:stop-image.base]).hexdigest()!=sha:
            raise ValueError('Wild Arrow graphic helper changed')
        helpers.append(dict(address=address,size=stop-address,sha256=sha))
    constructors=spell_scene_objects.constructors(dict(initializer=record['handler'],preparation=[],state_global=0x8017A010),image)
    objects=constructors['objects']
    if constructors['blocked'] or len(objects)!=10:raise ValueError('Unbound Wild Arrow object constructors')
    fans=[]
    for member in range(2):
        group=[o for o in objects if o['indices'][0]==member]
        if len(group)!=5 or any(o['animation']!=17 or o['enabled']!=0 or o['size']!=4096 or o['initial'][76]!=32 or o['node_initial']!={28:400} for o in group):
            raise ValueError('Wild Arrow fan descriptor changed')
        raw,origin=field.source('/'+members[member]['source']['file'].split('/')[-1])
        animations,flags,_=animation_frames(raw)
        if flags[17]!=1 or len(animations[17])!=1:raise ValueError('Wild Arrow initial arrow pose changed')
        fans.append(dict(member=member,animation=17,pose=animations[17][0][0],source=origin,
            rolls=[o['initial'][68] for o in group],node_angles=[0,0,400],initially_visible=False,
            trigger_signal=16,velocity_q12=[-49152,0,0],anchor_z=-40,
            frame_driver='controller draws initial pose; does not call object animation updater'))
    return dict(startup=startup,controller=dict(address=start,size=end-start,sha256=digest),
        damage_member=1,assist_member=0,reaction_group=True,
        targets='ascending live enemy slots; skip B+0x45==1',multiplier=10,damage_count=2,
        callback_order=['member_hit_reactions_or_group_damage','fan_signal_activation','fan_movement_and_draw','member_ready_and_return','all_ready_object_free'],
        constructors=json.loads(json.dumps(constructors)),graphic_helpers=helpers,fans=fans,
        graphic_contract=dict(rotation='node angles; rotated branch when any angle nonzero',corner_extents='raw width/height plus one',depth='world projection quarter-depth clamped to 5..379',fan_position='rotate integer local Q12 position then add member XY and fixed Z; anchor captured before actor sweep'),
        admission='native_vm_scene_bound_visual_acceptance_pending',
        scope='Shared controller for records2/19/20; first member signals a group reaction, second member signals one combined group damage pass')


def beauty_scene_controller(record, members, image):
    """One source controller for both three-member Beauty combinations."""
    import spell_scene_objects
    spans=(
        (0x800FC410,0x800FC438,'fa45dab3ba373535401d3e7f44b39f4a7eaaa5fa2d2da6f5b670b3c0cf8ece92'),
        (0x800FC438,0x800FC64C,'7be617d112d7e660862961703b3ece4482eabf76c98cdc68c5aa645e53d7268e'),
        (0x800FC64C,0x800FCD1C,'a5574b8083060689676f0225e306686ea2d71cfb663e6e1209c94e665971dee5'),
        (0x800F9114,0x800F9178,'e88f8fe06783380bb48125b98265205f46374aef648cf99223bcfb2b61987dd8'),
        (0x800F9178,0x800F91C0,'7086e55f217d5ebd66b9e293bfbc4eea9cf1cc53312f8fa0422f384f787d362b'),
        (0x80123054,0x80123258,'47fe22ab009b883537b4c9de4da88d67ebc89ecf86c194143bda66096411cde9'),
        (0x80122AAC,0x80122BAC,'c9aa20d6e9f85db2ba0b33da7cc7b349e3a8ea383173748b6667715903697cea'),
        (0x80122BAC,0x80122EB4,'068a1859e1573e6a3b350fcc79e0acbeca169d023e1c54ce7781cb5973e7e6f1'),
        (0x801233B4,0x801234D0,'445f9fd3169761fa1175ba0a4bdecc702f320f2d55c351013670c9e2d6db1fd8'),
        (0x800F6110,0x800F62D4,'a9d5ebe82b6a1c6e670e83267fb1e727f632e0b4671592126e1c26c082d45966'),
        (0x801238E0,0x80123974,'14c0ab74e12d9417dda9582dea1a69d9d492195d57c5fa23dac394acaf42cee6'),
        (0x80123720,0x801238E0,'4dc2c2da15c8ef6b434a85494b643cc7376d609f97ec430262c0dd5adbdc851a'),
        (0x800E5A08,0x800E5AFC,'7671362ad5439615e722e7fd34f9a4d09f3e7f28894bf1474b6c7e64666db825'),
        (0x800E6AB8,0x800E6D38,'4c431d4adb9b245748d2810d83f7f9e6eccf1613b4ba87e39512502ca3f5957f'),
        (0x800E04DC,0x800E0778,'1a9254e29d9a9adce8f9d562361d9724d59425fb508ed1d6dd421682c45f52d7'),

    )
    if record['index'] not in (9,25) or record['handler']!=spans[0][0] or record['callback_chain']!=[spans[1][0],spans[2][0]]:
        raise ValueError('Beauty callback chain changed')
    blocks=[]
    for start,end,digest in spans:
        if image.end(start)!=end or hashlib.sha256(image.data[start-image.base:end-image.base]).hexdigest()!=digest:
            raise ValueError('Beauty source helper changed')
        blocks.append(dict(address=start,size=end-start,sha256=digest))
    camera_bytes=image.data[0x8016CC1C-image.base:0x8016CC1C-image.base+48]
    camera_digest='a0fd1e8456b31ca4d8e8b3e27bc0c2589fa660b7e78117f1a0ef0da12d9b1f72'
    if hashlib.sha256(camera_bytes).hexdigest()!=camera_digest:raise ValueError('Beauty camera block changed')
    blocks.append(dict(address=0x8016CC1C,size=48,sha256=camera_digest))
    camera=list(struct.unpack('<12i',camera_bytes))
    constructors=spell_scene_objects.constructors(dict(initializer=0x800FC438,preparation=[],state_global=0x8017A010),image)
    objects=constructors['objects']
    if constructors['blocked'] or len(objects)!=30 or any(o['animation']!=13 or o['looping']!=1 or o['enabled']!=0 or o['size']!=1365 or o['slot']!=4*i for i,o in enumerate(objects)):
        raise ValueError('Beauty graphic constructors changed')
    clocks=[]
    for index,member in enumerate(members):
        if [s['script'] for s in member['scripts']]!=[10]:raise ValueError('Beauty member program changed')
        raw,origin=field.source('/'+member['source']['file'].split('/')[-1])
        animations,flags,_=animation_frames(raw)
        timing=journey_battle.script_events(animations,journey_battle.script(raw,10),flags)
        clocks.append(dict(member=index,script=10,events=timing['events'],duration=timing['duration']))
    raw,origin=field.source('/'+members[0]['source']['file'].split('/')[-1])
    operations=journey_battle.script(raw,15)
    offset=struct.unpack_from('<I',raw,struct.unpack_from('<I',raw,32)[0]+60)[0]
    size=sum(2+2*len(args) for op,args in operations)
    digest=hashlib.sha256(raw[offset:offset+size]).hexdigest()
    if digest!='a59d0346a15abc654739e7c8f55fc430d51d34a5f177bb1998831b0fe9800971':
        raise ValueError('Beauty recipient descriptor changed')
    recipient_clock=journey_battle.script_events([],operations)
    return dict(id='beauty',records=[9,25],blocks=blocks,
        constructors=dict(site=objects[0]['site'],count=len(objects),slots=[o['slot'] for o in objects],loop=objects[0]['loop'],
            animation=13,looping=True,enabled=False,node_scale=1365,dynamic_parameters=['sway_age']),
        clocks=json.loads(json.dumps(clocks)),
        contract=dict(
            startup=dict(resource='battle_spell_page_pool',load_request='table_handler',ready_poll='asynchronous',
                member_scripts=[10,10,10],first_sweep='initializer completes before actor sweep; no invented CD wait duration'),
            trigger=dict(member=0,signal=16,retained=True),
            camera=dict(on='rise_entry',updates=60,focus_q12=camera[:3],angles_q12=camera[3:6],translation_q12=camera[6:9],scale_q12=camera[9:],advance='next update; integrator precedes callback'),
            phases=[dict(id='rise',updates=64,translation_delta=[-2,0,0],scale_accumulator_delta=262144,node_scale_delta=64,wave_rgb_q12_delta=[5120,3072,3072]),
                    dict(id='sway',updates=128,rotation_delta=16,recipient_reaction_on_entry=True,reset_recipient_angles_on_exit=True,respawn_finished_particles=True),
                    dict(id='fade',updates=32,rotation_delta=16,node_scale_delta=-128,wave_rgb_q12_delta=[-10240,-6144,-6144],group_damage_on_exit=True,return_all_members_on_exit=True),
                    dict(id='cleanup',updates=1,free_graphics=True)],
            graphics=dict(section=7,animation=13,count=30,initial_node_scale=1365,enabled_after_sphere=True,initial_rgb=[127,127,127],initial_translation=[0,0,-40],
                initial_draws_per_particle=5,draw_order=['animation_warmup_mod32','sway_phase_mod64','sphere_x','sphere_y','sphere_z'],
                sphere_radius=150,sphere_sampling='three-draw hemisphere helper with source lookup square root',initial_scale_q12=[4096]*3,
                warmup='advance animation only; preserve sway phase counter',
                oscillation=dict(axis='z',amplitude_q12=122880,phase_step=32,age_step=1),
                phase1_looping=False,respawn_draws=3,respawn='use current object Q12 scale, retain original base Z and sway age'),
            wave=dict(section=3,animation=2,amplitude=50,period=200,width=320,initial_rgb_q12=[0,0,0],initially_visible=False),
            recipient=dict(script=15,tint=[192,64,64],white=True,hold_updates=128,reset_tint=[128]*3,
                source_clock=dict(units='descriptor wait clocks before frame-driver alignment',tint_on=3,tint_restore=131,status_attempt=133),
                rotation=dict(set_x=1,roll='trunc(source_sine(phase_age*64)/16)',preserve_y=True,reset_xz_on_phase_exit=[0,0]),
                status=dict(class_id=5,name='sleep',failure_percent=30,draw_mapping='((draw*100)//32767)%100',timing='after return-home command',duplicates='existing Sleep bit stays set; probability draw is still consumed')),
            damage=dict(count=3,multiplier=4,divisor=10,targets='ascending enemy slots; shared helper skips inactive target status',reaction='none in shared helper'),
            drawing=dict(gate='first member flag16; none before trigger or on cleanup',call_order=['wave','enabled_particles'],object_scale='shared scale accumulator >>12; full signed word',particle_order='ascending; animation advances before node projection')),
        recipient_source=dict(source=origin,source_offset=offset,byte_length=size,sha256=digest,operations=[dict(op=op,args=list(args)) for op,args in operations],
            local_timing=dict(status='actor_local_wait_clocks',duration=recipient_clock['duration'],operation_ticks=recipient_clock['operation_ticks'])),
        admission='native_vm_scene_bound_visual_acceptance_pending',
        unresolved=['KO behavior, audio, overlapping actions and human media acceptance'])


def bumpy_phase_schedule(record, members, image):
    start,end=0x800FA764,0x800FA9CC
    digest='01468b063bbf45964e3ca31d5982a672139a9c34455d41d8227e6310faa8fd24'
    if record['index']!=6 or record['update']!=start or image.end(start)!=end or hashlib.sha256(image.data[start-image.base:end-image.base]).hexdigest()!=digest:
        raise ValueError('Bumpy controller changed')
    startup=pair_startup(record,image)
    startup.update(vm_playback='phased_pair_with_secondary_damage_signal',scope='Krin starts before the first sweep; Humphrey starts after80 callback invocations; flag2 controls transition/reaction while flag16 applies damage')
    if [s['script'] for s in members[0]['scripts']]!=[10,11] or [s['script'] for s in members[1]['scripts']]!=[9]:raise ValueError('Bumpy member programs changed')
    clocks=[]
    returns=journey_battle.script_at(maindec.body(),0x8016D214-maindec.MBASE)
    for member,script in ((0,11),(1,9)):
        raw,_=field.source('/'+members[member]['source']['file'].split('/')[-1])
        animations,flags,_=animation_frames(raw)
        operations=journey_battle.script(raw,script)
        primary=journey_battle.script_events(animations,operations,flags)
        complete=journey_battle.script_events(animations,operations+returns,flags)
        clocks.append(dict(member=member,script=script,events=primary['events'],primary=primary['duration'],complete=complete['duration']))
    return dict(startup=startup,controller=dict(address=start,size=end-start,sha256=digest),clocks=json.loads(json.dumps(clocks)),
        entries=[dict(member=0,script=10),dict(member=1,script=9,start_after=80)],
        transition=dict(trigger_member=1,signal=2,dispatches=[dict(member=0,script=11)]),
        embedded_returns=False,assist=dict(member=0,variant=0),damage_member=0,damage_signal=16,
        callback_order=['increment_counter_start_member1_at80','member1_hit2_dispatch_member0_script11','member0_hit2_recipient_reaction','member0_flag16_combined_damage','member_ready_and_return'],
        admission='native_vm_scene_bound_visual_acceptance_pending',scope='Fixed startup counter, signal-driven Krin phase switch, shared return and combined count2 multiplier15')


def fatal_phase_schedule(record, members, image):
    start,end=0x800FBAF8,0x800FBCB4
    digest='d12c2431093d1849b98504c59da1cda85336b07f269274af75c26df9539e73d5'
    if record['index']!=13 or record['update']!=start or image.end(start)!=end or hashlib.sha256(image.data[start-image.base:end-image.base]).hexdigest()!=digest:
        raise ValueError('Fatal controller changed')
    startup=pair_startup(record,image)
    startup.update(vm_playback='signal_started_partner',scope='Only Kamandol starts before the first sweep; her flag16 dispatches Gen and is consumed before damage/return checks')
    if [m['id'] for m in members]!=[20,67] or any([s['script'] for s in m['scripts']]!=[9] for m in members):
        raise ValueError('Fatal member programs changed')
    clocks=[]
    returns=journey_battle.script_at(maindec.body(),0x8016D214-maindec.MBASE)
    for index,member in enumerate(members):
        raw,_=field.source('/'+member['source']['file'].split('/')[-1])
        animations,flags,_=animation_frames(raw)
        operations=journey_battle.script(raw,9)
        primary=journey_battle.script_events(animations,operations,flags)
        complete=journey_battle.script_events(animations,operations+returns,flags)
        clocks.append(dict(member=index,script=9,events=primary['events'],primary=primary['duration'],complete=complete['duration']))
    raw,origin=field.source('/'+members[0]['source']['file'].split('/')[-1])
    operations=journey_battle.script(raw,15)
    offset=struct.unpack_from('<I',raw,struct.unpack_from('<I',raw,32)[0]+15*4)[0]
    size=sum(2+2*len(args) for op,args in operations)
    assist_digest='ba933903992efc4ad6d27d63eeb022a43b7301b10c205263900f900a51a02600'
    if hashlib.sha256(raw[offset:offset+size]).hexdigest()!=assist_digest or any(op==5 for op,args in operations):
        raise ValueError('Fatal assist descriptor changed')
    timing=journey_battle.script_events([],operations)
    return dict(startup=startup,controller=dict(address=start,size=end-start,sha256=digest),clocks=json.loads(json.dumps(clocks)),
        entries=[dict(member=0,script=9,deferred_entry=True),dict(member=1,script=9)],
        transition=dict(trigger_member=1,signal=16,dispatches=[dict(member=0,script=9)]),
        embedded_returns=False,assist=dict(member=0,variant=1,source=origin,source_offset=offset,byte_length=size,sha256=assist_digest,
            operations=[dict(op=op,args=list(args)) for op,args in operations],
            local_timing=dict(status='actor_local_wait_clocks',duration=timing['duration'],operation_ticks=timing['operation_ticks'])),damage_member=1,damage_signal=2,
        callback_order=['member0_hit2_recipient_reaction','member1_flag16_start_member0','member1_hit2_combined_damage','member_ready_and_return'],
        admission='native_vm_scene_bound_visual_acceptance_pending',scope='Signal-started partner, independent reaction/damage, source body/trail art and shared returns; KO/audio, overlapping actions and visual acceptance remain unfinished')


def airborne_recipient(member, image, main_source, expected_digest):
    """Shared callback8 path used by Ninja and Pretty Girl recipient descriptors."""
    raw,origin=field.source('/'+member['source']['file'].split('/')[-1])
    offset=struct.unpack_from('<I',raw,struct.unpack_from('<I',raw,32)[0]+15*4)[0]
    operations=journey_battle.script(raw,15)
    size=sum(2+2*len(args) for op,args in operations)
    digest=hashlib.sha256(raw[offset:offset+size]).hexdigest()
    if digest!=expected_digest:
        raise ValueError('Airborne recipient descriptor changed')
    stream=dict(script=15,operations=[dict(op=op,args=list(args)) for op,args in operations])
    roots,auxiliary=auxiliary_scripts(raw,origin,[stream],main_source)
    helper=0x800F3544;end=image.end(helper)
    if end!=0x800F387C or hashlib.sha256(image.data[helper-image.base:end-image.base]).hexdigest()!='8283a2379640247221b6d82b497a3363eabd41c65295394e56658d51429ea1d0':
        raise ValueError('Airborne recipient callback8 changed')
    table=0x800C125C
    if hashlib.sha256(image.data[table-image.base:table-image.base+400]).hexdigest()!='50b3622523c87a0a0ecc161da0ca42d3c8eb2d11aa1858b88052cd9e8ad43f3a':
        raise ValueError('Ninja recipient callback8 dispatch table changed')
    if image.word(0x8016BB90)!=helper:raise ValueError('Ninja assist callback changed')
    # The selected state path never reaches callback-owned movement cases5/7.
    clocks=journey_battle.script_events([],operations)
    callback_ticks=[at for at,(op,args) in zip(clocks['operation_ticks'],operations,strict=True) if op==35]
    mailbox={args[0]:at for at,(op,args) in zip(clocks['operation_ticks'],operations,strict=True) if op==30}
    pins={0x800E37DC:0x8C420054,0x800E37F4:0x0040F809,
          0x800E003C:0x0C0383A8,0x800E0044:0x0C03826F,
          0x800E0EB4:0x104000CA,0x800E0ECC:0x104000C4,
          0x800E12F4:0x84821324,0x800E1304:0x2462FFFF,
          0x800E1308:0xA4821324,0x800E1324:0x8C821294,
          0x800E1328:0x8C8312F4,0x800E1330:0x00431021,
          0x800E1354:0x8C6212C4,0x800E135C:0xAC621294,
          0x8016C23C:0x8016C200,0x8016C200:0x00020005,
          0x8016BABC:0x800E38F0,0x800E38F0:0x03E00008,0x800E38F4:0x00001021}
    for address,word in pins.items():
        if image.word(address)!=word:raise ValueError(f'Ninja recipient consumer changed at {address:#x}')
    install,stop=callback_ticks[0],mailbox[99]
    shake=mailbox[1]
    recipient_binding=dict(
        units='actor_local_updates_from_dispatch',
        scope='Selected script15 path only; callback8 movement cases5/7 are not reached',
        flip=dict(start=install,stop=stop,angles=[0,2048,2048],
                  screen_offset='recipient_current_attachment_y_minus_anchor_y',
                  offset_arithmetic='signed_byte_wrap',reset_offsets=[0,0]),
        callback_states=[dict(at=install,state=0),dict(at=shake,state=1),
                         dict(at=shake+1,state=2),dict(at=shake+2,state=3),
                         dict(at=shake+3,state=4),dict(at=stop,state=99)],
        camera_pulses=[dict(at=shake,channel='focus',delta_q12=[0,0,20480],updates=1),
                       dict(at=shake+2,channel='focus',delta_q12=[0,0,-20480],updates=1)],
        camera_order='request_after_integrator; apply_next_update; restore_existing_target_one_update_later',
        camera_preserves='focus_target_and_xy_velocity',
        terminal='retain_current_pose_and_absolute_position_until_replaced',
        impact=dict(at=clocks['events'][2],animation=0,child=13,offset=[5,5,0],centered=False),
        motions=[dict(at=at,updates=args[1],binding='absolute',destination_q12=[v*4096 for v in args[2:5]],
                      velocity_q12=[v*2048 for v in args[5:8]])
                 for at,(op,args) in zip(clocks['operation_ticks'],operations,strict=True) if op==23])
    return dict(member=0,script=15,animation_context='recipient',playback='native_selected_recipient_and_member_scene_bound',source=origin,source_offset=offset,byte_length=size,sha256=digest,
                    operations=stream['operations'],auxiliary_spawns=roots,auxiliary_scripts=auxiliary,
                    callback=dict(slot=8,address=helper,size=end-helper,sha256=hashlib.sha256(image.data[helper-image.base:end-image.base]).hexdigest(),
                                  dispatch_table=table,dispatch_table_sha256='50b3622523c87a0a0ecc161da0ca42d3c8eb2d11aa1858b88052cd9e8ad43f3a',cases=[dict(state=i,handler=image.word(table+4*i)) for i in (0,1,2,3,5,7,99)]),
                    local_timing=dict(status='actor_local_wait_clocks',duration=clocks['duration'],operation_ticks=clocks['operation_ticks']),
                    recipient_binding=recipient_binding,
                    timing='Selected callback state path and local clocks qualified; native scene alignment remains unbound')


def pretty_girl_phase_schedule(record, members, image, main_source):
    spans=((0x800FDAFC,0x800FDC64,'0ef71e8e85ef8e15736f6600d73654840010cd4ac78a1fe838970d22f96f0dc1'),
           (0x800FDC64,0x800FDE20,'044c5f38d29798fec54a04d59cf225e3f71f9272e5889e012e6c0469fe698ce1'))
    blocks=[]
    for start,end,digest in spans:
        if image.end(start)!=end or hashlib.sha256(image.data[start-image.base:end-image.base]).hexdigest()!=digest:
            raise ValueError('Pretty Girl phase controller changed')
        blocks.append(dict(address=start,size=end-start,sha256=digest))
    if record['index']!=8 or record['handler']!=spans[0][0] or record['update']!=spans[1][0] or [m['id'] for m in members]!=[3,33,23]:
        raise ValueError('Pretty Girl member/controller binding changed')
    if [[s['script'] for s in m['scripts']] for m in members]!=[[9],[11,12],[10]]:
        raise ValueError('Pretty Girl script12 belongs to Tengaar, not Camille')
    assist=airborne_recipient(members[0],image,main_source,'92488c78d517f57c86bff7a8c9f59d99d0f8e32c22738b7838e7471a9023b8ed')
    return dict(source=main_source,blocks=blocks,startup=dict(selection=0,initializer=1,first_actor_sweep=1,first_callback=2),
        entries=[dict(member=0,script=9),dict(member=1,script=11),dict(member=2,script=10)],
        transition=dict(trigger_member=2,signal=16,dispatches=[dict(member=1,script=12)]),
        embedded_returns=True,assist=assist,damage_member=1,damage_signal=2,
        admission='native_vm_scene_bound_visual_acceptance_pending',
        scope='Kasumi16 redispatches Tengaar12; Camille hit2 starts recipient15; Tengaar child-owned hit2 gates combined count3 multiplier25 with Kasumi16 recipient; embedded returns remain independent')


def ninja_phase_schedule(record, members, image, main_source):
    blocks=[]
    for start,end,digest in (
        (0x800FD7A4,0x800FD90C,'5dc8eec9ed6973bc6309dab7db555072efaa6af071ffeb65021b818034c5d449'),
        (0x800FD90C,0x800FDAFC,'c651d5a81856dffede72e2863026a451d63c611e5ac7c8f4268dd1b8180fadd9')):
        if image.end(start)!=end or hashlib.sha256(image.data[start-image.base:end-image.base]).hexdigest()!=digest:
            raise ValueError('Ninja phase controller changed')
        blocks.append(dict(address=start,size=end-start,sha256=digest))
    if record['handler']!=blocks[0]['address'] or record['update']!=blocks[1]['address']:
        raise ValueError('Ninja phase binding changed')
    assist=airborne_recipient(members[0],image,main_source,'164c0f89217f02ed36b321e9b47bf8e344cf8473b7a0e53db8a9209c167dd923')
    return dict(source=main_source,blocks=blocks,startup=dict(selection=0,initializer=1,first_actor_sweep=1,first_callback=2),
        entries=[dict(member=0,script=13),dict(member=1,script=10),dict(member=2,script=10)],
        transition=dict(trigger_member=0,signal=16,dispatches=[dict(member=1,script=11),dict(member=2,script=11)]),
        embedded_returns=True,
        assist=assist,
        admission='native_vm_scene_bound_visual_acceptance_pending',
        scope='Living-target Ninja scene for all three command owners; KO tails, audio and visual acceptance remain unfinished')


def bandit_phase_schedule(record, members, image, main_source):
    spans=((0x800FCD1C,0x800FCE00,'c2ecf544149db35bce4e17ace56508528b9d5f300003cbe2e3aba15189c330b2'),
           (0x800FCE00,0x800FD09C,'ffc46c9a7a9b6b71a7fbb48cd887de396bdb07f4f48545419efba165fab7955d'))
    blocks=[]
    for start,end,digest in spans:
        if image.end(start)!=end or hashlib.sha256(image.data[start-image.base:end-image.base]).hexdigest()!=digest:
            raise ValueError('Bandit phase controller changed')
        blocks.append(dict(address=start,size=end-start,sha256=digest))
    if record['index']!=17 or record['handler']!=spans[0][0] or record['update']!=spans[1][0] or [m['id'] for m in members]!=[12,31]:
        raise ValueError('Bandit member/controller binding changed')
    if [[s['script'] for s in m['scripts']] for m in members]!=[[9,10],[10]]:
        raise ValueError('Bandit member scripts changed')
    return dict(source=main_source,blocks=blocks,startup=dict(selection=0,initializer=1,first_actor_sweep=1,first_callback=2),
        entries=[dict(member=0,script=9),dict(member=1,script=10,deferred_entry=True)],
        transition=dict(trigger_member=0,signal=16,dispatches=[dict(member=1,script=10)]),
        embedded_returns=True,damage_target_signal=2,
        admission='native_vm_scene_bound_visual_acceptance_pending',
        scope='Varkas16 starts Sydonia10; Varkas2 requests camera and recipient10, Sydonia2 starts recipient15; target2 gates count2 multiplier25, with no helper reaction or common return')


def flash_controller_research(record, members, image):
    """Retain source callback clocks without admitting an unfinished scene."""
    import spell_scene_columns
    start, end = 0x800FBEE0, 0x800FC198
    digest = '7b0baa0ed95cfb1a423a612521189826600888cbeb01eeefafb42707ccf3f27c'
    if record['index'] != 10 or record['update'] != start or image.end(start) != end or hashlib.sha256(image.data[start-image.base:end-image.base]).hexdigest() != digest:
        raise ValueError('Flash controller changed')
    if [member['id'] for member in members] != [7, 18, 91] or any([s['script'] for s in member['scripts']] != [9] for member in members):
        raise ValueError('Flash member binding changed')
    pair_startup(record, image)
    columns = spell_scene_columns.constructors(dict(initializer=record['handler'], preparation=[], state_global=0x8017A010), image)
    if columns['blocked'] or len(columns['columns']) != 3:
        raise ValueError('Flash effect column constructors changed')
    helpers = []
    for first, last, expected in ((0x8011CF4C,0x8011D054,'17c71d0b11cecd380f7f3ca51345c8b65452d66ab60effe0aa9a5e595b941150'),
                                   (0x8011D054,0x8011D154,'26f2308a13da8e71b6fd78786410fa6006987a15645e7ef8ac80b7b0f7380385')):
        if image.end(first) != last or hashlib.sha256(image.data[first-image.base:last-image.base]).hexdigest() != expected:
            raise ValueError('Flash screen wash helper changed')
        helpers.append(dict(address=first, size=last-first, sha256=expected))
    return dict(controller=dict(address=start, size=end-start, sha256=digest),
        trigger=dict(actor='command_owner', signal=16, held_until_completion=True),
        phase_updates=[64,64,64], damage=dict(phase=2, zero_based_update=32, count=3, numerator=20),
        return_at_completed_updates=192, columns=json.loads(json.dumps(columns['columns'])),
        column_origins=[[0,-30,-40],[0,10,-40],[0,30,-40]],
        column_draws=dict(phase=0, first_update=0, last_update=62, angle_step=96,
                          angle_argument='signed_state_0x68_shift_right_12_after_decrement',
                          segment_gaps=[(0x190000 - 0x3200 * (index + 1)) >> 12 for index in range(63)]),
        wash_helpers=helpers, source_effect_fields=dict(initial_0x68=0x190000, phase0_delta_0x68=-0x3200,
                                  initial_0x64=0xFF000, phase2_delta_0x64=-0x3FC0),
        admission='source_research_only',
        scope='Callback-relative clocks while command-owner signal16 remains set; geometry, audio and native scheduler integration remain unbound.')


def family_schedule(record, members, image):
    start, end = 0x800FE3A8, 0x800FE4FC
    digest = '7dc3bf30a9aa0082dfbfeb96125a480ebafa2513c3347fcfa816c4ab187ca819'
    if record['index'] != 30 or record['handler'] != start or record['update'] != end or image.end(start) != end or hashlib.sha256(image.data[start-image.base:end-image.base]).hexdigest() != digest:
        raise ValueError('Lepant Family initializer changed')
    if [member['id'] for member in members] != [30, 0, 62] or [[row['script'] for row in member['scripts']] for member in members] != [[11], [12], [9]]:
        raise ValueError('Lepant Family member binding changed')
    verified = pair_startup(record, image)
    startup = {key: verified[key] for key in ('selection', 'initializer', 'first_actor_sweep', 'first_callback')}
    return dict(startup=startup, initializer=dict(address=start, size=end-start, sha256=digest),
                damage_target_signal=16, callback_order=['member_hit2_dispatches_recipient15',
                'target_flag16_combined_damage', 'member_ready_and_return'],
                admission='native_vm_scene_bound_visual_acceptance_pending',
                scope='Three distinct source recipient descriptors; KO, audio, overlapping actions and visual acceptance remain unfinished')


def master_pupil_schedule(record, members, image):
    start, end = 0x800FE84C, 0x800FEAEC
    digest = '12ef65e818d06023d93a0a74c8b9df86c168b1b819ae37f0e4b8b6f2b25b4470'
    if record['index'] != 31 or record['update'] != start or image.end(start) != end or hashlib.sha256(image.data[start-image.base:end-image.base]).hexdigest() != digest:
        raise ValueError('Master pupil controller changed')
    if [member['id'] for member in members] != [8, 91] or any([script['script'] for script in member['scripts']] != [10, 11] for member in members):
        raise ValueError('Master pupil member binding changed')
    for member in members:
        setup, strike = member['scripts']
        signals = lambda script: [op['args'][1] for op in script['operations'] if op['op'] == 26 and op['args'][0] == 0]
        if signals(setup) != [16] or signals(strike) != [2, 16]:
            raise ValueError('Master pupil member signals changed')
    footprint = master_pupil_footprint(members, image)
    return dict(startup=pair_startup(record, image), controller=dict(address=start, size=end-start, sha256=digest),
                entries=[dict(member=i, setup=10, strike=11) for i in range(2)],
                target_queue=dict(eligibility='active and unlocked at initializer', order='ascending enemy slots',
                                  claim_signal=16, impact_signal=2, target_rechecked_at_impact=True),
                finish_delay=40, footprint=footprint, admission='source_research_only',
                scope='Independent member loops and target queue; live actor, recipient and cleanup integration remain separate.')


def master_pupil_footprint(members, image):
    """Qualify fresh, unrotated primary nodes through both member programs and return."""
    expected = {
        8: ['ed0df09fa9da7795cd42a6767fe247ff4c68c7d2c4dd282fd4dbb61d94736b6e', '330cffe5dee54ace772bd82fb86fad5d04033586938e727ac2ead4bf6114543c'],
        91: ['f2988f0e69d2cfbfc74848d774c16a23b9eacde857b489539cb538d66110acb7', '330cffe5dee54ace772bd82fb86fad5d04033586938e727ac2ead4bf6114543c'],
    }
    ops = set()
    for member in members:
        if [script['sha256'] for script in member['scripts']] != expected[member['id']]:
            raise ValueError('Master pupil footprint script changed')
        for script in member['scripts']:
            ops.update(item['op'] for item in script['operations'])
            for item in script['operations']:
                if item['op'] == 35 and item['args'] != [0, 4]:
                    raise ValueError('Master pupil footprint callback changed')
    kai, _ = field.source('/KAI.BIN')
    table = struct.unpack_from('<I', kai, 32)[0]
    kai_flash = journey_battle.script(kai, 9)
    flash_offset = struct.unpack_from('<I', kai, table + 9*4)[0]
    flash_length = sum(2 + 2*len(args) for _, args in kai_flash)
    if hashlib.sha256(kai[flash_offset:flash_offset+flash_length]).hexdigest() != '0016b067cf96d8438a84b11368c38707c155424777ed27a59ec8a6a0c5a1bc61' or any(op == 35 and args != (0, 4) for op, args in kai_flash):
        raise ValueError('Kai Flash footprint script changed')
    ops.update(op for op, _ in kai_flash)
    offset = 0x8016D214 - image.base
    returning = journey_battle.script_at(image.data, offset)
    length = sum(2 + 2 * len(args) for _, args in returning)
    if hashlib.sha256(image.data[offset:offset+length]).hexdigest() != '69997ffd5e997c8d2caad93a646c8832fe314ded915b8db8811dd84d324468e1':
        raise ValueError('Master pupil footprint return changed')
    ops.update(op for op, _ in returning)
    if ops != {0,3,4,5,6,8,9,13,14,15,16,21,23,26,30,33,34,35,38,39,43}:
        raise ValueError('Master pupil footprint opcode set changed')
    starts = sorted({image.word(0x8016BABC + 4*op) for op in ops} | {
        0x800E0824, 0x800E09BC, 0x800E1E3C, 0x800E2044, 0x800E211C,
        0x800E256C, 0x800E2A9C, 0x800E358C, 0x800E3820, 0x800F14B4,
        0x800FE680, 0x800FE84C, 0x800FBCB4, 0x800FBEE0,
    })
    digest = hashlib.sha256()
    for op in sorted(ops):
        digest.update(struct.pack('<II', op, image.word(0x8016BABC + 4*op)))
    for start in starts:
        end = image.end(start)
        digest.update(struct.pack('<II', start, end))
        digest.update(image.data[start-image.base:end-image.base])
    if digest.hexdigest() != '52855f4c185676a0e83e212bca4ed176854e766a6742ea6768e30595986c2287':
        raise ValueError('Master pupil footprint writer or consumer changed')
    return dict(mode='axis_aligned_packet', initial_angles=[0,0,0], guarded_state='fresh or zero-angle primary nodes',
                nodes='actor body and separately constructed trail nodes', source_handlers=sorted(ops),
                source_block_count=len(starts), source_blocks_sha256=digest.hexdigest(),
                scope='Master pupil scripts, Kai Flash script, common return, trail callback and ordinary draw path; concurrent external node-angle writers remain unqualified.')


def direct_assists(record, members, image):
    callbacks={3:(0x800FA18C,0x800FA20C,'83647db2864e3b07c2c99101de9b4d536359126637f6a0f08011560a77c154f7'),
               4:(0x800FA334,0x800FA3B8,'c12fcbec11f0ae7b81693d0f1be593d86a5eecf947219f91115c3cfacf7632e5'),
               7:(0x800FC2C0,0x800FC410,'7e0b94722ef000efc1f6310104e17f090db3141db93c320e52295561b11bfcea'),
               17:(0x800FCE00,0x800FD09C,'ffc46c9a7a9b6b71a7fbb48cd887de396bdb07f4f48545419efba165fab7955d'),
               26:(0x800FD1D0,0x800FD2FC,'1d10d7b797b09bd8d008ea5605f7d897b363caac247eb2d53b687828afb9d31b'),
               30:(0x800FE4FC,0x800FE680,'ec423005594696983819fe3d8118e0dab963cb4fd94962d0db671cbb4e35dafa')}
    start,end,sha=callbacks[record['index']]
    if record['update']!=start or image.end(start)!=end or hashlib.sha256(image.data[start-image.base:end-image.base]).hexdigest()!=sha:
        raise ValueError('Direct Unite callback changed')
    selected={3:(),4:(),7:((0,15),(1,15)),17:((0,10),(1,15)),26:((0,15),),30:((0,15),(1,15),(2,15))}[record['index']]
    expected={7:'4c50d0df41c7300b12c0d13a1af6e1da58ff1ec64e452b64939a9b16b4fbcaf0',
              26:'2cfa10aa1ae2a1cf89aa7b964e4254fbae287c3f9e9619f7599f2be01bbf24cb'}
    assists=[];variants=[]
    for index,script in selected:
        raw,origin=field.source('/'+members[index]['source']['file'].split('/')[-1])
        operations=journey_battle.script(raw,script)
        offset=struct.unpack_from('<I',raw,struct.unpack_from('<I',raw,32)[0]+script*4)[0]
        size=sum(2+2*len(args) for op,args in operations)
        digest=(['8048ee0ae41b0fa174fad214e05b83a27365001b64232cbe2889b8134f1f3a3b','51d416a6c26705a7e4461b240fd386cbfad702e50a3d918d52ab8389afedcf81'][index]
                if record['index']==17 else ['68b249f9a58f307b200570ed73b68aacd5bafac9b1a3aae514de89d2a257e143','e1b42d923e7452789e32b6de7773ef2e1ee66d2fa8742ab890a48a1ee8261a13','c11653ab2580ab336d5bec2b4c31740eeb60d4d5d4f66d96497280d5de12751a'][index]
                if record['index']==30 else expected[record['index']])
        if hashlib.sha256(raw[offset:offset+size]).hexdigest()!=digest or any(op==5 for op,args in operations):
            raise ValueError('Unbound direct Unite assist descriptor')
        clocks=journey_battle.script_events([],operations,initial_movement_wait=True)
        reaction=dict(source=origin,source_offset=offset,byte_length=size,sha256=digest,
                      operations=[dict(op=op,args=list(args)) for op,args in operations],
                      local_timing=dict(status='actor_local_wait_clocks',duration=clocks['duration'],operation_ticks=clocks['operation_ticks']))
        if record['index']==30:
            _,main_source=field.source('MAIN.EXE')
            reaction['auxiliary_spawns'],reaction['auxiliary_scripts']=auxiliary_scripts(raw,origin,[dict(script=script,operations=reaction['operations'])],main_source)
        variant=next((v['variant'] for v in variants if v['reaction']['sha256']==digest),len(variants)+1)
        assists.append(dict(member=index,variant=variant,reaction=reaction))
        if not any(v['variant']==variant for v in variants):variants.append(dict(variant=variant,reaction=reaction))
        if record['index']==17 and index==0:
            from export_spell_scenes import interpreted_block
            assists[-1]['hit_camera']=dict(target=interpreted_block(0x8016D2A0),updates=30)
    return dict(assists=assists,variants=variants,after_damage=record['index']==26,callback_sha256=sha)


def blacksmith_startup(record, image):
    """Primary-coordinator invocation phases, distinct from actor-local clocks."""
    pins = {0x800DE0D0:0x2421DA94, 0x800DE0D8:0x8C220000, 0x800DE0E0:0x0040F809,
            0x800DE0E4:0x26040001, 0x800DE1C8:0x0C03800D,
            0x800F436C:0x0C03D5E4, 0x800F4378:0x2402FFFF, 0x800F437C:0x10620007,
            0x800F4384:0x1060000F, 0x800F4388:0x00121880,
            0x800F438C:0x3C02800F, 0x800F4390:0x24424550,
            0x800F4394:0x0803D0EC, 0x800F43B4:0x2421DA90,
            0x800F43BC:0xAC220000, 0x800F43C0:0x2402FFFF,
            0x800F5914:0x90420019, 0x800F591C:0x00021080,
            0x800F5924:0x2421D2D0, 0x800F592C:0x8C230000,
            0x800F5938:0x34020001, 0x800F593C:0xAC830018,
            0x800F4568:0x8C440008, 0x800F456C:0x8C420018,
            0x800F4574:0x0040F809, 0x800F457C:0x2403FFFF, 0x800F4580:0x1043000C,
            0x800FA3FC:0xAE000000, 0x800FA448:0x2402FFFF,
            0x800FA44C:0x3C038010, 0x800FA450:0x2463A478,
            0x800FA454:0xAC830018, 0x800FA470:0x03E00008}
    pins.update({0x800E0A74:0x0C038AA7, 0x800E0A7C:0x0C038D63,
                 0x800E2AC0:0x2442FFFF, 0x800E2AC4:0xA0820003,
                 0x800E3C10:0x30420002, 0x800E3C14:0x14400005,
                 0x800E478C:0x0004C2C0, 0x800E4798:0x0005CAC0,
                 0x800E47A4:0x00037AC0, 0x800E3748:0xAF050068,
                 0x800E3750:0xAF06006C, 0x800E3758:0xAF070070})
    for address, expected in pins.items():
        if image.word(address) != expected:
            raise ValueError(f'Blacksmith startup changed at {address:#x}')
    if record['handler'] != 0x800FA3B8 or record['update'] != 0x800FA478 or image.word(0x8016D2D0 + 4*record['unite_id']) != record['handler']:
        raise ValueError('Unbound Blacksmith startup initializer')
    return dict(units='primary_coordinator_updates', selection=0, initializer=1,
                first_callback=2, initializer_to_callback=1,
                entry=record['handler'], callback=record['update'],
                actor_sweep='after_primary_dispatch', native_mapping='selection_clock_verified',
                scope='All five native Blacksmith variants dispatch on update2 plus member offsets0/45/90/135; broader engine hooks, KO behavior and media acceptance remain separate.')


def blacksmith_trail(image):
    """Qualify the selected auxiliary helper; renderer lowering remains separate."""
    pins = {0x8016BB80:0x800F14B4, 0x800E5620:0x8C440000,
            0x800E5630:0xAC640054, 0x800E37DC:0x8C420054,
            0x800E37E4:0x10400005, 0x800E37F4:0x0040F809,
            0x800E37F8:0x02602821, 0x800F1538:0x106200F0,
            0x800F1540:0x106200F3, 0x800F1554:0x34040028,
            0x800F1584:0xAE020000, 0x800F1668:0x2A220008,
            0x800F1674:0xAE400020, 0x800F1678:0xAE400024,
            0x800F16A8:0x8E420024, 0x800F16CC:0x84C6000C,
            0x800F1734:0x341006F9, 0x800F1738:0x34020007,
            0x800F1764:0x00003012, 0x800F1798:0xA0460004,
            0x800F17B8:0xA0460005, 0x800F17C4:0x2610FF01,
            0x800F17E0:0x340200FF, 0x800F17E8:0xA0620006,
            0x800F18E4:0xAE420024, 0x800F18E8:0x28420008,
            0x800F18F8:0xAE400024, 0x800F190C:0xA6020042,
            0x800F191C:0x0C038ACF, 0x800F1924:0x2A220008,
            0x800F194C:0x0C030B70, 0x800F1958:0xAE000054}
    pins.update({0x800F1578:0x90450000, 0x800F157C:0x0C03878F,
                 0x800E1F50:0x0C038811, 0x800E206C:0xA0800002,
                 0x800E2104:0x0C038847, 0x800E2178:0x90440000,
                 0x800E21A4:0xAE820024, 0x800E25A0:0x8E530024,
                 0x800F16C0:0x8CC20008, 0x800F16D0:0x3042FFF8,
                 0x800F16DC:0xACA30008, 0x800E0A7C:0x0C038D63,
                 0x800E0B54:0x0C038209, 0x800E0954:0xAE050008})
    pins.update({0x800F1514:0x10620064, 0x800F1524:0x1060000A,
                 0x800F15A8:0xAC430008, 0x800F166C:0x1440FFC0,
                 0x800F16A0:0x0803C657, 0x800F18FC:0x96020042})
    pins.update({0x800E2254:0x00002821, 0x800E2294:0x0C052AC3,
                 0x800E2994:0x30420004, 0x800E299C:0x34050001,
                 0x800E29DC:0x0C052B7A})
    pins.update({0x8016BB48:0x800E557C, 0x800E5634:0x24420006,
                 0x800E5638:0xAC62000C, 0x800E5640:0x2402FFFF,
                 0x800E3898:0x10400006, 0x800E38AC:0x08038E21})
    for address, expected in pins.items():
        if image.word(address) != expected:
            raise ValueError(f'Blacksmith trail helper changed at {address:#x}')
    return dict(callback=4, source=0x800F14B4, nodes=8,
                capture='actor_screen_position_and_flags', ring_updates=8, invocation=0x800E37F4,
                pose='allocation_animation_first_pair',
                position_phase='before_current_actor_projection',
                initial_slots='allocation_actor_screen_position',
                first_draw_after_enable=1, last_draw_before_stop=1,
                cleanup_after_stop=1,
                blend='average',
                callback_phase='actor_vm_tail',
                full_ring_rgb_newest_first=[[255*(7-age)//7]*2+[255] for age in range(8)],
                stop_value=99, teardown_value=100, playback='source_inventory_only',
                scope='Allocation, actor-VM tail invocation, ring, tint and teardown bindings; outer-frame alignment, packet sampling and transform lowering remain unqualified.')


def blacksmith_schedule(record, members, reaction, image):
    """Export the counter-driven family; counter zero is its first callback."""
    if record['update'] != 0x800FA478:
        return None
    # These consumers qualify the division, member index, assist loop and return path.
    pins = {0x800FA3FC:0xAE000000, 0x800FA438:0x3C028017,
            0x800FA43C:0x2442D214, 0x800FA440:0x3C018018, 0x800FA444:0xAC22A020,
            0x800FA49C:0x8E460000,
            0x800FA4A4:0x00C2001A, 0x800FA4CC:0x00003812, 0x800FA4D0:0x00002810,
            0x800FA4F8:0x14A00012, 0x800FA504:0x1040000F, 0x800FA508:0x00071080,
            0x800FA510:0x8C440004, 0x800FA53C:0x0C038E08, 0x800FA540:0x02802821,
            0x800FA550:0x24420001, 0x800FA554:0xAE420000,
            0x800FA578:0x94620040, 0x800FA580:0x30420002, 0x800FA584:0x10400012,
            0x800FA598:0x0C038E08, 0x800FA59C:0x02802021,
            0x800FA5C8:0x3063FFFD, 0x800FA5CC:0xA4430040, 0x800FA5D4:0x1440FFE0,
            0x800FA5D8:0x26100004, 0x800FA5DC:0x8E440010,
            0x800FA5EC:0x0C03E522, 0x800FA600:0x0C03E4E4,
            0x800FA60C:0x0C03E5C6}
    pins.update({0x800DEF00:0x80460004, 0x800DEF1C:0x8C43000C,
                 0x800DEF20:0x00061080, 0x800DEF28:0x8C510000,
                 0x800E5754:0x84A20074, 0x800E5758:0x84A30076,
                 0x800E5780:0x84430074, 0x800E5784:0x84420076,
                 0x800E57AC:0x00072300, 0x800E57BC:0xAC430038,
                 0x800E57D0:0xAC45003C, 0x800E3698:0x830C0078,
                 0x800E36A4:0x0082001A, 0x800E36E4:0x0062001A,
                 0x800E3784:0xA30C0078, 0x800E3790:0xA30B0079,
                 0x800E37B8:0xA3020078, 0x800E37C0:0xA3030079,
                 0x800DED2C:0xA6000074, 0x800DED30:0xA6000076,
                 0x800DF088:0x9622003C, 0x800DF090:0xA6020074,
                 0x800DF094:0x9622003E, 0x800DF09C:0xA6020076})
    for address, expected in pins.items():
        if image.word(address) != expected:
            raise ValueError(f'Blacksmith callback changed at {address:#x}')
    def immediate(address, encoding):
        value = image.word(address)
        if value & 0xffff0000 != encoding:
            raise ValueError(f'Blacksmith schedule operand changed at {address:#x}')
        return value & 65535
    spacing = immediate(0x800FA4A0, 0x34020000)
    stop = immediate(0x800FA500, 0x28C20000)
    script_bytes = immediate(0x800FA538, 0x8C460000)
    reaction_bytes = immediate(0x800FA594, 0x8C460000)
    assist_count = immediate(0x800FA5D0, 0x2A220000)
    if not spacing or script_bytes % 4 or reaction_bytes % 4:
        raise ValueError('Invalid Blacksmith counter/script operands')
    counters = list(range(0, stop, spacing))
    if len(counters) != len(members) or assist_count != len(members)-1:
        raise ValueError('Blacksmith schedule does not cover its canonical members')
    dispatches = [dict(member=index, script=script_bytes//4, callback_counter=counter)
                  for index, counter in enumerate(counters)]
    assists = []
    tracks = []
    return_address = record['recovery_source']['return_script']
    if return_address != 0x8016D214:
        raise ValueError('Blacksmith return descriptor disagrees with initializer')
    return_operations = journey_battle.script_at(maindec.body(), return_address-maindec.MBASE)
    for index, member in enumerate(members):
        raw, _ = field.source('/'+member['source']['file'].split('/')[-1])
        animations, flags, _ = animation_frames(raw)
        operations = journey_battle.script(raw, script_bytes//4)
        primary = journey_battle.script_events(animations, operations, flags)
        complete = journey_battle.script_events(animations, operations+return_operations, flags)
        trail_events = [(tick, op, args) for tick, (op,args) in
                        zip(primary['operation_ticks'], operations, strict=True)
                        if op == 35 or op == 30]
        if [(op,args) for _,op,args in trail_events] != [(30,(0,)),(35,(0,4)),(30,(99,))]:
            raise ValueError('Blacksmith trail lifetime requires a distinct binding')
        selected = None
        for op,args in operations:
            if op == 4: selected = args[0]
            if op == 35: break
        if selected is None or not animations[selected]:
            raise ValueError('Blacksmith trail lacks an allocation pose')
        if set(primary['events']) != {2,4} or primary['events'][4] != primary['duration']:
            raise ValueError('Blacksmith member lacks its hit/ready boundary')
        tracks.append(dict(member=index, start_after=counters[index],
                           local_hit_flag=primary['events'][2], local_ready_flag=primary['events'][4],
                           local_track_end=complete['duration'],
                           trail_start=trail_events[1][0], trail_stop=trail_events[2][0],
                           trail_animation=selected, trail_pose=animations[selected][0][0]))
    for index, member in enumerate(members[:assist_count]):
        raw, origin = field.source('/'+member['source']['file'].split('/')[-1])
        operations = journey_battle.script(raw, reaction_bytes//4)
        table = struct.unpack_from('<I', raw, 32)[0]
        offset = struct.unpack_from('<I', raw, table+reaction_bytes)[0]
        length = sum(2+2*len(args) for op,args in operations)
        digest = hashlib.sha256(raw[offset:offset+length]).hexdigest()
        if digest != reaction['sha256'] or [dict(op=op,args=list(args)) for op,args in operations] != reaction['operations']:
            raise ValueError('Blacksmith assist needs a distinct recipient program')
        assists.append(dict(member=index, script=reaction_bytes//4, trigger='hit_flag',
                            clear_hit_flag=True, commits_damage=False, reaction_record=record['index'],
                            source=origin, source_offset=offset, byte_length=length, sha256=digest))
    return dict(kind='staggered_members', counter_origin='first_callback', dispatches=dispatches,
                startup=blacksmith_startup(record,image),
                assists=assists, member_clocks=tracks, return_source=return_address,
                trail=blacksmith_trail(image),
                combined_damage_member=len(members)-1,
                return_dispatch='each_member_ready_flag',
                scope='Native script-driven dispatch, assist reactions, combined damage and independent return/handoff clocks are verified for all five variants; KO behavior, audio and visual acceptance remain unfinished.')


def animation_frames(data, section=None, base=0, animation_table_end=None):
    section = struct.unpack_from('<I', data, 36)[0] if section is None else section
    if not 0 <= section <= len(data)-24:
        raise ValueError('Unite animation section outside source')
    count = struct.unpack_from('<H', data, section + 2)[0]
    table = struct.unpack_from('<I', data, section + 20)[0]-base
    if animation_table_end is not None:
        if type(animation_table_end) is not int or not table+4*count<=animation_table_end<=len(data) or (animation_table_end-table)%4 or (animation_table_end-table)//4>256:
            raise ValueError('Invalid proven animation table extent')
        count=(animation_table_end-table)//4
    if not 0 <= table <= len(data)-4*count:
        raise ValueError('Unite animation table outside source')
    animations, flags, zero_count = [], [], []
    for index in range(count):
        offset = struct.unpack_from('<I', data, table + 4*index)[0]-base
        if not 0 <= offset < len(data):
            raise ValueError('Unite animation outside member resource')
        # The setter reads pair zero before the updater compares against the count.
        length = max(1, data[offset])
        if offset + 4 + 2*length > len(data):
            raise ValueError('Invalid Unite animation frames')
        animations.append([tuple(data[offset+4+2*k:offset+6+2*k]) for k in range(length)])
        flags.append(data[offset+1])
        if data[offset] == 0:
            zero_count.append(dict(animation=index,source_offset=offset,first_pair=list(animations[-1][0])))
    return animations, flags, zero_count


def auxiliary_scripts(data, source, primary, main_source, table=None, base=0):
    """Follow spawn descriptors without inventing their owner-dependent schedules."""
    definitions = {}
    pending = []
    member_table = struct.unpack_from('<I', data, 32)[0] if table is None else table
    member_base = base

    def spawns(operations, resource):
        links = []
        for index, operation in enumerate(operations):
            if operation['op'] != 24:
                continue
            flags, _, script, *_ = operation['args']
            if script < 0:
                raise ValueError('Negative Unite auxiliary script index')
            selected = resource if flags & 1 else 'shared'
            identifier = f'{selected}:{script}'
            links.append(dict(operation=index, child=identifier))
            pending.append((identifier, selected, script))
        return links

    roots = []
    for script in primary:
        roots.extend(dict(script=script['script'], **link) for link in spawns(script['operations'], 'member'))
    while pending:
        identifier, resource, index = pending.pop(0)
        if identifier in definitions:
            continue
        if resource == 'member':
            raw, origin, source_base, header = data, source, member_base, 0
            source_table = member_table
        else:
            raw, origin, source_base, header = maindec.body(), main_source, maindec.MBASE, maindec.EXE_HEADER
            source_table = 0x8016C208
        operations = journey_battle.script(raw, index, source_table, source_base)
        offset = struct.unpack_from('<I', raw, source_table-source_base+4*index)[0]-source_base
        length = sum(2+2*len(args) for op,args in operations)
        if not 0 <= offset < offset+length <= len(raw):
            raise ValueError('Unite auxiliary stream outside source')
        rows = [dict(op=op,args=list(args)) for op,args in operations]
        definitions[identifier] = dict(id=identifier,resource=resource,script=index,source=origin,
            source_offset=offset+header,byte_length=length,
            sha256=hashlib.sha256(raw[offset:offset+length]).hexdigest(),
            operations=rows,spawns=spawns(rows,resource),
            playback='owner_signals_and_auxiliary_lifecycle_not_bound')
    return roots, list(definitions.values())


def report():
    catalogue = json.loads(CATALOGUE.read_text())
    by_id = {record['id']: record for record in character_table.records()}
    out = []
    resource_cache = {}
    image = Image()
    _, main_source = field.source('MAIN.EXE')
    for record in catalogue['records']:
        members = []
        scripts = []
        if maindec.mword(0x8016D2D0 + 4*record['unite_id']) != record['handler']:
            raise ValueError('Unite initializer no longer agrees with action table')
        selected={member['member']:member for member in record['recovery_source']['members']}
        if set(selected)!=set(record['members']):raise ValueError('Unite selected-script membership mismatch')
        for member_id in record['members']:
            character = by_id.get(member_id)
            if character is None:raise ValueError('Unite member has no character resource')
            if member_id not in resource_cache:
                data, source = field.source('/' + character['sprite_file'])
                animations, flags, zero_count = animation_frames(data)
                resource_cache[member_id] = data, source, animations, flags, zero_count
            data, source, animations, flags, zero_count = resource_cache[member_id]
            table = struct.unpack_from('<I', data, 32)[0]
            resources=[];camera=[]
            for script in selected[member_id]['scripts']:
                ops = journey_battle.script(data, script)
                offset = struct.unpack_from('<I', data, table + 4*script)[0]
                length=sum(2+2*len(args) for op,args in ops)
                try:
                    clocks=journey_battle.script_events(animations,ops,flags)
                    timing=dict(status='actor_local_wait_clocks',duration=clocks['duration'],
                                operation_ticks=clocks['operation_ticks'])
                except journey_battle.UnresolvedActorClock as error:
                    timing=dict(status='unresolved_animation_wait',reason=str(error))
                resources.append(dict(script=script,source_offset=offset,byte_length=length,
                    sha256=hashlib.sha256(data[offset:offset+length]).hexdigest(),
                    local_timing=timing,camera_requests=journey_battle.camera_requests(animations,ops,flags),
                    operations=[dict(op=op,args=list(args)) for op,args in ops]))
                camera.extend(dict(script=script,op=op,args=list(args)) for op,args in ops if op in OPS)
            roots, auxiliaries = auxiliary_scripts(data,source,resources,main_source)
            section = struct.unpack_from('<I',data,36)[0]
            pose_count = struct.unpack_from('<H',data,section)[0]
            requested = sorted({op['args'][0] for stream in resources for op in stream['operations'] if op['op']==4})
            animation_art = dict(pose_count=pose_count,animations=[dict(id=index,flags=flags[index],
                frames=[dict(pose=pose,updates=updates or 256) for pose,updates in animations[index]],
                unresolved_poses=sorted({pose for pose,_ in animations[index] if pose>=pose_count})) for index in requested],
                scope='Primary resource animation references only; pixel residency and auxiliary/return art are not qualified.')
            scripts.append(dict(id=member_id,source=source,scripts=resources,zero_count_animations=zero_count,
                                animation_art=animation_art,auxiliary_spawns=roots,auxiliary_scripts=auxiliaries,
                                binding='source_selected_scripts',
                                playback='existing_track_binding' if record['unite_id'] in (1,2) else 'coordinator_schedule_not_exported'))
            if camera:
                members.append(dict(id=member_id, name=character['name'], ops=camera))
        binding = reaction_binding(record,image)
        reaction = dict(binding=binding,scope='Shared combined-damage helper only; callback-owned reactions may also run.')
        if binding['kind']=='member_resource':
            data,source,_,_,_ = resource_cache[binding['member']]
            ops = journey_battle.script(data,binding['script'])
            table = struct.unpack_from('<I',data,32)[0]
            offset = struct.unpack_from('<I',data,table+4*binding['script'])[0]
            length = sum(2+2*len(args) for op,args in ops)
            if any(op==5 for op,args in ops):
                timing = dict(status='recipient_animation_durations_required')
            else:
                clocks = journey_battle.script_events([],ops,initial_movement_wait=True)
                timing = dict(status='actor_local_wait_clocks',duration=clocks['duration'],operation_ticks=clocks['operation_ticks'])
            stream = dict(script=binding['script'],operations=[dict(op=op,args=list(args)) for op,args in ops])
            if any(op==24 and args[0]&1 for op,args in ops):
                raise ValueError('Recipient-resource auxiliary needs a target resource binding')
            roots,auxiliaries = auxiliary_scripts(data,source,[stream],main_source)
            reaction.update(source=source,source_offset=offset,byte_length=length,
                sha256=hashlib.sha256(data[offset:offset+length]).hexdigest(),operations=stream['operations'],
                animation_context='recipient',local_timing=timing,auxiliary_spawns=roots,auxiliary_scripts=auxiliaries,
                playback='source_inventory_only')
        out.append(dict(index=record['index'], name=record['name'],
                        unite_id=record['unite_id'], members=members,
                        initializer=record['handler'], update=record['update'],
                        outcome=record['outcome'], family=record['family'],
                        callback_chain=record['callback_chain'], all_enemies=record['all_enemies'],
                        recovery=record['recovery'],
                        multiplier=record.get('multiplier', 0), member_scripts=scripts,
                        resource_dispatches=resource_script_loads(record),
                        target_reaction=reaction,
                        hit_gate=hit_gate_binding(record,image),
                        callback_schedule=blacksmith_schedule(record,scripts,reaction,image),
                        scope='Selected resource streams and actor-local wait clocks assuming auxiliary allocation succeeds; coordinator dispatch, frame-driver timing and other camera writers are not established by concatenating streams.'))
        if record['handler'] in (0x800F9758,0x800F9920,0x800FA064,0x800FA20C,0x800FC198,0x800FD09C,0x800FBCB4,0x800FB428,0x800FD2FC,0x800FDE20,0x800FE680,0x800FE3A8): out[-1]['primary_startup'] = pair_startup(record,image)
        if record['index'] in (9,25):out[-1]['scene_controller']=beauty_scene_controller(record,scripts,image)
        if record['index']==13:out[-1]['phase_schedule']=fatal_phase_schedule(record,scripts,image)
        if record['index']==6:out[-1]['phase_schedule']=bumpy_phase_schedule(record,scripts,image)
        if record['index']==28:out[-1]['phase_schedule']=ninja_phase_schedule(record,scripts,image,main_source)
        if record['index']==8:out[-1]['phase_schedule']=pretty_girl_phase_schedule(record,scripts,image,main_source)
        if record['index']==17:out[-1]['phase_schedule']=bandit_phase_schedule(record,scripts,image,main_source)
        if record['index']==10:out[-1]['controller_research']=flash_controller_research(record,scripts,image)
        if record['index'] in (15,16):
            import unite_linked_controllers
            out[-1]['controller_research']=unite_linked_controllers.research(record,scripts,image)
        if record['index'] in (2,19,20):out[-1]['group_schedule']=wild_arrow_schedule(record,scripts,image)
        if record['index']==30:out[-1]['family_schedule']=family_schedule(record,scripts,image)
        if record['index']==31:out[-1]['sweep_research']=master_pupil_schedule(record,scripts,image)
        if record['index'] in (3,4,7,17,26,30):out[-1]['direct_assists']=direct_assists(record,scripts,image)
    return out


def wild_arrow_projection_vectors():
    """Independent Python projection of raw one-piece arrow descriptors."""
    from battle_drops import projected,transform
    import disc
    cases=[]
    rows=report()
    for record in (2,19,20):
        for member in rows[record]['member_scripts']:
            origin=member['source']
            raw=disc.extract(origin['lba'],origin['size'])
            section=struct.unpack_from('<I',raw,36)[0]
            table=struct.unpack_from('<I',raw,section+16)[0]
            frame=struct.unpack_from('<I',raw,table+40)[0]
            if raw[frame]!=1:raise ValueError('Wild Arrow requires a single draw piece')
            ax,ay=raw[frame+4:frame+6]
            x,y,_,_,wm,hm,_,_=raw[frame+8:frame+16]
            sprite=dict(rect=dict(x=0,y=0,w=wm+1,h=hm+1),anchor_x=ax-x,anchor_y=ay-y)
            for scale in (3328,4864):
                camera=dict(position=[0,0,0],angles=[-768,0,640],c=[0,0,1024],d=[scale]*3)
                anchor=dict(x=320,y=240,depth=1067)
                node=[0,0,0,0,0,400,0,0,1024,scale,scale,scale]
                corners=[(x-ax,y-ay,0),(x-ax+wm+1,y-ay,0),(x-ax,y-ay+hm+1,0),(x-ax+wm+1,y-ay+hm+1,0)]
                vertices=[[anchor['x']+2*p[0],anchor['y']+2*p[1]] for p in [projected(c,node,centered=False) for c in corners]]
                cases.append(dict(camera=camera,anchor=anchor,sprite=sprite,angles=[0,0,400],vertices=vertices,depth=1064))
    positions=[]
    for local in (-49152,-503809,-5406720):
        for roll in (340,170,0,-170,-340):
            anchor=[131,-57,-40]
            positions.append(dict(local_x_q12=local,anchor=anchor,roll=roll,world=transform((local>>12,0,0),(0,0,roll),(4096,4096,4096),anchor)))
    anchor=[-32768,32767,-40]
    positions.append(dict(local_x_q12=-49152,anchor=anchor,roll=340,world=transform((-12,0,0),(0,0,340),(4096,4096,4096),anchor)))
    return dict(schema='suikoden-wild-arrow-projection/1',cases=cases,positions=positions)


if __name__ == '__main__':
    import argparse
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--projection-vectors',action='store_true')
    args=parser.parse_args()
    print(json.dumps(wild_arrow_projection_vectors() if args.projection_vectors else report(), indent=2))

"""B-only candidate resource and independent source packet/pixel checks; no window."""
from pathlib import Path
import hashlib
import json
import struct
import sys
import tempfile
from PIL import Image
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
import export_world_battle as export
from export_first_room import ROOT,source
from test_battle_trial_export import source_pose


def check():
    with tempfile.TemporaryDirectory(prefix='suikoden-battle-b-art-') as temporary:
        output=Path(temporary);scene,proof=export.export(output)
        assert scene['encounter']=='world_b_encounter_4' and scene['region']=='region_b'
        assert [row['id'] for row in scene['actors']]==['hero','gremio','pahn','viktor','yam_koo','tai_ho','roc']
        assert not proof['native_launched'] and not proof['media_accepted'] and not proof['promoted']
        from test_world_b_party import compare
        compare(scene,json.loads((ROOT/'game/tests/fixtures/world_b_party_source.json').read_text()))
        reference=json.loads((ROOT/'game/tests/fixtures/world_roc_presentation.json').read_text())['samples']
        for identifier,begin,track in (('roc',1,'attack'),('hero',146,'attack'),('hero',49,'hurt'),('roc',218,'hurt')):
            actor=next(row for row in scene['actors'] if row['id']==identifier)
            for index,sample in enumerate(actor[track]):
                expected=reference[begin+index-1][identifier]
                assert all(sample[key]==expected[key] for key in sample),(identifier,track,index)

        covered=json.loads((ROOT/'game/tests/fixtures/world_roc_cover.json').read_text())[0]['samples']
        for index,identifier,begin,track in ((0,'hero',1,'cover'),(1,'guard',1,'cover'),(0,'hero',146,'covered_attack'),(6,'roc',1,'covered_attack')):
            for offset,sample in enumerate(scene['actors'][index][track]):
                expected=covered[begin+offset-1][identifier]
                assert all(sample[key]==expected[key] for key in sample),(identifier,track,offset)

        for continued in json.loads((ROOT/'game/tests/fixtures/world_roc_two_round.json').read_text()):
            track='covered_attack' if continued['initial_hp']==100 else 'attack'
            for index,sample in enumerate(scene['actors'][-1][track]):
                expected=continued['second']['samples'][31+index]['roc']
                assert all(sample[key]==expected[key] for key in sample),('continued',track,index)

        continued=json.loads((ROOT/'game/tests/fixtures/world_roc_medicine_round.json').read_text())['rounds'][0]['samples']
        for index,sample in enumerate(scene['actors'][-1]['settled_attack']):
            expected=continued[31+index]['visuals'][2]
            assert all(sample[key]==expected[key] for key in sample),('settled-attack',index)

        medicine=json.loads((ROOT/'game/tests/fixtures/world_medicine.json').read_text())['roc']['samples']
        for tick in range(169,198):
            expected=medicine[tick-1]
            for particle,offset in zip(expected['particles'],scene['medicine_particles'][tick-169]):
                assert all(abs(particle['position'][key]-expected['hero']['position'][key]-offset[key])<1e-6 for key in offset)
                assert particle['pose']==scene['actors'][0]['animations'][0][0]['pose']

        assert all('A_DATA.BIN' not in origin['file'] for origin in proof['sources'])
        assert sum(origin['file'].endswith('B_DATA.BIN') for origin in proof['sources'])==1
        with Image.open(output/'actors.png') as atlas:
            count=0
            for actor,origin in zip(scene['actors'],proof['actors']):
                record=proof['sources'][0] if actor['id']=='roc' else proof['sources'][scene['actors'].index(actor)+2]
                raw,actual=source('/'+record['file'].split('/')[-1]);assert actual==record
                base=0x80080000 if actor['id']=='roc' else 0
                # Check source F/E selection, UVs and anchors through the independent VRAM sampler.
                seen=set()
                for animation,clip in enumerate(actor['animations']):
                    for step,frame in enumerate(clip):
                        if frame['pose'] in seen:continue
                        expected,ax,ay=source_pose(raw,origin['section'],base,animation,step)
                        pose=actor['poses'][frame['pose']];rect=pose['rect']
                        actual=atlas.crop((rect['x'],rect['y'],rect['x']+rect['w'],rect['y']+rect['h']))
                        assert actual.size==expected.size and actual.tobytes()==expected.tobytes(),(actor['id'],animation,step)
                        assert (pose['anchor_x'],pose['anchor_y'])==(ax,ay)
                        seen.add(frame['pose']);count+=1
        # Read the B height table independently through its directory chain.
        raw,_=source('/B_DATA.BIN')
        pointer=lambda offset:struct.unpack_from('<I',raw,offset)[0]-0x80080000
        directory=pointer(pointer(pointer(0)+12));height=pointer(directory+16)
        grid=proof['heightfield'];assert (grid['across'],grid['down'],len(grid['vertices']))==(16,16,289)
        heights=[row[2] for row in grid['vertices']]
        assert heights==list(struct.unpack_from('<289h',raw,height))
        assert (min(heights),max(heights))==(-150,106)
        assert grid['vertices'][0][:2]==(-576,-576) and grid['vertices'][-1][:2]==(448,448)
        original={name:hashlib.sha256((output/name).read_bytes()).hexdigest() for name in ('scene.json','actors.png','floor.png','provenance.json')}
        export.export(output)
        assert original=={name:hashlib.sha256((output/name).read_bytes()).hexdigest() for name in original}
    try:export.export(ROOT/'kit/work/accepted/battle_b')
    except ValueError:pass
    else:raise AssertionError('accepted staging was writable')
    print(f'PASS:B formation4 candidate; {count} distinct source-selected actor poses/anchors match independent VRAM sampling; 289 nonflat height vertices; reproducible four-file output; accepted staging refused. Dynamic binding is checked separately; native/media acceptance remains pending.')


def compare_frames(assets,frames,ticks,reference):
    import math
    import numpy as np
    import battle_mock as geometry
    scene=json.loads((assets/'scene.json').read_text())
    atlas=Image.open(assets/'actors.png').convert('RGBA');floor=Image.open(assets/'floor.png').convert('RGBA')
    samples=[];yy,xx=np.mgrid[0:336,0:640].astype(np.float32)
    for tick in ticks:
        row=json.loads((frames/f'battle-{tick}-state.json').read_text());frame=row['battle_frame'];assert row['presentation_available'] and frame is not None
        image=Image.new('RGBA',(640,336),(0,0,0,255))
        image.paste(floor.crop((0,55,320,204)).resize((640,298),Image.Resampling.NEAREST),(0,38))
        array=np.array(image)
        for shadow in frame['shadows']:
            dx=(xx+np.float32(.5)-int(shadow['point']['x']))/np.float32(shadow['radius_x'])
            dy=(yy+np.float32(.5)-int(shadow['point']['y']))/np.float32(shadow['radius_y'])
            mask=(dx*dx+dy*dy<=1)&(yy>=38)
            array[mask,:3]=((array[mask,:3].astype(np.uint16)*115+127)//255).astype(np.uint8)
        image=Image.fromarray(array)
        assert all(a['depth']>=b['depth'] for a,b in zip(frame['quads'],frame['quads'][1:]))
        for quad in frame['quads']:
            r=quad['sprite']['rect'];source_pixels=np.asarray(atlas.crop((r['x'],r['y'],r['x']+r['w'],r['y']+r['h'])))
            # Rational pixel centres avoid Pillow's resize tie rounding at half texels.
            xs=((2*np.arange(quad['w'])+1)*r['w'])//(2*quad['w']);ys=((2*np.arange(quad['h'])+1)*r['h'])//(2*quad['h'])
            source_pixels=source_pixels.copy();source_pixels[:,:,:3]=np.minimum(source_pixels[:,:,:3].astype(np.uint32)*np.array(quad.get('light',[128,128,128]),dtype=np.uint32)//128,255).astype(np.uint8)
            sprite=Image.fromarray(source_pixels[ys[:,None],xs])
            visible=Image.new('RGBA',image.size);visible.paste(sprite,(quad['x'],quad['y']));visible.paste((0,0,0,0),(0,0,640,38));image.alpha_composite(visible)
            index=quad['actor']
            if index in (0,6) or (index==1 and 'guard' in reference[0]):
                identifier='hero' if index==0 else 'guard' if index==1 else 'roc';expected=reference[min(tick,len(reference))-1][identifier]
                assert quad['position']==expected['position'] and quad['pose_index']==expected['pose'] and expected['visible']
                world=tuple(math.floor(quad['position'][k]) for k in ('x','y','z'))
                sx,sy,depth=geometry.project_point(world,H=geometry.PROJ_H*.72)
                home=scene['formation_slots'][index] if index<6 else scene['enemy_positions'][0]
                home_depth=geometry.project_point(tuple(int(home[k]) for k in ('x','y','z')),H=geometry.PROJ_H*.72)[2]
                scale=scene['sprite_scale']*home_depth/depth
                ex=sx*2+(expected['offset'][0]-quad['sprite']['anchor_x'])*scale
                ey=(sy+17-36)*2+(expected['offset'][1]-quad['sprite']['anchor_y'])*scale
                assert abs(quad['x']-ex)<=4 and abs(quad['y']-ey)<=4,(tick,identifier,quad['x'],ex,quad['y'],ey)
        expected=reference[min(tick,len(reference))-1]
        if 'particles' in expected:
            actual=[q for q in frame['quads'] if q['medicine_particle']]
            key=lambda position:tuple(position[k] for k in ('x','y','z'))
            assert sorted(key(q['position']) for q in actual)==sorted(key(p['position']) for p in expected['particles'])
            assert next(q['light'] for q in frame['quads'] if q['actor']==0)==expected['hero_light']
            assert all(q['light']==[64,128,0] for q in actual)
        for index,identifier in ((0,'hero'),(6,'roc'))+(((1,'guard'),) if 'guard' in reference[0] else ()):
            assert any(q['actor']==index for q in frame['quads'])==reference[min(tick,len(reference))-1][identifier]['visible']
        actual=Image.open(frames/f'battle-{tick}-{row["battle_phase"]}.png').convert('RGBA')
        expected_hash=hashlib.sha256(image.tobytes()).hexdigest()
        assert actual.tobytes()==image.tobytes() and frame['sha256']==expected_hash,tick
        samples.append(dict(tick=tick,sha256=expected_hash,sprites=len(frame['quads'])))
    return samples


def check_runtime():
    from test_world_replay import run,roc_loop_checks,roc_defeat_checks,roc_two_round_checks,roc_medicine_checks,supplied_packet,EXE
    assets=ROOT/'kit/work/build/world-battle-art'
    frames=assets/'frames';frames.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='suikoden-battle-b-process-') as temporary:
        root=Path(temporary);isolated=root/'saves';isolated.mkdir()
        run('--check-persistence',isolated,'write')
        from test_world_replay import primary_save
        saved=primary_save(isolated);packet=supplied_packet(json.loads(saved.read_text()))
        assert roc_loop_checks(root,packet,assets,frames)==490
        loss_root=root/'defeat';loss_root.mkdir();loss_frames=frames/'knockout';loss_frames.mkdir(exist_ok=True)
        loss_steps=roc_defeat_checks(loss_root,packet,assets,loss_frames)
        cover_root=root/'cover';cover_root.mkdir();cover_frames=frames/'cover';cover_frames.mkdir(exist_ok=True)
        cover_steps=roc_loop_checks(cover_root,packet,assets,cover_frames,cover=True)
        cover_ko_root=root/'cover-ko';cover_ko_root.mkdir();cover_ko_frames=frames/'cover-knockout';cover_ko_frames.mkdir(exist_ok=True)
        cover_ko_steps=roc_loop_checks(cover_ko_root,packet,assets,cover_ko_frames,cover=True,cover_knockout=True)
        rounds_root=root/'rounds';rounds_root.mkdir();rounds_frames=frames/'two-rounds';rounds_frames.mkdir(exist_ok=True)
        rounds_steps=roc_two_round_checks(rounds_root,packet,assets,rounds_frames)
        medicine_root=root/'medicine';medicine_root.mkdir();medicine_frames=frames/'medicine';medicine_frames.mkdir(exist_ok=True)
        medicine_steps=roc_medicine_checks(medicine_root,packet,assets,medicine_frames)
    reference=json.loads((ROOT/'game/tests/fixtures/world_roc_presentation.json').read_text())['samples']
    samples=compare_frames(assets,frames,(1,49,50,62,145,146,218,254,274,347,348,380),reference)
    assert len({row['sha256'] for row in samples})>=7
    receipt=dict(schema='suikoden-world-battle-render-review/1',status='candidate',executable_sha256=hashlib.sha256(EXE.read_bytes()).hexdigest(),scene_sha256=hashlib.sha256((assets/'scene.json').read_bytes()).hexdigest(),source_fixture_sha256=hashlib.sha256((ROOT/'game/tests/fixtures/world_roc_presentation.json').read_bytes()).hexdigest(),samples=samples,normal_input_steps=490,restart_points=6,independent_buffer_pixels_agree=True,source_positions_and_poses_agree=True,projection_tolerance_pixels=4,native_launched=False,media_accepted=False,promoted=False,limits=['scene buffers exclude common menu/HUD text','source terrain is unlit; fixed source camera uses an explicit crop','perspective billboard scaling and flat party shadows remain port presentation','original death palette flashing and GPU raster-edge identity are not claimed','diagnostic ownership/supplied RNG; one formation; no canonical boot or interactive world saves'])
    loss_reference=next(row['samples'] for row in json.loads((ROOT/'game/tests/fixtures/world_roc_knockout.json').read_text()) if row['hp']==16 and row['alone'])
    loss_samples=compare_frames(assets,loss_frames,(1,48,49,61,62,145,146,147),loss_reference)
    receipt['party_knockout']=dict(samples=loss_samples,normal_input_steps=loss_steps,restart_points=6,first_victory_hp_persisted=16,terminal_defeat=True,no_defeat_rewards_or_retry=True)
    cover_fixture=ROOT/'game/tests/fixtures/world_roc_cover.json'
    cover_reference=next(row['samples'] for row in json.loads(cover_fixture.read_text()) if row['hero_hp']==16 and not row['protected'])
    cover_samples=compare_frames(assets,cover_frames,(1,5,10,11,12,22,49,61,62,63,72,73,145,146,218,274,348,380),cover_reference)
    receipt['party_cover']=dict(source_fixture_sha256=hashlib.sha256(cover_fixture.read_bytes()).hexdigest(),samples=cover_samples,normal_input_steps=cover_steps,restart_points=6,first_victory_hp_persisted=16,protector_hp_after=58,two_exact_victories=True)
    cover_ko_reference=next(row['samples'] for row in json.loads(cover_fixture.read_text()) if row['hero_hp']==16 and row['hp']==16 and not row['protected'] and not row.get('flagged',False))
    cover_ko_samples=compare_frames(assets,cover_ko_frames,(1,5,10,11,12,22,49,61,62,63,72,73,145,146,218,274,348,380),cover_ko_reference)
    receipt['party_cover_knockout']=dict(source_fixture_sha256=hashlib.sha256(cover_fixture.read_bytes()).hexdigest(),samples=cover_ko_samples,normal_input_steps=cover_ko_steps,restart_points=6,hero_hp_persisted=16,protector_hp_sequence=[100,58,16,0],four_exact_victories=True,no_auto_revival=True)
    rounds_fixture=ROOT/'game/tests/fixtures/world_roc_two_round.json';continued=json.loads(rounds_fixture.read_text())[0]
    first_reference=continued['first']['samples']+[continued['classifier']]
    first_samples=compare_frames(assets,rounds_frames/'first',(1,49,145,146,218,253,254,264,274,275,276),first_reference)
    second_samples=compare_frames(assets,rounds_frames/'second',(1,5,29,30,31,32,80,93,104,176,177,249,285,305,378,379,411),continued['second']['samples'])
    receipt['two_rounds']=dict(source_fixture_sha256=hashlib.sha256(rounds_fixture.read_bytes()).hexdigest(),first_samples=first_samples,second_samples=second_samples,normal_input_steps=rounds_steps,restart_points=8,first_round_enemy_hp=48,round_camera_draw_consumed=True,selection_wait=30,one_final_reward=True)
    medicine_reference=json.loads((ROOT/'game/tests/fixtures/world_medicine.json').read_text())['roc']['samples']
    medicine_samples=compare_frames(assets,medicine_frames,(1,49,145,146,167,168,169,180,197,198,199,200,231,232,235,247,307,343,363,436,437),medicine_reference)
    receipt['medicine']=dict(samples=medicine_samples,normal_input_steps=medicine_steps,restart_points=8,source_particle_positions=116,source_lighting_checked=True,one_final_reward=True)
    (frames/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print('PASS:21 Medicine buffers match source poses,116 particle positions and lighting with independent pixels;587 inputs, eight restores, cancellation, one reward and world return agree.')
    print('PASS:28 additional two-round buffers match original poses/positions and independent pixels; nonlethal hurt/idle reset, source round launch and exactly-once victory pass with eight restores.')
    print('PASS:18 lethal-cover buffers match original ward/protector/Roc tracks and independent pixels; four connected victories preserve the protector KO, skip its EXP and return without revival, with six restores.')
    print('PASS:18 additional cover buffers match original ward/protector/Roc tracks and independent pixels; two connected victories retain16HP/58HP and source cover ownership with six restores.')
    print('PASS:eight additional knockout/defeat buffers match; two connected Roc encounters retain16HP before terminal defeat, rewards/ownership stay exact and six more prefix restores agree.')
    print('PASS:12 dynamic B scene buffers agree pixel-for-pixel with independent composition; source poses/world positions and quantized source projection agree within4px; 490 normal inputs and six bound-resource process restores preserve rewards/world return. No native window or promotion.')


if __name__=='__main__':
    check()
    if '--check-runtime' in sys.argv:check_runtime()

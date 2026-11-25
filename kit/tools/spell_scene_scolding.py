"""Scolding source contract and approved donor workaround; original texels remain unknown."""
import argparse
import hashlib
import json
import struct
from pathlib import Path

import spell_scene_source as source
import battle_drops

ACCEPTED_PREVIEW_SHA256='0358050397ec30433154927b3fa60014d77886855a200655c59ed0559cedbd2a'

SPANS = (
    (0x80102DE8, 0x80103000, '0da5d1efb0e48f04f09981a580b86ae50b5d6961d9ac36e3a4b2b731322ac581'),
    (0x80103000, 0x801037DC, '52c77a1c86b70bb7d77ae201b7b4cc9b00fb1181fb3241c002880d86ba843b6e'),
    (0x800C3A44, 0x800C3C58, 'bf49c5e58ed88eafd2fa22cbaee16a888e944e1e510652a60e8e876a9adc03a0'),
    (0x800CABCC, 0x800CACC0, 'fdae5307927d257fda0adc5fb82db427ba7f32c418dec766fe5be661f4bbf989'),
    (0x800DE61C, 0x800DE9E0, 'b065008b00fac99b94fe0e9f0c0c27225004379cc51787128559c5fbec42a4e8'),
    (0x800DEBE8, 0x800DEE44, '704d45751e6cfed467d85ad563e51da728f7ae47deb912f3d98dbda4ed1dade2'),
    (0x800DEE44, 0x800DF144, '7d631e8df5dafb59a6aa5c354d981e3a6b41dad3c6ce079fa2958787e8a9637b'),
    (0x800DF144, 0x800DF3B4, '5acc151a445e96310855f260a50df26afc269cd9aff5ea73e8bdf19dcf1937cb'),
    (0x800E79E8, 0x800E7D88, '5125a5eff14a5e8dc6c3a8ab1e187304081a61576b9e5ffc5ac1080a49644945'),
    (0x800C3500, 0x800C3670, '9557fd82957a9c645931dfc8005b4ac9d475497a199ff11d4c215c6a8e510466'),
    (0x800C3670, 0x800C36A4, '2d07eed9475eac1c55f32a9dbcaef915c5da814850516b654ced8efbe4c60143'),
    (0x800C33A0, 0x800C34CC, 'c8bf5ce17b63607e3f07507683a4a179350cc784a460e306278cdba61774da8f'),
    (0x80128B8C, 0x80128C60, '3ced3b960587a1f84bd47f658e29ecc57232f63dc6494047612195105236c1db'),
    (0x80132044, 0x80132280, 'e1b351dab6bbf73e31faf583cd56e290a2d874739b93f9fc98bac459d0f89839'),
    (0x801322D8, 0x801323A4, '55b65c257bd296a2e2be1378252330eccbc6b49895b7b232934394f09925b97e'),
    (0x8013240C, 0x801324D8, 'ef69162f47882c8b7a88baed4223e50aad1f22ff0632e8a1fa4d88f89a6c06f1'),
    (0x800C3704, 0x800C3800, '42b99baa1e5cf53f783b715a34cd95719c02485b71f0b00062e94c3bdcc04a66'),
    (0x800C36A4, 0x800C36D4, 'a381e61647339ddd95654f18a8c438caac3a61d2f3997101855e6e22d29298cf'),
)


def grid_upload_candidates(image):
    """Address-compatible writers only; no claim that these slots were queued."""
    checks={0x800C3A5C:0x34030005,0x800C3A8C:0x34020014,
            0x800C3AEC:0x34020040,0x800C3AF4:0x34020080,
            0x800C3B0C:0x24420140,0x800C3B20:0x0C052164,
            0x800C3B60:0x34030005,0x800C3B90:0x34020014,
            0x800C3BF8:0x34020020,0x800C3C00:0x34020080,
            0x800C3C18:0x24420140,0x800C3C28:0x0C052164}
    for pc,word in checks.items():
        if image.word(pc)!=word:raise ValueError('Scolding candidate grid uploader changed')
    candidates=[]
    for uploader,width in ((0x800C3A44,64),(0x800C3B54,32)):
        for slot in range(60):
            x=320+64*(slot//20*5+slot%5);y=128*((slot%20)//5)
            if x<=960 and 964<=x+width and y in (256,384):
                candidates.append(dict(uploader=uploader,counter=slot,rect=[x,y,width,128],
                                       sampled_rows=[y,y+127],queued_source=None))
    return candidates


def other_upload_witnesses(image, loading=None):
    """Two bounded upload routes; this is not a census of all VRAM writers."""
    from disc import extract
    loading=extract(18743,114116) if loading is None else loading
    start,stop=0x408,0x4B8
    digest='5980147c70c0a01378aeb2a2c361065aea9689899457ef2e2a019f59cb9b8e6a'
    if len(loading)!=114116 or hashlib.sha256(loading[start:stop]).hexdigest()!=digest:
        raise ValueError('Loading upload source changed')
    for pc,word in {0x800CAC18:0x34020003,0x800CAC50:0x34060020,
                    0x800CAC58:0x34060040,0x800CAC64:0x00031980,
                    0x800CAC68:0x00021140,0x800CAC6C:0x30420060,
                    0x800CAC70:0x24420340,0x800CAC78:0x306300FF,
                    0x800CAC7C:0x24630080,0x800CAC80:0x0C052164}.items():
        if image.word(pc)!=word:raise ValueError('Menu upload source changed')
    # Remainder modulo3 selects X; the masked quotient cycles four Y bands.
    menu_rects=[[x,y,32,64] for y in (128,192,256,320) for x in (832,864,896)]
    return [dict(role='menu_sprite_pixels',source_file='MAIN.EXE',call_site=0x800CAC80,
                 rectangles=menu_rects,sampled_strip_overlap=False),
            dict(role='loading_pixels',source_file='DATA/00_INIT/LOADING.BIN',lba=18743,size=114116,
                 code_span=dict(start=0x80010408,stop=0x800104B8,sha256=digest),
                 call_site=0x8001046C,dispatch_slot=0x70,source_address=0x8001727C,
                 rectangles=[[896,128,64,128]],sampled_strip_overlap=False),
            dict(role='loading_palette',source_file='DATA/00_INIT/LOADING.BIN',lba=18743,size=114116,
                 call_site=0x800104B0,dispatch_slot=0x70,source_address=0x800151EC,
                 rectangles=[[0,511,256,1]],sampled_strip_overlap=False)]


def battle_entry_texture_budget():
    """Bound the standard selector-table entry queue, not every possible VRAM writer."""
    import area_encounter_tables as encounters
    import battle_bin
    from disc import extract
    def section_count(data,offset):
        if not 0<=offset<=len(data)-24:raise ValueError('battle texture section outside file')
        return data[offset+4]
    players=[]
    for rec in encounters.iso_files():
        if not rec['path'].startswith('DATA/04_PLAY/') or not rec['path'].endswith('.BIN'):continue
        data=extract(rec['lba'],rec['size'])
        section=struct.unpack_from('<I',data,0x24)[0]
        players.append(dict(file=rec['path'],lba=rec['lba'],size=rec['size'],sha256=hashlib.sha256(data).hexdigest(),
                            section_offset=section,pages=section_count(data,section)))
    if not players:raise ValueError('missing player battle texture sections')
    party_upper=6*max(p['pages'] for p in players)
    sections,_,errors,shared=battle_bin.parse(need_atlases=False)
    if errors:raise ValueError(errors)
    shared_pages=sections[0]['c_count'];areas=[]
    for rec in encounters.area_data_files():
        data=encounters.load(rec)
        def rd(address):
            off=address-encounters.BASE
            if not 0<=off<=len(data)-4:raise ValueError('battle queue pointer outside area')
            return struct.unpack_from('<I',data,off)[0]
        row=dict(file=rec['path'],lba=rec['lba'],size=rec['size'],sha256=hashlib.sha256(data).hexdigest())
        descriptor=rd(encounters.BASE);resources=rd(descriptor+12);directory=rd(resources) if resources else 0
        if not directory:
            areas.append(dict(**row,status='null_battle_directory'));continue
        ground,scenery,selectors,table=[rd(directory+4*i) for i in range(4)]
        _,_,formations=encounters.encounter_structs(data,selectors,rd(table))
        ground_pages=section_count(data,ground-encounters.BASE)
        scenery_pages=section_count(data,scenery-encounters.BASE) if scenery else 0
        rows=[]
        for formation in formations:
            enemy_pages=sum(section_count(data,rd(rd(table+4*i)+44)-encounters.BASE) for i in set(formation['ids']))
            rows.append(dict(index=formation['index'],enemy_pages=enemy_pages,
                             pages_upper=ground_pages+party_upper+enemy_pages+shared_pages+scenery_pages))
        areas.append(dict(**row,status='bounded_standard_entry',ground_pages=ground_pages,scenery_pages=scenery_pages,formations=rows))
    lba,size=battle_bin.battle_bin_lba()
    maximum=max(f['pages_upper'] for a in areas if a['status']=='bounded_standard_entry' for f in a['formations'])
    return dict(scope='standard area selector-table entry queue; other paths and inherited texture contents unresolved',
                decoder='raw section and selector metadata; no pixel decoding',
                initial_counter=0,party_slots=6,party_pages_upper=party_upper,players=players,
                shared=dict(file=battle_bin.DISC_PATH,lba=lba,size=size,sha256=hashlib.sha256(shared).hexdigest(),pages=shared_pages),
                areas=areas,pages_upper=maximum,counter_range=[0,maximum-1])


def profile(image=None):
    image = image or source.Image()
    for start, stop, digest in SPANS:
        if hashlib.sha256(image.data[start-image.base:stop-image.base]).hexdigest() != digest:
            raise ValueError('Scolding quad source changed; requalify its equations')
    for pc, word in {0x8014AEA4:0x3402002C, 0x8014AEAC:0xA0820007,
                     0x8014AE20:0x34420001, 0x8014AE34:0xA0820007}.items():
        if image.word(pc) != word:raise ValueError('Scolding quad material helper changed')
    candidates=grid_upload_candidates(image)
    facts, analysis = source.analyze(0x80102DE8, image)
    if [p['updates'] for p in source.timeline(facts, analysis)] != [64, 64, 32, 96]:
        raise ValueError('unresolved Scolding phases')
    return dict(schema='suikoden-scolding-quads/6', producer='spell-scene-scolding/6',
                source=dict(file='MAIN.EXE', lba=17976, size=757760, image_base=image.base,
                            spans=[dict(start=a, stop=b, sha256=h) for a,b,h in SPANS]),
                original_texture_ready=False, blockers=['original_quad_texture_residency'],
                workaround=dict(runtime_ready=True,approval='2026-11-12 user requests Charm Arrow bank replacement',
                                donor=dict(section=2,animation=4,piece=1),blend='additive',uv='full donor piece per quad',
                                visual_acceptance='user_accepted_2026-11-12',accepted_preview_sha256=ACCEPTED_PREVIEW_SHA256),
                projection_status='native_shared_primitive_verified',
                address_compatible_grid_uploads=candidates,
                checked_upload_domains=other_upload_witnesses(image),
                battle_entry_texture_budget=battle_entry_texture_budget(),
                phases=[64,64,32,96], impact=256, release=257, reaction=160,
                cameras=[dict(at=1, updates=60, block=0x8016D6BC), dict(at=97, updates=60, block=0x8016D7DC)],
                records=90, drawn_indices=list(range(0,90,2)),
                texture=dict(mode='indexed4', page=[960,256], clut=[1008,504], raw=True,
                             semitransparent=False, pixel_source=None,
                             uv=[[[0,(12*i)&255],[12,(12*i)&255],[0,(12*(i+1))&255],[12,(12*(i+1))&255]] for i in range(90)]),
                units=dict(position='Q12 before signed integer shift', scale='Q12', angles='4096 per turn', width='Q12 before integer halving'),
                projection='Shift local Q12 center to signed16, rotate/scale, add integer caster position, narrow to signed16 again, then project with scene matrix. Project four XY offsets separately with scene matrix and add to projected center.',
                copy='After head update, copy records89..1 from predecessor; copy active flag unconditionally, transform/width only when active. Draw even indices.',
                flight=dict(start=129, updates=32, initial=[0,50*4096,-32*4096], target_height_multiplier=2048,
                            division='truncate signed endpoint delta toward zero before repeated addition'),
                texture_note='The ten shared spell uploads occupy X640..959. These UVs address X960..963. The known SLUS UI/glyph uploads occupy Y0..255, while this texture page starts at Y256. Neither witness establishes the sampled pixel producer. Visible record42 interpolates V248 to V4; do not replace it with a twelve-row crop.')


def trail_states(update, caster_q12, target_q12, target_sprite_height):
    """Lower recovered state equations, without drawing or inventing texture bytes."""
    if not isinstance(update,int) or not isinstance(target_sprite_height,int) or not 0 <= update <= 257 or len(caster_q12) != 3 or len(target_q12) != 3 or not 0 <= target_sprite_height <= 255:
        raise ValueError('invalid Scolding scene inputs')
    if any(not isinstance(v,int) or abs(v)>32767*4096 for v in (*caster_q12,*target_q12)):
        raise ValueError('invalid Scolding scene positions')
    initial=[0,50*4096,-32*4096]
    endpoint=[target_q12[i]-caster_q12[i]-(target_sprite_height*2048 if i==2 else 0) for i in range(3)]
    delta=[b-a for a,b in zip(initial,endpoint)]
    velocity=[(abs(v)//32)*(-1 if v<0 else 1) for v in delta]
    result=[]
    for index in range(90):
        # Record1 observes the newly updated head in the same callback.
        age=update-max(index-1,0)
        if not 65 <= age < 160 or update >= 256:continue
        grow=min(age-64,64);flight=max(age-128,0)
        width=(6*4096+2560*flight)>>12;half=width//2
        result.append(dict(index=index, drawn=index%2==0,
                           position=[p+v*flight for p,v in zip(initial,velocity)],
                           scale=[1+64*grow,1+64*grow,4096], angles=[0,0,64*grow],
                           width=width, corners=[[half,half,0],[half,-half,0],[-half,half,0],[-half,-half,0]]))
    return result


def quad_geometry(update, caster_q12, target_q12, target_sprite_height, camera):
    """Texture-independent packet vertices; UVs retain their source byte wrap."""
    if len(camera)!=12 or any(not isinstance(v,int) or abs(v)>32767 for v in camera):
        raise ValueError('invalid Scolding camera')
    nodes=trail_states(update,caster_q12,target_q12,target_sprite_height)
    caster=[v>>12 for v in caster_q12];result=[]
    for node in nodes:
        if not node['drawn']:continue
        world=battle_drops.transform([battle_drops.short(v>>12) for v in node['position']],node['angles'],node['scale'],caster)
        center=battle_drops.projected(world,camera)
        vertices=[]
        for corner in node['corners']:
            offset=battle_drops.projected(corner,camera,centered=False)
            vertices.append([battle_drops.short(center[i]+offset[i]) for i in range(2)])
        index=node['index']
        result.append(dict(index=index,vertices=vertices,depth=max(0,min(65535,center[2]))>>2,
                           uv=[[0,(12*index)&255],[12,(12*index)&255],
                               [0,(12*(index+1))&255],[12,(12*(index+1))&255]]))
    return result


def program(effect,pieces):
    """Approved glow replacement; original trail state and geometry remain the contract."""
    profile()
    donor=effect['animations'][4]['frames'][0]['piece']
    if donor not in (1,'piece_1'):raise ValueError('approved Scolding donor changed')
    import export_spell_scenes as export
    duration=258;caster=[];head=[];wash=[];tints=export.source_tints(effect,duration)
    for u in range(duration):
        caster.append(export.sample(pieces[0] if 0<u<256 else None,position=[0,0,-60*4096],tint=tints[u]))
        grow=min(max(u-64,0),64);flight=min(max(u-128,0),32);half=((6*4096+2560*flight)>>12)//2
        head.append(export.sample(pieces[1],visible=65<=u<160,position=[0,50*4096,-32*4096],
                                  scale=[1+64*grow,1+64*grow,4096],angles=[0,0,64*grow],tint=[128]*3,
                                  quad_offsets=[[half,half,0],[half,-half,0],[-half,half,0],[-half,-half,0]]))
        wash.append(([max(0,(5461*min(u,64)-3413*min(max(u-160,0),96))>>12)]*2+
                    [max(0,(4369*min(u,64)-2730*min(max(u-160,0),96))>>12)]) if u<256 else [0]*3)
    reaction=export.reaction_track(0x8016F1CC)
    return dict(impact=256,duration=257,initial_draws=0,tracks=[caster,head],
                objects=[dict(anchor='caster',track=0)]+[dict(anchor='caster',track=1,start=i,
                    flight=dict(start=129,updates=32,target_height_q12=2048),blend='additive') for i in range(0,90,2)],
                cameras=export.source_cameras(effect,unresolved=(97,)),meshes=[],wash=wash,wash_blend='subtractive',
                reaction=dict(start=160,**reaction),center_after_reaction=False)


def geometry_fixture():
    """No texture binding or scene-readiness claim accompanies these vectors."""
    cases=[]
    for address in (0x8016B878,0x8016D6BC,0x8016D7DC):
        camera=[v>>12 for v in battle_drops.block_at(address)]
        for caster,target,height in [((491521,-208897,32769),(-520193,159745,184319),33),
                                     ((-134213632,819200,-126976),(942080,-450560,40960),255)]:
            for update in (65,96,128,129,144,159,160,161,192,224,246,247):
                commands=quad_geometry(update,caster,target,height,camera)
                nodes=[n for n in trail_states(update,caster,target,height) if n['drawn']]
                for node,command in zip(nodes,commands,strict=True):
                    world=battle_drops.transform([battle_drops.short(v>>12) for v in node['position']],node['angles'],node['scale'],[v>>12 for v in caster])
                    cases.append(dict(camera=dict(zip(('position','angles','c','d'),[camera[i:i+3] for i in range(0,12,3)])),
                                      world=world,offsets=node['corners'],vertices=command['vertices'],depth=command['depth']))
    return dict(schema='suikoden-scolding-projection-vectors/1',cases=cases)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--geometry-out',type=Path)
    args=parser.parse_args()
    args.out.parent.mkdir(parents=True,exist_ok=True)
    args.out.write_text(json.dumps(profile(),indent=2)+'\n')
    if args.geometry_out:args.geometry_out.write_text(json.dumps(geometry_fixture(),separators=(',',':'))+'\n')
    print(args.out)


if __name__=='__main__':main()

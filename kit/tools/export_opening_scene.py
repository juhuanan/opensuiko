"""Private palace candidate art and animation metadata; no acceptance or promotion."""
from pathlib import Path
import hashlib
import json
import struct

from PIL import Image
import area_scene as scene
import maindec
import opening_audience
import system_glyphs
import war_text
from lzss import decode_strict
from psx_vram import texpage_encode
from export_first_room import Atlas, source, hero_clips, frame_table, collision_sources, scenery_query, terrain_query, walkable_grid, combine_ground
from psx_vram import rgb555_to_rgb888

ROOT=Path(__file__).resolve().parents[2]


def room_draws(data,number,atlas,proof,object_records=None,*,bind_scenery=False):
    """Export map and animated scenery draws for the supplied object state."""
    room=scene.room_record(data,number);sec=scene.section_off(data,room['section'])
    vram,_=scene.load_scene_materials(data,sec,proof)
    preview,prims,meta=scene.scene_compose(data,number,vram,npcs=False,object_records=object_records)
    if meta['scenery']['unresolved']:raise ValueError('unresolved opening scenery')
    draws=[]
    codes={key:set(struct.unpack_from(f"<{layer['w']*layer['h']}H",data,layer['offset']))
           if layer is not None and layer['offset'] is not None else set()
           for key,layer in ((key,meta[key]) for key in ('primary','secondary'))}
    materials=scene.scene_map_materials(data,sec,scene.section_off(data,room['byte9']),codes['primary'],codes['secondary'])
    for key,mats in zip(('primary','secondary'),materials):
        layer=meta[key]
        if layer is None or layer['offset'] is None:continue
        image,details=scene.map_layer_image(data,layer['offset'],layer['w'],layer['h'],mats,rgb555_to_rgb888,semi_transparent=key=='secondary')
        if details['missing_codes']:raise ValueError('missing opening map material')
        draws.append(dict(rect=atlas.add(image),x=0,y=0,depth=scene.GROUND_DEPTH_ORIGIN-layer['tag']))
    animations=frame_table(data,sec)
    base_objects=scene.scenery_records(data,sec) if object_records is None else object_records
    scenery_frames={}
    keys={(p.get('object'),p.get('vertex')) for p in prims}
    for kind,durations in animations.items():
        kind_objects=[s for s in base_objects if s['type']==kind]
        for frame in range(len(durations)):
            if (kind,frame) not in scenery_frames:
                candidates,details=scene.scenery_primitives(data,sec,vram,0,frame,proof,object_records=kind_objects)
                if details['unresolved']:raise ValueError('unresolved animated scenery')
                scenery_frames[(kind,frame)]={(p['object'],p['vertex']):p for p in candidates}
            for key,p in scenery_frames[(kind,frame)].items():
                if p['type']==kind and key not in keys:
                    p=dict(p,kind='scenery',tag=scene.scenery_tag(p['order'],room))
                    prims.append(p)
                    keys.add(key)
    prims.sort(key=lambda p:(-p['tag'],p['object'],p['vertex']))
    hidden_rect=None
    for primitive in prims:
        image=scene._prim_to_tile(primitive,rgb555_to_rgb888)
        if image is None:continue
        draw=dict(rect=atlas.add(image),x=primitive['left'],y=primitive['top'],depth=scene.GROUND_DEPTH_ORIGIN-primitive['tag'])
        if bind_scenery and primitive.get('kind')=='scenery':
            draw['scenery_object']=primitive['object']
        if primitive.get('kind')=='scenery' and primitive['type'] in animations:
            draw['frames']=[]
            for frame,ticks in enumerate(animations[primitive['type']]):
                variant=scenery_frames[(primitive['type'],frame)].get((primitive['object'],primitive['vertex']))
                image=scene._prim_to_tile(variant,rgb555_to_rgb888) if variant is not None else None
                if variant is not None and scene.scenery_tag(variant['order'],room)!=primitive['tag']:raise ValueError('opening animated scenery changes depth')
                if image is None:
                    if hidden_rect is None:hidden_rect=atlas.add(Image.new('RGBA',(1,1)))
                    draw['frames'].append(dict(rect=hidden_rect,x=draw['x'],y=draw['y'],ticks=ticks))
                else:
                    draw['frames'].append(dict(rect=atlas.add(image),x=variant['left'],y=variant['top'],ticks=ticks))
        draws.append(draw)
    return draws,preview


def surface_cells(data, number, object_records=None):
    section=scene.section_off(data,scene.room_record(data,number)['section'])
    objects=collision_sources(data,section,object_records=object_records)
    width,height,ground=walkable_grid(data,section,object_records=object_records)
    cells=[]
    for level in (0,1):
        for y in range(height-1):
            for x in range(width-1):
                query,index=scenery_query(objects,x,y,level)
                if not query:continue
                terrain=terrain_query(data,section,x,y)
                upper=(query>>4)&15
                solid=combine_ground(terrain,query,index,level)
                support=None
                if index and upper:
                    obj=objects[index-1]
                    if obj['b4'] not in (0,1):raise ValueError('palace surface exceeds supported levels')
                    support=dict(id=f"scenery_{obj['index']}",height=obj['b4'],depth=256-obj['order'])
                cells.append(dict(x=x*8,y=y*8,height=level,walkable=(ground[y*width+x]=='1' if level==0 else solid==0),support=support))
    return cells


def character_clips(data,sec,binding,vram,atlas):
    result=[]
    for variant in range(4):
        dtab=scene.ptr_at(data,binding['context']+20)
        descriptor=scene.ptr_at(data,dtab+variant*4)
        if descriptor is None:raise ValueError('missing opening actor variant')
        count=data[descriptor]
        if not 0<count<=64:raise ValueError('invalid opening actor sequence')
        frames=[]
        for frame in range(count):
            info=scene.descriptor_sheet(data,binding['context'],variant,frame)
            if info is None:raise ValueError('missing opening actor frame')
            sheet=info['sheet'];width,height,ax,ay=data[sheet+2:sheet+6]
            pieces=[data[sheet+8+8*i:sheet+16+8*i] for i in range(data[sheet])]
            width=max([width]+[p[0]+p[4] for p in pieces])
            height=max([height]+[p[1]+p[5] for p in pieces])
            image=Image.new('RGBA',(width,height))
            for i in range(data[sheet]):
                x,y,cell,uv,w,h,palette,flags=data[sheet+8+8*i:sheet+16+8*i]
                if palette>=len(binding['palette_offsets']) or flags&~3:raise ValueError(f'unsupported opening actor piece id{binding["id"]} variant{variant} frame{frame} palette{palette} flags{flags}')
                slot=binding['atlas_slot']+cell;gx,gy,fold=scene.atlas_slot_geometry(slot)
                u,v=(uv&15)*8,fold+(uv>>4)*8
                piece=Image.new('RGBA',(w,h))
                for py in range(h):
                    for px in range(w):
                        texel=vram.sample_texel(scene._texpage(gx,(slot%20)//10),(u+px)&255,(v+py)&255)
                        word=vram.get_word(scene.NPC_CLUT_X+(texel&31),binding['clut_row']+palette)
                        piece.putpixel((px,py),(*rgb555_to_rgb888(word),0 if word==0 else 255))
                if flags&2:piece=piece.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
                if flags&1:piece=piece.transpose(Image.Transpose.FLIP_TOP_BOTTOM)
                if x+w>width or y+h>height:raise ValueError(f'opening actor {binding["id"]} variant{variant} frame{frame} piece{x,y,w,h} exceeds sheet{width,height} at{sheet:#x}')
                image.alpha_composite(piece,(x,y))
            frames.append(dict(rect=atlas.add(image),anchor_x=ax,anchor_y=ay,ticks=info['duration'] or 256))
        result.append(dict(variant=variant,idle_frame=1 if count>1 else 0,flags=data[descriptor+1],frames=frames))
    return result


def portrait_payload(raw,image_offset,palette_offset):
    if image_offset<0 or image_offset+4>len(raw):raise ValueError('portrait header bounds changed')
    length=scene.u32(raw,image_offset)
    if length<=0 or image_offset+4+length>len(raw) or palette_offset<0 or palette_offset+512>len(raw):
        raise ValueError('portrait payload bounds changed')
    plane=decode_strict(raw[image_offset+4:image_offset+4+length])
    if len(plane)!=4096:raise ValueError('opening portrait extent changed')
    return plane,struct.unpack_from('<256H',raw,palette_offset),length


def dialogue_art(data,hero,atlas):
    portraits=[];evidence=[]
    sec=scene.section_off(data,scene.room_record(data,2)['section'])
    bindings=scene.character_bindings(data,sec)
    for code in (8,110,111,112,119):
        if code==119:
            portraits.append(dict(image=code,rect=None));continue
        if code==8:
            raw=hero;image_offset,palette_offset=struct.unpack_from('<II',raw,44)
        else:
            raw=data;record=bindings[code]['record']
            image_offset=scene.ptr_at(raw,record+4);palette_offset=scene.ptr_at(raw,record+8)
        plane,palette,length=portrait_payload(raw,image_offset,palette_offset)
        image=Image.new('RGBA',(64,64))
        image.putdata([(*rgb555_to_rgb888(palette[index]),0 if palette[index]==0 else 255) for index in plane])
        portraits.append(dict(image=code,rect=atlas.add(image)))
        evidence.append(dict(image=code,file='SHU.BIN' if code==8 else 'VAA.BIN',offset=image_offset,compressed_bytes=length,palette=palette_offset,decoder='lzss.py decode_strict;4096-byte8bpp;256RGB555'))
    glyphs,window,font_proof=dialogue_font_art(atlas)
    return portraits,glyphs,window,dict(portraits=evidence,**font_proof)


def dialogue_font_art(atlas):
    vram=system_glyphs.replay();page=texpage_encode(960,0,0)
    def pixels(u,v,w,h,semi=False):
        image=Image.new('RGBA',(w,h));values=[]
        for y in range(h):
            for x in range(w):
                index=vram.sample_texel(page,(u+x)&255,(v+y)&255)
                word=vram.get_word(1008+index,504)
                values.append((*rgb555_to_rgb888(word),0 if word==0 else 128 if semi and word&0x8000 else 255))
        image.putdata(values);return image
    glyphs=[]
    for code,character in war_text.SUBST.items():
        if len(character)!=1:continue  # Decoded digraphs use the ordinary character glyphs.
        if code==16:
            glyphs.append(dict(character=character,rect=None,advance=8));continue
        index=code-17
        if index<62:u,v=(index&15)*8+128,(index>>4)*12
        else:
            index+=26;u,v=(index&15)*8+128,((index>>4)*12-128)&255
        trim=maindec.body()[0x80171F5C-maindec.MBASE+code-17] if 17<=code<43 else 0
        glyphs.append(dict(character=character,rect=atlas.add(pixels(u,v,8,12)),advance=8-trim))
    window=[]
    roles=('center','top_left','top_right','bottom_left','bottom_right','top','bottom','left','right')
    for i,role in enumerate(roles):
        u,v=maindec.body()[0x80171F20-maindec.MBASE+2*i:0x80171F22-maindec.MBASE+2*i]
        window.append(dict(role=role,rect=atlas.add(pixels(u,v,12,12,semi=True))))
    return glyphs,window,dict(font_sources=[{key:value for key,value in entry.items() if key!='payload'} for entry in system_glyphs.sources()],glyph_consumer='MAIN801466EC..801467D4',window_uv_table='MAIN80171F20',window_consumer='MAIN80144E8C;MAIN80144C58')


def export(output):
    output=Path(output).resolve();accepted=(ROOT/'kit/work/accepted').resolve()
    if output==accepted or accepted in output.parents:raise ValueError('candidate output only')
    output.mkdir(parents=True,exist_ok=True)
    data,proof=source('/VAA.BIN');hero,hero_source=source('/SHU.BIN');atlas=Atlas()
    atlas.image=Image.new('RGBA',(4096,4096))
    player,player_proof=hero_clips(hero,atlas)
    rooms=[];characters=[];known=set()
    for number in (2,1):
        draws,preview=room_draws(data,number,atlas,proof)
        preview.save(output/f'vaa_room_{number}_background_review.png')
        actors,_=opening_audience.actor_bindings(data,number,bytearray(64))
        flags=bytearray(64);flags[0]=64
        after,_=opening_audience.actor_bindings(data,number,flags)
        rooms.append(dict(id=f'vaa_room_{number}',draws=draws,actors=actors,after_audience_actors=after,surfaces=surface_cells(data,number)))
        sec=scene.section_off(data,scene.room_record(data,number)['section'])
        vram,materials=scene.load_scene_materials(data,sec,proof)
        start=materials['atlas_base']+sum(len(context['atlases']) for context in materials['contexts'] if not context.get('is_32_colour'))
        bindings,_=scene.load_npc_contexts(data,sec,vram,start,proof)
        for native_id,binding in bindings.items():
            if native_id in known:continue
            known.add(native_id)
            characters.append(dict(id=f'palace_character_{native_id}',clips=character_clips(data,sec,binding,vram,atlas)))
    portraits,glyphs,window,dialogue_proof=dialogue_art(data,hero,atlas)
    atlas.save(output/'atlas.png')
    content=dict(portraits=portraits,glyphs=glyphs,window=window,schema='suikoden-opening-scene/3',atlas='atlas.png',rooms=rooms,player_clips=player,characters=characters)
    (output/'scene.json').write_text(json.dumps(content,indent=2)+'\n')
    (output/'provenance.json').write_text(json.dumps(dict(exporter='export_opening_scene.py/1',source=proof,hero=hero_source,hero_clips=player_proof,dialogue=dialogue_proof,status='candidate; human media acceptance and promotion pending',files={name:hashlib.sha256((output/name).read_bytes()).hexdigest() for name in ('atlas.png','scene.json')}),indent=2)+'\n')
    return content


if __name__=='__main__':
    value=export(ROOT/'kit/work/build/opening')
    print(f"Exported {len(value['rooms'])} palace rooms and {len(value['characters'])} character clip sets; candidate only")

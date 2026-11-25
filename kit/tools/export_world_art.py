"""Source B/C-world candidate atlas and named render data; never promotes media."""
from pathlib import Path
import argparse
import hashlib
import json
import shutil
import struct
from PIL import Image
import lzss
import maindec
import world_map_render as world
from export_first_room import source

ROOT = Path(__file__).resolve().parents[2]
RESERVE = 3 * 1024**3


def build(region='b'):
    if region not in ('b','c'):raise ValueError('unsupported world-art region')
    raw, origin = source(f'/{region.upper()}_DATA.BIN')
    _, main_origin = source('MAIN.EXE')
    plane = world.parse_worldmap(raw)
    image = Image.new('RGBA', (256, 368))
    tiles = []
    for index in range(320):
        atlas, tile, palette = world.tile_of(plane, index)
        tx, ty = tile % 8 * 16, tile // 8 * 16
        words_at = plane['clut_offsets'][palette]
        rect = dict(x=index % 16 * 16, y=index // 16 * 16, w=16, h=16)
        for y in range(16):
            for x in range(16):
                value = plane['pages'][atlas][(ty+y)*128+tx+x]
                word = struct.unpack_from('<H', raw, words_at+value*2)[0]
                image.putpixel((rect['x']+x, rect['y']+y), (*world.rgb555(word), 255 if word else 0))
        tiles.append(rect)
    pointer = lambda off: struct.unpack_from('<I', raw, off)[0] - world.AREA_BASE
    descriptor = pointer(0)
    resources = pointer(descriptor+12)
    section = pointer(resources+4)  # source foot mode selects resource1
    ne, nf, nc, flags = struct.unpack_from('<HHBB', raw, section)
    if (ne,nf,nc,flags) != (36,4,2,0x81):
        raise ValueError('unsupported world-foot section')
    ct, dt, et, ft = [pointer(section+n) for n in (8,12,16,20)]
    pages=[]; page_proof=[]
    for i in range(nc):
        offset=pointer(ct+4*i); length=struct.unpack_from('<I',raw,offset)[0]
        decoded=lzss.decode_strict(raw[offset+4:offset+4+length])
        if len(decoded)!=16384:raise ValueError('invalid world-foot page')
        pages.append(decoded);page_proof.append(dict(offset=offset,compressed_bytes=length,decoded_bytes=len(decoded)))
    poses=[]; pose_offsets=[]
    for i in range(ne):
        offset=pointer(et+4*i);count,_,width,height,ax,ay=raw[offset:offset+6]
        # The selected source pieces carry exact dimensions, not inclusive maxima.
        if (count,width,height,ax,ay)!=(1,16,16,0,0):raise ValueError('unsupported world-foot pose')
        x,y,page,tile,w,h,palette,flip=raw[offset+8:offset+16]
        if (x,y,w,h,flip)!=(0,0,16,16,0) or page>=nc or palette>=flags&63:raise ValueError('unsupported world-foot piece')
        clut=pointer(dt+4*palette);u,v=(tile&15)*8,(tile>>4)*8
        if u+w>128 or v+h>128:raise ValueError('world-foot piece outside page')
        rect=dict(x=i%16*16,y=320+i//16*16,w=16,h=16)
        for py in range(h):
            for px in range(w):
                index=pages[page][(v+py)*128+u+px]
                if index>=32:raise ValueError('world-foot index outside32-entry CLUT')
                word=struct.unpack_from('<H',raw,clut+2*index)[0]
                image.putpixel((rect['x']+px,rect['y']+py),(*world.rgb555(word),255 if word else 0))
        poses.append(rect);pose_offsets.append(offset)
    clips=[]
    for i in range(nf):
        offset=pointer(ft+4*i);count,flags=raw[offset:offset+2]
        if flags!=3 or count!=12:raise ValueError('unsupported world-foot animation')
        frames=[dict(pose=raw[offset+4+2*j],ticks=raw[offset+5+2*j] or 256) for j in range(count)]
        if any(frame['pose']>=ne for frame in frames):raise ValueError('world-foot frame outside pose table')
        clips.append(frames)
    data=dict(schema='suikoden-world-art/1',region=f'region_{region}',atlas='world.png',atlas_width=256,atlas_height=368,cells=list(plane['codes']),tiles=tiles,poses=poses,clips=clips,direction_clips=[maindec.mword(0x8016F33C+4*i) for i in range(4)],initial_clip=0,initial_water_tile=10,hero_x=160,hero_y=128)
    proof=dict(schema='suikoden-world-art-proof/1',source=origin,main=main_origin,decoder=f'lzss.py {lzss.__version__}; world_map_render.parse_worldmap',map=dict(header=plane['s_off'],tilemap=plane['tilemap_off'],pages=plane['page_offsets'],cluts=plane['clut_offsets'],palette_selectors=plane['etab_offsets']),foot=dict(section=section,pages=page_proof,poses=pose_offsets,cluts=[pointer(dt)],piece_dimensions='exact16x16, original800C3EF0 consumer; no inclusive+1'),status='candidate; image acceptance and promotion pending',scope=f'Region{1 if region=="b" else 2} foot travel only; no boats, minimap or battle media. Pixel masks retain RGB555-zero transparency; source water underlay and clock are rendered by the runtime model.')
    return data,image,proof


def export(output, region='b'):
    output=Path(output).resolve()
    if ROOT/'kit/work/accepted' in (output,*output.parents):raise ValueError('world art export cannot write accepted content')
    parent=output
    while not parent.exists():parent=parent.parent
    if shutil.disk_usage(parent).free < RESERVE+2*1024**2:raise OSError('world art needs2MiB headroom above the shared3GiB reserve')
    data,image,proof=build(region)
    output.mkdir(parents=True,exist_ok=True)
    image.save(output/'world.png')
    (output/'scene.json').write_text(json.dumps(data,separators=(',',':'))+'\n')
    proof['files']={name:hashlib.sha256((output/name).read_bytes()).hexdigest() for name in ('world.png','scene.json')}
    (output/'provenance.json').write_text(json.dumps(proof,indent=2)+'\n')
    return data


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',type=Path)
    parser.add_argument('--region',choices=('b','c'),default='b')
    parser.add_argument('--metadata',action='store_true',help='refresh the tracked semantic data alongside the private candidate')
    args=parser.parse_args()
    output=args.out or ROOT/('kit/work/build/world-travel-art' if args.region=='b' else 'kit/work/build/world-travel-art-c')
    data=export(output,args.region)
    if args.metadata:(ROOT/f'game/assets/world_art_{args.region}.json').write_text(json.dumps(data,separators=(',',':'))+'\n')
    print(f'Exported320 terrain tiles,36 foot poses and4 clips to {output}; candidate only')

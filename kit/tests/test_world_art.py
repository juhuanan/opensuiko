"""Disc/source world presentation checks; no window, GPU or audio device."""
from pathlib import Path
import hashlib
import json
import struct
import sys
import tempfile
sys.path[:0]=[str(Path(__file__).resolve().parents[1]/'tools')]
import export_world_art as export
from export_first_room import source
from test_canonical_start import assert_main_words
from test_opening_events import assert_span
import maindec as M
import world_map_render as W
ROOT=Path(__file__).resolve().parents[2]


def source_viewport(blob,plane,hero,grid,ox,oy,water):
    from PIL import Image
    result=Image.new('RGBA',(320,240),(0,0,0,255));cache={}
    def tile(code):
        if code not in cache:
            atlas,index,palette=W.tile_of(plane,code);pixels=[]
            for y in range(16):
                for x in range(16):
                    value=plane['pages'][atlas][(index//8*16+y)*128+index%8*16+x]
                    address=plane['clut_offsets'][palette]+2*value
                    word=int.from_bytes(blob[address:address+2],'little')
                    pixels.append((*W.rgb555(word),255 if word else 0))
            image=Image.new('RGBA',(16,16));image.putdata(pixels);cache[code]=image
        return cache[code]
    for background in (True,False):
        for y in range(15+(oy%16!=0)):
            for x in range(20+(ox%16!=0)):
                index=((oy//16+y)%120)*160+(ox//16+x)%160
                code=water if background else grid[index]
                result.alpha_composite(tile(code),(x*16-ox%16,y*16-oy%16))
    result.alpha_composite(hero,(160,128))
    return result



def clock_case(blob, plane, poses, clips, name, x=86, y=85, counter=1, keys=(), stallion=False):
    directions = {0x1000: 0, 0x2000: 1, 0x4000: 2, 0x8000: 3}
    deltas = ((0, -1), (1, 0), (0, 1), (-1, 0))
    direction_clips = [M.mword(0x8016F33C + 4 * i) for i in range(4)]
    threshold, = struct.unpack_from('<H', blob, plane['d_off'] + 4)
    speed = (M.mword(0x80127C04 if stallion else 0x80127C00) & 0xFFFF)
    period = M.mword(0x80126BE0) & 0xFFFF
    cells = list(plane['codes'])
    steps = []
    camera_x, camera_y = x, y
    ox, oy = camera_x * 16, camera_y * 16
    clip = frame = remaining = travel = 0
    heading = 1
    water = 10
    ticks = clips[clip][frame]['ticks']
    clock = counter

    for index, key in enumerate(keys):
        sprite_updates = 0
        if remaining == 0:
            sprite_updates += 1
            if key:
                heading = directions[key]
                dx, dy = deltas[heading]
                camera_x += dx
                camera_y += dy
                assert 0 <= camera_x <= 140 and 0 <= camera_y <= 105
                target = cells[(camera_y + 8) * 160 + camera_x + 10]
                assert target >= threshold, (name, camera_x, camera_y, target)
                remaining = 16 // speed
                if clip != direction_clips[heading]:
                    clip, frame = direction_clips[heading], 0
                    ticks = clips[clip][frame]['ticks']
        if remaining:
            dx, dy = deltas[heading]
            ox, oy = ox + dx * speed, oy + dy * speed
            remaining -= 1
            travel += int(remaining == 0)
            sprite_updates += 1
        for _ in range(sprite_updates):
            ticks -= 1
            if ticks == 0:
                frame = (frame + 1) % len(clips[clip])
                ticks = clips[clip][frame]['ticks']
        clock = (clock + 1) & 0xFFFFFFFF
        if clock % period == 0:
            water = 20 if water == 10 else 10
            # The water update walks linear map cells. Viewport reads wrap.
            for row in range(camera_y, camera_y + 15):
                for cell in range(row * 160 + camera_x, row * 160 + camera_x + 20):
                    if cell >= len(cells):
                        continue
                    tile = cells[cell]
                    if 1 <= tile <= 20:
                        cells[cell] = tile + 10 if tile <= 10 else tile - 10
        row = dict(key=key, camera=dict(x=camera_x, y=camera_y), origin=dict(x=ox, y=oy), heading=heading,
                   remaining=remaining, travel_counter=travel, clip=clip, frame=frame, ticks=ticks,
                   counter=clock, water=water, cells_sha256=None, pixels_sha256=None)
        if index in (0, 28, 29, 58, 59, len(keys) - 1):
            row['cells_sha256'] = hashlib.sha256(struct.pack('<19200H', *cells)).hexdigest()
            pose = poses[clips[clip][frame]['pose']][0].crop((0, 0, 16, 16))
            image = source_viewport(blob, plane, pose, cells, ox, oy, water)
            row['pixels_sha256'] = hashlib.sha256(image.tobytes()).hexdigest()
        steps.append(row)
    return dict(name=name, x=x, y=y, counter=counter, speed=speed, steps=steps)


def verify_source():
    for start, end, digest in (
        (0x800C3EF0, 0x800C4244, '5ddfb20c08720d5b249fd09ca34a57555969ff037262fabf476d341339867f68'),
        (0x800C4514, 0x800C4568, 'e111ffcf24b45d354fd8bb5db7b7f2f2446fa645d88284c2513ff9eee4fe4ad0'),
        (0x8012677C, 0x80126840, '2ec50f622b921c2e6cdee9cb157ef641d3a7701d615c4ba8a756e6d3154a80a4'),
        (0x801268CC, 0x801269A8, '6642e95ff877ead92f9d828ab4219c35facdaf73ef6d4896fd69de1c60969219'),
        (0x80126BCC, 0x80126CE8, 'c8f7c9814042cedc36825a5a43badcf8bdd9a6f7711259e8bfc6aecb1fc38bbb'),
        (0x80127114, 0x80127224, '506f5ff956ebfc408bcf697d1f25593553efd9f35c938dfa2fa092b4445b267e'),
        (0x8012731C, 0x801274E8, '0557abcf7380b83a823d6dbea7c8fc4009e5c229335e82e62d759375bd8bf287'),
        (0x801274E8, 0x80127650, '4b632a51d34ad5ca25c893d90630a987b7c04793a6628c924b3b7c26fab89fa3'),
        (0x80127650, 0x80127784, '764bce69bfa1a91e6f2b47b2b29acf02887826516193dc3f9ad4fb5fbb48d8be'),
        (0x80127AF0, 0x80127C38, '8e5a388c434bcc8f4852394f73a9c714cd34338a8269f7634e8e19486f49c43b'),
        (0x80127E9C, 0x80127F28, '7091f6e4bb36f6d6dc30f7251b65e3091b0a4c56732c2291bb1b454fdfbeafaf'),
        (0x801280C4, 0x80128150, '3626c6ab8268489c9b60decaf7cc0f39ec47bd416930419d066176e28c9dc929'),
    ):
        assert_span(start, end, digest)
    assert_main_words({
        0x8012776C: (0x0C031091,),
        0x80127460: (0x0C031091,),
        0x80126BE0: (0x3403001E,),
        0x80126C1C: (0x0C049A33,),
        0x80127C00: (0x34030001, 0x34030002, 0x0C049BE9, 0xA6030042),
    })


def verify(write=False):
    verify_source()
    data,image,proof=export.build()
    assert data==json.loads((ROOT/'game/assets/world_art_b.json').read_text())
    # Independently composed existing decoder agrees on every RGB terrain pixel.
    blob,_=source('/B_DATA.BIN');plane=W.parse_worldmap(blob)
    for tile,rect in enumerate(data['tiles']):
        a,t,p=W.tile_of(plane,tile);rgb=W.tile_pixels(plane,a,t,p)
        pixels=image.crop((rect['x'],rect['y'],rect['x']+16,rect['y']+16))
        assert pixels.convert('RGB').tobytes()==b''.join(bytes(pixel) for row in rgb for pixel in row)
        for y in range(16):
            for x in range(16):
                native_index=plane['pages'][a][(t//8*16+y)*128+t%8*16+x]
                word=int.from_bytes(blob[plane['clut_offsets'][p]+2*native_index:plane['clut_offsets'][p]+2*native_index+2],'little')
                assert pixels.getpixel((x,y))[3]==(255 if word else 0)
    # A second sprite decoder agrees after exact source width/height clipping.
    from export_battle_trial import section_art
    poses, _, _ = section_art(blob, proof['foot']['section'], 0x80080000)
    for i,rect in enumerate(data['poses']):
        assert poses[i][0].crop((0,0,16,16)).tobytes()==image.crop((rect['x'],rect['y'],rect['x']+16,rect['y']+16)).tobytes()

    # Region C uses its own map and foot assets.
    regional, regional_image, regional_proof = export.build('c')
    assert regional == json.loads((ROOT / 'game/assets/world_art_c.json').read_text())
    regional_blob, _ = source('/C_DATA.BIN')
    regional_poses, _, _ = section_art(regional_blob, regional_proof['foot']['section'], 0x80080000)
    for i, rect in enumerate(regional['poses']):
        bounds = rect['x'], rect['y'], rect['x'] + 16, rect['y'] + 16
        assert regional_poses[i][0].crop((0, 0, 16, 16)).tobytes() == regional_image.crop(bounds).tobytes()

    cases = [
        clock_case(blob, plane, poses, data['clips'], 'walk_and_idle', keys=[0]*8+[0x4000]*80+[0]*32),
        clock_case(blob, plane, poses, data['clips'], 'north_entry', keys=[0x1000]),
        clock_case(blob, plane, poses, data['clips'], 'east', keys=[0x2000]*16),
        clock_case(blob, plane, poses, data['clips'], 'west', keys=[0x8000]*16),
        clock_case(blob, plane, poses, data['clips'], 'wrap_seam', x=63, y=107, counter=29, keys=[0]),
        clock_case(blob, plane, poses, data['clips'], 'counter_wrap', counter=0xFFFFFFFF, keys=[0]),
        clock_case(blob, plane, poses, data['clips'], 'stallion_walk_and_idle', keys=[0]*8+[0x4000]*40+[0]*16, stallion=True),
        clock_case(blob, plane, poses, data['clips'], 'stallion_north_entry', keys=[0x1000], stallion=True),
        clock_case(blob, plane, poses, data['clips'], 'stallion_east', keys=[0x2000]*8, stallion=True),
        clock_case(blob, plane, poses, data['clips'], 'stallion_west', keys=[0x8000]*8, stallion=True),
    ]
    path=ROOT/'game/tests/fixtures/world_visual_steps.json'
    if write:path.write_text(json.dumps(cases,separators=(',',':'))+'\n')
    else:assert cases==json.loads(path.read_text())
    if write:
        with tempfile.TemporaryDirectory(prefix='suikoden-world-art-') as temporary:
            one=Path(temporary)/'one';two=Path(temporary)/'two';export.export(one);export.export(two)
            for name in ('world.png','scene.json','provenance.json'):assert (one/name).read_bytes()==(two/name).read_bytes()
    print(f'PASS:320 terrain tiles/alpha masks,36 world Hero poses, exact source sprite extent and{sum(len(c["steps"]) for c in cases)} complete source movement/animation/water frames; no native device')


def verify_runtime():
    import subprocess
    result=subprocess.run([str(ROOT/'game/zig-out/bin/suikoden-journey'),'--check-world',str(ROOT/'kit/work/build/world-travel-art'),str(ROOT/'game/tests/fixtures/world_visual_steps.json')],capture_output=True,text=True,check=True)
    cases=json.loads((ROOT/'game/tests/fixtures/world_visual_steps.json').read_text())
    expected={(case['name'],i):step['pixels_sha256'] for case in cases for i,step in enumerate(case['steps']) if step['pixels_sha256']}
    actual=[json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
    assert len(actual)==len(expected)==24
    for row in actual:assert row['sha256']==expected[(row['case'],row['step'])],row
    with tempfile.TemporaryDirectory(prefix='suikoden-world-invalid-') as temporary:
        broken=Path(temporary)
        data=json.loads((ROOT/'game/assets/world_art_b.json').read_text());data['schema']='future'
        (broken/'scene.json').write_text(json.dumps(data))
        failure=subprocess.run([str(ROOT/'game/zig-out/bin/suikoden-journey'),'--check-world',str(broken),str(ROOT/'game/tests/fixtures/world_visual_steps.json')],capture_output=True,text=True)
        assert failure.returncode!=0 and 'UnsupportedWorldArt' in failure.stderr
        print('PASS:24 native-binary CPU pixel buffers match independent source composition byte-for-byte; no graphics/audio initialization')


if __name__=='__main__':
    verify('--write-fixtures' in sys.argv)
    if '--check-runtime' in sys.argv:verify_runtime()

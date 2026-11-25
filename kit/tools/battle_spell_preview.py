#!/usr/bin/env python3
"""Export the scene library and render a ready program or explicit startup diagnostic without a window."""
import argparse
import hashlib
from html import escape
import json
import os
from pathlib import Path
import shutil
import subprocess
from PIL import Image,ImageDraw

from export_spell_scenes import ROOT,export
from spell_scene_player import Player
from battle_drops_preview import Preview


def review_packet(packet,spell,diagnostic=False):
    if not diagnostic:return packet,None
    from spell_scene_soul import shadow_fixture,hell_fixture
    build={'spell_26':shadow_fixture,'spell_27':hell_fixture}.get(spell)
    if build is None:raise ValueError('initialized-state diagnostics are available only for spell_26 and spell_27')
    fixture=build(packet)
    return fixture['packet'],dict(status=fixture['status'],startup=fixture['startup'])


def render_preview(packet,native,spell,output,knockouts=False,diagnostic=None):
    atlas=Image.open(native/packet['atlas']).convert('RGBA')
    content=json.loads((native/'trial.json').read_text())
    party=[dict(position=[p[k] for k in 'xyz']) for p in content['party_positions']]
    player=Player(packet,spell,atlas,party=party)
    scene=Preview(native,player,knockouts=knockouts);impact=player.program['impact'];last=player.program['duration']
    if knockouts and not scene.instant_knockout:
        reaction=player.program.get('reaction');start=max(impact,reaction['start']+reaction.get('release',len(reaction['offsets'])) if reaction else 0)
        last=max(last,start+94)
    samples=sorted(set((0,1,32,64,65,95,96,97,160,161,192,225,234,246,impact-1,impact)))
    samples+= [event['at'] for event in player.program['cameras']]+[o.get('start',0) for o in player.program['objects']]+[last-1,last]
    samples=[n for n in samples if n<=last]
    if reaction:=player.program.get('reaction'):samples=sorted(set(samples+[reaction['start']+n for n in (0,2,7,12,17,22,27,32,36)]))
    sequence=output/'frames';sequence.mkdir(parents=True,exist_ok=True)
    if diagnostic:
        (output/'diagnostic.json').write_text(json.dumps(dict(**diagnostic,packet=packet),separators=(',',':'))+'\n')
    elif (output/'diagnostic.json').exists():(output/'diagnostic.json').unlink()
    frames=[];contact=[];timing=[]
    for update in sorted(set(range(0,last+1,3))|set(samples)|{impact,last}):
        image=scene.render(update)
        if diagnostic:
            draw=ImageDraw.Draw(image);draw.rectangle((0,0,640,25),fill=(28,12,8))
            draw.text((8,8),'Diagnostic startup assumptions; canonical import and native pixel review pending',fill=(255,215,128))
        timing.append(dict(update=update,draw_count=player.draw_count,camera=scene.last_frame['camera'],commands=len(scene.last_frame['commands'])))
        if update%3==0 or update==last:
            image.save(sequence/f'frame_{len(frames):04d}.png');frames.append(image)
        if update in samples:
            image.save(output/f'update_{update:03d}.png');labeled=image.copy();ImageDraw.Draw(labeled).text((435,12),f'Update {update:03d}',fill=(255,210,100));contact.append(labeled)
        if update%30==0:print(f"{player.spell['name']} {update}/{last}",flush=True)
    for stale in sequence.glob('frame_[0-9][0-9][0-9][0-9].png'):
        if int(stale.stem[-4:])>=len(frames):stale.unlink()
    for stale in output.glob('update_*.png'):
        suffix=stale.stem.removeprefix('update_')
        if suffix.isdecimal() and int(suffix) not in samples:stale.unlink()
    timeline=[frames[0]]*10+frames+[frames[-1]]*20
    timeline[0].save(output/'preview.gif',save_all=True,append_images=timeline[1:],duration=50,loop=0,optimize=False)
    if encoder:=shutil.which('ffmpeg'):
        subprocess.run([encoder,'-hide_banner','-loglevel','error','-y','-framerate','20','-i',str(sequence/'frame_%04d.png'),'-vf','tpad=start_mode=clone:start_duration=0.5:stop_mode=clone:stop_duration=1','-c:v','libx264','-crf','14','-pix_fmt','yuv420p','-movflags','+faststart',str(output/f'{spell}_preview.mp4')],check=True)
        shutil.copyfile(output/f'{spell}_preview.mp4',output/'preview.mp4')
    sheet=Image.new('RGB',(640*3,480*((len(contact)+2)//3)))
    for i,image in enumerate(contact):sheet.paste(image,((i%3)*640,(i//3)*480))
    sheet.save(output/'contact_sheet.png')
    (output/'timeline.json').write_text(json.dumps(dict(spell=spell,callback_updates=last,impact_update=impact,playback_hz=60,initial_seed=17,frames=timing),indent=2)+'\n')
    manifest=dict(schema='suikoden-spell-review/1',status=diagnostic['status'] if diagnostic else 'candidate',startup=diagnostic['startup'] if diagnostic else None,spell=spell,source_provenance=dict(path=os.path.relpath(native/'provenance.json',output),sha256=hashlib.sha256((native/'provenance.json').read_bytes()).hexdigest()),scenario='forced recipient KO presentation; no damage formula simulation' if knockouts else 'VFX only; no damage formula simulation',files={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in output.iterdir() if p.is_file() and p.name!='manifest.json'})
    (output/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(output/f'{spell}_preview.mp4')

    return manifest


def write_review_page(report,output):
    cards=[]
    for row in report['spells']:
        title=escape(f"{row['id']} · {row['name']}")
        if row['status']=='blocked':
            body=f'<p>Blocked: {escape(json.dumps(row["blocker"]))}</p>'
        else:
            manifest=json.loads((output/row['manifest']).read_text())
            folder=Path(row['manifest']).parent
            video=f'{row["id"]}_preview.mp4'
            if video in manifest['files']:
                body=f'<video controls preload="none" aria-label="{title}" src="{escape((folder/video).as_posix(),quote=True)}"></video>'
            else:
                body=f'<a href="{escape((folder/"preview.gif").as_posix(),quote=True)}">Open animated preview</a>'
            body+=f'<p>{escape(manifest["scenario"])}</p>'
            if row['status']=='diagnostic_not_qualified':
                body+='<p>Explicit startup assumptions; this capture does not establish original allocation state.</p>'
            body+=f'<a href="{escape(row["manifest"],quote=True)}">Evidence manifest</a>'
        cards.append(f'<article id="{escape(row["id"],quote=True)}"><h2>{title}</h2><p>{escape(row["status"])}</p>{body}</article>')
    (output/'index.html').write_text('<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
        '<title>Suikoden spell scene review</title><style>body{background:#101522;color:#edf1ff;font:16px system-ui;margin:24px}a{color:#9bd8ff}'
        'main{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,640px),1fr));gap:24px}article{background:#1b2334;padding:16px}'
        'video{width:100%;max-width:640px}h2{font-size:20px}p{line-height:1.5}</style><h1>Spell scene review</h1>'
        f'<p>{report["canonical_programs"]}/{len(report["spells"])} qualified programs. Candidate videos still require visual acceptance. '
        'Clips use seed 17, source timing and review padding. No audio is included.</p><main>'+''.join(cards)+'</main></html>')


def batch_reviews(packet,native,output,knockouts=False,diagnostics=False):
    rows=[]
    for spell in packet['spells']:
        diagnostic=diagnostics and spell['program'] is None and spell['id'] in ('spell_26','spell_27')
        row=dict(id=spell['id'],name=spell['name'])
        if spell['program'] is None and not diagnostic:
            rows.append(dict(**row,status='blocked',blocker=spell['blocker']))
            continue
        selected,metadata=review_packet(packet,spell['id'],diagnostic)
        manifest=render_preview(selected,native,spell['id'],output/spell['id'],knockouts,metadata)
        path=output/spell['id']/'manifest.json'
        rows.append(dict(**row,status=manifest['status'],manifest=str(path.relative_to(output)),sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
    report=dict(schema='suikoden-spell-review-batch/1',canonical_programs=sum(s['program'] is not None for s in packet['spells']),spells=rows)
    (output/'index.json').write_text(json.dumps(report,indent=2)+'\n')
    write_review_page(report,output)
    return report


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    selection=parser.add_mutually_exclusive_group()
    selection.add_argument('--spell')
    selection.add_argument('--all',action='store_true',help='export once and generate every qualified scene preview with a complete blocker index')
    parser.add_argument('--knockouts',action='store_true',help='presentation test: force all spell recipients down at impact')
    parser.add_argument('--diagnostic',action='store_true',help='include explicit-startup Black Shadow/Hell reviews; never enables canonical import')
    parser.add_argument('--package',type=Path,default=ROOT/'kit/work/build/canonical/battle')
    parser.add_argument('--out',type=Path)
    args=parser.parse_args()
    output=args.out or ROOT/'kit/work/build/battle_review/spell_library'/('batch' if args.all else 'flaming_arrows')
    native=output/'native';packet=export(args.package,native)
    if args.all:
        batch_reviews(packet,native,output,args.knockouts,args.diagnostic)
        print(output/'index.html')
    else:
        spell=args.spell or 'spell_1'
        try:packet,diagnostic=review_packet(packet,spell,args.diagnostic)
        except ValueError as exc:parser.error(str(exc))
        render_preview(packet,native,spell,output,args.knockouts,diagnostic)


if __name__=='__main__':main()

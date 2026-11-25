#!/usr/bin/env python3
# Full boot -> load end-game save (Erian) -> wait for area to be LIVE (animating)
# -> F1 save. Prints state path at the end.
import time, sys, subprocess, os
import Xlib.display, Xlib.X, Xlib.XK
from Xlib.ext import xtest
from PIL import Image, ImageChops

APPRUN = os.path.expanduser('~/workspace/tools/pcsx-redux/b290/squashfs-root/AppRun')
ISO = os.path.expanduser('~/workspace/suikoden/Suikoden (v1.1).cue')
BIOS = os.path.expanduser('~/workspace/suikoden/SCPH1001.BIN')

def launch():
    env = dict(os.environ); env['DISPLAY'] = ':99'
    p = subprocess.Popen([APPRUN, '-interpreter', '-iso', ISO, '-bios', BIOS, '-run'],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env)
    print("launched pid", p.pid, flush=True)
    return p

def getd():
    d = Xlib.display.Display(':99')
    root = d.screen().root
    def rec(w):
        wins=[w]
        for c in w.query_tree().children: wins += rec(c)
        return wins
    for w in rec(root):
        try:
            nm = w.get_wm_name()
            if nm and ('pcsx' in nm.lower() or 'redux' in nm.lower()):
                return d, w
        except: pass
    return d, None

def key(d, name, hold=0.15):
    kc = d.keysym_to_keycode(Xlib.XK.string_to_keysym(name))
    xtest.fake_input(d, Xlib.X.KeyPress, kc); d.sync(); time.sleep(hold)
    xtest.fake_input(d, Xlib.X.KeyRelease, kc); d.sync()

def snap(d, root, path='/tmp/boot.png'):
    img = root.get_image(0,0,1024,768,Xlib.X.ZPixmap,0xffffffff)
    im = Image.frombytes("RGB",(1024,768),img.data,"raw","BGRX")
    im.save(path); return im

def changed(a, b):
    import numpy as np
    arr = np.array(ImageChops.difference(a,b))
    return int((arr.sum(axis=2)>0).sum())

def main():
    launch()
    time.sleep(6)
    d, w = getd()
    root = d.screen().root
    # dismiss update dialog
    key(d,'Tab'); time.sleep(0.3); key(d,'Tab'); time.sleep(0.3); key(d,'Return')
    print("dialog dismissed", flush=True)
    # wait for boot to title (~long). poll for frame animation to detect title
    time.sleep(45)
    snap(d,root,'/tmp/boot1.png')
    # mash Enter to skip FMV / get to title
    for i in range(6):
        key(d,'Return'); time.sleep(4)
    snap(d,root,'/tmp/boot2.png')
    print("at/near title", flush=True)
    # title -> START
    key(d,'Return'); time.sleep(3)
    # menu: Down to Continue, x confirm
    key(d,'Down'); time.sleep(1)
    key(d,'x'); time.sleep(6)
    snap(d,root,'/tmp/savelist.png')
    print("save list?", flush=True)
    # select Erian (first), confirm twice
    key(d,'x'); time.sleep(3)
    key(d,'x'); time.sleep(3)
    snap(d,root,'/tmp/loadstart.png')
    print("loading...", flush=True)
    # wait for load to complete: poll until frames animate for a while
    live = False
    for i in range(40):
        time.sleep(5)
        a = snap(d,root,'/tmp/a.png'); time.sleep(1.0); b = snap(d,root,'/tmp/b.png')
        n = changed(a,b)
        print(f"poll {i}: changed={n}", flush=True)
        if n > 50:
            live = True
            break
    snap(d,root,'/tmp/live.png')
    if not live:
        print("WARNING: area never started animating", flush=True)
    else:
        print("AREA IS LIVE", flush=True)
    # F1 save
    key(d,'F1'); time.sleep(3)
    src = os.path.expanduser('~/.config/pcsx-redux/SLUS00292.sstate0')
    dst = '/tmp/greg_live.sstate0'
    import shutil
    shutil.copy(src, dst)
    print("saved", dst, os.path.getsize(dst), flush=True)

main()

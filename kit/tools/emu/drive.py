#!/usr/bin/env python3
# Drive the emulator: hold a d-pad direction, then screenshot.
# usage: drive.py <up|down|left|right> [seconds] [outfile]
import sys, time
import Xlib.display, Xlib.X, Xlib.XK
from Xlib.ext import xtest
from PIL import Image

DIRS = {'up':'Up','down':'Down','left':'Left','right':'Right'}
def main():
    direction = sys.argv[1]
    seconds = float(sys.argv[2]) if len(sys.argv)>2 else 1.0
    out = sys.argv[3] if len(sys.argv)>3 else '/tmp/drive.png'
    keysym = Xlib.XK.string_to_keysym(DIRS[direction])
    d = Xlib.display.Display(':99')
    keycode = d.keysym_to_keycode(keysym)
    root = d.screen().root
    # focus the pcsx window first
    def rec(w):
        wins=[w]
        for c in w.query_tree().children: wins += rec(c)
        return wins
    for w in rec(root):
        try:
            nm = w.get_wm_name()
            if nm and ('pcsx' in nm.lower() or 'redux' in nm.lower()):
                w.raise_window(); d.sync(); break
        except: pass
    time.sleep(0.2)
    xtest.fake_input(d, Xlib.X.KeyPress, keycode); d.sync()
    time.sleep(seconds)
    xtest.fake_input(d, Xlib.X.KeyRelease, keycode); d.sync()
    time.sleep(0.3)
    img = root.get_image(0,0,1024,768,Xlib.X.ZPixmap,0xffffffff)
    im = Image.frombytes("RGB",(1024,768),img.data,"raw","BGRX")
    im.save(out)
    print("saved", out)
main()

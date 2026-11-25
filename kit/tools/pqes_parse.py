#!/usr/bin/env python3
"""
pQES sequence parser — Suikoden SEQ.BIN.

Reverse-engineered from MAIN.EXE static disassembly (seq_stream_interpreter
@0x8015B70C, seq_noteon_stream_advance @0x8015D3BC, 2026-10-01):

Event format (event-first, NOT MIDI delta-first):
  [status 0x80-0xFF][params][delta]
  - 0x9n: note on, 2 params (note, vel). vel 0 = note off.
  - 0xBn: control change, 1 param (controller).
  - 0xCn: program change, 1 param (program).
  - 0xEn: pitch bend, 2 params.
  - 0xF0: system/meta (handler @0x8015D068).
  - 0xFF: meta event (FF <type> <len> <data>), e.g. FF 51 = tempo.
  Running status IS supported (last command cached; a byte <0x80 reuses it).
  Delta: byte 0 = wait 0; bit7 clear = single-byte delta; bit7 set = VLQ
  ((b&0x7f)<<7 | next). Stored per-channel; 0 means "more events now".

Container: 'pQES\\0\\0\\0\\x01' magic, then id->index table (c0..),
then (id,bank,patch,00) program table (b0..), then events.
SEQ.BIN holds 4 concatenated pQES songs (headers at 0, 15812, 34352, 44438).

Usage: python3 pqes_parse.py SEQ.BIN
"""
import struct, sys

def parse_events(ev):
    """Returns (notes, total_ticks, error). notes = [(tick,ch,note,vel),...]."""
    notes=[]; i=0; tick=0; last_cmd=None; err="ok"
    while i < len(ev):
        b=ev[i]
        if b==0xFF:
            if i+2>=len(ev): err="trunc meta"; break
            i+=3+ev[i+2]; last_cmd=None; continue
        if b<0x80:
            if last_cmd is None: err=f"data w/o status at {i}"; break
            b=last_cmd
        else:
            last_cmd=b; i+=1
        nib=b>>4; ch=b&0x0F
        if nib==0x9:
            if i+2>len(ev): err="trunc"; break
            note,vel=ev[i],ev[i+1]; i+=2
            delta=ev[i]; i+=1
            if delta&0x80:
                if i>=len(ev): err="trunc"; break
                delta=(delta&0x7F)<<7|ev[i]; i+=1
            notes.append((tick,ch,note,vel)); tick+=delta
        elif nib==0xB or nib==0xC:
            i+=1  # 1 param
            if i>=len(ev): err="trunc"; break
            delta=ev[i]; i+=1
            if delta&0x80:
                delta=(delta&0x7F)<<7|ev[i]; i+=1
            tick+=delta
        elif nib==0xE:
            i+=2  # 2 params
            if i>=len(ev): err="trunc"; break
            delta=ev[i]; i+=1
            if delta&0x80:
                delta=(delta&0x7F)<<7|ev[i]; i+=1
            tick+=delta
        else:
            err=f"unknown cmd {b:02X} at {i}"; break
    return notes,tick,err

def find_songs(data):
    """Find pQES headers. Returns list of (offset, next_offset)."""
    offs=[]; i=0
    while True:
        i=data.find(b'pQES\x00\x00\x00\x01', i)
        if i<0: break
        offs.append(i); i+=1
    offs.append(len(data))
    return [(offs[j],offs[j+1]) for j in range(len(offs)-1)]

def find_event_start(data, song_off):
    """Scan for first 0x90-0x9F with sane params after the tables."""
    for off in range(song_off+0x80, song_off+0x400):
        if 0x90<=data[off]<=0x9F and data[off+1]<0x80 and data[off+2]<0x80:
            return off
    return None

if __name__=="__main__":
    path=sys.argv[1] if len(sys.argv)>1 else "SEQ.BIN"
    with open(path,'rb') as fh:
        data=fh.read()
    for s,(s0,s1) in enumerate(find_songs(data)):
        est=find_event_start(data,s0)
        if est is None:
            print(f"song{s}: no event start found"); continue
        notes,ticks,err=parse_events(data[est:s1])
        ons=sum(1 for n in notes if n[3]>0)
        print(f"song{s}: file+{s0}..{s1} events@{est} "
              f"notes={len(notes)} (on={ons}) ticks={ticks} err={err}")

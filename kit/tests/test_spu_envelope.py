#!/usr/bin/env python3
"""Numerical envelope and first-traversal checks, not game/emulator execution."""
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
sys.path[:0]=[str(Path(__file__).resolve().parents[1]/'tools/seq')]
from spu import Envelope, Voice, calc_vc_delta, DECAY, SUSTAIN, RELEASE
from spu_fir import FIR
import render_seq as R


class EnvelopeChecks(unittest.TestCase):
    def test_signed_fast_exponential_decay(self):
        self.assertEqual(calc_vc_delta(124,0,True,True,True,32767),(-16384,32768))
        e=Envelope(0,0);e.level=32767;e.phase=DECAY
        self.assertEqual([e.step() for _ in range(4)],[16383,8191,4095,2047])
        self.assertEqual(e.phase,SUSTAIN)

    def test_rate_signs_and_dividers(self):
        # Legal rates cannot turn a decreasing envelope into positive gain.
        for rate in range(128):
            for level in [0,1,24575,24576,32767]:
                for log in [False,True]:
                    up,ud=calc_vc_delta(127,rate,log,False,False,level)
                    down,dd=calc_vc_delta(127,rate,log,True,True,level)
                    self.assertGreaterEqual(up,0)
                    self.assertLessEqual(down,0)
                    self.assertTrue(0<=ud<=32768 and 0<=dd<=32768)

    def test_release_mode_bit_five(self):
        self.assertTrue(Envelope(0,0x20).release_exp)
        self.assertFalse(Envelope(0,0x2000).release_exp)
        self.assertTrue(Envelope(0,0x2020).release_exp)

    def test_linear_and_exponential_release_differ(self):
        linear,exp=Envelope(0,0),Envelope(0,0x20)
        for e in [linear,exp]:e.level=32767;e.key_off()
        self.assertEqual([linear.step() for _ in range(2)],[16383,0])
        self.assertEqual([exp.step() for _ in range(2)],[16383,8191])


class VoiceChecks(unittest.TestCase):
    def voice(self,samples,ls=56,le=84,repeats=True):
        v=Voice(samples,ls,le,repeats,1.0,0,0)
        v.env.phase=SUSTAIN;v.env.level=32767
        # Rate127 sustains the chosen level indefinitely.
        v.env.sustain_rate=127;v.env.sustain_dec=False
        return v

    def render(self,v,n,start=0,output=None):
        out=output if output is not None else [0.0]*(start+n)
        v.render(FIR,out,[0.0]*len(out),start,n,44100)
        return out

    def test_attack_is_not_replaced_by_sustain(self):
        out=self.render(self.voice([10000]*56+[0]*56),40)
        self.assertTrue(any(out))

    def test_poisoned_attack_only_changes_first_traversal(self):
        plain=[10000]*56+[1000]*56;changed=[-10000]*56+[1000]*56
        a=self.render(self.voice(plain),230);b=self.render(self.voice(changed),230)
        self.assertNotEqual(a[:56],b[:56])
        self.assertEqual(a[116:],b[116:])

    def test_chunked_render_keeps_loop_history(self):
        samples=list(range(112));a=self.render(self.voice(samples),240)
        v=self.voice(samples);b=[0.0]*240
        self.render(v,112,output=b);self.render(v,128,start=112,output=b)
        self.assertEqual(a,b)

    def test_one_block_loop_is_valid(self):
        v=self.voice([1000]*28,ls=0,le=0)
        self.render(v,100)
        self.assertTrue(v.active and v.looped)
        self.assertEqual(v.pos,16.0)

    def test_nonrepeat_end_mutes_and_stays_inactive(self):
        v=self.voice([1000]*112,repeats=False)
        out=self.render(v,140)
        self.assertEqual(out[112:],[0.0]*28)
        self.assertFalse(v.active)
        self.assertEqual(v.env.level,0)
        self.assertEqual(self.render(v,10),[0.0]*10)

    def test_note_off_reaches_rendered_release(self):
        v=self.voice([1000]*112)
        self.render(v,20);v.env.key_off()
        out=self.render(v,20)
        self.assertTrue(any(out));self.assertFalse(v.active)

    def test_static_volume_preserves_negative_low_level_samples(self):
        from math import floor
        full=self.render(self.voice([-1000]*112),20)
        quiet=self.voice([-1000]*112);quiet.vol_l=1/16384
        actual=self.render(quiet,20)
        self.assertEqual(actual,[floor(value/16384) for value in full])
        self.assertIn(-1,actual)

    def test_send_buffers_receive_the_same_post_pan_samples(self):
        v=self.voice([-1000]*112);v.vol_l=1/16384;v.vol_r=0.5
        left=[0.0]*40;right=[0.0]*40;send=([0]*20,[0]*20)
        v.render(FIR,left,right,10,20,44100,send=send)
        self.assertEqual(send[0],left[10:30]);self.assertEqual(send[1],right[10:30])
        self.assertIn(-1,send[0])

    def test_renderer_issues_one_keyoff_at_gate(self):
        calls=[];steps=[]
        class Env:
            level=32767
            release_rate=0
            released=False
            def key_on(self):pass
            def key_off(self):calls.append('off');self.released=True
        class RecordingVoice:
            def __init__(self,*args):steps.append(args[4]);self.env=Env();self.active=True
            def render(self,fir,l,r,start,n,sr):
                calls.append((start,n))
                if self.env.released:self.active=False
                return n
        tone=dict(min=0,max=127,center=60,shift=124,vag=0,vol=127,pan=64,prior=15,bank_vol=127,program_vol=127,program_pan=64,adsr1=0,adsr2=0,mode=0)
        notes=[(0,60,127,0,480,0)]
        parsed=(notes,[(0,120)],480,120,dict(notes=1,tempo_changes=0,last_tick=480,event_ticks=[0,480],voice_events=[(0,9,0,60,127),(480,9,0,60,0)]))
        with patch.object(R,'parse_track',return_value=parsed),patch('spu.Voice',RecordingVoice):
            R.render_song(0,b'',{'ORCH':([[1]*28],[[tone]],[(0,0,False)])},None,write=False)
        self.assertEqual(calls,[(735*i,735) for i in range(1,30)]+['off',(22050,735)])
        # Native event update29 stages the off; update30 flushes it.
        self.assertEqual(steps,[R.pitch_register(60,60,124)/4096.0])
        self.assertGreater(steps[0],1.0)

    def test_renderer_layers_matching_tones_without_nearest_fallback(self):
        selected=[];loop_args=[]
        class Env:
            level=32767
            release_rate=0
            released=False
            def key_on(self):pass
            def key_off(self):self.released=True
        class RecordingVoice:
            def __init__(self,samples,*args):
                selected.append(samples[0]);loop_args.append(args[:3]);self.env=Env();self.active=True
            def render(self,*args):
                if self.env.released:self.active=False
                return 1
        base=dict(center=60,shift=0,vol=127,pan=64,prior=15,bank_vol=127,program_vol=127,program_pan=64,adsr1=0,adsr2=0,mode=0)
        tones=[dict(base,min=60,max=72,vag=0),dict(base,min=66,max=84,vag=1)]
        notes=[(0,67,127,0,480,0),(480,100,127,0,480,0)]
        parsed=(notes,[(0,120)],480,120,dict(notes=2,tempo_changes=0,last_tick=480,event_ticks=[0,480,480,480],voice_events=[(0,9,0,67,127),(480,9,0,67,0),(480,9,0,100,127),(480,9,0,100,0)]))
        bank=([[1000]*28,[2000]*28],[tones],[(0,0,True),(0,0,False)])
        with patch.object(R,'parse_track',return_value=parsed),patch('spu.Voice',RecordingVoice):
            R.render_song(0,b'',{'ORCH':bank},None,write=False)
        self.assertEqual(selected,[1000,2000])
        self.assertEqual(loop_args,[(0,0,True),(0,0,False)])


if __name__=='__main__':unittest.main(verbosity=2)

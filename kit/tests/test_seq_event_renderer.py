#!/usr/bin/env python3
"""Ordered event playback edges; native arithmetic/allocation have separate gates."""
from fractions import Fraction
from pathlib import Path
import tempfile
import sys
import unittest
import wave
from unittest.mock import patch
sys.path[:0]=[str(Path(__file__).resolve().parents[1]/'tools/seq')]
import render_seq as R
from spu import voice_levels


def tone(**changes):
    value=dict(min=0,max=127,center=60,shift=0,vag=0,vol=127,pan=64,prior=15,
               bank_vol=127,program_vol=127,program_pan=64,adsr1=0,adsr2=0,pbmin=2,pbmax=2,mode=0)
    value.update(changes);return value


class Events(unittest.TestCase):
    def synth(self,events,programs=None,end=10,sr=60):
        made=[]
        class RecordingVoice:
            def __init__(self,samples,ls,le,repeat,step,*args):
                self.sample=samples[0];self.step=step;self.active=True;self.chunks=[];self.offs=[];self.chunk_key=None
                parent=self
                class Env:
                    level=32767
                    release_rate=0
                    def key_on(self):pass
                    def key_off(self):parent.offs.append(parent.chunks[-1][0]+parent.chunks[-1][1] if parent.chunks else 0)
                self.env=Env();made.append(self)
            def render(self,fir,left,right,start,n,sr):
                key=(self.vol_l,self.vol_r,self.step,bool(self.offs))
                if self.chunks and self.chunk_key==key and sum(self.chunks[-1][:2])==start:
                    row=self.chunks[-1];self.chunks[-1]=(row[0],row[1]+n,*row[2:])
                else:self.chunks.append((start,n,*key[:3]))
                self.chunk_key=key
                if self.offs:self.active=False
                return n
        bank=([[1000]*28,[2000]*28],programs or [[tone()]],[(0,0,True),(0,0,True)])
        with patch.object(R,'SR',sr),patch('spu.Voice',RecordingVoice):
            output=R.render_events(events,*bank,lambda t:Fraction(t,60),end)
        return made,output

    def test_live_pan_and_bend_wait_for_next_flush(self):
        events=[(0,11,0,7,64),(0,11,0,10,0),(0,9,0,60,100),
                (5,11,0,10,127),(7,14,0,99,127),(10,9,0,60,0)]
        made,_=self.synth(events);v,=made
        self.assertEqual([(r[0],r[1]) for r in v.chunks],[(1,5),(6,2),(8,3),(11,1)])
        self.assertEqual(v.offs,[11])
        self.assertEqual(v.chunks[0][3],0);self.assertGreater(v.chunks[0][2],0)
        self.assertEqual(v.chunks[1][2],0);self.assertGreater(v.chunks[1][3],0)
        self.assertEqual(v.chunks[0][4],1)
        self.assertEqual(v.chunks[2][4],R.bend_register(60,tone(),127)/4096)

    def test_repeated_notes_survive_until_shared_program_pitch_off(self):
        events=[(0,9,0,60,127),(1,12,1,0,None),(1,9,1,60,127),(2,9,0,60,0)]
        made,_=self.synth(events,end=2)
        self.assertEqual(len(made),2)
        self.assertEqual([v.offs for v in made],[[3],[3]])
        self.assertEqual([(r[0],r[1]) for r in made[0].chunks],[(1,2),(3,1)])

    def test_note_off_uses_current_program_and_channel_defaults_to_its_index(self):
        programs=[[tone()],[tone(vag=1)]]
        events=[(0,9,1,60,127),(1,12,1,0,None),(2,9,1,60,0)]
        made,_=self.synth(events,programs,end=4)
        self.assertEqual(made[0].sample,2000)
        self.assertEqual(made[0].offs,[5]) # program0 off cannot release program1

    def test_twenty_third_equal_priority_voice_replaces_oldest(self):
        made,output=self.synth([(0,9,0,60+i,127) for i in range(23)],end=1)
        self.assertEqual(len(made),22);self.assertEqual(output[2],23)
        self.assertTrue(all(v.chunks for v in made))
        self.assertEqual(made[0].step,R.pitch_register(82,60,0)/4096)
        self.assertNotIn(1,[v.step for v in made])

    def test_controller_update_reads_latest_shared_scratch_and_velocity(self):
        programs=[[tone(vol=127,pan=20,program_vol=80)],
                  [tone(vol=32,pan=100,program_vol=120,program_pan=90,vag=1)]]
        events=[(0,9,0,60,120),(1,9,1,65,70),(2,11,0,7,90)]
        made,_=self.synth(events,programs,end=3)
        want=voice_levels((127,70*90//127,120,32),(100,90,64),update=True)
        self.assertEqual(made[0].chunks[-2][2:4],tuple(v/16384 for v in want))
        self.assertEqual(made[1].chunks[0][2:4],made[1].chunks[1][2:4])

    def test_effective_zero_note_releases_without_creating_a_voice(self):
        made,_=self.synth([(0,9,0,60,100),(1,11,0,7,0),(2,9,0,60,80)],end=3)
        self.assertEqual(len(made),1);self.assertEqual(made[0].offs,[3])

    def test_first_note_waits_for_the_next_nominal_update(self):
        made,_=self.synth([(0,9,0,60,127)],end=2,sr=44100)
        self.assertEqual(made[0].chunks[0][0],735)
        self.assertEqual(made[0].offs,[2205])

    def test_same_update_note_off_cancels_pending_key_on(self):
        made,output=self.synth([(0,9,0,60,127),(0,8,0,60,0)],end=2)
        self.assertEqual(made,[])
        self.assertFalse(any(output[0]))

    def test_same_update_retrigger_wins_after_note_off(self):
        made,_=self.synth([(0,9,0,60,127),(0,8,0,60,0),(0,9,0,60,90)],end=2)
        self.assertEqual(len(made),1)
        self.assertEqual(made[0].chunks[0][0],1)
        self.assertEqual(made[0].offs,[3])

    def test_stolen_voice_keeps_playing_until_next_flush(self):
        events=[(0,9,0,60+i,127) for i in range(22)]+[(2,9,0,90,127)]
        made,_=self.synth(events,end=4)
        self.assertEqual(len(made),23)
        self.assertEqual(made[0].chunks[0][:2],(1,2))
        self.assertEqual(made[-1].chunks[0][0],3)

    def test_cancelled_replacement_releases_old_sample_without_restarting(self):
        programs=[[tone(adsr1=15)],[tone(vag=1,adsr1=31)]]
        events=[(0,9,0,60+i,127) for i in range(22)]
        events += [(2,9,1,90,127),(2,8,1,90,0)]
        made,_=self.synth(events,programs,end=4)
        self.assertEqual(len(made),22)
        self.assertEqual(made[0].sample,1000)
        self.assertEqual(made[0].offs,[3])
        self.assertEqual(made[0].chunks[-1][4],min(0x3FFF,R.pitch_register(90,60,0))/4096)
        self.assertEqual(made[0].env.decay_rate,4)

    def wet(self,events,mode=4,programs=None):
        from reverb import disc_preset
        sent=[]
        class IdentityNetwork:
            def __init__(self,*args):pass
            def process(self,left,right):sent.append((left,right));return left,right
        bank=([[10000]*28],programs or [[tone(mode=mode,adsr1=15)]],[(0,0,True)])
        with patch.object(R,'SR',60),patch('reverb.Reverb',IdentityNetwork):
            dry=R.render_events(events,*bank,lambda t:Fraction(t,60),5)
            wet=R.render_events(events,*bank,lambda t:Fraction(t,60),5,reverb=True)
        return dry,wet,sent

    def test_reverb_routes_post_pan_voice_samples_and_release(self):
        dry,wet,sent=self.wet([(0,9,0,60,127),(5,8,0,60,0)])
        depth=40*32767//127
        for i,(left,right) in enumerate(zip(*dry[:2])):
            self.assertEqual(sent[i],(left,right))
            self.assertEqual(wet[0][i],left+((int(left)*depth)>>15))
            self.assertEqual(wet[1][i],right+((int(right)*depth)>>15))
        self.assertTrue(any(l or r for l,r in sent[6:])) # actual release after flush
        self.assertGreater(len(wet[0]),len(dry[0]))

    def test_no_send_bit_keeps_voice_out_of_reverb(self):
        dry,wet,sent=self.wet([(0,9,0,60,127)],mode=0)
        self.assertFalse(any(l or r for l,r in sent))
        self.assertEqual(wet[0][:len(dry[0])],dry[0])
        self.assertEqual(wet[1][:len(dry[1])],dry[1])

    def test_controller91_changes_depth_at_its_event(self):
        dry,wet,sent=self.wet([(0,9,0,60,127),(3,11,0,91,0)])
        self.assertTrue(any(wet[0][i]!=dry[0][i] for i in range(3)))
        self.assertEqual(wet[0][3:len(dry[0])],dry[0][3:])
        self.assertTrue(any(l or r for l,r in sent[3:]))

    def test_cancelled_replacement_still_flushes_its_send_mask(self):
        events=[(0,9,0,60+i,127) for i in range(22)]+[(2,9,1,90,127),(2,8,1,90,0)]
        _,_,sent=self.wet(events,programs=[[tone(mode=0,adsr1=15)],[tone(mode=4,adsr1=15)]])
        self.assertFalse(any(l or r for l,r in sent[:3]))
        self.assertTrue(sent[3][0] or sent[3][1])

    def test_export_writes_stereo_and_has_no_peak_normalization(self):
        parsed=([],[(0,120)],480,120,dict(notes=0,tempo_changes=0,last_tick=0,voice_events=[],event_ticks=[]))
        rendered=([16000.0],[8000.0],0,0,0.01)
        with tempfile.TemporaryDirectory(prefix='seq-stereo-') as tmp:
            with patch.object(R,'parse_track',return_value=parsed),patch.object(R,'render_events',return_value=rendered):
                R.render_song(0,b'',{'ORCH':([],[],[])},tmp)
            with wave.open(str(Path(tmp)/'song0_v3.wav'),'rb') as w:
                self.assertEqual((w.getnchannels(),w.getsampwidth(),w.getframerate()),(2,2,44100))
                import struct
                self.assertEqual(struct.unpack('<hh',w.readframes(1)),(15999,7999))

    def test_export_uses_exact_quantized_audio_updates(self):
        for bpm,tick,update in ((115,480,31),(120,192,11),(120,352,21)):
            parsed=([],[(0,bpm)],480,bpm,dict(notes=0,tempo_changes=0,last_tick=tick,
                        voice_events=[],event_ticks=[0,tick]))
            with patch.object(R,'parse_track',return_value=parsed),patch.object(R,'render_events',return_value=([],[],0,0,0)) as render:
                R.render_song(0,b'',{'ORCH':([],[],[])},None,write=False)
            clock=render.call_args.args[4]
            self.assertEqual(clock(0),0)
            self.assertEqual(int(clock(tick)*R.SR),update*735)

    def test_score_start_levels_reach_the_event_renderer(self):
        parsed=([],[(0,120)],480,120,dict(notes=0,tempo_changes=0,last_tick=0,voice_events=[],event_ticks=[]))
        for song,bank in enumerate(('ORCH','ORCH','HNK1','HNK2')):
            with patch.object(R,'parse_track',return_value=parsed),patch.object(R,'render_events',return_value=([],[],0,0,0)) as render:
                R.render_song(song,b'',{bank:([],[],[])},None,write=False,bank=bank)
            self.assertEqual(render.call_args.kwargs['sequence'],(R.START_LEVELS[song],)*2)

    def test_unsupported_controller_fails_instead_of_silently_rendering(self):
        with self.assertRaisesRegex(ValueError,'controller'):
            self.synth([(0,11,0,0,2)])

    def test_full_release_drains_beyond_the_old_half_second_cap(self):
        from spu import Voice
        made=[]
        class CapturedVoice(Voice):
            def __init__(self,*args):super().__init__(*args);made.append(self)
        with patch('spu.Voice',CapturedVoice):
            left,right,_,_,total=R.render_events([(0,9,0,60,127)],[[10000]*28],
                [[tone(adsr1=15,adsr2=0x2D)]],[(0,0,True)],lambda t:Fraction(t,R.SR),1000)
        self.assertTrue(any(left[1000+R.SR//2:]))
        self.assertFalse(made[0].active)
        self.assertEqual(made[0].env.level,0)
        self.assertEqual(len(left),len(right))
        self.assertEqual(total,len(left)/R.SR)
        self.assertGreater(total,1)

    def test_polled_silent_voice_still_receives_the_final_preview_stop(self):
        from spu import Voice,RELEASE
        made=[]
        class BoundedVoice(Voice):
            def __init__(self,*args):super().__init__(*args);made.append(self)
            def render(self,*args,**kwargs):
                self_test.assertLess(args[3],60,'silent voice was never released at the preview stop')
                return super().render(*args,**kwargs)
        self_test=self
        with patch.object(R,'SR',60),patch('spu.Voice',BoundedVoice):
            left,_,_,_,total=R.render_events([(0,9,0,60,127)],[[10000]*28],
                [[tone(adsr1=0x7F0F)]],[(0,0,True)],lambda t:Fraction(t,60),20)
        self.assertFalse(any(left));self.assertLess(total,2)
        self.assertEqual(made[0].env.phase,RELEASE);self.assertFalse(made[0].active)

    def test_nondecaying_release_fails_instead_of_hanging_the_export(self):
        with self.assertRaisesRegex(ValueError,'non-decaying release'):
            R.render_events([(0,9,0,60,127)],[[10000]*28],
                [[tone(adsr1=15,adsr2=31)]],[(0,0,True)],lambda t:Fraction(t,R.SR),1000)

    def test_loop_rewind_preserves_held_voices_program_and_volume(self):
        header=b'pQES'+(1).to_bytes(4,'big')+(480).to_bytes(2,'big')+(500000).to_bytes(3,'big')+b'\2\2'
        stream=bytes([0,0xC0,2,0,0xB0,7,77,0,99,20,0,6,127,
                      0,0x90,60,90,4,0xB0,99,30,0,0xFF,0x2F,0])
        notes,_,_,_,stats=R.parse_track(header+stream,loop_passes=2)
        self.assertEqual([n[-1] for n in notes],[2,2])
        made,_=self.synth(stats['voice_events'],[[tone()],[],[tone(vag=1)]],stats['last_tick'])
        self.assertEqual([v.sample for v in made],[2000,2000])
        self.assertEqual([v.offs for v in made],[[9],[9]])
        self.assertEqual(made[0].chunks[0][2:4],made[1].chunks[0][2:4])


if __name__=='__main__':unittest.main(verbosity=2)

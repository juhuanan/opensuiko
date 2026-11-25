"""Second qualified source caller for the shared field Session; no copied VM."""
from pathlib import Path
import json
import sys
import unittest
import tempfile
import subprocess
import argparse
import struct

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'kit/tools'))
import export_field_scene_contexts as export
import area_scene
import maindec
from export_first_room import source
from test_field_party_queue import check_source_paths, clock, hero_vectors, select, source_clips


class Contexts(unittest.TestCase):
    def test_audience_command_28_static_source(self):
        raw,_=source('/VAA.BIN')
        self.assertEqual(raw[0x50dc9:0x50dcb],bytes.fromhex('41 49'))
        table=0x80171c2c-maindec.MBASE+2*raw[0x50dca]
        self.assertEqual(struct.unpack_from('<H',maindec.body(),table)[0],0x422)
        words={0x80139970:0x86040000,0x80139974:0x0c050910,0x80139984:0xa6220030,
               0x80142454:0x84631e22,0x80142460:0x10830015,0x80142468:0x2602fdff,
               0x80142470:0x2c420245,0x80142480:0xa4251e22,0x80142484:0x0c030c41}
        for address,expected in words.items():self.assertEqual(maindec.mword(address),expected)

    def test_current_context_exports(self):
        for name,row in zip(('vb6_field_context.json','vaa_field_context.json'),export.export()):
            self.assertEqual(row,json.loads((ROOT/'game/assets'/name).read_text()))

    def test_actual_audience_prefix_and_alignment(self):
        check_source_paths()
        raw,_=source('/VAA.BIN')
        entity=area_scene.entities(raw,area_scene.room_record(raw,2))[22]
        stream = entity['stream_offsets'][2]
        self.assertEqual(stream, 0x50D80)
        self.assertEqual(raw[stream:stream + 9], bytes.fromhex('10 3e 4e 11 80 03 11 0c 01'))
        self.assertEqual(maindec.mword(0x80171718 + 4 * raw[stream + 3]), 0x8013CE08)
        self.assertEqual(maindec.mword(0x8013CE50), 0x0C04F33C)
        anchor = dict(zip(('x', 'y'), (cell * 8 for cell in raw[stream + 1:stream + 3])))
        clips = source_clips('SHU', 8)
        rows = hero_vectors(anchor, clips, starts=((58, 76, 0),))
        aligned = rows[0]['samples'][-1]['after'].copy()
        direction = maindec.mword(0x80171B98 + 4 * raw[stream + 5])
        select(aligned, clips, direction, face_only=True)
        settled = aligned.copy()
        clock(settled, clips, int(settled['frame'] in (0, 2)))
        rows[0]['transition'] = dict(selected=aligned, emitted=aligned.copy(), after=settled)
        self.assertEqual(rows, json.loads((ROOT/'game/tests/fixtures/vaa_field_hero.json').read_text()))
        self.assertEqual(raw[entity['stream_offsets'][0]:entity['stream_offsets'][0]+4],bytes.fromhex('08 00 40 06'))


def verify_position_process(executable,temporary_root=None):
    def run(directory,phase,success=True):
        result=subprocess.run([str(executable),'--check-field-position',str(directory),phase],cwd=ROOT,capture_output=True,text=True,timeout=60)
        assert (result.returncode==0)==success,result.stdout+result.stderr
        return result
    with tempfile.TemporaryDirectory(prefix='suikoden-field-position-',dir=temporary_root) as temporary:
        directory=Path(temporary)
        first=json.loads(run(directory,'write').stdout)
        assert first==dict(arrival_construction_checkpoint=True,actor_handoff='partial_arrival_diagnostic',axis_checkpoints=2,track_checkpoint=True,future_updates_checked=3,ground='diagnostic',live_e7=False)
        assert json.loads(run(directory,'read').stdout)==first
        for filename,changes in (
            ('arrival.json',((lambda s:s.update(schema='suikoden-field-event/11',construction_ground_identity=''),'UnsupportedFieldGroundConstruction'),
                             (lambda s:s.update(ordinary_actors=None),'UnsupportedFieldGroundConstruction'),
                             (lambda s:s['ordinary_actors']['slots'][0]['avatar']['motion'].update(x=24),'InvalidFieldActorState'))),
            ('axis-x.json',((lambda s:s['ordinary_actors']['slots'][0]['avatar']['motion'].update(x=24),'InvalidFieldActorState'),
                            (lambda s:s['position_history'].update(instance=10),'InvalidFieldActorPositionHistory'))),
            ('axis-y.json',((lambda s:s['position_history'].update(x_batch=2),'InvalidFieldActorPositionHistory'),
                            (lambda s:s['instance']['execution'].update(pc=3),'InvalidFieldActorPositionHistory'),
                            (lambda s:s['position_history'].update(support_identity='forged'),'InvalidFieldActorPositionHistory'))),
            ('track.json',((lambda s:s.update(ordinary_track=None),'InvalidFieldActorPositionHistory'),))):
            path=directory/filename;saved=path.read_bytes()
            for change,expected in changes:
                invalid=json.loads(saved);change(invalid['session']);path.write_text(json.dumps(invalid))
                failure=run(directory,'read',False)
                assert expected in failure.stderr,(filename,expected,failure.stderr)
            path.write_bytes(saved)
        assert json.loads(run(directory,'read').stdout)==first
        return dict(fresh_process_arrival_construction_restart=True,fresh_process_position_restart=True,actor_handoff='partial_arrival_diagnostic',axis_checkpoints=2,track_checkpoint=True,
                    future_updates_checked=3,forgery_rejected=True,ground='diagnostic',live_e7=False,
                    native_window_launched=False,media_accepted=False)


def verify_process(executable,temporary_root=None,conversation=False):
    def run(directory,phase,success=True):
        result=subprocess.run([str(executable),'--check-field-conversation'if conversation else '--check-field-context',str(directory),phase],cwd=ROOT,capture_output=True,text=True,timeout=60)
        assert (result.returncode==0)==success,result.stdout+result.stderr
        return result
    with tempfile.TemporaryDirectory(prefix='suikoden-field-context-',dir=temporary_root)as temporary:
        directory=Path(temporary)
        first=json.loads(run(directory,'write').stdout)
        path=directory/'field-context.json';saved=path.read_bytes()
        assert json.loads(run(directory,'read').stdout)==first
        assert path.read_bytes()==saved
        assert first['frontier']['command']==28 and first['position']==dict(x=224,y=624)
        assert first['messenger']['motion']['x']==112 and first['messenger']['motion']['y']==632
        assert first['teo']['motion']['x']==184 and first['teo']['motion']['y']==624
        assert first['box_closed'] and first['mid_track_checkpoint'] and first['mid_overlap_checkpoint'] and first['messenger_spoken'] and first['return_spoken']
        assert first['teo']['sprite']['remaining']>0
        after_path=directory/'field-context-after-conversation.json';after_bytes=after_path.read_bytes()
        assert json.loads(run(directory,'read').stdout)==first
        assert after_path.read_bytes()==after_bytes
        for change,expected in ((lambda s:s.update(context_sha256='0'*64),'FieldEventIdentityMismatch'),
                                (lambda s:s.update(selected_program=False),'InvalidFieldEventState'),
                                (lambda s:s['hero_sprite']['animation'].update(remaining=0),'InvalidFieldHeroAnimation'),
                                (lambda s:s.update(ordinary_actors=None),'MissingFieldActorConstruction'),
                                (lambda s:s['ordinary_actors'].update(count=65,slots=[None]*65),'UnexpectedToken'),
                                (lambda s:s['ordinary_actors']['slots'][12]['avatar']['sprite'].update(remaining=0),'InvalidFieldActorState'),
                                (lambda s:s['ordinary_actors']['construction_story'].update(scenario=chr(64)+s['ordinary_actors']['construction_story']['scenario'][1:]),'InvalidFieldActorState')):
            invalid=json.loads(saved);change(invalid['session']);path.write_text(json.dumps(invalid))
            assert expected in run(directory,'read',False).stderr
        path.write_bytes(saved)
        mid=directory/'field-context-mid-track.json';mid_bytes=mid.read_bytes()
        for change in (lambda s:s['ordinary_track'].update(actor=11),
                       lambda s:s['ordinary_track']['state'].update(remaining=255),
                       lambda s:s.update(movement_identity='incorrect'),
                       lambda s:s['movement_camera'].update(x=0),
                       lambda s:s['ordinary_actors']['slots'][10]['avatar']['motion'].update(offset_x=99)):
            invalid=json.loads(mid_bytes);change(invalid['session']);mid.write_text(json.dumps(invalid))
            assert 'InvalidFieldActorState' in run(directory,'read',False).stderr
        mid.write_bytes(mid_bytes)
        timer=directory/'field-context-mid-delay.json';timer_bytes=timer.read_bytes()
        invalid=json.loads(timer_bytes);invalid['session']['delay_remaining']=65535;timer.write_text(json.dumps(invalid))
        assert 'InvalidFieldEventState' in run(directory,'read',False).stderr
        timer.write_bytes(timer_bytes)
        overlap=directory/'field-context-mid-overlap.json';overlap_bytes=overlap.read_bytes()
        for change in (lambda s:s['other_tracks'][0].update(actor=10),
                       lambda s:s['other_tracks'][1].update(actor=12),
                       lambda s:s['movement_camera'].update(x=1000)):
            invalid=json.loads(overlap_bytes);change(invalid['session']);overlap.write_text(json.dumps(invalid))
            assert 'InvalidFieldActorState' in run(directory,'read',False).stderr
        overlap.write_bytes(overlap_bytes)
        audio=directory/'field-context-audio-pending.json';audio_bytes=audio.read_bytes()
        acknowledged=directory/'field-context-audio-acknowledged.json';acknowledged_bytes=acknowledged.read_bytes()
        assert json.loads(acknowledged_bytes)['session']['audio_request'] is None
        for change in (lambda s:s.update(audio_identity='0'*64),
                       lambda s:s.update(audio_cached_command=0x404),
                       lambda s:s.update(area_command=0x404),
                       lambda s:s['audio_request'].update(batch=2**32),
                       lambda s:s['audio_request'].update(origin=27)):
            invalid=json.loads(audio_bytes);change(invalid['session']);audio.write_text(json.dumps(invalid))
            assert 'InvalidFieldAudioState' in run(directory,'read',False).stderr
        audio.write_bytes(audio_bytes)
        assert acknowledged.read_bytes()==acknowledged_bytes
        return dict(fresh_process_restart=True,future_updates_checked=3,program='vaa_room2_audience',source_start='VAA:0x50D80',committed_prefix_end_command=27,first_unsupported_command=28,source_hero_alignment_updates=32,hero_transition_source_checked=True,teo_transition_source_checked=True,after_conversation_fresh_process_restore=True,mid_track_fresh_process_restore=True,mid_delay_fresh_process_restore=True,mid_overlap_fresh_process_restore=True,mock_audio_request_fresh_process_restore=True,mock_audio_acknowledgement_fresh_process_restore=True,page_checkpoint=conversation,messenger_spoken=True,return_spoken=True,box_closed=True,ordinary_construction_history_preserved=True,selected_context_preserved=True,malformed_context_scope_sprite_rejected=True,ordinary_main_states_constructed=14,full_room_construction=False,whole_program_complete=False,native_window_launched=False,media_accepted=False)


if __name__=='__main__':
    if '--executable' in sys.argv:
        parser=argparse.ArgumentParser(description=__doc__)
        parser.add_argument('--executable',required=True,type=Path)
        parser.add_argument('--temporary-root',type=Path)
        parser.add_argument('--conversation',action='store_true')
        parser.add_argument('--position',action='store_true')
        args=parser.parse_args()
        print(json.dumps(verify_position_process(args.executable.resolve(),args.temporary_root) if args.position else verify_process(args.executable.resolve(),args.temporary_root,args.conversation),sort_keys=True))
    else:unittest.main()


#!/usr/bin/env python3
"""Battle cue source bindings and full independent ADPCM comparisons."""
from pathlib import Path
import hashlib
import json
import sys
import tempfile
import unittest
import wave
import numpy as np
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'kit/tools'))
from export_battle_audio import export,validate,encounter_music
from dot8_audio import channel_bytes
from disc import extract
from test_spu_adpcm import reference_decode


class BattleAudio(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory();cls.output=Path(cls.temp.name)
        cls.packet=export(cls.output)
    @classmethod
    def tearDownClass(cls):cls.temp.cleanup()

    def test_encounter_music_uses_only_the_source_boss_bit(self):
        for flags in (0,1,0x80000000,0x3fffffff,0x40000000,0xc0000000,0xffffffff):
            self.assertEqual(encounter_music(flags),{'music':'boss'} if flags&0x40000000 else {})

    def test_source_table_cues_and_native_fixture(self):
        self.assertEqual(self.packet,json.loads((ROOT/'game/tests/fixtures/battle_audio.json').read_text()))
        validate(self.output,self.packet)
        proof=json.loads((self.output/'battle_provenance.json').read_text())
        for track,origin,(index,lba,rate,loop,end) in zip(self.packet['tracks'],proof['sources'],[(29,87267,43953,224,1696),(30,88963,43690,96,1664),(31,90699,42063,192,512)],strict=True):
            self.assertEqual((origin['index'],origin['lba'],origin['rate'],origin['loop_sector'],origin['end_sector']),(index,lba,rate,loop,end))
            self.assertEqual(track['frames'],end//16*28672)
            self.assertEqual(track['loop_start_frame'],loop//16*28672)
            self.assertEqual(track['volume'],40 if index==31 else 127)
            self.assertEqual(hashlib.sha256((self.output/track['path']).read_bytes()).hexdigest(),track['sha256'])

    def test_full_stereo_streams_match_the_independent_adpcm_decoder(self):
        proof=json.loads((self.output/'battle_provenance.json').read_text())
        for track,origin in zip(self.packet['tracks'],proof['sources'],strict=True):
            raw=extract(origin['lba'],origin['source_bytes'])
            with wave.open(str(self.output/track['path']),'rb') as stream:
                self.assertEqual((stream.getnchannels(),stream.getsampwidth(),stream.getframerate(),stream.getnframes()),(2,2,track['sample_rate'],track['frames']))
                data=stream.readframes(stream.getnframes())
            pcm=np.frombuffer(data,dtype='<i2').reshape(-1,2)
            for channel,compressed in enumerate(channel_bytes(raw)):
                expected=np.asarray(reference_decode(compressed),dtype=np.int16)
                self.assertTrue(np.array_equal(pcm[:,channel],expected),(track['id'],channel))
            self.assertGreater(np.max(np.abs(pcm.astype(np.int32))),1000)

    def test_package_checker_and_bundle_require_a_complete_valid_audio_group(self):
        import check_journey_package as checker
        import bundle_macos as bundle
        import shutil
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            errors=[];checker.check_battle_audio(root,errors);self.assertEqual(errors,[])
            (root/'audio').mkdir()
            shutil.copyfile(self.output/'battle.json',root/'audio/battle.json')
            checker.check_battle_audio(root,errors);self.assertIn('incomplete',errors[0])
            for name in ('battle.wav','boss.wav','victory.wav','battle_provenance.json'):
                shutil.copyfile(self.output/name,root/'audio'/name)
            errors=[];checker.check_battle_audio(root,errors);self.assertEqual(errors,[])
            files={}
            for name in bundle.FILES:
                path=root/name;path.parent.mkdir(parents=True,exist_ok=True)
                path.write_bytes(b'{"rooms":[]}' if name == 'room.json' else name.encode())
                files[name]=bundle.digest(path)
            for name in bundle.BATTLE_AUDIO_FILES:files[name]=bundle.digest(root/name)
            manifest=dict(schema='suikoden-journey-manifest/1',files=files)
            (root/'manifest.json').write_text(json.dumps(manifest))
            self.assertEqual(bundle.checked_content(root),manifest)
            del files['audio/boss.wav'];(root/'manifest.json').write_text(json.dumps(manifest))
            with self.assertRaisesRegex(ValueError,'incomplete'):bundle.checked_content(root)
            packet=json.loads((root/'audio/battle.json').read_text());packet['tracks'][0]['volume']=None
            (root/'audio/battle.json').write_text(json.dumps(packet));errors=[]
            checker.check_battle_audio(root,errors);self.assertIn('dimensions',errors[0])

    def test_rejects_promotion_invalid_loops_paths_and_corrupt_files(self):
        with self.assertRaisesRegex(ValueError,'accepted staging'):export(ROOT/'kit/work/accepted/audio')
        for key,value in [('path','../battle.wav'),('loop_start_frame',self.packet['tracks'][0]['frames'])]:
            packet=json.loads(json.dumps(self.packet));packet['tracks'][0][key]=value
            with self.assertRaises(ValueError):validate(self.output,packet)
        packet=json.loads(json.dumps(self.packet));packet['tracks'][0]['sha256']='0'*64
        with self.assertRaisesRegex(ValueError,'hash/path'):validate(self.output,packet)


if __name__=='__main__':unittest.main()

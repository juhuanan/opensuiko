"""The bundle boundary rejects changed content before packaging or signing."""
import hashlib
import io
import tarfile
from unittest.mock import patch
import subprocess
import json
from pathlib import Path
import sys
import tempfile
import unittest
import wave

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import bundle_macos as bundle

ROOM_BYTES = b'{"schema":"suikoden-room/7","rooms":[]}'


class BundleManifest(unittest.TestCase):
    def test_current_spell_and_sound_candidates_are_included_and_verified(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            files = {}
            for name in bundle.FILES | bundle.SPELL_FILES | {"battle/spells.provenance.json", bundle.ROOM_BATTLE_PATH}:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(ROOM_BYTES if name == 'room.json' else name.encode())
                files[name] = bundle.digest(path)
            folder = root / 'audio/sfx'
            folder.mkdir(parents=True)
            with wave.open(str(folder / '0524.wav'), 'wb') as out:
                out.setnchannels(2); out.setsampwidth(2); out.setframerate(44100); out.writeframes(b'\0\0\0\0')
            packet = dict(schema='suikoden-battle-sfx/1', sample_rate=44100,
                          cues=[dict(id=0x524, path='0524.wav', frames=1, bank=0, program=2, note=28,
                                     retrigger=True, sha256=bundle.digest(folder / '0524.wav'))])
            (folder / 'battle_sfx.json').write_text(json.dumps(packet))
            for name in ('audio/sfx/battle_sfx.json', 'audio/sfx/0524.wav'):
                files[name] = bundle.digest(root / name)
            manifest = dict(schema='suikoden-journey-manifest/1', files=files)
            (root / 'manifest.json').write_text(json.dumps(manifest))
            self.assertEqual(bundle.checked_content(root), manifest)
            events = root / bundle.ROOM_BATTLE_PATH
            events.write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError, 'battle/field_events.json'):
                bundle.checked_content(root)
            events.write_bytes(bundle.ROOM_BATTLE_PATH.encode())
            del files['audio/sfx/0524.wav']
            (root / 'manifest.json').write_text(json.dumps(manifest))
            with self.assertRaisesRegex(ValueError, 'incomplete battle sound files'):
                bundle.checked_content(root)

    def test_notices_use_the_configured_package_cache(self):
        with tempfile.TemporaryDirectory() as temporary:
            cache=Path(temporary)/'cache';packages=cache/'p';packages.mkdir(parents=True)
            with tarfile.open(packages/'raylib-6.0.0-test.tar.gz','w:gz') as archive:
                content=b'raylib license';member=tarfile.TarInfo('raylib/LICENSE');member.size=len(content)
                archive.addfile(member,io.BytesIO(content))
            (packages/'raylib_zig-6.0.0-test.tar.gz').write_bytes(b'complete pinned package')
            output=Path(temporary)/'notices';output.mkdir()
            with patch.dict('os.environ',{'ZIG_GLOBAL_CACHE_DIR':str(cache)}):
                records=bundle.notices(output)
            self.assertEqual([r['component'] for r in records],['raylib','raylib-zig'])
            self.assertTrue(all((output/r['notices']).is_file() for r in records))

    def test_bundle_checks_content_and_recovers_saves_in_separate_launches(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);content=root/'content';content.mkdir()
            files={}
            for name in bundle.FILES:
                path=content/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(ROOM_BYTES if name == 'room.json' else name.encode())
                files[name]=bundle.digest(path)
            (content/'manifest.json').write_text(json.dumps(dict(schema='suikoden-journey-manifest/1',files=files)))
            binary=root/'binary';binary.write_bytes(b'candidate executable')
            opening = root / 'opening'
            opening.mkdir()
            for name in ('scene.json', 'atlas.png'):
                (opening / name).write_bytes(name.encode())
            (opening / 'provenance.json').write_text(json.dumps(dict(files={name: bundle.digest(opening / name) for name in ('scene.json', 'atlas.png')})))
            calls=[]
            def run(command,**kwargs):
                calls.append(command)
                if '--check-persistence' in command:
                    phase = command[2]
                    saves = Path(kwargs['env']['SUIKODEN_USER_DATA'])
                    self.assertEqual(saves.parent, Path(kwargs['cwd']).resolve())
                    slots = ('journey-slot.json', 'journey-slot2.json', 'journey-slot3.json')
                    for name in slots:
                        if phase == 'write':
                            (saves / name).write_bytes(b'primary')
                            (saves / (name + '.bak')).write_bytes(b'backup')
                        else:
                            expected = b'primary' if phase == 'load' else b'incomplete save\n'
                            self.assertEqual((saves / name).read_bytes(), expected)
                            self.assertEqual((saves / (name + '.bak')).read_bytes(), b'backup')
                    return subprocess.CompletedProcess(command, 0, '', f'OK: isolated persistence {phase} across all three save slots\n')
                return subprocess.CompletedProcess(command,0,'','OK: candidate is a loadable content package')
            with patch.object(bundle,'notices',return_value=[]),patch.object(bundle.subprocess,'run',side_effect=run):
                output=bundle.bundle(content,root/'Candidate.app',binary,opening)
            payload = output / 'Contents/Resources/content'
            packaged = json.loads((payload / 'manifest.json').read_text())
            for name in ('scene.json', 'atlas.png', 'provenance.json'):
                path = 'opening/' + name
                self.assertEqual(packaged['files'][path], bundle.digest(payload / path))
            checks=[command for command in calls if '--check-content' in command]
            self.assertEqual(len(checks),1)
            self.assertEqual(checks[0][1],'--check-content')
            self.assertEqual(len(checks[0]),3)
            self.assertTrue(Path(checks[0][2]).is_absolute())
            self.assertEqual([command[2] for command in calls if '--check-persistence' in command], ['write', 'load', 'recover'])
            receipt=json.loads((root/'Candidate-receipt.json').read_text())
            self.assertEqual(receipt['headless_content_check'],True)
            self.assertTrue(receipt['persistence_check'].startswith('passed'))

    def test_hashes_missing_members_and_escaping_links(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "content"
            root.mkdir()
            files = {}
            for name in bundle.FILES:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(ROOM_BYTES if name == 'room.json' else name.encode())
                files[name] = bundle.digest(path)
            manifest = dict(schema="suikoden-journey-manifest/1", status="candidate", files=files)
            (root / "manifest.json").write_text(json.dumps(manifest))
            self.assertEqual(bundle.checked_content(root), manifest)
            (root / 'room.json').write_text(json.dumps(dict(schema='suikoden-room/11', rooms=[dict(scenery_atlas='field/scenery.png')])))
            files['room.json'] = bundle.digest(root / 'room.json')
            (root / 'manifest.json').write_text(json.dumps(manifest))
            with self.assertRaisesRegex(ValueError, 'incomplete journey scenery atlas manifest'):
                bundle.checked_content(root)
            (root / 'field').mkdir()
            (root / 'field/scenery.png').write_bytes(b'candidate scenery')
            files['field/scenery.png'] = bundle.digest(root / 'field/scenery.png')
            (root / 'manifest.json').write_text(json.dumps(manifest))
            self.assertEqual(bundle.checked_content(root), manifest)
            actor_path = root / "battle/unites.json"
            actor_path.write_bytes(b"candidate unite metadata")
            files["battle/unites.json"] = hashlib.sha256(actor_path.read_bytes()).hexdigest()
            (root / "manifest.json").write_text(json.dumps(manifest))
            self.assertEqual(bundle.checked_content(root), manifest)
            for group, missing in ((bundle.DIALOGUE_FILES, 'field-ui/ui.json'), (bundle.DUEL_FILES, 'duel/atlas.png')):
                for name in group:
                    path=root/name;path.parent.mkdir(parents=True,exist_ok=True)
                    path.write_bytes(name.encode());files[name]=bundle.digest(path)
                (root/'manifest.json').write_text(json.dumps(manifest))
                self.assertEqual(bundle.checked_content(root),manifest)
                removed=files.pop(missing)
                (root/'manifest.json').write_text(json.dumps(manifest))
                with self.assertRaisesRegex(ValueError,'incomplete'):
                    bundle.checked_content(root)
                files[missing]=removed
            (root/'manifest.json').write_text(json.dumps(manifest))
            (root / "atlas.png").write_bytes(b"changed")
            with self.assertRaisesRegex(ValueError, "hash/path mismatch"):
                bundle.checked_content(root)
            outside = Path(temporary) / "outside.png"
            outside.write_bytes(b"atlas.png")
            (root / "atlas.png").unlink()
            (root / "atlas.png").symlink_to(outside)
            with self.assertRaisesRegex(ValueError, "hash/path mismatch"):
                bundle.checked_content(root)
            del files["room.json"]
            (root / "manifest.json").write_text(json.dumps(manifest))
            with self.assertRaisesRegex(ValueError, "incomplete"):
                bundle.checked_content(root)


if __name__ == "__main__":
    unittest.main()

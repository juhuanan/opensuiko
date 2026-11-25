#!/usr/bin/env python3
"""Assemble a private candidate app; never launch a window or promote assets."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tarfile
import tempfile
import zipfile

from room_battle_package import PATH as ROOM_BATTLE_PATH, SCENERY_SCHEMAS, object_rows, valid_scenery_path

ROOT = Path(__file__).resolve().parents[2]
FILES = {
    "room.json", "journey.json", "atlas.png", "provenance.json",
    "battle/trial.json", "battle/actors.png", "battle/floor.png", "battle/provenance.json",
}
DIALOGUE_FILES = {"field-ui/ui.json", "field-ui/atlas.png", "field-ui/provenance.json"}

SPELL_FILES = {"battle/spells.json", "battle/spell_effects.png"}
BATTLE_AUDIO_FILES = {"audio/battle.json", "audio/battle.wav", "audio/boss.wav", "audio/victory.wav", "audio/battle_provenance.json"}
DEFEAT_AUDIO_FILES = {"audio/defeat.json", "audio/defeat.wav", "audio/defeat_provenance.json"}
OPENING_AUDIO_FILES = {"audio/audio.json", "audio/palace.wav", "audio/audience.wav"}
PARTY_FILES = {"party/catalogue.json", "party/ownership_bindings.json"}
DUEL_FILES = {"duel/presentation.json", "duel/atlas.png"}
SFX_MANIFEST = "audio/sfx/battle_sfx.json"
OPTIONAL_FILES = DIALOGUE_FILES | SPELL_FILES | BATTLE_AUDIO_FILES | DEFEAT_AUDIO_FILES | OPENING_AUDIO_FILES | PARTY_FILES | DUEL_FILES | {"ui.json", "battle/ground.png", "battle/unites.json", "battle/spells.provenance.json", "video/movies.json", ROOM_BATTLE_PATH}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def checked_content(root):
    manifest = json.loads((root / "manifest.json").read_text())
    members = set(manifest.get("files", {}))
    sound_files = {name for name in members if name.startswith("audio/sfx/")}
    scenery_files = {name for name in members if valid_scenery_path(name)}
    if manifest.get("schema") != "suikoden-journey-manifest/1" or not FILES <= members or members - FILES - OPTIONAL_FILES - sound_files - scenery_files or any(members & group and not group <= members for group in (DIALOGUE_FILES, SPELL_FILES, BATTLE_AUDIO_FILES, DEFEAT_AUDIO_FILES, OPENING_AUDIO_FILES, PARTY_FILES, DUEL_FILES)) or ("battle/spells.provenance.json" in members and not SPELL_FILES <= members):
        raise ValueError("unsupported or incomplete journey manifest")
    for name, expected in manifest["files"].items():
        path = root / name
        if path.is_symlink() or not path.resolve().is_relative_to(root.resolve()) or digest(path) != expected:
            raise ValueError(f"content hash/path mismatch: {name}")
    rooms = json.loads((root / "room.json").read_text())
    if not isinstance(rooms, dict):
        raise ValueError("invalid journey room metadata")
    expected_scenery = set()
    for room in object_rows(rooms.get('rooms'), 'rooms'):
        path = room.get('scenery_atlas')
        if path is not None:
            if rooms.get('schema') not in SCENERY_SCHEMAS or not valid_scenery_path(path):
                raise ValueError("invalid journey scenery atlas path")
            expected_scenery.add(path)
    if scenery_files != expected_scenery:
        raise ValueError("incomplete journey scenery atlas manifest")
    if BATTLE_AUDIO_FILES <= members:
        from export_battle_audio import validate
        validate(root / "audio", json.loads((root / "audio/battle.json").read_text()))
    if DEFEAT_AUDIO_FILES <= members:
        from export_defeat_audio import validate as validate_defeat
        validate_defeat(root / "audio", json.loads((root / "audio/defeat.json").read_text()))
    if sound_files:
        if SFX_MANIFEST not in sound_files:
            raise ValueError("incomplete battle sound manifest")
        from export_battle_sfx import validate
        packet = json.loads((root / SFX_MANIFEST).read_text())
        validate(root / "audio/sfx", packet)
        expected = {SFX_MANIFEST} | {f"audio/sfx/{cue['path']}" for cue in packet['cues']}
        if sound_files != expected:
            raise ValueError("incomplete battle sound files")
    return manifest


def notices(destination):
    records = []
    cache = Path(os.environ.get("ZIG_GLOBAL_CACHE_DIR", ROOT / "kit/work/cache/zig")) / "p"
    for pattern, label in (("raylib-6.0.0-*.tar.gz", "raylib"), ("raylib_zig-6.0.0-*.tar.gz", "raylib-zig")):
        matches = list(cache.glob(pattern))
        if len(matches) != 1:
            raise ValueError(f"expected one pinned {label} package")
        source = matches[0]
        if label == "raylib-zig":
            output = destination / source.name
            shutil.copyfile(source, output)
        else:
            output = destination / "raylib-notices-and-embedded-sources.zip"
            with tarfile.open(source) as archive, zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as target:
                for member in sorted(archive.getmembers(), key=lambda item: item.name):
                    relative = member.name.split("/", 1)[-1]
                    if member.isfile() and (relative == "LICENSE" or relative.startswith("src/external/")):
                        data = archive.extractfile(member).read()
                        target.writestr(zipfile.ZipInfo(relative), data, compress_type=zipfile.ZIP_DEFLATED)
        records.append(dict(component=label, package=source.name, source_sha256=digest(source), notices=output.name))
    return records


def verify_packaged_saves(executable, content, working_directory):
    saves = Path(working_directory) / 'persistence'
    saves.mkdir()
    env = {**os.environ, 'SUIKODEN_USER_DATA': str(saves.resolve())}

    def run(phase):
        result = subprocess.run([str(executable), '--check-persistence', phase, str(content)],
                                cwd=working_directory, env=env, capture_output=True, text=True)
        output = result.stdout + result.stderr
        if result.returncode or f'OK: isolated persistence {phase} across all three save slots' not in output:
            raise ValueError(f'packaged persistence {phase} failed: {output.strip()}')
        return output

    def saved_digests():
        files = {}
        for path in saves.iterdir():
            if path.is_symlink() or not path.is_file():
                raise ValueError(f'unexpected persistence output: {path.name}')
            files[path.name] = digest(path)
        return files

    write_log = run('write')
    original = saved_digests()
    primaries = sorted(name for name in original if name.endswith('.json'))
    if len(primaries) != 3 or any(name + '.bak' not in original for name in primaries):
        raise ValueError('packaged persistence did not write three slots with backups')
    load_log = run('load')
    if saved_digests() != original:
        raise ValueError('packaged load changed the save files')
    for name in primaries:
        (saves / name).write_bytes(b'incomplete save\n')
    damaged = saved_digests()
    recover_log = run('recover')
    if saved_digests() != damaged:
        raise ValueError('packaged backup recovery changed the save files')
    return write_log + load_log + recover_log


def bundle(content, output, binary, opening=None):
    content, output, binary = map(lambda p: Path(p).resolve(), (content, output, binary))
    accepted = (ROOT / "kit/work/accepted").resolve()
    if output == accepted or accepted in output.parents or output.suffix != ".app":
        raise ValueError("output must be a candidate .app outside accepted staging")
    if output.exists():
        raise FileExistsError(output)
    manifest = checked_content(content)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="suikoden-bundle-", dir=output.parent) as temporary:
        app = Path(temporary) / output.name
        resources = app / "Contents/Resources"
        payload = resources / "content"
        executable = app / "Contents/MacOS/Suikoden"
        executable.parent.mkdir(parents=True)
        payload.mkdir(parents=True)
        for name in sorted(set(manifest["files"]) | {"manifest.json"}):
            target = payload / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(content / name, target)
        if opening is not None:
            opening=Path(opening).resolve()
            proof=json.loads((opening/'provenance.json').read_text())
            if set(proof.get('files',{}))!={'scene.json','atlas.png'}:raise ValueError('incomplete opening candidate')
            for name,expected in proof['files'].items():
                if (opening/name).is_symlink() or digest(opening/name)!=expected:raise ValueError('opening candidate hash/path mismatch')
            (payload/'opening').mkdir()
            for name in ('scene.json','atlas.png','provenance.json'):shutil.copyfile(opening/name,payload/'opening'/name)
            audio=opening/'audio'
            if audio.exists():
                audio_proof=json.loads((audio/'provenance.json').read_text())
                if set(audio_proof.get('files',{}))!={'audio.json','palace.wav','audience.wav'}:raise ValueError('incomplete opening audio candidate')
                for name,expected in audio_proof['files'].items():
                    if (audio/name).is_symlink() or digest(audio/name)!=expected:raise ValueError('opening audio hash/path mismatch')
                (payload/'opening/audio').mkdir()
                for name in ('audio.json','palace.wav','audience.wav','provenance.json'):shutil.copyfile(audio/name,payload/'opening/audio'/name)
            opening_files = {path.relative_to(payload).as_posix(): digest(path)
                             for path in sorted((payload / 'opening').rglob('*')) if path.is_file()}
            manifest = {**manifest, 'files': {**manifest['files'], **opening_files}}
            (payload / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        shutil.copyfile(binary, executable)
        executable.chmod(0o755)
        info = dict(CFBundleExecutable="Suikoden", CFBundleIdentifier="local.suikoden.zig.prototype", CFBundleName="Suikoden", CFBundlePackageType="APPL", CFBundleShortVersionString="0.1.0", CFBundleVersion="1", NSHighResolutionCapable=True, LSMinimumSystemVersion="13.0")
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        licenses = resources / "licenses"
        licenses.mkdir()
        components = notices(licenses)
        (resources / "NOTICE.txt").write_text(
            "Private behavior-based Suikoden prototype. Candidate content; review/promotion remains separate.\n"
            "Original game content belongs to Konami and comes from the owner's private disc dump. Do not redistribute it.\n"
            "Extraction provenance is in content/provenance.json and content/battle/provenance.json.\n"
            "Raylib uses the zlib license with embedded third-party notices retained in licenses/.\n"
            "The complete pinned raylib-zig package is retained because it supplies no top-level license file.\n"
            "This local package does not grant a redistribution license for project code or game assets.\n"
        )
        record = dict(schema="suikoden-local-app/1", status="candidate", content=manifest,
                      executable="Contents/MacOS/Suikoden", components=components,
                      files={p.relative_to(resources).as_posix(): digest(p) for p in sorted(resources.rglob("*")) if p.is_file()})
        (resources / "bundle-manifest.json").write_text(json.dumps(record, indent=2) + "\n")
        subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(app)], check=True, capture_output=True)
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True, capture_output=True)
        with tempfile.TemporaryDirectory(prefix="suikoden-outside-repo-") as cwd:
            env = {**os.environ, 'SUIKODEN_USER_DATA': str((Path(cwd) / 'content-state').resolve())}
            result = subprocess.run([str(executable), "--check-content", str(payload)], cwd=cwd, env=env, capture_output=True, text=True, check=True)
            if "is a loadable content package" not in result.stderr:
                raise ValueError("native content check did not report success")
            persistence_log = verify_packaged_saves(executable, payload, cwd)
        (Path(temporary) / "content-check.log").write_text(result.stdout + result.stderr + persistence_log)
        os.replace(app, output)
        shutil.copyfile(Path(temporary) / "content-check.log", output.parent / (output.stem + "-content-check.log"))
        (output.parent / (output.stem + "-receipt.json")).write_text(json.dumps(dict(
            schema="suikoden-local-app-receipt/1", status="candidate", signature="ad-hoc; codesign --verify --deep --strict passed",
            executable_sha256=digest(output / "Contents/MacOS/Suikoden"),
            manifest_sha256=digest(output / "Contents/Resources/bundle-manifest.json"),
            outside_repository_content_check=True,
            headless_content_check=True,
            persistence_check="passed for all three primary and backup slots in separate processes",
            opening_candidate_included=opening is not None,
            battle_audio_candidate_included=BATTLE_AUDIO_FILES <= set(manifest["files"]),
            defeat_audio_candidate_included=DEFEAT_AUDIO_FILES <= set(manifest["files"]),
            battle_sfx_candidate_included=SFX_MANIFEST in manifest["files"],
        ), indent=2) + "\n")
    return output


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--content", type=Path, default=ROOT / "kit/work/build/journey")
    parser.add_argument("--out", type=Path, default=ROOT / "kit/work/build/standalone/Suikoden.app")
    parser.add_argument("--binary", type=Path, default=ROOT / "game/zig-out/bin/suikoden-journey")
    parser.add_argument("--opening", type=Path, help="include the private palace candidate with its source hashes")
    arguments = parser.parse_args()
    print(f"Verified local candidate: {bundle(arguments.content, arguments.out, arguments.binary, arguments.opening)}")

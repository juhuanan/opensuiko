"""Lower the Warriors effect into the shared scene player; the caller moves its anchor."""
import battle_unite_camera


def program(piece_ids):
    from export_spell_scenes import sample

    contract = battle_unite_camera.report()[15]['controller_research']
    phases, ring, art = contract['phases'], contract['ring'], contract['impact_art']
    if ([phase['updates'] for phase in phases] != [64, 32, 32] or
            ring['count'] != 8 or ring['initial_scale_x'] != 1 or
            ring['local_x_q12'] != 30 * 4096 or not ring['disabled_on_phase1_exit']):
        raise ValueError('Warriors effect geometry changed')
    animation = {row['id']: row['frames'] for row in art['animations']}
    if animation[9] != [dict(piece='piece_30', ticks=1)]:
        raise ValueError('Warriors ring animation changed')
    tracks, objects = [], []
    for angle in ring['initial_angles']:
        track = [sample()]
        for age in range(1, 96):
            track.append(sample(piece_ids[30], angles=[0, 0, angle + ring['angle_delta'] * age],
                                scale=[ring['initial_scale_x'] + phases[0]['object_scale_x_delta'] * min(age, 64), 4096, 4096]))
        objects.append(dict(anchor='caster', track=len(tracks), start=1, position=[ring['local_x_q12'], 0, 0]))
        tracks.append(track)
    # The animation driver advances before drawing and disables a non-looping
    # effect on its final update.
    frames = [piece_ids[int(frame['piece'].removeprefix('piece_'))]
              for frame in animation[6] for _ in range(frame['ticks'])]
    tracks.append([sample()] + [sample(piece) for piece in frames[1:]])
    objects.append(dict(anchor='target', track=len(tracks)-1, start=81))
    return dict(group=False, impact=128, duration=129, initial_draws=0,
                tracks=tracks, objects=objects, cameras=[], meshes=[], wash=[[0, 0, 0]] * 130,
                wash_blend='additive')

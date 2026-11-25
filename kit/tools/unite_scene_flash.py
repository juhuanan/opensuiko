"""Source-derived Flash effect program; battle-controller admission is separate."""
import battle_unite_camera


def program():
    contract = battle_unite_camera.report()[10]['controller_research']
    if contract['phase_updates'] != [64, 64, 64] or contract['damage']['zero_based_update'] != 32:
        raise ValueError('Flash controller timing changed')
    columns = contract['columns']
    drawing = contract['column_draws']
    gaps = [0] + drawing['segment_gaps']
    if len(gaps) != 64:
        raise ValueError('Flash needs 63 visible column updates')
    samples = [dict(angles=[0, 0, 96 * age]) for age in range(64)]
    meshes = []
    for column, origin in zip(columns, contract['column_origins'], strict=True):
        shape = dict(radius=column['lower']['radius'], top_radius=column['upper']['radius'],
                     base_height=column['lower']['height'], height=column['upper']['height'],
                     inner=column['upper']['color'], outer=column['lower']['color'])
        meshes.append(dict(kind='column', anchor='world', origin=origin, track=0, start=1, stop=64,
                           radius=shape['radius'], segments=column['segments'], blend=column['blend'],
                           inner=shape['inner'], outer=shape['outer'], animated_angles=True,
                           segment_gaps=gaps, shape_samples=[shape] * 64))
    # The wash enables at the end of phase0 and is disabled at the end of phase2.
    wash = [None] * 193
    for update in range(64, 192):
        color = 255 if update <= 128 else (0xFF000 - 0x3FC0 * (update - 128)) >> 12
        wash[update] = [color] * 3
    return dict(group=False, impact=161, duration=193, initial_draws=0, tracks=[samples],
                objects=[], cameras=[], meshes=meshes, wash=[[0, 0, 0]] * 194,
                wash_blend='additive', screen_washes=[dict(depth=7, blend='additive', colors=wash)])


if __name__ == '__main__':
    import json
    print(json.dumps(program(), separators=(',', ':')))

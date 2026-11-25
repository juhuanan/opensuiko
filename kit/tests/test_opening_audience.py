"""Source checks for opening audience commands, text, and actor queues."""
from pathlib import Path
from itertools import product
import json
import struct
import sys
import unittest

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'kit/tools'))
import opening_audience as audience
import event_script_decode
import area_scene as scene
import maindec as main
from export_first_room import source
from test_canonical_start import assert_main_words, boot_seed
from test_opening_events import assert_span

BASE=0x80010000


class Audience(unittest.TestCase):
    def test_palace_surface_maps_match_original_queries_and_attachment_draw_tags(self):
        import export_opening_scene as export
        import export_first_room as ground
        for start, end, digest in (
            (0x8012E308, 0x8012E5A0, 'e9b9a322bea24c2724c1db84ee26646634a639ce714e2ec0d23cb28442d6a829'),
            (0x8012DB9C, 0x8012DC38, '8051a60fa648646667915e050363eaa9eb5847e914c7d22298c56378c37536a3'),
            (0x8012DF34, 0x8012DFA4, '5dfa228725f2704a3d86e1fecd4355f97d977af5cc7b7eaade154c992521381c'),
            (0x8012FDF8, 0x8012FE58, '75aaa3c1d7720ebbcd5a6fbd8811fee58dd41180b729d832efa977c263c80405'),
            (0x8012E08C, 0x8012E308, 'c312301765ad7caec40b754b8de746fc996e36b4c2661428ab1cab9877fb1eeb'),
        ):
            assert_span(start, end, digest)
        data, _ = source('/VAA.BIN')
        for number in (2, 1):
            section = scene.section_off(data, scene.room_record(data, number)['section'])
            records = ground.collision_sources(data, section)
            cells = export.surface_cells(data, number)
            width, height = struct.unpack_from('<HH', data, section)
            tiles, packed = (struct.unpack_from('<I', data, section + offset)[0] - BASE for offset in (0x14, 0x30))
            expected = []
            for level in (0, 1):
                for y in range(2 * height - 1):
                    for x in range(2 * width - 1):
                        footprint = ((x, y), (x + 1, y), (x, y + 1), (x + 1, y + 1))
                        coverage = solid = upper = 0
                        index = 0
                        for ordinal, obj in enumerate(records, 1):
                            if obj['order'] < 2 or not level <= obj['b4'] <= level + 1:
                                continue
                            samples = {}
                            for bit, (cx, cy) in enumerate(footprint):
                                u, v = cx - obj['x_half'], cy - obj['y_half']
                                if 0 <= u < obj['width'] and 0 <= v < obj['height']:
                                    start = obj['sheet'] + 8 * (1 + data[obj['sheet']])
                                    samples[bit] = data[start + v * obj['width'] + u]
                            if not samples:
                                continue
                            coverage = sum(1 << bit for bit in samples)
                            solid = sum(1 << bit for bit, mask in samples.items() if mask & 1)
                            upper = sum(1 << bit for bit, mask in samples.items() if mask & 2)
                            index = 0 if solid else ordinal
                            if solid or upper:
                                break
                        query = coverage << 8 | upper << 4 | solid
                        self.assertEqual(ground.scenery_query(records, x, y, level), (query, index))
                        if not query:
                            continue
                        terrain = 0
                        for bit, (cx, cy) in enumerate(footprint):
                            tile, = struct.unpack_from('<H', data, tiles + 2 * ((cy >> 1) * width + (cx >> 1)))
                            nibble = data[packed + (tile >> 1)]
                            shift = 4 * (1 - (tile & 1)) + 2 * (cy & 1) + (cx & 1)
                            terrain |= ((nibble >> shift) & 1) << bit
                        self.assertEqual(ground.terrain_query(data, section, x, y), terrain)
                        support = None
                        if index and upper:
                            obj = records[index - 1]
                            support = dict(id=f"scenery_{obj['index']}", height=obj['b4'], depth=256 - obj['order'])
                            self.assertEqual(ground.support_after_step(records, query, index, level), (support['height'], index - 1))
                        else:
                            self.assertEqual(ground.support_after_step(records, query, index, level), (level, None))
                        if level:
                            blocked = (solid & coverage if index else solid) | (terrain & ~coverage)
                        elif index and (upper & ~solid):
                            blocked = solid | (terrain & ~coverage)
                        else:
                            blocked = (solid & ~upper) | terrain
                        expected.append(dict(x=x * 8, y=y * 8, height=level, walkable=not blocked, support=support))
            self.assertEqual(cells, expected)

    def test_palace_scene_fixture_matches_rebuilt_named_actor_states_and_source_clips(self):
        import tempfile
        import export_opening_scene
        with tempfile.TemporaryDirectory() as directory:
            rebuilt=export_opening_scene.export(Path(directory))
        expected=json.loads((ROOT/'game/tests/fixtures/opening_scene.json').read_text())
        self.assertEqual(rebuilt,expected)
        self.assertEqual(rebuilt['schema'],'suikoden-opening-scene/3')

    def test_opening_frame_root_and_field_callbacks_request_mode_zero_sync_once(self):
        for start, end, digest in (
            (0x800C2854, 0x800C28BC, '987369a11be76239032cb9eb225fa2c6b32ed24c19f499d49860c6bc0a4acec5'),
            (0x801319C4, 0x80131C08, 'a38c6eded27ad01e1f26cdc8d0c36e6dbc43dac4f8f1e1d1149c6a8ec110c72f'),
            (0x80132938, 0x80132B6C, 'cc109c39c196802e7cecc1fa081527ea17a8c2609a8a9db237a7f53b8a8c67fd'),
            (0x80132B6C, 0x80132D10, 'fccd299d77d3564a7544347352fe2c2ecefd99d606fd051b848e80e1962ce765'),
            (0x8013F0C0, 0x8013F1BC, '944e2ffa6a6d86d351f5196de67b4cb92715383b2710064c8d3057d4db93b756'),
            (0x8013ED6C, 0x8013EE48, '0a263fb749e11a913a965dde1c94dba98417be5a3025f1c6a17fcc607661c779'),
        ):
            assert_span(start, end, digest)
        assert_main_words({
            # Clear the sync field, invoke the root slot, then read the same field as argument zero.
            0x800C2854: (0x3C028018, 0x8C42C20C, 0, 0xAC400024, 0x3C028018, 0x8C42DA90, 0, 0x0040F809, 0x00002021),
            0x800C289C: (0x3C038018, 0x8C63C20C, 0, 0x8C640024, 0x3C018018, 0xAC22BE34, 0x0C05524A),
            0x80131998: (0x3C038013, 0x246319C4, 0x3C018018, 0x2421DA90, 0x00220821, 0xAC230000),
            # Increment the field counter, load the child slot, and run the hero and NPC passes.
            0x80131A50: (0x3C128018, 0x2652DA94, 0x8C620488, 0x00108880, 0x02329821, 0x24420001, 0xAC620488, 0x8E620000, 0, 0x0040F809),
            0x80131BA0: (0x0C04C03B, 0, 0x0C04C145),
            0x801325E0: (0x3C038013, 0x24632938, 0x3C018018, 0x2421DA94, 0x00220821, 0xAC230000),
            0x8013297C: (0x0C04FC6F,),
            0x80132990: (0x3C038013, 0x24632B6C, 0x3C018018, 0x2421DA90, 0x00220821, 0xAC230000),
            0x80132B90: (0x10400007, 0x2410FFFF, 0x0C04FC44),
            # The blocker skips the stream pump and still reaches the scroll timer consumer.
            0x8013F0EC: (0x3C028018, 0x9442C028, 0, 0x3042FFFC),
            0x8013F124: (0x14400004, 0, 0x0C04F80A, 0, 0x00408021, 0x0C04F888, 0, 0x0C04F914, 0, 0x0C04FB5B),
            0x8013EE04: (0x3C028018, 0x8442A138, 0, 0x1040000D, 0x00401821, 0x2462FFFF, 0x3C018018, 0xA422A138),
        })
        root = [main.mword(pc) for pc in range(0x800C2854, 0x800C28BC, 4)]
        self.assertEqual(root.count(0x0040F809), 1)
        self.assertEqual(root.count(0x0C05524A), 1)
        data, _ = source('/VAA.BIN')
        self.assertEqual(data[0x50D30:0x50D37], bytes.fromhex('41 75 03 01 05 10 FD'))
        flags_mask = main.mword(0x8013F0F8) & 0xFFFF
        decrement = struct.unpack_from('<h', main.body(), 0x8013EE18 - main.MBASE)[0]
        for active, flags, delay, expected in (
            (False, 0, 0, ('selector', 0)),
            (True, 0, 0, ('stream', 0)),
            (True, 32, 5, ('timer', 4)),
        ):
            path = 'selector' if not active else 'timer' if flags & flags_mask else 'stream'
            self.assertEqual((path, delay + decrement if active and delay else delay), expected)
        runtime, _ = audience.export()
        self.assertEqual(runtime['nominal_updates_per_second'], 60)

    def test_original_sync_modes_distinguish_query_next_refresh_and_multirefresh_wait(self):
        assert_main_words({
            # A negative mode returns the counter. Mode one returns the measured interval.
            0x8015495C: (0x00431023, 0x04810005, 0x3051FFFF),
            0x80154968: (0x3C028018, 0x8C4283F8, 0x08055296),
            0x80154978: (0x34020001, 0x10820036, 0x02201021),
            # Wait on the previous refresh plus mode - 1, or on the previous refresh itself for mode zero.
            0x80154988: (0, 0x3C028018, 0x8C42840C, 0, 0x2442FFFF, 0x0805526B, 0x00441021),
            0x801549A4: (0x3C028018, 0x8C42840C, 0x18800002, 0x00002821, 0x2485FFFF, 0x0C05529C, 0x00402021),
            # Read the live counter after the first wait and wait one more refresh.
            0x801549D0: (0x3C048018, 0x8C8483F8, 0x34050001, 0x0C05529C, 0x24840001),
            0x80154A44: (0xAC22840C, 0x8C630000, 0x02201021, 0x3C018018, 0xAC238408),
        })
        for mode, expected_counter, expected_waits, expected_result in (
            (-1, 100, [], 100), (0, 101, [(100, 0), (101, 1)], 50), (1, 100, [], 50),
            (2, 102, [(101, 1), (102, 1)], 50), (3, 103, [(102, 2), (103, 1)], 50),
        ):
            counter = previous_refresh = 100
            result = counter if mode < 0 else (200 - 150) & 0xFFFF
            waits = []
            if mode == 0 or mode > 1:
                delay = max(mode - 1, 0)
                first = previous_refresh + delay
                waits.append((first, delay))
                counter = max(counter, first) + 1
                waits.append((counter, 1))
            self.assertEqual((counter, waits, result), (expected_counter, expected_waits, expected_result))

    def test_complete_field_selector_and_event_driver_defer_exit_cue_and_handoff(self):
        for start, end, digest in (
            (0x8013F1BC, 0x8013F2A4, '4db7aede2434499dc42779af0e3646a822c5b88a69da97f48bfdd93e5e8cb007'),
            (0x8013DCE0, 0x8013DD38, '52e32fff53b648906f95b552f7eac62074e3651152749648f72f67339c1a9504'),
            (0x8013E028, 0x8013E17C, 'de21a37e1a6a09ebe58814d58dac4e65135ed9414df9dbef4146e5f361387477'),
            (0x8013C12C, 0x8013C184, 'a374bfec0e5cfb437285d6dd1dc711eb2098f28a7d665029b7ccf2ec6eee1d21'),
            (0x80139930, 0x8013999C, 'f6b4984a549cc260f5dd650d0e4ffcacdbeadfe41b961a65018cd9c29bb4a220'),
            (0x80142440, 0x80142534, 'cb7e1afb98df643c810541eb6b12887e3231ca4c98f9bcdede277617b54abddd'),
        ):
            assert_span(start, end, digest)
        assert_main_words({
            # Interpolating movement blocks free selection. A match installs the event child and exits.
            0x80132944: (0x3C028018, 0x8C42BD74, 0x3C03FFFF, 0x00431024, 0x14400079),
            0x8013297C: (0x0C04FC6F, 0x00002021, 0x304200FF, 0x1040000C),
            0x801329A4: (0xAC230000, 0x34020001, 0x3C018017, 0xA0221C28, 0x0804CACF),
            0x80132B90: (0x10400007, 0x2410FFFF, 0x0C04FC44),
            0x8013F124: (0x14400004, 0, 0x0C04F80A),
            0x8013DBD8: (0x30420010, 0x1440010E, 0x00001021),
            0x800C1A2C: (0x8013DCE0, 0x8013DD0C),
            0x8013E1B8: (0xA020A160, 0x3C018018, 0xA020A180),
            0x8013E1EC: (0x3C028018, 0x8C42A120, 0, 0x8C420014, 0, 0x3C018018, 0xAC22AF84),
            0x80171718 + 4 * 0x41: (0x80139930,),
            0x8013C224: (0x90630001, 0x34020003, 0xA4A30006),
        })
        data, _ = source('/VAA.BIN')
        exit_entry = scene.entities(data, scene.room_record(data, 2))[0]
        self.assertFalse(exit_entry['flags'] & 0x10)
        guard, stream = exit_entry['stream_offsets'][1:]
        check_x, left, right, check_y, top, bottom, end = data[guard:guard + 7]
        self.assertEqual((check_x, check_y, end), (0x0B, 0x0C, 0x06))
        self.assertEqual(stream, 0x50D30)
        self.assertEqual(data[stream:stream + 7], bytes.fromhex('41 75 03 01 05 10 FD'))
        motion_mask = (main.mword(0x8013294C) & 0xFFFF) << 16
        for offset, expected in ((-8, False), (-2, False), (2, False), (8, False), (0, True)):
            position = int.from_bytes(struct.pack('<BBbb', 58, 26, offset, 0), 'little')
            x, y = position & 255, (position >> 8) & 255
            selected = position & motion_mask == 0 and left <= x <= right and top <= y <= bottom
            self.assertEqual(selected, expected)

        # The selected stream gets one handler per frame with its re-loop flag clear.
        cursor = None
        room = 2
        cue = spawn = None
        for expected in ((2, None, None, True), (2, 0x508, None, True), (1, 0x508, (5, 16), False)):
            if cursor is None:
                self.assertTrue(selected)
                cursor = stream
            elif data[cursor] == 0x41:
                selector = data[cursor + 1]
                cue, = struct.unpack_from('<H', main.body(), 0x80171C2C + 2 * selector - main.MBASE)
                cursor += 2
            else:
                self.assertEqual(data[cursor], 0x03)
                room, x, y = data[cursor + 1:cursor + 4]
                spawn, cursor = (x, y), None
            self.assertEqual((room, cue, spawn, cursor is not None), expected)

    def test_audience_queue_animation_clock_matches_original_player_and_auto_actor_paths(self):
        assert_main_words({
            # Nonzero interpolation offsets take the moving queue path.
            0x8013E8A4: (0x8E420000, 0x3C03FFFF, 0x00431024, 0x144000D4),
            0x8013EC04: (0x3C028018, 0x2442BD74, 0x16420018),
            0x8013EC20: (0x8C420450, 0, 0x14400011),
            # Hero clocks once per speed unit. Ordinary actors use a separate auto-animation bit.
            0x8013EC34: (0x9042BD79, 0, 0x1840000C, 0x00008821, 0x8E440008, 0x0C031091),
            0x8013EC5C: (0x92420005, 0, 0x0222102A, 0x1440FFF6),
            0x8013EC70: (0x0C04BE0A, 0x02402021, 0x1040000C, 0, 0x90420001, 0, 0x30420001),
            0x8013EC94: (0x8E440008, 0x0C031091),
            # Only descriptors in the ordinary actor array use its metadata.
            0x8012F854: (0x8C430484, 0x000510C0, 0x0804BE29, 0x00431021),
            0x8012F888: (0x1064FFEF, 0, 0x24A50001, 0x00A6102A, 0x1440FFFA, 0x24630018),
        })
        runtime, _ = audience.export()
        auto_animate = {actor['id']: actor['auto_animate'] for actor in runtime['actors']}
        vectors = []
        for track in runtime['tracks']:
            actor = track['actor']
            moving_ticks = 2 if actor == 'hero' else int(auto_animate.get(actor, False))
            for moving in (False, True):
                vectors.append(dict(track=track['id'], moving=moving, sprite_ticks=moving_ticks if moving else 0))
        self.assertEqual(vectors, json.loads((ROOT / 'game/tests/fixtures/opening_queue_clocks.json').read_text()))

    def test_complete_ground_actor_passes_match_animation_clock_and_emitted_pose_order(self):
        self.assertEqual(original_field_vectors(),json.loads((ROOT/'game/tests/fixtures/opening_field.json').read_text()))

    def test_selected_glyph_attribute_raises_only_its_own_row_by_one_pixel(self):
        assert_main_words({
            # The glyph and attribute buffers share row * columns + column.
            0x801466D0: (0x02630018, 0x00001012, 0, 0x8E23004C, 0x00522021, 0x00041040, 0x00431021),
            0x80146700: (0x8E220050, 0, 0x00441021, 0x90450000, 0x27A40010, 0x30A800F0, 0xA3A80040),
            # The row offset adds to the box origin before any attribute nudge.
            0x801467D8: (0x9622003C, 0, 0x02821021, 0xA7A20014),
            0x801467E8: (0x9622003E, 0x96230016, 0x00561021, 0x00431023, 0xA7A20016),
            0x8014688C: (0x93A80040, 0, 0x11000002, 0x24E2FFFF, 0xA7A20016),
            0x801468B0: (0x0C052F7D, 0x27A40010),
            0x801468E0: (0x26730001, 0x0262102A, 0x10400006, 0x02D5B021),
        })
        for row in (0, 1):
            for flags in (0, 16):
                attributes = bytearray(60)
                attributes[row * 30] = flags
                positions = [(-124, 38 + line * 12 - bool(attributes[line * 30] & 0xF0)) for line in (0, 1)]
                expected = [(-124, 38), (-124, 50)]
                if flags:
                    expected[row] = (-124, expected[row][1] - 1)
                self.assertEqual(positions, expected)

    def test_original_selection_highlight_interpolation_fill_and_border(self):
        self.assertEqual(original_selection_vectors(),json.loads((ROOT/'game/tests/fixtures/opening_selection.json').read_text()))

    def test_original_window_open_close_draws_twenty_outlines_then_changes_state(self):
        self.assertEqual(original_window_vectors(),json.loads((ROOT/'game/tests/fixtures/opening_windows.json').read_text()))

    def test_interaction_grid_matches_complete_original_actor_predicate(self):
        assert_main_words({
            # Check the pressed keys and look up the actor by its descriptor ID.
            0x8013D3E0: (0x30420041, 0x14400005),
            0x8013D468: (0x90620014, 0, 0x1044FFE0),
            # Both aim offsets are indexed by the player's facing.
            0x8013D4AC: (0x3C018017, 0x242116F4, 0x00240821, 0x94250000),
            0x8013D4C8: (0x3C018017, 0x242116FC, 0x00240821, 0x94240000),
            # Vertical facing tests X on either side. Horizontal facing also accepts Y + 1.
            0x8013D528: (0x2482FFFF, 0x0062102A, 0x1440001B, 0x312200FF, 0x24820001, 0x0043102A),
            0x8013D558: (0x14620011, 0x312200FF, 0x2562FFFE, 0x2C420002, 0x1040000C),
            0x8013D57C: (0x0064102A, 0x14400007, 0x312200FF, 0x24820001, 0x0043102A, 0x14400003),
            0x8013D5AC: (0x24211704, 0x00220821, 0x90250000, 0x00072400, 0x0C04F33C),
        })
        image = main.body()
        aim_x = struct.unpack_from('<4h', image, 0x801716F4 - main.MBASE)
        aim_y = struct.unpack_from('<4h', image, 0x801716FC - main.MBASE)
        turn = struct.unpack_from('<4B', image, 0x80171704 - main.MBASE)
        vectors = []
        for facing, (dx, dy, opposite) in enumerate(zip(aim_x, aim_y, turn, strict=True)):
            target_x, target_y = (58 + dx, 76 + dy)
            for x in range(55, 62):
                for y in range(73, 80):
                    if facing < 2:
                        reachable = abs(x - target_x) <= 1 and y == target_y
                    else:
                        reachable = x == target_x and 0 <= y - target_y <= 1
                    for keys in (0, 1, 32, 64):
                        accepted = bool(keys & 0x41) and reachable
                        vectors.append(dict(facing=facing, x=x * 8, y=y * 8, keys=keys,
                                            accepted=accepted, actor_facing=opposite if accepted else None))
        self.assertEqual(vectors, json.loads((ROOT / 'game/tests/fixtures/opening_interaction.json').read_text()))

    def test_follower_ground_path_matches_original_history_and_direction_updates(self):
        assert_main_words({
            # Compare Y before X and update only the direction bit for that axis.
            0x8012D804: (0x0083102B, 0x10400006, 0x341100FF),
            0x8012D818: (0x00008821, 0x0804B625, 0x30420002),
            0x8012D824: (0x0064102B, 0x10400006),
            0x8012D838: (0x34110001, 0x0804B625, 0x34420001),
            0x8012D858: (0x0083102B, 0x10400006),
            0x8012D86C: (0x34110003, 0x0804B625, 0x34420002),
            0x8012D878: (0x0064102B, 0x10400008, 0x340200FF),
            0x8012D88C: (0x34110002, 0x30420001, 0x3C018018, 0xA022C0A8),
            # Movement copies the previous Hero coordinates and loads the offsets.
            0x8012D9CC: (0x90620020, 0x3C108018, 0x2610C0A4, 0xA2020000, 0x90620024),
            0x8012D9E4: (0x246315B0, 0x3C018018, 0xA022C0A5, 0x00111080, 0x00431021, 0x8C430000),
            0x8012DA00: (0x90630002, 0, 0x3C018018, 0xA023C0A6),
            0x8012DA1C: (0x90420003, 0, 0x3C018018, 0xA022C0A7),
            0x8012DA60: (0, 0xAC430020, 0x3C038018, 0x9063BD75, 0, 0xAC430024),
        })
        image = main.body()
        offsets = [struct.unpack_from('<2b', image, main.mword(0x801715B0 + direction * 4) + 2 - main.MBASE)
                   for direction in range(4)]
        vectors = []
        for flags in range(4):
            for dx in range(-3, 4):
                for dy in range(-3, 4):
                    direction = None
                    next_flags = flags
                    if dy != 0:
                        direction = int(dy > 0)
                        next_flags = (flags & 2) | direction
                    elif dx != 0:
                        direction = 3 if dx < 0 else 2
                        next_flags = (flags & 1) | (2 if dx < 0 else 0)
                    moved = direction is not None
                    offset_x, offset_y = offsets[direction] if moved else (0, 0)
                    vectors.append(dict(flags=flags, x=(58 + dx) * 8, y=(76 + dy) * 8, direction=direction,
                                        next_x=456 if moved else 464, next_y=608, offset_x=offset_x,
                                        offset_y=offset_y, next_flags=next_flags, previous_x=464 if moved else 456,
                                        previous_y=608))
        self.assertEqual(vectors, json.loads((ROOT / 'game/tests/fixtures/opening_follower.json').read_text()))

    def test_choice_success_consumes_the_third_byte_and_does_not_dispatch_slot24(self):
        data, _ = source('/VAA.BIN')
        cursor = 0x50EE0
        self.assertEqual(data[cursor:cursor + 5], bytes.fromhex('05 00 02 01 18'))
        rows = list(event_script_decode.decode_stream(data, cursor))
        first, count, argument = rows[0][2]
        self.assertEqual((first, count, argument), (0, 2, 1))
        next_opcode = rows[1][0]
        self.assertEqual((next_opcode, rows[1][1]), (cursor + 4, 24))
        assert_main_words({
            0x80171718 + 4 * 5: (0x8013BCDC,),
            # Initialize the selection or consume two bytes before reading input.
            0x8013BCF4: (0x340200FF, 0x14620021),
            0x8013BD18: (0x90430000, 0x24420002, 0x3C018018, 0xAC22AF84, 0x3C018018, 0xA023C018),
            0x8013BDC4: (0x24620001, 0x3C018018, 0xAC22AF84, 0x90620000),
            0x8013BDDC: (0x00822821, 0x30635041, 0x34021000, 0x1062000F),
            0x8013BE0C: (0x0804EFA3, 0x34110001),
            # Both selection directions wrap inside the encoded range.
            0x8013BE3C: (0x0804EF9E, 0x24A2FFFF),
            0x8013BE50: (0x2442FFFF, 0x3C038018, 0x9063C018, 0x2442FFFF, 0x10620005, 0x00801021),
            0x8013BE74: (0x24420001, 0x3C018018, 0xA022C018),
            # Without confirmation, retry the opcode. Confirmation saves the
            # selected row and consumes the third argument before returning.
            0x8013BF00: (0x322200FF, 0x14400009, 0x340200FF),
            0x8013BF18: (0x2442FFFD, 0x3C018018, 0xAC22AF84, 0x0804EFE0),
            0x8013BF48: (0xA022C018, 0x24630001, 0x3C018018, 0xAC23AF84, 0x3C018018, 0xA025BD6C),
            0x8013BF78: (0x0C051309, 0, 0x8FBF0028, 0x8FB10024, 0x8FB00020, 0x03E00008),
        })
        for selected, keys, expected in (
            (255, 0, (0, cursor, None)), (0, 0, (0, cursor, None)),
            (0, 0x40, (255, next_opcode, 0)), (1, 0x40, (255, next_opcode, 1)),
            (0, 0x4000, (1, cursor, None)), (1, 0x1000, (0, cursor, None)),
        ):
            if selected == 255:
                actual = (first, cursor, None)
            elif (keys & 0x5041) == 0x40:
                actual = (255, next_opcode, selected)
            else:
                delta = {0x1000: -1, 0x4000: 1}.get(keys & 0x5041, 0)
                actual = (first + (selected - first + delta) % count, cursor, None)
            self.assertEqual(actual, expected)

    def test_all_audience_text_sources_and_complete_original_widget_interpreters(self):
        self.assertEqual(original_text_vectors(self),json.loads((ROOT/'game/tests/fixtures/opening_text.json').read_text()))

    def test_original_alignment_moves_hero_with_horizontal_then_vertical_upload_jobs(self):
        data, _ = source('/VAA.BIN')
        self.assertEqual(data[0x50D80:0x50D83], bytes.fromhex('10 3E 4E'))
        target_x, target_y = data[0x50D81:0x50D83]
        assert_span(0x8013E450, 0x8013E6B4, '1d72d77f8f3cf1503fe41fda7c14a110b0a78796542a8e7deebfe0087022f525')
        assert_main_words({
            0x80171718 + 4 * 0x10: (0x8013D0B8,),
            0x80171B98: (1, 3, 0, 2),
            # Queue the first axis and retain the second axis for the next upload.
            0x8013D108: (0x0082102B, 0x10400004, 0x34070003),
            0x8013D120: (0x90A20000, 0x34070001, 0x00821023),
            0x8013D154: (0xA020A168, 0x0804F45D, 0x00461023, 0x90620000, 0x34030002),
            0x8013D16C: (0xA023A168, 0x00C21023, 0x3C018018, 0xA022A170, 0x00E02021, 0x0C04F40E),
            0x8013E4A4: (0x34150004,),
            0x8013E554: (0x24211B98, 0x00220821, 0x8C250000, 0x0C04B6A3),
            0x8013E5F0: (0x244200FF, 0xA2020000, 0x3C018017, 0xA02316B8),
        })
        for start, expected, duration in (
            ((64, 73), [2, 2, None, 0, 0, 0, 0, 0, None], 36),
            ((62, 78), [None, None], 8),
            ((60, 80), [3, 3, None, 1, 1, None], 24),
            ((62, 73), [None, 0, 0, 0, 0, 0, None], 28),
            ((64, 78), [2, 2, None, None], 16),
        ):
            x, y = start
            horizontal = [3 if x < target_x else 2] * abs(target_x - x)
            vertical = [0 if y < target_y else 1] * abs(target_y - y)
            schedule = horizontal + [None] + vertical + [None]
            self.assertEqual(schedule, expected)
            self.assertEqual(len(schedule) * 4, duration)

    def test_original_multi_palette_upload_and_sampling_rows(self):
        assert_main_words({
            # Context flags select this loader and give the table length.
            0x800C3594: (0x92220005, 0, 0x304200C0, 0x10400017),
            0x800C35BC: (0x92220005, 0xA2230007, 0x3042003F),
            0x800C35D4: (0x8E22000C, 0x00101880, 0x00621821, 0x8C640000, 0x0C030F32, 0x26100001),
            # Upload 32 entries at X = 256 and advance the CLUT row after each upload.
            0x800C3CD0: (0x34020100, 0xA7A20010, 0x34020020, 0xA7A20014, 0x34020001, 0xA7A20016),
            0x800C3D00: (0x244201E0, 0x0C052164, 0xA7A20012),
            0x800C3D18: (0x24420001, 0x3C018018, 0xA0229040),
        })
        data, _ = source('/VAA.BIN')
        section = scene.section_off(data, scene.room_record(data, 2)['section'])
        vram, materials = scene.load_scene_materials(data, section)
        first_slot = materials['atlas_base'] + sum(len(c['atlases']) for c in materials['contexts'] if not c.get('is_32_colour'))
        bindings, _ = scene.load_npc_contexts(data, section, vram, first_slot)
        row = 480
        for binding in sorted(bindings.values(), key=lambda entry: entry['index']):
            context = binding['context']
            flags = data[context + 5]
            self.assertTrue(flags & 0xC0)
            count = flags & 0x3F
            table, = struct.unpack_from('<I', data, context + 12)
            pointers = struct.unpack_from(f'<{count}I', data, table - BASE)
            offsets = [pointer - BASE for pointer in pointers]
            self.assertEqual(binding['palette_offsets'], offsets)
            self.assertEqual((binding['clut_x'], binding['clut_row']), (256, row))
            for offset in offsets:
                expected = struct.unpack_from('<32H', data, offset)
                self.assertEqual(tuple(vram.get_word(256 + color, row) for color in range(32)), expected)
                row += 1
        self.assertEqual(len(bindings[201]['palette_offsets']), 2)

    def test_original_actor_builder_uses_compact_descriptor_ids_and_source_predicates(self):
        for start, end, digest in (
            (0x8012ED84, 0x8012F3AC, '76d0eb0d2fe784020445c3ecb1f4747ec4934b43d22bab82fd9660fb322324dd'),
            (0x8013D8E0, 0x8013DB6C, '50e2ed023ff810a38121677f0a538cd6f36e04370b95e63116b90bfe36aa88a5'),
            (0x8013D6CC, 0x8013D788, '100d180a2e7e89be2b85ae1e8a513a0e1ce570deb4fffcc508a7c41bdbe9ef2c'),
        ):
            assert_span(start, end, digest)
        assert_main_words({
            # Null classifiers skip the compact table. Rejected predicates retain a null object slot.
            0x8013D8F0: (0x16000095, 0x34020001),
            0x800C19B4: (0x8013D95C, 0x8013D974),
            0x8012F2E8: (0x14620007, 0x34020002),
            0x8012F358: (0xAC400008, 0xAC40000C, 0xAC400010),
            # The illustration lookup uses the source character ID and low two orientation bits.
            0x80134648: (0x24840001, 0x90820000, 0, 0xA4A20000, 0x90820001, 0x03E00008, 0xA0C20000),
            0x8012F190: (0x93A50016, 0x9604FFFE, 0x0C04D1AA, 0x30A50003),
        })
        actor_mask = main.mword(0x8012EF48) & 0xFFFF
        motion_bit = (main.mword(0x8012F030) >> 6) & 31
        animate_bit = (main.mword(0x8012F284) >> 6) & 31
        stride = main.mword(0x8012F39C) & 0xFFFF
        data, _ = source('/VAA.BIN')
        seed = boot_seed()
        for number, flag, count, attached_mask in ((2, 0, 14, 16383), (2, 64, 14, 12287), (1, 0, 11, 511), (1, 64, 11, 975)):
            flags = seed[0x190:0x1D0]
            flags[0] = flag
            room = scene.room_record(data, number)
            entries = []
            for entity in range(room['entity_count']):
                start = room['entity_off'] + stride * entity
                x, y, actor_flags, character = struct.unpack_from('<HHHH', data, start)
                pointer, = struct.unpack_from('<I', data, start + 12)
                if not actor_flags & actor_mask or not pointer:
                    continue
                classifier = pointer - BASE
                cursor = classifier
                attached = True
                for _ in range(16):
                    operation = data[cursor]
                    if operation == 6:
                        break
                    self.assertIn(operation, (7, 8))
                    index, mask = data[cursor + 1:cursor + 3]
                    attached &= bool(flags[index] & mask) == (operation == 7)
                    cursor += 3
                else:
                    self.fail(f'Unterminated actor classifier for room {number}, entity {entity}')
                entries.append((entity, classifier, character, attached, (x & 255) * 8, (y & 255) * 8,
                                (actor_flags >> motion_bit) & 1, data[cursor + 2] & 3, bool(actor_flags & (1 << animate_bit))))
            actors, proof = audience.actor_bindings(data, number, flags)
            self.assertEqual(len(actors), count)
            self.assertEqual(len(entries), count)
            self.assertEqual(sum(1 << i for i, entry in enumerate(entries) if entry[3]), attached_mask)
            for slot, ((entity, classifier, character, attached, x, y, motion, variant, animate), actor, source_entry) in enumerate(zip(entries, actors, proof)):
                self.assertEqual(source_entry, dict(actor=f'scene_actor_{slot}', entity=entity, native_character=character, classifier=classifier))
                self.assertEqual(actor['attached'], attached)
                if attached:
                    self.assertEqual((actor['graphic'], actor['x'], actor['y'], actor['motion'], actor['variant'], actor['auto_animate']),
                                     (f'palace_character_{character}', x, y, motion, variant, animate))

    def test_original_fractional_motion_consumers(self):
        assert_span(0x8012F8AC, 0x8012F97C, '6b47ed2c0d24b48fc6b56e8edb4b86a140da7a5b4ac0168bf4a1a53442681e52')
        assert_main_words({
            # Each signed axis uses the same speed and clamps at zero on crossover.
            0x8012F8CC: (0x92020005, 0, 0x00621023, 0xA2020002, 0x00021600, 0x1C400002, 0, 0xA2000002),
            0x8012F8FC: (0x92020005, 0, 0x00621021, 0xA2020002, 0x00021600, 0x04400002, 0, 0xA2000002),
            0x8012F92C: (0x92020005, 0, 0x00621023, 0xA2020003, 0x00021600, 0x1C400002, 0, 0xA2000003),
            0x8012F95C: (0x92020005, 0, 0x00621021, 0xA2020003, 0x00021600, 0x04400002, 0, 0xA2000003),
        })
        vectors = []
        for speed in (0, 1, 2):
            for offset in range(-8, 9):
                remaining = max(abs(offset) - speed, 0)
                next_x = -remaining if offset < 0 else remaining
                vectors.append(dict(speed=speed, offset_x=offset, offset_y=-offset,
                                    next_x=next_x, next_y=-next_x))
        self.assertEqual(vectors, json.loads((ROOT / 'game/tests/fixtures/opening_motion.json').read_text()))

    def test_runtime_export_covers_real_boundaries_and_keeps_nested_names(self):
        runtime,evidence=audience.export()
        self.assertEqual(len(runtime['commands']),201)
        self.assertEqual(len(runtime['tracks']),19)
        self.assertEqual(runtime,json.loads((ROOT/'game/assets/opening_audience.json').read_text()))
        self.assertEqual(evidence,json.loads((ROOT/'kit/data/reports/opening_audience.json').read_text()))
        self.assertNotIn('close_boxes',[row['kind'] for row in runtime['commands']])
        text=next(row for row in runtime['texts'] if row['id']=='room_text_0')
        self.assertIn(dict(kind='player_name'),text['tokens'])
        self.assertTrue(any(token.get('text')=='.' for token in text['tokens']))
        self.assertEqual(runtime['commands'][-1],dict(kind='finish'))

    def test_original_queue_producer_allocates_hero_and_preserves_every_audience_track(self):
        assert_main_words({
            0x80171718 + 4 * 0x32: (0x8013C354,),
            # Hero uses selector 0x80. The producer allocates 12 bytes and remembers the stream and motion.
            0x8013C37C: (0x90500000, 0x34020080, 0x320400FF, 0x14820005, 0x34120001, 0x3C118018, 0x2631BD74),
            0x8013C3F8: (0x0C030B4C, 0x3404000C),
            0x8013C41C: (0xAC220000, 0xA0D00000, 0x3C028018, 0x8C42AF84, 0, 0xACC20004),
            0x8013C494: (0xA0C00008, 0x92220005, 0xA2200002, 0xA2200003, 0xA0C2000A, 0x34020002, 0xA2220005, 0xA0C0000B),
            0x800C1A68: (0x8013E968,) * 4 + (0x8013E9CC, 0x8013EAD4, 0x8013EA6C, 0x8013E9FC),
            # A count of zero faces the actor. Opcode 7 uses the reverse direction table.
            0x8013E994: (0x10400008, 0x02402021),
            0x8013E9A4: (0x2442FFFF, 0x0C04B6A3, 0xA2020008),
            0x8013E9BC: (0x0C04F33C,),
            0x8013E9E4: (0x0804FAB0, 0xA2430005),
            0x8013EA20: (0x244200FF, 0xA2020008, 0x34630040, 0xA203000B),
            0x8013EA38: (0x24211BA8, 0x00240821, 0x8C250000, 0x0C04F9AD),
            0x8013EAD4: (0x9202000A, 0x00138080, 0xA2420005),
            0x8013EB00: (0xAE000000, 0x2442FFFF, 0x3C018017, 0xA02216B9),
        })
        assert_span(0x8013E7E0, 0x8013ED78, '2303f7929d8371cfad642eeb58188ecb56358ee12ca426725e7d75080de2f2ba')
        data, _ = source('/VAA.BIN')
        runtime, evidence = audience.export()
        rows = [row for row in evidence['instructions'] if row.get('opcode') == 0x32]
        self.assertEqual(len(rows), 19)
        directions = ('down', 'up', 'left', 'right')
        vectors = []
        for index, (row, track) in enumerate(zip(rows, runtime['tracks'], strict=True)):
            operands = bytes.fromhex(row['operands'])
            start = row['offset']
            self.assertEqual(data[start:start + 1 + len(operands)], b'\x32' + operands)
            selector = operands[0]
            actor = {128: 'hero', 64: 'audience_double'}.get(selector, f'scene_actor_{selector}')
            self.assertEqual(track['actor'], actor)
            self.assertEqual(track['id'], f'audience_track_{index}')
            self.assertEqual((operands[-1], len(operands) % 2), (5, 0))
            commands, updates = [], []
            motion = 2
            last_direction = None
            for opcode, value in zip(operands[1:-1:2], operands[2:-1:2], strict=True):
                if opcode < 4:
                    last_direction = opcode
                    direction = directions[main.mword(0x80171B98 + opcode * 4)]
                    commands.append(dict(kind='move', direction=direction, cells=value))
                    effects = [dict(kind='move' if value else 'face', actor=actor, direction=direction)]
                elif opcode == 4:
                    self.assertIn(value, (1, 2))
                    motion = value
                    commands.append(dict(kind='set_motion', motion=motion))
                    effects = []
                elif opcode == 7:
                    self.assertIsNotNone(last_direction)
                    self.assertGreater(value, 0)
                    direction = directions[main.mword(0x80171BA8 + last_direction * 4)]
                    commands.append(dict(kind='advance', cells=value))
                    effects = [dict(kind='advance', actor=actor, direction=direction)]
                else:
                    self.fail(f'Unexpected audience track opcode {opcode}')
                repeat = 1 if opcode == 4 else max(value, 1)
                updates.extend(dict(effects=effects, motion=motion, active=True) for _ in range(repeat))
            commands.append(dict(kind='finish'))
            self.assertEqual(track['commands'], commands)
            updates.append(dict(effects=[], motion=7, active=False))
            vectors.append(dict(track=track['id'], updates=updates))
        self.assertEqual(vectors, json.loads((ROOT / 'game/tests/fixtures/opening_tracks.json').read_text()))

def widget_samples(data, cursor, pace, name, width, height, should_press):
    glyphs = audience.war_text.SUBST
    column = row = countdown = 0
    waiting = fast = False
    grid = bytearray(width * height)
    for tick in range(20000):
        was_waiting = waiting
        if not waiting:
            unlimited = fast
            if not unlimited:
                countdown = (countdown - 1) & 255
            if unlimited or countdown == 255:
                fast = False
                while data[cursor]:
                    code = data[cursor]
                    cursor += 1
                    if code in (1, 3):
                        column, row = 0, row + 1
                    elif code == 2:
                        waiting = True
                    elif code == 4:
                        pace = data[cursor]
                        cursor += 1
                    elif code == 5:
                        countdown = data[cursor]
                        cursor += 1
                    else:
                        if code == 6:
                            assert data[cursor] == 0
                            cursor += 1
                            characters = name
                        else:
                            assert code in glyphs
                            characters = bytes([code])
                        assert row < height and column + len(characters) <= width
                        position = row * width + column
                        grid[position:position + len(characters)] = characters
                        column += len(characters)
                    if not unlimited or code in (2, 5):
                        break
                if not unlimited:
                    countdown = pace
        done = data[cursor] == 0 and not waiting
        pressed = not done and should_press(tick, was_waiting, waiting)
        if pressed:
            if waiting:
                waiting = False
                row = column = 0
                grid[:] = bytes(len(grid))
            else:
                fast = True
        visible = '\n'.join(''.join(glyphs.get(code, ' ') for code in grid[i:i + width]).rstrip()
                            for i in range(0, len(grid), width)).rstrip()
        yield dict(pressed=pressed, visible=visible, page_wait=waiting, done=done,
                   countdown=countdown, pace=pace, fast=fast)
        if done:
            return
    raise AssertionError(f'Unterminated text delivery at {cursor:#x}')


def original_text_vectors(self):
    for start, end, digest in (
        (0x8013B830, 0x8013B950, 'fd7cbd4c1ced3eb8980d560c52e42317ccfb380b1c2fc23c0cb823d6cb3bc54a'),
        (0x80146934, 0x80146A28, 'c4498861196342d68f76d47b9a258bd501e1c9ba82cd4bd6a1b0bbc4db8fac07'),
        (0x80146A28, 0x80146BB4, '7554b386b68a34ff50f449501253ecd2d3af589c835ebaf6efe5783d43a4ecfd'),
        (0x80146BB4, 0x80146D8C, '0ad254e23b951cd149b9684cd49d37b2adef323002c3daf827c30bf334da8b2e'),
        (0x80146DFC, 0x80146ED0, 'ddaf2397523592c4eb5c0e9749eb16c0c0107acdb7dc349aedb9cfe304aceb08'),
        (0x80146F9C, 0x80146FE8, '2504e10afebfb57a5fa4e00c9700d002371ca88d4881ac0664a8fefcda481f1c'),
    ):
        assert_span(start, end, digest)
    assert_main_words({
        0x80171718 + 4 * 0x04: (0x8013B830,),
        0x80171718 + 4 * 0x1C: (0x8013B8CC,),
        0x800C1C60: (0x80146C2C, 0x80146C3C, 0x80146C50),
        # Nested selector zero reads the player name from the game state.
        0x800C4ED8: (0x24421B74, 0x3C018018, 0xAC22C1D8),
    })
    data, _ = source('/VAA.BIN')
    runtime, evidence = audience.export()

    def pointer(at):
        return struct.unpack_from('<I', data, at)[0] - BASE

    room_text = pointer(scene.room_record(data, 2)['record_off'] + 12)
    area_text = pointer(pointer(0) + 20)
    input_text = {row['text']: row['offset'] for row in evidence['instructions'] if 'text' in row}
    default_pace = main.body()[0x80171885 - main.MBASE + 4 * boot_seed()[0x1B90]]
    self.assertEqual(default_pace, runtime['default_text_pace'])
    name = bytes.fromhex('3e 19 22')
    result = []
    for record in evidence['instructions']:
        if record.get('opcode') not in (0x04, 0x1C):
            continue
        address = record['offset']
        opcode, box, index = data[address:address + 3]
        if opcode == 0x04:
            text_id = f'room_text_{index}'
            text_start = pointer(room_text + 4 * index)
        else:
            self.assertEqual(opcode, 0x1C)
            entry = data[address + 3]
            text_id = f'area_text_{index}_{entry}'
            text_start = pointer(pointer(area_text + 4 * index) + 4 * entry)
        self.assertEqual(runtime['commands'][record['command']], dict(kind='text', box=box, text=text_id))
        self.assertEqual(text_start, input_text[text_id])
        for accelerated in (False, True):
            checkpoints, acknowledgements = [], []
            previous = None
            def should_press(tick, _, waiting):
                return tick % 5 == 0 and (accelerated or waiting)

            for tick, sample in enumerate(widget_samples(data, text_start, default_pace, name, 30, 5, should_press)):
                if sample.pop('pressed'):
                    acknowledgements.append(tick)
                signature = tuple(value for key, value in sample.items() if key != 'countdown')
                if signature != previous or tick % 17 == 0:
                    checkpoints.append(dict(tick=tick, **sample))
                    previous = signature
            result.append(dict(text=text_id, accelerated=accelerated, updates=tick + 1,
                               acknowledgements=acknowledgements, checkpoints=checkpoints))
    return result



def original_window_vectors():
    # Descriptor coordinates, box constructor, transition setup, and four grey line submissions.
    for start, end, digest in (
        (0x8013B054, 0x8013B0C8, '94ebdb2c61ad3939aaa865264b55b4b92f5a914ed993301b98d18281921d2b7b'),
        (0x80145224, 0x801452A8, 'fdcfa5da52095ce82034148b50cdcd8b94d8483b107cd07814b402d3c0b24357'),
        (0x8014555C, 0x801455B8, '8d03df0333e7629ce55267f9064b87482ae8588e6b31dc97283bfaac2b97b9c5'),
        (0x80145644, 0x80145680, 'cdb729faf26f38746cf639a6b8f4d73d7713fd7780374054897f5dd8677ffa87'),
        (0x80145A34, 0x80145AD0, '283a2a4967821f2d0b2fb63fddf81c27f4c7dab7ccda40e67a85da070b26bfe3'),
        (0x80147568, 0x801479A0, '26f92d0f8df30fdc732503d5ddd56e18b4109351bd9a9ebe71170fd6e3a7e6a5'),
    ):
        assert_span(start, end, digest)
    assert_main_words({
        0x8013B0F0: (0x34020003, 0xA7A20016, 0xA7A20014),
        0x8013B134: (0x0C03136D, 0x34060014),
        0x8013B360: (0x0C051591, 0x34050014),
        0x80145200: (0x10600008, 0x34020008),
        0x800C4D88: (0x84450000, 0x84460002, 0x84470004, 0x84420006, 0xAFA30014, 0x0C051557, 0xAFA20010),
        0x800C4DDC: (0x02002021, 0x02202821, 0x0C031359, 0x02403021),
    })
    duration = main.mword(0x8013B138) & 0xFFFF
    small = main.mword(0x8013B0F0) & 0xFFFF
    width = 30 * (main.mword(0x80145204) & 0xFFFF)
    height = 5 * (main.mword(0x8014522C) & 0xFFFF)
    result = []
    for x, y, camera_x, camera_y in (
        (62, 78, 320, 472), (58, 78, 320, 472), (23, 45, 32, 200), (0, 0, 0, 0),
        (79, 111, 320, 656), (1, 1, 320, 472), (62, 78, 320, 471), (10, 50, 0, 472),
    ):
        origin = dict(x=(x + 1) * 8 - camera_x, y=(y - 3) * 8 - camera_y)
        anchor = (origin['x'] - 160, origin['y'] - 120, small, small)
        panel = (-124, 38, width, height)
        states = []
        for closing, start, end in ((False, anchor, panel), (True, panel, anchor)):
            updates = []
            for remaining in range(duration - 1, -1, -1):
                # MAIN divides signed screen coordinates before restoring the display center.
                left, top, w, h = (
                    int((a * remaining + b * (duration - remaining)) / duration) for a, b in zip(start, end)
                )
                left += 160
                top += 120
                corners = ((left, top), (left + w, top), (left + w, top + h), (left, top + h))
                lines = [dict(zip(('x1', 'y1', 'x2', 'y2'), a + b)) for a, b in zip(corners, corners[1:] + corners[:1])]
                updates.append(dict(remaining=remaining, open=False, lines=lines))
            updates.append(dict(remaining=0, open=not closing, lines=[]))
            states.append(dict(closing=closing, updates=updates))
        result.append(dict(actor_x=x * 8, actor_y=y * 8, camera_x=camera_x, camera_y=camera_y, origin=origin, states=states))
    return result


def original_selection_vectors():
    # MAIN derives the row rectangle, copies the current rectangle when retargeting,
    # interpolates before decrementing, and draws fill only on the stationary path.
    for start, end, digest in (
        (0x801441B0, 0x801442D4, '3a21157b14cb53fd15416692b1c140a348929b3d97daa9740060653cb16694ae'),
        (0x801442D4, 0x801444B8, '262128a205ffa4ee343bfb0934a9367fc4b5129ef6f5579a8eef348456f8d909'),
        (0x801444B8, 0x80144620, '5fb8934c368f97ef8e6daac7a6d4314a816ea0e24301f3275c321d0be459b86a'),
        (0x80144620, 0x80144830, '5a3fc137ce13bca593f93b4fa3256ec550e2d9ea8f7d68bd60eb3893ba4243eb'),
        (0x80144830, 0x80144B60, '6bab5a9ce32dd00a0cdae4cb6b1b4ba8e33b31367787c306f8463f1fe5275c60'),
        (0x80144B60, 0x80144C24, 'a3061bd8e9a1e58b217a4afcc1b822ca9a5eaa82c0166e1e1b887df9c8da277b'),
    ):
        assert_span(start, end, digest)
    assert_main_words({0x80145200: (0x10600008, 0x34020008), 0x80145224: (0xA2020011, 0x08051492, 0x3402000C)})
    column_width = main.mword(0x80145204) & 0xFFFF
    row_height = main.mword(0x8014522C) & 0xFFFF
    fill_rgb = tuple(main.mword(address) & 0xFF for address in (0x80144324, 0x8014432C, 0x80144334))
    grey = main.mword(0x80144500) & 0xFF
    bright = main.mword(0x8014437C) & 0xFF
    muted = fill_rgb[0]
    result = []
    duration = 8
    y = origin = target = 38 - 2
    remaining = duration
    moving = True
    for row, count in ((None, 10), (1, 3), (0, 12), (1, 12), (0, 12), (1, 1), (0, 1), (1, 12)):
        if row is not None:
            origin, target = y, 38 - 2 + row * row_height
            remaining, moving = duration, True
        for tick in range(count):
            commands = []
            light, dark = grey, grey
            if moving:
                y = int((origin * remaining + target * (duration - remaining)) / duration)
                moving = remaining > 0
                remaining = max(0, remaining - 1)
            else:
                light, dark = bright, muted
                rect = dict(x=-124 + 160, y=y + 120, w=30 * column_width, h=row_height)
                commands.append(dict(additive_fill=dict(rect=rect, red=fill_rgb[0], green=fill_rgb[1], blue=fill_rgb[2])))
            left, right = -124 + 160 - 1, -124 + 160 + 30 * column_width + 1
            top, bottom = y + 120 - 1, y + 120 + row_height + 1
            for x1, y1, x2, y2, level in (
                (left, top, right, top, light), (left, bottom, left, top, light),
                (right, bottom, left, bottom, dark), (right, top, right, bottom, dark),
            ):
                commands.append(dict(line=dict(x1=x1, y1=y1, x2=x2, y2=y2, red=level, green=level, blue=level)))
            result.append(dict(select=row if tick == 0 else None, remaining=remaining, moving=moving, y=y + 120, commands=commands))
    return result


def original_field_vectors():
    for start, end, digest in (
        (0x8012F8AC, 0x8012F97C, '6b47ed2c0d24b48fc6b56e8edb4b86a140da7a5b4ac0168bf4a1a53442681e52'),
        (0x8012FD10, 0x801300EC, '339a1365c86cebd706a6c7be2279d8fcd768b9b0b4122f6a4b09a36734cf9f3b'),
        (0x80130514, 0x8013096C, '8b1e8efceafcd8b31fc041b748115a2a6c8f2e08a3943e7f3027e7880d7f74d5'),
        (0x800C4244, 0x800C42E8, '753933deb284721faa176a42841e7ff7f9779efe7fed3a432b6fc220a30c3776'),
        (0x8012FA20, 0x8012FA5C, '5f62520db153135f0350f8fcece755e1ca46e576d59ea4b031d23be4a53f9653'),
    ):
        assert_span(start, end, digest)
    assert_main_words({
        # Player motion runs before the draw. The NPC pass emits before its motion and sprite updates.
        0x8012FD28: (0x0C04BE2B, 0x00808821),
        0x8012FE5C: (0x0C030FBC, 0x02402021),
        0x80130878: (0x0C04BE88, 0x02002021, 0x10400003, 0, 0x0C031091, 0x02402021),
        0x80130914: (0x0C04BE2B, 0x02002021),
        0x800C3EC8: (0x90450001, 0x90420000, 0x8C830014, 0xA0850003),
    })

    def advance(offset, speed):
        return max(0, offset - speed) if offset >= 0 else min(0, offset + speed)

    result = []
    options = product(('hero', 'follower', 'npc'), (0, 1, 2, 4), ((0, 0), (-8, 0), (-1, 0), (0, 8), (0, 1), (2, -2)),
                      range(4), (False, True), (False, True), (23, 255))
    for role, speed, (ox, oy), frame, auto, boost, source_x in options:
        npc = role == 'npc'
        hero_speed = speed if role == 'hero' else 2
        next_x, next_y = advance(ox, speed), advance(oy, speed)
        emitted_x, emitted_y = (ox, oy) if npc else (next_x, next_y)
        x, y = source_x * 8 + emitted_x, 360 + emitted_y
        screen_x, screen_y = x - 40 - 160, y - 240 - 120
        visible = not npc or (screen_x + 24 >= -159 and screen_x - 32 < 160
                              and screen_y + 64 >= -119 and screen_y - 64 < 120)
        pose = dict(x=x, y=y, frame=frame) if visible else None
        if emitted_x or emitted_y:
            ticks = int(visible) if npc else hero_speed * boost
        else:
            ticks = int(frame in (0, 2) or (npc and auto))
        result.append(dict(role=role, speed=speed, hero_speed=hero_speed, offset_x=ox, offset_y=oy, frame=frame,
                           auto_animate=auto, boost=boost, x=source_x * 8, next_x=next_x, next_y=next_y,
                           next_frame=(frame + ticks) % 4, remaining=1, sprite_ticks=ticks, pose=pose))
    return result


if __name__=='__main__':unittest.main()

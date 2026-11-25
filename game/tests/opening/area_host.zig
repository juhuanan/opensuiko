const std = @import("std");
const area = @import("area_host");
const callback = area.callback;
const host = area.host;
const predicate = area.predicate;
const tile = area.tile;
const transition = area.transition;
const dialogue = area.dialogue_box;
const flow = area.event_flow;
const room = area.room_flags;
const roster = area.roster_edit;
const sprite = area.sprite_slot;
const upload = area.sprite_upload;

test "wheel clock matches independent source phase arithmetic and channel order" {
    const wheel = area.wheel;
    const Case = struct { roll: u15, updates: u16, angle: u16, distance: i16, result: wheel.Outcome };
    const cases = [_]Case{
        .{ .roll = 0, .updates = 234, .angle = 49, .distance = -414, .result = .medicine },
        .{ .roll = 89, .updates = 234, .angle = 49, .distance = -414, .result = .medicine },
        .{ .roll = 90, .updates = 234, .angle = 49, .distance = -413, .result = .medicine },
        .{ .roll = 12960, .updates = 242, .angle = 188, .distance = -414, .result = .passage },
        .{ .roll = 16384, .updates = 244, .angle = 220, .distance = -412, .result = .lose_experience },
        .{ .roll = 29160, .updates = 252, .angle = 14, .distance = -414, .result = .nothing },
        .{ .roll = 32767, .updates = 254, .angle = 49, .distance = -410, .result = .medicine },
    };
    for (cases) |case| {
        var state: wheel.State = .{};
        state.start(case.roll);
        var updates: u16 = 0;
        var sample: wheel.Sample = .{};
        while (state.phase != null and updates < 300) : (updates += 1) sample = state.advance();
        try std.testing.expectEqual(case.updates, updates);
        try std.testing.expectEqual(case.angle, state.angle);
        try std.testing.expectEqual(case.distance, state.distance);
        try std.testing.expectEqual(case.result, state.result.?);
        try std.testing.expectEqual(case.angle - 1, sample.geometry_angles[0]);
    }
    var state: wheel.State = .{ .angle = 178, .visible = true };
    state.alignToCenter();
    state.restore();
    try std.testing.expectEqualSlices(u16, &.{ 179, 181 }, &state.advance().geometry_angles);
    state = .{ .angle = 359, .visible = true };
    state.restore();
    const final = state.advance();
    try std.testing.expect(final.recentered and !state.visible and state.phase == null);
    try std.testing.expectEqual(@as(u16, 361), final.geometry_angles[0]);
    try std.testing.expectEqual(@as(u16, 0), final.logical_angle);
    state.turnFor(90);
    for (0..90) |_| try std.testing.expectEqual(@as(u2, 0), state.advance().geometry_count);
    try std.testing.expect(state.phase == null and state.angle == 180);
    try std.testing.expect(!wheel.consumesExtraDraw(-32768) and !wheel.consumesExtraDraw(5));
    try std.testing.expect(wheel.consumesExtraDraw(6) and wheel.consumesExtraDraw(32767));
}

test "0x4F installs only the six live source callbacks" {
    var state: callback.State = .{};
    try std.testing.expectEqual(callback.Result{ .installed = .scan_0 }, try state.install(0));
    try std.testing.expectEqual(callback.Callback.scan_0, state.callback.?);
    try std.testing.expect(state.flags & callback.active_flag != 0);
    try std.testing.expectEqual(callback.Result{ .wait = {} }, try state.install(1));
    try std.testing.expectError(error.ScanAlreadyInstalled, state.install(2));
    state.finish();
    try std.testing.expectEqual(@as(?callback.Callback, null), state.callback);
    try std.testing.expectEqual(@as(u16, 0), state.flags & callback.active_flag);
    try std.testing.expectEqual(callback.Result{ .invalid = {} }, try state.install(1));
    try std.testing.expectEqual(callback.Result{ .installed = .scan_6 }, try state.install(6));
}

test "0x4F wait arm reports wait while the scan flag is set" {
    var state: callback.State = .{ .flags = callback.active_flag };
    try std.testing.expectEqual(callback.Result{ .wait = {} }, try state.install(1));
    state.finish();
    try std.testing.expectEqual(callback.Result{ .invalid = {} }, try state.install(1));
}

test "the area host binds every first-town subsystem model" {
    var object = tile.Object{ .variant = 0 };
    var descriptors = [_]tile.Descriptor{.{ .object = &object }};
    const draw = [_]u8{ 0x10, 0x11 };
    var state = host.Host{ .tiles = .{ .descriptors = &descriptors, .draw_by_variant = &draw } };

    try std.testing.expect(!try state.setVariant(0, .increment, 0));
    try std.testing.expectEqual(@as(u8, 1), object.variant);
    try std.testing.expectEqual(@as(?u8, 0x11), object.draw);

    try std.testing.expect(state.coordinateMatches(.x, 0, 0, .inclusive));
    try std.testing.expect(!state.coordinateMatches(.x, 1, 1, .inclusive));
    state.position = .{ .x = 45, .y = 10 };
    try std.testing.expect(state.coordinateMatches(.x, 45, 45, .inclusive));
    try std.testing.expect(!state.coordinateMatches(.x, 45, 45, .strict));

    try std.testing.expectEqualStrings("scan_0", @tagName((try state.installCallback(0)).installed));
    try state.openBox(0, 7);
    _ = try state.updateBox(0x80, 1);
    try state.loadUploadBlock(&.{ 1, 0x80, 2, 1 });
    try state.orRoomFlag(2, 0x40);
    state.party.party[0] = 6;
    try std.testing.expect(state.removePartyMember(6));
    state.beginTransition(0x80, 0x1234);
    try std.testing.expectEqual(@as(?u16, 0x1234), state.transition.callback);
}

test "typed host actions reach their models without a no-op arm" {
    var object = tile.Object{ .variant = 0 };
    var descriptors = [_]tile.Descriptor{.{ .object = &object }};
    const draw = [_]u8{ 0x10, 0x11 };
    var state = host.Host{ .tiles = .{ .descriptors = &descriptors, .draw_by_variant = &draw } };
    try state.apply(.{ .tile_variant = .{ .tile = 0, .op = .increment } });
    try std.testing.expectEqual(@as(u8, 1), object.variant);
    try state.apply(.{ .area_callback = .{ .selector = 0 } });
    try std.testing.expectEqual(callback.Callback.scan_0, state.area.callback.?);
    try state.apply(.{ .dialogue_open = .{ .style = 0, .handle = 9 } });
    try std.testing.expectEqual(@as(?u32, 9), state.box.handle);
    try state.apply(.{ .sprite_upload = &.{ 1, 0x80, 2, 1 } });
    try std.testing.expectEqual(@as(u8, 0x80), state.uploads.entries[0].kind);
    try state.apply(.{ .room_flag = .{ .id = 2, .bits = 0x40 } });
    try std.testing.expectEqual(@as(u8, 0x40), state.room_flags.values[2]);
    state.party.party[0] = 6;
    try state.apply(.{ .roster_remove = .{ .character = 6 } });
    try std.testing.expectEqual(roster.empty, state.party.party[0]);
    try state.apply(.{ .area_transition = .{ .selector = 0x80, .entry = 0x1234 } });
    try std.testing.expectEqual(@as(?u16, 0x1234), state.transition.callback);
}

test "0x0B/0x0C inclusive and 0x01/0x02 strict coordinate bounds" {
    const position = predicate.Position{ .x = 45, .y = 10 };
    try std.testing.expect(predicate.coordinate(position, .x, 45, 45, .inclusive));
    try std.testing.expect(!predicate.coordinate(position, .x, 45, 45, .strict));
    try std.testing.expect(predicate.coordinate(position, .y, 9, 11, .strict));
    try std.testing.expect(!predicate.coordinate(position, .y, 10, 11, .strict));
}

test "0x04 pressed mask and 0x09/0x0A room flag comparisons" {
    const masks = [_]u8{ 0x10, 0x40, 0x01 };
    try std.testing.expect(predicate.inputIntersects(0x0040, &masks, 1));
    try std.testing.expect(!predicate.inputIntersects(0x0040, &masks, 0));
    try std.testing.expect(!predicate.inputIntersects(0x0040, &masks, 3));
    const flags = [_]u8{ 0x00, 0x20 };
    try std.testing.expect(predicate.roomByteIntersects(&flags, 1, 0x20, true));
    try std.testing.expect(!predicate.roomByteIntersects(&flags, 1, 0x20, false));
    try std.testing.expect(!predicate.roomByteIntersects(&flags, 0, 0x20, true));
}

test "0x4D source operations select the object variant and draw byte" {
    var object = tile.Object{ .variant = 2 };
    var descriptors = [_]tile.Descriptor{.{ .object = &object }};
    const draw = [_]u8{ 0x10, 0x11, 0x12, 0x13, 0x14 };
    const table = tile.Table{ .descriptors = &descriptors, .draw_by_variant = &draw };
    try std.testing.expect(tile.resolve(&table, 0) != null);
    try std.testing.expect(tile.resolve(&table, 1) == null);

    _ = try tile.apply(&table, &descriptors[0], .increment, 0);
    try std.testing.expectEqual(@as(u8, 3), object.variant);
    try std.testing.expectEqual(@as(u8, 0x13), object.draw);
    _ = try tile.apply(&table, &descriptors[0], .decrement, 0);
    try std.testing.expectEqual(@as(u8, 2), object.variant);
    _ = try tile.apply(&table, &descriptors[0], .absolute, 4);
    try std.testing.expectEqual(@as(u8, 4), object.variant);
    try std.testing.expectEqual(@as(u8, 0x14), object.draw);
}

test "0x4D wait arm does not mutate while the object flag is set" {
    var object = tile.Object{ .variant = 1, .flags = tile.object_flag_wait };
    var descriptors = [_]tile.Descriptor{.{ .object = &object }};
    const draw = [_]u8{ 0x01, 0x02 };
    const table = tile.Table{ .descriptors = &descriptors, .draw_by_variant = &draw };
    try std.testing.expect(try tile.apply(&table, &descriptors[0], .wait, 0));
    try std.testing.expectEqual(@as(u8, 1), object.variant);
    object.flags = 0;
    try std.testing.expect(!try tile.apply(&table, &descriptors[0], .wait, 0));
    var empty = tile.Descriptor{};
    try std.testing.expectError(error.MissingAreaTileObject, tile.apply(&table, &empty, .increment, 0));
}

test "0x43 publishes a callback for 0xFF/0x80 and a menu word otherwise" {
    var state: transition.State = .{};
    state.begin(0xFF, 0x1234);
    try std.testing.expectEqual(@as(u8, 0), state.transition);
    try std.testing.expectEqual(@as(?u16, 0x1234), state.callback);
    try std.testing.expectEqual(@as(?u16, null), state.menu_word);
    try std.testing.expect(!state.collision_enabled and state.entity_flag);
    try std.testing.expectEqual(@as(u16, 1), state.driver_word);

    state.begin(0x80, 0x5678);
    try std.testing.expectEqual(@as(u8, 0x80), state.transition);
    try std.testing.expectEqual(@as(?u16, 0x5678), state.callback);

    state.begin(3, 0x9ABC);
    try std.testing.expectEqual(@as(u8, 3), state.transition);
    try std.testing.expectEqual(@as(?u16, null), state.callback);
    try std.testing.expectEqual(@as(?u16, 0x9ABC), state.menu_word);
}

test "0x05 build arm stores style with bit 0x80 and allocates a handle" {
    var box: dialogue.Box = .{};
    try box.open(0x03, 7);
    try std.testing.expectEqual(@as(u8, 0x83), box.state);
    try std.testing.expectEqual(@as(u8, 0x03), box.style);
    try std.testing.expectEqual(@as(?u32, 7), box.handle);
    try std.testing.expectError(error.DialogueBoxAlreadyOpen, box.open(1, 8));
}

test "0x05 open arm honours the changed bit and frees on no change" {
    var box: dialogue.Box = .{};
    try box.open(0, 7);
    const changed = try box.update(0x84, 2);
    try std.testing.expectEqual(@as(u8, 6), changed.state);
    try std.testing.expect(changed.draw);
    try std.testing.expect(!changed.freed);
    const unchanged = try box.update(0x01, 0);
    try std.testing.expectEqual(dialogue.idle_state, unchanged.state);
    try std.testing.expect(unchanged.freed);
    try std.testing.expectEqual(@as(?u32, null), box.handle);
    try std.testing.expectError(error.DialogueBoxNotOpen, box.update(0x80, 0));
}

test "0x2E scans forward and leaves the cursor after the match" {
    const stream = [_]u8{ 0xAA, 0x10, 0x20, 0x10, 0x30 };
    try std.testing.expectEqual(@as(?usize, 2), flow.scanForward(&stream, 1, 0x10));
    try std.testing.expectEqual(@as(?usize, 4), flow.scanForward(&stream, 3, 0x10));
    try std.testing.expectEqual(@as(?usize, null), flow.scanForward(&stream, 1, 0x99));
}

test "0x2F resolves default and selected label displacements" {
    const stream = [_]u8{ 0x03, 0x20, 0x30, 0x10, 0x20, 0x30 };
    try std.testing.expectEqual(@as(usize, 2), try flow.switchTarget(&stream, 0, 0));
    try std.testing.expectEqual(@as(usize, 2), try flow.switchTarget(&stream, 0, 1));
    try std.testing.expectEqual(@as(usize, 5), try flow.switchTarget(&stream, 0, 2));
    try std.testing.expectEqual(@as(usize, 6), try flow.switchTarget(&stream, 0, 3));
    try std.testing.expectError(error.MissingSelector, flow.switchTarget(&.{}, 0, 0));
    try std.testing.expectError(error.MissingLabel, flow.switchTarget(&stream, 0, 4));
}

test "0x16 ORs the per-room byte and refuses out-of-range ids" {
    var state: room.State = .{};
    try state.orByte(3, 0x40);
    try state.orByte(3, 0x01);
    try std.testing.expectEqual(@as(u8, 0x41), state.values[3]);
    try std.testing.expectEqual(@as(u8, 0), state.values[4]);
    try std.testing.expectError(error.RoomFlagOutOfRange, state.orByte(room.bytes, 1));
    state.clear();
    try std.testing.expectEqual(@as(u8, 0), state.values[3]);
}

test "0x16 reset clears the whole 20-byte region" {
    var state: room.State = .{};
    for (0..room.bytes) |index| try state.orByte(@intCast(index), 0xFF);
    state.clear();
    for (state.values) |value| try std.testing.expectEqual(@as(u8, 0), value);
}

test "0x20 removes the exact party occupant and syncs formation" {
    var state: roster.State = .{ .party = .{ 6, 1, 2, roster.empty, roster.empty, roster.empty } };
    try std.testing.expectEqual(@as(u8, 3), state.count());
    try std.testing.expectEqual(@as(?usize, 1), state.select(1));
    try std.testing.expect(state.remove(1));
    try std.testing.expectEqual(@as(usize, 1), state.syncs);
    try std.testing.expectEqual(@as(?usize, null), state.select(1));
    try std.testing.expect(!state.remove(1));
    try std.testing.expectEqual(@as(usize, 1), state.syncs);
    try std.testing.expect(!state.remove(roster.empty));
}

test "0x00 spawns once and waits while the slot flag is set" {
    var state: sprite.State = .{};
    try std.testing.expect(!try state.spawn(0, 10, 20, 4, 2));
    try std.testing.expectEqual(@as(?u32, 1), state.slots[0].handle);
    try std.testing.expectEqual(@as(i16, 80 - 0x96), state.slots[0].screen_x);
    try std.testing.expectEqual(@as(u16, 12), state.slots[0].width);
    try state.flagSet(0);
    try std.testing.expect(try state.spawn(0, 0, 0, 0, 0));
    try std.testing.expectEqual(@as(u16, 0x0001), state.flags);
    try state.release(0);
    try std.testing.expectEqual(@as(?u32, null), state.slots[0].handle);
    try std.testing.expectEqual(@as(u16, 0), state.flags);
}

test "0x01 uses bit 2 for nonzero slots and rejects out-of-range slots" {
    var state: sprite.State = .{};
    try state.flagSet(3);
    try std.testing.expectEqual(@as(u8, 2), state.slots[3].flags);
    try std.testing.expectEqual(@as(u16, 0x0002), state.flags);
    try std.testing.expectError(error.SpriteSlotOutOfRange, state.flagSet(sprite.slots));
}

test "0x06 loads typed slots and fills the rest with 0xFF/0" {
    const block = try upload.Block.load(&.{ 2, 0x80, 3, 1, 0x04, 5, 0 });
    try std.testing.expectEqual(@as(u8, 0x80), block.entries[0].kind);
    try std.testing.expectEqual(@as(u8, 3), block.entries[0].parameter);
    try std.testing.expectEqual(@as(u8, 1), block.entries[0].enable);
    try std.testing.expectEqual(@as(u8, 0x04), block.entries[1].kind);
    try std.testing.expectEqual(@as(u8, 0xFF), block.entries[2].kind);
    try std.testing.expectEqual(@as(u8, 0), block.entries[2].enable);
    try std.testing.expectEqual(upload.initial_countdown, block.countdown);
}

test "0x06 rejects bad counts and lengths" {
    try std.testing.expectError(error.MissingSpriteUploadCount, upload.Block.load(&.{}));
    try std.testing.expectError(error.TooManySpriteUploads, upload.Block.load(&.{9}));
    try std.testing.expectError(error.InvalidSpriteUploadLength, upload.Block.load(&.{ 1, 0x80, 2 }));
}

test "wheel room retains its draw count and last geometry across inactive updates" {
    var state: area.wheel.Room = .{};
    state.starts = 4;
    try std.testing.expectEqual(@as(u2, 1), state.startDraws());
    state.start(12960);
    try std.testing.expectEqual(@as(i16, 5), state.starts);
    try std.testing.expectEqual(@as(u2, 2), state.startDraws());
    while (state.clock.phase != null) state.advance();
    try state.validate();
    try std.testing.expectEqual(area.wheel.Outcome.passage, state.clock.result.?);
    try std.testing.expectEqual(@as(u16, 187), state.geometry_angle);
    state.advance();
    try std.testing.expectEqual(@as(u16, 187), state.geometry_angle);
    try std.testing.expectEqual(@as(u2, 0), state.sample.geometry_count);
    const bytes = try std.json.Stringify.valueAlloc(std.testing.allocator, state, .{});
    defer std.testing.allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(area.wheel.Room, std.testing.allocator, bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqualDeep(state, parsed.value);
    state.clock.turnFor(0);
    state.advance();
    try std.testing.expect(state.clock.phase == null);
    try std.testing.expectEqual(@as(u16, 2), state.clock.angle);
    state.starts = 32767;
    try std.testing.expectEqual(@as(u2, 1), state.startDraws());
    state.start(0);
    try std.testing.expectEqual(@as(i16, -32768), state.starts);
}

test "wheel visual keeps orbital geometry separate from current map rotation" {
    var state: area.wheel.Room = .{};
    const cases = [_]struct { angle: u16, primary: [2]i16, basis: [2]i16 }{
        .{ .angle = 0, .primary = .{ -168, -48 }, .basis = .{ 0, 4096 } },
        .{ .angle = 90, .primary = .{ -248, -128 }, .basis = .{ 4096, 0 } },
        .{ .angle = 180, .primary = .{ -168, -208 }, .basis = .{ 0, -4096 } },
        .{ .angle = 270, .primary = .{ -88, -128 }, .basis = .{ -4096, 0 } },
    };
    for (cases) |case| {
        state.clock.angle = case.angle;
        state.map_angle = case.angle;
        state.geometry_angle = case.angle;
        const visual = state.visual();
        try std.testing.expectEqual(case.primary, visual.primary_offset);
        try std.testing.expectEqual(@as(i16, 48), visual.auxiliary_offset[1] - visual.primary_offset[1]);
        try std.testing.expectEqual(case.basis, [2]i16{ visual.map_sine_q12, visual.map_cosine_q12 });
    }
    state.clock.angle = 359;
    state.clock.restore();
    state.advance();
    const restored = state.visual();
    try std.testing.expectEqual(@as(u16, 0), restored.map_angle_degrees);
    try std.testing.expectEqual([2]i16{ -169, -49 }, restored.primary_offset);
    try std.testing.expect(!restored.transformed_map);
    state.start(12960);
    while (state.clock.phase != null) state.advance();
    state.clock.alignToCenter();
    while (state.clock.alignment != null) state.advance();
    const aligned = state.visual();
    try std.testing.expectEqual(@as(u16, 180), state.clock.angle);
    try std.testing.expectEqual(@as(u16, 188), aligned.map_angle_degrees);
    try std.testing.expectEqual([2]i16{ -168, -208 }, aligned.primary_offset);
    const held = aligned.primary_offset;
    state.clock.turnFor(90);
    for (0..90) |_| state.advance();
    const timed = state.visual();
    try std.testing.expectEqual(held, timed.primary_offset);
    try std.testing.expectEqual(@as(u16, 180), timed.map_angle_degrees);
    try std.testing.expectEqual(@as(i16, -4096), timed.map_cosine_q12);
    try std.testing.expect(timed.transformed_map);
}

test "wheel map wraps source tiles and floors rotated viewport vertices" {
    const Projection = area.wheel.MapProjection;
    for ([_][2]i32{ .{ 16, 80 }, .{ 17, 81 }, .{ 381, 509 }, .{ -3, -5 }, .{ 384, 512 } }) |origin| {
        const projection = try Projection.init(.{ 384, 512 }, origin, 90);
        var fragments = projection.fragments();
        var count: usize = 0;
        var pixels: usize = 0;
        var y: i32 = 0;
        while (y < 240) {
            const height = @min(16 - @mod(origin[1] + y, 16), 240 - y);
            var x: i32 = 0;
            while (x < 320) {
                const width = @min(16 - @mod(origin[0] + x, 16), 320 - x);
                const fragment = fragments.next().?;
                try std.testing.expectEqual(@mod(origin[0] + x, 384), fragment.source.x);
                try std.testing.expectEqual(@mod(origin[1] + y, 512), fragment.source.y);
                try std.testing.expectEqual(width, fragment.source.w);
                try std.testing.expectEqual(height, fragment.source.h);
                const corners = [4][2]i32{ .{ x, y }, .{ x + width, y }, .{ x, y + height }, .{ x + width, y + height } };
                for (corners, fragment.vertices) |point, vertex| {
                    try std.testing.expectEqual(280 - point[1], vertex.x);
                    try std.testing.expectEqual(point[0] - 40, vertex.y);
                }
                pixels += @intCast(width * height);
                count += 1;
                x += width;
            }
            y += height;
        }
        try std.testing.expect(fragments.next() == null);
        try std.testing.expectEqual(@as(usize, 320 * 240), pixels);
        try std.testing.expectEqual(@as(usize, if (@mod(origin[0], 16) == 0) 300 else 336), count);
    }
    const angled = try Projection.init(.{ 384, 512 }, .{ 0, 0 }, 37);
    const point = angled.project(159, 120);
    try std.testing.expectEqual(@as(i32, 159), point.x);
    try std.testing.expectEqual(@as(i32, 119), point.y);
    try std.testing.expectError(error.InvalidWheelMap, Projection.init(.{ 383, 512 }, .{ 0, 0 }, 0));
    try std.testing.expectError(error.InvalidWheelMap, Projection.init(.{ 384, 512 }, .{ 0, 0 }, 360));
}

test "wheel actor graphics retain stationary anchors and accept later source writers" {
    var wheel: area.wheel.Room = .{};
    var graphics = area.wheel.ActorGraphics.init(1, .{ .x = 152, .y = 192 });
    try std.testing.expectEqual(area.wheel.MapPoint{ .x = 154, .y = 240 }, graphics.auxiliary);
    try std.testing.expectEqualDeep([4]area.wheel.MapPoint{ .{ .x = 151, .y = 204 }, .{ .x = 166, .y = 204 }, .{ .x = 151, .y = 196 }, .{ .x = 166, .y = 196 } }, graphics.shadowPoints());
    wheel.clock.visible = true;
    graphics.advance(wheel, .{ .x = 9, .y = 10 }, 0);
    try std.testing.expectEqual(area.wheel.MapPoint{ .x = 152, .y = 192 }, graphics.primary);
    graphics.advance(wheel, .{ .x = 152, .y = 190 }, -2);
    try std.testing.expectEqual(@as(i32, 190), graphics.primary.y);
    graphics.advance(wheel, .{ .x = 152, .y = 184 }, 0);
    try std.testing.expectEqual(@as(i32, 190), graphics.primary.y);
    wheel.geometry_angle = 90;
    wheel.sample.geometry_count = 1;
    graphics.advance(wheel, .{ .x = 152, .y = 182 }, -2);
    try std.testing.expectEqual(area.wheel.MapPoint{ .x = 72, .y = 112 }, graphics.primary);
    try std.testing.expectEqual(area.wheel.MapPoint{ .x = 72, .y = 160 }, graphics.auxiliary);
    wheel.sample.geometry_count = 0;
    wheel.clock.visible = false;
    graphics.advance(wheel, .{ .x = 152, .y = 184 }, 0);
    try std.testing.expectEqual(area.wheel.MapPoint{ .x = 152, .y = 184 }, graphics.primary);
    const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, graphics, .{});
    defer std.testing.allocator.free(encoded);
    const parsed = try std.json.parseFromSlice(area.wheel.ActorGraphics, std.testing.allocator, encoded, .{});
    defer parsed.deinit();
    try std.testing.expectEqualDeep(graphics, parsed.value);
}

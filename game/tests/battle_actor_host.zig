const std = @import("std");
const a = std.testing.allocator;
const vm = @import("battle").actor_program;
const host = @import("battle").actor_host;
const frames = [_]host.Frame{ .{ .pose = 0, .updates = 2 }, .{ .pose = 1, .updates = 1, .attachment = .{ -4, 3 } } };
const clips = [_]host.Clip{ .{ .id = 0, .advances = true, .loop = true, .frames = frames[0..1] }, .{ .id = 1, .advances = true, .loop = false, .frames = &frames } };
const resource = host.Resource{ .id = "actor", .pose_count = 2, .clips = &clips };

const RabbitSource = struct {
    ordinary: @import("battle").counter.MeleeEnemy,
    programs: vm.Packet,
    animations: host.Resources,
    projectile: struct { owner_program: []const u8, child_program: []const u8, resource: []const u8, animation: u16, position_z_q12: i32, spin_step: i16 },
    return_cases: []const struct {
        first: [3]i32,
        home: [3]i32,
        delta: [3]i32,
        hops: []const struct {
            start: [3]i32,
            destination: [3]i32,
            velocity: [3]i32,
            acceleration: [3]i32,
            samples: []const struct { position: [3]i32, velocity: [3]i32 },
        },
    },
};

test "Rabbit source projectile scripts publish source clocks and spin without shared aiming" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const data = try std.json.parseFromSlice(RabbitSource, arena.allocator(), @embedFile("fixtures/enemy_rabbit_source.json"), .{ .ignore_unknown_fields = true });
    const source = data.value;
    const packet = try rabbitOrdinaryPacket(arena.allocator(), source);
    var actors = [_]host.Actor{
        try host.Actor.init(packet.animations.find("hero").?, .{ 128 * 4096, 13 * 4096, 7 * 4096 }),
        try host.Actor.init(packet.animations.find("killer_rabbit").?, .{ -128 * 4096, 0, 0 }),
    };
    actors[0].position_q12 = .{ 71 * 4096, -9 * 4096, 0 };
    actors[1].position_q12 = .{ -117 * 4096, 11 * 4096, -37 * 4096 };
    var children: [1]?host.Actor = @splat(null);
    const RabbitProjectileObserver = struct {
        fn command(_: *anyopaque, _: u16, request: vm.Command, _: bool) !bool {
            if (request != .sound) return error.UnexpectedRabbitCommand;
            return true;
        }
    };
    var context: u8 = 0;
    var runtime = host.Runtime{ .actors = &actors, .auxiliary = &children, .library = packet.library(), .camera_angles = .{ 101, 202, 303 }, .external = .{ .context = &context, .command = RabbitProjectileObserver.command } };
    try runtime.dispatch(1, 0, packet.programs.find(source.projectile.owner_program).?);
    try std.testing.expect(try runtime.spawn(1, .{ .program = source.projectile.child_program, .resource = source.projectile.resource, .animation = source.projectile.animation, .owner = .self, .home = .spawn, .draw_record = true, .offset = .{ 0, 0, 0 } }, null));
    // The source initializer captures target HOME and uses absolute Z, before the first actor sweep.
    children[0].?.home_q12 = actors[0].home_q12;
    children[0].?.position_q12[2] = source.projectile.position_z_q12;
    children[0].?.draw_angles = .{ 17, -29, 32512 };
    try std.testing.expect(!children[0].?.visible);
    const first_position = children[0].?.position_q12;
    var contact: ?u16 = null;
    var returned: ?u16 = null;
    var retired: ?u16 = null;
    var finished: ?u16 = null;
    var spins: i32 = 0;
    for (1..130) |update| {
        try runtime.stepActor(1);
        if (children[0] != null) {
            try runtime.stepActor(2);
            if (children[0]) |child| {
                if (child.projectile == .rabbit_spin) {
                    spins += 1;
                    try std.testing.expectEqualDeep([2]i16{ 17, -29 }, child.draw_angles[0..2].*);
                    try std.testing.expectEqual(@as(i16, @truncate(32512 + spins * 512)), child.draw_angles[2]);
                    try std.testing.expectEqual(@as(i16, 0), child.shared_value);
                } else {
                    try std.testing.expectEqualDeep(first_position, child.position_q12);
                }
                if (child.movement) |move| {
                    if (actors[1].signals & 2 == 0) try std.testing.expectEqualDeep([3]i32{ actors[0].home_q12[0], actors[0].home_q12[1], -24 * 4096 }, move.destination);
                }
            } else retired = @intCast(update);
        }
        if (contact == null and actors[1].signals & 2 != 0) contact = @intCast(update);
        if (returned == null and actors[1].signals & 4 != 0) returned = @intCast(update);
        if (finished == null and actors[1].highlights == 0) finished = @intCast(update);
    }
    try std.testing.expectEqual(@as(?u16, 63), contact);
    try std.testing.expectEqual(@as(?u16, 94), retired);
    try std.testing.expectEqual(@as(?u16, 93), returned);
    try std.testing.expectEqual(@as(?u16, 117), finished);
    try std.testing.expect(children[0] == null and actors[1].machine.?.halted);
    const Retained = struct { impact_tick: ?u16 = null, release_tick: ?u16 = null, duration: ?u16 = null };
    const retained = try std.json.parseFromSlice([]const Retained, arena.allocator(), @embedFile("fixtures/world_rabbit_projectile.json"), .{ .ignore_unknown_fields = true });
    var matched: usize = 0;
    for (retained.value) |row| if (row.impact_tick != null) {
        try std.testing.expectEqual(row.impact_tick.?, contact.? + 1);
        try std.testing.expectEqual(row.release_tick.?, returned.? + 1);
        try std.testing.expectEqual(row.duration, finished);
        matched += 1;
    };
    try std.testing.expect(matched > 0);
}

test "Rabbit source projectile spin restores and refuses an overlapping callback" {
    var actors = [_]host.Actor{try host.Actor.init(resource, .{ 0, 0, 0 })};
    var runtime = host.Runtime{ .actors = &actors, .camera_angles = .{ 111, 222, 333 } };
    const install = [_]vm.Instruction{ .{ .command = .{ .effect = .{ .id = "rabbit_projectile_spin", .binding = .self } } }, .{ .halt = {} } };
    try runtime.dispatch(0, null, .{ .id = "spin", .instructions = &install });
    actors[0].draw_angles = .{ 12, -34, 32512 };
    try runtime.stepActor(0);
    const bytes = try std.json.Stringify.valueAlloc(a, actors[0], .{});
    defer a.free(bytes);
    const restored = try std.json.parseFromSlice(host.Actor, a, bytes, .{});
    defer restored.deinit();
    var copies = [_]host.Actor{restored.value};
    var replay = host.Runtime{ .actors = &copies, .camera_angles = .{ -111, -222, -333 } };
    for (0..130) |_| {
        try runtime.stepActor(0);
        try replay.stepActor(0);
        try std.testing.expectEqualDeep(actors[0].draw_angles, copies[0].draw_angles);
        try std.testing.expectEqualDeep([2]i16{ 12, -34 }, actors[0].draw_angles[0..2].*);
        try std.testing.expectEqualDeep([3]i32{ 0, 0, 0 }, actors[0].position_q12);
        try std.testing.expectEqual(@as(i16, 0), actors[0].shared_value);
    }
    try std.testing.expectError(error.ActorEffectAlreadyActive, runtime.dispatch(0, null, .{ .id = "spin", .instructions = &install }));
}

test "Rabbit source return follows every independent hop sample and preserves division residues" {
    const parsed = try std.json.parseFromSlice(RabbitSource, a, @embedFile("fixtures/enemy_rabbit_source.json"), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const data = parsed.value;
    const install = [_]vm.Instruction{ .{ .command = .{ .effect = .{ .id = "rabbit_return", .binding = .self } } }, .{ .halt = {} } };
    for (data.return_cases) |row| {
        var actors = [_]host.Actor{try host.Actor.init(data.animations.resources[0], row.home)};
        actors[0].position_q12 = row.first;
        actors[0].shared_value = 1;
        var runtime = host.Runtime{ .actors = &actors };
        try runtime.dispatch(0, null, .{ .id = "install", .instructions = &install });
        try runtime.stepActor(0);
        try std.testing.expectEqualDeep(row.delta, actors[0].rabbit_return.?.delta_q12);
        try std.testing.expectEqual(@as(i16, 2), actors[0].shared_value);
        for (row.hops) |hop| {
            actors[0].shared_value = 3;
            try runtime.stepActor(0);
            try std.testing.expectEqualDeep(hop.start, actors[0].position_q12);
            try std.testing.expectEqualDeep(hop.destination, actors[0].movement.?.destination);
            try std.testing.expectEqualDeep(hop.velocity, actors[0].velocity_q12);
            try std.testing.expectEqualDeep(hop.acceleration, actors[0].acceleration_q12);
            for (hop.samples) |sample| {
                try runtime.stepActor(0);
                try std.testing.expectEqualDeep(sample.position, actors[0].position_q12);
                try std.testing.expectEqualDeep(sample.velocity, actors[0].velocity_q12);
            }
            try std.testing.expect(actors[0].movement == null);
        }
        actors[0].shared_value = 3;
        try std.testing.expectError(error.InvalidRabbitReturnState, runtime.stepActor(0));
        actors[0].shared_value = 4;
        try runtime.stepActor(0);
        try std.testing.expect(actors[0].rabbit_return == null);
        try std.testing.expectEqualDeep(row.hops[2].destination, actors[0].position_q12);
    }
}

test "Rabbit source return persists through JSON and keeps absent callback serialization unchanged" {
    const parsed = try std.json.parseFromSlice(RabbitSource, a, @embedFile("fixtures/enemy_rabbit_source.json"), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const data = parsed.value;
    const row = data.return_cases[1];
    var actors = [_]host.Actor{try host.Actor.init(data.animations.resources[0], row.home)};
    const empty = try std.json.Stringify.valueAlloc(a, actors[0], .{});
    defer a.free(empty);
    try std.testing.expect(std.mem.indexOf(u8, empty, "rabbit_return") == null);
    var invalid = actors;
    invalid[0].rabbit_return = .{};
    invalid[0].shared_value = 3;
    var invalid_runtime = host.Runtime{ .actors = &invalid };
    try std.testing.expectError(error.InvalidRabbitReturnState, invalid_runtime.stepActor(0));
    actors[0].position_q12 = row.first;
    actors[0].shared_value = 1;
    const install = [_]vm.Instruction{ .{ .command = .{ .effect = .{ .id = "rabbit_return", .binding = .self } } }, .{ .halt = {} } };
    var runtime = host.Runtime{ .actors = &actors };
    try runtime.dispatch(0, null, .{ .id = "install", .instructions = &install });
    const machine = actors[0].machine;
    try std.testing.expectError(error.ActorEffectAlreadyActive, runtime.dispatch(0, null, .{ .id = "install", .instructions = &install }));
    actors[0].machine = machine;
    try runtime.stepActor(0);
    actors[0].shared_value = 3;
    try runtime.stepActor(0);
    for (0..5) |_| try runtime.stepActor(0);
    const bytes = try std.json.Stringify.valueAlloc(a, actors[0], .{});
    defer a.free(bytes);
    const restored = try std.json.parseFromSlice(host.Actor, a, bytes, .{});
    defer restored.deinit();
    var copies = [_]host.Actor{restored.value};
    var replay = host.Runtime{ .actors = &copies };
    for (0..5) |_| {
        try runtime.stepActor(0);
        try replay.stepActor(0);
        try std.testing.expectEqualDeep(actors[0].position_q12, copies[0].position_q12);
        try std.testing.expectEqualDeep(actors[0].velocity_q12, copies[0].velocity_q12);
        try std.testing.expectEqualDeep(actors[0].rabbit_return, copies[0].rabbit_return);
    }
    try std.testing.expectEqualDeep(row.hops[0].destination, copies[0].position_q12);
}

fn rabbitOrdinaryPacket(alloc: std.mem.Allocator, data: RabbitSource) !@import("battle").counter.Packet {
    const bundle = try host.loadBundle(alloc, @embedFile("fixtures/journey_unites_actor_library.json"));
    const packet = bundle.value.counterPacket().?;
    try std.testing.expectEqualStrings(data.ordinary.attack_program, packet.meleeEnemy(data.ordinary.id).?.attack_program);
    return packet;
}

test "Rabbit source projectile allocation restores failed startup and captures source placement" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    const data = try std.json.parseFromSlice(RabbitSource, alloc, @embedFile("fixtures/enemy_rabbit_source.json"), .{ .ignore_unknown_fields = true });
    const Counter = @import("battle").counter;
    const packet = try rabbitOrdinaryPacket(alloc, data.value);
    var actors = [_]host.Actor{
        try host.Actor.init(packet.animations.find("hero").?, .{ 128 * 4096, 13 * 4096, 7 * 4096 }),
        try host.Actor.init(packet.animations.find("killer_rabbit").?, .{ -128 * 4096, 0, 0 }),
    };
    actors[0].position_q12 = .{ 71 * 4096, -9 * 4096, 0 };
    actors[1].position_q12 = .{ -117 * 4096, 11 * 4096, -37 * 4096 };
    actors[1].signals = 0x4242;
    var runtime = host.Runtime{ .actors = &actors, .library = packet.library() };
    const before = actors;
    try std.testing.expectError(error.NoProjectileActor, Counter.Action.beginFor(packet, &runtime, 1, 0, .projectile));
    try std.testing.expectEqualDeep(before, actors);
    var children: [2]?host.Actor = @splat(null);
    runtime.auxiliary = &children;
    const programs = try alloc.dupe(vm.Program, packet.programs.programs);
    var broken = packet;
    broken.programs.programs = programs;
    const invalid = [_]vm.Instruction{ .{ .command = .{ .animation = 65535 } }, .{ .halt = {} } };
    for (programs) |*program| if (std.mem.eql(u8, program.id, data.value.projectile.child_program)) {
        program.instructions = &invalid;
    };
    try std.testing.expectError(error.MissingActorAnimation, Counter.Action.beginFor(broken, &runtime, 1, 0, .projectile));
    try std.testing.expectEqualDeep(before, actors);
    try std.testing.expectEqualDeep([2]?host.Actor{ null, null }, children);
    const unknown_effect = [_]vm.Instruction{ .{ .command = .{ .effect = .{ .id = "invalid_rabbit_callback", .binding = .self } } }, .{ .halt = {} } };
    for (programs) |*program| if (std.mem.eql(u8, program.id, data.value.projectile.child_program)) {
        program.instructions = &unknown_effect;
    };
    try std.testing.expectError(error.UnsupportedActorCommand, Counter.Action.beginFor(broken, &runtime, 1, 0, .projectile));
    try std.testing.expectEqualDeep(before, actors);
    try std.testing.expectEqualDeep([2]?host.Actor{ null, null }, children);
    _ = try Counter.Action.beginFor(packet, &runtime, 1, 0, .projectile);
    try std.testing.expect(children[0] == null and children[1] != null);
    const child = children[1].?;
    try std.testing.expectEqualDeep(actors[0].home_q12, child.home_q12);
    try std.testing.expectEqualDeep([3]i32{ -117 * 4096, 11 * 4096, -81920 }, child.position_q12);
    try std.testing.expectEqual(@as(?u16, 1), child.owner);
    try std.testing.expect(child.animation == 16 and !child.visible and child.has_draw_record);
    try std.testing.expectEqual(@as(u16, 0), actors[1].signals);
}

test "Rabbit source ordinary action records contact return and complete actor release" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const data = try std.json.parseFromSlice(RabbitSource, arena.allocator(), @embedFile("fixtures/enemy_rabbit_source.json"), .{ .ignore_unknown_fields = true });
    const Counter = @import("battle").counter;
    const packet = try rabbitOrdinaryPacket(arena.allocator(), data.value);
    var actors = [_]host.Actor{
        try host.Actor.init(packet.animations.find("hero").?, .{ 128 * 4096, 0, 0 }),
        try host.Actor.init(packet.animations.find("killer_rabbit").?, .{ -128 * 4096, 0, 0 }),
    };
    var children: [17]?host.Actor = @splat(null);
    const RabbitSoundObserver = struct {
        fn command(_: *anyopaque, _: u16, request: vm.Command, _: bool) !bool {
            if (request != .sound) return error.UnexpectedRabbitCommand;
            return true;
        }
    };
    var context: u8 = 0;
    var runtime = host.Runtime{ .actors = &actors, .auxiliary = &children, .library = packet.library(), .external = .{ .context = &context, .command = RabbitSoundObserver.command } };
    var action = try Counter.Action.beginFor(packet, &runtime, 1, 0, .ordinary_hit);
    var contact: ?u16 = null;
    var returning: ?u16 = null;
    var unlocked: ?u16 = null;
    for (1..180) |update| {
        try action.advance(packet, &runtime);
        if (action.stage == .contact) {
            contact = @intCast(update);
            try action.acknowledgeContact(packet, &runtime);
        }
        if (action.returnReady(runtime)) {
            returning = @intCast(update);
            try action.beginReturn(packet, &runtime);
        }
        for (0..actors.len) |actor| try runtime.stepActor(@intCast(actor));
        for (0..children.len) |slot| if (children[slot] != null) try runtime.stepActor(@intCast(actors.len + slot));
        if (returning != null and unlocked == null and actors[1].highlights == 0) unlocked = @intCast(update);
    }
    try std.testing.expectEqual(@as(?u16, 79), contact);
    try std.testing.expectEqual(@as(?u16, 99), returning);
    try std.testing.expectEqual(@as(?u16, 134), unlocked);
    const Retained = struct { impact_tick: ?u16 = null, return_tick: ?u16 = null, duration: ?u16 = null };
    const retained = try std.json.parseFromSlice([]const Retained, arena.allocator(), @embedFile("fixtures/world_rabbit_ordinary.json"), .{ .ignore_unknown_fields = true });
    var matched: usize = 0;
    for (retained.value) |row| if (row.return_tick != null and row.return_tick.? == 99) {
        try std.testing.expectEqual(row.impact_tick, contact);
        try std.testing.expectEqual(row.return_tick, returning);
        try std.testing.expectEqual(row.duration, unlocked);
        matched += 1;
    };
    try std.testing.expect(matched > 0 and action.stage == .released);
    for (children) |child| try std.testing.expect(child == null);
    try std.testing.expect(actors[0].machine.?.halted and actors[1].machine.?.halted and actors[1].rabbit_return == null);
}

const CommanderSource = struct {
    binding: @import("battle").commander.Binding,
    programs: vm.Packet,
    animations: host.Resources,
    ordered_ally: @import("battle").counter.Bindings,
};
const CommanderObserver = struct {
    update: u16 = 0,
    status_at: ?u16 = null,
    sounds: usize = 0,
    fn command(raw: *anyopaque, actor: u16, request: vm.Command, _: bool) !bool {
        const self: *@This() = @ptrCast(@alignCast(raw));
        switch (request) {
            .sound => |id| {
                try std.testing.expect((actor == 1 and id == 1383) or (actor == 0 and id == 1306));
                self.sounds += 1;
            },
            .status => |attempt| {
                try std.testing.expectEqual(@as(u16, 0), actor);
                try std.testing.expectEqual(.sleep, attempt.kind);
                try std.testing.expectEqual(@as(u8, 30), attempt.threshold_percent);
                try std.testing.expect(self.status_at == null);
                self.status_at = self.update;
            },
            else => return error.UnexpectedCommanderCommand,
        }
        return true;
    }
};

test "Commander source solo action uses the shared child signal and complete recipient lifecycle" {
    const parsed = try std.json.parseFromSlice(CommanderSource, a, @embedFile("fixtures/enemy_order_source.json"), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const data = parsed.value;
    try data.programs.validate();
    try data.animations.validate();
    var actors = [_]host.Actor{ try host.Actor.init(data.animations.find("hero").?, .{ 128 * 4096, 0, 0 }), try host.Actor.init(data.animations.find("beast_commander").?, .{ -128 * 4096, 0, 0 }) };
    var children: [1]?host.Actor = @splat(null);
    var observer: CommanderObserver = .{};
    var runtime = host.Runtime{ .actors = &actors, .auxiliary = &children, .library = .{ .programs = data.programs, .resources = data.animations }, .external = .{ .context = &observer, .command = CommanderObserver.command } };
    var action = try @import("battle").commander.Action.begin(data.binding, &runtime, 1, 0);
    var born: ?u16 = null;
    var released: ?u16 = null;
    var target_done: ?u16 = null;
    var child_gone: ?u16 = null;
    var reaction: ?u16 = null;
    for (1..144) |update| {
        observer.update = @intCast(update);
        const event = try action.advance(data.binding, &runtime);
        if (event != .none) {
            try std.testing.expectEqual(.recipient, event);
            try std.testing.expect(reaction == null);
            reaction = @intCast(update);
        }
        for (0..2) |actor| try runtime.stepActor(@intCast(actor));
        if (children[0] != null) {
            if (born == null) {
                born = @intCast(update);
                try std.testing.expectEqualDeep(actors[0].home_q12, children[0].?.home_q12);
                try std.testing.expect(children[0].?.color == null);
            }
            try runtime.stepActor(2);
            if (children[0] == null) child_gone = @intCast(update);
        }
        if (released == null and actors[1].released) released = @intCast(update);
        if (target_done == null and actors[0].machine != null and actors[0].machine.?.halted) target_done = @intCast(update);
    }
    try std.testing.expectEqual(@as(?u16, 24), born);
    try std.testing.expectEqual(@as(?u16, 85), reaction);
    try std.testing.expectEqual(@as(?u16, 85), child_gone);
    try std.testing.expectEqual(@as(?u16, 101), released);
    try std.testing.expectEqual(@as(?u16, 120), observer.status_at);
    try std.testing.expectEqual(@as(?u16, 130), target_done);
    try std.testing.expectEqual(@as(usize, 2), observer.sounds);
    try std.testing.expect(actors[0].highlights == 0 and actors[1].highlights == 0 and children[0] == null);
    try std.testing.expectEqualDeep(actors[0].home_q12, actors[0].position_q12);
}

test "Commander source order emits one launch before owner release and validates its bindings" {
    const parsed = try std.json.parseFromSlice(CommanderSource, a, @embedFile("fixtures/enemy_order_source.json"), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const data = parsed.value;
    var actors = [_]host.Actor{ try host.Actor.init(data.animations.find("hero").?, .{ 128 * 4096, 0, 0 }), try host.Actor.init(data.animations.find("beast_commander").?, .{ -128 * 4096, 0, 0 }) };
    var runtime = host.Runtime{ .actors = &actors, .library = .{ .programs = data.programs, .resources = data.animations } };
    const Commander = @import("battle").commander;
    var invalid = data.binding;
    invalid.order_program = "missing";
    try std.testing.expectError(error.InvalidEnemyOrderBinding, Commander.Action.begin(invalid, &runtime, 1, null));
    invalid = data.binding;
    invalid.selection_delay = 59;
    try std.testing.expectError(error.InvalidEnemyOrderBinding, Commander.Action.begin(invalid, &runtime, 1, null));
    try std.testing.expectError(error.InvalidActorBinding, Commander.Action.begin(data.binding, &runtime, 0, null));
    try std.testing.expectError(error.InvalidActorBinding, Commander.Action.begin(data.binding, &runtime, 1, 1));
    try std.testing.expect(actors[1].machine == null);
    var action = try Commander.Action.begin(data.binding, &runtime, 1, null);
    var launched: ?u16 = null;
    var released: ?u16 = null;
    for (1..150) |update| {
        const event = try action.advance(data.binding, &runtime);
        if (event != .none) {
            try std.testing.expectEqual(.orders, event);
            try std.testing.expect(launched == null);
            launched = @intCast(update);
        }
        try runtime.stepActor(1);
        if (released == null and actors[1].released) released = @intCast(update);
    }
    try std.testing.expectEqual(@as(?u16, 12), launched);
    try std.testing.expectEqual(@as(?u16, 142), released);
    try std.testing.expect(actors[1].machine.?.halted and actors[1].highlights == 0);
    try std.testing.expect(actors[0].machine == null);
}

test "Commander source zero through three ally orders share ordinary actors without the acknowledgement flag" {
    const parsed = try std.json.parseFromSlice(CommanderSource, a, @embedFile("fixtures/enemy_order_source.json"), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const data = parsed.value;
    const Counter = @import("battle").counter;
    const packet = Counter.Packet{ .schema = "suikoden-counter-actors/3", .programs = data.programs, .animations = data.animations, .defenders = data.ordered_ally.defenders, .enemies = data.ordered_ally.enemies, .parries = data.ordered_ally.parries, .melee = data.ordered_ally.melee };
    try packet.validate();
    const OrderObserver = struct {
        update: u16 = 0,
        statuses: [3]?u16 = @splat(null),
        sounds: usize = 0,
        fn command(raw: *anyopaque, actor: u16, request: vm.Command, _: bool) !bool {
            const self: *@This() = @ptrCast(@alignCast(raw));
            switch (request) {
                .sound => |id| {
                    try std.testing.expect((actor < 3 and id == 1304) or (actor >= 3 and actor < 6 and (id == 1296 or id == 1382)));
                    self.sounds += 1;
                },
                .status => |attempt| {
                    try std.testing.expect(actor < 3 and attempt.kind == .accuracy_reduced and attempt.threshold_percent == 20);
                    try std.testing.expect(self.statuses[actor] == null);
                    self.statuses[actor] = self.update;
                },
                else => return error.UnexpectedOrderCommand,
            }
            return true;
        }
    };
    for (0..4) |ordered_count| {
        var observer: OrderObserver = .{};
        var actors: [7]host.Actor = undefined;
        for (&actors, 0..) |*actor, index| actor.* = try host.Actor.init(data.animations.find(if (index < 3) "hero" else if (index < 6) "flying_squirrel" else "beast_commander").?, .{ (if (index < 3) @as(i32, 128) else -128) * 4096, @as(i32, @intCast(index % 3)) * 32 * 4096, 0 });
        var children: [12]?host.Actor = @splat(null);
        var runtime = host.Runtime{ .actors = &actors, .auxiliary = &children, .library = packet.library(), .external = .{ .context = &observer, .command = OrderObserver.command } };
        var commander = try @import("battle").commander.Action.begin(data.binding, &runtime, 6, null);
        var allies: [3]?Counter.Action = @splat(null);
        var contact: [3]?u16 = @splat(null);
        var returning: [3]?u16 = @splat(null);
        var target_release: [3]?u16 = @splat(null);
        var ally_release: [3]?u16 = @splat(null);
        var owner_release: ?u16 = null;
        for (1..211) |update| {
            observer.update = @intCast(update);
            if (try commander.advance(data.binding, &runtime) == .orders) {
                try std.testing.expectEqual(@as(usize, 12), update);
                for (allies[0..ordered_count], 0..) |*ally, index| ally.* = try Counter.Action.beginFor(packet, &runtime, @intCast(index + 3), @intCast(index), .ordered);
            }
            for (&allies, 0..) |*maybe, index| if (maybe.*) |*ally| {
                try ally.advance(packet, &runtime);
                if (ally.stage == .contact) {
                    try std.testing.expect(contact[index] == null);
                    contact[index] = @intCast(update);
                    try ally.acknowledgeContact(packet, &runtime);
                    try std.testing.expectEqual(@as(u16, 0), actors[index + 3].signals & 16);
                }
                if (ally.returnReady(runtime)) {
                    returning[index] = @intCast(update);
                    try ally.beginReturn(packet, &runtime);
                }
            };
            for (0..actors.len) |index| try runtime.stepActor(@intCast(index));
            for (0..children.len) |index| if (children[index] != null) try runtime.stepActor(@intCast(actors.len + index));
            for (0..3) |index| {
                if (contact[index] != null and target_release[index] == null and actors[index].highlights == 0) target_release[index] = @intCast(update);
                if (returning[index] != null and ally_release[index] == null and actors[index + 3].highlights == 0) ally_release[index] = @intCast(update);
            }
            if (owner_release == null and actors[6].released) owner_release = @intCast(update);
        }
        for (0..3) |index| {
            if (index >= ordered_count) {
                try std.testing.expect(contact[index] == null and actors[index].machine == null and actors[index + 3].machine == null);
                continue;
            }
            try std.testing.expectEqual(@as(?u16, 117), contact[index]);
            try std.testing.expectEqual(@as(?u16, 118), returning[index]);
            try std.testing.expectEqual(@as(?u16, 119), observer.statuses[index]);
            try std.testing.expectEqual(@as(?u16, 153), target_release[index]);
            try std.testing.expectEqual(@as(?u16, 199), ally_release[index]);
            try std.testing.expectEqualDeep(actors[index + 3].home_q12, actors[index + 3].position_q12);
            try std.testing.expect(actors[index].machine.?.halted and actors[index + 3].machine.?.halted);
        }
        try std.testing.expectEqual(@as(?u16, 142), owner_release);
        try std.testing.expectEqual(ordered_count * 3, observer.sounds);
        for (children) |child| try std.testing.expect(child == null);
    }
}

const ColorObserver = struct {
    update: u16 = 0,
    sounds: usize = 0,
    status_at: ?u16 = null,
    fn command(raw: *anyopaque, _: u16, request: vm.Command, _: bool) !bool {
        const self: *@This() = @ptrCast(@alignCast(raw));
        switch (request) {
            .sound => |id| {
                try std.testing.expectEqual(@as(u16, 1306), id);
                self.sounds += 1;
            },
            .status => |attempt| {
                try std.testing.expectEqual(.sleep, attempt.kind);
                try std.testing.expectEqual(@as(u8, 30), attempt.threshold_percent);
                self.status_at = self.update;
            },
            else => return error.UnexpectedColorSideEffect,
        }
        return true;
    }
};

test "actor RGB executes the source Commander recipient with retained motion and status clocks" {
    const Source = struct { programs: vm.Packet, animations: host.Resources, clocks: struct { red: u16, restore: u16, status: u16, halt: u16 } };
    const source = try std.json.parseFromSlice(Source, a, @embedFile("fixtures/actor_color_source.json"), .{ .ignore_unknown_fields = true });
    defer source.deinit();
    try source.value.programs.validate();
    var actors = [_]host.Actor{ try host.Actor.init(source.value.animations.resources[0], .{ 0, 0, 0 }), try host.Actor.init(source.value.animations.resources[0], .{ -128 * 4096, 0, 0 }) };
    var observer: ColorObserver = .{};
    var runtime = host.Runtime{ .actors = &actors, .external = .{ .context = &observer, .command = ColorObserver.command } };
    try runtime.dispatch(0, 1, source.value.programs.programs[0]);
    try std.testing.expect(actors[0].color == null);
    for (1..source.value.clocks.halt + 1) |update| {
        observer.update = @intCast(update);
        try runtime.stepActor(0);
        if (update < source.value.clocks.red) try std.testing.expect(actors[0].color == null) else try std.testing.expectEqualDeep(@as(?[3]u8, if (update < source.value.clocks.restore) .{ 255, 64, 64 } else @splat(128)), actors[0].color);
        try std.testing.expect(actors[1].color == null);
        try std.testing.expectEqual(update == source.value.clocks.halt, actors[0].machine.?.halted);
    }
    try std.testing.expectEqual(@as(usize, 1), observer.sounds);
    try std.testing.expectEqual(@as(?u16, source.value.clocks.status), observer.status_at);
    try std.testing.expectEqual(@as(u8, 0), actors[0].highlights);
    try std.testing.expect(actors[0].movement == null);
}

test "actor RGB checkpoint preserves an active color and omits the legacy default" {
    var actors = [_]host.Actor{try host.Actor.init(resource, .{ 0, 0, 0 })};
    const neutral = try std.json.Stringify.valueAlloc(a, actors[0], .{});
    defer a.free(neutral);
    try std.testing.expect(std.mem.indexOf(u8, neutral, "\"color\"") == null);
    const code = [_]vm.Instruction{ .{ .command = .{ .color = .{ 255, 64, 64 } } }, .{ .delay = 4 }, .{ .command = .{ .animation = 1 } }, .{ .command = .{ .reset_draw = false } }, .{ .delay = 3 }, .{ .command = .{ .color = @splat(128) } }, .{ .halt = {} } };
    var runtime = host.Runtime{ .actors = &actors };
    try runtime.dispatch(0, null, .{ .id = "rgb", .instructions = &code });
    try runtime.stepActor(0);
    const bytes = try std.json.Stringify.valueAlloc(a, actors[0], .{});
    defer a.free(bytes);
    const restored = try std.json.parseFromSlice(host.Actor, a, bytes, .{});
    defer restored.deinit();
    var resumed = [_]host.Actor{restored.value};
    var other = host.Runtime{ .actors = &resumed };
    for (0..7) |update| {
        try runtime.stepActor(0);
        try other.stepActor(0);
        try std.testing.expectEqualDeep(actors[0], resumed[0]);
        try std.testing.expectEqualDeep(@as(?[3]u8, if (update < 5) .{ 255, 64, 64 } else @splat(128)), actors[0].color);
    }
    try std.testing.expectEqualDeep(@as(?[3]u8, @splat(128)), resumed[0].color);
    try std.testing.expect(actors[0].machine.?.halted);
}

test "actor RGB is local to each newly allocated child node" {
    const child_code = [_]vm.Instruction{ .{ .delay = 1 }, .{ .command = .{ .color = .{ 64, 128, 255 } } }, .{ .halt = {} } };
    const programs = [_]vm.Program{.{ .id = "child", .instructions = &child_code }};
    const resources = [_]host.Resource{resource};
    var actors = [_]host.Actor{try host.Actor.init(resource, .{ 0, 0, 0 })};
    var children: [1]?host.Actor = @splat(null);
    var runtime = host.Runtime{ .actors = &actors, .auxiliary = &children, .library = .{ .programs = .{ .schema = "suikoden-actor-programs/12", .programs = &programs }, .resources = .{ .schema = "suikoden-actor-animations/1", .resources = &resources } } };
    const code = [_]vm.Instruction{ .{ .command = .{ .color = .{ 255, 64, 64 } } }, .{ .command = .{ .child = .{ .program = "child", .resource = "actor", .animation = 0, .offset = .{ 0, 0, 0 } } } }, .{ .halt = {} } };
    try runtime.dispatch(0, null, .{ .id = "parent", .instructions = &code });
    try std.testing.expect(children[0].?.color == null);
    try runtime.stepActor(1);
    try std.testing.expectEqualDeep(@as(?[3]u8, .{ 64, 128, 255 }), children[0].?.color);
    try std.testing.expectEqualDeep(@as(?[3]u8, .{ 255, 64, 64 }), actors[0].color);
}

test "actor RGB reaches common body reactions and every auxiliary piece without moving them" {
    const content = try Battle.load(a, @embedFile("fixtures/journey_unites_battle.json"));
    defer content.deinit();
    const library = try host.loadBundle(a, @embedFile("fixtures/journey_unites_actor_library.json"));
    defer library.deinit();
    const items = try Field.items.load(a, Field.items.json);
    defer items.deinit();
    var members: [6]Battle.Member = undefined;
    var state = try Battle.State.init(content.value, items.value, &members, 17);
    try state.attachUniteActors(&library.value);
    const index = for (library.value.animations.resources, 0..) |value, i| {
        if (std.mem.eql(u8, value.id, "hero")) break i;
    } else return error.MissingHeroResource;
    state.unite_vm.actors[0] = try host.Actor.init(library.value.animations.resources[index], .{ 0, 0, 0 });
    state.unite_vm.scripted_actors[0] = .{ .family = .counter, .leader = 0, .resource = @intCast(index) };
    state.unite_vm.counter_actions[0] = .{ .kind = .ordinary_hit, .attacker = 6, .defender = 0, .start_at = 0, .controller_done = true };
    const before = Battle.layout.actorLayout(state, 0);
    try std.testing.expect(state.spellReaction(0) == null);
    state.unite_vm.actors[0].color = .{ 255, 64, 64 };
    const reaction = state.spellReaction(0).?;
    try std.testing.expectEqualDeep([3]u8{ 255, 64, 64 }, reaction.color);
    try std.testing.expect(reaction.entry == null);
    const after = Battle.layout.actorLayout(state, 0);
    try std.testing.expectEqualDeep(before.point, after.point);
    try std.testing.expectEqualDeep(before.sprite, after.sprite);
    state.unite_vm.actors[0].color = @splat(128);
    try std.testing.expectEqualDeep([3]u8{ 128, 128, 128 }, state.spellReaction(0).?.color);
    state.unite_vm.actors[0].visible = false;
    try std.testing.expect(!state.spellReaction(0).?.visible);
    state.unite_vm.actors[0].visible = true;
    state.unite_vm.scripted_actors[0] = null;
    try std.testing.expect(state.spellReaction(0) == null);
    for ([_]bool{ false, true }) |secondary| {
        var child = try host.Actor.init(library.value.animations.resources[index], .{ 0, 0, 0 });
        child.has_draw_record = secondary;
        state.unite_vm.auxiliary[0] = child;
        var count: usize = 0;
        while (Battle.layout.uniteAuxiliaryPiece(state, 0, count)) |neutral| : (count += 1) {
            try std.testing.expectEqualDeep([3]u8{ 128, 128, 128 }, neutral.color);
            state.unite_vm.auxiliary[0].?.color = .{ 255, 64, 64 };
            const colored = Battle.layout.uniteAuxiliaryPiece(state, 0, count).?;
            try std.testing.expectEqualDeep([3]u8{ 255, 64, 64 }, colored.color);
            try std.testing.expectEqualDeep(neutral.vertices, colored.vertices);
            try std.testing.expectEqualDeep(neutral.sprite, colored.sprite);
            state.unite_vm.auxiliary[0].?.color = null;
        }
        try std.testing.expect(count > 0);
    }
}

test "Ivy geometry agrees with independent root calibration and packet vertices" {
    const Witness = struct {
        roots: []const struct { input: u31, expected: u32 },
        bases: []const struct { delta: [2]i32, expected: ?[4]i32 },
        quads: []const struct {
            block: @import("battle_camera").Block,
            points: [13][3]i32,
            parts: []const struct { index: usize, anchor: [2]i16, extent: [2]u16, expected: ?host.ivy.Quad },
        },
    };
    const parsed = try std.json.parseFromSlice(Witness, a, @embedFile("fixtures/ivy_geometry.json"), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    for (parsed.value.roots) |case| try std.testing.expectEqual(case.expected, host.ivy.rootQ12(case.input));
    for (parsed.value.bases) |case| try std.testing.expectEqualDeep(case.expected, host.ivy.segmentBasis(case.delta));
    for (parsed.value.quads) |case| for (case.parts) |part| try std.testing.expectEqualDeep(part.expected, host.ivy.quad(case.points, case.block, part.index, part.anchor, part.extent));
}

test "Ivy vine matches independent world curve and clock witnesses without moving its owner" {
    const Witness = struct { cases: []const struct {
        start: [3]i32,
        home: [3]i32,
        frames: []const struct { stage: i16, visible: bool, remaining: u8, end: [3]i32, points: [13][3]i32 },
    } };
    const fixture = try std.json.parseFromSlice(Witness, a, @embedFile("fixtures/ivy_vine.json"), .{ .ignore_unknown_fields = true });
    defer fixture.deinit();
    const code = [_]vm.Instruction{ .{ .command = .{ .effect = .{ .binding = .self, .id = "ivy_vine" } } }, .{ .halt = {} } };
    for (fixture.value.cases) |case| {
        var actors = [_]host.Actor{ try host.Actor.init(resource, case.start), try host.Actor.init(resource, case.home) };
        actors[1].position_q12 = .{ 1, 2, 3 };
        actors[0].draw_angles = .{ 11, -12, 13 };
        actors[0].screen_offset = .{ -7, 9 };
        var runtime = host.Runtime{ .actors = &actors };
        try runtime.dispatch(0, 1, .{ .id = "vine", .instructions = &code });
        for (case.frames, 0..) |frame, index| {
            try runtime.stepActor(0);
            const vine = actors[0].ivy_vine.?;
            try std.testing.expectEqual(frame.stage, actors[0].shared_value);
            try std.testing.expectEqual(frame.visible, vine.visible);
            try std.testing.expectEqual(frame.remaining, vine.remaining);
            try std.testing.expectEqualDeep(frame.end, vine.points[2]);
            try std.testing.expectEqualDeep(frame.points, vine.samples());
            try std.testing.expectEqualDeep(case.start, actors[0].position_q12);
            if (index == 0) actors[1].home_q12 = .{ 101, 202, 303 };
        }
        const held = actors[0].ivy_vine.?.points;
        for ([_]i16{ 0, 3, 98 }) |stage| {
            actors[0].shared_value = stage;
            try runtime.stepActor(0);
            try std.testing.expectEqual(stage, actors[0].shared_value);
            try std.testing.expect(actors[0].ivy_vine.?.visible);
            try std.testing.expectEqualDeep(held, actors[0].ivy_vine.?.points);
        }
        actors[0].shared_value = 99;
        try runtime.stepActor(0);
        try std.testing.expectEqual(@as(i16, 100), actors[0].shared_value);
        try std.testing.expect(!actors[0].ivy_vine.?.visible);
        try runtime.stepActor(0);
        try std.testing.expect(actors[0].ivy_vine == null);
        try std.testing.expectEqualDeep([3]i16{ 11, -12, 13 }, actors[0].draw_angles);
        try std.testing.expectEqualDeep([2]i8{ -7, 9 }, actors[0].screen_offset);
    }
}

test "Ivy vine rejects missing targets and occupied effect channels" {
    const code = [_]vm.Instruction{ .{ .command = .{ .effect = .{ .binding = .self, .id = "ivy_vine" } } }, .{ .halt = {} } };
    for (0..7) |case| {
        var actors = [_]host.Actor{ try host.Actor.init(resource, .{ 0, 0, 0 }), try host.Actor.init(resource, .{ 0, 0, 0 }) };
        var runtime = host.Runtime{ .actors = &actors };
        switch (case) {
            1 => actors[0].projectile = .fixed,
            2 => actors[0].blue_trail_active = true,
            3 => actors[0].palette_cycle_active = true,
            4 => actors[0].reaction_callback = .spin,
            5 => actors[0].crow_dive = .{},
            6 => actors[0].ivy_vine = .{},
            else => {},
        }
        try std.testing.expectError(if (case == 0) error.MissingActorOwner else error.ActorEffectAlreadyActive, runtime.dispatch(0, if (case == 0) null else 1, .{ .id = "vine", .instructions = &code }));
        if (case != 6) try std.testing.expect(actors[0].ivy_vine == null);
    }
}

test "Ivy vine refuses an uninitialized phase and keeps the hide then free boundary" {
    var actors = [_]host.Actor{ try host.Actor.init(resource, .{ 0, 0, 0 }), try host.Actor.init(resource, .{ 0, 0, 0 }) };
    var runtime = host.Runtime{ .actors = &actors };
    actors[0].owner = 1;
    actors[0].ivy_vine = .{};
    actors[0].shared_value = 1;
    try std.testing.expectError(error.MissingActorMotion, runtime.stepActor(0));
    actors[0].shared_value = 99;
    try runtime.stepActor(0);
    try std.testing.expect(actors[0].ivy_vine != null);
    try runtime.stepActor(0);
    try std.testing.expect(actors[0].ivy_vine == null);
}

test "Ivy clock support cannot admit an uncomposed live packet" {
    const packet = try host.loadBundle(a, @embedFile("fixtures/journey_unites_actor_library.json"));
    defer packet.deinit();
    var bundle = packet.value;
    const programs = try a.alloc(vm.Program, bundle.programs.programs.len + 1);
    defer a.free(programs);
    @memcpy(programs[0..bundle.programs.programs.len], bundle.programs.programs);
    const code = [_]vm.Instruction{ .{ .command = .{ .effect = .{ .binding = .self, .id = "ivy_vine" } } }, .{ .halt = {} } };
    programs[programs.len - 1] = .{ .id = "ivy/unqualified", .instructions = &code };
    bundle.programs.programs = programs;
    try std.testing.expectError(error.UnsupportedIvyComposition, bundle.validate());
}

test "Crow dive agrees with independent signed word source vectors and keeps its sampled target" {
    const Fixture = struct { cases: []const struct { start: [3]i32, target: [3]i32, positions: []const [3]i32 } };
    const fixture = try std.json.parseFromSlice(Fixture, a, @embedFile("fixtures/crow_dive.json"), .{ .ignore_unknown_fields = true });
    defer fixture.deinit();
    const code = [_]vm.Instruction{ .{ .command = .{ .effect = .{ .binding = .self, .id = "crow_dive" } } }, .{ .halt = {} } };
    for (fixture.value.cases) |case| {
        var actors = [_]host.Actor{ try host.Actor.init(resource, case.start), try host.Actor.init(resource, case.target) };
        var runtime = host.Runtime{ .actors = &actors };
        actors[0].draw_angles = .{ 11, -12, 13 };
        actors[0].screen_offset = .{ -7, 9 };
        actors[0].velocity_q12 = .{ 17, -19, 23 };
        try runtime.dispatch(0, 1, .{ .id = "dive", .instructions = &code });
        try runtime.stepActor(0);
        try std.testing.expectEqualDeep(case.start, actors[0].position_q12);
        try std.testing.expectEqual(@as(i16, 1), actors[0].shared_value);
        actors[1].position_q12 = .{ 1, 2, 3 };
        for (case.positions, 0..) |point, age| {
            try runtime.stepActor(0);
            try std.testing.expectEqualDeep(point, actors[0].position_q12);
            try std.testing.expectEqual(@as(i16, if (age == 29) 99 else if (age >= 16) 2 else 1), actors[0].shared_value);
        }
        try std.testing.expect(actors[0].crow_dive != null);
        const last = actors[0].position_q12;
        try runtime.stepActor(0);
        try std.testing.expect(actors[0].crow_dive == null);
        try std.testing.expectEqualDeep(last, actors[0].position_q12);
        try std.testing.expectEqualDeep([3]i16{ 11, -12, 13 }, actors[0].draw_angles);
        try std.testing.expectEqualDeep([2]i8{ -7, 9 }, actors[0].screen_offset);
        try std.testing.expectEqualDeep([3]i32{ 17, -19, 23 }, actors[0].velocity_q12);
    }
}

test "Crow dive rejects missing targets and occupied callback channels" {
    const code = [_]vm.Instruction{ .{ .command = .{ .effect = .{ .binding = .self, .id = "crow_dive" } } }, .{ .halt = {} } };
    for (0..6) |case| {
        var actors = [_]host.Actor{ try host.Actor.init(resource, .{ 0, 0, 0 }), try host.Actor.init(resource, .{ 0, 0, 0 }) };
        var runtime = host.Runtime{ .actors = &actors };
        switch (case) {
            1 => actors[0].projectile = .fixed,
            2 => actors[0].blue_trail_active = true,
            3 => actors[0].palette_cycle_active = true,
            4 => actors[0].reaction_callback = .spin,
            5 => actors[0].crow_dive = .{},
            else => {},
        }
        try std.testing.expectError(if (case == 0) error.MissingActorOwner else error.ActorEffectAlreadyActive, runtime.dispatch(0, if (case == 0) null else 1, .{ .id = "dive", .instructions = &code }));
        if (case != 5) try std.testing.expect(actors[0].crow_dive == null);
    }
}

test "Crow dive releases early at shared99 and refuses a missing initialized curve" {
    const code = [_]vm.Instruction{ .{ .command = .{ .effect = .{ .binding = .self, .id = "crow_dive" } } }, .{ .halt = {} } };
    var actors = [_]host.Actor{ try host.Actor.init(resource, .{ 1, 2, 3 }), try host.Actor.init(resource, .{ 4, 5, 6 }) };
    var runtime = host.Runtime{ .actors = &actors };
    try runtime.dispatch(0, 1, .{ .id = "dive", .instructions = &code });
    actors[0].shared_value = 1;
    try std.testing.expectError(error.MissingActorMotion, runtime.stepActor(0));
    actors[0].shared_value = 99;
    try runtime.stepActor(0);
    try std.testing.expect(actors[0].crow_dive == null);
    try std.testing.expectEqualDeep([3]i32{ 1, 2, 3 }, actors[0].position_q12);
}

test "resumed motion preserves post-jump derivatives and the original destination" {
    var actors = [_]host.Actor{try host.Actor.init(resource, .{ 101, -202, 303 })};
    var runtime = host.Runtime{ .actors = &actors };
    const jump = [_]vm.Instruction{ .{ .command = .{ .motion = .{ .anchor = .self, .updates = 2, .offset = .{ 2, -1, 1 }, .velocity_q12 = .{ 4, -6, 8 } } } }, .{ .halt = {} } };
    try runtime.dispatch(0, null, .{ .id = "jump", .instructions = &jump });
    try runtime.stepActor(0);
    try runtime.stepActor(0);
    const destination = [3]i32{ 8293, -4298, 4096 };
    const velocity = [3]i32{ 16372, -8174, 7562 };
    const acceleration = [3]i32{ 8184, -4084, 3777 };
    try std.testing.expectEqualDeep(destination, actors[0].position_q12);
    try std.testing.expect(actors[0].movement == null);
    const restart = [_]vm.Instruction{ .{ .command = .{ .resume_motion = 10 } }, .{ .halt = {} } };
    try runtime.dispatch(0, null, .{ .id = "restart", .instructions = &restart });
    try std.testing.expectEqualDeep(velocity, actors[0].velocity_q12);
    try std.testing.expectEqualDeep(acceleration, actors[0].acceleration_q12);
    for (1..11) |update| {
        try runtime.stepActor(0);
        const k: i32 = @intCast(update);
        for (0..3) |axis| {
            const position = if (update == 10) destination[axis] else destination[axis] + k * velocity[axis] + @divTrunc(k * (k - 1), 2) * acceleration[axis];
            try std.testing.expectEqual(position, actors[0].position_q12[axis]);
            try std.testing.expectEqual(velocity[axis] + k * acceleration[axis], actors[0].velocity_q12[axis]);
        }
    }
    try std.testing.expect(actors[0].movement == null);
}

test "resumed motion stops without snapping and retains an active destination for later restarts" {
    for ([_]i16{ 0, -1, -32768 }) |stop| {
        var actors = [_]host.Actor{try host.Actor.init(resource, .{ 0, 0, 0 })};
        var runtime = host.Runtime{ .actors = &actors };
        const move = [_]vm.Instruction{ .{ .command = .{ .motion = .{ .anchor = .self, .updates = 4, .offset = .{ 4, 0, 0 }, .velocity_q12 = .{ 0, 0, 0 }, .kind = .linear } } }, .{ .halt = {} } };
        try runtime.dispatch(0, null, .{ .id = "move", .instructions = &move });
        try runtime.stepActor(0);
        const pause = [_]vm.Instruction{ .{ .command = .{ .resume_motion = stop } }, .{ .halt = {} } };
        try runtime.dispatch(0, null, .{ .id = "pause", .instructions = &pause });
        try runtime.stepActor(0);
        try std.testing.expect(actors[0].movement == null);
        try std.testing.expectEqualDeep([3]i32{ 4096, 0, 0 }, actors[0].position_q12);
        try std.testing.expectEqualDeep([3]i32{ 4096, 0, 0 }, actors[0].velocity_q12);
        const restart = [_]vm.Instruction{ .{ .command = .{ .resume_motion = 1 } }, .{ .halt = {} } };
        try runtime.dispatch(0, null, .{ .id = "restart", .instructions = &restart });
        try runtime.stepActor(0);
        try std.testing.expectEqualDeep([3]i32{ 16384, 0, 0 }, actors[0].position_q12);
    }
    var actors = [_]host.Actor{try host.Actor.init(resource, .{ 0, 0, 0 })};
    var runtime = host.Runtime{ .actors = &actors };
    const restart = [_]vm.Instruction{ .{ .command = .{ .resume_motion = 1 } }, .{ .halt = {} } };
    try std.testing.expectError(error.MissingActorMotion, runtime.dispatch(0, null, .{ .id = "missing", .instructions = &restart }));
    try std.testing.expect(actors[0].movement == null);
    try std.testing.expect(actors[0].retained_destination_q12 == null);
    const move = [_]vm.Instruction{ .{ .command = .{ .motion = .{ .anchor = .self, .updates = 4, .offset = .{ 4, 0, 0 }, .velocity_q12 = .{ 0, 0, 0 }, .kind = .linear } } }, .{ .halt = {} } };
    try runtime.dispatch(0, null, .{ .id = "move", .instructions = &move });
    try runtime.stepActor(0);
    const shorten = [_]vm.Instruction{ .{ .command = .{ .resume_motion = 2 } }, .{ .halt = {} } };
    try runtime.dispatch(0, null, .{ .id = "shorten", .instructions = &shorten });
    try runtime.stepActor(0);
    try std.testing.expectEqualDeep([3]i32{ 8192, 0, 0 }, actors[0].position_q12);
    try runtime.stepActor(0);
    try std.testing.expectEqualDeep([3]i32{ 16384, 0, 0 }, actors[0].position_q12);
    try std.testing.expectEqualDeep([3]i32{ 4096, 0, 0 }, actors[0].velocity_q12);
}

test "owner recipient spin wraps its draw angle and resets only at shared value two" {
    var actors = [_]host.Actor{ try host.Actor.init(resource, .{ 17, -29, 41 }), try host.Actor.init(resource, .{ 0, 0, 0 }) };
    var runtime = host.Runtime{ .actors = &actors };
    const code = [_]vm.Instruction{ .{ .command = .{ .effect = .{ .binding = .owner, .id = "recipient_spin" } } }, .{ .halt = {} } };
    actors[0].draw_angles = .{ 123, -456, 32760 };
    actors[0].screen_offset = .{ -4, 7 };
    actors[1].draw_angles = .{ -1, 2, -3 };
    try runtime.dispatch(0, 1, .{ .id = "spin", .instructions = &code });
    for ([_]i16{ 0, -32768, -1, 3, 32767 }) |value| {
        actors[0].shared_value = value;
        try runtime.stepActor(0);
        try std.testing.expectEqualDeep([3]i16{ 123, -456, 32760 }, actors[0].draw_angles);
        try std.testing.expect(actors[0].reaction_callback == .spin);
    }
    actors[0].shared_value = 1;
    for (1..131) |update| {
        try runtime.stepActor(0);
        const expected: i16 = @bitCast(@as(u16, @truncate(32760 + @as(u32, @intCast(update)) * 256)));
        try std.testing.expectEqualDeep([3]i16{ 123, -456, expected }, actors[0].draw_angles);
        try std.testing.expectEqual(@as(i16, 1), actors[0].shared_value);
    }
    actors[0].shared_value = 2;
    try runtime.stepActor(0);
    try std.testing.expect(actors[0].reaction_callback == null);
    try std.testing.expectEqualDeep([3]i16{ 123, -456, 0 }, actors[0].draw_angles);
    try std.testing.expectEqualDeep([3]i16{ -1, 2, -3 }, actors[1].draw_angles);
    try std.testing.expectEqualDeep([3]i32{ 17, -29, 41 }, actors[0].position_q12);
    try std.testing.expectEqualDeep([2]i8{ -4, 7 }, actors[0].screen_offset);
    actors[0].shared_value = 1;
    try runtime.stepActor(0);
    try std.testing.expectEqual(@as(i16, 0), actors[0].draw_angles[2]);
}

test "owner recipient spin rejects missing owner and occupied callback channels before activation" {
    const code = [_]vm.Instruction{ .{ .command = .{ .effect = .{ .binding = .owner, .id = "recipient_spin" } } }, .{ .halt = {} } };
    for (0..7) |case| {
        var actors = [_]host.Actor{ try host.Actor.init(resource, .{ 0, 0, 0 }), try host.Actor.init(resource, .{ 0, 0, 0 }) };
        var runtime = host.Runtime{ .actors = &actors };
        switch (case) {
            1 => actors[0].projectile = .aimed,
            2 => actors[0].blue_trail_active = true,
            3 => actors[0].palette_cycle_active = true,
            4 => actors[0].reaction_callback = .airborne,
            5 => actors[0].reaction_callback = .spin,
            6 => actors[0].crow_dive = .{},
            else => {},
        }
        const previous = actors[0].reaction_callback;
        try std.testing.expectError(if (case == 0) error.MissingActorOwner else error.ActorEffectAlreadyActive, runtime.dispatch(0, if (case == 0) null else 1, .{ .id = "spin", .instructions = &code }));
        try std.testing.expectEqual(previous, actors[0].reaction_callback);
    }
}

const PhysicalFixture = struct {
    schema: []const u8,
    programs: vm.Packet,
    animations: host.Resources,
    techniques: []const struct { id: []const u8, members: []const []const u8, owner_program: []const u8, recipient_program: []const u8 },
};
fn physicalFixture() !std.json.Parsed(PhysicalFixture) {
    const bytes = @embedFile("fixtures/physical_actor_library.json");
    return std.json.parseFromSlice(PhysicalFixture, a, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}
const PhysicalCallbackReference = struct {
    motions: []const struct {
        kind: []const u8,
        state: i16,
        first: [3]i32,
        home: [3]i32,
        owner: [3]i32,
        attachment_x: i16,
        destination: [3]i32,
        velocity: [3]i32,
        acceleration: [3]i32,
        samples: []const struct { position: [3]i32, velocity: [3]i32 },
    },
    shrike: struct { flip: u16, pulse_positive: u16, pulse_negative: u16, contact: u16, restore: u16, complete: u16, child_retired: u16 },
    trick: struct { animation20: u16, callback: u16, contact: u16, retired: u16, response_complete: u16 },
};
fn physicalCallbackReference() !std.json.Parsed(PhysicalCallbackReference) {
    return std.json.parseFromSlice(PhysicalCallbackReference, a, @embedFile("fixtures/physical_callback_vectors.json"), .{ .ignore_unknown_fields = true });
}
const DecoyObserver = struct {
    contacts: u16 = 0,
    attacker: u16 = 0,
    child: u16 = 0,
    exhausted: bool = false,
    fn command(_: *anyopaque, _: u16, request: vm.Command, _: bool) !bool {
        if (request != .sound) return error.UnboundCommand;
        return true;
    }
    fn contact(context: *anyopaque, attacker: u16, child: u16) !void {
        const self: *DecoyObserver = @ptrCast(@alignCast(context));
        if (self.exhausted) return error.RandomInputExhausted;
        self.contacts += 1;
        self.attacker = attacker;
        self.child = child;
    }
};

test "Physical rune callbacks reject missing dependencies and overlapping effects before activation" {
    const parsed = try physicalFixture();
    defer parsed.deinit();
    for ([_]anyerror{ error.MissingActorCamera, error.ActorEffectAlreadyActive, error.InvalidDecoyActor, error.MissingDecoyContact, error.MissingActorLibrary, error.MissingActorChildProgram, error.MissingActorResource, error.ActorEffectAlreadyActive, error.ActorEffectAlreadyActive }, 0..) |expected, index| {
        var actors = [_]host.Actor{ try host.Actor.init(resource, .{ 0, 0, 0 }), try host.Actor.init(resource, .{ 0, 0, 0 }) };
        var children = [_]?host.Actor{try host.Actor.init(resource, .{ 0, 0, 0 })};
        var observer = DecoyObserver{};
        var runtime = host.Runtime{ .actors = &actors, .auxiliary = &children, .library = .{ .programs = parsed.value.programs, .resources = parsed.value.animations }, .external = .{ .context = &observer, .command = DecoyObserver.command, .decoy_contact = DecoyObserver.contact } };
        const id: u16 = if (index <= 2) 0 else 2;
        const current = if (id == 0) &actors[0] else &children[0].?;
        switch (index) {
            1 => current.blue_trail_active = true,
            3 => runtime.external = null,
            4 => runtime.library = null,
            5 => runtime.library.?.programs.programs = &.{},
            6 => actors[1] = host.Actor.anchor(.{ 0, 0, 0 }, .{ 0, 0, 0 }, .{ 0, 0 }),
            7 => current.projectile = .aimed,
            8 => current.reaction_callback = .airborne,
            else => {},
        }
        const before = current.reaction_callback;
        const code = [_]vm.Instruction{ .{ .command = .{ .effect = .{ .binding = .shared, .id = if (index < 2) "airborne_recipient" else "decoy_retaliation" } } }, .{ .halt = {} } };
        try std.testing.expectError(expected, runtime.dispatch(id, 1, .{ .id = "invalid_callback", .instructions = &code }));
        try std.testing.expectEqual(before, current.reaction_callback);
        try std.testing.expectEqual(@as(u16, 0), observer.contacts);
    }
}

test "Physical rune Trick contact exhaustion preserves its pending callback for one successful retry" {
    const parsed = try physicalFixture();
    defer parsed.deinit();
    var actors = [_]host.Actor{try host.Actor.init(parsed.value.animations.find("hero").?, .{ 0, 0, 0 })};
    var children = [_]?host.Actor{try host.Actor.init(parsed.value.animations.find("juppo").?, .{ 0, 0, 0 })};
    var observer = DecoyObserver{ .exhausted = true };
    var runtime = host.Runtime{ .actors = &actors, .auxiliary = &children, .library = .{ .programs = parsed.value.programs, .resources = parsed.value.animations }, .external = .{ .context = &observer, .command = DecoyObserver.command, .decoy_contact = DecoyObserver.contact } };
    const code = [_]vm.Instruction{ .{ .command = .{ .effect = .{ .binding = .shared, .id = "decoy_retaliation" } } }, .{ .halt = {} } };
    try runtime.dispatch(1, 0, .{ .id = "decoy_contact", .instructions = &code });
    children[0].?.shared_value = 1;
    children[0].?.signals = 2;
    try std.testing.expectError(error.RandomInputExhausted, runtime.stepActor(1));
    try std.testing.expect(children[0].?.reaction_callback == .decoy);
    try std.testing.expect(actors[0].machine == null);
    try std.testing.expectEqual(@as(u16, 0), observer.contacts);
    observer.exhausted = false;
    try runtime.stepActor(1);
    try runtime.stepActor(1);
    try std.testing.expectEqual(@as(u16, 1), observer.contacts);
    try std.testing.expect(children[0].?.reaction_callback == null);
    try std.testing.expectEqual(@as(u16, 2), children[0].?.signals);
    try std.testing.expectEqual(@as(?u16, 1), actors[0].owner);
    try std.testing.expect(actors[0].machine != null);
}

test "Physical rune airborne callback keeps signed draw offsets and untouched state" {
    const attached_frames = [_]host.Frame{.{ .pose = 0, .updates = 1, .attachment = .{ 4, 130 } }};
    const attached_clips = [_]host.Clip{.{ .id = 0, .advances = true, .loop = true, .frames = &attached_frames }};
    const attached = host.Resource{ .id = "attached", .pose_count = 1, .clips = &attached_clips };
    var actors = [_]host.Actor{try host.Actor.init(attached, .{ 0, 0, 0 })};
    actors[0].screen_offset = .{ 17, 9 };
    actors[0].offset_destination = .{ 45, -67 };
    actors[0].draw_angles[0] = 123;
    var controller = try @import("battle_camera").ActorController.init(@import("battle_camera").standard_battle);
    var runtime = host.Runtime{ .actors = &actors, .camera_controller = &controller };
    const code = [_]vm.Instruction{ .{ .command = .{ .effect = .{ .binding = .shared, .id = "airborne_recipient" } } }, .{ .halt = {} } };
    try runtime.dispatch(0, null, .{ .id = "airborne_states", .instructions = &code });
    try runtime.stepActor(0);
    try std.testing.expectEqualDeep([2]i8{ 17, -126 }, actors[0].screen_offset);
    try std.testing.expectEqualDeep([3]i16{ 123, 2048, 2048 }, actors[0].draw_angles);
    for ([_]i16{ -1, 4, 6, 8, 9, 98, 100, 32767 }) |value| {
        actors[0].shared_value = value;
        try runtime.stepActor(0);
        try std.testing.expectEqual(value, actors[0].shared_value);
        try std.testing.expectEqualDeep([3]i16{ 123, 2048, 2048 }, actors[0].draw_angles);
        try std.testing.expect(actors[0].movement == null);
    }
    actors[0].shared_value = 99;
    try runtime.stepActor(0);
    try std.testing.expectEqualDeep([2]i8{ 0, 0 }, actors[0].screen_offset);
    try std.testing.expectEqualDeep([3]i16{ 123, 0, 0 }, actors[0].draw_angles);
    try std.testing.expectEqualDeep([2]i32{ 45, -67 }, actors[0].offset_destination);
    try std.testing.expect(actors[0].reaction_callback == null);
}

test "Physical rune callbacks agree with independent fractional and wrapped Q12 jump vectors" {
    const parsed = try physicalFixture();
    defer parsed.deinit();
    const reference = try physicalCallbackReference();
    defer reference.deinit();
    for (reference.value.motions) |case| {
        const fixed_frames = [_]host.Frame{.{ .pose = 0, .updates = 1, .attachment = .{ case.attachment_x, 130 } }};
        const fixed_clips = [_]host.Clip{ .{ .id = 0, .advances = true, .loop = true, .frames = &fixed_frames }, .{ .id = 1, .advances = true, .loop = false, .frames = &fixed_frames } };
        const fixed = host.Resource{ .id = "motion", .pose_count = 1, .clips = &fixed_clips };
        var actors = [_]host.Actor{ try host.Actor.init(fixed, case.home), try host.Actor.init(fixed, .{ 0, 0, 0 }) };
        var children = [_]?host.Actor{null};
        const decoy = std.mem.eql(u8, case.kind, "decoy");
        const id: u16 = if (decoy) 2 else 0;
        if (decoy) children[0] = try host.Actor.init(fixed, case.home);
        const current = if (decoy) &children[0].? else &actors[0];
        current.position_q12 = case.first;
        current.shared_value = case.state;
        if (decoy) actors[0].position_q12 = case.owner;
        var observer = DecoyObserver{};
        var controller = try @import("battle_camera").ActorController.init(@import("battle_camera").standard_battle);
        var runtime = host.Runtime{ .actors = &actors, .auxiliary = &children, .camera_controller = &controller, .library = .{ .programs = parsed.value.programs, .resources = parsed.value.animations }, .external = .{ .context = &observer, .command = DecoyObserver.command, .decoy_contact = DecoyObserver.contact } };
        const code = [_]vm.Instruction{ .{ .command = .{ .effect = .{ .binding = .shared, .id = if (decoy) "decoy_retaliation" else "airborne_recipient" } } }, .{ .halt = {} } };
        try runtime.dispatch(id, if (decoy) @as(u16, 0) else 1, .{ .id = "callback", .instructions = &code });
        try runtime.stepActor(id);
        try std.testing.expectEqualDeep(case.first, current.position_q12);
        try std.testing.expectEqualDeep(case.destination, current.movement.?.destination);
        try std.testing.expectEqualDeep(case.velocity, current.velocity_q12);
        try std.testing.expectEqualDeep(case.acceleration, current.acceleration_q12);
        for (case.samples) |sample| {
            try runtime.stepActor(id);
            try std.testing.expectEqualDeep(sample.position, current.position_q12);
            try std.testing.expectEqualDeep(sample.velocity, current.velocity_q12);
        }
        try std.testing.expect(current.movement == null);
        try std.testing.expectEqual(@as(u16, 0), observer.contacts);
    }
}

test "Physical rune Shrike recipient preserves flip camera pulses hit and cleanup clocks" {
    const parsed = try physicalFixture();
    defer parsed.deinit();
    const reference = try physicalCallbackReference();
    defer reference.deinit();
    const expected = reference.value.shrike;
    const actor_resource = parsed.value.animations.find("bonbon").?;
    const home = [3]i32{ 200 * 4096, 40 * 4096, -30 * 4096 };
    var actors = [_]host.Actor{ try host.Actor.init(actor_resource, .{ 0, 0, 0 }), try host.Actor.init(actor_resource, home) };
    actors[1].highlights = 8;
    var children: [17]?host.Actor = @splat(null);
    var observer = Observer{};
    var controller = try @import("battle_camera").ActorController.init(@import("battle_camera").standard_battle);
    controller.velocity[0][0] = 7;
    controller.velocity[0][1] = -11;
    const original_target = controller.target;
    var runtime = host.Runtime{ .actors = &actors, .auxiliary = &children, .camera_controller = &controller, .library = .{ .programs = parsed.value.programs, .resources = parsed.value.animations }, .external = .{ .context = &observer, .command = Observer.command } };
    try runtime.dispatch(1, 0, parsed.value.programs.find("physical/shrike/recipient").?);
    var contact: u16 = 0;
    var completed: u16 = 0;
    var child_finished: u16 = 0;
    var child_seen = false;
    for (1..201) |tick| {
        runtime.beginUpdate();
        actors[1].signals &= ~@as(u16, 2);
        try runtime.stepActor(1);
        for (0..children.len) |child| if (children[child] != null) {
            child_seen = true;
            try runtime.stepActor(@intCast(actors.len + child));
        };
        if (child_seen and child_finished == 0) {
            var alive = false;
            for (children) |child| alive = alive or child != null;
            if (!alive) child_finished = @intCast(tick);
        }
        if (contact == 0 and actors[1].signals & 2 != 0) contact = @intCast(tick);
        if (completed == 0 and actors[1].highlights == 0) completed = @intCast(tick);
        const flipped = tick >= expected.flip and tick < expected.restore;
        try std.testing.expectEqual(@as(i16, if (flipped) 2048 else 0), actors[1].draw_angles[1]);
        try std.testing.expectEqual(@as(i16, if (flipped) 2048 else 0), actors[1].draw_angles[2]);
        try std.testing.expectEqualDeep(original_target, controller.target);
        if (tick == expected.pulse_positive or tick == expected.pulse_negative) {
            try std.testing.expectEqual(@as(u16, 1), controller.remaining[0]);
            try std.testing.expectEqual(@as(i32, if (tick == expected.pulse_positive) 20480 else -20480), controller.velocity[0][2]);
            try std.testing.expectEqual(@as(i32, 7), controller.velocity[0][0]);
            try std.testing.expectEqual(@as(i32, -11), controller.velocity[0][1]);
        }
        const delta: i32 = if (tick == expected.pulse_positive + 1) 20480 else if (tick == expected.pulse_negative + 1) -20480 else 0;
        try std.testing.expectEqual(original_target[0][2] + delta, controller.current[0][2]);
    }
    try std.testing.expectEqual(expected.contact, contact);
    try std.testing.expectEqual(expected.complete, completed);
    try std.testing.expectEqual(expected.child_retired, child_finished);
    try std.testing.expectEqualDeep(home, actors[1].position_q12);
    try std.testing.expect(actors[1].machine.?.halted and actors[1].reaction_callback == null);
}

test "Physical rune Trick child consumes contact once and dispatches the real enemy hurt script" {
    const parsed = try physicalFixture();
    defer parsed.deinit();
    const reference = try physicalCallbackReference();
    defer reference.deinit();
    const expected = reference.value.trick;
    const child_resource = parsed.value.animations.find("juppo").?;
    const enemy_resource = parsed.value.animations.find("bonbon").?;
    const home = [3]i32{ -150 * 4096, 27 * 4096, 0 };
    var actors = [_]host.Actor{ try host.Actor.init(child_resource, .{ 90 * 4096, -50 * 4096, 0 }), try host.Actor.init(enemy_resource, home) };
    actors[1].highlights = 8;
    var children: [17]?host.Actor = @splat(null);
    const child_id: u16 = 18;
    var observer = DecoyObserver{};
    var runtime = host.Runtime{ .actors = &actors, .auxiliary = &children, .library = .{ .programs = parsed.value.programs, .resources = parsed.value.animations }, .external = .{ .context = &observer, .command = DecoyObserver.command, .decoy_contact = DecoyObserver.contact } };
    const birth = [_]vm.Instruction{ .{ .command = .{ .child = .{ .program = "physical/trick/auxiliary/member_10", .resource = "juppo", .animation = 19, .owner = .owner, .draw_record = true, .offset = .{ 0, 0, 0 } } } }, .{ .halt = {} } };
    try runtime.dispatch(0, 1, .{ .id = "trick_birth", .instructions = &birth });
    var activated: ?u16 = null;
    var retired: ?u16 = null;
    var response_end: ?u16 = null;
    for (0..251) |tick| {
        try runtime.stepActor(0);
        try runtime.stepActor(1);
        for (0..children.len) |child| if (children[child] != null) try runtime.stepActor(@intCast(actors.len + child));
        if (children[16]) |current| {
            if (activated == null and current.reaction_callback != null) activated = @intCast(tick);
            if (tick >= expected.contact) try std.testing.expect(current.signals & 2 != 0);
        } else if (retired == null) retired = @intCast(tick);
        try std.testing.expectEqual(@as(u16, if (tick >= expected.contact) 1 else 0), observer.contacts);
        if (observer.contacts != 0 and response_end == null and actors[1].highlights & 8 == 0) response_end = @intCast(tick);
    }
    try std.testing.expectEqual(expected.callback, activated.?);
    try std.testing.expectEqual(expected.retired, retired.?);
    try std.testing.expectEqual(expected.response_complete, response_end.?);
    try std.testing.expectEqual(@as(u16, 1), observer.attacker);
    try std.testing.expectEqual(child_id, observer.child);
    try std.testing.expectEqualDeep(home, actors[1].position_q12);
    try std.testing.expect(actors[1].machine.?.halted);
}

test "Physical rune batch imports all six families and 78 character resources through the shared VM" {
    const parsed = try physicalFixture();
    defer parsed.deinit();
    const packet = parsed.value;
    try std.testing.expectEqualStrings("suikoden-physical-actors/2", packet.schema);
    try packet.programs.validate();
    try packet.animations.validate();
    try std.testing.expectEqual(@as(usize, 21), packet.programs.programs.len);
    try std.testing.expectEqual(@as(usize, 92), packet.animations.resources.len);
    try std.testing.expectEqual(@as(usize, 6), packet.techniques.len);
    for (packet.techniques) |technique| {
        const owner = packet.programs.find(technique.owner_program).?;
        try std.testing.expect(packet.programs.find(technique.recipient_program) != null);
        for (technique.members) |id| {
            const animation_resource = packet.animations.find(id).?;
            for (owner.instructions) |instruction| if (instruction == .command and instruction.command == .animation) {
                try std.testing.expect(animation_resource.find(instruction.command.animation) != null);
            };
        }
    }
    for (packet.programs.programs) |program| for (program.instructions) |instruction| if (instruction == .command and instruction.command == .child) {
        const child = instruction.command.child;
        try std.testing.expect(packet.programs.find(child.program) != null);
        try std.testing.expect(packet.animations.find(child.resource).?.find(child.animation) != null);
    };
}

test "Physical rune recipient programs keep source damage signals and home returns in the shared host" {
    const parsed = try physicalFixture();
    defer parsed.deinit();
    const packet = parsed.value;
    for ([_]struct { id: []const u8, impact: u16, release: u16 }{
        .{ .id = "physical/boar/recipient", .impact = 261, .release = 262 },
        .{ .id = "physical/clone/recipient", .impact = 7, .release = 37 },
        .{ .id = "physical/falcon/recipient", .impact = 95, .release = 128 },
        .{ .id = "physical/hate/recipient", .impact = 1, .release = 34 },
    }) |case| {
        const animation_resource = packet.animations.find("hero").?;
        const home = [3]i32{ 200 * 4096, 40 * 4096, -30 * 4096 };
        var actors = [_]host.Actor{ try host.Actor.init(animation_resource, .{ 0, 0, 0 }), try host.Actor.init(animation_resource, home) };
        actors[1].highlights = 8;
        var children: [17]?host.Actor = @splat(null);
        var observer = Observer{};
        var runtime = host.Runtime{ .actors = &actors, .auxiliary = &children, .library = .{ .programs = packet.programs, .resources = packet.animations }, .external = .{ .context = &observer, .command = Observer.command } };
        try runtime.dispatch(1, 0, packet.programs.find(case.id).?);
        var impact: u16 = 0;
        var released: u16 = 0;
        for (1..401) |tick| {
            actors[1].signals &= ~@as(u16, 2);
            try runtime.stepActor(1);
            for (0..children.len) |child| if (children[child] != null) try runtime.stepActor(@intCast(actors.len + child));
            if (impact == 0 and actors[1].signals & 2 != 0) impact = @intCast(tick);
            if (actors[1].highlights & 8 == 0) {
                released = @intCast(tick);
                break;
            }
        }
        try std.testing.expectEqual(case.impact, impact);
        try std.testing.expectEqual(case.release, released);
        var destination = home;
        if (case.impact == 261) destination[2] = 0;
        try std.testing.expectEqualDeep(destination, actors[1].position_q12);
        try std.testing.expect(actors[1].machine.?.halted);
        try std.testing.expect(actors[1].palette == .resource);
        for (children) |child| try std.testing.expect(child == null);
    }
}

test "group Unite bindings validate source damage member and preserve older defaults" {
    const parsed = try host.loadBundle(a, @embedFile("fixtures/unite_actor_library.json"));
    defer parsed.deinit();
    var bundle = parsed.value;
    const unites = try a.dupe(host.UniteBinding, bundle.unites);
    defer a.free(unites);
    bundle.unites = unites;
    try bundle.validate();
    try std.testing.expectEqual(@as(?u8, 1), unites[2].damage_member);
    try std.testing.expect(unites[2].members[0].reaction_group);
    try std.testing.expectEqual(@as(?u16, 1), unites[2].dispatch_after);
    unites[2].damage_member = 2;
    try std.testing.expectError(error.InvalidUniteBindings, bundle.validate());
    unites[2].damage_member = 0;
    try std.testing.expectError(error.InvalidUniteBindings, bundle.validate());
    unites[2] = parsed.value.unites[2];
    bundle.schema = "suikoden-unite-actors/4";
    try std.testing.expectError(error.InvalidUniteBindings, bundle.validate());
    var members: [3][2]host.MemberBinding = undefined;
    for ([_]usize{ 2, 19, 20 }, 0..) |record, index| {
        unites[record].damage_member = null;
        @memcpy(&members[index], unites[record].members);
        unites[record].members = &members[index];
        for (&members[index]) |*member| member.fan = null;
        members[index][0].reaction_group = false;
        members[index][0].reaction_on_hit = false;
    }
    var bumpy: [2]host.MemberBinding = undefined;
    @memcpy(&bumpy, unites[6].members);
    for (&bumpy) |*member| {
        member.start_after = 0;
        member.reaction_on_hit = false;
    }
    unites[6].members = &bumpy;
    unites[6].damage_member = null;
    unites[6].damage_signal = 2;
    unites[6].transition = null;
    var fatal: [2]host.MemberBinding = undefined;
    @memcpy(&fatal, unites[13].members);
    for (&fatal) |*member| {
        member.deferred_entry = false;
        member.reaction_on_hit = false;
        member.reaction_variant = 0;
    }
    unites[13].members = &fatal;
    unites[13].transition = null;
    unites[13].damage_member = null;
    unites[8].damage_member = null;
    var bandit: [2]host.MemberBinding = undefined;
    @memcpy(&bandit, unites[17].members);
    for (&bandit) |*member| {
        member.hit_camera = null;
        member.deferred_entry = false;
        member.reaction_on_hit = false;
        member.reaction_variant = 0;
    }
    unites[17].members = &bandit;
    unites[17].transition = null;
    unites[17].damage_member = null;
    for (unites) |*unite| {
        unite.controller = null;
        unite.damage_target_signal = null;
        unite.damage_reaction = true;
    }
    try bundle.validate();
    const encoded = try std.json.Stringify.valueAlloc(a, bundle, .{});
    defer a.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "reaction_group") == null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "damage_member") == null);
}

test "actor host advances real animation before VM and movement after VM in the same update" {
    var actors = [_]host.Actor{ try host.Actor.init(resource, .{ 0, 0, 0 }), try host.Actor.init(resource, .{ 10 * 4096, 20 * 4096, -30 * 4096 }) };
    const code = [_]vm.Instruction{
        .{ .command = .{ .animation = 1 } },                                                                                         .{ .wait = .{ .animation_done = {} } },
        .{ .command = .{ .motion = .{ .anchor = .owner, .updates = 3, .offset = .{ 2, 0, 0 }, .velocity_q12 = .{ 4096, 0, 0 } } } }, .{ .wait = .{ .movement_done = {} } },
        .{ .command = .{ .signal_set = .{ .target = .owner, .bits = 2 } } },                                                         .{ .halt = {} },
    };
    var runtime = host.Runtime{ .actors = &actors };
    try runtime.dispatch(0, 1, .{ .id = "dynamic", .instructions = &code });
    try std.testing.expectEqual(@as(u16, 0), actors[0].currentFrame().pose);
    try runtime.stepActor(0);
    try std.testing.expect(actors[0].movement == null);
    try runtime.stepActor(0);
    try std.testing.expectEqual(@as(u16, 1), actors[0].currentFrame().pose);
    try runtime.stepActor(0);
    try std.testing.expectEqual(@as(i32, 4096), actors[0].position_q12[0]);
    try std.testing.expectEqual(@as(u16, 2), actors[0].movement.?.remaining);
    try runtime.stepActor(0);
    try runtime.stepActor(0);
    try std.testing.expectEqual([3]i32{ 12 * 4096, 20 * 4096, 0 }, actors[0].position_q12);
    try std.testing.expectEqual(@as(u16, 0), actors[1].signals);
    try runtime.stepActor(0);
    try std.testing.expectEqual(@as(u16, 2), actors[1].signals);
    try std.testing.expect(actors[0].machine.?.halted);
}

test "actor host offsets interpolate with movement and immediate attachments use current owner pose" {
    var actors = [_]host.Actor{ try host.Actor.init(resource, .{ 0, 0, 0 }), try host.Actor.init(resource, .{ 0, 0, 0 }) };
    actors[1].baseline_offset = .{ -10, 10 };
    const code = [_]vm.Instruction{
        .{ .command = .{ .motion = .{ .anchor = .home, .updates = 10, .offset = .{ 0, 0, 0 }, .velocity_q12 = .{ 0, 0, 0 } } } },
        .{ .command = .{ .offsets = .{ .anchor = .owner, .value = .{ 0, 0 } } } },
        .{ .halt = {} },
    };
    var runtime = host.Runtime{ .actors = &actors };
    try runtime.dispatch(0, 1, .{ .id = "offset", .instructions = &code });
    try runtime.stepActor(0);
    try std.testing.expectEqual([2]i8{ -1, 1 }, actors[0].screen_offset);
    for (0..9) |_| try runtime.stepActor(0);
    try std.testing.expectEqual([2]i8{ -10, 10 }, actors[0].screen_offset);
    const attached = [_]vm.Instruction{ .{ .command = .{ .offsets = .{ .anchor = .owner, .value = .{ 0, 0 }, .from_sprite = true, .immediate = true } } }, .{ .halt = {} } };
    actors[1].animation = 1;
    actors[1].frame = 1;
    try runtime.dispatch(0, 1, .{ .id = "attachment", .instructions = &attached });
    try std.testing.expectEqual([2]i8{ -4, 3 }, actors[0].screen_offset);
    try std.testing.expectEqual([2]i32{ -4, 3 }, actors[0].offset_destination);
    const wrapped = [_]vm.Instruction{ .{ .command = .{ .offsets = .{ .anchor = .absolute, .value = .{ 130, -130 }, .immediate = true } } }, .{ .halt = {} } };
    try runtime.dispatch(0, 1, .{ .id = "wrapped", .instructions = &wrapped });
    try std.testing.expectEqual([2]i8{ -126, 126 }, actors[0].screen_offset);
    try std.testing.expectEqual([2]i32{ -126, 126 }, actors[0].offset_destination);
}

test "actor host refuses missing animations owners and external bindings" {
    var actors = [_]host.Actor{try host.Actor.init(resource, .{ 0, 0, 0 })};
    var runtime = host.Runtime{ .actors = &actors };
    const animation = [_]vm.Instruction{ .{ .command = .{ .animation = 99 } }, .{ .halt = {} } };
    try std.testing.expectError(error.MissingActorAnimation, runtime.dispatch(0, null, .{ .id = "bad", .instructions = &animation }));
    const sound = [_]vm.Instruction{ .{ .command = .{ .sound = 1 } }, .{ .halt = {} } };
    try std.testing.expectError(error.UnsupportedActorCommand, runtime.dispatch(0, null, .{ .id = "audio", .instructions = &sound }));
    const owner = [_]vm.Instruction{ .{ .wait = .{ .signal_set = .{ .target = .owner, .bits = 2 } } }, .{ .halt = {} } };
    try std.testing.expectError(error.MissingActorOwner, runtime.dispatch(0, null, .{ .id = "owner", .instructions = &owner }));
    var invalid = resource;
    invalid.pose_count = 1;
    try std.testing.expectError(error.InvalidActorAnimations, invalid.validate());
}

const Observer = struct {
    sounds: usize = 0,
    effects: usize = 0,
    captures: usize = 0,
    screen: @import("battle").presentation.ScreenPoint = .{ .x = 10, .y = 20, .depth = 30 },
    fn previousScreen(ctx: *anyopaque, id: u16) !@import("battle").presentation.ScreenPoint {
        _ = id;
        const self: *Observer = @ptrCast(@alignCast(ctx));
        self.captures += 1;
        return self.screen;
    }
    fn command(ctx: *anyopaque, id: u16, c: vm.Command, resuming: bool) !bool {
        _ = id;
        _ = resuming;
        const self: *Observer = @ptrCast(@alignCast(ctx));
        switch (c) {
            .sound => self.sounds += 1,
            .effect => |e| {
                if (!std.mem.eql(u8, e.id, "blue_afterimages")) return error.UnboundEffect;
                self.effects += 1;
            },
            else => return error.UnboundCommand,
        }
        return true;
    }
};
test "exported Blacksmith programs execute in shared animation physics and signal host" {
    const parsed = try host.loadBundle(a, @embedFile("fixtures/unite_actor_library.json"));
    defer parsed.deinit();
    const programs = parsed.value.programs;
    const resources = parsed.value.animations;
    for ([_]struct { id: []const u8, hit: u16, ready: u16, end: u16 }{ .{ .id = "maas", .hit = 73, .ready = 77, .end = 123 }, .{ .id = "moose", .hit = 73, .ready = 77, .end = 123 }, .{ .id = "meese", .hit = 73, .ready = 77, .end = 123 }, .{ .id = "mace", .hit = 74, .ready = 78, .end = 124 }, .{ .id = "mose", .hit = 72, .ready = 77, .end = 126 } }) |case| {
        const actor_resource = resources.find(case.id).?;
        var actors = [_]host.Actor{ try host.Actor.init(actor_resource, .{ 0, 0, 0 }), try host.Actor.init(actor_resource, .{ 200 * 4096, 40 * 4096, -30 * 4096 }) };
        actors[1].baseline_offset = .{ -10, 10 };
        var observer = Observer{};
        var runtime = host.Runtime{ .actors = &actors, .library = parsed.value.library(), .external = .{ .context = &observer, .command = Observer.command, .previous_screen_position = Observer.previousScreen } };
        const id = try std.fmt.allocPrint(a, "{s}/unite_9", .{case.id});
        defer a.free(id);
        try runtime.dispatch(0, 1, programs.find(id).?);
        var first_hit: u16 = 0;
        var first_ready: u16 = 0;
        var ending: u16 = 0;
        var returned = false;
        for (1..301) |step| {
            if (!returned and actors[0].signals & 4 != 0) {
                actors[0].signals &= ~@as(u16, 4);
                try runtime.dispatch(0, 1, programs.find("common/unite_return").?);
                returned = true;
            }
            try runtime.stepActor(0);
            if (step >= 14 and step <= 45) {
                if (step < 45) {
                    const trail = actors[0].blue_trail.?;
                    try std.testing.expectEqual(@as(u16, 4), trail.pose);
                    try std.testing.expectEqual(step >= 15 and step < 44, trail.visible);
                } else try std.testing.expect(actors[0].blue_trail == null and !actors[0].blue_trail_active);
            }
            if (step == 14) try std.testing.expectEqual([3]i32{ -8 * 4096, 0, -8 * 4096 }, actors[0].position_q12);
            if (step == 34) try std.testing.expectEqual([2]i8{ -1, 1 }, actors[0].screen_offset);
            if (first_hit == 0 and actors[0].signals & 2 != 0) first_hit = @intCast(step);
            if (first_ready == 0 and actors[0].signals & 4 != 0) first_ready = @intCast(step);
            if (actors[0].released) {
                ending = @intCast(step);
                break;
            }
        }
        try std.testing.expectEqual(case.hit, first_hit);
        try std.testing.expectEqual(case.ready, first_ready);
        try std.testing.expectEqual(case.end, ending);
        try std.testing.expectEqual(@as(usize, 2), observer.sounds);
        try std.testing.expectEqual(@as(usize, 0), observer.effects);
        try std.testing.expectEqual([3]i32{ 0, 0, 0 }, actors[0].position_q12);
        try std.testing.expectEqual([2]i8{ 0, 0 }, actors[0].screen_offset);
    }
}

test "actor host owner highlights and shared value entry yield preserve source semantics" {
    var actors = [_]host.Actor{ try host.Actor.init(resource, .{ 0, 0, 0 }), try host.Actor.init(resource, .{ 0, 0, 0 }) };
    var runtime = host.Runtime{ .actors = &actors };
    const code = [_]vm.Instruction{
        .{ .command = .{ .highlight = .{ .target = .self, .bits = 2, .set = true } } },
        .{ .command = .{ .highlight = .{ .target = .owner, .bits = 4, .set = true } } },
        .{ .command = .{ .shared_value = 7 } },
        .{ .command = .{ .highlight = .{ .target = .owner, .bits = 4, .set = false } } },
        .{ .command = .{ .signal_set = .{ .target = .self, .bits = 2 } } },
        .{ .halt = {} },
    };
    try runtime.dispatch(0, 1, .{ .id = "synchronize", .instructions = &code });
    try std.testing.expectEqual(@as(u8, 2), actors[0].highlights);
    try std.testing.expectEqual(@as(u8, 4), actors[1].highlights);
    try std.testing.expectEqual(@as(i16, 7), actors[0].shared_value);
    try std.testing.expectEqual(@as(u16, 0), actors[0].signals);
    // A callback may change the mailbox before polling; resumption must not rewrite it.
    actors[0].shared_value = 9;
    try runtime.stepActor(0);
    try std.testing.expectEqual(@as(i16, 9), actors[0].shared_value);
    try std.testing.expectEqual(@as(u8, 2), actors[0].highlights);
    try std.testing.expectEqual(@as(u8, 0), actors[1].highlights);
    try std.testing.expectEqual(@as(u16, 2), actors[0].signals);
    try std.testing.expect(actors[0].machine.?.halted);
}

const Lifetime = struct {
    released: usize = 0,
    fn release(context: *anyopaque, id: u16) !void {
        _ = id;
        const self: *Lifetime = @ptrCast(@alignCast(context));
        self.released += 1;
    }
    fn reject(_: *anyopaque, _: u16, _: vm.Command, _: bool) !bool {
        return error.UnboundCommand;
    }
};
test "actor child slots retry once free dispatch immediately and release after teardown polling" {
    const child_code = [_]vm.Instruction{
        .{ .command = .{ .signal_set = .{ .target = .owner, .bits = 8 } } },
        .{ .command = .{ .motion = .{ .anchor = .home, .updates = 3, .offset = .{ 0, 0, 0 }, .velocity_q12 = .{ 0, 0, 0 }, .kind = .linear } } },
        .{ .wait = .{ .movement_done = {} } },
        .{ .command = .{ .teardown = {} } },
        .{ .halt = {} },
    };
    const parent_code = [_]vm.Instruction{
        .{ .command = .{ .child = .{ .program = "child", .resource = "actor", .animation = 1, .owner = .owner, .home = .parent_owner, .draw_record = true, .offset = .{ -2, 3, -4 } } } },
        .{ .halt = {} },
    };
    const library = host.Library{ .programs = .{ .schema = "suikoden-actor-programs/7", .programs = &.{ .{ .id = "parent", .instructions = &parent_code }, .{ .id = "child", .instructions = &child_code } } }, .resources = .{ .schema = "suikoden-actor-animations/1", .resources = &.{resource} } };
    try library.programs.validate();
    var actors = [_]host.Actor{ try host.Actor.init(resource, .{ 10 * 4096, 20 * 4096, 30 * 4096 }), try host.Actor.init(resource, .{ 100 * 4096, 200 * 4096, 300 * 4096 }) };
    var pool = [_]?host.Actor{ try host.Actor.init(resource, .{ 0, 0, 0 }), try host.Actor.init(resource, .{ 0, 0, 0 }) };
    var lifetime = Lifetime{};
    var runtime = host.Runtime{ .actors = &actors, .auxiliary = &pool, .library = library, .external = .{ .context = &lifetime, .command = Lifetime.reject, .release_actor = Lifetime.release } };
    try runtime.dispatch(0, 1, library.programs.find("parent").?);
    try std.testing.expect(actors[0].machine.?.resuming_command);
    try std.testing.expectEqual(@as(u16, 0), actors[1].signals);
    pool[1] = null;
    try runtime.stepActor(0);
    try std.testing.expect(actors[0].machine.?.halted);
    try std.testing.expectEqual(@as(u16, 8), actors[1].signals);
    try std.testing.expectEqual(@as(?u16, 1), pool[1].?.owner);
    try std.testing.expectEqual([3]i32{ 8 * 4096, 23 * 4096, 26 * 4096 }, pool[1].?.position_q12);
    try std.testing.expectEqual(actors[1].position_q12, pool[1].?.home_q12);
    try std.testing.expectEqual(@as(u16, 1), pool[1].?.animation);
    try std.testing.expect(pool[1].?.has_draw_record);
    for (0..3) |_| try runtime.stepActor(3);
    try std.testing.expectEqual(actors[1].position_q12, pool[1].?.position_q12);
    try runtime.stepActor(3);
    try std.testing.expect(!pool[1].?.visible);
    try std.testing.expectEqual(@as(usize, 0), lifetime.released);
    try runtime.stepActor(3);
    try std.testing.expect(pool[1] == null and pool[0] != null);
    try std.testing.expectEqual(@as(usize, 1), lifetime.released);
    try std.testing.expectError(error.InvalidActorBinding, runtime.stepActor(3));
    try runtime.dispatch(0, 1, library.programs.find("parent").?);
    try std.testing.expect(pool[1] != null);
}

test "actor linear motion uses XYZ anchors constant velocity and a single-update snap" {
    var actors = [_]host.Actor{ try host.Actor.init(resource, .{ 0, 0, 0 }), try host.Actor.init(resource, .{ 10 * 4096, -20 * 4096, 30 * 4096 }) };
    var runtime = host.Runtime{ .actors = &actors };
    const code = [_]vm.Instruction{ .{ .command = .{ .motion = .{ .anchor = .owner, .updates = 3, .offset = .{ 2, -1, 3 }, .velocity_q12 = .{ 0, 0, 0 }, .kind = .linear } } }, .{ .wait = .{ .movement_done = {} } }, .{ .halt = {} } };
    try runtime.dispatch(0, 1, .{ .id = "linear", .instructions = &code });
    try runtime.stepActor(0);
    try std.testing.expectEqual([3]i32{ 4 * 4096, -7 * 4096, 11 * 4096 }, actors[0].position_q12);
    try runtime.stepActor(0);
    try std.testing.expectEqual([3]i32{ 8 * 4096, -14 * 4096, 22 * 4096 }, actors[0].position_q12);
    try runtime.stepActor(0);
    try std.testing.expectEqual([3]i32{ 12 * 4096, -21 * 4096, 33 * 4096 }, actors[0].position_q12);
    const snap = [_]vm.Instruction{ .{ .command = .{ .motion = .{ .anchor = .home, .updates = 1, .offset = .{ 0, 0, 0 }, .velocity_q12 = .{ 0, 0, 0 }, .kind = .snap } } }, .{ .halt = {} } };
    try runtime.dispatch(0, 1, .{ .id = "snap", .instructions = &snap });
    try std.testing.expectEqual([3]i32{ 0, 0, 0 }, actors[0].velocity_q12);
    try runtime.stepActor(0);
    try std.testing.expectEqual([3]i32{ 0, 0, 0 }, actors[0].position_q12);
}

test "actor zero-duration snap waits one movement update before continuing" {
    var actors = [_]host.Actor{try host.Actor.init(resource, .{ 100 * 4096, 0, 0 })};
    var runtime = host.Runtime{ .actors = &actors };
    const code = [_]vm.Instruction{
        .{ .command = .{ .motion = .{ .anchor = .home, .updates = 1, .offset = .{ 0, 0, -400 }, .velocity_q12 = .{ 0, 0, 0 }, .kind = .snap } } },
        .{ .wait = .{ .movement_done = {} } },
        .{ .command = .{ .signal_set = .{ .target = .self, .bits = 2 } } },
        .{ .halt = {} },
    };
    try runtime.dispatch(0, null, .{ .id = "snap_wait", .instructions = &code });
    try std.testing.expectEqual(@as(u16, 0), actors[0].signals);
    try runtime.stepActor(0);
    try std.testing.expectEqual([3]i32{ 100 * 4096, 0, -400 * 4096 }, actors[0].position_q12);
    try std.testing.expectEqual(@as(u16, 0), actors[0].signals);
    try runtime.stepActor(0);
    try std.testing.expectEqual(@as(u16, 2), actors[0].signals);
}

test "nine exported Unite child bindings spawn with their original animation owner and home" {
    const Fixture = struct { programs: vm.Packet, animations: host.Resources };
    const parsed = try std.json.parseFromSlice(Fixture, a, @embedFile("fixtures/unite_actor_vm.json"), .{});
    defer parsed.deinit();
    try parsed.value.programs.validate();
    try parsed.value.animations.validate();
    var checked: usize = 0;
    for (parsed.value.programs.programs) |program| for (program.instructions) |instruction| {
        if (instruction != .command or instruction.command != .child) continue;
        const child = instruction.command.child;
        const separator = std.mem.indexOfScalar(u8, program.id, '/').?;
        const source_resource = parsed.value.animations.find(program.id[0..separator]).?;
        var actors = [_]host.Actor{ try host.Actor.init(source_resource, .{ 0, 0, 0 }), try host.Actor.init(source_resource, .{ 100 * 4096, 20 * 4096, -30 * 4096 }) };
        var pool = [_]?host.Actor{ null, null };
        var observer = Observer{};
        var runtime = host.Runtime{ .actors = &actors, .auxiliary = &pool, .library = .{ .programs = parsed.value.programs, .resources = parsed.value.animations }, .external = .{ .context = &observer, .command = Observer.command, .previous_screen_position = Observer.previousScreen } };
        try runtime.dispatch(0, 1, program);
        var parent_position = actors[0].position_q12;
        for (0..500) |_| {
            if (pool[1] != null) break;
            parent_position = actors[0].position_q12;
            try runtime.stepActor(0);
        }
        const spawned = pool[1] orelse return error.ChildDidNotSpawn;
        try std.testing.expect(pool[0] == null);
        try std.testing.expectEqual(@as(?u16, 0), spawned.owner);
        try std.testing.expectEqual(child.animation, spawned.animation);
        try std.testing.expectEqualStrings(child.resource, spawned.resource.?.id);
        try std.testing.expectEqual(if (child.home == .parent_owner) actors[1].position_q12 else spawned.position_q12, spawned.home_q12);
        for (0..3) |axis| try std.testing.expectEqual(parent_position[axis] + @as(i32, child.offset[axis]) * 4096, spawned.position_q12[axis]);
        // Child sound and mailbox entry execute during spawn; its effect callback waits for polling.
        if (std.mem.eql(u8, child.resource, "shared_impacts")) {
            try std.testing.expect(!spawned.has_draw_record);
            try std.testing.expectEqual(actors[0].currentFrame().attachment, [2]i16{ spawned.screen_offset[0], spawned.screen_offset[1] });
            try std.testing.expect(spawned.machine.?.instructions[spawned.machine.?.pc] == .wait);
            var duration: usize = 0;
            for (spawned.resource.?.find(child.animation).?.frames) |frame| duration += frame.updates;
            try std.testing.expectEqual(@as(usize, 19), duration);
            for (0..duration) |_| try runtime.stepActor(3);
            try std.testing.expect(!pool[1].?.visible);
            try runtime.stepActor(3);
            try std.testing.expect(pool[1] == null);
        } else {
            try std.testing.expect(spawned.machine.?.resuming_command);
            try std.testing.expectEqual(@as(i16, 0), spawned.shared_value);
        }
        checked += 1;
    };
    try std.testing.expectEqual(@as(usize, 9), checked);
}

test "actor hidden and translucent states preserve script animation and movement updates" {
    var actors = [_]host.Actor{try host.Actor.init(resource, .{ 0, 0, 0 })};
    var runtime = host.Runtime{ .actors = &actors };
    const code = [_]vm.Instruction{
        .{ .command = .{ .reset_draw = false } },
        .{ .command = .{ .translucent = true } },
        .{ .command = .{ .visible = false } },
        .{ .command = .{ .animation = 1 } },
        .{ .command = .{ .motion = .{ .anchor = .absolute, .updates = 2, .offset = .{ 2, 0, 0 }, .velocity_q12 = .{ 0, 0, 0 }, .kind = .linear } } },
        .{ .wait = .{ .animation_done = {} } },
        .{ .command = .{ .visible = true } },
        .{ .command = .{ .translucent = false } },
        .{ .command = .{ .reset_draw = true } },
        .{ .halt = {} },
    };
    try runtime.dispatch(0, null, .{ .id = "hidden", .instructions = &code });
    try std.testing.expect(!actors[0].visible and actors[0].translucent);
    try std.testing.expect(actors[0].palette == .shared and actors[0].palette.shared == 0);
    try runtime.stepActor(0);
    try std.testing.expectEqual(@as(i32, 4096), actors[0].position_q12[0]);
    try runtime.stepActor(0);
    try std.testing.expectEqual(@as(u16, 1), actors[0].currentFrame().pose);
    try std.testing.expectEqual(@as(i32, 8192), actors[0].position_q12[0]);
    try std.testing.expect(!actors[0].visible);
    try runtime.stepActor(0);
    try std.testing.expect(actors[0].visible and !actors[0].translucent and actors[0].machine.?.halted);
    try std.testing.expect(actors[0].palette == .resource);
}

test "exported Lepant palette cycle follows four-update phases and restores on mailbox stop" {
    const Fixture = struct { programs: vm.Packet, animations: host.Resources };
    const parsed = try std.json.parseFromSlice(Fixture, a, @embedFile("fixtures/unite_actor_vm.json"), .{});
    defer parsed.deinit();
    try parsed.value.programs.validate();
    try parsed.value.animations.validate();
    const actor_resource = parsed.value.animations.find("lepant").?;
    var actors = [_]host.Actor{ try host.Actor.init(actor_resource, .{ 0, 0, 0 }), try host.Actor.init(actor_resource, .{ 100 * 4096, 20 * 4096, -30 * 4096 }) };
    var observer = Observer{};
    var runtime = host.Runtime{ .actors = &actors, .external = .{ .context = &observer, .command = Observer.command, .previous_screen_position = Observer.previousScreen } };
    try runtime.dispatch(0, 1, parsed.value.programs.find("lepant/unite_10").?);
    try std.testing.expect(actors[0].palette == .resource);
    var hit: usize = 0;
    var ready: usize = 0;
    for (1..74) |update| {
        try runtime.stepActor(0);
        if (hit == 0 and actors[0].signals & 2 != 0) hit = update;
        if (ready == 0 and actors[0].signals & 4 != 0) ready = update;
        for ([_]struct { update: usize, variant: u8 }{ .{ .update = 2, .variant = 1 }, .{ .update = 5, .variant = 2 }, .{ .update = 9, .variant = 3 }, .{ .update = 13, .variant = 1 }, .{ .update = 59, .variant = 3 } }) |sample| {
            if (update == sample.update) try std.testing.expectEqual(sample.variant, actors[0].palette.shared);
        }
        if (update == 1) try std.testing.expect(actors[0].palette == .resource and actors[0].shared_value == 1);
        if (update >= 60) try std.testing.expect(actors[0].palette == .resource and !actors[0].palette_cycle_active and actors[0].palette_cycle_state == null);
    }
    try std.testing.expectEqual(@as(usize, 45), hit);
    try std.testing.expectEqual(@as(usize, 73), ready);
    try std.testing.expect(actors[0].machine.?.halted);
    try std.testing.expectEqual([3]i32{ -50 * 4096, 20 * 4096, -30 * 4096 }, actors[0].position_q12);
    try std.testing.expectEqual(@as(usize, 2), observer.sounds);
    try std.testing.expectEqual(@as(usize, 0), observer.effects);
}

test "Couple recipient palette and screen offsets match the shared actor interpreter" {
    const battle = @import("battle");
    const parsed = try vm.load(a, @embedFile("fixtures/couple_recipient_program.json"));
    defer parsed.deinit();
    const effects = try battle.spell_scene.load(a, @embedFile("fixtures/spell_scene_library.json"));
    defer effects.deinit();
    const reaction = for (effects.value.unite_reactions) |value| {
        if (value.record == 16 and value.variant == 0) break value;
    } else return error.MissingCoupleReaction;
    try std.testing.expect(reaction.blocker == null and reaction.palette_cycle != null);
    const pose = battle.spell_scene.HurtPose{ .id = "actor", .entry = 10, .flash_entries = .{ 11, 12, 13 } };
    var actors = [_]host.Actor{try host.Actor.init(resource, .{ 0, 0, 0 })};
    var runtime = host.Runtime{ .actors = &actors };
    try runtime.dispatch(0, null, parsed.value.find("couple/recipient").?);
    for (0..reaction.duration) |age| {
        try runtime.stepActor(0);
        const sample = battle.spell_scene.uniteReactionAt(reaction, pose, @intCast(age)).?;
        const expected: u16 = switch (actors[0].palette) {
            .resource => pose.entry,
            .shared => |row| pose.flash_entries.?[row - 1],
        };
        try std.testing.expectEqual(expected, sample.entry.?);
        try std.testing.expectEqualDeep([2]i16{ actors[0].screen_offset[0], actors[0].screen_offset[1] }, sample.offset);
    }
    var packet = effects.value;
    const reactions = try a.dupe(battle.spell_scene.UniteReaction, packet.unite_reactions);
    defer a.free(reactions);
    const index = for (reactions, 0..) |value, i| {
        if (value.record == 16 and value.variant == 0) break i;
    } else return error.MissingCoupleReaction;
    packet.unite_reactions = reactions;
    packet.schema = "suikoden-spell-scenes/43";
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    packet.schema = "suikoden-spell-scenes/45";
    try packet.validate(4096, 4096);
    const original = reactions[index].palette_cycle.?;
    reactions[index].palette_cycle.?.period = 0;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    reactions[index].palette_cycle = original;
    reactions[index].palette_cycle.?.row = 2;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    reactions[index].palette_cycle = original;
    reactions[index].palette_cycle.?.stop = reaction.duration + 1;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
}

test "Beat recipient movement and idle palette match the shared actor interpreter" {
    const battle = @import("battle");
    const source = try vm.load(a, @embedFile("fixtures/beat_em_up_recipient_program.json"));
    defer source.deinit();
    const library = try physicalFixture();
    defer library.deinit();
    const effects = try battle.spell_scene.load(a, @embedFile("fixtures/spell_scene_library.json"));
    defer effects.deinit();
    const reaction = for (effects.value.unite_reactions) |value| {
        if (value.record == 27 and value.variant == 0) break value;
    } else return error.MissingBeatReaction;
    const idle_frames = [_]host.Frame{ .{ .pose = 0, .updates = 3 }, .{ .pose = 1, .updates = 5 } };
    const actor_clips = [_]host.Clip{ .{ .id = 0, .advances = true, .loop = false, .frames = &idle_frames }, .{ .id = 1, .advances = false, .loop = false, .frames = frames[0..1] } };
    const actor_resource = host.Resource{ .id = "target", .pose_count = 2, .clips = &actor_clips };
    const idle_art = [_]battle.spell_scene.IdleFlashFrame{
        .{ .ticks = 3, .entries = .{ 21, 22, 23 }, .normal = 20 }, .{ .ticks = 5, .entries = .{ 31, 32, 33 }, .normal = 30 },
    };
    const pose = battle.spell_scene.HurtPose{ .id = "target", .entry = 10, .flash_entries = .{ 11, 12, 13 }, .idle_flash = .{ .advances = true, .loop = false, .frames = &idle_art } };
    const home = [3]i32{ 200 * 4096 + 137, 40 * 4096 - 19, -30 * 4096 + 73 };
    const origin = [3]i32{ 180 * 4096 + 29, 35 * 4096 + 13, -20 * 4096 - 7 };
    var actors = [_]host.Actor{try host.Actor.init(actor_resource, home)};
    actors[0].position_q12 = origin;
    var children: [19]?host.Actor = @splat(null);
    var observer = Observer{};
    var runtime = host.Runtime{ .actors = &actors, .auxiliary = &children, .library = .{ .programs = source.value, .resources = library.value.animations }, .external = .{ .context = &observer, .command = Observer.command } };
    try runtime.dispatch(0, null, source.value.find("beat_recipient").?);
    for (0..reaction.duration) |age| {
        try runtime.stepActor(0);
        for (0..children.len) |i| if (children[i] != null) try runtime.stepActor(@intCast(i + 1));
        try std.testing.expectEqualDeep(actors[0].position_q12, battle.spell_scene.unitePosition(reaction, origin, home, @intCast(age)));
        const sample = battle.spell_scene.uniteReactionAt(reaction, pose, @intCast(age)).?;
        try std.testing.expectEqual(@as(u8, @intCast(actors[0].animation)), sample.animation);
        const expected: ?u16 = switch (actors[0].palette) {
            .resource => if (actors[0].animation == 1) pose.entry else idle_art[actors[0].frame].normal,
            .shared => |row| if (actors[0].animation == 1) pose.flash_entries.?[row - 1] else idle_art[actors[0].frame].entries[row - 1],
        };
        try std.testing.expectEqual(expected, sample.entry);
    }
    try std.testing.expectEqualDeep(home, actors[0].position_q12);
    try std.testing.expectEqual(@as(usize, 1), observer.sounds);
    var packet = effects.value;
    packet.schema = "suikoden-spell-scenes/44";
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    packet.schema = "suikoden-spell-scenes/45";
    try packet.validate(4096, 4096);
    const hurt = try a.dupe(battle.spell_scene.HurtPose, packet.hurt_poses);
    defer a.free(hurt);
    packet.hurt_poses = hurt;
    const index = for (hurt, 0..) |p, i| {
        if (p.idle_flash != null) break i;
    } else return error.MissingIdleFlash;
    var idle = hurt[index].idle_flash.?;
    idle.frames = &.{};
    hurt[index].idle_flash = idle;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
}

test "Lepant Family recipient reactions match their shared actor programs" {
    const battle = @import("battle");
    const source = try vm.load(a, @embedFile("fixtures/lepant_family_recipient_programs.json"));
    defer source.deinit();
    const effects = try battle.spell_scene.load(a, @embedFile("fixtures/spell_scene_library.json"));
    defer effects.deinit();
    const impact_clips = [_]host.Clip{
        .{ .id = 0, .advances = true, .loop = false, .frames = frames[0..1] },
        .{ .id = 1, .advances = true, .loop = false, .frames = frames[0..1] },
        .{ .id = 2, .advances = true, .loop = false, .frames = frames[0..1] },
    };
    const resources = [_]host.Resource{.{ .id = "shared_impacts", .pose_count = 2, .clips = &impact_clips }};
    const names = [_][]const u8{ "family/recipient1", "family/recipient2", "family/recipient3" };
    const home = [3]i32{ 200 * 4096 + 137, 40 * 4096 - 19, -30 * 4096 + 73 };
    const origin = [3]i32{ 180 * 4096 + 29, 35 * 4096 + 13, -20 * 4096 - 7 };
    const pose = battle.spell_scene.HurtPose{ .id = "target", .entry = 10, .white_entry = 11 };
    for (names, 1..) |name, variant| {
        const reaction = for (effects.value.unite_reactions) |value| {
            if (value.record == 30 and value.variant == variant) break value;
        } else return error.MissingFamilyReaction;
        var actors = [_]host.Actor{try host.Actor.init(resource, home)};
        actors[0].position_q12 = origin;
        var children: [19]?host.Actor = @splat(null);
        var observer = Observer{};
        var runtime = host.Runtime{ .actors = &actors, .auxiliary = &children, .library = .{ .programs = source.value, .resources = .{ .schema = "suikoden-actor-animations/1", .resources = &resources } }, .external = .{ .context = &observer, .command = Observer.command } };
        try runtime.dispatch(0, null, source.value.find(name).?);
        for (0..reaction.duration) |age| {
            try runtime.stepActor(0);
            for (0..children.len) |i| if (children[i] != null) try runtime.stepActor(@intCast(i + 1));
            try std.testing.expectEqualDeep(actors[0].position_q12, battle.spell_scene.unitePosition(reaction, origin, home, @intCast(age)));
            const sample = battle.spell_scene.uniteReactionAt(reaction, pose, @intCast(age)).?;
            if (actors[0].animation != sample.animation) std.debug.print("family variant {d} age {d}: actor animation {d}, sample {d}\n", .{ variant, age, actors[0].animation, sample.animation });
            try std.testing.expectEqual(@as(u8, @intCast(actors[0].animation)), sample.animation);
            const expected: ?u16 = if (actors[0].animation == 0) null else switch (actors[0].palette) {
                .resource => pose.entry,
                .shared => |row| if (row == 0) pose.white_entry else return error.UnexpectedPalette,
            };
            try std.testing.expectEqual(expected, sample.entry);
            const signal = for (reaction.signals) |event| {
                if (age >= event.at and event.set) break event.bits;
            } else @as(u16, 0);
            try std.testing.expectEqual(signal, actors[0].signals);
        }
    }
}

test "Pirate recipient initial jump wait matches the actor interpreter" {
    const battle = @import("battle");
    const source = try vm.load(a, @embedFile("fixtures/pirate_recipient_program.json"));
    defer source.deinit();
    const library = try physicalFixture();
    defer library.deinit();
    const effects = try battle.spell_scene.load(a, @embedFile("fixtures/spell_scene_library.json"));
    defer effects.deinit();
    const reaction = for (effects.value.unite_reactions) |value| {
        if (value.record == 4 and value.variant == 0) break value;
    } else return error.MissingPirateReaction;
    const pose = battle.spell_scene.HurtPose{ .id = "target", .entry = 10, .white_entry = 11 };
    const home = [3]i32{ 200 * 4096 + 137, 40 * 4096 - 19, -30 * 4096 + 73 };
    const origin = [3]i32{ 180 * 4096 + 29, 35 * 4096 + 13, -20 * 4096 - 7 };
    var actors = [_]host.Actor{try host.Actor.init(resource, home)};
    actors[0].position_q12 = origin;
    var children: [19]?host.Actor = @splat(null);
    var observer = Observer{};
    var runtime = host.Runtime{ .actors = &actors, .auxiliary = &children, .library = .{ .programs = source.value, .resources = library.value.animations }, .external = .{ .context = &observer, .command = Observer.command } };
    try runtime.dispatch(0, null, source.value.find("pirate/recipient").?);
    for (0..reaction.duration) |age| {
        try runtime.stepActor(0);
        for (0..children.len) |i| if (children[i] != null) try runtime.stepActor(@intCast(i + 1));
        try std.testing.expectEqualDeep(actors[0].position_q12, battle.spell_scene.unitePosition(reaction, origin, home, @intCast(age)));
        const sample = battle.spell_scene.uniteReactionAt(reaction, pose, @intCast(age)).?;
        try std.testing.expectEqual(@as(u8, @intCast(actors[0].animation)), sample.animation);
        try std.testing.expectEqualDeep([2]i16{ actors[0].screen_offset[0], actors[0].screen_offset[1] }, sample.offset);
    }
    try std.testing.expectEqualDeep(home, actors[0].position_q12);
}

test "actor palette cycle survives script halt and rejects missing or invalid configuration" {
    var actors = [_]host.Actor{try host.Actor.init(resource, .{ 0, 0, 0 })};
    var runtime = host.Runtime{ .actors = &actors };
    const missing = [_]vm.Instruction{ .{ .command = .{ .effect = .{ .id = "palette_cycle", .binding = .shared } } }, .{ .halt = {} } };
    try std.testing.expectError(error.MissingPaletteCycleConfig, runtime.dispatch(0, null, .{ .id = "missing", .instructions = &missing }));
    const invalid = [_]vm.Instruction{ .{ .command = .{ .palette_cycle = .{ .variants = .{ 1, 2, 7 }, .updates = 1 } } }, .{ .halt = {} } };
    try std.testing.expectError(error.InvalidPaletteCycleConfig, runtime.dispatch(0, null, .{ .id = "invalid", .instructions = &invalid }));
    try std.testing.expectError(error.InvalidActorPrograms, (vm.Packet{ .schema = "suikoden-actor-programs/7", .programs = &.{.{ .id = "invalid", .instructions = &invalid }} }).validate());
    const code = [_]vm.Instruction{ .{ .command = .{ .palette_cycle = .{ .variants = .{ 1, 2, 3 }, .updates = 1 } } }, .{ .command = .{ .effect = .{ .id = "palette_cycle", .binding = .shared } } }, .{ .halt = {} } };
    try runtime.dispatch(0, null, .{ .id = "cycle", .instructions = &code });
    try std.testing.expect(actors[0].machine.?.halted);
    try runtime.stepActor(0);
    try std.testing.expectEqual(@as(i16, 1), actors[0].shared_value);
    try runtime.stepActor(0);
    try std.testing.expectEqual(@as(u8, 2), actors[0].palette.shared);
    actors[0].shared_value = 99;
    try runtime.stepActor(0);
    try std.testing.expect(actors[0].palette == .resource and !actors[0].palette_cycle_active);
}

const Battle = @import("battle");
const Field = @import("field");
const Rules = Battle.systems;
const RecoveryBridge = struct {
    state: *Battle.State,
    requests: usize = 0,
    effects: Observer = .{},
    fn previousScreen(ctx: *anyopaque, id: u16) !@import("battle").presentation.ScreenPoint {
        const self: *RecoveryBridge = @ptrCast(@alignCast(ctx));
        return Observer.previousScreen(&self.effects, id);
    }
    fn command(context: *anyopaque, id: u16, request: vm.Command, resuming: bool) !bool {
        const self: *RecoveryBridge = @ptrCast(@alignCast(context));
        if (request == .recovery) {
            try self.state.requestUniteRecovery(id, request.recovery);
            self.requests += 1;
            return true;
        }
        return Observer.command(&self.effects, id, request, resuming);
    }
};

test "exported actor recovery programs use party Turtle gates draws and retained round boundaries" {
    const Fixture = struct { programs: vm.Packet, animations: host.Resources };
    const scripts = try std.json.parseFromSlice(Fixture, a, @embedFile("fixtures/unite_actor_vm.json"), .{});
    defer scripts.deinit();
    try scripts.value.programs.validate();
    const content = try Battle.load(a, @embedFile("fixtures/journey_battle.json"));
    defer content.deinit();
    const items = try Field.items.load(a, Field.items.json);
    defer items.deinit();
    for ([_]struct { id: []const u8, resource_id: []const u8, end: usize }{ .{ .id = "common/fisherman_return", .resource_id = "tai_ho", .end = 52 }, .{ .id = "kasumi/unite_10", .resource_id = "kasumi", .end = 192 }, .{ .id = "pahn/unite_10", .resource_id = "pahn", .end = 395 } }) |case| {
        for ([_]u15{ 0, 32767 }) |roll| for (0..3) |variant| {
            var members: [6]Battle.Member = undefined;
            var state = try Battle.State.init(content.value, items.value, &members, 17);
            const turtle = variant == 1;
            const existing: u8 = if (variant == 2 or turtle) 1 else 0;
            state.runes[0] = if (turtle) content.value.systems.?.runeIndex("turtle").? else null;
            state.unbalanced[0] = existing;
            state.progress.party[0].status = .poisoned;
            state.progress.party[0].balloons = 2;
            state.accuracy_reduced[0] = true;
            state.protection[0] = 3;
            const values = [_]u15{roll};
            var draws = Rules.Draws{ .values = &values };
            state.replay_draws = &draws;
            const actor_resource = scripts.value.animations.find(case.resource_id).?;
            // The real resource program binds to a test party slot, independent of scene admission.
            var actors = [_]host.Actor{ try host.Actor.init(actor_resource, .{ 0, 0, 0 }), try host.Actor.init(actor_resource, .{ 100 * 4096, 20 * 4096, -30 * 4096 }) };
            var bridge = RecoveryBridge{ .state = &state };
            var runtime = host.Runtime{ .actors = &actors, .external = .{ .context = &bridge, .command = RecoveryBridge.command, .previous_screen_position = RecoveryBridge.previousScreen } };
            try runtime.dispatch(0, 1, scripts.value.programs.find(case.id).?);
            for (1..case.end + 1) |update| {
                try runtime.stepActor(0);
                if (update < case.end) try std.testing.expectEqual(existing, state.unbalanced[0]);
            }
            try std.testing.expect(actors[0].machine.?.halted);
            try std.testing.expectEqual(@as(usize, 1), bridge.requests);
            try std.testing.expectEqual(@as(usize, if (turtle) 0 else 1), draws.cursor);
            try std.testing.expectEqual(@as(u8, if (existing != 0) existing else 2), state.unbalanced[0]);
            try std.testing.expectEqual(Field.game_state.Status.poisoned, state.progress.party[0].status);
            try std.testing.expectEqual(@as(u8, 2), state.progress.party[0].balloons);
            try std.testing.expect(state.accuracy_reduced[0]);
            try std.testing.expectEqual(@as(u8, 3), state.protection[0]);
            state.replay_draws = null;
            if (existing == 0) {
                state.applyRoundBoundaryStatuses();
                try std.testing.expectEqual(@as(u8, 1), state.unbalanced[0]);
                state.applyRoundBoundaryStatuses();
                try std.testing.expectEqual(@as(u8, 0), state.unbalanced[0]);
            }
        };
    }
}

test "actor recovery refuses invalid targets and exhausted draws without applying status" {
    const content = try Battle.load(a, @embedFile("fixtures/journey_battle.json"));
    defer content.deinit();
    const items = try Field.items.load(a, Field.items.json);
    defer items.deinit();
    var members: [6]Battle.Member = undefined;
    var state = try Battle.State.init(content.value, items.value, &members, 17);
    state.runes[0] = null;
    var empty = Rules.Draws{};
    state.replay_draws = &empty;
    try std.testing.expectError(error.InvalidActorRecovery, state.requestUniteRecovery(state.partyCount(), 2));
    try std.testing.expectError(error.InvalidActorRecovery, state.requestUniteRecovery(0, 0));
    const code = [_]vm.Instruction{ .{ .command = .{ .recovery = 2 } }, .{ .command = .{ .release_actor = true } }, .{ .halt = {} } };
    var actors = [_]host.Actor{try host.Actor.init(resource, .{ 0, 0, 0 })};
    var bridge = RecoveryBridge{ .state = &state };
    var runtime = host.Runtime{ .actors = &actors, .external = .{ .context = &bridge, .command = RecoveryBridge.command, .previous_screen_position = RecoveryBridge.previousScreen } };
    try std.testing.expectError(error.RandomInputExhausted, runtime.dispatch(0, null, .{ .id = "recovery", .instructions = &code }));
    try std.testing.expectEqual(@as(u8, 0), state.unbalanced[0]);
    try std.testing.expectEqual(@as(usize, 0), actors[0].machine.?.pc);
    try std.testing.expect(!actors[0].released);
    const values = [_]u15{32767};
    var draws = Rules.Draws{ .values = &values };
    state.replay_draws = &draws;
    state.replay_exhausted = false;
    try runtime.stepActor(0);
    try std.testing.expectEqual(@as(u8, 2), state.unbalanced[0]);
    try std.testing.expectEqual(@as(usize, 1), draws.cursor);
    try std.testing.expect(actors[0].released and actors[0].machine.?.halted);
}

test "actor blue trail captures retained projection freezes allocation pose wraps and tears down after halt" {
    var actors = [_]host.Actor{try host.Actor.init(resource, .{ 0, 0, 0 })};
    var observer = Observer{};
    var runtime = host.Runtime{ .actors = &actors, .external = .{ .context = &observer, .command = Observer.command, .previous_screen_position = Observer.previousScreen } };
    const code = [_]vm.Instruction{ .{ .command = .{ .animation = 1 } }, .{ .command = .{ .effect = .{ .id = "blue_afterimages", .binding = .shared } } }, .{ .halt = {} } };
    try runtime.dispatch(0, null, .{ .id = "trail", .instructions = &code });
    try std.testing.expect(actors[0].machine.?.halted and actors[0].blue_trail == null);
    try runtime.stepActor(0);
    try std.testing.expectEqual(@as(i16, 1), actors[0].shared_value);
    try std.testing.expect(!actors[0].blue_trail.?.visible);
    try std.testing.expectEqual(@as(u16, 0), actors[0].blue_trail.?.pose);
    for (1..11) |update| {
        if (update == 4) actors[0].visible = false;
        observer.screen = .{ .x = @floatFromInt(update * 10), .y = @floatFromInt(update * 20), .depth = @floatFromInt(100 + update) };
        try runtime.stepActor(0);
        const trail = actors[0].blue_trail.?;
        try std.testing.expect(trail.visible);
        try std.testing.expectEqual(observer.screen.depth, trail.depth);
        try std.testing.expectEqual([2]f32{ observer.screen.x, observer.screen.y }, trail.newest(0).position);
        try std.testing.expectEqual(@as(u16, 0), trail.newest(0).pose);
        try std.testing.expectEqual([3]u8{ 255, 255, 255 }, trail.newest(0).color);
        try std.testing.expectEqual([3]u8{ 0, 0, 255 }, trail.newest(7).color);
        if (update >= 8) {
            for (0..8) |age| {
                const sample = trail.newest(@intCast(age));
                try std.testing.expectEqual([2]f32{ @floatFromInt((update - age) * 10), @floatFromInt((update - age) * 20) }, sample.position);
                const shades = [_]u8{ 255, 218, 182, 145, 109, 72, 36, 0 };
                try std.testing.expectEqual(shades[age], sample.color[0]);
            }
        }
    }
    try std.testing.expectEqual(@as(u16, 1), actors[0].currentFrame().pose);
    actors[0].shared_value = 99;
    try runtime.stepActor(0);
    try std.testing.expectEqual(@as(i16, 100), actors[0].shared_value);
    try std.testing.expect(actors[0].blue_trail != null and !actors[0].blue_trail.?.visible);
    try runtime.stepActor(0);
    try std.testing.expect(actors[0].blue_trail == null and !actors[0].blue_trail_active);
    try std.testing.expectEqual(@as(usize, 0), observer.effects);
    try std.testing.expectEqual(@as(usize, 11), observer.captures);
}

test "actor blue trail requires projection and refuses nonfinite captures without initializing" {
    var actors = [_]host.Actor{try host.Actor.init(resource, .{ 0, 0, 0 })};
    var runtime = host.Runtime{ .actors = &actors };
    const code = [_]vm.Instruction{ .{ .command = .{ .effect = .{ .id = "blue_afterimages", .binding = .shared } } }, .{ .halt = {} } };
    const program = vm.Program{ .id = "trail", .instructions = &code };
    try std.testing.expectError(error.MissingActorProjection, runtime.dispatch(0, null, program));
    try std.testing.expect(!actors[0].blue_trail_active);
    var observer = Observer{};
    runtime.external = .{ .context = &observer, .command = Observer.command, .previous_screen_position = Observer.previousScreen };
    try runtime.dispatch(0, null, program);
    try std.testing.expectError(error.ActorEffectAlreadyActive, runtime.dispatch(0, null, program));
    actors[0].machine = null;
    observer.screen.x = std.math.nan(f32);
    try std.testing.expectError(error.InvalidActorProjection, runtime.stepActor(0));
    try std.testing.expect(actors[0].blue_trail == null and actors[0].shared_value == 0);
    observer.screen.x = 10;
    try runtime.stepActor(0);
    try std.testing.expect(actors[0].blue_trail != null and actors[0].shared_value == 1);
}

test "actor projectile callbacks acquire target pose wait for result retain miss velocity and orient sprites" {
    for ([_][]const u8{ "aimed_projectile", "spinning_projectile" }) |effect| {
        for ([_]bool{ false, true }) |hit| {
            var actors = [_]host.Actor{ try host.Actor.init(resource, .{ 0, 0, 0 }), try host.Actor.init(resource, .{ 10 * 4096, 0, 0 }), try host.Actor.init(resource, .{ 0, 0, 0 }) };
            actors[0].owner = 1;
            actors[1].owner = 2;
            actors[2].animation = 1;
            actors[2].frame = 1;
            var runtime = host.Runtime{ .actors = &actors, .camera_angles = .{ -100, 200, -300 } };
            const code = [_]vm.Instruction{ .{ .command = .{ .effect = .{ .id = effect, .binding = .shared } } }, .{ .command = .{ .motion = .{ .anchor = .owner, .updates = 2, .offset = .{ 0, 0, 0 }, .velocity_q12 = .{ 0, 0, 0 }, .kind = .linear } } }, .{ .halt = {} } };
            try runtime.dispatch(0, 1, .{ .id = "projectile", .instructions = &code });
            try runtime.stepActor(0);
            try std.testing.expectEqual([2]i32{ -4, 3 }, actors[0].offset_destination);
            try std.testing.expectEqual(@as(i16, 1), actors[0].shared_value);
            try runtime.stepActor(0);
            try std.testing.expect(actors[0].movement == null);
            try std.testing.expectEqual([3]i32{ 5 * 4096, 0, 0 }, actors[0].velocity_q12);
            actors[2].frame = 0;
            actors[1].signals = 2 | (if (hit) @as(u16, 16) else 0);
            try runtime.stepActor(0);
            try std.testing.expectEqual(@as(i16, 2), actors[0].shared_value);
            try runtime.stepActor(0);
            if (hit) {
                try std.testing.expectEqual(@as(i16, 99), actors[0].shared_value);
                try std.testing.expect(actors[0].movement == null);
            } else {
                try std.testing.expectEqual(@as(i16, 3), actors[0].shared_value);
                try std.testing.expectEqual(@as(u16, 30), actors[0].movement.?.remaining);
                try std.testing.expectEqual([3]i32{ 160 * 4096, 0, 0 }, actors[0].movement.?.destination);
                for (0..30) |_| try runtime.stepActor(0);
                try std.testing.expectEqual([3]i32{ 160 * 4096, 0, 0 }, actors[0].position_q12);
                try std.testing.expectEqual(@as(i16, 99), actors[0].shared_value);
            }
            try std.testing.expectEqual([2]i32{ -4, 3 }, actors[0].offset_destination);
            const updates: i16 = if (hit) 4 else 34;
            try std.testing.expectEqual([3]i16{ -100, 200, if (std.mem.eql(u8, effect, "aimed_projectile")) -300 else updates *% 512 }, actors[0].draw_angles);
            const angles = actors[0].draw_angles;
            try runtime.stepActor(0);
            try std.testing.expect(actors[0].projectile == null);
            try std.testing.expectEqual(angles, actors[0].draw_angles);
        }
    }
}

test "all seven exported Unite projectile children execute their actual callbacks and teardown" {
    const Fixture = struct { programs: vm.Packet, animations: host.Resources };
    const parsed = try std.json.parseFromSlice(Fixture, a, @embedFile("fixtures/unite_actor_vm.json"), .{});
    defer parsed.deinit();
    for ([_]struct { member: []const u8, parent: []const u8, end: u16, miss_end: u16 }{
        .{ .member = "kirkis", .parent = "kirkis/unite_11", .end = 18, .miss_end = 48 },
        .{ .member = "sylvina", .parent = "sylvina/unite_11", .end = 18, .miss_end = 48 },
        .{ .member = "stallion", .parent = "stallion/unite_11", .end = 18, .miss_end = 48 },
        .{ .member = "fuma", .parent = "fuma/unite_11", .end = 18, .miss_end = 48 },
        .{ .member = "kage", .parent = "kage/unite_11", .end = 18, .miss_end = 48 },
        .{ .member = "krin", .parent = "krin/unite_10", .end = 9, .miss_end = 9 },
        .{ .member = "eileen", .parent = "eileen/unite_12", .end = 48, .miss_end = 78 },
    }) |case| {
        const parent = parsed.value.programs.find(case.parent).?;
        var child: ?vm.Child = null;
        for (parent.instructions) |instruction| if (instruction == .command and instruction.command == .child) {
            child = instruction.command.child;
            break;
        };
        for ([_]bool{ false, true }) |hit| {
            var actors = [_]host.Actor{ try host.Actor.init(parsed.value.animations.find(case.member).?, .{ 0, 0, 0 }), try host.Actor.init(resource, .{ 0, 0, 0 }) };
            actors[1].animation = 1;
            actors[1].frame = 1;
            if (hit) actors[0].signals = 16;
            var children = [_]?host.Actor{null};
            var observer = Observer{};
            var runtime = host.Runtime{ .actors = &actors, .auxiliary = &children, .library = .{ .programs = parsed.value.programs, .resources = parsed.value.animations }, .external = .{ .context = &observer, .command = Observer.command } };
            const code = [_]vm.Instruction{ .{ .command = .{ .child = child.? } }, .{ .halt = {} } };
            try runtime.dispatch(0, 1, .{ .id = "spawn", .instructions = &code });
            var ending: usize = 0;
            for (1..101) |update| {
                if (std.mem.eql(u8, case.member, "eileen") and update == 45) actors[0].signals |= 2;
                try runtime.stepActor(2);
                if (children[0] == null) {
                    ending = update;
                    break;
                }
                if (update == 1) try std.testing.expectEqual([2]i32{ -4, 3 }, children[0].?.offset_destination);
            }
            try std.testing.expectEqual(if (hit) case.end else case.miss_end, ending);
            try std.testing.expectEqual(@as(usize, 1), observer.sounds);
            try std.testing.expectEqual(@as(usize, 0), observer.effects);
        }
    }
}

test "Cleo and Ted ranged scripts spawn their source projectile and signal contact" {
    const Fixture = struct { programs: vm.Packet, animations: host.Resources };
    const parsed = try std.json.parseFromSlice(Fixture, a, @embedFile("fixtures/party_ranged_actor_library.json"), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try parsed.value.programs.validate();
    try parsed.value.animations.validate();
    for ([_]struct { name: []const u8, attack: []const u8, back: []const u8, born: usize, contact: usize, retired: usize, ready: usize }{
        .{ .name = "cleo", .attack = "ranged/cleo/attack", .back = "ranged/cleo/return", .born = 26, .contact = 40, .retired = 43, .ready = 92 },
        .{ .name = "ted", .attack = "ranged/ted/attack", .back = "ranged/ted/return", .born = 34, .contact = 48, .retired = 51, .ready = 89 },
    }) |case| {
        var actors = [_]host.Actor{ try host.Actor.init(parsed.value.animations.find(case.name).?, .{ 0, 0, 0 }), try host.Actor.init(resource, .{ -128 * 4096, 0, 0 }) };
        var children = [_]?host.Actor{null};
        var observer = Observer{};
        var runtime = host.Runtime{ .actors = &actors, .auxiliary = &children, .library = .{ .programs = parsed.value.programs, .resources = parsed.value.animations }, .external = .{ .context = &observer, .command = Observer.command } };
        actors[1].animation = 1;
        actors[1].frame = 1;
        try runtime.dispatch(0, 1, parsed.value.programs.find(case.attack).?);
        var born: usize = 0;
        var contact: usize = 0;
        var retired: usize = 0;
        var ready: usize = 0;
        for (1..201) |tick| {
            try runtime.stepActor(0);
            if (children[0] != null) {
                if (born == 0) {
                    born = tick;
                    try std.testing.expectEqual(@as(u16, 17), children[0].?.animation);
                }
                try runtime.stepActor(2);
                if (tick == born) try std.testing.expectEqual([2]i32{ -4, 3 }, children[0].?.offset_destination);
                if (children[0] == null) retired = tick;
            }
            if (contact == 0 and actors[0].signals & 2 != 0) {
                contact = tick;
                actors[0].signals |= 16;
            }
            if (actors[0].signals & 4 != 0) {
                ready = tick;
                break;
            }
        }
        try std.testing.expectEqual(case.born, born);
        try std.testing.expectEqual(case.contact, contact);
        try std.testing.expectEqual(case.retired, retired);
        try std.testing.expectEqual(case.ready, ready);
        try std.testing.expectEqual(@as(usize, 1), observer.sounds);
        try runtime.dispatch(0, 1, parsed.value.programs.find(case.back).?);
        for (0..25) |_| try runtime.stepActor(0);
        try std.testing.expect(actors[0].machine.?.halted);
        try std.testing.expect(actors[0].released);
    }
}

const camera = @import("battle_camera");
test "actor camera commands share the existing Q12 controller and advance before the actor sweep" {
    var initial = camera.intro_wide;
    initial.focus = .{ 80, -3, 7 };
    var controller = try camera.ActorController.init(initial);
    var actors = [_]host.Actor{ try host.Actor.init(resource, .{ 0, 0, 0 }), try host.Actor.init(resource, .{ -128 * 4096 + 13, 40 * 4096 - 5, 12345 }), try host.Actor.init(resource, .{ 0, 0, 0 }) };
    actors[1].owner = 2;
    var runtime = host.Runtime{ .actors = &actors, .camera_controller = &controller };
    const code = [_]vm.Instruction{
        .{ .command = .{ .camera = .{ .channel = .focus, .anchor = .owner, .updates = 20, .value_q12 = .{ 1, -3, 0 } } } },
        .{ .command = .{ .camera = .{ .channel = .scale, .updates = 20, .value_q12 = @splat(3328 * 4096) } } },
        .{ .command = .{ .camera = .{ .channel = .angles, .updates = 20, .value_q12 = .{ -768 * 4096, 0, 640 * 4096 } } } },
        .{ .command = .{ .camera = .{ .channel = .translation, .updates = 20, .value_q12 = .{ 0, 0, 900 * 4096 } } } },
        .{ .command = .{ .effect = .{ .id = "aimed_projectile", .binding = .shared } } },
        .{ .halt = {} },
    };
    try runtime.dispatch(0, 1, .{ .id = "camera", .instructions = &code });
    try std.testing.expectEqualDeep(initial, controller.sample());
    try std.testing.expectEqual([3]i32{ -524274, 163832, 0 }, controller.target[0]);
    runtime.beginUpdate();
    try runtime.stepActor(0);
    try std.testing.expectEqual([3]i32{ 285083, -3482, 27239 }, controller.current[0]);
    for (1..20) |_| {
        runtime.beginUpdate();
        try runtime.stepActor(0);
    }
    try std.testing.expectEqual([3]i32{ -524260, 163832, 12 }, controller.current[0]);
    try std.testing.expectEqual(@as(i16, 639), actors[0].draw_angles[2]);
    runtime.beginUpdate();
    try runtime.stepActor(0);
    try std.testing.expectEqual(controller.target[0], controller.current[0]);
    try std.testing.expectEqual(@as(i16, 640), actors[0].draw_angles[2]);
    try std.testing.expectEqual([3]i32{ 0, 0, 900 }, controller.sample().translation);
    try std.testing.expectEqual([3]i32{ 3328, 3328, 3328 }, controller.sample().scale);
    actors[0].position_q12 = .{ 11 * 4096 + 3, -9 * 4096 - 2, 999 };
    const retarget = [_]vm.Instruction{ .{ .command = .{ .camera = .{ .channel = .focus, .anchor = .self, .updates = 3, .value_q12 = .{ -1, 2, 0 } } } }, .{ .halt = {} } };
    const before = controller.current;
    try runtime.dispatch(0, 1, .{ .id = "retarget", .instructions = &retarget });
    try std.testing.expectEqual(before, controller.current);
    try std.testing.expectEqual([3]i32{ 11 * 4096 + 2, -9 * 4096, 0 }, controller.target[0]);
}

test "overlapping actor camera requests replace only the claimed channel" {
    var initial = camera.intro_wide;
    initial.focus = @splat(0);
    initial.scale = @splat(1000);
    var controller = try camera.ActorController.init(initial);
    var actors = [_]host.Actor{
        try host.Actor.init(resource, @splat(0)),
        try host.Actor.init(resource, @splat(0)),
    };
    var runtime = host.Runtime{ .actors = &actors, .camera_controller = &controller };

    const first = [_]vm.Instruction{
        .{ .command = .{ .camera = .{ .channel = .focus, .updates = 4, .value_q12 = .{ 16000, 0, 0 } } } },
        .{ .command = .{ .camera = .{ .channel = .scale, .updates = 5, .value_q12 = @splat(1500 * 4096) } } },
        .{ .delay = 2 },
        .{ .halt = {} },
    };
    const second = [_]vm.Instruction{
        .{ .delay = 1 },
        .{ .command = .{ .camera = .{ .channel = .focus, .updates = 3, .value_q12 = .{ -8000, 0, 0 } } } },
        .{ .halt = {} },
    };
    try runtime.dispatch(0, null, .{ .id = "first-camera", .instructions = &first });
    try runtime.dispatch(1, null, .{ .id = "second-camera", .instructions = &second });

    const focus_after_update = [_]i32{ 4000, 0, -4000, -8000, -8000 };
    for (focus_after_update, 1..) |focus, update| {
        runtime.beginUpdate();
        try runtime.stepActor(0);
        try runtime.stepActor(1);
        try std.testing.expectEqual(focus, controller.current[0][0]);
        try std.testing.expectEqual([3]i32{ -8000, 0, 0 }, controller.target[0]);
        try std.testing.expectEqual(@as(u16, @intCast(4 -| update)), controller.remaining[0]);
        try std.testing.expectEqual(@as(u16, @intCast(5 - update)), controller.remaining[3]);
        const scale: i32 = @intCast((1000 + 100 * update) * 4096);
        try std.testing.expectEqual(@as([3]i32, @splat(scale)), controller.current[3]);
        if (update >= 2) try std.testing.expect(actors[0].machine.?.halted and actors[1].machine.?.halted);
    }
}

test "actor camera refuses missing controllers and invalid requests before camera mutation" {
    var actors = [_]host.Actor{try host.Actor.init(resource, .{ 0, 0, 0 })};
    var runtime = host.Runtime{ .actors = &actors };
    var code = [_]vm.Instruction{ .{ .command = .{ .camera = .{ .channel = .focus, .updates = 20, .value_q12 = .{ 0, 0, 0 } } } }, .{ .halt = {} } };
    const program = vm.Program{ .id = "camera", .instructions = &code };
    try std.testing.expectError(error.MissingActorCamera, runtime.dispatch(0, null, program));
    var controller = try camera.ActorController.init(camera.intro_wide);
    runtime.camera_controller = &controller;
    const before = controller;
    for ([_]vm.Camera{
        .{ .channel = .focus, .updates = 0, .value_q12 = .{ 0, 0, 0 } },
        .{ .channel = .focus, .updates = 20, .value_q12 = .{ 32768, 0, 0 } },
        .{ .channel = .angles, .anchor = .self, .updates = 20, .value_q12 = .{ 0, 0, 0 } },
        .{ .channel = .focus, .anchor = .self, .updates = 20, .value_q12 = .{ 0, 0, 1 } },
    }) |request| {
        code[0] = .{ .command = .{ .camera = request } };
        try std.testing.expectError(error.InvalidActorCamera, runtime.dispatch(0, null, program));
        try std.testing.expectEqualDeep(before, controller);
    }
}

test "exported Fisherman and Wild Arrow camera requests retain their dispatch and remainder frames" {
    const Fixture = struct { programs: vm.Packet, animations: host.Resources };
    const parsed = try std.json.parseFromSlice(Fixture, a, @embedFile("fixtures/unite_actor_vm.json"), .{});
    defer parsed.deinit();
    for ([_]struct { member: []const u8, program: []const u8, at: usize }{ .{ .member = "tai_ho", .program = "tai_ho/unite_9", .at = 62 }, .{ .member = "kirkis", .program = "kirkis/unite_10", .at = 2 } }) |case| {
        var controller = try camera.ActorController.init(camera.intro_wide);
        var actors = [_]host.Actor{ try host.Actor.init(parsed.value.animations.find(case.member).?, .{ 0, 0, 0 }), try host.Actor.init(resource, .{ -128 * 4096 + 13, 40 * 4096 - 5, 12345 }) };
        var observer = Observer{};
        var runtime = host.Runtime{ .actors = &actors, .camera_controller = &controller, .external = .{ .context = &observer, .command = Observer.command, .previous_screen_position = Observer.previousScreen } };
        try runtime.dispatch(0, 1, parsed.value.programs.find(case.program).?);
        const initial = controller.current;
        for (1..case.at + 22) |update| {
            runtime.beginUpdate();
            try runtime.stepActor(0);
            if (update <= case.at) try std.testing.expectEqual(initial, controller.current);
            if (update == case.at) try std.testing.expectEqual(@as(u16, 20), controller.remaining[0]);
            if (update == case.at + 20) {
                try std.testing.expectEqual(@as(u16, 0), controller.remaining[0]);
                if (case.at == 62) {
                    try std.testing.expectEqual([3]i32{ -524260, 163820, 0 }, controller.current[0]);
                } else try std.testing.expectEqual(@as(i32, 639), controller.sample().angles[2]);
            }
            if (update == case.at + 21) try std.testing.expectEqual(controller.target, controller.current);
        }
        if (case.at == 62) {
            try std.testing.expectEqual([3]i32{ -524275, 163835, 0 }, controller.target[0]);
        } else {
            try std.testing.expectEqual([3]i32{ -768, 0, 640 }, controller.sample().angles);
            try std.testing.expectEqual([3]i32{ 3328, 3328, 3328 }, controller.sample().scale);
        }
    }
}

test "unite actor bundle resolves all32 records and preserves explicit multi-program choices" {
    const parsed = try host.loadBundle(a, @embedFile("fixtures/unite_actor_library.json"));
    defer parsed.deinit();
    const bundle = &parsed.value;
    try std.testing.expectEqual(@as(usize, 84), bundle.programs.programs.len);
    try std.testing.expectEqual(@as(usize, 53), bundle.animations.resources.len);
    for (0..32) |record| {
        const unite = bundle.find(@intCast(record)).?;
        try std.testing.expectEqual(record, unite.record);
        for (unite.members) |member| {
            const member_resource = bundle.library().resources.find(member.id).?;
            try std.testing.expectEqualStrings(member.id, member_resource.id);
            for (member.programs) |id| try std.testing.expectEqualStrings(id, bundle.library().programs.find(id).?.id);
        }
    }
    try std.testing.expect(bundle.find(32) == null);
    try std.testing.expectEqualStrings("common/fisherman_return", bundle.find(1).?.return_program.?);
    try std.testing.expectEqual(@as(usize, 2), bundle.find(6).?.members[0].programs.len);
    try std.testing.expectEqual(@as(usize, 3), bundle.find(29).?.members[0].programs.len);
}

test "unite actor bundle rejects broken record member resource program and animation bindings" {
    const parsed = try host.loadBundle(a, @embedFile("fixtures/unite_actor_library.json"));
    defer parsed.deinit();
    var bad = parsed.value;
    bad.schema = "suikoden-unite-actors/0";
    try std.testing.expectError(error.InvalidUniteBindings, bad.validate());
    bad = parsed.value;
    bad.unites = bad.unites[0..31];
    try std.testing.expectError(error.InvalidUniteBindings, bad.validate());
    bad = parsed.value;
    var scenes: [32]host.UniteBinding = undefined;
    @memcpy(&scenes, bad.unites);
    bad.unites = &scenes;
    scenes[1].record = 0;
    try std.testing.expectError(error.InvalidUniteBindings, bad.validate());
    scenes[1] = parsed.value.unites[1];
    var members: [2]host.MemberBinding = undefined;
    @memcpy(&members, scenes[0].members);
    scenes[0].members = &members;
    members[1] = members[0];
    try std.testing.expectError(error.InvalidUniteBindings, bad.validate());
    members[1] = parsed.value.unites[0].members[1];
    members[0].id = "missing_actor";
    try std.testing.expectError(error.MissingActorResource, bad.validate());
    members[0] = parsed.value.unites[0].members[0];
    members[0].programs = &.{"pahn/missing"};
    try std.testing.expectError(error.MissingUniteProgram, bad.validate());
    members[0].programs = &.{"gremio/unite_9"};
    try std.testing.expectError(error.InvalidUniteBindings, bad.validate());
    members[0] = parsed.value.unites[0].members[0];
    scenes[0].return_program = "missing_return";
    try std.testing.expectError(error.MissingUniteProgram, bad.validate());
    scenes[0] = parsed.value.unites[0];
    var resources: [53]host.Resource = undefined;
    @memcpy(&resources, bad.animations.resources);
    bad.animations.resources = &resources;
    for (&resources) |*resource_entry| if (std.mem.eql(u8, resource_entry.id, "pahn")) {
        resource_entry.clips = resource_entry.clips[0..1];
    };
    try std.testing.expectError(error.MissingActorAnimation, bad.validate());
}

test "actor anchors provide live target position flags and proven attachment without drawable resources" {
    var actors = [_]host.Actor{ try host.Actor.init(resource, .{ 0, 0, 0 }), host.Actor.anchor(.{ 10 * 4096 + 1, 20 * 4096 - 1, -30 * 4096 }, .{ 10 * 4096, 20 * 4096, 0 }, .{ -14, -32 }) };
    try std.testing.expect(actors[1].resource == null and !actors[1].visible and !actors[1].has_draw_record);
    var runtime = host.Runtime{ .actors = &actors };
    const code = [_]vm.Instruction{
        .{ .command = .{ .motion = .{ .anchor = .owner, .updates = 2, .offset = .{ 0, 0, 0 }, .velocity_q12 = .{ 0, 0, 0 }, .kind = .linear } } },
        .{ .command = .{ .offsets = .{ .anchor = .owner, .value = .{ 0, 0 }, .from_sprite = true, .immediate = true } } },
        .{ .wait = .{ .movement_done = {} } },
        .{ .command = .{ .signal_set = .{ .target = .owner, .bits = 2 } } },
        .{ .halt = {} },
    };
    const program = vm.Program{ .id = "target", .instructions = &code };
    try runtime.dispatch(0, 1, program);
    try std.testing.expectEqual([2]i8{ -14, -32 }, actors[0].screen_offset);
    try runtime.stepActor(0);
    try std.testing.expectEqual([3]i32{ 5 * 4096, 10 * 4096 - 1, -15 * 4096 }, actors[0].position_q12);
    actors[1].position_q12 = .{ -99, -98, -97 };
    try runtime.stepActor(1);
    try std.testing.expectEqual([3]i32{ -99, -98, -97 }, actors[1].position_q12);
    try runtime.stepActor(0);
    try runtime.stepActor(0);
    try std.testing.expectEqual([3]i32{ 10 * 4096 + 1, 20 * 4096 - 1, -30 * 4096 }, actors[0].position_q12);
    try std.testing.expectEqual(@as(u16, 2), actors[1].signals);
    try std.testing.expectError(error.MissingActorResource, runtime.dispatch(1, null, program));
    try std.testing.expect(actors[1].machine == null);
}

test "actor anchors refuse unknown target attachments instead of fabricating a pose" {
    var actors = [_]host.Actor{ try host.Actor.init(resource, .{ 0, 0, 0 }), host.Actor.anchor(.{ 0, 0, 0 }, .{ 0, 0, 0 }, null) };
    var runtime = host.Runtime{ .actors = &actors };
    const code = [_]vm.Instruction{ .{ .command = .{ .offsets = .{ .anchor = .owner, .value = .{ 0, 0 }, .from_sprite = true, .immediate = true } } }, .{ .halt = {} } };
    try std.testing.expectError(error.MissingActorAttachment, runtime.dispatch(0, 1, .{ .id = "target", .instructions = &code }));
    try std.testing.expectEqual([2]i8{ 0, 0 }, actors[0].screen_offset);
    try std.testing.expectEqual(@as(usize, 0), actors[0].machine.?.pc);
    actors[1].external_attachment = .{ -6, -45 };
    try runtime.stepActor(0);
    try std.testing.expectEqual([2]i8{ -6, -45 }, actors[0].screen_offset);
    try std.testing.expect(actors[0].machine.?.halted);
}

test "Unite schedules validate phases and preserve legacy content identity" {
    const parsed = try host.loadBundle(a, @embedFile("fixtures/unite_actor_library.json"));
    defer parsed.deinit();
    var bundle = parsed.value;
    var unites: [32]host.UniteBinding = undefined;
    var members: [32][4]host.MemberBinding = undefined;
    @memcpy(&unites, bundle.unites);
    bundle.unites = &unites;
    bundle.schema = "suikoden-unite-actors/2";
    try std.testing.expectError(error.InvalidUniteBindings, bundle.validate());
    bundle.schema = parsed.value.schema;
    @memcpy(members[7][0..3], unites[7].members);
    unites[7].members = members[7][0..3];
    members[7][0].reaction_variant = 4;
    try std.testing.expectError(error.InvalidUniteBindings, bundle.validate());
    members[7][0].reaction_variant = 1;
    members[7][0].reaction_on_hit = false;
    try std.testing.expectError(error.InvalidUniteBindings, bundle.validate());
    unites[7] = parsed.value.unites[7];
    unites[5].dispatch_after = 0;
    try std.testing.expectError(error.InvalidUniteBindings, bundle.validate());
    unites[5] = parsed.value.unites[5];
    @memcpy(members[5][0..4], unites[5].members);
    unites[5].members = &members[5];
    members[5][3].start_after = 1000;
    try std.testing.expectError(error.InvalidUniteBindings, bundle.validate());
    members[5][3] = parsed.value.unites[5].members[3];
    unites[5].dispatch_after = null;
    try std.testing.expectError(error.InvalidUniteBindings, bundle.validate());
    for (&unites, 0..) |*unite, index| {
        unite.* = parsed.value.unites[index];
        @memcpy(members[index][0..unite.members.len], unite.members);
        for (members[index][0..unite.members.len]) |*member| {
            member.start_after = 0;
            member.deferred_entry = false;
            member.reaction_on_hit = false;
            member.reaction_variant = 0;
            member.reaction_group = false;
            member.fan = null;
            member.hit_camera = null;
            member.entry_program = null;
        }
        unite.members = members[index][0..unite.members.len];
        unite.dispatch_after = null;
        unite.assist_after_damage = false;
        unite.transition = null;
        unite.embedded_returns = false;
        unite.damage_member = null;
        unite.damage_signal = 2;
        unite.damage_target_signal = null;
        unite.damage_reaction = true;
        unite.controller = null;
    }
    bundle.schema = "suikoden-unite-actors/1";
    try bundle.validate();
    const legacy = unites[0];
    const expected = try std.json.Stringify.valueAlloc(a, .{ .record = legacy.record, .name = legacy.name, .members = legacy.members, .return_program = legacy.return_program }, .{});
    defer a.free(expected);
    const actual = try std.json.Stringify.valueAlloc(a, legacy, .{});
    defer a.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
    const member_json = try std.json.Stringify.valueAlloc(a, legacy.members[0], .{});
    defer a.free(member_json);
    const old_member_json = try std.json.Stringify.valueAlloc(a, .{ .id = legacy.members[0].id, .programs = legacy.members[0].programs }, .{});
    defer a.free(old_member_json);
    try std.testing.expectEqualStrings(old_member_json, member_json);
}

test "Unite phase bindings validate entry choices signals and deferred prefixes" {
    const parsed = try host.loadBundle(a, @embedFile("fixtures/unite_actor_library.json"));
    defer parsed.deinit();
    var bundle = parsed.value;
    var unites: [32]host.UniteBinding = undefined;
    @memcpy(&unites, bundle.unites);
    bundle.unites = &unites;
    const original = unites[28];
    bundle.schema = "suikoden-unite-actors/3";
    try std.testing.expectError(error.InvalidUniteBindings, bundle.validate());
    bundle.schema = parsed.value.schema;
    unites[28].transition.?.signal = 3;
    try std.testing.expectError(error.InvalidUniteBindings, bundle.validate());
    unites[28] = original;
    unites[28].transition.?.trigger_member = 3;
    try std.testing.expectError(error.InvalidUniteBindings, bundle.validate());
    unites[28] = original;
    var dispatches = original.transition.?.dispatches[0..2].*;
    unites[28].transition.?.dispatches = &dispatches;
    dispatches[1] = dispatches[0];
    try std.testing.expectError(error.InvalidUniteBindings, bundle.validate());
    dispatches[1] = original.transition.?.dispatches[1];
    dispatches[0].program = original.members[0].programs[0];
    try std.testing.expectError(error.InvalidUniteBindings, bundle.validate());
    unites[28] = original;
    unites[28].return_program = unites[0].return_program;
    try std.testing.expectError(error.InvalidUniteBindings, bundle.validate());
    unites[28] = original;
    var members = original.members[0..3].*;
    unites[28].members = &members;
    unites[28].dispatch_after = 1;
    members[1].entry_program = null;
    try std.testing.expectError(error.InvalidUniteBindings, bundle.validate());
    members[1] = original.members[1];
    try bundle.validate();
    const programs = try a.dupe(vm.Program, bundle.programs.programs);
    defer a.free(programs);
    bundle.programs.programs = programs;
    for (programs) |*program| if (std.mem.eql(u8, program.id, "fuma/unite_11")) {
        const instructions = try a.dupe(vm.Instruction, program.instructions);
        defer a.free(instructions);
        program.instructions = instructions;
        instructions[0] = .{ .command = .{ .signal_set = .{ .target = .self, .bits = 2 } } };
        try std.testing.expectError(error.InvalidUniteBindings, bundle.validate());
        break;
    };
}

test "controller fan bindings require dedicated schema signal and single initial pose" {
    const parsed = try host.loadBundle(a, @embedFile("fixtures/unite_actor_library.json"));
    defer parsed.deinit();
    var bundle = parsed.value;
    var unites: [32]host.UniteBinding = undefined;
    @memcpy(&unites, bundle.unites);
    bundle.unites = &unites;
    var members: [2]host.MemberBinding = undefined;
    @memcpy(&members, unites[2].members);
    unites[2].members = &members;
    try bundle.validate();
    const fan = members[0].fan.?;
    members[0].fan.?.signal = 3;
    try std.testing.expectError(error.InvalidUniteBindings, bundle.validate());
    members[0].fan = fan;
    members[0].fan.?.node_angles = .{ 0, 0, 0 };
    try std.testing.expectError(error.InvalidUniteBindings, bundle.validate());
    members[0].fan = fan;
    members[0].fan.?.animation = 65535;
    try std.testing.expectError(error.MissingActorAnimation, bundle.validate());
    members[0].fan = fan;
    bundle.schema = "suikoden-unite-actors/5";
    try std.testing.expectError(error.InvalidUniteBindings, bundle.validate());
}

test "Bumpy actor controls preserve delayed entry phase motion and secondary damage signal" {
    const battle = @import("battle");
    const parsed = try host.loadBundle(a, @embedFile("fixtures/unite_actor_library.json"));
    defer parsed.deinit();
    var bundle = parsed.value;
    var unites: [32]host.UniteBinding = undefined;
    @memcpy(&unites, bundle.unites);
    bundle.unites = &unites;
    try std.testing.expectEqual(@as(?u16, 1), unites[6].dispatch_after);
    // Isolate actor ordering from the normal-gameplay scene qualification.
    unites[6].dispatch_after = 1;
    try bundle.validate();
    const Scene = struct {
        unite_actors: ?*const host.Bundle,
        camera_ticks: u32 = 0,
        unite_flags: [12]u16 = @splat(0),
        actor_camera: ?camera.ActorController = null,
        recovery: [6]u8 = @splat(0),
        pub fn partyCount(_: @This()) usize {
            return 6;
        }
        pub fn enemyCount(_: @This()) usize {
            return 1;
        }
        pub fn prepareUniteScene(_: *@This(), _: usize) !void {}
        pub fn requestUniteRecovery(self: *@This(), actor: usize, value: u8) !void {
            self.recovery[actor] = value;
        }
    };
    for (0..2) |owner| {
        var scene = Scene{ .unite_actors = &bundle };
        var playback = battle.unite_playback.State{};
        var homes: [7][3]i32 = @splat(.{ 0, 0, 0 });
        homes[0] = .{ -100 * 4096, -20 * 4096, 0 };
        homes[1] = .{ -150 * 4096, 20 * 4096, 0 };
        homes[6] = .{ 120 * 4096, 0, 0 };
        try playback.begin(&bundle, 6, @intCast(owner), 6, &.{ "krin", "humphrey", "hero", "pahn", "gremio", "viktor" }, &homes, 0);
        playback.actors[6] = host.Actor.anchor(homes[6], homes[6], .{ -4, 3 });
        scene.unite_flags[1] = 2; // Reservation state must not trigger a phase before initializer/entry.
        var switched: ?u32 = null;
        var damage: ?u32 = null;
        var ready: ?u32 = null;
        var end: ?u32 = null;
        var assists: usize = 0;
        for (1..401) |age| {
            scene.camera_ticks = @intCast(age);
            const before = playback.actors[0].position_q12;
            try playback.advanceTransition(&bundle, @intCast(owner), &scene.unite_flags);
            if (playback.members[0].?.pending_dispatch) {
                try std.testing.expect(switched == null);
                switched = @intCast(age);
                try std.testing.expectEqualDeep(before, playback.actors[0].position_q12);
                try std.testing.expectEqual(@as(u16, 0), scene.unite_flags[1] & 2);
            }
            if (playback.hitReady(0)) {
                assists += 1;
                scene.unite_flags[0] &= ~@as(u16, 2);
                playback.actors[0].signals &= ~@as(u16, 2);
            }
            if (playback.signalReady(0, 16)) {
                try std.testing.expect(damage == null);
                damage = @intCast(age);
                scene.unite_flags[0] &= ~@as(u16, 16);
                playback.actors[0].signals &= ~@as(u16, 16);
            }
            if (playback.allReady(owner) and ready == null) ready = @intCast(age);
            for (0..2) |actor| {
                const q = playback.actors[actor].position_q12;
                const point = camera.projectScene(camera.settled_pan, .{ q[0] >> 12, q[1] >> 12, q[2] >> 12 }, .{}).?;
                playback.previous_points[actor] = .{ .x = point.x * 2, .y = point.y * 2, .depth = point.depth };
            }
            try playback.update(&scene, camera.settled_pan);
            if (age >= 144 and age < 164) try std.testing.expectEqual(host.Palette{ .shared = 0 }, playback.actors[0].palette);
            if (age == 164) try std.testing.expectEqual(host.Palette{ .resource = {} }, playback.actors[0].palette);
            try std.testing.expectEqual(age >= 81, playback.members[1].?.initialized);
            if (age == 81) try std.testing.expectEqual(@as(u16, 1), playback.members[1].?.age);
            if (playback.actors[0].released and playback.actors[1].released) {
                end = @intCast(age);
                break;
            }
        }
        try std.testing.expect(switched != null and damage != null and ready != null and end != null);
        try std.testing.expectEqual(@as(?u32, 144), switched);
        try std.testing.expectEqual(@as(?u32, 165), damage);
        try std.testing.expectEqual(@as(?u32, 213), ready);
        try std.testing.expectEqual(@as(?u32, 246), end);
        try std.testing.expectEqual(@as(usize, 1), assists);
        try std.testing.expectEqualDeep(homes[0], playback.actors[0].position_q12);
        try std.testing.expectEqualDeep(homes[1], playback.actors[1].position_q12);
    }
}

test "secondary Unite damage controls reject conflicting masks and preserve defaults" {
    const parsed = try host.loadBundle(a, @embedFile("fixtures/unite_actor_library.json"));
    defer parsed.deinit();
    var bundle = parsed.value;
    var unites: [32]host.UniteBinding = undefined;
    @memcpy(&unites, bundle.unites);
    bundle.unites = &unites;
    try std.testing.expectEqual(@as(u16, 16), unites[6].damage_signal);
    try std.testing.expectEqual(@as(?u16, 1), unites[6].dispatch_after);
    unites[6].damage_signal = 3;
    try std.testing.expectError(error.InvalidUniteBindings, bundle.validate());
    unites[6].damage_signal = 2;
    try std.testing.expectError(error.InvalidUniteBindings, bundle.validate());
    unites[6].damage_signal = 16;
    bundle.schema = "suikoden-unite-actors/6";
    try std.testing.expectError(error.InvalidUniteBindings, bundle.validate());
}

test "Fatal actor controls wait for partner signal and retain independent returns for both owners" {
    const battle = @import("battle");
    const parsed = try host.loadBundle(a, @embedFile("fixtures/unite_actor_library.json"));
    defer parsed.deinit();
    var bundle = parsed.value;
    var unites: [32]host.UniteBinding = undefined;
    @memcpy(&unites, bundle.unites);
    bundle.unites = &unites;
    try std.testing.expectEqual(@as(?u16, 1), unites[13].dispatch_after);
    // Actor-only qualification; normal battle admission requires complete scene art/reaction checks.
    unites[13].dispatch_after = 1;
    try bundle.validate();
    const Scene = struct {
        unite_actors: ?*const host.Bundle,
        camera_ticks: u32 = 0,
        unite_flags: [12]u16 = @splat(0),
        actor_camera: ?camera.ActorController = null,
        pub fn partyCount(_: @This()) usize {
            return 6;
        }
        pub fn enemyCount(_: @This()) usize {
            return 1;
        }
        pub fn prepareUniteScene(_: *@This(), _: usize) !void {}
        pub fn requestUniteRecovery(_: *@This(), _: usize, _: u8) !void {}
    };
    for (0..2) |owner| {
        var scene = Scene{ .unite_actors = &bundle };
        var playback = battle.unite_playback.State{};
        var homes: [7][3]i32 = @splat(.{ 0, 0, 0 });
        homes[0] = .{ -100 * 4096, -20 * 4096, 0 };
        homes[1] = .{ -150 * 4096, 20 * 4096, 0 };
        homes[6] = .{ 120 * 4096, 0, 0 };
        try playback.begin(&bundle, 13, @intCast(owner), 6, &.{ "gen", "kamandol", "hero", "pahn", "gremio", "viktor" }, &homes, 0);
        playback.actors[6] = host.Actor.anchor(homes[6], homes[6], .{ -4, 3 });
        scene.unite_flags[1] = 16;
        var started: ?u32 = null;
        var reaction: ?u32 = null;
        var damage: ?u32 = null;
        var ready: ?u32 = null;
        var end: ?u32 = null;
        for (1..401) |age| {
            scene.camera_ticks = @intCast(age);
            try playback.advanceTransition(&bundle, @intCast(owner), &scene.unite_flags);
            if (!playback.members[0].?.deferred_entry and started == null) started = @intCast(age);
            if (playback.hitReady(0)) {
                try std.testing.expect(reaction == null);
                reaction = @intCast(age);
                scene.unite_flags[0] &= ~@as(u16, 2);
                playback.actors[0].signals &= ~@as(u16, 2);
            }
            if (playback.hitReady(1)) {
                try std.testing.expect(damage == null);
                damage = @intCast(age);
                scene.unite_flags[1] &= ~@as(u16, 2);
                playback.actors[1].signals &= ~@as(u16, 2);
            }
            if (playback.allReady(owner) and ready == null) ready = @intCast(age);
            for (0..2) |actor| {
                const q = playback.actors[actor].position_q12;
                const point = camera.projectScene(camera.settled_pan, .{ q[0] >> 12, q[1] >> 12, q[2] >> 12 }, .{}).?;
                playback.previous_points[actor] = .{ .x = point.x * 2, .y = point.y * 2, .depth = point.depth };
            }
            try playback.update(&scene, camera.settled_pan);
            if ((age >= 15 and age <= 35) or (age >= 194 and age <= 214)) {
                const trail = playback.actors[1].blue_trail.?;
                try std.testing.expectEqual(@as(u16, 4), trail.pose);
                try std.testing.expectEqual((age > 15 and age < 35) or (age > 194 and age < 214), trail.visible);
            }
            if (age == 36 or age == 215) try std.testing.expect(playback.actors[1].blue_trail == null);
            try std.testing.expectEqual(age >= 61, playback.members[0].?.initialized);
            if (age < 61) {
                try std.testing.expect(playback.pose(0) == null);
                try std.testing.expectEqualDeep(homes[0], playback.actors[0].position_q12);
                try std.testing.expectEqual(@as(u16, 0), playback.members[0].?.age);
            }
            if (age == 61) {
                try std.testing.expectEqual(@as(u16, 1), playback.members[0].?.age);
                try std.testing.expectEqual(@as(u16, 0), scene.unite_flags[1] & 16);
            }
            if (playback.actors[0].released and playback.actors[1].released) {
                end = @intCast(age);
                break;
            }
        }
        try std.testing.expectEqual(@as(?u32, 61), started);
        try std.testing.expectEqual(@as(?u32, 125), reaction);
        try std.testing.expectEqual(@as(?u32, 252), damage);
        try std.testing.expectEqual(@as(?u32, 272), ready);
        try std.testing.expectEqual(@as(?u32, 317), end);
        try std.testing.expectEqualDeep(homes[0], playback.actors[0].position_q12);
        try std.testing.expectEqualDeep(homes[1], playback.actors[1].position_q12);
    }
}

test "deferred Unite entry requires schema and a reachable initialized trigger" {
    const parsed = try host.loadBundle(a, @embedFile("fixtures/unite_actor_library.json"));
    defer parsed.deinit();
    var bundle = parsed.value;
    var unites: [32]host.UniteBinding = undefined;
    @memcpy(&unites, bundle.unites);
    bundle.unites = &unites;
    var members: [2]host.MemberBinding = undefined;
    @memcpy(&members, unites[13].members);
    unites[13].members = &members;
    try bundle.validate();
    bundle.schema = "suikoden-unite-actors/7";
    try std.testing.expectError(error.InvalidUniteBindings, bundle.validate());
    bundle.schema = parsed.value.schema;
    members[0].start_after = 1;
    try std.testing.expectError(error.InvalidUniteBindings, bundle.validate());
    members[0].start_after = 0;
    members[1].deferred_entry = true;
    try std.testing.expectError(error.InvalidUniteBindings, bundle.validate());
    members[1].deferred_entry = false;
    unites[13].transition = null;
    try std.testing.expectError(error.InvalidUniteBindings, bundle.validate());
}

test "scene controller bindings require schema9 ordered phases and exclusive event ownership" {
    const parsed = try host.loadBundle(a, @embedFile("fixtures/unite_actor_library.json"));
    defer parsed.deinit();
    var bundle = parsed.value;
    var unites: [32]host.UniteBinding = undefined;
    @memcpy(&unites, bundle.unites);
    bundle.unites = &unites;
    try bundle.validate();
    bundle.schema = "suikoden-unite-actors/8";
    try std.testing.expectError(error.InvalidUniteBindings, bundle.validate());
    bundle.schema = parsed.value.schema;
    const original = unites[9];
    unites[9].controller.?.trigger_member = 3;
    try std.testing.expectError(error.InvalidUniteBindings, bundle.validate());
    unites[9] = original;
    unites[9].controller.?.recipient_at = original.controller.?.damage_at;
    try std.testing.expectError(error.InvalidUniteBindings, bundle.validate());
    unites[9] = original;
    unites[9].controller.?.recipient_rolls = &.{};
    try std.testing.expectError(error.InvalidUniteBindings, bundle.validate());
    unites[9] = original;
    unites[9].controller.?.cleanup_at += 1;
    try std.testing.expectError(error.InvalidUniteBindings, bundle.validate());
    unites[9] = original;
    unites[9].damage_member = 0;
    try std.testing.expectError(error.InvalidUniteBindings, bundle.validate());
    unites[9] = original;
    unites[9].dispatch_after = null;
    try std.testing.expectError(error.InvalidUniteBindings, bundle.validate());
    const bytes = try std.json.Stringify.valueAlloc(a, unites[0], .{});
    defer a.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "controller") == null);
}

test "Martial arts queue bundle validates source members and rejects ambiguous dispatch" {
    const parsed = try host.loadBundle(a, @embedFile("fixtures/martial_actor_library.json"));
    defer parsed.deinit();
    const bindings = try a.dupe(host.UniteBinding, parsed.value.unites);
    defer a.free(bindings);
    var bundle = parsed.value;
    bundle.unites = bindings;
    const original = bindings[29];
    const members = try a.dupe(host.MemberBinding, original.members);
    defer a.free(members);
    bindings[29].members = members;
    try bundle.validate();
    bundle.schema = "suikoden-unite-actors/26";
    try std.testing.expectError(error.InvalidUniteBindings, bundle.validate());
    bundle.schema = parsed.value.schema;
    bindings[29].target_queue.?.damage = bindings[29].target_queue.?.recipient_return;
    try std.testing.expectError(error.InvalidUniteBindings, bundle.validate());
    bindings[29].target_queue = original.target_queue;
    members[1].loop_program = null;
    try std.testing.expectError(error.InvalidUniteBindings, bundle.validate());
    members[1] = original.members[1];
    members[1].entry_program = members[1].loop_program;
    try std.testing.expectError(error.InvalidUniteBindings, bundle.validate());
    members[1] = original.members[1];
    bindings[29].damage_reaction = true;
    try std.testing.expectError(error.InvalidUniteBindings, bundle.validate());
    bindings[29].damage_reaction = false;
    bindings[29].target_queue = null;
    try std.testing.expectError(error.InvalidUniteBindings, bundle.validate());
    bindings[29] = original;
    try bundle.validate();
}

test "Beat callback child survives normal playback rebind and preserves its dispatch sound" {
    const battle = @import("battle");
    const parsed = try host.loadBundle(a, @embedFile("fixtures/beat_actor_library.json"));
    defer parsed.deinit();
    const bundle = parsed.value;
    const Scene = struct {
        unite_actors: ?*const host.Bundle,
        camera_ticks: u32 = 0,
        unite_flags: [12]u16 = @splat(0),
        actor_camera: ?camera.ActorController = null,
        recovery: [6]u8 = @splat(0),
        pub fn partyCount(_: @This()) usize {
            return 2;
        }
        pub fn enemyCount(_: @This()) usize {
            return 1;
        }
        pub fn prepareUniteScene(_: *@This(), _: usize) !void {}
        pub fn requestUniteRecovery(self: *@This(), actor: usize, value: u8) !void {
            self.recovery[actor] = value;
        }
    };
    const block = camera.Block{ .focus = .{ 0, 0, 0 }, .angles = .{ 0, 0, 0 }, .translation = .{ 0, 0, 1024 }, .scale = .{ 1024, 1024, 1024 } };
    const homes = [_][3]i32{ .{ 0, 0, 0 }, .{ 0, 40 * 4096, 0 }, .{ 120 * 4096 + 17, 25 * 4096 + 23, 0 } };
    for (0..2) |order| {
        const party: [2][]const u8 = if (order == 0) .{ "pahn", "ronnie" } else .{ "ronnie", "pahn" };
        const pahn: usize = order;
        const bell: usize = 1 - order;
        var scene = Scene{ .unite_actors = &bundle };
        var playback = battle.unite_playback.State{};
        try playback.begin(&bundle, 27, @intCast(order), 2, &party, &homes, 0);
        var spawned = false;
        var completed = false;
        var sound_count: usize = 0;
        for (0..451) |tick| {
            scene.camera_ticks = @intCast(tick);
            const before = playback.actors[bell].position_q12;
            if (tick == 299) try playback.emitSound(scene.camera_ticks, @intCast(pahn), 0x7fff);
            try playback.advanceCallbackChild(&scene, @intCast(order), homes[2], .{ 200, -190 }, block);
            try playback.advanceTransition(&bundle, @intCast(order), &scene.unite_flags);
            if (playback.hitReady(pahn)) {
                try std.testing.expectEqual(@as(usize, 62), tick);
                scene.unite_flags[pahn] &= ~@as(u16, 2);
                playback.actors[pahn].signals &= ~@as(u16, 2);
            }
            if (playback.hitReady(bell)) {
                try std.testing.expectEqual(@as(usize, 330), tick);
                scene.unite_flags[bell] &= ~@as(u16, 2);
                playback.actors[bell].signals &= ~@as(u16, 2);
            }
            if (!spawned and playback.hasAuxiliary()) {
                try std.testing.expectEqual(@as(usize, 299), tick);
                const child = playback.auxiliary[playback.auxiliary_capacity - 1].?;
                try std.testing.expectEqualDeep([3]i32{ before[0] - 10 * 4096, before[1], before[2] - 20 * 4096 }, child.position_q12);
                try std.testing.expectEqualDeep(homes[2], child.home_q12);
                try std.testing.expectEqualDeep([2]i32{ 200, -190 }, child.offset_destination);
                try std.testing.expectEqual(@as(i16, 99), playback.actors[bell].shared_value);
                spawned = true;
            }
            if (!completed and playback.allReady(order)) {
                try std.testing.expectEqual(@as(usize, 343), tick);
                try std.testing.expect(playback.hasAuxiliary());
                completed = true;
            }
            try playback.update(&scene, block);
            const sounds = playback.takeSounds();
            if (tick == 299) {
                try std.testing.expect(sounds.len >= 2);
                try std.testing.expectEqual(battle.unite_playback.Sound{ .actor = @intCast(pahn), .id = 0x7fff }, sounds[0]);
                try std.testing.expectEqual(@as(u16, 1316), sounds[1].id);
            }
            for (sounds) |sound| if (sound.id == 1316) {
                sound_count += 1;
            };
            if (tick == 390) {
                try std.testing.expect(playback.hasAuxiliary());
                try std.testing.expect(!playback.auxiliary[playback.auxiliary_capacity - 1].?.visible);
            }
            if (tick == 391) try std.testing.expect(!playback.hasAuxiliary());
        }
        try std.testing.expect(spawned and completed);
        try std.testing.expectEqual(@as(usize, 1), sound_count);
        try std.testing.expectEqual(@as(u8, 2), scene.recovery[pahn]);
        try std.testing.expectEqual(@as(u8, 0), scene.recovery[bell]);
    }
}

test "Beat bindings reject missing children and mismatched resource or callback fields" {
    const parsed = try host.loadBundle(a, @embedFile("fixtures/beat_actor_library.json"));
    defer parsed.deinit();
    var bundle = parsed.value;
    const bindings = try a.dupe(host.UniteBinding, bundle.unites);
    defer a.free(bindings);
    bundle.unites = bindings;
    const original = bindings[27];
    bundle.schema = "suikoden-unite-actors/27";
    try std.testing.expectError(error.InvalidUniteBindings, bundle.validate());
    bundle.schema = parsed.value.schema;
    bindings[27].beat_child = null;
    try std.testing.expectError(error.InvalidUniteBindings, bundle.validate());
    bindings[27] = original;
    bindings[27].beat_child.?.resource = "pahn";
    try std.testing.expectError(error.InvalidUniteBindings, bundle.validate());
    bindings[27] = original;
    bindings[27].beat_child.?.home = .spawn;
    try std.testing.expectError(error.InvalidUniteBindings, bundle.validate());
    bindings[27] = original;
    bindings[27].beat_child.?.program = "ronnie/absent";
    try std.testing.expectError(error.MissingUniteProgram, bundle.validate());
    bindings[27] = original;
    bindings[27].damage_member = 0;
    try std.testing.expectError(error.InvalidUniteBindings, bundle.validate());
}

test "actor status thresholds preserve side Turtle duplicate and zero HP ordering" {
    const content = try Battle.load(a, @embedFile("fixtures/journey_battle.json"));
    defer content.deinit();
    const items = try Field.items.load(a, Field.items.json);
    defer items.deinit();
    const kinds = [_]@FieldType(vm.Status, "kind"){ .poison, .balloon, .accuracy_reduced, .sleep, .rune_blocked };
    // Source scaled/modulo outputs are 0, 19, 20, 99 and 0 respectively.
    const rolls = [_]u15{ 0, 6553, 6554, 32766, 32767 };
    const percentages = [_]u8{ 0, 19, 20, 99, 0 };
    for (kinds) |kind| for ([_]u8{ 0, 20, 100 }) |threshold| for (rolls, percentages) |roll, percent| for (0..3) |variant| {
        var members: [6]Battle.Member = undefined;
        var state = try Battle.State.init(content.value, items.value, &members, 17);
        const party = variant != 2;
        if (!party and (kind == .poison or kind == .balloon)) continue;
        const target = if (party) @as(usize, 0) else state.partyCount();
        const turtle = variant == 1;
        state.runes[0] = if (turtle) content.value.systems.?.runeIndex("turtle").? else null;
        const values = [_]u15{ roll, roll };
        var draws = Rules.Draws{ .values = &values };
        state.replay_draws = &draws;
        const request = vm.Status{ .kind = kind, .threshold_percent = threshold };
        try state.requestActorStatus(target, request);
        const expected = !turtle and (if (party) percent < threshold else percent >= threshold);
        const actual = switch (kind) {
            .poison => state.progress.party[0].status == .poisoned,
            .balloon => state.progress.party[0].balloons > 0,
            .sleep => state.asleep[target] > 0,
            .accuracy_reduced => state.accuracy_reduced[target],
            .rune_blocked => state.rune_blocked[target],
        };
        try std.testing.expectEqual(expected, actual);
        try std.testing.expectEqual(@as(usize, if (turtle) 0 else 1), draws.cursor);
        try state.requestActorStatus(target, request);
        try std.testing.expectEqual(@as(usize, if (turtle) 0 else 2), draws.cursor);
    };
    var members: [6]Battle.Member = undefined;
    var state = try Battle.State.init(content.value, items.value, &members, 17);
    state.runes[0] = null;
    state.progress.party[0].hp = 0;
    state.markPartyKnockout(0);
    const values = [_]u15{0};
    var draws = Rules.Draws{ .values = &values };
    state.replay_draws = &draws;
    try state.requestActorStatus(0, .{ .kind = .poison, .threshold_percent = 20 });
    try std.testing.expectEqual(Field.game_state.Status.poisoned, state.knockout_status[0].?);
    try std.testing.expectEqual(Field.game_state.Status.unconscious, state.progress.party[0].status);
    try std.testing.expectEqual(@as(u8, 1), state.status_icons[0].active & 1);
    state.progress.party[0].inventory.slots[0] = .{ .id = .sacrificial_buddha, .uses = 0 };
    try std.testing.expect(!state.commitPartyKnockout(0));
    try std.testing.expectEqual(Field.game_state.Status.poisoned, state.revivals[0].?.original_status);
    const revival_start = state.revivals[0].?.started_at;
    state.camera_ticks = revival_start + state.rules.automatic_revival.?.pending_delay;
    state.advanceRevivals();
    state.camera_ticks = revival_start + state.rules.automatic_revival.?.impact_delay;
    state.advanceRevivals();
    try std.testing.expect(state.hp(0) > 0);
    try std.testing.expectEqual(Field.game_state.Status.poisoned, state.progress.party[0].status);
    const poisoned = state;
    try std.testing.expectError(error.RandomInputExhausted, state.requestActorStatus(0, .{ .kind = .accuracy_reduced, .threshold_percent = 100 }));
    try std.testing.expect(!state.accuracy_reduced[0]);
    try std.testing.expectEqualDeep(poisoned.progress, state.progress);
    try std.testing.expectError(error.InvalidActorStatus, state.requestActorStatus(state.partyCount(), .{ .kind = .poison, .threshold_percent = 20 }));
    try std.testing.expectError(error.InvalidActorStatus, state.requestActorStatus(12, .{ .kind = .poison, .threshold_percent = 20 }));
    try std.testing.expectError(error.InvalidActorStatus, state.requestActorStatus(0, .{ .kind = .poison, .threshold_percent = 101 }));
}

test "actor status reaches the live playback bridge at its own script clock" {
    const content = try Battle.load(a, @embedFile("fixtures/journey_unites_battle.json"));
    defer content.deinit();
    const library = try host.loadBundle(a, @embedFile("fixtures/journey_unites_actor_library.json"));
    defer library.deinit();
    const items = try Field.items.load(a, Field.items.json);
    defer items.deinit();
    const programs = try a.dupe(vm.Program, library.value.programs.programs);
    defer a.free(programs);
    var status_code = [_]vm.Instruction{ .{ .delay = 2 }, .{ .command = .{ .status = .{ .kind = .poison, .threshold_percent = 20 } } }, .{ .halt = {} } };
    const waiting = [_]vm.Instruction{ .{ .delay = 100 }, .{ .halt = {} } };
    for (programs) |*program| {
        if (std.mem.eql(u8, program.id, "gremio/unite_9")) program.instructions = &status_code;
        if (std.mem.eql(u8, program.id, "pahn/unite_9")) program.instructions = &waiting;
    }
    var bundle = library.value;
    bundle.programs.programs = programs;
    try bundle.validate();
    for ([_]@FieldType(vm.Status, "kind"){ .poison, .balloon, .sleep }) |kind| for ([_]bool{ false, true }) |turtle| {
        status_code[1].command.status.kind = kind;
        var members: [6]Battle.Member = undefined;
        var state = try Battle.State.init(content.value, items.value, &members, 17);
        state.runes[1] = if (turtle) content.value.systems.?.runeIndex("turtle").? else null;
        state.unite_actors = &bundle;
        const homes: [12][3]i32 = @splat(.{ 0, 0, 0 });
        try state.unite_vm.begin(&bundle, 0, 1, 6, content.value.initial_party.?, homes[0 .. state.partyCount() + state.enemyCount()], 0);
        const values = [_]u15{0};
        var draws = Rules.Draws{ .values = if (turtle) &.{} else &values };
        state.replay_draws = &draws;
        state.camera_ticks = 1;
        try state.unite_vm.update(&state, @import("battle_camera").settled_pan);
        try std.testing.expectEqual(Field.game_state.Status.healthy, members[1].status);
        try std.testing.expectEqual(@as(usize, 0), draws.cursor);
        state.camera_ticks = 2;
        try state.unite_vm.update(&state, @import("battle_camera").settled_pan);
        try std.testing.expectEqual(if (!turtle and kind == .poison) Field.game_state.Status.poisoned else Field.game_state.Status.healthy, members[1].status);
        try std.testing.expectEqual(@as(u8, @intFromBool(!turtle and kind == .balloon)), members[1].balloons);
        try std.testing.expectEqual(@as(u8, @intFromBool(!turtle and kind == .sleep)), state.asleep[1]);
        try std.testing.expectEqual(!turtle and kind == .sleep, state.acted[1]);
        try std.testing.expectEqual(@as(usize, if (turtle) 0 else 1), draws.cursor);
        try std.testing.expect(!state.accuracy_reduced[6] and !state.rune_blocked[6]);
        state.camera_ticks = 3;
        try state.unite_vm.update(&state, @import("battle_camera").settled_pan);
        try std.testing.expectEqual(@as(usize, if (turtle) 0 else 1), draws.cursor);
    };
}

test "actor status balloons draw before worn-hat duplicate and departure guards" {
    const content = try Battle.load(a, @embedFile("fixtures/journey_battle.json"));
    defer content.deinit();
    const items = try Field.items.load(a, Field.items.json);
    defer items.deinit();
    for (0..6) |actor| for (0..4) |existing| for (0..4) |variant| {
        var members: [6]Battle.Member = undefined;
        var state = try Battle.State.init(content.value, items.value, &members, 17);
        state.runes[actor] = if (variant == 3) content.value.systems.?.runeIndex("turtle").? else null;
        state.loadouts[actor].head = if (variant == 1) state.gearIndex(.pointed_hat).? else null;
        if (variant == 1 or variant == 2) members[actor].inventory.slots[0] = .{ .id = .pointed_hat, .uses = 0 };
        members[actor].balloons = @intCast(existing);
        const before = members[actor];
        const values = [_]u15{0};
        var draws = Rules.Draws{ .values = if (variant == 3) &.{} else &values };
        state.replay_draws = &draws;
        try state.requestActorStatus(actor, .{ .kind = .balloon, .threshold_percent = 30 });
        const expected: u8 = @intCast(if (variant == 1 or variant == 3) existing else @min(3, existing + 1));
        try std.testing.expectEqual(expected, members[actor].balloons);
        try std.testing.expectEqual(@as(usize, if (variant == 3) 0 else 1), draws.cursor);
        try std.testing.expectEqual(before.hp, members[actor].hp);
        try std.testing.expectEqual(before.status, members[actor].status);
        try std.testing.expect(!state.departed[actor]);
        state.applyRoundBoundaryStatuses();
        try std.testing.expectEqual(expected == 3, state.departed[actor]);
        try std.testing.expectEqual(before.hp, members[actor].hp);
        if (expected == 3) {
            try std.testing.expect(!state.participates(actor));
            try std.testing.expectEqual(@as(u32, 0), state.experienceAward(actor));
        }
    };
    var members: [6]Battle.Member = undefined;
    var state = try Battle.State.init(content.value, items.value, &members, 17);
    state.runes[0] = null;
    var empty = Rules.Draws{ .values = &.{} };
    state.replay_draws = &empty;
    const before = members;
    try std.testing.expectError(error.RandomInputExhausted, state.requestActorStatus(0, .{ .kind = .balloon, .threshold_percent = 30 }));
    try std.testing.expectEqualDeep(before, members);
    try std.testing.expectError(error.InvalidActorStatus, state.requestActorStatus(state.partyCount(), .{ .kind = .balloon, .threshold_percent = 30 }));
}

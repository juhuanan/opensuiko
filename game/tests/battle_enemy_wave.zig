const std = @import("std");
const battle = @import("battle");
const wave = battle.enemy_wave;
const host = battle.actor_host;

fn library(alloc: std.mem.Allocator) !host.Library {
    const Packet = struct { programs: battle.actor_program.Packet, animations: host.Resources };
    const parsed = try std.json.parseFromSlice(Packet, alloc, @embedFile("fixtures/enemy_holly_fairy_source.json"), .{ .ignore_unknown_fields = true });
    try parsed.value.programs.validate();
    try parsed.value.animations.validate();
    return .{ .programs = parsed.value.programs, .resources = parsed.value.animations };
}

const Context = struct {
    acted: [6]bool = .{ false, false, false, false, false, true },
    locked: [6]bool = @splat(false),
    inactive: [6]bool = @splat(false),
    signals: [6]u16 = @splat(255),
    results: [6]wave.Decision = @splat(.no_action),
    decisions: [6]u16 = @splat(0),
    attacks: [6]u16 = @splat(0),
    resolver_accepts: bool = true,
    fail_actor: ?usize = null,
    current_actor: usize = 5,
    primary_owner: usize = 5,
    restored: u16 = 0,

    pub fn partyCount(_: *Context) usize {
        return 2;
    }
    pub fn enemyCount(_: *Context) usize {
        return 4;
    }
    pub fn eligible(self: *Context, actor: usize) bool {
        return !self.acted[actor] and !self.locked[actor] and !self.inactive[actor];
    }
    pub fn decision(self: *Context, actor: usize) !wave.Decision {
        self.current_actor = actor;
        self.decisions[actor] += 1;
        if (self.fail_actor == actor) return error.RandomInputExhausted;
        // Exercise restoration after a zero result, and ownership transfer after one.
        if (self.results[actor] == .no_action or self.results[actor] == .started) self.primary_owner = actor;
        return self.results[actor];
    }
    pub fn ordinary(self: *Context, actor: usize) !bool {
        try std.testing.expectEqual(actor, self.current_actor);
        self.attacks[actor] += 1;
        return self.resolver_accepts;
    }
    pub fn markStarted(self: *Context, actor: usize) void {
        self.acted[actor] = true;
        self.signals[actor] = 0;
    }
    pub fn restoreWave(self: *Context, owner: usize) void {
        self.primary_owner = owner;
    }
    pub fn restoreOwner(self: *Context, owner: usize) void {
        self.current_actor = owner;
        self.restored += 1;
    }
};

fn actorsFor(lib: host.Library) ![6]host.Actor {
    var actors: [6]host.Actor = undefined;
    for (&actors) |*actor| actor.* = try host.Actor.init(lib.resources.find("holly_fairy").?, .{ 0, 0, 0 });
    return actors;
}

test "Holly Fairy wave actor mailbox clock observes the complete source animation tail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lib = try library(arena.allocator());
    var actors = try actorsFor(lib);
    var runtime = host.Runtime{ .actors = &actors, .library = lib };
    var action = try wave.Action.begin(&runtime, 5);
    var context: Context = .{};
    var first: ?usize = null;
    var last: usize = 0;
    var done: ?usize = null;
    for (1..181) |update| {
        const before = context.decisions[2];
        if (try action.advance(&runtime, &context) == .completed) done = update;
        if (context.decisions[2] != before) {
            if (first == null) first = update;
            last = update;
        }
        runtime.beginUpdate();
        try runtime.stepActor(5);
    }
    // Independent source frames: 12 lasts13, 13 lasts16, 14 lasts1; mailbox writes yield.
    try std.testing.expectEqual(@as(usize, 31), first.?);
    try std.testing.expectEqual(@as(usize, 152), last);
    try std.testing.expectEqual(@as(usize, 153), done.?);
    try std.testing.expectEqual(@as(u16, 122), context.decisions[2]);
    try std.testing.expectEqual(context.decisions[2], context.decisions[3]);
    try std.testing.expectEqual(context.decisions[2], context.decisions[4]);
    try std.testing.expectEqual(@as(usize, 5), context.current_actor);
    try std.testing.expectEqual(@as(usize, 5), context.primary_owner);
    try std.testing.expect(action.completed and actors[5].machine.?.halted);
    try std.testing.expectEqual(@as(u16, 0), actors[5].signals);
    try std.testing.expectEqual(@as(u8, 30), wave.selection_delay);
}

test "Holly Fairy wave actor skips unavailable allies and launches only one per primary update" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lib = try library(arena.allocator());
    var actors = try actorsFor(lib);
    var runtime = host.Runtime{ .actors = &actors, .library = lib };
    var action = try wave.Action.begin(&runtime, 5);
    actors[5].shared_value = 1;
    for (0..3) |guard| {
        var context: Context = .{};
        context.results = @splat(.ordinary_attack);
        switch (guard) {
            0 => context.acted[2] = true,
            1 => context.locked[2] = true,
            2 => context.inactive[2] = true,
            else => unreachable,
        }
        _ = try action.advance(&runtime, &context);
        try std.testing.expectEqual(@as(u16, 0), context.decisions[2]);
        try std.testing.expectEqual(@as(u16, 1), context.attacks[3]);
        try std.testing.expect(context.acted[3]);
        try std.testing.expectEqual(@as(u16, 0), context.signals[3]);
        try std.testing.expectEqual(@as(u16, 0), context.decisions[4]);
        _ = try action.advance(&runtime, &context);
        try std.testing.expectEqual(@as(u16, 1), context.attacks[4]);
        try std.testing.expectEqual(@as(usize, 5), context.current_actor);
    }
}

test "Holly Fairy wave actor continues past zero and consumes a refused ordinary turn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lib = try library(arena.allocator());
    var actors = try actorsFor(lib);
    var runtime = host.Runtime{ .actors = &actors, .library = lib };
    var action = try wave.Action.begin(&runtime, 5);
    actors[5].shared_value = 1;
    var context: Context = .{ .resolver_accepts = false };
    context.results[3] = .ordinary_attack;
    _ = try action.advance(&runtime, &context);
    try std.testing.expectEqual(@as(u16, 1), context.decisions[2]);
    try std.testing.expect(!context.acted[2]);
    try std.testing.expectEqual(@as(u16, 255), context.signals[2]);
    try std.testing.expectEqual(@as(u16, 1), context.attacks[3]);
    try std.testing.expect(context.acted[3]);
    try std.testing.expectEqual(@as(u16, 0), context.signals[3]);
    try std.testing.expectEqual(@as(u16, 0), context.decisions[4]);
    try std.testing.expectEqual(@as(usize, 5), context.primary_owner);
    try std.testing.expectEqual(@as(usize, 5), context.current_actor);
}

test "Holly Fairy wave actor retains delegated primary on one and stops on other results" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lib = try library(arena.allocator());
    var actors = try actorsFor(lib);
    var runtime = host.Runtime{ .actors = &actors, .library = lib };
    var action = try wave.Action.begin(&runtime, 5);
    actors[5].shared_value = 1;
    for ([_]wave.Decision{ .started, .stop }) |result| {
        var context: Context = .{};
        context.results[2] = result;
        _ = try action.advance(&runtime, &context);
        try std.testing.expectEqual(@as(u16, 0), context.decisions[3]);
        try std.testing.expectEqual(result == .started, context.acted[2]);
        try std.testing.expectEqual(@as(u16, if (result == .started) 0 else 255), context.signals[2]);
        try std.testing.expectEqual(@as(usize, if (result == .started) 2 else 5), context.primary_owner);
        try std.testing.expectEqual(@as(usize, 5), context.current_actor);
        try std.testing.expectEqual(@as(u16, 0), context.attacks[2]);
    }
}

test "Holly Fairy wave actor propagates failed decisions and refuses missing owner bindings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lib = try library(arena.allocator());
    var actors = try actorsFor(lib);
    var runtime = host.Runtime{ .actors = &actors, .library = lib };
    try std.testing.expectError(error.InvalidActorBinding, wave.Action.begin(&runtime, 6));
    runtime.library = null;
    try std.testing.expectError(error.MissingActorLibrary, wave.Action.begin(&runtime, 5));
    runtime.library = lib;
    runtime.library.?.programs.programs = &.{};
    try std.testing.expectError(error.MissingActorProgram, wave.Action.begin(&runtime, 5));
    runtime.library = lib;
    actors[5].resource = null;
    try std.testing.expectError(error.InvalidActorBinding, wave.Action.begin(&runtime, 5));
    try std.testing.expect(actors[5].machine == null);
    actors = try actorsFor(lib);
    var action = try wave.Action.begin(&runtime, 5);
    actors[5].shared_value = 1;
    var context: Context = .{ .fail_actor = 2 };
    try std.testing.expectError(error.RandomInputExhausted, action.advance(&runtime, &context));
    try std.testing.expectEqual(@as(usize, 5), context.current_actor);
    try std.testing.expectEqual(@as(u16, 0), context.decisions[3]);
    try std.testing.expect(!context.acted[2] and !action.completed);
}

test "Holly Fairy wave actor checkpoints resume across mailbox and final animation boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const lib = try library(alloc);
    const replacement = try library(alloc);
    for ([_]usize{ 0, 30, 31, 151, 152, 153 }) |checkpoint| {
        var actors = try actorsFor(lib);
        var runtime = host.Runtime{ .actors = &actors, .library = lib };
        var action = try wave.Action.begin(&runtime, 5);
        var context: Context = .{};
        for (0..checkpoint) |_| {
            _ = try action.advance(&runtime, &context);
            try runtime.stepActor(5);
        }
        const actor_json = try std.json.Stringify.valueAlloc(alloc, actors[5], .{});
        const action_json = try std.json.Stringify.valueAlloc(alloc, action, .{});
        var restored_actors = try actorsFor(replacement);
        restored_actors[5] = (try std.json.parseFromSlice(host.Actor, alloc, actor_json, .{})).value;
        restored_actors[5].resource = replacement.resources.find("holly_fairy");
        restored_actors[5].machine.?.instructions = replacement.programs.find("melee/holly_fairy/wave_owner").?.instructions;
        var restored_action = (try std.json.parseFromSlice(wave.Action, alloc, action_json, .{})).value;
        var restored_context = context;
        var restored_runtime = host.Runtime{ .actors = &restored_actors, .library = replacement };
        for (checkpoint..181) |_| {
            try std.testing.expectEqual(try action.advance(&runtime, &context), try restored_action.advance(&restored_runtime, &restored_context));
            try runtime.stepActor(5);
            try restored_runtime.stepActor(5);
            try std.testing.expectEqualDeep(action, restored_action);
            try std.testing.expectEqualDeep(context, restored_context);
            try std.testing.expectEqualDeep(actors[5], restored_actors[5]);
        }
        try std.testing.expect(action.completed and actors[5].machine.?.halted);
    }
}

test "Holly Fairy idle actor post-sweep restart retains signed Q12 residue and a 61-update cycle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lib = try library(arena.allocator());
    var actors = try actorsFor(lib);
    const origin: [3]i32 = .{ 12345, -23456, 34567 };
    actors[5].position_q12 = origin;
    var runtime = host.Runtime{ .actors = &actors, .library = lib };
    const idle = lib.programs.find("melee/holly_fairy/idle").?;
    var restarts: usize = 0;
    for (1..186) |update| {
        try runtime.stepActor(5);
        if (actors[5].machine == null or actors[5].machine.?.halted) {
            try runtime.dispatch(5, 5, idle);
            restarts += 1;
            try std.testing.expectEqual(@as(usize, 0), (update - 1) % 61);
        }
        const phase: i32 = @intCast((update - 1) % 61);
        const delta: i32 = if (phase < 30) -1365 * phase else if (phase == 30) -40960 else if (phase < 60) -40960 + 1365 * (phase - 30) else 0;
        try std.testing.expectEqual(origin[0], actors[5].position_q12[0]);
        try std.testing.expectEqual(origin[1], actors[5].position_q12[1]);
        try std.testing.expectEqual(origin[2] + delta, actors[5].position_q12[2]);
        try std.testing.expectEqual(@as(u16, 0), actors[5].animation);
    }
    try std.testing.expectEqual(@as(usize, 4), restarts);
}

test "Holly Fairy idle actor interruption preserves pending motion and delays the source wave" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lib = try library(arena.allocator());
    for ([_]usize{ 1, 2, 15, 30, 31, 32, 45, 60, 61, 62 }) |at| {
        var actors = try actorsFor(lib);
        var runtime = host.Runtime{ .actors = &actors, .library = lib };
        const idle = lib.programs.find("melee/holly_fairy/idle").?;
        for (0..at) |_| {
            try runtime.stepActor(5);
            if (actors[5].machine == null or actors[5].machine.?.halted) try runtime.dispatch(5, 5, idle);
        }
        const move = actors[5].movement;
        const pending: u32 = if (move) |motion| motion.remaining else 0;
        const destination = if (move) |motion| motion.destination else actors[5].position_q12;
        const velocity = actors[5].velocity_q12;
        var action = try wave.Action.begin(&runtime, 5);
        try std.testing.expectEqualDeep(move, actors[5].movement);
        try std.testing.expectEqualDeep(velocity, actors[5].velocity_q12);
        var context: Context = .{};
        context.acted = @splat(true);
        var first_active: ?usize = null;
        var completed: ?usize = null;
        for (1..201) |update| {
            if (actors[5].shared_value == 1 and first_active == null) first_active = update;
            if (try action.advance(&runtime, &context) == .completed) completed = update;
            try runtime.stepActor(5);
        }
        try std.testing.expectEqual(@as(usize, 31) + pending, first_active.?);
        try std.testing.expectEqual(@as(usize, 153) + pending, completed.?);
        try std.testing.expectEqualDeep(destination, actors[5].position_q12);
        try std.testing.expect(action.completed and actors[5].machine.?.halted);
    }
}

test "Holly Fairy idle actor motion continues through attack preparation until the leap replaces it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lib = try library(arena.allocator());
    var actors = try actorsFor(lib);
    var runtime = host.Runtime{ .actors = &actors, .library = lib };
    const idle = lib.programs.find("melee/holly_fairy/idle").?;
    for (0..15) |_| {
        try runtime.stepActor(5);
        if (actors[5].machine == null or actors[5].machine.?.halted) try runtime.dispatch(5, 5, idle);
    }
    const start = actors[5].position_q12;
    const motion = actors[5].movement;
    const velocity = actors[5].velocity_q12;
    try runtime.dispatch(5, 0, lib.programs.find("melee/holly_fairy/attack").?);
    try std.testing.expectEqualDeep(motion, actors[5].movement);
    // Source animation4 totals13 updates; its first12 advances retain idle's linear motion.
    for (1..13) |update| {
        try runtime.stepActor(5);
        try std.testing.expectEqual(start[2] + @as(i32, @intCast(update)) * velocity[2], actors[5].position_q12[2]);
        try std.testing.expectEqualDeep([3]i32{ 0, 0, 0 }, actors[5].acceleration_q12);
        try std.testing.expectEqual(motion.?.remaining - @as(u16, @intCast(update)), actors[5].movement.?.remaining);
    }
    try runtime.stepActor(5);
    try std.testing.expect(actors[5].acceleration_q12[2] != 0);
    try std.testing.expectEqual(@as(u16, 19), actors[5].movement.?.remaining);
}

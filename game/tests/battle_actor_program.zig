const std = @import("std");
const vm = @import("battle").actor_program;

test "actor RGB command requires version12 and rejects invalid serialized channels" {
    const instructions = [_]vm.Instruction{ .{ .command = .{ .color = .{ 255, 64, 64 } } }, .{ .halt = {} } };
    const programs = [_]vm.Program{.{ .id = "rgb", .instructions = &instructions }};
    var packet = vm.Packet{ .schema = "suikoden-actor-programs/12", .programs = &programs };
    try packet.validate();
    for ([_][]const u8{ "suikoden-actor-programs/7", "suikoden-actor-programs/8", "suikoden-actor-programs/9", "suikoden-actor-programs/10", "suikoden-actor-programs/11" }) |schema| {
        packet.schema = schema;
        try std.testing.expectError(error.InvalidActorPrograms, packet.validate());
    }
    for ([_][]const u8{ "[256,0,0]", "[-1,0,0]", "[0,0]", "[0,0,0,0]" }) |channels| {
        const bytes = try std.fmt.allocPrint(std.testing.allocator, "{{\"schema\":\"suikoden-actor-programs/12\",\"programs\":[{{\"id\":\"rgb\",\"instructions\":[{{\"command\":{{\"color\":{s}}}}},{{\"halt\":{{}}}}]}}]}}", .{channels});
        defer std.testing.allocator.free(bytes);
        if (vm.load(std.testing.allocator, bytes)) |parsed| {
            parsed.deinit();
            return error.InvalidActorColorAccepted;
        } else |_| {}
    }
}

const State = struct {
    signals: [2]u16 = .{ 0, 0 },
    value: i16 = 0,
    animation_done: bool = false,
    commands: usize = 0,
    starts: usize = 0,
    polls: usize = 0,
    finish_ready: bool = false,
    fn command(context: *anyopaque, actor: u16, action: vm.Command, resuming: bool) !bool {
        const self: *State = @ptrCast(@alignCast(context));
        switch (action) {
            .signal_set => |mask| self.signals[if (mask.target == .owner) 0 else actor] |= mask.bits,
            .signal_clear => |mask| self.signals[if (mask.target == .owner) 0 else actor] &= ~mask.bits,
            .shared_value => |value| self.value = value,
            .animation => self.animation_done = false,
            .teardown => {
                if (resuming) self.polls += 1 else self.starts += 1;
                return self.finish_ready;
            },
            else => return error.UnsupportedActorCommand,
        }
        self.commands += 1;
        return true;
    }
    fn ready(context: *anyopaque, actor: u16, condition: vm.Condition) !bool {
        const self: *State = @ptrCast(@alignCast(context));
        return switch (condition) {
            .animation_done => self.animation_done,
            .signal_set => |mask| self.signals[if (mask.target == .owner) 0 else actor] & mask.bits != 0,
            .signal_clear => |mask| self.signals[if (mask.target == .owner) 0 else actor] & mask.bits == 0,
            .shared_value => |value| self.value == value,
            else => error.UnsupportedActorCondition,
        };
    }
    fn host(self: *State) vm.Host {
        return .{ .context = self, .command = command, .ready = ready };
    }
};

test "actor VM waits for live animation and owner signals rather than exported tick guesses" {
    const code = [_]vm.Instruction{
        .{ .command = .{ .animation = 4 } },                                .{ .wait = .{ .animation_done = {} } },
        .{ .wait = .{ .signal_set = .{ .target = .owner, .bits = 2 } } },   .{ .command = .{ .signal_set = .{ .target = .self, .bits = 4 } } },
        .{ .wait = .{ .signal_clear = .{ .target = .owner, .bits = 2 } } }, .{ .command = .{ .shared_value = 99 } },
        .{ .halt = {} },
    };
    var host = State{};
    var machine = vm.Machine.init(.{ .id = "dynamic", .instructions = &code }, 1);
    try machine.dispatch(host.host());
    for (0..7) |_| try machine.update(host.host());
    try std.testing.expectEqual(@as(usize, 1), machine.pc);
    host.animation_done = true;
    try machine.update(host.host());
    try std.testing.expectEqual(@as(usize, 2), machine.pc);
    host.signals[0] = 2;
    try machine.update(host.host());
    try std.testing.expectEqual(@as(u16, 4), host.signals[1]);
    try std.testing.expect(!machine.halted);
    host.signals[0] = 0;
    try machine.update(host.host());
    try std.testing.expect(machine.halted);
    try std.testing.expectEqual(@as(i16, 99), host.value);
    const commands = host.commands;
    try machine.update(host.host());
    try std.testing.expectEqual(commands, host.commands);
}

test "actor VM counts dispatch-frame delays and resumes blocking commands without restarting" {
    const code = [_]vm.Instruction{ .{ .delay = 2 }, .{ .command = .{ .teardown = {} } }, .{ .halt = {} } };
    var host = State{};
    var machine = vm.Machine.init(.{ .id = "delay", .instructions = &code }, 0);
    try machine.dispatch(host.host());
    try std.testing.expectEqual(@as(u16, 2), machine.remaining);
    try machine.update(host.host());
    try std.testing.expectEqual(@as(usize, 0), host.starts);
    try machine.update(host.host());
    try std.testing.expectEqual(@as(usize, 1), host.starts);
    try machine.update(host.host());
    host.finish_ready = true;
    try machine.update(host.host());
    try std.testing.expectEqual(@as(usize, 1), host.starts);
    try std.testing.expectEqual(@as(usize, 2), host.polls);
    try std.testing.expect(machine.halted);
}

test "actor VM propagates unsupported host operations without skipping them" {
    const code = [_]vm.Instruction{ .{ .command = .{ .sound = 1 } }, .{ .halt = {} } };
    var host = State{};
    var machine = vm.Machine.init(.{ .id = "unsupported", .instructions = &code }, 0);
    try std.testing.expectError(error.UnsupportedActorCommand, machine.dispatch(host.host()));
    try std.testing.expectEqual(@as(usize, 0), machine.pc);
    try std.testing.expect(!machine.halted);
}

test "actor VM movement restart requires schema nine and preserves signed operands" {
    const packet = try vm.load(std.testing.allocator, "{\"schema\":\"suikoden-actor-programs/9\",\"programs\":[{\"id\":\"restart\",\"instructions\":[{\"command\":{\"resume_motion\":-32768}},{\"halt\":{}}]}]}");
    defer packet.deinit();
    try std.testing.expectEqual(@as(i16, -32768), packet.value.programs[0].instructions[0].command.resume_motion);
    var legacy = packet.value;
    for ([_][]const u8{ "suikoden-actor-programs/7", "suikoden-actor-programs/8" }) |schema| {
        legacy.schema = schema;
        try std.testing.expectError(error.InvalidActorPrograms, legacy.validate());
    }
}

test "actor VM packet parser rejects missing children duplicate ids and unterminated code" {
    const valid = try vm.load(std.testing.allocator, "{\"schema\":\"suikoden-actor-programs/7\",\"programs\":[{\"id\":\"one\",\"instructions\":[{\"delay\":0},{\"halt\":{}}]}]}");
    defer valid.deinit();
    var legacy = valid.value;
    for ([_][]const u8{ "suikoden-actor-programs/1", "suikoden-actor-programs/2", "suikoden-actor-programs/3", "suikoden-actor-programs/4", "suikoden-actor-programs/5", "suikoden-actor-programs/6" }) |schema| {
        legacy.schema = schema;
        try std.testing.expectError(error.InvalidActorPrograms, legacy.validate());
    }
    try std.testing.expect(valid.value.find("one") != null);
    var host = State{};
    var machine = vm.Machine.init(valid.value.programs[0], 0);
    try machine.dispatch(host.host());
    try std.testing.expect(!machine.halted);
    try machine.update(host.host());
    try std.testing.expect(machine.halted);
    const code = [_]vm.Instruction{.{ .command = .{ .animation = 1 } }};
    try std.testing.expectError(error.InvalidActorPrograms, (vm.Packet{ .schema = "suikoden-actor-programs/7", .programs = &.{.{ .id = "bad", .instructions = &code }} }).validate());
    const end = [_]vm.Instruction{.{ .halt = {} }};
    try std.testing.expectError(error.InvalidActorPrograms, (vm.Packet{ .schema = "suikoden-actor-programs/7", .programs = &.{ .{ .id = "duplicate", .instructions = &end }, .{ .id = "duplicate", .instructions = &end } } }).validate());
    const child = [_]vm.Instruction{ .{ .command = .{ .child = .{ .program = "missing", .resource = "actor", .animation = 0, .offset = .{ 0, 0, 0 } } } }, .{ .halt = {} } };
    try std.testing.expectError(error.MissingActorChildProgram, (vm.Packet{ .schema = "suikoden-actor-programs/7", .programs = &.{.{ .id = "parent", .instructions = &child }} }).validate());
}

test "actor status commands require schema ten and bounded thresholds" {
    var code = [_]vm.Instruction{ .{ .command = .{ .status = .{ .kind = .poison, .threshold_percent = 20 } } }, .{ .halt = {} } };
    const programs = [_]vm.Program{.{ .id = "status", .instructions = &code }};
    var packet = vm.Packet{ .schema = "suikoden-actor-programs/10", .programs = &programs };
    try packet.validate();
    for ([_][]const u8{ "suikoden-actor-programs/7", "suikoden-actor-programs/8", "suikoden-actor-programs/9" }) |schema| {
        packet.schema = schema;
        try std.testing.expectError(error.InvalidActorPrograms, packet.validate());
    }
    packet.schema = "suikoden-actor-programs/10";
    code[0].command.status.threshold_percent = 101;
    try std.testing.expectError(error.InvalidActorPrograms, packet.validate());
}

test "actor balloon and sleep require schema eleven while earlier status kinds retain schema ten" {
    var code = [_]vm.Instruction{ .{ .command = .{ .status = .{ .kind = .balloon, .threshold_percent = 30 } } }, .{ .halt = {} } };
    const programs = [_]vm.Program{.{ .id = "status", .instructions = &code }};
    var packet = vm.Packet{ .schema = "suikoden-actor-programs/11", .programs = &programs };
    for ([_]@FieldType(vm.Status, "kind"){ .balloon, .sleep }) |kind| {
        code[0].command.status.kind = kind;
        try packet.validate();
        packet.schema = "suikoden-actor-programs/10";
        try std.testing.expectError(error.InvalidActorPrograms, packet.validate());
        packet.schema = "suikoden-actor-programs/11";
    }
    packet.schema = "suikoden-actor-programs/10";
    code[0].command.status.kind = .poison;
    try packet.validate();
}

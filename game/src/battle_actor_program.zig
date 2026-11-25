//! Actor-script control flow. The battle host owns animation, physics and effects;
//! update animation before update(), then integrate movement and auxiliary effects.
const std = @import("std");

pub const Target = enum { self, owner };
pub const Mask = struct { target: Target, bits: u16 };
pub const Motion = struct { anchor: enum { absolute, self, owner, home }, updates: u16, offset: [3]i16, velocity_q12: [3]i32, kind: enum { jump, linear, snap } = .jump };
pub const Camera = struct { channel: enum { angles, translation, scale, focus }, anchor: enum { absolute, self, owner } = .absolute, updates: u16, value_q12: [3]i32 };
pub const Flags = struct { bits: u8, set: bool };
pub const Highlight = struct { target: Target, bits: u8, set: bool };
pub const Offsets = struct { anchor: enum { absolute, self, owner }, value: [2]i16, from_sprite: bool = false, immediate: bool = false };
pub const Child = struct { program: []const u8, resource: []const u8, animation: u16, owner: Target = .self, home: enum { spawn, parent_owner } = .spawn, draw_record: bool = false, offset: [3]i16 };
pub const PaletteCycle = struct { variants: [3]u8, updates: u16 };
pub const Effect = struct { id: []const u8, binding: enum { shared, self, owner } };
pub const Status = struct { kind: enum { poison, balloon, accuracy_reduced, sleep, rune_blocked }, threshold_percent: u8 };
pub const Command = union(enum) {
    animation: u16,
    color: [3]u8,
    palette_cycle: PaletteCycle,
    recovery: u8,
    status: Status,
    visible: bool,
    translucent: bool,
    motion: Motion,
    resume_motion: i16,
    signal_set: Mask,
    signal_clear: Mask,
    shared_value: i16,
    camera: Camera,
    child: Child,
    offsets: Offsets,
    record_flags: Flags,
    highlight: Highlight,
    release_actor: bool,
    hold_coordinator_dispatch: bool,
    tail_return: bool,
    sound: u16,
    effect: Effect,
    teardown: void,
    reset_draw: bool,
};
pub const Condition = union(enum) { animation_done: void, movement_done: void, signal_set: Mask, signal_clear: Mask, highlight_clear: Mask, shared_value: i16 };
pub const Instruction = union(enum) { command: Command, wait: Condition, delay: u16, halt: void };
pub const Program = struct { id: []const u8, instructions: []const Instruction };
pub const Packet = struct {
    schema: []const u8,
    programs: []const Program,
    pub fn validate(self: Packet) !void {
        const thirteenth = std.mem.eql(u8, self.schema, "suikoden-actor-programs/13");
        const twelfth = std.mem.eql(u8, self.schema, "suikoden-actor-programs/12") or thirteenth;
        const eleventh = twelfth or std.mem.eql(u8, self.schema, "suikoden-actor-programs/11");
        const tenth = eleventh or std.mem.eql(u8, self.schema, "suikoden-actor-programs/10");
        const ninth = tenth or std.mem.eql(u8, self.schema, "suikoden-actor-programs/9");
        const eighth = ninth or std.mem.eql(u8, self.schema, "suikoden-actor-programs/8");
        if ((!eighth and !std.mem.eql(u8, self.schema, "suikoden-actor-programs/7")) or self.programs.len == 0 or self.programs.len > 4096) return error.InvalidActorPrograms;
        for (self.programs, 0..) |program, i| {
            if (program.id.len == 0 or program.id.len > 128 or program.instructions.len == 0 or program.instructions.len > 512 or program.instructions[program.instructions.len - 1] != .halt) return error.InvalidActorPrograms;
            for (self.programs[0..i]) |other| if (std.mem.eql(u8, program.id, other.id)) return error.InvalidActorPrograms;
            for (program.instructions, 0..) |instruction, index| switch (instruction) {
                .halt => if (index + 1 != program.instructions.len) return error.InvalidActorPrograms,
                .delay => |updates| if (updates > 32767) return error.InvalidActorPrograms,
                .wait => |condition| if (condition == .highlight_clear and (!eighth or condition.highlight_clear.bits > 255)) return error.InvalidActorPrograms,
                .command => |command| switch (command) {
                    .color => if (!twelfth) return error.InvalidActorPrograms,
                    .hold_coordinator_dispatch, .tail_return => if (!thirteenth) return error.InvalidActorPrograms,
                    .status => |attempt| if (!tenth or attempt.threshold_percent > 100 or (!eleventh and (attempt.kind == .balloon or attempt.kind == .sleep))) return error.InvalidActorPrograms,
                    .resume_motion => if (!ninth) return error.InvalidActorPrograms,
                    .motion => |motion| if (motion.updates < (if (motion.kind != .jump) @as(u16, 1) else 2) or motion.updates > 1000 or (motion.kind == .snap and motion.updates != 1)) return error.InvalidActorPrograms,
                    .camera => |camera| if (camera.updates == 0 or camera.updates > 1000) return error.InvalidActorPrograms,
                    .recovery => |boundaries| if (boundaries == 0) return error.InvalidActorPrograms,
                    .palette_cycle => |cycle| {
                        if (cycle.updates == 0 or cycle.updates > 1000) return error.InvalidActorPrograms;
                        for (cycle.variants) |variant| if (variant >= 7) return error.InvalidActorPrograms;
                    },
                    .child => |child| {
                        if (child.resource.len == 0 or child.resource.len > 128) return error.InvalidActorPrograms;
                        if (self.find(child.program) == null) return error.MissingActorChildProgram;
                    },
                    .effect => |effect| if (effect.id.len == 0 or effect.id.len > 128) return error.InvalidActorPrograms,
                    else => {},
                },
            };
        }
    }
    pub fn find(self: Packet, id: []const u8) ?Program {
        for (self.programs) |program| if (std.mem.eql(u8, program.id, id)) return program;
        return null;
    }
};
pub fn load(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Packet) {
    if (bytes.len > 16 * 1024 * 1024) return error.InvalidActorPrograms;
    const parsed = try std.json.parseFromSlice(Packet, allocator, bytes, .{});
    errdefer parsed.deinit();
    try parsed.value.validate();
    return parsed;
}

pub const Host = struct {
    context: *anyopaque,
    // A blocking command is polled with resuming=true, without re-entering it.
    command: *const fn (*anyopaque, u16, Command, bool) anyerror!bool,
    ready: *const fn (*anyopaque, u16, Condition) anyerror!bool,
};
pub const Machine = struct {
    instructions: []const Instruction,
    actor: u16,
    pc: usize = 0,
    remaining: u16 = 0,
    resuming_command: bool = false,
    halted: bool = false,
    pub fn init(program: Program, actor: u16) Machine {
        return .{ .instructions = program.instructions, .actor = actor };
    }
    pub fn dispatch(self: *Machine, host: Host) !void {
        try self.pump(host);
    }
    pub fn update(self: *Machine, host: Host) !void {
        if (self.remaining != 0) {
            self.remaining -= 1;
            if (self.remaining != 0) return;
        }
        try self.pump(host);
    }
    fn pump(self: *Machine, host: Host) !void {
        if (self.halted or self.remaining != 0) return;
        var budget: usize = 512;
        while (budget != 0) : (budget -= 1) {
            if (self.pc >= self.instructions.len) return error.UnterminatedActorProgram;
            switch (self.instructions[self.pc]) {
                .halt => {
                    self.halted = true;
                    return;
                },
                .delay => |updates| {
                    self.pc += 1;
                    self.remaining = @max(1, updates);
                    return;
                },
                .wait => |condition| {
                    if (!try host.ready(host.context, self.actor, condition)) return;
                    self.pc += 1;
                },
                .command => |command| {
                    if (!try host.command(host.context, self.actor, command, self.resuming_command)) {
                        self.resuming_command = true;
                        return;
                    }
                    self.resuming_command = false;
                    self.pc += 1;
                },
            }
        }
        return error.ActorInstructionBudgetExceeded;
    }
};

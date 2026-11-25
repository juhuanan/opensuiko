//! Source battle camera blocks and the GTE projection law.
//! Angles are 12-bit turns; D scales the rotation, not the translation.
const std = @import("std");
pub const sin_cos = @import("battle_sin_cos.zig");

pub const Screen = struct { x: f32, y: f32, depth: f32 };
pub const Block = struct {
    position: [3]i32,
    angles: [3]i32,
    c: [3]i32,
    d: [3]i32,
};
pub const Q12Block = struct {
    position: [3]i32,
    angles: [3]i32,
    c: [3]i32,
    d: [3]i32,
    pub fn validate(self: Q12Block) !void {
        inline for (.{ "position", "angles", "c", "d" }) |field| for (@field(self, field)) |value| {
            if (@abs(@as(i64, value)) > 32767 * 4096) return error.InvalidActorCamera;
        };
    }
};

pub const ActorRequest = struct {
    at: u16,
    updates: u16,
    channel: enum { focus, angles, translation, scale },
    binding: enum { absolute, actor, target },
    target_q12: [3]i32,

    pub fn validate(self: ActorRequest) !void {
        if (self.at == 0 or self.at > 1000 or self.updates == 0 or self.updates > 1000) return error.InvalidActorCamera;
        if (self.channel != .focus and self.binding != .absolute) return error.InvalidActorCamera;
        if (self.binding != .absolute and self.target_q12[2] != 0) return error.InvalidActorCamera;
        for (self.target_q12) |value| {
            const limit: i64 = if (self.channel == .focus) 32768 else 32768 * 4096;
            if (value < -limit or value >= limit) return error.InvalidActorCamera;
        }
    }
};

pub const ActorController = struct {
    current: [4][3]i32,
    target: [4][3]i32,
    velocity: [4][3]i32 = @splat(@splat(0)),
    remaining: [4]u16 = @splat(0),

    pub fn init(initial: Block) !ActorController {
        var vectors: [4][3]i32 = undefined;
        inline for (.{ "position", "angles", "c", "d" }, 0..) |field, channel| {
            for (@field(initial, field), 0..) |value, axis| {
                if (value < -32768 or value > 32767) return error.InvalidActorCamera;
                vectors[channel][axis] = value * 4096;
            }
        }
        return .{ .current = vectors, .target = vectors };
    }

    pub fn request(self: *ActorController, event: ActorRequest, anchor_q12: [3]i32) !void {
        try event.validate();
        var destination = event.target_q12;
        if (event.binding != .absolute) for (0..2) |axis| {
            if (@abs(@as(i64, anchor_q12[axis])) > 32768 * 4096) return error.InvalidActorCamera;
            destination[axis] += anchor_q12[axis];
        };
        const channel = @backingInt(event.channel);
        self.target[channel] = destination;
        self.remaining[channel] = event.updates;
        for (0..3) |axis| self.velocity[channel][axis] = @divTrunc(destination[axis] - self.current[channel][axis], event.updates);
    }

    pub fn advance(self: *ActorController) void {
        for (0..4) |channel| {
            if (self.remaining[channel] > 0) {
                self.remaining[channel] -= 1;
                for (0..3) |axis| self.current[channel][axis] += self.velocity[channel][axis];
            } else self.current[channel] = self.target[channel];
        }
    }

    pub fn requestBlock(self: *ActorController, block_target: Block, updates: u16) !void {
        if (updates == 0 or updates > 4096) return error.InvalidActorCamera;
        const destination = try init(block_target);
        self.target = destination.target;
        self.remaining = @splat(updates);
        for (0..4) |channel| for (0..3) |axis| {
            self.velocity[channel][axis] = @divTrunc(self.target[channel][axis] - self.current[channel][axis], updates);
        };
    }

    pub fn requestQ12(self: *ActorController, block_target: Q12Block, updates: u16) !void {
        if (updates == 0 or updates > 1000) return error.InvalidActorCamera;
        try block_target.validate();
        inline for (.{ "position", "angles", "c", "d" }, 0..) |field, channel| self.target[channel] = @field(block_target, field);
        self.remaining = @splat(updates);
        for (0..4) |channel| for (0..3) |axis| {
            self.velocity[channel][axis] = @divTrunc(self.target[channel][axis] - self.current[channel][axis], updates);
        };
    }

    pub fn sample(self: ActorController) Block {
        var result: Block = undefined;
        inline for (.{ "position", "angles", "c", "d" }, 0..) |field, channel| {
            for (0..3) |axis| @field(result, field)[axis] = self.current[channel][axis] >> 12;
        }
        return result;
    }
};

pub const state0 = Block{
    .position = .{ 80, 0, 0 },
    .angles = .{ -768, 0, 608 },
    .c = .{ 0, 0, 1024 },
    .d = .{ 4864, 4864, 4864 },
};
pub const state1 = Block{
    .position = .{ 112, 0, 0 },
    .angles = .{ -768, 0, 608 },
    .c = .{ 0, 0, 1024 },
    .d = .{ 3840, 3840, 3840 },
};
/// The block installed by state 3 and held by state 4.
pub const state2 = Block{
    .position = .{ 112, 0, 0 },
    .angles = .{ -768, 0, 352 },
    .c = .{ 0, 0, 1024 },
    .d = .{ 3840, 3840, 3840 },
};

pub const attack_party = Block{ .position = .{ 80, 0, 0 }, .angles = .{ -768, 0, 608 }, .c = .{ 0, 0, 1024 }, .d = .{ 4864, 4864, 4864 } };
pub const attack_enemy = Block{ .position = .{ -80, 0, 0 }, .angles = .{ -768, 0, 608 }, .c = .{ 0, 0, 1024 }, .d = .{ 4864, 4864, 4864 } };
pub const effect_close = Block{ .position = .{ -160, 0, 0 }, .angles = .{ -768, 0, 352 }, .c = .{ 0, 0, 1024 }, .d = .{ 5120, 5120, 5120 } };

pub const round_cameras = [_]Block{
    .{ .position = .{ -32, 0, 0 }, .angles = .{ -704, 0, 640 }, .c = .{ 0, 0, 1024 }, .d = @splat(2816) },
    .{ .position = .{ 0, 0, 0 }, .angles = .{ -768, 0, 608 }, .c = .{ 0, 0, 1024 }, .d = @splat(4096) },
    .{ .position = .{ 0, 0, 0 }, .angles = .{ -864, 0, 800 }, .c = .{ 0, 0, 1024 }, .d = @splat(5376) },
};

pub fn block(state: usize) Block {
    return switch (state) {
        0 => state0,
        1 => state1,
        else => state2,
    };
}

/// `(D[0] << 10) / C[2]` in Q12: 4864 intro, 3840 settled.
pub fn scaleQ12(state: usize) i32 {
    const b = block(state);
    return @divTrunc(b.d[0] << 10, b.c[2]);
}

pub fn actorScale(state: usize) f32 {
    return @as(f32, @floatFromInt(scaleQ12(state))) / 4096.0;
}

fn sinCos(angle: i32) [2]i32 {
    if (angle >= 0) {
        const index = angle & 0xFFF;
        return table(@intCast(index));
    }
    const positive = table(@intCast((-angle) & 0xFFF));
    return .{ -positive[0], positive[1] };
}

fn table(index: u12) [2]i32 {
    const pair = sin_cos.table[index];
    return .{ pair[0], pair[1] };
}

pub fn rotationMatrix(angles: [3]i32) [9]i32 {
    const s0 = sinCos(angles[0]);
    const s1 = sinCos(angles[1]);
    const s2 = sinCos(angles[2]);
    const t3 = s0[0];
    const t0 = s0[1];
    const t6 = s1[0];
    const t1 = s1[1];
    const t4 = -t6;
    const t5 = s2[0];
    const t2 = s2[1];
    var m: [9]i32 = undefined;
    m[2] = t6;
    m[5] = (-(t1 * t3)) >> 12;
    m[8] = (t1 * t0) >> 12;
    m[0] = (t2 * t1) >> 12;
    m[1] = (-(t5 * t1)) >> 12;
    const t8 = (t2 * t4) >> 12;
    m[3] = ((t5 * t0) >> 12) - ((t8 * t3) >> 12);
    m[6] = ((t5 * t3) >> 12) + ((t8 * t0) >> 12);
    const t8b = (t5 * t4) >> 12;
    m[4] = ((t2 * t0) >> 12) + ((t8b * t3) >> 12);
    m[7] = ((t2 * t3) >> 12) - ((t8b * t0) >> 12);
    return m;
}

pub fn scaledRot(b: Block) [9]i32 {
    const m = rotationMatrix(b.angles);
    var result: [9]i32 = undefined;
    for (0..3) |i| {
        for (0..3) |j| result[i * 3 + j] = (m[i * 3 + j] * b.d[j]) >> 12;
    }
    return result;
}

pub const Scroll = struct { x: f32 = 0, y: f32 = 0 };

pub fn project(state: usize, position: [3]i32) ?Screen {
    return projectWithScroll(state, position, .{});
}

pub fn projectAt(ticks: u32, position: [3]i32) ?Screen {
    return projectBlock(sampleAt(ticks), position, .{});
}

/// Source screen space adds the accumulated scene scroll to the projection.
/// The shake producer is not exported, so runtime callers use the zero default.
pub fn projectWithScroll(state: usize, position: [3]i32, scroll: Scroll) ?Screen {
    return projectBlock(block(state), position, scroll);
}

pub fn projectBlock(b: Block, position: [3]i32, scroll: Scroll) ?Screen {
    const m = scaledRot(b);
    var view: [3]i32 = undefined;
    for (0..3) |i| {
        var sum: i64 = @as(i64, b.c[i]) << 12;
        for (0..3) |j| sum += @as(i64, m[i * 3 + j]) * position[j];
        view[i] = @intCast(sum >> 12);
    }
    if (view[2] <= 1) return null;
    return .{
        .x = 160.0 + 1024.0 * @as(f32, @floatFromInt(view[0])) / @as(f32, @floatFromInt(view[2])) + scroll.x,
        .y = 120.0 + 1024.0 * @as(f32, @floatFromInt(view[1])) / @as(f32, @floatFromInt(view[2])) + scroll.y,
        .depth = @floatFromInt(view[2]),
    };
}

pub fn rawProject(b: Block, p: [3]i32) [3]i32 {
    return rawProjectMatrix(scaledRot(b), b.c, p);
}

pub fn rawProjectMatrix(r: [9]i32, translation: [3]i32, p: [3]i32) [3]i32 {
    var view: [3]i32 = undefined;
    for (0..3) |i| {
        var sum: i64 = @as(i64, translation[i]) << 12;
        for (0..3) |j| sum += @as(i64, r[3 * i + j]) * p[j];
        view[i] = @intCast(sum >> 12);
    }
    const divisor: i64 = @max(512, view[2]);
    return .{ @intCast(std.math.clamp(@divFloor(@as(i64, view[0]) * 1024, divisor), -1024, 1023)), @intCast(std.math.clamp(@divFloor(@as(i64, view[1]) * 1024, divisor), -1024, 1023)), view[2] };
}
/// Per-frame focus compensation. RTPS writes projected zero before focus is subtracted.
pub fn focusOffset(b: Block) Scroll {
    const zero = rawProject(b, .{ 0, 0, 0 });
    const focus = rawProject(b, b.position);
    return .{ .x = @floatFromInt(zero[0] - focus[0]), .y = @floatFromInt(zero[1] - focus[1]) };
}
pub fn projectScene(b: Block, position: [3]i32, shake: Scroll) ?Screen {
    const p = rawProject(b, position);
    const offset = focusOffset(b);
    return .{ .x = @as(f32, @floatFromInt(p[0] + 160)) + offset.x + shake.x, .y = @as(f32, @floatFromInt(p[1] + 120)) + offset.y + shake.y, .depth = @floatFromInt(p[2]) };
}

pub fn mix(a: Block, b: Block, t: f32) Block {
    return blend(a, b, @min(@max(t, 0), 1));
}

fn blend(a: Block, b: Block, t: f32) Block {
    var result: Block = undefined;
    for (0..3) |i| {
        result.position[i] = @intFromFloat(@round(@as(f32, @floatFromInt(a.position[i])) * (1 - t) + @as(f32, @floatFromInt(b.position[i])) * t));
        result.angles[i] = @intFromFloat(@round(@as(f32, @floatFromInt(a.angles[i])) * (1 - t) + @as(f32, @floatFromInt(b.angles[i])) * t));
        result.c[i] = @intFromFloat(@round(@as(f32, @floatFromInt(a.c[i])) * (1 - t) + @as(f32, @floatFromInt(b.c[i])) * t));
        result.d[i] = @intFromFloat(@round(@as(f32, @floatFromInt(a.d[i])) * (1 - t) + @as(f32, @floatFromInt(b.d[i])) * t));
    }
    return result;
}

/// Camera block after the source setter's frame interpolation.
pub fn sampleAt(ticks: u32) Block {
    if (ticks < Timeline.state0_frames) return state0;
    if (ticks < Timeline.state0_frames + 60) {
        const t = @as(f32, @floatFromInt(ticks - Timeline.state0_frames)) / 60.0;
        return blend(state0, state1, t);
    }
    if (ticks < Timeline.state0_frames + Timeline.state1_frames + Timeline.state2_frames) return state1;
    if (ticks < Timeline.state0_frames + Timeline.state1_frames + Timeline.state2_frames + 80) {
        const t = @as(f32, @floatFromInt(ticks - 176)) / 80.0;
        return blend(state1, state2, t);
    }
    return state2;
}

pub fn scaleBlock(b: Block) f32 {
    return @as(f32, @floatFromInt(@divTrunc(b.d[0] << 10, b.c[2]))) / 4096.0;
}

pub fn scaleAt(ticks: u32) f32 {
    const b = sampleAt(ticks);
    return @as(f32, @floatFromInt(@divTrunc(b.d[0] << 10, b.c[2]))) / 4096.0;
}

/// Standard-battle framing observed in the reference: intro zoom into block 1,
/// then hold. The state machine's later block-2 install is not yet tied to a
/// trigger seen in a normal fight.
pub fn sampleAtStandard(ticks: u32) Block {
    if (ticks < Timeline.state0_frames) return state0;
    if (ticks < Timeline.state0_frames + 60) {
        const t = @as(f32, @floatFromInt(ticks - Timeline.state0_frames)) / 60.0;
        return blend(state0, state1, t);
    }
    return state1;
}

pub fn scaleAtStandard(ticks: u32) f32 {
    const b = sampleAtStandard(ticks);
    return @as(f32, @floatFromInt(@divTrunc(b.d[0] << 10, b.c[2]))) / 4096.0;
}

pub fn projectStandard(ticks: u32, position: [3]i32) ?Screen {
    return projectBlock(sampleAtStandard(ticks), position, .{});
}

pub const Timeline = struct {
    pub const state0_frames: u32 = 64;
    pub const state1_frames: u32 = 32;
    pub const state2_frames: u32 = 80;
    pub const state3_frames: u32 = 60;

    /// Camera state installed by the battle state machine at a battle tick.
    pub fn stateAt(ticks: u32) usize {
        if (ticks < state0_frames) return 0;
        if (ticks < state0_frames + state1_frames) return 1;
        if (ticks < state0_frames + state1_frames + state2_frames) return 2;
        if (ticks < state0_frames + state1_frames + state2_frames + state3_frames) return 3;
        return 4;
    }

    /// State 2 installs no camera; state 3 installs block 2; state 4 holds it.
    pub fn blockAt(ticks: u32) usize {
        return switch (stateAt(ticks)) {
            0 => 0,
            1, 2 => 1,
            else => 2,
        };
    }
};

/// One global camera channel from the actor VM (opcodes 17-20).
pub const Channel = struct {
    current: [3]i32 = .{ 0, 0, 0 },
    target: [3]i32 = .{ 0, 0, 0 },
    delta: [3]i32 = .{ 0, 0, 0 },
    duration: u16 = 0,

    pub fn moveTo(self: *Channel, target: [3]i32, frames: u16) void {
        self.target = target;
        self.duration = frames;
        if (frames == 0) {
            self.current = target;
            self.delta = .{ 0, 0, 0 };
            return;
        }
        for (0..3) |i| self.delta[i] = @divTrunc(target[i] - self.current[i], frames);
    }

    pub fn tick(self: *Channel) void {
        if (self.duration == 0) {
            self.current = self.target;
            return;
        }
        self.duration -= 1;
        for (0..3) |i| self.current[i] += self.delta[i];
        if (self.duration == 0) self.current = self.target;
    }
};

pub const default_channels = Channels{
    .a = .{ .current = .{ -768 << 12, 0, 640 << 12 }, .target = .{ -768 << 12, 0, 640 << 12 } },
    .b = .{ .current = .{ 0, 0, 1024 << 12 }, .target = .{ 0, 0, 1024 << 12 } },
    .c = .{ .current = .{ 0, 0, 0 }, .target = .{ 0, 0, 0 } },
    .d = .{ .current = .{ 4096 << 12, 4096 << 12, 4096 << 12 }, .target = .{ 4096 << 12, 4096 << 12, 4096 << 12 } },
};

pub const Channels = struct {
    a: Channel = .{},
    b: Channel = .{},
    c: Channel = .{},
    d: Channel = .{},

    pub fn block(self: Channels) Block {
        var result: Block = .{
            .position = .{ 0, 0, 0 },
            .angles = .{ 0, 0, 0 },
            .c = .{ 0, 0, 1024 },
            .d = .{ 4096, 4096, 4096 },
        };
        for (0..3) |i| {
            result.position[i] = @divTrunc(self.c.current[i], 4096);
            result.angles[i] = @divTrunc(self.a.current[i], 4096);
            result.c[i] = @divTrunc(self.b.current[i], 4096);
            result.d[i] = @divTrunc(self.d.current[i], 4096);
        }
        return result;
    }

    pub fn tick(self: *Channels) void {
        self.a.tick();
        self.b.tick();
        self.c.tick();
        self.d.tick();
    }
};

/// Every static camera block resolved from the 104 call sites.
pub const Preset = struct { address: u32, block: Block };
pub const presets = [_]Preset{
    .{ .address = 0x8016B7DC, .block = .{ .position = .{ 0, 0, 0 }, .angles = .{ -768, 0, 640 }, .c = .{ 0, 0, 1024 }, .d = .{ 4096, 4096, 4096 } } },
    .{ .address = 0x8016B848, .block = .{ .position = .{ 0, 0, 0 }, .angles = .{ 0, 0, 0 }, .c = .{ 80, 60, 1024 }, .d = .{ 4096, 4096, 4096 } } },
    .{ .address = 0x8016B878, .block = .{ .position = .{ 0, 0, 0 }, .angles = .{ -768, 0, 608 }, .c = .{ 0, 0, 1024 }, .d = .{ 4096, 4096, 4096 } } },
    .{ .address = 0x8016C7E4, .block = .{ .position = .{ 0, 0, 0 }, .angles = .{ -864, 0, 512 }, .c = .{ 0, 0, 1024 }, .d = .{ 10000, 10000, 10000 } } },
    .{ .address = 0x8016C9DC, .block = .{ .position = .{ 0, 0, 0 }, .angles = .{ -832, 0, 512 }, .c = .{ 0, 0, 1024 }, .d = .{ 4096, 4096, 4096 } } },
    .{ .address = 0x8016CC1C, .block = .{ .position = .{ -160, 0, 0 }, .angles = .{ -768, 0, 352 }, .c = .{ 0, 0, 1024 }, .d = .{ 5120, 5120, 5120 } } },
    .{ .address = 0x8016D2A0, .block = .{ .position = .{ 0, 0, 0 }, .angles = .{ -768, 0, 448 }, .c = .{ 0, 0, 1024 }, .d = .{ 3840, 3840, 3840 } } },
    .{ .address = 0x8016D3DC, .block = .{ .position = .{ 80, 0, 0 }, .angles = .{ -768, 0, 608 }, .c = .{ 0, 0, 1024 }, .d = .{ 4864, 4864, 4864 } } },
    .{ .address = 0x8016D4FC, .block = .{ .position = .{ -80, 0, 0 }, .angles = .{ -768, 0, 608 }, .c = .{ 0, 0, 1024 }, .d = .{ 4864, 4864, 4864 } } },
    .{ .address = 0x8016D52C, .block = .{ .position = .{ -160, 0, 0 }, .angles = .{ -768, 0, 352 }, .c = .{ 0, 0, 1024 }, .d = .{ 5120, 5120, 5120 } } },
    .{ .address = 0x8016D55C, .block = .{ .position = .{ -160, 0, 0 }, .angles = .{ -768, 0, 608 }, .c = .{ 0, 0, 1024 }, .d = .{ 5120, 5120, 5120 } } },
    .{ .address = 0x8016D58C, .block = .{ .position = .{ -160, 0, 0 }, .angles = .{ -768, 0, 352 }, .c = .{ 0, 0, 1024 }, .d = .{ 3840, 3840, 3840 } } },
    .{ .address = 0x8016D5BC, .block = .{ .position = .{ -160, 0, 0 }, .angles = .{ -704, 0, 352 }, .c = .{ 0, 0, 1024 }, .d = .{ 4096, 4096, 4096 } } },
    .{ .address = 0x8016D5EC, .block = .{ .position = .{ -160, 0, 0 }, .angles = .{ -704, 0, 608 }, .c = .{ 0, 0, 1024 }, .d = .{ 4096, 4096, 4096 } } },
    .{ .address = 0x8016D6BC, .block = .{ .position = .{ 80, 0, 0 }, .angles = .{ -768, 0, 608 }, .c = .{ 0, 0, 1024 }, .d = .{ 4864, 4864, 4864 } } },
    .{ .address = 0x8016D71C, .block = .{ .position = .{ 112, 0, 0 }, .angles = .{ -768, 0, 608 }, .c = .{ 0, 0, 1024 }, .d = .{ 5888, 5888, 5888 } } },
    .{ .address = 0x8016D74C, .block = .{ .position = .{ 112, 0, 0 }, .angles = .{ -768, 0, 352 }, .c = .{ 0, 0, 1024 }, .d = .{ 5888, 5888, 5888 } } },
    .{ .address = 0x8016D77C, .block = .{ .position = .{ 112, 0, 0 }, .angles = .{ -768, 0, 608 }, .c = .{ 0, 0, 1024 }, .d = .{ 3840, 3840, 3840 } } },
    .{ .address = 0x8016D7AC, .block = .{ .position = .{ 112, 0, 0 }, .angles = .{ -768, 0, 352 }, .c = .{ 0, 0, 1024 }, .d = .{ 3840, 3840, 3840 } } },
    .{ .address = 0x8016D7DC, .block = .{ .position = .{ -80, 0, 0 }, .angles = .{ -768, 0, 608 }, .c = .{ 0, 0, 1024 }, .d = .{ 4864, 4864, 4864 } } },
    .{ .address = 0x8016D80C, .block = .{ .position = .{ -160, 0, 0 }, .angles = .{ -768, 0, 352 }, .c = .{ 0, 0, 1024 }, .d = .{ 5120, 5120, 5120 } } },
    .{ .address = 0x8016D97C, .block = .{ .position = .{ 80, 0, 0 }, .angles = .{ -768, 0, 608 }, .c = .{ 0, 0, 1024 }, .d = .{ 4864, 4864, 4864 } } },
    .{ .address = 0x8016DA3C, .block = .{ .position = .{ 112, 0, 0 }, .angles = .{ -768, 0, 608 }, .c = .{ 0, 0, 1024 }, .d = .{ 3840, 3840, 3840 } } },
    .{ .address = 0x8016DA6C, .block = .{ .position = .{ 112, 0, 0 }, .angles = .{ -768, 0, 352 }, .c = .{ 0, 0, 1024 }, .d = .{ 3840, 3840, 3840 } } },
    .{ .address = 0x8016DACC, .block = .{ .position = .{ -160, 0, 0 }, .angles = .{ -768, 0, 352 }, .c = .{ 0, 0, 1024 }, .d = .{ 5120, 5120, 5120 } } },
    .{ .address = 0x8016DC5C, .block = .{ .position = .{ 80, 0, 0 }, .angles = .{ -768, 0, 608 }, .c = .{ 0, 0, 1024 }, .d = .{ 4864, 4864, 4864 } } },
    .{ .address = 0x8016DC8C, .block = .{ .position = .{ 0, 0, 0 }, .angles = .{ -768, 0, 640 }, .c = .{ 0, 0, 1024 }, .d = .{ 3840, 3840, 3840 } } },
    .{ .address = 0x8016DCBC, .block = .{ .position = .{ 112, 0, 0 }, .angles = .{ -768, 0, 608 }, .c = .{ 0, 0, 1024 }, .d = .{ 5888, 5888, 5888 } } },
    .{ .address = 0x8016DD7C, .block = .{ .position = .{ -80, 0, 0 }, .angles = .{ -768, 0, 608 }, .c = .{ 0, 0, 1024 }, .d = .{ 4864, 4864, 4864 } } },
    .{ .address = 0x8016DDAC, .block = .{ .position = .{ -160, 0, 0 }, .angles = .{ -768, 0, 352 }, .c = .{ 0, 0, 1024 }, .d = .{ 5120, 5120, 5120 } } },
    .{ .address = 0x8016DF80, .block = .{ .position = .{ 80, 0, 0 }, .angles = .{ -768, 0, 608 }, .c = .{ 0, 0, 1024 }, .d = .{ 4864, 4864, 4864 } } },
    .{ .address = 0x8016E0D0, .block = .{ .position = .{ -160, 0, 0 }, .angles = .{ -768, 0, 352 }, .c = .{ 0, 0, 1024 }, .d = .{ 5120, 5120, 5120 } } },
    .{ .address = 0x8016E160, .block = .{ .position = .{ -160, 0, 0 }, .angles = .{ -704, 0, 352 }, .c = .{ 0, 0, 1024 }, .d = .{ 4096, 4096, 4096 } } },
    .{ .address = 0x8016E190, .block = .{ .position = .{ -160, 0, 0 }, .angles = .{ -704, 0, 608 }, .c = .{ 0, 0, 1024 }, .d = .{ 4096, 4096, 4096 } } },
    .{ .address = 0x8016E260, .block = .{ .position = .{ 80, 0, 0 }, .angles = .{ -768, 0, 608 }, .c = .{ 0, 0, 1024 }, .d = .{ 4864, 4864, 4864 } } },
    .{ .address = 0x8016E2C0, .block = .{ .position = .{ 112, 0, 0 }, .angles = .{ -768, 0, 608 }, .c = .{ 0, 0, 1024 }, .d = .{ 5888, 5888, 5888 } } },
    .{ .address = 0x8016E2F0, .block = .{ .position = .{ 112, 0, 0 }, .angles = .{ -768, 0, 352 }, .c = .{ 0, 0, 1024 }, .d = .{ 5888, 5888, 5888 } } },
    .{ .address = 0x8016E320, .block = .{ .position = .{ 112, 0, 0 }, .angles = .{ -768, 0, 608 }, .c = .{ 0, 0, 1024 }, .d = .{ 3840, 3840, 3840 } } },
    .{ .address = 0x8016E350, .block = .{ .position = .{ 112, 0, 0 }, .angles = .{ -768, 0, 352 }, .c = .{ 0, 0, 1024 }, .d = .{ 3840, 3840, 3840 } } },
    .{ .address = 0x8016E410, .block = .{ .position = .{ -160, 0, 0 }, .angles = .{ -768, 0, 352 }, .c = .{ 0, 0, 1024 }, .d = .{ 3840, 3840, 3840 } } },
    .{ .address = 0x8016E440, .block = .{ .position = .{ -160, 0, 0 }, .angles = .{ -704, 0, 352 }, .c = .{ 0, 0, 1024 }, .d = .{ 4096, 4096, 4096 } } },
    .{ .address = 0x8016E5D0, .block = .{ .position = .{ 80, 0, 0 }, .angles = .{ -768, 0, 608 }, .c = .{ 0, 0, 1024 }, .d = .{ 4864, 4864, 4864 } } },
    .{ .address = 0x8016E810, .block = .{ .position = .{ 0, 0, 0 }, .angles = .{ -864, 0, 608 }, .c = .{ 0, 0, 1024 }, .d = .{ 4096, 4096, 4096 } } },
    .{ .address = 0x8016E840, .block = .{ .position = .{ -128, 0, 0 }, .angles = .{ -736, 0, 128 }, .c = .{ 0, 0, 1024 }, .d = .{ 2304, 2304, 2304 } } },
    .{ .address = 0x8016E870, .block = .{ .position = .{ -128, 0, 0 }, .angles = .{ -320, 0, 128 }, .c = .{ 0, 0, 1024 }, .d = .{ 2304, 2304, 2304 } } },
    .{ .address = 0x8016E950, .block = .{ .position = .{ 0, 0, 0 }, .angles = .{ -768, 0, 640 }, .c = .{ 0, 0, 1024 }, .d = .{ 3840, 3840, 3840 } } },
    .{ .address = 0x8016EA70, .block = .{ .position = .{ -160, 0, 0 }, .angles = .{ -768, 0, 352 }, .c = .{ 0, 0, 1024 }, .d = .{ 5120, 5120, 5120 } } },
    .{ .address = 0x8016EB00, .block = .{ .position = .{ -160, 0, 0 }, .angles = .{ -704, 0, 352 }, .c = .{ 0, 0, 1024 }, .d = .{ 4096, 4096, 4096 } } },
    .{ .address = 0x8016EB30, .block = .{ .position = .{ -160, 0, 0 }, .angles = .{ -704, 0, 608 }, .c = .{ 0, 0, 1024 }, .d = .{ 4096, 4096, 4096 } } },
};

pub fn preset(address: u32) ?Block {
    for (presets) |entry| if (entry.address == address) return entry.block;
    return null;
}

/// Apply one character-script camera opcode (17-20) to the channels.
/// `origin` is the actor or owner world position used by op 20 modes 1/2.
pub fn applyOp(channels: *Channels, op: u16, args: []const i16, origin: [3]i32) void {
    if (args.len < 4) return;
    const frames: u16 = @intCast(@max(args[0], 0));
    switch (op) {
        17 => channels.a.moveTo(.{ @as(i32, args[1]) << 12, @as(i32, args[2]) << 12, @as(i32, args[3]) << 12 }, frames),
        18 => channels.b.moveTo(.{ @as(i32, args[1]) << 12, @as(i32, args[2]) << 12, @as(i32, args[3]) << 12 }, frames),
        19 => channels.d.moveTo(.{ @as(i32, args[1]) << 12, @as(i32, args[2]) << 12, @as(i32, args[3]) << 12 }, frames),
        20 => {
            if (args.len < 5) return;
            const mode = args[0];
            const target: [3]i32 = if (mode == 0)
                .{ @as(i32, args[2]) << 12, @as(i32, args[3]) << 12, @as(i32, args[4]) << 12 }
            else
                .{ origin[0] + (@as(i32, args[2]) << 12), origin[1] + (@as(i32, args[3]) << 12), @as(i32, args[4]) << 12 };
            channels.c.moveTo(target, @intCast(@max(args[1], 0)));
        },
        else => {},
    }
}

pub const Family = enum { party_close, enemy_close, effect_close, wide_default, special_zoom, enemy_wide, other };

pub fn family(b: Block) Family {
    if (b.position[0] == 80 and b.d[0] == 4864) return .party_close;
    if (b.position[0] == -80 and b.d[0] == 4864) return .enemy_close;
    if (b.position[0] == -160 and b.angles[2] == 352 and b.d[0] == 5120) return .effect_close;
    if (b.angles[2] == 640) return .wide_default;
    if (b.d[0] >= 5888) return .special_zoom;
    if (b.position[0] < 0) return .enemy_wide;
    return .other;
}

pub fn presetForFamily(f: Family) Block {
    return switch (f) {
        .party_close => preset(0x8016D3DC).?,
        .enemy_close => preset(0x8016D4FC).?,
        .effect_close => preset(0x8016CC1C).?,
        .wide_default => preset(0x8016B7DC).?,
        .special_zoom => preset(0x8016E2C0).?,
        .enemy_wide => preset(0x8016E160).?,
        .other => preset(0x8016D2A0).?,
    };
}

pub const CastPreset = struct { name: []const u8, address: u32 };

/// Last camera block installed by the source spell action, where known.
pub const cast_presets = [_]CastPreset{
    .{ .name = "Flaming Arrows", .address = 0x8016D4FC },
    .{ .name = "Firestorm", .address = 0x8016D55C },
    .{ .name = "Dancing Flames", .address = 0x8016D5EC },
    .{ .name = "Explosion", .address = 0x8016D58C },
    .{ .name = "Scolding", .address = 0x8016D7DC },
    .{ .name = "Yell", .address = 0x8016D74C },
    .{ .name = "Scream", .address = 0x8016D7AC },
    .{ .name = "Charm Arrow", .address = 0x8016D80C },
    .{ .name = "Drops of Kindness", .address = 0x8016D97C },
    .{ .name = "Fog of Deception", .address = 0x8016DACC },
    .{ .name = "Water of Kindness", .address = 0x8016DA6C },
    .{ .name = "Rain of Kindness", .address = 0x8016DA6C },
    .{ .name = "Mother Ocean", .address = 0x8016DA6C },
    .{ .name = "Wind of Sleep", .address = 0x8016DDAC },
    .{ .name = "The Shredding", .address = 0x8016DC8C },
    .{ .name = "Healing Wind", .address = 0x8016DCBC },
    .{ .name = "Shining Wind", .address = 0x8016DC8C },
    .{ .name = "Angry Blow", .address = 0x8016E0D0 },
    .{ .name = "Rainstorm", .address = 0x8016E190 },
    .{ .name = "Ball of Lightning", .address = 0x8016E160 },
    .{ .name = "Clay Guardian", .address = 0x8016E2C0 },
    .{ .name = "Copper Flesh", .address = 0x8016E2F0 },
    .{ .name = "Earthquake", .address = 0x8016E440 },
    .{ .name = "Voice of Earth", .address = 0x8016E410 },
    .{ .name = "Deadly Fingertips", .address = 0x8016E810 },
    .{ .name = "Black Shadow", .address = 0x8016E810 },
    .{ .name = "Hell", .address = 0x8016E870 },
    .{ .name = "Judgment", .address = 0x8016EB30 },
};

pub fn castPreset(name: []const u8) ?Block {
    for (cast_presets) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return preset(entry.address);
    }
    return null;
}

/// Interpreted camera matrix in presentation form: rotation/scale plus translation.
pub fn transform(b: Block) [3][4]f32 {
    const r = rotationMatrix(b.angles);
    var out: [3][4]f32 = undefined;
    for (0..3) |i| {
        for (0..3) |j| out[i][j] = @as(f32, @floatFromInt(r[i * 3 + j] * b.d[j])) / (4096.0 * 4096.0);
        out[i][3] = @floatFromInt(b.c[i]);
    }
    return out;
}

//! Battle camera poses and integer GTE projection.
//! Angles are 12-bit turns; scale scales the rotation matrix, not translation.
const std = @import("std");
pub const sin_cos = @import("battle_sin_cos_data");

pub const Screen = struct { x: f32, y: f32, depth: f32 };
pub const Vec3 = [3]i32;

pub const FixedQ12 = struct {
    raw: i32,

    pub const one: i32 = 4096;

    pub fn fromInt(value: i32) FixedQ12 {
        return .{ .raw = value << 12 };
    }

    pub fn toInt(self: FixedQ12) i32 {
        return self.raw >> 12;
    }

    pub fn toFloat(self: FixedQ12) f32 {
        return @as(f32, @floatFromInt(self.raw)) / 4096.0;
    }
};

const WireBlock = struct {
    position: Vec3,
    angles: Vec3,
    c: Vec3,
    d: Vec3,
};

pub const Block = struct {
    focus: Vec3,
    angles: Vec3,
    translation: Vec3,
    scale: Vec3,

    pub fn jsonStringify(self: Block, writer: anytype) !void {
        try writer.write(WireBlock{
            .position = self.focus,
            .angles = self.angles,
            .c = self.translation,
            .d = self.scale,
        });
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Block {
        const wire = try std.json.innerParse(WireBlock, allocator, source, options);
        return .{ .focus = wire.position, .angles = wire.angles, .translation = wire.c, .scale = wire.d };
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Block {
        const wire = try std.json.innerParseFromValue(WireBlock, allocator, source, options);
        return .{ .focus = wire.position, .angles = wire.angles, .translation = wire.c, .scale = wire.d };
    }
};

pub const CameraPose = Block;

pub const Q12Block = struct {
    focus: Vec3,
    angles: Vec3,
    translation: Vec3,
    scale: Vec3,

    pub fn validate(self: Q12Block) !void {
        inline for (.{ "focus", "angles", "translation", "scale" }) |field| for (@field(self, field)) |value| {
            if (@abs(@as(i64, value)) > 32767 * FixedQ12.one) return error.InvalidActorCamera;
        };
    }

    pub fn jsonStringify(self: Q12Block, writer: anytype) !void {
        try writer.write(WireBlock{
            .position = self.focus,
            .angles = self.angles,
            .c = self.translation,
            .d = self.scale,
        });
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Q12Block {
        const wire = try std.json.innerParse(WireBlock, allocator, source, options);
        return .{ .focus = wire.position, .angles = wire.angles, .translation = wire.c, .scale = wire.d };
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Q12Block {
        const wire = try std.json.innerParseFromValue(WireBlock, allocator, source, options);
        return .{ .focus = wire.position, .angles = wire.angles, .translation = wire.c, .scale = wire.d };
    }
};

pub const Q12Pose = Q12Block;

pub const ActorRequest = struct {
    at: u16,
    updates: u16,
    channel: enum { focus, angles, translation, scale },
    binding: enum { absolute, actor, target },
    target_q12: Vec3,

    pub fn validate(self: ActorRequest) !void {
        if (self.at == 0 or self.at > 1000 or self.updates == 0 or self.updates > 1000) return error.InvalidActorCamera;
        if (self.channel != .focus and self.binding != .absolute) return error.InvalidActorCamera;
        if (self.binding != .absolute and self.target_q12[2] != 0) return error.InvalidActorCamera;
        for (self.target_q12) |value| {
            const limit: i64 = if (self.channel == .focus) 32768 else 32768 * FixedQ12.one;
            if (value < -limit or value >= limit) return error.InvalidActorCamera;
        }
    }
};

pub const ActorController = struct {
    current: [4]Vec3,
    target: [4]Vec3,
    velocity: [4]Vec3 = @splat(@splat(0)),
    remaining: [4]u16 = @splat(0),

    pub fn init(initial: Block) !ActorController {
        var vectors: [4]Vec3 = undefined;
        inline for (.{ "focus", "angles", "translation", "scale" }, 0..) |field, channel| {
            for (@field(initial, field), 0..) |value, axis| {
                if (value < -32768 or value > 32767) return error.InvalidActorCamera;
                vectors[channel][axis] = value * FixedQ12.one;
            }
        }
        return .{ .current = vectors, .target = vectors };
    }

    pub fn request(self: *ActorController, event: ActorRequest, anchor_q12: Vec3) !void {
        try event.validate();
        var destination = event.target_q12;
        if (event.binding != .absolute) for (0..2) |axis| {
            if (@abs(@as(i64, anchor_q12[axis])) > 32768 * FixedQ12.one) return error.InvalidActorCamera;
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
        inline for (.{ "focus", "angles", "translation", "scale" }, 0..) |field, channel| self.target[channel] = @field(block_target, field);
        self.remaining = @splat(updates);
        for (0..4) |channel| for (0..3) |axis| {
            self.velocity[channel][axis] = @divTrunc(self.target[channel][axis] - self.current[channel][axis], updates);
        };
    }

    pub fn sample(self: ActorController) Block {
        var result: Block = undefined;
        inline for (.{ "focus", "angles", "translation", "scale" }, 0..) |field, channel| {
            for (0..3) |axis| @field(result, field)[axis] = self.current[channel][axis] >> 12;
        }
        return result;
    }
};

pub const intro_wide = Block{
    .focus = .{ 80, 0, 0 },
    .angles = .{ -768, 0, 608 },
    .translation = .{ 0, 0, 1024 },
    .scale = .{ 4864, 4864, 4864 },
};
pub const standard_battle = Block{
    .focus = .{ 112, 0, 0 },
    .angles = .{ -768, 0, 608 },
    .translation = .{ 0, 0, 1024 },
    .scale = .{ 3840, 3840, 3840 },
};
pub const settled_pan = Block{
    .focus = .{ 112, 0, 0 },
    .angles = .{ -768, 0, 352 },
    .translation = .{ 0, 0, 1024 },
    .scale = .{ 3840, 3840, 3840 },
};

pub const attack_party = Block{ .focus = .{ 80, 0, 0 }, .angles = .{ -768, 0, 608 }, .translation = .{ 0, 0, 1024 }, .scale = .{ 4864, 4864, 4864 } };
pub const attack_enemy = Block{ .focus = .{ -80, 0, 0 }, .angles = .{ -768, 0, 608 }, .translation = .{ 0, 0, 1024 }, .scale = .{ 4864, 4864, 4864 } };
pub const effect_close = Block{ .focus = .{ -160, 0, 0 }, .angles = .{ -768, 0, 352 }, .translation = .{ 0, 0, 1024 }, .scale = .{ 5120, 5120, 5120 } };
pub const wide_default = Block{ .focus = .{ 0, 0, 0 }, .angles = .{ -768, 0, 640 }, .translation = .{ 0, 0, 1024 }, .scale = .{ 4096, 4096, 4096 } };
pub const special_zoom = Block{ .focus = .{ 112, 0, 0 }, .angles = .{ -768, 0, 608 }, .translation = .{ 0, 0, 1024 }, .scale = .{ 5888, 5888, 5888 } };
pub const enemy_wide = Block{ .focus = .{ -160, 0, 0 }, .angles = .{ -704, 0, 352 }, .translation = .{ 0, 0, 1024 }, .scale = .{ 4096, 4096, 4096 } };
pub const other_default = Block{ .focus = .{ 0, 0, 0 }, .angles = .{ -768, 0, 448 }, .translation = .{ 0, 0, 1024 }, .scale = .{ 3840, 3840, 3840 } };

pub const round_cameras = [_]Block{
    .{ .focus = .{ -32, 0, 0 }, .angles = .{ -704, 0, 640 }, .translation = .{ 0, 0, 1024 }, .scale = @splat(2816) },
    .{ .focus = .{ 0, 0, 0 }, .angles = .{ -768, 0, 608 }, .translation = .{ 0, 0, 1024 }, .scale = @splat(4096) },
    .{ .focus = .{ 0, 0, 0 }, .angles = .{ -864, 0, 800 }, .translation = .{ 0, 0, 1024 }, .scale = @splat(5376) },
};

pub fn block(state: usize) Block {
    return switch (state) {
        0 => intro_wide,
        1 => standard_battle,
        else => settled_pan,
    };
}

/// `(scale[0] << 10) / translation[2]` in Q12: 4864 intro, 3840 settled.
pub fn scaleQ12(state: usize) i32 {
    const b = block(state);
    return @divTrunc(b.scale[0] << 10, b.translation[2]);
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

pub fn rotationMatrix(angles: Vec3) [9]i32 {
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
        for (0..3) |j| result[i * 3 + j] = (m[i * 3 + j] * b.scale[j]) >> 12;
    }
    return result;
}

pub const Scroll = struct { x: f32 = 0, y: f32 = 0 };

pub fn project(state: usize, position: Vec3) ?Screen {
    return projectWithScroll(state, position, .{});
}

pub fn projectAt(ticks: u32, position: Vec3) ?Screen {
    return projectBlock(sampleAt(ticks), position, .{});
}

/// Source screen space adds the accumulated scene scroll to the projection.
/// The shake producer is not exported, so runtime callers use the zero default.
pub fn projectWithScroll(state: usize, position: Vec3, scroll: Scroll) ?Screen {
    return projectBlock(block(state), position, scroll);
}

pub fn projectBlock(b: Block, position: Vec3, scroll: Scroll) ?Screen {
    const m = scaledRot(b);
    var view: Vec3 = undefined;
    for (0..3) |i| {
        var sum: i64 = @as(i64, b.translation[i]) << 12;
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

pub fn rawProject(b: Block, p: Vec3) Vec3 {
    return rawProjectMatrix(scaledRot(b), b.translation, p);
}

pub fn rawProjectMatrix(r: [9]i32, translation: Vec3, p: Vec3) Vec3 {
    var view: Vec3 = undefined;
    for (0..3) |i| {
        var sum: i64 = @as(i64, translation[i]) << 12;
        for (0..3) |j| sum += @as(i64, r[3 * i + j]) * p[j];
        view[i] = @intCast(sum >> 12);
    }
    const divisor: i64 = @max(512, view[2]);
    return .{
        @intCast(std.math.clamp(@divFloor(@as(i64, view[0]) * 1024, divisor), -1024, 1023)),
        @intCast(std.math.clamp(@divFloor(@as(i64, view[1]) * 1024, divisor), -1024, 1023)),
        view[2],
    };
}

/// Per-frame focus compensation. RTPS writes projected zero before focus is subtracted.
pub fn focusOffset(b: Block) Scroll {
    const zero = rawProject(b, .{ 0, 0, 0 });
    const focus = rawProject(b, b.focus);
    return .{ .x = @floatFromInt(zero[0] - focus[0]), .y = @floatFromInt(zero[1] - focus[1]) };
}

pub fn projectScene(b: Block, position: Vec3, shake: Scroll) ?Screen {
    const p = rawProject(b, position);
    const offset = focusOffset(b);
    return .{
        .x = @as(f32, @floatFromInt(p[0] + 160)) + offset.x + shake.x,
        .y = @as(f32, @floatFromInt(p[1] + 120)) + offset.y + shake.y,
        .depth = @floatFromInt(p[2]),
    };
}

pub fn mix(a: Block, b: Block, t: f32) Block {
    return blend(a, b, @min(@max(t, 0), 1));
}

pub fn actionEnvelope(tick: u32, duration: u32, ease_in: u32, ease_out: u32) f32 {
    if (tick >= duration) return 0;
    const in_ticks: f32 = @floatFromInt(ease_in);
    const out_ticks: f32 = @floatFromInt(ease_out);
    const duration_ticks: f32 = @floatFromInt(duration);
    const scale = @min(1, duration_ticks / @max(1, in_ticks + out_ticks));
    const rise = if (ease_in == 0) 1 else @as(f32, @floatFromInt(tick)) / (in_ticks * scale);
    const fall = if (ease_out == 0) 1 else @as(f32, @floatFromInt(duration - tick)) / (out_ticks * scale);
    const weight = @min(1, @min(rise, fall));
    return weight * weight * (3 - 2 * weight);
}

fn blend(a: Block, b: Block, t: f32) Block {
    var result: Block = undefined;
    for (0..3) |i| {
        result.focus[i] = @intFromFloat(@round(@as(f32, @floatFromInt(a.focus[i])) * (1 - t) + @as(f32, @floatFromInt(b.focus[i])) * t));
        result.angles[i] = @intFromFloat(@round(@as(f32, @floatFromInt(a.angles[i])) * (1 - t) + @as(f32, @floatFromInt(b.angles[i])) * t));
        result.translation[i] = @intFromFloat(@round(@as(f32, @floatFromInt(a.translation[i])) * (1 - t) + @as(f32, @floatFromInt(b.translation[i])) * t));
        result.scale[i] = @intFromFloat(@round(@as(f32, @floatFromInt(a.scale[i])) * (1 - t) + @as(f32, @floatFromInt(b.scale[i])) * t));
    }
    return result;
}

/// Camera pose after frame interpolation along the standard battle timeline.
pub fn sampleAt(ticks: u32) Block {
    if (ticks < Timeline.state0_frames) return intro_wide;
    if (ticks < Timeline.state0_frames + 60) {
        const t = @as(f32, @floatFromInt(ticks - Timeline.state0_frames)) / 60.0;
        return blend(intro_wide, standard_battle, t);
    }
    if (ticks < Timeline.state0_frames + Timeline.state1_frames + Timeline.state2_frames) return standard_battle;
    if (ticks < Timeline.state0_frames + Timeline.state1_frames + Timeline.state2_frames + 80) {
        const t = @as(f32, @floatFromInt(ticks - 176)) / 80.0;
        return blend(standard_battle, settled_pan, t);
    }
    return settled_pan;
}

pub fn scaleBlock(b: Block) f32 {
    return @as(f32, @floatFromInt(@divTrunc(b.scale[0] << 10, b.translation[2]))) / 4096.0;
}

pub fn scaleAt(ticks: u32) f32 {
    const b = sampleAt(ticks);
    return @as(f32, @floatFromInt(@divTrunc(b.scale[0] << 10, b.translation[2]))) / 4096.0;
}

/// Standard-battle framing observed in the reference: intro zoom into standard_battle, then hold.
pub fn sampleAtStandard(ticks: u32) Block {
    if (ticks < Timeline.state0_frames) return intro_wide;
    if (ticks < Timeline.state0_frames + 60) {
        const t = @as(f32, @floatFromInt(ticks - Timeline.state0_frames)) / 60.0;
        return blend(intro_wide, standard_battle, t);
    }
    return standard_battle;
}

pub fn scaleAtStandard(ticks: u32) f32 {
    const b = sampleAtStandard(ticks);
    return @as(f32, @floatFromInt(@divTrunc(b.scale[0] << 10, b.translation[2]))) / 4096.0;
}

pub fn projectStandard(ticks: u32, position: Vec3) ?Screen {
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

    /// State 2 installs no camera; state 3 installs settled_pan; state 4 holds it.
    pub fn blockAt(ticks: u32) usize {
        return switch (stateAt(ticks)) {
            0 => 0,
            1, 2 => 1,
            else => 2,
        };
    }
};

/// One global camera channel driven by actor script camera requests.
pub const Channel = struct {
    current: Vec3 = .{ 0, 0, 0 },
    target: Vec3 = .{ 0, 0, 0 },
    delta: Vec3 = .{ 0, 0, 0 },
    duration: u16 = 0,

    pub fn moveTo(self: *Channel, target: Vec3, frames: u16) void {
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
    .angles = .{ .current = .{ -768 << 12, 0, 640 << 12 }, .target = .{ -768 << 12, 0, 640 << 12 } },
    .translation = .{ .current = .{ 0, 0, 1024 << 12 }, .target = .{ 0, 0, 1024 << 12 } },
    .focus = .{ .current = .{ 0, 0, 0 }, .target = .{ 0, 0, 0 } },
    .scale = .{ .current = .{ 4096 << 12, 4096 << 12, 4096 << 12 }, .target = .{ 4096 << 12, 4096 << 12, 4096 << 12 } },
};

pub const Channels = struct {
    angles: Channel = .{},
    translation: Channel = .{},
    focus: Channel = .{},
    scale: Channel = .{},

    pub fn block(self: Channels) Block {
        var result: Block = .{
            .focus = .{ 0, 0, 0 },
            .angles = .{ 0, 0, 0 },
            .translation = .{ 0, 0, 1024 },
            .scale = .{ 4096, 4096, 4096 },
        };
        for (0..3) |i| {
            result.focus[i] = @divTrunc(self.focus.current[i], 4096);
            result.angles[i] = @divTrunc(self.angles.current[i], 4096);
            result.translation[i] = @divTrunc(self.translation.current[i], 4096);
            result.scale[i] = @divTrunc(self.scale.current[i], 4096);
        }
        return result;
    }

    pub fn tick(self: *Channels) void {
        self.angles.tick();
        self.translation.tick();
        self.focus.tick();
        self.scale.tick();
    }
};

/// Apply one character-script camera opcode (17-20) to the channels.
/// `origin` is the actor or owner world position used by op 20 modes 1/2.
pub fn applyOp(channels: *Channels, op: u16, args: []const i16, origin: Vec3) void {
    if (args.len < 4) return;
    const frames: u16 = @intCast(@max(args[0], 0));
    switch (op) {
        17 => channels.angles.moveTo(.{ @as(i32, args[1]) << 12, @as(i32, args[2]) << 12, @as(i32, args[3]) << 12 }, frames),
        18 => channels.translation.moveTo(.{ @as(i32, args[1]) << 12, @as(i32, args[2]) << 12, @as(i32, args[3]) << 12 }, frames),
        19 => channels.scale.moveTo(.{ @as(i32, args[1]) << 12, @as(i32, args[2]) << 12, @as(i32, args[3]) << 12 }, frames),
        20 => {
            if (args.len < 5) return;
            const mode = args[0];
            const target: Vec3 = if (mode == 0)
                .{ @as(i32, args[2]) << 12, @as(i32, args[3]) << 12, @as(i32, args[4]) << 12 }
            else
                .{ origin[0] + (@as(i32, args[2]) << 12), origin[1] + (@as(i32, args[3]) << 12), @as(i32, args[4]) << 12 };
            channels.focus.moveTo(target, @intCast(@max(args[1], 0)));
        },
        else => {},
    }
}

pub const Family = enum { party_close, enemy_close, effect_close, wide_default, special_zoom, enemy_wide, other };

pub fn family(b: Block) Family {
    if (b.focus[0] == 80 and b.scale[0] == 4864) return .party_close;
    if (b.focus[0] == -80 and b.scale[0] == 4864) return .enemy_close;
    if (b.focus[0] == -160 and b.angles[2] == 352 and b.scale[0] == 5120) return .effect_close;
    if (b.angles[2] == 640) return .wide_default;
    if (b.scale[0] >= 5888) return .special_zoom;
    if (b.focus[0] < 0) return .enemy_wide;
    return .other;
}

pub fn presetForFamily(f: Family) Block {
    return switch (f) {
        .party_close => attack_party,
        .enemy_close => attack_enemy,
        .effect_close => effect_close,
        .wide_default => wide_default,
        .special_zoom => special_zoom,
        .enemy_wide => enemy_wide,
        .other => other_default,
    };
}

pub const CastPreset = struct { name: []const u8, pose: Block };

const firestorm_cast = Block{ .focus = .{ -160, 0, 0 }, .angles = .{ -768, 0, 608 }, .translation = .{ 0, 0, 1024 }, .scale = .{ 5120, 5120, 5120 } };
const dancing_flames_cast = Block{ .focus = .{ -160, 0, 0 }, .angles = .{ -704, 0, 608 }, .translation = .{ 0, 0, 1024 }, .scale = .{ 4096, 4096, 4096 } };
const explosion_cast = Block{ .focus = .{ -160, 0, 0 }, .angles = .{ -768, 0, 352 }, .translation = .{ 0, 0, 1024 }, .scale = .{ 3840, 3840, 3840 } };
const yell_cast = Block{ .focus = .{ 112, 0, 0 }, .angles = .{ -768, 0, 352 }, .translation = .{ 0, 0, 1024 }, .scale = .{ 5888, 5888, 5888 } };
const shredding_cast = Block{ .focus = .{ 0, 0, 0 }, .angles = .{ -768, 0, 640 }, .translation = .{ 0, 0, 1024 }, .scale = .{ 3840, 3840, 3840 } };
const black_shadow_cast = Block{ .focus = .{ 0, 0, 0 }, .angles = .{ -864, 0, 608 }, .translation = .{ 0, 0, 1024 }, .scale = .{ 4096, 4096, 4096 } };
const hell_cast = Block{ .focus = .{ -128, 0, 0 }, .angles = .{ -320, 0, 128 }, .translation = .{ 0, 0, 1024 }, .scale = .{ 2304, 2304, 2304 } };

/// Final camera poses used for spell casts without a full per-phase camera script.
pub const cast_presets = [_]CastPreset{
    .{ .name = "Flaming Arrows", .pose = attack_enemy },
    .{ .name = "Firestorm", .pose = firestorm_cast },
    .{ .name = "Dancing Flames", .pose = dancing_flames_cast },
    .{ .name = "Explosion", .pose = explosion_cast },
    .{ .name = "Scolding", .pose = attack_enemy },
    .{ .name = "Yell", .pose = yell_cast },
    .{ .name = "Scream", .pose = settled_pan },
    .{ .name = "Charm Arrow", .pose = effect_close },
    .{ .name = "Drops of Kindness", .pose = attack_party },
    .{ .name = "Fog of Deception", .pose = effect_close },
    .{ .name = "Water of Kindness", .pose = settled_pan },
    .{ .name = "Rain of Kindness", .pose = settled_pan },
    .{ .name = "Mother Ocean", .pose = settled_pan },
    .{ .name = "Wind of Sleep", .pose = effect_close },
    .{ .name = "The Shredding", .pose = shredding_cast },
    .{ .name = "Healing Wind", .pose = special_zoom },
    .{ .name = "Shining Wind", .pose = shredding_cast },
    .{ .name = "Angry Blow", .pose = effect_close },
    .{ .name = "Rainstorm", .pose = dancing_flames_cast },
    .{ .name = "Ball of Lightning", .pose = enemy_wide },
    .{ .name = "Clay Guardian", .pose = special_zoom },
    .{ .name = "Copper Flesh", .pose = yell_cast },
    .{ .name = "Earthquake", .pose = enemy_wide },
    .{ .name = "Voice of Earth", .pose = explosion_cast },
    .{ .name = "Deadly Fingertips", .pose = black_shadow_cast },
    .{ .name = "Black Shadow", .pose = black_shadow_cast },
    .{ .name = "Hell", .pose = hell_cast },
    .{ .name = "Judgment", .pose = dancing_flames_cast },
};

pub fn castPreset(name: []const u8) ?Block {
    for (cast_presets) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.pose;
    }
    return null;
}

/// Interpreted camera matrix in presentation form: rotation/scale plus translation.
pub fn transform(b: Block) [3][4]f32 {
    const r = rotationMatrix(b.angles);
    var out: [3][4]f32 = undefined;
    for (0..3) |i| {
        for (0..3) |j| out[i][j] = @as(f32, @floatFromInt(r[i * 3 + j] * b.scale[j])) / (4096.0 * 4096.0);
        out[i][3] = @floatFromInt(b.translation[i]);
    }
    return out;
}

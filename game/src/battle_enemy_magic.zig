//! Enemy magic callbacks use named state; the battle owns actors, HP, RNG and art.
const std = @import("std");
const sin_cos = @import("battle_camera").sin_cos;
const Actor = @import("battle_actor_host.zig").Actor;
const CombatState = @import("battle.zig").State;

pub fn nextBattleDraw(combat: *CombatState) !u15 {
    const value = combat.roll();
    if (combat.replay_exhausted) return error.RandomInputExhausted;
    return value;
}

pub const ClipKind = enum { flare, impact, projectile, golem_rock, golem_impact };
pub const Frame = struct { entry: u16, updates: u16 };
pub const Clip = struct {
    id: ClipKind,
    frames: []const Frame,
    pub fn entryAt(self: Clip, age: u32) ?u16 {
        var remaining = age;
        for (self.frames) |frame| {
            if (remaining < frame.updates) return frame.entry;
            remaining -= frame.updates;
        }
        return null;
    }
};
pub const Art = struct {
    clips: []const Clip,
    anchors: []const struct { id: []const u8, centers_x: []const i16 },
    pub fn clip(self: Art, kind: ClipKind) Clip {
        for (self.clips) |value| if (value.id == kind) return value;
        unreachable;
    }
    pub fn hasClip(self: Art, kind: ClipKind) bool {
        for (self.clips) |value| if (value.id == kind) return true;
        return false;
    }
    pub fn center(self: Art, id: []const u8, pose: u16) ?i16 {
        for (self.anchors) |anchor| if (std.mem.eql(u8, anchor.id, id)) {
            return if (pose < anchor.centers_x.len) anchor.centers_x[pose] else null;
        };
        return null;
    }
    pub fn validate(self: Art, entry_count: usize) !void {
        if ((self.clips.len != 3 and self.clips.len != 5) or self.anchors.len == 0 or self.anchors.len > 78) return error.InvalidEnemyMagicArt;
        for (self.clips, 0..) |value, index| {
            if (value.frames.len == 0 or value.frames.len > 256) return error.InvalidEnemyMagicArt;
            for (self.clips[0..index]) |prior| if (value.id == prior.id) return error.InvalidEnemyMagicArt;
            for (value.frames) |frame| if (frame.entry >= entry_count or frame.updates == 0 or frame.updates > 256) return error.InvalidEnemyMagicArt;
        }
        for (self.anchors, 0..) |anchor, index| {
            if (anchor.id.len == 0 or anchor.id.len > 128 or anchor.centers_x.len == 0 or anchor.centers_x.len > 256) return error.InvalidEnemyMagicArt;
            for (anchor.centers_x) |value| if (value < -255 or value > 382) return error.InvalidEnemyMagicArt;
            for (self.anchors[0..index]) |prior| if (std.mem.eql(u8, anchor.id, prior.id)) return error.InvalidEnemyMagicArt;
        }
    }
};
pub const Parameters = struct {
    owner_wait_updates: u16,
    art_prepare_updates: u16,
    origin_offset: [3]i16,
    flight_offset_q12: [3]i32,
    projectile_size: i32,
    projectile_growth: i32,
    flight_updates: u16,
    flare_updates: u16,
    flare_grow_until: u16,
    flare_growth: i32,
    flare_shrink: i32,
    projectiles: [6]struct { launch_update: u16, contact_update: u16 },
    flares: [6]struct { launch_update: u16 },
    damage_update: u16,
    cleanup_update: u16,
    reaction_update: u16,
    shock_size: i32,
    shock_updates: u16,
    sounds: []const struct { update: u16, id: u16 },
};
pub const Binding = struct {
    id: []const u8,
    owner_program: []const u8,
    recipient_program: []const u8,
    selection_delay: u16,
    effect: Parameters,
    element: u8,
    target_rune_elements: [31]u8,
    fallback_element: u8,

    pub fn validate(self: Binding) !void {
        if (!std.mem.eql(u8, self.id, "kobold_type_3") or self.owner_program.len == 0 or self.owner_program.len > 128 or self.recipient_program.len == 0 or self.recipient_program.len > 128 or self.selection_delay == 0 or self.selection_delay > 1000 or self.element != 1 or self.fallback_element != 0) return error.InvalidEnemyMagicBinding;
        for (self.target_rune_elements) |element| if (element > 7) return error.InvalidEnemyMagicBinding;
        const p = self.effect;
        if (p.owner_wait_updates == 0 or p.owner_wait_updates > 1000 or p.art_prepare_updates == 0 or p.art_prepare_updates > 256 or p.flight_updates == 0 or p.flight_updates > 1000 or p.flare_updates == 0 or p.flare_updates > 1000 or p.flare_grow_until >= p.flare_updates or p.reaction_update != p.projectiles[0].contact_update or p.cleanup_update <= p.damage_update or p.cleanup_update > 1000 or p.sounds.len > 32 or p.shock_updates != 1 or p.shock_size < 0 or p.shock_size > 1048576) return error.InvalidEnemyMagicBinding;
        for ([_]i32{ p.projectile_size, p.projectile_growth, p.flare_growth, p.flare_shrink }) |value| if (value <= 0 or value > 65536) return error.InvalidEnemyMagicBinding;
        for (p.projectiles) |projectile| if (projectile.launch_update == 0 or @as(u32, projectile.launch_update) + p.flight_updates - 1 != projectile.contact_update or projectile.contact_update >= p.damage_update) return error.InvalidEnemyMagicBinding;
        for (p.flares) |flare| if (flare.launch_update == 0 or @as(u32, flare.launch_update) + p.flare_updates >= p.cleanup_update) return error.InvalidEnemyMagicBinding;
        for (p.sounds) |sound| if (sound.update == 0 or sound.update >= p.cleanup_update) return error.InvalidEnemyMagicBinding;
    }
    pub fn damage(self: Binding, caster_magic: u16, recipient_magic: u16, rune: u8, draw: u15) u32 {
        const selector = if (rune >= 1 and rune <= self.target_rune_elements.len) self.target_rune_elements[rune - 1] else self.fallback_element;
        return @import("battle_rules").physicalDamage(caster_magic, recipient_magic, draw, selector == self.element or selector == 7);
    }
};

pub const LinePool = struct {
    count: u8,
    spawn_until: u16,
    radius: i32,
    speed_base: i32,
    speed_mod: u15,
    life_mod: u15,
    tail_frames: i32,
    stop_abs_x: i32,
    angle_y: i16,
    color: [3]u8,
};
pub const SorcererBeam = struct {
    count: u8,
    clip: ClipKind,
    clip_period: u16,
    grow_until: u16,
    max_size: i32,
    size_step: i32,
    flight_start: u16,
    flight_updates: u16,
    reaction_update: u16,
    impact_clip: ClipKind,
    impact_period: u16,
    impact_loop_clear_update: u16,
    impact_end_update: u16,
    impact_size: i32,
};
pub const SirenRing = struct { radius: i16, height: i16, color: [3]u8 };
pub const SirenWaves = struct {
    active_until: u16,
    cycle_updates: u16,
    scale_step: i32,
    column_count: u8,
    column_delay_step: u16,
    reaction_scale: i32,
    reaction_updates: [8]u16,
    lower: SirenRing,
    upper: SirenRing,
    segments: u8,
    angle_y: i16,
    note_count: u8,
    note_delay_step: u16,
    note_turn_step: i16,
    note_local: [3]i32,
    note_poses: [4]u16,
    note_size: i32,
};
pub const GolemRocks = struct {
    camera_pulse_until: u16,
    camera_pulse_z_q12: i32,
    launch_update: u16,
    flight_updates: u16,
    active_until: u16,
    draw_until: u16,
    sine_divisor: u16,
    flight_arc: i32,
    bounce_arc: i32,
    spin_step: i16,
    impact_enable_update: u16,
    reaction_update: u16,
    impact_end_update: u16,
    rock_clip: ClipKind,
    impact_clip: ClipKind,
    impact_duration: u16,
    size: i32,
};
pub const AreaWorker = struct {
    origin_offset: [3]i16,
    target_z_offset: i16,
    art_prepare_updates: u16,
    damage_update: u16,
    cleanup_update: u16,
    sounds: []const struct { update: u16, id: u16 },
    line_pool: ?LinePool = null,
    beam: ?SorcererBeam = null,
    waves: ?SirenWaves = null,
    rocks: ?GolemRocks = null,

    pub fn jsonStringify(self: AreaWorker, writer: anytype) !void {
        try writer.beginObject();
        inline for (.{ "origin_offset", "target_z_offset", "art_prepare_updates", "damage_update", "cleanup_update", "sounds" }) |name| {
            try writer.objectField(name);
            try writer.write(@field(self, name));
        }
        inline for (.{ "line_pool", "beam", "waves", "rocks" }) |name| {
            if (@field(self, name)) |value| {
                try writer.objectField(name);
                try writer.write(value);
            }
        }
        try writer.endObject();
    }
};
pub const AreaKind = enum { sorcerer, siren, earth_golem };
pub const AreaBinding = struct {
    id: []const u8,
    owner_program: []const u8,
    recipient_program: []const u8,
    wave_recipient_program: ?[]const u8 = null,
    group: bool,
    front_reject_below: u8,
    special_reject_below: u8,
    selection_delay: u16,
    first_callback_update: u16,
    warmup_updates: u16,
    ready_mailboxes: []const u8,
    worker: AreaWorker,
    element: u8,
    target_rune_elements: [31]u8,
    fallback_element: u8,
    fallback_by_slot: bool = false,

    pub fn kind(self: AreaBinding) ?AreaKind {
        if (std.mem.eql(u8, self.id, "sorcerer")) return .sorcerer;
        if (std.mem.eql(u8, self.id, "siren")) return .siren;
        if (std.mem.eql(u8, self.id, "earth_golem")) return .earth_golem;
        return null;
    }
    pub fn validate(self: AreaBinding) !void {
        const k = self.kind() orelse return error.InvalidEnemyMagicBinding;
        if (self.owner_program.len == 0 or self.owner_program.len > 128 or self.recipient_program.len == 0 or self.recipient_program.len > 128 or self.front_reject_below != 51) return error.InvalidEnemyMagicBinding;
        for (self.target_rune_elements) |element| if (element > 7) return error.InvalidEnemyMagicBinding;
        const w = self.worker;
        if (w.damage_update == 0 or w.cleanup_update <= w.damage_update or w.cleanup_update > 1000 or w.sounds.len > 8) return error.InvalidEnemyMagicBinding;
        for (w.sounds) |sound| if (sound.update == 0 or sound.update >= w.cleanup_update) return error.InvalidEnemyMagicBinding;
        switch (k) {
            .sorcerer => {
                if (self.group or self.wave_recipient_program != null or self.special_reject_below != 51 or self.selection_delay != 0 or self.first_callback_update != 32 or self.warmup_updates != 0 or !std.mem.eql(u8, self.ready_mailboxes, &.{99}) or self.element != 6 or self.fallback_element != 1 or self.fallback_by_slot) return error.InvalidEnemyMagicBinding;
                if (w.art_prepare_updates != 10 or w.damage_update != 293 or w.cleanup_update != 294 or w.waves != null or w.rocks != null) return error.InvalidEnemyMagicBinding;
                const lp = w.line_pool orelse return error.InvalidEnemyMagicBinding;
                const beam = w.beam orelse return error.InvalidEnemyMagicBinding;
                if (lp.count != 20 or lp.spawn_until != 65 or lp.radius != 100 or lp.speed_mod == 0 or lp.life_mod == 0 or beam.count != 32 or beam.clip != .projectile or beam.impact_clip != .impact or beam.flight_start != 97 or beam.flight_updates != 24 or beam.reaction_update != 121 or beam.impact_end_update != 239) return error.InvalidEnemyMagicBinding;
            },
            .siren => {
                if (!self.group or self.wave_recipient_program == null or self.special_reject_below != 51 or self.selection_delay != 30 or self.first_callback_update != 38 or self.warmup_updates != 20 or !std.mem.eql(u8, self.ready_mailboxes, &.{ 99, 100 }) or self.element != 8 or self.fallback_element != 0 or self.fallback_by_slot) return error.InvalidEnemyMagicBinding;
                if (w.art_prepare_updates != 0 or w.damage_update != 198 or w.cleanup_update != 199 or w.line_pool != null or w.beam != null or w.rocks != null) return error.InvalidEnemyMagicBinding;
                const waves = w.waves orelse return error.InvalidEnemyMagicBinding;
                if (waves.active_until != 128 or waves.column_count != 4 or waves.note_count != 16 or waves.reaction_scale != 3009 or waves.segments != 24) return error.InvalidEnemyMagicBinding;
            },
            .earth_golem => {
                if (!self.group or self.wave_recipient_program != null or self.special_reject_below != 71 or self.selection_delay != 30 or self.first_callback_update != 38 or self.warmup_updates != 0 or !std.mem.eql(u8, self.ready_mailboxes, &.{99}) or self.element != 3 or self.fallback_element != 0 or !self.fallback_by_slot) return error.InvalidEnemyMagicBinding;
                if (w.art_prepare_updates != 10 or w.damage_update != 192 or w.cleanup_update != 194 or w.line_pool != null or w.beam != null or w.waves != null) return error.InvalidEnemyMagicBinding;
                const rocks = w.rocks orelse return error.InvalidEnemyMagicBinding;
                if (rocks.launch_update != 65 or rocks.flight_updates != 48 or rocks.impact_enable_update != 112 or rocks.reaction_update != 113 or rocks.impact_end_update != 147 or rocks.rock_clip != .golem_rock or rocks.impact_clip != .golem_impact) return error.InvalidEnemyMagicBinding;
            },
        }
    }
    pub fn damage(self: AreaBinding, caster_magic: u16, recipient_magic: u16, rune: u8, draw: u15, party_slot: usize) u32 {
        const fallback: u8 = if (self.fallback_by_slot) @intCast(party_slot + 1) else self.fallback_element;
        const raw = if (rune >= 1 and rune <= self.target_rune_elements.len) self.target_rune_elements[rune - 1] else 0;
        const selector = if (raw == 0) fallback else raw;
        return @import("battle_rules").physicalDamage(caster_magic, recipient_magic, draw, selector == self.element or selector == 7);
    }
};

pub const Event = struct {
    contact: bool = false,
    reaction: bool = false,
    wave_reaction: bool = false,
    damage: bool = false,
    cleanup: bool = false,
    camera_pulse_z_q12: ?i32 = null,
};
pub const Graphic = struct {
    kind: ClipKind,
    index: u6,
    entry: u16,
    position_q12: [3]i32,
    size: i32,
    tint: [3]u8 = .{ 127, 127, 127 },
    node_angle_z: i16 = 1,
};
pub const Graphics = struct { values: [18]Graphic = undefined, count: usize = 0 };
pub const AreaGraphics = struct {
    sprites: [33]Graphic = undefined,
    sprite_count: usize = 0,
    lines: [20]struct { head: [3]i32, tail: [3]i32, angle_y: i16, color: [3]u8 } = undefined,
    line_count: usize = 0,
    columns: [4]struct { scale: i32, lower: SirenRing, upper: SirenRing, segments: u8, angle_y: i16 } = undefined,
    column_count: usize = 0,
    notes: [16]struct { pose: u16, scale: i32, angle_y: i16, angle_z: i16, local: [3]i32, size: i32 } = undefined,
    note_count: usize = 0,
};
pub const LineParticle = struct {
    enabled: bool = false,
    life: i16 = 0,
    head_q12: [3]i32 = .{ 0, 0, 0 },
    tail_q12: [3]i32 = .{ 0, 0, 0 },
    vel_q12: [3]i32 = .{ 0, 0, 0 },
};
pub const SirenColumn = struct {
    enabled: bool = false,
    delay: u16 = 0,
    scale: i32 = 4096,
};
pub const SirenNote = struct {
    enabled: bool = false,
    delay: u16 = 0,
    scale: i32 = 4096,
    angle_z: i16 = 0,
};
pub const GolemRock = struct {
    enabled: bool = false,
    delta_q12: [3]i32 = .{ 0, 0, 0 },
    pos_q12: [3]i32 = .{ 0, 0, 0 },
    node_angle_z: i16 = 1,
    impact_enabled: bool = false,
    impact_pos_q12: [3]i32 = .{ 0, 0, 0 },
};
pub const AreaState = union(AreaKind) {
    sorcerer: [20]LineParticle,
    siren: struct {
        columns: [4]SirenColumn = .{
            .{ .delay = 0 },
            .{ .delay = 16 },
            .{ .delay = 32 },
            .{ .delay = 48 },
        },
        notes: [16]SirenNote = .{
            .{ .delay = 0 },  .{ .delay = 4 },  .{ .delay = 8 },  .{ .delay = 12 },
            .{ .delay = 16 }, .{ .delay = 20 }, .{ .delay = 24 }, .{ .delay = 28 },
            .{ .delay = 32 }, .{ .delay = 36 }, .{ .delay = 40 }, .{ .delay = 44 },
            .{ .delay = 48 }, .{ .delay = 52 }, .{ .delay = 56 }, .{ .delay = 60 },
        },
    },
    earth_golem: [6]GolemRock,

    pub fn init(kind: AreaKind) AreaState {
        return switch (kind) {
            .sorcerer => .{ .sorcerer = @splat(.{}) },
            .siren => .{ .siren = .{} },
            .earth_golem => .{ .earth_golem = @splat(.{}) },
        };
    }
};

pub const Playback = struct {
    owner: u8,
    recipient: u8,
    start_at: u32,
    prepared: bool = false,
    recipient_started: bool = false,
    owner_done: bool = false,
    recipient_done: bool = false,
    amount: ?u32 = null,
    phase: enum { owner_script, allocate, waiting, nested_start, load, ready, create, running, nested_return, free, awaiting_owner, complete } = .owner_script,
    remaining: u16 = 0,
    update: u16 = 0,
    root: [3]i32 = .{ 0, 0, 0 },
    flight_delta_q12: [3]i32 = .{ 0, 0, 0 },
    group: bool = false,
    group_recipients_started: u8 = 0,
    group_recipients_done: u8 = 0,
    group_amounts: [6]?u32 = @splat(null),
    area: ?AreaState = null,

    pub fn jsonStringify(self: Playback, writer: anytype) !void {
        try writer.beginObject();
        inline for (.{ "owner", "recipient", "start_at", "prepared", "recipient_started", "owner_done", "recipient_done", "amount", "phase", "remaining", "update", "root", "flight_delta_q12" }) |name| {
            try writer.objectField(name);
            try writer.write(@field(self, name));
        }
        if (self.area != null) {
            inline for (.{ "group", "group_recipients_started", "group_recipients_done", "group_amounts", "area" }) |name| {
                try writer.objectField(name);
                try writer.write(@field(self, name));
            }
        }
        try writer.endObject();
    }
    pub fn ownsRecipient(self: Playback, actor: usize) bool {
        if (!self.group) return actor == self.recipient and self.recipient_started and !self.recipient_done;
        if (actor >= 6) return false;
        const bit = @as(u8, 1) << @intCast(actor);
        return (self.group_recipients_started & bit) != 0 and (self.group_recipients_done & bit) == 0;
    }
    pub fn allRecipientsDone(self: Playback) bool {
        if (!self.group) return self.recipient_done;
        return self.phase == .complete and self.group_recipients_done == self.group_recipients_started;
    }
    pub fn beginEffect(self: *Playback) !void {
        if (self.phase != .owner_script) return error.DuplicateEnemyMagicEffect;
        self.phase = .allocate;
    }
    pub fn advance(self: *Playback, binding: Binding, actor: *Actor, recipient_q12: [3]i32) Event {
        const p = binding.effect;
        var event = Event{};
        switch (self.phase) {
            .owner_script, .complete => {},
            .allocate => {
                self.remaining = p.owner_wait_updates;
                actor.shared_value = 1;
                self.phase = .waiting;
            },
            .waiting => {
                self.remaining -= 1;
                if (self.remaining == 0) {
                    actor.shared_value = 2;
                    self.phase = .nested_start;
                }
            },
            .nested_start => {
                actor.shared_value = 3;
                self.phase = .load;
            },
            .load => {
                self.remaining = p.art_prepare_updates;
                self.phase = .ready;
            },
            .ready => {
                if (self.remaining > 0) self.remaining -= 1 else self.phase = .create;
            },
            .create => {
                for (0..3) |axis| self.root[axis] = (actor.position_q12[axis] >> 12) + p.origin_offset[axis];
                self.phase = .running;
            },
            .running => {
                if (self.update == 0) for (0..3) |axis| {
                    self.flight_delta_q12[axis] = recipient_q12[axis] +% p.flight_offset_q12[axis] -% actor.position_q12[axis];
                };
                self.update += 1;
                for (p.projectiles) |projectile| event.contact = event.contact or self.update == projectile.contact_update;
                event.reaction = self.update == p.reaction_update;
                event.damage = self.update == p.damage_update;
                if (self.update == p.cleanup_update) {
                    event.cleanup = true;
                    self.phase = .nested_return;
                }
            },
            .nested_return => {
                actor.shared_value = 99;
                self.phase = .free;
            },
            .free => self.phase = .awaiting_owner,
            .awaiting_owner => if (actor.shared_value == 100) {
                self.phase = .complete;
            },
        }
        return event;
    }
    pub fn advanceArea(self: *Playback, binding: AreaBinding, actor: *Actor, party_q12: [6][3]i32, party_active: [6]bool, combat: *CombatState) !Event {
        const w = binding.worker;
        const area = &(self.area orelse return error.MissingEnemyMagicBinding);
        var event = Event{};
        switch (self.phase) {
            .owner_script, .complete, .awaiting_owner => {},
            .allocate => {
                if (binding.warmup_updates > 0) {
                    self.remaining = binding.warmup_updates;
                    actor.shared_value = 1;
                    self.phase = .waiting;
                } else self.phase = .nested_start;
            },
            .waiting => {
                self.remaining -= 1;
                if (self.remaining == 0) {
                    actor.shared_value = 2;
                    self.phase = .nested_start;
                }
            },
            .nested_start => {
                if (binding.warmup_updates > 0) actor.shared_value = 3;
                self.phase = if (w.art_prepare_updates > 0) .load else .create;
            },
            .load => {
                self.remaining = w.art_prepare_updates;
                self.phase = .ready;
            },
            .ready => {
                if (self.remaining > 0) self.remaining -= 1 else self.phase = .create;
            },
            .create => {
                for (0..3) |axis| self.root[axis] = (actor.position_q12[axis] >> 12) + w.origin_offset[axis];
                switch (area.*) {
                    .siren => |*siren| {
                        for (&siren.notes) |*note| {
                            const random = try nextBattleDraw(combat);
                            note.angle_z = @intCast(random & 0xfff);
                        }
                    },
                    else => {},
                }
                self.phase = .running;
            },
            .running => {
                self.update += 1;
                const u = self.update;
                if (u == w.cleanup_update) {
                    event.cleanup = true;
                    self.phase = .nested_return;
                    return event;
                }
                switch (area.*) {
                    .sorcerer => |*lines| {
                        const lp = w.line_pool.?;
                        const beam = w.beam.?;
                        if (u == 1) {
                            const target_q12 = party_q12[self.recipient];
                            self.flight_delta_q12 = .{
                                ((target_q12[0] >> 12) - self.root[0]) << 12,
                                ((target_q12[1] >> 12) - self.root[1]) << 12,
                                ((target_q12[2] >> 12) + w.target_z_offset - self.root[2]) << 12,
                            };
                        }
                        if (u <= lp.spawn_until) {
                            const span_x: u15 = @intCast(2 * lp.radius - 2);
                            for (lines) |*line| if (!line.enabled) {
                                const d0 = try nextBattleDraw(combat);
                                const x: i32 = @as(i32, @intCast(d0 % span_x)) - (lp.radius - 1);
                                const rem_xy: u32 = @intCast(lp.radius * lp.radius - x * x);
                                const max_y = sin_cos.psxSqrt(rem_xy);
                                const d1 = try nextBattleDraw(combat);
                                const y: i32 = if (max_y > 0) @as(i32, @intCast(d1 % @as(u15, @intCast(2 * max_y)))) - max_y else 0;
                                const rem_z: u32 = @intCast(@max(0, @as(i32, @intCast(rem_xy)) - y * y));
                                const z_lim = sin_cos.psxSqrt(rem_z) + 1;
                                const z: i32 = if (((x + y) & 1) != 0) -(z_lim - 1) else (z_lim - 1);
                                const d2 = try nextBattleDraw(combat);
                                const speed: i32 = lp.speed_base + @as(i32, d2 % lp.speed_mod);
                                const vx = @divTrunc(-x * speed, lp.radius);
                                const vy = @divTrunc(-y * speed, lp.radius);
                                const vz = @divTrunc(-z * speed, lp.radius);
                                const d3 = try nextBattleDraw(combat);
                                line.* = .{
                                    .enabled = true,
                                    .life = @intCast(d3 % lp.life_mod),
                                    .head_q12 = .{ x << 12, y << 12, z << 12 },
                                    .tail_q12 = .{
                                        (x + @divTrunc(lp.tail_frames * vx, 64)) << 12,
                                        (y + @divTrunc(lp.tail_frames * vy, 64)) << 12,
                                        (z + @divTrunc(lp.tail_frames * vz, 64)) << 12,
                                    },
                                    .vel_q12 = .{ vx << 6, vy << 6, vz << 6 },
                                };
                            };
                        }
                        for (lines) |*line| if (line.enabled) {
                            const tx = line.tail_q12[0] >> 12;
                            if (line.life <= 0 or @abs(tx) < lp.stop_abs_x) {
                                line.enabled = false;
                            } else {
                                line.life -= 1;
                                for (0..3) |axis| {
                                    line.head_q12[axis] +%= line.vel_q12[axis];
                                    line.tail_q12[axis] +%= line.vel_q12[axis];
                                }
                            }
                        };
                        event.reaction = u == beam.reaction_update;
                        event.damage = u == w.damage_update;
                    },
                    .siren => |*siren| {
                        const waves = w.waves.?;
                        const clock = u - 1;
                        if (u <= waves.active_until) {
                            for (&siren.columns) |*col| {
                                if ((col.delay == 0 and !col.enabled) or (col.delay != 0 and col.delay == clock)) {
                                    col.enabled = true;
                                    col.delay = 0;
                                    col.scale = 1;
                                }
                            }
                            for (&siren.notes) |*note| {
                                if ((note.delay == 0 and !note.enabled) or (note.delay != 0 and note.delay == clock)) {
                                    note.enabled = true;
                                    note.delay = 0;
                                    note.scale = 1;
                                }
                            }
                        }
                        for (&siren.notes) |*note| if (note.enabled) {
                            if (note.scale < 4096) {
                                note.scale += waves.scale_step;
                                note.angle_z +%= waves.note_turn_step;
                            } else note.enabled = false;
                        };
                        for (&siren.columns) |*col| if (col.enabled) {
                            if (col.scale < 4096) {
                                col.scale += waves.scale_step;
                                if (col.scale == waves.reaction_scale) event.wave_reaction = true;
                            } else col.enabled = false;
                        };
                        if (u == w.damage_update) {
                            event.reaction = true;
                            event.damage = true;
                        }
                    },
                    .earth_golem => |*rocks_state| {
                        const rocks = w.rocks.?;
                        if (u == rocks.launch_update) {
                            for (0..6) |slot| if (party_active[slot]) {
                                rocks_state[slot] = .{
                                    .enabled = true,
                                    .delta_q12 = .{
                                        ((party_q12[slot][0] >> 12) - self.root[0]) << 12,
                                        ((party_q12[slot][1] >> 12) - self.root[1]) << 12,
                                        ((party_q12[slot][2] >> 12) + w.target_z_offset - self.root[2]) << 12,
                                    },
                                };
                            };
                        }
                        if (u >= rocks.launch_update and u <= rocks.active_until) {
                            const age = u - rocks.launch_update;
                            const step: i32 = @intCast(age + 1);
                            const angle: usize = ((@as(usize, age) << 12) / rocks.sine_divisor) & 4095;
                            const sin_val: i32 = sin_cos.table[angle][0];
                            for (rocks_state) |*rock| if (rock.enabled) {
                                rock.pos_q12[0] = @divTrunc(rock.delta_q12[0] *% step, rocks.flight_updates);
                                rock.pos_q12[1] = @divTrunc(rock.delta_q12[1] *% step, rocks.flight_updates);
                                rock.pos_q12[2] = if (age < rocks.flight_updates)
                                    @divTrunc(rock.delta_q12[2] *% step, rocks.flight_updates) - rocks.flight_arc * sin_val
                                else
                                    rock.delta_q12[2] + rocks.bounce_arc * sin_val;
                                if (u == rocks.impact_enable_update) {
                                    rock.impact_enabled = true;
                                    rock.impact_pos_q12 = rock.pos_q12;
                                }
                            };
                        }
                        if (u >= rocks.launch_update and u <= rocks.draw_until) {
                            for (rocks_state) |*rock| if (rock.enabled) {
                                rock.node_angle_z +%= rocks.spin_step;
                            };
                        }
                        if (u <= rocks.camera_pulse_until) {
                            if (u % 4 == 1) event.camera_pulse_z_q12 = rocks.camera_pulse_z_q12;
                            if (u % 4 == 3) event.camera_pulse_z_q12 = -rocks.camera_pulse_z_q12;
                        }
                        event.reaction = u == rocks.reaction_update;
                        event.damage = u == w.damage_update;
                    },
                }
            },
            .nested_return => {
                actor.shared_value = 99;
                self.phase = .free;
            },
            .free => {
                if (binding.ready_mailboxes.len > 1) actor.shared_value = binding.ready_mailboxes[1];
                self.phase = .complete;
            },
        }
        return event;
    }
    pub fn graphics(self: Playback, binding: Binding, art: Art) Graphics {
        var result = Graphics{};
        const p = binding.effect;
        if (self.phase != .running or self.update == 0 or self.update >= p.cleanup_update) return result;
        for (p.projectiles, 0..) |projectile, index| {
            if (self.update >= projectile.launch_update) {
                const age = self.update - projectile.launch_update + 1;
                if (age < p.flight_updates) {
                    var position: [3]i32 = undefined;
                    for (self.flight_delta_q12, 0..) |delta, axis| position[axis] = @divTrunc(delta *% @as(i32, age), p.flight_updates);
                    result.values[result.count] = .{ .kind = .projectile, .index = @intCast(index), .entry = art.clip(.projectile).entryAt(age) orelse continue, .position_q12 = position, .size = p.projectile_size + p.projectile_growth * age };
                    result.count += 1;
                }
            }
            if (self.update > projectile.contact_update) {
                const age = self.update - projectile.contact_update;
                if (art.clip(.impact).entryAt(age)) |entry| {
                    var position: [3]i32 = undefined;
                    for (self.flight_delta_q12, 0..) |delta, axis| position[axis] = @divTrunc(delta *% @as(i32, p.flight_updates), p.flight_updates);
                    result.values[result.count] = .{ .kind = .impact, .index = @intCast(index), .entry = entry, .position_q12 = position, .size = 4096 };
                    result.count += 1;
                }
            }
        }
        for (p.flares, 0..) |flare, index| {
            if (self.update < flare.launch_update) continue;
            const age = self.update - flare.launch_update + 1;
            if (age >= p.flare_updates) continue;
            const growing: i32 = @min(age, p.flare_updates - p.flare_grow_until);
            result.values[result.count] = .{ .kind = .flare, .index = @intCast(index), .entry = art.clip(.flare).entryAt(0).?, .position_q12 = .{ 0, 0, 0 }, .size = 1 + growing * p.flare_growth - (@as(i32, age) - growing) * p.flare_shrink };
            result.count += 1;
        }
        return result;
    }
    pub fn areaGraphics(self: Playback, binding: AreaBinding, art: Art) AreaGraphics {
        var result = AreaGraphics{};
        const w = binding.worker;
        const area = self.area orelse return result;
        if (self.phase != .running or self.update == 0 or self.update >= w.cleanup_update) return result;
        const u = self.update;
        switch (area) {
            .sorcerer => |lines| {
                const lp = w.line_pool.?;
                const beam = w.beam.?;
                const proj_entry = art.clip(.projectile).entryAt(u % beam.clip_period).?;
                for (0..beam.count) |index| {
                    const lag: u16 = @intCast(if (index == 0) 0 else index - 1);
                    const end_u = beam.flight_start + beam.flight_updates - 1 + lag;
                    if (u > end_u) continue;
                    const source_u: i32 = @as(i32, u) - @as(i32, lag);
                    var pos: [3]i32 = .{ 0, 0, 0 };
                    if (source_u >= beam.flight_start) {
                        const step = source_u - @as(i32, beam.flight_start - 1);
                        for (0..3) |axis| pos[axis] = @divTrunc(self.flight_delta_q12[axis] *% step, beam.flight_updates);
                    }
                    const size: i32 = if (source_u <= 0) 1 else if (source_u < beam.grow_until) 1 + beam.size_step * source_u else beam.max_size;
                    const tint: u8 = @intCast(((32 - @as(u16, @intCast(index))) * 127) >> 5);
                    result.sprites[result.sprite_count] = .{
                        .kind = .projectile,
                        .index = @intCast(index),
                        .entry = proj_entry,
                        .position_q12 = pos,
                        .size = size,
                        .tint = .{ tint, tint, tint },
                    };
                    result.sprite_count += 1;
                }
                if (u >= beam.reaction_update and u <= beam.impact_end_update) {
                    const age = u - (beam.reaction_update - 1);
                    if (art.clip(.impact).entryAt(age % beam.impact_period)) |entry| {
                        result.sprites[result.sprite_count] = .{
                            .kind = .impact,
                            .index = 0,
                            .entry = entry,
                            .position_q12 = self.flight_delta_q12,
                            .size = beam.impact_size,
                        };
                        result.sprite_count += 1;
                    }
                }
                for (lines) |line| if (line.enabled) {
                    result.lines[result.line_count] = .{
                        .head = .{ line.head_q12[0] >> 12, line.head_q12[1] >> 12, line.head_q12[2] >> 12 },
                        .tail = .{ line.tail_q12[0] >> 12, line.tail_q12[1] >> 12, line.tail_q12[2] >> 12 },
                        .angle_y = lp.angle_y,
                        .color = lp.color,
                    };
                    result.line_count += 1;
                };
            },
            .siren => |siren| {
                const waves = w.waves.?;
                for (siren.notes, 0..) |note, index| if (note.enabled) {
                    result.notes[result.note_count] = .{
                        .pose = waves.note_poses[index % 4],
                        .scale = note.scale,
                        .angle_y = waves.angle_y,
                        .angle_z = note.angle_z,
                        .local = waves.note_local,
                        .size = waves.note_size,
                    };
                    result.note_count += 1;
                };
                for (siren.columns) |col| if (col.enabled) {
                    result.columns[result.column_count] = .{
                        .scale = col.scale,
                        .lower = waves.lower,
                        .upper = waves.upper,
                        .segments = waves.segments,
                        .angle_y = waves.angle_y,
                    };
                    result.column_count += 1;
                };
            },
            .earth_golem => |rocks_state| {
                const rocks = w.rocks.?;
                if (u >= rocks.impact_enable_update and u <= rocks.impact_end_update and art.hasClip(.golem_impact)) {
                    const age = u - (rocks.impact_enable_update - 1);
                    if (art.clip(.golem_impact).entryAt(age)) |entry| {
                        for (rocks_state, 0..) |rock, index| if (rock.impact_enabled) {
                            result.sprites[result.sprite_count] = .{
                                .kind = .golem_impact,
                                .index = @intCast(index),
                                .entry = entry,
                                .position_q12 = rock.impact_pos_q12,
                                .size = rocks.size,
                            };
                            result.sprite_count += 1;
                        };
                    }
                }
                if (u >= rocks.launch_update and u <= rocks.draw_until and art.hasClip(.golem_rock)) {
                    const entry = art.clip(.golem_rock).entryAt(0).?;
                    for (rocks_state, 0..) |rock, index| if (rock.enabled) {
                        result.sprites[result.sprite_count] = .{
                            .kind = .golem_rock,
                            .index = @intCast(index),
                            .entry = entry,
                            .position_q12 = rock.pos_q12,
                            .size = rocks.size,
                            .node_angle_z = rock.node_angle_z,
                        };
                        result.sprite_count += 1;
                    };
                }
            },
        }
        return result;
    }
};

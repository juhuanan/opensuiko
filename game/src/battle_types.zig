const std = @import("std");
const field = @import("field");
const battle_systems = @import("battle_systems");
const battle_host_systems = battle_systems.host;
const combat_effects = @import("combat_systems").effects;
const validPosition = @import("battle_content.zig").validPosition;

pub fn battleSchemaVersion(schema: []const u8) ?u8 {
    const prefix = "suikoden-battle-trial/";
    if (!std.mem.startsWith(u8, schema, prefix)) return null;
    const suffix = schema[prefix.len..];
    if (suffix.len == 0 or suffix[0] < '1' or suffix[0] > '9') return null;
    for (suffix) |ch| if (ch < '0' or ch > '9') return null;
    const version = std.fmt.parseInt(u8, suffix, 10) catch return null;
    return if (version == 2 or (version >= 5 and version <= 46)) version else null;
}

pub fn supportedBattleSchema(schema: []const u8) bool {
    return battleSchemaVersion(schema) != null;
}

pub const Rect = field.Rect;
pub const trial_seed: u64 = 0x5355494B;
pub const Member = field.game_state.Member;
pub const Stats = field.game_state.Stats;
pub const Ailment = enum { poison, balloon, sleep, accuracy_reduced, rune_blocked };
pub const systems = @import("battle_rules");
pub const Pose = struct { rect: Rect, anchor_x: i16, anchor_y: i16 };
pub const Frame = struct { pose: Pose, ticks: u16, source_pose: ?u16 = null };
pub const ActorLayout = struct { point: presentation.ScreenPoint, scale: f32, sprite: Pose, source_pose: ?u16 = null };
pub const layout = @import("battle_layout.zig");
pub const drops = @import("battle_drops.zig");
pub const spell_scene = @import("battle_spell_scene.zig");
pub const presentation = @import("battle_presentation.zig");
pub const Position = presentation.Vec3;
pub const Scenery = struct { sprite: Pose, position: Position };
pub const Row = field.game_state.Row;
pub const WeaponRange = field.game_state.WeaponRange;
pub const Drop = struct { item: ?field.items.Id, uses: u16, rate: u8, identified: bool = true };
pub const OrdinaryTiming = struct { impact_tick: u16, return_tick: u16, duration: u16, target_release_delay: ?u16 = null };
pub const DodgeTiming = struct { id: []const u8, target_release_tick: u16 };
pub const FrontProjectileTiming = struct {
    impact_tick: u16,
    target_release_tick: u16,
    owner_release_tick: u16,
    dodges: []const DodgeTiming = &.{},
    pub fn jsonStringify(self: FrontProjectileTiming, writer: anytype) !void {
        try writer.beginObject();
        inline for (@typeInfo(FrontProjectileTiming).@"struct".field_names) |name| {
            if (comptime std.mem.eql(u8, name, "dodges")) {
                if (self.dodges.len != 0) {
                    try writer.objectField(name);
                    try writer.write(self.dodges);
                }
            } else {
                try writer.objectField(name);
                try writer.write(@field(self, name));
            }
        }
        try writer.endObject();
    }
};
pub const FrontProjectile = struct { actor: usize, target: usize, ticks: u16 = 0, target_released: bool = false, owner_released: bool = false, dodge_release: ?u16 = null, low_hp_target: bool = false };
pub const ProjectileTiming = struct { impact_tick: u16, release_tick: u16, duration: u16 };
pub const CommanderTiming = struct { auxiliary_spawn_tick: u16, auxiliary_release_tick: u16, reaction_tick: u16, owner_release_tick: u16, status_tick: u16, duration: u16, status_percent: u8 };
pub const CommanderOrderTiming = struct { launch_tick: u16, owner_release_tick: u16 };
pub const OrderedAttackTiming = struct { impact_tick: u16, return_tick: u16, status_tick: u16, target_release_tick: u16, duration: u16, status_percent: u8 };
pub const UniteTrail = struct { start: u16, stop: u16, poses: [8]Pose };
pub const UniteTrailState = struct { points: [8]presentation.ScreenPoint = undefined, next: u3 = 0, initialized: bool = false, visible: bool = false };
pub const ScreenOffset = struct { start: u16, updates: u16, target: bool, value: [2]i16 };
pub const UniteTrack = struct {
    screen_offsets: []const ScreenOffset = &.{},
    trail: ?UniteTrail = null,
    attack: []const Frame,
    motion: presentation.Motion,
    camera: []const @import("battle_camera").ActorRequest = &.{},
    start_after: u16 = 0,
    reaction_on_hit: bool = false,

    pub fn jsonStringify(self: UniteTrack, writer: anytype) !void {
        try writer.beginObject();
        inline for (@typeInfo(UniteTrack).@"struct".field_names) |name| {
            if (comptime std.mem.eql(u8, name, "screen_offsets")) {
                if (self.screen_offsets.len != 0) {
                    try writer.objectField(name);
                    try writer.write(self.screen_offsets);
                }
            } else if (comptime std.mem.eql(u8, name, "trail")) {
                if (self.trail) |trail| {
                    try writer.objectField(name);
                    try writer.write(trail);
                }
            } else if (comptime std.mem.eql(u8, name, "start_after")) {
                if (self.start_after != 0) {
                    try writer.objectField(name);
                    try writer.write(self.start_after);
                }
            } else if (comptime std.mem.eql(u8, name, "reaction_on_hit")) {
                if (self.reaction_on_hit) {
                    try writer.objectField(name);
                    try writer.write(true);
                }
            } else {
                try writer.objectField(name);
                try writer.write(@field(self, name));
            }
        }
        try writer.endObject();
    }
};
pub const UniteScene = struct { record: u8, track: UniteTrack };
pub const AnimationClip = struct {
    advances: bool,
    loop: bool,
    frames: []const Frame,
    pub fn sample(self: AnimationClip, elapsed: u32) Pose {
        return self.frameAt(elapsed).pose;
    }
    pub fn frameAt(self: AnimationClip, elapsed: u32) Frame {
        if (!self.advances) return self.frames[0];
        var total: u32 = 0;
        for (self.frames) |frame| total += frame.ticks;
        var tick = if (self.loop) elapsed % total else @min(elapsed, total - 1);
        for (self.frames) |frame| {
            if (tick < frame.ticks) return frame;
            tick -= frame.ticks;
        }
        unreachable;
    }
};
pub const RevivalArt = struct { down: AnimationClip, recovery: AnimationClip };
pub const ItemArt = struct { idle: AnimationClip, prepare: AnimationClip, hold: AnimationClip, recover: AnimationClip };
pub const Dodge = struct {
    animation: u8,
    back: presentation.Leap,
    ready_wait: u16,
    retreat: presentation.Leap,
    pub fn retreatStart(self: Dodge, timing: PartyAttackTiming) u16 {
        const contact = @max(timing.dodge_start_tick.? + self.back.ticks, timing.impact_tick - 1);
        return @max(contact + 1, timing.return_tick - 1) + self.ready_wait;
    }
    pub fn releaseTick(self: Dodge, timing: PartyAttackTiming) u16 {
        return self.retreatStart(timing) + self.retreat.ticks;
    }
    pub fn validate(self: Dodge) !void {
        if (self.animation >= 64 or self.ready_wait == 0 or self.ready_wait > 256) return error.InvalidDodge;
        for ([_]presentation.Leap{ self.back, self.retreat }) |leap| {
            if (leap.ticks < 2 or leap.ticks > 256 or leap.acceleration_step != 1.0 / 4096.0) return error.InvalidDodge;
            inline for (.{ "x", "y", "z" }) |axis| if (!std.math.isFinite(@field(leap.offset, axis)) or !std.math.isFinite(@field(leap.velocity, axis)) or @abs(@field(leap.offset, axis)) > 4096 or @abs(@field(leap.velocity, axis)) > 4096) return error.InvalidDodge;
        }
    }
};
pub const Profile = struct {
    dodge: ?Dodge = null,
    revival_art: ?RevivalArt = null,
    item_art: ?ItemArt = null,
    effect_offset: ?[2]i16 = null,
    front_projectile: ?FrontProjectileTiming = null,
    knockout_ticks: ?u16 = null,
    commander_order: ?CommanderOrderTiming = null,
    ordered_attack: ?OrderedAttackTiming = null,
    commander: ?CommanderTiming = null,
    ordinary_timing: ?OrdinaryTiming = null,
    projectile: ?ProjectileTiming = null,
    rune_locked: bool = false,
    weapon: ?systems.Weapon = null,
    id: []const u8,
    name: []const u8,
    max_hp: u16,
    level: u8,
    stats: Stats,
    sprite: Pose,
    attack: []const Frame,
    motion: ?presentation.Motion = null,
    money: u32 = 0,
    growth: [6]u4 = @splat(0),
    weapon_range: ?WeaponRange = null,
    foot_offset_y: i16 = 0,
    rune: ?[]const u8 = null,
    unite_attack: []const Frame = &.{},
    unite_motion: ?presentation.Motion = null,
    unite_camera: []const @import("battle_camera").ActorRequest = &.{},
    unite_scenes: []const UniteScene = &.{},
    cast: []const Frame = &.{},
    cast_impact: u16 = 60,
    fire_affinity: systems.Affinity = .neutral,
    affinities: ?systems.Affinities = null,
    other_affinity: ?systems.Affinity = null,
    death_immune: ?bool = null,
    airborne: ?bool = null,
    target_policy: enum { random, front_first, any_row } = .random,
    action_policy: enum { attack, ant_double_strike, rabbit, roc, commander, front_projectile, source_melee, unsupported, source_magic, source_projectile, source_commander, source_rabbit, source_ninja, source_dagon, source_whip_wolf, source_holly_fairy, source_sorcerer, source_siren, source_earth_golem, source_creeper, source_shadow_man, source_mirage_f, source_mirage_h } = .attack,
    dodges_attacks: bool = false,
    unavoidable_attack: bool = false,
    drops: ?[3]Drop = null,
    pub fn uniteTrack(self: Profile, record: ?u8) ?UniteTrack {
        if (self.unite_scenes.len != 0) {
            if (record) |id| {
                for (self.unite_scenes) |scene| if (scene.record == id) return scene.track;
                return null;
            }
            return if (self.unite_scenes.len == 1) self.unite_scenes[0].track else null;
        }
        return if (self.unite_motion) |motion| .{ .attack = self.unite_attack, .motion = motion, .camera = self.unite_camera } else null;
    }
    pub fn jsonStringify(self: Profile, writer: anytype) !void {
        // Keep prior content/save identities when the new source policy is absent.
        try writer.beginObject();
        inline for (@typeInfo(Profile).@"struct".field_names) |member_field| {
            if (comptime std.mem.eql(u8, member_field, "unite_scenes")) {
                if (self.unite_scenes.len != 0) {
                    try writer.objectField(member_field);
                    try writer.write(self.unite_scenes);
                }
            } else if (comptime std.mem.eql(u8, member_field, "dodge") or std.mem.eql(u8, member_field, "revival_art") or std.mem.eql(u8, member_field, "item_art") or std.mem.eql(u8, member_field, "front_projectile") or std.mem.eql(u8, member_field, "other_affinity") or std.mem.eql(u8, member_field, "death_immune") or std.mem.eql(u8, member_field, "airborne") or std.mem.eql(u8, member_field, "effect_offset")) {
                if (@field(self, member_field)) |value| {
                    try writer.objectField(member_field);
                    try writer.write(value);
                }
            } else {
                try writer.objectField(member_field);
                try writer.write(@field(self, member_field));
            }
        }
        try writer.endObject();
    }
};

pub const Encounter = struct {
    pub const ScriptedFinish = struct { after_round: u16, wait_ticks: u16 };
    music: ?enum { normal, boss } = null,
    id: []const u8,
    title: []const u8,
    enemies: []const []const u8,
    experience_per_member: u16,
    positions: []const Position,
    enemy_rows: ?[]const Row = null,
    escape_allowed: bool = true,
    source_slots: ?[]const u8 = null,
    bribe_cost: ?u32 = null,
    battlefield: ?[]const u8 = null,
    reward_policy: enum { standard, none } = .standard,
    scripted_finish: ?ScriptedFinish = null,
    pub fn jsonStringify(self: Encounter, writer: anytype) !void {
        try writer.beginObject();
        inline for (.{ "id", "title", "enemies", "experience_per_member", "positions", "enemy_rows", "escape_allowed", "source_slots" }) |name| {
            try writer.objectField(name);
            try writer.write(@field(self, name));
        }
        if (self.music) |music| {
            try writer.objectField("music");
            try writer.write(music);
        }
        if (self.bribe_cost) |cost| {
            try writer.objectField("bribe_cost");
            try writer.write(cost);
        }
        if (self.battlefield) |id| {
            try writer.objectField("battlefield");
            try writer.write(id);
        }
        if (self.reward_policy != .standard) {
            try writer.objectField("reward_policy");
            try writer.write(self.reward_policy);
        }
        if (self.scripted_finish) |finish| {
            try writer.objectField("scripted_finish");
            try writer.write(finish);
        }
        try writer.endObject();
    }
};
// The existing reserve-save and recruitment-seed layout.
pub const OwnedMemberRecord = field.game_state.OwnedMemberRecord;
pub const Protection = struct {
    hurt_duration: u16,
    ward_return_duration: u16,
    characters: []const struct { id: []const u8, character_type: u8 },
    pairs: []const struct { ward: []const u8, protector: []const u8 },
    pub fn characterType(self: Protection, id: []const u8) ?u8 {
        for (self.characters) |entry| if (std.mem.eql(u8, entry.id, id)) return entry.character_type;
        return null;
    }
    pub fn validate(self: Protection) !void {
        if (self.hurt_duration == 0 or self.hurt_duration > 1024 or self.ward_return_duration == 0 or self.ward_return_duration > 1024) return error.InvalidProtectionData;
        for (self.characters, 0..) |entry, i| {
            if (entry.id.len == 0) return error.InvalidProtectionData;
            for (self.characters[0..i]) |previous| if (std.mem.eql(u8, previous.id, entry.id)) return error.InvalidProtectionData;
        }
        for (self.pairs) |pair| if (self.characterType(pair.ward) == null or self.characterType(pair.protector) == null) return error.InvalidProtectionData;
    }
};
pub const PartyAttackTiming = struct {
    dodge_start_tick: ?u16 = null,
    motion: ?presentation.Motion = null,
    impacts: ?struct { ordinary: []const spell_scene.UniteImpactSpawn, critical: []const spell_scene.UniteImpactSpawn, white: []const struct { at: u16, enabled: bool } = &.{} } = null,
    critical_camera: ?struct { updates: u16, target: @import("battle_camera").Q12Block } = null,
    id: []const u8,
    impact_tick: u16,
    return_tick: u16,
    release_tick: u16,
    target_release_delay: u16,
    pub fn validate(self: PartyAttackTiming) !void {
        if (self.id.len == 0 or self.impact_tick == 0 or self.impact_tick >= self.return_tick or self.return_tick >= self.release_tick or self.release_tick > 1024 or self.target_release_delay == 0 or self.target_release_delay > self.release_tick - self.impact_tick) return error.InvalidPartyAttackTiming;
        if (self.dodge_start_tick) |tick| if (tick == 0 or tick >= self.impact_tick) return error.InvalidPartyAttackTiming;
        if (self.motion) |motion| {
            if (motion.stages.len != 0 or motion.ready_tick != self.return_tick or motion.impact_tick != self.impact_tick or motion.duration != self.release_tick or motion.approach_start >= self.impact_tick or motion.return_start < self.return_tick or motion.return_start >= self.release_tick) return error.InvalidPartyAttackTiming;
            if (@as(u32, motion.approach_start) + motion.approach.ticks > self.impact_tick or @as(u32, motion.return_start) + motion.retreat.ticks > self.release_tick) return error.InvalidPartyAttackTiming;
            for ([_]presentation.Leap{ motion.approach, motion.retreat }) |leap| {
                if (leap.ticks < 2 or leap.ticks > 256 or leap.acceleration_step != 1.0 / 4096.0) return error.InvalidPartyAttackTiming;
                inline for (.{ "x", "y", "z" }) |axis| if (!std.math.isFinite(@field(leap.offset, axis)) or !std.math.isFinite(@field(leap.velocity, axis)) or @abs(@field(leap.offset, axis)) > 4096 or @abs(@field(leap.velocity, axis)) > 4096) return error.InvalidPartyAttackTiming;
            }
        }
        if (self.critical_camera) |request| {
            if (request.updates == 0 or request.updates > 1000 or request.target.focus[0] != 0 or request.target.focus[1] != 0) return error.InvalidPartyAttackTiming;
            request.target.validate() catch return error.InvalidPartyAttackTiming;
        }
        if (self.impacts) |impacts| for ([_][]const spell_scene.UniteImpactSpawn{ impacts.ordinary, impacts.critical }) |spawns| {
            if (spawns.len == 0 or spawns.len > 2) return error.InvalidPartyAttackTiming;
            for (spawns, 0..) |spawn, i| {
                if (!spawn.centered or spawn.at >= self.target_release_delay or (i > 0 and spawn.at < spawns[i - 1].at) or (spawn.animation > 2 and spawn.animation != 18 and spawn.animation != 19)) return error.InvalidPartyAttackTiming;
                for (spawn.offset) |v| if (@abs(@as(i32, v)) > 4096) return error.InvalidPartyAttackTiming;
            }
        };
        if (self.impacts) |impacts| {
            if (impacts.white.len > 8) return error.InvalidPartyAttackTiming;
            for (impacts.white, 0..) |event, i| if (event.at >= self.target_release_delay or (i > 0 and event.at < impacts.white[i - 1].at)) return error.InvalidPartyAttackTiming;
        }
    }
    pub fn jsonStringify(self: PartyAttackTiming, writer: anytype) !void {
        try writer.beginObject();
        inline for (@typeInfo(PartyAttackTiming).@"struct".field_names) |name| {
            if (comptime std.mem.eql(u8, name, "dodge_start_tick") or std.mem.eql(u8, name, "motion") or std.mem.eql(u8, name, "impacts") or std.mem.eql(u8, name, "critical_camera")) {
                if (@field(self, name)) |value| {
                    try writer.objectField(name);
                    try writer.write(value);
                }
            } else {
                try writer.objectField(name);
                try writer.write(@field(self, name));
            }
        }
        try writer.endObject();
    }
};
pub const ItemImpact = struct {
    issued_at: u32,
    recovered_hp: u16,
    cured_poison: bool,
    removed_balloon: bool,
    revived: bool,
};

pub const MedicineAction = struct {
    id: field.items.Id = .medicine,
    timing: MedicineTiming,
    target_interrupted: bool = false,
    actor: usize,
    target: usize,
    targets: u8 = 0,
    interrupted_targets: u8 = 0,
    ticks: u16 = 0,
    amount: u16 = 0,
    amounts: [6]u16 = @splat(0),
    particle_poses: [6]?u16 = @splat(null),
    particle_origins: [6]?Position = @splat(null),
    particle_sprites: [6]?Pose = @splat(null),
    detached_status: ?u3 = null,
    started_at: u32,
    owner_released: bool = false,
    target_released: bool = false,
    pub fn affects(self: MedicineAction, index: usize) bool {
        return if (self.targets == 0) index == self.target else index < 6 and self.targets & (@as(u8, 1) << @intCast(index)) != 0;
    }
    pub fn interrupted(self: MedicineAction, index: usize) bool {
        return self.target_interrupted or (index < 6 and self.interrupted_targets & (@as(u8, 1) << @intCast(index)) != 0);
    }
    pub fn interrupt(self: *MedicineAction, index: usize) void {
        if (!self.affects(index)) return;
        if (self.targets == 0) self.target_interrupted = true else self.interrupted_targets |= @as(u8, 1) << @intCast(index);
    }
};
pub const MedicineTiming = struct {
    id: []const u8,
    target_start: u16,
    pending_tick: u16,
    impact_tick: u16,
    target_release: u16,
    owner_release: u16,
    pub fn validate(self: MedicineTiming) !void {
        if (self.id.len == 0 or self.target_start < 3 or self.target_start > 256 or self.pending_tick != self.target_start + 31 or self.impact_tick != self.pending_tick + 1 or self.target_release != self.target_start + 64 or self.owner_release < self.target_start + 60 or self.owner_release > self.target_start + 315) return error.InvalidMedicineTiming;
    }
};
pub const PartyStrike = struct {
    missed: bool = false,
    dodge_origin: ?Position = null,
    impact_births: [2]?struct { position_q12: [3]i32, center: [2]i8 } = @splat(null),
    origin: ?Position = null,
    critical: bool = false,
    owner_released: bool = false,
    target_down: bool = false,
    actor: usize,
    target: usize,
    ticks: u16 = 0,
    amount: u32 = 0,
    target_released: bool = false,
    returning: bool = false,

    pub fn showsFeedback(self: PartyStrike, timing: PartyAttackTiming) bool {
        const start = if (self.missed) timing.dodge_start_tick orelse return false else timing.impact_tick;
        return self.ticks >= start and self.ticks - start < 30;
    }
};
pub const world_art = @import("battle_world_art.zig");
pub const RoundStart = struct {
    camera_choices: u8,
    selection_delay: u16,
    pub fn validate(self: RoundStart) !void {
        if (self.camera_choices != 3 or self.selection_delay != 30) return error.InvalidRoundStartTiming;
    }
};
pub const Ground = struct {
    pub const tile_size = 32;
    pub const max_axis = 32;

    across: u8,
    down: u8,
    vertices: []const Position,
    tiles: []const u8,

    pub fn validate(self: Ground) !void {
        if (self.across == 0 or self.down == 0 or self.across > max_axis or self.down > max_axis) return error.InvalidBattleGround;
        if (self.vertices.len != (@as(usize, self.across) + 1) * (@as(usize, self.down) + 1)) return error.InvalidBattleGround;
        if (self.tiles.len != @as(usize, self.across) * @as(usize, self.down)) return error.InvalidBattleGround;
        for (self.vertices) |vertex| try validPosition(vertex);
    }

    pub fn tileColumns(self: Ground, width: i32, height: i32) ?usize {
        if (width <= 0 or height <= 0 or @mod(width, tile_size) != 0 or @mod(height, tile_size) != 0) return null;
        const columns: usize = @intCast(@divExact(width, tile_size));
        const rows: u64 = @intCast(@divExact(height, tile_size));
        const capacity = @as(u64, columns) * rows;
        for (self.tiles) |tile| if (tile >= capacity) return null;
        return columns;
    }
};

pub const Battlefield = struct {
    id: []const u8,
    ground: Ground,
    ground_atlas: Rect,
    scenery: []const Scenery = &.{},
};

pub const UniteGraphicPose = struct {
    id: u16,
    sprite: Pose,
    pieces: []const Pose = &.{},
    trail: ?[8]Pose = null,
    white: ?Pose = null,
    flash: ?[3]Pose = null,
    ordinary: ?Pose = null,
    pub fn jsonStringify(self: UniteGraphicPose, writer: anytype) !void {
        try writer.beginObject();
        try writer.objectField("id");
        try writer.write(self.id);
        try writer.objectField("sprite");
        try writer.write(self.sprite);
        if (self.pieces.len != 0) {
            try writer.objectField("pieces");
            try writer.write(self.pieces);
        }
        if (self.white) |pose| {
            try writer.objectField("white");
            try writer.write(pose);
        }
        if (self.flash) |poses| {
            try writer.objectField("flash");
            try writer.write(poses);
        }
        if (self.ordinary) |pose| {
            try writer.objectField("ordinary");
            try writer.write(pose);
        }
        if (self.trail) |poses| {
            try writer.objectField("trail");
            try writer.write(poses);
        }
        try writer.endObject();
    }
};
pub const UniteGraphic = struct {
    id: []const u8,
    record: ?u8 = null,
    poses: []const UniteGraphicPose,
    pub fn jsonStringify(self: UniteGraphic, writer: anytype) !void {
        try writer.beginObject();
        try writer.objectField("id");
        try writer.write(self.id);
        if (self.record) |record| {
            try writer.objectField("record");
            try writer.write(record);
        }
        try writer.objectField("poses");
        try writer.write(self.poses);
        try writer.endObject();
    }
};

pub const Phase = enum { intro, battle_menu, command, target, rune_target, item, item_target, spell, spell_target, unite_target, escaped, run_refused, bribe_refused, confirm_round, resolving, victory, loot, loot_replace, confirm_loot_replace, confirm_leave_loot, defeat, complete, confirm_quit };
pub const BattleOutcome = enum { ongoing, victory, defeat };
/// Result of advancing settlement at a turn checkpoint. Completion hands off to the result UI.
pub const BattleCompletion = enum { resolving, waiting_for_revival, waiting_for_animation, rewards_pending, complete };
pub const TemporaryStats = struct { skill_bonus: i16 = 0, defense_bonus: i16 = 0 };
pub const SpellSelection = struct { index: usize, target: usize };
pub const Action = union(enum) { attack: usize, rune_attack: usize, defend, item: struct { slot: usize, target: usize, id: field.items.Id = .medicine }, spell: SpellSelection, unite: usize, assist: usize };
pub const Coordinator = struct {
    pub const Stage = enum { await_order, select, check, dispatch, round_boundary, round_ready, round_setup, item_wait, victory_wait };
    pub const Choice = union(enum) { no_ready, round_end, actor: usize };
    stage: Stage = .await_order,
    remaining: i32 = 0,
    current_actor: usize,
    cached: ?Choice = null,
    completed: bool = false,
    cross_side_pending: bool = false,
    elapsed: u16 = 1,
    dispatch_count: u8 = 0,
    last_dispatched: ?usize = null,
};
pub const OrderedAttack = struct { actor: usize, started: bool = false, returning: bool = false, target_released: bool = false, target_down: bool = false };
pub const UniteImpactEffect = struct { clip: u8, origin_q12: [3]i32, started_at: ?u32 = null };
pub const Effect = struct { unite_impact_effect: ?UniteImpactEffect = null, motion_origin: ?Position = null, counter_attack: bool = false, instant_knockouts: u16 = 0, spell_hp_loss: u16 = 0, scene: ?spell_scene.Instance = null, drops: ?drops.Instance = null, started_at: u16 = 0, target_down: bool = false, target_released: bool = false, ordered: ?OrderedAttack = null, auxiliary_alive: bool = false, target_reacting: bool = false, owner_released: bool = false, protector: ?usize = null, protector_released: bool = false, protector_down: bool = false, protector_revival_delay: u16 = 0, ward_returning: bool = false, ward_released: bool = false, damage_at_impact: bool = false, returning: bool = false, projectile: bool = false, projectile_alive: bool = false, followup_from: ?usize = null, enemy_special: bool = false, critical: bool = false, rune_attack: bool = false, unite_boundary: bool = false, recovery_rounds: u8 = 0, actor: usize, target: usize, partner: ?usize = null, kind: enum { attack, miss, defend, item, unavailable, cast, unite, sleeping, status_attack, group_order, escape, escape_failed, enemy_magic, enemy_command }, amount: u32 = 0, retargeted_from: ?usize = null, affected: u16 = 0, amounts: [12]u32 = @splat(0), spell: usize = 0, item_id: field.items.Id = .medicine };
pub const Input = struct { up: bool = false, down: bool = false, left: bool = false, right: bool = false, confirm: bool = false, cancel: bool = false, restart: bool = false };

/// Session integration host.  The pointer is opaque to serialisation:
/// a battle digest/fingerprint must not depend on which immutable packet
/// objects are attached, and a `battle.State` is never parsed back from JSON
/// (the save owner captures named fields).  Writing `null` keeps both true.
pub const IntegrationHost = battle_host_systems.Host;

pub const Integration = struct {
    host: *const battle_host_systems.Host,

    pub fn jsonStringify(self: Integration, writer: anytype) !void {
        _ = self;
        try writer.write(null);
    }
};

/// Effect-composition packet handle.  The pointer is opaque to
/// serialisation for the same reason as `Integration`: a digest or fingerprint
/// must not depend on which immutable packet is attached, and a battle state is
/// never parsed back from JSON.  `null` keeps both true.
pub const Effects = struct {
    packet: *const combat_effects.Packet,

    pub fn jsonStringify(self: Effects, writer: anytype) !void {
        _ = self;
        try writer.write(null);
    }
};

pub const UniteReturn = struct { record: ?u8 = null, owner: usize, target: usize, ticks: u16, target_released: bool, target_release: ?u16 = null, handoff_at: u32 };
pub const UniteReactionState = struct { record: u8, variant: u8 = 0, status_applied: u8 = 0, signals_applied: u8 = 0, sound_cursor: u8 = 0, started_at: u32, origin_q12: [3]i32, home_q12: [3]i32, knockout_ticks: u16 = 0 };
pub const UniteScenePlayback = struct {
    owner: u8,
    record: u8,
    trigger: u8,
    started_at: ?u32 = null,
    updated_at: u32,
    orbit_origin_q12: [3]i32 = @splat(0),
    orbit_velocity_x_q12: i32 = 0,
    pending_sound: ?u16 = null,
};

// Original percent scaling wraps the maximum 32767 roll back to zero.
pub fn antSpecial(random: u15) bool {
    return systems.statusPercent(random) >= 77;
}

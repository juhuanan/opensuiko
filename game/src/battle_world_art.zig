const std = @import("std");
const battle = @import("battle.zig");
const p = battle.presentation;
pub const Frame = struct { pose: u16, ticks: u16 };
pub const Sample = struct { position: p.Vec3, pose: u16, offset: [2]i16 };
pub const StrikeTracks = struct { unhurt: []const Sample, after_hit: []const Sample };
pub const ExtraStrike = struct {
    id: []const u8,
    targets: []const StrikeTracks,
    target_hurt: ?[]const []const Sample = null,
    restored_target_hurt: ?[]const []const Sample = null,
    pub fn jsonStringify(self: ExtraStrike, writer: anytype) !void {
        try writer.beginObject();
        try writer.objectField("id");
        try writer.write(self.id);
        try writer.objectField("targets");
        try writer.write(self.targets);
        if (self.target_hurt) |tracks| {
            try writer.objectField("target_hurt");
            try writer.write(tracks);
        }
        if (self.restored_target_hurt) |tracks| {
            try writer.objectField("restored_target_hurt");
            try writer.write(tracks);
        }
        try writer.endObject();
    }
};
pub const Actor = struct {
    impact_offsets: ?[]const [2]i8 = null,
    foot_offset_y: i16,
    id: []const u8,
    poses: []const battle.Pose,
    animations: []const []const Frame,
    attack: []const Sample,
    hurt: []const Sample,
    cover: []const Sample,
    covered_attack: []const Sample,
    settled_attack: []const Sample,
    pub fn jsonStringify(self: Actor, writer: anytype) !void {
        try writer.beginObject();
        inline for (@typeInfo(Actor).@"struct".field_names) |name| {
            if (comptime std.mem.eql(u8, name, "impact_offsets")) {
                if (self.impact_offsets) |offsets| {
                    try writer.objectField(name);
                    try writer.write(offsets);
                }
            } else {
                try writer.objectField(name);
                try writer.write(@field(self, name));
            }
        }
        try writer.endObject();
    }
};
pub const CTracks = struct {
    hero_attacks: [2]StrikeTracks,
    projectile_start_tick: u16,
    projectiles: [2][2][]const Sample,
    misses: ?struct { dodges: [2][]const Sample, projectiles: [2][2][]const Sample } = null,
    low_hp: ?struct { target: []const u8, dodge: []const Sample, projectiles: [2][]const Sample, miss_projectiles: [2][]const Sample } = null,
    extra_party_attacks: []const ExtraStrike = &.{},
    repeated_hurt: ?[2][]const Sample = null,
    pub fn attacks(self: CTracks, id: []const u8) ?[2]StrikeTracks {
        if (std.mem.eql(u8, id, "hero")) return self.hero_attacks;
        for (self.extra_party_attacks) |entry| if (std.mem.eql(u8, entry.id, id)) return entry.targets[0..2].*;
        return null;
    }
    pub fn hasTargetReactions(self: CTracks) bool {
        for (self.extra_party_attacks) |entry| if (entry.target_hurt != null) return true;
        return false;
    }
    pub fn targetReaction(self: CTracks, id: []const u8, target: usize, fallback: []const Sample) []const Sample {
        for (self.extra_party_attacks) |entry| if (std.mem.eql(u8, entry.id, id)) {
            if (entry.target_hurt) |tracks| return tracks[target];
        };
        return fallback;
    }
    pub fn jsonStringify(self: CTracks, writer: anytype) !void {
        try writer.beginObject();
        inline for (@typeInfo(CTracks).@"struct".field_names) |name| {
            if (comptime std.mem.eql(u8, name, "misses") or std.mem.eql(u8, name, "low_hp") or std.mem.eql(u8, name, "repeated_hurt")) {
                if (@field(self, name)) |tracks| {
                    try writer.objectField(name);
                    try writer.write(tracks);
                }
            } else if (comptime std.mem.eql(u8, name, "extra_party_attacks")) {
                if (self.extra_party_attacks.len != 0) {
                    try writer.objectField(name);
                    try writer.write(self.extra_party_attacks);
                }
            } else {
                try writer.objectField(name);
                try writer.write(@field(self, name));
            }
        }
        try writer.endObject();
    }
};
pub const Data = struct {
    schema: []const u8,
    region: []const u8,
    encounter: []const u8,
    atlas: []const u8,
    background: []const u8,
    atlas_width: i32,
    atlas_height: i32,
    actors: []const Actor,
    scenery: []const battle.Scenery,
    formation_slots: [6]p.Vec3,
    enemy_positions: []const p.Vec3,
    camera: p.Camera,
    sprite_scale: f32,
    medicine_particles: []const [4]p.Vec3,
    c_tracks: ?CTracks = null,
    extra_party_attacks: []const ExtraStrike = &.{},
    pub fn jsonStringify(self: Data, writer: anytype) !void {
        // Keep existing B content/save identities when C presentation is absent.
        try writer.beginObject();
        inline for (@typeInfo(Data).@"struct".field_names) |name| {
            if (comptime std.mem.eql(u8, name, "c_tracks")) {
                if (self.c_tracks) |tracks| {
                    try writer.objectField(name);
                    try writer.write(tracks);
                }
            } else if (comptime std.mem.eql(u8, name, "extra_party_attacks")) {
                if (self.extra_party_attacks.len != 0) {
                    try writer.objectField(name);
                    try writer.write(self.extra_party_attacks);
                }
            } else {
                try writer.objectField(name);
                try writer.write(@field(self, name));
            }
        }
        try writer.endObject();
    }
    pub fn attackTracks(self: Data, id: []const u8, target: usize) ?StrikeTracks {
        if (target >= self.enemy_positions.len) return null;
        if (self.c_tracks) |tracks| {
            const attacks = tracks.attacks(id) orelse return null;
            return attacks[target];
        }
        for (self.extra_party_attacks) |entry| if (std.mem.eql(u8, entry.id, id)) return entry.targets[target];
        if (std.mem.eql(u8, id, "hero")) return .{ .unhurt = self.actors[0].attack, .after_hit = self.actors[0].attack };
        return null;
    }
    pub fn targetReaction(self: Data, id: []const u8, target: usize, restored: bool) []const Sample {
        const fallback = self.actors[6 + target].hurt;
        if (self.c_tracks) |tracks| return tracks.targetReaction(id, target, fallback);
        for (self.extra_party_attacks) |entry| if (std.mem.eql(u8, entry.id, id)) {
            if (restored) if (entry.restored_target_hurt) |targets| return targets[target];
            if (entry.target_hurt) |targets| return targets[target];
        };
        return fallback;
    }
    pub fn validate(self: Data) !void {
        const c = self.c_tracks != null;
        const impact_schema = std.mem.eql(u8, self.schema, if (c) "suikoden-world-battle-art/13" else "suikoden-world-battle-art/12");
        if (c and self.extra_party_attacks.len != 0) return error.InvalidWorldBattleArt;
        if (!impact_schema and !std.mem.eql(u8, self.schema, if (c) (if (self.c_tracks.?.hasTargetReactions()) "suikoden-world-battle-art/10" else if (self.c_tracks.?.extra_party_attacks.len != 0) "suikoden-world-battle-art/9" else if (self.c_tracks.?.low_hp != null) "suikoden-world-battle-art/8" else if (self.c_tracks.?.misses != null) "suikoden-world-battle-art/7" else "suikoden-world-battle-art/6") else if (self.extra_party_attacks.len != 0) "suikoden-world-battle-art/11" else "suikoden-world-battle-art/5")) return error.UnsupportedWorldBattleArt;
        if (!std.mem.eql(u8, self.region, if (c) "region_c" else "region_b") or !std.mem.eql(u8, self.encounter, if (c) "world_c_encounter_1" else "world_b_encounter_4") or !std.mem.eql(u8, self.atlas, "actors.png") or !std.mem.eql(u8, self.background, "floor.png") or self.actors.len != (if (c) @as(usize, 8) else 7) or self.scenery.len > 32 or self.enemy_positions.len != (if (c) @as(usize, 2) else 1)) return error.InvalidWorldBattleArt;
        if (self.atlas_width <= 0 or self.atlas_width > 4096 or self.atlas_height <= 0 or self.atlas_height > 4096 or !std.math.isFinite(self.sprite_scale) or self.sprite_scale <= 0 or self.sprite_scale > 4) return error.InvalidWorldBattleArt;
        for (self.camera.transform) |row| for (row) |value| if (!std.math.isFinite(value) or @abs(value) > 32768) return error.InvalidWorldBattleArt;
        for ([_]f32{ self.camera.focal_length, self.camera.center_x, self.camera.center_y }) |value| if (!std.math.isFinite(value) or @abs(value) > 32768) return error.InvalidWorldBattleArt;
        if (self.camera.focal_length <= 0) return error.InvalidWorldBattleArt;
        const ids: []const []const u8 = if (c) &.{ "hero", "gremio", "pahn", "viktor", "yam_koo", "tai_ho", "kobold_type_2", "kobold_type_2" } else &.{ "hero", "gremio", "pahn", "viktor", "yam_koo", "tai_ho", "roc" };
        for (self.actors, ids, 0..) |actor, id, index| {
            if (impact_schema and actor.impact_offsets == null) return error.InvalidWorldBattleArt;
            if (actor.impact_offsets) |offsets| if (offsets.len != actor.poses.len) return error.InvalidWorldBattleArt;
            if (!std.mem.eql(u8, actor.id, id) or actor.poses.len == 0 or actor.poses.len > 256 or actor.animations.len < 4 or actor.animations.len > 64) return error.InvalidWorldBattleArt;
            if (@abs(@as(i32, actor.foot_offset_y)) > 128) return error.InvalidWorldBattleArt;
            for (actor.poses) |pose| try self.poseBounds(pose);
            for (actor.animations) |clip| {
                if (clip.len > 256) return error.InvalidWorldBattleArt;
                for (clip) |frame| if (frame.pose >= actor.poses.len or frame.ticks == 0 or frame.ticks > 256) return error.InvalidWorldBattleArt;
            }
            for ([_]usize{ 0, 2, 3 }) |clip| if (actor.animations[clip].len == 0) return error.InvalidWorldBattleArt;
            if (index < 6) {
                if (actor.animations.len <= 15) return error.InvalidWorldBattleArt;
                for ([_]usize{ 13, 14, 15 }, ([6][3]u32{ .{ 18, 1, 10 }, .{ 21, 1, 20 }, .{ 15, 1, 19 }, .{ 11, 1, 11 }, .{ 10, 1, 10 }, .{ 10, 1, 10 } })[index]) |clip, expected| {
                    var total: u32 = 0;
                    for (actor.animations[clip]) |frame| total += frame.ticks;
                    if (total != expected) return error.InvalidWorldBattleArt;
                }
            }
            const attack: usize = if (c) (if (index >= 6) 116 else 0) else if (index == 0) 128 else if (index == 6) 144 else 0;
            const hurt: usize = if (c) (if (index < 2 or index >= 6) 36 else 0) else if (index == 0) 13 else if (index == 6) 36 else 0;
            if (actor.attack.len != attack or actor.hurt.len != hurt or actor.cover.len != (if (c) @as(usize, 0) else if (index == 0) @as(usize, 72) else if (index == 1) @as(usize, 61) else 0) or actor.covered_attack.len != (if (c) @as(usize, 0) else if (index == 0) @as(usize, 128) else if (index == 6) @as(usize, 144) else 0)) return error.InvalidWorldBattleArt;
            if (actor.settled_attack.len != (if (!c and index == 6) @as(usize, 144) else 0)) return error.InvalidWorldBattleArt;
            for ([_][]const Sample{ actor.attack, actor.hurt, actor.cover, actor.covered_attack, actor.settled_attack }) |track| for (track) |sample| {
                try positionBounds(sample.position);
                if (sample.pose >= actor.poses.len or @abs(@as(i32, sample.offset[0])) > 128 or @abs(@as(i32, sample.offset[1])) > 128) return error.InvalidWorldBattleArt;
            };
        }
        if (self.medicine_particles.len != (if (c) @as(usize, 0) else 29)) return error.InvalidWorldBattleArt;
        if (self.extra_party_attacks.len > 6) return error.InvalidWorldBattleArt;
        for (self.extra_party_attacks, 0..) |entry, index| {
            const member = for (self.actors[0..6], 0..) |actor, member| {
                if (std.mem.eql(u8, actor.id, entry.id)) break member;
            } else return error.InvalidWorldBattleArt;
            if (entry.targets.len != self.enemy_positions.len) return error.InvalidWorldBattleArt;
            for (self.extra_party_attacks[0..index]) |previous| if (std.mem.eql(u8, previous.id, entry.id)) return error.InvalidWorldBattleArt;
            const reactions = entry.target_hurt orelse return error.InvalidWorldBattleArt;
            const restored = entry.restored_target_hurt orelse return error.InvalidWorldBattleArt;
            if (restored.len != reactions.len or reactions.len != entry.targets.len) return error.InvalidWorldBattleArt;
            for (restored, 0..) |track, target_index| {
                if (track.len != reactions[target_index].len) return error.InvalidWorldBattleArt;
                for (track) |sample| try self.sampleBounds(sample, self.actors[6 + target_index]);
            }
            for (entry.targets, reactions, 0..) |target, reaction, target_index| {
                if (target.unhurt.len == 0 or target.unhurt.len > 4095 or target.after_hit.len != target.unhurt.len or reaction.len == 0 or reaction.len > 256) return error.InvalidWorldBattleArt;
                for (target.unhurt) |sample| try self.sampleBounds(sample, self.actors[member]);
                for (target.after_hit) |sample| try self.sampleBounds(sample, self.actors[member]);
                for (reaction) |sample| try self.sampleBounds(sample, self.actors[6 + target_index]);
            }
        }
        if (self.c_tracks) |tracks| {
            if (tracks.extra_party_attacks.len > 5) return error.InvalidWorldBattleArt;
            for (tracks.extra_party_attacks, 0..) |entry, index| {
                if (entry.targets.len != 2 or entry.restored_target_hurt != null) return error.InvalidWorldBattleArt;
                if (entry.target_hurt) |targets| if (targets.len != 2) return error.InvalidWorldBattleArt;
                const member = for (self.actors[1..6]) |actor| {
                    if (std.mem.eql(u8, actor.id, entry.id)) break actor;
                } else return error.InvalidWorldBattleArt;
                for (tracks.extra_party_attacks[0..index]) |previous| if (std.mem.eql(u8, entry.id, previous.id)) return error.InvalidWorldBattleArt;
                if (tracks.low_hp == null or tracks.repeated_hurt == null) return error.InvalidWorldBattleArt;
                for (entry.targets) |target| {
                    if (target.unhurt.len == 0 or target.unhurt.len > 4095 or target.after_hit.len != target.unhurt.len) return error.InvalidWorldBattleArt;
                    for (target.unhurt) |sample| try self.sampleBounds(sample, member);
                    for (target.after_hit) |sample| try self.sampleBounds(sample, member);
                }
                if (entry.target_hurt) |targets| {
                    for (targets) |track| {
                        if (track.len == 0 or track.len > 256) return error.InvalidWorldBattleArt;
                        for (track) |sample| try self.sampleBounds(sample, self.actors[6]);
                    }
                } else if (tracks.hasTargetReactions()) return error.InvalidWorldBattleArt;
            }
            if (tracks.repeated_hurt) |targets| {
                if (tracks.extra_party_attacks.len == 0) return error.InvalidWorldBattleArt;
                for (targets, 0..) |track, index| {
                    if (track.len != 36) return error.InvalidWorldBattleArt;
                    for (track) |sample| try self.sampleBounds(sample, self.actors[index]);
                }
            }
            if (tracks.projectile_start_tick != 41) return error.InvalidWorldBattleArt;
            for (tracks.hero_attacks) |entry| for ([_][]const Sample{ entry.unhurt, entry.after_hit }) |track| {
                if (track.len != 128) return error.InvalidWorldBattleArt;
                for (track) |sample| try self.sampleBounds(sample, self.actors[0]);
            };
            for (tracks.projectiles) |targets| for (targets) |track| {
                if (track.len != 17) return error.InvalidWorldBattleArt;
                for (track) |sample| try self.sampleBounds(sample, self.actors[6]);
            };
            if (tracks.misses) |misses| {
                for (misses.dodges, 0..) |track, index| {
                    if (track.len != (if (index == 0) @as(usize, 113) else 118)) return error.InvalidWorldBattleArt;
                    for (track) |sample| try self.sampleBounds(sample, self.actors[index]);
                }
                for (misses.projectiles) |targets| for (targets) |track| {
                    if (track.len != 47) return error.InvalidWorldBattleArt;
                    for (track) |sample| try self.sampleBounds(sample, self.actors[6]);
                };
            }
            if (tracks.low_hp) |low| {
                if (tracks.misses == null or !std.mem.eql(u8, low.target, "gremio") or low.dodge.len != 118) return error.InvalidWorldBattleArt;
                for (low.dodge) |sample| try self.sampleBounds(sample, self.actors[1]);
                for (low.projectiles, low.miss_projectiles) |hit, miss| {
                    if (hit.len != 17 or miss.len != 47) return error.InvalidWorldBattleArt;
                    for (hit) |sample| try self.sampleBounds(sample, self.actors[6]);
                    for (miss) |sample| try self.sampleBounds(sample, self.actors[6]);
                }
            }
        }
        for (self.medicine_particles) |frame| for (frame) |position| try positionBounds(position);
        for (self.formation_slots) |home| try positionBounds(home);
        for (self.enemy_positions) |home| try positionBounds(home);
        for (self.scenery) |entry| {
            try positionBounds(entry.position);
            try self.poseBounds(entry.sprite);
        }
    }
    fn sampleBounds(self: Data, sample: Sample, actor: Actor) !void {
        _ = self;
        try positionBounds(sample.position);
        if (sample.pose >= actor.poses.len or @abs(@as(i32, sample.offset[0])) > 128 or @abs(@as(i32, sample.offset[1])) > 128) return error.InvalidWorldBattleArt;
    }
    fn poseBounds(self: Data, pose: battle.Pose) !void {
        const r = pose.rect;
        if (r.x < 0 or r.y < 0 or r.w <= 0 or r.h <= 0 or r.w > 512 or r.h > 512 or r.x > self.atlas_width - r.w or r.y > self.atlas_height - r.h or @abs(@as(i32, pose.anchor_x)) > 512 or @abs(@as(i32, pose.anchor_y)) > 512) return error.InvalidWorldBattleArt;
    }
    pub fn validateAtlas(self: Data, width: i32, height: i32) !void {
        if (width != self.atlas_width or height != self.atlas_height) return error.InvalidWorldBattleArt;
    }
    pub fn bind(self: Data, base: battle.Content, index: usize, members: []const battle.Member, formation: [6]u8) !battle.Content {
        try self.validate();
        if (members.len != 6 or index >= base.encounters.len or !std.mem.eql(u8, base.encounters[index].id, self.encounter)) return error.UnsupportedWorldBattlePresentation;
        for (members, 0..) |member, i| if (!std.mem.eql(u8, member.id, self.actors[i].id) or formation[i] != i) return error.UnsupportedWorldBattlePresentation;
        if (base.encounters[index].positions.len != self.enemy_positions.len or !std.meta.eql(self.formation_slots, base.formation_slots)) return error.InvalidWorldBattleArt;
        for (self.enemy_positions, base.encounters[index].positions) |expected, actual| if (!std.meta.eql(expected, actual)) return error.InvalidWorldBattleArt;
        const enemy = base.enemyIndex(if (self.c_tracks != null) "kobold_type_2" else "roc") orelse return error.InvalidWorldBattleArt;
        if (self.c_tracks != null) {
            const timing = base.enemies[enemy].front_projectile orelse return error.InvalidWorldBattleArt;
            if (timing.impact_tick != 56 or timing.target_release_tick != 92 or timing.owner_release_tick != 116 or base.enemies[enemy].knockout_ticks != 94) return error.InvalidWorldBattleArt;
            if (self.c_tracks.?.misses) |misses| for (misses.dodges, 0..) |track, member| {
                const release = for (timing.dodges) |dodge| {
                    if (std.mem.eql(u8, dodge.id, self.actors[member].id)) break dodge.target_release_tick;
                } else return error.InvalidWorldBattleArt;
                if (release != track.len + 1) return error.InvalidWorldBattleArt;
            };
        } else {
            const timing = base.enemies[enemy].ordinary_timing orelse return error.InvalidWorldBattleArt;
            if (timing.impact_tick != 49 or timing.return_tick != 50 or timing.duration != 145 or timing.target_release_delay != 13 or base.enemies[enemy].knockout_ticks != 94) return error.InvalidWorldBattleArt;
        }
        const hero = for (base.party_attacks) |entry| {
            if (std.mem.eql(u8, entry.id, "hero")) break entry;
        } else return error.InvalidWorldBattleArt;
        if (hero.impact_tick != 73 or hero.return_tick != 97 or hero.release_tick != 129 or hero.target_release_delay != 36) return error.InvalidWorldBattleArt;
        if (self.c_tracks) |tracks| for (tracks.extra_party_attacks) |entry| {
            const timing = for (base.party_attacks) |clock| {
                if (std.mem.eql(u8, entry.id, clock.id)) break clock;
            } else return error.InvalidWorldBattleArt;
            for (entry.targets, 0..) |target, target_index| {
                if (target.unhurt.len + 1 != timing.release_tick) return error.InvalidWorldBattleArt;
                const reaction = tracks.targetReaction(entry.id, target_index, self.actors[6 + target_index].hurt);
                if (reaction.len != timing.target_release_delay) return error.InvalidWorldBattleArt;
            }
        };
        for (self.extra_party_attacks) |entry| {
            const timing = for (base.party_attacks) |clock| {
                if (std.mem.eql(u8, entry.id, clock.id)) break clock;
            } else return error.InvalidWorldBattleArt;
            for (entry.targets, entry.target_hurt.?) |target, reaction| {
                if (target.unhurt.len + 1 != timing.release_tick or reaction.len != timing.target_release_delay) return error.InvalidWorldBattleArt;
            }
        }
        var result = base;
        result.enemies = base.enemies[enemy .. enemy + 1];
        result.encounters = base.encounters[index .. index + 1];
        result.world_art = self;
        result.atlas = self.atlas;
        result.background = self.background;
        result.presentation_ready = true;
        result.scenery = self.scenery;
        result.formation_slots = self.formation_slots;
        result.camera = self.camera;
        result.sprite_scale = self.sprite_scale;
        // Party profiles retain gameplay/preparation metadata; every displayed B pose comes from this validated atlas.
        try result.validate();
        return result;
    }
};
fn positionBounds(v: p.Vec3) !void {
    for ([_]f32{ v.x, v.y, v.z }) |x| if (!std.math.isFinite(x) or @abs(x) > 4096) return error.InvalidWorldBattleArt;
}
pub fn load(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Data) {
    if (bytes.len > 512 * 1024) return error.InvalidWorldBattleArt;
    const version = try std.json.parseFromSlice(struct { schema: []const u8 }, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer version.deinit();
    if (!std.mem.eql(u8, version.value.schema, "suikoden-world-battle-art/13") and !std.mem.eql(u8, version.value.schema, "suikoden-world-battle-art/12") and !std.mem.eql(u8, version.value.schema, "suikoden-world-battle-art/11") and !std.mem.eql(u8, version.value.schema, "suikoden-world-battle-art/5") and !std.mem.eql(u8, version.value.schema, "suikoden-world-battle-art/6") and !std.mem.eql(u8, version.value.schema, "suikoden-world-battle-art/7") and !std.mem.eql(u8, version.value.schema, "suikoden-world-battle-art/8") and !std.mem.eql(u8, version.value.schema, "suikoden-world-battle-art/9") and !std.mem.eql(u8, version.value.schema, "suikoden-world-battle-art/10")) return error.UnsupportedWorldBattleArt;
    const parsed = try std.json.parseFromSlice(Data, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    try parsed.value.validate();
    return parsed;
}
fn clipPose(actor: Actor, clip_index: usize, tick: u32) u16 {
    const clip = actor.animations[clip_index];
    var total: u32 = 0;
    for (clip) |frame| total += frame.ticks;
    var left = tick % total;
    for (clip) |frame| {
        if (left < frame.ticks) return frame.pose;
        left -= frame.ticks;
    }
    unreachable;
}
fn oncePose(actor: Actor, index: usize, tick: u32) u16 {
    var left = tick;
    for (actor.animations[index]) |frame| {
        if (left < frame.ticks) return frame.pose;
        left -= frame.ticks;
    }
    return actor.animations[index][actor.animations[index].len - 1].pose;
}
pub const Visual = struct { sample: Sample, visible: bool = true };
fn strikeSample(data: Data, state: *const battle.State, strike: battle.PartyStrike, track: []const Sample) ?Sample {
    if (strike.ticks == 0 and strike.origin == null) return null;
    const at = @max(1, strike.ticks);
    if (at > track.len) return null;
    var sample = track[at - 1];
    if (strike.origin) |origin| {
        const motion = state.partyAttackTiming(strike.actor).?.motion.?;
        var target = data.enemy_positions[strike.target - state.partyCount()];
        // The selected source leaps use target XY with an absolute Z operand.
        target.z = 0;
        sample.position = p.actorPositionFrom(origin, data.formation_slots[state.formationSlot(strike.actor)], target, motion, strike.ticks);
    }
    return sample;
}
fn dodgeSample(data: Data, state: *const battle.State, index: usize) ?Sample {
    for (state.party_strikes) |maybe| if (maybe) |strike| {
        if (!strike.missed or strike.target != index or strike.target_released) continue;
        const origin = strike.dodge_origin orelse continue;
        const timing = state.partyAttackTiming(strike.actor).?;
        const spec = state.enemy(index - state.partyCount()).dodge.?;
        const elapsed = strike.ticks - timing.dodge_start_tick.?;
        var back = p.offset(origin, spec.back.offset);
        back.z = spec.back.offset.z;
        var home = p.offset(data.enemy_positions[index - 6], spec.retreat.offset);
        home.z = spec.retreat.offset.z;
        const returning = spec.retreatStart(timing);
        const position = if (strike.ticks < returning) p.leap(origin, back, spec.back, elapsed + 1) else p.leap(back, home, spec.retreat, strike.ticks - returning + 1);
        const actor = data.actors[index];
        const pose = if (elapsed < spec.back.ticks) oncePose(actor, spec.animation, elapsed + 1) else clipPose(actor, 0, elapsed - spec.back.ticks);
        return .{ .position = position, .pose = pose, .offset = .{ 0, 0 } };
    };
    return null;
}
fn cActorSample(data: Data, state: *const battle.State, index: usize) Visual {
    const actor = data.actors[index];
    const home = if (index < 6) data.formation_slots[state.formationSlot(index)] else data.enemy_positions[index - 6];
    const stance: usize = if (index >= 6) 0 else if (state.partyInactive(index)) 3 else if (state.hp(index) < state.progress.party[index].max_hp / 4) 2 else 0;
    var result: Visual = .{ .sample = .{ .position = home, .pose = clipPose(actor, stance, state.presentation_tick), .offset = .{ 0, 0 } } };
    if (index >= 6) if (state.dodge_idle_at[index - 6]) |started| {
        result.sample.pose = clipPose(actor, 0, state.presentation_tick - started);
    };
    if (index < 2) if (state.front_hurt_at[index]) |started| {
        const elapsed = state.presentation_tick -% started;
        if (elapsed < actor.hurt.len) {
            const track = if (state.front_hurt_repeated[index]) data.c_tracks.?.repeated_hurt.?[index] else actor.hurt;
            result.sample = track[elapsed];
        } else result.sample.offset = .{ 0, -2 };
    };
    if (index < 6) if (state.formation_shifts[index]) |shift| {
        const elapsed = state.presentation_tick -% shift.started_at;
        if (elapsed < 20) {
            const from = data.formation_slots[shift.from_slot];
            inline for (.{ "x", "y", "z" }) |axis| {
                const start = @field(from, axis);
                const velocity = @trunc((@field(home, axis) - start) * 4096 / 20) / 4096;
                @field(result.sample.position, axis) = start + velocity * @as(f32, @floatFromInt(elapsed));
            }
        }
    };
    if (index >= 6) if (state.front_projectiles[index - 6]) |shot| {
        if (shot.ticks > 0 and shot.ticks <= actor.attack.len) result.sample = actor.attack[shot.ticks - 1];
    };
    if (index < 2) for (state.front_projectiles[0..2]) |maybe| {
        const shot = maybe orelse continue;
        if (shot.target != index or shot.dodge_release == null or shot.target_released) continue;
        const track = if (shot.low_hp_target) data.c_tracks.?.low_hp.?.dodge else data.c_tracks.?.misses.?.dodges[index];
        if (shot.ticks > 0 and shot.ticks <= track.len) {
            const retained_offset = result.sample.offset;
            result.sample = track[shot.ticks - 1];
            for (0..2) |axis| result.sample.offset[axis] += retained_offset[axis];
        }
    };
    for (state.party_strikes) |maybe| if (maybe) |strike| {
        const timing = state.partyAttackTiming(strike.actor).?;
        if (index == strike.actor and !strike.owner_released) {
            const tracks = data.attackTracks(actor.id, strike.target - 6).?;
            const track = if (state.front_hurt_at[index] != null) tracks.after_hit else tracks.unhurt;
            if (strikeSample(data, state, strike, track)) |sample| result.sample = sample;
        }
        if (index == strike.target and !strike.missed) {
            const hurt_end = timing.impact_tick + timing.target_release_delay;
            if (strike.ticks >= timing.impact_tick and strike.ticks < hurt_end) {
                const reaction = data.targetReaction(state.progress.party[strike.actor].id, index - 6, false);
                result.sample = reaction[strike.ticks - timing.impact_tick];
            }
            if (strike.target_down) {
                const death = strike.ticks - hurt_end + 1;
                result.sample.pose = actor.animations[if (death == 1) @as(usize, 0) else 3][0].pose;
                result.visible = death < 94;
            }
        }
    };
    if (index >= 6 and state.hp(index) == 0 and !state.coordinatorLocked(index)) {
        result.sample.pose = actor.animations[3][0].pose;
        result.visible = false;
    }
    return result;
}
// shortcut: first-round single-Roc samples; export additional tracks before admitting other bound routes.
pub fn actorSample(data: Data, state: *const battle.State, index: usize) Visual {
    if (state.revivalAge(index)) |age| {
        const spec = state.rules.automatic_revival.?;
        const instance = state.party_knockouts[index].revival.?;
        const pose = if (age < spec.recovery_start) oncePose(data.actors[index], 3, age) else oncePose(data.actors[index], 2, age - spec.recovery_start);
        return .{ .sample = .{ .pose = pose, .position = instance.origin, .offset = instance.screen_offset } };
    }
    if (state.unite_vm.pose(index)) |pose| return .{ .sample = .{ .pose = pose, .offset = .{ 0, 0 }, .position = state.uniteActorPosition(index).? }, .visible = state.unite_vm.actors[index].visible };
    if (dodgeSample(data, state, index)) |sample| return .{ .sample = sample };
    if (index < state.partyCount() and !state.uniteMemberWaiting(index) and (state.activeUniteMember(index) or state.uniteReturnFor(index) != null)) {
        if (state.uniteTrack(index)) |track| {
            const motion = track.motion;
            var tick = state.attackFrameTick(index);
            for (track.attack) |frame| {
                if (tick >= frame.ticks) {
                    tick -= frame.ticks;
                    continue;
                }
                if (frame.source_pose) |pose| if (pose < data.actors[index].poses.len) {
                    const target = if (state.uniteReturnFor(index)) |tail| tail.target else state.active.?.target;
                    return .{ .sample = .{
                        .pose = pose,
                        .offset = .{ 0, 0 },
                        .position = p.actorPosition(data.formation_slots[state.formationSlot(index)], data.enemy_positions[target - state.partyCount()], motion, state.animationTick(index)),
                    } };
                };
                break;
            }
        }
    }
    if (data.c_tracks != null) return cActorSample(data, state, index);
    if (data.extra_party_attacks.len != 0) {
        // Preserve the verified B idle/cover/item paths while replacing per-owner strikes.
        var legacy = data;
        legacy.extra_party_attacks = &.{};
        var result = actorSample(legacy, state, index);
        const actor = data.actors[index];
        for (state.party_strikes) |maybe| {
            const strike = maybe orelse continue;
            const timing = state.partyAttackTiming(strike.actor).?;
            if (index == strike.actor and !strike.owner_released) {
                const tracks = data.attackTracks(actor.id, strike.target - 6).?;
                const after_hit = state.front_hurt_at[index] != null or (index == 0 and state.hero_reaction_offset);
                const track = if (after_hit) tracks.after_hit else tracks.unhurt;
                if (strikeSample(data, state, strike, track)) |sample| result.sample = sample;
            }
            if (index == strike.target and !strike.missed) {
                result.visible = true;
                const hurt_end = timing.impact_tick + timing.target_release_delay;
                if (strike.ticks >= timing.impact_tick and strike.ticks < hurt_end) {
                    const reaction = data.targetReaction(state.progress.party[strike.actor].id, index - 6, state.roc_home_restored);
                    result.sample = reaction[strike.ticks - timing.impact_tick];
                }
                if (strike.target_down) {
                    const death = strike.ticks - hurt_end + 1;
                    result.sample.position = data.enemy_positions[index - 6];
                    result.sample.offset = .{ 0, 0 };
                    result.sample.pose = if (death == 1) actor.animations[0][0].pose else actor.animations[3][0].pose;
                    result.visible = death < state.enemy(index - 6).knockout_ticks.?;
                }
            }
        }
        return result;
    }
    const actor = data.actors[index];
    const home = if (index < 6) data.formation_slots[index] else data.enemy_positions[0];
    const low = index < 6 and state.hp(index) < state.progress.party[index].max_hp / 4;
    var result: Visual = .{ .sample = .{ .position = home, .pose = clipPose(actor, if (index < 6 and state.partyInactive(index)) 3 else if (low) 2 else 0, state.presentation_tick), .offset = .{ 0, 0 } } };
    const covered = state.roc_cover;
    const effect_tick = state.effectTicks();
    if (covered and (index == 0 or index == 1)) {
        var cover_tick = effect_tick;
        if (state.active) |effect| if (effect.target == index and effect.protector_revival_delay != 0) {
            const old_return = state.protectorReleaseTick(effect) + @intFromBool(effect.protector.? > effect.target);
            if (effect_tick >= old_return) cover_tick = if (effect_tick < old_return + effect.protector_revival_delay) old_return - 1 else effect_tick - effect.protector_revival_delay;
        };
        if (cover_tick > 0 and cover_tick <= actor.cover.len) {
            result.sample = actor.cover[cover_tick - 1];
            return result;
        }
        if (index == 1) result.sample.offset = .{ 0, -2 };
    }
    if (index == 0 and state.hero_reaction_offset) result.sample.offset = .{ 0, -2 };
    if (battle.layout.itemAnimation(state, index)) |sample| {
        result.sample.pose = switch (sample.clip) {
            .idle => clipPose(actor, 0, sample.elapsed),
            .prepare => oncePose(actor, 13, sample.elapsed),
            .hold => oncePose(actor, 14, sample.elapsed),
            .recover => oncePose(actor, 15, sample.elapsed),
        };
        return result;
    }
    if (index != 0 and index != 6) return result;
    if (index == 0) {
        if (state.party_strikes[0]) |strike| {
            if (strikeSample(data, state, strike, if (covered) actor.covered_attack else actor.attack)) |sample| result.sample = sample;
            return result;
        }
        if (state.active) |effect| {
            if (effect.actor == 6 and effect.protector == null and effect_tick >= 49 and effect_tick < 62) {
                result.sample = actor.hurt[effect_tick - 49];
                if (state.roc_attack_from_settled and effect_tick < 51) result.sample.offset = .{ 0, -2 };
            }
        }
    } else {
        if (state.roc_idle_at) |started| {
            result.sample.position.z = if (state.roc_home_restored) home.z else 0;
            result.sample.pose = clipPose(actor, 0, state.presentation_tick - started);
        }
        if (state.phase == .defeat) {
            result.sample.position.z = 0;
            result.sample.pose = actor.animations[0][0].pose;
            return result;
        }
        if (state.coordinator) |clock| {
            result.sample.position.z = if (state.roc_home_restored) home.z else 0;
            if (state.roc_idle_at == null and clock.elapsed >= 145) result.sample.pose = clipPose(actor, 0, clock.elapsed - 145);
        }
        if (state.active) |effect| if (effect.actor == 6 and effect_tick > 0 and effect_tick <= actor.attack.len) {
            result.sample = (if (covered) actor.covered_attack else if (state.roc_attack_from_settled) actor.settled_attack else actor.attack)[effect_tick - 1];
            return result;
        };
        if (state.party_strikes[0]) |strike| {
            if (strike.missed) return result;
            if (strike.ticks >= 73 and strike.ticks < 109) result.sample = actor.hurt[strike.ticks - 73];
            if (strike.target_down) {
                const death = strike.ticks - 109 + 1;
                result.sample.position = data.enemy_positions[0];
                result.sample.offset = .{ 0, 0 };
                result.sample.pose = if (death == 1) actor.animations[0][0].pose else actor.animations[3][0].pose;
                result.visible = death < 94;
            }
        } else if (state.hp(index) == 0) {
            result.visible = false;
            result.sample.position = home;
            result.sample.pose = actor.animations[3][0].pose;
        }
    }
    return result;
}
pub const Quad = struct { sprite: battle.Pose, x: i32, y: i32, w: i32, h: i32, depth: f32, actor: ?usize = null, pose_index: ?u16 = null, position: p.Vec3, light: [3]u8 = .{ 128, 128, 128 }, opacity: u8 = 255, medicine_particle: bool = false, projectile: bool = false };
// Twelve actors,32 scenery,12 healing clones,24 revival clones and6 projectiles.
pub const quad_capacity = 86;
pub const List = struct { shadows: [6]p.Shadow = undefined, quads: [quad_capacity]Quad = undefined, length: usize = 0 };
pub fn actorLayout(data: Data, state: battle.State, index: usize) battle.ActorLayout {
    const visual = actorSample(data, &state, index);
    const shift = state.actor_transforms[index].world_offset;
    const position: p.Vec3 = battle.layout.departurePosition(&state, index) orelse state.uniteActorPosition(index) orelse state.spellActorPosition(index) orelse .{ .x = visual.sample.position.x + shift.x, .y = visual.sample.position.y + shift.y, .z = visual.sample.position.z + shift.z };
    var point = p.project(data.camera, position);
    // Perspective scaling reuses the port's billboard policy; the source camera/anchors remain explicit.
    const home = if (index < 6) data.formation_slots[index] else data.enemy_positions[index - 6];
    const scale = (if (state.uniteActorPosition(index) != null or state.spellActorPosition(index) != null) data.sprite_scale else std.math.clamp(data.sprite_scale * p.project(data.camera, home).depth / point.depth, 0.25, 4)) * state.actorSize(index);
    point.x += @as(f32, @floatFromInt(visual.sample.offset[0])) * scale;
    point.y += @as(f32, @floatFromInt(visual.sample.offset[1])) * scale;
    var sprite = data.actors[index].poses[visual.sample.pose];
    var source_pose: ?u16 = visual.sample.pose;
    if (state.spellReaction(index)) |reaction| if (reaction.entry == null and data.actors[index].animations.len > reaction.animation) {
        const pose = oncePose(data.actors[index], reaction.animation, reaction.elapsed);
        sprite = data.actors[index].poses[pose];
        source_pose = pose;
    };
    const screen_offset = state.uniteScreenOffset(index);
    point.x += @as(f32, @floatFromInt(screen_offset[0])) * scale;
    point.y += @as(f32, @floatFromInt(screen_offset[1])) * scale;
    if (state.uniteVmPose(index)) |pose| {
        sprite = pose;
        source_pose = state.unite_vm.pose(index);
    }
    battle.layout.applySpellReaction(state, index, &point, &sprite);
    if (state.spellReaction(index)) |reaction| if (reaction.entry != null) {
        source_pose = if (state.spell_scenes.?.statusAnchors(data.actors[index].id)) |value| (if (reaction.animation == 0) value.idle_pose else value.hurt_pose) else null;
    };
    return .{ .point = point, .scale = scale, .sprite = sprite, .source_pose = source_pose };
}
pub fn compose(data: Data, state: battle.State) List {
    var list: List = .{};
    for (0..6) |index| {
        list.shadows[index] = p.contactShadow(data.camera, data.formation_slots[index], actorSample(data, &state, index).sample.position, data.actors[index].foot_offset_y, data.sprite_scale);
        if (index < state.partyCount() and state.departed[index]) {
            list.shadows[index].radius_x = 0;
            list.shadows[index].radius_y = 0;
        }
    }
    for (data.scenery) |entry| {
        const point = p.project(data.camera, entry.position);
        append(&list, entry.sprite, point, data.sprite_scale, null, null, entry.position);
    }
    for (0..data.actors.len) |index| {
        if (index < state.partyCount() and state.departed[index] and state.departures[index] == null) continue;
        const visual = actorSample(data, &state, index);
        const response = state.spellReaction(index);
        if (response) |value| {
            if (!value.visible) continue;
        } else if (!visual.visible) continue;
        const actor = actorLayout(data, state, index);
        append(&list, actor.sprite, actor.point, actor.scale, index, visual.sample.pose, battle.layout.departurePosition(&state, index) orelse visual.sample.position);
    }
    if (data.c_tracks) |tracks| for (state.front_projectiles[0..2], 0..) |maybe, enemy| {
        const shot = maybe orelse continue;
        if (shot.target >= 2 or shot.ticks < tracks.projectile_start_tick) continue;
        const track = if (shot.low_hp_target) (if (shot.dodge_release != null) tracks.low_hp.?.miss_projectiles[enemy] else tracks.low_hp.?.projectiles[enemy]) else if (shot.dodge_release != null) tracks.misses.?.projectiles[enemy][shot.target] else tracks.projectiles[enemy][shot.target];
        const tick = shot.ticks - tracks.projectile_start_tick;
        if (tick >= track.len) continue;
        const sample = track[tick];
        var point = p.project(data.camera, sample.position);
        const scale = std.math.clamp(data.sprite_scale * p.project(data.camera, data.enemy_positions[enemy]).depth / point.depth, 0.25, 4);
        point.x += @as(f32, @floatFromInt(sample.offset[0])) * scale;
        point.y += @as(f32, @floatFromInt(sample.offset[1])) * scale;
        append(&list, data.actors[6 + enemy].poses[sample.pose], point, scale, 6 + enemy, sample.pose, sample.position);
        list.quads[list.length - 1].projectile = true;
    };
    if (state.medicine_action) |item| {
        const definition = state.rules.consumable(item.id).?;
        if (definition.heal_hp > 0 and item.ticks >= item.timing.impact_tick and item.ticks < item.timing.impact_tick + 31) for (list.quads[0..list.length]) |*quad| {
            if (quad.actor != null and item.affects(quad.actor.?) and !item.interrupted(quad.actor.?)) {
                const light: u8 = @intCast(255 - 4 * (item.ticks - item.timing.impact_tick));
                quad.light = .{ light, light, light };
            }
        };
        for (0..state.partyCount()) |recipient| if (battle.layout.itemParticles(&state, recipient)) |particles| {
            for (particles.quads[0..particles.count]) |quad| {
                append(&list, quad.sprite, quad.point, quad.scale, null, null, quad.position);
                list.quads[list.length - 1].light = quad.light;
                list.quads[list.length - 1].opacity = 128;
                list.quads[list.length - 1].medicine_particle = true;
            }
        };
    }
    for (0..state.partyCount()) |recipient| if (state.revivalAge(recipient) != null) {
        const light = battle.revival.revivalLight(state, recipient);
        for (list.quads[0..list.length]) |*quad| if (quad.actor == recipient) {
            quad.light = .{ light, light, light };
        };
        if (battle.revival.revivalParticlePositions(state, recipient)) |positions| {
            const sprite = data.actors[recipient].poses[data.actors[recipient].animations[3][0].pose];
            for (positions) |position| {
                append(&list, sprite, p.project(data.camera, position), data.sprite_scale, null, null, position);
                list.quads[list.length - 1].light = state.rules.automatic_revival.?.particle_tint;
                list.quads[list.length - 1].medicine_particle = true;
            }
        }
    };
    // Stable depth ordering keeps equal-depth source placements in their original order.
    for (1..list.length) |i| {
        var j = i;
        while (j > 0 and list.quads[j].depth > list.quads[j - 1].depth) : (j -= 1) std.mem.swap(Quad, &list.quads[j], &list.quads[j - 1]);
    }
    return list;
}
fn append(list: *List, sprite: battle.Pose, point: p.ScreenPoint, scale: f32, actor: ?usize, pose_index: ?u16, position: p.Vec3) void {
    std.debug.assert(list.length < list.quads.len);
    list.quads[list.length] = .{ .sprite = sprite, .x = @intFromFloat(@round(point.x - @as(f32, @floatFromInt(sprite.anchor_x)) * scale)), .y = @intFromFloat(@round(point.y - @as(f32, @floatFromInt(sprite.anchor_y)) * scale)), .w = @intFromFloat(@round(@as(f32, @floatFromInt(sprite.rect.w)) * scale)), .h = @intFromFloat(@round(@as(f32, @floatFromInt(sprite.rect.h)) * scale)), .depth = point.depth, .actor = actor, .pose_index = pose_index, .position = position };
    list.length += 1;
}

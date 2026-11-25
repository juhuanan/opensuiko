const std = @import("std");
const types = @import("battle_spell_scene_types.zig");
const Entry = types.Entry;
const Variation = types.Variation;
const Reaction = types.Reaction;
const HurtPose = types.HurtPose;
const UniteImpact = types.UniteImpact;
const UniteReaction = types.UniteReaction;
const Spell = types.Spell;

pub const Packet = struct {
    schema: []const u8,
    atlas: []const u8,
    hurt_poses: []const HurtPose = &.{},
    unite_impacts: []const UniteImpact = &.{},
    physical_white_poses: []const struct { id: []const u8, entry: u16 } = &.{},
    unite_reactions: []const UniteReaction = &.{},
    entries: []const Entry,
    pieces: []const []const u16,
    spells: []const Spell,
    unite_scenes: []const Spell = &.{},
    status_icons: []const types.StatusIcon = &.{},
    status_anchors: []const types.StatusAnchors = &.{},
    enemy_magic_art: ?@import("battle_enemy_magic.zig").Art = null,
    needle_burst: @FieldType(types.StatusIcon, "frames") = &.{},
    pub fn jsonStringify(self: Packet, writer: anytype) !void {
        try writer.beginObject();
        inline for (@typeInfo(Packet).@"struct".field_names) |name| {
            const emit = if (comptime std.mem.eql(u8, name, "needle_burst")) self.needle_burst.len != 0 else if (comptime std.mem.eql(u8, name, "enemy_magic_art")) self.enemy_magic_art != null else if (comptime std.mem.eql(u8, name, "status_icons")) self.status_icons.len != 0 else if (comptime std.mem.eql(u8, name, "status_anchors")) self.status_anchors.len != 0 else if (comptime std.mem.eql(u8, name, "unite_scenes")) self.unite_scenes.len != 0 else if (comptime std.mem.eql(u8, name, "physical_white_poses")) self.physical_white_poses.len != 0 else true;
            if (emit) {
                try writer.objectField(name);
                try writer.write(@field(self, name));
            }
        }
        try writer.endObject();
    }
    pub fn reactionPose(self: Packet, id: []const u8) ?types.HurtPose {
        for (self.hurt_poses) |pose| {
            if (std.mem.eql(u8, id, pose.id) and pose.impact_offset != null and (pose.unite_white_entry != null or pose.white_entry != null)) return pose;
        }
        return null;
    }

    pub fn statusAnchors(self: Packet, id: []const u8) ?types.StatusAnchors {
        for (self.status_anchors) |entry| if (std.mem.eql(u8, entry.id, id)) return entry;
        return null;
    }
    pub fn uniteIndexOf(self: Packet, id: []const u8) ?usize {
        for (self.unite_scenes, 0..) |scene, i| if (scene.program != null and std.mem.eql(u8, scene.id, id)) return i;
        return null;
    }
    pub fn digest(self: Packet) ![32]u8 {
        const bytes = try std.json.Stringify.valueAlloc(std.heap.page_allocator, self, .{});
        defer std.heap.page_allocator.free(bytes);
        var result: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
        return result;
    }
    pub fn indexOf(self: Packet, id: []const u8) ?usize {
        for (self.spells, 0..) |spell, i| if (spell.program != null and std.mem.eql(u8, spell.id, id)) return i;
        return null;
    }
    pub fn validate(self: Packet, width: i32, height: i32) !void {
        const version52 = std.mem.eql(u8, self.schema, "suikoden-spell-scenes/52");
        const version51 = version52 or std.mem.eql(u8, self.schema, "suikoden-spell-scenes/51");
        const version50 = version51 or std.mem.eql(u8, self.schema, "suikoden-spell-scenes/50");
        const version49 = version50 or std.mem.eql(u8, self.schema, "suikoden-spell-scenes/49");
        const version48 = version49 or std.mem.eql(u8, self.schema, "suikoden-spell-scenes/48");
        const version47 = version48 or std.mem.eql(u8, self.schema, "suikoden-spell-scenes/47");
        const version46 = version47 or std.mem.eql(u8, self.schema, "suikoden-spell-scenes/46");
        const version45 = version46 or std.mem.eql(u8, self.schema, "suikoden-spell-scenes/45");
        const version44 = version45 or std.mem.eql(u8, self.schema, "suikoden-spell-scenes/44");
        const version43 = version44 or std.mem.eql(u8, self.schema, "suikoden-spell-scenes/43");
        if (self.needle_burst.len != 0) {
            if (!version43 or self.needle_burst.len != 2 or self.needle_burst[0].ticks != 4 or self.needle_burst[1].ticks != 6 or self.needle_burst[0].entry == self.needle_burst[1].entry) return error.InvalidSpellScenes;
            for (self.needle_burst) |frame| if (frame.entry >= self.entries.len) return error.InvalidSpellScenes;
        }
        const version42 = version43 or std.mem.eql(u8, self.schema, "suikoden-spell-scenes/42");
        const version41 = version42 or std.mem.eql(u8, self.schema, "suikoden-spell-scenes/41");
        if (self.enemy_magic_art) |art| {
            if (!version42) return error.InvalidSpellScenes;
            try art.validate(self.entries.len);
        }
        const version40 = version41 or std.mem.eql(u8, self.schema, "suikoden-spell-scenes/40");
        if ((!version41 and self.status_icons.len + self.status_anchors.len != 0) or
            (self.status_icons.len != 0 and self.status_icons.len != 8) or self.status_anchors.len > 78 or
            (self.status_icons.len == 0) != (self.status_anchors.len == 0)) return error.InvalidSpellScenes;
        for (self.status_icons, 0..) |icon, i| {
            if (icon.frames.len == 0 or icon.frames.len > 32) return error.InvalidSpellScenes;
            for (self.status_icons[0..i]) |prior| if (prior.status == icon.status) return error.InvalidSpellScenes;
            for (icon.frames) |frame| if (frame.entry >= self.entries.len or frame.ticks == 0 or frame.ticks > 256) return error.InvalidSpellScenes;
        }
        for (self.status_anchors, 0..) |anchor, i| {
            if (anchor.id.len == 0 or anchor.id.len > 128 or anchor.offsets.len == 0 or anchor.offsets.len > 256 or anchor.idle_pose >= anchor.offsets.len or anchor.hurt_pose >= anchor.offsets.len) return error.InvalidSpellScenes;
            for (self.status_anchors[0..i]) |prior| if (std.mem.eql(u8, prior.id, anchor.id)) return error.InvalidSpellScenes;
            for (anchor.offsets) |offset| for (offset) |value| if (value < -255 or value > 255) return error.InvalidSpellScenes;
        }
        const version39 = version40 or std.mem.eql(u8, self.schema, "suikoden-spell-scenes/39");
        const version38 = version39 or std.mem.eql(u8, self.schema, "suikoden-spell-scenes/38");
        if ((!version39 and self.physical_white_poses.len != 0) or self.physical_white_poses.len > 256) return error.InvalidSpellScenes;
        for (self.physical_white_poses, 0..) |pose, i| {
            if (pose.id.len == 0 or pose.entry >= self.entries.len) return error.InvalidSpellScenes;
            for (self.physical_white_poses[0..i]) |prior| if (std.mem.eql(u8, pose.id, prior.id)) return error.InvalidSpellScenes;
        }
        const version37 = version38 or std.mem.eql(u8, self.schema, "suikoden-spell-scenes/37");
        const version36 = version37 or std.mem.eql(u8, self.schema, "suikoden-spell-scenes/36");
        const version35 = version36 or std.mem.eql(u8, self.schema, "suikoden-spell-scenes/35");
        const version34 = version35 or std.mem.eql(u8, self.schema, "suikoden-spell-scenes/34");
        const version33 = version34 or std.mem.eql(u8, self.schema, "suikoden-spell-scenes/33");
        const version32 = version33 or std.mem.eql(u8, self.schema, "suikoden-spell-scenes/32");
        const version31 = version32 or std.mem.eql(u8, self.schema, "suikoden-spell-scenes/31");
        const version30 = version31 or std.mem.eql(u8, self.schema, "suikoden-spell-scenes/30");
        const version29 = version30 or std.mem.eql(u8, self.schema, "suikoden-spell-scenes/29");
        const version28 = version29 or std.mem.eql(u8, self.schema, "suikoden-spell-scenes/28");
        const version27 = version28 or std.mem.eql(u8, self.schema, "suikoden-spell-scenes/27");
        const version26 = version27 or std.mem.eql(u8, self.schema, "suikoden-spell-scenes/26");
        const version25 = version26 or std.mem.eql(u8, self.schema, "suikoden-spell-scenes/25");
        const version24 = version25 or std.mem.eql(u8, self.schema, "suikoden-spell-scenes/24");
        const version23 = version24 or std.mem.eql(u8, self.schema, "suikoden-spell-scenes/23");
        const version22 = version23 or std.mem.eql(u8, self.schema, "suikoden-spell-scenes/22");
        const version21 = version22 or std.mem.eql(u8, self.schema, "suikoden-spell-scenes/21");
        const version20 = version21 or std.mem.eql(u8, self.schema, "suikoden-spell-scenes/20");
        const version19 = version20 or std.mem.eql(u8, self.schema, "suikoden-spell-scenes/19");
        const version18 = version19 or std.mem.eql(u8, self.schema, "suikoden-spell-scenes/18");
        const version17 = version18 or std.mem.eql(u8, self.schema, "suikoden-spell-scenes/17");
        const version16 = version17 or std.mem.eql(u8, self.schema, "suikoden-spell-scenes/16");
        const version15 = version16 or std.mem.eql(u8, self.schema, "suikoden-spell-scenes/15");
        const version14 = std.mem.eql(u8, self.schema, "suikoden-spell-scenes/14") or version15;
        const version13 = std.mem.eql(u8, self.schema, "suikoden-spell-scenes/13") or version14;
        const version12 = std.mem.eql(u8, self.schema, "suikoden-spell-scenes/12") or version13;
        const version11 = version12 or std.mem.eql(u8, self.schema, "suikoden-spell-scenes/11");
        const version10 = version11 or std.mem.eql(u8, self.schema, "suikoden-spell-scenes/10");
        const version9 = version10 or std.mem.eql(u8, self.schema, "suikoden-spell-scenes/9");
        if (!std.mem.eql(u8, self.atlas, "spell_effects.png")) return error.InvalidSpellScenes;
        if ((!std.mem.eql(u8, self.schema, "suikoden-spell-scenes/1") and !std.mem.eql(u8, self.schema, "suikoden-spell-scenes/2") and !std.mem.eql(u8, self.schema, "suikoden-spell-scenes/3") and !std.mem.eql(u8, self.schema, "suikoden-spell-scenes/4") and !std.mem.eql(u8, self.schema, "suikoden-spell-scenes/5") and !std.mem.eql(u8, self.schema, "suikoden-spell-scenes/6") and !std.mem.eql(u8, self.schema, "suikoden-spell-scenes/7") and !std.mem.eql(u8, self.schema, "suikoden-spell-scenes/8") and !version9) or self.entries.len == 0 or self.entries.len > 4096 or self.pieces.len == 0 or self.pieces.len > 4096 or self.spells.len == 0 or self.spells.len > 33 or width <= 0 or height <= 0) return error.InvalidSpellScenes;
        if (self.unite_scenes.len > 32 or (!version37 and self.unite_scenes.len != 0)) return error.InvalidSpellScenes;
        if (self.hurt_poses.len > 256) return error.InvalidSpellScenes;
        if ((!version32 and (self.unite_impacts.len != 0 or self.unite_reactions.len != 0)) or self.unite_impacts.len > (if (version52) @as(usize, 11) else if (version51) @as(usize, 8) else if (version48) @as(usize, 7) else if (version46) @as(usize, 6) else if (version39) @as(usize, 5) else 3) or self.unite_reactions.len > 128) return error.InvalidSpellScenes;
        for (self.unite_impacts, 0..) |clip, i| {
            if ((clip.id > 2 and !(version52 and (clip.id == 14 or clip.id == 17 or clip.id == 20)) and !(version51 and clip.id == 13) and !(version48 and clip.id == 6) and !(version46 and clip.id == 3) and !(version39 and (clip.id == 18 or clip.id == 19))) or clip.frames.len == 0 or clip.frames.len > 32) return error.InvalidSpellScenes;
            for (self.unite_impacts[0..i]) |prior| if (clip.id == prior.id) return error.InvalidSpellScenes;
            for (clip.frames) |frame| if (frame.entry >= self.entries.len or frame.ticks == 0 or frame.ticks > 256) return error.InvalidSpellScenes;
        }
        for (self.unite_reactions, 0..) |reaction, i| {
            if (reaction.sounds.len > 64 or (reaction.sounds.len != 0 and (!version49 or reaction.blocker != null))) return error.InvalidSpellScenes;
            for (reaction.sounds, 0..) |sound, j| if (sound.at >= reaction.duration or (j > 0 and sound.at < reaction.sounds[j - 1].at)) return error.InvalidSpellScenes;
            if (reaction.record >= 32 or reaction.variant > 3 or (!version33 and reaction.variant != 0) or reaction.duration == 0 or reaction.duration > 1000) return error.InvalidSpellScenes;
            for (self.unite_reactions[0..i]) |prior| if (prior.record == reaction.record and prior.variant == reaction.variant) return error.InvalidSpellScenes;
            if (!version34 and (reaction.flip != null or reaction.focus_z_pulses.len != 0)) return error.InvalidSpellScenes;
            if (!version36 and (reaction.colors.len != 0 or reaction.status_attempts.len != 0)) return error.InvalidSpellScenes;
            if ((!version38 and reaction.signals.len != 0) or reaction.signals.len > 8) return error.InvalidSpellScenes;
            for (reaction.signals, 0..) |event, j| if (event.at > reaction.duration or event.bits == 0 or (j > 0 and event.at < reaction.signals[j - 1].at)) return error.InvalidSpellScenes;
            if (reaction.status_attempts.len > 8) return error.InvalidSpellScenes;
            for (reaction.status_attempts, 0..) |event, j| if (event.at > reaction.duration or event.failure_percent > 100 or (j > 0 and event.at < reaction.status_attempts[j - 1].at)) return error.InvalidSpellScenes;
            if (!version35 and !reaction.locks_target) return error.InvalidSpellScenes;
            if (reaction.retain_lock and (!version40 or !reaction.locks_target or reaction.blocker != null)) return error.InvalidSpellScenes;
            if (reaction.palette_cycle) |cycle| {
                if (!version44 or (cycle.row != 1 and cycle.row != 4) or cycle.period == 0 or cycle.period > 1000 or cycle.start >= cycle.stop or cycle.stop > reaction.duration or reaction.blocker != null) return error.InvalidSpellScenes;
                var animation: u8 = 1;
                for (reaction.poses) |event| {
                    if (event.at <= cycle.start) animation = event.animation else if (event.at < cycle.stop and event.animation != 1 and (!version45 or cycle.row != 1)) return error.InvalidSpellScenes;
                }
                if (animation != 1) return error.InvalidSpellScenes;
                var white = false;
                for (reaction.white) |event| {
                    if (event.at <= cycle.start) white = event.enabled else if (event.at < cycle.stop and event.enabled) return error.InvalidSpellScenes;
                }
                if (white) return error.InvalidSpellScenes;
            }
            if (reaction.blocker != null) {
                if (reaction.blocker.?.len == 0 or reaction.flip != null or reaction.focus_z_pulses.len != 0 or reaction.poses.len + reaction.white.len + reaction.offsets.len + reaction.motions.len + reaction.impacts.len + reaction.colors.len + reaction.status_attempts.len + reaction.signals.len != 0) return error.InvalidSpellScenes;
                continue;
            }
            if (reaction.poses.len == 0 or reaction.poses[0].at != 0 or reaction.poses[0].animation != 1) return error.InvalidSpellScenes;
            inline for (.{ "poses", "white", "offsets", "motions", "impacts", "focus_z_pulses", "colors" }) |name| {
                const events = @field(reaction, name);
                if (events.len > 64) return error.InvalidSpellScenes;
                for (events, 0..) |event, j| if (event.at >= reaction.duration or (j > 0 and event.at < events[j - 1].at)) return error.InvalidSpellScenes;
            }
            for (reaction.poses) |event| if (event.animation > 1) return error.InvalidSpellScenes;
            for (reaction.offsets) |event| for (event.offset) |v| if (v < -128 or v > 127) return error.InvalidSpellScenes;
            for (reaction.motions, 0..) |motion, j| {
                if (motion.linear_offset and (!version45 or !motion.linear or !motion.home)) return error.InvalidSpellScenes;
                if (motion.absolute and (!version34 or motion.home or motion.linear)) return error.InvalidSpellScenes;
                if (j > 0 and motion.at <= reaction.motions[j - 1].at) return error.InvalidSpellScenes;
                if (motion.updates < (if (motion.linear) @as(u16, 1) else 2) or motion.updates > 1000 or @as(u32, motion.at) + motion.updates > reaction.duration or (motion.linear and !motion.home)) return error.InvalidSpellScenes;
                for (motion.offset_q12) |v| if (@abs(@as(i64, v)) > 32768 * 4096) return error.InvalidSpellScenes;
                for (motion.velocity_q12) |v| if (@abs(@as(i64, v)) > 1048576) return error.InvalidSpellScenes;
            }
            if (reaction.flip) |flip| if (flip.start >= flip.stop or flip.stop > reaction.duration) return error.InvalidSpellScenes;
            for (reaction.focus_z_pulses, 0..) |pulse, j| {
                if (@abs(@as(i64, pulse.delta_q12)) > 32768 * 4096 or (j > 0 and pulse.at <= reaction.focus_z_pulses[j - 1].at)) return error.InvalidSpellScenes;
            }
            for (reaction.impacts) |event| {
                if (!version34 and !event.centered) return error.InvalidSpellScenes;
                var found = false;
                for (self.unite_impacts) |clip| if (clip.id == event.animation) {
                    found = true;
                    break;
                };
                if (!found) return error.InvalidSpellScenes;
            }
        }
        for (self.hurt_poses, 0..) |pose, i| {
            if (pose.id.len == 0 or pose.entry >= self.entries.len) return error.InvalidSpellScenes;
            if (pose.idle_flash) |idle| {
                if (!version45 or idle.frames.len == 0 or idle.frames.len > 32 or (idle.loop and !idle.advances)) return error.InvalidSpellScenes;
                for (idle.frames) |frame| {
                    if (frame.ticks == 0 or frame.ticks > 256 or frame.normal >= self.entries.len) return error.InvalidSpellScenes;
                    for (frame.entries) |entry| if (entry >= self.entries.len) return error.InvalidSpellScenes;
                    const base = self.entries[frame.normal];
                    for (frame.entries) |entry| {
                        const variant = self.entries[entry];
                        if (base.w != variant.w or base.h != variant.h or base.dx != variant.dx or base.dy != variant.dy) return error.InvalidSpellScenes;
                    }
                }
            }
            if (pose.source_attachment) |offset| {
                if (!version50 or pose.impact_offset == null) return error.InvalidSpellScenes;
                for (offset, pose.impact_offset.?) |value, wrapped| if (value < -255 or value > 255 or @as(i8, @truncate(value)) != wrapped) return error.InvalidSpellScenes;
            }
            if (!version32 and (pose.unite_entry != null or pose.unite_white_entry != null or pose.impact_offset != null)) return error.InvalidSpellScenes;
            if ((pose.unite_entry == null) != (pose.unite_white_entry == null)) return error.InvalidSpellScenes;
            if (pose.unite_entry) |normal| {
                const white = pose.unite_white_entry.?;
                if (normal >= self.entries.len or white >= self.entries.len) return error.InvalidSpellScenes;
                const a = self.entries[normal];
                const b = self.entries[white];
                if (a.w != b.w or a.h != b.h or a.dx != b.dx or a.dy != b.dy) return error.InvalidSpellScenes;
            }
            if (pose.white_entry) |id| {
                if (id >= self.entries.len) return error.InvalidSpellScenes;
                const entry = self.entries[id];
                const base = self.entries[pose.entry];
                if (entry.w != base.w or entry.h != base.h or entry.dx != base.dx or entry.dy != base.dy) return error.InvalidSpellScenes;
            }
            if (pose.knockout) |ko| if (ko.entry >= self.entries.len or ko.duration < 3 or ko.duration > 1024) return error.InvalidSpellScenes;
            if (pose.shock_entries) |variants| for (variants) |entry_id| {
                if (entry_id >= self.entries.len or self.entries[entry_id].w != self.entries[pose.entry].w or self.entries[entry_id].h != self.entries[pose.entry].h or self.entries[entry_id].dx != self.entries[pose.entry].dx or self.entries[entry_id].dy != self.entries[pose.entry].dy) return error.InvalidSpellScenes;
            };
            if (pose.flash_entries) |variants| for (variants) |entry_id| {
                if (entry_id >= self.entries.len) return error.InvalidSpellScenes;
                const entry = self.entries[entry_id];
                const base = self.entries[pose.entry];
                if (entry.w != base.w or entry.h != base.h or entry.dx != base.dx or entry.dy != base.dy) return error.InvalidSpellScenes;
            };
            if (pose.idle_center) |center| for (center) |v| if (@abs(v) > 255) return error.InvalidSpellScenes;
            if (pose.center) |center| for (center) |v| if (@abs(v) > 255) return error.InvalidSpellScenes;
            for (self.hurt_poses[0..i]) |prior| if (std.mem.eql(u8, prior.id, pose.id)) return error.InvalidSpellScenes;
        }
        for (self.entries) |entry| if (entry.w <= 0 or entry.h <= 0 or entry.w > 256 or entry.h > 128 or entry.x < 0 or entry.y < 0 or entry.x > width - entry.w or entry.y > height - entry.h or entry.dx < -255 or entry.dx > 255 or entry.dy < -255 or entry.dy > 255) return error.InvalidSpellScenes;
        for (self.pieces) |piece| {
            if (piece.len > 128) return error.InvalidSpellScenes;
            for (piece) |entry| if (entry >= self.entries.len) return error.InvalidSpellScenes;
        }
        for ([_][]const Spell{ self.spells, self.unite_scenes }) |scenes| for (scenes, 0..) |spell, i| {
            if (spell.id.len == 0 or spell.id.len > 40 or spell.name.len == 0 or spell.name.len > 80) return error.InvalidSpellScenes;
            for (scenes[0..i]) |prior| if (std.mem.eql(u8, spell.id, prior.id)) return error.InvalidSpellScenes;
            if (spell.program) |program| {
                if (spell.blocker != null or program.impact == 0 or program.impact >= program.duration or program.duration > 4096 or @as(u16, program.initial_draws) + @as(u16, program.initial_draws_per_party) * 6 > (if (version37 and program.emitter != null and program.emitter.?.kind == .seeded_spheres) @as(u16, 150) else 128) or program.tracks.len == 0 or program.tracks.len > 128 or program.objects.len > (if (version24) @as(usize, 160) else 128) or program.meshes.len > (if (version16) @as(usize, 16) else 8) or program.cameras.len > 64 or program.wash.len < program.impact + 1 or program.wash.len > program.duration + 1) return error.InvalidSpellScenes;
                if (program.actor_motion) |motion| {
                    if (!version27 or !program.group or motion.start == 0 or motion.updates < 2 or motion.updates > 256 or @as(u32, motion.start) + motion.updates > motion.returning or @as(u32, motion.returning) + motion.updates > program.duration or motion.size_delta.len != @as(usize, program.duration) + 1) return error.InvalidSpellScenes;
                    for (motion.destination) |v| if (@abs(v) > 32767) return error.InvalidSpellScenes;
                    for (motion.velocity ++ motion.return_velocity) |v| if (@abs(v) > 1048576) return error.InvalidSpellScenes;
                }
                if (program.background_warps.len > 2 or (program.background_warps.len != 0 and !version26)) return error.InvalidSpellScenes;
                for (program.background_warps) |warp| {
                    if (warp.anchor != .world and (!version30 or warp.anchor != .target)) return error.InvalidSpellScenes;
                    if (warp.depth < 1 or warp.depth > 509 or warp.samples.len == 0 or warp.samples.len > program.duration + 1 or warp.faces.len == 0 or warp.faces.len > 192) return error.InvalidSpellScenes;
                    for (warp.faces) |face| if (face.count != 3 and face.count != 4) return error.InvalidSpellScenes;
                    for (warp.samples) |sample| if (sample) |mesh| {
                        if (mesh.source.len < 3 or mesh.source.len > 193 or mesh.source.len != mesh.destination.len) return error.InvalidSpellScenes;
                        for (warp.faces) |face| for (face.indices[0..face.count]) |index| if (index >= mesh.source.len) return error.InvalidSpellScenes;
                    };
                }
                if (program.erosion) |erosion| {
                    if (!version25 or erosion.entry >= self.entries.len or erosion.levels.len == 0 or erosion.levels.len > 16384 or erosion.lower_present.len != erosion.levels.len or erosion.start == 0 or erosion.start >= erosion.stop or erosion.stop > program.duration or erosion.budget == 0 or erosion.budget > 160 or erosion.minimum_weight < erosion.budget or erosion.minimum_weight > 32768 or program.emitterCount() != 0 or program.scale_noise != null) return error.InvalidSpellScenes;
                    const entry = self.entries[erosion.entry];
                    const pixels: usize = @intCast(entry.w * entry.h);
                    if (entry.w > 64 or entry.h > 64 or erosion.view_cells.len != pixels or erosion.view_upper.len != pixels or erosion.colors.len != pixels) return error.InvalidSpellScenes;
                    for (erosion.levels, erosion.lower_present) |level, lower| if (level > 2 or (level == 1 and !lower) or (level == 0 and lower)) return error.InvalidSpellScenes;
                    for (erosion.view_cells) |cell| if (cell >= erosion.levels.len) return error.InvalidSpellScenes;
                    var weight: usize = 0;
                    var remaining: usize = 0;
                    for (erosion.levels, erosion.lower_present) |level, lower| {
                        weight += level;
                        remaining += @as(usize, @intFromBool(level == 2)) + @as(usize, @intFromBool(lower));
                    }
                    const attempts: usize = erosion.stop - erosion.start;
                    // High-only cells overcount source weight; reject an impossible removal loop.
                    if (weight >= erosion.minimum_weight and remaining < @as(usize, erosion.budget) * attempts and weight != remaining) return error.InvalidSpellScenes;
                }
                if (program.scale_noise) |noise| {
                    if (!version21 or noise.start == 0 or noise.start >= noise.stop or noise.stop >= program.duration or noise.modulus == 0 or noise.modulus > 256 or @abs(noise.bias) > 256 or @as(i32, noise.stop - noise.start) * (@as(i32, noise.modulus) + @as(i32, @intCast(@abs(noise.bias)))) > 16384) return error.InvalidSpellScenes;
                }
                if (program.reaction_center_switch and (!version11 or program.reaction == null or program.group)) return error.InvalidSpellScenes;
                if (program.party_reaction != null and (!version20 or !program.group)) return error.InvalidSpellScenes;
                for ([_]?Reaction{ program.reaction, program.party_reaction }) |optional_reaction| if (optional_reaction) |reaction| {
                    if (reaction.active_samples.len != 0 and (!version14 or reaction.active_samples.len != reaction.offsets.len)) return error.InvalidSpellScenes;
                    if (reaction.start >= program.duration or reaction.offsets.len == 0 or reaction.offsets.len > program.duration + 1) return error.InvalidSpellScenes;
                    if (reaction.release) |release| if (release > reaction.offsets.len) return error.InvalidSpellScenes;
                    if (reaction.animation > 1 or (reaction.tints.len != 0 and reaction.tints.len != reaction.offsets.len)) return error.InvalidSpellScenes;
                    if (reaction.flash_frames.len != 0 and reaction.flash_frames.len != reaction.offsets.len) return error.InvalidSpellScenes;
                    for (reaction.flash_frames) |frame| if (frame) |variant| if (variant >= 7 or (variant >= 4 and !version11)) return error.InvalidSpellScenes;
                    for (reaction.offsets) |offset| for (offset) |v| if (@abs(v) > 255) return error.InvalidSpellScenes;
                };
                if (program.focus_samples.len > program.duration + 1) return error.InvalidSpellScenes;
                for (program.focus_samples) |sample| if (sample) |focus| {
                    for (focus) |v| if (@abs(v) > 32767) return error.InvalidSpellScenes;
                };
                var maxima: [128]usize = @splat(0);
                for (program.tracks, 0..) |track, t| {
                    if (track.len == 0 or track.len > program.duration + 1) return error.InvalidSpellScenes;
                    for (track) |sample| {
                        if (sample.noise_scale and (!version21 or program.scale_noise == null)) return error.InvalidSpellScenes;
                        if (sample.piece) |piece| {
                            if (piece >= self.pieces.len) return error.InvalidSpellScenes;
                            maxima[t] = @max(maxima[t], self.pieces[piece].len);
                        }
                        if (sample.quad_offsets != null and !version31) return error.InvalidSpellScenes;
                        for (sample.target_weight) |weight| if (@abs(weight) > 32768 or (weight != 0 and !version16)) return error.InvalidSpellScenes;
                        if (@abs(sample.size) > 65536) return error.InvalidSpellScenes;
                        for (sample.position) |v| if (@abs(v) > 134217728) return error.InvalidSpellScenes;
                        for (sample.scale) |v| if (@abs(v) > 65536 or (sample.noise_scale and @abs(v) + @as(u32, program.scale_noise.?.stop - program.scale_noise.?.start) * (@as(u32, program.scale_noise.?.modulus) + @abs(program.scale_noise.?.bias)) > 65536)) return error.InvalidSpellScenes;
                        for (sample.angles ++ sample.node_angles) |v| if (@abs(v) > 1048576) return error.InvalidSpellScenes;
                    }
                }
                if (program.emitters.len > 4 or (program.emitters.len != 0 and (!version19 or program.emitter != null))) return error.InvalidSpellScenes;
                var occupied: u128 = 0;
                for (0..program.emitterCount()) |pool_index| {
                    const emitter = program.emitterAt(pool_index);
                    const first: usize = emitter.particle_start;
                    const stop = first + emitter.count;
                    if ((program.emitters.len != 0 and emitter.count == 0) or stop > (if (version20) @as(usize, 90) else 50) or (program.emitter != null and first != 0) or (emitter.initial_delay_draw != 0 and (!version19 or emitter.kind != .cycling_sprites))) return error.InvalidSpellScenes;
                    for (first..stop) |index| {
                        const bit = @as(u128, 1) << @as(u7, @intCast(index));
                        if (occupied & bit != 0) return error.InvalidSpellScenes;
                        occupied |= bit;
                    }
                }
                var capacity: usize = 0;
                for (0..@as(usize, program.duration) + 1) |update| {
                    var active_faces: usize = 0;
                    var capture_depth: ?u16 = null;
                    for (program.background_warps) |warp| if (update < warp.samples.len and warp.samples[update] != null) {
                        if (capture_depth) |depth| if (depth != warp.depth) return error.InvalidSpellScenes;
                        capture_depth = warp.depth;
                        active_faces += warp.faces.len;
                    };
                    capacity = @max(capacity, active_faces);
                }
                for (program.objects) |object| {
                    if (object.flight) |flight| {
                        if (!version31 or object.anchor != .caster or flight.updates == 0 or flight.updates > 1024 or flight.start > program.duration or @abs(flight.target_height_q12) > 4096 or object.particle_index != null) return error.InvalidSpellScenes;
                    }
                    if (object.anchor == .screen) {
                        if (!version25 or object.screen_depth == null or object.screen_depth.? < 5 or object.screen_depth.? > 379 or object.particle_index != null or object.center_on_target) return error.InvalidSpellScenes;
                    } else if (object.screen_depth != null) return error.InvalidSpellScenes;
                    const object_emitter = if (object.particle_index) |index| program.emitterForParticle(index) else null;
                    for (object.random_node_angles) |term| if (term != null and !version22) return error.InvalidSpellScenes;
                    if (object.random_node_angle != null and !version17) return error.InvalidSpellScenes;
                    if (object.trail_index) |index| {
                        const emitter = object_emitter orelse return error.InvalidSpellScenes;
                        if (!version19 or emitter.kind != .falling_trails or object.particle_part != .primary or index >= emitter.trail_count) return error.InvalidSpellScenes;
                    }
                    if (object.origin_until > program.duration or (object.origin_until != 0 and (!version12 or object.anchor != .world))) return error.InvalidSpellScenes;
                    if ((!object.center_y or object.particle_part != .primary) and !version11) return error.InvalidSpellScenes;
                    if (object.track >= program.tracks.len or object.start > program.duration) return error.InvalidSpellScenes;
                    if (object.particle_index) |index| {
                        const emitter = program.emitterForParticle(index) orelse return error.InvalidSpellScenes;
                        if ((emitter.kind == .inward_lines or emitter.kind == .inward_points or emitter.kind == .rising_lines) or @as(u16, index) >= @as(u16, emitter.particle_start) + emitter.count or (emitter.kind == .falling_lines and object.track != emitter.splash_track)) return error.InvalidSpellScenes;
                    }
                    if (object.particle_part != .primary and (object.particle_index == null or (object_emitter.?.kind != .lightning_bolts and object_emitter.?.kind != .scheduled_pulses and object_emitter.?.kind != .falling_trails and object_emitter.?.kind != .bouncing_sprites and object_emitter.?.kind != .ballistic_sprites))) return error.InvalidSpellScenes;
                    if (object.particle_index != null and (object_emitter.?.kind == .falling_trails or object_emitter.?.kind == .bouncing_sprites or object_emitter.?.kind == .ballistic_sprites) and object.particle_part == .pulse) return error.InvalidSpellScenes;
                    if (object.piece_track) |track| if (!version14 or object.particle_index == null or track >= program.tracks.len or program.tracks[object.track].len < program.duration or (object_emitter.?.kind != .lightning_bolts and object_emitter.?.kind != .spherical_sprites and object_emitter.?.kind != .seeded_spheres and object_emitter.?.kind != .cycling_sprites and object_emitter.?.kind != .ballistic_sprites)) return error.InvalidSpellScenes;
                    for (program.tracks[object.track]) |sample| for (sample.target_weight) |weight| if (weight != 0) return error.InvalidSpellScenes;
                    capacity += maxima[object.piece_track orelse object.track] * @as(usize, if (object.anchor == .each_target) 6 else 1);
                    if (object.member_index >= 6 or (object.anchor == .party_member and program.initial_draws_per_party == 0)) return error.InvalidSpellScenes;
                    if (object.anchor == .each_target and !program.group) return error.InvalidSpellScenes;
                    for (object.origin) |v| if (@abs(v) > 32767) return error.InvalidSpellScenes;
                    for (object.position) |v| if (@abs(v) > 134217728) return error.InvalidSpellScenes;
                    const draw_limit = @as(u16, program.initial_draws) + @as(u16, program.initial_draws_per_party) * (if (object.anchor == .party_member) @as(u16, object.member_index) + 1 else 0);
                    for ([_]?Variation{ object.random_z, object.random_angle, object.random_node_angle, object.random_size, object.random_node_angles[0], object.random_node_angles[1], object.random_node_angles[2] }) |maybe| if (maybe) |variation| {
                        if (@as(u16, variation.draw) >= draw_limit or variation.modulus == 0 or @abs(variation.bias) > 65536 or @abs(variation.multiplier) > 4096) return error.InvalidSpellScenes;
                    };
                    if (object.random_size) |v| {
                        const lo: i64 = @as(i64, v.bias) + @as(i64, @intCast(@min(@as(i64, 0), @as(i64, v.modulus - 1) * v.multiplier)));
                        const hi: i64 = @as(i64, v.bias) + @as(i64, @intCast(@max(@as(i64, 0), @as(i64, v.modulus - 1) * v.multiplier)));
                        for (program.tracks[object.track]) |sample| if (@abs(sample.size + lo) > 65536 or @abs(sample.size + hi) > 65536) return error.InvalidSpellScenes;
                    }
                }
                var previous: u16 = 0;
                for (program.cameras) |event| {
                    if (event.at <= previous or event.at >= program.duration or event.updates == 0 or event.updates > 4096) return error.InvalidSpellScenes;
                    for (event.target.position ++ event.target.angles ++ event.target.c ++ event.target.d) |v| if (@abs(v) > 32767) return error.InvalidSpellScenes;
                    if (event.target.c[2] < 256 or @abs(event.target.d[0]) > 16384 or @abs(event.target.d[1]) > 16384 or @abs(event.target.d[2]) > 16384 or @abs(@divTrunc(event.target.d[0] << 10, event.target.c[2])) > 16384) return error.InvalidSpellScenes;
                    previous = event.at;
                }
                if (program.screen_washes.len > 8) return error.InvalidSpellScenes;
                for (program.screen_washes) |screen| {
                    if ((!version9) or screen.depth < 0 or screen.depth > 509 or screen.colors.len < program.duration or screen.colors.len > program.duration + 1) return error.InvalidSpellScenes;
                    capacity += 1;
                }
                for (program.meshes) |mesh| {
                    if (mesh.segment_gap != 0 and (!version30 or mesh.kind != .column or mesh.segments < 3 or mesh.segment_gap >= 4096 / @as(u16, mesh.segments))) return error.InvalidSpellScenes;
                    if (mesh.segment_gaps.len != 0) {
                        if (!version47 or mesh.kind != .column or mesh.segment_gap != 0 or mesh.segments < 3 or mesh.segment_gaps.len < mesh.stop or mesh.segment_gaps.len > program.duration + 1) return error.InvalidSpellScenes;
                        for (mesh.segment_gaps) |gap| if (gap >= 4096 / @as(u16, mesh.segments)) return error.InvalidSpellScenes;
                    }
                    if (mesh.shape_samples.len != 0) {
                        if (!version28 or mesh.kind != .column or mesh.shape_samples.len < mesh.stop or mesh.shape_samples.len > program.duration + 1) return error.InvalidSpellScenes;
                        for (mesh.shape_samples) |shape| {
                            if (shape.radius < 0 or shape.radius > 1024 or shape.top_radius < 0 or shape.top_radius > 1024 or @abs(shape.base_height) > 32767 or @abs(shape.height) > 32767) return error.InvalidSpellScenes;
                        }
                    }
                    if (mesh.kind == .strip) {
                        if (!version16 or (mesh.strip_edges.len != 1 and mesh.strip_edges.len < mesh.stop) or mesh.strip_edges.len > program.duration) return error.InvalidSpellScenes;
                        for (mesh.strip_edges) |edges| {
                            if (edges.len != @as(usize, mesh.segments) + 1) return error.InvalidSpellScenes;
                            for (edges) |pair| for (pair) |vertex| for (vertex) |v| if (@abs(@as(i32, v)) > 4096) return error.InvalidSpellScenes;
                        }
                    } else if (mesh.strip_edges.len != 0) return error.InvalidSpellScenes;
                    if (mesh.kind != .strip and mesh.track < program.tracks.len) for (program.tracks[mesh.track]) |sample| for (sample.target_weight) |weight| if (weight != 0) return error.InvalidSpellScenes;
                    for (mesh.angles) |angle| if (@abs(angle) > 1048576 or (angle != 0 and (!version14 or (mesh.kind != .column and (!version27 or mesh.kind != .fan))))) return error.InvalidSpellScenes;
                    if (mesh.anchor == .screen or mesh.anchor == .each_target or mesh.anchor == .party_member or mesh.track >= program.tracks.len or mesh.start >= mesh.stop or mesh.stop > program.duration or mesh.segments < 3 or mesh.segments > 64 or (mesh.radius < 0 or (mesh.radius == 0 and (!version21 or mesh.kind != .column or mesh.top_radius == null))) or mesh.radius > 1024 or program.tracks[mesh.track].len < mesh.stop or (mesh.kind == .column and mesh.shape_samples.len == 0 and mesh.heights.len < mesh.stop)) return error.InvalidSpellScenes;
                    if (mesh.animated_angles and (!version19 or mesh.kind != .column)) return error.InvalidSpellScenes;
                    if (mesh.top_radius) |radius| if (radius <= 0 or radius > 1024) return error.InvalidSpellScenes;
                    if (mesh.kind == .band and (mesh.segments % 2 != 0 or mesh.opening.len < mesh.stop or mesh.spread.len < mesh.stop)) return error.InvalidSpellScenes;
                    if (mesh.kind == .band and (!version9)) return error.InvalidSpellScenes;
                    if (mesh.base_heights.len != 0 and mesh.base_heights.len < mesh.stop) return error.InvalidSpellScenes;
                    for (mesh.base_heights) |base_height| if (@abs(base_height) > 32767) return error.InvalidSpellScenes;
                    for (mesh.origin) |v| if (@abs(v) > 32767) return error.InvalidSpellScenes;
                    for (mesh.heights) |h| if (@abs(h) > 32767) return error.InvalidSpellScenes;
                    if (mesh.depth) |depth| if (depth < 1 or depth > 509) return error.InvalidSpellScenes;
                    capacity += mesh.segments;
                }
                for (0..program.emitterCount()) |emitter_index| {
                    const emitter = program.emitterAt(emitter_index).*;
                    if (emitter.kind == .inward_points) {
                        if (!version29 or emitter.anchor != .world or emitter.origin[1] != 0 or emitter.model_track != null or emitter.scale_track >= program.tracks.len or program.tracks[emitter.scale_track].len <= emitter.stop or emitter.count == 0 or emitter.point_initial_scales.len != emitter.count or emitter.spawn_stop < emitter.start or emitter.spawn_stop >= emitter.stop) return error.InvalidSpellScenes;
                        for (emitter.point_initial_scales) |v| if (@abs(v) > 65536) return error.InvalidSpellScenes;
                        for (program.tracks[emitter.scale_track]) |sample| if (sample.scale[0] != sample.scale[1] or sample.scale[0] != sample.scale[2]) return error.InvalidSpellScenes;
                    } else if (emitter.point_initial_scales.len != 0) return error.InvalidSpellScenes;
                    if (emitter.kind == .rising_lines) {
                        if (!version30 or emitter.anchor != .target or emitter.model_track != null or emitter.scale_track >= program.tracks.len or program.tracks[emitter.scale_track].len <= emitter.stop or emitter.count == 0 or emitter.spawn_stop < emitter.start or emitter.spawn_stop >= emitter.stop or emitter.trail_min == 0 or emitter.trail_range == 0 or @as(u16, emitter.trail_min) + emitter.trail_range > 256 or emitter.speed_range == 0 or emitter.speed_range > 16 or emitter.velocity_z > -4096 or emitter.velocity_z < -1048576 or emitter.life_max == 0 or emitter.min_z >= 0 or emitter.min_z < -32767) return error.InvalidSpellScenes;
                        for (emitter.origin) |v| if (v != 0) return error.InvalidSpellScenes;
                    }
                    if (emitter.model_track) |track| {
                        if (!version21 or emitter.kind != .inward_lines or emitter.anchor != .world or track >= program.tracks.len or program.tracks[track].len <= emitter.stop) return error.InvalidSpellScenes;
                    }
                    if (emitter.anchor == .world) for (emitter.origin) |v| {
                        if (@abs(v) > 32767) return error.InvalidSpellScenes;
                    };
                    if (emitter.anchor == .world and emitter.model_track == null and emitter.kind != .inward_points) return error.InvalidSpellScenes;
                    if (emitter.kind == .inward_lines and emitter.anchor == .caster) for (emitter.origin) |v| {
                        if (v != 0) return error.InvalidSpellScenes;
                    };
                    if (emitter.anchor != .caster and !(version30 and emitter.kind == .rising_lines and emitter.anchor == .target) and (!version21 or (emitter.kind != .inward_lines and emitter.kind != .inward_points) or emitter.anchor != .world)) return error.InvalidSpellScenes;
                    if (emitter.kind == .inward_lines and emitter.spawn_stop != 0 and (!version21 or emitter.spawn_stop < emitter.start or emitter.spawn_stop >= emitter.stop)) return error.InvalidSpellScenes;
                    if (emitter.repeat_size_range != 0 or emitter.repeat_size_min != 0 or emitter.focus_on_first) {
                        if (!version21 or emitter.kind != .cycling_sprites or ((emitter.repeat_size_range == 0) != (emitter.repeat_size_min == 0)) or (emitter.focus_on_first and emitter.focus_kick <= 0) or (emitter.repeat_size_range != 0 and (emitter.repeat_size_min <= 0 or emitter.repeat_size_min + @as(i32, emitter.repeat_size_range) > 65536))) return error.InvalidSpellScenes;
                    }
                    if (!emitter.initial_delays and (!version23 or emitter.kind != .cycling_sprites)) return error.InvalidSpellScenes;
                    if (emitter.spawn_override) |position| {
                        if (!version23 or emitter.kind != .lightning_bolts or emitter.fixed_positions.len != 0 or emitter.repeat_until != 0 or emitter.strike_at != 0) return error.InvalidSpellScenes;
                        for (position) |v| if (@abs(v) > 134217728) return error.InvalidSpellScenes;
                    }
                    if (emitter.spark_velocity_z != 0 or emitter.spark_min_z != 0) {
                        if (!version23 or emitter.kind != .lightning_bolts or emitter.spark_velocity_z >= 0 or emitter.spark_velocity_z < -1048576 or emitter.spark_min_z >= 0 or emitter.spark_min_z < -32767 or emitter.fixed_positions.len != 0) return error.InvalidSpellScenes;
                    }
                    if (emitter.kind == .seeded_spheres) {
                        if (!version37 or program.emitterCount() != 1 or emitter.particle_start != 0 or emitter.count != 30 or program.initial_draws != 150 or program.initial_draws_per_party != 0 or emitter.initial_warmup != 32 or emitter.initial_phase != 64 or emitter.loop_stop < emitter.start or emitter.loop_stop >= emitter.spawn_stop or emitter.spawn_stop >= emitter.stop or emitter.life_max != 47 or emitter.oscillation.len != 128 or emitter.scale_track >= program.tracks.len or program.tracks[emitter.scale_track].len <= emitter.stop) return error.InvalidSpellScenes;
                        for (emitter.oscillation) |value| if (@abs(@as(i64, value)) > 128 * 4096) return error.InvalidSpellScenes;
                    } else if (emitter.loop_stop != 0 or emitter.initial_warmup != 0 or emitter.initial_phase != 0 or emitter.oscillation.len != 0) return error.InvalidSpellScenes;
                    const radius: usize = emitter.radius;
                    if (emitter.start >= emitter.stop or emitter.stop >= program.duration or emitter.count > (if (version20 and emitter.kind == .drifting_sprites or version17 and emitter.kind == .spherical_sprites or version37 and emitter.kind == .seeded_spheres) @as(u8, 50) else if (emitter.kind == .scheduled_sprites or emitter.kind == .falling_lines or emitter.kind == .lightning_bolts or emitter.kind == .scheduled_pulses or emitter.kind == .cycling_sprites or emitter.kind == .falling_trails or emitter.kind == .orbiting_sprites or emitter.kind == .ballistic_sprites or emitter.kind == .rising_lines or (version21 and (emitter.kind == .inward_lines or emitter.kind == .inward_points))) @as(u8, 40) else 20) or radius < 2 or radius > (if (version20 and emitter.kind == .drifting_sprites) @as(usize, 300) else if (version21 and (emitter.kind == .inward_lines or emitter.kind == .inward_points)) @as(usize, 200) else if ((version17 and emitter.kind == .spherical_sprites or version18 and emitter.kind == .cycling_sprites or version37 and emitter.kind == .seeded_spheres)) @as(usize, 200) else if (version12 and emitter.kind == .lightning_bolts) @as(usize, 192) else 128) or emitter.roots.len != radius * radius + 1) return error.InvalidSpellScenes;
                    for (emitter.roots, 0..) |r, n| if (@as(usize, r) * r > n or (n > 0 and r == 0)) return error.InvalidSpellScenes;

                    if (emitter.kind == .bouncing_sprites) {
                        if (!version22 or emitter.count == 0 or emitter.spawn_at.len != emitter.count or emitter.min_z >= 0 or emitter.min_z < -32767 or emitter.velocity_x >= 0 or emitter.velocity_x < -1048576 or emitter.velocity_z != 0 or emitter.gravity <= 0 or emitter.gravity > 65536 or emitter.bounce_divisor < 2 or emitter.bounce_divisor > 8 or emitter.min_x >= 0 or emitter.min_x < -32767 or emitter.spin_modulus == 0 or emitter.spin_modulus > 4096 or emitter.focus_stride == 0 or emitter.focus_stride > emitter.count or emitter.focus_kick < 0 or emitter.focus_kick > 128 or emitter.spark_track >= program.tracks.len) return error.InvalidSpellScenes;
                        for (emitter.spawn_at) |at| if (at < emitter.start or at >= emitter.stop) return error.InvalidSpellScenes;
                    } else if ((emitter.kind != .ballistic_sprites and (emitter.velocity_x != 0 or emitter.gravity != 0)) or emitter.bounce_divisor != 0 or emitter.min_x != 0 or emitter.spin_modulus != 0 or emitter.focus_stride != 1) return error.InvalidSpellScenes;
                    if (emitter.delay_bias != 0 and (!version24 or emitter.kind != .cycling_sprites or emitter.spawn_stop < emitter.start or emitter.delay_bias > emitter.spawn_stop - emitter.start)) return error.InvalidSpellScenes;
                    if (emitter.kind == .ballistic_sprites) {
                        if (!version24 or emitter.count == 0 or emitter.spawn_at.len != emitter.count or @abs(emitter.velocity_x) > 1048576 or @abs(emitter.velocity_z) > 1048576 or @abs(emitter.gravity) > 65536 or emitter.focus_kick < 0 or emitter.focus_kick > 128) return error.InvalidSpellScenes;
                        const steps: i64 = emitter.stop - emitter.start;
                        if (@as(i64, @intCast(@abs(emitter.velocity_x))) * steps + @as(i64, emitter.radius) * 4096 > 2147483647 or @as(i64, @intCast(@abs(emitter.velocity_z))) * steps + (@as(i64, @intCast(@abs(emitter.gravity))) * steps * (steps + 1) >> 1) + @as(i64, emitter.height_range) * 4096 > 2147483647) return error.InvalidSpellScenes;
                        if (emitter.landing_z == 0) {
                            if (emitter.gravity >= 0 or emitter.velocity_z != 0 or emitter.min_z >= 0 or emitter.min_z < -32767 or emitter.focus_kick != 0) return error.InvalidSpellScenes;
                        } else if (emitter.landing_z < 1 or emitter.landing_z > 32767 or emitter.velocity_z <= 0 or emitter.gravity != 0 or emitter.spark_track >= program.tracks.len) return error.InvalidSpellScenes;
                        for (emitter.spawn_at) |at| if (at < emitter.start or at >= emitter.stop) return error.InvalidSpellScenes;
                    } else if (emitter.landing_z != 0) return error.InvalidSpellScenes;
                    if (emitter.kind == .orbiting_sprites or emitter.kind == .drifting_sprites) {
                        if (!version20 or emitter.count == 0 or emitter.height_range == 0 or emitter.spawn_stop < emitter.start or emitter.spawn_stop >= emitter.stop or emitter.life_max == 0) return error.InvalidSpellScenes;
                        if (emitter.kind == .orbiting_sprites) {
                            if (emitter.spawn_at.len != emitter.count or emitter.spawn_height_min != 0 or emitter.velocity_min != 0 or emitter.velocity_range != 0) return error.InvalidSpellScenes;
                            for (emitter.spawn_at) |at| if (at < emitter.start or at > emitter.spawn_stop) return error.InvalidSpellScenes;
                        } else if (emitter.spawn_at.len != 0 or emitter.velocity_min <= 0 or emitter.velocity_range == 0 or emitter.velocity_min + emitter.velocity_range > 65536 or emitter.spawn_height_min + @as(u32, emitter.height_range) > 32767) return error.InvalidSpellScenes;
                    } else if (emitter.spawn_height_min != 0 or emitter.velocity_min != 0 or emitter.velocity_range != 0) return error.InvalidSpellScenes;
                    if (emitter.kind == .falling_trails) {
                        if (!version19 or emitter.count == 0 or emitter.trail_count < 2 or emitter.trail_count > 10 or emitter.spawn_at.len != emitter.count or emitter.spawn_stop < emitter.start or emitter.spawn_stop >= emitter.stop or emitter.min_z >= 0 or emitter.min_z < -32767 or emitter.velocity_z <= 0 or emitter.velocity_z > 1048576 or emitter.spark_track >= program.tracks.len or emitter.focus_kick < 0 or emitter.focus_kick > 128) return error.InvalidSpellScenes;
                        for (emitter.spawn_at) |at| if (at < emitter.start or at > emitter.spawn_stop) return error.InvalidSpellScenes;
                    } else if (emitter.trail_count != 0) return error.InvalidSpellScenes;
                    if (emitter.delay_stride != 1 and emitter.kind != .cycling_sprites) return error.InvalidSpellScenes;
                    if (emitter.kind == .cycling_sprites and (!version18 or emitter.count == 0 or emitter.life_max < 2 or emitter.focus_kick < 0 or emitter.focus_kick > 128 or emitter.delay_modulus == 0 or emitter.delay_stride == 0 or emitter.delay_stride > 8 or @as(u16, emitter.initial_delay_draw) + (@as(u16, emitter.count) - 1) * emitter.delay_stride >= program.initial_draws or emitter.spawn_stop < emitter.start or emitter.spawn_stop >= emitter.stop or emitter.scale_track >= program.tracks.len or program.tracks[emitter.scale_track].len <= emitter.stop)) return error.InvalidSpellScenes;
                    if (emitter.kind == .spherical_sprites and (!version17 or emitter.count == 0 or emitter.life_max == 0 or emitter.scale_track >= program.tracks.len or program.tracks[emitter.scale_track].len <= emitter.stop)) return error.InvalidSpellScenes;
                    if (emitter.kind == .rising_sprites or emitter.kind == .scheduled_sprites) {
                        if (emitter.spawn_stop < emitter.start or emitter.spawn_stop >= emitter.stop or emitter.scale_track >= program.tracks.len or program.tracks[emitter.scale_track].len <= emitter.stop or emitter.life_max == 0 or emitter.velocity_z >= 0 or emitter.velocity_z < -1048576 or emitter.min_z >= 0 or emitter.min_z < -32767) return error.InvalidSpellScenes;
                    }
                    if (emitter.kind == .scheduled_sprites and (emitter.delay_modulus == 0 or program.initial_draws < emitter.count or emitter.repeat_radius < 2 or emitter.repeat_radius > emitter.radius or emitter.spawn_clock.len <= emitter.spawn_stop or emitter.spawn_clock.len > program.duration + 1)) return error.InvalidSpellScenes;
                    if (emitter.kind == .falling_lines) {
                        if ((!version10) or emitter.spawn_stop < emitter.start or emitter.spawn_stop >= emitter.stop or emitter.splash_track >= program.tracks.len or emitter.trail_range == 0 or emitter.speed_range == 0 or emitter.min_z >= 0 or emitter.min_z < -32700 or emitter.velocity_z <= 0 or emitter.velocity_z + @as(i32, emitter.speed_range) * 4096 > 1048576) return error.InvalidSpellScenes;
                        for (emitter.origin) |v| if (@abs(v) > 32767) return error.InvalidSpellScenes;
                    }
                    if ((emitter.repeat_until != 0 or emitter.strike_at != 0 or emitter.strike_radius != 0) and (!version12 or emitter.kind != .lightning_bolts)) return error.InvalidSpellScenes;
                    if (emitter.repeat_until != 0 and (emitter.repeat_until < emitter.start or emitter.repeat_until >= emitter.flight_stop or (emitter.strike_at != 0 and emitter.repeat_until >= emitter.strike_at))) return error.InvalidSpellScenes;
                    if (emitter.strike_at != 0 and (!program.group or emitter.strike_at <= emitter.start or emitter.strike_at >= emitter.flight_stop or emitter.strike_radius < 2 or emitter.strike_radius > emitter.radius)) return error.InvalidSpellScenes;
                    if ((emitter.contact_holds or emitter.spark_stop != 0) and (!version14 or emitter.fixed_positions.len == 0 or emitter.spark_stop <= emitter.start or emitter.spark_stop >= emitter.stop)) return error.InvalidSpellScenes;
                    if (emitter.fixed_positions.len != 0) {
                        if (!version13 or emitter.kind != .lightning_bolts or emitter.fixed_positions.len != emitter.count or emitter.persistent_from >= emitter.count or emitter.focus_kick < 0 or emitter.focus_kick > 128 or emitter.repeat_until != 0 or emitter.strike_at != 0 or emitter.spark_life_range != 0) return error.InvalidSpellScenes;
                        if (emitter.spark_turn_at != 0) {
                            if (emitter.spark_turn_at < emitter.start or emitter.spark_turn_at >= emitter.stop or emitter.spark_turn_stop < emitter.spark_turn_at or emitter.spark_turn_stop >= emitter.stop or emitter.spark_turn_step <= 0 or emitter.spark_turn_step > 1024 or emitter.spark_turn_limit <= 0 or emitter.spark_turn_limit > 4096) return error.InvalidSpellScenes;
                        } else if (!version14 or emitter.spark_turn_stop != 0 or emitter.spark_turn_step != 0 or emitter.spark_turn_limit != 0) return error.InvalidSpellScenes;
                        for (emitter.fixed_positions) |position| for (position) |value| if (@abs(value) > 134217728) return error.InvalidSpellScenes;
                    } else if (emitter.target_height or emitter.persistent_from != 0 or emitter.spark_turn_at != 0 or emitter.spark_turn_stop != 0 or emitter.spark_turn_step != 0 or emitter.spark_turn_limit != 0 or (emitter.focus_kick != 0 and emitter.kind != .falling_trails and emitter.kind != .bouncing_sprites and emitter.kind != .ballistic_sprites and (!version19 or emitter.kind != .cycling_sprites))) return error.InvalidSpellScenes;
                    if (emitter.kind == .scheduled_pulses) {
                        for (program.objects) |object| if (object.particle_index != null and object.particle_index.? >= emitter.particle_start and @as(u16, object.particle_index.?) < @as(u16, emitter.particle_start) + emitter.count and object.particle_part != .pulse) return error.InvalidSpellScenes;
                        if (!version15 or emitter.count == 0 or emitter.height_range == 0 or emitter.pulse_spawns.len == 0 or emitter.pulse_spawns.len > 256 or emitter.pulse_life == 0 or emitter.pulse_fade_at >= emitter.pulse_life or emitter.pulse_grow <= 0 or emitter.pulse_grow > 4096 or emitter.pulse_shrink <= 0 or emitter.pulse_shrink > 4096 or 1 + @as(i32, emitter.pulse_life - emitter.pulse_fade_at) * emitter.pulse_grow > 65536) return error.InvalidSpellScenes;
                        for (emitter.pulse_spawns, 0..) |event, index| {
                            if (event.index >= emitter.count or event.at < emitter.start or event.at >= emitter.stop) return error.InvalidSpellScenes;
                            if (index > 0) {
                                const prior = emitter.pulse_spawns[index - 1];
                                if (event.at < prior.at or (!version20 and event.at == prior.at and event.index <= prior.index)) return error.InvalidSpellScenes;
                                for (emitter.pulse_spawns[0..index]) |other| if (event.at == other.at and event.index == other.index) return error.InvalidSpellScenes;
                            }
                        }
                    } else if (emitter.pulse_spawns.len != 0 or (emitter.height_range != 0 and (!version19 or emitter.kind != .cycling_sprites) and (!version20 or (emitter.kind != .orbiting_sprites and emitter.kind != .drifting_sprites and (!version24 or emitter.kind != .ballistic_sprites))))) return error.InvalidSpellScenes;
                    if (emitter.kind == .lightning_bolts) {
                        if (!version11 or emitter.count == 0 or emitter.spawn_at.len != emitter.count or emitter.flight_stop <= emitter.start or emitter.flight_stop > emitter.stop or emitter.spark_track >= program.tracks.len or emitter.pulse_track >= program.tracks.len or (emitter.spark_life_range == 0 and !version12) or emitter.spark_life_min == 0 or emitter.pulse_life == 0 or emitter.pulse_fade_at >= emitter.pulse_life or emitter.pulse_grow <= 0 or emitter.pulse_grow > 4096 or emitter.pulse_shrink <= 0 or emitter.pulse_shrink > 4096 or 1 + @as(i32, emitter.pulse_life - emitter.pulse_fade_at) * emitter.pulse_grow > 65536 or emitter.min_z >= 0 or emitter.min_z < -32767 or emitter.velocity_z <= 0 or emitter.velocity_z > 1048576) return error.InvalidSpellScenes;
                        for (emitter.spawn_at) |at| if (at < emitter.start or at >= emitter.flight_stop) return error.InvalidSpellScenes;
                    }
                    capacity += if (emitter.kind == .inward_lines or emitter.kind == .inward_points or emitter.kind == .rising_lines or emitter.kind == .falling_lines) emitter.count else 0;
                }
                if (program.screen_layers.len > 4) return error.InvalidSpellScenes;
                for (program.screen_layers) |layer| {
                    if (!version15 and layer.blend != .additive) return error.InvalidSpellScenes;
                    if (layer.entries.len == 0 or layer.entries.len > 128 or layer.copies == 0 or layer.copies > 2 or layer.samples.len > program.duration + 1) return error.InvalidSpellScenes;
                    for (layer.entries) |entry| if (entry >= self.entries.len) return error.InvalidSpellScenes;
                    for (layer.samples) |sample| if (sample) |value| {
                        if (value.rgb != null and !version17) return error.InvalidSpellScenes;
                        if (value.vertices.len != layer.entries.len) return error.InvalidSpellScenes;
                        for (value.vertices) |quad| for (quad) |xy| for (xy) |v| if (@abs(@as(i32, v)) > 4096) return error.InvalidSpellScenes;
                    };
                    capacity += layer.entries.len * layer.copies;
                }
                if (capacity > 512) return error.InvalidSpellScenes;
            } else if (spell.blocker == null or spell.blocker.?.len == 0) return error.InvalidSpellScenes;
        };
    }
};
pub fn load(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Packet) {
    const result = try std.json.parseFromSlice(Packet, allocator, bytes, .{});
    errdefer result.deinit();
    try result.value.validate(4096, 4096);
    return result;
}

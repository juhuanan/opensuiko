const std = @import("std");
const host = @import("../battle_actor_host.zig");
const vm = @import("../battle_actor_program.zig");
const camera = @import("battle_camera");
const physical = @import("../battle_physical.zig");
const counter_mod = @import("../battle_counter.zig");
const enemy_magic = @import("../battle_enemy_magic.zig");
const commander_mod = @import("../battle_commander.zig");
const enemy_wave = @import("../battle_enemy_wave.zig");
const unite_trick = @import("../battle_unite_trick.zig");
const unite_queue = @import("../battle_unite_queue.zig");

pub const Bundle = struct {
    schema: []const u8,
    programs: vm.Packet,
    animations: host.Resources,
    unites: []const host.UniteBinding,
    physical: ?[]const physical.Binding = null,
    counter: ?counter_mod.Bindings = null,
    enemy_magic: ?enemy_magic.Binding = null,
    commander: ?commander_mod.Binding = null,
    group_orders: ?[]const commander_mod.Binding = null,
    enemy_wave: ?enemy_wave.Binding = null,
    enemy_area_magic: ?[]const enemy_magic.AreaBinding = null,
    enemy_regional: ?[]const host.RegionalBinding = null,

    pub fn jsonStringify(self: Bundle, writer: anytype) !void {
        try writer.beginObject();
        inline for (.{ "schema", "programs", "animations", "unites" }) |name| {
            try writer.objectField(name);
            try writer.write(@field(self, name));
        }
        if (self.physical) |bindings| {
            try writer.objectField("physical");
            try writer.write(bindings);
        }
        if (self.counter) |bindings| {
            try writer.objectField("counter");
            try writer.write(bindings);
        }
        if (self.enemy_magic) |binding| {
            try writer.objectField("enemy_magic");
            try writer.write(binding);
        }
        if (self.commander) |binding| {
            try writer.objectField("commander");
            try writer.write(binding);
        }
        if (self.group_orders) |bindings| {
            try writer.objectField("group_orders");
            try writer.write(bindings);
        }
        if (self.enemy_wave) |binding| {
            try writer.objectField("enemy_wave");
            try writer.write(binding);
        }
        if (self.enemy_area_magic) |bindings| {
            try writer.objectField("enemy_area_magic");
            try writer.write(bindings);
        }
        if (self.enemy_regional) |bindings| {
            try writer.objectField("enemy_regional");
            try writer.write(bindings);
        }
        try writer.endObject();
    }

    pub fn regionalFor(self: Bundle, id: []const u8) ?*const host.RegionalBinding {
        for (self.enemy_regional orelse return null) |*binding| if (std.mem.eql(u8, binding.id, id)) return binding;
        return null;
    }

    pub fn areaMagicFor(self: Bundle, id: []const u8) ?enemy_magic.AreaBinding {
        for (self.enemy_area_magic orelse return null) |binding| if (std.mem.eql(u8, binding.id, id)) return binding;
        return null;
    }

    pub fn commanderFor(self: Bundle, id: []const u8) ?commander_mod.Binding {
        if (self.commander) |binding| if (std.mem.eql(u8, binding.id, id)) return binding;
        for (self.group_orders orelse return null) |binding| if (std.mem.eql(u8, binding.id, id)) return binding;
        return null;
    }

    pub fn physicalPacket(self: Bundle) ?physical.Packet {
        return .{ .schema = "suikoden-physical-actors/2", .programs = self.programs, .animations = self.animations, .techniques = self.physical orelse return null };
    }

    pub fn counterPacket(self: Bundle) ?counter_mod.Packet {
        const bindings = self.counter orelse return null;
        return .{
            .schema = if (bindings.hasSpecialReturnCamera()) "suikoden-counter-actors/13" else if (bindings.hasSpecialReturn()) "suikoden-counter-actors/12" else if (bindings.hasProjectileCamera()) "suikoden-counter-actors/11" else if (bindings.hasProjectile()) "suikoden-counter-actors/10" else if (bindings.party_melee != null) "suikoden-counter-actors/9" else if (bindings.hasSpecial()) "suikoden-counter-actors/8" else if (bindings.ranged != null and bindings.ranged.?.critical_camera != null) "suikoden-counter-actors/7" else if (bindings.ranged != null) "suikoden-counter-actors/6" else if (bindings.cooperation != null) "suikoden-counter-actors/5" else if (bindings.cover != null) "suikoden-counter-actors/4" else if (bindings.melee != null) "suikoden-counter-actors/3" else if (bindings.parries != null) "suikoden-counter-actors/2" else "suikoden-counter-actors/1",
            .programs = self.programs,
            .animations = self.animations,
            .defenders = bindings.defenders,
            .enemies = bindings.enemies,
            .parries = bindings.parries,
            .melee = bindings.melee,
            .cover = bindings.cover,
            .cooperation = bindings.cooperation,
            .ranged = bindings.ranged,
            .party_melee = bindings.party_melee,
        };
    }

    pub fn digest(self: Bundle) ![32]u8 {
        const bytes = try std.json.Stringify.valueAlloc(std.heap.page_allocator, self, .{});
        defer std.heap.page_allocator.free(bytes);
        var result: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
        return result;
    }

    pub fn library(self: Bundle) host.Library {
        return .{ .programs = self.programs, .resources = self.animations };
    }

    pub fn find(self: *const Bundle, record: u8) ?*const host.UniteBinding {
        for (self.unites) |*unite| if (unite.record == record) return unite;
        return null;
    }

    fn uniteActorsSchemaVersion(schema: []const u8) ?u8 {
        const prefix = "suikoden-unite-actors/";
        if (!std.mem.startsWith(u8, schema, prefix)) return null;
        const suffix = schema[prefix.len..];
        if (suffix.len == 0 or suffix[0] < '1' or suffix[0] > '9') return null;
        for (suffix) |ch| if (ch < '0' or ch > '9') return null;
        const version = std.fmt.parseInt(u8, suffix, 10) catch return null;
        return if (version <= 40) version else null;
    }

    pub fn validate(self: Bundle) !void {
        const schema_version = uniteActorsSchemaVersion(self.schema) orelse return error.InvalidUniteBindings;
        if (self.unites.len != 32) return error.InvalidUniteBindings;
        try self.validateSchemaFeatureMatrix(schema_version);
        try self.programs.validate();
        try self.animations.validate();
        try self.validateEnemyBindings(schema_version);
        try self.validateRegionalBindings(schema_version);
        try self.validateUniteBindings(schema_version);
        try self.validateProgramReferences(schema_version);
    }

    fn validateSchemaFeatureMatrix(self: Bundle, schema_version: u8) !void {
        const standalone22 = schema_version >= 22 and self.physical == null and self.counter == null and self.enemy_magic == null and self.commander == null and self.group_orders == null and self.enemy_wave == null and self.enemy_area_magic == null and self.enemy_regional == null;
        if ((self.enemy_area_magic != null) != (schema_version >= 39 and !standalone22)) return error.InvalidUniteBindings;
        if ((self.enemy_regional != null) != (schema_version >= 40 and !standalone22)) return error.InvalidUniteBindings;
        if ((self.enemy_wave != null) != (schema_version >= 38 and !standalone22)) return error.InvalidUniteBindings;
        if ((self.group_orders != null) != (schema_version >= 37 and !standalone22)) return error.InvalidUniteBindings;
        if ((self.counter != null and self.counter.?.hasProjectile()) != (schema_version >= 33 and !standalone22)) return error.InvalidUniteBindings;
        if ((self.counter != null and self.counter.?.hasSpecialReturnCamera()) != (schema_version >= 36 and !standalone22)) return error.InvalidUniteBindings;
        if ((self.counter != null and self.counter.?.hasSpecialReturn()) != (schema_version >= 35 and !standalone22)) return error.InvalidUniteBindings;
        if ((self.counter != null and self.counter.?.hasProjectileCamera()) != (schema_version >= 34 and !standalone22)) return error.InvalidUniteBindings;
        if ((self.commander != null) != (schema_version >= 32 and !standalone22)) return error.InvalidUniteBindings;
        if ((self.physical != null) != (schema_version >= 11 and !standalone22)) return error.InvalidUniteBindings;
        if ((self.counter != null) != (schema_version >= 12 and !standalone22)) return error.InvalidUniteBindings;
        if ((self.counter != null and self.counter.?.parries != null) != (schema_version >= 13 and !standalone22)) return error.InvalidUniteBindings;
        if ((self.counter != null and self.counter.?.melee != null) != (schema_version >= 14 and !standalone22)) return error.InvalidUniteBindings;
        if ((self.enemy_magic != null) != ((schema_version == 15 or schema_version == 17 or schema_version >= 19) and !standalone22)) return error.InvalidUniteBindings;
        if ((self.counter != null and self.counter.?.cover != null) != (schema_version >= 16 and !standalone22)) return error.InvalidUniteBindings;
        if ((self.counter != null and self.counter.?.cooperation != null) != (schema_version >= 18 and !standalone22)) return error.InvalidUniteBindings;
        if ((self.counter != null and self.counter.?.ranged != null) != (schema_version >= 20 and !standalone22)) return error.InvalidUniteBindings;
        if ((self.counter != null and self.counter.?.ranged != null and self.counter.?.ranged.?.critical_camera != null) != (schema_version >= 21 and !standalone22)) return error.InvalidUniteBindings;
        if ((self.counter != null and self.counter.?.hasSpecial()) != (schema_version >= 25 and !standalone22)) return error.InvalidUniteBindings;
        if ((self.counter != null and self.counter.?.party_melee != null) != (schema_version >= 31 and !standalone22)) return error.InvalidUniteBindings;
        if (self.physicalPacket()) |packet| try packet.validate();
        if (self.counterPacket()) |packet| try packet.validate();
    }

    fn validateEnemyBindings(self: Bundle, schema_version: u8) !void {
        if (self.enemy_wave) |binding| {
            try binding.validate(self.library());
            try self.validateProgram(self.animations.find(binding.id).?, binding.owner_program);
        }
        if (self.commander) |binding| {
            if (!std.mem.eql(u8, binding.id, "beast_commander")) return error.InvalidEnemyOrderBinding;
            try binding.validate(self.library());
            const resource = self.animations.find(binding.id).?;
            try self.validateProgram(resource, binding.order_program);
            try self.validateProgram(resource, binding.solo_program.?);
            for (self.counter.?.melee.?.party_reactions) |party| try self.validateProgram(self.animations.find(party.id).?, binding.recipient_program.?);
        }
        if (self.group_orders) |bindings| {
            if (bindings.len != 1) return error.InvalidEnemyOrderBinding;
            for (bindings) |binding| {
                if (!std.mem.eql(u8, binding.id, "whip_wolf")) return error.InvalidEnemyOrderBinding;
                try binding.validate(self.library());
                try self.validateProgram(self.animations.find(binding.id).?, binding.order_program);
            }
        }
        if (self.enemy_magic) |binding| {
            try binding.validate();
            const resource = self.animations.find(binding.id) orelse return error.MissingActorResource;
            try self.validateProgram(resource, binding.owner_program);
            if (self.programs.find(binding.recipient_program) == null) return error.MissingUniteProgram;
            for (self.counter.?.melee.?.party_reactions) |party| try self.validateProgram(self.animations.find(party.id).?, binding.recipient_program);
        }
        if (self.enemy_area_magic) |bindings| {
            if (schema_version < 39 or bindings.len != 3) return error.InvalidEnemyMagicBinding;
            for (bindings, 0..) |binding, i| {
                try binding.validate();
                for (bindings[0..i]) |prior| if (std.mem.eql(u8, prior.id, binding.id)) return error.InvalidEnemyMagicBinding;
                const resource = self.animations.find(binding.id) orelse return error.MissingActorResource;
                try self.validateProgram(resource, binding.owner_program);
                if (self.programs.find(binding.recipient_program) == null) return error.MissingUniteProgram;
                for (self.counter.?.melee.?.party_reactions) |party| try self.validateProgram(self.animations.find(party.id).?, binding.recipient_program);
                if (binding.wave_recipient_program) |wave_program| {
                    if (self.programs.find(wave_program) == null) return error.MissingUniteProgram;
                    for (self.counter.?.melee.?.party_reactions) |party| try self.validateProgram(self.animations.find(party.id).?, wave_program);
                }
            }
        }
        if (self.counter) |counter| if (counter.melee) |melee| {
            for (melee.party_reactions) |party| {
                if (schema_version >= 40) {
                    const ret = party.return_program orelse return error.InvalidCounterBindings;
                    try self.validateProgram(self.animations.find(party.id) orelse return error.MissingActorResource, ret);
                } else if (party.return_program != null) return error.InvalidCounterBindings;
            }
        };
    }

    fn validateRegionalBindings(self: Bundle, schema_version: u8) !void {
        if (self.enemy_regional) |bindings| {
            if (schema_version < 40 or bindings.len != 4 or self.counter == null or self.counter.?.melee == null) return error.InvalidUniteBindings;
            for (bindings, 0..) |binding, i| {
                if (binding.id.len == 0 or binding.id.len > 128) return error.InvalidUniteBindings;
                if (binding.front_roll_threshold > 100) return error.InvalidUniteBindings;
                if (binding.special_hits > 0 and (binding.shrink_step_q12 <= 0 or binding.shrink_min_q12 <= 0 or binding.expand_step_q12 <= 0 or binding.expand_target_q12 <= binding.shrink_min_q12)) return error.InvalidUniteBindings;
                if (binding.direct_attack and (binding.fade_updates == 0 or binding.camera_shake_z_q12 <= 0 or binding.camera_shake_z_q12 > 32767 * 4096)) return error.InvalidUniteBindings;
                if (binding.shadow_column) |column| {
                    if (!binding.direct_attack or column.segments < 3 or column.segments > 32 or
                        column.radial_start_q12 > 4096 or column.step_q12 == 0 or column.step_q12 > 4096 or
                        column.shape.radius < 0 or column.shape.radius > 1024 or column.shape.top_radius < 0 or column.shape.top_radius > 1024 or
                        @abs(column.shape.base_height) > 1024 or @abs(column.shape.height) > 1024) return error.InvalidUniteBindings;
                }
                if (binding.rear_triggers_special and (binding.vanish_phase_updates == 0 or binding.vanish_offset_q12 < 0)) return error.InvalidUniteBindings;
                if (binding.mirage_visual) |visual| {
                    if (!binding.rear_triggers_special or visual.copies == 0 or visual.copies > host.MirageVisual.max_copies or visual.copies % 2 == 0 or
                        visual.crop[2] == 0 or visual.crop[3] == 0 or visual.modulation == 0 or visual.modulation > 128 or
                        visual.spread_step_q12 == 0 or visual.spread_step_q12 > 4096) return error.InvalidUniteBindings;
                }
                for (bindings[0..i]) |prior| if (std.mem.eql(u8, prior.id, binding.id)) return error.InvalidUniteBindings;
                _ = self.animations.find(binding.id) orelse return error.MissingActorResource;
                var found_melee = false;
                for (self.counter.?.melee.?.enemies) |melee| if (std.mem.eql(u8, melee.id, binding.id)) {
                    found_melee = true;
                    break;
                };
                if (!found_melee) return error.InvalidCounterBindings;
                if (binding.special_recipient_return) |ret| {
                    if (self.programs.find(ret) == null) return error.MissingUniteProgram;
                    for (self.counter.?.melee.?.party_reactions) |party| try self.validateProgram(self.animations.find(party.id).?, ret);
                }
            }
        }
    }

    fn validateUniteBindings(self: Bundle, schema_version: u8) !void {
        const target_signals = schema_version >= 10;
        const grouped = schema_version >= 5;
        const phased = schema_version >= 4;
        const variants = schema_version >= 3;
        const scheduled = schema_version >= 2;
        const signals = schema_version >= 7;

        for (self.unites, 0..) |unite, index| {
            if (unite.record >= 32 or unite.name.len == 0 or unite.name.len > 128 or unite.members.len < 2 or unite.members.len > 4) return error.InvalidUniteBindings;
            if (unite.impact_effect != null and (schema_version < 24 or unite.damage_member == null or unite.controller != null or unite.dispatch_after == null)) return error.InvalidUniteBindings;
            if (!unite.damage_reaction and !target_signals) return error.InvalidUniteBindings;
            if (unite.damage_target_signal) |signal| {
                if (!target_signals or @popCount(signal) != 1 or unite.damage_member != null or unite.controller != null or unite.dispatch_after == null or unite.damage_signal != 2) return error.InvalidUniteBindings;
            }
            if (unite.controller) |spec| try validateUniteController(schema_version, unite, spec);
            for (self.unites[0..index]) |prior| if (prior.record == unite.record) return error.InvalidUniteBindings;
            if (@popCount(unite.damage_signal) != 1 or (unite.damage_signal != 2 and (!signals or unite.damage_member == null))) return error.InvalidUniteBindings;
            if (unite.damage_member) |member| if (!grouped or member >= unite.members.len or (unite.damage_signal == 2 and unite.members[member].reaction_on_hit)) return error.InvalidUniteBindings;
            if (unite.embedded_returns and (!phased or unite.return_program != null)) return error.InvalidUniteBindings;
            if (schema_version >= 29 and unite.record == 14 and unite.dispatch_after != null and unite.wave_heights == null) return error.InvalidUniteBindings;
            if (unite.wave_heights) |heights| {
                if (schema_version < 29 or unite.record != 14 or unite.members.len != 2 or unite.dispatch_after != 1 or unite.return_program == null or !std.mem.eql(u8, unite.return_program.?, "common/unite_return") or unite.controller != null or unite.target_queue != null or unite.beat_child != null or unite.transition != null or unite.embedded_returns or unite.damage_member != null or unite.damage_target_signal != null or !unite.damage_reaction or unite.assist_after_damage or unite.impact_effect != null) return error.InvalidUniteBindings;
                _ = unite_trick.State.init(heights) catch return error.InvalidUniteBindings;
                for (unite.members) |member| if (member.entry_program == null or member.programs.len != 1 or member.reaction_on_hit or member.deferred_entry or member.fan != null or member.loop_program != null or member.start_after != 0) return error.InvalidUniteBindings;
                const resource = self.animations.find(unite.members[1].id) orelse return error.MissingActorResource;
                const clip = resource.find(19) orelse return error.MissingActorAnimation;
                if (!clip.advances) return error.InvalidUniteBindings;
            }
            if (schema_version >= 28 and unite.record == 27 and unite.dispatch_after != null and unite.beat_child == null) return error.InvalidUniteBindings;
            if (unite.beat_child) |child| {
                if (schema_version < 28 or unite.record != 27 or unite.members.len != 2 or unite.dispatch_after != 1 or !unite.embedded_returns or unite.controller != null or unite.target_queue != null or unite.damage_member != 1 or unite.damage_signal != 2 or !unite.damage_reaction or unite.damage_target_signal != null or unite.assist_after_damage or unite.impact_effect != null) return error.InvalidUniteBindings;
                if (!std.mem.eql(u8, child.resource, unite.members[1].id) or child.owner != .self or child.home != .parent_owner or child.draw_record) return error.InvalidUniteBindings;
                const transition = unite.transition orelse return error.InvalidUniteBindings;
                if (transition.trigger_member != 0 or transition.signal != 16 or transition.dispatches.len != 1 or transition.dispatches[0].member != 1) return error.InvalidUniteBindings;
                for (unite.members, 0..) |member, ordinal| if (member.entry_program == null or member.deferred_entry or member.loop_program != null or member.start_after != 0 or member.fan != null or member.reaction_group or member.reaction_on_hit != (ordinal == 0) or member.reaction_variant != (if (ordinal == 0) @as(u8, 1) else 0)) return error.InvalidUniteBindings;
                const resource = self.animations.find(child.resource) orelse return error.MissingActorResource;
                if (resource.find(child.animation) == null) return error.MissingActorAnimation;
                try self.validateProgram(resource, child.program);
            }
            if (unite.transition) |transition| try self.validateUniteTransition(schema_version, unite, transition);
            if (unite.assist_after_damage and (!variants or unite.dispatch_after == null)) return error.InvalidUniteBindings;
            if (unite.dispatch_after) |after| if (!scheduled or after == 0 or after > 1000 or (unite.return_program == null and !unite.embedded_returns)) return error.InvalidUniteBindings;
            if (unite.record == 31 and unite.dispatch_after != null and schema_version >= 23) {
                if (unite.members.len != 2 or unite.controller != null or unite.transition != null or unite.damage_member != null or unite.damage_target_signal != null or unite.embedded_returns) return error.InvalidUniteBindings;
                for (unite.members) |member| if (member.loop_program == null or member.reaction_on_hit or member.deferred_entry or member.start_after != 0) return error.InvalidUniteBindings;
            }
            if (schema_version >= 27 and unite.record == 29 and unite.dispatch_after != null and unite.target_queue == null) return error.InvalidUniteBindings;
            if (unite.target_queue) |timing| {
                if (schema_version < 27 or unite.record != 29 or unite.members.len != 3 or unite.dispatch_after == null or unite.return_program == null or unite.controller != null or unite.transition != null or unite.damage_member != null or unite.damage_target_signal != null or unite.embedded_returns or unite.damage_reaction or unite.assist_after_damage or unite.impact_effect != null) return error.InvalidUniteBindings;
                _ = unite_queue.State.init(timing, @splat(false)) catch return error.InvalidUniteBindings;
                for (unite.members) |member| if (member.loop_program == null or member.entry_program == null or member.reaction_on_hit or member.deferred_entry or member.start_after != 0 or member.fan != null) return error.InvalidUniteBindings;
            }
            for (unite.members, 0..) |member, ordinal| try self.validateUniteMember(schema_version, unite, member, ordinal);
        }
    }

    fn validateUniteController(schema_version: u8, unite: host.UniteBinding, spec: host.SceneController) !void {
        const controllers = schema_version >= 9;
        if (!controllers or spec.vfx.len == 0 or spec.vfx.len > 40 or spec.trigger_member >= unite.members.len or @popCount(spec.signal) != 1 or spec.recipient_variant > 3 or spec.cleanup_at > 1000 or unite.dispatch_after == null or unite.return_program == null or unite.embedded_returns or unite.transition != null or unite.damage_member != null or unite.assist_after_damage) return error.InvalidUniteBindings;
        switch (spec.mode) {
            .beauty => if (spec.orbit != null or spec.return_at != null or spec.recipient_at == 0 or spec.recipient_at >= spec.damage_at or @as(u32, spec.damage_at) + 1 != spec.cleanup_at or spec.recipient_rolls.len == 0 or spec.recipient_rolls.len > spec.damage_at - spec.recipient_at) return error.InvalidUniteBindings,
            .owner_clock => if (spec.orbit != null or schema_version < 22 or spec.return_at == null or spec.damage_at == 0 or spec.damage_at >= spec.return_at.? or @as(u32, spec.return_at.?) + 1 != spec.cleanup_at or spec.recipient_at != 0 or spec.recipient_variant != 0 or spec.recipient_rolls.len != 0 or !unite.damage_reaction) return error.InvalidUniteBindings,
            .orbit => {
                const orbit = spec.orbit orelse return error.InvalidUniteBindings;
                if (schema_version < 26 or spec.return_at != null or orbit.anchor_member >= unite.members.len or orbit.hold_updates == 0 or orbit.divisor == 0 or orbit.heights_q12.len == 0 or orbit.heights_q12.len > 256 or @as(u32, orbit.hold_updates) + orbit.heights_q12.len >= spec.damage_at or spec.recipient_at <= orbit.hold_updates or spec.recipient_at >= spec.damage_at or spec.recipient_variant == 0 or spec.recipient_rolls.len != 0 or @as(u32, spec.damage_at) + 1 != spec.cleanup_at or unite.damage_reaction) return error.InvalidUniteBindings;
                if (@abs(@as(i64, orbit.base_z_q12)) > 32768 * 4096 or orbit.sounds.len > 16) return error.InvalidUniteBindings;
                for (orbit.heights_q12) |height| if (@abs(@as(i64, height)) > 32768 * 4096) return error.InvalidUniteBindings;
                for (orbit.sounds, 0..) |sound, i| if (sound.at == 0 or sound.at >= spec.cleanup_at or (i > 0 and sound.at <= orbit.sounds[i - 1].at)) return error.InvalidUniteBindings;
            },
        }
        for (unite.members) |member| if (member.reaction_on_hit or member.deferred_entry or member.fan != null) return error.InvalidUniteBindings;
        for (spec.recipient_rolls) |roll| if (roll < -4096 or roll > 4096) return error.InvalidUniteBindings;
    }

    fn validateUniteTransition(self: Bundle, schema_version: u8, unite: host.UniteBinding, transition: host.Transition) !void {
        const target_signals = schema_version >= 10;
        const signals = schema_version >= 7;
        const phased = schema_version >= 4;
        if (!phased or transition.trigger_member >= unite.members.len or @popCount(transition.signal) != 1 or transition.dispatches.len == 0 or transition.dispatches.len > unite.members.len) return error.InvalidUniteBindings;
        for (transition.dispatches, 0..) |dispatch, ordinal| {
            if (dispatch.member >= unite.members.len) return error.InvalidUniteBindings;
            for (transition.dispatches[0..ordinal]) |prior| if (prior.member == dispatch.member) return error.InvalidUniteBindings;
            var listed = false;
            for (unite.members[dispatch.member].programs) |id| listed = listed or std.mem.eql(u8, id, dispatch.program);
            if (!listed) return error.InvalidUniteBindings;
            const program = self.programs.find(dispatch.program) orelse return error.MissingUniteProgram;
            // Deferred dispatch must not change callback-visible signals or positions before its first wait.
            for (program.instructions) |instruction| {
                if (instruction != .command) break;
                switch (instruction.command) {
                    .animation, .highlight, .record_flags, .sound, .visible, .translucent, .reset_draw => {},
                    .shared_value => if (!target_signals) return error.InvalidUniteBindings,
                    .palette_cycle => if (schema_version < 24) return error.InvalidUniteBindings,
                    .effect => |effect| if (!target_signals or effect.binding != .shared or (!std.mem.eql(u8, effect.id, "blue_afterimages") and !(schema_version >= 24 and std.mem.eql(u8, effect.id, "palette_cycle")))) return error.InvalidUniteBindings,
                    .motion => |move| if (!signals or move.kind == .snap) return error.InvalidUniteBindings,
                    .offsets => |offset| if (!signals or offset.immediate) return error.InvalidUniteBindings,
                    else => return error.InvalidUniteBindings,
                }
            }
        }
    }

    fn validateUniteMember(self: Bundle, schema_version: u8, unite: host.UniteBinding, member: host.MemberBinding, ordinal: usize) !void {
        const target_signals = schema_version >= 10;
        const deferred = schema_version >= 8;
        const signals = schema_version >= 7;
        const fans = schema_version >= 6;
        const grouped = schema_version >= 5;
        const phased = schema_version >= 4;
        const variants = schema_version >= 3;

        if (member.hit_camera) |request| {
            if (!target_signals or !member.reaction_on_hit or request.updates == 0 or request.updates > 1000) return error.InvalidUniteBindings;
            _ = camera.ActorController.init(request.target) catch return error.InvalidUniteBindings;
        }
        if (member.deferred_entry) {
            if (!deferred or member.start_after != 0 or member.fan != null) return error.InvalidUniteBindings;
            const transition = unite.transition orelse return error.InvalidUniteBindings;
            if (transition.trigger_member == ordinal or unite.members[transition.trigger_member].deferred_entry) return error.InvalidUniteBindings;
            var dispatched = false;
            for (transition.dispatches) |dispatch| if (dispatch.member == ordinal) {
                dispatched = true;
            };
            if (!dispatched) return error.InvalidUniteBindings;
        }
        if (member.reaction_group and (!grouped or !member.reaction_on_hit)) return error.InvalidUniteBindings;
        if (member.reaction_variant > 3 or (member.reaction_variant > 0 and (!variants or !member.reaction_on_hit))) return error.InvalidUniteBindings;
        if (member.start_after > 0 and unite.dispatch_after == null and !(signals and unite.damage_signal != 2)) return error.InvalidUniteBindings;
        if (member.reaction_on_hit and unite.dispatch_after == null and (!grouped or unite.damage_member == null)) return error.InvalidUniteBindings;
        if (member.start_after > 1000 or @as(u32, unite.dispatch_after orelse 0) + member.start_after > 1000 or (unite.dispatch_after != null and member.programs.len != 1 and member.entry_program == null)) return error.InvalidUniteBindings;
        if (member.entry_program) |entry| {
            if (!phased) return error.InvalidUniteBindings;
            var listed = false;
            for (member.programs) |id| listed = listed or std.mem.eql(u8, id, entry);
            if (!listed) return error.InvalidUniteBindings;
        }
        if (member.loop_program) |loop| {
            if (schema_version < 23 or !((unite.record == 31 and unite.members.len == 2) or (unite.record == 29 and unite.members.len == 3 and unite.target_queue != null)) or unite.dispatch_after == null or member.entry_program == null or unite.return_program == null) return error.InvalidUniteBindings;
            var listed = false;
            for (member.programs) |id| listed = listed or std.mem.eql(u8, id, loop);
            if (!listed or std.mem.eql(u8, member.entry_program.?, loop)) return error.InvalidUniteBindings;
        }
        const resource = self.animations.find(member.id) orelse return error.MissingActorResource;
        if (member.fan) |fan| {
            if (!fans or std.mem.eql(i16, &fan.node_angles, &.{ 0, 0, 0 }) or @popCount(fan.signal) != 1 or fan.velocity_q12 < -1048576 or fan.velocity_q12 > 1048576) return error.InvalidUniteBindings;
            const clip = resource.find(fan.animation) orelse return error.MissingActorAnimation;
            if (clip.frames.len != 1 or clip.semitransparent) return error.InvalidUniteBindings;
        }
        if (resource.find(0) == null or member.programs.len == 0 or member.programs.len > 8) return error.InvalidUniteBindings;
        for (unite.members[0..ordinal]) |prior| if (std.mem.eql(u8, prior.id, member.id)) return error.InvalidUniteBindings;
        for (member.programs, 0..) |id, choice| {
            if (id.len <= member.id.len or !std.mem.startsWith(u8, id, member.id) or id[member.id.len] != '/') return error.InvalidUniteBindings;
            for (member.programs[0..choice]) |prior| if (std.mem.eql(u8, prior, id)) return error.InvalidUniteBindings;
            try self.validateProgram(resource, id);
        }
        if (unite.return_program) |id| try self.validateProgram(resource, id);
    }

    fn validateProgramReferences(self: Bundle, schema_version: u8) !void {
        for (self.programs.programs) |program| for (program.instructions) |instruction| {
            if (instruction == .command and instruction.command == .effect and std.mem.eql(u8, instruction.command.effect.id, "ivy_vine")) {
                const bindings = if (self.counter) |counter| counter.melee else null;
                const art = for ((bindings orelse return error.UnsupportedIvyComposition).enemies) |enemy| {
                    if (std.mem.eql(u8, enemy.attack_program, program.id)) break enemy.vine_art;
                } else null;
                if (schema_version < 30 or art == null or instruction.command.effect.binding != .self) return error.UnsupportedIvyComposition;
            }
            if (instruction == .command and instruction.command == .child) {
                const child = instruction.command.child;
                const resource = self.animations.find(child.resource) orelse return error.MissingActorResource;
                if (resource.find(child.animation) == null) return error.MissingActorAnimation;
                try self.validateProgram(resource, child.program);
            }
        };
    }

    fn validateProgram(self: Bundle, resource: host.Resource, id: []const u8) !void {
        const program = self.programs.find(id) orelse return error.MissingUniteProgram;
        for (program.instructions) |instruction| if (instruction == .command and instruction.command == .animation) {
            if (resource.find(instruction.command.animation) == null) return error.MissingActorAnimation;
        };
    }
};

pub fn loadBundle(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Bundle) {
    if (bytes.len > 16 * 1024 * 1024) return error.InvalidUniteBindings;
    const parsed = try std.json.parseFromSlice(Bundle, allocator, bytes, .{});
    errdefer parsed.deinit();
    try parsed.value.validate();
    return parsed;
}

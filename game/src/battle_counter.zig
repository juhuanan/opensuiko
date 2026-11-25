//! Counter callbacks over the shared actor VM; gameplay owns eligibility, HP and KO.
const std = @import("std");
const host = @import("battle_actor_host.zig");
const vm = @import("battle_actor_program.zig");

pub const Defender = struct { id: []const u8, response_program: []const u8, strike_program: []const u8, hurt_program: []const u8 };
pub const Attacker = struct { id: []const u8, attack_program: []const u8, return_program: []const u8 };
pub const Enemy = struct { id: []const u8, counterable: bool, attack_program: ?[]const u8, return_program: ?[]const u8 };
pub const ParryBindings = struct { attackers: []const Attacker, defenders: []const Defender };
pub const MeleeSpecial = struct {
    attack_program: []const u8,
    hurt_program: []const u8,
    return_program: ?[]const u8 = null,
    damage_numerator: u8 = 2,
    damage_denominator: u8 = 1,
    clear_contact_signal: bool = true,
    return_camera: ?RangedCamera = null,
    pub fn jsonStringify(self: MeleeSpecial, writer: anytype) !void {
        try writer.beginObject();
        inline for (.{ "attack_program", "hurt_program" }) |name| {
            try writer.objectField(name);
            try writer.write(@field(self, name));
        }
        if (self.return_program) |program| {
            try writer.objectField("return_program");
            try writer.write(program);
            try writer.objectField("damage_numerator");
            try writer.write(self.damage_numerator);
            try writer.objectField("damage_denominator");
            try writer.write(self.damage_denominator);
            if (!self.clear_contact_signal) {
                try writer.objectField("clear_contact_signal");
                try writer.write(false);
            }
            if (self.return_camera) |camera| {
                try writer.objectField("return_camera");
                try writer.write(camera);
            }
        }
        try writer.endObject();
    }
};
pub const SelfProjectile = struct {
    owner_program: []const u8,
    child_program: []const u8,
    animation: u16,
    position_z_q12: i32,
    camera: ?RangedCamera = null,
    pub fn jsonStringify(self: SelfProjectile, writer: anytype) !void {
        try writer.beginObject();
        inline for (.{ "owner_program", "child_program", "animation", "position_z_q12" }) |name| {
            try writer.objectField(name);
            try writer.write(@field(self, name));
        }
        if (self.camera) |value| {
            try writer.objectField("camera");
            try writer.write(value);
        }
        try writer.endObject();
    }
};
pub const MeleeEnemy = struct {
    id: []const u8,
    attack_program: []const u8,
    hurt_program: []const u8,
    return_program: []const u8,
    special: ?MeleeSpecial = null,
    projectile: ?SelfProjectile = null,
    vine_art: ?@import("battle_ivy.zig").Art = null,
    pub fn jsonStringify(self: MeleeEnemy, writer: anytype) !void {
        try writer.beginObject();
        inline for (.{ "id", "attack_program", "hurt_program", "return_program" }) |name| {
            try writer.objectField(name);
            try writer.write(@field(self, name));
        }
        if (self.special) |value| {
            try writer.objectField("special");
            try writer.write(value);
        }
        if (self.projectile) |value| {
            try writer.objectField("projectile");
            try writer.write(value);
        }
        if (self.vine_art) |value| {
            try writer.objectField("vine_art");
            try writer.write(value);
        }
        try writer.endObject();
    }
};
pub const PartyReaction = struct {
    id: []const u8,
    response_program: []const u8,
    return_program: ?[]const u8 = null,
    pub fn jsonStringify(self: PartyReaction, writer: anytype) !void {
        try writer.beginObject();
        try writer.objectField("id");
        try writer.write(self.id);
        try writer.objectField("response_program");
        try writer.write(self.response_program);
        if (self.return_program) |program| {
            try writer.objectField("return_program");
            try writer.write(program);
        }
        try writer.endObject();
    }
};
pub const MeleeBindings = struct { enemies: []const MeleeEnemy, party_reactions: []const PartyReaction };
pub const PartyAttacker = struct {
    id: []const u8,
    attack_program: []const u8,
    return_program: []const u8,
    hurt_program: []const u8,
    critical_hurt_program: ?[]const u8 = null,
    pub fn jsonStringify(self: PartyAttacker, writer: anytype) !void {
        try writer.beginObject();
        inline for (.{ "id", "attack_program", "return_program", "hurt_program" }) |name| {
            try writer.objectField(name);
            try writer.write(@field(self, name));
        }
        if (self.critical_hurt_program) |value| {
            try writer.objectField("critical_hurt_program");
            try writer.write(value);
        }
        try writer.endObject();
    }
};
pub const RangedAttacker = PartyAttacker;
pub const RangedCamera = struct { updates: u16, target: @import("battle_camera").Q12Block };
pub const RangedBindings = struct {
    attackers: []const RangedAttacker,
    dodges: []const PartyReaction,
    critical_camera: ?RangedCamera = null,
    pub fn jsonStringify(self: RangedBindings, writer: anytype) !void {
        try writer.beginObject();
        try writer.objectField("attackers");
        try writer.write(self.attackers);
        try writer.objectField("dodges");
        try writer.write(self.dodges);
        if (self.critical_camera) |value| {
            try writer.objectField("critical_camera");
            try writer.write(value);
        }
        try writer.endObject();
    }
};
pub const CoverBindings = struct { guard_program: []const u8, ward_program: []const u8, return_program: []const u8 };
pub const CooperationBinding = struct { id: []const u8, allies: []const []const u8, fallback_program: []const u8, approach_program: []const u8, lift_program: []const u8, launch_program: []const u8 };
pub const Cooperation = struct {
    active: bool = false,
    assistant: ?u8 = null,
    assistant_done: bool = false,
    pub fn advance(self: *Cooperation, binding: CooperationBinding, runtime: *host.Runtime, owner: u8, candidate: ?u8) !void {
        if (!self.active) return;
        const current = &runtime.actors[owner];
        const programs = runtime.library.?.programs;
        switch (current.shared_value) {
            0 => if (candidate) |ally| {
                if (ally == owner or ally >= runtime.actors.len) return error.InvalidActorBinding;
                self.assistant = ally;
                try runtime.dispatch(ally, owner, programs.find(binding.approach_program) orelse return error.MissingCounterProgram);
                current.shared_value = 1;
            } else {
                self.active = false;
                try runtime.dispatch(owner, current.owner, programs.find(binding.fallback_program) orelse return error.MissingCounterProgram);
            },
            1 => {
                const ally = self.assistant orelse return error.InvalidActorBinding;
                if (runtime.actors[ally].shared_value != 1) return;
                try runtime.dispatch(ally, current.owner, programs.find(binding.lift_program).?);
                current.shared_value += 1;
            },
            30 => {
                try runtime.dispatch(self.assistant orelse return error.InvalidActorBinding, current.owner, programs.find(binding.launch_program).?);
                current.shared_value += 1;
            },
            31 => {
                if (runtime.actors[self.assistant orelse return error.InvalidActorBinding].shared_value == 2) current.shared_value += 1;
            },
            20, 29, 32 => {},
            99 => self.active = false,
            else => current.shared_value +%= 1,
        }
    }
};
pub const Bindings = struct {
    defenders: []const Defender,
    enemies: []const Enemy,
    parries: ?ParryBindings = null,
    melee: ?MeleeBindings = null,
    cover: ?CoverBindings = null,
    cooperation: ?CooperationBinding = null,
    ranged: ?RangedBindings = null,
    party_melee: ?RangedBindings = null,
    pub fn hasSpecial(self: Bindings) bool {
        for ((self.melee orelse return false).enemies) |enemy| if (enemy.special != null) return true;
        return false;
    }
    pub fn hasProjectile(self: Bindings) bool {
        for ((self.melee orelse return false).enemies) |enemy| if (enemy.projectile != null) return true;
        return false;
    }
    pub fn hasProjectileCamera(self: Bindings) bool {
        for ((self.melee orelse return false).enemies) |enemy| if (enemy.projectile != null and enemy.projectile.?.camera != null) return true;
        return false;
    }
    pub fn hasSpecialReturn(self: Bindings) bool {
        for ((self.melee orelse return false).enemies) |enemy| if (enemy.special != null and enemy.special.?.return_program != null) return true;
        return false;
    }
    pub fn hasSpecialReturnCamera(self: Bindings) bool {
        for ((self.melee orelse return false).enemies) |enemy| if (enemy.special != null and enemy.special.?.return_camera != null) return true;
        return false;
    }
    pub fn jsonStringify(self: Bindings, writer: anytype) !void {
        try writer.beginObject();
        inline for (.{ "defenders", "enemies" }) |name| {
            try writer.objectField(name);
            try writer.write(@field(self, name));
        }
        if (self.parries) |value| {
            try writer.objectField("parries");
            try writer.write(value);
        }
        if (self.melee) |value| {
            try writer.objectField("melee");
            try writer.write(value);
        }
        if (self.cover) |value| {
            try writer.objectField("cover");
            try writer.write(value);
        }
        if (self.cooperation) |value| {
            try writer.objectField("cooperation");
            try writer.write(value);
        }
        if (self.ranged) |value| {
            try writer.objectField("ranged");
            try writer.write(value);
        }
        if (self.party_melee) |value| {
            try writer.objectField("party_melee");
            try writer.write(value);
        }
        try writer.endObject();
    }
};
pub const Kind = enum {
    counter,
    parry,
    ordinary_hit,
    ordinary_miss,
    special,
    cover,
    ranged_hit,
    ranged_miss,
    melee_hit,
    melee_miss,
    ordered,
    projectile,
    pub fn ordinary(self: Kind) bool {
        return self == .ordinary_hit or self == .ordered or self == .projectile or self == .ordinary_miss or self == .special or self == .cover or self.party();
    }
    pub fn melee(self: Kind) bool {
        return self == .melee_hit or self == .melee_miss;
    }
    pub fn party(self: Kind) bool {
        return self.ranged() or self.melee();
    }
    pub fn ranged(self: Kind) bool {
        return self == .ranged_hit or self == .ranged_miss;
    }
    pub fn miss(self: Kind) bool {
        return self == .ordinary_miss or self == .ranged_miss or self == .melee_miss;
    }
};
pub const Playback = struct {
    kind: Kind = .counter,
    attacker: u8,
    defender: u8,
    guard: ?u8 = null,
    start_at: u32,
    action: ?Action = null,
    contact_at: ?u32 = null,
    miss_at: ?u32 = null,
    critical: bool = false,
    amount: u32 = 0,
    controller_done: bool = false,
    attacker_done: bool = false,
    defender_done: bool = false,
    guard_done: bool = false,
    knockout_at: ?u32 = null,
    cooperation: Cooperation = .{},
    pub fn victim(self: Playback) u8 {
        return self.guard orelse if (self.kind.ordinary()) self.defender else self.attacker;
    }
    pub fn striker(self: Playback) u8 {
        return if (self.kind.ordinary()) self.attacker else self.defender;
    }
    pub fn showsMiss(self: Playback, actor: usize, now: u32) bool {
        const at = self.miss_at orelse return false;
        return actor == self.defender and now -% at < 30;
    }
};
pub const Packet = struct {
    schema: []const u8,
    programs: vm.Packet,
    animations: host.Resources,
    defenders: []const Defender,
    enemies: []const Enemy,
    parries: ?ParryBindings = null,
    melee: ?MeleeBindings = null,
    cover: ?CoverBindings = null,
    cooperation: ?CooperationBinding = null,
    ranged: ?RangedBindings = null,
    party_melee: ?RangedBindings = null,

    pub fn library(self: Packet) host.Library {
        return .{ .programs = self.programs, .resources = self.animations };
    }
    pub fn defender(self: Packet, id: []const u8) ?Defender {
        for (self.defenders) |binding| if (std.mem.eql(u8, id, binding.id)) return binding;
        return null;
    }
    pub fn enemy(self: Packet, id: []const u8) ?Enemy {
        for (self.enemies) |binding| if (std.mem.eql(u8, id, binding.id)) return binding;
        return null;
    }
    pub fn attackerFor(self: Packet, id: []const u8, kind: Kind) ?Attacker {
        if (kind.party()) {
            const binding = self.partyAttacker(id, kind) orelse return null;
            return .{ .id = binding.id, .attack_program = binding.attack_program, .return_program = binding.return_program };
        }
        if (kind.ordinary()) {
            const binding = self.meleeEnemy(id) orelse return null;
            const attack = if (kind == .special) (binding.special orelse return null).attack_program else if (kind == .projectile) (binding.projectile orelse return null).owner_program else binding.attack_program;
            const returning = if (kind == .special) binding.special.?.return_program orelse binding.return_program else binding.return_program;
            return .{ .id = binding.id, .attack_program = attack, .return_program = returning };
        }
        if (kind == .counter) {
            const binding = self.enemy(id) orelse return null;
            if (!binding.counterable) return null;
            return .{ .id = binding.id, .attack_program = binding.attack_program.?, .return_program = binding.return_program.? };
        }
        for ((self.parries orelse return null).attackers) |binding| if (std.mem.eql(u8, id, binding.id)) return binding;
        return null;
    }
    pub fn partyAttacker(self: Packet, id: []const u8, kind: Kind) ?PartyAttacker {
        const bindings = (if (kind.melee()) self.party_melee else self.ranged) orelse return null;
        for (bindings.attackers) |binding| if (std.mem.eql(u8, id, binding.id)) return binding;
        return null;
    }
    pub fn rangedAttacker(self: Packet, id: []const u8) ?RangedAttacker {
        for ((self.ranged orelse return null).attackers) |binding| if (std.mem.eql(u8, id, binding.id)) return binding;
        return null;
    }
    pub fn rangedDodge(self: Packet, id: []const u8) ?PartyReaction {
        if (self.party_melee) |bindings| for (bindings.dodges) |binding| if (std.mem.eql(u8, id, binding.id)) return binding;
        for ((self.ranged orelse return null).dodges) |binding| if (std.mem.eql(u8, id, binding.id)) return binding;
        return null;
    }
    pub fn meleeEnemy(self: Packet, id: []const u8) ?MeleeEnemy {
        for ((self.melee orelse return null).enemies) |binding| if (std.mem.eql(u8, id, binding.id)) return binding;
        return null;
    }
    pub fn partyReaction(self: Packet, id: []const u8) ?PartyReaction {
        for ((self.melee orelse return null).party_reactions) |binding| if (std.mem.eql(u8, id, binding.id)) return binding;
        return null;
    }
    pub fn defenderFor(self: Packet, id: []const u8, kind: Kind) ?Defender {
        if (kind == .counter) return self.defender(id);
        for ((self.parries orelse return null).defenders) |binding| if (std.mem.eql(u8, id, binding.id)) return binding;
        return null;
    }
    pub fn validateProgram(self: Packet, id: []const u8, resource: host.Resource) !void {
        const program = self.programs.find(id) orelse return error.MissingCounterProgram;
        for (program.instructions) |instruction| if (instruction == .command and instruction.command == .animation) {
            if (resource.find(instruction.command.animation) == null) return error.MissingActorAnimation;
        };
    }
    pub fn validate(self: Packet) !void {
        const thirteenth = std.mem.eql(u8, self.schema, "suikoden-counter-actors/13");
        const twelfth = std.mem.eql(u8, self.schema, "suikoden-counter-actors/12") or thirteenth;
        const eleventh = std.mem.eql(u8, self.schema, "suikoden-counter-actors/11") or twelfth;
        const tenth = std.mem.eql(u8, self.schema, "suikoden-counter-actors/10") or eleventh;
        const ninth = std.mem.eql(u8, self.schema, "suikoden-counter-actors/9") or tenth;
        if (ninth != (self.party_melee != null)) return error.InvalidCounterBindings;
        const eighth = std.mem.eql(u8, self.schema, "suikoden-counter-actors/8") or ninth;
        const seventh = std.mem.eql(u8, self.schema, "suikoden-counter-actors/7") or (eighth and self.ranged != null and self.ranged.?.critical_camera != null);
        const sixth = std.mem.eql(u8, self.schema, "suikoden-counter-actors/6") or seventh or (eighth and self.ranged != null);
        const fifth = std.mem.eql(u8, self.schema, "suikoden-counter-actors/5") or sixth or eighth;
        const fourth = std.mem.eql(u8, self.schema, "suikoden-counter-actors/4") or fifth;
        const third = std.mem.eql(u8, self.schema, "suikoden-counter-actors/3") or fourth;
        const second = std.mem.eql(u8, self.schema, "suikoden-counter-actors/2") or third;
        if ((!second and !std.mem.eql(u8, self.schema, "suikoden-counter-actors/1")) or second != (self.parries != null) or third != (self.melee != null) or fourth != (self.cover != null) or fifth != (self.cooperation != null) or sixth != (self.ranged != null) or self.defenders.len == 0 or self.defenders.len > 78 or self.enemies.len == 0 or self.enemies.len > 256) return error.InvalidCounterBindings;
        var has_special = false;
        var has_projectile = false;
        var has_camera = false;
        var has_special_return = false;
        var has_return_camera = false;
        if (self.melee) |melee| for (melee.enemies) |binding| {
            has_special = has_special or binding.special != null;
            has_projectile = has_projectile or binding.projectile != null;
            has_camera = has_camera or (binding.projectile != null and binding.projectile.?.camera != null);
            has_special_return = has_special_return or (binding.special != null and binding.special.?.return_program != null);
            has_return_camera = has_return_camera or (binding.special != null and binding.special.?.return_camera != null);
        };
        if (eighth != has_special) return error.InvalidCounterBindings;
        if (tenth != has_projectile) return error.InvalidCounterBindings;
        if (eleventh != has_camera) return error.InvalidCounterBindings;
        if (twelfth != has_special_return) return error.InvalidCounterBindings;
        if (thirteenth != has_return_camera) return error.InvalidCounterBindings;
        try self.programs.validate();
        try self.animations.validate();
        for ([2]?RangedBindings{ self.ranged, self.party_melee }, 0..) |maybe, family| if (maybe) |bindings| {
            const has_critical = family == 1 or seventh;
            if (bindings.attackers.len == 0 or bindings.attackers.len > 78 or bindings.dodges.len > 256) return error.InvalidCounterBindings;
            if (has_critical != (bindings.critical_camera != null)) return error.InvalidCounterBindings;
            if (bindings.critical_camera) |request| {
                if (request.updates == 0 or request.updates > 1000) return error.InvalidCounterBindings;
                try request.target.validate();
            }
            for (bindings.attackers, 0..) |binding, index| {
                for (bindings.attackers[0..index]) |prior| if (std.mem.eql(u8, prior.id, binding.id)) return error.InvalidCounterBindings;
                const resource = self.animations.find(binding.id) orelse return error.MissingActorResource;
                try self.validateProgram(binding.attack_program, resource);
                try self.validateProgram(binding.return_program, resource);
                if (self.programs.find(binding.hurt_program) == null) return error.MissingCounterProgram;
                if (has_critical != (binding.critical_hurt_program != null)) return error.InvalidCounterBindings;
                if (binding.critical_hurt_program) |program| if (self.programs.find(program) == null) return error.MissingCounterProgram;
            }
            for (bindings.dodges, 0..) |binding, index| {
                for (bindings.dodges[0..index]) |prior| if (std.mem.eql(u8, prior.id, binding.id)) return error.InvalidCounterBindings;
                const resource = self.animations.find(binding.id) orelse return error.MissingActorResource;
                try self.validateProgram(binding.response_program, resource);
            }
        };
        for (self.defenders, 0..) |binding, index| {
            for (self.defenders[0..index]) |prior| if (std.mem.eql(u8, prior.id, binding.id)) return error.InvalidCounterBindings;
            const resource = self.animations.find(binding.id) orelse return error.MissingActorResource;
            if (resource.find(0) == null) return error.MissingActorAnimation;
            inline for (.{ "response_program", "strike_program", "hurt_program" }) |name| try self.validateProgram(@field(binding, name), resource);
        }
        for (self.enemies, 0..) |binding, index| {
            for (self.enemies[0..index]) |prior| if (std.mem.eql(u8, prior.id, binding.id)) return error.InvalidCounterBindings;
            if (self.defender(binding.id) != null or binding.id.len == 0 or binding.id.len > 128 or binding.counterable != (binding.attack_program != null) or binding.counterable != (binding.return_program != null)) return error.InvalidCounterBindings;
            if (!binding.counterable) continue;
            const resource = self.animations.find(binding.id) orelse return error.MissingActorResource;
            if (resource.find(0) == null) return error.MissingActorAnimation;
            try self.validateProgram(binding.attack_program.?, resource);
            try self.validateProgram(binding.return_program.?, resource);
            for (self.defenders) |striker| try self.validateProgram(striker.hurt_program, resource);
        }
        if (self.parries) |parries| {
            if (parries.attackers.len != self.defenders.len or parries.defenders.len == 0 or parries.defenders.len > self.enemies.len) return error.InvalidCounterBindings;
            for (parries.attackers, 0..) |binding, index| {
                for (parries.attackers[0..index]) |prior| if (std.mem.eql(u8, prior.id, binding.id)) return error.InvalidCounterBindings;
                if (self.defender(binding.id) == null) return error.InvalidCounterBindings;
                const resource = self.animations.find(binding.id) orelse return error.MissingActorResource;
                try self.validateProgram(binding.attack_program, resource);
                try self.validateProgram(binding.return_program, resource);
            }
            for (parries.defenders, 0..) |binding, index| {
                for (parries.defenders[0..index]) |prior| if (std.mem.eql(u8, prior.id, binding.id)) return error.InvalidCounterBindings;
                if (self.enemy(binding.id) == null) return error.InvalidCounterBindings;
                const resource = self.animations.find(binding.id) orelse return error.MissingActorResource;
                inline for (.{ "response_program", "strike_program", "hurt_program" }) |name| try self.validateProgram(@field(binding, name), resource);
                for (parries.attackers) |recipient| try self.validateProgram(binding.hurt_program, self.animations.find(recipient.id).?);
            }
        }
        if (self.melee) |melee| {
            if (melee.enemies.len == 0 or melee.enemies.len > self.enemies.len or melee.party_reactions.len == 0 or melee.party_reactions.len > 78) return error.InvalidCounterBindings;
            for (melee.party_reactions, 0..) |binding, index| {
                for (melee.party_reactions[0..index]) |prior| if (std.mem.eql(u8, prior.id, binding.id)) return error.InvalidCounterBindings;
                if (self.enemy(binding.id) != null) return error.InvalidCounterBindings;
                const resource = self.animations.find(binding.id) orelse return error.MissingActorResource;
                try self.validateProgram(binding.response_program, resource);
            }
            for (melee.enemies, 0..) |binding, index| {
                for (melee.enemies[0..index]) |prior| if (std.mem.eql(u8, prior.id, binding.id)) return error.InvalidCounterBindings;
                if (self.enemy(binding.id) == null) return error.InvalidCounterBindings;
                const resource = self.animations.find(binding.id) orelse return error.MissingActorResource;
                if (binding.vine_art) |art| {
                    if (art.strip >= resource.pose_count or art.leaves[0] >= resource.pose_count or art.leaves[1] >= resource.pose_count or art.strip == art.leaves[0] or art.strip == art.leaves[1] or art.leaves[0] == art.leaves[1]) return error.InvalidCounterBindings;
                    for (art.leaf_extents) |extent| for (extent) |value| if (value == 0 or value > 512) return error.InvalidCounterBindings;
                }
                try self.validateProgram(binding.attack_program, resource);
                try self.validateProgram(binding.return_program, resource);
                for (melee.party_reactions) |recipient| try self.validateProgram(binding.hurt_program, self.animations.find(recipient.id).?);
                if (binding.projectile) |projectile| {
                    if (!std.mem.eql(u8, binding.id, "killer_rabbit") or projectile.animation != 16 or projectile.position_z_q12 != -81920 or resource.find(projectile.animation) == null) return error.InvalidCounterBindings;
                    try self.validateProgram(projectile.owner_program, resource);
                    try self.validateProgram(projectile.child_program, resource);
                    if (projectile.camera) |request| {
                        if (request.updates != 20) return error.InvalidCounterBindings;
                        try request.target.validate();
                    }
                }
                if (binding.special) |special| {
                    if (special.return_program) |program| {
                        if (std.mem.eql(u8, binding.id, "ninja_master")) {
                            if (special.damage_numerator != 3 or special.damage_denominator != 2 or !special.clear_contact_signal or special.return_camera != null) return error.InvalidCounterBindings;
                        } else if (std.mem.eql(u8, binding.id, "dagon")) {
                            if (special.damage_numerator != 1 or special.damage_denominator != 2 or special.clear_contact_signal or special.return_camera == null or special.return_camera.?.updates != 10) return error.InvalidCounterBindings;
                            try special.return_camera.?.target.validate();
                        } else return error.InvalidCounterBindings;
                        try self.validateProgram(program, resource);
                    } else if (special.damage_numerator != 2 or special.damage_denominator != 1 or special.return_camera != null) return error.InvalidCounterBindings;
                    try self.validateProgram(special.attack_program, resource);
                    for (melee.party_reactions) |recipient| try self.validateProgram(special.hurt_program, self.animations.find(recipient.id).?);
                }
            }
        }
        if (self.cover) |cover| for (self.melee.?.party_reactions) |party| {
            const resource = self.animations.find(party.id) orelse return error.MissingActorResource;
            inline for (.{ "guard_program", "ward_program", "return_program" }) |name| try self.validateProgram(@field(cover, name), resource);
        };
        if (self.cooperation) |binding| {
            if (self.meleeEnemy(binding.id) == null or binding.allies.len == 0 or binding.allies.len > self.enemies.len) return error.InvalidCounterBindings;
            try self.validateProgram(binding.fallback_program, self.animations.find(binding.id).?);
            for (binding.allies, 0..) |id, index| {
                for (binding.allies[0..index]) |prior| if (std.mem.eql(u8, prior, id)) return error.InvalidCounterBindings;
                if (self.enemy(id) == null) return error.InvalidCounterBindings;
                const resource = self.animations.find(id) orelse return error.MissingActorResource;
                inline for (.{ "approach_program", "lift_program", "launch_program" }) |name| try self.validateProgram(@field(binding, name), resource);
            }
        }
        for (self.programs.programs) |program| for (program.instructions) |instruction| if (instruction == .command and instruction.command == .child) {
            const child = instruction.command.child;
            const resource = self.animations.find(child.resource) orelse return error.MissingActorResource;
            if (resource.find(child.animation) == null) return error.MissingActorAnimation;
            try self.validateProgram(child.program, resource);
        };
        for (self.programs.programs) |program| for (program.instructions) |instruction| if (instruction == .command and instruction.command == .effect) {
            const effect = instruction.command.effect;
            if ((std.mem.eql(u8, effect.id, "ally_throw") or std.mem.eql(u8, effect.id, "fixed_projectile")) and (self.cooperation == null or effect.binding != .self)) return error.InvalidCounterBindings;
        };
    }
};
pub fn load(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Packet) {
    if (bytes.len > 16 * 1024 * 1024) return error.InvalidCounterBindings;
    const parsed = try std.json.parseFromSlice(Packet, allocator, bytes, .{});
    errdefer parsed.deinit();
    try parsed.value.validate();
    return parsed;
}

pub const Action = struct {
    kind: Kind = .counter,
    attacker: u8,
    defender: u8,
    guard: ?u8 = null,
    critical: bool = false,
    separate_special_return: bool = false,
    clear_special_contact: bool = false,
    regional_mode: enum { none, creeper_special, shadow_man, mirage_special } = .none,
    suikomi_shrunk: bool = false,
    multi_hits_remaining: u8 = 0,
    direct_special_hurt: ?[]const u8 = null,
    direct_special_return: ?[]const u8 = null,
    stage: enum { approach, response, strike, multi_hit, contact, hurt, returning, released } = .approach,

    pub fn callbackActor(self: Action) ?u8 {
        return switch (self.stage) {
            .approach, .multi_hit, .hurt => self.attacker,
            .response, .strike, .contact => self.defender,
            .returning, .released => null,
        };
    }

    pub fn configureRegional(self: *Action, packet: Packet, runtime: *host.Runtime, defender_slot: u8, regional: *const host.RegionalBinding) !void {
        const defender_resource = runtime.actors[defender_slot].resource orelse return error.MissingActorResource;
        if (regional.special_hits > 0) {
            const ret = regional.special_recipient_return orelse return error.InvalidCounterBindings;
            try packet.validateProgram(ret, defender_resource);
            const melee = packet.meleeEnemy(regional.id) orelse return error.InvalidCounterBindings;
            self.regional_mode = .creeper_special;
            self.multi_hits_remaining = regional.special_hits;
            self.direct_special_hurt = (melee.special orelse return error.InvalidCounterBindings).hurt_program;
            self.direct_special_return = ret;
        } else if (regional.direct_attack) {
            const reaction = packet.partyReaction(defender_resource.id) orelse return error.InvalidCounterBindings;
            const ret = reaction.return_program orelse return error.InvalidCounterBindings;
            try packet.validateProgram(ret, defender_resource);
            const melee = packet.meleeEnemy(regional.id) orelse return error.InvalidCounterBindings;
            self.regional_mode = .shadow_man;
            self.direct_special_hurt = melee.hurt_program;
        } else if (regional.rear_triggers_special and self.kind == .special) {
            self.regional_mode = .mirage_special;
        }
    }

    pub fn begin(packet: Packet, runtime: *host.Runtime, attacker: u8, defender_slot: u8) !Action {
        return beginFor(packet, runtime, attacker, defender_slot, .counter);
    }
    pub fn beginFor(packet: Packet, runtime: *host.Runtime, attacker: u8, defender_slot: u8, kind: Kind) !Action {
        if (kind == .cover) return error.InvalidActorBinding;
        return beginWithGuard(packet, runtime, attacker, defender_slot, kind, null);
    }
    pub fn beginCovered(packet: Packet, runtime: *host.Runtime, attacker: u8, ward: u8, guard: u8) !Action {
        if (guard == attacker or guard == ward or guard >= runtime.actors.len) return error.InvalidActorBinding;
        return beginWithGuard(packet, runtime, attacker, ward, .cover, guard);
    }
    fn beginWithGuard(packet: Packet, runtime: *host.Runtime, attacker: u8, defender_slot: u8, kind: Kind, guard: ?u8) !Action {
        if (attacker == defender_slot or attacker >= runtime.actors.len or defender_slot >= runtime.actors.len) return error.InvalidActorBinding;
        const attacker_resource = runtime.actors[attacker].resource orelse return error.MissingActorResource;
        const defender_resource = runtime.actors[defender_slot].resource orelse return error.MissingActorResource;
        const origin = packet.attackerFor(attacker_resource.id, kind) orelse return error.InvalidCounterBindings;
        try packet.validateProgram(origin.attack_program, attacker_resource);
        try packet.validateProgram(origin.return_program, attacker_resource);
        if (guard) |protector| {
            const cover = packet.cover orelse return error.InvalidCounterBindings;
            const resource = runtime.actors[protector].resource orelse return error.MissingActorResource;
            try packet.validateProgram(cover.guard_program, resource);
            try packet.validateProgram(cover.ward_program, defender_resource);
            try packet.validateProgram(cover.return_program, defender_resource);
            try packet.validateProgram(packet.meleeEnemy(attacker_resource.id).?.hurt_program, resource);
        } else if (kind.party()) {
            const binding = packet.partyAttacker(attacker_resource.id, kind) orelse return error.InvalidCounterBindings;
            try packet.validateProgram(binding.hurt_program, defender_resource);
            if (kind.miss()) try packet.validateProgram((packet.rangedDodge(defender_resource.id) orelse return error.InvalidCounterBindings).response_program, defender_resource);
        } else if (kind.ordinary()) {
            const responder = packet.partyReaction(defender_resource.id) orelse return error.InvalidCounterBindings;
            try packet.validateProgram(responder.response_program, defender_resource);
            const melee = packet.meleeEnemy(attacker_resource.id).?;
            try packet.validateProgram(if (kind == .special) melee.special.?.hurt_program else melee.hurt_program, defender_resource);
        } else {
            const responder = packet.defenderFor(defender_resource.id, kind) orelse return error.InvalidCounterBindings;
            try packet.validateProgram(responder.response_program, defender_resource);
            try packet.validateProgram(responder.strike_program, defender_resource);
            try packet.validateProgram(responder.hurt_program, attacker_resource);
        }
        const saved_attacker = runtime.actors[attacker];
        const saved_defender = runtime.actors[defender_slot];
        errdefer if (kind == .projectile) {
            runtime.actors[attacker] = saved_attacker;
            runtime.actors[defender_slot] = saved_defender;
        };
        runtime.actors[attacker].signals = 0;
        if (guard) |protector| {
            try runtime.dispatch(protector, defender_slot, packet.programs.find(packet.cover.?.guard_program).?);
            try runtime.dispatch(defender_slot, protector, packet.programs.find(packet.cover.?.ward_program).?);
        }
        if (kind == .projectile) {
            const projectile = packet.meleeEnemy(attacker_resource.id).?.projectile.?;
            try packet.validateProgram(projectile.child_program, attacker_resource);
            const slot = blk: {
                var index = runtime.auxiliary.len;
                while (index > 0) {
                    index -= 1;
                    if (runtime.auxiliary[index] == null) break :blk index;
                }
                return error.NoProjectileActor;
            };
            var child = try host.Actor.initAnimation(attacker_resource, runtime.actors[defender_slot].home_q12, projectile.animation);
            child.position_q12 = runtime.actors[attacker].position_q12;
            child.position_q12[2] = projectile.position_z_q12;
            child.graphic_record = runtime.actors[attacker].graphic_record;
            errdefer runtime.auxiliary[slot] = null;
            runtime.auxiliary[slot] = child;
            const id = std.math.cast(u16, runtime.actors.len + slot) orelse return error.InvalidActorBinding;
            try runtime.dispatch(id, attacker, packet.programs.find(projectile.child_program).?);
            try runtime.dispatch(attacker, defender_slot, packet.programs.find(origin.attack_program).?);
        } else try runtime.dispatch(attacker, defender_slot, packet.programs.find(origin.attack_program).?);
        return .{ .kind = kind, .attacker = attacker, .defender = defender_slot, .guard = guard, .separate_special_return = kind == .special and packet.meleeEnemy(attacker_resource.id).?.special.?.return_program != null, .clear_special_contact = kind == .special and packet.meleeEnemy(attacker_resource.id).?.special.?.clear_contact_signal };
    }
    // Poll once before the ascending actor sweep; never collapse two callbacks into one.
    pub fn advance(self: *Action, packet: Packet, runtime: *host.Runtime) !void {
        if (self.regional_mode == .creeper_special) {
            switch (self.stage) {
                .approach => {
                    if (!self.suikomi_shrunk and runtime.actors[self.attacker].signals & 1 != 0) {
                        self.suikomi_shrunk = true;
                        runtime.actors[self.defender].draw_size_q12 = 4096;
                        runtime.actors[self.defender].suikomi_phase = .shrink_spin;
                        try runtime.dispatch(self.defender, self.attacker, packet.programs.find(self.direct_special_hurt.?).?);
                    }
                    if (runtime.actors[self.attacker].signals & 2 != 0) self.stage = .multi_hit;
                },
                .multi_hit => {
                    if (self.multi_hits_remaining > 0 and runtime.actors[self.attacker].signals & 16 != 0) {
                        self.stage = .contact;
                    } else if (self.multi_hits_remaining == 0 and runtime.actors[self.attacker].signals & 4 != 0) {
                        runtime.actors[self.defender].suikomi_phase = .spit_expand;
                        try runtime.dispatch(self.defender, self.attacker, packet.programs.find(self.direct_special_return.?).?);
                        self.stage = .hurt;
                    }
                },
                .returning => {
                    const enemy_actor = runtime.actors[self.attacker];
                    const party_actor = runtime.actors[self.defender];
                    if (enemy_actor.machine.?.halted and enemy_actor.highlights == 0 and party_actor.machine.?.halted and party_actor.highlights == 0 and party_actor.suikomi_phase == null) self.stage = .released;
                },
                .response, .strike, .contact, .hurt, .released => {},
            }
            return;
        }
        if (self.regional_mode == .shadow_man) {
            switch (self.stage) {
                .approach => if (runtime.actors[self.attacker].signals & 2 != 0) {
                    try runtime.dispatch(self.defender, self.attacker, packet.programs.find(self.direct_special_hurt.?).?);
                    self.stage = .strike;
                },
                .strike => if (runtime.actors[self.attacker].signals & 16 != 0) {
                    self.stage = .contact;
                },
                .returning => {
                    const enemy_actor = runtime.actors[self.attacker];
                    const party_actor = runtime.actors[self.defender];
                    if (enemy_actor.machine.?.halted and enemy_actor.highlights == 0 and party_actor.machine.?.halted and party_actor.highlights == 0) self.stage = .released;
                },
                .response, .multi_hit, .contact, .hurt, .released => {},
            }
            return;
        }
        if (self.kind.ordinary() and self.stage == .approach) {
            const signal: u16 = if (!self.kind.miss()) 2 else 1;
            if (runtime.actors[self.attacker].signals & signal == 0) return;
            if (!self.kind.miss()) self.stage = .contact else {
                const reaction = if (self.kind.party()) packet.rangedDodge(runtime.actors[self.defender].resource.?.id).? else packet.partyReaction(runtime.actors[self.defender].resource.?.id).?;
                try runtime.dispatch(self.defender, self.attacker, packet.programs.find(reaction.response_program).?);
                self.stage = .hurt;
            }
            return;
        }
        switch (self.stage) {
            .approach => if (runtime.actors[self.attacker].signals & 1 != 0) {
                const responder = packet.defenderFor(runtime.actors[self.defender].resource.?.id, self.kind).?;
                try runtime.dispatch(self.defender, self.attacker, packet.programs.find(responder.response_program).?);
                self.stage = .response;
            },
            .response => if (runtime.actors[self.defender].signals & 2 != 0) {
                const responder = packet.defenderFor(runtime.actors[self.defender].resource.?.id, self.kind).?;
                runtime.actors[self.defender].signals = 0;
                try runtime.dispatch(self.defender, self.attacker, packet.programs.find(responder.strike_program).?);
                self.stage = .strike;
            },
            .strike => if (runtime.actors[self.defender].signals & 2 != 0) {
                self.stage = .contact;
            },
            .returning => {
                const enemy_actor = runtime.actors[self.attacker];
                const party_actor = runtime.actors[self.defender];
                if (enemy_actor.machine.?.halted and enemy_actor.highlights == 0 and party_actor.machine.?.halted and party_actor.highlights == 0) self.stage = .released;
            },
            .contact, .multi_hit, .hurt, .released => {},
        }
    }
    // Commit HP/RNG first. Failure keeps the contact pending for replay rollback.
    pub fn acknowledgeContact(self: *Action, packet: Packet, runtime: *host.Runtime) !void {
        if (self.stage != .contact) return error.CounterContactNotReady;
        if (self.regional_mode == .creeper_special) {
            runtime.actors[self.attacker].signals &= ~@as(u16, 16);
            self.multi_hits_remaining -= 1;
            self.stage = .multi_hit;
            return;
        }
        if (self.regional_mode == .shadow_man) {
            runtime.actors[self.attacker].signals &= ~@as(u16, 16);
            self.stage = .hurt;
            return;
        }
        if (self.kind == .ordinary_hit or self.kind == .ordered or self.kind == .projectile or self.kind == .special or self.kind == .cover or self.kind == .ranged_hit or self.kind == .melee_hit) {
            const hurt = if (self.kind.party()) blk: {
                const ranged = packet.partyAttacker(runtime.actors[self.attacker].resource.?.id, self.kind).?;
                break :blk if (self.critical) ranged.critical_hurt_program orelse ranged.hurt_program else ranged.hurt_program;
            } else blk: {
                const melee = packet.meleeEnemy(runtime.actors[self.attacker].resource.?.id).?;
                break :blk if (self.kind == .special) melee.special.?.hurt_program else melee.hurt_program;
            };
            // Source group orders dispatch hurt directly, without the ordinary acknowledgement.
            if ((self.kind != .special or self.regional_mode == .mirage_special) and self.kind != .ordered and self.kind != .projectile) runtime.actors[self.attacker].signals |= 16;
            try runtime.dispatch(self.guard orelse self.defender, self.attacker, packet.programs.find(hurt).?);
            if (self.kind == .special and self.separate_special_return and self.clear_special_contact) runtime.actors[self.attacker].signals &= ~@as(u16, 2);
            if (self.guard) |guard| try runtime.dispatch(self.defender, guard, packet.programs.find(packet.cover.?.return_program).?);
            self.stage = .hurt;
            return;
        }
        const responder = packet.defenderFor(runtime.actors[self.defender].resource.?.id, self.kind).?;
        runtime.actors[self.defender].signals = 0;
        try runtime.dispatch(self.attacker, self.defender, packet.programs.find(responder.hurt_program).?);
        self.stage = .hurt;
    }
    pub fn returnReady(self: Action, runtime: host.Runtime) bool {
        return self.stage == .hurt and if ((self.kind == .special and !self.separate_special_return) or self.kind == .projectile or self.regional_mode == .shadow_man) runtime.actors[self.attacker].released else runtime.actors[self.attacker].signals & 4 != 0;
    }
    // The scene retains the actor through the return and any later KO tail.
    pub fn beginReturn(self: *Action, packet: Packet, runtime: *host.Runtime) !void {
        if (!self.returnReady(runtime.*)) return error.CounterReturnNotReady;
        if ((self.kind != .special or self.separate_special_return) and self.kind != .projectile and self.regional_mode != .shadow_man) {
            if (self.kind == .special) if (packet.meleeEnemy(runtime.actors[self.attacker].resource.?.id).?.special.?.return_camera) |request| {
                const controller = runtime.camera_controller orelse return error.MissingActorCamera;
                try controller.requestQ12(request.target, request.updates);
            };
            const origin = packet.attackerFor(runtime.actors[self.attacker].resource.?.id, self.kind).?;
            try runtime.dispatch(self.attacker, self.defender, packet.programs.find(origin.return_program).?);
        }
        self.stage = .returning;
    }
};

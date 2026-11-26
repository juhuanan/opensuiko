const std = @import("std");
const battle = @import("battle");
const world = @import("world");
const field_link = @import("world_field");
const combat_session = @import("combat_session");
const combat_world_gate = @import("combat_world_gate");
const battle_systems = @import("battle_systems");
const techniques_mod = battle_systems.techniques;
const outcomes_mod = battle_systems.outcomes;
const battle_host = battle_systems.host;
pub const json = @import("world_battle_data").json;
pub const json_c = @import("world_battle_data").json_c;

pub const Data = struct {
    presentation: ?battle.world_art.Data = null,
    actor_content: ?battle.Content = null,
    schema: []const u8,
    protection: battle.Protection,
    round_start: battle.RoundStart,
    medicine_timings: []const battle.MedicineTiming,
    party_attacks: []const battle.PartyAttackTiming,
    enemies: []const battle.Profile,
    encounters: []const battle.Encounter,
    unsupported_enemies: []const []const u8,

    pub fn supportsActorContent(self: Data) bool {
        return std.mem.eql(u8, self.schema, "suikoden-world-battle/28") or
            std.mem.eql(u8, self.schema, "suikoden-world-battle/29") or
            std.mem.eql(u8, self.schema, "suikoden-world-battle/30") or
            std.mem.eql(u8, self.schema, "suikoden-world-battle/31");
    }

    pub fn jsonStringify(self: Data, writer: anytype) !void {
        try writer.beginObject();
        inline for (@typeInfo(Data).@"struct".field_names) |name| {
            if (comptime std.mem.eql(u8, name, "actor_content")) {
                if (self.actor_content) |value| {
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

    pub fn view(self: Data, travel: world.Content, base: battle.Content) !battle.Content {
        const cooperation_actors = std.mem.eql(u8, self.schema, "suikoden-world-battle/30") or std.mem.eql(u8, self.schema, "suikoden-world-battle/31");
        const magic_actors = cooperation_actors or std.mem.eql(u8, self.schema, "suikoden-world-battle/29");
        const actors = self.supportsActorContent();
        if (self.actor_content != null and !actors) return error.UnsupportedWorldBattleSchema;
        const dodge_schema = actors or std.mem.eql(u8, self.schema, "suikoden-world-battle/25") or std.mem.eql(u8, self.schema, "suikoden-world-battle/26");
        const impact_schema = dodge_schema or std.mem.eql(u8, self.schema, "suikoden-world-battle/23") or std.mem.eql(u8, self.schema, "suikoden-world-battle/24");
        const motion_schema = impact_schema or std.mem.eql(u8, self.schema, "suikoden-world-battle/21") or std.mem.eql(u8, self.schema, "suikoden-world-battle/22");
        const current = motion_schema or std.mem.eql(u8, self.schema, "suikoden-world-battle/20") or std.mem.eql(u8, self.schema, "suikoden-world-battle/18") or std.mem.eql(u8, self.schema, "suikoden-world-battle/19");
        const c_region = actors or std.mem.eql(u8, self.schema, "suikoden-world-battle/26") or std.mem.eql(u8, self.schema, "suikoden-world-battle/24") or std.mem.eql(u8, self.schema, "suikoden-world-battle/22") or std.mem.eql(u8, self.schema, "suikoden-world-battle/19") or std.mem.eql(u8, self.schema, "suikoden-world-battle/14") or std.mem.eql(u8, self.schema, "suikoden-world-battle/15") or std.mem.eql(u8, self.schema, "suikoden-world-battle/16") or std.mem.eql(u8, self.schema, "suikoden-world-battle/17");
        if (!current and !c_region and !std.mem.eql(u8, self.schema, "suikoden-world-battle/13")) return error.UnsupportedWorldBattleSchema;
        if (!std.mem.eql(u8, travel.id, if (c_region) "region_c" else "region_b")) return error.WorldRegionMismatch;
        const unsupported: []const []const u8 = if (cooperation_actors) &.{} else if (magic_actors) &.{"strong_arm"} else if (actors) &.{ "kobold_type_3", "strong_arm" } else if (c_region) &.{ "kobold_type_1", "kobold_type_3", "strong_arm" } else &.{ "killer_rabbit", "beast_commander" };
        if (base.systems == null or self.enemies.len != travel.enemies.len or self.encounters.len != travel.encounters.len or self.unsupported_enemies.len != unsupported.len) return error.InvalidWorldBattleData;
        for (unsupported, self.unsupported_enemies) |expected, actual| if (!std.mem.eql(u8, expected, actual)) return error.InvalidWorldBattleData;
        for (travel.enemies) |expected| {
            const found = for (self.enemies) |enemy| {
                if (std.mem.eql(u8, expected.id, enemy.id)) break enemy;
            } else return error.UnknownWorldEnemy;
            const expected_policy: @TypeOf(found.action_policy) = if (c_region) (if (std.mem.eql(u8, found.id, "kobold_type_2")) .front_projectile else if ((actors and std.mem.eql(u8, found.id, "kobold_type_1")) or (cooperation_actors and std.mem.eql(u8, found.id, "strong_arm"))) .source_melee else if (magic_actors and std.mem.eql(u8, found.id, "kobold_type_3")) .source_magic else .unsupported) else if (std.mem.eql(u8, found.id, "killer_rabbit")) .rabbit else if (std.mem.eql(u8, found.id, "beast_commander")) .commander else if (std.mem.eql(u8, found.id, "roc")) .roc else .attack;
            if (found.action_policy != expected_policy) return error.InvalidWorldBattleData;
            if (dodge_schema and found.dodges_attacks and found.action_policy != .unsupported and found.action_policy != .rabbit and found.action_policy != .commander and found.action_policy != .source_melee and found.action_policy != .source_magic and found.dodge == null) return error.MissingWorldDodge;
            if (std.mem.eql(u8, found.id, "flying_squirrel") and found.ordered_attack == null) return error.MissingWorldOrderedTiming;
            if (std.mem.eql(u8, found.id, "flying_squirrel") and found.knockout_ticks == null) return error.MissingWorldKnockoutTiming;
            if (found.drops == null) return error.InvalidWorldBattleData;
            if (found.level != expected.level or !std.mem.eql(u8, found.name, expected.name)) return error.InvalidWorldBattleData;
        }
        for (travel.encounters, self.encounters) |expected, actual| {
            if (current and actual.bribe_cost == null) return error.MissingBribeCost;
            if (!std.mem.eql(u8, expected.id, actual.id)) return error.InvalidWorldBattleData;
            const slots = actual.source_slots orelse return error.MissingWorldEnemySlots;
            var compact: usize = 0;
            for (expected.enemies, 0..) |id, slot| if (id) |enemy_id| {
                if (compact >= actual.enemies.len or compact >= slots.len or slots[compact] != slot or !std.mem.eql(u8, enemy_id, actual.enemies[compact])) return error.InvalidWorldBattleData;
                compact += 1;
            };
            if (compact != actual.enemies.len or compact != slots.len) return error.InvalidWorldBattleData;
        }
        var result = base;
        const item_actors = (battle.battleSchemaVersion(result.schema) orelse return error.UnsupportedBattleSchema) >= 31;
        if (actors and !item_actors) result.schema = if (magic_actors) "suikoden-battle-trial/30" else "suikoden-battle-trial/29";
        result.protection = self.protection;
        result.round_start = self.round_start;
        if (!item_actors) result.medicine_timings = self.medicine_timings;
        result.party_attacks = self.party_attacks;
        if (motion_schema) for (self.party_attacks) |timing| if (timing.motion == null) return error.MissingPartyAttackMotion;
        if (impact_schema) for (self.party_attacks) |timing| if (timing.impacts == null or timing.critical_camera == null) return error.MissingPartyImpactData;
        if (dodge_schema) for (self.party_attacks) |timing| if (timing.dodge_start_tick == null) return error.MissingPartyDodgeTiming;
        for (base.party) |profile| {
            var found = false;
            for (self.protection.characters) |entry| if (std.mem.eql(u8, entry.id, profile.id)) {
                found = true;
            };
            if (!found) return error.InvalidProtectionData;
        }
        result.enemies = self.enemies;
        result.encounters = self.encounters;
        result.scenery = &.{};
        // Core rosters stay simulation-only; Adapter binds validated B media for formation4.
        // Other formations need their own asset/track binding; media approval remains separate.
        result.presentation_ready = false;
        try result.validate();
        return result;
    }
    pub fn supports(self: Data, encounter: battle.Encounter) bool {
        if (self.actor_content) |content| {
            var found = false;
            for (content.encounters) |entry| if (std.mem.eql(u8, entry.id, encounter.id)) {
                found = true;
            };
            if (!found and (self.presentation == null or !std.mem.eql(u8, self.presentation.?.encounter, encounter.id))) return false;
        }
        for (encounter.enemies) |id| {
            for (self.unsupported_enemies) |unsupported| if (std.mem.eql(u8, id, unsupported)) return false;
            if (std.mem.eql(u8, id, "kobold_type_1") or std.mem.eql(u8, id, "kobold_type_3") or std.mem.eql(u8, id, "strong_arm")) {
                const content = self.actor_content orelse return false;
                var found = false;
                for (content.encounters) |entry| if (std.mem.eql(u8, entry.id, encounter.id)) {
                    found = true;
                };
                if (!found) return false;
            }
        }
        return true;
    }
    pub fn bindPresentation(self: Data, allocator: std.mem.Allocator, base: battle.Content, index: usize, members: []const battle.Member, formation: [6]u8) !struct { content: battle.Content, encounter: usize } {
        const encounter = base.encounters[index];
        if (self.actor_content) |content| if (for (content.encounters, 0..) |entry, source_index| {
            if (std.mem.eql(u8, entry.id, encounter.id)) break @as(?usize, source_index);
        } else @as(?usize, null)) |source_index| {
            if ((!std.mem.eql(u8, self.schema, "suikoden-world-battle/28") and !std.mem.eql(u8, self.schema, "suikoden-world-battle/29") and !std.mem.eql(u8, self.schema, "suikoden-world-battle/30") and !std.mem.eql(u8, self.schema, "suikoden-world-battle/31")) or content.world_art != null or !content.presentation_ready) return error.InvalidWorldBattleData;
            try content.validate();
            if (!try sameValue(allocator, encounter, content.encounters[source_index])) return error.InvalidWorldBattleData;
            // Appended source scenery preserves the base atlas and every party profile's coordinates.
            for (members) |member| {
                const original = base.partyProfile(member.id) orelse return error.InvalidWorldBattleData;
                const supplied = content.partyProfile(member.id) orelse return error.InvalidWorldBattleData;
                if (!try sameValue(allocator, original, supplied)) return error.WorldPartyArtMismatch;
            }
            for (content.enemies) |enemy| {
                var original = base.enemies[base.enemyIndex(enemy.id) orelse return error.InvalidWorldBattleData];
                original.sprite = enemy.sprite;
                original.attack = enemy.attack;
                if (enemy.action_policy == .source_projectile and original.action_policy == .front_projectile and std.mem.eql(u8, self.schema, "suikoden-world-battle/31")) {
                    original.action_policy = .source_projectile;
                    original.front_projectile = null;
                }
                if ((enemy.action_policy != .source_melee and enemy.action_policy != .source_magic and enemy.action_policy != .source_projectile) or !try sameValue(allocator, original, enemy)) return error.InvalidWorldBattleData;
            }
            var result = content;
            result.party = base.party;
            result.initial_party = base.initial_party;
            result.systems = base.systems;
            result.protection = base.protection;
            result.round_start = base.round_start;
            result.party_attacks = base.party_attacks;
            result.medicine_timings = base.medicine_timings;
            try result.validate();
            return .{ .content = result, .encounter = source_index };
        };
        if (self.presentation) |art| {
            if (!std.mem.eql(u8, encounter.id, art.encounter)) return error.UnsupportedWorldBattlePresentation;
            var result = try art.bind(base, index, members, formation);
            if (self.actor_content) |content| result.ground = content.ground;
            try result.validate();
            return .{ .content = result, .encounter = 0 };
        }
        for (encounter.enemies) |id| if (base.enemies[base.enemyIndex(id).?].action_policy == .source_melee or base.enemies[base.enemyIndex(id).?].action_policy == .source_magic or base.enemies[base.enemyIndex(id).?].action_policy == .source_projectile) return error.MissingSourceActorPresentation;
        return .{ .content = base, .encounter = index };
    }
};
fn sameValue(allocator: std.mem.Allocator, left: anytype, right: @TypeOf(left)) !bool {
    const a = try std.json.Stringify.valueAlloc(allocator, left, .{});
    defer allocator.free(a);
    const b = try std.json.Stringify.valueAlloc(allocator, right, .{});
    defer allocator.free(b);
    return std.mem.eql(u8, a, b);
}
fn checkActorBindings(state: battle.State, content: battle.Content, encounter: usize) !void {
    var checked = state;
    checked.content = content;
    for (content.encounters[encounter].enemies) |id| {
        const enemy = content.enemies[content.enemyIndex(id).?];
        if (enemy.action_policy != .source_melee and enemy.action_policy != .source_magic and enemy.action_policy != .source_projectile) continue;
        const bundle = state.unite_actors orelse return error.MissingWorldActorLibrary;
        const packet = bundle.counterPacket() orelse return error.MissingWorldActorLibrary;
        if (packet.meleeEnemy(id) == null) return error.MissingWorldActorLibrary;
        if (std.mem.eql(u8, id, "strong_arm") and packet.cooperation == null) return error.MissingWorldActorLibrary;
        if (enemy.action_policy == .source_magic and state.unite_actors.?.enemy_magic == null) return error.MissingWorldActorLibrary;
    }
    for (content.encounters[encounter].enemies) |id| {
        const enemy = content.enemies[content.enemyIndex(id).?];
        if (enemy.action_policy != .source_melee and enemy.action_policy != .source_magic and enemy.action_policy != .source_projectile) continue;
        try checked.attachUniteActors(state.unite_actors.?);
        checked.spell_scenes = state.spell_scenes orelse return error.MissingWorldReactionArt;
        const pose = for (checked.spell_scenes.?.hurt_poses) |entry| {
            if (std.mem.eql(u8, entry.id, enemy.id)) break entry;
        } else return error.MissingWorldReactionArt;
        if (pose.knockout == null or pose.impact_offset == null or pose.white_entry == null) return error.MissingWorldReactionArt;
        if (enemy.action_policy == .source_magic and checked.spell_scenes.?.enemy_magic_art == null) return error.MissingWorldReactionArt;
    }
}
pub fn load(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Data) {
    if (bytes.len > 4 * 1024 * 1024) return error.InvalidWorldBattleData;
    const version = try std.json.parseFromSlice(struct { schema: []const u8 }, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer version.deinit();
    if (!std.mem.eql(u8, version.value.schema, "suikoden-world-battle/31") and !std.mem.eql(u8, version.value.schema, "suikoden-world-battle/30") and !std.mem.eql(u8, version.value.schema, "suikoden-world-battle/29") and !std.mem.eql(u8, version.value.schema, "suikoden-world-battle/28") and !std.mem.eql(u8, version.value.schema, "suikoden-world-battle/26") and !std.mem.eql(u8, version.value.schema, "suikoden-world-battle/25") and !std.mem.eql(u8, version.value.schema, "suikoden-world-battle/24") and !std.mem.eql(u8, version.value.schema, "suikoden-world-battle/23") and !std.mem.eql(u8, version.value.schema, "suikoden-world-battle/22") and !std.mem.eql(u8, version.value.schema, "suikoden-world-battle/21") and !std.mem.eql(u8, version.value.schema, "suikoden-world-battle/20") and !std.mem.eql(u8, version.value.schema, "suikoden-world-battle/19") and !std.mem.eql(u8, version.value.schema, "suikoden-world-battle/18") and !std.mem.eql(u8, version.value.schema, "suikoden-world-battle/13") and !std.mem.eql(u8, version.value.schema, "suikoden-world-battle/14") and !std.mem.eql(u8, version.value.schema, "suikoden-world-battle/15") and !std.mem.eql(u8, version.value.schema, "suikoden-world-battle/16") and !std.mem.eql(u8, version.value.schema, "suikoden-world-battle/17")) return error.UnsupportedWorldBattleSchema;
    return std.json.parseFromSlice(Data, allocator, bytes, .{ .allocate = .alloc_always });
}

/// Source loadout identity for the loadout transition guard.  The shared
/// `Member` record carries the rune charges but not the weapon-fragment vector
/// or the lock byte, so fragments are zero on both sides and the lock comes
/// from the profile; a rune/weapon/member substitution is still refused.
pub fn loadoutOf(host: *const battle_host.Host, state: *const battle.State, index: usize) !techniques_mod.carry.Loadout {
    const owned = state.ownedMember(index);
    const character = host.characterId(owned.id) orelse return error.MissingCharacterIdentity;
    const rune_byte: u8 = state.runeByteFor(index) orelse 0;
    if (!techniques_mod.carry.validRuneByte(rune_byte)) return error.InvalidRuneByte;
    return .{
        .member = character,
        .weapon_level = owned.weapon_level,
        .rune = .{ .byte = rune_byte, .charges = owned.rune_charges, .locked = state.partyProfile(index).rune_locked },
        .fragments = .{},
    };
}

fn liveEnemies(state: *const battle.State) u32 {
    var count: u32 = 0;
    for (0..state.enemyCount()) |index| {
        if (state.enemy_hp[index] > 0) count += 1;
    }
    return count;
}

/// The production reward gate for one battle end.  A victory with a set end or
/// defeat flag is not a victory and is refused by the callers.
fn consequenceOf(state: *const battle.State) outcomes_mod.Consequence {
    return battle_host.classify(.{
        .live_enemies = liveEnemies(state),
        .end_flag = state.phase == .escaped,
        .defeat_flag = state.phase == .defeat,
    });
}

// Borrows the parsed overlay and the caller's existing owned party/combat state.
pub const Adapter = struct {
    original: ?battle.Content = null,
    original_encounter: usize = 0,
    transaction: ?*Transaction = null,
    /// Loadout baseline for the non-transactional battle entry.
    carry: [6]?techniques_mod.carry.Loadout = @splat(null),
    /// Scripted-outcome host.  Only a caller that supplies a
    /// real packet battle id can begin it; the ordinary route has no invented
    /// mapping and uses `consequenceOf`.
    scripted: ?battle_host.ScriptedOutcome = null,
    const Transaction = struct {
        scratch: [6]battle.Member = undefined,
        admitted: [6]battle.OwnedMember = undefined,
        original: battle.State,
        session: combat_session.Session = undefined,
        fingerprint: [64]u8 = undefined,
        receipt_buffer: [20]u8 = undefined,
        receipt: u64,
        bribe_before: ?u32 = null,
        carry: [6]?techniques_mod.carry.Loadout = @splat(null),
    };
    pub fn jsonStringify(self: Adapter, writer: anytype) !void {
        try writer.beginObject();
        try writer.objectField("original");
        try writer.write(self.original);
        try writer.objectField("original_encounter");
        try writer.write(self.original_encounter);
        if (self.transaction) |tx| {
            try writer.objectField("transaction");
            try writer.write(.{ .entry = tx.session.entry, .state = tx.session.state, .draws = tx.session.draws, .receipt = tx.receipt, .original = tx.original });
        }
        try writer.endObject();
    }
    pub fn deinit(self: *Adapter, allocator: std.mem.Allocator) void {
        if (self.transaction) |value| allocator.destroy(value);
        self.transaction = null;
    }
    pub fn beginTransactional(self: *Adapter, link: *field_link.Session, combat: *battle.State, data: Data, draws: world.Draws, last_receipt: u64) !void {
        if (self.original != null or self.transaction != null or link.travel.mode != .battle or combat.pending_enemy_actor != null or combat.coordinator != null) return error.WorldBattleNotReady;
        if (combat.partyCount() != 6) return error.UnsupportedWorldCombatParty;
        if (!combat.progress.party.equal(link.field_state.progress.party)) return error.WorldPartyMismatch;
        var view = try data.view(link.content, combat.content);
        const id = link.travel.selected orelse return error.WorldBattleNotReady;
        var index = for (view.encounters, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.id, id)) break i;
        } else return error.UnknownWorldEncounter;
        if (!data.supports(view.encounters[index])) return error.UnsupportedWorldEncounter;
        const bound = try data.bindPresentation(link.allocator, view, index, combat.progress.party.values()[0..combat.partyCount()], combat.formationOrder());
        view = bound.content;
        index = bound.encounter;
        try checkActorBindings(combat.*, view, index);
        const receipt = std.math.add(u64, last_receipt, 1) catch return error.CombatReceiptOverflow;
        const tx = try link.allocator.create(Transaction);
        errdefer link.allocator.destroy(tx);
        tx.original = combat.*;
        tx.receipt = receipt;
        tx.bribe_before = null;
        for (0..combat.partyCount()) |i| tx.admitted[i] = combat.ownedMember(i);
        if (combat.integrationHost()) |host| for (0..combat.partyCount()) |i| {
            tx.carry[i] = try loadoutOf(host, combat, i);
        };
        var source = combat.*;
        source.content = view;
        source.encounter = index;
        tx.fingerprint = try combat_session.fingerprint(source);
        const receipt_text = try std.fmt.bufPrint(&tx.receipt_buffer, "{d}", .{receipt});
        tx.session = try combat_session.Session.begin(.{ .id = "world_encounter", .receipt = receipt_text, .content_id = link.content.id, .encounter_id = id, .content_fingerprint = &tx.fingerprint }, source, tx.scratch[0..combat.partyCount()], draws);
        self.transaction = tx;
        combat.* = tx.session.state;
    }
    pub fn tickTransactional(self: *Adapter, link: *field_link.Session, combat: *battle.State, input: battle.Input, draws: *world.Draws, last_receipt: *u64) !Result {
        const tx = self.transaction orelse return error.WorldBattleNotReady;
        const saved_session = tx.session;
        const saved_members = tx.scratch;
        const saved_draws = draws.*;
        const saved_bribe = tx.bribe_before;
        errdefer {
            tx.session = saved_session;
            tx.scratch = saved_members;
            draws.* = saved_draws;
            tx.bribe_before = saved_bribe;
        }
        if (tx.session.state.phase == .defeat) {
            if (consequenceOf(&tx.session.state).branch != .defeat) return error.InvalidBattleConsequence;
            return .defeated;
        }
        if (input.confirm and (tx.session.state.phase == .escaped or (tx.session.state.phase == .victory and tx.session.state.rewardReady()))) {
            if (tx.receipt != (std.math.add(u64, last_receipt.*, 1) catch return error.CombatReceiptOverflow)) return error.InvalidCombatReceipt;
            // The reward gate runs before anything is committed.  A
            // victory requires both source result flags clear and a zero live
            // count; an end request returns to the field without rewards.
            const consequence = consequenceOf(&tx.session.state);
            switch (tx.session.state.phase) {
                .victory => if (consequence.branch != .victory or !consequence.rewards or consequence.action != .return_to_field) return error.InvalidBattleConsequence,
                .escaped => if (consequence.branch != .no_reward_end) return error.InvalidBattleConsequence,
                else => {},
            }
            const result = try tx.session.result(draws.*);
            if (link.field_state.progress.money != tx.original.progress.money) return error.StaleCombatMoney;
            if (result.outcome == .bribed) {
                const amount = tx.bribe_before orelse return error.InvalidBribeResult;
                const cost = tx.session.state.content.encounters[tx.session.state.encounter].bribe_cost orelse return error.MissingBribeCost;
                if (amount < cost or result.money != amount - cost) return error.InvalidBribeResult;
            } else if (tx.bribe_before != null) return error.InvalidBribeResult;
            const plan = try combat_world_gate.returnPlan(link.content, link.travel, tx.session.entry, result);
            if (plan.after.mode != .world) return error.InvalidWorldBattleReturn;
            if (result.member_count != tx.original.partyCount()) return error.InvalidCombatResult;
            var members: [6]battle.Member = undefined;
            var next = tx.session.state;
            next.content = tx.original.content;
            next.encounter = tx.original.encounter;
            next.progress.party = .init(members[0..result.member_count]);
            for (0..result.member_count) |i| {
                const current = tx.original.ownedMember(i);
                if (!std.meta.eql(current, tx.admitted[i]) or !std.mem.eql(u8, current.id, result.members[i].id)) return error.StaleCombatParty;
                try tx.original.validateOwnedMember(result.members[i]);
                members[i] = current;
                next.setOwnedMember(i, result.members[i]);
            }
            if (next.integrationHost()) |host| for (0..result.member_count) |i| {
                const destination = try loadoutOf(host, &next, i);
                _ = techniques_mod.carry.carry(tx.carry[i].?, destination) catch return error.LoadoutIdentityChanged;
            };
            var seen: [6]bool = @splat(false);
            for (result.formation) |slot| {
                if (slot >= result.member_count or seen[slot]) return error.InvalidFormation;
                seen[slot] = true;
            }
            next.setFormation(result.formation);
            next.progress.money = result.money;
            next.clearSleep();
            next.clearTemporaryStats();
            next.unbalanced = @splat(0);
            next.medicine_action = null;
            try next.progress.validate();
            var acknowledged = tx.session;
            try acknowledged.acknowledge(draws.*);
            const destination = tx.original.progress.party;
            destination.copyFrom(members[0..result.member_count]);
            next.progress.party = destination;
            next.setFormation(result.formation);
            link.travel = plan.after;
            link.field_state.progress.* = next.progress;
            combat.* = next;
            last_receipt.* = tx.receipt;
            self.transaction = null;
            link.allocator.destroy(tx);
            return .returned;
        }
        const before_phase = tx.session.state.phase;
        const before_money = tx.session.state.progress.money;
        const before_bribed = tx.session.state.bribed_enemies;
        const before_can_escape = tx.session.state.canEscape();
        const before_cost = tx.session.state.content.encounters[tx.session.state.encounter].bribe_cost;
        try tx.session.tick(input, draws);
        if (tx.session.state.bribed_enemies and !before_bribed) {
            const cost = before_cost orelse return error.MissingBribeCost;
            if (before_phase != .battle_menu or !input.confirm or input.cancel or tx.session.state.selection != 2 or !before_can_escape or before_money < cost or tx.session.state.progress.money != before_money - cost or !std.meta.eql(saved_draws, draws.*)) return error.InvalidBribeResult;
            tx.bribe_before = before_money;
        }
        combat.* = tx.session.state;
        return if (combat.phase == .defeat) .defeated else .running;
    }
    pub fn begin(self: *Adapter, session: *field_link.Session, combat: *battle.State, data: Data) !void {
        if (self.original != null or session.travel.mode != .battle or combat.pending_enemy_actor != null or combat.coordinator != null) return error.WorldBattleNotReady;
        if (!combat.progress.party.equal(session.field_state.progress.party)) return error.WorldPartyMismatch;
        var view = try data.view(session.content, combat.content);
        const id = session.travel.selected orelse return error.WorldBattleNotReady;
        var index = for (view.encounters, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.id, id)) break i;
        } else return error.UnknownWorldEncounter;
        const bound = try data.bindPresentation(session.allocator, view, index, combat.progress.party.values()[0..combat.partyCount()], combat.formationOrder());
        view = bound.content;
        index = bound.encounter;
        try checkActorBindings(combat.*, view, index);
        try session.field_state.progress.validate();
        self.original = combat.content;
        self.original_encounter = combat.encounter;
        combat.content = view;
        combat.encounter = index;
        combat.progress = session.field_state.progress.*;
        combat.escape_allowed = view.encounters[index].escape_allowed;
        combat.reward_drop = false;
        combat.quit_requested = false;
        combat.startEncounter();
        if (combat.integrationHost()) |host| for (0..combat.partyCount()) |i| {
            self.carry[i] = loadoutOf(host, combat, i) catch return error.LoadoutIdentityChanged;
        };
    }
    pub const Result = enum { running, returned, defeated };
    pub fn tick(self: *Adapter, session: *field_link.Session, combat: *battle.State, input: battle.Input, draws: *world.Draws) !Result {
        if (self.original == null or session.travel.mode != .battle) return error.WorldBattleNotReady;
        if (input.restart or combat.phase == .complete or combat.phase == .confirm_quit) return error.UnsupportedWorldBattleControl;
        if (combat.phase == .defeat) {
            if (consequenceOf(combat).branch != .defeat) return error.InvalidBattleConsequence;
            return .defeated;
        }
        if (combat.phase == .battle_menu and input.cancel) return .running;
        if (input.confirm and (combat.phase == .escaped or (combat.phase == .victory and combat.rewardReady()))) {
            const consequence = consequenceOf(combat);
            switch (combat.phase) {
                .victory => if (consequence.branch != .victory or !consequence.rewards or consequence.action != .return_to_field) return error.InvalidBattleConsequence,
                .escaped => if (consequence.branch != .no_reward_end) return error.InvalidBattleConsequence,
                else => {},
            }
            if (combat.integrationHost()) |host| for (0..combat.partyCount()) |i| {
                if (self.carry[i]) |source| {
                    const destination = try loadoutOf(host, combat, i);
                    _ = techniques_mod.carry.carry(source, destination) catch return error.LoadoutIdentityChanged;
                }
            };
            const outcome: world.Outcome = if (combat.phase == .victory) .victory else if (combat.released_enemies) .released else .fled;
            try session.finishBattle(outcome, combat.progress);
            combat.clearSleep();
            combat.clearTemporaryStats();
            combat.unbalanced = @splat(0);
            combat.medicine_action = null;
            combat.content = self.original.?;
            combat.encounter = self.original_encounter;
            self.original = null;
            self.carry = @splat(null);
            return .returned;
        }
        try combat.tickReplay(input, draws);
        return if (combat.phase == .defeat) .defeated else .running;
    }

    /// Begin a declared scripted battle result.  `battle_id` must be a real id
    /// in the control-draws contract; the caller supplies the source-qualified binding.
    pub fn beginScripted(self: *Adapter, host: *const battle_host.Host, battle_id: []const u8, token: u64) !void {
        if (self.scripted != null) return error.ScriptedOutcomeBusy;
        self.scripted = try battle_host.ScriptedOutcome.begin(host.outcomeAsset(), battle_id, token);
    }

    pub fn resolveScripted(self: *Adapter, signal: outcomes_mod.Signal) !outcomes_mod.Consequence {
        const scripted = if (self.scripted) |*value| value else return error.ScriptedOutcomeMissing;
        return scripted.resolve(signal);
    }

    pub fn commitScripted(self: *Adapter) !outcomes_mod.Receipt {
        const scripted = if (self.scripted) |*value| value else return error.ScriptedOutcomeMissing;
        return scripted.commit();
    }

    pub fn captureScripted(self: *const Adapter) ?outcomes_mod.Capture {
        if (self.scripted) |value| return value.capture();
        return null;
    }

    pub fn restoreScripted(self: *Adapter, snapshot: outcomes_mod.Capture) !void {
        const scripted = if (self.scripted) |*value| value else return error.ScriptedOutcomeMissing;
        return scripted.restore(snapshot);
    }
};

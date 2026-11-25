//! Shared fixtures and helpers for integrated battle-system tests.

const std = @import("std");
pub const battle_systems = @import("battle_systems");
pub const host_mod = battle_systems.host;
pub const battle = @import("battle");
pub const rules = @import("battle_rules");
pub const field = @import("field");
pub const world_battle = @import("world_battle");
pub const combat_session = @import("combat_session");
pub const spells_mod = battle_systems.spells;
pub const techniques_mod = battle_systems.techniques;
pub const unite_mod = battle_systems.unite;
pub const outcomes_mod = battle_systems.outcomes;

pub const allocator = std.testing.allocator;

pub fn hostFixture() !*host_mod.Host {
    return host_mod.Host.init(allocator);
}

pub fn firstLiving(state: battle.State, party: bool) ?usize {
    const start: usize = if (party) 0 else state.partyCount();
    const end = if (party) state.partyCount() else state.partyCount() + state.enemyCount();
    for (start..end) |index| if (state.participates(index)) return index;
    return null;
}

pub const Tape = struct {
    values: [8192]u15 = undefined,

    pub fn init(self: *Tape) rules.Draws {
        for (&self.values, 0..) |*value, index| value.* = @intCast((index * 37 + 11) % 32767);
        return .{ .values = &self.values };
    }
};

pub const Fixture = struct {
    content: std.json.Parsed(battle.Content),
    items: std.json.Parsed(field.items.Rules),
    /// A mutable enemy copy so a case can raise one target's HP and observe an
    /// exact effect amount instead of a saturating kill.
    profiles: ?[]battle.Profile = null,
    view: battle.Content = undefined,

    pub fn open(raise: ?struct { id: []const u8, max_hp: u16 }) !Fixture {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/journey_battle.json", allocator, .limited(1024 * 1024));
        defer allocator.free(bytes);
        var result = Fixture{
            .content = try battle.load(allocator, bytes),
            .items = try field.items.load(allocator, field.items.json),
        };
        result.view = result.content.value;
        if (raise) |request| {
            const profiles = try allocator.dupe(battle.Profile, result.content.value.enemies);
            for (profiles) |*profile| if (std.mem.eql(u8, profile.id, request.id)) {
                profile.max_hp = request.max_hp;
            };
            result.profiles = profiles;
            result.view.enemies = profiles;
        }
        return result;
    }

    pub fn deinit(self: *Fixture) void {
        if (self.profiles) |profiles| allocator.free(profiles);
        self.items.deinit();
        self.content.deinit();
    }
};

pub const RoundMode = enum { ordinary, spell, rune, unite };

pub fn queueRound(state: *battle.State, mode: RoundMode) !void {
    const first = firstLiving(state.*, true) orelse return error.NoParty;
    state.enterRoundMenu();
    state.choose(first);
    // The non-ordinary modes exercise exactly one module-owned action; every
    // other member defends so the first enemy HP change is that action and not
    // an earlier ordinary strike.  The ordinary mode keeps the full round.
    var selected = false;
    var guard: usize = 0;
    while (state.phase == .command and guard < 12) : (guard += 1) {
        const actor = state.actor;
        if (!selected and mode == .spell and state.canCast(actor, 0)) {
            state.queue(.{ .spell = .{ .index = 0, .target = 0 } });
            selected = true;
            continue;
        }
        if (!selected and mode == .rune and state.canPhysicalRune(actor)) {
            state.queue(.{ .rune_attack = 0 });
            selected = true;
            continue;
        }
        if (!selected and mode == .unite and state.canUnite(actor)) {
            state.queue(.{ .unite = 0 });
            selected = true;
            continue;
        }
        if (mode == .ordinary and state.canAttackTarget(actor, 0)) {
            state.queue(.{ .attack = 0 });
        } else state.queue(.defend);
    }
    if (state.phase != .confirm_round) return error.RoundNotQueued;
}

pub fn tickToVictory(state: *battle.State, draws: *rules.Draws, limit: usize) !void {
    var ticks: usize = 0;
    while (state.phase != .victory and state.phase != .defeat and ticks < limit) : (ticks += 1) {
        try state.tickReplay(.{}, draws);
    }
    if (state.phase != .victory) return error.BattleNotWon;
}

pub fn stateBytes(state: battle.State) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, state, .{});
}

pub fn sourceRoundBoundary(combat: *battle.State, data: world_battle.Data) !void {
    combat.content.enemies = data.enemies;
    combat.content.encounters = data.encounters;
    combat.encounter = for (data.encounters, 0..) |encounter, i| {
        var archer = false;
        for (encounter.enemies) |id| for (data.enemies) |profile| {
            if (std.mem.eql(u8, id, profile.id) and profile.action_policy == .front_projectile) archer = true;
        };
        if (archer) break i;
    } else return error.MissingSourceRoundFixture;
    combat.startEncounter();
    combat.content.round_start = data.round_start;
    combat.phase = .resolving;
    combat.coordinator = .{ .stage = .round_ready, .current_actor = 0, .cached = .round_end, .completed = true };
    try std.testing.expect(combat.sourceRounds());
}

/// Source-exported journey changes over the shared spell fixture, without duplicating its cast programs.
pub fn journeyScenes(alloc: std.mem.Allocator, base: battle.spell_scene.Packet) !battle.spell_scene.Packet {
    const Patch = struct {
        schema: []const u8,
        entries: @TypeOf(base.entries),
        needle_burst: @TypeOf(base.needle_burst),
        enemy_magic_art: @TypeOf(base.enemy_magic_art),
        status_icons: @TypeOf(base.status_icons),
        unite_scenes: @TypeOf(base.unite_scenes),
        hurt_poses: @TypeOf(base.hurt_poses),
        unite_impacts: @TypeOf(base.unite_impacts),
        unite_reactions: @TypeOf(base.unite_reactions),
        physical_white_poses: @TypeOf(base.physical_white_poses),
    };
    const patch = try std.json.parseFromSliceLeaky(Patch, alloc, @embedFile("../fixtures/journey_unite_scenes_patch.json"), .{});
    var packet = base;
    inline for (@typeInfo(Patch).@"struct".field_names) |name| @field(packet, name) = @field(patch, name);
    try packet.validate(4096, 4096);
    return packet;
}

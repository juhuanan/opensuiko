//! Integrated host bindings for the shared combat owners.
//!
//! This module owns the shared battle-systems data: one instance parses the
//! reviewed spell rule catalogue, the Unite catalogue and the scripted outcome
//! asset for a session.  It deliberately imports no battle/session module, so
//! `battle.zig`, `world_battle.zig`, and the save owner can all consume it
//! without a cycle.
//!
//! The character id table is generated from the tracked character table; a
//! profile id is normalised (lower-case, alphanumeric only) before the lookup, so
//! `yam_koo` and `Yam Koo` agree.  A missing id is `null`, never a guess: the
//! callers refuse.

const std = @import("std");
const spells_mod = @import("spells/root.zig");
const techniques_mod = @import("techniques/root.zig");
const unite_mod = @import("unite/root.zig");
const outcomes_mod = @import("outcomes.zig");
const battle_assets = @import("battle_systems_data");
const outcomes_data = battle_assets.outcomes;

pub const data = struct {
    pub const character_ids = @import("character_ids.zig");
    pub const integration_json = battle_assets.integration.integration_json;
};
pub const character_ids = data.character_ids;

pub const rules = spells_mod.rules;
pub const plan = spells_mod.plan;
pub const bridge = spells_mod.bridge;
pub const Catalogue = unite_mod.Catalogue;
pub const OutcomeHost = outcomes_mod.Host;

pub const Host = struct {
    allocator: std.mem.Allocator,
    spell: std.json.Parsed(spells_mod.rules.Rules),
    unite: unite_mod.Catalogue,
    outcomes: outcomes_mod.Opened,

    pub fn init(allocator: std.mem.Allocator) !*Host {
        const self = try allocator.create(Host);
        errdefer allocator.destroy(self);
        self.allocator = allocator;
        self.spell = try spells_mod.rules.load(allocator, spells_mod.asset.json);
        errdefer self.spell.deinit();
        self.unite = try unite_mod.load(allocator);
        errdefer self.unite.deinit(allocator);
        self.outcomes = try outcomes_mod.open(allocator, outcomes_data.json);
        return self;
    }

    pub fn deinit(self: *Host) void {
        self.outcomes.deinit();
        self.unite.deinit(self.allocator);
        self.spell.deinit();
        self.allocator.destroy(self);
    }

    pub fn spellRules(self: *const Host) *const spells_mod.rules.Rules {
        return &self.spell.value;
    }

    pub fn uniteCatalogue(self: *const Host) *const unite_mod.Catalogue {
        return &self.unite;
    }

    pub fn outcomeAsset(self: *const Host) *const outcomes_mod.Asset {
        return self.outcomes.asset();
    }

    /// Rule index for a shared spell entry, matched by its exported name.  The
    /// shared catalogue and the source descriptor list are not in the same
    /// order, so the name is the identity join; an unknown name is `null`.
    pub fn spellIndexForName(self: *const Host, name: []const u8) ?usize {
        for (self.spell.value.spells, 0..) |spell, index| {
            if (std.mem.eql(u8, spell.name, name)) return index;
        }
        return null;
    }

    /// Reference lookup for the unfiltered source catalogue (Fire first).
    /// Runtime lists can be compacted; use battle.State.runeByteFor there.
    pub fn runeByte(self: *const Host, catalogue_index: usize) ?u8 {
        _ = self;
        const index = std.math.cast(u8, catalogue_index) orelse return null;
        return techniques_mod.physical.runeByteFromCatalogue(index);
    }

    pub fn characterId(self: *const Host, name: []const u8) ?u8 {
        _ = self;
        var buffer: [64]u8 = undefined;
        if (name.len > buffer.len) return null;
        var length: usize = 0;
        for (name) |c| {
            if (c >= 'A' and c <= 'Z') {
                buffer[length] = c + 32;
            } else if ((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9')) {
                buffer[length] = c;
            } else continue;
            length += 1;
        }
        return character_ids.idOf(buffer[0..length]);
    }
};

/// Host commit protocol for one declared scripted battle.  The ownership token
/// is the stable per-battle identity; a restored snapshot is accepted only for
/// the same token, and a commit is accepted exactly once.
pub const ScriptedOutcome = struct {
    host: outcomes_mod.Host,
    battle: *const outcomes_mod.Battle,

    pub fn begin(asset: *const outcomes_mod.Asset, id: []const u8, token: u64) !ScriptedOutcome {
        const battle = outcomes_mod.battleById(asset, id) orelse return error.UnknownScriptedBattle;
        var result = ScriptedOutcome{ .host = .{}, .battle = battle };
        try result.host.begin(battle, token);
        return result;
    }

    pub fn resolve(self: *ScriptedOutcome, signal: outcomes_mod.Signal) !outcomes_mod.Consequence {
        return self.host.resolve(self.battle, signal);
    }

    pub fn commit(self: *ScriptedOutcome) !outcomes_mod.Receipt {
        return self.host.commit();
    }

    pub fn capture(self: *const ScriptedOutcome) outcomes_mod.Capture {
        return self.host.capture();
    }

    pub fn restore(self: *ScriptedOutcome, snapshot: outcomes_mod.Capture) !void {
        if (snapshot.battle_len == 0 or snapshot.battle_len > snapshot.battle.len) return error.InvalidSnapshot;
        if (!std.mem.eql(u8, snapshot.battle[0..snapshot.battle_len], self.battle.id)) return error.BattleMismatch;
        return self.host.restore(snapshot);
    }

    pub fn adopt(self: *ScriptedOutcome, snapshot: outcomes_mod.Capture, token: u64) !void {
        if (snapshot.token != token) return error.OwnershipMismatch;
        return self.restore(snapshot);
    }
};

/// Resume a captured scripted transition into a fresh idle host.
pub fn resumeScripted(asset: *const outcomes_mod.Asset, id: []const u8, snapshot: outcomes_mod.Capture) !ScriptedOutcome {
    const battle = outcomes_mod.battleById(asset, id) orelse return error.UnknownScriptedBattle;
    var result = ScriptedOutcome{ .host = .{}, .battle = battle };
    try result.restore(snapshot);
    return result;
}

/// Ordinary (non-scripted) battle-end classification.  This is the production
/// reward gate: rewards need both source result flags clear.
pub fn classify(signal: outcomes_mod.Signal) outcomes_mod.Consequence {
    return outcomes_mod.classify(signal);
}

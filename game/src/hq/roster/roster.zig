//! Canonical roster transitions for forced party, temporary leave and
//! return, followers, death/absence and small-party ownership.
//!
//! The member record is the existing `battle.OwnedMember`; the per-character
//! sidecar is the existing `party.CharacterExtra`; the six active slots, the
//! reserve list and the forced set are exactly `party.Snapshot`'s fields.  This
//! module adds only the source-qualified presence/loaded sidecar that the
//! canonical snapshot does not carry: whether one of the six source slots is
//! retained and whether a departure is temporary, a forced strip or permanent.
//!
//! Nothing here changes inventory, gear, experience, rune, stats or sidecar
//! bytes.  A leave/rejoin/KO/save transition copies the member and validates
//! the result; a failure leaves the caller's roster untouched.
const std = @import("std");
const battle = @import("battle");
const party = @import("party_session");
const source = @import("source.zig");

pub const max_members = party.max_owned;
pub const max_active = 6;
pub const max_loaded = 6;
pub const max_noncombatants = 32;
pub const max_commands = 64;
pub const save_schema = "suikoden-roster-state/1";
pub const max_save_bytes = 1024 * 1024;

pub const Presence = enum { active, reserve, temporary_absent, detached, unrecruited };
pub const LeaveKind = enum { temporary, detached, permanent };
pub const Departure = struct {
    kind: LeaveKind,
    return_order: u8,
    source: []const u8,
};
pub const MemberState = struct {
    presence: Presence = .reserve,
    loaded: bool = false,
    departure: ?Departure = null,
    /// HP held before a knockout.  Knockout writes HP0 to the canonical
    /// record; this sidecar value lets a revive restore the member without
    /// inventing or discarding HP, and it is persisted with the roster.
    revive_hp: ?u16 = null,
};
pub const NoncombatantState = struct {
    identity: u16,
    recruited: bool = false,
};
pub const Command = union(enum) {
    load_join: struct { id: []const u8, forced: bool = false, source_text: []const u8 },
    rejoin: struct { id: []const u8, forced: bool = false, source_text: []const u8 },
    leave: struct { id: []const u8, kind: LeaveKind, source_text: []const u8 },
    leave_one: struct { id: []const u8, source_text: []const u8 },
    leave_all_nonhero: struct { source_text: []const u8 },
    select: [max_active]?[]const u8,
    scene_order: [max_active]?[]const u8,
    followers: [max_active]?[]const u8,
    recruit: struct { identity: u16, recruited: bool, source_text: []const u8 },
    knockout: struct { id: []const u8, source_text: []const u8 },
    revive: struct { id: []const u8, source_text: []const u8 },
};
pub const Journal = struct {
    baseline_revision: u64,
    receipt: u64,
    commands: [max_commands]?Command = @splat(null),
};

pub const Roster = struct {
    snapshot: party.Snapshot,
    states: [max_members]MemberState = @splat(.{}),
    noncombatants: [max_noncombatants]?NoncombatantState = @splat(null),
    source_digest: [32]u8,
    revision: u64 = 0,
    last_receipt: ?u64 = null,

    /// Bind a canonical snapshot to the source packet.  Members are classified
    /// from the snapshot's own active/eligible fields; no member is invented.
    pub fn init(packet: source.Packet, snapshot: party.Snapshot, noncombatants: []const NoncombatantState) !Roster {
        try packet.validate();
        var result = Roster{
            .snapshot = snapshot,
            .source_digest = source.digest(packet),
            .revision = snapshot.baseline_revision,
        };
        for (snapshot.members, 0..) |maybe, i| if (maybe) |member| {
            const active = contains(snapshot.active, member.member.id);
            const eligible = snapshot.eligible[i];
            result.states[i] = .{
                .presence = if (active) .active else if (eligible) .reserve else .unrecruited,
                .loaded = active,
            };
        };
        for (noncombatants, 0..) |entry, i| {
            if (i >= result.noncombatants.len) return error.TooManyNoncombatants;
            if (packet.noncombatant(entry.identity) == null) return error.Noncombatant;
            for (result.noncombatants[0..i]) |prior| if (prior) |other| {
                if (other.identity == entry.identity) return error.DuplicateNoncombatant;
            };
            result.noncombatants[i] = entry;
        }
        try result.validate(packet);
        return result;
    }

    pub fn toSnapshot(self: Roster) party.Snapshot {
        return self.snapshot;
    }

    pub fn memberIndex(self: *const Roster, id: []const u8) ?usize {
        for (self.snapshot.members, 0..) |maybe, i| if (maybe) |member| {
            if (std.mem.eql(u8, member.member.id, id)) return i;
        };
        return null;
    }
    pub fn activeIndex(self: *const Roster, id: []const u8) ?usize {
        for (self.snapshot.active, 0..) |maybe, i| if (maybe) |value| {
            if (std.mem.eql(u8, value, id)) return i;
        };
        return null;
    }
    pub fn stateOf(self: *const Roster, id: []const u8) ?MemberState {
        const index = self.memberIndex(id) orelse return null;
        return self.states[index];
    }
    pub fn activeCount(self: *const Roster) usize {
        return listCount(self.snapshot.active);
    }
    pub fn loadedCount(self: *const Roster) usize {
        var count: usize = 0;
        for (self.states) |state| if (state.loaded) {
            count += 1;
        };
        return count;
    }
    pub fn isForced(self: *const Roster, id: []const u8) bool {
        return contains(self.snapshot.forced, id);
    }
    pub fn isActive(self: *const Roster, id: []const u8) bool {
        return contains(self.snapshot.active, id);
    }
    pub fn noncombatantState(self: *const Roster, identity: u16) ?NoncombatantState {
        for (self.noncombatants) |maybe| if (maybe) |entry| {
            if (entry.identity == identity) return entry;
        };
        return null;
    }

    pub fn validate(self: *Roster, packet: source.Packet) !void {
        if (self.snapshot.schema != party.version) return error.InvalidRosterSchema;
        if (self.snapshot.entry_id.len == 0 or self.snapshot.content_id.len == 0 or self.snapshot.receipt.len == 0) return error.InvalidRosterEntry;
        try self.snapshot.storage.validate();
        if (!std.mem.eql(u8, &self.source_digest, &source.digest(packet))) return error.PacketDigestMismatch;
        if (self.revision != self.snapshot.baseline_revision) return error.InvalidRevision;
        var ended = false;
        var member_count: usize = 0;
        for (self.snapshot.members, 0..) |maybe, i| {
            if (maybe) |member| {
                if (ended) return error.InvalidRoster;
                const profile = packet.profile(member.member.id) orelse return error.UnknownMember;
                if (!std.mem.eql(u8, profile.name, member.member.name)) return error.InvalidRoster;
                const extra = self.snapshot.extras[i] orelse return error.MissingCharacterExtra;
                if (!std.mem.eql(u8, extra.member_id, member.member.id)) return error.InvalidCharacterExtra;
                member_count += 1;
                const active = contains(self.snapshot.active, member.member.id);
                const state = self.states[i];
                if (state.presence == .active and !active) return error.InvalidPresence;
                if (state.presence != .active and active) return error.InvalidPresence;
                switch (state.presence) {
                    .active => {
                        if (!state.loaded or state.departure != null or !self.snapshot.eligible[i]) return error.InvalidPresence;
                    },
                    .reserve => {
                        if (state.loaded or state.departure != null or !self.snapshot.eligible[i]) return error.InvalidPresence;
                    },
                    .temporary_absent => {
                        if (!state.loaded or !self.snapshot.eligible[i]) return error.InvalidPresence;
                        const departure = state.departure orelse return error.InvalidPresence;
                        if (departure.kind != .temporary) return error.InvalidPresence;
                    },
                    .detached => {
                        if (state.loaded or !self.snapshot.eligible[i]) return error.InvalidPresence;
                        const departure = state.departure orelse return error.InvalidPresence;
                        if (departure.kind != .detached) return error.InvalidPresence;
                    },
                    .unrecruited => {
                        if (state.loaded or self.snapshot.eligible[i]) return error.InvalidPresence;
                        if (state.departure) |departure| if (departure.kind != .permanent) return error.InvalidPresence;
                    },
                }
                if (state.departure) |departure| {
                    if (departure.return_order >= max_active or departure.source.len == 0) return error.InvalidPresence;
                }
                if (state.revive_hp) |hp| {
                    if (member.member.status != .unconscious or member.member.hp != 0 or hp == 0 or hp > member.member.max_hp) return error.InvalidPresence;
                }
            } else {
                ended = true;
                if (self.snapshot.extras[i] != null) return error.InvalidCharacterExtra;
                if (self.states[i].presence != .reserve or self.states[i].loaded or self.states[i].departure != null) return error.InvalidPresence;
            }
        }
        if (member_count == 0) return error.EmptyRoster;
        const active_count = try validateList(self.snapshot.active);
        if (active_count < packet.rules.active_min or active_count > packet.rules.active_max) return error.InvalidParty;
        const loaded_count = self.loadedCount();
        if (loaded_count > packet.rules.loaded_max or loaded_count < active_count) return error.InvalidLoadedSlots;
        for (self.snapshot.active) |maybe| if (maybe) |id| {
            const index = self.memberIndex(id) orelse return error.UnknownMember;
            if (self.states[index].presence != .active or !self.states[index].loaded) return error.InvalidPresence;
            // Every active member needs a combat record.  Guests (Ted/Odessa)
            // have one but sit outside the 108 portrait identities.
            if (!packet.isCombat(id)) return error.UnknownMember;
            if (packet.identityOfCombat(id)) |identity| {
                if (packet.noncombatant(identity) != null) return error.Noncombatant;
            }
        };
        const forced_count = try validateList(self.snapshot.forced);
        if (forced_count > active_count) return error.InvalidForced;
        for (self.snapshot.forced) |maybe| if (maybe) |id| {
            if (!contains(self.snapshot.active, id)) return error.ForcedMemberMissing;
        };
        for (self.snapshot.forced, 0..) |maybe, i| if (maybe) |id| {
            for (self.snapshot.forced[0..i]) |prior| if (prior) |other| {
                if (std.mem.eql(u8, other, id)) return error.DuplicateForced;
            };
        };
        const follower_count = try validateList(self.snapshot.followers);
        if (follower_count > active_count) return error.InvalidFollowers;
        for (self.snapshot.followers) |maybe| if (maybe) |id| {
            if (!contains(self.snapshot.active, id) and !packet.isGuest(id)) return error.InvalidSceneMember;
        };
        const scene_count = try validateList(self.snapshot.scene_order);
        if (scene_count > active_count) return error.InvalidSceneOrder;
        for (self.snapshot.scene_order) |maybe| if (maybe) |id| {
            if (!contains(self.snapshot.active, id)) return error.InvalidSceneMember;
        };
        for (self.noncombatants, 0..) |maybe, i| {
            const entry = maybe orelse continue;
            const identity = packet.noncombatant(entry.identity) orelse return error.Noncombatant;
            _ = identity;
            for (self.noncombatants[0..i]) |prior| if (prior) |other| {
                if (other.identity == entry.identity) return error.DuplicateNoncombatant;
            };
        }
        // Noncombatants are a ledger; no member may be one.
        for (self.snapshot.members) |maybe| if (maybe) |member| {
            if (!packet.isCombat(member.member.id)) return error.UnknownMember;
            if (packet.identityOfCombat(member.member.id)) |identity| {
                if (packet.noncombatant(identity) != null) return error.Noncombatant;
            }
        };
    }

    pub fn apply(self: *Roster, packet: source.Packet, command: Command) !void {
        var next = self.*;
        try next.applyOne(packet, command);
        try next.validate(packet);
        self.* = next;
    }

    fn applyOne(self: *Roster, packet: source.Packet, command: Command) !void {
        switch (command) {
            .load_join => |value| try self.loadJoin(packet, value.id, value.forced, value.source_text),
            .rejoin => |value| try self.rejoin(packet, value.id, value.forced, value.source_text),
            .leave => |value| try self.leave(packet, value.id, value.kind, value.source_text),
            .leave_one => |value| try self.leave(packet, value.id, .detached, value.source_text),
            .leave_all_nonhero => |value| try self.leaveAllNonHero(packet, value.source_text),
            .select => |value| try self.select(packet, value),
            .scene_order => |value| try self.setSceneOrder(packet, value),
            .followers => |value| try self.setFollowers(packet, value),
            .recruit => |value| try self.setRecruit(packet, value.identity, value.recruited, value.source_text),
            .knockout => |value| try self.knockout(packet, value.id, value.source_text),
            .revive => |value| try self.revive(packet, value.id, value.source_text),
        }
    }

    pub fn loadJoin(self: *Roster, packet: source.Packet, id: []const u8, forced: bool, source_text: []const u8) !void {
        try requireSource(source_text);
        try packet.requires("opcode1f.load_slot");
        const index = self.memberIndex(id) orelse return error.UnknownMember;
        if (self.states[index].loaded or self.isActive(id)) return error.AlreadyLoaded;
        if (!self.snapshot.eligible[index]) return error.RecruitRequired;
        if (self.activeCount() >= max_active or self.loadedCount() >= max_loaded) return error.PartyFull;
        try appendActive(&self.snapshot.active, id);
        const revive_hp = self.states[index].revive_hp;
        self.states[index] = .{ .presence = .active, .loaded = true, .departure = null, .revive_hp = revive_hp };
        if (forced) try appendForced(&self.snapshot.forced, id);
    }

    pub fn rejoin(self: *Roster, packet: source.Packet, id: []const u8, forced: bool, source_text: []const u8) !void {
        try requireSource(source_text);
        try packet.requires("opcode3c.rejoin_order");
        const index = self.memberIndex(id) orelse return error.UnknownMember;
        const state = self.states[index];
        if (state.presence != .temporary_absent or !state.loaded) return error.NotTemporaryAbsence;
        if (self.activeCount() >= max_active) return error.PartyFull;
        try appendActive(&self.snapshot.active, id);
        self.states[index].presence = .active;
        self.states[index].departure = null;
        if (forced) try appendForced(&self.snapshot.forced, id);
    }

    pub fn leave(self: *Roster, packet: source.Packet, id: []const u8, kind: LeaveKind, source_text: []const u8) !void {
        try requireSource(source_text);
        const operation = switch (kind) {
            .temporary => "opcode20.leave_temporary",
            .detached => "opcode20.leave_one",
            .permanent => "opcode20.leave_permanent",
        };
        try packet.requires(operation);
        const index = self.memberIndex(id) orelse return error.UnknownMember;
        const position = self.activeIndex(id) orelse return error.MemberNotActive;
        if (self.activeCount() <= packet.rules.active_min) return error.LastActive;
        const revive_hp = self.states[index].revive_hp;
        self.removeForced(id);
        removeActive(&self.snapshot.active, id);
        self.removeFromScene(id);
        self.states[index] = .{
            .revive_hp = revive_hp,
            .presence = switch (kind) {
                .temporary => .temporary_absent,
                .detached => .detached,
                .permanent => .unrecruited,
            },
            .loaded = kind == .temporary,
            .departure = .{ .kind = kind, .return_order = @intCast(position), .source = source_text },
        };
        if (kind == .permanent) self.snapshot.eligible[index] = false else self.snapshot.eligible[index] = true;
    }

    pub fn leaveAllNonHero(self: *Roster, packet: source.Packet, source_text: []const u8) !void {
        try requireSource(source_text);
        try packet.requires("opcode20.leave_all_nonhero");
        var keep: usize = 0;
        var removed: usize = 0;
        for (self.snapshot.active) |maybe| if (maybe) |id| {
            const profile = packet.profile(id) orelse return error.UnknownMember;
            if (profile.source_character_id != 8) removed += 1 else keep += 1;
        };
        if (keep == 0 or self.activeCount() - removed < packet.rules.active_min) return error.LastActive;
        var position: u8 = 0;
        for (self.snapshot.active) |maybe| if (maybe) |id| {
            const profile = packet.profile(id) orelse return error.UnknownMember;
            if (profile.source_character_id != 8) {
                const index = self.memberIndex(id) orelse return error.UnknownMember;
                const revive_hp = self.states[index].revive_hp;
                self.states[index] = .{
                    .presence = .detached,
                    .loaded = false,
                    .departure = .{ .kind = .detached, .return_order = position, .source = source_text },
                    .revive_hp = revive_hp,
                };
                self.snapshot.eligible[index] = true;
            }
            position += 1;
        };
        var next: [max_active]?[]const u8 = @splat(null);
        var count: usize = 0;
        for (self.snapshot.active) |maybe| if (maybe) |id| {
            const profile = packet.profile(id) orelse return error.UnknownMember;
            if (profile.source_character_id == 8) {
                next[count] = id;
                count += 1;
            }
        };
        self.snapshot.active = next;
        // A source strip releases the removed members' host locks but must not
        // quietly drop the retained Hero's lock.
        var forced_next: [max_active]?[]const u8 = @splat(null);
        var forced_count: usize = 0;
        for (self.snapshot.forced) |maybe| if (maybe) |id| {
            if (contains(next, id)) {
                forced_next[forced_count] = id;
                forced_count += 1;
            }
        };
        self.snapshot.forced = forced_next;
        self.snapshot.scene_order = @splat(null);
        self.snapshot.followers = @splat(null);
        // Recompute the retained Hero's state because the loop above only touched removed entries.
        for (0..max_members) |i| {
            const member = self.snapshot.members[i] orelse continue;
            if (self.states[i].presence == .active and !contains(self.snapshot.active, member.member.id)) return error.InternalPresence;
        }
    }

    pub fn select(self: *Roster, packet: source.Packet, active: [max_active]?[]const u8) !void {
        const count = try validateList(active);
        if (count < packet.rules.active_min or count > packet.rules.active_max) return error.InvalidParty;
        for (active) |maybe| if (maybe) |id| {
            const index = self.memberIndex(id) orelse return error.UnknownMember;
            const state = self.states[index];
            if (!state.loaded or (state.presence != .active and state.presence != .temporary_absent)) return error.NotLoaded;
        };
        for (self.snapshot.forced) |maybe| if (maybe) |id| {
            if (!contains(active, id)) return error.ForcedMemberRemoval;
        };
        var next: [max_active]?[]const u8 = @splat(null);
        for (active, 0..) |maybe, i| next[i] = maybe;
        for (self.snapshot.active) |maybe| if (maybe) |id| {
            if (!contains(next, id) and !self.isForced(id)) {
                const index = self.memberIndex(id) orelse return error.UnknownMember;
                const revive_hp = self.states[index].revive_hp;
                self.states[index] = .{
                    .presence = .temporary_absent,
                    .loaded = true,
                    .departure = .{ .kind = .temporary, .return_order = @intCast(self.activeIndex(id) orelse 0), .source = "ordinary_select" },
                    .revive_hp = revive_hp,
                };
            }
        };
        for (next, 0..) |maybe, i| if (maybe) |id| {
            const index = self.memberIndex(id) orelse return error.UnknownMember;
            self.states[index].presence = .active;
            self.states[index].departure = null;
            _ = i;
        };
        self.snapshot.active = next;
        self.snapshot.scene_order = @splat(null);
        self.snapshot.followers = @splat(null);
    }

    pub fn setRecruit(self: *Roster, packet: source.Packet, identity: u16, recruited: bool, source_text: []const u8) !void {
        try requireSource(source_text);
        try packet.requires("opcode45.recruit_toggle");
        if (packet.noncombatant(identity) != null) {
            for (&self.noncombatants) |*maybe| if (maybe.*) |entry| {
                if (entry.identity == identity) {
                    maybe.* = .{ .identity = identity, .recruited = recruited };
                    return;
                }
            };
            for (&self.noncombatants) |*maybe| if (maybe.* == null) {
                maybe.* = .{ .identity = identity, .recruited = recruited };
                return;
            };
            return error.TooManyNoncombatants;
        }
        const profile = packet.identity(identity) orelse return error.UnknownIdentity;
        const combat_id = profile.combat_id orelse return error.Noncombatant;
        const index = self.memberIndex(combat_id) orelse return error.RecordUnavailable;
        if (recruited) {
            self.snapshot.eligible[index] = true;
            if (self.states[index].presence == .unrecruited) {
                const revive_hp = self.states[index].revive_hp;
                self.states[index] = .{ .presence = .reserve, .loaded = false, .departure = null, .revive_hp = revive_hp };
            }
        } else {
            if (self.isActive(combat_id) or self.states[index].loaded or self.isForced(combat_id)) return error.MemberInUse;
            self.snapshot.eligible[index] = false;
            const revive_hp = self.states[index].revive_hp;
            self.states[index] = .{
                .presence = .unrecruited,
                .loaded = false,
                .departure = .{ .kind = .permanent, .return_order = 0, .source = source_text },
                .revive_hp = revive_hp,
            };
        }
    }

    pub fn setSceneOrder(self: *Roster, packet: source.Packet, order: [max_active]?[]const u8) !void {
        try packet.requires("opcode3b.scene_order");
        const count = try validateList(order);
        if (count > self.activeCount()) return error.InvalidSceneOrder;
        for (order) |maybe| if (maybe) |id| {
            if (!self.isActive(id)) return error.InvalidSceneMember;
        };
        self.snapshot.scene_order = order;
    }

    pub fn setFollowers(self: *Roster, packet: source.Packet, followers: [max_active]?[]const u8) !void {
        try packet.requires("opcode36.follower_build");
        const count = try validateList(followers);
        if (count > self.activeCount()) return error.InvalidFollowers;
        for (followers) |maybe| if (maybe) |id| {
            if (!self.isActive(id) and !packet.isGuest(id)) return error.InvalidSceneMember;
        };
        self.snapshot.followers = followers;
    }

    pub fn knockout(self: *Roster, packet: source.Packet, id: []const u8, source_text: []const u8) !void {
        try requireSource(source_text);
        try packet.requires("battle.knockout");
        const index = self.memberIndex(id) orelse return error.UnknownMember;
        if (!self.isActive(id)) return error.MemberNotActive;
        var member = &self.snapshot.members[index].?;
        if (member.member.status == .unconscious) return;
        if (member.member.hp == 0) return error.MissingRecoveryHp;
        self.states[index].revive_hp = member.member.hp;
        member.member.hp = 0;
        member.member.status = .unconscious;
    }

    pub fn revive(self: *Roster, packet: source.Packet, id: []const u8, source_text: []const u8) !void {
        try requireSource(source_text);
        try packet.requires("battle.exit");
        const index = self.memberIndex(id) orelse return error.UnknownMember;
        if (!self.isActive(id)) return error.MemberNotActive;
        const member = &self.snapshot.members[index].?;
        if (member.member.status != .unconscious) return error.NotUnconscious;
        const hp = self.states[index].revive_hp orelse return error.MissingRecoveryHp;
        if (hp == 0 or hp > member.member.max_hp) return error.InvalidRecoveryHp;
        member.member.hp = hp;
        member.member.status = .healthy;
        self.states[index].revive_hp = null;
    }

    pub fn replay(packet: source.Packet, baseline: Roster, journal: Journal) !Roster {
        if (journal.baseline_revision != baseline.revision) return error.InvalidReceipt;
        if (journal.receipt != std.math.add(u64, baseline.revision, 1) catch return error.InvalidReceipt) return error.InvalidReceipt;
        if (baseline.last_receipt) |last| if (journal.receipt <= last) return error.InvalidReceipt;
        var result = baseline;
        var applied: usize = 0;
        var ended = false;
        for (journal.commands) |maybe| {
            if (maybe) |command| {
                if (ended) return error.InvalidJournal;
                try result.apply(packet, command);
                applied += 1;
            } else ended = true;
        }
        if (applied == 0) return error.EmptyJournal;
        result.revision = journal.receipt;
        result.snapshot.baseline_revision = journal.receipt;
        result.last_receipt = journal.receipt;
        try result.validate(packet);
        return result;
    }

    // ------------------------------------------------------------------
    // Bounded save/restore.  The canonical snapshot is carried verbatim; the
    // sidecar adds only the presence/loaded/departure ledger.
    // ------------------------------------------------------------------
    const PersistedDeparture = struct { kind: LeaveKind, return_order: u8, source: []const u8 };
    const PersistedState = struct { presence: Presence, loaded: bool, departure: ?PersistedDeparture = null, revive_hp: ?u16 = null };
    const Persisted = struct {
        schema: []const u8 = save_schema,
        source_digest: [64]u8,
        revision: u64,
        last_receipt: ?u64 = null,
        snapshot: party.Snapshot,
        states: [max_members]PersistedState,
        noncombatants: [max_noncombatants]?NoncombatantState,
    };

    pub fn save(self: *const Roster, allocator: std.mem.Allocator) ![]u8 {
        const hex = std.fmt.bytesToHex(self.source_digest, .lower);
        var persisted = Persisted{
            .source_digest = hex,
            .revision = self.revision,
            .last_receipt = self.last_receipt,
            .snapshot = self.snapshot,
            .states = undefined,
            .noncombatants = self.noncombatants,
        };
        for (self.states, 0..) |state, i| {
            persisted.states[i] = .{
                .presence = state.presence,
                .loaded = state.loaded,
                .departure = if (state.departure) |departure| .{
                    .kind = departure.kind,
                    .return_order = departure.return_order,
                    .source = departure.source,
                } else null,
                .revive_hp = state.revive_hp,
            };
        }
        return std.json.Stringify.valueAlloc(allocator, persisted, .{});
    }

    pub fn restore(allocator: std.mem.Allocator, packet: source.Packet, bytes: []const u8) !Roster {
        if (bytes.len > max_save_bytes) return error.SaveTooLarge;
        const parsed = try std.json.parseFromSliceLeaky(Persisted, allocator, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
        if (!std.mem.eql(u8, parsed.schema, save_schema)) return error.InvalidSave;
        const expected = std.fmt.bytesToHex(source.digest(packet), .lower);
        if (!std.mem.eql(u8, &parsed.source_digest, &expected)) return error.InvalidSave;
        var result = Roster{
            .snapshot = parsed.snapshot,
            .source_digest = source.digest(packet),
            .revision = parsed.revision,
            .last_receipt = parsed.last_receipt,
        };
        for (parsed.states, 0..) |state, i| {
            result.states[i] = .{
                .presence = state.presence,
                .loaded = state.loaded,
                .departure = if (state.departure) |departure| .{
                    .kind = departure.kind,
                    .return_order = departure.return_order,
                    .source = departure.source,
                } else null,
                .revive_hp = state.revive_hp,
            };
        }
        result.noncombatants = parsed.noncombatants;
        try result.validate(packet);
        return result;
    }

    fn removeFromScene(self: *Roster, id: []const u8) void {
        removeFromList(&self.snapshot.scene_order, id);
        removeFromList(&self.snapshot.followers, id);
    }
    fn removeForced(self: *Roster, id: []const u8) void {
        removeFromList(&self.snapshot.forced, id);
    }
};

pub fn replay(packet: source.Packet, baseline: Roster, journal: Journal) !Roster {
    return Roster.replay(packet, baseline, journal);
}

fn requireSource(text: []const u8) !void {
    if (text.len == 0) return error.InvalidSource;
}
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn contains(list: [max_active]?[]const u8, id: []const u8) bool {
    for (list) |maybe| if (maybe) |value| {
        if (eq(value, id)) return true;
    };
    return false;
}
fn listCount(list: [max_active]?[]const u8) usize {
    var count: usize = 0;
    for (list) |maybe| if (maybe != null) {
        count += 1;
    };
    return count;
}
fn validateList(list: [max_active]?[]const u8) !usize {
    var count: usize = 0;
    var ended = false;
    for (list, 0..) |maybe, i| {
        if (maybe) |id| {
            if (ended or id.len == 0) return error.InvalidIdentityList;
            for (list[0..i]) |prior| if (prior) |other| {
                if (eq(other, id)) return error.DuplicateMember;
            };
            count += 1;
        } else ended = true;
    }
    return count;
}
fn appendActive(list: *[max_active]?[]const u8, id: []const u8) !void {
    for (list, 0..) |maybe, i| if (maybe == null) {
        if (i > 0 and list[i - 1] == null) return error.InvalidIdentityList;
        list[i] = id;
        return;
    };
    return error.PartyFull;
}
fn appendForced(list: *[max_active]?[]const u8, id: []const u8) !void {
    for (list, 0..) |maybe, i| if (maybe == null) {
        if (i > 0 and list[i - 1] == null) return error.InvalidForced;
        list[i] = id;
        return;
    };
    return error.ForcedFull;
}
fn removeActive(list: *[max_active]?[]const u8, id: []const u8) void {
    removeFromList(list, id);
}
fn removeFromList(list: *[max_active]?[]const u8, id: []const u8) void {
    var found: ?usize = null;
    for (list, 0..) |maybe, i| if (maybe) |value| {
        if (eq(value, id)) {
            found = i;
            break;
        }
    };
    const start = found orelse return;
    var i = start;
    while (i + 1 < list.len) : (i += 1) list[i] = list[i + 1];
    list[list.len - 1] = null;
}

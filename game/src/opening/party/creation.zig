//! Source-qualified NewGame templates and existing-record 0x3C party additions.
const std = @import("std");
const battle = @import("battle");
const party = @import("party_session");

const entry = @import("opening_records").entry;
const facts = entry;
pub const Source = facts.Source;
pub const sources = facts.sources;
pub const sourceFor = facts.sourceFor;
pub const same = facts.same;

pub const EventResult = struct {
    source: Source,
    before: party.Snapshot,
    after: party.Snapshot,
};
pub const InitialTemplate = struct {
    source: Source,
    materialized: party.catalogue.Materialized,
};
pub const LoadedBinding = struct {
    source_character_id: u32,
    member_id: []const u8,
};

/// Materialize the source's persistent NewGame template. This creates no roster,
/// eligibility, formation, or recruitment mutation.
pub fn initialTemplate(
    combat: battle.State,
    catalogue: party.catalogue.Catalogue,
    source_character_id: u8,
) !InitialTemplate {
    const source = try sourceFor(source_character_id);
    const character = for (catalogue.characters) |candidate| {
        if (candidate.source_character_id == source.source_character_id and
            std.mem.eql(u8, candidate.id, source.character_id) and
            std.mem.eql(u8, candidate.name, source.name) and
            std.mem.eql(u8, candidate.resource, source.resource) and
            std.mem.eql(u8, candidate.resource_sha256, source.resource_sha256)) break candidate;
    } else return error.PersistentRecordMismatch;
    return .{ .source = source, .materialized = try party.catalogue.materialize(combat, catalogue, character.id) };
}

pub const InitialParty = struct {
    roster: party.Snapshot,
    members: [4][]const u8,
};

/// Production initial-party caller: materialize the source NewGame records for
/// Hero, Pahn, Cleo and Gremio and install them as the four active members.
/// This is the template caller; it does not claim the 0x3C event join, which
/// needs its own source-qualified event contract.
pub fn beginInitialParty(
    combat: battle.State,
    catalogue: party.catalogue.Catalogue,
    sources_for_session: party.Sources,
) !InitialParty {
    const ids = [_][]const u8{ "hero", "pahn", "cleo", "gremio" };
    const operands = [_]u8{ 0, 6, 1, 2 };
    var roster: party.Snapshot = .{
        .entry_id = "opening_initial_party",
        .content_id = combat.content.schema,
        .receipt = "initial",
        .baseline_revision = 0,
    };
    for (ids, operands, 0..) |id, operand, index| {
        const materialized = if (index == 0)
            try party.catalogue.materialize(combat, catalogue, id)
        else
            (try initialTemplate(combat, catalogue, operand)).materialized;
        roster.members[index] = materialized.owned;
        roster.extras[index] = materialized.extra;
        roster.eligible[index] = true;
        roster.active[index] = materialized.owned.id;
    }
    _ = try party.Session.init(combat, roster, sources_for_session);
    return .{ .roster = roster, .members = ids };
}

/// Prepare the active-roster part of 0x3C only when the loader proves that the
/// operand resolved to an existing persistent member. No member record is created.
pub fn addLoaded(
    combat: battle.State,
    expected_before: party.Snapshot,
    current: party.Snapshot,
    operand: u8,
    binding: ?LoadedBinding,
    sources_for_session: party.Sources,
) !EventResult {
    if (!std.meta.eql(expected_before, current)) return error.StaleBeforeState;
    const source = try sourceFor(operand);
    const loaded = binding orelse return error.LoadedPartyBindingUnavailable;
    if (loaded.source_character_id != source.source_character_id or
        !std.mem.eql(u8, loaded.member_id, source.character_id)) return error.LoadedPartyBindingMismatch;
    if (current.active[0] == null) return error.InvalidParty;
    for (current.active) |member| if (member) |id| {
        if (std.mem.eql(u8, id, source.character_id)) return error.AlreadyActive;
    };

    var next = current;
    const member_index = for (next.members, 0..) |member, i| {
        if (member) |owned| if (std.mem.eql(u8, owned.id, source.character_id)) break i;
    } else return error.PersistentRecordUnavailable;
    var active_slot: ?usize = null;
    for (next.active, 0..) |member, i| if (member == null) {
        active_slot = i;
        break;
    };
    const active_index = active_slot orelse return error.PartyFull;

    next.eligible[member_index] = true;
    next.active[active_index] = current.members[member_index].?.id;
    _ = try party.Session.init(combat, next, sources_for_session);
    return .{ .source = source, .before = current, .after = next };
}

pub const local = @import("local_template.zig");

/// Canonical source state. IDs index the source character space; no raw loaded-bit
/// layout has been established.
pub const OwnerState = struct {
    roster: party.Snapshot,
    slots: [6]u8 = .{ 8, 0xff, 0xff, 0xff, 0xff, 0xff },
    order: [6]u8 = .{ 0, 0xfe, 0xfe, 0xfe, 0xfe, 0xfe },
    count: u8 = 1,
    // Unknown until the source formation sync has run. IDs are in slot order.
    area_party: ?[6]u8 = null,
    initialized: [110]bool = @splat(false),
    loaded: [110]bool = @splat(false),
    recruit_flags: [108]u8 = @splat(0),
    revision: u64 = 0,
    checkpoint: u64 = 0,
    receipt: u64 = 0,
};
pub const Operation = union(enum) {
    initialize_template: u8,
    event_add: u8,
    local_template: struct { room: u8, entity: u8, offset: u32, selector: u8 },
};
pub const Proposal = struct { operation: Operation, before: OwnerState, after: OwnerState };
pub const Context = struct {
    combat: battle.State,
    catalogue: party.catalogue.Catalogue,
    sources: party.Sources,
    template: local.Asset,
    ownership_bindings: ?party.catalogue.OwnershipBindings = null,
};
pub const EntryPending = entry.EntryPending;
pub const EntryAck = entry.EntryAck;
pub const EntryState = entry.EntryState;
pub const EntryResource = entry.EntryResource;
pub const EntryResources = entry.EntryResources;
pub const OpenedEntryResources = entry.OpenedEntryResources;
pub const StandaloneEntryRequest = entry.StandaloneEntryRequest;
pub const Entry = entry.Entry;
pub const openEntryResources = entry.openEntryResources;
pub const entry_resource_json = entry.entry_resource_json;

fn sourceCharacter(catalogue: party.catalogue.Catalogue, id: []const u8) !party.catalogue.Character {
    const character = for (catalogue.characters) |candidate| {
        if (std.mem.eql(u8, candidate.id, id)) break candidate;
    } else return error.InvalidOwnerState;
    const expected: Source = if (std.mem.eql(u8, id, "hero"))
        .{ .operand = 8, .character_id = "hero", .name = "Hero", .source_character_id = 8, .resource = "SHU.BIN", .resource_sha256 = "e9fdbee8391cc74349a091428767e208a4255960eeb4a118952cb612088b2428" }
    else if (std.mem.eql(u8, id, "viktor"))
        .{ .operand = 35, .character_id = "viktor", .name = "Viktor", .source_character_id = 35, .resource = "VIC.BIN", .resource_sha256 = "f68a6fccbc03b1a16a09b0d14c1b4838b6cc4206f0bd84c5b496c9d97b7fae20" }
    else blk: {
        for (sources) |source| if (std.mem.eql(u8, id, source.character_id)) break :blk source;
        return error.InvalidOwnerState;
    };
    if (character.source_character_id != expected.source_character_id or
        !std.mem.eql(u8, character.name, expected.name) or !std.mem.eql(u8, character.resource, expected.resource) or
        !std.mem.eql(u8, character.resource_sha256, expected.resource_sha256)) return error.InvalidOwnerState;
    return character;
}

/// VA1's resource entry state is independent of combat and roster presentation.
pub const Owner = struct {
    state: OwnerState,

    pub fn init(combat: battle.State, roster: party.Snapshot, sources_for_session: party.Sources) !Owner {
        _ = try party.Session.init(combat, roster, sources_for_session);
        if (roster.active[0] == null or !std.mem.eql(u8, roster.active[0].?, "hero")) return error.InvalidBootParty;
        for (roster.active[1..]) |id| if (id != null) return error.InvalidBootParty;
        for (roster.members[1..]) |member| if (member != null) return error.InvalidBootParty;
        var state: OwnerState = .{ .roster = roster };
        state.initialized[8] = true;
        state.loaded[8] = true;
        return .{ .state = state };
    }

    /// Build the canonical owner view from a shared party snapshot. Slots are
    /// source character ids in active order; inactive slots stay 0xff.
    pub fn fromSnapshot(context: Context, snapshot: party.Snapshot) !Owner {
        var state: OwnerState = .{ .roster = snapshot };
        state.slots = .{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
        state.order = .{ 0xfe, 0xfe, 0xfe, 0xfe, 0xfe, 0xfe };
        state.count = 0;
        for (snapshot.active, 0..) |maybe_id, i| {
            const id = maybe_id orelse break;
            const character = try sourceCharacter(context.catalogue, id);
            const source_id: u8 = @intCast(character.source_character_id);
            if (source_id >= 110 or state.loaded[source_id]) return error.InvalidOwnerState;
            state.slots[i] = source_id;
            state.order[i] = @intCast(i);
            state.initialized[source_id] = true;
            state.loaded[source_id] = true;
            state.count += 1;
        }
        return restore(context, state);
    }

    /// Identity slices are rebound to the catalogue. The caller retains the
    /// decoded snapshot's entry/content/receipt strings for this owner's lifetime.
    pub fn restore(context: Context, saved: OwnerState) !Owner {
        if (saved.count == 0 or saved.count > 6 or saved.receipt != saved.revision or
            (saved.revision == 0) != (saved.checkpoint == 0) or saved.checkpoint < saved.revision)
            return error.InvalidOwnerState;
        for (saved.recruit_flags) |flag| if (flag != 0) return error.InvalidOwnerState;
        if (saved.area_party) |area| {
            var ended = false;
            for (area, 0..) |id, i| {
                if (id == 0xff) {
                    ended = true;
                    continue;
                }
                if (ended or (id != 8 and id != 35 and id != 6 and id != 1 and id != 2 and id != 108)) return error.InvalidOwnerState;
                for (area[0..i]) |earlier| if (earlier == id) return error.InvalidOwnerState;
            }
        }
        var state = saved;
        var present: [110]bool = @splat(false);
        for (&state.roster.members, 0..) |*maybe_member, index| if (maybe_member.*) |*member| {
            const character = try sourceCharacter(context.catalogue, member.id);
            const id: usize = @intCast(character.source_character_id);
            if (present[id] or !state.initialized[id] or !std.mem.eql(u8, member.name, character.name)) return error.InvalidOwnerState;
            present[id] = true;
            member.id = character.id;
            member.name = character.name;
            const extra = state.roster.extras[index] orelse return error.InvalidOwnerState;
            if (!std.mem.eql(u8, extra.member_id, character.id)) return error.InvalidOwnerState;
            state.roster.extras[index].?.member_id = character.id;
        } else if (state.roster.eligible[index]) return error.InvalidOwnerState;
        for (0..110) |id| {
            if (state.initialized[id] != present[id]) return error.InvalidOwnerState;
            if (state.loaded[id] and id != 8 and id != 35) _ = try sourceFor(@intCast(id));
        }
        if (!state.loaded[8] or state.slots[0] != 8) return error.InvalidOwnerState;
        var used_slots: [6]bool = @splat(false);
        var slot_ids: [110]bool = @splat(false);
        for (state.slots) |id| {
            if (id == 0xff) continue;
            if (id >= 110 or !state.loaded[id] or slot_ids[id]) return error.InvalidOwnerState;
            slot_ids[id] = true;
        }
        if (state.area_party) |area| {
            if (area[0] != 8) return error.InvalidOwnerState;
            for (area) |id| {
                if (id == 0xff) break;
                if (!slot_ids[id] or !state.loaded[id]) return error.InvalidOwnerState;
            }
        }
        for (state.order, 0..) |slot, index| {
            if (index >= state.count) {
                if (slot != 0xfe or state.roster.active[index] != null) return error.InvalidOwnerState;
                continue;
            }
            if (slot >= 6 or used_slots[slot]) return error.InvalidOwnerState;
            used_slots[slot] = true;
            const id = state.slots[slot];
            if (id >= 110) return error.InvalidOwnerState;
            const active = state.roster.active[index] orelse return error.InvalidOwnerState;
            const character = try sourceCharacter(context.catalogue, active);
            if (character.source_character_id != id) return error.InvalidOwnerState;
            state.roster.active[index] = character.id;
        }
        for (0..110) |id| if (state.loaded[id] and !slot_ids[id]) {
            if (id != 35 or (state.count < 6 and std.mem.indexOfScalar(u8, &state.slots, 0xff) != null)) return error.InvalidOwnerState;
        };
        inline for (.{ "forced", "followers", "scene_order" }) |field_name| {
            for (&@field(state.roster, field_name)) |*maybe_id| if (maybe_id.*) |id| {
                maybe_id.* = (try sourceCharacter(context.catalogue, id)).id;
            };
        }
        _ = try party.Session.init(context.combat, state.roster, context.sources);
        return .{ .state = state };
    }

    fn replay(self: Owner, context: Context, operation: Operation, checkpoint: u64) !OwnerState {
        if (checkpoint <= self.state.checkpoint) return error.InvalidCheckpoint;
        var next = self.state;
        switch (operation) {
            .initialize_template => |operand| {
                const character = if (operand == 35) try sourceCharacter(context.catalogue, "viktor") else blk: {
                    const source = try sourceFor(operand);
                    break :blk try sourceCharacter(context.catalogue, source.character_id);
                };
                if (next.initialized[operand]) return error.AlreadyInitialized;
                const materialized = if (operand == 108)
                    try party.catalogue.materializeBound(context.combat, context.catalogue, character.id, context.ownership_bindings)
                else if (operand == 35)
                    try party.catalogue.materialize(context.combat, context.catalogue, character.id)
                else
                    (try initialTemplate(context.combat, context.catalogue, operand)).materialized;
                const index = for (next.roster.members, 0..) |member, i| {
                    if (member == null) break i;
                    if (std.mem.eql(u8, member.?.id, character.id)) return error.PersistentRecordMismatch;
                } else return error.RosterFull;
                next.roster.members[index] = materialized.owned;
                next.roster.extras[index] = materialized.extra;
                next.initialized[operand] = true;
            },
            .event_add => |operand| {
                const source = try sourceFor(operand);
                const slot = for (next.slots, 0..) |id, i| {
                    if (id == operand) break i;
                } else null;
                if (slot) |index| {
                    if (!next.initialized[operand]) return error.PersistentRecordUnavailable;
                    if (!next.loaded[operand]) return error.LoadedPartyBindingUnavailable;
                    // Native append is unchecked; these states are outside the bounded owner.
                    if (next.count >= 6) return error.UnmodeledNativePartyAppend;
                    for (next.order[0..next.count]) |active_slot| {
                        if (active_slot == index) return error.UnmodeledNativePartyAppend;
                    }
                    const result = try addLoaded(context.combat, next.roster, next.roster, operand, .{ .source_character_id = source.source_character_id, .member_id = source.character_id }, context.sources);
                    next.order[next.count] = @intCast(index);
                    next.count += 1;
                    next.roster = result.after;
                }
                var area: [6]u8 = @splat(0xff);
                var count: usize = 0;
                for (next.slots) |id| if (id != 0xff) {
                    area[count] = id;
                    count += 1;
                };
                next.area_party = area;
            },
            .local_template => |op| {
                const template = context.template;
                if (!std.mem.eql(u8, template.schema, "suikoden-opening-local-template/1") or !std.mem.eql(u8, template.source.file, "DATA/01_AREA.A/VA1.BIN") or !std.mem.eql(u8, template.source.sha256, "dcca6119f28f3863250f31be8cd164d4795eaa493aeec5b51ca0737690979fed") or template.area_header_offset != 23016 or template.table_index != 11 or template.table_offset != 283092 or template.template_offset != 369444 or template.template_copy_bytes != 20480 or !std.mem.eql(u8, template.resource.file, "DATA/04_PLAY/VIC.BIN")) return error.UntrustedLocalTemplate;
                const resolved = try local.resolve(template, op.room, op.entity, op.offset, op.selector, next.count, next.slots, next.revision, checkpoint);
                if (next.loaded[35]) return error.AlreadyLoaded;
                if (!next.initialized[35]) return error.PersistentRecordUnavailable;
                const character = try sourceCharacter(context.catalogue, "viktor");
                const index = for (next.roster.members, 0..) |member, i| {
                    if (member != null and std.mem.eql(u8, member.?.id, character.id)) break i;
                } else return error.PersistentRecordUnavailable;
                if (resolved.slot) |slot| {
                    next.roster.eligible[index] = true;
                    next.roster.active[next.count] = next.roster.members[index].?.id;
                    next.slots[slot] = 35;
                    next.order[next.count] = slot;
                    next.count += 1;
                }
                next.loaded[35] = true;
            },
        }
        _ = try party.Session.init(context.combat, next.roster, context.sources);
        next.revision = try std.math.add(u64, next.revision, 1);
        next.receipt = try std.math.add(u64, next.receipt, 1);
        next.checkpoint = checkpoint;
        return next;
    }

    /// Admit the completed resource owner without materializing battle records.
    pub fn adoptEntry(self: *Owner, entry_owner: Entry, checkpoint: u64) !void {
        if (checkpoint <= self.state.checkpoint) return error.InvalidCheckpoint;
        const validated = try Entry.restore(entry_owner.state);
        if (validated.state.pending != null or (try validated.propose(try std.math.add(u64, validated.state.checkpoint, 1))) != null) return error.EntryLoadPending;
        if (!std.mem.eql(u8, &self.state.slots, &.{ 8, 0xff, 0xff, 0xff, 0xff, 0xff }) or self.state.count != 1) return error.InvalidBootParty;
        var next = self.state;
        next.slots = validated.state.slots;
        next.loaded = validated.state.loaded;
        next.revision = try std.math.add(u64, next.revision, 1);
        next.receipt = try std.math.add(u64, next.receipt, 1);
        next.checkpoint = checkpoint;
        self.state = next;
    }

    pub fn propose(self: Owner, context: Context, operation: Operation, checkpoint: u64) !Proposal {
        return .{ .operation = operation, .before = self.state, .after = try self.replay(context, operation, checkpoint) };
    }

    pub fn commit(self: *Owner, context: Context, proposal: Proposal) !void {
        if (!same(self.state, proposal.before)) return error.StaleBeforeState;
        const canonical = try self.replay(context, proposal.operation, proposal.after.checkpoint);
        if (!same(canonical, proposal.after)) return error.InvalidProposal;
        self.state = canonical;
    }
};

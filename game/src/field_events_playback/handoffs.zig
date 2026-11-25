const std = @import("std");
const field = @import("field");
const events = @import("../field_events.zig");
const runtime = @import("event_runtime");
const validate = @import("../field_events_validate.zig").validate;

const Session = events.Session;
const Binding = events.Binding;
const semanticEqual = events.semanticEqual;

pub fn pendingGameplayRequest(self: *const Session) ?events.GameplayRequest {
    const owner = if (self.instance) |*value| value else return null;
    const pending = if (owner.pending) |*value| value else return null;
    if (pending.batch.effect_count != 1) return null;
    const command = &pending.batch.effects[0];
    const receipt: events.Receipt = .{
        .content_sha256 = owner.content_sha256,
        .program = owner.program_id,
        .instance = self.serial,
        .batch = pending.batch.id,
    };
    return switch (command.kind) {
        .battle => .{ .battle = .{
            .id = command.battle orelse return null,
            .defeat_target = command.defeat_target,
            .defeat_ends_run = command.defeat_ends_run,
            .receipt = receipt,
        } },
        .fixed_dice => .{ .dice = receipt },
        .party_select => .{ .party_selection = receipt },
        .item_overload => .{ .item_overload = .{ .item_name = command.item_name.?, .receipt = receipt } },
        .field_music => .{ .field_music = command.music orelse return null },
        else => null,
    };
}

pub fn queuedGameplayRequest(self: *const Session) ?events.GameplayRequest {
    const request = pendingGameplayRequest(self) orelse return null;
    if (request == .battle and !std.mem.eql(u8, self.pending_battle orelse return null, request.battle.id)) return null;
    return request;
}

fn battleRequest(self: *const Session) ?events.BattleRequest {
    const request = pendingGameplayRequest(self) orelse return null;
    return if (request == .battle) request.battle else null;
}

pub fn queuedBattle(self: *const Session) ?events.BattleRequest {
    const request = queuedGameplayRequest(self) orelse return null;
    return if (request == .battle) request.battle else null;
}

pub fn takeBattle(self: *Session) ?events.BattleRequest {
    const request = queuedBattle(self) orelse return null;
    self.pending_battle = null;
    return request;
}

pub fn queuedFixedDice(self: *const Session) ?events.Receipt {
    const request = pendingGameplayRequest(self) orelse return null;
    return if (request == .dice) request.dice else null;
}

pub fn queuedItemOverload(self: *const Session) ?events.ItemOverloadRequest {
    const request = pendingGameplayRequest(self) orelse return null;
    return if (request == .item_overload) request.item_overload else null;
}

pub fn resumeItemOverload(self: *Session, binding: Binding, state: *field.State, completed: events.Receipt) !void {
    try validate(self, binding);
    const request = queuedItemOverload(self) orelse return error.MissingItemOverload;
    if (!semanticEqual(request.receipt, completed)) return error.InvalidItemOverloadReceipt;
    var story = state.progress.story.scenario orelse return error.MissingSourceStoryState;
    try self.validateStory(&story);
    var next = self.*;
    try runtime.acknowledge(binding.content, &next.instance.?, &story, completed.batch);
    next.receipt = completed;
    try validate(&next, binding);
    self.* = next;
    state.progress.story.scenario = story;
}

pub fn queuedPartySelect(self: *const Session) ?events.Receipt {
    const request = pendingGameplayRequest(self) orelse return null;
    return if (request == .party_selection) request.party_selection else null;
}

pub fn partySelectReservesSlot(self: *const Session) bool {
    const request = self.pendingPartySelectCommand() orelse return false;
    if (request.parameter != 5) return false;
    if (request.index) |member| return std.mem.indexOfScalar(u8, self.source_party[0..self.active_party_count], member) == null;
    return true;
}

pub fn resumePartySelect(self: *Session, binding: Binding, state: *field.State, completed: events.Receipt) !void {
    try validate(self, binding);
    const request = queuedPartySelect(self) orelse return error.InvalidFieldPartySelectReceipt;
    if (!semanticEqual(request, completed)) return error.InvalidFieldPartySelectReceipt;
    if (partySelectReservesSlot(self) and binding.party.len == 6) return error.FieldEventPartyMismatch;
    var story = state.progress.story.scenario orelse return error.MissingSourceStoryState;
    try self.validateStory(&story);
    var next = self.*;
    try runtime.acknowledge(binding.content, &next.instance.?, &story, request.batch);
    next.receipt = request;
    try validate(&next, binding);
    self.* = next;
    state.progress.story.scenario = story;
}

// A confirmed edit leaves the callback pending; only selector cleanup resumes it.
pub fn updateSelectorParty(self: *Session, binding: Binding, completed: events.Receipt, next_party: []const u8, auxiliary: [6]u8) !void {
    try validate(self, binding);
    const request = queuedPartySelect(self) orelse return error.InvalidFieldPartySelectReceipt;
    if (!semanticEqual(request, completed)) return error.InvalidFieldPartySelectReceipt;
    const previous = binding.party;
    if (next_party.len == previous.len + 1 and next_party.len <= 6 and !partySelectReservesSlot(self)) {
        if (!std.mem.eql(u8, previous, next_party[0..previous.len]) or next_party[previous.len] >= 108 or
            std.mem.indexOfScalar(u8, previous, next_party[previous.len]) != null) return error.FieldEventPartyMismatch;
    } else if (next_party.len + 1 == previous.len and next_party.len != 0) {
        const removed = for (previous, 0..) |id, i| {
            if (i >= next_party.len or id != next_party[i]) break i;
        } else return error.FieldEventPartyMismatch;
        const protected = self.pendingPartySelectCommand().?.required_party orelse &.{};
        if (previous[removed] == 8 or std.mem.indexOfScalar(u8, &auxiliary, previous[removed]) != null or
            std.mem.indexOfScalar(u8, protected, previous[removed]) != null or
            !std.mem.eql(u8, previous[removed + 1 ..], next_party[removed..])) return error.FieldEventPartyMismatch;
    } else return error.FieldEventPartyMismatch;
    var next = self.*;
    next.source_party = @splat(255);
    @memcpy(next.source_party[0..next_party.len], next_party);
    next.active_party_count = @intCast(next_party.len);
    var next_binding = binding;
    next_binding.party = next_party;
    try validate(&next, next_binding);
    self.* = next;
}

pub fn pendingFieldMusic(self: *const Session) ?runtime.FieldMusic {
    const request = pendingGameplayRequest(self) orelse return null;
    return if (request == .field_music) request.field_music else null;
}

pub fn resumeFieldMusic(self: *Session, binding: Binding, state: *field.State, requested: runtime.FieldMusic) !void {
    try validate(self, binding);
    if (pendingFieldMusic(self) != requested) return error.InvalidFieldMusicReceipt;
    var story = state.progress.story.scenario orelse return error.MissingSourceStoryState;
    try self.validateStory(&story);
    const batch = self.instance.?.pending.?.batch.id;
    try runtime.acknowledge(binding.content, &self.instance.?, &story, batch);
    self.receipt = .{ .content_sha256 = self.instance.?.content_sha256, .program = self.instance.?.program_id, .instance = self.serial, .batch = batch };
    state.progress.story.scenario = story;
    state.music = if (requested == .fade) .stop else requested;
}

pub fn resumeFixedDice(self: *Session, binding: Binding, state: *field.State, completed: events.Receipt) !void {
    try validate(self, binding);
    const request = queuedFixedDice(self) orelse return error.InvalidFieldDiceReceipt;
    if (!semanticEqual(request, completed)) return error.InvalidFieldDiceReceipt;
    var story = state.progress.story.scenario orelse return error.MissingSourceStoryState;
    try self.validateStory(&story);
    try runtime.acknowledge(binding.content, &self.instance.?, &story, request.batch);
    self.receipt = request;
    state.progress.story.scenario = story;
}

pub fn resumeBattleStory(self: *Session, binding: Binding, source_story: ?runtime.StoryState, completed: events.BattleRequest, outcome: events.BattleOutcome) !runtime.StoryState {
    try validate(self, binding);
    const request = battleRequest(self) orelse return error.InvalidFieldBattleReceipt;
    if (self.pending_battle != null or !semanticEqual(request, completed)) return error.InvalidFieldBattleReceipt;
    var story = source_story orelse return error.MissingSourceStoryState;
    try self.validateStory(&story);
    const continuation: ?u16 = switch (outcome) {
        .victory => null,
        .escape => self.instance.?.pending.?.batch.effects[0].escape_target,
        .defeat => request.defeat_target orelse return error.MissingFieldDefeatContinuation,
    };
    const battle_command = self.instance.?.pending.?.batch.effects[0].origin;
    var next = self.*;
    try runtime.acknowledge(binding.content, &next.instance.?, &story, request.receipt.batch);
    if (continuation) |target| {
        try next.instance.?.redirect(binding.content, battle_command, target);
        next.instance.?.execution.wait = null;
    }
    next.receipt = request.receipt;
    self.* = next;
    return story;
}

// The recipient must deduplicate the stable (scene, instance, batch, origin) key.
pub fn acknowledgeAudio(self: *Session, binding: Binding, batch: u64, origin: u16) !void {
    try validate(self, binding);
    const request = self.audio_request orelse return error.MissingFieldAudioRequest;
    if (request.batch != batch or request.origin != origin) return error.InvalidFieldAudioReceipt;
    self.audio_request = null;
}

const std = @import("std");
const field = @import("field");
const ordinary = @import("field_actors");
const population = @import("scene_population");
const room2_descriptor = @import("descriptor_release");
const events = @import("field_events.zig");
const runtime = @import("event_runtime");
const motion = @import("opening_audience");
const dispatch = @import("scene_dispatch");
const records = @import("opening_records");
const ted_party_add = records.ted_party_add;
const field_records = records.field_records;
const room2_movement = @import("movement_batch");
const room2_text_host = @import("room2_text").host;
const fade = @import("fade");
const CompletedEvent = events.CompletedEvent;
const SourceCueRequest = events.SourceCueRequest;
const RoomTransitionProposal = events.RoomTransitionProposal;
const TransitionCommit = events.TransitionCommit;
const retainedE27Program = events.retainedE27Program;
const semanticEqual = events.semanticEqual;
const Initialization = events.Initialization;
const Result = events.Result;
const graphicVariant = events.graphicVariant;
const validateConstructedGround = events.validateConstructedGround;
const pureInitializationProgram = events.pureInitializationProgram;
const pureInitializationPump = events.pureInitializationPump;
const Session = events.Session;
const Binding = events.Binding;
const Room2Descriptor = events.Room2Descriptor;
const validate = @import("field_events_validate.zig").validate;
const session_mod = @import("field_events_session.zig");
const finishInitialization = session_mod.finishInitialization;
const tick = session_mod.tick;

fn sourceRequest(self: *const Session, binding: Binding, kind: @FieldType(runtime.Command, "kind")) !runtime.Command {
    try validate(self, binding);
    const owner = self.instance orelse return error.MissingFieldEventTransition;
    const pending = owner.pending orelse return error.MissingFieldEventTransition;
    if (self.blocker == null or self.blocker.?.reason != .unimplemented_effect or pending.batch.effect_count != 1) return error.InvalidFieldEventReceipt;
    const effect = pending.batch.effects[0];
    const blocked_command = self.blocker.?.command orelse return error.InvalidFieldEventReceipt;
    if (effect.origin != blocked_command or effect.kind != kind) return error.InvalidFieldEventReceipt;
    const program = binding.content.program(owner.program_id) orelse return error.UnknownEventProgram;
    if (effect.origin >= program.commands.len) return error.InvalidFieldEventReceipt;
    var canonical = program.commands[effect.origin];
    canonical.origin = effect.origin;
    if (!semanticEqual(effect, canonical)) return error.InvalidFieldEventReceipt;
    return effect;
}

pub fn pendingPartyChange(self: *const Session, binding: Binding) !?runtime.Command {
    if (binding.room_package == null) return null;
    const owner = self.instance orelse return null;
    const pending = owner.pending orelse return null;
    if (pending.batch.effect_count != 1) return null;
    const kind = pending.batch.effects[0].kind;
    if (kind != .party_join and kind != .party_load and kind != .party_leave and kind != .party_dismiss) return null;
    return try sourceRequest(self, binding, kind);
}

pub noinline fn acknowledgePartyChange(self: *Session, binding: Binding, slot: usize, next_party: []const u8, story: *runtime.StoryState) !void {
    return acknowledgeChange(self, binding, slot, next_party, null, story);
}

pub fn acknowledgePartyLoad(self: *Session, binding: Binding, character: u8, next_party: []const u8, story: *runtime.StoryState) !void {
    return acknowledgeChange(self, binding, binding.party.len, next_party, character, story);
}

fn acknowledgeChange(self: *Session, binding: Binding, slot: usize, next_party: []const u8, loaded: ?u8, story: *runtime.StoryState) !void {
    const effect = (try pendingPartyChange(self, binding)) orelse return error.InvalidFieldEventReceipt;
    const previous = binding.party;
    if ((effect.kind == .party_load) != (loaded != null)) return error.InvalidFieldEventReceipt;
    if (loaded) |id| if (id >= 108) return error.InvalidFieldEventReceipt;
    const unchanged = if (loaded) |id| previous.len == 6 or std.mem.indexOfScalar(u8, previous, id) != null else false;
    if (effect.kind == .party_dismiss) {
        if (previous.len == 0) return error.FieldEventPartyMismatch;
        const keep = std.mem.indexOfScalar(u8, previous, 8) orelse previous.len - 1;
        if (slot != keep or next_party.len != 1 or next_party[0] != previous[keep]) return error.FieldEventPartyMismatch;
    } else if (unchanged) {
        if (!std.mem.eql(u8, previous, next_party)) return error.FieldEventPartyMismatch;
    } else if (effect.kind == .party_join or effect.kind == .party_load) {
        if (slot != previous.len or next_party.len != previous.len + 1 or next_party.len > self.source_party.len or
            !std.mem.eql(u8, next_party[0..slot], previous)) return error.FieldEventPartyMismatch;
        const id = next_party[slot];
        if ((loaded != null and id != loaded.?) or id == 255 or std.mem.indexOfScalar(u8, previous, id) != null) return error.FieldEventPartyMismatch;
    } else if (effect.value == 1 and slot == previous.len) {
        if (!std.mem.eql(u8, previous, next_party)) return error.FieldEventPartyMismatch;
    } else {
        if (slot >= previous.len or next_party.len == 0 or next_party.len + 1 != previous.len or
            !std.mem.eql(u8, next_party[0..slot], previous[0..slot]) or
            !std.mem.eql(u8, next_party[slot..], previous[slot + 1 ..])) return error.FieldEventPartyMismatch;
    }
    try self.validateStory(story);
    var staged = self.*;
    var next_story = story.*;
    if (loaded) |id| next_story.markCharacterLoaded(id);
    const batch = staged.instance.?.pending.?.batch.id;
    try runtime.acknowledge(binding.content, &staged.instance.?, &next_story, batch);
    staged.receipt = .{ .content_sha256 = binding.content.content_sha256, .program = staged.instance.?.program_id, .instance = staged.serial, .batch = batch };
    staged.blocker = null;
    staged.source_party = @splat(255);
    @memcpy(staged.source_party[0..next_party.len], next_party);
    // Legacy combined joins/removals also refresh the transient follower order.
    if (loaded == null) {
        staged.area_party = @splat(255);
        @memcpy(staged.area_party[0..next_party.len], next_party);
    }
    staged.active_party_count = @intCast(next_party.len);
    var next_binding = binding;
    next_binding.party = next_party;
    try validate(&staged, next_binding);
    self.* = staged;
    story.* = next_story;
}

pub fn pendingWheelSpin(self: *const Session, binding: Binding) !bool {
    if (binding.room_package == null or !binding.content.hasWheelMotion()) return false;
    const pending = (self.instance orelse return false).pending orelse return false;
    if (pending.batch.effect_count != 1 or pending.batch.effects[0].kind != .wheel_spin) return false;
    _ = try sourceRequest(self, binding, .wheel_spin);
    return true;
}

pub fn acknowledgeWheelSpin(self: *Session, binding: Binding, state: *field.State, roll: u15) !void {
    if (!try pendingWheelSpin(self, binding)) return error.InvalidFieldEventReceipt;
    var story = state.progress.story.scenario orelse return error.MissingSourceStoryState;
    try self.validateStory(&story);
    var wheel = state.wheel_state orelse field.wheel.Room{};
    try wheel.validate();
    if (wheel.clock.phase != null) return error.WheelStillActive;
    wheel.start(roll);
    var staged = self.*;
    const batch = staged.instance.?.pending.?.batch.id;
    try runtime.acknowledge(binding.content, &staged.instance.?, &story, batch);
    staged.receipt = .{ .content_sha256 = binding.content.content_sha256, .program = staged.instance.?.program_id, .instance = staged.serial, .batch = batch };
    staged.blocker = null;
    try validate(&staged, binding);
    self.* = staged;
    state.wheel_state = wheel;
    state.progress.story.scenario = story;
}

pub fn pendingPartyEdit(self: *const Session, binding: Binding) !?runtime.Command {
    if (binding.room_package == null) return null;
    const pending = (self.instance orelse return null).pending orelse return null;
    if (pending.batch.effect_count != 1) return null;
    const kind = pending.batch.effects[0].kind;
    if (kind != .rune_grant and kind != .inventory_edit and kind != .shared_inventory_edit and kind != .warehouse_deposit and kind != .advance_character and kind != .party_gain_experience and kind != .party_lose_experience) return null;
    return try sourceRequest(self, binding, kind);
}

pub noinline fn acknowledgePartyEdit(self: *Session, binding: Binding, applied: bool, story: *runtime.StoryState) !void {
    const effect = (try pendingPartyEdit(self, binding)) orelse return error.InvalidFieldEventReceipt;
    if (!applied and effect.inventory == null) return error.InvalidFieldEventReceipt;
    try self.validateStory(story);
    var staged = self.*;
    var next_story = story.*;
    const batch = staged.instance.?.pending.?.batch.id;
    try runtime.acknowledge(binding.content, &staged.instance.?, &next_story, batch);
    if (!applied) try staged.instance.?.redirect(binding.content, effect.origin, effect.inventory.?.failure_target);
    staged.receipt = .{ .content_sha256 = binding.content.content_sha256, .program = staged.instance.?.program_id, .instance = staged.serial, .batch = batch };
    staged.blocker = null;
    try validate(&staged, binding);
    self.* = staged;
    story.* = next_story;
}

/// Authenticate Ted's source 3C against the retained event and its pending effect.
pub fn sourceTedAddRequest(self: *const Session, binding: Binding) !?ted_party_add.Request {
    try validate(self, binding);
    if (self.blocker == null or self.blocker.?.reason != .unimplemented_effect) return null;
    const owner = self.instance orelse return null;
    const pending = owner.pending orelse return null;
    if (pending.batch.effect_count != 1 or pending.batch.effects[0].kind != .source_party_add) return null;
    const effect = try sourceRequest(self, binding, .source_party_add);
    if (!std.mem.eql(u8, binding.room, "va1_room_2") or !std.mem.eql(u8, owner.program_id, "va1_r02_e02_ordinary") or
        effect.source_offset != 0x3d1a6 or effect.code != 108) return error.InvalidFieldEventReceipt;
    return .{ .content_id = binding.content.id, .content_sha256 = binding.content.content_sha256, .program = owner.program_id, .instance = self.serial, .batch = pending.batch.id, .origin = effect.origin, .source_offset = 0x3d1a6, .source_character_id = 108 };
}

/// Commit VM and roster facts together; the caller stages and owns the party storage.
pub fn acknowledgeTedAdd(self: *Session, old_binding: Binding, new_binding: Binding, request: ted_party_add.Request, proposal: ted_party_add.Proposal, state: *field.State) !void {
    const expected = (try self.sourceTedAddRequest(old_binding)) orelse return error.InvalidFieldEventReceipt;
    if (!semanticEqual(expected, request) or !semanticEqual(request, proposal.request) or
        proposal.after.count == 0 or proposal.after.count > 6 or
        !std.mem.eql(u8, new_binding.party, proposal.active_ids[0..proposal.after.count]) or
        !semanticEqual(@as([]const field.game_state.Member, state.progress.party), proposal.after.active[0..proposal.after.count])) return error.InvalidFieldEventReceipt;
    var roster: field_records.Owner = .{ .state = proposal.before };
    try roster.validate();
    var prior_ids: [6]u8 = @splat(0xff);
    for (roster.state.order[0..roster.state.count], 0..) |slot, index| prior_ids[index] = roster.state.entry.slots[slot];
    if (!std.mem.eql(u8, old_binding.party, prior_ids[0..roster.state.count])) return error.InvalidFieldEventReceipt;
    try ted_party_add.commit(&roster, request, proposal);
    var staged = self.*;
    var next_state = state.*;
    var story = next_state.progress.story.scenario orelse return error.MissingSourceStoryState;
    try staged.validateStory(&story);
    var owner = staged.instance.?;
    try runtime.acknowledge(old_binding.content, &owner, &story, request.batch);
    staged.instance = owner;
    staged.receipt = .{ .content_sha256 = old_binding.content.content_sha256, .program = owner.program_id, .instance = staged.serial, .batch = request.batch };
    staged.blocker = null;
    staged.source_party = proposal.active_ids;
    staged.area_party = proposal.area_party;
    staged.active_party_count = proposal.after.count;
    next_state.progress.story.scenario = story;
    try next_state.progress.validate();
    try staged.validate(new_binding);
    self.* = staged;
    state.* = next_state;
}

/// Return a source-qualified cue request from the retained pending batch.
/// It carries no media or timing assumption and cannot be fabricated by a caller.
pub fn sourceCueRequest(self: *const Session, binding: Binding) !?SourceCueRequest {
    try validate(self, binding);
    if (self.blocker == null or self.blocker.?.reason != .unimplemented_effect) return null;
    const owner = self.instance orelse return null;
    const pending = owner.pending orelse return null;
    if (pending.batch.effect_count != 1 or pending.batch.effects[0].kind != .cue) return null;
    const effect = try sourceRequest(self, binding, .cue);
    return .{
        .content_id = binding.content.id,
        .content_sha256 = binding.content.content_sha256,
        .program = self.instance.?.program_id,
        .instance = self.serial,
        .batch = self.instance.?.pending.?.batch.id,
        .origin = effect.origin,
        .cue = effect.cue orelse return error.InvalidFieldEventReceipt,
    };
}

/// Acknowledge a cue only against the exact retained source command and publish
/// its PC, receipt, and story writes together. Audio playback is optional.
pub fn acknowledgeSourceCue(self: *Session, binding: Binding, request: SourceCueRequest, state: *field.State) !void {
    try validate(self, binding);
    const effect = try sourceRequest(self, binding, .cue);
    const owner = self.instance.?;
    if (!std.mem.eql(u8, request.content_id, binding.content.id) or
        !std.mem.eql(u8, request.content_sha256, binding.content.content_sha256) or
        !std.mem.eql(u8, request.program, owner.program_id) or request.instance != self.serial or
        request.batch != owner.pending.?.batch.id or request.origin != effect.origin or request.cue != effect.cue.?) return error.InvalidFieldEventReceipt;
    var staged = self.*;
    var next_state = state.*;
    var story = next_state.progress.story.scenario orelse return error.MissingSourceStoryState;
    try staged.validateStory(&story);
    var next_owner = owner;
    try runtime.acknowledge(binding.content, &next_owner, &story, request.batch);
    staged.instance = next_owner;
    staged.receipt = .{ .content_sha256 = binding.content.content_sha256, .program = next_owner.program_id, .instance = staged.serial, .batch = request.batch };
    staged.blocker = null;
    const program = binding.content.program(next_owner.program_id) orelse return error.UnknownEventProgram;
    if (program.entry == .initialization and next_owner.execution.pc + 1 == program.commands.len and
        program.commands.len >= 2 and program.commands[program.commands.len - 2].kind == .yield_tick and
        program.commands[program.commands.len - 1].kind == .end_stream)
    {
        try finishInitialization(&staged, binding, &story);
    }
    next_state.progress.story.scenario = story;
    try next_state.progress.validate();
    try staged.validate(binding);
    self.* = staged;
    state.* = next_state;
}

/// Propose a room transition from the current, retained VM batch. The caller
/// receives the source's destination and coordinates, not authority to choose them.
pub fn proposeRoomTransition(self: *const Session, binding: Binding) !?RoomTransitionProposal {
    try validate(self, binding);
    if (self.blocker == null or self.blocker.?.reason != .unimplemented_effect) return null;
    const owner = self.instance orelse return null;
    const pending = owner.pending orelse return null;
    if (pending.batch.effect_count != 1 or pending.batch.effects[0].kind != .room_transition) return null;
    const effect = try sourceRequest(self, binding, .room_transition);
    return .{
        .content_id = binding.content.id,
        .content_sha256 = binding.content.content_sha256,
        .program = owner.program_id,
        .instance = self.serial,
        .batch = owner.pending.?.batch.id,
        .origin = effect.origin,
        .destination = effect.destination orelse return error.InvalidFieldEventReceipt,
        .x = effect.x orelse return error.InvalidFieldEventReceipt,
        .y = effect.y orelse return error.InvalidFieldEventReceipt,
        .arrival_facing = if (effect.arrival_facing) |facing| events.fieldDirection(facing) else null,
    };
}

/// Atomically acknowledge the source route and enter the caller's already
/// validated destination binding through the same shared field-event host.
pub fn acknowledgeRoomTransition(
    self: *Session,
    binding: Binding,
    proposal: RoomTransitionProposal,
    destination: Binding,
    destination_room: field.Room,
    source_state: field.State,
) !TransitionCommit {
    try validate(self, binding);
    const effect = try sourceRequest(self, binding, .room_transition);
    const owner = self.instance.?;
    if (!std.mem.eql(u8, proposal.content_id, binding.content.id) or
        !std.mem.eql(u8, proposal.content_sha256, binding.content.content_sha256) or
        !std.mem.eql(u8, proposal.program, owner.program_id) or proposal.instance != self.serial or
        proposal.batch != owner.pending.?.batch.id or proposal.origin != effect.origin or
        !std.mem.eql(u8, proposal.destination, effect.destination.?) or proposal.x != effect.x.? or proposal.y != effect.y.? or
        proposal.arrival_facing != (if (effect.arrival_facing) |facing| events.fieldDirection(facing) else null)) return error.InvalidFieldEventReceipt;
    try destination.validateContext();
    if (!std.mem.eql(u8, destination.room, proposal.destination) or proposal.x < 0 or proposal.y < 0 or
        proposal.x >= destination_room.width or proposal.y >= destination_room.height or
        !destination_room.canStand(proposal.x, proposal.y)) return error.InvalidFieldEventTransition;
    try destination.validateRoom(destination_room, destination.party.len);
    const destination_ground = destination.ground orelse return error.UnsupportedFieldGroundConstruction;
    if (destination_ground.identity.len == 0 or destination_ground.ground_fn(
        destination_ground.context,
        "hero",
        .{ .x = proposal.x, .y = proposal.y, .speed = 2 },
    ) != true) return error.InvalidFieldEventTransition;
    var next_state = source_state;
    var story = next_state.progress.story.scenario orelse return error.MissingSourceStoryState;
    try self.validateStory(&story);
    var next_owner = owner;
    try runtime.acknowledge(binding.content, &next_owner, &story, proposal.batch);
    if (next_owner.execution.active or next_owner.pending != null) return error.InvalidFieldEventReceipt;
    next_state.progress.story.scenario = story;
    next_state.x = proposal.x;
    next_state.y = proposal.y;
    next_state.destination = .{ .x = proposal.x, .y = proposal.y };
    if (proposal.arrival_facing) |facing| next_state.facing = facing;
    next_state.walking = false;
    next_state.remaining = 0;
    try next_state.progress.validate();
    const serial = std.math.add(u64, self.serial, 1) catch return error.FieldEventSequenceOverflow;
    const next_session = try Session.enter(destination, next_state, serial);
    if (next_session.blocker != null) return error.UnsupportedFieldGroundConstruction;
    try next_session.validate(destination);
    var acknowledged = self.*;
    acknowledged.instance = next_owner;
    acknowledged.receipt = .{ .content_sha256 = binding.content.content_sha256, .program = next_owner.program_id, .instance = acknowledged.serial, .batch = proposal.batch };
    acknowledged.blocker = null;
    try acknowledged.validate(binding);
    self.* = acknowledged;
    return .{ .state = next_state, .event = next_session };
}

// The caller validates and stages the world handback before acknowledging this effect.
pub fn acknowledgeWorldExit(self: *Session, binding: Binding, story: *runtime.StoryState) !void {
    try validate(self, binding);
    const blocker = self.blocker orelse return error.MissingFieldEventTransition;
    if (blocker.entity != 1 or blocker.command != 1 or blocker.reason != .unimplemented_effect or !std.mem.eql(u8, binding.content.id, "vb6_room0_world_exit")) return error.InvalidFieldEventReceipt;
    var owner = self.instance orelse return error.InvalidFieldEventReceipt;
    const pending = owner.pending orelse return error.InvalidFieldEventReceipt;
    if (pending.batch.effect_count != 1 or pending.batch.effects[0].kind != .world_transition or pending.batch.effects[0].origin != 1 or pending.story_write_count != 0) return error.InvalidFieldEventReceipt;
    try runtime.acknowledge(binding.content, &owner, story, pending.batch.id);
    if (owner.execution.active or owner.pending != null) return error.InvalidFieldEventReceipt;
    self.instance = owner;
    self.receipt = .{ .content_sha256 = binding.content.content_sha256, .program = owner.program_id, .instance = self.serial, .batch = pending.batch.id };
    self.blocker = null;
}

// Stage the source E7 acknowledgement and both eligible initializers together.
pub fn reconstruct(self: *Session, binding: Binding, state: *field.State) !bool {
    try validate(self, binding);
    const blocker = self.blocker orelse return false;
    if (!std.mem.eql(u8, self.schema, "suikoden-field-event/17") or blocker.entity != 7 or blocker.command != 12) return false;
    const prior = self.completed_event orelse return error.InvalidFieldEventReceipt;
    const initial = self.initializations[0] orelse return error.InvalidFieldEventReceipt;
    var owner = self.instance orelse return error.InvalidFieldEventReceipt;
    const pending = owner.pending orelse return error.InvalidFieldEventReceipt;
    if (pending.batch.effect_count != 1 or pending.batch.effects[0].kind != .room_transition or pending.batch.effects[0].origin != 12 or pending.batch.effects[0].destination == null or !std.mem.eql(u8, pending.batch.effects[0].destination.?, binding.room) or pending.batch.effects[0].x != 216 or pending.batch.effects[0].y != 200 or pending.story_write_count != 0) return error.InvalidFieldEventReceipt;
    var next_state = state.*;
    var story = next_state.progress.story.scenario orelse return error.MissingSourceStoryState;
    try self.validateStory(&story);
    try runtime.acknowledge(binding.content, &owner, &story, pending.batch.id);
    if (owner.execution.active or owner.pending != null) return error.InvalidFieldEventReceipt;
    const finished: CompletedEvent = .{ .execution = owner.execution, .effect_sequence = owner.effect_sequence, .receipt = .{ .content_sha256 = binding.content.content_sha256, .program = owner.program_id, .instance = self.serial, .batch = pending.batch.id } };
    next_state.x = 216;
    next_state.y = 200;
    next_state.destination = .{ .x = 216, .y = 200 };
    next_state.walking = false;
    next_state.remaining = 0;
    next_state.progress.story.scenario = story;
    var next = try Session.enter(binding, next_state, std.math.add(u64, self.serial, 1) catch return error.FieldEventSequenceOverflow);
    if (next.blocker != null or next.instance == null) return false;
    _ = try next.tick(binding, &next_state, false);
    if (next.blocker != null or !next.initialization_done or next.instance != null or next.initialization_count != 2 or next.initializations[0].?.entity != 6 or next.initializations[1].?.entity != 8) return false;
    next.reconstruction = .{ .arrival = prior, .followon = finished, .arrival_initializer = initial };
    next.schema = "suikoden-field-event/18";
    next.blocker = .{ .entity = 7, .reason = .source_gate_unknown };
    try next.validate(binding);
    try next.validateStory(&next_state.progress.story.scenario.?);
    self.* = next;
    state.* = next_state;
    return true;
}

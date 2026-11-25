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
const validate_mod = @import("field_events_validate.zig");
const validate = validate_mod.validate;

pub fn beginInteraction(binding: Binding, state: field.State, serial: u64, entity: u8, construction: ?ordinary.State) !Session {
    try binding.validateContext();
    try population.validate(binding.population);
    const story = state.progress.story.scenario orelse return error.MissingSourceStoryState;
    if (entity >= binding.population.entities.len) return error.IneligibleFieldInteraction;
    const source_program = if (binding.population.entities[entity].event.program_id) |id| binding.content.program(id) else null;
    const inherited = source_program != null and (source_program.?.owner_actor != null or source_program.?.owner_actors != null);
    if (!inherited) switch (population.interactionEligibility(binding.population.entities[entity], .{ .story = &story, .active_party_count = @intCast(binding.party.len), .party = binding.party, .levels = binding.character_levels })) {
        .eligible => {},
        .ineligible => return error.IneligibleFieldInteraction,
        .unsupported => return error.UnsupportedPopulationPredicate,
    };
    var result: Session = undefined;
    try result.seed(binding, state, serial);
    if ((binding.ordinary != null) != (construction != null)) return error.MissingFieldActorConstruction;
    if (construction) |actors| {
        try actors.validate(binding.ordinary.?, binding.animations);
        var target = binding.population.entities[entity].record_role == .event or binding.room_actors.len != 0;
        if (binding.population.entities[entity].event.program_id) |id| if (binding.content.program(id)) |program| if ((program.owner_actor != null or program.owner_actors != null)) {
            target = false;
        };
        for (binding.ordinary.?.actors, 0..) |definition, index| if (binding.actorOwnsEntity(definition, entity)) {
            target = actors.slots[index].?.phase == .active;
        };
        if (!target) return error.IneligibleFieldInteraction;
    }
    result.ordinary_actors = construction;
    if (result.ordinary_actors) |*actors| actors.clearSceneActors(binding.ordinary.?);
    result.selected_program = true;
    result.initialization_done = true;
    result.next_initialization = @intCast(binding.population.entities.len);
    try selectInWorld(&result, binding, state, .interaction, entity, null);
    if (result.instance == null or result.blocker != null) return error.UnavailableFieldInteraction;
    return result;
}

/// Initialize a fresh session from a settled field position and existing actor construction.
pub noinline fn beginOrdinary(out: *Session, binding: Binding, state: field.State, serial: u64, construction: ?*const ordinary.State) !bool {
    return beginRoomEvent(out, binding, state, serial, construction, .ordinary, null);
}

pub noinline fn beginRoomEvent(out: *Session, binding: Binding, state: field.State, serial: u64, construction: ?*const ordinary.State, trigger: enum { ordinary, area_entry }, direction: ?field.Direction) !bool {
    if (trigger == .area_entry) {
        for (binding.population.entities) |entity| {
            if (entity.trigger == .area_entry and entity.event.status == .resolved) break;
        } else return false;
    }
    try binding.validateContext();
    try binding.content.validate();
    try population.validate(binding.population);
    if ((binding.ordinary != null) != (construction != null)) return error.MissingFieldActorConstruction;
    if (construction) |actors| try actors.validate(binding.ordinary.?, binding.animations);
    try out.seed(binding, state, serial);
    out.ordinary_actors = if (construction) |actors| actors.* else null;
    if (out.ordinary_actors) |*actors| actors.clearSceneActors(binding.ordinary.?);
    out.selected_program = true;
    out.initialization_done = true;
    out.next_initialization = @intCast(binding.population.entities.len);
    try selectInWorld(out, binding, state, if (trigger == .ordinary) .ordinary else .area_entry, null, direction);
    if (out.blocker != null) return error.UnavailableFieldEvent;
    try validate(out, binding);
    return out.instance != null;
}

/// Start the authored VAA room-1 entity-1 exit while retaining the existing
/// Live actor host. The campaign owner admits the source route; this bridge
/// verifies its state, program, and resolved population owner.
pub fn beginRoute(binding: Binding, state: field.State, serial: u64, program_id: []const u8) !Session {
    try binding.validateContext();
    if (binding.ordinary != null or !std.mem.eql(u8, binding.content.id, "vaa_room1_route_events") or
        binding.population.source.room != 1 or !std.mem.eql(u8, program_id, "vaa_r01_e01_exit")) return error.InvalidFieldRoute;
    const cell_x = std.math.cast(u8, @divTrunc(state.x, 8)) orelse return error.InvalidFieldRoute;
    const cell_y = std.math.cast(u8, @divTrunc(state.y, 8)) orelse return error.InvalidFieldRoute;
    if (cell_x < 32 or cell_x > 38 or cell_y != 104) return error.InvalidFieldRoute;
    const program = binding.content.program(program_id) orelse return error.UnexportedFieldRoute;
    if (program.entry != .ordinary or program.entity != 1 or program.trigger != .none) return error.InvalidFieldRoute;
    const entity = for (binding.population.entities) |candidate| {
        if (candidate.source_order == program.entity) break candidate;
    } else return error.InvalidFieldRoute;
    if (entity.trigger != .ordinary or entity.event.status != .resolved or entity.event.program_id == null or
        !std.mem.eql(u8, entity.event.program_id.?, program.id)) return error.InvalidFieldRoute;
    const story = state.progress.story.scenario orelse return error.MissingSourceStoryState;
    if (!story.matches(program.conditions)) return error.IneligibleFieldRoute;
    var result: Session = undefined;
    try result.seed(binding, state, serial);
    result.selected_program = true;
    result.initialization_done = true;
    result.next_initialization = @intCast(binding.population.entities.len);
    result.instance = try runtime.start(binding.content, &story, program.id);
    try validate(&result, binding);
    return result;
}

/// Start the source VA1 room0 entity27 interaction while retaining the
/// initialized room host. Calling this method is the caller's interaction
/// admission; it never constructs or reseeds the field Session.
pub fn beginRetainedInteraction(self: *const Session, binding: Binding, state: field.State, entity_id: u8) !Session {
    if (!self.ordinaryReady() or entity_id != 27 or !self.initialization_done or self.busy() or self.selected_program or
        (self.retained_selection != null and self.retained_selection.? != entity_id) or
        self.ordinary_track != null or self.party_queue != null or self.text_job != null or
        self.boxes[0].phase != .closed or self.boxes[1].phase != .closed or self.fade_state.enabled or
        self.alignment != null or self.completed_event != null or self.reconstruction != null or
        self.position_history != null) return error.FieldEventBusy;
    for (self.other_tracks) |job| if (job != null) return error.FieldEventBusy;
    if (binding.ordinary == null or !std.mem.eql(u8, binding.content.id, "va1_room0_field_events") or
        !std.mem.eql(u8, binding.room, "va1_room_0") or binding.population.source.room != 0) return error.InvalidRetainedInteraction;
    if (binding.movement) |movement| if (movement.event_active) return error.FieldEventMovementActive;
    try validate(self, binding);

    const story = state.progress.story.scenario orelse return error.MissingSourceStoryState;
    try state.progress.validate();
    try self.validateStory(&story);
    const construction = self.ordinary_actors orelse return error.MissingFieldActorConstruction;
    if (!std.mem.eql(u8, story.schema, "suikoden-event-story/1") or story.scenario[0] != 0x40 or
        !std.mem.allEqual(u8, story.scenario[1..], 0) or state.x != self.hero.x or state.y != self.hero.y or
        !std.mem.eql(u8, &construction.construction_story.scenario, &story.scenario) or
        state.facing != .down or self.facing != .down or self.hero.moving() or self.hero.offset_x != 0 or
        self.hero.offset_y != 0 or state.x != 808 or state.y != 472 or state.walking or state.remaining != 0 or
        state.destination.x != state.x or state.destination.y != state.y) return error.IneligibleFieldInteraction;

    var eligible_storage: [population.max_entities]population.Entity = undefined;
    const eligible = try population.select(binding.population, .{ .story = &story, .active_party_count = self.active_party_count }, &eligible_storage);
    const source_entity = for (binding.population.entities) |candidate| {
        if (candidate.source_order == entity_id) break candidate;
    } else return error.IneligibleFieldInteraction;
    if (source_entity.record_role != .character or !source_entity.population_candidate or
        source_entity.classification.pointer_state == .null or source_entity.event_selection.pointer_state == .null or
        source_entity.trigger != .interaction or source_entity.event.status != .resolved or
        source_entity.event.program_id == null or
        !std.mem.eql(u8, source_entity.event.program_id.?, "va1_r00_e27_ordinary") or
        source_entity.resource_id == null or source_entity.position.placement != .placed or
        source_entity.position.x != 808 or source_entity.position.y != 488) return error.IneligibleFieldInteraction;
    const source_eligible = for (eligible.entities) |candidate| {
        if (candidate.source_order == entity_id) break true;
    } else false;
    if (!source_eligible) return error.IneligibleFieldInteraction;
    var interaction_term = false;
    for (source_entity.event_selection.terms) |term| switch (term.kind) {
        .interaction => interaction_term = true,
        .story_mask_set, .story_mask_clear => {
            const condition: runtime.Condition = .{ .kind = if (term.kind == .story_mask_set) .story_mask_set else .story_mask_clear, .flag = term.flag.? };
            if (!story.matches(&.{condition})) return error.IneligibleFieldInteraction;
        },
        .coordinate_range, .unsupported => return error.UnsupportedFieldEventPredicate,
        else => return error.UnsupportedFieldEventPredicate,
    };
    if (!interaction_term) return error.IneligibleFieldInteraction;

    const program = binding.content.program("va1_r00_e27_ordinary") orelse return error.UnexportedFieldInteraction;
    if (!retainedE27Program(program) or !story.matches(program.conditions)) return error.InvalidRetainedInteraction;

    const packet = binding.ordinary.?;
    const actors = construction;
    const actor_index = for (packet.actors, 0..) |definition, index| {
        if (definition.entity == entity_id) break index;
    } else return error.MissingFieldActorConstruction;
    if (actor_index >= actors.count or actors.slots[actor_index] == null or actors.slots[actor_index].?.phase != .active or actors.slots[actor_index].?.avatar == null) return error.IneligibleFieldInteraction;
    const avatar = actors.slots[actor_index].?.avatar.?;
    if (packet.actors[actor_index].entity != source_entity.source_order or
        !std.mem.eql(u8, packet.actors[actor_index].resource, source_entity.resource_id.?) or
        packet.actors[actor_index].x != source_entity.position.x or packet.actors[actor_index].y != source_entity.position.y or
        avatar.motion.x != 808 or avatar.motion.y != 488 or avatar.motion.moving() or avatar.support != null) return error.IneligibleFieldInteraction;

    var next_serial = self.serial;
    if (self.instance) |previous| {
        if (previous.execution.active or previous.execution.wait != null or previous.pending != null) return error.FieldEventBusy;
        next_serial = std.math.add(u64, self.serial, 1) catch return error.FieldEventSequenceOverflow;
    } else if (self.receipt != null) return error.InvalidFieldEventReceipt;
    if (next_serial == 0) return error.FieldEventSequenceOverflow;

    var next = self.*;
    next.schema = "suikoden-field-event/21";
    next.retained_selection = entity_id;
    next.serial = next_serial;
    next.receipt = null;
    next.instance = try runtime.start(binding.content, &story, program.id);
    try next.validate(binding);
    return next;
}

pub fn beginHomeRoute(self: *const Session, binding: Binding, state: field.State, up_held: bool) !Session {
    if (!up_held or !self.ordinaryReady() or !self.initialization_done or self.busy() or self.selected_program or
        self.ordinary_track != null or self.party_queue != null or self.text_job != null or self.alignment != null or
        self.boxes[0].phase != .closed or self.boxes[1].phase != .closed or self.fade_state.enabled or
        self.hero_descriptor_state == null or !std.mem.eql(u8, binding.room, "va1_room_0") or
        !std.mem.eql(u8, binding.content.id, "va1_room0_field_events")) return error.IneligibleHomeRoute;
    for (self.other_tracks) |job| if (job != null) return error.FieldEventBusy;
    try validate(self, binding);
    const story = state.progress.story.scenario orelse return error.MissingSourceStoryState;
    if (story.scenario[0] != 0x40 or !std.mem.allEqual(u8, story.scenario[1..], 0) or
        state.x != self.hero.x or state.y != self.hero.y or self.hero.moving() or
        @mod(state.x, 8) != 0 or state.x < 130 * 8 or state.x > 132 * 8 or state.y != 44 * 8) return error.IneligibleHomeRoute;
    const program = binding.content.program("va1_r00_e03_home") orelse return error.UnexportedFieldRoute;
    if (program.entry != .ordinary or program.entity != 3 or program.commands.len != 5 or
        program.commands[0].kind != .actor_transition or program.commands[0].actor == null or
        !std.mem.eql(u8, program.commands[0].actor.?, "hero") or program.commands[0].transition != 1 or
        program.commands[1].kind != .spatial_object_probe or program.commands[1].selector != 0x80 or
        program.commands[2].kind != .delay or program.commands[2].updates != 10 or program.commands[2].wait == null or program.commands[2].wait.?.kind != .delay or !std.mem.eql(u8, program.commands[2].wait.?.id, "delay") or
        program.commands[3].kind != .cue or program.commands[3].cue != 0x42c or
        program.commands[4].kind != .room_transition or program.commands[4].destination == null or
        !std.mem.eql(u8, program.commands[4].destination.?, "va1_room_1") or
        program.commands[4].x != 184 or program.commands[4].y != 352) return error.InvalidFieldRoute;
    var next = self.*;
    if (self.instance) |prior| {
        if (prior.execution.active or prior.pending != null or prior.execution.wait != null) return error.FieldEventBusy;
        next.serial = std.math.add(u64, self.serial, 1) catch return error.FieldEventSequenceOverflow;
    } else if (self.receipt != null) return error.InvalidFieldEventReceipt;
    next.retained_selection = null;
    next.schema = "suikoden-field-event/20";
    next.receipt = null;
    next.instance = try runtime.start(binding.content, &story, program.id);
    try next.validate(binding);
    return next;
}

pub fn room2DescriptorBinding(binding: Binding) !room2_descriptor.Binding {
    const packet = binding.ordinary orelse return error.MissingFieldActorConstruction;
    if (!std.mem.eql(u8, binding.room, "va1_room_2") or packet.actors.len == 0) return error.InvalidFieldEventState;
    const actor = packet.actors[0];
    const program = binding.content.program("va1_r02_e02_ordinary") orelse return error.InvalidFieldEventState;
    const offsets = [_]u32{ 0x3d174, 0x3d178, 0x3d17c, 0x3d181, 0x3d186, 0x3d19f, 0x3d1a4 };
    const indices = [_]u16{ 0, 1, 2, 3, 4, 14, 15 };
    for (indices, offsets) |index, offset| if (index >= program.commands.len or program.commands[index].source_offset != offset) return error.InvalidFieldEventState;
    return .{ .scene = packet.scene, .event_id = binding.content.id, .event_sha256 = binding.content.content_sha256, .program = program.id, .actor_id = actor.id, .resource = actor.resource, .graphic = actor.graphic, .entity = actor.entity, .slot = actor.slot, .selector = 0, .command_indices = indices };
}

pub fn room2ActorPosition(descriptor: Room2Descriptor) ordinary.Position {
    if (descriptor.movement_frames == 0) return .{ .actor = 0, .x = if (descriptor.history_len >= 1) 280 else 2032, .y = if (descriptor.history_len >= 2) 128 else 2032 };
    const attempts = @divTrunc(@as(i32, descriptor.movement_frames) + 3, 4);
    const phase = descriptor.movement_frames % 4;
    const offset: i16 = if (phase == 0) 0 else -8 + @as(i16, phase) * 2;
    const actor_motion: motion.ActorMotion = .{ .x = 280, .y = 128 + attempts * 8, .offset_y = offset, .speed = 2 };
    return .{ .actor = 0, .x = actor_motion.x, .y = actor_motion.y, .motion = actor_motion };
}

/// Enter the first source-ordered automatic event at the retained C40 arrival.
pub fn beginRoom2Event(self: *const Session, binding: Binding, state: field.State) !Session {
    if (!self.ordinaryReady() or !self.initialization_done or self.busy() or self.instance != null or self.receipt != null or
        !std.mem.eql(u8, binding.room, "va1_room_2") or !std.mem.eql(u8, binding.content.id, "va1_room2_field_events") or
        self.hero.moving() or self.hero.x != 152 or self.hero.y != 264 or state.x != 152 or state.y != 264) return error.IneligibleRoom2Event;
    try validate(self, binding);
    const story = state.progress.story.scenario orelse return error.MissingSourceStoryState;
    if (story.scenario[0] != 0x40 or !std.mem.allEqual(u8, story.scenario[1..], 0)) return error.IneligibleRoom2Event;
    const program = binding.content.program("va1_r02_e02_ordinary") orelse return error.UnexportedFieldRoute;
    if (program.entity != 2 or program.entry != .ordinary or !story.matches(program.conditions)) return error.InvalidFieldRoute;
    var next = self.*;
    next.schema = "suikoden-field-event/22";
    next.retained_selection = 2;
    _ = try room2DescriptorBinding(binding);
    next.room2_descriptor = .{};
    next.instance = try runtime.start(binding.content, &story, program.id);
    try next.validate(binding);
    return next;
}

pub fn beginHomeStairs(self: *const Session, binding: Binding, state: field.State) !Session {
    if (!self.ordinaryReady() or !self.initialization_done or self.busy() or self.instance != null or self.receipt != null or
        self.hero.moving() or self.hero_descriptor_state == null or !std.mem.eql(u8, binding.room, "va1_room_1") or
        !std.mem.eql(u8, binding.content.id, "va1_room1_field_events")) return error.IneligibleHomeStairs;
    try validate(self, binding);
    const story = state.progress.story.scenario orelse return error.MissingSourceStoryState;
    if (story.scenario[0] != 0x40 or !std.mem.allEqual(u8, story.scenario[1..], 0) or
        state.x != self.hero.x or state.y != self.hero.y or state.x != 17 * 8 or state.y != 35 * 8) return error.IneligibleHomeStairs;
    const program = binding.content.program("va1_r01_e01_exit") orelse return error.UnexportedFieldRoute;
    if (program.entity != 1 or program.entry != .ordinary or program.commands.len != 2 or
        program.commands[0].kind != .cue or program.commands[0].cue != 0x508 or
        program.commands[1].kind != .room_transition or program.commands[1].destination == null or
        !std.mem.eql(u8, program.commands[1].destination.?, "va1_room_2") or program.commands[1].x != 152 or program.commands[1].y != 264) return error.InvalidFieldRoute;
    var next = self.*;
    next.instance = try runtime.start(binding.content, &story, program.id);
    try next.validate(binding);
    return next;
}

/// Start the room-zero south-door route from an already initialized and
/// constructed field Session, retaining actor clocks and initializer receipts.
pub fn beginConstructedRoute(self: *const Session, binding: Binding, state: field.State, program_id: []const u8) !Session {
    if (!self.ordinaryReady()) return error.FieldEventEntryOwnsFrame;
    if (!self.initialization_done or self.busy() or self.instance != null or self.receipt != null or
        self.blocker != null or self.selected_program or self.ordinary_track != null or
        self.party_queue != null or self.text_job != null or self.boxes[0].phase != .closed or
        self.boxes[1].phase != .closed or self.fade_state.enabled or self.alignment != null) return error.FieldEventBusy;
    for (self.other_tracks) |job| if (job != null) return error.FieldEventBusy;
    const movement = binding.movement orelse return error.MissingFieldMovementAccess;
    if (movement.event_active) return error.FieldEventMovementActive;
    if (movement.identity.len == 0 or movement.identity.len > 128 or movement.camera.x < 0 or movement.camera.y < 0 or movement.camera.x > 2040 or movement.camera.y > 2040) return error.InvalidFieldMovementAccess;
    try validate(self, binding);
    const actors = self.ordinary_actors orelse return error.MissingFieldActorConstruction;
    const room0 = std.mem.eql(u8, binding.content.id, "vaa_room0_field_events") and
        std.mem.eql(u8, binding.room, "vaa_room_0") and binding.population.source.room == 0;
    const room10 = std.mem.eql(u8, binding.content.id, "vaa_room10_field_events") and
        std.mem.eql(u8, binding.room, "vaa_room_10") and binding.population.source.room == 10;
    if (binding.ordinary == null or self.construction_ground_identity.len == 0 or (!room0 and !room10)) return error.InvalidFieldRoute;
    const story = state.progress.story.scenario orelse return error.MissingSourceStoryState;
    try state.progress.validate();
    if (!std.mem.eql(u8, story.schema, "suikoden-event-story/1") or story.scenario[0] != 0x40 or
        !std.mem.allEqual(u8, story.scenario[1..], 0) or
        !std.mem.eql(u8, &actors.construction_story.scenario, &story.scenario)) return error.IneligibleFieldRoute;
    const source_x = std.math.cast(u8, @divTrunc(state.x, 8)) orelse return error.InvalidFieldRoute;
    const source_y = std.math.cast(u8, @divTrunc(state.y, 8)) orelse return error.InvalidFieldRoute;
    const in_source_guard = if (room0)
        source_x >= 37 and source_x <= 41 and source_y >= 93 and source_y <= 94
    else
        source_x >= 18 and source_x <= 28 and source_y >= 29 and source_y <= 30;
    if (state.x != self.hero.x or state.y != self.hero.y or state.facing != self.facing or
        @mod(state.x, 8) != 0 or @mod(state.y, 8) != 0 or !in_source_guard) return error.InvalidFieldRoute;
    const expected_program: []const u8 = if (room0) "vaa_r00_e15_exit" else "vaa_r10_e01_exit";
    if (!std.mem.eql(u8, program_id, expected_program)) return error.InvalidFieldRoute;
    const program = binding.content.program(program_id) orelse return error.UnexportedFieldRoute;
    const expected_entity: u8 = if (room0) 15 else 1;
    if (program.entry != .ordinary or program.entity != expected_entity or program.trigger != .none or !story.matches(program.conditions)) return error.InvalidFieldRoute;
    const entity = for (binding.population.entities) |candidate| {
        if (candidate.source_order == program.entity) break candidate;
    } else return error.InvalidFieldRoute;
    if (entity.trigger != .ordinary or entity.event.status != .resolved or entity.event.program_id == null or
        !std.mem.eql(u8, entity.event.program_id.?, program.id)) return error.InvalidFieldRoute;
    if (room10) {
        if (!std.mem.eql(u8, self.schema, "suikoden-field-event/20") or program.commands.len != 1 or
            program.commands[0].kind != .room_transition or program.commands[0].destination == null or
            !std.mem.eql(u8, program.commands[0].destination.?, "va1_room_0") or
            program.commands[0].x != 808 or program.commands[0].y != 56) return error.InvalidFieldRoute;
        const archived = for (self.initializations[0..self.initialization_count]) |entry| {
            if (entry) |initializer| if (initializer.entity == 2 and initializer.kind == .pure_pump and
                initializer.pump_pc == 2 and std.mem.eql(u8, initializer.program, "vaa_r10_init_02")) break true;
        } else false;
        if (!archived) return error.InvalidFieldRoute;
    }
    var next = self.*;
    next.instance = try runtime.start(binding.content, &story, program.id);
    try next.validate(binding);
    return next;
}

// The world owner selects the source rectangle and owns the eventual handback.
pub fn beginWorldExit(binding: Binding, state: field.State, serial: u64) !Session {
    try binding.validateContext();
    if (!std.mem.eql(u8, binding.content.id, "vb6_room0_world_exit") or !std.mem.eql(u8, binding.room, "vb6_village")) return error.InvalidFieldEventBinding;
    const story = state.progress.story.scenario orelse return error.MissingSourceStoryState;
    var result: Session = undefined;
    try result.seed(binding, state, serial);
    result.initialization_done = true;
    result.next_initialization = @intCast(binding.population.entities.len);
    result.instance = try runtime.start(binding.content, &story, "vb6_room0_world_exit");
    try validate(&result, binding);
    return result;
}

// Select the first source record, including unresolved records; never skip to a convenient program.
pub noinline fn select(self: *Session, binding: Binding, story: *const runtime.StoryState, trigger: @FieldType(population.Entity, "trigger"), interaction: ?u8) !void {
    return selectInternal(self, binding, .{ .story = story, .active_party_count = @intCast(binding.party.len), .party = binding.party }, trigger, interaction, null, null);
}

pub fn selectWithFacts(
    self: *Session,
    binding: Binding,
    facts: population.Facts,
    trigger: @FieldType(population.Entity, "trigger"),
    interaction: ?u8,
    direction: ?field.Direction,
    flags: ?*const field.room_flags.State,
) !void {
    return selectInternal(self, binding, facts, trigger, interaction, direction, flags);
}

fn programSelectionMatches(
    terms: []const runtime.Selection,
    cell: ?population.Cell,
    direction: ?field.Direction,
    flags: ?*const field.room_flags.State,
    facts: population.Facts,
) !bool {
    const party = if (facts.party.len != 0) facts.party else &.{};
    for (terms) |term| {
        switch (term.kind) {
            .party_absent => {
                for (party) |member_id| if (member_id == term.index) return false;
            },
            .party_contains => {
                const found = for (party) |member_id| {
                    if (member_id == term.index) break true;
                } else false;
                if (!found) return false;
            },
            .room_mask_set, .room_mask_clear => {
                const local = flags orelse return false;
                const mask = std.math.cast(u8, term.mask) orelse return false;
                if (!local.matches(term.index, mask, term.kind == .room_mask_set)) return false;
            },
            .pressed_mask => {
                const required = runtime.Direction.fromPadMask(term.mask) orelse return false;
                if (direction != events.fieldDirection(required)) return false;
            },
            .hero_x_inclusive, .hero_y_inclusive, .hero_x_strict, .hero_y_strict => {
                const position = cell orelse return false;
                const matches = switch (term.kind) {
                    .hero_x_inclusive => term.min <= position.x and position.x <= term.max,
                    .hero_y_inclusive => term.min <= position.y and position.y <= term.max,
                    .hero_x_strict => term.min < position.x and position.x < term.max,
                    .hero_y_strict => term.min < position.y and position.y < term.max,
                    else => false,
                };
                if (!matches) return false;
            },
            .story_mask_set, .story_mask_clear => {
                const cond: runtime.Condition = .{
                    .kind = if (term.kind == .story_mask_set) .story_mask_set else .story_mask_clear,
                    .flag = term.flag.?,
                };
                if (!facts.story.matches(&.{cond})) return false;
            },
            .confirm_pressed => if (!facts.confirm_pressed) return false,
            .money_at_least => if (facts.money < term.amount) return false,
            .recruit_present => {
                if (term.index >= facts.story.recruit_flags.len) return false;
                const b = facts.story.recruit_flags[term.index];
                if ((b & 1) == 0 or (b & 2) != 0) return false;
            },
            .recruit_absent => {
                if (term.index >= facts.story.recruit_flags.len) return false;
                if ((facts.story.recruit_flags[term.index] & 3) != 0) return false;
            },
            .recruit_ever => {
                if (term.index >= facts.story.recruit_flags.len) return false;
                if ((facts.story.recruit_flags[term.index] & 3) == 0) return false;
            },
            .party_count_equals => if (facts.active_party_count != term.index) return false,
            .level_at_least => {
                const current = try characterLevel(facts, term.index);
                if (current == 0 or current < term.min) return false;
            },
            .stage_at_least => if (facts.story.castle_tier < term.min) return false,
            .random_chance => {
                const q = @divTrunc(@as(u32, 0x7fff), @as(u32, term.divisor));
                if (q != 0 and @divTrunc(facts.rng & 0x7fff, q) != 0) return false;
            },
            .recruit_count_at_least => if (facts.story.recruitCount() < term.index) return false,
            .has_item => if (!try itemMatches(facts, if (term.mask != 0) term.mask else term.index, term.require_key)) return false,
        }
    }
    return true;
}

fn characterLevel(facts: population.Facts, id: u8) !u8 {
    const levels = facts.levels orelse return error.MissingFieldCharacterLevels;
    return levels[id];
}

fn itemMatches(facts: population.Facts, id: u16, equipped: bool) !bool {
    return population.eventTermMatchesWithFacts(.{ .kind = .has_item, .item_id = id, .require_key = equipped }, facts, false, null) orelse error.MissingFieldItemPresence;
}

noinline fn selectInWorld(self: *Session, binding: Binding, state: field.State, trigger: @FieldType(population.Entity, "trigger"), interaction: ?u8, direction: ?field.Direction) !void {
    const story = state.progress.story.scenario orelse return error.MissingSourceStoryState;
    return selectInternal(self, binding, .{
        .story = &story,
        .active_party_count = @intCast(binding.party.len),
        .party = binding.party,
        .room_flags = &state.local_flags.values,
        .money = state.progress.money,
        .levels = binding.character_levels,
        .item_ids = if (binding.item_presence) |items| items.carried else null,
        .equipped_item_ids = if (binding.item_presence) |items| items.equipped else null,
    }, trigger, interaction, direction, &state.local_flags);
}

noinline fn selectInternal(self: *Session, binding: Binding, supplied_facts: population.Facts, trigger: @FieldType(population.Entity, "trigger"), interaction: ?u8, direction: ?field.Direction, flags: ?*const field.room_flags.State) !void {
    var facts = supplied_facts;
    facts.direction_mask = field.directionPadMask(direction);
    const story = facts.story;
    const cell = population.Cell.fromPixels(self.hero.x, self.hero.y);
    entity_loop: for (binding.population.entities) |entity| {
        if (entity.trigger != trigger or entity.event_selection.pointer_state == .null) continue;
        if (binding.room_package != null and entity.event.status == .source_only) continue;
        if (trigger == .initialization and entity.source_order < self.next_initialization) continue;
        if (trigger == .interaction and interaction != entity.source_order) continue;
        // VA1 room 2 entity20 tests cell (10,36) before its story term.
        // The only admitted constructor spawn is (19,33), so that source
        // predicate fails. Other positions retain the unsupported blocker.
        if (trigger == .initialization and entity.source_order == 20 and std.mem.eql(u8, binding.content.id, "va1_room2_field_events") and
            self.hero.x == 152 and self.hero.y == 264 and story.scenario[0] == 0x40 and std.mem.allEqual(u8, story.scenario[1..], 0)) continue;
        for (entity.event_selection.terms) |term| {
            const matches = if (term.kind == .level_at_least) level: {
                const current = try characterLevel(facts, term.character_id.?);
                break :level current != 0 and current >= term.level.?;
            } else if (term.kind == .has_item)
                try itemMatches(facts, term.item_id.?, term.require_key)
            else
                population.eventTermMatchesWithFacts(term, facts, interaction == entity.source_order, cell) orelse return error.UnsupportedFieldEventPredicate;
            if (!matches) continue :entity_loop;
        }
        if (entity.event.status == .source_only) {
            if (trigger == .initialization or trigger == .interaction) for (binding.content.programs) |program| {
                if (program.entity == entity.source_order and ((trigger == .initialization and program.entry == .initialization) or (trigger == .interaction and program.entry == .ordinary and program.trigger == .interaction))) {
                    self.instance = try runtime.start(binding.content, story, program.id);
                    return;
                }
            };
            self.blocker = .{ .entity = entity.source_order, .reason = .unexported_program };
            return;
        }
        const program_id = entity.event.program_id.?;
        if (trigger == .ordinary or (binding.room_package != null and (trigger == .area_entry or trigger == .interaction))) {
            const program = binding.content.program(program_id) orelse return error.UnknownEventProgram;
            const expected: @FieldType(runtime.Program, "trigger") = switch (trigger) {
                .area_entry => .area_entry,
                .interaction => .interaction,
                else => .none,
            };
            if (program.entity != entity.source_order or program.entry != .ordinary or program.trigger != expected) return error.InvalidFieldEventBinding;
            if (!story.matches(program.conditions) or !try programSelectionMatches(program.selection, cell, direction, flags, facts)) continue :entity_loop;
        }
        self.instance = try runtime.start(binding.content, story, program_id);
        return;
    }
}

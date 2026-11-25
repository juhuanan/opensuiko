const std = @import("std");
const field = @import("field");
const runtime = @import("event_runtime");
const records = @import("opening_records");
const ted_party_add = records.ted_party_add;
const field_records = records.field_records;
const room2_descriptor = @import("descriptor_release");
const room2_movement = @import("movement_batch");
const room2_text_host = @import("room2_text").host;
const fade = @import("fade");
const population = @import("scene_population");
const dispatch = @import("scene_dispatch");
const motion = @import("opening_audience");
const hero_descriptor = @import("hero_descriptor");
const data = @import("field_events_data");
const ordinary = @import("field_actors");
const village = @import("village_initializer.zig");
const fe = @import("field_events.zig");
const Room2Descriptor = fe.Room2Descriptor;
const TextState = fe.TextState;
const TextSpeed = fe.TextSpeed;
const sources_mod = @import("field_events_sources.zig");
const FieldPredicates = sources_mod.FieldPredicates;
const GroundAccess = fe.GroundAccess;
const Binding = fe.Binding;
const CompletedEvent = fe.CompletedEvent;
const Initialization = fe.Initialization;
const Session = fe.Session;
const rebind = fe.rebind;

pub fn pureInitializationProgram(program: runtime.Program, pump_pc: u16) bool {
    const commands = program.commands;
    return program.entry == .initialization and commands.len == 3 and
        commands[0].kind == .continue_tick and commands[1].kind == .yield_tick and
        commands[2].kind == .end_stream and pump_pc == 2;
}

pub fn pureInitializationPump(program: runtime.Program, owner: *const runtime.Instance) bool {
    return pureInitializationProgram(program, owner.execution.pc) and
        owner.execution.active and !owner.execution.reloop and owner.execution.wait == null and
        owner.pending == null and owner.effect_sequence == 0;
}

pub fn retainedE27Program(program: runtime.Program) bool {
    if (program.entry != .ordinary or program.entity != 27 or program.trigger != .interaction or program.commands.len != 5) return false;
    const open = program.commands[0];
    const text = program.commands[1];
    const accept = program.commands[2];
    const close = program.commands[3];
    const end = program.commands[4];
    return open.kind == .open_box and open.box == 0 and open.layout == 0 and open.requires != null and
        open.requires.?.kind == .box_closed and std.mem.eql(u8, open.requires.?.id, "box_0") and
        text.kind == .text and text.box == 0 and text.text != null and std.mem.eql(u8, text.text.?, "va1_r00_text_0") and
        accept.kind == .wait_for_accept and close.kind == .close_box and close.box == 0 and
        end.kind == .end_stream and end.requires != null and end.requires.?.kind == .event_flags_low2 and
        std.mem.eql(u8, end.requires.?.id, "dialogue_flags");
}

noinline fn isOffMapStaging(binding: *const Binding, definition: ordinary.Definition) !bool {
    if (definition.scene_owned) return false;
    for (binding.population.entities) |entity| if (entity.source_order == definition.entity) {
        if (entity.record_role != .character or !entity.population_candidate or
            entity.position.x != definition.x or entity.position.y != definition.y) return error.InvalidFieldActorState;
        return entity.position.placement == .off_map_staging;
    };
    return error.InvalidFieldActorState;
}

pub noinline fn validateConstructedGround(binding: *const Binding, actors: *const ordinary.State, access: GroundAccess, source_staging: bool) !void {
    const packet = binding.ordinary orelse return error.UnsupportedFieldGroundConstruction;
    if (actors.count != packet.actors.len) return error.UnsupportedFieldGroundConstruction;
    for (actors.slots[0..actors.count], 0..) |slot, index| if (slot) |entry| if (entry.avatar) |avatar| {
        if (avatar.support != null) return error.UnsupportedFieldGroundConstruction;
        if (source_staging and try isOffMapStaging(binding, packet.actors[index])) continue;
        if (access.ground_fn(access.context, avatar.id, avatar.motion) != true) return error.UnsupportedFieldGroundConstruction;
    };
}

pub const Reconstruction = struct { arrival: CompletedEvent, followon: CompletedEvent, arrival_initializer: Initialization };
pub const Blocker = struct { entity: u8, command: ?u16 = null, reason: enum { unimplemented_effect, unexported_program, unbound_actor, source_gate_unknown, unsupported_predicate, room_coordinate_transition, unbound_dispatch_program } = .unimplemented_effect };
pub const Result = enum { idle, running, completed, blocked };

pub const DispatchInput = struct {
    locks: dispatch.Locks = .{},
    unsupported_terms: dispatch.UnsupportedTerms = .unsupported,
    up_held: ?bool = null,
    post_frame_mode: enum { clear, pending, unsupported } = .unsupported,
};
pub const PredicateFacts = struct {
    predicates: FieldPredicates,
    position: field.Point,
    up_held: ?bool,
    fn resolve(raw: *const anyopaque, entity: u8, index: usize, semantics: []const u8) ?bool {
        const facts: *const PredicateFacts = @ptrCast(@alignCast(raw));
        if (entity >= facts.predicates.records.len) return null;
        const record = facts.predicates.records[entity];
        if (record.entity != entity or index >= record.terms.len) return null;
        const term = record.terms[index];
        if (!std.mem.eql(u8, term.source_kind, semantics)) return null;
        return switch (term.kind) {
            .x_range => facts.position.x >= term.min_pixel.? and facts.position.x <= term.max_pixel.?,
            .y_range => facts.position.y >= term.min_pixel.? and facts.position.y <= term.max_pixel.?,
            .up_input => facts.up_held,
        };
    }
};
pub const DispatchTracker = struct {
    population_sha256: []const u8,
    dispatch_sha256: []const u8,
    bundle_sha256: []const u8,
    predicates_sha256: []const u8,
    construction_story: runtime.StoryState,
    phase: enum { event_frame, free_selection } = .event_frame,

    pub fn start(binding: Binding, story: runtime.StoryState) !DispatchTracker {
        const policy = binding.dispatch orelse return error.MissingFieldDispatch;
        if (policy.packet.scene(binding.population.id) == null or !std.mem.eql(u8, story.schema, "suikoden-event-story/1")) return error.InvalidFieldDispatchState;
        return .{ .population_sha256 = binding.population.content_sha256, .dispatch_sha256 = policy.packet.content_sha256, .bundle_sha256 = policy.bundle.content_sha256, .predicates_sha256 = policy.predicates.content_sha256, .construction_story = story };
    }
    pub fn rebind(self: *DispatchTracker, binding: Binding) !void {
        const policy = binding.dispatch orelse return error.MissingFieldDispatch;
        self.population_sha256 = binding.population.content_sha256;
        self.dispatch_sha256 = policy.packet.content_sha256;
        self.bundle_sha256 = policy.bundle.content_sha256;
        self.predicates_sha256 = policy.predicates.content_sha256;
        self.construction_story.schema = "suikoden-event-story/1";
    }
    pub fn validate(self: DispatchTracker, binding: Binding, session: *const Session) !void {
        const policy = binding.dispatch orelse return error.InvalidFieldDispatchState;
        if (!std.mem.eql(u8, self.population_sha256, binding.population.content_sha256) or !std.mem.eql(u8, self.dispatch_sha256, policy.packet.content_sha256) or !std.mem.eql(u8, self.bundle_sha256, policy.bundle.content_sha256) or !std.mem.eql(u8, self.predicates_sha256, policy.predicates.content_sha256) or !std.mem.eql(u8, self.construction_story.schema, "suikoden-event-story/1")) return error.InvalidFieldDispatchState;
        if (self.phase == .free_selection and (!session.initialization_done or session.instance == null or session.instance.?.execution.active or session.instance.?.pending != null)) return error.InvalidFieldDispatchState;
        if (session.initialization_done and session.instance != null) _ = try session.dispatchInstance(binding);
    }
    pub fn advance(self: *DispatchTracker, binding: Binding, session: *const Session, state: field.State, story: *const runtime.StoryState, input: DispatchInput) !dispatch.Decision {
        try self.validate(binding, session);
        if (!session.initialization_done or session.instance == null) return error.InvalidFieldDispatchState;
        const policy = binding.dispatch.?;
        try policy.predicates.validate(binding.population);
        if (self.phase == .free_selection and input.locks.free_gate == .clear and (state.walking or state.remaining != 0 or @mod(state.x, 8) != 0 or @mod(state.y, 8) != 0)) return error.InvalidFieldDispatchState;
        const scene = policy.packet.scene(binding.population.id) orelse return error.InvalidFieldDispatchState;
        var owner = try session.dispatchInstance(binding);
        const predicates: PredicateFacts = .{ .predicates = policy.predicates, .position = .{ .x = state.x, .y = state.y }, .up_held = input.up_held };
        const decision = try dispatch.plan(policy.packet, scene.id, binding.population, .{
            .phase = if (self.phase == .event_frame) .event_frame else .free_selection,
            .story = story,
            .construction = .{ .scene_id = scene.id, .phase = .active, .population = scene.population, .bundle = scene.bundle, .story = &self.construction_story },
            .initialization_cursor = scene.initialization_count,
            .contents = policy.contents,
            .owner = if (self.phase == .event_frame) &owner else null,
            .locks = input.locks,
            .field_cell = population.Cell.fromPixels(state.x, state.y),
            .unsupported_terms = input.unsupported_terms,
            .term_resolver = .{ .context = &predicates, .resolve_fn = PredicateFacts.resolve },
        });
        if (self.phase == .event_frame) {
            // The later source mode driver may replace either event or free handler.
            switch (input.post_frame_mode) {
                .clear => {},
                .pending => return error.UnsupportedFieldModeTransition,
                .unsupported => return error.UnsupportedDispatchDependency,
            }
        }
        if (decision.action == .rearm_free_selection) self.phase = .free_selection;
        return decision;
    }
    pub fn startSelected(self: *DispatchTracker, binding: Binding, session: *Session, state: field.State, story: *const runtime.StoryState, input: DispatchInput) !dispatch.Decision {
        if (self.phase != .free_selection) return error.InvalidFieldDispatchState;
        var tracker = self.*;
        const decision = try tracker.advance(binding, session, state, story, input);
        if (decision.kind != .selected_ordinary or decision.source_order != 7) return decision;
        const reference = decision.program orelse return error.InvalidFieldDispatchState;
        if (!std.mem.eql(u8, reference.content_id, "vb6_room6_e7") or !std.mem.eql(u8, reference.program_id, "vb6_r06_entity07_followon")) return error.UnknownDispatchOwner;
        const old = session.instance orelse return error.MissingFieldEventOwner;
        const receipt = session.receipt orelse return error.InvalidFieldEventReceipt;
        if (!std.mem.eql(u8, session.schema, "suikoden-field-event/16") or old.execution.active or old.pending != null or !std.mem.eql(u8, old.program_id, "vb6_r06_first_arrival") or old.effect_sequence != 20 or receipt.batch != old.effect_sequence or receipt.instance != session.serial) return error.InvalidFieldEventReceipt;
        var next = session.*;
        next.completed_event = .{ .execution = old.execution, .effect_sequence = old.effect_sequence, .receipt = receipt };
        next.serial = std.math.add(u64, next.serial, 1) catch return error.FieldEventSequenceOverflow;
        next.instance = try runtime.start(binding.content, story, reference.program_id);
        next.receipt = null;
        next.schema = "suikoden-field-event/17";
        try next.validate(binding);
        try next.validateStory(story);
        _ = try next.dispatchInstance(binding);
        tracker.phase = .event_frame;
        session.* = next;
        self.* = tracker;
        return decision;
    }
};

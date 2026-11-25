const std = @import("std");
const validation = @import("validation");
const population = @import("scene_population");
const event_runtime = @import("event_runtime");

pub const schema = "suikoden-scene-dispatch/1";
pub const max_json_bytes = 1024 * 1024;

pub const Identity = struct { content_id: []const u8, content_sha256: []const u8 };
pub const CallerPhase = enum {
    construction_initialization,
    free_selection,
    event_frame,
    area_49c_callback,
    area_498_callback,
    menu,
};
pub const Caller = struct {
    phase: CallerPhase,
    function: []const u8,
    supported: bool,
    selector: ?[]const u8,
    rule: []const u8,
};
pub const PredicateContract = struct { decoder: []const u8, evaluation: []const u8 };
pub const OwnershipContract = struct {
    instance: []const u8,
    free_selection: []const u8,
    event_frame: []const u8,
    locks: []const u8,
};
pub const InitializationContract = struct { cursor: []const u8, lifetime: []const u8 };
pub const ExecutionEntry = enum { ordinary, initialization };
pub const QualifiedReference = struct {
    namespace: []const u8,
    content_id: []const u8,
    content_sha256: []const u8,
    program_id: []const u8,
    entry: ExecutionEntry,

    pub fn eql(a: QualifiedReference, b: QualifiedReference) bool {
        return a.entry == b.entry and std.mem.eql(u8, a.namespace, b.namespace) and
            std.mem.eql(u8, a.content_id, b.content_id) and
            std.mem.eql(u8, a.content_sha256, b.content_sha256) and
            std.mem.eql(u8, a.program_id, b.program_id);
    }
};
pub const Reason = enum {
    initialization_complete,
    no_ordinary_match,
    completed_return_to_free_selection,
    program_not_compiled,
    room_coordinate_transition,
    unsupported_predicate,
    active_instance,
    caller_gate,
    vm_gate,
    event_flags_low2,
    completion_gate,
};
pub const SourceBlocker = struct {
    reason: Reason,
    source_offset: u32,
    source_address: u32,
};
pub const Entry = struct {
    source_entity_id: []const u8,
    source_order: u8,
    phase: ExecutionEntry,
    status: enum { executable, blocked_unsupported },
    program: ?QualifiedReference,
    blocker: ?SourceBlocker,
};
pub const Scene = struct {
    id: []const u8,
    source: population.Source,
    population: Identity,
    bundle: Identity,
    initialization_count: u8,
    entries: []const Entry,

    pub fn entry(self: Scene, source_order: u8) ?Entry {
        for (self.entries) |candidate| if (candidate.source_order == source_order) return candidate;
        return null;
    }
};
pub const Packet = struct {
    schema: []const u8,
    id: []const u8,
    sources: []const population.Source,
    callers: []const Caller,
    predicate_contract: PredicateContract,
    ownership_contract: OwnershipContract,
    initialization_contract: InitializationContract,
    reference_contract: []const u8,
    scenes: []const Scene,
    content_sha256: []const u8,

    pub fn scene(self: Packet, id: []const u8) ?Scene {
        for (self.scenes) |candidate| if (std.mem.eql(u8, candidate.id, id)) return candidate;
        return null;
    }
};

pub const ConstructionPhase = enum { constructing, active, recreated };
pub const Construction = struct {
    scene_id: []const u8,
    phase: ConstructionPhase,
    population: Identity,
    bundle: Identity,
    story: *const event_runtime.StoryState,
};
pub const FreeGate = enum { clear, blocked, unsupported };
pub const VmGate = enum { clear, text_blocked, unsupported };
pub const Locks = struct {
    free_gate: FreeGate = .unsupported,
    vm_gate: VmGate = .unsupported,
    completion_gate: FreeGate = .unsupported,
    event_flags_low2: u2 = 0,
};
pub const UnsupportedTerms = enum { unsupported, all_false };
pub const TermResolver = struct {
    context: *const anyopaque,
    resolve_fn: *const fn (*const anyopaque, u8, usize, []const u8) ?bool,
};
pub const Facts = struct {
    phase: CallerPhase,
    story: *const event_runtime.StoryState,
    construction: Construction,
    initialization_cursor: u8,
    // Borrow the actual parsed program contents; a packet reference cannot authorize itself.
    contents: []const event_runtime.Content = &.{},
    owner: ?*const event_runtime.Instance = null,
    locks: Locks = .{},
    interaction_entity: ?u8 = null,
    field_cell: ?population.Cell = null,
    unsupported_terms: UnsupportedTerms = .unsupported,
    term_resolver: ?TermResolver = null,
};
pub const DecisionKind = enum {
    continue_current_instance,
    wait_current_instance,
    no_candidate,
    selected_initialization,
    selected_ordinary,
    blocked,
};
pub const Action = enum {
    none,
    pump_once_and_advance,
    start_event_owner,
    continue_event_frame,
    finish_initialization,
    rearm_free_selection,
};
pub const Decision = struct {
    kind: DecisionKind,
    source_entity_id: ?[]const u8 = null,
    source_order: ?u8 = null,
    program: ?QualifiedReference = null,
    reason: ?Reason = null,
    next_initialization_cursor: ?u8 = null,
    action: Action = .none,
};

fn validId(id: []const u8) !void {
    if (!validation.isAsciiId(id, 96, "_")) return error.InvalidDispatchId;
}

fn validHash(hash: []const u8) !void {
    if (!validation.isHex64(hash)) return error.InvalidDispatchIdentity;
}

fn validIdentity(identity: Identity) !void {
    try validId(identity.content_id);
    try validHash(identity.content_sha256);
}

fn sameIdentity(a: Identity, b: Identity) bool {
    return std.mem.eql(u8, a.content_id, b.content_id) and std.mem.eql(u8, a.content_sha256, b.content_sha256);
}

fn validReference(reference: QualifiedReference, phase: ExecutionEntry) !void {
    try validId(reference.content_id);
    try validId(reference.program_id);
    try validHash(reference.content_sha256);
    if (!std.mem.eql(u8, reference.namespace, "suikoden-event-ir/1") or reference.entry != phase) return error.InvalidDispatchProgramReference;
}

pub fn validate(packet: Packet) !void {
    if (!std.mem.eql(u8, packet.schema, schema)) return error.UnsupportedDispatchSchema;
    try validId(packet.id);
    try validHash(packet.content_sha256);
    if (packet.sources.len != 2 or packet.scenes.len != 2 or packet.callers.len != 6) return error.InvalidDispatchContent;
    for (packet.sources) |source| {
        if (source.file.len == 0 or source.size == 0) return error.InvalidDispatchSource;
        try validHash(source.sha256);
    }
    for (packet.callers, [_]CallerPhase{ .construction_initialization, .free_selection, .event_frame, .area_49c_callback, .area_498_callback, .menu }, 0..) |caller, phase, index| {
        if (caller.phase != phase or caller.supported != (index < 3)) return error.InvalidDispatchCaller;
    }
    for (packet.scenes, 0..) |scene, scene_index| {
        try validId(scene.id);
        try validIdentity(scene.population);
        try validIdentity(scene.bundle);
        if (!std.mem.eql(u8, scene.id, scene.population.content_id) or !std.mem.eql(u8, scene.id, scene.bundle.content_id)) return error.InvalidDispatchDependency;
        if (scene.initialization_count == 0 or scene.source.room == 0 or scene.entries.len > 64) return error.InvalidDispatchContent;
        const source = packet.sources[scene_index];
        if (source.room != scene.source.room or source.lba != scene.source.lba or !std.mem.eql(u8, source.file, scene.source.file) or !std.mem.eql(u8, source.sha256, scene.source.sha256)) return error.InvalidDispatchSource;
        for (scene.entries, 0..) |entry, index| {
            try validId(entry.source_entity_id);
            for (scene.entries[0..index]) |other| {
                if (entry.source_order == other.source_order or std.mem.eql(u8, entry.source_entity_id, other.source_entity_id)) return error.DuplicateDispatchEntry;
            }
            switch (entry.status) {
                .executable => {
                    if (entry.blocker != null) return error.InvalidDispatchEntry;
                    try validReference(entry.program orelse return error.InvalidDispatchProgramReference, entry.phase);
                },
                .blocked_unsupported => {
                    if (entry.program != null or entry.blocker == null) return error.InvalidDispatchEntry;
                },
            }
        }
    }
}

pub fn load(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Packet) {
    if (bytes.len > max_json_bytes) return error.DispatchContentTooLarge;
    const parsed = try std.json.parseFromSlice(Packet, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    try validate(parsed.value);
    return parsed;
}

fn validateScene(scene: Scene, pop: population.Packet) !void {
    if (!std.mem.eql(u8, pop.id, scene.id) or !sameIdentity(scene.population, .{ .content_id = pop.id, .content_sha256 = pop.content_sha256 })) return error.StaleDispatchPopulation;
    if (pop.source.room != scene.source.room or !std.mem.eql(u8, pop.source.file, scene.source.file) or !std.mem.eql(u8, pop.source.sha256, scene.source.sha256)) return error.StaleDispatchPopulation;
    var initialization_count: u8 = 0;
    for (pop.entities) |entity| if (entity.record_role == .initialization) {
        initialization_count += 1;
    };
    if (initialization_count != scene.initialization_count) return error.InvalidDispatchInitialization;
    for (scene.entries) |entry| {
        if (entry.source_order >= pop.entities.len) return error.UnknownDispatchEntity;
        const entity = pop.entities[entry.source_order];
        const phase: ExecutionEntry = if (entity.record_role == .initialization) .initialization else .ordinary;
        if (!std.mem.eql(u8, entity.id, entry.source_entity_id) or phase != entry.phase) return error.DispatchEntityMismatch;
    }
}

fn referencedContent(reference: QualifiedReference, contents: []const event_runtime.Content) !event_runtime.Content {
    for (contents) |content| {
        if (std.mem.eql(u8, reference.content_id, content.id) and
            std.mem.eql(u8, reference.content_sha256, content.content_sha256))
        {
            try content.validate();
            if (content.program(reference.program_id) != null) return content;
        }
    }
    return error.MissingDispatchProgramContent;
}

fn validatedProgramContent(entry: Entry, contents: []const event_runtime.Content) !event_runtime.Content {
    const reference = entry.program.?;
    const content = try referencedContent(reference, contents);
    const program = content.program(reference.program_id).?;
    if (program.entity != entry.source_order or
        !std.mem.eql(u8, @tagName(program.entry), @tagName(entry.phase)))
        return error.DispatchProgramEntityMismatch;
    return content;
}

fn validateFacts(scene: Scene, facts: Facts) !void {
    if (!std.mem.eql(u8, facts.construction.scene_id, scene.id) or
        !sameIdentity(facts.construction.population, scene.population) or
        !sameIdentity(facts.construction.bundle, scene.bundle)) return error.StaleDispatchConstruction;
    if (facts.phase == .construction_initialization) {
        if (facts.construction.phase != .constructing or facts.initialization_cursor > scene.initialization_count) return error.InvalidDispatchConstruction;
    } else {
        if (facts.construction.phase == .constructing or facts.initialization_cursor != scene.initialization_count) return error.InvalidDispatchInitialization;
    }
    if (facts.owner) |owner| {
        if (!std.mem.eql(u8, owner.schema, event_runtime.state_schema) or (!owner.execution.active and owner.pending != null)) return error.InvalidDispatchOwnership;
        var found = false;
        for (scene.entries) |entry| {
            if (entry.status != .executable) continue;
            const reference = entry.program.?;
            if (std.mem.eql(u8, owner.content_id, reference.content_id) and
                std.mem.eql(u8, owner.content_sha256, reference.content_sha256) and
                std.mem.eql(u8, owner.program_id, reference.program_id))
            {
                const expected: ExecutionEntry = if (facts.phase == .construction_initialization) .initialization else .ordinary;
                if (reference.entry != expected) return error.InvalidDispatchOwnership;
                try owner.validate(try validatedProgramContent(entry, facts.contents));
                found = true;
                break;
            }
        }
        if (!found) return error.UnknownDispatchOwner;
    }
}

fn blocked(reason: Reason, entity: ?population.Entity, reference: ?QualifiedReference) Decision {
    return .{
        .kind = .blocked,
        .source_entity_id = if (entity) |value| value.id else null,
        .source_order = if (entity) |value| value.source_order else null,
        .program = reference,
        .reason = reason,
    };
}

fn selected(kind: DecisionKind, entity: population.Entity, reference: QualifiedReference, next_cursor: ?u8) Decision {
    return .{
        .kind = kind,
        .source_entity_id = entity.id,
        .source_order = entity.source_order,
        .program = reference,
        .next_initialization_cursor = next_cursor,
        .action = if (kind == .selected_initialization) .pump_once_and_advance else .start_event_owner,
    };
}

fn ownerDecision(kind: DecisionKind, entry: Entry, reason: ?Reason) Decision {
    return .{
        .kind = kind,
        .source_entity_id = entry.source_entity_id,
        .source_order = entry.source_order,
        .program = entry.program,
        .reason = reason,
        .action = if (kind == .continue_current_instance) .continue_event_frame else .none,
    };
}

fn ownerEntry(scene: Scene, owner: *const event_runtime.Instance) !Entry {
    for (scene.entries) |entry| {
        if (entry.status != .executable) continue;
        const reference = entry.program.?;
        if (std.mem.eql(u8, owner.content_id, reference.content_id) and
            std.mem.eql(u8, owner.content_sha256, reference.content_sha256) and
            std.mem.eql(u8, owner.program_id, reference.program_id)) return entry;
    }
    return error.UnknownDispatchOwner;
}

fn eligible(entity: population.Entity, facts: Facts) ?Reason {
    if (entity.event_selection.pointer_state == .null) return .no_ordinary_match;
    for (entity.event_selection.terms, 0..) |term, index| {
        const matched = population.eventTermMatches(term, facts.story, facts.interaction_entity == entity.source_order, facts.field_cell) orelse blk: {
            if (term.kind != .unsupported) return .unsupported_predicate;
            if (facts.term_resolver) |resolver| {
                break :blk resolver.resolve_fn(resolver.context, entity.source_order, index, term.semantics.?) orelse return .unsupported_predicate;
            }
            if (facts.unsupported_terms == .unsupported) return .unsupported_predicate;
            break :blk false;
        };
        if (!matched) return .no_ordinary_match;
    }
    return null;
}

fn select(scene: Scene, pop: population.Packet, facts: Facts, initialization: bool) !Decision {
    for (pop.entities) |entity| {
        const is_initialization = entity.record_role == .initialization;
        if (is_initialization != initialization) continue;
        if (initialization and entity.initialization_order.? < facts.initialization_cursor) continue;
        if (eligible(entity, facts)) |reason| {
            if (reason == .unsupported_predicate) return blocked(reason, entity, null);
            continue;
        }
        const binding = scene.entry(entity.source_order) orelse return blocked(.program_not_compiled, entity, null);
        if (binding.status == .blocked_unsupported) return blocked(binding.blocker.?.reason, entity, null);
        _ = try validatedProgramContent(binding, facts.contents);
        return selected(if (initialization) .selected_initialization else .selected_ordinary, entity, binding.program.?, if (initialization) entity.initialization_order.? + 1 else null);
    }
    return .{
        .kind = .no_candidate,
        .reason = if (initialization) .initialization_complete else .no_ordinary_match,
        .next_initialization_cursor = if (initialization) scene.initialization_count else facts.initialization_cursor,
        .action = if (initialization) .finish_initialization else .none,
    };
}

pub fn plan(packet: Packet, scene_id: []const u8, pop: population.Packet, facts: Facts) !Decision {
    try validate(packet);
    try population.validate(pop);
    const scene = packet.scene(scene_id) orelse return error.UnknownDispatchScene;
    try validateScene(scene, pop);
    try validateFacts(scene, facts);
    switch (facts.phase) {
        .construction_initialization => return select(scene, pop, facts, true),
        .free_selection => {
            if (facts.owner) |owner| if (owner.execution.active) {
                return ownerDecision(.blocked, try ownerEntry(scene, owner), .active_instance);
            };
            switch (facts.locks.free_gate) {
                .blocked => return blocked(.caller_gate, null, null),
                .unsupported => return error.UnsupportedDispatchDependency,
                .clear => {},
            }
            return select(scene, pop, facts, false);
        },
        .event_frame => {
            const owner = facts.owner orelse return error.InvalidDispatchOwnership;
            const entry = try ownerEntry(scene, owner);
            if (!owner.execution.active) {
                // FD clears the VM owner, but the original child waits for its
                // post-frame completion signal and pending area callback too.
                switch (facts.locks.completion_gate) {
                    .blocked => return ownerDecision(.wait_current_instance, entry, .completion_gate),
                    .unsupported => return error.UnsupportedDispatchDependency,
                    .clear => {},
                }
                return .{
                    .kind = .no_candidate,
                    .reason = .completed_return_to_free_selection,
                    .next_initialization_cursor = facts.initialization_cursor,
                    .action = .rearm_free_selection,
                };
            }
            switch (facts.locks.vm_gate) {
                .text_blocked => return ownerDecision(.wait_current_instance, entry, .vm_gate),
                .unsupported => return error.UnsupportedDispatchDependency,
                .clear => {},
            }
            if (owner.execution.wait) |wait| {
                if (wait.kind == .event_flags_low2 and facts.locks.event_flags_low2 != 0)
                    return ownerDecision(.wait_current_instance, entry, .event_flags_low2);
            }
            return ownerDecision(.continue_current_instance, entry, null);
        },
        .area_49c_callback, .area_498_callback, .menu => return error.UnsupportedDispatchPhase,
    }
}

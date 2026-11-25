//! Event admission/completion production for the existing field Session.
//!
//! The module owns no scheduler: `observe` is called once at the source caller
//! with the raw frame fields and the canonical owner instance. It produces the
//! phase, free/VM gates, a single `scene_dispatch.plan` decision and the
//! completion fact. It exposes no acknowledgement, callback invocation or VM
//! step; those stay with the canonical `field_events.Session`.

const std = @import("std");
const runtime = @import("event_runtime");
const dispatch = @import("scene_dispatch");
const population = @import("scene_population");
const source = @import("source.zig");

pub const schema = "suikoden-event-host/1";
pub const snapshot_schema = "suikoden-event-host-snapshot/1";
pub const version = "event-admission.1";
pub const max_initializers = 8;

pub const OwnerReceipt = struct { batch: u64 };

pub const OwnerView = struct {
    /// The canonical owner, borrowed. The host never copies execution state.
    instance: *const runtime.Instance,
    serial: u64,
    receipt: ?OwnerReceipt = null,
};

pub const OwnerState = enum { active, settled, completed };

pub const OwnerHistory = struct {
    serial: u64,
    reference: dispatch.QualifiedReference,
    effect_sequence: u64,
    receipt_batch: ?u64 = null,
    state: OwnerState,
};

pub const Selection = struct {
    reference: dispatch.QualifiedReference,
    frame: u64,
    prior_serial: u64,
};

pub const CompletionReceipt = struct {
    serial: u64,
    reference: dispatch.QualifiedReference,
    effect_sequence: u64,
    batch: u64,
    frame: u64,
};

pub const Completion = union(enum) {
    not_applicable,
    active,
    awaiting_ack: u64,
    awaiting_source_gate,
    awaiting_receipt,
    unknown_callback_498,
    unknown_callback_49c,
    proposed: CompletionReceipt,
};

pub const Reason = enum {
    menu,
    free_reservation,
    encounter_reservation,
    alternate_mode,
    encounter_claim,
    unproven_encounter_gate,
    construction_same_pass,
    completion_same_pass,
    live_event_owner,
    active_without_event_child,
    transition_driver,
    unknown_driver,
    awaiting_ack,
    awaiting_receipt,
    completed_return_to_free_selection,
    initialization_complete,
    no_ordinary_match,
    program_not_compiled,
    room_coordinate_transition,
    unsupported_predicate,
    active_instance,
    caller_gate,
    vm_gate,
    event_flags_low2,
    completion_gate,
};

pub const Action = enum {
    none,
    pump_initializer,
    finish_initialization,
    start_event_owner,
    continue_event_frame,
    wait_current_instance,
    rearm_free_selection,
    denied,
    blocked,
};

pub const Result = struct {
    phase: source.Phase,
    gate: source.FreeGate = .clear,
    vm_gate: source.VmGate = .clear,
    vm_reason: ?source.VmReason = null,
    completion: Completion = .not_applicable,
    admitted: bool = false,
    action: Action = .none,
    decision: ?dispatch.Decision = null,
    reason: ?Reason = null,
    cursor: u8 = 0,
    construction_done: bool = false,
    free_ready: bool = false,
    owner_serial: ?u64 = null,
    owner_state: ?OwnerState = null,

    pub fn decisionKind(self: Result) ?[]const u8 {
        return if (self.decision) |decision| @tagName(decision.kind) else null;
    }
    pub fn sourceOrder(self: Result) ?u8 {
        return if (self.decision) |decision| decision.source_order else null;
    }
    pub fn programId(self: Result) ?[]const u8 {
        const decision = self.decision orelse return null;
        const reference = decision.program orelse return null;
        return reference.program_id;
    }
    pub fn completionTag(self: Result) []const u8 {
        return @tagName(std.meta.activeTag(self.completion));
    }
    pub fn completionBatch(self: Result) ?u64 {
        return switch (self.completion) {
            .awaiting_ack => |batch| batch,
            .proposed => |receipt| receipt.batch,
            else => null,
        };
    }
};

pub const Binding = struct {
    packet: *const dispatch.Packet,
    population: *const population.Packet,
    contents: []const runtime.Content,
    scene_id: []const u8,
    story: *const runtime.StoryState,
    /// Proven position/up facts for source predicate terms. When absent, the
    /// planner blocks an unsupported term instead of treating it as false.
    predicates: ?*const source.Predicates = null,
};

fn freeReason(value: source.FreeReason) Reason {
    return switch (value) {
        .menu => .menu,
        .free_reservation => .free_reservation,
        .encounter_reservation => .encounter_reservation,
        .alternate_mode => .alternate_mode,
        .encounter_claim => .encounter_claim,
        .unproven_encounter_gate => .unproven_encounter_gate,
    };
}

fn reasonOf(value: dispatch.Reason) Reason {
    return switch (value) {
        .initialization_complete => .initialization_complete,
        .no_ordinary_match => .no_ordinary_match,
        .completed_return_to_free_selection => .completed_return_to_free_selection,
        .program_not_compiled => .program_not_compiled,
        .room_coordinate_transition => .room_coordinate_transition,
        .unsupported_predicate => .unsupported_predicate,
        .active_instance => .active_instance,
        .caller_gate => .caller_gate,
        .vm_gate => .vm_gate,
        .event_flags_low2 => .event_flags_low2,
        .completion_gate => .completion_gate,
    };
}

fn findContent(binding: Binding, content_id: []const u8, content_sha256: []const u8) !runtime.Content {
    for (binding.contents) |content| {
        if (std.mem.eql(u8, content.id, content_id) and
            std.mem.eql(u8, content.content_sha256, content_sha256)) return content;
    }
    return error.MissingOwnerContent;
}

fn ownerReference(binding: Binding, instance: *const runtime.Instance) !dispatch.QualifiedReference {
    const scene = binding.packet.scene(binding.scene_id) orelse return error.UnknownDispatchScene;
    for (scene.entries) |entry| {
        if (entry.status != .executable or entry.phase != .ordinary) continue;
        const reference = entry.program.?;
        if (std.mem.eql(u8, instance.content_id, reference.content_id) and
            std.mem.eql(u8, instance.content_sha256, reference.content_sha256) and
            std.mem.eql(u8, instance.program_id, reference.program_id)) return reference;
    }
    return error.UnknownOwnerIdentity;
}

fn validateOwner(binding: Binding, owner: OwnerView) !dispatch.QualifiedReference {
    if (owner.serial == 0) return error.InvalidOwnerSerial;
    const reference = try ownerReference(binding, owner.instance);
    const content = try findContent(binding, reference.content_id, reference.content_sha256);
    try owner.instance.validate(content);
    return reference;
}

pub const Host = struct {
    scene_id: []const u8,
    admission_content_sha256: []const u8,
    cursor: u8 = 0,
    construction_done: bool = false,
    last_frame: ?u64 = null,
    construction_frame: ?u64 = null,
    completion_frame: ?u64 = null,
    owner: ?OwnerHistory = null,
    selection: ?Selection = null,
    last_completion: ?CompletionReceipt = null,

    pub fn init(binding: Binding) !Host {
        try dispatch.validate(binding.packet.*);
        try population.validate(binding.population.*);
        const scene = binding.packet.scene(binding.scene_id) orelse return error.UnknownDispatchScene;
        if (!std.mem.eql(u8, scene.population.content_id, binding.population.id) or
            !std.mem.eql(u8, scene.population.content_sha256, binding.population.content_sha256))
            return error.StaleDispatchPopulation;
        if (scene.initialization_count == 0 or scene.initialization_count > max_initializers)
            return error.InvalidDispatchInitialization;
        if (!std.mem.eql(u8, binding.story.schema, "suikoden-event-story/1"))
            return error.InvalidStorySchema;
        return .{ .scene_id = scene.id, .admission_content_sha256 = binding.packet.content_sha256 };
    }

    pub fn ownerState(self: *const Host) ?OwnerState {
        return if (self.owner) |owner| owner.state else null;
    }

    pub fn freeReady(self: *const Host, index: u64) bool {
        if (!self.construction_done) return false;
        if (self.construction_frame) |frame| if (index <= frame) return false;
        if (self.completion_frame) |frame| if (index <= frame) return false;
        return true;
    }

    fn baseResult(self: *const Host, frame: source.Frame, phase: source.Phase) Result {
        return .{
            .phase = phase,
            .cursor = self.cursor,
            .construction_done = self.construction_done,
            .free_ready = self.freeReady(frame.index),
            .owner_serial = if (self.owner) |owner| owner.serial else null,
            .owner_state = self.ownerState(),
        };
    }

    fn finish(self: *const Host, result: *Result, frame: source.Frame) Result {
        result.cursor = self.cursor;
        result.construction_done = self.construction_done;
        result.free_ready = self.freeReady(frame.index);
        result.owner_serial = if (self.owner) |owner| owner.serial else null;
        result.owner_state = self.ownerState();
        return result.*;
    }

    fn deny(self: *const Host, frame: source.Frame, result: *Result, reason: Reason) Result {
        result.action = .denied;
        result.reason = reason;
        return self.finish(result, frame);
    }

    fn buildFacts(
        self: *const Host,
        binding: Binding,
        frame: source.Frame,
        phase: dispatch.CallerPhase,
        owner: ?*const runtime.Instance,
        locks: dispatch.Locks,
    ) !dispatch.Facts {
        const scene = binding.packet.scene(binding.scene_id) orelse return error.UnknownDispatchScene;
        const constructing = phase == .construction_initialization;
        var result: dispatch.Facts = .{
            .phase = phase,
            .story = binding.story,
            .construction = .{
                .scene_id = scene.id,
                .phase = if (constructing) .constructing else .active,
                .population = scene.population,
                .bundle = scene.bundle,
                .story = binding.story,
            },
            .initialization_cursor = self.cursor,
            .contents = binding.contents,
            .owner = owner,
            .locks = locks,
            .interaction_entity = frame.interaction_entity,
            .unsupported_terms = .unsupported,
        };
        if (binding.predicates) |predicates| {
            try source.validatePredicates(predicates.*);
            result.term_resolver = .{ .context = @ptrCast(predicates), .resolve_fn = source.resolve };
        }
        return result;
    }

    pub fn observe(self: *Host, binding: Binding, frame: source.Frame, owner: ?OwnerView) !Result {
        if (self.last_frame) |last| if (frame.index < last) return error.StaleFrame;
        self.last_frame = frame.index;
        const fact = source.phase(frame, self.construction_done);
        var result = self.baseResult(frame, fact.phase);
        switch (fact.phase) {
            .menu => {
                result.reason = .menu;
                return self.finish(&result, frame);
            },
            .transition => {
                result.reason = .transition_driver;
                return self.finish(&result, frame);
            },
            .unsupported => {
                result.reason = if (fact.basis == .active_without_event_child)
                    .active_without_event_child
                else
                    .unknown_driver;
                return self.finish(&result, frame);
            },
            .construction_initialization => return self.observeConstruction(binding, frame, &result),
            .free_selection => return self.observeFree(binding, frame, owner, &result),
            .event_frame => return self.observeEvent(binding, frame, owner, &result),
        }
    }

    fn observeConstruction(self: *Host, binding: Binding, frame: source.Frame, result: *Result) !Result {
        const scene = binding.packet.scene(binding.scene_id) orelse return error.UnknownDispatchScene;
        const facts = try self.buildFacts(binding, frame, .construction_initialization, null, .{
            .free_gate = .clear,
            .vm_gate = .clear,
            .completion_gate = .clear,
        });
        const decision = try dispatch.plan(binding.packet.*, self.scene_id, binding.population.*, facts);
        result.decision = decision;
        switch (decision.kind) {
            .selected_initialization => {
                const next = decision.next_initialization_cursor orelse return error.InvalidDispatchDecision;
                if (next <= self.cursor or next > scene.initialization_count) return error.InvalidDispatchDecision;
                self.cursor = next;
                result.admitted = true;
                result.action = .pump_initializer;
            },
            .blocked => {
                result.reason = reasonOf(decision.reason orelse return error.InvalidDispatchDecision);
                result.action = .blocked;
            },
            .no_candidate => {
                if (decision.reason != .initialization_complete) return error.InvalidDispatchDecision;
                result.reason = .initialization_complete;
                const next = decision.next_initialization_cursor orelse return error.InvalidDispatchDecision;
                if (next != scene.initialization_count) return error.InvalidDispatchDecision;
                self.cursor = next;
                self.construction_done = true;
                self.construction_frame = frame.index;
                result.admitted = true;
                result.action = .finish_initialization;
            },
            else => return error.InvalidDispatchDecision,
        }
        return self.finish(result, frame);
    }

    fn observeFree(self: *Host, binding: Binding, frame: source.Frame, owner: ?OwnerView, result: *Result) !Result {
        if (owner != null) {
            if (self.owner == null or self.owner.?.state == .active)
                return self.deny(frame, result, .live_event_owner);
        }
        if (self.selection != null and owner == null) return error.SelectionNotAdopted;
        if (self.construction_frame) |value| if (frame.index == value)
            return self.deny(frame, result, .construction_same_pass);
        if (self.completion_frame) |value| if (frame.index == value)
            return self.deny(frame, result, .completion_same_pass);
        if (self.owner) |history| if (history.state == .active)
            return self.deny(frame, result, .live_event_owner);
        const gate = source.freeGate(frame);
        result.gate = gate.gate;
        if (gate.gate != .clear) return self.deny(frame, result, freeReason(gate.reason.?));
        const facts = try self.buildFacts(binding, frame, .free_selection, null, .{
            .free_gate = .clear,
            .vm_gate = .clear,
            .completion_gate = .clear,
        });
        const decision = try dispatch.plan(binding.packet.*, self.scene_id, binding.population.*, facts);
        result.decision = decision;
        switch (decision.kind) {
            .selected_ordinary => {
                const reference = decision.program orelse return error.InvalidDispatchDecision;
                self.selection = .{
                    .reference = reference,
                    .frame = frame.index,
                    .prior_serial = if (self.owner) |history| history.serial else 0,
                };
                result.admitted = true;
                result.action = .start_event_owner;
            },
            .blocked => {
                result.reason = reasonOf(decision.reason orelse return error.InvalidDispatchDecision);
                result.action = .blocked;
            },
            .no_candidate => {
                result.reason = reasonOf(decision.reason orelse return error.InvalidDispatchDecision);
            },
            else => return error.InvalidDispatchDecision,
        }
        return self.finish(result, frame);
    }

    fn observeEvent(self: *Host, binding: Binding, frame: source.Frame, owner: ?OwnerView, result: *Result) !Result {
        const view = owner orelse return error.MissingOwner;
        const reference = try validateOwner(binding, view);
        const previous = self.owner;
        if (self.selection) |selection| {
            if (!selection.reference.eql(reference) or view.serial <= selection.prior_serial)
                return error.OwnerRebindMismatch;
            self.selection = null;
        } else if (previous) |history| {
            if (history.state == .completed) {
                if (view.serial == history.serial and history.reference.eql(reference))
                    return error.OwnerAlreadyCompleted;
                if (view.serial <= history.serial) return error.OwnerRebindMismatch;
            } else if (view.serial != history.serial or !history.reference.eql(reference)) {
                return error.OwnerRebindMismatch;
            }
        }
        var history: OwnerHistory = .{
            .serial = view.serial,
            .reference = reference,
            .effect_sequence = view.instance.effect_sequence,
            .receipt_batch = if (view.receipt) |receipt| receipt.batch else null,
            .state = if (view.instance.execution.active) .active else .settled,
        };
        if (view.instance.pending != null) {
            self.owner = history;
            result.completion = .{ .awaiting_ack = view.instance.pending.?.batch.id };
            result.reason = .awaiting_ack;
            return self.finish(result, frame);
        }
        const gate = source.vmGate(frame);
        result.vm_gate = gate.gate;
        result.vm_reason = gate.reason;
        if (view.instance.execution.active) {
            const facts = try self.buildFacts(binding, frame, .event_frame, view.instance, .{
                .free_gate = .clear,
                .vm_gate = if (gate.gate == .clear) .clear else .text_blocked,
                .completion_gate = .clear,
                .event_flags_low2 = frame.event_flags_low2,
            });
            const decision = try dispatch.plan(binding.packet.*, self.scene_id, binding.population.*, facts);
            result.decision = decision;
            result.completion = .active;
            switch (decision.kind) {
                .continue_current_instance => {
                    result.admitted = true;
                    result.action = .continue_event_frame;
                },
                .wait_current_instance => {
                    result.reason = reasonOf(decision.reason orelse return error.InvalidDispatchDecision);
                    result.action = .wait_current_instance;
                },
                else => return error.InvalidDispatchDecision,
            }
            self.owner = history;
            return self.finish(result, frame);
        }

        // Inactive owner: the driver's completion production. No callback is
        // ever called or acknowledged here.
        const unknown_callback: ?Completion = if (frame.callbacks.area_49c != .none)
            .unknown_callback_49c
        else if (frame.callbacks.area_498 != .none)
            .unknown_callback_498
        else
            null;
        const completion_blocked = unknown_callback != null or frame.completion_flag != 1 or
            frame.event_active != 0 or history.receipt_batch == null;
        const facts = try self.buildFacts(binding, frame, .event_frame, view.instance, .{
            .free_gate = .clear,
            .vm_gate = .clear,
            .completion_gate = if (completion_blocked) .blocked else .clear,
        });
        const decision = try dispatch.plan(binding.packet.*, self.scene_id, binding.population.*, facts);
        result.decision = decision;
        if (unknown_callback) |completion| {
            result.completion = completion;
            result.action = .wait_current_instance;
            result.reason = .completion_gate;
            self.owner = history;
            return self.finish(result, frame);
        }
        if (frame.completion_flag != 1 or frame.event_active != 0) {
            result.completion = .awaiting_source_gate;
            result.action = .wait_current_instance;
            result.reason = .completion_gate;
            self.owner = history;
            return self.finish(result, frame);
        }
        if (history.receipt_batch == null) {
            result.completion = .awaiting_receipt;
            result.action = .wait_current_instance;
            result.reason = .completion_gate;
            self.owner = history;
            return self.finish(result, frame);
        }
        if (decision.kind != .no_candidate or decision.reason != .completed_return_to_free_selection)
            return error.InvalidDispatchDecision;
        const receipt: CompletionReceipt = .{
            .serial = history.serial,
            .reference = history.reference,
            .effect_sequence = history.effect_sequence,
            .batch = history.receipt_batch.?,
            .frame = frame.index,
        };
        self.completion_frame = frame.index;
        self.last_completion = receipt;
        history.state = .completed;
        history.receipt_batch = null;
        self.owner = history;
        result.completion = .{ .proposed = receipt };
        result.action = .rearm_free_selection;
        result.reason = .completed_return_to_free_selection;
        return self.finish(result, frame);
    }

    // -----------------------------------------------------------------------
    // Durable envelope
    // -----------------------------------------------------------------------

    pub const OwnerSnapshot = struct {
        content_id: []const u8,
        content_sha256: []const u8,
        program_id: []const u8,
        serial: u64,
        effect_sequence: u64,
        receipt_batch: ?u64 = null,
        state: OwnerState,
    };
    pub const SelectionSnapshot = struct {
        content_id: []const u8,
        content_sha256: []const u8,
        program_id: []const u8,
        frame: u64,
        prior_serial: u64,
    };
    pub const CompletionSnapshot = struct {
        serial: u64,
        content_id: []const u8,
        content_sha256: []const u8,
        program_id: []const u8,
        effect_sequence: u64,
        batch: u64,
        frame: u64,
    };
    pub const Snapshot = struct {
        schema: []const u8,
        version: []const u8,
        scene_id: []const u8,
        admission_content_sha256: []const u8,
        cursor: u8,
        construction_done: bool,
        last_frame: ?u64 = null,
        construction_frame: ?u64 = null,
        completion_frame: ?u64 = null,
        owner: ?OwnerSnapshot = null,
        selection: ?SelectionSnapshot = null,
        last_completion: ?CompletionSnapshot = null,
    };

    fn ownerSnapshot(value: OwnerHistory) OwnerSnapshot {
        return .{
            .content_id = value.reference.content_id,
            .content_sha256 = value.reference.content_sha256,
            .program_id = value.reference.program_id,
            .serial = value.serial,
            .effect_sequence = value.effect_sequence,
            .receipt_batch = value.receipt_batch,
            .state = value.state,
        };
    }
    fn selectionSnapshot(value: Selection) SelectionSnapshot {
        return .{
            .content_id = value.reference.content_id,
            .content_sha256 = value.reference.content_sha256,
            .program_id = value.reference.program_id,
            .frame = value.frame,
            .prior_serial = value.prior_serial,
        };
    }
    fn completionSnapshot(value: CompletionReceipt) CompletionSnapshot {
        return .{
            .serial = value.serial,
            .content_id = value.reference.content_id,
            .content_sha256 = value.reference.content_sha256,
            .program_id = value.reference.program_id,
            .effect_sequence = value.effect_sequence,
            .batch = value.batch,
            .frame = value.frame,
        };
    }

    pub fn snapshot(self: *const Host) Snapshot {
        return .{
            .schema = snapshot_schema,
            .version = version,
            .scene_id = self.scene_id,
            .admission_content_sha256 = self.admission_content_sha256,
            .cursor = self.cursor,
            .construction_done = self.construction_done,
            .last_frame = self.last_frame,
            .construction_frame = self.construction_frame,
            .completion_frame = self.completion_frame,
            .owner = if (self.owner) |value| ownerSnapshot(value) else null,
            .selection = if (self.selection) |value| selectionSnapshot(value) else null,
            .last_completion = if (self.last_completion) |value| completionSnapshot(value) else null,
        };
    }

    pub fn save(self: *const Host, allocator: std.mem.Allocator) ![]u8 {
        return std.json.Stringify.valueAlloc(allocator, self.snapshot(), .{});
    }

    pub fn referenceFromSnapshot(
        binding: Binding,
        content_id: []const u8,
        content_sha256: []const u8,
        program_id: []const u8,
        entry: dispatch.ExecutionEntry,
    ) !dispatch.QualifiedReference {
        const scene = binding.packet.scene(binding.scene_id) orelse return error.UnknownDispatchScene;
        for (scene.entries) |candidate| {
            if (candidate.status != .executable or candidate.phase != entry) continue;
            const reference = candidate.program.?;
            if (std.mem.eql(u8, reference.content_id, content_id) and
                std.mem.eql(u8, reference.content_sha256, content_sha256) and
                std.mem.eql(u8, reference.program_id, program_id)) return reference;
        }
        return error.UnknownOwnerIdentity;
    }

    pub fn restoreSnapshot(value: Snapshot, binding: Binding) !Host {
        if (!std.mem.eql(u8, value.schema, snapshot_schema) or !std.mem.eql(u8, value.version, version))
            return error.InvalidSnapshot;
        try dispatch.validate(binding.packet.*);
        try population.validate(binding.population.*);
        const scene = binding.packet.scene(binding.scene_id) orelse return error.UnknownDispatchScene;
        if (!std.mem.eql(u8, value.scene_id, scene.id) or
            !std.mem.eql(u8, value.admission_content_sha256, binding.packet.content_sha256))
            return error.StaleSnapshot;
        if (value.cursor > scene.initialization_count) return error.InvalidSnapshot;
        if (value.construction_done) {
            if (value.cursor != scene.initialization_count) return error.InvalidSnapshot;
        } else if (value.cursor == scene.initialization_count) {
            return error.InvalidSnapshot;
        }
        if (value.last_frame) |last| {
            if (value.construction_frame) |frame| if (frame > last) return error.InvalidSnapshot;
            if (value.completion_frame) |frame| if (frame > last) return error.InvalidSnapshot;
        } else {
            if (value.construction_frame != null or value.completion_frame != null)
                return error.InvalidSnapshot;
        }
        var result: Host = .{
            .scene_id = scene.id,
            .admission_content_sha256 = binding.packet.content_sha256,
            .cursor = value.cursor,
            .construction_done = value.construction_done,
            .last_frame = value.last_frame,
            .construction_frame = value.construction_frame,
            .completion_frame = value.completion_frame,
        };
        if (value.owner) |owner| {
            if (owner.serial == 0) return error.InvalidSnapshot;
            result.owner = .{
                .serial = owner.serial,
                .reference = try referenceFromSnapshot(binding, owner.content_id, owner.content_sha256, owner.program_id, .ordinary),
                .effect_sequence = owner.effect_sequence,
                .receipt_batch = owner.receipt_batch,
                .state = owner.state,
            };
        }
        if (value.selection) |selection| {
            const reference = try referenceFromSnapshot(binding, selection.content_id, selection.content_sha256, selection.program_id, .ordinary);
            if (selection.frame > (value.last_frame orelse 0)) return error.InvalidSnapshot;
            result.selection = .{
                .reference = reference,
                .frame = selection.frame,
                .prior_serial = selection.prior_serial,
            };
        }
        if (value.last_completion) |completion| {
            if (completion.batch == 0 or completion.serial == 0) return error.InvalidSnapshot;
            if (completion.frame > (value.last_frame orelse 0)) return error.InvalidSnapshot;
            result.last_completion = .{
                .serial = completion.serial,
                .reference = try referenceFromSnapshot(binding, completion.content_id, completion.content_sha256, completion.program_id, .ordinary),
                .effect_sequence = completion.effect_sequence,
                .batch = completion.batch,
                .frame = completion.frame,
            };
        }
        if (result.owner) |owner| {
            if (owner.state == .completed and result.last_completion == null) return error.InvalidSnapshot;
        }
        return result;
    }

    pub fn restore(allocator: std.mem.Allocator, bytes: []const u8, binding: Binding) !Host {
        const parsed = std.json.parseFromSlice(Snapshot, allocator, bytes, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidSnapshot,
        };
        defer parsed.deinit();
        return restoreSnapshot(parsed.value, binding);
    }
};

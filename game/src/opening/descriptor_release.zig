//! Source-qualified descriptor writes and terminal off-map handoff for VA1 room 2 entity 2.
//! This records source results; the field host owns the actor and primary animation clock.
const std = @import("std");
const movement_batch = @import("movement_batch");

const source_moves = [_]u32{ 0x3d17c, 0x3d181, 0x3d19f };
const max_movement_steps = 100;

pub const source_sha256 = "dcca6119f28f3863250f31be8cd164d4795eaa493aeec5b51ca0737690979fed";

pub const Binding = struct {
    scene: []const u8,
    event_id: []const u8,
    event_sha256: []const u8,
    program: []const u8,
    actor_id: []const u8,
    resource: []const u8,
    graphic: []const u8,
    entity: u8,
    entity_record_offset: u32 = 0x3d7c8,
    source_character_id: u8 = 0x6c,
    slot: u8,
    selector: u8,
    /// Tile entry 0 is built from VA1 room2 packed scenery row 0: source +3
    /// (VA1.BIN+0x6e2b) is copied into runtime entry +2.
    tile_entry_index: u16 = 0,
    tile_entry_source_offset: u32 = 0x6e28,
    tile_entry_zero_plus2: u8 = 0xe0,
    /// Command indices resolved from the retained source map: x, y, move A, move B, mode 0, move C, release.
    command_indices: [7]u16,

    pub fn validate(self: Binding) !void {
        if (!std.mem.eql(u8, self.scene, "va1_room2") or
            !std.mem.eql(u8, self.event_id, "va1_room2_field_events") or
            self.event_sha256.len != 64 or
            !std.mem.eql(u8, self.program, "va1_r02_e02_ordinary") or
            !std.mem.eql(u8, self.actor_id, "scene_actor_0") or
            !std.mem.eql(u8, self.resource, "va1_room2_character_108") or
            !std.mem.eql(u8, self.graphic, "va1_room2_graphic_108") or
            self.entity != 2 or self.entity_record_offset != 0x3d7c8 or self.source_character_id != 0x6c or
            self.slot != 0 or self.selector != 0 or
            self.tile_entry_index != 0 or self.tile_entry_source_offset != 0x6e28 or self.tile_entry_zero_plus2 != 0xe0) return error.InvalidDescriptorBinding;
        for (self.command_indices, 0..) |index, i| if (i != 0 and index <= self.command_indices[i - 1]) return error.InvalidDescriptorBinding;
    }
};

pub const Operation = enum { x, y, mode0, release };
pub const Receipt = struct {
    event_id: []const u8,
    event_sha256: []const u8,
    program: []const u8,
    instance: u64,
    batch: u64,
    command_index: u16,
    source_file: []const u8,
    source_sha256: []const u8,
    entity: u8,
    selector: u8,
    source_offset: u32,
    opcode: [2]u8,
    value: u8,
    operation: Operation,
};

pub const Child = struct {
    resource: []const u8,
    graphic: []const u8,
    attached: bool = true,
};

pub const Entry = struct {
    operation: Operation,
    instance: u64,
    batch: u64,
    command_index: u16,
    source_offset: u32,
    descriptor_16_result: ?u8 = null,
};

pub const ActorMotion = struct {
    x: i32,
    y: i32,
    offset_x: i16 = 0,
    offset_y: i16 = 0,
    speed: u8,
};

pub const SourceCommand = struct {
    event_id: []const u8,
    event_sha256: []const u8,
    program: []const u8,
    instance: u64,
    batch: u64,
    command_index: u16,
    source_file: []const u8,
    source_sha256: []const u8,
    source_offset: u32,
    opcode: u8 = 0x06,
    entity: u8 = 2,
    selector: u8,
    parameter: u8,
    repetitions: u8,
    direction: u2,
};

/// Actual actor snapshots carried with each retained movement-owner proposal.
/// The source Session must independently replay collision and motion before commit.
pub const MovementStep = struct {
    source_offset: u32,
    command_index: u16,
    event_instance: u64,
    event_batch: u64,
    proposal: movement_batch.Proposal,
    before: ActorMotion,
    after: ActorMotion,
    command: ?SourceCommand = null,
};

pub const State = struct {
    event_sha256: []const u8,
    child: Child,
    x: u8 = 254,
    y: u8 = 254,
    descriptor_5: u8 = 0,
    descriptor_16_copy_calls: u2 = 0,
    descriptor_16_result: ?u8 = null,
    /// This bound scene's on-map visibility, not the graphics child's draw-flag byte.
    draw_enabled: bool = true,
    released: bool = false,
    instance: u64 = 0,
    last_batch: u64 = 0,
    last_event_batch: u64 = 0,
    last_command_index: u16 = 0,
    history: [4]?Entry = @splat(null),
    history_len: u3 = 0,
    movement_owner: movement_batch.State = .{},
    movement_steps: [max_movement_steps]?MovementStep = @splat(null),
    movement_len: u7 = 0,
    actor_motion: ?ActorMotion = null,

    pub fn init(binding: Binding) !State {
        try binding.validate();
        return .{
            .event_sha256 = binding.event_sha256,
            .child = .{ .resource = binding.resource, .graphic = binding.graphic },
        };
    }

    pub fn validate(self: State, binding: Binding) !void {
        try binding.validate();
        if (!std.mem.eql(u8, self.event_sha256, binding.event_sha256) or
            !std.mem.eql(u8, self.child.resource, binding.resource) or
            !std.mem.eql(u8, self.child.graphic, binding.graphic) or
            !self.child.attached or self.history_len > self.history.len or
            self.movement_len > self.movement_steps.len or
            (self.instance == 0) != (self.history_len == 0) or
            self.released != !self.draw_enabled) return error.InvalidDescriptorState;
        if ((self.history_len == 0 and (self.x != 254 or self.y != 254 or self.descriptor_16_copy_calls != 0 or self.descriptor_16_result != null or self.descriptor_5 != 0)) or
            (self.history_len == 1 and (self.x != 0x23 or self.y != 254 or self.descriptor_16_copy_calls != 1 or self.descriptor_16_result == null)) or
            ((self.history_len == 2 or self.history_len == 3) and (self.x != 0x23 or self.y != 0x10 or self.descriptor_16_copy_calls != 2 or self.descriptor_16_result == null)) or
            (self.history_len == 4 and (self.x != 254 or self.y != 254 or self.descriptor_16_copy_calls != 2 or self.descriptor_16_result == null or self.descriptor_5 != 0)) or
            (self.history_len < 4 and self.released) or
            (self.released and (self.x != 254 or self.y != 254 or self.descriptor_5 != 0 or self.history_len != 4))) return error.InvalidDescriptorState;
        const expected_operations = [_]Operation{ .x, .y, .mode0, .release };
        for (self.history[0..self.history_len], 0..) |entry_opt, i| {
            const entry = entry_opt orelse return error.InvalidDescriptorState;
            if (entry.operation != expected_operations[i] or entry.instance == 0 or entry.batch == 0 or
                entry.source_offset != sourceOffset(entry.operation) or entry.command_index != binding.command_indices[commandSlot(entry.operation)]) return error.InvalidDescriptorState;
            const expected_field_copy = switch (entry.operation) {
                .x => fieldCopyResult(254, binding.tile_entry_zero_plus2),
                .y => fieldCopyResult(0x10, binding.tile_entry_zero_plus2),
                .mode0, .release => null,
            };
            if (!std.meta.eql(entry.descriptor_16_result, expected_field_copy)) return error.InvalidDescriptorState;
            if (i != 0) {
                const prior = self.history[i - 1].?;
                if (entry.instance != prior.instance or entry.batch < prior.batch or entry.command_index <= prior.command_index) return error.InvalidDescriptorState;
            }
        }
        for (self.history[self.history_len..]) |entry| if (entry != null) return error.InvalidDescriptorState;
        const latest_copy = if (self.history_len >= 2) self.history[1].?.descriptor_16_result else if (self.history_len == 1) self.history[0].?.descriptor_16_result else null;
        if (!std.meta.eql(self.descriptor_16_result, latest_copy)) return error.InvalidDescriptorState;
        if (self.history_len > 0 and (self.history[self.history_len - 1].?.batch != self.last_batch or
            self.history[self.history_len - 1].?.command_index != self.last_command_index)) return error.InvalidDescriptorState;
        try validateMovement(self, binding);
        var seen: [7]bool = @splat(false);
        var source_batches: [7]?u64 = @splat(null);
        for (self.history[0..self.history_len]) |entry_opt| {
            const entry = entry_opt.?;
            const slot = commandSlot(entry.operation);
            if (source_batches[slot] != null) return error.InvalidDescriptorState;
            seen[slot] = true;
            source_batches[slot] = entry.batch;
        }
        for (self.movement_steps[0..self.movement_len]) |step_opt| if (step_opt.?.proposal.operation == .request) {
            const command = step_opt.?.command orelse return error.InvalidDescriptorState;
            const slot = moveCommandSlot(requestCountBefore(self, step_opt.?));
            if (seen[slot] or source_batches[slot] != null) return error.InvalidDescriptorState;
            seen[slot] = true;
            source_batches[slot] = command.batch;
        };
        var first_missing = false;
        for (seen) |present| {
            if (!present) first_missing = true else if (first_missing) return error.InvalidDescriptorState;
        }
        var latest_batch: u64 = 0;
        for (source_batches) |event_batch| if (event_batch) |value| {
            if (value < latest_batch) return error.InvalidDescriptorState;
            latest_batch = value;
        };
        if (self.last_event_batch != latest_batch) return error.InvalidDescriptorState;
    }

    /// Make a copy-on-write state proposal for an acknowledged source command.
    /// Caller must obtain receipt from the retained source event owner; this module
    /// validates its exact program binding and source position before staging.
    pub fn stage(self: State, binding: Binding, receipt: Receipt) !Proposal {
        try self.validate(binding);
        try validateReceipt(binding, receipt);
        if (self.released or self.history_len >= self.history.len) return error.InvalidDescriptorState;
        const completed_moves = completedMovementBatches(self);
        if (self.history_len == 0) {
            if (receipt.operation != .x or receipt.instance == 0) return error.InvalidDescriptorReceipt;
        } else {
            const previous = self.history[self.history_len - 1].?;
            if (receipt.instance != previous.instance or receipt.batch < self.last_event_batch or receipt.command_index <= previous.command_index or
                !allowedNext(previous.operation, receipt.operation)) return error.InvalidDescriptorReceipt;
        }
        if (receipt.command_index != binding.command_indices[commandSlot(receipt.operation)]) return error.InvalidDescriptorReceipt;
        if ((receipt.operation == .x and (self.history_len != 0 or self.movement_len != 0)) or
            (receipt.operation == .y and (self.history_len != 1 or self.movement_len != 0)) or
            (receipt.operation == .mode0 and (self.history_len != 2 or completed_moves != 2 or self.movement_owner.source_offset != null)) or
            (receipt.operation == .release and (self.history_len != 3 or completed_moves != 3 or self.movement_owner.source_offset != null))) return error.InvalidDescriptorReceipt;

        var next = self;
        next.instance = receipt.instance;
        next.last_batch = receipt.batch;
        next.last_event_batch = receipt.batch;
        next.last_command_index = receipt.command_index;
        const field_copy_result: ?u8 = switch (receipt.operation) {
            .x => fieldCopyResult(254, binding.tile_entry_zero_plus2),
            .y => fieldCopyResult(0x10, binding.tile_entry_zero_plus2),
            .mode0, .release => null,
        };
        next.history[next.history_len] = .{
            .operation = receipt.operation,
            .instance = receipt.instance,
            .batch = receipt.batch,
            .command_index = receipt.command_index,
            .source_offset = receipt.source_offset,
            .descriptor_16_result = field_copy_result,
        };
        next.history_len += 1;
        switch (receipt.operation) {
            .x => {
                next.x = receipt.value;
                next.descriptor_16_copy_calls += 1;
                next.descriptor_16_result = field_copy_result;
            },
            .y => {
                next.y = receipt.value;
                next.descriptor_16_copy_calls += 1;
                next.descriptor_16_result = field_copy_result;
            },
            .mode0 => next.descriptor_5 = 0,
            .release => {
                next.x = 254;
                next.y = 254;
                next.descriptor_5 = 0;
                next.draw_enabled = false;
                next.released = true;
            },
        }
        try next.validate(binding);
        return .{ .before = self, .after = next, .change = .{
            .descriptor_x_px = @as(i32, next.x) * 8,
            .descriptor_y_px = @as(i32, next.y) * 8,
            .observed_motion = next.actor_motion,
            .released = next.released,
            .keep_graphics_child = next.child.attached,
        } };
    }

    /// Retain an owner proposal and the actor state observed by the shared host.
    /// The source Session must replay MovementAccess collision before publishing.
    pub fn stageMovement(
        self: State,
        binding: Binding,
        command: SourceCommand,
        proposal: movement_batch.Proposal,
        before: ActorMotion,
        after: ActorMotion,
    ) !MovementProposal {
        try self.validate(binding);
        try validateSourceCommand(binding, command);
        if (self.released or self.movement_len >= self.movement_steps.len or command.instance != self.instance or
            command.batch < self.last_event_batch) return error.InvalidDescriptorMovement;
        var owner = try movement_batch.Owner.restore(self.movement_owner);
        switch (proposal.operation) {
            .request => |offset| {
                const request_index = requestCount(self);
                if (request_index >= source_moves.len or offset != source_moves[request_index] or
                    command.source_offset != offset or command.command_index != binding.command_indices[moveCommandSlot(request_index)] or
                    (request_index < 2 and self.history_len != 2) or (request_index == 2 and self.history_len != 3) or
                    self.movement_owner.source_offset != null or !std.meta.eql(before, after)) return error.InvalidDescriptorMovement;
                const expected = try owner.proposeRequest(offset, proposal.after.checkpoint);
                if (!std.meta.eql(expected, proposal)) return error.InvalidDescriptorMovement;
                if (self.actor_motion) |current| {
                    if (!std.meta.eql(current, before)) return error.InvalidDescriptorMovement;
                } else if (before.x != 280 or before.y != 128 or before.offset_x != 0 or before.offset_y != 0) return error.InvalidDescriptorMovement;
            },
            .tick => {
                const offset = self.movement_owner.source_offset orelse return error.InvalidDescriptorMovement;
                const index = requestCount(self) - 1;
                if (command.source_offset != offset or command.command_index != binding.command_indices[moveCommandSlot(index)] or
                    !std.meta.eql(self.actor_motion orelse return error.InvalidDescriptorMovement, before)) return error.InvalidDescriptorMovement;
                const request = latestRequest(self) orelse return error.InvalidDescriptorMovement;
                if (!sameCommand(request, command)) return error.InvalidDescriptorMovement;
                const expected = try owner.proposeTick(proposal.after.checkpoint);
                if (!std.meta.eql(expected, proposal)) return error.InvalidDescriptorMovement;
            },
        }
        try validateMotion(before);
        try validateMotion(after);
        var next = self;
        next.movement_owner = proposal.after;
        next.actor_motion = after;
        next.last_event_batch = command.batch;
        next.movement_steps[next.movement_len] = .{
            .source_offset = command.source_offset,
            .command_index = command.command_index,
            .event_instance = command.instance,
            .event_batch = command.batch,
            .proposal = proposal,
            .before = before,
            .after = after,
            .command = command,
        };
        next.movement_len += 1;
        try next.validate(binding);
        return .{ .before = self, .after = next, .change = .{
            .descriptor_x_px = @as(i32, next.x) * 8,
            .descriptor_y_px = @as(i32, next.y) * 8,
            .observed_motion = next.actor_motion,
            .released = next.released,
            .keep_graphics_child = next.child.attached,
        } };
    }

    /// Publish only if the retained state still matches the proposal's base.
    pub fn publish(self: *State, proposal: Proposal) !void {
        if (!std.meta.eql(self.*, proposal.before)) return error.StaleDescriptorProposal;
        self.* = proposal.after;
    }

    pub fn publishMovement(self: *State, proposal: MovementProposal) !void {
        if (!std.meta.eql(self.*, proposal.before)) return error.StaleDescriptorProposal;
        self.* = proposal.after;
    }
};

pub const ActorChange = struct {
    descriptor_x_px: i32,
    descriptor_y_px: i32,
    observed_motion: ?ActorMotion,
    released: bool,
    keep_graphics_child: bool,
};
pub const Proposal = struct { before: State, after: State, change: ActorChange };
pub const MovementProposal = struct { before: State, after: State, change: ActorChange };

fn allowedNext(previous: Operation, next: Operation) bool {
    return switch (previous) {
        .x => next == .y,
        .y => next == .mode0,
        .mode0 => next == .release,
        .release => false,
    };
}

fn commandSlot(operation: Operation) usize {
    return switch (operation) {
        .x => 0,
        .y => 1,
        .mode0 => 4,
        .release => 6,
    };
}

fn moveCommandSlot(index: usize) usize {
    return switch (index) {
        0 => 2,
        1 => 3,
        2 => 5,
        else => unreachable,
    };
}

fn requestCount(state: State) usize {
    var count: usize = 0;
    for (state.movement_steps[0..state.movement_len]) |step| if (step.?.proposal.operation == .request) {
        count += 1;
    };
    return count;
}

fn requestCountBefore(state: State, step: MovementStep) usize {
    var count: usize = 0;
    for (state.movement_steps[0..state.movement_len]) |prior| {
        if (prior.?.proposal.after.checkpoint == step.proposal.after.checkpoint) break;
        if (prior.?.proposal.operation == .request) count += 1;
    }
    return count;
}

fn completedMovementBatches(state: State) usize {
    var count: usize = 0;
    for (state.movement_steps[0..state.movement_len]) |step| if (step.?.proposal.operation == .tick and step.?.proposal.after.source_offset == null) {
        count += 1;
    };
    return count;
}

fn latestRequest(state: State) ?SourceCommand {
    var i = state.movement_len;
    while (i > 0) {
        i -= 1;
        const step = state.movement_steps[i].?;
        if (step.proposal.operation == .request) return step.command;
    }
    return null;
}

fn sameCommand(a: SourceCommand, b: SourceCommand) bool {
    return std.mem.eql(u8, a.event_id, b.event_id) and std.mem.eql(u8, a.event_sha256, b.event_sha256) and
        std.mem.eql(u8, a.program, b.program) and a.instance == b.instance and a.batch == b.batch and
        a.command_index == b.command_index and std.mem.eql(u8, a.source_file, b.source_file) and
        std.mem.eql(u8, a.source_sha256, b.source_sha256) and a.source_offset == b.source_offset and
        a.opcode == b.opcode and a.entity == b.entity and a.selector == b.selector and a.parameter == b.parameter and
        a.repetitions == b.repetitions and a.direction == b.direction;
}

fn validateSourceCommand(binding: Binding, command: SourceCommand) !void {
    const expected = for (movement_batch.sources) |source| {
        if (source.offset == command.source_offset) break source;
    } else return error.InvalidDescriptorMovement;
    const index: usize = for (source_moves, 0..) |offset, i| {
        if (offset == command.source_offset) break i;
    } else return error.InvalidDescriptorMovement;
    if (!std.mem.eql(u8, command.event_id, binding.event_id) or
        !std.mem.eql(u8, command.event_sha256, binding.event_sha256) or
        !std.mem.eql(u8, command.program, binding.program) or command.instance == 0 or command.batch == 0 or
        command.command_index != binding.command_indices[moveCommandSlot(index)] or
        !std.mem.eql(u8, command.source_file, "VA1.BIN") or
        !std.mem.eql(u8, command.source_sha256, source_sha256) or command.opcode != 0x06 or command.entity != 2 or
        command.selector != expected.selector or command.parameter != expected.parameter or
        command.repetitions != expected.repetitions or command.direction != expected.direction) return error.InvalidDescriptorMovement;
}

fn validateMotion(value: ActorMotion) !void {
    if (value.x < 0 or value.x > 2040 or value.y < 0 or value.y > 2040 or
        @mod(value.x, 8) != 0 or @mod(value.y, 8) != 0 or value.offset_x < -8 or value.offset_x > 8 or
        value.offset_y < -8 or value.offset_y > 8 or (value.offset_x != 0 and value.offset_y != 0)) return error.InvalidDescriptorMovement;
}

fn validateMovement(state: State, binding: Binding) !void {
    var owner = try movement_batch.Owner.restore(.{});
    var actor_motion: ?ActorMotion = null;
    var active_command: ?SourceCommand = null;
    var request_index: usize = 0;
    var last_event_batch: u64 = 0;
    for (state.movement_steps[0..state.movement_len]) |step_opt| {
        const step = step_opt orelse return error.InvalidDescriptorState;
        try validateMotion(step.before);
        try validateMotion(step.after);
        const proposal_offset = switch (step.proposal.operation) {
            .request => |offset| offset,
            .tick => step.proposal.before.source_offset orelse return error.InvalidDescriptorState,
        };
        const command = step.command orelse return error.InvalidDescriptorState;
        if (step.event_instance != state.instance or step.event_batch == 0 or step.source_offset != proposal_offset or
            step.event_instance != command.instance or step.event_batch != command.batch or
            step.command_index != command.command_index) return error.InvalidDescriptorState;
        switch (step.proposal.operation) {
            .request => |offset| {
                try validateSourceCommand(binding, command);
                if (request_index >= source_moves.len or offset != source_moves[request_index] or command.source_offset != offset or
                    command.batch < last_event_batch or step.command_index != command.command_index or
                    step.command_index != binding.command_indices[moveCommandSlot(request_index)] or owner.state.source_offset != null or
                    !std.meta.eql(step.before, step.after)) return error.InvalidDescriptorState;
                if (actor_motion) |previous| {
                    if (!std.meta.eql(previous, step.before)) return error.InvalidDescriptorState;
                } else if (step.before.x != 280 or step.before.y != 128 or step.before.offset_x != 0 or step.before.offset_y != 0) return error.InvalidDescriptorState;
                const expected = try owner.proposeRequest(offset, step.proposal.after.checkpoint);
                if (!std.meta.eql(expected, step.proposal)) return error.InvalidDescriptorState;
                owner.state = expected.after;
                active_command = command;
                last_event_batch = command.batch;
                request_index += 1;
            },
            .tick => {
                const active = active_command orelse return error.InvalidDescriptorState;
                if (!sameCommand(active, command) or step.source_offset != active.source_offset or
                    step.command_index != active.command_index or !std.meta.eql(owner.state, step.proposal.before) or
                    !std.meta.eql(actor_motion orelse return error.InvalidDescriptorState, step.before)) return error.InvalidDescriptorState;
                const expected = try owner.proposeTick(step.proposal.after.checkpoint);
                if (!std.meta.eql(expected, step.proposal)) return error.InvalidDescriptorState;
                owner.state = expected.after;
            },
        }
        actor_motion = step.after;
    }
    for (state.movement_steps[state.movement_len..]) |step| if (step != null) return error.InvalidDescriptorState;
    if (!std.meta.eql(owner.state, state.movement_owner) or
        ((actor_motion == null) != (state.actor_motion == null)) or
        (actor_motion != null and !std.meta.eql(actor_motion.?, state.actor_motion.?))) return error.InvalidDescriptorState;
}

fn sourceOffset(operation: Operation) u32 {
    return switch (operation) {
        .x => 0x3d174,
        .y => 0x3d178,
        .mode0 => 0x3d186,
        .release => 0x3d1a4,
    };
}

fn fieldCopyResult(descriptor_y: u8, tile_entry_plus2: u8) u8 {
    return if (tile_entry_plus2 == 1) 0 -% descriptor_y else tile_entry_plus2;
}

fn validateReceipt(binding: Binding, receipt: Receipt) !void {
    const opcode: [2]u8 = switch (receipt.operation) {
        .x, .y, .mode0 => .{ 0x07, 0x00 },
        .release => .{ 0x3a, 0x00 },
    };
    const value: u8 = switch (receipt.operation) {
        .x => 0x23,
        .y => 0x10,
        .mode0, .release => 0,
    };
    if (!std.mem.eql(u8, receipt.event_id, binding.event_id) or
        !std.mem.eql(u8, receipt.event_sha256, binding.event_sha256) or
        !std.mem.eql(u8, receipt.program, binding.program) or receipt.instance == 0 or receipt.batch == 0 or
        !std.mem.eql(u8, receipt.source_file, "VA1.BIN") or
        !std.mem.eql(u8, receipt.source_sha256, source_sha256) or
        receipt.entity != 2 or receipt.selector != 0 or receipt.source_offset != sourceOffset(receipt.operation) or
        !std.mem.eql(u8, &receipt.opcode, &opcode) or receipt.value != value) return error.InvalidDescriptorReceipt;
}

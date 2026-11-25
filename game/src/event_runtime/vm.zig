//! Step-based VM execution, branch history tracking, and host batch synchronization.
const std = @import("std");
const runtime = @import("../event_runtime.zig");
const schema = @import("schema.zig");
const story_mod = @import("story.zig");
const validate_mod = @import("validate.zig");

const Command = runtime.Command;
const Content = runtime.Content;
const StoryWrite = story_mod.StoryWrite;
const StoryState = story_mod.StoryState;
const Wait = runtime.Wait;
const Actor = runtime.Actor;

pub const Input = struct {
    completions: []const []const u8 = &.{},
    active_party: ?[]const u8 = null,
    confirm: bool = false,
    choice: u8 = 0,
    choice_confirmed: bool = false,
    wheel_outcome: ?u3 = null,
    alignment_ready: ?bool = null,
    mode_ready: bool = true,
    room_transition_ready: ?bool = null,

    pub fn completed(self: Input, id: []const u8) bool {
        for (self.completions) |entry| if (std.mem.eql(u8, entry, id)) return true;
        return false;
    }
};

pub const Status = enum { idle, running, waiting, waiting_choice, completed };

pub const Execution = struct {
    pc: u16 = 0,
    active: bool = true,
    reloop: bool = false,
    choice: u8 = 0,
    wait: ?Wait = null,
    path: ?BranchPath = null,
};

pub const BranchPath = struct {
    pub const Edge = struct { command: u16 = 0, target: u16 = 0 };
    count: u8 = 0,
    edges: [8]Edge = @splat(.{}),

    fn record(self: *BranchPath, command: u16, target: u16) !void {
        if (target <= command or (self.count != 0 and command <= self.edges[self.count - 1].command)) return error.InvalidEventBranchHistory;
        if (self.count == self.edges.len) return error.EventBranchHistoryFull;
        self.edges[self.count] = .{ .command = command, .target = target };
        self.count += 1;
    }
};

fn validHistoryEdge(command: Command, index: u16, target: u16) bool {
    return switch (command.kind) {
        .jump => command.target == target,
        .branch_wheel, .branch_castle_tier, .branch_party => if (command.targets) |targets| std.mem.indexOfScalar(u16, targets, target) != null else false,
        .branch_choice => target == index + 1 or (if (command.targets) |targets| std.mem.indexOfScalar(u16, targets, target) != null else command.target == target),
        .battle => command.escape_target == target or command.defeat_target == target,
        .chest_grant => command.failure_target == target,
        .inventory_edit, .shared_inventory_edit => if (command.inventory) |edit| edit.failure_target == target else false,
        else => false,
    };
}

pub const CommandHistory = struct {
    commands: []const Command,
    execution: Execution,
    cursor: usize = 0,
    stopped: bool = false,

    pub fn next(self: *CommandHistory) ?struct { index: u16, command: Command } {
        if (self.stopped or self.cursor >= self.execution.pc or self.cursor >= self.commands.len) return null;
        const index = self.cursor;
        self.cursor += 1;
        if (self.execution.path) |path| for (path.edges[0..@min(path.count, path.edges.len)]) |edge| {
            if (edge.command == index) {
                self.cursor = edge.target;
                break;
            }
        };
        if (self.execution.path != null and endsEvent(self.commands[index].kind)) self.stopped = true;
        return .{ .index = @intCast(index), .command = self.commands[index] };
    }
};

pub const EventBatch = struct {
    id: u64,
    effect_count: u16 = 0,
    effects: [runtime.max_batch_effects]Command = @splat(.{ .kind = .label }),

    pub fn slice(self: *const EventBatch) []const Command {
        return self.effects[0..self.effect_count];
    }
};

pub const PendingBatch = struct {
    batch: EventBatch,
    next: Execution,
    story_write_count: u8 = 0,
    story_writes: [4]StoryWrite = @splat(.{ .flag = .{ .id = "", .mask = 0 } }),
};

pub const Instance = struct {
    pub fn heroVisible(self: *const Instance, content: Content) bool {
        const program = content.program(self.program_id) orelse return true;
        var visible = true;
        var history: CommandHistory = .{ .commands = program.commands, .execution = self.execution };
        while (history.next()) |entry| switch (entry.command.kind) {
            .hide_hero => visible = false,
            .place_hero => visible = true,
            else => {},
        };
        return visible;
    }

    pub fn redirect(self: *Instance, content: Content, command: u16, target: u16) !void {
        const program = content.program(self.program_id) orelse return error.UnknownEventProgram;
        if (command >= program.commands.len or target >= program.commands.len or !validHistoryEdge(program.commands[command], command, target)) return error.InvalidEventBranchHistory;
        if (self.execution.path) |*path| try path.record(command, target);
        self.execution.pc = target;
    }

    schema: []const u8 = schema.state_schema,
    content_id: []const u8,
    content_sha256: []const u8,
    program_id: []const u8,
    execution: Execution = .{},
    effect_sequence: u64 = 0,
    pending: ?PendingBatch = null,

    pub fn pendingBattle(self: *const Instance) ?[]const u8 {
        const pending = if (self.pending) |*value| value else return null;
        const effect = &pending.batch.effects[0];
        return if (pending.batch.effect_count == 1 and effect.kind == .battle) effect.battle else null;
    }

    pub fn pendingFixedDice(self: *const Instance) bool {
        const pending = if (self.pending) |*value| value else return false;
        return pending.batch.effect_count == 1 and pending.batch.effects[0].kind == .fixed_dice;
    }

    pub fn pendingItemOverload(self: *const Instance) bool {
        const pending = self.pending orelse return false;
        return pending.batch.effect_count == 1 and pending.batch.effects[0].kind == .item_overload;
    }

    pub fn pendingPartySelect(self: *const Instance) bool {
        const pending = self.pending orelse return false;
        return pending.batch.effect_count == 1 and pending.batch.effects[0].kind == .party_select;
    }

    pub fn choiceBox(self: *const Instance, content: Content) ?u8 {
        const wait = self.execution.wait orelse return null;
        if (wait.kind != .choice) return null;
        const program = content.program(self.program_id) orelse return null;
        if (wait.command_index >= program.commands.len) return null;
        const command = program.commands[wait.command_index];
        return if (command.kind == .choice) command.box else null;
    }

    pub fn choiceOptions(self: *const Instance, content: Content) ?u8 {
        const wait = self.execution.wait orelse return null;
        if (wait.kind != .choice) return null;
        const program = content.program(self.program_id) orelse return null;
        if (wait.command_index >= program.commands.len) return null;
        const command = program.commands[wait.command_index];
        return if (command.kind == .choice) command.options else null;
    }

    pub fn validate(self: Instance, content: Content) !void {
        try content.validate();
        if (!std.mem.eql(u8, self.content_id, content.id) or !std.mem.eql(u8, self.content_sha256, content.content_sha256)) return error.EventContentIdentityMismatch;
        const program = content.program(self.program_id) orelse return error.UnknownEventProgram;
        const track_branches = content.tracksBranchHistory(program);
        if (!std.mem.eql(u8, self.schema, if (track_branches) schema.branch_state_schema else schema.state_schema)) return error.EventContentIdentityMismatch;
        if ((self.execution.path != null) != track_branches) return error.InvalidEventBranchHistory;
        try validateExecution(self.execution, program.commands);
        if (self.pending) |pending| {
            if ((pending.next.path != null) != track_branches) return error.InvalidEventBranchHistory;
            if (self.execution.path) |current| {
                const future = pending.next.path.?;
                if (future.count < current.count or future.count > future.edges.len) return error.InvalidEventBranchHistory;
                for (current.edges[0..current.count], future.edges[0..current.count]) |a, b| if (a.command != b.command or a.target != b.target) return error.InvalidEventBranchHistory;
            }
            if (pending.batch.id == 0 or pending.batch.id > self.effect_sequence or pending.batch.effect_count == 0 or pending.batch.effect_count > runtime.max_batch_effects or pending.story_write_count > 4) return error.InvalidEventBatch;
            try validateExecution(pending.next, program.commands);
            const effects = pending.batch.slice();
            if (track_branches) {
                var history: CommandHistory = .{ .commands = program.commands, .execution = pending.next };
                var effect_index: usize = 0;
                var write_index: usize = 0;
                while (history.next()) |executed| {
                    if (executed.index < self.execution.pc or !isHostEffect(executed.command.kind)) continue;
                    var expected = executed.command;
                    expected.origin = executed.index;
                    if (effect_index >= effects.len or !validate_mod.semanticEqual(effects[effect_index], expected)) return error.InvalidEventBatch;
                    effect_index += 1;
                    if (expected.kind == .story_or or expected.kind == .story_andnot) {
                        if (write_index >= pending.story_write_count or !validate_mod.semanticEqual(pending.story_writes[write_index].flag, expected.flag.?) or pending.story_writes[write_index].clear != (expected.kind == .story_andnot)) return error.InvalidEventBatch;
                        write_index += 1;
                    }
                }
                if (effect_index != effects.len or write_index != pending.story_write_count) return error.InvalidEventBatch;
            }
            for (effects, 0..) |effect, index| {
                if (endsEvent(effect.kind) and index + 1 != effects.len) return error.InvalidEventBatch;
                try content.validateCommand(effect, program.commands.len, program.commands.len - 1);
                if (effect.kind == .battle or isIsolatedEffect(effect.kind)) {
                    if (pending.batch.effect_count != 1 or pending.story_write_count != 0 or effect.origin >= program.commands.len or
                        !self.execution.active or pending.next.pc != effect.origin + 1 or !pending.next.active) return error.InvalidEventBatch;
                    var expected = program.commands[effect.origin];
                    expected.origin = effect.origin;
                    if (!validate_mod.semanticEqual(effect, expected) or !validate_mod.semanticEqual(pending.next.wait, expected.wait)) return error.InvalidEventBatch;
                }
            }
            const last = effects[effects.len - 1];
            if (endsEvent(last.kind) == pending.next.active) return error.InvalidEventBatch;
            if (!pending.next.active) {
                if (!self.execution.active or @as(usize, last.origin) + 1 != pending.next.pc) return error.InvalidEventBatch;
                var expected = program.commands[last.origin];
                expected.origin = last.origin;
                if (!validate_mod.semanticEqual(last, expected)) return error.InvalidEventBatch;
            }
            for (pending.story_writes[0..pending.story_write_count]) |write| try content.validateFlag(write.flag);
            if (program.commands[program.commands.len - 1].kind == .room_transition or program.commands[program.commands.len - 1].kind == .world_transition) {
                var write_index: usize = 0;
                for (effects) |effect| {
                    if (effect.origin >= program.commands.len) return error.InvalidEventBatch;
                    var original = program.commands[effect.origin];
                    original.origin = effect.origin;
                    if (!validate_mod.semanticEqual(effect, original)) return error.InvalidEventBatch;
                    if (effect.kind == .story_or or effect.kind == .story_andnot) {
                        if (write_index >= pending.story_write_count or
                            !validate_mod.semanticEqual(pending.story_writes[write_index].flag, effect.flag.?) or
                            pending.story_writes[write_index].clear != (effect.kind == .story_andnot))
                            return error.InvalidEventBatch;
                        write_index += 1;
                    }
                }
                if (write_index != pending.story_write_count) return error.InvalidEventBatch;
            }
        }
    }
};

fn validateExecution(execution: Execution, commands: []const Command) !void {
    if (execution.path) |path| {
        if (path.count > path.edges.len) return error.InvalidEventBranchHistory;
        for (path.edges[0..path.count], 0..) |edge, i| {
            if (edge.command >= commands.len or edge.target >= commands.len or edge.target <= edge.command or edge.command >= execution.pc or
                !validHistoryEdge(commands[edge.command], edge.command, edge.target) or
                (i != 0 and edge.command < path.edges[i - 1].target)) return error.InvalidEventBranchHistory;
        }
        var history: CommandHistory = .{ .commands = commands, .execution = execution };
        var used: u8 = 0;
        var last_kind: ?@FieldType(Command, "kind") = null;
        while (history.next()) |entry| {
            last_kind = entry.command.kind;
            if (used < path.count and path.edges[used].command == entry.index) {
                used += 1;
            } else if (isBranch(entry.command.kind)) return error.InvalidEventBranchHistory;
        }
        if (history.cursor != execution.pc or used != path.count) return error.InvalidEventBranchHistory;
        if (!execution.active and (last_kind == null or !endsEvent(last_kind.?))) return error.InvalidEventBranchHistory;
    }
    const command_count = commands.len;
    if (execution.pc > command_count or (execution.active and execution.pc == command_count)) return error.InvalidEventCursor;
    if (!execution.active and (execution.pc == 0 or !endsEvent(commands[execution.pc - 1].kind))) return error.InvalidEventCursor;
    if (execution.wait) |pending| {
        try Content.validateWait(pending);
        if (pending.kind == .camera_push and (execution.pc == 0 or commands[execution.pc - 1].kind != .camera_push or
            !validate_mod.semanticEqual(commands[execution.pc - 1].wait, @as(?Wait, pending)))) return error.InvalidEventWait;
        if (pending.kind == .field_effect and (execution.pc >= command_count or
            commands[execution.pc].kind != .wait_field_effect or !std.mem.eql(u8, pending.id, "field_effect"))) return error.InvalidEventWait;
        if (pending.kind == .choice and (pending.command_index >= command_count or @as(usize, pending.command_index) + 1 != execution.pc or commands[pending.command_index].kind != .choice))
            return error.InvalidEventWait;
    }
}

pub fn start(content: Content, story: *const StoryState, program_id: []const u8) !Instance {
    try content.validate();
    const program = content.program(program_id) orelse return error.UnknownEventProgram;
    if (!story.matches(program.conditions)) return error.EventConditionFalse;
    const track_branches = content.tracksBranchHistory(program);
    return .{ .schema = if (track_branches) schema.branch_state_schema else schema.state_schema, .execution = .{ .path = if (track_branches) .{} else null }, .content_id = content.id, .content_sha256 = content.content_sha256, .program_id = program.id };
}

pub const StepResult = struct { status: Status, batch: ?EventBatch = null };

fn statusOf(execution: Execution, pending: bool) Status {
    if (!execution.active) return .completed;
    if (pending) return .running;
    if (execution.wait) |pending_wait| return if (pending_wait.kind == .choice) .waiting_choice else .waiting;
    return .running;
}

fn isHostEffect(kind: @TypeOf(@as(Command, undefined).kind)) bool {
    return switch (kind) {
        .jump, .branch_choice, .branch_wheel, .branch_castle_tier, .branch_party, .label, .continue_tick, .yield_tick, .wait_for_accept, .wait_tracks, .wait_field_effect, .wait_boxes, .wait_event_flags_low2, .wait_text_queue_empty, .wait_text_queue_drain_and_release => false,
        else => true,
    };
}

pub fn isPartyMutation(kind: @FieldType(Command, "kind")) bool {
    return switch (kind) {
        .party_join, .party_load, .advance_character, .party_gain_experience, .party_lose_experience, .party_leave, .party_dismiss, .rune_grant, .inventory_edit, .warehouse_deposit => true,
        else => false,
    };
}

pub fn isWheelControl(kind: @FieldType(Command, "kind")) bool {
    return switch (kind) {
        .wheel_spin, .wheel_restore, .wheel_turn, .wheel_align, .branch_wheel => true,
        else => false,
    };
}

fn isIsolatedEffect(kind: @FieldType(Command, "kind")) bool {
    return switch (kind) {
        .field_music, .play_sound, .shared_inventory_edit, .inn_stay, .party_restore, .world_mode, .soul_eater_advance, .money_edit, .recruit_toggle, .recruit_mark_loaded, .service, .chest_grant, .tile_variant, .auto_route, .special_checkpoint, .fixed_dice, .party_select, .item_overload => true,
        else => isPartyMutation(kind) or (isWheelControl(kind) and kind != .wheel_align),
    };
}

pub fn endsEvent(kind: @FieldType(Command, "kind")) bool {
    return kind == .end_stream or kind == .room_transition or kind == .world_transition;
}

pub fn isBranch(kind: @FieldType(Command, "kind")) bool {
    return kind == .jump or kind == .branch_choice or kind == .branch_wheel or kind == .branch_castle_tier or kind == .branch_party;
}

fn pureWait(command: Command) ?Wait {
    return switch (command.kind) {
        .wait_for_accept => .{ .kind = .accept, .id = "accept" },
        .wait_tracks => .{ .kind = .tracks, .id = "tracks" },
        .wait_field_effect => .{ .kind = .field_effect, .id = "field_effect" },
        .wait_boxes => .{ .kind = .event_flags_low2, .id = "dialogue_flags" },
        .wait_event_flags_low2 => .{ .kind = .event_flags_low2, .id = "dialogue_flags" },
        .wait_text_queue_empty, .wait_text_queue_drain_and_release => .{ .kind = .text_queue, .id = "text_queue" },
        else => null,
    };
}

pub fn step(content: Content, instance: *Instance, story: *StoryState, input: Input) !StepResult {
    try instance.validate(content);
    if (instance.pending) |pending| return .{ .status = statusOf(pending.next, true), .batch = pending.batch };
    if (!instance.execution.active) return .{ .status = .completed };
    var next = instance.*;
    if (next.execution.wait) |pending_wait| {
        if (pending_wait.kind == .choice) {
            if (!input.choice_confirmed) return .{ .status = .waiting_choice };
            next.execution.choice = input.choice;
            next.execution.wait = null;
            instance.* = next;
            return .{ .status = .running };
        }
        const complete = if (pending_wait.kind == .accept) input.confirm else input.completed(pending_wait.id);
        if (!complete) return .{ .status = .waiting };
        next.execution.wait = null;
        if (pending_wait.kind == .speaker_prefix) {
            instance.* = next;
            return .{ .status = .running };
        }
    }
    const program = content.program(next.program_id).?;
    var batch: EventBatch = .{ .id = next.effect_sequence + 1 };
    var story_writes: [4]StoryWrite = @splat(.{ .flag = .{ .id = "", .mask = 0 } });
    var story_write_count: u8 = 0;
    var operations: usize = 0;
    while (next.execution.active) {
        if (operations == runtime.max_commands_per_step) return error.EventCycleBound;
        operations += 1;
        const command_index = next.execution.pc;
        if (command_index >= program.commands.len) return error.InvalidEventCursor;
        const command = program.commands[command_index];
        if (command.kind == .align_hero) if (input.alignment_ready) |ready| {
            if (!ready or batch.effect_count != 0) break;
        };
        // Commit the prefix and finish field motion before handing off the frame.
        if ((command.kind == .battle or command.kind == .fixed_dice or command.kind == .party_select) and (batch.effect_count != 0 or !input.mode_ready)) break;
        const isolated = isIsolatedEffect(command.kind);
        if (isolated and batch.effect_count != 0) break;
        if (command.kind == .room_transition) if (input.room_transition_ready) |ready| {
            if (!ready or batch.effect_count != 0) break;
        };
        if (command.requires) |required| {
            if (!input.completed(required.id)) {
                if (batch.effect_count == 0) return .{ .status = .waiting };
                break;
            }
        }
        if ((command.kind == .room_transition or command.kind == .world_transition) and !input.completed("dialogue_flags")) {
            next.execution.wait = .{ .kind = .event_flags_low2, .id = "dialogue_flags" };
            break;
        }
        if (pureWait(command)) |required| {
            const complete = if (required.kind == .accept) input.confirm else input.completed(required.id);
            const effect_queued = required.kind == .field_effect and for (batch.slice()) |effect| {
                if (effect.kind == .field_effect) break true;
            } else false;
            if (!complete or effect_queued) {
                next.execution.wait = required;
                break;
            }
            next.execution.pc += 1;
        } else switch (command.kind) {
            .label => next.execution.pc += 1,
            .jump => try next.redirect(content, command_index, command.target.?),
            .branch_wheel => {
                const outcome = input.wheel_outcome orelse return error.WheelResultNotReady;
                if (outcome >= 7) return error.InvalidWheelOutcome;
                try next.redirect(content, command_index, command.targets.?[outcome]);
            },
            .branch_castle_tier => try next.redirect(content, command_index, command.targets.?[@min(story.castle_tier -| 2, 2)]),
            .branch_party => {
                const party = input.active_party orelse return error.EventPartyNotAvailable;
                const present = std.mem.indexOfScalar(u8, party, command.index.?) != null;
                try next.redirect(content, command_index, command.targets.?[@intFromBool(present)]);
            },
            .branch_choice => {
                if (command.targets) |targets| {
                    try next.redirect(content, command_index, if (next.execution.choice == 0) next.execution.pc + 1 else targets[@min(@as(usize, next.execution.choice - 1), targets.len - 1)]);
                } else {
                    try next.redirect(content, command_index, if (next.execution.choice == 0) next.execution.pc + 1 else command.target.?);
                }
            },
            .continue_tick => {
                next.execution.reloop = true;
                next.execution.pc += 1;
            },
            .yield_tick => {
                next.execution.reloop = false;
                next.execution.pc += 1;
                break;
            },
            else => {
                if (!isHostEffect(command.kind)) return error.UnsupportedEventCommand;
                if (batch.effect_count == runtime.max_batch_effects) return error.EventBatchOverflow;
                batch.effects[batch.effect_count] = command;
                batch.effects[batch.effect_count].origin = command_index;
                batch.effect_count += 1;
                if (command.kind == .story_or or command.kind == .story_andnot) {
                    if (story_write_count == story_writes.len) return error.EventBatchOverflow;
                    story_writes[story_write_count] = .{ .flag = command.flag.?, .clear = command.kind == .story_andnot };
                    story_write_count += 1;
                }
                next.execution.pc += 1;
                if (endsEvent(command.kind)) next.execution.active = false;
                if (command.kind == .choice) {
                    next.execution.choice = 0;
                    next.execution.wait = .{ .kind = .choice, .command_index = command_index };
                } else if (command.wait) |pending_wait| {
                    next.execution.wait = pending_wait;
                }
                if (command.kind == .battle or isolated) break;
            },
        }
        if (!next.execution.active or !next.execution.reloop or next.execution.wait != null) break;
    }
    if (batch.effect_count != 0) {
        const pending: PendingBatch = .{ .batch = batch, .next = next.execution, .story_write_count = story_write_count, .story_writes = story_writes };
        next.execution = instance.execution;
        next.effect_sequence += 1;
        next.pending = pending;
        instance.* = next;
        return .{ .status = statusOf(pending.next, true), .batch = batch };
    }
    next.pending = null;
    instance.* = next;
    return .{ .status = statusOf(next.execution, false) };
}

pub fn acknowledge(content: Content, instance: *Instance, story: *StoryState, batch_id: u64) !void {
    try instance.validate(content);
    const pending = instance.pending orelse return error.NoPendingEventBatch;
    if (pending.batch.id != batch_id) return error.EventBatchIdentityMismatch;
    var next_story = story.*;
    for (pending.story_writes[0..pending.story_write_count]) |write| {
        if (write.clear) try next_story.clear(write.flag) else try next_story.apply(write.flag);
    }
    instance.execution = pending.next;
    instance.pending = null;
    story.* = next_story;
}

pub fn actorVisible(story: *const StoryState, actor: Actor) bool {
    return story.matches(actor.conditions);
}

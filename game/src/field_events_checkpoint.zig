//! Field-event checkpoint capture/rebind. Imports the session types lazily
//! through a module cycle; Zig resolves this because the declarations are
//! analyzed lazily.
const std = @import("std");
const field = @import("field");
const runtime = @import("event_runtime");
const ordinary = @import("field_actors");
const begin = @import("field_events_begin.zig");
const checks = @import("field_events_validate_checks.zig");
const field_events = @import("field_events.zig");
const Session = field_events.Session;
const Binding = field_events.Binding;
const Receipt = field_events.Receipt;

pub const Checkpoint = struct {
    session: Session,
    story: runtime.StoryState,
    position: field.Point,

    pub fn capture(session: Session, state: field.State) !Checkpoint {
        const story = state.progress.story.scenario orelse return error.MissingSourceStoryState;
        if (state.x != session.hero.x or state.y != session.hero.y) return error.FieldEventPositionMismatch;
        return .{ .session = session, .story = story, .position = .{ .x = state.x, .y = state.y } };
    }
    pub fn apply(self: Checkpoint, allocator: std.mem.Allocator, binding: Binding, target: *Session, state: *field.State) !void {
        const next = try rebind(self.session, allocator, binding);
        try next.validateStory(&self.story);
        if (!std.mem.eql(u8, self.story.schema, "suikoden-event-story/1") or self.position.x != next.hero.x or self.position.y != next.hero.y or self.position.x < 0 or self.position.y < 0 or self.position.x > 2040 or self.position.y > 2040 or @mod(self.position.x, 8) != 0 or @mod(self.position.y, 8) != 0) return error.InvalidFieldEventCheckpoint;
        var next_state_progress: field.game_state.Progress = undefined;
        var next_state = state.stageProgress(&next_state_progress);
        next_state.progress.story.scenario = self.story;
        next_state.progress.story.scenario.?.schema = "suikoden-event-story/1";
        try next_state.progress.validate();
        next_state.x = self.position.x;
        next_state.y = self.position.y;
        next_state.destination = self.position;
        next_state.walking = next.hero.moving();
        next_state.facing = next.facing;
        target.* = next;
        state.commitProgress(next_state);
    }
};

fn rebindWait(binding: Binding, pending: ?runtime.Wait) !?runtime.Wait {
    const value = pending orelse return null;
    for (binding.content.programs) |program| for (program.commands) |command| {
        for ([_]?runtime.Wait{ command.wait, command.requires }) |candidate| if (candidate) |wait| {
            if (wait.kind == value.kind and std.mem.eql(u8, wait.id, value.id)) {
                var result = value;
                result.id = wait.id;
                return result;
            }
        };
    };
    for ([_][]const u8{ "", "accept", "tracks", "dialogue_flags", "text_queue" }) |id| if (std.mem.eql(u8, id, value.id)) {
        var result = value;
        result.id = id;
        return result;
    };
    return error.InvalidFieldEventWait;
}

pub fn rebind(self: Session, allocator: std.mem.Allocator, binding: Binding) !Session {
    try self.validate(binding);
    var next = self;
    const multiple = for (next.other_tracks) |job| {
        if (job != null) break true;
    } else false;
    next.schema = if (next.retained_selection != null) (if (next.retained_selection.? == 2) "suikoden-field-event/22" else "suikoden-field-event/21") else if (next.reconstruction != null) "suikoden-field-event/18" else if (next.completed_event != null) "suikoden-field-event/17" else if (next.construction_ground_identity.len != 0) (if (std.mem.eql(u8, self.schema, "suikoden-field-event/20")) "suikoden-field-event/20" else if (std.mem.eql(u8, self.schema, "suikoden-field-event/19")) "suikoden-field-event/19" else "suikoden-field-event/16") else if (next.position_history != null) "suikoden-field-event/15" else if (next.audio_cached_command != null) "suikoden-field-event/14" else if (multiple) "suikoden-field-event/13" else if (next.ordinary_track != null) "suikoden-field-event/12" else "suikoden-field-event/11";
    if (next.construction_ground_identity.len != 0) next.construction_ground_identity = binding.ground.?.identity;
    if (next.audio_cached_command != null) next.audio_identity = binding.audio.?.identity;
    if (next.ordinary_track != null) next.movement_identity = binding.movement.?.identity;
    if (next.position_history) |*history| history.support_identity = binding.ground.?.identity;
    if (next.completed_event) |*completed| {
        completed.receipt.content_sha256 = binding.content.content_sha256;
        completed.receipt.program = binding.content.program(completed.receipt.program).?.id;
    }
    if (next.reconstruction) |*history| {
        for ([_]*Receipt{ &history.arrival.receipt, &history.followon.receipt }) |receipt| {
            receipt.content_sha256 = binding.content.content_sha256;
            receipt.program = binding.content.program(receipt.program).?.id;
        }
        const initializer_receipt = &history.arrival_initializer.receipt.?;
        initializer_receipt.content_sha256 = binding.content.content_sha256;
        initializer_receipt.program = binding.content.program(initializer_receipt.program).?.id;
    }
    next.context_sha256 = binding.context.content_sha256;
    if (next.ordinary_actors) |actors| {
        const jobs = next.tracks();
        const ownership: ?ordinary.PositionOwnership = if (next.position_history) |history| .{ .history = history, .instance = &next.instance.?, .serial = next.serial, .committed_batch = next.receipt.?.batch } else null;
        var descriptor_storage: [3]ordinary.Position = undefined;
        const descriptor_positions = try checks.descriptorInitializerPositions(&next, binding, &descriptor_storage);
        var scripted_storage: [64]ordinary.Position = undefined;
        const scripted_positions = try checks.scriptedActorPositions(&next, binding, &scripted_storage);
        if (next.room2_descriptor) |descriptor| {
            const position = [_]ordinary.Position{begin.room2ActorPosition(descriptor)};
            next.ordinary_actors = try actors.rebindTracksAtMany(binding.ordinary.?, binding.animations, binding.content, &jobs, ownership, &position);
        } else if (scripted_positions.len != 0) {
            if (descriptor_positions.len != 0 or ownership != null) return error.InvalidFieldActorPositionHistory;
            next.ordinary_actors = try actors.rebindTracksAtMany(binding.ordinary.?, binding.animations, binding.content, &jobs, null, scripted_positions);
        } else next.ordinary_actors = if (descriptor_positions.len != 0) try actors.rebindTracksAtMany(binding.ordinary.?, binding.animations, binding.content, &jobs, ownership, descriptor_positions) else try actors.rebindTracksAt(binding.ordinary.?, binding.animations, binding.content, &jobs, ownership, try checks.initializedPosition(&next, binding));
    }
    next.content_sha256 = binding.content.content_sha256;
    next.population_sha256 = binding.population.content_sha256;
    next.queue_sha256 = binding.queues.content_sha256;
    next.dialogue_sha256 = binding.dialogue.content_sha256;
    next.graphics_sha256 = if (binding.queues.graphics) |graphics| graphics.content_sha256 else "";
    next.hero_sha256 = binding.hero_sha256;
    if (next.text_job) |*job| job.state.id = binding.dialogue.texts[job.text].id;
    for (next.initializations[0..next.initialization_count]) |*record| {
        switch (record.*.?.kind) {
            .effect_ack => {
                const receipt = &record.*.?.receipt.?;
                receipt.content_sha256 = binding.content.content_sha256;
                receipt.program = binding.content.program(receipt.program).?.id;
            },
            .pure_pump => record.*.?.program = binding.content.program(record.*.?.program).?.id,
        }
    }
    if (next.instance) |*instance| {
        const program = binding.content.program(instance.program_id).?;
        const track_branches = binding.content.tracksBranchHistory(program);
        if ((instance.execution.path != null) != track_branches) return error.InvalidEventBranchHistory;
        instance.schema = if (track_branches) runtime.branch_state_schema else runtime.state_schema;
        instance.content_id = binding.content.id;
        instance.content_sha256 = binding.content.content_sha256;
        instance.program_id = program.id;
        if (next.receipt) |*receipt| {
            receipt.content_sha256 = binding.content.content_sha256;
            receipt.program = program.id;
        }
        instance.execution.wait = try rebindWait(binding, instance.execution.wait);
        if (instance.pending) |*pending| {
            pending.next.wait = try rebindWait(binding, pending.next.wait);
            for (pending.batch.effects[0..pending.batch.effect_count]) |*effect| {
                if (effect.origin >= program.commands.len) return error.InvalidEventCommand;
                var canonical = program.commands[effect.origin];
                canonical.origin = effect.origin;
                const expected = try std.json.Stringify.valueAlloc(allocator, canonical, .{});
                defer allocator.free(expected);
                const actual = try std.json.Stringify.valueAlloc(allocator, effect.*, .{});
                defer allocator.free(actual);
                if (!std.mem.eql(u8, expected, actual)) return error.FieldEventIdentityMismatch;
                effect.* = canonical;
            }
            for (pending.story_writes[0..pending.story_write_count]) |*write| write.flag.id = binding.content.storyValue(write.flag.id).?.id;
            @memset(pending.story_writes[pending.story_write_count..], .{ .flag = .{ .id = "", .mask = 0 } });
            @memset(pending.batch.effects[pending.batch.effect_count..], .{ .kind = .label });
        }
        if (next.pending_battle != null) next.pending_battle = instance.pendingBattle().?;
    }
    return next;
}

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
const begin_mod = @import("field_events_begin.zig");
const validate_mod = @import("field_events_validate.zig");
const playback_mod = @import("field_events_playback.zig");

pub fn finishInitialization(self: *Session, binding: Binding, story: *const runtime.StoryState) !void {
    const owner = self.instance orelse return error.InvalidFieldInitialization;
    const program = binding.content.program(owner.program_id) orelse return error.UnknownEventProgram;
    if (program.entry != .initialization) return error.InvalidFieldInitialization;
    if (owner.pending != null or owner.execution.wait != null) return error.UnsupportedInitializationPump;
    if (self.initialization_count == self.initializations.len) return error.TooManyFieldInitializers;
    const archived: Initialization = if (self.receipt) |receipt|
        .{ .entity = program.entity, .kind = .effect_ack, .receipt = receipt, .pump_pc = owner.execution.pc }
    else if (pureInitializationPump(program, &owner))
        .{ .entity = program.entity, .kind = .pure_pump, .program = program.id, .instance = self.serial, .pump_pc = owner.execution.pc }
    else
        return error.UnsupportedInitializationPump;
    if (archived.kind == .pure_pump) self.schema = "suikoden-field-event/20";
    self.initializations[self.initialization_count] = archived;
    self.initialization_count += 1;
    self.next_initialization = @as(u16, program.entity) + 1;
    self.serial = std.math.add(u64, self.serial, 1) catch return error.FieldEventSequenceOverflow;
    self.instance = null;
    self.receipt = null;
    try begin_mod.select(self, binding, story, .initialization, null);
    if (self.blocker != null or self.instance != null) return;
    self.initialization_done = true;
    self.next_initialization = @intCast(binding.population.entities.len);
    try begin_mod.select(self, binding, story, .area_entry, null);
}

// The original entry driver pumps each eligible initializer once, not until FD.
fn initialize(self: *Session, binding: Binding, state: *field.State, story: *runtime.StoryState) !void {
    while (self.instance != null) {
        const program = binding.content.program(self.instance.?.program_id).?;
        if (program.entry != .initialization) return error.InvalidFieldInitialization;
        if (!try playback_mod.pump(self, binding, state, story, .{})) return;
        try finishInitialization(self, binding, story);
        if (self.blocker != null or self.initialization_done) return;
    }
    if (self.initialization_done) return;
    self.initialization_done = true;
    self.next_initialization = @intCast(binding.population.entities.len);
    try begin_mod.select(self, binding, story, .area_entry, null);
}

// Host mutation, receipt, PC and the Progress-owned flag bank publish together.
pub noinline fn tick(self: *Session, binding: Binding, state: *field.State, confirm: bool) !Result {
    return self.tickPad(binding, state, if (confirm) 0x40 else 0, 0);
}

/// Consume source pad edges for text and choices.
/// The `held` word is accepted but not consumed until that host-owned text
/// clock is integrated; the text PC range returns UnsupportedRoom2NativeText.
pub noinline fn tickPad(self: *Session, binding: Binding, state: *field.State, pressed: u32, held: u32) !Result {
    _ = held;
    const confirm = pressed & 0x65 != 0;
    try validate_mod.validate(self, binding);
    if (self.completed_event != null) {
        const initial_story = state.progress.story.scenario orelse return error.MissingSourceStoryState;
        try self.validateStory(&initial_story);
    }
    if (self.blocker != null) return .blocked;
    if (self.instance == null) return .idle;
    if (self.instance.?.pendingBattle() != null or self.instance.?.pendingFixedDice() or self.instance.?.pendingPartySelect() or self.instance.?.pendingItemOverload()) return .running;
    if (!self.instance.?.execution.active and self.instance.?.pending == null) return .idle;
    var next = self.*;
    var next_state_progress: field.game_state.Progress = undefined;
    var next_state = state.stageProgress(&next_state_progress);
    var story = next_state.progress.story.scenario orelse return error.MissingSourceStoryState;
    if (!next.initialization_done) {
        try initialize(&next, binding, &next_state, &story);
    } else scene: {
        try next.startHeroDriver(binding);
        var completions: [12][]const u8 = undefined;
        var count: usize = 0;
        const aligned = next.alignment == null and (!binding.scripted_motion or !next.hero.moving());
        const pan_done = next.scripted_camera == null or next.scripted_camera.?.pan == null;
        if (aligned) {
            completions[count] = "alignment";
            count += 1;
        }
        if (pan_done) {
            completions[count] = "pan";
            count += 1;
        }
        if (next.party_queue == null or next.party_queue.?.active() == 0) {
            completions[count] = "text_queue";
            count += 1;
        }
        if (next.activeTracks() == 0 and (next.party_queue == null or next.party_queue.?.active() == 0)) {
            completions[count] = "tracks";
            count += 1;
        }
        if (!next.fade_state.active) {
            completions[count] = "fade";
            count += 1;
        }
        if (next.delay_remaining == 0) {
            completions[count] = "delay";
            count += 1;
        }
        const push_done = next.camera_push == null or !next.camera_push.?.model.active();
        if (push_done) {
            completions[count] = "camera_push";
            count += 1;
            if (next.camera_push != null) {
                next.camera_push = null;
                next.scripted_camera = null;
            }
        }
        if (next.field_effect == null or next.field_effect.?.model.clock.callback == null) {
            completions[count] = "field_effect";
            count += 1;
        }
        for (next.boxes, [_][]const u8{ "box_0", "box_1" }) |box, id| if (box.phase == .closed) {
            completions[count] = id;
            count += 1;
        };
        if (!next.boxes[0].changing() and !next.boxes[1].changing()) {
            completions[count] = "dialogue_flags";
            count += 1;
        }
        if (next.text_job) |job| if ((job.kind == .prefix and job.state.done) or job.kind == .body_done) {
            completions[count] = if (job.kind == .prefix) (if (job.box == 0) "box_0" else "box_1") else binding.dialogue.texts[job.text].id;
            count += 1;
        };
        var choice: u8 = 0;
        var choice_confirmed = false;
        if (next.instance) |*instance| if (instance.execution.wait) |wait| {
            if (wait.kind == .choice) {
                const slot = instance.choiceBox(binding.content) orelse return error.InvalidFieldChoices;
                const options = instance.choiceOptions(binding.content) orelse return error.InvalidFieldChoices;
                if (slot > 1 or options < 2 or options > 4 or next.boxes[slot].phase != .open) return error.InvalidFieldChoices;
                switch (pressed & 0x5041) {
                    0x1000 => instance.execution.choice = @intCast((@as(u16, instance.execution.choice) + options - 1) % options),
                    0x4000 => instance.execution.choice = @intCast((@as(u16, instance.execution.choice) + 1) % options),
                    0x40, 0x41 => choice_confirmed = true,
                    else => {},
                }
                choice = instance.execution.choice;
            }
        };
        const movement_active = if (next.room2_descriptor) |descriptor| descriptor.movement != null else false;
        const text_owned = if (next.instance) |instance| std.mem.eql(u8, next.schema, "suikoden-field-event/22") and
            ((instance.execution.pc >= 8 and instance.execution.pc <= 13) or (instance.execution.pc >= 29 and instance.execution.pc <= 34)) else false;
        if (!movement_active and text_owned) {
            // The native room-2 text clock needs a host-owned TextState.
            // Storing it inline would grow the field-event Session past
            // the accepted stack budget, so this path is an exact blocker
            // rather than a second, unsaved text owner.
            return error.UnsupportedRoom2NativeText;
        } else if (!movement_active and (next_state.wheel_state == null or next_state.wheel_state.?.clock.phase == null)) _ = try playback_mod.pump(&next, binding, &next_state, &story, .{
            .confirm = confirm,
            .wheel_outcome = if (next_state.wheel_state) |wheel| if (wheel.clock.phase == null and wheel.clock.result != null) @backingInt(wheel.clock.result.?) else null else null,
            .choice = choice,
            .choice_confirmed = choice_confirmed,
            .completions = completions[0..count],
            .alignment_ready = if (binding.scripted_motion) aligned else null,
            .mode_ready = !binding.scripted_motion or (aligned and pan_done and push_done),
            .room_transition_ready = if (binding.room_package != null) aligned and pan_done and push_done else null,
        });
        if (next.queuedGameplayRequest() != null) {
            self.* = next;
            return .running;
        }
        if (next_state.room_entries != state.room_entries) break :scene;
        if (next.room2_descriptor) |*descriptor| if (descriptor.movement) |saved_movement| {
            if (descriptor.movement_frames == 28) {
                self.blocker = .{ .entity = 2, .command = 2, .reason = .unimplemented_effect };
                return .blocked;
            }
            var movement_owner = try room2_movement.Owner.restore(saved_movement);
            const proposal = try movement_owner.proposeTick(@as(u64, movement_owner.state.checkpoint) + 1);
            if (proposal.attempt) |attempt| {
                if (attempt.source_offset != 0x3d17c or attempt.selector != 0 or attempt.direction != 0) return error.InvalidFieldEventReceipt;
                const packet = binding.ordinary orelse return error.MissingFieldActorConstruction;
                const actors = if (next.ordinary_actors) |*present| present else return error.MissingFieldActorConstruction;
                const avatar = try actors.actor(packet, "scene_actor_0");
                if (avatar.motion.moving() or avatar.support != null) return error.InvalidFieldActorState;
                avatar.motion.speed = 2;
                avatar.motion.step(.down);
                avatar.pose = null;
            }
            try movement_owner.commit(proposal);
            descriptor.movement = movement_owner.state;
            descriptor.movement_frames += 1;
        };
        if (try next.fade_state.tick()) if (next.hero_descriptor_state) |*retained| {
            retained.tint_word = if (next.fade_state.direction == .from_black) 0x80 else 0;
        };
        if (next.delay_remaining != 0) next.delay_remaining -= 1;
        for (&next.boxes) |*box| box.tick();
        if (next.text_job) |*job| if (next.boxes[job.box].phase == .open and (job.kind == .prefix or job.kind == .body)) {
            const text = binding.dialogue.texts[job.text];
            const player_name = binding.player_name orelse if (std.mem.indexOfScalar(u8, binding.party, 8)) |hero_index| next_state.progress.party.at(hero_index).name else "";
            if (player_name.len == 0) for (text.tokens) |token| {
                if (token.kind == .player_name) return error.MissingSourcePartyIdentity;
            };
            try job.state.tick(text, player_name);
        };
        if (next.alignment) |*alignment| {
            if (alignment.tick()) |direction| {
                next.hero.step(direction);
                const previous_primary = next.hero_sprite.?.variant;
                next.hero_sprite.?.select(binding.hero_animation, direction, true);
                if (next.hero_sprite.?.variant != previous_primary) try next.resetHeroAux(binding, next.hero_sprite.?.variant);
                next.facing = switch (direction) {
                    .down => .down,
                    .up => .up,
                    .left => .left,
                    .right => .right,
                };
            }
            if (!alignment.active()) next.alignment = null;
        }
        if (next.scripted_camera) |*camera| if (camera.pan) |*pan| {
            if (pan.tick(&camera.scroll)) camera.pan = null;
        };
        var hero_queued = false;
        if (next.ordinary_track != null) {
            const access = binding.movement orelse return error.MissingFieldMovementAccess;
            if (!access.event_active) return error.MissingFieldMovementAccess;
            var job = next.ordinary_track.?;
            hero_queued = job.actor == 255 and job.state.active;
            try next.tickTrack(binding, &job, access);
            next.ordinary_track = job;
            for (&next.other_tracks) |*entry| if (entry.*) |*current| {
                var candidate = current.*;
                if (candidate.actor == 255 and candidate.state.active) hero_queued = true;
                try next.tickTrack(binding, &candidate, access);
                current.* = candidate;
            };
            if (hero_queued) next.movement_camera = next.heroTrackCamera(binding);
        }
        if (next.camera_push) |*push| if (push.model.advance(&next.hero)) |frame| {
            const room = (binding.room_package orelse return error.MissingFieldRoomPackage).rooms[next_state.room];
            const scroll = field.sourceCameraScroll(room.width, room.height, frame.camera_target_x, frame.camera_target_y);
            next.scripted_camera = .{ .scroll = .{ .x = scroll.x, .y = scroll.y }, .absolute = true };
            for (0..frame.forced_animation_steps) |_| {
                next.hero_sprite.?.animation.tick(binding.hero_animation.clips[next.hero_sprite.?.variant]);
                try next.tickHeroAux(binding, 1);
                try next.drawHeroAux(binding);
            }
        };
        if (next.hero_sprite) |*sprite| {
            var avatar: motion.Avatar = .{ .id = "hero", .graphic = "hero", .motion = next.hero, .variant = sprite.variant, .orientation_flags = next.hero_flags, .sprite = sprite.animation, .attached = true };
            const ticks = avatar.fieldTickAnimationCount(binding.hero_animation, true, .{ .camera = .{ .x = 0, .y = 0 }, .allow_player_animation = (next.alignment != null or hero_queued) and (next.hero_descriptor_state == null or next.hero_descriptor_state.?.tint_word == 0x80), .hero_speed = next.hero.speed });
            try next.tickHeroAux(binding, ticks);
            try next.drawHeroAux(binding);
            next.hero = avatar.motion;
            sprite.animation = avatar.sprite;
            sprite.emitted_frame = avatar.pose.?.frame;
            const display = next_state.scene_view.hero orelse field.Point{ .x = avatar.pose.?.x, .y = avatar.pose.?.y };
            sprite.emitted_x = display.x;
            sprite.emitted_y = display.y;
        }
        if (next.ordinary_actors) |*actors| {
            if (next.ordinary_track != null) {
                try actors.tickCamera(binding.ordinary.?, binding.animations, next.movement_camera.?);
            } else if (binding.movement) |access| {
                try actors.tickCamera(binding.ordinary.?, binding.animations, access.camera);
            } else try actors.tick(binding.ordinary.?, binding.animations);
        }
        next_state.x = next.hero.x;
        next_state.y = next.hero.y;
        next_state.destination = .{ .x = next.hero.x, .y = next.hero.y };
        next_state.walking = next.hero.moving();
        next_state.facing = next.facing;
        if (next.party_queue) |*queue| try queue.tickTracks(binding.queues, binding.content);
        if (next.text_job) |*job| {
            if (job.kind == .body_staged) job.kind = .body;
            if (job.kind == .body) {
                const configuration = binding.dialogue.configuration[@backingInt(next.text_speed)];
                if (confirm and job.state.page_wait and binding.dialogue.allow_pages) {
                    job.state.acknowledge();
                } else if (confirm and job.current_pace != configuration.pressed_pace) {
                    job.current_pace = configuration.pressed_pace;
                    job.state.fast = true;
                } else job.current_pace = configuration.normal_pace;
                if (job.state.done) job.kind = .body_done;
            }
        }
    }
    // The original driver invokes its area callback after script, motion and text.
    if (next_state.room_entries == state.room_entries and next.field_effect != null)
        try next.advanceFieldEffect(next_state, binding.room_package orelse return error.MissingFieldRoomPackage);
    next_state.progress.story.scenario = story;
    try next.validateStory(&story);
    self.* = next;
    state.commitProgress(next_state);
    if (next.blocker != null) return .blocked;
    return if (next.instance != null and next.instance.?.execution.active) .running else .completed;
}

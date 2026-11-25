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
const room2DescriptorBinding = begin_mod.room2DescriptorBinding;
const select = begin_mod.select;
const checks = @import("field_events_validate_checks.zig");
const descriptorInitializerPositions = checks.descriptorInitializerPositions;
const validate = @import("field_events_validate.zig").validate;

fn battleRequest(self: *const Session) ?events.BattleRequest {
    const owner = if (self.instance) |*value| value else return null;
    const id = owner.pendingBattle() orelse return null;
    const command = owner.pending.?.batch.effects[0];
    return .{ .id = id, .defeat_target = command.defeat_target, .defeat_ends_run = command.defeat_ends_run, .receipt = .{
        .content_sha256 = owner.content_sha256,
        .program = owner.program_id,
        .instance = self.serial,
        .batch = owner.pending.?.batch.id,
    } };
}

pub fn queuedBattle(self: *const Session) ?events.BattleRequest {
    const id = self.pending_battle orelse return null;
    const request = battleRequest(self) orelse return null;
    return if (std.mem.eql(u8, id, request.id)) request else null;
}

pub fn takeBattle(self: *Session) ?events.BattleRequest {
    const request = queuedBattle(self) orelse return null;
    self.pending_battle = null;
    return request;
}

pub fn queuedFixedDice(self: *const Session) ?events.Receipt {
    const owner = if (self.instance) |*value| value else return null;
    if (!owner.pendingFixedDice()) return null;
    return .{
        .content_sha256 = owner.content_sha256,
        .program = owner.program_id,
        .instance = self.serial,
        .batch = owner.pending.?.batch.id,
    };
}

pub fn queuedItemOverload(self: *const Session) ?struct { item_name: []const u8, receipt: events.Receipt } {
    const owner = self.instance orelse return null;
    if (!owner.pendingItemOverload()) return null;
    return .{ .item_name = owner.pending.?.batch.effects[0].item_name.?, .receipt = .{
        .content_sha256 = owner.content_sha256,
        .program = owner.program_id,
        .instance = self.serial,
        .batch = owner.pending.?.batch.id,
    } };
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
    const owner = if (self.instance) |*value| value else return null;
    if (!owner.pendingPartySelect()) return null;
    return .{ .content_sha256 = owner.content_sha256, .program = owner.program_id, .instance = self.serial, .batch = owner.pending.?.batch.id };
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
    const owner = if (self.instance) |*value| value else return null;
    const pending = owner.pending orelse return null;
    if (pending.batch.effect_count != 1 or pending.batch.effects[0].kind != .field_music) return null;
    return pending.batch.effects[0].music;
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

pub fn resumeBattle(self: *Session, binding: Binding, state: *field.State, completed: events.BattleRequest, outcome: events.BattleOutcome) !void {
    try validate(self, binding);
    const request = battleRequest(self) orelse return error.InvalidFieldBattleReceipt;
    if (self.pending_battle != null or !semanticEqual(request, completed)) return error.InvalidFieldBattleReceipt;
    var story = state.progress.story.scenario orelse return error.MissingSourceStoryState;
    try self.validateStory(&story);
    const continuation: ?u16 = switch (outcome) {
        .victory => null,
        .escape => self.instance.?.pending.?.batch.effects[0].escape_target,
        .defeat => request.defeat_target orelse return error.MissingFieldDefeatContinuation,
    };
    const battle_command = self.instance.?.pending.?.batch.effects[0].origin;
    try runtime.acknowledge(binding.content, &self.instance.?, &story, request.receipt.batch);
    if (continuation) |target| {
        try self.instance.?.redirect(binding.content, battle_command, target);
        self.instance.?.execution.wait = null;
    }
    self.receipt = request.receipt;
    state.progress.story.scenario = story;
}

// The recipient must deduplicate the stable (scene, instance, batch, origin) key.
pub fn acknowledgeAudio(self: *Session, binding: Binding, batch: u64, origin: u16) !void {
    try validate(self, binding);
    const request = self.audio_request orelse return error.MissingFieldAudioRequest;
    if (request.batch != batch or request.origin != origin) return error.InvalidFieldAudioReceipt;
    self.audio_request = null;
}

pub noinline fn apply(self: *Session, binding: Binding, command: runtime.Command, state: *field.State) !bool {
    switch (command.kind) {
        .camera_push => {
            if (!binding.content.hasCameraPush() or !binding.scripted_motion or !self.selected_program or !self.initialization_done or binding.room_package == null)
                return false;
            if (self.camera_push != null or self.alignment != null or self.activeTracks() != 0 or
                (self.scripted_camera != null and self.scripted_camera.?.pan != null)) return error.FieldEventBusy;
            const start: motion.Point = .{ .x = self.hero.x, .y = self.hero.y };
            self.camera_push = .{ .command = command.origin, .start = start, .model = try runtime.camera_push.State.begin(command.push.?, &self.hero) };
        },
        .hide_hero => {
            if (!binding.content.hasHeroVisibility() or !self.initialization_done or self.hero.moving()) return false;
        },
        .wheel_restore, .wheel_turn, .wheel_align => {
            if (!binding.content.hasWheelMotion() or !self.initialization_done or binding.room_package == null) return false;
            if (state.wheel_state == null and command.kind == .wheel_turn) state.wheel_state = .{};
            const wheel = if (state.wheel_state) |*present| present else return error.MissingWheelState;
            if (wheel.clock.phase != null) return error.WheelStillActive;
            switch (command.kind) {
                .wheel_restore => wheel.clock.restore(),
                .wheel_turn => {
                    wheel.clock.turnFor(@intCast(command.updates.?));
                    wheel.sample = .{};
                },
                .wheel_align => wheel.clock.alignToCenter(),
                else => unreachable,
            }
        },
        .field_effect => {
            if (!self.initialization_done or binding.room_package == null or !binding.content.hasFieldEffects()) return false;
            if (self.field_effect) |effect| if (effect.model.clock.callback != null) return error.FieldEffectStillActive;
            self.field_effect = .{
                .command = command.origin,
                .position = .{ .x = command.x.?, .y = command.y.? },
                .model = field.area_effect.Effect.init(command.effect.?),
            };
        },
        .field_music => {
            if (self.instance == null or binding.content.program(self.instance.?.program_id).?.entry != .initialization or command.music != .headquarters) return false;
            state.music = .headquarters;
        },
        .set_camera => {
            if (!binding.content.hasFadeIn() or !self.initialization_done) return false;
            self.scripted_camera = .{ .scroll = .{ .x = command.x.?, .y = command.y.? }, .absolute = true };
        },
        .align_hero => self.alignment = try motion.Alignment.start(self.hero.x, self.hero.y, command.x.?, command.y.?),
        .place_hero => {
            const package = binding.room_package orelse return false;
            const x = command.x.?;
            const y = command.y.?;
            const scenery = if (state.room_scenery) |*value| value else null;
            if (!package.rooms[state.room].canStandWithScenery(scenery, x, y)) return error.InvalidFieldEventTransition;
            self.hero = .{ .x = x, .y = y, .speed = self.hero.speed };
            state.x = x;
            state.y = y;
            state.destination = .{ .x = x, .y = y };
        },
        .pan => {
            if (!binding.scripted_motion or !self.selected_program) return false;
            var camera: @import("field_events_state.zig").ScriptedCamera = self.scripted_camera orelse .{};
            camera.pan = .{ .dx = command.dx.?, .dy = command.dy.?, .remaining = command.updates.? };
            try camera.validate();
            self.scripted_camera = camera;
        },
        .spawn_actor => {
            if (!binding.content.hasSceneActors()) return false;
            const packet = binding.ordinary orelse return false;
            const actors = if (self.ordinary_actors) |*value| value else return false;
            try actors.spawn(packet, binding.animations, command.actor.?);
        },
        .release_actor => {
            // Ordinary and scene-owned actors share animation and movement ownership.
            if (!binding.content.hasActorPositions()) return false;
            const packet = binding.ordinary orelse return false;
            const actors = if (self.ordinary_actors) |*value| value else return false;
            const avatar = actors.actor(packet, command.actor.?) catch return false;
            if (avatar.support != null or avatar.motion.moving()) return false;
            const jobs = self.tracks();
            for (jobs) |job| if (job != null and job.?.state.active and std.mem.eql(u8, binding.content.tracks[job.?.track].actor, command.actor.?)) return false;
            try actors.release(packet, command.actor.?);
        },
        .place_actor => {
            if (!binding.content.hasActorPositions()) return false;
            const packet = binding.ordinary orelse return false;
            const actors = if (self.ordinary_actors) |*value| value else return false;
            const jobs = self.tracks();
            for (jobs) |job| if (job != null and job.?.state.active and std.mem.eql(u8, binding.content.tracks[job.?.track].actor, command.actor.?)) return false;
            actors.place(packet, command.actor.?, command.x, command.y) catch |err| switch (err) {
                error.UnknownFieldActor, error.FieldActorNotConstructed, error.FieldActorReleased, error.FieldActorGraphicsUnavailable, error.FieldActorBusy => return false,
                else => return err,
            };
        },
        .actor_x, .actor_y => {
            const access = binding.ground orelse return false;
            const initializer = std.mem.eql(u8, self.schema, "suikoden-field-event/16") and std.mem.eql(u8, self.instance.?.program_id, "vb6_r06_init_08");
            if (access.identity.len == 0 or (!initializer and ((!std.mem.eql(u8, binding.content.id, "vb6_room6_e7") and !std.mem.eql(u8, self.schema, "suikoden-field-event/17")) or !std.mem.eql(u8, self.instance.?.program_id, "vb6_r06_entity07_followon")))) return false;
            const batch = self.instance.?.pending.?.batch.id;
            const packet = binding.ordinary orelse return false;
            const actors = if (self.ordinary_actors) |*value| value else return false;
            const slot = for (packet.actors, 0..) |definition, index| {
                if (std.mem.eql(u8, definition.id, command.actor.?)) break index;
            } else return false;
            const avatar = actors.actor(packet, command.actor.?) catch return false;
            if (avatar.support != null or avatar.motion.moving() or access.ground_fn(access.context, avatar.id, avatar.motion) != true) return false;
            var next_motion = avatar.motion;
            if (command.kind == .actor_x) next_motion.x = @as(i32, command.value.?) * 8 else next_motion.y = @as(i32, command.value.?) * 8;
            if (access.ground_fn(access.context, avatar.id, next_motion) != true) return false;
            if (initializer) {
                if (batch != 1 or self.position_history != null or (command.kind == .actor_x and (command.origin != 1 or command.value != 24)) or (command.kind == .actor_y and (command.origin != 2 or command.value != 25))) return false;
            } else if (command.kind == .actor_x) {
                if (command.origin != 0 or batch != 1 or self.position_history != null) return false;
                self.position_history = .{ .actor = @intCast(slot), .instance = self.serial, .x_batch = batch, .support_identity = access.identity };
            } else {
                if (command.origin != 1 or batch != 2 or self.position_history == null or self.position_history.?.actor != slot or !std.mem.eql(u8, self.position_history.?.support_identity, access.identity)) return false;
                self.position_history.?.y_batch = batch;
            }
            avatar.motion = next_motion;
            avatar.pose = null;
            if (!initializer and !std.mem.eql(u8, self.schema, "suikoden-field-event/17")) self.schema = "suikoden-field-event/15";
        },
        .actor_transition, .source_hero_transition => {
            if (command.kind == .actor_transition and !std.mem.eql(u8, command.actor.?, "hero")) {
                if (runtime.partyActorIndex(command.actor.?)) |index| {
                    if (!binding.content.hasPartyScene() or !std.mem.eql(u8, binding.dialogue.schema, events.DialogueData.party_schema) or !binding.queues.isRoom()) return false;
                    const queue = if (self.party_queue) |*value| value else return false;
                    if (index >= queue.count) return false;
                    const direction = ([_]motion.Direction{ .down, .up, .left, .right })[command.transition.?];
                    try queue.followers[index].?.selectFacing(binding.queues.graphics, direction, false);
                    return true;
                }
                const packet = binding.ordinary orelse return false;
                const actors = if (self.ordinary_actors) |*value| value else return false;
                actors.transition(packet, binding.animations, command.actor.?, command.transition.?) catch |err| switch (err) {
                    error.UnknownFieldActor, error.FieldActorNotConstructed, error.FieldActorReleased => return false,
                    else => return err,
                };
                return true;
            }
            const transition: u2 = if (command.kind == .source_hero_transition) ([_]u2{ 1, 3, 0, 2 })[command.transition.?] else command.transition.?;
            const direction: motion.Direction = switch (transition) {
                0 => .down,
                1 => .up,
                2 => .left,
                3 => .right,
            };
            const previous_primary = self.hero_sprite.?.variant;
            self.hero_sprite.?.select(binding.hero_animation, direction, false);
            if (self.hero_descriptor_state) |*retained| {
                const source = binding.hero_descriptor orelse return error.MissingHeroDescriptorContext;
                if (try retained.auxiliary.opcode11(binding.hero_animation, previous_primary, @intCast(self.hero_sprite.?.variant), source.room_byte7, retained.tint_word)) |attr| retained.primary_attr_18 = attr;
            }
            self.hero_flags = switch (transition) {
                0 => self.hero_flags & 2,
                1 => self.hero_flags | 1,
                2 => self.hero_flags & 1,
                3 => self.hero_flags | 2,
            };
            self.facing = switch (direction) {
                .down => .down,
                .up => .up,
                .left => .left,
                .right => .right,
            };
        },
        .queue_track => {
            const track = binding.content.track(command.track.?) orelse return false;
            if (runtime.partyActorIndex(track.actor) != null) {
                if (!binding.context.party_queue or !binding.queues.isRoom() or !self.selected_program) return false;
                const queue = if (self.party_queue) |*queue| queue else return false;
                return queue.startTrack(binding.content, command.track.?);
            }
            const access = binding.movement orelse return false;
            if (!access.event_active or (!self.selected_program and !std.mem.eql(u8, self.schema, "suikoden-field-event/17"))) return false;
            const slot = self.activeTracks();
            if (slot >= 30) return false;
            var jobs = self.tracks();
            if (jobs[slot]) |prior| {
                const prior_id = binding.content.tracks[prior.track].actor;
                if (prior.state.active) return false;
                if (!std.mem.eql(u8, prior_id, track.actor)) {
                    const retained = for (jobs, 0..) |job, i| {
                        if (i == slot) continue;
                        if (job) |entry| {
                            const id = binding.content.tracks[entry.track].actor;
                            if (std.mem.eql(u8, id, track.actor)) {
                                if (entry.state.active) return false;
                                break i;
                            }
                        }
                    } else for (jobs, 0..) |job, i| {
                        if (i != slot and job == null) break i;
                    } else return false;
                    jobs[retained] = prior;
                    jobs[slot] = null;
                }
            }
            for (jobs, 0..) |job, i| if (i != slot and job != null) {
                const existing_id = binding.content.tracks[job.?.track].actor;
                if (std.mem.eql(u8, existing_id, track.actor)) return false;
            };
            const next_job = if (std.mem.eql(u8, track.actor, "hero")) blk: {
                var hero = self.heroAvatar();
                const job = try ordinary.TrackJob.startHero(&hero, binding.content, command.track.?);
                self.setHeroAvatar(hero);
                break :blk job;
            } else blk: {
                const actors = if (self.ordinary_actors) |*value| value else return false;
                const packet = binding.ordinary orelse return false;
                break :blk ordinary.TrackJob.start(actors, packet, binding.content, command.track.?) catch |err| switch (err) {
                    error.UnknownFieldActor, error.FieldActorNotConstructed, error.FieldActorReleased => return false,
                    else => return err,
                };
            };
            if (access.identity.len == 0 or access.identity.len > 128 or access.camera.x < 0 or access.camera.y < 0 or access.camera.x > 2040 or access.camera.y > 2040) return error.InvalidFieldActorState;
            jobs[slot] = next_job;
            self.ordinary_track = jobs[0];
            @memcpy(&self.other_tracks, jobs[1..]);
            self.movement_identity = access.identity;
            if (self.movement_camera == null) self.movement_camera = access.camera;
            self.schema = if (self.completed_event != null) "suikoden-field-event/17" else if (self.position_history != null) "suikoden-field-event/15" else if (self.audio_cached_command != null) "suikoden-field-event/14" else if (for (self.other_tracks) |job| {
                if (job != null) break true;
            } else false) "suikoden-field-event/13" else "suikoden-field-event/12";
        },
        .delay, .source_timer => {
            const duration = command.updates orelse return false;
            if (duration == 0 or self.delay_remaining != 0) return false;
            self.delay_remaining = duration;
        },
        .cue => {
            const access = binding.audio orelse return false;
            const previous = access.initial_cached_command orelse return false;
            if (!self.selected_program or !std.mem.eql(u8, self.instance.?.program_id, "vaa_room2_audience") or command.origin != 28 or command.cue != 0x422 or access.identity.len != 64 or !std.mem.eql(u8, access.audience_path, "audience.wav") or self.audio_cached_command != null or self.audio_request != null) return false;
            self.audio_identity = access.identity;
            self.audio_cached_command = 0x422;
            self.area_command = 0x422;
            if (previous != 0x422) self.audio_request = .{ .batch = self.instance.?.pending.?.batch.id, .command = 0x422, .origin = command.origin, .track = .audience };
            self.schema = "suikoden-field-event/14";
        },
        .play_sound => {
            if (binding.room_package == null) return false;
            self.sound_effect = command.cue.?;
        },
        .show_prop => {
            if (!binding.content.hasProps() or binding.room_package == null) return false;
            state.shown_props |= @as(u64, 1) << command.prop.?;
        },
        .scenery_stage, .scenery_restore, .scenery_append => {
            if (!binding.content.hasSceneryMutations() or !self.initialization_done) return false;
            const package = binding.room_package orelse return false;
            try package.rooms[state.room].mutateScenery(&state.room_scenery, command);
        },
        .area_action => {
            const action = command.area.?;
            if (binding.room_package == null) return false;
            if (action.kind == .room_flag) {
                try state.local_flags.orByte(action.id, action.bits);
            } else if (action.isAuxiliaryPartyEdit()) {
                var auxiliary = state.auxiliary_party orelse return error.MissingAuxiliaryPartyState;
                field.editAuxiliaryParty(&auxiliary, action.kind == .auxiliary_party_add, action.character);
                state.auxiliary_party = auxiliary;
            } else return false;
        },
        .request_area_party_prefix => {
            if (command.requested_prefix.?.len > self.active_party_count) return false;
            const previous = self.area_party;
            self.area_party = @splat(255);
            var count: usize = 0;
            for (command.requested_prefix.?) |id| {
                if (count == self.area_party.len) return error.InvalidAreaPartyPrefix;
                self.area_party[count] = id;
                count += 1;
            }
            for (previous) |id| {
                if (id == 255 or std.mem.indexOfScalar(u8, command.requested_prefix.?, id) != null) continue;
                if (count >= self.active_party_count) break;
                self.area_party[count] = id;
                count += 1;
            }
        },
        .queue_glyphs_a, .queue_glyphs_b => {
            if (!binding.context.party_queue) return false;
            if (self.hero.x != binding.queues.anchor.x or self.hero.y != binding.queues.anchor.y or self.hero.moving() or self.alignment != null) return error.UnsupportedFieldPartyAnchor;
            if (command.kind == .queue_glyphs_a) {
                if (self.party_queue != null) return error.FieldPartyQueueBusy;
                if (self.active_party_count > 1) {
                    self.party_queue = .{ .facing = self.facing, .count = self.active_party_count - 1 };
                    for (self.party_queue.?.followers[0 .. self.active_party_count - 1], 0..) |*slot, index| {
                        const character = self.area_party[index + 1];
                        slot.* = .{ .character = character, .position = .{ .x = self.hero.x, .y = self.hero.y, .speed = 2 }, .track = .{ .saved_motion = 2 } };
                        if (binding.queues.graphics) |graphics| if (graphics.resource(character)) |resource| {
                            if (std.mem.indexOfScalar(u8, self.source_party[0..self.active_party_count], character) != null) slot.*.?.sprite = .{ .animation = motion.SpriteAnimation.start(resource.clips[0]), .emitted_x = self.hero.x, .emitted_y = self.hero.y };
                        };
                    }
                }
            } else if (self.party_queue) |*queue| {
                if (queue.active() != 0 or queue.phase != .spread) return error.FieldPartyQueueBusy;
                if (queue.facing != self.facing) return error.UnsupportedFieldPartyAnchor;
                queue.phase = .returning;
                queue.facing = self.facing;
                for (queue.followers[0..queue.count]) |*slot| {
                    slot.*.?.position.offset_x = 0;
                    slot.*.?.position.offset_y = 0;
                    slot.*.?.custom_track = null;
                    slot.*.?.track = .{ .saved_motion = 2 };
                }
            } else if (self.active_party_count != 1) return error.MissingFieldPartyQueue;
        },
        .open_fixed_box => {
            if (!binding.content.hasFixedBoxes()) return false;
            const box = &self.boxes[command.box.?];
            if (box.phase != .closed) return error.FieldDialogueBusy;
            box.* = .{ .phase = .opening, .transition = 20, .fixed = .{ .x = command.x.?, .y = command.y.?, .w = command.width.?, .h = command.height.? } };
            self.sound_effect = @import("audio_route").SoundContent.window_open;
        },
        .open_box => {
            const definition = for (binding.dialogue.anchors) |anchor| {
                if (anchor.command == command.origin and std.mem.eql(u8, anchor.program, self.instance.?.program_id)) break anchor;
            } else return false;
            if (self.boxes[definition.box].phase != .closed) return error.FieldDialogueBusy;
            if (definition.interaction_actor != null) {
                const program = binding.content.program(self.instance.?.program_id) orelse return false;
                const actors = if (self.ordinary_actors) |*value| value else return false;
                const point = binding.interactionPosition(program.entity, actors) orelse return error.IneligibleFieldInteraction;
                self.boxes[definition.box] = .{ .phase = .opening, .transition = 20, .anchor = .{ .x = point.x + 8, .y = point.y - 24 } };
                if (binding.content.hasFixedBoxes()) self.sound_effect = @import("audio_route").SoundContent.window_open;
                return true;
            }
            if (definition.point) |point| {
                self.boxes[definition.box] = .{ .phase = .opening, .transition = 20, .anchor = .{ .x = point.x + 8, .y = point.y - 24 } };
                if (binding.content.hasFixedBoxes()) self.sound_effect = @import("audio_route").SoundContent.window_open;
                return true;
            }
            const actor = if (definition.actor) |id| blk: {
                if (std.mem.eql(u8, id, "hero") and command.actor != null) break :blk self.hero;
                const packet = binding.ordinary orelse return false;
                const actors = if (self.ordinary_actors) |*value| value else return false;
                if (command.actor == null) {
                    const layout = command.layout orelse return false;
                    const avatar = actors.actorAtLayout(packet, layout, id) catch return false;
                    break :blk avatar.motion;
                }
                const avatar = actors.actor(packet, id) catch return false;
                break :blk avatar.motion;
            } else blk: {
                const queue = self.party_queue orelse return error.MissingFieldPartyQueue;
                if (definition.follower.? >= queue.count or queue.active() != 0) return error.InvalidFieldDialogue;
                break :blk queue.followers[definition.follower.?].?.position;
            };
            self.boxes[definition.box] = .{ .phase = .opening, .transition = 20, .anchor = .{ .x = actor.x + 8, .y = actor.y - 24 } };
            if (binding.content.hasFixedBoxes()) self.sound_effect = @import("audio_route").SoundContent.window_open;
        },
        .close_box => {
            const box = &self.boxes[command.box.?];
            if (box.phase != .open) return error.FieldDialogueBusy;
            box.phase = .closing;
            box.transition = 20;
            box.image = null;
            if (self.text_job != null and self.text_job.?.box == command.box.?) self.text_job = null;
        },
        .start_or_wait_dialogue, .speaker => {
            const prefix = binding.dialogue.prefixFor(self.instance.?.program_id, command.origin) orelse return false;
            const box = &self.boxes[prefix.box];
            if (box.phase == .closed or box.phase == .closing) return error.FieldDialogueBusy;
            if (prefix.text != null and self.text_job != null and !self.text_job.?.state.done) return error.FieldDialogueBusy;
            // The original image lookup leaves its descriptor unchanged when no custom/loaded character matches.
            if (prefix.absent_character) |character| if (std.mem.indexOfScalar(u8, self.source_party[0..self.active_party_count], character) != null) return false;
            if (prefix.image) |image| {
                const resource = binding.dialogue.images[image];
                const loaded = resource.domain != .active_party or std.mem.indexOfScalar(u8, self.source_party[0..self.active_party_count], resource.character) != null;
                if (!loaded and resource.atlas_rect == null) return false;
                if (resource.domain == .area_custom and resource.resource == null) return false;
                if (loaded) box.image = image;
            }
            if (prefix.text) |text| {
                box.speaker = text;
                self.text_job = .{ .box = prefix.box, .text = text, .state = motion.TextState.start(binding.dialogue.texts[text], 0) };
            }
        },
        .text => {
            const index = for (binding.dialogue.texts, 0..) |text, i| {
                if (std.mem.eql(u8, text.id, command.text.?)) break i;
            } else return false;
            for (binding.dialogue.texts[index].tokens) |token| switch (token.kind) {
                .glyph, .newline, .countdown, .pace => {},
                .page => if (!binding.dialogue.allow_pages) return false,
                .player_name => if (!binding.dialogue.allow_substitution) return false,
            };
            if (self.text_job != null and !self.text_job.?.state.done) return error.FieldDialogueBusy;
            const pace = binding.dialogue.configuration[@backingInt(self.text_speed)].normal_pace;
            self.text_job = .{ .box = command.box.?, .text = @intCast(index), .state = motion.TextState.start(binding.dialogue.texts[index], pace), .kind = .body_staged, .current_pace = pace };
        },
        .choice => {
            const slot = command.box.?;
            const job = if (self.text_job) |*job| job else return error.FieldDialogueBusy;
            if (self.boxes[slot].phase != .open) return error.FieldDialogueBusy;
            if (!job.hasChoiceRows(slot)) return error.InvalidFieldChoices;
        },
        .source_move_batch => {
            if (!std.mem.eql(u8, self.schema, "suikoden-field-event/22") or command.source_offset != 0x3d17c or command.origin != 2) return false;
            var descriptor = self.room2_descriptor orelse return error.InvalidDescriptorInitialization;
            if (descriptor.history_len != 2 or descriptor.movement != null or self.instance.?.pending.?.batch.id != 3) return false;
            var owner: room2_movement.Owner = .{};
            try owner.commit(try owner.proposeRequest(0x3d17c, 1));
            descriptor.movement = owner.state;
            descriptor.movement_frames = 0;
            self.room2_descriptor = descriptor;
        },
        .descriptor_display => {
            if (std.mem.eql(u8, self.schema, "suikoden-field-event/22")) {
                const descriptor_binding = try room2DescriptorBinding(binding);
                var descriptor = self.room2_descriptor orelse return error.InvalidDescriptorInitialization;
                const expected_index: u16 = @intCast(descriptor.history_len);
                if (expected_index >= 2 or command.origin != expected_index or command.selector != 0 or
                    command.parameter != @as(u8, @intCast(expected_index + 1)) or command.source_offset != (if (expected_index == 0) @as(u32, 0x3d174) else 0x3d178) or
                    command.value != (if (expected_index == 0) @as(u8, 0x23) else 0x10)) return false;
                const batch = self.instance.?.pending.?.batch.id;
                if (batch != @as(u64, expected_index) + 1) return error.InvalidFieldEventReceipt;
                const actors = if (self.ordinary_actors) |*present| present else return false;
                const avatar = try actors.actor(binding.ordinary.?, descriptor_binding.actor_id);
                if (avatar.motion.moving() or avatar.support != null) return false;
                if (expected_index == 0) avatar.motion.x = 280 else avatar.motion.y = 128;
                avatar.pose = null;
                descriptor.batches[expected_index] = batch;
                descriptor.history_len += 1;
                descriptor.descriptor_16_result = 0xe0;
                self.room2_descriptor = descriptor;
                return true;
            }
            if (self.initialization_done or !std.mem.eql(u8, binding.content.id, "va1_room1_field_events") or
                !std.mem.eql(u8, self.instance.?.program_id, "va1_r01_init_03")) return false;
            var projection: [3]ordinary.Position = undefined;
            _ = try descriptorInitializerPositions(self, binding, &projection);
            const index = command.selector.?;
            if (index >= 3) return false;
            const actors = if (self.ordinary_actors) |*present| present else return false;
            const avatar = if (actors.slots[index].?.avatar) |*present| present else return false;
            if (avatar.motion.moving() or avatar.support != null) return false;
            switch (command.parameter.?) {
                0 => {
                    if (command.value.? != 0) return false;
                    avatar.auto_animate = false;
                },
                1 => avatar.motion.x = @as(i32, command.value.?) * 8,
                2 => avatar.motion.y = @as(i32, command.value.?) * 8,
                else => return false,
            }
            avatar.pose = null;
        },
        .spatial_object_probe => {
            const source = binding.spatial_source orelse return false;
            if (command.selector != 0x80 or !std.mem.eql(u8, binding.room, "va1_room_0") or
                !std.mem.eql(u8, source.source_sha256, "dcca6119f28f3863250f31be8cd164d4795eaa493aeec5b51ca0737690979fed") or
                source.room != 0 or source.levels.len != 253 or self.hero_sprite == null or self.hero_descriptor_state == null) return false;
            // This source-bound scene has no eligible flags&0x02 records.
            // Other scenes need the full object replacement owner.
            for (source.levels) |level| if (level != 1) return false;
        },
        .descriptor_flags => {
            const change = for (binding.dialogue.descriptor_changes) |entry| {
                if (entry.command == command.origin and std.mem.eql(u8, entry.program, self.instance.?.program_id)) break entry;
            } else return false;
            const queue = if (self.party_queue) |*present| present else return false;
            if (change.follower >= queue.count) return false;
            try queue.followers[change.follower].?.selectFacing(binding.queues.graphics, change.direction, false);
        },
        .fade_in => {
            if (!self.initialization_done or !binding.content.hasFadeIn()) return false;
            try self.fade_state.requestIn();
            if (self.hero_descriptor_state) |*retained| retained.tint_word = 0x80;
        },
        .fade_out => {
            if (!self.initialization_done) return false;
            try self.fade_state.request();
        },
        .room_transition => {
            const package = binding.room_package orelse return false;
            const room = package.roomIndex(command.destination.?) orelse return error.UnknownEventRoom;
            const spawn: field.Point = .{ .x = command.x.?, .y = command.y.? };
            if (!package.rooms[room].contains(spawn.x, spawn.y) or
                (!command.source_arrival and !package.rooms[room].canStand(spawn.x, spawn.y))) return error.InvalidFieldEventTransition;
            if (command.world_entry) |entry_id| {
                const entry = package.world_entries[package.worldEntryIndex(entry_id) orelse return error.MissingWorldEntry];
                if (!std.mem.eql(u8, entry.area, package.rooms[room].source_area orelse "")) return error.InvalidFieldEventTransition;
            }
            state.enterRoom(room, spawn);
            if (command.world_entry) |entry_id| state.setWorldEntry(package, entry_id) else state.reconcileWorldEntry(package, command.world_point);
            self.field_effect = null;
            if (command.arrival_facing) |facing| state.facing = events.fieldDirection(facing);
        },
        .world_transition => {
            const package = binding.room_package orelse return false;
            var destination = command.destination;
            var spawn: field.Point = undefined;
            if (command.return_to_entry) {
                state.reconcileWorldEntry(package, null);
                const entry = state.worldEntry(package) orelse return error.MissingWorldEntry;
                destination = entry.world_room;
                spawn = .{ .x = entry.return_x, .y = entry.return_y };
            } else {
                if (command.retain_world_region) {
                    const context = state.world_context orelse return error.MissingWorldRegion;
                    destination = package.rooms[context.room].id;
                }
                spawn = .{ .x = command.x.? * 8, .y = command.y.? * 8 };
            }
            const room = package.roomIndex(destination.?) orelse return error.UnknownEventRoom;
            if (!package.rooms[room].contains(spawn.x, spawn.y)) return error.InvalidFieldEventTransition;
            state.enterRoom(room, spawn);
            self.field_effect = null;
            state.reconcileWorldEntry(package, null);
            state.crossed_world_exit = true;
            if (command.arrival_facing) |facing| state.facing = events.fieldDirection(facing);
        },
        .room_flag_clear => {
            if (binding.room_package == null) return false;
            const index = command.index.?;
            if (index >= state.local_flags.values.len) return false;
            state.local_flags.values[index] &= ~command.mask.?;
        },
        .money_edit => {
            if (!binding.content.isCampaign()) return false;
            const amt = command.amount.?;
            switch (command.parameter.?) {
                0, 3 => {
                    const sum = @as(u64, state.progress.money) + @as(u64, amt);
                    state.progress.money = @intCast(@min(sum, field.game_state.max_money));
                },
                1 => state.progress.money -|= amt,
                2 => {
                    for (state.progress.party) |*member| {
                        member.hp = member.max_hp;
                        member.status = .healthy;
                        member.balloons = 0;
                    }
                },
                else => return false,
            }
        },
        .tile_variant => {
            if (!binding.content.isCampaign()) return false;
            const slot = command.index.? & 31;
            switch (command.parameter.?) {
                0 => state.tile_variants[slot] +%= 1,
                1 => state.tile_variants[slot] -%= 1,
                2 => {},
                3 => state.tile_variants[slot] = command.value orelse 0,
                else => return false,
            }
        },
        .auto_route => {
            if (!binding.content.isCampaign()) return false;
            state.auto_route_id = if (command.value.? == 255) null else command.value.?;
        },
        .service => {
            if (!binding.content.isCampaign()) return false;
            state.pending_service = .{ .kind = command.fieldService().?, .id = command.index orelse 0, .shop_items = command.shop_items };
        },
        .special_checkpoint => {
            if (!binding.content.isCampaign()) return false;
            state.pending_checkpoint = .{ .selector = command.selector.?, .code = command.code orelse 0 };
        },
        .end_stream => if (self.field_effect) |effect| {
            // shortcut: effects finish within this stream; add visit ownership for a source that outlives it.
            if (effect.model.clock.callback != null) return error.FieldEffectStillActive;
        },
        .world_mode, .soul_eater_advance, .recruit_toggle, .recruit_mark_loaded, .chest_grant, .inn_stay, .party_restore, .story_or, .story_andnot, .sequence_input => {}, // Progress and branch effects commit in pump below.
        else => return false,
    }
    return true;
}

const ItemGrant = struct { member: usize, inventory: field.items.Inventory };

fn prepareChestItem(state: field.State, command: runtime.Command) !?ItemGrant {
    const name = command.item_name orelse return error.UnknownFieldEventItem;
    const item_id = std.meta.stringToEnum(field.items.Id, name) orelse return error.UnknownFieldEventItem;
    for (state.progress.party, 0..) |member, index| {
        var inventory = member.inventory;
        if (try inventory.receive(item_id)) return .{ .member = index, .inventory = inventory };
    }
    return null;
}

pub noinline fn pump(self: *Session, binding: Binding, state: *field.State, story: *runtime.StoryState, input: runtime.Input) !bool {
    const before_pc = self.instance.?.execution.pc;
    var event_input = input;
    event_input.active_party = self.source_party[0..self.active_party_count];
    const stepped = try runtime.step(binding.content, &self.instance.?, story, event_input);
    var staged = self.*;
    const after_pc = if (self.instance.?.pending) |pending| pending.next.pc else self.instance.?.execution.pc;
    const program = binding.content.program(self.instance.?.program_id).?;
    if (after_pc >= before_pc) for (program.commands[before_pc..after_pc]) |command| {
        if (command.kind == .wait_text_queue_drain_and_release) {
            if (self.party_queue != null and self.party_queue.?.active() != 0) return error.FieldPartyQueueBusy;
            staged.party_queue = null;
        }
    };
    if (stepped.batch) |batch| {
        if (staged.instance.?.pendingBattle()) |id| {
            staged.pending_battle = id;
            self.* = staged;
            return true;
        }
        if (staged.instance.?.pendingFixedDice() or staged.instance.?.pendingPartySelect() or staged.instance.?.pendingItemOverload() or (pendingFieldMusic(&staged) != null and program.entry != .initialization)) {
            self.* = staged;
            return true;
        }
        var staged_state = state.*;
        var staged_story = story.*;
        var chest_failed_target: ?u16 = null;
        var item_grant: ?ItemGrant = null;
        for (batch.slice()) |effect| {
            if (!try apply(&staged, binding, effect, &staged_state)) {
                self.blocker = .{ .entity = binding.content.program(self.instance.?.program_id).?.entity, .command = effect.origin };
                return false;
            }
            switch (effect.kind) {
                .soul_eater_advance => {
                    if (staged_story.soul_eater_spell_slots < 1 or staged_story.soul_eater_spell_slots >= 4) return error.InvalidSoulEaterProgress;
                    staged_story.soul_eater_spell_slots += 1;
                },
                .world_mode => {
                    const code = effect.code.?;
                    if (code == 2) {
                        if (staged_story.castle_tier >= 4) return error.InvalidRecruitmentTier;
                        staged_story.castle_tier += 1;
                        staged_state.progress.story.recruitment_tier = staged_story.castle_tier;
                    } else if (code >= 0x0B and code <= 0x0D) {
                        staged_story.world_mode = code - 0x0B;
                    } else if (code == 0x14) {
                        staged_story.scenario[38] |= 8;
                    } else if (code == 0x19) {
                        staged_story.scenario[43] ^= 0x40;
                    } else if (code == 0x1B) {
                        staged_story.scenario[44] ^= 0x04;
                    }
                },
                .recruit_toggle => {
                    staged_story.toggleRecruit(effect.index.?, (effect.mask orelse 0) != 0);
                    if (effect.mask == 2) staged_story.recruit_flags[effect.index.?] |= 2;
                },
                .recruit_mark_loaded => {
                    staged_story.markCharacterLoaded(effect.index.?);
                },
                .sequence_input => try staged_story.advanceSequence(effect.flag.?, effect.parameter.?, effect.value.?),
                .chest_grant => {
                    item_grant = try prepareChestItem(staged_state, effect);
                    if (item_grant == null) {
                        chest_failed_target = effect.failure_target;
                    } else if (effect.flag) |f| {
                        try staged_story.apply(f);
                    }
                },
                else => {},
            }
        }
        staged.receipt = .{ .content_sha256 = binding.content.content_sha256, .program = staged.instance.?.program_id, .instance = staged.serial, .batch = batch.id };
        try runtime.acknowledge(binding.content, &staged.instance.?, &staged_story, batch.id);
        if (staged_story.castle_tier != story.castle_tier)
            staged_state.progress.story.recruitment_tier = staged_story.castle_tier;
        if (batch.slice()[0].kind == .party_restore) try staged_state.progress.restoreParty(batch.slice()[0].hp_only);
        if (batch.slice()[0].kind == .inn_stay) {
            // The isolated batch is acknowledged before changing the shared party backing.
            staged.inn_payment_refused = false;
            staged_state.progress.stay(@intCast(batch.slice()[0].amount.?)) catch |err| switch (err) {
                error.InsufficientFunds => staged.inn_payment_refused = true,
                else => return err,
            };
            if (!staged.inn_payment_refused) staged_state.rest_ticks = 60;
        }
        if (chest_failed_target) |target| try staged.instance.?.redirect(binding.content, batch.slice()[0].origin, target);
        if (item_grant) |grant| staged_state.progress.party[grant.member].inventory = grant.inventory;
        self.* = staged;
        state.* = staged_state;
        story.* = staged_story;
    } else self.* = staged;
    return true;
}

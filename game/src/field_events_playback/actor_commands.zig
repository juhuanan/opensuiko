const std = @import("std");
const ordinary = @import("field_actors");
const events = @import("../field_events.zig");
const runtime = @import("event_runtime");
const motion = @import("opening_audience");
const room2_movement = @import("movement_batch");
const room2DescriptorBinding = @import("../field_events_begin.zig").room2DescriptorBinding;
const descriptorInitializerPositions = @import("../field_events_validate_checks.zig").descriptorInitializerPositions;

const Session = events.Session;
const Binding = events.Binding;

pub fn applySpawnActor(self: *Session, binding: Binding, command: runtime.Command) !bool {
    if (!binding.content.hasSceneActors()) return false;
    const packet = binding.ordinary orelse return false;
    const actors = if (self.ordinary_actors) |*value| value else return false;
    try actors.spawn(packet, binding.animations, command.actor.?);
    return true;
}

pub fn applyReleaseActor(self: *Session, binding: Binding, command: runtime.Command) !bool {
    // Ordinary and scene-owned actors share animation and movement ownership.
    if (!binding.content.hasActorPositions()) return false;
    const packet = binding.ordinary orelse return false;
    const actors = if (self.ordinary_actors) |*value| value else return false;
    const avatar = actors.actor(packet, command.actor.?) catch return false;
    if (avatar.support != null or avatar.motion.moving()) return false;
    const jobs = self.tracks();
    for (jobs) |job| if (job != null and job.?.state.active and std.mem.eql(u8, binding.content.tracks[job.?.track].actor, command.actor.?)) return false;
    try actors.release(packet, command.actor.?);
    return true;
}

pub fn applyPlaceActor(self: *Session, binding: Binding, command: runtime.Command) !bool {
    if (!binding.content.hasActorPositions()) return false;
    const packet = binding.ordinary orelse return false;
    const actors = if (self.ordinary_actors) |*value| value else return false;
    const jobs = self.tracks();
    for (jobs) |job| if (job != null and job.?.state.active and std.mem.eql(u8, binding.content.tracks[job.?.track].actor, command.actor.?)) return false;
    actors.place(packet, command.actor.?, command.x, command.y) catch |err| switch (err) {
        error.UnknownFieldActor, error.FieldActorNotConstructed, error.FieldActorReleased, error.FieldActorGraphicsUnavailable, error.FieldActorBusy => return false,
        else => return err,
    };
    return true;
}

pub fn applyActorAxis(self: *Session, binding: Binding, command: runtime.Command) bool {
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
    return true;
}

pub fn applyActorTransition(self: *Session, binding: Binding, command: runtime.Command) !bool {
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
    return true;
}

pub fn applyQueueTrack(self: *Session, binding: Binding, command: runtime.Command) !bool {
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
    return true;
}

pub fn applyRequestAreaPartyPrefix(self: *Session, command: runtime.Command) !bool {
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
    return true;
}

pub fn applyQueueGlyphs(self: *Session, binding: Binding, command: runtime.Command) !bool {
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
    return true;
}

pub fn applySourceMoveBatch(self: *Session, command: runtime.Command) !bool {
    if (!std.mem.eql(u8, self.schema, "suikoden-field-event/22") or command.source_offset != 0x3d17c or command.origin != 2) return false;
    var descriptor = self.room2_descriptor orelse return error.InvalidDescriptorInitialization;
    if (descriptor.history_len != 2 or descriptor.movement != null or self.instance.?.pending.?.batch.id != 3) return false;
    var owner: room2_movement.Owner = .{};
    try owner.commit(try owner.proposeRequest(0x3d17c, 1));
    descriptor.movement = owner.state;
    descriptor.movement_frames = 0;
    self.room2_descriptor = descriptor;
    return true;
}

pub fn applyDescriptorDisplay(self: *Session, binding: Binding, command: runtime.Command) !bool {
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
    return true;
}

pub fn applySpatialObjectProbe(self: *Session, binding: Binding, command: runtime.Command) bool {
    const source = binding.spatial_source orelse return false;
    if (command.selector != 0x80 or !std.mem.eql(u8, binding.room, "va1_room_0") or
        !std.mem.eql(u8, source.source_sha256, "dcca6119f28f3863250f31be8cd164d4795eaa493aeec5b51ca0737690979fed") or
        source.room != 0 or source.levels.len != 253 or self.hero_sprite == null or self.hero_descriptor_state == null) return false;
    // This source-bound scene has no eligible flags&0x02 records.
    // Other scenes need the full object replacement owner.
    for (source.levels) |level| if (level != 1) return false;
    return true;
}

pub fn applyDescriptorFlags(self: *Session, binding: Binding, command: runtime.Command) !bool {
    const change = for (binding.dialogue.descriptor_changes) |entry| {
        if (entry.command == command.origin and std.mem.eql(u8, entry.program, self.instance.?.program_id)) break entry;
    } else return false;
    const queue = if (self.party_queue) |*present| present else return false;
    if (change.follower >= queue.count) return false;
    try queue.followers[change.follower].?.selectFacing(binding.queues.graphics, change.direction, false);
    return true;
}

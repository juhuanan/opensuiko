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
const room2ActorPosition = begin_mod.room2ActorPosition;
const select = begin_mod.select;
const validate_mod = @import("field_events_validate.zig");
const validate = validate_mod.validate;

pub fn initializedPosition(self: *const Session, binding: Binding) !?ordinary.Position {
    if (self.initialization_count > self.initializations.len) return error.InvalidFieldEventState;
    for (self.initializations[0..self.initialization_count]) |entry| {
        const initialized = entry orelse return error.InvalidFieldEventReceipt;
        if (initialized.entity != 8) continue;
        const packet = binding.ordinary orelse return error.InvalidFieldActorPositionHistory;
        const actors = if (self.ordinary_actors) |*value| value else return error.InvalidFieldActorPositionHistory;
        const program = binding.content.program("vb6_r06_init_08") orelse return error.InvalidFieldEventReceipt;
        const receipt = initialized.receipt orelse return error.InvalidFieldEventReceipt;
        if (initialized.kind != .effect_ack or (!std.mem.eql(u8, self.schema, "suikoden-field-event/16") and !std.mem.eql(u8, self.schema, "suikoden-field-event/18")) or !std.mem.eql(u8, receipt.program, program.id) or receipt.batch != 1 or initialized.pump_pc != 6 or !actors.construction_story.matches(program.conditions) or program.commands.len != 7) return error.InvalidFieldEventReceipt;
        const x = program.commands[1];
        const y = program.commands[2];
        if (x.kind != .actor_x or y.kind != .actor_y or x.actor == null or y.actor == null or x.value != 24 or y.value != 25 or !std.mem.eql(u8, x.actor.?, y.actor.?)) return error.InvalidFieldActorPositionHistory;
        const index = for (packet.actors, 0..) |definition, i| {
            if (std.mem.eql(u8, definition.id, x.actor.?)) break i;
        } else return error.InvalidFieldActorPositionHistory;
        if (index > 255 or index >= actors.count or actors.slots[index] == null or actors.slots[index].?.avatar == null) return error.InvalidFieldActorPositionHistory;
        const actor_transition = program.commands[3];
        const hero_transition = program.commands[4];
        const avatar = actors.slots[index].?.avatar.?;
        if (actor_transition.kind != .actor_transition or actor_transition.actor == null or !std.mem.eql(u8, actor_transition.actor.?, x.actor.?) or actor_transition.transition != 3 or hero_transition.kind != .actor_transition or hero_transition.actor == null or !std.mem.eql(u8, hero_transition.actor.?, "hero") or hero_transition.transition != 2 or avatar.variant != 3 or avatar.orientation_flags != 2 or self.facing != .left) return error.InvalidFieldActorPositionHistory;
        return .{ .actor = @intCast(index), .x = 192, .y = 200 };
    }
    return null;
}

/// Rebuild axis writes from acknowledged commands; queued motion keeps its own owner.
pub fn scriptedActorPositions(self: *const Session, binding: Binding, storage: *[64]ordinary.Position) ![]const ordinary.Position {
    if (!binding.content.hasActorPositions()) return &.{};
    const packet = binding.ordinary orelse return &.{};
    const actors = self.ordinary_actors orelse return error.InvalidFieldActorState;
    if (actors.count != packet.actors.len or actors.count > actors.slots.len) return error.InvalidFieldActorState;
    if (self.instance == null) {
        for (actors.slots[0..actors.count], 0..) |entry, i| {
            if (entry == null or (entry.?.phase == .released and !actors.initialPosition(packet.actors[i]).released) or (packet.actors[i].scene_owned and entry.?.phase != .absent)) return error.InvalidFieldActorState;
        }
        return &.{};
    }
    const owner = self.instance.?;
    const program = binding.content.program(owner.program_id) orelse return error.InvalidFieldActorPositionHistory;
    if (owner.execution.pc > program.commands.len) return error.InvalidFieldActorPositionHistory;
    var positions: [64]?ordinary.Position = @splat(null);
    var queued_tracks: [64]?u16 = @splat(null);
    var released: [64]bool = @splat(false);
    var spawned: [64]bool = @splat(false);
    if (actors.settled_positions) |settled| for (settled, 0..) |position, i| {
        released[i] = position != null and position.?.released;
    };
    const jobs = self.tracks();
    var history: runtime.CommandHistory = .{ .commands = program.commands, .execution = owner.execution };
    while (history.next()) |executed| {
        const command = executed.command;
        if (command.kind == .queue_track) {
            const track_index = for (binding.content.tracks, 0..) |track, i| {
                if (std.mem.eql(u8, track.id, command.track.?)) break i;
            } else return error.InvalidFieldActorPositionHistory;
            const target = binding.content.tracks[track_index].actor;
            for (packet.actors, 0..) |actor, i| {
                if (i < positions.len and std.mem.eql(u8, actor.id, target)) queued_tracks[i] = @intCast(track_index);
            }
            continue;
        }
        if (command.kind != .spawn_actor and command.kind != .place_actor and command.kind != .release_actor) continue;
        const index = for (packet.actors, 0..) |actor, i| {
            if (std.mem.eql(u8, actor.id, command.actor.?)) break i;
        } else return error.InvalidFieldActorPositionHistory;
        if (index >= positions.len) return error.InvalidFieldActorPositionHistory;
        var position = positions[index] orelse actors.initialPosition(packet.actors[index]);
        if (command.kind == .spawn_actor) {
            if (!binding.content.hasSceneActors() or !packet.actors[index].scene_owned or spawned[index]) return error.InvalidFieldActorLifetime;
            spawned[index] = true;
            positions[index] = position;
            continue;
        }
        if (packet.actors[index].scene_owned and !spawned[index]) return error.InvalidFieldActorLifetime;
        if (command.kind == .release_actor) {
            released[index] = true;
            position.released = true;
            positions[index] = position;
            continue;
        }
        if (command.x) |x| position.x = x;
        if (command.y) |y| position.y = y;
        positions[index] = position;
    }
    for (actors.slots[0..actors.count], 0..) |entry, i| {
        const slot = entry orelse return error.InvalidFieldActorState;
        if ((slot.phase == .released) != released[i]) return error.InvalidFieldActorState;
        if (packet.actors[i].scene_owned and ((slot.phase != .absent) != spawned[i])) return error.InvalidFieldActorLifetime;
    }
    var count: usize = 0;
    for (positions) |entry| if (entry) |position| {
        if (queued_tracks[position.actor]) |track| {
            const queued = for (jobs) |job| {
                if (job != null and job.?.actor == position.actor and job.?.track == track) break true;
            } else false;
            if (!queued) return error.InvalidFieldActorPositionHistory;
            continue;
        }
        for (jobs) |job| if (job != null and job.?.actor == position.actor) return error.InvalidFieldActorPositionHistory;
        storage[count] = position;
        count += 1;
    };
    return storage[0..count];
}

pub fn descriptorInitializerPositions(self: *const Session, binding: Binding, storage: *[3]ordinary.Position) ![]const ordinary.Position {
    if (!std.mem.eql(u8, binding.content.id, "va1_room1_field_events")) return &.{};
    const program = binding.content.program("va1_r01_init_03") orelse return error.InvalidDescriptorInitialization;
    const packet = binding.ordinary orelse return error.InvalidDescriptorInitialization;
    if (program.entry != .initialization or program.entity != 3 or program.commands.len != 12 or packet.actors.len != 17 or
        program.commands[0].kind != .continue_tick or program.commands[10].kind != .yield_tick or program.commands[11].kind != .end_stream)
        return error.InvalidDescriptorInitialization;
    const source = [_][3]u8{ .{ 0, 1, 0x27 }, .{ 0, 2, 0x0b }, .{ 0, 0, 0 }, .{ 2, 1, 0x0c }, .{ 2, 2, 8 }, .{ 2, 0, 0 }, .{ 1, 1, 0x1b }, .{ 1, 2, 0x0b }, .{ 1, 0, 0 } };
    for (source, program.commands[1..10]) |record, command| {
        if (command.kind != .descriptor_display or command.selector != record[0] or command.parameter != record[1] or command.value != record[2]) return error.InvalidDescriptorInitialization;
    }
    const entities = [_]u8{ 5, 6, 9 };
    for (storage, entities, packet.actors[0..3], 0..) |*position, entity, definition, index| {
        if (definition.entity != entity or definition.slot != index or definition.x != 2032 or definition.y != 2032 or definition.auto_animate or definition.source_graphics != .child_present) return error.InvalidDescriptorInitialization;
        position.* = .{ .actor = @intCast(index), .x = definition.x, .y = definition.y };
    }
    var pc: usize = 0;
    if (self.instance) |owner| {
        if (std.mem.eql(u8, owner.program_id, program.id)) pc = owner.execution.pc;
    }
    for (self.initializations[0..self.initialization_count]) |entry| if (entry) |initialized| {
        if (initialized.entity != 3) continue;
        const receipt = initialized.receipt orelse return error.InvalidDescriptorInitialization;
        if (initialized.kind != .effect_ack or !std.mem.eql(u8, receipt.program, program.id) or receipt.batch != 1 or initialized.pump_pc != 11 or receipt.instance >= self.serial) return error.InvalidDescriptorInitialization;
        pc = initialized.pump_pc;
    };
    if (pc > 11) return error.InvalidDescriptorInitialization;
    for (program.commands[0..pc]) |command| if (command.kind == .descriptor_display) {
        if (command.parameter.? == 1) storage[command.selector.?].x = @as(i32, command.value.?) * 8;
        if (command.parameter.? == 2) storage[command.selector.?].y = @as(i32, command.value.?) * 8;
    };
    return storage;
}

pub fn openingSchema(schema: []const u8) bool {
    return std.mem.eql(u8, schema, "suikoden-field-event/19") or std.mem.eql(u8, schema, "suikoden-field-event/20") or
        std.mem.eql(u8, schema, "suikoden-field-event/21") or std.mem.eql(u8, schema, "suikoden-field-event/22");
}

pub fn validateHeaderContext(self: *const Session, binding: Binding) !void {
    if (self.context_sha256.len != 0 and !std.mem.eql(u8, self.context_sha256, binding.context.content_sha256)) return error.FieldEventIdentityMismatch;
    if (self.selected_program and (self.context_sha256.len != 64 or !self.initialization_done or self.actor_count != 0 or self.initialization_count != 0 or self.next_initialization != binding.population.entities.len)) return error.InvalidFieldEventState;
    if (self.wheel_graphics) |graphics| {
        if (!binding.content.hasWheelMotion() or graphics.actor >= binding.room_actors.len or
            binding.room_actors[graphics.actor].scene_actor == null or binding.room_actors[graphics.actor].scene_actor.?.character != 8)
            return error.InvalidWheelGraphics;
        for ([_]i32{ graphics.primary.x, graphics.primary.y, graphics.auxiliary.x, graphics.auxiliary.y }) |coordinate|
            if (std.math.cast(i16, coordinate) == null) return error.InvalidWheelGraphics;
    }
    if (self.scripted_camera) |camera| {
        if (!binding.scripted_motion or !self.selected_program) return error.InvalidCameraPan;
        if (camera.absolute and !binding.content.isScene()) return error.InvalidCameraPan;
        try camera.validate();
    }
}

pub fn validateHeroSpriteState(self: *const Session, binding: Binding, check_descriptor_state: bool) !void {
    if (self.hero_sprite) |sprite| {
        if (check_descriptor_state) {
            if (self.hero_descriptor_state) |retained| {
                if (retained.auxiliary.child_0c.variant != sprite.variant or
                    !std.meta.eql(retained.auxiliary.child_0c.animation, sprite.animation)) return error.InvalidHeroDescriptorState;
            }
        }
        const clip = binding.hero_animation.clips[sprite.variant];
        const variant: u2 = switch (self.facing) {
            .down => 0,
            .up => 1,
            .left => 2,
            .right => 3,
        };
        if (sprite.variant != variant or sprite.animation.frame >= clip.ticks.len or sprite.emitted_frame >= clip.ticks.len or sprite.animation.remaining == 0 or sprite.animation.remaining > clip.ticks[sprite.animation.frame] or sprite.emitted_x < (if (self.camera_push != null) @as(i32, -16) else 0) or sprite.emitted_x > (if (self.camera_push != null) @as(i32, 2064) else 2048) or sprite.emitted_y < (if (self.camera_push != null) @as(i32, -16) else 0) or sprite.emitted_y > (if (self.camera_push != null) @as(i32, 2064) else 2048) or !sprite.animation.active or !sprite.animation.repeating) return error.InvalidFieldHeroAnimation;
    } else if (self.busy()) return error.InvalidFieldHeroAnimation;
}

pub fn validateInitializations(self: *const Session, binding: Binding, allow_pure_pumps: bool) !void {
    if (self.serial == 0 or self.actor_count > self.actors.len or self.active_party_count != binding.party.len) return error.InvalidFieldEventState;
    if (self.initialization_count > self.initializations.len or self.next_initialization > binding.population.entities.len) return error.InvalidFieldEventState;
    var previous: ?u8 = null;
    var pure_pumps: u8 = 0;
    for (self.initializations, 0..) |record, index| {
        if (index >= self.initialization_count) {
            if (record != null) return error.InvalidFieldEventReceipt;
            continue;
        }
        const initialized = record orelse return error.InvalidFieldEventReceipt;
        if (allow_pure_pumps and (initialized.entity >= self.next_initialization or (previous != null and previous.? >= initialized.entity))) return error.InvalidFieldEventReceipt;
        const program = switch (initialized.kind) {
            .effect_ack => blk: {
                const receipt = initialized.receipt orelse return error.InvalidFieldEventReceipt;
                if (allow_pure_pumps and (initialized.program.len != 0 or initialized.instance != 0 or receipt.instance >= self.serial or receipt.batch == 0 or !std.mem.eql(u8, receipt.content_sha256, self.content_sha256))) return error.InvalidFieldEventReceipt;
                const resolved = binding.content.program(receipt.program) orelse return error.UnknownEventProgram;
                if (!allow_pure_pumps and (receipt.instance >= self.serial or receipt.batch == 0 or !std.mem.eql(u8, receipt.content_sha256, self.content_sha256))) return error.InvalidFieldEventReceipt;
                break :blk resolved;
            },
            .pure_pump => blk: {
                if (!allow_pure_pumps or initialized.receipt != null or initialized.instance == 0 or initialized.instance >= self.serial) return error.InvalidFieldEventReceipt;
                pure_pumps += 1;
                break :blk binding.content.program(initialized.program) orelse return error.UnknownEventProgram;
            },
        };
        if (program.entry != .initialization or program.entity != initialized.entity or initialized.pump_pc >= program.commands.len or (!allow_pure_pumps and (initialized.entity >= self.next_initialization or (previous != null and previous.? >= initialized.entity)))) return error.InvalidFieldEventReceipt;
        if (initialized.kind == .pure_pump) {
            if (!pureInitializationProgram(program, initialized.pump_pc)) return error.InvalidFieldEventReceipt;
            const actors = self.ordinary_actors orelse return error.InvalidFieldEventReceipt;
            if (!actors.construction_story.matches(program.conditions)) return error.InvalidFieldEventReceipt;
            const source_entity = for (binding.population.entities) |candidate| {
                if (candidate.source_order == initialized.entity) break candidate;
            } else return error.InvalidFieldEventReceipt;
            if (source_entity.trigger != .initialization or source_entity.event.status != .resolved or
                source_entity.event.program_id == null or !std.mem.eql(u8, source_entity.event.program_id.?, program.id)) return error.InvalidFieldEventReceipt;
        }
        previous = initialized.entity;
    }
    if (allow_pure_pumps and ((std.mem.eql(u8, self.schema, "suikoden-field-event/20") and pure_pumps == 0) or
        (pure_pumps != 0 and !std.mem.eql(u8, self.schema, "suikoden-field-event/20") and !std.mem.eql(u8, self.schema, "suikoden-field-event/21") and !std.mem.eql(u8, self.schema, "suikoden-field-event/22")))) return error.InvalidFieldEventReceipt;
}

pub fn validateRuntimeQueuesAndActors(self: *const Session, binding: Binding) !void {
    if (!std.mem.eql(u8, self.source_party[0..self.active_party_count], binding.party)) return error.FieldEventPartyMismatch;
    for (self.boxes, 0..) |box, slot| {
        const placements = @as(u8, @intFromBool(box.anchor != null)) + @as(u8, @intFromBool(box.fixed != null));
        if (box.transition > 20 or (!box.changing() and box.transition != 0) or placements != @as(u8, @intFromBool(box.phase != .closed))) return error.InvalidFieldDialogue;
        if (box.anchor) |anchor| if (anchor.x < 8 or anchor.x > 2048 or anchor.y < -24 or anchor.y > 2016 or @mod(anchor.x, 8) != 0 or @mod(anchor.y, 8) != 0) return error.InvalidFieldDialogue;
        if (box.fixed) |rect| {
            if (!binding.content.hasFixedBoxes()) return error.InvalidFieldDialogue;
            const owner = self.instance orelse return error.InvalidFieldDialogue;
            const program = binding.content.program(owner.program_id) orelse return error.InvalidFieldDialogue;
            if (owner.execution.pc > program.commands.len) return error.InvalidFieldDialogue;
            var cursor: usize = owner.execution.pc;
            while (cursor != 0) {
                cursor -= 1;
                const command = program.commands[cursor];
                if ((command.kind != .open_fixed_box and command.kind != .open_box) or command.box.? != slot) continue;
                if (command.kind != .open_fixed_box or command.x != rect.x or command.y != rect.y or @as(i32, command.width.?) != rect.w or @as(i32, command.height.?) != rect.h) return error.InvalidFieldDialogue;
                break;
            } else return error.InvalidFieldDialogue;
        }
        if (box.speaker) |speaker| if (speaker >= binding.dialogue.texts.len or box.phase == .closed) return error.InvalidFieldDialogue;
        if (box.image) |image| if (image >= binding.dialogue.images.len or box.phase == .closed or box.phase == .closing) return error.InvalidFieldDialogue;
    }
    if (self.text_job) |job| {
        if (job.box > 1 or job.text >= binding.dialogue.texts.len or self.boxes[job.box].phase == .closed or job.current_pace > 5 or job.state.cursor > binding.dialogue.texts[job.text].tokens.len or job.state.length > job.state.buffer.len or job.state.id == null or !std.mem.eql(u8, job.state.id.?, binding.dialogue.texts[job.text].id)) return error.InvalidFieldDialogue;
        const is_prefix = for (binding.dialogue.prefixes) |prefix| {
            if (prefix.box == job.box and prefix.text == job.text) break true;
        } else false;
        if ((job.kind == .prefix) != is_prefix or (job.kind == .prefix and job.state.pace != 0)) return error.InvalidFieldDialogue;
        if ((job.kind == .body_done and !job.state.done) or (job.kind == .body and job.state.done) or (job.kind == .body_staged and (job.state.cursor != 0 or job.state.length != 0 or job.state.done))) return error.InvalidFieldDialogue;
    }
    if (self.party_queue) |queue| {
        if (queue.count == 0 or queue.count > 5 or queue.count + 1 != self.active_party_count) return error.InvalidFieldPartyQueue;
        for (queue.followers, 0..) |slot, index| {
            if (index >= queue.count) {
                if (slot != null) return error.InvalidFieldPartyQueue;
                continue;
            }
            const follower = slot orelse return error.InvalidFieldPartyQueue;
            const loaded = std.mem.indexOfScalar(u8, self.source_party[0..self.active_party_count], follower.character) != null;
            if ((loaded and binding.queues.graphics != null and binding.queues.graphics.?.resource(follower.character) != null) != (follower.sprite != null)) return error.InvalidFieldPartyGraphics;
            if (follower.sprite) |sprite| {
                const clip = binding.queues.graphics.?.resource(follower.character).?.clips[sprite.variant];
                if (sprite.variant != graphicVariant(follower.facing) or sprite.animation.frame >= clip.ticks.len or sprite.emitted_frame >= clip.ticks.len or sprite.animation.remaining == 0 or sprite.animation.remaining > clip.ticks[sprite.animation.frame] or sprite.emitted_x < 0 or sprite.emitted_x > 2048 or sprite.emitted_y < 0 or sprite.emitted_y > 2048 or !sprite.animation.active or !sprite.animation.repeating) return error.InvalidFieldPartyGraphics;
            }
            const anchor = binding.queues.anchor;
            if (follower.custom_track) |custom| {
                if (!binding.queues.isRoom() or !binding.content.hasPartyTracks()) return error.InvalidFieldPartyQueue;
                const job: ordinary.TrackJob = .{ .track = custom, .actor = 255, .state = follower.track };
                try job.validate(binding.content, runtime.party_actor_ids[index]);
                if (follower.position.speed != follower.track.motion or follower.position.x < 0 or follower.position.x > 2040 or follower.position.y < 0 or follower.position.y > 2040) return error.InvalidFieldPartyQueue;
                if (follower.track.hold_remaining != 0 and follower.position.moving()) return error.InvalidFieldPartyQueue;
                if (follower.track.hop_remaining != 0 and (follower.position.offset_x != 0 or follower.position.offset_y != motion.hop_offsets[motion.hop_offsets.len - 1 - follower.track.hop_remaining])) return error.InvalidFieldPartyQueue;
            } else {
                const track = binding.queues.tracks[queue.trackIndex(index)];
                if (follower.track.cursor > track.commands.len or (follower.track.active and follower.track.cursor == track.commands.len) or follower.track.remaining > 3 or follower.track.hold_remaining != 0 or follower.track.hop_remaining != 0 or follower.track.motion != 2 or follower.track.saved_motion != 2 or follower.position.speed != 2 or follower.position.x < anchor.x - 24 or follower.position.x > anchor.x + 24 or follower.position.y < anchor.y - 24 or follower.position.y > anchor.y + 24) return error.InvalidFieldPartyQueue;
            }
            if (follower.character != self.area_party[index + 1] or @mod(follower.position.x, 8) != 0 or @mod(follower.position.y, 8) != 0 or follower.position.offset_x < -8 or follower.position.offset_x > 8 or follower.position.offset_y < -8 or follower.position.offset_y > 8 or (follower.position.offset_x != 0 and follower.position.offset_y != 0) or (!follower.track.active and follower.position.moving())) return error.InvalidFieldPartyQueue;
        }
    }
    for (self.actors, 0..) |actor, index| {
        if (index >= self.actor_count) {
            if (actor != null) return error.InvalidFieldEventState;
            continue;
        }
        const current = actor orelse return error.InvalidFieldEventState;
        if (current.entity >= binding.population.entities.len) return error.InvalidFieldEventState;
        const definition = binding.population.entities[current.entity];
        if (!definition.population_candidate or current.x != definition.position.x or current.y != definition.position.y or current.placed != (definition.position.placement == .placed)) return error.InvalidFieldEventState;
    }
}

pub fn validateInstanceState(self: *const Session, binding: Binding, modern: bool) !void {
    if (self.instance) |instance| {
        try instance.validate(binding.content);
        const program = binding.content.program(instance.program_id).?;
        if (instance.choiceBox(binding.content)) |slot| {
            const job = if (self.text_job) |*job| job else return error.InvalidFieldChoices;
            if (self.boxes[slot].phase != .open or !job.hasChoiceRows(slot)) return error.InvalidFieldChoices;
        }
        if (self.delay_remaining != 0) {
            if (instance.execution.wait == null or instance.execution.wait.?.kind != .delay or instance.execution.pc == 0) return error.InvalidFieldEventState;
            const command = program.commands[instance.execution.pc - 1];
            if ((command.kind != .delay and (!modern or command.kind != .source_timer)) or command.updates == null or self.delay_remaining >= command.updates.?) return error.InvalidFieldEventState;
        }
        if (program.entity >= binding.population.entities.len) return error.InvalidFieldEventBinding;
        if (binding.population.entities[program.entity].trigger == .interaction and !self.selected_program and (!modern or self.retained_selection != program.entity)) return error.InvalidFieldEventState;
        if ((binding.content.program(instance.program_id).?.entry == .ordinary) != self.initialization_done) return error.InvalidFieldInitialization;
        if (self.receipt) |receipt| if (!std.mem.eql(u8, receipt.content_sha256, self.content_sha256) or !std.mem.eql(u8, receipt.program, instance.program_id) or receipt.instance != self.serial or receipt.batch > instance.effect_sequence or (instance.pending != null and receipt.batch >= instance.pending.?.batch.id)) return error.InvalidFieldEventReceipt;
        const applied = instance.effect_sequence - @as(u64, if (instance.pending != null) 1 else 0);
        if (applied != (if (self.receipt) |receipt| receipt.batch else 0)) return error.InvalidFieldEventReceipt;
    } else if (self.receipt != null or self.delay_remaining != 0) return error.InvalidFieldEventReceipt;
}

pub fn validateAudioState(self: *const Session, binding: Binding, allow_audio_schema: bool) !void {
    if (self.audio_cached_command != null) {
        const access = binding.audio orelse return error.MissingFieldAudioAccess;
        if (!allow_audio_schema or !std.mem.eql(u8, self.schema, "suikoden-field-event/14") or access.identity.len != 64 or !std.mem.eql(u8, access.identity, self.audio_identity) or !std.mem.eql(u8, access.audience_path, "audience.wav") or self.audio_cached_command.? != 0x422 or self.area_command != 0x422 or self.instance == null or !std.mem.eql(u8, self.instance.?.program_id, "vaa_room2_audience") or self.instance.?.execution.pc <= 28) return error.InvalidFieldAudioState;
        if (self.audio_request) |request| {
            if (request.command != 0x422 or request.origin != 28 or request.batch == 0 or self.receipt == null or request.batch > self.receipt.?.batch) return error.InvalidFieldAudioState;
        }
    } else if (self.audio_identity.len != 0 or self.area_command != null or self.audio_request != null or (allow_audio_schema and std.mem.eql(u8, self.schema, "suikoden-field-event/14"))) return error.InvalidFieldAudioState;
}

pub noinline fn validateLegacy(self: *const Session, binding: Binding) !void {
    try validateHeaderContext(self, binding);
    const requires_construction = std.mem.eql(u8, binding.content.id, "vb6_room6_arrival") and binding.context.ordinary_sha256 != null;
    const constructed = std.mem.eql(u8, self.schema, "suikoden-field-event/16") or std.mem.eql(u8, self.schema, "suikoden-field-event/17") or std.mem.eql(u8, self.schema, "suikoden-field-event/18");
    if (requires_construction != constructed) return error.UnsupportedFieldGroundConstruction;
    if (constructed) {
        try binding.validateContext();
        const access = binding.ground orelse return error.UnsupportedFieldGroundConstruction;
        const actors = self.ordinary_actors orelse return error.UnsupportedFieldGroundConstruction;
        if (!std.mem.eql(u8, binding.content.id, "vb6_room6_arrival") or self.selected_program or (std.mem.eql(u8, self.schema, "suikoden-field-event/16") and self.position_history != null) or actors.count > actors.slots.len or access.identity.len == 0 or !std.mem.eql(u8, self.construction_ground_identity, access.identity)) return error.UnsupportedFieldGroundConstruction;
        if (std.mem.eql(u8, self.schema, "suikoden-field-event/16") and self.instance != null and std.mem.eql(u8, self.instance.?.program_id, "vb6_r06_entity07_followon")) return error.InvalidFieldEventReceipt;
        for (actors.slots[0..actors.count]) |slot| if (slot) |entry| if (entry.avatar) |avatar| {
            if (avatar.support != null or access.ground_fn(access.context, avatar.id, avatar.motion) != true) return error.UnsupportedFieldGroundConstruction;
        };
    } else if (self.construction_ground_identity.len != 0) return error.UnsupportedFieldGroundConstruction;
    if (std.mem.eql(u8, self.schema, "suikoden-field-event/17")) {
        const completed = self.completed_event orelse return error.InvalidFieldEventReceipt;
        const current = self.instance orelse return error.InvalidFieldEventReceipt;
        const prior = binding.content.program("vb6_r06_first_arrival") orelse return error.InvalidFieldEventReceipt;
        if (!std.mem.eql(u8, current.program_id, "vb6_r06_entity07_followon") or !std.mem.eql(u8, completed.receipt.program, prior.id) or !std.mem.eql(u8, completed.receipt.content_sha256, binding.content.content_sha256) or self.serial == 0 or completed.receipt.instance == 0 or completed.receipt.instance != self.serial - 1 or completed.effect_sequence != 20 or completed.receipt.batch != completed.effect_sequence or completed.execution.active or completed.execution.reloop or completed.execution.choice != 0 or completed.execution.wait != null or completed.execution.pc != prior.commands.len or !self.initialization_done or self.initialization_count != 1 or self.initializations[0] == null or self.initializations[0].?.entity != 6) return error.InvalidFieldEventReceipt;
        const archived: runtime.Instance = .{ .content_id = binding.content.id, .content_sha256 = binding.content.content_sha256, .program_id = prior.id, .execution = completed.execution, .effect_sequence = completed.effect_sequence };
        try archived.validate(binding.content);
        if (current.execution.pc > 0 and self.position_history == null) return error.InvalidFieldActorPositionHistory;
    } else if (self.completed_event != null) return error.InvalidFieldEventReceipt;
    if (std.mem.eql(u8, self.schema, "suikoden-field-event/18")) {
        const history = self.reconstruction orelse return error.InvalidFieldEventReceipt;
        const arrival = binding.content.program("vb6_r06_first_arrival") orelse return error.InvalidFieldEventReceipt;
        const followon = binding.content.program("vb6_r06_entity07_followon") orelse return error.InvalidFieldEventReceipt;
        if (history.arrival_initializer.entity != 6 or (std.math.add(u64, history.arrival_initializer.receipt.?.instance, 1) catch return error.InvalidFieldEventReceipt) != history.arrival.receipt.instance or history.arrival_initializer.receipt.?.batch != 1 or history.arrival_initializer.pump_pc != 3 or !std.mem.eql(u8, history.arrival_initializer.receipt.?.content_sha256, binding.content.content_sha256) or !std.mem.eql(u8, history.arrival_initializer.receipt.?.program, "vb6_room6_init_06")) return error.InvalidFieldEventReceipt;
        for ([_]CompletedEvent{ history.arrival, history.followon }, [_]runtime.Program{ arrival, followon }) |done, program| {
            if (!std.mem.eql(u8, done.receipt.program, program.id) or !std.mem.eql(u8, done.receipt.content_sha256, binding.content.content_sha256) or done.receipt.instance == 0 or done.receipt.batch == 0 or done.receipt.batch != done.effect_sequence or done.execution.active or done.execution.reloop or done.execution.choice != 0 or done.execution.wait != null or done.execution.pc != program.commands.len) return error.InvalidFieldEventReceipt;
            const archived: runtime.Instance = .{ .content_id = binding.content.id, .content_sha256 = binding.content.content_sha256, .program_id = program.id, .execution = done.execution, .effect_sequence = done.effect_sequence };
            try archived.validate(binding.content);
        }
        if (history.arrival.effect_sequence != 20 or history.followon.receipt.instance != (std.math.add(u64, history.arrival.receipt.instance, 1) catch return error.InvalidFieldEventReceipt) or self.initialization_count != 2 or self.initializations[0] == null or self.initializations[0].?.entity != 6 or self.initializations[0].?.pump_pc != 3 or self.initializations[0].?.receipt.?.batch != 1 or self.initializations[0].?.receipt.?.instance != (std.math.add(u64, history.followon.receipt.instance, 1) catch return error.InvalidFieldEventReceipt) or self.initializations[1] == null or self.initializations[1].?.entity != 8 or self.initializations[1].?.receipt.?.instance != (std.math.add(u64, history.followon.receipt.instance, 2) catch return error.InvalidFieldEventReceipt) or self.serial != (std.math.add(u64, history.followon.receipt.instance, 3) catch return error.InvalidFieldEventReceipt) or !self.initialization_done or self.instance != null or self.receipt != null or self.blocker == null or self.blocker.?.reason != .source_gate_unknown) return error.InvalidFieldEventReceipt;
    } else if (self.reconstruction != null) return error.InvalidFieldEventReceipt;
    const jobs = self.tracks();
    const ownership: ?ordinary.PositionOwnership = if (self.position_history) |history| blk: {
        if ((!std.mem.eql(u8, self.schema, "suikoden-field-event/15") and !std.mem.eql(u8, self.schema, "suikoden-field-event/17")) or (!self.selected_program and !std.mem.eql(u8, self.schema, "suikoden-field-event/17")) or self.ordinary_actors == null or self.instance == null or self.receipt == null or self.audio_cached_command != null) return error.InvalidFieldActorPositionHistory;
        const receipt = self.receipt.?;
        if (!std.mem.eql(u8, receipt.content_sha256, binding.content.content_sha256) or !std.mem.eql(u8, receipt.program, self.instance.?.program_id) or receipt.instance != self.serial) return error.InvalidFieldActorPositionHistory;
        const ground = binding.ground orelse return error.InvalidFieldActorPositionHistory;
        if (ground.identity.len == 0 or !std.mem.eql(u8, history.support_identity, ground.identity)) return error.InvalidFieldActorPositionHistory;
        const actors = self.ordinary_actors.?;
        if (history.actor >= actors.count or actors.slots[history.actor] == null or actors.slots[history.actor].?.avatar == null) return error.InvalidFieldActorPositionHistory;
        const avatar = actors.slots[history.actor].?.avatar.?;
        if (avatar.support != null or ground.ground_fn(ground.context, avatar.id, avatar.motion) != true) return error.InvalidFieldActorPositionHistory;
        if (self.instance.?.execution.pc > 2) {
            const queued = for (jobs) |entry| {
                if (entry) |job| {
                    if (job.actor == history.actor and job.track < binding.content.tracks.len and std.mem.eql(u8, binding.content.tracks[job.track].id, "vb6_e7_actor_track")) break true;
                }
            } else false;
            if (!queued) return error.InvalidFieldActorPositionHistory;
        }
        break :blk .{ .history = history, .instance = &self.instance.?, .serial = self.serial, .committed_batch = receipt.batch };
    } else blk: {
        if (std.mem.eql(u8, self.schema, "suikoden-field-event/15")) return error.InvalidFieldActorPositionHistory;
        break :blk null;
    };
    const initialized_position = try initializedPosition(self, binding);
    // shortcut: this candidate needs E7 reconstruction ownership for an eligible initializer8; add other source entry paths when proven.
    if (std.mem.eql(u8, self.schema, "suikoden-field-event/16") and self.initialization_done) if (self.ordinary_actors) |*actors| {
        if (binding.content.program("vb6_r06_init_08")) |program| if (actors.construction_story.matches(program.conditions)) return error.InvalidFieldEventReceipt;
    };
    if (self.ordinary_actors) |actors| {
        var storage: [64]ordinary.Position = undefined;
        const positions = try scriptedActorPositions(self, binding, &storage);
        if (positions.len != 0) {
            if (ownership != null or initialized_position != null) return error.InvalidFieldActorPositionHistory;
            try actors.validateTracksAtMany(binding.ordinary.?, binding.animations, binding.content, &jobs, null, positions);
        } else try actors.validateTracksAt(binding.ordinary orelse return error.InvalidFieldActorState, binding.animations, binding.content, &jobs, ownership, initialized_position);
    }
    const multiple = for (self.other_tracks) |job| {
        if (job != null) break true;
    } else false;
    if (self.ordinary_actors == null) {
        if (multiple) return error.InvalidFieldActorState;
        if (self.ordinary_track) |job| {
            if (job.actor != 255) return error.InvalidFieldActorState;
            try job.validate(binding.content, "hero");
        }
    }
    if (self.ordinary_track != null and ((!self.selected_program and !std.mem.eql(u8, self.schema, "suikoden-field-event/17")) or self.instance == null or binding.movement == null or !binding.movement.?.event_active or !(std.mem.eql(u8, self.schema, "suikoden-field-event/12") or std.mem.eql(u8, self.schema, "suikoden-field-event/13") or std.mem.eql(u8, self.schema, "suikoden-field-event/14") or std.mem.eql(u8, self.schema, "suikoden-field-event/15") or std.mem.eql(u8, self.schema, "suikoden-field-event/17")))) return error.InvalidFieldActorState;
    if (multiple and (self.ordinary_track == null or !(std.mem.eql(u8, self.schema, "suikoden-field-event/13") or std.mem.eql(u8, self.schema, "suikoden-field-event/14") or std.mem.eql(u8, self.schema, "suikoden-field-event/15") or std.mem.eql(u8, self.schema, "suikoden-field-event/17")))) return error.InvalidFieldActorState;
    if (self.ordinary_track != null) {
        const access = binding.movement.?;
        if (access.identity.len == 0 or !std.mem.eql(u8, self.movement_identity, access.identity) or self.movement_camera == null) return error.InvalidFieldActorState;
        const program = binding.content.program(self.instance.?.program_id) orelse return error.InvalidFieldActorState;
        var hero_job: ?ordinary.TrackJob = null;
        for (jobs) |entry| if (entry) |job| {
            const track = binding.content.tracks[job.track];
            const origin = for (program.commands, 0..) |command, i| {
                if (command.kind == .queue_track and std.mem.eql(u8, command.track.?, track.id)) break i;
            } else return error.InvalidFieldActorState;
            if (self.instance.?.execution.pc <= origin) return error.InvalidFieldActorState;
            if (job.actor == 255) hero_job = job;
        };
        if (hero_job) |job| {
            if (self.hero.speed != job.state.motion or self.hero.x < 0 or self.hero.x > 2040 or self.hero.y < 0 or self.hero.y > 2040 or @mod(self.hero.x, 8) != 0 or @mod(self.hero.y, 8) != 0 or @abs(@as(i32, self.hero.offset_x)) > 8 or @abs(@as(i32, self.hero.offset_y)) > 8 or (self.hero.offset_x != 0 and self.hero.offset_y != 0) or (!job.state.active and self.hero.moving())) return error.InvalidFieldActorState;
            const expected = self.heroTrackCamera(binding);
            const camera = self.movement_camera.?;
            if (@abs(@as(i64, camera.x) - expected.x) > 8 or @abs(@as(i64, camera.y) - expected.y) > 8) return error.InvalidFieldActorState;
        } else if (!std.meta.eql(self.movement_camera.?, access.camera)) return error.InvalidFieldActorState;
    } else if (self.movement_identity.len != 0 or self.movement_camera != null) return error.InvalidFieldActorState;
    if (self.selected_program and binding.ordinary != null and self.ordinary_actors == null) return error.MissingFieldActorConstruction;
    const old9 = std.mem.eql(u8, self.schema, "suikoden-field-event/9");
    const old10 = std.mem.eql(u8, self.schema, "suikoden-field-event/10");
    const legacy_settled = (old9 or old10) and !self.busy() and self.party_queue == null and self.text_job == null and self.boxes[0].phase == .closed and self.boxes[1].phase == .closed and self.hero_sprite == null and self.hero_sha256.len == 0 and (!old9 or self.graphics_sha256.len == 0);
    if ((!legacy_settled and !std.mem.eql(u8, self.schema, "suikoden-field-event/11") and !std.mem.eql(u8, self.schema, "suikoden-field-event/12") and !std.mem.eql(u8, self.schema, "suikoden-field-event/13") and !std.mem.eql(u8, self.schema, "suikoden-field-event/14") and !std.mem.eql(u8, self.schema, "suikoden-field-event/15") and !std.mem.eql(u8, self.schema, "suikoden-field-event/16") and !std.mem.eql(u8, self.schema, "suikoden-field-event/17") and !std.mem.eql(u8, self.schema, "suikoden-field-event/18")) or !std.mem.eql(u8, self.content_sha256, binding.content.content_sha256) or !std.mem.eql(u8, self.population_sha256, binding.population.content_sha256) or !std.mem.eql(u8, self.queue_sha256, binding.queues.content_sha256) or !std.mem.eql(u8, self.dialogue_sha256, binding.dialogue.content_sha256)) return error.FieldEventIdentityMismatch;
    if (!(legacy_settled and old9) and !std.mem.eql(u8, self.graphics_sha256, if (binding.queues.graphics) |graphics| graphics.content_sha256 else "")) return error.FieldEventIdentityMismatch;
    if (!legacy_settled and !std.mem.eql(u8, self.hero_sha256, binding.hero_sha256)) return error.FieldEventIdentityMismatch;
    try validateHeroSpriteState(self, binding, false);
    try validateInitializations(self, binding, false);
    try validateRuntimeQueuesAndActors(self, binding);
    try validateInstanceState(self, binding, false);
    try validateAudioState(self, binding, true);
}

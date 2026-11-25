const std = @import("std");
const field = @import("field");
const events = @import("../field_events.zig");
const runtime = @import("event_runtime");
const motion = @import("opening_audience");
const state_mod = @import("../field_events_state.zig");
const actor_commands = @import("actor_commands.zig");
const dialogue_commands = @import("dialogue_commands.zig");

const Session = events.Session;
const Binding = events.Binding;

fn applyCameraPush(self: *Session, binding: Binding, command: runtime.Command) !bool {
    if (!binding.content.hasCameraPush() or !binding.scripted_motion or !self.selected_program or !self.initialization_done or binding.room_package == null)
        return false;
    if (self.camera_push != null or self.alignment != null or self.activeTracks() != 0 or
        (self.scripted_camera != null and self.scripted_camera.?.pan != null)) return error.FieldEventBusy;
    const start: motion.Point = .{ .x = self.hero.x, .y = self.hero.y };
    self.camera_push = .{ .command = command.origin, .start = start, .model = try runtime.camera_push.State.begin(command.push.?, &self.hero) };
    return true;
}

fn applyWheel(self: *Session, binding: Binding, command: runtime.Command, state: *field.State) !bool {
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
    return true;
}

fn applyFieldEffect(self: *Session, binding: Binding, command: runtime.Command) !bool {
    if (!self.initialization_done or binding.room_package == null or !binding.content.hasFieldEffects()) return false;
    if (self.field_effect) |effect| if (effect.model.clock.callback != null) return error.FieldEffectStillActive;
    self.field_effect = .{
        .command = command.origin,
        .position = .{ .x = command.x.?, .y = command.y.? },
        .model = field.area_effect.Effect.init(command.effect.?),
    };
    return true;
}

fn applyPlaceHero(self: *Session, binding: Binding, command: runtime.Command, state: *field.State) !bool {
    const package = binding.room_package orelse return false;
    const x = command.x.?;
    const y = command.y.?;
    const scenery = if (state.room_scenery) |*value| value else null;
    if (!package.rooms[state.room].canStandWithScenery(scenery, x, y)) return error.InvalidFieldEventTransition;
    self.hero = .{ .x = x, .y = y, .speed = self.hero.speed };
    state.x = x;
    state.y = y;
    state.destination = .{ .x = x, .y = y };
    return true;
}

fn applyPan(self: *Session, binding: Binding, command: runtime.Command) !bool {
    if (!binding.scripted_motion or !self.selected_program) return false;
    var camera: state_mod.ScriptedCamera = self.scripted_camera orelse .{};
    camera.pan = .{ .dx = command.dx.?, .dy = command.dy.?, .remaining = command.updates.? };
    try camera.validate();
    self.scripted_camera = camera;
    return true;
}

fn applyCue(self: *Session, binding: Binding, command: runtime.Command) bool {
    const access = binding.audio orelse return false;
    const previous = access.initial_cached_command orelse return false;
    if (!self.selected_program or !std.mem.eql(u8, self.instance.?.program_id, "vaa_room2_audience") or command.origin != 28 or command.cue != 0x422 or access.identity.len != 64 or !std.mem.eql(u8, access.audience_path, "audience.wav") or self.audio_cached_command != null or self.audio_request != null) return false;
    self.audio_identity = access.identity;
    self.audio_cached_command = 0x422;
    self.area_command = 0x422;
    if (previous != 0x422) self.audio_request = .{ .batch = self.instance.?.pending.?.batch.id, .command = 0x422, .origin = command.origin, .track = .audience };
    self.schema = "suikoden-field-event/14";
    return true;
}

fn applyAreaAction(binding: Binding, command: runtime.Command, state: *field.State) !bool {
    const action = command.area.?;
    if (binding.room_package == null) return false;
    if (action.kind == .room_flag) {
        try state.local_flags.orByte(action.id, action.bits);
    } else if (action.isAuxiliaryPartyEdit()) {
        var auxiliary = state.auxiliary_party orelse return error.MissingAuxiliaryPartyState;
        field.editAuxiliaryParty(&auxiliary, action.kind == .auxiliary_party_add, action.character);
        state.auxiliary_party = auxiliary;
    } else return false;
    return true;
}

fn applyRoomTransition(self: *Session, binding: Binding, command: runtime.Command, state: *field.State) !bool {
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
    return true;
}

fn applyWorldTransition(self: *Session, binding: Binding, command: runtime.Command, state: *field.State) !bool {
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
    return true;
}

fn applyMoneyEdit(binding: Binding, command: runtime.Command, state: *field.State) bool {
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
    return true;
}

fn applyTileVariant(binding: Binding, command: runtime.Command, state: *field.State) bool {
    if (!binding.content.isCampaign()) return false;
    const slot = command.index.? & 31;
    switch (command.parameter.?) {
        0 => state.tile_variants[slot] +%= 1,
        1 => state.tile_variants[slot] -%= 1,
        2 => {},
        3 => state.tile_variants[slot] = command.value orelse 0,
        else => return false,
    }
    return true;
}

pub noinline fn apply(self: *Session, binding: Binding, command: runtime.Command, state: *field.State) !bool {
    switch (command.kind) {
        .camera_push => return applyCameraPush(self, binding, command),
        .hide_hero => return binding.content.hasHeroVisibility() and self.initialization_done and !self.hero.moving(),
        .wheel_restore, .wheel_turn, .wheel_align => return applyWheel(self, binding, command, state),
        .field_effect => return applyFieldEffect(self, binding, command),
        .field_music => {
            if (self.instance == null or binding.content.program(self.instance.?.program_id).?.entry != .initialization or command.music != .headquarters) return false;
            state.music = .headquarters;
        },
        .set_camera => {
            if (!binding.content.hasFadeIn() or !self.initialization_done) return false;
            self.scripted_camera = .{ .scroll = .{ .x = command.x.?, .y = command.y.? }, .absolute = true };
        },
        .align_hero => self.alignment = try motion.Alignment.start(self.hero.x, self.hero.y, command.x.?, command.y.?),
        .place_hero => return applyPlaceHero(self, binding, command, state),
        .pan => return applyPan(self, binding, command),
        .spawn_actor => return actor_commands.applySpawnActor(self, binding, command),
        .release_actor => return actor_commands.applyReleaseActor(self, binding, command),
        .place_actor => return actor_commands.applyPlaceActor(self, binding, command),
        .actor_x, .actor_y => return actor_commands.applyActorAxis(self, binding, command),
        .actor_transition, .source_hero_transition => return actor_commands.applyActorTransition(self, binding, command),
        .queue_track => return actor_commands.applyQueueTrack(self, binding, command),
        .delay, .source_timer => {
            const duration = command.updates orelse return false;
            if (duration == 0 or self.delay_remaining != 0) return false;
            self.delay_remaining = duration;
        },
        .cue => return applyCue(self, binding, command),
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
        .area_action => return applyAreaAction(binding, command, state),
        .request_area_party_prefix => return actor_commands.applyRequestAreaPartyPrefix(self, command),
        .queue_glyphs_a, .queue_glyphs_b => return actor_commands.applyQueueGlyphs(self, binding, command),
        .open_fixed_box => return dialogue_commands.applyOpenFixedBox(self, binding, command),
        .open_box => return dialogue_commands.applyOpenBox(self, binding, command),
        .close_box => return dialogue_commands.applyCloseBox(self, command),
        .start_or_wait_dialogue, .speaker => return dialogue_commands.applyDialoguePrefix(self, binding, command),
        .text => return dialogue_commands.applyText(self, binding, command),
        .choice => return dialogue_commands.applyChoice(self, command),
        .source_move_batch => return actor_commands.applySourceMoveBatch(self, command),
        .descriptor_display => return actor_commands.applyDescriptorDisplay(self, binding, command),
        .spatial_object_probe => return actor_commands.applySpatialObjectProbe(self, binding, command),
        .descriptor_flags => return actor_commands.applyDescriptorFlags(self, binding, command),
        .fade_in => {
            if (!self.initialization_done or !binding.content.hasFadeIn()) return false;
            try self.fade_state.requestIn();
            if (self.hero_descriptor_state) |*retained| retained.tint_word = 0x80;
        },
        .fade_out => {
            if (!self.initialization_done) return false;
            try self.fade_state.request();
        },
        .room_transition => return applyRoomTransition(self, binding, command, state),
        .world_transition => return applyWorldTransition(self, binding, command, state),
        .room_flag_clear => {
            if (binding.room_package == null) return false;
            const index = command.index.?;
            if (index >= state.local_flags.values.len) return false;
            state.local_flags.values[index] &= ~command.mask.?;
        },
        .money_edit => return applyMoneyEdit(binding, command, state),
        .tile_variant => return applyTileVariant(binding, command, state),
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

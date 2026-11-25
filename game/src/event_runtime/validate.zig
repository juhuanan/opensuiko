//! Static validation for event IR content, commands, selections, and branch actor paths.
const std = @import("std");
const runtime = @import("../event_runtime.zig");
const schema = @import("schema.zig");
const story_mod = @import("story.zig");
const vm = @import("vm.zig");

const Command = runtime.Command;
const Content = runtime.Content;
const Program = runtime.Program;

pub fn semanticEqual(a: anytype, b: @TypeOf(a)) bool {
    return switch (@typeInfo(@TypeOf(a))) {
        .@"struct" => blk: {
            inline for (comptime std.meta.fieldNames(@TypeOf(a))) |name| {
                if (!semanticEqual(@field(a, name), @field(b, name))) break :blk false;
            }
            break :blk true;
        },
        .optional => if (a) |value| (if (b) |other| semanticEqual(value, other) else false) else b == null,
        .pointer => |info| if (info.size == .slice) blk: {
            if (a.len != b.len) break :blk false;
            for (a, b) |x, y| if (!semanticEqual(x, y)) break :blk false;
            break :blk true;
        } else a == b,
        else => a == b,
    };
}

pub fn validDrawRecordBytes(bytes: []const u8) bool {
    if (bytes.len < 3 or bytes.len % 2 == 0 or bytes[bytes.len - 1] != 5) return false;
    var cursor: usize = 0;
    while (cursor + 1 < bytes.len) : (cursor += 2) {
        const code = bytes[cursor];
        const value = bytes[cursor + 1];
        if (code > 4 and code != 6 and code != 7) return false;
        if ((code == 4 and value == 255) or (code == 7 and value == 0)) return false;
    }
    return cursor + 1 == bytes.len;
}

pub fn validId(id: []const u8) !void {
    if (id.len == 0 or id.len > 96) return error.InvalidEventId;
    for (id) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return error.InvalidEventId;
}

pub fn validateFlag(content: Content, value: story_mod.Flag) !void {
    if (value.mask == 0 or content.storyValue(value.id) == null) return error.UnknownStoryValue;
}

pub fn validateConditions(content: Content, conditions: []const story_mod.Condition) !void {
    if (conditions.len > 16) return error.TooManyEventConditions;
    for (conditions) |entry| try validateFlag(content, entry.flag);
}

fn validAreaAction(action: runtime.AreaAction) bool {
    return switch (action.kind) {
        .sprite_upload => action.upload.len >= 1 and action.upload.len <= 25 and
            action.upload[0] <= 8 and action.upload.len == 1 + 3 * @as(usize, action.upload[0]),
        .room_flag => action.id < 20,
        .roster_remove, .roster_add => action.character != 0xFF,
        .auxiliary_party_add, .auxiliary_party_remove => semanticEqual(action, runtime.AreaAction{ .kind = action.kind, .character = action.character }),
        .fade_in => true,
        .sprite_spawn => action.id < 8,
        .sprite_flag => action.id < 8,
        .area_transition => true,
        .dialogue_box => true,
        .flow_switch => action.upload.len >= 2 and action.upload.len <= 64,
        .ui_dispatch => true,
        .tile_variant => action.op <= 3,
        .pan => action.updates > 0,
        .party_order => action.upload.len <= 6,
        .fade_out_1 => true,
        .camera_scroll => true,
        .area_callback => action.selector == 0 or action.selector == 1 or (action.selector >= 2 and action.selector <= 6),
        .descriptor_field => action.style <= 6,
        .palette_reupload => true,
        .tile_entry_free => true,
        .glyph_queue_a, .glyph_queue_b, .text_queue_wait => true,
        .area_effect => true,
    };
}

fn validateSelection(selection: []const runtime.Selection) !void {
    if (selection.len > 16) return error.TooManyEventSelections;
    for (selection) |entry| switch (entry.kind) {
        .hero_x_inclusive, .hero_y_inclusive, .hero_x_strict, .hero_y_strict => if (entry.min > entry.max) return error.InvalidEventSelection,
        .pressed_mask => if (entry.mask == 0) return error.InvalidEventSelection,
        .room_mask_set, .room_mask_clear => if (entry.index >= 20 or entry.mask == 0) return error.InvalidEventSelection,
        .party_absent, .party_contains => if (entry.index == 0) return error.InvalidEventSelection,
        .story_mask_set, .story_mask_clear => {
            const flag = entry.flag orelse return error.InvalidEventSelection;
            if (flag.mask == 0 or story_mod.parseScenarioId(flag.id) == null) return error.InvalidEventSelection;
        },
        .confirm_pressed, .money_at_least => {},
        .party_count_equals => if (entry.index > 6) return error.InvalidEventSelection,
        .recruit_present, .recruit_absent, .recruit_ever => if (entry.index >= 108) return error.InvalidEventSelection,
        .recruit_count_at_least => if (entry.index > 108) return error.InvalidEventSelection,
        .level_at_least => {},
        .stage_at_least => if (entry.min >= 5) return error.InvalidEventSelection,
        .random_chance => if (entry.divisor == 0) return error.InvalidEventSelection,
        .has_item => {},
    };
}

pub fn validateWait(wait: runtime.Wait) !void {
    if (wait.id.len > 96 or !std.unicode.utf8ValidateSlice(wait.id)) return error.InvalidEventWait;
}

pub fn validateCommand(self: Content, command: Command, count: usize, index: usize) !void {
    const version = schema.parseVersion(self.schema) orelse 0;
    if (command.actor) |id| if (!self.knownActor(id)) return error.UnknownEventActor;
    if (command.text) |id| if (self.text(id) == null) return error.UnknownEventText;
    if (command.track) |id| if (self.track(id) == null) return error.UnknownEventTrack;
    if (command.flag) |value| try validateFlag(self, value);
    if (command.requires) |required| try validateWait(required);
    if (command.wait) |pending| try validateWait(pending);
    if ((command.requires != null and command.requires.?.kind == .camera_push) or
        (command.wait != null and command.wait.?.kind == .camera_push and command.kind != .camera_push)) return error.InvalidEventWait;
    if (command.push != null and command.kind != .camera_push) return error.InvalidEventCommand;
    if ((command.requires != null and command.requires.?.kind == .field_effect) or
        (command.wait != null and command.wait.?.kind == .field_effect)) return error.InvalidEventWait;
    if (command.updates) |updates| if ((updates == 0 and command.kind != .wheel_turn) or updates > 4096) return error.InvalidEventDuration;
    if (command.kind == .jump and (command.target == null or command.target.? >= count or command.targets != null)) return error.InvalidEventBranch;
    if (command.kind == .branch_choice) {
        if (command.targets) |targets| {
            if (command.target != null or targets.len == 0 or targets.len > 3) return error.InvalidEventBranch;
            for (targets) |target| if (target >= count) return error.InvalidEventBranch;
        } else if (command.target == null or command.target.? >= count) return error.InvalidEventBranch;
    }
    if (!vm.isBranch(command.kind) and (command.target != null or command.targets != null)) return error.InvalidEventCommand;
    if (command.kind == .branch_wheel or command.kind == .branch_castle_tier or command.kind == .branch_party) {
        const targets = command.targets orelse return error.InvalidEventBranch;
        const count_required: usize = switch (command.kind) {
            .branch_wheel => 7,
            .branch_castle_tier => 3,
            .branch_party => 2,
            else => unreachable,
        };
        if (command.target != null or targets.len != count_required) return error.InvalidEventBranch;
        for (targets) |target| if (target >= count) return error.InvalidEventBranch;
    }
    if (command.kind == .item_overload) try validId(command.item_name orelse return error.InvalidEventCommand);
    if (command.kind != .room_transition and command.arrival_facing != null) return error.InvalidEventCommand;
    if (command.source_arrival and (command.kind != .room_transition or !self.hasQueuedMusic())) return error.InvalidEventCommand;
    if (command.kind != .field_music and command.music != null) return error.InvalidEventCommand;
    if (command.kind != .field_effect and command.effect != null) return error.InvalidEventCommand;
    if (command.kind != .party_select and command.required_party != null) return error.InvalidEventCommand;
    if (command.level_advances) |adv| if ((command.kind != .party_join and command.kind != .advance_character) or adv == 0 or adv > 99) return error.InvalidEventCommand;
    if (command.add_hero_level) |enabled| if (!enabled or command.kind != .advance_character) return error.InvalidEventCommand;
    if (command.defeat_ends_run and (command.kind != .battle or command.defeat_target != null)) return error.InvalidEventCommand;
    if (command.hp_only and command.kind != .party_restore) return error.InvalidEventCommand;
    for ([_]?u16{ command.escape_target, command.defeat_target }) |branch| if (branch) |target| {
        if (command.kind != .battle) return error.InvalidEventCommand;
        if (target >= count) return error.InvalidEventBranch;
    };
    const valid = switch (command.kind) {
        .choice => command.box != null and command.box.? <= 1 and command.options != null and command.options.? >= 2 and command.options.? <= 4,
        .story_or, .story_andnot => command.flag != null,
        .show_prop => self.hasProps() and command.prop != null and semanticEqual(command, Command{ .kind = .show_prop, .prop = command.prop, .origin = command.origin }),
        .dialogue_cleanup => true,
        .area_action => command.area != null and validAreaAction(command.area.?) and
            (!command.area.?.isAuxiliaryPartyEdit() or (self.hasFieldEffects() and
                semanticEqual(command, Command{ .kind = .area_action, .area = command.area, .origin = command.origin }))),
        .request_area_party_prefix => command.requested_prefix != null and command.requested_prefix.?.len > 0 and command.requested_prefix.?.len <= 6 and command.scope != null and std.mem.eql(u8, command.scope.?, "area_transient"),
        .descriptor_flags => command.selector != null and command.parameter != null and command.mask != null,
        .descriptor_display => command.selector != null and command.selector.? < 64 and command.parameter != null and command.parameter.? <= 2 and command.value != null,
        .spatial_object_probe => command.selector == 0x80,
        .open_fixed_box => self.hasFixedBoxes() and command.box != null and command.box.? <= 1 and
            command.x != null and command.y != null and command.width != null and command.height != null and
            command.x.? >= 8 and command.y.? >= 8 and command.width.? >= 16 and command.height.? >= 12 and
            command.x.? <= 312 - @as(i32, command.width.?) and command.y.? <= 232 - @as(i32, command.height.?) and
            command.width.? % 8 == 0 and command.height.? % 12 == 0 and command.actor == null and command.layout == null and command.wait == null,
        .open_box, .close_box => command.box != null and command.box.? <= 1,
        .speaker => command.box != null and command.image != null and command.name != null,
        .text => command.box != null and command.text != null,
        .queue_track => command.track != null,
        .queue_draw_record => command.selector != null and command.glyph_bytes != null and
            command.countdown != null and command.flags != null and validDrawRecordBytes(command.glyph_bytes.?),
        .fade_in => self.hasFadeIn() and command.wait != null and command.wait.?.kind == .fade and std.mem.eql(u8, command.wait.?.id, "fade") and
            semanticEqual(command, Command{ .kind = .fade_in, .wait = command.wait, .origin = command.origin }),
        .fade_out => command.blend_mode == 2 and command.draw_slot == 10 and command.updates == null and command.wait != null and command.wait.?.kind == .fade and std.mem.eql(u8, command.wait.?.id, "fade"),
        .delay => command.updates != null,
        .pan => command.dx != null and command.dy != null and command.updates != null,
        .cue => command.cue != null,
        .play_sound => command.cue != null and ((command.cue.? >= 0x500 and command.cue.? <= 0x5ff) or
            (self.hasFieldEffects() and command.cue.? == 0x813 and semanticEqual(command, Command{ .kind = .play_sound, .cue = 0x813, .origin = command.origin }))) and command.wait == null,
        .field_music => self.hasFieldMusic() and command.music != null and (command.music.? != .area_b or self.hasMansionMusic()) and
            (command.music.? != .fade or self.hasQueuedMusic()) and
            (command.music.? != .founding or self.hasFieldEffects()) and
            (command.music.? != .infiltration or self.hasFadeIn()) and
            (command.music.? != .mansion or self.hasMansionMusic()) and
            (command.music.? != .wheel or self.hasWheelMusic()) and
            (command.music.? != .headquarters or version >= 13) and command.wait == null,
        .hide_hero => self.hasHeroVisibility() and semanticEqual(command, Command{ .kind = .hide_hero, .origin = command.origin }),
        .item_overload => self.hasItemOverload() and command.item_name != null and
            semanticEqual(command, Command{ .kind = .item_overload, .item_name = command.item_name, .origin = command.origin }),
        .wheel_spin, .wheel_restore, .wheel_align => self.hasWheelMotion() and
            semanticEqual(command, Command{ .kind = command.kind, .origin = command.origin }),
        .wheel_turn => self.hasWheelMotion() and command.updates != null and command.updates.? <= 255 and
            semanticEqual(command, Command{ .kind = .wheel_turn, .updates = command.updates, .origin = command.origin }),
        .branch_wheel => self.hasWheelMotion() and command.targets != null and
            semanticEqual(command, Command{ .kind = .branch_wheel, .targets = command.targets, .origin = command.origin }),
        .branch_castle_tier => (self.hasBranchHistory() or self.hasActorOwners()) and command.targets != null and
            semanticEqual(command, Command{ .kind = .branch_castle_tier, .targets = command.targets, .origin = command.origin }),
        .branch_party => self.hasActorOwners() and command.index != null and command.index.? < 108 and command.targets != null and
            semanticEqual(command, Command{ .kind = .branch_party, .index = command.index, .targets = command.targets, .origin = command.origin }),
        .field_effect => self.hasFieldEffects() and command.fieldEffectOperation() != null,
        .wait_field_effect => self.hasFieldEffects() and command.wait == null and command.requires == null,
        .camera_push => self.hasCameraPush() and command.push != null and push_valid: {
            command.push.?.validate() catch break :push_valid false;
            break :push_valid semanticEqual(command, Command{ .kind = .camera_push, .push = command.push, .wait = .{ .kind = .camera_push, .id = "camera_push" }, .origin = command.origin });
        },
        .scenery_stage, .scenery_restore, .scenery_append => self.hasSceneryMutations() and command.sceneryOperation() != null and
            semanticEqual(command, Command{ .kind = command.kind, .scenery_object = command.scenery_object, .origin = command.origin }),
        .sequence_input => self.hasSceneryMutations() and command.flag != null and command.flag.?.mask == 255 and
            command.parameter != null and command.value != null and command.value.? <= 1 and
            semanticEqual(command, Command{ .kind = .sequence_input, .flag = command.flag, .parameter = command.parameter, .value = command.value, .origin = command.origin }),
        .align_hero => command.x != null and command.y != null,
        .place_hero => command.x != null and command.y != null and command.wait == null,
        .set_camera, .set_hero_display => command.x != null and command.y != null and command.wait == null and
            command.x.? >= 0 and command.x.? <= 2040 and command.y.? >= 0 and command.y.? <= 2040,
        .battle => command.battle != null and command.battle.?.len > 0 and command.battle.?.len <= 96,
        .party_load => self.hasCharacters() and command.character != null and command.level_advances == null and command.wait == null,
        .advance_character => self.hasCharacters() and command.character != null and command.level_advances != null and command.wait == null,
        .party_gain_experience, .party_lose_experience => self.hasPartyExperience() and
            semanticEqual(command, Command{ .kind = command.kind, .origin = command.origin }),
        .party_join => command.character != null and command.wait == null,
        .party_leave => command.character != null and command.wait == null and (command.value == null or command.value == 1),
        .party_restore => (version == 2 or version >= 14) and
            semanticEqual(command, Command{ .kind = .party_restore, .hp_only = command.hp_only, .origin = command.origin }),
        .party_dismiss => self.hasFieldEffects() and semanticEqual(command, Command{ .kind = .party_dismiss, .origin = command.origin }),
        .rune_grant => command.character != null and command.rune != null and command.wait == null,
        .inventory_edit => command.character != null and command.inventory != null and command.wait == null,
        .warehouse_deposit => self.hasCharacters() and command.character != null and
            semanticEqual(command, Command{ .kind = .warehouse_deposit, .character = command.character, .origin = command.origin }),
        .shared_inventory_edit => command.character == null and command.inventory != null and command.wait == null,
        .room_transition => command.roomTransition() != null,
        .world_transition => command.worldTransition() != null,
        .actor_transition => command.actorFacing() != null,
        .next_variant, .previous_variant, .wait_variant, .release_actor => command.actor != null,
        .set_variant => command.actor != null and command.variant != null,
        .place_actor => self.hasActorPositions() and command.actorPlacement() != null and self.actor(command.actor.?) != null and
            (command.x == null or command.y == null or (self.hasFieldEffects() and semanticEqual(command, Command{
                .kind = .place_actor,
                .actor = command.actor,
                .x = command.x,
                .y = command.y,
                .if_actor_constructed = command.if_actor_constructed,
                .origin = command.origin,
            }))),
        .actor_motion => command.actorMotionRestore() != null,
        .actor_x, .actor_y => command.actorAxisMove() != null,
        .spawn_actor => self.hasSceneActors() and command.actor != null and self.actor(command.actor.?) != null and
            semanticEqual(command, Command{ .kind = .spawn_actor, .actor = command.actor, .origin = command.origin }),
        .create_double => command.actor != null and command.character != null and command.x != null and command.y != null,
        .follow_character => command.character != null,
        .start_or_wait_dialogue => command.box != null and command.code != null,
        .source_move_batch => command.source_offset != null and (command.source_offset.? == 0x3d17c or command.source_offset.? == 0x3d181 or command.source_offset.? == 0x3d19f),
        .native_slot_prefix => command.source_offset != null and (command.source_offset.? == 0x3d195 or command.source_offset.? == 0x3d1cb) and command.box == 0 and command.code == 108,
        .source_release_descriptor => command.source_offset == 0x3d1a4 and command.selector == 0,
        .source_party_add => command.source_offset == 0x3d1a6 and command.code == 108,
        .source_spawn_text => command.source_offset == 0x3d1c5 and command.box == 0 and command.x == 10 and command.y == 10 and command.width == 12 and command.height == 2,
        .source_close_keep_image => command.source_offset == 0x3d1d3 and command.box == 0,
        .source_hero_transition => command.selector == 0x80 and ((command.source_offset == 0x3d18d and command.transition == 1) or (command.source_offset == 0x3d1ac and command.transition == 2) or (command.source_offset == 0x3d1b1 and command.transition == 3) or (command.source_offset == 0x3d1b6 and command.transition == 0) or (command.source_offset == 0x3d1bb and command.transition == 1) or (command.source_offset == 0x3d1c0 and command.transition == 2)),
        .source_hero_alignment => command.source_offset == 0x3d18a and command.x == 27 and command.y == 30,
        .source_area_command => command.source_offset == 0x3d1a8 and command.selector == 0x96 and command.cue == 0x52a,
        .source_timer => command.source_offset != null and (command.source_offset.? == 0x3d1aa or command.source_offset.? == 0x3d1af or command.source_offset.? == 0x3d1b4 or command.source_offset.? == 0x3d1b9 or command.source_offset.? == 0x3d1be or command.source_offset.? == 0x3d1c3) and command.updates == 5 and command.wait != null and command.wait.?.kind == .delay and std.mem.eql(u8, command.wait.?.id, "delay"),
        .inn_stay => command.amount != null and command.amount.? <= std.math.maxInt(u16) and command.wait == null,
        .room_flag_clear => command.index != null and command.index.? < 20 and command.mask != null and command.mask.? != 0,
        .world_mode => command.code != null,
        .soul_eater_advance => command.wait == null and command.requires == null,
        .money_edit => command.parameter != null and command.amount != null and (command.failure_target == null or command.failure_target.? < count),
        .recruit_toggle => command.index != null and command.index.? < 108,
        .recruit_mark_loaded => command.index != null and command.index.? < 108,
        .service => blk: {
            const facility = command.fieldService() orelse break :blk false;
            if (command.facility != null) break :blk switch (facility) {
                .save_point, .storage, .cup_game, .card_game, .teleport, .bathhouse, .tablet, .library, .window_styles, .sound_themes, .music_player => semanticEqual(command, Command{ .kind = .service, .facility = facility, .origin = command.origin }),
                else => false,
            };
            if (command.index == null) break :blk false;
            if (command.shop_items) |items| {
                if (facility != .shop or items.len == 0 or items.len > 8) break :blk false;
                for (items) |id| try validId(id);
            }
            break :blk true;
        },
        .chest_grant => command.item_name != null and command.item_name.?.len != 0 and
            command.failure_target != null and command.failure_target.? < count and semanticEqual(command, Command{
            .kind = .chest_grant,
            .item_name = command.item_name,
            .flag = command.flag,
            .failure_target = command.failure_target,
            .origin = command.origin,
        }),
        .tile_variant => command.parameter != null and command.parameter.? <= 3 and command.index != null,
        .auto_route => command.value != null,
        .special_checkpoint => command.selector != null,
        .fixed_dice => command.wait == null and command.requires == null,
        .party_select => blk: {
            if (version < 15) break :blk false;
            if (command.parameter != null and command.parameter != 5) break :blk false;
            if (command.index) |requested| {
                const required = command.required_party orelse break :blk false;
                if (command.parameter != 5 or required.len == 0 or required.len > 5 or
                    std.mem.indexOfScalar(u8, required, requested) == null) break :blk false;
                for (required, 0..) |member, member_index| {
                    if (member == 0 or member >= 108 or std.mem.indexOfScalar(u8, required[0..member_index], member) != null) break :blk false;
                }
            } else if (command.required_party != null) break :blk false;
            break :blk semanticEqual(command, Command{
                .kind = .party_select,
                .parameter = command.parameter,
                .index = command.index,
                .required_party = command.required_party,
                .origin = command.origin,
            });
        },
        else => true,
    };
    if (!valid) return error.InvalidEventCommand;
    if (command.return_to_entry and (!self.hasWorldEntries() or command.kind != .world_transition)) return error.InvalidEventCommand;
    if (command.retain_world_region and (!self.hasWorldEntries() or command.kind != .world_transition)) return error.InvalidEventCommand;
    if (command.world_point != null and (!self.hasWorldEntries() or command.kind != .room_transition)) return error.InvalidEventCommand;
    if (command.world_entry) |entry| {
        if (!self.hasWorldEntries() or command.kind != .room_transition) return error.InvalidEventCommand;
        try validId(entry);
    }
    if (command.kind != .service and (command.shop_items != null or command.facility != null)) return error.InvalidEventCommand;
    if (!self.isCampaign() and @backingInt(command.kind) >= @backingInt(@FieldType(Command, "kind").room_flag_clear)) return error.InvalidEventCommand;
    if (command.source_offset != null and !std.mem.eql(u8, self.id, "va1_room2_field_events")) return error.InvalidEventCommand;
    if ((command.kind == .room_transition or command.kind == .world_transition) and !command.retainsWorldRegion()) try validId(command.destination.?);
    if (vm.isPartyMutation(command.kind) and command.kind != .party_dismiss and command.kind != .party_gain_experience and command.kind != .party_lose_experience) try validId(command.character orelse return error.InvalidEventCommand);
    if (command.rune) |rune| {
        if (command.kind != .rune_grant or rune.len == 0 or rune.len > 96 or !std.unicode.utf8ValidateSlice(rune)) return error.InvalidEventId;
    }
    if (command.inventory) |edit| {
        if ((command.kind != .inventory_edit and command.kind != .shared_inventory_edit) or
            (edit.give == null and edit.take == null)) return error.InvalidEventCommand;
        if (edit.failure_target >= count) return error.InvalidEventBranch;
        if (edit.give) |id| try validId(id);
        if (edit.take) |id| try validId(id);
    }
    if ((command.kind == .world_transition or (command.kind == .room_transition and !self.isCampaign())) and index + 1 != count) return error.InvalidEventEnd;
}

pub fn forwardGraph(self: Content) bool {
    for (self.programs) |entry| for (entry.commands, 0..) |command, index| {
        if (command.target) |target| if (target <= index) return false;
        if (command.targets) |targets| for (targets) |target| {
            if (target <= index) return false;
        };
        for ([_]?u16{ command.escape_target, command.defeat_target, command.failure_target, if (command.inventory) |edit| edit.failure_target else null }) |target| {
            if (target != null and target.? <= index) return false;
        }
    };
    return true;
}

pub fn validateContent(self: Content) !void {
    if (!schema.isKnown(self.schema)) return error.UnsupportedEventSchema;
    if (self.hasActorOwners()) {
        if (self.forward_branches == null or self.forward_branches.? != forwardGraph(self)) return error.InvalidEventBranch;
    } else if (self.forward_branches != null) return error.InvalidEventBranch;
    const is_campaign = self.isCampaign();
    try validId(self.id);
    const program_cap: usize = if (is_campaign) runtime.campaign_max_programs else runtime.max_programs;
    const actor_cap: usize = if (is_campaign) 255 else 64;
    const text_cap: usize = if (is_campaign) 1024 else 254;
    const command_cap: usize = if (is_campaign) 2048 else 512;
    if (self.content_sha256.len != 64 or self.story_values.len > 240 or (self.programs.len == 0 and !is_campaign and !std.mem.eql(u8, self.id, "va1_room2_field_events")) or self.programs.len > program_cap) return error.InvalidEventContent;
    for (self.content_sha256) |byte| if (!std.ascii.isHex(byte)) return error.InvalidEventIdentity;
    for (self.story_values, 0..) |entry, i| {
        try validId(entry.id);
        const index = story_mod.parseScenarioId(entry.id) orelse return error.InvalidStoryValue;
        if (index >= 240 or index != entry.byte_index) return error.InvalidStoryValue;
        for (self.story_values[0..i]) |other| if (std.mem.eql(u8, entry.id, other.id) or entry.byte_index == other.byte_index) return error.DuplicateStoryValue;
    }
    if (self.actors.len > actor_cap or self.texts.len > text_cap or self.tracks.len > actor_cap) return error.InvalidEventContent;
    for (self.actors, 0..) |entry, i| {
        try validId(entry.id);
        if (runtime.partyActorIndex(entry.id) != null) return error.ReservedEventActor;
        try validateConditions(self, entry.conditions);
        for (self.actors[0..i]) |other| if (std.mem.eql(u8, entry.id, other.id)) return error.DuplicateEventActor;
    }
    for (self.texts, 0..) |entry, i| {
        try validId(entry.id);
        if (entry.tokens.len == 0 or entry.tokens.len > 4096) return error.InvalidEventText;
        for (self.texts[0..i]) |other| if (std.mem.eql(u8, entry.id, other.id)) return error.DuplicateEventText;
        for (entry.tokens) |token| if (token.text) |glyph| if (!std.unicode.utf8ValidateSlice(glyph)) return error.InvalidEventText;
    }
    const version = schema.parseVersion(self.schema) orelse 0;
    for (self.tracks, 0..) |entry, i| {
        try validId(entry.id);
        const party_actor = self.hasPartyTracks() and runtime.partyActorIndex(entry.actor) != null;
        if ((!self.knownActor(entry.actor) and !party_actor) or entry.commands.len == 0 or entry.commands.len > 64) return error.InvalidEventTrack;
        for (self.tracks[0..i]) |other| if (std.mem.eql(u8, entry.id, other.id)) return error.DuplicateEventTrack;
        for (entry.commands) |command| {
            if ((command.kind == .hold) != (command.updates != null)) return error.InvalidEventTrack;
            if (command.updates) |updates| if (version < 4 or updates == 0 or updates > 1275 or updates % 5 != 0 or command.direction != null or command.cells != null or command.motion != null) return error.InvalidEventTrack;
            if (command.kind == .hop and (version < 5 or command.direction != null or command.cells != null or command.motion != null)) return error.InvalidEventTrack;
        }
    }
    for (self.programs, 0..) |entry, i| {
        const track_branches = self.tracksBranchHistory(entry);
        try validId(entry.id);
        try validateConditions(self, entry.conditions);
        try validateSelection(entry.selection);
        if (entry.commands.len == 0 or entry.commands.len > command_cap or
            !vm.endsEvent(entry.commands[entry.commands.len - 1].kind)) return error.InvalidEventProgram;
        for (self.programs[0..i]) |other| if (std.mem.eql(u8, entry.id, other.id)) return error.DuplicateEventProgram;
        if (entry.owner_actor) |owner| if (!self.hasFadeIn() or entry.entry != .ordinary or entry.trigger != .interaction or self.actor(owner) == null) return error.InvalidEventActor;
        if (entry.owner_actors) |owners| {
            if (!self.hasActorOwners() or entry.owner_actor != null or entry.entry != .ordinary or entry.trigger != .interaction or owners.len != 1) return error.InvalidEventActor;
            for (owners, 0..) |owner, index| {
                if (self.actor(owner) == null) return error.InvalidEventActor;
                for (owners[0..index]) |prior| if (std.mem.eql(u8, owner, prior)) return error.InvalidEventActor;
            }
        }
        const actor_suffix = for (entry.commands, 0..) |command, index| {
            if (command.kind == .spawn_actor or command.kind == .place_actor or command.kind == .release_actor or command.kind == .queue_track) break index;
        } else entry.commands.len;
        for (entry.commands, 0..) |command, command_index| {
            if (command.kind == .hide_hero and !track_branches) {
                if (entry.entry != .ordinary) return error.InvalidEventCommand;
                var restored = false;
                for (entry.commands[command_index + 1 ..]) |later| {
                    if (later.kind == .place_hero) {
                        restored = true;
                        break;
                    }
                    if (later.kind == .end_stream or later.kind == .room_transition or later.kind == .world_transition) break;
                }
                if (!restored) return error.InvalidEventCommand;
                // shortcut: visibility follows a linear prefix; qualify branch lifetimes for another caller.
                for (entry.commands) |other| if (vm.isBranch(other.kind) or other.kind == .choice or
                    other.escape_target != null or other.defeat_target != null or other.failure_target != null or other.inventory != null) return error.InvalidEventCommand;
            }
            if (command.kind == .hide_hero and entry.entry != .ordinary) return error.InvalidEventCommand;
            if (track_branches) {
                if (command.target) |target| if (target <= command_index) return error.InvalidEventBranch;
                if (command.targets) |targets| for (targets) |target| {
                    if (target <= command_index) return error.InvalidEventBranch;
                };
                for ([_]?u16{ command.escape_target, command.defeat_target, command.failure_target, if (command.inventory) |edit| edit.failure_target else null }) |target| {
                    if (target) |value| if (value <= command_index) return error.InvalidEventBranch;
                }
            }
            if (command.prop != null and command.kind != .show_prop) return error.InvalidEventCommand;
            if (command.kind == .camera_push) {
                if (entry.entry != .ordinary) return error.InvalidEventCommand;
                // Source reloop bypasses the frame guard and needs separate ownership.
                for (entry.commands) |other| if (other.kind == .continue_tick) return error.InvalidEventCommand;
            }
            if (command.kind == .area_action and command.area != null and command.area.?.isAuxiliaryPartyEdit() and entry.entry != .ordinary) return error.InvalidEventCommand;
            if ((command.kind == .field_effect or command.kind == .wait_field_effect or command.kind == .party_restore or command.kind == .party_dismiss or command.kind == .fade_in or command.kind == .party_gain_experience or command.kind == .party_lose_experience or vm.isWheelControl(command.kind) or command.kind == .item_overload or command.kind == .warehouse_deposit or command.kind == .branch_castle_tier) and entry.entry != .ordinary) return error.InvalidEventCommand;
            if ((command.kind == .set_camera or command.kind == .set_hero_display) and
                ((!self.isScene()) or (entry.entry != .initialization and !(self.hasFadeIn() and entry.entry == .ordinary and command.kind == .set_camera)))) return error.InvalidEventCommand;
            try validateCommand(self, command, entry.commands.len, command_index);
            if (command.kind == .branch_party and (entry.entry != .ordinary or (entry.trigger != .none and entry.trigger != .interaction))) return error.InvalidEventCommand;
            if (command.kind == .room_transition and command_index + 1 != entry.commands.len) {
                if (entry.commands[command_index + 1].kind != .end_stream) return error.InvalidEventEnd;
                for (entry.commands[0..command_index]) |prior| {
                    if (prior.kind == .branch_choice or prior.kind == .branch_castle_tier) break;
                } else return error.InvalidEventEnd;
            }
            if (command.facility != null and (entry.entry != .ordinary or entry.trigger != .interaction or
                command_index + 1 == entry.commands.len or entry.commands[command_index + 1].kind != .end_stream)) return error.InvalidEventCommand;
            if (command.if_actor_constructed != null and
                (command_index == 0 or command_index >= entry.commands.len -| 2 or !self.actorInitialization(entry))) return error.InvalidEventCommand;
            if (command.kind == .party_load or command.kind == .advance_character or command.kind == .field_music) {
                const music_entry = command.kind == .field_music and command.music == .headquarters and entry.entry == .initialization;
                if (music_entry) {
                    if (entry.commands.len != 2 or command_index != 0 or entry.commands[1].kind != .end_stream) return error.InvalidEventCommand;
                } else if (entry.entry != .ordinary or (command.kind == .field_music and command.music == .headquarters and !self.hasFieldEffects())) return error.InvalidEventCommand;
                if (!music_entry and command.kind == .field_music and (command.music == .headquarters or command.music == .founding)) {
                    if (!semanticEqual(command, Command{ .kind = .field_music, .music = command.music, .origin = command.origin })) return error.InvalidEventCommand;
                    for (entry.commands) |other| if (vm.isBranch(other.kind) or other.kind == .choice or
                        other.escape_target != null or other.defeat_target != null or other.failure_target != null or other.inventory != null) return error.InvalidEventCommand;
                }
                for (entry.commands) |other| if (other.kind == .continue_tick) return error.InvalidEventCommand;
            }
            // shortcut: admit re-loop fade callers when their within-pump scheduling is qualified.
            if (command.kind == .fade_in) for (entry.commands) |other| {
                if (other.kind == .continue_tick) return error.InvalidEventCommand;
            };
            if (command.kind == .spawn_actor and !track_branches) for (entry.commands[0..command_index]) |prior| {
                const target = if (prior.kind == .queue_track) self.track(prior.track.?).?.actor else prior.actor orelse continue;
                if (std.mem.eql(u8, target, command.actor.?)) return error.InvalidEventCommand;
            };
            if (self.hasActorPositions() and !track_branches) for (entry.commands[0..command_index]) |prior| {
                if (prior.kind != .release_actor) continue;
                const target = if (command.kind == .queue_track) self.track(command.track.?).?.actor else command.actor orelse continue;
                if (std.mem.eql(u8, target, prior.actor.?)) return error.InvalidEventCommand;
            };
            if (command.kind == .spawn_actor or command.kind == .place_actor or command.kind == .open_fixed_box or (command.kind == .release_actor and self.hasActorPositions())) {
                if (command.kind != .open_fixed_box and (command.actor == null or self.actor(command.actor.?) == null)) return error.InvalidEventCommand;
                if (entry.entry != .ordinary and !(command.kind == .place_actor and self.actorInitialization(entry))) return error.InvalidEventCommand;
                if (command.kind == .release_actor and (command.wait != null or command.requires != null)) return error.InvalidEventCommand;
                // Older packets reconstruct the committed linear prefix.
                if (!track_branches) for (entry.commands, 0..) |other, prior| {
                    if (vm.isBranch(other.kind)) {
                        if (!self.hasFadeIn() or command.kind == .open_fixed_box or prior >= actor_suffix) return error.InvalidEventCommand;
                        if (other.targets) |targets| {
                            for (targets) |target| if (target > actor_suffix) return error.InvalidEventCommand;
                        } else if ((other.target orelse return error.InvalidEventBranch) > actor_suffix) return error.InvalidEventCommand;
                    }
                    if ((command.kind == .open_fixed_box and other.kind == .choice) or other.escape_target != null or other.defeat_target != null or other.failure_target != null or other.inventory != null) return error.InvalidEventCommand;
                    if (command.kind == .place_actor and prior < command_index and other.kind == .queue_track and std.mem.eql(u8, self.track(other.track.?).?.actor, command.actor.?)) {
                        var waited = false;
                        if (self.hasHeroVisibility()) for (entry.commands[prior + 1 .. command_index]) |between| {
                            if (between.kind == .wait_tracks) waited = true;
                        };
                        if (!waited) return error.InvalidEventCommand;
                    }
                };
            }
        }
        if (track_branches) try validateActorPaths(self, entry);
    }
}

fn validateActorPaths(self: Content, entry_program: Program) !void {
    const Phase = enum { absent, active, released };
    const Path = struct { pc: u16 = 0, edges: u8 = 0, actors: [255]Phase = @splat(.active), queued: [255]bool = @splat(false), hero_visible: bool = true };
    var scene_owned: [255]bool = @splat(false);
    var initial: Path = .{};
    for (entry_program.commands) |command| if (command.kind == .spawn_actor) {
        for (self.actors, 0..) |definition, i| if (std.mem.eql(u8, definition.id, command.actor.?)) {
            scene_owned[i] = true;
            initial.actors[i] = .absent;
        };
    };
    var work: [32]Path = undefined;
    work[0] = initial;
    var count: usize = 1;
    while (count != 0) {
        count -= 1;
        var path = work[count];
        while (path.pc < entry_program.commands.len) {
            const command = entry_program.commands[path.pc];
            const target = if (command.kind == .queue_track) self.track(command.track.?).?.actor else command.actor;
            if (target) |id| for (self.actors, 0..) |definition, i| {
                if (!std.mem.eql(u8, definition.id, id)) continue;
                if (command.kind == .spawn_actor) {
                    if (path.actors[i] != .absent) return error.InvalidEventActorLifetime;
                    path.actors[i] = .active;
                } else {
                    if (path.actors[i] != .active) return error.InvalidEventActorLifetime;
                    if ((command.kind == .place_actor or command.kind == .release_actor) and path.queued[i]) return error.InvalidEventActorLifetime;
                    if (command.kind == .release_actor) path.actors[i] = .released;
                    if (command.kind == .queue_track) path.queued[i] = true;
                }
            };
            if (command.kind == .hide_hero) path.hero_visible = false;
            if (command.kind == .place_hero) path.hero_visible = true;
            if (command.kind == .wait_tracks) path.queued = @splat(false);
            if (vm.endsEvent(command.kind)) {
                if (!path.hero_visible) return error.InvalidEventActorLifetime;
                for (scene_owned, path.actors) |owned, phase| if (owned and phase == .active) return error.InvalidEventActorLifetime;
                break;
            }
            var targets: [10]u16 = undefined;
            var target_count: usize = 0;
            const branching = vm.isBranch(command.kind);
            if (branching) {
                if (command.targets) |values| {
                    for (values) |value| {
                        targets[target_count] = value;
                        target_count += 1;
                    }
                } else if (command.target) |value| {
                    targets[target_count] = value;
                    target_count += 1;
                }
                if (command.kind == .branch_choice) {
                    targets[target_count] = path.pc + 1;
                    target_count += 1;
                }
            } else {
                for ([_]?u16{ command.escape_target, command.defeat_target, command.failure_target, if (command.inventory) |edit| edit.failure_target else null }) |value| {
                    if (value) |index| {
                        targets[target_count] = index;
                        target_count += 1;
                    }
                }
            }
            for (targets[0..target_count], 0..) |index, i| {
                if (path.edges == 8) return error.EventBranchHistoryFull;
                if (branching and i == 0) continue;
                if (count == work.len) return error.EventBranchHistoryFull;
                work[count] = path;
                work[count].pc = index;
                work[count].edges += 1;
                count += 1;
            }
            if (branching) {
                path.pc = targets[0];
                path.edges += 1;
            } else path.pc += 1;
        }
    }
}

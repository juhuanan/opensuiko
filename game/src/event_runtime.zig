const std = @import("std");
pub const camera_push = @import("field_camera_push.zig");

pub const schema = "suikoden-event-ir/1";
pub const campaign_schema = "suikoden-event-ir/2";
pub const scene_schema = "suikoden-event-ir/3";
pub const motion_schema = "suikoden-event-ir/4";
pub const hop_schema = "suikoden-event-ir/5";
pub const party_track_schema = "suikoden-event-ir/6";
pub const party_scene_schema = "suikoden-event-ir/7";
pub const position_schema = "suikoden-event-ir/8";
pub const fixed_box_schema = "suikoden-event-ir/9";
pub const character_schema = "suikoden-event-ir/10";
pub const music_schema = "suikoden-event-ir/11";
pub const queued_music_schema = "suikoden-event-ir/12";
pub const entry_music_schema = "suikoden-event-ir/13";
pub const field_effect_schema = "suikoden-event-ir/14";
pub const party_select_schema = "suikoden-event-ir/15";
pub const scene_actor_schema = "suikoden-event-ir/16";
pub const fade_in_schema = "suikoden-event-ir/17";
pub const prop_schema = "suikoden-event-ir/18";
pub const mansion_music_schema = "suikoden-event-ir/19";
pub const party_experience_schema = "suikoden-event-ir/20";
pub const wheel_music_schema = "suikoden-event-ir/21";
pub const wheel_motion_schema = "suikoden-event-ir/22";
pub const item_overload_schema = "suikoden-event-ir/23";
pub const hero_visibility_schema = "suikoden-event-ir/24";
pub const branch_history_schema = "suikoden-event-ir/25";
pub const world_entry_schema = "suikoden-event-ir/26";
pub const actor_owners_schema = "suikoden-event-ir/27";
pub const camera_push_schema = "suikoden-event-ir/28";
pub const scenery_mutation_schema = "suikoden-event-ir/29";
pub const FieldEffect = enum { appearance, disappearance };
pub const FieldMusic = enum { stop, fade, area_b, ruins, lakeshore, headquarters, founding, infiltration, mansion, wheel };
pub const FieldService = enum { shop, blacksmith, rune_master, appraisal, save_point, storage, cup_game, card_game, teleport, bathhouse, tablet, library, window_styles, sound_themes, music_player };
pub const SoundTheme = enum { standard, chime, reed, pulse, pluck };
pub const WindowAppearance = struct {
    pub const Style = enum { classic, rounded, double, corners, inset };
    pub const Color = enum { blue, slate, forest, teal, plum, burgundy, bronze, graphite };

    style: Style = .classic,
    color: Color = .blue,

    pub fn isDefault(self: WindowAppearance) bool {
        return self.style == .classic and self.color == .blue;
    }
};
pub const party_actor_ids = [_][]const u8{ "party_follower_0", "party_follower_1", "party_follower_2", "party_follower_3", "party_follower_4" };

pub fn partyActorIndex(id: []const u8) ?u3 {
    for (party_actor_ids, 0..) |candidate, index| if (std.mem.eql(u8, id, candidate)) return @intCast(index);
    return null;
}
pub const state_schema = "suikoden-event-state/1";
pub const branch_state_schema = "suikoden-event-state/2";
pub const max_programs = 64;
pub const campaign_max_programs = 255;
pub const max_commands_per_step = 256;
pub const max_batch_effects = 64;

pub const Direction = enum {
    up,
    right,
    down,
    left,

    pub fn fromPadMask(mask: u16) ?Direction {
        return switch (mask) {
            0x1000 => .up,
            0x2000 => .right,
            0x4000 => .down,
            0x8000 => .left,
            else => null,
        };
    }
};
pub const TrackCommand = struct {
    kind: enum { move, advance, set_motion, finish, hold, hop },
    direction: ?Direction = null,
    cells: ?u8 = null,
    motion: ?u8 = null,
    updates: ?u16 = null,

    // Omit the new field on legacy commands so existing scene identities stay stable.
    pub fn jsonStringify(self: TrackCommand, writer: anytype) !void {
        try writer.beginObject();
        inline for (@typeInfo(TrackCommand).@"struct".field_names) |name| {
            const include = if (comptime std.mem.eql(u8, name, "updates")) self.updates != null else true;
            if (include) {
                try writer.objectField(name);
                try writer.write(@field(self, name));
            }
        }
        try writer.endObject();
    }
};
pub const Track = struct { id: []const u8, actor: []const u8, commands: []const TrackCommand };
pub const Token = struct {
    kind: enum { glyph, newline, page, pace, countdown, player_name },
    text: ?[]const u8 = null,
    value: ?u8 = null,
};
pub const Text = struct { id: []const u8, tokens: []const Token };
pub const Flag = struct {
    id: []const u8,
    mask: u8,

    pub fn scenarioIndex(self: Flag) ?u8 {
        const index = parseScenarioId(self.id) orelse return null;
        if (index >= @typeInfo(@FieldType(StoryState, "scenario")).array.len or self.mask == 0) return null;
        for (self.id[9..]) |digit| if (!std.ascii.isDigit(digit)) return null;
        return index;
    }
};
pub const StoryWrite = struct { flag: Flag, clear: bool = false };
pub const Condition = struct { kind: enum { story_mask_set, story_mask_clear }, flag: Flag };
pub const AreaAction = struct {
    kind: enum { sprite_upload, room_flag, roster_remove, roster_add, auxiliary_party_add, auxiliary_party_remove, fade_in, sprite_spawn, sprite_flag, area_transition, dialogue_box, flow_switch, ui_dispatch, tile_variant, pan, party_order, fade_out_1, camera_scroll, area_callback, descriptor_field, palette_reupload, tile_entry_free, glyph_queue_a, glyph_queue_b, text_queue_wait, area_effect },
    id: u8 = 0,
    bits: u8 = 0,
    character: u8 = 0,
    style: u8 = 0,
    selector: u8 = 0,
    skip: u8 = 0,
    tile: u8 = 0,
    op: u8 = 0,
    variant: u8 = 0,
    dx: i32 = 0,
    dy: i32 = 0,
    updates: u16 = 0,
    x: u8 = 0,
    y: u8 = 0,
    w: u8 = 0,
    h: u8 = 0,
    upload: []const u8 = &.{},

    pub fn isAuxiliaryPartyEdit(self: AreaAction) bool {
        return self.kind == .auxiliary_party_add or self.kind == .auxiliary_party_remove;
    }
};
pub const Selection = struct {
    kind: enum {
        hero_x_inclusive,
        hero_y_inclusive,
        hero_x_strict,
        hero_y_strict,
        pressed_mask,
        room_mask_set,
        room_mask_clear,
        party_absent,
        story_mask_set,
        story_mask_clear,
        confirm_pressed,
        money_at_least,
        party_contains,
        recruit_present,
        recruit_absent,
        recruit_ever,
        party_count_equals,
        level_at_least,
        stage_at_least,
        random_chance,
        recruit_count_at_least,
        has_item,
    },
    min: u8 = 0,
    max: u8 = 0,
    index: u8 = 0,
    mask: u16 = 0,
    flag: ?Flag = null,
    amount: u32 = 0,
    divisor: u8 = 0,
    require_key: bool = false, // Legacy wire name: opcode18 requires equipped gear.
};
pub const StoryValue = struct {
    id: []const u8,
    storage: enum { scenario },
    byte_index: u8,
    initial: u8,
};
pub const Actor = struct {
    id: []const u8,
    graphic: []const u8 = "",
    character: ?u8 = null,
    x: i32 = 0,
    y: i32 = 0,
    motion: u8 = 0,
    variant: u8 = 0,
    attached: bool = false,
    auto_animate: bool = false,
    conditions: []const Condition = &.{},
};
pub const Wait = struct {
    kind: enum {
        accept,
        alignment,
        box_closed,
        choice,
        delay,
        camera_push,
        event_flags_low2,
        fade,
        field_effect,
        pan,
        speaker_prefix,
        text,
        text_queue,
        tracks,
        variant,
    },
    id: []const u8 = "",
    command_index: u16 = 0,
};
pub const InventoryEdit = struct {
    give: ?[]const u8 = null,
    take: ?[]const u8 = null,
    failure_target: u16,
};
pub const Command = struct {
    kind: enum {
        align_hero,
        camera_push,
        place_hero,
        set_camera,
        set_hero_display,
        actor_transition,
        open_box,
        open_fixed_box,
        speaker,
        text,
        wait_for_accept,
        close_box,
        queue_track,
        queue_draw_record,
        wait_tracks,
        delay,
        cue,
        play_sound,
        field_music,
        field_effect,
        wait_field_effect,
        pan,
        next_variant,
        previous_variant,
        wait_variant,
        set_variant,
        actor_motion,
        actor_x,
        actor_y,
        place_actor,
        release_actor,
        create_double,
        spawn_actor,
        choice,
        jump,
        branch_choice,
        label,
        free_double,
        follow_character,
        story_or,
        story_andnot,
        dialogue_cleanup,
        area_action,
        wait_boxes,
        continue_tick,
        yield_tick,
        end_stream,
        room_transition,
        battle,
        party_join,
        party_load,
        advance_character,
        party_gain_experience,
        party_lose_experience,
        party_leave,
        party_restore,
        party_dismiss,
        rune_grant,
        inventory_edit,
        fade_out,
        fade_in,
        world_transition,
        request_area_party_prefix,
        queue_glyphs_a,
        queue_glyphs_b,
        wait_text_queue_empty,
        wait_text_queue_drain_and_release,
        start_or_wait_dialogue,
        wait_event_flags_low2,
        descriptor_flags,
        descriptor_display,
        spatial_object_probe,
        source_move_batch,
        native_slot_prefix,
        source_release_descriptor,
        source_party_add,
        source_spawn_text,
        source_close_keep_image,
        source_hero_transition,
        source_hero_alignment,
        source_area_command,
        source_timer,
        shared_inventory_edit,
        inn_stay,
        soul_eater_advance,
        room_flag_clear,
        world_mode,
        money_edit,
        recruit_toggle,
        recruit_mark_loaded,
        service,
        chest_grant,
        tile_variant,
        show_prop,
        auto_route,
        special_checkpoint,
        fixed_dice,
        party_select,
        wheel_spin,
        wheel_restore,
        wheel_turn,
        wheel_align,
        branch_wheel,
        item_overload,
        hide_hero,
        scenery_stage,
        scenery_restore,
        scenery_append,
        sequence_input,
        warehouse_deposit,
        branch_castle_tier,
        branch_party,
    },
    prop: ?u6 = null,
    actor: ?[]const u8 = null,
    character: ?[]const u8 = null,
    rune: ?[]const u8 = null,
    inventory: ?InventoryEdit = null,
    box: ?u8 = null,
    image: ?u8 = null,
    name: ?[]const u8 = null,
    text: ?[]const u8 = null,
    track: ?[]const u8 = null,
    transition: ?u2 = null,
    x: ?i32 = null,
    y: ?i32 = null,
    updates: ?u16 = null,
    cue: ?u16 = null,
    music: ?FieldMusic = null,
    effect: ?FieldEffect = null,
    push: ?camera_push.Request = null,
    dx: ?i32 = null,
    dy: ?i32 = null,
    variant: ?u8 = null,
    value: ?u8 = null,
    options: ?u8 = null,
    target: ?u16 = null,
    targets: ?[]const u16 = null,
    level_advances: ?u8 = null,
    add_hero_level: ?bool = null,
    flag: ?Flag = null,
    requires: ?Wait = null,
    wait: ?Wait = null,
    requested_prefix: ?[]const u8 = null,
    scope: ?[]const u8 = null,
    layout: ?u8 = null,
    code: ?u8 = null,
    area: ?AreaAction = null,
    selector: ?u8 = null,
    shop_items: ?[]const []const u8 = null,
    facility: ?FieldService = null,
    parameter: ?u8 = null,
    destination: ?[]const u8 = null,
    arrival_facing: ?Direction = null,
    source_arrival: bool = false,
    return_to_entry: bool = false,
    retain_world_region: bool = false,
    world_point: ?u8 = null,
    world_entry: ?[]const u8 = null,
    battle: ?[]const u8 = null,
    escape_target: ?u16 = null,
    defeat_target: ?u16 = null,
    defeat_ends_run: bool = false,
    hp_only: bool = false,
    mask: ?u8 = null,
    table: ?u8 = null,
    index: ?u8 = null,
    required_party: ?[]const u8 = null,
    speaker_slot: ?u8 = null,
    blend_mode: ?u8 = null,
    draw_slot: ?u8 = null,
    glyph_bytes: ?[]const u8 = null,
    countdown: ?u8 = null,
    flags: ?u8 = null,
    source_offset: ?u32 = null,
    width: ?u8 = null,
    height: ?u8 = null,
    amount: ?u32 = null,
    item_id: ?u16 = null,
    item_name: ?[]const u8 = null,
    failure_target: ?u16 = null,
    scenery_object: ?u16 = null,
    if_actor_constructed: ?bool = null,
    origin: u16 = 0,

    pub fn retainsWorldRegion(self: Command) bool {
        return self.return_to_entry or self.retain_world_region;
    }

    pub fn fieldService(self: Command) ?FieldService {
        if (self.facility) |facility| return facility;
        return switch (self.selector orelse return null) {
            2 => .shop,
            3 => .blacksmith,
            4 => .rune_master,
            5 => .appraisal,
            else => null,
        };
    }

    pub fn jsonStringify(self: Command, writer: anytype) !void {
        @setEvalBranchQuota(4000);
        try writer.beginObject();
        inline for (comptime std.meta.fieldNames(Command)) |name| {
            if (comptime std.mem.eql(u8, name, "push") or std.mem.eql(u8, name, "effect") or std.mem.eql(u8, name, "music") or std.mem.eql(u8, name, "destination") or std.mem.eql(u8, name, "arrival_facing") or std.mem.eql(u8, name, "rune") or std.mem.eql(u8, name, "inventory") or std.mem.eql(u8, name, "escape_target") or std.mem.eql(u8, name, "defeat_target") or std.mem.eql(u8, name, "amount") or std.mem.eql(u8, name, "item_id") or std.mem.eql(u8, name, "item_name") or std.mem.eql(u8, name, "failure_target") or std.mem.eql(u8, name, "scenery_object") or std.mem.eql(u8, name, "if_actor_constructed") or std.mem.eql(u8, name, "shop_items") or std.mem.eql(u8, name, "facility")) {
                if (@field(self, name)) |id| {
                    try writer.objectField(name);
                    try writer.write(id);
                }
            } else if (comptime std.mem.eql(u8, name, "defeat_ends_run") or std.mem.eql(u8, name, "hp_only") or std.mem.eql(u8, name, "source_arrival") or std.mem.eql(u8, name, "return_to_entry") or std.mem.eql(u8, name, "retain_world_region")) {
                if (@field(self, name)) {
                    try writer.objectField(name);
                    try writer.write(true);
                }
            } else {
                const value = @field(self, name);
                const emit = if (comptime @typeInfo(@TypeOf(value)) == .optional)
                    writer.options.emit_null_optional_fields or value != null
                else
                    true;
                if (emit) {
                    try writer.objectField(name);
                    try writer.write(value);
                }
            }
        }
        try writer.endObject();
    }
};
pub const Program = struct {
    id: []const u8,
    entry: enum { ordinary, initialization },
    entity: u8,
    trigger: enum { none, interaction, area_entry },
    conditions: []const Condition = &.{},
    selection: []const Selection = &.{},
    commands: []const Command,
    owner_actor: ?[]const u8 = null,
    owner_actors: ?[]const []const u8 = null,

    pub fn jsonStringify(self: Program, writer: anytype) !void {
        try writer.beginObject();
        inline for (comptime std.meta.fieldNames(Program)) |name| {
            if (comptime !std.mem.eql(u8, name, "owner_actor") and !std.mem.eql(u8, name, "owner_actors")) {
                try writer.objectField(name);
                try writer.write(@field(self, name));
            } else if (@field(self, name)) |value| {
                try writer.objectField(name);
                try writer.write(value);
            }
        }
        try writer.endObject();
    }
};
pub const Content = struct {
    schema: []const u8,
    id: []const u8,
    content_sha256: []const u8,
    story_values: []const StoryValue = &.{},
    actors: []const Actor = &.{},
    texts: []const Text = &.{},
    tracks: []const Track = &.{},
    programs: []const Program,
    forward_branches: ?bool = null,

    pub fn program(self: Content, id: []const u8) ?Program {
        for (self.programs) |entry| if (std.mem.eql(u8, entry.id, id)) return entry;
        return null;
    }
    pub fn storyValue(self: Content, id: []const u8) ?StoryValue {
        for (self.story_values) |entry| if (std.mem.eql(u8, entry.id, id)) return entry;
        return null;
    }
    pub fn text(self: Content, id: []const u8) ?Text {
        for (self.texts) |entry| if (std.mem.eql(u8, entry.id, id)) return entry;
        return null;
    }
    pub fn track(self: Content, id: []const u8) ?Track {
        for (self.tracks) |entry| if (std.mem.eql(u8, entry.id, id)) return entry;
        return null;
    }
    pub fn actor(self: Content, id: []const u8) ?Actor {
        for (self.actors) |entry| if (std.mem.eql(u8, entry.id, id)) return entry;
        return null;
    }
    fn knownActor(self: Content, id: []const u8) bool {
        if (self.hasPartyScene() and partyActorIndex(id) != null) return true;
        return std.mem.eql(u8, id, "hero") or std.mem.eql(u8, id, "audience_double") or self.actor(id) != null;
    }
    fn validateFlag(self: Content, value: Flag) !void {
        if (value.mask == 0 or self.storyValue(value.id) == null) return error.UnknownStoryValue;
    }
    fn validateConditions(self: Content, conditions: []const Condition) !void {
        if (conditions.len > 16) return error.TooManyEventConditions;
        for (conditions) |entry| try self.validateFlag(entry.flag);
    }
    fn validAreaAction(action: AreaAction) bool {
        return switch (action.kind) {
            .sprite_upload => action.upload.len >= 1 and action.upload.len <= 25 and
                action.upload[0] <= 8 and action.upload.len == 1 + 3 * @as(usize, action.upload[0]),
            .room_flag => action.id < 20,
            .roster_remove, .roster_add => action.character != 0xFF,
            .auxiliary_party_add, .auxiliary_party_remove => semanticEqual(action, AreaAction{ .kind = action.kind, .character = action.character }),
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
    fn validateSelection(selection: []const Selection) !void {
        if (selection.len > 16) return error.TooManyEventSelections;
        for (selection) |entry| switch (entry.kind) {
            .hero_x_inclusive, .hero_y_inclusive, .hero_x_strict, .hero_y_strict => if (entry.min > entry.max) return error.InvalidEventSelection,
            .pressed_mask => if (entry.mask == 0) return error.InvalidEventSelection,
            .room_mask_set, .room_mask_clear => if (entry.index >= 20 or entry.mask == 0) return error.InvalidEventSelection,
            .party_absent, .party_contains => if (entry.index == 0) return error.InvalidEventSelection,
            .story_mask_set, .story_mask_clear => {
                const flag = entry.flag orelse return error.InvalidEventSelection;
                if (flag.mask == 0 or parseScenarioId(flag.id) == null) return error.InvalidEventSelection;
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
    fn validateWait(wait: Wait) !void {
        if (wait.id.len > 96 or !std.unicode.utf8ValidateSlice(wait.id)) return error.InvalidEventWait;
    }
    fn validateCommand(self: Content, command: Command, count: usize, index: usize) !void {
        if (command.actor) |id| if (!self.knownActor(id)) return error.UnknownEventActor;
        if (command.text) |id| if (self.text(id) == null) return error.UnknownEventText;
        if (command.track) |id| if (self.track(id) == null) return error.UnknownEventTrack;
        if (command.flag) |value| try self.validateFlag(value);
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
        if (!isBranch(command.kind) and (command.target != null or command.targets != null)) return error.InvalidEventCommand;
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
                (command.music.? != .headquarters or std.mem.eql(u8, self.schema, entry_music_schema) or self.hasFieldEffects()) and command.wait == null,
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
            .field_effect => self.hasFieldEffects() and command.effect != null and command.x != null and command.y != null and
                command.x.? >= 0 and command.x.? <= 2040 and @mod(command.x.?, 8) == 0 and
                command.y.? >= 0 and command.y.? <= 2040 and @mod(command.y.?, 8) == 0 and command.wait == null and command.requires == null,
            .wait_field_effect => self.hasFieldEffects() and command.wait == null and command.requires == null,
            .camera_push => self.hasCameraPush() and command.push != null and push_valid: {
                command.push.?.validate() catch break :push_valid false;
                break :push_valid semanticEqual(command, Command{ .kind = .camera_push, .push = command.push, .wait = .{ .kind = .camera_push, .id = "camera_push" }, .origin = command.origin });
            },
            .scenery_stage, .scenery_restore, .scenery_append => self.hasSceneryMutations() and command.scenery_object != null and
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
            .party_restore => (std.mem.eql(u8, self.schema, campaign_schema) or self.hasFieldEffects()) and
                semanticEqual(command, Command{ .kind = .party_restore, .hp_only = command.hp_only, .origin = command.origin }),
            .party_dismiss => self.hasFieldEffects() and semanticEqual(command, Command{ .kind = .party_dismiss, .origin = command.origin }),
            .rune_grant => command.character != null and command.rune != null and command.wait == null,
            .inventory_edit => command.character != null and command.inventory != null and command.wait == null,
            .warehouse_deposit => self.hasCharacters() and command.character != null and
                semanticEqual(command, Command{ .kind = .warehouse_deposit, .character = command.character, .origin = command.origin }),
            .shared_inventory_edit => command.character == null and command.inventory != null and command.wait == null,
            .room_transition => command.destination != null and command.x != null and command.y != null and
                command.x.? >= 0 and command.x.? <= 2040 and @mod(command.x.?, 8) == 0 and
                command.y.? >= 0 and command.y.? <= 2040 and @mod(command.y.?, 8) == 0,
            .world_transition => if (command.return_to_entry)
                self.hasWorldEntries() and command.destination == null and command.x == null and command.y == null
            else
                (command.destination != null or (self.hasWorldEntries() and command.retain_world_region)) and command.x != null and command.y != null and
                    command.x.? >= 0 and command.x.? <= 255 and command.y.? >= 0 and command.y.? <= 255,
            .actor_transition => command.actor != null and command.transition != null,
            .next_variant, .previous_variant, .wait_variant, .release_actor => command.actor != null,
            .set_variant => command.actor != null and command.variant != null,
            .place_actor => self.hasActorPositions() and command.actor != null and self.actor(command.actor.?) != null and
                (command.x != null or command.y != null) and command.wait == null and command.requires == null and
                (command.x == null or command.y == null or (self.hasFieldEffects() and semanticEqual(command, Command{
                    .kind = .place_actor,
                    .actor = command.actor,
                    .x = command.x,
                    .y = command.y,
                    .if_actor_constructed = command.if_actor_constructed,
                    .origin = command.origin,
                }))) and
                (if (command.x) |x| x >= 0 and x <= 2040 and @mod(x, 8) == 0 else true) and
                (if (command.y) |y| y >= 0 and y <= 2040 and @mod(y, 8) == 0 else true),
            .actor_motion, .actor_x, .actor_y => command.actor != null and command.value != null,
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
                if (!std.mem.eql(u8, self.schema, party_select_schema) and !self.hasSceneActors()) break :blk false;
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
        if (command.retain_world_region and (!self.hasWorldEntries() or command.kind != .world_transition or command.return_to_entry or command.destination != null)) return error.InvalidEventCommand;
        if (command.world_point != null and (!self.hasWorldEntries() or command.kind != .room_transition)) return error.InvalidEventCommand;
        if (command.world_entry) |entry| {
            if (!self.hasWorldEntries() or command.kind != .room_transition or command.world_point != null) return error.InvalidEventCommand;
            try validId(entry);
        }
        if (command.kind != .service and (command.shop_items != null or command.facility != null)) return error.InvalidEventCommand;
        if (!self.isCampaign() and @backingInt(command.kind) >= @backingInt(@FieldType(Command, "kind").room_flag_clear)) return error.InvalidEventCommand;
        if (command.source_offset != null and !std.mem.eql(u8, self.id, "va1_room2_field_events")) return error.InvalidEventCommand;
        if ((command.kind == .room_transition or command.kind == .world_transition) and !command.retainsWorldRegion()) try validId(command.destination.?);
        if (isPartyMutation(command.kind) and command.kind != .party_dismiss and command.kind != .party_gain_experience and command.kind != .party_lose_experience) try validId(command.character orelse return error.InvalidEventCommand);
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
    pub fn isCampaign(self: Content) bool {
        return std.mem.eql(u8, self.schema, campaign_schema) or self.isScene();
    }
    pub fn isScene(self: Content) bool {
        return std.mem.eql(u8, self.schema, scene_schema) or std.mem.eql(u8, self.schema, motion_schema) or std.mem.eql(u8, self.schema, hop_schema) or self.hasPartyTracks();
    }
    pub fn hasPartyTracks(self: Content) bool {
        return std.mem.eql(u8, self.schema, party_track_schema) or self.hasPartyScene();
    }
    pub fn hasPartyScene(self: Content) bool {
        return std.mem.eql(u8, self.schema, party_scene_schema) or self.hasActorPositions();
    }
    pub fn actorInitialization(self: Content, entry: Program) bool {
        if (!self.hasActorOwners() or entry.entry != .initialization or entry.commands.len < 4 or entry.commands.len > max_batch_effects + 3 or
            entry.commands[0].kind != .continue_tick or entry.commands[entry.commands.len - 2].kind != .yield_tick or
            entry.commands[entry.commands.len - 1].kind != .end_stream) return false;
        for (entry.commands[1 .. entry.commands.len - 2]) |command| {
            if (command.wait != null or command.requires != null) return false;
            if (command.if_actor_constructed) |guard| {
                if (!guard or !self.hasSceneryMutations()) return false;
            } else {
                if (command.kind == .place_hero or command.kind == .story_or or command.kind == .story_andnot or command.kind == .scenery_stage or command.kind == .scenery_append or command.kind == .set_camera) continue;
                if (command.kind == .actor_transition and command.actor != null and std.mem.eql(u8, command.actor.?, "hero")) continue;
            }
            if ((command.kind != .place_actor and command.kind != .actor_transition and command.kind != .actor_motion) or
                (command.kind == .actor_motion and (command.value == null or command.value.? > 1)) or command.wait != null or command.requires != null or
                command.actor == null or std.mem.eql(u8, command.actor.?, "hero") or partyActorIndex(command.actor.?) != null or self.actor(command.actor.?) == null) return false;
        }
        return true;
    }
    pub fn hasActorPositions(self: Content) bool {
        return std.mem.eql(u8, self.schema, position_schema) or self.hasFixedBoxes();
    }
    pub fn hasFixedBoxes(self: Content) bool {
        return std.mem.eql(u8, self.schema, fixed_box_schema) or self.hasCharacters();
    }
    pub fn hasCharacters(self: Content) bool {
        return std.mem.eql(u8, self.schema, character_schema) or self.hasFieldMusic();
    }
    pub fn hasFieldMusic(self: Content) bool {
        return std.mem.eql(u8, self.schema, music_schema) or self.hasQueuedMusic();
    }
    pub fn hasQueuedMusic(self: Content) bool {
        return std.mem.eql(u8, self.schema, queued_music_schema) or std.mem.eql(u8, self.schema, entry_music_schema) or self.hasFieldEffects();
    }
    pub fn hasFieldEffects(self: Content) bool {
        return std.mem.eql(u8, self.schema, field_effect_schema) or std.mem.eql(u8, self.schema, party_select_schema) or self.hasSceneActors();
    }
    pub fn hasSceneActors(self: Content) bool {
        return std.mem.eql(u8, self.schema, scene_actor_schema) or self.hasFadeIn();
    }
    pub fn hasFadeIn(self: Content) bool {
        return std.mem.eql(u8, self.schema, fade_in_schema) or self.hasProps();
    }
    pub fn hasProps(self: Content) bool {
        return std.mem.eql(u8, self.schema, prop_schema) or self.hasMansionMusic();
    }
    pub fn hasMansionMusic(self: Content) bool {
        return std.mem.eql(u8, self.schema, mansion_music_schema) or self.hasPartyExperience();
    }
    pub fn hasPartyExperience(self: Content) bool {
        return std.mem.eql(u8, self.schema, party_experience_schema) or self.hasWheelMusic();
    }
    pub fn hasWheelMusic(self: Content) bool {
        return std.mem.eql(u8, self.schema, wheel_music_schema) or self.hasWheelMotion();
    }
    pub fn hasWheelMotion(self: Content) bool {
        return std.mem.eql(u8, self.schema, wheel_motion_schema) or self.hasItemOverload();
    }
    pub fn hasItemOverload(self: Content) bool {
        return std.mem.eql(u8, self.schema, item_overload_schema) or self.hasHeroVisibility();
    }
    pub fn hasHeroVisibility(self: Content) bool {
        return std.mem.eql(u8, self.schema, hero_visibility_schema) or std.mem.eql(u8, self.schema, branch_history_schema) or self.hasWorldEntries();
    }
    pub fn hasBranchHistory(self: Content) bool {
        if (self.hasActorOwners()) return self.forward_branches orelse false;
        return std.mem.eql(u8, self.schema, branch_history_schema) or self.hasWorldEntries();
    }
    pub fn tracksBranchHistory(self: Content, entry: Program) bool {
        if (self.hasBranchHistory()) return true;
        if (self.hasActorOwners()) for (entry.commands) |command| {
            if (command.kind == .branch_castle_tier or command.kind == .branch_party) return true;
        };
        return false;
    }
    pub fn hasWorldEntries(self: Content) bool {
        return std.mem.eql(u8, self.schema, world_entry_schema) or self.hasActorOwners();
    }
    pub fn hasActorOwners(self: Content) bool {
        return std.mem.eql(u8, self.schema, actor_owners_schema) or self.hasCameraPush();
    }
    pub fn hasCameraPush(self: Content) bool {
        return std.mem.eql(u8, self.schema, camera_push_schema) or self.hasSceneryMutations();
    }
    pub fn hasSceneryMutations(self: Content) bool {
        return std.mem.eql(u8, self.schema, scenery_mutation_schema);
    }
    fn forwardGraph(self: Content) bool {
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
    pub fn needsWorldContext(self: Content) bool {
        for (self.programs) |entry| for (entry.commands) |command| {
            if (command.return_to_entry or command.retain_world_region or command.world_point != null or command.world_entry != null) return true;
        };
        return false;
    }
    pub fn validate(self: Content) !void {
        if (self.hasActorOwners()) {
            if (self.forward_branches == null or self.forward_branches.? != self.forwardGraph()) return error.InvalidEventBranch;
        } else if (self.forward_branches != null) return error.InvalidEventBranch;
        const is_campaign = self.isCampaign();
        if (!is_campaign and !std.mem.eql(u8, self.schema, schema)) return error.UnsupportedEventSchema;
        try validId(self.id);
        const program_cap: usize = if (is_campaign) campaign_max_programs else max_programs;
        const actor_cap: usize = if (is_campaign) 255 else 64;
        const text_cap: usize = if (is_campaign) 1024 else 254;
        const command_cap: usize = if (is_campaign) 2048 else 512;
        if (self.content_sha256.len != 64 or self.story_values.len > 240 or (self.programs.len == 0 and !is_campaign and !std.mem.eql(u8, self.id, "va1_room2_field_events")) or self.programs.len > program_cap) return error.InvalidEventContent;
        for (self.content_sha256) |byte| if (!std.ascii.isHex(byte)) return error.InvalidEventIdentity;
        for (self.story_values, 0..) |entry, i| {
            try validId(entry.id);
            const index = parseScenarioId(entry.id) orelse return error.InvalidStoryValue;
            if (index >= 240 or index != entry.byte_index) return error.InvalidStoryValue;
            for (self.story_values[0..i]) |other| if (std.mem.eql(u8, entry.id, other.id) or entry.byte_index == other.byte_index) return error.DuplicateStoryValue;
        }
        if (self.actors.len > actor_cap or self.texts.len > text_cap or self.tracks.len > actor_cap) return error.InvalidEventContent;
        for (self.actors, 0..) |entry, i| {
            try validId(entry.id);
            if (partyActorIndex(entry.id) != null) return error.ReservedEventActor;
            try self.validateConditions(entry.conditions);
            for (self.actors[0..i]) |other| if (std.mem.eql(u8, entry.id, other.id)) return error.DuplicateEventActor;
        }
        for (self.texts, 0..) |entry, i| {
            try validId(entry.id);
            if (entry.tokens.len == 0 or entry.tokens.len > 4096) return error.InvalidEventText;
            for (self.texts[0..i]) |other| if (std.mem.eql(u8, entry.id, other.id)) return error.DuplicateEventText;
            for (entry.tokens) |token| if (token.text) |glyph| if (!std.unicode.utf8ValidateSlice(glyph)) return error.InvalidEventText;
        }
        for (self.tracks, 0..) |entry, i| {
            try validId(entry.id);
            const party_actor = self.hasPartyTracks() and partyActorIndex(entry.actor) != null;
            if ((!self.knownActor(entry.actor) and !party_actor) or entry.commands.len == 0 or entry.commands.len > 64) return error.InvalidEventTrack;
            for (self.tracks[0..i]) |other| if (std.mem.eql(u8, entry.id, other.id)) return error.DuplicateEventTrack;
            for (entry.commands) |command| {
                if ((command.kind == .hold) != (command.updates != null)) return error.InvalidEventTrack;
                if (command.updates) |updates| if ((!std.mem.eql(u8, self.schema, motion_schema) and !std.mem.eql(u8, self.schema, hop_schema) and !self.hasPartyTracks()) or updates == 0 or updates > 1275 or updates % 5 != 0 or command.direction != null or command.cells != null or command.motion != null) return error.InvalidEventTrack;
                if (command.kind == .hop and ((!std.mem.eql(u8, self.schema, hop_schema) and !self.hasPartyTracks()) or command.direction != null or command.cells != null or command.motion != null)) return error.InvalidEventTrack;
            }
        }
        for (self.programs, 0..) |entry, i| {
            const track_branches = self.tracksBranchHistory(entry);
            try validId(entry.id);
            try self.validateConditions(entry.conditions);
            try validateSelection(entry.selection);
            if (entry.commands.len == 0 or entry.commands.len > command_cap or
                !endsEvent(entry.commands[entry.commands.len - 1].kind)) return error.InvalidEventProgram;
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
                    for (entry.commands) |other| if (isBranch(other.kind) or other.kind == .choice or
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
                if ((command.kind == .field_effect or command.kind == .wait_field_effect or command.kind == .party_restore or command.kind == .party_dismiss or command.kind == .fade_in or command.kind == .party_gain_experience or command.kind == .party_lose_experience or isWheelControl(command.kind) or command.kind == .item_overload or command.kind == .warehouse_deposit or command.kind == .branch_castle_tier) and entry.entry != .ordinary) return error.InvalidEventCommand;
                if ((command.kind == .set_camera or command.kind == .set_hero_display) and
                    ((!self.isScene()) or (entry.entry != .initialization and !(self.hasFadeIn() and entry.entry == .ordinary and command.kind == .set_camera)))) return error.InvalidEventCommand;
                try self.validateCommand(command, entry.commands.len, command_index);
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
                        for (entry.commands) |other| if (isBranch(other.kind) or other.kind == .choice or
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
                        if (isBranch(other.kind)) {
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
            if (track_branches) try self.validateActorPaths(entry);
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
                if (endsEvent(command.kind)) {
                    if (!path.hero_visible) return error.InvalidEventActorLifetime;
                    for (scene_owned, path.actors) |owned, phase| if (owned and phase == .active) return error.InvalidEventActorLifetime;
                    break;
                }
                var targets: [10]u16 = undefined;
                var target_count: usize = 0;
                const branching = isBranch(command.kind);
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
};

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

fn validId(id: []const u8) !void {
    if (id.len == 0 or id.len > 96) return error.InvalidEventId;
    for (id) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return error.InvalidEventId;
}

pub fn validate(content: Content) !void {
    try content.validate();
}

pub const StoryState = struct {
    schema: []const u8 = "suikoden-event-story/1",
    scenario: [240]u8 = @splat(0),
    recruit_flags: [108]u8 = @splat(0),
    castle_tier: u8 = 0,
    world_mode: u8 = 0,
    soul_eater_spell_slots: u8 = 1,
    library_books: u8 = 0,
    window_appearance: WindowAppearance = .{},
    sound_theme: SoundTheme = .standard,
    save_counter: u32 = 0,

    pub fn hasWindowStyle(self: StoryState, style: WindowAppearance.Style) bool {
        const index = @backingInt(style);
        return index == 0 or self.scenario[36] & (@as(u8, 1) << @as(u3, @intCast(index - 1))) != 0;
    }

    pub fn hasSoundTheme(self: StoryState, theme: SoundTheme) bool {
        const index = @backingInt(theme);
        return index == 0 or self.scenario[36] & (@as(u8, 1) << @as(u3, @intCast(@as(u8, index) + 3))) != 0;
    }

    pub fn jsonStringify(self: StoryState, writer: anytype) !void {
        try writer.beginObject();
        try writer.objectField("schema");
        try writer.write(self.schema);
        try writer.objectField("scenario");
        try writer.write(self.scenario);
        if (!std.mem.allEqual(u8, &self.recruit_flags, 0)) {
            try writer.objectField("recruit_flags");
            try writer.write(self.recruit_flags);
        }
        if (self.castle_tier != 0) {
            try writer.objectField("castle_tier");
            try writer.write(self.castle_tier);
        }
        if (self.world_mode != 0) {
            try writer.objectField("world_mode");
            try writer.write(self.world_mode);
        }
        if (self.soul_eater_spell_slots != 1) {
            try writer.objectField("soul_eater_spell_slots");
            try writer.write(self.soul_eater_spell_slots);
        }
        if (self.library_books != 0) {
            try writer.objectField("library_books");
            try writer.write(self.library_books);
        }
        if (!self.window_appearance.isDefault()) {
            try writer.objectField("window_appearance");
            try writer.write(self.window_appearance);
        }
        if (self.sound_theme != .standard) {
            try writer.objectField("sound_theme");
            try writer.write(self.sound_theme);
        }
        if (self.save_counter != 0) {
            try writer.objectField("save_counter");
            try writer.write(self.save_counter);
        }
        try writer.endObject();
    }

    pub fn advanceSaveCounter(self: *StoryState, elapsed: u32) void {
        self.save_counter +%= elapsed;
    }

    pub fn recruitCount(self: *const StoryState) u8 {
        var count: u8 = 0;
        for (self.recruit_flags) |b| if ((b & 1) != 0 and (b & 2) == 0) {
            count += 1;
        };
        return count;
    }

    pub fn markCharacterLoaded(self: *StoryState, id: u8) void {
        if (id >= self.recruit_flags.len) return;
        self.recruit_flags[id] |= 1;
        self.refreshCastleTier();
    }

    fn refreshCastleTier(self: *StoryState) void {
        var total: u8 = 0;
        for (self.recruit_flags) |flags| if (flags & 3 != 0) {
            total += 1;
        };
        switch (self.castle_tier) {
            1 => if (total >= 25 and self.scenario[15] & 2 != 0) {
                self.castle_tier = 2;
            },
            2 => if (total >= 45) {
                self.castle_tier = 3;
            },
            3 => if (total >= 90) {
                self.castle_tier = 4;
            },
            else => {},
        }
    }

    pub fn toggleRecruit(self: *StoryState, slot: u8, toggle_only: bool) void {
        if (slot >= self.recruit_flags.len) return;
        if (toggle_only) {
            self.recruit_flags[slot] ^= 1;
        } else {
            if ((self.recruit_flags[slot] & 2) != 0) self.recruit_flags[slot] = 0;
            self.recruit_flags[slot] |= 1;
            self.refreshCastleTier();
        }
    }

    pub fn init(contents: []const Content) !StoryState {
        var result: StoryState = .{};
        for (contents) |content| {
            try content.validate();
            for (content.story_values) |entry| {
                const current = result.scenario[entry.byte_index];
                if (current != 0 and current != entry.initial) return error.ConflictingStoryInitialValue;
                result.scenario[entry.byte_index] = entry.initial;
            }
        }
        return result;
    }
    pub fn matches(self: *const StoryState, conditions: []const Condition) bool {
        for (conditions) |entry| {
            const index = parseScenarioId(entry.flag.id) orelse return false;
            if (index >= self.scenario.len or entry.flag.mask == 0) return false;
            const present = self.scenario[index] & entry.flag.mask != 0;
            if (present != (entry.kind == .story_mask_set)) return false;
        }
        return true;
    }
    pub fn apply(self: *StoryState, value: Flag) !void {
        const index = parseScenarioId(value.id) orelse return error.UnknownStoryValue;
        if (index >= self.scenario.len or value.mask == 0) return error.UnknownStoryValue;
        self.scenario[index] |= value.mask;
    }
    pub fn clear(self: *StoryState, value: Flag) !void {
        const index = parseScenarioId(value.id) orelse return error.UnknownStoryValue;
        if (index >= self.scenario.len or value.mask == 0) return error.UnknownStoryValue;
        self.scenario[index] &= ~value.mask;
    }

    pub fn advanceSequence(self: *StoryState, flag: Flag, pattern: u8, input: u8) !void {
        const index = flag.scenarioIndex() orelse return error.UnknownStoryValue;
        const progress = self.scenario[index];
        if (progress == 255) return;
        const step_index: u3 = @intCast(@popCount(progress));
        const expected = (pattern >> step_index) & 1;
        // A valid partial sequence has a contiguous run of low bits set.
        const next_bit = progress + 1;
        self.scenario[index] = if (progress & next_bit == 0 and input == expected) progress | next_bit else 0;
    }
};

fn parseScenarioId(id: []const u8) ?u8 {
    if (id.len != 13 or !std.mem.startsWith(u8, id, "scenario_")) return null;
    return std.fmt.parseInt(u8, id[9..], 10) catch null;
}

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
    effects: [max_batch_effects]Command = @splat(.{ .kind = .label }),

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

fn semanticEqual(a: anytype, b: @TypeOf(a)) bool {
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
    schema: []const u8 = state_schema,
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
        if (!std.mem.eql(u8, self.schema, if (track_branches) branch_state_schema else state_schema)) return error.EventContentIdentityMismatch;
        if ((self.execution.path != null) != track_branches) return error.InvalidEventBranchHistory;
        try validateExecution(self.execution, program.commands);
        if (self.pending) |pending| {
            if ((pending.next.path != null) != track_branches) return error.InvalidEventBranchHistory;
            if (self.execution.path) |current| {
                const future = pending.next.path.?;
                if (future.count < current.count or future.count > future.edges.len) return error.InvalidEventBranchHistory;
                for (current.edges[0..current.count], future.edges[0..current.count]) |a, b| if (a.command != b.command or a.target != b.target) return error.InvalidEventBranchHistory;
            }
            if (pending.batch.id == 0 or pending.batch.id > self.effect_sequence or pending.batch.effect_count == 0 or pending.batch.effect_count > max_batch_effects or pending.story_write_count > 4) return error.InvalidEventBatch;
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
                    if (effect_index >= effects.len or !semanticEqual(effects[effect_index], expected)) return error.InvalidEventBatch;
                    effect_index += 1;
                    if (expected.kind == .story_or or expected.kind == .story_andnot) {
                        if (write_index >= pending.story_write_count or !semanticEqual(pending.story_writes[write_index].flag, expected.flag.?) or pending.story_writes[write_index].clear != (expected.kind == .story_andnot)) return error.InvalidEventBatch;
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
                    if (!semanticEqual(effect, expected) or !semanticEqual(pending.next.wait, expected.wait)) return error.InvalidEventBatch;
                }
            }
            const last = effects[effects.len - 1];
            if (endsEvent(last.kind) == pending.next.active) return error.InvalidEventBatch;
            if (!pending.next.active) {
                if (!self.execution.active or @as(usize, last.origin) + 1 != pending.next.pc) return error.InvalidEventBatch;
                var expected = program.commands[last.origin];
                expected.origin = last.origin;
                if (!semanticEqual(last, expected)) return error.InvalidEventBatch;
            }
            for (pending.story_writes[0..pending.story_write_count]) |write| try content.validateFlag(write.flag);
            if (program.commands[program.commands.len - 1].kind == .room_transition or program.commands[program.commands.len - 1].kind == .world_transition) {
                var write_index: usize = 0;
                for (effects) |effect| {
                    if (effect.origin >= program.commands.len) return error.InvalidEventBatch;
                    var original = program.commands[effect.origin];
                    original.origin = effect.origin;
                    if (!semanticEqual(effect, original)) return error.InvalidEventBatch;
                    if (effect.kind == .story_or or effect.kind == .story_andnot) {
                        if (write_index >= pending.story_write_count or
                            !semanticEqual(pending.story_writes[write_index].flag, effect.flag.?) or
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
            !semanticEqual(commands[execution.pc - 1].wait, @as(?Wait, pending)))) return error.InvalidEventWait;
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
    return .{ .schema = if (track_branches) branch_state_schema else state_schema, .execution = .{ .path = if (track_branches) .{} else null }, .content_id = content.id, .content_sha256 = content.content_sha256, .program_id = program.id };
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

fn isPartyMutation(kind: @FieldType(Command, "kind")) bool {
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

fn endsEvent(kind: @FieldType(Command, "kind")) bool {
    return kind == .end_stream or kind == .room_transition or kind == .world_transition;
}

fn isBranch(kind: @FieldType(Command, "kind")) bool {
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
        if (operations == max_commands_per_step) return error.EventCycleBound;
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
                if (batch.effect_count == max_batch_effects) return error.EventBatchOverflow;
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

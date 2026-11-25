//! Event IR data model, schema version gates, and modular re-exports for story/validation/VM.
const std = @import("std");
pub const camera_push = @import("field_camera_push.zig");
pub const schema_versions = @import("event_runtime/schema.zig");
const story_mod = @import("event_runtime/story.zig");
const validate_mod = @import("event_runtime/validate.zig");
const vm = @import("event_runtime/vm.zig");

pub const schema = schema_versions.schema;
pub const campaign_schema = schema_versions.campaign_schema;
pub const scene_schema = schema_versions.scene_schema;
pub const motion_schema = schema_versions.motion_schema;
pub const hop_schema = schema_versions.hop_schema;
pub const party_track_schema = schema_versions.party_track_schema;
pub const party_scene_schema = schema_versions.party_scene_schema;
pub const position_schema = schema_versions.position_schema;
pub const fixed_box_schema = schema_versions.fixed_box_schema;
pub const character_schema = schema_versions.character_schema;
pub const music_schema = schema_versions.music_schema;
pub const queued_music_schema = schema_versions.queued_music_schema;
pub const entry_music_schema = schema_versions.entry_music_schema;
pub const field_effect_schema = schema_versions.field_effect_schema;
pub const party_select_schema = schema_versions.party_select_schema;
pub const scene_actor_schema = schema_versions.scene_actor_schema;
pub const fade_in_schema = schema_versions.fade_in_schema;
pub const prop_schema = schema_versions.prop_schema;
pub const mansion_music_schema = schema_versions.mansion_music_schema;
pub const party_experience_schema = schema_versions.party_experience_schema;
pub const wheel_music_schema = schema_versions.wheel_music_schema;
pub const wheel_motion_schema = schema_versions.wheel_motion_schema;
pub const item_overload_schema = schema_versions.item_overload_schema;
pub const hero_visibility_schema = schema_versions.hero_visibility_schema;
pub const branch_history_schema = schema_versions.branch_history_schema;
pub const world_entry_schema = schema_versions.world_entry_schema;
pub const actor_owners_schema = schema_versions.actor_owners_schema;
pub const camera_push_schema = schema_versions.camera_push_schema;
pub const scenery_mutation_schema = schema_versions.scenery_mutation_schema;
pub const state_schema = schema_versions.state_schema;
pub const branch_state_schema = schema_versions.branch_state_schema;

pub const FieldEffect = story_mod.FieldEffect;
pub const FieldMusic = story_mod.FieldMusic;
pub const FieldService = story_mod.FieldService;
pub const SoundTheme = story_mod.SoundTheme;
pub const WindowAppearance = story_mod.WindowAppearance;
pub const Flag = story_mod.Flag;
pub const StoryWrite = story_mod.StoryWrite;
pub const Condition = story_mod.Condition;
pub const StoryValue = story_mod.StoryValue;
pub const StoryState = story_mod.StoryState;

pub const party_actor_ids = [_][]const u8{ "party_follower_0", "party_follower_1", "party_follower_2", "party_follower_3", "party_follower_4" };

pub fn partyActorIndex(id: []const u8) ?u3 {
    for (party_actor_ids, 0..) |candidate, index| if (std.mem.eql(u8, id, candidate)) return @intCast(index);
    return null;
}

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

    pub fn toPadMask(self: Direction) u16 {
        return switch (self) {
            .up => 0x1000,
            .right => 0x2000,
            .down => 0x4000,
            .left => 0x8000,
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

pub const FieldEffectOperation = struct {
    origin: u16,
    x: i32,
    y: i32,
    effect: FieldEffect,
};

pub const SceneryOperation = union(enum) {
    stage_instance: u16,
    restore_instance: u16,
    append_template: u16,
};

pub const RoomTransition = struct {
    origin: u16,
    destination: []const u8,
    x: i32,
    y: i32,
    facing: ?Direction,
    source_arrival: bool,
    world_entry: union(enum) { reconcile, point: u8, named: []const u8 },
};

pub const WorldTransition = union(enum) {
    pub const Cell = struct { x: u8, y: u8 };

    destination: struct { room: []const u8, cell: Cell },
    retained_region: Cell,
    return_to_entry,
};

pub const ActorPlacement = struct {
    actor: []const u8,
    x: ?i32,
    y: ?i32,
    if_constructed: bool,
};

pub const ActorAxisMove = struct {
    actor: []const u8,
    axis: enum { x, y },
    cell: u8,
    origin: u16,
};

pub const ActorFacing = struct {
    pub const Variant = enum(u2) {
        down,
        up,
        left,
        right,

        pub fn direction(self: Variant) Direction {
            return switch (self) {
                .down => .down,
                .up => .up,
                .left => .left,
                .right => .right,
            };
        }
    };
    actor: []const u8,
    variant: Variant,
    if_constructed: bool,
};

pub const ActorMotionRestore = struct {
    actor: []const u8,
    speed: u8,
    if_constructed: bool,
};

pub const Command = struct {
    pub const Category = enum {
        control_flow,
        wait,
        dialogue,
        camera_visual,
        actor_track,
        party_inventory,
        transition,
        story_flag,
        service_minigame,
        source_record,
    };

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

    pub fn fieldEffectOperation(self: Command) ?FieldEffectOperation {
        if (self.kind != .field_effect or self.wait != null or self.requires != null) return null;
        const x = self.x orelse return null;
        const y = self.y orelse return null;
        if (x < 0 or x > 2040 or @mod(x, 8) != 0 or y < 0 or y > 2040 or @mod(y, 8) != 0) return null;
        return .{ .origin = self.origin, .x = x, .y = y, .effect = self.effect orelse return null };
    }

    pub fn sceneryOperation(self: Command) ?SceneryOperation {
        const object = self.scenery_object orelse return null;
        return switch (self.kind) {
            .scenery_stage => .{ .stage_instance = object },
            .scenery_restore => .{ .restore_instance = object },
            .scenery_append => .{ .append_template = object },
            else => null,
        };
    }

    pub fn roomTransition(self: Command) ?RoomTransition {
        if (self.kind != .room_transition or self.return_to_entry or self.retain_world_region) return null;
        if (self.world_entry != null and self.world_point != null) return null;
        const x = self.x orelse return null;
        const y = self.y orelse return null;
        if (x < 0 or x > 2040 or @mod(x, 8) != 0 or y < 0 or y > 2040 or @mod(y, 8) != 0) return null;
        return .{
            .origin = self.origin,
            .destination = self.destination orelse return null,
            .x = x,
            .y = y,
            .facing = self.arrival_facing,
            .source_arrival = self.source_arrival,
            .world_entry = if (self.world_entry) |entry| .{ .named = entry } else if (self.world_point) |point| .{ .point = point } else .reconcile,
        };
    }

    pub fn worldTransition(self: Command) ?WorldTransition {
        if (self.kind != .world_transition or self.arrival_facing != null or self.source_arrival or self.world_entry != null or self.world_point != null) return null;
        if (self.return_to_entry) {
            if (self.destination != null or self.retain_world_region or self.x != null or self.y != null) return null;
            return .return_to_entry;
        }
        const cell: WorldTransition.Cell = .{
            .x = std.math.cast(u8, self.x orelse return null) orelse return null,
            .y = std.math.cast(u8, self.y orelse return null) orelse return null,
        };
        if (self.retain_world_region) {
            if (self.destination != null) return null;
            return .{ .retained_region = cell };
        }
        return .{ .destination = .{ .room = self.destination orelse return null, .cell = cell } };
    }

    pub fn actorPlacement(self: Command) ?ActorPlacement {
        if (self.kind != .place_actor or (self.x == null and self.y == null) or self.wait != null or self.requires != null) return null;
        for ([_]?i32{ self.x, self.y }) |coordinate| if (coordinate) |value| {
            if (value < 0 or value > 2040 or @mod(value, 8) != 0) return null;
        };
        return .{ .actor = self.actor orelse return null, .x = self.x, .y = self.y, .if_constructed = self.if_actor_constructed == true };
    }

    pub fn actorAxisMove(self: Command) ?ActorAxisMove {
        if (self.kind != .actor_x and self.kind != .actor_y) return null;
        return .{
            .actor = self.actor orelse return null,
            .axis = if (self.kind == .actor_x) .x else .y,
            .cell = self.value orelse return null,
            .origin = self.origin,
        };
    }

    pub fn actorFacing(self: Command) ?ActorFacing {
        const variant = self.transition orelse return null;
        return switch (self.kind) {
            .actor_transition => .{
                .actor = self.actor orelse return null,
                .variant = @fromBackingInt(@intCast(variant)),
                .if_constructed = self.if_actor_constructed == true,
            },
            .source_hero_transition => .{
                .actor = "hero",
                .variant = ([_]ActorFacing.Variant{ .up, .right, .down, .left })[variant],
                .if_constructed = false,
            },
            else => null,
        };
    }

    pub fn actorMotionRestore(self: Command) ?ActorMotionRestore {
        if (self.kind != .actor_motion) return null;
        return .{ .actor = self.actor orelse return null, .speed = self.value orelse return null, .if_constructed = self.if_actor_constructed == true };
    }

    pub fn category(self: Command) Category {
        return switch (self.kind) {
            .choice, .jump, .branch_choice, .label, .dialogue_cleanup, .area_action, .wait_boxes, .continue_tick, .yield_tick, .end_stream, .branch_wheel, .branch_castle_tier, .branch_party => .control_flow,
            .wait_for_accept, .wait_tracks, .wait_field_effect, .wait_text_queue_empty, .wait_text_queue_drain_and_release, .wait_event_flags_low2 => .wait,
            .open_box, .open_fixed_box, .speaker, .text, .close_box, .start_or_wait_dialogue, .queue_glyphs_a, .queue_glyphs_b => .dialogue,
            .camera_push, .set_camera, .set_hero_display, .cue, .play_sound, .field_music, .field_effect, .pan, .fade_out, .fade_in, .show_prop, .tile_variant, .scenery_stage, .scenery_restore, .scenery_append => .camera_visual,
            .align_hero, .place_hero, .actor_transition, .queue_track, .queue_draw_record, .delay, .next_variant, .previous_variant, .wait_variant, .set_variant, .actor_motion, .actor_x, .actor_y, .place_actor, .release_actor, .create_double, .spawn_actor, .free_double, .follow_character, .hide_hero => .actor_track,
            .party_join, .party_load, .advance_character, .party_gain_experience, .party_lose_experience, .party_leave, .party_restore, .party_dismiss, .rune_grant, .inventory_edit, .shared_inventory_edit, .warehouse_deposit, .chest_grant, .item_overload, .money_edit, .party_select => .party_inventory,
            .room_transition, .battle, .world_transition, .world_mode, .auto_route, .special_checkpoint => .transition,
            .story_or, .story_andnot, .room_flag_clear, .soul_eater_advance, .recruit_toggle, .recruit_mark_loaded, .sequence_input => .story_flag,
            .inn_stay, .service, .fixed_dice, .wheel_spin, .wheel_restore, .wheel_turn, .wheel_align => .service_minigame,
            .request_area_party_prefix, .descriptor_flags, .descriptor_display, .spatial_object_probe, .source_move_batch, .native_slot_prefix, .source_release_descriptor, .source_party_add, .source_spawn_text, .source_close_keep_image, .source_hero_transition, .source_hero_alignment, .source_area_command, .source_timer => .source_record,
        };
    }

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
    pub fn knownActor(self: Content, id: []const u8) bool {
        if (self.hasPartyScene() and partyActorIndex(id) != null) return true;
        return std.mem.eql(u8, id, "hero") or std.mem.eql(u8, id, "audience_double") or self.actor(id) != null;
    }
    pub fn validateFlag(self: Content, value: Flag) !void {
        return validate_mod.validateFlag(self, value);
    }
    pub fn validateConditions(self: Content, conditions: []const Condition) !void {
        return validate_mod.validateConditions(self, conditions);
    }
    pub fn validateWait(pending: Wait) !void {
        return validate_mod.validateWait(pending);
    }
    pub fn validateCommand(self: Content, command: Command, count: usize, index: usize) !void {
        return validate_mod.validateCommand(self, command, count, index);
    }
    pub fn isCampaign(self: Content) bool {
        return schema_versions.atLeast(self.schema, 2);
    }
    pub fn isScene(self: Content) bool {
        return schema_versions.atLeast(self.schema, 3);
    }
    pub fn hasPartyTracks(self: Content) bool {
        return schema_versions.atLeast(self.schema, 6);
    }
    pub fn hasPartyScene(self: Content) bool {
        return schema_versions.atLeast(self.schema, 7);
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
        return schema_versions.atLeast(self.schema, 8);
    }
    pub fn hasFixedBoxes(self: Content) bool {
        return schema_versions.atLeast(self.schema, 9);
    }
    pub fn hasCharacters(self: Content) bool {
        return schema_versions.atLeast(self.schema, 10);
    }
    pub fn hasFieldMusic(self: Content) bool {
        return schema_versions.atLeast(self.schema, 11);
    }
    pub fn hasQueuedMusic(self: Content) bool {
        return schema_versions.atLeast(self.schema, 12);
    }
    pub fn hasFieldEffects(self: Content) bool {
        return schema_versions.atLeast(self.schema, 14);
    }
    pub fn hasSceneActors(self: Content) bool {
        return schema_versions.atLeast(self.schema, 16);
    }
    pub fn hasFadeIn(self: Content) bool {
        return schema_versions.atLeast(self.schema, 17);
    }
    pub fn hasProps(self: Content) bool {
        return schema_versions.atLeast(self.schema, 18);
    }
    pub fn hasMansionMusic(self: Content) bool {
        return schema_versions.atLeast(self.schema, 19);
    }
    pub fn hasPartyExperience(self: Content) bool {
        return schema_versions.atLeast(self.schema, 20);
    }
    pub fn hasWheelMusic(self: Content) bool {
        return schema_versions.atLeast(self.schema, 21);
    }
    pub fn hasWheelMotion(self: Content) bool {
        return schema_versions.atLeast(self.schema, 22);
    }
    pub fn hasItemOverload(self: Content) bool {
        return schema_versions.atLeast(self.schema, 23);
    }
    pub fn hasHeroVisibility(self: Content) bool {
        return schema_versions.atLeast(self.schema, 24);
    }
    pub fn hasBranchHistory(self: Content) bool {
        if (self.hasActorOwners()) return self.forward_branches orelse false;
        return schema_versions.atLeast(self.schema, 25);
    }
    pub fn tracksBranchHistory(self: Content, entry: Program) bool {
        if (self.hasBranchHistory()) return true;
        if (self.hasActorOwners()) for (entry.commands) |command| {
            if (command.kind == .branch_castle_tier or command.kind == .branch_party) return true;
        };
        return false;
    }
    pub fn hasWorldEntries(self: Content) bool {
        return schema_versions.atLeast(self.schema, 26);
    }
    pub fn hasActorOwners(self: Content) bool {
        return schema_versions.atLeast(self.schema, 27);
    }
    pub fn hasCameraPush(self: Content) bool {
        return schema_versions.atLeast(self.schema, 28);
    }
    pub fn hasSceneryMutations(self: Content) bool {
        return schema_versions.atLeast(self.schema, 29);
    }
    pub fn needsWorldContext(self: Content) bool {
        for (self.programs) |entry| for (entry.commands) |command| {
            if (command.return_to_entry or command.retain_world_region or command.world_point != null or command.world_entry != null) return true;
        };
        return false;
    }
    pub fn validate(self: Content) !void {
        return validate_mod.validateContent(self);
    }
};

pub const validDrawRecordBytes = validate_mod.validDrawRecordBytes;

pub fn validate(content: Content) !void {
    try content.validate();
}

pub const Input = vm.Input;
pub const Status = vm.Status;
pub const Execution = vm.Execution;
pub const BranchPath = vm.BranchPath;
pub const CommandHistory = vm.CommandHistory;
pub const EventBatch = vm.EventBatch;
pub const PendingBatch = vm.PendingBatch;
pub const Instance = vm.Instance;
pub const StepResult = vm.StepResult;
pub const isWheelControl = vm.isWheelControl;
pub const start = vm.start;
pub const step = vm.step;
pub const acknowledge = vm.acknowledge;
pub const actorVisible = vm.actorVisible;

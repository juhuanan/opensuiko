const characterFields = @import("character_fields.zig").capture;
const std = @import("std");
const content = @import("journey_content");
const journey = @import("journey");
const battle = @import("battle");
const field = @import("field");
const runtime = @import("event_runtime");
const ui_font = @import("ui_font");
const pause = @import("pause_menu");
const frame = @import("journey_frame");

const opening_rooms = [_][]const u8{ "test_route_start", "test_route_dungeon", "test_route_palace", "vb6_inn" };

fn fixtures(io: std.Io, directory: std.Io.Dir) !void {
    try directory.createDir(io, "battle", .default_dir);
    try directory.writeFile(io, .{ .sub_path = "room.json", .data = @embedFile("fixtures/journey_room.json") });
    try directory.writeFile(io, .{ .sub_path = "battle/trial.json", .data = @embedFile("fixtures/journey_battle.json") });
    try directory.writeFile(io, .{ .sub_path = "journey.json", .data = @embedFile("fixtures/journey.json") });
}

const compact_room_width = 304;
const compact_room_height = 224;

fn writeFieldBattle(io: std.Io, directory: std.Io.Dir, encounter: []const u8, variant: enum { silent, escape_branch, terminal_defeat, dialogue, motion, portrait, choice, scene, join, opening_battle, hero_track, compact_hero_track, scenery, facilities, modal, acceptance }) !void {
    const hash = "0000000000000000000000000000000000000000000000000000000000000000";
    const compact = variant == .compact_hero_track;
    const with_hero_track = variant == .hero_track or compact;
    const with_dialogue = variant != .silent and variant != .escape_branch and variant != .terminal_defeat and variant != .scenery and variant != .facilities and variant != .acceptance and !with_hero_track;
    const with_portrait = variant == .portrait;
    const with_motion = variant == .motion or with_portrait;
    const with_choice = variant == .choice or variant == .scene or variant == .join or variant == .opening_battle;
    const approach = [_]runtime.Command{
        .{ .kind = .align_hero, .x = 272, .y = 200 },
        .{ .kind = .pan, .dx = 1, .dy = -2, .updates = 12 },
        .{ .kind = .align_hero, .x = 264, .y = 200 },
    };
    const open = [_]runtime.Command{
        .{ .kind = .open_box, .box = 0, .requires = if (with_motion) .{ .kind = .alignment, .id = "alignment" } else .{ .kind = .box_closed, .id = "box_0" } },
    };
    const portrait_commands = [_]runtime.Command{
        .{ .kind = .start_or_wait_dialogue, .box = 0, .code = 42, .wait = .{ .kind = .speaker_prefix, .id = "box_0" } },
        .{ .kind = .start_or_wait_dialogue, .box = 0, .code = 8 },
        .{ .kind = .start_or_wait_dialogue, .box = 0, .code = 124 },
    };
    const body = [_]runtime.Command{
        .{ .kind = .text, .box = 0, .text = "test_warning", .wait = .{ .kind = .text, .id = "test_warning" } },
        .{ .kind = .wait_for_accept },
        .{ .kind = .close_box, .box = 0 },
    };
    const exit_pan = [_]runtime.Command{.{ .kind = .pan, .dx = -1, .dy = 1, .updates = 28 }};
    const battle_commands = [_]runtime.Command{
        .{ .kind = .story_or, .flag = .{ .id = "scenario_0001", .mask = 2 } },
        .{ .kind = .delay, .updates = 2, .wait = .{ .kind = .delay, .id = "delay" } },
        .{ .kind = .battle, .battle = encounter, .requires = if (with_dialogue) .{ .kind = .event_flags_low2, .id = "dialogue_flags" } else null },
        .{ .kind = .story_or, .flag = .{ .id = "scenario_0001", .mask = 1 } },
        .{ .kind = .end_stream },
    };
    var escape_branch = battle_commands[0 .. battle_commands.len - 1].* ++ [_]runtime.Command{
        .{ .kind = .jump, .target = 6 },
        .{ .kind = .story_or, .flag = .{ .id = "scenario_0001", .mask = 8 } },
        .{ .kind = .end_stream },
    };
    escape_branch[2].escape_target = escape_branch.len - 1;
    escape_branch[2].defeat_target = escape_branch.len - 2;
    var terminal_defeat = battle_commands;
    terminal_defeat[2].defeat_ends_run = true;
    const dialogue_battle = open ++ body ++ battle_commands;
    const acceptance_commands = [_]runtime.Command{
        .{ .kind = .inventory_edit, .character = "hero", .inventory = .{ .give = "antitoxin", .failure_target = 4 } },
        .{ .kind = .story_or, .flag = .{ .id = "scenario_0001", .mask = 2 } },
        .{ .kind = .battle, .battle = encounter },
        .{ .kind = .story_or, .flag = .{ .id = "scenario_0001", .mask = 0x20 } },
        .{ .kind = .end_stream },
    };
    const fixture_namespace = switch (variant) {
        .modal => runtime.wheel_music_schema,
        .acceptance => runtime.character_schema,
        else => runtime.schema,
    };
    const modal_commands = open ++ body ++ [_]runtime.Command{
        .{ .kind = .wait_boxes },
        .{ .kind = .party_select },
        .{ .kind = .field_music, .music = .area_b },
        .{ .kind = .story_or, .flag = .{ .id = "scenario_0001", .mask = 0x20 } },
        .{ .kind = .end_stream },
    };
    const motion_battle = approach ++ open ++ body ++ exit_pan ++ battle_commands;
    const portrait_battle = approach ++ open ++ portrait_commands ++ body ++ [_]runtime.Command{
        .{ .kind = .actor_transition, .actor = "hero", .transition = 1 },
    } ++ exit_pan ++ battle_commands;
    const portrait_start = approach.len + open.len;
    const choice_prelude = open ++ [_]runtime.Command{
        body[0],
        .{ .kind = .choice, .box = 0, .options = 2 },
        .{ .kind = .close_box, .box = 0 },
    };
    const battle_arm = [_]runtime.Command{.{ .kind = .wait_boxes }} ++ battle_commands[0 .. battle_commands.len - 1].*;
    const alternate = choice_prelude.len + 1 + battle_arm.len + 1;
    const choice_battle = choice_prelude ++ [_]runtime.Command{
        .{ .kind = .branch_choice, .target = alternate },
    } ++ battle_arm ++ [_]runtime.Command{
        .{ .kind = .jump, .target = alternate + 2 },
        .{ .kind = .align_hero, .x = 272, .y = 200 },
        .{ .kind = .wait_boxes },
        .{ .kind = .end_stream, .requires = .{ .kind = .alignment, .id = "alignment" } },
    };
    var optional_exit = choice_battle ++ [_]runtime.Command{
        .{ .kind = .room_transition, .destination = "vb6_village", .x = 400, .y = 264 },
    };
    optional_exit[alternate - 1].target = optional_exit.len - 1;
    var opening_battle = choice_battle;
    for (&opening_battle) |*command| if (command.kind == .battle) {
        command.escape_target = opening_battle.len - 1;
    };
    var scene = choice_battle;
    for (&scene) |*command| {
        if (command.kind == .battle) command.* = if (variant == .join)
            .{ .kind = .party_join, .character = "gremio" }
        else
            .{ .kind = .align_hero, .x = 264, .y = 208 };
    }
    scene[scene.len - 1] = if (variant == .scene)
        .{ .kind = .room_transition, .destination = "vb6_inn", .x = 248, .y = 208 }
    else
        .{ .kind = .room_transition, .destination = "vb6_village", .x = 400, .y = 264, .arrival_facing = .left };
    const scene_with_sound = scene[0 .. scene.len - 1].* ++ [_]runtime.Command{
        .{ .kind = .actor_transition, .actor = "test_guard", .transition = 3 },
        .{ .kind = .queue_track, .track = "guard_walk" },
        .{ .kind = .wait_tracks },
        .{ .kind = .play_sound, .cue = 0x501 },
        .{ .kind = .fade_out, .blend_mode = 2, .draw_slot = 10, .wait = .{ .kind = .fade, .id = "fade" } },
        .{ .kind = .area_action, .area = .{ .kind = .room_flag, .bits = 4 } },
        scene[scene.len - 1],
    };
    const joining_scene = scene[0 .. scene.len - 1].* ++ [_]runtime.Command{
        .{ .kind = .rune_grant, .character = "hero", .rune = "water" },
        .{ .kind = .inventory_edit, .character = "hero", .inventory = .{ .give = "antitoxin", .failure_target = scene.len + 2 } },
        .{ .kind = .story_or, .flag = .{ .id = "scenario_0001", .mask = 8 } },
        .{ .kind = .inventory_edit, .character = "hero", .inventory = .{ .take = "medicine", .give = "needle", .failure_target = scene.len + 3 } },
        .{ .kind = .inventory_edit, .character = "gremio", .inventory = .{ .give = "antitoxin", .failure_target = scene.len + 4 } },
        .{ .kind = .party_leave, .character = "gremio" },
        .{ .kind = .party_join, .character = "pahn" },
        .{ .kind = .shared_inventory_edit, .inventory = .{ .give = "fire_crystal", .failure_target = scene.len + 10 } },
        .{ .kind = .shared_inventory_edit, .inventory = .{ .take = "fire_crystal", .give = "water_crystal", .failure_target = scene.len + 10 } },
        .{ .kind = .shared_inventory_edit, .inventory = .{ .take = "fire_crystal", .give = "wind_crystal", .failure_target = scene.len + 10 } },
        .{ .kind = .story_or, .flag = .{ .id = "scenario_0001", .mask = 8 } },
        .{ .kind = .rune_grant, .character = "gremio", .rune = "wind" },
        scene[scene.len - 1],
    };
    var packet: content.BattleRooms.Packet = .{
        .schema = switch (variant) {
            .silent => content.BattleRooms.legacy_schema,
            .acceptance => content.BattleRooms.party_edit_schema,
            .dialogue => content.BattleRooms.dialogue_schema,
            .motion => content.BattleRooms.motion_schema,
            .portrait => content.BattleRooms.portrait_schema,
            .choice => content.BattleRooms.scene_schema,
            .scene, .join, .hero_track, .compact_hero_track => content.BattleRooms.schema,
            .opening_battle => content.BattleRooms.escape_branch_schema,
            .escape_branch => content.BattleRooms.defeat_branch_schema,
            .terminal_defeat => content.BattleRooms.schema,
            .scenery, .facilities, .modal => content.BattleRooms.current_schema,
        },
        .opening_battles = if (variant == .opening_battle) &.{.{ .room = "vb6_inn", .program = "test_guard" }} else &.{},
        .rooms = &.{.{
            .room = "vb6_inn",
            .dialogue = if (with_dialogue) .{
                .schema = if (with_portrait) "suikoden-field-dialogue/8" else "suikoden-field-dialogue/7",
                .content_sha256 = hash,
                .allow_substitution = variant == .scene,
                .anchors = &.{.{ .program = "test_guard", .command = if (with_motion) approach.len else 0, .box = 0, .point = .{ .x = 264, .y = 208 } }},
                .texts = &.{
                    .{ .id = "test_warning", .tokens = if (with_choice)
                        &.{ .{ .kind = .glyph, .text = "G" }, .{ .kind = .glyph, .text = "o" }, .{ .kind = .newline }, if (variant == .scene) .{ .kind = .player_name } else .{ .kind = .glyph, .text = "R" } }
                    else
                        &.{ .{ .kind = .glyph, .text = "G" }, .{ .kind = .glyph, .text = "o" } } },
                    .{ .id = "test_name", .tokens = &.{.{ .kind = .glyph, .text = "R" }} },
                },
                .prefixes = if (with_portrait) &.{
                    .{ .program = "test_guard", .command = portrait_start, .box = 0, .text = 1, .image = 0 },
                    .{ .program = "test_guard", .command = portrait_start + 1, .box = 0, .image = 1 },
                    .{ .program = "test_guard", .command = portrait_start + 2, .box = 0, .image = 2 },
                } else &.{},
                .images = if (with_portrait) &.{
                    .{ .id = "guard_portrait", .character = 42, .width = 64, .height = 64, .plane_sha256 = hash, .palette_sha256 = hash, .domain = .room, .atlas_rect = .{ .x = 80, .y = 16, .w = 64, .h = 64 } },
                    .{ .id = "hero_portrait", .character = 8, .width = 64, .height = 64, .plane_sha256 = hash, .palette_sha256 = hash, .atlas_rect = .{ .x = 144, .y = 16, .w = 64, .h = 64 } },
                    .{ .id = "absent_portrait", .character = 124, .width = 64, .height = 64, .plane_sha256 = hash, .palette_sha256 = hash, .atlas_rect = .{ .x = 208, .y = 16, .w = 64, .h = 64 } },
                } else &.{},
                .descriptor_changes = &.{},
                .configuration = @splat(.{ .normal_pace = 3, .pressed_pace = 1 }),
                .default_speed = .normal,
            } else null,
            .population = .{
                .schema = if (variant == .modal or variant == .acceptance) "suikoden-scene-population/3" else "suikoden-scene-population/2",
                .id = "test_room_population",
                .content_sha256 = hash,
                .source = .{ .file = "authored_fixture", .lba = 0, .size = 1, .sha256 = hash, .room = 0 },
                .coordinate_contract = .{
                    .source_units = "half_cell",
                    .pixel_units = "pixel",
                    .source_to_pixel = "pixel = source * 8",
                    .axes = "x_right_y_down",
                    .origin = "room_top_left",
                    .source_coordinate_max = 255,
                    .pixel_coordinate_max = 2040,
                    .room_half_width = if (compact) compact_room_width / 8 else 48,
                    .room_half_height = if (compact) compact_room_height / 8 else 32,
                },
                .duplicate_policy = "preserve_source_records",
                .story_values = &.{.{ .id = "scenario_0001", .storage = .scenario, .byte_index = 1 }},
                .programs = &.{.{ .id = "test_guard", .namespace = fixture_namespace, .content_id = "test_room_events" }},
                .entities = &.{.{
                    .id = "test_guard_owner",
                    .source_order = 0,
                    .record_role = .event,
                    .population_candidate = false,
                    .source_character_id = null,
                    .resource_id = null,
                    .resource_domain = null,
                    .position = .{ .source_x = 0, .source_y = 0, .x = 0, .y = 0, .placement = .not_applicable },
                    .classification = .{ .pointer_state = .null, .terms = &.{} },
                    .event_selection = .{ .pointer_state = .present, .terms = &.{
                        .{ .kind = .story_mask_clear, .flag = .{ .id = "scenario_0001", .mask = 2 } },
                        .{ .kind = .coordinate_range, .coordinate = .{ .axis = .x, .first = 32, .last = 32 } },
                        .{ .kind = .coordinate_range, .coordinate = .{ .axis = .y, .first = 26, .last = 26 } },
                    } },
                    .trigger = .ordinary,
                    .initialization_order = null,
                    .event = .{ .reference = "test_guard_stream", .status = .resolved, .program_id = "test_guard" },
                }},
            },
            .content = .{
                .schema = fixture_namespace,
                .id = "test_room_events",
                .content_sha256 = hash,
                .story_values = &.{.{ .id = "scenario_0001", .storage = .scenario, .byte_index = 1, .initial = if (variant == .scene) 0 else 4 }},
                .texts = if (with_dialogue) &.{
                    .{ .id = "test_warning", .tokens = if (with_choice)
                        &.{ .{ .kind = .glyph, .text = "G" }, .{ .kind = .glyph, .text = "o" }, .{ .kind = .newline }, if (variant == .scene) .{ .kind = .player_name } else .{ .kind = .glyph, .text = "R" } }
                    else
                        &.{ .{ .kind = .glyph, .text = "G" }, .{ .kind = .glyph, .text = "o" } } },
                    .{ .id = "test_name", .tokens = &.{.{ .kind = .glyph, .text = "R" }} },
                } else &.{},
                .tracks = if (with_hero_track) &.{
                    .{ .id = "cross_room", .actor = "hero", .commands = &.{
                        .{ .kind = .move, .direction = .right, .cells = 2 },
                        .{ .kind = .finish },
                    } },
                    .{ .id = "turn_corner", .actor = "hero", .commands = &.{
                        .{ .kind = .move, .direction = .down, .cells = 1 },
                        .{ .kind = .finish },
                    } },
                } else &.{},
                .programs = &.{.{
                    .id = "test_guard",
                    .entry = .ordinary,
                    .entity = 0,
                    .trigger = .none,
                    .conditions = &.{.{ .kind = .story_mask_set, .flag = .{ .id = "scenario_0001", .mask = 4 } }},
                    .commands = switch (variant) {
                        .silent => &battle_commands,
                        .acceptance => &acceptance_commands,
                        .escape_branch => &escape_branch,
                        .terminal_defeat => &terminal_defeat,
                        .dialogue => &dialogue_battle,
                        .modal => &modal_commands,
                        .motion => &motion_battle,
                        .portrait => &portrait_battle,
                        .choice => &optional_exit,
                        .opening_battle => &opening_battle,
                        .scene => &scene_with_sound,
                        .join => &joining_scene,
                        .scenery => &.{
                            .{ .kind = .continue_tick },
                            .{ .kind = .scenery_stage, .scenery_object = 0 },
                            .{ .kind = .scenery_append, .scenery_object = 1 },
                            .{ .kind = .scenery_stage, .scenery_object = 2 },
                            .{ .kind = .end_stream },
                        },
                        .facilities => &.{
                            .{ .kind = .service, .facility = .save_point },
                            .{ .kind = .end_stream },
                        },
                        .hero_track, .compact_hero_track => &.{
                            .{ .kind = .queue_track, .track = "cross_room" },
                            .{ .kind = .wait_tracks },
                            .{ .kind = .queue_track, .track = "turn_corner" },
                            .{ .kind = .wait_tracks },
                            .{ .kind = .story_or, .flag = .{ .id = "scenario_0001", .mask = 2 } },
                            .{ .kind = .end_stream },
                        },
                    },
                }},
            },
        }},
    };
    var room = packet.rooms[0];
    const secondary_exit = "test_secondary_exit";
    var programs = [_]runtime.Program{ room.content.programs[0], room.content.programs[0] };
    var join_programs: [3]runtime.Program = undefined;
    var references = [_]@TypeOf(room.population.programs[0]){ room.population.programs[0], room.population.programs[0] };
    var entities = [_]@TypeOf(room.population.entities[0]){ room.population.entities[0], room.population.entities[0] };
    var scenery_entities: [3]@TypeOf(entities[0]) = undefined;
    var terms = [_]@TypeOf(entities[1].event_selection.terms[0]){ entities[1].event_selection.terms[0], entities[1].event_selection.terms[1], entities[1].event_selection.terms[2] };
    const interaction_terms = [_]@TypeOf(terms[0]){ terms[0], .{ .kind = .interaction } };
    if (variant == .facilities) {
        room.content.schema = runtime.campaign_schema;
        room.population.schema = "suikoden-scene-population/4";
        programs[0].trigger = .interaction;
        programs[1] = .{ .id = "test_storage_counter", .entry = .ordinary, .entity = 1, .trigger = .interaction, .commands = &.{
            .{ .kind = .service, .facility = .storage },
            .{ .kind = .end_stream },
        } };
        for (&references, &entities, programs, [2]i32{ 264, 240 }, 0..) |*reference, *entity, program, x, i| {
            reference.namespace = room.content.schema;
            reference.id = program.id;
            entity.id = program.id;
            entity.source_order = @intCast(i);
            entity.trigger = .interaction;
            entity.position = .{ .source_x = @intCast(@divExact(x, 8)), .source_y = 26, .x = x, .y = 208, .placement = .placed };
            entity.classification = .{ .pointer_state = .present, .terms = &.{} };
            entity.event_selection.terms = &.{.{ .kind = .interaction }};
            entity.event = .{ .reference = program.id, .status = .resolved, .program_id = program.id };
        }
        room.content.programs = &programs;
        room.population.programs = &references;
        room.population.entities = &entities;
        packet.rooms = (&room)[0..1];
    }
    if (variant == .scenery) {
        const pose: field.Frame = .{ .rect = .{ .x = 0, .y = 0, .w = 8, .h = 8 }, .anchor_x = 4, .anchor_y = 8, .ticks = 1 };
        const visitor = "test_visitor";
        room.actors = &.{.{ .id = visitor, .entity = 2, .poses = @splat(pose) }};
        room.content.actors = &.{.{ .id = visitor }};
        room.content.schema = runtime.scenery_mutation_schema;
        room.content.forward_branches = true;
        room.population.schema = "suikoden-scene-population/4";
        programs[0].trigger = .interaction;
        programs[1] = .{ .id = "test_room_setup", .entry = .initialization, .entity = 1, .trigger = .none, .commands = &.{
            .{ .kind = .continue_tick },
            .{ .kind = .story_or, .flag = .{ .id = "scenario_0001", .mask = 8 } },
            .{ .kind = .place_actor, .actor = visitor, .x = 288, .y = 184, .if_actor_constructed = true },
            .{ .kind = .actor_motion, .actor = visitor, .value = 0, .if_actor_constructed = true },
            .{ .kind = .actor_transition, .actor = visitor, .transition = 3, .if_actor_constructed = true },
            .{ .kind = .scenery_append, .scenery_object = 1 },
            .{ .kind = .yield_tick },
            .{ .kind = .end_stream },
        } };
        references[0].namespace = room.content.schema;
        references[1] = references[0];
        references[1].id = programs[1].id;
        entities[0].trigger = .interaction;
        entities[0].position = .{ .source_x = 32, .source_y = 26, .x = 256, .y = 208, .placement = .placed };
        entities[0].classification = .{ .pointer_state = .present, .terms = &.{} };
        entities[0].event_selection.terms = &interaction_terms;
        entities[1].source_order = 1;
        entities[1].id = "test_room_setup_owner";
        entities[1].record_role = .initialization;
        entities[1].trigger = .initialization;
        entities[1].initialization_order = 0;
        entities[1].event_selection.terms = &.{};
        entities[1].event = .{ .reference = "test_room_setup_stream", .status = .resolved, .program_id = programs[1].id };
        room.content.programs = &programs;
        room.population.programs = &references;
        scenery_entities = entities ++ [_]@TypeOf(entities[0]){.{
            .id = "test_visitor_owner",
            .source_order = 2,
            .record_role = .character,
            .population_candidate = true,
            .source_character_id = 42,
            .resource_id = visitor,
            .resource_domain = .area_character_context,
            .position = .{ .source_x = 32, .source_y = 23, .x = 256, .y = 184, .placement = .placed },
            .classification = .{ .pointer_state = .present, .terms = &.{.{ .kind = .story_mask_set, .flag = .{ .id = "scenario_0001", .mask = 8 } }} },
            .event_selection = .{ .pointer_state = .null, .terms = &.{} },
            .trigger = .ordinary,
            .initialization_order = null,
            .event = .{ .reference = "test_visitor_stream", .status = .source_only, .program_id = null },
        }};
        room.population.entities = &scenery_entities;
        packet.rooms = (&room)[0..1];
    }
    if (variant == .opening_battle or variant == .escape_branch) {
        programs[0].entity = 1;
        if (variant == .opening_battle) {
            programs[0].trigger = .area_entry;
            entities[0].trigger = .area_entry;
            entities[0].event_selection.terms = &.{};
        }
        entities[1] = entities[0];
        entities[1].source_order = 1;
        entities[0].id = "test_source_only_owner";
        entities[0].event = .{ .reference = "test_source_only_stream", .status = .source_only, .program_id = null };
        room.content.programs = programs[0..1];
        room.population.entities = &entities;
        packet.rooms = (&room)[0..1];
    }
    if (variant == .scene) {
        room.actors = &.{.{ .id = "test_guard", .entity = 0, .poses = .{
            .{ .rect = .{ .x = 0, .y = 0, .w = 8, .h = 8 }, .anchor_x = 4, .anchor_y = 8, .ticks = 1 },
            .{ .rect = .{ .x = 8, .y = 0, .w = 8, .h = 8 }, .anchor_x = 4, .anchor_y = 8, .ticks = 1 },
            .{ .rect = .{ .x = 16, .y = 0, .w = 8, .h = 8 }, .anchor_x = 4, .anchor_y = 8, .ticks = 1 },
            .{ .rect = .{ .x = 24, .y = 0, .w = 8, .h = 8 }, .anchor_x = 4, .anchor_y = 8, .ticks = 1 },
        } }};
        room.content.actors = &.{.{ .id = "test_guard" }};
        room.content.tracks = &.{.{ .id = "guard_walk", .actor = "test_guard", .commands = &.{
            .{ .kind = .move, .direction = .right, .cells = 1 },
            .{ .kind = .move, .direction = .down, .cells = 1 },
            .{ .kind = .move, .direction = .right, .cells = 1 },
            .{ .kind = .finish },
        } }};
        programs[0].trigger = .interaction;
        programs[0].selection = &.{
            .{ .kind = .party_contains, .index = 8 },
            .{ .kind = .party_absent, .index = 1 },
        };
        entities[0].trigger = .interaction;
        entities[0].record_role = .character;
        entities[0].population_candidate = true;
        entities[0].source_character_id = 42;
        entities[0].resource_id = "test_guard";
        entities[0].resource_domain = .area_character_context;
        entities[0].position = .{ .source_x = 34, .source_y = 26, .x = 272, .y = 208, .placement = .placed };
        entities[0].classification = .{ .pointer_state = .present, .terms = &.{} };
        entities[0].event_selection.terms = &interaction_terms;
        programs[1] = .{ .id = "test_room_setup", .entry = .initialization, .entity = 1, .trigger = .none, .commands = &.{
            .{ .kind = .continue_tick },
            .{ .kind = .story_or, .flag = .{ .id = "scenario_0001", .mask = 4 } },
            .{ .kind = .story_andnot, .flag = .{ .id = "scenario_0001", .mask = 1 } },
            .{ .kind = .area_action, .area = .{ .kind = .room_flag, .bits = 2 } },
            .{ .kind = .yield_tick },
            .{ .kind = .story_or, .flag = .{ .id = "scenario_0001", .mask = 8 } },
            .{ .kind = .end_stream },
        } };
        references[1].id = programs[1].id;
        entities[1].id = "test_room_setup_owner";
        entities[1].source_order = 1;
        entities[1].record_role = .initialization;
        entities[1].trigger = .initialization;
        entities[1].initialization_order = 0;
        entities[1].event_selection.terms = &.{};
        entities[1].event.reference = "test_room_setup_stream";
        entities[1].event.program_id = programs[1].id;
        room.content.programs = &programs;
        room.population.programs = &references;
        room.population.entities = &entities;
        packet.rooms = (&room)[0..1];
    }
    if (variant == .join) {
        programs[0].selection = &.{
            .{ .kind = .hero_x_strict, .min = 31, .max = 33 },
            .{ .kind = .hero_y_inclusive, .min = 26, .max = 26 },
            .{ .kind = .pressed_mask, .mask = 0x4000 },
            .{ .kind = .room_mask_set, .mask = 2 },
            .{ .kind = .room_mask_clear, .mask = 4 },
        };
        entities[0].event_selection.terms = entities[0].event_selection.terms[0..1];
        programs[1].id = secondary_exit;
        programs[1].entity = 1;
        programs[1].commands = scene[scene.len - 1 ..];
        references[1].id = secondary_exit;
        entities[1].id = "test_secondary_exit_owner";
        entities[1].source_order = 1;
        entities[1].event.reference = "test_secondary_exit_stream";
        entities[1].event.program_id = secondary_exit;
        terms[1].coordinate.?.first = 33;
        terms[1].coordinate.?.last = 33;
        entities[1].event_selection.terms = &terms;
        join_programs = programs ++ [_]runtime.Program{.{
            .id = "test_unused_join",
            .entry = .ordinary,
            .entity = 2,
            .trigger = .none,
            .commands = &.{ .{ .kind = .party_join, .character = "cleo" }, .{ .kind = .end_stream } },
        }};
        room.content.programs = &join_programs;
        room.population.programs = &references;
        room.population.entities = &entities;
        packet.rooms = (&room)[0..1];
        packet.opening_route = .{
            .dungeon = opening_rooms[1],
            .palace = opening_rooms[2],
            .first_town = opening_rooms[3],
            .initial_party = &.{ "gremio", "pahn" },
        };
        packet.opening_world_exits = &.{ .{ .room = "vb6_inn", .program = secondary_exit }, .{ .room = "vb6_inn", .program = "test_guard" } };
    }
    const bytes = try std.json.Stringify.valueAlloc(std.testing.allocator, packet, .{});
    defer std.testing.allocator.free(bytes);
    try directory.writeFile(io, .{ .sub_path = content.BattleRooms.path, .data = bytes });
}

fn expectHeroTrackResume(compact: bool) !void {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try fixtures(io, temp.dir);
    if (compact) {
        const parsed = try field.load(allocator, @embedFile("fixtures/journey_room.json"));
        defer parsed.deinit();
        var package = parsed.value;
        const rooms = try allocator.dupe(field.Room, package.rooms);
        defer allocator.free(rooms);
        const start = &rooms[package.roomIndex(package.start_room).?];
        start.width = compact_room_width;
        start.height = compact_room_height;
        start.walkable = &(@as([compact_room_width * compact_room_height / 64]u8, @splat('1')));
        start.draws = &.{};
        start.exits = &.{};
        package.rooms = rooms;
        const package_json = try std.json.Stringify.valueAlloc(allocator, package, .{});
        defer allocator.free(package_json);
        try temp.dir.writeFile(io, .{ .sub_path = "room.json", .data = package_json });
    }
    try writeFieldBattle(io, temp.dir, "", if (compact) .compact_hero_track else .hero_track);
    var diagnostic: content.Diagnostic = .{};
    var loaded = try content.Bundle.load(allocator, io, temp.dir, &diagnostic);
    defer loaded.deinit();
    var members: [6]battle.Member = undefined;
    var boot_combat: battle.State = undefined;
    var boot: @import("journey_boot").Boot = .{
        .allocator = allocator,
        .path = @constCast(""),
        .save_path = null,
        .bundle = loaded,
        .party = null,
        .members = &members,
        .combat = &boot_combat,
        .state = undefined,
    };
    var state = try boot.newState();
    for (0..state.package.step_ticks) |_| {
        _ = try state.tickWithFieldEvents(.{ .field = .{ .direction = .right } }, .{});
    }
    const event = state.field_event orelse return error.MissingFieldEvent;
    _ = try state.tickWithFieldEvents(.{}, .{});
    try std.testing.expect(event.session.ordinary_actors == null);
    try std.testing.expect(event.session.ordinary_track.?.state.active);
    try std.testing.expectEqual(@as(i32, if (compact) 0 else 64), event.session.movement_camera.?.x);
    try std.testing.expectEqual(@as(i32, if (compact) 0 else 16), event.session.movement_camera.?.y);
    const bytes = try std.json.Stringify.valueAlloc(allocator, event.session.*, .{});
    defer allocator.free(bytes);
    const restored = try std.json.parseFromSlice(@TypeOf(event.session.*), allocator, bytes, .{});
    defer restored.deinit();
    try restored.value.validate(event.binding.*);
    var invalid = restored.value;
    invalid.ordinary_track.?.track = 255;
    try std.testing.expectError(error.InvalidFieldActorState, invalid.validate(event.binding.*));
    invalid = restored.value;
    invalid.movement_camera.?.x += 16;
    try std.testing.expectError(error.InvalidFieldActorState, invalid.validate(event.binding.*));
    event.session.* = restored.value;

    for (0..24) |_| {
        _ = try state.tickWithFieldEvents(.{}, .{});
        if (state.field_event == null) break;
    } else return error.FieldTrackDidNotFinish;
    try std.testing.expectEqual(@as(i32, 272), state.field_state.x);
    try std.testing.expectEqual(@as(i32, 216), state.field_state.y);
    try std.testing.expectEqual(@as(u8, 6), state.field_state.progress.story.scenario.?.scenario[1]);
}

test "package hero tracks advance and restore without room NPCs" {
    try expectHeroTrackResume(false);
}

test "package hero tracks advance and restore in rooms smaller than the viewport" {
    try expectHeroTrackResume(true);
}

test "room scenery interaction and constructor guards share room entry state" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try fixtures(io, temp.dir);
    const parsed = try field.load(allocator, @embedFile("fixtures/journey_room.json"));
    defer parsed.deinit();
    var package = parsed.value;
    package.schema = field.Package.scenery_draw_schema;
    const rooms = try allocator.dupe(field.Room, package.rooms);
    defer allocator.free(rooms);
    package.rooms = rooms;
    const room = &rooms[package.roomIndex(package.start_room).?];
    room.scenery_model = .{
        .schema = "suikoden-field-scenery/1",
        .columns = 48,
        .rows = 32,
        .initial_count = 1,
        .terrain = &(@as([48 * 32]u8, @splat('0'))),
        .objects = &.{
            .{ .x = 304, .y = 208, .width_cells = 1, .height_cells = 1, .layer = 0, .collides = true, .mask = "1" },
            .{ .x = 320, .y = 208, .width_cells = 1, .height_cells = 1, .layer = 0, .collides = true, .mask = "1" },
        },
    };
    const base_draw = room.draws[0];
    var draws = [_]field.Draw{ base_draw, base_draw };
    draws[0].scenery_object = 0;
    draws[1].scenery_object = 1;
    room.draws = &draws;
    const encoded = try std.json.Stringify.valueAlloc(allocator, package, .{});
    defer allocator.free(encoded);
    try temp.dir.writeFile(io, .{ .sub_path = "room.json", .data = encoded });
    try writeFieldBattle(io, temp.dir, "", .scenery);

    var diagnostics: content.Diagnostic = .{};
    var loaded = try content.Bundle.load(allocator, io, temp.dir, &diagnostics);
    defer loaded.deinit();
    var members: [6]battle.Member = undefined;
    var boot_combat: battle.State = undefined;
    var boot: @import("journey_boot").Boot = .{
        .allocator = allocator,
        .path = @constCast(""),
        .save_path = null,
        .bundle = loaded,
        .party = null,
        .members = &members,
        .combat = &boot_combat,
        .state = undefined,
    };
    var state = try boot.newState();
    try state.initializeRoomVisit();
    const world = &state.field_state;
    const battle_rooms = state.room_battles.?;
    const binding = battle_rooms.bindingFor(room.id).?;
    const first = battle_rooms.settledForVisit(binding, world.room_entries).?;
    try std.testing.expectEqual(.absent, first.state.slots[0].?.phase);
    try std.testing.expectEqual(@as(u8, 12), world.progress.story.scenario.?.scenario[1]);
    try std.testing.expectEqual(@as(u16, 2), world.room_scenery.?.count);
    try std.testing.expect(!room.canStandWithScenery(&world.room_scenery.?, 304, 208));
    try std.testing.expect(!room.canStandWithScenery(&world.room_scenery.?, 320, 208));

    _ = try state.tickWithFieldEvents(.{ .field = .{ .direction = .right, .action = true } }, .{});
    for (0..4) |_| _ = try state.tickWithFieldEvents(.{}, .{});
    try std.testing.expect(state.field_event == null);
    try std.testing.expectEqual(@as(u16, 3), world.room_scenery.?.count);
    try std.testing.expectEqual(@as(usize, 0), room.sceneryCopies(draws[0], &world.room_scenery.?));
    try std.testing.expectEqual(@as(usize, 1), room.sceneryCopies(draws[1], &world.room_scenery.?));
    try std.testing.expect(room.canStandWithScenery(&world.room_scenery.?, 304, 208));
    try std.testing.expect(!room.canStandWithScenery(&world.room_scenery.?, 320, 208));
    for (0..8 * @as(usize, package.step_ticks)) |_| {
        _ = try state.tickWithFieldEvents(.{ .field = .{ .direction = .right } }, .{});
    }
    try std.testing.expectEqual(@as(i32, 304), world.x);
    try std.testing.expectEqual(@as(u16, 0), world.remaining);

    const edited = world.room_scenery.?;
    try journey.save(io, allocator, temp.dir, state);
    world.enterRoom(world.room, .{ .x = package.start_x, .y = package.start_y });
    try std.testing.expect(world.room_scenery == null);
    try journey.restore(io, allocator, temp.dir, &state);
    try std.testing.expectEqual(@as(i32, 304), world.x);
    try std.testing.expectEqualDeep(edited, world.room_scenery.?);
    var old = try journey.Snapshot.capture(state);
    old.room_scenery.?.model_sha256[0] ^= 1;
    try std.testing.expectError(error.FieldSceneryContentMismatch, old.validate(state));
    old.schema = "suikoden-journey-save/41";
    try std.testing.expectError(error.InvalidSave, old.validate(state));
    old.room_scenery = null;
    old.x = package.start_x;
    try old.validate(state);

    world.enterRoom(world.room, .{ .x = package.start_x, .y = package.start_y });
    try state.initializeRoomVisit();
    const next = battle_rooms.settledForVisit(binding, world.room_entries).?;
    const visitor = next.state.slots[0].?.avatar.?;
    try std.testing.expectEqual(@as(i32, 288), visitor.motion.x);
    try std.testing.expectEqual(@as(i32, 184), visitor.motion.y);
    try std.testing.expectEqual(@as(u2, 3), visitor.variant);
}

test "field facilities open a save point and storage from interaction" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try fixtures(io, temp.dir);
    try writeFieldBattle(io, temp.dir, "", .facilities);
    var diagnostic: content.Diagnostic = .{};
    var loaded = try content.Bundle.load(allocator, io, temp.dir, &diagnostic);
    defer loaded.deinit();
    var members: [6]battle.Member = undefined;
    var boot_combat: battle.State = undefined;
    var boot: @import("journey_boot").Boot = .{
        .allocator = allocator,
        .path = @constCast(""),
        .save_path = null,
        .bundle = loaded,
        .party = null,
        .members = &members,
        .combat = &boot_combat,
        .state = undefined,
    };
    var state = try boot.newState();
    const action: pause.Input = .{ .field = .{ .action = true } };
    const cancel: pause.Input = .{ .field = .{ .cancel = true } };
    for (0..2) |attempt| {
        var effect = try state.tickWithFieldEvents(.{ .field = .{ .direction = .right, .action = true } }, .{});
        for (0..8) |_| {
            if (state.menu.phase != .closed) break;
            effect = try state.tickWithFieldEvents(.{}, .{});
        }
        try std.testing.expectEqual(.inspect_saves, effect);
        try std.testing.expectEqual(.save_slots, state.menu.phase);
        try std.testing.expectEqual(.none, try state.tickWithFieldEvents(action, .{}));
        try std.testing.expectEqual(.name_save, state.menu.phase);
        _ = try state.tickWithFieldEvents(action, .{});
        try std.testing.expectEqual(.confirm_save, state.menu.phase);
        try std.testing.expect(!state.menu.yes);
        if (attempt == 0) {
            try std.testing.expectEqual(.none, try state.tickWithFieldEvents(action, .{}));
            try std.testing.expectEqual(.closed, state.menu.phase);
            try std.testing.expectEqual(.empty, journey.summaries(io, allocator, temp.dir, state)[0].status);
        } else {
            _ = try state.tickWithFieldEvents(.{ .right = true }, .{});
            try std.testing.expectEqual(.save, try state.tickWithFieldEvents(action, .{}));
        }
    }
    const checkpoint = try journey.Snapshot.capture(state);
    try journey.saveSlot(io, allocator, temp.dir, state, state.menu.save_slot, state.menu.save_label);
    _ = try state.tickWithFieldEvents(action, .{});
    try std.testing.expectEqual(.closed, state.menu.phase);
    state.combat.progress.money = 0;
    state.field_state.progress.story.scenario.?.scenario[1] = 0;
    _ = try journey.restoreSlotWithSource(io, allocator, temp.dir, &state, 0);
    try std.testing.expectEqual(checkpoint.money, state.combat.progress.money);
    try std.testing.expectEqualDeep(checkpoint.story, state.field_state.progress.story);
    for (checkpoint.party[0..checkpoint.party_count], state.combat.progress.party) |saved, member| try std.testing.expectEqualDeep(saved, member.record());
    try std.testing.expectEqualStrings(checkpoint.room, state.package.rooms[state.field_state.room].id);

    const inventory = &state.field_state.progress.party[0].inventory;
    const item_slot = inventory.count();
    try std.testing.expect(try inventory.receive(.medicine));
    _ = try state.tickWithFieldEvents(.{ .field = .{ .direction = .left, .action = true } }, .{});
    for (0..8) |_| {
        if (state.menu.phase != .closed) break;
        _ = try state.tickWithFieldEvents(.{}, .{});
    }
    try std.testing.expectEqual(.storage, state.menu.phase);
    _ = try state.tickWithFieldEvents(action, .{});
    for (0..item_slot) |_| _ = try state.tickWithFieldEvents(.{ .field = .{ .menu_direction = .down } }, .{});
    _ = try state.tickWithFieldEvents(action, .{});
    _ = try state.tickWithFieldEvents(.{ .right = true }, .{});
    _ = try state.tickWithFieldEvents(action, .{});
    try std.testing.expectEqual(.storage_notice, state.menu.phase);
    try std.testing.expectEqual(item_slot, inventory.count());
    try std.testing.expectEqual(@as(usize, 1), state.field_state.progress.storage.count());
    for (0..2) |_| _ = try state.tickWithFieldEvents(cancel, .{});
    try std.testing.expectEqual(.storage, state.menu.phase);
    _ = try state.tickWithFieldEvents(.{ .field = .{ .menu_direction = .down } }, .{});
    _ = try state.tickWithFieldEvents(action, .{});
    _ = try state.tickWithFieldEvents(action, .{});
    _ = try state.tickWithFieldEvents(.{ .right = true }, .{});
    _ = try state.tickWithFieldEvents(action, .{});
    try std.testing.expectEqual(.storage_notice, state.menu.phase);
    try std.testing.expectEqual(item_slot + 1, inventory.count());
    try std.testing.expectEqual(@as(usize, 0), state.field_state.progress.storage.count());
    for (0..3) |_| _ = try state.tickWithFieldEvents(cancel, .{});
    try std.testing.expectEqual(.closed, state.menu.phase);
}

test "package field battle admits a room event after a real step and resumes it after escape" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const io = std.testing.io;
    try fixtures(io, temp.dir);
    var diagnostic: content.Diagnostic = .{};
    try writeFieldBattle(io, temp.dir, "missing_encounter", .silent);
    try std.testing.expectError(error.UnknownEncounter, content.Bundle.load(std.testing.allocator, io, temp.dir, &diagnostic));
    try std.testing.expectEqualStrings(content.BattleRooms.path, diagnostic.path);
    try writeFieldBattle(io, temp.dir, "area_a_1", .escape_branch);
    var loaded = try content.Bundle.load(std.testing.allocator, io, temp.dir, &diagnostic);
    defer loaded.deinit();
    var members: [6]battle.Member = undefined;
    var boot_combat: battle.State = undefined;
    var boot: @import("journey_boot").Boot = .{
        .allocator = std.testing.allocator,
        .path = @constCast(""),
        .save_path = null,
        .bundle = loaded,
        .party = null,
        .members = &members,
        .combat = &boot_combat,
        .state = undefined,
    };
    var state = try boot.newState();
    const world = &state.field_state;
    const rooms = try std.testing.allocator.dupe(field.Room, state.package.rooms);
    defer std.testing.allocator.free(rooms);
    rooms[world.room].exits = &.{.{
        .x = 256,
        .y = 208,
        .w = 8,
        .h = 8,
        .room = "vb6_village",
        .spawn_x = 400,
        .spawn_y = 264,
        .direction = .right,
    }};
    state.package.rooms = rooms;
    const balance = world.progress.money;
    const fallback = [_]journey.Trigger{.{ .id = "overlapping_fallback", .room = "vb6_inn", .x = 256, .y = 208, .w = 8, .h = 8, .encounter = "area_a_2", .flag = .forest_battle_one_won }};
    state.data.encounters = &fallback;
    for (0..state.package.step_ticks) |step| {
        _ = try state.tickWithFieldEvents(.{ .field = .{ .direction = .right }, .menu = step + 1 == state.package.step_ticks }, .{});
        try std.testing.expectEqual(.field, state.mode);
        try std.testing.expectEqual(step + 1 == state.package.step_ticks, state.field_event != null);
    }
    try std.testing.expectEqual(@as(i32, 256), world.x);
    try std.testing.expect(!world.walking);
    try std.testing.expectEqual(.closed, state.menu.phase);
    try std.testing.expect(!state.menu.pending);
    try std.testing.expectEqual(@as(u8, 4), world.progress.story.scenario.?.scenario[1]);
    const before_scene = world.scene_ticks;
    _ = try state.tickWithFieldEvents(.{}, .{});
    try std.testing.expectEqual(before_scene +% 1, world.scene_ticks);
    for (0..8) |_| {
        _ = try state.tickWithFieldEvents(.{ .field = .{ .direction = .right } }, .{});
        if (state.mode == .battle) break;
    }
    try std.testing.expectEqual(.battle, state.mode);
    try std.testing.expectEqualStrings("area_a_1", state.combat.content.encounters[state.combat.encounter].id);
    try std.testing.expectEqual(@as(i32, 256), world.x);
    try std.testing.expectEqual(@as(u8, 6), world.progress.story.scenario.?.scenario[1]);
    try std.testing.expect(state.combat.canLetGo());
    const before_combat = world.scene_ticks;
    _ = try state.tickWithFieldEvents(.{}, .{ .down = true });
    _ = try state.tickWithFieldEvents(.{}, .{ .confirm = true });
    try std.testing.expectEqual(.escaped, state.combat.phase);
    _ = try state.tickWithFieldEvents(.{}, .{ .confirm = true });
    try std.testing.expectEqual(.field, state.mode);
    try std.testing.expectEqual(before_combat, world.scene_ticks);
    try std.testing.expectEqual(@as(u8, 6), world.progress.story.scenario.?.scenario[1]);
    _ = try state.tickWithFieldEvents(.{}, .{});
    try std.testing.expectEqual(before_combat +% 1, world.scene_ticks);
    try std.testing.expectEqual(@as(u8, 6), world.progress.story.scenario.?.scenario[1]);
    const snapshot = try journey.Snapshot.capture(state);
    try snapshot.apply(&state);
    _ = try state.tickWithFieldEvents(.{}, .{});
    try std.testing.expect(state.field_event == null);
    try std.testing.expectEqual(balance, world.progress.money);
    try std.testing.expectEqual(@as(u8, 6), world.progress.story.scenario.?.scenario[1]);
    try std.testing.expectEqual(@as(u64, 1), loaded.room_battles.?.serial);

    world.progress.story.scenario.?.scenario[1] = 0;
    state.combat.progress.story.scenario.?.scenario[1] = 0;
    _ = try state.tickWithFieldEvents(.{}, .{});
    try std.testing.expect(state.field_event == null);
    try std.testing.expectEqual(@as(u64, 1), loaded.room_battles.?.serial);
    for (0..state.package.step_ticks) |_| _ = try state.tickWithFieldEvents(.{ .field = .{ .direction = .left } }, .{});
    for (0..state.package.step_ticks) |step| _ = try state.tickWithFieldEvents(.{ .field = .{ .direction = .right }, .menu = step + 1 == state.package.step_ticks }, .{});
    try std.testing.expectEqualStrings("vb6_village", state.package.rooms[world.room].id);
    try std.testing.expect(state.field_event == null);
    try std.testing.expectEqual(.root, state.menu.phase);
    try snapshot.apply(&state);

    world.progress.story.scenario.?.scenario[1] = 4;
    state.combat.progress.story.scenario.?.scenario[1] = 4;
    state.data.field_encounters = .{
        .schema = "suikoden-field-movement-encounters/1",
        .rooms = &.{.{ .room = "vb6_inn", .rate = 1, .counter_threshold = 1, .candidates = &.{.{ .id = "area_a_2", .enemy_level_sum = 15 }} }},
    };
    state.field_encounter_clock = .{ .ready = true, .updates = 2 };
    const before_encounter = state.combat.random;
    for (0..8) |_| {
        _ = try state.tickWithFieldEvents(.{}, .{});
        if (state.mode == .battle) break;
    } else return error.MissingScriptedBattle;
    try std.testing.expectEqualStrings("area_a_1", state.combat.content.encounters[state.combat.encounter].id);
    try std.testing.expectEqualDeep(before_encounter, state.combat.random);
    for (state.combat.progress.party) |*member| {
        member.hp = 0;
        member.status = .unconscious;
    }
    state.combat.phase = .defeat;
    _ = try state.tickWithFieldEvents(.{}, .{});
    try std.testing.expectEqual(.defeat, state.mode);
    try std.testing.expect(state.defeatContinuesScene());
    _ = try state.tickWithFieldEvents(.{}, .{ .confirm = true });
    try std.testing.expectEqual(.field, state.mode);
    try std.testing.expect(state.checkpoint == null and state.scripted_battle == null);
    _ = try state.tickWithFieldEvents(.{}, .{});
    try std.testing.expectEqual(@as(u8, 14), world.progress.story.scenario.?.scenario[1]);
    try std.testing.expectEqual(@as(i32, 256), world.x);
    try std.testing.expectEqual(balance, world.progress.money);
    try std.testing.expectEqual(@as(u16, 0), world.progress.party[0].hp);

    try writeFieldBattle(io, temp.dir, "area_a_1", .terminal_defeat);
    var terminal = try content.Bundle.load(std.testing.allocator, io, temp.dir, &diagnostic);
    defer terminal.deinit();
    boot.bundle = terminal;
    state = try boot.newState();
    for (0..state.package.step_ticks + 8) |_| {
        _ = try state.tickWithFieldEvents(.{ .field = .{ .direction = .right } }, .{});
        if (state.mode == .battle) break;
    } else return error.MissingScriptedBattle;
    try std.testing.expect(!state.scripted_battle.?.opening and state.defeatEndsRun());
    state.combat.phase = .defeat;
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try state.tickWithFieldEvents(.{}, .{ .confirm = true });
    try std.testing.expectEqual(.game_over, state.mode);
    try std.testing.expect(state.checkpoint == null and state.field_event == null and state.scripted_battle == null);
    try std.testing.expectEqual(@as(u8, 6), world.progress.story.scenario.?.scenario[1]);
}

test "scripted duel outcomes and war completion resume field branches and persist" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const cases = [_]struct { encounter: []const u8, duel_result_mask: u8 }{
        .{ .encounter = "duel:pahn_teo", .duel_result_mask = 1 },
        .{ .encounter = "duel:pahn_teo", .duel_result_mask = 2 },
        .{ .encounter = "war:teo_before_fire_spear", .duel_result_mask = 0 },
    };
    for (cases) |case| {
        errdefer std.debug.print("Returning from {s} with duel result mask {d}\n", .{ case.encounter, case.duel_result_mask });
        var temp = std.testing.tmpDir(.{});
        defer temp.cleanup();
        try fixtures(io, temp.dir);
        try writeFieldBattle(io, temp.dir, case.encounter, .escape_branch);
        var diag: content.Diagnostic = .{};
        var loaded = try content.Bundle.load(allocator, io, temp.dir, &diag);
        defer loaded.deinit();
        var members: [6]battle.Member = undefined;
        var boot_combat: battle.State = undefined;
        var boot: @import("journey_boot").Boot = .{
            .allocator = allocator,
            .path = @constCast(""),
            .save_path = null,
            .bundle = loaded,
            .party = null,
            .members = &members,
            .combat = &boot_combat,
            .state = undefined,
        };
        var state = try boot.newState();
        defer state.releaseRestoredSave();
        defer state.deinitActiveModes();
        if (case.duel_result_mask == 1) {
            for (state.combat.progress.party, 0..) |member, index| {
                if (!std.mem.eql(u8, member.id, "pahn")) continue;
                state.combat.progress.party[index].base_stats.attack = 999;
                state.combat.progress.party[index].base_stats.defense = 999;
            }
        }
        const expected_mode: journey.Mode = if (case.duel_result_mask != 0) .duel else .war;
        for (0..state.package.step_ticks + 8) |_| {
            _ = try state.tickWithFieldEvents(.{ .field = .{ .direction = .right } }, .{});
            if (state.mode != .field) break;
        }
        try std.testing.expectEqual(expected_mode, state.mode);
        const expected_audio: @TypeOf(state.audioScene()) = if (expected_mode == .duel) .duel else .war;
        try std.testing.expectEqual(expected_audio, state.audioScene());
        try std.testing.expect(state.defeatContinuesScene());
        for (0..4000) |_| {
            if (state.mode != expected_mode) break;
            if (state.active_duel) |*active| {
                const selecting = active.state.phase == .choosing;
                const defend = case.duel_result_mask == 2 and selecting and active.state.selected != .defend;
                _ = try state.tickWithFieldEvents(.{}, .{
                    .down = defend,
                    .confirm = (selecting and !defend) or active.state.phase == .finished,
                });
            } else if (state.active_war) |*active| {
                const engine = &active.session.engine;
                const confirm = switch (engine.phase) {
                    .scripted => if (engine.script) |script| script.phase == engine.scenario.lifecycle.wait_phase else false,
                    .result => true,
                    else => false,
                };
                _ = try state.tickWithFieldEvents(.{}, .{ .confirm = confirm });
            }
        }
        try std.testing.expectEqual(.field, state.mode);
        try std.testing.expectEqual(.field, state.audioScene());
        try std.testing.expect(state.active_duel == null and state.active_war == null);
        try std.testing.expect(state.scripted_battle == null);
        for (0..8) |_| {
            if (state.field_event == null) break;
            _ = try state.tickWithFieldEvents(.{}, .{});
        }
        try std.testing.expect(state.field_event == null);
        const story = state.field_state.progress.story.scenario.?;
        try std.testing.expectEqual(@as(u8, if (case.duel_result_mask == 2) 14 else 7), story.scenario[1]);
        try std.testing.expectEqual(case.duel_result_mask, story.scenario[34] & 3);
        try std.testing.expectEqualDeep(story, state.combat.progress.story.scenario.?);
        try journey.save(io, allocator, temp.dir, state);
        var fresh_members: [6]battle.Member = undefined;
        boot.members = &fresh_members;
        var restored = try boot.newState();
        defer restored.releaseRestoredSave();
        try journey.restore(io, allocator, temp.dir, &restored);
        try std.testing.expectEqualDeep(story, restored.field_state.progress.story.scenario.?);
    }
}

fn dialogueFont(window: *[9]ui_font.WindowPiece) ui_font.Font {
    for (window, 0..) |*piece, index| piece.* = .{ .role = @fromBackingInt(@intCast(index)), .rect = .{ .x = 0, .y = 0, .w = 12, .h = 12 } };
    return .{
        .schema = "suikoden-ui-font/1",
        .window = window,
        .glyphs = &.{
            .{ .character = "G", .rect = .{ .x = 32, .y = 0, .w = 8, .h = 12 }, .advance = 8 },
            .{ .character = "o", .rect = .{ .x = 40, .y = 0, .w = 8, .h = 12 }, .advance = 8 },
            .{ .character = "R", .rect = .{ .x = 48, .y = 0, .w = 8, .h = 12 }, .advance = 8 },
            .{ .character = "H", .rect = .{ .x = 56, .y = 0, .w = 8, .h = 12 }, .advance = 8 },
            .{ .character = "e", .rect = .{ .x = 64, .y = 0, .w = 8, .h = 12 }, .advance = 8 },
            .{ .character = "r", .rect = .{ .x = 72, .y = 0, .w = 8, .h = 12 }, .advance = 8 },
        },
    };
}

test "package field battle stages movement, shared camera, portraits, and visible dialogue before combat" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const io = std.testing.io;
    try fixtures(io, temp.dir);
    var diagnostic: content.Diagnostic = .{};
    try writeFieldBattle(io, temp.dir, "area_a_1", .dialogue);
    try std.testing.expectError(error.MissingUiFont, content.Bundle.load(std.testing.allocator, io, temp.dir, &diagnostic));
    try std.testing.expectEqualStrings("ui.json", diagnostic.path);
    var window: [9]ui_font.WindowPiece = undefined;
    const font = dialogueFont(&window);
    var incomplete = font;
    incomplete.glyphs = font.glyphs[0..1];
    const missing_bytes = try std.json.Stringify.valueAlloc(std.testing.allocator, incomplete, .{});
    defer std.testing.allocator.free(missing_bytes);
    try temp.dir.writeFile(io, .{ .sub_path = "ui.json", .data = missing_bytes });
    try std.testing.expectError(error.MissingOpeningGlyph, content.Bundle.load(std.testing.allocator, io, temp.dir, &diagnostic));
    try std.testing.expectEqualStrings("ui.json", diagnostic.path);
    try writeFieldBattle(io, temp.dir, "area_a_1", .motion);
    const bytes = try std.json.Stringify.valueAlloc(std.testing.allocator, font, .{});
    defer std.testing.allocator.free(bytes);
    try temp.dir.writeFile(io, .{ .sub_path = "ui.json", .data = bytes });
    {
        var motion_bundle = try content.Bundle.load(std.testing.allocator, io, temp.dir, &diagnostic);
        defer motion_bundle.deinit();
        try std.testing.expect(!motion_bundle.room_battles.?.hasPortraits());
    }
    try writeFieldBattle(io, temp.dir, "area_a_1", .portrait);
    var loaded = try content.Bundle.load(std.testing.allocator, io, temp.dir, &diagnostic);
    defer loaded.deinit();
    try std.testing.expect(loaded.room_battles.?.hasPortraits());
    try loaded.room_battles.?.validatePortraitAtlas(272, 80);
    try std.testing.expectError(error.InvalidFieldPortraitAtlas, loaded.room_battles.?.validatePortraitAtlas(271, 80));
    var members: [6]battle.Member = undefined;
    var boot_combat: battle.State = undefined;
    var boot: @import("journey_boot").Boot = .{ .allocator = std.testing.allocator, .path = @constCast(""), .save_path = null, .bundle = loaded, .party = null, .members = &members, .combat = &boot_combat, .state = undefined };
    var state = try boot.newState();
    for (0..state.package.step_ticks) |_| _ = try state.tickWithFieldEvents(.{ .field = .{ .direction = .right } }, .{});
    _ = try state.tickWithFieldEvents(.{}, .{});
    try std.testing.expectEqual(@as(i32, 264), state.field_state.x);
    const base_camera = state.fieldCamera();
    const first_frame = state.package.player_clips[@backingInt(state.field_state.facing)].frames[1];
    const first_hero = (try state.scriptedFieldHero(base_camera)).?;
    try std.testing.expectEqual(base_camera.x + 258 - @as(f32, @floatFromInt(first_frame.anchor_x)), first_hero.x);
    _ = try state.tickWithFieldEvents(.{}, .{});
    try std.testing.expectEqual(base_camera.x - 1, state.fieldCamera().x);
    try std.testing.expectEqual(base_camera.y + 2, state.fieldCamera().y);
    const session = state.field_event.?.session;
    const saved_session = try std.json.Stringify.valueAlloc(std.testing.allocator, session.*, .{});
    defer std.testing.allocator.free(saved_session);
    var restored = try std.json.parseFromSlice(@TypeOf(session.*), std.testing.allocator, saved_session, .{});
    defer restored.deinit();
    try restored.value.validate(state.field_event.?.binding.*);
    try std.testing.expectEqualDeep(session.scripted_camera, restored.value.scripted_camera);
    restored.value.scripted_camera.?.pan.?.remaining = 0;
    try std.testing.expectError(error.InvalidCameraPan, restored.value.validate(state.field_event.?.binding.*));
    for (0..18) |_| {
        try std.testing.expectEqual(.closed, session.boxes[0].phase);
        _ = try state.tickWithFieldEvents(.{}, .{});
    }
    try std.testing.expectEqual(@as(i32, 272), state.field_state.x);
    try std.testing.expectEqual(@as(i32, 200), state.field_state.y);
    try std.testing.expectEqual(base_camera.x - 12, state.fieldCamera().x);
    try std.testing.expectEqual(base_camera.y + 24, state.fieldCamera().y);
    for (0..12) |_| {
        try std.testing.expectEqual(.closed, session.boxes[0].phase);
        _ = try state.tickWithFieldEvents(.{}, .{});
    }
    try std.testing.expectEqual(@as(i32, 264), state.field_state.x);
    _ = try state.tickWithFieldEvents(.{}, .{});
    const list = try std.testing.allocator.create(journey.field_dialogue_view.presentation.List);
    defer std.testing.allocator.destroy(list);
    try state.composeFieldBattleDialogue(loaded.ui.?, list);
    try std.testing.expectEqual(@as(usize, 4), list.length);
    try std.testing.expectEqual(.line, std.meta.activeTag(list.pieces[0]));
    _ = try state.tickWithFieldEvents(.{ .field = .{ .action = true } }, .{ .confirm = true });
    var drew_room_portrait = false;
    for (0..60) |_| {
        if (!drew_room_portrait and session.boxes[0].phase == .open and session.boxes[0].image == 0) {
            try state.composeFieldBattleDialogue(loaded.ui.?, list);
            try std.testing.expectEqual(@as(i32, 80), list.pieces[9].sprite.rect.x);
            drew_room_portrait = true;
        }
        _ = try state.tickWithFieldEvents(.{}, .{});
    }
    try std.testing.expect(drew_room_portrait);
    try std.testing.expectEqual(.field, state.mode);
    try std.testing.expectEqual(@as(u8, 4), state.field_state.progress.story.scenario.?.scenario[1]);
    try state.composeFieldBattleDialogue(loaded.ui.?, list);
    try std.testing.expectEqual(window.len + 4, list.length);
    try std.testing.expectEqualStrings("Go", state.field_event.?.session.text_job.?.state.visible());
    try std.testing.expectEqual(@as(?u8, 1), session.boxes[0].image);
    try std.testing.expectEqual(@as(i32, 144), list.pieces[9].sprite.rect.x);
    try std.testing.expect(list.pieces[9].sprite.mirror);
    try std.testing.expectEqual(@as(i32, 48), list.pieces[10].sprite.rect.x);
    try std.testing.expectEqual(@as(i32, 32), list.pieces[11].sprite.rect.x);
    try std.testing.expectEqual(@as(i32, 40), list.pieces[12].sprite.rect.x);
    _ = try state.tickWithFieldEvents(.{ .field = .{ .action = true } }, .{ .confirm = true });
    try std.testing.expectEqual(.field, state.mode);
    try std.testing.expectEqual(.open, state.field_event.?.session.boxes[0].phase);
    _ = try state.tickWithFieldEvents(.{}, .{});
    try state.composeFieldBattleDialogue(loaded.ui.?, list);
    try std.testing.expectEqual(@as(usize, 4), list.length);
    for (0..19) |_| _ = try state.tickWithFieldEvents(.{}, .{});
    try std.testing.expectEqual(.field, state.mode);
    for (0..16) |_| {
        if (session.scripted_camera.?.pan == null) break;
        _ = try state.tickWithFieldEvents(.{}, .{});
        try std.testing.expectEqual(.field, state.mode);
    } else return error.ScriptedPanDidNotFinish;
    try std.testing.expectEqual(base_camera.x + 16, state.fieldCamera().x);
    try std.testing.expectEqual(base_camera.y - 4, state.fieldCamera().y);
    try std.testing.expectEqual(.up, state.field_state.facing);
    try std.testing.expectEqual(@as(u2, 1), (try state.scriptedFieldHero(state.fieldCamera())).?.variant);
    _ = try state.tickWithFieldEvents(.{}, .{});
    try std.testing.expectEqual(.battle, state.mode);
    try std.testing.expectEqual(@as(u8, 6), state.field_state.progress.story.scenario.?.scenario[1]);
    try state.composeFieldBattleDialogue(loaded.ui.?, list);
    try std.testing.expectEqual(@as(usize, 0), list.length);
}

test "package field battle choices wait for confirmation and select battle or field return" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const io = std.testing.io;
    try fixtures(io, temp.dir);
    var window: [9]ui_font.WindowPiece = undefined;
    const font = dialogueFont(&window);
    const bytes = try std.json.Stringify.valueAlloc(std.testing.allocator, font, .{});
    defer std.testing.allocator.free(bytes);
    try temp.dir.writeFile(io, .{ .sub_path = "ui.json", .data = bytes });
    const list = try std.testing.allocator.create(journey.field_dialogue_view.presentation.List);
    defer std.testing.allocator.destroy(list);
    const Outcome = enum { battle, alternate, scene, join };
    for ([_]Outcome{ .battle, .alternate, .scene, .join }) |outcome| {
        const alternate = outcome == .alternate;
        if (outcome == .battle) {
            const allocator = std.testing.allocator;
            const trial = try battle.load(allocator, @embedFile("fixtures/journey_battle.json"));
            defer trial.deinit();
            const encounters = try allocator.dupe(battle.Encounter, trial.value.encounters);
            defer allocator.free(encounters);
            encounters[0].reward_policy = .none;
            encounters[0].escape_allowed = false;
            encounters[0].scripted_finish = .{ .after_round = 1, .wait_ticks = 12 };
            const enemies = try allocator.dupe(battle.Profile, trial.value.enemies);
            defer allocator.free(enemies);
            enemies[trial.value.enemyIndex(encounters[0].enemies[0]).?].max_hp = 9999;
            var configured = trial.value;
            configured.schema = "suikoden-battle-trial/46";
            configured.encounters = encounters;
            configured.enemies = enemies;
            const encoded = try std.json.Stringify.valueAlloc(allocator, configured, .{});
            defer allocator.free(encoded);
            try temp.dir.writeFile(io, .{ .sub_path = "battle/trial.json", .data = encoded });
        }
        if (outcome == .join) {
            const allocator = std.testing.allocator;
            const parsed = try field.load(allocator, @embedFile("fixtures/journey_room.json"));
            defer parsed.deinit();
            const entry_count = opening_rooms.len - 1;
            const rooms = try allocator.alloc(field.Room, entry_count + parsed.value.rooms.len);
            defer allocator.free(rooms);
            @memcpy(rooms[entry_count..], parsed.value.rooms);
            const inn_index = parsed.value.roomIndex("vb6_inn").?;
            const template = parsed.value.rooms[inn_index];
            var exits: [entry_count]field.Exit = undefined;
            for (rooms[0..entry_count], &exits, 0..) |*room, *exit, index| {
                exit.* = .{ .x = 256, .y = 208, .w = 8, .h = 8, .room = opening_rooms[index + 1], .spawn_x = 248, .spawn_y = 208 };
                room.* = template;
                room.id = opening_rooms[index];
                room.npcs = &.{};
                room.events = &.{};
                room.exits = exits[index .. index + 1];
            }
            exits[0].conditions = &.{.{ .kind = .story_mask_set, .flag = .{ .id = "scenario_0001", .mask = 4 } }};
            rooms[entry_count + inn_index].exits = &.{.{
                .x = 248,
                .y = 216,
                .w = 8,
                .h = 8,
                .room = "vb6_village",
                .spawn_x = 400,
                .spawn_y = 264,
                .direction = .down,
                .arrival_facing = .up,
                .conditions = exits[0].conditions,
                .room_conditions = &.{.{ .kind = .room_mask_set, .index = 0, .mask = 2 }},
                .world_exit = true,
            }};
            var package = parsed.value;
            package.schema = field.Package.room_conditions_schema;
            package.rooms = rooms;
            package.start_room = opening_rooms[0];
            const encoded = try std.json.Stringify.valueAlloc(allocator, package, .{});
            defer allocator.free(encoded);
            try temp.dir.writeFile(io, .{ .sub_path = "room.json", .data = encoded });

            const parsed_journey = try std.json.parseFromSlice(journey.Data, allocator, @embedFile("fixtures/journey.json"), .{});
            defer parsed_journey.deinit();
            var configured = parsed_journey.value;
            configured.field_encounters = .{
                .schema = "suikoden-field-movement-encounters/3",
                .rooms = &.{.{ .room = "vb6_village", .rate = 2, .counter_threshold = 60, .candidates = &.{.{ .id = "area_a_1", .enemy_level_sum = 5 }} }},
                .suppress_when = .{ .kind = .story_mask_set, .flag = .{ .id = "scenario_0001", .mask = 4 } },
                .clear_suppression_on_world_entry = true,
            };
            const journey_bytes = try std.json.Stringify.valueAlloc(allocator, configured, .{});
            defer allocator.free(journey_bytes);
            try temp.dir.writeFile(io, .{ .sub_path = "journey.json", .data = journey_bytes });
        }
        try writeFieldBattle(io, temp.dir, "area_a_1", switch (outcome) {
            .scene => .scene,
            .join => .join,
            .battle => .opening_battle,
            .alternate => .choice,
        });
        var diagnostic: content.Diagnostic = .{};
        if (outcome == .scene) {
            const allocator = std.testing.allocator;
            const parsed = try field.load(allocator, @embedFile("fixtures/journey_room.json"));
            defer parsed.deinit();
            var package = parsed.value;
            const rooms = try allocator.dupe(field.Room, package.rooms);
            defer allocator.free(rooms);
            const room = &rooms[package.roomIndex("vb6_inn").?];
            var draws = [_]field.Draw{ room.draws[0], room.draws[0] };
            draws[0].room_conditions = &.{.{ .kind = .room_mask_clear, .index = 0, .mask = 4 }};
            draws[1].room_conditions = &.{.{ .kind = .room_mask_set, .index = 0, .mask = 4 }};
            draws[1].x += 8;
            room.draws = &draws;
            package.rooms = rooms;
            package.schema = field.Package.room_conditions_schema;
            try std.testing.expectError(error.InvalidSceneryConditions, package.validate());
            package.schema = field.Package.scenery_conditions_schema;
            const encoded = try std.json.Stringify.valueAlloc(allocator, package, .{});
            defer allocator.free(encoded);
            try temp.dir.writeFile(io, .{ .sub_path = "room.json", .data = encoded });

            const sound_path = "audio/sfx/battle_sfx.json";
            try temp.dir.createDirPath(io, "audio/sfx");
            try temp.dir.writeFile(io, .{ .sub_path = sound_path, .data = "{\"schema\":\"suikoden-battle-sfx/1\",\"sample_rate\":44100,\"cues\":[]}" });
            try std.testing.expectError(error.MissingFieldSoundCue, content.Bundle.load(std.testing.allocator, io, temp.dir, &diagnostic));
            try std.testing.expectEqualStrings(sound_path, diagnostic.path);
            try temp.dir.writeFile(io, .{ .sub_path = sound_path, .data =
                \\{"schema":"suikoden-battle-sfx/1","sample_rate":44100,"cues":[{"id":1281,"path":"0501.wav","frames":1,"sha256":"0000000000000000000000000000000000000000000000000000000000000000","bank":0,"program":0,"note":60,"retrigger":false}]}
            });
        }
        var loaded = try content.Bundle.load(std.testing.allocator, io, temp.dir, &diagnostic);
        defer loaded.deinit();
        if (outcome == .battle) try temp.dir.writeFile(io, .{ .sub_path = "battle/trial.json", .data = @embedFile("fixtures/journey_battle.json") });
        var members: [6]battle.Member = undefined;
        var boot_combat: battle.State = undefined;
        const boot = try std.testing.allocator.create(@import("journey_boot").Boot);
        defer std.testing.allocator.destroy(boot);
        boot.* = .{ .allocator = std.testing.allocator, .path = @constCast(""), .save_path = null, .bundle = loaded, .party = null, .members = &members, .combat = &boot_combat, .state = undefined };
        defer if (boot.opening_seed) |seed| seed.deinit();
        defer if (boot.party) |*party| party.deinit();
        if (outcome == .join) {
            boot.opening_seed = try journey.opening.load(std.testing.allocator, journey.opening.json);
            const catalogue = @import("party_session").catalogue;
            const roster_data = @import("party_data").json;
            const catalog = try catalogue.decode(std.testing.allocator, roster_data);
            errdefer catalog.deinit();
            boot.party = .{ .catalog = catalog, .bindings = try catalogue.decodeBindings(std.testing.allocator, @embedFile("party_session/ownership_bindings.json"), roster_data) };
        }
        const state = try std.testing.allocator.create(journey.State);
        defer std.testing.allocator.destroy(state);
        state.* = try boot.newState();
        const initial_rng = state.combat.random;
        var room_actors: [64]journey.RoomActorDraw = undefined;
        if (outcome == .scene) {
            try std.testing.expect(!state.room_battles.?.ownsRoomExit("vb6_inn"));
            try std.testing.expectEqual(@as(u8, 4), state.field_state.progress.story.scenario.?.scenario[1]);
            try std.testing.expect(state.field_state.local_flags.matches(0, 2, true));
            const draws = state.package.rooms[state.field_state.room].draws;
            try std.testing.expect(draws[0].sampleVisible(&state.field_state) != null);
            try std.testing.expect(draws[1].sampleVisible(&state.field_state) == null);
            try std.testing.expectError(error.InvalidFieldActorAtlas, state.room_battles.?.validateActorAtlas(31, 8));
            const actor_draws = state.roomActorDraws(.{ .x = 0, .y = 0 }, &room_actors);
            try std.testing.expectEqual(@as(usize, 1), actor_draws.len);
            try std.testing.expectEqual(@as(i32, 0), actor_draws[0].rect.x);
            try std.testing.expectEqual(@as(f32, 268), actor_draws[0].x);
        }
        if (outcome == .join) {
            try std.testing.expectEqual(.opening, state.route.stage);
            try std.testing.expect(state.room_battles.?.ownsPartyJoin("pahn"));
            try std.testing.expect(!state.room_battles.?.ownsPartyJoin("cleo"));
            try std.testing.expect(!state.route.milestones.initial_party);
            try std.testing.expect(state.combat.rune(0) == null);
            const bag = &state.combat.progress.party[0].inventory;
            @memset(bag.slots[bag.count()..], .{ .id = .medicine, .uses = 6 });
            for ([_]journey.opening_route.Stage{ .dungeon, .palace, .first_town }) |stage| {
                for (0..state.package.step_ticks) |_| _ = try state.tickWithFieldEvents(.{ .field = .{ .direction = .right } }, .{});
                try std.testing.expectEqual(stage, state.route.stage);
            }
            try std.testing.expectEqualStrings("vb6_inn", state.package.rooms[state.field_state.room].id);
            try std.testing.expectEqual(@as(usize, 1), state.combat.partyCount());
            try std.testing.expect(!state.field_encounter_clock.enabled);
            try state.field_state.local_flags.orByte(0, 2);
            try journey.save(io, std.testing.allocator, temp.dir, state.*);
            try journey.restore(io, std.testing.allocator, temp.dir, state);
            try std.testing.expect(state.field_state.local_flags.matches(0, 2, true));
            const before_exit = try std.testing.allocator.create(journey.Snapshot);
            defer std.testing.allocator.destroy(before_exit);
            before_exit.* = try journey.Snapshot.capture(state.*);
            for (0..state.package.step_ticks) |_| _ = try state.tickWithFieldEvents(.{ .field = .{ .direction = .down } }, .{});
            try std.testing.expectEqual(.world, state.route.stage);
            try std.testing.expectEqual(@as(u64, 4), state.route.journal);
            try std.testing.expectEqualStrings("vb6_village", state.package.rooms[state.field_state.room].id);
            try std.testing.expectEqual(.up, state.field_state.facing);
            try std.testing.expectEqual(@as(u8, 0), state.field_state.local_flags.values[0]);
            try std.testing.expect(state.field_encounter_clock.enabled);
            try std.testing.expectEqual(@as(u8, 0), state.combat.progress.story.scenario.?.scenario[1]);
            try std.testing.expectEqualDeep(initial_rng, state.combat.random);
            try journey.save(io, std.testing.allocator, temp.dir, state.*);
            try journey.restore(io, std.testing.allocator, temp.dir, state);
            try std.testing.expectEqual(.up, state.field_state.facing);
            try before_exit.apply(state);
            state.combat.progress.party[0].rune = state.combat.content.systems.?.runeIndex("fire") orelse return error.MissingFixtureRune;
        }
        if (outcome == .battle) {
            const fallback = [_]journey.Trigger{.{ .id = "old_guard_trigger", .room = "vb6_inn", .x = 256, .y = 208, .w = 8, .h = 8, .encounter = "area_a_1", .flag = .forest_battle_one_won }};
            const encounters = state.data.encounters;
            state.data.encounters = &fallback;
            const before_arrival = try std.testing.allocator.create(journey.Snapshot);
            defer std.testing.allocator.destroy(before_arrival);
            before_arrival.* = try journey.Snapshot.capture(state.*);
            var story = state.room_battles.?.initial_story;
            try story.clear(.{ .id = "scenario_0001", .mask = 4 });
            state.combat.progress.story.scenario = story;
            for (0..state.package.step_ticks) |_| _ = try state.tickWithFieldEvents(.{ .field = .{ .direction = .right } }, .{});
            try std.testing.expectEqual(.field, state.mode);
            try std.testing.expectEqual(@as(i32, 256), state.field_state.x);
            try before_arrival.apply(state);
            var competing = fallback;
            competing[0].encounter = "area_a_2";
            competing[0].x = 248;
            state.data.encounters = &competing;
            state.field_state.enterRoom(state.package.roomIndex("vb6_village").?, .{ .x = 400, .y = 264 });
            for (0..state.package.step_ticks) |_| _ = try state.tickWithFieldEvents(.{ .field = .{ .direction = .up } }, .{});
            try std.testing.expectEqualStrings("vb6_inn", state.package.rooms[state.field_state.room].id);
            try std.testing.expectEqual(.field, state.mode);
            try std.testing.expect(state.field_event != null);
            state.data.encounters = encounters;
            try before_arrival.apply(state);
            try journey.save(io, std.testing.allocator, temp.dir, state.*);
            try journey.restore(io, std.testing.allocator, temp.dir, state);
            const x = state.field_state.x;
            _ = try state.tickWithFieldEvents(.{ .field = .{ .direction = .right } }, .{});
            try std.testing.expect(state.field_event != null);
            try std.testing.expectEqual(x, state.field_state.x);
            try std.testing.expectEqual(@as(u16, 0), state.field_state.remaining);
        } else {
            for (0..state.package.step_ticks) |_| _ = try state.tickWithFieldEvents(.{ .field = .{ .direction = .right } }, .{});
        }
        if (outcome == .scene) {
            _ = try state.tickWithFieldEvents(.{}, .{});
            try std.testing.expect(state.field_event == null);
            const room_events = state.room_battles.?;
            var binding = room_events.bindingFor("vb6_inn").?;
            const story = state.field_state.progress.story.scenario.?;
            const actors = try binding.constructRoomActors(story);
            const Session = @TypeOf(room_events.session);
            const host = state.combat.integrationHost().?;
            var ids: [6]u8 = undefined;
            const roster = ids[0..state.combat.partyCount()];
            for (state.combat.progress.party, roster) |member, *id| id.* = host.characterId(member.id).?;
            const leader = roster[0];
            roster[0] = 4;
            binding.party = roster;
            try std.testing.expectError(error.UnavailableFieldInteraction, Session.beginInteraction(binding, state.field_state, 1, 0, actors));
            roster[0] = leader;
            roster[roster.len - 1] = 1;
            try std.testing.expectError(error.UnavailableFieldInteraction, Session.beginInteraction(binding, state.field_state, 1, 0, actors));
            try std.testing.expectEqualDeep(story, state.field_state.progress.story.scenario.?);
            _ = try state.tickWithFieldEvents(.{ .field = .{ .action = true } }, .{});
            try std.testing.expect(state.field_event != null);
        }
        if (outcome == .join) {
            _ = try state.tickWithFieldEvents(.{ .field = .{ .menu_direction = .down } }, .{});
            try std.testing.expect(state.field_event == null);
            const open_gate = state.field_state;
            try state.field_state.local_flags.orByte(0, 4);
            _ = try state.tickWithFieldEvents(.{ .field = .{ .direction = .down } }, .{});
            try std.testing.expect(state.field_event == null);
            state.field_state = open_gate;
            _ = try state.tickWithFieldEvents(.{ .field = .{ .direction = .down } }, .{});
            try std.testing.expect(state.field_event != null);
        }
        for (0..100) |_| {
            _ = try state.tickWithFieldEvents(.{}, .{});
            if (state.field_event) |owner| if (owner.session.instance.?.choiceBox(owner.binding.content) != null) break;
        } else return error.FieldChoiceDidNotOpen;
        const owner = state.field_event.?;
        const session = owner.session;
        if (outcome == .scene) try std.testing.expectEqualStrings("Go\nHero", session.text_job.?.state.visible());
        if (outcome == .scene) state.field_encounter_clock.updates = 17;
        try state.composeFieldBattleDialogue(loaded.ui.?, list);
        try std.testing.expectEqual(@as(i32, 156), list.pieces[list.length - 5].additive_fill.rect.y);
        _ = try state.tickWithFieldEvents(.{ .field = .{ .menu_direction = .down, .action = true } }, .{});
        _ = try state.tickWithFieldEvents(.{ .field = .{ .cancel = true } }, .{});
        try std.testing.expectEqual(@as(u1, 0), session.instance.?.execution.choice);
        try std.testing.expectEqual(.choice, session.instance.?.execution.wait.?.kind);
        if (alternate) _ = try state.tickWithFieldEvents(.{ .field = .{ .menu_direction = .up } }, .{});
        try state.composeFieldBattleDialogue(loaded.ui.?, list);
        try std.testing.expectEqual(@as(i32, if (alternate) 168 else 156), list.pieces[list.length - 5].additive_fill.rect.y);
        const checkpoint = try std.json.Stringify.valueAlloc(std.testing.allocator, session.*, .{});
        defer std.testing.allocator.free(checkpoint);
        var restored = try std.json.parseFromSlice(@TypeOf(session.*), std.testing.allocator, checkpoint, .{});
        defer restored.deinit();
        try restored.value.validate(owner.binding.*);
        const wait = &restored.value.instance.?.execution.wait.?;
        const choice_command = wait.command_index;
        wait.command_index = 0;
        try std.testing.expectError(error.InvalidEventWait, restored.value.validate(owner.binding.*));
        wait.command_index = choice_command;
        session.* = restored.value;
        try std.testing.expectEqual(@as(u8, 4), state.field_state.progress.story.scenario.?.scenario[1]);
        _ = try state.tickWithFieldEvents(.{ .field = .{ .action = true } }, .{});
        try std.testing.expectEqual(.field, state.mode);
        try std.testing.expectEqual(@as(u1, @intFromBool(alternate)), session.instance.?.execution.choice);
        try std.testing.expect(session.instance.?.execution.wait == null);
        var moved_while_closing = false;
        var reached_exit_mark = false;
        var faded_before_exit = false;
        var room_flag_committed = false;
        var actor_turned = false;
        var sound_count: usize = 0;
        for (0..80) |_| {
            _ = try state.tickWithFieldEvents(.{}, .{});
            for (state.roomActorDraws(.{ .x = 0, .y = 0 }, &room_actors)) |actor| actor_turned = actor_turned or actor.rect.x == 24;
            if (state.takeFieldSound()) |cue| {
                try std.testing.expectEqual(@as(u16, 0x501), cue);
                const actors = state.roomActorDraws(.{ .x = 0, .y = 0 }, &room_actors);
                try std.testing.expectEqual(@as(usize, 1), actors.len);
                // Two right steps and one down step, minus the fixture's sprite anchor.
                try std.testing.expectEqual(@as(f32, 272 + 2 * 8 - 4), actors[0].x);
                try std.testing.expectEqual(@as(f32, 208 + 8 - 8), actors[0].y);
                try std.testing.expect(state.takeFieldSound() == null);
                sound_count += 1;
            }
            moved_while_closing = moved_while_closing or (session.alignment != null and session.boxes[0].phase == .closing);
            reached_exit_mark = reached_exit_mark or (state.field_event != null and state.field_state.x == 264 and !state.field_state.walking);
            if (state.field_event != null) if (session.fadeOverlay()) |fade| {
                faded_before_exit = faded_before_exit or fade.color[0] == 255;
            };
            if (state.field_state.local_flags.matches(0, 4, true)) {
                const draws = state.package.rooms[state.field_state.room].draws;
                try std.testing.expect(draws[0].sampleVisible(&state.field_state) == null);
                try std.testing.expectEqual(draws[0].x + 8, draws[1].sampleVisible(&state.field_state).?.x);
                room_flag_committed = true;
            }
            if (state.mode == .battle or state.field_event == null) break;
        } else return error.FieldChoiceDidNotResolve;
        try std.testing.expectEqual(@as(usize, @intFromBool(outcome == .scene)), sound_count);
        try std.testing.expectEqual(outcome == .scene, faded_before_exit);
        try std.testing.expectEqual(outcome == .scene, room_flag_committed);
        try std.testing.expectEqual(outcome == .scene, actor_turned);
        try std.testing.expectEqual(alternate, moved_while_closing);
        const expected_story: u8 = switch (outcome) {
            .battle, .scene => 6,
            .alternate => 4,
            .join => 3,
        };
        try std.testing.expectEqual(expected_story, state.field_state.progress.story.scenario.?.scenario[1]);
        if (outcome != .battle) {
            try std.testing.expectEqual(.field, state.mode);
            try std.testing.expect(state.field_event == null);
            if (outcome == .scene or outcome == .join) {
                const reentered = outcome == .scene;
                if (reentered) {
                    const draws = state.package.rooms[state.field_state.room].draws;
                    try std.testing.expect(draws[0].sampleVisible(&state.field_state) != null);
                    try std.testing.expect(draws[1].sampleVisible(&state.field_state) == null);
                    try std.testing.expect(reached_exit_mark);
                    try std.testing.expectEqual(@as(u8, 2), state.field_state.local_flags.values[0]);
                    try std.testing.expectEqual(@as(u16, 0), state.field_encounter_clock.updates);
                }
                try std.testing.expectEqual(@as(u32, 1), state.field_state.room_entries);
                try std.testing.expectEqualStrings(if (reentered) "vb6_inn" else "vb6_village", state.package.rooms[state.field_state.room].id);
                try std.testing.expectEqual(@as(i32, if (reentered) 248 else 400), state.field_state.x);
                try std.testing.expectEqual(@as(i32, if (reentered) 208 else 264), state.field_state.y);
                if (reentered) {
                    try journey.save(io, std.testing.allocator, temp.dir, state.*);
                    try journey.restore(io, std.testing.allocator, temp.dir, state);
                    try std.testing.expectEqual(expected_story, state.field_state.progress.story.scenario.?.scenario[1]);
                    var saved = try journey.Snapshot.capture(state.*);
                    saved.story.scenario.?.scenario[1] |= 1;
                    try saved.apply(state);
                    _ = try state.tickWithFieldEvents(.{}, .{});
                    try std.testing.expectEqual(@as(u8, 7), state.field_state.progress.story.scenario.?.scenario[1]);
                }
            } else {
                try std.testing.expectEqual(@as(i32, 272), state.field_state.x);
                try std.testing.expectEqualStrings("vb6_inn", state.package.rooms[state.field_state.room].id);
                try std.testing.expectEqual(@as(u32, 0), state.field_state.room_entries);
            }
        } else {
            try std.testing.expectEqual(.battle, state.mode);
            try std.testing.expect(!state.route.milestones.opening_battles);
            const balance = state.combat.progress.money;
            const experience = characterFields("experience", state.combat.progress.party);
            state.combat.reward_drop = true;
            const defeated = try std.testing.allocator.create(journey.State);
            defer std.testing.allocator.destroy(defeated);
            defeated.* = state.*;
            var defeated_members: [6]battle.Member = undefined;
            var defeated_combat: battle.State = undefined;
            defeated.bindValidatedStorage(&defeated_combat, &defeated_members);
            defeated.combat.phase = .defeat;
            defeated.mode = .defeat;
            _ = try defeated.tickWithFieldEvents(.{}, .{ .confirm = true });
            try std.testing.expectEqual(.game_over, defeated.mode);
            try std.testing.expect(defeated.scripted_battle == null and defeated.checkpoint == null);
            try std.testing.expectEqualDeep(state.field_state.progress.story, defeated.field_state.progress.story);
            const run_rng = state.combat.random;
            _ = try state.tickWithFieldEvents(.{}, .{ .down = true });
            _ = try state.tickWithFieldEvents(.{}, .{ .confirm = true });
            try std.testing.expectEqual(.run_refused, state.combat.phase);
            try std.testing.expect(state.scripted_battle != null and state.field_event != null);
            try std.testing.expectEqual(@as(u8, 6), state.field_state.progress.story.scenario.?.scenario[1]);
            _ = try state.tickWithFieldEvents(.{}, .{ .confirm = true });
            try std.testing.expectEqual(.resolving, state.combat.phase);
            try std.testing.expectEqualDeep(run_rng, state.combat.random);
            var finish_started: ?u32 = null;
            var finish_rng = state.combat.random;
            for (0..2000) |_| {
                if (state.combat.phase == .victory and state.combat.rewardReady()) break;
                if (finish_started == null and state.combat.coordinator != null and state.combat.coordinator.?.stage == .victory_wait) {
                    try std.testing.expectEqual(@as(u32, 2), state.combat.round);
                    finish_started = state.combat.camera_ticks;
                    finish_rng = state.combat.random;
                }
                if (state.combat.phase == .battle_menu) {
                    for (0..3) |_| _ = try state.tickWithFieldEvents(.{}, .{ .down = true });
                    _ = try state.tickWithFieldEvents(.{}, .{ .confirm = true });
                } else {
                    _ = try state.tickWithFieldEvents(.{}, .{});
                }
            } else return error.FieldBattleDidNotFinish;
            try std.testing.expectEqual(@as(u32, 12), state.combat.camera_ticks - (finish_started orelse return error.MissingScriptedFinish));
            try std.testing.expect(state.combat.enemy_hp[0] > 0);
            try std.testing.expectEqualDeep(finish_rng, state.combat.random);
            try std.testing.expectEqual(balance, state.combat.progress.money);
            try std.testing.expectEqualDeep(experience, characterFields("experience", state.combat.progress.party));
            try std.testing.expect(state.combat.dropped_item == null);
            try std.testing.expect(!state.route.milestones.opening_battles);
            _ = try state.tickWithFieldEvents(.{}, .{ .confirm = true });
            try std.testing.expectEqual(.field, state.mode);
            try std.testing.expect(state.route.milestones.opening_battles);
            _ = try state.tickWithFieldEvents(.{}, .{});
            try std.testing.expectEqual(@as(u8, 7), state.field_state.progress.story.scenario.?.scenario[1]);
            for (0..40) |_| {
                if (state.field_event == null) break;
                _ = try state.tickWithFieldEvents(.{}, .{});
            } else return error.ArrivalDidNotFinish;
            _ = try state.tickWithFieldEvents(.{}, .{});
            try std.testing.expect(state.field_event == null);
            const saved = try journey.Snapshot.capture(state.*);
            state.* = try boot.newState();
            try saved.apply(state);
            _ = try state.tickWithFieldEvents(.{}, .{});
            try std.testing.expect(state.field_event == null);
            state.field_state.enterRoom(state.field_state.room, .{ .x = saved.x, .y = saved.y });
            _ = try state.tickWithFieldEvents(.{}, .{});
            try std.testing.expect(state.field_event != null);
        }
        if (outcome == .join) {
            try std.testing.expectEqual(.world, state.route.stage);
            try std.testing.expectEqual(@as(u64, 4), state.route.journal);
            try std.testing.expectEqual(.left, state.field_state.facing);
            try std.testing.expect(state.field_encounter_clock.enabled);
            try std.testing.expect(state.route.milestones.initial_party);
            try std.testing.expectEqual(@as(usize, 2), state.combat.partyCount());
            try std.testing.expectEqualStrings("hero", state.combat.progress.party[0].id);
            const joined = state.combat.ownedMember(1);
            try std.testing.expectEqualStrings("pahn", joined.id);
            const reserved = state.reserves[0].?;
            try std.testing.expectEqualStrings("gremio", reserved.id);
            try std.testing.expectEqual(.antitoxin, reserved.inventory.slots[reserved.inventory.count() - 1].?.id);
            try std.testing.expect(state.combat.hasRune(0, "water"));
            try std.testing.expectEqual(.needle, state.combat.progress.party[0].inventory.slots[8].?.id);
            try std.testing.expectEqualStrings("water_crystal", state.shared_items[0].?);
            try std.testing.expect(state.shared_items[1] == null);
            try std.testing.expectEqualDeep(initial_rng, state.combat.random);
            try journey.save(io, std.testing.allocator, temp.dir, state.*);
            state.* = try boot.newState();
            try journey.restore(io, std.testing.allocator, temp.dir, state);
            try std.testing.expectEqual(.world, state.route.stage);
            try std.testing.expectEqual(.left, state.field_state.facing);
            try std.testing.expect(state.route.milestones.initial_party);
            try std.testing.expect(state.combat.hasRune(0, "water"));
            try std.testing.expectEqual(.needle, state.combat.progress.party[0].inventory.slots[8].?.id);
            try std.testing.expectEqualStrings("water_crystal", state.buildPartySnapshot().shared[0].?);
            try std.testing.expect(state.shared_items[1] == null);
            try std.testing.expectEqualDeep(initial_rng, state.combat.random);
            state.menu.selected = .item;
            _ = try state.tickWithFieldEvents(.{ .menu = true }, .{});
            _ = try state.tickWithFieldEvents(.{ .field = .{ .action = true } }, .{});
            try std.testing.expectEqual(.items, state.menu.phase);
            _ = try state.tickWithFieldEvents(.{ .left = true }, .{});
            try std.testing.expectEqual(.shared_items, state.menu.phase);
            try std.testing.expectEqualStrings("Water crystal", state.sharedItemNames()[0].?);
            _ = try state.tickWithFieldEvents(.{ .field = .{ .action = true } }, .{});
            try std.testing.expectEqual(.shared_items, state.menu.phase);
            _ = try state.tickWithFieldEvents(.{ .right = true }, .{});
            try std.testing.expectEqual(.items, state.menu.phase);
            try std.testing.expectEqual(@as(usize, 0), state.menu.member);
            _ = try state.tickWithFieldEvents(.{ .field = .{ .cancel = true } }, .{});
            try std.testing.expectEqual(.root, state.menu.phase);
            try std.testing.expectEqual(@as(usize, 2), state.combat.partyCount());
            try std.testing.expectEqualDeep(joined, state.combat.ownedMember(1));
            try std.testing.expectEqualDeep(reserved, state.reserves[0].?);
            try state.joinPartyMember(&members, state.party_catalog.?, state.party_bindings, "gremio");
            try std.testing.expectEqual(@as(usize, 3), state.combat.partyCount());
            try std.testing.expectEqualDeep(reserved, state.combat.ownedMember(2));
            try std.testing.expect(state.combat.hasRune(2, "wind"));
            try std.testing.expect(state.reserves[0] == null);
            try std.testing.expectEqual(@as(u8, 3), state.field_state.progress.story.scenario.?.scenario[1]);
        }
    }
}

test "journey bundle keeps borrowed content and retained allocator valid after moving owner" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const io = std.testing.io;
    try fixtures(io, temp.dir);
    var diagnostic: content.Diagnostic = .{};
    try temp.dir.writeFile(io, .{ .sub_path = "battle/spells.json", .data = @embedFile("fixtures/spell_scene_library.json") });
    var first = try content.Bundle.load(std.testing.allocator, io, temp.dir, &diagnostic);
    const allocator = first.allocator();
    var moved = first;
    first = undefined;
    defer moved.deinit();
    const bytes = try allocator.dupe(u8, "retained allocator after move");
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings("retained allocator after move", bytes);
    var members: [6]battle.Member = undefined;
    var boot_combat: battle.State = undefined;
    var combat_backing: battle.State = undefined;
    var state = try journey.State.initEpisode(moved.package, moved.data, moved.combat, moved.items, moved.inn, &members, &combat_backing);
    state.bind();
    try state.combat.content.validate();
    try state.data.validate(state.package, state.combat.content);
    _ = try journey.Snapshot.capture(state);
    var boot = @import("journey_boot").Boot{
        .allocator = std.testing.allocator,
        .path = @constCast(""),
        .save_path = null,
        .bundle = moved,
        .party = null,
        .members = &members,
        .combat = &boot_combat,
        .state = undefined,
    };
    var fresh = try boot.newState();
    try std.testing.expect(moved.battle_host != null);
    try std.testing.expect(fresh.combat.integrationHost() == moved.battle_host);
    try std.testing.expect(fresh.combat.spell_scenes == moved.spell_scenes);
    try std.testing.expect(fresh.combat.spell_scenes.?.indexOf("spell_1") != null);
    const snapshot = try journey.Snapshot.capture(fresh);
    try std.testing.expectEqualStrings("suikoden-journey-save/43", snapshot.schema);
    try snapshot.apply(&fresh);
    try journey.save(io, std.testing.allocator, temp.dir, fresh);
    const saved = try temp.dir.readFileAlloc(io, "journey-slot.json", std.testing.allocator, .limited(256 * 1024));
    defer std.testing.allocator.free(saved);
    const decoded = try journey.decodeSnapshot(std.testing.allocator, saved, fresh);
    defer decoded.deinit();
    try decoded.value.apply(&fresh);
    try std.testing.expect(fresh.combat.spell_scenes == moved.spell_scenes);
    var wrong = snapshot;
    wrong.spell_scene_hash.?[0] ^= 1;
    try std.testing.expectError(error.SpellSceneContentMismatch, wrong.apply(&fresh));
    fresh.combat.spell_scenes = null;
    try std.testing.expectError(error.SpellSceneContentMismatch, snapshot.apply(&fresh));
    try std.testing.expectError(error.SpellSceneContentMismatch, journey.save(io, std.testing.allocator, temp.dir, fresh));
    const retained = try temp.dir.readFileAlloc(io, "journey-slot.json", std.testing.allocator, .limited(256 * 1024));
    defer std.testing.allocator.free(retained);
    try std.testing.expectEqualStrings(saved, retained);
    fresh.combat.spell_scenes = moved.spell_scenes;
    try std.testing.expect(fresh.combat.integrationHost() == moved.battle_host);
    try std.testing.expect(diagnostic.cause == null);
}

test "journey bundle preserves filename and original read and parse errors" {
    var missing = std.testing.tmpDir(.{});
    defer missing.cleanup();
    const io = std.testing.io;
    var diagnostic: content.Diagnostic = .{};
    try std.testing.expectError(error.FileNotFound, content.Bundle.load(std.testing.allocator, io, missing.dir, &diagnostic));
    try std.testing.expectEqualStrings("room.json", diagnostic.path);
    try std.testing.expectEqual(error.FileNotFound, diagnostic.cause.?);
    try missing.dir.writeFile(io, .{ .sub_path = "room.json", .data = @embedFile("fixtures/journey_room.json") });
    try missing.dir.createDir(io, "battle", .default_dir);
    try std.testing.expectError(error.FileNotFound, content.Bundle.load(std.testing.allocator, io, missing.dir, &diagnostic));
    try std.testing.expectEqualStrings("battle/trial.json", diagnostic.path);
    try missing.dir.writeFile(io, .{ .sub_path = "battle/trial.json", .data = @embedFile("fixtures/journey_battle.json") });
    try std.testing.expectError(error.FileNotFound, content.Bundle.load(std.testing.allocator, io, missing.dir, &diagnostic));
    try std.testing.expectEqualStrings("journey.json", diagnostic.path);
    try missing.dir.writeFile(io, .{ .sub_path = "journey.json", .data = "{}" });
    try std.testing.expectError(error.MissingField, content.Bundle.load(std.testing.allocator, io, missing.dir, &diagnostic));
    try std.testing.expectEqualStrings("journey.json", diagnostic.path);
    try std.testing.expectEqual(error.MissingField, diagnostic.cause.?);
}

test "journey content check finds missing knockout bindings for encounter targets" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const io = std.testing.io;
    try fixtures(io, temp.dir);
    var diagnostic: content.Diagnostic = .{};
    var bundle = try content.Bundle.load(std.testing.allocator, io, temp.dir, &diagnostic);
    defer bundle.deinit();
    try std.testing.expect(!bundle.missingStrikeKnockout("bonbon"));

    const combat = try battle.load(std.testing.allocator, @embedFile("fixtures/journey_unites_battle.json"));
    defer combat.deinit();
    const actors = try battle.actor_host.loadBundle(std.testing.allocator, @embedFile("fixtures/journey_unites_actor_library.json"));
    defer actors.deinit();
    const scenes = try battle.spell_scene.load(std.testing.allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer scenes.deinit();
    bundle.combat = combat.value;
    bundle.unite_actors = &actors.value;
    try std.testing.expect(bundle.missingStrikeKnockout("bonbon"));
    bundle.spell_scenes = &scenes.value;
    try std.testing.expect(!bundle.missingStrikeKnockout("bonbon"));
    try std.testing.expect(!bundle.missingStrikeKnockout("not_in_an_encounter"));
    for ([_][]const u8{ "creeper", "shadow_man", "mirage_f", "mirage_h" }) |enemy| {
        try std.testing.expect(bundle.missingStrikeKnockout(enemy));
    }

    var incomplete = scenes.value;
    var pose = incomplete.reactionPose("bonbon").?;
    pose.knockout = null;
    incomplete.hurt_poses = &.{pose};
    bundle.spell_scenes = &incomplete;
    try std.testing.expect(bundle.missingStrikeKnockout("bonbon"));
}

test "journey bundle preserves per-file limits and original validation errors" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const io = std.testing.io;
    try fixtures(io, temp.dir);
    var diagnostic: content.Diagnostic = .{};
    const cases = .{
        .{ "room.json", field.Package.max_file_size, @embedFile("fixtures/journey_room.json"), error.UnsupportedSchema },
        .{ "battle/trial.json", battle.Content.max_file_size, @embedFile("fixtures/journey_battle.json"), error.UnsupportedBattleSchema },
        .{ "journey.json", journey.Data.max_file_size, @embedFile("fixtures/journey.json"), error.InvalidJourney },
    };
    inline for (cases) |case| {
        {
            const file = try temp.dir.createFile(io, case[0], .{});
            defer file.close(io);
            try file.setLength(io, case[1] + 1);
        }
        try std.testing.expectError(error.StreamTooLong, content.Bundle.load(std.testing.allocator, io, temp.dir, &diagnostic));
        try std.testing.expectEqualStrings(case[0], diagnostic.path);
        try std.testing.expectEqual(error.StreamTooLong, diagnostic.cause.?);
        const document = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, case[2], .{});
        defer document.deinit();
        document.value.object.getPtr("schema").?.* = .{ .string = "unsupported" };
        const invalid = try std.json.Stringify.valueAlloc(std.testing.allocator, document.value, .{});
        defer std.testing.allocator.free(invalid);
        try temp.dir.writeFile(io, .{ .sub_path = case[0], .data = invalid });
        try std.testing.expectError(case[3], content.Bundle.load(std.testing.allocator, io, temp.dir, &diagnostic));
        try std.testing.expectEqualStrings(case[0], diagnostic.path);
        try std.testing.expectEqual(case[3], diagnostic.cause.?);
        try temp.dir.writeFile(io, .{ .sub_path = case[0], .data = case[2] });
    }
    const item_bytes: [256 * 1024 + 1]u8 = @splat(' ');
    try std.testing.expectError(error.ItemDataTooLarge, @import("field").items.load(std.testing.allocator, &item_bytes));
    const inn_bytes: [4097]u8 = @splat(' ');
    try std.testing.expectError(error.InnDataTooLarge, @import("field").inn.load(std.testing.allocator, &inn_bytes));
}

test "canonical package loads through the runtime bundle loader" {
    const io = std.testing.io;
    var directory = std.Io.Dir.cwd().openDir(io, "../kit/work/build/canonical", .{}) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer directory.close(io);
    var diagnostic: content.Diagnostic = .{};
    var bundle = try content.Bundle.load(std.testing.allocator, io, directory, &diagnostic);
    defer bundle.deinit();
    try std.testing.expectEqualStrings("vaa_room_2", bundle.package.start_room);
    try std.testing.expect(bundle.package.rooms.len >= 78);
    try std.testing.expect(bundle.data.encounters.len == 1);
    try std.testing.expectEqualStrings("world_patrol", bundle.data.encounters[0].id);
}

test "party content distinguishes missing and malformed files" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var diagnostic: @import("party_content").Diagnostic = .{};
    try std.testing.expectError(error.MissingPartyCatalogue, @import("party_content").load(std.testing.allocator, io, temp.dir, true, &diagnostic));
    try std.testing.expectEqualStrings("party/catalogue.json", diagnostic.path);
    try temp.dir.createDir(io, "party", .default_dir);
    try temp.dir.writeFile(io, .{ .sub_path = "party/catalogue.json", .data = "{}" });
    try std.testing.expectError(error.MissingPartyBindings, @import("party_content").load(std.testing.allocator, io, temp.dir, true, &diagnostic));
    try std.testing.expectEqualStrings("party/ownership_bindings.json", diagnostic.path);
    try std.testing.expect((try @import("party_content").load(std.testing.allocator, io, temp.dir, false, &diagnostic)) == null);
}

test "ZON nested string slices survive parsing and copying" {
    const Nested = struct {
        groups: []const struct { names: []const []const u8 },
    };
    const source_text = ".{ .groups = .{ .{ .names = .{ \"alpha\", \"beta\" } }, .{ .names = .{ \"gamma\" } } } }";
    const source = try std.testing.allocator.dupeSentinel(u8, source_text, 0);
    defer std.testing.allocator.free(source);
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = try std.zon.parse.fromSlice(Nested, .{
        .gpa = std.testing.allocator,
        .arena = arena.allocator(),
        .source = source,
        .diagnostics = &diagnostics,
    });
    try std.testing.expectEqual(@as(usize, 2), value.groups.len);
    try std.testing.expectEqualStrings("alpha", value.groups[0].names[0]);
    try std.testing.expectEqualStrings("gamma", value.groups[1].names[0]);
}

test "malformed optional spell library fails with its filename" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const io = std.testing.io;
    try fixtures(io, temp.dir);
    try temp.dir.writeFile(io, .{ .sub_path = "battle/spells.json", .data = "{}" });
    var diagnostic: content.Diagnostic = .{};
    try std.testing.expectError(error.MissingField, content.Bundle.load(std.testing.allocator, io, temp.dir, &diagnostic));
    try std.testing.expectEqualStrings("battle/spells.json", diagnostic.path);
}

test "journey Unite bundle reaches new battle state and saves refuse changed content" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const io = std.testing.io;
    try fixtures(io, temp.dir);
    try temp.dir.writeFile(io, .{ .sub_path = "battle/unites.json", .data = @embedFile("fixtures/battle_actor_library.json") });
    var diagnostic: content.Diagnostic = .{};
    var bundle = try content.Bundle.load(std.testing.allocator, io, temp.dir, &diagnostic);
    defer bundle.deinit();
    var members: [6]battle.Member = undefined;
    var boot_combat: battle.State = undefined;
    var boot = @import("journey_boot").Boot{ .allocator = std.testing.allocator, .path = @constCast(""), .save_path = null, .bundle = bundle, .party = null, .members = &members, .combat = &boot_combat, .state = undefined };
    var fresh = try boot.newState();
    try std.testing.expect(fresh.combat.unite_actors == bundle.unite_actors);
    try std.testing.expectEqual(@as(usize, 32), fresh.combat.unite_actors.?.unites.len);
    const snapshot = try journey.Snapshot.capture(fresh);
    try std.testing.expectEqualStrings("suikoden-journey-save/43", snapshot.schema);
    try std.testing.expect(snapshot.spell_scene_hash == null and snapshot.unite_actor_hash != null);
    try journey.save(io, std.testing.allocator, temp.dir, fresh);
    const saved = try temp.dir.readFileAlloc(io, "journey-slot.json", std.testing.allocator, .limited(256 * 1024));
    defer std.testing.allocator.free(saved);
    const decoded = try journey.decodeSnapshot(std.testing.allocator, saved, fresh);
    defer decoded.deinit();
    try decoded.value.apply(&fresh);
    try std.testing.expect(fresh.combat.unite_actors == bundle.unite_actors);
    var wrong = snapshot;
    wrong.unite_actor_hash.?[0] ^= 1;
    try std.testing.expectError(error.UniteActorContentMismatch, wrong.apply(&fresh));
    fresh.combat.unite_actors = null;
    try std.testing.expectError(error.UniteActorContentMismatch, snapshot.apply(&fresh));
    try std.testing.expectError(error.UniteActorContentMismatch, journey.save(io, std.testing.allocator, temp.dir, fresh));
    const retained = try temp.dir.readFileAlloc(io, "journey-slot.json", std.testing.allocator, .limited(256 * 1024));
    defer std.testing.allocator.free(retained);
    try std.testing.expectEqualStrings(saved, retained);
    try std.testing.expect(diagnostic.cause == null);
}

test "journey bundle reports malformed Unite content at its source filename" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const io = std.testing.io;
    try fixtures(io, temp.dir);
    try temp.dir.writeFile(io, .{ .sub_path = "battle/unites.json", .data = "{}" });
    var diagnostic: content.Diagnostic = .{};
    try std.testing.expectError(error.MissingField, content.Bundle.load(std.testing.allocator, io, temp.dir, &diagnostic));
    try std.testing.expectEqualStrings("battle/unites.json", diagnostic.path);
}

test "duel atlas clips bind to the loaded exchange clock and reject the authored preview" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const presentation = content.duel_presentation;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try fixtures(io, temp.dir);
    try temp.dir.createDir(io, "duel", .default_dir);

    const rules = try journey.duel.load(allocator, journey.duel.content_json);
    defer rules.deinit();
    const tile: field.Rect = .{ .x = 0, .y = 0, .w = 1, .h = 1 };
    const idle: [2]presentation.Frame = .{
        .{ .rect = tile, .ticks = 2, .x = 0, .y = 0 },
        .{ .rect = tile, .ticks = 1, .x = 1, .y = 0 },
    };
    var scenes: [3]presentation.Scene = undefined;
    var exchanges: [3][9]presentation.Exchange = undefined;
    var exchanges_frames: [3][9][2]presentation.Frame = undefined;
    var defeats: [3][2]presentation.Frame = undefined;
    for (rules.value.duels, &scenes, &exchanges, &exchanges_frames, &defeats) |match, *scene, *paired, *frames, *fall| {
        for (match.exchanges, paired, frames) |script, *pair, *poses| {
            poses.* = .{ idle[0], idle[1] };
            poses[0].ticks = 1;
            poses[1].ticks = @intCast(script.updates - 1);
            pair.* = .{ .id = script.id, .clips = .{ poses, poses } };
        }
        for (match.fighters, fall) |fighter, *pose| {
            pose.* = .{ .rect = tile, .ticks = @intCast(fighter.defeat_updates), .x = 2, .y = 0 };
        }
        scene.* = .{ .id = match.id, .backdrop = tile, .idle = .{ &idle, &idle }, .defeat = .{ fall[0..1], fall[1..2] }, .exchanges = paired };
    }
    const atlas_bytes = "atlas fixture";
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(atlas_bytes, &digest, .{});
    const hash = std.fmt.bytesToHex(digest, .lower);
    const packet: presentation.Packet = .{ .schema = "suikoden-duel-presentation/1", .atlas_sha256 = &hash, .scenes = &scenes, .art_origin = presentation.extracted_origin };
    var preview = packet;
    preview.art_origin = "authored-duel-art/1";
    try std.testing.expectError(error.AuthoredDuelPreview, preview.validate(rules.value));
    preview.art_origin = null;
    try std.testing.expectError(error.UnverifiedDuelArt, preview.validate(rules.value));
    const bytes = try std.json.Stringify.valueAlloc(allocator, packet, .{});
    defer allocator.free(bytes);
    try temp.dir.writeFile(io, .{ .sub_path = presentation.path, .data = bytes });
    try temp.dir.writeFile(io, .{ .sub_path = presentation.atlas_path, .data = "changed bytes" });
    var diagnostic: content.Diagnostic = .{};
    try std.testing.expectError(error.DuelAtlasMismatch, content.Bundle.load(allocator, io, temp.dir, &diagnostic));
    try temp.dir.writeFile(io, .{ .sub_path = presentation.atlas_path, .data = atlas_bytes });
    var loaded = try content.Bundle.load(allocator, io, temp.dir, &diagnostic);
    defer loaded.deinit();
    try loaded.duel_art.?.validateAtlas(1, 1);
    try std.testing.expectError(error.InvalidDuelAtlas, loaded.duel_art.?.validateAtlas(0, 1));
    scenes[0].gauges = .{ .{ .x = 0, .y = 0, .w = 128, .h = 32 }, .{ .x = 128, .y = 0, .w = 128, .h = 32 } };
    try packet.validateAtlas(256, 32);
    try std.testing.expectError(error.InvalidDuelAtlas, packet.validateAtlas(255, 32));

    const fighters: [2]journey.duel.FighterState = @splat(.{ .maximum_hp = 50, .hp = 50, .attack = 20, .defense = 10 });
    var state = try journey.duel.State.init(&rules.value, scenes[0].id, fighters, .{ .values = &.{ 0, 0, 0 } });
    const art = loaded.duel_art.?.scene(state.duel.id).?;
    try std.testing.expectEqual(@as(i32, 1), art.frame(state, .player, 2).x);
    try std.testing.expectEqual(@as(i32, 0), art.frame(state, .player, 3).x);
    try state.choose(.attack);
    try std.testing.expectEqual(@as(i32, 0), art.frame(state, .opponent, 100).x);
    try state.tick();
    try std.testing.expectEqual(@as(i32, 0), art.frame(state, .opponent, 100).x);
    try state.tick();
    try std.testing.expectEqual(@as(i32, 1), art.frame(state, .opponent, 100).x);

    exchanges_frames[0][0][1].ticks -= 1;
    try std.testing.expectError(error.InvalidDuelClip, packet.validate(rules.value));
}

test "journey duel mode lifecycle returns cleanly to field" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const io = std.testing.io;
    try fixtures(io, temp.dir);
    var diagnostic: content.Diagnostic = .{};
    var loaded = try content.Bundle.load(std.testing.allocator, io, temp.dir, &diagnostic);
    defer loaded.deinit();
    var members: [6]battle.Member = undefined;
    var boot_combat: battle.State = undefined;
    var boot: @import("journey_boot").Boot = .{
        .allocator = std.testing.allocator,
        .path = @constCast(""),
        .save_path = null,
        .bundle = loaded,
        .party = null,
        .members = &members,
        .combat = &boot_combat,
        .state = undefined,
    };
    var state = try boot.newState();
    defer state.releaseRestoredSave();

    const profiles = [2]journey.duel.FighterState{
        .{ .maximum_hp = 1000, .hp = 1000, .attack = 500, .defense = 80 },
        .{ .maximum_hp = 10, .hp = 10, .attack = 20, .defense = 10 },
    };
    const rolls = [_]u15{ 0, 0, 0, 0, 0, 0, 0, 0 };
    try state.startDuel(std.testing.allocator, "pahn_teo", profiles, .{ .values = &rolls });
    try std.testing.expectEqual(journey.Mode.duel, state.mode);
    try std.testing.expect(state.active_duel != null);
    try state.tickDuel(false, true, false);
    try state.tickDuel(true, false, false);
    try state.chooseDuelCommand(.desperate_attack);
    var ticks: usize = 0;
    while (state.mode == .duel and ticks < 2000) : (ticks += 1) {
        const confirm = if (state.active_duel) |active| active.state.phase == .finished or active.state.phase == .choosing else false;
        try state.tickDuel(false, false, confirm);
    }
    try std.testing.expectEqual(journey.Mode.field, state.mode);
    try std.testing.expect(state.active_duel == null);
}

test "journey war mode lifecycle initializes and resolves" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const io = std.testing.io;
    try fixtures(io, temp.dir);
    const war_bytes = try std.Io.Dir.cwd().readFileAlloc(io, "assets/war/scenarios.json", std.testing.allocator, .limited(4 * 1024 * 1024));
    defer std.testing.allocator.free(war_bytes);
    const war_packet = try journey.war.load(std.testing.allocator, war_bytes);
    defer war_packet.deinit();
    var diagnostic: content.Diagnostic = .{};
    var loaded = try content.Bundle.load(std.testing.allocator, io, temp.dir, &diagnostic);
    defer loaded.deinit();
    var members: [6]battle.Member = undefined;
    var boot_combat: battle.State = undefined;
    var boot: @import("journey_boot").Boot = .{
        .allocator = std.testing.allocator,
        .path = @constCast(""),
        .save_path = null,
        .bundle = loaded,
        .party = null,
        .members = &members,
        .combat = &boot_combat,
        .state = undefined,
    };
    var state = try boot.newState();
    defer state.releaseRestoredSave();

    const scenario = war_packet.value.scenarios[2];
    try state.startWar(std.testing.allocator, .{ .scenario = scenario, .rng = .{ .state = 1 } });
    try std.testing.expectEqual(journey.Mode.war, state.mode);
    try std.testing.expect(state.active_war != null);
    var ticks: usize = 0;
    while (state.mode == .war and ticks < 4000) : (ticks += 1) {
        const active = &(state.active_war orelse break);
        const confirm = switch (active.session.engine.phase) {
            .scripted => if (active.session.engine.script) |script| script.phase == scenario.lifecycle.wait_phase else false,
            .result => true,
            else => false,
        };
        try state.tickWar(.{ .confirm = confirm });
    }
    try std.testing.expectEqual(journey.Mode.field, state.mode);
    try std.testing.expect(state.active_war == null);
}

test "journey startWarById resolves embedded war scenario cleanly" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const io = std.testing.io;
    try fixtures(io, temp.dir);
    var diagnostic: content.Diagnostic = .{};
    var loaded = try content.Bundle.load(std.testing.allocator, io, temp.dir, &diagnostic);
    defer loaded.deinit();
    var members: [6]battle.Member = undefined;
    var boot_combat: battle.State = undefined;
    var boot: @import("journey_boot").Boot = .{
        .allocator = std.testing.allocator,
        .path = @constCast(""),
        .save_path = null,
        .bundle = loaded,
        .party = null,
        .members = &members,
        .combat = &boot_combat,
        .state = undefined,
    };
    var state = try boot.newState();
    defer state.releaseRestoredSave();

    try state.startWarById(std.testing.allocator, "scarleticia_pollen", 1);
    try std.testing.expectEqual(journey.Mode.war, state.mode);
    try std.testing.expect(state.active_war != null);
    try std.testing.expectEqualStrings("scarleticia_pollen", state.active_war.?.session.engine.scenario.id);
    const wait_phase = state.active_war.?.session.engine.scenario.lifecycle.wait_phase;
    var ticks: usize = 0;
    while (state.mode == .war and ticks < 4000) : (ticks += 1) {
        const active = &(state.active_war orelse break);
        const confirm = switch (active.session.engine.phase) {
            .scripted => if (active.session.engine.script) |script| script.phase == wait_phase else false,
            .result => true,
            else => false,
        };
        try state.tickWar(.{ .confirm = confirm });
    }
    try std.testing.expectEqual(journey.Mode.field, state.mode);
    try std.testing.expect(state.active_war == null);
}

test "journey startDuelById dispatches all three canonical duels" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const io = std.testing.io;
    try fixtures(io, temp.dir);
    var diagnostic: content.Diagnostic = .{};
    var loaded = try content.Bundle.load(std.testing.allocator, io, temp.dir, &diagnostic);
    defer loaded.deinit();
    var members: [6]battle.Member = undefined;
    var boot_combat: battle.State = undefined;
    var boot: @import("journey_boot").Boot = .{
        .allocator = std.testing.allocator,
        .path = @constCast(""),
        .save_path = null,
        .bundle = loaded,
        .party = null,
        .members = &members,
        .combat = &boot_combat,
        .state = undefined,
    };
    var state = try boot.newState();
    defer state.releaseRestoredSave();

    const cases = .{
        .{ "shu_kwanda", 280, 280, 150, 75 },
        .{ "pahn_teo", 370, 370, 290, 150 },
        .{ "shu_teo", 360, 180, 240, 105 },
    };
    inline for (cases) |case| {
        try state.startDuelById(std.testing.allocator, case[0]);
        try std.testing.expectEqual(journey.Mode.duel, state.mode);
        try std.testing.expectEqualStrings(case[0], state.active_duel.?.state.duel.id);
        const opponent = state.active_duel.?.state.fighters[1];
        try std.testing.expectEqual(case[1], opponent.maximum_hp);
        try std.testing.expectEqual(case[2], opponent.hp);
        try std.testing.expectEqual(case[3], opponent.attack);
        try std.testing.expectEqual(case[4], opponent.defense);
        try std.testing.expectEqual(.duel, state.audioScene());
        state.deinitActiveModes();
        state.mode = .field;
    }
}

test "journey ending mode initializes and advances through epilogue cleanly" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const io = std.testing.io;
    try fixtures(io, temp.dir);
    var diagnostic: content.Diagnostic = .{};
    var loaded = try content.Bundle.load(std.testing.allocator, io, temp.dir, &diagnostic);
    defer loaded.deinit();
    var members: [6]battle.Member = undefined;
    var boot_combat: battle.State = undefined;
    var boot: @import("journey_boot").Boot = .{
        .allocator = std.testing.allocator,
        .path = @constCast(""),
        .save_path = null,
        .bundle = loaded,
        .party = null,
        .members = &members,
        .combat = &boot_combat,
        .state = undefined,
    };
    var state = try boot.newState();
    defer state.releaseRestoredSave();

    try state.startEnding(std.testing.allocator);
    try std.testing.expectEqual(journey.Mode.ending, state.mode);
    try std.testing.expect(state.active_ending != null);
    try std.testing.expectEqual(.ending, state.audioScene());
    const phases = state.active_ending.?.parsed.value.bounded_ending.main_ending_phases;
    for (0..phases) |_| try state.tickEnding(false, false, true);
    try std.testing.expectEqual(phases, state.active_ending.?.phase_index);
    try state.tickEnding(false, true, false);
    try std.testing.expectEqual(@as(u16, 1), state.active_ending.?.entry_cursor);
    try state.tickEnding(true, false, false);
    try std.testing.expectEqual(@as(u16, 0), state.active_ending.?.entry_cursor);
    try state.tickEnding(false, false, true);
    try std.testing.expectEqual(journey.Mode.field, state.mode);
    try std.testing.expect(state.active_ending == null);
}

test "BattleRooms.schema_versions.parseSchemaVersion parses numbered and current schemas" {
    const schema_mod = content.BattleRooms.schema_versions;
    try std.testing.expectEqual(@as(?u8, 1), schema_mod.parseVersion(content.BattleRooms.legacy_schema));
    try std.testing.expectEqual(@as(?u8, 19), schema_mod.parseVersion(content.BattleRooms.campaign_schema));
    try std.testing.expectEqual(@as(?u8, 52), schema_mod.parseVersion(content.BattleRooms.scenery_mutation_schema));
    try std.testing.expectEqual(@as(?u8, 53), schema_mod.parseVersion(content.BattleRooms.current_schema));
    try std.testing.expectEqual(@as(?u8, null), schema_mod.parseVersion("suikoden-battle-field-events/0"));
    try std.testing.expectEqual(@as(?u8, null), schema_mod.parseVersion("suikoden-battle-field-events/01"));
    try std.testing.expectEqual(@as(?u8, null), schema_mod.parseVersion("suikoden-battle-field-events/53"));
    try std.testing.expectEqual(@as(?u8, null), schema_mod.parseVersion("bad"));
}

const SimulationAudio = struct {
    polls: usize = 0,
    ready: bool = false,

    pub fn pollFieldMusic(self: *@This(), track: anytype) !bool {
        try std.testing.expectEqual(.area_b, track);
        self.polls += 1;
        return self.ready;
    }

    pub fn requestFieldFade(_: *@This()) void {
        unreachable;
    }

    pub fn requestDiceMusic(_: *@This(), _: anytype) !void {
        return error.UnexpectedDiceMusic;
    }
};

test "production simulation frame hands dialogue to party selection and acknowledges each modal once" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try fixtures(io, temp.dir);
    try writeFieldBattle(io, temp.dir, "", .modal);
    var window: [9]ui_font.WindowPiece = undefined;
    const font = try std.json.Stringify.valueAlloc(allocator, dialogueFont(&window), .{});
    defer allocator.free(font);
    try temp.dir.writeFile(io, .{ .sub_path = "ui.json", .data = font });
    try temp.dir.createDirPath(io, "audio/sfx");
    try temp.dir.writeFile(io, .{
        .sub_path = "audio/sfx/battle_sfx.json",
        .data =
        \\{"schema":"suikoden-battle-sfx/1","sample_rate":44100,"cues":[{"id":1281,"path":"0501.wav","frames":1,"sha256":"0000000000000000000000000000000000000000000000000000000000000000","bank":0,"program":0,"note":60,"retrigger":false}]}
        ,
    });
    const wave = "RIFF\x28\x00\x00\x00WAVEfmt \x10\x00\x00\x00\x01\x00\x02\x00" ++
        "\x44\xac\x00\x00\x10\xb1\x02\x00\x04\x00\x10\x00data\x04\x00\x00\x00\x00\x00\x00\x00";
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(wave, &digest, .{});
    const hash = std.fmt.bytesToHex(digest, .lower);
    const audio_route = @import("audio_route");
    var streams: [3]audio_route.StreamTrack = undefined;
    for (&streams, [_]audio_route.Track{ .area_b, .ruins, .lakeshore }, [_][]const u8{ "area_b.wav", "ruins.wav", "lakeshore.wav" }) |*stream, id, path| {
        stream.* = .{ .id = id, .path = path, .sample_rate = 44100, .frames = 1, .loop_start_frame = 0, .volume = 0, .sha256 = &hash };
        var buffer: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&buffer, "audio/{s}", .{path});
        try temp.dir.writeFile(io, .{ .sub_path = name, .data = wave });
    }
    const audio_manifest: audio_route.FieldContent = .{ .schema = "suikoden-field-audio/1", .tracks = &streams };
    const manifest = try std.json.Stringify.valueAlloc(allocator, audio_manifest, .{});
    defer allocator.free(manifest);
    try temp.dir.writeFile(io, .{ .sub_path = "audio/field.json", .data = manifest });
    var diagnostic: content.Diagnostic = .{};
    var bundle = try content.Bundle.load(allocator, io, temp.dir, &diagnostic);
    defer bundle.deinit();

    const catalogue = @import("party_session").catalogue;
    const roster_bytes = @import("party_data").json;
    const catalog = try catalogue.decode(allocator, roster_bytes);
    defer catalog.deinit();
    const bindings = try catalogue.decodeBindings(allocator, @embedFile("party_session/ownership_bindings.json"), roster_bytes);
    defer bindings.deinit();
    var members: [6]battle.Member = undefined;
    var combat: battle.State = undefined;
    var boot = @import("journey_boot").Boot{
        .allocator = allocator,
        .path = @constCast(""),
        .save_path = null,
        .bundle = bundle,
        .party = .{ .catalog = catalog, .bindings = bindings },
        .members = &members,
        .combat = &combat,
        .state = undefined,
    };
    var state = try boot.newState();
    state.field_state.auxiliary_party = @splat(0xff);
    var audio: SimulationAudio = .{};

    for (0..state.package.step_ticks) |_| _ = try frame.stepWithAudio(&state, .{ .menu = .{ .field = .{ .direction = .right } } }, &audio);
    const event = state.field_event orelse return error.MissingFieldEvent;
    const session = event.session;
    var saw_dialogue = false;
    for (0..128) |_| {
        saw_dialogue = saw_dialogue or session.boxes[0].phase != .closed;
        _ = try frame.stepWithAudio(&state, .{
            .menu = .{ .field = .{ .action = true } },
            .party = .{ .repeated = .{ .cancel = true } },
        }, &audio);
        if (state.party_selection != null) break;
    } else return error.MissingPartySelection;
    try std.testing.expect(saw_dialogue);
    try std.testing.expectEqual(.main_creation, state.party_selection.?.menu.phase);
    const party_receipt = session.queuedPartySelect().?;
    const party_pc = session.instance.?.execution.pc;
    const party_resume_pc = session.instance.?.pending.?.next.pc;
    const held_position = state.field_state.destination;

    for (0..128) |_| {
        if (state.party_selection.?.menu.phase == .main) break;
        _ = try frame.stepWithAudio(&state, .{}, &audio);
    } else return error.PartySelectionDidNotOpen;
    _ = try frame.stepWithAudio(&state, .{
        .menu = .{ .field = .{ .action = true, .direction = .right } },
        .party = .{ .repeated = .{ .cancel = true } },
    }, &audio);
    try std.testing.expect(state.party_selection != null);
    try std.testing.expectEqualDeep(party_receipt, session.queuedPartySelect().?);
    try std.testing.expectEqual(party_pc, session.instance.?.execution.pc);
    for (0..128) |_| {
        if (state.party_selection == null) break;
        _ = try frame.stepWithAudio(&state, .{}, &audio);
    } else return error.PartySelectionDidNotClose;
    try std.testing.expectEqualDeep(party_receipt, session.receipt.?);
    try std.testing.expectEqual(party_resume_pc, session.instance.?.execution.pc);
    try std.testing.expectEqual(held_position, state.field_state.destination);
    try std.testing.expect(session.queuedPartySelect() == null and state.pendingFieldMusic() == null);
    try std.testing.expectError(error.InvalidFieldPartySelectReceipt, session.resumePartySelect(event.binding.*, &state.field_state, party_receipt));

    state.menu.pending_sound = 0x501;
    const issuing = try frame.stepWithAudio(&state, .{}, &audio);
    try std.testing.expect(issuing.field_music == null);
    try std.testing.expectEqual(@as(?u16, 0x501), issuing.sounds.field);
    try std.testing.expectEqual(.area_b, state.pendingFieldMusic().?);
    try std.testing.expectEqual(@as(usize, 0), audio.polls);
    const music_pc = session.instance.?.execution.pc;
    const music_batch = session.instance.?.pending.?.batch.id;
    const music_resume_pc = session.instance.?.pending.?.next.pc;

    var teleport: journey.travel.teleport.Session = undefined;
    teleport.phase = .selecting;
    teleport.entry.entry_id = "modal_priority_test";
    teleport.entry.receipt = 1;
    teleport.settled = 0;
    state.teleport_session = teleport;
    audio.ready = true;
    const teleport_step = try frame.stepWithAudio(&state, .{ .menu = .{ .field = .{ .cancel = true } } }, &audio);
    try std.testing.expect(teleport_step.field_music == null);
    try std.testing.expect(state.teleport_session == null);
    try std.testing.expectEqual(@as(usize, 0), audio.polls);
    try std.testing.expectEqual(music_pc, session.instance.?.execution.pc);
    try std.testing.expectEqual(music_batch, session.instance.?.pending.?.batch.id);

    audio.ready = false;
    const waiting = try frame.stepWithAudio(&state, .{}, &audio);
    try std.testing.expectEqual(.area_b, waiting.field_music.?);
    try std.testing.expect(waiting.sounds.field == null);
    try std.testing.expectEqual(@as(usize, 1), audio.polls);
    try std.testing.expectEqual(music_pc, session.instance.?.execution.pc);
    try std.testing.expectEqual(music_batch, session.instance.?.pending.?.batch.id);
    audio.ready = true;
    _ = try frame.stepWithAudio(&state, .{}, &audio);
    try std.testing.expectEqual(@as(usize, 2), audio.polls);
    try std.testing.expectEqual(music_batch, session.receipt.?.batch);
    try std.testing.expectEqual(music_resume_pc, session.instance.?.execution.pc);
    try std.testing.expectEqual(.area_b, state.field_state.music.?);
    try std.testing.expectEqual(@as(u8, 4), state.progress().story.scenario.?.scenario[1]);
    try std.testing.expectError(error.InvalidFieldMusicReceipt, state.completeFieldMusic(.area_b));
    _ = try frame.stepWithAudio(&state, .{}, &audio);
    try std.testing.expectEqual(@as(usize, 2), audio.polls);
    try std.testing.expectEqual(@as(u8, 0x24), state.progress().story.scenario.?.scenario[1]);
}

test "field event compatibility preserves versioned restoration, world context, and pending effects" {
    const event_host = @import("field_events");
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try fixtures(io, temp.dir);
    try writeFieldBattle(io, temp.dir, "area_a_1", .silent);
    var diagnostic: content.Diagnostic = .{};
    var bundle = try content.Bundle.load(allocator, io, temp.dir, &diagnostic);
    defer bundle.deinit();

    const template = bundle.room_battles.?.bindingFor("vb6_inn").?;
    const session = try allocator.create(event_host.Session);
    defer allocator.destroy(session);
    const resumed = try allocator.create(event_host.Session);
    defer allocator.destroy(resumed);
    var members: [6]battle.Member = undefined;
    var combat: battle.State = undefined;
    var boot = @import("journey_boot").Boot{
        .allocator = allocator,
        .path = @constCast(""),
        .save_path = null,
        .bundle = bundle,
        .party = null,
        .members = &members,
        .combat = &combat,
        .state = undefined,
    };

    const full_restore: []const runtime.Command = &.{ .{ .kind = .party_restore }, .{ .kind = .end_stream } };
    const hp_restore: []const runtime.Command = &.{ .{ .kind = .party_restore, .hp_only = true }, .{ .kind = .end_stream } };
    const static_world: []const runtime.Command = &.{.{ .kind = .world_transition, .destination = "world_a", .x = 20, .y = 25 }};
    const retained_world: []const runtime.Command = &.{.{ .kind = .world_transition, .retain_world_region = true, .x = 20, .y = 25 }};
    const return_world: []const runtime.Command = &.{.{ .kind = .world_transition, .return_to_entry = true }};
    const effect: []const runtime.Command = &.{
        .{ .kind = .field_effect, .x = 256, .y = 208, .effect = .appearance },
        .{ .kind = .wait_field_effect },
        .{ .kind = .end_stream },
    };
    const Case = struct { schema: []const u8, commands: []const runtime.Command, outcome: enum { full, hp, rejected, static_world, retained_world, return_world, effect } };
    for ([_]Case{
        .{ .schema = runtime.campaign_schema, .commands = full_restore, .outcome = .full },
        .{ .schema = runtime.scene_schema, .commands = full_restore, .outcome = .rejected },
        .{ .schema = runtime.field_effect_schema, .commands = hp_restore, .outcome = .hp },
        .{ .schema = runtime.branch_history_schema, .commands = static_world, .outcome = .static_world },
        .{ .schema = runtime.branch_history_schema, .commands = retained_world, .outcome = .rejected },
        .{ .schema = runtime.world_entry_schema, .commands = retained_world, .outcome = .retained_world },
        .{ .schema = runtime.branch_history_schema, .commands = return_world, .outcome = .rejected },
        .{ .schema = runtime.world_entry_schema, .commands = return_world, .outcome = .return_world },
        .{ .schema = runtime.field_effect_schema, .commands = effect, .outcome = .effect },
    }) |case| {
        var state = try boot.newState();
        state.field_state.enterRoom(state.package.roomIndex("vb6_inn").?, .{ .x = 256, .y = 208 });
        var binding = template;
        var package = state.package;
        if (case.outcome == .return_world) package.world_entries = &.{
            .{ .id = "test_gate", .world_room = "world_a", .point = 3, .area = "vb6", .return_x = 168, .return_y = 216 },
        };
        binding.room_package = package;
        binding.scripted_motion = case.outcome == .effect;
        const host = state.combat.integrationHost() orelse return error.MissingBattleIntegration;
        var party_ids: [6]u8 = undefined;
        for (&party_ids, members) |*id, member| id.* = host.characterId(member.id) orelse return error.UnknownFieldEventPartyMember;
        binding.party = &party_ids;
        var programs = [_]runtime.Program{binding.content.programs[0]};
        programs[0].commands = case.commands;
        binding.content.schema = case.schema;
        binding.content.programs = &programs;
        var references = [_]@TypeOf(binding.population.programs[0]){binding.population.programs[0]};
        references[0].namespace = case.schema;
        binding.population.schema = "suikoden-scene-population/3";
        binding.population.programs = &references;
        const field_state = &state.field_state;
        if (case.outcome == .rejected) {
            try std.testing.expectError(error.InvalidEventCommand, session.beginOrdinary(binding, field_state.*, 1, null));
            continue;
        }
        field_state.progress.story.scenario = try runtime.StoryState.init(&.{binding.content});
        try std.testing.expect(try session.beginOrdinary(binding, field_state.*, 1, null));
        switch (case.outcome) {
            .full, .hp => {
                members[0].hp = 1;
                members[0].status = .poisoned;
                members[0].balloons = 2;
                members[0].max_rune_charges[0] = 3;
                members[0].rune_charges[0] = 1;
                members[1].hp = 0;
                members[1].status = .unconscious;
                _ = try session.tick(binding, field_state, false);
                const full = case.outcome == .full;
                try std.testing.expectEqual(members[0].max_hp, members[0].hp);
                try std.testing.expectEqual(members[1].max_hp, members[1].hp);
                try std.testing.expectEqual(.healthy, members[1].status);
                const expected_status: field.game_state.Status = if (full) .healthy else .poisoned;
                try std.testing.expectEqual(expected_status, members[0].status);
                try std.testing.expectEqual(@as(u8, if (full) 0 else 2), members[0].balloons);
                try std.testing.expectEqual(@as(u16, if (full) 3 else 1), members[0].rune_charges[0]);
            },
            .static_world, .retained_world => {
                const world_room = state.package.roomIndex("world_a").?;
                if (case.outcome == .retained_world) {
                    const before = session.instance.?.execution.pc;
                    try std.testing.expectError(error.MissingWorldRegion, session.tick(binding, field_state, false));
                    try std.testing.expectEqual(before, session.instance.?.execution.pc);
                    try std.testing.expectEqualStrings("vb6_inn", state.package.rooms[field_state.room].id);
                    field_state.world_context = .{ .room = world_room };
                }
                _ = try session.tick(binding, field_state, false);
                try std.testing.expectEqual(world_room, field_state.room);
                try std.testing.expectEqual(field.Point{ .x = 160, .y = 200 }, field_state.destination);
                try std.testing.expect(field_state.crossed_world_exit);
            },
            .return_world => {
                const world_room = package.roomIndex("world_a").?;
                const old_entries = field_state.room_entries;
                const old_pc = session.instance.?.execution.pc;
                try std.testing.expectError(error.MissingWorldEntry, session.tick(binding, field_state, false));
                try std.testing.expectEqual(old_entries, field_state.room_entries);
                try std.testing.expectEqual(old_pc, session.instance.?.execution.pc);
                field_state.setWorldEntry(package, "test_gate");
                _ = try session.tick(binding, field_state, false);
                try std.testing.expectEqual(world_room, field_state.room);
                try std.testing.expectEqual(field.Point{ .x = 168, .y = 216 }, field_state.destination);
                try std.testing.expect(field_state.crossed_world_exit);
                try std.testing.expectEqual(old_entries + 1, field_state.room_entries);
                try std.testing.expect(!session.instance.?.execution.active);
            },
            .effect => {
                const pending = (try runtime.step(binding.content, &session.instance.?, &field_state.progress.story.scenario.?, .{})).batch.?;
                try std.testing.expect(session.field_effect == null and session.receipt == null);
                const checkpoint = try event_host.Checkpoint.capture(session.*, field_state.*);
                const bytes = try std.json.Stringify.valueAlloc(allocator, checkpoint, .{});
                defer allocator.free(bytes);
                const decoded = try std.json.parseFromSlice(event_host.Checkpoint, allocator, bytes, .{ .allocate = .alloc_always });
                defer decoded.deinit();
                try decoded.value.apply(allocator, binding, resumed, field_state);
                try std.testing.expectEqual(pending.id, resumed.instance.?.pending.?.batch.id);
                try std.testing.expect(resumed.field_effect == null and resumed.receipt == null);
                _ = try resumed.tick(binding, field_state, false);
                const receipt = resumed.receipt.?;
                try std.testing.expectEqual(pending.id, receipt.batch);
                try std.testing.expectEqual(field.Point{ .x = 256, .y = 208 }, resumed.field_effect.?.position);
                try std.testing.expectEqual(@as(u8, 1), resumed.field_effect.?.model.clock.elapsed);
                for (2..86) |elapsed| {
                    _ = try resumed.tick(binding, field_state, false);
                    try std.testing.expectEqualDeep(receipt, resumed.receipt.?);
                    try std.testing.expectEqual(@as(u8, @intCast(elapsed)), resumed.field_effect.?.model.clock.elapsed);
                }
                for (0..4) |_| {
                    if (!resumed.busy()) break;
                    _ = try resumed.tick(binding, field_state, false);
                    try std.testing.expect(resumed.field_effect == null);
                }
                try std.testing.expect(!resumed.busy());
                try std.testing.expectEqual(pending.id + 1, resumed.receipt.?.batch);
            },
            .rejected => unreachable,
        }
    }
}

test "production field inventory and battle handoff survives saving and continuing from a fresh session" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try fixtures(io, temp.dir);
    try writeFieldBattle(io, temp.dir, "area_a_1", .acceptance);
    var diagnostic: content.Diagnostic = .{};
    var bundle = try content.Bundle.load(allocator, io, temp.dir, &diagnostic);
    defer bundle.deinit();

    var members: [6]battle.Member = undefined;
    var combat: battle.State = undefined;
    var boot = @import("journey_boot").Boot{
        .allocator = allocator,
        .path = @constCast(""),
        .save_path = null,
        .bundle = bundle,
        .party = null,
        .members = &members,
        .combat = &combat,
        .state = undefined,
    };
    var state = try boot.newState();
    var audio: SimulationAudio = .{};
    const original_progress = state.progress();
    const original_rng = state.combat.random;
    const slot = members[0].inventory.count();
    const expected_item = field.items.Stack{ .id = .antitoxin, .uses = field.items.Id.antitoxin.maxUses() };
    for (0..state.package.step_ticks) |_| _ = try frame.stepWithAudio(&state, .{ .menu = .{ .field = .{ .direction = .right } } }, &audio);
    const session = (state.field_event orelse return error.MissingFieldEvent).session;
    for (0..32) |_| {
        if (state.mode == .battle) break;
        _ = try frame.stepWithAudio(&state, .{}, &audio);
    } else return error.FieldBattleDidNotStart;
    try std.testing.expect(state.progress() == original_progress);
    try std.testing.expectEqualDeep(expected_item, members[0].inventory.slots[slot].?);
    try std.testing.expectEqual(slot + 1, members[0].inventory.count());
    try std.testing.expectEqualDeep(original_rng, state.combat.random);
    try std.testing.expectEqual(@as(u8, 6), state.progress().story.scenario.?.scenario[1]);
    try std.testing.expectError(error.GameBusy, journey.save(io, allocator, temp.dir, state));

    const request = (state.scripted_battle orelse return error.MissingScriptedBattleRequest).request;
    const battle_pc = session.instance.?.execution.pc;
    const resume_pc = session.instance.?.pending.?.next.pc;
    try std.testing.expectEqual(request.receipt.batch, session.instance.?.pending.?.batch.id);
    const position = state.field_state.destination;
    const room = state.field_state.room;
    for (0..6000) |_| {
        try std.testing.expectEqual(battle_pc, session.instance.?.execution.pc);
        if (state.combat.phase == .victory and state.combat.rewardReady()) break;
        switch (state.combat.phase) {
            .battle_menu => {
                for (0..3) |_| _ = try frame.stepWithAudio(&state, .{ .battle = .{ .down = true } }, &audio);
                _ = try frame.stepWithAudio(&state, .{ .battle = .{ .confirm = true } }, &audio);
            },
            .victory => _ = try frame.stepWithAudio(&state, .{ .battle = .{ .confirm = true } }, &audio),
            .defeat, .escaped => return error.UnexpectedBattleOutcome,
            else => _ = try frame.stepWithAudio(&state, .{}, &audio),
        }
    } else return error.BattleDidNotFinish;
    try std.testing.expect(!std.meta.eql(original_rng, state.combat.random));
    const battle_rng = state.combat.random;
    _ = try frame.stepWithAudio(&state, .{ .battle = .{ .confirm = true } }, &audio);
    try std.testing.expectEqual(.field, state.mode);
    try std.testing.expectEqualDeep(request.receipt, session.receipt.?);
    try std.testing.expectEqual(resume_pc, session.instance.?.execution.pc);
    try std.testing.expect(session.instance.?.pending == null and state.scripted_battle == null);
    try std.testing.expectEqual(@as(u8, 6), state.progress().story.scenario.?.scenario[1]);
    try std.testing.expectEqual(room, state.field_state.room);
    try std.testing.expectEqual(position, state.field_state.destination);

    for (0..8) |_| {
        if (state.field_event == null) break;
        _ = try frame.stepWithAudio(&state, .{}, &audio);
    } else return error.FieldEventDidNotFinish;
    try std.testing.expect(!session.busy());
    try std.testing.expectEqual(@as(u8, 0x26), state.progress().story.scenario.?.scenario[1]);
    try std.testing.expectEqualDeep(battle_rng, state.combat.random);
    const saved = try journey.Snapshot.capture(state);
    try journey.save(io, allocator, temp.dir, state);

    var restored_members: [6]battle.Member = undefined;
    var restored_combat: battle.State = undefined;
    boot.members = &restored_members;
    boot.combat = &restored_combat;
    var restored = try boot.newState();
    const restored_progress = restored.progress();
    try std.testing.expect(restored_progress != original_progress);
    try journey.restore(io, allocator, temp.dir, &restored);
    defer restored.releaseRestoredSave();
    try std.testing.expect(restored.field_state.progress == restored_progress);
    try std.testing.expectEqualDeep(saved, try journey.Snapshot.capture(restored));
    try std.testing.expectEqualDeep(expected_item, restored_members[0].inventory.slots[slot].?);

    for (0..restored.package.step_ticks) |_| _ = try frame.stepWithAudio(&restored, .{ .menu = .{ .field = .{ .direction = .right } } }, &audio);
    try std.testing.expectEqual(field.Point{ .x = position.x + 8, .y = position.y }, restored.field_state.destination);
    try std.testing.expect(restored.field_event == null and restored.scripted_battle == null);
    try std.testing.expectEqual(@as(u8, 0x26), restored.progress().story.scenario.?.scenario[1]);
    try std.testing.expectEqualDeep(battle_rng, restored.combat.random);
    try std.testing.expectEqual(@as(usize, 0), audio.polls);
}

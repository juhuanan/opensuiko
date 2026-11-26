//! Loader and static validator for package-owned ordinary field event bundles.
const std = @import("std");
const field = @import("field");
const events = @import("../field_events.zig");
const runtime = @import("event_runtime");
const population = @import("scene_population");
const motion = @import("opening_audience");
const ordinary = @import("field_actors");
const data = @import("field_events_data");
const rooms_mod = @import("../field_battle_rooms.zig");
const schema = @import("schema.zig");

const BattleRooms = rooms_mod.BattleRooms;

pub fn open(allocator: std.mem.Allocator, bytes: []const u8, package: field.Package) !*BattleRooms {
    const parsed = try std.json.parseFromSlice(BattleRooms.Packet, allocator, bytes, .{ .allocate = .alloc_always });
    const packet = parsed.value;
    const version = schema.parseVersion(packet.schema) orelse return error.InvalidBattleFieldEvents;
    const current_format = version >= 53;
    const with_scenery_mutations = version >= 52;
    const with_camera_push = version >= 51;
    const with_actor_owners = version >= 50;
    const with_hero_visibility = version >= 47;
    const with_item_overload = version >= 46;
    const with_wheel_motion = version >= 45;
    const with_wheel_music = version >= 44;
    const with_party_experience = version >= 43;
    const with_party_library = version >= 42;
    const with_mansion_music = version >= 41;
    const with_props = version >= 40;
    const with_fade_in = version >= 39;
    const with_scene_actors = version >= 38;
    const with_party_select = version >= 37;
    const with_effect_render = version >= 36;
    const with_party_graphics = version >= 35;
    const with_founding_audio = version >= 34;
    const with_founding_scene = version >= 33;
    const with_entry_placement = version >= 32;
    const with_auxiliary_party = version >= 31;
    const with_party_dismiss = version >= 30;
    const with_field_effects = version >= 29;
    const with_entry_music = version >= 28;
    const with_queued_music = version >= 27;
    const with_music = version >= 26;
    const with_actor_clips = version >= 25;
    const with_party_art = version >= 24;
    const with_party_queue = version >= 23;
    const with_dice = version >= 22;
    const with_recruit_loading = version >= 21;
    const with_rune_progression = version >= 20;
    const with_campaign = version >= 19;
    const with_actors = version >= 18;
    const with_room_flags = version >= 17;
    const with_game_over = version >= 16;
    const with_fade = version >= 15;
    const with_shared_items = version >= 14;
    const with_opening_route = version >= 13;
    const with_sound = version >= 12;
    const with_party_leave = version >= 11;
    const with_defeat_branch = version >= 10;
    const with_escape_branch = version >= 9;
    const with_multiple_exits = version >= 8;
    const with_party_edits = version >= 7;
    const allows_scenes = version >= 6;
    const with_choice = version >= 5;
    const with_portraits = version >= 4;
    const with_motion = version >= 3;
    const extended = version >= 2;
    if (packet.rooms.len == 0 or packet.rooms.len > package.rooms.len) return error.InvalidBattleFieldEvents;
    if ((packet.opening_world_exit != null and (!with_party_edits or packet.opening_world_exits.len != 0)) or
        (packet.opening_world_exits.len != 0 and !with_multiple_exits)) return error.InvalidOpeningWorldExit;
    if (packet.opening_battles.len != 0 and !with_party_edits) return error.InvalidOpeningBattle;
    if (packet.opening_route) |route| {
        if (!with_opening_route or package.roomIndex(route.dungeon) == null or package.roomIndex(route.palace) == null or
            package.roomIndex(route.first_town) == null or route.initial_party.len > 6) return error.InvalidOpeningRoute;
        for (route.initial_party, 0..) |id, i| {
            if (id.len == 0) return error.InvalidOpeningRoute;
            for (route.initial_party[0..i]) |prior| if (std.mem.eql(u8, prior, id)) return error.InvalidOpeningRoute;
        }
    }
    const exits = if (packet.opening_world_exit) |exit| try allocator.dupe(BattleRooms.ProgramRef, &.{exit}) else packet.opening_world_exits;
    const bindings = try allocator.alloc(events.Binding, packet.rooms.len);
    const contents = try allocator.alloc(runtime.Content, packet.rooms.len);
    const queues = (try std.json.parseFromSlice(events.QueueData, allocator, data.queues, .{})).value;
    try queues.validate();
    const hero = try fieldAnimation(allocator, "hero", package.player_clips);
    const hero_hash = try digest(allocator, hero);
    const empty_dialogue: events.DialogueData = .{
        .schema = "suikoden-field-dialogue/5",
        .content_sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
        .anchors = &.{},
        .texts = &.{},
        .prefixes = &.{},
        .images = &.{},
        .descriptor_changes = &.{},
        .configuration = @splat(.{ .normal_pace = 3, .pressed_pace = 1 }),
        .default_speed = .normal,
    };
    for (packet.rooms, bindings, contents, 0..) |room, *binding, *content, index| {
        if (room.party_actors.len != 0 and (!with_party_art or room.queues == null or room.queues.?.graphics != null)) return error.UnsupportedFieldPartyGraphics;
        var compiled_queues = room.queues orelse queues;
        if (room.party_actors.len != 0) compiled_queues.graphics = try compilePartyGraphics(allocator, room.party_actors, with_party_library);
        if (room.queues) |room_queues| {
            if (!with_party_queue or !room_queues.isRoom()) return error.UnsupportedFieldPartyQueue;
            try room_queues.validate();
            if (room_queues.graphics) |graphics| if (!with_party_library and std.mem.eql(u8, graphics.schema, "suikoden-field-party-graphics/3")) return error.UnsupportedFieldPartyGraphics;
        }
        const field_room = &package.rooms[package.roomIndex(room.room) orelse return error.UnknownEventRoom];
        if (room.queues) |room_queues| if (!field_room.canStand(room_queues.anchor.x, room_queues.anchor.y)) return error.InvalidFieldPartyAnchor;
        for (packet.rooms[0..index]) |prior| if (std.mem.eql(u8, prior.room, room.room)) return error.DuplicateEventRoom;
        try population.validate(room.population);
        try room.content.validate();
        if (room.content.hasSceneryMutations() and !with_scenery_mutations) return error.UnsupportedBattleFieldCommand;
        if (room.content.hasCameraPush() and !with_camera_push) return error.UnsupportedBattleFieldCommand;
        if (room.content.hasActorOwners() and !with_actor_owners) return error.UnsupportedBattleFieldCommand;
        if (room.content.needsWorldContext() and (version < 49 or !package.supportsWorldEntries())) return error.UnsupportedBattleFieldCommand;
        if (room.content.hasBranchHistory() and version < 48) return error.UnsupportedBattleFieldCommand;
        for (room.content.programs) |program| for (program.commands) |command| if (command.kind == .show_prop) {
            if (!with_props or !room.content.hasProps()) return error.UnsupportedBattleFieldCommand;
            const found = for (field_room.draws) |draw| {
                if (draw.prop == command.prop) break true;
            } else false;
            if (!found) return error.UnknownSceneryProp;
        };
        if (room.actors.len != 0 and !with_actors) return error.UnsupportedFieldActors;
        if (!with_actor_clips) for (room.actors) |actor| if (actor.clips != null) return error.UnsupportedFieldActorClips;
        for (room.actors) |actor| if (actor.entry_placement != null and (!with_entry_placement or actor.clips == null)) return error.UnsupportedFieldActorPlacement;
        if (room.field_effect_blend != null and (!with_effect_render or !room.content.hasFieldEffects())) return error.UnsupportedBattleFieldCommand;
        for (room.actors) |actor| if (actor.required_party_graphic != null and !with_party_graphics) return error.UnsupportedBattleFieldCommand;
        for (room.actors) |actor| if (actor.speed != null and !with_scene_actors) return error.UnsupportedBattleFieldCommand;
        for (room.actors) |actor| if (actor.scene_actor) |scene_actor| {
            if (!with_scene_actors or !room.content.hasSceneActors()) return error.UnsupportedBattleFieldCommand;
            if (!field_room.canStand(scene_actor.x, scene_actor.y)) return error.InvalidFieldActorResource;
        };
        const compiled = try compileRoomActors(allocator, room);
        const with_tracks = room.content.tracks.len != 0;
        const guarded_init = guarded: {
            for (room.content.programs) |program| for (program.commands) |command| {
                if (command.if_actor_constructed != null) break :guarded true;
            };
            break :guarded false;
        };
        if (guarded_init and !current_format) return error.UnsupportedBattleFieldCommand;
        if (with_tracks or guarded_init) {
            if (!with_actors) return error.UnsupportedBattleFieldCommand;
            try validateActorTracks(room);
        }
        if (!extended and room.dialogue != null) return error.UnsupportedBattleFieldDialogue;
        const dialogue = room.dialogue orelse empty_dialogue;
        if (dialogue.usesPartySchema() and
            (!room.content.hasPartyScene() or (room.queues == null and (!with_entry_placement or dialogue.hasFollowerBindings())))) return error.UnsupportedBattleFieldDialogue;
        if (room.dialogue != null) {
            try dialogue.validate(room.content);
            const portrait_dialogue = std.mem.eql(u8, dialogue.schema, events.DialogueData.room_portrait_schema) or dialogue.usesPartySchema();
            if (dialogue.descriptor_changes.len != 0 or
                (portrait_dialogue and !with_portraits) or
                (!portrait_dialogue and (dialogue.prefixes.len != 0 or dialogue.images.len != 0))) return error.UnsupportedBattleFieldDialogue;
            for (dialogue.images) |image| if (image.atlas_rect == null) return error.UnsupportedBattleFieldDialogue;
            for (dialogue.prefixes, 0..) |prefix, i| {
                for (dialogue.prefixes[0..i]) |prior| if (prior.command == prefix.command and std.mem.eql(u8, prior.program, prefix.program)) return error.InvalidFieldDialogue;
                if (prefix.text) |text| for (dialogue.texts[text].tokens, 0..) |token, j| {
                    if (token.kind == .glyph or (token.kind == .newline and j + 1 == dialogue.texts[text].tokens.len)) continue;
                    return error.InvalidFieldDialogue;
                };
            }
            for (dialogue.texts, 0..) |entry, i| {
                const source = room.content.text(entry.id) orelse return error.MissingBattleFieldText;
                if (source.tokens.len != entry.tokens.len) return error.InvalidFieldDialogue;
                for (dialogue.texts[0..i]) |prior| if (std.mem.eql(u8, prior.id, entry.id)) return error.InvalidFieldDialogue;
                for (source.tokens, entry.tokens) |expected, actual| {
                    if (!std.mem.eql(u8, @tagName(expected.kind), @tagName(actual.kind)) or expected.value != actual.value or
                        !std.mem.eql(u8, expected.text orelse "", actual.text orelse "")) return error.InvalidFieldDialogue;
                }
            }
            for (dialogue.anchors, 0..) |anchor, i| {
                if (anchor.point) |point| {
                    if (point.x >= field_room.width or point.y >= field_room.height) return error.InvalidFieldDialogue;
                } else if (!dialogue.usesPartySchema()) return error.UnsupportedBattleFieldDialogue;
                for (dialogue.anchors[0..i]) |prior| if (prior.command == anchor.command and std.mem.eql(u8, prior.program, anchor.program)) return error.InvalidFieldDialogue;
            }
        }
        for (room.population.entities) |entity| {
            const interaction = allows_scenes and entity.trigger == .interaction;
            const arrival = allows_scenes and entity.trigger == .area_entry;
            const initialization = allows_scenes and entity.trigger == .initialization;
            if ((entity.trigger != .ordinary and !interaction and !arrival and !initialization) or entity.event_selection.pointer_state == .null) {
                if (entity.event.status == .resolved) return error.UnsupportedBattleFieldEvent;
                continue;
            }
            if (allows_scenes and entity.event.status == .source_only) continue;
            if (entity.event.status != .resolved) return error.UnsupportedBattleFieldEvent;
            const owner_program = room.content.program(entity.event.program_id.?).?;
            const inherited = owner_program.owner_actor != null or owner_program.owner_actors != null;
            if (interaction and !inherited and (!population.isPlacedInteraction(entity) or
                entity.classification.pointer_state == .null)) return error.InvalidFieldEventBinding;
            if (interaction) for (entity.classification.terms) |term| switch (term.kind) {
                .story_mask_set, .story_mask_clear => {},
                else => if (!with_campaign) return error.UnsupportedFieldEventPredicate,
            };
            for (entity.event_selection.terms) |term| switch (term.kind) {
                .story_mask_set, .story_mask_clear, .coordinate_range => {},
                .interaction => if (!interaction) return error.UnsupportedFieldEventPredicate,
                .unsupported => return error.UnsupportedFieldEventPredicate,
                else => if (!with_campaign) return error.UnsupportedFieldEventPredicate,
            };
            const program = room.content.program(entity.event.program_id.?) orelse return error.UnknownEventProgram;
            const trigger: @FieldType(runtime.Program, "trigger") = if (interaction) .interaction else if (arrival) .area_entry else .none;
            const entry: @FieldType(runtime.Program, "entry") = if (initialization) .initialization else .ordinary;
            if (program.entry != entry or program.trigger != trigger) return error.UnsupportedBattleFieldEvent;
        }
        for (room.content.programs) |program| {
            for (program.commands) |command| {
                if (command.facility != null and !current_format) return error.UnsupportedBattleFieldCommand;
                if (command.kind == .branch_party and !current_format) return error.UnsupportedBattleFieldCommand;
                if (!with_hero_visibility and command.kind == .hide_hero) return error.UnsupportedBattleFieldCommand;
                if (!with_item_overload and command.kind == .item_overload) return error.UnsupportedBattleFieldCommand;
                if (command.kind == .item_overload and std.meta.stringToEnum(field.items.Id, command.item_name.?) == null) return error.UnknownFieldEventItem;
                if (!with_wheel_motion and runtime.isWheelControl(command.kind)) return error.UnsupportedBattleFieldCommand;
                if (!with_wheel_music and command.kind == .field_music and command.music == .wheel) return error.UnsupportedBattleFieldCommand;
                if (!with_party_experience and (command.kind == .party_gain_experience or command.kind == .party_lose_experience)) return error.UnsupportedBattleFieldCommand;
                if (!with_mansion_music and command.kind == .field_music and (command.music == .mansion or command.music == .area_b)) return error.UnsupportedBattleFieldCommand;
                if (!with_founding_audio and ((command.kind == .field_music and command.music == .founding) or (command.kind == .play_sound and command.cue == 0x813))) return error.UnsupportedBattleFieldCommand;
                if (!with_founding_scene and command.kind == .place_actor and command.x != null and command.y != null) return error.UnsupportedBattleFieldCommand;
                if (!with_founding_scene and program.entry == .ordinary and command.kind == .field_music and command.music == .headquarters) return error.UnsupportedBattleFieldCommand;
                if (!with_auxiliary_party and command.kind == .area_action and command.area.?.isAuxiliaryPartyEdit()) return error.UnsupportedBattleFieldCommand;
                if (!with_party_dismiss and command.kind == .party_dismiss) return error.UnsupportedBattleFieldCommand;
                if (!with_field_effects and (command.kind == .field_effect or command.kind == .wait_field_effect or command.kind == .party_restore)) return error.UnsupportedBattleFieldCommand;
                if (command.kind == .fade_in and !with_fade_in) return error.UnsupportedBattleFieldCommand;
                if (command.kind == .spawn_actor and !with_scene_actors) return error.UnsupportedBattleFieldCommand;
                if (command.kind == .party_select and !with_party_select) return error.UnsupportedBattleFieldCommand;
                if (command.kind == .fixed_dice and !with_dice) return error.UnsupportedBattleFieldCommand;
                if (command.kind == .recruit_mark_loaded and !with_recruit_loading) return error.UnsupportedBattleFieldCommand;
                if (command.kind == .soul_eater_advance and !with_rune_progression) return error.UnsupportedBattleFieldCommand;
                if (command.kind == .place_hero and !with_actors) return error.UnsupportedBattleFieldCommand;
                if (command.kind == .queue_track and room.content.track(command.track.?) == null) return error.UnknownEventTrack;
                if (command.kind == .actor_transition and !std.mem.eql(u8, command.actor.?, "hero") and runtime.partyActorIndex(command.actor.?) == null) {
                    for (room.actors) |actor| {
                        if (std.mem.eql(u8, command.actor.?, actor.id)) break;
                    } else return error.UnknownFieldActor;
                }
                if (!with_party_edits and (command.kind == .rune_grant or command.kind == .inventory_edit or command.kind == .warehouse_deposit)) return error.UnsupportedBattleFieldCommand;
                if ((!with_escape_branch and command.escape_target != null) or
                    (!with_defeat_branch and command.defeat_target != null) or
                    (!with_game_over and command.defeat_ends_run) or
                    (!with_party_leave and command.kind == .party_leave) or
                    (!with_queued_music and command.kind == .field_music and command.music == .fade) or
                    (!with_queued_music and command.source_arrival) or
                    (!with_entry_music and command.kind == .field_music and command.music == .headquarters) or
                    (!with_music and command.kind == .field_music) or
                    (!with_sound and command.kind == .play_sound) or
                    (!with_opening_route and command.arrival_facing != null) or
                    (!with_shared_items and command.kind == .shared_inventory_edit) or
                    (!with_fade and command.kind == .fade_out)) return error.UnsupportedBattleFieldCommand;
            }
            try validateProgram(room.content, program, room.dialogue, if (with_motion) field_room.* else null, with_choice, if (allows_scenes) package else null, with_room_flags, with_tracks, with_campaign, room.queues != null);
        }
        binding.* = .{
            .scripted_motion = with_motion,
            .room_package = if (allows_scenes) package else null,
            .room_actors = room.actors,
            .party_actors = room.party_actors,
            .ordinary = compiled.packet,
            .movement = if (with_tracks) .{
                .identity = room.room,
                .camera = .{ .x = 0, .y = 0 },
                .event_active = true,
                .context = field_room,
                .decide_fn = canMoveRoomActor,
            } else null,
            .room = room.room,
            .field_effect_blend = room.field_effect_blend,
            .context = .{
                .schema = "suikoden-field-scene-context/1",
                .room = room.room,
                .event_id = room.content.id,
                .event_sha256 = room.content.content_sha256,
                .population_id = room.population.id,
                .population_sha256 = room.population.content_sha256,
                .dialogue_sha256 = dialogue.content_sha256,
                .dialogue_counts = .{ @intCast(dialogue.anchors.len), @intCast(dialogue.texts.len), @intCast(dialogue.prefixes.len), @intCast(dialogue.images.len), 0 },
                .party_queue = room.queues != null,
                .ordinary_sha256 = if (compiled.packet) |value| value.content_sha256 else null,
                .content_sha256 = try digest(allocator, room),
            },
            .content = room.content,
            .population = room.population,
            .party = &.{},
            .queues = compiled_queues,
            .dialogue = dialogue,
            .animations = compiled.animations,
            .hero_animation = hero,
            .hero_sha256 = hero_hash,
        };
        try binding.validateRoomScene(field_room.*);
        content.* = room.content;
    }
    const result = try allocator.create(BattleRooms);
    result.* = .{ .bindings = bindings, .initial_story = try runtime.StoryState.init(contents), .opening_route = packet.opening_route, .opening_world_exits = exits, .opening_battles = packet.opening_battles };
    for (exits, 0..) |exit, i| {
        for (exits[0..i]) |other| if (other.matches(exit.room, exit.program)) return error.InvalidOpeningWorldExit;
        const program = result.ordinaryProgram(exit) orelse return error.InvalidOpeningWorldExit;
        const terminal = program.commands[program.commands.len - 1];
        if ((terminal.kind != .room_transition and terminal.kind != .world_transition) or (!terminal.retainsWorldRegion() and std.mem.eql(u8, exit.room, terminal.destination.?))) return error.InvalidOpeningWorldExit;
    }
    for (packet.opening_battles) |ref| {
        const program = result.ordinaryProgram(ref) orelse return error.InvalidOpeningBattle;
        var battles: usize = 0;
        for (program.commands) |command| battles += @intFromBool(command.kind == .battle);
        if (battles != 1) return error.InvalidOpeningBattle;
    }
    return result;
}

fn compileRoomActors(allocator: std.mem.Allocator, room: BattleRooms.Room) !struct { packet: ?ordinary.Packet = null, animations: []const motion.Animation = &.{} } {
    if (room.actors.len == 0) return .{};
    if (room.actors.len > 64) return error.InvalidFieldActorResource;
    const definitions = try allocator.alloc(ordinary.Definition, room.actors.len);
    const animations = try allocator.alloc(motion.Animation, room.actors.len);
    for (room.actors, definitions, animations, 0..) |actor, *definition, *animation, index| {
        if (actor.entity >= room.population.entities.len or actor.id.len == 0 or actor.id.len > 96 or std.mem.eql(u8, actor.id, "hero")) return error.InvalidFieldActorResource;
        for (actor.id) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return error.InvalidFieldActorResource;
        const entity = room.population.entities[actor.entity];
        if (actor.required_party_graphic) |character| {
            if (character == 0 or character == 255 or actor.clips == null or entity.source_character_id != @as(?u16, character) or entity.resource_domain != .area_character_context) return error.InvalidFieldActorResource;
        }
        const staged = entity.position.placement == .off_map_staging and room.content.hasPartyScene() and
            (actor.clips != null or room.content.hasActorOwners());
        if (actor.scene_actor == null and ((entity.position.placement != .placed and !staged) or !entity.population_candidate)) return error.InvalidFieldActorResource;
        if (actor.scene_actor) |scene_actor| {
            if (actor.clips == null or actor.entry_placement != null or actor.required_party_graphic != null or scene_actor.character == 0 or scene_actor.character == 255) return error.InvalidFieldActorResource;
            var creates: usize = 0;
            for (room.content.programs) |program| {
                const linear = !room.content.tracksBranchHistory(program);
                var created = false;
                var released = false;
                for (program.commands) |command| {
                    const target = if (command.kind == .queue_track) room.content.track(command.track.?).?.actor else command.actor orelse continue;
                    if (!std.mem.eql(u8, target, actor.id)) continue;
                    if (command.kind == .spawn_actor) {
                        if (created) return error.InvalidFieldActorResource;
                        if (!entity.population_candidate and (entity.record_role != .event or program.entity != actor.entity)) return error.InvalidFieldActorResource;
                        created = true;
                        creates += 1;
                    } else if (!created or (linear and released)) return error.InvalidFieldActorResource;
                    if (command.kind == .release_actor) released = true;
                }
                if (linear and created and !released) return error.InvalidFieldActorResource;
            }
            if (creates != 1) return error.InvalidFieldActorResource;
        }
        const resource = if (actor.scene_actor) |scene_actor| try std.fmt.allocPrint(allocator, "scene_character_{d}", .{scene_actor.character}) else entity.resource_id orelse return error.InvalidFieldActorResource;
        var cond_count: usize = 0;
        for (entity.classification.terms) |term| {
            if (term.kind == .story_mask_set or term.kind == .story_mask_clear) {
                cond_count += 1;
            } else if (!std.mem.eql(u8, room.population.schema, population.extended_schema) and !std.mem.eql(u8, room.population.schema, population.prop_schema)) {
                return error.InvalidFieldActorResource;
            }
        }
        const conditions = try allocator.alloc(runtime.Condition, cond_count);
        const presence = try allocator.alloc(population.Term, entity.classification.terms.len - cond_count);
        var ci: usize = 0;
        var pi: usize = 0;
        for (entity.classification.terms) |term| {
            if (term.kind == .story_mask_set or term.kind == .story_mask_clear) {
                conditions[ci] = .{ .kind = if (term.kind == .story_mask_set) .story_mask_set else .story_mask_clear, .flag = term.flag.? };
                ci += 1;
            } else {
                presence[pi] = term;
                pi += 1;
            }
        }
        definition.* = .{ .id = actor.id, .entity = actor.entity, .slot = @intCast(index), .resource = resource, .graphic = actor.id, .x = entity.position.x, .y = entity.position.y, .speed = actor.speed orelse 0, .variant = @intCast(@backingInt(actor.facing)), .auto_animate = false, .conditions = conditions, .presence = presence, .entry_placement = actor.entry_placement, .required_party_graphic = actor.required_party_graphic };
        if (actor.scene_actor) |scene_actor| {
            definition.x = scene_actor.x;
            definition.y = scene_actor.y;
            definition.scene_owned = true;
            definition.speed = 2;
            definition.conditions = &.{};
            definition.presence = &.{};
        }
        animation.graphic = actor.id;
        if (actor.clips) |clips| {
            for (clips, 0..) |clip, direction| {
                if (@backingInt(clip.direction) != direction or clip.frames.len != 4 or clip.idle_frame != 1) return error.InvalidFieldActorResource;
                for (clip.frames) |frame| {
                    if (!rooms_mod.inAtlas(frame.rect, 4096, 4096) or frame.rect.w > 128 or frame.rect.h > 128 or frame.anchor_x < 0 or frame.anchor_x > frame.rect.w or frame.anchor_y < 0 or frame.anchor_y > frame.rect.h) return error.InvalidFieldActorAtlas;
                }
                if (!std.meta.eql(actor.poses[direction], clip.frames[clip.idle_frame])) return error.InvalidFieldActorAtlas;
            }
            animation.* = try fieldAnimation(allocator, actor.id, &clips);
            continue;
        }
        for (actor.poses, &animation.clips) |pose, *clip| {
            if (!rooms_mod.inAtlas(pose.rect, 4096, 4096) or pose.rect.w > 128 or pose.rect.h > 128 or
                pose.anchor_x < 0 or pose.anchor_x > pose.rect.w or pose.anchor_y < 0 or pose.anchor_y > pose.rect.h or
                pose.ticks == 0 or pose.ticks > 256) return error.InvalidFieldActorAtlas;
            clip.* = .{ .flags = 0, .ticks = try allocator.dupe(u16, &.{pose.ticks}), .bounds = try allocator.dupe(motion.Bounds, &.{.{ .width = @intCast(pose.rect.w), .height = @intCast(pose.rect.h) }}) };
        }
    }
    const hash = try digest(allocator, room.actors);
    const has_scene_actors = for (room.actors) |actor| {
        if (actor.scene_actor != null) break true;
    } else false;
    const packet: ordinary.Packet = .{ .schema = if (has_scene_actors) "suikoden-field-ordinary-actors/2" else "suikoden-field-ordinary-actors/1", .scene = room.room, .binding_sha256 = hash, .content_sha256 = hash, .population_sha256 = room.population.content_sha256, .event_sha256 = room.content.content_sha256, .actors = definitions };
    try packet.validate(animations);
    return .{ .animations = animations, .packet = packet };
}

fn validateActorTracks(room: BattleRooms.Room) !void {
    for (room.content.programs) |program| for (program.commands) |command| {
        const initializer = room.content.actorInitialization(program);
        if (initializer and command.kind == .actor_transition and std.mem.eql(u8, command.actor.?, "hero")) continue;
        if (command.kind != .spawn_actor and command.kind != .place_actor and command.kind != .release_actor and
            !(initializer and (command.kind == .actor_transition or command.kind == .actor_motion))) continue;
        if (!room.content.hasActorPositions()) return error.UnsupportedBattleFieldCommand;
        for (room.actors) |actor| {
            if (!std.mem.eql(u8, actor.id, command.actor.?)) continue;
            if (command.kind == .actor_motion and command.value.? != (actor.speed orelse 0)) return error.InvalidFieldActorResource;
            if ((initializer and actor.scene_actor != null) or (!initializer and actor.clips == null and
                !(room.content.hasSceneryMutations() and command.kind == .place_actor and actor.scene_actor == null))) return error.InvalidFieldActorResource;
            break;
        } else return error.InvalidFieldActorResource;
    };
    for (room.content.tracks) |track| {
        if (runtime.partyActorIndex(track.actor) != null) {
            if (room.queues == null or !room.content.hasPartyTracks()) return error.InvalidFieldActorTrack;
        } else if (!std.mem.eql(u8, track.actor, "hero")) {
            for (room.actors) |actor| {
                if (std.mem.eql(u8, actor.id, track.actor)) break;
            } else return error.UnknownFieldActor;
        }
        var has_direction = false;
        for (track.commands, 0..) |command, i| {
            if ((command.kind == .finish) != (i == track.commands.len - 1) or
                (command.kind == .move) != (command.direction != null) or
                (command.kind == .move or command.kind == .advance) != (command.cells != null) or
                (command.kind == .set_motion) != (command.motion != null) or command.motion == 255)
                return error.InvalidFieldActorTrack;
            if (command.kind == .advance and (!has_direction or command.cells.? == 0)) return error.InvalidFieldActorTrack;
            if (command.kind == .move) has_direction = true;
        }
    }
}

fn canMoveRoomActor(_: *const anyopaque, _: []const u8, actor: motion.ActorMotion, direction: motion.Direction) ?bool {
    const x = actor.x + @as(i32, switch (direction) {
        .left => -8,
        .right => 8,
        else => 0,
    });
    const y = actor.y + @as(i32, switch (direction) {
        .up => -8,
        .down => 8,
        else => 0,
    });
    // The source event-active flag bypasses collision during queued motion.
    return x >= 0 and y >= 0 and x <= 2040 and y <= 2040;
}

fn validateProgram(content: runtime.Content, program: runtime.Program, dialogue: ?events.DialogueData, motion_room: ?field.Room, with_choice: bool, room_package: ?field.Package, with_room_flags: bool, with_tracks: bool, with_campaign: bool, with_party_queue: bool) !void {
    if (program.selection.len != 0 and (room_package == null or program.entry != .ordinary or (program.trigger != .none and program.trigger != .interaction))) return error.UnsupportedBattleFieldEvent;
    if (program.trigger == .interaction) for (program.selection) |term| switch (term.kind) {
        .party_absent, .party_contains => {},
        .recruit_present, .recruit_absent, .recruit_ever, .recruit_count_at_least, .stage_at_least, .money_at_least, .level_at_least, .has_item, .party_count_equals => if (!with_campaign) return error.UnsupportedFieldEventPredicate,
        .room_mask_set, .room_mask_clear => if (!with_room_flags) return error.UnsupportedFieldEventPredicate,
        .hero_x_inclusive, .hero_y_inclusive, .hero_x_strict, .hero_y_strict => if (!with_campaign) return error.UnsupportedFieldEventPredicate,
        else => return error.UnsupportedFieldEventPredicate,
    };
    for (program.selection) |term| switch (term.kind) {
        .hero_x_inclusive, .hero_y_inclusive, .hero_x_strict, .hero_y_strict => {},
        .pressed_mask => if (runtime.Direction.fromPadMask(term.mask) == null) return error.UnsupportedFieldEventPredicate,
        .room_mask_set, .room_mask_clear => if (!with_room_flags or term.mask > 255) return error.UnsupportedFieldEventPredicate,
        .party_absent, .party_contains => if (term.index == 0) return error.UnsupportedFieldEventPredicate,
        else => if (!with_campaign) return error.UnsupportedFieldEventPredicate,
    };
    var has_battle = false;
    for (program.commands, 0..) |command, index| {
        if (command.kind == .scenery_stage or command.kind == .scenery_restore or command.kind == .scenery_append) {
            const operation = command.sceneryOperation() orelse return error.UnsupportedBattleFieldCommand;
            if (!content.hasSceneryMutations() or
                (operation == .restore_instance and program.entry != .ordinary) or
                (program.entry == .initialization and !content.actorInitialization(program))) return error.UnsupportedBattleFieldCommand;
            const room = motion_room orelse return error.UnsupportedBattleFieldCommand;
            const model = room.scenery_model orelse return error.InvalidFieldSceneryState;
            switch (operation) {
                .append_template => |template| if (template < model.initial_count or template >= model.objects.len)
                    return error.UnknownFieldSceneryTemplate,
                .stage_instance, .restore_instance => |instance| if (instance >= field.scenery.max_instances or
                    (model.objects.len == model.initial_count and instance >= model.initial_count))
                    return error.UnknownFieldSceneryInstance,
            }
            continue;
        }
        if (command.kind == .area_action) {
            const action = command.area.?;
            if (action.isAuxiliaryPartyEdit()) {
                if (room_package == null or !with_campaign or program.entry != .ordinary) return error.UnsupportedBattleFieldCommand;
            } else if (!with_room_flags or action.kind != .room_flag or action.bits == 0 or command.wait != null or command.requires != null) return error.UnsupportedBattleFieldCommand;
            continue;
        }
        if (program.entry == .initialization) {
            if (room_package == null or command.wait != null or command.requires != null) return error.UnsupportedBattleFieldCommand;
            switch (command.kind) {
                .show_prop => {
                    if (!room_package.?.supportsProps()) return error.UnsupportedBattleFieldCommand;
                    continue;
                },
                .field_music => {
                    if (command.music != .headquarters) return error.UnsupportedBattleFieldCommand;
                    continue;
                },
                .set_camera, .set_hero_display => {
                    if (motion_room == null) return error.UnsupportedBattleFieldCommand;
                    continue;
                },
                .place_actor, .place_hero, .actor_transition, .actor_motion => {
                    if (!content.actorInitialization(program) or motion_room == null) return error.UnsupportedBattleFieldCommand;
                    continue;
                },
                .continue_tick, .yield_tick, .label, .jump, .story_or, .story_andnot, .end_stream => continue,
                else => return error.UnsupportedBattleFieldCommand,
            }
        }
        if (command.requires) |required| {
            const allowed = switch (required.kind) {
                .event_flags_low2 => dialogue != null and std.mem.eql(u8, required.id, "dialogue_flags"),
                .box_closed => dialogue != null and (command.kind == .open_box or command.kind == .open_fixed_box) and std.mem.eql(u8, required.id, if (command.box.? == 0) "box_0" else "box_1"),
                .alignment => motion_room != null and std.mem.eql(u8, required.id, "alignment"),
                .pan => motion_room != null and std.mem.eql(u8, required.id, "pan"),
                else => false,
            };
            if (!allowed) return error.UnsupportedBattleFieldCommand;
        }
        if (command.wait) |wait| {
            const allowed = switch (command.kind) {
                .delay => wait.kind == .delay and std.mem.eql(u8, wait.id, "delay"),
                .text => wait.kind == .text and std.mem.eql(u8, wait.id, command.text.?),
                .start_or_wait_dialogue, .speaker => wait.kind == .speaker_prefix and std.mem.eql(u8, wait.id, if (command.box.? == 0) "box_0" else "box_1"),
                .camera_push => wait.kind == .camera_push and std.mem.eql(u8, wait.id, "camera_push"),
                .align_hero => wait.kind == .alignment and std.mem.eql(u8, wait.id, "alignment"),
                .pan => wait.kind == .pan and std.mem.eql(u8, wait.id, "pan"),
                .fade_out, .fade_in => wait.kind == .fade and std.mem.eql(u8, wait.id, "fade"),
                else => false,
            };
            if (!allowed) return error.UnsupportedBattleFieldCommand;
        }
        switch (command.kind) {
            .camera_push => if (!content.hasCameraPush() or motion_room == null or room_package == null) return error.UnsupportedBattleFieldCommand,
            .sequence_input => if (!with_campaign or room_package == null) return error.UnsupportedBattleFieldCommand,
            .hide_hero => if (motion_room == null or room_package == null) return error.UnsupportedBattleFieldCommand,
            .wheel_spin, .wheel_restore, .wheel_turn, .wheel_align, .branch_wheel => {
                const room = motion_room orelse return error.UnsupportedBattleFieldCommand;
                if (!content.hasWheelMotion() or room_package == null or room.wheel_map == null) return error.UnsupportedBattleFieldCommand;
            },
            .item_overload => if (!with_campaign or room_package == null) return error.UnsupportedBattleFieldCommand,
            .field_effect, .wait_field_effect => if (motion_room == null or room_package == null) return error.UnsupportedBattleFieldCommand,
            .continue_tick, .yield_tick, .label, .jump, .story_or, .story_andnot, .end_stream => {},
            .delay => if (command.updates.? == 0 or command.wait == null) return error.UnsupportedBattleFieldCommand,
            .align_hero, .place_hero => {
                const room = motion_room orelse return error.UnsupportedBattleFieldCommand;
                const x = command.x.?;
                const y = command.y.?;
                _ = try motion.Alignment.start(x, y, x, y);
                if (!room.canStand(x, y)) return error.InvalidBattleFieldAlignment;
            },
            .pan => {
                if (motion_room == null) return error.UnsupportedBattleFieldCommand;
                const camera: @import("../field_events_state.zig").ScriptedCamera = .{
                    .pan = .{ .dx = command.dx.?, .dy = command.dy.?, .remaining = command.updates.? },
                };
                try camera.validate();
            },
            .show_prop => {
                if (room_package == null or !room_package.?.supportsProps()) return error.UnsupportedBattleFieldCommand;
            },
            .set_camera, .fade_in, .spawn_actor, .place_actor, .release_actor => if (motion_room == null) return error.UnsupportedBattleFieldCommand,
            .actor_transition => {
                if (motion_room == null) return error.UnsupportedBattleFieldCommand;
                if (runtime.partyActorIndex(command.actor.?) != null and (!with_party_queue or dialogue == null or !std.mem.eql(u8, dialogue.?.schema, events.DialogueData.party_schema))) return error.UnsupportedBattleFieldCommand;
            },
            .queue_track, .wait_tracks => if (!with_tracks) return error.UnsupportedBattleFieldCommand,
            .request_area_party_prefix => if (!with_party_queue and program.owner_actor == null) return error.UnsupportedBattleFieldCommand,
            .queue_glyphs_a, .queue_glyphs_b, .wait_text_queue_empty, .wait_text_queue_drain_and_release => if (!with_party_queue) return error.UnsupportedBattleFieldCommand,
            .open_fixed_box => if (dialogue == null) return error.UnsupportedBattleFieldDialogue,
            .open_box => {
                const scene = dialogue orelse return error.UnsupportedBattleFieldDialogue;
                for (scene.anchors) |anchor| {
                    if (anchor.command == index and std.mem.eql(u8, anchor.program, program.id)) break;
                } else return error.MissingBattleFieldDialogueAnchor;
            },
            .text => {
                const scene = dialogue orelse return error.UnsupportedBattleFieldDialogue;
                if (command.box.? > 1 or command.wait == null) return error.UnsupportedBattleFieldCommand;
                for (scene.texts) |entry| {
                    if (std.mem.eql(u8, entry.id, command.text.?)) break;
                } else return error.MissingBattleFieldText;
            },
            .start_or_wait_dialogue, .speaker => {
                const scene = dialogue orelse return error.UnsupportedBattleFieldDialogue;
                const prefix = scene.prefixFor(program.id, index) orelse return error.UnsupportedBattleFieldDialogue;
                if ((prefix.text != null) != (command.wait != null)) return error.UnsupportedBattleFieldCommand;
            },
            .choice, .branch_choice => if (!with_choice or dialogue == null) return error.UnsupportedBattleFieldCommand,
            .inn_stay => if (room_package == null or !with_choice) return error.UnsupportedBattleFieldCommand,
            .close_box, .wait_for_accept, .wait_boxes, .wait_event_flags_low2 => if (dialogue == null) return error.UnsupportedBattleFieldDialogue,
            .battle => has_battle = true,
            .party_join, .party_load, .advance_character, .party_gain_experience, .party_lose_experience, .party_leave, .rune_grant, .inventory_edit, .warehouse_deposit, .shared_inventory_edit, .field_music, .play_sound, .fade_out, .branch_castle_tier, .branch_party => if (room_package == null) return error.UnsupportedBattleFieldCommand,
            .party_restore, .party_dismiss => if (room_package == null or !with_campaign) return error.UnsupportedBattleFieldCommand,
            .room_transition => {
                const package = room_package orelse return error.UnsupportedBattleFieldCommand;
                const transition = command.roomTransition() orelse return error.UnsupportedBattleFieldCommand;
                const room = package.roomIndex(transition.destination) orelse return error.UnknownEventRoom;
                const area = package.rooms[room].source_area orelse "";
                switch (transition.world_entry) {
                    .named => |id| {
                        const entry = package.world_entries[package.worldEntryIndex(id) orelse return error.MissingWorldEntry];
                        if (!std.mem.eql(u8, entry.area, area)) return error.InvalidFieldEventTransition;
                    },
                    .point => |point| {
                        for (package.world_entries) |entry| {
                            if (entry.point == point and std.mem.eql(u8, entry.area, area)) break;
                        } else return error.MissingWorldEntry;
                    },
                    .reconcile => {},
                }
                if (!package.rooms[room].contains(transition.x, transition.y) or
                    (!transition.source_arrival and !package.rooms[room].canStand(transition.x, transition.y))) return error.InvalidFieldEventTransition;
            },
            .world_transition => {
                if (!with_campaign) return error.UnsupportedBattleFieldCommand;
                const package = room_package orelse return error.UnsupportedBattleFieldCommand;
                const transition = command.worldTransition() orelse return error.UnsupportedBattleFieldCommand;
                switch (transition) {
                    .return_to_entry => if (package.world_entries.len == 0) return error.MissingWorldEntry,
                    .retained_region => |cell| {
                        var matched = false;
                        for (package.world_entries) |entry| {
                            if (!std.mem.eql(u8, entry.area, (motion_room orelse return error.UnsupportedBattleFieldCommand).source_area orelse "")) continue;
                            const room = package.roomIndex(entry.world_room) orelse return error.UnknownEventRoom;
                            const spawn = (field.HalfCell{ .x = cell.x, .y = cell.y }).toPixels();
                            if (!package.rooms[room].contains(spawn.x, spawn.y)) return error.InvalidFieldEventTransition;
                            matched = true;
                        }
                        if (!matched) return error.MissingWorldEntry;
                    },
                    .destination => |target| {
                        const room = package.roomIndex(target.room) orelse return error.UnknownEventRoom;
                        const spawn = (field.HalfCell{ .x = target.cell.x, .y = target.cell.y }).toPixels();
                        if (!package.rooms[room].contains(spawn.x, spawn.y)) return error.InvalidFieldEventTransition;
                    },
                }
            },
            .party_select => if (!with_campaign or room_package == null or program.entry != .ordinary) return error.UnsupportedBattleFieldCommand,
            .chest_grant => {
                if (!with_campaign or room_package == null) return error.UnsupportedBattleFieldCommand;
                _ = std.meta.stringToEnum(field.items.Id, command.item_name.?) orelse return error.UnknownFieldEventItem;
            },
            .room_flag_clear, .world_mode, .soul_eater_advance, .money_edit, .recruit_toggle, .recruit_mark_loaded, .tile_variant, .auto_route, .special_checkpoint, .fixed_dice => {
                if (!with_campaign or room_package == null) return error.UnsupportedBattleFieldCommand;
            },
            .service => {
                if (!with_campaign or room_package == null) return error.UnsupportedBattleFieldCommand;
                if (command.shop_items) |items| for (items) |id| {
                    _ = std.meta.stringToEnum(field.items.Id, id) orelse return error.UnknownFieldEventItem;
                };
            },
            else => return error.UnsupportedBattleFieldCommand,
        }
    }
    if (!has_battle and room_package == null) return error.MissingFieldBattleCommand;
}

fn compilePartyGraphics(allocator: std.mem.Allocator, actors: []const events.PartyActor, expanded: bool) !events.GraphicsData {
    // The bank contains eligible characters; a scene still instantiates at most five followers.
    if (actors.len == 0 or actors.len > (if (expanded) @as(usize, 255) else 5)) return error.InvalidFieldPartyGraphics;
    const resources = try allocator.alloc(events.GraphicsResource, actors.len);
    for (actors, resources) |actor, *resource| {
        for (actor.clips, 0..) |clip, direction| {
            if (@backingInt(clip.direction) != direction or clip.idle_frame != 1 or clip.frames.len != 4) return error.InvalidFieldPartyGraphics;
            for (clip.frames) |frame| {
                if (frame.rect.w <= 0 or frame.rect.w > 128 or frame.rect.h <= 0 or frame.rect.h > 128 or frame.anchor_x < 0 or frame.anchor_x > frame.rect.w or frame.anchor_y < 0 or frame.anchor_y > frame.rect.h) return error.InvalidFieldPartyGraphics;
            }
        }
        resource.* = .{ .character = actor.character, .id = actor.id, .clips = (try fieldAnimation(allocator, actor.id, &actor.clips)).clips };
    }
    const result: events.GraphicsData = .{ .schema = if (actors.len > 5) "suikoden-field-party-graphics/3" else "suikoden-field-party-graphics/2", .resources = resources, .content_sha256 = try digest(allocator, actors) };
    try result.validate();
    return result;
}

fn fieldAnimation(allocator: std.mem.Allocator, graphic: []const u8, clips: []const field.Clip) !motion.Animation {
    if (clips.len != 4) return error.InvalidFieldHeroAnimation;
    var result: motion.Animation = .{ .graphic = graphic, .clips = undefined };
    for (clips) |clip| {
        if (clip.idle_frame != 1 or clip.frames.len < 2) return error.InvalidFieldHeroAnimation;
        const ticks = try allocator.alloc(u16, clip.frames.len);
        const bounds = try allocator.alloc(motion.Bounds, clip.frames.len);
        for (clip.frames, ticks, bounds) |frame, *duration, *extent| {
            if (frame.ticks == 0 or frame.ticks > 256) return error.InvalidFieldHeroAnimation;
            duration.* = frame.ticks;
            extent.* = .{ .width = std.math.cast(u8, frame.rect.w) orelse return error.InvalidFieldHeroAnimation, .height = std.math.cast(u8, frame.rect.h) orelse return error.InvalidFieldHeroAnimation };
        }
        result.clips[@backingInt(clip.direction)] = .{ .flags = clip.flags, .ticks = ticks, .bounds = bounds };
    }
    return result;
}

fn digest(allocator: std.mem.Allocator, value: anytype) ![]const u8 {
    const bytes = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(bytes);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return allocator.dupe(u8, &std.fmt.bytesToHex(hash, .lower));
}

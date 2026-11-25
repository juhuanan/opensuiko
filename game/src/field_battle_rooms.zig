//! Package-owned ordinary field scripts and the workspace borrowed by Journey.
const std = @import("std");
const field = @import("field");
const events = @import("field_events.zig");
const runtime = @import("event_runtime");
const population = @import("scene_population");
const motion = @import("opening_audience");
const ordinary = @import("field_actors");
const loader = @import("field_battle_rooms/loader.zig");

pub const BattleRooms = struct {
    pub const schema_versions = @import("field_battle_rooms/schema.zig");
    pub const path = "battle/field_events.json";
    pub const campaign_schema = schema_versions.campaign_schema;
    pub const rune_progression_schema = schema_versions.rune_progression_schema;
    pub const recruit_loading_schema = schema_versions.recruit_loading_schema;
    pub const dice_schema = schema_versions.dice_schema;
    pub const party_queue_schema = schema_versions.party_queue_schema;
    pub const party_art_schema = schema_versions.party_art_schema;
    pub const queued_music_schema = schema_versions.queued_music_schema;
    pub const entry_music_schema = schema_versions.entry_music_schema;
    pub const field_effect_schema = schema_versions.field_effect_schema;
    pub const party_dismiss_schema = schema_versions.party_dismiss_schema;
    pub const auxiliary_party_schema = schema_versions.auxiliary_party_schema;
    pub const entry_placement_schema = schema_versions.entry_placement_schema;
    pub const founding_scene_schema = schema_versions.founding_scene_schema;
    pub const founding_audio_schema = schema_versions.founding_audio_schema;
    pub const party_graphics_schema = schema_versions.party_graphics_schema;
    pub const party_select_schema = schema_versions.party_select_schema;
    pub const scene_actor_schema = schema_versions.scene_actor_schema;
    pub const fade_in_schema = schema_versions.fade_in_schema;
    pub const prop_schema = schema_versions.prop_schema;
    pub const mansion_music_schema = schema_versions.mansion_music_schema;
    pub const party_library_schema = schema_versions.party_library_schema;
    pub const party_experience_schema = schema_versions.party_experience_schema;
    pub const wheel_music_schema = schema_versions.wheel_music_schema;
    pub const wheel_motion_schema = schema_versions.wheel_motion_schema;
    pub const item_overload_schema = schema_versions.item_overload_schema;
    pub const hero_visibility_schema = schema_versions.hero_visibility_schema;
    pub const branch_history_schema = schema_versions.branch_history_schema;
    pub const current_schema = schema_versions.current_schema;
    pub const scenery_mutation_schema = schema_versions.scenery_mutation_schema;
    pub const camera_push_schema = schema_versions.camera_push_schema;
    pub const actor_owners_schema = schema_versions.actor_owners_schema;
    pub const world_entry_schema = schema_versions.world_entry_schema;
    pub const effect_render_schema = schema_versions.effect_render_schema;
    pub const music_schema = schema_versions.music_schema;
    pub const actor_clips_schema = schema_versions.actor_clips_schema;
    pub const schema = schema_versions.schema;
    pub const room_flags_schema = schema_versions.room_flags_schema;
    pub const game_over_schema = schema_versions.game_over_schema;
    pub const fade_schema = schema_versions.fade_schema;
    pub const shared_items_schema = schema_versions.shared_items_schema;
    pub const opening_route_schema = schema_versions.opening_route_schema;
    pub const sound_schema = schema_versions.sound_schema;
    pub const party_leave_schema = schema_versions.party_leave_schema;
    pub const defeat_branch_schema = schema_versions.defeat_branch_schema;
    pub const escape_branch_schema = schema_versions.escape_branch_schema;
    pub const multi_exit_schema = schema_versions.multi_exit_schema;
    pub const party_edit_schema = schema_versions.party_edit_schema;
    pub const scene_schema = schema_versions.scene_schema;
    pub const choice_schema = schema_versions.choice_schema;
    pub const portrait_schema = schema_versions.portrait_schema;
    pub const motion_schema = schema_versions.motion_schema;
    pub const dialogue_schema = schema_versions.dialogue_schema;
    pub const legacy_schema = schema_versions.legacy_schema;
    pub const max_bytes = 64 * 1024 * 1024;

    pub const Room = struct {
        room: []const u8,
        population: population.Packet,
        content: runtime.Content,
        dialogue: ?events.DialogueData = null,
        actors: []const events.RoomActor = &.{},
        queues: ?events.QueueData = null,
        party_actors: []const events.PartyActor = &.{},
        field_effect_blend: ?events.FieldEffectBlend = null,

        pub fn jsonStringify(self: Room, writer: anytype) !void {
            try writer.beginObject();
            inline for (@typeInfo(Room).@"struct".field_names) |name| {
                if (comptime !std.mem.eql(u8, name, "field_effect_blend")) {
                    try writer.objectField(name);
                    try writer.write(@field(self, name));
                } else if (self.field_effect_blend) |blend| {
                    try writer.objectField(name);
                    try writer.write(blend);
                }
            }
            try writer.endObject();
        }
    };
    pub const ActorDraw = struct { rect: field.Rect, x: f32, y: f32, depth: f32, shadow: ?field.ShadowDraw = null };
    pub const ProgramRef = struct {
        room: []const u8,
        program: []const u8,

        pub fn matches(self: ProgramRef, room: []const u8, program: []const u8) bool {
            return std.mem.eql(u8, self.room, room) and std.mem.eql(u8, self.program, program);
        }
    };
    pub const Packet = struct {
        schema: []const u8,
        rooms: []const Room,
        opening_route: ?OpeningRoute = null,
        opening_world_exit: ?ProgramRef = null,
        opening_world_exits: []const ProgramRef = &.{},
        opening_battles: []const ProgramRef = &.{},
    };
    pub const OpeningRoute = struct {
        dungeon: []const u8,
        palace: []const u8,
        first_town: []const u8,
        initial_party: []const []const u8,
    };

    bindings: []const events.Binding,
    initial_story: runtime.StoryState,
    opening_route: ?OpeningRoute = null,
    opening_world_exits: []const ProgramRef = &.{},
    opening_battles: []const ProgramRef = &.{},
    serial: u64 = 0,
    party: [6]u8 = @splat(255),
    character_levels: [population.hq_level_slots]u8 = @splat(0),
    carried_items: [6 * 9 + 16]u16 = undefined,
    equipped_items: [6 * 5]u16 = undefined,
    active_binding: events.Binding = undefined,
    session: events.Session = undefined,
    settled_actors: ?SettledActors = null,

    pub const SettledActors = struct {
        room: []const u8,
        visit: u32,
        state: ordinary.State,
    };

    pub fn retainSettledActors(self: *BattleRooms, binding: events.Binding, session: *const events.Session, visit: u32, story: ?runtime.StoryState) !void {
        if (!binding.content.hasCharacters()) return;
        const packet = binding.ordinary orelse return;
        const actors = session.ordinary_actors orelse return error.MissingFieldActorConstruction;
        if (session.busy() or session.activeTracks() != 0 or session.party_queue != null or
            session.boxes[0].phase != .closed or session.boxes[1].phase != .closed or session.text_job != null) return error.FieldEventBusy;
        try session.validate(binding);
        if (binding.needsFreshRoomActors(actors.construction_story, story)) {
            self.settled_actors = null;
            return;
        }
        self.settled_actors = .{ .room = binding.room, .visit = visit, .state = try actors.settle(packet, binding.animations) };
    }

    pub fn settledForVisit(self: *const BattleRooms, binding: events.Binding, visit: u32) ?*const SettledActors {
        const retained = if (self.settled_actors) |*value| value else return null;
        const packet = binding.ordinary orelse return null;
        return if (retained.visit == visit and std.mem.eql(u8, retained.room, binding.room) and std.mem.eql(u8, retained.state.content_sha256, packet.content_sha256)) retained else null;
    }

    pub fn constructActorsForVisit(self: *const BattleRooms, binding: events.Binding, story: runtime.StoryState, visit: u32) !?ordinary.State {
        const retained = self.settledForVisit(binding, visit) orelse return binding.constructRoomActors(story);
        return try retained.state.rebind(binding.ordinary.?, binding.animations);
    }

    pub fn drawSettledActors(binding: events.Binding, retained: *const SettledActors, camera: field.CameraOffset, out: *[64]ActorDraw) []const ActorDraw {
        var count: usize = 0;
        for (binding.room_actors, 0..) |art, index| {
            const slot = retained.state.slots[index] orelse continue;
            if (slot.phase != .active) continue;
            const avatar = slot.avatar orelse continue;
            out[count] = actorDraw(art, avatar.drawPose(), camera);
            count += 1;
        }
        return out[0..count];
    }

    pub fn bindingFor(self: *const BattleRooms, room: []const u8) ?events.Binding {
        for (self.bindings) |binding| if (std.mem.eql(u8, binding.room, room)) return binding;
        return null;
    }

    fn ordinaryProgramAt(self: *const BattleRooms, room: []const u8, story: *const runtime.StoryState, active_party_count: u8, room_flags: *const [20]u8, money: u32, cell_x: i32, cell_y: i32, direction: ?field.Direction) ?runtime.Program {
        const binding = self.bindingFor(room) orelse return null;
        if (cell_x < 0 or cell_y < 0 or cell_x > 255 or cell_y > 255) return null;
        const cell: population.Cell = .{ .x = @intCast(cell_x), .y = @intCast(cell_y) };
        const facts: population.Facts = .{
            .story = story,
            .active_party_count = active_party_count,
            .room_flags = room_flags,
            .money = money,
            .direction_mask = field.directionPadMask(direction),
        };
        entries: for (binding.population.entities) |entity| {
            if (entity.trigger != .ordinary or entity.event.status != .resolved or entity.event_selection.pointer_state == .null) continue;
            var has_coord = false;
            var unknown = false;
            for (entity.event_selection.terms) |term| {
                if (term.kind == .coordinate_range) has_coord = true;
                switch (term.kind) {
                    .party_contains, .party_excludes, .level_at_least, .has_item => {
                        unknown = true;
                        continue;
                    },
                    else => {},
                }
                if (population.eventTermMatchesWithFacts(term, facts, false, cell)) |matches| {
                    if (!matches) continue :entries;
                } else unknown = true;
            }
            if (!has_coord) continue;
            // An unknown earlier selection must not expose a later event.
            if (unknown) return null;
            const program = binding.content.program(entity.event.program_id.?) orelse continue;
            if (!story.matches(program.conditions)) continue;
            return program;
        }
        return null;
    }

    pub fn ordinaryTransitionAt(self: *const BattleRooms, room: []const u8, story: *const runtime.StoryState, active_party_count: u8, room_flags: *const [20]u8, money: u32, cell_x: i32, cell_y: i32, retained_world: ?[]const u8, direction: ?field.Direction) ?[]const u8 {
        const program = self.ordinaryProgramAt(room, story, active_party_count, room_flags, money, cell_x, cell_y, direction) orelse return null;
        if (program.commands.len == 0) return null;
        const terminal_index = program.commands.len - 1;
        for (program.commands[0..terminal_index]) |command| {
            if (command.kind != .fade_out and command.kind != .delay) return null;
        }
        const terminal = program.commands[terminal_index];
        return if (terminal.kind == .room_transition or terminal.kind == .world_transition)
            (if (terminal.retainsWorldRegion()) retained_world else terminal.destination)
        else
            null;
    }

    pub fn ordinaryPushAt(self: *const BattleRooms, room: []const u8, story: *const runtime.StoryState, active_party_count: u8, room_flags: *const [20]u8, money: u32, cell_x: i32, cell_y: i32, direction: field.Direction) ?field.Point {
        const program = self.ordinaryProgramAt(room, story, active_party_count, room_flags, money, cell_x, cell_y, direction) orelse return null;
        const push = pureCameraPush(program) orelse return null;
        return .{ .x = @mod(cell_x * 8 + @as(i32, push.dx) * push.repeats, 2048), .y = @mod(cell_y * 8 + @as(i32, push.dy) * push.repeats, 2048) };
    }

    fn pureCameraPush(program: runtime.Program) ?runtime.camera_push.Request {
        // shortcut: straight facing/push/end streams; extend when qualifying compound motion paths.
        if (program.commands.len != 3 or program.commands[0].kind != .actor_transition or
            program.commands[0].actor == null or !std.mem.eql(u8, program.commands[0].actor.?, "hero") or
            program.commands[1].kind != .camera_push or program.commands[2].kind != .end_stream) return null;
        return program.commands[1].push;
    }

    pub fn permitsSourcePush(self: *const BattleRooms, room: []const u8, x: i32, y: i32, story: *const runtime.StoryState, active_party_count: u8, room_flags: *const [20]u8, money: u32) bool {
        const binding = self.bindingFor(room) orelse return false;
        if (!binding.content.hasCameraPush()) return false;
        const package = binding.room_package orelse return false;
        const ground = package.rooms[package.roomIndex(room) orelse return false];
        if (!ground.contains(x, y) or x > 2040 or y > 2040 or @mod(x, 8) != 0 or @mod(y, 8) != 0) return false;
        // Reverse only admitted pushes, grounding the chain in an existing standing/arrival rule.
        var pending: std.StaticBitSet(256 * 256) = .empty;
        var seen: std.StaticBitSet(256 * 256) = .empty;
        pending.set(@intCast(@divExact(y, 8) * 256 + @divExact(x, 8)));
        while (pending.findFirstSet()) |index| {
            pending.unset(index);
            seen.set(index);
            const target: field.Point = .{ .x = @as(i32, @intCast(index % 256)) * 8, .y = @as(i32, @intCast(index / 256)) * 8 };
            for (binding.content.programs) |program| {
                const push = pureCameraPush(program) orelse continue;
                const ox = @mod(target.x - @as(i32, push.dx) * push.repeats, 2048);
                const oy = @mod(target.y - @as(i32, push.dy) * push.repeats, 2048);
                if (!ground.contains(ox, oy)) continue;
                var selected = false;
                for ([_]field.Direction{ .up, .right, .down, .left }) |direction| {
                    const endpoint = self.ordinaryPushAt(room, story, active_party_count, room_flags, money, @divExact(ox, 8), @divExact(oy, 8), direction) orelse continue;
                    if (endpoint.x == target.x and endpoint.y == target.y) {
                        selected = true;
                        break;
                    }
                }
                if (!selected) continue;
                if (ground.canStand(ox, oy) or package.permitsSourceArrival(room, ox, oy) or self.permitsSourceArrival(room, ox, oy)) return true;
                const origin: usize = @intCast(@divExact(oy, 8) * 256 + @divExact(ox, 8));
                if (!seen.isSet(origin)) pending.set(origin);
            }
        }
        return false;
    }

    pub fn isOpeningBattle(self: *const BattleRooms, room: []const u8, program: []const u8) bool {
        for (self.opening_battles) |ref| if (ref.matches(room, program)) return true;
        return false;
    }

    pub fn ownsOpeningEncounter(self: *const BattleRooms, room: []const u8, encounter: []const u8) bool {
        for (self.opening_battles) |ref| {
            if (!std.mem.eql(u8, ref.room, room)) continue;
            const program = self.ordinaryProgram(ref) orelse continue;
            for (program.commands) |command| {
                if (command.kind == .battle and std.mem.eql(u8, command.battle.?, encounter)) return true;
            }
        }
        return false;
    }

    pub fn initializeStory(self: *BattleRooms, binding: events.Binding, world: *field.State, story: *runtime.StoryState) !bool {
        const with_actors = for (binding.content.programs) |program| {
            if (binding.content.actorInitialization(program)) break true;
        } else false;
        var construction = if (with_actors) try binding.constructRoomActors(story.*) else null;
        const field_room: ?field.Room = if (binding.room_package) |package| package.rooms[world.room] else null;
        var scenery_state = world.room_scenery;
        var cell = population.Cell.fromPixels(world.x, world.y);
        var hero_position: field.Point = .{ .x = world.x, .y = world.y };
        var hero_facing = world.facing;
        var hero_placed = false;
        var local_flags = world.local_flags;
        var view = world.scene_view;
        var music = world.music;
        var ran = false;
        const facts: population.Facts = .{
            .story = story,
            .active_party_count = @intCast(binding.party.len),
            .party = binding.party,
            .room_flags = &local_flags.values,
            .money = world.progress.money,
        };
        entries: for (binding.population.entities) |entity| {
            if (entity.trigger != .initialization or entity.event.status != .resolved) continue;
            for (entity.event_selection.terms) |term| {
                const matches = population.eventTermMatchesWithFacts(term, facts, false, cell) orelse return error.UnsupportedFieldEventPredicate;
                if (!matches) continue :entries;
            }
            var instance = runtime.start(binding.content, story, entity.event.program_id.?) catch |err| switch (err) {
                error.EventConditionFalse => continue,
                else => return err,
            };
            // Room entry runs one pump per initializer, then continues the scan.
            const step = try runtime.step(binding.content, &instance, story, .{});
            if (step.batch) |batch| {
                for (batch.slice()) |effect| switch (effect.kind) {
                    .area_action => try local_flags.orByte(effect.area.?.id, effect.area.?.bits),
                    .set_camera => view.camera = .{ .x = effect.x.?, .y = effect.y.? },
                    .set_hero_display => view.hero = .{ .x = effect.x.?, .y = effect.y.? },
                    .field_music => music = effect.music.?,
                    .place_actor, .actor_motion, .actor_transition => {
                        const facing = effect.actorFacing();
                        if (facing) |turn| if (std.mem.eql(u8, turn.actor, "hero")) {
                            hero_facing = events.fieldDirection(turn.variant.direction());
                            continue;
                        };
                        const actors = if (construction) |*value| value else return error.MissingFieldActorConstruction;
                        const packet = binding.ordinary.?;
                        const change: struct { result: anyerror!void, if_constructed: bool } = switch (effect.kind) {
                            .place_actor => blk: {
                                const placement = effect.actorPlacement() orelse return error.InvalidEventCommand;
                                break :blk .{ .result = actors.place(packet, placement.actor, placement.x, placement.y), .if_constructed = placement.if_constructed };
                            },
                            .actor_motion => blk: {
                                const restore = effect.actorMotionRestore() orelse return error.InvalidEventCommand;
                                break :blk .{ .result = actors.restoreMotion(packet, restore.actor, restore.speed), .if_constructed = restore.if_constructed };
                            },
                            .actor_transition => blk: {
                                const turn = facing orelse return error.InvalidEventCommand;
                                break :blk .{ .result = actors.transition(packet, binding.animations, turn.actor, @backingInt(turn.variant)), .if_constructed = turn.if_constructed };
                            },
                            else => unreachable,
                        };
                        change.result catch |err| {
                            if (err != error.FieldActorNotConstructed or !change.if_constructed) return err;
                        };
                    },
                    .place_hero => {
                        const room = field_room orelse return error.MissingFieldEventRoomPackage;
                        const x = effect.x.?;
                        const y = effect.y.?;
                        if (x < 0 or x > 2040 or y < 0 or y > 2040 or
                            @mod(x, 8) != 0 or @mod(y, 8) != 0) return error.InvalidFieldEventTransition;
                        // Room initializers can stage the hero offscreen before a scene.
                        if (room.contains(x, y)) {
                            const stand = if (room.scenery_model) |model|
                                model.canStand(if (scenery_state) |*scenery| scenery else null, x, y, 0)
                            else
                                room.canStand(x, y);
                            if (!stand) return error.InvalidFieldEventTransition;
                        }
                        hero_position = .{ .x = x, .y = y };
                        hero_placed = true;
                        cell = population.Cell.fromPixels(hero_position.x, hero_position.y);
                    },
                    .scenery_stage, .scenery_append => {
                        const room = field_room orelse return error.MissingFieldEventRoomPackage;
                        const operation = effect.sceneryOperation() orelse return error.InvalidFieldSceneryState;
                        try room.mutateScenery(&scenery_state, operation);
                    },
                    else => {},
                };
                try runtime.acknowledge(binding.content, &instance, story, batch.id);
            }
            ran = true;
        }
        if (construction) |actors| self.settled_actors = .{
            .room = binding.room,
            .visit = world.room_entries,
            .state = try actors.settle(binding.ordinary.?, binding.animations),
        };
        world.room_scenery = scenery_state;
        world.local_flags = local_flags;
        world.scene_view = view;
        world.music = music;
        if (hero_placed) {
            world.x = hero_position.x;
            world.y = hero_position.y;
            world.destination = hero_position;
        }
        world.facing = hero_facing;
        return ran;
    }

    pub fn isOpeningWorldExit(self: *const BattleRooms, room: []const u8, program: []const u8) bool {
        for (self.opening_world_exits) |ref| if (ref.matches(room, program)) return true;
        return false;
    }

    pub fn permitsSourceArrival(self: *const BattleRooms, room: []const u8, x: i32, y: i32) bool {
        for (self.opening_world_exits) |ref| {
            const program = self.ordinaryProgram(ref) orelse continue;
            const terminal = program.commands[program.commands.len - 1];
            if (terminal.kind == .world_transition and !terminal.retainsWorldRegion() and std.mem.eql(u8, terminal.destination.?, room) and
                terminal.x.? * 8 == x and terminal.y.? * 8 == y) return true;
            if (terminal.kind == .world_transition and terminal.retain_world_region and terminal.x.? * 8 == x and terminal.y.? * 8 == y) {
                const binding = self.bindingFor(ref.room) orelse continue;
                const package = binding.room_package orelse continue;
                const source_area = package.rooms[package.roomIndex(ref.room).?].source_area orelse continue;
                for (package.world_entries) |entry| {
                    if (std.mem.eql(u8, entry.area, source_area) and std.mem.eql(u8, entry.world_room, room)) return true;
                }
            }
        }
        for (self.bindings) |binding| for (binding.content.programs) |program| for (program.commands) |command| {
            if (command.kind == .room_transition and command.source_arrival and std.mem.eql(u8, command.destination.?, room) and command.x == x and command.y == y) return true;
        };
        return false;
    }

    pub fn ordinaryProgram(self: *const BattleRooms, ref: ProgramRef) ?runtime.Program {
        const binding = self.bindingFor(ref.room) orelse return null;
        for (binding.population.entities) |entity| {
            if (entity.trigger != .initialization and entity.event.status == .resolved and std.mem.eql(u8, entity.event.program_id.?, ref.program)) return binding.content.program(ref.program);
        }
        return null;
    }

    pub fn ownsPartyJoin(self: *const BattleRooms, member: []const u8) bool {
        for (self.bindings) |binding| for (binding.population.entities) |entity| {
            if (entity.event.status != .resolved) continue;
            const program = binding.content.program(entity.event.program_id.?) orelse continue;
            for (program.commands) |command| {
                if (command.kind == .party_join and std.mem.eql(u8, command.character.?, member)) return true;
            }
        };
        return false;
    }

    pub fn ownsRoomExit(self: *const BattleRooms, room: []const u8) bool {
        const binding = self.bindingFor(room) orelse return false;
        for (binding.population.entities) |entity| {
            if (entity.event.status != .resolved) continue;
            const program = binding.content.program(entity.event.program_id.?) orelse continue;
            const terminal = program.commands[program.commands.len - 1];
            if ((terminal.kind == .room_transition or terminal.kind == .world_transition) and (terminal.retainsWorldRegion() or !std.mem.eql(u8, room, terminal.destination.?))) return true;
        }
        return false;
    }

    pub fn hasPortraits(self: *const BattleRooms) bool {
        for (self.bindings) |binding| if (binding.dialogue.images.len != 0) return true;
        return false;
    }

    pub fn validatePortraitAtlas(self: *const BattleRooms, width: i32, height: i32) !void {
        for (self.bindings) |binding| for (binding.dialogue.images) |image| {
            const rect = image.atlas_rect.?;
            if (width < rect.w or height < rect.h or rect.x > width - rect.w or rect.y > height - rect.h) return error.InvalidFieldPortraitAtlas;
        };
    }

    pub fn validateActorAtlas(self: *const BattleRooms, width: i32, height: i32) !void {
        for (self.bindings) |binding| for (binding.room_actors) |actor| {
            for (actor.poses) |pose| if (!inAtlas(pose.rect, width, height)) return error.InvalidFieldActorAtlas;
            if (actor.clips) |clips| for (clips) |clip| for (clip.frames) |frame| {
                if (!inAtlas(frame.rect, width, height)) return error.InvalidFieldActorAtlas;
            };
        };
        for (self.bindings) |binding| for (binding.party_actors) |actor| for (actor.clips) |clip| for (clip.frames) |frame| {
            if (!inAtlas(frame.rect, width, height)) return error.InvalidFieldPartyGraphics;
        };
    }

    pub fn drawPartyActors(binding: events.Binding, session: *const events.Session, camera: field.CameraOffset, out: *[5]ActorDraw) ![]const ActorDraw {
        // shortcut: primary sprites only, add auxiliary/shadow emissions when qualifying scene presentation.
        if (binding.party_actors.len == 0) return out[0..0];
        const queue = session.party_queue orelse return out[0..0];
        var count: usize = 0;
        for (queue.followers[0..queue.count]) |slot| {
            const follower = slot.?;
            const sprite = follower.sprite orelse continue;
            const actor = for (binding.party_actors) |actor| {
                if (actor.character == follower.character) break actor;
            } else return error.MissingFieldPartyGraphics;
            const clip = actor.clips[sprite.variant];
            if (sprite.emitted_frame >= clip.frames.len) return error.InvalidFieldPartyGraphics;
            const frame = clip.frames[sprite.emitted_frame];
            out[count] = .{ .rect = frame.rect, .x = camera.x + @as(f32, @floatFromInt(sprite.emitted_x - frame.anchor_x)), .y = camera.y + @as(f32, @floatFromInt(sprite.emitted_y - frame.anchor_y)), .depth = @as(f32, @floatFromInt(sprite.emitted_y)) / 8 };
            count += 1;
        }
        return out[0..count];
    }

    pub fn drawActors(binding: events.Binding, story: *const runtime.StoryState, session: ?*const events.Session, camera: field.CameraOffset, out: *[64]ActorDraw) []const ActorDraw {
        if (binding.room_actors.len == 0) return out[0..0];
        const actors = binding.ordinary orelse return out[0..0];
        const live = if (session) |active| if (active.ordinary_actors != null) &active.ordinary_actors.? else null else null;
        var count: usize = 0;
        for (binding.room_actors, actors.actors, 0..) |art, definition, i| {
            const pose: motion.Pose = if (live) |state| active_pose: {
                const slot = state.slots[i].?;
                if (slot.phase != .active) continue;
                break :active_pose slot.avatar.?.drawPose();
            } else initial_pose: {
                if (definition.scene_owned or !definition.selected(story, binding.party)) continue;
                if (!definition.partyGraphicAvailable(binding.party)) continue;
                const initial = definition.initialPosition(story.*);
                break :initial_pose .{ .x = initial.x, .y = initial.y, .variant = definition.variant, .frame = if (art.clips != null) 1 else 0 };
            };
            const actor_camera: field.CameraOffset = if (session) |active| blk: {
                if (active.wheel_graphics) |graphics| if (graphics.actor == i)
                    break :blk .{ .x = @floatFromInt(graphics.primary.x - pose.x), .y = @floatFromInt(graphics.primary.y - pose.y) };
                break :blk camera;
            } else camera;
            out[count] = actorDraw(art, pose, actor_camera);
            if (session) |active| if (active.wheel_graphics) |graphics| if (graphics.actor == i) {
                const frame = art.clips.?[field.wheel.shadow_variant].frames[field.wheel.shadow_frame];
                var rect = frame.rect;
                rect.w = field.wheel.shadow_crop[0];
                rect.h = field.wheel.shadow_crop[1];
                out[count].shadow = .{ .rect = rect, .points = graphics.shadowPoints() };
            };
            count += 1;
        }
        return out[0..count];
    }

    // The package arena owns the parsed content and the session workspace.
    pub fn open(allocator: std.mem.Allocator, bytes: []const u8, package: field.Package) !*BattleRooms {
        return loader.open(allocator, bytes, package);
    }
};

pub fn inAtlas(rect: field.Rect, width: i32, height: i32) bool {
    return rect.w > 0 and rect.h > 0 and rect.x >= 0 and rect.y >= 0 and
        rect.w <= width and rect.h <= height and rect.x <= width - rect.w and rect.y <= height - rect.h;
}

fn actorDraw(art: events.RoomActor, pose: motion.Pose, camera: field.CameraOffset) BattleRooms.ActorDraw {
    const frame = if (art.clips) |clips| clips[pose.variant].frames[pose.frame] else art.poses[pose.variant];
    return .{ .rect = frame.rect, .x = camera.x + @as(f32, @floatFromInt(pose.x - frame.anchor_x)), .y = camera.y + @as(f32, @floatFromInt(pose.y - frame.anchor_y)), .depth = @as(f32, @floatFromInt(pose.y)) / 8 };
}

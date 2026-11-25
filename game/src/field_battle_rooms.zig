//! Package-owned ordinary field scripts and the workspace borrowed by Journey.
const std = @import("std");
const field = @import("field");
const events = @import("field_events.zig");
const runtime = @import("event_runtime");
const population = @import("scene_population");
const motion = @import("opening_audience");
const ordinary = @import("field_actors");
const data = @import("field_events_data");

pub const BattleRooms = struct {
    pub const path = "battle/field_events.json";
    pub const campaign_schema = "suikoden-battle-field-events/19";
    pub const rune_progression_schema = "suikoden-battle-field-events/20";
    pub const recruit_loading_schema = "suikoden-battle-field-events/21";
    pub const dice_schema = "suikoden-battle-field-events/22";
    pub const party_queue_schema = "suikoden-battle-field-events/23";
    pub const party_art_schema = "suikoden-battle-field-events/24";
    pub const queued_music_schema = "suikoden-battle-field-events/27";
    pub const entry_music_schema = "suikoden-battle-field-events/28";
    pub const field_effect_schema = "suikoden-battle-field-events/29";
    pub const party_dismiss_schema = "suikoden-battle-field-events/30";
    pub const auxiliary_party_schema = "suikoden-battle-field-events/31";
    pub const entry_placement_schema = "suikoden-battle-field-events/32";
    pub const founding_scene_schema = "suikoden-battle-field-events/33";
    pub const founding_audio_schema = "suikoden-battle-field-events/34";
    pub const party_graphics_schema = "suikoden-battle-field-events/35";
    pub const party_select_schema = "suikoden-battle-field-events/37";
    pub const scene_actor_schema = "suikoden-battle-field-events/38";
    pub const fade_in_schema = "suikoden-battle-field-events/39";
    pub const prop_schema = "suikoden-battle-field-events/40";
    pub const mansion_music_schema = "suikoden-battle-field-events/41";
    pub const party_library_schema = "suikoden-battle-field-events/42";
    pub const party_experience_schema = "suikoden-battle-field-events/43";
    pub const wheel_music_schema = "suikoden-battle-field-events/44";
    pub const wheel_motion_schema = "suikoden-battle-field-events/45";
    pub const item_overload_schema = "suikoden-battle-field-events/46";
    pub const hero_visibility_schema = "suikoden-battle-field-events/47";
    pub const branch_history_schema = "suikoden-battle-field-events/48";
    pub const current_schema = "suikoden-battle-field-events";
    pub const scenery_mutation_schema = "suikoden-battle-field-events/52";
    pub const camera_push_schema = "suikoden-battle-field-events/51";
    pub const actor_owners_schema = "suikoden-battle-field-events/50";
    pub const world_entry_schema = "suikoden-battle-field-events/49";
    pub const effect_render_schema = "suikoden-battle-field-events/36";
    pub const music_schema = "suikoden-battle-field-events/26";
    pub const actor_clips_schema = "suikoden-battle-field-events/25";
    pub const schema = "suikoden-battle-field-events/18";
    pub const room_flags_schema = "suikoden-battle-field-events/17";
    pub const game_over_schema = "suikoden-battle-field-events/16";
    pub const fade_schema = "suikoden-battle-field-events/15";
    pub const shared_items_schema = "suikoden-battle-field-events/14";
    pub const opening_route_schema = "suikoden-battle-field-events/13";
    pub const sound_schema = "suikoden-battle-field-events/12";
    pub const party_leave_schema = "suikoden-battle-field-events/11";
    pub const defeat_branch_schema = "suikoden-battle-field-events/10";
    pub const escape_branch_schema = "suikoden-battle-field-events/9";
    pub const multi_exit_schema = "suikoden-battle-field-events/8";
    pub const party_edit_schema = "suikoden-battle-field-events/7";
    pub const scene_schema = "suikoden-battle-field-events/6";
    pub const choice_schema = "suikoden-battle-field-events/5";
    pub const portrait_schema = "suikoden-battle-field-events/4";
    pub const motion_schema = "suikoden-battle-field-events/3";
    pub const dialogue_schema = "suikoden-battle-field-events/2";
    pub const legacy_schema = "suikoden-battle-field-events/1";
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
                        const actor = effect.actor.?;
                        if (effect.kind == .actor_transition and std.mem.eql(u8, actor, "hero")) {
                            hero_facing = ([_]field.Direction{ .down, .up, .left, .right })[effect.transition.?];
                            continue;
                        }
                        const actors = if (construction) |*value| value else return error.MissingFieldActorConstruction;
                        const packet = binding.ordinary.?;
                        const result = switch (effect.kind) {
                            .place_actor => actors.place(packet, actor, effect.x, effect.y),
                            .actor_motion => actors.restoreMotion(packet, actor, effect.value.?),
                            .actor_transition => actors.transition(packet, binding.animations, actor, effect.transition.?),
                            else => unreachable,
                        };
                        result catch |err| {
                            if (err != error.FieldActorNotConstructed or effect.if_actor_constructed != true) return err;
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
                        try room.mutateScenery(&scenery_state, effect);
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

    fn ordinaryProgram(self: *const BattleRooms, ref: ProgramRef) ?runtime.Program {
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
        const parsed = try std.json.parseFromSlice(Packet, allocator, bytes, .{ .allocate = .alloc_always });
        const packet = parsed.value;
        const current_format = std.mem.eql(u8, packet.schema, current_schema);
        const with_scenery_mutations = current_format or std.mem.eql(u8, packet.schema, scenery_mutation_schema);
        const with_camera_push = with_scenery_mutations or std.mem.eql(u8, packet.schema, camera_push_schema);
        const with_actor_owners = with_camera_push or std.mem.eql(u8, packet.schema, actor_owners_schema);
        const with_hero_visibility = with_actor_owners or std.mem.eql(u8, packet.schema, world_entry_schema) or std.mem.eql(u8, packet.schema, branch_history_schema) or std.mem.eql(u8, packet.schema, hero_visibility_schema);
        const with_item_overload = with_hero_visibility or std.mem.eql(u8, packet.schema, item_overload_schema);
        const with_wheel_motion = with_item_overload or std.mem.eql(u8, packet.schema, wheel_motion_schema);
        const with_wheel_music = with_wheel_motion or std.mem.eql(u8, packet.schema, wheel_music_schema);
        const with_party_experience = with_wheel_music or std.mem.eql(u8, packet.schema, party_experience_schema);
        const with_party_library = with_party_experience or std.mem.eql(u8, packet.schema, party_library_schema);
        const with_mansion_music = with_party_library or std.mem.eql(u8, packet.schema, mansion_music_schema);
        const with_props = with_mansion_music or std.mem.eql(u8, packet.schema, prop_schema);
        const with_fade_in = with_props or std.mem.eql(u8, packet.schema, fade_in_schema);
        const with_scene_actors = with_fade_in or std.mem.eql(u8, packet.schema, scene_actor_schema);
        const with_party_select = with_scene_actors or std.mem.eql(u8, packet.schema, party_select_schema);
        const with_effect_render = with_party_select or std.mem.eql(u8, packet.schema, effect_render_schema);
        const with_party_graphics = with_effect_render or std.mem.eql(u8, packet.schema, party_graphics_schema);
        const with_founding_audio = with_party_graphics or std.mem.eql(u8, packet.schema, founding_audio_schema);
        const with_founding_scene = with_founding_audio or std.mem.eql(u8, packet.schema, founding_scene_schema);
        const with_entry_placement = with_founding_scene or std.mem.eql(u8, packet.schema, entry_placement_schema);
        const with_auxiliary_party = with_entry_placement or std.mem.eql(u8, packet.schema, auxiliary_party_schema);
        const with_party_dismiss = with_auxiliary_party or std.mem.eql(u8, packet.schema, party_dismiss_schema);
        const with_field_effects = with_party_dismiss or std.mem.eql(u8, packet.schema, field_effect_schema);
        const with_entry_music = with_field_effects or std.mem.eql(u8, packet.schema, entry_music_schema);
        const with_queued_music = with_entry_music or std.mem.eql(u8, packet.schema, queued_music_schema);
        const with_music = with_queued_music or std.mem.eql(u8, packet.schema, music_schema);
        const with_actor_clips = with_music or std.mem.eql(u8, packet.schema, actor_clips_schema);
        const with_party_art = with_actor_clips or std.mem.eql(u8, packet.schema, party_art_schema);
        const with_party_queue = with_party_art or std.mem.eql(u8, packet.schema, party_queue_schema);
        const with_dice = with_party_queue or std.mem.eql(u8, packet.schema, dice_schema);
        const with_recruit_loading = with_dice or std.mem.eql(u8, packet.schema, recruit_loading_schema);
        const with_rune_progression = with_recruit_loading or std.mem.eql(u8, packet.schema, rune_progression_schema);
        const with_campaign = with_rune_progression or std.mem.eql(u8, packet.schema, campaign_schema);
        const with_actors = with_campaign or std.mem.eql(u8, packet.schema, schema);
        const with_room_flags = with_actors or std.mem.eql(u8, packet.schema, room_flags_schema);
        const with_game_over = with_room_flags or std.mem.eql(u8, packet.schema, game_over_schema);
        const with_fade = with_game_over or std.mem.eql(u8, packet.schema, fade_schema);
        const with_shared_items = with_fade or std.mem.eql(u8, packet.schema, shared_items_schema);
        const with_opening_route = with_shared_items or std.mem.eql(u8, packet.schema, opening_route_schema);
        const with_sound = with_opening_route or std.mem.eql(u8, packet.schema, sound_schema);
        const with_party_leave = with_sound or std.mem.eql(u8, packet.schema, party_leave_schema);
        const with_defeat_branch = with_party_leave or std.mem.eql(u8, packet.schema, defeat_branch_schema);
        const with_escape_branch = with_defeat_branch or std.mem.eql(u8, packet.schema, escape_branch_schema);
        const with_multiple_exits = with_escape_branch or std.mem.eql(u8, packet.schema, multi_exit_schema);
        const with_party_edits = with_multiple_exits or std.mem.eql(u8, packet.schema, party_edit_schema);
        const allows_scenes = with_party_edits or std.mem.eql(u8, packet.schema, scene_schema);
        const with_choice = allows_scenes or std.mem.eql(u8, packet.schema, choice_schema);
        const with_portraits = with_choice or std.mem.eql(u8, packet.schema, portrait_schema);
        const with_motion = with_portraits or std.mem.eql(u8, packet.schema, motion_schema);
        const extended = with_motion or std.mem.eql(u8, packet.schema, dialogue_schema);
        if ((!extended and !std.mem.eql(u8, packet.schema, legacy_schema)) or packet.rooms.len == 0 or packet.rooms.len > package.rooms.len) return error.InvalidBattleFieldEvents;
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
        const exits = if (packet.opening_world_exit) |exit| try allocator.dupe(ProgramRef, &.{exit}) else packet.opening_world_exits;
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
            if (room.content.needsWorldContext() and ((!std.mem.eql(u8, packet.schema, world_entry_schema) and !with_actor_owners) or !package.supportsWorldEntries())) return error.UnsupportedBattleFieldCommand;
            if (room.content.hasBranchHistory() and !std.mem.eql(u8, packet.schema, branch_history_schema) and (!std.mem.eql(u8, packet.schema, world_entry_schema) and !with_actor_owners)) return error.UnsupportedBattleFieldCommand;
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
};

fn inAtlas(rect: field.Rect, width: i32, height: i32) bool {
    return rect.w > 0 and rect.h > 0 and rect.x >= 0 and rect.y >= 0 and
        rect.w <= width and rect.h <= height and rect.x <= width - rect.w and rect.y <= height - rect.h;
}

fn actorDraw(art: events.RoomActor, pose: motion.Pose, camera: field.CameraOffset) BattleRooms.ActorDraw {
    const frame = if (art.clips) |clips| clips[pose.variant].frames[pose.frame] else art.poses[pose.variant];
    return .{ .rect = frame.rect, .x = camera.x + @as(f32, @floatFromInt(pose.x - frame.anchor_x)), .y = camera.y + @as(f32, @floatFromInt(pose.y - frame.anchor_y)), .depth = @as(f32, @floatFromInt(pose.y)) / 8 };
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
                    if (!inAtlas(frame.rect, 4096, 4096) or frame.rect.w > 128 or frame.rect.h > 128 or frame.anchor_x < 0 or frame.anchor_x > frame.rect.w or frame.anchor_y < 0 or frame.anchor_y > frame.rect.h) return error.InvalidFieldActorAtlas;
                }
                if (!std.meta.eql(actor.poses[direction], clip.frames[clip.idle_frame])) return error.InvalidFieldActorAtlas;
            }
            animation.* = try fieldAnimation(allocator, actor.id, &clips);
            continue;
        }
        for (actor.poses, &animation.clips) |pose, *clip| {
            if (!inAtlas(pose.rect, 4096, 4096) or pose.rect.w > 128 or pose.rect.h > 128 or
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
            if (!content.hasSceneryMutations() or
                (command.kind == .scenery_restore and program.entry != .ordinary) or
                (program.entry == .initialization and !content.actorInitialization(program))) return error.UnsupportedBattleFieldCommand;
            const room = motion_room orelse return error.UnsupportedBattleFieldCommand;
            const model = room.scenery_model orelse return error.InvalidFieldSceneryState;
            const object = command.scenery_object.?;
            if (command.kind == .scenery_append) {
                if (object < model.initial_count or object >= model.objects.len) return error.UnknownFieldSceneryTemplate;
            } else if (object >= field.scenery.max_instances or (model.objects.len == model.initial_count and object >= model.initial_count)) {
                return error.UnknownFieldSceneryInstance;
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
                const camera: @import("field_events_state.zig").ScriptedCamera = .{
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
                const room = package.roomIndex(command.destination.?) orelse return error.UnknownEventRoom;
                if (command.world_entry) |entry_id| {
                    const entry = package.world_entries[package.worldEntryIndex(entry_id) orelse return error.MissingWorldEntry];
                    if (!std.mem.eql(u8, entry.area, package.rooms[room].source_area orelse "")) return error.InvalidFieldEventTransition;
                } else if (command.world_point) |point| {
                    for (package.world_entries) |entry| {
                        if (entry.point == point and std.mem.eql(u8, entry.area, package.rooms[room].source_area orelse "")) break;
                    } else return error.MissingWorldEntry;
                }
                if (!package.rooms[room].contains(command.x.?, command.y.?) or
                    (!command.source_arrival and !package.rooms[room].canStand(command.x.?, command.y.?))) return error.InvalidFieldEventTransition;
            },
            .world_transition => {
                if (!with_campaign) return error.UnsupportedBattleFieldCommand;
                const package = room_package orelse return error.UnsupportedBattleFieldCommand;
                if (command.return_to_entry) {
                    if (package.world_entries.len == 0) return error.MissingWorldEntry;
                } else if (command.retain_world_region) {
                    var matched = false;
                    for (package.world_entries) |entry| {
                        if (!std.mem.eql(u8, entry.area, (motion_room orelse return error.UnsupportedBattleFieldCommand).source_area orelse "")) continue;
                        const room = package.roomIndex(entry.world_room) orelse return error.UnknownEventRoom;
                        if (!package.rooms[room].contains(command.x.? * 8, command.y.? * 8)) return error.InvalidFieldEventTransition;
                        matched = true;
                    }
                    if (!matched) return error.MissingWorldEntry;
                } else {
                    const room = package.roomIndex(command.destination.?) orelse return error.UnknownEventRoom;
                    if (!package.rooms[room].contains(command.x.? * 8, command.y.? * 8)) return error.InvalidFieldEventTransition;
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

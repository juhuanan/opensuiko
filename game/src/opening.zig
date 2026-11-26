const std = @import("std");
const field = @import("field");
const events = @import("opening_events");
pub const audience = @import("opening_audience");
pub const audio = @import("opening_audio.zig");
pub const art = @import("opening_art.zig");
pub const presentation = @import("opening_presentation.zig");
pub const json = @import("opening_data").json;
pub const BaseStats = struct { power: u8, skill: u8, defense: u8, speed: u8, magic: u8, luck: u8 };
pub const Equipment = struct { head: ?field.items.Id = null, body: ?field.items.Id = null, shield: ?field.items.Id = null, accessory_one: ?field.items.Id = null, accessory_two: ?field.items.Id = null };
pub const Hero = struct {
    member: field.game_state.CharacterRecord,
    level: u8,
    experience: u16,
    base_stats: BaseStats,
    weapon_level: u8,
    rune: ?[]const u8,
    equipped: Equipment,

    fn validate(self: Hero) !void {
        var members = [_]field.game_state.Member{self.member.character()};
        try (field.game_state.Progress{ .party = .init(&members), .money = 0 }).validate();
        if (!std.mem.eql(u8, self.member.id, "hero") or self.level == 0 or self.level > 99 or self.weapon_level == 0 or self.weapon_level > 16) return error.InvalidOpeningHero;
        // Only the rune-free opening seed is integrated; later attachment needs shared rune rules.
        if (self.rune != null) return error.UnsupportedOpeningRune;
        var worn: [5]?usize = @splat(null);
        inline for (.{ "head", "body", "shield", "accessory_one", "accessory_two" }, 0..) |slot, i| {
            if (@field(self.equipped, slot)) |id| {
                for (self.member.inventory.slots, 0..) |item, index| {
                    if (item != null and item.?.id == id) {
                        worn[i] = index;
                        break;
                    }
                }
                if (worn[i] == null) return error.UnownedOpeningEquipment;
                for (worn[0..i]) |other| if (other != null and other == worn[i]) return error.DuplicateOpeningEquipment;
            }
        }
    }
};
pub const Size = struct { width: i32, height: i32 };
pub const Content = struct {
    schema: []const u8,
    room: []const u8,
    position: field.Point,
    camera: field.Point,
    viewport: Size,
    camera_bias: field.Point,
    money: u32,
    hero: Hero,
    rooms: []const field.Room,

    pub fn roomById(self: Content, id: []const u8) ?field.Room {
        for (self.rooms) |room| if (std.mem.eql(u8, room.id, id)) return room;
        return null;
    }
    pub fn cameraFor(self: Content, room: field.Room, point: field.Point) field.Point {
        return .{ .x = std.math.clamp(point.x - self.camera_bias.x, 0, room.width - self.viewport.width), .y = std.math.clamp(point.y - self.camera_bias.y, 0, room.height - self.viewport.height) };
    }
    pub fn validate(self: Content) !void {
        if (!std.mem.eql(u8, self.schema, "suikoden-opening/1")) return error.UnsupportedOpeningSchema;
        if (self.rooms.len != 2 or self.money > field.game_state.max_money or self.viewport.width != 320 or self.viewport.height != 240 or self.camera_bias.x != 152 or self.camera_bias.y != 112) return error.InvalidOpeningContent;
        try self.hero.validate();
        for (self.rooms, 0..) |room, i| {
            if (room.width < self.viewport.width or room.height < self.viewport.height or room.width > 2048 or room.height > 2048 or @mod(room.width, 8) != 0 or @mod(room.height, 8) != 0) return error.InvalidOpeningRoom;
            if (room.walkable.len != @as(usize, @intCast(@divTrunc(room.width, 8) * @divTrunc(room.height, 8)))) return error.InvalidOpeningRoom;
            for (room.walkable) |cell| if (cell != '0' and cell != '1') return error.InvalidOpeningRoom;
            for (self.rooms[0..i]) |other| if (std.mem.eql(u8, room.id, other.id)) return error.DuplicateOpeningRoom;
            if (room.draws.len != 0 or room.npcs.len != 0 or room.events.len != 0) return error.UnsupportedOpeningPresentation;
        }
        for (self.rooms) |room| {
            for (room.exits) |exit| {
                const target = self.roomById(exit.room) orelse return error.UnknownOpeningRoom;
                if (exit.x < 0 or exit.y < 0 or exit.w <= 0 or exit.h <= 0 or exit.x >= room.width or exit.y >= room.height or exit.w > room.width - exit.x or exit.h > room.height - exit.y or exit.direction != null or exit.conditions != null or !target.canStand(exit.spawn_x, exit.spawn_y)) return error.InvalidOpeningExit;
            }
        }
        const room = self.roomById(self.room) orelse return error.UnknownOpeningRoom;
        if (!std.mem.eql(u8, self.room, "vaa_room_2") or self.roomById("vaa_room_1") == null or !room.canStand(self.position.x, self.position.y)) return error.InvalidOpeningEntry;
        if (!std.meta.eql(self.cameraFor(room, self.position), self.camera)) return error.InvalidOpeningCamera;
    }
};
pub fn load(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Content) {
    if (bytes.len > 128 * 1024) return error.OpeningContentTooLarge;
    const parsed = try std.json.parseFromSlice(Content, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    try parsed.value.validate();
    return parsed;
}

// Internal pre-audience state only; original save/load rebuilding is not established.
pub const State = struct {
    schema: []const u8 = "suikoden-opening-state/1",
    room: []const u8,
    position: field.Point,
    camera: field.Point,
    money: u32,
    hero: Hero,
    events: events.State,

    pub fn start(content: Content, event_content: events.Content) !struct { state: State, effects: events.Initialization } {
        try content.validate();
        if (!std.mem.eql(u8, content.room, event_content.room)) return error.OpeningEventRoomMismatch;
        var event_state = try events.State.init(event_content);
        if (event_state.flags.story_0006) return error.InvalidOpeningEntry;
        const effects = try event_state.initializeRoom(event_content);
        return .{ .state = .{ .room = content.room, .position = content.position, .camera = content.camera, .money = content.money, .hero = content.hero, .events = event_state }, .effects = effects };
    }
    pub fn apply(self: State, content: Content, event_content: events.Content, destination: *State) !void {
        try content.validate();
        try event_content.validate();
        if (!std.mem.eql(u8, content.room, event_content.room)) return error.OpeningEventRoomMismatch;
        if (!std.mem.eql(u8, self.schema, "suikoden-opening-state/1")) return error.UnsupportedOpeningState;
        // Actor staging, movement and room transitions are not yet connected.
        if (!std.mem.eql(u8, self.room, content.room) or !std.meta.eql(self.position, content.position) or !std.meta.eql(self.camera, content.camera) or self.money != content.money) return error.InvalidOpeningState;
        try self.hero.validate();
        if (!self.events.initialized or self.events.flags.story_0006 or self.events.active) return error.UnsupportedOpeningStage;
        var next = self;
        next.schema = "suikoden-opening-state/1";
        next.room = content.room;
        next.hero.member.id = content.hero.member.id;
        next.hero.member.name = content.hero.member.name;
        if (!std.meta.eql(next.hero, content.hero)) return error.UnsupportedOpeningStage;
        try self.events.apply(event_content, &next.events);
        const entry = try State.start(content, event_content);
        if (!std.meta.eql(next.events, entry.state.events)) return error.UnsupportedOpeningStage;
        destination.* = next;
    }
};

pub const Input = struct { direction: ?audience.Direction = null, interact: bool = false, dialogue: audience.Input = .{} };
pub const Update = struct { cue: ?u16 = null, audience_started: bool = false, audience_finished: bool = false, room_changed: bool = false };

// Grid interaction from the original actor predicate, with positions in pixels.
pub fn canInteract(hero: field.Point, facing: audience.Direction, actor: field.Point) bool {
    const target = switch (facing) {
        .down => field.Point{ .x = hero.x, .y = hero.y + 16 },
        .up => field.Point{ .x = hero.x, .y = hero.y - 8 },
        .left => field.Point{ .x = hero.x - 16, .y = hero.y },
        .right => field.Point{ .x = hero.x + 16, .y = hero.y },
    };
    return switch (facing) {
        .down, .up => actor.y == target.y and actor.x >= target.x - 8 and actor.x <= target.x + 8,
        .left, .right => actor.x == target.x and actor.y >= target.y and actor.y <= target.y + 8,
    };
}
fn directionFor(variant: u8) audience.Direction {
    return switch (variant) {
        0 => .down,
        1 => .up,
        2 => .left,
        3 => .right,
        else => unreachable,
    };
}

pub const Live = struct {
    seed: State,
    stage: audience.State,
    elapsed: u32 = 0,
    exited_audience_room: bool = false,
    pending_exit: ?struct { exit: field.Exit, step: enum { cue, handoff } = .cue } = null,

    pub fn start(content: Content, event_content: events.Content, script: audience.Content, scene: art.Scene) !Live {
        return startNamed(content, event_content, script, scene, "Tir");
    }
    pub fn startNamed(content: Content, event_content: events.Content, script: audience.Content, scene: art.Scene, player_name: []const u8) !Live {
        try scene.validate(content.rooms, script);
        const entry = try State.start(content, event_content);
        var stage = try audience.State.start(script, .{ .hero = .{ .x = content.position.x, .y = content.position.y }, .camera = .{ .x = content.camera.x, .y = content.camera.y }, .width = content.roomById(content.room).?.width, .height = content.roomById(content.room).?.height, .player_name = player_name });
        stage.active = false;
        const room_art = scene.roomById(content.room).?;
        for (stage.actors[0..stage.actor_count]) |*actor| room_art.resolve(actor);
        return .{ .seed = entry.state, .stage = stage };
    }
    pub fn hero(self: *Live) *audience.Avatar {
        return &self.stage.actors[self.stage.hero];
    }
    pub fn canPause(self: *const Live) bool {
        return !self.stage.active and self.pending_exit == null and !self.stage.actors[self.stage.hero].motion.moving() and (self.stage.follower == null or !self.stage.follower.?.actor.motion.moving());
    }
    pub fn blocked(self: *const Live, content: Content, scene: art.Scene, x: i32, y: i32) bool {
        const height = if (self.stage.actors[self.stage.hero].support) |support| support.height else 0;
        const surface = scene.roomById(self.seed.room).?.surfaceAt(x, y, height);
        if (!(if (surface) |cell| cell.walkable else content.roomById(self.seed.room).?.canStand(x, y))) return true;

        for (self.stage.actors[0..self.stage.actor_count], 0..) |actor, i| {
            if (i == self.stage.hero or !actor.attached or (if (actor.support) |support| support.height else @as(u8, 0)) != (if (self.stage.actors[self.stage.hero].support) |support| support.height else @as(u8, 0))) continue;
            if (actor.motion.x >= x - 8 and actor.motion.x <= x + 8 and actor.motion.y >= y and actor.motion.y <= y + 8) return true;
        }
        return false;
    }
    fn enter(self: *Live, content: Content, script: audience.Content, scene: art.Scene, exit: field.Exit) !void {
        const room = content.roomById(exit.room).?;
        const art_room = scene.roomById(exit.room).?;
        const definitions = if (self.stage.audience_complete) art_room.after_audience_actors else art_room.actors;
        const player = self.hero().*;
        self.stage.actors = @splat(audience.Avatar.empty);
        self.stage.actor_count = @intCast(definitions.len + 2);
        self.stage.hero = @intCast(definitions.len);
        self.stage.double = self.stage.hero + 1;
        for (definitions, 0..) |definition, i| {
            const clip = script.animation(definition.graphic).?.clips[definition.variant];
            self.stage.actors[i] = .{ .id = definition.id, .graphic = definition.graphic, .motion = .{ .x = definition.x, .y = definition.y, .speed = definition.motion }, .variant = definition.variant, .attached = definition.attached, .auto_animate = definition.auto_animate, .sprite = audience.SpriteAnimation.start(clip) };
        }
        self.stage.actors[self.stage.hero] = player;
        self.hero().motion = .{ .x = exit.spawn_x, .y = exit.spawn_y, .speed = 2 };
        self.hero().pose = null;
        self.hero().support = null;
        self.stage.width = room.width;
        self.stage.height = room.height;
        self.seed.room = room.id;
        const camera = content.cameraFor(room, .{ .x = exit.spawn_x, .y = exit.spawn_y });
        self.stage.camera = .{ .x = camera.x, .y = camera.y };
        if (self.stage.following_teo) self.stage.follower = try audience.Follower.start(script, self.hero().motion);
        for (self.stage.actors[0..self.stage.actor_count]) |*actor| art_room.resolve(actor);
        if (self.stage.follower) |*follower| art_room.resolve(&follower.actor);
        self.exited_audience_room = true;
    }
    pub fn tick(self: *Live, content: Content, script: audience.Content, scene: art.Scene, input: Input) !Update {
        var output: Update = .{};
        var previous: [66]audience.Point = undefined;
        for (self.stage.actors, 0..) |actor, index| previous[index] = .{ .x = actor.motion.x, .y = actor.motion.y };
        const old_room = self.seed.room;
        const old_follower = if (self.stage.follower) |follower| audience.Point{ .x = follower.actor.motion.x, .y = follower.actor.motion.y } else null;
        if (self.stage.active) {
            const result = try self.stage.tick(script, input.dialogue);
            output.cue = result.cue;
            output.audience_finished = result.completed;
            self.seed.events.flags.story_0006 = self.stage.audience_complete;
        } else if (self.pending_exit) |*pending| {
            if (pending.step == .cue) {
                output.cue = 0x508;
                pending.step = .handoff;
                self.stage.allow_player_animation = false;
                self.stage.fieldPass(script);
            } else {
                const exit = pending.exit;
                try self.enter(content, script, scene, exit);
                self.pending_exit = null;
                self.stage.allow_player_animation = true;
                output.room_changed = true;
            }
        } else {
            const player = self.hero();
            if (!player.motion.moving()) {
                const room = content.roomById(self.seed.room).?;
                for (room.exits) |exit| if (player.motion.x >= exit.x and player.motion.x < exit.x + exit.w and player.motion.y >= exit.y and player.motion.y < exit.y + exit.h) {
                    self.pending_exit = .{ .exit = exit };
                    break;
                };
                if (self.pending_exit == null and input.interact and !self.stage.audience_complete and std.mem.eql(u8, self.seed.room, "vaa_room_2")) {
                    const teo = try self.stage.avatar("scene_actor_12");
                    if (teo.attached and canInteract(.{ .x = player.motion.x, .y = player.motion.y }, directionFor(player.variant), .{ .x = teo.motion.x, .y = teo.motion.y })) {
                        try teo.face(script, switch (directionFor(player.variant)) {
                            .down => .up,
                            .up => .down,
                            .left => .right,
                            .right => .left,
                        });
                        self.stage.active = true;
                        output.audience_started = true;
                    }
                }
                if (!self.stage.active and self.pending_exit == null) if (input.direction) |direction| {
                    try player.face(script, direction);
                    var next = player.motion;
                    next.step(direction);
                    if (!self.blocked(content, scene, next.x, next.y)) {
                        if (self.stage.follower) |*follower| try follower.beforeHeroStep(script, player.motion);
                        player.motion = next;
                        player.motion.speed = 2;
                    }
                };
            }
            const before = self.hero().motion;
            const camera = content.cameraFor(content.roomById(self.seed.room).?, .{ .x = before.x + before.offset_x, .y = before.y + before.offset_y });
            self.stage.camera = .{ .x = camera.x, .y = camera.y };
            self.stage.allow_player_animation = true;
            self.stage.fieldPass(script);
        }
        if (std.mem.eql(u8, old_room, self.seed.room)) {
            const room_art = scene.roomById(self.seed.room).?;
            for (self.stage.actors[0..self.stage.actor_count], 0..) |*actor, index| if (actor.motion.x != previous[index].x or actor.motion.y != previous[index].y) room_art.resolve(actor);
            if (self.stage.follower) |*follower| if (old_follower == null or follower.actor.motion.x != old_follower.?.x or follower.actor.motion.y != old_follower.?.y) room_art.resolve(&follower.actor);
        }
        self.seed.position = .{ .x = self.hero().motion.x, .y = self.hero().motion.y };
        self.seed.camera = .{ .x = self.stage.camera.x, .y = self.stage.camera.y };
        self.elapsed += 1;
        return output;
    }
};

// Internal boundary checkpoint for this candidate, not the original memory-card save policy.
pub const ExitCheckpoint = struct {
    schema: []const u8 = "suikoden-opening-exit-checkpoint/1",
    room: []const u8,
    position: field.Point,
    facing: audience.Direction,
    player_name: []const u8 = "Tir",
    audience_complete: bool,
    following_teo: bool,

    pub fn capture(live: *Live) !ExitCheckpoint {
        if (live.stage.active or live.pending_exit != null or live.hero().motion.moving() or (live.stage.follower != null and live.stage.follower.?.actor.motion.moving())) return error.GameBusy;
        if (!live.exited_audience_room or !live.stage.audience_complete or !live.stage.following_teo or !live.seed.events.flags.story_0006 or !std.mem.eql(u8, live.seed.room, "vaa_room_1")) return error.UnsupportedOpeningCheckpointStage;
        return .{ .room = live.seed.room, .position = live.seed.position, .facing = directionFor(live.hero().variant), .player_name = live.stage.playerName(), .audience_complete = true, .following_teo = true };
    }
    pub fn apply(self: ExitCheckpoint, content: Content, event_content: events.Content, script: audience.Content, scene: art.Scene, destination: *Live) !void {
        if (!std.mem.eql(u8, self.schema, "suikoden-opening-exit-checkpoint/1")) return error.UnsupportedOpeningCheckpoint;
        if (!std.mem.eql(u8, self.room, "vaa_room_1") or !self.audience_complete or !self.following_teo or !content.roomById(self.room).?.canStand(self.position.x, self.position.y)) return error.InvalidOpeningCheckpoint;
        if (self.player_name.len == 0 or self.player_name.len > 32) return error.InvalidOpeningCheckpoint;
        var next = try Live.startNamed(content, event_content, script, scene, self.player_name);
        next.stage.audience_complete = true;
        next.stage.following_teo = true;
        next.seed.events.flags.story_0006 = true;
        try next.enter(content, script, scene, .{ .x = 0, .y = 0, .w = 8, .h = 8, .room = self.room, .spawn_x = self.position.x, .spawn_y = self.position.y });
        if (next.blocked(content, scene, self.position.x, self.position.y)) return error.InvalidOpeningCheckpoint;
        try next.hero().face(script, self.facing);
        next.seed.position = self.position;
        const camera = content.cameraFor(content.roomById(next.seed.room).?, self.position);
        next.seed.camera = camera;
        next.stage.camera = .{ .x = camera.x, .y = camera.y };
        destination.* = next;
    }
};

// Approved prototype field saves. Actor resources are rebuilt, not serialized as a VM memory image.
pub const Snapshot = struct {
    schema: []const u8 = "suikoden-opening-save-state/2",
    room: []const u8,
    position: field.Point,
    facing: audience.Direction,
    money: u32,
    hero: Hero,
    audience_complete: bool,
    following_teo: bool,
    player_name: []const u8 = "Tir",
    elapsed_ticks: u32,
    support: ?audience.Support = null,

    pub fn capture(live: *const Live, content: Content) !Snapshot {
        const player = live.stage.actors[live.stage.hero];
        if (!live.canPause()) return error.GameBusy;
        if (live.seed.events.flags.story_0006 != live.stage.audience_complete) return error.InvalidOpeningState;
        const result: Snapshot = .{ .room = live.seed.room, .position = live.seed.position, .facing = directionFor(player.variant), .money = live.seed.money, .hero = live.seed.hero, .audience_complete = live.stage.audience_complete, .following_teo = live.stage.following_teo, .player_name = live.stage.playerName(), .elapsed_ticks = live.elapsed, .support = player.support };
        try result.validate(content);
        return result;
    }
    pub fn validate(self: Snapshot, content: Content) !void {
        if (!std.mem.eql(u8, self.schema, "suikoden-opening-save-state/2")) return error.UnsupportedOpeningSaveState;
        const room = content.roomById(self.room) orelse return error.UnknownOpeningSaveRoom;
        if ((self.support == null and !room.canStand(self.position.x, self.position.y)) or self.position.x < 0 or self.position.y < 0 or self.position.x >= room.width or self.position.y >= room.height or @mod(self.position.x, 8) != 0 or @mod(self.position.y, 8) != 0 or self.following_teo != self.audience_complete or self.money > field.game_state.max_money or self.player_name.len == 0 or self.player_name.len > 32) return error.InvalidOpeningSaveState;
        try self.hero.validate();
        if (!std.mem.eql(u8, self.hero.member.id, content.hero.member.id) or !std.mem.eql(u8, self.hero.member.name, content.hero.member.name) or self.hero.member.max_hp != content.hero.member.max_hp or self.hero.member.hp == 0) return error.InvalidOpeningSaveHero;
        // This slice has no progression or equipment-changing events yet.
        if (self.hero.level != content.hero.level or self.hero.experience != content.hero.experience or self.hero.weapon_level != content.hero.weapon_level or !std.meta.eql(self.hero.base_stats, content.hero.base_stats) or !std.meta.eql(self.hero.equipped, content.hero.equipped)) return error.UnsupportedOpeningSaveHero;
    }
    pub fn validateSurface(self: Snapshot, scene: art.Scene) !void {
        const support = self.support orelse return;
        if (support.height != 1) return error.InvalidOpeningSaveSupport;
        const room = scene.roomById(self.room) orelse return error.UnknownOpeningSaveRoom;
        const cell = room.surfaceAt(self.position.x, self.position.y, support.height) orelse return error.InvalidOpeningSaveSupport;
        if (!cell.walkable) return error.InvalidOpeningSaveSupport;
        for (room.surfaces) |entry| if (entry.support) |candidate| if (std.mem.eql(u8, candidate.id, support.id) and candidate.height == support.height and candidate.depth == support.depth) return;
        return error.InvalidOpeningSaveSupport;
    }
    pub fn apply(self: Snapshot, content: Content, event_content: events.Content, script: audience.Content, scene: art.Scene, destination: *Live) !void {
        try self.validate(content);
        try self.validateSurface(scene);
        var next = try Live.start(content, event_content, script, scene);
        const room = content.roomById(self.room).?;
        const camera = content.cameraFor(room, self.position);
        var room_script = script;
        const room_art = scene.roomById(content.room).?;
        room_script.actors = if (self.audience_complete) room_art.after_audience_actors else room_art.actors;
        next.stage = try audience.State.start(room_script, .{ .hero = .{ .x = self.position.x, .y = self.position.y }, .camera = .{ .x = camera.x, .y = camera.y }, .width = room.width, .height = room.height, .player_name = self.player_name });
        next.stage.active = false;
        next.stage.audience_complete = self.audience_complete;
        next.stage.following_teo = self.following_teo;
        next.seed.events = try events.State.init(event_content);
        next.seed.events.flags.story_0006 = self.audience_complete;
        const names = [_][]const u8{ "scene_actor_0", "scene_actor_1", "scene_actor_2", "scene_actor_3", "scene_actor_7", "scene_actor_8", "scene_actor_9" };
        if (std.mem.eql(u8, room.id, content.room)) {
            for (names, 0..) |id, i| next.seed.events.actors[i].attached = (try next.stage.avatar(id)).attached;
            const initialization = try next.seed.events.initializeRoom(event_content);
            for (initialization.pumps) |pump| if (pump) |effects| for (effects.released) |released| if (released) |id| {
                const actor = try next.stage.avatar(names[@backingInt(id)]);
                actor.motion.speed = 0;
                actor.released = true;
                actor.variant = 254;
                actor.sprite.active = false;
            };
            next.seed.room = room.id;
            next.hero().motion = .{ .x = self.position.x, .y = self.position.y, .speed = 2 };
            if (self.following_teo) {
                next.stage.follower = try audience.Follower.start(script, next.hero().motion);
                room_art.resolve(&next.stage.follower.?.actor);
            }
        } else {
            try next.enter(content, script, scene, .{ .x = 0, .y = 0, .w = 8, .h = 8, .room = room.id, .spawn_x = self.position.x, .spawn_y = self.position.y });
            next.seed.events.initialized = true;
        }
        try next.hero().face(script, self.facing);
        next.seed.hero = self.hero;
        next.seed.hero.member.id = content.hero.member.id;
        next.seed.hero.member.name = content.hero.member.name;
        next.seed.money = self.money;
        next.seed.position = self.position;
        next.seed.camera = camera;
        if (self.support) |support| {
            var found: ?audience.Support = null;
            for (scene.roomById(room.id).?.surfaces) |cell| if (cell.support) |candidate| if (std.mem.eql(u8, candidate.id, support.id) and candidate.height == support.height and candidate.depth == support.depth) {
                found = candidate;
                break;
            };
            next.hero().support = found orelse return error.InvalidOpeningSaveSupport;
        } else next.hero().support = null;
        next.elapsed = self.elapsed_ticks;
        destination.* = next;
    }
};

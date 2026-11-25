const std = @import("std");
const validation = @import("validation");
const movement = @import("field_movement");
const services = @import("field_services");
const interaction = @import("field_interaction");
pub const game_state = @import("game_state.zig");
pub const inn = @import("inn.zig");
pub const items = game_state.items;
pub const room_flags = @import("area_host").room_flags;
pub const wheel = @import("area_host").wheel;
pub const area_effect = @import("area_host").callback;
pub const interactionReaches = interaction.reaches;
pub const scenery = @import("field_scenery.zig");
pub const camera_push = game_state.event_runtime.camera_push;

pub const Direction = enum { down, up, left, right };
pub fn directionPadMask(direction: ?Direction) u16 {
    return if (direction) |held| switch (held) {
        .up => 0x1000,
        .right => 0x2000,
        .down => 0x4000,
        .left => 0x8000,
    } else 0;
}

pub fn editAuxiliaryParty(list: *[6]u8, add: bool, character: u8) void {
    for (list) |*slot| {
        if (slot.* == (if (add) @as(u8, 255) else character)) {
            slot.* = if (add) character else 255;
            break;
        }
    }
}
pub const Point = struct { x: i32, y: i32 };
pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };
pub const ShadowDraw = struct { rect: Rect, points: [4]wheel.MapPoint };
pub const Frame = struct { rect: Rect, anchor_x: i32, anchor_y: i32, ticks: u16 };
pub const Clip = struct {
    direction: Direction,
    idle_frame: usize,
    frames: []const Frame,
    flags: u2 = 3,

    pub fn jsonStringify(self: Clip, writer: anytype) !void {
        try writer.beginObject();
        inline for (comptime std.meta.fieldNames(Clip)) |name| {
            if (comptime !std.mem.eql(u8, name, "flags")) {
                try writer.objectField(name);
                try writer.write(@field(self, name));
            } else if (self.flags != 3) {
                try writer.objectField(name);
                try writer.write(self.flags);
            }
        }
        try writer.endObject();
    }
};
pub const DrawFrame = struct { rect: Rect, x: i32, y: i32, ticks: u16 };
pub const Draw = struct {
    rect: Rect,
    x: i32,
    y: i32,
    depth: i32,
    hidden_by: ?game_state.StoryFlag = null,
    frames: []const DrawFrame = &.{},
    room_conditions: ?[]const RoomFlagCondition = null,
    prop: ?u6 = null,
    scenery_object: ?u16 = null,

    pub fn jsonStringify(self: Draw, writer: anytype) !void {
        try writer.beginObject();
        inline for (comptime std.meta.fieldNames(Draw)) |name| {
            const value = @field(self, name);
            const emit = if (comptime std.mem.eql(u8, name, "scenery_object") or std.mem.eql(u8, name, "room_conditions") or std.mem.eql(u8, name, "prop")) value != null else if (comptime @typeInfo(@TypeOf(value)) == .optional) value != null or writer.options.emit_null_optional_fields else true;
            if (emit) {
                try writer.objectField(name);
                try writer.write(value);
            }
        }
        try writer.endObject();
    }

    pub fn sampleVisible(self: Draw, state: *const State) ?Draw {
        if (self.prop) |id| if (state.shown_props & (@as(u64, 1) << id) == 0) return null;
        if (self.hidden_by) |flag| if (state.progress.story.has(flag)) return null;
        for (self.room_conditions orelse &.{}) |condition| if (!condition.matches(&state.local_flags)) return null;
        return self.sample(state.scene_ticks);
    }

    pub fn sample(self: Draw, elapsed: u32) Draw {
        if (self.frames.len == 0) return self;
        var total: u32 = 0;
        for (self.frames) |frame| total += frame.ticks;
        var tick = elapsed % total;
        var result = self;
        for (self.frames) |frame| {
            if (tick < frame.ticks) {
                result.rect = frame.rect;
                result.x = frame.x;
                result.y = frame.y;
                return result;
            }
            tick -= frame.ticks;
        }
        unreachable;
    }
};
pub const RecruitmentDialogue = struct { choices: [2][]const u8, accepted_prefix: []const u8, accepted_suffix: []const u8, declined: []const []const u8, joined: []const u8 };
pub const Npc = struct {
    service: ?enum { blacksmith, rune } = null,
    weapon_limit: u8 = 16,
    marker: ?enum { treasure, service } = null,
    id: []const u8,
    name: []const u8,
    x: i32,
    y: i32,
    pages: []const []const u8,
    hidden_by: ?game_state.StoryFlag = null,
    absent_by: ?game_state.StoryFlag = null,
    minimum_recruitment_tier: u8 = 0,
    recruitment: ?RecruitmentDialogue = null,
    scenario_index: ?u8 = null,
    scenario_set_mask: u8 = 0,
    scenario_clear_mask: u8 = 0,
    pub fn visible(self: Npc, story: game_state.Story) bool {
        if (story.recruitment_tier < self.minimum_recruitment_tier) return false;
        if (self.hidden_by) |flag| if (story.has(flag)) return false;
        if (self.absent_by) |flag| if (story.has(flag)) return false;
        if (self.scenario_index) |index| {
            const scenario = story.scenario orelse return false;
            const byte = scenario.scenario[index];
            if (byte & self.scenario_set_mask != self.scenario_set_mask) return false;
            if (byte & self.scenario_clear_mask != 0) return false;
        }
        return true;
    }
};
pub const Event = struct {
    id: []const u8,
    name: []const u8,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    flag: game_state.StoryFlag,
    requires: ?game_state.StoryFlag = null,
    pages: []const []const u8,
};
pub const RoomFlagCondition = struct {
    kind: enum { room_mask_set, room_mask_clear },
    index: u8,
    mask: u8,

    fn valid(self: RoomFlagCondition) bool {
        return self.index < room_flags.bytes and self.mask != 0;
    }

    fn matches(self: RoomFlagCondition, local: *const room_flags.State) bool {
        return local.matches(self.index, self.mask, self.kind == .room_mask_set);
    }
};

pub const WorldEntry = struct {
    id: []const u8,
    world_room: []const u8,
    point: u8,
    area: []const u8,
    return_x: i32,
    return_y: i32,
};
pub const WorldContext = struct { room: usize, entry: ?u16 = null };

pub const Exit = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    room: []const u8,
    spawn_x: i32,
    spawn_y: i32,
    direction: ?Direction = null,
    arrival_facing: ?Direction = null,
    conditions: ?[]const game_state.event_runtime.Condition = null,
    room_conditions: ?[]const RoomFlagCondition = null,
    world_exit: bool = false,
    world_entry: ?[]const u8 = null,
    source_arrival: bool = false,

    pub fn allows(self: Exit, story: *const game_state.Story, local: *const room_flags.State) bool {
        if (self.conditions) |conditions| {
            const scenario = story.scenario orelse game_state.event_runtime.StoryState{};
            if (!scenario.matches(conditions)) return false;
        }
        for (self.room_conditions orelse &.{}) |condition| {
            if (!condition.matches(local)) return false;
        }
        return true;
    }

    pub fn jsonStringify(self: Exit, writer: anytype) !void {
        try writer.beginObject();
        inline for (comptime std.meta.fieldNames(Exit)) |name| {
            const value = @field(self, name);
            const emit = if (comptime (std.mem.eql(u8, name, "world_exit") or std.mem.eql(u8, name, "source_arrival")))
                value
            else if (comptime std.mem.eql(u8, name, "conditions") or std.mem.eql(u8, name, "room_conditions") or std.mem.eql(u8, name, "arrival_facing"))
                value != null
            else if (comptime @typeInfo(@TypeOf(value)) == .optional)
                value != null or writer.options.emit_null_optional_fields
            else
                true;
            if (emit) {
                try writer.objectField(name);
                try writer.write(value);
            }
        }
        try writer.endObject();
    }
};
pub const Room = struct {
    id: []const u8,
    title: []const u8,
    width: i32,
    height: i32,
    walkable: []const u8,
    boat_walkable: ?[]const u8 = null,
    boat_rapids: ?struct {
        requires: game_state.event_runtime.Flag,
        warned: game_state.event_runtime.Flag,
        pages: []const []const u8,
    } = null,
    draws: []const Draw,
    npcs: []const Npc,
    exits: []const Exit,
    events: []const Event = &.{},
    scenery_atlas: ?[]const u8 = null,
    scenery_model: ?scenery.Model = null,
    wheel_map: ?u12 = null,
    source_area: ?[]const u8 = null,

    pub fn jsonStringify(self: Room, writer: anytype) !void {
        try writer.beginObject();
        inline for (comptime std.meta.fieldNames(Room)) |name| {
            const value = @field(self, name);
            if (comptime std.mem.eql(u8, name, "scenery_model") or std.mem.eql(u8, name, "scenery_atlas") or std.mem.eql(u8, name, "boat_walkable") or std.mem.eql(u8, name, "boat_rapids") or std.mem.eql(u8, name, "wheel_map") or std.mem.eql(u8, name, "source_area")) {
                if (value != null) {
                    try writer.objectField(name);
                    try writer.write(value);
                }
            } else {
                try writer.objectField(name);
                try writer.write(value);
            }
        }
        try writer.endObject();
    }

    pub fn validateSceneryAtlas(self: Room, width: i32, height: i32) !void {
        if (width <= 0 or height <= 0 or width > 4096 or height > 4096) return error.InvalidAtlas;
        for (self.draws) |draw| {
            try validRect(draw.rect, width, height);
            for (draw.frames) |frame| try validRect(frame.rect, width, height);
        }
    }

    pub fn sceneryCopies(self: Room, draw: Draw, visit: ?*const scenery.State) usize {
        const object = draw.scenery_object orelse return 1;
        const model = self.scenery_model orelse return 0;
        const state = visit orelse return @intFromBool(object < model.initial_count and model.initial(object).active());
        var copies: usize = 0;
        for (state.instances[0..state.count]) |instance| {
            if (instance.object == object and instance.active()) copies += 1;
        }
        return copies;
    }

    pub fn canStandWithScenery(self: Room, visit: ?*const scenery.State, x: i32, y: i32) bool {
        if (visit) |state| if (self.scenery_model) |model| return model.canStand(state, x, y, 0);
        return self.canStand(x, y);
    }

    pub fn mutateScenery(self: Room, visit: *?scenery.State, command: game_state.event_runtime.Command) !void {
        const model = self.scenery_model orelse return error.InvalidFieldSceneryState;
        const object = command.scenery_object orelse return error.InvalidFieldSceneryState;
        var state = visit.* orelse try scenery.State.init(model);
        switch (command.kind) {
            .scenery_stage => try state.stage(object),
            .scenery_restore => try state.restore(model, object),
            .scenery_append => _ = try state.append(model, object),
            else => return error.InvalidFieldSceneryState,
        }
        visit.* = state;
    }

    pub fn hasWorldExit(self: Room) bool {
        for (self.exits) |exit| if (exit.world_exit) return true;
        return false;
    }

    pub fn contains(self: Room, x: i32, y: i32) bool {
        return x >= 0 and y >= 0 and x < self.width and y < self.height and @mod(x, 8) == 0 and @mod(y, 8) == 0;
    }

    pub fn canStand(self: Room, x: i32, y: i32) bool {
        if (!self.contains(x, y)) return false;
        const index: usize = @intCast(@divTrunc(y, 8) * @divTrunc(self.width, 8) + @divTrunc(x, 8));
        return self.walkable[index] == '1';
    }

    pub fn canMoveInMode(self: Room, x: i32, y: i32, world_mode: u8) bool {
        if (!self.contains(x, y)) return false;
        if (world_mode == 2) return true;
        const index: usize = @intCast(@divTrunc(y, 8) * @divTrunc(self.width, 8) + @divTrunc(x, 8));
        if (world_mode == 1) {
            return if (self.boat_walkable) |boat| boat[index] == '1' else false;
        }
        return self.walkable[index] == '1';
    }

    pub fn boatPassage(self: Room, x: i32, y: i32, story: *const game_state.event_runtime.StoryState) enum { blocked, open, rapids } {
        if (!self.contains(x, y)) return .blocked;
        const water = self.boat_walkable orelse return .blocked;
        const index: usize = @intCast(@divTrunc(y, 8) * @divTrunc(self.width, 8) + @divTrunc(x, 8));
        if (water[index] == '1') return .open;
        const rapids = self.boat_rapids orelse return .blocked;
        if (water[index] != '2') return .blocked;
        return if (story.matches(&.{.{ .kind = .story_mask_set, .flag = rapids.requires }})) .open else .rapids;
    }
};

/// Static ground query, as a value interface.  The travel/session owner
/// binds the decoded geometry and the package->source-room identity; `field` owns
/// no geometry, allocator or packet, so `State` stays a plain serializable value.
/// A bound query answers the source 2x2 footprint; an unbound room keeps the
/// accepted exported `walkable` string.
pub const Ground = struct {
    context: *const anyopaque,
    query: *const fn (context: *const anyopaque, room_id: []const u8, x: i32, y: i32) bool,
    authoritative: bool = false,
};

fn canStand(room: Room, visit: ?*const scenery.State, x: i32, y: i32, ground: ?Ground) bool {
    if (ground) |query| {
        if (query.authoritative) return query.query(query.context, room.id, x, y);
    }
    if (!room.canStandWithScenery(visit, x, y)) return false;
    const query = ground orelse return true;
    return query.query(query.context, room.id, x, y);
}

pub const Package = struct {
    pub const max_rooms = 2048;
    pub const max_file_size = 64 * 1024 * 1024;
    pub const story_exits_schema = "suikoden-room/8";
    pub const world_exits_schema = "suikoden-room/9";
    pub const arrival_facing_schema = "suikoden-room/10";
    pub const scenery_atlas_schema = "suikoden-room/11";
    pub const room_conditions_schema = "suikoden-room/12";
    pub const scenery_conditions_schema = "suikoden-room/13";
    pub const prop_schema = "suikoden-room/14";
    pub const wheel_map_schema = "suikoden-room/15";
    pub const world_entry_schema = "suikoden-room/16";
    pub const scenery_model_schema = "suikoden-room/17";
    pub const scenery_draw_schema = "suikoden-room/18";

    schema: []const u8,
    atlas: []const u8,
    cell_size: u8,
    start_room: []const u8,
    start_x: i32,
    start_y: i32,
    step_ticks: u16,
    interaction_offsets: [4]Point,
    player_clips: []const Clip,
    rooms: []const Room,
    world_entries: []const WorldEntry = &.{},
    initial_world_entry: ?[]const u8 = null,

    pub fn roomIndex(self: Package, id: []const u8) ?usize {
        for (self.rooms, 0..) |room, i| if (std.mem.eql(u8, room.id, id)) return i;
        return null;
    }

    pub fn worldEntryIndex(self: Package, id: []const u8) ?u16 {
        for (self.world_entries, 0..) |entry, index| if (std.mem.eql(u8, entry.id, id)) return @intCast(index);
        return null;
    }

    pub fn permitsSourceArrival(self: Package, room: []const u8, x: i32, y: i32) bool {
        for (self.world_entries) |entry| if (std.mem.eql(u8, entry.world_room, room) and entry.return_x == x and entry.return_y == y) return true;
        for (self.rooms) |source| for (source.exits) |exit| {
            if (exit.source_arrival and std.mem.eql(u8, exit.room, room) and exit.spawn_x == x and exit.spawn_y == y) return true;
        };
        return false;
    }

    pub fn supportsStoryExits(self: Package) bool {
        return std.mem.eql(u8, self.schema, story_exits_schema) or self.supportsWorldExits();
    }

    fn supportsWorldExits(self: Package) bool {
        return std.mem.eql(u8, self.schema, world_exits_schema) or self.supportsArrivalFacing();
    }

    fn supportsArrivalFacing(self: Package) bool {
        return std.mem.eql(u8, self.schema, arrival_facing_schema) or self.supportsSceneryAtlases();
    }

    fn supportsSceneryAtlases(self: Package) bool {
        return std.mem.eql(u8, self.schema, scenery_atlas_schema) or self.supportsRoomConditions();
    }

    fn supportsRoomConditions(self: Package) bool {
        return std.mem.eql(u8, self.schema, room_conditions_schema) or std.mem.eql(u8, self.schema, scenery_conditions_schema) or self.supportsProps();
    }

    pub fn supportsProps(self: Package) bool {
        return std.mem.eql(u8, self.schema, prop_schema) or std.mem.eql(u8, self.schema, wheel_map_schema) or self.supportsWorldEntries();
    }

    pub fn supportsWorldEntries(self: Package) bool {
        return std.mem.eql(u8, self.schema, world_entry_schema) or self.supportsSceneryModels();
    }

    pub fn supportsSceneryModels(self: Package) bool {
        return std.mem.eql(u8, self.schema, scenery_model_schema) or std.mem.eql(u8, self.schema, scenery_draw_schema);
    }

    pub fn hasWorldExit(self: Package) bool {
        if (!self.supportsWorldExits()) return false;
        for (self.rooms) |room| if (room.hasWorldExit()) return true;
        return false;
    }

    pub fn validate(self: Package) !void {
        const legacy = std.mem.eql(u8, self.schema, "suikoden-room/2");
        if (!legacy and !std.mem.eql(u8, self.schema, "suikoden-room/4") and !std.mem.eql(u8, self.schema, "suikoden-room/5") and !std.mem.eql(u8, self.schema, "suikoden-room/6") and !std.mem.eql(u8, self.schema, "suikoden-room/7") and !self.supportsStoryExits()) return error.UnsupportedSchema;
        if (!std.mem.eql(u8, self.atlas, "atlas.png") or self.cell_size != 8 or self.step_ticks == 0 or self.step_ticks > 60) return error.InvalidPackage;
        if (self.rooms.len == 0 or self.rooms.len > max_rooms or self.player_clips.len != 4) return error.InvalidPackage;
        const with_world_entries = self.supportsWorldEntries();
        if ((!with_world_entries and (self.world_entries.len != 0 or self.initial_world_entry != null)) or self.world_entries.len > max_rooms) return error.InvalidWorldEntry;
        for (self.world_entries, 0..) |entry, index| {
            try validText(entry.id, 96);
            try validText(entry.area, 64);
            const world = self.roomIndex(entry.world_room) orelse return error.InvalidWorldEntry;
            if (!self.rooms[world].contains(entry.return_x, entry.return_y) or @mod(entry.return_x, 8) != 0 or @mod(entry.return_y, 8) != 0) return error.InvalidWorldEntry;
            for (self.world_entries[0..index]) |other| if (std.mem.eql(u8, entry.id, other.id) or
                (entry.point == other.point and std.mem.eql(u8, entry.world_room, other.world_room))) return error.InvalidWorldEntry;
        }
        if (self.initial_world_entry) |id| _ = self.worldEntryIndex(id) orelse return error.InvalidWorldEntry;
        for (self.interaction_offsets) |p| if (@abs(p.x) > 32 or @abs(p.y) > 32) return error.InvalidPackage;
        for (self.player_clips, 0..) |clip, i| {
            if (@backingInt(clip.direction) != i or clip.frames.len == 0 or clip.frames.len > 32 or clip.idle_frame >= clip.frames.len) return error.InvalidClip;
            for (clip.frames) |frame| {
                try validRect(frame.rect, 4096, 4096);
                if (frame.ticks == 0 or frame.ticks > 3600 or frame.anchor_x < 0 or frame.anchor_y < 0 or frame.anchor_x > frame.rect.w or frame.anchor_y > frame.rect.h) return error.InvalidClip;
            }
        }
        for (self.rooms, 0..) |room, i| {
            try validText(room.id, 64);
            if (room.source_area) |area| {
                if (!with_world_entries) return error.InvalidWorldEntry;
                try validText(area, 64);
            }
            try validText(room.title, 120);
            if (room.scenery_atlas) |path| {
                if (!self.supportsSceneryAtlases() or !validSceneryPath(path)) return error.InvalidSceneryAtlas;
            }
            if (room.width < 16 or room.height < 16 or room.width > 2048 or room.height > 2048 or @mod(room.width, 8) != 0 or @mod(room.height, 8) != 0) return error.InvalidRoom;
            if (room.scenery_model) |model| {
                if (!self.supportsSceneryModels()) return error.InvalidFieldScenery;
                try model.validate();
                if (@as(i32, model.columns) * 8 != room.width or @as(i32, model.rows) * 8 != room.height) return error.InvalidFieldScenery;
            }
            const count: usize = @intCast(@divTrunc(room.width, 8) * @divTrunc(room.height, 8));
            if (room.walkable.len != count or room.draws.len > 4096 or room.npcs.len > 128 or room.exits.len > 128) return error.InvalidRoom;
            for (room.walkable) |cell| if (cell != '0' and cell != '1') return error.InvalidRoom;
            if (room.boat_walkable) |boat| {
                if (boat.len != count) return error.InvalidRoom;
                for (boat) |cell| if (cell != '0' and cell != '1' and (cell != '2' or room.boat_rapids == null)) return error.InvalidRoom;
            }
            if (room.boat_rapids) |rapids| {
                const water = room.boat_walkable orelse return error.InvalidRoom;
                if (std.mem.indexOfScalar(u8, water, '2') == null or rapids.requires.scenarioIndex() == null or
                    rapids.warned.scenarioIndex() == null or rapids.pages.len == 0 or rapids.pages.len > 4) return error.InvalidRoom;
                for (rapids.pages) |page| try validText(page, 512);
            }
            for (self.rooms[0..i]) |other| if (std.mem.eql(u8, room.id, other.id)) return error.DuplicateId;
            if (room.wheel_map) |index| {
                if ((!std.mem.eql(u8, self.schema, wheel_map_schema) and !self.supportsWorldEntries()) or index >= room.draws.len or
                    room.width < 320 or room.height < 240 or room.scenery_atlas == null) return error.InvalidWheelMap;
                const map = room.draws[index];
                if (map.x != 0 or map.y != 0 or map.frames.len != 0 or map.prop != null or map.hidden_by != null or map.room_conditions != null)
                    return error.InvalidWheelMap;
                _ = try wheel.MapProjection.init(.{ std.math.cast(u16, map.rect.w) orelse return error.InvalidWheelMap, std.math.cast(u16, map.rect.h) orelse return error.InvalidWheelMap }, .{ 0, 0 }, 0);
            }
            for (room.draws) |draw| {
                if (draw.scenery_object) |object| {
                    const model = room.scenery_model orelse return error.InvalidFieldSceneryDraw;
                    if (!std.mem.eql(u8, self.schema, scenery_draw_schema) or object >= model.objects.len or draw.prop != null) return error.InvalidFieldSceneryDraw;
                }
                if (draw.prop != null and !self.supportsProps()) return error.InvalidSceneryProp;
                try validRect(draw.rect, 4096, 4096);
                if (draw.room_conditions) |conditions| {
                    if ((!std.mem.eql(u8, self.schema, scenery_conditions_schema) and !self.supportsProps()) or conditions.len > 16) return error.InvalidSceneryConditions;
                    for (conditions) |condition| if (!condition.valid()) return error.InvalidSceneryConditions;
                }
                if (draw.frames.len > 16) return error.InvalidClip;
                for (draw.frames) |frame| {
                    try validRect(frame.rect, 4096, 4096);
                    if (frame.ticks == 0 or frame.ticks > 3600 or @abs(frame.x) > 4096 or @abs(frame.y) > 4096) return error.InvalidClip;
                }
                if (@abs(draw.x) > 4096 or @abs(draw.y) > 4096 or @abs(draw.depth) > 4096) return error.InvalidRoom;
            }
            for (room.npcs, 0..) |npc, j| {
                if (npc.minimum_recruitment_tier > 4) return error.InvalidNpc;
                if (npc.recruitment) |dialogue| {
                    for (dialogue.choices) |label| try validText(label, 80);
                    try validText(dialogue.accepted_prefix, 4096);
                    try validText(dialogue.accepted_suffix, 80);
                    try validText(dialogue.joined, 80);
                    if (dialogue.declined.len == 0 or dialogue.declined.len > 64) return error.InvalidNpc;
                    for (dialogue.declined) |page| try validText(page, 4096);
                }
                if (npc.weapon_limit == 0 or npc.weapon_limit > 16) return error.InvalidNpc;
                try validText(npc.id, 64);
                try validText(npc.name, 64);
                if (npc.x < 0 or npc.x >= room.width or npc.y < 0 or npc.y >= room.height or npc.pages.len == 0 or npc.pages.len > 64) return error.InvalidNpc;
                for (npc.pages) |page| try validText(page, 4096);
                for (room.npcs[0..j]) |other| if (std.mem.eql(u8, npc.id, other.id)) return error.DuplicateId;
            }
            if (room.events.len > 32 or (legacy and room.events.len != 0)) return error.InvalidEvent;
            for (room.events, 0..) |event, j| {
                try validText(event.id, 64);
                try validText(event.name, 64);
                try validRect(.{ .x = event.x, .y = event.y, .w = event.w, .h = event.h }, room.width, room.height);
                if (@mod(event.x, 8) != 0 or @mod(event.y, 8) != 0 or @mod(event.w, 8) != 0 or @mod(event.h, 8) != 0) return error.InvalidEvent;
                if (event.pages.len == 0 or event.pages.len > 64) return error.InvalidEvent;
                for (event.pages) |page| try validText(page, 4096);
                for (room.events[0..j]) |other| if (std.mem.eql(u8, event.id, other.id) or event.flag == other.flag) return error.DuplicateEvent;
                var reachable_origin = false;
                var y = event.y;
                while (y < event.y + event.h) : (y += 8) {
                    var x = event.x;
                    while (x < event.x + event.w) : (x += 8) {
                        reachable_origin = reachable_origin or room.canStand(x, y);
                    }
                }
                if (!reachable_origin) return error.InvalidEvent;
            }
        }
        // All grids are validated before checking cross-room spawn references.
        for (self.rooms) |room| for (room.exits) |exit| {
            try validRect(.{ .x = exit.x, .y = exit.y, .w = exit.w, .h = exit.h }, room.width, room.height);
            const target = self.roomIndex(exit.room) orelse return error.UnknownRoom;
            if (exit.world_exit and (!self.supportsWorldExits() or std.mem.eql(u8, room.id, exit.room))) return error.InvalidWorldExit;
            if (exit.arrival_facing != null and !self.supportsArrivalFacing()) return error.InvalidExitArrivalFacing;
            if (!self.rooms[target].contains(exit.spawn_x, exit.spawn_y) or
                (!self.rooms[target].canStand(exit.spawn_x, exit.spawn_y) and !exit.source_arrival)) return error.InvalidSpawn;
            if (exit.source_arrival and !with_world_entries) return error.InvalidSpawn;
            if (exit.world_entry) |id| {
                if (!with_world_entries) return error.InvalidWorldEntry;
                const entry = self.world_entries[self.worldEntryIndex(id) orelse return error.InvalidWorldEntry];
                if (!std.mem.eql(u8, entry.world_room, room.id) or !std.mem.eql(u8, entry.area, self.rooms[target].source_area orelse "")) return error.InvalidWorldEntry;
            }
            if (exit.conditions) |conditions| {
                if (!self.supportsStoryExits()) return error.InvalidExitConditions;
                for (conditions) |condition| if (condition.flag.scenarioIndex() == null) return error.InvalidExitConditions;
            }
            if (exit.room_conditions) |conditions| {
                if (!self.supportsRoomConditions()) return error.InvalidExitRoomConditions;
                for (conditions) |condition| if (!condition.valid()) return error.InvalidExitRoomConditions;
            }
        };
        const start = self.roomIndex(self.start_room) orelse return error.UnknownRoom;
        if (!self.rooms[start].canStand(self.start_x, self.start_y)) return error.InvalidSpawn;
    }

    pub fn validateAtlas(self: Package, width: i32, height: i32) !void {
        if (width <= 0 or height <= 0 or width > 4096 or height > 4096) return error.InvalidAtlas;
        for (self.player_clips) |clip| for (clip.frames) |frame| try validRect(frame.rect, width, height);
        for (self.rooms) |room| if (room.scenery_atlas == null) try room.validateSceneryAtlas(width, height);
    }
};

fn validSceneryPath(path: []const u8) bool {
    const prefix = "field/";
    const suffix = ".png";
    if (path.len <= prefix.len + suffix.len or path.len > prefix.len + 64 + suffix.len or
        !std.mem.startsWith(u8, path, prefix) or !std.mem.endsWith(u8, path, suffix)) return false;
    for (path[prefix.len .. path.len - suffix.len]) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '_' and char != '-') return false;
    }
    return true;
}

fn validText(text: []const u8, limit: usize) !void {
    if (!validation.isUtf8Text(text, 1, limit)) return error.InvalidText;
}

fn validRect(rect: Rect, width: i32, height: i32) !void {
    if (rect.x < 0 or rect.y < 0 or rect.w <= 0 or rect.h <= 0 or rect.w > width or rect.h > height or rect.x > width - rect.w or rect.y > height - rect.h) return error.InvalidRectangle;
}

pub fn load(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Package) {
    if (bytes.len > Package.max_file_size) return error.PackageTooLarge;
    const parsed = try std.json.parseFromSlice(Package, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    try parsed.value.validate();
    return parsed;
}

pub const Input = struct { direction: ?Direction = null, menu_direction: ?Direction = null, action: bool = false, cancel: bool = false };
pub const StepArrival = enum { immediate, deferred };
pub const Dialogue = @import("field_dialogue").Dialogue;
pub const revealedCount = @import("field_dialogue").revealedCount;

pub const ServiceRequest = struct { kind: game_state.event_runtime.FieldService, id: u8 = 0, shop_items: ?[]const []const u8 = null };
pub const CheckpointRequest = struct { selector: u8, code: u8 };
pub const SceneView = struct { camera: ?Point = null, hero: ?Point = null };

pub const State = struct {
    // Null preserves unknown membership when importing a save predating this owner.
    auxiliary_party: ?[6]u8 = @as([6]u8, @splat(255)),
    music: ?game_state.event_runtime.FieldMusic = null,
    world_context: ?WorldContext = null,
    room: usize,
    x: i32,
    y: i32,
    facing: Direction = .down,
    destination: Point,
    remaining: u16 = 0,
    step_duration: ?u8 = null,
    scene_view: SceneView = .{},
    animation_ticks: u32 = 0,
    movement_updates: u64 = 0,
    room_entries: u32 = 0,
    local_flags: room_flags.State = .{},
    shown_props: u64 = 0,
    room_scenery: ?scenery.State = null,
    wheel_state: ?wheel.Room = null,
    crossed_world_exit: bool = false,
    scene_ticks: u32 = 0,
    walking: bool = false,
    action_pending: bool = false,
    dialogue: ?Dialogue = null,
    progress: game_state.Progress,
    inn_rules: ?inn.Rules = null,
    item_rules: ?items.Rules = null,
    rest_ticks: u16 = 0,
    tile_variants: [32]u8 = @splat(0),
    pending_service: ?ServiceRequest = null,
    pending_checkpoint: ?CheckpointRequest = null,
    auto_route_id: ?u8 = null,

    pub fn init(package: Package, progress: game_state.Progress) State {
        var result: State = .{ .room = package.roomIndex(package.start_room).?, .x = package.start_x, .y = package.start_y, .destination = .{ .x = package.start_x, .y = package.start_y }, .progress = progress };
        if (package.initial_world_entry) |id| result.setWorldEntry(package, id);
        return result;
    }

    pub fn worldEntry(self: State, package: Package) ?WorldEntry {
        const context = self.world_context orelse return null;
        const index = context.entry orelse return null;
        return if (index < package.world_entries.len) package.world_entries[index] else null;
    }

    pub fn setWorldEntry(self: *State, package: Package, id: []const u8) void {
        const index = package.worldEntryIndex(id).?;
        self.world_context = .{ .room = package.roomIndex(package.world_entries[index].world_room).?, .entry = index };
    }

    pub fn reconcileWorldEntry(self: *State, package: Package, point: ?u8) void {
        const room = package.rooms[self.room];
        const area = room.source_area orelse {
            for (package.world_entries) |entry| if (std.mem.eql(u8, entry.world_room, room.id)) {
                if (self.world_context == null or self.world_context.?.room != self.room) self.world_context = .{ .room = self.room };
                return;
            };
            return;
        };
        if (point == null) if (self.worldEntry(package)) |entry| if (std.mem.eql(u8, entry.area, area)) return;
        var selected: ?u16 = null;
        for (package.world_entries, 0..) |entry, index| {
            if (!std.mem.eql(u8, entry.area, area) or (point != null and entry.point != point.?)) continue;
            if (self.world_context) |context| if (!std.mem.eql(u8, entry.world_room, package.rooms[context.room].id)) continue;
            if (selected != null) {
                if (self.world_context) |*context| context.entry = null;
                return;
            }
            selected = @intCast(index);
        }
        if (selected) |index| self.setWorldEntry(package, package.world_entries[index].id) else if (self.world_context) |*context| context.entry = null;
    }

    pub fn enterRoom(self: *State, room: usize, spawn: Point) void {
        self.room_entries +%= 1;
        self.local_flags.clear();
        self.shown_props = 0;
        self.room_scenery = null;
        self.wheel_state = null;
        self.tile_variants = @splat(0);
        self.crossed_world_exit = false;
        self.room = room;
        self.x = spawn.x;
        self.y = spawn.y;
        self.destination = spawn;
        self.remaining = 0;
        self.step_duration = null;
        self.scene_view = .{};
        self.animation_ticks = 0;
        self.walking = false;
        self.action_pending = false;
    }

    pub fn configureInn(self: *State, package: Package, rules: inn.Rules) !void {
        try rules.validate();
        try self.progress.validate();
        const index = package.roomIndex(rules.room) orelse return error.UnknownInnRoom;
        for (package.rooms[index].npcs) |npc| {
            if (std.mem.eql(u8, rules.npc, npc.id)) {
                self.inn_rules = rules;
                return;
            }
        }
        return error.UnknownInnNpc;
    }

    pub fn tick(self: *State, package: Package, input: Input) void {
        self.tickWithGround(package, input, null);
    }

    /// The same tick with the static ground query bound.  Movement
    /// consults the source footprint first and falls back to the exported
    /// walkable string for rooms without geometry.
    pub fn tickWithGround(self: *State, package: Package, input: Input, ground: ?Ground) void {
        self.tickWithArrival(package, input, ground, .immediate);
    }

    pub fn tickWithArrival(self: *State, package: Package, input: Input, ground: ?Ground, arrival: StepArrival) void {
        self.scene_ticks +%= 1;
        if (self.rest_ticks > 0) {
            self.rest_ticks -= 1;
            return;
        }
        const room = package.rooms[self.room];
        if (services.handleDialogue(self, room, input)) return;
        self.action_pending = !input.cancel and (self.action_pending or input.action);
        if (self.remaining > 0) {
            self.advance(package, arrival);
            if (self.remaining == 0 and input.direction == null) self.walking = false;
            return;
        }
        if (self.triggerEvent(room)) return;
        if (input.direction) |facing| self.facing = facing;
        if (interaction.interact(self, package, room)) return;
        const direction = input.direction orelse {
            self.animation_ticks = 0;
            self.walking = false;
            return;
        };
        self.facing = direction;
        const delta: Point = switch (direction) {
            .down => .{ .x = 0, .y = 8 },
            .up => .{ .x = 0, .y = -8 },
            .left => .{ .x = -8, .y = 0 },
            .right => .{ .x = 8, .y = 0 },
        };
        const next = Point{ .x = self.x + delta.x, .y = self.y + delta.y };
        const world_mode: u8 = if (self.progress.story.scenario) |s| s.world_mode else 0;
        const scenery_state = if (self.room_scenery) |*visit| visit else null;
        const river = if (world_mode == 1 and room.boat_rapids != null)
            room.boatPassage(next.x, next.y, &self.progress.story.scenario.?)
        else
            null;
        if (river == .rapids) {
            self.progress.story.scenario.?.apply(room.boat_rapids.?.warned) catch unreachable;
            self.dialogue = .{ .source = .boat_rapids, .reveal_started = self.scene_ticks };
            self.action_pending = false;
            self.walking = false;
            return;
        }
        const can_walk = if (river) |passage| passage == .open else if (world_mode != 0 and room.boat_walkable != null)
            room.canMoveInMode(next.x, next.y, world_mode)
        else
            canStand(room, scenery_state, next.x, next.y, ground);
        if (can_walk) {
            self.destination = next;
            self.remaining = package.step_ticks;
            self.walking = true;
            self.advance(package, arrival);
        } else {
            self.animation_ticks = 0;
            self.walking = false;
        }
    }

    fn advance(self: *State, package: Package, arrival: StepArrival) void {
        if (movement.advance(self) and arrival == .immediate) self.finishStepArrival(package);
    }

    pub fn finishStepArrival(self: *State, package: Package) void {
        movement.finish(self, package);
    }

    fn triggerEvent(self: *State, room: Room) bool {
        return movement.triggerEvent(self, room);
    }

    pub fn position(self: State, package: Package) struct { x: f32, y: f32 } {
        const duration = self.step_duration orelse package.step_ticks;
        const fraction = if (self.remaining > 0) 1.0 - @as(f32, @floatFromInt(self.remaining)) / @as(f32, @floatFromInt(duration)) else 0;
        return .{ .x = @as(f32, @floatFromInt(self.x)) + @as(f32, @floatFromInt(self.destination.x - self.x)) * fraction, .y = @as(f32, @floatFromInt(self.y)) + @as(f32, @floatFromInt(self.destination.y - self.y)) * fraction };
    }

    pub fn restOpacity(self: State) f32 {
        return @min(1, @as(f32, @floatFromInt(@min(60 - self.rest_ticks, self.rest_ticks))) / 15.0);
    }

    pub fn frame(self: State, package: Package) Frame {
        const clip = package.player_clips[@backingInt(self.facing)];
        const frames = clip.frames;
        if (!self.walking) return frames[clip.idle_frame];
        var total: u32 = 0;
        for (frames) |f| total += f.ticks;
        var tick_index = self.animation_ticks % total;
        for (frames) |f| {
            if (tick_index < f.ticks) return f;
            tick_index -= f.ticks;
        }
        unreachable;
    }
};

pub const CameraOffset = struct { x: f32, y: f32 };
/// The dialogue box has room for six 16px lines. Longer source pages use 12px
/// so an eight-line page still fits inside the box instead of drawing past it.
pub fn dialogueTextSize(page: []const u8) i32 {
    var lines: usize = 1;
    for (page) |byte| if (byte == '\n') {
        lines += 1;
    };
    return if (lines > 6) 12 else 16;
}

pub fn sourceCameraScroll(width: i32, height: i32, x: i32, y: i32) Point {
    return .{ .x = @max(0, @min(x - 152, width - 320)), .y = @max(0, @min(y - 112, height - 240)) };
}

pub fn cameraOffset(width: i32, height: i32, x: f32, y: f32) CameraOffset {
    return .{ .x = @round(cameraAxis(width, 512, x)), .y = 24 + @round(cameraAxis(height, 384, y)) };
}
fn cameraAxis(world: i32, viewport: i32, focus: f32) f32 {
    const span: f32 = @floatFromInt(world);
    const view: f32 = @floatFromInt(viewport);
    return if (world <= viewport) (view - span) / 2 else -std.math.clamp(focus - view / 2, 0, span - view);
}

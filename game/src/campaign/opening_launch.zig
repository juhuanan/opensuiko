//! Headless launch path for the canonical Opening opening and palace route.
//!
//! The windowed opening (`opening_platform`) and the world session both need a
//! content root.  This module is the launcher-side binder: it reads the
//! accepted opening scene from the caller's content root, loads the embedded
//! Opening start and fade assets, builds the single Opening `Host` and drives the same ordinary
//! input sequence the focused gate uses.  It is headless by construction: no
//! window, image or audio call is reachable from here.
//!
//! A content root without `scene.json` is reported as the exact missing file;
//! the palace route is never claimed startable without it.

const std = @import("std");
const start = @import("opening_start");
const opening_assets = @import("opening_assets");
const start_data = opening_assets.canonical_start;
const opening = @import("opening");
const events = @import("opening_events");
const audience = @import("opening_audience");
const save_policy = @import("opening_save_policy");
const save_policy_data = opening_assets.save_policy;
const destination = @import("opening_destination");
const destination_data = opening_assets.destination;
const field = @import("field");
const field_events = @import("field_events");
const dungeon = @import("opening_dungeon");
const dungeon_data = opening_assets.dungeon;
const opening_battle = @import("opening_battle");
const battle_data = opening_assets.battles;
const party = @import("opening_party").party;
const party_data = opening_assets.party_setup;

pub const scene_file = "scene.json";
pub const PalaceContent = struct {
    destination: *destination.Opened,
    package: field.Package,
    base: field_events.Binding,
};

pub const palace_room_ids = [_][]const u8{
    "vaa_room_0", "vaa_room_1", "vaa_room_2", "vaa_room_10",
    "va1_room_0", "va1_room_1", "va1_room_2",
};

pub fn palaceRooms(out: *[palace_room_ids.len]field.Room, opened: *destination.Opened, content: opening.Content) ![]const field.Room {
    for (palace_room_ids, 0..) |id, index| {
        out[index] = if (content.roomById(id)) |room| room else opened.fieldRoomFor(id) orelse return error.MissingPalaceFieldRoom;
    }
    return out;
}

pub fn palacePackage(rooms: []const field.Room, clips: []const field.Clip) field.Package {
    return .{
        .schema = "suikoden-room/6",
        .atlas = "atlas.png",
        .cell_size = 8,
        .start_room = "vaa_room_1",
        .start_x = 272,
        .start_y = 832,
        .step_ticks = 4,
        .interaction_offsets = .{ .{ .x = 0, .y = 16 }, .{ .x = 0, .y = -8 }, .{ .x = -16, .y = 0 }, .{ .x = 16, .y = 0 } },
        .player_clips = clips,
        .rooms = rooms,
    };
}

pub const Loaded = struct {
    allocator: std.mem.Allocator,
    asset: std.json.Parsed(start.Asset),
    opening: std.json.Parsed(opening.Content),
    events: std.json.Parsed(events.Content),
    script: std.json.Parsed(audience.Content),
    scene: std.json.Parsed(opening.art.Scene),
    rules: std.json.Parsed(save_policy.Asset),
    dungeon: std.json.Parsed(dungeon.Asset),
    battles: std.json.Parsed(opening_battle.Asset),
    party: std.json.Parsed(party.Asset),
    opened: *destination.Opened,
    owned: field_events.Owned,

    pub fn deinit(self: *Loaded) void {
        self.owned.deinit();
        self.opened.deinit();
        self.allocator.destroy(self.opened);
        self.asset.deinit();
        self.opening.deinit();
        self.events.deinit();
        self.script.deinit();
        self.scene.deinit();
        self.rules.deinit();
        self.dungeon.deinit();
        self.battles.deinit();
        self.party.deinit();
    }
};

/// Load the accepted Opening content plus the caller's opening scene.  Every JSON
/// value is hash/identity validated by its accepted owner before use.
pub fn load(allocator: std.mem.Allocator, scene_bytes: []const u8) !Loaded {
    const asset = try start.open(allocator, start_data.json);
    errdefer asset.deinit();
    const content = try opening.load(allocator, opening.json);
    errdefer content.deinit();
    const event_content = try events.load(allocator, events.json);
    errdefer event_content.deinit();
    const script = try audience.load(allocator, audience.json);
    errdefer script.deinit();
    const scene = try opening.art.load(allocator, scene_bytes, content.value.rooms, script.value);
    errdefer scene.deinit();
    const rules = try save_policy.open(allocator, save_policy_data.json);
    errdefer rules.deinit();
    const dungeon_asset = try dungeon.open(allocator, dungeon_data.json);
    errdefer dungeon_asset.deinit();
    const battle_asset = try opening_battle.open(allocator, battle_data.json);
    errdefer battle_asset.deinit();
    const party_asset = try party.open(allocator, party_data.json);
    errdefer party_asset.deinit();
    const opened = try allocator.create(destination.Opened);
    errdefer allocator.destroy(opened);
    opened.* = try destination.open(allocator, destination_data.json, destination_data.ground_json);
    errdefer opened.deinit();
    var members = [_]field.game_state.Member{content.value.hero.member.character()};
    const owned = try field_events.Owned.load(allocator, &members);
    return .{ .allocator = allocator, .asset = asset, .opening = content, .events = event_content, .script = script, .scene = scene, .rules = rules, .dungeon = dungeon_asset, .battles = battle_asset, .party = party_asset, .opened = opened, .owned = owned };
}

/// The exact room array the package borrows.  It stays in the caller's frame
/// so no package points into a temporary.
pub const Rooms = [palace_room_ids.len]field.Room;

pub fn bindPalace(loaded: *Loaded, rooms: *Rooms) !PalaceContent {
    const entries = try palaceRooms(rooms, loaded.opened, loaded.opening.value);
    return .{
        .destination = loaded.opened,
        .package = palacePackage(entries, &loaded.scene.value.player_clips),
        .base = loaded.owned.binding(),
    };
}

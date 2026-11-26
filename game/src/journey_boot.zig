//! Headless boot: resolve content, load the bundle, build the initial state and
//! locate the save directory. The launcher owns window, input and rendering.
const std = @import("std");
const field = @import("field");
const battle = @import("battle");
const engine = @import("engine");
const journey = @import("journey");
const journey_content = @import("journey_content");
const opening = @import("opening");
const opening_data = @import("opening_data");
const party_content = @import("party_content");
const package_host = @import("package_host");
const saves = @import("save_file");

pub const Boot = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    save_path: ?[]u8,
    bundle: journey_content.Bundle,
    party: ?party_content.Content,
    opening_seed: ?std.json.Parsed(opening.Content) = null,
    hero_name_override: ?[]u8 = null,
    members: []battle.Member,
    combat: *battle.State,
    state: engine.State,

    pub fn newState(self: *Boot) !engine.State {
        return self.newStateNamed(null);
    }

    pub fn newStateNamed(self: *Boot, hero_name: ?[]const u8) !engine.State {
        const package = self.bundle.package;
        var members: [battle.Party.roster_capacity]battle.Member = undefined;
        var combat: battle.State = undefined;
        var name_override: ?[]u8 = null;
        errdefer if (name_override) |name| self.allocator.free(name);
        var state = if (self.opening_seed) |seed| blk: {
            var hero = seed.value.hero;
            if (hero_name) |custom| {
                if (custom.len != 0) {
                    name_override = try self.allocator.dupe(u8, custom);
                    hero.member.name = name_override.?;
                }
            }
            break :blk try engine.State.initOpening(package, self.bundle.data, self.bundle.combat, self.bundle.items, self.bundle.inn, &members, &combat, hero, seed.value.money);
        } else try engine.State.initEpisode(package, self.bundle.data, self.bundle.combat, self.bundle.items, self.bundle.inn, &members, &combat);
        if (self.bundle.battle_host) |host| state.combat.integration = .{ .host = host };
        if (self.bundle.spell_scenes) |packet| try state.combat.attachSpellScenes(packet);
        if (self.bundle.unite_actors) |packet| try state.combat.attachUniteActors(packet);
        state.room_battles = self.bundle.room_battles;
        if (state.room_battles) |rooms| rooms.settled_actors = null;
        state.dice_host = self.bundle.dice_host;
        state.teleport_catalogue = self.bundle.teleport_catalogue;
        state.dice_model = self.bundle.dice_model;
        state.boat_data = self.bundle.boat_data;
        state.menu.region_bgm = self.bundle.region_bgm;
        if (state.dice_host) |host| {
            host.session = null;
            host.owner = .field;
        }
        state.shared_item_catalogue = self.bundle.shared_item_catalogue;
        if (state.packagedOpeningRoute() != null) state.route = .{};
        state.seedFieldStoryDefaults();
        state.updateOpeningPartyMilestone();
        state.enterEncounterRoom();
        if (self.party) |*value| {
            state.party_catalog = value.catalog.value;
            state.party_bindings = value.bindings.value;
            state.world_battle_enabled = true;
        }
        try state.validateScenePartyChanges();
        try state.initializeRoomVisit();
        state.bindValidatedStorage(self.combat, self.members);
        if (name_override) |name| {
            if (self.hero_name_override) |old| self.allocator.free(old);
            self.hero_name_override = name;
        }
        return state;
    }

    pub fn deinit(self: *Boot) void {
        if (self.hero_name_override) |name| self.allocator.free(name);
        if (self.party) |*value| value.deinit();
        if (self.opening_seed) |seed| seed.deinit();
        self.bundle.deinit();
        self.allocator.destroy(self.combat);
        self.allocator.free(self.members);
        self.allocator.free(self.path);
        if (self.save_path) |save| self.allocator.free(save);
    }
};

pub fn load(init: std.process.Init, args: []const [:0]const u8, check_journey_files: bool, diagnostic: *journey_content.Diagnostic) !Boot {
    const allocator = init.gpa;
    const first: usize = 1;
    if (args.len > first + 1) return error.InvalidArguments;
    const executable_directory = try std.process.executableDirPathAlloc(init.io, allocator);
    defer allocator.free(executable_directory);
    var content_diagnostic = package_host.Diagnostic.init(allocator);
    defer content_diagnostic.deinit();
    var content_location = package_host.resolveContent(
        allocator,
        init.io,
        executable_directory,
        if (args.len > first) args[first] else null,
        init.environ_map,
        &content_diagnostic,
    ) catch |err| {
        std.log.err("Content package ({s}): {s} -- {s}", .{ content_diagnostic.subject orelse "", content_diagnostic.message orelse @errorName(err), content_diagnostic.hint orelse "" });
        return err;
    };
    defer content_location.deinit();
    const path = try allocator.dupe(u8, content_location.location.path);
    errdefer allocator.free(path);
    _ = package_host.verifyPackage(allocator, init.io, path, check_journey_files, &content_diagnostic) catch |err| {
        std.log.err("Content package ({s}): {s} -- {s}", .{ content_diagnostic.subject orelse "", content_diagnostic.message orelse @errorName(err), content_diagnostic.hint orelse "" });
        return err;
    };
    var directory = try std.Io.Dir.cwd().openDir(init.io, path, .{});
    defer directory.close(init.io);
    var bundle = try journey_content.Bundle.load(allocator, init.io, directory, diagnostic);
    errdefer bundle.deinit();
    if (!package_host.verifyStartSeed(@import("opening_data").json).ok) return error.CanonicalSeedMismatch;
    const packaged_opening = if (bundle.room_battles) |rooms| rooms.opening_route != null else false;
    const canonical = journey.usesOpeningSeed(bundle.package.start_room);
    const opening_seed = if (canonical or packaged_opening) try opening.load(allocator, opening_data.json) else null;
    errdefer if (opening_seed) |seed| seed.deinit();
    const members = try allocator.alloc(battle.Member, battle.Party.roster_capacity);
    errdefer allocator.free(members);
    const combat = try allocator.create(battle.State);
    errdefer allocator.destroy(combat);
    var party_diagnostic: party_content.Diagnostic = .{};
    var party = party_content.load(allocator, init.io, directory, canonical, &party_diagnostic) catch |err| {
        if (party_diagnostic.path.len != 0) diagnostic.* = .{ .path = party_diagnostic.path, .cause = err };
        return err;
    };
    errdefer if (party) |*value| value.deinit();
    var save_path: ?[]u8 = package_host.stateDirectory(allocator, init.io, path, executable_directory, init.environ_map, &content_diagnostic) catch |err| blk: {
        if (init.environ_map.get("SUIKODEN_USER_DATA") != null) {
            std.log.err("User data ({s}): {s}", .{ content_diagnostic.subject orelse "SUIKODEN_USER_DATA", content_diagnostic.message orelse @errorName(err) });
            diagnostic.* = .{ .path = "SUIKODEN_USER_DATA", .cause = err };
            return err;
        }
        std.log.warn("Candidate user-state layout ({s}) is unreadable: {s}", .{ path, @errorName(err) });
        break :blk null;
    };
    errdefer if (save_path) |save| allocator.free(save);
    if (save_path == null) save_path = saves.defaultDirectory(allocator, init.environ_map) catch null;
    var result: Boot = .{ .allocator = allocator, .path = path, .save_path = save_path, .bundle = bundle, .party = party, .opening_seed = opening_seed, .members = members, .combat = combat, .state = undefined };
    result.state = try result.newState();
    return result;
}

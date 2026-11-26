const std = @import("std");

const ModSpec = struct { []const u8, []const u8, []const []const u8 };

const Registry = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_filter: ?[]const u8,
    mods: std.StringHashMapUnmanaged(*std.Build.Module) = .{},

    fn addData(self: *Registry, name: []const u8, path: []const u8) void {
        const m = self.b.createModule(.{ .root_source_file = self.b.path(path) });
        self.mods.put(self.b.allocator, name, m) catch @panic("OOM");
    }

    fn bind(self: *Registry, alias: []const u8, existing: []const u8) void {
        self.mods.put(self.b.allocator, alias, self.get(existing)) catch @panic("OOM");
    }

    fn add(self: *Registry, name: []const u8, path: []const u8, dep_names: []const []const u8) void {
        const m = self.b.addModule(name, .{
            .root_source_file = self.b.path(path),
            .target = self.target,
            .optimize = self.optimize,
            .imports = self.imports(dep_names),
        });
        self.mods.put(self.b.allocator, name, m) catch @panic("OOM");
    }

    fn get(self: *const Registry, name: []const u8) *std.Build.Module {
        return self.mods.get(name) orelse std.debug.panic("unknown module: {s}", .{name});
    }

    fn imports(self: *const Registry, names: []const []const u8) []const std.Build.Module.Import {
        const out = self.b.allocator.alloc(std.Build.Module.Import, names.len) catch @panic("OOM");
        for (names, 0..) |name, i| out[i] = .{ .name = name, .module = self.get(name) };
        return out;
    }

    fn addTest(
        self: *const Registry,
        step: ?*std.Build.Step,
        source_path: []const u8,
        dep_names: []const []const u8,
        cwd_parent: bool,
    ) *std.Build.Step.Compile {
        const compile = self.b.addTest(.{
            .root_module = self.b.createModule(.{
                .root_source_file = self.b.path(source_path),
                .target = self.target,
                .optimize = self.optimize,
                .imports = self.imports(dep_names),
            }),
            .filters = if (self.test_filter) |filter| &.{filter} else &.{},
        });
        const run = self.b.addRunArtifact(compile);
        // Runtime packages and fixtures can change without recompiling the tests.
        run.has_side_effects = true;
        if (cwd_parent) run.setCwd(self.b.path(".."));
        if (step) |s| s.dependOn(&run.step);
        return compile;
    }

    fn addRayExe(
        self: *const Registry,
        name: []const u8,
        source_path: []const u8,
        raylib: *std.Build.Dependency,
        dep_names: []const []const u8,
    ) *std.Build.Step.Compile {
        const exe = self.b.addExecutable(.{
            .name = name,
            .root_module = self.b.createModule(.{
                .root_source_file = self.b.path(source_path),
                .target = self.target,
                .optimize = self.optimize,
                .imports = self.imports(dep_names),
            }),
        });
        exe.root_module.linkLibrary(raylib.artifact("raylib"));
        return exe;
    }
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const public_replay = b.option(bool, "public-replay", "Build the synthetic replay without private assets or raylib") orelse false;
    const raylib = if (public_replay) null else try b.dependencyLazy("raylib_zig", .{ .target = target, .optimize = optimize });
    var r = Registry{ .b = b, .target = target, .optimize = optimize, .test_filter = b.option([]const u8, "test-filter", "Run matching headless tests only") };
    if (raylib) |dep| {
        r.mods.put(b.allocator, "raylib", dep.module("raylib")) catch @panic("OOM");
    } else {
        r.addData("replay_data", "tests/simulation_replay_data.zig");
        r.bind("raylib", "replay_data");
    }

    const data_modules = [_][2][]const u8{
        .{ "campaign_policies_data", "assets/campaign_policies.zig" },
        .{ "travel_data", "assets/travel.zig" },
        .{ "field_effect_data", "assets/travel/founding_effects.zig" },
        .{ "wheel_data", "assets/travel/kouan_wheel.zig" },
        .{ "item_overload_data", "assets/travel/item_overload.zig" },
        .{ "battle_systems_data", "assets/battle_systems.zig" },
        .{ "combat_systems_data", "assets/combat_systems.zig" },
        .{ "hq_data", "assets/hq.zig" },
        .{ "world_graph_data", "assets/world_graph.zig" },
        .{ "package_host_data", "assets/package_host.zig" },
        .{ "opening_assets", "assets/campaign/opening.zig" },
        .{ "middle_assets", "assets/campaign/middle.zig" },
        .{ "final_assets", "assets/campaign/final.zig" },
        .{ "campaign_content_data", "assets/campaign/content.zig" },
        .{ "party_data", "assets/party_session/catalogue.zig" },
        .{ "route_data", "assets/routes/region_b_vb6_c.zig" },
        .{ "opening_data", "assets/opening.zig" },
        .{ "opening_event_data", "assets/opening_events.zig" },
        .{ "audience_data", "assets/opening_audience.zig" },
        .{ "field_events_data", "assets/field_events.zig" },
        .{ "world_data", "assets/world_b.zig" },
        .{ "world_battle_data", "assets/world_b_battle.zig" },
        .{ "world_art_data", "assets/world_art_b.zig" },
        .{ "inn_data", "assets/inn.zig" },
        .{ "item_data", "assets/items.zig" },
        .{ "duel_data", "assets/duels.zig" },
        .{ "war_data", "assets/war/resources.zig" },
        .{ "war_scenarios_data", "assets/war/scenarios.zig" },
        .{ "war_manifest_data", "assets/war/content_manifest.zig" },
        .{ "battle_sin_cos_data", "assets/battle_sin_cos.zig" },
    };
    for (data_modules) |pair| r.addData(pair[0], pair[1]);
    if (public_replay) {
        for ([_][]const u8{ "field_events_data", "duel_data", "war_scenarios_data", "final_assets" }) |name|
            r.bind(name, "replay_data");
    }

    const core_modules = [_]ModSpec{
        .{ "validation", "src/validation.zig", &.{} },
        .{ "battle_rules", "src/battle_rules.zig", &.{} },
        .{ "inn_zon", "assets/inn_zon.zig", &.{} },
        .{ "campaign_content_zon", "assets/campaign/content_zon.zig", &.{} },
        .{ "audio_route", "src/audio_route.zig", &.{} },
        .{ "menu_layout", "src/menu_layout.zig", &.{} },
        .{ "settings", "src/settings.zig", &.{} },
        .{ "event_runtime", "src/event_runtime.zig", &.{} },
        .{ "opening_audio", "src/opening_audio/root.zig", &.{} },
        .{ "movement_batch", "src/movement_batch.zig", &.{} },
        .{ "area_host", "src/area_host/root.zig", &.{ "field_effect_data", "wheel_data", "event_runtime" } },
        .{ "fade", "src/opening/fade.zig", &.{} },
        .{ "opening_save_policy", "src/opening/save_policy.zig", &.{} },
        .{ "battle_camera", "src/battle_camera.zig", &.{"battle_sin_cos_data"} },
        .{ "hq_state", "src/hq_state.zig", &.{} },
        .{ "campaign_state", "src/campaign_state.zig", &.{} },
        .{ "war", "src/war.zig", &.{} },
        .{ "field_dialogue", "src/field_dialogue.zig", &.{} },
        .{ "raylib_app", "src/raylib_app.zig", &.{"raylib"} },
        .{ "combat_systems", "src/combat_systems/root.zig", &.{ "validation", "combat_systems_data" } },
        .{ "game", "src/battle_menu.zig", &.{"combat_systems"} },
        .{ "campaign_policies", "src/campaign_policies/root.zig", &.{ "battle_rules", "campaign_policies_data" } },
        .{ "battle_systems", "src/battle_systems/root.zig", &.{ "battle_rules", "validation", "campaign_policies", "battle_systems_data" } },
        .{ "field", "src/field.zig", &.{ "field_dialogue", "inn_data", "inn_zon", "item_data", "validation", "event_runtime", "area_host", "battle_rules" } },
        .{ "ui_font", "src/ui_font.zig", &.{"field"} },
        .{ "ui", "src/ui.zig", &.{ "raylib", "ui_font", "field" } },
        .{ "world", "src/world.zig", &.{ "battle_rules", "world_data", "field" } },
        .{ "save_file", "src/save_file.zig", &.{"field"} },
        .{ "battle_damage", "src/battle_damage.zig", &.{"battle_rules"} },
        .{ "battle", "src/battle.zig", &.{ "field", "game", "validation", "battle_rules", "battle_damage", "battle_camera", "combat_systems", "battle_systems" } },
        .{ "combat_session", "src/combat_session/session.zig", &.{ "battle", "battle_rules", "battle_systems" } },
        .{ "combat_world_gate", "src/combat_session/world_gate.zig", &.{ "combat_session", "battle", "world" } },
        .{ "pause_menu", "src/pause_menu.zig", &.{ "field", "battle", "audio_route" } },
        .{ "world_field", "src/world_field.zig", &.{ "world", "field", "pause_menu" } },
        .{ "world_battle", "src/world_battle.zig", &.{ "world", "world_field", "battle", "combat_session", "combat_world_gate", "world_battle_data", "battle_systems" } },
        .{ "world_view", "src/world_view.zig", &.{ "world", "field", "world_art_data" } },
        .{ "demo_batch", "src/demo_batch.zig", &.{ "battle", "field" } },
        .{ "opening_events", "src/opening_events.zig", &.{"opening_event_data"} },
        .{ "opening_audience", "src/opening_audience.zig", &.{ "validation", "audience_data" } },
        .{ "dice_presentation", "src/dice_presentation.zig", &.{ "battle_camera", "opening_audience" } },
        .{ "opening_event_adapter", "src/opening_event_adapter.zig", &.{ "event_runtime", "opening_audience" } },
        .{ "scene_population", "src/scene_population.zig", &.{"event_runtime"} },
        .{ "scene_dispatch", "src/scene_dispatch.zig", &.{ "scene_population", "event_runtime", "validation" } },
        .{ "field_actors", "src/field_actors.zig", &.{ "event_runtime", "opening_audience", "scene_population" } },
        .{ "room2_text", "src/opening/room2_text/root.zig", &.{ "opening_assets", "opening_audience", "event_runtime" } },
        .{ "descriptor_release", "src/opening/descriptor_release.zig", &.{"movement_batch"} },
        .{ "hero_descriptor", "src/opening/hero_descriptor.zig", &.{"opening_audience"} },
        .{ "opening_routes", "src/opening/routes.zig", &.{"event_runtime"} },
        .{ "draw_record_queue", "src/draw_record_queue.zig", &.{"event_runtime"} },
        .{ "opening_town", "src/opening/town.zig", &.{"event_runtime"} },
        .{ "opening_dungeon", "src/opening/dungeon.zig", &.{ "event_runtime", "opening_assets" } },
        .{ "opening_battle", "src/opening/battle.zig", &.{ "event_runtime", "battle", "combat_session" } },
        .{ "opening_records", "src/opening/records/root.zig", &.{ "field", "opening_assets" } },
        .{ "field_events", "src/field_events.zig", &.{ "field", "event_runtime", "scene_population", "opening_audience", "field_actors", "room2_text", "movement_batch", "descriptor_release", "hero_descriptor", "scene_dispatch", "field_events_data", "fade", "opening_records", "audio_route" } },
        .{ "opening", "src/opening.zig", &.{ "field", "opening_events", "opening_audience", "opening_data" } },
        .{ "opening_start", "src/opening/start.zig", &.{"battle_rules"} },
        .{ "opening_ledger", "src/campaign/opening_ledger.zig", &.{"opening_assets"} },
        .{ "recruitment", "src/recruitment.zig", &.{"battle"} },
        .{ "party_session", "src/party_session/session.zig", &.{ "battle", "field", "recruitment", "combat_systems", "party_data" } },
        .{ "party_content", "src/party_content.zig", &.{"party_session"} },
        .{ "opening_party", "src/opening/party/root.zig", &.{ "party_session", "battle", "opening_records" } },
        .{ "item_ledger", "src/item_ledger/root.zig", &.{ "battle", "field", "party_session" } },
        .{ "route_coordinates", "src/route_coordinates.zig", &.{} },
        .{ "route_transitions", "src/route_transitions.zig", &.{ "event_runtime", "validation", "route_coordinates" } },
        .{ "travel_modes", "src/travel_modes/controller.zig", &.{ "route_transitions", "event_runtime", "travel_data" } },
        .{ "travel_checkpoint", "src/travel_modes/checkpoint.zig", &.{ "travel_modes", "route_transitions", "event_runtime" } },
        .{ "travel", "src/travel/root.zig", &.{ "validation", "event_runtime", "world", "campaign_policies", "field_actors", "opening_audience", "scene_dispatch", "scene_population", "travel_data", "route_coordinates" } },
        .{ "opening_destination", "src/opening/destination.zig", &.{ "travel", "field", "field_actors", "field_events", "event_runtime", "opening_audience", "scene_population", "opening_assets" } },
        .{ "opening_collision", "src/opening/collision/root.zig", &.{ "field_actors", "travel", "opening_audience" } },
        .{ "world_travel", "src/world_travel.zig", &.{ "world", "field", "battle", "world_field", "world_battle", "world_view", "pause_menu", "event_runtime", "field_events", "route_transitions", "travel_modes", "travel", "travel_data", "party_session" } },
        .{ "campaign_session", "src/campaign_session/root.zig", &.{ "campaign_policies", "campaign_policies_data", "world", "world_travel", "battle", "field" } },
        .{ "travel_host", "src/travel_host.zig", &.{ "campaign_state", "travel_data", "travel", "campaign_policies", "world", "world_travel", "field", "event_runtime" } },
        .{ "world_graph", "src/world_graph/root.zig", &.{ "world_graph_data", "validation" } },
        .{ "duel", "src/duel.zig", &.{"duel_data"} },
        .{ "optional_game_contracts", "src/optional_game_contracts.zig", &.{"battle_rules"} },
    };
    for (core_modules) |spec| {
        if (public_replay and std.mem.eql(u8, spec[0], "inn_zon")) {
            r.bind("inn_zon", "replay_data");
        } else r.add(spec[0], spec[1], spec[2]);
    }
    r.bind("owner_state_hq", "hq_state");
    r.bind("palace_fade", "fade");

    const top_modules = [_]ModSpec{
        .{ "hq", "src/hq/root.zig", &.{ "owner_state_hq", "battle", "field", "party_session", "event_runtime", "scene_population", "validation", "campaign_policies", "optional_game_contracts", "hq_data" } },
        .{ "platform_recovery", "src/platform_recovery/root.zig", &.{ "pause_menu", "opening", "field" } },
        .{ "package_host", "src/package_host/root.zig", &.{ "validation", "package_host_data", "hq", "pause_menu" } },
        .{ "route", "src/campaign/route.zig", &.{"field"} },
        .{ "journey_travel", "src/journey_travel.zig", &.{ "field", "world", "travel_modes", "travel", "travel_data", "scene_population" } },
        .{ "war_session", "src/war_session.zig", &.{"war"} },
        .{ "war_content", "src/war_content.zig", &.{"war_data"} },
        .{ "war_view", "src/war_view.zig", &.{ "war", "war_content", "war_data" } },
        .{ "war_view_platform", "src/war_view_platform.zig", &.{ "raylib", "war", "war_view", "ui" } },
        .{ "war_audio_platform", "src/war_audio_platform.zig", &.{ "raylib", "war_content" } },
        .{ "war_mode", "src/war_mode.zig", &.{ "raylib", "raylib_app", "war", "war_session", "war_content", "war_view", "war_view_platform", "war_audio_platform" } },
        .{ "chapters", "src/chapters/root.zig", &.{ "event_runtime", "duel", "war", "war_session", "item_ledger", "party_session", "hq", "battle", "field" } },
        .{ "journey", "src/journey.zig", &.{ "campaign_state", "hq_state", "hq", "opening", "opening_events", "field", "field_events", "battle", "pause_menu", "recruitment", "party_session", "route", "campaign_policies", "field_actors", "save_file", "audio_route", "item_ledger", "dice_presentation", "travel_modes", "journey_travel", "item_overload_data", "duel", "war", "war_session", "war_scenarios_data", "chapters", "final_assets" } },
        .{ "party_host", "src/party_session/host.zig", &.{ "battle", "journey", "party_session" } },
        .{ "journey_content", "src/journey_content.zig", &.{ "field", "field_events", "battle", "journey", "ui_font", "item_ledger", "campaign_policies_data", "hq_data", "audio_route", "dice_presentation", "world_view" } },
        .{ "engine", "src/engine.zig", &.{"journey"} },
        .{ "journey_boot", "src/journey_boot.zig", &.{ "field", "battle", "engine", "journey", "journey_content", "opening", "opening_data", "party_content", "package_host", "save_file" } },
        .{ "journey_persistence", "src/journey_persistence.zig", &.{ "engine", "pause_menu" } },
        .{ "journey_frame", "src/journey_frame.zig", &.{ "journey_content", "field", "battle", "pause_menu", "raylib", "raylib_app", "platform_recovery", "journey_persistence", "journey", "journey_boot", "game", "audio_route", "ui", "menu_layout", "battle_camera", "world_view", "world", "war_content", "war_view", "war_view_platform", "war_manifest_data", "chapters" } },
        .{ "opening_launch", "src/campaign/opening_launch.zig", &.{ "opening_start", "opening_assets", "opening", "opening_events", "opening_audience", "field", "field_events", "opening_destination", "opening_save_policy", "opening_dungeon", "opening_battle", "opening_party" } },
        .{ "opening_package", "src/campaign/opening_package.zig", &.{ "opening_launch", "field" } },
        .{ "opening_export", "src/campaign/opening_export.zig", &.{ "field", "opening_package" } },
        .{ "hq_session", "src/hq_session.zig", &.{ "hq", "journey" } },
        .{ "campaign", "src/campaign/root.zig", &.{ "campaign_content_data", "campaign_content_zon", "opening_ledger", "middle_assets", "journey" } },
    };
    for (top_modules) |spec| r.add(spec[0], spec[1], spec[2]);
    r.get("pause_menu").addImport("hq", r.get("hq"));

    const replay = b.addExecutable(.{
        .name = "simulation-replay",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/simulation_replay.zig"),
            .target = target,
            .optimize = optimize,
            .imports = r.imports(&.{ "engine", "journey", "battle", "field", "field_events" }),
        }),
    });
    replay.stack_size = 64 * 1024 * 1024;
    b.step("simulation-replay", "Build the headless simulation replay runner").dependOn(&b.addInstallArtifact(replay, .{}).step);
    if (public_replay) return;

    const campaign_test = b.step("test-campaign", "Run consolidated campaign and domain integration tests");
    const test_step = b.step("test", "Run headless behavior tests");

    // Primary native executable (headless diagnostics, opening export, journey runtime, war mode).
    const journey_exe = r.addRayExe("suikoden-journey", "src/journey_main.zig", raylib.?, &.{ "journey_boot", "journey_frame", "opening_export", "journey_content", "journey_persistence", "war_mode", "raylib" });
    const install_journey = b.addInstallArtifact(journey_exe, .{});
    b.getInstallStep().dependOn(&install_journey.step);
    b.step("build-journey", "Build only the connected game without launching a window").dependOn(&install_journey.step);
    b.step("run-journey", "Run the connected field/battle episode").dependOn(&b.addRunArtifact(journey_exe).step);
    // Compile the native runtime and views during headless checks without executing a window loop.
    test_step.dependOn(&journey_exe.step);

    // Core, world, and domain test suites.
    const world_filter = b.option([]const u8, "world-test-filter", "Run matching world tests only");
    const world_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/world.zig"),
            .target = target,
            .optimize = optimize,
            .imports = r.imports(&.{ "world", "field", "world_field", "world_battle", "battle", "world_view", "world_travel", "field_events", "party_session", "party_host", "party_data", "route_transitions", "travel_modes", "travel_checkpoint", "route_data", "journey", "pause_menu", "travel_host", "campaign_policies", "combat_session" }),
        }),
        .filters = if (world_filter) |filter| &.{filter} else &.{},
    });
    // Additive Opening field-event state; keep deep replay fixtures off the default test stack.
    world_tests.stack_size = 64 * 1024 * 1024;
    b.step("test-world", "Check source world traversal and encounter boundaries without media").dependOn(&b.addRunArtifact(world_tests).step);

    _ = r.addTest(test_step, "tests/event_runtime.zig", &.{ "event_runtime", "opening_event_adapter", "opening_audience", "field_actors", "wheel_data" }, true);
    _ = r.addTest(test_step, "tests/scene_population.zig", &.{ "scene_population", "event_runtime", "pause_menu" }, true);
    _ = r.addTest(test_step, "tests/duel.zig", &.{"duel"}, false);
    _ = r.addTest(test_step, "tests/room_package.zig", &.{ "field", "save_file", "pause_menu" }, false);
    _ = r.addTest(test_step, "tests/journey_content.zig", &.{ "journey_content", "journey", "battle", "field", "party_content", "party_session", "party_data", "journey_boot", "journey_frame", "audio_route", "event_runtime", "field_events", "ui_font", "pause_menu" }, false);
    _ = r.addTest(test_step, "tests/root.zig", &.{ "game", "field", "battle", "save_file", "pause_menu", "journey", "party_session", "party_data", "opening", "opening_events", "opening_audience", "demo_batch", "audio_route", "ui_font", "battle_camera", "dice_presentation", "campaign", "campaign_policies_data" }, false);
    _ = r.addTest(test_step, "tests/route_transitions.zig", &.{ "route_transitions", "event_runtime" }, true);
    _ = r.addTest(test_step, "tests/scene_dispatch.zig", &.{ "scene_dispatch", "scene_population", "event_runtime" }, true);
    _ = r.addTest(test_step, "tests/war.zig", &.{"war"}, true);
    _ = r.addTest(test_step, "tests/war_content.zig", &.{"war_content"}, true);
    _ = r.addTest(test_step, "tests/war_session.zig", &.{ "war", "war_session" }, true);
    _ = r.addTest(test_step, "tests/war_view.zig", &.{ "war", "war_content", "war_view" }, true);

    _ = r.addTest(b.step("test-settings", "Check ZON settings persistence and legacy JSON fallback"), "tests/settings.zig", &.{"settings"}, false);
    _ = r.addTest(b.step("test-zon-data", "Check embedded ZON data against JSON oracles"), "tests/zon_data.zig", &.{"field"}, false);
    _ = r.addTest(b.step("test-hq-launch", "Check the production HQ context entry point"), "tests/hq/launch.zig", &.{"hq"}, false);
    _ = r.addTest(b.step("test-hq-session", "Check the production HQ constructor"), "tests/hq/session.zig", &.{"hq_session"}, false);

    _ = r.addTest(campaign_test, "tests/opening_suite.zig", &.{ "field", "battle", "pause_menu", "event_runtime", "opening_audience", "room2_text", "opening_assets", "opening_audio", "movement_batch", "descriptor_release", "hero_descriptor", "opening_routes", "palace_fade", "opening_town", "draw_record_queue", "opening_dungeon", "opening_battle", "combat_session", "opening_records", "area_host", "opening_party", "party_session", "party_data", "party_content", "opening_destination", "travel", "opening_collision", "field_actors", "field_events", "opening_ledger", "route", "opening_package", "journey", "journey_content", "journey_boot" }, false);
    _ = r.addTest(campaign_test, "tests/campaign_policies_suite.zig", &.{ "campaign_policies", "campaign_policies_data", "battle_rules", "battle", "field", "party_session", "item_ledger", "world", "world_view", "campaign_session" }, true);
    _ = r.addTest(campaign_test, "tests/travel_suite.zig", &.{ "travel", "travel_data", "event_runtime", "pause_menu", "campaign_policies", "world", "field_actors", "opening_audience", "scene_dispatch", "scene_population" }, true);
    _ = r.addTest(campaign_test, "tests/battle_systems_suite.zig", &.{ "battle_systems", "battle_systems_data", "battle_rules", "campaign_policies", "battle", "world_battle", "world", "field", "combat_session" }, true);
    _ = r.addTest(campaign_test, "tests/combat_systems_suite.zig", &.{ "combat_systems", "combat_systems_data", "battle", "battle_rules", "field" }, true);
    _ = r.addTest(campaign_test, "tests/hq_suite.zig", &.{ "hq", "hq_data", "event_runtime", "scene_population", "battle", "field", "party_session", "optional_game_contracts", "hq_session" }, true);
    _ = r.addTest(campaign_test, "tests/package_host_suite.zig", &.{ "world_graph", "package_host", "package_host_data", "platform_recovery", "pause_menu", "field", "hq", "hq_data", "opening_data" }, true);
    _ = r.addTest(campaign_test, "tests/chapters_suite.zig", &.{ "chapters", "middle_assets", "final_assets", "event_runtime", "duel", "war", "war_session", "battle", "item_ledger", "campaign_policies_data", "party_session", "hq", "hq_data", "field" }, true);
    _ = r.addTest(campaign_test, "tests/campaign_status.zig", &.{"campaign"}, false);
    _ = r.addTest(campaign_test, "tests/optional_game_contracts.zig", &.{"optional_game_contracts"}, false);
}

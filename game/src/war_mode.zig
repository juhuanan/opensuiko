const std = @import("std");
const rl = @import("raylib");
const raylib_app = @import("raylib_app");
const war = @import("war");
const session = @import("war_session");
const content = @import("war_content");
const view = @import("war_view");
const view_platform = @import("war_view_platform");
const audio_platform = @import("war_audio_platform");

fn readWarAsset(io: std.Io, allocator: std.mem.Allocator, repo_rel: []const u8, game_rel: []const u8, limit: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, repo_rel, allocator, .limited(limit)) catch |err| switch (err) {
        error.FileNotFound => try std.Io.Dir.cwd().readFileAlloc(io, game_rel, allocator, .limited(limit)),
        else => return err,
    };
}

fn dirExists(io: std.Io, path: []const u8) bool {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

fn openWarAudio(init: std.process.Init, audio: content.Audio) !audio_platform.Platform {
    const audio_dir = if (dirExists(init.io, "../kit/work/accepted/audio")) "../kit/work/accepted/audio" else "kit/work/accepted/audio";
    return audio_platform.Platform.open(init, audio_dir, audio);
}

pub fn check(init: std.process.Init) !void {
    const allocator = init.gpa;
    const rules_bytes = try readWarAsset(init.io, allocator, "game/assets/war/scenarios.json", "assets/war/scenarios.json", war.max_json_bytes);
    defer allocator.free(rules_bytes);
    const rules = try war.load(allocator, rules_bytes);
    defer rules.deinit();
    std.debug.print("{{\"schema\":\"suikoden-war-check/1\",\"scenarios\":{d}}}\n", .{rules.value.scenarios.len});
}

pub fn run(init: std.process.Init, selector_arg: ?[]const u8) !void {
    const allocator = init.gpa;
    const selector: u8 = if (selector_arg) |arg| try std.fmt.parseInt(u8, arg, 10) else 0;
    const rules_bytes = try readWarAsset(init.io, allocator, "game/assets/war/scenarios.json", "assets/war/scenarios.json", war.max_json_bytes);
    defer allocator.free(rules_bytes);
    const rules = try war.load(allocator, rules_bytes);
    defer rules.deinit();
    if (selector >= rules.value.scenarios.len) return error.UnknownWarScenario;
    const scenario = rules.value.scenarios[selector];
    var session_value = try session.Session.init(allocator, .{ .scenario = scenario, .rng = .{ .state = 1 } });
    defer session_value.deinit();
    const manifest_bytes = try readWarAsset(init.io, allocator, "game/assets/war/content_manifest.json", "assets/war/content_manifest.json", content.max_json_bytes);
    defer allocator.free(manifest_bytes);
    const manifest = try content.load(allocator, manifest_bytes);
    defer manifest.deinit();
    var model = try view.View.init(manifest.value, scenario.id);

    try raylib_app.initWindow(.{
        .width = 960,
        .height = 720,
        .title = "Suikoden - War",
        .min_width = 640,
        .min_height = 480,
        .resizable = true,
        .vsync = true,
    });
    defer rl.closeWindow();

    var platform = try view_platform.Platform.init();
    defer platform.deinit();
    var audio = try openWarAudio(init, manifest.value.audio);
    defer audio.deinit();

    while (!rl.windowShouldClose()) {
        const input: session.Input = .{
            .up = rl.isKeyDown(.up) or rl.isKeyDown(.w),
            .down = rl.isKeyDown(.down) or rl.isKeyDown(.s),
            .left = rl.isKeyDown(.left) or rl.isKeyDown(.a),
            .right = rl.isKeyDown(.right) or rl.isKeyDown(.d),
            .confirm = rl.isKeyDown(.enter) or rl.isKeyDown(.space),
            .cancel = rl.isKeyDown(.backspace) or rl.isKeyDown(.escape),
            .target = rl.isKeyDown(.tab),
            .restart = rl.isKeyDown(.r),
        };
        try session_value.update(input);
        audio.update();
        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(.black);
        try platform.draw(&model, &session_value.engine, session_value.command_index, "Press R to restart");
    }
}

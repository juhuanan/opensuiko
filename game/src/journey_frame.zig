const std = @import("std");
const controller_platform = @import("controller_platform.zig");
const settings_platform = @import("settings_platform.zig");
const rl = @import("raylib");
const raylib_app = @import("raylib_app");
const field = @import("field");
const battle = @import("battle");
const pause = @import("pause_menu");
const audio = @import("audio.zig");
const persistence = @import("journey_persistence");
const boot = @import("journey_boot");
const field_view = @import("field_view.zig");
const menu_view = @import("menu_view.zig");
const overload_view = @import("item_overload_view.zig");
const battle_view = @import("battle_trial_view.zig");
const ui = @import("ui");
const title_view = @import("title_view.zig");
const movie_player_mod = @import("movie_player.zig");
const recovery_layer = @import("platform_recovery");
const journey = @import("journey");
const duel_presentation = @import("journey_content").duel_presentation;
const dice_view = @import("dice_view.zig");
const side_game_view = @import("side_game_view.zig");
const party_view = @import("party_view.zig");
const world_view = @import("world_view");
const world = @import("world");
const war_content = @import("war_content");
const war_view = @import("war_view");
const war_view_platform = @import("war_view_platform");
const war_manifest_data = @import("war_manifest_data");
const chapters = @import("chapters");
const dialogue_presentation = journey.field_dialogue_view.presentation;

const WarRenderer = struct {
    canvas: rl.RenderTexture2D,
    platform: ?war_view_platform.Platform = null,
    manifest: ?std.json.Parsed(war_content.Manifest) = null,
    view_model: ?war_view.View = null,
    cached_scenario: [64]u8 = @splat(0),
    cached_len: usize = 0,

    fn init() !WarRenderer {
        return .{ .canvas = try raylib_app.loadPointCanvas(war_view.width, war_view.height) };
    }

    fn deinit(self: *WarRenderer) void {
        if (self.platform) |*platform| platform.deinit();
        if (self.manifest) |manifest| manifest.deinit();
        rl.unloadRenderTexture(self.canvas);
        self.* = undefined;
    }

    fn prepare(self: *WarRenderer, allocator: std.mem.Allocator, engine: anytype, command_index: u8) !void {
        if (self.manifest == null) self.manifest = try war_content.load(allocator, war_manifest_data.json);
        if (self.platform == null) self.platform = try war_view_platform.Platform.init();
        const scenario_id = engine.scenario.id;
        if (self.view_model == null or !std.mem.eql(u8, self.cached_scenario[0..self.cached_len], scenario_id)) {
            self.view_model = try war_view.View.init(self.manifest.?.value, scenario_id);
            const copy_len = @min(scenario_id.len, self.cached_scenario.len);
            @memcpy(self.cached_scenario[0..copy_len], scenario_id[0..copy_len]);
            self.cached_len = copy_len;
        }
        rl.beginTextureMode(self.canvas);
        defer rl.endTextureMode();
        rl.clearBackground(.black);
        try self.platform.?.draw(&self.view_model.?, engine, command_index, "Confirm to continue");
    }
};

fn findPortraitRect(rooms: anytype, prefix: []const u8) ?field.Rect {
    const rb = rooms orelse return null;
    for (rb.bindings) |binding| {
        for (binding.dialogue.images) |image| {
            if (std.mem.startsWith(u8, image.id, prefix)) return image.atlas_rect;
        }
    }
    return null;
}

fn drawMultilineText(bytes: []const u8, x: i32, y: i32, line_step: i32, size: i32, color: rl.Color) void {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var row_y = y;
    while (lines.next()) |line| : (row_y += line_step) {
        ui.text(line, x, row_y, size, color);
    }
}

fn drawDuelFighterCard(
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    name: []const u8,
    fighter: journey.duel.FighterState,
    atlas: rl.Texture2D,
    portrait_rect: ?field.Rect,
    is_player: bool,
) void {
    ui.window(x, y, w, h);
    const frame_x = x + 12;
    const frame_y = y + 12;
    rl.drawRectangle(frame_x - 1, frame_y - 1, 130, 130, .{ .r = 16, .g = 22, .b = 36, .a = 255 });
    rl.drawRectangleLines(frame_x - 1, frame_y - 1, 130, 130, if (is_player) rl.Color.gold else rl.Color{ .r = 210, .g = 90, .b = 90, .a = 255 });
    if (portrait_rect) |rect| {
        rl.drawTexturePro(
            atlas,
            .{ .x = @floatFromInt(rect.x), .y = @floatFromInt(rect.y), .width = @floatFromInt(rect.w), .height = @floatFromInt(rect.h) },
            .{ .x = @floatFromInt(frame_x), .y = @floatFromInt(frame_y), .width = 128, .height = 128 },
            .{ .x = 0, .y = 0 },
            0,
            .white,
        );
    }
    const info_x = frame_x + 140;
    ui.text(name, info_x, y + 16, 17, if (is_player) .gold else .ray_white);
    ui.text(if (is_player) "Ally" else "Challenger", info_x, y + 38, 12, .light_gray);
    drawDuelHealth(info_x, y + 66, 138, fighter);
    ui.numberText("HP {d}/{d}", .{ fighter.hp, fighter.maximum_hp }, info_x, y + 88, 15, .ray_white);
    ui.numberText("ATK {d}  DEF {d}", .{ fighter.attack, fighter.defense }, info_x, y + 114, 13, .light_gray);
}

fn drawDuelHealth(bar_x: i32, bar_y: i32, bar_w: i32, fighter: journey.duel.FighterState) void {
    drawDuelHealthFill(bar_x, bar_y, bar_w, 14, fighter);
    rl.drawRectangleLines(bar_x, bar_y, bar_w, 14, .light_gray);
}

fn drawDuelHealthFill(bar_x: i32, bar_y: i32, bar_w: i32, bar_h: i32, fighter: journey.duel.FighterState) void {
    rl.drawRectangle(bar_x, bar_y, bar_w, bar_h, .{ .r = 35, .g = 18, .b = 22, .a = 255 });
    const clamped_hp = @max(@as(i32, 0), @min(fighter.hp, fighter.maximum_hp));
    const fill_w: i32 = if (fighter.maximum_hp > 0) @intCast(@divTrunc(@as(i64, clamped_hp) * bar_w, fighter.maximum_hp)) else 0;
    const fill_color: rl.Color = if (clamped_hp * 4 <= fighter.maximum_hp)
        .{ .r = 220, .g = 60, .b = 60, .a = 255 }
    else if (clamped_hp * 2 <= fighter.maximum_hp)
        .{ .r = 230, .g = 190, .b = 50, .a = 255 }
    else
        .{ .r = 65, .g = 200, .b = 95, .a = 255 };
    if (fill_w > 0) rl.drawRectangle(bar_x, bar_y, fill_w, bar_h, fill_color);
}

fn drawDuelStage(scene: duel_presentation.Scene, atlas: rl.Texture2D, duel_state: journey.duel.State, elapsed: u64) void {
    if (scene.backdrop) |backdrop| {
        rl.drawTexturePro(atlas, .{
            .x = @floatFromInt(backdrop.x),
            .y = @floatFromInt(backdrop.y),
            .width = @floatFromInt(backdrop.w),
            .height = @floatFromInt(backdrop.h),
        }, .{ .x = 12, .y = 48, .width = duel_presentation.width, .height = duel_presentation.height }, .{ .x = 0, .y = 0 }, 0, .white);
    } else {
        ui.window(12, 48, duel_presentation.width, duel_presentation.height);
    }
    for ([_]journey.duel.Side{ .player, .opponent }) |side| {
        const frame = scene.frame(duel_state, side, elapsed);
        if (!frame.visible) continue;
        const rect = frame.rect;
        const hit_flash = if (duel_state.last_hit) |hit| hit.target == side and hit.damage > 0 else false;
        rl.drawTexturePro(atlas, .{
            .x = @floatFromInt(rect.x),
            .y = @floatFromInt(rect.y),
            .width = @floatFromInt(if (frame.mirror) -rect.w else rect.w),
            .height = @floatFromInt(rect.h),
        }, .{
            .x = @floatFromInt(12 + frame.x),
            .y = @floatFromInt(48 + frame.y),
            .width = @floatFromInt(rect.w),
            .height = @floatFromInt(rect.h),
        }, .{ .x = 0, .y = 0 }, 0, if (frame.flash or hit_flash) .red else .white);
    }
    for (duel_state.fighters, duel_state.duel.fighters, [_]i32{ 24, 480 }, 0..) |fighter, profile, x, side| {
        ui.panel(x - 4, 52, 139, if (scene.gauges != null) 53 else 39);
        ui.text(profile.name, x, 55, 14, .ray_white);
        if (scene.gauges) |gauges| {
            const gauge = gauges[side];
            const y = 70;
            // The two orientations have the same opening with different left margins.
            drawDuelHealthFill(x + (if (side == 0) @as(i32, 4) else 9), y + 21, 115, 6, fighter);
            rl.drawTextureRec(atlas, .{
                .x = @floatFromInt(gauge.x),
                .y = @floatFromInt(gauge.y),
                .width = @floatFromInt(gauge.w),
                .height = @floatFromInt(gauge.h),
            }, .{ .x = @floatFromInt(x), .y = y }, .white);
        } else {
            drawDuelHealth(x, 74, 130, fighter);
        }
    }
}

fn crossingMotion(motion: anytype) world.State {
    return .{
        .camera = .{ .x = motion.position.x, .y = motion.position.y },
        .heading = switch (motion.heading) {
            .north => .north,
            .east => .east,
            .south => .south,
            .west => .west,
        },
        .remaining = motion.remaining,
        .boat = true,
        .scripted = true,
    };
}

fn crossingState(state: *const journey.State) ?world.State {
    if (state.auto_travel) |active| {
        if (!active.flight) return crossingMotion(active.controller.state);
    }
    if (state.boat_travel) |active| return active.motion();
    return null;
}

pub fn checkCrossingAtlas(allocator: std.mem.Allocator, state: *const boot.Boot) !void {
    const model = state.bundle.crossing_art orelse return;
    const image = try raylib_app.loadImage(allocator, state.path, model.atlas);
    defer rl.unloadImage(image);
    try model.validateAtlas(image.width, image.height);
}

fn drawDialogue(list: *const dialogue_presentation.List, atlas: rl.Texture2D, scale: f32, top: f32) void {
    for (list.pieces[0..list.length]) |piece| switch (piece) {
        .sprite => |sprite| {
            const rect = sprite.rect;
            rl.drawTexturePro(atlas, .{ .x = @floatFromInt(rect.x), .y = @floatFromInt(rect.y), .width = @floatFromInt(if (sprite.mirror) -rect.w else rect.w), .height = @floatFromInt(rect.h) }, .{
                .x = @as(f32, @floatFromInt(sprite.x)) * scale,
                .y = top + @as(f32, @floatFromInt(sprite.y)) * scale,
                .width = @as(f32, @floatFromInt(sprite.width)) * scale,
                .height = @as(f32, @floatFromInt(sprite.height)) * scale,
            }, .{ .x = 0, .y = 0 }, 0, .{ .r = sprite.color[0], .g = sprite.color[1], .b = sprite.color[2], .a = 255 });
        },
        .line => |line| rl.drawLineV(
            .{ .x = @as(f32, @floatFromInt(line.x1)) * scale, .y = top + @as(f32, @floatFromInt(line.y1)) * scale },
            .{ .x = @as(f32, @floatFromInt(line.x2)) * scale, .y = top + @as(f32, @floatFromInt(line.y2)) * scale },
            .{ .r = line.red, .g = line.green, .b = line.blue, .a = 255 },
        ),
        .additive_fill => |fill| {
            rl.beginBlendMode(.additive);
            rl.drawRectangleRec(.{
                .x = @as(f32, @floatFromInt(fill.rect.x)) * scale,
                .y = top + @as(f32, @floatFromInt(fill.rect.y)) * scale,
                .width = @as(f32, @floatFromInt(fill.rect.w)) * scale,
                .height = @as(f32, @floatFromInt(fill.rect.h)) * scale,
            }, .{ .r = fill.red, .g = fill.green, .b = fill.blue, .a = 255 });
            rl.endBlendMode();
        },
        .solid_fill => |fill| rl.drawRectangleRec(.{
            .x = @as(f32, @floatFromInt(fill.rect.x)) * scale,
            .y = top + @as(f32, @floatFromInt(fill.rect.y)) * scale,
            .width = @as(f32, @floatFromInt(fill.rect.w)) * scale,
            .height = @as(f32, @floatFromInt(fill.rect.h)) * scale,
        }, .{ .r = fill.color[0], .g = fill.color[1], .b = fill.color[2], .a = 255 }),
        .styled_window => |window| ui.drawWindowAppearance(
            window.appearance,
            @intFromFloat(@as(f32, @floatFromInt(window.rect.x)) * scale),
            @intFromFloat(top + @as(f32, @floatFromInt(window.rect.y)) * scale),
            @intFromFloat(@as(f32, @floatFromInt(window.rect.w)) * scale),
            @intFromFloat(@as(f32, @floatFromInt(window.rect.h)) * scale),
        ),
    };
}

pub fn checkFieldAtlas(allocator: std.mem.Allocator, state: *const boot.Boot) !void {
    const image = try raylib_app.loadImage(allocator, state.path, "atlas.png");
    defer rl.unloadImage(image);
    try state.bundle.package.validateAtlas(image.width, image.height);
    if (state.bundle.ui) |font| try font.validate(image.width, image.height);
    if (state.bundle.room_battles) |rooms| {
        try rooms.validatePortraitAtlas(image.width, image.height);
        try rooms.validateActorAtlas(image.width, image.height);
    }
}

pub fn checkDiceAtlas(allocator: std.mem.Allocator, state: *const boot.Boot) !void {
    if (state.bundle.dice_model == null) return;
    const font = state.bundle.ui orelse return error.MissingDiceFont;
    const model = state.bundle.dice_model.?;
    for (model.texts()) |text| for (text.tokens) |token| if (token.text) |bytes| for (bytes) |byte| {
        if (font.glyph(byte) == null) return error.MissingDiceGlyph;
    };
    for ([_][]const u8{ model.hud.bet_label, model.hud.money_label, "0123456789" }) |text| for (text) |byte| {
        if (font.glyph(byte) == null) return error.MissingDiceGlyph;
    };
    for (model.entry_layout.choices.text) |byte| if (byte != '\n' and font.glyph(byte) == null) return error.MissingDiceGlyph;
    const image = try raylib_app.loadImage(allocator, state.path, journey.dice.visual.texture_path);
    defer rl.unloadImage(image);
    try journey.dice.visual.validateAtlas(image.width, image.height);
    const portraits = try raylib_app.loadImage(allocator, state.path, journey.dice.visual.portrait_texture_path);
    defer rl.unloadImage(portraits);
    try journey.dice.visual.validatePortraitAtlas(portraits.width, portraits.height);
}

pub fn checkDuelAtlas(allocator: std.mem.Allocator, state: *const boot.Boot) !void {
    const packet = state.bundle.duel_art orelse return;
    const image = try raylib_app.loadImage(allocator, state.path, duel_presentation.atlas_path);
    defer rl.unloadImage(image);
    try packet.validateAtlas(image.width, image.height);
}

pub fn checkSceneryAtlases(allocator: std.mem.Allocator, state: *const boot.Boot) !void {
    for (state.bundle.package.rooms) |room| if (room.scenery_atlas) |path| {
        const image = raylib_app.loadImage(allocator, state.path, path) catch |err| {
            std.log.err("Scenery for {s} ({s}): {s}", .{ room.id, path, @errorName(err) });
            return err;
        };
        defer rl.unloadImage(image);
        room.validateSceneryAtlas(image.width, image.height) catch |err| {
            std.log.err("Scenery for {s} ({s}): {s}", .{ room.id, path, @errorName(err) });
            return err;
        };
    };
}

pub fn checkBattleImages(allocator: std.mem.Allocator, root: []const u8, content: battle.Content) !void {
    for ([_][]const u8{ "battle/actors.png", "battle/floor.png" }, 0..) |name, i| {
        const image = raylib_app.loadImage(allocator, root, name) catch |err| {
            std.log.err("Battle image ({s}): {s}", .{ name, @errorName(err) });
            return err;
        };
        defer rl.unloadImage(image);
        const valid: anyerror!void = if (i == 0) content.validateAtlas(image.width, image.height) else if (image.width != 320 or image.height != 240) error.InvalidBattleFloor else {};
        valid catch |err| {
            std.log.err("Battle image ({s}): {s}", .{ name, @errorName(err) });
            return err;
        };
    }
}

pub fn checkSpellAtlas(allocator: std.mem.Allocator, state: *const boot.Boot) !void {
    const packet = state.bundle.spell_scenes orelse return;
    const image = try raylib_app.loadImage(allocator, state.path, "battle/spell_effects.png");
    defer rl.unloadImage(image);
    try packet.validate(image.width, image.height);
}

pub fn checkBattlefieldAtlas(allocator: std.mem.Allocator, root: []const u8, content: battle.Content) !void {
    if (content.battlefields.len == 0) return;
    const image = try raylib_app.loadImage(allocator, root, "battle/ground.png");
    defer rl.unloadImage(image);
    try content.validateGroundAtlas(image.width, image.height);
}

fn inspectTitleSaves(init: std.process.Init, save_path: ?[]const u8, state: *journey.State, title: *pause.title.State) void {
    if (save_path) |save| {
        persistence.apply(init, save, state, .inspect_saves) catch {
            title.message = "The save directory could not be read.";
            return;
        };
        title.ready(state.menu.summaries);
    }
}

pub fn run(init: std.process.Init, boot_state: *boot.Boot) !void {
    const allocator = init.gpa;
    var state = boot_state.state;
    defer state.releaseRestoredSave();
    const package = boot_state.bundle.package;
    const content = boot_state.bundle.combat;
    const path = boot_state.path;
    const save_path = boot_state.save_path;
    try checkFieldAtlas(allocator, boot_state);
    try checkDiceAtlas(allocator, boot_state);
    try checkDuelAtlas(allocator, boot_state);
    try checkCrossingAtlas(allocator, boot_state);
    try checkBattleImages(allocator, path, content);
    try checkBattlefieldAtlas(allocator, path, content);
    state.menu.preferences = settings_platform.load(init, save_path);
    try raylib_app.initWindow(.{
        .width = 1280,
        .height = 960,
        .title = "Suikoden",
        .min_width = 640,
        .min_height = 480,
        .resizable = true,
        .vsync = state.menu.preferences.vsync,
    });
    defer rl.closeWindow();
    settings_platform.apply(state.menu.preferences);
    var ui_context: ui.Context = .{};
    var audio_player = try audio.Player.init(init, path, boot_state.bundle.region_bgm);
    defer audio_player.deinit();
    audio_player.setVolume(state.menu.preferences.musicVolume());
    audio_player.setEffectsVolume(state.menu.preferences.effectsVolume());
    var movie_player = movie_player_mod.MoviePlayer.init(init.io, allocator, path, audio_player.ready);
    defer movie_player.deinit();
    var title_media = title_view.Media.init(allocator, path, audio_player.ready);
    defer title_media.deinit();
    const atlas = try raylib_app.loadPointTexture(allocator, path, "atlas.png");
    defer rl.unloadTexture(atlas);
    try package.validateAtlas(atlas.width, atlas.height);
    const dice_atlas = if (boot_state.bundle.dice_model != null) try raylib_app.loadPointTexture(allocator, path, journey.dice.visual.texture_path) else null;
    defer if (dice_atlas) |texture| rl.unloadTexture(texture);
    if (dice_atlas) |texture| try journey.dice.visual.validateAtlas(texture.width, texture.height);
    const duel_atlas = if (boot_state.bundle.duel_art != null)
        try raylib_app.loadPointTexture(allocator, path, duel_presentation.atlas_path)
    else
        null;
    defer if (duel_atlas) |texture| rl.unloadTexture(texture);
    const crossing_atlas = if (boot_state.bundle.crossing_art) |model| try raylib_app.loadPointTexture(allocator, path, model.atlas) else null;
    defer if (crossing_atlas) |texture| rl.unloadTexture(texture);
    const crossing_view = if (boot_state.bundle.crossing_art) |model| view: {
        const value = try allocator.create(world_view.State);
        // shortcut: first entry starts at phase10; bind the prior world clock before canonical admission.
        value.* = world_view.State.init(model.*);
        break :view value;
    } else null;
    defer if (crossing_view) |view| allocator.destroy(view);
    const dice_portraits = if (boot_state.bundle.dice_model != null) try raylib_app.loadPointTexture(allocator, path, journey.dice.visual.portrait_texture_path) else null;
    defer if (dice_portraits) |texture| rl.unloadTexture(texture);
    if (dice_portraits) |texture| try journey.dice.visual.validatePortraitAtlas(texture.width, texture.height);
    var scenery_room: ?usize = null;
    var scenery: ?rl.Texture2D = null;
    defer if (scenery) |texture| rl.unloadTexture(texture);
    if (boot_state.bundle.ui) |*font| {
        try font.validate(atlas.width, atlas.height);
        ui_context = .{ .font = font, .atlas = atlas };
        ui.configure(font, atlas);
    }
    const scripted_dialogue = if (boot_state.bundle.room_battles != null and ui_context.font != null) try allocator.create(dialogue_presentation.List) else null;
    defer if (scripted_dialogue) |list| allocator.destroy(list);
    const actors = try raylib_app.loadPointTexture(allocator, path, "battle/actors.png");
    defer rl.unloadTexture(actors);
    try content.validateAtlas(actors.width, actors.height);
    var dynamic_effect = try @import("battle_spell_view.zig").DynamicTexture.init();
    defer dynamic_effect.deinit();
    const effect_atlas: ?rl.Texture2D = if (state.combat.spell_scenes != null) try raylib_app.loadPointTexture(allocator, path, "battle/spell_effects.png") else null;
    defer if (effect_atlas) |image| rl.unloadTexture(image);
    if (state.combat.spell_scenes) |packet| try packet.validate(effect_atlas.?.width, effect_atlas.?.height);
    const floor = try raylib_app.loadPointTexture(allocator, path, "battle/floor.png");
    defer rl.unloadTexture(floor);
    const battle_ground: ?rl.Texture2D = raylib_app.loadPointTexture(allocator, path, "battle/ground.png") catch |err| blk: {
        if (content.battlefields.len != 0) return err;
        break :blk null;
    };
    defer if (battle_ground) |ground| rl.unloadTexture(ground);
    const canvas = try raylib_app.loadPointCanvas(640, 480);
    defer rl.unloadRenderTexture(canvas);
    const outgoing_canvas = try raylib_app.loadPointCanvas(canvas.texture.width, canvas.texture.height);
    defer rl.unloadRenderTexture(outgoing_canvas);
    var mode_fade: recovery_layer.display.ModeFade = .{};
    var presented_mode: ?journey.Mode = null;
    const field_canvas = try raylib_app.loadPointCanvas(512, 432);
    defer rl.unloadRenderTexture(field_canvas);
    var war_renderer = try WarRenderer.init();
    defer war_renderer.deinit();
    var party_background: ?party_view.Background = null;
    defer if (party_background) |background| background.deinit();
    var wheel_shadow_shader: ?rl.Shader = null;
    defer if (wheel_shadow_shader) |shader| rl.unloadShader(shader);
    var field_effect_half_shader: ?rl.Shader = null;
    defer if (field_effect_half_shader) |shader| rl.unloadShader(shader);
    var clock: f64 = 0;
    var menu_input = pause.Input{};
    var battle_input = battle.Input{};
    var dice_sampler: journey.dice.Entry.Sampler = .{};
    var dice_input: journey.dice.Entry.Controls = .{};
    var party_sampler: journey.party_selection.selector.Sampler = .{};
    var collision = false;
    var controller = controller_platform.State{};
    var recovery: recovery_layer.Recovery = .{ .mode = .field };
    var typed: [32]u8 = undefined;
    var typed_len: usize = 0;
    var title = pause.title.State.bootWithMovies();
    title.opening_context = true;
    title.awaiting_start = true;
    _ = recovery.begin(.title);
    inspectTitleSaves(init, save_path, &state, &title);
    while (!rl.windowShouldClose()) {
        var fade_updates: u8 = 0;
        const focused = rl.isWindowFocused();
        recovery.focus(focused);
        if (focused) {
            const pad = controller.poll();
            recovery.device(controller.device != null, controller.device);
            dice_input.merge(dice_view.poll(&dice_sampler, title.phase == .playing and state.dice_game != null, controller.device));
            const naming = state.menu.phase == .name_save or title.phase == .hero_name;
            while (true) {
                const character = rl.getCharPressed();
                if (character == 0) break;
                if (naming and character >= 32 and character <= 126 and typed_len < typed.len) {
                    typed[typed_len] = @intCast(character);
                    typed_len += 1;
                }
            }
            const erase_key = rl.isKeyPressed(.backspace) or rl.isKeyPressedRepeat(.backspace);
            menu_input.text = if (state.menu.phase == .name_save) typed[0..typed_len] else &.{};
            menu_input.erase = menu_input.erase or (state.menu.phase == .name_save and erase_key);
            if (rl.isKeyPressed(.f2)) collision = !collision;
            const nav: @TypeOf(pad.navigation) = if (title.phase == .hero_name)
                if (pad.navigation == .up or rl.isKeyPressed(.up)) .up else if (pad.navigation == .down or rl.isKeyPressed(.down)) .down else if (pad.navigation == .left or rl.isKeyPressed(.left)) .left else if (pad.navigation == .right or rl.isKeyPressed(.right)) .right else null
            else if (pad.navigation == .up or raylib_app.anyKeyPressed(.up, .w)) .up else if (pad.navigation == .down or raylib_app.anyKeyPressed(.down, .s)) .down else if (pad.navigation == .left or raylib_app.anyKeyPressed(.left, .a)) .left else if (pad.navigation == .right or raylib_app.anyKeyPressed(.right, .d)) .right else null;
            const raw = recovery_layer.Sample{
                .direction = raylib_app.heldDirection(field.Direction) orelse pad.direction,
                .navigation = nav,
                .confirm = pad.confirm or (if (naming) rl.isKeyPressed(.enter) else raylib_app.anyKeyPressed(.z, .enter) or (state.mode == .field and rl.isKeyPressed(.space))),
                .cancel = pad.cancel or (if (naming) rl.isKeyPressed(.escape) else raylib_app.anyKeyPressed(.x, .escape)),
                .menu = pad.menu or raylib_app.anyKeyPressed(.tab, .escape),
                .physical_up = pad.physical_up,
            };
            const safe = recovery.frame(raw);
            const confirm = safe.confirm;
            const cancel = safe.cancel;
            const up = safe.navigation == .up;
            const down = safe.navigation == .down;
            const left = safe.navigation == .left;
            const right = safe.navigation == .right;
            if (title.phase != .playing) {
                const title_text = if (title.phase == .hero_name) typed[0..typed_len] else &.{};
                const effect = title.tick(.{
                    .up = up,
                    .down = down,
                    .left = left,
                    .right = right,
                    .confirm = confirm,
                    .cancel = cancel,
                    .erase = title.phase == .hero_name and erase_key,
                    .text = title_text,
                });
                typed_len = 0;
                switch (effect) {
                    .quit => break,
                    .start_opening => {
                        const preferences = state.menu.preferences;
                        const next = try boot_state.newStateNamed(title.heroName());
                        state.releaseRestoredSave();
                        state = next;
                        state.menu.preferences = preferences;
                        clock = 0;
                        controller = .{};
                        _ = recovery.begin(.field);
                    },
                    .start_episode => {
                        const preferences = state.menu.preferences;
                        const next = try boot_state.newState();
                        state.releaseRestoredSave();
                        state = next;
                        state.menu.preferences = preferences;
                        clock = 0;
                        controller = .{};
                        _ = recovery.begin(.field);
                    },
                    .inspect => if (save_path) |save| {
                        persistence.apply(init, save, &state, .inspect_saves) catch {
                            title.message = "The save directory could not be read.";
                        };
                        title.summaries = state.menu.summaries;
                    },
                    .load => if (save_path) |save| {
                        state.menu.save_slot = title.slot;
                        if (persistence.apply(init, save, &state, .load)) |_| {
                            title.phase = .playing;
                            clock = 0;
                            controller = .{};
                            _ = recovery.begin(.field);
                        } else |_| title.message = "Load failed. Choose another slot or return.";
                    } else {
                        title.message = "The save directory is unavailable.";
                    },
                    .none => {},
                }
                if (title.phase == .playing) {
                    movie_player.stop();
                    title_media.syncAudio(false, 0);
                } else {
                    clock += @min(rl.getFrameTime(), 0.1);
                    while (clock >= 1.0 / 60.0) : (clock -= 1.0 / 60.0) {
                        _ = title.advanceFrame(.{});
                    }
                    const vol = state.menu.preferences.musicVolume();
                    movie_player.sync(title.phase == .movie, title.movie_stage, title.movie_tick, vol);
                    title_media.syncAudio(title.phase != .movie, vol);
                }
            } else {
                menu_input.field.direction = safe.direction;
                menu_input.field.action = menu_input.field.action or confirm;
                menu_input.field.cancel = menu_input.field.cancel or cancel;
                if (up) menu_input.field.menu_direction = .up;
                if (down) menu_input.field.menu_direction = .down;
                menu_input.menu = menu_input.menu or safe.menu;
                menu_input.left = menu_input.left or left;
                menu_input.right = menu_input.right or right;
                battle_input.up = battle_input.up or up;
                battle_input.down = battle_input.down or down;
                battle_input.left = battle_input.left or left;
                battle_input.right = battle_input.right or right;
                battle_input.confirm = battle_input.confirm or confirm;
                battle_input.cancel = battle_input.cancel or cancel;
                clock += @min(rl.getFrameTime(), 0.1);
                while (clock >= 1.0 / 60.0) : (clock -= 1.0 / 60.0) {
                    fade_updates += 1;
                    const held = dice_view.pollHeld(controller.device);
                    const party_input = party_sampler.sample(.{
                        .up = held.up,
                        .down = held.down,
                        .left = held.left,
                        .right = held.right,
                        .confirm = held.confirm,
                        .cancel = held.cancel,
                    });
                    const crossing_before = crossingState(&state);
                    const boat_advances = state.menu.phase == .closed and (!menu_input.menu or state.field_state.remaining != 0);
                    var dice_landings: u2 = 0;
                    var dice_box_opened = false;
                    var dice_won = false;
                    const effect: pause.Effect = if (state.dice_game != null and journey.dice.usesModel(&state)) blk: {
                        const active = state.dice_game.?;
                        if (!active.entry_audio_ready) {
                            try audio_player.requestDiceMusic(.dice);
                            try journey.dice.tick(&state, .entry_audio_ready);
                        } else if (active.pending_exit and !active.exit_ready) {
                            try audio_player.requestDiceMusic(.dice);
                            try journey.dice.tick(&state, .exit_ready);
                        } else {
                            if (active.pending_exit and active.exit_ready) try audio_player.requestDiceMusic(.area_b);
                            try journey.dice.tickFrame(&state, dice_input);
                            if (active.animation != null) {
                                const frame = state.dice_game.?.frame.?;
                                for (frame.landed) |landed| dice_landings += @intFromBool(landed);
                            }
                        }
                        if (state.dice_game) |next| {
                            dice_box_opened = active.dialogue.phase == .allocate and next.dialogue.phase == .opening;
                            if (active.result) |report| {
                                const advanced = if (next.result) |result| result.cursor != report.cursor else true;
                                const session = state.dice_host.?.session.?.dice;
                                dice_won = report.hand_report and report.cursor == 0 and advanced and
                                    session.phase == .proposal and session.decision.?.outcome == .win;
                            }
                        }
                        state.elapsed_ticks +|= 1;
                        break :blk .none;
                    } else if (state.party_selection) |active| blk: {
                        try state.tickPartySelection(party_input.forPhase(active.menu.phase));
                        state.elapsed_ticks +|= 1;
                        break :blk .none;
                    } else try state.tickWithFieldEvents(menu_input, battle_input);
                    if (state.pendingFieldMusic()) |requested| {
                        const target: @import("audio_route").Track = switch (requested) {
                            .stop, .fade => .none,
                            .ruins => .ruins,
                            .lakeshore => .lakeshore,
                            .headquarters => .headquarters,
                            .founding => .founding,
                            .infiltration => .infiltration,
                            .mansion => .mansion,
                            .wheel => .wheel,
                            .area_b => .area_b,
                        };
                        if (requested == .fade) {
                            audio_player.requestFieldFade();
                            try state.completeFieldMusic(requested);
                        } else {
                            const duplicate = requested != .stop and state.field_state.music == requested;
                            if (duplicate or try audio_player.pollFieldMusic(target)) try state.completeFieldMusic(requested);
                        }
                    }
                    if (crossingState(&state)) |current| {
                        const view = crossing_view orelse return error.MissingCrossingArt;
                        const model = boot_state.bundle.crossing_art.?.*;
                        if (crossing_before) |before| {
                            if (current.scripted) try view.stepScripted(model, before, current) else if (boat_advances) try view.step(model, before, current, .{
                                .direction = if (menu_input.field.direction) |d| switch (d) {
                                    .up => .north,
                                    .right => .east,
                                    .down => .south,
                                    .left => .west,
                                } else null,
                            });
                        } else view.reload(model);
                    }
                    dice_input.pressed = .{};
                    if (state.mode == .game_over) {
                        title = .{ .opening_context = true };
                        inspectTitleSaves(init, save_path, &state, &title);
                        try audio_player.update(package.rooms[state.field_state.room].id, state.audioScene(), null);
                        _ = recovery.begin(.title);
                        clock = 0;
                        menu_input = .{};
                        battle_input = .{};
                        typed_len = 0;
                        break;
                    }
                    if (state.dice_game == null and audio_player.field_stop_level == null and audio_player.queued_stop_level == null) {
                        audio_player.field_music = if (state.field_state.music) |music| switch (music) {
                            .stop, .fade => .none,
                            .area_b => .area_b,
                            .ruins => .ruins,
                            .lakeshore => .lakeshore,
                            .headquarters => .headquarters,
                            .founding => .founding,
                            .infiltration => .infiltration,
                            .mansion => .mansion,
                            .wheel => .wheel,
                        } else null;
                    }
                    const room_id = package.rooms[state.field_state.room].id;
                    audio_player.update(room_id, state.audioScene(), state.menu.jukeboxTrack()) catch |err| {
                        std.log.warn("Kasios music player: {s}", .{@errorName(err)});
                        state.menu.jukebox_playing = null;
                        state.menu.jukebox_failed = true;
                        try audio_player.update(room_id, state.audioScene(), null);
                    };
                    audio_player.menu_theme = if (state.field_state.progress.story.scenario) |story| story.sound_theme else .standard;
                    if (dice_won) audio_player.playSounds(&[_]struct { id: u16 }{.{ .id = @import("audio_route").SoundContent.dice_win }});
                    const field_sound = if (state.mode == .field) state.takeFieldSound() else null;
                    const restores_stream = field_sound == @import("audio_route").SoundContent.stream_restore_cue;
                    if (restores_stream) audio_player.playSounds(&[_]struct { id: u16 }{.{ .id = field_sound.? }});
                    audio_player.advanceSoundVoices();
                    if (state.party_selection) |*active| {
                        while (active.windows.takeOpenCue()) audio_player.playSounds(&[_]struct { id: u16 }{.{ .id = journey.party_selection.selector.layout.window_open_cue }});
                    }
                    if (dice_box_opened) audio_player.playSounds(&[_]struct { id: u16 }{.{ .id = @import("audio_route").SoundContent.dice_box_open }});
                    for (0..dice_landings) |_| audio_player.playSounds(&[_]struct { id: u16 }{.{ .id = @import("audio_route").SoundContent.dice_landing }});
                    const battle_sounds = state.combat.unite_vm.takeSounds();
                    if (state.mode == .field) {
                        if (!restores_stream) if (field_sound) |id| audio_player.playSounds(&[_]struct { id: u16 }{.{ .id = id }});
                    } else if (state.mode == .battle or state.mode == .defeat) audio_player.playSounds(battle_sounds);
                    if (effect == .settings_changed) {
                        settings_platform.save(init, save_path, state.menu.preferences) catch state.menu.notify("Settings could not be saved. Current choices apply until exit.");
                        audio_player.setVolume(state.menu.preferences.musicVolume());
                        audio_player.setEffectsVolume(state.menu.preferences.effectsVolume());
                    } else if (effect == .new_game) {
                        const preferences = state.menu.preferences;
                        const next = try boot_state.newState();
                        state.releaseRestoredSave();
                        state = next;
                        state.menu.preferences = preferences;
                        clock = 0;
                        controller = .{};
                        recovery = .{ .mode = .field };
                        menu_input = .{};
                        battle_input = .{};
                        typed_len = 0;
                    } else if (effect != .none) {
                        if (save_path) |save| persistence.apply(init, save, &state, effect) catch |err| {
                            std.log.warn("Journey {s}: {s}", .{ @tagName(effect), @errorName(err) });
                            state.menu.notify(switch (err) {
                                error.FileNotFound => "No journey save yet.",
                                error.MissingSharedItemCatalogue, error.SharedItemContentMismatch => "This slot needs its matching item catalogue.",
                                else => if (effect == .save) "Save failed. The previous save was kept." else "Load failed. Current progress was kept.",
                            });
                        } else state.menu.notify("The save directory is unavailable.");
                    }
                    typed_len = 0;
                    menu_input = .{ .field = .{ .direction = safe.direction } };
                    battle_input = .{};
                }
            }
        } else {
            _ = dice_sampler.sample(.{}, false, null);
            dice_input = .{};
            clock = 0;
            controller = .{};
            typed_len = 0;
            menu_input = .{};
            battle_input = .{};
        }
        state.bind();
        ui_context.appearance = if (title.phase == .playing) (if (state.field_state.progress.story.scenario) |story| story.window_appearance else .{}) else .{};
        ui.setWindowAppearance(ui_context.appearance);
        if (state.party_selection != null) {
            if (party_background == null) party_background = try party_view.Background.capture(canvas.texture);
        } else if (party_background) |background| {
            background.deinit();
            party_background = null;
        }
        const crossing = crossingState(&state);
        if (title.phase == .playing and state.mode == .field and state.dice_game == null and crossing == null and state.party_selection == null) {
            if (scenery_room != state.field_state.room) {
                if (scenery) |texture| rl.unloadTexture(texture);
                scenery = null;
                const room = package.rooms[state.field_state.room];
                if (room.scenery_atlas) |image_path| {
                    const texture = try raylib_app.loadPointTexture(allocator, path, image_path);
                    errdefer rl.unloadTexture(texture);
                    try room.validateSceneryAtlas(texture.width, texture.height);
                    scenery = texture;
                }
                scenery_room = state.field_state.room;
            }
            const camera = state.fieldCamera();
            const hero: ?field_view.ExtraSprite = if (try state.scriptedFieldHero(camera)) |sprite|
                .{ .atlas = atlas, .rect = sprite.rect, .x = sprite.x, .y = sprite.y, .depth = sprite.depth }
            else river: {
                const room = package.rooms[state.field_state.room];
                const story = state.field_state.progress.story.scenario orelse break :river null;
                if (room.boat_rapids == null or story.world_mode != 1) break :river null;
                const texture = crossing_atlas orelse break :river null;
                const model = boot_state.bundle.crossing_art.?.*;
                const heading: world.Direction = switch (state.field_state.facing) {
                    .up => .north,
                    .right => .east,
                    .down => .south,
                    .left => .west,
                };
                const clip = model.clips[model.direction_clips[@backingInt(heading)]];
                const pose = clip[(state.field_state.animation_ticks / clip[0].ticks) % clip.len].pose;
                const position = state.field_state.position(package);
                const anchor = model.anchors[pose];
                break :river .{
                    .atlas = texture,
                    .rect = model.poses[pose],
                    .x = camera.x + position.x - @as(f32, @floatFromInt(anchor.x)),
                    .y = camera.y + position.y - @as(f32, @floatFromInt(anchor.y)),
                    .depth = position.y / 8.0,
                };
            };
            var room_actor_draws: [64]journey.RoomActorDraw = undefined;
            const room_actors = state.roomActorDraws(camera, &room_actor_draws);
            var party_actor_draws: [5]journey.RoomActorDraw = undefined;
            const party_actors = try state.partyActorDraws(camera, &party_actor_draws);
            var extras: [field_view.max_extra_sprites]field_view.ExtraSprite = undefined;
            for (room_actors, extras[0..room_actors.len]) |actor, *extra| extra.* = .{
                .atlas = atlas,
                .rect = actor.rect,
                .x = actor.x,
                .y = actor.y,
                .depth = actor.depth,
                .shadow = actor.shadow,
            };
            for (party_actors, extras[room_actors.len..][0..party_actors.len]) |actor, *extra| extra.* = .{ .atlas = atlas, .rect = actor.rect, .x = actor.x, .y = actor.y, .depth = actor.depth };
            if (scripted_dialogue) |list| try state.composeFieldBattleDialogue(ui_context.font.?.*, list);
            if (state.field_event) |active| if (active.session.field_effect) |effect| {
                if (active.binding.field_effect_blend != .half) return error.UnqualifiedFieldEffectBlend;
                if (effect.model.ray(0)) |ray| if (ray.semitransparent and field_effect_half_shader == null) {
                    const shader = try rl.loadShaderFromMemory(null, field_view.effect_half_fragment);
                    if (shader.id == rl.gl.rlGetShaderIdDefault()) return error.FieldEffectShaderUnavailable;
                    field_effect_half_shader = shader;
                };
            };
            if (wheel_shadow_shader == null) for (room_actors) |actor| {
                if (actor.shadow == null) continue;
                const shader = try rl.loadShaderFromMemory(null, field_view.shadow_fragment);
                if (shader.id == rl.gl.rlGetShaderIdDefault()) return error.WheelShadowShaderUnavailable;
                const shade: f32 = @floatFromInt(field.wheel.shadow_shade);
                rl.setShaderValue(shader, rl.getShaderLocation(shader, "shade8"), &shade, .float);
                wheel_shadow_shader = shader;
                break;
            };
            const wheel_room = package.rooms[state.field_state.room];
            var wheel_layer: ?field_view.WheelLayer = null;
            if (wheel_room.wheel_map) |index| if (state.field_state.wheel_state) |wheel| if (wheel.clock.visible) {
                const rect = wheel_room.draws[index].rect;
                wheel_layer = .{ .draw_index = index, .projection = try field.wheel.MapProjection.init(.{ @intCast(rect.w), @intCast(rect.h) }, .{ @intFromFloat(-camera.x), @intFromFloat(-camera.y) }, wheel.map_angle) };
            };
            rl.beginTextureMode(field_canvas);
            const hero_visible = if (state.field_event) |active| (if (active.session.instance) |instance| instance.heroVisible(active.binding.content) else true) else true;
            field_view.drawScene(state.field_state, package, atlas, scenery orelse atlas, collision, camera, extras[0 .. room_actors.len + party_actors.len], hero, hero_visible, wheel_layer, wheel_shadow_shader);
            if (scripted_dialogue) |list| drawDialogue(list, atlas, 8.0 / 5.0, 24.0);
            if (state.field_event) |active| if (active.session.fadeOverlay()) |fade| {
                // Subtract the overlay from the field colour and keep the canvas alpha.
                rl.gl.rlSetBlendFactorsSeparate(1, 1, 0, 1, 0x800B, 0x8006);
                rl.beginBlendMode(.custom_separate);
                rl.drawRectangle(0, 0, field_canvas.texture.width, field_canvas.texture.height, .{
                    .r = fade.color[0],
                    .g = fade.color[1],
                    .b = fade.color[2],
                    .a = 255,
                });
                rl.endBlendMode();
            };
            if (state.field_event) |active| if (active.session.field_effect) |effect| field_view.drawEffect(effect.model, field_effect_half_shader);
            if (state.menu.phase != .closed) {
                const item_names: @TypeOf(state.shared_items) = if (state.menu.phase == .items or state.menu.phase == .shared_items)
                    state.sharedItemNames()
                else
                    @splat(null);
                menu_view.draw(state.menu, state.field_state, package.rooms[state.field_state.room], &item_names, &ui_context);
            }
            if (state.item_overload != null) try overload_view.draw(&state, &ui_context);
            rl.endTextureMode();
        }
        if (title.phase == .playing and state.mode == .war) {
            if (state.active_war) |*active| try war_renderer.prepare(allocator, &active.session.engine, active.session.command_index);
        }
        if (title.phase == .playing and (state.mode == .battle or state.mode == .defeat or state.mode == .game_over)) battle_view.prepare(state.combat, actors, floor, battle_ground, effect_atlas, &dynamic_effect);
        const frame_source: rl.Rectangle = .{ .x = 0, .y = 0, .width = 640, .height = -480 };
        const next_mode: ?journey.Mode = if (title.phase == .playing)
            (if (state.mode == .defeat) .battle else state.mode)
        else
            null;
        mode_fade.advance(fade_updates);
        if (next_mode == null) {
            mode_fade = .{};
        } else if (presented_mode != null and next_mode != presented_mode) {
            if (!mode_fade.showsOutgoing()) {
                rl.beginTextureMode(outgoing_canvas);
                rl.clearBackground(.black);
                rl.drawTextureRec(canvas.texture, frame_source, .{ .x = 0, .y = 0 }, .white);
                rl.endTextureMode();
            }
            mode_fade.begin();
        }
        presented_mode = next_mode;
        rl.beginTextureMode(canvas);
        rl.clearBackground(.black);
        if (title.phase != .playing) {
            if (title.phase != .movie or !movie_player.draw()) {
                title_view.drawWithMedia(title, state.data.title, &ui_context, &title_media);
            }
        } else if (state.dice_game) |active| {
            if (journey.dice.usesModel(&state)) {
                const model = boot_state.bundle.dice_model.?.*;
                if (active.cursor) |cursor| dice_view.drawCursor(model, cursor);
                if (active.frame) |frame| dice_view.draw(model, frame.poses, dice_atlas.?);
                if (active.hud != null) dice_view.drawPortraits(model, dice_portraits.?);
                try dice_view.compose(active, model, boot_state.bundle.ui.?, scripted_dialogue.?);
                drawDialogue(scripted_dialogue.?, atlas, 2, 0);
            } else side_game_view.drawDice(&state);
        } else if (state.side_game != null) {
            side_game_view.draw(&state);
        } else if (state.teleport_session) |session| {
            const catalogue = journey.travel.teleport.catalogue;
            var buffer: [catalogue.max_destinations]u8 = undefined;
            const destinations = session.eligible(&buffer);
            const start = @as(usize, session.page) * catalogue.rows_per_page;
            ui.panel(98, 42, 444, 376);
            ui.text("Travel to a destination", 126, 58, 23, .gold);
            if (destinations.len == 0) ui.text("No destinations are available yet.", 126, 104, 17, .ray_white);
            for (destinations[start..@min(start + catalogue.rows_per_page, destinations.len)], 0..) |index, row| {
                ui.numberText("{s}{s}", .{ if (row == session.row) "> " else "  ", session.viki.destinations[index].name }, 126, 104 + @as(i32, @intCast(row)) * 28, 18, .ray_white);
            }
            ui.text(if (destinations.len > catalogue.rows_per_page) "Left/Right: Page    Cancel: Return" else "Cancel: Return", 126, 379, 16, .gold);
        } else if (state.party_selection) |active| {
            party_background.?.draw(active.menu.fade);
            var projection: journey.party_selection.View = .{};
            const roster_view = try projection.read(&state);
            const hero_name = for (state.combat.progress.party) |member| {
                if (std.mem.eql(u8, member.id, "hero")) break member.name;
            } else return error.MissingSelectorName;
            var details: ?journey.party_selection.selector.Details = null;
            var portrait: ?field.Rect = null;
            if (active.windows.window(.details)) |window| if (window.phase == .open) {
                var buffer: [78][]const u8 = undefined;
                const candidates = active.menu.list(roster_view, &buffer);
                if (candidates.len != 0) {
                    if (active.menu.cursor >= candidates.len) return error.StaleSelectorRoster;
                    details = try journey.party_selection.inspect(&state, candidates[active.menu.cursor]);
                    if (journey.party_selector_view.portraitVisible(active.menu, roster_view)) {
                        portrait = try journey.party_selector_view.portraitRect(state.room_battles.?.bindings, candidates[active.menu.cursor], active.menu.action);
                    }
                }
            };
            try journey.party_selector_view.compose(active.menu, active.windows, roster_view, .{ .characters = state.party_catalog.?.characters, .hero = hero_name, .profiles = state.combat.content.party, .details = details, .portrait = portrait }, boot_state.bundle.ui.?, scripted_dialogue.?);
            drawDialogue(scripted_dialogue.?, atlas, 2, 0);
        } else if (crossing) |motion| {
            var list: world_view.List = .{};
            try world_view.compose(boot_state.bundle.crossing_art.?.*, motion, crossing_view.?, &list);
            for (list.sprites[0..list.length]) |sprite| {
                const rect = sprite.rect;
                rl.drawTexturePro(crossing_atlas.?, .{ .x = @floatFromInt(rect.x), .y = @floatFromInt(rect.y), .width = @floatFromInt(rect.w), .height = @floatFromInt(rect.h) }, .{
                    .x = @floatFromInt(sprite.x * 2),
                    .y = @floatFromInt(sprite.y * 2),
                    .width = @floatFromInt(rect.w * 2),
                    .height = @floatFromInt(rect.h * 2),
                }, .{ .x = 0, .y = 0 }, 0, .white);
            }
        } else if (state.mode == .field) {
            rl.drawTextureRec(field_canvas.texture, .{ .x = 0, .y = 0, .width = 512, .height = -432 }, .{ .x = 64, .y = 0 }, .white);
            if (state.episodeObjective()) |guide| {
                ui.panel(6, 440, 628, 34);
                ui.text(guide, 14, 450, 13, .gold);
            }
        } else if (state.mode == .duel) {
            if (state.active_duel) |*active| {
                ui.window(12, 6, 616, 38);
                ui.numberText("{s} vs {s}   Round {d}", .{
                    active.state.duel.fighters[0].name,
                    active.state.duel.fighters[1].name,
                    active.state.round,
                }, 24, 16, 16, .gold);
                if (duel_atlas) |texture| {
                    drawDuelStage(boot_state.bundle.duel_art.?.scene(active.state.duel.id).?, texture, active.state, state.elapsed_ticks);
                } else {
                    const left_prefix: []const u8 = if (std.mem.eql(u8, active.state.duel.id, "pahn_teo")) "portrait_006_pahn" else "portrait_008_hero";
                    const right_prefix: []const u8 = if (std.mem.eql(u8, active.state.duel.id, "shu_kwanda")) "portrait_025_kwanda" else "portrait_110_teo";
                    drawDuelFighterCard(12, 48, 304, 154, active.state.duel.fighters[0].name, active.state.fighters[0], atlas, findPortraitRect(state.room_battles, left_prefix), true);
                    drawDuelFighterCard(324, 48, 304, 154, active.state.duel.fighters[1].name, active.state.fighters[1], atlas, findPortraitRect(state.room_battles, right_prefix), false);
                }
                ui.window(12, 208, 616, 114);
                drawMultilineText(active.state.cue(), 26, 224, 22, 16, .ray_white);
                ui.window(12, 328, 616, 140);
                const labels = [_][]const u8{ "Attack", "Defend", "Desperate Attack" };
                for (labels, 0..) |label, idx| {
                    const selected = @backingInt(active.state.selected) == idx;
                    const row_y = 344 + @as(i32, @intCast(idx)) * 28;
                    if (selected) ui.selection(22, row_y - 4, 250, 24);
                    ui.numberText("{s}{s}", .{ if (selected) "> " else "  ", label }, 30, row_y, 16, if (selected) .gold else .ray_white);
                }
                if (active.state.phase == .finished) {
                    const won = (active.state.outcome orelse .defeat) == .victory;
                    ui.panel(300, 356, 312, 64);
                    ui.text(if (won) "Duel won!\nPress Z or Enter to continue." else "Duel lost!\nPress Z or Enter to continue.", 316, 372, 15, .gold);
                }
            }
        } else if (state.mode == .war) {
            if (state.active_war != null) {
                rl.drawTexturePro(
                    war_renderer.canvas.texture,
                    .{ .x = 0, .y = 0, .width = @floatFromInt(war_view.width), .height = -@as(f32, @floatFromInt(war_view.height)) },
                    .{ .x = 0, .y = 0, .width = 640, .height = 480 },
                    .{ .x = 0, .y = 0 },
                    0,
                    .white,
                );
            }
        } else if (state.mode == .ending) {
            if (state.active_ending) |*active| {
                const asset = active.parsed.value;
                const total_phases = asset.bounded_ending.main_ending_phases;
                ui.window(12, 10, 616, 460);
                ui.numberText("Suikoden - Ending ({s})", .{if (active.phase_index < total_phases) "Finale" else "108 Stars of Destiny"}, 28, 26, 20, .gold);
                const alive_count = active.census.recruited + active.census.recruited_alternate;
                const lost_count = active.census.lost + active.census.lost_alternate;
                ui.numberText("Recruited: {d}   Fallen: {d}   Unrecruited: {d}", .{ alive_count, lost_count, active.census.absent }, 28, 56, 15, .light_gray);
                if (active.phase_index < total_phases) {
                    ui.panel(28, 92, 584, 292);
                    ui.numberText("Ending Sequence Phase {d} of {d}", .{ active.phase_index + 1, total_phases }, 44, 114, 17, .gold);
                    drawMultilineText(asset.bounded_ending.text, 44, 160, 24, 16, .ray_white);
                    ui.text("Press Z/Enter to advance.", 28, 412, 16, .gold);
                } else {
                    ui.panel(28, 92, 584, 304);
                    const start: usize = active.entry_cursor;
                    const end = @min(start + 8, asset.entries.len);
                    for (asset.entries[start..end], 0..) |entry, row| {
                        const result = chapters.endings.plan(asset, start + row, &active.recruit_flags) catch null;
                        const status_label: []const u8 = if (result) |res| switch (res.variant) {
                            .recruited => "Joined",
                            .recruited_alternate => "Joined (Alt)",
                            .lost => "Fallen",
                            .lost_alternate => "Fallen (Alt)",
                            .absent => "Absent",
                        } else "?";
                        const row_y: i32 = 108 + @as(i32, @intCast(row)) * 34;
                        ui.numberText("{d}. {s} - {s}", .{ start + row + 1, entry.display_name, status_label }, 44, row_y, 15, .ray_white);
                    }
                    ui.text("Up/Down: Scroll Stars   |   Z/Enter: Continue", 28, 418, 15, .gold);
                }
            }
        } else {
            battle_view.draw(state.combat, actors, floor, battle_ground, effect_atlas, &dynamic_effect);
            if (state.mode == .defeat and !state.combat.hasDepartureFlights()) {
                ui.panel(72, 76, 496, 210);
                ui.text("Party defeated", 94, 96, 26, .gold);
                if (state.defeatContinuesScene()) {
                    ui.text("Enter: continue", 94, 150, 20, .ray_white);
                } else if (state.defeatEndsRun()) {
                    ui.text("Enter: return to title", 94, 150, 20, .ray_white);
                } else {
                    ui.text("Enter: retry from before this encounter", 94, 150, 20, .ray_white);
                    ui.text("The retry restores all pre-battle party state.", 94, 195, 17, .light_gray);
                    ui.text("Close the window to leave without saving.", 94, 245, 17, .light_gray);
                }
            }
        }
        rl.endTextureMode();
        // One integer layout policy; an unsupported transient size keeps
        // the last valid layout instead of drawing a clipped canvas.
        const layout = recovery.layout(.journey, .{ .width = rl.getScreenWidth(), .height = rl.getScreenHeight() });
        rl.beginDrawing();
        rl.clearBackground(.black);
        const frame = if (mode_fade.showsOutgoing()) outgoing_canvas.texture else canvas.texture;
        rl.drawTexturePro(frame, frame_source, .{ .x = @floatFromInt(layout.x), .y = @floatFromInt(layout.y), .width = @floatFromInt(layout.width), .height = @floatFromInt(layout.height) }, .{ .x = 0, .y = 0 }, 0, .white);
        const opacity = mode_fade.alpha();
        if (opacity != 0) {
            rl.drawRectangle(layout.x, layout.y, layout.width, layout.height, .{ .r = 0, .g = 0, .b = 0, .a = opacity });
        }
        rl.endDrawing();
    }
}

pub fn showStartupError(err: anyerror, path: []const u8, cause: ?anyerror) !void {
    raylib_app.initWindow(.{
        .width = 800,
        .height = 420,
        .title = "Suikoden - content unavailable",
        .target_fps = 30,
        .disable_exit_key = false,
    }) catch return err;
    defer rl.closeWindow();
    while (!rl.windowShouldClose()) {
        rl.beginDrawing();
        rl.clearBackground(.black);
        ui.text("The adventure could not start.", 32, 40, 28, .gold);
        if (path.len != 0) {
            ui.numberText("File: {s}", .{path}, 32, 100, 19, .ray_white);
            ui.numberText("Cause: {s}", .{@errorName(cause orelse err)}, 32, 132, 19, .ray_white);
        } else {
            ui.numberText("Reason: {s}", .{@errorName(err)}, 32, 112, 19, .ray_white);
        }
        ui.text("The content package may be missing or incompatible.", 32, 180, 19, .ray_white);
        ui.text("Restore the complete content package and reopen the game.", 32, 214, 18, .light_gray);
        ui.text("Existing saves have been kept. Close this window to exit.", 32, 300, 18, .light_gray);
        rl.endDrawing();
    }
}

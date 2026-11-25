//! Pre-window and `--check-content` atlas validation checks.
const std = @import("std");
const rl = @import("raylib");
const raylib_app = @import("raylib_app");
const battle = @import("battle");
const boot = @import("journey_boot");
const journey = @import("journey");
const duel_presentation = @import("journey_content").duel_presentation;

pub fn checkCrossingAtlas(allocator: std.mem.Allocator, state: *const boot.Boot) !void {
    const model = state.bundle.crossing_art orelse return;
    const image = try raylib_app.loadImage(allocator, state.path, model.atlas);
    defer rl.unloadImage(image);
    try model.validateAtlas(image.width, image.height);
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

pub fn checkStartupAtlases(allocator: std.mem.Allocator, boot_state: *const boot.Boot) !void {
    try checkFieldAtlas(allocator, boot_state);
    try checkDiceAtlas(allocator, boot_state);
    try checkDuelAtlas(allocator, boot_state);
    try checkCrossingAtlas(allocator, boot_state);
    try checkBattleImages(allocator, boot_state.path, boot_state.bundle.combat);
    try checkBattlefieldAtlas(allocator, boot_state.path, boot_state.bundle.combat);
}

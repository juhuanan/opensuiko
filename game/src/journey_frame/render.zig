//! Scene composition and canvas/screen presentation for the journey runtime.
const std = @import("std");
const rl = @import("raylib");
const raylib_app = @import("raylib_app");
const field = @import("field");
const pause = @import("pause_menu");
const boot = @import("journey_boot");
const field_view = @import("../field_view.zig");
const menu_view = @import("../menu_view.zig");
const overload_view = @import("../item_overload_view.zig");
const battle_view = @import("../battle_trial_view.zig");
const ui = @import("ui");
const title_view = @import("../title_view.zig");
const recovery_layer = @import("platform_recovery");
const journey = @import("journey");
const duel_presentation = @import("journey_content").duel_presentation;
const dice_view = @import("../dice_view.zig");
const side_game_view = @import("../side_game_view.zig");
const world_view = @import("world_view");
const world = @import("world");
const chapters = @import("chapters");
const resources_mod = @import("resources.zig");
const dialogue_presentation = journey.field_dialogue_view.presentation;

pub fn crossingState(state: *const journey.State) ?world.State {
    if (state.auto_travel) |active| {
        if (!active.flight) return active.motion();
    }
    if (state.boat_travel) |active| return active.motion();
    return null;
}

const Scene = union(enum) {
    title,
    field,
    battle,
    duel,
    war,
    ending,
    dice,
    side_game,
    teleport,
    party_selection,
    crossing: world.State,
};

fn resolveScene(state: *const journey.State, title: pause.title.State) Scene {
    if (title.phase != .playing) return .title;
    if (state.dice_game != null) return .dice;
    if (state.side_game != null) return .side_game;
    if (state.teleport_session != null) return .teleport;
    if (state.party_selection != null) return .party_selection;
    if (crossingState(state)) |motion| return .{ .crossing = motion };
    return switch (state.mode) {
        .field => .field,
        .duel => .duel,
        .war => .war,
        .ending => .ending,
        .battle, .defeat, .game_over => .battle,
    };
}

fn findPortraitRect(rooms: @FieldType(journey.State, "room_battles"), prefix: []const u8) ?field.Rect {
    const rb = rooms orelse return null;
    for (rb.bindings) |binding| {
        for (binding.dialogue.images) |image| {
            if (std.mem.startsWith(u8, image.id, prefix)) return image.atlas_rect;
        }
    }
    return null;
}

fn drawDuelFighterCard(
    context: *const ui.Context,
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
    context.window(x, y, w, h);
    const frame_x = x + 12;
    const frame_y = y + 12;
    ui.framedRect(frame_x - 1, frame_y - 1, 130, 130, .{ .r = 16, .g = 22, .b = 36, .a = 255 }, if (is_player) .gold else .{ .r = 210, .g = 90, .b = 90, .a = 255 });
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
    context.text(name, info_x, y + 16, 17, if (is_player) .gold else .ray_white);
    context.text(if (is_player) "Ally" else "Challenger", info_x, y + 38, 12, .light_gray);
    drawDuelHealth(info_x, y + 66, 138, fighter);
    context.numberText("HP {d}/{d}", .{ fighter.hp, fighter.maximum_hp }, info_x, y + 88, 15, .ray_white);
    context.numberText("ATK {d}  DEF {d}", .{ fighter.attack, fighter.defense }, info_x, y + 114, 13, .light_gray);
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

fn drawDuelStage(context: *const ui.Context, scene: duel_presentation.Scene, atlas: rl.Texture2D, duel_state: journey.duel.State, elapsed: u64) void {
    if (scene.backdrop) |backdrop| {
        rl.drawTexturePro(atlas, .{
            .x = @floatFromInt(backdrop.x),
            .y = @floatFromInt(backdrop.y),
            .width = @floatFromInt(backdrop.w),
            .height = @floatFromInt(backdrop.h),
        }, .{ .x = 12, .y = 48, .width = duel_presentation.width, .height = duel_presentation.height }, .{ .x = 0, .y = 0 }, 0, .white);
    } else {
        context.window(12, 48, duel_presentation.width, duel_presentation.height);
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
        context.panel(x - 4, 52, 139, if (scene.gauges != null) 53 else 39);
        context.text(profile.name, x, 55, 14, .ray_white);
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

fn prepareFieldCanvas(
    context: *const ui.Context,
    boot_state: *const boot.Boot,
    state: *const journey.State,
    res: *resources_mod.Resources,
    collision: bool,
) !void {
    const package = boot_state.bundle.package;
    const room = package.rooms[state.field_state.room];
    try res.ensureRoomScenery(boot_state.path, state.field_state.room, room);

    const camera = state.fieldCamera();
    const hero: ?field_view.ExtraSprite = if (try state.scriptedFieldHero(camera)) |sprite|
        .{ .atlas = res.atlas, .rect = sprite.rect, .x = sprite.x, .y = sprite.y, .depth = sprite.depth }
    else river: {
        const story = state.field_state.progress.story.scenario orelse break :river null;
        if (room.boat_rapids == null or story.world_mode != 1) break :river null;
        const texture = res.crossing_atlas orelse break :river null;
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
        .atlas = res.atlas,
        .rect = actor.rect,
        .x = actor.x,
        .y = actor.y,
        .depth = actor.depth,
        .shadow = actor.shadow,
    };
    for (party_actors, extras[room_actors.len..][0..party_actors.len]) |actor, *extra| extra.* = .{
        .atlas = res.atlas,
        .rect = actor.rect,
        .x = actor.x,
        .y = actor.y,
        .depth = actor.depth,
    };
    if (res.scripted_dialogue) |list| try state.composeFieldBattleDialogue(context.source.?.font.*, list);
    if (state.field_event) |active| try res.ensureFieldEffectShader(active);
    try res.ensureWheelShadowShader(room_actors);

    var wheel_layer: ?field_view.WheelLayer = null;
    if (room.wheel_map) |index| if (state.field_state.wheel_state) |wheel| if (wheel.clock.visible) {
        const rect = room.draws[index].rect;
        wheel_layer = .{ .draw_index = index, .projection = try field.wheel.MapProjection.init(.{ @intCast(rect.w), @intCast(rect.h) }, .{ @intFromFloat(-camera.x), @intFromFloat(-camera.y) }, wheel.map_angle) };
    };

    rl.beginTextureMode(res.field_canvas);
    defer rl.endTextureMode();
    const hero_visible = if (state.field_event) |active| (if (active.session.instance) |instance| instance.heroVisible(active.binding.content) else true) else true;
    field_view.drawScene(context, state.field_state, package, res.atlas, res.scenery orelse res.atlas, collision, camera, extras[0 .. room_actors.len + party_actors.len], hero, hero_visible, wheel_layer, res.wheel_shadow_shader);
    if (res.scripted_dialogue) |list| drawDialogue(list, res.atlas, 8.0 / 5.0, 24.0);
    if (state.field_event) |active| if (active.session.fadeOverlay()) |fade| {
        // Subtract the overlay from the field colour and keep the canvas alpha.
        rl.gl.rlSetBlendFactorsSeparate(1, 1, 0, 1, 0x800B, 0x8006);
        rl.beginBlendMode(.custom_separate);
        rl.drawRectangle(0, 0, res.field_canvas.texture.width, res.field_canvas.texture.height, .{
            .r = fade.color[0],
            .g = fade.color[1],
            .b = fade.color[2],
            .a = 255,
        });
        rl.endBlendMode();
    };
    if (state.field_event) |active| if (active.session.field_effect) |effect| field_view.drawEffect(effect.model, res.field_effect_half_shader);
    if (state.menu.phase != .closed) {
        const item_names: @TypeOf(state.shared_items) = if (state.menu.phase == .items or state.menu.phase == .shared_items)
            state.sharedItemNames()
        else
            @splat(null);
        menu_view.draw(state.menu, state.field_state, room, &item_names, context);
    }
    if (state.item_overload != null) try overload_view.draw(state, context);
}

fn prepareSubRenderers(
    context: *const ui.Context,
    boot_state: *const boot.Boot,
    state: *const journey.State,
    res: *resources_mod.Resources,
    scene: Scene,
    collision: bool,
) !void {
    switch (scene) {
        // Keep the retained field canvas current under field overlays.
        .field, .side_game, .teleport => try prepareFieldCanvas(context, boot_state, state, res, collision),
        .war => if (state.active_war) |*active| try res.war_renderer.prepare(res.allocator, &active.session.engine, active.session.command_index, context),
        .battle => battle_view.prepare(context, state.combat.*, res.actors, res.floor, res.battle_ground, res.effect_atlas, &res.dynamic_effect),
        else => {},
    }
}

fn drawDiceScene(context: *const ui.Context, boot_state: *const boot.Boot, state: *const journey.State, active: journey.dice.Active, res: *resources_mod.Resources) !void {
    if (journey.dice.usesModel(state)) {
        const model = boot_state.bundle.dice_model.?.*;
        if (active.cursor) |cursor| dice_view.drawCursor(model, cursor);
        if (active.frame) |frame| dice_view.draw(model, frame.poses, res.dice_atlas.?);
        if (active.hud != null) dice_view.drawPortraits(model, res.dice_portraits.?);
        try dice_view.compose(active, model, context.source.?.font.*, res.scripted_dialogue.?);
        drawDialogue(res.scripted_dialogue.?, res.atlas, 2, 0);
    } else side_game_view.drawDice(context, state);
}

fn drawTeleportOverlay(context: *const ui.Context, session: journey.travel.teleport.Session) void {
    const catalogue = journey.travel.teleport.catalogue;
    var buffer: [catalogue.max_destinations]u8 = undefined;
    const destinations = session.eligible(&buffer);
    const start = @as(usize, session.page) * catalogue.rows_per_page;
    context.panel(98, 42, 444, 376);
    context.text("Travel to a destination", 126, 58, 23, .gold);
    if (destinations.len == 0) context.text("No destinations are available yet.", 126, 104, 17, .ray_white);
    for (destinations[start..@min(start + catalogue.rows_per_page, destinations.len)], 0..) |index, row| {
        context.numberText("{s}{s}", .{ if (row == session.row) "> " else "  ", session.viki.destinations[index].name }, 126, 104 + @as(i32, @intCast(row)) * 28, 18, .ray_white);
    }
    context.text(if (destinations.len > catalogue.rows_per_page) "Left/Right: Page    Cancel: Return" else "Cancel: Return", 126, 379, 16, .gold);
}

fn drawPartySelectionScene(context: *const ui.Context, state: *const journey.State, active: journey.party_selection.Active, res: *resources_mod.Resources) !void {
    res.party_background.?.draw(active.menu.fade);
    var projection: journey.party_selection.View = .{};
    const roster_view = try projection.read(state);
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
            details = try journey.party_selection.inspect(state, candidates[active.menu.cursor]);
            if (journey.party_selector_view.portraitVisible(active.menu, roster_view)) {
                portrait = try journey.party_selector_view.portraitRect(state.room_battles.?.bindings, candidates[active.menu.cursor], active.menu.action);
            }
        }
    };
    try journey.party_selector_view.compose(active.menu, active.windows, roster_view, .{ .characters = state.party_catalog.?.characters, .hero = hero_name, .profiles = state.combat.content.party, .details = details, .portrait = portrait }, context.source.?.font.*, res.scripted_dialogue.?);
    drawDialogue(res.scripted_dialogue.?, res.atlas, 2, 0);
}

fn drawCrossingScene(boot_state: *const boot.Boot, res: *resources_mod.Resources, motion: world.State) !void {
    var list: world_view.List = .{};
    try world_view.compose(boot_state.bundle.crossing_art.?.*, motion, res.crossing_view.?, &list);
    for (list.sprites[0..list.length]) |sprite| {
        const rect = sprite.rect;
        rl.drawTexturePro(res.crossing_atlas.?, .{ .x = @floatFromInt(rect.x), .y = @floatFromInt(rect.y), .width = @floatFromInt(rect.w), .height = @floatFromInt(rect.h) }, .{
            .x = @floatFromInt(sprite.x * 2),
            .y = @floatFromInt(sprite.y * 2),
            .width = @floatFromInt(rect.w * 2),
            .height = @floatFromInt(rect.h * 2),
        }, .{ .x = 0, .y = 0 }, 0, .white);
    }
}

fn drawDuelScene(context: *const ui.Context, boot_state: *const boot.Boot, state: *const journey.State, res: *resources_mod.Resources) void {
    const active = &(state.active_duel orelse return);
    context.window(12, 6, 616, 38);
    context.numberText("{s} vs {s}   Round {d}", .{
        active.state.duel.fighters[0].name,
        active.state.duel.fighters[1].name,
        active.state.round,
    }, 24, 16, 16, .gold);
    if (res.duel_atlas) |texture| {
        drawDuelStage(context, boot_state.bundle.duel_art.?.scene(active.state.duel.id).?, texture, active.state, state.elapsed_ticks);
    } else {
        const left_prefix: []const u8 = if (std.mem.eql(u8, active.state.duel.id, "pahn_teo")) "portrait_006_pahn" else "portrait_008_hero";
        const right_prefix: []const u8 = if (std.mem.eql(u8, active.state.duel.id, "shu_kwanda")) "portrait_025_kwanda" else "portrait_110_teo";
        drawDuelFighterCard(context, 12, 48, 304, 154, active.state.duel.fighters[0].name, active.state.fighters[0], res.atlas, findPortraitRect(state.room_battles, left_prefix), true);
        drawDuelFighterCard(context, 324, 48, 304, 154, active.state.duel.fighters[1].name, active.state.fighters[1], res.atlas, findPortraitRect(state.room_battles, right_prefix), false);
    }
    context.window(12, 208, 616, 114);
    context.multilineText(active.state.cue(), 26, 224, 22, 16, .ray_white);
    context.window(12, 328, 616, 140);
    const labels = [_][]const u8{ "Attack", "Defend", "Desperate Attack" };
    for (labels, 0..) |label, idx| {
        const selected = @backingInt(active.state.selected) == idx;
        const row_y = 344 + @as(i32, @intCast(idx)) * 28;
        if (selected) context.selection(22, row_y - 4, 250, 24);
        context.numberText("{s}{s}", .{ if (selected) "> " else "  ", label }, 30, row_y, 16, if (selected) .gold else .ray_white);
    }
    if (active.state.phase == .finished) {
        const won = (active.state.outcome orelse .defeat) == .victory;
        context.panel(300, 356, 312, 64);
        context.text(if (won) "Duel won!\nPress Z or Enter to continue." else "Duel lost!\nPress Z or Enter to continue.", 316, 372, 15, .gold);
    }
}

fn drawEndingScene(context: *const ui.Context, state: *const journey.State) void {
    const active = &(state.active_ending orelse return);
    const asset = active.parsed.value;
    const total_phases = asset.bounded_ending.main_ending_phases;
    context.window(12, 10, 616, 460);
    context.numberText("Suikoden - Ending ({s})", .{if (active.phase_index < total_phases) "Finale" else "108 Stars of Destiny"}, 28, 26, 20, .gold);
    const alive_count = active.census.recruited + active.census.recruited_alternate;
    const lost_count = active.census.lost + active.census.lost_alternate;
    context.numberText("Recruited: {d}   Fallen: {d}   Unrecruited: {d}", .{ alive_count, lost_count, active.census.absent }, 28, 56, 15, .light_gray);
    if (active.phase_index < total_phases) {
        context.panel(28, 92, 584, 292);
        context.numberText("Ending Sequence Phase {d} of {d}", .{ active.phase_index + 1, total_phases }, 44, 114, 17, .gold);
        context.multilineText(asset.bounded_ending.text, 44, 160, 24, 16, .ray_white);
        context.text("Press Z/Enter to advance.", 28, 412, 16, .gold);
    } else {
        context.panel(28, 92, 584, 304);
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
            context.numberText("{d}. {s} - {s}", .{ start + row + 1, entry.display_name, status_label }, 44, row_y, 15, .ray_white);
        }
        context.text("Up/Down: Scroll Stars   |   Z/Enter: Continue", 28, 418, 15, .gold);
    }
}

fn drawBattleScene(context: *const ui.Context, state: *const journey.State, res: *resources_mod.Resources) void {
    battle_view.draw(context, state.combat.*, res.actors, res.floor, res.battle_ground, res.effect_atlas, &res.dynamic_effect);
    if (state.mode == .defeat and !state.combat.hasDepartureFlights()) {
        context.panel(72, 76, 496, 210);
        context.text("Party defeated", 94, 96, 26, .gold);
        if (state.defeatContinuesScene()) {
            context.text("Enter: continue", 94, 150, 20, .ray_white);
        } else if (state.defeatEndsRun()) {
            context.text("Enter: return to title", 94, 150, 20, .ray_white);
        } else {
            context.text("Enter: retry from before this encounter", 94, 150, 20, .ray_white);
            context.text("The retry restores all pre-battle party state.", 94, 195, 17, .light_gray);
            context.text("Close the window to leave without saving.", 94, 245, 17, .light_gray);
        }
    }
}

fn drawActiveScene(
    context: *const ui.Context,
    boot_state: *const boot.Boot,
    state: *const journey.State,
    title: pause.title.State,
    res: *resources_mod.Resources,
    scene: Scene,
) !void {
    switch (scene) {
        .title => {
            if (title.phase != .movie or !res.movie_player.draw()) {
                title_view.drawWithMedia(title, state.data.title, context, &res.title_media);
            }
        },
        .dice => try drawDiceScene(context, boot_state, state, state.dice_game.?, res),
        .side_game => side_game_view.draw(context, state),
        .teleport => drawTeleportOverlay(context, state.teleport_session.?),
        .party_selection => try drawPartySelectionScene(context, state, state.party_selection.?, res),
        .crossing => |motion| try drawCrossingScene(boot_state, res, motion),
        .field => {
            rl.drawTextureRec(res.field_canvas.texture, raylib_app.canvasSource(res.field_canvas.texture), .{ .x = 64, .y = 0 }, .white);
            if (state.episodeObjective()) |guide| {
                context.panel(6, 440, 628, 34);
                context.text(guide, 14, 450, 13, .gold);
            }
        },
        .duel => drawDuelScene(context, boot_state, state, res),
        .war => {
            if (state.active_war != null) {
                rl.drawTexturePro(
                    res.war_renderer.canvas.texture,
                    raylib_app.canvasSource(res.war_renderer.canvas.texture),
                    .{ .x = 0, .y = 0, .width = 640, .height = 480 },
                    .{ .x = 0, .y = 0 },
                    0,
                    .white,
                );
            }
        },
        .ending => drawEndingScene(context, state),
        .battle => drawBattleScene(context, state, res),
    }
}

pub const Presentation = struct {
    fade: recovery_layer.display.ModeFade = .{},
    presented_mode: ?journey.Mode = null,

    pub fn present(
        self: *Presentation,
        boot_state: *const boot.Boot,
        state: *const journey.State,
        title: pause.title.State,
        res: *resources_mod.Resources,
        recovery: *recovery_layer.Recovery,
        gameplay_ticks: u8,
        collision: bool,
    ) !void {
        const scene = resolveScene(state, title);
        const context: ui.Context = .{
            .source = if (boot_state.bundle.ui) |*font| .{ .font = font, .atlas = res.atlas } else null,
            .appearance = if (scene != .title)
                (if (state.field_state.progress.story.scenario) |story| story.window_appearance else .{})
            else
                .{},
        };
        try res.syncPartyBackground(scene == .party_selection);
        try prepareSubRenderers(&context, boot_state, state, res, scene, collision);

        const next_mode: ?journey.Mode = if (scene != .title)
            (if (state.mode == .defeat) .battle else state.mode)
        else
            null;
        self.fade.advance(gameplay_ticks);
        if (next_mode == null) {
            self.fade = .{};
        } else if (self.presented_mode != null and next_mode != self.presented_mode) {
            if (!self.fade.showsOutgoing()) {
                rl.beginTextureMode(res.outgoing_canvas);
                defer rl.endTextureMode();
                rl.clearBackground(.black);
                rl.drawTextureRec(res.canvas.texture, raylib_app.canvasSource(res.canvas.texture), .{ .x = 0, .y = 0 }, .white);
            }
            self.fade.begin();
        }
        self.presented_mode = next_mode;
        {
            rl.beginTextureMode(res.canvas);
            defer rl.endTextureMode();
            rl.clearBackground(.black);
            try drawActiveScene(&context, boot_state, state, title, res, scene);
        }

        // Keep the last valid layout through unsupported transient window sizes.
        const layout = recovery.layout(.journey, .{ .width = rl.getScreenWidth(), .height = rl.getScreenHeight() });
        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(.black);
        const frame = if (self.fade.showsOutgoing()) res.outgoing_canvas.texture else res.canvas.texture;
        rl.drawTexturePro(frame, raylib_app.canvasSource(frame), .{ .x = @floatFromInt(layout.x), .y = @floatFromInt(layout.y), .width = @floatFromInt(layout.width), .height = @floatFromInt(layout.height) }, .{ .x = 0, .y = 0 }, 0, .white);
        const opacity = self.fade.alpha();
        if (opacity != 0) {
            rl.drawRectangle(layout.x, layout.y, layout.width, layout.height, .{ .r = 0, .g = 0, .b = 0, .a = opacity });
        }
    }
};

pub fn showStartupError(err: anyerror, path: []const u8, cause: ?anyerror) !void {
    raylib_app.initWindow(.{
        .width = 800,
        .height = 420,
        .title = "Suikoden - content unavailable",
        .target_fps = 30,
        .disable_exit_key = false,
    }) catch return err;
    defer rl.closeWindow();
    const context: ui.Context = .{};
    while (!rl.windowShouldClose()) {
        rl.beginDrawing();
        rl.clearBackground(.black);
        context.text("The adventure could not start.", 32, 40, 28, .gold);
        if (path.len != 0) {
            context.numberText("File: {s}", .{path}, 32, 100, 19, .ray_white);
            context.numberText("Cause: {s}", .{@errorName(cause orelse err)}, 32, 132, 19, .ray_white);
        } else {
            context.numberText("Reason: {s}", .{@errorName(err)}, 32, 112, 19, .ray_white);
        }
        context.text("The content package may be missing or incompatible.", 32, 180, 19, .ray_white);
        context.text("Restore the complete content package and reopen the game.", 32, 214, 18, .light_gray);
        context.text("Existing saves have been kept. Close this window to exit.", 32, 300, 18, .light_gray);
        rl.endDrawing();
    }
}

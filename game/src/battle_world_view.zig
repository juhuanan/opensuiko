const std = @import("std");
const rl = @import("raylib");
const battle = @import("battle");
const art = battle.world_art;

const SpellTint = struct { core: rl.Color, glow: rl.Color };

fn spellTint(name: []const u8) SpellTint {
    if (std.mem.indexOf(u8, name, "Flaming") != null or std.mem.indexOf(u8, name, "Fire") != null or std.mem.indexOf(u8, name, "Flame") != null or std.mem.indexOf(u8, name, "Explosion") != null)
        return .{ .core = .{ .r = 255, .g = 180, .b = 40, .a = 255 }, .glow = .{ .r = 220, .g = 45, .b = 20, .a = 180 } };
    if (std.mem.indexOf(u8, name, "Water") != null or std.mem.indexOf(u8, name, "Rain") != null or std.mem.indexOf(u8, name, "Ocean") != null or std.mem.indexOf(u8, name, "Kindness") != null or std.mem.indexOf(u8, name, "Fog") != null)
        return .{ .core = .{ .r = 120, .g = 210, .b = 255, .a = 255 }, .glow = .{ .r = 30, .g = 90, .b = 220, .a = 180 } };
    if (std.mem.indexOf(u8, name, "Healing") != null or std.mem.indexOf(u8, name, "Wind") != null or std.mem.indexOf(u8, name, "Shredding") != null)
        return .{ .core = .{ .r = 160, .g = 255, .b = 170, .a = 255 }, .glow = .{ .r = 30, .g = 170, .b = 90, .a = 180 } };
    if (std.mem.indexOf(u8, name, "Storm") != null or std.mem.indexOf(u8, name, "Thunder") != null or std.mem.indexOf(u8, name, "Lightning") != null)
        return .{ .core = .{ .r = 255, .g = 255, .b = 170, .a = 255 }, .glow = .{ .r = 120, .g = 80, .b = 255, .a = 180 } };
    if (std.mem.indexOf(u8, name, "Earth") != null or std.mem.indexOf(u8, name, "Clay") != null or std.mem.indexOf(u8, name, "Copper") != null or std.mem.indexOf(u8, name, "Guardian") != null)
        return .{ .core = .{ .r = 230, .g = 190, .b = 90, .a = 255 }, .glow = .{ .r = 120, .g = 80, .b = 40, .a = 180 } };
    if (std.mem.indexOf(u8, name, "Black") != null or std.mem.indexOf(u8, name, "Hell") != null or std.mem.indexOf(u8, name, "Judgment") != null or std.mem.indexOf(u8, name, "Deadly") != null)
        return .{ .core = .{ .r = 210, .g = 110, .b = 255, .a = 255 }, .glow = .{ .r = 70, .g = 20, .b = 120, .a = 200 } };
    return .{ .core = .{ .r = 255, .g = 230, .b = 120, .a = 255 }, .glow = .{ .r = 160, .g = 40, .b = 180, .a = 180 } };
}

fn drawSpellVfx(state: battle.State, data: art.Data) void {
    if (state.hasSourceEffect()) return;
    const effect = state.active orelse return;
    if (effect.kind != .cast) return;
    const systems = state.content.systems orelse return;
    if (effect.spell >= systems.spells.len) return;
    const tint = spellTint(systems.spells[effect.spell].name);
    const caster = art.actorLayout(data, state, effect.actor).point;
    const target = art.actorLayout(data, state, effect.target).point;
    const tick = state.effectTicks();
    if (tick < 20) {
        const cx = @as(i32, @intFromFloat(caster.x));
        const cy = @as(i32, @intFromFloat(caster.y - 68));
        const pulse = 14 + @as(i32, @intCast(tick / 4));
        rl.drawCircleLines(cx, cy, @floatFromInt(pulse), tint.core);
        rl.drawCircleLines(cx, cy, @floatFromInt(pulse + 6), tint.glow);
        rl.drawLine(cx - pulse, cy, cx + pulse, cy, tint.core);
        rl.drawLine(cx, cy - pulse, cx, cy + pulse, tint.core);
    } else if (tick < 36) {
        const f = @as(f32, @floatFromInt(tick - 20)) / 16.0;
        const x = caster.x + (target.x - caster.x) * f;
        const y = caster.y + (target.y - caster.y) * f - 34.0;
        rl.drawCircleV(.{ .x = x, .y = y }, 8, tint.glow);
        rl.drawCircleV(.{ .x = x, .y = y }, 4, tint.core);
    } else {
        const cx = @as(i32, @intFromFloat(target.x));
        const cy = @as(i32, @intFromFloat(target.y - 30));
        const flicker = @as(i32, @intCast((tick / 3) % 4));
        for (0..5) |i| {
            const dx = @as(i32, @intCast(i)) * 9 - 18;
            const h = 18 + (@mod(@as(i32, @intCast(i)) * 7 + tick, 15));
            const bx = cx + dx;
            rl.drawTriangle(.{ .x = @floatFromInt(bx - 7), .y = @floatFromInt(cy) }, .{ .x = @floatFromInt(bx), .y = @floatFromInt(cy - h - flicker) }, .{ .x = @floatFromInt(bx + 7), .y = @floatFromInt(cy) }, tint.core);
        }
        rl.drawCircleLines(cx, cy + 20, 24, tint.glow);
    }
}

pub fn prepare(state: battle.State, atlas: rl.Texture2D, floor: rl.Texture2D, ground_texture: ?rl.Texture2D, effect_atlas: ?rl.Texture2D, dynamic: ?*@import("battle_spell_view.zig").DynamicTexture) void {
    if (state.backgroundCaptureMinimum()) |minimum| if (dynamic) |cache| {
        rl.beginTextureMode(cache.background);
        drawScene(state, atlas, floor, ground_texture, effect_atlas, dynamic, minimum);
        rl.endTextureMode();
    };
}

pub fn draw(state: battle.State, atlas: rl.Texture2D, floor: rl.Texture2D, ground_texture: ?rl.Texture2D, effect_atlas: ?rl.Texture2D, dynamic: ?*@import("battle_spell_view.zig").DynamicTexture) void {
    drawScene(state, atlas, floor, ground_texture, effect_atlas, dynamic, null);
}

fn drawScene(state: battle.State, atlas: rl.Texture2D, floor: rl.Texture2D, ground_texture: ?rl.Texture2D, effect_atlas: ?rl.Texture2D, dynamic: ?*@import("battle_spell_view.zig").DynamicTexture, minimum_depth: ?u16) void {
    const data = battle.layout.sceneArt(state);
    const list = art.compose(data, state);
    rl.clearBackground(if (minimum_depth != null) .blank else .black);
    if (minimum_depth != null) rl.beginScissorMode(0, 0, 640, 480) else rl.beginScissorMode(0, battle.layout.viewport_top, 640, battle.layout.viewport_height);
    defer rl.endScissorMode();
    @import("battle_ground_view.zig").draw(&state, floor, ground_texture, minimum_depth orelse 0);
    if ((minimum_depth orelse 0) <= 380) for (list.shadows) |shadow| {
        if (shadow.radius_x > 0 and shadow.radius_y > 0) rl.drawEllipse(@intFromFloat(shadow.point.x), @intFromFloat(shadow.point.y), shadow.radius_x, shadow.radius_y, .{ .r = 0, .g = 0, .b = 0, .a = 140 });
    };
    const spell_view = @import("battle_spell_view.zig");
    const spell_frame: ?battle.spell_scene.Frame = if (state.hasSourceEffect() or state.hasStatusIcons()) state.spellSceneFrame() else null;
    const Draw = struct { effect: bool, trail: bool = false, auxiliary: bool = false, index: usize, depth: f32 };
    var draws: [battle.spell_scene.Frame.capacity + art.quad_capacity + 12 + battle.layout.unite_graphic_capacity + 19]Draw = undefined;
    var count: usize = 0;
    for (list.quads[0..list.length], 0..) |q, i| {
        draws[count] = .{ .effect = false, .index = i, .depth = q.depth };
        count += 1;
    }
    for (0..state.partyCount() + state.enemyCount()) |member| if (battle.layout.uniteTrail(state, member)) |trail| {
        const depth = if (member >= state.partyCount()) trail[0].point.depth else if (state.unite_vm.ownsActor(member)) state.unite_trails[member].points[0].depth else battle.layout.position(state, member).depth;
        draws[count] = .{ .effect = false, .trail = true, .index = member, .depth = depth + 8 };
        count += 1;
    };
    for (0..battle.layout.unite_graphic_capacity) |index| if (battle.layout.uniteAuxiliary(state, index)) |quad| {
        draws[count] = .{ .effect = false, .auxiliary = true, .index = index, .depth = quad.depth };
        count += 1;
    };
    for (0..state.unite_vm.auxiliary.len) |index| if (battle.layout.uniteTrail(state, state.unite_vm.actors.len + index)) |trail| {
        draws[count] = .{ .effect = false, .trail = true, .index = state.unite_vm.actors.len + index, .depth = trail[0].point.depth + 8 };
        count += 1;
    };
    if (spell_frame) |frame| for (frame.commands[0..frame.count], 0..) |command, i| {
        if (!command.drawsInPass(minimum_depth)) continue;
        draws[count] = .{ .effect = true, .index = i, .depth = @floatFromInt(command.depth * 4) };
        count += 1;
    };
    std.mem.sort(Draw, draws[0..count], {}, struct {
        fn before(_: void, a: Draw, b: Draw) bool {
            if (a.depth == b.depth) {
                if (a.effect != b.effect) return a.effect;
                return if (a.effect) a.index > b.index else a.index < b.index;
            }
            return a.depth > b.depth;
        }
    }.before);
    for (draws[0..count]) |entry| {
        if (minimum_depth) |minimum| if (entry.depth < @as(f32, @floatFromInt(@as(u32, minimum) * 4))) continue;
        if (entry.auxiliary) {
            @import("battle_trial_view.zig").drawUniteAuxiliary(state, atlas, effect_atlas, entry.index);
            continue;
        }
        if (entry.trail) {
            @import("battle_trial_view.zig").drawUniteTrail(state, atlas, entry.index);
            continue;
        }
        if (entry.effect) {
            spell_view.drawCommand(state, effect_atlas orelse atlas, dynamic, spell_frame.?.commands[entry.index]);
            continue;
        }
        const q = list.quads[entry.index];
        const reaction = if (!q.projectile and !q.medicine_particle and q.actor != null) state.spellReaction(q.actor.?) else null;
        const sprite_atlas = if (reaction != null and reaction.?.entry != null) effect_atlas orelse atlas else atlas;
        const r = q.sprite.rect;
        const source: rl.Rectangle = .{ .x = @floatFromInt(r.x), .y = @floatFromInt(r.y), .width = @floatFromInt(r.w), .height = @floatFromInt(if (reaction != null and reaction.?.flip_y) -r.h else r.h) };
        const dest: rl.Rectangle = .{ .x = @floatFromInt(q.x), .y = @floatFromInt(q.y), .width = @floatFromInt(q.w), .height = @floatFromInt(q.h) };
        const rotated = if (!q.projectile and !q.medicine_particle and q.actor != null) battle.layout.rotatedActorQuad(state, q.actor.?, q.sprite, battle.layout.actorLayout(state, q.actor.?).point) else null;
        var light = q.light;
        if (reaction) |response| {
            if (!response.visible) continue;
            for (0..3) |axis| light[axis] = @intCast(@min(255, @as(u16, response.color[axis]) * response.tint / 128));
            spell_view.beginBlend(response.blend);
        }
        const tint = rl.Color{ .r = @intCast(@min(@as(u16, light[0]) * 2, 255)), .g = @intCast(@min(@as(u16, light[1]) * 2, 255)), .b = @intCast(@min(@as(u16, light[2]) * 2, 255)), .a = q.opacity };
        if (rotated) |quad| @import("battle_trial_view.zig").drawActorQuad(sprite_atlas, quad, tint, reaction != null and reaction.?.flip_y) else rl.drawTexturePro(sprite_atlas, source, dest, .{ .x = 0, .y = 0 }, 0, tint);
        if (reaction != null) rl.endBlendMode();
        if (light[0] > 128 or light[1] > 128 or light[2] > 128) {
            rl.beginBlendMode(.additive);
            const excess = rl.Color{ .r = (light[0] -| 128) * 2, .g = (light[1] -| 128) * 2, .b = (light[2] -| 128) * 2, .a = 255 };
            if (rotated) |quad| @import("battle_trial_view.zig").drawActorQuad(sprite_atlas, quad, excess, reaction != null and reaction.?.flip_y) else rl.drawTexturePro(sprite_atlas, source, dest, .{ .x = 0, .y = 0 }, 0, excess);
            rl.endBlendMode();
        }
    }
    if (minimum_depth == null) for (0..state.partyCount() + state.enemyCount()) |index| {
        const actor = art.actorLayout(data, state, index);
        @import("battle_trial_view.zig").drawActorFeedback(state, index, actor.point.x, actor.point.y, actor.point.y - @as(f32, @floatFromInt(actor.sprite.anchor_y)) * actor.scale);
    };
    if (minimum_depth == null) {
        const view = @import("battle_trial_view.zig");
        if (view.selectionTarget(&state)) |target| {
            const actor = art.actorLayout(data, state, target);
            view.drawTargetMarker(actor.point.x, actor.point.y);
        }
    }
    if (minimum_depth == null) if (spell_frame) |frame| {
        spell_view.beginBlend(frame.wash_blend);
        rl.drawRectangle(0, 38, 640, 298, .{ .r = frame.wash[0], .g = frame.wash[1], .b = frame.wash[2], .a = 255 });
        rl.endBlendMode();
    };
    if (minimum_depth == null) drawSpellVfx(state, data);
}
// Actor/background pass only; shares draw() camera and sampling, excludes placeholder VFX.
pub fn pixels(allocator: std.mem.Allocator, state: battle.State, atlas: []const rl.Color, floor: []const rl.Color) ![]rl.Color {
    for (0..state.partyCount() + state.enemyCount()) |index| if (state.spellReaction(index)) |reaction| if (reaction.entry != null) return error.SpellReactionAtlasRequired;
    const data = battle.layout.sceneArt(state);
    if (atlas.len != @as(usize, @intCast(data.atlas_width * data.atlas_height)) or floor.len != 320 * 240) return error.InvalidWorldBattleArt;
    const out = try allocator.alloc(rl.Color, 640 * 336);
    errdefer allocator.free(out);
    @memset(out, .black);
    for (38..336) |y| for (0..640) |x| {
        out[y * 640 + x] = floor[(36 + y / 2) * 320 + x / 2];
    };
    const list = art.compose(data, state);
    for (list.shadows) |shadow| {
        if (shadow.radius_x <= 0 or shadow.radius_y <= 0) continue;
        const cx: @TypeOf(shadow.point.x) = @floatFromInt(@as(i32, @intFromFloat(shadow.point.x)));
        const cy: @TypeOf(cx) = @floatFromInt(@as(i32, @intFromFloat(shadow.point.y)));
        for (38..336) |y| for (0..640) |x| {
            const dx = (@as(f32, @floatFromInt(x)) + 0.5 - cx) / shadow.radius_x;
            const dy = (@as(f32, @floatFromInt(y)) + 0.5 - cy) / shadow.radius_y;
            if (dx * dx + dy * dy > 1) continue;
            const color = &out[y * 640 + x];
            color.r = @intCast((@as(u32, color.r) * 115 + 127) / 255);
            color.g = @intCast((@as(u32, color.g) * 115 + 127) / 255);
            color.b = @intCast((@as(u32, color.b) * 115 + 127) / 255);
        };
    }
    for (list.quads[0..list.length]) |q| {
        const r = q.sprite.rect;
        const left = @max(0, q.x);
        const top = @max(38, q.y);
        const right = @min(640, q.x + q.w);
        const bottom = @min(336, q.y + q.h);
        if (left >= right or top >= bottom or q.w <= 0 or q.h <= 0) continue;
        for (@intCast(top)..@as(usize, @intCast(bottom))) |y| for (@intCast(left)..@as(usize, @intCast(right))) |x| {
            const sx = r.x + @divTrunc((2 * (@as(i32, @intCast(x)) - q.x) + 1) * r.w, 2 * q.w);
            const sy = r.y + @divTrunc((2 * (@as(i32, @intCast(y)) - q.y) + 1) * r.h, 2 * q.h);
            const color = atlas[@intCast(sy * data.atlas_width + sx)];
            if (color.a != 0 and color.a != 255) return error.UnsupportedWorldBattleAlpha;
            if (color.a != 0) out[y * 640 + x] = .{ .r = @intCast(@min(@as(u32, color.r) * q.light[0] / 128, 255)), .g = @intCast(@min(@as(u32, color.g) * q.light[1] / 128, 255)), .b = @intCast(@min(@as(u32, color.b) * q.light[2] / 128, 255)), .a = 255 };
        };
    }
    return out;
}

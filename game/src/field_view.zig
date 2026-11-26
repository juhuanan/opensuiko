const std = @import("std");
const rl = @import("raylib");
const field = @import("field");
const ui = @import("ui");
pub const effect_half_fragment =
    \\#version 330
    \\in vec4 fragColor;
    \\out vec4 finalColor;
    \\void main() { finalColor = vec4(fragColor.rgb, 0.5); }
;

pub fn drawEffect(effect: field.area_effect.Effect, half_shader: ?rl.Shader) void {
    rl.beginScissorMode(0, 24, 512, 384);
    defer rl.endScissorMode();
    // The shared source bucket prepends the flash after all ray submissions.
    if (effect.flash()) |quad| {
        const width = quad.points[1].x - quad.points[0].x;
        const height = quad.points[0].y - quad.points[2].y;
        if (width > 0 and height > 0) rl.drawRectangle(quad.points[0].x, quad.points[2].y, width, height, .white);
    }
    const first = effect.ray(0) orelse return;
    if (first.semitransparent) {
        std.debug.assert(half_shader != null);
        rl.beginShaderMode(half_shader.?);
        rl.gl.rlSetBlendFactorsSeparate(0x0302, 0x0303, 0, 1, 0x8006, 0x8006);
        rl.beginBlendMode(.custom_separate);
    }
    defer if (first.semitransparent) {
        rl.endBlendMode();
        rl.endShaderMode();
    };
    for (0..180) |index| {
        const ray = effect.ray(179 - index).?;
        rl.drawLine(ray.from.x, ray.from.y, ray.to.x, ray.to.y, .{ .r = ray.intensity, .g = ray.intensity, .b = ray.intensity, .a = 255 });
    }
}

fn sprite(atlas: rl.Texture2D, rect: field.Rect, x: f32, y: f32) void {
    rl.drawTextureRec(atlas, .{ .x = @floatFromInt(rect.x), .y = @floatFromInt(rect.y), .width = @floatFromInt(rect.w), .height = @floatFromInt(rect.h) }, .{ .x = @round(x), .y = @round(y) }, .white);
}

pub const ExtraSprite = struct { atlas: rl.Texture2D, rect: field.Rect, x: f32, y: f32, depth: f32, shadow: ?field.ShadowDraw = null };
pub const max_extra_sprites = 64 + 5;
pub const shadow_fragment =
    \\#version 330
    \\in vec2 fragTexCoord;
    \\uniform sampler2D texture0;
    \\uniform float shade8;
    \\out vec4 finalColor;
    \\void main() {
    \\    vec4 texel = texture(texture0, fragTexCoord);
    \\    vec3 rgb5 = floor(texel.rgb * 31.0 + 0.5);
    \\    vec3 shaded = floor(rgb5 * shade8 / 128.0);
    \\    finalColor = vec4(floor(shaded * 255.0 / 31.0) / 255.0, texel.a);
    \\}
;

fn drawActor(actor: ExtraSprite, shadow_shader: ?rl.Shader) void {
    if (actor.shadow) |shadow| {
        std.debug.assert(shadow_shader != null);
        rl.beginShaderMode(shadow_shader.?);
        const gl = rl.gl;
        gl.rlDisableBackfaceCulling();
        gl.rlSetTexture(actor.atlas.id);
        gl.rlBegin(4);
        for ([_]usize{ 0, 1, 2, 1, 3, 2 }) |corner| {
            const u = shadow.rect.x + if (corner & 1 != 0) shadow.rect.w else @as(i32, 0);
            const v = shadow.rect.y + if (corner >= 2) shadow.rect.h else @as(i32, 0);
            gl.rlColor4ub(255, 255, 255, 255);
            gl.rlTexCoord2f(@as(f32, @floatFromInt(u)) / @as(f32, @floatFromInt(actor.atlas.width)), @as(f32, @floatFromInt(v)) / @as(f32, @floatFromInt(actor.atlas.height)));
            gl.rlVertex2f(@floatFromInt(shadow.points[corner].x), @floatFromInt(shadow.points[corner].y));
        }
        gl.rlEnd();
        gl.rlSetTexture(0);
        gl.rlDrawRenderBatchActive();
        gl.rlEnableBackfaceCulling();
        rl.endShaderMode();
    }
    sprite(actor.atlas, actor.rect, actor.x, actor.y);
}

pub const WheelLayer = struct {
    draw_index: usize,
    projection: field.wheel.MapProjection,
};

fn drawWheelMap(atlas: rl.Texture2D, rect: field.Rect, layer: WheelLayer) void {
    std.debug.assert(rect.w == layer.projection.map_size[0] and rect.h == layer.projection.map_size[1]);
    const gl = rl.gl;
    gl.rlDisableBackfaceCulling();
    defer {
        gl.rlDrawRenderBatchActive();
        gl.rlEnableBackfaceCulling();
    }
    gl.rlSetTexture(atlas.id);
    gl.rlBegin(4);
    var fragments = layer.projection.fragments();
    while (fragments.next()) |fragment| {
        for ([_]usize{ 0, 1, 2, 1, 3, 2 }) |corner| {
            const u = rect.x + fragment.source.x + if (corner & 1 != 0) fragment.source.w else @as(i32, 0);
            const v = rect.y + fragment.source.y + if (corner >= 2) fragment.source.h else @as(i32, 0);
            gl.rlColor4ub(255, 255, 255, 255);
            gl.rlTexCoord2f(@as(f32, @floatFromInt(u)) / @as(f32, @floatFromInt(atlas.width)), @as(f32, @floatFromInt(v)) / @as(f32, @floatFromInt(atlas.height)));
            gl.rlVertex2f(@floatFromInt(fragment.vertices[corner].x), @floatFromInt(fragment.vertices[corner].y));
        }
    }
    gl.rlEnd();
    gl.rlSetTexture(0);
}

pub fn drawScene(context: *const ui.Context, state: field.State, package: field.Package, atlas: rl.Texture2D, scenery: rl.Texture2D, show_collision: bool, camera: field.CameraOffset, extras: []const ExtraSprite, hero: ?ExtraSprite, hero_visible: bool, wheel_layer: ?WheelLayer, shadow_shader: ?rl.Shader) void {
    std.debug.assert(extras.len <= max_extra_sprites);
    var draw_indices: [4096]usize = undefined;
    const room = package.rooms[state.room];
    const scenery_state = if (state.room_scenery) |*visit| visit else null;
    if (wheel_layer) |layer| std.debug.assert(layer.draw_index < room.draws.len);
    const position = state.position(package);
    const ox = camera.x;
    const oy = camera.y;
    const source_viewport = room.wheel_map != null;
    const scrolling = source_viewport or room.width > 512 or room.height > 384;
    const frame = state.frame(package);
    const depth = position.y / 8.0;
    for (room.draws, 0..) |_, i| draw_indices[i] = i;
    std.mem.sort(usize, draw_indices[0..room.draws.len], room.draws, struct {
        fn less(draws: []const field.Draw, a: usize, b: usize) bool {
            if (draws[a].depth == draws[b].depth) return a < b;
            return draws[a].depth < draws[b].depth;
        }
    }.less);
    rl.clearBackground(.{ .r = 17, .g = 23, .b = 30, .a = 255 });
    if (source_viewport) rl.beginMode2D(.{ .offset = .{ .x = 0, .y = 24 }, .target = .{ .x = 0, .y = 0 }, .rotation = 0, .zoom = 8.0 / 5.0 });
    defer if (source_viewport) rl.endMode2D();
    if (scrolling) rl.beginScissorMode(0, 24, 512, 384);
    var actors: [max_extra_sprites + 1]ExtraSprite = undefined;
    const first_extra: usize = if (hero_visible) 1 else 0;
    if (hero_visible) actors[0] = hero orelse .{ .atlas = atlas, .rect = frame.rect, .x = ox + position.x - @as(f32, @floatFromInt(frame.anchor_x)), .y = oy + position.y - @as(f32, @floatFromInt(frame.anchor_y)), .depth = depth };
    @memcpy(actors[first_extra..][0..extras.len], extras);
    const actor_count = extras.len + first_extra;
    std.mem.sort(ExtraSprite, actors[0..actor_count], {}, struct {
        fn less(_: void, a: ExtraSprite, b: ExtraSprite) bool {
            return a.depth < b.depth;
        }
    }.less);
    var next_actor: usize = 0;
    for (draw_indices[0..room.draws.len]) |index| {
        const piece = room.draws[index].sampleVisible(&state) orelse continue;
        const copies = room.sceneryCopies(piece, scenery_state);
        if (copies == 0) continue;
        while (next_actor < actor_count and @as(f32, @floatFromInt(piece.depth)) > actors[next_actor].depth) : (next_actor += 1) {
            const actor = actors[next_actor];
            drawActor(actor, shadow_shader);
        }
        if (wheel_layer != null and wheel_layer.?.draw_index == index) {
            drawWheelMap(scenery, piece.rect, wheel_layer.?);
        } else for (0..copies) |_| {
            sprite(scenery, piece.rect, ox + @as(f32, @floatFromInt(piece.x)), oy + @as(f32, @floatFromInt(piece.y)));
        }
    }
    for (actors[next_actor..actor_count]) |actor| drawActor(actor, shadow_shader);
    // Authored interaction marker for treasure events whose source appearance script is not exported.
    for (room.npcs) |npc| if (npc.marker != null and npc.visible(state.progress.story)) {
        const x: i32 = @intFromFloat(ox + @as(f32, @floatFromInt(npc.x)));
        const y: i32 = @intFromFloat(oy + @as(f32, @floatFromInt(npc.y)));
        if (npc.marker == .service) {
            rl.drawCircleLines(x, y - 8, 9, .gold);
            context.text("Smith", x - 18, y - 28, 12, .gold);
            continue;
        }
        rl.drawRectangle(x - 7, y - 11, 15, 12, .{ .r = 67, .g = 43, .b = 20, .a = 255 });
        rl.drawRectangleLines(x - 7, y - 11, 15, 12, .gold);
        rl.drawLine(x - 6, y - 6, x + 7, y - 6, .gold);
        rl.drawRectangle(x - 1, y - 7, 3, 4, .gold);
    };
    if (show_collision) {
        const width: usize = @intCast(@divTrunc(room.width, 8));
        for (room.walkable, 0..) |cell, i| {
            const x = @as(i32, @intCast(i % width)) * 8;
            const y = @as(i32, @intCast(i / width)) * 8;
            const walkable = if (scenery_state) |visit| room.canStandWithScenery(visit, x, y) else cell != '0';
            if (!walkable) rl.drawRectangle(@as(i32, @intFromFloat(ox)) + x, @as(i32, @intFromFloat(oy)) + y, 8, 8, .{ .r = 240, .g = 50, .b = 50, .a = 90 });
        }
        context.text("DEBUG: collision overlay - F2 to hide", 8, 24, 12, .gold);
    }
    if (scrolling) rl.endScissorMode();
    context.text(room.title, 8, 4, 16, .ray_white);
    var hp: u32 = 0;
    var max_hp: u32 = 0;
    var ailments: usize = 0;
    for (state.progress.party.items()) |member| {
        hp += member.hp;
        max_hp += member.max_hp;
        if (member.status != .healthy or member.balloons > 0) ailments += 1;
    }
    context.numberText("Party HP: {d}/{d}   Status ailments: {d}", .{ hp, max_hp, ailments }, 8, 392, 12, .ray_white);
    context.numberText("{d} bits", .{state.progress.money}, 402, 4, 12, .gold);
    context.text("Arrows/WASD: walk   Z/Enter: talk   Tab/Esc: menu   F2: collision", 8, 414, 10, .light_gray);
    if (state.dialogue) |dialogue| {
        context.window(12, 270, 488, 134);
        context.text(dialogue.name(room), 24, 278, 16, .gold);
        switch (dialogue.phase) {
            .pages => {
                const page = dialogue.pages(room)[dialogue.page];
                const shown = page[0..dialogue.revealedLength(page.len, state.scene_ticks)];
                context.text(shown, 24, 302, field.dialogueTextSize(page), .ray_white);
            },
            .recruitment_choices => {
                for (room.npcs[dialogue.source.npc].recruitment.?.choices, 0..) |label, i| {
                    const y: i32 = 302 + @as(i32, @intCast(i)) * 24;
                    context.text(if (dialogue.choice == i) ">" else " ", 24, y, 16, .gold);
                    context.text(label, 44, y, 16, if (dialogue.choice == i) .gold else .ray_white);
                }
            },
            .recruitment_accepted => {
                const reply = room.npcs[dialogue.source.npc].recruitment.?;
                context.numberText("{s}{s}{s}", .{ reply.accepted_prefix, state.progress.story.castleName(), reply.accepted_suffix }, 24, 302, 16, .ray_white);
            },
            .recruitment_declined => {
                const page = room.npcs[dialogue.source.npc].recruitment.?.declined[dialogue.page];
                context.text(page, 24, 302, field.dialogueTextSize(page), .ray_white);
            },
            .recruitment_joined => context.numberText("{s} {s}", .{ room.npcs[dialogue.source.npc].name, room.npcs[dialogue.source.npc].recruitment.?.joined }, 24, 302, 16, .ray_white),
            .choices => {
                const rules = state.inn_rules.?;
                context.numberText("Stay for {d} bits? ({d} per person)", .{ state.progress.cost(rules.price_per_member), rules.price_per_member }, 24, 302, 16, .ray_white);
                for (rules.choices, 0..) |label, i| {
                    const y: i32 = 330 + @as(i32, @intCast(i)) * 24;
                    context.text(if (dialogue.choice == i) ">" else " ", 24, y, 16, .gold);
                    context.text(label, 44, y, 16, if (dialogue.choice == i) .gold else .ray_white);
                }
                context.text("Up/Down: choose", 24, 380, 10, .light_gray);
            },
            .insufficient_funds => context.text(state.inn_rules.?.insufficient_funds, 24, 302, 16, .ray_white),
            .shop, .service => {},
            .unavailable => context.text("Your party cannot rest.", 24, 302, 16, .ray_white),
        }
        context.text("Z/Enter: continue   X: cancel", 274, 380, 10, .light_gray);
    }
    if (state.rest_ticks > 0) {
        rl.drawRectangle(0, 0, 512, 384, .{ .r = 0, .g = 0, .b = 0, .a = @intFromFloat(state.restOpacity() * 255) });
        context.text("Resting...", 214, 200, 16, .ray_white);
    }
}

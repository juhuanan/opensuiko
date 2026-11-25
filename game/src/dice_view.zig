//! Native dice controls, face geometry and source UI composition.
const rl = @import("raylib");
const platform = @import("raylib_app");
const journey = @import("journey");
const visual = journey.dice.visual;
const entry = journey.dice.Entry;
const presentation = journey.field_dialogue_view.presentation;

pub fn draw(packet: visual.Packet, poses: [3]visual.Pose, atlas: rl.Texture2D) void {
    for (packet.drawList(poses)) |quad| {
        var vertices: [4]rl.Vector2 = undefined;
        for (quad.points, 0..) |point, i| vertices[i] = .{ .x = @as(f32, @floatFromInt(point.x)) * 2, .y = @as(f32, @floatFromInt(point.y)) * 2 };
        const face = packet.faces[quad.face];
        platform.drawTexturedQuad(atlas, .{ .x = @floatFromInt(face.x), .y = @floatFromInt(face.y), .width = @floatFromInt(face.width), .height = @floatFromInt(face.height) }, vertices, .white, false);
    }
}

pub fn drawPortraits(packet: visual.Packet, atlas: rl.Texture2D) void {
    for (packet.portraits) |portrait| {
        const target = portrait.screen;
        rl.drawTexturePro(atlas, .{ .x = @floatFromInt(portrait.x), .y = @floatFromInt(portrait.y), .width = @floatFromInt(if (portrait.mirror) -portrait.width else portrait.width), .height = @floatFromInt(portrait.height) }, .{ .x = @floatFromInt(target.x * 2), .y = @floatFromInt(target.y * 2), .width = @floatFromInt(target.width * 2), .height = @floatFromInt(target.height * 2) }, .{ .x = 0, .y = 0 }, 0, .white);
    }
}

pub fn drawCursor(packet: visual.Packet, position: visual.Cursor) void {
    const vertices = packet.cursorVertices(position);
    const gl = rl.gl;
    gl.rlDisableBackfaceCulling();
    defer {
        gl.rlDrawRenderBatchActive();
        gl.rlEnableBackfaceCulling();
    }
    gl.rlSetTexture(gl.rlGetTextureIdDefault());
    gl.rlBegin(4);
    // The first source triangle has duplicate tip vertices and zero area.
    for ([_]usize{ 1, 3, 2 }) |corner| {
        const color = packet.cursor.colors[corner];
        gl.rlColor4ub(color[0], color[1], color[2], 255);
        gl.rlTexCoord2f(0.5, 0.5);
        gl.rlVertex2f(@as(f32, @floatFromInt(vertices[corner].x)) * 2, @as(f32, @floatFromInt(vertices[corner].y)) * 2);
    }
    gl.rlEnd();
    gl.rlSetTexture(0);
}

pub fn poll(sampler: *entry.Sampler, enabled: bool, device: ?i32) entry.Controls {
    return sampler.sample(pollHeld(device), enabled, device);
}

pub fn pollHeld(device: ?i32) entry.Buttons {
    return .{
        .up = rl.isKeyDown(.up) or rl.isKeyDown(.w) or pad(device, .left_face_up),
        .down = rl.isKeyDown(.down) or rl.isKeyDown(.s) or pad(device, .left_face_down),
        .left = rl.isKeyDown(.left) or rl.isKeyDown(.a) or pad(device, .left_face_left),
        .right = rl.isKeyDown(.right) or rl.isKeyDown(.d) or pad(device, .left_face_right),
        .confirm = rl.isKeyDown(.z) or rl.isKeyDown(.enter) or rl.isKeyDown(.space) or pad(device, .right_face_down),
        .cancel = rl.isKeyDown(.x) or rl.isKeyDown(.escape) or pad(device, .right_face_right),
        .triangle = rl.isKeyDown(.c) or pad(device, .right_face_up),
        .square = rl.isKeyDown(.v) or pad(device, .right_face_left),
    };
}

fn pad(device: ?i32, button: rl.GamepadButton) bool {
    return if (device) |id| rl.isGamepadButtonDown(id, button) else false;
}

pub fn compose(active: journey.dice.Active, packet: visual.Packet, art: anytype, list: *presentation.List) !void {
    list.length = 0;
    if (active.hud) |hud| {
        const rect = packet.hud.box;
        var buffer: [32]u8 = undefined;
        const text = try packet.formatHud(&buffer, hud.wager, hud.balance);
        try presentation.window(list, art, .{ .x = rect.x, .y = rect.y, .w = rect.width, .h = rect.height });
        try presentation.glyphs(list, art, text, rect.x, rect.y, null);
    }
    const dialogue = active.dialogue;
    if (dialogue.phase == .finished or dialogue.phase == .allocate) return;
    if (dialogue.outline(packet)) |rect| {
        try list.outlineRect(.{ .x = rect.x, .y = rect.y, .w = rect.width, .h = rect.height });
    } else {
        const rect = packet.entry_layout.box;
        try presentation.window(list, art, .{ .x = rect.x, .y = rect.y, .w = rect.width, .h = rect.height });
        try presentation.glyphs(list, art, dialogue.text.visible(), rect.x, rect.y, null);
    }
    if (active.result == null and active.entry.choicesAvailable()) {
        const choices = packet.entry_layout.choices;
        try presentation.window(list, art, .{ .x = choices.x, .y = choices.y, .w = choices.width, .h = choices.height });
        try presentation.glyphs(list, art, choices.text, choices.x, choices.y, null);
        try list.outlineRect(.{ .x = choices.x - 8, .y = choices.y - 2 + @as(i32, if (active.entry.selected_yes) 0 else 12), .w = 16, .h = 16 });
    }
}

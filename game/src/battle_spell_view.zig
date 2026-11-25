const rl = @import("raylib");
const gl = rl.gl;
const battle = @import("battle");

pub fn beginBlend(blend: battle.spell_scene.Blend) void {
    switch (blend) {
        .additive => rl.beginBlendMode(.additive),
        .subtractive => {
            // Subtract RGB while preserving the canvas alpha for compositing.
            gl.rlSetBlendFactorsSeparate(1, 1, 0, 1, 0x800B, 0x8006);
            rl.beginBlendMode(.custom_separate);
        },
        .@"opaque" => rl.beginBlendMode(.alpha),
    }
}

pub const DynamicTexture = struct {
    texture: rl.Texture2D,
    background: rl.RenderTexture2D,
    pixels: [4096][4]u8 = @splat(.{ 0, 0, 0, 0 }),
    pub fn init() !DynamicTexture {
        var pixels: [4096][4]u8 = @splat(.{ 0, 0, 0, 0 });
        const texture = try rl.loadTextureFromImage(.{ .data = &pixels, .width = 64, .height = 64, .mipmaps = 1, .format = .uncompressed_r8g8b8a8 });
        errdefer rl.unloadTexture(texture);
        const background = try rl.loadRenderTexture(1024, 512);
        rl.setTextureFilter(background.texture, .point);
        rl.setTextureFilter(texture, .point);
        return .{ .texture = texture, .background = background };
    }
    pub fn deinit(self: DynamicTexture) void {
        rl.unloadRenderTexture(self.background);
        rl.unloadTexture(self.texture);
    }
};

pub fn drawCommand(state: battle.State, atlas: rl.Texture2D, dynamic: ?*DynamicTexture, command: battle.spell_scene.Command) void {
    var source = atlas;
    var mutable = false;
    if (command.background_uv != null) {
        const cache = dynamic orelse @panic("background spell requires its render surface");
        source = cache.background.texture;
    }
    if (command.texture) |entry| if (dynamic) |cache| {
        mutable = state.effectPixels(entry, &cache.pixels);
        if (mutable) {
            gl.rlDrawRenderBatchActive();
            rl.updateTexture(cache.texture, &cache.pixels);
            source = cache.texture;
        }
    };
    beginBlend(command.blend);
    defer rl.endBlendMode();
    gl.rlDisableBackfaceCulling();
    defer {
        gl.rlDrawRenderBatchActive();
        gl.rlEnableBackfaceCulling();
    }
    gl.rlSetTexture(if (command.texture != null or command.background_uv != null) source.id else 0);
    gl.rlBegin(if (command.count == 2) 1 else 4);
    const order = [_]usize{ 0, 1, 2, 1, 3, 2 };
    for (order[0..if (command.count == 2) @as(usize, 2) else if (command.count == 3) @as(usize, 3) else 6]) |i| {
        if (command.background_uv) |uv| {
            gl.rlColor4ub(254, 254, 254, command.opacity);
            // Render targets have bottom-up texture storage; imported UVs use screen coordinates.
            gl.rlTexCoord2f(uv[i].x / 512, 1 - uv[i].y / 256);
        } else if (command.texture) |texture| {
            const rect = state.effectEntry(texture);
            gl.rlColor4ub(@intCast(@min(@as(u16, command.tint[0]) * 2, 255)), @intCast(@min(@as(u16, command.tint[1]) * 2, 255)), @intCast(@min(@as(u16, command.tint[2]) * 2, 255)), command.opacity);
            gl.rlTexCoord2f(@as(f32, @floatFromInt((if (mutable) @as(i32, 0) else rect.x) + (if (i == 1 or i == 3) rect.w else 0))) / @as(f32, @floatFromInt(source.width)), @as(f32, @floatFromInt((if (mutable) @as(i32, 0) else rect.y) + (if (i >= 2) rect.h else 0))) / @as(f32, @floatFromInt(source.height)));
        } else {
            const color = command.colors[i];
            gl.rlColor4ub(color[0], color[1], color[2], command.opacity);
        }
        gl.rlVertex2f(command.vertices[i].x * 2, command.vertices[i].y * 2);
    }
    gl.rlEnd();
    gl.rlSetTexture(0);
}

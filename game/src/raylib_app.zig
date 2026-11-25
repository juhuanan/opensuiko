const std = @import("std");
const rl = @import("raylib");

pub fn drawTexturedQuad(atlas: rl.Texture2D, rect: rl.Rectangle, vertices: [4]rl.Vector2, tint: rl.Color, flip_y: bool) void {
    const gl = rl.gl;
    gl.rlDisableBackfaceCulling();
    defer {
        gl.rlDrawRenderBatchActive();
        gl.rlEnableBackfaceCulling();
    }
    gl.rlSetTexture(atlas.id);
    gl.rlBegin(4);
    for ([_]usize{ 0, 1, 2, 1, 3, 2 }) |corner| {
        gl.rlColor4ub(tint.r, tint.g, tint.b, tint.a);
        gl.rlTexCoord2f((rect.x + if (corner & 1 != 0) rect.width else 0) / @as(f32, @floatFromInt(atlas.width)), (rect.y + if ((corner >= 2) != flip_y) rect.height else 0) / @as(f32, @floatFromInt(atlas.height)));
        gl.rlVertex2f(vertices[corner].x, vertices[corner].y);
    }
    gl.rlEnd();
    gl.rlSetTexture(0);
}

pub const WindowConfig = struct {
    width: i32,
    height: i32,
    title: [:0]const u8,
    min_width: ?i32 = null,
    min_height: ?i32 = null,
    target_fps: ?i32 = 60,
    resizable: bool = false,
    vsync: bool = false,
    hidden: bool = false,
    disable_exit_key: bool = true,
    trace_log_level: ?rl.TraceLogLevel = null,
};

pub fn initWindow(config: WindowConfig) !void {
    if (config.trace_log_level) |level| rl.setTraceLogLevel(level);
    if (config.resizable or config.vsync or config.hidden) {
        rl.setConfigFlags(.{
            .window_resizable = config.resizable,
            .vsync_hint = config.vsync,
            .window_hidden = config.hidden,
        });
    }
    rl.initWindow(config.width, config.height, config.title);
    if (!rl.isWindowReady()) return error.WindowInitializationFailed;
    if (config.min_width != null and config.min_height != null) {
        rl.setWindowMinSize(config.min_width.?, config.min_height.?);
    }
    if (config.disable_exit_key) rl.setExitKey(.null);
    if (config.target_fps) |fps| rl.setTargetFPS(fps);
}

pub fn anyKeyPressed(primary: rl.KeyboardKey, alternate: rl.KeyboardKey) bool {
    return rl.isKeyPressed(primary) or rl.isKeyPressed(alternate);
}

pub fn heldDirection(comptime Direction: type) ?Direction {
    if (rl.isKeyDown(.up) or rl.isKeyDown(.w)) return .up;
    if (rl.isKeyDown(.down) or rl.isKeyDown(.s)) return .down;
    if (rl.isKeyDown(.left) or rl.isKeyDown(.a)) return .left;
    if (rl.isKeyDown(.right) or rl.isKeyDown(.d)) return .right;
    return null;
}

pub fn pressedDirection(comptime Direction: type) ?Direction {
    if (anyKeyPressed(.up, .w)) return .up;
    if (anyKeyPressed(.down, .s)) return .down;
    if (anyKeyPressed(.left, .a)) return .left;
    if (anyKeyPressed(.right, .d)) return .right;
    return null;
}

pub fn joinSentinelPath(allocator: std.mem.Allocator, root: []const u8, name: []const u8) ![:0]u8 {
    const path = try std.fs.path.join(allocator, &.{ root, name });
    defer allocator.free(path);
    return allocator.dupeSentinel(u8, path, 0);
}

pub fn loadPointTexturePath(path: [:0]const u8) !rl.Texture2D {
    const texture = try rl.loadTexture(path);
    rl.setTextureFilter(texture, .point);
    return texture;
}

pub fn loadPointTexture(allocator: std.mem.Allocator, root: []const u8, name: []const u8) !rl.Texture2D {
    const sentinel = try joinSentinelPath(allocator, root, name);
    defer allocator.free(sentinel);
    return loadPointTexturePath(sentinel);
}

pub fn loadImage(allocator: std.mem.Allocator, root: []const u8, name: []const u8) !rl.Image {
    const sentinel = try joinSentinelPath(allocator, root, name);
    defer allocator.free(sentinel);
    return rl.loadImage(sentinel);
}

pub fn loadPointCanvas(width: i32, height: i32) !rl.RenderTexture2D {
    const canvas = try rl.loadRenderTexture(width, height);
    rl.setTextureFilter(canvas.texture, .point);
    return canvas;
}

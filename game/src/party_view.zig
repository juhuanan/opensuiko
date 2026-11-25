//! Native ownership of the selector's captured field image.
const std = @import("std");
const rl = @import("raylib");
const platform = @import("raylib_app");

const brightness_fragment =
    \\#version 330
    \\in vec2 fragTexCoord;
    \\in vec4 fragColor;
    \\uniform sampler2D texture0;
    \\uniform float brightness;
    \\out vec4 finalColor;
    \\void main() {
    \\    vec4 image = texture(texture0, fragTexCoord) * fragColor;
    \\    finalColor = vec4(image.rgb * brightness, image.a);
    \\}
;

pub const Background = struct {
    image: rl.RenderTexture2D,
    shader: rl.Shader,
    brightness_location: i32,

    pub fn capture(frame: rl.Texture2D) !Background {
        const image = try platform.loadPointCanvas(frame.width, frame.height);
        errdefer rl.unloadRenderTexture(image);
        const shader = try rl.loadShaderFromMemory(null, brightness_fragment);
        if (shader.id == rl.gl.rlGetShaderIdDefault()) return error.PartyBackgroundShaderUnavailable;
        errdefer rl.unloadShader(shader);
        const location = rl.getShaderLocation(shader, "brightness");
        if (location < 0) return error.PartyBackgroundShaderUnavailable;
        rl.beginTextureMode(image);
        rl.clearBackground(.black);
        rl.drawTextureRec(frame, .{ .x = 0, .y = 0, .width = @floatFromInt(frame.width), .height = @floatFromInt(-frame.height) }, .{ .x = 0, .y = 0 }, .white);
        rl.endTextureMode();
        return .{ .image = image, .shader = shader, .brightness_location = location };
    }

    pub fn draw(self: Background, level: u8) void {
        std.debug.assert(level <= 128);
        const brightness: f32 = @as(f32, @floatFromInt(level)) / 128.0;
        rl.setShaderValue(self.shader, self.brightness_location, &brightness, .float);
        rl.beginShaderMode(self.shader);
        defer rl.endShaderMode();
        rl.drawTextureRec(self.image.texture, .{ .x = 0, .y = 0, .width = @floatFromInt(self.image.texture.width), .height = @floatFromInt(-self.image.texture.height) }, .{ .x = 0, .y = 0 }, .white);
    }

    pub fn deinit(self: Background) void {
        rl.unloadShader(self.shader);
        rl.unloadRenderTexture(self.image);
    }
};

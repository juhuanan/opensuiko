//! Shared native ground draw and the source spell background-sampling pass.
const rl = @import("raylib");
const gl = rl.gl;
const battle = @import("battle");
const geometry = battle.layout;
const presentation = battle.presentation;

pub fn draw(state: *const battle.State, floor: rl.Texture2D, texture: ?rl.Texture2D, minimum_depth: u16) void {
    if (texture) |atlas| if (drawMesh(state, atlas, minimum_depth)) return;
    rl.drawTexturePro(floor, .{ .x = 0, .y = 36, .width = 320, .height = 168 }, .{ .x = 0, .y = 0, .width = 640, .height = 336 }, .{ .x = 0, .y = 0 }, 0, .white);
}

fn drawMesh(state: *const battle.State, texture: rl.Texture2D, minimum_depth: u16) bool {
    const field = geometry.battlefield(state);
    const ground = if (field) |entry| entry.ground else state.content.ground orelse return false;
    const source: battle.Rect = if (field) |entry| entry.ground_atlas else .{ .x = 0, .y = 0, .w = texture.width, .h = texture.height };
    const tile_columns = ground.tileColumns(source.w, source.h) orelse return false;
    const projection = geometry.worldProjection(state);
    const tile_size = battle.Ground.tile_size;
    const stride = @as(usize, ground.across) + 1;
    var projected: [(battle.Ground.max_axis + 1) * (battle.Ground.max_axis + 1)]presentation.ScreenPoint = undefined;
    for (projected[0..ground.vertices.len], ground.vertices) |*point, vertex| point.* = projection.point(vertex);
    gl.rlSetTexture(texture.id);
    gl.rlBegin(4);
    for (0..ground.down) |y| {
        for (0..ground.across) |x| {
            const a = projected[y * stride + x];
            const b = projected[y * stride + x + 1];
            const c = projected[(y + 1) * stride + x + 1];
            const d = projected[(y + 1) * stride + x];
            if (battle.spell_scene.groundDepth(@intFromFloat(a.depth)) < minimum_depth) continue;
            const tile = ground.tiles[y * @as(usize, ground.across) + x];
            const tile_x: i32 = @intCast((tile % tile_columns) * tile_size);
            const tile_y: i32 = @intCast((tile / tile_columns) * tile_size);
            const u_start = @as(f32, @floatFromInt(source.x + tile_x)) / @as(f32, @floatFromInt(texture.width));
            const v_start = @as(f32, @floatFromInt(source.y + tile_y)) / @as(f32, @floatFromInt(texture.height));
            const u_end = u_start + tile_size / @as(f32, @floatFromInt(texture.width));
            const v_end = v_start + tile_size / @as(f32, @floatFromInt(texture.height));
            gl.rlColor4ub(255, 255, 255, 255);
            gl.rlTexCoord2f(u_start, v_start);
            gl.rlVertex2f(a.x, a.y);
            gl.rlTexCoord2f(u_end, v_end);
            gl.rlVertex2f(c.x, c.y);
            gl.rlTexCoord2f(u_end, v_start);
            gl.rlVertex2f(b.x, b.y);
            gl.rlTexCoord2f(u_start, v_start);
            gl.rlVertex2f(a.x, a.y);
            gl.rlTexCoord2f(u_start, v_end);
            gl.rlVertex2f(d.x, d.y);
            gl.rlTexCoord2f(u_end, v_end);
            gl.rlVertex2f(c.x, c.y);
        }
    }
    gl.rlEnd();
    gl.rlSetTexture(0);
    return true;
}

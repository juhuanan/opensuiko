//! Shared native ground draw and the source spell background-sampling pass.
const rl = @import("raylib");
const gl = rl.gl;
const battle = @import("battle");
const geometry = battle.layout;
const presentation = battle.presentation;

pub fn draw(state: *const battle.State, floor: rl.Texture2D, texture: ?rl.Texture2D, minimum_depth: u16) void {
    if (texture) |atlas| if (drawMesh(state, atlas, minimum_depth)) return;
    rl.drawTexturePro(floor, .{ .x = 0, .y = 0, .width = 320, .height = 240 }, .{ .x = 0, .y = 0, .width = 640, .height = 480 }, .{ .x = 0, .y = 0 }, 0, .white);
}

fn projectGround(cam: presentation.Camera, p: presentation.Vec3) ?presentation.ScreenPoint {
    var view: [3]f32 = undefined;
    for (cam.transform, 0..) |row, i| view[i] = row[0] * p.x + row[1] * p.y + row[2] * p.z + row[3];
    if (view[2] <= 64.0) return null;
    return .{
        .x = cam.center_x + cam.focal_length * view[0] / view[2],
        .y = cam.center_y + cam.focal_length * view[1] / view[2],
        .depth = view[2],
    };
}

fn bilerpPos(a: battle.Position, b: battle.Position, c: battle.Position, d: battle.Position, u: f32, v: f32) presentation.Vec3 {
    const ab_x = a.x + (b.x - a.x) * u;
    const ab_y = a.y + (b.y - a.y) * u;
    const ab_z = a.z + (b.z - a.z) * u;
    const dc_x = d.x + (c.x - d.x) * u;
    const dc_y = d.y + (c.y - d.y) * u;
    const dc_z = d.z + (c.z - d.z) * u;
    return .{
        .x = ab_x + (dc_x - ab_x) * v,
        .y = ab_y + (dc_y - ab_y) * v,
        .z = ab_z + (dc_z - ab_z) * v,
    };
}

fn drawMesh(state: *const battle.State, texture: rl.Texture2D, minimum_depth: u16) bool {
    const field = geometry.battlefield(state);
    const ground = if (field) |entry| entry.ground else state.content.ground orelse return false;
    const source: battle.Rect = if (field) |entry| entry.ground_atlas else .{ .x = 0, .y = 0, .w = texture.width, .h = texture.height };
    const tile_columns = ground.tileColumns(source.w, source.h) orelse return false;
    const cam = geometry.sceneCamera(state);
    const tile_size = battle.Ground.tile_size;
    const stride = @as(usize, ground.across) + 1;
    const subdiv: usize = 4;
    const tex_w: f32 = @floatFromInt(texture.width);
    const tex_h: f32 = @floatFromInt(texture.height);
    gl.rlSetTexture(texture.id);
    gl.rlBegin(4);
    for (0..ground.down) |y| {
        for (0..ground.across) |x| {
            const w00 = ground.vertices[y * stride + x];
            const w10 = ground.vertices[y * stride + x + 1];
            const w11 = ground.vertices[(y + 1) * stride + x + 1];
            const w01 = ground.vertices[(y + 1) * stride + x];
            if (minimum_depth > 0) {
                const depth_ref = projectGround(cam, .{ .x = w00.x, .y = w00.y, .z = w00.z }) orelse continue;
                if (battle.spell_scene.groundDepth(@intFromFloat(depth_ref.depth)) < minimum_depth) continue;
            }
            const tile = ground.tiles[y * @as(usize, ground.across) + x];
            const tile_x: i32 = @intCast((tile % tile_columns) * tile_size);
            const tile_y: i32 = @intCast((tile / tile_columns) * tile_size);
            const u_start = @as(f32, @floatFromInt(source.x + tile_x)) / tex_w;
            const v_start = @as(f32, @floatFromInt(source.y + tile_y)) / tex_h;
            const u_span = tile_size / tex_w;
            const v_span = tile_size / tex_h;

            var grid: [subdiv + 1][subdiv + 1]?presentation.ScreenPoint = undefined;
            for (0..subdiv + 1) |sy| {
                const v = @as(f32, @floatFromInt(sy)) / @as(f32, @floatFromInt(subdiv));
                for (0..subdiv + 1) |sx| {
                    const u = @as(f32, @floatFromInt(sx)) / @as(f32, @floatFromInt(subdiv));
                    grid[sy][sx] = projectGround(cam, bilerpPos(w00, w10, w11, w01, u, v));
                }
            }

            gl.rlColor4ub(255, 255, 255, 255);
            for (0..subdiv) |sy| {
                const v_top = v_start + v_span * @as(f32, @floatFromInt(sy)) / @as(f32, @floatFromInt(subdiv));
                const v_bottom = v_start + v_span * @as(f32, @floatFromInt(sy + 1)) / @as(f32, @floatFromInt(subdiv));
                for (0..subdiv) |sx| {
                    const a = grid[sy][sx] orelse continue;
                    const b = grid[sy][sx + 1] orelse continue;
                    const c = grid[sy + 1][sx + 1] orelse continue;
                    const d = grid[sy + 1][sx] orelse continue;
                    const u_left = u_start + u_span * @as(f32, @floatFromInt(sx)) / @as(f32, @floatFromInt(subdiv));
                    const u_right = u_start + u_span * @as(f32, @floatFromInt(sx + 1)) / @as(f32, @floatFromInt(subdiv));
                    gl.rlTexCoord2f(u_left, v_top);
                    gl.rlVertex2f(a.x, a.y);
                    gl.rlTexCoord2f(u_right, v_bottom);
                    gl.rlVertex2f(c.x, c.y);
                    gl.rlTexCoord2f(u_right, v_top);
                    gl.rlVertex2f(b.x, b.y);
                    gl.rlTexCoord2f(u_left, v_top);
                    gl.rlVertex2f(a.x, a.y);
                    gl.rlTexCoord2f(u_left, v_bottom);
                    gl.rlVertex2f(d.x, d.y);
                    gl.rlTexCoord2f(u_right, v_bottom);
                    gl.rlVertex2f(c.x, c.y);
                }
            }
        }
    }
    gl.rlEnd();
    gl.rlSetTexture(0);
    return true;
}

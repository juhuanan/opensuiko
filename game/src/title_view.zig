const std = @import("std");
const rl = @import("raylib");
const raylib_app = @import("raylib_app");
const title = @import("pause_menu").title;
const ui = @import("ui");

pub const Media = struct {
    water: ?rl.Texture2D = null,
    clouds: ?rl.Texture2D = null,
    hero_spin: ?rl.Texture2D = null,
    logo: ?rl.Texture2D = null,
    push_start: ?rl.Texture2D = null,
    copyright: ?rl.Texture2D = null,
    music: ?rl.Music = null,
    music_playing: bool = false,
    music_volume_scale: f32 = @as(f32, 117.0) / 127.0,

    pub fn init(allocator: std.mem.Allocator, root: []const u8, audio_ready: bool) Media {
        var self: Media = .{};
        self.water = raylib_app.loadPointTexture(allocator, root, "title/water.png") catch null;
        if (self.water) |tex| {
            rl.setTextureFilter(tex, .bilinear);
            rl.setTextureWrap(tex, .clamp);
        }
        self.clouds = raylib_app.loadPointTexture(allocator, root, "title/clouds.png") catch null;
        self.hero_spin = raylib_app.loadPointTexture(allocator, root, "title/hero_spin.png") catch null;
        self.logo = raylib_app.loadPointTexture(allocator, root, "title/logo.png") catch null;
        self.push_start = raylib_app.loadPointTexture(allocator, root, "title/push_start.png") catch null;
        self.copyright = raylib_app.loadPointTexture(allocator, root, "title/copyright.png") catch null;
        if (audio_ready) {
            if (raylib_app.joinSentinelPath(allocator, root, "title/title.wav")) |path| {
                defer allocator.free(path);
                if (rl.loadMusicStream(path)) |loaded| {
                    var stream = loaded;
                    stream.looping = true;
                    self.music = stream;
                } else |_| {}
            } else |_| {}
        }
        return self;
    }

    pub fn deinit(self: *Media) void {
        if (self.music) |m| {
            if (self.music_playing) rl.stopMusicStream(m);
            rl.unloadMusicStream(m);
            self.music = null;
        }
        if (self.water) |tex| rl.unloadTexture(tex);
        if (self.clouds) |tex| rl.unloadTexture(tex);
        if (self.hero_spin) |tex| rl.unloadTexture(tex);
        if (self.logo) |tex| rl.unloadTexture(tex);
        if (self.push_start) |tex| rl.unloadTexture(tex);
        if (self.copyright) |tex| rl.unloadTexture(tex);
        self.* = .{};
    }

    pub fn syncAudio(self: *Media, active: bool, volume: f32) void {
        const m = self.music orelse return;
        if (!active) {
            if (self.music_playing) {
                rl.stopMusicStream(m);
                self.music_playing = false;
            }
            return;
        }
        rl.setMusicVolume(m, volume * self.music_volume_scale);
        if (!self.music_playing) {
            rl.seekMusicStream(m, 0);
            rl.playMusicStream(m);
            self.music_playing = true;
        }
        rl.updateMusicStream(m);
    }
};

pub fn draw(state: title.State, episode_name: []const u8, context: *const ui.Context) void {
    drawWithMedia(state, episode_name, context, null);
}

pub fn drawWithMedia(state: title.State, episode_name: []const u8, context: *const ui.Context, media: ?*const Media) void {
    if (media) |m| {
        if (m.water != null and m.logo != null) {
            drawPS1Composition(state, episode_name, context, m);
            return;
        }
    }
    drawFallback(state, episode_name, context);
}

fn drawWater(tex: rl.Texture2D, ticks: u32) void {
    const phase = @as(f32, @floatFromInt(ticks % 30000)) * (2.0 * std.math.pi / 128.0);
    const cols: usize = 40;
    const src_w: f32 = 8.0;
    const dst_w: f32 = 16.0;
    const wave_step = (2.0 * std.math.pi) / 28.0;
    for (0..cols) |col| {
        const col_f: f32 = @floatFromInt(col);
        const y0 = -12.0 + @sin(phase + col_f * wave_step) * 12.0;
        const y1 = -12.0 + @sin(phase + (col_f + 1.0) * wave_step) * 12.0;
        const x0 = col_f * dst_w;
        const x1 = x0 + dst_w;
        raylib_app.drawTexturedQuad(
            tex,
            .{ .x = col_f * src_w, .y = 0, .width = src_w, .height = 240.0 },
            .{
                .{ .x = x0, .y = y0 },
                .{ .x = x1, .y = y1 },
                .{ .x = x0, .y = 480.0 },
                .{ .x = x1, .y = 480.0 },
            },
            .white,
            false,
        );
    }
}

fn drawClouds(tex: rl.Texture2D) void {
    rl.drawTexturePro(
        tex,
        .{ .x = 0, .y = 0, .width = @floatFromInt(tex.width), .height = @floatFromInt(tex.height) },
        .{ .x = 0, .y = 0, .width = 640.0, .height = 480.0 },
        .{ .x = 0, .y = 0 },
        0,
        .white,
    );
}

fn drawHeroNaming(state: title.State, context: *const ui.Context, hero_spin: ?rl.Texture2D) void {
    if (hero_spin) |hs| {
        const frame = (state.title_ticks / 6) % 8;
        rl.drawTexturePro(
            hs,
            .{ .x = @floatFromInt(frame * 32), .y = 0, .width = 32.0, .height = 64.0 },
            .{ .x = 88.0, .y = 26.0, .width = 64.0, .height = 128.0 },
            .{ .x = 0, .y = 0 },
            0,
            .white,
        );
    }
    context.window(212, 48, 224, 62);
    var name_disp: [10]u8 = undefined;
    @memcpy(name_disp[0..state.hero_name_len], state.hero_name_buf[0..state.hero_name_len]);
    const show_cursor = (state.title_ticks / 18) % 2 == 0 and state.hero_name_len < title.max_hero_name;
    var disp_len = state.hero_name_len;
    if (show_cursor) {
        name_disp[disp_len] = '_';
        disp_len += 1;
    }
    context.text(name_disp[0..disp_len], 236, 68, 24, .ray_white);

    context.window(78, 134, 484, 272);
    var char_buf: [2]u8 = .{ 0, 0 };
    for (title.name_grid, 0..) |row, r| {
        const row_len = title.State.rowCharCount(r);
        const y = 152 + @as(i32, @intCast(r)) * 32;
        for (0..row_len) |c| {
            const x = 104 + @as(i32, @intCast(c)) * 34;
            const selected = state.name_cursor_row == r and state.name_cursor_col == c;
            if (selected) rl.drawRectangle(x - 4, y - 2, 24, 26, .{ .r = 212, .g = 175, .b = 55, .a = 95 });
            char_buf[0] = row[c];
            context.text(char_buf[0..1], x, y, 20, if (selected) .gold else .ray_white);
        }
    }
    const del_selected = state.name_cursor_row == 6 and state.name_cursor_col < 6;
    const start_selected = state.name_cursor_row == 6 and state.name_cursor_col >= 6;
    if (del_selected) rl.drawRectangle(178, 356, 62, 28, .{ .r = 212, .g = 175, .b = 55, .a = 95 });
    if (start_selected) rl.drawRectangle(342, 356, 98, 28, .{ .r = 212, .g = 175, .b = 55, .a = 95 });
    context.text("DEL", 188, 360, 20, if (del_selected) .gold else .ray_white);
    context.text("START", 352, 360, 20, if (start_selected) .gold else .ray_white);
}

fn drawPS1Composition(state: title.State, episode_name: []const u8, context: *const ui.Context, m: *const Media) void {
    if (state.phase == .movie) {
        drawFallback(state, episode_name, context);
        return;
    }
    const use_clouds = !(state.phase == .title and state.awaiting_start) and m.clouds != null;
    if (use_clouds) {
        drawClouds(m.clouds.?);
    } else {
        drawWater(m.water.?, state.title_ticks);
        const logo = m.logo.?;
        rl.drawTexturePro(
            logo,
            .{ .x = 0, .y = 0, .width = @floatFromInt(logo.width), .height = @floatFromInt(logo.height) },
            .{ .x = 64.0, .y = 44.0, .width = 512.0, .height = 192.0 },
            .{ .x = 0, .y = 0 },
            0,
            .white,
        );
    }
    switch (state.phase) {
        .movie, .playing => {},
        .title => {
            if (state.awaiting_start) {
                if (m.push_start) |ps| {
                    const frame = (state.title_ticks / 4 + 7) % 16;
                    rl.drawTexturePro(
                        ps,
                        .{ .x = 0, .y = @floatFromInt(frame * 32), .width = 128.0, .height = 32.0 },
                        .{ .x = 192.0, .y = 286.0, .width = 256.0, .height = 64.0 },
                        .{ .x = 0, .y = 0 },
                        0,
                        .white,
                    );
                } else {
                    context.text("PUSH START", 220, 304, 24, .gold);
                }
            } else {
                const win_y: i32 = if (use_clouds) 174 else 224;
                context.window(170, win_y, 300, 148);
                const labels = [_][]const u8{ "Continue game", if (state.opening_context) "New game" else title.start_label, "Quit" };
                for (labels, 0..) |label, i| {
                    const y = win_y + 20 + @as(i32, @intCast(i)) * 38;
                    if (state.selection == i) {
                        context.selectedText(">", 198, y, 20, .gold);
                        context.selectedText(label, 218, y, 20, .gold);
                    } else {
                        context.text(" ", 198, y, 20, .ray_white);
                        context.text(label, 218, y, 20, .ray_white);
                    }
                }
            }
        },
        .saves => {
            context.window(44, 150, 552, 212);
            for (state.summaries, 0..) |entry, i| {
                const y = 166 + @as(i32, @intCast(i)) * 46;
                context.numberText("{s} {d}: {s}", .{ if (state.slot == i) ">" else " ", i + 1, entry.name.text() }, 64, y, 17, if (state.slot == i) .gold else .ray_white);
                if (entry.status == .ready or entry.status == .backup) {
                    context.numberText("{s} Lv{d} | {s} | {d}:{d:0>2}{s}", .{ entry.leader, entry.level, entry.scene, entry.seconds / 3600, entry.seconds / 60 % 60, if (entry.status == .backup) " | Backup" else "" }, 84, y + 20, 12, .light_gray);
                } else {
                    context.text(switch (entry.status) {
                        .empty => "Empty",
                        .future => "Newer version required",
                        else => "Unreadable save",
                    }, 84, y + 20, 13, .light_gray);
                }
            }
        },
        .hero_name => drawHeroNaming(state, context, m.hero_spin),
        .episode_confirm => {
            context.window(70, 184, 500, 164);
            context.text(if (state.opening_context) "Begin the palace opening?" else title.confirmation_label, 108, 202, 22, .ray_white);
            context.text("Your existing saves will be kept.", 138, 240, 16, .light_gray);
            context.text(if (state.yes) "> Yes     No" else "  Yes   > No", 204, 290, 22, .gold);
        },
    }
    if (state.message.len != 0) context.text(state.message, 52, 392, 14, .gold);
    if (state.phase == .title and state.awaiting_start) {
        if (m.copyright) |copy_tex| {
            rl.drawTexturePro(
                copy_tex,
                .{ .x = 0, .y = 0, .width = @floatFromInt(copy_tex.width), .height = @floatFromInt(copy_tex.height) },
                .{ .x = 28.0, .y = 414.0, .width = 584.0, .height = 16.0 },
                .{ .x = 0, .y = 0 },
                0,
                .white,
            );
        }
        context.text("Press Enter / Confirm", 206, 446, 16, .light_gray);
    } else if (state.phase == .hero_name) {
        context.text("Type or Arrows: choose   Enter: insert / confirm   Esc: delete / back", 52, 446, 13, .light_gray);
    } else {
        context.text("Arrows / D-pad: choose   Enter / Confirm: select", 80, 446, 16, .light_gray);
    }
}

fn drawFallback(state: title.State, episode_name: []const u8, context: *const ui.Context) void {
    context.window(40, 54, 560, 370);
    context.text("SUIKODEN", 166, 78, 42, .gold);
    context.text(episode_name, 174, 130, 22, .ray_white);
    switch (state.phase) {
        .movie => {
            const spec = state.currentMovie();
            const frame = @min(state.movie_tick / 4 + 1, spec.frames);
            context.text(spec.disc_path, 152, 210, 22, .gold);
            context.numberText("Frame {d} / {d} ({d} fps)", .{ frame, spec.frames, spec.fps }, 152, 250, 18, .ray_white);
            context.text("Video playback metadata (media review open)", 118, 290, 15, .light_gray);
        },
        .title => {
            const labels = [_][]const u8{ "Continue", if (state.opening_context) "New Game" else title.start_label, "Quit" };
            for (labels, 0..) |label, i| {
                const y = 208 + @as(i32, @intCast(i)) * 48;
                if (state.selection == i) {
                    context.selectedText(">", 188, y, 24, .gold);
                    context.selectedText(label, 208, y, 24, .gold);
                } else {
                    context.text(" ", 188, y, 24, .ray_white);
                    context.text(label, 208, y, 24, .ray_white);
                }
            }
        },
        .saves => {
            for (state.summaries, 0..) |entry, i| {
                const y = 186 + @as(i32, @intCast(i)) * 64;
                context.numberText("{s} {d}: {s}", .{ if (state.slot == i) ">" else " ", i + 1, entry.name.text() }, 70, y, 19, if (state.slot == i) .gold else .ray_white);
                if (entry.status == .ready or entry.status == .backup) {
                    context.numberText("{s} Lv{d} | {s} | {d}:{d:0>2}{s}", .{ entry.leader, entry.level, entry.scene, entry.seconds / 3600, entry.seconds / 60 % 60, if (entry.status == .backup) " | Backup" else "" }, 88, y + 24, 13, .light_gray);
                } else context.text(switch (entry.status) {
                    .empty => "Empty",
                    .future => "Newer version required",
                    else => "Unreadable save",
                }, 88, y + 24, 15, .light_gray);
            }
        },
        .hero_name => drawHeroNaming(state, context, null),
        .episode_confirm => {
            context.text(if (state.opening_context) "Begin the palace opening?" else title.confirmation_label, 98, 202, 24, .ray_white);
            context.text("Your existing saves will be kept.", 134, 244, 18, .light_gray);
            context.text(if (state.yes) "> Yes     No" else "  Yes   > No", 192, 302, 23, .gold);
        },
        .playing => {},
    }
    context.text(state.message, 52, 390, 14, .gold);
    context.text("Arrows / D-pad: choose   Enter / Confirm: select", 80, 448, 16, .light_gray);
}

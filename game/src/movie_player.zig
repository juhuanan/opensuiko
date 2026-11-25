//! Candidate STR movie playback (SJV1 PNG frames + WAV audio stream).
const std = @import("std");
const rl = @import("raylib");
const raylib_app = @import("raylib_app");
const title_mod = @import("pause_menu").title;

const FrameEntry = struct {
    offset: u32,
    size: u32,
};

pub const MoviePlayer = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    audio_ready: bool,
    active_stage: ?title_mod.MovieStage = null,
    file: ?std.Io.File = null,
    entries: []FrameEntry = &.{},
    fps: u16 = 15,
    width: i32 = 320,
    height: i32 = 240,
    jpeg_buf: []u8 = &.{},
    texture: ?rl.Texture2D = null,
    loaded_frame: ?usize = null,
    music: ?rl.Music = null,
    has_video_frame: bool = false,
    missing_stage: ?title_mod.MovieStage = null,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, root: []const u8, audio_ready: bool) MoviePlayer {
        return .{
            .io = io,
            .allocator = allocator,
            .root = root,
            .audio_ready = audio_ready,
        };
    }

    pub fn deinit(self: *MoviePlayer) void {
        self.stop();
        if (self.texture) |tex| rl.unloadTexture(tex);
        self.texture = null;
    }

    pub fn stop(self: *MoviePlayer) void {
        if (self.music) |m| {
            rl.stopMusicStream(m);
            rl.unloadMusicStream(m);
            self.music = null;
        }
        if (self.file) |f| {
            f.close(self.io);
            self.file = null;
        }
        if (self.entries.len != 0) {
            self.allocator.free(self.entries);
            self.entries = &.{};
        }
        if (self.jpeg_buf.len != 0) {
            self.allocator.free(self.jpeg_buf);
            self.jpeg_buf = &.{};
        }
        self.active_stage = null;
        self.loaded_frame = null;
        self.has_video_frame = false;
    }

    pub fn sync(self: *MoviePlayer, phase_is_movie: bool, stage: title_mod.MovieStage, movie_tick: u32, volume: f32) void {
        if (!phase_is_movie) {
            if (self.active_stage != null or self.music != null) self.stop();
            return;
        }
        if (self.active_stage != stage) {
            if (self.missing_stage == stage) return;
            self.loadStage(stage, volume) catch |err| {
                std.log.warn("Movie playback unavailable for {s}: {s}", .{ @tagName(stage), @errorName(err) });
                self.stop();
                self.missing_stage = stage;
                return;
            };
        }
        if (self.music) |m| {
            rl.setMusicVolume(m, volume);
            rl.updateMusicStream(m);
        }
        if (self.entries.len == 0 or self.file == null) return;
        var frame_index: usize = @intCast(movie_tick / 4);
        if (self.music) |m| {
            if (rl.isMusicStreamPlaying(m)) {
                const played = rl.getMusicTimePlayed(m);
                if (played >= 0) {
                    frame_index = @intFromFloat(played * @as(f32, @floatFromInt(self.fps)));
                }
            }
        }
        frame_index = @min(frame_index, self.entries.len - 1);
        if (self.loaded_frame == frame_index) return;
        self.decodeFrame(frame_index) catch |err| {
            std.log.warn("Movie frame {d} failed: {s}", .{ frame_index, @errorName(err) });
        };
    }

    pub fn draw(self: *const MoviePlayer) bool {
        if (!self.has_video_frame) return false;
        const tex = self.texture orelse return false;
        rl.drawTexturePro(
            tex,
            .{ .x = 0, .y = 0, .width = @floatFromInt(tex.width), .height = @floatFromInt(tex.height) },
            .{ .x = 0, .y = 0, .width = 640, .height = 480 },
            .{ .x = 0, .y = 0 },
            0,
            .white,
        );
        return true;
    }

    fn loadStage(self: *MoviePlayer, stage: title_mod.MovieStage, volume: f32) !void {
        self.stop();
        self.missing_stage = null;
        const spec = title_mod.movieSpec(stage);
        const rel_vid = try std.fmt.allocPrint(self.allocator, "video/{s}.sjv", .{spec.id});
        defer self.allocator.free(rel_vid);
        const full_vid = try std.fs.path.join(self.allocator, &.{ self.root, rel_vid });
        defer self.allocator.free(full_vid);

        var file_owned = true;
        const file = try std.Io.Dir.cwd().openFile(self.io, full_vid, .{ .mode = .read_only, .allow_directory = false });
        errdefer if (file_owned) file.close(self.io);

        var hdr: [14]u8 = undefined;
        if (try file.readPositionalAll(self.io, &hdr, 0) != hdr.len) return error.InvalidMovieFile;
        if (!std.mem.eql(u8, hdr[0..4], "SJV1")) return error.InvalidMovieHeader;
        const width = std.mem.readInt(u16, hdr[4..6], .little);
        const height = std.mem.readInt(u16, hdr[6..8], .little);
        const fps = std.mem.readInt(u16, hdr[8..10], .little);
        const count = std.mem.readInt(u32, hdr[10..14], .little);
        if (width == 0 or height == 0 or fps == 0 or count == 0 or count > 20000) return error.InvalidMovieHeader;

        const index_bytes = try self.allocator.alloc(u8, @as(usize, count) * 8);
        defer self.allocator.free(index_bytes);
        if (try file.readPositionalAll(self.io, index_bytes, hdr.len) != index_bytes.len) return error.InvalidMovieIndex;

        var entries_owned = true;
        const entries = try self.allocator.alloc(FrameEntry, count);
        errdefer if (entries_owned) self.allocator.free(entries);
        var max_size: u32 = 0;
        for (entries, 0..) |*entry, i| {
            const base = i * 8;
            entry.* = .{
                .offset = std.mem.readInt(u32, index_bytes[base..][0..4], .little),
                .size = std.mem.readInt(u32, index_bytes[base + 4 ..][0..4], .little),
            };
            if (entry.size > max_size) max_size = entry.size;
        }
        if (max_size == 0 or max_size > 4 * 1024 * 1024) return error.InvalidMovieFrameSize;
        var jpeg_buf_owned = true;
        const jpeg_buf = try self.allocator.alloc(u8, max_size);
        errdefer if (jpeg_buf_owned) self.allocator.free(jpeg_buf);

        if (self.texture) |tex| {
            if (tex.width != width or tex.height != height) {
                rl.unloadTexture(tex);
                self.texture = null;
            }
        }
        if (self.texture == null) {
            const pixels = try self.allocator.alloc(u8, @as(usize, width) * @as(usize, height) * 4);
            defer self.allocator.free(pixels);
            @memset(pixels, 0);
            const tex = try rl.loadTextureFromImage(.{
                .data = pixels.ptr,
                .width = @intCast(width),
                .height = @intCast(height),
                .mipmaps = 1,
                .format = .uncompressed_r8g8b8a8,
            });
            rl.setTextureFilter(tex, .point);
            self.texture = tex;
        }

        if (self.audio_ready) {
            const rel_wav = try std.fmt.allocPrint(self.allocator, "video/{s}.wav", .{spec.id});
            defer self.allocator.free(rel_wav);
            const full_wav = try raylib_app.joinSentinelPath(self.allocator, self.root, rel_wav);
            defer self.allocator.free(full_wav);
            if (rl.loadMusicStream(full_wav)) |loaded| {
                var stream = loaded;
                stream.looping = false;
                rl.setMusicVolume(stream, volume);
                rl.playMusicStream(stream);
                self.music = stream;
            } else |_| {}
        }

        self.file = file;
        file_owned = false;
        self.entries = entries;
        entries_owned = false;
        self.jpeg_buf = jpeg_buf;
        jpeg_buf_owned = false;
        self.fps = fps;
        self.width = @intCast(width);
        self.height = @intCast(height);
        self.active_stage = stage;
        self.loaded_frame = null;
        self.has_video_frame = false;
        try self.decodeFrame(0);
    }

    fn decodeFrame(self: *MoviePlayer, index: usize) !void {
        const entry = self.entries[index];
        const slice = self.jpeg_buf[0..entry.size];
        if (try self.file.?.readPositionalAll(self.io, slice, entry.offset) != slice.len) return error.ShortMovieFrame;
        var image = try rl.loadImageFromMemory(".png", slice);
        defer rl.unloadImage(image);
        if (image.width != self.width or image.height != self.height) return error.UnexpectedMovieDimensions;
        if (image.format != .uncompressed_r8g8b8a8) {
            rl.imageFormat(&image, .uncompressed_r8g8b8a8);
        }
        rl.updateTexture(self.texture.?, image.data);
        self.loaded_frame = index;
        self.has_video_frame = true;
    }
};

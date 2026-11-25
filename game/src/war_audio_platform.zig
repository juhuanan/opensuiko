const std = @import("std");
const rl = @import("raylib");
const content = @import("war_content");

pub const Platform = struct {
    wave: rl.Wave,
    sample_bytes: []const content.Sample,
    device: bool = false,
    current: ?rl.Sound = null,
    music: [3]?rl.Music = @splat(null),
    active_music: ?usize = null,

    pub fn open(init: std.process.Init, path: []const u8, audio: content.Audio) !Platform {
        const filename = try std.fs.path.joinZ(init.gpa, &.{ path, "banks/WAR.wav" });
        defer init.gpa.free(filename);
        var self: Platform = .{
            .wave = try rl.loadWave(filename),
            .sample_bytes = audio.samples,
        };
        errdefer self.deinit();
        rl.initAudioDevice();
        self.device = rl.isAudioDeviceReady();
        if (!self.device) return error.AudioDeviceUnavailable;
        for (audio.xa2.channels) |channel| {
            const music_path = try std.fs.path.joinZ(init.gpa, &.{ path, channel.path });
            defer init.gpa.free(music_path);
            self.music[channel.index] = try rl.loadMusicStream(music_path);
            self.music[channel.index].?.looping = false;
        }
        return self;
    }

    pub fn deinit(self: *Platform) void {
        if (self.current) |sound| {
            rl.stopSound(sound);
            rl.unloadSound(sound);
        }
        for (self.music) |stream| if (stream) |music| {
            rl.stopMusicStream(music);
            rl.unloadMusicStream(music);
        };
        if (self.device) rl.closeAudioDevice();
        rl.unloadWave(self.wave);
        self.* = undefined;
    }

    fn range(self: *const Platform, index: u16) !struct { start: usize, end: usize } {
        if (index >= self.sample_bytes.len) return error.UnknownWarAudioSample;
        var start: usize = 0;
        for (self.sample_bytes[0..index]) |size| start += size * 28;
        return .{ .start = start, .end = start + self.sample_bytes[index] * 28 };
    }

    pub fn stopXa(self: *Platform) void {
        if (self.active_music) |index| {
            rl.stopMusicStream(self.music[index].?);
            self.active_music = null;
        }
    }

    pub fn playXa(self: *Platform, index: usize) !void {
        if (index >= self.music.len or self.music[index] == null) return error.UnknownWarAudioChannel;
        self.stopXa();
        rl.playMusicStream(self.music[index].?);
        self.active_music = index;
    }

    pub fn playSample(self: *Platform, index: u16) !void {
        self.stopXa();
        const bounds = try self.range(index);
        if (self.current) |sound| {
            rl.stopSound(sound);
            rl.unloadSound(sound);
            self.current = null;
        }
        const samples = @as([*]i16, @ptrCast(@alignCast(self.wave.data))) + bounds.start;
        const event_wave: rl.Wave = .{
            .frameCount = @intCast(bounds.end - bounds.start),
            .sampleRate = self.wave.sampleRate,
            .sampleSize = self.wave.sampleSize,
            .channels = self.wave.channels,
            .data = samples,
        };
        self.current = rl.loadSoundFromWave(event_wave);
        rl.playSound(self.current.?);
    }

    pub fn update(self: *Platform) void {
        if (self.active_music) |index| rl.updateMusicStream(self.music[index].?);
    }
};

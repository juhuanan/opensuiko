const std = @import("std");
pub const Id = enum { palace, audience };
pub const Track = struct {
    id: Id,
    path: []const u8,
    sample_rate: u32,
    frames: u32,
    loop_start_frame: u32,
    volume: u8,
    pub fn loopSeconds(self: Track) f32 {
        return @as(f32, @floatFromInt(self.loop_start_frame)) / @as(f32, @floatFromInt(self.sample_rate));
    }
};
pub const Content = struct {
    schema: []const u8,
    tracks: []const Track,
    pub fn get(self: Content, id: Id) Track {
        for (self.tracks) |track| if (track.id == id) return track;
        unreachable;
    }
    pub fn validate(self: Content) !void {
        if (!std.mem.eql(u8, self.schema, "suikoden-opening-audio/1")) return error.UnsupportedOpeningAudio;
        if (self.tracks.len != 2) return error.InvalidOpeningAudio;
        for (self.tracks, 0..) |track, index| {
            const path = if (track.id == .palace) "palace.wav" else "audience.wav";
            if (!std.mem.eql(u8, path, track.path) or track.sample_rate < 8000 or track.sample_rate > 48000 or track.frames == 0 or track.frames > 48000 * 600 or track.loop_start_frame >= track.frames or track.volume > 127) return error.InvalidOpeningAudio;
            for (self.tracks[0..index]) |previous| if (previous.id == track.id) return error.InvalidOpeningAudio;
        }
    }
};
pub fn load(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Content) {
    if (bytes.len > 4096) return error.InvalidOpeningAudio;
    const parsed = try std.json.parseFromSlice(Content, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    try parsed.value.validate();
    return parsed;
}
pub fn matchesHash(bytes: []const u8, expected: []const u8) bool {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.mem.eql(u8, &std.fmt.bytesToHex(digest, .lower), expected);
}
pub const State = struct {
    track: ?Id = null,
    pub fn deliverField(self: *State, scene: anytype, binding: anytype, identity: []const u8, audience_path: []const u8, sink: anytype) !void {
        try scene.validate(binding);
        const request = scene.audio_request orelse return error.MissingFieldAudioRequest;
        const access = binding.audio orelse return error.MissingFieldAudioAccess;
        if (!std.mem.eql(u8, identity, access.identity) or !std.mem.eql(u8, audience_path, access.audience_path)) return error.FieldAudioResourceMismatch;
        try self.requestAudience(sink);
        try scene.acknowledgeAudio(binding, request.batch, request.origin);
    }
    pub fn requestAudience(self: *State, sink: anytype) !void {
        // shortcut: same-stream reload is unproven; implement it when its source lifecycle is established.
        if (self.track == .audience) return error.UnsupportedAudienceReload;
        try sink.playAudience(self.track);
        self.track = .audience;
    }
    pub fn cue(self: *State, value: u16) bool {
        const next: ?Id = switch (value) {
            0x81 => .palace,
            0x422 => .audience,
            0x15 => null,
            else => return false,
        };
        if (next == self.track) return false;
        self.track = next;
        return true;
    }
};

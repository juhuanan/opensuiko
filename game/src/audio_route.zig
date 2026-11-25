//! Pure room/battle routing and the optional source stream manifest.
const std = @import("std");

pub const Track = enum { none, palace, audience, battle, boss, victory, defeat, area_b, dice, ruins, lakeshore, headquarters, founding, infiltration, mansion, wheel };

pub fn trackForRoom(room_id: []const u8) Track {
    if (std.mem.startsWith(u8, room_id, "vaa_")) return .palace;
    if (std.mem.startsWith(u8, room_id, "va1_") or std.mem.eql(u8, room_id, "world_a")) return .audience;
    return .none;
}

pub const StreamTrack = struct {
    id: Track,
    path: []const u8,
    sample_rate: u32,
    frames: u32,
    loop_start_frame: u32,
    volume: u8,
    sha256: []const u8,
    restart_after_ticks: ?u32 = null,
    pub fn loopSeconds(self: StreamTrack) f32 {
        return @as(f32, @floatFromInt(self.loop_start_frame)) / @as(f32, @floatFromInt(self.sample_rate));
    }
    pub fn matches(self: StreamTrack, bytes: []const u8) bool {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        return std.mem.eql(u8, &std.fmt.bytesToHex(digest, .lower), self.sha256);
    }
    pub fn loops(self: StreamTrack) bool {
        return self.id != .defeat and self.restart_after_ticks == null;
    }
    pub fn advanceRestart(self: StreamTrack, elapsed: *u32) bool {
        const period = self.restart_after_ticks orelse return false;
        std.debug.assert(period > 0 and elapsed.* < period);
        elapsed.* += 1;
        if (elapsed.* < period) return false;
        elapsed.* = 0;
        return true;
    }
    pub fn validate(self: StreamTrack) !void {
        const expected = switch (self.id) {
            .battle => "battle.wav",
            .boss => "boss.wav",
            .victory => "victory.wav",
            .defeat => "defeat.wav",
            .area_b => "area_b.wav",
            .dice => "dice.wav",
            .ruins => "ruins.wav",
            .lakeshore => "lakeshore.wav",
            .headquarters => "headquarters.wav",
            .founding => "founding.wav",
            .infiltration => "infiltration.wav",
            .mansion => "mansion.wav",
            .wheel => "wheel.wav",
            else => return error.InvalidBattleAudio,
        };
        if (self.id == .founding) {
            if (self.restart_after_ticks != 7249 or self.loop_start_frame != 0 or self.sample_rate != 37800 or self.frames != 4632768 or self.volume != 127) return error.InvalidBattleAudio;
        } else if (self.restart_after_ticks != null) return error.InvalidBattleAudio;
        if (!std.mem.eql(u8, self.path, expected) or self.sample_rate < 8000 or self.sample_rate > 48000 or self.frames == 0 or self.frames > 48000 * 600 or self.loop_start_frame >= self.frames or self.volume > 127 or self.sha256.len != 64) return error.InvalidBattleAudio;
        for (self.sha256) |char| if (!(char >= '0' and char <= '9') and !(char >= 'a' and char <= 'f')) return error.InvalidBattleAudio;
    }
};
pub const BattleTrack = StreamTrack;

pub const BattleContent = struct {
    schema: []const u8,
    tracks: []const BattleTrack,
    pub fn get(self: BattleContent, id: Track) ?BattleTrack {
        for (self.tracks) |track| if (track.id == id) return track;
        return null;
    }
    pub fn validate(self: BattleContent) !void {
        if (!std.mem.eql(u8, self.schema, "suikoden-battle-audio/1") or self.tracks.len != 3) return error.InvalidBattleAudio;
        for (self.tracks, 0..) |track, index| {
            if (track.id != .battle and track.id != .boss and track.id != .victory) return error.InvalidBattleAudio;
            try track.validate();
            for (self.tracks[0..index]) |prior| if (prior.id == track.id) return error.InvalidBattleAudio;
        }
    }
};
pub fn loadBattle(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(BattleContent) {
    if (bytes.len > 4096) return error.InvalidBattleAudio;
    const parsed = try std.json.parseFromSlice(BattleContent, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    try parsed.value.validate();
    return parsed;
}

pub const DiceContent = struct {
    pub const manifest_path = "audio/dice.json";
    schema: []const u8,
    tracks: [2]StreamTrack,

    pub fn get(self: DiceContent, id: Track) ?StreamTrack {
        for (self.tracks) |track| if (track.id == id) return track;
        return null;
    }
    pub fn validate(self: DiceContent) !void {
        if (!std.mem.eql(u8, self.schema, "suikoden-dice-audio/1") or self.get(.area_b) == null or self.get(.dice) == null) return error.InvalidDiceAudio;
        for (self.tracks) |track| track.validate() catch return error.InvalidDiceAudio;
    }
};
pub fn loadDice(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(DiceContent) {
    if (bytes.len > 4096) return error.InvalidDiceAudio;
    const parsed = try std.json.parseFromSlice(DiceContent, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    try parsed.value.validate();
    return parsed;
}

pub const FieldContent = struct {
    pub const manifest_path = "audio/field.json";
    schema: []const u8,
    tracks: []const StreamTrack,

    pub fn get(self: FieldContent, id: Track) ?StreamTrack {
        for (self.tracks) |track| if (track.id == id) return track;
        return null;
    }
    pub fn validate(self: FieldContent) !void {
        const wheel = std.mem.eql(u8, self.schema, "suikoden-field-audio/6");
        const mansion = wheel or std.mem.eql(u8, self.schema, "suikoden-field-audio/5");
        const infiltration = mansion or std.mem.eql(u8, self.schema, "suikoden-field-audio/4");
        const founding = infiltration or std.mem.eql(u8, self.schema, "suikoden-field-audio/3");
        const entry_music = founding or std.mem.eql(u8, self.schema, "suikoden-field-audio/2");
        if ((!entry_music and !std.mem.eql(u8, self.schema, "suikoden-field-audio/1")) or self.tracks.len != @as(usize, if (wheel) 8 else if (mansion) 7 else if (infiltration) 6 else if (founding) 5 else if (entry_music) 4 else 3) or
            self.get(.area_b) == null or self.get(.ruins) == null or self.get(.lakeshore) == null or (entry_music and self.get(.headquarters) == null)) return error.InvalidFieldAudio;
        if (wheel and self.get(.wheel) == null) return error.InvalidFieldAudio;
        if (mansion and self.get(.mansion) == null) return error.InvalidFieldAudio;
        if (infiltration and self.get(.infiltration) == null) return error.InvalidFieldAudio;
        if (founding and self.get(.founding) == null) return error.InvalidFieldAudio;
        for (self.tracks) |track| try track.validate();
    }
};

pub fn loadField(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(FieldContent) {
    if (bytes.len > 4096) return error.InvalidFieldAudio;
    const parsed = try std.json.parseFromSlice(FieldContent, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    try parsed.value.validate();
    return parsed;
}

pub const DefeatContent = struct {
    schema: []const u8,
    id: Track,
    path: []const u8,
    sample_rate: u32,
    frames: u32,
    volume: u8,
    repeat: bool,
    sha256: []const u8,

    pub fn track(self: DefeatContent) BattleTrack {
        return .{ .id = self.id, .path = self.path, .sample_rate = self.sample_rate, .frames = self.frames, .loop_start_frame = 0, .volume = self.volume, .sha256 = self.sha256 };
    }
    pub fn validate(self: DefeatContent) !void {
        if (!std.mem.eql(u8, self.schema, "suikoden-defeat-audio/1") or self.id != .defeat or self.repeat) return error.InvalidBattleAudio;
        try self.track().validate();
    }
};
pub fn loadDefeat(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(DefeatContent) {
    if (bytes.len > 4096) return error.InvalidBattleAudio;
    const parsed = try std.json.parseFromSlice(DefeatContent, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    try parsed.value.validate();
    return parsed;
}

pub const MenuCue = enum(u16) { move = 0x502, cancel = 0x503, confirm = 0x504, warning = 0x505 };
pub const menu_theme_count = 5;
pub const menu_cue_count = 4;
pub const menu_sample_rate = 24_000;
pub const menu_sample_count = 4_320;

pub fn renderMenuCue(theme: usize, cue: MenuCue, samples: *[menu_sample_count]i16) void {
    const tones = [menu_theme_count]struct { frequency: f32, harmonic: f32, blend: f32 }{
        .{ .frequency = 392, .harmonic = 2, .blend = 0.08 },
        .{ .frequency = 523, .harmonic = 3, .blend = 0.30 },
        .{ .frequency = 330, .harmonic = 2, .blend = 0.38 },
        .{ .frequency = 466, .harmonic = 5, .blend = 0.27 },
        .{ .frequency = 587, .harmonic = 4, .blend = 0.20 },
    };
    const tone = tones[theme];
    const slope: f32 = switch (cue) {
        .move => 1.0,
        .cancel => 0.8,
        .confirm => 1.5,
        .warning => 0.65,
    };
    for (samples, 0..) |*sample, i| {
        const frame: f32 = @floatFromInt(i);
        const phase = 2 * std.math.pi * tone.frequency * slope * frame / menu_sample_rate;
        const attack = @min(frame / 96, 1);
        const fade = 1 - frame / (menu_sample_count - 1);
        const signal = @sin(phase) * (1 - tone.blend) + @sin(phase * tone.harmonic) * tone.blend;
        sample.* = @intFromFloat(signal * attack * fade * fade * 9_000);
    }
}

pub const SoundCue = struct {
    id: u16,
    path: []const u8,
    frames: u32,
    sha256: []const u8,
    bank: u8,
    program: u8,
    note: u8,
    retrigger: bool,
    restore_stream: bool = false,
    tone_index: ?u8 = null,
    occupied_updates: ?u16 = null,
    pitch_delta: u16 = 0,

    pub fn matches(self: SoundCue, bytes: []const u8) bool {
        if (bytes.len != 44 + @as(usize, self.frames) * 4 or
            !std.mem.eql(u8, bytes[0..4], "RIFF") or std.mem.readInt(u32, bytes[4..8], .little) != bytes.len - 8 or
            !std.mem.eql(u8, bytes[8..16], "WAVEfmt ") or
            std.mem.readInt(u32, bytes[16..20], .little) != 16 or
            std.mem.readInt(u16, bytes[20..22], .little) != 1 or
            std.mem.readInt(u16, bytes[22..24], .little) != 2 or
            std.mem.readInt(u32, bytes[24..28], .little) != 44100 or
            std.mem.readInt(u32, bytes[28..32], .little) != 44100 * 4 or
            std.mem.readInt(u16, bytes[32..34], .little) != 4 or
            std.mem.readInt(u16, bytes[34..36], .little) != 16 or
            !std.mem.eql(u8, bytes[36..40], "data") or
            std.mem.readInt(u32, bytes[40..44], .little) != self.frames * 4) return false;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        return std.mem.eql(u8, &std.fmt.bytesToHex(digest, .lower), self.sha256);
    }
};

pub const SoundContent = struct {
    pub const manifest_path = "audio/sfx/battle_sfx.json";
    pub const max_bytes = 256 * 1024;
    pub const dice_landing: u16 = 0x5a1;
    pub const window_open: u16 = 0x501;
    pub const stream_restore_cue: u16 = 0x52a;
    pub const dice_box_open = window_open;
    pub const dice_win = stream_restore_cue;

    schema: []const u8,
    sample_rate: u32,
    cues: []const SoundCue,

    pub fn cueIndex(self: SoundContent, id: u16) ?usize {
        for (self.cues, 0..) |cue, index| if (cue.id == id) return index;
        return null;
    }

    pub fn validate(self: SoundContent) !void {
        const founding = std.mem.eql(u8, self.schema, "suikoden-battle-sfx/5");
        const restoration = founding or std.mem.eql(u8, self.schema, "suikoden-battle-sfx/4");
        const mode_banks = restoration or std.mem.eql(u8, self.schema, "suikoden-battle-sfx/3");
        if ((!std.mem.eql(u8, self.schema, "suikoden-battle-sfx/1") and !std.mem.eql(u8, self.schema, "suikoden-battle-sfx/2") and !mode_banks) or self.sample_rate != 44100 or self.cues.len > 256) return error.InvalidBattleSounds;
        for (self.cues, 0..) |cue, index| {
            var path: [8]u8 = undefined;
            const expected = std.fmt.bufPrint(&path, "{x:0>4}.wav", .{cue.id}) catch unreachable;
            const timed = (std.mem.eql(u8, self.schema, "suikoden-battle-sfx/2") or mode_banks) and switch (cue.id) {
                0x813 => founding,
                0x819, 0x81b, 0x81e, 0x81f => true,
                else => false,
            };
            if (cue.pitch_delta != @as(u16, @intFromBool(founding and cue.id == 0x813))) return error.InvalidBattleSounds;
            if (timed) {
                if (cue.tone_index == null or cue.tone_index.? >= 16 or cue.occupied_updates == null or cue.occupied_updates.? == 0 or cue.occupied_updates.? > 600 or cue.frames != @as(u32, cue.occupied_updates.?) * 735 or cue.retrigger) return error.InvalidBattleSounds;
            } else if (cue.tone_index != null or cue.occupied_updates != null) return error.InvalidBattleSounds;
            const mode_bank = mode_banks and cue.id == dice_landing and cue.bank == 2;
            if ((cue.restore_stream and (!restoration or cue.id != dice_win)) or (cue.id == dice_win and !cue.restore_stream)) return error.InvalidBattleSounds;
            if ((!timed and (cue.id < 0x500 or cue.id > 0x5ff)) or (cue.bank != 0 and !mode_bank) or cue.program >= 128 or cue.note >= 128 or cue.frames == 0 or cue.frames > 441000 or !std.mem.eql(u8, cue.path, expected) or cue.sha256.len != 64) return error.InvalidBattleSounds;
            for (cue.sha256) |char| if (!(char >= '0' and char <= '9') and !(char >= 'a' and char <= 'f')) return error.InvalidBattleSounds;
            for (self.cues[0..index]) |previous| if (previous.id == cue.id) return error.InvalidBattleSounds;
        }
    }
};

pub const StreamRestore = struct {
    level: u8 = 0,
    target: u8,

    pub fn advance(self: *StreamRestore) void {
        if (self.level < self.target) self.level += 1;
    }
};

pub const TimedVoices = struct {
    remaining: [3]u16 = @splat(0),

    pub fn advance(self: *TimedVoices) void {
        for (&self.remaining) |*remaining| remaining.* -|= 1;
    }

    pub fn release(self: *TimedVoices, slot: usize) void {
        self.remaining[slot] = 0;
    }

    pub fn admit(self: *TimedVoices, updates: u16) ?usize {
        if (updates == 0) return null;
        for (&self.remaining, 0..) |*remaining, index| if (remaining.* == 0) {
            remaining.* = updates;
            return index;
        };
        return null;
    }
};

pub fn loadSounds(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(SoundContent) {
    if (bytes.len > SoundContent.max_bytes) return error.InvalidBattleSounds;
    const parsed = try std.json.parseFromSlice(SoundContent, allocator, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    errdefer parsed.deinit();
    try parsed.value.validate();
    return parsed;
}
pub const Scene = enum {
    title,
    field,
    battle,
    boss,
    victory,
    defeat,
    duel,
    war,
    ending,

    pub fn track(self: Scene, room_id: []const u8, has_battle: bool, has_defeat: bool) Track {
        return switch (self) {
            .title => .none,
            .field => trackForRoom(room_id),
            .battle => if (has_battle) .battle else trackForRoom(room_id),
            .boss, .duel, .war => if (has_battle) .boss else trackForRoom(room_id),
            .victory, .ending => if (has_battle) .victory else trackForRoom(room_id),
            .defeat => if (has_defeat) .defeat else trackForRoom(room_id),
        };
    }

    pub fn clearsSoundsFrom(self: Scene, previous: Scene) bool {
        if (self == previous) return false;
        return self != .victory or (previous != .battle and previous != .boss);
    }

    pub fn usesRegionTrack(self: Scene, selected: Track, field_music: ?Track) bool {
        if (selected != .none or self == .title) return false;
        // A script can explicitly mute the room by selecting .none.
        return self != .field or field_music == null;
    }
};

pub const ModeGain = struct {
    const full: u8 = 8;
    level: u8 = full,
    fading_out: bool = false,

    pub fn advance(self: *ModeGain, changing_track: bool) bool {
        self.fading_out = self.fading_out or changing_track;
        if (self.fading_out) {
            // Switch at the quietest audible step so the incoming track starts above zero.
            self.fading_out = self.level > 1;
            if (self.fading_out) self.level -= 1;
            return self.fading_out;
        }
        if (self.level < full) self.level += 1;
        return false;
    }

    pub fn scale(self: ModeGain, volume: f32) f32 {
        return volume * @as(f32, @floatFromInt(self.level)) / full;
    }
};

pub const RegionBgmTrack = struct {
    id: []const u8,
    path: []const u8,
    title: ?[]const u8 = null,
    sample_rate: u32,
    frames: u32,
    loop_start_frame: u32,
    volume: u8,

    pub fn loopSeconds(self: RegionBgmTrack) f32 {
        return @as(f32, @floatFromInt(self.loop_start_frame)) / @as(f32, @floatFromInt(self.sample_rate));
    }
};

pub const RegionBgmRoom = struct {
    room: []const u8,
    track: []const u8,
};

pub const RegionBgmContent = struct {
    pub const manifest_path = "audio/region_bgm.json";
    pub const max_bytes = 1024 * 1024;
    pub const jukebox_size = 16;

    schema: []const u8,
    tracks: []const RegionBgmTrack,
    rooms: []const RegionBgmRoom,
    jukebox: []const []const u8 = &.{},

    pub fn trackById(self: RegionBgmContent, id: []const u8) ?RegionBgmTrack {
        for (self.tracks) |track| if (std.mem.eql(u8, track.id, id)) return track;
        return null;
    }

    pub fn trackForRoom(self: RegionBgmContent, room_id: []const u8) ?RegionBgmTrack {
        for (self.rooms) |entry| {
            if (std.mem.eql(u8, entry.room, room_id)) return self.trackById(entry.track);
        }
        return null;
    }

    pub fn validate(self: RegionBgmContent) !void {
        if (!std.mem.eql(u8, self.schema, "suikoden-region-bgm/1") or self.tracks.len == 0) return error.InvalidRegionBgm;
        for (self.tracks, 0..) |track, index| {
            if (track.id.len == 0 or !std.mem.startsWith(u8, track.path, "bgm/") or
                std.mem.indexOf(u8, track.path, "..") != null or std.mem.indexOfScalar(u8, track.path, 0) != null or
                track.sample_rate < 8000 or track.sample_rate > 48000 or
                track.frames == 0 or track.frames > 48000 * 600 or track.loop_start_frame >= track.frames or track.volume > 127)
                return error.InvalidRegionBgm;
            if (track.title) |title| if (title.len == 0 or title.len > 64 or !std.unicode.utf8ValidateSlice(title)) return error.InvalidRegionBgm;
            for (self.tracks[0..index]) |prior| if (std.mem.eql(u8, prior.id, track.id)) return error.InvalidRegionBgm;
        }
        for (self.rooms, 0..) |entry, index| {
            if (entry.room.len == 0 or self.trackById(entry.track) == null) return error.InvalidRegionBgm;
            for (self.rooms[0..index]) |prior| if (std.mem.eql(u8, prior.room, entry.room)) return error.InvalidRegionBgm;
        }
        if (self.jukebox.len != 0 and self.jukebox.len != jukebox_size) return error.InvalidRegionBgm;
        for (self.jukebox, 0..) |id, index| {
            if (self.trackById(id) == null) return error.InvalidRegionBgm;
            for (self.jukebox[0..index]) |prior| if (std.mem.eql(u8, prior, id)) return error.InvalidRegionBgm;
        }
    }
};

pub fn loadRegionBgm(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(RegionBgmContent) {
    if (bytes.len > RegionBgmContent.max_bytes) return error.InvalidRegionBgm;
    const parsed = try std.json.parseFromSlice(RegionBgmContent, allocator, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    errdefer parsed.deinit();
    try parsed.value.validate();
    return parsed;
}

pub const JukeboxAction = union(enum) { unchanged, restore_room_music, play: RegionBgmTrack };

pub fn jukeboxAction(scene: Scene, catalogue: ?RegionBgmContent, active: ?[]const u8, requested: ?[]const u8) !JukeboxAction {
    if (scene != .field or requested == null) return if (active == null) .unchanged else .restore_room_music;
    if (active) |id| if (std.mem.eql(u8, id, requested.?)) return .unchanged;
    const content = catalogue orelse return error.MissingJukeboxPlaylist;
    for (content.jukebox) |id| {
        if (std.mem.eql(u8, id, requested.?)) return .{ .play = content.trackById(id) orelse return error.UnknownJukeboxTrack };
    }
    return error.UnknownJukeboxTrack;
}

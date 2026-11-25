//! raylib music and optional sound effects.
const std = @import("std");
const rl = @import("raylib");
const route = @import("audio_route");
const Track = route.Track;
const MenuTheme = @import("field").game_state.event_runtime.SoundTheme;
// shortcut: ordinary voices retain host allocation; qualify the shared SPU voice limit with the live mixer.
const ordinary_channels = 24;
const SoundChannel = struct { sound: rl.Sound, cue: usize };

pub const Player = struct {
    palace: ?rl.Music = null,
    audience: ?rl.Music = null,
    battle: ?rl.Music = null,
    boss: ?rl.Music = null,
    victory: ?rl.Music = null,
    defeat: ?rl.Music = null,
    area_b: ?rl.Music = null,
    dice: ?rl.Music = null,
    ruins: ?rl.Music = null,
    lakeshore: ?rl.Music = null,
    headquarters: ?rl.Music = null,
    founding: ?rl.Music = null,
    infiltration: ?rl.Music = null,
    mansion: ?rl.Music = null,
    wheel: ?rl.Music = null,
    restart_ticks: u32 = 0,
    field_content: ?std.json.Parsed(route.FieldContent) = null,
    field_stop_level: ?u8 = null,
    queued_stop_level: ?u8 = null,
    dice_content: ?std.json.Parsed(route.DiceContent) = null,
    field_music: ?Track = null,
    stream_restore: ?route.StreamRestore = null,
    defeat_content: ?std.json.Parsed(route.DefeatContent) = null,
    battle_content: ?std.json.Parsed(route.BattleContent) = null,
    sound_content: ?std.json.Parsed(route.SoundContent) = null,
    allocator: ?std.mem.Allocator = null,
    root_dir: ?[]u8 = null,
    region_bgm: ?route.RegionBgmContent = null,
    region_music: ?rl.Music = null,
    region_track: ?route.RegionBgmTrack = null,
    region_started: bool = false,
    jukebox_music: ?rl.Music = null,
    jukebox_track: ?route.RegionBgmTrack = null,
    paused_background: ?rl.Music = null,
    sounds: [256]?rl.Sound = @splat(null),
    menu_theme: MenuTheme = .standard,
    menu_sounds: [route.menu_theme_count][route.menu_cue_count]?rl.Sound = @splat(@splat(null)),
    channels: [ordinary_channels + 3]?SoundChannel = @splat(null),
    timed_voices: route.TimedVoices = .{},
    next_channel: usize = 0,
    current: Track = .none,
    scene: route.Scene = .title,
    mode_gain: route.ModeGain = .{},
    volume: f32 = 0.6,
    effects_volume: f32 = 0.8,
    ready: bool = false,

    pub fn init(init_context: std.process.Init, root: []const u8, region_bgm: ?route.RegionBgmContent) !Player {
        const allocator = init_context.gpa;
        rl.initAudioDevice();
        var self: Player = .{ .ready = rl.isAudioDeviceReady(), .region_bgm = region_bgm };
        errdefer self.deinit();
        if (!self.ready) return self;
        self.allocator = allocator;
        self.root_dir = try allocator.dupe(u8, root);
        const manifest_path = try std.fs.path.join(allocator, &.{ root, "audio/battle.json" });
        defer allocator.free(manifest_path);
        const bytes: ?[]u8 = std.Io.Dir.cwd().readFileAlloc(init_context.io, manifest_path, allocator, .limited(4096)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (bytes) |raw| {
            defer allocator.free(raw);
            self.battle_content = try route.loadBattle(allocator, raw);
            for (self.battle_content.?.value.tracks) |track| {
                const stream = try loadChecked(init_context, root, track);
                switch (track.id) {
                    .battle => self.battle = stream,
                    .boss => self.boss = stream,
                    .victory => self.victory = stream,
                    else => unreachable,
                }
            }
        }
        const dice_path = try std.fs.path.join(allocator, &.{ root, route.DiceContent.manifest_path });
        defer allocator.free(dice_path);
        const dice_bytes = std.Io.Dir.cwd().readFileAlloc(init_context.io, dice_path, allocator, .limited(4096)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (dice_bytes) |raw| {
            defer allocator.free(raw);
            self.dice_content = try route.loadDice(allocator, raw);
            for (self.dice_content.?.value.tracks) |track| {
                const stream = try loadChecked(init_context, root, track);
                if (track.id == .area_b) self.area_b = stream else self.dice = stream;
            }
        }
        const field_path = try std.fs.path.join(allocator, &.{ root, route.FieldContent.manifest_path });
        defer allocator.free(field_path);
        const field_bytes = std.Io.Dir.cwd().readFileAlloc(init_context.io, field_path, allocator, .limited(4096)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (field_bytes) |raw| {
            defer allocator.free(raw);
            self.field_content = try route.loadField(allocator, raw);
            for (self.field_content.?.value.tracks) |track| {
                if (track.id == .area_b and self.area_b != null) {
                    const other = self.dice_content.?.value.get(.area_b).?;
                    if (!std.mem.eql(u8, track.sha256, other.sha256) or track.volume != other.volume or track.loop_start_frame != other.loop_start_frame or track.sample_rate != other.sample_rate or track.frames != other.frames) return error.ConflictingFieldAudio;
                    continue;
                }
                const stream = try loadChecked(init_context, root, track);
                switch (track.id) {
                    .area_b => self.area_b = stream,
                    .ruins => self.ruins = stream,
                    .lakeshore => self.lakeshore = stream,
                    .headquarters => self.headquarters = stream,
                    .founding => self.founding = stream,
                    .infiltration => self.infiltration = stream,
                    .mansion => self.mansion = stream,
                    .wheel => self.wheel = stream,
                    else => unreachable,
                }
            }
        }
        const defeat_path = try std.fs.path.join(allocator, &.{ root, "audio/defeat.json" });
        defer allocator.free(defeat_path);
        const defeat_bytes: ?[]u8 = std.Io.Dir.cwd().readFileAlloc(init_context.io, defeat_path, allocator, .limited(4096)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (defeat_bytes) |raw| {
            defer allocator.free(raw);
            self.defeat_content = try route.loadDefeat(allocator, raw);
            self.defeat = try loadChecked(init_context, root, self.defeat_content.?.value.track());
        }
        const sound_manifest = try std.fs.path.join(allocator, &.{ root, route.SoundContent.manifest_path });
        defer allocator.free(sound_manifest);
        const sound_bytes: ?[]u8 = std.Io.Dir.cwd().readFileAlloc(init_context.io, sound_manifest, allocator, .limited(route.SoundContent.max_bytes)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (sound_bytes) |raw| {
            defer allocator.free(raw);
            self.sound_content = try route.loadSounds(allocator, raw);
            for (self.sound_content.?.value.cues, 0..) |cue, index| {
                const file = try std.fs.path.joinZ(allocator, &.{ root, "audio/sfx", cue.path });
                defer allocator.free(file);
                const wave_bytes = try std.Io.Dir.cwd().readFileAlloc(init_context.io, file, allocator, .limited(@as(usize, cue.frames) * 4 + 45));
                defer allocator.free(wave_bytes);
                if (!cue.matches(wave_bytes)) return error.BattleSoundResourceMismatch;
                self.sounds[index] = rl.loadSound(file) catch return error.BattleSoundUnavailable;
            }
        }
        self.palace = load(allocator, root, "audio/palace.wav");
        self.audience = load(allocator, root, "audio/audience.wav");
        return self;
    }

    fn loadChecked(init_context: std.process.Init, root: []const u8, track: route.StreamTrack) !rl.Music {
        const allocator = init_context.gpa;
        const file = try std.fs.path.join(allocator, &.{ root, "audio", track.path });
        defer allocator.free(file);
        const wave_bytes = try std.Io.Dir.cwd().readFileAlloc(init_context.io, file, allocator, .limited(@as(usize, track.frames) * 4 + 1024));
        defer allocator.free(wave_bytes);
        if (!track.matches(wave_bytes)) return error.BattleAudioResourceMismatch;
        const relative = try std.fs.path.join(allocator, &.{ "audio", track.path });
        defer allocator.free(relative);
        var stream = load(allocator, root, relative) orelse return error.BattleAudioStreamUnavailable;
        stream.looping = false;
        return stream;
    }

    fn load(allocator: std.mem.Allocator, root: []const u8, name: []const u8) ?rl.Music {
        const path = std.fs.path.join(allocator, &.{ root, name }) catch return null;
        defer allocator.free(path);
        const sentinel = allocator.dupeSentinel(u8, path, 0) catch return null;
        defer allocator.free(sentinel);
        return rl.loadMusicStream(sentinel) catch null;
    }

    fn music(self: Player) ?rl.Music {
        return switch (self.current) {
            .palace => self.palace,
            .audience => self.audience,
            .battle => self.battle,
            .boss => self.boss,
            .victory => self.victory,
            .defeat => self.defeat,
            .area_b => self.area_b,
            .dice => self.dice,
            .ruins => self.ruins,
            .lakeshore => self.lakeshore,
            .headquarters => self.headquarters,
            .founding => self.founding,
            .infiltration => self.infiltration,
            .mansion => self.mansion,
            .wheel => self.wheel,
            .none => null,
        };
    }

    fn regionVolume(self: Player, track: route.RegionBgmTrack) f32 {
        return self.volume * @as(f32, @floatFromInt(track.volume)) / 127;
    }

    fn stopRegionMusic(self: *Player) void {
        if (self.region_music) |stream| {
            if (rl.isMusicStreamPlaying(stream)) rl.stopMusicStream(stream);
        }
        self.region_started = false;
    }

    fn stopJukebox(self: *Player, resume_background: bool) void {
        if (self.jukebox_music) |stream| {
            rl.stopMusicStream(stream);
            rl.unloadMusicStream(stream);
        }
        self.jukebox_music = null;
        self.jukebox_track = null;
        if (resume_background) if (self.paused_background) |stream| {
            rl.resumeMusicStream(stream);
        };
        self.paused_background = null;
    }

    fn startJukebox(self: *Player, track: route.RegionBgmTrack) !void {
        const allocator = self.allocator.?;
        const path = try std.fs.path.join(allocator, &.{ "audio", track.path });
        defer allocator.free(path);
        var stream = load(allocator, self.root_dir.?, path) orelse return error.JukeboxTrackUnavailable;
        stream.looping = false;
        if (self.jukebox_music) |previous| {
            rl.stopMusicStream(previous);
            rl.unloadMusicStream(previous);
        } else if (self.music() orelse self.region_music) |background| {
            if (rl.isMusicStreamPlaying(background)) {
                rl.pauseMusicStream(background);
                self.paused_background = background;
            }
        }
        self.jukebox_music = stream;
        self.jukebox_track = track;
        rl.setMusicVolume(stream, self.regionVolume(track));
        rl.playMusicStream(stream);
    }

    pub fn update(self: *Player, room_id: []const u8, scene: route.Scene, jukebox: ?[]const u8) !void {
        if (!self.ready) {
            if (scene == .field and jukebox != null) return error.JukeboxTrackUnavailable;
            return;
        }
        const previous_scene = self.scene;
        if (scene.clearsSoundsFrom(previous_scene)) self.clearSounds();
        self.scene = scene;
        const active = if (self.jukebox_track) |track| track.id else null;
        switch (try route.jukeboxAction(scene, self.region_bgm, active, jukebox)) {
            .unchanged => {},
            .restore_room_music => self.stopJukebox(true),
            .play => |track| try self.startJukebox(track),
        }
        if (self.jukebox_music) |stream| {
            if (!rl.isMusicStreamPlaying(stream)) {
                rl.seekMusicStream(stream, self.jukebox_track.?.loopSeconds());
                rl.playMusicStream(stream);
            }
            rl.updateMusicStream(stream);
            return;
        }
        if (scene == .title) {
            self.field_music = null;
            self.field_stop_level = null;
            self.queued_stop_level = null;
            self.mode_gain = .{};
        }
        const routed = scene.track(room_id, self.battle_content != null, self.defeat_content != null);
        const wanted = if (scene == .field and routed == .none) self.field_music orelse routed else routed;
        const use_region = scene.usesRegionTrack(wanted, self.field_music);
        const want_region = if (use_region and self.region_bgm != null) self.region_bgm.?.trackForRoom(room_id) else null;
        const same_region = if (self.region_track) |current| if (want_region) |next| std.mem.eql(u8, current.id, next.id) else false else false;
        const level_before = self.mode_gain.level;
        const changing_track = scene != .title and scene.clearsSoundsFrom(previous_scene) and
            ((wanted != self.current and self.music() != null) or (self.region_started and !same_region));
        const hold_previous = self.mode_gain.advance(changing_track);
        if (level_before != self.mode_gain.level) self.setBackgroundVolume();
        if (hold_previous) {
            if (!self.pumpMusic() and self.region_started) self.pumpRegionMusic(self.region_track.?);
            return;
        }
        if (!use_region) self.stopRegionMusic();
        if (wanted != self.current) {
            self.stream_restore = null;
            self.field_stop_level = null;
            self.queued_stop_level = null;
            if (self.music()) |playing| rl.stopMusicStream(playing);
            self.current = wanted;
            self.restart_ticks = 0;
            if (self.music()) |next| {
                rl.setMusicVolume(next, self.currentVolume());
                rl.playMusicStream(next);
            }
        }
        if (!self.pumpMusic() and use_region) {
            if (want_region) |track| {
                if (!same_region) {
                    self.stopRegionMusic();
                    if (self.region_music) |old| {
                        rl.unloadMusicStream(old);
                        self.region_music = null;
                    }
                    self.region_track = track;
                    if (self.allocator) |alloc| if (self.root_dir) |dir| {
                        if (std.fmt.allocPrint(alloc, "audio/{s}", .{track.path})) |rel| {
                            defer alloc.free(rel);
                            if (load(alloc, dir, rel)) |loaded| {
                                var stream = loaded;
                                stream.looping = false;
                                self.region_music = stream;
                            }
                        } else |_| {}
                    };
                }
                self.pumpRegionMusic(track);
            } else {
                self.stopRegionMusic();
            }
        }
    }

    fn pumpMusic(self: *Player) bool {
        const playing = self.music() orelse return false;
        if (self.currentDefinition()) |track| {
            if (track.loops() and !rl.isMusicStreamPlaying(playing)) {
                rl.seekMusicStream(playing, track.loopSeconds());
                rl.playMusicStream(playing);
            }
        }
        rl.updateMusicStream(playing);
        return true;
    }

    fn pumpRegionMusic(self: *Player, track: route.RegionBgmTrack) void {
        const playing = self.region_music orelse return;
        if (!rl.isMusicStreamPlaying(playing)) {
            rl.seekMusicStream(playing, if (self.region_started) track.loopSeconds() else 0);
            rl.setMusicVolume(playing, self.mode_gain.scale(self.regionVolume(track)));
            rl.playMusicStream(playing);
            self.region_started = true;
        }
        rl.updateMusicStream(playing);
    }

    fn currentDefinition(self: Player) ?route.StreamTrack {
        if (self.field_content) |content| if (content.value.get(self.current)) |track| return track;
        if (self.current == .area_b or self.current == .dice) return if (self.dice_content) |content| content.value.get(self.current) else null;
        if (self.current == .defeat) return if (self.defeat_content) |content| content.value.track() else null;
        return if (self.battle_content) |content| content.value.get(self.current) else null;
    }

    fn currentVolume(self: Player) f32 {
        if (self.currentDefinition()) |track| {
            const level = self.field_stop_level orelse self.queued_stop_level orelse if (self.stream_restore) |restore| restore.level else track.volume;
            return self.mode_gain.scale(self.volume * @as(f32, @floatFromInt(level)) / 127);
        }
        return self.mode_gain.scale(self.volume);
    }

    pub fn requestDiceMusic(self: *Player, track: Track) !void {
        if (track != .area_b and track != .dice) return error.InvalidDiceAudio;
        if (self.ready and (self.dice_content == null or (if (track == .area_b) self.area_b == null else self.dice == null))) return error.DiceAudioUnavailable;
        // The source gate waits for resource loading, not for voices to finish.
        self.stream_restore = null;
        self.field_stop_level = null;
        self.queued_stop_level = null;
        self.field_music = track;
        if (self.ready) {
            const stream = if (track == .area_b) self.area_b.? else self.dice.?;
            if (self.current == track) rl.stopMusicStream(stream);
            rl.seekMusicStream(stream, 0);
            if (self.current == track) {
                rl.setMusicVolume(stream, self.currentVolume());
                rl.playMusicStream(stream);
            }
        }
    }

    pub fn pollFieldMusic(self: *Player, requested: Track) !bool {
        if (requested != .none and requested != .area_b and requested != .ruins and requested != .lakeshore and requested != .headquarters and requested != .founding and requested != .infiltration and requested != .mansion and requested != .wheel) return error.InvalidFieldAudio;
        if (!self.ready) return true;
        if (requested == .none) {
            if (self.music()) |playing| {
                if (self.field_stop_level == null) {
                    self.field_stop_level = self.queued_stop_level orelse if (self.stream_restore) |restore| restore.level else if (self.currentDefinition()) |track| track.volume else 127;
                    self.queued_stop_level = null;
                    self.stream_restore = null;
                }
                if (self.field_stop_level.? != 0) {
                    // shortcut: native audio polls stand in for the source blocking loader loop's cadence.
                    self.field_stop_level.? -|= 4;
                    rl.setMusicVolume(playing, self.currentVolume());
                    return false;
                }
                rl.stopMusicStream(playing);
            }
            self.field_stop_level = null;
            self.stream_restore = null;
            self.current = .none;
            self.field_music = .none;
            self.queued_stop_level = null;
            return true;
        }
        const stream = (switch (requested) {
            .area_b => self.area_b,
            .ruins => self.ruins,
            .lakeshore => self.lakeshore,
            .headquarters => self.headquarters,
            .founding => self.founding,
            .infiltration => self.infiltration,
            .mansion => self.mansion,
            .wheel => self.wheel,
            else => unreachable,
        }) orelse return error.FieldAudioUnavailable;
        if (requested == .founding and self.current != .founding and !try self.pollFieldMusic(.none)) return false;
        self.field_stop_level = null;
        self.queued_stop_level = null;
        self.stream_restore = null;
        self.field_music = requested;
        self.restart_ticks = 0;
        if (self.current == requested) rl.stopMusicStream(stream);
        rl.seekMusicStream(stream, 0);
        if (self.current == requested) {
            rl.setMusicVolume(stream, self.currentVolume());
            rl.playMusicStream(stream);
        }
        return true;
    }

    pub fn requestFieldFade(self: *Player) void {
        if (!self.ready) return;
        if (self.music() == null) {
            self.field_stop_level = null;
            self.queued_stop_level = null;
            self.stream_restore = null;
            self.field_music = .none;
            return;
        }
        self.queued_stop_level = self.field_stop_level orelse self.queued_stop_level orelse if (self.stream_restore) |restore| restore.level else if (self.currentDefinition()) |track| track.volume else 127;
        self.field_stop_level = null;
        self.stream_restore = null;
    }

    pub fn setVolume(self: *Player, volume: f32) void {
        self.volume = std.math.clamp(volume, 0, 1);
        self.setBackgroundVolume();
        if (self.jukebox_music) |playing| rl.setMusicVolume(playing, self.regionVolume(self.jukebox_track.?));
    }

    fn setBackgroundVolume(self: Player) void {
        if (self.music()) |playing| rl.setMusicVolume(playing, self.currentVolume());
        if (self.region_music) |playing| if (self.region_track) |track|
            rl.setMusicVolume(playing, self.mode_gain.scale(self.regionVolume(track)));
    }

    pub fn setEffectsVolume(self: *Player, volume: f32) void {
        self.effects_volume = std.math.clamp(volume, 0, 1);
        if (!self.ready) return;
        for (self.channels) |channel| if (channel) |playing| rl.setSoundVolume(playing.sound, self.effects_volume);
        for (self.menu_sounds) |sounds| for (sounds) |slot| if (slot) |sound| {
            rl.setSoundVolume(sound, self.effects_volume);
        };
    }

    fn stopChannel(self: *Player, slot: usize) void {
        const playing = self.channels[slot] orelse return;
        rl.stopSound(playing.sound);
        rl.unloadSoundAlias(playing.sound);
        self.channels[slot] = null;
        if (slot >= ordinary_channels) self.timed_voices.release(slot - ordinary_channels);
    }

    fn clearSounds(self: *Player) void {
        for (0..self.channels.len) |slot| self.stopChannel(slot);
        for (self.menu_sounds) |sounds| for (sounds) |slot| if (slot) |sound| {
            rl.stopSound(sound);
        };
        self.timed_voices = .{};
        self.next_channel = 0;
    }

    pub fn advanceSoundVoices(self: *Player) void {
        if (!self.ready or self.scene == .title or self.jukebox_music != null) return;
        if (self.currentDefinition()) |track| {
            // shortcut: native simulation ticks stand in for the original counter; qualify wall-clock/stall timing.
            if (track.advanceRestart(&self.restart_ticks)) if (self.music()) |playing| {
                rl.stopMusicStream(playing);
                rl.seekMusicStream(playing, 0);
                rl.playMusicStream(playing);
            };
        }
        if (self.queued_stop_level) |*level| {
            std.debug.assert(self.field_stop_level == null and level.* <= 127);
            // Source14 queues this fade and returns; source15 waits in its caller.
            if (level.* == 0) {
                if (self.music()) |playing| rl.stopMusicStream(playing);
                self.current = .none;
                self.field_music = .none;
                self.queued_stop_level = null;
            } else {
                level.* -|= 4;
                if (self.music()) |playing| rl.setMusicVolume(playing, self.currentVolume());
            }
        }
        if (self.sound_content == null) return;
        if (self.stream_restore) |*restore| {
            // shortcut: native steps stand in for original main-loop timing; qualify wall-clock/stall scheduling.
            restore.advance();
            if (self.music()) |playing| rl.setMusicVolume(playing, self.currentVolume());
            if (restore.level == restore.target) self.stream_restore = null;
        }
        self.timed_voices.advance();
        for (self.timed_voices.remaining, 0..) |remaining, index| if (remaining == 0) {
            self.stopChannel(ordinary_channels + index);
        };
    }

    fn playMenuCue(self: *Player, cue: route.MenuCue) void {
        const theme = @backingInt(self.menu_theme);
        const index = @backingInt(cue) - @backingInt(route.MenuCue.move);
        const cached = &self.menu_sounds[theme][index];
        if (cached.* == null) {
            var samples: [route.menu_sample_count]i16 = undefined;
            route.renderMenuCue(theme, cue, &samples);
            const sound = rl.loadSoundFromWave(.{ .frameCount = samples.len, .sampleRate = route.menu_sample_rate, .sampleSize = 16, .channels = 1, .data = &samples });
            if (!rl.isSoundValid(sound)) return;
            cached.* = sound;
        }
        const sound = cached.*.?;
        rl.stopSound(sound);
        rl.setSoundVolume(sound, self.effects_volume);
        rl.playSound(sound);
    }

    pub fn playSounds(self: *Player, events: anytype) void {
        if (!self.ready or self.scene == .title) return;
        for (events) |event| {
            if (std.enums.fromInt(route.MenuCue, event.id)) |cue| {
                self.playMenuCue(cue);
                continue;
            }
            const content = (self.sound_content orelse continue).value;
            const index = content.cueIndex(event.id) orelse continue;
            const cue = content.cues[index];
            if (cue.restore_stream) {
                if (self.currentDefinition()) |track| self.stream_restore = .{ .target = track.volume };
                if (self.music()) |playing| rl.setMusicVolume(playing, self.currentVolume());
            }
            const timed_slot = if (cue.occupied_updates) |updates| self.timed_voices.admit(updates) orelse continue else null;
            const sound = rl.loadSoundAlias(self.sounds[index].?);
            if (!rl.isSoundValid(sound)) {
                if (timed_slot) |timed| self.timed_voices.release(timed);
                continue;
            }
            if (cue.retrigger) for (self.channels, 0..) |channel, slot| if (channel) |playing| {
                const old = content.cues[playing.cue];
                if (old.bank == cue.bank and old.program == cue.program and old.note == cue.note) {
                    // shortcut: the source releases this voice; preserve release tails when live mixing is available.
                    self.stopChannel(slot);
                }
            };
            const slot = if (timed_slot) |timed| ordinary_channels + timed else for (self.channels[0..ordinary_channels], 0..) |channel, i| {
                if (channel == null or !rl.isSoundPlaying(channel.?.sound)) break i;
            } else self.next_channel;
            if (timed_slot == null) {
                self.stopChannel(slot);
                self.next_channel = (slot + 1) % ordinary_channels;
            }
            std.debug.assert(self.channels[slot] == null);
            self.channels[slot] = .{ .sound = sound, .cue = index };
            rl.setSoundVolume(sound, self.effects_volume);
            rl.playSound(sound);
        }
    }

    pub fn deinit(self: *Player) void {
        if (!self.ready) return;
        self.clearSounds();
        for (self.sounds) |sound| if (sound) |value| rl.unloadSound(value);
        for (self.menu_sounds) |sounds| for (sounds) |slot| if (slot) |sound| {
            rl.unloadSound(sound);
        };
        if (self.sound_content) |content| content.deinit();
        if (self.palace) |track| rl.unloadMusicStream(track);
        if (self.audience) |track| rl.unloadMusicStream(track);
        if (self.battle) |track| rl.unloadMusicStream(track);
        if (self.boss) |track| rl.unloadMusicStream(track);
        if (self.victory) |track| rl.unloadMusicStream(track);
        if (self.defeat) |track| rl.unloadMusicStream(track);
        if (self.area_b) |track| rl.unloadMusicStream(track);
        if (self.dice) |track| rl.unloadMusicStream(track);
        if (self.ruins) |track| rl.unloadMusicStream(track);
        if (self.lakeshore) |track| rl.unloadMusicStream(track);
        if (self.headquarters) |track| rl.unloadMusicStream(track);
        if (self.founding) |track| rl.unloadMusicStream(track);
        if (self.infiltration) |track| rl.unloadMusicStream(track);
        if (self.mansion) |track| rl.unloadMusicStream(track);
        if (self.wheel) |track| rl.unloadMusicStream(track);
        if (self.region_music) |track| rl.unloadMusicStream(track);
        self.stopJukebox(false);
        if (self.root_dir) |dir| if (self.allocator) |alloc| alloc.free(dir);
        if (self.field_content) |content| content.deinit();
        if (self.dice_content) |content| content.deinit();
        if (self.defeat_content) |content| content.deinit();
        if (self.battle_content) |content| content.deinit();
        rl.closeAudioDevice();
        self.* = .{};
    }
};

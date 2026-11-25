const std = @import("std");
const route = @import("audio_route");

test "jukebox routes selection changes and restores room music when playback ends" {
    const catalogue: route.RegionBgmContent = .{
        .schema = "suikoden-region-bgm/1",
        .tracks = &.{
            .{ .id = "first", .path = "bgm/first.wav", .sample_rate = 32000, .frames = 32000, .loop_start_frame = 0, .volume = 100 },
            .{ .id = "second", .path = "bgm/second.wav", .sample_rate = 32000, .frames = 32000, .loop_start_frame = 0, .volume = 100 },
        },
        .rooms = &.{},
        .jukebox = &.{ "first", "second" },
    };
    try std.testing.expectEqualStrings("first", (try route.jukeboxAction(.field, catalogue, null, "first")).play.id);
    try std.testing.expectEqual(.unchanged, try route.jukeboxAction(.field, catalogue, "first", "first"));
    try std.testing.expectEqualStrings("second", (try route.jukeboxAction(.field, catalogue, "first", "second")).play.id);
    try std.testing.expectEqual(.restore_room_music, try route.jukeboxAction(.field, catalogue, "second", null));
    try std.testing.expectEqual(.restore_room_music, try route.jukeboxAction(.battle, catalogue, "second", "second"));
    try std.testing.expectError(error.UnknownJukeboxTrack, route.jukeboxAction(.field, catalogue, null, "unknown"));
}

test "authored menu cues have distinct themes and fade to silence" {
    for (std.enums.values(route.MenuCue)) |cue| {
        var previous: [route.menu_sample_count]i16 = @splat(0);
        for (0..route.menu_theme_count) |theme| {
            var samples: [route.menu_sample_count]i16 = undefined;
            route.renderMenuCue(theme, cue, &samples);
            try std.testing.expectEqual(@as(i16, 0), samples[0]);
            try std.testing.expectEqual(@as(i16, 0), samples[samples.len - 1]);
            try std.testing.expect(!std.mem.eql(i16, &previous, &samples));
            for (samples) |sample| try std.testing.expect(@abs(sample) <= 9_000);
            previous = samples;
        }
    }
}

test "accepted opening music routes palace, first-town and world rooms" {
    try std.testing.expectEqual(route.Track.palace, route.trackForRoom("vaa_room_0"));
    try std.testing.expectEqual(route.Track.palace, route.trackForRoom("vaa_room_2"));
    try std.testing.expectEqual(route.Track.audience, route.trackForRoom("va1_room_0"));
    try std.testing.expectEqual(route.Track.audience, route.trackForRoom("va1_room_2"));
    try std.testing.expectEqual(route.Track.audience, route.trackForRoom("world_a"));
    try std.testing.expectEqual(route.Track.none, route.trackForRoom("vb6_forest_paths"));
}

test "battle cues replace room music and returning to field restores its route" {
    try std.testing.expectEqual(route.Track.battle, route.Scene.battle.track("vaa_room_2", true, false));
    try std.testing.expectEqual(route.Track.victory, route.Scene.victory.track("world_a", true, false));
    try std.testing.expectEqual(route.Track.boss, route.Scene.boss.track("world_a", true, false));
    try std.testing.expectEqual(route.Track.audience, route.Scene.field.track("world_a", true, true));
    try std.testing.expectEqual(route.Track.palace, route.Scene.battle.track("vaa_room_2", false, false));
}

test "region music fallback follows scene ownership and scripted silence" {
    const room = "vb6_forest_paths";
    try std.testing.expect(route.Scene.field.usesRegionTrack(route.Scene.field.track(room, true, true), null));
    try std.testing.expect(!route.Scene.field.usesRegionTrack(.none, route.Track.none));
    try std.testing.expect(!route.Scene.field.usesRegionTrack(.wheel, .wheel));
    for ([_]route.Scene{ .battle, .boss, .victory, .defeat, .duel, .war, .ending }) |scene| {
        try std.testing.expect(!scene.usesRegionTrack(scene.track(room, true, true), null));
        try std.testing.expect(scene.usesRegionTrack(scene.track(room, false, false), null));
    }
    try std.testing.expect(!route.Scene.title.usesRegionTrack(route.Scene.title.track(room, true, true), null));
}

test "duel, war and ending cues hand off to field or the next mode" {
    const room = "va1_room_2";
    for ([_]route.Scene{ .duel, .war }) |mode| {
        try std.testing.expectEqual(.boss, mode.track(room, true, true));
        try std.testing.expect(mode.clearsSoundsFrom(.field));
        try std.testing.expect(mode.clearsSoundsFrom(.boss));
        try std.testing.expect(route.Scene.field.clearsSoundsFrom(mode));
    }
    try std.testing.expectEqual(.victory, route.Scene.ending.track(room, true, true));
    try std.testing.expect(route.Scene.ending.clearsSoundsFrom(.field));
    try std.testing.expect(route.Scene.ending.clearsSoundsFrom(.war));
    try std.testing.expect(route.Scene.war.clearsSoundsFrom(.duel));
    try std.testing.expect(!route.Scene.duel.clearsSoundsFrom(.duel));
    try std.testing.expect(!route.Scene.victory.clearsSoundsFrom(.battle));
    try std.testing.expect(!route.Scene.victory.clearsSoundsFrom(.boss));
    try std.testing.expectEqual(.audience, route.Scene.field.track(room, true, true));
}

test "mode music handoff switches above zero and recovers to full gain" {
    var gain: route.ModeGain = .{};
    const room = "va1_room_2";
    var previous: route.Scene = .field;
    for ([_]route.Scene{ .battle, .field, .duel, .field, .war, .field, .ending }) |scene| {
        try std.testing.expect(scene.track(room, true, true) != previous.track(room, true, true));
        for (0..8) |tick| {
            try std.testing.expectEqual(tick != 7, gain.advance(tick == 0));
            try std.testing.expectEqual(@as(f32, @floatFromInt(@max(1, 7 - tick))) / 8, gain.scale(1));
        }
        for (2..9) |tick| {
            try std.testing.expect(!gain.advance(false));
            try std.testing.expectEqual(@as(f32, @floatFromInt(tick)) / 8, gain.scale(1));
        }
        previous = scene;
    }

    for (0..8) |tick| _ = gain.advance(tick == 0);
    try std.testing.expect(!gain.advance(false));
    try std.testing.expectEqual(@as(f32, 0.25), gain.scale(1));
    try std.testing.expect(gain.advance(true));
    try std.testing.expect(!gain.advance(false));
    try std.testing.expectEqual(@as(f32, 0.125), gain.scale(1));
}

test "battle audio manifest validates rates loop offsets identities and hashes" {
    const parsed = try route.loadBattle(std.testing.allocator, @embedFile("fixtures/battle_audio.json"));
    defer parsed.deinit();
    const battle = parsed.value.get(.battle).?;
    try std.testing.expectEqual(@as(u32, 43953), battle.sample_rate);
    try std.testing.expectEqual(@as(u32, 401408), battle.loop_start_frame);
    try std.testing.expectApproxEqAbs(@as(f32, 9.13266), battle.loopSeconds(), 0.0001);
    try std.testing.expect(!battle.matches("tampered audio"));
    var packet = parsed.value;
    var tracks = [_]route.BattleTrack{ battle, parsed.value.get(.boss).?, parsed.value.get(.victory).? };
    packet.tracks = &tracks;
    tracks[0].path = "../battle.wav";
    try std.testing.expectError(error.InvalidBattleAudio, packet.validate());
    tracks[0] = battle;
    tracks[0].loop_start_frame = tracks[0].frames;
    try std.testing.expectError(error.InvalidBattleAudio, packet.validate());
    tracks[0] = tracks[1];
    try std.testing.expectError(error.InvalidBattleAudio, packet.validate());
}

test "battle sound manifest checks paths identities and PCM content" {
    const json =
        \\{"schema":"suikoden-battle-sfx/1","sample_rate":44100,"status":"candidate",
        \\"cues":[{"id":1316,"path":"0524.wav","frames":1,"sha256":"0000000000000000000000000000000000000000000000000000000000000000","bank":0,"program":2,"note":28,"retrigger":true,"reverb":true}],"unsupported":[]}
    ;
    const parsed = try route.loadSounds(std.testing.allocator, json);
    defer parsed.deinit();
    var packet = parsed.value;
    var cues = [_]route.SoundCue{packet.cues[0]};
    packet.cues = &cues;
    try packet.validate();
    cues[0].path = "../x.wav";
    try std.testing.expectError(error.InvalidBattleSounds, packet.validate());
    cues[0] = parsed.value.cues[0];
    cues[0].frames = 0;
    try std.testing.expectError(error.InvalidBattleSounds, packet.validate());
    cues[0] = parsed.value.cues[0];
    var wave: [48]u8 = @splat(0);
    @memcpy(wave[0..4], "RIFF");
    std.mem.writeInt(u32, wave[4..8], 40, .little);
    @memcpy(wave[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, wave[16..20], 16, .little);
    std.mem.writeInt(u16, wave[20..22], 1, .little);
    std.mem.writeInt(u16, wave[22..24], 2, .little);
    std.mem.writeInt(u32, wave[24..28], 44100, .little);
    std.mem.writeInt(u32, wave[28..32], 44100 * 4, .little);
    std.mem.writeInt(u16, wave[32..34], 4, .little);
    std.mem.writeInt(u16, wave[34..36], 16, .little);
    @memcpy(wave[36..40], "data");
    std.mem.writeInt(u32, wave[40..44], 4, .little);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&wave, &digest, .{});
    const hash = std.fmt.bytesToHex(digest, .lower);
    cues[0].sha256 = &hash;
    try std.testing.expect(cues[0].matches(&wave));
    wave[47] = 1;
    try std.testing.expect(!cues[0].matches(&wave));
    packet.schema = "suikoden-battle-sfx/3";
    cues[0].id = route.SoundContent.dice_landing;
    cues[0].path = "05a1.wav";
    cues[0].bank = 2;
    try packet.validate();
    cues[0].bank = 1;
    try std.testing.expectError(error.InvalidBattleSounds, packet.validate());
    packet.schema = "suikoden-battle-sfx/4";
    cues[0].id = route.SoundContent.dice_win;
    cues[0].path = "052a.wav";
    cues[0].bank = 0;
    cues[0].restore_stream = true;
    try packet.validate();
    cues[0].restore_stream = false;
    try std.testing.expectError(error.InvalidBattleSounds, packet.validate());
    var restore: route.StreamRestore = .{ .target = 98 };
    restore.advance();
    try std.testing.expectEqual(@as(u8, 1), restore.level);
    for (0..100) |_| restore.advance();
    try std.testing.expectEqual(@as(u8, 98), restore.level);
}

test "defeat music uses its own optional stream and plays without looping" {
    try std.testing.expectEqual(route.Track.defeat, route.Scene.defeat.track("world_a", true, true));
    try std.testing.expectEqual(route.Track.defeat, route.Scene.defeat.track("world_a", false, true));
    try std.testing.expectEqual(route.Track.audience, route.Scene.defeat.track("world_a", true, false));
    const parsed = try route.loadDefeat(std.testing.allocator, @embedFile("fixtures/defeat_audio.json"));
    defer parsed.deinit();
    const content = parsed.value;
    try std.testing.expectEqual(@as(u32, 477792), content.frames);
    try std.testing.expectEqual(@as(u32, 37800), content.sample_rate);
    try std.testing.expectEqual(@as(u8, 80), content.volume);
    try std.testing.expect(!content.track().loops());
    try std.testing.expectEqual(@as(u32, 0), content.track().loop_start_frame);
    try std.testing.expect(!content.track().matches("changed PCM"));
    const legacy = try route.loadBattle(std.testing.allocator, @embedFile("fixtures/battle_audio.json"));
    defer legacy.deinit();
    for (legacy.value.tracks) |track| try std.testing.expect(track.loops());
    var invalid = content;
    invalid.repeat = true;
    try std.testing.expectError(error.InvalidBattleAudio, invalid.validate());
    invalid = content;
    invalid.id = .victory;
    try std.testing.expectError(error.InvalidBattleAudio, invalid.validate());
    invalid = content;
    invalid.path = "../defeat.wav";
    try std.testing.expectError(error.InvalidBattleAudio, invalid.validate());
    invalid = content;
    invalid.frames = 0;
    try std.testing.expectError(error.InvalidBattleAudio, invalid.validate());
}

test "timed sound voices use the first free of three slots and retain silent source lifetimes" {
    var voices = route.TimedVoices{};
    try std.testing.expectEqual(@as(?usize, 0), voices.admit(11));
    try std.testing.expectEqual(@as(?usize, 1), voices.admit(26));
    try std.testing.expectEqual(@as(?usize, 2), voices.admit(11));
    try std.testing.expectEqual(@as(?usize, null), voices.admit(26));
    for (0..10) |_| voices.advance();
    try std.testing.expectEqualDeep([3]u16{ 1, 16, 1 }, voices.remaining);
    try std.testing.expectEqual(@as(?usize, null), voices.admit(1));
    voices.advance();
    try std.testing.expectEqual(@as(?usize, 0), voices.admit(26));
    try std.testing.expectEqual(@as(?usize, 2), voices.admit(11));
    voices.release(1);
    try std.testing.expectEqual(@as(?usize, 1), voices.admit(11));
    try std.testing.expectEqualDeep([3]u16{ 26, 11, 11 }, voices.remaining);
    for (0..26) |_| voices.advance();
    try std.testing.expectEqualDeep([3]u16{ 0, 0, 0 }, voices.remaining);
    try std.testing.expectEqual(@as(?usize, null), voices.admit(0));
}

test "timed sound metadata keeps ordinary manifests compatible and rejects uncontrolled lifetimes" {
    const json =
        \\{"schema":"suikoden-battle-sfx/2","sample_rate":44100,"cues":[{"id":2073,"path":"0819.wav","frames":8085,"sha256":"0000000000000000000000000000000000000000000000000000000000000000","bank":0,"program":1,"tone_index":15,"note":60,"retrigger":false,"occupied_updates":11}]}
    ;
    const parsed = try route.loadSounds(std.testing.allocator, json);
    defer parsed.deinit();
    var content = parsed.value;
    var cues = [_]route.SoundCue{content.cues[0]};
    content.cues = &cues;
    content.schema = "suikoden-battle-sfx/3";
    try content.validate();
    content.schema = "suikoden-battle-sfx/1";
    try std.testing.expectError(error.InvalidBattleSounds, content.validate());
    content.schema = "suikoden-battle-sfx/2";
    cues[0].occupied_updates = 0;
    try std.testing.expectError(error.InvalidBattleSounds, content.validate());
    cues[0] = parsed.value.cues[0];
    cues[0].frames += 1;
    try std.testing.expectError(error.InvalidBattleSounds, content.validate());
    cues[0] = parsed.value.cues[0];
    cues[0].retrigger = true;
    try std.testing.expectError(error.InvalidBattleSounds, content.validate());
}

test "dice audio validates both stream roles and excludes them from battle manifests" {
    const parsed = try route.loadBattle(std.testing.allocator, @embedFile("fixtures/battle_audio.json"));
    defer parsed.deinit();
    var region = parsed.value.tracks[0];
    region.id = .area_b;
    region.path = "area_b.wav";
    var dice = region;
    dice.id = .dice;
    dice.path = "dice.wav";
    var packet: route.DiceContent = .{ .schema = "suikoden-dice-audio/1", .tracks = .{ region, dice } };
    try packet.validate();
    packet.tracks[1] = region;
    try std.testing.expectError(error.InvalidDiceAudio, packet.validate());
    var battle = parsed.value;
    const wrong_roles = [_]route.StreamTrack{ region, parsed.value.tracks[1], parsed.value.tracks[2] };
    battle.tracks = &wrong_roles;
    try std.testing.expectError(error.InvalidBattleAudio, battle.validate());
}

test "wheel field music requires audio6 and a complete unique stream set" {
    var tracks: [8]route.StreamTrack = undefined;
    const ids = [_]route.Track{ .area_b, .ruins, .lakeshore, .headquarters, .founding, .infiltration, .mansion, .wheel };
    const paths = [_][]const u8{ "area_b.wav", "ruins.wav", "lakeshore.wav", "headquarters.wav", "founding.wav", "infiltration.wav", "mansion.wav", "wheel.wav" };
    for (ids, paths, &tracks) |id, path, *track| {
        track.* = .{ .id = id, .path = path, .sample_rate = 44100, .frames = 100, .loop_start_frame = 0, .volume = 127, .sha256 = "0000000000000000000000000000000000000000000000000000000000000000" };
    }
    tracks[4].sample_rate = 37800;
    tracks[4].frames = 4632768;
    tracks[4].restart_after_ticks = 7249;
    var packet: route.FieldContent = .{ .schema = "suikoden-field-audio/6", .tracks = &tracks };
    try packet.validate();
    packet.schema = "suikoden-field-audio/5";
    try std.testing.expectError(error.InvalidFieldAudio, packet.validate());
    packet.schema = "suikoden-field-audio/6";
    tracks[7] = tracks[6];
    try std.testing.expectError(error.InvalidFieldAudio, packet.validate());
}

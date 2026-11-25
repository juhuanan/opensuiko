//! Unified field music mapping and per-tick BGM/SFX routing for the main loop.
const std = @import("std");
const field = @import("field");
const audio = @import("../audio.zig");
const audio_route = @import("audio_route");
const journey = @import("journey");

pub const DiceAudioEvents = struct {
    landings: u2 = 0,
    box_opened: bool = false,
    won: bool = false,
};

pub fn fieldMusicToTrack(music: field.game_state.event_runtime.FieldMusic) audio_route.Track {
    return switch (music) {
        .stop, .fade => .none,
        .ruins => .ruins,
        .lakeshore => .lakeshore,
        .headquarters => .headquarters,
        .founding => .founding,
        .infiltration => .infiltration,
        .mansion => .mansion,
        .wheel => .wheel,
        .area_b => .area_b,
    };
}

pub fn syncPendingFieldMusic(state: *journey.State, audio_player: *audio.Player) !void {
    const requested = state.pendingFieldMusic() orelse return;
    const target = fieldMusicToTrack(requested);
    if (requested == .fade) {
        audio_player.requestFieldFade();
        try state.completeFieldMusic(requested);
    } else {
        const duplicate = requested != .stop and state.field_state.music == requested;
        if (duplicate or try audio_player.pollFieldMusic(target)) try state.completeFieldMusic(requested);
    }
}

pub fn syncTickAudio(state: *journey.State, package: field.Package, audio_player: *audio.Player, dice: DiceAudioEvents) !void {
    if (state.dice_game == null and audio_player.field_stop_level == null and audio_player.queued_stop_level == null) {
        audio_player.field_music = if (state.field_state.music) |music| fieldMusicToTrack(music) else null;
    }
    const room_id = package.rooms[state.field_state.room].id;
    audio_player.update(room_id, state.audioScene(), state.menu.jukeboxTrack()) catch |err| {
        std.log.warn("Kasios music player: {s}", .{@errorName(err)});
        state.menu.jukebox_playing = null;
        state.menu.jukebox_failed = true;
        try audio_player.update(room_id, state.audioScene(), null);
    };
    audio_player.menu_theme = if (state.field_state.progress.story.scenario) |story| story.sound_theme else .standard;
    if (dice.won) audio_player.playSounds(&[_]struct { id: u16 }{.{ .id = audio_route.SoundContent.dice_win }});
    const field_sound = if (state.mode == .field) state.takeFieldSound() else null;
    const restores_stream = field_sound == audio_route.SoundContent.stream_restore_cue;
    if (restores_stream) audio_player.playSounds(&[_]struct { id: u16 }{.{ .id = field_sound.? }});
    audio_player.advanceSoundVoices();
    if (state.party_selection) |*active| {
        while (active.windows.takeOpenCue()) audio_player.playSounds(&[_]struct { id: u16 }{.{ .id = journey.party_selection.selector.layout.window_open_cue }});
    }
    if (dice.box_opened) audio_player.playSounds(&[_]struct { id: u16 }{.{ .id = audio_route.SoundContent.dice_box_open }});
    for (0..dice.landings) |_| audio_player.playSounds(&[_]struct { id: u16 }{.{ .id = audio_route.SoundContent.dice_landing }});
    const battle_sounds = state.combat.unite_vm.takeSounds();
    if (state.mode == .field) {
        if (!restores_stream) if (field_sound) |id| audio_player.playSounds(&[_]struct { id: u16 }{.{ .id = id }});
    } else if (state.mode == .battle or state.mode == .defeat) audio_player.playSounds(battle_sounds);
}

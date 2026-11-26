//! Top-level application coordinator for window lifetime, input, fixed-step update, and presentation.
const std = @import("std");
const settings_platform = @import("settings_platform.zig");
const rl = @import("raylib");
const raylib_app = @import("raylib_app");
const field = @import("field");
const pause = @import("pause_menu");
const persistence = @import("journey_persistence");
const boot = @import("journey_boot");
const journey = @import("journey");

const atlas_checks = @import("journey_frame/atlas_checks.zig");
const resources_mod = @import("journey_frame/resources.zig");
const audio_sync = @import("journey_frame/audio_sync.zig");
const clocks = @import("journey_clock");
const input_mod = @import("journey_frame/input.zig");
const render_mod = @import("journey_frame/render.zig");

pub const checkCrossingAtlas = atlas_checks.checkCrossingAtlas;
pub const checkFieldAtlas = atlas_checks.checkFieldAtlas;
pub const checkDiceAtlas = atlas_checks.checkDiceAtlas;
pub const checkDuelAtlas = atlas_checks.checkDuelAtlas;
pub const checkSceneryAtlases = atlas_checks.checkSceneryAtlases;
pub const checkBattleImages = atlas_checks.checkBattleImages;
pub const checkSpellAtlas = atlas_checks.checkSpellAtlas;
pub const checkBattlefieldAtlas = atlas_checks.checkBattlefieldAtlas;
pub const showStartupError = render_mod.showStartupError;

fn inspectTitleSaves(init: std.process.Init, save_path: ?[]const u8, state: *journey.State, title: *pause.title.State) void {
    if (save_path) |save| {
        persistence.apply(init, save, state, .inspect_saves) catch {
            title.message = "The save directory could not be read.";
            return;
        };
        title.ready(state.menu.summaries);
    }
}

pub const SimulationInput = journey.SimulationInput;

pub fn stepWithAudio(state: *journey.State, input: SimulationInput, audio_player: anytype) !journey.SimulationStep {
    var frame = input;
    frame.party = input.party orelse .{};
    if (state.preTickDiceMusic(frame.menu)) |request| {
        try audio_player.requestDiceMusic(audio_sync.diceMusicToTrack(request));
        frame.dice_music_ready = request;
    }
    const step = try state.advanceSimulation(frame);
    if (step.field_music) |request| {
        if (try audio_sync.pollFieldMusic(audio_player, request, state.field_state.music))
            try state.completeFieldMusic(request);
    }
    return step;
}

const App = struct {
    init_ctx: std.process.Init,
    boot_state: *boot.Boot,
    state: journey.State,
    resources: resources_mod.Resources,
    input: input_mod.InputState = .{},
    title: pause.title.State,
    simulation_clock: clocks.SimulationClock = .{},
    title_clock: clocks.FixedStepClock(pause.title.ticks_per_second) = .{},
    presentation: render_mod.Presentation = .{},

    fn init(init_ctx: std.process.Init, boot_state: *boot.Boot, initial_state: journey.State) !App {
        var app = App{
            .init_ctx = init_ctx,
            .boot_state = boot_state,
            .state = initial_state,
            .resources = try resources_mod.Resources.init(init_ctx, boot_state, &initial_state),
            .title = pause.title.State.bootWithMovies(),
        };
        app.title.opening_context = true;
        app.title.awaiting_start = true;
        _ = app.input.recovery.begin(.title);
        inspectTitleSaves(init_ctx, boot_state.save_path, &app.state, &app.title);
        return app;
    }

    fn deinit(self: *App) void {
        self.resources.deinit();
        self.state.releaseRestoredSave();
    }

    fn resetSession(self: *App, next: journey.State, clear_edges: bool) void {
        const preferences = self.state.menu.preferences;
        self.state.releaseRestoredSave();
        self.state = next;
        self.state.bind();
        self.state.menu.preferences = preferences;
        self.simulation_clock = .{};
        self.title_clock = .{};
        self.input.resetForGameplay(clear_edges);
    }

    fn stepTitle(self: *App, frame_input: input_mod.FrameInput, frame_seconds: f32) !bool {
        const safe = frame_input.safe;
        const effect = self.title.tick(.{
            .up = safe.navigation == .up,
            .down = safe.navigation == .down,
            .left = safe.navigation == .left,
            .right = safe.navigation == .right,
            .confirm = safe.confirm,
            .cancel = safe.cancel,
            .erase = self.title.phase == .hero_name and frame_input.erase_key,
            .text = frame_input.title_text,
        });
        self.input.typed_len = 0;
        switch (effect) {
            .quit => return false,
            .start_opening => self.resetSession(try self.boot_state.newStateNamed(self.title.heroName()), false),
            .start_episode => self.resetSession(try self.boot_state.newState(), false),
            .inspect => if (self.boot_state.save_path) |save| {
                persistence.apply(self.init_ctx, save, &self.state, .inspect_saves) catch {
                    self.title.message = "The save directory could not be read.";
                };
                self.title.summaries = self.state.menu.summaries;
            },
            .load => if (self.boot_state.save_path) |save| {
                self.state.menu.save_slot = self.title.slot;
                if (persistence.apply(self.init_ctx, save, &self.state, .load)) |_| {
                    self.title.phase = .playing;
                    self.simulation_clock = .{};
                    self.title_clock = .{};
                    self.input.resetForGameplay(false);
                } else |_| self.title.message = "Load failed. Choose another slot or return.";
            } else {
                self.title.message = "The save directory is unavailable.";
            },
            .none => {},
        }
        if (self.title.phase == .playing) {
            self.resources.movie_player.stop();
            self.resources.title_media.syncAudio(false, 0);
        } else {
            self.title_clock.addFrame(frame_seconds);
            while (self.title_clock.takeTick()) {
                _ = self.title.advanceFrame(.{});
            }
            const vol = self.state.menu.preferences.musicVolume();
            self.resources.movie_player.sync(self.title.phase == .movie, self.title.movie_stage, self.title.movie_tick, vol);
            self.resources.title_media.syncAudio(self.title.phase != .movie, vol);
        }
        return true;
    }

    fn applyMenuEffect(self: *App, effect: pause.Effect) !void {
        if (effect == .settings_changed) {
            settings_platform.save(self.init_ctx, self.boot_state.save_path, self.state.menu.preferences) catch {
                self.state.menu.notify("Settings could not be saved. Current choices apply until exit.");
            };
            self.resources.syncAudioVolumes(self.state.menu.preferences);
        } else if (effect == .new_game) {
            self.resetSession(try self.boot_state.newState(), true);
        } else if (effect != .none) {
            if (self.boot_state.save_path) |save| {
                persistence.apply(self.init_ctx, save, &self.state, effect) catch |err| {
                    std.log.warn("Journey {s}: {s}", .{ @tagName(effect), @errorName(err) });
                    self.state.menu.notify(switch (err) {
                        error.FileNotFound => "No journey save yet.",
                        error.MissingSharedItemCatalogue, error.SharedItemContentMismatch => "This slot needs its matching item catalogue.",
                        else => if (effect == .save) "Save failed. The previous save was kept." else "Load failed. Current progress was kept.",
                    });
                };
            } else self.state.menu.notify("The save directory is unavailable.");
        }
    }

    fn stepSimulationTick(self: *App, held_direction: ?field.Direction) !bool {
        const package = self.boot_state.bundle.package;
        const crossing_before = render_mod.crossingState(&self.state);
        const step = try stepWithAudio(&self.state, .{
            .menu = self.input.menu_input,
            .battle = self.input.battle_input,
            .dice = self.input.dice_input,
            .party = self.input.samplePartySelection(),
        }, &self.resources.audio_player);

        if (render_mod.crossingState(&self.state)) |current| {
            const view = self.resources.crossing_view orelse return error.MissingCrossingArt;
            const model = self.boot_state.bundle.crossing_art.?.*;
            if (crossing_before) |before| {
                switch (step.crossing) {
                    .none => {},
                    .scripted => try view.stepScripted(model, before, current),
                    .steered => |direction| try view.step(model, before, current, .{ .direction = direction }),
                }
            } else view.reload(model);
        }

        self.input.dice_input.pressed = .{};
        if (self.state.mode == .game_over) {
            self.title = .{ .opening_context = true };
            inspectTitleSaves(self.init_ctx, self.boot_state.save_path, &self.state, &self.title);
            try self.resources.audio_player.update(package.rooms[self.state.field_state.room].id, self.state.audioScene(), null);
            _ = self.input.recovery.begin(.title);
            self.simulation_clock = .{};
            self.title_clock = .{};
            self.input.clearStepEdges(null);
            return false;
        }

        try audio_sync.syncTickAudio(&self.state, package, &self.resources.audio_player, step.dice_audio, step.sounds);
        try self.applyMenuEffect(step.effect);
        self.input.clearStepEdges(held_direction);
        return true;
    }

    fn update(self: *App, frame_seconds: f32) !struct { running: bool, gameplay_ticks: u8 } {
        var gameplay_ticks: u8 = 0;
        const focused = rl.isWindowFocused();
        self.input.recovery.focus(focused);
        if (focused) {
            const frame_input = self.input.pollFocused(self.title.phase, &self.state, frame_seconds);
            if (self.title.phase != .playing) {
                if (!try self.stepTitle(frame_input, frame_seconds)) return .{ .running = false, .gameplay_ticks = gameplay_ticks };
            } else {
                self.input.accumulateGameplay(frame_input.safe);
                self.simulation_clock.addFrame(frame_seconds);
                // A session reset inside the update precedes the clock debit.
                while (self.simulation_clock.tickReady()) : (self.simulation_clock.finishTick()) {
                    gameplay_ticks += 1;
                    if (!try self.stepSimulationTick(frame_input.safe.direction)) break;
                }
            }
        } else {
            self.simulation_clock = .{};
            self.title_clock = .{};
            self.input.clearUnfocused();
        }
        return .{ .running = true, .gameplay_ticks = gameplay_ticks };
    }
};

pub fn run(init: std.process.Init, boot_state: *boot.Boot) !void {
    try atlas_checks.checkStartupAtlases(init.gpa, boot_state);
    var initial_state = boot_state.state;
    initial_state.menu.preferences = settings_platform.load(init, boot_state.save_path);
    try raylib_app.initWindow(.{
        .width = 1280,
        .height = 960,
        .title = "Suikoden",
        .min_width = 640,
        .min_height = 480,
        .resizable = true,
        .vsync = initial_state.menu.preferences.vsync,
    });
    defer rl.closeWindow();
    settings_platform.apply(initial_state.menu.preferences);
    var app = try App.init(init, boot_state, initial_state);
    defer app.deinit();
    app.state.bind();
    while (!rl.windowShouldClose()) {
        const step = try app.update(rl.getFrameTime());
        if (!step.running) break;
        try app.presentation.present(boot_state, &app.state, app.title, &app.resources, &app.input.recovery, step.gameplay_ticks, app.input.collision);
    }
}

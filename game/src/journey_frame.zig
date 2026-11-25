//! Top-level application coordinator for window lifetime, input, fixed-step update, and presentation.
const std = @import("std");
const settings_platform = @import("settings_platform.zig");
const rl = @import("raylib");
const raylib_app = @import("raylib_app");
const field = @import("field");
const pause = @import("pause_menu");
const persistence = @import("journey_persistence");
const boot = @import("journey_boot");
const ui = @import("ui");
const recovery_layer = @import("platform_recovery");
const journey = @import("journey");

const atlas_checks = @import("journey_frame/atlas_checks.zig");
const resources_mod = @import("journey_frame/resources.zig");
const audio_sync = @import("journey_frame/audio_sync.zig");
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

pub const SimulationInput = struct {
    menu: pause.Input = .{},
    battle: @import("battle").Input = .{},
    dice: journey.dice.Entry.Controls = .{},
    party: journey.party_selection.selector.Sampler.Sample = .{},
};

pub fn advanceSimulation(state: *journey.State, input: SimulationInput, audio_player: anytype) !struct { effect: pause.Effect, dice_audio: audio_sync.DiceAudioEvents } {
    var dice_events: audio_sync.DiceAudioEvents = .{};

    const owner = state.modalOwner(input.menu);
    if (owner == .pending_field_music) {
        try audio_sync.syncPendingFieldMusic(state, audio_player);
        return .{ .effect = .none, .dice_audio = .{} };
    }
    const effect: pause.Effect = if (owner == .dice_or_party_selection and state.dice_game != null and journey.dice.usesModel(state)) blk: {
        const active = state.dice_game.?;
        if (!active.entry_audio_ready) {
            try audio_player.requestDiceMusic(.dice);
            try journey.dice.tick(state, .entry_audio_ready);
        } else if (active.pending_exit and !active.exit_ready) {
            try audio_player.requestDiceMusic(.dice);
            try journey.dice.tick(state, .exit_ready);
        } else {
            if (active.pending_exit and active.exit_ready) try audio_player.requestDiceMusic(.area_b);
            try journey.dice.tickFrame(state, input.dice);
            if (active.animation != null) {
                const frame = state.dice_game.?.frame.?;
                for (frame.landed) |landed| dice_events.landings += @intFromBool(landed);
            }
        }
        if (state.dice_game) |next| {
            dice_events.box_opened = active.dialogue.phase == .allocate and next.dialogue.phase == .opening;
            if (active.result) |report| {
                const advanced = if (next.result) |result| result.cursor != report.cursor else true;
                const session = state.dice_host.?.session.?.dice;
                dice_events.won = report.hand_report and report.cursor == 0 and advanced and
                    session.phase == .proposal and session.decision.?.outcome == .win;
            }
        }
        state.elapsed_ticks +|= 1;
        break :blk .none;
    } else if (owner == .dice_or_party_selection and state.party_selection != null) blk: {
        try state.tickPartySelection(input.party.forPhase(state.party_selection.?.menu.phase));
        state.elapsed_ticks +|= 1;
        break :blk .none;
    } else try state.tickWithModalOwner(owner, input.menu, input.battle);
    return .{ .effect = effect, .dice_audio = dice_events };
}

const App = struct {
    init_ctx: std.process.Init,
    boot_state: *boot.Boot,
    state: journey.State,
    resources: resources_mod.Resources,
    input: input_mod.InputState = .{},
    title: pause.title.State,
    clock: f64 = 0,
    mode_fade: recovery_layer.display.ModeFade = .{},
    presented_mode: ?journey.Mode = null,

    fn init(init_ctx: std.process.Init, boot_state: *boot.Boot, initial_state: journey.State) !App {
        var resources = try resources_mod.Resources.init(init_ctx, boot_state, &initial_state);
        errdefer resources.deinit(init_ctx.gpa);

        var app = App{
            .init_ctx = init_ctx,
            .boot_state = boot_state,
            .state = initial_state,
            .resources = resources,
            .title = pause.title.State.bootWithMovies(),
        };
        app.title.opening_context = true;
        app.title.awaiting_start = true;
        _ = app.input.recovery.begin(.title);
        inspectTitleSaves(init_ctx, boot_state.save_path, &app.state, &app.title);
        return app;
    }

    fn deinit(self: *App) void {
        self.resources.deinit(self.init_ctx.gpa);
        self.state.releaseRestoredSave();
    }

    fn resetSession(self: *App, next: journey.State, clear_edges: bool) void {
        const preferences = self.state.menu.preferences;
        self.state.releaseRestoredSave();
        self.state = next;
        self.state.menu.preferences = preferences;
        self.clock = 0;
        self.input.resetForGameplay(clear_edges);
    }

    fn stepTitle(self: *App, frame_input: input_mod.FrameInput) !bool {
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
                    self.clock = 0;
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
            self.clock += @min(rl.getFrameTime(), 0.1);
            while (self.clock >= 1.0 / 60.0) : (self.clock -= 1.0 / 60.0) {
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
        const party_input = self.input.samplePartySelection();
        const crossing_before = render_mod.crossingState(&self.state);
        const boat_advances = self.state.menu.phase == .closed and (!self.input.menu_input.menu or self.state.field_state.remaining != 0);
        const simulation = try advanceSimulation(&self.state, .{
            .menu = self.input.menu_input,
            .battle = self.input.battle_input,
            .dice = self.input.dice_input,
            .party = party_input,
        }, &self.resources.audio_player);

        if (render_mod.crossingState(&self.state)) |current| {
            const view = self.resources.crossing_view orelse return error.MissingCrossingArt;
            const model = self.boot_state.bundle.crossing_art.?.*;
            if (crossing_before) |before| {
                if (current.scripted) try view.stepScripted(model, before, current) else if (boat_advances) try view.step(model, before, current, .{
                    .direction = if (self.input.menu_input.field.direction) |d| switch (d) {
                        .up => .north,
                        .right => .east,
                        .down => .south,
                        .left => .west,
                    } else null,
                });
            } else view.reload(model);
        }

        self.input.dice_input.pressed = .{};
        if (self.state.mode == .game_over) {
            self.title = .{ .opening_context = true };
            inspectTitleSaves(self.init_ctx, self.boot_state.save_path, &self.state, &self.title);
            try self.resources.audio_player.update(package.rooms[self.state.field_state.room].id, self.state.audioScene(), null);
            _ = self.input.recovery.begin(.title);
            self.clock = 0;
            self.input.clearStepEdges(null);
            return false;
        }

        try audio_sync.syncTickAudio(&self.state, package, &self.resources.audio_player, simulation.dice_audio);
        try self.applyMenuEffect(simulation.effect);
        self.input.clearStepEdges(held_direction);
        return true;
    }

    fn update(self: *App) !struct { running: bool, fade_updates: u8 } {
        var fade_updates: u8 = 0;
        const focused = rl.isWindowFocused();
        self.input.recovery.focus(focused);
        if (focused) {
            const frame_input = self.input.pollFocused(self.title.phase, &self.state);
            if (self.title.phase != .playing) {
                if (!try self.stepTitle(frame_input)) return .{ .running = false, .fade_updates = fade_updates };
            } else {
                self.input.accumulateGameplay(frame_input.safe);
                self.clock += @min(rl.getFrameTime(), 0.1);
                while (self.clock >= 1.0 / 60.0) : (self.clock -= 1.0 / 60.0) {
                    fade_updates += 1;
                    if (!try self.stepSimulationTick(frame_input.safe.direction)) break;
                }
            }
        } else {
            self.clock = 0;
            self.input.clearUnfocused();
        }
        return .{ .running = true, .fade_updates = fade_updates };
    }

    fn render(self: *App, fade_updates: u8) !void {
        self.state.bind();
        self.resources.ui_context.appearance = if (self.title.phase == .playing)
            (if (self.state.field_state.progress.story.scenario) |story| story.window_appearance else .{})
        else
            .{};
        ui.setWindowAppearance(self.resources.ui_context.appearance);
        try self.resources.syncPartyBackground(self.state.party_selection != null);
        const crossing = render_mod.crossingState(&self.state);
        try render_mod.prepareSubRenderers(self.init_ctx.gpa, self.boot_state, &self.state, self.title, &self.resources, crossing, self.input.collision);
        try render_mod.presentFrame(self.boot_state, &self.state, self.title, &self.resources, &self.input.recovery, &self.mode_fade, &self.presented_mode, fade_updates, crossing);
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
    while (!rl.windowShouldClose()) {
        const step = try app.update();
        if (!step.running) break;
        try app.render(step.fade_updates);
    }
}

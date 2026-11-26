//! GPU textures, canvases, shaders, audio/media players, and cached war renderer ownership.
const std = @import("std");
const rl = @import("raylib");
const raylib_app = @import("raylib_app");
const field = @import("field");
const audio = @import("../audio.zig");
const boot = @import("journey_boot");
const field_view = @import("../field_view.zig");
const battle_spell_view = @import("../battle_spell_view.zig");
const ui = @import("ui");
const Preferences = @import("pause_menu").Value;
const title_view = @import("../title_view.zig");
const movie_player_mod = @import("../movie_player.zig");
const journey = @import("journey");
const duel_presentation = @import("journey_content").duel_presentation;
const party_view = @import("../party_view.zig");
const world_view = @import("world_view");
const war_content = @import("war_content");
const war_view = @import("war_view");
const war_view_platform = @import("war_view_platform");
const war_manifest_data = @import("war_manifest_data");
const dialogue_presentation = journey.field_dialogue_view.presentation;

pub const WarRenderer = struct {
    canvas: rl.RenderTexture2D,
    platform: ?war_view_platform.Platform = null,
    manifest: ?std.json.Parsed(war_content.Manifest) = null,
    view_model: ?war_view.View = null,
    cached_scenario: [64]u8 = @splat(0),
    cached_len: usize = 0,

    pub fn init() !WarRenderer {
        return .{ .canvas = try raylib_app.loadPointCanvas(war_view.width, war_view.height) };
    }

    pub fn deinit(self: *WarRenderer) void {
        if (self.platform) |*platform| platform.deinit();
        if (self.manifest) |manifest| manifest.deinit();
        rl.unloadRenderTexture(self.canvas);
        self.* = undefined;
    }

    pub fn prepare(self: *WarRenderer, allocator: std.mem.Allocator, engine: *const journey.war.Engine, command_index: u8, context: *const ui.Context) !void {
        if (self.manifest == null) self.manifest = try war_content.load(allocator, war_manifest_data.json);
        if (self.platform == null) self.platform = try war_view_platform.Platform.init();
        const scenario_id = engine.scenario.id;
        if (self.view_model == null or !std.mem.eql(u8, self.cached_scenario[0..self.cached_len], scenario_id)) {
            self.view_model = try war_view.View.init(self.manifest.?.value, scenario_id);
            const copy_len = @min(scenario_id.len, self.cached_scenario.len);
            @memcpy(self.cached_scenario[0..copy_len], scenario_id[0..copy_len]);
            self.cached_len = copy_len;
        }
        rl.beginTextureMode(self.canvas);
        defer rl.endTextureMode();
        rl.clearBackground(.black);
        try self.platform.?.draw(&self.view_model.?, engine, command_index, "Confirm to continue", context);
    }
};

pub const Resources = struct {
    allocator: std.mem.Allocator,
    audio_player: audio.Player,
    movie_player: movie_player_mod.MoviePlayer,
    title_media: title_view.Media,
    atlas: rl.Texture2D,
    dice_atlas: ?rl.Texture2D = null,
    duel_atlas: ?rl.Texture2D = null,
    crossing_atlas: ?rl.Texture2D = null,
    crossing_view: ?*world_view.State = null,
    dice_portraits: ?rl.Texture2D = null,
    scenery_room: ?usize = null,
    scenery: ?rl.Texture2D = null,
    scripted_dialogue: ?*dialogue_presentation.List = null,
    actors: rl.Texture2D,
    dynamic_effect: battle_spell_view.DynamicTexture,
    effect_atlas: ?rl.Texture2D = null,
    floor: rl.Texture2D,
    battle_ground: ?rl.Texture2D = null,
    canvas: rl.RenderTexture2D,
    outgoing_canvas: rl.RenderTexture2D,
    field_canvas: rl.RenderTexture2D,
    war_renderer: WarRenderer,
    party_background: ?party_view.Background = null,
    wheel_shadow_shader: ?rl.Shader = null,
    field_effect_half_shader: ?rl.Shader = null,

    pub fn init(init_ctx: std.process.Init, boot_state: *boot.Boot, state: *const journey.State) !Resources {
        const allocator = init_ctx.gpa;
        const package = boot_state.bundle.package;
        const content = boot_state.bundle.combat;
        const path = boot_state.path;

        var audio_player = try audio.Player.init(init_ctx, path, boot_state.bundle.region_bgm);
        errdefer audio_player.deinit();
        audio_player.setVolume(state.menu.preferences.musicVolume());
        audio_player.setEffectsVolume(state.menu.preferences.effectsVolume());

        var movie_player = movie_player_mod.MoviePlayer.init(init_ctx.io, allocator, path, audio_player.ready);
        errdefer movie_player.deinit();

        var title_media = title_view.Media.init(allocator, path, audio_player.ready);
        errdefer title_media.deinit();

        const atlas = try raylib_app.loadPointTexture(allocator, path, "atlas.png");
        errdefer rl.unloadTexture(atlas);
        try package.validateAtlas(atlas.width, atlas.height);

        const dice_atlas = if (boot_state.bundle.dice_model != null)
            try raylib_app.loadPointTexture(allocator, path, journey.dice.visual.texture_path)
        else
            null;
        errdefer if (dice_atlas) |texture| rl.unloadTexture(texture);
        if (dice_atlas) |texture| try journey.dice.visual.validateAtlas(texture.width, texture.height);

        const duel_atlas = if (boot_state.bundle.duel_art != null)
            try raylib_app.loadPointTexture(allocator, path, duel_presentation.atlas_path)
        else
            null;
        errdefer if (duel_atlas) |texture| rl.unloadTexture(texture);

        const crossing_atlas = if (boot_state.bundle.crossing_art) |model|
            try raylib_app.loadPointTexture(allocator, path, model.atlas)
        else
            null;
        errdefer if (crossing_atlas) |texture| rl.unloadTexture(texture);

        const crossing_view = if (boot_state.bundle.crossing_art) |model| view: {
            const value = try allocator.create(world_view.State);
            // shortcut: first entry starts at phase10; bind the prior world clock before canonical admission.
            value.* = world_view.State.init(model.*);
            break :view value;
        } else null;
        errdefer if (crossing_view) |view| allocator.destroy(view);

        const dice_portraits = if (boot_state.bundle.dice_model != null)
            try raylib_app.loadPointTexture(allocator, path, journey.dice.visual.portrait_texture_path)
        else
            null;
        errdefer if (dice_portraits) |texture| rl.unloadTexture(texture);
        if (dice_portraits) |texture| try journey.dice.visual.validatePortraitAtlas(texture.width, texture.height);

        if (boot_state.bundle.ui) |*font| try font.validate(atlas.width, atlas.height);

        const scripted_dialogue = if (boot_state.bundle.room_battles != null and boot_state.bundle.ui != null)
            try allocator.create(dialogue_presentation.List)
        else
            null;
        errdefer if (scripted_dialogue) |list| allocator.destroy(list);

        const actors = try raylib_app.loadPointTexture(allocator, path, "battle/actors.png");
        errdefer rl.unloadTexture(actors);
        try content.validateAtlas(actors.width, actors.height);

        var dynamic_effect = try battle_spell_view.DynamicTexture.init();
        errdefer dynamic_effect.deinit();

        const effect_atlas: ?rl.Texture2D = if (state.combat.spell_scenes != null)
            try raylib_app.loadPointTexture(allocator, path, "battle/spell_effects.png")
        else
            null;
        errdefer if (effect_atlas) |image| rl.unloadTexture(image);
        if (state.combat.spell_scenes) |packet| try packet.validate(effect_atlas.?.width, effect_atlas.?.height);

        const floor = try raylib_app.loadPointTexture(allocator, path, "battle/floor.png");
        errdefer rl.unloadTexture(floor);

        const battle_ground: ?rl.Texture2D = raylib_app.loadPointTexture(allocator, path, "battle/ground.png") catch |err| blk: {
            if (content.battlefields.len != 0) return err;
            break :blk null;
        };
        errdefer if (battle_ground) |ground| rl.unloadTexture(ground);

        const canvas = try raylib_app.loadPointCanvas(640, 480);
        errdefer rl.unloadRenderTexture(canvas);

        const outgoing_canvas = try raylib_app.loadPointCanvas(canvas.texture.width, canvas.texture.height);
        errdefer rl.unloadRenderTexture(outgoing_canvas);

        const field_canvas = try raylib_app.loadPointCanvas(512, 432);
        errdefer rl.unloadRenderTexture(field_canvas);

        const war_renderer = try WarRenderer.init();

        return .{
            .allocator = allocator,
            .audio_player = audio_player,
            .movie_player = movie_player,
            .title_media = title_media,
            .atlas = atlas,
            .dice_atlas = dice_atlas,
            .duel_atlas = duel_atlas,
            .crossing_atlas = crossing_atlas,
            .crossing_view = crossing_view,
            .dice_portraits = dice_portraits,
            .scripted_dialogue = scripted_dialogue,
            .actors = actors,
            .dynamic_effect = dynamic_effect,
            .effect_atlas = effect_atlas,
            .floor = floor,
            .battle_ground = battle_ground,
            .canvas = canvas,
            .outgoing_canvas = outgoing_canvas,
            .field_canvas = field_canvas,
            .war_renderer = war_renderer,
        };
    }

    pub fn deinit(self: *Resources) void {
        if (self.field_effect_half_shader) |shader| rl.unloadShader(shader);
        if (self.wheel_shadow_shader) |shader| rl.unloadShader(shader);
        if (self.party_background) |background| background.deinit();
        self.war_renderer.deinit();
        rl.unloadRenderTexture(self.field_canvas);
        rl.unloadRenderTexture(self.outgoing_canvas);
        rl.unloadRenderTexture(self.canvas);
        if (self.battle_ground) |ground| rl.unloadTexture(ground);
        rl.unloadTexture(self.floor);
        if (self.effect_atlas) |image| rl.unloadTexture(image);
        self.dynamic_effect.deinit();
        rl.unloadTexture(self.actors);
        if (self.scripted_dialogue) |list| self.allocator.destroy(list);
        if (self.scenery) |texture| rl.unloadTexture(texture);
        if (self.dice_portraits) |texture| rl.unloadTexture(texture);
        if (self.crossing_view) |view| self.allocator.destroy(view);
        if (self.crossing_atlas) |texture| rl.unloadTexture(texture);
        if (self.duel_atlas) |texture| rl.unloadTexture(texture);
        if (self.dice_atlas) |texture| rl.unloadTexture(texture);
        rl.unloadTexture(self.atlas);
        self.title_media.deinit();
        self.movie_player.deinit();
        self.audio_player.deinit();
        self.* = undefined;
    }

    pub fn syncAudioVolumes(self: *Resources, preferences: Preferences) void {
        self.audio_player.setVolume(preferences.musicVolume());
        self.audio_player.setEffectsVolume(preferences.effectsVolume());
    }

    pub fn syncPartyBackground(self: *Resources, active: bool) !void {
        if (active) {
            if (self.party_background == null) self.party_background = try party_view.Background.capture(self.canvas.texture);
        } else if (self.party_background) |background| {
            background.deinit();
            self.party_background = null;
        }
    }

    pub fn ensureRoomScenery(self: *Resources, path: []const u8, room_index: usize, room: field.Room) !void {
        if (self.scenery_room == room_index) return;
        const replacement = if (room.scenery_atlas) |image_path| load: {
            const texture = try raylib_app.loadPointTexture(self.allocator, path, image_path);
            errdefer rl.unloadTexture(texture);
            try room.validateSceneryAtlas(texture.width, texture.height);
            break :load texture;
        } else null;
        raylib_app.replaceTexture(&self.scenery, replacement);
        self.scenery_room = room_index;
    }

    pub fn ensureFieldEffectShader(self: *Resources, active: journey.ActiveFieldEvent) !void {
        if (active.session.field_effect) |effect| {
            if (active.binding.field_effect_blend != .half) return error.UnqualifiedFieldEffectBlend;
            if (effect.model.ray(0)) |ray| if (ray.semitransparent and self.field_effect_half_shader == null) {
                const shader = try rl.loadShaderFromMemory(null, field_view.effect_half_fragment);
                if (shader.id == rl.gl.rlGetShaderIdDefault()) return error.FieldEffectShaderUnavailable;
                self.field_effect_half_shader = shader;
            };
        }
    }

    pub fn ensureWheelShadowShader(self: *Resources, room_actors: []const journey.RoomActorDraw) !void {
        if (self.wheel_shadow_shader != null) return;
        for (room_actors) |actor| {
            if (actor.shadow == null) continue;
            const shader = try rl.loadShaderFromMemory(null, field_view.shadow_fragment);
            if (shader.id == rl.gl.rlGetShaderIdDefault()) return error.WheelShadowShaderUnavailable;
            const shade: f32 = @floatFromInt(field.wheel.shadow_shade);
            rl.setShaderValue(shader, rl.getShaderLocation(shader, "shade8"), &shade, .float);
            self.wheel_shadow_shader = shader;
            break;
        }
    }
};

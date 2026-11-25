//! Integrated host for combat presentation, control and cue seams.
//!
//! One `Host` parses the combat-systems assets once per session, so every mode
//! shares the reviewed content identity instead of reloading it per action.
//! The host owns no rule effect, no draw queue and no save format: it hands
//! each module's typed value to the production owner that already owns the
//! behaviour, and records the per-subsystem integration state below.
//!
//! The module imports only the combat-systems modules, never `battle`, `world`,
//! the save owner or raylib, so the shared owners can import this host (or a
//! subsystem directly) without a cycle.
//!
//! Integration state:
//!
//! | subsystem | seam | production owner state |
//! |---|---|---|
//! | poses    | pose/family catalogue and per-actor session | module-only: shared `battle.Profile` has no area-scoped enemy id, and the existing per-encounter B/C tracks stay the reviewed source (a name/slot match is forbidden) |
//! | effects  | effect composer at the coordinator clock | integrated: `battle.State.presentation` + `battle_trial_view` |
//! | camera   | shared camera state and snapshot | host-level: the battle owner carries a projected `presentation.Camera`, not the source 12-word block, so it cannot be installed without a new export |
//! | dialogue | dialogue engine and scene host | host-level: the reviewed `opening_audience` token assets are not the corrected source bodies |
//! | menu     | menu model, window and refusal | integrated: `party_session` window/clip and `battle_menu` refusal |
//! | audio    | logical audio host over the platform port | integrated: field audio request path |
//! | streams  | three proven stream lifecycles | host-level: the scene -> stream mapping is a blocked row |

const std = @import("std");

const poses_mod = @import("poses/root.zig");
const effects_mod = @import("effects/root.zig");
const camera_mod = @import("camera/root.zig");
const dialogue_mod = @import("dialogue/root.zig");
const menu_mod = @import("menu/root.zig");
const audio_mod = @import("audio/root.zig");
const streams_mod = @import("streams.zig");

pub const schema = "suikoden-combat-systems-integration/1";

pub const State = enum {
    /// The package value reaches a shared production owner in this commit.
    integrated,
    /// The package value is bound at the host; the shared owner
    /// named in `owner` still needs its own change.
    host_level,
    /// The package is exercised by its own gate only; `blocker` is the exact
    /// missing input.
    module_only,
};

pub const Pack = struct {
    id: []const u8,
    package: []const u8,
    state: State,
    owner: []const u8,
    blocker: ?[]const u8 = null,
};

pub const packs = [_]Pack{
    .{ .id = "poses", .package = "game/src/combat_systems/poses/root.zig", .state = .module_only, .owner = "battle_world_art.Data.actors", .blocker = "area_scoped_enemy_identity_absent_from_shared_profile" },
    .{ .id = "effects", .package = "game/src/combat_systems/effects/root.zig", .state = .integrated, .owner = "battle.State.presentation + battle_trial_view" },
    .{ .id = "camera", .package = "game/src/combat_systems/camera/root.zig", .state = .host_level, .owner = "battle_presentation.Camera", .blocker = "source_camera_block_not_in_battle_content" },
    .{ .id = "dialogue", .package = "game/src/combat_systems/dialogue/root.zig", .state = .host_level, .owner = "opening_audience.TextState", .blocker = "reviewed_audience_tokens_are_not_corrected_source_bodies" },
    .{ .id = "menu", .package = "game/src/combat_systems/menu/root.zig", .state = .integrated, .owner = "party_session/view + battle_menu" },
    .{ .id = "audio", .package = "game/src/combat_systems/audio/root.zig", .state = .integrated, .owner = "field audio request" },
    .{ .id = "streams", .package = "game/src/combat_systems/streams.zig", .state = .host_level, .owner = "frontend scene loop", .blocker = "stream_caller_mapping" },
};

/// One scene-sink receipt.  The host never invents a true acknowledgement: a
/// pending modelled request leaves `receipts` at zero.
pub const AudioSink = struct {
    receipts: u32 = 0,
    last_batch: u64 = 0,
    last_origin: u16 = 0,

    fn acknowledge(context: *anyopaque, batch: u64, origin: u16) anyerror!void {
        const self: *AudioSink = @ptrCast(@alignCast(context));
        self.receipts += 1;
        self.last_batch = batch;
        self.last_origin = origin;
    }

    pub fn sink(self: *AudioSink) audio_mod.SceneSink {
        return .{ .context = self, .acknowledge_fn = acknowledge };
    }
};

pub const Host = struct {
    allocator: std.mem.Allocator,
    poses: poses_mod.Catalogue,
    effects: std.json.Parsed(effects_mod.Packet),
    camera: std.json.Parsed(camera_mod.Packet),
    dialogue: std.json.Parsed(dialogue_mod.model.Pipeline),
    menus: menu_mod.vocabulary.Opened,
    audio_content: audio_mod.plan.Asset,
    streams: streams_mod.Opened,
    audio_trace: audio_mod.trace.Trace = .{},
    audio_sink: AudioSink = .{},

    pub fn init(allocator: std.mem.Allocator) !*Host {
        const self = try allocator.create(Host);
        errdefer allocator.destroy(self);
        self.allocator = allocator;
        self.audio_trace = .{};
        self.audio_sink = .{};
        self.poses = try poses_mod.Catalogue.load(allocator, @import("combat_systems_data").pose_families.json);
        errdefer self.poses.deinit();
        self.effects = try effects_mod.loadAsset(allocator);
        errdefer self.effects.deinit();
        self.camera = try camera_mod.load(allocator);
        errdefer self.camera.deinit();
        self.dialogue = try dialogue_mod.load(allocator);
        errdefer self.dialogue.deinit();
        self.menus = try menu_mod.vocabulary.load(allocator, menu_mod.json);
        errdefer self.menus.deinit();
        self.audio_content = try audio_mod.plan.open(allocator, @import("combat_systems_data").audio_integration.json);
        errdefer self.audio_content.deinit();
        self.streams = try streams_mod.open(allocator, @import("combat_systems_data").streams.json);
        errdefer self.streams.deinit();
        return self;
    }

    pub fn deinit(self: *Host) void {
        self.streams.deinit();
        self.audio_content.deinit();
        self.menus.deinit();
        self.dialogue.deinit();
        self.camera.deinit();
        self.effects.deinit();
        self.poses.deinit();
        self.allocator.destroy(self);
    }

    // -- Poses: actor pose/family sessions ------------------------------------

    /// Admit one family for one actor.  A blocked binding is
    /// `error.UnsupportedFamily`; `poseReason` carries the source reason.
    pub fn beginPose(self: *const Host, actor_id: []const u8, family: poses_mod.Family) !poses_mod.Session {
        return poses_mod.Session.begin(&self.poses, actor_id, family);
    }

    pub fn poseReason(self: *const Host, actor_id: []const u8, family: poses_mod.Family) ?[]const u8 {
        const binding = self.poses.bindingFor(actor_id, family) orelse return "unknown_binding";
        return binding.reason;
    }

    pub fn poseContentSha(self: *const Host) []const u8 {
        return self.poses.contentSha();
    }

    // -- Effects: effect composition -------------------------------------------

    pub fn beginCast(self: *const Host, spell_id: []const u8, contact: u16, finish: u16) !effects_mod.Composer {
        return effects_mod.beginCast(&self.effects.value, spell_id, contact, finish);
    }

    pub fn beginAttack(self: *const Host, attack_id: []const u8, contact: u16, finish: u16, resource_ready: bool) !effects_mod.Composer {
        return effects_mod.beginAttack(&self.effects.value, attack_id, contact, finish, resource_ready);
    }

    pub fn effectPacket(self: *const Host) *const effects_mod.Packet {
        return &self.effects.value;
    }

    // -- Camera: shared camera -------------------------------------------------

    pub fn fieldCamera(self: *const Host, focus_cell: camera_mod.Vec2, offset_px: camera_mod.Vec2, section_cells: camera_mod.Vec2) !camera_mod.State {
        return camera_mod.initField(&self.camera.value, focus_cell, offset_px, section_cells);
    }

    pub fn battleCamera(self: *const Host, preset_id: []const u8) !camera_mod.State {
        return camera_mod.initBattle(&self.camera.value, preset_id);
    }

    /// Project one world position through the *one* camera state the caller
    /// owns.  An unknown projection is the package's typed refusal.
    pub fn project(self: *const Host, state: *const camera_mod.State, world_q12: camera_mod.Vec3) !camera_mod.ScreenPoint {
        _ = self;
        return camera_mod.project(state, world_q12);
    }

    pub fn restoreCamera(self: *const Host, snapshot: camera_mod.Snapshot) !camera_mod.State {
        return camera_mod.restore(&self.camera.value, snapshot);
    }

    // -- Dialogue: dialogue ------------------------------------------------------

    pub fn dialogueSceneCount(self: *const Host) usize {
        return self.dialogue.value.scenes.len;
    }

    pub fn beginDialogue(self: *const Host, scene_index: u8) !dialogue_mod.host.Host {
        var sha: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(dialogue_mod.asset.json, &sha, .{});
        return dialogue_mod.host.Host.init(&self.dialogue.value, scene_index, sha);
    }

    // -- Menus: menus ---------------------------------------------------------

    pub fn battleCommandRows(self: *const Host, enabled: []const bool, out: []menu_mod.model.Row) ![]menu_mod.model.Row {
        return menu_mod.adapter.serviceRows(self.menus.packet(), "battle_commands", enabled, out);
    }

    pub fn menuPacket(self: *const Host) *const menu_mod.vocabulary.Packet {
        return self.menus.packet();
    }

    // -- Audio: logical audio ------------------------------------------------

    /// The audio request planner is candidate-only in this campaign, so the host
    /// binds `audio_mod.Unbound`: every modelled request stays pending and the scene
    /// is never acknowledged by a substitute.  A no-device port is a waiver,
    /// not a world stop.
    pub fn audioHost(self: *Host, port: audio_mod.Port) audio_mod.Host(audio_mod.Unbound) {
        return audio_mod.Host(audio_mod.Unbound).init(self.audio_content.content(), audio_mod.Unbound{}, port, &self.audio_trace, self.audio_sink.sink());
    }

    // -- Streams: streams ------------------------------------------------------

    pub fn beginStream(self: *const Host, stream_id: []const u8, caller_id: []const u8, token: u32) !streams_mod.Session {
        return streams_mod.Session.begin(self.streams.asset(), stream_id, caller_id, token);
    }

    pub fn streamCount(self: *const Host) usize {
        return self.streams.asset().streams.len;
    }

    pub fn streamBlocker(self: *const Host, id: []const u8) ?[]const u8 {
        for (self.streams.asset().blocked) |row| {
            if (std.mem.eql(u8, row.id, id)) return row.reason;
        }
        return null;
    }
};

/// A capture of every mode seam the host hands out.  `fresh` restores it into a
/// newly parsed host; a swapped content identity or a tampered capture is a
/// typed refusal instead of a silent reset.
pub const Snapshot = struct {
    version: u16 = 1,
    pose: ?poses_mod.Capture = null,
    effect: ?effects_mod.Snapshot = null,
    camera: ?camera_mod.Snapshot = null,
    dialogue: ?dialogue_mod.host.Host.Snapshot = null,
    menu: ?menu_mod.model.Snapshot = null,
};

pub const SnapshotError = error{ StaleCapture, InvalidCapture };

pub fn restorePose(host: *const Host, capture: poses_mod.Capture) !poses_mod.Session {
    return poses_mod.Session.restore(&host.poses, capture) catch |err| switch (err) {
        error.StaleCapture => return error.StaleCapture,
        error.InvalidCapture => return error.InvalidCapture,
        else => return err,
    };
}

pub fn restoreEffect(host: *const Host, snapshot: effects_mod.Snapshot) !effects_mod.Composer {
    return effects_mod.Composer.restore(&host.effects.value, snapshot);
}

pub fn restoreDialogue(host: *const Host, snapshot: dialogue_mod.host.Host.Snapshot) !dialogue_mod.host.Host {
    var dialog = try host.beginDialogue(snapshot.scene_index);
    try dialog.restore(&host.dialogue.value, snapshot);
    return dialog;
}

/// Restore the saved screen state, then rebuild the rows the owner derived from
/// the restored session.  `menu_mod.model.Menu.restore` deliberately drops row
/// pointers; reopening re-finds the remembered id, so a restored menu never acts
/// on an index-0 row.
pub fn restoreMenu(host: *const Host, menu: *menu_mod.model.Menu, rows: []const menu_mod.model.Row, options: menu_mod.model.Options, snapshot: menu_mod.model.Snapshot) void {
    _ = host;
    menu.restore(snapshot);
    menu.open(snapshot.active, rows, options);
}

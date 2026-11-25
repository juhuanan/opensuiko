//! Integrated headquarters / roster / service / tablet host.
//!
//! One `Host` owns the headquarters state that the lower layers do not:
//! the 108 source recruit bytes, the castle stage produced by
//! the recount/promote pair (`story.recruitment_tier`), the
//! roster sidecar, the service screen, the tablet view and the optional-game
//! frame seam.
//!
//! The canonical owners are *not* duplicated here:
//!
//!   * money, item bags, storage and the story scenario stay in the live
//!     `field.State` the caller passes in (the same owner the world session
//!     saves), so a service transaction mutates the real bags;
//!   * the party identity/HP/level/gear facts stay in the HQ roster, which
//!     wraps the canonical `party.Snapshot`;
//!   * the optional-game settlement is published through the shared
//!     mode-result transaction, never through a second stored host.
//!
//! Only the facts that had no owner before are new durable state: the recruit
//! bytes, the roster sidecar, the tablet cursor and the optional-game
//! projection.  `Snapshot` is the bounded sidecar the world-session save writes.
//!
//! Construction facts (a room's actors, a caller's stock) and current-story
//! facts (a recruit window, a story mask) have different lifetimes: the host
//! rebuilds the first from the second on every state change instead of caching
//! an actor list across a recruit.
const std = @import("std");
const owner_state = @import("owner_state_hq");
const field = @import("field");
const stage_mod = @import("stage.zig");
const scene_mod = @import("scene.zig");
const windows_mod = @import("windows.zig");
const roster_mod = @import("roster/root.zig");
const services_mod = @import("services/root.zig");
const tablet_mod = @import("tablet/root.zig");
const service_engines = @import("services/engines.zig");
const results = @import("campaign_policies").mode_result;

const population_host = @import("host/population.zig");
const recruit_host = @import("host/recruit.zig");
const services_host = @import("host/services.zig");
const mode_host = @import("host/mode.zig");
const sidecar_host = @import("host/sidecar.zig");

const hq_assets = @import("hq_data");
const stage_data = hq_assets;
const stages_data = hq_assets.stages;
const windows_data = hq_assets.recruitment_windows;
const roster_data = hq_assets.roster;
const services_data = hq_assets.service_callers;
const tablet_data = @import("tablet/table.zig");

pub const schema = "suikoden-hq/1";
pub const sidecar_schema = "suikoden-hq-sidecar/1";
pub const sidecar_version: u8 = 1;
pub const max_interactions = 64;
pub const max_rooms = 64;
pub const max_actors = 512;
pub const max_service_ops = 8;
pub const flag_slots: usize = 108;
pub const identity_slots: usize = 108;

pub const story_castle_index: u8 = 15;
pub const story_castle_mask: u8 = 0x02;

pub const Screen = enum { field, party, service, tablet, mode, recruit };
pub const Intent = enum { up, down, left, right, confirm, cancel };

/// A non-canonical entry must be requested explicitly.  `canonical` is refused
/// with the exact unresolved-entry error instead of silently working.
pub const Entry = enum { canonical, declared };

pub const InteractionKind = enum { recruit, service_caller, service_unbound, inspect, tablet };

pub const Interaction = struct {
    kind: InteractionKind,
    id: []const u8,
    room: u8 = 0,
    entity_index: u8 = 0,
    identity: u16 = 0,
    window: ?[]const u8 = null,
    blocker: ?[]const u8 = null,
    declared: bool = false,
};

pub const Blocker = struct {
    code: []const u8,
    detail: []const u8 = "",
    interaction: ?[]const u8 = null,
};

/// The three runtime facts a source service conversation carries.  They have no
/// default: the caller (the scene dispatcher) must supply them, because the
/// per-caller story gate is not decoded in the HQ service caller asset.
pub const ServiceAccess = struct {
    npc_present: bool,
    service_available: bool,
    story_gate: bool,
    rune_permitted: ?bool = null,
};

pub const ModeInput = enum { up, down, left, right, confirm, cancel };
pub const ModeReceipt = struct { receipt: u64, money: u32 };

/// The durable optional-game projection.  The shared store is built
/// from these facts for one transaction and written back after publication, so
/// there is exactly one stored mode-result owner.
pub const ModeFacts = struct {
    net: i32 = 0,
    status: [16]u8 = @splat(0),
    retained: u32 = 0,
    best: [4]u32 = @splat(0),
    draws_cursor: u64 = 0,
    draws_bios: ?u32 = null,
    receipts: [4]u64 = @splat(0),
    revision: u64 = 0,
};

/// The optional-game seam.  The core host never imports the optional-game module, so
/// this file compiles from this checkout alone; `mode.zig` supplies the driver
/// when the accepted optional-game contracts is available.
pub const ModeDriver = struct {
    ctx: *anyopaque,
    owns_frame: *const fn (*anyopaque) bool,
    admit: *const fn (*anyopaque, caller_site: u32) anyerror!void,
    play: *const fn (*anyopaque, ModeInput) anyerror!void,
    settle: *const fn (*anyopaque) anyerror!ModeReceipt,
    finish: *const fn (*anyopaque) anyerror!void,
};

pub const Snapshot = struct {
    schema: []const u8 = sidecar_schema,
    version: u8 = sidecar_version,
    content_sha256: []const u8 = "",
    recruit: [flag_slots]u8 = @splat(0),
    roster_json: []const u8 = "",
    tablet: ?tablet_mod.Snapshot = null,
    mode: ModeFacts = .{},
    screen: Screen = .field,
    room: u8 = 0,
    cursor: u8 = 0,
    revision: u64 = 0,
};

pub const Host = struct {
    allocator: std.mem.Allocator,
    /// Canonical field owner (money, bags, storage, story scenario, party).
    field_state: *field.State,
    scenes: std.json.Parsed(scene_mod.Catalogue),
    windows: windows_mod.Loaded,
    roster_packet: std.json.Parsed(roster_mod.source.Packet),
    services: std.json.Parsed(services_mod.Packet),
    roster: roster_mod.roster.Roster,
    result_host: results.Host,
    recruit: [flag_slots]u8,
    mode_facts: ModeFacts = .{},
    content_sha: results.Sha,
    /// Lowercase hex of `content_sha`; a stable address for the sidecar.
    content_hex: [64]u8 = @splat(0),
    tablet: ?tablet_mod.View = null,
    service: ?services_mod.Host = null,
    service_ops: [max_service_ops]services_mod.ServiceId = @splat(.shop_buy),
    service_op_count: u8 = 0,
    service_cursor: u8 = 0,
    service_adapter: service_engines.Adapter,
    area: ?[]const u8 = null,
    screen: Screen = .field,
    room: u8 = 0,
    cursor: u8 = 0,
    interactions: [max_interactions]Interaction = @splat(.{ .kind = .inspect, .id = "" }),
    interaction_count: u8 = 0,
    revision: u64 = 1,
    mode_driver: ?ModeDriver = null,
    /// Backing arena for the restored roster JSON; the roster borrows it.
    restore_arena: std.heap.ArenaAllocator,
    blocker: ?Blocker = null,
    message: []const u8 = "",
    /// Interaction-time facts the caller supplies for a service area; the
    /// per-caller story gate is not decoded, so there is no default.
    service_access: ?ServiceAccess = null,
    // Reused scratch storage for facts/population; a returned slice borrows it.
    room_buffer: [max_rooms]scene_mod.RoomView = undefined,
    actor_buffer: [max_actors]scene_mod.ActorView = undefined,
    party_bitmap: [identity_slots]u8 = @splat(0),
    level_buffer: [identity_slots]u8 = @splat(0),

    pub const Construction = population_host.Construction;

    pub const Init = struct {
        field_state: *field.State,
        roster: roster_mod.roster.Roster,
        recruit: [flag_slots]u8,
    };

    pub fn init(allocator: std.mem.Allocator, config: Init) !*Host {
        const self = try allocator.create(Host);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .field_state = config.field_state,
            .scenes = try scene_mod.load(allocator, stages_data.stages_json),
            .windows = undefined,
            .roster_packet = undefined,
            .services = undefined,
            .roster = config.roster,
            .result_host = undefined,
            .recruit = config.recruit,
            .content_sha = undefined,
            .restore_arena = std.heap.ArenaAllocator.init(allocator),
            .service_adapter = .{ .state = config.field_state },
        };
        errdefer self.scenes.deinit();
        self.windows = try windows_mod.open(allocator, windows_data.json);
        errdefer self.windows.deinit();
        self.roster_packet = try roster_mod.source.load(allocator, roster_data.json);
        errdefer self.roster_packet.deinit();
        self.services = try services_mod.load(allocator, services_data.json);
        errdefer self.services.deinit();
        self.content_sha = try contentIdentity();
        self.content_hex = std.fmt.bytesToHex(self.content_sha.bytes, .lower);
        self.result_host = try results.Host.init(self.modeProjection(), self.content_sha);
        try self.validateInitial();
        try self.rebuild();
        return self;
    }

    pub fn deinit(self: *Host) void {
        self.restore_arena.deinit();
        self.services.deinit();
        self.roster_packet.deinit();
        self.windows.deinit();
        self.scenes.deinit();
        self.allocator.destroy(self);
    }

    // -- identity -----------------------------------------------------------

    /// SHA-256 over the exact committed content the host binds.  A save from a
    /// different packet set is refused, never silently re-bound.
    fn contentIdentity() !results.Sha {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update("suikoden-hq-content/1");
        const parts = [_][]const u8{
            stage_data.stage_plan_json,
            stages_data.stages_json,
            windows_data.json,
            roster_data.json,
            services_data.json,
            tablet_data.tablet_json,
        };
        for (parts) |part| {
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(part, &digest, .{});
            hasher.update(&digest);
        }
        var sha: results.Sha = .{};
        hasher.final(&sha.bytes);
        return sha;
    }

    pub fn contentSha(self: *const Host) results.Sha {
        return self.content_sha;
    }

    pub fn validateInitial(self: *Host) !void {
        try self.roster.validate(self.roster_packet.value);
        for (self.recruit) |byte| if (byte & 0xFC != 0) return error.InvalidRecruitByte;
        // Every *active* member must be a recruited identity: no fabricated
        // profile.  A reserve record may exist before its source grant (that is
        // the only way a combatant can join without inventing stats).
        for (self.roster.snapshot.active) |maybe| if (maybe) |id| {
            const record = self.recordIdOf(id) orelse return error.UnknownMember;
            if (record >= flag_slots or self.recruit[record] & 1 == 0) return error.RosterMemberNotRecruited;
        };
        // The stage is the source byte, not a guess from the roster size.
        if (self.field_state.progress.story.recruitment_tier > 4) return error.InvalidRecruitmentTier;
    }

    // -- source facts -------------------------------------------------------

    pub fn stageByte(self: *const Host) u8 {
        return self.field_state.progress.story.recruitment_tier;
    }

    pub fn stage(self: *const Host) !stage_mod.Stage {
        return stage_mod.Stage.fromByte(self.stageByte());
    }

    pub fn recruitFlags(self: *const Host) [flag_slots]u8 {
        return self.recruit;
    }

    pub fn counts(self: *const Host) stage_mod.Counts {
        return stage_mod.recount(&self.recruit);
    }

    /// Return whether the HQ castle story flag is active on the live scenario.
    pub fn storyCastleFlag(self: *const Host) bool {
        const scenario = self.field_state.progress.story.scenario orelse return false;
        return scenario.scenario[story_castle_index] & story_castle_mask != 0;
    }

    /// The source record id of a combat member (the recruit flag slot).
    /// The portrait index the HQ roster asset exposes is a *different* space.
    pub fn recordIdOf(self: *Host, member_id: []const u8) ?u16 {
        const profile = self.roster_packet.value.profile(member_id) orelse return null;
        return profile.source_character_id;
    }

    /// Map one source record id (HQ window cid) to the HQ roster identity space.
    /// A combat profile carries the identity; a non-combatant is taken from the
    /// HQ identity block; anything else stays unsupported.
    pub fn identityForRecord(self: *Host, cid: u16) !u16 {
        for (self.roster_packet.value.profiles) |profile| {
            if (profile.source_character_id != cid) continue;
            return profile.identity orelse error.GuestIdentity;
        }
        const asset = self.windows.asset();
        if (cid < asset.identity.identities.len) {
            if (asset.identity.identities[cid].portrait_index) |index| return index;
        }
        return error.NoPortraitIdentity;
    }

    /// Persistent level by source record id, derived from the canonical roster.
    pub fn levels(self: *Host) [256]u8 {
        var out: [256]u8 = @splat(0);
        for (self.roster.snapshot.members) |maybe| if (maybe) |member| {
            const record = self.recordIdOf(member.member.id) orelse continue;
            if (record < out.len) out[record] = member.level;
        };
        return out;
    }

    /// Active party record ids in party order.
    pub fn partyIdentities(self: *Host) [6]u8 {
        var out: [6]u8 = @splat(0);
        var count: usize = 0;
        for (self.roster.snapshot.active) |maybe| if (maybe) |id| {
            if (count == out.len) break;
            if (self.recordIdOf(id)) |record| {
                out[count] = @intCast(record);
                count += 1;
            }
        };
        return out;
    }

    /// The HQ scene construction slice, rebuilt from the canonical owners.
    pub fn sceneState(self: *Host) scene_mod.State {
        var state: scene_mod.State = .{};
        state.stage_byte = self.stageByte();
        if (self.field_state.progress.story.scenario) |scenario| state.story = scenario;
        state.recruit = self.recruit;
        const identities = self.partyIdentities();
        var count: usize = 0;
        for (identities) |id| if (id != 0) {
            count += 1;
        };
        state.party = identities;
        state.party_len = @intCast(count);
        state.levels = self.levels();
        return state;
    }

    // -- headquarters population -------------------------------------------

    pub fn construction(self: *Host) !Construction {
        return population_host.construction(self);
    }

    pub fn stageEntry(self: *const Host) !*const scene_mod.StageEntry {
        return population_host.stageEntry(self);
    }

    pub fn rebuild(self: *Host) !void {
        return population_host.rebuild(self);
    }

    pub fn interactionList(self: *const Host) []const Interaction {
        return self.interactions[0..self.interaction_count];
    }

    pub fn currentInteraction(self: *const Host) ?Interaction {
        if (self.cursor >= self.interaction_count) return null;
        return self.interactions[self.cursor];
    }

    // -- navigation ---------------------------------------------------------

    pub fn enterRoom(self: *Host, room: u8) !void {
        if (self.screen != .field) return error.WrongScreen;
        const entry = try self.stageEntry();
        if (scene_mod.findRoom(entry.*, room) == null) return error.UnknownRoom;
        self.area = null;
        self.room = room;
        try self.rebuild();
    }

    /// Enter a source service area.  The castle exterior -> interior route is
    /// not derived, so a canonical request is refused.
    pub fn enterArea(self: *Host, area_id: []const u8, entry: Entry, access: ServiceAccess) !void {
        if (self.screen != .field) return error.WrongScreen;
        if (entry == .canonical) return error.HqInteriorRouteUnresolved;
        var known = false;
        for (self.services.value.callers) |caller| {
            if (std.mem.eql(u8, caller.area, area_id)) known = true;
        }
        if (!known) return error.UnknownServiceArea;
        self.area = area_id;
        self.service_access = access;
        try self.rebuild();
    }

    pub fn leaveArea(self: *Host) void {
        self.area = null;
        self.service_access = null;
        self.rebuild() catch {};
    }

    pub fn setModeDriver(self: *Host, driver: ?ModeDriver) void {
        self.mode_driver = driver;
    }

    // -- ordinary input -----------------------------------------------------

    pub fn step(self: *Host, intent: Intent) !void {
        self.message = "";
        switch (self.screen) {
            .field => try self.stepField(intent),
            .party => try self.stepParty(intent),
            .service => try services_host.stepService(self, intent),
            .tablet => try services_host.stepTablet(self, intent),
            .mode => try mode_host.stepMode(self, intent),
            .recruit => try recruit_host.stepRecruit(self, intent),
        }
    }

    fn stepField(self: *Host, intent: Intent) !void {
        switch (intent) {
            .up => if (self.cursor > 0) {
                self.cursor -= 1;
            },
            .down => if (self.cursor + 1 < self.interaction_count) {
                self.cursor += 1;
            },
            .confirm => try self.confirmInteraction(),
            .cancel => {},
            .left, .right => {},
        }
    }

    fn stepParty(self: *Host, intent: Intent) !void {
        switch (intent) {
            .up => if (self.cursor > 0) {
                self.cursor -= 1;
            },
            .down => if (self.cursor + 1 < self.roster.activeCount()) {
                self.cursor += 1;
            },
            .cancel, .confirm => {
                self.screen = .field;
                self.cursor = 0;
                try self.rebuild();
            },
            .left, .right => {},
        }
    }

    pub fn openParty(self: *Host) !void {
        if (self.screen != .field) return error.WrongScreen;
        self.screen = .party;
        self.cursor = 0;
    }

    fn confirmInteraction(self: *Host) !void {
        const interaction = self.currentInteraction() orelse return error.NoInteraction;
        switch (interaction.kind) {
            .recruit => try recruit_host.openRecruit(self, interaction),
            .service_caller => try services_host.openService(self, interaction),
            .service_unbound => {
                self.blocker = .{ .code = interaction.blocker orelse "service_family_unproved", .detail = "the headquarters service actor has no bound service family", .interaction = interaction.id };
                return error.ServiceFamilyUnproved;
            },
            .tablet => {
                self.blocker = .{ .code = "tablet_entry_unbound", .detail = "no decoded field object/scene event opens the tablet", .interaction = interaction.id };
                return error.TabletEntryUnbound;
            },
            .inspect => {
                self.message = interaction.id;
            },
        }
    }

    // -- recruit ------------------------------------------------------------

    pub fn recruitFacts(self: *Host, interaction: bool) windows_mod.Facts {
        return recruit_host.recruitFacts(self, interaction);
    }

    pub fn recountStage(self: *Host) !stage_mod.Plan {
        return recruit_host.recountStage(self);
    }

    // -- services & tablet --------------------------------------------------

    pub fn openService(self: *Host, interaction: Interaction) !void {
        return services_host.openService(self, interaction);
    }

    pub fn openTablet(self: *Host, entry: Entry) !void {
        return services_host.openTablet(self, entry);
    }

    pub fn tabletView(self: *const Host) ?*const tablet_mod.View {
        if (self.tablet) |*view| return view;
        return null;
    }

    // -- optional-game seam -------------------------------------------------

    pub fn admitMode(self: *Host, caller_site: u32) !void {
        return mode_host.admitMode(self, caller_site);
    }

    pub fn modeProjection(self: *Host) results.Store {
        return mode_host.modeProjection(self);
    }

    pub fn publishMode(self: *Host, result: results.Result) !results.Outcome {
        return mode_host.publishMode(self, result);
    }

    pub fn modeFacts(self: *const Host) ModeFacts {
        return self.mode_facts;
    }

    // -- roster operations (source-event entry) ----------------------------

    /// Apply one reviewed HQ roster command.  The roster validates the whole
    /// candidate before it replaces the live state, so a refused command leaves
    /// the roster untouched.
    pub fn applyRoster(self: *Host, command: roster_mod.roster.Command) !void {
        try self.roster.apply(self.roster_packet.value, command);
        self.revision += 1;
        try self.rebuild();
    }

    pub fn leave(self: *Host, id: []const u8, kind: roster_mod.roster.LeaveKind, source: []const u8) !void {
        try self.roster.leave(self.roster_packet.value, id, kind, source);
        self.revision += 1;
        try self.rebuild();
    }

    pub fn rejoin(self: *Host, id: []const u8, forced: bool, source: []const u8) !void {
        try self.roster.rejoin(self.roster_packet.value, id, forced, source);
        self.revision += 1;
        try self.rebuild();
    }

    pub fn knockout(self: *Host, id: []const u8, source: []const u8) !void {
        try self.roster.knockout(self.roster_packet.value, id, source);
        self.revision += 1;
    }

    pub fn rosterState(self: *Host) *roster_mod.roster.Roster {
        return &self.roster;
    }

    // -- durable sidecar ----------------------------------------------------

    pub fn captureOwnerState(self: *Host, allocator: std.mem.Allocator) !owner_state.HqState {
        return sidecar_host.captureOwnerState(self, allocator);
    }

    pub fn applyOwnerState(self: *Host, state: owner_state.HqState) !void {
        return sidecar_host.applyOwnerState(self, state);
    }

    pub fn capture(self: *Host, allocator: std.mem.Allocator) !Snapshot {
        return sidecar_host.capture(self, allocator);
    }

    pub fn restore(self: *Host, snapshot: Snapshot) !void {
        return sidecar_host.restore(self, snapshot);
    }

    // -- diagnostics --------------------------------------------------------

    pub fn blockerInfo(self: *const Host) ?Blocker {
        return self.blocker;
    }

    pub fn interactionsFor(self: *const Host, room: u8) usize {
        var count: usize = 0;
        for (self.interactionList()) |interaction| {
            if (interaction.room == room) count += 1;
        }
        return count;
    }
};

test {
    _ = stage_mod;
    _ = scene_mod;
    _ = windows_mod;
    _ = roster_mod;
    _ = services_mod;
    _ = tablet_mod;
    _ = service_engines;
    _ = results;
    _ = population_host;
    _ = recruit_host;
    _ = services_host;
    _ = mode_host;
    _ = sidecar_host;
}

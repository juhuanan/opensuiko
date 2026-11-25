//! Integrated headquarters / roster / service / tablet host.
//!
//! One `Host` owns the headquarters state that the lower layers do not:
//! the 108 source recruit bytes (`gs+0x1AF4`), the castle stage produced by
//! the recount/promote pair (`gs+0x34` -> `story.recruitment_tier`), the
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
const event_runtime = @import("event_runtime");
const stage_mod = @import("stage.zig");
const scene_mod = @import("scene.zig");
const windows_mod = @import("windows.zig");
const roster_mod = @import("roster/root.zig");
const services_mod = @import("services/root.zig");
const tablet_mod = @import("tablet/root.zig");
const service_engines = @import("services/engines.zig");
const results = @import("campaign_policies").mode_result;

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

/// `gs+0x190` is the base of the 240-byte scenario array (`event_runtime`); the
/// HQ window predicate contract indexes its story operands by absolute `gs`
/// offset, so the host bridges the two spaces here instead of re-indexing a
/// package asset. Every committed window byte is inside `0x190..0x280`.
pub const story_page_base: u16 = 0x190;
pub const story_page_bytes: usize = 0x300;
/// `gs+0x19F & 0x02`, the HQ castle story gate, expressed in scenario
/// coordinates.
pub const story_castle_index: u8 = 0x19F - story_page_base;
pub const story_castle_mask: u8 = 0x02;
const arcade_status_story_index: usize = 160;

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
    story_page_buffer: [story_page_bytes]u8 = @splat(0),
    party_bitmap: [identity_slots]u8 = @splat(0),
    level_buffer: [identity_slots]u8 = @splat(0),

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

    fn validateInitial(self: *Host) !void {
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

    /// `gs+0x19F & 0x02` read from the live scenario.
    pub fn storyCastleFlag(self: *const Host) bool {
        const scenario = self.field_state.progress.story.scenario orelse return false;
        return scenario.scenario[story_castle_index] & story_castle_mask != 0;
    }

    /// The 240-byte scenario in absolute `gs` coordinates, for HQ recruitment windows.  The
    /// returned slice borrows the host buffer and stays valid until the next
    /// call.
    pub fn storyPage(self: *Host) []const u8 {
        @memset(&self.story_page_buffer, 0);
        if (self.field_state.progress.story.scenario) |scenario| {
            @memcpy(self.story_page_buffer[story_page_base .. story_page_base + scenario.scenario.len], &scenario.scenario);
        }
        return &self.story_page_buffer;
    }

    /// The source record id of a combat member (the `gs+0x1AF4` flag slot).
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
    fn partyIdentities(self: *Host) [6]u8 {
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

    pub const Construction = struct {
        rooms: []const scene_mod.RoomView,
        actors: []const scene_mod.ActorView,
        skipped_unproved_actors: u16,
        skipped_unproved_entrances: u16,
    };

    /// Reconstruct the current stage's reachable rooms and present actors.  An
    /// unproved doorway/actor is skipped by HQ scene construction, never defaulted.
    pub fn construction(self: *Host) !Construction {
        var state = self.sceneState();
        const facts = try state.facts();
        const built = try scene_mod.reconstruct(&self.scenes.value, facts, &self.room_buffer, &self.actor_buffer);
        return .{
            .rooms = built.rooms,
            .actors = built.actors,
            .skipped_unproved_actors = built.skipped_unproved_actors,
            .skipped_unproved_entrances = built.skipped_unproved_entrances,
        };
    }

    pub fn stageEntry(self: *const Host) !*const scene_mod.StageEntry {
        return scene_mod.findStage(self.scenes.value, try self.stage()) orelse error.UnknownStage;
    }

    /// The HQ recruitment window bound to one constructed actor, if any.  The binding
    /// is the source area file plus the entity index plus the identity byte --
    /// a catalogue/portrait match alone is never a window.
    fn windowForActor(self: *Host, entry: *const scene_mod.StageEntry, actor: scene_mod.ActorView) ?*const windows_mod.Window {
        for (self.windows.asset().windows) |*window| {
            if (!std.mem.eql(u8, window.area.source_file, entry.area.file)) continue;
            if (window.area.entity_id != actor.source_character_id) continue;
            if (window.area.room_entity != actor.entity_index) continue;
            return window;
        }
        return null;
    }

    fn serviceActorFor(_: *Host, entry: *const scene_mod.StageEntry, actor: scene_mod.ActorView) ?scene_mod.ServiceActor {
        for (entry.service_actors) |service| {
            if (std.mem.eql(u8, service.id, actor.id)) return service;
        }
        return null;
    }

    /// Rebuild the current room's interaction list from the current facts.
    pub fn rebuild(self: *Host) !void {
        self.interaction_count = 0;
        self.cursor = 0;
        self.blocker = null;
        if (self.area) |area_id| {
            try self.rebuildArea(area_id);
            return;
        }
        const entry = try self.stageEntry();
        const built = try self.construction();
        for (built.actors) |actor| {
            if (actor.room != self.room) continue;
            if (self.interaction_count == max_interactions) return error.TooManyInteractions;
            if (self.windowForActor(entry, actor)) |window| {
                self.push(.{
                    .kind = .recruit,
                    .id = actor.id,
                    .room = actor.room,
                    .entity_index = actor.entity_index,
                    .identity = actor.source_character_id,
                    .window = window.id,
                });
            } else if (self.serviceActorFor(entry, actor)) |service| {
                self.push(.{
                    .kind = .service_unbound,
                    .id = actor.id,
                    .room = actor.room,
                    .entity_index = actor.entity_index,
                    .identity = actor.source_character_id,
                    .blocker = service.binding_status,
                });
            } else {
                self.push(.{
                    .kind = .inspect,
                    .id = actor.id,
                    .room = actor.room,
                    .entity_index = actor.entity_index,
                    .identity = actor.source_character_id,
                });
            }
        }
        // The tablet's field object is not yet bound; the host exposes it
        // as a declared entry only, in the landing room.
        if (self.room == entry.landing.room and self.interaction_count < max_interactions) {
            self.push(.{ .kind = .tablet, .id = "stars_of_destiny_tablet", .room = self.room, .declared = true, .blocker = "tablet_entry_unbound" });
        }
    }

    fn rebuildArea(self: *Host, area_id: []const u8) !void {
        for (self.services.value.callers) |*caller| {
            if (!std.mem.eql(u8, caller.area, area_id)) continue;
            if (self.interaction_count == max_interactions) return error.TooManyInteractions;
            self.push(.{ .kind = .service_caller, .id = caller.id, .room = caller.room, .entity_index = caller.entity });
        }
    }

    fn push(self: *Host, interaction: Interaction) void {
        self.interactions[self.interaction_count] = interaction;
        self.interaction_count += 1;
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
            .service => try self.stepService(intent),
            .tablet => try self.stepTablet(intent),
            .mode => try self.stepMode(intent),
            .recruit => try self.stepRecruit(intent),
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

    // -- recruit ------------------------------------------------------------

    /// The HQ recruitment window facts for the current canonical state.  Every fact comes
    /// from a real owner; a fact the port cannot express (item identity) is
    /// left empty so a window that needs it blocks instead of defaulting true.
    pub fn recruitFacts(self: *Host, interaction: bool) windows_mod.Facts {
        @memset(&self.party_bitmap, 0);
        const identities = self.partyIdentities();
        var party_count: u8 = 0;
        for (identities) |id| if (id != 0) {
            self.party_bitmap[id] = 1;
            party_count += 1;
        };
        const by_identity = self.levels();
        @memcpy(&self.level_buffer, by_identity[0..identity_slots]);
        return .{
            .entity_available = true,
            .interaction = interaction,
            .story = self.storyPage(),
            .recruit = &self.recruit,
            .party = &self.party_bitmap,
            .money = self.field_state.progress.money,
            .levels = &self.level_buffer,
            .tier = self.stageByte(),
            .eligible = self.counts().present,
            .party_count = party_count,
            .hero_x = @intCast(@divTrunc(self.field_state.x, 8)),
            .hero_y = @intCast(@divTrunc(self.field_state.y, 8)),
            .input_mask = 0x41,
            .mode_word = 0,
            .random = 0,
        };
    }

    fn evaluateWindow(self: *Host, window: *const windows_mod.Window, interaction: bool) windows_mod.Outcome {
        return windows_mod.evaluate(window, self.recruitFacts(interaction));
    }

    fn confirmInteraction(self: *Host) !void {
        const interaction = self.currentInteraction() orelse return error.NoInteraction;
        switch (interaction.kind) {
            .recruit => try self.openRecruit(interaction),
            .service_caller => try self.openService(interaction),
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

    fn openRecruit(self: *Host, interaction: Interaction) !void {
        const window = windows_mod.windowById(self.windows.asset(), interaction.window orelse return error.UnknownWindow) orelse return error.UnknownWindow;
        const outcome = self.evaluateWindow(window, true);
        switch (outcome.route) {
            .admitted => {
                self.screen = .recruit;
                self.message = window.id;
            },
            else => {
                self.blocker = .{
                    .code = @tagName(outcome.blocker.?.code),
                    .detail = outcome.blocker.?.detail,
                    .interaction = interaction.id,
                };
                return error.RecruitWindowClosed;
            },
        }
    }

    fn stepRecruit(self: *Host, intent: Intent) !void {
        switch (intent) {
            .cancel => {
                self.screen = .field;
                self.message = "recruit_declined";
                try self.rebuild();
            },
            .confirm => {
                const interaction = self.currentInteraction() orelse return error.NoInteraction;
                const window = windows_mod.windowById(self.windows.asset(), interaction.window orelse return error.UnknownWindow) orelse return error.UnknownWindow;
                // A window without a source menu grants on its admitted entry
                // conjunction; only a real menu goes through `choose`, which
                // keeps an unproved second arm on the typed second route.
                const outcome = if (window.choice == null)
                    windows_mod.evaluate(window, self.recruitFacts(true))
                else
                    windows_mod.choose(window, 0, self.recruitFacts(true));
                if (outcome.route != .admitted) {
                    self.blocker = .{ .code = @tagName(outcome.blocker.?.code), .detail = outcome.blocker.?.detail, .interaction = interaction.id };
                    return error.RecruitRefused;
                }
                const plan = outcome.plan orelse return error.MissingRecruitPlan;
                // Only the reviewed roster recruitment invocation is applied.
                if (!std.mem.eql(u8, plan.op_id, windows_mod.grant_op_id) or plan.op_code != windows_mod.grant_op_code) return error.UnsupportedRecruitPlan;
                try self.commitRecruit(plan.cid, window.id);
            },
            .up, .down, .left, .right => {},
        }
    }

    /// Apply one admitted source grant: roster mutation, recruit byte, the
    /// Recount/promote pair, then a fresh population rebuild.
    fn commitRecruit(self: *Host, cid: u8, source_text: []const u8) !void {
        if (cid >= flag_slots) return error.InvalidRecruitSlot;
        if (self.recruit[cid] & 1 != 0) return error.AlreadyRecruited;
        const identity = self.identityForRecord(cid) catch |err| {
            self.blocker = .{ .code = @errorName(err), .detail = "no roster identity for this source record id" };
            return err;
        };
        self.roster.setRecruit(self.roster_packet.value, identity, true, source_text) catch |err| {
            // A combatant with no member record cannot be given fabricated
            // stats; the missing character seed is a typed blocker.
            if (err == error.RecordUnavailable) {
                self.blocker = .{ .code = "combat_member_seed_unresolved", .detail = "the roster carries no member record for this combatant" };
            }
            return err;
        };
        self.recruit[cid] |= 1;
        try self.promoteAfterRecount();
        self.screen = .field;
        self.message = "recruited";
        try self.rebuild();
    }

    /// Re-run the source recount/promotion on the current facts (the
    /// save/load and recruit-flag path).  Exactly one step is applied.
    pub fn recountStage(self: *Host) !stage_mod.Plan {
        const current = try self.stage();
        const plan = try stage_mod.afterRecount(current, self.counts(), self.storyCastleFlag());
        self.field_state.progress.story.recruitment_tier = plan.stage.byte();
        try self.rebuild();
        return plan;
    }

    /// The one source promotion step (`0x801395FC`).  The stage byte is the
    /// produced value; it is never hand-set.
    fn promoteAfterRecount(self: *Host) !void {
        const current = try self.stage();
        const plan = try stage_mod.afterRecount(current, self.counts(), self.storyCastleFlag());
        self.field_state.progress.story.recruitment_tier = plan.stage.byte();
    }

    // -- services -----------------------------------------------------------

    pub fn openService(self: *Host, interaction: Interaction) !void {
        const caller = self.services.value.findCaller(interaction.id) orelse return error.UnknownServiceCaller;
        // The three runtime facts are supplied by the interaction owner.  The
        // per-caller story gate is not decoded in the packet, so the host
        // records that as a blocker instead of pretending it was checked.
        const supplied = self.service_access orelse return error.MissingServiceAccess;
        const access: services_mod.Access = .{
            .area = self.area,
            .npc_present = supplied.npc_present,
            .service_available = supplied.service_available,
            .story_gate = if (caller.access.requires_story_gate) supplied.story_gate else null,
            .rune_permitted = supplied.rune_permitted,
        };
        switch (services_mod.open(&self.services.value, caller.id, access, self.revision)) {
            .blocked => |blocked| {
                self.blocker = .{ .code = @tagName(blocked.reason), .detail = blocked.requirement orelse "", .interaction = caller.id };
                return error.ServiceBlocked;
            },
            .opened => |host| {
                self.service = host;
                self.service_op_count = 0;
                for (caller.services) |id| {
                    if (self.service_op_count == max_service_ops) break;
                    self.service_ops[self.service_op_count] = id;
                    self.service_op_count += 1;
                }
                self.service_cursor = 0;
                self.screen = .service;
                self.message = caller.id;
            },
        }
    }

    fn stepService(self: *Host, intent: Intent) !void {
        switch (intent) {
            .up => if (self.service_cursor > 0) {
                self.service_cursor -= 1;
            },
            .down => if (self.service_cursor + 1 < self.service_op_count) {
                self.service_cursor += 1;
            },
            .cancel => {
                if (self.service) |*host| _ = host.cancel();
                self.service = null;
                self.screen = .field;
                self.message = "service_cancelled";
                try self.rebuild();
            },
            .confirm => try self.executeService(),
            .left, .right => {},
        }
    }

    fn executeService(self: *Host) !void {
        if (self.service == null) return error.NoService;
        const host = &self.service.?;
        const id = self.service_ops[self.service_cursor];
        const engine = self.service_adapter.engine();
        const outcome = switch (id) {
            .shop_buy => blk: {
                const caller = host.caller orelse return error.UnknownServiceCaller;
                if (caller.stock.len == 0) break :blk services_mod.Outcome{ .failed = .{ .reason = .not_in_stock, .caller = caller.id } };
                break :blk host.buy(&engine, 0, caller.stock[0].native_id);
            },
            .shop_sell => host.sell(&engine, 0, 0),
            .warehouse_deposit => blk: {
                // The interactive AZUKARI caller is unresolved: the overlay entry
                // stays locked in production.
                break :blk services_mod.Outcome{ .failed = .{ .reason = .non_canonical_overlay, .caller = "azukari_entry" } };
            },
            .warehouse_withdraw => services_mod.Outcome{ .failed = .{ .reason = .non_canonical_overlay, .caller = "azukari_entry" } },
            .appraisal_appraise => host.appraise(&engine, 0, 0),
            .blacksmith_sharpen => blk: {
                const caller = host.caller orelse return error.UnknownServiceCaller;
                const limit = caller.level_limit orelse
                    break :blk services_mod.Outcome{ .failed = .{ .reason = .level_limit_invalid, .requirement = "blacksmith_level_limit_unresolved", .caller = caller.id } };
                break :blk host.sharpen(&engine, 0, limit);
            },
            .rune_attach => host.attach(&engine, 0, 0, 0),
            .rune_detach => host.detach(&engine, 0),
        };
        switch (outcome) {
            .ok => |receipt| {
                self.revision += 1;
                self.message = "service_ok";
                _ = receipt;
            },
            .failed => |blocked| {
                self.blocker = .{ .code = @tagName(blocked.reason), .detail = blocked.requirement orelse "", .interaction = blocked.caller };
                return error.ServiceRefused;
            },
        }
    }

    // -- tablet -------------------------------------------------------------

    /// Journey owns the field callers. The standalone host opens declared entries.
    pub fn openTablet(self: *Host, entry: Entry) !void {
        if (self.screen != .field) return error.WrongScreen;
        if (entry == .canonical) return error.TabletEntryUnbound;
        self.tablet = tablet_mod.View.init(self.recruit);
        self.screen = .tablet;
        self.message = "tablet_declared_entry";
    }

    fn stepTablet(self: *Host, intent: Intent) !void {
        var view = &(self.tablet orelse return error.NoTablet);
        const result = view.apply(switch (intent) {
            .up => .up,
            .down => .down,
            .left => .left,
            .right => .right,
            .confirm => .confirm,
            .cancel => .cancel,
        });
        switch (result) {
            .closed => {
                self.tablet = null;
                self.screen = .field;
                self.message = "tablet_closed";
                try self.rebuild();
            },
            .revealed => |reveal| self.message = reveal.name,
            .blocked => |reason| {
                self.blocker = .{ .code = @tagName(reason), .detail = "tablet entry is not listed/active", .interaction = "stars_of_destiny_tablet" };
                return error.TabletEntryBlocked;
            },
            .moved => {},
        }
    }

    pub fn tabletView(self: *const Host) ?*const tablet_mod.View {
        if (self.tablet) |*view| return view;
        return null;
    }

    // -- optional-game seam -------------------------------------------------

    pub fn admitMode(self: *Host, caller_site: u32) !void {
        const driver = self.mode_driver orelse {
            self.blocker = .{ .code = "optional_game_seam_unbound", .detail = "the optional-game driver needs the accepted contracts" };
            return error.OptionalGameSeamUnbound;
        };
        if (self.screen != .field) return error.WrongScreen;
        try driver.admit(driver.ctx, caller_site);
        self.screen = .mode;
        self.message = "optional_game_admitted";
    }

    fn stepMode(self: *Host, intent: Intent) !void {
        const driver = self.mode_driver orelse return error.OptionalGameSeamUnbound;
        switch (intent) {
            .confirm => try driver.play(driver.ctx, .confirm),
            .cancel => {
                driver.finish(driver.ctx) catch |err| {
                    self.blocker = .{ .code = @errorName(err), .detail = "a pending settlement must be committed before the field resumes" };
                    return err;
                };
                self.screen = .field;
                self.message = "optional_game_closed";
                try self.rebuild();
            },
            .up, .down, .left, .right => try driver.play(driver.ctx, switch (intent) {
                .up => .up,
                .down => .down,
                .left => .left,
                .right => .right,
                else => unreachable,
            }),
        }
    }

    /// Build the shared mode-result store for one optional-game transaction from the
    /// canonical owners.  This is a projection, never a second stored host.
    pub fn modeProjection(self: *Host) results.Store {
        var store: results.Store = .{};
        store.revision = self.mode_facts.revision;
        store.money = self.field_state.progress.money;
        store.net = self.mode_facts.net;
        store.status = self.mode_facts.status;
        if (self.field_state.progress.story.scenario) |story| {
            store.story = story.scenario;
            store.story_bound = true;
            @memcpy(&store.status, story.scenario[arcade_status_story_index..][0..store.status.len]);
        }
        store.retained = self.mode_facts.retained;
        store.best = self.mode_facts.best;
        store.draws_cursor = self.mode_facts.draws_cursor;
        store.draws_bios = self.mode_facts.draws_bios;
        store.receipts = self.mode_facts.receipts;
        store.camera = .{
            .x = self.field_state.x,
            .y = self.field_state.y,
            .facing = switch (self.field_state.facing) {
                .up => .north,
                .right => .east,
                .down => .south,
                .left => .west,
            },
            .place = .field,
        };
        // Party identity/HP/level facts only: an optional-game result cannot
        // publish an item, and the bags stay with the field owner.
        store.party.count = 0;
        for (self.roster.snapshot.members) |maybe| if (maybe) |member| {
            if (store.party.count == results.max_members) break;
            const member_state = self.roster.stateOf(member.member.id) orelse continue;
            if (member_state.presence != .active) continue;
            var slot = results.Member{};
            slot.id = results.Id.init(member.member.id) catch continue;
            slot.hp = member.member.hp;
            slot.max_hp = member.member.max_hp;
            slot.status = switch (member.member.status) {
                .healthy => .healthy,
                .poisoned => .poisoned,
                .unconscious => .unconscious,
            };
            slot.level = member.level;
            slot.experience = member.experience;
            slot.weapon_level = member.weapon_level;
            store.party.members[store.party.count] = slot;
            store.party.count += 1;
        };
        return store;
    }

    /// Publish one optional-game result through the shared transaction.  The
    /// mode facts are written back only after the store is committed.
    pub fn publishMode(self: *Host, result: results.Result) !results.Outcome {
        try self.result_host.begin(result);
        const outcome = try self.result_host.commit();
        const committed = self.result_host.store;
        self.field_state.progress.money = committed.money;
        if (committed.story_bound) {
            if (self.field_state.progress.story.scenario) |*story| {
                story.scenario = committed.story;
                @memcpy(story.scenario[arcade_status_story_index..][0..committed.status.len], &committed.status);
            }
        }
        self.mode_facts = .{
            .net = committed.net,
            .status = committed.status,
            .retained = committed.retained,
            .best = committed.best,
            .draws_cursor = committed.draws_cursor,
            .draws_bios = committed.draws_bios,
            .receipts = committed.receipts,
            .revision = committed.revision,
        };
        self.revision += 1;
        return outcome;
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

    /// The caller owns `roster_json`; the world-session capture passes its own
    /// arena so the sidecar never leaks into the session allocator.
    pub fn captureOwnerState(self: *Host, allocator: std.mem.Allocator) !owner_state.HqState {
        const snapshot = try self.capture(allocator);
        return .{
            .content_sha256 = snapshot.content_sha256,
            .recruit = snapshot.recruit,
            .roster_json = snapshot.roster_json,
            .tablet = if (snapshot.tablet) |tablet| .{
                .magic = tablet.magic,
                .layout = tablet.layout,
                .reserved = tablet.reserved,
                .tablet_sha256 = tablet.tablet_sha256,
                .flags_sha256 = tablet.flags_sha256,
                .cursor = tablet.cursor,
                .revealed_entry = tablet.revealed_entry,
                .up_counter = tablet.up_counter,
                .down_counter = tablet.down_counter,
                .up_armed = tablet.up_armed,
                .down_armed = tablet.down_armed,
                .revision = tablet.revision,
                .scroll = tablet.scroll,
                .scroll_target = tablet.scroll_target,
                .checksum = tablet.checksum,
            } else null,
            .mode = .{
                .net = snapshot.mode.net,
                .status = snapshot.mode.status,
                .retained = snapshot.mode.retained,
                .best = snapshot.mode.best,
                .draws_cursor = snapshot.mode.draws_cursor,
                .draws_bios = snapshot.mode.draws_bios,
                .receipts = snapshot.mode.receipts,
                .revision = snapshot.mode.revision,
            },
            .screen = @fromBackingInt(@intCast(@backingInt(snapshot.screen))),
            .room = snapshot.room,
            .cursor = snapshot.cursor,
            .revision = snapshot.revision,
        };
    }

    pub fn applyOwnerState(self: *Host, state: owner_state.HqState) !void {
        const tablet: ?tablet_mod.Snapshot = if (state.tablet) |tablet| .{
            .magic = tablet.magic,
            .layout = tablet.layout,
            .reserved = tablet.reserved,
            .tablet_sha256 = tablet.tablet_sha256,
            .flags_sha256 = tablet.flags_sha256,
            .cursor = tablet.cursor,
            .revealed_entry = tablet.revealed_entry,
            .up_counter = tablet.up_counter,
            .down_counter = tablet.down_counter,
            .up_armed = tablet.up_armed,
            .down_armed = tablet.down_armed,
            .revision = tablet.revision,
            .scroll = tablet.scroll,
            .scroll_target = tablet.scroll_target,
            .checksum = tablet.checksum,
        } else null;
        try self.restore(.{
            .content_sha256 = state.content_sha256,
            .recruit = state.recruit,
            .roster_json = state.roster_json,
            .tablet = tablet,
            .mode = .{
                .net = state.mode.net,
                .status = state.mode.status,
                .retained = state.mode.retained,
                .best = state.mode.best,
                .draws_cursor = state.mode.draws_cursor,
                .draws_bios = state.mode.draws_bios,
                .receipts = state.mode.receipts,
                .revision = state.mode.revision,
            },
            .screen = @fromBackingInt(@intCast(@backingInt(state.screen))),
            .room = state.room,
            .cursor = state.cursor,
            .revision = state.revision,
        });
    }

    pub fn capture(self: *Host, allocator: std.mem.Allocator) !Snapshot {
        const roster_bytes = try self.roster.save(allocator);
        return .{
            .content_sha256 = &self.content_hex,
            .recruit = self.recruit,
            .roster_json = roster_bytes,
            .tablet = if (self.tablet) |*view| view.snapshot() else null,
            .mode = self.mode_facts,
            .screen = self.screen,
            .room = self.room,
            .cursor = self.cursor,
            .revision = self.revision,
        };
    }

    /// Restore a sidecar into this host.  Every component validates itself: a
    /// different content identity, a different roster packet, a stale tablet
    /// roster digest or a tampered recruit byte is a typed refusal, never a
    /// silent reset to a default state.
    pub fn restore(self: *Host, snapshot: Snapshot) !void {
        if (!std.mem.eql(u8, snapshot.schema, sidecar_schema)) return error.UnsupportedHqSidecar;
        if (snapshot.version != sidecar_version) return error.UnsupportedHqSidecar;
        if (!std.mem.eql(u8, snapshot.content_sha256, &self.content_hex)) return error.HqContentMismatch;
        for (snapshot.recruit) |byte| if (byte & 0xFC != 0) return error.InvalidRecruitByte;
        _ = self.restore_arena.reset(.retain_capacity);
        var roster = try roster_mod.roster.Roster.restore(self.restore_arena.allocator(), self.roster_packet.value, snapshot.roster_json);
        try roster.validate(self.roster_packet.value);
        self.recruit = snapshot.recruit;
        self.roster = roster;
        self.mode_facts = snapshot.mode;
        self.result_host = try results.Host.init(self.modeProjection(), self.content_sha);
        self.revision = snapshot.revision;
        self.room = snapshot.room;
        self.screen = snapshot.screen;
        self.tablet = null;
        if (snapshot.tablet) |stored| {
            self.tablet = try tablet_mod.View.restore(stored, self.recruit);
        } else if (snapshot.screen == .tablet) return error.InvalidHqSidecar;
        try self.validateInitial();
        try self.rebuild();
        if (self.cursor != snapshot.cursor) {
            if (snapshot.cursor < self.interaction_count) self.cursor = snapshot.cursor;
        }
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
}

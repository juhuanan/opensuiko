//! Integrated travel host across world routes, boat, teleport and admission.
//!
//! The single integration surface for travel modes.  It owns no simulation of
//! its own: every mode is driven by its reviewed consumer (route edges, boat,
//! Viki/Mirror teleport) over the canonical `world_travel.State`, and every
//! committed mode result is admitted and published through the shared
//! mode-result transaction.  Field ground queries come from the travel ground
//! geometry; the package -> source-room identity comes from the route-edge
//! catalogue, never a hardcoded table.
//!
//! Ordinary input drives the boat and teleport sessions.  There is no injected
//! story, roster or RNG: `beginBoat` refuses before-facts whose story/roster do
//! not equal the canonical owner state, and no travel result publishes draws.
const std = @import("std");
const world = @import("world");
const field = @import("field");
const travel = @import("world_travel");
const events = @import("event_runtime");
const travel_mod = @import("travel");
const routes_mod = travel_mod.routes;
const boat_mod = travel_mod.boat;
const teleport_mod = travel_mod.teleport;
const ground_mod = travel_mod.ground;
const results = @import("campaign_policies").mode_result;
const travel_data = @import("travel_data");
const data = travel_data.navigation;
const teleport_data = travel_data.teleport;
const ground_data = travel_data.ground_geometry;

pub const schema = "suikoden-travel-host/1";
pub const BoatFacts = boat_mod.Facts;
pub const BoatChoice = boat_mod.Choice;
pub const BoatOutcome = boat_mod.BoardOutcome;
pub const TeleportRequest = teleport_mod.Request;
pub const route_schema = routes_mod.schema;
pub const boat_schema = boat_mod.schema;
pub const teleport_schema = teleport_mod.schema;

/// The production admission for the Viki/Mirror widget is the field event
/// opcode `0x43 FF 03` (Viki) or the item-use dispatch of item 81/73.  Neither
/// owner exists in the port yet, so the production admission is a typed
/// blocker; a caller that supplies a request can only use a declared,
/// non-canonical scenario, and the handler still revalidates the request
/// against the catalogue (`NotAdmitted` otherwise).
pub const teleport_admission = "field_op_0x43_and_item_use_dispatch_not_implemented";

/// Durable value snapshot.  The two mode sessions are stored as their own
/// validated packets so a fresh process rebuilds them through the same
/// `boat_mod.loadFresh`/`teleport_mod.load` contract instead of trusting an in-memory struct.
const owner_state = @import("campaign_state");
pub const Mode = owner_state.Mode;
pub const Snapshot = owner_state.Snapshot;

pub const Host = struct {
    allocator: std.mem.Allocator,
    catalogue: teleport_mod.catalogue.Loaded,
    route_packet: std.json.Parsed(routes_mod.edges.Packet),
    boat_packet: std.json.Parsed(boat_mod.Packet),
    boat_ledger: boat_mod.Ledger = .{},
    boat: ?boat_mod.boat.LoadedSession = null,
    teleport: ?teleport_mod.Decoded = null,
    ground: ?*ground_mod.Geometry = null,
    /// Capture buffers.  A Snapshot borrows this arena and stays valid until the
    /// next capture or `deinit`, so a save never leaks a per-capture JSON copy.
    capture_arena: std.heap.ArenaAllocator,
    /// Monotonic before-fact revision for the mode-result transaction.  A travel
    /// mode result bumps it exactly once; it is not a party revision.
    result_revision: u64 = 0,
    /// Declared entry ids already used in this session; a replayed entry id is
    /// refused by `boat_mod.board` itself through the ledger, so this is evidence
    /// only.
    last_board: [96]u8 = @splat(0),
    last_board_len: u8 = 0,

    pub fn init(allocator: std.mem.Allocator) !*Host {
        const self = try allocator.create(Host);
        errdefer allocator.destroy(self);
        var catalogue = try teleport_mod.loadCatalogue(allocator, teleport_data.viki_json, teleport_data.mirror_json);
        errdefer catalogue.deinit();
        const route_packet = try routes_mod.edges.load(allocator, data.route_json);
        errdefer route_packet.deinit();
        const boat_packet = try boat_mod.load(allocator, data.boat_json);
        errdefer boat_packet.deinit();
        self.* = .{
            .allocator = allocator,
            .capture_arena = std.heap.ArenaAllocator.init(allocator),
            .catalogue = catalogue,
            .route_packet = route_packet,
            .boat_packet = boat_packet,
        };
        return self;
    }

    pub fn deinit(self: *Host) void {
        if (self.teleport) |*decoded| decoded.deinit();
        if (self.boat) |*loaded| loaded.deinit();
        if (self.ground) |geometry| geometry.deinit();
        self.boat_packet.deinit();
        self.route_packet.deinit();
        self.catalogue.deinit();
        self.capture_arena.deinit();
        self.allocator.destroy(self);
    }

    pub fn mode(self: *const Host) Mode {
        if (self.teleport != null) return .teleport;
        if (self.boat) |loaded| if (loaded.session.status != .settled) return .boat;
        return .none;
    }

    // ------------------------------------------------------------------
    // Static ground
    // ------------------------------------------------------------------

    fn sourceRoomId(location: routes_mod.edges.Location, buffer: []u8) ?[]const u8 {
        const file = location.source_file orelse return null;
        const base = std.fs.path.basename(file);
        const dot = std.mem.indexOfScalar(u8, base, '.') orelse base.len;
        if (dot == 0 or dot >= buffer.len) return null;
        for (base[0..dot], 0..) |byte, index| buffer[index] = std.ascii.toLower(byte);
        const room = location.source_room orelse return null;
        return std.fmt.bufPrint(buffer[dot..], "_room{d}", .{room}) catch null;
    }

    fn locationForRoom(self: *const Host, room_id: []const u8) ?routes_mod.edges.Location {
        return self.route_packet.value.location(room_id);
    }

    fn groundRoom(self: *Host, room_id: []const u8, buffer: []u8) ?*const ground_mod.Room {
        const geometry = self.ground orelse return null;
        const location = self.locationForRoom(room_id) orelse return null;
        const source = sourceRoomId(location, buffer) orelse return null;
        return geometry.roomById(source);
    }

    fn queryGround(context: *const anyopaque, room_id: []const u8, x: i32, y: i32) bool {
        const self: *Host = @ptrCast(@alignCast(@constCast(context)));
        var buffer: [32]u8 = undefined;
        const room = self.groundRoom(room_id, &buffer) orelse return true;
        if (x < 0 or y < 0 or @mod(x, 8) != 0 or @mod(y, 8) != 0) return false;
        const value = ground_mod.groundAt(room, @intCast(@divTrunc(x, 8)), @intCast(@divTrunc(y, 8)), 0);
        return value.walkable and !value.edge_blocked and !value.unsupported_level;
    }

    /// Bind the reviewed geometry to the production travel owner.  Loading is
    /// lazy and once; a failed load is not silently replaced by fallback data.
    /// The one parsed route packet this host owns, borrowed by the
    /// travel consumer for the session lifetime (never copied, never freed by
    /// the borrower).
    pub fn routePacket(self: *const Host) *const routes_mod.edges.Packet {
        return &self.route_packet.value;
    }

    pub fn attachGround(self: *Host, state: *travel.State) !void {
        if (self.ground == null) {
            self.ground = try ground_mod.Geometry.load(self.allocator, ground_data.json);
        }
        state.attachGround(.{ .context = self, .query = queryGround });
    }

    // ------------------------------------------------------------------
    // Mode-result canonical before-facts and publication
    // ------------------------------------------------------------------

    fn ownerSlot(owner: results.Owner) usize {
        return @backingInt(owner);
    }

    fn contentSha(self: *const Host) !results.Sha {
        return results.Sha.initHex(self.route_packet.value.content_sha256);
    }

    fn storyOf(state: *const travel.State) ?events.StoryState {
        return state.link.field_state.progress.story.scenario;
    }

    pub fn storeForState(self: *Host, state: *const travel.State, camera_override: ?results.Camera) !results.Store {
        var store: results.Store = .{};
        store.revision = self.result_revision;
        store.money = state.combat.progress.money;
        const party = state.combat.progress.party;
        store.party.count = @intCast(party.len);
        for (party, 0..) |member, index| {
            store.party.members[index] = .{
                .id = try results.Id.init(member.id),
                .hp = member.hp,
                .max_hp = member.max_hp,
                .status = switch (member.status) {
                    .healthy => .healthy,
                    .poisoned => .poisoned,
                    .unconscious => .unconscious,
                },
                .level = @max(state.combat.levels[index], 1),
                .weapon_level = 1,
            };
        }
        if (storyOf(state)) |story| {
            store.story = story.scenario;
            store.story_bound = true;
        }
        const place = state.link.travel.mode;
        if (camera_override) |camera| {
            store.camera = camera;
        } else if (place == .world or place == .field_pending or place == .battle_pending) {
            store.camera = .{
                .x = state.link.travel.camera.x,
                .y = state.link.travel.camera.y,
                .facing = switch (state.link.travel.heading) {
                    .north => .north,
                    .east => .east,
                    .south => .south,
                    .west => .west,
                },
                .place = .world,
            };
        } else {
            store.camera = .{
                .x = state.link.field_state.x,
                .y = state.link.field_state.y,
                .facing = switch (state.link.field_state.facing) {
                    .down => .south,
                    .up => .north,
                    .left => .west,
                    .right => .east,
                },
                .place = .field,
            };
        }
        store.receipts[ownerSlot(.travel)] = state.travel_receipt;
        return store;
    }

    fn expectedFor(self: *Host, state: *const travel.State, camera_override: ?results.Camera) !results.Expected {
        const store = try self.storeForState(state, camera_override);
        return .{
            .content_sha256 = try self.contentSha(),
            .revision = store.revision,
            .money = store.money,
            .roster = results.rosterDigest(store),
            .ledger = results.ledgerDigest(store),
            .story = results.storyDigest(store),
            .camera = store.camera,
            .receipt = store.receipts[ownerSlot(.travel)],
        };
    }

    /// Publish one mode result atomically and project its camera/receipt back
    /// into the canonical travel owner.  Travel results may not publish party,
    /// money, story, ledger or draws; a packet that does is refused.
    fn publish(self: *Host, state: *travel.State, result: results.Result, camera_override: ?results.Camera) !void {
        if (result.owner != .travel) return error.InvalidResultOwner;
        var host = try results.Host.init(try self.storeForState(state, camera_override), try self.contentSha());
        try host.begin(result);
        const outcome = try host.commit();
        const before = try self.storeForState(state, camera_override);
        if (outcome.receipt != result.receipt) return error.InvalidPublishReceipt;
        if (host.store.revision != before.revision + 1) return error.InvalidPublishRevision;
        if (host.store.money != before.money or
            !std.mem.eql(u8, &host.store.story, &before.story) or
            host.store.story_bound != before.story_bound or
            results.rosterDigest(host.store) != results.rosterDigest(before)) return error.TravelResultChangedOwnedState;
        for (result.effects[0..result.effect_count]) |effect| switch (effect.payload) {
            .camera => |camera| switch (camera.place) {
                // The board camera is the vessel's region-9 mode camera, and
                // region 9 is not an attached world map here: it stays in the
                // boat session instead of overwriting the canonical world
                // position.  Route/teleport cameras are canonical arrivals.
                .world => if (result.kind != .travel_board and state.link.travel.mode == .world) {
                    state.link.travel.camera = .{ .x = camera.x, .y = camera.y };
                    state.link.travel.heading = switch (camera.facing) {
                        .north => .north,
                        .east => .east,
                        .south => .south,
                        .west => .west,
                    };
                },
                .field => {},
                .battle => return error.InvalidTravelPlace,
            },
            else => return error.TravelResultChangedOwnedState,
        };
        state.travel_receipt = outcome.receipt;
        self.result_revision = host.store.revision;
    }

    // ------------------------------------------------------------------
    // Boat
    // ------------------------------------------------------------------

    fn boatFacts(self: *Host, state: *const travel.State, pressed: u32) !boat_mod.Facts {
        _ = self;
        const story = storyOf(state) orelse return error.MissingSourceStoryState;
        const progress = state.link.field_state.progress;
        if (progress.story.recruitment_tier > 4) return error.InvalidRecruitmentTier;
        return .{
            .story = story,
            .recruitment_tier = progress.story.recruitment_tier,
            .hero_x = @intCast(@max(0, @min(255, @divTrunc(state.link.field_state.x, 8)))),
            .hero_y = @intCast(@max(0, @min(255, @divTrunc(state.link.field_state.y, 8)))),
            .pressed = pressed,
            .upgrade_flag = false,
        };
    }

    /// Declared boat entry.  `facts` names the source event's position/input
    /// guard facts, which belong to the unattached VB8 room; the story and
    /// recruitment tier must still be the canonical ones, or the entry is
    /// refused before a receipt exists.
    pub fn beginBoat(self: *Host, state: *travel.State, board_id: []const u8, entry_id: []const u8, facts: boat_mod.Facts, choice: boat_mod.Choice) !boat_mod.BoardOutcome {
        if (self.boat != null) return error.BoatSessionBusy;
        const story = storyOf(state) orelse return error.MissingSourceStoryState;
        if (!std.mem.eql(u8, &facts.story.scenario, &story.scenario)) return error.StaleStory;
        if (facts.recruitment_tier != state.link.field_state.progress.story.recruitment_tier) return error.StaleRecruitmentTier;
        if (entry_id.len > self.last_board.len) return error.InvalidEntryIdentity;
        const expected = try self.expectedFor(state, null);
        const outcome = try boat_mod.board(self.boat_packet.value, &self.boat_ledger, board_id, entry_id, self.modeAsBoat(), facts, choice, expected);
        if (outcome.result) |result| try self.publish(state, result, null);
        if (choice == .board) {
            const session = outcome.session() orelse return error.InvalidBoatSession;
            const bytes = try session.encode(self.allocator, self.boat_packet.value);
            defer self.allocator.free(bytes);
            self.boat = try boat_mod.restoreSession(self.allocator, &self.boat_ledger, bytes, self.boat_packet.value);
            @memcpy(self.last_board[0..entry_id.len], entry_id);
            self.last_board_len = @intCast(entry_id.len);
        }
        return outcome;
    }

    fn modeAsBoat(self: *const Host) boat_mod.Mode {
        _ = self;
        return .foot;
    }

    /// Ordinary world input while a vessel is active.  Returns null when no boat
    /// session owns this frame.  The source heading and the saved field facing
    /// stay separate: the field entry fact is the teardown byte, not the world
    /// heading.
    pub fn tickBoat(self: *Host, state: *travel.State, world_input: world.Input) !?travel.Event {
        const loaded = if (self.boat) |*value| value else return null;
        const session = &loaded.session;
        switch (session.status) {
            .in_field => {
                try self.settleBoatCleanup(state, session);
                return .none;
            },
            .settled => {
                loaded.deinit();
                self.boat = null;
                return null;
            },
            .underway, .awaiting_point => {},
        }
        if (state.link.travel.mode != .world) return null;
        const pressed: u32 = if (world_input.encounter_arm_suppressed) 0 else 0;
        const facts = try self.boatFacts(state, pressed);
        const step = session.steer(self.boat_packet.value, world_input.direction, facts) catch |err| switch (err) {
            error.BoatTransitionPending, error.FieldEntryPending => return null,
            else => return err,
        };
        switch (step) {
            .none => return .none,
            .warning => return .none,
            .point => |proposal| {
                _ = proposal;
                const vessel = session.vessel orelse return error.VesselNotAboard;
                const mode_camera: results.Camera = .{ .x = vessel.camera.x, .y = vessel.camera.y, .facing = .east, .place = .world };
                const expected = try self.expectedFor(state, mode_camera);
                const saved = @as(u8, @backingInt(state.link.field_state.facing));
                const disembark = try session.disembark(self.boat_packet.value, expected, saved, facts);
                try self.publish(state, disembark.result, mode_camera);
                const destination = disembark.point.destination orelse return error.UnsupportedPointDestination;
                // The region-9 destination rooms are not attached to the
                // connected package; the refusal is typed and the vessel is
                // retired by the source cleanup, so it cannot be resurrected.
                const room = self.packageRoomForDestination(destination) orelse {
                    try self.settleBoatCleanup(state, session);
                    return .{ .unsupported_entrance = "travel_boat_region_9_arrival_unattached" };
                };
                try self.enterRoom(state, room, .{
                    .x = @intCast(disembark.field.spawn_x),
                    .y = @intCast(disembark.field.spawn_y),
                }, switch (disembark.field_facing) {
                    .north => .up,
                    .east => .right,
                    .south => .down,
                    .west => .left,
                });
                try self.settleBoatCleanup(state, session);
                return .field_entered;
            },
        }
    }

    fn settleBoatCleanup(self: *Host, state: *travel.State, session: *boat_mod.Session) !void {
        const receipt = state.travel_receipt;
        _ = try session.settleCleanup(&self.boat_ledger, receipt);
        if (self.boat) |*loaded| {
            loaded.deinit();
            self.boat = null;
        }
    }

    fn packageRoomForDestination(self: *const Host, destination: []const u8) ?[]const u8 {
        for (self.route_packet.value.locations) |location| {
            if (location.kind != .field_room) continue;
            if (!std.mem.eql(u8, location.id, destination)) continue;
            return location.id;
        }
        return null;
    }

    // ------------------------------------------------------------------
    // Teleport (Viki / Mirror)
    // ------------------------------------------------------------------

    /// Declared teleport entry.  The request is the source admission token; the
    /// handler revalidates it, so a fabricated request is `NotAdmitted`.
    pub fn beginTeleport(self: *Host, state: *travel.State, request: teleport_mod.Request, entry_id: []const u8) !void {
        if (self.teleport != null) return error.TeleportSessionBusy;
        const story = storyOf(state) orelse return error.MissingSourceStoryState;
        const entry: teleport_mod.Entry = .{
            .entry_id = entry_id,
            .content_sha256 = self.catalogue.viki.value.content_sha256,
            .receipt = state.travel_receipt + 1,
            .settled_receipt = state.travel_receipt,
            .money = state.combat.progress.money,
            .story = story,
            .story_bound = true,
            .world_mode = @intFromBool(state.link.travel.mode == .world),
            .item = .{},
            .castle_stage = 0,
        };
        var session = try teleport_mod.Session.open(&self.catalogue.viki.value, &self.catalogue.mirror.value, request, entry);
        // The session starts from the receipts this owner already settled.
        session.settled = state.travel_receipt;
        const bytes = try teleport_mod.save(session, self.allocator);
        defer self.allocator.free(bytes);
        self.teleport = try teleport_mod.load(self.allocator, bytes, &self.catalogue.viki.value, &self.catalogue.mirror.value);
        _ = &session;
    }

    fn currentFacts(self: *Host, state: *const travel.State) !teleport_mod.Facts {
        const story = storyOf(state) orelse return error.MissingSourceStoryState;
        const session = if (self.teleport) |*value| value else return error.NoTeleportSession;
        return .{
            .content_sha256 = self.catalogue.viki.value.content_sha256,
            .entry_id = session.session.entry.entry_id,
            .receipt = session.session.entry.receipt,
            .money = state.combat.progress.money,
            .story = story.scenario,
            .world_mode = @intFromBool(state.link.travel.mode == .world),
            .item = session.session.entry.item,
            .castle_stage = 0,
            .retained_point = session.session.entry.retained_point,
        };
    }

    /// Ordinary field input while the destination widget is open.  Up/down,
    /// confirm and cancel are the widget's own inputs; no key shortcut exists.
    pub fn tickTeleport(self: *Host, state: *travel.State, input: field.Input) !?travel.Event {
        const decoded = if (self.teleport) |*value| value else return null;
        const session = &decoded.session;
        const mapped: teleport_mod.Input = if (input.cancel) .cancel else if (input.action) .confirm else switch (input.menu_direction orelse return .none) {
            .up => .up,
            .down => .down,
            .left => .left,
            .right => .right,
        };
        const event = try session.tick(mapped);
        switch (event) {
            .none => return .none,
            .cancelled => {
                decoded.deinit();
                self.teleport = null;
                return .none;
            },
            .confirmed => |proposal| {
                const arrival = try self.resolveArrival(state, proposal.plan) orelse {
                    // The destination is source-valid but its room is not part
                    // of the attached package: refuse before consuming a receipt.
                    _ = try session.cancel();
                    return error.UnavailableDestination;
                };
                const receipt = try session.commit(try self.currentFacts(state));
                const kind: results.ResultKind = if (proposal.family == .viki) .travel_teleport else .travel_mirror;
                var result = results.Result{
                    .schema = try results.Id.init(results.result_schema),
                    .owner = .travel,
                    .kind = kind,
                    .entry_id = try results.Id.init(proposal.plan.result_entry_id),
                    .receipt = receipt.receipt,
                    .expected = try self.expectedFor(state, null),
                    .effect_count = 1,
                };
                const camera: results.Camera = if (proposal.plan.world_camera) |point| .{
                    .x = point.x,
                    .y = point.y,
                    .facing = .south,
                    .place = .world,
                } else .{
                    .x = proposal.plan.spawn.x,
                    .y = proposal.plan.spawn.y,
                    .facing = .south,
                    .place = .field,
                };
                result.effects[0] = .{ .kind = .camera, .payload = .{ .camera = camera } };
                try self.publish(state, result, null);
                if (state.link.travel.mode == .field) {
                    try state.reconstructFieldRoom(arrival.room, arrival.spawn, .down);
                } else {
                    try self.enterRoom(state, arrival.room, arrival.spawn, .down);
                    if (proposal.plan.world_camera) |point| {
                        state.link.travel.camera = .{ .x = point.x, .y = point.y };
                    }
                }
                decoded.deinit();
                self.teleport = null;
                return .field_entered;
            },
        }
    }

    const Arrival = struct { room: []const u8, spawn: field.Point };

    /// Join the source arrival (area file + room index) to the attached package
    /// through the route location identity.  The field spawn is the source
    /// half-cell * 8 the packet exported.
    fn resolveArrival(self: *const Host, state: *const travel.State, plan: teleport_mod.Plan) !?Arrival {
        _ = state;
        for (self.route_packet.value.locations) |location| {
            if (location.kind != .field_room) continue;
            if (!location.constructible) continue;
            const file = location.source_file orelse continue;
            if (!std.mem.eql(u8, file, plan.area)) continue;
            const room = location.source_room orelse continue;
            if (room != plan.room) continue;
            return .{ .room = location.id, .spawn = .{ .x = plan.spawn.x, .y = plan.spawn.y } };
        }
        return null;
    }

    fn enterRoom(self: *Host, state: *travel.State, room_id: []const u8, spawn: field.Point, facing: field.Direction) !void {
        _ = self;
        if (state.link.travel.mode != .world) return error.NotInFootWorld;
        // Reuse the production world-point entry that owns this room's identity
        // and world cell, so the port's saved position stays valid.
        for (state.link.content.points) |point| {
            const destination = point.destination orelse continue;
            const room_index = if (std.mem.eql(u8, destination, "village")) state.link.village else state.link.package.roomIndex(destination) orelse continue;
            if (!std.mem.eql(u8, state.link.package.rooms[room_index].id, room_id)) continue;
            if (spawn.x != point.spawn_x or spawn.y != point.spawn_y) return error.ArrivalSpawnMismatch;
            return state.enterFieldAtPoint(point.id, spawn, facing);
        }
        return error.UnknownWorldEntrance;
    }

    // ------------------------------------------------------------------
    // Durable state
    // ------------------------------------------------------------------

    pub fn capture(self: *Host) !Snapshot {
        _ = self.capture_arena.reset(.retain_capacity);
        const allocator = self.capture_arena.allocator();
        var snapshot: Snapshot = .{ .mode = self.mode() };
        snapshot.boat_ledger_json = try std.json.Stringify.valueAlloc(allocator, self.boat_ledger, .{});
        if (self.boat) |loaded| snapshot.boat_session_json = try loaded.session.encode(allocator, self.boat_packet.value);
        if (self.teleport) |decoded| snapshot.teleport_json = try teleport_mod.save(decoded.session, allocator);
        return snapshot;
    }

    /// Rebuild the durable mode state from the save envelope.  Every byte is
    /// revalidated by the package owner; a retired vessel id cannot be restored
    /// as an active vessel, and a teleport receipt already settled is refused.
    pub fn applySnapshot(self: *Host, snapshot: Snapshot) !void {
        if (self.teleport) |*decoded| decoded.deinit();
        self.teleport = null;
        if (self.boat) |*loaded| loaded.deinit();
        self.boat = null;
        self.boat_ledger = .{};
        if (snapshot.boat_ledger_json) |bytes| {
            if (bytes.len > 16 * 1024) return error.BoatSnapshotTooLarge;
            const parsed = try std.json.parseFromSlice(boat_mod.Ledger, self.allocator, bytes, .{ .allocate = .alloc_always });
            defer parsed.deinit();
            try parsed.value.validate();
            self.boat_ledger = parsed.value;
            // The parsed schema slice belongs to the temporary arena; keep the
            // package's literal so the ledger outlives the parse.
            self.boat_ledger.schema = boat_mod.boat.ledger_schema;
        }
        if (snapshot.boat_session_json) |bytes| {
            self.boat = try boat_mod.restoreSession(self.allocator, &self.boat_ledger, bytes, self.boat_packet.value);
        }
        if (snapshot.teleport_json) |bytes| {
            self.teleport = try teleport_mod.load(self.allocator, bytes, &self.catalogue.viki.value, &self.catalogue.mirror.value);
        }
        if (snapshot.mode != self.mode()) return error.InvalidCampaignMode;
    }
};

pub const review = struct {
    pub const route = "route cues, prefix order and destinations belong to travel.route_consumer";
    pub const boat = "board/steer/point/cleanup and the vessel ledger belong to travel.boat";
    pub const teleport = "admission, destination list and arrival plans belong to travel.teleport";
    pub const ground = "static ground queries and units belong to travel.ground";
    pub const transaction = "admission/publication/receipts use the shared campaign_policies.mode_result host";
    pub const no_rng = "no travel path draws from the RNG tape";
};

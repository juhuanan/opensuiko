//! Immutable content graph: decode, validate, resolve.
//!
//! Assembled from the packaged world/chapter inventories.  It carries
//! *identities, statuses and verified joins*, never PS1 addresses, LBAs,
//! pointers or dev-tree paths.  This module owns:
//!
//!   * strict decoding of the content graph and its pinned digests;
//!   * the cross-package reference rules: a resolved edge must land on a usable
//!     node, a mandatory scene must have resolved geometry or an exact visible
//!     blocker, and a cue request must land on packaged content;
//!   * the body digest, re-derived here from the decoded rows so a mutated or
//!     substituted graph is refused instead of trusted;
//!   * named queries for the runtime owners (scene geometry, actor identity,
//!     weapon/item identity, formation enemies, cue resolution).
//!
//! `residency.zig` owns selection lifetime on top of this read-only graph.

const std = @import("std");
const validation = @import("validation");

pub const schema = "suikoden-world-content-graph/1";
pub const revision = "world-content-graph.1";
pub const max_bytes = 8 * 1024 * 1024;

pub const Kind = enum {
    scene,
    room,
    support,
    scenery,
    actor,
    record,
    portrait,
    tablet,
    formation,
    enemy,
    effect,
    item,
    weapon,
    fragment,
    score,
    bank,
    stream,
    cue,
};

pub const Status = enum { qualified, partial, blocked, excluded, unsupported, external };

pub const EdgeKind = enum {
    geometry,
    support,
    scenery,
    scene_actor,
    actor_record,
    actor_portrait,
    actor_tablet,
    record_portrait,
    record_tablet,
    record_weapon,
    formation_enemy,
    formation_item,
    score_bank,
    cue_score,
    cue_stream,
    cue_bank,
};

pub const EdgeStatus = enum { resolved, qualified, partial, blocked, excluded, unsupported, external };

pub const Scope = enum { internal, external };

pub const Pack = struct {
    id: []const u8,
    version: []const u8,
    digest: []const u8,
    rows: u32,
};

pub const Node = struct {
    id: []const u8,
    kind: Kind,
    pack: []const u8,
    status: Status,
    key: []const u8,
    detail: []const u8,

    /// Human-readable identity carried by the packaging row (never a source
    /// pointer): e.g. `Cleo|cid:1`, `Wolf Fang Staff|family:1`.
    pub fn label(self: Node) []const u8 {
        const bar = std.mem.indexOfScalar(u8, self.key, '|') orelse return self.key;
        return self.key[0..bar];
    }
};

pub const Edge = struct {
    from: []const u8,
    kind: EdgeKind,
    to: []const u8,
    status: EdgeStatus,
    code: []const u8,
};

pub const Scene = struct {
    id: []const u8,
    mandatory: bool,
    closure: []const []const u8,
    blockers: []const []const u8,

    pub fn hasBlocker(self: Scene, code: []const u8) bool {
        for (self.blockers) |candidate| if (std.mem.eql(u8, candidate, code)) return true;
        return false;
    }
};

pub const Request = struct {
    id: []const u8,
    command: u32,
    kind: []const u8,
    status: EdgeStatus,
    target: []const u8,
    code: []const u8,

    pub fn resolved(self: Request) bool {
        return self.status == .resolved;
    }
};

pub const Blocker = struct {
    id: []const u8,
    code: []const u8,
    scope: Scope,
    detail: []const u8,
};

pub const Join = struct {
    id: []const u8,
    status: []const u8,
    detail: []const u8,

    pub fn verified(self: Join) bool {
        return std.mem.eql(u8, self.status, "verified");
    }
};

pub const Counts = struct {
    nodes: u32,
    edges: u32,
    scenes: u32,
    mandatory_scenes: u32,
    requests: u32,
    blockers: u32,
    joins: u32,
    dangling: u32,
    mandatory_unresolved: u32,
};

/// A resolved actor identity.  `resource_only` means the cid is a constructed
/// area actor whose *display identity* is unavailable; it is never joined to a
/// dialogue speaker code and never given an invented name.
pub const ActorIdentity = struct {
    cid: u32,
    name: []const u8,
    status: Status,
    record: ?u32,
    portrait: ?u32,
    tablet: ?u32,

    pub fn resourceOnly(self: ActorIdentity) bool {
        return self.record == null and self.portrait == null and self.status == .partial;
    }
};

pub const FormationRef = struct {
    id: []const u8,
    status: Status,
    enemies: u8,
    rewards: u8,
    blockers: u8,

    pub fn usable(self: FormationRef) bool {
        return self.status == .qualified and self.enemies > 0;
    }
};

pub const CueRef = struct {
    command: u32,
    id: []const u8,
    status: EdgeStatus,
    target: []const u8,
    target_kind: ?Kind,
    code: []const u8,
};

pub const Error = error{
    ContentTooLarge,
    ContentFileDigestMismatch,
    BodyDigestMismatch,
    UnsupportedSchema,
    UnsupportedRevision,
    InvalidPack,
    InvalidCounts,
    InvalidNode,
    InvalidEdge,
    InvalidScene,
    InvalidRequest,
    InvalidBlocker,
    InvalidJoin,
    DuplicateNode,
    DuplicateScene,
    DuplicateRequest,
    DuplicateBlocker,
    UnknownNodeKind,
    UnknownNodeStatus,
    UnknownEdgeKind,
    UnknownEdgeStatus,
    UnknownBlockerScope,
    DanglingReference,
    ResolvedToBlocked,
    MandatoryGeometricUnresolved,
    CountMismatch,
    UnknownScene,
    SceneBlocked,
    UnknownActor,
    UnknownWeapon,
    UnknownItem,
    UnknownFormation,
    UnknownCue,
    AmbiguousCommand,
    OutOfMemory,
};

fn parseKind(text: []const u8) Error!Kind {
    return std.meta.stringToEnum(Kind, text) orelse error.UnknownNodeKind;
}

fn parseStatus(text: []const u8) Error!Status {
    return std.meta.stringToEnum(Status, text) orelse error.UnknownNodeStatus;
}

fn parseEdgeKind(text: []const u8) Error!EdgeKind {
    return std.meta.stringToEnum(EdgeKind, text) orelse error.UnknownEdgeKind;
}

fn parseEdgeStatus(text: []const u8) Error!EdgeStatus {
    return std.meta.stringToEnum(EdgeStatus, text) orelse error.UnknownEdgeStatus;
}

fn parseScope(text: []const u8) Error!Scope {
    return std.meta.stringToEnum(Scope, text) orelse error.UnknownBlockerScope;
}

fn isHex64(text: []const u8) bool {
    return validation.isHex64(text);
}

pub fn parseSuffix(text: []const u8) ?u32 {
    const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse return null;
    return std.fmt.parseInt(u32, text[colon + 1 ..], 10) catch null;
}

const JsonNode = struct {
    id: []const u8,
    kind: []const u8,
    pack: []const u8,
    status: []const u8,
    key: []const u8 = "",
    detail: []const u8 = "",
};

const JsonEdge = struct {
    from: []const u8,
    kind: []const u8,
    to: []const u8,
    status: []const u8,
    code: []const u8 = "",
};

const JsonScene = struct {
    id: []const u8,
    mandatory: bool,
    closure: []const []const u8,
    blockers: []const []const u8,
};

const JsonRequest = struct {
    id: []const u8,
    command: u32,
    kind: []const u8,
    status: []const u8,
    target: []const u8 = "",
    code: []const u8 = "",
};

const JsonBlocker = struct {
    id: []const u8,
    code: []const u8,
    status: []const u8,
    detail: []const u8 = "",
};

const JsonJoin = struct {
    id: []const u8,
    status: []const u8,
    detail: []const u8 = "",
};

const JsonPack = struct {
    id: []const u8,
    version: []const u8,
    digest: []const u8,
    rows: u32,
};

const JsonCounts = struct {
    nodes: u32,
    edges: u32,
    scenes: u32,
    mandatory_scenes: u32,
    requests: u32,
    blockers: u32,
    joins: u32,
    dangling: u32,
    mandatory_unresolved: u32,
};

const RawGraph = struct {
    schema: []const u8,
    revision: []const u8,
    packs: []const JsonPack,
    counts: JsonCounts,
    nodes: []const JsonNode,
    edges: []const JsonEdge,
    scenes: []const JsonScene,
    requests: []const JsonRequest,
    blockers: []const JsonBlocker,
    joins: []const JsonJoin,
    body_sha256: []const u8,
};

pub const Graph = struct {
    arena: std.heap.ArenaAllocator,
    packs: []Pack,
    nodes: []Node,
    edges: []Edge,
    scenes: []Scene,
    requests: []Request,
    blockers: []Blocker,
    joins: []Join,
    counts: Counts,
    body_sha256: []const u8,
    revision: []const u8,
    node_index: std.StringHashMapUnmanaged(u32) = .{},
    scene_index: std.StringHashMapUnmanaged(u32) = .{},
    command_index: std.AutoHashMapUnmanaged(u32, u32) = .{},

    /// Decode, verify the pinned digests and validate every reference.  The
    /// returned graph borrows its own arena and must be freed through `deinit`.
    pub fn load(backing: std.mem.Allocator, bytes: []const u8, expected_file_sha256: []const u8, expected_body_sha256: []const u8) !*Graph {
        if (bytes.len > max_bytes) return error.ContentTooLarge;
        var file_digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &file_digest, .{});
        if (!std.mem.eql(u8, &std.fmt.bytesToHex(file_digest, .lower), expected_file_sha256)) return error.ContentFileDigestMismatch;

        const self = try backing.create(Graph);
        errdefer backing.destroy(self);
        self.* = .{
            .arena = std.heap.ArenaAllocator.init(backing),
            .packs = &.{},
            .nodes = &.{},
            .edges = &.{},
            .scenes = &.{},
            .requests = &.{},
            .blockers = &.{},
            .joins = &.{},
            .counts = std.mem.zeroes(Counts),
            .body_sha256 = "",
            .revision = "",
        };
        errdefer self.arena.deinit();
        const arena = self.arena.allocator();

        const raw = try std.json.parseFromSliceLeaky(RawGraph, arena, bytes, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        if (!std.mem.eql(u8, raw.schema, schema)) return error.UnsupportedSchema;
        if (!std.mem.eql(u8, raw.revision, revision)) return error.UnsupportedRevision;
        if (!isHex64(raw.body_sha256)) return error.InvalidCounts;
        if (!std.mem.eql(u8, raw.body_sha256, expected_body_sha256)) return error.BodyDigestMismatch;

        // -- packs ---------------------------------------------------------
        if (raw.packs.len == 0 or raw.packs.len > 32) return error.InvalidPack;
        self.packs = try arena.alloc(Pack, raw.packs.len);
        for (raw.packs, 0..) |source, index| {
            if (source.id.len == 0 or source.version.len == 0 or source.rows == 0 or !isHex64(source.digest)) return error.InvalidPack;
            for (self.packs[0..index]) |prior| if (std.mem.eql(u8, prior.id, source.id)) return error.InvalidPack;
            self.packs[index] = .{
                .id = try arena.dupe(u8, source.id),
                .version = try arena.dupe(u8, source.version),
                .digest = try arena.dupe(u8, source.digest),
                .rows = source.rows,
            };
        }

        // -- nodes ---------------------------------------------------------
        if (raw.nodes.len == 0 or raw.nodes.len != raw.counts.nodes) return error.CountMismatch;
        self.nodes = try arena.alloc(Node, raw.nodes.len);
        try self.node_index.ensureTotalCapacity(arena, @intCast(raw.nodes.len));
        for (raw.nodes, 0..) |source, index| {
            if (source.id.len == 0 or source.id.len > 160 or source.detail.len > 512) return error.InvalidNode;
            const kind = try parseKind(source.kind);
            const status = try parseStatus(source.status);
            if (!self.packKnown(source.pack)) return error.InvalidNode;
            const record: Node = .{
                .id = try arena.dupe(u8, source.id),
                .kind = kind,
                .pack = try arena.dupe(u8, source.pack),
                .status = status,
                .key = try arena.dupe(u8, source.key),
                .detail = try arena.dupe(u8, source.detail),
            };
            const entry = try self.node_index.getOrPut(arena, record.id);
            if (entry.found_existing) return error.DuplicateNode;
            entry.value_ptr.* = @intCast(index);
            self.nodes[index] = record;
        }

        // -- edges ---------------------------------------------------------
        if (raw.edges.len != raw.counts.edges) return error.CountMismatch;
        self.edges = try arena.alloc(Edge, raw.edges.len);
        for (raw.edges, 0..) |source, index| {
            const from = self.node(source.from) orelse return error.DanglingReference;
            const to = self.node(source.to) orelse return error.DanglingReference;
            const status = try parseEdgeStatus(source.status);
            if (source.code.len > 120) return error.InvalidEdge;
            if (status == .resolved and (to.status == .blocked or to.status == .unsupported or to.status == .excluded)) return error.ResolvedToBlocked;
            if (from.kind == .scene and to.kind == .scene) return error.InvalidEdge;
            self.edges[index] = .{
                .from = from.id,
                .kind = try parseEdgeKind(source.kind),
                .to = to.id,
                .status = status,
                .code = try arena.dupe(u8, source.code),
            };
        }

        // -- scenes --------------------------------------------------------
        if (raw.scenes.len != raw.counts.scenes) return error.CountMismatch;
        self.scenes = try arena.alloc(Scene, raw.scenes.len);
        var mandatory: u32 = 0;
        for (raw.scenes, 0..) |source, index| {
            const scene_node = self.node(source.id) orelse return error.DanglingReference;
            if (scene_node.kind != .scene or source.closure.len == 0 or source.closure.len > 4096) return error.InvalidScene;
            for (source.closure) |member| if (self.node(member) == null) return error.DanglingReference;
            const closure = try arena.alloc([]const u8, source.closure.len);
            for (source.closure, 0..) |member, slot| closure[slot] = self.node(member).?.id;
            const blockers = try arena.alloc([]const u8, source.blockers.len);
            for (source.blockers, 0..) |code, slot| {
                if (code.len == 0 or code.len > 120) return error.InvalidScene;
                blockers[slot] = try arena.dupe(u8, code);
            }
            const entry = try self.scene_index.getOrPut(arena, scene_node.id);
            if (entry.found_existing) return error.DuplicateScene;
            entry.value_ptr.* = @intCast(index);
            self.scenes[index] = .{ .id = scene_node.id, .mandatory = source.mandatory, .closure = closure, .blockers = blockers };
            if (source.mandatory) mandatory += 1;
        }
        if (mandatory != raw.counts.mandatory_scenes) return error.CountMismatch;

        // -- requests ------------------------------------------------------
        if (raw.requests.len != raw.counts.requests) return error.CountMismatch;
        self.requests = try arena.alloc(Request, raw.requests.len);
        try self.command_index.ensureTotalCapacity(arena, @intCast(raw.requests.len));
        for (raw.requests, 0..) |source, index| {
            if (source.id.len == 0 or source.kind.len == 0 or source.kind.len > 40) return error.InvalidRequest;
            const status = try parseEdgeStatus(source.status);
            if (status == .resolved) {
                if (source.target.len == 0) return error.InvalidRequest;
                _ = self.node(source.target) orelse return error.DanglingReference;
            } else if (source.code.len == 0) {
                // An unresolved/excluded branch must say why; silence is not a status.
                return error.InvalidRequest;
            }
            const entry = try self.command_index.getOrPut(arena, source.command);
            if (entry.found_existing) return error.DuplicateRequest;
            entry.value_ptr.* = @intCast(index);
            self.requests[index] = .{
                .id = try arena.dupe(u8, source.id),
                .command = source.command,
                .kind = try arena.dupe(u8, source.kind),
                .status = status,
                .target = try arena.dupe(u8, source.target),
                .code = try arena.dupe(u8, source.code),
            };
        }

        // -- blockers / joins ---------------------------------------------
        if (raw.blockers.len != raw.counts.blockers) return error.CountMismatch;
        self.blockers = try arena.alloc(Blocker, raw.blockers.len);
        for (raw.blockers, 0..) |source, index| {
            if (source.id.len == 0 or source.code.len == 0 or source.detail.len > 512) return error.InvalidBlocker;
            for (self.blockers[0..index]) |prior| if (std.mem.eql(u8, prior.id, source.id)) return error.DuplicateBlocker;
            self.blockers[index] = .{
                .id = try arena.dupe(u8, source.id),
                .code = try arena.dupe(u8, source.code),
                .scope = try parseScope(source.status),
                .detail = try arena.dupe(u8, source.detail),
            };
        }
        if (raw.joins.len != raw.counts.joins) return error.CountMismatch;
        self.joins = try arena.alloc(Join, raw.joins.len);
        for (raw.joins, 0..) |source, index| {
            if (source.id.len == 0 or source.status.len == 0 or source.status.len > 32) return error.InvalidJoin;
            self.joins[index] = .{
                .id = try arena.dupe(u8, source.id),
                .status = try arena.dupe(u8, source.status),
                .detail = try arena.dupe(u8, source.detail),
            };
        }

        self.counts = .{
            .nodes = raw.counts.nodes,
            .edges = raw.counts.edges,
            .scenes = raw.counts.scenes,
            .mandatory_scenes = raw.counts.mandatory_scenes,
            .requests = raw.counts.requests,
            .blockers = raw.counts.blockers,
            .joins = raw.counts.joins,
            .dangling = raw.counts.dangling,
            .mandatory_unresolved = raw.counts.mandatory_unresolved,
        };
        self.body_sha256 = try arena.dupe(u8, raw.body_sha256);
        self.revision = try arena.dupe(u8, raw.revision);
        if (self.counts.dangling != 0) return error.DanglingReference;
        try self.verifyBody();
        try self.verifyMandatoryScenes();
        return self;
    }

    pub fn deinit(self: *Graph) void {
        const backing = self.arena.child_allocator;
        // The index maps are arena-backed; the arena release below owns them.
        self.arena.deinit();
        backing.destroy(self);
    }

    fn packKnown(self: *const Graph, id: []const u8) bool {
        for (self.packs) |pack| if (std.mem.eql(u8, pack.id, id)) return true;
        return false;
    }

    pub fn node(self: *const Graph, id: []const u8) ?*const Node {
        const index = self.node_index.get(id) orelse return null;
        return &self.nodes[index];
    }

    pub fn require(self: *const Graph, id: []const u8) Error!*const Node {
        return self.node(id) orelse error.DanglingReference;
    }

    /// `id` may be the scene node id (`scene:vb6_room0`) or the packaged scene
    /// name (`vb6_room0`); the two are the same selection.
    pub fn sceneOf(self: *const Graph, id: []const u8) ?*const Scene {
        if (self.scene_index.get(id)) |index| return &self.scenes[index];
        if (std.mem.indexOfScalar(u8, id, ':') != null) return null;
        var buffer: [172]u8 = undefined;
        if (id.len + 6 > buffer.len) return null;
        const prefixed = std.fmt.bufPrint(&buffer, "scene:{s}", .{id}) catch return null;
        const index = self.scene_index.get(prefixed) orelse return null;
        return &self.scenes[index];
    }

    pub fn requireScene(self: *const Graph, id: []const u8) Error!*const Scene {
        return self.sceneOf(id) orelse error.UnknownScene;
    }

    /// The scene's resolved geometry edge target, if any.  A blocked geometry
    /// edge is returned with its exact code so a caller cannot mistake it for a
    /// usable room.
    pub const Geometry = struct { room: *const Node, status: EdgeStatus, code: []const u8 };

    pub fn geometry(self: *const Graph, scene_id: []const u8) Error!Geometry {
        const scene = try self.requireScene(scene_id);
        for (self.edges) |edge| {
            if (edge.kind != .geometry or !std.mem.eql(u8, edge.from, scene.id)) continue;
            const room = self.node(edge.to) orelse return error.DanglingReference;
            return .{ .room = room, .status = edge.status, .code = edge.code };
        }
        return error.MandatoryGeometricUnresolved;
    }

    pub fn edgesFrom(self: *const Graph, id: []const u8, kind: EdgeKind) EdgeIterator {
        return .{ .graph = self, .from = id, .kind = kind };
    }

    pub const EdgeIterator = struct {
        graph: *const Graph,
        from: []const u8,
        kind: EdgeKind,
        cursor: usize = 0,

        pub fn next(self: *EdgeIterator) ?*const Edge {
            while (self.cursor < self.graph.edges.len) {
                const edge = &self.graph.edges[self.cursor];
                self.cursor += 1;
                if (edge.kind == self.kind and std.mem.eql(u8, edge.from, self.from)) return edge;
            }
            return null;
        }
    };

    /// Resolve an actor cid to its display identity.  A cid that exists only as
    /// an area resource returns `record == null`; it is never given a name and a
    /// speaker code of the same number is a different space.
    pub fn actorIdentity(self: *const Graph, cid: u32) Error!ActorIdentity {
        var buffer: [24]u8 = undefined;
        const id = std.fmt.bufPrint(&buffer, "actor:{d}", .{cid}) catch return error.UnknownActor;
        const actor_node = self.node(id) orelse return error.UnknownActor;
        var result: ActorIdentity = .{
            .cid = cid,
            .name = actor_node.label(),
            .status = actor_node.status,
            .record = null,
            .portrait = null,
            .tablet = null,
        };
        var iterator = self.edgesFrom(actor_node.id, .actor_record);
        while (iterator.next()) |edge| {
            if (edge.status == .resolved) result.record = parseSuffix(edge.to);
        }
        iterator = self.edgesFrom(actor_node.id, .actor_portrait);
        while (iterator.next()) |edge| {
            if (edge.status == .resolved) result.portrait = parseSuffix(edge.to);
        }
        iterator = self.edgesFrom(actor_node.id, .actor_tablet);
        while (iterator.next()) |edge| {
            if (edge.status == .resolved) result.tablet = parseSuffix(edge.to);
        }
        return result;
    }

    pub fn weaponStatus(self: *const Graph, weapon_id: u32) Error!Status {
        var buffer: [24]u8 = undefined;
        const id = std.fmt.bufPrint(&buffer, "weapon:{d}", .{weapon_id}) catch return error.UnknownWeapon;
        const weapon_node = self.node(id) orelse return error.UnknownWeapon;
        return weapon_node.status;
    }

    pub fn itemStatus(self: *const Graph, item_id: u32) Error!Status {
        var buffer: [24]u8 = undefined;
        const id = std.fmt.bufPrint(&buffer, "item:{d}", .{item_id}) catch return error.UnknownItem;
        const item_node = self.node(id) orelse return error.UnknownItem;
        return item_node.status;
    }

    /// A formation resolves when it names at least one packaged enemy record;
    /// its action readiness is a separate status the caller must not skip.
    pub fn formationRef(self: *const Graph, formation_id: []const u8) Error!FormationRef {
        var id_buffer: [160]u8 = undefined;
        const id = std.fmt.bufPrint(&id_buffer, "formation:{s}", .{formation_id}) catch return error.UnknownFormation;
        const formation_node = self.node(id) orelse return error.UnknownFormation;
        var result: FormationRef = .{ .id = formation_node.id, .status = formation_node.status, .enemies = 0, .rewards = 0, .blockers = 0 };
        var iterator = self.edgesFrom(formation_node.id, .formation_enemy);
        while (iterator.next()) |edge| {
            if (edge.status == .resolved) {
                result.enemies += 1;
            } else {
                result.blockers += 1;
            }
        }
        iterator = self.edgesFrom(formation_node.id, .formation_item);
        while (iterator.next()) |edge| {
            if (edge.status == .resolved) result.rewards += 1;
        }
        return result;
    }

    pub fn requestByCommand(self: *const Graph, command: u32) Error!*const Request {
        const index = self.command_index.get(command) orelse return error.UnknownCue;
        return &self.requests[index];
    }

    /// Resolve a source cue command to packaged content.  An excluded command
    /// keeps its typed code; a resolved one names the target node kind so a cue
    /// cannot masquerade as a different resource family.
    pub fn resolveCue(self: *const Graph, command: u32) Error!CueRef {
        const request = try self.requestByCommand(command);
        var kind: ?Kind = null;
        if (request.target.len != 0) {
            const target_node = self.node(request.target) orelse return error.DanglingReference;
            kind = target_node.kind;
        }
        if (request.status == .resolved and kind == null) return error.DanglingReference;
        return .{
            .command = command,
            .id = request.id,
            .status = request.status,
            .target = request.target,
            .target_kind = kind,
            .code = request.code,
        };
    }

    /// Re-derive the body digest from the decoded rows.  The canonical line
    /// encoding is written a second time by the assembler tool; agreeing here is
    /// what makes the pinned body digest meaningful.
    pub fn verifyBody(self: *const Graph) Error!void {
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(self.arena.child_allocator);
        const allocator = self.arena.child_allocator;
        var first = true;
        for (self.packs) |pack| {
            try self.appendLine(allocator, &list, &first, "P|{s}|{s}|{s}|{d}", .{ pack.id, pack.version, pack.digest, pack.rows });
        }
        for (self.nodes) |item| {
            try self.appendLine(allocator, &list, &first, "N|{s}|{s}|{s}|{s}|{s}", .{
                item.id,
                @tagName(item.kind),
                item.pack,
                @tagName(item.status),
                item.key,
            });
        }
        for (self.edges) |edge| {
            try self.appendLine(allocator, &list, &first, "E|{s}|{s}|{s}|{s}|{s}", .{
                edge.from,
                @tagName(edge.kind),
                edge.to,
                @tagName(edge.status),
                edge.code,
            });
        }
        for (self.scenes) |scene| {
            var closure_len: usize = 0;
            for (scene.closure) |member| closure_len += member.len + 1;
            var blockers_len: usize = 0;
            for (scene.blockers) |code| blockers_len += code.len + 1;
            const buffer = try allocator.alloc(u8, closure_len + blockers_len + 16);
            defer allocator.free(buffer);
            var cursor: usize = 0;
            @memcpy(buffer[cursor..][0..2], if (scene.mandatory) "1|" else "0|");
            cursor += 2;
            for (scene.closure, 0..) |member, index| {
                if (index != 0) {
                    buffer[cursor] = ',';
                    cursor += 1;
                }
                @memcpy(buffer[cursor..][0..member.len], member);
                cursor += member.len;
            }
            buffer[cursor] = '|';
            cursor += 1;
            for (scene.blockers, 0..) |code, index| {
                if (index != 0) {
                    buffer[cursor] = ',';
                    cursor += 1;
                }
                @memcpy(buffer[cursor..][0..code.len], code);
                cursor += code.len;
            }
            try self.appendLine(allocator, &list, &first, "S|{s}|{s}", .{ scene.id, buffer[0..cursor] });
        }
        for (self.requests) |request| {
            try self.appendLine(allocator, &list, &first, "R|{s}|{d}|{s}|{s}|{s}|{s}", .{
                request.id,
                request.command,
                request.kind,
                @tagName(request.status),
                request.target,
                request.code,
            });
        }
        for (self.blockers) |blocker| {
            try self.appendLine(allocator, &list, &first, "B|{s}|{s}|{s}", .{ blocker.id, blocker.code, @tagName(blocker.scope) });
        }
        for (self.joins) |join| {
            try self.appendLine(allocator, &list, &first, "J|{s}|{s}", .{ join.id, join.status });
        }
        try self.appendLine(allocator, &list, &first, "C|{d}|{d}|{d}|{d}|{d}|{d}", .{
            self.counts.nodes,
            self.counts.edges,
            self.counts.scenes,
            self.counts.requests,
            self.counts.blockers,
            self.counts.joins,
        });
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(list.items, &digest, .{});
        if (!std.mem.eql(u8, &std.fmt.bytesToHex(digest, .lower), self.body_sha256)) return error.BodyDigestMismatch;
    }

    fn appendLine(self: *const Graph, allocator: std.mem.Allocator, list: *std.ArrayList(u8), first: *bool, comptime format: []const u8, args: anytype) Error!void {
        _ = self;
        if (!first.*) try list.append(allocator, '\n');
        first.* = false;
        const line = std.fmt.allocPrint(allocator, format, args) catch return error.OutOfMemory;
        defer allocator.free(line);
        try list.appendSlice(allocator, line);
    }

    /// A mandatory scene must resolve usable geometry, or state the exact reason
    /// why it does not.  A mandatory scene with an unexplained missing room is a
    /// broken graph, not a partial one.
    fn verifyMandatoryScenes(self: *const Graph) Error!void {
        for (self.scenes) |scene| {
            const blocked = scene.hasBlocker("mandatory-geometry-unresolved");
            if (blocked) {
                if (scene.blockers.len < 2) return error.MandatoryGeometricUnresolved;
                for (scene.blockers) |code| {
                    if (std.mem.eql(u8, code, "mandatory-geometry-unresolved")) continue;
                    if (!self.blockerCodeKnown(code)) return error.InvalidScene;
                }
                continue;
            }
            if (!scene.mandatory) continue;
            const placement = self.geometry(scene.id) catch |err| switch (err) {
                error.MandatoryGeometricUnresolved => return error.MandatoryGeometricUnresolved,
                else => return err,
            };
            if (placement.status != .resolved) return error.MandatoryGeometricUnresolved;
            if (placement.room.status != .qualified) return error.ResolvedToBlocked;
        }
    }

    fn blockerCodeKnown(self: *const Graph, code: []const u8) bool {
        for (self.blockers) |blocker| if (std.mem.eql(u8, blocker.code, code)) return true;
        return false;
    }
};

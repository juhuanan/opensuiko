//! Scene selection, residency and rebinding on the assembled graph.
//!
//! The graph is immutable; this module owns the *lifetime* around it:
//!
//!   * a scene selection admits the exact closure the assembler recorded, and
//!     refuses a scene whose geometry is blocked or missing (no blank layer, no
//!     nearest anchor);
//!   * the admitted set is refcounted per node id, so a room transition releases
//!     only what the previous scene owned;
//!   * `Snapshot` carries content digests, not pointers: `restore` re-derives the
//!     closure from the packaged graph and refuses a snapshot from another
//!     revision, body or closure (a save cannot be replayed against substituted
//!     content);
//!   * a `Selection` from a previous host generation is refused, which is the
//!     explicit replacement for holding a RAM pointer across a reload.

const std = @import("std");
const graph_mod = @import("graph.zig");

pub const Graph = graph_mod.Graph;
pub const Node = graph_mod.Node;
pub const Scene = graph_mod.Scene;

pub const Snapshot = struct {
    revision: []const u8,
    body_sha256: []const u8,
    scene: []const u8,
    closure_sha256: []const u8,
};

pub const Selection = struct {
    /// Qualified scene node id (`scene:vb6_room0`).
    scene: []const u8,
    generation: u32,
    closure_len: u32,
    closure_sha256: []const u8,

    /// The packaged scene name without the graph namespace prefix.
    pub fn sceneName(self: Selection) []const u8 {
        return if (std.mem.startsWith(u8, self.scene, "scene:")) self.scene["scene:".len..] else self.scene;
    }
};

pub const Error = graph_mod.Error || error{
    SceneBlocked,
    SceneHasNoUsableGeometry,
    StaleSelection,
    ContentChanged,
    SelectionNotAdmitted,
    SelectionCountOverflow,
};

pub const Host = struct {
    arena: *std.heap.ArenaAllocator,
    graph: *Graph,
    admitted: std.StringHashMapUnmanaged(u32) = .{},
    generation: u32 = 0,
    loads: u32 = 0,

    /// Load the packaged graph and admit the whole qualified set once, so a
    /// missing or blocked node is refused at boot instead of at the first room.
    pub fn open(backing: std.mem.Allocator, bytes: []const u8, expected_file_sha256: []const u8, expected_body_sha256: []const u8) !*Host {
        const self = try backing.create(Host);
        errdefer backing.destroy(self);
        self.* = .{
            .arena = try backing.create(std.heap.ArenaAllocator),
            .graph = undefined,
        };
        self.arena.* = std.heap.ArenaAllocator.init(backing);
        errdefer {
            self.arena.deinit();
            backing.destroy(self.arena);
        }
        self.graph = try Graph.load(backing, bytes, expected_file_sha256, expected_body_sha256);
        errdefer self.graph.deinit();
        try self.admitQualifiedSet();
        return self;
    }

    pub fn deinit(self: *Host) void {
        self.admitted.deinit(self.arena.child_allocator);
        self.generation +%= 1;
        self.graph.deinit();
        const arena = self.arena;
        const backing = arena.child_allocator;
        arena.deinit();
        backing.destroy(arena);
        backing.destroy(self);
    }

    /// Every node the qualified graph declares is available to a selection.
    /// Admission here is the *identity* residency check: the node exists, its
    /// package row is present, and its status is not a silent placeholder.
    fn admitQualifiedSet(self: *Host) !void {
        const allocator = self.arena.child_allocator;
        try self.admitted.ensureTotalCapacity(allocator, @intCast(self.graph.nodes.len));
        for (self.graph.nodes) |item| {
            const entry = try self.admitted.getOrPut(allocator, item.id);
            if (!entry.found_existing) entry.value_ptr.* = 0;
        }
        for (self.graph.blockers) |blocker| {
            if (blocker.scope == .external) continue;
            if (blocker.code.len == 0) return error.InvalidBlocker;
        }
    }

    pub fn residentCount(self: *const Host) usize {
        var count: usize = 0;
        var iterator = self.admitted.iterator();
        while (iterator.next()) |entry| if (entry.value_ptr.* != 0) {
            count += 1;
        };
        return count;
    }

    pub fn resident(self: *const Host, id: []const u8) bool {
        return (self.admitted.get(id) orelse 0) != 0;
    }

    /// Admit the scene's exact closure.  A scene whose geometry edge is blocked
    /// or absent is refused with `SceneHasNoUsableGeometry`; a scene node that is
    /// itself blocked/excluded is refused with `SceneBlocked`.  Both are visible
    /// source branches, never silently substituted.
    pub fn admitScene(self: *Host, scene_id: []const u8) !Selection {
        const scene = try self.graph.requireScene(scene_id);
        const scene_node = try self.graph.require(scene.id);
        if (scene_node.status == .blocked or scene_node.status == .excluded or scene_node.status == .unsupported) return error.SceneBlocked;
        const placement = self.graph.geometry(scene.id) catch return error.SceneHasNoUsableGeometry;
        if (placement.status != .resolved or placement.room.status != .qualified) return error.SceneHasNoUsableGeometry;

        const allocator = self.arena.child_allocator;
        for (scene.closure) |member| {
            const member_node = self.graph.node(member) orelse return error.DanglingReference;
            if (member_node.status == .blocked or member_node.status == .excluded or member_node.status == .unsupported) {
                if (!scene.hasBlocker(placement.code) and !scene.hasBlocker("room-blocked")) return error.SceneBlocked;
            }
            const entry = try self.admitted.getOrPut(allocator, member_node.id);
            if (entry.value_ptr.* == std.math.maxInt(u32)) return error.SelectionCountOverflow;
            entry.value_ptr.* += 1;
        }
        self.generation +%= 1;
        self.loads +%= 1;
        return .{
            .scene = scene.id,
            .generation = self.generation,
            .closure_len = @intCast(scene.closure.len),
            .closure_sha256 = try self.closureDigest(scene),
        };
    }

    /// Release exactly the closure the selection admitted.  A selection from
    /// another generation is refused instead of decrementing unrelated members.
    pub fn release(self: *Host, selection: Selection) !void {
        if (selection.generation != self.generation) return error.StaleSelection;
        const scene = self.graph.sceneOf(selection.scene) orelse return error.UnknownScene;
        if (!std.mem.eql(u8, try self.closureDigest(scene), selection.closure_sha256)) return error.ContentChanged;
        for (scene.closure) |member| {
            const entry = self.admitted.getEntry(member) orelse return error.SelectionNotAdmitted;
            if (entry.value_ptr.* == 0) return error.SelectionNotAdmitted;
            entry.value_ptr.* -= 1;
        }
        self.generation +%= 1;
    }

    pub fn snapshot(self: *Host, selection: Selection) !Snapshot {
        const scene = self.graph.sceneOf(selection.scene) orelse return error.UnknownScene;
        return .{
            .revision = self.graph.revision,
            .body_sha256 = self.graph.body_sha256,
            .scene = scene.id,
            .closure_sha256 = selection.closure_sha256,
        };
    }

    /// Rebind a captured selection against the packaged graph.  The scene id is
    /// re-resolved, the closure is re-derived and compared, and the admission is
    /// repeated -- a stale or substituted content set is refused.
    pub fn restore(self: *Host, saved: Snapshot) !Selection {
        if (!std.mem.eql(u8, saved.revision, self.graph.revision)) return error.ContentChanged;
        if (!std.mem.eql(u8, saved.body_sha256, self.graph.body_sha256)) return error.ContentChanged;
        const scene = self.graph.sceneOf(saved.scene) orelse return error.UnknownScene;
        // A snapshot may only target a scene whose geometry is usable; the
        // admissibility check runs before the closure comparison so a blocked
        // scene reports its exact refusal instead of a generic digest mismatch.
        const placement = self.graph.geometry(scene.id) catch return error.SceneHasNoUsableGeometry;
        if (placement.status != .resolved or placement.room.status != .qualified) return error.SceneHasNoUsableGeometry;
        const digest = try self.closureDigest(scene);
        if (!std.mem.eql(u8, digest, saved.closure_sha256)) return error.ContentChanged;
        const selection = try self.admitScene(scene.id);
        if (!std.mem.eql(u8, selection.closure_sha256, saved.closure_sha256)) return error.ContentChanged;
        return selection;
    }

    pub fn closureDigest(self: *Host, scene: *const Scene) ![]const u8 {
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(self.arena.child_allocator);
        for (scene.closure, 0..) |member, index| {
            if (index != 0) try list.append(self.arena.child_allocator, '\n');
            try list.appendSlice(self.arena.child_allocator, member);
        }
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(list.items, &digest, .{});
        return try self.arena.allocator().dupe(u8, &std.fmt.bytesToHex(digest, .lower));
    }
};

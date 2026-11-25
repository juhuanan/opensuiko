//! Cross-mode logical input recovery.
//!
//! This layer does not sample devices and does not compute edges: the existing
//! `controller.State` adapter owns edge filtering, and this gate only decides
//! whether an already-filtered logical frame may be consumed by the current
//! mode.  A focus regain, a controller reconnect or a mode change closes the
//! gate; it reopens only after a fully neutral frame, so a button that was held
//! through the transition can never become an ordinary confirm/menu action.

const std = @import("std");
const controller = @import("pause_menu");
const field = @import("field");
const diagnostic = @import("diagnostic.zig");
const mode = @import("mode.zig");

pub const Mode = mode.Mode;
pub const Direction = field.Direction;

/// One logical input lease.  A mode owns it; adapters that need exclusive input
/// (for example a native text entry surface) acquire the same lease.  Failed
/// acquisition and a non-owner release are readable errors and change nothing.
pub const Lease = struct {
    owner: Mode = .title,
    held: bool = false,
    acquisitions: u32 = 0,
    releases: u32 = 0,
    refusals: u32 = 0,

    pub fn acquire(self: *Lease, next: Mode) !void {
        if (self.held) {
            self.refusals +|= 1;
            return error.InputOwned;
        }
        self.owner = next;
        self.held = true;
        self.acquisitions +|= 1;
    }

    pub fn release(self: *Lease, next: Mode) !void {
        if (!self.held or self.owner != next) {
            self.refusals +|= 1;
            return error.NotInputOwner;
        }
        self.held = false;
        self.releases +|= 1;
    }

    /// Atomic transfer used by a mode change: the lease is never observably
    /// unowned, and exactly one release + one acquisition happens per change.
    pub fn transfer(self: *Lease, next: Mode) void {
        if (!self.held) {
            self.owner = next;
            self.held = true;
            self.acquisitions +|= 1;
            return;
        }
        self.owner = next;
        self.held = true;
        self.releases +|= 1;
        self.acquisitions +|= 1;
    }

    pub fn reset(self: *Lease) void {
        self.* = .{};
    }
};

pub const Held = struct {
    direction: ?Direction = null,
    confirm: bool = false,
    cancel: bool = false,
    menu: bool = false,
    physical_up: bool = false,
};

pub const Counters = struct {
    frames: u32 = 0,
    rearmed_frames: u32 = 0,
    closed_frames: u32 = 0,
    suppressed_confirms: u32 = 0,
    suppressed_cancels: u32 = 0,
    suppressed_menus: u32 = 0,
    suppressed_directions: u32 = 0,
    suppressed_physical_up: u32 = 0,
    refocuses: u32 = 0,
    reconnects: u32 = 0,
    mode_changes: u32 = 0,
    device_transitions: u32 = 0,
};

pub fn isNeutral(out: controller.Output) bool {
    return out.direction == null and
        out.navigation == null and
        !out.confirm and
        !out.cancel and
        !out.menu and
        !out.physical_up;
}

pub const Gate = struct {
    lease: Lease = .{},
    focused: bool = false,
    armed: bool = false,
    device_present: bool = false,
    device_id: ?i32 = null,
    held: Held = .{},
    counters: Counters = .{},

    /// Focus loss drops every held logical input immediately.  Regaining focus
    /// requires a neutral frame before any ordinary action is forwarded.
    pub fn setFocus(self: *Gate, focused: bool) void {
        if (focused == self.focused) return;
        self.focused = focused;
        self.armed = false;
        self.held = .{};
        if (focused) self.counters.refocuses +|= 1;
    }

    /// A reconnect is a device transition: the previous device's held state is
    /// gone, so the gate closes until the ordinary controls are released.
    /// Repeated calls with the same present/id are a no-op (they must not keep
    /// swallowing ordinary input).
    pub fn setDevice(self: *Gate, present: bool, id: ?i32) void {
        if (present == self.device_present and id == self.device_id) return;
        self.device_present = present;
        self.device_id = id;
        self.armed = false;
        self.held = .{};
        self.counters.device_transitions +|= 1;
        if (present) self.counters.reconnects +|= 1;
    }

    /// Claim input for a mode outside a coordinated mode change.
    pub fn claim(self: *Gate, next: Mode) !void {
        try self.lease.acquire(next);
        self.armed = false;
        self.held = .{};
    }

    pub fn release(self: *Gate, next: Mode) !void {
        try self.lease.release(next);
        self.armed = false;
        self.held = .{};
    }

    pub const Entry = struct {
        previous: Mode,
        current: Mode,
        changed: bool,
        released_held: bool,
        armed: bool,
    };

    /// Cross-mode transfer.  Repeating the same mode is idempotent: it neither
    /// re-acquires the lease nor closes the gate, so repeated mode reports from
    /// a caller cannot leak a logical resource.
    pub fn enter(self: *Gate, next: Mode) Entry {
        const previous = self.lease.owner;
        if (previous == next and self.lease.held) {
            return .{ .previous = previous, .current = next, .changed = false, .released_held = false, .armed = self.armed };
        }
        if (!self.lease.held) {
            self.lease.acquire(next) catch unreachable;
        } else {
            self.lease.transfer(next);
        }
        const released = self.held.direction != null or self.held.confirm or self.held.cancel or self.held.menu or self.held.physical_up;
        self.armed = false;
        self.held = .{};
        self.counters.mode_changes +|= 1;
        return .{ .previous = previous, .current = next, .changed = true, .released_held = released, .armed = false };
    }

    /// Consume one already-filtered logical frame.  Unsafe frames are replaced
    /// by the neutral output; the gate never fabricates a different action.
    pub fn gate(self: *Gate, out: controller.Output) controller.Output {
        self.counters.frames +|= 1;
        if (!self.focused) {
            self.counters.closed_frames +|= 1;
            self.armed = false;
            self.held = .{};
            self.suppress(out);
            return .{};
        }
        if (!self.armed) {
            if (isNeutral(out)) {
                self.armed = true;
                self.counters.rearmed_frames +|= 1;
                self.held = .{};
                return .{};
            }
            self.counters.closed_frames +|= 1;
            self.suppress(out);
            self.held = .{};
            return .{};
        }
        self.held = .{
            .direction = out.direction,
            .confirm = out.confirm,
            .cancel = out.cancel,
            .menu = out.menu,
            .physical_up = out.physical_up,
        };
        return out;
    }

    fn suppress(self: *Gate, out: controller.Output) void {
        if (out.confirm) self.counters.suppressed_confirms +|= 1;
        if (out.cancel) self.counters.suppressed_cancels +|= 1;
        if (out.menu) self.counters.suppressed_menus +|= 1;
        if (out.direction != null or out.navigation != null) self.counters.suppressed_directions +|= 1;
        if (out.physical_up) self.counters.suppressed_physical_up +|= 1;
    }

    pub fn describe(err: anyerror) diagnostic.Diagnostic {
        return diagnostic.describe(err);
    }
};

test "lease refuses a second owner and a foreign release" {
    var lease: Lease = .{};
    try lease.acquire(.field);
    try std.testing.expectError(error.InputOwned, lease.acquire(.menu));
    try std.testing.expectError(error.NotInputOwner, lease.release(.battle));
    try std.testing.expect(lease.held);
    try lease.release(.field);
    try std.testing.expect(!lease.held);
    try std.testing.expectEqual(@as(u32, 1), lease.refusals);
}

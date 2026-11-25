//! One menu/input architecture for every list this campaign admits.
//!
//! The model is deliberately data-only: a `Row` is an id, a full label and a
//! role; a `Screen` owns one cursor, one scroll offset and one confirmed
//! snapshot; a `Menu` routes ordinary control events between screens.  It never
//! imports a renderer, a save module or a game mode, so `pause_menu`,
//! `party_session/view`, `battle_menu` and a future status page can all drive
//! the same implementation.
//!
//! Two behaviours are worth stating because they define the acceptance contract:
//!
//! * **Selection is identity.**  `refresh` re-finds the selected id after a
//!   roster/list change; if it is gone the cursor is clamped and a notice is
//!   counted.  A mode switch keeps each screen's cursor, and `restore` carries
//!   the remembered ids into the next `open`, which re-finds them.
//! * **Hidden input cannot replay.**  Every `open`, `refresh`, `setLocked`,
//!   `setVisible`, navigate and restore bumps an input epoch.  A `confirm` on a
//!   disabled row is refused without creating a pending command; a second
//!   confirm cannot duplicate one; an event carrying an older epoch is reported
//!   as stale and dropped.

const std = @import("std");

pub const max_id = 40;
pub const source_count = @typeInfo(Source).@"enum".field_names.len;

pub const Source = enum {
    root,
    item_action,
    roster,
    bag,
    storage,
    target,
    shop,
    shop_stock,
    shop_confirm,
    blacksmith,
    blacksmith_confirm,
    rune,
    rune_confirm,
    appraiser,
    appraiser_confirm,
    setup,
    pause_commands,
    battle_commands,
};

pub fn sourceName(source: Source) []const u8 {
    return @tagName(source);
}

pub fn sourceFromName(name: []const u8) ?Source {
    return std.meta.stringToEnum(Source, name);
}

pub const Role = enum { command, separator };

pub const Row = struct {
    id: []const u8,
    label: []const u8,
    role: Role = .command,
    enabled: bool = true,
    detail: ?[]const u8 = null,
};

pub const RoleName = struct { role: Role = .command, enabled: bool = true };

pub const Route = struct {
    source: Source,
    left: ?Source = null,
    right: ?Source = null,
    cancel: ?Source = null,
};

pub const Options = struct {
    window_rows: u16 = 9,
    wrap: bool = true,
    columns: u16 = 26,
};

pub const Key = enum { up, down, left, right, confirm, cancel, menu };

pub const Event = struct {
    key: Key,
    epoch: u32,
};

pub const Refusal = enum {
    screen_locked,
    not_visible,
    empty_list,
    row_disabled,
    command_pending,
};

pub const Command = struct {
    source: Source,
    index: usize,
    id: []const u8,
    label: []const u8,
};

pub const Action = union(enum) {
    moved,
    accepted,
    refused: Refusal,
    navigate: Source,
    close,
    stale,
    ignored,
};

pub const Display = struct {
    buffer: [max_id + 2]u8 = undefined,
    len: usize = 0,
    clipped: bool = false,

    pub fn text(self: *const Display) []const u8 {
        return self.buffer[0..self.len];
    }
};

/// Clip a full label to the window's cell budget.  The last cell becomes `~`
/// when something was cut; the caller still has the row's full `label`, so no
/// content is lost by drawing.
pub fn fitLabel(label: []const u8, columns: usize) Display {
    var result = Display{};
    if (columns == 0) {
        result.clipped = label.len != 0;
        return result;
    }
    if (label.len <= columns) {
        const length = @min(label.len, result.buffer.len);
        @memcpy(result.buffer[0..length], label[0..length]);
        result.len = length;
        result.clipped = length != label.len;
        return result;
    }
    const keep = @min(columns - 1, result.buffer.len - 1);
    @memcpy(result.buffer[0..keep], label[0..keep]);
    result.buffer[keep] = '~';
    result.len = keep + 1;
    result.clipped = true;
    return result;
}

pub const Range = struct { first: usize, last: usize };

pub const Screen = struct {
    rows: []const Row = &.{},
    cursor: usize = 0,
    first: usize = 0,
    confirmed: ?usize = null,
    confirmed_id: []const u8 = "",
    pending: ?Command = null,
    known: [max_id]u8 = undefined,
    known_len: u8 = 0,
    window_rows: usize = 9,
    wrap: bool = true,
    columns: usize = 26,
    opened: bool = false,

    pub fn count(self: Screen) usize {
        return self.rows.len;
    }

    pub fn remember(self: *Screen) void {
        const row = self.selected() orelse {
            self.known_len = 0;
            return;
        };
        const length = @min(row.id.len, self.known.len);
        @memcpy(self.known[0..length], row.id[0..length]);
        self.known_len = @intCast(length);
    }

    pub fn knownId(self: *const Screen) []const u8 {
        return self.known[0..@as(usize, self.known_len)];
    }

    pub fn selected(self: *const Screen) ?*const Row {
        if (self.cursor >= self.rows.len) return null;
        return &self.rows[self.cursor];
    }

    pub fn selectedId(self: *const Screen) ?[]const u8 {
        return if (self.selected()) |row| row.id else null;
    }

    pub fn visibleRange(self: *const Screen) Range {
        return self.rangeFor(self.window_rows);
    }

    pub fn rangeFor(self: *const Screen, window_rows: usize) Range {
        if (self.rows.len == 0) return .{ .first = 0, .last = 0 };
        const window = @max(@as(usize, 1), @min(window_rows, self.rows.len));
        var first = @min(self.first, self.rows.len - window);
        if (self.cursor < first) first = self.cursor;
        if (self.cursor >= first + window) first = self.cursor + 1 - window;
        const last = @min(first + window, self.rows.len);
        return .{ .first = first, .last = last };
    }

    pub fn selectedVisible(self: *const Screen) bool {
        const range = self.visibleRange();
        return self.rows.len != 0 and self.cursor >= range.first and self.cursor < range.last;
    }
};

pub const Slot = struct {
    cursor: usize = 0,
    first: usize = 0,
    known: [max_id]u8 = undefined,
    known_len: u8 = 0,
    opened: bool = false,
};

pub const Snapshot = struct {
    active: Source = .root,
    visible: bool = true,
    locked: bool = false,
    slots: [source_count]Slot = @splat(.{}),
};

pub const Menu = struct {
    screens: [source_count]Screen = @splat(.{}),
    routes: []const Route = &.{},
    active: Source = .root,
    visible: bool = true,
    locked: bool = false,
    epoch: u32 = 1,
    ignored: u32 = 0,
    stale: u32 = 0,
    lost: u32 = 0,
    pages: u32 = 0,

    pub fn init(routes: []const Route) Menu {
        return .{ .routes = routes };
    }

    pub fn screenFor(self: *Menu, source: Source) *Screen {
        return &self.screens[@backingInt(source)];
    }

    pub fn readScreenFor(self: *const Menu, source: Source) *const Screen {
        return &self.screens[@backingInt(source)];
    }

    pub fn activeScreen(self: *const Menu) *const Screen {
        return self.readScreenFor(self.active);
    }

    pub fn routeFor(self: *const Menu, source: Source) ?Route {
        for (self.routes) |route| if (route.source == source) return route;
        return null;
    }

    fn bump(self: *Menu) void {
        self.epoch +%= 1;
        if (self.epoch == 0) self.epoch = 1;
    }

    fn ensureVisible(self: *Menu, screen: *Screen) void {
        _ = self;
        if (screen.rows.len == 0) {
            screen.cursor = 0;
            screen.first = 0;
            return;
        }
        screen.cursor = @min(screen.cursor, screen.rows.len - 1);
        const window = @max(@as(usize, 1), @min(screen.window_rows, screen.rows.len));
        if (screen.cursor < screen.first) screen.first = screen.cursor;
        if (screen.cursor >= screen.first + window) screen.first = screen.cursor + 1 - window;
        const max_first = screen.rows.len - window;
        if (screen.first > max_first) screen.first = max_first;
    }

    fn reanchor(self: *Menu, screen: *Screen) void {
        screen.pending = null;
        screen.confirmed = null;
        if (screen.rows.len == 0) {
            self.ensureVisible(screen);
            screen.known_len = 0;
            return;
        }
        const wanted = screen.knownId();
        var found: ?usize = null;
        if (wanted.len != 0) {
            for (screen.rows, 0..) |row, index| {
                if (std.mem.eql(u8, row.id, wanted)) {
                    found = index;
                    break;
                }
            }
        }
        if (found) |index| {
            screen.cursor = index;
        } else {
            if (wanted.len != 0) self.lost += 1;
            if (screen.cursor >= screen.rows.len) screen.cursor = screen.rows.len - 1;
            // Never land on a separator when a command exists.
            var probe = screen.cursor;
            var steps: usize = 0;
            while (steps < screen.rows.len and screen.rows[probe].role == .separator) : (steps += 1) {
                probe = if (probe == 0) screen.rows.len - 1 else probe - 1;
            }
            if (screen.rows[probe].role != .separator) screen.cursor = probe;
        }
        self.ensureVisible(screen);
        screen.remember();
    }

    /// Open a screen with fresh rows.  A previously remembered id wins over the
    /// old index, which is what makes a mode switch or a list refresh keep the
    /// same selection.
    pub fn open(self: *Menu, source: Source, rows: []const Row, options: Options) void {
        const screen = self.screenFor(source);
        screen.rows = rows;
        screen.window_rows = @max(@as(usize, 1), @min(@as(usize, options.window_rows), 32));
        screen.wrap = options.wrap;
        screen.columns = @as(usize, options.columns);
        screen.opened = true;
        self.reanchor(screen);
        self.active = source;
        self.visible = true;
        self.bump();
    }

    /// A roster/list change for the active screen.  Identity is re-found; a
    /// vanished id clamps to the nearest row and increments `lost`.
    pub fn refresh(self: *Menu, rows: []const Row) void {
        const screen = self.screenFor(self.active);
        screen.rows = rows;
        screen.opened = true;
        self.reanchor(screen);
        self.bump();
    }

    pub fn selectIndex(self: *Menu, source: Source, index: usize) bool {
        const screen = self.screenFor(source);
        if (index >= screen.rows.len or screen.rows[index].role == .separator) return false;
        screen.cursor = index;
        self.ensureVisible(screen);
        screen.remember();
        return true;
    }

    pub fn setLocked(self: *Menu, locked: bool) void {
        if (self.locked == locked) return;
        self.locked = locked;
        for (&self.screens) |*screen| screen.pending = null;
        self.bump();
    }

    pub fn setVisible(self: *Menu, visible: bool) void {
        if (self.visible == visible) return;
        self.visible = visible;
        for (&self.screens) |*screen| screen.pending = null;
        self.bump();
    }

    fn move(self: *Menu, screen: *Screen, direction: Key) void {
        if (screen.rows.len == 0) return;
        var index = screen.cursor;
        var steps: usize = 0;
        while (steps < screen.rows.len) : (steps += 1) {
            if (direction == .down) {
                index = if (index + 1 >= screen.rows.len)
                    (if (screen.wrap) 0 else screen.rows.len - 1)
                else
                    index + 1;
            } else {
                index = if (index == 0)
                    (if (screen.wrap) screen.rows.len - 1 else 0)
                else
                    index - 1;
            }
            if (screen.rows[index].role != .separator) {
                screen.cursor = index;
                break;
            }
        }
        // The confirmed snapshot survives navigation (source obj+0x5C), but a
        // not-yet-consumed command is invalidated by moving the cursor.
        screen.pending = null;
        self.ensureVisible(screen);
        screen.remember();
    }

    fn leave(self: *Menu) Action {
        const screen = self.screenFor(self.active);
        screen.pending = null;
        screen.confirmed = null;
        self.visible = false;
        self.bump();
        return .close;
    }

    pub fn receive(self: *Menu, event: Event) Action {
        if (!self.visible) {
            self.ignored += 1;
            return .ignored;
        }
        if (event.epoch != self.epoch) {
            self.stale += 1;
            return .stale;
        }
        const screen = self.screenFor(self.active);
        if (!screen.opened or screen.rows.len == 0) {
            return switch (event.key) {
                .cancel => {
                    screen.pending = null;
                    screen.confirmed = null;
                    if (self.routeFor(self.active)) |route| {
                        if (route.cancel) |parent| {
                            self.visible = false;
                            self.bump();
                            return .{ .navigate = parent };
                        }
                    }
                    return self.leave();
                },
                .menu => self.leave(),
                .left, .right => blk: {
                    self.ignored += 1;
                    break :blk .ignored;
                },
                else => .{ .refused = .empty_list },
            };
        }
        switch (event.key) {
            .up, .down => {
                self.move(screen, event.key);
                return .moved;
            },
            .left, .right => {
                const route = self.routeFor(self.active) orelse {
                    self.ignored += 1;
                    return .ignored;
                };
                const target = if (event.key == .left) route.left else route.right;
                if (target) |next| {
                    screen.pending = null;
                    screen.confirmed = null;
                    self.visible = false;
                    self.bump();
                    return .{ .navigate = next };
                }
                self.ignored += 1;
                return .ignored;
            },
            .cancel => {
                screen.pending = null;
                screen.confirmed = null;
                if (self.routeFor(self.active)) |route| {
                    if (route.cancel) |parent| {
                        self.visible = false;
                        self.bump();
                        return .{ .navigate = parent };
                    }
                }
                return self.leave();
            },
            .menu => return self.leave(),
            .confirm => {
                if (self.locked) return .{ .refused = .screen_locked };
                if (screen.pending != null) return .{ .refused = .command_pending };
                const row = screen.selected() orelse return .{ .refused = .empty_list };
                if (row.role == .separator or !row.enabled) return .{ .refused = .row_disabled };
                screen.confirmed = screen.cursor;
                screen.confirmed_id = row.id;
                screen.pending = .{
                    .source = self.active,
                    .index = screen.cursor,
                    .id = row.id,
                    .label = row.label,
                };
                return .accepted;
            },
        }
    }

    pub fn receiveKey(self: *Menu, key: Key) Action {
        return self.receive(.{ .key = key, .epoch = self.epoch });
    }

    /// The confirmed command is available exactly once.  This is the analogue
    /// of the source confirm copying `obj+0x54` into `obj+0x5C`: the page owner
    /// consumes a snapshot, not the live cursor.
    pub fn takeCommand(self: *Menu) ?Command {
        const screen = self.screenFor(self.active);
        const command = screen.pending orelse return null;
        screen.pending = null;
        return command;
    }

    pub fn snapshot(self: *const Menu) Snapshot {
        var result = Snapshot{ .active = self.active, .visible = self.visible, .locked = self.locked };
        for (&result.slots, 0..) |*slot, index| {
            const screen = &self.screens[index];
            slot.cursor = screen.cursor;
            slot.first = screen.first;
            slot.known_len = screen.known_len;
            const length: usize = screen.known_len;
            @memcpy(slot.known[0..length], screen.known[0..length]);
            slot.opened = screen.opened;
        }
        return result;
    }

    /// Restore only the selection memory; rows are deliberately not restored.
    /// The host must `open` the active (or a parent) screen again with validated
    /// rows, and that `open` re-finds the remembered id or clamps visibly.
    pub fn restore(self: *Menu, saved: Snapshot) void {
        self.active = saved.active;
        self.visible = saved.visible;
        self.locked = saved.locked;
        for (&self.screens, 0..) |*screen, index| {
            const slot = saved.slots[index];
            screen.rows = &.{};
            screen.cursor = slot.cursor;
            screen.first = slot.first;
            screen.confirmed = null;
            screen.pending = null;
            screen.known_len = slot.known_len;
            const length: usize = slot.known_len;
            @memcpy(screen.known[0..length], slot.known[0..length]);
            screen.opened = false;
        }
        self.bump();
    }

    pub fn pageLabel(self: *const Menu, buffer: []u8) []const u8 {
        return self.pageLabelFor(buffer, self.activeScreen().window_rows);
    }

    pub fn pageLabelFor(self: *const Menu, buffer: []u8, window_rows: usize) []const u8 {
        const screen = self.activeScreen();
        const range = screen.rangeFor(window_rows);
        if (screen.rows.len == 0) return std.fmt.bufPrint(buffer, "0/0", .{}) catch "0/0";
        return std.fmt.bufPrint(buffer, "{d}-{d}/{d}{s}{s}", .{
            range.first + 1,
            range.last,
            screen.rows.len,
            if (range.first > 0) " ^" else "",
            if (range.last < screen.rows.len) " v" else "",
        }) catch "?";
    }
};

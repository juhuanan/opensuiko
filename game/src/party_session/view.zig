//! Platform-independent preparation view. A host draws `title`, `row` and
//! `last_error`, and forwards ordinary directional/confirm/cancel inputs.
const std = @import("std");
const battle = @import("battle");
const combat_menu = @import("combat_systems").menu;
const session = @import("session.zig");
const roster = @import("controller.zig");

pub const Input = enum { up, down, left, right, confirm, cancel, finish };
pub const screen_count = @typeInfo(Screen).@"enum".field_names.len;
pub const Outcome = enum { editing, accepted, cancelled };
pub const Screen = enum { party, member, bag, action, recipient, swap_slot, equipment_slot, replace, discard_confirm, storage, shared };
pub const View = struct {
    screen: Screen = .party,
    outcome: Outcome = .editing,
    allow_party_selection: bool = false,
    party: roster.Controller = .{},
    cursor: usize = 0,
    member: usize = 0,
    item: usize = 0,
    last_error: ?[]const u8 = null,
    unequip: bool = false,
    give_piece: bool = false,
    swapping: bool = false,
    rune_transfer: bool = false,
    target: usize = 0,
    /// The row a screen was left on, by label.  Entering a screen again
    /// re-finds that row instead of resetting to index 0; a vanished row clamps
    /// to the neighbouring one.  Fixed values keep the view copyable.
    remembered: [screen_count]struct { label: [40]u8 = @splat(0), len: u8 = 0 } = @splat(.{}),

    fn ownedCount(s: session.Session) usize {
        for (s.current.members, 0..) |member, i| if (member == null) return i;
        return session.max_owned;
    }
    fn memberId(self: View, s: session.Session) []const u8 {
        return s.current.members[self.member].?.id;
    }
    pub fn title(self: View) []const u8 {
        return switch (self.screen) {
            .party => "Party",
            .member => "Choose member",
            .bag => "Inventory",
            .action => "Choose action",
            .recipient => if (self.rune_transfer) "Transfer rune to" else if (self.swapping) "Swap with" else if (self.give_piece) "Apply piece to" else "Give to",
            .swap_slot => "Choose item to swap",
            .equipment_slot => "Equipment slot",
            .storage => "Storage",
            .shared => "Shared items",
            .replace => "Replace weapon element?",
            .discard_confirm => "Discard this item?",
        };
    }
    pub fn count(self: View, s: session.Session) usize {
        return switch (self.screen) {
            .party, .member, .recipient => ownedCount(s),
            .bag => s.current.members[self.member].?.inventory.count(),
            .swap_slot => s.current.members[self.target].?.inventory.count(),
            .action => 10,
            .replace, .discard_confirm => 2,
            .equipment_slot => 5,
            .storage => s.current.storage.count(),
            .shared => for (s.current.shared, 0..) |item, i| {
                if (item == null) break i;
            } else 7,
        };
    }
    pub fn row(self: View, s: session.Session, i: usize) ?[]const u8 {
        if (i >= self.count(s)) return null;
        return switch (self.screen) {
            .party, .member, .recipient => s.current.members[i].?.name,
            .bag => s.current.members[self.member].?.inventory.slots[i].?.name(),
            .swap_slot => s.current.members[self.target].?.inventory.slots[i].?.name(),
            .storage => s.current.storage.itemAt(i).?.name(),
            .shared => s.current.shared[i].?,
            .action => (&[_][]const u8{ "Give", "Store", "Discard", "Equip", "Attach rune", "Unequip", "Detach rune", "Apply weapon piece", "Swap", "Transfer rune" })[i],
            .replace, .discard_confirm => (&[_][]const u8{ "No", "Yes" })[i],
            .equipment_slot => (&[_][]const u8{ "Head", "Body", "Shield", "Accessory 1", "Accessory 2" })[i],
        };
    }
    pub fn selectedIndex(self: View) usize {
        return if (self.screen == .party) self.party.cursor else self.cursor;
    }
    /// Sink provides text(x, y, value, selected); the host supplies its font.
    /// The visible window, the clipped label, the page marker and the
    /// detail column all come from the shared menu model, so a 78-row roster or
    /// a 100-row bag scrolls with the selection always inside the drawn range
    /// and a long name can never overlap its quantity.
    pub fn draw(self: View, s: session.Session, sink: anytype) void {
        var rows: [100]combat_menu.model.Row = undefined;
        var details: [100][16]u8 = undefined;
        const row_count = @min(self.count(s), rows.len);
        for (0..row_count) |i| {
            var detail: ?[]const u8 = null;
            if (self.screen == .storage) {
                const id = s.current.storage.itemAt(i).?;
                detail = std.fmt.bufPrint(&details[i], "x{d}", .{s.current.storage.quantity(id)}) catch null;
            }
            if (self.screen == .bag) {
                const item = s.current.members[self.member].?.inventory.slots[i].?;
                if (item.id.maxUses() > 0) detail = std.fmt.bufPrint(&details[i], "{d} uses", .{item.uses}) catch null;
            }
            rows[i] = .{ .id = self.row(s, i).?, .label = self.row(s, i).?, .detail = detail };
        }
        var menu = combat_menu.model.Menu.init(&.{});
        menu.open(.root, rows[0..row_count], .{ .window_rows = 8, .columns = 26, .wrap = true });
        _ = menu.selectIndex(.root, @min(self.selectedIndex(), if (row_count == 0) 0 else row_count - 1));
        const rendered = combat_menu.view.draw(&menu, .{
            .x = 24,
            .y = 31,
            .row_height = 24,
            .columns = 26,
            .rows = 8,
            .page_x = 300,
            .detail_x = 370,
            .title = self.title(),
        }, sink);
        if (self.screen == .bag or self.screen == .storage or self.screen == .action)
            sink.text(300, 24, s.current.members[self.member].?.name, false);
        if (self.screen == .party) for (rendered.first..rendered.last) |i| {
            if (roster.Controller.active(s, s.current.members[i].?.id)) {
                sink.text(300, 31 + @as(i32, @intCast(i - rendered.first + 1)) * 24, "Active", false);
            }
        };
        if (self.last_error) |message| sink.text(24, 264, message, false);
        sink.text(24, 292, if (self.screen == .party) "Choose: Z/Enter  Finish: Space  Cancel: X/Esc" else "Up/Down: choose  Confirm: select  Cancel: back", false);
    }
    fn choose(self: *View, s: session.Session, screen: Screen) void {
        self.remember(s);
        self.screen = screen;
        self.cursor = self.refind(s, screen);
    }

    fn remember(self: *View, s: session.Session) void {
        const selected = self.selectedIndex();
        const label = self.row(s, selected) orelse return;
        const slot = &self.remembered[@backingInt(self.screen)];
        const length = @min(label.len, slot.label.len);
        @memcpy(slot.label[0..length], label[0..length]);
        slot.len = @intCast(length);
    }

    fn refind(self: *View, s: session.Session, screen: Screen) usize {
        var probe = self.*;
        probe.screen = screen;
        const slot = &self.remembered[@backingInt(screen)];
        if (slot.len == 0) return 0;
        const wanted = slot.label[0..slot.len];
        for (0..probe.count(s)) |i| {
            if (probe.row(s, i)) |label| if (std.mem.eql(u8, label, wanted)) return i;
        }
        return 0;
    }
    fn issue(self: *View, s: *session.Session, command: session.Command) bool {
        s.execute(command) catch |err| {
            self.last_error = @errorName(err);
            return false;
        };
        return true;
    }
    pub fn input(self: *View, s: *session.Session, key: Input) void {
        self.last_error = null;
        if (self.outcome != .editing) return;
        if (key == .finish) {
            if (self.screen == .party) self.outcome = .accepted else self.last_error = "ReturnToPartyToFinish";
            return;
        }
        if (self.screen == .party) {
            switch (key) {
                .right => {
                    self.party.last_error = null;
                    self.choose(s.*, .member);
                },
                .left => {
                    self.party.last_error = null;
                    self.choose(s.*, .storage);
                },
                .up => self.party.input(s, .up),
                .down => self.party.input(s, .down),
                .confirm => if (self.allow_party_selection) self.party.input(s, .confirm) else {
                    self.party.last_error = "PartyChangeUnavailable";
                },
                .cancel => {
                    self.party.input(s, .cancel);
                    self.outcome = .cancelled;
                },
                .finish => unreachable,
            }
            self.last_error = self.party.last_error;
            return;
        }
        const n = self.count(s.*);
        switch (key) {
            .finish => unreachable,
            .up => if (n > 0) {
                self.cursor = if (self.cursor == 0) n - 1 else self.cursor - 1;
            },
            .down => if (n > 0) {
                self.cursor = (self.cursor + 1) % n;
            },
            .left => switch (self.screen) {
                .member => self.choose(s.*, .party),
                .storage => self.choose(s.*, .member),
                .shared => self.choose(s.*, .storage),
                else => {},
            },
            .right => switch (self.screen) {
                .member => self.choose(s.*, .storage),
                .storage => self.choose(s.*, .shared),
                .shared => self.choose(s.*, .party),
                else => {},
            },
            .cancel => switch (self.screen) {
                .member, .storage, .shared => self.choose(s.*, .party),
                .bag => self.choose(s.*, .member),
                .action => self.choose(s.*, .bag),
                .recipient, .equipment_slot => self.choose(s.*, .action),
                .swap_slot => self.choose(s.*, .recipient),
                .replace => self.choose(s.*, .recipient),
                .discard_confirm => self.choose(s.*, .action),
                .party => unreachable,
            },
            .confirm => {
                if (n == 0) {
                    if (self.screen == .bag) {
                        self.item = 0;
                        self.choose(s.*, .action);
                    } else self.last_error = "NothingAvailable";
                    return;
                }
                switch (self.screen) {
                    .member => {
                        self.member = self.cursor;
                        self.choose(s.*, .bag);
                    },
                    .bag => {
                        self.item = self.cursor;
                        self.choose(s.*, .action);
                    },
                    .action => switch (self.cursor) {
                        0 => {
                            self.give_piece = false;
                            self.swapping = false;
                            self.rune_transfer = false;
                            self.choose(s.*, .recipient);
                        },
                        1 => if (self.issue(s, .{ .deposit = .{ .member = self.memberId(s.*), .slot = self.item } })) self.choose(s.*, .bag),
                        2 => self.choose(s.*, .discard_confirm),
                        3 => {
                            self.unequip = false;
                            self.choose(s.*, .equipment_slot);
                        },
                        4 => if (self.issue(s, .{ .attach_rune = .{ .member = self.memberId(s.*), .owner = self.memberId(s.*), .slot = self.item } })) self.choose(s.*, .bag),
                        5 => {
                            self.unequip = true;
                            self.choose(s.*, .equipment_slot);
                        },
                        7 => {
                            self.give_piece = true;
                            self.swapping = false;
                            self.rune_transfer = false;
                            self.choose(s.*, .recipient);
                        },
                        6 => if (self.issue(s, .{ .detach_rune = .{ .member = self.memberId(s.*) } })) self.choose(s.*, .bag),
                        8 => {
                            self.give_piece = false;
                            self.swapping = true;
                            self.rune_transfer = false;
                            self.choose(s.*, .recipient);
                        },
                        9 => {
                            self.give_piece = false;
                            self.swapping = false;
                            self.rune_transfer = true;
                            self.choose(s.*, .recipient);
                        },
                        else => unreachable,
                    },
                    .recipient => {
                        const recipient = s.current.members[self.cursor].?.id;
                        if (self.rune_transfer) {
                            if (self.issue(s, .{ .transfer_rune = .{ .from = self.memberId(s.*), .to = recipient } })) self.choose(s.*, .bag);
                        } else if (self.swapping) {
                            self.target = self.cursor;
                            self.choose(s.*, .swap_slot);
                        } else if (self.give_piece) {
                            self.target = self.cursor;
                            if (self.issue(s, .{ .weapon_piece = .{ .owner = self.memberId(s.*), .slot = self.item, .target = recipient } })) {
                                self.choose(s.*, .bag);
                            } else if (self.last_error != null and std.mem.eql(u8, self.last_error.?, "ReplacementConfirmationRequired")) {
                                self.last_error = null;
                                self.choose(s.*, .replace);
                            }
                        } else if (self.issue(s, .{ .give = .{ .from = self.memberId(s.*), .slot = self.item, .to = recipient } })) self.choose(s.*, .bag);
                    },
                    .swap_slot => {
                        const recipient = s.current.members[self.target].?.id;
                        if (self.issue(s, .{ .swap = .{ .first = self.memberId(s.*), .first_slot = self.item, .second = recipient, .second_slot = self.cursor } })) self.choose(s.*, .bag);
                    },
                    .discard_confirm => {
                        if (self.cursor == 0) {
                            self.choose(s.*, .action);
                            return;
                        }
                        if (self.issue(s, .{ .discard = .{ .member = self.memberId(s.*), .slot = self.item } })) self.choose(s.*, .bag);
                    },
                    .replace => {
                        if (self.cursor == 0) {
                            self.choose(s.*, .recipient);
                            return;
                        }
                        const recipient = s.current.members[self.target].?.id;
                        if (self.issue(s, .{ .weapon_piece = .{ .owner = self.memberId(s.*), .slot = self.item, .target = recipient, .replace = true } })) self.choose(s.*, .bag);
                    },
                    .equipment_slot => {
                        const slots = [_]battle.systems.EquipmentSlot{ .head, .body, .shield, .accessory_one, .accessory_two };
                        var found: ?usize = null;
                        if (!self.unequip) {
                            const bag = s.current.members[self.member].?.inventory;
                            if (self.item >= bag.count()) {
                                self.last_error = "InvalidItem";
                                return;
                            }
                            const item_id = @tagName(bag.slots[self.item].?.id);
                            const systems = s.combat.content.systems orelse {
                                self.last_error = "EquipmentUnavailable";
                                return;
                            };
                            for (systems.equipment, 0..) |equipment, i| if (std.mem.eql(u8, equipment.id, item_id)) {
                                found = i;
                                break;
                            };
                            if (found == null) {
                                self.last_error = "InvalidEquipment";
                                return;
                            }
                        }
                        if (self.issue(s, .{ .equip = .{ .member = self.memberId(s.*), .slot = slots[self.cursor], .equipment = found } })) self.choose(s.*, .bag);
                    },
                    .storage => {
                        const item_id = s.current.storage.itemAt(self.cursor).?;
                        if (self.issue(s, .{ .withdraw = .{ .member = self.memberId(s.*), .item = item_id } })) self.choose(s.*, .storage);
                    },
                    .shared => {
                        self.last_error = "EventManagedItem";
                    },
                    .party => unreachable,
                }
            },
        }
    }
};

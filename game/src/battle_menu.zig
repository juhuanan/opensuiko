const std = @import("std");
const combat_menu = @import("combat_systems").menu;

pub const Command = enum(u8) { attack, defend, rune, item, unite };
pub const labels = [_][:0]const u8{ "Attack", "Defend", "Rune", "Item", "Unite" };
pub const Input = struct { up: bool = false, down: bool = false, confirm: bool = false, cancel: bool = false };
pub const Result = union(enum) { none, confirmed: Command, cancelled };

// MAIN 0x800EA934: confirm, cancel, then repeated up/down; manual/11-battle.md.
pub const Picker = struct {
    enabled: [5]bool,
    selected: Command,
    /// A refused confirm is typed instead of a panic.  The command is
    /// still reachable (the source list is authoritative), so the caller can
    /// report the refusal and keep the previous selection.
    last_refusal: ?combat_menu.model.Refusal = null,

    pub fn init(enabled: [5]bool, prior: Command) error{NoEnabledCommands}!Picker {
        for (enabled, 0..) |available, i| {
            if (available) return .{
                .enabled = enabled,
                .selected = if (enabled[@backingInt(prior)]) prior else @fromBackingInt(@intCast(i)),
            };
        }
        return error.NoEnabledCommands;
    }

    pub fn update(self: *Picker, input: Input) Result {
        self.last_refusal = null;
        if (input.confirm) {
            if (!self.enabled[@backingInt(self.selected)]) {
                self.last_refusal = .row_disabled;
                return .none;
            }
            return .{ .confirmed = self.selected };
        }
        if (input.cancel) return .cancelled;
        if (input.up) self.move(4);
        if (input.down) self.move(1);
        return .none;
    }

    fn move(self: *Picker, step: usize) void {
        var next: usize = @backingInt(self.selected);
        for (0..5) |_| {
            next = (next + step) % 5;
            if (self.enabled[next]) {
                self.selected = @fromBackingInt(@intCast(next));
                return;
            }
        }
        unreachable;
    }
};

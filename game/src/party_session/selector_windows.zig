//! Source callback requests own windows; each window advances after that callback.
const selector = @import("selector.zig");
const Window = selector.Window;
const layout = selector.layout;

pub const Kind = enum { main, list, details, confirmation, party, full };
pub const Windows = struct {
    slots: [6]?Window = @splat(null),
    pending_open_cues: u8 = 0,

    pub fn window(self: *const Windows, kind: Kind) ?Window {
        return self.slots[@backingInt(kind)];
    }

    fn create(self: *Windows, kind: Kind, target: layout.Rect) !void {
        if (self.window(kind) != null) return error.SelectorWindowAlreadyOwned;
        self.slots[@backingInt(kind)] = try Window.init(.{ .x = target.x, .y = target.y, .w = target.w, .h = target.h });
    }

    fn open(self: *Windows, kind: Kind) !void {
        if (self.pending_open_cues == 255) return error.PendingSelectorWindowCues;
        const slot = if (self.slots[@backingInt(kind)]) |*value| value else return error.MissingSelectorWindow;
        slot.open();
        self.pending_open_cues += 1;
    }

    fn close(self: *Windows, kind: Kind) void {
        if (self.slots[@backingInt(kind)]) |*slot| slot.close();
    }

    fn ready(self: Windows, kind: Kind) bool {
        return if (self.slots[@backingInt(kind)]) |slot| slot.ready() else true;
    }

    fn closePanels(self: *Windows) void {
        inline for (.{ Kind.list, Kind.details, Kind.party }) |kind| self.close(kind);
    }

    fn releaseList(self: *Windows) void {
        inline for (.{ Kind.list, Kind.details, Kind.confirmation, Kind.party, Kind.full }) |kind| self.slots[@backingInt(kind)] = null;
    }

    pub fn takeOpenCue(self: *Windows) bool {
        if (self.pending_open_cues == 0) return false;
        self.pending_open_cues -= 1;
        return true;
    }

    fn advance(self: *Windows, phase: selector.Phase) void {
        for (&self.slots, 0..) |*maybe, index| {
            // The main callback stops submitting its window on entry to cleanup.
            if (index == @backingInt(Kind.main) and phase == .main_cleanup) continue;
            if (maybe.*) |*slot| slot.tick();
        }
    }

    pub fn afterCommit(self: *Windows, menu: selector.Selector, count: usize) void {
        if (menu.action == .admit and count == 6) self.closePanels();
        self.advance(menu.phase);
    }

    pub fn tick(self: *Windows, menu: *selector.Selector, roster: selector.Roster, controls: selector.Controls) !void {
        try roster.validate();
        const before = menu.phase;
        if (before == .loading) return error.PendingSelectorMutation;
        switch (before) {
            .main_creation => {
                try self.create(.main, layout.main);
                try self.open(.main);
            },
            .main_cleanup => self.slots[@backingInt(Kind.main)] = null,
            .list_creation => {
                const admit = menu.action == .admit;
                try self.create(.list, if (admit) layout.admit_list else layout.eject_list);
                try self.create(.details, if (admit) layout.admit_details else layout.eject_details);
                try self.create(.confirmation, if (admit) layout.admit_confirmation else layout.eject_confirmation);
                if (admit) {
                    try self.create(.party, layout.admit_party);
                    try self.create(.full, layout.admit_full);
                }
                if (!admit or roster.active.len != 6) {
                    try self.open(.list);
                    try self.open(.details);
                    if (admit) try self.open(.party);
                }
            },
            .list_close_request => self.closePanels(),
            .list_closing => if (self.ready(.list) and self.ready(.details)) self.releaseList(),
            .full_closing => if (self.ready(.full)) self.releaseList(),
            else => {},
        }
        const settled = switch (before) {
            .main_opening => (self.window(.main) orelse return error.MissingSelectorWindow).phase == .open,
            .main_closing => (self.window(.main) orelse return error.MissingSelectorWindow).phase == .closed,
            .list_opening, .list_closing => self.ready(.list) and self.ready(.details),
            .confirmation_opening, .confirmation_closing => self.ready(.confirmation),
            .full_opening, .full_closing => self.ready(.full),
            else => false,
        };
        try menu.tick(roster, controls, settled);
        if (before == .main and menu.phase == .main_closing) self.close(.main);
        if (before == .list and menu.phase == .confirmation_opening) try self.open(.confirmation);
        if (before == .list and menu.phase == .full_opening) try self.open(.full);
        if (before == .confirmation and menu.phase == .confirmation_closing) self.close(.confirmation);
        if (before == .full and menu.phase == .full_closing) self.close(.full);
        self.advance(menu.phase);
    }
};

//! Canonical title / New Game / Continue / Load / Setup / slot machine.
//!
//! The machine is pure: it reads the host's slot snapshot and the committed
//! Setup profile, and returns at most one `Command` per tick for the host to
//! execute.  It never performs I/O and never mutates campaign state, so a host
//! failure can always be reported without the module having written anything
//! halfway.
//!
//! Safety properties the tests pin:
//!   * New Game carries a name and the packaged start-seed digest only - it has
//!     no slot index, so starting a route can never overwrite a slot.
//!   * A prototype-authored start seed, a missing seed and a mismatched digest
//!     are three distinct refusals.
//!   * Empty / damaged / future-version slots are distinct notices; a future
//!     slot is never loaded *or* overwritten.
//!   * Overwriting a ready/backup/damaged slot requires an explicit second
//!     confirmation whose default answer is No; Cancel writes nothing.
//!   * Setup Cancel discards the draft; a failed write keeps the previous
//!     committed profile and retains the draft for retry.
//!   * Settings are a separate store and are untouched by the campaign flows.
const std = @import("std");
const name = @import("name.zig");
const slots = @import("slots.zig");
const setup = @import("setup.zig");
const policy = @import("policy.zig");

pub const Phase = enum { title, name_entry, name_confirm, load_slots, save_slots, overwrite_confirm, setup, inactive };
pub const Surface = enum { title, pause_menu };

pub const Intent = struct {
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,
    confirm: bool = false,
    cancel: bool = false,
    text: []const u8 = "",
    erase: bool = false,
};

pub const Notice = enum {
    none,
    name_empty,
    name_too_long,
    name_invalid_character,
    continue_none,
    slot_empty,
    slot_damaged,
    slot_future,
    future_not_overwritable,
    save_failed_previous_kept,
    save_failed_nothing_written,
    load_failed_progress_kept,
    settings_failed_previous_kept,
    settings_saved,
    settings_unset,
    no_source_save_here,
    canonical_seed_unavailable,
    prototype_seed_refused,
    canonical_seed_mismatch,
    campaign_started,
    campaign_start_failed,
};

pub fn noticeText(notice: Notice) []const u8 {
    return switch (notice) {
        .none => "",
        .name_empty => "A name is required. Empty names are rejected.",
        .name_too_long => "The name is full.",
        .name_invalid_character => "Only printable characters are accepted.",
        .continue_none => "There is no saved game to continue.",
        .slot_empty => "This slot is empty.",
        .slot_damaged => "This save and its backup could not be read.",
        .slot_future => "This save needs a newer game version.",
        .future_not_overwritable => "A newer-version save is never overwritten.",
        .save_failed_previous_kept => "Save failed. The previous save was kept.",
        .save_failed_nothing_written => "Save failed. Nothing was written.",
        .load_failed_progress_kept => "Load failed. Current progress was kept.",
        .settings_failed_previous_kept => "Settings could not be saved. The previous settings apply.",
        .settings_saved => "Settings saved.",
        .settings_unset => "No stored setting yet; choose each option before relying on it.",
        .no_source_save_here => "Saving is not allowed at this point.",
        .canonical_seed_unavailable => "The canonical start is unavailable; the authored prototype is not started as canonical.",
        .prototype_seed_refused => "The authored prototype start is not canonical and was refused.",
        .canonical_seed_mismatch => "The start data does not match the packaged canonical campaign.",
        .campaign_started => "",
        .campaign_start_failed => "The campaign could not be started. No save was written.",
    };
}

pub const StartOrigin = enum { canonical_packaged, prototype_authored };

/// The packaged canonical start, supplied by the host from
/// `game/assets/opening.json`.  The module checks the identity fields as well as
/// the digest so a fabricated "canonical" seed cannot slip through.
pub const StartSeed = struct {
    origin: StartOrigin = .canonical_packaged,
    content_sha256: [32]u8 = policy.start_seed_sha256,
    money: u32 = policy.start_seed_money,
    party_count: usize = policy.start_seed_party,
    room: []const u8 = policy.start_seed_room,
};

pub const SaveGate = enum { port_approved, source_allowed, source_refused };

pub const BeginPlan = struct {
    name: [name.capacity]u8 = @splat(0),
    name_len: u8 = 0,
    seed_sha256: [32]u8 = policy.start_seed_sha256,

    pub fn text(self: *const BeginPlan) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn eql(self: BeginPlan, other: []const u8) bool {
        return std.mem.eql(u8, self.text(), other);
    }
};

pub const LoadPlan = struct {
    slot: usize,
    from_backup: bool,
};

pub const SavePlan = struct {
    slot: usize,
    overwrite: slots.Overwrite,
    gate: SaveGate,
};

pub const SettingsPlan = struct {
    profile: setup.Profile,
};

pub const Command = union(enum) {
    none,
    begin_campaign: BeginPlan,
    load_slot: LoadPlan,
    save_slot: SavePlan,
    write_settings: SettingsPlan,
    quit,
    close,
};

pub const Outcome = enum { ok, failed_previous_kept, failed_nothing_written };
pub const CommandTag = enum { begin_campaign, load_slot, save_slot, write_settings };

pub const Entry = struct {
    config: policy.Policy = .{},
    seed: ?StartSeed = null,
    items: []const slots.SlotInfo = &.{},
    committed: setup.Profile = .{},
    draft: setup.Profile = .{},
    settings_available: bool = false,
    gate: SaveGate = .port_approved,
    surface: Surface = .title,
    phase: Phase = .title,
    row: usize = policy.default_row,
    setup_row: usize = 0,
    name_buf: name.Name = .{},
    confirm_yes: bool = false,
    slot_cursor: usize = 0,
    pending_slot: usize = 0,
    return_phase: Phase = .title,
    notice: Notice = .none,
    started: bool = false,

    pub fn init(
        items: []const slots.SlotInfo,
        committed: setup.Profile,
        seed: ?StartSeed,
        settings_available: bool,
    ) !Entry {
        var entry = Entry{
            .items = items,
            .committed = committed,
            .draft = committed,
            .seed = seed,
            .settings_available = settings_available,
        };
        try entry.validate();
        return entry;
    }

    pub fn validate(self: Entry) !void {
        try self.config.validate();
        if (self.items.len != self.config.slot_count) return error.SlotCountMismatch;
        try self.committed.validate();
        for (self.items) |info| {
            if (info.name.len > name.capacity) return error.SlotNameTooLong;
            for (info.name) |byte| if (!name.printable(byte)) return error.InvalidSlotName;
            if ((info.status == .ready or info.status == .backup) and info.name.len == 0) return error.MissingSlotName;
            for (info.party) |member| {
                if (member.name.len == 0 or member.name.len > name.capacity) return error.InvalidPartyPreview;
                for (member.name) |byte| if (!name.printable(byte)) return error.InvalidPartyPreview;
            }
        }
    }

    /// Refreshes the host snapshot after a save/load without touching the
    /// player's committed Setup profile.
    pub fn setItems(self: *Entry, items: []const slots.SlotInfo) !void {
        if (items.len != self.config.slot_count) return error.SlotCountMismatch;
        self.items = items;
        if (self.slot_cursor >= items.len) self.slot_cursor = 0;
        try self.validate();
    }

    /// Binds the policy document the host parsed.  A document that disagrees
    /// with the compiled contract is refused before any screen is shown.
    pub fn bindPolicy(self: *Entry, loaded: policy.Policy) !void {
        self.config = loaded;
        try self.validate();
    }

    pub fn bindSettings(self: *Entry, profile: setup.Profile, available: bool) !void {
        try profile.validate();
        self.committed = profile;
        if (self.phase != .setup) self.draft = profile;
        self.settings_available = available;
    }

    pub fn openLoad(self: *Entry, surface: Surface) void {
        self.surface = surface;
        self.return_phase = if (surface == .pause_menu) .inactive else .title;
        self.phase = .load_slots;
        self.slot_cursor = 0;
        self.notice = .none;
    }

    pub fn openSave(self: *Entry, surface: Surface) void {
        self.surface = surface;
        self.return_phase = if (surface == .pause_menu) .inactive else .title;
        self.phase = .save_slots;
        self.slot_cursor = 0;
        self.notice = .none;
    }

    pub fn openSetup(self: *Entry, surface: Surface) void {
        self.surface = surface;
        self.return_phase = if (surface == .pause_menu) .inactive else .title;
        self.phase = .setup;
        self.setup_row = 0;
        self.draft = self.committed;
        self.notice = if (self.settings_available) .none else .settings_unset;
    }

    pub fn returnToTitle(self: *Entry) void {
        self.phase = .title;
        self.surface = .title;
        self.row = self.config.default_row;
        self.setup_row = 0;
        self.name_buf.clear();
        self.confirm_yes = false;
        self.draft = self.committed;
        self.return_phase = .title;
        self.notice = .none;
        self.started = false;
    }

    pub fn tick(self: *Entry, input: Intent) Command {
        return switch (self.phase) {
            .title => self.tickTitle(input),
            .name_entry => self.tickNameEntry(input),
            .name_confirm => self.tickNameConfirm(input),
            .load_slots => self.tickLoadSlots(input),
            .save_slots => self.tickSaveSlots(input),
            .overwrite_confirm => self.tickOverwrite(input),
            .setup => self.tickSetup(input),
            .inactive => .none,
        };
    }

    fn closeOrReturn(self: *Entry) Command {
        if (self.surface == .pause_menu) return .close;
        self.phase = self.return_phase;
        return .none;
    }

    fn tickTitle(self: *Entry, input: Intent) Command {
        if (input.cancel) {
            self.notice = .none;
            return .none;
        }
        if (input.up) self.row = (self.row + policy.rows.len - 1) % policy.rows.len;
        if (input.down) self.row = (self.row + 1) % policy.rows.len;
        if (!input.confirm) return .none;
        self.notice = .none;
        return switch (policy.rows[self.row].id) {
            .new_game => block: {
                self.name_buf.clear();
                self.confirm_yes = false;
                self.phase = .name_entry;
                break :block .none;
            },
            .continue_game => self.continueLatest(),
            .load_game => block: {
                self.slot_cursor = if (slots.latest(self.items)) |latest| latest.slot else 0;
                self.return_phase = .title;
                self.phase = .load_slots;
                break :block .none;
            },
            .setup => block: {
                self.openSetup(.title);
                break :block .none;
            },
            .quit => .quit,
        };
    }

    fn continueLatest(self: *Entry) Command {
        const latest = slots.latest(self.items) orelse {
            self.notice = .continue_none;
            return .none;
        };
        self.pending_slot = latest.slot;
        self.return_phase = .title;
        return .{ .load_slot = .{ .slot = latest.slot, .from_backup = latest.from_backup } };
    }

    fn tickNameEntry(self: *Entry, input: Intent) Command {
        if (input.cancel) {
            self.name_buf.clear();
            self.phase = .title;
            self.notice = .none;
            return .none;
        }
        if (input.erase) {
            self.name_buf.erase();
            self.notice = .none;
        }
        if (input.text.len > 0) switch (self.name_buf.append(input.text)) {
            .accepted => self.notice = .none,
            .rejected_character => self.notice = .name_invalid_character,
            .full => self.notice = .name_too_long,
        };
        if (!input.confirm) return .none;
        self.name_buf.validate() catch |err| {
            self.notice = if (err == error.EmptyName) .name_empty else .name_invalid_character;
            return .none;
        };
        // The source prompt defaults to No; an accidental confirm must not start
        // the campaign.
        self.confirm_yes = false;
        self.phase = .name_confirm;
        return .none;
    }

    fn tickNameConfirm(self: *Entry, input: Intent) Command {
        if (input.cancel) {
            self.phase = .name_entry;
            self.notice = .none;
            return .none;
        }
        if (input.up or input.down or input.left or input.right) self.confirm_yes = !self.confirm_yes;
        if (!input.confirm) return .none;
        if (!self.confirm_yes) {
            self.phase = .name_entry;
            return .none;
        }
        const seed = self.seed orelse {
            self.notice = .canonical_seed_unavailable;
            return .none;
        };
        if (seed.origin == .prototype_authored) {
            self.notice = .prototype_seed_refused;
            return .none;
        }
        if (!self.config.seedMatches(seed.content_sha256) or
            seed.money != policy.start_seed_money or
            seed.party_count != policy.start_seed_party or
            !std.mem.eql(u8, seed.room, policy.start_seed_room))
        {
            self.notice = .canonical_seed_mismatch;
            return .none;
        }
        var plan = BeginPlan{ .seed_sha256 = seed.content_sha256, .name_len = self.name_buf.len };
        @memcpy(plan.name[0..self.name_buf.len], self.name_buf.text());
        return .{ .begin_campaign = plan };
    }

    fn tickLoadSlots(self: *Entry, input: Intent) Command {
        if (input.cancel) {
            self.notice = .none;
            return self.closeOrReturn();
        }
        if (input.up) self.slot_cursor = (self.slot_cursor + self.items.len - 1) % self.items.len;
        if (input.down) self.slot_cursor = (self.slot_cursor + 1) % self.items.len;
        if (!input.confirm) return .none;
        const info = self.items[self.slot_cursor];
        switch (info.status) {
            .empty => {
                self.notice = .slot_empty;
                return .none;
            },
            .damaged => {
                self.notice = .slot_damaged;
                return .none;
            },
            .future => {
                self.notice = .slot_future;
                return .none;
            },
            .ready, .backup => {
                self.pending_slot = self.slot_cursor;
                self.return_phase = .load_slots;
                self.notice = .none;
                return .{ .load_slot = .{ .slot = self.slot_cursor, .from_backup = info.status == .backup } };
            },
        }
    }

    fn tickSaveSlots(self: *Entry, input: Intent) Command {
        if (input.cancel) {
            self.notice = .none;
            return self.closeOrReturn();
        }
        if (input.up) self.slot_cursor = (self.slot_cursor + self.items.len - 1) % self.items.len;
        if (input.down) self.slot_cursor = (self.slot_cursor + 1) % self.items.len;
        if (!input.confirm) return .none;
        const overwrite = slots.overwriteFor(self.items[self.slot_cursor].status);
        self.pending_slot = self.slot_cursor;
        self.confirm_yes = false;
        switch (overwrite) {
            .refused => {
                self.notice = .future_not_overwritable;
                return .none;
            },
            .none => return self.emitSave(.none),
            .confirm_then_backup, .confirm_replace => {
                self.notice = .none;
                self.phase = .overwrite_confirm;
                return .none;
            },
        }
    }

    fn tickOverwrite(self: *Entry, input: Intent) Command {
        if (input.cancel) {
            self.notice = .none;
            self.phase = .save_slots;
            return .none;
        }
        if (input.up or input.down or input.left or input.right) self.confirm_yes = !self.confirm_yes;
        if (!input.confirm) return .none;
        if (!self.confirm_yes) {
            self.phase = .save_slots;
            return .none;
        }
        return self.emitSave(slots.overwriteFor(self.items[self.pending_slot].status));
    }

    fn emitSave(self: *Entry, overwrite: slots.Overwrite) Command {
        if (self.gate == .source_refused) {
            self.notice = .no_source_save_here;
            return .none;
        }
        return .{ .save_slot = .{
            .slot = self.pending_slot,
            .overwrite = overwrite,
            .gate = if (self.gate == .source_allowed) .source_allowed else .port_approved,
        } };
    }

    fn tickSetup(self: *Entry, input: Intent) Command {
        if (input.cancel) {
            self.draft = self.committed;
            self.notice = .none;
            return self.closeOrReturn();
        }
        if (input.up) self.setup_row = (self.setup_row + setup.group_count - 1) % setup.group_count;
        if (input.down) self.setup_row = (self.setup_row + 1) % setup.group_count;
        if (input.left) self.draft.step(setup.groups[self.setup_row].id, false);
        if (input.right) self.draft.step(setup.groups[self.setup_row].id, true);
        if (!input.confirm) return .none;
        return .{ .write_settings = .{ .profile = self.draft } };
    }

    pub fn acknowledge(self: *Entry, tag: CommandTag, outcome: Outcome) void {
        switch (tag) {
            .begin_campaign => {
                if (outcome == .ok) {
                    self.started = true;
                    self.phase = .inactive;
                    self.notice = .campaign_started;
                } else {
                    self.phase = .name_confirm;
                    self.notice = .campaign_start_failed;
                }
            },
            .load_slot => {
                if (outcome == .ok) {
                    self.started = true;
                    self.phase = .inactive;
                    self.notice = .none;
                } else {
                    self.phase = self.return_phase;
                    self.notice = .load_failed_progress_kept;
                }
            },
            .save_slot => {
                if (outcome == .ok) {
                    self.phase = .inactive;
                    self.notice = .none;
                } else {
                    self.phase = .save_slots;
                    self.notice = if (outcome == .failed_previous_kept) .save_failed_previous_kept else .save_failed_nothing_written;
                }
            },
            .write_settings => {
                if (outcome == .ok) {
                    self.committed = self.draft;
                    self.settings_available = true;
                    self.notice = .settings_saved;
                    self.phase = if (self.surface == .pause_menu) .inactive else .title;
                } else {
                    // The draft stays for a retry; the committed value and the
                    // campaign slots are untouched.
                    self.notice = .settings_failed_previous_kept;
                }
            },
        }
    }
};

test "new game carries a name and no slot" {
    const items = [_]slots.SlotInfo{ .{}, .{}, .{} };
    var entry = try Entry.init(&items, .{}, .{}, false);
    // Continue is the default row, so move up to New game and open it.
    _ = entry.tick(.{ .up = true });
    try std.testing.expectEqual(policy.RowId.new_game, policy.rows[entry.row].id);
    try std.testing.expect(std.meta.activeTag(entry.tick(.{ .confirm = true })) == .none);
    try std.testing.expectEqual(Phase.name_entry, entry.phase);
    try std.testing.expect(entry.name_buf.isEmpty());
}

test "notice text is distinct for every slot failure" {
    try std.testing.expect(!std.mem.eql(u8, noticeText(.slot_empty), noticeText(.slot_damaged)));
    try std.testing.expect(!std.mem.eql(u8, noticeText(.slot_future), noticeText(.slot_empty)));
    try std.testing.expect(!std.mem.eql(u8, noticeText(.future_not_overwritable), noticeText(.slot_future)));
}

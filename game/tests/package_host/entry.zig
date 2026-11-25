//! Focused gate: canonical title, New Game naming, Continue/Load,
//! Setup and save-slot controls.
//!
//! Port level only: no original instruction executes, no emulator/window/media
//! is used and no real user save is read or written.  Every flow is driven by
//! ordinary `Intent` values through the entry module and the
//! packaged `entry_policy.json` bytes (bound through the generated `data`
//! module).
const std = @import("std");
const entry_mod = @import("package_host").entry;
const data = @import("package_host_data");

const allocator = std.testing.allocator;
const slots = entry_mod.slots;
const setup = entry_mod.setup;
const entry = entry_mod.entry;
const view = entry_mod.view;
const name = entry_mod.name;

const long_name = "Abcdefghij Klmnopqrstuvwxyz 0123";
const second_name = "Tir Mcdohl With A Very Long";

fn isNone(command: entry.Command) bool {
    return std.meta.activeTag(command) == .none;
}

fn slot(status: slots.Status, slot_name: []const u8, order: u64) slots.SlotInfo {
    return .{ .status = status, .name = slot_name, .order = order };
}

fn emptySnapshot() [3]slots.SlotInfo {
    return .{ .{}, .{}, .{} };
}

/// Types `value` one byte at a time, exactly as the platform text queue does.
fn typeName(state: *entry.Entry, value: []const u8) void {
    for (value) |byte| _ = state.tick(.{ .text = &.{byte} });
}

/// Drives the New Game flow up to (not including) the "Is this OK?" Yes.
fn reachConfirm(state: *entry.Entry, hero: []const u8) void {
    _ = state.tick(.{ .up = true }); // Continue -> New game
    _ = state.tick(.{ .confirm = true });
    typeName(state, hero);
    _ = state.tick(.{ .confirm = true }); // name -> prompt
}

fn confirmYes(state: *entry.Entry) entry.Command {
    if (!state.confirm_yes) _ = state.tick(.{ .right = true });
    return state.tick(.{ .confirm = true });
}

test "the packaged policy loads and matches the compiled contract" {
    const loaded = try entry_mod.policy.load(allocator, data.entry_policy_json);
    try std.testing.expectEqual(@as(usize, 3), loaded.slot_count);
    try std.testing.expectEqual(@as(u8, 32), loaded.name_max);
    try std.testing.expectEqual(@as(usize, 1), loaded.default_row);
    try std.testing.expect(loaded.seedMatches(entry_mod.policy.start_seed_sha256));

    // A drifted packaged document fails closed.
    const tampered = try allocator.dupe(u8, data.entry_policy_json);
    defer allocator.free(tampered);
    const at = std.mem.indexOf(u8, tampered, "entry_policy") orelse return error.MissingPack;
    tampered[at + 4] = 'X';
    try std.testing.expectError(error.InvalidPolicy, entry_mod.policy.load(allocator, tampered));

    const wrong_seed = try allocator.dupe(u8, data.entry_policy_json);
    defer allocator.free(wrong_seed);
    const digest_at = std.mem.indexOf(u8, wrong_seed, "47243f2f") orelse return error.MissingDigest;
    wrong_seed[digest_at] = '5';
    try std.testing.expectError(error.InvalidPolicy, entry_mod.policy.load(allocator, wrong_seed));
}

test "the title opens on Continue game and New game starts an empty name" {
    const items = emptySnapshot();
    const loaded = try entry_mod.policy.load(allocator, data.entry_policy_json);
    var state = try entry.Entry.init(&items, .{}, null, false);
    try state.bindPolicy(loaded);

    const rows = view.titleItems(&state);
    try std.testing.expectEqualStrings("New game", rows[0].label);
    try std.testing.expectEqualStrings("Continue game", rows[1].label);
    try std.testing.expect(rows[1].selected);
    try std.testing.expectEqual(entry_mod.policy.Provenance.port_extension, rows[2].provenance);

    try std.testing.expect(isNone(state.tick(.{ .up = true })));
    try std.testing.expect(view.titleItems(&state)[0].selected);
    try std.testing.expect(isNone(state.tick(.{ .confirm = true })));
    try std.testing.expectEqual(entry.Phase.name_entry, state.phase);
    // No prototype hero name is pre-filled.
    try std.testing.expect(state.name_buf.isEmpty());
}

test "an empty name is rejected before the confirmation prompt" {
    const items = emptySnapshot();
    var state = try entry.Entry.init(&items, .{}, null, false);
    _ = state.tick(.{ .up = true });
    _ = state.tick(.{ .confirm = true });
    try std.testing.expect(isNone(state.tick(.{ .confirm = true })));
    try std.testing.expectEqual(entry.Phase.name_entry, state.phase);
    try std.testing.expectEqual(entry.Notice.name_empty, state.notice);
    try std.testing.expectEqualStrings("A name is required. Empty names are rejected.", view.notice(&state));
}

test "long names are preserved, overflow is visible, and wrap never truncates" {
    const items = emptySnapshot();
    var state = try entry.Entry.init(&items, .{}, null, false);
    _ = state.tick(.{ .up = true });
    _ = state.tick(.{ .confirm = true });
    typeName(&state, long_name);
    try std.testing.expectEqual(@as(usize, 32), long_name.len);
    try std.testing.expectEqual(@as(u8, 32), state.name_buf.len);
    try std.testing.expectEqualStrings(long_name, view.namePreview(&state));

    typeName(&state, "XY");
    try std.testing.expectEqual(entry.Notice.name_too_long, state.notice);
    try std.testing.expectEqualStrings(long_name, state.name_buf.text());

    _ = state.tick(.{ .erase = true });
    try std.testing.expectEqualStrings(long_name[0..31], state.name_buf.text());

    _ = state.tick(.{ .text = "\x01" });
    try std.testing.expectEqual(entry.Notice.name_invalid_character, state.notice);
    try std.testing.expectEqualStrings(long_name[0..31], state.name_buf.text());

    var lines: [name.capacity][]const u8 = undefined;
    const count = try view.nameLines(&state, 5, &lines);
    var joined: [name.capacity]u8 = undefined;
    var at: usize = 0;
    for (lines[0..count]) |line| {
        @memcpy(joined[at..][0..line.len], line);
        at += line.len;
    }
    try std.testing.expectEqualStrings(long_name[0..31], joined[0..at]);
    try std.testing.expect(count == 7);
}

test "New Game confirmation defaults to No and refuses non-canonical seeds" {
    const items = emptySnapshot();
    var state = try entry.Entry.init(&items, .{}, null, false);
    reachConfirm(&state, "Tir");
    try std.testing.expectEqual(entry.Phase.name_confirm, state.phase);
    // The default answer is No: an accidental confirm returns to the name.
    try std.testing.expect(isNone(state.tick(.{ .confirm = true })));
    try std.testing.expectEqual(entry.Phase.name_entry, state.phase);
    try std.testing.expectEqualStrings("Tir", state.name_buf.text());

    // A missing canonical start is refused, not replaced by the prototype.
    _ = state.tick(.{ .confirm = true });
    try std.testing.expect(isNone(confirmYes(&state)));
    try std.testing.expectEqual(entry.Notice.canonical_seed_unavailable, state.notice);
    try std.testing.expectEqual(entry.Phase.name_confirm, state.phase);

    // The authored prototype is a different, explicitly refused origin.
    state.seed = .{ .origin = .prototype_authored };
    try std.testing.expect(isNone(confirmYes(&state)));
    try std.testing.expectEqual(entry.Notice.prototype_seed_refused, state.notice);

    // A fabricated digest is a third, distinct refusal.
    var wrong = entry.StartSeed{};
    wrong.content_sha256[0] ^= 0xff;
    state.seed = wrong;
    try std.testing.expect(isNone(confirmYes(&state)));
    try std.testing.expectEqual(entry.Notice.canonical_seed_mismatch, state.notice);

    // The packaged seed starts the campaign with the typed name.
    state.seed = entry.StartSeed{};
    const command = confirmYes(&state);
    switch (command) {
        .begin_campaign => |plan| {
            try std.testing.expectEqualStrings("Tir", plan.text());
            try std.testing.expectEqualSlices(u8, &entry_mod.policy.start_seed_sha256, &plan.seed_sha256);
        },
        else => return error.ExpectedBegin,
    }
    state.acknowledge(.begin_campaign, .ok);
    try std.testing.expectEqual(entry.Phase.inactive, state.phase);
    try std.testing.expect(state.started);
}

test "starting a route never writes a slot and never touches the snapshot" {
    var items = emptySnapshot();
    items[0] = slot(.ready, "Old Adventure", 10);
    items[1] = slot(.backup, "Older Adventure", 4);
    items[2] = slot(.empty, "", 0);
    const before = items;
    var state = try entry.Entry.init(&items, .{}, entry.StartSeed{}, true);

    // The start plan type has no slot at all.
    try std.testing.expect(!@hasField(entry.BeginPlan, "slot"));
    reachConfirm(&state, "Tir");
    const command = confirmYes(&state);
    try std.testing.expect(!isNone(command));
    state.acknowledge(.begin_campaign, .ok);

    for (items, before) |now, was| {
        try std.testing.expectEqualStrings(was.name, now.name);
        try std.testing.expectEqual(was.status, now.status);
    }
    try std.testing.expectEqualStrings("Old Adventure", items[0].name);
    try std.testing.expectEqual(slots.Status.ready, items[0].status);
}

test "Continue loads the newest loadable slot and reports absence" {
    var items = emptySnapshot();
    var state = try entry.Entry.init(&items, .{}, null, false);
    try std.testing.expect(isNone(state.tick(.{ .confirm = true })));
    try std.testing.expectEqual(entry.Notice.continue_none, state.notice);
    try std.testing.expectEqual(entry.Phase.title, state.phase);

    items[0] = slot(.ready, "First", 5);
    items[1] = slot(.backup, "Second", 9);
    items[2] = slot(.damaged, "", 20);
    try state.setItems(&items);
    switch (state.tick(.{ .confirm = true })) {
        .load_slot => |plan| {
            try std.testing.expectEqual(@as(usize, 1), plan.slot);
            try std.testing.expect(plan.from_backup);
        },
        else => return error.ExpectedLoad,
    }
    state.acknowledge(.load_slot, .failed_previous_kept);
    try std.testing.expectEqual(entry.Phase.title, state.phase);
    try std.testing.expectEqual(entry.Notice.load_failed_progress_kept, state.notice);
    // Settings and the snapshot survived the failed load.
    try std.testing.expect(state.committed.eql(.{}));
    try std.testing.expectEqualStrings("Second", items[1].name);
}

test "load list keeps empty, damaged and future slots as distinct refusals" {
    var items = emptySnapshot();
    items[0] = .{};
    items[1] = .{ .status = .damaged };
    items[2] = .{ .status = .future };
    var state = try entry.Entry.init(&items, .{}, null, false);
    state.openLoad(.title);

    try std.testing.expect(isNone(state.tick(.{ .confirm = true })));
    try std.testing.expectEqual(entry.Notice.slot_empty, state.notice);
    _ = state.tick(.{ .down = true });
    try std.testing.expect(isNone(state.tick(.{ .confirm = true })));
    try std.testing.expectEqual(entry.Notice.slot_damaged, state.notice);
    _ = state.tick(.{ .down = true });
    try std.testing.expect(isNone(state.tick(.{ .confirm = true })));
    try std.testing.expectEqual(entry.Notice.slot_future, state.notice);
    // A future save is also never loaded.
    try std.testing.expectEqual(entry.Phase.load_slots, state.phase);

    _ = state.tick(.{ .cancel = true });
    try std.testing.expectEqual(entry.Phase.title, state.phase);
}

test "save asks for an explicit overwrite and preserves the backup" {
    var items = emptySnapshot();
    items[0] = slot(.ready, "Current", 3);
    items[1] = slot(.backup, "Older", 1);
    items[2] = .{};
    var state = try entry.Entry.init(&items, .{}, null, false);
    state.openSave(.pause_menu);

    // A ready slot first opens a second confirmation whose default is No.
    try std.testing.expect(isNone(state.tick(.{ .confirm = true })));
    try std.testing.expectEqual(entry.Phase.overwrite_confirm, state.phase);
    try std.testing.expect(isNone(state.tick(.{ .confirm = true })));
    try std.testing.expectEqual(entry.Phase.save_slots, state.phase);
    const prompt = view.overwriteView(&state);
    try std.testing.expect(prompt.slot == 0);

    // Yes commits a plan that keeps the previous save as a backup.
    _ = state.tick(.{ .confirm = true });
    const command = confirmYes(&state);
    switch (command) {
        .save_slot => |plan| {
            try std.testing.expectEqual(@as(usize, 0), plan.slot);
            try std.testing.expectEqual(slots.Overwrite.confirm_then_backup, plan.overwrite);
            try std.testing.expectEqual(entry.SaveGate.port_approved, plan.gate);
        },
        else => return error.ExpectedSave,
    }
    state.acknowledge(.save_slot, .ok);
    try std.testing.expectEqual(entry.Phase.inactive, state.phase);

    // An empty slot writes directly, and a backup slot still confirms.
    state.openSave(.pause_menu);
    _ = state.tick(.{ .down = true });
    _ = state.tick(.{ .down = true });
    switch (state.tick(.{ .confirm = true })) {
        .save_slot => |plan| try std.testing.expectEqual(slots.Overwrite.none, plan.overwrite),
        else => return error.ExpectedDirectSave,
    }
}

test "a future slot is never loaded or overwritten; a damaged one needs a replace confirm" {
    var items = emptySnapshot();
    items[0] = .{ .status = .future };
    items[1] = .{ .status = .damaged };
    items[2] = .{};
    var state = try entry.Entry.init(&items, .{}, null, false);
    state.openSave(.pause_menu);
    try std.testing.expect(isNone(state.tick(.{ .confirm = true })));
    try std.testing.expectEqual(entry.Notice.future_not_overwritable, state.notice);
    try std.testing.expectEqual(entry.Phase.save_slots, state.phase);

    _ = state.tick(.{ .down = true });
    _ = state.tick(.{ .confirm = true });
    try std.testing.expectEqual(entry.Phase.overwrite_confirm, state.phase);
    const command = confirmYes(&state);
    switch (command) {
        .save_slot => |plan| try std.testing.expectEqual(slots.Overwrite.confirm_replace, plan.overwrite),
        else => return error.ExpectedReplace,
    }
    state.acknowledge(.save_slot, .failed_previous_kept);
    try std.testing.expectEqual(entry.Phase.save_slots, state.phase);
    try std.testing.expectEqual(entry.Notice.save_failed_previous_kept, state.notice);
}

test "Setup Cancel discards the draft and a failed write keeps the previous profile" {
    const items = emptySnapshot();
    var committed = setup.Profile{};
    committed.set(.message_speed, 2) catch unreachable;
    var state = try entry.Entry.init(&items, committed, null, true);
    state.openSetup(.title);
    try std.testing.expectEqual(entry.Notice.none, state.notice);

    // Cancel never emits a write and restores the draft.
    _ = state.tick(.{ .right = true });
    try std.testing.expect(!state.draft.eql(state.committed));
    try std.testing.expect(isNone(state.tick(.{ .cancel = true })));
    try std.testing.expectEqual(entry.Phase.title, state.phase);
    try std.testing.expect(state.draft.eql(state.committed));

    // A failed write leaves the committed profile and the campaign alone.
    state.openSetup(.title);
    _ = state.tick(.{ .left = true }); // message speed 2 -> 1
    _ = state.tick(.{ .down = true });
    _ = state.tick(.{ .right = true }); // window setup first choice
    const command = state.tick(.{ .confirm = true });
    const attempted = switch (command) {
        .write_settings => |plan| plan.profile,
        else => return error.ExpectedSettings,
    };
    try std.testing.expectEqual(@as(?u8, 1), attempted.message_speed);
    try std.testing.expectEqual(@as(?u8, 0), attempted.window_setup);
    state.acknowledge(.write_settings, .failed_previous_kept);
    try std.testing.expectEqual(entry.Notice.settings_failed_previous_kept, state.notice);
    try std.testing.expectEqual(@as(?u8, 2), state.committed.message_speed);
    try std.testing.expect(state.draft.eql(attempted));
    // Retry succeeds and only then becomes committed.
    switch (state.tick(.{ .confirm = true })) {
        .write_settings => |plan| try std.testing.expect(plan.profile.eql(attempted)),
        else => return error.ExpectedSettingsRetry,
    }
    state.acknowledge(.write_settings, .ok);
    try std.testing.expect(state.committed.eql(attempted));
    try std.testing.expect(state.settings_available);
    try std.testing.expectEqual(entry.Notice.settings_saved, state.notice);
    // A committed write returns to the screen that opened Setup.
    try std.testing.expectEqual(entry.Phase.title, state.phase);
}

test "an unset Setup profile is displayed as unset, not as a default" {
    const items = emptySnapshot();
    var state = try entry.Entry.init(&items, .{}, null, false);
    state.openSetup(.title);
    try std.testing.expectEqual(entry.Notice.settings_unset, state.notice);
    const rows = view.setupRows(&state);
    for (rows) |row| try std.testing.expectEqualStrings(view.unset_label, row.value);
    _ = state.tick(.{ .confirm = true });
    switch (state.tick(.{ .confirm = true })) {
        .write_settings => |plan| try std.testing.expect(!plan.profile.complete()),
        else => {},
    }
    try std.testing.expectEqual(@as(?u8, null), state.draft.message_speed);
}

test "settings survive ordinary campaign and slot flows" {
    var items = emptySnapshot();
    items[0] = slot(.empty, "", 0);
    items[1] = slot(.empty, "", 0);
    items[2] = slot(.empty, "", 0);
    var committed = setup.Profile{};
    committed.set(.message_speed, 0) catch unreachable;
    committed.set(.window_setup, 1) catch unreachable;
    committed.set(.sound_setup, 0) catch unreachable;
    var state = try entry.Entry.init(&items, committed, entry.StartSeed{}, true);

    // The campaign plan types intentionally carry no settings payload.
    try std.testing.expect(!@hasField(entry.BeginPlan, "profile"));
    try std.testing.expect(!@hasField(entry.LoadPlan, "profile"));
    try std.testing.expect(!@hasField(entry.SavePlan, "profile"));

    reachConfirm(&state, "Tir");
    _ = confirmYes(&state);
    state.acknowledge(.begin_campaign, .ok);
    try std.testing.expect(state.committed.eql(committed));

    state.returnToTitle();
    _ = state.tick(.{ .confirm = true }); // Continue with no save reports none
    try std.testing.expectEqual(entry.Notice.continue_none, state.notice);
    try std.testing.expect(state.committed.eql(committed));

    state.openSave(.pause_menu);
    _ = state.tick(.{ .confirm = true });
    state.acknowledge(.save_slot, .failed_nothing_written);
    try std.testing.expect(state.committed.eql(committed));
}

test "the slot preview keeps the full roster and every long name" {
    var party: [6]slots.PartyMember = undefined;
    const names = [6][]const u8{
        "Abcdefghij Klmnopqrstuvwxyz 0123",
        "Tir Mcdohl With A Very Long",
        "Gremio The Loyal Servant Here",
        "Viktor The Bear Of Warriors",
        "Cleo The Silent Observer",
        "Pahn The Palace Guard",
    };
    for (&party, names, 0..) |*member, member_name, index| {
        member.* = .{ .name = member_name, .level = @intCast(index + 1) };
    }
    var items = emptySnapshot();
    items[0] = .{
        .status = .ready,
        .name = long_name,
        .scene = "Palace",
        .level = 7,
        .seconds = 7500,
        .roster_total = 108,
        .party = &party,
    };
    var state = try entry.Entry.init(&items, .{}, null, false);

    const row = view.slotRow(&state, 0);
    try std.testing.expectEqualStrings(long_name, row.name);
    try std.testing.expectEqual(@as(u16, 108), row.roster_total);
    try std.testing.expectEqual(@as(usize, 6), row.party.len);
    var lines: [6][]const u8 = undefined;
    const count = try view.partyNames(row.party, &lines);
    try std.testing.expectEqual(@as(usize, 6), count);
    for (lines[0..count], names) |line, want| try std.testing.expectEqualStrings(want, line);
    var time_buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("2:05", view.timeLabel(row.seconds, &time_buffer));

    // A valid save without a name, or an over-long one, is refused instead of
    // being shown under a prototype label.
    var nameless = items;
    nameless[0].name = "";
    try std.testing.expectError(error.MissingSlotName, state.setItems(&nameless));
    var too_long = items;
    too_long[0].name = long_name ++ "x";
    try std.testing.expectError(error.SlotNameTooLong, state.setItems(&too_long));
}

test "the save gate is an explicit typed seam" {
    var items = emptySnapshot();
    var state = try entry.Entry.init(&items, .{}, null, false);
    state.gate = .source_refused;
    state.openSave(.pause_menu);
    try std.testing.expect(isNone(state.tick(.{ .confirm = true })));
    try std.testing.expectEqual(entry.Notice.no_source_save_here, state.notice);
    try std.testing.expectEqual(entry.Phase.save_slots, state.phase);

    state.gate = .source_allowed;
    switch (state.tick(.{ .confirm = true })) {
        .save_slot => |plan| try std.testing.expectEqual(entry.SaveGate.source_allowed, plan.gate),
        else => return error.ExpectedSave,
    }
}

test "pause-menu cancel closes every surface without writing" {
    var items = emptySnapshot();
    items[0] = slot(.ready, "Current", 1);
    var state = try entry.Entry.init(&items, .{}, null, false);
    state.openSave(.pause_menu);
    switch (state.tick(.{ .cancel = true })) {
        .close => {},
        else => return error.ExpectedClose,
    }
    state.openLoad(.pause_menu);
    switch (state.tick(.{ .cancel = true })) {
        .close => {},
        else => return error.ExpectedClose,
    }
    state.openSetup(.pause_menu);
    switch (state.tick(.{ .cancel = true })) {
        .close => {},
        else => return error.ExpectedClose,
    }
    try std.testing.expectEqualStrings("Current", items[0].name);
    try std.testing.expect(state.committed.eql(.{}));
}

test "a fresh host reconstructs the same title state and profile" {
    var items = emptySnapshot();
    items[1] = .{ .status = .backup, .name = "Second", .order = 8 };
    var committed = setup.Profile{};
    committed.set(.message_speed, 1) catch unreachable;
    var first = try entry.Entry.init(&items, committed, entry.StartSeed{}, true);
    reachConfirm(&first, "Tir");
    first.returnToTitle();
    try std.testing.expectEqual(entry.Phase.title, first.phase);

    var second = try entry.Entry.init(&items, first.committed, entry.StartSeed{}, true);
    try std.testing.expectEqual(entry.Phase.title, second.phase);
    try std.testing.expectEqual(second.config.default_row, second.row);
    try std.testing.expect(second.committed.eql(committed));
    try std.testing.expect(second.name_buf.isEmpty());
    try std.testing.expectEqual(@as(usize, 3), second.items.len);
}

test "ordinary inputs never mutate the host snapshot, roster or settings" {
    var party: [6]slots.PartyMember = undefined;
    const names = [6][]const u8{
        "Abcdefghij Klmnopqrstuvwxyz 0123",
        "Tir Mcdohl With A Very Long",
        "Gremio The Loyal Servant Here",
        "Viktor The Bear Of Warriors",
        "Cleo The Silent Observer",
        "Pahn The Palace Guard",
    };
    for (&party, names, 0..) |*member, member_name, index| {
        member.* = .{ .name = member_name, .level = @intCast(index + 1) };
    }
    var items = emptySnapshot();
    items[0] = .{ .status = .ready, .name = long_name, .scene = "Palace", .level = 7, .seconds = 7500, .roster_total = 108, .party = &party, .order = 9 };
    items[1] = .{ .status = .backup, .name = second_name, .order = 4 };
    items[2] = .{ .status = .future };
    const before = items;
    var committed = setup.Profile{};
    committed.set(.message_speed, 2) catch unreachable;
    committed.set(.window_setup, 0) catch unreachable;
    var state = try entry.Entry.init(&items, committed, entry.StartSeed{}, true);

    // A long ordinary-input walk across the title, name entry, load list, save
    // list, overwrite prompt and Setup.  Nothing is acknowledged here, so the
    // host snapshot and the committed profile must stay byte-identical.
    const walk = [_]entry.Intent{
        .{ .up = true },     .{ .confirm = true }, .{ .text = "A" },     .{ .text = "b" },     .{ .erase = true },
        .{ .cancel = true }, .{ .down = true },    .{ .confirm = true }, .{ .down = true },    .{ .confirm = true },
        .{ .cancel = true }, .{ .down = true },    .{ .confirm = true }, .{ .confirm = true }, .{ .cancel = true },
        .{ .down = true },   .{ .confirm = true }, .{ .down = true },    .{ .confirm = true }, .{ .cancel = true },
    };
    for (walk) |input| {
        _ = state.tick(input);
        for (items, before) |now, was| {
            try std.testing.expectEqual(was.status, now.status);
            try std.testing.expectEqualStrings(was.name, now.name);
            try std.testing.expectEqual(was.order, now.order);
            try std.testing.expectEqual(was.roster_total, now.roster_total);
            try std.testing.expectEqual(was.party.len, now.party.len);
            for (now.party, was.party) |member, original| try std.testing.expectEqualStrings(original.name, member.name);
        }
        try std.testing.expect(state.committed.eql(committed));
    }
    // The preview still exposes the full roster and the long names.
    const row = view.slotRow(&state, 0);
    try std.testing.expectEqualStrings(long_name, row.name);
    try std.testing.expectEqual(@as(u16, 108), row.roster_total);
    try std.testing.expectEqual(@as(usize, 6), row.party.len);
}

test "the canonical settings store is not the prototype settings object" {
    const prototype =
        \\{"schema":"suikoden-settings/1","music":8,"effects":8,"fullscreen":false,"vsync":true}
    ;
    try std.testing.expectError(error.PrototypeSettingsNotCanonical, setup.decode(allocator, prototype));

    var profile = setup.Profile{};
    profile.set(.message_speed, 2) catch unreachable;
    const bytes = try setup.encode(allocator, profile);
    defer allocator.free(bytes);
    const decoded = try setup.decode(allocator, bytes);
    try std.testing.expect(decoded.eql(profile));
    try std.testing.expectEqual(@as(?u8, null), decoded.window_setup);
}

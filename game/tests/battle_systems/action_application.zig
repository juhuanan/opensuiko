//! Focused tests: runtime action application for the auxiliary,
//! delayed-callback, projectile and interrupted-return families.
//!
//! No original instruction is executed, no emulator/interpreter is used, and no
//! rendering, audio, save or damage behaviour is claimed.  The tests drive the
//! owned module with a hand-written host that stands in for the battle state and
//! checks that every packet operand reaches actor state, that contact, owner
//! return and target release stay separate across interruptions and across a
//! fresh-process checkpoint, and that a drifted packet is refused.

const std = @import("std");
const apply_mod = @import("battle_systems").apply;
const packet = apply_mod.content;
const apply = apply_mod.apply;

const Host = struct {
    slots: [apply.max_slots]bool = @splat(false),
    allocated: usize = 0,
    released_slots: usize = 0,
    contacts: usize = 0,
    target_releases: usize = 0,
    owner_releases: usize = 0,
    last_slot: u8 = 0,

    fn allocate(context: *anyopaque) ?u8 {
        const self: *Host = @ptrCast(@alignCast(context));
        for (&self.slots, 0..) |*used, index| {
            if (!used.*) {
                used.* = true;
                self.allocated += 1;
                self.last_slot = @intCast(index);
                return @intCast(index);
            }
        }
        return null;
    }
    fn release(context: *anyopaque, slot: u8) void {
        const self: *Host = @ptrCast(@alignCast(context));
        self.slots[slot] = false;
        self.released_slots += 1;
    }
    fn contact(context: *anyopaque, owner: u8) void {
        _ = owner;
        const self: *Host = @ptrCast(@alignCast(context));
        self.contacts += 1;
    }
    fn target(context: *anyopaque, owner: u8) void {
        _ = owner;
        const self: *Host = @ptrCast(@alignCast(context));
        self.target_releases += 1;
    }
    fn ownerRelease(context: *anyopaque, owner: u8) void {
        _ = owner;
        const self: *Host = @ptrCast(@alignCast(context));
        self.owner_releases += 1;
    }

    fn asHost(self: *Host) apply.Host {
        return .{
            .context = self,
            .allocate_slot = allocate,
            .release_slot = release,
            .observe_contact = contact,
            .release_target = target,
            .release_owner = ownerRelease,
        };
    }
};

fn loadContent(allocator: std.mem.Allocator) !std.json.Parsed(packet.Content) {
    return packet.load(allocator, apply_mod.data.json);
}

fn runTicks(session: *apply.Session, owner: u8, until: u16) !void {
    while ((session.find(owner) orelse unreachable).elapsed <= until) {
        _ = try session.tick(owner);
    }
}

test "packet pins and record domain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try loadContent(arena.allocator());
    const content = parsed.value;

    try std.testing.expectEqualStrings(packet.schema, content.schema);
    try std.testing.expectEqual(@as(usize, 18), content.records.len);
    try std.testing.expectEqual(@as(usize, 2), content.projectiles.len);
    try std.testing.expectEqual(@as(usize, 64), apply_mod.data.asset_sha256.len);
    try std.testing.expectEqual(@as(usize, 64), apply_mod.data.party_actions_asset_sha256.len);
    try std.testing.expectEqual(@as(usize, 64), apply_mod.data.sprite_residency_manifest_sha256.len);

    // The embedded asset must be the exact file the report pins.
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(apply_mod.data.json, &digest, .{});
    var hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{digest}) catch unreachable;
    try std.testing.expectEqualStrings(&hex, apply_mod.data.asset_sha256);

    // Every record carries the four families' operands.
    for (content.records) |record| {
        try std.testing.expectEqualStrings("stationary_auxiliary", record.family);
        try std.testing.expect(record.spawn.bits.reuse_own_source);
        try std.testing.expect(record.spawn.bits.secondary_draw_list);
        try std.testing.expect(!record.spawn.bits.owner_is_linked_slot);
        try std.testing.expect(record.spawn.bits.source_position_from_owner);
        try std.testing.expectEqual(@as(u16, 2), record.contact.mask);
        try std.testing.expectEqual(record.contact.write_tick + 1, record.contact.observe_tick);
        try std.testing.expect(record.callback.id == 1 or record.callback.id == 2);
        try std.testing.expectEqual(@as(u16, 0), record.callback.compare.set_value);
        try std.testing.expectEqual(@as(u16, 1), record.callback.compare.after_invoke);
        try std.testing.expect(!record.auxiliary.motion.translation);
        try std.testing.expectEqual(@as(u16, 9), record.tracks.auxiliary);
    }
}

test "auxiliary creation: every spawn operand reaches the auxiliary actor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try loadContent(arena.allocator());
    const content = parsed.value;
    const index = packet.find(content, "kage") orelse return error.UnknownRecord;
    const record = content.records[index];

    var host = Host{};
    var session = apply.Session.init(&content, host.asHost());
    const action = try session.begin(@intCast(index), 0);
    action.owner_actor.position = .{ .x = 100 << 12, .y = 7 << 12, .z = -3 << 12 };

    var update = try session.tick(0);
    while (update.elapsed < record.spawn.tick) update = try session.tick(0);
    try std.testing.expect(update.spawned);
    try std.testing.expectEqual(@as(usize, 1), host.allocated);
    try std.testing.expectEqual(host.last_slot, update.spawned_slot);

    const auxiliary = (session.find(0) orelse unreachable).auxiliary.?;
    try std.testing.expect(auxiliary.active);
    try std.testing.expectEqual(@as(u16, record.spawn.animation), auxiliary.animation.?);
    try std.testing.expectEqual(record.spawn.script_slot, auxiliary.script_slot);
    try std.testing.expectEqual(@as(u8, 0), auxiliary.owner.?);
    try std.testing.expectEqual(apply.Source.own_source, auxiliary.source);
    try std.testing.expectEqual(apply.DrawList.secondary, auxiliary.draw_list);
    // 12.12 offset: owner position + (offset << 12).
    try std.testing.expectEqual((100 << 12) + (@as(i32, record.spawn.offset.x) << 12), auxiliary.position.x);
    try std.testing.expectEqual((7 << 12) + (@as(i32, record.spawn.offset.y) << 12), auxiliary.position.y);
    try std.testing.expectEqual((-3 << 12) + (@as(i32, record.spawn.offset.z) << 12), auxiliary.position.z);
    // The callback handshake runs on the spawn update.
    try std.testing.expect(update.callback_invoked);
    try std.testing.expectEqual(record.callback.compare.after_invoke, (session.find(0) orelse unreachable).auxiliary.?.compare_value);
    try std.testing.expectEqual(@as(u16, record.callback.id), (session.find(0) orelse unreachable).auxiliary.?.callback.?);
}

test "delayed callback: compare is set, invoked and observed before contact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try loadContent(arena.allocator());
    const content = parsed.value;
    const index = packet.find(content, "cleo") orelse return error.UnknownRecord;
    const record = content.records[index];

    var host = Host{};
    var session = apply.Session.init(&content, host.asHost());
    const action = try session.begin(@intCast(index), 2);
    action.owner_actor.position = .{ .x = 0, .y = 0, .z = 0 };

    var converged: u16 = 0;
    var contact_written: u16 = 0;
    while (contact_written == 0) {
        const update = try session.tick(2);
        if (update.callback_invoked) converged = update.elapsed;
        if (update.contact_written) contact_written = update.elapsed;
    }
    // cleo uses callback 1; the compare value must be 1 before contact.
    try std.testing.expectEqual(record.callback.tick, converged);
    try std.testing.expectEqual(record.contact.write_tick, contact_written);
    try std.testing.expect(converged < contact_written);
    const current = session.find(2) orelse unreachable;
    try std.testing.expectEqual(@as(u16, 1), current.auxiliary.?.compare_value);
    try std.testing.expect(current.auxiliary.?.timer > 0);
}

test "contact, owner return and target release are separate boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try loadContent(arena.allocator());
    const content = parsed.value;
    const index = packet.find(content, "kage") orelse return error.UnknownRecord;
    const record = content.records[index];

    var host = Host{};
    var session = apply.Session.init(&content, host.asHost());
    _ = try session.begin(@intCast(index), 1);

    var contact_at: u16 = 0;
    var target_at: u16 = 0;
    var return_at: u16 = 0;
    var aux_release_at: u16 = 0;
    var owner_ready_at: u16 = 0;
    while (return_at == 0) {
        const update = try session.tick(1);
        if (update.contact_observed) contact_at = update.elapsed;
        if (update.target_released) target_at = update.elapsed;
        if (update.auxiliary_released) aux_release_at = update.elapsed;
        if (update.owner_ready) owner_ready_at = update.elapsed;
        if (update.owner_released) return_at = update.elapsed;
    }
    try std.testing.expectEqual(record.contact.observe_tick, contact_at);
    try std.testing.expectEqual(record.target_release.tick, target_at);
    try std.testing.expectEqual(record.auxiliary.release.tick, aux_release_at);
    try std.testing.expectEqual(record.owner.return_track.release.tick, return_at);
    // Contact is observed before the target is released (reaction delay), which
    // is a different deadline from the owner return.
    try std.testing.expect(contact_at < target_at);
    try std.testing.expect(target_at < return_at);
    try std.testing.expectEqual(@as(usize, 1), host.contacts);
    try std.testing.expectEqual(@as(usize, 1), host.target_releases);
    try std.testing.expectEqual(@as(usize, 1), host.owner_releases);
    try std.testing.expectEqual(@as(usize, 1), host.released_slots);

    const current = session.find(1) orelse unreachable;
    try std.testing.expect(current.complete);
    try std.testing.expect(current.contact.observed and current.target_release.done);
    try std.testing.expect(current.return_track.released);
    try std.testing.expectEqual(apply.ReleaseReason.flag_clear, current.return_track.reason);
    // The return release clears actor flags 1 and 8 only.
    try std.testing.expectEqual(@as(u8, 0), current.owner_actor.primary_flags & 0x9);
    try std.testing.expectEqual(record.owner.ready_observe_tick, owner_ready_at);
}

test "auxiliary script operands reach the auxiliary and owner state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try loadContent(arena.allocator());
    const content = parsed.value;
    const index = packet.find(content, "kage") orelse return error.UnknownRecord;
    const record = content.records[index];

    var host = Host{};
    var session = apply.Session.init(&content, host.asHost());
    _ = try session.begin(@intCast(index), 6);

    // First timer (10 updates at the spawn tick), then the motion countdown.
    var elapsed: u16 = 0;
    while (elapsed <= record.spawn.tick) : (elapsed += 1) _ = try session.tick(6);
    const after_spawn = session.find(6) orelse unreachable;
    try std.testing.expectEqual(record.auxiliary.timers[0].ticks, after_spawn.auxiliary.?.timer);
    // The source motion counter covers `duration` updates including the setting
    // update, which is why the release lands at start + duration - 1.
    try std.testing.expectEqual(record.auxiliary.motion.duration - 1, after_spawn.auxiliary.?.motion_remaining);

    // Second timer and the mask-1 write to the owner at the same update.
    const second = record.auxiliary.timers[1];
    while (elapsed <= second.tick) : (elapsed += 1) _ = try session.tick(6);
    const mid = session.find(6) orelse unreachable;
    try std.testing.expectEqual(second.ticks, mid.auxiliary.?.timer);
    try std.testing.expectEqual(@as(u8, 1), mid.owner_actor.primary_flags & 1);
    try std.testing.expect(mid.auxiliary.?.timer > 0);

    // The motion counter reaches zero exactly at the auxiliary release update.
    while (elapsed <= record.auxiliary.release.tick) : (elapsed += 1) _ = try session.tick(6);
    const released = session.find(6) orelse unreachable;
    try std.testing.expectEqual(@as(u16, 0), released.auxiliary.?.motion_remaining);
    try std.testing.expect(released.auxiliary_released);
    try std.testing.expect(!released.auxiliary.?.active);
    try std.testing.expect(released.auxiliary.?.callback == null);
    try std.testing.expectEqual(@as(usize, 1), host.released_slots);
}

test "interruption keeps the three boundaries separate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try loadContent(arena.allocator());
    const content = parsed.value;
    const index = packet.find(content, "kage") orelse return error.UnknownRecord;
    const record = content.records[index];

    var host = Host{};
    var session = apply.Session.init(&content, host.asHost());
    _ = try session.begin(@intCast(index), 3);
    try runTicks(&session, 3, record.contact.observe_tick);

    // Interrupt after contact, before the target release and the owner return.
    session.interrupt(3, .knockout);
    const interrupted = session.find(3) orelse unreachable;
    try std.testing.expect(interrupted.interrupted);
    try std.testing.expect(interrupted.contact.observed);
    try std.testing.expect(interrupted.target_release.interrupted);
    try std.testing.expect(!interrupted.target_release.done);

    var target_at: u16 = 0;
    var return_at: u16 = 0;
    while (return_at == 0) {
        const update = try session.tick(3);
        if (update.target_released) target_at = update.elapsed;
        if (update.owner_released) return_at = update.elapsed;
    }
    // Neither release is dropped or retargeted by the interruption.
    try std.testing.expectEqual(record.target_release.tick, target_at);
    try std.testing.expectEqual(record.owner.return_track.release.tick, return_at);
    try std.testing.expectEqual(apply.ReleaseReason.flag_clear, (session.find(3) orelse unreachable).return_track.reason);
    const current = session.find(3) orelse unreachable;
    try std.testing.expect(current.contact.observed and current.target_release.done);
}

test "teardown releases the owner without touching contact or target release" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try loadContent(arena.allocator());
    const content = parsed.value;
    const index = packet.find(content, "kage") orelse return error.UnknownRecord;
    const record = content.records[index];

    var host = Host{};
    var session = apply.Session.init(&content, host.asHost());
    _ = try session.begin(@intCast(index), 4);
    // Teardown after the spawn but before contact and before the auxiliary release.
    try runTicks(&session, 4, record.contact.write_tick - 1);
    session.teardown(4);
    const current = session.find(4) orelse unreachable;
    try std.testing.expectEqual(apply.ReleaseReason.teardown, current.return_track.reason);
    try std.testing.expect(current.return_track.released);
    try std.testing.expect(current.owner_actor.stopped);
    try std.testing.expect(current.owner_actor.animation == null);
    try std.testing.expect(current.owner_actor.callback == null);
    try std.testing.expect(current.spawned);
    // The auxiliary is a separate slot; teardown does not free it early.
    try std.testing.expect(!current.auxiliary_released);
    try std.testing.expectEqual(@as(usize, 1), host.owner_releases);

    // Contact, the auxiliary release and the target release still land on their
    // own deadlines after the owner has been torn down.
    var contact_at: u16 = 0;
    var aux_at: u16 = 0;
    var target_at: u16 = 0;
    while (target_at == 0) {
        const update = try session.tick(4);
        if (update.contact_observed) contact_at = update.elapsed;
        if (update.auxiliary_released) aux_at = update.elapsed;
        if (update.target_released) target_at = update.elapsed;
    }
    try std.testing.expectEqual(record.contact.observe_tick, contact_at);
    try std.testing.expectEqual(record.auxiliary.release.tick, aux_at);
    try std.testing.expectEqual(record.target_release.tick, target_at);
    const finished = session.find(4) orelse unreachable;
    try std.testing.expect(finished.contact.observed);
    try std.testing.expect(finished.auxiliary_released);
    try std.testing.expect(finished.target_release.done);
    try std.testing.expectEqual(apply.ReleaseReason.teardown, finished.return_track.reason);
    try std.testing.expectEqual(@as(usize, 1), host.owner_releases);
    try std.testing.expectEqual(@as(usize, 1), host.target_releases);
}

test "checkpoint restores the three boundary states in a fresh session" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try loadContent(arena.allocator());
    const content = parsed.value;
    const index = packet.find(content, "kage") orelse return error.UnknownRecord;
    const record = content.records[index];

    var host = Host{};
    var session = apply.Session.init(&content, host.asHost());
    _ = try session.begin(@intCast(index), 5);
    try runTicks(&session, 5, record.contact.observe_tick + 1);

    var buffer: [apply.max_checkpoint_bytes]u8 = undefined;
    const length = try session.checkpoint(&buffer);

    var restored_host = Host{};
    var restored = apply.Session.init(&content, restored_host.asHost());
    try restored.restore(buffer[0..length]);
    const restored_action = restored.find(5) orelse return error.ActionNotRunning;
    try std.testing.expect(restored_action.contact.observed);
    try std.testing.expect(!restored_action.target_release.done);
    try std.testing.expect(!restored_action.return_track.released);
    try std.testing.expectEqual(host.last_slot, restored_action.auxiliary_slot);

    // Both sessions continue on the same clock and reach the same final state.
    var original_return: u16 = 0;
    var restored_return: u16 = 0;
    while (original_return == 0 or restored_return == 0) {
        if (original_return == 0) {
            const update = try session.tick(5);
            if (update.owner_released) original_return = update.elapsed;
        }
        if (restored_return == 0) {
            const update = try restored.tick(5);
            if (update.owner_released) restored_return = update.elapsed;
        }
    }
    try std.testing.expectEqual(original_return, restored_return);
    try std.testing.expectEqual(record.owner.return_track.release.tick, restored_return);
    const left = session.find(5) orelse unreachable;
    const right = restored.find(5) orelse unreachable;
    try std.testing.expectEqual(left.elapsed, right.elapsed);
    try std.testing.expectEqual(left.complete, right.complete);
    try std.testing.expectEqual(left.owner_actor.primary_flags, right.owner_actor.primary_flags);
    try std.testing.expectEqual(left.target_release.done, right.target_release.done);
    try std.testing.expectEqual(left.contact.observed, right.contact.observed);
    try std.testing.expectEqual(left.return_track.reason, right.return_track.reason);
    try std.testing.expectEqual(@as(usize, 1), restored_host.target_releases);
    try std.testing.expectEqual(@as(usize, 1), restored_host.owner_releases);
}

test "refuses a drifted packet instead of defaulting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try loadContent(arena.allocator());
    const content = parsed.value;

    var contact = content;
    contact.records = try arena.allocator().dupe(packet.Record, content.records);
    contact.records[0].contact.observe_tick += 1;
    try std.testing.expectError(error.InvalidContact, packet.validate(contact));

    var flags = content;
    flags.records = try arena.allocator().dupe(packet.Record, content.records);
    flags.records[0].spawn.flags = 9;
    try std.testing.expectError(error.InvalidSpawn, packet.validate(flags));

    var callback = content;
    callback.records = try arena.allocator().dupe(packet.Record, content.records);
    callback.records[0].callback.id = 3;
    try std.testing.expectError(error.InvalidCallback, packet.validate(callback));

    var residency = content;
    residency.records = try arena.allocator().dupe(packet.Record, content.records);
    residency.records[0].residency.qualified = false;
    try std.testing.expectError(error.InvalidResidency, packet.validate(residency));

    var projectile = content;
    projectile.projectiles = try arena.allocator().dupe(packet.Projectile, content.projectiles);
    projectile.projectiles[0].target_release_tick = projectile.projectiles[0].impact_tick - 1;
    try std.testing.expectError(error.InvalidProjectile, packet.validate(projectile));
}

test "an exhausted slot budget refuses the spawn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try loadContent(arena.allocator());
    const content = parsed.value;
    const index = packet.find(content, "kage") orelse return error.UnknownRecord;
    const record = content.records[index];

    var host = Host{};
    host.slots = @splat(true);
    var session = apply.Session.init(&content, host.asHost());
    _ = try session.begin(@intCast(index), 0);
    try runTicks(&session, 0, record.spawn.tick - 1);
    try std.testing.expectError(error.NoActorSlot, session.tick(0));
    // The failed update is rolled back: nothing was spawned or advanced.
    const current = session.find(0) orelse unreachable;
    try std.testing.expect(!current.spawned);
    try std.testing.expectEqual(record.spawn.tick, current.elapsed);
}

test "front projectile keeps contact, dodge release and owner return separate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try loadContent(arena.allocator());
    const content = parsed.value;
    const index = packet.findProjectile(content, "kobold_type_2") orelse return error.UnknownRecord;
    const projectile = content.projectiles[index];
    try std.testing.expectEqual(@as(usize, 2), projectile.dodges.len);

    // The dodging defender is hero: release 114, not the normal 92.
    const dodge = projectile.dodges[0].target_release_tick;
    var state = apply.ProjectileState.init(&content, @intCast(index));
    var contact_at: u16 = 0;
    var target_at: u16 = 0;
    var owner_at: u16 = 0;
    var elapsed: u16 = 0;
    while (elapsed <= projectile.owner_release_tick + 2) : (elapsed += 1) {
        const event = state.tick(elapsed, dodge);
        if (event.contact) contact_at = elapsed;
        if (event.target_released) target_at = elapsed;
        if (event.owner_returned) owner_at = elapsed;
    }
    try std.testing.expectEqual(projectile.impact_tick, contact_at);
    try std.testing.expectEqual(dodge, target_at);
    try std.testing.expectEqual(projectile.owner_release_tick, owner_at);
    try std.testing.expect(target_at < owner_at);
    try std.testing.expect(contact_at < target_at);
    try std.testing.expect(state.released_by_dodge);

    // A non-dodging target is released at the normal tick.
    var normal = apply.ProjectileState.init(&content, @intCast(index));
    elapsed = 0;
    target_at = 0;
    while (elapsed <= projectile.owner_release_tick + 2) : (elapsed += 1) {
        const event = normal.tick(elapsed, null);
        if (event.target_released) target_at = elapsed;
    }
    try std.testing.expectEqual(projectile.target_release_tick, target_at);
    try std.testing.expect(!normal.released_by_dodge);
}

test "projectile interruption and restart preserve the deadlines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try loadContent(arena.allocator());
    const content = parsed.value;
    const index = packet.findProjectile(content, "killer_rabbit") orelse return error.UnknownRecord;
    const projectile = content.projectiles[index];

    var state = apply.ProjectileState.init(&content, @intCast(index));
    var elapsed: u16 = 0;
    while (elapsed < projectile.impact_tick) : (elapsed += 1) _ = state.tick(elapsed, null);
    state.interrupt();

    var buffer: [64]u8 = undefined;
    var writer = apply.Writer{ .buffer = &buffer };
    try state.encode(&writer);
    var reader = apply.Reader{ .data = buffer[0..writer.at] };
    var restored = try apply.ProjectileState.decode(&reader, &content);
    try std.testing.expect(restored.interrupted);
    try std.testing.expect(!restored.contact);

    var contact_at: u16 = 0;
    var target_at: u16 = 0;
    var owner_at: u16 = 0;
    elapsed = restored.impact_tick;
    while (elapsed <= restored.owner_release_tick + 2) : (elapsed += 1) {
        const event = restored.tick(elapsed, null);
        if (event.contact) contact_at = elapsed;
        if (event.target_released) target_at = elapsed;
        if (event.owner_returned) owner_at = elapsed;
    }
    try std.testing.expectEqual(projectile.impact_tick, contact_at);
    try std.testing.expectEqual(projectile.target_release_tick, target_at);
    try std.testing.expectEqual(projectile.owner_release_tick, owner_at);
}

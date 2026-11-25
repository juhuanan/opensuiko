//! Combat audio host focused gate: logical source audio requests against the
//! platform service, with no device and no playback.
//!
//! The cases verify the acceptance facts:
//!   * one request per committed source event, and a repeated delivery is a
//!     typed refusal instead of a second request;
//!   * replacement stops the previous stream before starting the next, and a
//!     stop with no stream is not a request;
//!   * a modeled request whose completion is missing stays pending across
//!     frames and across a restart; a wrong token is refused and changes
//!     nothing;
//!   * sequence and bank owners are tracked, and only a score stop releases
//!     sequence-owned voices;
//!   * a no-device request is waived: the scene is acknowledged so gameplay
//!     continues, playback is recorded unavailable, and no owner is installed;
//!   * cleanup orders stop, volume restore, loop disable, bank close (refused
//!     while a transfer is pending) and sequence retention;
//!   * no trace row claims playback.
//!
//! The expected traces come from the independent Python model; this gate compares
//! them row for row and asserts the semantic consequences directly.  Nothing here
//! executes an original instruction, opens a device, decodes audio or plays a
//! sample.

const std = @import("std");
const audio_mod = @import("combat_systems").audio;
const data = @import("combat_systems_data").audio_integration;

const Scene = struct {
    acks: usize = 0,
    duplicates: usize = 0,
    batches: [16]u64 = @splat(0),

    fn acknowledge(context: *anyopaque, batch: u64, origin: u16) anyerror!void {
        _ = origin;
        const self: *Scene = @ptrCast(@alignCast(context));
        for (self.batches[0..self.acks]) |seen| {
            if (seen == batch) {
                self.duplicates += 1;
                return error.DuplicateReceipt;
            }
        }
        if (self.acks == self.batches.len) return error.AckOverflow;
        self.batches[self.acks] = batch;
        self.acks += 1;
    }

    fn sink(self: *Scene) audio_mod.SceneSink {
        return .{ .context = self, .acknowledge_fn = acknowledge };
    }
};

const Outcome = struct {
    owners: audio_mod.Owners,
    pending: ?audio_mod.events.Pending,
    acks: usize,
    duplicates: usize,
};

fn scenarioNamed(content: *const audio_mod.plan.Content, name: []const u8) *const audio_mod.plan.Scenario {
    for (content.scenarios) |*scenario| {
        if (std.mem.eql(u8, scenario.name, name)) return scenario;
    }
    unreachable;
}

fn runScenario(
    content: *const audio_mod.plan.Content,
    scenario: audio_mod.plan.Scenario,
    trace: *audio_mod.trace.Trace,
    scene: *Scene,
) !Outcome {
    const init = scenario.steps[0];
    const port = audio_mod.Port{ .available = std.mem.eql(u8, init.port, "recording") };
    if (std.mem.eql(u8, init.planner, "double")) {
        const planner = audio_mod.Double.init(&content.plan);
        return runWith(audio_mod.Double, content, planner, port, trace, scene, scenario);
    }
    return runWith(audio_mod.Unbound, content, audio_mod.Unbound{}, port, trace, scene, scenario);
}

fn runWith(
    comptime Planner: type,
    content: *const audio_mod.plan.Content,
    planner: Planner,
    port: audio_mod.Port,
    trace: *audio_mod.trace.Trace,
    scene: *Scene,
    scenario: audio_mod.plan.Scenario,
) !Outcome {
    var host = audio_mod.Host(Planner).init(content, planner, port, trace, scene.sink());
    var saved: ?audio_mod.Host(Planner).Snapshot = null;
    for (scenario.steps[1..]) |step| {
        if (std.mem.eql(u8, step.op, "commit")) {
            _ = host.commit(.{ .batch = step.batch, .command = step.command, .origin = step.origin }) catch |err| switch (err) {
                error.DuplicateRequest, error.NoStateChange, error.InvalidRequest => {},
                else => return err,
            };
        } else if (std.mem.eql(u8, step.op, "open_sequence")) {
            try host.openSequence();
        } else if (std.mem.eql(u8, step.op, "service")) {
            try host.service();
        } else if (std.mem.eql(u8, step.op, "complete")) {
            const kind = audio_mod.events.tokenKind(step.kind) orelse return error.InvalidScenario;
            host.complete(.{ .kind = kind, .request = step.request, .generation = step.generation, .chunk = step.chunk }) catch |err| switch (err) {
                error.WrongTransferOwner, error.WrongTransferChunk, error.WrongTransferKind, error.NoPendingTransfer, error.PlannerUnbound => {},
                else => return err,
            };
        } else if (std.mem.eql(u8, step.op, "complete_sequence")) {
            const kind = audio_mod.events.tokenKind(step.kind) orelse return error.InvalidScenario;
            host.completeSequence(.{ .kind = kind, .request = 0, .generation = step.generation, .chunk = 0 }) catch |err| switch (err) {
                error.WrongTransferOwner, error.WrongTransferChunk, error.WrongTransferKind, error.NoPendingTransfer, error.PlannerUnbound => {},
                else => return err,
            };
        } else if (std.mem.eql(u8, step.op, "cleanup")) {
            try host.cleanup();
        } else if (std.mem.eql(u8, step.op, "snapshot")) {
            saved = host.snapshot();
        } else if (std.mem.eql(u8, step.op, "restore")) {
            const snapshot = saved orelse return error.InvalidScenario;
            var fresh = audio_mod.Host(Planner).init(content, host.planner, port, trace, scene.sink());
            try fresh.restore(snapshot);
            host = fresh;
        } else {
            return error.InvalidScenario;
        }
    }
    return .{
        .owners = host.owners,
        .pending = host.pendingRequest(),
        .acks = scene.acks,
        .duplicates = scene.duplicates,
    };
}

fn countRows(trace: *const audio_mod.trace.Trace, needle: []const u8) usize {
    var count: usize = 0;
    for (0..trace.count()) |index| {
        if (std.mem.indexOf(u8, trace.row(index), needle) != null) count += 1;
    }
    return count;
}

fn rowIndex(trace: *const audio_mod.trace.Trace, needle: []const u8) ?usize {
    return rowIndexAfter(trace, 0, needle);
}

fn rowIndexAfter(trace: *const audio_mod.trace.Trace, start: usize, needle: []const u8) ?usize {
    var index = start;
    while (index < trace.count()) : (index += 1) {
        if (std.mem.indexOf(u8, trace.row(index), needle) != null) return index;
    }
    return null;
}

fn expectPendingEqual(expected: audio_mod.events.Pending, actual: audio_mod.events.Pending) !void {
    try std.testing.expectEqual(expected.kind, actual.kind);
    try std.testing.expectEqual(expected.request, actual.request);
    try std.testing.expectEqual(expected.generation, actual.generation);
    try std.testing.expectEqual(expected.chunk, actual.chunk);
    try std.testing.expectEqualStrings(expected.phase, actual.phase);
}

fn expectedJoin(allocator: std.mem.Allocator, rows: []const []const u8) ![]u8 {
    var total: usize = 0;
    for (rows, 0..) |row, index| {
        total += row.len;
        if (index + 1 < rows.len) total += 1;
    }
    const bytes = try allocator.alloc(u8, total);
    var cursor: usize = 0;
    for (rows, 0..) |row, index| {
        @memcpy(bytes[cursor..][0..row.len], row);
        cursor += row.len;
        if (index + 1 < rows.len) {
            bytes[cursor] = '\n';
            cursor += 1;
        }
    }
    return bytes;
}

test "asset pins the audio candidate, the runtime interfaces and the plan shape" {
    var opened = try audio_mod.plan.open(std.testing.allocator, data.json);
    defer opened.deinit();
    const content = opened.content();

    try std.testing.expectEqualStrings(audio_mod.plan.schema, content.schema);
    try std.testing.expectEqualStrings("combat_audio", content.package);
    try std.testing.expectEqualStrings(audio_mod.plan.base_snapshot, content.base_snapshot);
    try std.testing.expectEqualStrings(audio_mod.plan.contract_commit, content.contract.commit);
    try std.testing.expectEqualStrings(audio_mod.plan.contract_asset_sha256, content.contract.files.asset.file_sha256);
    try std.testing.expectEqualStrings(audio_mod.plan.contract_asset_canonical_sha256, content.contract.files.asset.canonical_sha256.?);
    try std.testing.expectEqualStrings(audio_mod.plan.contract_source_sha256, content.contract.files.source.file_sha256);
    try std.testing.expectEqualStrings("candidate_only", content.contract.status);

    // the runtime seam is recorded with the exact cue table the host mirrors.
    try std.testing.expectEqual(@as(usize, 3), content.runtime.cue_commands.len);
    try std.testing.expectEqual(@as(u16, 0x81), content.runtime.cue_commands[0].command);
    try std.testing.expectEqualStrings("palace", content.runtime.cue_commands[0].track.?);
    try std.testing.expectEqual(@as(u16, 0x422), content.runtime.cue_commands[1].command);
    try std.testing.expectEqualStrings("audience", content.runtime.cue_commands[1].track.?);
    try std.testing.expectEqual(@as(u16, 0x15), content.runtime.cue_commands[2].command);
    try std.testing.expect(content.runtime.cue_commands[2].track == null);
    try std.testing.expectEqual(@as(usize, 5), content.runtime.interfaces.len);
    for (content.runtime.interfaces) |interface| {
        try std.testing.expectEqual(@as(usize, 64), interface.sha256.len);
        try std.testing.expect(interface.anchors.len > 0);
    }

    try std.testing.expectEqual(@as(usize, 33), content.plan.families.len);
    try std.testing.expectEqual(@as(usize, 47), content.plan.banks.len);
    try std.testing.expectEqual(@as(usize, 4), content.plan.scores.len);
    try std.testing.expectEqual(@as(usize, 10), content.plan.cue_operands.len);
    try std.testing.expectEqual(@as(u32, 120832), content.plan.chunk_bytes);
    try std.testing.expectEqual(@as(u8, 31), content.plan.queue.capacity);
    try std.testing.expectEqualStrings("DATA/00_INIT/SEQ.BIN", content.plan.sequence_open.resource_path);
    var slot: usize = 0;
    for (content.plan.sequence_open.tracks) |track| {
        try std.testing.expectEqual(@as(u8, @intCast(slot)), track.index);
        slot += 1;
    }
    try std.testing.expectEqual([4]u8{ 1, 1, 2, 2 }, [4]u8{
        content.plan.sequence_open.tracks[0].slot,
        content.plan.sequence_open.tracks[1].slot,
        content.plan.sequence_open.tracks[2].slot,
        content.plan.sequence_open.tracks[3].slot,
    });
}

test "committed scenario traces hash to their recorded digests" {
    var opened = try audio_mod.plan.open(std.testing.allocator, data.json);
    defer opened.deinit();
    const content = opened.content();
    try std.testing.expectEqual(@as(usize, 5), content.scenarios.len);
    for (content.scenarios) |scenario| {
        const joined = try expectedJoin(std.testing.allocator, scenario.expected);
        defer std.testing.allocator.free(joined);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(joined, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        try std.testing.expectEqualStrings(scenario.trace_sha256, &hex);
    }
}

test "classification keeps the live stream cue out of the bank/score plan" {
    var opened = try audio_mod.plan.open(std.testing.allocator, data.json);
    defer opened.deinit();
    const content = opened.content();

    // the palace audience cue is family 4, unmodeled as a streamed cue.
    const stream = audio_mod.classifyCommand(content, 0x0422);
    try std.testing.expectEqual(audio_mod.Class.stream, stream.class);
    try std.testing.expectEqual(@as(u8, 4), stream.family);
    // the other two runtime cue-table codes are stream vocabulary too.
    try std.testing.expectEqual(audio_mod.Class.stream, audio_mod.classifyCommand(content, 0x0081).class);
    try std.testing.expectEqual(audio_mod.Class.stream, audio_mod.classifyCommand(content, 0x0015).class);
    // modeled requests.
    try std.testing.expectEqual(audio_mod.Class.bank, audio_mod.classifyCommand(content, 0x0021).class);
    try std.testing.expectEqual(audio_mod.Class.bank, audio_mod.classifyCommand(content, 0x004F).class);
    try std.testing.expectEqual(audio_mod.Class.volume, audio_mod.classifyCommand(content, 0x00B0).class);
    try std.testing.expectEqual(audio_mod.Class.volume, audio_mod.classifyCommand(content, 0x00B1).class);
    try std.testing.expectEqual(audio_mod.Class.score, audio_mod.classifyCommand(content, 0x0201).class);
    try std.testing.expectEqual(audio_mod.Class.score, audio_mod.classifyCommand(content, 0x0204).class);
    try std.testing.expectEqual(audio_mod.Class.cue_candidate, audio_mod.classifyCommand(content, 0x050C).class);
    // unmodeled families and unmapped slots are refused, never guessed.
    const family_three = audio_mod.classifyCommand(content, 0x0301);
    try std.testing.expectEqual(audio_mod.Class.unmodeled, family_three.class);
    try std.testing.expectEqualStrings("family_effects_unmodeled", family_three.blocker.?);
    const unmapped = audio_mod.classifyCommand(content, 0x0701);
    try std.testing.expectEqual(audio_mod.Class.unmodeled, unmapped.class);
    try std.testing.expectEqualStrings("family_slot_unmapped", unmapped.blocker.?);
    const control = audio_mod.classifyCommand(content, 0x0020);
    try std.testing.expectEqual(audio_mod.Class.unmodeled, control.class);
}

test "the Zig host reproduces every committed Python trace" {
    var opened = try audio_mod.plan.open(std.testing.allocator, data.json);
    defer opened.deinit();
    const content = opened.content();
    for (content.scenarios) |scenario| {
        var trace = audio_mod.trace.Trace{};
        var scene = Scene{};
        _ = try runScenario(content, scenario, &trace, &scene);
        try trace.expectRows(scenario.expected);
        try std.testing.expectEqual(@as(usize, 0), scene.duplicates);
    }
}

test "one request per committed event and stop-before-replacement" {
    var opened = try audio_mod.plan.open(std.testing.allocator, data.json);
    defer opened.deinit();
    const content = opened.content();
    var trace = audio_mod.trace.Trace{};
    var scene = Scene{};
    const outcome = try runScenario(content, scenarioNamed(content, "stream_replacement_order").*, &trace, &scene);

    try std.testing.expectEqual(@as(usize, 4), scene.acks);
    try std.testing.expectEqual(@as(usize, 0), scene.duplicates);
    try std.testing.expect(outcome.owners.stream == null);
    try std.testing.expectEqual(@as(usize, 4), countRows(&trace, "request batch="));
    try std.testing.expectEqual(@as(usize, 1), countRows(&trace, "refuse reason=duplicate_request"));
    try std.testing.expectEqual(@as(usize, 1), countRows(&trace, "refuse reason=no_state_change"));

    const audience_start = rowIndex(&trace, "device op=start track=audience").?;
    const palace_stop = rowIndex(&trace, "device op=stop track=audience").?;
    const palace_start = rowIndex(&trace, "device op=start track=palace").?;
    try std.testing.expect(audience_start < palace_stop);
    try std.testing.expect(palace_stop < palace_start);
    const final_stop = rowIndexAfter(&trace, palace_start + 1, "device op=stop track=audience").?;
    try std.testing.expect(palace_start < final_stop);
}

test "no device waives the request and keeps gameplay usable" {
    var opened = try audio_mod.plan.open(std.testing.allocator, data.json);
    defer opened.deinit();
    const content = opened.content();
    var trace = audio_mod.trace.Trace{};
    var scene = Scene{};
    const outcome = try runScenario(content, scenarioNamed(content, "stream_no_device_waived").*, &trace, &scene);

    try std.testing.expectEqual(@as(usize, 2), scene.acks);
    try std.testing.expect(outcome.owners.stream == null);
    try std.testing.expectEqual(@as(usize, 2), countRows(&trace, "playback=unavailable"));
    try std.testing.expectEqual(@as(usize, 0), countRows(&trace, "device op="));
    // two request waivers and the two cleanup writes the device cannot take.
    try std.testing.expectEqual(@as(usize, 4), countRows(&trace, "refuse reason=audio_device_unavailable"));
    // the scene was acknowledged, so a session would not stay busy.
    try std.testing.expectEqual(@as(usize, 2), countRows(&trace, "receipt "));
}

test "a missing completion stays pending across frames and a restart" {
    var opened = try audio_mod.plan.open(std.testing.allocator, data.json);
    defer opened.deinit();
    const content = opened.content();
    var trace = audio_mod.trace.Trace{};
    var scene = Scene{};

    const planner = audio_mod.Double.init(&content.plan);
    var host = audio_mod.Host(audio_mod.Double).init(content, planner, .{ .available = true }, &trace, scene.sink());
    const receipt = try host.commit(.{ .batch = 21, .command = 0x0021, .origin = 4 });
    try std.testing.expectEqual(audio_mod.Service.pending, receipt.service);
    try std.testing.expectEqual(audio_mod.Playback.not_attempted, receipt.playback);
    try host.service();
    const pending = host.pendingRequest().?;
    try std.testing.expectEqual(@as(u8, 0x21), pending.request);
    try std.testing.expectEqualStrings("header_transfer", pending.phase);
    try std.testing.expectEqual(@as(usize, 0), scene.acks);
    try std.testing.expectEqual(audio_mod.Service.pending, host.serviceFor(21, 4).?);

    // a second frame without a token changes nothing.
    try host.service();
    try std.testing.expectEqual(audio_mod.Service.pending, host.serviceFor(21, 4).?);
    try std.testing.expectEqual(@as(usize, 0), scene.acks);

    // a wrong token is refused before the planner mutates state.
    try std.testing.expectError(error.WrongTransferChunk, host.complete(.{ .kind = .transfer_ready, .request = 0x21, .generation = 1, .chunk = 1 }));
    try expectPendingEqual(pending, host.pendingRequest().?);
    try std.testing.expectEqual(audio_mod.Service.pending, host.serviceFor(21, 4).?);

    // a restart keeps the same pending transfer and the same ledger.
    const snapshot = host.snapshot();
    var fresh = audio_mod.Host(audio_mod.Double).init(content, host.planner, .{ .available = true }, &trace, scene.sink());
    try fresh.restore(snapshot);
    try expectPendingEqual(pending, fresh.pendingRequest().?);
    try std.testing.expectEqual(audio_mod.Service.pending, fresh.serviceFor(21, 4).?);
    try std.testing.expectEqual(@as(usize, 0), scene.acks);

    // the real completion chain lands, and only then is the scene acknowledged.
    try fresh.complete(.{ .kind = .transfer_ready, .request = 0x21, .generation = 1, .chunk = 0 });
    try fresh.complete(.{ .kind = .dma_ready, .request = 0x21, .generation = 1, .chunk = 0 });
    try fresh.service();
    try fresh.complete(.{ .kind = .transfer_ready, .request = 0x21, .generation = 1, .chunk = 0 });
    try fresh.complete(.{ .kind = .dma_ready, .request = 0x21, .generation = 1, .chunk = 0 });
    try fresh.complete(.{ .kind = .commit_ready, .request = 0x21, .generation = 1, .chunk = 0 });
    try fresh.complete(.{ .kind = .transfer_ready, .request = 0x21, .generation = 1, .chunk = 1 });
    try fresh.complete(.{ .kind = .dma_ready, .request = 0x21, .generation = 1, .chunk = 1 });
    try fresh.complete(.{ .kind = .commit_ready, .request = 0x21, .generation = 1, .chunk = 1 });
    try std.testing.expectEqual(@as(usize, 1), scene.acks);
    try std.testing.expectEqual(audio_mod.Service.accepted, fresh.serviceFor(21, 4).?);
    try std.testing.expect(fresh.owners.bank != null);
    try std.testing.expect(fresh.pendingRequest() == null);
}

test "sequence and bank owners survive, and only a score stop releases voices" {
    var opened = try audio_mod.plan.open(std.testing.allocator, data.json);
    defer opened.deinit();
    const content = opened.content();
    var trace = audio_mod.trace.Trace{};
    var scene = Scene{};
    const outcome = try runScenario(content, scenarioNamed(content, "sequence_owner_and_score_replacement").*, &trace, &scene);

    try std.testing.expectEqual(@as(?u32, 1), outcome.owners.sequence);
    try std.testing.expectEqual(@as(?u8, 2), outcome.owners.score);
    try std.testing.expect(outcome.owners.bank == null);
    try std.testing.expectEqual(@as(usize, 1), countRows(&trace, "note bank_closed request=0x25"));
    try std.testing.expectEqual(@as(usize, 1), countRows(&trace, "note sequence_owner_retained"));
    try std.testing.expectEqual(@as(usize, 1), countRows(&trace, "refuse reason=score_stop_entry_point_missing"));
    try std.testing.expectEqual(@as(usize, 1), countRows(&trace, "owner stream=- sequence=1 bank=0x25:1:2 score=- voices=2"));

    const first = rowIndex(&trace, "device op=score_start track=- value=1").?;
    const stop = rowIndex(&trace, "device op=score_stop track=- value=1").?;
    const second = rowIndex(&trace, "device op=score_start track=- value=2").?;
    try std.testing.expect(first < stop);
    try std.testing.expect(stop < second);
}

test "cleanup orders stop, volume, loop, and refuses to close a pending bank" {
    var opened = try audio_mod.plan.open(std.testing.allocator, data.json);
    defer opened.deinit();
    const content = opened.content();
    var trace = audio_mod.trace.Trace{};
    var scene = Scene{};
    const outcome = try runScenario(content, scenarioNamed(content, "pending_blocks_bank_close").*, &trace, &scene);

    try std.testing.expect(outcome.owners.bank != null);
    try std.testing.expect(outcome.pending != null);
    const volume = rowIndex(&trace, "device op=volume track=- value=100").?;
    const loop = rowIndex(&trace, "device op=loop track=- value=0").?;
    const refused = rowIndex(&trace, "refuse reason=pending_transfer_blocks_bank_close").?;
    try std.testing.expect(volume < loop);
    try std.testing.expect(loop < refused);
    try std.testing.expectEqual(@as(usize, 0), countRows(&trace, "note bank_closed"));
}

test "no trace row claims playback" {
    var opened = try audio_mod.plan.open(std.testing.allocator, data.json);
    defer opened.deinit();
    const content = opened.content();
    for (content.scenarios) |scenario| {
        var trace = audio_mod.trace.Trace{};
        var scene = Scene{};
        _ = try runScenario(content, scenario, &trace, &scene);
        for (0..trace.count()) |index| {
            const row = trace.row(index);
            try std.testing.expect(std.mem.indexOf(u8, row, "playback=played") == null);
            if (std.mem.indexOf(u8, row, "receipt ") != null) {
                const accepted = std.mem.indexOf(u8, row, "playback=not_attempted") != null or
                    std.mem.indexOf(u8, row, "playback=unavailable") != null or
                    std.mem.indexOf(u8, row, "playback=refused") != null;
                try std.testing.expect(accepted);
            }
        }
    }
}

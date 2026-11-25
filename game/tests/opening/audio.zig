const std = @import("std");
const audio = @import("opening_audio");
const media = audio.raw_media_owner;
const transfer = audio.logical_bank_transfer;
const seq = audio.sequence_stop;
const staging = audio.sound_staging;
const sound = audio.sound_globals;

fn pinnedReceipt() media.Receipt {
    return .{
        .stay = .{ .id = .stay, .request = 0x21, .slot = 0, .va_sha256 = "95051a43cf81d4303633d91379a08e45e13f03e33320bb7b14d2b3b666109952".*, .vb_sha256 = "10bc5bdeb7fb861208b1f1473cdc28d489fad44a00a5aa484ca2f1bb6b5815bd".*, .programs = 5, .tones = 64, .samples = 44, .sample_bytes = 208768 },
        .orch = .{ .id = .orch, .request = 0x25, .slot = 1, .va_sha256 = "cb4be9f6e3a86d522a55f6f62ccb0df8a0dc74d9adc4552fee23fa34af160fea".*, .vb_sha256 = "b44df918d55cd6c0453acdffa003781255d15f1f290163d830bb1ecf1b6c4979".*, .programs = 12, .tones = 16, .samples = 13, .sample_bytes = 108784 },
        .sequence_sha256 = "ad0bead9bea912e046ddd2947e4c2eaca747bb0af6be1e9baf8723abb3d068c8".*,
        .sequences = .{
            .{ .index = 0, .offset = 0, .length = 15812, .bank_slot = 1, .ppqn = 480, .microseconds_per_quarter = 500000 },
            .{ .index = 1, .offset = 15812, .length = 18540, .bank_slot = 1, .ppqn = 480, .microseconds_per_quarter = 521739 },
            .{ .index = 2, .offset = 34352, .length = 10086, .bank_slot = 2, .ppqn = 480, .microseconds_per_quarter = 717703 },
            .{ .index = 3, .offset = 44438, .length = 26724, .bank_slot = 2, .ppqn = 480, .microseconds_per_quarter = 525854 },
        },
    };
}

fn emptyVoiceStaging() staging.State {
    const tr: staging.Transition = .{ .active = 0, .delta = 0, .period = 0, .countdown = 0, .current = 0, .target = 0 };
    return .{ .voices = .{ .checkpoint = 4, .callback_token = 3, .sample_clock = 10, .allocator = .{}, .keys = @splat(.{ .owner = -1, .slot = -1, .program = -1, .note = -1, .sample = 0 }), .pending_key_on = 0, .pending_key_off = 0 }, .images = @splat(.{ .left = 0, .right = 0, .pitch = 0, .sample = null, .adsr1 = 0, .adsr2 = 0 }), .pitches = @splat(0), .tones = @splat(null), .dirty = @splat(0), .volume_transitions = @splat(tr), .pan_transitions = @splat(tr), .noise_enabled = 0, .reverb_enabled = 0, .cd_input = .{ 0, 0 }, .adsr2_bias = 0, .revision = 0, .receipt = 0 };
}

// Explicit synthetic fixture: these handle records do not attest a real open.
fn syntheticSequenceOwner() seq.Owner {
    const steps = [4]u16{ 160, 153, 112, 152 };
    var records: [4]seq.Record = undefined;
    for (&records, 0..) |*r, i| r.* = .{ .handle = @intCast(i), .bank_slot = if (i < 2) 1 else 2, .generation = 1, .flags = 0x20b, .cursor = seq.starts[i] + 1, .start = seq.starts[i], .loop_cursor = seq.starts[i] + 1, .event_control = @splat(9), .loop_control = @splat(9), .control_word = 9, .countdown = -1, .step = 7, .initial_step = steps[i], .initial_delay = 0, .delay = 9, .zero_word = 9, .initial_bpm = seq.initial_bpm[i], .current_bpm = 9, .channels = @splat(.{ .program = 99, .pan = 1, .volume = 2 }), .levels = .{ 1, 2 }, .master_levels = .{ 127, 127 }, .last_velocity = 127 };
    return .{ .state = .{ .records = records, .voice = emptyVoiceStaging(), .generation = 1, .revision = 0, .receipt = 0 }, .rate = 60 };
}

fn sequenceStopRequest() seq.Request {
    return .{ .instance = 1, .batch = 2, .origin = 3 };
}

fn bootInputFixture() sound.BootInput {
    return .{ .template_sha256 = sound.boot_sha256, .setting_1b92 = 0 };
}

test "logical transfer refuses unverified bytes before closing or publishing a slot" {
    const allocator = std.testing.allocator;
    const stay_va = try allocator.alloc(u8, 5152);
    const stay_vb = try allocator.alloc(u8, 208768);
    const orch_va = try allocator.alloc(u8, 8736);
    const orch_vb = try allocator.alloc(u8, 108784);
    const seq_buf = try allocator.alloc(u8, 71162);
    @memset(stay_va, 0);
    @memset(stay_vb, 0);
    @memset(orch_va, 0);
    @memset(orch_vb, 0);
    @memset(seq_buf, 0);

    var source = media.Loaded{ .allocator = allocator, .stay = .{ .va = stay_va, .vb = stay_vb }, .orch = .{ .va = orch_va, .vb = orch_vb }, .seq = seq_buf, .receipt = std.mem.zeroes(media.Receipt) };
    defer source.deinit();
    var owner = transfer.Owner.init(allocator);
    defer owner.deinit();
    const before = try owner.snapshot();
    try std.testing.expectError(error.SourceHashMismatch, owner.closeSlot(source, 0x21, 1));
    try std.testing.expect(std.meta.eql(before, try owner.snapshot()));
    try std.testing.expectEqual(transfer.Status.empty, try owner.status(0));
    try std.testing.expect(!(try owner.selectorAvailable(0)));
}

test "source-order request mapping is bounded to STAY then ORCH" {
    const allocator = std.testing.allocator;
    var owner = transfer.Owner.init(allocator);
    defer owner.deinit();
    try std.testing.expectEqual(transfer.Status.empty, try owner.status(0));
    try std.testing.expectEqual(transfer.Status.empty, try owner.status(1));
    try std.testing.expectError(error.InvalidLogicalBankSlot, owner.status(3));
}

test "status rejects forged nonempty metadata with missing or corrupted buffers" {
    const allocator = std.testing.allocator;
    var missing = transfer.Owner.init(allocator);
    missing.source_receipt = pinnedReceipt();
    missing.state = .{ .completed = 0, .last_generation = 2, .pending = .{ .bank = .stay, .generation = 2, .phase = .header_loaded }, .slots = .{ .{ .status = .header_only, .bank = .stay, .generation = 2 }, .{}, .{} } };
    try std.testing.expectError(error.InvalidLogicalBankStorage, missing.snapshot());
    try std.testing.expectError(error.InvalidLogicalBankStorage, missing.status(0));
    missing.deinit();

    var corrupted = transfer.Owner.init(allocator);
    corrupted.source_receipt = pinnedReceipt();
    corrupted.state = .{ .completed = 1, .last_generation = 2, .slots = .{ .{ .status = .resident, .bank = .stay, .generation = 2 }, .{}, .{} } };
    const va = try allocator.alloc(u8, 5152);
    const vb = try allocator.alloc(u8, 208768);
    @memset(va, 0);
    @memset(vb, 0);
    corrupted.storage[0] = .{ .va = va, .vb = vb };
    defer corrupted.deinit();
    try std.testing.expectError(error.InvalidLogicalBankStorage, corrupted.snapshot());
    try std.testing.expectError(error.InvalidLogicalBankStorage, corrupted.status(0));
}

test "stop two synthetic opened handles and only their voices" {
    var owner = syntheticSequenceOwner();
    owner.state.voice.voices.keys[0] = .{ .owner = 0, .slot = 0, .program = 0, .note = 2, .sample = 0xff };
    owner.state.voice.voices.keys[1] = .{ .owner = 1, .slot = 0, .program = 0, .note = 3, .sample = 7 };
    owner.state.voice.voices.keys[2] = .{ .owner = 33, .slot = 0, .program = 0, .note = 3, .sample = 8 };
    owner.state.voice.voices.allocator.voices[0] = .{ .status = 1, .level = 123, .priority = 7, .age = 8 };
    owner.state.voice.pitches[0] = 500;
    owner.state.voice.voices.pending_key_on = 15;
    const proposal = try owner.proposeStop(sequenceStopRequest(), 1);
    try std.testing.expectEqual([2]u32{ 1, 2 }, proposal.stopped_masks);
    try std.testing.expectEqual(@as(u32, 0x204), proposal.after.records[0].flags);
    try std.testing.expectEqual(seq.starts[0], proposal.after.records[0].cursor);
    try std.testing.expectEqual(@as(u8, 15), proposal.after.records[0].channels[15].program);
    try std.testing.expectEqual(@as(u16, 127), proposal.after.records[0].channels[15].volume);
    try std.testing.expectEqual(@as(u32, 0x20b), proposal.after.records[2].flags);
    try std.testing.expectEqual(@as(i16, 0), proposal.after.voice.voices.keys[0].sample);
    try std.testing.expectEqual(@as(i16, 8), proposal.after.voice.voices.keys[2].sample);
    try std.testing.expectEqual(@as(u16, 123), proposal.after.voice.voices.allocator.voices[0].level);
    try std.testing.expectEqual(@as(u32, 3), proposal.after.voice.voices.pending_key_off);
    try std.testing.expectEqual(@as(u32, 12), proposal.after.voice.voices.pending_key_on);
    var receipt: seq.Receipt = .{ .token = 1, .revision = 0, .request = sequenceStopRequest(), .stopped_masks = proposal.stopped_masks };
    receipt.stopped_masks[0] = 0;
    try std.testing.expectError(error.InvalidSequenceStopReceipt, owner.commit(proposal, receipt));
    try std.testing.expect(std.meta.eql(owner.state, proposal.before));
    receipt.stopped_masks = proposal.stopped_masks;
    try owner.commit(proposal, receipt);
    try std.testing.expectError(error.StaleSequenceState, owner.commit(proposal, receipt));
}

test "corrupt bytes and immutable opened-handle fields are refused" {
    const bytes: [71162]u8 = @splat(0);
    try std.testing.expectError(error.InvalidSequenceSource, seq.verifySource(&bytes));
    var owner = syntheticSequenceOwner();
    owner.state.records[0].start += 1;
    try std.testing.expectError(error.InvalidSequenceState, owner.proposeStop(sequenceStopRequest(), 1));
}

test "source header initializer derives records and retains prior levels" {
    const headers = [4][16]u8{
        .{ 0x70, 0x51, 0x45, 0x53, 0, 0, 0, 1, 1, 0xe0, 0x07, 0xa1, 0x20, 2, 2, 0 },
        .{ 0x70, 0x51, 0x45, 0x53, 0, 0, 0, 1, 1, 0xe0, 0x07, 0xf6, 0x0b, 2, 2, 0 },
        .{ 0x70, 0x51, 0x45, 0x53, 0, 0, 0, 1, 1, 0xe0, 0x0a, 0xf3, 0x87, 3, 2, 0 },
        .{ 0x70, 0x51, 0x45, 0x53, 0, 0, 0, 1, 1, 0xe0, 0x08, 0x06, 0x1e, 3, 2, 0 },
    };
    const steps = [4]u16{ 160, 153, 112, 152 };
    for (headers, 0..) |header, i| {
        const record = try seq.initialRecord(&header, @intCast(i), 1, 60, .{ 12, 34 });
        try std.testing.expectEqual(seq.starts[i], record.start);
        try std.testing.expectEqual(steps[i], record.initial_step);
        try std.testing.expectEqual([2]u16{ 12, 34 }, record.levels);
        try std.testing.expectEqual(@as(u16, 127), record.last_velocity);
        try std.testing.expectEqual(@as(u8, 15), record.channels[15].program);
    }
    var bad = headers[0];
    bad[15] = 1;
    try std.testing.expectError(error.InvalidSequenceSource, seq.initialRecord(&bad, 0, 1, 60, .{ 0, 0 }));
    try std.testing.expectError(error.InvalidSequenceClockRate, seq.initialRecord(&headers[0], 0, 1, 30, .{ 0, 0 }));
}

test "VAB structural parser checks program, tone, and sample extents" {
    var va: [0x822]u8 = @splat(0);
    @memcpy(va[0..4], "pBAV");
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, va[0x12..0x14], .little));
    const parsed = try media.inspectVab(&va, &.{});
    try std.testing.expectEqual(@as(u16, 0), parsed.programs);
    try std.testing.expectEqual(@as(u16, 0), parsed.tones);
    try std.testing.expectEqual(@as(u16, 0), parsed.samples);

    va[0x820] = 1;
    try std.testing.expectError(error.InvalidVabSampleTable, media.inspectVab(&va, &.{}));
}

test "raw source verifier rejects truncated and same-size unpinned inputs" {
    const stay_va: [5152]u8 = @splat(0);
    const stay_vb: [208768]u8 = @splat(0);
    const orch_va: [8736]u8 = @splat(0);
    const orch_vb: [108784]u8 = @splat(0);
    const seq_buf: [71162]u8 = @splat(0);
    try std.testing.expectError(error.SourceExtentMismatch, media.verify(.{
        .stay = .{ .va = stay_va[0 .. stay_va.len - 1], .vb = &stay_vb },
        .orch = .{ .va = &orch_va, .vb = &orch_vb },
        .seq = &seq_buf,
    }));
    try std.testing.expectError(error.SourceHashMismatch, media.verify(.{
        .stay = .{ .va = &stay_va, .vb = &stay_vb },
        .orch = .{ .va = &orch_va, .vb = &orch_vb },
        .seq = &seq_buf,
    }));
    try std.testing.expectError(error.SourceHashMismatch, media.load(std.testing.allocator, .{
        .stay = .{ .va = &stay_va, .vb = &stay_vb },
        .orch = .{ .va = &orch_va, .vb = &orch_vb },
        .seq = &seq_buf,
    }));
}

test "source mode commands replay atomically" {
    var owner = try sound.Owner.init(bootInputFixture());
    try std.testing.expectEqual(@as(u8, 1), owner.state.mode_9be8);
    const p = try owner.propose(.mode_0_command_1);
    var forged = p;
    forged.after.adjustment_9c12 = 0x41;
    try std.testing.expectError(error.StaleOrForged, owner.commit(forged));
    try std.testing.expectEqual(@as(u64, 0), owner.state.revision);
    try owner.commit(p);
    try std.testing.expectEqual(@as(u16, 0x37), owner.state.adjustment_9c12);
    try std.testing.expectError(error.StaleOrForged, owner.commit(p));
    const q = try owner.propose(.mode_1_command_2);
    try owner.commit(q);
    try std.testing.expectEqual(@as(u16, 0x41), owner.state.adjustment_9c12);
}

test "boot identity and checkpoint are bounded" {
    var boot = bootInputFixture();
    boot.setting_1b92 = 1;
    try std.testing.expectError(error.InvalidBoot, sound.Owner.init(boot));
    boot = bootInputFixture();
    boot.template_sha256[0] = 'x';
    try std.testing.expectError(error.InvalidBoot, sound.Owner.init(boot));
    var owner = try sound.Owner.init(bootInputFixture());
    const p = try owner.propose(.mode_0_command_1);
    try owner.commit(p);
    _ = try sound.Owner.restore(owner.state);
    var invalid = owner.state;
    invalid.receipt = 0;
    try std.testing.expectError(error.InvalidState, sound.Owner.restore(invalid));
}

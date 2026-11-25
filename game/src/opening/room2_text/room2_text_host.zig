//! Bounded source event/text adapter for VA1 room2 entity2.
//! Unsupported non-text effects remain the caller's responsibility.
const std = @import("std");
const runtime = @import("event_runtime");
const room = @import("room2_text.zig");
const source = @import("room2_text_binding.zig");
const destination_data = @import("opening_assets").destination;

const Packet = struct { constructor: struct { va1_room2: struct { events: runtime.Content } } };
pub const Pad = struct {
    pressed: u32 = 0,
    held: u32 = 0,
    /// Caller verifies all other source low flag owners are clear.
    other_low_flags_clear: bool = false,
};
pub const Result = enum { advanced, waiting, completed };
pub const Opened = struct {
    allocator: std.mem.Allocator,
    text_source: source.Opened,
    packet: std.json.Parsed(Packet),
    canonical_event: []u8,
    pub fn deinit(self: *Opened) void {
        self.allocator.free(self.canonical_event);
        self.packet.deinit();
        self.text_source.deinit();
    }
    fn content(self: *const Opened) runtime.Content {
        return self.packet.value.constructor.va1_room2.events;
    }
    fn validate(self: *const Opened, allocator: std.mem.Allocator) !void {
        const bytes = try std.json.Stringify.valueAlloc(allocator, self.content(), .{});
        defer allocator.free(bytes);
        if (!std.mem.eql(u8, bytes, self.canonical_event)) return error.Room2EventIdentityMismatch;
        const c = self.content();
        try c.validate();
        const program = c.program("va1_r02_e02_ordinary") orelse return error.Room2EventIdentityMismatch;
        if (!std.mem.eql(u8, c.id, "va1_room2_field_events") or program.entity != 2 or program.entry != .ordinary) return error.Room2EventIdentityMismatch;
    }
};

/// Opened owns all event and text slices. It and Hero-name storage must remain
/// alive and immutable until the instance and any snapshots have been rebound.
pub fn open(allocator: std.mem.Allocator, native_bytes: []const u8, packet_bytes: []const u8) !Opened {
    var text_source = try source.open(allocator, native_bytes, packet_bytes);
    errdefer text_source.deinit();
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(packet_bytes, &digest, .{});
    if (!std.mem.eql(u8, &std.fmt.bytesToHex(digest, .lower), destination_data.asset_sha256)) return error.Room2EventIdentityMismatch;
    const packet = try std.json.parseFromSlice(Packet, allocator, packet_bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    errdefer packet.deinit();
    const canonical = try std.json.Stringify.valueAlloc(allocator, packet.value.constructor.va1_room2.events, .{});
    errdefer allocator.free(canonical);
    const result: Opened = .{ .allocator = allocator, .text_source = text_source, .packet = packet, .canonical_event = canonical };
    try result.validate(allocator);
    return result;
}

fn equalJson(allocator: std.mem.Allocator, a: anytype, b: @TypeOf(a)) !bool {
    const x = try std.json.Stringify.valueAlloc(allocator, a, .{});
    defer allocator.free(x);
    const y = try std.json.Stringify.valueAlloc(allocator, b, .{});
    defer allocator.free(y);
    return std.mem.eql(u8, x, y);
}
fn action(effect: runtime.Command, serial: u64, batch: u64) !?room.Action {
    const off = effect.source_offset orelse return null;
    return switch (off) {
        0x3d193 => if (effect.kind == .open_box and effect.box == 0 and effect.layout == 0) .{ .open = .layout_zero } else error.InvalidRoom2EventEffect,
        0x3d195, 0x3d1cb => if (effect.kind == .native_slot_prefix and effect.box == 0 and effect.code == 108)
            .{ .native = .{ .slot = .first, .code = 108, .command = .{ .instance = serial, .batch = batch, .origin = effect.origin } } }
        else
            error.InvalidRoom2EventEffect,
        0x3d198 => if (effect.kind == .text and effect.box == 0 and effect.text != null and std.mem.eql(u8, effect.text.?, "va1_r02_text_5")) .{ .body = .entry5 } else error.InvalidRoom2EventEffect,
        0x3d1c5 => if (effect.kind == .source_spawn_text and effect.box == 0 and effect.x == 10 and effect.y == 10 and effect.width == 12 and effect.height == 2) .{ .open = .fixed_10_10_12_2 } else error.InvalidRoom2EventEffect,
        0x3d1ce => if (effect.kind == .text and effect.box == 0 and effect.text != null and std.mem.eql(u8, effect.text.?, "va1_r02_text_47")) .{ .body = .entry47 } else error.InvalidRoom2EventEffect,
        0x3d19d => if (effect.kind == .close_box and effect.box == 0) .close_0c else error.InvalidRoom2EventEffect,
        0x3d1d3 => if (effect.kind == .source_close_keep_image and effect.box == 0) .close_01 else error.InvalidRoom2EventEffect,
        0x3d1d5 => if (effect.kind == .end_stream) .fd else error.InvalidRoom2EventEffect,
        else => null,
    };
}

/// Validate the full pending batch by regenerating it from its original VM PC.
/// Completion signals only resolve a previously installed source wait.
fn validatePending(allocator: std.mem.Allocator, content: runtime.Content, instance: runtime.Instance, story: runtime.StoryState) !void {
    const pending = instance.pending orelse return;
    if (pending.batch.id == 0 or pending.batch.id != instance.effect_sequence or pending.batch.effect_count != 1) return error.InvalidRoom2EventEffect;
    var prior = instance;
    prior.pending = null;
    prior.effect_sequence = pending.batch.id - 1;
    var story_copy = story;
    const wait_id = if (prior.execution.wait) |wait| wait.id else "";
    const completions = [_][]const u8{ wait_id, "dialogue_flags", "box_0" };
    _ = try runtime.step(content, &prior, &story_copy, .{ .confirm = true, .completions = &completions });
    const expected = prior.pending orelse return error.InvalidRoom2EventEffect;
    if (!try equalJson(allocator, expected, pending)) return error.InvalidRoom2EventEffect;
}

/// Last committed event batch identity, matching the field Session receipt.
pub const Receipt = struct {
    content_sha256: []const u8,
    program: []const u8,
    instance: u64,
    batch: u64,
};
fn commandPc(program: runtime.Program, offset: u32) !u16 {
    for (program.commands, 0..) |command, i| if (command.source_offset == offset) return @intCast(i);
    return error.Room2EventIdentityMismatch;
}

/// Read-only checkpoint check. The caller must additionally authenticate the
/// source selection, complete event history, other owners and story history.
pub fn validateSnapshot(allocator: std.mem.Allocator, opened: *const Opened, instance: *const runtime.Instance, story: *const runtime.StoryState, text: *const room.State, serial: u64, receipt: ?Receipt, hero_name: []const u8, text_speed: u8, generation: u64) !void {
    if (serial == 0 or !std.mem.eql(u8, story.schema, "suikoden-event-story/1")) return error.InvalidRoom2EventEffect;
    try opened.validate(allocator);
    const c = opened.content();
    if (!std.mem.eql(u8, instance.program_id, "va1_r02_e02_ordinary") or instance.execution.reloop) return error.Room2EventIdentityMismatch;
    try instance.validate(c);
    try validatePending(allocator, c, instance.*, story.*);
    const tb = try opened.text_source.bind(hero_name, text_speed, generation);
    try text.validate(tb);
    const p = c.program(instance.program_id) orelse return error.Room2EventIdentityMismatch;
    const first_open = try commandPc(p, 0x3d193);
    const first_native = try commandPc(p, 0x3d195);
    const first_body = try commandPc(p, 0x3d198);
    const first_accept = try commandPc(p, 0x3d19c);
    const first_close = try commandPc(p, 0x3d19d);
    const first_wait = try commandPc(p, 0x3d19e);
    const second_open = try commandPc(p, 0x3d1c5);
    const second_native = try commandPc(p, 0x3d1cb);
    const second_body = try commandPc(p, 0x3d1ce);
    const second_accept = try commandPc(p, 0x3d1d2);
    const second_close = try commandPc(p, 0x3d1d3);
    const finish = try commandPc(p, 0x3d1d5);
    const pc = instance.execution.pc;
    const prior_batch = if (instance.pending != null) instance.effect_sequence - 1 else instance.effect_sequence;
    if (prior_batch == 0) {
        if (receipt != null) return error.InvalidRoom2EventReceipt;
    } else {
        const r = receipt orelse return error.InvalidRoom2EventReceipt;
        if (r.instance != serial or r.batch != prior_batch or !std.mem.eql(u8, r.program, p.id) or !std.mem.eql(u8, r.content_sha256, c.content_sha256)) return error.InvalidRoom2EventReceipt;
    }
    if (text.owner.slots[0].waiting) |request| {
        const pending = instance.pending orelse return error.InvalidRoom2EventEffect;
        const effect = pending.batch.effects[0];
        if (effect.kind != .native_slot_prefix or request.slot != .first or request.code != 108 or
            request.command.instance != serial or request.command.batch != pending.batch.id or request.command.origin != effect.origin or
            effect.origin != pc or (pc != first_native and pc != second_native)) return error.InvalidRoom2EventEffect;
    }
    switch (text.phase) {
        .absent => {
            if (text.job != .none or !((pc <= first_open) or (pc >= first_wait and pc <= second_open) or pc >= finish)) return error.InvalidRoom2EventEffect;
        },
        .opening, .open => {
            const first = text.geometry == .layout_zero;
            const native_pc = if (first) first_native else second_native;
            const body_pc = if (first) first_body else second_body;
            const accept_pc = if (first) first_accept else second_accept;
            const close_pc = if (first) first_close else second_close;
            if (pc < native_pc or pc > close_pc) return error.InvalidRoom2EventEffect;
            const image = text.owner.slots[0].image;
            switch (text.job) {
                .none => {
                    if (pc != native_pc and pc != body_pc) return error.InvalidRoom2EventEffect;
                    if (pc == native_pc and (instance.pending != null or image != null)) return error.InvalidRoom2EventEffect;
                    if (pc == body_pc and (image == null or image.?.id != 513 or image.?.origin != .custom)) return error.InvalidRoom2EventEffect;
                },
                .prefix => if (pc != native_pc or text.owner.slots[0].waiting == null or instance.pending == null or image == null or image.?.id != 513 or image.?.origin != .custom) return error.InvalidRoom2EventEffect,
                .body5, .body47 => {
                    if ((first and text.job != .body5) or (!first and text.job != .body47) or (pc != accept_pc and pc != close_pc) or
                        image == null or image.?.id != 513 or image.?.origin != .custom or (pc == close_pc and !text.bodyDone())) return error.InvalidRoom2EventEffect;
                    if (pc == accept_pc) {
                        const wait = instance.execution.wait orelse return error.InvalidRoom2EventEffect;
                        const expected_id = if (first) tb.body5.id else tb.body47.id;
                        if (!((wait.kind == .text and std.mem.eql(u8, wait.id, expected_id)) or (wait.kind == .accept and text.bodyDone()))) return error.InvalidRoom2EventEffect;
                    }
                },
            }
        },
        .closing, .release_pending => {
            if (text.job != .none or text.owner.slots[0].waiting != null) return error.InvalidRoom2EventEffect;
            const image = text.owner.slots[0].image;
            if (text.geometry == .layout_zero) {
                if (pc != first_wait or image != null) return error.InvalidRoom2EventEffect;
            } else if (pc != finish or image == null or image.?.id != 513 or image.?.origin != .custom) return error.InvalidRoom2EventEffect;
        },
    }
}

/// One call is one real field pass. The caller must schedule non-text source
/// effects elsewhere, and must not also tick the same slot or text state.
pub fn pass(allocator: std.mem.Allocator, opened: *const Opened, instance: *runtime.Instance, story: *runtime.StoryState, text: *room.State, serial: u64, hero_name: []const u8, text_speed: u8, generation: u64, pad: Pad) !Result {
    if (serial == 0 or !std.mem.eql(u8, story.schema, "suikoden-event-story/1")) return error.InvalidRoom2EventEffect;
    try opened.validate(allocator);
    const c = opened.content();
    const tb = try opened.text_source.bind(hero_name, text_speed, generation);
    try instance.validate(c);
    if (!std.mem.eql(u8, instance.program_id, "va1_r02_e02_ordinary")) return error.Room2EventIdentityMismatch;
    try text.validate(tb);
    try validatePending(allocator, c, instance.*, story.*);
    if (text.owner.slots[0].waiting) |request| {
        const pending = instance.pending orelse return error.InvalidRoom2EventEffect;
        if (pending.batch.effect_count != 1 or pending.batch.effects[0].kind != .native_slot_prefix or
            request.command.instance != serial or request.command.batch != pending.batch.id or
            request.command.origin != pending.batch.effects[0].origin or request.code != 108 or request.slot != .first)
            return error.InvalidRoom2EventEffect;
    }
    if (instance.pending == null and instance.effect_sequence == std.math.maxInt(u64)) return error.Room2EventSequenceExhausted;
    if (instance.execution.reloop) return error.UnsupportedRoom2TextEffect;
    var next_instance = instance.*;
    var next_story = story.*;
    var next_text = text.*;
    var completions: [3][]const u8 = undefined;
    var count: usize = 0;
    if (next_text.phase == .absent) {
        completions[count] = "box_0";
        count += 1;
    }
    if (next_text.fdReady() and pad.other_low_flags_clear) {
        completions[count] = "dialogue_flags";
        count += 1;
    }
    if (next_text.bodyDone()) {
        completions[count] = if (next_text.job == .body5) tb.body5.id else tb.body47.id;
        count += 1;
    }
    const stepped = try runtime.step(c, &next_instance, &next_story, .{ .confirm = pad.pressed & 0x65 != 0, .completions = completions[0..count] });
    var result: Result = .advanced;
    if (stepped.batch) |batch| {
        if (batch.effect_count != 1 or next_instance.pending.?.story_write_count != 0) return error.UnsupportedRoom2TextEffect;
        try validatePending(allocator, c, next_instance, next_story);
        const selected = (try action(batch.effects[0], serial, batch.id)) orelse return error.UnsupportedRoom2TextEffect;
        const slot_result = try next_text.pass(tb, .{ .action = selected, .pressed = pad.pressed, .held = pad.held });
        if (slot_result == .advance) {
            try runtime.acknowledge(c, &next_instance, &next_story, batch.id);
        } else result = .waiting;
    } else {
        _ = try next_text.pass(tb, .{ .action = .none, .pressed = pad.pressed, .held = pad.held });
        if (stepped.status == .waiting) result = .waiting;
    }
    try next_instance.validate(c);
    try next_text.validate(tb);
    if (!next_instance.execution.active and next_instance.pending == null) result = .completed;
    instance.* = next_instance;
    story.* = next_story;
    text.* = next_text;
    return result;
}

/// Construct the source event from its real guard. Tests may explicitly move
/// the returned PC for isolated effect fixtures; production must not do so.
pub fn start(opened: *const Opened, story: *const runtime.StoryState) !runtime.Instance {
    try opened.validate(opened.allocator);
    return runtime.start(opened.content(), story, "va1_r02_e02_ordinary");
}

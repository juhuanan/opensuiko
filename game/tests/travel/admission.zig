//! Focused gate: real event admission and completion production.
//!
//! Pure/port-level only: no original instruction, no emulator, no window, no
//! media, no save file. The real dispatch packet, population and event contents
//! are read from the repository root, so a content or type change breaks this
//! gate instead of silently drifting from the packet.

const std = @import("std");
const admission_mod = @import("travel").admission;
const data = @import("travel_data").admission;
const dispatch = admission_mod.dispatch;
const population = admission_mod.population;
const runtime = admission_mod.runtime;
const source = admission_mod.source;
const hostmod = admission_mod.host;

const finite = std.Io.Limit.limited(4 * 1024 * 1024);

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, finite);
}

fn loadDispatch(allocator: std.mem.Allocator) !std.json.Parsed(dispatch.Packet) {
    const bytes = try readFile(allocator, "game/assets/scenes/dispatch/vaa_vb6.json");
    defer allocator.free(bytes);
    return dispatch.load(allocator, bytes);
}

fn loadPopulation(allocator: std.mem.Allocator, scene_id: []const u8) !std.json.Parsed(population.Packet) {
    const path = if (std.mem.eql(u8, scene_id, "vaa_room2"))
        "game/assets/scenes/population/vaa_room2.json"
    else
        "game/assets/scenes/population/vb6_room6.json";
    const bytes = try readFile(allocator, path);
    defer allocator.free(bytes);
    return population.load(allocator, bytes);
}

const LinkedBundle = struct { contents: []const struct { content: ?runtime.Content = null } };
const Contents = struct {
    bundle: std.json.Parsed(LinkedBundle),
    external: std.json.Parsed(runtime.Content),
    values: [8]runtime.Content = undefined,
    count: usize = 0,
    fn slice(self: *const Contents) []const runtime.Content {
        return self.values[0..self.count];
    }
    fn deinit(self: Contents) void {
        self.external.deinit();
        self.bundle.deinit();
    }
};

fn loadContents(allocator: std.mem.Allocator, scene_id: []const u8) !Contents {
    const path = if (std.mem.eql(u8, scene_id, "vaa_room2"))
        "game/assets/scenes/events/vaa_room2.json"
    else
        "game/assets/scenes/events/vb6_room6.json";
    const bytes = try readFile(allocator, path);
    defer allocator.free(bytes);
    var result: Contents = .{
        .bundle = try std.json.parseFromSlice(LinkedBundle, allocator, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }),
        .external = undefined,
    };
    errdefer result.bundle.deinit();
    for (result.bundle.value.contents) |record| if (record.content) |content| {
        result.values[result.count] = content;
        result.count += 1;
    };
    const external = try readFile(allocator, "game/assets/events/vb6_room6_field_host.json");
    defer allocator.free(external);
    result.external = try std.json.parseFromSlice(runtime.Content, allocator, external, .{ .allocate = .alloc_always });
    result.values[result.count] = result.external.value;
    result.count += 1;
    return result;
}

fn findContent(contents: []const runtime.Content, id: []const u8, hash: []const u8) ?runtime.Content {
    for (contents) |content| {
        if (std.mem.eql(u8, content.id, id) and std.mem.eql(u8, content.content_sha256, hash)) return content;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Conformance JSON
// ---------------------------------------------------------------------------

const GameJson = struct {
    flags_37: u8 = 0,
    encounter_enabled_159a: u8 = 0,
    encounter_pending_36: u8 = 0,
    suppress_bd7a: u8 = 0,
    encounter_threshold_30: u8 = 0,
    encounter_timer_159c: u8 = 0,
    area_header: bool = false,
    area_header_word_38: bool = false,
    free_reservation_hi: u16 = 0,
};
const VmJson = struct {
    upload_mode_16b8: u8 = 0,
    state_flags_c028: u16 = 0,
    slot_busy_dbb4: u8 = 0,
    box1_busy_dbc8: u8 = 0,
};
const CallbacksJson = struct {
    area_498: []const u8 = "none",
    area_49c: []const u8 = "none",
};
const FrameJson = struct {
    index: u64,
    installed_driver: u32,
    event_active: u8 = 0,
    init_done: u8 = 0,
    completion_flag: u8 = 0,
    menu_state: u8 = 0,
    game_state: GameJson = .{},
    vm: VmJson = .{},
    callbacks: CallbacksJson = .{},
    encounter_claim: ?bool = null,
    predicates: []const u8 = "exclude",
    interaction_entity: ?u8 = null,
    event_flags_low2: u8 = 0,
};
const PendingJson = struct { batch: u64, origin: u16 };
const OwnerJson = struct {
    content_id: []const u8,
    content_sha256: []const u8,
    program_id: []const u8,
    serial: u64,
    active: bool,
    pc: u16,
    wait: ?[]const u8 = null,
    reloop: bool = true,
    effect_sequence: u64 = 0,
    receipt_batch: ?u64 = null,
    pending: ?PendingJson = null,
};
const SelectionJson = struct {
    content_id: []const u8,
    content_sha256: []const u8,
    program_id: []const u8,
    frame: u64,
    prior_serial: u64,
};
const HostJson = struct {
    cursor: u8 = 0,
    construction_done: bool = false,
    last_frame: ?u64 = null,
    construction_frame: ?u64 = null,
    completion_frame: ?u64 = null,
    owner: ?OwnerJson = null,
    pending_selection: ?SelectionJson = null,
    completed: bool = false,
    last_completion: ?std.json.Value = null,
};
const ExpectJson = struct {
    phase: []const u8,
    admitted: bool,
    action: []const u8,
    decision_kind: ?[]const u8 = null,
    source_order: ?u8 = null,
    program_id: ?[]const u8 = null,
    reason: ?[]const u8 = null,
    completion: []const u8,
    completion_batch: ?u64 = null,
    free_gate: []const u8,
    vm_gate: []const u8,
    vm_reason: ?[]const u8 = null,
    cursor: u8,
    construction_done: bool,
    free_ready: bool,
    owner_serial: ?u64 = null,
    owner_state: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};
const Case = struct {
    id: []const u8,
    scene: []const u8,
    story: std.json.Value,
    host: HostJson,
    owner: ?OwnerJson = null,
    frame: FrameJson,
    expect: ExpectJson,
};
const Cases = struct {
    schema: []const u8,
    id: []const u8,
    admission_content_sha256: []const u8,
    content_sha256: []const u8,
    cases: []const Case,
};
const Anchor = struct { address: u32, word: u32 };
const Admission = struct {
    schema: []const u8,
    id: []const u8,
    version: []const u8,
    anchors: []const Anchor,
    source: struct { image_sha256: []const u8, image_bytes: usize },
    content_sha256: []const u8,
};

// ---------------------------------------------------------------------------
// Predicate / story / owner helpers
// ---------------------------------------------------------------------------

const PredicateStorage = struct {
    records: [64]source.Record = undefined,
    terms: [64][8]source.Term = undefined,
    count: usize = 0,

    fn build(self: *PredicateStorage, packet: population.Packet) source.Predicates {
        for (packet.entities, 0..) |entity, index| {
            var count: usize = 0;
            for (entity.event_selection.terms) |term| {
                const kind: source.TermKind = if (term.kind == .unsupported) blk: {
                    const semantics = term.semantics.?;
                    if (std.mem.eql(u8, semantics, "event_predicate_0c")) break :blk .y_range;
                    if (std.mem.eql(u8, semantics, "event_predicate_04")) break :blk .up_input;
                    break :blk .x_range;
                } else .x_range;
                self.terms[index][count] = .{
                    .kind = kind,
                    .source_kind = if (term.kind == .unsupported) term.semantics.? else "event_predicate_0b",
                    .min_pixel = if (kind == .up_input) null else 0,
                    .max_pixel = if (kind == .up_input) null else 0,
                };
                count += 1;
            }
            self.records[index] = .{ .entity = @intCast(index), .terms = self.terms[index][0..count] };
        }
        self.count = packet.entities.len;
        return .{ .records = self.records[0..self.count], .position = .{ .x = 1000, .y = 1000 }, .up_held = false };
    }
};

fn buildStory(value: std.json.Value) !runtime.StoryState {
    var story: runtime.StoryState = .{};
    if (value != .object) return error.InvalidStoryValue;
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.key_ptr.*.len != 13 or !std.mem.startsWith(u8, entry.key_ptr.*, "scenario_")) return error.InvalidStoryValue;
        const index = try std.fmt.parseInt(u8, entry.key_ptr.*[9..], 10);
        story.scenario[index] = @intCast(entry.value_ptr.integer);
    }
    return story;
}

fn parseWait(value: ?[]const u8) !?runtime.Wait {
    const text = value orelse return null;
    const kind = std.meta.stringToEnum(@FieldType(runtime.Wait, "kind"), text) orelse return error.InvalidWait;
    return .{ .kind = kind, .id = text };
}

fn buildInstance(owner: OwnerJson, contents: []const runtime.Content, story: *runtime.StoryState) !runtime.Instance {
    const content = findContent(contents, owner.content_id, owner.content_sha256) orelse return error.MissingOwnerContent;
    try content.validate();
    if (content.program(owner.program_id) == null) return error.UnknownOwnerProgram;
    var instance: runtime.Instance = .{
        .content_id = owner.content_id,
        .content_sha256 = owner.content_sha256,
        .program_id = owner.program_id,
        .execution = .{
            .pc = owner.pc,
            .active = owner.active,
            .reloop = owner.reloop,
            .choice = 0,
            .wait = try parseWait(owner.wait),
        },
        .effect_sequence = owner.effect_sequence,
    };
    if (owner.pending) |pending| {
        if (pending.batch == 0 or pending.batch != owner.effect_sequence) return error.InvalidPendingBatch;
        instance.effect_sequence -= 1;
        const step = try runtime.step(content, &instance, story, .{});
        const batch = step.batch orelse return error.InvalidPendingBatch;
        if (batch.id != pending.batch or batch.effects[0].origin != pending.origin) return error.InvalidPendingBatch;
    }
    return instance;
}

fn callbackFrom(text: []const u8) !source.Callback {
    return std.meta.stringToEnum(source.Callback, text) orelse error.InvalidCallback;
}

fn frameFrom(value: FrameJson) !source.Frame {
    return .{
        .index = value.index,
        .installed_driver = value.installed_driver,
        .event_active = value.event_active,
        .init_done = value.init_done,
        .completion_flag = value.completion_flag,
        .menu_state = value.menu_state,
        .game = .{
            .flags_37 = value.game_state.flags_37,
            .encounter_enabled_159a = value.game_state.encounter_enabled_159a,
            .encounter_pending_36 = value.game_state.encounter_pending_36,
            .suppress_bd7a = value.game_state.suppress_bd7a,
            .encounter_threshold_30 = value.game_state.encounter_threshold_30,
            .encounter_timer_159c = value.game_state.encounter_timer_159c,
            .area_header = value.game_state.area_header,
            .area_header_word_38 = value.game_state.area_header_word_38,
            .free_reservation_hi = value.game_state.free_reservation_hi,
        },
        .vm = .{
            .upload_mode_16b8 = value.vm.upload_mode_16b8,
            .state_flags_c028 = value.vm.state_flags_c028,
            .slot_busy_dbb4 = value.vm.slot_busy_dbb4,
            .box1_busy_dbc8 = value.vm.box1_busy_dbc8,
        },
        .callbacks = .{
            .area_498 = try callbackFrom(value.callbacks.area_498),
            .area_49c = try callbackFrom(value.callbacks.area_49c),
        },
        .encounter_claim = value.encounter_claim,
        .interaction_entity = value.interaction_entity,
        .event_flags_low2 = @intCast(value.event_flags_low2 & 3),
    };
}

fn expectText(actual: ?[]const u8, expected: ?[]const u8) !void {
    if (expected) |value| {
        try std.testing.expect(actual != null);
        try std.testing.expectEqualStrings(value, actual.?);
    } else try std.testing.expect(actual == null);
}

fn expectOptional(comptime T: type, actual: ?T, expected: ?T) !void {
    if (expected) |value| {
        try std.testing.expect(actual != null);
        try std.testing.expectEqual(value, actual.?);
    } else try std.testing.expect(actual == null);
}

fn checkResult(result: hostmod.Result, expected: ExpectJson) !void {
    try std.testing.expectEqualStrings(expected.phase, @tagName(result.phase));
    try std.testing.expectEqual(expected.admitted, result.admitted);
    try std.testing.expectEqualStrings(expected.action, @tagName(result.action));
    try expectText(result.decisionKind(), expected.decision_kind);
    try expectOptional(u8, result.sourceOrder(), expected.source_order);
    try expectText(result.programId(), expected.program_id);
    try expectText(if (result.reason) |reason| @tagName(reason) else null, expected.reason);
    try std.testing.expectEqualStrings(expected.completion, result.completionTag());
    try expectOptional(u64, result.completionBatch(), expected.completion_batch);
    try std.testing.expectEqualStrings(expected.free_gate, @tagName(result.gate));
    try std.testing.expectEqualStrings(expected.vm_gate, @tagName(result.vm_gate));
    try expectText(if (result.vm_reason) |reason| @tagName(reason) else null, expected.vm_reason);
    try std.testing.expectEqual(expected.cursor, result.cursor);
    try std.testing.expectEqual(expected.construction_done, result.construction_done);
    try std.testing.expectEqual(expected.free_ready, result.free_ready);
    try expectOptional(u64, result.owner_serial, expected.owner_serial);
    try expectText(if (result.owner_state) |state| @tagName(state) else null, expected.owner_state);
}

fn runCase(packet: *const dispatch.Packet, pop: *const population.Packet, contents: []const runtime.Content, case: Case) !void {
    var story = try buildStory(case.story);
    var storage: PredicateStorage = .{};
    const predicates = storage.build(pop.*);
    const binding: hostmod.Binding = .{
        .packet = packet,
        .population = pop,
        .contents = contents,
        .scene_id = case.scene,
        .story = &story,
        .predicates = if (std.mem.eql(u8, case.frame.predicates, "exclude")) &predicates else null,
    };
    var host = try hostmod.Host.init(binding);
    host.cursor = case.host.cursor;
    host.construction_done = case.host.construction_done;
    host.last_frame = case.host.last_frame;
    host.construction_frame = case.host.construction_frame;
    host.completion_frame = case.host.completion_frame;
    if (case.host.owner) |owner| {
        const reference = try hostmod.Host.referenceFromSnapshot(binding, owner.content_id, owner.content_sha256, owner.program_id, .ordinary);
        host.owner = .{
            .serial = owner.serial,
            .reference = reference,
            .effect_sequence = owner.effect_sequence,
            .receipt_batch = owner.receipt_batch,
            .state = if (case.host.completed) .completed else if (owner.active) .active else .settled,
        };
    }
    if (case.host.pending_selection) |selection| {
        const reference = try hostmod.Host.referenceFromSnapshot(binding, selection.content_id, selection.content_sha256, selection.program_id, .ordinary);
        host.selection = .{ .reference = reference, .frame = selection.frame, .prior_serial = selection.prior_serial };
    }
    const frame = try frameFrom(case.frame);
    var owner_instance: runtime.Instance = undefined;
    if (case.owner) |owner| owner_instance = try buildInstance(owner, contents, &story);
    const view: ?hostmod.OwnerView = if (case.owner) |owner| .{
        .instance = &owner_instance,
        .serial = owner.serial,
        .receipt = if (owner.receipt_batch) |batch| hostmod.OwnerReceipt{ .batch = batch } else null,
    } else null;
    if (expectedError(case.expect.@"error")) |expected| {
        try std.testing.expectError(expected, host.observe(binding, frame, view));
        return;
    }
    const result = try host.observe(binding, frame, view);
    try checkResult(result, case.expect);
}

fn expectedError(name: ?[]const u8) ?anyerror {
    const text = name orelse return null;
    const errors = .{
        .StaleFrame = error.StaleFrame,
        .SelectionNotAdopted = error.SelectionNotAdopted,
        .OwnerRebindMismatch = error.OwnerRebindMismatch,
        .InvalidSnapshot = error.InvalidSnapshot,
    };
    inline for (@typeInfo(@TypeOf(errors)).@"struct".field_names) |field_name| {
        if (std.mem.eql(u8, text, field_name)) return @field(errors, field_name);
    }
    return null;
}

// ---------------------------------------------------------------------------
// Gate A: packet identity and the embedded evidence
// ---------------------------------------------------------------------------

test "embedded admission packet is the generated one" {
    const allocator = std.testing.allocator;
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    digest.update(data.event_admission_json);
    var actual: [32]u8 = undefined;
    digest.final(&actual);
    var hex: [64]u8 = undefined;
    const alphabet = "0123456789abcdef";
    for (actual, 0..) |byte, index| {
        hex[index * 2] = alphabet[byte >> 4];
        hex[index * 2 + 1] = alphabet[byte & 0x0f];
    }
    try std.testing.expectEqualStrings(data.event_admission_file_sha256, &hex);

    var case_digest = std.crypto.hash.sha2.Sha256.init(.{});
    case_digest.update(data.conformance_json);
    case_digest.final(&actual);
    for (actual, 0..) |byte, index| {
        hex[index * 2] = alphabet[byte >> 4];
        hex[index * 2 + 1] = alphabet[byte & 0x0f];
    }
    try std.testing.expectEqualStrings(data.conformance_file_sha256, &hex);

    const parsed = try std.json.parseFromSlice(Admission, allocator, data.event_admission_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const doc = parsed.value;
    try std.testing.expectEqualStrings("suikoden-event-admission/1", doc.schema);
    try std.testing.expectEqualStrings("travel_vb6_event_admission", doc.id);
    try std.testing.expectEqualStrings(admission_mod.version, doc.version);
    try std.testing.expectEqual(@as(usize, 84), doc.anchors.len);
    try std.testing.expectEqual(@as(u32, 0x8012CB24), doc.anchors[0].address);
    try std.testing.expectEqual(@as(u32, 0x8013F364), doc.anchors[doc.anchors.len - 1].address);
    try std.testing.expectEqual(@as(usize, 64), doc.source.image_sha256.len);
    try std.testing.expectEqual(@as(usize, 755712), doc.source.image_bytes);

    const cases = try std.json.parseFromSlice(Cases, allocator, data.conformance_json, .{ .ignore_unknown_fields = true });
    defer cases.deinit();
    try std.testing.expectEqualStrings("suikoden-event-admission-cases/1", cases.value.schema);
    try std.testing.expectEqual(@as(usize, 35), cases.value.cases.len);
    try std.testing.expectEqualStrings(doc.content_sha256, cases.value.admission_content_sha256);
    for (cases.value.cases) |case| {
        try std.testing.expect(case.id.len > 0);
        try std.testing.expect(case.expect.phase.len > 0);
    }
}

// ---------------------------------------------------------------------------
// Gate B: the hand-authored cases replay on the owned host
// ---------------------------------------------------------------------------

test "hand-authored admission and completion cases replay" {
    const allocator = std.testing.allocator;
    const packet = try loadDispatch(allocator);
    defer packet.deinit();
    const pop = try loadPopulation(allocator, "vb6_room6");
    defer pop.deinit();
    const contents = try loadContents(allocator, "vb6_room6");
    defer contents.deinit();
    const cases = try std.json.parseFromSlice(Cases, allocator, data.conformance_json, .{ .ignore_unknown_fields = true });
    defer cases.deinit();
    for (cases.value.cases) |case| {
        runCase(&packet.value, &pop.value, contents.slice(), case) catch |err| {
            std.debug.print("case {s} failed: {s}\n", .{ case.id, @errorName(err) });
            return err;
        };
    }
}

// ---------------------------------------------------------------------------
// Gate C: initializer blockers cannot be skipped
// ---------------------------------------------------------------------------

test "a selected blocked initializer stops the ordered pass" {
    const allocator = std.testing.allocator;
    const packet = try loadDispatch(allocator);
    defer packet.deinit();
    const pop = try loadPopulation(allocator, "vb6_room6");
    defer pop.deinit();
    const contents = try loadContents(allocator, "vb6_room6");
    defer contents.deinit();
    var story: runtime.StoryState = .{};
    story.scenario[15] = 0x40;
    var storage: PredicateStorage = .{};
    const predicates = storage.build(pop.value);
    const binding: hostmod.Binding = .{
        .packet = &packet.value,
        .population = &pop.value,
        .contents = contents.slice(),
        .scene_id = "vb6_room6",
        .story = &story,
        .predicates = &predicates,
    };
    var host = try hostmod.Host.init(binding);
    var frame: source.Frame = .{ .index = 1, .init_done = 0 };
    const first = try host.observe(binding, frame, null);
    try std.testing.expectEqualStrings("pump_initializer", @tagName(first.action));
    try std.testing.expectEqual(@as(?u8, 6), first.sourceOrder());
    try std.testing.expectEqual(@as(u8, 1), host.cursor);

    frame.index = 2;
    const blocked = try host.observe(binding, frame, null);
    try std.testing.expectEqualStrings("blocked", @tagName(blocked.action));
    try std.testing.expectEqual(@as(?u8, 8), blocked.sourceOrder());
    try std.testing.expectEqual(@as(u8, 1), host.cursor);
    try std.testing.expect(!host.construction_done);

    frame.index = 3;
    const again = try host.observe(binding, frame, null);
    try std.testing.expectEqual(@as(?u8, 8), again.sourceOrder());
    try std.testing.expectEqual(@as(u8, 1), host.cursor);

    // Even with the free driver installed, construction is not complete, so a
    // later initializer/free selection cannot be reached.
    frame.index = 4;
    frame.init_done = 1;
    frame.installed_driver = source.FREE_CALLER;
    const still = try host.observe(binding, frame, null);
    try std.testing.expectEqualStrings("construction_initialization", @tagName(still.phase));
    try std.testing.expectEqual(@as(?u8, 8), still.sourceOrder());
    try std.testing.expectEqual(@as(u8, 1), host.cursor);
}

// ---------------------------------------------------------------------------
// Gate D: completion gates E7 behind a separate pass; no E7 -> E9 chain
// ---------------------------------------------------------------------------

test "completion arms a later free pass; E7 stays blocked and never chains to E9" {
    const allocator = std.testing.allocator;
    const packet = try loadDispatch(allocator);
    defer packet.deinit();
    const pop = try loadPopulation(allocator, "vb6_room6");
    defer pop.deinit();
    const contents = try loadContents(allocator, "vb6_room6");
    defer contents.deinit();
    var story: runtime.StoryState = .{};
    story.scenario[15] = 0x28;
    var storage: PredicateStorage = .{};
    const predicates = storage.build(pop.value);
    const binding: hostmod.Binding = .{
        .packet = &packet.value,
        .population = &pop.value,
        .contents = contents.slice(),
        .scene_id = "vb6_room6",
        .story = &story,
        .predicates = &predicates,
    };
    const e5 = OwnerJson{
        .content_id = "vb6_room6_arrival",
        .content_sha256 = "9e6fd6c3d0a1b4b9e91762a68efe43dcfdfa6797f27e3e107c96969dcd7b75ad",
        .program_id = "vb6_r06_first_arrival",
        .serial = 1,
        .active = false,
        .pc = 28,
        .reloop = false,
        .effect_sequence = 19,
        .receipt_batch = 19,
    };
    var instance = try buildInstance(e5, contents.slice(), &story);
    const view: hostmod.OwnerView = .{ .instance = &instance, .serial = 1, .receipt = .{ .batch = 19 } };
    var host = try hostmod.Host.init(binding);
    host.cursor = 3;
    host.construction_done = true;
    host.construction_frame = 1;
    host.last_frame = 4;
    host.owner = .{
        .serial = 1,
        .reference = try hostmod.Host.referenceFromSnapshot(binding, e5.content_id, e5.content_sha256, e5.program_id, .ordinary),
        .effect_sequence = 19,
        .receipt_batch = 19,
        .state = .settled,
    };
    const completion = try host.observe(binding, .{
        .index = 5,
        .installed_driver = source.EVENT_CHILD,
        .init_done = 1,
        .event_active = 0,
        .completion_flag = 1,
    }, view);
    try std.testing.expectEqualStrings("proposed", completion.completionTag());
    try std.testing.expectEqualStrings("rearm_free_selection", @tagName(completion.action));
    try std.testing.expectEqual(@as(?u8, null), completion.sourceOrder());
    try std.testing.expectEqual(@as(u64, 5), host.completion_frame.?);
    try std.testing.expect(!host.freeReady(5));

    // Same pass: the selector never runs even though the E7 guard is true.
    const same = try host.observe(binding, .{
        .index = 5,
        .installed_driver = source.FREE_CALLER,
        .init_done = 1,
    }, null);
    try std.testing.expectEqualStrings("denied", @tagName(same.action));
    try std.testing.expectEqualStrings("completion_same_pass", @tagName(same.reason.?));
    try std.testing.expectEqual(@as(?u8, null), same.sourceOrder());

    // Later pass: E7 is eligible but remains a typed blocker; E9 is not tried.
    const e7 = try host.observe(binding, .{
        .index = 6,
        .installed_driver = source.FREE_CALLER,
        .init_done = 1,
    }, null);
    try std.testing.expectEqualStrings("blocked", @tagName(e7.action));
    try std.testing.expectEqual(@as(?u8, 7), e7.sourceOrder());
    try std.testing.expectEqualStrings("room_coordinate_transition", @tagName(e7.reason.?));
    try std.testing.expect(e7.decision.?.program == null);
    try std.testing.expect(e7.programId() == null);
}

test "E9 requires its own free pass and guard" {
    const allocator = std.testing.allocator;
    const packet = try loadDispatch(allocator);
    defer packet.deinit();
    const pop = try loadPopulation(allocator, "vb6_room6");
    defer pop.deinit();
    const contents = try loadContents(allocator, "vb6_room6");
    defer contents.deinit();
    var story: runtime.StoryState = .{};
    story.scenario[15] = 0x40;
    story.scenario[16] = 0x00;
    var storage: PredicateStorage = .{};
    const predicates = storage.build(pop.value);
    const binding: hostmod.Binding = .{
        .packet = &packet.value,
        .population = &pop.value,
        .contents = contents.slice(),
        .scene_id = "vb6_room6",
        .story = &story,
        .predicates = &predicates,
    };
    var host = try hostmod.Host.init(binding);
    host.cursor = 3;
    host.construction_done = true;
    host.construction_frame = 1;
    host.completion_frame = 5;
    host.last_frame = 6;
    const e9 = try host.observe(binding, .{
        .index = 7,
        .installed_driver = source.FREE_CALLER,
        .init_done = 1,
    }, null);
    try std.testing.expectEqualStrings("start_event_owner", @tagName(e9.action));
    try std.testing.expectEqual(@as(?u8, 9), e9.sourceOrder());
    try std.testing.expectEqualStrings("vb6_r06_entity09_followon", e9.programId().?);
}

// ---------------------------------------------------------------------------
// Gate E: restart rebinding and durable envelope rejection
// ---------------------------------------------------------------------------

test "fresh-process snapshot rebinds the same active owner" {
    const allocator = std.testing.allocator;
    const packet = try loadDispatch(allocator);
    defer packet.deinit();
    const pop = try loadPopulation(allocator, "vb6_room6");
    defer pop.deinit();
    const contents = try loadContents(allocator, "vb6_room6");
    defer contents.deinit();
    var story: runtime.StoryState = .{};
    var storage: PredicateStorage = .{};
    const predicates = storage.build(pop.value);
    const binding: hostmod.Binding = .{
        .packet = &packet.value,
        .population = &pop.value,
        .contents = contents.slice(),
        .scene_id = "vb6_room6",
        .story = &story,
        .predicates = &predicates,
    };
    const e5 = OwnerJson{
        .content_id = "vb6_room6_arrival",
        .content_sha256 = "9e6fd6c3d0a1b4b9e91762a68efe43dcfdfa6797f27e3e107c96969dcd7b75ad",
        .program_id = "vb6_r06_first_arrival",
        .serial = 1,
        .active = true,
        .pc = 3,
        .reloop = true,
    };
    var instance = try buildInstance(e5, contents.slice(), &story);
    const view: hostmod.OwnerView = .{ .instance = &instance, .serial = 1 };
    var host = try hostmod.Host.init(binding);
    host.cursor = 3;
    host.construction_done = true;
    host.construction_frame = 1;
    host.last_frame = 4;
    host.owner = .{
        .serial = 1,
        .reference = try hostmod.Host.referenceFromSnapshot(binding, e5.content_id, e5.content_sha256, e5.program_id, .ordinary),
        .effect_sequence = 0,
        .state = .active,
    };
    const first = try host.observe(binding, .{
        .index = 5,
        .installed_driver = source.EVENT_CHILD,
        .event_active = 1,
        .init_done = 1,
    }, view);
    try std.testing.expectEqualStrings("continue_event_frame", @tagName(first.action));
    const saved = try host.save(allocator);
    defer allocator.free(saved);

    var restored = try hostmod.Host.restore(allocator, saved, binding);
    try std.testing.expectEqual(@as(?u64, 1), restored.owner.?.serial);
    try std.testing.expectEqual(@as(?u64, 5), restored.last_frame);
    const continued = try restored.observe(binding, .{
        .index = 6,
        .installed_driver = source.EVENT_CHILD,
        .event_active = 1,
        .init_done = 1,
    }, view);
    try std.testing.expectEqualStrings("continue_event_frame", @tagName(continued.action));
    try std.testing.expectEqual(@as(?u64, 1), continued.owner_serial);
    try std.testing.expectEqualStrings("vb6_r06_first_arrival", continued.programId().?);

    // A different owner is refused rather than reselected.
    const e9 = try buildInstance(.{
        .content_id = "vb6_room6_entity09",
        .content_sha256 = "9a5063e83ecd9875c9f06118b7ec5d54df3cd110889059b0bf408d365d06d08a",
        .program_id = "vb6_r06_entity09_followon",
        .serial = 2,
        .active = true,
        .pc = 0,
        .reloop = true,
    }, contents.slice(), &story);
    const wrong: hostmod.OwnerView = .{ .instance = &e9, .serial = 2 };
    try std.testing.expectError(error.OwnerRebindMismatch, restored.observe(binding, .{
        .index = 7,
        .installed_driver = source.EVENT_CHILD,
        .event_active = 1,
        .init_done = 1,
    }, wrong));

    // A tampered construction cursor is refused at restore.
    const parsed = try std.json.parseFromSlice(hostmod.Host.Snapshot, allocator, saved, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    var tampered = parsed.value;
    tampered.cursor = 255;
    try std.testing.expectError(error.InvalidSnapshot, hostmod.Host.restoreSnapshot(tampered, binding));
}

// ---------------------------------------------------------------------------
// Gate F: the module owns no scheduler, callback invocation or ack
// ---------------------------------------------------------------------------

test "host exposes no acknowledgement or scheduler surface" {
    try std.testing.expect(!@hasDecl(hostmod.Host, "acknowledge"));
    try std.testing.expect(!@hasDecl(hostmod.Host, "tick"));
    try std.testing.expect(!@hasDecl(hostmod.Host, "run"));
    const allocator = std.testing.allocator;
    for ([_][]const u8{
        "game/src/travel/admission/host.zig",
        "game/src/travel/admission/source.zig",
        "game/src/travel/admission/root.zig",
    }) |path| {
        const bytes = try readFile(allocator, path);
        defer allocator.free(bytes);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "fn acknowledge") == null);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "runtime.acknowledge") == null);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "@import(\"field_events\")") == null);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "@import(\"world\")") == null);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "pub fn tick") == null);
    }
}

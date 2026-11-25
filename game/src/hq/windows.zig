//! Port packet: recruitment windows and source dialogue admission.
//!
//! The data is the static ledger in the embedded campaign asset; the
//! producer is the extraction pipeline.  A window is
//! an event-entity grant site with a same-room recruitment-byte predicate for
//! that exact character id.  Admission is a pure conjunction over caller
//! facts; the identity block (name, combat record, portrait index) is display
//! data and is never consulted by `evaluate` or `choose`.
//!
//! No original instruction executes here and no game window or media is used.

const std = @import("std");

pub const schema = "suikoden-recruitment-windows/1";
pub const grant_op_code: u8 = 0x45;
pub const grant_op_id = "roster.recruit_present";
pub const grant_arm = "non_escape";
pub const recruit_flag_count: usize = 108;
pub const max_terms: usize = 16;

pub const Kind = enum {
    interaction,
    story,
    recruit,
    tier,
    party,
    party_count,
    money,
    level,
    eligible,
    item,
    item_equipped,
    hero_bounds,
    input,
    mode_word,
    random,
};

pub const Requirement = enum { set, clear, present, absent, either, contains, lacks };
pub const Axis = enum { x, y };
pub const SecondKind = enum { decline, service, trade, unproved, unlabelled };
pub const ItemKind = enum { in_party, equipped };

pub const Term = struct {
    kind: Kind,
    at: u32 = 0,
    byte: ?u16 = null,
    mask: ?u32 = null,
    required: ?std.json.Value = null,
    cid: ?u8 = null,
    mode_byte: ?u8 = null,
    threshold: ?u16 = null,
    count: ?u8 = null,
    units: ?u32 = null,
    item: ?u16 = null,
    descriptor_flags: ?u16 = null,
    axis: ?Axis = null,
    strict: ?bool = null,
    lower: ?u8 = null,
    upper: ?u8 = null,
    index: ?u8 = null,
    bucket: ?u8 = null,
    mask_word: ?u32 = null,
};

pub const Predicate = struct {
    terms: []const Term = &.{},
    predicate_bytes: ?[]const u8 = null,
    max_terms: u16 = 0,
};

pub const Presence = struct {
    terms: []const Term = &.{},
    predicate_bytes: ?[]const u8 = null,
    caller_owned: bool = true,
};

pub const VariantTerm = struct {
    opcode: u8,
    operands: []const u8,
};

pub const Variant = struct {
    entity: u8,
    domain: []const u8,
    terms: []const VariantTerm = &.{},
};

pub const Choice = struct {
    @"switch": u32 = 0,
    accept: u32 = 0,
    second: u32 = 0,
    second_end: u32 = 0,
    prompt_lines: []const []const u8 = &.{},
    accept_label: ?[]const u8 = null,
    second_label: ?[]const u8 = null,
    second_kind: SecondKind = .unlabelled,
    verified: bool = false,
    decline_route: bool = false,
    accept_first: ?[]const u8 = null,
    second_first: ?[]const u8 = null,
};

pub const Item = struct {
    item: u16,
    name: ?[]const u8 = null,
    at: u32 = 0,
    kind: ItemKind,
    descriptor_flags: ?u16 = null,
};

pub const Money = struct { units: u32, required: u32, at: u32 = 0 };
pub const AreaRequest = struct { at: u32, operand: u8, area_index: u16 };
pub const UiState = struct { at: u32, selector: u8 };
pub const Transition = struct { at: u32, selector: u8, index: u8, branch: ?[]const u8 = null };
pub const OtherOp = struct { at: u32, opcode: u8, operands: []const u8 = &.{} };

pub const Links = struct {
    items: []const Item = &.{},
    money: ?Money = null,
    area_requests: []const AreaRequest = &.{},
    ui_states: []const UiState = &.{},
    service_transitions: []const Transition = &.{},
    other_ops: []const OtherOp = &.{},
    entry_terms: u16 = 0,
};

pub const Area = struct {
    source_file: []const u8,
    room_record: u32,
    room_entity: u8,
    entity_id: u8,
    event_predicate: u32 = 0,
    event_stream: u32 = 0,
    streams_reaching_grant: []const u32 = &.{},
};

pub const Operation = struct {
    op_id: []const u8,
    op_code: u8,
    arm: []const u8,
    operands: []const u8 = &.{},
    at: u32 = 0,
    bytes: []const u8,
    recount: []const u8 = "host_owned",
};

pub const Window = struct {
    id: []const u8,
    cid: u8,
    identity: ?[]const u8 = null,
    combat_record: bool = false,
    area: Area,
    entry: Predicate,
    presence: Presence = .{},
    presence_variants: []const Variant = &.{},
    choice: ?Choice = null,
    links: Links = .{},
    operation: Operation,
};

pub const Identity = struct {
    cid: u8,
    name: ?[]const u8 = null,
    combat_record: bool = false,
    record_row: ?u16 = null,
    portrait_index: ?u16 = null,
    has_window: bool = false,
};

pub const IdentityBlock = struct {
    recruit_flag_count: u16,
    record_count: u16 = 0,
    hero_id: u8 = 0,
    empty_id: u8 = 0,
    recruit_flag_base: []const u8 = "",
    recruit_flag_index_is_record_id: bool,
    identities: []const Identity,
};

pub const Coverage = struct {
    windows: u16,
    area_files_with_windows: u16 = 0,
    identities_with_window: u16,
    identities_without_window: u16,
    combatants_with_window: u16 = 0,
    noncombatants_with_window: u16 = 0,
    choice_windows: u16 = 0,
    verified_choices: u16 = 0,
    verified_decline_routes: u16 = 0,
    entry_terms: u16 = 0,
    proved_ids: []const u8 = &.{},
    missing_ids: []const u8 = &.{},
    noncombatant_flag_ids: []const u8 = &.{},
    record_ids_without_recruit_flag: []const u8 = &.{},
};

pub const Asset = struct {
    schema: []const u8,
    target: []const u8 = "",
    base_snapshot: []const u8 = "",
    content_sha256: []const u8,
    identity: IdentityBlock,
    coverage: Coverage,
    windows: []const Window,
};

pub const ValidateError = error{
    InvalidSchema,
    InvalidDigest,
    InvalidIdentityCount,
    InvalidIdentityOrder,
    InvalidIdentityField,
    InvalidCid,
    DuplicateWindow,
    InvalidOperation,
    InvalidOperationBytes,
    InvalidIdentityLink,
    InvalidTerm,
    InvalidVariant,
    InvalidChoice,
    CoverageMismatch,
};

pub const Loaded = struct {
    parsed: std.json.Parsed(Asset),

    pub fn deinit(self: Loaded) void {
        self.parsed.deinit();
    }

    pub fn asset(self: *const Loaded) *const Asset {
        return &self.parsed.value;
    }
};

/// Parse and validate the static ledger.  Validation is deliberately before
/// any caller state exists: a corrupt or re-labelled asset cannot be used.
pub fn open(allocator: std.mem.Allocator, source: []const u8) !Loaded {
    const parsed = try std.json.parseFromSlice(Asset, allocator, source, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    errdefer parsed.deinit();
    var loaded = Loaded{ .parsed = parsed };
    try validate(loaded.asset());
    return loaded;
}

fn requiredString(term: Term) ![]const u8 {
    const value = term.required orelse return error.InvalidTerm;
    return switch (value) {
        .string => |text| text,
        else => error.InvalidTerm,
    };
}

fn requiredInteger(term: Term) !u32 {
    const value = term.required orelse return error.InvalidTerm;
    return switch (value) {
        .integer => |number| std.math.cast(u32, number) orelse error.InvalidTerm,
        else => error.InvalidTerm,
    };
}

fn termValid(term: Term) bool {
    switch (term.kind) {
        .interaction => return true,
        .story => {
            if (term.byte == null or term.mask == null) return false;
            const req = std.meta.stringToEnum(Requirement, requiredString(term) catch
                return false) orelse return false;
            return req == .set or req == .clear;
        },
        .recruit => {
            if (term.cid == null) return false;
            const req = std.meta.stringToEnum(Requirement, requiredString(term) catch
                return false) orelse return false;
            return req == .present or req == .absent or req == .either;
        },
        .tier => return term.threshold != null,
        .party => {
            if (term.cid == null) return false;
            const req = std.meta.stringToEnum(Requirement, requiredString(term) catch
                return false) orelse return false;
            return req == .contains or req == .lacks;
        },
        .party_count => return term.count != null,
        .money => return term.units != null,
        .level => return term.cid != null and term.threshold != null,
        .eligible => return term.threshold != null,
        .item => return term.item != null,
        .item_equipped => return term.item != null and term.descriptor_flags != null,
        .hero_bounds => return term.axis != null and term.strict != null and
            term.lower != null and term.upper != null,
        .input => return true,
        .mode_word => return term.mask != null,
        .random => return term.bucket != null,
    }
}

fn validateTerm(term: Term) ValidateError!void {
    if (!termValid(term)) return error.InvalidTerm;
    if (term.kind == .money) {
        const amount = requiredInteger(term) catch return error.InvalidTerm;
        if (term.units.? * 100 != amount) return error.InvalidTerm;
    }
}

pub fn validate(asset: *const Asset) ValidateError!void {
    if (!std.mem.eql(u8, asset.schema, schema)) return error.InvalidSchema;
    if (asset.content_sha256.len != 64) return error.InvalidDigest;
    if (asset.identity.recruit_flag_count != recruit_flag_count) return error.InvalidIdentityCount;
    if (asset.identity.identities.len != recruit_flag_count) return error.InvalidIdentityCount;
    if (!asset.identity.recruit_flag_index_is_record_id) return error.InvalidIdentityField;

    var seen_identity = std.mem.zeroes([recruit_flag_count]bool);
    for (asset.identity.identities, 0..) |row, index| {
        if (row.cid != index) return error.InvalidIdentityOrder;
        if (row.cid >= recruit_flag_count) return error.InvalidCid;
        if (seen_identity[row.cid]) return error.InvalidIdentityOrder;
        seen_identity[row.cid] = true;
        if (row.combat_record and row.record_row == null) return error.InvalidIdentityField;
        if (!row.combat_record and row.name != null) return error.InvalidIdentityField;
    }

    var proved = std.mem.zeroes([recruit_flag_count]bool);
    var area_count: usize = 0;
    var choice_count: usize = 0;
    var verified_count: usize = 0;
    var decline_count: usize = 0;
    var entry_terms: usize = 0;
    for (asset.windows, 0..) |window, window_index| {
        if (window.cid >= recruit_flag_count) return error.InvalidCid;
        for (asset.windows[0..window_index]) |earlier| {
            if (std.mem.eql(u8, earlier.id, window.id)) return error.DuplicateWindow;
        }
        proved[window.cid] = true;
        if (!std.mem.eql(u8, window.operation.op_id, grant_op_id)) return error.InvalidOperation;
        if (window.operation.op_code != grant_op_code) return error.InvalidOperation;
        if (!std.mem.eql(u8, window.operation.arm, grant_arm)) return error.InvalidOperation;
        if (window.operation.operands.len != 1 or window.operation.operands[0] != window.cid)
            return error.InvalidOperation;
        var expected_bytes: [5]u8 = undefined;
        const text = std.fmt.bufPrint(&expected_bytes, "45 {x:0>2}", .{window.cid}) catch
            return error.InvalidOperationBytes;
        if (!std.mem.eql(u8, window.operation.bytes, text)) return error.InvalidOperationBytes;
        const identity_row = asset.identity.identities[window.cid];
        if (window.identity) |name| {
            if (identity_row.name) |expected| {
                if (!std.mem.eql(u8, name, expected)) return error.InvalidIdentityLink;
            } else return error.InvalidIdentityLink;
        } else if (identity_row.name != null) {
            return error.InvalidIdentityLink;
        }
        if (window.combat_record != identity_row.combat_record)
            return error.InvalidIdentityLink;
        if (window.entry.terms.len > max_terms) return error.InvalidTerm;
        entry_terms += window.entry.terms.len;
        for (window.entry.terms) |term| try validateTerm(term);
        for (window.presence.terms) |term| try validateTerm(term);
        for (window.presence_variants) |variant| {
            for (variant.terms) |term| {
                if (term.operands.len != 1 or term.operands[0] != window.cid)
                    return error.InvalidVariant;
                if (term.opcode != 0x10 and term.opcode != 0x11 and term.opcode != 0x19)
                    return error.InvalidVariant;
            }
        }
        if (window.choice) |choice| {
            choice_count += 1;
            if (choice.verified) verified_count += 1;
            if (choice.decline_route) {
                decline_count += 1;
                if (!choice.verified or choice.second_kind != .decline)
                    return error.InvalidChoice;
            }
            if (choice.verified and choice.prompt_lines.len != 2) return error.InvalidChoice;
        }
    }
    for (asset.windows, 0..) |window, window_index| {
        var first = true;
        for (asset.windows[0..window_index]) |earlier| {
            if (std.mem.eql(u8, earlier.area.source_file, window.area.source_file)) {
                first = false;
                break;
            }
        }
        if (first) area_count += 1;
    }
    if (@as(usize, asset.coverage.windows) != asset.windows.len) return error.CoverageMismatch;
    if (@as(usize, asset.coverage.area_files_with_windows) != area_count) return error.CoverageMismatch;
    if (@as(usize, asset.coverage.identities_with_window) != countTrue(&proved))
        return error.CoverageMismatch;
    if (@as(usize, asset.coverage.identities_without_window) !=
        recruit_flag_count - countTrue(&proved)) return error.CoverageMismatch;
    if (@as(usize, asset.coverage.choice_windows) != choice_count) return error.CoverageMismatch;
    if (@as(usize, asset.coverage.verified_choices) != verified_count) return error.CoverageMismatch;
    if (@as(usize, asset.coverage.verified_decline_routes) != decline_count)
        return error.CoverageMismatch;
    if (@as(usize, asset.coverage.entry_terms) != entry_terms) return error.CoverageMismatch;
    for (asset.identity.identities) |row| {
        if (row.has_window != proved[row.cid]) return error.CoverageMismatch;
    }
}

fn countTrue(bits: *const [recruit_flag_count]bool) usize {
    var total: usize = 0;
    for (bits) |bit| {
        if (bit) total += 1;
    }
    return total;
}

pub const Facts = struct {
    entity_available: bool = true,
    interaction: bool = false,
    story: []const u8 = &.{},
    scenario: ?[]const u8 = null,
    recruit: []const u8 = &.{},
    party: []const u8 = &.{},
    money: i64 = 0,
    items: []const u16 = &.{},
    equipped: []const u16 = &.{},
    levels: []const u8 = &.{},
    tier: u8 = 0,
    eligible: u16 = 0,
    party_count: u8 = 0,
    hero_x: u8 = 0,
    hero_y: u8 = 0,
    input_mask: u16 = 0,
    mode_word: u32 = 0,
    random: u16 = 0,
};

pub const Route = enum {
    admitted,
    absent,
    no_window,
    already_recruited,
    declined,
    invalid_choice,
    second_route,
    window_not_open,
    missed_window,
    missing_item,
    insufficient_money,
    party_conflict,
    level_too_low,
    recruit_count_too_low,
    out_of_range,
    unsupported,
    invalid_state,
};

pub const BlockCode = enum {
    entity_unloaded,
    no_window,
    already_recruited,
    declined,
    second_arm_unproved,
    invalid_choice,
    interaction_required,
    story_not_set,
    story_closed,
    recruit_gate,
    tier_below,
    party_mismatch,
    party_count_mismatch,
    money_below,
    level_below,
    eligible_below,
    item_missing,
    equipped_item_missing,
    hero_out_of_bounds,
    input_mismatch,
    mode_mismatch,
    random_bucket,
    missing_recruit_bitmap,
    missing_story,
    missing_level,
    corrupt_ledger,
};

pub const Blocker = struct {
    code: BlockCode,
    term_at: ?u32 = null,
    detail: []const u8 = "",
};

pub const Plan = struct {
    window_id: []const u8,
    cid: u8,
    op_id: []const u8 = grant_op_id,
    op_code: u8 = grant_op_code,
    arm: []const u8 = grant_arm,
};

pub const Outcome = struct {
    route: Route,
    plan: ?Plan = null,
    blocker: ?Blocker = null,
};

fn blocked(route: Route, code: BlockCode, term_at: ?u32, detail: []const u8) Outcome {
    return .{ .route = route, .plan = null, .blocker = .{
        .code = code,
        .term_at = term_at,
        .detail = detail,
    } };
}

fn admitted(window: *const Window) Outcome {
    return .{ .route = .admitted, .plan = .{
        .window_id = window.id,
        .cid = window.cid,
    } };
}

fn recruitByte(facts: Facts, cid: u8) ?u8 {
    if (cid >= facts.recruit.len) return null;
    return facts.recruit[cid];
}

fn present(facts: Facts, cid: u8) ?bool {
    const byte = recruitByte(facts, cid) orelse return null;
    return (byte & 1) != 0 and (byte & 2) == 0;
}

fn absent(facts: Facts, cid: u8) ?bool {
    const byte = recruitByte(facts, cid) orelse return null;
    return (byte & 3) == 0;
}

fn either(facts: Facts, cid: u8) ?bool {
    const byte = recruitByte(facts, cid) orelse return null;
    return (byte & 3) != 0;
}

const scenario_wire_base: u16 = 0x190;

fn storyHolds(facts: Facts, byte: u16, mask: u32, set: bool) ?bool {
    const value: u8 = if (facts.scenario) |scenario| blk: {
        if (byte < scenario_wire_base) return null;
        const index = byte - scenario_wire_base;
        if (index >= scenario.len) return null;
        break :blk scenario[index];
    } else blk: {
        if (byte >= facts.story.len) return null;
        break :blk facts.story[byte];
    };
    const hit = (@as(u32, value) & mask) != 0;
    return if (set) hit else !hit;
}

fn partyHas(facts: Facts, cid: u8) ?bool {
    if (cid >= facts.party.len) return null;
    return facts.party[cid] != 0;
}

fn hasItem(list: []const u16, item: u16) bool {
    for (list) |entry| {
        if (entry == item) return true;
    }
    return false;
}

fn termOutcome(term: Term, facts: Facts) ?Outcome {
    switch (term.kind) {
        .interaction => {
            if (!facts.interaction) {
                return blocked(.window_not_open, .interaction_required, term.at, "interaction");
            }
        },
        .story => {
            const req = std.meta.stringToEnum(Requirement, requiredString(term) catch
                return blocked(.invalid_state, .corrupt_ledger, term.at, "story requirement")) orelse
                return blocked(.invalid_state, .corrupt_ledger, term.at, "story requirement");
            const holds = storyHolds(facts, term.byte orelse
                return blocked(.invalid_state, .corrupt_ledger, term.at, "story byte"), term.mask orelse
                return blocked(.invalid_state, .corrupt_ledger, term.at, "story mask"), req == .set) orelse
                return blocked(.invalid_state, .missing_story, term.at, "story snapshot");
            if (!holds) {
                if (req == .clear) {
                    return blocked(.missed_window, .story_closed, term.at, "required-clear story byte is set");
                }
                return blocked(.window_not_open, .story_not_set, term.at, "required-set story byte is clear");
            }
        },
        .recruit => {
            const req = std.meta.stringToEnum(Requirement, requiredString(term) catch
                return blocked(.invalid_state, .corrupt_ledger, term.at, "recruit requirement")) orelse
                return blocked(.invalid_state, .corrupt_ledger, term.at, "recruit requirement");
            const cid = term.cid orelse
                return blocked(.invalid_state, .corrupt_ledger, term.at, "recruit cid");
            const ok = switch (req) {
                .present => present(facts, cid) orelse
                    return blocked(.invalid_state, .missing_recruit_bitmap, term.at, "recruit bitmap"),
                .absent => absent(facts, cid) orelse
                    return blocked(.invalid_state, .missing_recruit_bitmap, term.at, "recruit bitmap"),
                .either => either(facts, cid) orelse
                    return blocked(.invalid_state, .missing_recruit_bitmap, term.at, "recruit bitmap"),
                else => false,
            };
            if (!ok) {
                if (req == .absent and ((recruitByte(facts, cid) orelse 0) & 1) != 0) {
                    return blocked(.already_recruited, .already_recruited, term.at, "recruit bit set");
                }
                return blocked(.window_not_open, .recruit_gate, term.at, "recruit gate");
            }
        },
        .tier => {
            if (facts.tier < (term.threshold orelse 0)) {
                return blocked(.window_not_open, .tier_below, term.at, "tier below threshold");
            }
        },
        .party => {
            const req = std.meta.stringToEnum(Requirement, requiredString(term) catch
                return blocked(.invalid_state, .corrupt_ledger, term.at, "party requirement")) orelse
                return blocked(.invalid_state, .corrupt_ledger, term.at, "party requirement");
            const cid = term.cid orelse
                return blocked(.invalid_state, .corrupt_ledger, term.at, "party cid");
            const contains = partyHas(facts, cid) orelse
                return blocked(.invalid_state, .corrupt_ledger, term.at, "party bitmap");
            if ((req == .contains) != contains) {
                return blocked(.party_conflict, .party_mismatch, term.at, "party membership");
            }
        },
        .party_count => {
            if (facts.party_count != (term.count orelse 0)) {
                return blocked(.party_conflict, .party_count_mismatch, term.at, "party count");
            }
        },
        .money => {
            if (facts.money < @as(i64, term.units orelse 0) * 100) {
                return blocked(.insufficient_money, .money_below, term.at, "money below gate");
            }
        },
        .level => {
            const cid = term.cid orelse
                return blocked(.invalid_state, .corrupt_ledger, term.at, "level cid");
            if (cid >= facts.levels.len) {
                return blocked(.invalid_state, .missing_level, term.at, "level record");
            }
            if (facts.levels[cid] < (term.threshold orelse 0)) {
                return blocked(.level_too_low, .level_below, term.at, "record level below threshold");
            }
        },
        .eligible => {
            if (facts.eligible < (term.threshold orelse 0)) {
                return blocked(.recruit_count_too_low, .eligible_below, term.at, "eligible recruits below threshold");
            }
        },
        .item => {
            if (!hasItem(facts.items, term.item orelse 0)) {
                return blocked(.missing_item, .item_missing, term.at, "party item missing");
            }
        },
        .item_equipped => {
            if (!hasItem(facts.equipped, term.item orelse 0)) {
                return blocked(.missing_item, .equipped_item_missing, term.at, "equipped item missing");
            }
            if (((term.descriptor_flags orelse 0) & 0x80) == 0) {
                return blocked(.unsupported, .corrupt_ledger, term.at, "equipped descriptor has no 0x80 bit");
            }
        },
        .hero_bounds => {
            const axis = term.axis orelse .x;
            const value = if (axis == .x) facts.hero_x else facts.hero_y;
            const lower = term.lower orelse 0;
            const upper = term.upper orelse 0;
            const strict = term.strict orelse false;
            const inside = if (strict) value > lower and value < upper else value >= lower and value <= upper;
            if (!inside) {
                return blocked(.out_of_range, .hero_out_of_bounds, term.at, "hero coordinate outside bounds");
            }
        },
        .input => {
            if ((facts.input_mask & 0x41) == 0) {
                return blocked(.window_not_open, .input_mismatch, term.at, "pressed-edge 0x41 absent");
            }
        },
        .mode_word => {
            if ((facts.mode_word & (term.mask orelse 0)) == 0) {
                return blocked(.window_not_open, .mode_mismatch, term.at, "mode word does not intersect");
            }
        },
        .random => {
            const bucket = term.bucket orelse 0;
            const divisor: u32 = 32767 / (@as(u32, bucket) + 1);
            if (divisor != 0 and @as(u32, facts.random) / divisor != 0) {
                return blocked(.window_not_open, .random_bucket, term.at, "random quotient is nonzero");
            }
        },
    }
    return null;
}

/// Evaluate the whole entry conjunction.  The identity block is not an input.
pub fn evaluate(window: *const Window, facts: Facts) Outcome {
    if (!facts.entity_available) {
        return blocked(.absent, .entity_unloaded, null, "caller reports the source entity unloaded");
    }
    const byte = recruitByte(facts, window.cid) orelse
        return blocked(.invalid_state, .missing_recruit_bitmap, null, "recruit bitmap too short");
    if ((byte & 1) != 0) {
        return blocked(.already_recruited, .already_recruited, null, "recruit bit already set");
    }
    for (window.entry.terms) |term| {
        if (termOutcome(term, facts)) |outcome| return outcome;
    }
    return admitted(window);
}

/// Select a source menu arm after the interaction: 0 accepts, 1 takes the
/// second arm.  A second arm is declined only when the producer verified a
/// refusal label; any other second arm is a typed unproved route.
pub fn choose(window: *const Window, option: u8, facts: Facts) Outcome {
    var active = facts;
    active.interaction = true;
    const pre = evaluate(window, active);
    if (pre.route != .admitted) return pre;
    if (window.choice == null) {
        return blocked(.invalid_choice, .invalid_choice, null, "window has no source menu");
    }
    const choice = window.choice.?;
    return switch (option) {
        0 => pre,
        1 => if (choice.verified and choice.decline_route)
            blocked(.declined, .declined, null, "verified refusal arm")
        else
            blocked(.second_route, .second_arm_unproved, null, "second arm is not a proved decline"),
        else => blocked(.invalid_choice, .invalid_choice, null, "option outside the two source arms"),
    };
}

pub fn identity(asset: *const Asset, cid: u8) ?Identity {
    if (cid >= asset.identity.identities.len) return null;
    const value = asset.identity.identities[cid];
    if (value.cid != cid) return null;
    return value;
}

pub fn windowById(asset: *const Asset, id: []const u8) ?*const Window {
    for (asset.windows) |*window| {
        if (std.mem.eql(u8, window.id, id)) return window;
    }
    return null;
}

pub fn windowByCid(asset: *const Asset, cid: u8) ?*const Window {
    for (asset.windows) |*window| {
        if (window.cid == cid) return window;
    }
    return null;
}

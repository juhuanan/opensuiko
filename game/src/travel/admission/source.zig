//! Source facts: caller phase, free/VM locks and predicate resolution.
//!
//! Every field below names a MAIN.EXE location this package asserts statically.
//! The host consumes the raw field values; it does not accept a caller-supplied
//! `free_gate`/`vm_gate`/phase. See `event_admission.json` for the instruction
//! anchors and the packet-level rules.
//!
//!   0x8018DA90 + index*4   installed frame driver (source frame table)
//!   0x80171C28             active event stream
//!   0x80171C29             initializer pump completed
//!   0x8017DC4C             post-frame completion word
//!   0x8018BD74 high half   free-caller reservation
//!   0x8018BE20 + 0x37      game-state reservation bits (0x04 encounter / 0x08 mode)
//!   0x8017159A/0x8017159C  encounter enable/timer
//!   0x8017159D             encounter rate threshold
//!   0x8018BD7A             encounter suppression
//!   0x8018BE20 + 0x36      encounter pending
//!   0x8018BE20 + 0x30      area coordinate threshold
//!   0x8018AAE4 -> +0x38    area header word used by the encounter gate
//!   0x801716B8             VM upload mode gate
//!   0x8018C028             VM/text mode flags
//!   0x8018DBB4/0x8018DBC8  box slot/box one busy bytes
//!   0x8018BE20 + 0x498     area callback (post-frame)
//!   0x8018BE20 + 0x49C     area callback (pre-completion)
//!   0x8018BE20 + 0x4E0     menu/transition state byte

const std = @import("std");

pub const schema = "suikoden-event-source-facts/1";

pub const FREE_CALLER: u32 = 0x80132938;
pub const EVENT_CHILD: u32 = 0x80132B6C;
pub const TRANSITION_DRIVER: u32 = 0x80132898;
pub const MENU_DRIVER: u32 = 0x80132BD8;
pub const CONSTRUCTION_CALLER: u32 = 0x801318C4;
pub const INIT_PUMP: u32 = 0x8013F2A4;
pub const ORDINARY_SELECTOR: u32 = 0x8013F1BC;
pub const EVENT_FRAME: u32 = 0x8013F110;
pub const VM_GATE: u32 = 0x8013F0C0;
pub const VM_TICK: u32 = 0x8013E028;
pub const PREDICATE: u32 = 0x8013DB6C;
pub const EVENT_INSTALL: u32 = 0x8013E17C;
pub const ENCOUNTER_GATE: u32 = 0x8012CC38;
pub const ALTERNATE_MODE: u32 = 0x8012CB10;
pub const COMPLETION_WORD: u32 = 0x8017DC4C;
pub const ACTIVE_WORD: u32 = 0x80171C28;
pub const INIT_DONE_WORD: u32 = 0x80171C29;

pub const Driver = enum { none, construction, free_selection, event_child, transition, menu };

pub fn driverOf(address: u32) Driver {
    return switch (address) {
        CONSTRUCTION_CALLER => .construction,
        FREE_CALLER => .free_selection,
        EVENT_CHILD => .event_child,
        TRANSITION_DRIVER => .transition,
        MENU_DRIVER => .menu,
        else => .none,
    };
}

pub const Phase = enum { construction_initialization, free_selection, event_frame, menu, transition, unsupported };

pub const PhaseBasis = enum {
    installed_event_child,
    active_without_event_child,
    installed_free,
    init_incomplete,
    menu_state,
    transition_driver,
    construction_caller,
    unknown_driver,
};

pub const PhaseFact = struct { phase: Phase, basis: PhaseBasis };

pub const FreeGate = enum { clear, blocked, unproven };
pub const FreeReason = enum {
    menu,
    free_reservation,
    encounter_reservation,
    alternate_mode,
    encounter_claim,
    unproven_encounter_gate,
};
pub const VmGate = enum { clear, blocked };
pub const VmReason = enum { upload_mode, box_slot, box_one, vm_flags };
pub const Callback = enum { none, pending, unknown };
pub const CallbackFields = struct {
    area_498: Callback = .none,
    area_49c: Callback = .none,
};

pub const GameFields = struct {
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

pub const VmFields = struct {
    upload_mode_16b8: u8 = 0,
    state_flags_c028: u16 = 0,
    slot_busy_dbb4: u8 = 0,
    box1_busy_dbc8: u8 = 0,
};

/// One observed source frame. The values are raw engine state, not admission
/// opinions: `installed_driver` is the actual 0x8018DA90 slot word and the
/// gates below are the fields 0x80132938/0x8012CC38/0x8012CB10/0x8013F0C0 read.
pub const Frame = struct {
    index: u64 = 0,
    installed_driver: u32 = 0,
    event_active: u8 = 0,
    init_done: u8 = 0,
    completion_flag: u8 = 0,
    menu_state: u8 = 0,
    game: GameFields = .{},
    vm: VmFields = .{},
    callbacks: CallbackFields = .{},
    /// The world encounter owner's claim for the 0x8012CC38 picker branch.
    /// null means the branch was not reached or the owner has not spoken; it is
    /// never defaulted to false.
    encounter_claim: ?bool = null,
    interaction_entity: ?u8 = null,
    event_flags_low2: u2 = 0,
};

pub fn phase(frame: Frame, construction_done: bool) PhaseFact {
    if (frame.menu_state != 0) return .{ .phase = .menu, .basis = .menu_state };
    const driver = driverOf(frame.installed_driver);
    if (driver == .event_child) return .{ .phase = .event_frame, .basis = .installed_event_child };
    if (frame.event_active != 0) return .{ .phase = .unsupported, .basis = .active_without_event_child };
    if (driver == .transition) return .{ .phase = .transition, .basis = .transition_driver };
    if (frame.init_done == 0 or !construction_done) return .{ .phase = .construction_initialization, .basis = .init_incomplete };
    if (driver == .free_selection) return .{ .phase = .free_selection, .basis = .installed_free };
    if (driver == .construction) return .{ .phase = .construction_initialization, .basis = .construction_caller };
    return .{ .phase = .unsupported, .basis = .unknown_driver };
}

pub const FreeFact = struct { gate: FreeGate, reason: ?FreeReason };

/// 0x80132938: 0x8018BD74 high half, then 0x8012CC38 and 0x8012CB10.
pub fn freeGate(frame: Frame) FreeFact {
    const game = frame.game;
    if (game.free_reservation_hi != 0) return .{ .gate = .blocked, .reason = .free_reservation };
    if (game.flags_37 & 0x04 != 0) return .{ .gate = .blocked, .reason = .encounter_reservation };
    if (game.flags_37 & 0x08 != 0) return .{ .gate = .blocked, .reason = .alternate_mode };
    const deterministically_clear =
        game.encounter_enabled_159a == 0 or
        game.encounter_pending_36 == 0 or
        game.suppress_bd7a != 0 or
        game.encounter_timer_159c >= game.encounter_threshold_30 or
        !game.area_header or
        !game.area_header_word_38;
    if (deterministically_clear) return .{ .gate = .clear, .reason = null };
    const claim = frame.encounter_claim orelse
        return .{ .gate = .unproven, .reason = .unproven_encounter_gate };
    if (claim) return .{ .gate = .blocked, .reason = .encounter_claim };
    return .{ .gate = .clear, .reason = null };
}

pub const VmFact = struct { gate: VmGate, reason: ?VmReason };

/// 0x8013F0C0 -> 0x8013F060.
pub fn vmGate(frame: Frame) VmFact {
    const vm = frame.vm;
    if (vm.upload_mode_16b8 != 0) return .{ .gate = .blocked, .reason = .upload_mode };
    if (vm.state_flags_c028 & 0x0001 != 0 and vm.slot_busy_dbb4 == 1)
        return .{ .gate = .blocked, .reason = .box_slot };
    if (vm.state_flags_c028 & 0x0002 != 0 and vm.box1_busy_dbc8 == 1)
        return .{ .gate = .blocked, .reason = .box_one };
    if (vm.state_flags_c028 & 0xFFFC != 0) return .{ .gate = .blocked, .reason = .vm_flags };
    return .{ .gate = .clear, .reason = null };
}

// ---------------------------------------------------------------------------
// Predicate facts
// ---------------------------------------------------------------------------

pub const Point = struct { x: i32, y: i32 };

pub const TermKind = enum { x_range, y_range, up_input };
pub const Term = struct {
    kind: TermKind,
    source_kind: []const u8,
    min_pixel: ?i32 = null,
    max_pixel: ?i32 = null,
};
pub const Record = struct { entity: u8, terms: []const Term };
pub const Predicates = struct {
    records: []const Record,
    position: Point,
    up_held: ?bool,
};

pub fn validatePredicates(facts: Predicates) !void {
    if (facts.records.len > 64) return error.TooManyPredicateRecords;
    for (facts.records, 0..) |record, index| {
        if (record.entity != index or record.terms.len > 16) return error.InvalidPredicateRecord;
        for (record.terms) |term| {
            const expected = switch (term.kind) {
                .x_range => "event_predicate_0b",
                .y_range => "event_predicate_0c",
                .up_input => "event_predicate_04",
            };
            if (!std.mem.eql(u8, term.source_kind, expected)) return error.InvalidPredicateRecord;
            if (term.kind == .up_input) {
                if (term.min_pixel != null or term.max_pixel != null) return error.InvalidPredicateRecord;
            } else {
                const low = term.min_pixel orelse return error.InvalidPredicateRecord;
                const high = term.max_pixel orelse return error.InvalidPredicateRecord;
                if (low < 0 or high < low or high > 2040 or @mod(low, 8) != 0 or @mod(high, 8) != 0)
                    return error.InvalidPredicateRecord;
            }
        }
    }
}

/// Matches `field_events.PredicateFacts.resolve`; null means the host has no
/// proven answer and dispatch must block instead of treating it as false.
pub fn resolve(raw: *const anyopaque, entity: u8, index: usize, semantics: []const u8) ?bool {
    const facts: *const Predicates = @ptrCast(@alignCast(raw));
    if (entity >= facts.records.len) return null;
    const record = facts.records[entity];
    if (record.entity != entity or index >= record.terms.len) return null;
    const term = record.terms[index];
    if (!std.mem.eql(u8, term.source_kind, semantics)) return null;
    return switch (term.kind) {
        .x_range => facts.position.x >= term.min_pixel.? and facts.position.x <= term.max_pixel.?,
        .y_range => facts.position.y >= term.min_pixel.? and facts.position.y <= term.max_pixel.?,
        .up_input => facts.up_held,
    };
}

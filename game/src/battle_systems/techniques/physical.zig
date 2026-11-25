//! Remaining class-1 physical rune techniques.
//!
//! Source: MAIN.EXE (LBA 17976, 757760 B).  Rune byte 8..13 selects the
//! class-1 dispatcher table `0x8016A630[1..6]`; each descriptor's `+0x1C`
//! installs one of six callbacks and the handler stores a damage numerator at
//! `0x8017A008`, which updater `0x800F881C` applies as
//! `physical_damage * numerator / 10` to the exact target before clearing the
//! target latch (`target+0x40` bit 2).  Class 1 skips the magic charge service
//! `0x800F5344` (dispatcher `0x800F56F0` branches over it).
//!
//! Shrike, Falcon and Trick are the three techniques this pack adds; Boar and
//! Clone are already wired by the shared battle module, and Hate is typed
//! unsupported because its stage creates an auxiliary actor.

const std = @import("std");

pub const technique_count = 6;

/// Source rune byte as stored in a character record at `+0x4C`.
pub const RuneByte = u8;
pub const boar_rune: RuneByte = 8;
pub const shrike_rune: RuneByte = 9;
pub const falcon_rune: RuneByte = 10;
pub const hate_rune: RuneByte = 11;
pub const trick_rune: RuneByte = 12;
pub const clone_rune: RuneByte = 13;

pub const Technique = enum(u8) {
    boar = 1,
    shrike = 2,
    falcon = 3,
    hate = 4,
    trick = 5,
    clone = 6,
};

pub const Status = enum { shared, physical_rune, unsupported };

pub const Info = struct {
    technique: Technique,
    rune_byte: RuneByte,
    /// `0x8017A008` store in the handler; denominator is always 10.
    numerator: u16,
    denominator: u16 = 10,
    callback: u32,
    status: Status,
    /// Fixed recovery status is proven only for Boar/Clone (`op40(7,100)`).
    recovery: ?u8 = null,
    recovery_proven: bool = false,
    /// Hate's impact belongs to a newly allocated auxiliary actor.
    auxiliary_stage: bool = false,
    /// Instruction site of the `ori` numerator, recorded for re-derivation.
    multiplier_site: u32,
};

pub const info_table = [_]Info{
    .{ .technique = .boar, .rune_byte = boar_rune, .numerator = 20, .callback = 0x800F8A9C, .status = .shared, .recovery = 7, .recovery_proven = true, .multiplier_site = 0x800F8B2C },
    .{ .technique = .shrike, .rune_byte = shrike_rune, .numerator = 20, .callback = 0x800F8FB4, .status = .physical_rune, .multiplier_site = 0x800F9024 },
    .{ .technique = .falcon, .rune_byte = falcon_rune, .numerator = 30, .callback = 0x800F8C24, .status = .physical_rune, .multiplier_site = 0x800F8CB4 },
    .{ .technique = .hate, .rune_byte = hate_rune, .numerator = 30, .callback = 0x800F8D00, .status = .unsupported, .auxiliary_stage = true, .multiplier_site = 0x800F8F70 },
    .{ .technique = .trick, .rune_byte = trick_rune, .numerator = 15, .callback = 0x800F9064, .status = .physical_rune, .multiplier_site = 0x800F90D4 },
    .{ .technique = .clone, .rune_byte = clone_rune, .numerator = 20, .callback = 0x800F8B78, .status = .shared, .recovery = 7, .recovery_proven = true, .multiplier_site = 0x800F8BEC },
};

pub fn info(technique: Technique) Info {
    return info_table[@backingInt(technique) - 1];
}

/// Map a source rune byte to its class-1 technique.  `null` for every rune
/// that is not a physical-rune byte, including the special bytes 1/32/33.
pub fn techniqueForRune(rune_byte: RuneByte) ?Technique {
    if (rune_byte < boar_rune or rune_byte > clone_rune) return null;
    return @fromBackingInt(@intCast(rune_byte - boar_rune + 1));
}

/// The accepted magic catalogue inserts True Holy at index 20 and omits
/// Soul Eater / masked 32, so the catalogue id is **not** a constant shift.
/// This table is catalogue index -> source rune byte and is cross-checked
/// against `game/assets/magic_actions/catalogue.json`.
pub const catalogue_to_rune = [_]u8{
    2,  3,  4,  5,  6,  7,  8,  9,  10, 11,
    12, 13, 14, 15, 16, 17, 18, 19, 20, 21,
    33, 22, 23, 24, 25, 26, 27, 28, 29, 30,
    31,
};

pub fn catalogueIndex(rune_byte: RuneByte) ?u8 {
    for (catalogue_to_rune, 0..) |byte, index| {
        if (byte == rune_byte) return @intCast(index);
    }
    return null;
}

pub fn runeByteFromCatalogue(index: u8) ?RuneByte {
    if (index >= catalogue_to_rune.len) return null;
    return catalogue_to_rune[index];
}

/// Damage applied by updater `0x800F881C`: signed product then truncating
/// division by ten.  Damage is non-negative in the source call path.
pub fn damage(numerator: u16, amount: u32) u32 {
    const product = @as(u64, amount) * @as(u64, numerator);
    return @intCast(product / 10);
}

/// The one-shot latch at the target actor's `+0x40` bit 2.  The updater checks
/// the bit, applies damage, and clears it, so a second callback pass in the
/// same impact is inert (proven by the accepted physical-rune gate).
pub const Latch = struct {
    armed: bool = false,

    pub fn arm(self: *Latch) void {
        self.armed = true;
    }

    /// Returns true exactly once after `arm`.
    pub fn consume(self: *Latch) bool {
        if (!self.armed) return false;
        self.armed = false;
        return true;
    }
};

pub const Presentation = enum {
    /// Port fallback until the exported physical actor programs reach the live controller.
    ordinary_attack,
};

pub const Strike = struct {
    technique: Technique,
    rune_byte: RuneByte,
    target: usize,
    numerator: u16,
    denominator: u16,
    /// Dispatcher `0x800F56F0` skips `0x800F5344` for class 1.
    charge_cost: u16,
    presentation: Presentation = .ordinary_attack,
    recovery: ?u8,
    latch: Latch = .{},
};

pub const Unsupported = enum {
    /// Hate stage `0x800F8DB0` allocates an auxiliary through `0x800E1E3C`
    /// and re-enters `0x800E3820`; that actor is not the rune holder.
    auxiliary_actor_creation,
    /// A reserved identity (Soul Eater, masked 32, True Holy) must never be
    /// substituted with a physical technique.
    reserved_rune_identity,
};

pub const Outcome = union(enum) {
    strike: Strike,
    unsupported: Unsupported,
};

pub const Request = struct {
    rune_byte: RuneByte,
    actor_can_act: bool,
    target: ?usize,
    target_live: bool,
};

pub const PlanError = error{
    ActorCannotAct,
    NotPhysicalRune,
    MissingTarget,
    InvalidTarget,
};

/// Eligibility and cost for a class-1 technique.  This is the shared action
/// hook: the caller owns scheduling and presentation, while the module owns the
/// source-qualified rule boundary.  Unproven families return `unsupported`
/// instead of falling back to an ordinary attack.
pub fn plan(request: Request) PlanError!Outcome {
    if (!request.actor_can_act) return error.ActorCannotAct;
    const technique = techniqueForRune(request.rune_byte) orelse {
        if (request.rune_byte == 1 or request.rune_byte == 32 or request.rune_byte == 33) {
            return .{ .unsupported = .reserved_rune_identity };
        }
        return error.NotPhysicalRune;
    };
    const metadata = info(technique);
    if (metadata.status == .unsupported) {
        return .{ .unsupported = .auxiliary_actor_creation };
    }
    const target = request.target orelse return error.MissingTarget;
    if (!request.target_live) return error.InvalidTarget;
    var strike = Strike{
        .technique = technique,
        .rune_byte = request.rune_byte,
        .target = target,
        .numerator = metadata.numerator,
        .denominator = metadata.denominator,
        .charge_cost = 0,
        .recovery = metadata.recovery,
    };
    strike.latch.arm();
    return .{ .strike = strike };
}

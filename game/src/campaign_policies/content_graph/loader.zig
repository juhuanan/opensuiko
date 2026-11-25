//! Immutable reviewed-content graph loader and identity joins.
//!
//! The graph is produced by the extraction pipeline from reviewed,
//! read-only sprite, party-action, item-ledger, and enemy-policy inputs.  This module owns:
//!
//!   * strict decoding and structural validation of that packet;
//!   * recomputation of every section digest, so a substituted or edited asset
//!     is refused instead of trusted;
//!   * named identity joins (character, pose, action, item, enemy, formation)
//!     that re-check page/palette/pose/roster identity at the consumer;
//!   * refcounted content lifetime that survives a mode switch and a checkpoint
//!     restore;
//!   * the explicit spell-presentation dependency, which is refused rather
//!     than defaulted.
//!
//! There is no writer API: `Content` exposes read-only accessors and the live
//! session commits a change only after the matching join succeeded.

const std = @import("std");
pub const schema = @import("schema.zig");
const digest = @import("digest.zig");

pub const Graph = schema.Graph;
pub const Character = schema.Character;
pub const Action = schema.Action;
pub const Pose = schema.Pose;
pub const Item = schema.Item;
pub const Area = schema.Area;
pub const Enemy = schema.Enemy;
pub const Formation = schema.Formation;
pub const Blocker = schema.Blocker;
pub const Evaluation = struct {
    ready: bool,
    residency_status: []const u8,
    action_status: []const u8,
    admission: schema.Admission,
    residency_blockers: []const Blocker,
    action_blockers: []const Blocker,
    required_animations: []const u32,
};

pub const Error = error{
    GraphTooLarge,
    InvalidSchema,
    InvalidRevision,
    InvalidPackageSet,
    CrossVersionSubstitution,
    InvalidDigest,
    ContentDigestMismatch,
    DuplicateId,
    InvalidCharacter,
    InvalidPage,
    InvalidPalette,
    InvalidPose,
    PoseNotResident,
    PageIdentityMismatch,
    PaletteIdentityMismatch,
    InvalidAnimation,
    AnimationUnresolved,
    InvalidAction,
    ActionNotAdmitted,
    InvalidBlocker,
    InvalidItem,
    UnknownItem,
    AmbiguousItem,
    InvalidCategory,
    InvalidArea,
    InvalidEnemy,
    InvalidFormation,
    FormationIdentityMismatch,
    InvalidPolicy,
    InvalidDrop,
    InvalidPresentationDependency,
    SpellPresentationUnavailable,
    UnknownCharacter,
    UnknownPose,
    UnknownArea,
    UnknownFormation,
    UnknownEnemy,
    InvalidName,
    InvalidUses,
    LiveStateFull,
    InvalidCheckpoint,
};

/// Reviewed package digests.  A graph that names any other reviewed asset is a
/// different version and is refused at the consumer, not silently joined.
const reviewed = struct {
    const sprite_residency_asset = "2599058d4581f3b5349027d16be34077460d4f2735558462ac893baea1cea38f";
    const party_actions_asset = "9762265f75efcfdbb7b6db3c1aa9ae056a4462b380f851ca83513ae7624f218d";
    const item_contracts_asset = "ca19a0f12154b99a6c1275cafe2b420e0f14502885548830a40f551920521fa9";
    const enemy_policy_asset = "24b014bb9567150d92cc6bcca4fca3d775da5995e77d1ea38c9817cd16c4664c";
    const item_digest = "b23023b00e0e1aef";
};

pub const max_graph_bytes = 8 * 1024 * 1024;
const expected_characters = 78;
const expected_compatible = 74;
const expected_items = 179;
const expected_areas = 8;
const expected_enemies = 29;
const expected_formations = 77;
const expected_drop_items = 37;
const expected_policy_blocked = 2;
const expected_effect_blocked = 11;
const expected_duplicate_groups = 1;
const expected_fragments = 5;

const action_families = [_][]const u8{ "melee", "ranged_sequence", "stationary_auxiliary" };
const action_statuses = [_][]const u8{ "ready", "mechanics_ready", "blocked" };
const residency_statuses = [_][]const u8{ "supported", "blocked" };
const policy_families = [_][]const u8{
    "random_target",
    "target_then_script_chance",
    "target_then_special_chance",
    "own_row_special",
    "target_row_special",
    "always_special",
    "blocked",
};
const special_families = [_][]const u8{
    "target_then_script_chance",
    "target_then_special_chance",
    "own_row_special",
    "target_row_special",
    "always_special",
};
const blocker_kinds = [_][]const u8{
    "unproven_global_script_roots",
    "missing_resident_page",
    "unresolved_animation_reachability",
    "residency_blocked",
    "residency_unresolved_pose",
    "unresolved_timeline",
    "unresolved_reaction_contract",
    "unresolved_impact_trigger",
    "unresolved_owner_ready",
    "pre_scan_special",
    "unresolved_library_slot_124",
    "unresolved_special_effect",
    "deposit_requires_personal_inventory",
    "warehouse_quantity_not_owned",
    "handler_slots_above_13_are_not_code",
    "personal_inventory_and_save_schema_not_rewritten",
};
const item_categories = [_]struct { id: []const u8, count: u32, ownership: []const u8 }{
    .{ .id = "equipment_head", .count = 8, .ownership = "personal_equipment" },
    .{ .id = "equipment_body", .count = 16, .ownership = "personal_equipment" },
    .{ .id = "equipment_shield", .count = 4, .ownership = "personal_equipment" },
    .{ .id = "equipment_feet_or_accessory", .count = 30, .ownership = "personal_equipment" },
    .{ .id = "consumable", .count = 4, .ownership = "usable_bundle" },
    .{ .id = "stat_rune_piece", .count = 6, .ownership = "usable_bundle" },
    .{ .id = "key_tool", .count = 3, .ownership = "usable_tool" },
    .{ .id = "weapon_fragment", .count = 5, .ownership = "weapon_attachment" },
    .{ .id = "appraised_decoration", .count = 22, .ownership = "appraisal" },
    .{ .id = "key_item", .count = 81, .ownership = "shared_key" },
};
const supported_ops = [_][]const u8{ "shared_acquire", "shared_remove", "shared_query", "transfer_check", "consume_preview" };

fn contains(comptime set: []const []const u8, value: []const u8) bool {
    for (set) |candidate| if (std.mem.eql(u8, candidate, value)) return true;
    return false;
}

fn isHex(text: []const u8, comptime length: usize) bool {
    if (text.len != length) return false;
    for (text) |byte| {
        if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

fn findPage(pages: []const schema.Page, index: u32) ?*const schema.Page {
    for (pages) |*page| if (page.index == index) return page;
    return null;
}

fn findPalette(palettes: []const schema.Palette, index: u32) ?*const schema.Palette {
    for (palettes) |*palette| if (palette.index == index) return palette;
    return null;
}

fn findPose(poses: []const schema.Pose, index: u32) ?*const schema.Pose {
    for (poses) |*pose| if (pose.index == index) return pose;
    return null;
}

fn findAnimation(animations: []const schema.Animation, index: u32) ?*const schema.Animation {
    for (animations) |*animation| if (animation.index == index) return animation;
    return null;
}

fn hasIndex(values: []const u32, index: u32) bool {
    for (values) |value| if (value == index) return true;
    return false;
}

fn hasPage(bindings: []const schema.PageBinding, index: u32) bool {
    for (bindings) |binding| if (binding.index == index) return true;
    return false;
}

fn hasPalette(bindings: []const schema.PaletteBinding, index: u32) bool {
    for (bindings) |binding| if (binding.index == index) return true;
    return false;
}

fn hasAnimation(animations: []const schema.Animation, index: u32) bool {
    for (animations) |animation| if (animation.index == index) return true;
    return false;
}

/// A piece samples its 128-pixel page column-wise.  Columns beyond the page
/// width continue into the next page; columns past the resident set are
/// outside samples.  This reproduces the reviewed residency plan and is the identity
/// rule the consumer enforces for every piece.
const SamplingPlan = struct { cross: u32, outside: u32 };

fn samplingPlan(pages: []const schema.Page, piece: schema.Piece) Error!SamplingPlan {
    const page = findPage(pages, piece.page) orelse return error.PageIdentityMismatch;
    if (piece.v + piece.height > page.height) return error.PageIdentityMismatch;
    const overflow: u64 = @as(u64, piece.u) + piece.width -| @as(u64, page.width);
    const cross: u64 = overflow * piece.height;
    if (cross > std.math.maxInt(u32)) return error.InvalidPose;
    const outside: u32 = if (piece.page + 1 >= pages.len) @intCast(cross) else 0;
    return .{ .cross = @intCast(cross), .outside = outside };
}

fn poseIdentityEqual(action_pose: schema.Pose, resident_pose: schema.Pose) bool {
    if (action_pose.width != resident_pose.width or action_pose.height != resident_pose.height) return false;
    if (action_pose.anchor.x != resident_pose.anchor.x or action_pose.anchor.y != resident_pose.anchor.y) return false;
    if (action_pose.pieces.len != resident_pose.pieces.len) return false;
    for (action_pose.pieces, resident_pose.pieces) |left, right| {
        if (left.page != right.page or left.palette != right.palette) return false;
        if (left.u != right.u or left.v != right.v or left.width != right.width or left.height != right.height) return false;
        if (left.flip_x != right.flip_x or left.flip_y != right.flip_y) return false;
        if (left.cross_page_samples != right.cross_page_samples) return false;
        if (left.outside_samples != right.outside_samples) return false;
    }
    return true;
}

fn animationIdentityEqual(left: schema.Animation, right: schema.Animation) bool {
    if (left.frames.len != right.frames.len) return false;
    for (left.frames, right.frames) |a, b| {
        if (a.pose != b.pose or a.ticks != b.ticks) return false;
    }
    return true;
}

fn blockerKindKnown(kind: []const u8) bool {
    inline for (blocker_kinds) |candidate| if (std.mem.eql(u8, candidate, kind)) return true;
    return false;
}

fn validateBlocker(value: schema.Blocker) Error!void {
    if (!blockerKindKnown(value.kind)) return error.InvalidBlocker;
    if (value.poses) |poses| if (poses.len > 64) return error.InvalidBlocker;
    if (value.animations) |animations| if (animations.len > 64) return error.InvalidBlocker;
}

/// The consumer-side pose residency rule: every piece must resolve inside the
/// character's resident pages and palettes, the reviewed sampling plan must
/// still hold, and a pose with outside samples is refused rather than drawn
/// from a missing page.  Exposed for the refusal tests.
pub fn verifyPoseResidency(character: schema.Character, pose: schema.Pose) Error!void {
    for (pose.pieces) |piece| {
        _ = findPage(character.pages, piece.page) orelse return error.PageIdentityMismatch;
        _ = findPalette(character.palettes, piece.palette) orelse return error.PaletteIdentityMismatch;
        const plan = try samplingPlan(character.pages, piece);
        if (plan.cross != piece.cross_page_samples or plan.outside != piece.outside_samples)
            return error.PageIdentityMismatch;
        if (piece.outside_samples != 0) return error.PoseNotResident;
    }
}

/// The consumer-side action/residency agreement check.  It re-derives every committed
/// page, palette, pose and animation binding from the sprite-residency record, so an action
/// asset compiled against another residency revision cannot be joined.  Exposed so
/// the rejection paths can be exercised with a deliberately altered record.
pub fn verifyActionBinding(character: schema.Character, action: schema.Action) Error!void {
    if (!contains(&action_families, action.family)) return error.InvalidAction;
    if (!contains(&action_statuses, action.status)) return error.InvalidAction;
    if (!isHex(action.binding_sha256, 64)) return error.InvalidAction;
    if (std.mem.eql(u8, action.status, "ready") and action.required_animations.len == 0) return error.InvalidAction;
    if (std.mem.eql(u8, action.status, "ready") and !action.admission.complete()) return error.InvalidAction;
    if (std.mem.eql(u8, action.status, "ready") and action.blockers.len != 0) return error.InvalidAction;
    for (action.blockers) |entry| try validateBlocker(entry);

    for (action.pages) |binding| {
        const page = findPage(character.pages, binding.index) orelse return error.PageIdentityMismatch;
        if (!isHex(binding.sha256, 64)) return error.PageIdentityMismatch;
        if (!std.mem.eql(u8, page.sha256, binding.sha256)) return error.PageIdentityMismatch;
    }
    for (action.palettes) |binding| {
        const palette = findPalette(character.palettes, binding.index) orelse return error.PaletteIdentityMismatch;
        if (!isHex(binding.sha256, 64)) return error.PaletteIdentityMismatch;
        if (!std.mem.eql(u8, palette.sha256, binding.sha256) or palette.words != binding.words) return error.PaletteIdentityMismatch;
    }
    for (action.poses) |action_pose| {
        const resident = findPose(character.poses, action_pose.index) orelse return error.CrossVersionSubstitution;
        if (!poseIdentityEqual(action_pose, resident.*)) return error.CrossVersionSubstitution;
        for (action_pose.pieces) |piece| {
            if (!hasPage(action.pages, piece.page)) return error.PageIdentityMismatch;
            if (!hasPalette(action.palettes, piece.palette)) return error.PaletteIdentityMismatch;
            _ = try samplingPlan(character.pages, piece);
        }
    }
    for (action.animations) |action_animation| {
        const resident = findAnimation(character.animations, action_animation.index) orelse return error.CrossVersionSubstitution;
        if (!resident.resolved or resident.missing_poses.len != 0) return error.AnimationUnresolved;
        if (!animationIdentityEqual(action_animation, resident.*)) return error.CrossVersionSubstitution;
        if (!action_animation.resolved or action_animation.missing_poses.len != 0) return error.AnimationUnresolved;
    }
    for (action.required_animations) |required| {
        if (!hasAnimation(action.animations, required)) return error.InvalidAction;
        if (!hasIndex(character.action_animations, required)) return error.InvalidAction;
    }
}

fn validateCharacter(character: schema.Character) Error!void {
    if (character.id.len == 0) return error.InvalidCharacter;
    if (!contains(&residency_statuses, character.residency_status)) return error.InvalidCharacter;
    for (character.blockers) |entry| try validateBlocker(entry);

    for (character.pages, 0..) |page, position| {
        if (page.index != position) return error.InvalidPage;
        if (page.width != 128 or page.height != 128) return error.InvalidPage;
        if (!isHex(page.sha256, 64)) return error.InvalidPage;
    }
    for (character.palettes, 0..) |palette, position| {
        if (palette.index != position) return error.InvalidPalette;
        if (palette.words != 32 and palette.words != 256) return error.InvalidPalette;
        if (!isHex(palette.sha256, 64)) return error.InvalidPalette;
    }
    for (character.poses, 0..) |pose, position| {
        if (pose.index != position) return error.InvalidPose;
        if (pose.pieces.len == 0) return error.InvalidPose;
        for (pose.pieces) |piece| {
            _ = findPalette(character.palettes, piece.palette) orelse return error.PaletteIdentityMismatch;
            const plan = try samplingPlan(character.pages, piece);
            if (plan.cross != piece.cross_page_samples) return error.InvalidPose;
            if (plan.outside != piece.outside_samples) return error.InvalidPose;
            if (piece.outside_samples != 0 and piece.page + 1 < character.pages.len) return error.InvalidPose;
        }
    }
    for (character.animations, 0..) |animation, position| {
        if (animation.index != position) return error.InvalidAnimation;
        if (animation.resolved == (animation.missing_poses.len != 0)) return error.InvalidAnimation;
        for (animation.frames) |frame| {
            if (frame.ticks == 0) return error.InvalidAnimation;
            if (frame.pose >= character.poses.len) {
                if (animation.resolved) return error.InvalidAnimation;
                if (!hasIndex(animation.missing_poses, frame.pose)) return error.InvalidAnimation;
            }
        }
    }
    for (character.action_poses) |index| {
        if (index >= character.poses.len) return error.InvalidAction;
    }
    for (character.action_animations) |index| {
        if (index >= character.animations.len) return error.InvalidAction;
    }
    const action = character.action orelse return error.InvalidAction;
    try verifyActionBinding(character, action);
}

fn validateItemCatalogue(graph: *const schema.Graph) Error!void {
    const catalogue = graph.item_catalogue;
    if (graph.items.len != expected_items) return error.InvalidItem;
    if (!std.mem.eql(u8, catalogue.digest, graph.digests.items)) return error.InvalidDigest;
    if (!std.mem.eql(u8, graph.digests.items, reviewed.item_digest)) return error.CrossVersionSubstitution;
    if (catalogue.engine.shared_capacity != 7) return error.InvalidItem;
    if (catalogue.categories.len != item_categories.len) return error.InvalidCategory;
    for (catalogue.categories, 0..) |category, position| {
        if (!std.mem.eql(u8, category.id, item_categories[position].id)) return error.InvalidCategory;
        if (category.count != item_categories[position].count) return error.InvalidCategory;
        if (!std.mem.eql(u8, category.ownership, item_categories[position].ownership)) return error.InvalidCategory;
    }
    for (catalogue.blockers) |entry| try validateBlocker(entry);
    if (catalogue.identity.duplicate_label_groups.len != expected_duplicate_groups) return error.InvalidItem;
    if (catalogue.identity.weapon_fragments.len != expected_fragments) return error.InvalidItem;

    var counts: [item_categories.len]u32 = @splat(0);
    for (graph.items, 0..) |item, position| {
        if (item.id.len == 0) return error.InvalidItem;
        var category_index: ?usize = null;
        for (item_categories, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.id, item.category)) {
                category_index = index;
                break;
            }
        }
        const resolved_category = category_index orelse return error.InvalidCategory;
        counts[resolved_category] += 1;
        const equipment = resolved_category < 4;
        if (equipment) {
            const slot = item.equipment_slot orelse return error.InvalidItem;
            if (!(std.mem.eql(u8, slot, "head") or std.mem.eql(u8, slot, "body") or
                std.mem.eql(u8, slot, "shield") or std.mem.eql(u8, slot, "feet_or_accessory")))
                return error.InvalidItem;
            if (item.equipment_type_mask == 0) return error.InvalidItem;
        } else {
            if (item.equipment_slot != null or item.equipment_type_mask != 0) return error.InvalidItem;
        }
        for (item.supported_ops) |operation| {
            if (!contains(&supported_ops, operation)) return error.InvalidItem;
        }
        for (graph.items[0..position]) |previous| {
            if (std.mem.eql(u8, previous.id, item.id)) return error.DuplicateId;
            if (previous.source_item_id == item.source_item_id) return error.DuplicateId;
        }
    }
    for (counts, 0..) |count, index| {
        if (count != item_categories[index].count) return error.InvalidCategory;
    }
    if (digest.items(graph)) |computed| {
        if (!std.mem.eql(u8, &computed, catalogue.digest)) return error.ContentDigestMismatch;
    } else return error.ContentDigestMismatch;
}

fn validatePolicy(policy: schema.Policy, enemy: schema.Enemy, graph: *const schema.Graph) Error!void {
    if (!contains(&policy_families, policy.family)) return error.InvalidPolicy;
    for (enemy.drops) |drop| {
        if (drop.item) |source_id| {
            var found = false;
            for (graph.items) |item| if (item.source_item_id == source_id) {
                found = true;
                break;
            };
            if (!found) return error.InvalidDrop;
        } else if (drop.rate != 0) return error.InvalidDrop;
    }
    if (std.mem.eql(u8, policy.family, "blocked")) {
        if (policy.blocker == null or policy.scan != null or policy.special != null) return error.InvalidPolicy;
        try validateBlocker(policy.blocker.?);
        return;
    }
    if (policy.blocker != null) return error.InvalidPolicy;
    const scan = policy.scan orelse return error.InvalidPolicy;
    if (scan.accept_at_least > 100) return error.InvalidPolicy;
    if (contains(&special_families, policy.family)) {
        const special = policy.special orelse return error.InvalidPolicy;
        if (special.wait_frames > 600) return error.InvalidPolicy;
        if (special.effect_blocker) |blocker| try validateBlocker(blocker);
    } else if (policy.special != null) return error.InvalidPolicy;
    if (std.mem.eql(u8, policy.family, "random_target")) {
        if (policy.second_draw != null or policy.own_row_front_below != null or policy.target_row_front_below != null)
            return error.InvalidPolicy;
    }
    if (std.mem.eql(u8, policy.family, "own_row_special")) {
        if (policy.own_row_front_below == null) return error.InvalidPolicy;
    }
    if (std.mem.eql(u8, policy.family, "target_row_special")) {
        if (policy.target_row_front_below == null) return error.InvalidPolicy;
    }
    if (std.mem.startsWith(u8, policy.family, "target_then_")) {
        if (policy.second_draw == null) return error.InvalidPolicy;
    }
}

fn validateArea(area: schema.Area, graph: *const schema.Graph) Error!void {
    if (area.id.len == 0) return error.InvalidArea;
    for (area.enemies, 0..) |enemy, position| {
        if (enemy.id.len == 0 or enemy.name.len == 0) return error.InvalidEnemy;
        if (!std.mem.startsWith(u8, enemy.id, area.id)) return error.InvalidEnemy;
        for (area.enemies[0..position]) |previous| {
            if (std.mem.eql(u8, previous.id, enemy.id)) return error.DuplicateId;
        }
        if (enemy.level == 0 or enemy.level > 99) return error.InvalidEnemy;
        if (enemy.formation_footprint > 1) return error.InvalidEnemy;
        try validatePolicy(enemy.policy, enemy, graph);
    }
    for (area.formations, 0..) |formation, position| {
        if (formation.id.len == 0) return error.InvalidFormation;
        if (!std.mem.startsWith(u8, formation.id, area.id)) return error.InvalidFormation;
        for (area.formations[0..position]) |previous| {
            if (std.mem.eql(u8, previous.id, formation.id)) return error.DuplicateId;
        }
        try verifyFormation(area, formation);
    }
}

/// Re-derives the formation identity: six slots, `active` occupied slots, and
/// each occupied slot's roster index resolving to the referenced area enemy.
/// Exposed for the consumer-side rejection tests.
pub fn verifyFormation(area: schema.Area, formation: schema.Formation) Error!void {
    if (formation.slots.len != 6) return error.FormationIdentityMismatch;
    if (formation.active == 0 or formation.active > 6) return error.FormationIdentityMismatch;
    var occupied: u32 = 0;
    for (formation.slots) |slot| {
        if (slot.enemy) |enemy_id| {
            occupied += 1;
            if (slot.roster_id == 0 or slot.roster_id > area.enemies.len) return error.FormationIdentityMismatch;
            if (!std.mem.eql(u8, area.enemies[slot.roster_id - 1].id, enemy_id)) return error.FormationIdentityMismatch;
        } else if (slot.roster_id != 0) return error.FormationIdentityMismatch;
    }
    if (occupied != formation.active) return error.FormationIdentityMismatch;
}

fn validateGraph(graph: *const schema.Graph) Error!u16 {
    if (!std.mem.eql(u8, graph.schema, schema.schema_id)) return error.InvalidSchema;
    if (!std.mem.eql(u8, graph.revision, "content-graph.1")) return error.InvalidRevision;

    if (graph.provenance.packages.len != 4) return error.InvalidPackageSet;
    const expected = [_]struct { id: []const u8, asset: []const u8, schema_id: []const u8 }{
        .{ .id = "sprite_residency", .asset = reviewed.sprite_residency_asset, .schema_id = "suikoden-battle-sprite-residency/3" },
        .{ .id = "party_actions", .asset = reviewed.party_actions_asset, .schema_id = "suikoden-party-action-contracts/2" },
        .{ .id = "item_contracts", .asset = reviewed.item_contracts_asset, .schema_id = "suikoden-full-item-contracts/1" },
        .{ .id = "enemy_policy", .asset = reviewed.enemy_policy_asset, .schema_id = "suikoden-enemy-policy-catalogue/1" },
    };
    for (graph.provenance.packages, expected) |package, want| {
        if (!std.mem.eql(u8, package.id, want.id)) return error.InvalidPackageSet;
        if (!std.mem.eql(u8, package.asset_file_sha256, want.asset)) return error.CrossVersionSubstitution;
        if (!std.mem.eql(u8, package.schema, want.schema_id)) return error.CrossVersionSubstitution;
        if (!isHex(package.commit, 40)) return error.InvalidPackageSet;
        if (!isHex(package.asset_canonical_sha256, 64)) return error.InvalidPackageSet;
        if (!isHex(package.proof_file_sha256, 64)) return error.InvalidPackageSet;
    }

    if (graph.provenance.resources.len == 0) return error.InvalidCharacter;
    for (graph.provenance.resources, 0..) |resource, position| {
        if (resource.id.len == 0 or !isHex(resource.sha256, 64)) return error.InvalidCharacter;
        for (graph.provenance.resources[0..position]) |previous| {
            if (std.mem.eql(u8, previous.id, resource.id)) return error.DuplicateId;
        }
    }

    if (graph.characters.len != expected_characters) return error.InvalidCharacter;
    var compatible: u16 = 0;
    for (graph.characters, 0..) |character, position| {
        for (graph.characters[0..position]) |previous| {
            if (std.mem.eql(u8, previous.id, character.id)) return error.DuplicateId;
        }
        var resource_found = false;
        for (graph.provenance.resources) |resource| {
            if (std.mem.eql(u8, resource.id, character.resource)) {
                resource_found = true;
                break;
            }
        }
        if (!resource_found) return error.InvalidCharacter;
        try validateCharacter(character);
        const action = character.action.?;
        if (std.mem.eql(u8, character.residency_status, "supported") and
            std.mem.eql(u8, action.status, "ready") and
            action.blockers.len == 0 and
            action.admission.complete()) compatible += 1;
    }
    if (compatible != expected_compatible) return error.InvalidCharacter;

    try validateItemCatalogue(graph);

    if (graph.areas.len != expected_areas) return error.InvalidArea;
    var enemies: u32 = 0;
    var formations: u32 = 0;
    var policy_blocked: u32 = 0;
    var effect_blocked: u32 = 0;
    for (graph.areas, 0..) |area, position| {
        for (graph.areas[0..position]) |previous| {
            if (std.mem.eql(u8, previous.id, area.id)) return error.DuplicateId;
        }
        try validateArea(area, graph);
        enemies += @intCast(area.enemies.len);
        formations += @intCast(area.formations.len);
        for (area.enemies) |enemy| {
            if (std.mem.eql(u8, enemy.policy.family, "blocked")) policy_blocked += 1;
            if (enemy.policy.special) |special| {
                if (special.effect_blocker != null) effect_blocked += 1;
            }
        }
    }
    if (enemies != expected_enemies) return error.InvalidEnemy;
    if (formations != expected_formations) return error.InvalidFormation;
    if (policy_blocked != expected_policy_blocked) return error.InvalidPolicy;
    if (effect_blocked != expected_effect_blocked) return error.InvalidPolicy;

    if (graph.drop_items.len != expected_drop_items) return error.InvalidDrop;
    for (graph.drop_items, 0..) |drop, position| {
        var found = false;
        for (graph.items) |item| if (item.source_item_id == drop.id) {
            found = true;
            break;
        };
        if (!found) return error.InvalidDrop;
        for (graph.drop_items[0..position]) |previous| {
            if (previous.id == drop.id) return error.DuplicateId;
        }
    }

    if (!std.mem.eql(u8, graph.spell_presentation.status, "unavailable")) return error.InvalidPresentationDependency;
    if (!std.mem.eql(u8, graph.spell_presentation.package, "spell_presentation")) return error.InvalidPresentationDependency;
    if (!std.mem.eql(u8, graph.spell_presentation.code, "presentation_correction_unavailable")) return error.InvalidPresentationDependency;
    if (!std.mem.eql(u8, graph.spell_presentation.owner, "magic_actions")) return error.InvalidPresentationDependency;
    if (!std.mem.eql(u8, graph.spell_presentation.required_interface, "spell_identity_to_presentation_frames_and_audio"))
        return error.InvalidPresentationDependency;

    const poses_hex = digest.hex(digest.poses(graph));
    if (!std.mem.eql(u8, &poses_hex, graph.digests.poses)) return error.ContentDigestMismatch;
    const actions_hex = digest.hex(digest.actions(graph));
    if (!std.mem.eql(u8, &actions_hex, graph.digests.actions)) return error.ContentDigestMismatch;
    const formations_hex = digest.hex(digest.formations(graph));
    if (!std.mem.eql(u8, &formations_hex, graph.digests.formations)) return error.ContentDigestMismatch;

    return compatible;
}

pub const Content = struct {
    allocator: std.mem.Allocator,
    parsed: std.json.Parsed(schema.Graph),
    refs: usize,
    exact_sha256: [64]u8,
    compatible: u16,

    pub fn graph(self: *const Content) *const schema.Graph {
        return &self.parsed.value;
    }

    pub fn references(self: *const Content) usize {
        return self.refs;
    }

    pub fn exactDigest(self: *const Content) []const u8 {
        return &self.exact_sha256;
    }

    pub fn compatibleCount(self: *const Content) u16 {
        return self.compatible;
    }

    pub fn retain(self: *Content) void {
        self.refs += 1;
    }

    pub fn release(self: *Content) void {
        std.debug.assert(self.refs > 0);
        self.refs -= 1;
        if (self.refs == 0) self.destroy();
    }

    fn destroy(self: *Content) void {
        self.parsed.deinit();
        self.allocator.destroy(self);
    }

    pub fn character(self: *const Content, id: []const u8) Error!*const schema.Character {
        const characters = self.graph().characters;
        for (characters, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.id, id)) return &characters[index];
        }
        return error.UnknownCharacter;
    }

    /// Pose identity join: the pose must belong to the character, every piece
    /// must resolve to a resident page and palette, and the reviewed sampling
    /// plan must still hold.  A pose with outside samples is refused rather
    /// than rendered from a missing page.
    pub fn pose(self: *const Content, character_id: []const u8, pose_index: u32) Error!*const schema.Pose {
        const record = try self.character(character_id);
        for (record.poses, 0..) |candidate, index| {
            if (candidate.index != pose_index) continue;
            try verifyPoseResidency(record.*, candidate);
            return &record.poses[index];
        }
        return error.UnknownPose;
    }

    pub fn evaluation(self: *const Content, character_id: []const u8) Error!Evaluation {
        const record = try self.character(character_id);
        const contract = record.action orelse return error.InvalidAction;
        const ready = std.mem.eql(u8, record.residency_status, "supported") and
            std.mem.eql(u8, contract.status, "ready") and
            contract.blockers.len == 0 and
            contract.admission.complete();
        return .{
            .ready = ready,
            .residency_status = record.residency_status,
            .action_status = contract.status,
            .admission = contract.admission,
            .residency_blockers = record.blockers,
            .action_blockers = contract.blockers,
            .required_animations = contract.required_animations,
        };
    }

    /// Action identity join: the consumer receives the action only when the
    /// reviewed party-action contract and the reviewed sprite residency agree and the record
    /// is admitted.  Blocked records stay blocked with their typed blockers.
    pub fn action(self: *const Content, character_id: []const u8) Error!*const schema.Action {
        const record = try self.character(character_id);
        const contract = if (record.action) |*value| value else return error.InvalidAction;
        try verifyActionBinding(record.*, contract.*);
        if (!std.mem.eql(u8, record.residency_status, "supported")) return error.ActionNotAdmitted;
        if (!std.mem.eql(u8, contract.status, "ready")) return error.ActionNotAdmitted;
        if (contract.blockers.len != 0) return error.ActionNotAdmitted;
        if (!contract.admission.complete()) return error.ActionNotAdmitted;
        return contract;
    }

    pub fn item(self: *const Content, id: []const u8) Error!*const schema.Item {
        for (self.graph().items) |*entry| {
            if (std.mem.eql(u8, entry.id, id)) return entry;
        }
        return error.UnknownItem;
    }

    pub fn itemBySourceId(self: *const Content, source_id: u16) Error!*const schema.Item {
        for (self.graph().items) |*entry| {
            if (entry.source_item_id == source_id) return entry;
        }
        return error.UnknownItem;
    }

    pub fn area(self: *const Content, id: []const u8) Error!*const schema.Area {
        const areas = self.graph().areas;
        for (areas, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.id, id)) return &areas[index];
        }
        return error.UnknownArea;
    }

    pub fn enemy(self: *const Content, area_id: []const u8, enemy_id: []const u8) Error!*const schema.Enemy {
        const area_entry = try self.area(area_id);
        for (area_entry.enemies, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.id, enemy_id)) return &area_entry.enemies[index];
        }
        return error.UnknownEnemy;
    }

    /// Formation identity join.  Revalidates the six-slot roster mapping on
    /// every access, so an edited formation cannot be used through a cached
    /// reference either.
    pub fn formation(self: *const Content, area_id: []const u8, formation_id: []const u8) Error!*const schema.Formation {
        const area_entry = try self.area(area_id);
        for (area_entry.formations, 0..) |record, index| {
            if (!std.mem.eql(u8, record.id, formation_id)) continue;
            try verifyFormation(area_entry.*, record);
            return &area_entry.formations[index];
        }
        return error.UnknownFormation;
    }

    pub fn dropItem(self: *const Content, item_id: u16) Error!*const schema.DropItem {
        for (self.graph().drop_items) |*entry| {
            if (entry.id == item_id) return entry;
        }
        return error.UnknownItem;
    }

    /// Spell-presentation dependency: no reviewed spell presentation exists, so the join is a
    /// typed refusal.  This is deliberately not an optional value.
    pub fn spellPresentation(self: *const Content) Error!void {
        _ = self;
        return error.SpellPresentationUnavailable;
    }
};

pub fn open(allocator: std.mem.Allocator, bytes: []const u8) !*Content {
    if (bytes.len > max_graph_bytes) return error.GraphTooLarge;
    var parsed = try std.json.parseFromSlice(schema.Graph, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    const compatible = try validateGraph(&parsed.value);

    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &raw, .{});
    const content = try allocator.create(Content);
    content.* = .{
        .allocator = allocator,
        .parsed = parsed,
        .refs = 1,
        .exact_sha256 = std.fmt.bytesToHex(raw, .lower),
        .compatible = compatible,
    };
    return content;
}

pub const ItemSlot = struct {
    id: schema.Name,
    uses: u8,
};

pub const Live = struct {
    mode: schema.Mode = .field,
    character: ?schema.Name = null,
    area: ?schema.Name = null,
    formation: ?schema.Name = null,
    items: [7]?ItemSlot = @splat(null),

    pub fn eql(self: Live, other: Live) bool {
        if (self.mode != other.mode) return false;
        if (!nameEql(self.character, other.character)) return false;
        if (!nameEql(self.area, other.area)) return false;
        if (!nameEql(self.formation, other.formation)) return false;
        for (self.items, other.items) |left, right| {
            if ((left == null) != (right == null)) return false;
            if (left) |a| {
                const b = right.?;
                if (!a.id.eql(&b.id) or a.uses != b.uses) return false;
            }
        }
        return true;
    }

    fn nameEql(left: ?schema.Name, right: ?schema.Name) bool {
        if ((left == null) != (right == null)) return false;
        if (left) |a| return a.eql(&right.?);
        return true;
    }
};

pub const Checkpoint = struct {
    graph_sha256: [64]u8,
    live: Live,
};

/// A live session.  Every mutation commits only after the corresponding join
/// succeeded, so a refused join leaves `live` byte-identical.
pub const Session = struct {
    content: *Content,
    live: Live = .{},

    pub fn init(content: *Content) Session {
        content.retain();
        return .{ .content = content, .live = .{} };
    }

    pub fn deinit(self: *Session) void {
        self.content.release();
        self.* = undefined;
    }

    pub fn switchMode(self: *Session, mode: schema.Mode) void {
        self.live.mode = mode;
    }

    pub fn selectCharacter(self: *Session, id: []const u8) Error!void {
        _ = try self.content.action(id);
        const name = schema.Name.init(id) catch return error.InvalidName;
        self.live.character = name;
    }

    pub fn bindFormation(self: *Session, area_id: []const u8, formation_id: []const u8) Error!void {
        _ = try self.content.formation(area_id, formation_id);
        const area_name = schema.Name.init(area_id) catch return error.InvalidName;
        const formation_name = schema.Name.init(formation_id) catch return error.InvalidName;
        self.live.area = area_name;
        self.live.formation = formation_name;
    }

    pub fn acquireItem(self: *Session, source_item_id: u16, uses: u8) Error!void {
        const item = try self.content.itemBySourceId(source_item_id);
        if (uses > item.max_uses) return error.InvalidUses;
        if (item.max_uses == 0 and uses != 0) return error.InvalidUses;
        var slot: ?usize = null;
        for (self.live.items, 0..) |entry, index| {
            if (entry == null) {
                slot = index;
                break;
            }
        }
        if (slot == null) return error.LiveStateFull;
        const name = schema.Name.init(item.id) catch return error.InvalidName;
        self.live.items[slot.?] = .{ .id = name, .uses = uses };
    }

    pub fn checkpoint(self: *const Session) Checkpoint {
        return .{ .graph_sha256 = self.content.exact_sha256, .live = self.live };
    }
};

/// Restores a checkpoint only against the exact graph it was made from.  A
/// different reviewed set is refused before any live state is produced, and
/// every named identity is re-joined against the current graph.
pub fn restore(content: *Content, checkpoint: Checkpoint) Error!Session {
    if (!std.mem.eql(u8, content.exactDigest(), &checkpoint.graph_sha256)) return error.CrossVersionSubstitution;
    if (checkpoint.live.character) |name| _ = try content.action(name.slice());
    if (checkpoint.live.formation) |formation_name| {
        const area_name = checkpoint.live.area orelse return error.InvalidCheckpoint;
        _ = try content.formation(area_name.slice(), formation_name.slice());
    } else if (checkpoint.live.area != null) return error.InvalidCheckpoint;
    for (checkpoint.live.items) |maybe| {
        if (maybe) |slot| {
            const item = try content.item(slot.id.slice());
            if (slot.uses > item.max_uses) return error.InvalidCheckpoint;
            if (item.max_uses == 0 and slot.uses != 0) return error.InvalidCheckpoint;
        }
    }
    var session = Session.init(content);
    session.live = checkpoint.live;
    return session;
}

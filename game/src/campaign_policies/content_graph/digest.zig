//! Section digests of the immutable content graph.
//!
//! The encoding is the fixed little-endian field encoding implemented a second
//! time by the extraction pipeline:
//!
//!   * integers: little-endian, no padding or alignment;
//!   * strings: u32 byte length + UTF-8 bytes;
//!   * arrays: u32 element count + elements in file order;
//!   * optionals: one presence byte + the value when present;
//!   * booleans: one byte, 0 or 1.
//!
//! `poses`, `actions` and `formations` are SHA-256 over that encoding.
//! `items` is the reviewed item-ledger semantic FNV-1a64 digest, reconstructed from the
//! item identity fields as specified by the item-ledger export.  Recomputing them here is
//! what lets the consumer refuse a substituted asset rather than trusting it.

const std = @import("std");
const schema = @import("schema.zig");

const ShaWriter = struct {
    hasher: std.crypto.hash.sha2.Sha256,

    fn init() ShaWriter {
        return .{ .hasher = std.crypto.hash.sha2.Sha256.init(.{}) };
    }

    fn put(self: *ShaWriter, bytes: []const u8) void {
        self.hasher.update(bytes);
    }

    fn u8v(self: *ShaWriter, value: u8) void {
        self.put(&[_]u8{value});
    }

    fn flag(self: *ShaWriter, value: bool) void {
        self.u8v(@intFromBool(value));
    }

    fn int(self: *ShaWriter, comptime T: type, value: T) void {
        var buffer: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
        std.mem.writeInt(T, &buffer, value, .little);
        self.put(&buffer);
    }

    fn text(self: *ShaWriter, value: []const u8) void {
        self.int(u32, @intCast(value.len));
        self.put(value);
    }

    fn optU32(self: *ShaWriter, value: ?u32) void {
        self.flag(value != null);
        if (value) |present| self.int(u32, present);
    }

    fn optText(self: *ShaWriter, value: ?[]const u8) void {
        self.flag(value != null);
        if (value) |present| self.text(present);
    }

    fn u32s(self: *ShaWriter, values: []const u32) void {
        self.int(u32, @intCast(values.len));
        for (values) |value| self.int(u32, value);
    }

    fn optU32s(self: *ShaWriter, values: ?[]const u32) void {
        self.flag(values != null);
        if (values) |present| self.u32s(present);
    }

    fn finish(self: *ShaWriter) [32]u8 {
        var digest: [32]u8 = undefined;
        self.hasher.final(&digest);
        return digest;
    }
};

fn blocker(writer: *ShaWriter, value: schema.Blocker) void {
    writer.text(value.kind);
    writer.optU32s(value.poses);
    writer.optU32s(value.animations);
    writer.optU32(value.samples);
    writer.optU32(value.opcode);
    writer.optText(value.track);
}

fn pose(writer: *ShaWriter, value: schema.Pose) void {
    writer.int(u32, value.index);
    writer.int(u32, value.width);
    writer.int(u32, value.height);
    writer.int(i32, value.anchor.x);
    writer.int(i32, value.anchor.y);
    writer.int(u32, @intCast(value.pieces.len));
    for (value.pieces) |piece| {
        writer.int(u32, piece.page);
        writer.int(u32, piece.palette);
        writer.int(u32, piece.u);
        writer.int(u32, piece.v);
        writer.int(u32, piece.width);
        writer.int(u32, piece.height);
        writer.optU32(if (piece.x) |x| @intCast(x) else null);
        writer.optU32(if (piece.y) |y| @intCast(y) else null);
        writer.flag(piece.flip_x);
        writer.flag(piece.flip_y);
        writer.int(u32, piece.cross_page_samples);
        writer.int(u32, piece.outside_samples);
    }
}

fn animation(writer: *ShaWriter, value: schema.Animation) void {
    writer.int(u32, value.index);
    writer.flag(value.resolved);
    writer.u32s(value.missing_poses);
    writer.int(u32, @intCast(value.frames.len));
    for (value.frames) |frame| {
        writer.int(u32, frame.pose);
        writer.int(u32, frame.ticks);
    }
}

pub fn poses(graph: *const schema.Graph) [32]u8 {
    var writer = ShaWriter.init();
    writer.int(u32, @intCast(graph.characters.len));
    for (graph.characters) |character| {
        writer.text(character.id);
        writer.text(character.resource);
        writer.text(character.residency_status);
        writer.flag(character.script_domain_complete);
        writer.int(u32, @intCast(character.blockers.len));
        for (character.blockers) |entry| blocker(&writer, entry);
        writer.int(u32, @intCast(character.pages.len));
        for (character.pages) |page| {
            writer.int(u32, page.index);
            writer.int(u32, page.slot);
            writer.int(u32, page.width);
            writer.int(u32, page.height);
            writer.text(page.sha256);
        }
        writer.int(u32, @intCast(character.palettes.len));
        for (character.palettes) |palette| {
            writer.int(u32, palette.index);
            writer.int(u32, palette.words);
            writer.text(palette.sha256);
        }
        writer.int(u32, @intCast(character.poses.len));
        for (character.poses) |entry| pose(&writer, entry);
        writer.int(u32, @intCast(character.animations.len));
        for (character.animations) |entry| animation(&writer, entry);
        writer.u32s(character.action_poses);
        writer.u32s(character.action_animations);
    }
    return writer.finish();
}

pub fn actions(graph: *const schema.Graph) [32]u8 {
    var writer = ShaWriter.init();
    writer.int(u32, @intCast(graph.characters.len));
    for (graph.characters) |character| {
        const action = character.action orelse {
            // load() refuses a character without an action; keep the digest
            // total anyway so a tampered packet cannot skip a record.
            writer.text(character.id);
            writer.text("");
            writer.text("");
            writer.text("");
            writer.u32s(&.{});
            continue;
        };
        writer.text(character.id);
        writer.text(action.family);
        writer.text(action.status);
        writer.text(action.binding_sha256);
        writer.u32s(action.required_animations);
        writer.flag(action.admission.mechanics_complete);
        writer.flag(action.admission.reaction_resolved);
        writer.flag(action.admission.residency_qualified);
        writer.int(u32, @intCast(action.blockers.len));
        for (action.blockers) |entry| blocker(&writer, entry);
        writer.int(u32, @intCast(action.pages.len));
        for (action.pages) |page| {
            writer.int(u32, page.index);
            writer.text(page.sha256);
        }
        writer.int(u32, @intCast(action.palettes.len));
        for (action.palettes) |palette| {
            writer.int(u32, palette.index);
            writer.int(u32, palette.words);
            writer.text(palette.sha256);
        }
        writer.int(u32, @intCast(action.poses.len));
        for (action.poses) |entry| pose(&writer, entry);
        writer.int(u32, @intCast(action.animations.len));
        for (action.animations) |entry| animation(&writer, entry);
    }
    return writer.finish();
}

pub fn formations(graph: *const schema.Graph) [32]u8 {
    var writer = ShaWriter.init();
    writer.int(u32, @intCast(graph.areas.len));
    for (graph.areas) |area| {
        writer.text(area.id);
        writer.text(area.label);
        writer.int(u32, @intCast(area.enemies.len));
        for (area.enemies) |enemy| {
            writer.text(enemy.id);
            writer.text(enemy.name);
            writer.int(u8, enemy.level);
            writer.int(u8, enemy.formation_footprint);
            writer.int(u16, enemy.hp);
            writer.int(u16, enemy.stats.power);
            writer.int(u16, enemy.stats.skill);
            writer.int(u16, enemy.stats.defense);
            writer.int(u16, enemy.stats.speed);
            writer.int(u16, enemy.stats.magic);
            writer.int(u16, enemy.stats.luck);
            for (enemy.element_coefficients) |coefficient| writer.int(u8, coefficient);
            writer.int(u16, enemy.feature_flags);
            writer.int(i16, enemy.money_encoded);
            writer.int(u32, @intCast(enemy.drops.len));
            for (enemy.drops) |drop| {
                writer.flag(drop.item != null);
                if (drop.item) |item| writer.int(u16, item);
                writer.int(u8, drop.rate);
            }
            const policy = enemy.policy;
            writer.text(policy.family);
            if (policy.scan) |scan| {
                writer.flag(true);
                writer.flag(scan.front_only);
                writer.text(scan.draw_kind);
                writer.int(u8, scan.accept_at_least);
            } else writer.flag(false);
            if (policy.second_draw) |second| {
                writer.flag(true);
                writer.text(second.kind);
                writer.int(u8, second.threshold);
            } else writer.flag(false);
            writer.optU32(if (policy.own_row_front_below) |value| @as(u32, value) else null);
            writer.optU32(if (policy.target_row_front_below) |value| @as(u32, value) else null);
            writer.optText(policy.no_selection);
            if (policy.special) |special| {
                writer.flag(true);
                writer.text(special.kind);
                writer.flag(special.target_required);
                writer.int(u16, special.wait_frames);
                writer.text(special.effect_kind);
                writer.flag(special.effect_blocker != null);
                if (special.effect_blocker) |entry| blocker(&writer, entry);
            } else writer.flag(false);
            writer.flag(policy.blocker != null);
            if (policy.blocker) |entry| blocker(&writer, entry);
        }
        writer.int(u32, @intCast(area.formations.len));
        for (area.formations) |formation| {
            writer.text(formation.id);
            writer.int(u8, formation.active);
            writer.int(u32, @intCast(formation.slots.len));
            for (formation.slots) |slot| {
                writer.int(u8, slot.roster_id);
                writer.optText(slot.enemy);
                writer.int(i32, slot.x);
                writer.int(i32, slot.y);
                writer.int(i32, slot.z);
            }
        }
    }
    writer.int(u32, @intCast(graph.drop_items.len));
    for (graph.drop_items) |drop| {
        writer.int(u16, drop.id);
        writer.int(u8, drop.default_uses);
    }
    return writer.finish();
}

// The reviewed item category partition; the same codes are used by the producer.
const category_codes = [_]struct { id: []const u8, code: u8 }{
    .{ .id = "equipment_head", .code = 1 },
    .{ .id = "equipment_body", .code = 2 },
    .{ .id = "equipment_shield", .code = 3 },
    .{ .id = "equipment_feet_or_accessory", .code = 4 },
    .{ .id = "consumable", .code = 5 },
    .{ .id = "stat_rune_piece", .code = 6 },
    .{ .id = "key_tool", .code = 7 },
    .{ .id = "weapon_fragment", .code = 8 },
    .{ .id = "appraised_decoration", .code = 9 },
    .{ .id = "key_item", .code = 10 },
};

const fragment_elements = [_][]const u8{ "fire", "water", "wind", "thunder", "earth" };

fn categoryCode(id: []const u8) ?u8 {
    for (category_codes) |entry| if (std.mem.eql(u8, entry.id, id)) return entry.code;
    return null;
}

fn fragmentCode(element: []const u8) ?u16 {
    for (fragment_elements, 0..) |candidate, index| if (std.mem.eql(u8, candidate, element)) return @intCast(index + 1);
    return null;
}

const Fnv = struct {
    value: u64 = 0xCBF29CE484222325,

    fn put(self: *Fnv, bytes: []const u8) void {
        for (bytes) |byte| {
            self.value ^= byte;
            self.value *%= 0x100000001B3;
        }
    }

    fn u8v(self: *Fnv, value: u8) void {
        self.put(&[_]u8{value});
    }

    fn int(self: *Fnv, comptime T: type, value: T) void {
        var buffer: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
        std.mem.writeInt(T, &buffer, value, .little);
        self.put(&buffer);
    }
};

/// The reviewed item-ledger semantic digest over the item identity fields.
pub fn items(graph: *const schema.Graph) ?[16]u8 {
    if (graph.items.len > std.math.maxInt(u16)) return null;
    var hash = Fnv{};
    hash.int(u16, @intCast(graph.items.len));
    for (graph.items) |item| {
        const category = categoryCode(item.category) orelse return null;
        hash.int(u16, item.source_item_id);
        hash.u8v(category);
        hash.int(u32, item.price);
        hash.u8v(item.max_uses);
        const flags_byte: u8 = @intFromBool(item.usable) |
            (@as(u8, @intFromBool(item.requires_target)) << 1) |
            (@as(u8, @intFromBool(item.battle_usable)) << 2) |
            (@as(u8, @intFromBool(item.duplicate_label)) << 3);
        hash.u8v(flags_byte);
        hash.u8v(item.equipment_type_mask);
        hash.u8v(item.appraisal_tier);
        var fragment: u16 = 0;
        if (item.weapon_fragment) |element| fragment = fragmentCode(element) orelse return null;
        hash.int(u16, fragment);
        if (item.id.len > std.math.maxInt(u8)) return null;
        hash.u8v(@intCast(item.id.len));
        hash.put(item.id);
        if (item.label.len > std.math.maxInt(u16)) return null;
        hash.int(u16, @intCast(item.label.len));
        hash.put(item.label);
    }
    var text: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&text, "{x:0>16}", .{hash.value}) catch return null;
    return text;
}

pub fn hex(digest: [32]u8) [64]u8 {
    return std.fmt.bytesToHex(digest, .lower);
}

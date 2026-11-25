const std = @import("std");

pub const expected_sha256 = "bcfbbab864174c4aee91057b5976b7c67059251f714428aed173704f228be15d";
pub const Source = struct { file: []const u8, lba: u32, size: u32, sha256: []const u8 };
pub const Asset = struct {
    schema: []const u8,
    source: Source,
    resource: Source,
    room: u8,
    entity: u8,
    opcode_offset: u32,
    opcode: u8,
    selector: u8,
    area_header_offset: u32,
    table_offset: u32,
    table_index: u8,
    template_offset: u32,
    template_copy_bytes: u32,
    template_copy_sha256: []const u8,
    character_id: u8,
    character: []const u8,
    portrait_offset: u32,
    portrait_container_bytes: u32,
    portrait_container_sha256: []const u8,
    portrait_decoded_bytes: u32,
    portrait_decoded_sha256: []const u8,
    palette_offset: u32,
    palette_bytes: u32,
    palette_sha256: []const u8,
};

pub fn open(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Asset) {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &hex, expected_sha256)) return error.UntrustedLocalTemplate;
    return std.json.parseFromSlice(Asset, allocator, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
}

// This is a proposal for the resource owner; the caller owns all mutations.
pub const Proposal = struct {
    expected_revision: u64,
    checkpoint: u64,
    slot: ?u8,
    character_id: u8,
    resource_sha256: []const u8,
    template_copy_sha256: []const u8,
    set_loaded_bit: bool = true,
    recount_required: bool = true,
};

pub fn resolve(asset: Asset, room: u8, entity: u8, offset: u32, selector: u8, active_count: u8, slots: [6]u8, revision: u64, checkpoint: u64) !Proposal {
    if (asset.character_id != 35 or asset.opcode != 0x1f or asset.selector != 0 or
        asset.room != 0 or asset.entity != 37 or asset.opcode_offset != 0x3b825 or
        !std.mem.eql(u8, asset.resource.sha256, "f68a6fccbc03b1a16a09b0d14c1b4838b6cc4206f0bd84c5b496c9d97b7fae20") or
        !std.mem.eql(u8, asset.template_copy_sha256, "719a9d3703748171629c6876654baed1da46e272540ad764341f53b54aeb245a")) return error.UntrustedLocalTemplate;
    if (room != asset.room or entity != asset.entity or offset != asset.opcode_offset or selector != asset.selector)
        return error.UnsupportedLocalTemplate;
    if (active_count > 6) return error.InvalidActiveCount;
    var selected: ?u8 = null;
    if (active_count < 6) {
        for (slots, 0..) |slot, index| {
            if (slot == 0xff) {
                selected = @intCast(index);
                break;
            }
        }
    }
    return .{ .expected_revision = revision, .checkpoint = checkpoint, .slot = selected, .character_id = asset.character_id, .resource_sha256 = asset.resource.sha256, .template_copy_sha256 = asset.template_copy_sha256 };
}

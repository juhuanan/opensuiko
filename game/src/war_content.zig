const std = @import("std");
const data = @import("war_data");

pub const schema = "suikoden-war-content/2";
pub const max_json_bytes = 4 * 1024 * 1024;

pub const Source = struct { file: []const u8, lba: u32, size: u32, sha256: []const u8 };
pub const Composition = struct {
    row_stride_cells: u16,
    page: []const u8,
    tile: []const u8,
    tile_width: u16,
    tile_height: u16,
    source_tile_width: u16,
    source_tile_height: u16,
    page_width: u16,
    page_height: u16,
    pixel_width: u32,
    pixel_height: u32,
};
pub const Map = struct {
    descriptor_offset: u32,
    width: u16,
    height: u16,
    cell_offset: u32,
    cells: []const u16,
    pages: []const []const u8,
    composition: Composition,
};
pub const Pose = struct {
    script_offset: u32,
    frame: u8,
    width: u8,
    height: u8,
    secondary: u8,
    flags: u8,
};
pub const Atlas = struct {
    descriptor_offset: u32,
    width: u16,
    height: u16,
    poses: []const Pose,
    resource: []const u8,
};
pub const TextRow = struct { offset: u32, name: ?[]const u8 = null, text: ?[]const u8 = null };
pub const Attack = struct { offset: u32, flags: u32, name: []const u8 };
pub const TerrainCodes = struct {
    descriptor_offset: u32,
    block_offsets: []const u32,
    blocks_sha256: []const []const u8,
};
pub const Scenario = struct {
    selector: u8,
    id: []const u8,
    source: Source,
    maps: []const Map,
    atlases: []const Atlas,
    portraits: []const []const u8,
    roster: []const TextRow,
    quotes: []const TextRow,
    attacks: []const Attack,
    ui: []const TextRow,
    script: []const TextRow,
    terrain_code_pages: []const TerrainCodes,
};
pub const XaChannel = struct { index: u8, path: []const u8 };
pub const Xa2 = struct { file: []const u8, format: []const u8, channels: []const XaChannel };
pub const Audio = struct {
    header: []const u8,
    body: []const u8,
    program_count: u16,
    tone_count: u16,
    sample_count: u16,
    tone_table: std.json.Value,
    samples: []const Sample,
    xa2: Xa2,
};
pub const Sample = struct { index: u16, blocks: u32, bytes: u32, sha256: []const u8 };
pub const Resource = struct {
    id: []const u8,
    kind: []const u8,
    data_sha256: []const u8,
    palette_sha256: ?[]const u8,
    provenance: std.json.Value,
};
pub const Manifest = struct {
    schema: []const u8,
    id: []const u8,
    target: []const u8,
    scenarios: []const Scenario,
    audio: Audio,
    resources: []const Resource,
};

pub const MapRole = enum { battlefield, sky };

pub fn load(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Manifest) {
    if (bytes.len > max_json_bytes) return error.WarManifestTooLarge;
    const parsed = try std.json.parseFromSlice(Manifest, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    try validate(parsed.value);
    return parsed;
}

pub fn resource(id: []const u8) !data.Entry {
    for (data.entries) |entry| if (std.mem.eql(u8, entry.id, id)) return entry;
    return error.UnknownWarResource;
}

fn validateHash(bytes: []const u8, expected: []const u8) !void {
    if (expected.len != 64) return error.InvalidWarResourceIdentity;
    var expected_digest: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&expected_digest, expected) catch return error.InvalidWarResourceIdentity;
    var actual_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &actual_digest, .{});
    if (!std.mem.eql(u8, &expected_digest, &actual_digest)) return error.InvalidWarResourceData;
}

fn validate(manifest: Manifest) !void {
    if (!std.mem.eql(u8, manifest.schema, schema) or manifest.scenarios.len != 9) return error.InvalidWarManifest;
    if (manifest.resources.len != data.entries.len) return error.InvalidWarResourceInventory;
    for (manifest.resources, data.entries) |expected, actual| {
        if (!std.mem.eql(u8, expected.id, actual.id) or !std.mem.eql(u8, expected.kind, actual.kind)) return error.InvalidWarResourceInventory;
        if ((expected.palette_sha256 == null) != (actual.palette == null)) return error.InvalidWarResourceInventory;
        try validateHash(actual.data, expected.data_sha256);
        if (expected.palette_sha256) |palette_sha256| try validateHash(actual.palette.?, palette_sha256);
        if (std.mem.eql(u8, actual.kind, "map_page") or std.mem.eql(u8, actual.kind, "sprite_atlas")) {
            if (actual.data.len != 128 * 128 or actual.palette == null or actual.palette.?.len != 512) return error.InvalidWarResourceData;
        } else if (std.mem.eql(u8, actual.kind, "portrait")) {
            if (actual.data.len != 64 * 64 or actual.palette == null or actual.palette.?.len != 512) return error.InvalidWarResourceData;
        } else if (actual.data.len == 0) return error.InvalidWarResourceData;
    }
    for (manifest.scenarios, 0..) |scene, index| {
        if (scene.selector != index or scene.maps.len != 2 or scene.atlases.len != 6 or scene.portraits.len < 111) return error.InvalidWarScenarioContent;
        for (scene.maps) |entry| {
            if (entry.cells.len != entry.width * entry.height or entry.composition.row_stride_cells != entry.width or
                entry.composition.tile_width != 32 or entry.composition.tile_height != 32 or
                entry.composition.source_tile_width != 16 or entry.composition.source_tile_height != 16 or
                entry.composition.page_width != 128 or entry.composition.page_height != 128) return error.InvalidWarMap;
            for (entry.cells) |code| if (code >> 6 >= entry.pages.len) return error.InvalidWarMapReference;
            for (entry.pages) |id| _ = try resource(id);
        }
        for (scene.atlases, 0..) |atlas, atlas_index| {
            _ = try resource(atlas.resource);
            if (atlas_index < 2 and atlas.poses.len == 0) return error.MissingWarUnitPoses;
            for (atlas.poses) |pose| if (pose.width == 0 or pose.height == 0 or pose.frame >= 16) return error.InvalidWarPose;
        }
        for (scene.portraits) |id| _ = try resource(id);
    }
    _ = try resource(manifest.audio.header);
    _ = try resource(manifest.audio.body);
    if (manifest.audio.xa2.channels.len != 3) return error.InvalidWarAudio;
    for (manifest.audio.xa2.channels, 0..) |channel, index| {
        if (channel.index != index) return error.InvalidWarAudio;
        var expected: [32]u8 = undefined;
        const path = std.fmt.bufPrint(&expected, "xa/xa2_ch{d}.wav", .{index}) catch return error.InvalidWarAudio;
        if (!std.mem.eql(u8, channel.path, path)) return error.InvalidWarAudio;
    }
}

pub fn scenario(manifest: Manifest, id: []const u8) !Scenario {
    for (manifest.scenarios) |candidate| if (std.mem.eql(u8, candidate.id, id)) return candidate;
    return error.UnknownWarScenario;
}

pub fn map(scene: Scenario, role: MapRole) !Map {
    for (scene.maps) |entry| {
        const is_sky = entry.width == 16 and entry.height == 12;
        if ((role == .sky) == is_sky) return entry;
    }
    return error.MissingWarMap;
}

pub fn portrait(scene: Scenario, index: u8) !data.Entry {
    if (index >= scene.portraits.len) return error.UnknownWarPortrait;
    return resource(scene.portraits[index]);
}

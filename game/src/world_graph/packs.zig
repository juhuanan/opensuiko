//! World content graph pack summary and dependency counts.

pub const counts = struct {
    pub const nodes: u32 = 2497;
    pub const edges: u32 = 969;
    pub const scenes: u32 = 15;
    pub const mandatory_scenes: u32 = 13;
    pub const requests: u32 = 133;
    pub const blockers: u32 = 535;
    pub const joins: u32 = 27;
    pub const dangling: u32 = 0;
    pub const mandatory_unresolved: u32 = 3;
};

/// Pinned pack digests: a graph that names another version of any package
/// is refused rather than silently joined.
pub const Pack = struct { id: []const u8, version: []const u8, digest: []const u8, rows: u32 };
pub const packs = [_]Pack{
    .{ .id = "production-scenes", .version = "export-scene-population/1", .digest = "d8aed009e273773a83b4702200278b27e55adcafd412d6e28553fb327ef6da89", .rows = 84 },
    .{ .id = "item-shared-ledger", .version = "item-shared-ledger/1", .digest = "1cd7963ff7aa64565bcf38fcdd364892eb5fd955d45fb69f3b57dc8171b5d3c8", .rows = 193 },
    .{ .id = "character-weapons", .version = "character-weapons.1", .digest = "531f0b6569ca4eec377dfa7993c06376aac4f780936bd9d1868f6097e058563d", .rows = 248 },
    .{ .id = "formations-and-enemies", .version = "formations-and-enemies.1", .digest = "10c62387eaf5bd812bfeaaf6a929a14b5d323f8595361d142b722fc3d161307e", .rows = 274 },
    .{ .id = "actor-identities", .version = "actor-identities.1", .digest = "873eb7bf63f22a843dd08891b99d30b0f4ea1b338f618f1595b519ac2a282ae1", .rows = 321 },
    .{ .id = "area-rooms", .version = "area-rooms.1", .digest = "4608ef3e72f2f4196a145532cf06d52b4c4a501c393382044a359dffb476af94", .rows = 1950 },
    .{ .id = "effects-and-scenery", .version = "effects-and-scenery.1", .digest = "3318625c7178196d7d8184908419f58456d86d5626a5bf933688dd09cafb9b38", .rows = 67 },
    .{ .id = "audio-cues", .version = "audio-cues.1", .digest = "67407fa4e5f6f5a2befdad73bf300e0e1cc5e5a00fc8b1982f560f4df1dc49c4", .rows = 291 },
    .{ .id = "room-support", .version = "room-support.1", .digest = "fac4509cfd657aff2f9549ac0c49a4b928c95bcfa386f09f796060b8405b907a", .rows = 28 },
};

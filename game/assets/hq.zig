//! Embedded data and digests for headquarters stages, recruitment, tablet, and optional games.

const std = @import("std");

pub const stage_plan_json = @embedFile("hq/stage_plan.json");

pub const stages = struct {
    pub const stages_json = @embedFile("hq/stages.json");
    pub const ground_json = @embedFile("hq/ground.json");
    pub const Population = struct { id: []const u8, json: []const u8 };
    pub const populations = [_]Population{
        .{ .id = "hq_s0_r000", .json = @embedFile("hq/population/hq_s0_r000.json") },
        .{ .id = "hq_s0_r002", .json = @embedFile("hq/population/hq_s0_r002.json") },
        .{ .id = "hq_s0_r003", .json = @embedFile("hq/population/hq_s0_r003.json") },
        .{ .id = "hq_s1_r000", .json = @embedFile("hq/population/hq_s1_r000.json") },
        .{ .id = "hq_s1_r001", .json = @embedFile("hq/population/hq_s1_r001.json") },
        .{ .id = "hq_s1_r002", .json = @embedFile("hq/population/hq_s1_r002.json") },
        .{ .id = "hq_s1_r003", .json = @embedFile("hq/population/hq_s1_r003.json") },
        .{ .id = "hq_s1_r007", .json = @embedFile("hq/population/hq_s1_r007.json") },
        .{ .id = "hq_s2_r000", .json = @embedFile("hq/population/hq_s2_r000.json") },
        .{ .id = "hq_s2_r001", .json = @embedFile("hq/population/hq_s2_r001.json") },
        .{ .id = "hq_s2_r002", .json = @embedFile("hq/population/hq_s2_r002.json") },
        .{ .id = "hq_s2_r003", .json = @embedFile("hq/population/hq_s2_r003.json") },
        .{ .id = "hq_s2_r007", .json = @embedFile("hq/population/hq_s2_r007.json") },
        .{ .id = "hq_s3_r000", .json = @embedFile("hq/population/hq_s3_r000.json") },
        .{ .id = "hq_s3_r001", .json = @embedFile("hq/population/hq_s3_r001.json") },
        .{ .id = "hq_s3_r002", .json = @embedFile("hq/population/hq_s3_r002.json") },
        .{ .id = "hq_s3_r003", .json = @embedFile("hq/population/hq_s3_r003.json") },
        .{ .id = "hq_s3_r007", .json = @embedFile("hq/population/hq_s3_r007.json") },
        .{ .id = "hq_s4_r000", .json = @embedFile("hq/population/hq_s4_r000.json") },
        .{ .id = "hq_s4_r001", .json = @embedFile("hq/population/hq_s4_r001.json") },
        .{ .id = "hq_s4_r002", .json = @embedFile("hq/population/hq_s4_r002.json") },
        .{ .id = "hq_s4_r003", .json = @embedFile("hq/population/hq_s4_r003.json") },
        .{ .id = "hq_s4_r007", .json = @embedFile("hq/population/hq_s4_r007.json") },
    };
    pub fn populationById(id: []const u8) ?[]const u8 {
        for (populations) |entry| if (std.mem.eql(u8, entry.id, id)) return entry.json;
        return null;
    }
};

pub const recruitment_windows = struct {
    pub const json = @embedFile("hq/recruitment_windows.json");
    pub const asset_sha256 = "8c9a8f380c1578b232f40cac594bb3639f13a5e4ffb25a3f4d0598d695cf6292";
};

pub const roster = struct {
    pub const json = @embedFile("hq/roster.json");
};

pub const service_callers = struct {
    pub const json = @embedFile("hq/service_callers.json");
    pub const sha256 = "7fa3845440a8979633bd885b1eb1c33a7b8d0785249b97d8a3541768ca2192da";
};

pub const tablet = struct {
    pub const tablet_json = @embedFile("hq/tablet.json");
    pub const version = "tablet.1";
    pub const schema = "suikoden-tablet/1";
    pub const tablet_sha256 = "426ffa315923ca2c3b14f47bb632588e9236dac2b97a874be1ae745e1d0388a9";
    pub const tablet_content_sha256 = "708643d1e32fe017c09a724b251ad7f71e4c2f65a409f38806e75432d93be17b";
    pub const stone_sha256 = "d4e4f1af92ad267c4e13395525d28f841c67cfcc99c541f2978ff0ac77ec39ec";
    pub const main_sha256 = "439a166609dab8cde26249bd7661a835e4d55e79bb37a964761c981524e89d95";
    pub const slus_sha256 = "68a41f0228ae1fca8cb8b39f29dfed552f1305a3c86a686917290124e77f131d";
    pub const face_listing_sha256 = "efbc9aae81501eaf214353bbdf05c004d2a3863a890e3a478eb12a1c9e0e6a4d";
    pub const portrait_review = "not_assessed";
};

pub const optional_games = struct {
    pub const json = @embedFile("hq/optional_games.json");
    pub const rules_json = @embedFile("optional_game_contracts.json");
    pub const sha256_hex = "48e3b6775f4c93741451c78b467cd28984c243c0384bdab6e081ef4028fcb4f3";
};

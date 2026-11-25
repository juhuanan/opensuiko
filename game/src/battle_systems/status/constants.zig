//! Battle status bitmasks, interaction flags, and rune constants.

pub const schema = "suikoden-battle-status-data/1";
pub const main_body_sha256 = "e123263c3046a7283d8ca26598185672ed3f8de72d97f5efb0ee8e88ccaa55fa";
pub const b_data_sha256 = "b47b1bdf54091143387b41bbd1db08a47490fc2d0f2be9428184b1db9fc1e64e";
pub const interactions_sha256 = "479f239e57f6e7f340a1196cf41dc29ce2ad601a8865de244631f4fa9635ef4d";
pub const status_masks = [9]u16{ 1, 2, 4, 8, 16, 32, 128, 64, 32768 };
pub const status_names = [9][]const u8{ "poison", "balloon_one", "balloon_two", "balloon_three", "accuracy_reduced", "sleep", "rune_blocked", "recovery", "protection" };
pub const known_feature_mask: u16 = 0xC02F;
pub const interaction_feature_mask: u16 = 0x800F;
pub const feature_counter_eligible: u16 = 0x0001;
pub const feature_parry: u16 = 0x0002;
pub const feature_dodge: u16 = 0x0004;
pub const feature_ordinary_landing: u16 = 0x0008;
pub const feature_forced_hit: u16 = 0x8000;
pub const movement_feature: u16 = 0x0020;
pub const death_feature: u16 = 0x4000;
pub const killer_rune: u8 = 0x0F;
pub const counter_rune: u8 = 0x10;
pub const hazy_rune: u8 = 0x12;
pub const turtle_rune: u8 = 0x19;
pub const accuracy_base: i32 = 80;
pub const accuracy_min: i32 = 60;
pub const accuracy_max: i32 = 99;
pub const critical_divisor: u32 = 8;
pub const critical_min: u32 = 3;
pub const critical_max: u32 = 25;
pub const critical_damage_multiplier: u32 = 3;
pub const protection_hp_divisor: u16 = 4;
pub const common_hurt_duration: u16 = 46;
pub const ward_return_duration: u16 = 10;
pub const copper_counter: u8 = 2;
pub const copper_boundaries: u8 = 3;
pub const sleep_wake_percent: u8 = 50;
pub const poison_divisor: u16 = 20;
pub const general_cure_top_class: u8 = 6;
pub const battle_exit_keep_mask: u16 = 0x000F;
pub const Pair = struct { ward: u8, protector: u8 };
pub const protection_pairs = [_]Pair{
    .{ .ward = 8, .protector = 2 },
    .{ .ward = 8, .protector = 6 },
    .{ .ward = 8, .protector = 1 },
    .{ .ward = 1, .protector = 6 },
    .{ .ward = 2, .protector = 3 },
    .{ .ward = 32, .protector = 38 },
    .{ .ward = 38, .protector = 32 },
    .{ .ward = 33, .protector = 63 },
    .{ .ward = 9, .protector = 4 },
    .{ .ward = 0, .protector = 30 },
    .{ .ward = 30, .protector = 0 },
    .{ .ward = 62, .protector = 0 },
    .{ .ward = 8, .protector = 23 },
    .{ .ward = 32, .protector = 45 },
    .{ .ward = 14, .protector = 80 },
};
pub const pair_count = 15;

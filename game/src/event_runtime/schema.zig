//! Event IR schema version registry and numeric comparison helpers.
const std = @import("std");

pub const prefix = "suikoden-event-ir/";
pub const current_version: u8 = 29;

pub const schema = prefix ++ "1";
pub const campaign_schema = prefix ++ "2";
pub const scene_schema = prefix ++ "3";
pub const motion_schema = prefix ++ "4";
pub const hop_schema = prefix ++ "5";
pub const party_track_schema = prefix ++ "6";
pub const party_scene_schema = prefix ++ "7";
pub const position_schema = prefix ++ "8";
pub const fixed_box_schema = prefix ++ "9";
pub const character_schema = prefix ++ "10";
pub const music_schema = prefix ++ "11";
pub const queued_music_schema = prefix ++ "12";
pub const entry_music_schema = prefix ++ "13";
pub const field_effect_schema = prefix ++ "14";
pub const party_select_schema = prefix ++ "15";
pub const scene_actor_schema = prefix ++ "16";
pub const fade_in_schema = prefix ++ "17";
pub const prop_schema = prefix ++ "18";
pub const mansion_music_schema = prefix ++ "19";
pub const party_experience_schema = prefix ++ "20";
pub const wheel_music_schema = prefix ++ "21";
pub const wheel_motion_schema = prefix ++ "22";
pub const item_overload_schema = prefix ++ "23";
pub const hero_visibility_schema = prefix ++ "24";
pub const branch_history_schema = prefix ++ "25";
pub const world_entry_schema = prefix ++ "26";
pub const actor_owners_schema = prefix ++ "27";
pub const camera_push_schema = prefix ++ "28";
pub const scenery_mutation_schema = prefix ++ "29";

pub const state_schema = "suikoden-event-state/1";
pub const branch_state_schema = "suikoden-event-state/2";

pub fn parseVersion(value: []const u8) ?u8 {
    if (!std.mem.startsWith(u8, value, prefix)) return null;
    const digits = value[prefix.len..];
    if (digits.len == 0 or digits.len > 2 or digits[0] == '0') return null;
    for (digits) |byte| if (!std.ascii.isDigit(byte)) return null;
    const version = std.fmt.parseInt(u8, digits, 10) catch return null;
    if (version == 0 or version > current_version) return null;
    return version;
}

pub fn isKnown(value: []const u8) bool {
    return parseVersion(value) != null;
}

pub fn isCampaignNamespace(value: []const u8) bool {
    return atLeast(value, 2);
}

pub fn atLeast(value: []const u8, min_version: u8) bool {
    const version = parseVersion(value) orelse return false;
    return version >= min_version;
}

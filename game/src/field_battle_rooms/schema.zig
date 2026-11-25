//! Battle field event package schema version registry and numeric comparison helpers.
const std = @import("std");

pub const prefix = "suikoden-battle-field-events/";
pub const current_schema = "suikoden-battle-field-events";
pub const max_numbered_version: u8 = 52;
pub const current_version: u8 = 53;

pub const legacy_schema = prefix ++ "1";
pub const dialogue_schema = prefix ++ "2";
pub const motion_schema = prefix ++ "3";
pub const portrait_schema = prefix ++ "4";
pub const choice_schema = prefix ++ "5";
pub const scene_schema = prefix ++ "6";
pub const party_edit_schema = prefix ++ "7";
pub const multi_exit_schema = prefix ++ "8";
pub const escape_branch_schema = prefix ++ "9";
pub const defeat_branch_schema = prefix ++ "10";
pub const party_leave_schema = prefix ++ "11";
pub const sound_schema = prefix ++ "12";
pub const opening_route_schema = prefix ++ "13";
pub const shared_items_schema = prefix ++ "14";
pub const fade_schema = prefix ++ "15";
pub const game_over_schema = prefix ++ "16";
pub const room_flags_schema = prefix ++ "17";
pub const schema = prefix ++ "18";
pub const campaign_schema = prefix ++ "19";
pub const rune_progression_schema = prefix ++ "20";
pub const recruit_loading_schema = prefix ++ "21";
pub const dice_schema = prefix ++ "22";
pub const party_queue_schema = prefix ++ "23";
pub const party_art_schema = prefix ++ "24";
pub const actor_clips_schema = prefix ++ "25";
pub const music_schema = prefix ++ "26";
pub const queued_music_schema = prefix ++ "27";
pub const entry_music_schema = prefix ++ "28";
pub const field_effect_schema = prefix ++ "29";
pub const party_dismiss_schema = prefix ++ "30";
pub const auxiliary_party_schema = prefix ++ "31";
pub const entry_placement_schema = prefix ++ "32";
pub const founding_scene_schema = prefix ++ "33";
pub const founding_audio_schema = prefix ++ "34";
pub const party_graphics_schema = prefix ++ "35";
pub const effect_render_schema = prefix ++ "36";
pub const party_select_schema = prefix ++ "37";
pub const scene_actor_schema = prefix ++ "38";
pub const fade_in_schema = prefix ++ "39";
pub const prop_schema = prefix ++ "40";
pub const mansion_music_schema = prefix ++ "41";
pub const party_library_schema = prefix ++ "42";
pub const party_experience_schema = prefix ++ "43";
pub const wheel_music_schema = prefix ++ "44";
pub const wheel_motion_schema = prefix ++ "45";
pub const item_overload_schema = prefix ++ "46";
pub const hero_visibility_schema = prefix ++ "47";
pub const branch_history_schema = prefix ++ "48";
pub const world_entry_schema = prefix ++ "49";
pub const actor_owners_schema = prefix ++ "50";
pub const camera_push_schema = prefix ++ "51";
pub const scenery_mutation_schema = prefix ++ "52";

pub fn parseVersion(value: []const u8) ?u8 {
    if (std.mem.eql(u8, value, current_schema)) return current_version;
    if (!std.mem.startsWith(u8, value, prefix)) return null;
    const digits = value[prefix.len..];
    if (digits.len == 0 or digits.len > 2 or digits[0] == '0') return null;
    for (digits) |byte| if (!std.ascii.isDigit(byte)) return null;
    const version = std.fmt.parseInt(u8, digits, 10) catch return null;
    if (version == 0 or version > max_numbered_version) return null;
    return version;
}

pub fn atLeast(value: []const u8, min_version: u8) bool {
    const version = parseVersion(value) orelse return false;
    return version >= min_version;
}

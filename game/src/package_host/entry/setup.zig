//! Canonical Setup screen model.
//!
//! The source Setup screen is a 32-state driver (`MAIN:0x800D06C0`) reached
//! from the root menu handler `MAIN:0x800D0498`; it reads the settings list at
//! `MAIN:0x800D17EC` through the shared drawer's group 15.  That group is
//! exactly `{Message speed, Fast, Normal, Slow, Window setup, Transparent,
//! Opaque, Sound setup, Stereo, Mono}` (registry `extract_menu2.jsonl` row 2,
//! `archive/docs/menu_flow.md`).  The three groups and their choices below are
//! therefore source strings, not invented labels.
//!
//! What is *not* derived is the initial stored value of each group.  This
//! module never invents one: an option starts `unset` (rendered as such) until
//! the player or a caller supplies a choice.  Setup state is a separate store
//! from campaign saves, and the prototype volume/fullscreen/vsync object
//! (`suikoden-settings/1`) is explicitly refused as a canonical profile.
const std = @import("std");

pub const schema = "suikoden-canonical-settings/1";
pub const prototype_schema = "suikoden-settings/1";

pub const GroupId = enum(u8) { message_speed = 0, window_setup = 1, sound_setup = 2 };
pub const group_count = 3;

pub const Group = struct {
    id: GroupId,
    label: []const u8,
    choices: []const []const u8,
};

pub const groups = [group_count]Group{
    .{ .id = .message_speed, .label = "Message speed", .choices = &.{ "Fast", "Normal", "Slow" } },
    .{ .id = .window_setup, .label = "Window setup", .choices = &.{ "Transparent", "Opaque" } },
    .{ .id = .sound_setup, .label = "Sound setup", .choices = &.{ "Stereo", "Mono" } },
};

pub fn groupAt(index: usize) *const Group {
    return &groups[index];
}

pub fn choiceText(id: GroupId, index: u8) []const u8 {
    return groups[@backingInt(id)].choices[index];
}

pub const Profile = struct {
    schema: []const u8 = schema,
    message_speed: ?u8 = null,
    window_setup: ?u8 = null,
    sound_setup: ?u8 = null,

    pub fn get(self: Profile, id: GroupId) ?u8 {
        return switch (id) {
            .message_speed => self.message_speed,
            .window_setup => self.window_setup,
            .sound_setup => self.sound_setup,
        };
    }

    pub fn set(self: *Profile, id: GroupId, index: ?u8) !void {
        switch (id) {
            .message_speed => self.message_speed = index,
            .window_setup => self.window_setup = index,
            .sound_setup => self.sound_setup = index,
        }
        try self.validate();
    }

    /// Steps one group's choice.  `forward` moves to the next choice and wraps;
    /// an unset group selects its first choice forward and its last choice
    /// backward.  The cursor never lands on an implicit default value.
    pub fn step(self: *Profile, id: GroupId, forward: bool) void {
        const options = groups[@backingInt(id)].choices;
        const count = options.len;
        const next: u8 = if (self.get(id)) |index| block: {
            const at = @as(usize, index);
            break :block @intCast(if (forward) (at + 1) % count else (at + count - 1) % count);
        } else if (forward) 0 else @intCast(count - 1);
        self.set(id, next) catch unreachable;
    }

    pub fn validate(self: Profile) !void {
        if (!std.mem.eql(u8, self.schema, schema)) return error.UnsupportedSettings;
        if (self.message_speed) |index| if (@as(usize, index) >= groups[0].choices.len) return error.InvalidSetting;
        if (self.window_setup) |index| if (@as(usize, index) >= groups[1].choices.len) return error.InvalidSetting;
        if (self.sound_setup) |index| if (@as(usize, index) >= groups[2].choices.len) return error.InvalidSetting;
    }

    pub fn complete(self: Profile) bool {
        return self.message_speed != null and self.window_setup != null and self.sound_setup != null;
    }

    pub fn eql(self: Profile, other: Profile) bool {
        return self.message_speed == other.message_speed and
            self.window_setup == other.window_setup and
            self.sound_setup == other.sound_setup;
    }
};

const Wire = struct {
    schema: []const u8,
    message_speed: ?u8,
    window_setup: ?u8,
    sound_setup: ?u8,
};

pub fn encode(allocator: std.mem.Allocator, profile: Profile) ![]u8 {
    try profile.validate();
    return std.json.Stringify.valueAlloc(allocator, profile, .{ .whitespace = .indent_2 });
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Profile {
    if (bytes.len > 4096) return error.SettingsTooLarge;
    const version = try std.json.parseFromSlice(struct { schema: []const u8 }, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer version.deinit();
    if (std.mem.eql(u8, version.value.schema, prototype_schema)) return error.PrototypeSettingsNotCanonical;
    if (!std.mem.eql(u8, version.value.schema, schema)) return error.UnsupportedSettings;
    const parsed = try std.json.parseFromSlice(Wire, allocator, bytes, .{});
    defer parsed.deinit();
    var profile = Profile{ .message_speed = parsed.value.message_speed, .window_setup = parsed.value.window_setup, .sound_setup = parsed.value.sound_setup };
    try profile.validate();
    return profile;
}

test "canonical profile round trip keeps unset groups unset" {
    const allocator = std.testing.allocator;
    var profile = Profile{};
    profile.set(.message_speed, 1) catch unreachable;
    profile.set(.sound_setup, 0) catch unreachable;
    const bytes = try encode(allocator, profile);
    defer allocator.free(bytes);
    const decoded = try decode(allocator, bytes);
    try std.testing.expect(decoded.eql(profile));
    try std.testing.expect(decoded.message_speed == 1 and decoded.window_setup == null);
    try std.testing.expect(!decoded.complete());
}

test "the prototype settings object is not a canonical profile" {
    const allocator = std.testing.allocator;
    const prototype =
        \\{"schema":"suikoden-settings/1","music":8,"effects":8,"fullscreen":false,"vsync":true}
    ;
    try std.testing.expectError(error.PrototypeSettingsNotCanonical, decode(allocator, prototype));
    const unknown =
        \\{"schema":"suikoden-canonical-settings/1","message_speed":0,"window_setup":1,"sound_setup":0,"music":3}
    ;
    try std.testing.expectError(error.UnknownField, decode(allocator, unknown));
}

test "stepping never lands on an invented default" {
    var profile = Profile{};
    profile.step(.window_setup, true);
    try std.testing.expectEqual(@as(?u8, 0), profile.window_setup);
    profile.step(.window_setup, false);
    try std.testing.expectEqual(@as(?u8, 1), profile.window_setup);
    profile.step(.window_setup, true);
    try std.testing.expectEqual(@as(?u8, 0), profile.window_setup);
    try std.testing.expectEqualStrings("Transparent", choiceText(.window_setup, 0));
}

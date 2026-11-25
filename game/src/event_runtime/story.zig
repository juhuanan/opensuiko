//! Scenario flags, story state, window/sound presentation settings, and facility enums.
const std = @import("std");
const runtime = @import("../event_runtime.zig");

pub const FieldEffect = enum { appearance, disappearance };
pub const FieldMusic = enum { stop, fade, area_b, ruins, lakeshore, headquarters, founding, infiltration, mansion, wheel };
pub const FieldService = enum { shop, blacksmith, rune_master, appraisal, save_point, storage, cup_game, card_game, teleport, bathhouse, tablet, library, window_styles, sound_themes, music_player };
pub const SoundTheme = enum { standard, chime, reed, pulse, pluck };

pub const WindowAppearance = struct {
    pub const Style = enum { classic, rounded, double, corners, inset };
    pub const Color = enum { blue, slate, forest, teal, plum, burgundy, bronze, graphite };

    style: Style = .classic,
    color: Color = .blue,

    pub fn isDefault(self: WindowAppearance) bool {
        return self.style == .classic and self.color == .blue;
    }
};

pub const Flag = struct {
    id: []const u8,
    mask: u8,

    pub fn scenarioIndex(self: Flag) ?u8 {
        const index = parseScenarioId(self.id) orelse return null;
        if (index >= @typeInfo(@FieldType(StoryState, "scenario")).array.len or self.mask == 0) return null;
        for (self.id[9..]) |digit| if (!std.ascii.isDigit(digit)) return null;
        return index;
    }
};

pub const StoryWrite = struct { flag: Flag, clear: bool = false };
pub const Condition = struct { kind: enum { story_mask_set, story_mask_clear }, flag: Flag };
pub const StoryValue = struct {
    id: []const u8,
    storage: enum { scenario },
    byte_index: u8,
    initial: u8,
};

pub const StoryState = struct {
    schema: []const u8 = "suikoden-event-story/1",
    scenario: [240]u8 = @splat(0),
    recruit_flags: [108]u8 = @splat(0),
    castle_tier: u8 = 0,
    world_mode: u8 = 0,
    soul_eater_spell_slots: u8 = 1,
    library_books: u8 = 0,
    window_appearance: WindowAppearance = .{},
    sound_theme: SoundTheme = .standard,
    save_counter: u32 = 0,

    pub fn hasWindowStyle(self: StoryState, style: WindowAppearance.Style) bool {
        const index = @backingInt(style);
        return index == 0 or self.scenario[36] & (@as(u8, 1) << @as(u3, @intCast(index - 1))) != 0;
    }

    pub fn hasSoundTheme(self: StoryState, theme: SoundTheme) bool {
        const index = @backingInt(theme);
        return index == 0 or self.scenario[36] & (@as(u8, 1) << @as(u3, @intCast(@as(u8, index) + 3))) != 0;
    }

    pub fn jsonStringify(self: StoryState, writer: anytype) !void {
        try writer.beginObject();
        try writer.objectField("schema");
        try writer.write(self.schema);
        try writer.objectField("scenario");
        try writer.write(self.scenario);
        if (!std.mem.allEqual(u8, &self.recruit_flags, 0)) {
            try writer.objectField("recruit_flags");
            try writer.write(self.recruit_flags);
        }
        if (self.castle_tier != 0) {
            try writer.objectField("castle_tier");
            try writer.write(self.castle_tier);
        }
        if (self.world_mode != 0) {
            try writer.objectField("world_mode");
            try writer.write(self.world_mode);
        }
        if (self.soul_eater_spell_slots != 1) {
            try writer.objectField("soul_eater_spell_slots");
            try writer.write(self.soul_eater_spell_slots);
        }
        if (self.library_books != 0) {
            try writer.objectField("library_books");
            try writer.write(self.library_books);
        }
        if (!self.window_appearance.isDefault()) {
            try writer.objectField("window_appearance");
            try writer.write(self.window_appearance);
        }
        if (self.sound_theme != .standard) {
            try writer.objectField("sound_theme");
            try writer.write(self.sound_theme);
        }
        if (self.save_counter != 0) {
            try writer.objectField("save_counter");
            try writer.write(self.save_counter);
        }
        try writer.endObject();
    }

    pub fn advanceSaveCounter(self: *StoryState, elapsed: u32) void {
        self.save_counter +%= elapsed;
    }

    pub fn recruitCount(self: *const StoryState) u8 {
        var count: u8 = 0;
        for (self.recruit_flags) |b| if ((b & 1) != 0 and (b & 2) == 0) {
            count += 1;
        };
        return count;
    }

    pub fn markCharacterLoaded(self: *StoryState, id: u8) void {
        if (id >= self.recruit_flags.len) return;
        self.recruit_flags[id] |= 1;
        self.refreshCastleTier();
    }

    fn refreshCastleTier(self: *StoryState) void {
        var total: u8 = 0;
        for (self.recruit_flags) |flags| if (flags & 3 != 0) {
            total += 1;
        };
        switch (self.castle_tier) {
            1 => if (total >= 25 and self.scenario[15] & 2 != 0) {
                self.castle_tier = 2;
            },
            2 => if (total >= 45) {
                self.castle_tier = 3;
            },
            3 => if (total >= 90) {
                self.castle_tier = 4;
            },
            else => {},
        }
    }

    pub fn toggleRecruit(self: *StoryState, slot: u8, toggle_only: bool) void {
        if (slot >= self.recruit_flags.len) return;
        if (toggle_only) {
            self.recruit_flags[slot] ^= 1;
        } else {
            if ((self.recruit_flags[slot] & 2) != 0) self.recruit_flags[slot] = 0;
            self.recruit_flags[slot] |= 1;
            self.refreshCastleTier();
        }
    }

    pub fn init(contents: []const runtime.Content) !StoryState {
        var result: StoryState = .{};
        for (contents) |content| {
            try content.validate();
            for (content.story_values) |entry| {
                const current = result.scenario[entry.byte_index];
                if (current != 0 and current != entry.initial) return error.ConflictingStoryInitialValue;
                result.scenario[entry.byte_index] = entry.initial;
            }
        }
        return result;
    }

    pub fn matches(self: *const StoryState, conditions: []const Condition) bool {
        for (conditions) |entry| {
            const index = parseScenarioId(entry.flag.id) orelse return false;
            if (index >= self.scenario.len or entry.flag.mask == 0) return false;
            const present = self.scenario[index] & entry.flag.mask != 0;
            if (present != (entry.kind == .story_mask_set)) return false;
        }
        return true;
    }

    pub fn apply(self: *StoryState, value: Flag) !void {
        const index = parseScenarioId(value.id) orelse return error.UnknownStoryValue;
        if (index >= self.scenario.len or value.mask == 0) return error.UnknownStoryValue;
        self.scenario[index] |= value.mask;
    }

    pub fn clear(self: *StoryState, value: Flag) !void {
        const index = parseScenarioId(value.id) orelse return error.UnknownStoryValue;
        if (index >= self.scenario.len or value.mask == 0) return error.UnknownStoryValue;
        self.scenario[index] &= ~value.mask;
    }

    pub fn advanceSequence(self: *StoryState, flag: Flag, pattern: u8, input: u8) !void {
        const index = flag.scenarioIndex() orelse return error.UnknownStoryValue;
        const progress = self.scenario[index];
        if (progress == 255) return;
        const step_index: u3 = @intCast(@popCount(progress));
        const expected = (pattern >> step_index) & 1;
        // A valid partial sequence has a contiguous run of low bits set.
        const next_bit = progress + 1;
        self.scenario[index] = if (progress & next_bit == 0 and input == expected) progress | next_bit else 0;
    }
};

pub fn parseScenarioId(id: []const u8) ?u8 {
    if (id.len != 13 or !std.mem.startsWith(u8, id, "scenario_")) return null;
    return std.fmt.parseInt(u8, id[9..], 10) catch null;
}

//! Atlas clips sampled on the duel engine's update clock.
const std = @import("std");
const field = @import("field");
const duel = @import("journey").duel;

pub const path = "duel/presentation.json";
pub const atlas_path = "duel/atlas.png";
pub const extracted_origin = "disc-extracted-duel-art/1";
pub const width = 616;
pub const height = 154;

pub const Frame = struct {
    rect: field.Rect,
    ticks: u16,
    x: i32,
    y: i32,
    mirror: bool = false,
    flash: bool = false,
    visible: bool = true,
};

const Clip = []const Frame;

pub const Exchange = struct {
    id: []const u8,
    clips: [2]Clip,
};

pub const Scene = struct {
    id: []const u8,
    backdrop: ?field.Rect = null,
    gauges: ?[2]field.Rect = null,
    idle: [2]Clip,
    defeat: [2]Clip,
    exchanges: []const Exchange,

    fn exchange(self: Scene, id: []const u8) ?Exchange {
        for (self.exchanges) |entry| if (std.mem.eql(u8, entry.id, id)) return entry;
        return null;
    }

    pub fn frame(self: Scene, state: duel.State, side: duel.Side, elapsed: u64) Frame {
        const index = @backingInt(side);
        if (state.phase == .defeat_animation or state.phase == .finished) {
            if (state.loser == side) {
                const duration = state.duel.fighters[index].defeat_updates;
                return sample(self.defeat[index], duration -| state.timer);
            }
        } else if (state.current_exchange) |current| {
            return sample(self.exchange(current.id).?.clips[index], state.exchange_tick -| 1);
        }
        return sample(self.idle[index], elapsed % clipTicks(self.idle[index]));
    }
};

pub const Packet = struct {
    schema: []const u8,
    atlas_sha256: []const u8,
    scenes: []const Scene,
    art_origin: ?[]const u8 = null,

    pub fn scene(self: Packet, id: []const u8) ?Scene {
        for (self.scenes) |entry| if (std.mem.eql(u8, entry.id, id)) return entry;
        return null;
    }

    pub fn validate(self: Packet, rules: duel.Content) !void {
        const origin = self.art_origin orelse return error.UnverifiedDuelArt;
        if (std.mem.eql(u8, origin, "authored-duel-art/1")) return error.AuthoredDuelPreview;
        if (!std.mem.eql(u8, origin, extracted_origin)) return error.UnverifiedDuelArt;
        if (!std.mem.eql(u8, self.schema, "suikoden-duel-presentation/1") or self.scenes.len != rules.duels.len)
            return error.InvalidDuelPresentation;
        if (self.atlas_sha256.len != 64) return error.InvalidDuelPresentation;
        for (self.atlas_sha256) |digit| {
            if (!std.ascii.isDigit(digit) and (digit < 'a' or digit > 'f')) return error.InvalidDuelPresentation;
        }
        for (rules.duels) |match| {
            const art = self.scene(match.id) orelse return error.InvalidDuelPresentation;
            if (art.exchanges.len != match.exchanges.len) return error.InvalidDuelPresentation;
            for (art.idle, art.defeat, match.fighters) |idle, defeat, fighter| {
                try validateClip(idle, null);
                try validateClip(defeat, fighter.defeat_updates);
            }
            for (match.exchanges) |script| {
                const paired = art.exchange(script.id) orelse return error.InvalidDuelPresentation;
                for (paired.clips) |clip| try validateClip(clip, script.updates);
            }
        }
    }

    pub fn validateAtlas(self: Packet, atlas_width: i32, atlas_height: i32) !void {
        for (self.scenes) |entry| {
            if (entry.backdrop) |background| if (!fits(background, atlas_width, atlas_height)) return error.InvalidDuelAtlas;
            if (entry.gauges) |gauges| for (gauges) |gauge| {
                if (gauge.w != 128 or gauge.h != 32 or !fits(gauge, atlas_width, atlas_height)) return error.InvalidDuelAtlas;
            };
            for (entry.idle ++ entry.defeat) |clip| {
                try validateClipAtlas(clip, atlas_width, atlas_height);
            }
            for (entry.exchanges) |paired| for (paired.clips) |clip| {
                try validateClipAtlas(clip, atlas_width, atlas_height);
            };
        }
    }
};

fn validateClip(clip: Clip, duration: ?u32) !void {
    if (clip.len == 0 or clip.len > 4096) return error.InvalidDuelClip;
    for (clip) |frame_value| {
        if (frame_value.ticks == 0 or
            !fits(.{ .x = frame_value.x, .y = frame_value.y, .w = frame_value.rect.w, .h = frame_value.rect.h }, width, height))
            return error.InvalidDuelClip;
    }
    if (duration) |ticks| if (clipTicks(clip) != ticks) return error.InvalidDuelClip;
}

fn validateClipAtlas(clip: Clip, atlas_width: i32, atlas_height: i32) !void {
    for (clip) |frame_value| {
        if (!fits(frame_value.rect, atlas_width, atlas_height)) return error.InvalidDuelAtlas;
    }
}

fn fits(rect: field.Rect, w: i32, h: i32) bool {
    return rect.x >= 0 and rect.y >= 0 and rect.w > 0 and rect.h > 0 and
        rect.w <= w and rect.h <= h and rect.x <= w - rect.w and rect.y <= h - rect.h;
}

fn clipTicks(clip: Clip) u64 {
    var ticks: u64 = 0;
    for (clip) |value| ticks += value.ticks;
    return ticks;
}

fn sample(clip: Clip, tick: u64) Frame {
    var left = tick;
    for (clip) |value| {
        if (left < value.ticks) return value;
        left -= value.ticks;
    }
    return clip[clip.len - 1];
}

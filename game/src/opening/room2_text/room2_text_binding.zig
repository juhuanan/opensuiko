//! Authenticated inputs for the bounded room2 entity2 code108 text path.
//! Loaded-character fallback is unconsulted: the pinned custom record wins.
const std = @import("std");
const slots = @import("native_slots.zig");
const motion = @import("opening_audience");
const room = @import("room2_text.zig");
const destination_data = @import("opening_assets").destination;

const Packet = struct {
    va1_source: struct { sha256: []const u8 },
    constructor: struct {
        va1_room2: struct {
            section: u32,
            dialogue: struct { texts: []const motion.Text },
        },
    },
};

// Typed encoding v1: domain bytes, LE u32 item count, then token tag
// (glyph=0,newline=1,page=2,pace=3,countdown=4,player_name=5).
// Glyphs carry LE u32 UTF-8 byte length and bytes; pace/countdown carry u8.
// Custom resources encode LE u32 count then code:u8,id:LE u32,available:u8.
// Name encodes code:u8, LE u32 text-byte length/text, LE u32 glyph count/ends.
const Hash = std.crypto.hash.sha2.Sha256;
fn putCount(hash: *Hash, value: usize) !void {
    const count = std.math.cast(u32, value) orelse return error.InvalidRoom2Packet;
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, count, .little);
    hash.update(&bytes);
}
fn matches(hash: *Hash, expected: []const u8) bool {
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.mem.eql(u8, &std.fmt.bytesToHex(digest, .lower), expected);
}
fn checkText(text: motion.Text, expected: []const u8) !void {
    var hash = Hash.init(.{});
    hash.update("R2TEXT\x01");
    try putCount(&hash, text.tokens.len);
    for (text.tokens) |token| {
        hash.update(&.{@backingInt(token.kind)});
        switch (token.kind) {
            .glyph => {
                const value = token.text orelse return error.InvalidRoom2Packet;
                if (token.value != null) return error.InvalidRoom2Packet;
                try putCount(&hash, value.len);
                hash.update(value);
            },
            .pace, .countdown => {
                if (token.text != null or token.value == null) return error.InvalidRoom2Packet;
                hash.update(&.{token.value.?});
            },
            else => if (token.text != null or token.value != null) return error.InvalidRoom2Packet,
        }
    }
    if (!matches(&hash, expected)) return error.InvalidRoom2Packet;
}
fn checkCustom(resources: []const slots.Resource) !void {
    var hash = Hash.init(.{});
    hash.update("R2CUSTOM\x01");
    try putCount(&hash, resources.len);
    for (resources) |resource| {
        hash.update(&.{resource.code});
        var id: [4]u8 = undefined;
        std.mem.writeInt(u32, &id, resource.id, .little);
        hash.update(&id);
        hash.update(&.{@intFromBool(resource.available)});
    }
    if (!matches(&hash, "d97414162cb8749351342519312988585b9f2876db797f2eb57e7c066481e8cc")) return error.InvalidRoom2CustomImage;
}
fn checkName(name: slots.Name) !void {
    var hash = Hash.init(.{});
    hash.update("R2NAME\x01");
    hash.update(&.{name.code});
    try putCount(&hash, name.text.len);
    hash.update(name.text);
    try putCount(&hash, name.glyph_ends.len);
    hash.update(name.glyph_ends);
    if (!matches(&hash, "b073c87ee3356f7e5223dfcafe092a748a1e8f00c82ffa751724e20b013c5e99")) return error.InvalidRoom2Packet;
}

pub const Opened = struct {
    native: std.json.Parsed(slots.Asset),
    packet: std.json.Parsed(Packet),
    body_identity: [32]u8,

    pub fn deinit(self: *Opened) void {
        self.packet.deinit();
        self.native.deinit();
    }

    /// Result slices borrow this Opened and the caller's Hero name. Keep both
    /// alive and immutable through each pass, validation, and checkpoint rebind.
    pub fn bind(self: *const Opened, hero_name: []const u8, text_speed: u8, generation: u64) !room.Binding {
        if (text_speed > 2) return error.InvalidRoom2TextSpeed;
        if (!std.mem.eql(u8, &std.fmt.bytesToHex(self.body_identity, .lower), destination_data.asset_sha256)) return error.InvalidRoom2PacketDigest;
        const packet_room = self.packet.value.constructor.va1_room2;
        const texts = packet_room.dialogue.texts;
        if (!std.mem.eql(u8, self.packet.value.va1_source.sha256, "dcca6119f28f3863250f31be8cd164d4795eaa493aeec5b51ca0737690979fed") or
            packet_room.section != 28528 or texts.len != 2 or
            !std.mem.eql(u8, texts[0].id, "va1_r02_text_5") or !std.mem.eql(u8, texts[1].id, "va1_r02_text_47")) return error.InvalidRoom2Packet;
        try checkText(texts[0], "bcbe39e8034dabee9b753fdd820403220dba4e9852858ae5a60a31a246fd6b30");
        try checkText(texts[1], "e2218e5359347f09d1faad70c6fb49e2ba82bdd7bcefa51aca0a10fc28db5b76");
        if (self.native.value.rooms.len != 2) return error.InvalidRoom2Packet;
        const section = for (self.native.value.rooms) |item| {
            if (item.room == 2) break item.section;
        } else return error.InvalidRoom2Packet;
        if (section != 3) return error.InvalidRoom2Packet;
        const source_room = try self.native.value.context(2, generation, &.{});
        try checkCustom(source_room.custom_images);
        const ted = for (source_room.names) |item| {
            if (item.code == 108) break item;
        } else return error.InvalidRoom2Packet;
        try checkName(ted);
        const selected = for (source_room.custom_images) |resource| {
            if (resource.code == 108 and resource.available) break resource;
        } else return error.MissingRoom2CustomImage;
        if (selected.id != 513) return error.InvalidRoom2CustomImage;
        return .{ .context = source_room, .body_identity = self.body_identity, .body5 = texts[0], .body47 = texts[1], .text_speed = text_speed, .player_name = hero_name };
    }
};

/// Both byte slices are independently authenticated before parsing. This
/// constructor admits only the code108 custom-image path, with no fallback.
pub fn open(allocator: std.mem.Allocator, native_bytes: []const u8, packet_bytes: []const u8) !Opened {
    var native = try slots.load(allocator, native_bytes);
    errdefer native.deinit();
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(packet_bytes, &digest, .{});
    if (!std.mem.eql(u8, &std.fmt.bytesToHex(digest, .lower), destination_data.asset_sha256)) return error.InvalidRoom2PacketDigest;
    const packet = try std.json.parseFromSlice(Packet, allocator, packet_bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    errdefer packet.deinit();
    const room2 = packet.value.constructor.va1_room2;
    if (!std.mem.eql(u8, packet.value.va1_source.sha256, "dcca6119f28f3863250f31be8cd164d4795eaa493aeec5b51ca0737690979fed") or
        room2.section != 28528 or room2.dialogue.texts.len != 2 or
        !std.mem.eql(u8, room2.dialogue.texts[0].id, "va1_r02_text_5") or
        !std.mem.eql(u8, room2.dialogue.texts[1].id, "va1_r02_text_47") or
        room2.dialogue.texts[0].tokens.len != 160 or room2.dialogue.texts[1].tokens.len != 20) return error.InvalidRoom2Packet;
    const section = for (native.value.rooms) |item| {
        if (item.room == 2) break item.section;
    } else return error.InvalidRoom2Packet;
    if (section != 3) return error.InvalidRoom2Packet;
    const selected = try native.value.context(2, 0, &.{});
    const custom = for (selected.custom_images) |resource| {
        if (resource.code == 108 and resource.available) break resource;
    } else return error.MissingRoom2CustomImage;
    if (custom.id != 513) return error.InvalidRoom2CustomImage;
    const opened: Opened = .{ .native = native, .packet = packet, .body_identity = digest };
    _ = try opened.bind("", 0, 0);
    return opened;
}

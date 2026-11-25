//! Module surface for the host.
//!
//! The package keeps its pipeline, text engine and scene host in this namespace
//! so the shared queued text/box/name/image handlers can adopt them through one
//! import. The generated packet is the only asset the module embeds.

const std = @import("std");

pub const model = @import("model.zig");
pub const text = @import("text.zig");
pub const host = @import("host.zig");
pub const asset = @import("combat_systems_data").pipeline;

pub const schema = model.schema;
pub const pack = model.pack;

pub fn load(allocator: std.mem.Allocator) !std.json.Parsed(model.Pipeline) {
    return model.load(allocator, asset.json);
}

pub fn loadBytes(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(model.Pipeline) {
    return model.load(allocator, bytes);
}

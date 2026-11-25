//! Full-scale menu lists through one model.
//!
//! Data-driven menu package: the vocabulary asset holds the static source
//! vocabulary, `model` provides the single menu/input architecture, `adapter`
//! builds runtime rows, and `view` is the logical draw projection.

const std = @import("std");

pub const vocabulary = @import("vocabulary.zig");
pub const model = @import("model.zig");
pub const adapter = @import("adapter.zig");
pub const view = @import("view.zig");

pub const data = @import("combat_systems_data").menu_lists;
pub const json = data.json;
pub const schema = vocabulary.schema;
pub const base_snapshot = vocabulary.base_snapshot;

/// The exemplar route graph used by the focused gate.  Production owners pass
/// their own `Route` slice; the model does not hard-code a screen tree.
pub const routes = [_]model.Route{
    .{ .source = .root, .right = .item_action },
    .{ .source = .item_action, .left = .root, .cancel = .root },
    .{ .source = .roster, .right = .bag },
    .{ .source = .bag, .left = .item_action, .right = .target, .cancel = .item_action },
    .{ .source = .target, .left = .bag, .cancel = .bag },
    .{ .source = .storage, .left = .roster, .cancel = .root },
    .{ .source = .shop, .right = .shop_confirm, .cancel = .root },
    .{ .source = .shop_confirm, .left = .shop, .cancel = .shop },
    .{ .source = .shop_stock, .cancel = .shop },
    .{ .source = .blacksmith, .right = .blacksmith_confirm, .cancel = .root },
    .{ .source = .blacksmith_confirm, .left = .blacksmith, .cancel = .blacksmith },
    .{ .source = .rune, .right = .rune_confirm, .cancel = .root },
    .{ .source = .rune_confirm, .left = .rune, .cancel = .rune },
    .{ .source = .appraiser, .right = .appraiser_confirm, .cancel = .root },
    .{ .source = .appraiser_confirm, .left = .appraiser, .cancel = .appraiser },
    .{ .source = .setup, .cancel = .root },
    .{ .source = .pause_commands, .left = .root, .right = .root },
    .{ .source = .battle_commands, .cancel = .root },
};

pub fn menu() model.Menu {
    return model.Menu.init(&routes);
}

pub fn loadAsset(allocator: std.mem.Allocator) !vocabulary.Opened {
    return vocabulary.load(allocator, json);
}

pub fn windowOptions(catalogue: *const vocabulary.Packet, key: []const u8, fallback_rows: u16) model.Options {
    const window: ?*const vocabulary.Window = blk: {
        for (catalogue.windows) |*candidate| {
            if (std.mem.eql(u8, candidate.key, key)) break :blk candidate;
        }
        break :blk null;
    };
    const rows = if (window) |value| value.window.visible_rows else fallback_rows;
    const columns = if (window) |value| value.window.text_width else 26;
    return .{ .window_rows = rows, .columns = columns };
}

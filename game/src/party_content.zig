//! Canonical party-content loader shared by the launcher and headless tests.
const std = @import("std");
const party_session = @import("party_session");

pub const Diagnostic = struct {
    path: []const u8 = "",
    message: []const u8 = "",
};

pub const Content = struct {
    catalog: std.json.Parsed(party_session.catalogue.Catalogue),
    bindings: std.json.Parsed(party_session.catalogue.OwnershipBindings),

    pub fn deinit(self: *Content) void {
        self.catalog.deinit();
        self.bindings.deinit();
    }
};

/// Load the party catalogue and ownership bindings. Canonical starts require
/// both files; prototype packages may omit them and keep room-entry joins off.
pub fn load(allocator: std.mem.Allocator, io: std.Io, directory: std.Io.Dir, required: bool, diagnostic: *Diagnostic) !?Content {
    const catalog_bytes = directory.readFileAlloc(io, "party/catalogue.json", allocator, .limited(8 * 1024 * 1024)) catch |err| {
        diagnostic.path = "party/catalogue.json";
        diagnostic.message = @errorName(err);
        if (required) return error.MissingPartyCatalogue;
        std.log.info("party catalogue is absent; room-entry joins are disabled", .{});
        return null;
    };
    defer allocator.free(catalog_bytes);
    const binding_bytes = directory.readFileAlloc(io, "party/ownership_bindings.json", allocator, .limited(1024 * 1024)) catch |err| {
        diagnostic.path = "party/ownership_bindings.json";
        diagnostic.message = @errorName(err);
        if (required) return error.MissingPartyBindings;
        std.log.info("party ownership bindings are absent; Ted's rune join is disabled", .{});
        return null;
    };
    defer allocator.free(binding_bytes);
    const catalog = party_session.catalogue.decode(allocator, catalog_bytes) catch |err| {
        diagnostic.path = "party/catalogue.json";
        diagnostic.message = @errorName(err);
        return err;
    };
    errdefer catalog.deinit();
    const bindings = party_session.catalogue.decodeBindings(allocator, binding_bytes, catalog_bytes) catch |err| {
        diagnostic.path = "party/ownership_bindings.json";
        diagnostic.message = @errorName(err);
        return err;
    };
    return .{ .catalog = catalog, .bindings = bindings };
}

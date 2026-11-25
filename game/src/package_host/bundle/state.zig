//! Per-user state layout.
//!
//! The layout mirrors the owner the runtime already uses: the save directory is
//! `save_file.defaultDirectory` (`$HOME/Library/Application Support/Suikoden
//! Zig` on macOS) and `journey_main` reads `settings.json` from the same
//! directory.  This module declares that layout, validates it, and proves the
//! candidate can create it without touching anything outside it.
const std = @import("std");
const manifest = @import("manifest.zig");

pub const Scheme = struct {
    schema: []const u8,
    platform: []const u8,
    root_relative_to: []const u8,
    root: []const u8,
    settings: []const u8,
    saves: []const []const u8,
    backups: []const []const u8,
    checks: []const u8,
    isolation: []const u8,
    owner: []const u8,
    rule: []const u8,

    pub fn fromManifest(value: manifest.Manifest) !Scheme {
        const scheme = Scheme{
            .schema = value.user_state.schema,
            .platform = value.user_state.platform,
            .root_relative_to = value.user_state.root_relative_to,
            .root = value.user_state.root,
            .settings = value.user_state.settings,
            .saves = value.user_state.saves,
            .backups = value.user_state.backups,
            .checks = value.user_state.checks,
            .isolation = value.user_state.isolation,
            .owner = value.user_state.owner,
            .rule = value.user_state.rule,
        };
        try scheme.validate();
        return scheme;
    }

    pub fn validate(self: Scheme) !void {
        if (!std.mem.eql(u8, self.schema, "suikoden-user-state/1")) return error.UnsupportedUserState;
        if (!std.mem.eql(u8, self.platform, "macos")) return error.UnsupportedPlatform;
        if (!std.mem.eql(u8, self.root_relative_to, "HOME")) return error.UnsupportedUserRoot;
        if (!std.mem.eql(u8, self.isolation, "home-relative")) return error.UnsupportedIsolation;
        try manifest.safePath(self.root);
        try manifest.safePath(self.settings);
        if (self.saves.len == 0) return error.NoSaveLayout;
        for (self.saves) |name| try manifest.safePath(name);
        for (self.backups) |name| try manifest.safePath(name);
        try manifest.safePath(self.checks);
    }

    /// Join the declared root below a caller-supplied user root.
    pub fn rootPath(self: Scheme, allocator: std.mem.Allocator, user_root: []const u8) ![]u8 {
        return std.fs.path.join(allocator, &.{ user_root, self.root });
    }

    pub fn settingsPath(self: Scheme, allocator: std.mem.Allocator, user_root: []const u8) ![]u8 {
        const root = try self.rootPath(allocator, user_root);
        defer allocator.free(root);
        return std.fs.path.join(allocator, &.{ root, self.settings });
    }

    pub fn checkPath(self: Scheme, allocator: std.mem.Allocator, user_root: []const u8) ![]u8 {
        const root = try self.rootPath(allocator, user_root);
        defer allocator.free(root);
        return std.fs.path.join(allocator, &.{ root, self.checks });
    }

    /// Create only the declared namespace directory below `base`.  Settings and
    /// save files are never created here: a fresh user keeps defaults, and an
    /// existing user keeps every file.
    pub fn ensure(self: Scheme, io: std.Io, base: std.Io.Dir) !void {
        var directory = try base.createDirPathOpen(io, self.root, .{});
        directory.close(io);
    }
};

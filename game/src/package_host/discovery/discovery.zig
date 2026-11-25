//! Standalone resource discovery.
//!
//! The runtime discovers content from exactly two places and never from the
//! repository:
//!   1. an explicit root (`--content`, or an explicit user-data root),
//!   2. a documented executable-relative layout (macOS app bundle
//!      `Contents/Resources/content`, or `bin/../content` / `exe/content`),
//!   3. for user data only, the platform user-data directory.
//!
//! A root that is named but missing is an error.  There is no fallback to a
//! sibling checkout, the build scratch tree, the working directory or source tree.
const std = @import("std");
const builtin = @import("builtin");
const diagnostics = @import("diagnostic.zig");

pub const Diagnostic = diagnostics.Diagnostic;
pub const Code = diagnostics.Code;

pub const Source = enum {
    explicit,
    environment,
    executable_relative,
    bundle_resources,
    platform_default,
};

pub const Location = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    source: Source,

    pub fn deinit(self: *Location) void {
        self.allocator.free(self.path);
        self.* = undefined;
    }
};

pub const ContentOptions = struct {
    /// Explicit `--content` value. Must be absolute when present.
    explicit: ?[]const u8 = null,
    /// `SUIKODEN_CONTENT` value. Must be absolute when present.
    environment: ?[]const u8 = null,
    /// Absolute directory containing the running executable.
    executable_dir: []const u8,
};

pub const UserDataOptions = struct {
    /// Explicit `--user-data` value. Must be absolute when present.
    explicit: ?[]const u8 = null,
    /// `SUIKODEN_USER_DATA` value. Must be absolute when present.
    environment: ?[]const u8 = null,
    environ: *const std.process.Environ.Map,
};

const content_hint =
    "pass --content with an absolute package root, or set SUIKODEN_CONTENT; " ++
    "the runtime does not search the source tree";
const user_hint =
    "pass --user-data with an absolute writable directory, or set SUIKODEN_USER_DATA";

fn absoluteRoot(allocator: std.mem.Allocator, raw: []const u8, code: Code, diag: *Diagnostic, hint: []const u8) ![]u8 {
    if (!std.fs.path.isAbsolute(raw))
        return diag.fail(code, raw, "path is not absolute", .{}, hint);
    return std.fs.path.resolveAlloc(allocator, &.{raw}) catch |err|
        diag.fail(.io_failure, raw, "cannot normalize path: {s}", .{@errorName(err)}, hint);
}

/// Resolve symlinks in the existing part of a path so content/user-data
/// separation is compared on the real tree.  A not-yet-created user-data root
/// is resolved through its longest existing ancestor plus the remaining names.
fn canonical(allocator: std.mem.Allocator, io: std.Io, path: []const u8, diag: *Diagnostic, hint: []const u8) ![]u8 {
    var suffix: std.ArrayList([]const u8) = .empty;
    defer suffix.deinit(allocator);
    var current = path;
    while (true) {
        if (std.Io.Dir.cwd().realPathFileAlloc(io, current, allocator)) |real| {
            defer allocator.free(real);
            var result = allocator.dupe(u8, real) catch return error.OutOfMemory;
            var index = suffix.items.len;
            while (index > 0) {
                index -= 1;
                const next = std.fs.path.join(allocator, &.{ result, suffix.items[index] }) catch return error.OutOfMemory;
                allocator.free(result);
                result = next;
            }
            return result;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return diag.fail(.io_failure, path, "cannot resolve the real path: {s}", .{@errorName(err)}, hint),
        }
        const base = std.fs.path.basename(current);
        const parent = std.fs.path.dirname(current) orelse return allocator.dupe(u8, path);
        if (base.len == 0) return allocator.dupe(u8, path);
        suffix.append(allocator, base) catch return error.OutOfMemory;
        current = parent;
    }
}

const DirState = enum { present, missing, not_directory };

fn directoryState(io: std.Io, path: []const u8) !DirState {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return .missing,
        else => return err,
    };
    dir.close(io);
    return .present;
}

fn checkedContentRoot(allocator: std.mem.Allocator, io: std.Io, raw: []const u8, source: Source, diag: *Diagnostic) !Location {
    const lexical = try absoluteRoot(allocator, raw, .content_root_not_absolute, diag, content_hint);
    defer allocator.free(lexical);
    var dir = std.Io.Dir.cwd().openDir(io, lexical, .{}) catch |err| switch (err) {
        error.FileNotFound => return diag.fail(.content_root_missing, lexical, "content root does not exist", .{}, content_hint),
        error.NotDir => return diag.fail(.content_root_not_directory, lexical, "content root is not a directory", .{}, content_hint),
        else => return diag.fail(.io_failure, lexical, "cannot open content root: {s}", .{@errorName(err)}, content_hint),
    };
    dir.close(io);
    const path = try canonical(allocator, io, lexical, diag, content_hint);
    return .{ .allocator = allocator, .path = path, .source = source };
}

pub fn macBundleRoot(executable_dir: []const u8) ?[]const u8 {
    if (!std.mem.eql(u8, std.fs.path.basename(executable_dir), "MacOS")) return null;
    const contents = std.fs.path.dirname(executable_dir) orelse return null;
    if (!std.mem.eql(u8, std.fs.path.basename(contents), "Contents")) return null;
    return std.fs.path.dirname(contents);
}

/// Resolve the content package root without any source-tree fallback.
pub fn contentRoot(allocator: std.mem.Allocator, io: std.Io, options: ContentOptions, diag: *Diagnostic) !Location {
    if (options.explicit) |raw| return checkedContentRoot(allocator, io, raw, .explicit, diag);
    if (options.environment) |raw| return checkedContentRoot(allocator, io, raw, .environment, diag);

    const Candidate = struct { path: []u8, source: Source };
    var candidates: std.ArrayList(Candidate) = .empty;
    defer {
        for (candidates.items) |candidate| allocator.free(candidate.path);
        candidates.deinit(allocator);
    }

    if (macBundleRoot(options.executable_dir) != null) {
        try candidates.append(allocator, .{
            .path = try std.fs.path.join(allocator, &.{ options.executable_dir, "../Resources/content" }),
            .source = .bundle_resources,
        });
    }
    try candidates.append(allocator, .{
        .path = try std.fs.path.join(allocator, &.{ options.executable_dir, "../content" }),
        .source = .executable_relative,
    });
    try candidates.append(allocator, .{
        .path = try std.fs.path.join(allocator, &.{ options.executable_dir, "content" }),
        .source = .executable_relative,
    });

    for (candidates.items) |candidate| {
        const lexical = std.fs.path.resolveAlloc(allocator, &.{candidate.path}) catch continue;
        defer allocator.free(lexical);
        switch (directoryState(io, lexical) catch |err|
            return diag.fail(.io_failure, lexical, "cannot inspect candidate root: {s}", .{@errorName(err)}, content_hint)) {
            .present => return .{
                .allocator = allocator,
                .path = try canonical(allocator, io, lexical, diag, content_hint),
                .source = candidate.source,
            },
            .missing, .not_directory => {},
        }
    }
    return diag.fail(
        .no_content_root,
        options.executable_dir,
        "no content package next to the executable (looked for Contents/Resources/content, ../content and ./content)",
        .{},
        content_hint,
    );
}

fn defaultUserData(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map) !?[]u8 {
    const home = environ.get("HOME") orelse environ.get("USERPROFILE");
    switch (builtin.os.tag) {
        .windows => {
            if (environ.get("LOCALAPPDATA")) |local| return try std.fs.path.join(allocator, &.{ local, "Suikoden" });
            if (home) |value| return try std.fs.path.join(allocator, &.{ value, "AppData", "Local", "Suikoden" });
        },
        .macos => {
            if (home) |value| return try std.fs.path.join(allocator, &.{ value, "Library", "Application Support", "Suikoden" });
        },
        else => {
            if (environ.get("XDG_DATA_HOME")) |xdg| return try std.fs.path.join(allocator, &.{ xdg, "suikoden" });
            if (home) |value| return try std.fs.path.join(allocator, &.{ value, ".local", "share", "suikoden" });
        },
    }
    if (environ.get("XDG_DATA_HOME")) |xdg| return try std.fs.path.join(allocator, &.{ xdg, "suikoden" });
    if (home) |value| return try std.fs.path.join(allocator, &.{ value, ".local", "share", "suikoden" });
    return null;
}

/// Resolve the private user-data root.  It is created and write-probed later by
/// `prepareUserData`; discovery only decides the path.
pub fn userDataRoot(allocator: std.mem.Allocator, io: std.Io, options: UserDataOptions, diag: *Diagnostic) !Location {
    if (options.explicit) |raw| {
        const lexical = try absoluteRoot(allocator, raw, .user_data_root_not_absolute, diag, user_hint);
        defer allocator.free(lexical);
        return .{
            .allocator = allocator,
            .path = try canonical(allocator, io, lexical, diag, user_hint),
            .source = .explicit,
        };
    }
    if (options.environment) |raw| {
        const lexical = try absoluteRoot(allocator, raw, .user_data_root_not_absolute, diag, user_hint);
        defer allocator.free(lexical);
        return .{
            .allocator = allocator,
            .path = try canonical(allocator, io, lexical, diag, user_hint),
            .source = .environment,
        };
    }
    const default_path = (try defaultUserData(allocator, options.environ)) orelse
        return diag.fail(.no_user_data_root, "user data", "no platform user-data directory is defined and HOME is unset", .{}, user_hint);
    defer allocator.free(default_path);
    const lexical = try absoluteRoot(allocator, default_path, .user_data_root_not_absolute, diag, user_hint);
    defer allocator.free(lexical);
    return .{
        .allocator = allocator,
        .path = try canonical(allocator, io, lexical, diag, user_hint),
        .source = .platform_default,
    };
}

/// Create the user-data root if needed and prove it is writable by creating and
/// deleting a private marker.  Existing files are never touched.
pub fn prepareUserData(allocator: std.mem.Allocator, io: std.Io, root: []const u8, diag: *Diagnostic) !void {
    std.Io.Dir.cwd().createDirPath(io, root) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return diag.fail(.user_data_root_unwritable, root, "cannot create the user-data directory: {s}", .{@errorName(err)}, user_hint),
    };
    var dir = std.Io.Dir.cwd().openDir(io, root, .{}) catch |err|
        return diag.fail(.user_data_root_unwritable, root, "cannot open the user-data directory: {s}", .{@errorName(err)}, user_hint);
    defer dir.close(io);

    var index: usize = 0;
    const marker = while (index < 8) : (index += 1) {
        const name = std.fmt.allocPrint(allocator, ".write-probe-{d}", .{index}) catch return error.OutOfMemory;
        defer allocator.free(name);
        const file = dir.createFile(io, name, .{ .exclusive = true, .truncate = false }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return diag.fail(.user_data_root_unwritable, root, "cannot create a write probe: {s}", .{@errorName(err)}, user_hint),
        };
        var buffer: [64]u8 = undefined;
        var writer = file.writer(io, &buffer);
        writer.interface.writeAll("probe\n") catch |err| {
            file.close(io);
            dir.deleteFile(io, name) catch {};
            return diag.fail(.user_data_root_unwritable, root, "cannot write a write probe: {s}", .{@errorName(err)}, user_hint);
        };
        writer.end() catch |err| {
            file.close(io);
            dir.deleteFile(io, name) catch {};
            return diag.fail(.user_data_root_unwritable, root, "cannot flush a write probe: {s}", .{@errorName(err)}, user_hint);
        };
        file.close(io);
        const stored = allocator.dupe(u8, name) catch return error.OutOfMemory;
        break stored;
    } else {
        return diag.fail(.user_data_root_unwritable, root, "cannot place a write probe (eight names already exist)", .{}, user_hint);
    };
    defer allocator.free(marker);
    dir.deleteFile(io, marker) catch |err|
        return diag.fail(.user_data_root_unwritable, root, "cannot remove the write probe: {s}", .{@errorName(err)}, user_hint);
}

fn isWithin(parent: []const u8, child: []const u8) bool {
    if (std.mem.eql(u8, parent, child)) return true;
    if (parent.len == 0) return false;
    if (parent.len == 1 and parent[0] == std.fs.path.sep) return std.fs.path.isAbsolute(child);
    if (!std.mem.startsWith(u8, child, parent)) return false;
    return child[parent.len] == std.fs.path.sep;
}

/// Content and user data must be disjoint trees: saves are never written into
/// the package, and the package is never treated as user data.
pub fn validateSeparation(content: []const u8, user: []const u8, diag: *Diagnostic) !void {
    diag.clear();
    if (isWithin(content, user) or isWithin(user, content))
        return diag.fail(.roots_overlap, user, "user-data root overlaps the content root", .{}, user_hint);
}

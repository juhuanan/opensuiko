//! Standalone resource discovery and package validation.
//!
//! Public surface for the runtime integrator (module).  The shared content loader
//! is expected to call `boot`/`Package.read` instead of resolving
//! a build directory relative to the source tree.
const std = @import("std");
pub const diagnostic = @import("diagnostic.zig");
pub const discovery = @import("discovery.zig");
pub const package = @import("package.zig");

pub const Diagnostic = diagnostic.Diagnostic;
pub const Code = diagnostic.Code;
pub const Rejection = diagnostic.Rejection;

pub const Source = discovery.Source;
pub const Location = discovery.Location;
pub const ContentOptions = discovery.ContentOptions;
pub const UserDataOptions = discovery.UserDataOptions;

pub const Package = package.Package;
pub const Options = package.Options;
pub const Manifest = package.Manifest;
pub const Resource = package.Resource;
pub const Spec = package.Spec;
pub const Table = package.Table;
pub const Check = package.Check;
pub const open = package.open;

pub const schema = package.schema;
pub const format_version = package.format_version;
pub const content_schema = package.content_schema;
pub const manifest_name = package.manifest_name;
pub const runtime_version = "0.1.0";

pub const BootOptions = struct {
    content: ContentOptions,
    user: UserDataOptions,
    package: Options = .{},
};

pub const Loaded = struct {
    content: Location,
    user: Location,
    package: Package,

    pub fn deinit(self: *Loaded) void {
        self.package.deinit();
        self.user.deinit();
        self.content.deinit();
        self.* = undefined;
    }
};

/// Discover both roots, prove they are disjoint, validate the package and
/// prove the user-data root is writable.  No window, no scripting runtime, no disc image and no
/// source-tree path is consulted.
pub fn boot(allocator: std.mem.Allocator, io: std.Io, options: BootOptions, diag: *Diagnostic) !Loaded {
    var content = try discovery.contentRoot(allocator, io, options.content, diag);
    errdefer content.deinit();
    var user = try discovery.userDataRoot(allocator, io, options.user, diag);
    errdefer user.deinit();
    try discovery.validateSeparation(content.path, user.path, diag);
    const opened = try package.open(allocator, io, content.path, options.package, diag);
    errdefer {
        var pending = opened;
        pending.deinit();
    }
    try discovery.prepareUserData(allocator, io, user.path, diag);
    return .{ .content = content, .user = user, .package = opened };
}

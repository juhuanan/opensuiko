//! Runtime diagnostics.
//!
//! Every rejection carries a stable code, the subject path and a concrete fix.
//! The code is the machine contract (tests and the receipt tool assert it); the
//! message and hint are for a person trying to restore a private package.
const std = @import("std");

pub const Code = enum {
    ok,

    // Discovery / roots.
    no_content_root,
    content_root_not_absolute,
    content_root_missing,
    content_root_not_directory,
    no_user_data_root,
    user_data_root_not_absolute,
    user_data_root_unwritable,
    roots_overlap,

    // Package envelope.
    manifest_missing,
    manifest_symlink,
    manifest_too_large,
    manifest_malformed,
    manifest_schema_unsupported,
    format_version_unsupported,
    content_schema_unsupported,
    package_status_unsupported,
    content_version_invalid,
    table_invalid,

    // Declared resources.
    resource_unknown,
    resource_missing,
    resource_duplicate,
    resource_path_mismatch,
    resource_file_missing,
    resource_file_symlink,
    resource_too_large,
    resource_size_mismatch,
    resource_hash_mismatch,
    resource_unlisted,
    resource_schema_mismatch,
    resource_format_invalid,

    // Rights / provenance.
    notice_invalid,
    provenance_invalid,

    io_failure,
};

pub const Rejection = error{PackageRejected};

/// Owned diagnostic. `set`/`fail` replace any previous value.
pub const Diagnostic = struct {
    allocator: std.mem.Allocator,
    code: Code = .ok,
    subject: ?[]u8 = null,
    message: ?[]u8 = null,
    hint: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator) Diagnostic {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Diagnostic) void {
        self.clear();
        self.* = undefined;
    }

    pub fn clear(self: *Diagnostic) void {
        if (self.subject) |value| self.allocator.free(value);
        if (self.message) |value| self.allocator.free(value);
        if (self.hint) |value| self.allocator.free(value);
        self.code = .ok;
        self.subject = null;
        self.message = null;
        self.hint = null;
    }

    pub fn isOk(self: *const Diagnostic) bool {
        return self.code == .ok;
    }

    pub fn setName(self: *Diagnostic, code: Code, subject: []const u8) !void {
        self.clear();
        self.code = code;
        self.subject = try self.allocator.dupe(u8, subject);
    }

    /// Record a rejection and return `error.PackageRejected`.
    pub fn fail(
        self: *Diagnostic,
        code: Code,
        subject: []const u8,
        comptime fmt: []const u8,
        args: anytype,
        hint: []const u8,
    ) anyerror {
        self.clear();
        self.code = code;
        self.subject = self.allocator.dupe(u8, subject) catch return error.OutOfMemory;
        self.message = std.fmt.allocPrint(self.allocator, fmt, args) catch return error.OutOfMemory;
        self.hint = self.allocator.dupe(u8, hint) catch return error.OutOfMemory;
        return error.PackageRejected;
    }

    /// Single-line rendering used by the no-window candidate and its tool.
    pub fn render(self: *const Diagnostic, allocator: std.mem.Allocator) ![]u8 {
        if (self.code == .ok) return allocator.dupe(u8, "ok");
        return std.fmt.allocPrint(allocator, "error[{s}] {s}: {s}; fix: {s}", .{
            @tagName(self.code),
            self.subject orelse "(unset)",
            self.message orelse "(unset)",
            self.hint orelse "(unset)",
        });
    }
};

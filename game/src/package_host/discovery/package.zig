//! Content package validation.
//!
//! A package is a closed directory: `manifest.json` declares every regular file
//! with its byte count and SHA-256.  Opening the package checks the envelope
//! schema and version, the declared resource set against the compiled runtime
//! table, every file's size and hash, each resource's own schema/format, the
//! rights notice and the provenance documents.  Any mismatch is rejected with a
//! stable code and a concrete fix; consumers never see a half-validated package.
const std = @import("std");
const data = @import("package_host_data");
const diagnostics = @import("diagnostic.zig");

pub const Diagnostic = diagnostics.Diagnostic;
pub const Code = diagnostics.Code;

pub const schema = "suikoden-content-package/1";
pub const format_version: u32 = 1;
pub const content_schema = "suikoden-journey/2";
pub const manifest_name = "manifest.json";

pub const Check = enum { json_schema, json_object, png, wav, notice, provenance };

pub const Spec = struct {
    id: []const u8,
    path: []const u8,
    required: bool,
    check: Check,
    schemas: []const []const u8 = &.{},
    max_bytes: u64,
};

pub const Table = struct {
    schema: []const u8,
    format_version: u32,
    manifest_schema: []const u8,
    supported_content_schemas: []const []const u8,
    package_status: []const u8,
    manifest_max_bytes: u64,
    max_resources: u32,
    resources: []const Spec,
};

pub const Resource = struct {
    id: []const u8,
    path: []const u8,
    sha256: []const u8,
    bytes: u64,
};

pub const Manifest = struct {
    schema: []const u8,
    format_version: u32,
    content_schema: []const u8,
    content_version: []const u8,
    status: []const u8,
    resources: []const Resource,

    fn contains(self: Manifest, path: []const u8) bool {
        for (self.resources) |resource| if (std.mem.eql(u8, resource.path, path)) return true;
        return false;
    }
};

pub const Options = struct {
    /// Hash every declared file.  A consumer always uses the default; the
    /// option exists for a tool that already qualified the exact bytes.
    verify_hashes: bool = true,
    /// Reject any regular file the manifest does not declare.
    closed: bool = true,
};

const manifest_hint =
    "restore the package's own manifest.json, or rebuild the package from a qualified content root";
const resource_hint =
    "reinstall the declared file from the qualified content package; do not hand-edit the manifest";

const manifest_keys = [_][]const u8{ "schema", "format_version", "content_schema", "content_version", "status", "resources" };
const resource_keys = [_][]const u8{ "id", "path", "sha256", "bytes" };

fn rejectUnknown(
    object: std.json.ObjectMap,
    allowed: []const []const u8,
    code: Code,
    subject: []const u8,
    diag: *Diagnostic,
    hint: []const u8,
) !void {
    for (object.keys()) |key| {
        var known = false;
        for (allowed) |candidate| {
            if (std.mem.eql(u8, key, candidate)) {
                known = true;
                break;
            }
        }
        if (!known) return diag.fail(code, subject, "unknown field \"{s}\" is not part of the contract", .{key}, hint);
    }
}

fn textField(
    object: std.json.ObjectMap,
    key: []const u8,
    code: Code,
    subject: []const u8,
    diag: *Diagnostic,
    hint: []const u8,
) ![]const u8 {
    const value = object.get(key) orelse
        return diag.fail(code, subject, "missing required field \"{s}\"", .{key}, hint);
    return switch (value) {
        .string => |text| text,
        else => diag.fail(code, subject, "field \"{s}\" must be a string", .{key}, hint),
    };
}

fn integerField(
    object: std.json.ObjectMap,
    key: []const u8,
    code: Code,
    subject: []const u8,
    diag: *Diagnostic,
    hint: []const u8,
) !i64 {
    const value = object.get(key) orelse
        return diag.fail(code, subject, "missing required field \"{s}\"", .{key}, hint);
    return switch (value) {
        .integer => |number| number,
        else => diag.fail(code, subject, "field \"{s}\" must be an integer", .{key}, hint),
    };
}

fn isLowerHex64(text: []const u8) bool {
    if (text.len != 64) return false;
    for (text) |byte| {
        if (!((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))) return false;
    }
    return true;
}

fn isPrintable(text: []const u8) bool {
    for (text) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

pub fn findSpec(table: Table, id: []const u8) ?Spec {
    for (table.resources) |spec| if (std.mem.eql(u8, spec.id, id)) return spec;
    return null;
}

pub fn findResource(manifest: Manifest, id: []const u8) ?Resource {
    for (manifest.resources) |resource| if (std.mem.eql(u8, resource.id, id)) return resource;
    return null;
}

fn parseManifest(arena: std.mem.Allocator, bytes: []const u8, table: Table, diag: *Diagnostic) !Manifest {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, bytes, .{
        .allocate = .alloc_always,
        .max_value_len = bytes.len,
    }) catch |err|
        return diag.fail(.manifest_malformed, manifest_name, "not valid JSON ({s})", .{@errorName(err)}, manifest_hint);
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return diag.fail(.manifest_malformed, manifest_name, "top-level value must be an object", .{}, manifest_hint),
    };
    try rejectUnknown(root, &manifest_keys, .manifest_malformed, manifest_name, diag, manifest_hint);

    const found_schema = try textField(root, "schema", .manifest_malformed, manifest_name, diag, manifest_hint);
    if (!std.mem.eql(u8, found_schema, table.manifest_schema))
        return diag.fail(
            .manifest_schema_unsupported,
            manifest_name,
            "package schema \"{s}\" is not supported by this runtime (expected \"{s}\")",
            .{ found_schema, table.manifest_schema },
            manifest_hint,
        );

    const found_format = try integerField(root, "format_version", .manifest_malformed, manifest_name, diag, manifest_hint);
    if (found_format < 1 or found_format > std.math.maxInt(u32))
        return diag.fail(.manifest_malformed, manifest_name, "format_version {d} is not a valid version", .{found_format}, manifest_hint);
    if (@as(u32, @intCast(found_format)) != table.format_version)
        return diag.fail(
            .format_version_unsupported,
            manifest_name,
            "package format {d} is not supported (this runtime supports format {d})",
            .{ found_format, table.format_version },
            "rebuild the package for this runtime, or run a runtime that supports the package's format version",
        );

    const found_content_schema = try textField(root, "content_schema", .manifest_malformed, manifest_name, diag, manifest_hint);
    var schema_supported = false;
    for (table.supported_content_schemas) |candidate| {
        if (std.mem.eql(u8, candidate, found_content_schema)) schema_supported = true;
    }
    if (!schema_supported) {
        var supported_buffer: [512]u8 = undefined;
        var supported_length: usize = 0;
        for (table.supported_content_schemas, 0..) |candidate, index| {
            if (index != 0) {
                supported_buffer[supported_length..][0..2].* = ", ".*;
                supported_length += 2;
            }
            @memcpy(supported_buffer[supported_length..][0..candidate.len], candidate);
            supported_length += candidate.len;
        }
        const supported = supported_buffer[0..supported_length];
        return diag.fail(
            .content_schema_unsupported,
            manifest_name,
            "content schema \"{s}\" is not supported (this runtime supports {s})",
            .{ found_content_schema, supported },
            "rebuild the content package with a matching exporter, or use a runtime that supports this content schema",
        );
    }

    const found_version = try textField(root, "content_version", .manifest_malformed, manifest_name, diag, manifest_hint);
    if (found_version.len == 0 or found_version.len > 96 or !isPrintable(found_version))
        return diag.fail(.content_version_invalid, manifest_name, "content_version must be 1..96 printable bytes", .{}, manifest_hint);

    const found_status = try textField(root, "status", .manifest_malformed, manifest_name, diag, manifest_hint);
    if (!std.mem.eql(u8, found_status, table.package_status))
        return diag.fail(
            .package_status_unsupported,
            manifest_name,
            "package status \"{s}\" is not a private {s} package",
            .{ found_status, table.package_status },
            "this runtime only opens private candidate packages; promotion and review are separate gates",
        );

    const resources_value = root.get("resources") orelse
        return diag.fail(.manifest_malformed, manifest_name, "missing required field \"resources\"", .{}, manifest_hint);
    const entries = switch (resources_value) {
        .array => |array| array,
        else => return diag.fail(.manifest_malformed, manifest_name, "field \"resources\" must be an array", .{}, manifest_hint),
    };
    if (entries.items.len == 0 or entries.items.len > table.max_resources)
        return diag.fail(
            .manifest_malformed,
            manifest_name,
            "package declares {d} resources; expected 1..{d}",
            .{ entries.items.len, table.max_resources },
            manifest_hint,
        );

    var list: std.ArrayList(Resource) = .empty;
    try list.ensureTotalCapacity(arena, entries.items.len);
    for (entries.items) |entry| {
        const object = switch (entry) {
            .object => |object| object,
            else => return diag.fail(.manifest_malformed, manifest_name, "each resource entry must be an object", .{}, manifest_hint),
        };
        try rejectUnknown(object, &resource_keys, .manifest_malformed, manifest_name, diag, manifest_hint);
        const id = try textField(object, "id", .manifest_malformed, manifest_name, diag, manifest_hint);
        const path = try textField(object, "path", .manifest_malformed, manifest_name, diag, manifest_hint);
        const digest = try textField(object, "sha256", .manifest_malformed, manifest_name, diag, manifest_hint);
        const byte_count = try integerField(object, "bytes", .manifest_malformed, manifest_name, diag, manifest_hint);
        if (id.len == 0 or id.len > 64 or path.len == 0 or path.len > 160 or !isPrintable(id) or !isPrintable(path))
            return diag.fail(.manifest_malformed, manifest_name, "resource id/path lengths or characters are outside the contract", .{}, manifest_hint);
        if (!isLowerHex64(digest))
            return diag.fail(.manifest_malformed, manifest_name, "resource \"{s}\" sha256 must be 64 lowercase hex characters", .{id}, manifest_hint);
        if (byte_count <= 0)
            return diag.fail(.manifest_malformed, manifest_name, "resource \"{s}\" bytes must be a positive integer", .{id}, manifest_hint);
        list.appendAssumeCapacity(.{
            .id = id,
            .path = path,
            .sha256 = digest,
            .bytes = @intCast(byte_count),
        });
    }

    const manifest = Manifest{
        .schema = found_schema,
        .format_version = @intCast(found_format),
        .content_schema = found_content_schema,
        .content_version = found_version,
        .status = found_status,
        .resources = try arena.dupe(Resource, list.items),
    };

    // Declared ids, paths and required coverage.
    for (manifest.resources, 0..) |resource, index| {
        const spec = findSpec(table, resource.id) orelse
            return diag.fail(
                .resource_unknown,
                resource.path,
                "resource id \"{s}\" is not known to this runtime",
                .{resource.id},
                "regenerate the manifest from game/assets/package_host/resources.json; the runtime never opens an undeclared resource type",
            );
        if (!std.mem.eql(u8, spec.path, resource.path))
            return diag.fail(
                .resource_path_mismatch,
                resource.path,
                "resource \"{s}\" declares path \"{s}\" but the runtime requires \"{s}\"",
                .{ resource.id, resource.path, spec.path },
                manifest_hint,
            );
        if (resource.bytes > spec.max_bytes)
            return diag.fail(
                .resource_too_large,
                resource.path,
                "resource \"{s}\" declares {d} bytes; the runtime limit is {d}",
                .{ resource.id, resource.bytes, spec.max_bytes },
                "rebuild the resource with the current exporter; the runtime will not read an oversized file",
            );
        for (manifest.resources[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.id, resource.id))
                return diag.fail(.resource_duplicate, resource.path, "resource id \"{s}\" is declared more than once", .{resource.id}, manifest_hint);
            if (std.mem.eql(u8, earlier.path, resource.path))
                return diag.fail(.resource_duplicate, resource.path, "resource path \"{s}\" is declared more than once", .{resource.path}, manifest_hint);
        }
    }
    for (table.resources) |spec| {
        if (!spec.required) continue;
        if (findResource(manifest, spec.id) == null)
            return diag.fail(
                .resource_missing,
                spec.path,
                "required resource \"{s}\" ({s}) is not declared",
                .{ spec.id, spec.path },
                "restore the complete package or rebuild it from a qualified content root",
            );
    }
    return manifest;
}

fn openRoot(io: std.Io, root: []const u8, iterate: bool) !std.Io.Dir {
    return std.Io.Dir.cwd().openDir(io, root, .{ .iterate = iterate });
}

fn openRegularFile(
    dir: std.Io.Dir,
    io: std.Io,
    relative: []const u8,
    diag: *Diagnostic,
    missing: Code,
    symlink: Code,
    hint: []const u8,
) !struct { file: std.Io.File, size: u64 } {
    const file = dir.openFile(io, relative, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return diag.fail(missing, relative, "file is missing", .{}, hint),
        error.SymLinkLoop => return diag.fail(symlink, relative, "path is a symbolic link; the package must contain regular files", .{}, hint),
        error.IsDir => return diag.fail(.resource_format_invalid, relative, "path is a directory, not a regular file", .{}, hint),
        error.AccessDenied, error.PermissionDenied => return diag.fail(.io_failure, relative, "permission denied while opening the file", .{}, hint),
        else => return diag.fail(.io_failure, relative, "cannot open the file: {s}", .{@errorName(err)}, hint),
    };
    errdefer file.close(io);
    const stat = file.stat(io) catch |err|
        return diag.fail(.io_failure, relative, "cannot stat the file: {s}", .{@errorName(err)}, hint);
    if (stat.kind != .file)
        return diag.fail(.resource_format_invalid, relative, "path is not a regular file", .{}, hint);
    return .{ .file = file, .size = stat.size };
}

fn readFile(
    dir: std.Io.Dir,
    io: std.Io,
    relative: []const u8,
    allocator: std.mem.Allocator,
    limit: u64,
    diag: *Diagnostic,
    missing: Code,
    symlink: Code,
    too_large: Code,
    hint: []const u8,
) ![]u8 {
    const resource = try openRegularFile(dir, io, relative, diag, missing, symlink, hint);
    defer resource.file.close(io);
    if (resource.size > limit)
        return diag.fail(too_large, relative, "file is {d} bytes; the runtime limit for this resource is {d}", .{ resource.size, limit }, hint);
    var buffer: [8192]u8 = undefined;
    var file_reader = resource.file.reader(io, &buffer);
    var reader = &file_reader.interface;
    return reader.allocRemaining(allocator, .limited(@intCast(limit))) catch |err| switch (err) {
        error.StreamTooLong => diag.fail(too_large, relative, "file grew beyond the {d}-byte limit", .{limit}, hint),
        else => diag.fail(.io_failure, relative, "cannot read the file: {s}", .{@errorName(err)}, hint),
    };
}

fn parseJson(allocator: std.mem.Allocator, bytes: []const u8, code: Code, subject: []const u8, diag: *Diagnostic) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .allocate = .alloc_always,
        .max_value_len = bytes.len,
    }) catch |err|
        return diag.fail(code, subject, "not valid JSON ({s})", .{@errorName(err)}, resource_hint);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

fn checkNotice(bytes: []const u8, subject: []const u8, diag: *Diagnostic) !void {
    if (!std.unicode.utf8ValidateSlice(bytes))
        return diag.fail(.notice_invalid, subject, "notice is not valid UTF-8 text", .{}, "restore the package notice from game/assets/package_host/NOTICE.txt");
    const required = [_][]const u8{ "Konami", "private", "provenance" };
    for (required) |token| {
        if (!containsIgnoreCase(bytes, token))
            return diag.fail(
                .notice_invalid,
                subject,
                "notice does not state \"{s}\"",
                .{token},
                "restore the package notice from game/assets/package_host/NOTICE.txt",
            );
    }
}

fn checkProvenance(allocator: std.mem.Allocator, bytes: []const u8, subject: []const u8, diag: *Diagnostic) !void {
    const parsed = try parseJson(allocator, bytes, .provenance_invalid, subject, diag);
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return diag.fail(.provenance_invalid, subject, "provenance document must be a JSON object", .{}, resource_hint),
    };
    const document_schema = object.get("schema") orelse
        return diag.fail(.provenance_invalid, subject, "provenance document has no schema", .{}, resource_hint);
    switch (document_schema) {
        .string => |value| if (value.len == 0 or !std.mem.startsWith(u8, value, "suikoden-"))
            return diag.fail(.provenance_invalid, subject, "provenance schema \"{s}\" is not a Suikoden provenance schema", .{value}, resource_hint),
        else => return diag.fail(.provenance_invalid, subject, "provenance schema must be a string", .{}, resource_hint),
    }
    var has_decoder = false;
    for ([_][]const u8{ "decoder", "exporter", "codec" }) |key| {
        if (object.get(key)) |value| switch (value) {
            .string => |text| if (text.len != 0) {
                has_decoder = true;
            },
            else => {},
        };
    }
    if (!has_decoder)
        return diag.fail(.provenance_invalid, subject, "provenance does not name a decoder, exporter or codec", .{}, resource_hint);
    const sources = object.get("sources") orelse
        return diag.fail(.provenance_invalid, subject, "provenance has no sources", .{}, resource_hint);
    const array = switch (sources) {
        .array => |value| value,
        else => return diag.fail(.provenance_invalid, subject, "provenance sources must be an array", .{}, resource_hint),
    };
    if (array.items.len == 0)
        return diag.fail(.provenance_invalid, subject, "provenance sources is empty", .{}, "export the content package with provenance enabled");
    for (array.items) |source| {
        const entry = switch (source) {
            .object => |value| value,
            else => return diag.fail(.provenance_invalid, subject, "each provenance source must be an object", .{}, resource_hint),
        };
        const file_value = entry.get("file") orelse
            return diag.fail(.provenance_invalid, subject, "provenance source has no file", .{}, resource_hint);
        const file = switch (file_value) {
            .string => |value| value,
            else => return diag.fail(.provenance_invalid, subject, "provenance source file must be a string", .{}, resource_hint),
        };
        if (file.len == 0)
            return diag.fail(.provenance_invalid, subject, "provenance source file is empty", .{}, resource_hint);
        if (entry.get("lba")) |lba_value| switch (lba_value) {
            .integer => |lba| if (lba < 0)
                return diag.fail(.provenance_invalid, subject, "provenance source \"{s}\" has a negative LBA", .{file}, resource_hint),
            else => return diag.fail(.provenance_invalid, subject, "provenance source \"{s}\" LBA must be an integer", .{file}, resource_hint),
        };
        const digest_value = entry.get("sha256") orelse
            return diag.fail(.provenance_invalid, subject, "provenance source \"{s}\" has no sha256", .{file}, resource_hint);
        const digest = switch (digest_value) {
            .string => |value| value,
            else => return diag.fail(.provenance_invalid, subject, "provenance source \"{s}\" sha256 must be a string", .{file}, resource_hint),
        };
        if (!isLowerHex64(digest))
            return diag.fail(.provenance_invalid, subject, "provenance source \"{s}\" sha256 is not 64 lowercase hex characters", .{file}, resource_hint);
    }
}

fn checkResource(
    backing: std.mem.Allocator,
    resource: Resource,
    spec: Spec,
    bytes: []const u8,
    diag: *Diagnostic,
) !void {
    switch (spec.check) {
        .json_schema => {
            const parsed = try parseJson(backing, bytes, .resource_format_invalid, resource.path, diag);
            defer parsed.deinit();
            const object = switch (parsed.value) {
                .object => |value| value,
                else => return diag.fail(.resource_format_invalid, resource.path, "content document must be a JSON object", .{}, resource_hint),
            };
            const found = object.get("schema") orelse
                return diag.fail(.resource_schema_mismatch, resource.path, "content document has no schema", .{}, resource_hint);
            const actual = switch (found) {
                .string => |value| value,
                else => return diag.fail(.resource_schema_mismatch, resource.path, "content document schema must be a string", .{}, resource_hint),
            };
            var supported = false;
            for (spec.schemas) |candidate| {
                if (std.mem.eql(u8, candidate, actual)) supported = true;
            }
            if (!supported) {
                var list_buffer: [1024]u8 = undefined;
                var list_length: usize = 0;
                for (spec.schemas, 0..) |candidate, index| {
                    if (index != 0) {
                        list_buffer[list_length..][0..2].* = ", ".*;
                        list_length += 2;
                    }
                    @memcpy(list_buffer[list_length..][0..candidate.len], candidate);
                    list_length += candidate.len;
                }
                const list = list_buffer[0..list_length];
                return diag.fail(
                    .resource_schema_mismatch,
                    resource.path,
                    "content document schema \"{s}\" is not supported (runtime supports {s})",
                    .{ actual, list },
                    "rebuild the content package with a matching exporter, or run a runtime that supports this content schema",
                );
            }
        },
        .json_object => {
            const parsed = try parseJson(backing, bytes, .resource_format_invalid, resource.path, diag);
            defer parsed.deinit();
            switch (parsed.value) {
                .object => {},
                else => return diag.fail(.resource_format_invalid, resource.path, "document must be a JSON object", .{}, resource_hint),
            }
        },
        .png => {
            const signature = "\x89PNG\r\n\x1a\n";
            if (bytes.len < 16 or !std.mem.startsWith(u8, bytes, signature) or !std.mem.eql(u8, bytes[12..16], "IHDR"))
                return diag.fail(.resource_format_invalid, resource.path, "file is not a PNG image (signature or IHDR missing)", .{}, "reinstall the image from the qualified content package");
        },
        .wav => {
            if (bytes.len < 12 or !std.mem.eql(u8, bytes[0..4], "RIFF") or !std.mem.eql(u8, bytes[8..12], "WAVE"))
                return diag.fail(.resource_format_invalid, resource.path, "file is not a RIFF/WAVE audio stream", .{}, "reinstall the audio candidate from the qualified content package");
        },
        .notice => try checkNotice(bytes, resource.path, diag),
        .provenance => try checkProvenance(backing, bytes, resource.path, diag),
    }
}

pub const Package = struct {
    arena: std.heap.ArenaAllocator,
    root: []const u8,
    table: Table,
    manifest: Manifest,

    pub fn deinit(self: *Package) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn spec(self: *const Package, id: []const u8) ?Spec {
        return findSpec(self.table, id);
    }

    pub fn resource(self: *const Package, id: []const u8) ?Resource {
        return findResource(self.manifest, id);
    }

    pub fn declaredBytes(self: *const Package) u64 {
        var total: u64 = 0;
        for (self.manifest.resources) |item| total += item.bytes;
        return total;
    }

    /// Read a declared resource after the package passed validation.  The
    /// caller's `limit` is clamped to the table's per-resource ceiling.
    pub fn read(
        self: *const Package,
        io: std.Io,
        id: []const u8,
        allocator: std.mem.Allocator,
        limit: usize,
        diag: *Diagnostic,
    ) ![]u8 {
        const entry = self.resource(id) orelse
            return diag.fail(.resource_unknown, id, "resource id is not declared by this package", .{}, resource_hint);
        const entry_spec = self.spec(id) orelse
            return diag.fail(.resource_unknown, id, "resource id is not in the runtime table", .{}, resource_hint);
        const ceiling: u64 = @min(@as(u64, limit), entry_spec.max_bytes);
        var dir = openRoot(io, self.root, false) catch |err|
            return diag.fail(.content_root_missing, self.root, "content root disappeared: {s}", .{@errorName(err)}, "restore the content package root");
        defer dir.close(io);
        return readFile(dir, io, entry.path, allocator, ceiling, diag, .resource_file_missing, .resource_file_symlink, .resource_too_large, resource_hint);
    }
};

fn scanClosed(
    io: std.Io,
    root: []const u8,
    declared: anytype,
    backing: std.mem.Allocator,
    diag: *Diagnostic,
) !void {
    var root_dir = openRoot(io, root, true) catch |err|
        return diag.fail(.content_root_missing, root, "cannot iterate content root: {s}", .{@errorName(err)}, "restore the content package root");
    defer root_dir.close(io);
    var walker = root_dir.walk(backing) catch |err|
        return diag.fail(.io_failure, root, "cannot walk content root: {s}", .{@errorName(err)}, "restore the content package root");
    defer walker.deinit();
    while (walker.next(io) catch |err|
        return diag.fail(.io_failure, root, "cannot walk content root: {s}", .{@errorName(err)}, "restore the content package root")) |entry|
    {
        switch (entry.kind) {
            .directory => {},
            .file => {
                const relative = if (std.fs.path.isAbsolute(entry.path))
                    std.fs.path.relativeAlloc(backing, ".", null, root, entry.path) catch return error.OutOfMemory
                else
                    backing.dupe(u8, entry.path) catch return error.OutOfMemory;
                defer backing.free(relative);
                if (std.mem.eql(u8, relative, manifest_name)) continue;
                if (declared.contains(relative)) continue;
                return diag.fail(
                    .resource_unlisted,
                    relative,
                    "content package contains a file the manifest does not declare",
                    .{},
                    "remove the file or declare it in manifest.json; a closure-verified package never carries unknown resources",
                );
            },
            .sym_link => return diag.fail(
                .resource_file_symlink,
                entry.path,
                "content package contains a symbolic link",
                .{},
                "replace the link with the regular file it points to",
            ),
            else => return diag.fail(
                .resource_unlisted,
                entry.path,
                "content package contains a non-regular entry",
                .{},
                "remove the special file; a package contains only regular files and directories",
            ),
        }
    }
}

fn isJourneyResourcePath(path: []const u8) bool {
    if (std.mem.eql(u8, path, manifest_name) or !isPrintable(path) or
        std.mem.findAny(u8, path, "\\:") != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

pub fn verifyJourneyFiles(allocator: std.mem.Allocator, io: std.Io, root: []const u8, bytes: []const u8, diag: *Diagnostic) !void {
    const metadata = try parseJson(allocator, bytes, .manifest_malformed, manifest_name, diag);
    defer metadata.deinit();
    const files = if (metadata.value == .object) metadata.value.object.get("files") else null;
    if (files == null or files.? != .object or files.?.object.count() == 0)
        return diag.fail(.manifest_malformed, manifest_name, "expected a nonempty object of file hashes", .{}, manifest_hint);
    const declared = files.?.object;
    var directory = try openRoot(io, root, false);
    defer directory.close(io);
    for (declared.keys(), declared.values()) |path, digest| {
        if (!isJourneyResourcePath(path) or digest != .string or !isLowerHex64(digest.string))
            return diag.fail(.manifest_malformed, manifest_name, "invalid path or SHA-256 for {s}", .{path}, manifest_hint);
        const resource = try openRegularFile(directory, io, path, diag, .resource_file_missing, .resource_file_symlink, resource_hint);
        defer resource.file.close(io);
        var buffer: [8192]u8 = undefined;
        var file_reader = resource.file.reader(io, &buffer);
        var chunk: [32768]u8 = undefined;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        while (true) {
            const count = file_reader.interface.readSliceShort(&chunk) catch |err|
                return diag.fail(.io_failure, path, "cannot hash file: {s}", .{@errorName(err)}, resource_hint);
            hasher.update(chunk[0..count]);
            if (count < chunk.len) break;
        }
        const actual = std.fmt.bytesToHex(hasher.finalResult(), .lower);
        if (!std.mem.eql(u8, &actual, digest.string))
            return diag.fail(.resource_hash_mismatch, path, "declared sha256 {s} but found {s}", .{ digest.string, actual }, resource_hint);
    }
    try scanClosed(io, root, declared, allocator, diag);
}

/// Open and fully validate a package rooted at an absolute directory.
pub fn open(backing: std.mem.Allocator, io: std.Io, root: []const u8, options: Options, diag: *Diagnostic) !Package {
    if (!std.fs.path.isAbsolute(root))
        return diag.fail(.content_root_not_absolute, root, "package root must be absolute", .{}, "resolve the root before opening the package; the runtime never guesses a working directory");
    var arena = std.heap.ArenaAllocator.init(backing);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    const table = std.json.parseFromSliceLeaky(Table, allocator, data.resources_json, .{
        .allocate = .alloc_always,
    }) catch |err|
        return diag.fail(.table_invalid, "embedded resources.json", "runtime resource table is invalid ({s})", .{@errorName(err)}, "this is a runtime build defect; rebuild the game");
    if (!std.mem.eql(u8, table.schema, "suikoden-content-resource-table/1"))
        return diag.fail(.table_invalid, "embedded resources.json", "runtime resource table schema is not supported", .{}, "this is a runtime build defect; rebuild the game");
    for (table.resources) |entry| {
        if (entry.check == .json_schema and entry.schemas.len == 0)
            return diag.fail(.table_invalid, entry.path, "JSON resource has no supported schema list", .{}, "this is a runtime build defect; rebuild the game");
    }

    var dir = openRoot(io, root, false) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return diag.fail(.content_root_missing, root, "content root does not exist", .{}, "restore the content package or pass --content with its root"),
        else => return diag.fail(.io_failure, root, "cannot open content root: {s}", .{@errorName(err)}, "restore the content package root"),
    };
    defer dir.close(io);

    const manifest_bytes = try readFile(
        dir,
        io,
        manifest_name,
        allocator,
        table.manifest_max_bytes,
        diag,
        .manifest_missing,
        .manifest_symlink,
        .manifest_too_large,
        manifest_hint,
    );
    const manifest = try parseManifest(allocator, manifest_bytes, table, diag);

    for (manifest.resources) |resource| {
        const spec = findSpec(table, resource.id).?;
        const bytes = try readFile(
            dir,
            io,
            resource.path,
            backing,
            spec.max_bytes,
            diag,
            .resource_file_missing,
            .resource_file_symlink,
            .resource_too_large,
            resource_hint,
        );
        defer backing.free(bytes);
        if (bytes.len != resource.bytes)
            return diag.fail(
                .resource_size_mismatch,
                resource.path,
                "declared {d} bytes but found {d}; the file was modified or the manifest is stale",
                .{ resource.bytes, bytes.len },
                "restore the qualified file, or regenerate the manifest from the exact bytes",
            );
        if (options.verify_hashes) {
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
            const actual = std.fmt.bytesToHex(digest, .lower);
            if (!std.mem.eql(u8, &actual, resource.sha256))
                return diag.fail(
                    .resource_hash_mismatch,
                    resource.path,
                    "declared sha256 {s} but found {s}",
                    .{ resource.sha256, actual },
                    "restore the qualified file; a modified package is never loaded",
                );
        }
        try checkResource(backing, resource, spec, bytes, diag);
    }

    if (options.closed) try scanClosed(io, root, manifest, backing, diag);

    return .{ .arena = arena, .root = try allocator.dupe(u8, root), .table = table, .manifest = manifest };
}

//! Focused gate: standalone discovery and package validation.
//!
//! Port level only: no original instruction, disc image, Python process,
//! emulator, window or real user data.  Every fixture is built in a temporary
//! directory, hashed at runtime, and opened through the same public API the
//! integrated runtime will use.
const std = @import("std");
const discovery_mod = @import("package_host").discovery;

const allocator = std.testing.allocator;
const io = std.testing.io;

const png = "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR";
const notice_text =
    "Private candidate content. Original game content belongs to Konami. " ++
    "Extraction provenance is recorded in provenance.json.\n";
const room_text = "{\"schema\":\"suikoden-room/7\"}";
const journey_text = "{\"schema\":\"suikoden-journey/2\"}";
const trial_text = "{\"schema\":\"suikoden-battle-trial/15\"}";
const room_provenance =
    "{\"schema\":\"suikoden-room-provenance/1\",\"decoder\":\"lzss.py v2.0.0 strict\"," ++
    "\"sources\":[{\"file\":\"DATA/02_AREA.B/VB6.BIN\",\"lba\":62561,\"sha256\":\"" ++ "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ++ "\"}]}";
const battle_provenance =
    "{\"schema\":\"suikoden-journey-battle-provenance/1\",\"exporter\":\"export_journey.py\"," ++
    "\"sources\":[{\"file\":\"DATA/04_PLAY/SHU.BIN\",\"lba\":87156,\"sha256\":\"" ++ "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++ "\"}]}";

const Fixture = struct { path: []const u8, id: []const u8, bytes: []const u8 };

const required = [_]Fixture{
    .{ .path = "room.json", .id = "room", .bytes = room_text },
    .{ .path = "journey.json", .id = "journey", .bytes = journey_text },
    .{ .path = "battle/trial.json", .id = "battle_trial", .bytes = trial_text },
    .{ .path = "atlas.png", .id = "atlas", .bytes = png },
    .{ .path = "battle/actors.png", .id = "battle_actors", .bytes = png },
    .{ .path = "battle/floor.png", .id = "battle_floor", .bytes = png },
    .{ .path = "provenance.json", .id = "provenance", .bytes = room_provenance },
    .{ .path = "battle/provenance.json", .id = "battle_provenance", .bytes = battle_provenance },
    .{ .path = "NOTICE.txt", .id = "notice", .bytes = notice_text },
};

const Variant = struct {
    schema: []const u8 = discovery_mod.schema,
    format_version: u32 = discovery_mod.format_version,
    content_schema: []const u8 = discovery_mod.content_schema,
    content_version: []const u8 = "discovery-test",
    status: []const u8 = "candidate",
};

fn absolutePath(dir: std.Io.Dir) ![]u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try dir.realPath(io, &buffer);
    return allocator.dupe(u8, buffer[0..length]);
}

fn writeFile(dir: std.Io.Dir, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(io, parent);
    try dir.writeFile(io, .{ .sub_path = path, .data = data });
}

fn resourceEntries(files: []const Fixture) ![]discovery_mod.Resource {
    const entries = try allocator.alloc(discovery_mod.Resource, files.len);
    for (files, 0..) |file, index| {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(file.bytes, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        entries[index] = .{
            .id = file.id,
            .path = file.path,
            .sha256 = try allocator.dupe(u8, hex[0..]),
            .bytes = file.bytes.len,
        };
    }
    return entries;
}

fn freeEntries(entries: []discovery_mod.Resource) void {
    for (entries) |entry| allocator.free(entry.sha256);
    allocator.free(entries);
}

fn manifestJson(variant: Variant, entries: []const discovery_mod.Resource) ![]u8 {
    const manifest = discovery_mod.Manifest{
        .schema = variant.schema,
        .format_version = variant.format_version,
        .content_schema = variant.content_schema,
        .content_version = variant.content_version,
        .status = variant.status,
        .resources = entries,
    };
    return std.json.Stringify.valueAlloc(allocator, manifest, .{});
}

/// Install `files` plus a manifest built from their exact bytes.
fn install(dir: std.Io.Dir, files: []const Fixture, variant: Variant) !void {
    for (files) |file| try writeFile(dir, file.path, file.bytes);
    const entries = try resourceEntries(files);
    defer freeEntries(entries);
    const bytes = try manifestJson(variant, entries);
    defer allocator.free(bytes);
    try writeFile(dir, "manifest.json", bytes);
}

fn expectCode(root: []const u8, code: discovery_mod.Code) !void {
    var diagnostic = discovery_mod.Diagnostic.init(allocator);
    defer diagnostic.deinit();
    try std.testing.expectError(error.PackageRejected, discovery_mod.open(allocator, io, root, .{}, &diagnostic));
    try std.testing.expectEqual(code, diagnostic.code);
    try std.testing.expect(diagnostic.hint != null);
    try std.testing.expect(diagnostic.hint.?.len > 0);
}

fn tempRoot(temp: *std.testing.TmpDir) ![]u8 {
    return absolutePath(temp.dir);
}

test "valid package opens, verifies every declared byte and reads a resource" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const event_text = "{\"schema\":\"suikoden-battle-field-events/5\",\"rooms\":[]}";
    const files = required ++ [_]Fixture{.{ .path = "battle/field_events.json", .id = "battle_field_events", .bytes = event_text }};
    try install(temp.dir, &files, .{});
    const root = try tempRoot(&temp);
    defer allocator.free(root);

    var diagnostic = discovery_mod.Diagnostic.init(allocator);
    defer diagnostic.deinit();
    var package = try discovery_mod.open(allocator, io, root, .{}, &diagnostic);
    defer package.deinit();
    try std.testing.expect(diagnostic.isOk());
    try std.testing.expectEqualStrings(discovery_mod.schema, package.manifest.schema);
    try std.testing.expectEqual(@as(usize, files.len), package.manifest.resources.len);
    try std.testing.expect(package.declaredBytes() > 0);
    const bytes = try package.read(io, "room", allocator, 4096, &diagnostic);
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings(room_text, bytes);
    const event_bytes = try package.read(io, "battle_field_events", allocator, 4096, &diagnostic);
    defer allocator.free(event_bytes);
    try std.testing.expectEqualStrings(event_text, event_bytes);
    try std.testing.expectError(error.PackageRejected, package.read(io, "not_a_resource", allocator, 16, &diagnostic));
    try std.testing.expectEqual(discovery_mod.Code.resource_unknown, diagnostic.code);
}

test "a missing required declaration is rejected before any file is read" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try install(temp.dir, required[1..], .{});
    const root = try tempRoot(&temp);
    defer allocator.free(root);
    try expectCode(root, .resource_missing);
}

test "an id outside the compiled runtime table is rejected" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try install(temp.dir, &required, .{});
    const extra = Fixture{ .path = "extra.json", .id = "extra", .bytes = "{}" };
    try writeFile(temp.dir, extra.path, extra.bytes);
    var files = std.ArrayList(Fixture).empty;
    try files.appendSlice(allocator, &required);
    try files.append(allocator, extra);
    defer files.deinit(allocator);
    try install(temp.dir, files.items, .{});
    const root = try tempRoot(&temp);
    defer allocator.free(root);
    try expectCode(root, .resource_unknown);
}

test "a declared path that differs from the runtime path is rejected" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try install(temp.dir, &required, .{});
    const entries = try resourceEntries(&required);
    defer freeEntries(entries);
    entries[0].path = "room-alt.json";
    const bytes = try manifestJson(.{}, entries);
    defer allocator.free(bytes);
    try writeFile(temp.dir, "room-alt.json", room_text);
    try writeFile(temp.dir, "manifest.json", bytes);
    const root = try tempRoot(&temp);
    defer allocator.free(root);
    try expectCode(root, .resource_path_mismatch);
}

test "duplicate ids and paths are rejected" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const entries = try resourceEntries(&required);
    defer freeEntries(entries);
    var duplicated = try allocator.alloc(discovery_mod.Resource, required.len + 1);
    defer allocator.free(duplicated);
    @memcpy(duplicated[0..required.len], entries);
    duplicated[required.len] = entries[0];
    duplicated[required.len].sha256 = entries[0].sha256;
    const bytes = try manifestJson(.{}, duplicated);
    defer allocator.free(bytes);
    for (required) |file| try writeFile(temp.dir, file.path, file.bytes);
    try writeFile(temp.dir, "manifest.json", bytes);
    const root = try tempRoot(&temp);
    defer allocator.free(root);
    try expectCode(root, .resource_duplicate);
}

test "a declared file missing from the directory is named" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try install(temp.dir, &required, .{});
    try temp.dir.deleteFile(io, "atlas.png");
    const root = try tempRoot(&temp);
    defer allocator.free(root);
    try expectCode(root, .resource_file_missing);
}

test "a truncated file reports the declared and actual size" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try install(temp.dir, &required, .{});
    try writeFile(temp.dir, "journey.json", journey_text[0 .. journey_text.len - 1]);
    const root = try tempRoot(&temp);
    defer allocator.free(root);
    try expectCode(root, .resource_size_mismatch);
}

test "same-size tampering is caught by the SHA-256 check" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try install(temp.dir, &required, .{});
    const tampered = try allocator.dupe(u8, journey_text);
    defer allocator.free(tampered);
    tampered[1] = 'X';
    try writeFile(temp.dir, "journey.json", tampered);
    const root = try tempRoot(&temp);
    defer allocator.free(root);
    try expectCode(root, .resource_hash_mismatch);
}

test "a content document with the wrong schema version is rejected before the loader" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const files = [_]Fixture{
        .{ .path = "room.json", .id = "room", .bytes = "{\"schema\":\"suikoden-room/1\"}" },
        .{ .path = "journey.json", .id = "journey", .bytes = journey_text },
        .{ .path = "battle/trial.json", .id = "battle_trial", .bytes = trial_text },
        .{ .path = "atlas.png", .id = "atlas", .bytes = png },
        .{ .path = "battle/actors.png", .id = "battle_actors", .bytes = png },
        .{ .path = "battle/floor.png", .id = "battle_floor", .bytes = png },
        .{ .path = "provenance.json", .id = "provenance", .bytes = room_provenance },
        .{ .path = "battle/provenance.json", .id = "battle_provenance", .bytes = battle_provenance },
        .{ .path = "NOTICE.txt", .id = "notice", .bytes = notice_text },
    };
    try install(temp.dir, &files, .{});
    const root = try tempRoot(&temp);
    defer allocator.free(root);
    try expectCode(root, .resource_schema_mismatch);
}

test "a package with an older content schema is rejected with the supported schema" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try install(temp.dir, &required, .{ .content_schema = "suikoden-journey/9" });
    const root = try tempRoot(&temp);
    defer allocator.free(root);
    try expectCode(root, .content_schema_unsupported);
}

test "a future package format is rejected without guessing" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try install(temp.dir, &required, .{ .format_version = 2 });
    const root = try tempRoot(&temp);
    defer allocator.free(root);
    try expectCode(root, .format_version_unsupported);
}

test "an unknown manifest schema is rejected" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try install(temp.dir, &required, .{ .schema = "suikoden-content-package/9" });
    const root = try tempRoot(&temp);
    defer allocator.free(root);
    try expectCode(root, .manifest_schema_unsupported);
}

test "a non-candidate package status is rejected" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try install(temp.dir, &required, .{ .status = "reviewed" });
    const root = try tempRoot(&temp);
    defer allocator.free(root);
    try expectCode(root, .package_status_unsupported);
}

test "malformed and oversized manifests are rejected" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try writeFile(temp.dir, "manifest.json", "{not json");
    const root = try tempRoot(&temp);
    defer allocator.free(root);
    try expectCode(root, .manifest_malformed);

    const oversized = try allocator.alloc(u8, 64 * 1024 + 1);
    defer allocator.free(oversized);
    @memset(oversized, ' ');
    try writeFile(temp.dir, "manifest.json", oversized);
    try expectCode(root, .manifest_too_large);
}

test "a manifest with an unknown field is rejected" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const entries = try resourceEntries(&required);
    defer freeEntries(entries);
    const Unexpected = struct {
        schema: []const u8,
        format_version: u32,
        content_schema: []const u8,
        content_version: []const u8,
        status: []const u8,
        resources: []const discovery_mod.Resource,
        surprise: bool,
    };
    const bytes = try std.json.Stringify.valueAlloc(allocator, Unexpected{
        .schema = discovery_mod.schema,
        .format_version = discovery_mod.format_version,
        .content_schema = discovery_mod.content_schema,
        .content_version = "test",
        .status = "candidate",
        .resources = entries,
        .surprise = true,
    }, .{});
    defer allocator.free(bytes);
    for (required) |file| try writeFile(temp.dir, file.path, file.bytes);
    try writeFile(temp.dir, "manifest.json", bytes);
    const root = try tempRoot(&temp);
    defer allocator.free(root);
    try expectCode(root, .manifest_malformed);
}

test "a notice without the required rights and provenance statements is rejected" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var files = std.ArrayList(Fixture).empty;
    try files.appendSlice(allocator, &required);
    defer files.deinit(allocator);
    files.items[files.items.len - 1].bytes = "private only\n";
    try install(temp.dir, files.items, .{});
    const root = try tempRoot(&temp);
    defer allocator.free(root);
    try expectCode(root, .notice_invalid);
}

test "provenance without sources is rejected" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var files = try allocator.dupe(Fixture, required[0..]);
    defer allocator.free(files);
    files[7].bytes = "{\"schema\":\"suikoden-journey-battle-provenance/1\",\"exporter\":\"x\",\"sources\":[]}";
    try install(temp.dir, files, .{});
    const root = try tempRoot(&temp);
    defer allocator.free(root);
    try expectCode(root, .provenance_invalid);
}

test "an undeclared regular file breaks the closed package" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try install(temp.dir, &required, .{});
    try writeFile(temp.dir, "sneaky.txt", "not declared");
    const root = try tempRoot(&temp);
    defer allocator.free(root);
    try expectCode(root, .resource_unlisted);
}

test "symlinked manifest and resources are rejected" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try install(temp.dir, &required, .{});
    const root = try tempRoot(&temp);
    defer allocator.free(root);

    try temp.dir.deleteFile(io, "manifest.json");
    try temp.dir.symLink(io, "journey.json", "manifest.json", .{});
    try expectCode(root, .manifest_symlink);
    try temp.dir.deleteFile(io, "manifest.json");
    try install(temp.dir, &required, .{});

    try temp.dir.deleteFile(io, "atlas.png");
    try temp.dir.symLink(io, "room.json", "atlas.png", .{});
    try expectCode(root, .resource_file_symlink);
}

test "content discovery uses explicit, environment and executable-relative roots in order" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const base = try tempRoot(&temp);
    defer allocator.free(base);

    try temp.dir.createDirPath(io, "bin");
    try temp.dir.createDirPath(io, "content");
    try writeFile(temp.dir, "content/room.json", room_text);
    const bin = try std.fs.path.join(allocator, &.{ base, "bin" });
    defer allocator.free(bin);
    const missing = try std.fs.path.join(allocator, &.{ base, "missing" });
    defer allocator.free(missing);
    const explicit = try std.fs.path.join(allocator, &.{ base, "content" });
    defer allocator.free(explicit);

    var diagnostic = discovery_mod.Diagnostic.init(allocator);
    defer diagnostic.deinit();
    var by_relative = try discovery_mod.discovery.contentRoot(allocator, io, .{ .executable_dir = bin }, &diagnostic);
    defer by_relative.deinit();
    try std.testing.expectEqual(discovery_mod.Source.executable_relative, by_relative.source);
    try std.testing.expect(std.mem.endsWith(u8, by_relative.path, "content"));

    var by_explicit = try discovery_mod.discovery.contentRoot(allocator, io, .{ .explicit = explicit, .executable_dir = bin }, &diagnostic);
    defer by_explicit.deinit();
    try std.testing.expectEqual(discovery_mod.Source.explicit, by_explicit.source);

    var by_environment = try discovery_mod.discovery.contentRoot(allocator, io, .{ .environment = explicit, .executable_dir = bin }, &diagnostic);
    defer by_environment.deinit();
    try std.testing.expectEqual(discovery_mod.Source.environment, by_environment.source);

    // A named but missing explicit root must fail, even though a sibling
    // content directory exists and is the executable-relative default.
    try std.testing.expectError(error.PackageRejected, discovery_mod.discovery.contentRoot(allocator, io, .{
        .explicit = missing,
        .executable_dir = bin,
    }, &diagnostic));
    try std.testing.expectEqual(discovery_mod.Code.content_root_missing, diagnostic.code);

    // A relative root is refused instead of being resolved against the cwd.
    try std.testing.expectError(error.PackageRejected, discovery_mod.discovery.contentRoot(allocator, io, .{
        .explicit = "content",
        .executable_dir = bin,
    }, &diagnostic));
    try std.testing.expectEqual(discovery_mod.Code.content_root_not_absolute, diagnostic.code);

    // The same no-fallback rule applies to an environment value.
    try std.testing.expectError(error.PackageRejected, discovery_mod.discovery.contentRoot(allocator, io, .{
        .environment = missing,
        .executable_dir = bin,
    }, &diagnostic));
    try std.testing.expectEqual(discovery_mod.Code.content_root_missing, diagnostic.code);

    // An executable directory with no adjacent content must fail; `missing/..`
    // would alias the real content directory, so use a disjoint directory.
    try temp.dir.createDirPath(io, "isolated/bin");
    const isolated_bin = try std.fs.path.join(allocator, &.{ base, "isolated/bin" });
    defer allocator.free(isolated_bin);
    try std.testing.expectError(error.PackageRejected, discovery_mod.discovery.contentRoot(allocator, io, .{
        .executable_dir = isolated_bin,
    }, &diagnostic));
    try std.testing.expectEqual(discovery_mod.Code.no_content_root, diagnostic.code);
}

test "macOS bundle layout is discovered from Contents/MacOS" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const base = try tempRoot(&temp);
    defer allocator.free(base);
    try temp.dir.createDirPath(io, "app/Contents/MacOS");
    try writeFile(temp.dir, "app/Contents/Resources/content/room.json", room_text);
    const macos = try std.fs.path.join(allocator, &.{ base, "app/Contents/MacOS" });
    defer allocator.free(macos);
    var diagnostic = discovery_mod.Diagnostic.init(allocator);
    defer diagnostic.deinit();
    var location = try discovery_mod.discovery.contentRoot(allocator, io, .{ .executable_dir = macos }, &diagnostic);
    defer location.deinit();
    try std.testing.expectEqual(discovery_mod.Source.bundle_resources, location.source);
    try std.testing.expect(std.mem.endsWith(u8, location.path, "Contents/Resources/content"));
}

test "user-data discovery is explicit first, then environment, then platform default" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const base = try tempRoot(&temp);
    defer allocator.free(base);
    const requested = try std.fs.path.join(allocator, &.{ base, "wanted" });
    defer allocator.free(requested);
    const from_env = try std.fs.path.join(allocator, &.{ base, "from-env" });
    defer allocator.free(from_env);

    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("HOME", base);
    try environment.put("SUIKODEN_USER_DATA", from_env);

    var diagnostic = discovery_mod.Diagnostic.init(allocator);
    defer diagnostic.deinit();
    var explicit = try discovery_mod.discovery.userDataRoot(allocator, io, .{
        .explicit = requested,
        .environment = from_env,
        .environ = &environment,
    }, &diagnostic);
    defer explicit.deinit();
    try std.testing.expectEqual(discovery_mod.Source.explicit, explicit.source);
    try std.testing.expect(std.mem.endsWith(u8, explicit.path, "wanted"));

    var by_env = try discovery_mod.discovery.userDataRoot(allocator, io, .{
        .environment = from_env,
        .environ = &environment,
    }, &diagnostic);
    defer by_env.deinit();
    try std.testing.expectEqual(discovery_mod.Source.environment, by_env.source);

    var by_default = try discovery_mod.discovery.userDataRoot(allocator, io, .{ .environ = &environment }, &diagnostic);
    defer by_default.deinit();
    try std.testing.expectEqual(discovery_mod.Source.platform_default, by_default.source);
}

test "overlapping content and user-data roots are refused" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const base = try tempRoot(&temp);
    defer allocator.free(base);
    const root = try std.fs.path.join(allocator, &.{ base, "pkg" });
    defer allocator.free(root);
    const nested = try std.fs.path.join(allocator, &.{ root, "save" });
    defer allocator.free(nested);
    const other = try std.fs.path.join(allocator, &.{ base, "other" });
    defer allocator.free(other);
    var diagnostic = discovery_mod.Diagnostic.init(allocator);
    defer diagnostic.deinit();
    try std.testing.expectError(error.PackageRejected, discovery_mod.discovery.validateSeparation(root, nested, &diagnostic));
    try std.testing.expectEqual(discovery_mod.Code.roots_overlap, diagnostic.code);
    try std.testing.expectError(error.PackageRejected, discovery_mod.discovery.validateSeparation(root, root, &diagnostic));
    try std.testing.expectEqual(discovery_mod.Code.roots_overlap, diagnostic.code);
    try discovery_mod.discovery.validateSeparation(root, other, &diagnostic);
    try std.testing.expect(diagnostic.isOk());
}

test "the user-data write probe disappears and leaves existing files alone" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const base = try tempRoot(&temp);
    defer allocator.free(base);
    try writeFile(temp.dir, "user/keep.txt", "keep");
    const user = try std.fs.path.join(allocator, &.{ base, "user" });
    defer allocator.free(user);
    var diagnostic = discovery_mod.Diagnostic.init(allocator);
    defer diagnostic.deinit();
    try discovery_mod.discovery.prepareUserData(allocator, io, user, &diagnostic);
    try std.testing.expect(diagnostic.isOk());
    const kept = try temp.dir.readFileAlloc(io, "user/keep.txt", allocator, .limited(16));
    defer allocator.free(kept);
    try std.testing.expectEqualStrings("keep", kept);
    var probe: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&probe, ".write-probe-0", .{});
    try std.testing.expectError(error.FileNotFound, temp.dir.openFile(io, name, .{}));
}

test "boot loads a validated package with a private user-data root" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const base = try tempRoot(&temp);
    defer allocator.free(base);
    try temp.dir.createDirPath(io, "content");
    var content_dir = try temp.dir.openDir(io, "content", .{});
    defer content_dir.close(io);
    try install(content_dir, &required, .{});
    const content = try std.fs.path.join(allocator, &.{ base, "content" });
    defer allocator.free(content);
    const user = try std.fs.path.join(allocator, &.{ base, "user" });
    defer allocator.free(user);

    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("HOME", base);
    var diagnostic = discovery_mod.Diagnostic.init(allocator);
    defer diagnostic.deinit();
    var loaded = try discovery_mod.boot(allocator, io, .{
        .content = .{ .explicit = content, .executable_dir = base },
        .user = .{ .explicit = user, .environ = &environment },
    }, &diagnostic);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("candidate", loaded.package.manifest.status);
    try std.testing.expect(std.mem.endsWith(u8, loaded.user.path, "user"));
}

test "open refuses a relative package root" {
    var diagnostic = discovery_mod.Diagnostic.init(allocator);
    defer diagnostic.deinit();
    try std.testing.expectError(error.PackageRejected, discovery_mod.open(allocator, io, "content", .{}, &diagnostic));
    try std.testing.expectEqual(discovery_mod.Code.content_root_not_absolute, diagnostic.code);
}

test "boot reports the package defect before touching an unusable user-data root" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const base = try tempRoot(&temp);
    defer allocator.free(base);
    try temp.dir.createDirPath(io, "content");
    var content_dir = try temp.dir.openDir(io, "content", .{});
    defer content_dir.close(io);
    for (required) |file| try writeFile(content_dir, file.path, file.bytes);
    try temp.dir.writeFile(io, .{ .sub_path = "not-a-directory", .data = "x" });
    const content = try std.fs.path.join(allocator, &.{ base, "content" });
    defer allocator.free(content);
    const user = try std.fs.path.join(allocator, &.{ base, "not-a-directory" });
    defer allocator.free(user);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("HOME", base);
    var diagnostic = discovery_mod.Diagnostic.init(allocator);
    defer diagnostic.deinit();
    // The package has no manifest: that is the first failure, before the
    // unusable user-data path is touched.
    try std.testing.expectError(error.PackageRejected, discovery_mod.boot(allocator, io, .{
        .content = .{ .explicit = content, .executable_dir = base },
        .user = .{ .explicit = user, .environ = &environment },
    }, &diagnostic));
    try std.testing.expectEqual(discovery_mod.Code.manifest_missing, diagnostic.code);
}

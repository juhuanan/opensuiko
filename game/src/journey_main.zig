const std = @import("std");
const rl = @import("raylib");
const boot = @import("journey_boot");
const frame = @import("journey_frame");
const opening_export = @import("opening_export");
const journey_content = @import("journey_content");
const persistence = @import("journey_persistence");
const war_mode = @import("war_mode");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 2 and std.mem.eql(u8, args[1], "--war-check")) {
        try war_mode.check(init);
        return;
    }
    if ((args.len == 2 or args.len == 3) and std.mem.eql(u8, args[1], "--war")) {
        try war_mode.run(init, if (args.len == 3) args[2] else null);
        return;
    }
    if (args.len == 4 and std.mem.eql(u8, args[1], "--export-opening")) {
        opening_export.run(init, args[2], args[3]) catch |err| {
            std.log.err("Opening export: {s}", .{@errorName(err)});
            return err;
        };
        return;
    }
    if (args.len == 3 and std.mem.eql(u8, args[1], "--check-content")) {
        var diagnostic: journey_content.Diagnostic = .{};
        var checked = boot.load(init, args[1..3], true, &diagnostic) catch |err| {
            if (diagnostic.cause != null) std.debug.print("ERROR: {s}: {s}\n", .{ diagnostic.path, @errorName(err) }) else std.debug.print("ERROR: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        defer checked.deinit();
        validateStrikeReactions(&checked.bundle) catch std.process.exit(1);
        frame.checkFieldAtlas(init.gpa, &checked) catch |err| {
            std.debug.print("ERROR: atlas.png: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        frame.checkSceneryAtlases(init.gpa, &checked) catch std.process.exit(1);
        frame.checkDiceAtlas(init.gpa, &checked) catch |err| {
            std.debug.print("ERROR: dice/faces.png: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        frame.checkDuelAtlas(init.gpa, &checked) catch |err| {
            std.debug.print("ERROR: duel/atlas.png: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        frame.checkCrossingAtlas(init.gpa, &checked) catch |err| {
            std.debug.print("ERROR: travel/crossing.png: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        frame.checkBattleImages(init.gpa, checked.path, checked.bundle.combat) catch std.process.exit(1);
        frame.checkBattlefieldAtlas(init.gpa, checked.path, checked.bundle.combat) catch |err| {
            std.debug.print("ERROR: battle/ground.png: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        frame.checkSpellAtlas(init.gpa, &checked) catch |err| {
            std.debug.print("ERROR: battle/spell_effects.png: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        std.debug.print("OK: {s} is a loadable content package\n", .{args[2]});
        return;
    }
    if ((args.len == 3 or args.len == 4) and std.mem.eql(u8, args[1], "--check-persistence")) {
        if (init.environ_map.get("SUIKODEN_USER_DATA") == null) return error.PersistenceRequiresUserDataOverride;
        const phase = std.meta.stringToEnum(persistence.CheckPhase, args[2]) orelse return error.InvalidArguments;
        var diagnostic: journey_content.Diagnostic = .{};
        var checked = try boot.load(init, args[2..], false, &diagnostic);
        defer checked.deinit();
        defer checked.state.releaseRestoredSave();
        try persistence.check(init, checked.save_path.?, &checked.state, phase);
        return;
    }
    if (args.len > 1 and std.mem.startsWith(u8, args[1], "--")) {
        std.log.err("Invalid headless command or missing argument", .{});
        return error.InvalidArguments;
    }
    var diagnostic: journey_content.Diagnostic = .{};
    run(init, args, &diagnostic) catch |err| {
        if (diagnostic.cause != null) {
            std.log.err("Content/startup ({s}): {s}", .{ diagnostic.path, @errorName(err) });
        } else std.log.err("Content/startup: {s}", .{@errorName(err)});
        if (err == error.WindowInitializationFailed or err == error.InvalidArguments) return err;
        try frame.showStartupError(err, diagnostic.path, diagnostic.cause);
        std.process.exit(1);
    };
}

fn validateStrikeReactions(bundle: *const journey_content.Bundle) !void {
    var missing_knockout = false;
    for (bundle.combat.enemies) |enemy| {
        if (!bundle.missingStrikeKnockout(enemy.id)) continue;
        std.debug.print("ERROR: battle/spells.json: MissingCounterKnockout for enemy '{s}'\n", .{enemy.id});
        missing_knockout = true;
    }
    if (missing_knockout) return error.MissingCounterKnockout;
}

fn run(init: std.process.Init, args: []const [:0]const u8, diagnostic: *journey_content.Diagnostic) !void {
    var boot_state = try boot.load(init, args, false, diagnostic);
    defer boot_state.deinit();
    validateStrikeReactions(&boot_state.bundle) catch |err| {
        diagnostic.* = .{ .path = "battle/spells.json", .cause = err };
        return err;
    };
    try frame.run(init, &boot_state);
}

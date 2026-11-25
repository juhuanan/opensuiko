//! Save/load slot orchestration for the journey launcher.
const std = @import("std");
const engine = @import("engine");
const pause = @import("pause_menu");

pub const CheckPhase = enum { write, load, recover };

pub fn check(init: std.process.Init, directory_path: []const u8, state: *engine.State, phase: CheckPhase) !void {
    const labels = [_][]const u8{ "Persistence backup", "Persistence primary" };
    if (phase == .write) {
        var directory = try std.Io.Dir.cwd().openDir(init.io, directory_path, .{ .iterate = true });
        defer directory.close(init.io);
        var entries = directory.iterate();
        if (try entries.next(init.io) != null) return error.PersistenceDirectoryMustBeEmpty;
        for (labels) |label| {
            state.elapsed_ticks += 60;
            _ = state.combat.random.random().int(u64);
            state.menu.save_label = try pause.save_slots.Label.init(label);
            for (0..pause.save_slots.count) |slot| {
                state.menu.save_slot = slot;
                try apply(init, directory_path, state, .save);
            }
        }
    } else {
        const generation: usize = if (phase == .recover) 0 else 1;
        var random = state.combat.random;
        const ticks = state.elapsed_ticks + (generation + 1) * 60;
        const status: @FieldType(pause.save_slots.Summary, "status") = if (phase == .recover) .backup else .ready;
        for (0..generation + 1) |_| _ = random.random().int(u64);
        try apply(init, directory_path, state, .inspect_saves);
        const summaries = state.menu.summaries;
        for (summaries, 0..) |summary, slot| {
            if (summary.status != status) return error.UnexpectedPersistenceSource;
            state.menu.save_slot = slot;
            try apply(init, directory_path, state, .load);
            if (!std.mem.eql(u8, state.save_name.text(), labels[generation]) or state.elapsed_ticks != ticks or
                !std.meta.eql(state.combat.random, random)) return error.PersistenceRoundTripMismatch;
        }
    }
    std.debug.print("OK: isolated persistence {s} across all three save slots\n", .{@tagName(phase)});
}

pub fn apply(init: std.process.Init, directory_path: []const u8, state: *engine.State, effect: pause.Effect) !void {
    if (effect == .inspect_saves) {
        const available = std.Io.Dir.cwd().openDir(init.io, directory_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                state.menu.summaries = pause.save_slots.emptySummaries();
                return;
            }
            return err;
        };
        defer available.close(init.io);
        state.menu.summaries = engine.summaries(init.io, init.gpa, available, state.*);
        return;
    }
    var directory = if (effect == .save) try std.Io.Dir.cwd().createDirPathOpen(init.io, directory_path, .{}) else try std.Io.Dir.cwd().openDir(init.io, directory_path, .{});
    defer directory.close(init.io);
    if (effect == .save) {
        try engine.saveSlot(init.io, init.gpa, directory, state.*, state.menu.save_slot, state.menu.save_label);
        state.save_name = state.menu.save_label;
    } else if (try engine.restoreSlotWithSource(init.io, init.gpa, directory, state, state.menu.save_slot) == .backup) {
        state.menu.notify("Recovered the previous save from backup.");
        return;
    }
    state.menu.notify(if (effect == .save) "Journey saved. Party and story progress retained." else "Journey restored. Party and story progress retained.");
}

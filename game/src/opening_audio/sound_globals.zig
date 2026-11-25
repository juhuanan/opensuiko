//! Bounded source sound-mode globals, without device or callback ownership.
//! Source bootstrap 800C55D0 calls 800C53C0(1); 800C966C skips
//! command 1 when GS+1B92 is zero. Commands 1 and 2 call mode 0 and 1
//! respectively. Host must authenticate BootInput against its retained boot
//! template; this type cannot authenticate that binding. The separate stream
//! ramp at 80179C0C belongs to another adapter.
const std = @import("std");
pub const boot_sha256 = "8f9f1b8651f3e5b868f1cd20c0575fdad5512830d02a54d14195d87d35c6d2e5".*;
pub const BootInput = struct { template_sha256: [64]u8, setting_1b92: u8 };
pub const Command = enum { mode_0_command_1, mode_1_command_2 };
pub const State = struct {
    boot: BootInput,
    mode_9be8: u8,
    adjustment_9c12: u16,
    revision: u64,
    receipt: u64,
};
pub const Proposal = struct { before: State, command: Command, after: State };
pub const Error = error{ InvalidBoot, InvalidState, StaleOrForged, Overflow };
fn same(a: State, b: State) bool {
    return std.meta.eql(a, b);
}
fn modeValues(s: *State, command: Command) void {
    switch (command) {
        .mode_0_command_1 => {
            s.mode_9be8 = 0;
            s.adjustment_9c12 = 0x37;
        },
        .mode_1_command_2 => {
            s.mode_9be8 = 1;
            s.adjustment_9c12 = 0x41;
        },
    }
}
pub const Owner = struct {
    state: State,
    pub fn init(boot: BootInput) Error!Owner {
        if (!std.mem.eql(u8, &boot.template_sha256, &boot_sha256) or boot.setting_1b92 != 0) return error.InvalidBoot;
        return .{ .state = .{ .boot = boot, .mode_9be8 = 1, .adjustment_9c12 = 0x41, .revision = 0, .receipt = 0 } };
    }
    pub fn restore(state: State) Error!Owner {
        _ = try init(state.boot);
        if (state.revision != state.receipt or
            !((state.mode_9be8 == 0 and state.adjustment_9c12 == 0x37) or (state.mode_9be8 == 1 and state.adjustment_9c12 == 0x41)) or
            (state.revision == 0 and state.mode_9be8 != 1)) return error.InvalidState;
        return .{ .state = state };
    }
    pub fn propose(self: Owner, command: Command) Error!Proposal {
        _ = try restore(self.state);
        var after = self.state;
        after.revision = std.math.add(u64, after.revision, 1) catch return error.Overflow;
        after.receipt = after.revision;
        modeValues(&after, command);
        return .{ .before = self.state, .command = command, .after = after };
    }
    pub fn commit(self: *Owner, proposal: Proposal) Error!void {
        if (!same(self.state, proposal.before)) return error.StaleOrForged;
        const expected = try self.propose(proposal.command);
        if (!same(expected.after, proposal.after)) return error.StaleOrForged;
        self.state = expected.after;
    }
};

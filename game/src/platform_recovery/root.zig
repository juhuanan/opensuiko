//! Cross-mode platform recovery.
//!
//! One coordinator object, owned by whatever loop is already running.  It does
//! not poll the platform, open a window, start a device or add a loop; it receives
//! already-sampled logical facts (focus, controller presence, a filtered
//! `controller.Output`, window size, audio readiness) and returns a safe logical
//! frame plus readable diagnostics.  A platform failure changes the logical
//! state only through the documented recovery path, never by silently
//! continuing with a stale resource.

const std = @import("std");
const controller = @import("pause_menu");
const settings = @import("pause_menu");
pub const diagnostic = @import("diagnostic.zig");
pub const input = @import("input.zig");
pub const audio = @import("audio.zig");
pub const display = @import("display.zig");
pub const mode = @import("mode.zig");

pub const Mode = mode.Mode;
pub const Lease = input.Lease;
/// The already-filtered logical frame the running loop hands to `frame`.
pub const Sample = controller.Output;
pub const Diagnostic = diagnostic.Diagnostic;
pub const SettingsValue = settings.Value;
pub const Canvas = display.Canvas;
pub const Window = display.Window;
pub const Layout = display.Layout;
pub const PreferenceSink = display.PreferenceSink;
pub const PreferenceResult = display.PreferenceResult;
pub const AudioBackend = audio.Backend;
pub const AudioOutcome = audio.Outcome;

pub const Recovery = struct {
    mode: Mode = .title,
    input: input.Gate = .{},
    audio: audio.Gate = .{},
    display: display.Policy = .{},
    last: ?Diagnostic = null,

    pub fn begin(self: *Recovery, next: Mode) input.Gate.Entry {
        const entry = self.input.enter(next);
        self.mode = next;
        return entry;
    }

    pub fn focus(self: *Recovery, focused: bool) void {
        self.input.setFocus(focused);
    }

    /// Report the sampled controller state once per frame.  `id` identifies the
    /// device; a new or vanished device closes the input gate until release.
    pub fn device(self: *Recovery, present: bool, id: ?i32) void {
        self.input.setDevice(present, id);
    }

    pub fn frame(self: *Recovery, out: controller.Output) controller.Output {
        return self.input.gate(out);
    }

    pub fn claim(self: *Recovery, next: Mode) !void {
        self.input.claim(next) catch |err| {
            self.last = diagnostic.describe(err);
            return err;
        };
        self.mode = next;
    }

    pub fn release(self: *Recovery, next: Mode) !void {
        self.input.release(next) catch |err| {
            self.last = diagnostic.describe(err);
            return err;
        };
    }

    pub fn attachAudio(self: *Recovery, backend: AudioBackend) void {
        self.audio.attach(backend);
    }

    pub fn setAudioReady(self: *Recovery, ready: bool) void {
        self.audio.setReady(ready);
    }

    pub fn detachAudio(self: *Recovery) void {
        self.audio.detach();
    }

    pub fn cue(self: *Recovery, value: u16) AudioOutcome {
        const out = self.audio.cue(value);
        if (out.diagnostic) |value_diag| self.last = value_diag;
        return out;
    }

    pub fn retryAudio(self: *Recovery) AudioOutcome {
        const out = self.audio.retry();
        if (out.diagnostic) |value_diag| self.last = value_diag;
        return out;
    }

    pub fn resumeAudio(self: *Recovery) AudioOutcome {
        const out = self.audio.resumeTrack();
        if (out.diagnostic) |value_diag| self.last = value_diag;
        return out;
    }

    /// Keep the last valid layout on an unsupported transient window size.
    pub fn layout(self: *Recovery, canvas: Canvas, window: Window) Layout {
        const value = self.display.layout(canvas, window);
        self.last = self.display.last_error;
        return value;
    }

    pub fn applyPreferences(self: *Recovery, current: settings.Value, next: settings.Value, sink: PreferenceSink) PreferenceResult {
        const result = display.applyPreferences(current, next, sink);
        if (result.diagnostic) |value_diag| self.last = value_diag;
        return result;
    }

    pub fn lastDiagnostic(self: *const Recovery) ?Diagnostic {
        return self.last;
    }

    /// Bounded, allocation-free status for a receipt or a log line.
    pub const Report = struct {
        mode: Mode,
        focused: bool,
        armed: bool,
        device_present: bool,
        mode_changes: u32,
        refocuses: u32,
        reconnects: u32,
        suppressed_confirms: u32,
        suppressed_directions: u32,
        audio_pending: bool,
        audio_leases: usize,
        audio_waived: u32,
        audio_failed: u32,
        display_invalid_frames: u32,
    };

    pub fn report(self: *const Recovery) Report {
        return .{
            .mode = self.mode,
            .focused = self.input.focused,
            .armed = self.input.armed,
            .device_present = self.input.device_present,
            .mode_changes = self.input.counters.mode_changes,
            .refocuses = self.input.counters.refocuses,
            .reconnects = self.input.counters.reconnects,
            .suppressed_confirms = self.input.counters.suppressed_confirms,
            .suppressed_directions = self.input.counters.suppressed_directions,
            .audio_pending = self.audio.pending != null,
            .audio_leases = self.audio.deviceLeases(),
            .audio_waived = self.audio.counters.waived,
            .audio_failed = self.audio.counters.failed,
            .display_invalid_frames = self.display.invalid_frames,
        };
    }
};

test "a fresh coordinator owns no input until a mode begins" {
    var recovery: Recovery = .{};
    const out = recovery.frame(.{});
    try std.testing.expect(out.direction == null and !out.confirm);
    _ = recovery.begin(.field);
    try std.testing.expectEqual(Mode.field, recovery.input.lease.owner);
}

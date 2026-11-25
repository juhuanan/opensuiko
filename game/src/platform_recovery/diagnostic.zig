//! Static, allocation-free failure text.  A platform adapter may fail without
//! aborting the mode; the caller renders `message` and keeps the last valid
//! logical state.

pub const Code = enum {
    input_owned,
    not_input_owner,
    invalid_owner,
    invalid_window_size,
    unsupported_window_size,
    fullscreen_rejected,
    vsync_rejected,
    unsupported_settings,
    audio_device_unavailable,
    audio_stream_unavailable,
};

pub const Diagnostic = struct {
    code: Code,
    message: []const u8,

    pub fn jsonStringify(self: Diagnostic, writer: anytype) !void {
        try writer.beginObject();
        try writer.objectField("code");
        try writer.write(@tagName(self.code));
        try writer.objectField("message");
        try writer.write(self.message);
        try writer.endObject();
    }
};

pub fn of(code: Code) Diagnostic {
    return .{ .code = code, .message = switch (code) {
        .input_owned => "Input is already owned by another mode; release that lease before entering this one.",
        .not_input_owner => "This caller does not own the input lease; the current mode was left unchanged.",
        .invalid_owner => "A mode must be named to own input; the none owner cannot be acquired.",
        .invalid_window_size => "The window size is outside the supported range (1..16384 on each axis).",
        .unsupported_window_size => "The window is smaller than the smallest supported canvas; the last valid layout was kept.",
        .fullscreen_rejected => "The platform rejected the fullscreen change; the previous display state was restored.",
        .vsync_rejected => "The platform rejected the vsync change; the previous display state was restored.",
        .unsupported_settings => "The settings value is not valid for this build; the previous value was kept.",
        .audio_device_unavailable => "No audio device is available. The cue was kept as a waiver and no playback was claimed.",
        .audio_stream_unavailable => "The audio stream could not start. The cue stays retryable and no track is claimed.",
    } };
}

pub fn describe(err: anyerror) Diagnostic {
    return of(switch (err) {
        error.InputOwned => .input_owned,
        error.NotInputOwner => .not_input_owner,
        error.InvalidOwner => .invalid_owner,
        error.InvalidWindowSize => .invalid_window_size,
        error.UnsupportedWindowSize => .unsupported_window_size,
        error.UnsupportedSettings => .unsupported_settings,
        error.AudioDeviceUnavailable => .audio_device_unavailable,
        error.AudioStreamUnavailable => .audio_stream_unavailable,
        else => .unsupported_settings,
    });
}

//! Source-backed event control-flow helpers for Opening first-town.
//!
//! MAIN.EXE `switch_on_ui_mode_labels` @0x8013A484: selector byte, n = sel & 0x3F,
//! base = T + n - 1 where T is the byte after the selector; the n-1 bytes after T
//! are raw labels. Each label's displacement is found by searching from base+1.
//! Stack word 0 is zero (default), and the selected word is word[mode] when
//! bit 0x80 is set, otherwise word[mode-1].
//!
//! `scan_forward_label` @0x8013A604 searches forward for an operand byte and
//! leaves the cursor after the match. Both are cursor/branch operations, not
//! area state.
const std = @import("std");

pub const FlowError = error{ MissingSelector, MissingLabel, LabelOutOfRange };

/// Source 0x2E: return the index just after the first matching byte, or null.
pub fn scanForward(stream: []const u8, start: usize, byte: u8) ?usize {
    if (start >= stream.len) return null;
    for (stream[start..], start..) |value, index| {
        if (value == byte) return index + 1;
    }
    return null;
}

/// Source 0x2F: resolve a mode-selected label displacement.
pub fn switchTarget(stream: []const u8, start: usize, mode: u8) FlowError!usize {
    if (start >= stream.len) return error.MissingSelector;
    const selector = stream[start];
    const count = selector & 0x3F;
    if (count == 0) return error.MissingLabel;
    const table_start = start + 1;
    const header_len = count - 1;
    if (table_start + header_len > stream.len) return error.LabelOutOfRange;
    const base = table_start + header_len - 1;
    if (base >= stream.len) return error.LabelOutOfRange;
    const labels = stream[table_start .. table_start + header_len];
    const selected: usize = if (selector & 0x80 != 0) mode else if (mode == 0) 0 else mode - 1;
    if (selected == 0) return base;
    if (selected > labels.len) return error.MissingLabel;
    const label = labels[selected - 1];
    const match = scanForward(stream, base + 1, label) orelse return error.MissingLabel;
    return match;
}

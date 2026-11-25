//! Source text engine: fixed-cell grid, paging, reveal, substitutions.
//!
//! The engine follows the MAIN text-object path (0x80146BB4/0x8014695C):
//! one code per normal pass, a pace+1 glyph cadence, a fast pass with an
//! unlimited budget, a page-wait flag that is acknowledged without moving the
//! stream cursor, and the 0x04/0x05/0x06/0x07/0x08 control operands. The grid
//! is the fixed 30x5 shape the box allocator requests; the mode-0 variable
//! width path is explicitly out of scope in the packet.
//!
//! The engine owns no art, audio, native frame or allocation. Callers provide
//! the substitution values (player name, castle name, number sources) and copy
//! the engine's plain state for a restore.

const std = @import("std");
const model = @import("model.zig");

pub const max_body = 0x385;
pub const max_columns = 30;
pub const max_rows = 5;
pub const max_visible = max_rows * max_columns + max_rows;

pub const Cell = struct {
    glyph: u8 = 0x10,
    colour: u8 = 0,
    emphasis: bool = false,
};

pub const Grid = struct {
    cells: [max_rows][max_columns]Cell = @splat(@splat(Cell{})),
    column: u8 = 0,
    row: u8 = 0,
    scrolls: u16 = 0,
};

pub const Substitutions = struct {
    player_name: []const u8 = "",
    castle_name: []const u8 = "",
    numbers: []const u32 = &.{},
};

pub const Ack = enum { none, page, accelerate, restore, reset };

pub const Engine = struct {
    bytes: [max_body]u8 = @splat(0),
    len: u16 = 0,
    cursor: u16 = 0,
    grid: Grid = .{},
    page_index: u8 = 0,
    page_wait: bool = false,
    done: bool = true,
    countdown: u8 = 0,
    pace: u8 = 0,
    pace_normal: u8 = 0,
    pace_pressed: u8 = 0,
    fast: bool = false,
    colour: u8 = 0,
    emphasis: bool = false,

    pub fn begin(self: *Engine, body: []const u8, pace_normal: u8, pace_pressed: u8) !void {
        if (body.len == 0 or body.len > max_body) return error.BodyTooLarge;
        self.* = .{};
        @memcpy(self.bytes[0..body.len], body);
        self.len = @intCast(body.len);
        self.pace = pace_normal;
        self.pace_normal = pace_normal;
        self.pace_pressed = pace_pressed;
        self.done = false;
    }

    /// True while the body still owns the event gate (including a page wait).
    pub fn busy(self: *const Engine) bool {
        return !self.done;
    }

    pub fn bytesSlice(self: *const Engine) []const u8 {
        return self.bytes[0..self.len];
    }

    /// One source glyph pass. A normal pass consumes one countdown and one
    /// interpreter call; a requested fast pass consumes the countdown no further
    /// and runs one unlimited interpreter call, then clears the request.
    pub fn tick(self: *Engine, pipeline: *const model.Pipeline, subs: Substitutions) !void {
        if (self.done or self.page_wait) return;
        const unlimited = self.fast;
        self.fast = false;
        if (!unlimited) {
            self.countdown -%= 1;
            if (self.countdown != 0xFF) return;
        }
        try self.interpret(pipeline, subs, if (unlimited) 0 else 1);
        if (!unlimited) self.countdown = self.pace;
        // The source updater checks the byte at the returned cursor after the
        // interpreter call: a zero terminator completes the body in the same
        // pass that drew its last glyph.
        if (!self.page_wait and (self.cursor >= self.len or self.bytes[self.cursor] == 0)) {
            self.cursor = self.len;
            self.done = true;
        }
    }

    fn operand(self: *Engine) !u8 {
        // The source copies the body into a zeroed staging buffer and stops at
        // the source NUL, so a control whose operand is the terminator reads
        // the implicit zero sentinel. That is what makes a trailing 0x06 select
        // the player name and then terminate instead of running into the pool.
        if (self.cursor > self.len) return error.TruncatedControl;
        const value: u8 = if (self.cursor == self.len) 0 else self.bytes[self.cursor];
        self.cursor += 1;
        return value;
    }

    fn interpret(self: *Engine, pipeline: *const model.Pipeline, subs: Substitutions, budget: u8) !void {
        _ = pipeline;
        while (true) {
            if (self.cursor >= self.len) {
                self.cursor = self.len;
                self.done = true;
                return;
            }
            const code = self.bytes[self.cursor];
            self.cursor += 1;
            switch (code) {
                0 => {
                    self.cursor = self.len;
                    self.done = true;
                    return;
                },
                1, 3 => {
                    if (self.newline()) return;
                },
                2 => {
                    self.page_wait = true;
                    return;
                },
                4 => self.pace = try self.operand(),
                5 => {
                    self.countdown = try self.operand();
                    return;
                },
                6 => {
                    const selector = try self.operand();
                    try self.nested(selector, subs);
                },
                7 => {
                    const source = try self.operand();
                    const width = try self.operand();
                    try self.number(source, width, subs);
                },
                8 => self.colour = try self.operand(),
                9...14 => {},
                15 => self.clearGrid(),
                16 => try self.putGlyph(0x10),
                else => {
                    if (code == 0x51) {
                        self.emphasis = !self.emphasis;
                    } else {
                        if (asciiOf(code) == null) return error.UnsupportedControl;
                        try self.putGlyph(code);
                    }
                },
            }
            if (budget == 1) return;
        }
    }

    fn newline(self: *Engine) bool {
        self.grid.column = 0;
        if (self.grid.row + 1 >= max_rows) {
            self.scroll();
            self.grid.row = max_rows - 1;
            return true; // the source stops the pass after a bottom scroll
        }
        self.grid.row += 1;
        return false;
    }

    fn scroll(self: *Engine) void {
        var row: usize = 0;
        while (row + 1 < max_rows) : (row += 1) {
            self.grid.cells[row] = self.grid.cells[row + 1];
        }
        self.grid.cells[max_rows - 1] = @splat(Cell{});
        self.grid.scrolls +%= 1;
    }

    fn clearGrid(self: *Engine) void {
        self.grid.cells = @splat(@splat(Cell{}));
        self.grid.column = 0;
        self.grid.row = 0;
    }

    fn putGlyph(self: *Engine, code: u8) !void {
        if (self.grid.column >= max_columns) return error.LineOverflow;
        self.grid.cells[self.grid.row][self.grid.column] = .{
            .glyph = code,
            .colour = self.colour,
            .emphasis = self.emphasis,
        };
        self.grid.column += 1;
    }

    fn nested(self: *Engine, selector: u8, subs: Substitutions) !void {
        const value = switch (selector) {
            0 => subs.player_name,
            1 => subs.castle_name,
            else => return error.UnsupportedSubstitution,
        };
        if (value.len > 8) return error.SubstitutionTooLong;
        for (value) |code| {
            if (code == 0x51) {
                self.emphasis = !self.emphasis;
                continue;
            }
            if (asciiOf(code) == null) return error.UnsupportedNestedByte;
            try self.putGlyph(code);
        }
    }

    fn number(self: *Engine, source: u8, width: u8, subs: Substitutions) !void {
        if (width < 1 or width > 5) return error.UnsupportedNumberWidth;
        if (source >= subs.numbers.len) return error.UnsupportedNumberSource;
        var text: [5]u8 = @splat(' ');
        var remaining: u32 = subs.numbers[source] % 100000;
        var index: usize = 5;
        if (remaining == 0) {
            index = 4;
            text[4] = '0';
        } else {
            while (remaining > 0 and index > 0) {
                index -= 1;
                text[index] = @intCast('0' + remaining % 10);
                remaining /= 10;
            }
        }
        const start = 5 - @as(usize, width);
        for (text[start..5]) |digit| {
            const code: u8 = if (digit == ' ') 0x10 else @intCast(0x45 + (digit - '0'));
            try self.putGlyph(code);
        }
    }

    /// Source acknowledgement: a page wait clears the grid and retains the
    /// stream cursor; while revealing, a press toggles pressed/normal pacing
    /// and requests one unlimited pass.
    pub fn acknowledge(self: *Engine, pipeline: *const model.Pipeline, mask: u16) Ack {
        if (self.page_wait) {
            if (mask & pipeline.page.ack_mask == 0) return .none;
            self.clearGrid();
            self.page_wait = false;
            self.page_index +%= 1;
            return .page;
        }
        if (self.done) return .none;
        if (mask & pipeline.reveal.mask != 0) {
            if (self.pace == self.pace_pressed) {
                self.pace = self.pace_normal;
                return .restore;
            }
            self.pace = self.pace_pressed;
            self.fast = true;
            return .accelerate;
        }
        self.pace = self.pace_normal;
        return .reset;
    }

    /// Flatten the grid rows, trimming trailing blanks. This is the same
    /// projection the focused test compares with the generator's page plan.
    pub fn writeVisible(self: *const Engine, out: *[max_visible]u8) []const u8 {
        var last_row: ?usize = null;
        var row: usize = 0;
        while (row < max_rows) : (row += 1) {
            var column: usize = 0;
            while (column < max_columns) : (column += 1) {
                const cell = self.grid.cells[row][column];
                if (cell.glyph != 0x10 and cell.glyph != 0x51) {
                    last_row = row;
                    break;
                }
            }
        }
        var length: usize = 0;
        const stop = last_row orelse return out[0..0];
        row = 0;
        while (row <= stop) : (row += 1) {
            var last_column: usize = 0;
            var column: usize = 0;
            while (column < max_columns) : (column += 1) {
                const cell = self.grid.cells[row][column];
                if (cell.glyph != 0x10 and cell.glyph != 0x51) last_column = column + 1;
            }
            column = 0;
            while (column < last_column) : (column += 1) {
                const glyph = self.grid.cells[row][column].glyph;
                if (glyph == 0x51) continue;
                if (length >= out.len) return out[0..length];
                out[length] = asciiOf(glyph) orelse '?';
                length += 1;
            }
            if (row != stop) {
                if (length >= out.len) return out[0..length];
                out[length] = '\n';
                length += 1;
            }
        }
        return out[0..length];
    }
};

/// The frozen single-byte table. 0x51 is zero-width; the fixed-cell source
/// writer advances a cell for it, which the packet records as an unresolved
/// mode-0 detail and the port projects as a zero-width emphasis toggle.
pub fn asciiOf(code: u8) ?u8 {
    if (code == 0x10) return ' ';
    if (code >= 0x11 and code <= 0x2A) return @intCast('a' + code - 0x11);
    if (code >= 0x2B and code <= 0x44) return @intCast('A' + code - 0x2B);
    if (code >= 0x45 and code <= 0x4E) return @intCast('0' + code - 0x45);
    return switch (code) {
        0x53 => '\'',
        0x55 => ',',
        0x56 => '.',
        0x57 => '!',
        0x58 => '?',
        0x59 => '[',
        0x5A => ']',
        0x5C => '-',
        else => null,
    };
}

pub fn encodeAscii(text: []const u8, out: []u8) ![]const u8 {
    if (text.len > out.len) return error.BufferTooSmall;
    for (text, 0..) |character, index| {
        out[index] = switch (character) {
            ' ' => 0x10,
            'a'...'z' => @intCast(0x11 + character - 'a'),
            'A'...'Z' => @intCast(0x2B + character - 'A'),
            '0'...'9' => @intCast(0x45 + character - '0'),
            '\'' => 0x53,
            ',' => 0x55,
            '.' => 0x56,
            '!' => 0x57,
            '?' => 0x58,
            '[' => 0x59,
            ']' => 0x5A,
            '-' => 0x5C,
            else => return error.UnsupportedCharacter,
        };
    }
    return out[0..text.len];
}

pub fn decodeHex(hex: []const u8, out: []u8) ![]const u8 {
    if (hex.len % 2 != 0 or hex.len / 2 > out.len) return error.InvalidHex;
    var index: usize = 0;
    while (index < hex.len) : (index += 2) {
        const high = std.fmt.charToDigit(hex[index], 16) catch return error.InvalidHex;
        const low = std.fmt.charToDigit(hex[index + 1], 16) catch return error.InvalidHex;
        out[index / 2] = high * 16 + low;
    }
    return out[0 .. hex.len / 2];
}

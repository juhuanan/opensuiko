//! Logical session contract for the optional KARUTA pair board game.

const draws_mod = @import("battle_rules");
const rules_mod = @import("optional_game_rules.zig");
const KarutaRules = rules_mod.KarutaRules;
pub const host_rejection_budget = rules_mod.host_rejection_budget;

pub const face_count = 108;
pub const cell_count = 48;
pub const board_rows = 8;
pub const board_columns = 6;

pub const KarutaCellState = enum(u8) {
    face_up = 0,
    face_down = 1,
    flip_face_out = 2,
    flip_back_in = 3,
    flip_back_out = 4,
    flip_face_in = 5,
    matched_scale_in = 6,
    matched_scale_out = 7,
    matched_fade = 8,
    resolving = 9,
    empty = 10,
};

pub const KarutaCell = struct {
    face: u8 = 109,
    state: KarutaCellState = .empty,
    timer: u8 = 0,
    /// Neighbour-mark flag: a flipped-up card that must resolve (source +8).
    touched: bool = false,
    /// Selected-hint flag: a caller-supplied brief reveal (source +9).
    selected: bool = false,
};

pub const KarutaPhase = enum(u8) { select, dealing, play, proposal, acknowledged, exited };
pub const KarutaCompletion = enum { round_complete, record, flag, round_selected, exited };
pub const KarutaConsequence = enum(u8) { none, story_flag };

pub const KarutaEntry = struct {
    entry_id: u64,
    content_id: u64,
    receipt_id: u64,
    round: u8,
    balance: u32,
    best: [4]u32,
    flags: u32,
};

pub const KarutaResult = struct {
    entry_id: u64,
    content_id: u64,
    receipt_id: u64,
    round: u8,
    identities: u8,
    elapsed: u32,
    best_before: u32,
    best_after: u32,
    record: bool,
    flag_set: bool,
    consequence: KarutaConsequence,
};

pub const KarutaSession = struct {
    version: u8 = 1,
    rules: KarutaRules,
    entry_id: u64,
    content_id: u64,
    receipt_id: u64,
    round: u8,
    balance: u32,
    best: [4]u32,
    flags: u32,
    phase: KarutaPhase,
    cells: [cell_count]KarutaCell = @splat(.{}),
    cursor_row: u8 = 3,
    cursor_column: u8 = 2,
    deal_cursor: u8 = 0,
    first: ?u8 = null,
    second: ?u8 = null,
    compare_pending: bool = false,
    elapsed: u32 = 0,
    flag_set: bool = false,
    consequence: KarutaConsequence = .none,

    pub fn init(rules: KarutaRules, entry: KarutaEntry) !KarutaSession {
        if (entry.entry_id == 0 or entry.content_id == 0 or entry.receipt_id == 0) return error.InvalidEntry;
        if (entry.round > rules.quit_round) return error.InvalidEntry;
        if (entry.balance > rules.balance_cap) return error.InvalidEntry;
        var session = KarutaSession{
            .rules = rules,
            .entry_id = entry.entry_id,
            .content_id = entry.content_id,
            .receipt_id = entry.receipt_id,
            .round = entry.round,
            .balance = entry.balance,
            .best = entry.best,
            .flags = entry.flags,
            .phase = .select,
        };
        try session.validate();
        return session;
    }

    pub fn validate(self: KarutaSession) !void {
        if (self.version != 1) return error.InvalidState;
        if (self.round > self.rules.quit_round) return error.InvalidState;
        if (self.balance > self.rules.balance_cap) return error.InvalidState;
        if (self.cursor_row >= self.rules.rows or self.cursor_column >= self.rules.columns) return error.InvalidState;
        if (self.deal_cursor > self.rules.cells) return error.InvalidState;
        if (self.elapsed > self.rules.moves_cap) return error.InvalidState;
        if (self.first) |index| {
            if (index >= cell_count) return error.InvalidState;
        }
        if (self.second) |index| {
            if (index >= cell_count) return error.InvalidState;
        }
        for (self.cells) |cell| {
            if (cell.face != self.rules.empty_face and cell.face >= self.rules.faces and cell.face != self.rules.back_face) return error.InvalidState;
            if (@backingInt(cell.state) > @backingInt(KarutaCellState.empty)) return error.InvalidState;
            if (cell.timer > self.rules.resolve_frames) return error.InvalidState;
        }
        switch (self.phase) {
            .select => {
                if (self.first != null or self.second != null or self.compare_pending) return error.InvalidState;
            },
            .dealing => {
                if (self.first != null or self.second != null) return error.InvalidState;
            },
            .play => {
                if (self.deal_cursor != self.rules.cells) return error.InvalidState;
            },
            .proposal, .acknowledged => {
                if (self.compare_pending) return error.InvalidState;
                if (!self.boardComplete()) return error.InvalidState;
            },
            .exited => {},
        }
    }

    pub fn storage(row: u8, column: u8) usize {
        return @as(usize, row) * board_columns + column;
    }

    /// The source linear index: columns of eight rows, `column*8+row`.
    pub fn linearIndex(row: u8, column: u8) u8 {
        return column * board_rows + row;
    }

    pub fn roundIdentities(self: KarutaSession) u8 {
        if (self.round >= self.rules.rounds.len) return 0;
        return self.rules.rounds[self.round].identities;
    }

    pub fn selectRound(self: *KarutaSession, delta: i8) !void {
        if (self.phase != .select) return error.InvalidPhase;
        var next = self.*;
        const count: i8 = @intCast(self.rules.quit_round + 1);
        var value: i8 = @as(i8, @intCast(next.round)) + delta;
        while (value < 0) value += count;
        while (value >= count) value -= count;
        next.round = @intCast(value);
        next.flag_set = false;
        next.consequence = .none;
        try next.validate();
        self.* = next;
    }

    pub fn confirmRound(self: *KarutaSession, eligible: *const [face_count]bool, draws: *draws_mod.Draws) !void {
        if (self.phase != .select) return error.InvalidPhase;
        if (self.round == self.rules.quit_round) {
            try self.exit();
            return;
        }
        try self.deal(eligible, draws);
    }

    /// Deal the selected round. `eligible` is the caller's face availability
    /// table (the source reads one from field context); it is required, never
    /// defaulted. Duplicate identities, out-of-range identities, off-board
    /// draws and occupied cells all retry exactly like the source.
    pub fn deal(self: *KarutaSession, eligible: *const [face_count]bool, draws: *draws_mod.Draws) !void {
        if (self.phase != .select) return error.InvalidPhase;
        if (self.round == self.rules.quit_round) return error.RoundQuits;
        const identities_count = self.roundIdentities();
        if (identities_count == 0 or identities_count > 15) return error.InvalidContracts;
        var available: usize = 0;
        for (eligible) |is_eligible| {
            if (is_eligible) available += 1;
        }
        if (available < identities_count) return error.InsufficientEligibleFaces;
        var next = self.*;
        var random = draws.*;
        var identities: [15]u8 = undefined;
        var chosen: usize = 0;
        var rejections: usize = 0;
        while (chosen < identities_count) {
            if (rejections == host_rejection_budget) return error.RejectionBudget;
            const divisor: u16 = @intCast(self.rules.identity_divisor);
            const candidate = @as(u16, try random.next()) / divisor;
            if (candidate >= @as(u16, self.rules.faces) or !eligible[@intCast(candidate)]) {
                rejections += 1;
                continue;
            }
            var duplicate = false;
            for (identities[0..chosen]) |previous| {
                if (previous == @as(u8, @intCast(candidate))) duplicate = true;
            }
            if (duplicate) {
                rejections += 1;
                continue;
            }
            identities[chosen] = @intCast(candidate);
            chosen += 1;
        }
        next.cells = @splat(.{});
        next.deal_cursor = 0;
        next.first = null;
        next.second = null;
        next.compare_pending = false;
        next.elapsed = 0;
        next.flag_set = false;
        next.consequence = .none;
        var pairs: usize = 0;
        while (pairs < self.rules.pairs) : (pairs += 1) {
            const identity = identities[pairs % identities_count];
            var placed: usize = 0;
            while (placed < 2) {
                if (rejections == host_rejection_budget) return error.RejectionBudget;
                const row_divisor: u16 = @intCast(self.rules.row_divisor);
                const column_divisor: u16 = @intCast(self.rules.column_divisor);
                const row = @as(u16, try random.next()) / row_divisor;
                const column = @as(u16, try random.next()) / column_divisor;
                if (row >= @as(u16, self.rules.rows) or column >= @as(u16, self.rules.columns)) {
                    rejections += 1;
                    continue;
                }
                const index = storage(@intCast(row), @intCast(column));
                if (next.cells[index].face != self.rules.empty_face) {
                    rejections += 1;
                    continue;
                }
                next.cells[index].face = identity;
                placed += 1;
            }
        }
        next.phase = .dealing;
        try next.validate();
        self.* = next;
        draws.* = random;
    }

    /// The source completion check: every cell is empty (state 10). A card
    /// still face down or mid-animation keeps the round running.
    pub fn boardComplete(self: KarutaSession) bool {
        for (self.cells) |cell| {
            if (cell.state != .empty) return false;
        }
        return true;
    }

    /// True once the deal animation placed a card in every cell.
    pub fn boardDealt(self: KarutaSession) bool {
        for (self.cells) |cell| {
            if (cell.state == .empty) return false;
        }
        return true;
    }

    pub fn boardStable(self: KarutaSession) bool {
        for (self.cells) |cell| {
            if (isTransient(cell.state)) return false;
        }
        return true;
    }

    fn isTransient(state: KarutaCellState) bool {
        return switch (state) {
            .flip_face_out, .flip_back_in, .flip_back_out, .flip_face_in, .matched_scale_in, .matched_scale_out, .matched_fade, .resolving => true,
            else => false,
        };
    }

    /// One displayed frame. Presentation calls this only while the game is
    /// actually animating, which is the completion gate for the deal, the card
    /// flips, the matched removal and the neighbour resolution.
    pub fn advance(self: *KarutaSession) !void {
        var next = self.*;
        switch (self.phase) {
            .dealing => {
                if (next.deal_cursor < self.rules.cells) {
                    const row = next.deal_cursor % board_rows;
                    const column = next.deal_cursor / board_rows;
                    const index = storage(row, column);
                    next.cells[index].state = .flip_back_in;
                    next.cells[index].timer = 0;
                    next.deal_cursor += 1;
                }
                advanceCells(&next);
                if (next.deal_cursor == self.rules.cells and allState(next.cells, .face_down)) {
                    next.cursor_row = 3;
                    next.cursor_column = 2;
                    next.elapsed = 0;
                    next.phase = .play;
                }
                try next.validate();
                self.* = next;
            },
            .play => {
                // The source increments its counter once per frame in the play
                // phases; the value is the round's elapsed budget.
                if (next.elapsed < self.rules.moves_cap) next.elapsed += 1;
                advanceCells(&next);
                if (next.compare_pending) resolveComparison(&next);
                if (next.boardComplete() and next.boardStable()) {
                    next.phase = .proposal;
                }
                try next.validate();
                self.* = next;
            },
            else => {},
        }
    }

    pub fn moveCursor(self: *KarutaSession, delta_row: i8, delta_column: i8) !void {
        if (self.phase != .play) return error.InvalidPhase;
        if (!self.boardStable()) return error.PresentationBusy;
        var next = self.*;
        const rows: i8 = @intCast(self.rules.rows);
        const columns: i8 = @intCast(self.rules.columns);
        var row: i8 = @as(i8, @intCast(next.cursor_row)) + delta_row;
        var column: i8 = @as(i8, @intCast(next.cursor_column)) + delta_column;
        while (row < 0) row += rows;
        while (row >= rows) row -= rows;
        while (column < 0) column += columns;
        while (column >= columns) column -= columns;
        next.cursor_row = @intCast(row);
        next.cursor_column = @intCast(column);
        try next.validate();
        self.* = next;
    }

    pub fn cursorIndex(self: KarutaSession) usize {
        return storage(self.cursor_row, self.cursor_column);
    }

    /// Select or deselect the cursor cell, exactly like the source toggle: a
    /// face-down card turns up, a face-up selected card turns back down. The
    /// second face-down selection starts the comparison. A busy board (any
    /// transient card) is a paused-animation gate: nothing changes.
    pub fn confirm(self: *KarutaSession) !void {
        if (self.phase != .play) return error.InvalidPhase;
        if (!self.boardStable()) return error.PresentationBusy;
        const index = self.cursorIndex();
        const state = self.cells[index].state;
        if (state != .face_down and state != .face_up) return error.CellNotSelectable;
        var next = self.*;
        if (state == .face_up) {
            // Cancel a previous selection by turning the card back down.
            next.cells[index].state = .flip_face_out;
            next.cells[index].timer = 0;
            if (next.first == @as(u8, @intCast(index))) {
                next.first = null;
            }
            if (next.second == @as(u8, @intCast(index))) {
                next.second = null;
            }
            next.compare_pending = next.first != null and next.second != null;
            try next.validate();
            self.* = next;
            return;
        }
        next.cells[index].state = .flip_back_out;
        next.cells[index].timer = 0;
        next.cells[index].touched = false;
        if (next.first == null) {
            next.first = @intCast(index);
            next.second = null;
            next.compare_pending = false;
        } else {
            next.second = @intCast(index);
            next.compare_pending = true;
        }
        try next.validate();
        self.* = next;
    }

    fn resolveComparison(session: *KarutaSession) void {
        const first = session.first orelse return;
        const second = session.second orelse return;
        if (session.cells[first].state != .face_up or session.cells[second].state != .face_up) return;
        if (session.cells[first].face == session.cells[second].face) {
            session.cells[first].state = .matched_scale_in;
            session.cells[first].timer = 0;
            session.cells[second].state = .matched_scale_in;
            session.cells[second].timer = 0;
            markNeighbours(session, first);
            markNeighbours(session, second);
        } else {
            session.cells[first].state = .flip_face_out;
            session.cells[first].timer = 0;
            session.cells[second].state = .flip_face_out;
            session.cells[second].timer = 0;
        }
        session.first = null;
        session.second = null;
        session.compare_pending = false;
    }

    fn markNeighbours(session: *KarutaSession, index: u8) void {
        const row: i8 = @intCast(index / board_columns);
        const column: i8 = @intCast(index % board_columns);
        const offsets = [_][2]i8{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } };
        for (offsets) |offset| {
            const r = row + offset[0];
            const c = column + offset[1];
            if (r < 0 or r >= board_rows or c < 0 or c >= board_columns) continue;
            const neighbour = storage(@intCast(r), @intCast(c));
            switch (session.cells[neighbour].state) {
                .empty, .face_up, .matched_scale_in => continue,
                else => {},
            }
            session.cells[neighbour].state = .flip_back_out;
            session.cells[neighbour].timer = 0;
            session.cells[neighbour].touched = true;
        }
    }

    fn advanceCells(session: *KarutaSession) void {
        for (&session.cells, 0..) |*cell, index| {
            if (!isTransient(cell.state)) continue;
            cell.timer += 1;
            switch (cell.state) {
                .flip_face_out => {
                    if (cell.timer >= session.rules.flip_frames) {
                        cell.state = .flip_back_in;
                        cell.timer = 0;
                    }
                },
                .flip_back_in => {
                    if (cell.timer >= session.rules.flip_frames) {
                        cell.state = .face_down;
                        cell.timer = 0;
                    }
                },
                .flip_back_out => {
                    if (cell.timer >= session.rules.flip_frames) {
                        cell.state = .flip_face_in;
                        cell.timer = 0;
                    }
                },
                .flip_face_in => {
                    if (cell.timer >= session.rules.flip_frames) {
                        cell.timer = 0;
                        if (cell.touched) {
                            cell.touched = false;
                            cell.state = .resolving;
                        } else if (cell.selected) {
                            cell.selected = false;
                            cell.state = .matched_fade;
                        } else {
                            cell.state = .face_up;
                        }
                    }
                },
                .matched_scale_in => {
                    if (cell.timer >= session.rules.matched_scale_frames) {
                        cell.state = .matched_scale_out;
                        cell.timer = 0;
                    }
                },
                .matched_scale_out => {
                    if (cell.timer >= session.rules.matched_scale_frames) {
                        cell.state = .matched_fade;
                        cell.timer = 0;
                    }
                },
                .matched_fade => {
                    if (cell.timer >= session.rules.matched_fade_frames) {
                        cell.state = .empty;
                        cell.timer = 0;
                    }
                },
                .resolving => {
                    if (cell.timer >= session.rules.resolve_frames) {
                        cell.timer = 0;
                        resolveCell(session, @intCast(index));
                    }
                },
                else => {},
            }
        }
    }

    /// Resolve one marked card: a same-face partner in the resolving state is
    /// removed with it; otherwise the card turns back down.
    fn resolveCell(session: *KarutaSession, index: u8) void {
        const face = session.cells[index].face;
        var partner: ?u8 = null;
        for (session.cells, 0..) |cell, candidate| {
            if (candidate == index) continue;
            if (cell.state != .resolving) continue;
            if (cell.face != face) continue;
            partner = @intCast(candidate);
            break;
        }
        if (partner) |other| {
            session.cells[index].state = .matched_scale_in;
            session.cells[index].timer = 0;
            session.cells[other].state = .matched_scale_in;
            session.cells[other].timer = 0;
            markNeighbours(session, index);
            markNeighbours(session, other);
        } else {
            session.cells[index].state = .flip_face_out;
            session.cells[index].timer = 0;
        }
    }

    fn allState(cells: [cell_count]KarutaCell, state: KarutaCellState) bool {
        for (cells) |cell| {
            if (cell.state != state) return false;
        }
        return true;
    }

    pub fn propose(self: KarutaSession) !KarutaResult {
        if (self.phase != .proposal and self.phase != .acknowledged) return error.NoProposal;
        if (!self.boardComplete()) return error.RoundIncomplete;
        const best_before = self.best[self.round];
        const flag_set = (self.flags & self.rules.flag_mask) == self.rules.flag_value;
        return .{
            .entry_id = self.entry_id,
            .content_id = self.content_id,
            .receipt_id = self.receipt_id,
            .round = self.round,
            .identities = self.roundIdentities(),
            .elapsed = self.elapsed,
            .best_before = best_before,
            .best_after = self.elapsed,
            .record = self.elapsed < best_before,
            .flag_set = flag_set,
            .consequence = if (flag_set) .story_flag else .none,
        };
    }

    pub fn acknowledge(self: *KarutaSession, balance: u32, best_after: u32, receipts: []const u64, applied: []const u64) !KarutaResult {
        if (self.phase != .proposal) return error.InvalidPhase;
        const proposal = try self.propose();
        if (balance != self.balance) return error.StaleBalance;
        if (best_after != proposal.best_after) return error.StaleRecord;
        try rules_mod.verifyReceipt(proposal.receipt_id, receipts, applied);
        var next = self.*;
        next.phase = .acknowledged;
        next.best[self.round] = proposal.best_after;
        next.flag_set = proposal.flag_set;
        next.consequence = proposal.consequence;
        try next.validate();
        self.* = next;
        return proposal;
    }

    pub fn continueRound(self: *KarutaSession, receipt_id: u64, balance: u32, best: [4]u32) !void {
        if (self.phase != .acknowledged) return error.InvalidPhase;
        if (self.consequence != .none) return error.ConsequenceConsumesSession;
        if (receipt_id == 0 or receipt_id == self.receipt_id) return error.InvalidEntry;
        if (balance != self.balance) return error.StaleBalance;
        var next = self.*;
        next.receipt_id = receipt_id;
        next.best = best;
        next.phase = .select;
        next.cells = @splat(.{});
        next.deal_cursor = 0;
        next.first = null;
        next.second = null;
        next.compare_pending = false;
        next.elapsed = 0;
        next.flag_set = false;
        next.consequence = .none;
        try next.validate();
        self.* = next;
    }

    pub fn exit(self: *KarutaSession) !void {
        var next = self.*;
        next.phase = .exited;
        self.* = next;
    }

    pub fn completionToken(self: KarutaSession) ?KarutaCompletion {
        return switch (self.phase) {
            .select => .round_selected,
            .exited => .exited,
            .proposal => blk: {
                if ((self.flags & self.rules.flag_mask) == self.rules.flag_value) break :blk .flag;
                if (self.elapsed < self.best[self.round]) break :blk .record;
                break :blk .round_complete;
            },
            .acknowledged => if (self.consequence == .story_flag) .flag else .round_complete,
            else => null,
        };
    }

    pub fn checkpoint(self: KarutaSession) KarutaSession {
        return self;
    }

    pub fn restore(candidate: KarutaSession, rules: KarutaRules) !KarutaSession {
        var session = candidate;
        session.rules = rules;
        try session.validate();
        return session;
    }
};

const slots = @import("save_slots.zig");
pub const start_label = "Start authored episode";
pub const confirmation_label = "Start this authored episode?";
pub const MovieStage = enum { logo, opening, attract };
pub const MovieSpec = struct {
    stage: MovieStage,
    id: []const u8,
    disc_path: []const u8,
    frames: u32,
    fps: u8 = 15,
    ticks_60hz: u32,
    next: ?MovieStage,
};
pub const movie_specs = [_]MovieSpec{
    .{ .stage = .logo, .id = "logo", .disc_path = "DEMO/573LOGO.STR", .frames = 114, .ticks_60hz = 114 * 4, .next = .opening },
    .{ .stage = .opening, .id = "opening", .disc_path = "DEMO/SUIKODEN.STR", .frames = 1647, .ticks_60hz = 1647 * 4, .next = null },
    .{ .stage = .attract, .id = "attract", .disc_path = "OPEN15MX.STR", .frames = 1688, .ticks_60hz = 1688 * 4, .next = null },
};
pub fn movieSpec(stage: MovieStage) MovieSpec {
    return movie_specs[@backingInt(stage)];
}
pub const max_hero_name = 8;
pub const name_cols = 13;
pub const name_rows = 7;
pub const name_grid = [6][]const u8{
    "ABCDEFGHIJKLM",
    "NOPQRSTUVWXYZ",
    "abcdefghijklm",
    "nopqrstuvwxyz",
    "0123456789   ",
    ":;\"'&,.!?()-+",
};

pub const Input = struct {
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,
    confirm: bool = false,
    cancel: bool = false,
    erase: bool = false,
    text: []const u8 = "",
    pub fn any(self: Input) bool {
        return self.up or self.down or self.left or self.right or self.confirm or self.cancel or self.erase or self.text.len != 0;
    }
};
pub const Effect = enum { none, inspect, load, start_episode, start_opening, quit };
pub const State = struct {
    opening_context: bool = false,
    awaiting_start: bool = false,
    phase: enum { movie, title, saves, hero_name, episode_confirm, playing } = .title,
    movie_stage: MovieStage = .logo,
    movie_tick: u32 = 0,
    title_ticks: u32 = 0,
    title_idle_ticks: u32 = 0,
    attract_idle_limit: u32 = 900,
    selection: usize = 1,
    slot: usize = 0,
    yes: bool = false,
    hero_name_buf: [max_hero_name]u8 = .{ 'T', 'i', 'r', 0, 0, 0, 0, 0 },
    hero_name_len: usize = 3,
    name_cursor_row: usize = 6,
    name_cursor_col: usize = 6,
    message: []const u8 = "",
    summaries: [slots.count]slots.Summary = slots.emptySummaries(),

    pub fn heroName(self: *const State) []const u8 {
        if (self.hero_name_len == 0) return "Tir";
        return self.hero_name_buf[0..self.hero_name_len];
    }

    pub fn bootWithMovies() State {
        return .{ .phase = .movie, .movie_stage = .logo };
    }
    pub fn currentMovie(self: State) MovieSpec {
        return movieSpec(self.movie_stage);
    }
    pub fn ready(self: *State, summaries: [slots.count]slots.Summary) void {
        self.summaries = summaries;
        for (summaries) |entry| if (entry.status == .ready or entry.status == .backup) {
            self.selection = 0;
            return;
        };
    }
    pub fn advanceFrame(self: *State, input: Input) Effect {
        if (input.any()) return self.tick(input);
        switch (self.phase) {
            .movie => {
                self.movie_tick += 1;
                const spec = self.currentMovie();
                if (self.movie_tick >= spec.ticks_60hz) {
                    self.movie_tick = 0;
                    if (spec.next) |next_stage| {
                        self.movie_stage = next_stage;
                    } else {
                        self.phase = .title;
                        self.title_idle_ticks = 0;
                    }
                }
            },
            .title => {
                self.title_ticks +%= 1;
                if (self.attract_idle_limit != 0) {
                    self.title_idle_ticks += 1;
                    if (self.title_idle_ticks >= self.attract_idle_limit) {
                        self.phase = .movie;
                        self.movie_stage = .attract;
                        self.movie_tick = 0;
                        self.title_idle_ticks = 0;
                    }
                }
            },
            .saves, .hero_name, .episode_confirm => self.title_ticks +%= 1,
            .playing => {},
        }
        return .none;
    }
    pub fn tick(self: *State, input: Input) Effect {
        if (input.any()) self.title_idle_ticks = 0;
        if (self.phase == .movie) {
            if (input.any()) {
                self.phase = .title;
                self.movie_tick = 0;
            }
            return .none;
        }
        if (self.phase == .playing) return .none;
        if (self.phase == .title and self.awaiting_start) {
            if (input.confirm) self.awaiting_start = false;
            return .none;
        }
        if (self.phase == .hero_name) return self.tickHeroName(input);
        const move_up = input.up or input.left;
        const move_down = input.down or input.right;
        if (self.phase == .episode_confirm) {
            if (input.cancel) {
                self.phase = .title;
            } else if (move_up or move_down) {
                self.yes = !self.yes;
            } else if (input.confirm) {
                self.phase = if (self.yes) .playing else .title;
                if (self.yes) return if (self.opening_context) .start_opening else .start_episode;
            }
            return .none;
        }
        const selection = if (self.phase == .saves) &self.slot else &self.selection;
        const count: usize = if (self.phase == .saves) slots.count else 3;
        if (input.cancel) {
            self.phase = .title;
            self.message = "";
            return .none;
        }
        if (move_up) selection.* = (selection.* + count - 1) % count;
        if (move_down) selection.* = (selection.* + 1) % count;
        if (!input.confirm) return .none;
        self.message = "";
        if (self.phase == .saves) {
            switch (self.summaries[self.slot].status) {
                .ready, .backup => return .load,
                .empty => self.message = "This slot is empty.",
                .future => self.message = "This save needs a newer game version.",
                .damaged => self.message = "This save and its backup could not be read.",
            }
            return .none;
        }
        switch (self.selection) {
            0 => {
                self.phase = .saves;
                return .inspect;
            },
            1 => {
                if (self.opening_context) {
                    self.phase = .hero_name;
                    self.name_cursor_row = 6;
                    self.name_cursor_col = 6;
                } else {
                    self.phase = .episode_confirm;
                    self.yes = false;
                }
            },
            else => return .quit,
        }
        return .none;
    }

    fn tickHeroName(self: *State, input: Input) Effect {
        for (input.text) |ch| {
            if (ch >= 32 and ch <= 126 and self.hero_name_len < max_hero_name) {
                self.hero_name_buf[self.hero_name_len] = ch;
                self.hero_name_len += 1;
            }
        }
        if (input.erase and self.hero_name_len > 0) {
            self.hero_name_len -= 1;
            return .none;
        }
        if (input.cancel) {
            if (self.hero_name_len > 0) {
                self.hero_name_len -= 1;
            } else {
                self.phase = .title;
            }
            return .none;
        }
        if (input.up) self.name_cursor_row = (self.name_cursor_row + name_rows - 1) % name_rows;
        if (input.down) self.name_cursor_row = (self.name_cursor_row + 1) % name_rows;
        if (self.name_cursor_row == 6) {
            if (input.left or input.right) {
                self.name_cursor_col = if (self.name_cursor_col < 6) 6 else 0;
            }
        } else {
            const row_len = rowCharCount(self.name_cursor_row);
            if (self.name_cursor_col >= row_len) self.name_cursor_col = row_len - 1;
            if (input.left) self.name_cursor_col = (self.name_cursor_col + row_len - 1) % row_len;
            if (input.right) self.name_cursor_col = (self.name_cursor_col + 1) % row_len;
        }
        if (!input.confirm) return .none;
        if (self.name_cursor_row == 6) {
            if (self.name_cursor_col < 6) {
                if (self.hero_name_len > 0) self.hero_name_len -= 1;
                return .none;
            }
            if (self.hero_name_len == 0) {
                self.hero_name_buf[0] = 'T';
                self.hero_name_buf[1] = 'i';
                self.hero_name_buf[2] = 'r';
                self.hero_name_len = 3;
            }
            self.phase = .playing;
            return .start_opening;
        }
        const ch = name_grid[self.name_cursor_row][self.name_cursor_col];
        if (ch != ' ' and self.hero_name_len < max_hero_name) {
            self.hero_name_buf[self.hero_name_len] = ch;
            self.hero_name_len += 1;
            if (self.hero_name_len == max_hero_name) {
                self.name_cursor_row = 6;
                self.name_cursor_col = 6;
            }
        }
        return .none;
    }

    pub fn rowCharCount(row: usize) usize {
        return if (row == 4) 10 else name_cols;
    }
};

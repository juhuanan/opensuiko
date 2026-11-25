//! Embedded data and digests for final campaign and ending chapters.

pub const final_travel = struct {
    pub const json = @embedFile("final/final_travel.json");
    pub const asset_sha256 = "5b9e82fb217a18cb2a497261ab44dd8f555efd69667e95ef13329c4c7158cc57";
};

pub const final_story = struct {
    pub const json = @embedFile("final/final_story.json");
    pub const asset_sha256 = "f07de314b38ed33f6aa67dd132fdf8752c839c7f3f2e757b83a0940749bf303c";
};

pub const recruitment_map = struct {
    pub const json = @embedFile("final/recruitment_map.json");
    pub const asset_sha256 = "cd2b007b2255a0bd543e39024a71d4eab26a9f87b69fc726b16af20883b4ef4e";
};

pub const endings = struct {
    pub const json = @embedFile("final/endings.json");
    pub const asset_sha256 = "0887785672ddabf6902bac2c9abaef163fcc46b15e2642593de8eb1de9930d31";
};

pub const roster_progression = struct {
    pub const json = @embedFile("final/roster_progression.json");
    pub const asset_sha256 = "1f06cbfde9bdcec9bc39105a5c70cfca15c40daacb8eaf766ebb9a0f0f677fb9";
};

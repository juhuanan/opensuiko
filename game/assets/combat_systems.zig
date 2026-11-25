//! Embedded data and digests for combat presentation, poses, effects, menus, and streams.

pub const pose_families = struct {
    pub const json = @embedFile("combat_systems/pose_families.json");
    pub const schema = "suikoden-combat-pose-data/1";
    pub const packet_schema = "suikoden-combat-pose-families/1";
    pub const content_sha256 = "5d90507e3d393cbd2f7b2776d979f44063f482c993aa3d0f64e0ed97d2500382";
    pub const sprite_residency_sha256 = "2599058d4581f3b5349027d16be34077460d4f2735558462ac893baea1cea38f";
    pub const enemy_policy_report_sha256 = "ec517209cdeeb0f17fc4231f38ff1d4ef26e3970b2161c65ce3690ee23687c8b";
};

pub const effect_composition = struct {
    pub const effect_composition_json = @embedFile("combat_systems/effect_composition.json");
    pub const effect_composition_file_sha256 = "b493db193c9b2c8f2c4e8420c9feaa8bf1da748d3447fb6f61e924cfc9393702";
    pub const effect_composition_canonical_sha256 = "9f780d40291695916e830d087dca0cc0c9169e3da8a518f1921140ce04fd6d08";
    pub const version = "combat-effect-composition.1";
    pub const presentation_contract_sha256 = "6ee92f320b324b33195b4fe058970e0181bc319e800ba8bea9b3a33aaf132a95";
    pub const presentation_correction_code = "presentation_correction_unavailable";
};

pub const pipeline = struct {
    pub const json = @embedFile("combat_systems/pipeline.json");
};

pub const menu_lists = struct {
    pub const json = @embedFile("combat_systems/menu_lists.json");
    pub const schema = "suikoden-menu-lists/1";
};

pub const audio_integration = struct {
    pub const json = @embedFile("combat_systems/audio_integration.json");
};

pub const streams = struct {
    pub const json = @embedFile("combat_systems/streams.json");
};

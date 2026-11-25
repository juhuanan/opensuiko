//! Embedded data and digests for battle rules, spells, runes, and unite attacks.

pub const interactions_json = @embedFile("battle_systems/interactions.json");

pub const action_application = struct {
    pub const json = @embedFile("battle_systems/action_application.json");
    pub const asset_sha256 = "add0474f8823b7c26584ae68842337bb81bde924b5ae5a47ae336abe567923f5";
    pub const canonical_sha256 = "389f86624fd5c24dc3ff08ae0718d01b92d7800686bab319fdbc29b0f780b4f5";
    pub const semantics_sha256 = "315fa5b636c924195fca7e1a1aa1c75264cad7456f6de7126a8c960de37c5d01";
    pub const party_actions_asset_sha256 = "9762265f75efcfdbb7b6db3c1aa9ae056a4462b380f851ca83513ae7624f218d";
    pub const sprite_residency_manifest_sha256 = "2599058d4581f3b5349027d16be34077460d4f2735558462ac893baea1cea38f";
    pub const sprite_residency_proof_sha256 = "d7f81f6c4d99b7528323370d3c4a2766b27e90a8a9ee505f46dcde0111438b85";
    pub const main_body_sha256 = "e123263c3046a7283d8ca26598185672ed3f8de72d97f5efb0ee8e88ccaa55fa";
};

pub const enemy_effects = struct {
    pub const enemy_effects_json = @embedFile("battle_systems/enemy_effects.json");
    pub const vectors_json = @embedFile("battle_systems/enemy_vectors.json");
};

pub const spell_rules = struct {
    pub const json = @embedFile("battle_systems/spell_rules.json");
};

pub const runes = struct {
    pub const runes_json = @embedFile("battle_systems/runes.json");
    pub const vectors_json = @embedFile("battle_systems/rune_vectors.json");
};

pub const unite = struct {
    pub const unite_catalogue_json = @embedFile("battle_systems/unite_catalogue.json");
    pub const unite_catalogue_file_sha256 = "7ca4c09cb7f2c9edc96d6d1e24080a577409681da5d2cc1ab21384c1c1be8bb3";
    pub const unite_catalogue_canonical_sha256 = "c66c91278aa47a761d47f1434e069daaefab258ce0e919b338d7a146d4e5d62e";
    pub const version = "unite-catalogue.7";
};

pub const outcomes = struct {
    pub const json = @embedFile("battle_systems/outcomes.json");
};

pub const integration = struct {
    pub const integration_json = @embedFile("battle_systems/integration.json");
};

//! Embedded data and digests for campaign policies.

pub const content_graph = struct {
    pub const json = @embedFile("campaign_policies/content_graph.json");
};

pub const party_actions = struct {
    pub const json = @embedFile("campaign_policies/ordinary_party_actions.json");
    pub const asset_sha256 = "cb07915d893a53fdeedd434248c5091854e7504f48472e518700b6f6f3a05efe";
    pub const canonical_sha256 = "cb07915d893a53fdeedd434248c5091854e7504f48472e518700b6f6f3a05efe";
    pub const party_actions_asset_sha256 = "9762265f75efcfdbb7b6db3c1aa9ae056a4462b380f851ca83513ae7624f218d";
    pub const sprite_residency_manifest_sha256 = "2599058d4581f3b5349027d16be34077460d4f2735558462ac893baea1cea38f";
    pub const sprite_residency_proof_sha256 = "d7f81f6c4d99b7528323370d3c4a2766b27e90a8a9ee505f46dcde0111438b85";
    pub const sprite_residency_asset_sha256 = "2599058d4581f3b5349027d16be34077460d4f2735558462ac893baea1cea38f";
};

pub const enemy_policy = struct {
    pub const enemy_policy_json = @embedFile("campaign_policies/enemy_policy.json");
    pub const conformance_vectors_json = @embedFile("campaign_policies/enemy_policy_vectors.json");
};

pub const item_ledger = struct {
    pub const json = @embedFile("campaign_policies/item_shared_ledger.json");
};

pub const encounter_domains = struct {
    pub const domains_json = @embedFile("campaign_policies/encounter_domains.json");
    pub const vectors_json = @embedFile("campaign_policies/encounter_vectors.json");
};

pub const mode_result_host = struct {
    pub const mode_result_host_json = @embedFile("campaign_policies/mode_result_host.json");
    pub const conformance_vectors_json = @embedFile("campaign_policies/mode_result_vectors.json");
};

pub const control_draws = struct {
    pub const control_contract_json = @embedFile("campaign_policies/control_contract.json");
    pub const logical_draws_json = @embedFile("campaign_policies/logical_draws.json");
    pub const control_contract_file_sha256 = "4cf49d73f33db44bab6a426c657e08bdf4de274872ee422cc10d51ed39db6cf3";
    pub const control_contract_canonical_sha256 = "44dd9854d172e56f81820e411bcb72e05b6ab2bf3dd27c0675ad22b7c24dc159";
    pub const logical_draws_file_sha256 = "811c5f0dcc6a45b3cc405a0d1d7a1219869717530c246077098b1fa3fc5d3e48";
    pub const logical_draws_canonical_sha256 = "eb73aafbe4621bd4cc73509afee7df18ffdcf7eefe40579aac475050037543ff";
};

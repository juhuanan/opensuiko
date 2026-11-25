//! Embedded data and fixtures for packaged bundle discovery, validation, and scenarios.

pub const entry_policy_json = @embedFile("package_host/entry_policy.json");
pub const resources_json = @embedFile("package_host/resources.json");
pub const package_schema_json = @embedFile("package_host/package_schema.json");

pub const fixture = struct {
    pub const manifest_json = @embedFile("package_host/manifest_fixture.json");
    pub const signature_json = @embedFile("package_host/signature_fixture.json");
    pub const vectors_json = @embedFile("package_host/port_vectors.json");
};

pub const scenarios = struct {
    pub const scenarios_json = @embedFile("package_host/scenarios.json");
    pub const human_review_json = @embedFile("package_host/human_review.json");
    pub const scenarios_sha256 = "a2cf701ca88fc77a1ba113ec162b790181ffd291c027961b00472f58fc479e09";
    pub const human_review_sha256 = "e03d5732e2657592bdd6e1aefcb0c1c5c54a71b7217195c534f2c613f6c9f81a";
    pub const schema = "suikoden-scenario-deck/1";
    pub const revision = "scenarios.1";
};

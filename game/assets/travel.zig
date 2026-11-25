//! Embedded data and digests for world travel, admission, and field layers.

pub const navigation = struct {
    pub const scripted_routes = @import("travel/scripted_routes.zig");
    pub const route_json = @embedFile("travel/route_edges.json");
    pub const boat_json = @embedFile("travel/water.json");
    pub const layers_json = @embedFile("travel/field_layers.json");
    pub const route_sha256 = "07fe67e076e0d2488cc973b2381b5c945b2dfcd15caeda3ea084d75a12062e3e";
    pub const boat_sha256 = "fcb68f493bd7d4c205a3ca1294751081d10aba37578ab9453872bf7899544c72";
};

pub const teleport = struct {
    pub const viki_json = @embedFile("travel/viki.json");
    pub const mirror_json = @embedFile("travel/mirror.json");
};

pub const ground_geometry = struct {
    pub const json = @embedFile("travel/ground_geometry.json");
};

pub const populations = struct {
    pub const json = @embedFile("travel/populations.json");
};

pub const admission = struct {
    pub const event_admission_json = @embedFile("travel/event_admission.json");
    pub const conformance_json = @embedFile("travel/admission_conformance.json");
    pub const event_admission_file_sha256 = "b153d4ece8a0862e9fffaff3056a4606221c27abdf71a6fae0d842757bd09a8e";
    pub const event_admission_canonical_sha256 = "42b7927293fe47263082fa9aaa0ee831a96110cc33ccba30d43ff4e4a617a4a3";
    pub const conformance_file_sha256 = "34d72ffaeb16cee93d20f80235adf3b32776b2c04948370381d7fda7f822f84d";
    pub const conformance_canonical_sha256 = "243f60cd51f541b3b785f1aadcb9419d9cfa958f6afeb8c2465127c65591998d";
    pub const version = "event-admission.1";
};

pub const field_layers = struct {
    pub const json = navigation.layers_json;
};

//! Bundled dependencies for the source-only replay build.
//! The public fixtures use an empty party queue. Requests for the omitted
//! campaign packets reach their normal parsers with empty input.
pub const data = .{};
pub const json = "";
pub const endings = struct {
    pub const json = "";
};
pub const vb6_predicates = "";

const finish = "{\"id\":\"synthetic_finish\",\"actor\":\"hero\",\"commands\":[{\"kind\":\"finish\"}]}";
pub const queues = blk: {
    var text: []const u8 = "{\"schema\":\"suikoden-field-party-queue/1\"," ++
        "\"content_sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\"," ++
        "\"anchor\":{\"x\":216,\"y\":200},\"tracks\":[" ++ finish;
    for (1..40) |_| text = text ++ "," ++ finish;
    break :blk text ++ "]}";
};

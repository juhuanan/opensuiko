//! Integration bindings.
//!
//! Only the facts the integrated production path actually consumes live here.
//! The encounter rates are the two source bytes named by `campaign_policies.encounter`:
//! area header pair 0x8017159C/0x8017159D, paired for region B by the
//! reviewed world-map export (world_map_vb6 0x80044078).  Region C's pair is
//! not statically paired; `rateFor` returns null and the source policy refuses
//! with `rate_unavailable` rather than inventing a value.

const encounter_policy = @import("campaign_policies").encounter;

pub const schema = "suikoden-campaign-bindings/1";

pub const RegionRate = struct {
    region_id: []const u8,
    rate: u8,
    counter_threshold: u16,
    source: []const u8,
};

pub const region_rates = [_]RegionRate{
    .{
        .region_id = "region_b",
        .rate = 2,
        .counter_threshold = 60,
        .source = "world_map_vb6 0x80044078 -> area header 0x8017159C/0x8017159D",
    },
};

pub fn rateFor(region_id: []const u8) ?encounter_policy.SourceRate {
    for (region_rates) |rate| {
        if (std.mem.eql(u8, rate.region_id, region_id)) {
            return .{ .rate = rate.rate, .counter_threshold = rate.counter_threshold };
        }
    }
    return null;
}

pub fn bindingFor(region_id: []const u8) ?RegionRate {
    for (region_rates) |rate| if (std.mem.eql(u8, rate.region_id, region_id)) return rate;
    return null;
}

const std = @import("std");

test "region B carries the reviewed rate; region C stays an explicit blocker" {
    const b = bindingFor("region_b").?;
    try std.testing.expectEqual(@as(u8, 2), b.rate);
    try std.testing.expectEqual(@as(u16, 60), b.counter_threshold);
    try std.testing.expect(rateFor("region_c") == null);
    try std.testing.expect(rateFor("unknown") == null);
}

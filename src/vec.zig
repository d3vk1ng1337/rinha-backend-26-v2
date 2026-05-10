const std = @import("std");
const testing = std.testing;

pub const max_amount: f32 = 10000;
pub const max_installments: f32 = 12;
pub const amount_vs_avg_ratio: f32 = 10;
pub const max_minutes: f32 = 1440;
pub const max_km: f32 = 1000;
pub const max_tx_count_24h: f32 = 20;
pub const max_merchant_avg_amount: f32 = 10000;

pub fn clamp01(v: f32) f32 {
    if (v < 0) return 0;
    if (v > 1) return 1;
    return v;
}

pub fn round4(v: f32) f32 {
    if (v == -1) return -1;
    return @floatCast(@round(@as(f64, v) * 10000.0) / 10000.0);
}

pub fn boolFloat(b: bool) f32 {
    return if (b) 1 else 0;
}

pub fn safeFloat(v: f32) f32 {
    if (std.math.isNan(v) or std.math.isInf(v)) return 1;
    return v;
}

test "clamp01 keeps mid-range values" {
    try testing.expectEqual(@as(f32, 0.5), clamp01(0.5));
    try testing.expectEqual(@as(f32, 0), clamp01(0));
    try testing.expectEqual(@as(f32, 1), clamp01(1));
}
test "clamp01 clips out-of-range" {
    try testing.expectEqual(@as(f32, 0), clamp01(-3));
    try testing.expectEqual(@as(f32, 1), clamp01(7));
}
test "round4 rounds to 4 decimals" {
    try testing.expectEqual(@as(f32, 0.1235), round4(0.123456));
    try testing.expectEqual(@as(f32, 0), round4(0));
}
test "round4 passes -1 sentinel through" {
    try testing.expectEqual(@as(f32, -1), round4(-1));
}
test "boolFloat true and false" {
    try testing.expectEqual(@as(f32, 1), boolFloat(true));
    try testing.expectEqual(@as(f32, 0), boolFloat(false));
}
test "safeFloat replaces NaN and Inf with 1" {
    try testing.expectEqual(@as(f32, 1), safeFloat(std.math.nan(f32)));
    try testing.expectEqual(@as(f32, 1), safeFloat(std.math.inf(f32)));
    try testing.expectEqual(@as(f32, 1), safeFloat(-std.math.inf(f32)));
    try testing.expectEqual(@as(f32, 0.5), safeFloat(0.5));
}

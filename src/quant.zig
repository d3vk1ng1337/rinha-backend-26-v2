const std = @import("std");
const testing = std.testing;

pub const dim: usize = 14;
pub const Thresholds = [14]f32;

pub fn quantizeBinary14(v: *const [14]f32, t: *const Thresholds) u16 {
    var out: u16 = 0;
    comptime var d: u4 = 0;
    inline while (d < 14) : (d += 1) {
        if (v[d] >= t[d]) out |= @as(u16, 1) << d;
    }
    return out;
}

pub fn computeThresholds(allocator: std.mem.Allocator, values_per_dim: *const [14][]f32) !Thresholds {
    var t: Thresholds = undefined;
    var d: usize = 0;
    while (d < 14) : (d += 1) {
        const buf = try allocator.dupe(f32, values_per_dim[d]);
        defer allocator.free(buf);
        std.sort.pdq(f32, buf, {}, std.sort.asc(f32));
        t[d] = buf[buf.len / 2];
    }
    return t;
}

pub fn hammingDistance(a: u16, b: u16) u32 {
    return @as(u32, @popCount(a ^ b));
}

test "quantizeBinary14 sets bit when v >= threshold" {
    const t: Thresholds = .{ 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5 };
    const v: [14]f32 = .{ 0.6, 0.4, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5 };
    const code = quantizeBinary14(&v, &t);
    try testing.expectEqual(@as(u16, 1), code & 1);
    try testing.expectEqual(@as(u16, 0), (code >> 1) & 1);
    try testing.expectEqual(@as(u16, 1), (code >> 2) & 1);
}

test "quantizeBinary14 zero in upper bits 14, 15" {
    const t: Thresholds = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const v: [14]f32 = .{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 };
    const code = quantizeBinary14(&v, &t);
    try testing.expectEqual(@as(u16, 0x3FFF), code);
}

test "quantizeBinary14 sentinel -1 always falls below typical thresholds" {
    const t: Thresholds = .{ -0.5, -0.5, -0.5, -0.5, -0.5, -0.5, -0.5, -0.5, -0.5, -0.5, -0.5, -0.5, -0.5, -0.5 };
    const v: [14]f32 = .{ -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1 };
    const code = quantizeBinary14(&v, &t);
    try testing.expectEqual(@as(u16, 0), code);
}

test "computeThresholds returns median per dim" {
    const ally = testing.allocator;

    var per_dim: [14][]f32 = undefined;
    var d: usize = 0;
    while (d < 14) : (d += 1) {
        const slice = try ally.alloc(f32, 10);
        var i: usize = 0;
        while (i < 10) : (i += 1) slice[i] = @floatFromInt(i);
        per_dim[d] = slice;
    }
    defer {
        for (per_dim) |s| ally.free(s);
    }

    const t = try computeThresholds(ally, &per_dim);
    for (t) |th| try testing.expect(th >= 4.0 and th <= 5.0);
}

test "hammingDistance counts mismatched bits" {
    try testing.expectEqual(@as(u32, 0), hammingDistance(0, 0));
    try testing.expectEqual(@as(u32, 0), hammingDistance(0xABCD, 0xABCD));
    try testing.expectEqual(@as(u32, 14), hammingDistance(0x3FFF, 0));
    try testing.expectEqual(@as(u32, 1), hammingDistance(0b101, 0b100));
}

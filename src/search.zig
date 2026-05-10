const std = @import("std");
const testing = std.testing;
const index_format = @import("index_format.zig");

pub const k: usize = 5;
pub const k_rerank: usize = 32;

pub fn search(
    reader: *const index_format.Reader,
    q_bin: u16,
    q_int8: *const [14]i8,
) [k]u64 {
    var top_dist: [k_rerank]u32 = .{std.math.maxInt(u32)} ** k_rerank;
    var top_idx: [k_rerank]u64 = .{0} ** k_rerank;

    const codes = reader.binary_codes;
    const prefetch_ahead: usize = 256;
    var i: u64 = 0;
    while (i + prefetch_ahead < codes.len) : (i += 1) {
        @prefetch(&codes[i + prefetch_ahead], .{ .rw = .read, .locality = 0, .cache = .data });
        const d: u32 = @popCount(codes[i] ^ q_bin);
        if (d < top_dist[k_rerank - 1]) insertSorted(u32, top_dist[0..], top_idx[0..], d, i);
    }
    while (i < codes.len) : (i += 1) {
        const d: u32 = @popCount(codes[i] ^ q_bin);
        if (d < top_dist[k_rerank - 1]) insertSorted(u32, top_dist[0..], top_idx[0..], d, i);
    }

    var rer_dist: [k]u32 = .{std.math.maxInt(u32)} ** k;
    var rer_idx: [k]u64 = .{0} ** k;

    for (top_idx[0..k_rerank]) |idx| {
        const v = reader.vectorAt(idx);
        var d: u32 = 0;
        comptime var j: usize = 0;
        inline while (j < 14) : (j += 1) {
            const diff: i32 = @as(i32, q_int8[j]) - @as(i32, v[j]);
            d += @intCast(diff * diff);
        }
        if (d < rer_dist[k - 1]) insertSorted(u32, rer_dist[0..], rer_idx[0..], d, idx);
    }
    return rer_idx;
}

fn insertSorted(comptime T: type, dist: []T, idx: []u64, d: T, i: u64) void {
    const len = dist.len;
    var pos: usize = len - 1;
    while (pos > 0 and dist[pos - 1] > d) : (pos -= 1) {
        dist[pos] = dist[pos - 1];
        idx[pos] = idx[pos - 1];
    }
    dist[pos] = d;
    idx[pos] = i;
}

pub fn fraudScore(reader: *const index_format.Reader, top: [k]u64) f32 {
    var c: u32 = 0;
    for (top) |i| if (reader.labelAt(i)) {
        c += 1;
    };
    return @as(f32, @floatFromInt(c)) / @as(f32, k);
}

test "search v2 finds the closest int8 vector among rerank candidates" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile(io, "idx.bin", .{ .read = true });
    defer f.close(io);

    const N: u64 = 32;
    var w = try index_format.Writer.init(f, io, N, 14);
    const t = [_]f32{0} ** 14;
    try w.setThresholds(t);

    var i: u64 = 0;
    while (i < N) : (i += 1) {
        const code: u16 = @intCast(i);
        try w.writeBinary(code);
    }
    i = 0;
    while (i < N) : (i += 1) {
        var v: [14]i8 = undefined;
        for (&v) |*x| x.* = @intCast(@as(i64, @intCast(i)));
        try w.writeInt8Vector(&v);
    }
    try w.finalize();

    const total = try f.length(io);
    const buf = try testing.allocator.alignedAlloc(u8, .of(index_format.Header), total);
    defer testing.allocator.free(buf);
    _ = try f.readPositionalAll(io, buf, 0);
    const r = try index_format.Reader.init(buf);

    const q_bin: u16 = 7;
    const q_int8: [14]i8 = .{ 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7 };
    const top = search(&r, q_bin, &q_int8);

    try testing.expectEqual(@as(u64, 7), top[0]);
    try testing.expect(top[1] == 6 or top[1] == 8);
    try testing.expect(top[2] == 6 or top[2] == 8);
}

test "fraudScore counts fraud labels" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile(io, "idx.bin", .{ .read = true });
    defer f.close(io);
    var w = try index_format.Writer.init(f, io, 5, 14);
    try w.setThresholds(.{0} ** 14);
    var i: u64 = 0;
    while (i < 5) : (i += 1) try w.writeBinary(0);
    i = 0;
    const z = [_]i8{0} ** 14;
    while (i < 5) : (i += 1) try w.writeInt8Vector(&z);
    try w.setLabel(0, true);
    try w.setLabel(1, true);
    try w.setLabel(2, true);
    try w.finalize();

    const total = try f.length(io);
    const buf = try testing.allocator.alignedAlloc(u8, .of(index_format.Header), total);
    defer testing.allocator.free(buf);
    _ = try f.readPositionalAll(io, buf, 0);
    const r = try index_format.Reader.init(buf);

    const top = [_]u64{ 0, 1, 2, 3, 4 };
    try testing.expectApproxEqAbs(@as(f32, 0.6), fraudScore(&r, top), 1e-6);
}

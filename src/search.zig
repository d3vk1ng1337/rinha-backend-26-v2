const std = @import("std");
const testing = std.testing;
const index_format = @import("index_format.zig");

pub const k: usize = 5;

pub fn search(reader: *const index_format.Reader, query: *const [14]i8) [k]u64 {
    var top_dist: [k]u32 = .{ std.math.maxInt(u32), std.math.maxInt(u32), std.math.maxInt(u32), std.math.maxInt(u32), std.math.maxInt(u32) };
    var top_idx: [k]u64 = .{ 0, 0, 0, 0, 0 };

    const n = reader.header.num_vectors;
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        const v = reader.vectorAt(i);
        var d: u32 = 0;
        comptime var j: usize = 0;
        inline while (j < 14) : (j += 1) {
            const diff: i32 = @as(i32, query[j]) - @as(i32, v[j]);
            d += @intCast(diff * diff);
        }
        if (d < top_dist[k - 1]) insertSorted(&top_dist, &top_idx, d, i);
    }
    return top_idx;
}

fn insertSorted(dist: *[k]u32, idx: *[k]u64, d: u32, i: u64) void {
    var pos: usize = k - 1;
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

test "search returns 5 closest indices" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile(io, "idx.bin", .{ .read = true });
    defer f.close(io);

    var w = try index_format.Writer.init(f, io, 10, 14);
    var i: u64 = 0;
    while (i < 10) : (i += 1) {
        var v: [14]i8 = undefined;
        for (&v) |*x| x.* = @intCast(i);
        try w.writeVector(&v);
    }
    try w.finalize();

    const total = try f.length(io);
    const buf = try testing.allocator.alignedAlloc(u8, .of(index_format.Header), total);
    defer testing.allocator.free(buf);
    _ = try f.readPositionalAll(io, buf, 0);

    const r = try index_format.Reader.init(buf);

    const q: [14]i8 = .{ 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4 };
    const top = search(&r, &q);
    try testing.expectEqual(@as(u64, 4), top[0]);
    try testing.expectEqual(@as(u64, 3), top[1]);
    try testing.expectEqual(@as(u64, 5), top[2]);
}

test "fraudScore counts fraud labels" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile(io, "idx.bin", .{ .read = true });
    defer f.close(io);
    var w = try index_format.Writer.init(f, io, 5, 14);
    const z = [_]i8{0} ** 14;
    var i: u64 = 0;
    while (i < 5) : (i += 1) try w.writeVector(&z);
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

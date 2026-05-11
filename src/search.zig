const std = @import("std");
const testing = std.testing;
const index_format = @import("index_format.zig");

pub const k: usize = 5;
pub const k_rerank: usize = 32;
pub const num_probes: u32 = 8;
pub const dim: usize = 14;

const V8 = @Vector(8, f32);

pub fn searchFraudCount(
    reader: *const index_format.Reader,
    q_f32: *const [dim]f32,
    q_bin: u16,
    q_int8: *const [dim]i8,
) u8 {
    const top = search(reader, q_f32, q_bin, q_int8);
    var c: u8 = 0;
    for (top) |i| if (reader.labelAt(i)) {
        c += 1;
    };
    return c;
}

pub fn search(
    reader: *const index_format.Reader,
    q_f32: *const [dim]f32,
    q_bin: u16,
    q_int8: *const [dim]i8,
) [k]u64 {
    var top_dist: [k_rerank]u32 = .{std.math.maxInt(u32)} ** k_rerank;
    var top_idx: [k_rerank]u64 = .{0} ** k_rerank;

    const centroids_soa = reader.centroids();
    const num_centroids: u32 = reader.header.num_centroids;
    const codes = reader.binaryCodes();
    const offsets = reader.clusterOffsets();

    var probe_idx: [num_probes]u32 = .{std.math.maxInt(u32)} ** num_probes;
    topNCentroidsSoA(q_f32, centroids_soa, num_centroids, num_probes, &probe_idx);

    var unique_probes: [num_probes]u32 = undefined;
    var n_unique: u32 = 0;
    outer: for (probe_idx) |c| {
        if (c == std.math.maxInt(u32)) continue;
        for (unique_probes[0..n_unique]) |u| if (u == c) continue :outer;
        unique_probes[n_unique] = c;
        n_unique += 1;
    }

    const prefetch_ahead: u64 = 64;
    var p: u32 = 0;
    while (p < n_unique) : (p += 1) {
        const c = unique_probes[p];
        const start: u64 = offsets[c];
        const end: u64 = offsets[c + 1];
        var i: u64 = start;
        while (i + prefetch_ahead < end) : (i += 1) {
            @prefetch(&codes[i + prefetch_ahead], .{ .rw = .read, .locality = 0, .cache = .data });
            const d: u32 = @popCount(codes[i] ^ q_bin);
            if (d < top_dist[k_rerank - 1]) insertSorted(u32, top_dist[0..], top_idx[0..], d, i);
        }
        while (i < end) : (i += 1) {
            const d: u32 = @popCount(codes[i] ^ q_bin);
            if (d < top_dist[k_rerank - 1]) insertSorted(u32, top_dist[0..], top_idx[0..], d, i);
        }
    }

    var rer_dist: [k]u32 = .{std.math.maxInt(u32)} ** k;
    var rer_idx: [k]u64 = .{0} ** k;

    for (top_idx[0..k_rerank]) |idx| {
        const v = reader.vectorAt14(idx);
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

fn topNCentroidsSoA(
    q: *const [dim]f32,
    centroids_soa: []const f32,
    nc: u32,
    comptime top_n: u32,
    out_idx: *[top_n]u32,
) void {
    var top_d: [top_n]f32 = .{std.math.inf(f32)} ** top_n;
    const k_usize: usize = nc;

    var c: usize = 0;
    while (c + 8 <= k_usize) : (c += 8) {
        var acc: V8 = @splat(@as(f32, 0));
        comptime var d: usize = 0;
        inline while (d < dim) : (d += 1) {
            const qd: V8 = @splat(q[d]);
            const base = d * k_usize + c;
            const cv: V8 = centroids_soa[base..][0..8].*;
            const diff = cv - qd;
            acc = @mulAdd(V8, diff, diff, acc);
        }
        const arr: [8]f32 = acc;
        comptime var lane: u32 = 0;
        inline while (lane < 8) : (lane += 1) {
            const di = arr[lane];
            if (di < top_d[top_n - 1]) {
                var pos: usize = top_n - 1;
                while (pos > 0 and top_d[pos - 1] > di) : (pos -= 1) {
                    top_d[pos] = top_d[pos - 1];
                    out_idx[pos] = out_idx[pos - 1];
                }
                top_d[pos] = di;
                out_idx[pos] = @intCast(c + lane);
            }
        }
    }
    while (c < k_usize) : (c += 1) {
        var acc: f32 = 0;
        comptime var d: usize = 0;
        inline while (d < dim) : (d += 1) {
            const diff = centroids_soa[d * k_usize + c] - q[d];
            acc += diff * diff;
        }
        if (acc < top_d[top_n - 1]) {
            var pos: usize = top_n - 1;
            while (pos > 0 and top_d[pos - 1] > acc) : (pos -= 1) {
                top_d[pos] = top_d[pos - 1];
                out_idx[pos] = out_idx[pos - 1];
            }
            top_d[pos] = acc;
            out_idx[pos] = @intCast(c);
        }
    }
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

test "search v4 SoA single-cluster finds nearest int8" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile(io, "idx.bin", .{ .read = true });
    defer f.close(io);

    const N: u64 = 32;
    const t = [_]f32{0} ** 14;
    var labels: [N]bool = .{false} ** N;
    var codes: [N]u16 = undefined;
    var int8: [N * 14]i8 = undefined;
    var i: u64 = 0;
    while (i < N) : (i += 1) {
        codes[i] = @intCast(i);
        var d: usize = 0;
        while (d < 14) : (d += 1) int8[i * 14 + d] = @intCast(@as(i64, @intCast(i)));
    }
    try index_format.writeTestSingleCluster(testing.allocator, f, io, t, &labels, &codes, &int8);

    const total = try f.length(io);
    const buf = try testing.allocator.alignedAlloc(u8, .of(index_format.Header), total);
    defer testing.allocator.free(buf);
    _ = try f.readPositionalAll(io, buf, 0);
    const r = try index_format.Reader.init(buf);

    const q_f32: [14]f32 = .{ 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5 };
    const q_bin: u16 = 7;
    const q_int8: [14]i8 = .{ 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7 };
    const top = search(&r, &q_f32, q_bin, &q_int8);

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

    const t = [_]f32{0} ** 14;
    const labels = [_]bool{ true, true, true, false, false };
    const codes = [_]u16{ 0, 0, 0, 0, 0 };
    const z = [_]i8{0} ** (5 * 14);
    try index_format.writeTestSingleCluster(testing.allocator, f, io, t, &labels, &codes, &z);

    const total = try f.length(io);
    const buf = try testing.allocator.alignedAlloc(u8, .of(index_format.Header), total);
    defer testing.allocator.free(buf);
    _ = try f.readPositionalAll(io, buf, 0);
    const r = try index_format.Reader.init(buf);

    const top = [_]u64{ 0, 1, 2, 3, 4 };
    try testing.expectApproxEqAbs(@as(f32, 0.6), fraudScore(&r, top), 1e-6);
}

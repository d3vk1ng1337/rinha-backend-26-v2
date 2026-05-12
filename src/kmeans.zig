const std = @import("std");
const testing = std.testing;

const init_sample_size: usize = 50_000;

pub fn cluster(
    ally: std.mem.Allocator,
    data: []const f32,
    n: usize,
    dim: usize,
    k: usize,
    iters: usize,
    centroids: []f32,
    assignments: []u32,
) !void {
    if (centroids.len != k * dim) return error.BadArgs;
    if (assignments.len != n) return error.BadArgs;
    if (data.len != n * dim) return error.BadArgs;
    if (n < k) return error.NotEnoughData;

    try initPlusPlus(ally, data, n, dim, k, 0xdeadbeef_cafebabe, centroids);

    const sums = try ally.alloc(f32, k * dim);
    defer ally.free(sums);
    const counts = try ally.alloc(u32, k);
    defer ally.free(counts);

    var iter: usize = 0;
    while (iter < iters) : (iter += 1) {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            assignments[i] = nearest(data[i * dim ..][0..dim], centroids, k, dim);
        }

        @memset(sums, 0);
        @memset(counts, 0);
        i = 0;
        while (i < n) : (i += 1) {
            const c = assignments[i];
            counts[c] += 1;
            var d: usize = 0;
            while (d < dim) : (d += 1) sums[c * dim + d] += data[i * dim + d];
        }
        var c: usize = 0;
        while (c < k) : (c += 1) {
            if (counts[c] == 0) continue;
            const inv: f32 = 1.0 / @as(f32, @floatFromInt(counts[c]));
            var d: usize = 0;
            while (d < dim) : (d += 1) centroids[c * dim + d] = sums[c * dim + d] * inv;
        }
        std.log.info("kmeans: iter {}/{}", .{ iter + 1, iters });
    }
}

fn initPlusPlus(
    ally: std.mem.Allocator,
    data: []const f32,
    n: usize,
    dim: usize,
    k: usize,
    seed: u64,
    centroids: []f32,
) !void {
    var rng = std.Random.DefaultPrng.init(seed);
    const random = rng.random();

    const sample_size: usize = @min(n, init_sample_size);
    const sample = try ally.alloc(usize, sample_size);
    defer ally.free(sample);

    if (n <= init_sample_size) {
        var i: usize = 0;
        while (i < sample_size) : (i += 1) sample[i] = i;
    } else {
        var i: usize = 0;
        while (i < sample_size) : (i += 1) {
            sample[i] = random.intRangeLessThan(usize, 0, n);
        }
    }

    const first = sample[random.intRangeLessThan(usize, 0, sample_size)];
    @memcpy(centroids[0..dim], data[first * dim ..][0..dim]);

    const min_dists = try ally.alloc(f32, sample_size);
    defer ally.free(min_dists);
    @memset(min_dists, std.math.inf(f32));

    var c: usize = 1;
    while (c < k) : (c += 1) {
        const last = centroids[(c - 1) * dim ..][0..dim];
        var total: f64 = 0;

        var si: usize = 0;
        while (si < sample_size) : (si += 1) {
            const vi = sample[si];
            const d = distSq(data[vi * dim ..][0..dim], last, dim);
            if (d < min_dists[si]) min_dists[si] = d;
            total += min_dists[si];
        }

        var chosen_si: usize = sample_size - 1;
        if (total > 0 and std.math.isFinite(total)) {
            const target = random.float(f64) * total;
            var acc: f64 = 0;
            si = 0;
            while (si < sample_size) : (si += 1) {
                acc += min_dists[si];
                if (acc >= target) {
                    chosen_si = si;
                    break;
                }
            }
        } else {
            chosen_si = random.intRangeLessThan(usize, 0, sample_size);
        }

        const chosen = sample[chosen_si];
        @memcpy(centroids[c * dim ..][0..dim], data[chosen * dim ..][0..dim]);
    }
}

fn distSq(a: []const f32, b: []const f32, dim: usize) f32 {
    var out: f32 = 0;
    var d: usize = 0;
    while (d < dim) : (d += 1) {
        const diff = a[d] - b[d];
        out += diff * diff;
    }
    return out;
}

pub fn nearest(v: []const f32, centroids: []const f32, k: usize, dim: usize) u32 {
    if (dim == 14) return nearest14(v[0..14], centroids, k);
    var best: u32 = 0;
    var best_d: f32 = std.math.inf(f32);
    var c: usize = 0;
    while (c < k) : (c += 1) {
        var d: f32 = 0;
        var j: usize = 0;
        while (j < dim) : (j += 1) {
            const diff = v[j] - centroids[c * dim + j];
            d += diff * diff;
        }
        if (d < best_d) {
            best_d = d;
            best = @intCast(c);
        }
    }
    return best;
}

fn nearest14(v: *const [14]f32, centroids: []const f32, k: usize) u32 {
    const V = @Vector(14, f32);
    const qv: V = v.*;
    var best: u32 = 0;
    var best_d: f32 = std.math.inf(f32);
    var c: usize = 0;
    while (c < k) : (c += 1) {
        const cv: V = centroids[c * 14 ..][0..14].*;
        const diff = qv - cv;
        const sq = diff * diff;
        const d: f32 = @reduce(.Add, sq);
        if (d < best_d) {
            best_d = d;
            best = @intCast(c);
        }
    }
    return best;
}

pub fn topNCentroids(
    q: []const f32,
    centroids: []const f32,
    k: usize,
    dim: usize,
    top_n: u32,
    out_idx: []u32,
) void {
    std.debug.assert(out_idx.len >= top_n);
    std.debug.assert(top_n <= 256);
    if (dim == 14) {
        topN14(q[0..14], centroids, k, top_n, out_idx);
        return;
    }
    var top_d: [256]f32 = .{std.math.inf(f32)} ** 256;
    var c: usize = 0;
    while (c < k) : (c += 1) {
        var d: f32 = 0;
        var j: usize = 0;
        while (j < dim) : (j += 1) {
            const diff = q[j] - centroids[c * dim + j];
            d += diff * diff;
        }
        if (d < top_d[top_n - 1]) {
            var pos: usize = top_n - 1;
            while (pos > 0 and top_d[pos - 1] > d) : (pos -= 1) {
                top_d[pos] = top_d[pos - 1];
                out_idx[pos] = out_idx[pos - 1];
            }
            top_d[pos] = d;
            out_idx[pos] = @intCast(c);
        }
    }
}

fn topN14(q: *const [14]f32, centroids: []const f32, k: usize, top_n: u32, out_idx: []u32) void {
    const V = @Vector(14, f32);
    const qv: V = q.*;
    var top_d: [256]f32 = .{std.math.inf(f32)} ** 256;
    var c: usize = 0;
    const prefetch_ahead: usize = 8;
    while (c + prefetch_ahead < k) : (c += 1) {
        @prefetch(&centroids[(c + prefetch_ahead) * 14], .{ .rw = .read, .locality = 0, .cache = .data });
        const cv: V = centroids[c * 14 ..][0..14].*;
        const diff = qv - cv;
        const sq = diff * diff;
        const d: f32 = @reduce(.Add, sq);
        if (d < top_d[top_n - 1]) {
            var pos: usize = top_n - 1;
            while (pos > 0 and top_d[pos - 1] > d) : (pos -= 1) {
                top_d[pos] = top_d[pos - 1];
                out_idx[pos] = out_idx[pos - 1];
            }
            top_d[pos] = d;
            out_idx[pos] = @intCast(c);
        }
    }
    while (c < k) : (c += 1) {
        const cv: V = centroids[c * 14 ..][0..14].*;
        const diff = qv - cv;
        const sq = diff * diff;
        const d: f32 = @reduce(.Add, sq);
        if (d < top_d[top_n - 1]) {
            var pos: usize = top_n - 1;
            while (pos > 0 and top_d[pos - 1] > d) : (pos -= 1) {
                top_d[pos] = top_d[pos - 1];
                out_idx[pos] = out_idx[pos - 1];
            }
            top_d[pos] = d;
            out_idx[pos] = @intCast(c);
        }
    }
}

test "cluster converges on simple separated data" {
    const dim: usize = 2;
    const n: usize = 100;
    const k: usize = 2;
    var data: [n * dim]f32 = undefined;
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        data[i * dim + 0] = 0.1;
        data[i * dim + 1] = 0.1;
    }
    while (i < 100) : (i += 1) {
        data[i * dim + 0] = 0.9;
        data[i * dim + 1] = 0.9;
    }
    var centroids: [k * dim]f32 = undefined;
    var assignments: [n]u32 = undefined;
    try cluster(testing.allocator, &data, n, dim, k, 5, &centroids, &assignments);

    const a0_label: u32 = assignments[0];
    const a50_label: u32 = assignments[50];
    try testing.expect(a0_label != a50_label);
    for (assignments[0..50]) |a| try testing.expectEqual(a0_label, a);
    for (assignments[50..]) |a| try testing.expectEqual(a50_label, a);
}

test "kmeans++ initialization spreads separated centroids" {
    const dim: usize = 2;
    const n: usize = 4;
    const k: usize = 2;
    const data = [_]f32{
        0.0, 0.0,
        0.01, 0.0,
        10.0, 10.0,
        10.01, 10.0,
    };
    var centroids: [k * dim]f32 = undefined;
    try initPlusPlus(testing.allocator, &data, n, dim, k, 0xdeadbeef_cafebabe, &centroids);

    const dx = centroids[0] - centroids[2];
    const dy = centroids[1] - centroids[3];
    try testing.expect(dx * dx + dy * dy > 100.0);
}

test "topNCentroids returns sorted closest" {
    const dim: usize = 2;
    const k: usize = 5;
    const centroids = [_]f32{
        0.0, 0.0,
        1.0, 1.0,
        0.5, 0.5,
        2.0, 2.0,
        0.2, 0.2,
    };
    const q = [_]f32{ 0.0, 0.0 };
    var out: [3]u32 = undefined;
    topNCentroids(&q, &centroids, k, dim, 3, &out);

    try testing.expectEqual(@as(u32, 0), out[0]);
    try testing.expectEqual(@as(u32, 4), out[1]);
    try testing.expectEqual(@as(u32, 2), out[2]);
}

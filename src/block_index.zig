const std = @import("std");

pub const dims: usize = 14;
pub const block_size: usize = 8;
pub const header_size: usize = 64;
pub const magic: u64 = 0x3256_4949_484E_4952;
pub const version: u32 = 1;
pub const default_nprobe_fast: usize = 8;
pub const default_nprobe_full: usize = 32;
pub const max_clusters: usize = 16_384;
const q16_scale: f32 = 0.0001;
const q16_dist_scale: f32 = 1e-8;
const I16x8 = @Vector(8, i16);
const I32x8 = @Vector(8, i32);
const F32x8 = @Vector(8, f32);

pub const Reader = struct {
    bytes: []align(8) const u8,
    n: u32,
    k: u32,
    total_blocks: u32,
    centroids: []align(4) const f32,
    bbox_min: []align(2) const i16,
    bbox_max: []align(2) const i16,
    block_offsets: []align(4) const u32,
    labels: []const u8,
    blocks: []align(2) const i16,

    pub fn init(bytes: []align(8) const u8) !Reader {
        if (bytes.len < header_size) return error.TooShort;

        const got_magic = std.mem.readInt(u64, bytes[0..][0..8], .little);
        if (got_magic != magic) return error.BadMagic;
        const got_version = std.mem.readInt(u32, bytes[8..][0..4], .little);
        if (got_version != version) return error.BadVersion;

        const n = std.mem.readInt(u32, bytes[12..][0..4], .little);
        const k = std.mem.readInt(u32, bytes[16..][0..4], .little);
        const total_blocks = std.mem.readInt(u32, bytes[20..][0..4], .little);
        if (k == 0 or k > max_clusters) return error.UnsupportedClusterCount;

        const k_usize: usize = @intCast(k);
        const blocks_usize: usize = @intCast(total_blocks);

        var off: usize = header_size;
        const cent_bytes_len = k_usize * dims * @sizeOf(f32);
        const bbox_bytes_len = k_usize * dims * @sizeOf(i16);
        const offsets_bytes_len = (k_usize + 1) * @sizeOf(u32);
        const labels_bytes_len = blocks_usize * block_size;
        const blocks_bytes_len = blocks_usize * dims * block_size * @sizeOf(i16);
        const expected = off + cent_bytes_len + 2 * bbox_bytes_len + offsets_bytes_len + labels_bytes_len + blocks_bytes_len;
        if (bytes.len < expected) return error.TooShort;

        const cent_bytes: []align(4) const u8 = @alignCast(bytes[off .. off + cent_bytes_len]);
        const centroids = std.mem.bytesAsSlice(f32, cent_bytes);
        off += cent_bytes_len;

        const bmin_bytes: []align(2) const u8 = @alignCast(bytes[off .. off + bbox_bytes_len]);
        const bbox_min = std.mem.bytesAsSlice(i16, bmin_bytes);
        off += bbox_bytes_len;

        const bmax_bytes: []align(2) const u8 = @alignCast(bytes[off .. off + bbox_bytes_len]);
        const bbox_max = std.mem.bytesAsSlice(i16, bmax_bytes);
        off += bbox_bytes_len;

        const offset_bytes: []align(4) const u8 = @alignCast(bytes[off .. off + offsets_bytes_len]);
        const block_offsets = std.mem.bytesAsSlice(u32, offset_bytes);
        off += offsets_bytes_len;

        const labels = bytes[off .. off + labels_bytes_len];
        off += labels_bytes_len;

        const block_bytes: []align(2) const u8 = @alignCast(bytes[off .. off + blocks_bytes_len]);
        const blocks = std.mem.bytesAsSlice(i16, block_bytes);

        if (block_offsets[k_usize] != total_blocks) return error.BadOffsets;

        return .{
            .bytes = bytes,
            .n = n,
            .k = k,
            .total_blocks = total_blocks,
            .centroids = centroids,
            .bbox_min = bbox_min,
            .bbox_max = bbox_max,
            .block_offsets = block_offsets,
            .labels = labels,
            .blocks = blocks,
        };
    }

    pub inline fn centroidAt(self: *const Reader, d: usize, c: usize) f32 {
        return self.centroids[d * @as(usize, @intCast(self.k)) + c];
    }

    pub inline fn bboxMinAt(self: *const Reader, d: usize, c: usize) i16 {
        return self.bbox_min[d * @as(usize, @intCast(self.k)) + c];
    }

    pub inline fn bboxMaxAt(self: *const Reader, d: usize, c: usize) i16 {
        return self.bbox_max[d * @as(usize, @intCast(self.k)) + c];
    }
};

pub const WriteParams = struct {
    n: u64,
    k: usize,
    total_blocks: usize,
    centroids: []const f32,
    bbox_min: []const i16,
    bbox_max: []const i16,
    block_offsets: []const u32,
    labels: []const u8,
    blocks: []const i16,
};

pub fn writeAll(file: std.Io.File, io: std.Io, p: WriteParams) !void {
    std.debug.assert(p.k > 0 and p.k <= max_clusters);
    std.debug.assert(p.centroids.len == p.k * dims);
    std.debug.assert(p.bbox_min.len == p.k * dims);
    std.debug.assert(p.bbox_max.len == p.k * dims);
    std.debug.assert(p.block_offsets.len == p.k + 1);
    std.debug.assert(p.labels.len == p.total_blocks * block_size);
    std.debug.assert(p.blocks.len == p.total_blocks * dims * block_size);
    std.debug.assert(p.block_offsets[p.k] == p.total_blocks);

    var header: [header_size]u8 = .{0} ** header_size;
    std.mem.writeInt(u64, header[0..8], magic, .little);
    std.mem.writeInt(u32, header[8..12], version, .little);
    std.mem.writeInt(u32, header[12..16], @intCast(p.n), .little);
    std.mem.writeInt(u32, header[16..20], @intCast(p.k), .little);
    std.mem.writeInt(u32, header[20..24], @intCast(p.total_blocks), .little);

    var off: u64 = 0;
    try file.writePositionalAll(io, header[0..], off);
    off += header_size;
    try file.writePositionalAll(io, std.mem.sliceAsBytes(p.centroids), off);
    off += @as(u64, @intCast(p.centroids.len * @sizeOf(f32)));
    try file.writePositionalAll(io, std.mem.sliceAsBytes(p.bbox_min), off);
    off += @as(u64, @intCast(p.bbox_min.len * @sizeOf(i16)));
    try file.writePositionalAll(io, std.mem.sliceAsBytes(p.bbox_max), off);
    off += @as(u64, @intCast(p.bbox_max.len * @sizeOf(i16)));
    try file.writePositionalAll(io, std.mem.sliceAsBytes(p.block_offsets), off);
    off += @as(u64, @intCast(p.block_offsets.len * @sizeOf(u32)));
    try file.writePositionalAll(io, p.labels, off);
    off += @as(u64, @intCast(p.labels.len));
    try file.writePositionalAll(io, std.mem.sliceAsBytes(p.blocks), off);

    try file.sync(io);
}

pub fn quantize16(src: *const [dims]f32, dst: *[dims]i16) void {
    comptime var d: usize = 0;
    inline while (d < dims) : (d += 1) {
        var v = src[d];
        if (v < -1) v = -1;
        if (v > 1) v = 1;
        dst[d] = if (v >= 0)
            @intFromFloat(v * 10000.0 + 0.5)
        else
            @intFromFloat(v * 10000.0 - 0.5);
    }
}

pub fn searchFraudCount(reader: *const Reader, query: *const [dims]f32, comptime nprobe_fast: usize) u8 {
    const top = searchTop5(reader, query, nprobe_fast);
    var count: u8 = 0;
    for (top.labels) |label| {
        if (label == 1) count += 1;
    }
    return count;
}

pub fn searchFraudCountTwoTier(
    reader: *const Reader,
    query: *const [dims]f32,
    comptime nprobe_fast: usize,
    comptime nprobe_full: usize,
) u8 {
    const top = searchTop5TwoTier(reader, query, nprobe_fast, nprobe_full);
    var count: u8 = 0;
    for (top.labels) |label| {
        if (label == 1) count += 1;
    }
    return count;
}

const Top5 = struct {
    dists: [5]f32 = .{std.math.inf(f32)} ** 5,
    labels: [5]u8 = .{0} ** 5,

    inline fn worst(self: *const Top5) f32 {
        return self.dists[4];
    }

    fn insert(self: *Top5, d: f32, label: u8) void {
        if (d >= self.dists[4]) return;
        var pos: usize = 4;
        while (pos > 0 and self.dists[pos - 1] > d) : (pos -= 1) {
            self.dists[pos] = self.dists[pos - 1];
            self.labels[pos] = self.labels[pos - 1];
        }
        self.dists[pos] = d;
        self.labels[pos] = label;
    }
};

fn searchTop5(reader: *const Reader, query: *const [dims]f32, comptime nprobe_fast: usize) Top5 {
    comptime std.debug.assert(nprobe_fast > 0);
    var probe_d: [nprobe_fast]f32 = .{std.math.inf(f32)} ** nprobe_fast;
    var probe_i: [nprobe_fast]u32 = .{std.math.maxInt(u32)} ** nprobe_fast;

    findNearestProbes(reader, query, nprobe_fast, &probe_d, &probe_i);

    var q16: [dims]i16 = undefined;
    quantize16(query, &q16);

    var top = Top5{};
    var scanned: [max_clusters / 64]u64 = .{0} ** (max_clusters / 64);

    for (probe_i, 0..) |pc, pi| {
        if (pc == std.math.maxInt(u32)) continue;
        const ci: usize = pc;
        if (pi > 0 and bboxLowerBoundF32(reader, ci, &q16) >= top.worst()) {
            markScanned(&scanned, ci);
            continue;
        }
        scanCluster(reader, ci, query, &top);
        markScanned(&scanned, ci);
    }

    var fraud_count: u8 = 0;
    for (top.labels) |label| {
        if (label == 1) fraud_count += 1;
    }

    if (fraud_count == 2 or fraud_count == 3) {
        scanBboxFallback(reader, query, &q16, &scanned, &top);
    }

    return top;
}

fn searchTop5TwoTier(
    reader: *const Reader,
    query: *const [dims]f32,
    comptime nprobe_fast: usize,
    comptime nprobe_full: usize,
) Top5 {
    comptime {
        std.debug.assert(nprobe_fast > 0);
        std.debug.assert(nprobe_full >= nprobe_fast);
        std.debug.assert(nprobe_full <= max_clusters);
    }
    var probe_d: [nprobe_full]f32 = .{std.math.inf(f32)} ** nprobe_full;
    var probe_i: [nprobe_full]u32 = .{std.math.maxInt(u32)} ** nprobe_full;

    findNearestProbes(reader, query, nprobe_full, &probe_d, &probe_i);

    var top = Top5{};
    inline for (0..nprobe_fast) |pi| {
        const pc = probe_i[pi];
        if (pc != std.math.maxInt(u32)) {
            scanCluster(reader, pc, query, &top);
        }
    }

    var fraud_count: u8 = 0;
    for (top.labels) |label| {
        if (label == 1) fraud_count += 1;
    }

    if (fraud_count == 2 or fraud_count == 3) {
        inline for (nprobe_fast..nprobe_full) |pi| {
            const pc = probe_i[pi];
            if (pc != std.math.maxInt(u32)) {
                scanCluster(reader, pc, query, &top);
            }
        }
    }

    return top;
}

fn insertProbe(
    comptime nprobe_fast: usize,
    probe_d: *[nprobe_fast]f32,
    probe_i: *[nprobe_fast]u32,
    d: f32,
    i: u32,
) void {
    if (d >= probe_d[nprobe_fast - 1]) return;
    var pos: usize = nprobe_fast - 1;
    while (pos > 0 and probe_d[pos - 1] > d) : (pos -= 1) {
        probe_d[pos] = probe_d[pos - 1];
        probe_i[pos] = probe_i[pos - 1];
    }
    probe_d[pos] = d;
    probe_i[pos] = i;
}

fn findNearestProbes(
    reader: *const Reader,
    query: *const [dims]f32,
    comptime nprobe_fast: usize,
    probe_d: *[nprobe_fast]f32,
    probe_i: *[nprobe_fast]u32,
) void {
    const k: usize = @intCast(reader.k);

    var c: usize = 0;
    while (c + block_size <= k) : (c += block_size) {
        var cd: F32x8 = @splat(0);
        comptime var d: usize = 0;
        inline while (d < dims) : (d += 1) {
            const cent: F32x8 = reader.centroids[d * k + c ..][0..block_size].*;
            const diff = cent - @as(F32x8, @splat(query[d]));
            cd += diff * diff;
        }
        if (!@reduce(.Or, cd < @as(F32x8, @splat(probe_d[nprobe_fast - 1])))) continue;
        const dists: [block_size]f32 = cd;
        inline for (0..block_size) |lane| {
            if (dists[lane] < probe_d[nprobe_fast - 1]) {
                insertProbe(nprobe_fast, probe_d, probe_i, dists[lane], @intCast(c + lane));
            }
        }
    }

    while (c < k) : (c += 1) {
        var cd: f32 = 0;
        comptime var d: usize = 0;
        inline while (d < dims) : (d += 1) {
            const diff = reader.centroidAt(d, c) - query[d];
            cd += diff * diff;
        }
        insertProbe(nprobe_fast, probe_d, probe_i, cd, @intCast(c));
    }
}

fn scanCluster(reader: *const Reader, c: usize, query: *const [dims]f32, top: *Top5) void {
    const start: usize = @intCast(reader.block_offsets[c]);
    const end: usize = @intCast(reader.block_offsets[c + 1]);
    var b = start;
    while (b < end) : (b += 1) {
        const label_base = b * block_size;
        const block_base = b * dims * block_size;
        scanBlockF32(query, reader.blocks[block_base..], reader.labels[label_base..][0..block_size], top);
    }
}

fn scanBboxFallback(
    reader: *const Reader,
    query: *const [dims]f32,
    q: *const [dims]i16,
    scanned: *const [max_clusters / 64]u64,
    top: *Top5,
) void {
    const k: usize = @intCast(reader.k);
    var c: usize = 0;
    while (c + block_size <= k) : (c += block_size) {
        const lb = bboxLowerBoundVec8(reader, c, q);
        const cutoff = top.worst() + 1e-6;
        var lane: usize = 0;
        while (lane < block_size) : (lane += 1) {
            const ci = c + lane;
            if (isScanned(scanned, ci)) continue;
            if (lb[lane] >= cutoff) continue;
            scanCluster(reader, ci, query, top);
        }
    }

    while (c < k) : (c += 1) {
        if (isScanned(scanned, c)) continue;
        if (bboxLowerBoundF32(reader, c, q) >= top.worst()) continue;
        scanCluster(reader, c, query, top);
    }
}

inline fn scanBlockF32(
    query: *const [dims]f32,
    block: []align(2) const i16,
    labels: *const [block_size]u8,
    top: *Top5,
) void {
    const cutoff_vec: F32x8 = @splat(top.worst());
    var acc: F32x8 = @splat(0);

    accumDims(query, block, &acc, 0, 4);
    if (allGE(acc, cutoff_vec)) return;

    accumDims(query, block, &acc, 4, 6);
    if (allGE(acc, cutoff_vec)) return;

    accumDims(query, block, &acc, 6, 8);
    if (allGE(acc, cutoff_vec)) return;

    accumDims(query, block, &acc, 8, dims);
    const dists: [block_size]f32 = acc;
    inline for (0..block_size) |slot| {
        top.insert(dists[slot], labels[slot]);
    }
}

inline fn bboxLowerBoundF32(reader: *const Reader, c: usize, q: *const [dims]i16) f32 {
    return @as(f32, @floatFromInt(bboxLowerBound(reader, c, q))) * q16_dist_scale;
}

inline fn bboxLowerBoundVec8(reader: *const Reader, c: usize, q: *const [dims]i16) [block_size]f32 {
    const k: usize = @intCast(reader.k);
    var acc: F32x8 = @splat(0);
    comptime var d: usize = 0;
    inline while (d < dims) : (d += 1) {
        const mn_i16: I16x8 = reader.bbox_min[d * k + c ..][0..block_size].*;
        const mx_i16: I16x8 = reader.bbox_max[d * k + c ..][0..block_size].*;
        const mn: F32x8 = @floatFromInt(@as(I32x8, @intCast(mn_i16)));
        const mx: F32x8 = @floatFromInt(@as(I32x8, @intCast(mx_i16)));
        const qv: F32x8 = @splat(@floatFromInt(q[d]));
        const below = qv < mn;
        const above = qv > mx;
        const diff = @select(f32, below, mn - qv, @select(f32, above, qv - mx, @as(F32x8, @splat(0))));
        acc += diff * diff * @as(F32x8, @splat(q16_dist_scale));
    }
    return acc;
}

inline fn accumDims(
    query: *const [dims]f32,
    block: []align(2) const i16,
    acc: *F32x8,
    comptime start: usize,
    comptime end: usize,
) void {
    comptime var d: usize = start;
    inline while (d < end) : (d += 1) {
        const lanes_i16: I16x8 = block[d * block_size ..][0..block_size].*;
        const lanes_i32: I32x8 = @intCast(lanes_i16);
        const lanes_f32: F32x8 = @floatFromInt(lanes_i32);
        const v = lanes_f32 * @as(F32x8, @splat(q16_scale));
        const diff = v - @as(F32x8, @splat(query[d]));
        acc.* += diff * diff;
    }
}

inline fn allGE(acc: F32x8, cutoff: F32x8) bool {
    return !@reduce(.Or, acc < cutoff);
}

fn bboxLowerBound(reader: *const Reader, c: usize, q: *const [dims]i16) u64 {
    var acc: u64 = 0;
    comptime var d: usize = 0;
    inline while (d < dims) : (d += 1) {
        const qd = @as(i32, q[d]);
        const mn = @as(i32, reader.bboxMinAt(d, c));
        const mx = @as(i32, reader.bboxMaxAt(d, c));
        var diff: i32 = 0;
        if (qd < mn) {
            diff = mn - qd;
        } else if (qd > mx) {
            diff = qd - mx;
        }
        acc += @intCast(diff * diff);
    }
    return acc;
}

inline fn markScanned(scanned: *[max_clusters / 64]u64, c: usize) void {
    scanned[c / 64] |= @as(u64, 1) << @intCast(c % 64);
}

inline fn isScanned(scanned: *const [max_clusters / 64]u64, c: usize) bool {
    return (scanned[c / 64] & (@as(u64, 1) << @intCast(c % 64))) != 0;
}

test "quantize16 preserves round4 grid" {
    const q: [dims]f32 = .{ -1, 0, 0.0001, 0.1234, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    var out: [dims]i16 = undefined;
    quantize16(&q, &out);
    try std.testing.expectEqual(@as(i16, -10000), out[0]);
    try std.testing.expectEqual(@as(i16, 0), out[1]);
    try std.testing.expectEqual(@as(i16, 1), out[2]);
    try std.testing.expectEqual(@as(i16, 1234), out[3]);
    try std.testing.expectEqual(@as(i16, 10000), out[4]);
}

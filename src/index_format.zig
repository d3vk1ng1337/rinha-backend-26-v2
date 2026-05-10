const std = @import("std");
const testing = std.testing;
const Io = std.Io;

pub const magic: u64 = 0x52494E48413236;
pub const version_v4: u32 = 4;

pub const Header = extern struct {
    magic: u64,
    num_vectors: u64,
    dim: u64,
    version: u32,
    num_centroids: u32,
};

pub const thresholds_byte_count: u64 = 14 * @sizeOf(f32);

pub fn centroidsByteCount(k: u64, d: u64) u64 {
    return k * d * @sizeOf(f32);
}

pub fn clusterOffsetsByteCount(k: u64) u64 {
    return (k + 1) * @sizeOf(u32);
}

pub fn labelByteCount(n: u64) u64 {
    const raw = (n + 7) / 8;
    return (raw + 1) & ~@as(u64, 1);
}

pub fn binaryCodeByteCount(n: u64) u64 {
    return n * @sizeOf(u16);
}

pub fn vectorByteCount(n: u64, d: u64) u64 {
    return n * d * @sizeOf(i8);
}

pub fn fileSize(n: u64, d: u64, k: u64) u64 {
    return @sizeOf(Header) + thresholds_byte_count + centroidsByteCount(k, d) + clusterOffsetsByteCount(k) + labelByteCount(n) + binaryCodeByteCount(n) + vectorByteCount(n, d);
}

pub const quant_scale: f32 = 127.0;

pub fn quantize(v: f32) i8 {
    const scaled = v * quant_scale;
    const r = @round(scaled);
    if (r > 127) return 127;
    if (r < -127) return -127;
    return @intFromFloat(r);
}

pub fn quantize14(src: *const [14]f32, dst: *[14]i8) void {
    var i: usize = 0;
    while (i < 14) : (i += 1) dst[i] = quantize(src[i]);
}

pub const WriteParams = struct {
    n: u64,
    d: u64,
    k: u64,
    thresholds: *const [14]f32,
    centroids: []const f32,
    cluster_offsets: []const u32,
    labels: []const u8,
    binary_codes: []const u16,
    int8_vectors: []const i8,
};

pub fn writeTestSingleCluster(
    ally: std.mem.Allocator,
    file: std.Io.File,
    io: Io,
    thresholds: [14]f32,
    labels_bits: []const bool,
    binary_codes: []const u16,
    int8_vectors: []const i8,
) !void {
    const n: u64 = labels_bits.len;
    const d: u64 = 14;
    std.debug.assert(binary_codes.len == n);
    std.debug.assert(int8_vectors.len == n * d);

    const lb = labelByteCount(n);
    const labels_bytes = try ally.alloc(u8, lb);
    defer ally.free(labels_bytes);
    @memset(labels_bytes, 0);
    for (labels_bits, 0..) |fraud, i| {
        if (fraud) labels_bytes[i / 8] |= (@as(u8, 1) << @intCast(i % 8));
    }

    const centroid = [_]f32{0.0} ** 14;
    const cluster_offsets = [_]u32{ 0, @intCast(n) };
    try writeAll(file, io, .{
        .n = n,
        .d = d,
        .k = 1,
        .thresholds = &thresholds,
        .centroids = &centroid,
        .cluster_offsets = &cluster_offsets,
        .labels = labels_bytes,
        .binary_codes = binary_codes,
        .int8_vectors = int8_vectors,
    });
}

pub fn writeAll(file: std.Io.File, io: Io, p: WriteParams) !void {
    std.debug.assert(p.centroids.len == p.k * p.d);
    std.debug.assert(p.cluster_offsets.len == p.k + 1);
    std.debug.assert(p.labels.len == labelByteCount(p.n));
    std.debug.assert(p.binary_codes.len == p.n);
    std.debug.assert(p.int8_vectors.len == p.n * p.d);
    std.debug.assert(p.cluster_offsets[p.k] == p.n);

    const h = Header{
        .magic = magic,
        .num_vectors = p.n,
        .dim = p.d,
        .version = version_v4,
        .num_centroids = @intCast(p.k),
    };

    var off: u64 = 0;
    try file.writePositionalAll(io, std.mem.asBytes(&h), off);
    off += @sizeOf(Header);
    try file.writePositionalAll(io, std.mem.asBytes(p.thresholds), off);
    off += thresholds_byte_count;
    try file.writePositionalAll(io, std.mem.sliceAsBytes(p.centroids), off);
    off += centroidsByteCount(p.k, p.d);
    try file.writePositionalAll(io, std.mem.sliceAsBytes(p.cluster_offsets), off);
    off += clusterOffsetsByteCount(p.k);
    try file.writePositionalAll(io, p.labels, off);
    off += labelByteCount(p.n);
    try file.writePositionalAll(io, std.mem.sliceAsBytes(p.binary_codes), off);
    off += binaryCodeByteCount(p.n);
    try file.writePositionalAll(io, std.mem.sliceAsBytes(p.int8_vectors), off);

    try file.sync(io);
}

pub const Reader = struct {
    bytes: []align(@alignOf(Header)) const u8,
    header: Header,
    centroids_slice: []align(4) const f32,
    cluster_offsets_slice: []align(4) const u32,
    labels: []const u8,
    binary_codes: []align(2) const u16,
    vectors: []const i8,

    pub fn init(bytes: []align(@alignOf(Header)) const u8) !Reader {
        if (bytes.len < @sizeOf(Header)) return error.TooShort;
        const h = std.mem.bytesToValue(Header, bytes[0..@sizeOf(Header)]);
        if (h.magic != magic) return error.BadMagic;
        if (h.version != version_v4) return error.UnsupportedVersion;

        const k: u64 = h.num_centroids;
        const cb = centroidsByteCount(k, h.dim);
        const ob = clusterOffsetsByteCount(k);
        const lb = labelByteCount(h.num_vectors);
        const bb = binaryCodeByteCount(h.num_vectors);
        const vb = vectorByteCount(h.num_vectors, h.dim);
        const total_expected = @sizeOf(Header) + thresholds_byte_count + cb + ob + lb + bb + vb;
        if (bytes.len < total_expected) return error.TooShort;

        const cent_start = @sizeOf(Header) + thresholds_byte_count;
        const cent_end = cent_start + cb;
        const cent_bytes: []align(4) const u8 = @alignCast(bytes[cent_start..cent_end]);
        const centroids_slice = std.mem.bytesAsSlice(f32, cent_bytes);

        const off_start = cent_end;
        const off_end = off_start + ob;
        const off_bytes: []align(4) const u8 = @alignCast(bytes[off_start..off_end]);
        const cluster_offsets_slice = std.mem.bytesAsSlice(u32, off_bytes);

        const labels_start = off_end;
        const labels = bytes[labels_start .. labels_start + lb];

        const bin_start = labels_start + lb;
        const bin_end = bin_start + bb;
        const bin_bytes: []align(2) const u8 = @alignCast(bytes[bin_start..bin_end]);
        const binary_codes = std.mem.bytesAsSlice(u16, bin_bytes);

        const vec_start = bin_end;
        const vec_end = vec_start + vb;
        const vectors = std.mem.bytesAsSlice(i8, bytes[vec_start..vec_end]);
        return .{
            .bytes = bytes,
            .header = h,
            .centroids_slice = centroids_slice,
            .cluster_offsets_slice = cluster_offsets_slice,
            .labels = labels,
            .binary_codes = binary_codes,
            .vectors = vectors,
        };
    }

    pub fn thresholds(self: *const Reader) *const [14]f32 {
        const start = @sizeOf(Header);
        const end = start + thresholds_byte_count;
        const slice = self.bytes[start..end];
        return @ptrCast(@alignCast(slice.ptr));
    }

    pub fn centroids(self: *const Reader) []align(4) const f32 {
        return self.centroids_slice;
    }

    pub fn clusterOffsets(self: *const Reader) []align(4) const u32 {
        return self.cluster_offsets_slice;
    }

    pub fn binaryCodeAt(self: *const Reader, i: u64) u16 {
        return self.binary_codes[i];
    }

    pub fn binaryCodes(self: *const Reader) []align(2) const u16 {
        return self.binary_codes;
    }

    pub fn vectorAt(self: *const Reader, i: u64) []const i8 {
        const start: u64 = i * self.header.dim;
        return self.vectors[start..][0..self.header.dim];
    }

    pub fn labelAt(self: *const Reader, i: u64) bool {
        return (self.labels[i / 8] >> @as(u3, @intCast(i % 8))) & 1 == 1;
    }
};

test "labelByteCount handles non-multiples of 8 and pads to even" {
    try testing.expectEqual(@as(u64, 2), labelByteCount(1));
    try testing.expectEqual(@as(u64, 2), labelByteCount(8));
    try testing.expectEqual(@as(u64, 2), labelByteCount(9));
    try testing.expectEqual(@as(u64, 2), labelByteCount(16));
    try testing.expectEqual(@as(u64, 4), labelByteCount(17));
    try testing.expectEqual(@as(u64, 375000), labelByteCount(3_000_000));
}

test "fileSize includes centroids and offsets for v3" {
    const n: u64 = 3_000_000;
    const d: u64 = 14;
    const k: u64 = 4096;
    const expected = @sizeOf(Header) + thresholds_byte_count + centroidsByteCount(k, d) + clusterOffsetsByteCount(k) + labelByteCount(n) + binaryCodeByteCount(n) + vectorByteCount(n, d);
    try testing.expectEqual(expected, fileSize(n, d, k));
    try testing.expect(expected < 100 * 1024 * 1024);
}

test "quantize bounds and round-trip" {
    try testing.expectEqual(@as(i8, 0), quantize(0));
    try testing.expectEqual(@as(i8, 127), quantize(1));
    try testing.expectEqual(@as(i8, -127), quantize(-1));
    try testing.expectEqual(@as(i8, 127), quantize(1.5));
    try testing.expectEqual(@as(i8, -127), quantize(-1.5));
}

test "writer + reader v3 round-trip with single-cluster helper" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile(io, "idx.bin", .{ .read = true });
    defer f.close(io);

    const t: [14]f32 = .{ 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.0, -0.1, -0.2, -0.3, -0.4 };
    const labels = [_]bool{ true, false, true };
    const codes = [_]u16{ 0x1234, 0x5678, 0x3FFF };
    const v0 = [_]i8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14 };
    const v1 = [_]i8{ -1, -2, -3, -4, -5, -6, -7, -8, -9, -10, -11, -12, -13, -14 };
    const v2 = [_]i8{ 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100 };
    var int8: [3 * 14]i8 = undefined;
    @memcpy(int8[0..14], &v0);
    @memcpy(int8[14..28], &v1);
    @memcpy(int8[28..42], &v2);

    try writeTestSingleCluster(testing.allocator, f, io, t, &labels, &codes, &int8);

    const total = try f.length(io);
    const buf = try testing.allocator.alignedAlloc(u8, .of(Header), total);
    defer testing.allocator.free(buf);
    _ = try f.readPositionalAll(io, buf, 0);

    const r = try Reader.init(buf);
    try testing.expectEqual(@as(u64, 3), r.header.num_vectors);
    try testing.expectEqual(@as(u32, version_v4), r.header.version);
    try testing.expectEqual(@as(u64, 14), r.header.dim);
    try testing.expectEqual(@as(u32, 1), r.header.num_centroids);

    const got_t = r.thresholds();
    for (t, 0..) |v, i| try testing.expectEqual(v, got_t[i]);

    try testing.expectEqual(true, r.labelAt(0));
    try testing.expectEqual(false, r.labelAt(1));
    try testing.expectEqual(true, r.labelAt(2));

    try testing.expectEqual(@as(u16, 0x1234), r.binaryCodeAt(0));
    try testing.expectEqual(@as(u16, 0x5678), r.binaryCodeAt(1));
    try testing.expectEqual(@as(u16, 0x3FFF), r.binaryCodeAt(2));

    try testing.expectEqual(@as(i8, 14), r.vectorAt(0)[13]);
    try testing.expectEqual(@as(i8, -14), r.vectorAt(1)[13]);
    try testing.expectEqual(@as(i8, 100), r.vectorAt(2)[7]);

    const offs = r.clusterOffsets();
    try testing.expectEqual(@as(u32, 0), offs[0]);
    try testing.expectEqual(@as(u32, 3), offs[1]);
}

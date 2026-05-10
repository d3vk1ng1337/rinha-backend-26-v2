const std = @import("std");
const testing = std.testing;
const Io = std.Io;

pub const magic: u64 = 0x52494E48413236;
pub const version_v2: u32 = 2;

pub const Header = extern struct {
    magic: u64,
    num_vectors: u64,
    dim: u64,
    version: u32,
    reserved: u32,
};

pub const thresholds_byte_count: u64 = 14 * @sizeOf(f32);

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

pub fn fileSize(n: u64, d: u64) u64 {
    return @sizeOf(Header) + thresholds_byte_count + labelByteCount(n) + binaryCodeByteCount(n) + vectorByteCount(n, d);
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

pub const Writer = struct {
    file: std.Io.File,
    io: Io,
    header: Header,
    thresholds_offset: u64,
    label_offset: u64,
    binary_offset: u64,
    vector_offset: u64,
    next_binary_offset: u64,
    next_vector_offset: u64,
    written_binaries: u64 = 0,
    written_int8: u64 = 0,

    pub fn init(file: std.Io.File, io: Io, n: u64, d: u64) !Writer {
        const h = Header{
            .magic = magic,
            .num_vectors = n,
            .dim = d,
            .version = version_v2,
            .reserved = 0,
        };
        try file.writePositionalAll(io, std.mem.asBytes(&h), 0);
        const thresholds_offset: u64 = @sizeOf(Header);
        const label_offset: u64 = thresholds_offset + thresholds_byte_count;
        const label_bytes = labelByteCount(n);
        const binary_offset = label_offset + label_bytes;
        const binary_bytes = binaryCodeByteCount(n);
        const vector_offset = binary_offset + binary_bytes;
        var zero: [1]u8 = .{0};
        var i: u64 = 0;
        while (i < label_bytes) : (i += 1) {
            try file.writePositionalAll(io, &zero, label_offset + i);
        }
        return .{
            .file = file,
            .io = io,
            .header = h,
            .thresholds_offset = thresholds_offset,
            .label_offset = label_offset,
            .binary_offset = binary_offset,
            .vector_offset = vector_offset,
            .next_binary_offset = binary_offset,
            .next_vector_offset = vector_offset,
        };
    }

    pub fn setThresholds(self: *Writer, t: [14]f32) !void {
        try self.file.writePositionalAll(self.io, std.mem.asBytes(&t), self.thresholds_offset);
    }

    pub fn writeBinary(self: *Writer, code: u16) !void {
        std.debug.assert(self.written_binaries < self.header.num_vectors);
        var buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &buf, code, .little);
        try self.file.writePositionalAll(self.io, &buf, self.next_binary_offset);
        self.next_binary_offset += @sizeOf(u16);
        self.written_binaries += 1;
    }

    pub fn writeInt8Vector(self: *Writer, vec: []const i8) !void {
        std.debug.assert(vec.len == self.header.dim);
        std.debug.assert(self.written_int8 < self.header.num_vectors);
        try self.file.writePositionalAll(self.io, std.mem.sliceAsBytes(vec), self.next_vector_offset);
        self.next_vector_offset += vec.len;
        self.written_int8 += 1;
    }

    pub fn setLabel(self: *Writer, idx: u64, fraud: bool) !void {
        const byte_idx = idx / 8;
        const bit_idx: u3 = @intCast(idx % 8);
        var b: [1]u8 = undefined;
        const n = try self.file.readPositionalAll(self.io, &b, self.label_offset + byte_idx);
        std.debug.assert(n == 1);
        if (fraud) b[0] |= (@as(u8, 1) << bit_idx) else b[0] &= ~(@as(u8, 1) << bit_idx);
        try self.file.writePositionalAll(self.io, &b, self.label_offset + byte_idx);
    }

    pub fn finalize(self: *Writer) !void {
        std.debug.assert(self.written_binaries == self.header.num_vectors);
        std.debug.assert(self.written_int8 == self.header.num_vectors);
        try self.file.sync(self.io);
    }
};

pub const Reader = struct {
    bytes: []align(@alignOf(Header)) const u8,
    header: Header,
    labels: []const u8,
    binary_codes: []align(2) const u16,
    vectors: []const i8,

    pub fn init(bytes: []align(@alignOf(Header)) const u8) !Reader {
        if (bytes.len < @sizeOf(Header)) return error.TooShort;
        const h = std.mem.bytesToValue(Header, bytes[0..@sizeOf(Header)]);
        if (h.magic != magic) return error.BadMagic;
        if (h.version != version_v2) return error.UnsupportedVersion;
        const lb = labelByteCount(h.num_vectors);
        const bb = binaryCodeByteCount(h.num_vectors);
        const vb = vectorByteCount(h.num_vectors, h.dim);
        const total_expected = @sizeOf(Header) + thresholds_byte_count + lb + bb + vb;
        if (bytes.len < total_expected) return error.TooShort;

        const labels_start = @sizeOf(Header) + thresholds_byte_count;
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

test "fileSize computes total v2 storage" {
    const n: u64 = 3_000_000;
    const d: u64 = 14;
    const expected = @sizeOf(Header) + thresholds_byte_count + labelByteCount(n) + binaryCodeByteCount(n) + vectorByteCount(n, d);
    try testing.expectEqual(expected, fileSize(n, d));
    try testing.expect(expected < 100 * 1024 * 1024);
}

test "quantize bounds and round-trip" {
    try testing.expectEqual(@as(i8, 0), quantize(0));
    try testing.expectEqual(@as(i8, 127), quantize(1));
    try testing.expectEqual(@as(i8, -127), quantize(-1));
    try testing.expectEqual(@as(i8, 127), quantize(1.5));
    try testing.expectEqual(@as(i8, -127), quantize(-1.5));
}

test "writer + reader v2 round-trip with thresholds and binary codes" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile(io, "idx.bin", .{ .read = true });
    defer f.close(io);

    var w = try Writer.init(f, io, 3, 14);
    const t: [14]f32 = .{ 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.0, -0.1, -0.2, -0.3, -0.4 };
    try w.setThresholds(t);
    try w.setLabel(0, true);
    try w.setLabel(2, true);
    try w.writeBinary(0x1234);
    try w.writeBinary(0x5678);
    try w.writeBinary(0x3FFF);
    const v0 = [_]i8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14 };
    const v1 = [_]i8{ -1, -2, -3, -4, -5, -6, -7, -8, -9, -10, -11, -12, -13, -14 };
    const v2 = [_]i8{ 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100 };
    try w.writeInt8Vector(&v0);
    try w.writeInt8Vector(&v1);
    try w.writeInt8Vector(&v2);
    try w.finalize();

    const total = try f.length(io);
    const buf = try testing.allocator.alignedAlloc(u8, .of(Header), total);
    defer testing.allocator.free(buf);
    _ = try f.readPositionalAll(io, buf, 0);

    const r = try Reader.init(buf);
    try testing.expectEqual(@as(u64, 3), r.header.num_vectors);
    try testing.expectEqual(@as(u32, version_v2), r.header.version);
    try testing.expectEqual(@as(u64, 14), r.header.dim);

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
}

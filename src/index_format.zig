const std = @import("std");
const testing = std.testing;
const Io = std.Io;

pub const magic: u64 = 0x52494E48413236;
pub const Header = extern struct {
    magic: u64,
    num_vectors: u64,
    dim: u64,
    reserved: u64,
};

pub fn labelByteCount(n: u64) u64 {
    return (n + 7) / 8;
}

pub fn vectorByteCount(n: u64, d: u64) u64 {
    return n * d * @sizeOf(i8);
}

pub fn fileSize(n: u64, d: u64) u64 {
    return @sizeOf(Header) + labelByteCount(n) + vectorByteCount(n, d);
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
    label_offset: u64,
    vector_offset: u64,
    next_vector_offset: u64,
    written_vectors: u64 = 0,

    pub fn init(file: std.Io.File, io: Io, n: u64, d: u64) !Writer {
        const h = Header{ .magic = magic, .num_vectors = n, .dim = d, .reserved = 0 };
        try file.writePositionalAll(io, std.mem.asBytes(&h), 0);
        const label_offset: u64 = @sizeOf(Header);
        const label_bytes = labelByteCount(n);
        const vector_offset = label_offset + label_bytes;
        var zero: [1]u8 = .{0};
        var i: u64 = 0;
        while (i < label_bytes) : (i += 1) {
            try file.writePositionalAll(io, &zero, label_offset + i);
        }
        return .{
            .file = file,
            .io = io,
            .header = h,
            .label_offset = label_offset,
            .vector_offset = vector_offset,
            .next_vector_offset = vector_offset,
        };
    }

    pub fn writeVector(self: *Writer, vec: []const i8) !void {
        std.debug.assert(vec.len == self.header.dim);
        try self.file.writePositionalAll(self.io, std.mem.sliceAsBytes(vec), self.next_vector_offset);
        self.next_vector_offset += vec.len;
        self.written_vectors += 1;
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
        std.debug.assert(self.written_vectors == self.header.num_vectors);
        try self.file.sync(self.io);
    }
};

pub const Reader = struct {
    bytes: []align(@alignOf(Header)) const u8,
    header: Header,
    labels: []const u8,
    vectors: []const i8,

    pub fn init(bytes: []align(@alignOf(Header)) const u8) !Reader {
        if (bytes.len < @sizeOf(Header)) return error.TooShort;
        const h = std.mem.bytesToValue(Header, bytes[0..@sizeOf(Header)]);
        if (h.magic != magic) return error.BadMagic;
        const lb = labelByteCount(h.num_vectors);
        if (bytes.len < @sizeOf(Header) + lb + vectorByteCount(h.num_vectors, h.dim)) return error.TooShort;
        const labels = bytes[@sizeOf(Header) .. @sizeOf(Header) + lb];
        const v_start = @sizeOf(Header) + lb;
        const v_end = v_start + vectorByteCount(h.num_vectors, h.dim);
        const v_bytes = bytes[v_start..v_end];
        const v_int8 = std.mem.bytesAsSlice(i8, v_bytes);
        return .{ .bytes = bytes, .header = h, .labels = labels, .vectors = v_int8 };
    }

    pub fn vectorAt(self: *const Reader, i: u64) []const i8 {
        const start: u64 = i * self.header.dim;
        return self.vectors[start..][0..self.header.dim];
    }

    pub fn labelAt(self: *const Reader, i: u64) bool {
        return (self.labels[i / 8] >> @as(u3, @intCast(i % 8))) & 1 == 1;
    }
};

test "labelByteCount handles non-multiples of 8" {
    try testing.expectEqual(@as(u64, 1), labelByteCount(1));
    try testing.expectEqual(@as(u64, 1), labelByteCount(8));
    try testing.expectEqual(@as(u64, 2), labelByteCount(9));
}

test "fileSize computes total int8 storage" {
    const n: u64 = 3_000_000;
    const d: u64 = 14;
    const expected = @sizeOf(Header) + labelByteCount(n) + n * d;
    try testing.expectEqual(expected, fileSize(n, d));
    try testing.expect(expected < 50 * 1024 * 1024);
}

test "quantize bounds and round-trip" {
    try testing.expectEqual(@as(i8, 0), quantize(0));
    try testing.expectEqual(@as(i8, 127), quantize(1));
    try testing.expectEqual(@as(i8, -127), quantize(-1));
    try testing.expectEqual(@as(i8, 127), quantize(1.5));
    try testing.expectEqual(@as(i8, -127), quantize(-1.5));
}

test "writer + reader round-trip" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile(io, "idx.bin", .{ .read = true });
    defer f.close(io);

    var w = try Writer.init(f, io, 3, 14);
    const v0 = [_]i8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14 };
    const v1 = [_]i8{ 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    const v2 = [_]i8{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    try w.writeVector(&v0);
    try w.writeVector(&v1);
    try w.writeVector(&v2);
    try w.setLabel(0, true);
    try w.setLabel(2, true);
    try w.finalize();

    const total = try f.length(io);
    const allocator = testing.allocator;
    const buf = try allocator.alignedAlloc(u8, .of(Header), total);
    defer allocator.free(buf);
    _ = try f.readPositionalAll(io, buf, 0);

    const r = try Reader.init(buf);
    try testing.expectEqual(@as(u64, 3), r.header.num_vectors);
    try testing.expectEqual(@as(u64, 14), r.header.dim);
    try testing.expectEqual(true, r.labelAt(0));
    try testing.expectEqual(false, r.labelAt(1));
    try testing.expectEqual(true, r.labelAt(2));
    try testing.expectEqual(@as(i8, 14), r.vectorAt(0)[13]);
    try testing.expectEqual(@as(i8, 15), r.vectorAt(1)[13]);
    try testing.expectEqual(@as(i8, 16), r.vectorAt(2)[13]);
}

const std = @import("std");
const flate = std.compress.flate;
const json = std.json;
const lib = @import("lib");
const index_format = lib.index_format;
const quant = lib.quant;

const dim: usize = 14;

pub fn main(init: std.process.Init) !void {
    const ally = init.arena.allocator();
    const io = init.io;

    var it = try init.minimal.args.iterateAllocator(ally);
    defer it.deinit();
    _ = it.next();
    const input = it.next() orelse "/data/references.json.gz";
    const output = it.next() orelse "/index/index.bin";
    std.log.info("builder: input={s} output={s}", .{ input, output });

    const n = try countRecords(ally, io, input);
    std.log.info("builder: counted {} records", .{n});

    const floats = try ally.alloc(f32, n * dim);
    const label_bytes = index_format.labelByteCount(n);
    const labels = try ally.alloc(u8, label_bytes);
    @memset(labels, 0);

    try parseAll(ally, io, input, n, floats, labels);
    std.log.info("builder: parse complete", .{});

    var per_dim: [dim][]f32 = undefined;
    {
        var d: usize = 0;
        while (d < dim) : (d += 1) {
            const slice = try ally.alloc(f32, n);
            var i: u64 = 0;
            while (i < n) : (i += 1) slice[i] = floats[i * dim + d];
            per_dim[d] = slice;
        }
    }
    const thresholds = try quant.computeThresholds(ally, &per_dim);
    {
        var d: usize = 0;
        while (d < dim) : (d += 1) ally.free(per_dim[d]);
    }
    std.log.info("builder: thresholds computed", .{});

    const cwd = std.Io.Dir.cwd();
    const out_file = try cwd.createFile(io, output, .{ .read = true });
    defer out_file.close(io);

    var w = try index_format.Writer.init(out_file, io, n, dim);
    try w.setThresholds(thresholds);
    try w.writeLabelsRaw(labels);

    var i: u64 = 0;
    while (i < n) : (i += 1) {
        const v_slice: *const [dim]f32 = floats[i * dim ..][0..dim];
        const code = quant.quantizeBinary14(v_slice, &thresholds);
        try w.writeBinary(code);

        var q: [dim]i8 = undefined;
        index_format.quantize14(v_slice, &q);
        try w.writeInt8Vector(&q);

        if ((i + 1) % 200_000 == 0) std.log.info("builder: wrote {}", .{i + 1});
    }

    try w.finalize();
    std.log.info("builder: done", .{});
}

fn countRecords(ally: std.mem.Allocator, io: std.Io, path: []const u8) !u64 {
    const cwd = std.Io.Dir.cwd();
    const file = try cwd.openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);

    var file_buf: [64 * 1024]u8 = undefined;
    var file_reader = file.reader(io, &file_buf);

    var decompress_buf: [flate.max_window_len]u8 = undefined;
    var decompress: flate.Decompress = .init(&file_reader.interface, .gzip, &decompress_buf);

    var reader = json.Reader.init(ally, &decompress.reader);
    defer reader.deinit();

    if (.array_begin != try reader.next()) return error.UnexpectedToken;

    var n: u64 = 0;
    while (true) {
        const tt = try reader.peekNextTokenType();
        if (tt == .array_end) {
            _ = try reader.next();
            break;
        }
        try reader.skipValue();
        n += 1;
    }
    return n;
}

fn parseAll(
    ally: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    n: u64,
    floats: []f32,
    labels: []u8,
) !void {
    const cwd = std.Io.Dir.cwd();
    const file = try cwd.openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);

    var file_buf: [64 * 1024]u8 = undefined;
    var file_reader = file.reader(io, &file_buf);

    var decompress_buf: [flate.max_window_len]u8 = undefined;
    var decompress: flate.Decompress = .init(&file_reader.interface, .gzip, &decompress_buf);

    var reader = json.Reader.init(ally, &decompress.reader);
    defer reader.deinit();

    if (.array_begin != try reader.next()) return error.UnexpectedToken;

    var idx: u64 = 0;
    while (true) {
        const tt = try reader.peekNextTokenType();
        if (tt == .array_end) {
            _ = try reader.next();
            break;
        }
        try parseRecord(ally, &reader, idx, floats, labels);
        idx += 1;
        if (idx % 200_000 == 0) std.log.info("builder: read {}", .{idx});
    }
    if (idx != n) return error.RecordCountMismatch;
}

fn parseRecord(
    ally: std.mem.Allocator,
    reader: *json.Reader,
    idx: u64,
    floats: []f32,
    labels: []u8,
) !void {
    if (.object_begin != try reader.next()) return error.UnexpectedToken;

    var have_vector = false;
    var have_label = false;
    var label_fraud = false;
    const base = idx * dim;

    while (true) {
        const tt = try reader.peekNextTokenType();
        if (tt == .object_end) {
            _ = try reader.next();
            break;
        }
        const key_tok = try reader.nextAlloc(ally, .alloc_if_needed);
        const key = switch (key_tok) {
            inline .string, .allocated_string => |s| s,
            else => return error.UnexpectedToken,
        };

        if (std.mem.eql(u8, key, "vector")) {
            if (.array_begin != try reader.next()) return error.UnexpectedToken;
            var i: usize = 0;
            while (true) {
                const vt = try reader.peekNextTokenType();
                if (vt == .array_end) {
                    _ = try reader.next();
                    break;
                }
                const num_tok = try reader.nextAlloc(ally, .alloc_if_needed);
                const slice = switch (num_tok) {
                    inline .number, .allocated_number => |s| s,
                    else => return error.UnexpectedToken,
                };
                if (i >= dim) return error.TooManyFields;
                floats[base + i] = try std.fmt.parseFloat(f32, slice);
                i += 1;
            }
            if (i != dim) return error.WrongVectorLength;
            have_vector = true;
        } else if (std.mem.eql(u8, key, "label")) {
            const v_tok = try reader.nextAlloc(ally, .alloc_if_needed);
            const v = switch (v_tok) {
                inline .string, .allocated_string => |s| s,
                else => return error.UnexpectedToken,
            };
            label_fraud = std.mem.eql(u8, v, "fraud");
            have_label = true;
        } else {
            try reader.skipValue();
        }
    }

    if (!have_vector or !have_label) return error.MissingField;
    if (label_fraud) {
        const byte_idx = idx / 8;
        const bit_idx: u3 = @intCast(idx % 8);
        labels[byte_idx] |= (@as(u8, 1) << bit_idx);
    }
}

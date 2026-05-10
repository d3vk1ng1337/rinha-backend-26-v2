const std = @import("std");
const flate = std.compress.flate;
const json = std.json;
const lib = @import("lib");
const index_format = lib.index_format;
const quant = lib.quant;
const kmeans = lib.kmeans;

const dim: usize = 14;
const num_centroids: usize = 4096;
const kmeans_iters: usize = 6;

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
    const label_bits = try ally.alloc(bool, n);
    @memset(label_bits, false);

    try parseAll(ally, io, input, n, floats, label_bits);
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

    const centroids = try ally.alloc(f32, num_centroids * dim);
    const assignments = try ally.alloc(u32, n);
    std.log.info("builder: running k-means ({} centroids, {} iters)…", .{ num_centroids, kmeans_iters });
    try kmeans.cluster(ally, floats, n, dim, num_centroids, kmeans_iters, centroids, assignments);
    std.log.info("builder: k-means done", .{});

    const cluster_counts = try ally.alloc(u32, num_centroids);
    @memset(cluster_counts, 0);
    {
        var i: u64 = 0;
        while (i < n) : (i += 1) cluster_counts[assignments[i]] += 1;
    }

    const cluster_offsets = try ally.alloc(u32, num_centroids + 1);
    {
        var acc: u32 = 0;
        var c: usize = 0;
        while (c < num_centroids) : (c += 1) {
            cluster_offsets[c] = acc;
            acc += cluster_counts[c];
        }
        cluster_offsets[num_centroids] = acc;
        std.debug.assert(acc == n);
    }

    const reordered_codes = try ally.alloc(u16, n);
    const reordered_int8 = try ally.alloc(i8, n * dim);
    const label_bytes = index_format.labelByteCount(n);
    const reordered_labels = try ally.alloc(u8, label_bytes);
    @memset(reordered_labels, 0);

    {
        const cursor = try ally.alloc(u32, num_centroids);
        defer ally.free(cursor);
        @memcpy(cursor, cluster_offsets[0..num_centroids]);

        var i: u64 = 0;
        while (i < n) : (i += 1) {
            const c = assignments[i];
            const dst: u64 = cursor[c];
            cursor[c] += 1;

            const v_slice: *const [dim]f32 = floats[i * dim ..][0..dim];
            reordered_codes[dst] = quant.quantizeBinary14(v_slice, &thresholds);

            var q: [dim]i8 = undefined;
            index_format.quantize14(v_slice, &q);
            @memcpy(reordered_int8[dst * dim ..][0..dim], &q);

            if (label_bits[i]) {
                const dst_byte = dst / 8;
                const dst_bit: u3 = @intCast(dst % 8);
                reordered_labels[dst_byte] |= (@as(u8, 1) << dst_bit);
            }

            if ((i + 1) % 200_000 == 0) std.log.info("builder: reordered {}", .{i + 1});
        }
    }

    std.log.info("builder: reorder done, writing V3 index", .{});

    const cwd = std.Io.Dir.cwd();
    const out_file = try cwd.createFile(io, output, .{ .read = true });
    defer out_file.close(io);

    try index_format.writeAll(out_file, io, .{
        .n = n,
        .d = dim,
        .k = num_centroids,
        .thresholds = &thresholds,
        .centroids = centroids,
        .cluster_offsets = cluster_offsets,
        .labels = reordered_labels,
        .binary_codes = reordered_codes,
        .int8_vectors = reordered_int8,
    });
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
    label_bits: []bool,
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
        try parseRecord(ally, &reader, idx, floats, label_bits);
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
    label_bits: []bool,
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
    label_bits[idx] = label_fraud;
}

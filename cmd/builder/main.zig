const std = @import("std");
const flate = std.compress.flate;
const json = std.json;
const lib = @import("lib");
const block_index = lib.block_index;
const kmeans = lib.kmeans;

const dim: usize = 14;
const num_centroids: usize = 4096;
const kmeans_iters: usize = 3;

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

    const centroids_aos = try ally.alloc(f32, num_centroids * dim);
    const assignments = try ally.alloc(u32, n);
    std.log.info("builder: running k-means ({} centroids, {} iters)…", .{ num_centroids, kmeans_iters });
    try kmeans.cluster(ally, floats, n, dim, num_centroids, kmeans_iters, centroids_aos, assignments);
    std.log.info("builder: k-means done", .{});

    const centroids_soa = try ally.alloc(f32, num_centroids * dim);
    {
        var d: usize = 0;
        while (d < dim) : (d += 1) {
            var c: usize = 0;
            while (c < num_centroids) : (c += 1) {
                centroids_soa[d * num_centroids + c] = centroids_aos[c * dim + d];
            }
        }
    }
    ally.free(centroids_aos);
    std.log.info("builder: centroids transposed to SoA", .{});

    const cluster_counts = try ally.alloc(u32, num_centroids);
    @memset(cluster_counts, 0);
    {
        var i: u64 = 0;
        while (i < n) : (i += 1) cluster_counts[assignments[i]] += 1;
    }

    const block_offsets = try ally.alloc(u32, num_centroids + 1);
    var total_blocks: u32 = 0;
    {
        var c: usize = 0;
        while (c < num_centroids) : (c += 1) {
            block_offsets[c] = total_blocks;
            total_blocks += (cluster_counts[c] + @as(u32, @intCast(block_index.block_size)) - 1) / @as(u32, @intCast(block_index.block_size));
        }
        block_offsets[num_centroids] = total_blocks;
    }

    const labels = try ally.alloc(u8, @as(usize, total_blocks) * block_index.block_size);
    @memset(labels, 0);
    const blocks = try ally.alloc(i16, @as(usize, total_blocks) * dim * block_index.block_size);
    @memset(blocks, 0);
    const bbox_min = try ally.alloc(i16, num_centroids * dim);
    const bbox_max = try ally.alloc(i16, num_centroids * dim);
    @memset(bbox_min, 0);
    @memset(bbox_max, 0);

    {
        const cursor_slots = try ally.alloc(u32, num_centroids);
        defer ally.free(cursor_slots);
        const cluster_seen = try ally.alloc(u32, num_centroids);
        defer ally.free(cluster_seen);
        @memset(cluster_seen, 0);

        var c: usize = 0;
        while (c < num_centroids) : (c += 1) {
            cursor_slots[c] = block_offsets[c] * @as(u32, @intCast(block_index.block_size));
        }

        var i: u64 = 0;
        while (i < n) : (i += 1) {
            const cluster: usize = @intCast(assignments[i]);
            const dst_slot: usize = @intCast(cursor_slots[cluster]);
            cursor_slots[cluster] += 1;

            const v_slice: *const [dim]f32 = floats[i * dim ..][0..dim];
            const block_id = dst_slot / block_index.block_size;
            const slot = dst_slot % block_index.block_size;

            if (label_bits[i]) {
                labels[block_id * block_index.block_size + slot] = 1;
            }

            var d: usize = 0;
            while (d < dim) : (d += 1) {
                const q16 = quantize16(v_slice[d]);
                blocks[block_id * dim * block_index.block_size + d * block_index.block_size + slot] = q16;

                const bbox_idx = d * num_centroids + cluster;
                if (cluster_seen[cluster] == 0) {
                    bbox_min[bbox_idx] = q16;
                    bbox_max[bbox_idx] = q16;
                } else {
                    if (q16 < bbox_min[bbox_idx]) bbox_min[bbox_idx] = q16;
                    if (q16 > bbox_max[bbox_idx]) bbox_max[bbox_idx] = q16;
                }
            }
            cluster_seen[cluster] += 1;

            if ((i + 1) % 200_000 == 0) std.log.info("builder: reordered {}", .{i + 1});
        }
    }

    std.log.info("builder: block layout done, writing q16 index", .{});

    const cwd = std.Io.Dir.cwd();
    const out_file = try cwd.createFile(io, output, .{ .read = true });
    defer out_file.close(io);

    try block_index.writeAll(out_file, io, .{
        .n = n,
        .k = num_centroids,
        .total_blocks = @intCast(total_blocks),
        .centroids = centroids_soa,
        .block_offsets = block_offsets,
        .bbox_min = bbox_min,
        .bbox_max = bbox_max,
        .labels = labels,
        .blocks = blocks,
    });
    std.log.info("builder: done", .{});
}

fn quantize16(v_raw: f32) i16 {
    var v = v_raw;
    if (v < -1) v = -1;
    if (v > 1) v = 1;
    return if (v >= 0)
        @intFromFloat(v * 10000.0 + 0.5)
    else
        @intFromFloat(v * 10000.0 - 0.5);
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

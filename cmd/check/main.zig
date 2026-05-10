const std = @import("std");
const lib = @import("lib");
const index_format = lib.index_format;
const search = lib.search;

const dim: usize = 14;
const k: usize = 5;

pub fn main(init: std.process.Init) !void {
    const ally = init.arena.allocator();
    const io = init.io;

    var it = try init.minimal.args.iterateAllocator(ally);
    defer it.deinit();
    _ = it.next();
    const index_path = it.next() orelse "/tmp/index.bin";
    const num_queries: u32 = if (it.next()) |s| try std.fmt.parseInt(u32, s, 10) else 100;
    const seed: u64 = if (it.next()) |s| try std.fmt.parseInt(u64, s, 10) else 42;

    std.log.info("check: index={s} num_queries={} seed={}", .{ index_path, num_queries, seed });

    const cwd = std.Io.Dir.cwd();
    const idx_file = try cwd.openFile(io, index_path, .{ .mode = .read_only });
    defer idx_file.close(io);

    const total = try idx_file.length(io);
    var mm = try std.Io.File.MemoryMap.create(io, idx_file, .{
        .len = @intCast(total),
        .protection = .{ .read = true },
        .undefined_contents = false,
        .populate = true,
        .offset = 0,
    });
    defer mm.destroy(io);

    const aligned: []align(@alignOf(index_format.Header)) const u8 = @alignCast(mm.memory);
    const reader = try index_format.Reader.init(aligned);
    std.log.info("check: index loaded — {} vectors, {} dims", .{ reader.header.num_vectors, reader.header.dim });

    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    var overlap_sum: u64 = 0;
    var overlap_hist: [k + 1]u32 = .{0} ** (k + 1);
    var fs_abs_diff_sum: f64 = 0;
    var approved_agree: u32 = 0;
    var v2_time_ns_sum: i128 = 0;
    var bf_time_ns_sum: i128 = 0;

    var i: u32 = 0;
    while (i < num_queries) : (i += 1) {
        const q_idx = random.intRangeLessThan(u64, 0, reader.header.num_vectors);
        const q_bin = reader.binaryCodeAt(q_idx);
        const q_int8_slice = reader.vectorAt(q_idx);
        var q_int8: [14]i8 = undefined;
        @memcpy(&q_int8, q_int8_slice);
        var q_f32: [14]f32 = undefined;
        for (q_int8, 0..) |x, j| q_f32[j] = @as(f32, @floatFromInt(x)) / 127.0;

        const t0 = std.Io.Clock.Timestamp.now(io, .awake);
        const v2_top = search.search(&reader, &q_f32, q_bin, &q_int8);
        const t1 = std.Io.Clock.Timestamp.now(io, .awake);
        const bf_top = bruteForceInt8(&reader, &q_int8);
        const t2 = std.Io.Clock.Timestamp.now(io, .awake);

        v2_time_ns_sum += t0.durationTo(t1).raw.nanoseconds;
        bf_time_ns_sum += t1.durationTo(t2).raw.nanoseconds;

        const v2_fs = search.fraudScore(&reader, v2_top);
        const bf_fs = search.fraudScore(&reader, bf_top);

        const ov = setIntersection(v2_top, bf_top);
        overlap_sum += ov;
        overlap_hist[ov] += 1;

        fs_abs_diff_sum += @abs(@as(f64, v2_fs) - @as(f64, bf_fs));
        const v2_appr = v2_fs < 0.6;
        const bf_appr = bf_fs < 0.6;
        if (v2_appr == bf_appr) approved_agree += 1;
    }

    const nq_f: f64 = @floatFromInt(num_queries);
    std.log.info("=== ground-truth check ({} queries, seed {}) ===", .{ num_queries, seed });
    std.log.info("mean top-5 overlap: {d:.3} / 5", .{@as(f64, @floatFromInt(overlap_sum)) / nq_f});
    var oi: usize = k + 1;
    while (oi > 0) {
        oi -= 1;
        const cnt: f64 = @floatFromInt(overlap_hist[oi]);
        std.log.info("  overlap == {}/5: {} ({d:.1}%)", .{ oi, overlap_hist[oi], 100 * cnt / nq_f });
    }
    std.log.info("mean |fraud_score V2 - bf|: {d:.4}", .{fs_abs_diff_sum / nq_f});
    std.log.info("approved agreement: {} / {} ({d:.1}%)", .{ approved_agree, num_queries, 100 * @as(f64, @floatFromInt(approved_agree)) / nq_f });

    const v2_mean_us: f64 = @as(f64, @floatFromInt(@as(i64, @intCast(v2_time_ns_sum)))) / nq_f / 1000.0;
    const bf_mean_us: f64 = @as(f64, @floatFromInt(@as(i64, @intCast(bf_time_ns_sum)))) / nq_f / 1000.0;
    std.log.info("mean V2 search:     {d:.1} us", .{v2_mean_us});
    std.log.info("mean brute force:   {d:.1} us", .{bf_mean_us});
}

fn bruteForceInt8(reader: *const index_format.Reader, q: *const [14]i8) [k]u64 {
    var top_d: [k]u32 = .{std.math.maxInt(u32)} ** k;
    var top_i: [k]u64 = .{0} ** k;
    const n = reader.header.num_vectors;
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        const v = reader.vectorAt(i);
        var d: u32 = 0;
        comptime var j: usize = 0;
        inline while (j < 14) : (j += 1) {
            const diff: i32 = @as(i32, q[j]) - @as(i32, v[j]);
            d += @intCast(diff * diff);
        }
        if (d < top_d[k - 1]) {
            var pos: usize = k - 1;
            while (pos > 0 and top_d[pos - 1] > d) : (pos -= 1) {
                top_d[pos] = top_d[pos - 1];
                top_i[pos] = top_i[pos - 1];
            }
            top_d[pos] = d;
            top_i[pos] = i;
        }
    }
    return top_i;
}

fn setIntersection(a: [k]u64, b: [k]u64) u32 {
    var c: u32 = 0;
    for (a) |x| {
        for (b) |y| {
            if (x == y) {
                c += 1;
                break;
            }
        }
    }
    return c;
}

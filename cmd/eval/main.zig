const std = @import("std");
const lib = @import("lib");
const fast_parser = lib.fast_parser;
const index_format = lib.index_format;
const quant = lib.quant;
const search = lib.search;
const vec = lib.vec;

const dim = vec.dim;
const Kind = enum { binary, exact };
const Variant = struct {
    name: []const u8,
    kind: Kind,
    probes: u32,
    rerank: usize,
};
const variants = .{
    Variant{ .name = "binary_p8_r32", .kind = .binary, .probes = 8, .rerank = 32 },
    Variant{ .name = "binary_p64_r256", .kind = .binary, .probes = 64, .rerank = 256 },
    Variant{ .name = "exact_p8", .kind = .exact, .probes = 8, .rerank = 0 },
    Variant{ .name = "exact_p16", .kind = .exact, .probes = 16, .rerank = 0 },
    Variant{ .name = "exact_p32", .kind = .exact, .probes = 32, .rerank = 0 },
    Variant{ .name = "exact_p48", .kind = .exact, .probes = 48, .rerank = 0 },
    Variant{ .name = "exact_p64", .kind = .exact, .probes = 64, .rerank = 0 },
    Variant{ .name = "exact_p96", .kind = .exact, .probes = 96, .rerank = 0 },
    Variant{ .name = "exact_p128", .kind = .exact, .probes = 128, .rerank = 0 },
};

const extra_hist_count = 1;
const borderline_bf_i8_hist = variants.len;

const Hist = struct {
    fraud_by_count: [6]u64 = .{0} ** 6,
    legit_by_count: [6]u64 = .{0} ** 6,
    search_time_ns: i128 = 0,
    fallback_count: u64 = 0,
};

pub fn main(init: std.process.Init) !void {
    const ally = init.arena.allocator();
    const io = init.io;

    var it = try init.minimal.args.iterateAllocator(ally);
    defer it.deinit();
    _ = it.next();
    const index_path = it.next() orelse ".tmp/index-h13.bin";
    const test_path = it.next() orelse ".tmp/test-data.json";

    std.log.info("eval: index={s} test_data={s}", .{ index_path, test_path });

    const cwd = std.Io.Dir.cwd();
    const idx_file = try cwd.openFile(io, index_path, .{ .mode = .read_only });
    defer idx_file.close(io);

    const idx_len = try idx_file.length(io);
    var mm = try std.Io.File.MemoryMap.create(io, idx_file, .{
        .len = @intCast(idx_len),
        .protection = .{ .read = true },
        .undefined_contents = false,
        .populate = true,
        .offset = 0,
    });
    defer mm.destroy(io);

    const aligned: []align(@alignOf(index_format.Header)) const u8 = @alignCast(mm.memory);
    const reader = try index_format.Reader.init(aligned);

    const test_file = try cwd.openFile(io, test_path, .{ .mode = .read_only });
    defer test_file.close(io);
    const test_len = try test_file.length(io);
    const data = try ally.alloc(u8, test_len);
    _ = try test_file.readPositionalAll(io, data, 0);

    var hists: [variants.len + extra_hist_count]Hist = .{Hist{}} ** (variants.len + extra_hist_count);
    var parse_errors: u64 = 0;
    var entries: u64 = 0;

    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, data, pos, "\"request\"")) |request_key| {
        const request_start = try valueObjectStart(data, request_key + "\"request\"".len);
        const request_end = try findObjectEnd(data, request_start);
        const expected_key = std.mem.indexOfPos(u8, data, request_end, "\"expected_approved\"") orelse return error.MissingExpectedApproved;
        const expected_approved = try boolValue(data, expected_key + "\"expected_approved\"".len);

        var f: [dim]f32 = undefined;
        fast_parser.parseFeatures(data[request_start..request_end], &f) catch {
            parse_errors += 1;
            pos = request_end;
            continue;
        };

        var q_int8: [dim]i8 = undefined;
        index_format.quantize14(&f, &q_int8);
        const q_bin = quant.quantizeBinary14(&f, reader.thresholds());

        inline for (variants, 0..) |variant, vi| {
            const t0 = std.Io.Clock.Timestamp.now(io, .awake);
            const count = switch (variant.kind) {
                .binary => search.searchFraudCountWith(variant.probes, variant.rerank, &reader, &f, q_bin, &q_int8),
                .exact => search.searchFraudCountExactClustersWith(variant.probes, &reader, &f, &q_int8),
            };
            const t1 = std.Io.Clock.Timestamp.now(io, .awake);
            hists[vi].search_time_ns += t0.durationTo(t1).raw.nanoseconds;

            if (count > 5) return error.InvalidFraudCount;
            if (expected_approved) {
                hists[vi].legit_by_count[count] += 1;
            } else {
                hists[vi].fraud_by_count[count] += 1;
            }
        }

        const production_count = search.searchFraudCountExactClustersWith(32, &reader, &f, &q_int8);
        const t0_bf = std.Io.Clock.Timestamp.now(io, .awake);
        const bf_count = if (production_count == 2 or production_count == 3) blk: {
            hists[borderline_bf_i8_hist].fallback_count += 1;
            break :blk bruteForceInt8Count(&reader, &q_int8);
        } else production_count;
        const t1_bf = std.Io.Clock.Timestamp.now(io, .awake);
        hists[borderline_bf_i8_hist].search_time_ns += t0_bf.durationTo(t1_bf).raw.nanoseconds;
        if (expected_approved) {
            hists[borderline_bf_i8_hist].legit_by_count[bf_count] += 1;
        } else {
            hists[borderline_bf_i8_hist].fraud_by_count[bf_count] += 1;
        }

        entries += 1;
        pos = request_end;
    }

    const fraud_total = sum(&hists[0].fraud_by_count);
    const legit_total = sum(&hists[0].legit_by_count);
    const total = fraud_total + legit_total;
    const total_f: f64 = @floatFromInt(total);

    std.log.info("eval: entries={} parse_errors={} fraud={} legit={}", .{ entries, parse_errors, fraud_total, legit_total });

    inline for (variants, 0..) |variant, vi| {
        const hist = hists[vi];
        const mean_us = @as(f64, @floatFromInt(@as(i64, @intCast(hist.search_time_ns)))) / total_f / 1000.0;

        std.log.info("=== variant {s} probes={} rerank={} mean_search={d:.2}us ===", .{ variant.name, variant.probes, variant.rerank, mean_us });
        var c: usize = 0;
        while (c <= 5) : (c += 1) {
            std.log.info("count={} fraud={} legit={}", .{ c, hist.fraud_by_count[c], hist.legit_by_count[c] });
        }

        reportThresholds(hist, total_f);
    }

    {
        const hist = hists[borderline_bf_i8_hist];
        const mean_us = @as(f64, @floatFromInt(@as(i64, @intCast(hist.search_time_ns)))) / total_f / 1000.0;
        std.log.info("=== variant borderline_bf_i8 fallback_count={} mean_extra={d:.2}us ===", .{ hist.fallback_count, mean_us });
        var c: usize = 0;
        while (c <= 5) : (c += 1) {
            std.log.info("count={} fraud={} legit={}", .{ c, hist.fraud_by_count[c], hist.legit_by_count[c] });
        }
        reportThresholds(hist, total_f);
    }
}

fn bruteForceInt8Count(reader: *const index_format.Reader, q: *const [dim]i8) u8 {
    var top_d: [5]u32 = .{std.math.maxInt(u32)} ** 5;
    var top_i: [5]u64 = .{0} ** 5;
    const n = reader.header.num_vectors;
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        const v = reader.vectorAt14(i);
        var d: u32 = 0;
        comptime var j: usize = 0;
        inline while (j < dim) : (j += 1) {
            const diff: i32 = @as(i32, q[j]) - @as(i32, v[j]);
            d += @intCast(diff * diff);
        }
        if (d < top_d[4]) {
            var pos: usize = 4;
            while (pos > 0 and top_d[pos - 1] > d) : (pos -= 1) {
                top_d[pos] = top_d[pos - 1];
                top_i[pos] = top_i[pos - 1];
            }
            top_d[pos] = d;
            top_i[pos] = i;
        }
    }

    var count: u8 = 0;
    for (top_i) |idx| {
        if (reader.labelAt(idx)) count += 1;
    }
    return count;
}

fn reportThresholds(hist: Hist, total_f: f64) void {
    std.log.info("threshold sweep: fraud if fraud_count >= t", .{});
    var best_t: usize = 0;
    var best_e: u64 = std.math.maxInt(u64);
    var best_fp: u64 = 0;
    var best_fn: u64 = 0;
    var t: usize = 1;
    while (t <= 5) : (t += 1) {
        var fp: u64 = 0;
        var fn_: u64 = 0;
        var tp: u64 = 0;
        var tn: u64 = 0;

        var c: usize = 0;
        while (c <= 5) : (c += 1) {
            if (c >= t) {
                tp += hist.fraud_by_count[c];
                fp += hist.legit_by_count[c];
            } else {
                fn_ += hist.fraud_by_count[c];
                tn += hist.legit_by_count[c];
            }
        }

        const weighted_e = fp + 3 * fn_;
        if (weighted_e < best_e) {
            best_e = weighted_e;
            best_t = t;
            best_fp = fp;
            best_fn = fn_;
        }
        const failure_rate = @as(f64, @floatFromInt(fp + fn_)) / total_f * 100.0;
        std.log.info("t={} fp={} fn={} tp={} tn={} weighted_E={} fail={d:.3}%", .{
            t,
            fp,
            fn_,
            tp,
            tn,
            weighted_e,
            failure_rate,
        });
    }
    std.log.info("best_threshold={} best_weighted_E={} best_fp={} best_fn={}", .{ best_t, best_e, best_fp, best_fn });
}

fn valueObjectStart(buf: []const u8, key_end: usize) !usize {
    var p = key_end;
    while (p < buf.len and buf[p] != ':') : (p += 1) {}
    if (p >= buf.len) return error.MissingColon;
    p += 1;
    while (p < buf.len and isWs(buf[p])) : (p += 1) {}
    if (p >= buf.len or buf[p] != '{') return error.MissingObject;
    return p;
}

fn boolValue(buf: []const u8, key_end: usize) !bool {
    var p = key_end;
    while (p < buf.len and buf[p] != ':') : (p += 1) {}
    if (p >= buf.len) return error.MissingColon;
    p += 1;
    while (p < buf.len and isWs(buf[p])) : (p += 1) {}
    if (p + 4 <= buf.len and std.mem.eql(u8, buf[p .. p + 4], "true")) return true;
    if (p + 5 <= buf.len and std.mem.eql(u8, buf[p .. p + 5], "false")) return false;
    return error.MissingBool;
}

fn findObjectEnd(buf: []const u8, start: usize) !usize {
    if (start >= buf.len or buf[start] != '{') return error.MissingObject;
    var depth: u32 = 0;
    var in_string = false;
    var escaped = false;
    var i = start;
    while (i < buf.len) : (i += 1) {
        const ch = buf[i];
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (ch == '\\') {
                escaped = true;
            } else if (ch == '"') {
                in_string = false;
            }
            continue;
        }

        if (ch == '"') {
            in_string = true;
        } else if (ch == '{') {
            depth += 1;
        } else if (ch == '}') {
            depth -= 1;
            if (depth == 0) return i + 1;
        }
    }
    return error.UnclosedObject;
}

fn isWs(ch: u8) bool {
    return ch == ' ' or ch == '\n' or ch == '\r' or ch == '\t';
}

fn sum(xs: *const [6]u64) u64 {
    var total: u64 = 0;
    for (xs) |x| total += x;
    return total;
}

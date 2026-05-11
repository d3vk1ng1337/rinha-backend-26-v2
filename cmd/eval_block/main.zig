const std = @import("std");
const lib = @import("lib");
const block_index = lib.block_index;
const fast_parser = lib.fast_parser;

const dim = block_index.dims;
const nprobe_variants = [_]usize{ 8, 9, 10, 11, 12, 16, 24 };

const Hist = struct {
    fraud_by_count: [6]u64 = .{0} ** 6,
    legit_by_count: [6]u64 = .{0} ** 6,
    search_time_ns: i128 = 0,
};

pub fn main(init: std.process.Init) !void {
    const ally = init.arena.allocator();
    const io = init.io;

    var it = try init.minimal.args.iterateAllocator(ally);
    defer it.deinit();
    _ = it.next();
    const index_path = it.next() orelse "/Users/samuel/Documents/Personal/rinha-backend-26/bench/index2/index.bin";
    const test_path = it.next() orelse ".tmp/test-data.json";

    std.log.info("eval_block: index={s} test_data={s}", .{ index_path, test_path });

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

    const aligned: []align(8) const u8 = @alignCast(mm.memory);
    const reader = try block_index.Reader.init(aligned);
    std.log.info("eval_block: n={} k={} total_blocks={}", .{ reader.n, reader.k, reader.total_blocks });

    const test_file = try cwd.openFile(io, test_path, .{ .mode = .read_only });
    defer test_file.close(io);
    const test_len = try test_file.length(io);
    const data = try ally.alloc(u8, test_len);
    _ = try test_file.readPositionalAll(io, data, 0);

    var hists: [nprobe_variants.len]Hist = .{Hist{}} ** nprobe_variants.len;
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

        inline for (nprobe_variants, 0..) |nprobe, vi| {
            const t0 = std.Io.Clock.Timestamp.now(io, .awake);
            const count = block_index.searchFraudCount(&reader, &f, nprobe);
            const t1 = std.Io.Clock.Timestamp.now(io, .awake);
            hists[vi].search_time_ns += t0.durationTo(t1).raw.nanoseconds;

            if (count > 5) return error.InvalidFraudCount;
            if (expected_approved) {
                hists[vi].legit_by_count[count] += 1;
            } else {
                hists[vi].fraud_by_count[count] += 1;
            }
        }

        entries += 1;
        pos = request_end;
    }

    const fraud_total = sum(&hists[0].fraud_by_count);
    const legit_total = sum(&hists[0].legit_by_count);
    const total = fraud_total + legit_total;
    const total_f: f64 = @floatFromInt(total);

    std.log.info("eval_block: entries={} parse_errors={} fraud={} legit={}", .{
        entries,
        parse_errors,
        fraud_total,
        legit_total,
    });

    inline for (nprobe_variants, 0..) |nprobe, vi| {
        const hist = hists[vi];
        const mean_us = @as(f64, @floatFromInt(@as(i64, @intCast(hist.search_time_ns)))) / total_f / 1000.0;
        std.log.info("=== nprobe={} mean_search={d:.2}us ===", .{ nprobe, mean_us });
        var c: usize = 0;
        while (c <= 5) : (c += 1) {
            std.log.info("count={} fraud={} legit={}", .{ c, hist.fraud_by_count[c], hist.legit_by_count[c] });
        }
        reportThresholds(hist, total_f);
    }
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

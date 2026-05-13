const std = @import("std");
const lib = @import("lib");
const block_index = lib.block_index;
const fast_parser = lib.fast_parser;

const dim = block_index.dims;

pub fn main(init: std.process.Init) !void {
    const ally = init.arena.allocator();
    const io = init.io;

    var it = try init.minimal.args.iterateAllocator(ally);
    defer it.deinit();
    _ = it.next();
    const index_path = it.next() orelse ".tmp/index-k1280.bin";
    const test_path = it.next() orelse "test/test-data.json";

    std.log.info("dump_worst_dist: index={s} test_data={s}", .{ index_path, test_path });

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
    std.log.info("dump_worst_dist: n={} k={} total_blocks={}", .{ reader.n, reader.k, reader.total_blocks });

    const test_file = try cwd.openFile(io, test_path, .{ .mode = .read_only });
    defer test_file.close(io);
    const test_len = try test_file.length(io);
    const data = try ally.alloc(u8, test_len);
    _ = try test_file.readPositionalAll(io, data, 0);

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    try stdout.interface.print("fast_count,worst_dist,ref_count,expected_approved\n", .{});

    var pos: usize = 0;
    var entries: u64 = 0;
    var parse_errors: u64 = 0;
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

        const fast = block_index.searchFastTier(&reader, &f, 1);
        const ref = block_index.searchFraudCountTwoTierAdaptive(&reader, &f, 1, 20, 0, 5);
        try stdout.interface.print("{},{d},{},{}\n", .{ fast.count, fast.worst_dist, ref, @intFromBool(expected_approved) });

        entries += 1;
        pos = request_end;
    }
    try stdout.interface.flush();

    std.log.info("dump_worst_dist: entries={} parse_errors={}", .{ entries, parse_errors });
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
    return error.UnterminatedObject;
}

fn isWs(b: u8) bool {
    return b == ' ' or b == '\t' or b == '\n' or b == '\r';
}

const std = @import("std");
const testing = std.testing;
const vec = @import("vec.zig");
const search = @import("search.zig");
const fast_parser = @import("fast_parser.zig");
const index_format = @import("index_format.zig");
const block_index = @import("block_index.zig");

pub const Response = struct {
    bytes: []const u8,
    approved: bool,
};

const resp_0 = "HTTP/1.1 200 OK\r\nContent-Length: 33\r\n\r\n{\"approved\":true,\"fraud_score\":0}";
const resp_1 = "HTTP/1.1 200 OK\r\nContent-Length: 35\r\n\r\n{\"approved\":true,\"fraud_score\":0.2}";
const resp_2 = "HTTP/1.1 200 OK\r\nContent-Length: 35\r\n\r\n{\"approved\":true,\"fraud_score\":0.4}";
const resp_3 = "HTTP/1.1 200 OK\r\nContent-Length: 36\r\n\r\n{\"approved\":false,\"fraud_score\":0.6}";
const resp_4 = "HTTP/1.1 200 OK\r\nContent-Length: 36\r\n\r\n{\"approved\":false,\"fraud_score\":0.8}";
const resp_5 = "HTTP/1.1 200 OK\r\nContent-Length: 34\r\n\r\n{\"approved\":false,\"fraud_score\":1}";

const fraud_responses = [_][]const u8{ resp_0, resp_1, resp_2, resp_3, resp_4, resp_5 };

pub fn responseForCount(count: u8) []const u8 {
    return fraud_responses[count];
}

pub fn handle(
    ally: std.mem.Allocator,
    reader: *const index_format.Reader,
    body: []const u8,
) ![]const u8 {
    _ = ally;

    var f: [vec.dim]f32 = undefined;
    try fast_parser.parseFeatures(body, &f);
    var q_int8: [vec.dim]i8 = undefined;
    index_format.quantize14(&f, &q_int8);

    const count = search.searchFraudCount(reader, &f, 0, &q_int8);
    return fraud_responses[count];
}

pub fn handleBlock(
    ally: std.mem.Allocator,
    reader: *const block_index.Reader,
    body: []const u8,
) ![]const u8 {
    _ = ally;

    var f: [block_index.dims]f32 = undefined;
    try fast_parser.parseFeatures(body, &f);

    const count = block_index.searchFraudCountTwoTierAdaptive(
        reader,
        &f,
        block_index.default_nprobe_fast,
        block_index.default_nprobe_full,
        block_index.default_adaptive_min,
        block_index.default_adaptive_max,
    );
    return fraud_responses[count];
}

test "handle returns approved=true response when no frauds among top-5" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile(io, "idx.bin", .{ .read = true });
    defer f.close(io);

    const labels = [_]bool{false} ** 10;
    var codes: [10]u16 = undefined;
    var int8: [10 * 14]i8 = undefined;
    var i: u64 = 0;
    while (i < 10) : (i += 1) {
        codes[i] = @intCast(i);
        var d: usize = 0;
        while (d < 14) : (d += 1) int8[i * 14 + d] = @intCast(i);
    }
    try index_format.writeTestSingleCluster(testing.allocator, f, io, .{0} ** 14, &labels, &codes, &int8);

    const total = try f.length(io);
    const buf = try testing.allocator.alignedAlloc(u8, .of(index_format.Header), total);
    defer testing.allocator.free(buf);
    _ = try f.readPositionalAll(io, buf, 0);
    const r = try index_format.Reader.init(buf);

    const body =
        \\{"id":"a","transaction":{"amount":1,"installments":1,"requested_at":"2025-11-15T14:30:00Z"},
        \\"customer":{"avg_amount":1,"tx_count_24h":1,"known_merchants":[]},
        \\"merchant":{"id":"m","mcc":"5411","avg_amount":1},
        \\"terminal":{"is_online":true,"card_present":true,"km_from_home":0},
        \\"last_transaction":null}
    ;
    const out = try handle(testing.allocator, &r, body);
    try testing.expect(std.mem.indexOf(u8, out, "\"approved\":true") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"fraud_score\":0") != null);
}

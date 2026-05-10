const std = @import("std");
const testing = std.testing;
const vec = @import("vec.zig");
const search = @import("search.zig");
const json_io = @import("json_io.zig");
const index_format = @import("index_format.zig");
const quant = @import("quant.zig");

pub fn handle(
    ally: std.mem.Allocator,
    reader: *const index_format.Reader,
    body: []const u8,
    out: []u8,
) ![]u8 {
    var p = try json_io.parsePayload(ally, body);
    defer p.deinit();

    var f: [vec.dim]f32 = undefined;
    var q_int8: [vec.dim]i8 = undefined;
    vec.buildFloat(&p.value, &f);
    index_format.quantize14(&f, &q_int8);
    const q_bin = quant.quantizeBinary14(&f, reader.thresholds());

    const top = search.search(reader, &f, q_bin, &q_int8);
    const fs = search.fraudScore(reader, top);
    const approved = fs < 0.6;
    return json_io.encodeResponse(out, .{ .approved = approved, .fraud_score = fs });
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
    var out_buf: [256]u8 = undefined;
    const out = try handle(testing.allocator, &r, body, &out_buf);
    try testing.expect(std.mem.indexOf(u8, out, "\"approved\":true") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"fraud_score\":0") != null);
}

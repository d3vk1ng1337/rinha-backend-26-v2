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

    const top = search.search(reader, q_bin, &q_int8);
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
    var w = try index_format.Writer.init(f, io, 10, 14);
    try w.setThresholds(.{0} ** 14);
    var i: u64 = 0;
    while (i < 10) : (i += 1) try w.writeBinary(@intCast(i));
    i = 0;
    while (i < 10) : (i += 1) {
        var v: [14]i8 = undefined;
        for (&v) |*x| x.* = @intCast(i);
        try w.writeInt8Vector(&v);
    }
    try w.finalize();

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

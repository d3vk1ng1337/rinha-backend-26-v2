const std = @import("std");
const testing = std.testing;
const vec = @import("vec.zig");

pub const Response = struct {
    approved: bool,
    fraud_score: f32,
};

pub fn parsePayload(ally: std.mem.Allocator, body: []const u8) !std.json.Parsed(vec.Payload) {
    return std.json.parseFromSlice(vec.Payload, ally, body, .{ .ignore_unknown_fields = true });
}

pub fn encodeResponse(buf: []u8, resp: Response) ![]u8 {
    return std.fmt.bufPrint(buf, "{{\"approved\":{s},\"fraud_score\":{d}}}", .{
        if (resp.approved) "true" else "false",
        resp.fraud_score,
    });
}

test "parsePayload accepts canonical request" {
    const body =
        \\{"id":"a","transaction":{"amount":250,"installments":3,"requested_at":"2025-11-15T14:30:00Z"},
        \\"customer":{"avg_amount":100,"tx_count_24h":4,"known_merchants":["m1","m2"]},
        \\"merchant":{"id":"m3","mcc":"5411","avg_amount":200},
        \\"terminal":{"is_online":true,"card_present":true,"km_from_home":5.2},
        \\"last_transaction":{"timestamp":"2025-11-15T13:45:00Z","km_from_current":3.1}}
    ;
    const p = try parsePayload(testing.allocator, body);
    defer p.deinit();
    try testing.expectEqualStrings("a", p.value.id);
    try testing.expectEqual(@as(f32, 250), p.value.transaction.amount);
    try testing.expectEqualStrings("5411", p.value.merchant.mcc);
}

test "encodeResponse writes valid JSON" {
    var buf: [128]u8 = undefined;
    const out = try encodeResponse(&buf, .{ .approved = true, .fraud_score = 0.4 });
    try testing.expectEqualStrings("{\"approved\":true,\"fraud_score\":0.4}", out);
}

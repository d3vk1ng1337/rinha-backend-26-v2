const std = @import("std");
const testing = std.testing;
const time_parse = @import("time_parse.zig");
const mcc = @import("mcc.zig");

pub const max_amount: f32 = 10000;
pub const max_installments: f32 = 12;
pub const amount_vs_avg_ratio: f32 = 10;
pub const max_minutes: f32 = 1440;
pub const max_km: f32 = 1000;
pub const max_tx_count_24h: f32 = 20;
pub const max_merchant_avg_amount: f32 = 10000;

pub fn clamp01(v: f32) f32 {
    if (v < 0) return 0;
    if (v > 1) return 1;
    return v;
}

pub fn round4(v: f32) f32 {
    if (v == -1) return -1;
    return @floatCast(@round(@as(f64, v) * 10000.0) / 10000.0);
}

pub fn boolFloat(b: bool) f32 {
    return if (b) 1 else 0;
}

pub fn safeFloat(v: f32) f32 {
    if (std.math.isNan(v) or std.math.isInf(v)) return 1;
    return v;
}

test "clamp01 keeps mid-range values" {
    try testing.expectEqual(@as(f32, 0.5), clamp01(0.5));
    try testing.expectEqual(@as(f32, 0), clamp01(0));
    try testing.expectEqual(@as(f32, 1), clamp01(1));
}
test "clamp01 clips out-of-range" {
    try testing.expectEqual(@as(f32, 0), clamp01(-3));
    try testing.expectEqual(@as(f32, 1), clamp01(7));
}
test "round4 rounds to 4 decimals" {
    try testing.expectEqual(@as(f32, 0.1235), round4(0.123456));
    try testing.expectEqual(@as(f32, 0), round4(0));
}
test "round4 passes -1 sentinel through" {
    try testing.expectEqual(@as(f32, -1), round4(-1));
}
test "boolFloat true and false" {
    try testing.expectEqual(@as(f32, 1), boolFloat(true));
    try testing.expectEqual(@as(f32, 0), boolFloat(false));
}
test "safeFloat replaces NaN and Inf with 1" {
    try testing.expectEqual(@as(f32, 1), safeFloat(std.math.nan(f32)));
    try testing.expectEqual(@as(f32, 1), safeFloat(std.math.inf(f32)));
    try testing.expectEqual(@as(f32, 1), safeFloat(-std.math.inf(f32)));
    try testing.expectEqual(@as(f32, 0.5), safeFloat(0.5));
}

pub const Payload = struct {
    id: []const u8,
    transaction: Transaction,
    customer: Customer,
    merchant: Merchant,
    terminal: Terminal,
    last_transaction: ?LastTransaction,

    pub const Transaction = struct {
        amount: f32,
        installments: i32,
        requested_at: []const u8,
    };
    pub const Customer = struct {
        avg_amount: f32,
        tx_count_24h: i32,
        known_merchants: []const []const u8,
    };
    pub const Merchant = struct {
        id: []const u8,
        mcc: []const u8,
        avg_amount: f32,
    };
    pub const Terminal = struct {
        is_online: bool,
        card_present: bool,
        km_from_home: f32,
    };
    pub const LastTransaction = struct {
        timestamp: []const u8,
        km_from_current: f32,
    };
};

pub const dim: usize = 14;

pub fn buildFloat(p: *const Payload, dst: *[dim]f32) void {
    dst[0] = clamp01(p.transaction.amount / max_amount);
    dst[1] = clamp01(@as(f32, @floatFromInt(p.transaction.installments)) / max_installments);

    if (p.customer.avg_amount == 0) {
        dst[2] = 1;
    } else {
        const ratio = (p.transaction.amount / p.customer.avg_amount) / amount_vs_avg_ratio;
        dst[2] = clamp01(safeFloat(ratio));
    }

    const tx_ts = time_parse.parseRFC3339Z(p.transaction.requested_at) catch {
        dst[3] = 0;
        dst[4] = 0;
        finishWithoutPrev(p, dst);
        return;
    };
    dst[3] = @as(f32, @floatFromInt(time_parse.hourUTC(tx_ts))) / 23.0;
    dst[4] = @as(f32, @floatFromInt(time_parse.rinhaWeekday(tx_ts))) / 6.0;

    if (p.last_transaction) |lt| {
        const prev_ts = time_parse.parseRFC3339Z(lt.timestamp) catch {
            dst[5] = -1;
            dst[6] = clamp01(lt.km_from_current / max_km);
            finishCommon(p, dst);
            return;
        };
        const minutes = @as(f32, @floatFromInt(tx_ts - prev_ts)) / 60.0;
        dst[5] = clamp01(minutes / max_minutes);
        dst[6] = clamp01(lt.km_from_current / max_km);
    } else {
        dst[5] = -1;
        dst[6] = -1;
    }
    finishCommon(p, dst);
}

fn finishWithoutPrev(p: *const Payload, dst: *[dim]f32) void {
    if (p.last_transaction) |lt| {
        dst[5] = -1;
        dst[6] = clamp01(lt.km_from_current / max_km);
    } else {
        dst[5] = -1;
        dst[6] = -1;
    }
    finishCommon(p, dst);
}

fn finishCommon(p: *const Payload, dst: *[dim]f32) void {
    dst[7] = clamp01(p.terminal.km_from_home / max_km);
    dst[8] = clamp01(@as(f32, @floatFromInt(p.customer.tx_count_24h)) / max_tx_count_24h);
    dst[9] = boolFloat(p.terminal.is_online);
    dst[10] = boolFloat(p.terminal.card_present);

    var known = false;
    for (p.customer.known_merchants) |m| {
        if (std.mem.eql(u8, m, p.merchant.id)) {
            known = true;
            break;
        }
    }
    dst[11] = boolFloat(!known);
    dst[12] = mcc.risk(p.merchant.mcc);
    dst[13] = clamp01(p.merchant.avg_amount / max_merchant_avg_amount);

    for (dst) |*v| v.* = round4(v.*);
}

test "buildFloat basic shape" {
    var dst: [dim]f32 = undefined;
    const p = Payload{
        .id = "abc",
        .transaction = .{ .amount = 250, .installments = 3, .requested_at = "2025-11-15T14:30:00Z" },
        .customer = .{ .avg_amount = 100, .tx_count_24h = 4, .known_merchants = &[_][]const u8{ "m1", "m2" } },
        .merchant = .{ .id = "m3", .mcc = "5411", .avg_amount = 200 },
        .terminal = .{ .is_online = true, .card_present = true, .km_from_home = 5.2 },
        .last_transaction = .{ .timestamp = "2025-11-15T13:45:00Z", .km_from_current = 3.1 },
    };
    buildFloat(&p, &dst);

    try testing.expectApproxEqAbs(@as(f32, 0.025), dst[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.25), dst[1], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.25), dst[2], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 14.0 / 23.0), dst[3], 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 5.0 / 6.0), dst[4], 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 45.0 / 1440.0), dst[5], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 3.1 / 1000.0), dst[6], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 5.2 / 1000.0), dst[7], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 4.0 / 20.0), dst[8], 1e-4);
    try testing.expectEqual(@as(f32, 1), dst[9]);
    try testing.expectEqual(@as(f32, 1), dst[10]);
    try testing.expectEqual(@as(f32, 1), dst[11]);
    try testing.expectApproxEqAbs(@as(f32, 0.15), dst[12], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.02), dst[13], 1e-4);
}

test "buildFloat without last_transaction sets dim 5,6 to -1" {
    var dst: [dim]f32 = undefined;
    const p = Payload{
        .id = "x",
        .transaction = .{ .amount = 100, .installments = 1, .requested_at = "2025-01-01T00:00:00Z" },
        .customer = .{ .avg_amount = 50, .tx_count_24h = 0, .known_merchants = &[_][]const u8{} },
        .merchant = .{ .id = "m", .mcc = "9999", .avg_amount = 100 },
        .terminal = .{ .is_online = false, .card_present = false, .km_from_home = 0 },
        .last_transaction = null,
    };
    buildFloat(&p, &dst);
    try testing.expectEqual(@as(f32, -1), dst[5]);
    try testing.expectEqual(@as(f32, -1), dst[6]);
}

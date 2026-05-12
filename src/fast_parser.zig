const std = @import("std");
const testing = std.testing;
const time_parse = @import("time_parse.zig");
const mcc = @import("mcc.zig");

const max_amount: f32 = 10000;
const max_installments: f32 = 12;
const amount_vs_avg_ratio: f32 = 10;
const max_minutes: f32 = 1440;
const max_km: f32 = 1000;
const max_tx_count_24h: f32 = 20;
const max_merchant_avg_amount: f32 = 10000;

pub const ParseError = error{ Malformed, BadNumber, BadDate };

fn clamp01(v: f32) f32 {
    if (v < 0) return 0;
    if (v > 1) return 1;
    return v;
}

fn safeFloat(v: f32) f32 {
    if (std.math.isNan(v) or std.math.isInf(v)) return 1;
    return v;
}

fn round4(v: f32) f32 {
    if (v == -1) return -1;
    return @floatCast(@round(@as(f64, v) * 10000.0) / 10000.0);
}

const Cursor = struct {
    buf: []const u8,
    pos: usize,

    inline fn peek(self: *const Cursor) ?u8 {
        if (self.pos >= self.buf.len) return null;
        return self.buf[self.pos];
    }

    inline fn skipWs(self: *Cursor) void {
        while (self.pos < self.buf.len) {
            const c = self.buf[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') self.pos += 1 else break;
        }
    }

    fn nextKeyRawValue(self: *Cursor) !void {
        while (self.pos < self.buf.len) {
            if (self.buf[self.pos] != '"') {
                self.pos += 1;
                continue;
            }
            var end = self.pos + 1;
            while (end < self.buf.len and self.buf[end] != '"') end += 1;
            if (end + 1 < self.buf.len and self.buf[end + 1] == ':') {
                self.pos = end + 2;
                self.skipWs();
                return;
            }
            self.pos = end + 1;
        }
        return ParseError.Malformed;
    }

    fn nextKeyValueStart(self: *Cursor) !void {
        while (true) {
            try self.nextKeyRawValue();
            const c = self.peek() orelse return ParseError.Malformed;
            if (c == '{') {
                self.pos += 1;
                continue;
            }
            return;
        }
    }

    fn readF32(self: *Cursor) !f32 {
        try self.nextKeyValueStart();
        const start = self.pos;
        while (self.pos < self.buf.len) {
            const c = self.buf[self.pos];
            if (c == '-' or c == '+' or c == '.' or c == 'e' or c == 'E' or (c >= '0' and c <= '9')) {
                self.pos += 1;
            } else break;
        }
        if (self.pos == start) return ParseError.BadNumber;
        return parseF32Lit(self.buf[start..self.pos]);
    }

    fn readI32(self: *Cursor) !i32 {
        try self.nextKeyValueStart();
        const start = self.pos;
        while (self.pos < self.buf.len) {
            const c = self.buf[self.pos];
            if (c == '-' or (c >= '0' and c <= '9')) {
                self.pos += 1;
            } else break;
        }
        if (self.pos == start) return ParseError.BadNumber;
        return parseI32Lit(self.buf[start..self.pos]);
    }

    fn readString(self: *Cursor) ![]const u8 {
        try self.nextKeyValueStart();
        if (self.peek() != @as(?u8, '"')) return ParseError.Malformed;
        self.pos += 1;
        const start = self.pos;
        while (self.pos < self.buf.len and self.buf[self.pos] != '"') self.pos += 1;
        if (self.pos >= self.buf.len) return ParseError.Malformed;
        const end = self.pos;
        self.pos += 1;
        return self.buf[start..end];
    }

    fn readBool(self: *Cursor) !bool {
        try self.nextKeyValueStart();
        const remaining = self.buf.len - self.pos;
        if (remaining >= 4 and std.mem.eql(u8, self.buf[self.pos .. self.pos + 4], "true")) {
            self.pos += 4;
            return true;
        }
        if (remaining >= 5 and std.mem.eql(u8, self.buf[self.pos .. self.pos + 5], "false")) {
            self.pos += 5;
            return false;
        }
        return ParseError.Malformed;
    }

    fn readKnownMerchants(self: *Cursor, slots: *[16][]const u8, count: *u8) !void {
        try self.nextKeyRawValue();
        if (self.peek() != @as(?u8, '[')) return ParseError.Malformed;
        self.pos += 1;
        var n: u8 = 0;
        while (self.pos < self.buf.len) {
            self.skipWs();
            const c = self.peek() orelse return ParseError.Malformed;
            if (c == ']') {
                self.pos += 1;
                count.* = n;
                return;
            }
            if (c == ',') {
                self.pos += 1;
                continue;
            }
            if (c != '"') return ParseError.Malformed;
            self.pos += 1;
            const start = self.pos;
            while (self.pos < self.buf.len and self.buf[self.pos] != '"') self.pos += 1;
            if (self.pos >= self.buf.len) return ParseError.Malformed;
            if (n < 16) {
                slots[n] = self.buf[start..self.pos];
                n += 1;
            }
            self.pos += 1;
        }
        return ParseError.Malformed;
    }

    fn lastTxIsNull(self: *Cursor) !bool {
        try self.nextKeyRawValue();
        const c = self.peek() orelse return ParseError.Malformed;
        if (c == 'n') {
            const remaining = self.buf.len - self.pos;
            if (remaining >= 4 and std.mem.eql(u8, self.buf[self.pos .. self.pos + 4], "null")) {
                self.pos += 4;
                return true;
            }
            return ParseError.Malformed;
        }
        if (c != '{') return ParseError.Malformed;
        self.pos += 1;
        return false;
    }
};

fn parseF32Lit(s: []const u8) ParseError!f32 {
    if (s.len == 0) return ParseError.BadNumber;

    var i: usize = 0;
    var sign: f64 = 1;
    if (s[i] == '-') {
        sign = -1;
        i += 1;
    } else if (s[i] == '+') {
        i += 1;
    }
    if (i >= s.len) return ParseError.BadNumber;

    var digits: usize = 0;
    var int_part: f64 = 0;
    while (i < s.len and isDigit(s[i])) : (i += 1) {
        int_part = int_part * 10 + @as(f64, @floatFromInt(s[i] - '0'));
        digits += 1;
    }

    var frac_part: f64 = 0;
    var frac_scale: f64 = 1;
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and isDigit(s[i])) : (i += 1) {
            frac_part = frac_part * 10 + @as(f64, @floatFromInt(s[i] - '0'));
            frac_scale *= 10;
            digits += 1;
        }
    }
    if (digits == 0) return ParseError.BadNumber;

    var value = sign * (int_part + frac_part / frac_scale);
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        i += 1;
        if (i >= s.len) return ParseError.BadNumber;
        var exp_sign: i32 = 1;
        if (s[i] == '-') {
            exp_sign = -1;
            i += 1;
        } else if (s[i] == '+') {
            i += 1;
        }
        if (i >= s.len or !isDigit(s[i])) return ParseError.BadNumber;
        var exp: i32 = 0;
        while (i < s.len and isDigit(s[i])) : (i += 1) {
            exp = exp * 10 + @as(i32, @intCast(s[i] - '0'));
            if (exp > 64) break;
        }
        value *= pow10i(exp_sign * exp);
        while (i < s.len and isDigit(s[i])) : (i += 1) {}
    }

    if (i != s.len) return ParseError.BadNumber;
    return @floatCast(value);
}

fn parseI32Lit(s: []const u8) ParseError!i32 {
    if (s.len == 0) return ParseError.BadNumber;
    var i: usize = 0;
    var sign: i32 = 1;
    if (s[i] == '-') {
        sign = -1;
        i += 1;
    }
    if (i >= s.len or !isDigit(s[i])) return ParseError.BadNumber;

    var value: i32 = 0;
    while (i < s.len and isDigit(s[i])) : (i += 1) {
        value = value * 10 + @as(i32, @intCast(s[i] - '0'));
    }
    if (i != s.len) return ParseError.BadNumber;
    return value * sign;
}

inline fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn pow10i(exp: i32) f64 {
    if (exp == 0) return 1;
    var e: u32 = @intCast(if (exp < 0) -exp else exp);
    var base: f64 = 10;
    var result: f64 = 1;
    while (e != 0) : (e >>= 1) {
        if ((e & 1) != 0) result *= base;
        base *= base;
    }
    return if (exp < 0) 1 / result else result;
}

pub fn parseFeatures(body: []const u8, dst: *[14]f32) ParseError!void {
    var c = Cursor{ .buf = body, .pos = 0 };

    _ = try c.readString();
    const amount = try c.readF32();
    const installments = try c.readI32();
    const requested_at = try c.readString();

    const cust_avg = try c.readF32();
    const tx_count = try c.readI32();
    var known: [16][]const u8 = undefined;
    var n_known: u8 = 0;
    try c.readKnownMerchants(&known, &n_known);

    const merch_id = try c.readString();
    const merch_mcc = try c.readString();
    const merch_avg = try c.readF32();

    const is_online = try c.readBool();
    const card_present = try c.readBool();
    const km_from_home = try c.readF32();

    const is_null = try c.lastTxIsNull();
    const has_last = !is_null;
    var last_ts: []const u8 = "";
    var last_km: f32 = 0;
    if (has_last) {
        last_ts = try c.readString();
        last_km = try c.readF32();
    }

    dst[0] = clamp01(amount / max_amount);
    dst[1] = clamp01(@as(f32, @floatFromInt(installments)) / max_installments);
    if (cust_avg == 0) {
        dst[2] = 1;
    } else {
        const ratio = (amount / cust_avg) / amount_vs_avg_ratio;
        dst[2] = clamp01(safeFloat(ratio));
    }

    const tx_ts = time_parse.parseRFC3339Z(requested_at) catch {
        dst[3] = 0;
        dst[4] = 0;
        if (has_last) {
            dst[5] = -1;
            dst[6] = clamp01(last_km / max_km);
        } else {
            dst[5] = -1;
            dst[6] = -1;
        }
        finishFromValues(km_from_home, tx_count, is_online, card_present, &known, n_known, merch_id, merch_mcc, merch_avg, dst);
        return;
    };
    dst[3] = @as(f32, @floatFromInt(time_parse.hourUTC(tx_ts))) / 23.0;
    dst[4] = @as(f32, @floatFromInt(time_parse.rinhaWeekday(tx_ts))) / 6.0;

    if (has_last) {
        const prev_ts = time_parse.parseRFC3339Z(last_ts) catch {
            dst[5] = -1;
            dst[6] = clamp01(last_km / max_km);
            finishFromValues(km_from_home, tx_count, is_online, card_present, &known, n_known, merch_id, merch_mcc, merch_avg, dst);
            return;
        };
        const minutes = @as(f32, @floatFromInt(tx_ts - prev_ts)) / 60.0;
        dst[5] = clamp01(minutes / max_minutes);
        dst[6] = clamp01(last_km / max_km);
    } else {
        dst[5] = -1;
        dst[6] = -1;
    }
    finishFromValues(km_from_home, tx_count, is_online, card_present, &known, n_known, merch_id, merch_mcc, merch_avg, dst);
}

fn finishFromValues(
    km_from_home: f32,
    tx_count: i32,
    is_online: bool,
    card_present: bool,
    known: *const [16][]const u8,
    n_known: u8,
    merch_id: []const u8,
    merch_mcc: []const u8,
    merch_avg: f32,
    dst: *[14]f32,
) void {
    dst[7] = clamp01(km_from_home / max_km);
    dst[8] = clamp01(@as(f32, @floatFromInt(tx_count)) / max_tx_count_24h);
    dst[9] = if (is_online) 1 else 0;
    dst[10] = if (card_present) 1 else 0;

    var is_known = false;
    var i: usize = 0;
    while (i < n_known) : (i += 1) {
        if (std.mem.eql(u8, known[i], merch_id)) {
            is_known = true;
            break;
        }
    }
    dst[11] = if (is_known) 0 else 1;
    dst[12] = mcc.risk(merch_mcc);
    dst[13] = clamp01(merch_avg / max_merchant_avg_amount);

    for (dst) |*v| v.* = round4(v.*);
}

test "parseFeatures basic shape matches buildFloat" {
    const body =
        \\{"id":"a","transaction":{"amount":250,"installments":3,"requested_at":"2025-11-15T14:30:00Z"},
        \\"customer":{"avg_amount":100,"tx_count_24h":4,"known_merchants":["m1","m2"]},
        \\"merchant":{"id":"m3","mcc":"5411","avg_amount":200},
        \\"terminal":{"is_online":true,"card_present":true,"km_from_home":5.2},
        \\"last_transaction":{"timestamp":"2025-11-15T13:45:00Z","km_from_current":3.1}}
    ;
    var dst: [14]f32 = undefined;
    try parseFeatures(body, &dst);
    try testing.expectApproxEqAbs(@as(f32, 0.025), dst[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.25), dst[1], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.25), dst[2], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 5.0 / 6.0), dst[4], 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 45.0 / 1440.0), dst[5], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 5.2 / 1000.0), dst[7], 1e-4);
    try testing.expectEqual(@as(f32, 1), dst[9]);
    try testing.expectEqual(@as(f32, 1), dst[10]);
    try testing.expectEqual(@as(f32, 1), dst[11]);
    try testing.expectApproxEqAbs(@as(f32, 0.15), dst[12], 1e-4);
}

test "parseFeatures with null last_transaction" {
    const body =
        \\{"id":"x","transaction":{"amount":100,"installments":1,"requested_at":"2025-01-01T00:00:00Z"},
        \\"customer":{"avg_amount":50,"tx_count_24h":0,"known_merchants":[]},
        \\"merchant":{"id":"m","mcc":"9999","avg_amount":100},
        \\"terminal":{"is_online":false,"card_present":false,"km_from_home":0},
        \\"last_transaction":null}
    ;
    var dst: [14]f32 = undefined;
    try parseFeatures(body, &dst);
    try testing.expectEqual(@as(f32, -1), dst[5]);
    try testing.expectEqual(@as(f32, -1), dst[6]);
}

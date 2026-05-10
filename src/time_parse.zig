const std = @import("std");
const testing = std.testing;

pub const ParseError = error{InvalidFormat};

pub fn parseRFC3339Z(s: []const u8) ParseError!i64 {
    if (s.len != 20) return ParseError.InvalidFormat;
    if (s[4] != '-' or s[7] != '-' or s[10] != 'T' or s[13] != ':' or s[16] != ':' or s[19] != 'Z') {
        return ParseError.InvalidFormat;
    }
    const y: i64 = try parseN(s[0..4]);
    const mo: i64 = try parseN(s[5..7]);
    const d: i64 = try parseN(s[8..10]);
    const h: i64 = try parseN(s[11..13]);
    const mi: i64 = try parseN(s[14..16]);
    const se: i64 = try parseN(s[17..19]);
    const days = daysFromCivil(y, @intCast(mo), @intCast(d));
    return days * 86400 + h * 3600 + mi * 60 + se;
}

fn parseN(buf: []const u8) ParseError!i64 {
    var v: i64 = 0;
    for (buf) |c| {
        if (c < '0' or c > '9') return ParseError.InvalidFormat;
        v = v * 10 + (c - '0');
    }
    return v;
}

fn daysFromCivil(y_in: i64, m: u32, d: u32) i64 {
    var y = y_in;
    if (m <= 2) y -= 1;
    const era = if (y >= 0) @divFloor(y, 400) else @divFloor(y - 399, 400);
    const yoe: u32 = @intCast(y - era * 400);
    const m_adj: u32 = if (m > 2) m - 3 else m + 9;
    const doy: u32 = (153 * m_adj + 2) / 5 + d - 1;
    const doe: u32 = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + @as(i64, doe) - 719468;
}

pub fn hourUTC(unix_seconds: i64) u8 {
    const sec_of_day = @mod(unix_seconds, 86400);
    return @intCast(@divTrunc(sec_of_day, 3600));
}

pub fn rinhaWeekday(unix_seconds: i64) u8 {
    const days = @divFloor(unix_seconds, 86400);
    const go_wd: u8 = @intCast(@mod(days + 4, 7));
    return @intCast(@mod(@as(u32, go_wd) + 6, 7));
}

test "parse a known timestamp" {
    const ts = try parseRFC3339Z("2025-11-15T14:30:00Z");
    try testing.expectEqual(@as(i64, 1763217000), ts);
}
test "parse epoch" {
    try testing.expectEqual(@as(i64, 0), try parseRFC3339Z("1970-01-01T00:00:00Z"));
}
test "reject wrong length" {
    try testing.expectError(ParseError.InvalidFormat, parseRFC3339Z("2025-11-15"));
}
test "reject missing Z" {
    try testing.expectError(ParseError.InvalidFormat, parseRFC3339Z("2025-11-15T14:30:00X"));
}
test "weekday derivation" {
    const ts = try parseRFC3339Z("2025-11-15T00:00:00Z");
    try testing.expectEqual(@as(u8, 5), rinhaWeekday(ts));
}
test "hour derivation" {
    const ts = try parseRFC3339Z("2025-11-15T14:30:00Z");
    try testing.expectEqual(@as(u8, 14), hourUTC(ts));
}

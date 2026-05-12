const std = @import("std");
const builtin = @import("builtin");
const fdpass = @import("fdpass");

pub const std_options: std.Options = .{
    .log_level = .err,
};

const linux = if (builtin.os.tag == .linux) std.os.linux else struct {};

const ring_entries: u16 = 1024;
const accept_idx: u32 = std.math.maxInt(u32);
const diag_instrument = true;

const Op = enum(u8) { accept = 1, close_orphan };

const DiagMetric = enum(usize) {
    pass_fd,
};

const diag_metric_count: usize = 1;
const diag_metric_names = [_][]const u8{"pass_fd"};
const diag_bucket_limits_us = [_]u64{ 1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384 };
const diag_bucket_count = diag_bucket_limits_us.len + 1;

const DiagHist = struct {
    count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    sum_us: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    buckets: [diag_bucket_count]std.atomic.Value(u64) = .{std.atomic.Value(u64).init(0)} ** diag_bucket_count,

    fn record(self: *DiagHist, ns: u64) void {
        const us = ns / 1000;
        _ = self.count.fetchAdd(1, .monotonic);
        _ = self.sum_us.fetchAdd(us, .monotonic);
        _ = self.buckets[diagBucketIndex(us)].fetchAdd(1, .monotonic);
    }

    fn percentileUpperUs(self: *DiagHist, total: u64, pct: u64) u64 {
        if (total == 0) return 0;
        const target = (total * pct + 99) / 100;
        var acc: u64 = 0;
        var i: usize = 0;
        while (i < diag_bucket_count) : (i += 1) {
            acc += self.buckets[i].load(.monotonic);
            if (acc >= target) {
                if (i < diag_bucket_limits_us.len) return diag_bucket_limits_us[i];
                return std.math.maxInt(u64);
            }
        }
        return std.math.maxInt(u64);
    }
};

var diag_hists: [diag_metric_count]DiagHist = .{DiagHist{}} ** diag_metric_count;

fn diagBucketIndex(us: u64) usize {
    var i: usize = 0;
    while (i < diag_bucket_limits_us.len) : (i += 1) {
        if (us <= diag_bucket_limits_us[i]) return i;
    }
    return diag_bucket_limits_us.len;
}

fn diagNowNs() u64 {
    return @intCast(std.time.nanoTimestamp());
}

fn diagElapsedNs(start_ns: u64) u64 {
    const end_ns = diagNowNs();
    return if (end_ns >= start_ns) end_ns - start_ns else 0;
}

fn diagRecord(metric: DiagMetric, ns: u64) void {
    if (!diag_instrument) return;
    diag_hists[@intFromEnum(metric)].record(ns);
}

fn diagStatsThread() void {
    while (true) {
        std.time.sleep(2 * std.time.ns_per_s);
        var i: usize = 0;
        while (i < diag_metric_count) : (i += 1) {
            const hist = &diag_hists[i];
            const count = hist.count.load(.monotonic);
            if (count == 0) continue;
            const sum_us = hist.sum_us.load(.monotonic);
            const mean_us = sum_us / count;
            const p50_us = hist.percentileUpperUs(count, 50);
            const p90_us = hist.percentileUpperUs(count, 90);
            const p99_us = hist.percentileUpperUs(count, 99);
            std.debug.print(
                "INSTR lb metric={s} count={} mean_us={} p50_le_us={} p90_le_us={} p99_le_us={}\n",
                .{ diag_metric_names[i], count, mean_us, p50_us, p90_us, p99_us },
            );
        }
    }
}

var ctrl_paths: [][:0]const u8 = undefined;
var ctrl_fds: []i32 = undefined;
var rr_counter: usize = 0;

pub fn main(init: std.process.Init) !void {
    const ally = init.arena.allocator();

    var it = try init.minimal.args.iterateAllocator(ally);
    defer it.deinit();
    _ = it.next();

    var arg_list: std.ArrayList([]const u8) = .empty;
    while (it.next()) |a| {
        try arg_list.append(ally, try ally.dupe(u8, a));
    }
    const args = arg_list.items;
    if (args.len < 3) {
        std.log.err("usage: lb <bind_host:port> <api_sock_1> <api_sock_2> [...]", .{});
        return error.BadArgs;
    }

    if (builtin.os.tag != .linux) {
        std.log.err("lb: only linux is supported", .{});
        return error.Unsupported;
    }

    ctrl_paths = try ally.alloc([:0]const u8, args.len - 1);
    ctrl_fds = try ally.alloc(i32, args.len - 1);
    for (args[1..], 0..) |sock_path, i| {
        ctrl_paths[i] = try std.mem.concatWithSentinel(ally, u8, &.{ sock_path, ".ctrl" }, 0);
        ctrl_fds[i] = connectWithRetry(ctrl_paths[i]);
    }

    const listen_fd = try openTcpListener(args[0]);
    std.log.info("lb: fd-pass listening on {s}, upstreams={d}", .{ args[0], ctrl_fds.len });
    if (diag_instrument) {
        if (std.Thread.spawn(.{}, diagStatsThread, .{}) catch null) |t| t.detach();
    }

    try runIoUringLoop(listen_fd);
}

fn parseHostPort(s: []const u8) !struct { host: []const u8, port: u16 } {
    const colon = std.mem.lastIndexOfScalar(u8, s, ':') orelse return error.BadBind;
    const host = s[0..colon];
    const port = try std.fmt.parseInt(u16, s[colon + 1 ..], 10);
    return .{ .host = host, .port = port };
}

fn parseIp4(host: []const u8) !u32 {
    var parts: [4]u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, host, '.');
    while (it.next()) |p| {
        if (n >= 4) return error.BadAddr;
        parts[n] = std.fmt.parseInt(u8, p, 10) catch return error.BadAddr;
        n += 1;
    }
    if (n != 4) return error.BadAddr;
    return std.mem.readInt(u32, &parts, .big);
}

fn openTcpListener(bind_arg: []const u8) !i32 {
    if (builtin.os.tag != .linux) return error.Unsupported;
    const hp = try parseHostPort(bind_arg);

    const addr: u32 = if (std.mem.eql(u8, hp.host, "0.0.0.0") or hp.host.len == 0)
        0
    else
        try parseIp4(hp.host);

    const fd_r = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(fd_r) != .SUCCESS) return error.SocketFailed;
    const fd: i32 = @intCast(@as(isize, @bitCast(fd_r)));

    const one: i32 = 1;
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, std.mem.asBytes(&one), @sizeOf(i32));
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEPORT, std.mem.asBytes(&one), @sizeOf(i32));

    var sin: linux.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, hp.port),
        .addr = std.mem.nativeToBig(u32, addr),
    };
    const sa_ptr: *const linux.sockaddr = @ptrCast(&sin);
    const br = linux.bind(fd, sa_ptr, @sizeOf(linux.sockaddr.in));
    if (linux.errno(br) != .SUCCESS) {
        _ = linux.close(fd);
        return error.BindFailed;
    }
    const lr = linux.listen(fd, 65535);
    if (linux.errno(lr) != .SUCCESS) {
        _ = linux.close(fd);
        return error.ListenFailed;
    }
    return fd;
}

fn connectWithRetry(path: [:0]const u8) i32 {
    while (true) {
        if (fdpass.connectUnix(path)) |fd| {
            return fd;
        } else |_| {
            var ts: linux.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
            _ = linux.nanosleep(&ts, null);
        }
    }
}

fn makeUd(idx: u32, op: Op) u64 {
    const op_byte: u64 = @intFromEnum(op);
    return (op_byte << 32) | @as(u64, idx);
}

fn parseUd(ud: u64) struct { idx: u32, op: Op } {
    return .{
        .idx = @truncate(ud),
        .op = @enumFromInt(@as(u8, @truncate(ud >> 32))),
    };
}

fn runIoUringLoop(listen_fd: i32) !void {
    if (builtin.os.tag != .linux) return error.Unsupported;
    var ring = try linux.IoUring.init(ring_entries, 0);
    defer ring.deinit();

    _ = try ring.accept(makeUd(accept_idx, .accept), listen_fd, null, null, linux.SOCK.CLOEXEC);

    var cqes: [128]linux.io_uring_cqe = undefined;
    while (true) {
        _ = ring.submit_and_wait(1) catch |err| switch (err) {
            error.SignalInterrupt => continue,
            else => return err,
        };

        const n = try ring.copy_cqes(&cqes, 0);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const cqe = cqes[i];
            const ud = parseUd(cqe.user_data);
            switch (ud.op) {
                .accept => {
                    if (cqe.res >= 0) {
                        try passAcceptedFd(cqe.res);
                    }
                    _ = try ring.accept(makeUd(accept_idx, .accept), listen_fd, null, null, linux.SOCK.CLOEXEC);
                },
                .close_orphan => {},
            }
        }
    }
}

fn passAcceptedFd(client_fd: i32) !void {
    const pass_start = diagNowNs();
    defer diagRecord(.pass_fd, diagElapsedNs(pass_start));

    setNoDelay(client_fd);

    const idx = rr_counter % ctrl_fds.len;
    rr_counter +%= 1;

    fdpass.sendFd(ctrl_fds[idx], client_fd) catch {
        fdpass.closeFd(ctrl_fds[idx]);
        ctrl_fds[idx] = connectWithRetry(ctrl_paths[idx]);
        fdpass.sendFd(ctrl_fds[idx], client_fd) catch {
            fdpass.closeFd(client_fd);
            return;
        };
    };
    fdpass.closeFd(client_fd);
}

fn setNoDelay(fd: i32) void {
    const one: i32 = 1;
    _ = linux.setsockopt(fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, std.mem.asBytes(&one), @sizeOf(i32));
}

test "parseHostPort extracts host and port" {
    const hp = try parseHostPort("0.0.0.0:9999");
    try std.testing.expectEqualStrings("0.0.0.0", hp.host);
    try std.testing.expectEqual(@as(u16, 9999), hp.port);
}

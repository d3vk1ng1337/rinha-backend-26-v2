const std = @import("std");
const builtin = @import("builtin");
const fdpass = @import("fdpass");

pub const std_options: std.Options = .{
    .log_level = .err,
};

const linux = if (builtin.os.tag == .linux) std.os.linux else struct {};

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

    try runAcceptLoop(listen_fd);
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

fn runAcceptLoop(listen_fd: i32) !void {
    if (builtin.os.tag != .linux) return error.Unsupported;

    while (true) {
        const accept_r = linux.accept4(listen_fd, null, null, linux.SOCK.CLOEXEC);
        switch (linux.errno(accept_r)) {
            .SUCCESS => try passAcceptedFd(@intCast(@as(isize, @bitCast(accept_r)))),
            .INTR => continue,
            else => continue,
        }
    }
}

fn passAcceptedFd(client_fd: i32) !void {
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

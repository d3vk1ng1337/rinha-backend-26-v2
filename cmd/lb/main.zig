const std = @import("std");
const builtin = @import("builtin");

const linux = if (builtin.os.tag == .linux) std.os.linux else struct {};

const buf_size: usize = 4 * 1024;
const pool_size: usize = 512;
const ring_entries: u16 = 2048;

const Op = enum(u8) {
    accept = 1,
    connect_up,
    read_c,
    read_u,
    write_c,
    write_u,
    close_c,
    close_u,
    close_orphan,
};

const PairIdx = u32;
const accept_idx: PairIdx = std.math.maxInt(PairIdx);

const State = enum { connecting, forwarding, dying };

const Pair = struct {
    client_fd: i32 = -1,
    upstream_fd: i32 = -1,
    state: State = .dying,
    c2u_buf: [buf_size]u8 = undefined,
    u2c_buf: [buf_size]u8 = undefined,
    c_read_in: bool = false,
    u_read_in: bool = false,
    c_write_in: bool = false,
    u_write_in: bool = false,
    c_close_in: bool = false,
    u_close_in: bool = false,
    c_closed: bool = false,
    u_closed: bool = false,
    upstream_addr: if (builtin.os.tag == .linux) linux.sockaddr.un else void = undefined,
    upstream_path_len: u16 = 0,
};

var pairs: [pool_size]Pair = undefined;
var free_stack: [pool_size]PairIdx = undefined;
var free_top: usize = 0;

var upstream_paths: [][]const u8 = undefined;
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
        std.log.err("usage: lb <bind_host:port> <upstream_sock_1> <upstream_sock_2> [...]", .{});
        return error.BadArgs;
    }

    const bind_arg = args[0];
    upstream_paths = args[1..];

    for (0..pool_size) |i| pairs[i] = .{};
    free_top = 0;
    var i: usize = pool_size;
    while (i > 0) {
        i -= 1;
        free_stack[free_top] = @intCast(i);
        free_top += 1;
    }

    if (builtin.os.tag != .linux) {
        std.log.err("lb: only linux is supported", .{});
        return error.Unsupported;
    }

    const listen_fd = try openTcpListener(bind_arg);
    std.log.info("lb: listening on {s}, upstreams={d}", .{ bind_arg, upstream_paths.len });

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
    const lr = linux.listen(fd, 4096);
    if (linux.errno(lr) != .SUCCESS) {
        _ = linux.close(fd);
        return error.ListenFailed;
    }
    return fd;
}

fn makeUd(idx: PairIdx, op: Op) u64 {
    const op_byte: u64 = @intFromEnum(op);
    return (op_byte << 32) | @as(u64, idx);
}

fn parseUd(ud: u64) struct { idx: PairIdx, op: Op } {
    return .{
        .idx = @truncate(ud),
        .op = @enumFromInt(@as(u8, @truncate(ud >> 32))),
    };
}

fn buildUnixAddr(p: *Pair, path: []const u8) !void {
    if (path.len >= 108) return error.PathTooLong;
    p.upstream_addr = .{ .path = undefined };
    @memset(&p.upstream_addr.path, 0);
    @memcpy(p.upstream_addr.path[0..path.len], path);
    p.upstream_path_len = @intCast(path.len);
}

fn runIoUringLoop(listen_fd: i32) !void {
    if (builtin.os.tag != .linux) return error.Unsupported;
    var ring = try linux.IoUring.init(ring_entries, 0);
    defer ring.deinit();

    _ = try ring.accept(makeUd(accept_idx, .accept), listen_fd, null, null, 0);

    var cqes: [128]linux.io_uring_cqe = undefined;

    while (true) {
        _ = ring.submit_and_wait(1) catch |err| switch (err) {
            error.SignalInterrupt => continue,
            else => return err,
        };

        const n = try ring.copy_cqes(&cqes, 0);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            try handleCqe(&ring, listen_fd, cqes[i]);
        }
    }
}

fn handleCqe(ring: *linux.IoUring, listen_fd: i32, cqe: linux.io_uring_cqe) !void {
    const ud = parseUd(cqe.user_data);

    switch (ud.op) {
        .accept => {
            if (cqe.res < 0) {
                std.log.warn("accept err: {}", .{cqe.err()});
            } else {
                try onAccepted(ring, cqe.res);
            }
            _ = try ring.accept(makeUd(accept_idx, .accept), listen_fd, null, null, 0);
        },
        .close_orphan => {},
        .connect_up => {
            const p = &pairs[ud.idx];
            if (cqe.res < 0) {
                std.log.warn("upstream connect failed: {}", .{cqe.err()});
                try killPair(ring, ud.idx);
                return;
            }
            p.state = .forwarding;
            try submitReadClient(ring, ud.idx);
            try submitReadUpstream(ring, ud.idx);
        },
        .read_c => {
            const p = &pairs[ud.idx];
            p.c_read_in = false;
            if (cqe.res <= 0) {
                try killPair(ring, ud.idx);
                try maybeRelease(ring, ud.idx);
                return;
            }
            if (p.state == .dying) {
                try maybeRelease(ring, ud.idx);
                return;
            }
            const got: usize = @intCast(cqe.res);
            try submitWriteUpstream(ring, ud.idx, got);
        },
        .read_u => {
            const p = &pairs[ud.idx];
            p.u_read_in = false;
            if (cqe.res <= 0) {
                try killPair(ring, ud.idx);
                try maybeRelease(ring, ud.idx);
                return;
            }
            if (p.state == .dying) {
                try maybeRelease(ring, ud.idx);
                return;
            }
            const got: usize = @intCast(cqe.res);
            try submitWriteClient(ring, ud.idx, got);
        },
        .write_c => {
            const p = &pairs[ud.idx];
            p.c_write_in = false;
            if (cqe.res <= 0) {
                try killPair(ring, ud.idx);
                try maybeRelease(ring, ud.idx);
                return;
            }
            if (p.state == .dying) {
                try maybeRelease(ring, ud.idx);
                return;
            }
            try submitReadUpstream(ring, ud.idx);
        },
        .write_u => {
            const p = &pairs[ud.idx];
            p.u_write_in = false;
            if (cqe.res <= 0) {
                try killPair(ring, ud.idx);
                try maybeRelease(ring, ud.idx);
                return;
            }
            if (p.state == .dying) {
                try maybeRelease(ring, ud.idx);
                return;
            }
            try submitReadClient(ring, ud.idx);
        },
        .close_c => {
            const p = &pairs[ud.idx];
            p.c_close_in = false;
            p.c_closed = true;
            try maybeRelease(ring, ud.idx);
        },
        .close_u => {
            const p = &pairs[ud.idx];
            p.u_close_in = false;
            p.u_closed = true;
            try maybeRelease(ring, ud.idx);
        },
    }
}

fn onAccepted(ring: *linux.IoUring, new_fd: i32) !void {
    if (free_top == 0) {
        _ = try ring.close(makeUd(accept_idx, .close_orphan), new_fd);
        return;
    }
    free_top -= 1;
    const idx = free_stack[free_top];

    const up_idx = rr_counter % upstream_paths.len;
    rr_counter +%= 1;
    const path = upstream_paths[up_idx];

    const ufd_r = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(ufd_r) != .SUCCESS) {
        free_stack[free_top] = idx;
        free_top += 1;
        _ = try ring.close(makeUd(accept_idx, .close_orphan), new_fd);
        return;
    }
    const ufd: i32 = @intCast(@as(isize, @bitCast(ufd_r)));

    const p = &pairs[idx];
    p.* = .{};
    p.client_fd = new_fd;
    p.upstream_fd = ufd;
    p.state = .connecting;
    buildUnixAddr(p, path) catch {
        _ = linux.close(ufd);
        _ = try ring.close(makeUd(accept_idx, .close_orphan), new_fd);
        free_stack[free_top] = idx;
        free_top += 1;
        return;
    };

    const sa: *const linux.sockaddr = @ptrCast(&p.upstream_addr);
    const addrlen: u32 = @intCast(@sizeOf(linux.sa_family_t) + p.upstream_path_len + 1);
    _ = try ring.connect(makeUd(idx, .connect_up), ufd, sa, addrlen);
}

fn submitReadClient(ring: *linux.IoUring, idx: PairIdx) !void {
    const p = &pairs[idx];
    if (p.state != .forwarding) return;
    if (p.c_read_in) return;
    p.c_read_in = true;
    _ = try ring.read(makeUd(idx, .read_c), p.client_fd, .{ .buffer = p.c2u_buf[0..] }, 0);
}

fn submitReadUpstream(ring: *linux.IoUring, idx: PairIdx) !void {
    const p = &pairs[idx];
    if (p.state != .forwarding) return;
    if (p.u_read_in) return;
    p.u_read_in = true;
    _ = try ring.read(makeUd(idx, .read_u), p.upstream_fd, .{ .buffer = p.u2c_buf[0..] }, 0);
}

fn submitWriteUpstream(ring: *linux.IoUring, idx: PairIdx, len: usize) !void {
    const p = &pairs[idx];
    if (p.state != .forwarding) return;
    p.u_write_in = true;
    _ = try ring.write(makeUd(idx, .write_u), p.upstream_fd, p.c2u_buf[0..len], 0);
}

fn submitWriteClient(ring: *linux.IoUring, idx: PairIdx, len: usize) !void {
    const p = &pairs[idx];
    if (p.state != .forwarding) return;
    p.c_write_in = true;
    _ = try ring.write(makeUd(idx, .write_c), p.client_fd, p.u2c_buf[0..len], 0);
}

fn killPair(ring: *linux.IoUring, idx: PairIdx) !void {
    const p = &pairs[idx];
    if (p.state == .dying) return;
    p.state = .dying;

    if (!p.c_closed and !p.c_close_in) {
        p.c_close_in = true;
        _ = try ring.close(makeUd(idx, .close_c), p.client_fd);
    }
    if (!p.u_closed and !p.u_close_in) {
        p.u_close_in = true;
        _ = try ring.close(makeUd(idx, .close_u), p.upstream_fd);
    }
}

fn maybeRelease(ring: *linux.IoUring, idx: PairIdx) !void {
    _ = ring;
    const p = &pairs[idx];
    if (p.state != .dying) return;
    if (p.c_read_in or p.u_read_in or p.c_write_in or p.u_write_in) return;
    if (p.c_close_in or p.u_close_in) return;
    if (!p.c_closed or !p.u_closed) return;

    p.client_fd = -1;
    p.upstream_fd = -1;
    free_stack[free_top] = idx;
    free_top += 1;
}

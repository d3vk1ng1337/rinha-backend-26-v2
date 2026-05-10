const std = @import("std");
const builtin = @import("builtin");
const lib = @import("lib");
const index_format = lib.index_format;
const http_io = lib.http_io;

const max_request_bytes: usize = 64 * 1024;
const max_response_bytes: usize = 256;

pub fn main(init: std.process.Init) !void {
    const ally = init.arena.allocator();
    const io = init.io;

    var it = try init.minimal.args.iterateAllocator(ally);
    defer it.deinit();
    _ = it.next();
    const sock_path = it.next() orelse "/sockets/api.sock";
    const index_path = it.next() orelse "/index/index.bin";
    std.log.info("api: socket={s} index={s}", .{ sock_path, index_path });

    const cwd = std.Io.Dir.cwd();
    const idx_file = try cwd.openFile(io, index_path, .{ .mode = .read_only });
    defer idx_file.close(io);

    const total = try idx_file.length(io);
    var mm = try std.Io.File.MemoryMap.create(io, idx_file, .{
        .len = @intCast(total),
        .protection = .{ .read = true },
        .undefined_contents = false,
        .populate = true,
        .offset = 0,
    });
    defer mm.destroy(io);

    const aligned: []align(@alignOf(index_format.Header)) const u8 = @alignCast(mm.memory);
    const reader = try index_format.Reader.init(aligned);
    std.log.info("api: index loaded — {} vectors, {} dims", .{ reader.header.num_vectors, reader.header.dim });

    cwd.deleteFile(io, sock_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    const ua = try std.Io.net.UnixAddress.init(sock_path);
    var server = try ua.listen(io, .{ .kernel_backlog = 1024 });
    defer server.deinit(io);

    const path_z = try ally.dupeZ(u8, sock_path);
    if (std.c.chmod(path_z.ptr, 0o666) != 0) std.log.warn("chmod failed on {s}", .{sock_path});

    std.log.info("api: listening on {s}", .{sock_path});

    if (builtin.os.tag == .linux) {
        std.log.info("api: io_uring loop", .{});
        try runIoUringLoop(&reader, server.socket.handle);
    } else {
        std.log.info("api: blocking loop", .{});
        try runBlockingLoop(io, &reader, &server);
    }
}

fn runBlockingLoop(
    io: std.Io,
    reader: *const index_format.Reader,
    server: *std.Io.net.Server,
) !void {
    while (true) {
        const stream = server.accept(io) catch |err| {
            std.log.warn("accept error: {}", .{err});
            continue;
        };
        handleConn(io, reader, stream) catch |err| {
            std.log.warn("conn error: {}", .{err});
        };
        stream.close(io);
    }
}

fn handleConn(
    io: std.Io,
    reader: *const index_format.Reader,
    stream: std.Io.net.Stream,
) !void {
    var read_buf: [max_request_bytes + 4096]u8 = undefined;
    var s_reader = stream.reader(io, &read_buf);
    var write_buf: [max_response_bytes + 256]u8 = undefined;
    var s_writer = stream.writer(io, &write_buf);

    const r = &s_reader.interface;
    const w = &s_writer.interface;

    const head_raw = r.takeDelimiterInclusive('\n') catch |err| switch (err) {
        error.EndOfStream => return,
        else => return err,
    };
    const head_trimmed = std.mem.trimEnd(u8, head_raw, "\r\n");

    const sp1 = std.mem.indexOfScalar(u8, head_trimmed, ' ') orelse return writeStatus(w, 400);
    const method = head_trimmed[0..sp1];
    const rest = head_trimmed[sp1 + 1 ..];
    const sp2 = std.mem.indexOfScalar(u8, rest, ' ') orelse return writeStatus(w, 400);
    const target = rest[0..sp2];

    var content_length: usize = 0;
    while (true) {
        const line_raw = r.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        const line_t = std.mem.trimEnd(u8, line_raw, "\r\n");
        if (line_t.len == 0) break;
        if (std.ascii.startsWithIgnoreCase(line_t, "content-length:")) {
            const v = std.mem.trim(u8, line_t["content-length:".len..], " \t");
            content_length = std.fmt.parseInt(usize, v, 10) catch return writeStatus(w, 400);
        }
    }

    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, target, "/ready")) {
        try writeStatus(w, 200);
        try w.flush();
        return;
    }

    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, target, "/fraud-score")) {
        if (content_length > max_request_bytes) {
            try writeStatus(w, 413);
            try w.flush();
            return;
        }
        var body_buf: [max_request_bytes]u8 = undefined;
        const body = body_buf[0..content_length];
        try r.readSliceAll(body);

        var scratch: [scratch_bytes]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&scratch);
        var out_buf: [max_response_bytes]u8 = undefined;
        const out = http_io.handle(fba.allocator(), reader, body, &out_buf) catch {
            try writeStatus(w, 500);
            try w.flush();
            return;
        };
        try w.print(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
            .{out.len},
        );
        try w.writeAll(out);
        try w.flush();
        return;
    }

    try writeStatus(w, 404);
    try w.flush();
}

fn writeStatus(w: *std.Io.Writer, code: u16) !void {
    const phrase: []const u8 = switch (code) {
        200 => "OK",
        400 => "Bad Request",
        404 => "Not Found",
        413 => "Payload Too Large",
        500 => "Internal Server Error",
        else => "Error",
    };
    try w.print(
        "HTTP/1.1 {d} {s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        .{ code, phrase },
    );
}

const ParseStatus = enum { incomplete, ok, bad };

const ParsedRequest = struct {
    method: []const u8,
    target: []const u8,
    body: []const u8,
    total_len: usize,
};

fn parseRequest(buf: []const u8) struct { status: ParseStatus, req: ParsedRequest } {
    const head_end = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse {
        return .{ .status = .incomplete, .req = undefined };
    };
    const head = buf[0..head_end];
    const body_start = head_end + 4;

    const line_end = std.mem.indexOf(u8, head, "\r\n") orelse head.len;
    const start_line = head[0..line_end];
    const sp1 = std.mem.indexOfScalar(u8, start_line, ' ') orelse {
        return .{ .status = .bad, .req = undefined };
    };
    const method = start_line[0..sp1];
    const rest = start_line[sp1 + 1 ..];
    const sp2 = std.mem.indexOfScalar(u8, rest, ' ') orelse {
        return .{ .status = .bad, .req = undefined };
    };
    const target = rest[0..sp2];

    var content_length: usize = 0;
    var idx: usize = line_end + 2;
    while (idx < head.len) {
        const next = std.mem.indexOfPos(u8, head, idx, "\r\n") orelse head.len;
        const line = head[idx..next];
        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            const v = std.mem.trim(u8, line["content-length:".len..], " \t");
            content_length = std.fmt.parseInt(usize, v, 10) catch {
                return .{ .status = .bad, .req = undefined };
            };
        }
        idx = next + 2;
    }

    if (buf.len - body_start < content_length) {
        return .{ .status = .incomplete, .req = undefined };
    }
    return .{
        .status = .ok,
        .req = .{
            .method = method,
            .target = target,
            .body = buf[body_start .. body_start + content_length],
            .total_len = body_start + content_length,
        },
    };
}

fn formatStatusOnly(out: []u8, code: u16, close: bool) []u8 {
    const phrase: []const u8 = switch (code) {
        200 => "OK",
        400 => "Bad Request",
        404 => "Not Found",
        413 => "Payload Too Large",
        500 => "Internal Server Error",
        else => "Error",
    };
    if (close) {
        return std.fmt.bufPrint(
            out,
            "HTTP/1.1 {d} {s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            .{ code, phrase },
        ) catch out[0..0];
    }
    return std.fmt.bufPrint(
        out,
        "HTTP/1.1 {d} {s}\r\nContent-Length: 0\r\n\r\n",
        .{ code, phrase },
    ) catch out[0..0];
}

fn buildResponse(
    ally: std.mem.Allocator,
    reader: *const index_format.Reader,
    req: ParsedRequest,
    out: []u8,
    close_hint: *bool,
) []u8 {
    if (std.mem.eql(u8, req.method, "GET") and std.mem.eql(u8, req.target, "/ready")) {
        close_hint.* = false;
        return formatStatusOnly(out, 200, false);
    }
    if (std.mem.eql(u8, req.method, "POST") and std.mem.eql(u8, req.target, "/fraud-score")) {
        if (req.body.len > max_request_bytes) {
            close_hint.* = true;
            return formatStatusOnly(out, 413, true);
        }
        var body_out: [max_response_bytes]u8 = undefined;
        const body_resp = http_io.handle(ally, reader, req.body, &body_out) catch {
            close_hint.* = true;
            return formatStatusOnly(out, 500, true);
        };
        const r = std.fmt.bufPrint(
            out,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}",
            .{ body_resp.len, body_resp },
        ) catch {
            close_hint.* = true;
            return formatStatusOnly(out, 500, true);
        };
        close_hint.* = false;
        return r;
    }
    close_hint.* = true;
    return formatStatusOnly(out, 404, true);
}

const Op = enum(u8) { accept = 1, read, write, close };

fn makeUserData(idx: u32, op: Op) u64 {
    const op_byte: u64 = @intFromEnum(op);
    return (op_byte << 32) | @as(u64, idx);
}

fn parseUserData(ud: u64) struct { idx: u32, op: Op } {
    return .{
        .idx = @truncate(ud),
        .op = @enumFromInt(@as(u8, @truncate(ud >> 32))) ,
    };
}

const conn_pool_size: usize = 128;
const ring_entries: u16 = 256;
const scratch_bytes: usize = 8 * 1024;

const Conn = struct {
    fd: i32 = -1,
    buf: [max_request_bytes + 4096]u8 = undefined,
    buf_len: usize = 0,
    consumed_len: usize = 0,
    out_buf: [max_response_bytes + 512]u8 = undefined,
    out_len: usize = 0,
    out_sent: usize = 0,
    scratch: [scratch_bytes]u8 = undefined,
    state: State = .idle,
    close_after_write: bool = false,

    const State = enum { idle, reading, writing, closing };
};

fn parseAndDispatch(
    ring: *std.os.linux.IoUring,
    reader: *const index_format.Reader,
    c: *Conn,
    idx: u32,
) !void {
    const parsed = parseRequest(c.buf[0..c.buf_len]);
    switch (parsed.status) {
        .incomplete => {
            if (c.buf_len >= c.buf.len) {
                const out = formatStatusOnly(c.out_buf[0..], 413, true);
                c.out_len = out.len;
                c.out_sent = 0;
                c.consumed_len = c.buf_len;
                c.close_after_write = true;
                c.state = .writing;
                _ = try ring.write(makeUserData(idx, .write), c.fd, c.out_buf[0..c.out_len], 0);
            } else {
                c.state = .reading;
                _ = try ring.read(makeUserData(idx, .read), c.fd, .{ .buffer = c.buf[c.buf_len..] }, 0);
            }
        },
        .bad => {
            const out = formatStatusOnly(c.out_buf[0..], 400, true);
            c.out_len = out.len;
            c.out_sent = 0;
            c.consumed_len = c.buf_len;
            c.close_after_write = true;
            c.state = .writing;
            _ = try ring.write(makeUserData(idx, .write), c.fd, c.out_buf[0..c.out_len], 0);
        },
        .ok => {
            var fba = std.heap.FixedBufferAllocator.init(c.scratch[0..]);
            const out = buildResponse(fba.allocator(), reader, parsed.req, c.out_buf[0..], &c.close_after_write);
            c.out_len = out.len;
            c.out_sent = 0;
            c.consumed_len = parsed.req.total_len;
            c.state = .writing;
            _ = try ring.write(makeUserData(idx, .write), c.fd, c.out_buf[0..c.out_len], 0);
        },
    }
}

fn runIoUringLoop(
    reader: *const index_format.Reader,
    listen_fd: std.posix.fd_t,
) !void {
    if (builtin.os.tag != .linux) return error.Unsupported;
    const linux = std.os.linux;

    var ring = try linux.IoUring.init(ring_entries, 0);
    defer ring.deinit();

    var conns: [conn_pool_size]Conn = .{Conn{}} ** conn_pool_size;

    var free_stack: [conn_pool_size]u32 = undefined;
    var free_top: usize = 0;
    {
        var i: u32 = conn_pool_size;
        while (i > 0) {
            i -= 1;
            free_stack[free_top] = i;
            free_top += 1;
        }
    }

    const accept_idx: u32 = std.math.maxInt(u32);
    _ = try ring.accept(makeUserData(accept_idx, .accept), listen_fd, null, null, 0);

    var cqes: [64]linux.io_uring_cqe = undefined;

    while (true) {
        _ = ring.submit_and_wait(1) catch |err| switch (err) {
            error.SignalInterrupt => continue,
            else => return err,
        };

        const n = try ring.copy_cqes(&cqes, 0);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const cqe = cqes[i];
            const ud = parseUserData(cqe.user_data);

            switch (ud.op) {
                .accept => {
                    if (cqe.res < 0) {
                        std.log.warn("accept cqe err: {}", .{cqe.err()});
                        _ = try ring.accept(makeUserData(accept_idx, .accept), listen_fd, null, null, 0);
                        continue;
                    }
                    const new_fd: i32 = cqe.res;

                    if (free_top == 0) {
                        _ = try ring.close(makeUserData(accept_idx, .close), new_fd);
                        _ = try ring.accept(makeUserData(accept_idx, .accept), listen_fd, null, null, 0);
                        continue;
                    }
                    free_top -= 1;
                    const slot = free_stack[free_top];
                    conns[slot] = .{
                        .fd = new_fd,
                        .buf_len = 0,
                        .out_len = 0,
                        .out_sent = 0,
                        .state = .reading,
                    };
                    _ = try ring.read(
                        makeUserData(slot, .read),
                        new_fd,
                        .{ .buffer = conns[slot].buf[0..] },
                        0,
                    );
                    _ = try ring.accept(makeUserData(accept_idx, .accept), listen_fd, null, null, 0);
                },
                .read => {
                    const c = &conns[ud.idx];
                    if (cqe.res <= 0) {
                        c.state = .closing;
                        _ = try ring.close(makeUserData(ud.idx, .close), c.fd);
                        continue;
                    }
                    const got: usize = @intCast(cqe.res);
                    c.buf_len += got;
                    try parseAndDispatch(&ring, reader, c, ud.idx);
                },
                .write => {
                    const c = &conns[ud.idx];
                    if (cqe.res <= 0) {
                        c.state = .closing;
                        _ = try ring.close(makeUserData(ud.idx, .close), c.fd);
                        continue;
                    }
                    const wrote: usize = @intCast(cqe.res);
                    c.out_sent += wrote;
                    if (c.out_sent < c.out_len) {
                        _ = try ring.write(
                            makeUserData(ud.idx, .write),
                            c.fd,
                            c.out_buf[c.out_sent..c.out_len],
                            0,
                        );
                        continue;
                    }
                    if (c.close_after_write) {
                        c.state = .closing;
                        _ = try ring.close(makeUserData(ud.idx, .close), c.fd);
                        continue;
                    }
                    const leftover = c.buf_len - c.consumed_len;
                    if (leftover > 0) {
                        std.mem.copyForwards(u8, c.buf[0..leftover], c.buf[c.consumed_len..c.buf_len]);
                    }
                    c.buf_len = leftover;
                    c.consumed_len = 0;
                    c.out_len = 0;
                    c.out_sent = 0;
                    if (leftover > 0) {
                        try parseAndDispatch(&ring, reader, c, ud.idx);
                    } else {
                        c.state = .reading;
                        _ = try ring.read(
                            makeUserData(ud.idx, .read),
                            c.fd,
                            .{ .buffer = c.buf[0..] },
                            0,
                        );
                    }
                },
                .close => {
                    if (ud.idx == accept_idx) continue;
                    const c = &conns[ud.idx];
                    c.fd = -1;
                    c.state = .idle;
                    free_stack[free_top] = ud.idx;
                    free_top += 1;
                },
            }
        }
    }
}

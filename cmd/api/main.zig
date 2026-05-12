const std = @import("std");
const builtin = @import("builtin");
const lib = @import("lib");
const block_index = lib.block_index;
const http_io = lib.http_io;
const fdpass = lib.fdpass;
const fast_parser = lib.fast_parser;
const linux = std.os.linux;

pub const std_options: std.Options = .{
    .log_level = .err,
};

const max_request_bytes: usize = 4 * 1024;
const diag_instrument = true;

const DiagMetric = enum(usize) {
    queue_notify,
    fd_queue_wait,
    notify_drain,
    http_parse,
    features,
    search,
    app,
    write,
};

const diag_metric_count: usize = 8;
const diag_metric_names = [_][]const u8{
    "queue_notify",
    "fd_queue_wait",
    "notify_drain",
    "http_parse",
    "features",
    "search",
    "app",
    "write",
};
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
    var ts: std.posix.timespec = undefined;
    switch (std.posix.errno(std.posix.system.clock_gettime(.MONOTONIC, &ts))) {
        .SUCCESS => {
            const sec: u64 = @intCast(ts.sec);
            const nsec: u64 = @intCast(ts.nsec);
            return sec * 1_000_000_000 + nsec;
        },
        else => return 0,
    }
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
        diagSleepTwoSeconds();
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
                "INSTR api metric={s} count={} mean_us={} p50_le_us={} p90_le_us={} p99_le_us={}\n",
                .{ diag_metric_names[i], count, mean_us, p50_us, p90_us, p99_us },
            );
        }
    }
}

fn diagSleepTwoSeconds() void {
    var req: std.posix.timespec = .{ .sec = 2, .nsec = 0 };
    while (std.posix.errno(std.posix.system.nanosleep(&req, &req)) == .INTR) {}
}

const resp_bad_req_close: []const u8 = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
const resp_too_large_close: []const u8 = "HTTP/1.1 413 Payload Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
const resp_internal_close: []const u8 = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
const resp_not_found_close: []const u8 = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
const resp_ready: []const u8 = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n";

pub fn main(init: std.process.Init) !void {
    const ally = init.arena.allocator();
    const io = init.io;

    var it = try init.minimal.args.iterateAllocator(ally);
    defer it.deinit();
    _ = it.next();
    const sock_path = it.next() orelse "/sockets/api.sock";
    const index_path = it.next() orelse "/index/index.bin";
    const num_workers = try parseWorkerCountArg(it.next());
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

    const aligned: []align(8) const u8 = @alignCast(mm.memory);
    const reader = try block_index.Reader.init(aligned);
    std.log.info("api: block index loaded — n={} k={} blocks={}", .{ reader.n, reader.k, reader.total_blocks });
    warmBlockIndex(&reader);

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

    if (builtin.os.tag != .linux) {
        std.log.info("api: blocking loop unsupported on this build", .{});
        return error.Unsupported;
    }

    std.log.info("api: io_uring loop, {} workers", .{num_workers});
    if (diag_instrument) {
        if (std.Thread.spawn(.{}, diagStatsThread, .{}) catch null) |t| t.detach();
    }

    const ctrl_path_z = try std.mem.concatWithSentinel(ally, u8, &.{ sock_path, ".ctrl" }, 0);
    const ctrl_fd = try fdpass.openUnixListener(ctrl_path_z);
    defer fdpass.closeFd(ctrl_fd);
    if (std.c.chmod(ctrl_path_z.ptr, 0o666) != 0) std.log.warn("chmod failed on {s}", .{ctrl_path_z});

    const event_r = linux.eventfd(0, linux.EFD.CLOEXEC);
    if (linux.errno(event_r) != .SUCCESS) return error.EventFdFailed;
    const event_fd: i32 = @intCast(@as(isize, @bitCast(event_r)));
    defer fdpass.closeFd(event_fd);

    var fd_queue = FdQueue{};
    var ctrl_ctx = ControlThreadCtx{
        .listen_fd = ctrl_fd,
        .event_fd = event_fd,
        .queue = &fd_queue,
    };
    const ctrl_thread = try std.Thread.spawn(.{}, controlThread, .{&ctrl_ctx});
    ctrl_thread.detach();

    const c_alloc = std.heap.c_allocator;
    const workers = try c_alloc.alloc(Worker, num_workers);
    defer c_alloc.free(workers);
    for (workers) |*w| w.* = Worker{};

    if (num_workers == 1) {
        try runIoUringLoop(&workers[0], &reader, server.socket.handle, event_fd, &fd_queue);
        return;
    }

    const threads = try c_alloc.alloc(std.Thread, num_workers - 1);
    defer c_alloc.free(threads);
    for (threads, 1..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, runIoUringLoop, .{ &workers[i], &reader, server.socket.handle, event_fd, &fd_queue });
    }
    runIoUringLoop(&workers[0], &reader, server.socket.handle, event_fd, &fd_queue) catch |err| {
        std.log.err("worker 0 failed: {}", .{err});
    };
    for (threads) |t| t.join();
}

const ParseStatus = enum { incomplete, ok, bad };

const Endpoint = enum { ready, fraud_score, not_found };

const ParsedRequest = struct {
    endpoint: Endpoint,
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

    var endpoint: Endpoint = .not_found;
    if (std.mem.startsWith(u8, start_line, "POST /fraud-score ")) {
        endpoint = .fraud_score;
    } else if (std.mem.startsWith(u8, start_line, "GET /ready ")) {
        endpoint = .ready;
    }

    var content_length: usize = 0;
    var idx: usize = line_end + 2;
    while (idx < head.len) {
        const next = std.mem.indexOfPos(u8, head, idx, "\r\n") orelse head.len;
        const line = head[idx..next];
        if (line.len >= 16 and std.ascii.eqlIgnoreCase(line[0..15], "content-length:")) {
            const v = std.mem.trim(u8, line[15..], " \t");
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
            .endpoint = endpoint,
            .body = buf[body_start .. body_start + content_length],
            .total_len = body_start + content_length,
        },
    };
}

const conn_pool_size: usize = 256;
const ring_entries: u16 = 1024;
const scratch_bytes: usize = 8 * 1024;
const fd_queue_size: usize = conn_pool_size * 2;

const QueuedFd = struct {
    fd: i32,
    queued_ns: u64,
};

const FdQueue = struct {
    mutex: std.atomic.Mutex = .unlocked,
    fds: [fd_queue_size]QueuedFd = undefined,
    len: usize = 0,

    fn push(self: *FdQueue, fd: i32) bool {
        self.lock();
        defer self.mutex.unlock();
        if (self.len == self.fds.len) return false;
        self.fds[self.len] = .{
            .fd = fd,
            .queued_ns = diagNowNs(),
        };
        self.len += 1;
        return true;
    }

    fn pop(self: *FdQueue) ?QueuedFd {
        self.lock();
        defer self.mutex.unlock();
        if (self.len == 0) return null;
        self.len -= 1;
        return self.fds[self.len];
    }

    fn lock(self: *FdQueue) void {
        while (!self.mutex.tryLock()) {
            std.atomic.spinLoopHint();
        }
    }
};

const ControlThreadCtx = struct {
    listen_fd: i32,
    event_fd: i32,
    queue: *FdQueue,
};

const Op = enum(u8) { accept = 1, notify, read, write, close };
const accept_idx: u32 = std.math.maxInt(u32);
const notify_idx: u32 = std.math.maxInt(u32) - 1;

fn makeUserData(idx: u32, op: Op) u64 {
    const op_byte: u64 = @intFromEnum(op);
    return (op_byte << 32) | @as(u64, idx);
}

fn parseUserData(ud: u64) struct { idx: u32, op: Op } {
    return .{
        .idx = @truncate(ud),
        .op = @enumFromInt(@as(u8, @truncate(ud >> 32))),
    };
}

const Conn = struct {
    fd: i32 = -1,
    buf: [max_request_bytes + 4096]u8 = undefined,
    buf_len: usize = 0,
    consumed_len: usize = 0,
    out_ptr: [*]const u8 = undefined,
    out_len: usize = 0,
    out_sent: usize = 0,
    write_started_ns: u64 = 0,
    scratch: [scratch_bytes]u8 = undefined,
    state: State = .idle,
    close_after_write: bool = false,

    const State = enum { idle, reading, writing, closing };
};

const Worker = struct {
    conns: [conn_pool_size]Conn = .{Conn{}} ** conn_pool_size,
    free_stack: [conn_pool_size]u32 = undefined,
    free_top: usize = 0,
    event_buf: [8]u8 = undefined,

    pub fn init(self: *Worker) void {
        var i: u32 = conn_pool_size;
        self.free_top = 0;
        while (i > 0) {
            i -= 1;
            self.free_stack[self.free_top] = i;
            self.free_top += 1;
        }
    }
};

fn controlThread(ctx: *ControlThreadCtx) void {
    while (true) {
        const accept_r = linux.accept4(ctx.listen_fd, null, null, linux.SOCK.CLOEXEC);
        if (linux.errno(accept_r) != .SUCCESS) continue;
        const conn_fd: i32 = @intCast(@as(isize, @bitCast(accept_r)));
        defer fdpass.closeFd(conn_fd);

        while (fdpass.recvFd(conn_fd)) |fd| {
            const notify_start = diagNowNs();
            if (ctx.queue.push(fd)) {
                fdpass.notifyEvent(ctx.event_fd);
                diagRecord(.queue_notify, diagElapsedNs(notify_start));
            } else {
                fdpass.closeFd(fd);
            }
        }
    }
}

fn handleParsed(
    ring: *std.os.linux.IoUring,
    reader: *const block_index.Reader,
    c: *Conn,
    idx: u32,
) !void {
    const app_start = diagNowNs();
    const parse_start = diagNowNs();
    const parsed = parseRequest(c.buf[0..c.buf_len]);
    diagRecord(.http_parse, diagElapsedNs(parse_start));
    switch (parsed.status) {
        .incomplete => {
            if (c.buf_len >= c.buf.len) {
                c.out_ptr = resp_too_large_close.ptr;
                c.out_len = resp_too_large_close.len;
                c.out_sent = 0;
                c.consumed_len = c.buf_len;
                c.close_after_write = true;
                c.state = .writing;
                c.write_started_ns = diagNowNs();
                _ = try ring.write(makeUserData(idx, .write), c.fd, c.out_ptr[0..c.out_len], 0);
                diagRecord(.app, diagElapsedNs(app_start));
            } else {
                c.state = .reading;
                _ = try ring.read(makeUserData(idx, .read), c.fd, .{ .buffer = c.buf[c.buf_len..] }, 0);
            }
        },
        .bad => {
            c.out_ptr = resp_bad_req_close.ptr;
            c.out_len = resp_bad_req_close.len;
            c.out_sent = 0;
            c.consumed_len = c.buf_len;
            c.close_after_write = true;
            c.state = .writing;
            c.write_started_ns = diagNowNs();
            _ = try ring.write(makeUserData(idx, .write), c.fd, c.out_ptr[0..c.out_len], 0);
            diagRecord(.app, diagElapsedNs(app_start));
        },
        .ok => {
            const resp = pickResponse(reader, c, parsed.req);
            c.out_ptr = resp.ptr;
            c.out_len = resp.len;
            c.out_sent = 0;
            c.consumed_len = parsed.req.total_len;
            c.close_after_write = (parsed.req.endpoint == .not_found);
            c.state = .writing;
            c.write_started_ns = diagNowNs();
            _ = try ring.write(makeUserData(idx, .write), c.fd, c.out_ptr[0..c.out_len], 0);
            diagRecord(.app, diagElapsedNs(app_start));
        },
    }
}

fn pickResponse(reader: *const block_index.Reader, c: *Conn, req: ParsedRequest) []const u8 {
    return switch (req.endpoint) {
        .ready => resp_ready,
        .fraud_score => blk: {
            if (req.body.len > max_request_bytes) break :blk resp_too_large_close;
            if (diag_instrument) {
                var f: [block_index.dims]f32 = undefined;
                const features_start = diagNowNs();
                fast_parser.parseFeatures(req.body, &f) catch break :blk resp_internal_close;
                diagRecord(.features, diagElapsedNs(features_start));

                const search_start = diagNowNs();
                const count = block_index.searchFraudCountTwoTier(
                    reader,
                    &f,
                    block_index.default_nprobe_fast,
                    block_index.default_nprobe_full,
                );
                diagRecord(.search, diagElapsedNs(search_start));
                break :blk http_io.responseForCount(count);
            }
            var fba = std.heap.FixedBufferAllocator.init(c.scratch[0..]);
            const resp = http_io.handleBlock(fba.allocator(), reader, req.body) catch break :blk resp_internal_close;
            break :blk resp;
        },
        .not_found => resp_not_found_close,
    };
}

fn warmBlockIndex(reader: *const block_index.Reader) void {
    var state: u32 = 0x1234_5678;
    var sink: u8 = 0;

    var i: usize = 0;
    while (i < 512) : (i += 1) {
        var q: [block_index.dims]f32 = undefined;

        var d: usize = 0;
        while (d < block_index.dims) : (d += 1) {
            state = state *% 1_664_525 +% 1_013_904_223;
            const raw = state >> 8;
            q[d] = @as(f32, @floatFromInt(raw)) * (1.0 / 16_777_216.0);
        }

        if ((i & 7) == 0) {
            q[5] = -1;
            q[6] = -1;
        }

        sink +%= block_index.searchFraudCountTwoTier(
            reader,
            &q,
            block_index.default_nprobe_fast,
            block_index.default_nprobe_full,
        );
    }

    std.mem.doNotOptimizeAway(sink);
}

fn parseWorkerCountArg(arg: ?[]const u8) !usize {
    const n = if (arg) |s| try std.fmt.parseInt(usize, s, 10) else 3;
    if (n == 0 or n > 4) return error.BadWorkerCount;
    return n;
}

test "parseWorkerCountArg preserves default and bounds tuning" {
    try std.testing.expectEqual(@as(usize, 3), try parseWorkerCountArg(null));
    try std.testing.expectEqual(@as(usize, 1), try parseWorkerCountArg("1"));
    try std.testing.expectEqual(@as(usize, 4), try parseWorkerCountArg("4"));
    try std.testing.expectError(error.BadWorkerCount, parseWorkerCountArg("0"));
    try std.testing.expectError(error.BadWorkerCount, parseWorkerCountArg("5"));
}

fn activateConn(ring: *linux.IoUring, worker: *Worker, new_fd: i32) !void {
    if (worker.free_top == 0) {
        _ = try ring.close(makeUserData(accept_idx, .close), new_fd);
        return;
    }

    worker.free_top -= 1;
    const slot = worker.free_stack[worker.free_top];
    const c = &worker.conns[slot];
    c.fd = new_fd;
    c.buf_len = 0;
    c.consumed_len = 0;
    c.out_len = 0;
    c.out_sent = 0;
    c.write_started_ns = 0;
    c.close_after_write = false;
    c.state = .reading;
    _ = try ring.read(
        makeUserData(slot, .read),
        new_fd,
        .{ .buffer = c.buf[0..] },
        0,
    );
}

fn drainPassedFds(ring: *linux.IoUring, worker: *Worker, fd_queue: *FdQueue) !void {
    const drain_start = diagNowNs();
    while (fd_queue.pop()) |item| {
        diagRecord(.fd_queue_wait, diagElapsedNs(item.queued_ns));
        try activateConn(ring, worker, item.fd);
    }
    diagRecord(.notify_drain, diagElapsedNs(drain_start));
}

fn runIoUringLoop(
    worker: *Worker,
    reader: *const block_index.Reader,
    listen_fd: std.posix.fd_t,
    event_fd: i32,
    fd_queue: *FdQueue,
) !void {
    if (builtin.os.tag != .linux) return error.Unsupported;

    var ring = try linux.IoUring.init(ring_entries, 0);
    defer ring.deinit();

    worker.init();

    _ = try ring.accept(makeUserData(accept_idx, .accept), listen_fd, null, null, 0);
    _ = try ring.read(makeUserData(notify_idx, .notify), event_fd, .{ .buffer = worker.event_buf[0..] }, 0);

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
            const ud = parseUserData(cqe.user_data);

            switch (ud.op) {
                .accept => {
                    if (cqe.res < 0) {
                        _ = try ring.accept(makeUserData(accept_idx, .accept), listen_fd, null, null, 0);
                        continue;
                    }
                    try activateConn(&ring, worker, cqe.res);
                    _ = try ring.accept(makeUserData(accept_idx, .accept), listen_fd, null, null, 0);
                },
                .notify => {
                    try drainPassedFds(&ring, worker, fd_queue);
                    _ = try ring.read(makeUserData(notify_idx, .notify), event_fd, .{ .buffer = worker.event_buf[0..] }, 0);
                },
                .read => {
                    const c = &worker.conns[ud.idx];
                    if (cqe.res <= 0) {
                        c.state = .closing;
                        _ = try ring.close(makeUserData(ud.idx, .close), c.fd);
                        continue;
                    }
                    const got: usize = @intCast(cqe.res);
                    c.buf_len += got;
                    try handleParsed(&ring, reader, c, ud.idx);
                },
                .write => {
                    const c = &worker.conns[ud.idx];
                    if (c.write_started_ns != 0) {
                        diagRecord(.write, diagElapsedNs(c.write_started_ns));
                        c.write_started_ns = 0;
                    }
                    if (cqe.res <= 0) {
                        c.state = .closing;
                        _ = try ring.close(makeUserData(ud.idx, .close), c.fd);
                        continue;
                    }
                    const wrote: usize = @intCast(cqe.res);
                    c.out_sent += wrote;
                    if (c.out_sent < c.out_len) {
                        c.write_started_ns = diagNowNs();
                        _ = try ring.write(
                            makeUserData(ud.idx, .write),
                            c.fd,
                            c.out_ptr[c.out_sent..c.out_len],
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
                        try handleParsed(&ring, reader, c, ud.idx);
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
                    const c = &worker.conns[ud.idx];
                    c.fd = -1;
                    c.state = .idle;
                    worker.free_stack[worker.free_top] = ud.idx;
                    worker.free_top += 1;
                },
            }
        }
    }
}

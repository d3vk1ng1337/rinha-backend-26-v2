const std = @import("std");
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

    while (true) {
        const stream = server.accept(io) catch |err| {
            std.log.warn("accept error: {}", .{err});
            continue;
        };
        handleConn(ally, io, &reader, stream) catch |err| {
            std.log.warn("conn error: {}", .{err});
        };
        stream.close(io);
    }
}

fn handleConn(
    ally: std.mem.Allocator,
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
        const body = try ally.alloc(u8, content_length);
        defer ally.free(body);
        try r.readSliceAll(body);

        var out_buf: [max_response_bytes]u8 = undefined;
        const out = http_io.handle(ally, reader, body, &out_buf) catch {
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

const std = @import("std");
const Io = std.Io;

/// Fetch a URL to a heap buffer using curl, inheriting stderr for progress.
pub fn runCurl(allocator: std.mem.Allocator, io: Io, url: []const u8) ![]u8 {
    var child = try std.process.spawn(io, .{
        .argv = &.{ "curl", "-sL", url },
        .stdout = .pipe,
        .stderr = .inherit,
    });
    const stdout = child.stdout orelse return error.CurlStdoutNull;

    var read_buf: [4096]u8 = undefined;
    var reader = stdout.reader(io, &read_buf);

    var buf: std.ArrayList(u8) = .empty;
    try Io.Reader.appendRemainingUnlimited(&reader.interface, allocator, &buf);
    _ = try child.wait(io);
    return buf.toOwnedSlice(allocator);
}

/// Accept a single POST on 127.0.0.1:8080, read the full request body, answer
/// 200, and return the addon JSON payload from the body.
pub fn receiveAddonData(allocator: std.mem.Allocator, io: Io) !std.json.Parsed(std.json.Value) {
    std.debug.print("Starting HTTP server on localhost:8080...\n", .{});
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 8080);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    var stream = try server.accept(io);
    defer stream.close(io);

    // Read the full HTTP request (headers + body). The reader's internal
    // buffer must be separate from the destination buffer to avoid aliasing.
    var read_buf: [65536]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var chunk: [65536]u8 = undefined;

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);

    var content_length: ?usize = null;
    var header_end: usize = 0;

    while (true) {
        const buffered = reader.interface.buffered();
        if (buffered.len > 0) {
            try body.appendSlice(allocator, buffered);
            reader.interface.seek = reader.interface.end;
        }

        if (content_length == null) {
            if (std.mem.indexOf(u8, body.items, "\r\n\r\n")) |idx| {
                header_end = idx + 4;
                var lines = std.mem.splitScalar(u8, body.items[0..idx], '\n');
                while (lines.next()) |line| {
                    const trimmed = std.mem.trimEnd(u8, line, "\r");
                    if (std.ascii.startsWithIgnoreCase(trimmed, "content-length:")) {
                        const val = std.mem.trimStart(u8, trimmed["content-length:".len..], " \t");
                        content_length = std.fmt.parseInt(usize, val, 10) catch null;
                    }
                }
            }
        }

        if (content_length) |cl| {
            if (body.items.len >= header_end + cl) break;
        }

        var dest: [1][]u8 = .{chunk[0..]};
        const n = Io.Reader.readVec(&reader.interface, &dest) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n > 0) try body.appendSlice(allocator, chunk[0..n]);
        if (n == 0 and reader.interface.bufferedLen() == 0) break;
    }

    // Send HTTP response before parsing
    var resp_buf: [128]u8 = undefined;
    var writer = stream.writer(io, &resp_buf);
    _ = try Io.Writer.writeAll(&writer.interface, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK");

    std.debug.print("Received addon data. Killing BDS...\n", .{});

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body.items[header_end..], .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    return parsed;
}

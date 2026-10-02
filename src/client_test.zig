// SPDX-License-Identifier: BSD-2-Clause

//! The client against a server on this machine: no internet needed.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const http = std.http;

const Client = @import("Client.zig");

/// A server on a port of this machine's, answering by the path asked, and
/// keeping the last request's target and body as they arrived.
const Server = struct {
    io: Io,
    listener: Io.net.Server,
    port: u16,
    future: Io.Future(void) = .{ .any_future = null, .result = {} },
    target: [256]u8 = undefined,
    target_len: usize = 0,
    body: [256]u8 = undefined,
    body_len: usize = 0,

    fn start(s: *Server, io: Io) !void {
        const address = try Io.net.IpAddress.parse("127.0.0.1", 0);
        s.* = .{ .io = io, .listener = try address.listen(io, .{ .reuse_address = true }), .port = 0 };
        s.port = s.listener.socket.address.getPort();
        s.future = try io.concurrent(serve, .{s});
    }

    fn stop(s: *Server) void {
        _ = s.future.cancel(s.io);
        s.listener.deinit(s.io);
    }

    fn url(s: *const Server, buffer: []u8, path: []const u8) []const u8 {
        return std.fmt.bufPrint(buffer, "http://127.0.0.1:{d}{s}", .{ s.port, path }) catch unreachable;
    }

    fn lastTarget(s: *const Server) []const u8 {
        return s.target[0..s.target_len];
    }

    fn serve(s: *Server) void {
        while (true) {
            const stream = s.listener.accept(s.io) catch return;
            defer stream.close(s.io);
            var in_buffer: [4096]u8 = undefined;
            var out_buffer: [4096]u8 = undefined;
            var reader = stream.reader(s.io, &in_buffer);
            var writer = stream.writer(s.io, &out_buffer);
            var server = http.Server.init(&reader.interface, &writer.interface);
            while (true) {
                // Being stopped while reading or writing is a failure of
                // the stream, its reason kept in it: the cancelling is
                // said once, so it is looked for there.
                var request = server.receiveHead() catch {
                    if (reader.err) |err| if (err == error.Canceled) return;
                    break;
                };
                s.answer(&request) catch |err| switch (err) {
                    error.Canceled => return,
                    else => {
                        if (reader.err) |e| if (e == error.Canceled) return;
                        if (writer.err) |e| if (e == error.Canceled) return;
                        break;
                    },
                };
            }
        }
    }

    fn answer(s: *Server, request: *http.Server.Request) !void {
        const target = request.head.target;
        s.target_len = @min(target.len, s.target.len);
        @memcpy(s.target[0..s.target_len], target[0..s.target_len]);
        var content_type_buffer: [64]u8 = undefined;
        var content_type: []const u8 = "";
        if (request.head.content_type) |t| {
            const n = @min(t.len, content_type_buffer.len);
            @memcpy(content_type_buffer[0..n], t[0..n]);
            content_type = content_type_buffer[0..n];
        }
        s.body_len = 0;
        if (request.head.method.requestHasBody()) {
            var body_buffer: [512]u8 = undefined;
            const body_reader = try request.readerExpectContinue(&body_buffer);
            s.body_len = try body_reader.readSliceShort(&s.body);
        }

        const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
        if (std.mem.eql(u8, path, "/hello")) {
            try request.respond("hi there", .{ .extra_headers = &.{.{ .name = "x-test", .value = "yes" }} });
        } else if (std.mem.eql(u8, path, "/echo")) {
            try request.respond(s.body[0..s.body_len], .{ .extra_headers = &.{.{ .name = "x-type", .value = content_type }} });
        } else if (std.mem.eql(u8, path, "/big")) {
            try request.respond(&@as([4096]u8, @splat('x')), .{});
        } else if (std.mem.eql(u8, path, "/moved")) {
            try request.respond("", .{ .status = .found, .extra_headers = &.{.{ .name = "location", .value = "/hello" }} });
        } else if (std.mem.eql(u8, path, "/never")) {
            try s.io.sleep(.fromSeconds(30), .awake);
        } else {
            try request.respond("no", .{ .status = .not_found });
        }
    }
};

/// Updates until something is done, for as long as five seconds.
fn waitFor(c: *Client, into: []Client.Done) ![]Client.Done {
    var tries: usize = 0;
    while (tries < 1000) : (tries += 1) {
        const done = c.update(into);
        if (done.len > 0) return done;
        try testing.io.sleep(.fromMilliseconds(5), .awake);
    }
    return error.TestTimedOut;
}

fn only(c: *Client) !Client.Done {
    var into: [1]Client.Done = undefined;
    const done = try waitFor(c, &into);
    return done[0];
}

test "an answer: its status, headers and body; a 404 is one too; a redirect followed" {
    var server: Server = undefined;
    try server.start(testing.io);
    defer server.stop();
    var c: Client = .init(testing.allocator, testing.io, .{ .allow_plain_http = true });
    defer c.deinit();
    var buffer: [128]u8 = undefined;

    _ = try c.send(.{ .url = server.url(&buffer, "/hello") });
    var hello = try only(&c);
    defer hello.deinit();
    const answer = try hello.result;
    try testing.expectEqual(@as(u16, 200), answer.status);
    try testing.expectEqualStrings("hi there", answer.body);
    try testing.expectEqualStrings("yes", answer.header("X-Test").?);
    try testing.expectEqual(@as(u64, 8), answer.size);

    _ = try c.send(.{ .url = server.url(&buffer, "/nothing") });
    var missing = try only(&c);
    defer missing.deinit();
    try testing.expectEqual(@as(u16, 404), (try missing.result).status);

    _ = try c.send(.{ .url = server.url(&buffer, "/moved") });
    var moved = try only(&c);
    defer moved.deinit();
    try testing.expectEqualStrings("hi there", (try moved.result).body);
    try testing.expectEqual(@as(usize, 0), c.pending());
}

test "a URL goes out as it is written, and a body with its type" {
    var server: Server = undefined;
    try server.start(testing.io);
    defer server.stop();
    var c: Client = .init(testing.allocator, testing.io, .{ .allow_plain_http = true });
    defer c.deinit();
    var buffer: [128]u8 = undefined;

    _ = try c.send(.{ .url = server.url(&buffer, "/hello?b=%41b&a=c%2Bd&signature=0f") });
    var signed = try only(&c);
    signed.deinit();
    try testing.expectEqualStrings("/hello?b=%41b&a=c%2Bd&signature=0f", server.lastTarget());

    _ = try c.send(.{ .method = .POST, .url = server.url(&buffer, "/echo"), .body = "data=1&key=two", .content_type = "application/x-www-form-urlencoded" });
    var echoed = try only(&c);
    defer echoed.deinit();
    const answer = try echoed.result;
    try testing.expectEqualStrings("data=1&key=two", answer.body);
    try testing.expectEqualStrings("application/x-www-form-urlencoded", answer.header("x-type").?);
}

test "what cannot be asked, what takes too long, what is too large, and what is cancelled" {
    var server: Server = undefined;
    try server.start(testing.io);
    defer server.stop();
    var buffer: [128]u8 = undefined;

    var secure: Client = .init(testing.allocator, testing.io, .{});
    defer secure.deinit();
    _ = try secure.send(.{ .url = server.url(&buffer, "/hello") });
    var plain = try only(&secure);
    try testing.expectError(error.NotSecure, plain.result);
    plain.deinit();
    _ = try secure.send(.{ .url = "not a url" });
    var bad = try only(&secure);
    try testing.expectError(error.BadUrl, bad.result);
    bad.deinit();

    var c: Client = .init(testing.allocator, testing.io, .{ .allow_plain_http = true, .max_running = 1 });
    defer c.deinit();
    _ = try c.send(.{ .url = server.url(&buffer, "/big"), .max_body = 100 });
    var big = try only(&c);
    try testing.expectError(error.TooLarge, big.result);
    big.deinit();

    // One at a time: the second waits for the first, and is cancelled
    // before it starts.
    _ = try c.send(.{ .url = server.url(&buffer, "/never"), .timeout_ms = 200 });
    const second = try c.send(.{ .url = server.url(&buffer, "/hello") });
    try testing.expect(!c.progress(second).?.started);
    c.cancel(second);
    var into: [2]Client.Done = undefined;
    var done = try waitFor(&c, &into);
    try testing.expectEqual(second, done[0].id);
    try testing.expectError(error.Cancelled, done[0].result);
    done[0].deinit();
    if (done.len == 1) done = try waitFor(&c, &into) else done = done[1..];
    try testing.expectError(error.Timeout, done[0].result);
    done[0].deinit();
}

test "a body saved to a file, whole or not at all" {
    var server: Server = undefined;
    try server.start(testing.io);
    defer server.stop();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var folder: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = folder[0..try tmp.dir.realPath(testing.io, &folder)];
    const path = try std.fs.path.join(testing.allocator, &.{ root, "deep", "big.bin" });
    defer testing.allocator.free(path);

    var c: Client = .init(testing.allocator, testing.io, .{ .allow_plain_http = true });
    defer c.deinit();
    var buffer: [128]u8 = undefined;
    _ = try c.send(.{ .url = server.url(&buffer, "/big"), .save_to = path, .max_body = 10 });
    var saved = try only(&c);
    defer saved.deinit();
    const answer = try saved.result;
    try testing.expectEqual(@as(u64, 4096), answer.size);
    try testing.expectEqualStrings("", answer.body);

    const bytes = try tmp.dir.readFileAlloc(testing.io, "deep/big.bin", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);
    try testing.expectEqual(@as(usize, 4096), bytes.len);
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "deep/big.bin.part", .{}));

    // What is not a success is not saved: its body says why.
    const missing = try std.fs.path.join(testing.allocator, &.{ root, "missing.bin" });
    defer testing.allocator.free(missing);
    _ = try c.send(.{ .url = server.url(&buffer, "/nothing"), .save_to = missing });
    var refused = try only(&c);
    defer refused.deinit();
    try testing.expectEqual(@as(u16, 404), (try refused.result).status);
    try testing.expectEqualStrings("no", (try refused.result).body);
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "missing.bin", .{}));
}

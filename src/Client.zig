// SPDX-License-Identifier: BSD-2-Clause

//! Web requests for a game: each on a thread of its own, a few at a time,
//! and their answers collected on the thread that asked, once a frame, so
//! a game never waits for the network.
//!
//! ```zig
//! var net: fluxion_net.Client = .init(gpa, io, .{});
//! defer net.deinit();
//! const asked = try net.send(.{ .url = "https://example.com/scores?game=1" });
//!
//! // Each frame:
//! var done: [8]fluxion_net.Done = undefined;
//! for (net.update(&done)) |*d| {
//!     defer d.deinit();
//!     const answer = d.result catch |err| { log(err, d.reason); continue; };
//!     use(answer.status, answer.body);
//! }
//! ```
//!
//! A URL goes out as it is written: its path and query are not encoded
//! again, so a request signed over its URL arrives with the URL it was
//! signed over.
//!
//! In a browser a request is the page's own `fetch`, which
//! `fluxion-net.js` runs, and the same calls ask and collect: the page's
//! rules hold there - another site answers only if it allows this page to
//! ask it, and the browser sends its own user agent.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const http = std.http;

const Client = @This();

const is_web = builtin.cpu.arch.isWasm();

gpa: Allocator,
io: Io,
options: Options,
/// Nothing in a browser, where the page asks.
http_client: if (is_web) void else http.Client,
/// Every request not yet collected, in the order it was sent: those that
/// wait start in this order.
jobs: std.ArrayList(*Job) = .empty,
next_id: u32 = 1,

pub const Header = http.Header;

pub const Options = struct {
    /// How many requests are on their way at once; the rest wait their
    /// turn.
    max_running: u8 = 4,
    /// Whether `http://` URLs are asked for. Off, only `https://` are: a
    /// game's requests carry keys and scores, and plain HTTP hands them to
    /// anyone on the way.
    allow_plain_http: bool = false,
    user_agent: []const u8 = "fluxion-net",
};

pub const Request = struct {
    method: http.Method = .GET,
    url: []const u8,
    headers: []const Header = &.{},
    body: []const u8 = "",
    /// What the body is; `application/octet-stream` for a body without one.
    content_type: ?[]const u8 = null,
    /// How long it may take, from when it starts to its last byte; 0 for as
    /// long as it takes.
    timeout_ms: u32 = 30_000,
    /// The longest body read into memory; a longer one fails with
    /// `TooLarge`. One saved to a file has no limit.
    max_body: usize = 64 * 1024 * 1024,
    /// How many redirects a request without a body follows. A request with
    /// one gives the redirect back as its answer.
    redirects: u8 = 5,
    /// The file the body goes into instead of memory, when the answer is a
    /// success; any other's body is read into memory, to say why. It is
    /// written as `<path>.part` and renamed when it is whole, so a file at
    /// `path` is never half of one; its folders are made.
    save_to: ?[]const u8 = null,
};

/// An answer: whatever its status. A 404 is an answer, not a failure.
pub const Response = struct {
    status: u16,
    headers: []const Header = &.{},
    /// Empty when the body went to a file.
    body: []const u8 = "",
    /// How many bytes the body had, after any compression was undone.
    size: u64 = 0,
    arena: std.heap.ArenaAllocator,

    /// The value of the first header of the name, whatever its case.
    pub fn header(r: *const Response, name: []const u8) ?[]const u8 {
        for (r.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        return null;
    }

    pub fn deinit(r: *Response) void {
        r.arena.deinit();
        r.* = undefined;
    }
};

/// Why there is no answer. `Done.reason` says more.
pub const Error = error{
    /// Not a URL, or not an http or https one.
    BadUrl,
    /// An `http://` URL, which the client was not allowed to ask.
    NotSecure,
    /// The host's name was not found.
    Dns,
    /// The host was found, but could not be reached.
    Connect,
    /// The secure connection could not be made: a certificate not trusted,
    /// or out of date.
    Tls,
    /// It took longer than `Request.timeout_ms`.
    Timeout,
    /// `cancel` ended it.
    Cancelled,
    /// The body was longer than `Request.max_body`.
    TooLarge,
    /// The connection broke, or what came back was not HTTP.
    Broken,
    /// The file the body was saved to could not be written.
    CannotSave,
    OutOfMemory,
};

pub const Id = enum(u32) { _ };

/// A request that has ended, one way or another.
pub const Done = struct {
    id: Id,
    result: Error!Response,
    /// What went wrong, more closely than the error: the system's or the
    /// TLS library's own word for it. Empty for an answer.
    reason: []const u8 = "",

    pub fn deinit(d: *Done) void {
        if (d.result) |*r| r.deinit() else |_| {}
        d.* = undefined;
    }
};

pub const Progress = struct {
    /// Whether it is on its way, rather than waiting its turn.
    started: bool,
    /// The bytes of the body received so far.
    received: u64,
    /// How long the body is, when the answer said; when it came compressed,
    /// how long it is compressed.
    total: ?u64,
};

/// What a body's bytes are counted in: a word in a browser, which has no
/// wider atomics (and no other thread to read them).
const Count = if (is_web) usize else u64;

const unknown_total = std.math.maxInt(Count);

const Job = struct {
    id: Id,
    /// The request's own copy of what it was given.
    arena: std.heap.ArenaAllocator,
    request: Request = undefined,
    state: std.atomic.Value(State) = .init(.waiting),
    received: std.atomic.Value(Count) = .init(0),
    total: std.atomic.Value(Count) = .init(unknown_total),
    /// Set before it is cancelled, so that whatever failed as it was
    /// stopped is said to be the cancelling.
    stopping: std.atomic.Value(bool) = .init(false),
    timed_out: bool = false,
    future: Io.Future(void) = .{ .any_future = null, .result = {} },
    /// The page's number for it, in a browser.
    fetch: u32 = 0,
    started_at: Io.Timestamp = .zero,
    result: Error!Response = error.Cancelled,
    reason: []const u8 = "",

    const State = enum(u8) { waiting, running, done };

    fn failed(job: *Job, err: Error, reason: []const u8) Error {
        job.reason = reason;
        return err;
    }

    /// What a failure of the network or of the HTTP library is to a game.
    fn from(job: *Job, err: anyerror) Error {
        if (job.stopping.load(.acquire)) return job.failed(error.Cancelled, "cancelled");
        job.reason = @errorName(err);
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Canceled => error.Cancelled,
            error.UnsupportedUriScheme, error.UriMissingHost, error.UriHostTooLong, error.InvalidFormat, error.InvalidPort, error.UnexpectedCharacter => error.BadUrl,
            error.UnknownHostName, error.NameServerFailure, error.HostLacksNetworkAddresses, error.TemporaryNameServerFailure, error.NoAddressReturned => error.Dns,
            error.ConnectionRefused, error.NetworkUnreachable, error.HostUnreachable, error.ConnectionTimedOut, error.AddressUnavailable, error.NetworkDown => error.Connect,
            error.CertificateBundleLoadFailure, error.TlsInitializationFailed => error.Tls,
            else => if (std.mem.startsWith(u8, @errorName(err), "Tls") or std.mem.startsWith(u8, @errorName(err), "Certificate")) error.Tls else error.Broken,
        };
    }
};

pub fn init(gpa: Allocator, io: Io, options: Options) Client {
    return .{ .gpa = gpa, .io = io, .options = options, .http_client = if (is_web) {} else .{ .allocator = gpa, .io = io } };
}

/// Stops every request still on its way, and drops every answer not yet
/// collected.
pub fn deinit(c: *Client) void {
    for (c.jobs.items) |job| {
        if (job.state.load(.acquire) == .running) c.stop(job);
        c.drop(job);
    }
    c.jobs.deinit(c.gpa);
    if (!is_web) c.http_client.deinit();
    c.* = undefined;
}

/// Asks: the request is copied, so what it points at may go once this
/// returns. It starts at once if fewer than `Options.max_running` are on
/// their way, else when its turn comes in `update`.
pub fn send(c: *Client, request: Request) Allocator.Error!Id {
    const job = try c.gpa.create(Job);
    errdefer c.gpa.destroy(job);
    job.* = .{ .id = @enumFromInt(c.next_id), .arena = .init(c.gpa) };
    errdefer job.arena.deinit();
    const a = job.arena.allocator();
    var copy = request;
    copy.url = try a.dupe(u8, request.url);
    copy.body = try a.dupe(u8, request.body);
    if (request.content_type) |t| copy.content_type = try a.dupe(u8, t);
    if (request.save_to) |p| copy.save_to = try a.dupe(u8, p);
    const headers = try a.alloc(Header, request.headers.len);
    for (request.headers, headers) |h, *into| into.* = .{ .name = try a.dupe(u8, h.name), .value = try a.dupe(u8, h.value) };
    copy.headers = headers;
    job.request = copy;
    try c.jobs.append(c.gpa, job);
    c.next_id +%= 1;
    if (c.next_id == 0) c.next_id = 1;
    c.startWaiting();
    return job.id;
}

/// Ends a request: one waiting its turn never starts, one on its way stops
/// where it is (this waits for that, a moment; in a browser its `Done`
/// comes a frame or so later). Its `Done` says `Cancelled`; one already
/// done keeps its answer.
pub fn cancel(c: *Client, id: Id) void {
    const job = c.find(id) orelse return;
    switch (job.state.load(.acquire)) {
        .waiting => {
            job.result = job.failed(error.Cancelled, "cancelled");
            job.state.store(.done, .release);
        },
        .running => c.stop(job),
        .done => {},
    }
}

/// Stops one on its way: whatever it fails with is said to be the stopping.
fn stop(c: *Client, job: *Job) void {
    job.stopping.store(true, .release);
    if (is_web) web.glue.cancel(job.fetch) else _ = job.future.cancel(c.io);
}

/// How far a request not yet collected has come; null for one there is
/// no such request.
pub fn progress(c: *const Client, id: Id) ?Progress {
    const job = c.find(id) orelse return null;
    const total = job.total.load(.acquire);
    return .{
        .started = job.state.load(.acquire) != .waiting,
        .received = job.received.load(.acquire),
        .total = if (total == unknown_total) null else total,
    };
}

/// How many requests are not yet collected: waiting, on their way, or done.
pub fn pending(c: *const Client) usize {
    return c.jobs.items.len;
}

/// Ends what has run past its time, gives what has ended - as many as fit
/// in `into`, in the order they were sent, each the caller's to `deinit` -
/// and starts what waits. Once a frame.
pub fn update(c: *Client, into: []Done) []Done {
    if (is_web) for (c.jobs.items) |job| {
        if (job.state.load(.acquire) == .running) web.poll(c, job);
    };
    const now = Io.Clock.awake.now(c.io);
    for (c.jobs.items) |job| {
        if (job.state.load(.acquire) != .running or job.request.timeout_ms == 0) continue;
        const ran = job.started_at.durationTo(now).nanoseconds;
        if (ran < @as(i96, job.request.timeout_ms) * std.time.ns_per_ms) continue;
        job.timed_out = true;
        c.stop(job);
    }
    var n: usize = 0;
    var i: usize = 0;
    while (i < c.jobs.items.len and n < into.len) {
        const job = c.jobs.items[i];
        if (job.state.load(.acquire) != .done) {
            i += 1;
            continue;
        }
        if (!is_web) job.future.await(c.io);
        var result = job.result;
        if (job.timed_out) {
            if (result) |_| {} else |_| {
                result = error.Timeout;
                job.reason = "the time it was given ran out";
            }
        }
        into[n] = .{ .id = job.id, .result = result, .reason = job.reason };
        // The answer is the caller's now.
        job.result = error.Cancelled;
        n += 1;
        _ = c.jobs.orderedRemove(i);
        c.drop(job);
    }
    c.startWaiting();
    return into[0..n];
}

fn find(c: *const Client, id: Id) ?*Job {
    for (c.jobs.items) |job| if (job.id == id) return job;
    return null;
}

fn drop(c: *Client, job: *Job) void {
    if (is_web and job.fetch != 0) web.glue.release(job.fetch);
    if (job.result) |*r| r.deinit() else |_| {}
    job.arena.deinit();
    c.gpa.destroy(job);
}

fn startWaiting(c: *Client) void {
    var running: usize = 0;
    for (c.jobs.items) |job| {
        if (job.state.load(.acquire) == .running) running += 1;
    }
    for (c.jobs.items) |job| {
        if (running >= c.options.max_running) return;
        if (job.state.load(.acquire) != .waiting) continue;
        job.state.store(.running, .release);
        job.started_at = Io.Clock.awake.now(c.io);
        if (is_web) {
            web.start(c, job);
            running += 1;
            continue;
        }
        job.future = c.io.concurrent(run, .{ c, job }) catch {
            // Nowhere else to run it: it runs here, now.
            run(c, job);
            continue;
        };
        running += 1;
    }
}

fn run(c: *Client, job: *Job) void {
    job.result = c.perform(job);
    job.state.store(.done, .release);
}

/// Whether `url` may be asked at all: an http or https one, and plain http
/// only if the client allows it.
fn checkUrl(c: *const Client, job: *Job, url: []const u8) Error!void {
    const uri = std.Uri.parse(url) catch return job.failed(error.BadUrl, "the URL does not parse");
    if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) return;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) return job.failed(error.BadUrl, "only http and https URLs are asked");
    if (!c.options.allow_plain_http) return job.failed(error.NotSecure, "plain http is not allowed: ask over https");
}

fn perform(c: *Client, job: *Job) Error!Response {
    const r = &job.request;
    try c.checkUrl(job, r.url);
    const uri = std.Uri.parse(r.url) catch unreachable;

    const has_body = r.body.len > 0 or r.method.requestHasBody();
    var req = c.http_client.request(r.method, uri, .{
        .redirect_behavior = if (has_body) .unhandled else @enumFromInt(r.redirects),
        .headers = .{
            .user_agent = .{ .override = c.options.user_agent },
            .content_type = if (has_body) .{ .override = r.content_type orelse "application/octet-stream" } else .omit,
        },
        .extra_headers = r.headers,
    }) catch |err| return job.from(err);
    defer req.deinit();

    if (has_body) {
        req.transfer_encoding = .{ .content_length = r.body.len };
        var body = req.sendBodyUnflushed(&.{}) catch |err| return job.from(err);
        body.writer.writeAll(r.body) catch |err| return job.from(err);
        body.end() catch |err| return job.from(err);
        req.connection.?.flush() catch |err| return job.from(err);
    } else {
        req.sendBodiless() catch |err| return job.from(err);
    }
    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = req.receiveHead(if (has_body) &.{} else &redirect_buffer) catch |err| return job.from(err);

    var out: Response = .{ .status = @intFromEnum(response.head.status), .arena = .init(c.gpa) };
    errdefer out.arena.deinit();
    const a = out.arena.allocator();
    var headers: std.ArrayList(Header) = .empty;
    var it = response.head.iterateHeaders();
    while (it.next()) |h| try headers.append(a, .{ .name = try a.dupe(u8, h.name), .value = try a.dupe(u8, h.value) });
    out.headers = headers.items;
    if (response.head.content_length) |length| job.total.store(length, .release);

    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try a.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try a.alloc(u8, std.compress.flate.max_window_len),
        .compress => return job.failed(error.Broken, "the answer is compressed with `compress`, which is not read"),
    };
    var transfer_buffer: [16 * 1024]u8 = undefined;
    var decompress: http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    // A file is only ever what was asked for: an answer that is not a
    // success - a 404's page - is kept in memory instead, to say why.
    if (r.save_to != null and out.status >= 200 and out.status < 300) {
        out.size = try c.save(job, reader, &response, r.save_to.?);
    } else {
        var body: Io.Writer.Allocating = .init(a);
        out.size = try pump(job, reader, &response, &body.writer, r.max_body, error.OutOfMemory);
        out.body = body.written();
    }
    return out;
}

/// The body from `reader` into `w`, its length counted as it comes.
fn pump(job: *Job, reader: *Io.Reader, response: *http.Client.Response, w: *Io.Writer, max: ?usize, write_failure: Error) Error!u64 {
    var n: u64 = 0;
    while (true) {
        const got = reader.stream(w, .limited(64 * 1024)) catch |err| switch (err) {
            error.EndOfStream => return n,
            error.ReadFailed => return job.from(readFailure(response)),
            error.WriteFailed => return job.failed(write_failure, "the body could not be kept"),
        };
        n += got;
        if (max) |most| if (n > most) return job.failed(error.TooLarge, "the body is longer than the request allows");
        job.received.store(n, .release);
    }
}

fn readFailure(response: *http.Client.Response) anyerror {
    if (response.bodyErr()) |err| return err;
    if (response.request.connection) |connection| if (connection.getReadError()) |err| return err;
    return error.ReadFailed;
}

fn save(c: *Client, job: *Job, reader: *Io.Reader, response: *http.Client.Response, path: []const u8) Error!u64 {
    const dir = Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |parent| {
        dir.createDirPath(c.io, parent) catch |err| return job.failed(error.CannotSave, @errorName(err));
    }
    const part = try std.fmt.allocPrint(job.arena.allocator(), "{s}.part", .{path});
    var file = dir.createFile(c.io, part, .{}) catch |err| return job.failed(error.CannotSave, @errorName(err));
    var buffer: [16 * 1024]u8 = undefined;
    var w = file.writer(c.io, &buffer);
    const n = pump(job, reader, response, &w.interface, null, error.CannotSave) catch |err| {
        file.close(c.io);
        dir.deleteFile(c.io, part) catch {};
        return err;
    };
    w.interface.flush() catch {
        file.close(c.io);
        dir.deleteFile(c.io, part) catch {};
        return job.failed(error.CannotSave, "the file could not be written");
    };
    file.close(c.io);
    Io.Dir.rename(dir, part, dir, path, c.io) catch |err| {
        dir.deleteFile(c.io, part) catch {};
        return job.failed(error.CannotSave, @errorName(err));
    };
    return n;
}

/// A request as the page's `fetch`: `fluxion-net.js` is the other side. It
/// runs as the page's own; `update` asks how it is doing and, once it has
/// an answer, copies it out.
const web = struct {
    const glue = struct {
        /// Its headers are `name: value` lines; `follow` follows redirects,
        /// else one is a failure.
        extern "fluxion_net" fn start(method: [*]const u8, method_len: usize, url: [*]const u8, url_len: usize, headers: [*]const u8, headers_len: usize, body: [*]const u8, body_len: usize, follow: bool) u32;
        extern "fluxion_net" fn state(fetch: u32) State;
        extern "fluxion_net" fn received(fetch: u32) f64;
        /// -1 while the answer has not said.
        extern "fluxion_net" fn total(fetch: u32) f64;
        extern "fluxion_net" fn status(fetch: u32) u32;
        extern "fluxion_net" fn headersLength(fetch: u32) usize;
        extern "fluxion_net" fn bodyLength(fetch: u32) usize;
        /// Its headers, as `name: value` lines, and its body.
        extern "fluxion_net" fn copy(fetch: u32, headers: [*]u8, body: [*]u8) void;
        extern "fluxion_net" fn cancel(fetch: u32) void;
        /// Forgets it, stopping it if it is still on its way.
        extern "fluxion_net" fn release(fetch: u32) void;
    };

    const State = enum(u32) { running, answered, bad_url, connect, cancelled, broken, _ };

    fn start(c: *Client, job: *Job) void {
        const r = &job.request;
        c.checkUrl(job, r.url) catch |err| return finished(job, err);
        const has_body = r.body.len > 0 or r.method.requestHasBody();
        var headers: std.ArrayList(u8) = .empty;
        const a = job.arena.allocator();
        for (r.headers) |h| headers.print(a, "{s}: {s}\n", .{ h.name, h.value }) catch return finished(job, error.OutOfMemory);
        if (has_body) headers.print(a, "content-type: {s}\n", .{r.content_type orelse "application/octet-stream"}) catch return finished(job, error.OutOfMemory);
        const method = @tagName(r.method);
        job.fetch = glue.start(method.ptr, method.len, r.url.ptr, r.url.len, headers.items.ptr, headers.items.len, r.body.ptr, r.body.len, !has_body and r.redirects > 0);
    }

    fn poll(c: *Client, job: *Job) void {
        switch (glue.state(job.fetch)) {
            .running => {
                job.received.store(@intFromFloat(glue.received(job.fetch)), .release);
                const total = glue.total(job.fetch);
                if (total >= 0) job.total.store(@intFromFloat(total), .release);
            },
            .answered => finished(job, answer(c, job)),
            .bad_url => finished(job, job.failed(error.BadUrl, "the browser did not take the URL")),
            .connect => finished(job, job.failed(error.Connect, "the host could not be reached, or did not allow this page to ask it")),
            .cancelled => finished(job, job.failed(error.Cancelled, "cancelled")),
            else => finished(job, job.failed(error.Broken, "the answer broke off")),
        }
    }

    fn finished(job: *Job, result: Error!Response) void {
        job.result = if (job.stopping.load(.acquire)) blk: {
            if (result) |r| {
                var answered = r;
                answered.deinit();
            } else |_| {}
            break :blk job.failed(error.Cancelled, "cancelled");
        } else result;
        job.state.store(.done, .release);
    }

    fn answer(c: *Client, job: *Job) Error!Response {
        const r = &job.request;
        var out: Response = .{ .status = @intCast(glue.status(job.fetch)), .arena = .init(c.gpa) };
        errdefer out.arena.deinit();
        const a = out.arena.allocator();

        // Only a success goes to a file, as on any other system.
        const saving = r.save_to != null and out.status >= 200 and out.status < 300;
        const size = glue.bodyLength(job.fetch);
        if (!saving and size > r.max_body) return job.failed(error.TooLarge, "the body is longer than the request allows");
        const head = try a.alloc(u8, glue.headersLength(job.fetch));
        const body = try (if (saving) c.gpa else a).alloc(u8, size);
        defer if (saving) c.gpa.free(body);
        glue.copy(job.fetch, head.ptr, body.ptr);

        var headers: std.ArrayList(Header) = .empty;
        var lines = std.mem.tokenizeScalar(u8, head, '\n');
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            try headers.append(a, .{ .name = line[0..colon], .value = std.mem.trim(u8, line[colon + 1 ..], " ") });
        }
        out.headers = headers.items;
        out.size = size;
        job.received.store(size, .release);
        if (saving) try saveWhole(c, job, body, r.save_to.?) else out.body = body;
        return out;
    }

    /// Written as `<path>.part` and renamed, as a body streamed to a file is.
    fn saveWhole(c: *Client, job: *Job, bytes: []const u8, path: []const u8) Error!void {
        const dir = Io.Dir.cwd();
        if (std.fs.path.dirname(path)) |parent| {
            dir.createDirPath(c.io, parent) catch |err| return job.failed(error.CannotSave, @errorName(err));
        }
        const part = try std.fmt.allocPrint(job.arena.allocator(), "{s}.part", .{path});
        dir.writeFile(c.io, .{ .sub_path = part, .data = bytes }) catch |err| return job.failed(error.CannotSave, @errorName(err));
        Io.Dir.rename(dir, part, dir, path, c.io) catch |err| {
            dir.deleteFile(c.io, part) catch {};
            return job.failed(error.CannotSave, @errorName(err));
        };
    }
};

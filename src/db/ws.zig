//! A WebSocket client, for the one thing here that needs a socket that talks
//! back: `kubectl exec`'s side of a shell in a container.
//!
//! Kubernetes offers three ways into a container - SPDY, which is retired,
//! WebSocket, which every version since 1.29 speaks, and nothing else - so a
//! program that will not link a library has to write RFC 6455. That is less than
//! it sounds for a client: a handshake that is an HTTP request with four headers
//! and an answer to check, and a frame header of two to fourteen bytes.
//!
//! **A client masks and a server does not.** Every frame this sends carries four
//! random bytes and its payload XORed with them, which is in the standard to stop
//! a proxy being talked into forwarding something that looks like a request, and
//! is not security. Frames that arrive are refused if they are masked, because a
//! server that masks is not a server.
//!
//! **Fragmentation is real and is handled.** A message may arrive as an opening
//! frame and any number of continuations, and control frames may sit between
//! them - a ping in the middle of a long message is legal and has to be answered
//! without disturbing it.
//!
//! What is *not* here is anything a browser needs: no extensions, no compression,
//! no subprotocol negotiation beyond asking for one, and no server side. The
//! framing below is a pure function of bytes and is tested as one.

const std = @import("std");
const db = @import("db.zig");
const net = @import("net.zig");
const random = @import("random.zig");

const List = db.List;

pub const Error = error{ Ws, OutOfMemory };

/// The string RFC 6455 has everybody append before hashing, for no reason but to
/// make an accidental accept impossible.
const GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub const Opcode = enum(u4) {
    continuation = 0,
    text = 1,
    binary = 2,
    close = 8,
    ping = 9,
    pong = 10,
    _,
};

pub const Frame = struct {
    final: bool,
    opcode: Opcode,
    payload: []const u8,
};

/// Write a frame's header for `length` bytes of masked payload into `out`, and
/// give back the four mask bytes to XOR the payload with.
pub fn header(out: *[14]u8, opcode: Opcode, length: usize, mask: [4]u8) []const u8 {
    out[0] = 0x80 | @as(u8, @intFromEnum(opcode)); // FIN, and never a fragment
    var at: usize = 2;
    if (length < 126) {
        out[1] = 0x80 | @as(u8, @intCast(length));
    } else if (length <= 0xffff) {
        out[1] = 0x80 | 126;
        std.mem.writeInt(u16, out[2..4], @intCast(length), .big);
        at = 4;
    } else {
        out[1] = 0x80 | 127;
        std.mem.writeInt(u64, out[2..10], length, .big);
        at = 10;
    }
    @memcpy(out[at .. at + 4], &mask);
    return out[0 .. at + 4];
}

/// XOR a payload with its mask, continuing from `offset` bytes in - so a payload
/// written in pieces masks the same as one written whole.
pub fn applyMask(bytes: []u8, mask: [4]u8, offset: usize) void {
    for (bytes, 0..) |*byte, i| {
        byte.* ^= mask[(offset + i) % 4];
    }
}

/// What a frame header says, or null where `bytes` does not hold all of one yet.
pub const Head = struct {
    final: bool,
    opcode: Opcode,
    masked: bool,
    length: u64,
    /// How many bytes the header itself took.
    size: usize,
};

pub fn readHead(bytes: []const u8) ?Head {
    if (bytes.len < 2) {
        return null;
    }
    const first = bytes[0];
    const second = bytes[1];
    var length: u64 = second & 0x7f;
    var size: usize = 2;
    if (length == 126) {
        if (bytes.len < 4) {
            return null;
        }
        length = std.mem.readInt(u16, bytes[2..4], .big);
        size = 4;
    } else if (length == 127) {
        if (bytes.len < 10) {
            return null;
        }
        length = std.mem.readInt(u64, bytes[2..10], .big);
        size = 10;
    }
    const masked = (second & 0x80) != 0;
    if (masked) {
        size += 4;
        if (bytes.len < size) {
            return null;
        }
    }
    return .{
        .final = (first & 0x80) != 0,
        .opcode = @enumFromInt(@as(u4, @truncate(first & 0x0f))),
        .masked = masked,
        .length = length,
        .size = size,
    };
}

/// What the server must answer the handshake with: base64 of the SHA-1 of the
/// key it was sent and the standard's own string.
pub fn accept(out: *[28]u8, key: []const u8) []const u8 {
    var sum: [20]u8 = undefined;
    var hash = std.crypto.hash.Sha1.init(.{});
    hash.update(key);
    hash.update(GUID);
    hash.final(&sum);
    return std.base64.standard.Encoder.encode(out, &sum);
}

// ------------------------------------------------------------- the socket

/// How much of a message this will hold before calling the far end unreasonable.
pub const MESSAGE_LIMIT: usize = 8 << 20;

pub const Socket = struct {
    allocator: std.mem.Allocator,
    stream: net.Stream,
    /// What has arrived and not yet been taken apart.
    buffer: List = .empty,
    /// The message being assembled, where it came in fragments.
    message: List = .empty,
    closed: bool = false,

    pub fn deinit(self: *Socket) void {
        self.buffer.deinit(self.allocator);
        self.message.deinit(self.allocator);
        self.stream.close();
    }

    /// Send one whole message. Masked, as a client must.
    pub fn send(self: *Socket, opcode: Opcode, payload: []const u8) Error!void {
        var mask: [4]u8 = undefined;
        random.bytes(&mask) catch return error.Ws;
        var head: [14]u8 = undefined;
        self.stream.write(header(&head, opcode, payload.len, mask)) catch return error.Ws;
        if (payload.len == 0) {
            return;
        }
        // In pieces, so a megabyte of paste does not need a megabyte of copy.
        var chunk: [4096]u8 = undefined;
        var at: usize = 0;
        while (at < payload.len) {
            const size = @min(chunk.len, payload.len - at);
            @memcpy(chunk[0..size], payload[at .. at + size]);
            applyMask(chunk[0..size], mask, at);
            self.stream.write(chunk[0..size]) catch return error.Ws;
            at += size;
        }
    }

    /// The next whole message, or null where the far end has gone. Pings are
    /// answered here rather than handed up: nobody above this cares.
    pub fn receive(self: *Socket) Error!?Frame {
        while (true) {
            if (try self.take()) |frame| {
                switch (frame.opcode) {
                    .ping => {
                        try self.send(.pong, frame.payload);
                        continue;
                    },
                    .pong => continue,
                    .close => {
                        self.closed = true;
                        return null;
                    },
                    else => return frame,
                }
            }
            if (!try self.fill()) {
                return null;
            }
        }
    }

    /// A whole message out of what has arrived, if there is one there.
    fn take(self: *Socket) Error!?Frame {
        while (true) {
            const head = readHead(self.buffer.items) orelse return null;
            // A server that masks is not a server, and reading it as one would
            // hand back the mask as four bytes of payload.
            if (head.masked) {
                return error.Ws;
            }
            if (head.length > MESSAGE_LIMIT or self.message.items.len > MESSAGE_LIMIT) {
                return error.Ws;
            }
            const total = head.size + head.length;
            if (self.buffer.items.len < total) {
                return null;
            }
            const payload = self.buffer.items[head.size..total];
            const opcode = head.opcode;

            // A control frame may sit in the middle of a fragmented message and
            // must not join it.
            if (@intFromEnum(opcode) >= 8) {
                const copy = try self.allocator.dupe(u8, payload);
                errdefer self.allocator.free(copy);
                try self.eat(total);
                // Freed by the caller's next call; one control frame is small.
                defer self.allocator.free(copy);
                return .{ .final = true, .opcode = opcode, .payload = copy[0..copy.len] };
            }

            try self.message.appendSlice(self.allocator, payload);
            try self.eat(total);
            if (!head.final) {
                continue;
            }
            return .{ .final = true, .opcode = if (opcode == .continuation) .binary else opcode, .payload = self.message.items };
        }
    }

    /// Drop what has been read, and start the next message with nothing behind it.
    fn eat(self: *Socket, count: usize) Error!void {
        const left = self.buffer.items.len - count;
        std.mem.copyForwards(u8, self.buffer.items[0..left], self.buffer.items[count..]);
        self.buffer.shrinkRetainingCapacity(left);
    }

    /// The socket this is on, so a caller waiting on this and a terminal at once
    /// can wait on both.
    pub fn handle(self: *Socket) std.c.fd_t {
        return self.stream.fd;
    }

    /// Take whatever has arrived by now without waiting for more. False when the
    /// far end has gone; true - with nothing added - when it is simply quiet.
    pub fn drain(self: *Socket) Error!bool {
        var chunk: [16 << 10]u8 = undefined;
        const got = self.stream.readNow(&chunk) catch return false;
        if (got != 0) {
            try self.buffer.appendSlice(self.allocator, chunk[0..got]);
        }
        return true;
    }

    /// The next whole message out of what has already arrived, or null. Unlike
    /// `receive` this never waits on the network.
    pub fn next(self: *Socket) Error!?Frame {
        while (try self.take()) |frame| {
            switch (frame.opcode) {
                .ping => {
                    try self.send(.pong, frame.payload);
                    continue;
                },
                .pong => continue,
                .close => {
                    self.closed = true;
                    return null;
                },
                else => return frame,
            }
        }
        return null;
    }

    /// Take whatever the far end has sent. False when it has gone.
    fn fill(self: *Socket) Error!bool {
        var chunk: [16 << 10]u8 = undefined;
        const got = self.stream.readSome(&chunk) catch return false;
        if (got == 0) {
            return false;
        }
        try self.buffer.appendSlice(self.allocator, chunk[0..got]);
        return true;
    }

    /// Done with the message just handed out.
    pub fn done(self: *Socket) void {
        self.message.clearRetainingCapacity();
    }

    pub fn close(self: *Socket) void {
        if (!self.closed) {
            self.send(.close, &[_]u8{ 0x03, 0xe8 }) catch {};
            self.closed = true;
        }
    }
};

pub const Options = struct {
    host: []const u8,
    port: u16,
    tls: net.Tls = .{},
    use_tls: bool = true,
    /// The path and query, already escaped.
    target: []const u8,
    /// `Sec-WebSocket-Protocol`, which is how Kubernetes says which channel
    /// framing it will use.
    protocol: []const u8 = "",
    headers: []const [2][]const u8 = &.{},
    /// How long to wait on the socket at any one time.
    timeout_ms: i64 = 30_000,
};

/// Open a socket and get through the handshake, or say what went wrong.
pub fn connect(allocator: std.mem.Allocator, options: Options, why: *List) Error!Socket {
    var stream = net.connect(allocator, options.host, options.port) catch {
        try why.print(allocator, "cannot reach {s}:{d}", .{ options.host, options.port });
        return error.Ws;
    };
    errdefer stream.close();
    stream.setTimeout(options.timeout_ms);
    if (options.use_tls) {
        net.startTls(allocator, &stream, options.host, options.tls, why) catch {
            if (why.items.len == 0) {
                try why.appendSlice(allocator, "the TLS handshake failed");
            }
            return error.Ws;
        };
    }

    var nonce: [16]u8 = undefined;
    random.bytes(&nonce) catch return error.Ws;
    var key_bytes: [24]u8 = undefined;
    const key = std.base64.standard.Encoder.encode(&key_bytes, &nonce);

    var request: List = .empty;
    defer request.deinit(allocator);
    try request.print(allocator, "GET {s} HTTP/1.1\r\nHost: {s}\r\n", .{ options.target, options.host });
    try request.appendSlice(allocator, "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\n");
    try request.print(allocator, "Sec-WebSocket-Key: {s}\r\n", .{key});
    if (options.protocol.len != 0) {
        try request.print(allocator, "Sec-WebSocket-Protocol: {s}\r\n", .{options.protocol});
    }
    for (options.headers) |pair| {
        try request.print(allocator, "{s}: {s}\r\n", .{ pair[0], pair[1] });
    }
    try request.appendSlice(allocator, "\r\n");
    stream.write(request.items) catch {
        try why.appendSlice(allocator, "the connection went away before the handshake");
        return error.Ws;
    };

    var socket = Socket{ .allocator = allocator, .stream = stream };
    errdefer socket.buffer.deinit(allocator);
    // The answer's headers, up to the blank line. Whatever follows them is the
    // first frames and is kept.
    const end = while (true) {
        if (std.mem.indexOf(u8, socket.buffer.items, "\r\n\r\n")) |at| {
            break at + 4;
        }
        if (socket.buffer.items.len > 64 << 10) {
            try why.appendSlice(allocator, "the answer to the handshake was not a handshake");
            return error.Ws;
        }
        if (!try socket.fill()) {
            try why.appendSlice(allocator, "the connection closed during the handshake");
            return error.Ws;
        }
    };
    const answer = socket.buffer.items[0..end];
    if (!std.mem.startsWith(u8, answer, "HTTP/1.1 101") and !std.mem.startsWith(u8, answer, "HTTP/1.0 101")) {
        const line_end = std.mem.indexOfScalar(u8, answer, '\r') orelse answer.len;
        try why.print(allocator, "the server would not upgrade: {s}", .{answer[0..line_end]});
        return error.Ws;
    }
    // The one header that proves this is a WebSocket server and not something
    // that answers 101 to everything.
    var expected: [28]u8 = undefined;
    const wanted = accept(&expected, key);
    if (headerOf(answer, "sec-websocket-accept")) |said| {
        if (!std.mem.eql(u8, said, wanted)) {
            try why.appendSlice(allocator, "the server's handshake does not answer this key");
            return error.Ws;
        }
    } else {
        try why.appendSlice(allocator, "the server upgraded without saying to what");
        return error.Ws;
    }
    socket.eat(end) catch {};
    return socket;
}

fn headerOf(answer: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, answer, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name)) {
            return std.mem.trim(u8, line[colon + 1 ..], " ");
        }
    }
    return null;
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

test "the accept header is the one the standard's own example gives" {
    // RFC 6455 section 1.3, so a wrong SHA-1 or a wrong GUID cannot pass.
    var out: [28]u8 = undefined;
    try testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", accept(&out, "dGhlIHNhbXBsZSBub25jZQ=="));
}

test "a frame header says its length in as few bytes as it can" {
    var out: [14]u8 = undefined;
    const mask = [4]u8{ 1, 2, 3, 4 };

    // Short: the length is in the second byte, beside the mask bit.
    var head = header(&out, .binary, 5, mask);
    try testing.expectEqual(@as(usize, 6), head.len);
    try testing.expectEqual(@as(u8, 0x82), head[0]);
    try testing.expectEqual(@as(u8, 0x80 | 5), head[1]);

    // 126 and up: two more bytes.
    head = header(&out, .binary, 200, mask);
    try testing.expectEqual(@as(usize, 8), head.len);
    try testing.expectEqual(@as(u8, 0x80 | 126), head[1]);
    try testing.expectEqual(@as(u16, 200), std.mem.readInt(u16, head[2..4], .big));

    // 65536 and up: eight.
    head = header(&out, .binary, 70000, mask);
    try testing.expectEqual(@as(usize, 14), head.len);
    try testing.expectEqual(@as(u8, 0x80 | 127), head[1]);
    try testing.expectEqual(@as(u64, 70000), std.mem.readInt(u64, head[2..10], .big));

    // And what was written reads back the same way.
    for ([_]usize{ 0, 5, 125, 126, 200, 65535, 65536, 70000 }) |length| {
        const written = header(&out, .text, length, mask);
        const read = readHead(written).?;
        try testing.expect(read.final);
        try testing.expect(read.masked);
        try testing.expectEqual(Opcode.text, read.opcode);
        try testing.expectEqual(@as(u64, length), read.length);
        try testing.expectEqual(written.len, read.size);
    }
}

test "a header that has not all arrived yet is not a header" {
    var out: [14]u8 = undefined;
    const written = header(&out, .binary, 70000, .{ 9, 9, 9, 9 });
    var at: usize = 0;
    while (at < written.len) : (at += 1) {
        try testing.expect(readHead(written[0..at]) == null);
    }
    try testing.expect(readHead(written) != null);
}

test "masking is its own inverse, and survives being done in pieces" {
    const mask = [4]u8{ 0xde, 0xad, 0xbe, 0xef };
    var text = "the quick brown fox jumps over the lazy dog".*;
    const original = text;

    applyMask(&text, mask, 0);
    try testing.expect(!std.mem.eql(u8, &text, &original));
    applyMask(&text, mask, 0);
    try testing.expectEqualStrings(&original, &text);

    // The offset is what lets a long payload be written a chunk at a time: three
    // pieces have to come out the same as one.
    var whole = original;
    applyMask(&whole, mask, 0);
    var pieces = original;
    applyMask(pieces[0..7], mask, 0);
    applyMask(pieces[7..30], mask, 7);
    applyMask(pieces[30..], mask, 30);
    try testing.expectEqualSlices(u8, &whole, &pieces);
}

/// A socket with no network under it: what a server would have sent, ready to be
/// taken apart by the same code that takes a real one apart.
fn withBytes(allocator: std.mem.Allocator, bytes: []const u8) !Socket {
    var socket = Socket{ .allocator = allocator, .stream = undefined };
    try socket.buffer.appendSlice(allocator, bytes);
    return socket;
}

fn serverFrame(out: *List, allocator: std.mem.Allocator, final: bool, opcode: Opcode, payload: []const u8) !void {
    // Unmasked, as a server sends.
    try out.append(allocator, (if (final) @as(u8, 0x80) else 0) | @intFromEnum(opcode));
    if (payload.len < 126) {
        try out.append(allocator, @intCast(payload.len));
    } else {
        try out.append(allocator, 126);
        var two: [2]u8 = undefined;
        std.mem.writeInt(u16, &two, @intCast(payload.len), .big);
        try out.appendSlice(allocator, &two);
    }
    try out.appendSlice(allocator, payload);
}

test "a message split into fragments comes back as one" {
    const a = testing.allocator;
    var wire: List = .empty;
    defer wire.deinit(a);
    try serverFrame(&wire, a, false, .binary, "one ");
    try serverFrame(&wire, a, false, .continuation, "two ");
    try serverFrame(&wire, a, true, .continuation, "three");

    var socket = try withBytes(a, wire.items);
    defer {
        socket.buffer.deinit(a);
        socket.message.deinit(a);
    }
    const frame = (try socket.take()).?;
    try testing.expectEqualStrings("one two three", frame.payload);
    try testing.expectEqual(Opcode.binary, frame.opcode);
}

test "a control frame in the middle of a message does not join it" {
    const a = testing.allocator;
    var wire: List = .empty;
    defer wire.deinit(a);
    try serverFrame(&wire, a, false, .binary, "half ");
    try serverFrame(&wire, a, true, .ping, "beat");
    try serverFrame(&wire, a, true, .continuation, "a message");

    var socket = try withBytes(a, wire.items);
    defer {
        socket.buffer.deinit(a);
        socket.message.deinit(a);
    }
    // The ping arrives on its own, with the half-built message untouched.
    const ping = (try socket.take()).?;
    try testing.expectEqual(Opcode.ping, ping.opcode);
    const rest = (try socket.take()).?;
    try testing.expectEqualStrings("half a message", rest.payload);
}

test "a message that has not all arrived is waited for, not guessed at" {
    const a = testing.allocator;
    var wire: List = .empty;
    defer wire.deinit(a);
    try serverFrame(&wire, a, true, .binary, "a whole message");

    // Every prefix of it is not yet a message.
    var at: usize = 0;
    while (at < wire.items.len) : (at += 1) {
        var socket = try withBytes(a, wire.items[0..at]);
        defer {
            socket.buffer.deinit(a);
            socket.message.deinit(a);
        }
        try testing.expect(try socket.take() == null);
    }
}

test "a masked frame from a server is refused rather than read" {
    const a = testing.allocator;
    // A server must not mask; one that does would otherwise have four bytes of
    // mask read as the start of its payload.
    var out: [14]u8 = undefined;
    const head = header(&out, .binary, 4, .{ 1, 2, 3, 4 });
    var wire: List = .empty;
    defer wire.deinit(a);
    try wire.appendSlice(a, head);
    try wire.appendSlice(a, "\x00\x00\x00\x00");

    var socket = try withBytes(a, wire.items);
    defer {
        socket.buffer.deinit(a);
        socket.message.deinit(a);
    }
    try testing.expectError(error.Ws, socket.take());
}

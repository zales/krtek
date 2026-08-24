//! TDS, the protocol SQL Server speaks.
//!
//! Written out rather than linked, which for this engine is the only way that
//! keeps krtek one file that needs nothing installed. The three SQL engines here
//! use their vendor's C library because a good one exists and may be
//! redistributed; for SQL Server neither is true - Microsoft's driver is
//! proprietary and FreeTDS is LGPL, which a static binary cannot carry without
//! shipping the pieces to relink it. So this is the same reasoning that produced
//! the Kafka and Redis drivers, applied to a protocol that is older and stranger
//! than either.
//!
//! Strange in one particular way worth knowing before reading on: the TLS
//! handshake happens *inside* TDS packets. The client sends a PRELOGIN, the
//! server says whether it wants encryption, and then every record of the
//! handshake travels as the payload of a TDS packet of its own - so OpenSSL
//! cannot simply be pointed at the socket. It writes into memory instead, and
//! this file does the posting. Once the handshake is done the records go down
//! the socket the ordinary way.

const std = @import("std");
const db = @import("db.zig");
const net = @import("net.zig");

const ssl = net.ssl;

/// What a packet carries, in its first byte.
pub const Login = struct {
    user: []const u8,
    password: []const u8,
    database: []const u8 = "",
    host: []const u8 = "krtek",
};

pub const Kind = enum(u8) {
    batch = 0x01,
    /// Stop what you are doing. Carries nothing - the packet is the message -
    /// and the server answers it with a DONE saying it has stopped.
    attention = 0x06,
    login = 0x10,
    prelogin = 0x12,
};

/// The most a packet may hold, agreed at login. 4096 is what the server assumes
/// before it is told otherwise, and there is nothing here that a bigger one
/// would make faster: the reply is read as a stream either way.
pub const PACKET = 4096;

/// The header every packet carries, big-endian - the one part of TDS that is.
pub const Header = extern struct {
    kind: u8,
    status: u8,
    length_high: u8,
    length_low: u8,
    spid_high: u8,
    spid_low: u8,
    packet: u8,
    window: u8,

    pub const SIZE = 8;
    /// The last packet of a message says so, and the reader stops there.
    pub const LAST: u8 = 0x01;

    pub fn length(self: Header) u16 {
        return (@as(u16, self.length_high) << 8) | self.length_low;
    }
};

pub fn header(kind: Kind, length: u16, last: bool, number: u8) [Header.SIZE]u8 {
    return .{
        @intFromEnum(kind),
        if (last) Header.LAST else 0,
        @intCast(length >> 8),
        @truncate(length),
        0,
        0,
        number,
        0,
    };
}

/// The password, as TDS carries it: every UTF-16 byte has its nibbles swapped
/// and is then exclusive-ored with 0xA5.
///
/// This is not encryption and is not meant to be - it is why the login travels
/// under TLS whatever else does. Written out here so that nobody reading the
/// login packet has to wonder whether it is.
pub fn scramble(into: []u8, password: []const u16) void {
    for (password, 0..) |unit, i| {
        const low: u8 = @truncate(unit);
        const high: u8 = @truncate(unit >> 8);
        into[i * 2] = (((low << 4) | (low >> 4)) & 0xFF) ^ 0xA5;
        into[i * 2 + 1] = (((high << 4) | (high >> 4)) & 0xFF) ^ 0xA5;
    }
}

/// Text as TDS wants it: UTF-16, little end first, everywhere.
pub fn utf16(arena: std.mem.Allocator, text: []const u8) ![]u16 {
    return std.unicode.utf8ToUtf16LeAlloc(arena, text);
}

/// One connection to a server: the socket, the TLS session on top of it, and
/// the buffer a reply is read into.
///
/// The TLS session talks to memory rather than to the socket, for the reason in
/// the note at the top of this file, and it goes on doing so after the handshake
/// - there is no way to hand OpenSSL the socket halfway through. So every read
/// and write pumps bytes between the memory and the socket, which is a few lines
/// once and nothing to think about afterwards.
pub const Connection = struct {
    allocator: std.mem.Allocator,
    stream: net.Stream,
    ctx: ?*anyopaque = null,
    session: ?*anyopaque = null,
    /// What OpenSSL reads from and writes to. Owned by the session once handed
    /// over, so they are not freed here.
    incoming: ?*anyopaque = null,
    outgoing: ?*anyopaque = null,
    /// While the handshake is running its records travel inside packets; after
    /// it they are the stream.
    handshaking: bool = true,
    /// Which transaction the session is in, or zero for none. Every statement
    /// says so in its header - a statement that claims the wrong one is not part
    /// of the transaction the user opened, and the server quietly treats it as
    /// its own.
    transaction: u64 = 0,
    /// What went wrong, in words somebody can act on.
    trouble: db.List = .empty,

    pub const Options = struct {
        /// Whether the server's certificate is checked. SQL Server generates its
        /// own on first start and nothing signs it, so a great many real servers
        /// answer with one that cannot be verified - which is why this is asked
        /// rather than assumed.
        verify: bool = false,
        ca_pem: []const u8 = "",
    };

    pub fn open(
        allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
        options: Options,
        why: *db.List,
    ) !*Connection {
        const self = try allocator.create(Connection);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .stream = net.connect(allocator, host, port) catch {
                try why.print(allocator, "cannot reach {s}:{d}", .{ host, port });
                return error.Driver;
            },
        };
        errdefer self.close();
        self.stream.setTimeout(net.READ_TIMEOUT_MS);

        try self.prelogin(why);
        try self.startTls(host, options, why);
        return self;
    }

    /// What the two ends tell each other before there is a session: which
    /// version, and whether what follows is encrypted.
    ///
    /// Encryption is offered rather than merely accepted. A server may answer
    /// that it wants the login encrypted and the rest in the clear, which means
    /// turning TLS off halfway through a conversation - so this asks for the
    /// whole thing to be encrypted and there is no halfway.
    fn prelogin(self: *Connection, why: *db.List) !void {
        const options = [_]struct { token: u8, value: []const u8 }{
            .{ .token = 0, .value = &.{ 0x11, 0, 0, 0, 0, 0 } }, // version
            .{ .token = 1, .value = &.{0x01} }, // encryption: on
            .{ .token = 4, .value = &.{0x00} }, // MARS: no
        };
        var payload: [64]u8 = undefined;
        var at: usize = 0;
        var offset: u16 = @intCast(options.len * 5 + 1);
        for (options) |one| {
            payload[at] = one.token;
            std.mem.writeInt(u16, payload[at + 1 ..][0..2], offset, .big);
            std.mem.writeInt(u16, payload[at + 3 ..][0..2], @intCast(one.value.len), .big);
            at += 5;
            offset += @intCast(one.value.len);
        }
        payload[at] = 0xff;
        at += 1;
        for (options) |one| {
            @memcpy(payload[at..][0..one.value.len], one.value);
            at += one.value.len;
        }
        try self.sendPlain(.prelogin, payload[0..at], why);
        var answer = db.List.empty;
        defer answer.deinit(self.allocator);
        try self.readPlain(&answer, why);
    }

    /// A whole packet, straight down the socket. Only the prelogin and the
    /// handshake go this way; everything after is inside TLS.
    fn sendPlain(self: *Connection, kind: Kind, payload: []const u8, why: *db.List) !void {
        const head = header(kind, @intCast(Header.SIZE + payload.len), true, 1);
        self.stream.write(&head) catch return self.gone(why);
        if (payload.len != 0) {
            self.stream.write(payload) catch return self.gone(why);
        }
    }

    /// One packet from the socket, its payload appended.
    fn readPlain(self: *Connection, into: *db.List, why: *db.List) !void {
        var head: [Header.SIZE]u8 = undefined;
        self.stream.readExactly(&head) catch return self.gone(why);
        const said: Header = @bitCast(head);
        const length = said.length();
        if (length < Header.SIZE) {
            try why.appendSlice(self.allocator, "the server sent a packet shorter than its own header");
            return error.Driver;
        }
        const rest = length - Header.SIZE;
        const start = into.items.len;
        try into.resize(self.allocator, start + rest);
        self.stream.readExactly(into.items[start..]) catch return self.gone(why);
    }

    fn gone(self: *Connection, why: *db.List) anyerror {
        if (why.items.len == 0) {
            try why.appendSlice(self.allocator, "the connection to the server is gone");
        }
        return error.Driver;
    }

    /// The handshake, one record at a time, each inside a packet of its own.
    fn startTls(self: *Connection, host: []const u8, options: Options, why: *db.List) !void {
        _ = ssl.OPENSSL_init_ssl(0, null);
        self.ctx = ssl.SSL_CTX_new(ssl.TLS_client_method()) orelse {
            try why.appendSlice(self.allocator, "no TLS on this machine");
            return error.Driver;
        };
        if (options.verify) {
            if (options.ca_pem.len != 0) {
                _ = net.trustPem(self.allocator, self.ctx, options.ca_pem, why) catch {};
            } else if (ssl.SSL_CTX_set_default_verify_paths(self.ctx) != 1) {
                try why.appendSlice(self.allocator, "no trusted certificates on this machine");
                return error.Driver;
            }
            ssl.SSL_CTX_set_verify(self.ctx, ssl.VERIFY_PEER, null);
        }
        self.session = ssl.SSL_new(self.ctx) orelse {
            try why.appendSlice(self.allocator, "no TLS session");
            return error.Driver;
        };
        self.incoming = ssl.BIO_new(ssl.BIO_s_mem());
        self.outgoing = ssl.BIO_new(ssl.BIO_s_mem());
        if (self.incoming == null or self.outgoing == null) {
            try why.appendSlice(self.allocator, "out of memory for the TLS session");
            return error.Driver;
        }
        ssl.SSL_set_bio(self.session, self.incoming, self.outgoing);
        ssl.SSL_set_connect_state(self.session);

        const zero_host = try self.allocator.dupeZ(u8, host);
        defer self.allocator.free(zero_host);
        _ = ssl.SSL_ctrl(self.session, ssl.CTRL_SET_TLSEXT_HOSTNAME, ssl.TLSEXT_NAMETYPE_host_name, @ptrCast(@constCast(zero_host.ptr)));
        if (options.verify) {
            _ = ssl.SSL_set1_host(self.session, zero_host.ptr);
        }

        var rounds: usize = 0;
        while (true) {
            const done = ssl.SSL_do_handshake(self.session);
            try self.flush(why);
            if (done == 1) {
                self.handshaking = false;
                return;
            }
            const said = ssl.SSL_get_error(self.session, done);
            if (said != ssl.ERROR_WANT_READ and said != ssl.ERROR_WANT_WRITE) {
                var buffer: [256]u8 = undefined;
                const text = ssl.lastError(&buffer);
                try why.print(self.allocator, "the TLS handshake failed{s}{s}", .{
                    if (text.len != 0) ": " else "",
                    text,
                });
                return error.Driver;
            }
            rounds += 1;
            if (rounds > 32) {
                try why.appendSlice(self.allocator, "the TLS handshake would not finish");
                return error.Driver;
            }
            var answer = db.List.empty;
            defer answer.deinit(self.allocator);
            try self.readPlain(&answer, why);
            if (answer.items.len != 0) {
                _ = ssl.BIO_write(self.incoming, answer.items.ptr, @intCast(answer.items.len));
            }
        }
    }

    /// Whatever OpenSSL has produced, sent. During the handshake each flight
    /// goes inside a packet of its own, because that is where the server is
    /// looking for it; once there is a session the encrypted bytes are the
    /// stream itself and go down the socket as they are.
    fn flush(self: *Connection, why: *db.List) !void {
        while (ssl.BIO_ctrl(self.outgoing, ssl.CTRL_PENDING, 0, null) > 0) {
            var chunk: [PACKET]u8 = undefined;
            const got = ssl.BIO_read(self.outgoing, &chunk, chunk.len);
            if (got <= 0) {
                return;
            }
            const bytes = chunk[0..@intCast(got)];
            if (self.handshaking) {
                try self.sendPlain(.prelogin, bytes, why);
            } else {
                self.stream.write(bytes) catch return self.gone(why);
            }
        }
    }

    // --------------------------------------------------------------- talking

    /// Everything after the handshake goes through the session, and the session
    /// writes into memory - so a write is two steps: hand it to OpenSSL, then
    /// post what OpenSSL produced.
    fn sendSecure(self: *Connection, kind: Kind, payload: []const u8, why: *db.List) !void {
        var at: usize = 0;
        var number: u8 = 1;
        var whole: [PACKET]u8 = undefined;
        while (true) {
            const take = @min(PACKET - Header.SIZE, payload.len - at);
            const last = at + take >= payload.len;
            whole[0..Header.SIZE].* = header(kind, @intCast(Header.SIZE + take), last, number);
            @memcpy(whole[Header.SIZE..][0..take], payload[at..][0..take]);
            // Header and payload in one go: the server reads a packet out of a
            // record, so a packet split across two records is a packet it never
            // sees the end of.
            try self.writeSecure(whole[0 .. Header.SIZE + take], why);
            at += take;
            number +%= 1;
            if (last) {
                break;
            }
        }
        try self.flush(why);
    }

    fn writeSecure(self: *Connection, bytes: []const u8, why: *db.List) !void {
        var at: usize = 0;
        while (at < bytes.len) {
            const wrote = ssl.SSL_write(self.session, bytes[at..].ptr, @intCast(bytes.len - at));
            if (wrote <= 0) {
                try why.appendSlice(self.allocator, "the connection to the server is gone");
                return error.Driver;
            }
            at += @intCast(wrote);
            try self.flush(why);
        }
    }

    /// Bytes out of the session, filling it from the socket when it has none.
    ///
    /// `may_stop` is whether whoever asked for this may change their mind now.
    /// They may only do so on a packet boundary: the answer to a statement is a
    /// stream of packets, and walking away from the middle of one leaves the
    /// next read starting inside a packet with no way to tell.
    fn readSecure(self: *Connection, into: []u8, why: *db.List, may_stop: bool) !usize {
        while (true) {
            const got = ssl.SSL_read(self.session, into.ptr, @intCast(into.len));
            if (got > 0) {
                return @intCast(got);
            }
            const said = ssl.SSL_get_error(self.session, got);
            if (said != ssl.ERROR_WANT_READ and said != ssl.ERROR_WANT_WRITE) {
                try why.appendSlice(self.allocator, "the connection to the server is gone");
                return error.Driver;
            }
            var chunk: [PACKET]u8 = undefined;
            const asking = self.stream.keep_waiting;
            if (!may_stop) {
                self.stream.keep_waiting = null;
            }
            const arrived = self.stream.readSome(&chunk) catch |e| {
                self.stream.keep_waiting = asking;
                if (e == error.GivenUp) {
                    return error.GivenUp;
                }
                return self.gone(why);
            };
            self.stream.keep_waiting = asking;
            if (arrived == 0) {
                return self.gone(why);
            }
            _ = ssl.BIO_write(self.incoming, &chunk, @intCast(arrived));
        }
    }

    fn readExactlySecure(self: *Connection, into: []u8, why: *db.List, may_stop: bool) !void {
        var at: usize = 0;
        while (at < into.len) {
            // Only before the first byte: after that this is inside a packet.
            at += try self.readSecure(into[at..], why, may_stop and at == 0);
        }
    }

    /// Tell the server to stop, and then read until it says it has.
    ///
    /// The draining is not optional and cannot itself be given up on. Until the
    /// server acknowledges, the connection is in the middle of an answer, and a
    /// statement written into the middle of one goes nowhere.
    fn stop(self: *Connection, why: *db.List) anyerror {
        // Through the session, not down the socket: `sendPlain` is for the
        // handshake, and a packet written in the clear into a TLS stream is
        // noise that ends the connection rather than the statement.
        self.sendSecure(.attention, "", why) catch {};
        var rounds: usize = 0;
        while (rounds < 64) : (rounds += 1) {
            var scratch = std.heap.ArenaAllocator.init(self.allocator);
            defer scratch.deinit();
            const arena = scratch.allocator();
            const bytes = self.message(arena, why, false) catch break;
            var quiet: db.List = .empty;
            defer quiet.deinit(self.allocator);
            // Whatever the abandoned statement had to say is not wanted; what is
            // wanted is the one token that says it has stopped.
            const reply = read(arena, bytes, &quiet, self.allocator) catch continue;
            if (reply.attention) {
                break;
            }
        }
        why.clearRetainingCapacity();
        try why.appendSlice(self.allocator, "stopped");
        return error.GivenUp;
    }

    /// One whole message - every packet up to the one that says it is the last -
    /// as the token stream it carries.
    pub fn message(self: *Connection, arena: std.mem.Allocator, why: *db.List, may_stop: bool) ![]const u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        while (true) {
            var head: [Header.SIZE]u8 = undefined;
            self.readExactlySecure(&head, why, may_stop) catch |e| {
                if (e == error.GivenUp) {
                    return self.stop(why);
                }
                return e;
            };
            const said: Header = @bitCast(head);
            const length = said.length();
            if (length < Header.SIZE) {
                try why.appendSlice(self.allocator, "the server sent a packet shorter than its own header");
                return error.Driver;
            }
            const start = out.items.len;
            try out.resize(arena, start + length - Header.SIZE);
            try self.readExactlySecure(out.items[start..], why, false);
            if (said.status & Header.LAST != 0) {
                return out.items;
            }
        }
    }

    /// Who is asking, and for which database. The password is obfuscated the
    /// only way TDS knows how, which is why none of this happens before TLS.
    pub fn login(
        self: *Connection,
        arena: std.mem.Allocator,
        who: Login,
        why: *db.List,
    ) ![]const u8 {
        const body = try loginBody(arena, who);
        try self.sendSecure(.login, body, why);
        return self.message(arena, why, false);
    }

    /// The bytes of a LOGIN7, apart from the sending of them - so that what goes
    /// on the wire can be checked without a server to send it to.
    pub fn loginBody(arena: std.mem.Allocator, who: Login) ![]const u8 {
        const user = try utf16(arena, who.user);
        const password = try utf16(arena, who.password);
        const database = try utf16(arena, who.database);
        const host = try utf16(arena, who.host);
        const application = try utf16(arena, "krtek");

        const masked = try arena.alloc(u8, password.len * 2);
        scramble(masked, password);

        const fields = [_][]const u8{
            std.mem.sliceAsBytes(host),
            std.mem.sliceAsBytes(user),
            masked,
            std.mem.sliceAsBytes(application),
            std.mem.sliceAsBytes(host),
            "",
            std.mem.sliceAsBytes(application),
            "",
            std.mem.sliceAsBytes(database),
        };
        const counts = [_]u16{
            @intCast(host.len),        @intCast(user.len), @intCast(password.len),
            @intCast(application.len), @intCast(host.len), 0,
            @intCast(application.len), 0,                  @intCast(database.len),
        };

        // The fixed part of a LOGIN7 is 94 bytes and every offset in it is
        // counted from the start of that part, so the strings begin at 94. The
        // fixed part goes: six numbers, four option bytes, the time zone and the
        // language, then nine offset/length pairs, six bytes of client id, three
        // more pairs nothing here uses, and a length that goes with them.
        const FIXED: u16 = 94;
        const PAIRS: usize = 36;
        var out: std.ArrayListUnmanaged(u8) = .empty;
        try out.appendNTimes(arena, 0, FIXED);
        // TDS 7.4, the packet size asked for, and a version for the log.
        std.mem.writeInt(u32, out.items[4..][0..4], 0x74000004, .little);
        std.mem.writeInt(u32, out.items[8..][0..4], PACKET, .little);
        std.mem.writeInt(u32, out.items[12..][0..4], 7, .little);
        // fUseDB and fSetLang: change database and language without a warning
        // about having done so.
        out.items[25] = 0x03;
        std.mem.writeInt(u32, out.items[32..][0..4], 1033, .little);

        var offset: u16 = FIXED;
        var at: usize = PAIRS;
        for (fields, counts) |field, count| {
            std.mem.writeInt(u16, out.items[at..][0..2], if (field.len != 0) offset else 0, .little);
            std.mem.writeInt(u16, out.items[at + 2 ..][0..2], count, .little);
            at += 4;
            offset += @intCast(field.len);
            try out.appendSlice(arena, field);
        }
        std.mem.writeInt(u32, out.items[0..4], @intCast(out.items.len), .little);

        return out.items;
    }

    /// A statement, as text. TDS 7.2 and later want a header block in front of
    /// it saying which transaction it belongs to; none of these belong to one.
    pub fn batch(self: *Connection, arena: std.mem.Allocator, sql: []const u8, why: *db.List) ![]const u8 {
        const text = try utf16(arena, sql);
        var out: std.ArrayListUnmanaged(u8) = .empty;
        try out.appendSlice(arena, &std.mem.toBytes(@as(u32, 22)));
        try out.appendSlice(arena, &std.mem.toBytes(@as(u32, 18)));
        try out.appendSlice(arena, &std.mem.toBytes(@as(u16, 2)));
        try out.appendSlice(arena, &std.mem.toBytes(self.transaction));
        try out.appendSlice(arena, &std.mem.toBytes(@as(u32, 1)));
        try out.appendSlice(arena, std.mem.sliceAsBytes(text));
        try self.sendSecure(.batch, out.items, why);
        return self.message(arena, why, true);
    }

    pub fn close(self: *Connection) void {
        if (self.session) |session| {
            _ = ssl.SSL_shutdown(session);
            ssl.SSL_free(session);
            self.session = null;
        }
        if (self.ctx) |ctx| {
            ssl.SSL_CTX_free(ctx);
            self.ctx = null;
        }
        self.stream.close();
        self.trouble.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

// ---------------------------------------------------------------- the answer

/// What the server said a column is. The type byte is kept as it came: the
/// value reader needs it, and so does anything deciding whether a column holds
/// numbers.
pub const Column = struct {
    name: []const u8,
    kind: u8,
    size: u32 = 0,
    precision: u8 = 0,
    scale: u8 = 0,
    flags: u16 = 0,

    pub fn nullable(self: Column) bool {
        return self.flags & 0x0001 != 0;
    }

    /// Right-aligned in the grid. Money and decimals are text by the time they
    /// arrive - they do not fit a float without changing - but they are still
    /// numbers to look at.
    pub fn numeric(self: Column) bool {
        return switch (self.kind) {
            0x30, 0x34, 0x38, 0x7F, 0x26 => true, // the integers
            0x3B, 0x3E, 0x6D => true, // the floats
            0x3C, 0x7A, 0x6E => true, // money
            0x37, 0x3F, 0x6A, 0x6C => true, // decimal and numeric
            else => false,
        };
    }
};

/// One statement's worth of answer.
pub const Reply = struct {
    columns: []const Column = &.{},
    rows: []const []const db.Value = &.{},
    /// What the statement changed, where the server counted it.
    affected: i64 = 0,
    /// Whatever PRINT and the low-severity messages said, one per line.
    notes: []const u8 = "",
    /// Where a `use` moved the session to, empty when it did not move.
    database: []const u8 = "",
    began: usize = 0,
    ended: usize = 0,
    /// The transaction the session is now in, where it changed: the eight bytes
    /// the server gave it, or zero once it is over. Null means the message said
    /// nothing about transactions and whatever was true still is.
    transaction: ?u64 = null,
    /// The server saying it has stopped, in answer to being told to. Nothing
    /// else may be sent until this arrives - the connection is mid-answer until
    /// then, and a statement written into the middle of one is lost.
    attention: bool = false,
};

/// Walks a message, which is bytes that have already all arrived.
const Reader = struct {
    bytes: []const u8,
    at: usize = 0,

    fn take(self: *Reader, count: usize) ![]const u8 {
        if (self.at + count > self.bytes.len) {
            return error.Short;
        }
        defer self.at += count;
        return self.bytes[self.at..][0..count];
    }

    fn byte(self: *Reader) !u8 {
        return (try self.take(1))[0];
    }

    fn int(self: *Reader, comptime T: type) !T {
        return std.mem.readInt(T, (try self.take(@divExact(@typeInfo(T).int.bits, 8)))[0..@divExact(@typeInfo(T).int.bits, 8)], .little);
    }

    /// A name: a count of characters, then that many pairs of bytes.
    fn name(self: *Reader, arena: std.mem.Allocator, comptime Count: type) ![]const u8 {
        const count = try self.int(Count);
        return fromUtf16(arena, try self.take(@as(usize, count) * 2));
    }

    fn done(self: *Reader) bool {
        return self.at >= self.bytes.len;
    }
};

pub fn fromUtf16(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.ensureTotalCapacity(arena, bytes.len);
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 2) {
        var one: u21 = std.mem.readInt(u16, bytes[i..][0..2], .little);
        // A character outside the basic plane arrives as two halves; an
        // unpaired half is written out as the replacement rather than refused,
        // because a column of names is not the place to fail a query.
        if (one >= 0xD800 and one <= 0xDBFF and i + 3 < bytes.len) {
            const low = std.mem.readInt(u16, bytes[i + 2 ..][0..2], .little);
            if (low >= 0xDC00 and low <= 0xDFFF) {
                one = 0x10000 + ((one - 0xD800) << 10) + (low - 0xDC00);
                i += 2;
            }
        }
        if (one >= 0xD800 and one <= 0xDFFF) {
            one = 0xFFFD;
        }
        var buffer: [4]u8 = undefined;
        const wrote = std.unicode.utf8Encode(one, &buffer) catch continue;
        try out.appendSlice(arena, buffer[0..wrote]);
    }
    return out.items;
}

/// The whole token stream of one message.
///
/// Tokens are self describing but not self delimiting: a reader that does not
/// know a token has no way to step over it, which is why every one that can
/// turn up here is handled rather than skipped.
pub fn read(arena: std.mem.Allocator, bytes: []const u8, why: *db.List, allocator: std.mem.Allocator) !Reply {
    var reader = Reader{ .bytes = bytes };
    var out = Reply{};
    var columns: std.ArrayListUnmanaged(Column) = .empty;
    var rows: std.ArrayListUnmanaged([]const db.Value) = .empty;
    var notes: std.ArrayListUnmanaged(u8) = .empty;
    var failed = false;

    while (!reader.done()) {
        const token = reader.byte() catch break;
        switch (token) {
            0x81 => { // COLMETADATA
                columns.clearRetainingCapacity();
                const count = try reader.int(u16);
                if (count == 0xFFFF) {
                    continue; // the statement returned no columns of its own
                }
                for (0..count) |_| {
                    try columns.append(arena, try column(arena, &reader));
                }
            },
            0xD1 => { // ROW
                const values = try arena.alloc(db.Value, columns.items.len);
                for (columns.items, values) |one, *into| {
                    into.* = try value(arena, &reader, one);
                }
                try rows.append(arena, values);
            },
            0xD2 => { // NBCROW: the nulls are named up front rather than sent
                const map = try reader.take((columns.items.len + 7) / 8);
                const values = try arena.alloc(db.Value, columns.items.len);
                for (columns.items, values, 0..) |one, *into, i| {
                    if (map[i / 8] & (@as(u8, 1) << @intCast(i % 8)) != 0) {
                        into.* = .{ .null = {} };
                    } else {
                        into.* = try value(arena, &reader, one);
                    }
                }
                try rows.append(arena, values);
            },
            0xAA, 0xAB => { // ERROR, INFO
                const length = try reader.int(u16);
                const body = try reader.take(length);
                var inner = Reader{ .bytes = body };
                const number = try inner.int(u32);
                _ = try inner.byte(); // state
                const severity = try inner.byte();
                const text = try inner.name(arena, u16);
                if (token == 0xAA) {
                    // The first error is the one that says what happened; the
                    // ones after it are the server explaining where.
                    if (!failed) {
                        failed = true;
                        why.clearRetainingCapacity();
                        try why.appendSlice(allocator, text);
                    }
                } else if (severity <= 10 and number != 5701 and number != 5703) {
                    // 5701 and 5703 are "database changed" and "language
                    // changed", which the session says on every connect and
                    // nobody wants repeated at them.
                    if (notes.items.len != 0) {
                        try notes.append(arena, '\n');
                    }
                    try notes.appendSlice(arena, text);
                }
            },
            0xAD => { // LOGINACK
                const length = try reader.int(u16);
                _ = try reader.take(length);
            },
            0xE3 => { // ENVCHANGE
                const length = try reader.int(u16);
                const body = try reader.take(length);
                var inner = Reader{ .bytes = body };
                const what = inner.byte() catch continue;
                switch (what) {
                    1 => out.database = inner.name(arena, u8) catch "",
                    8 => {
                        out.began += 1;
                        // The new value is the descriptor, and every statement
                        // from here has to carry it or the server will not
                        // count it as part of this transaction.
                        out.transaction = descriptor(&inner);
                    },
                    9, 10 => {
                        out.ended += 1;
                        out.transaction = 0;
                    },
                    else => {},
                }
            },
            0xE5 => { // RETURNSTATUS-adjacent: SSPI, which never happens here
                const length = try reader.int(u16);
                _ = try reader.take(length);
            },
            0x79 => _ = try reader.int(u32), // RETURNSTATUS
            0xFD, 0xFE, 0xFF => { // DONE, DONEPROC, DONEINPROC
                const status = try reader.int(u16);
                _ = try reader.int(u16); // which statement
                const count = try reader.int(u64);
                if (status & 0x0010 != 0) { // the count means something
                    out.affected += @intCast(count);
                }
                if (status & 0x0020 != 0) {
                    out.attention = true;
                }
            },
            0xA9 => { // ORDER: which columns the rows are sorted by
                const length = try reader.int(u16);
                _ = try reader.take(length);
            },
            0xE2 => { // COLINFO
                const length = try reader.int(u16);
                _ = try reader.take(length);
            },
            0xA4 => { // TABNAME
                const length = try reader.int(u16);
                _ = try reader.take(length);
            },
            else => {
                // Not knowing a token means not knowing where the next one
                // starts, so this stops rather than guessing.
                if (!failed) {
                    try why.print(allocator, "the server sent something this does not read: token 0x{x:0>2}", .{token});
                }
                failed = true;
                break;
            },
        }
    }
    if (failed) {
        return error.Driver;
    }
    out.columns = columns.items;
    out.rows = rows.items;
    out.notes = notes.items;
    return out;
}

/// One column's description. The shape depends on the type, which is the whole
/// difficulty: a fixed length type says nothing more, a text one carries a
/// collation, and a decimal carries the two numbers that decide what its digits
/// mean.
fn column(arena: std.mem.Allocator, reader: *Reader) !Column {
    _ = try reader.int(u32); // user type
    const flags = try reader.int(u16);
    const kind = try reader.byte();
    var out = Column{ .name = "", .kind = kind, .flags = flags };
    switch (kind) {
        0x1F, 0x32, 0x30, 0x34, 0x38, 0x7F, 0x3B, 0x3E, 0x3A, 0x3D, 0x3C, 0x7A => {
            out.size = fixedSize(kind);
        },
        0x24, 0x26, 0x68, 0x6D, 0x6E, 0x6F, 0x2F, 0x27 => {
            out.size = try reader.byte();
        },
        // A date says nothing about itself: there is only one kind of date, and
        // it is three bytes wide.
        0x28 => out.size = 3,
        0x29, 0x2A, 0x2B => {
            out.scale = try reader.byte();
        },
        0x37, 0x3F, 0x6A, 0x6C => {
            out.size = try reader.byte();
            out.precision = try reader.byte();
            out.scale = try reader.byte();
        },
        0xA5, 0xAD => {
            out.size = try reader.int(u16);
        },
        0xA7, 0xAF, 0xE7, 0xEF => {
            out.size = try reader.int(u16);
            _ = try reader.take(5); // collation
        },
        0x22 => {
            out.size = try reader.int(u32);
            _ = try reader.name(arena, u16); // the table it lives in
        },
        0x23, 0x63 => {
            out.size = try reader.int(u32);
            _ = try reader.take(5); // collation
            _ = try reader.name(arena, u16);
        },
        0xF1 => {
            // XML: a byte saying whether a schema is named, and then the names.
            if (try reader.byte() != 0) {
                _ = try reader.name(arena, u8);
                _ = try reader.name(arena, u8);
                _ = try reader.name(arena, u16);
            }
            out.size = 0xFFFF; // always sent in chunks
        },
        0xF0 => {
            _ = try reader.int(u16); // max length
            _ = try reader.name(arena, u8);
            _ = try reader.name(arena, u8);
            _ = try reader.name(arena, u8);
            _ = try reader.name(arena, u16);
            out.size = 0xFFFF;
        },
        else => return error.Short,
    }
    out.name = try reader.name(arena, u8);
    return out;
}

/// The eight bytes a transaction is known by, out of an environment change
/// that carries one. A shorter value than eight is read as far as it goes,
/// because the only thing to do with a descriptor is hand it back.
fn descriptor(reader: *Reader) u64 {
    const length = reader.byte() catch return 0;
    const bytes = reader.take(length) catch return 0;
    var out: u64 = 0;
    var i: usize = @min(bytes.len, 8);
    while (i > 0) {
        i -= 1;
        out = (out << 8) | bytes[i];
    }
    return out;
}

fn fixedSize(kind: u8) u32 {
    return switch (kind) {
        0x1F => 0,
        0x32, 0x30 => 1,
        0x34 => 2,
        0x38, 0x3B, 0x3A, 0x7A => 4,
        0x7F, 0x3E, 0x3D, 0x3C => 8,
        else => 0,
    };
}


/// One cell.
///
/// A value's length is not in the value: it is in the column, in the shape of
/// the type, which is why this needs the column to read the row. Dates, money
/// and decimals come back as text - none of them is an integer and none of them
/// survives a float - and everything else keeps the shape it has.
fn value(arena: std.mem.Allocator, reader: *Reader, one: Column) !db.Value {
    // Days from the two epochs TDS counts from to the one everything else does.
    const FROM_0001: i64 = 719162;
    switch (one.kind) {
        0x1F => return .{ .null = {} },
        // Fixed length: always there, always the same size.
        0x32 => return .{ .int = (try reader.byte()) },
        0x30 => return .{ .int = (try reader.byte()) },
        0x34 => return .{ .int = try reader.int(i16) },
        0x38 => return .{ .int = try reader.int(i32) },
        0x7F => return .{ .int = try reader.int(i64) },
        0x3B => return .{ .float = @as(f32, @bitCast(try reader.int(u32))) },
        0x3E => return .{ .float = @as(f64, @bitCast(try reader.int(u64))) },
        0x3A, 0x3D => return .{ .text = try datetime(arena, try reader.take(one.size)) },
        0x7A, 0x3C => return .{ .text = try money(arena, try reader.take(one.size)) },
        // Length in a byte, and no length at all means null.
        0x26, 0x68, 0x6D, 0x6E, 0x6F, 0x24, 0x28, 0x29, 0x2A, 0x2B, 0x37, 0x3F, 0x6A, 0x6C, 0x2F, 0x27 => {
            const length = try reader.byte();
            if (length == 0) {
                return .{ .null = {} };
            }
            const bytes = try reader.take(length);
            return switch (one.kind) {
                0x26, 0x68 => .{ .int = signed(bytes) },
                0x6D => if (bytes.len == 4)
                    .{ .float = @as(f32, @bitCast(std.mem.readInt(u32, bytes[0..4], .little))) }
                else
                    .{ .float = @as(f64, @bitCast(std.mem.readInt(u64, bytes[0..8], .little))) },
                0x6E => .{ .text = try money(arena, bytes) },
                0x6F => .{ .text = try datetime(arena, bytes) },
                0x24 => .{ .text = try guid(arena, bytes) },
                0x28 => .{ .text = try dateText(arena, days(bytes) - FROM_0001) },
                0x29 => .{ .text = try timeText(arena, days(bytes), one.scale) },
                0x2A => .{ .text = try stamp(arena, bytes, one.scale, null) },
                0x2B => .{ .text = try stamp(arena, bytes[0 .. bytes.len - 2], one.scale, std.mem.readInt(i16, bytes[bytes.len - 2 ..][0..2], .little)) },
                0x37, 0x3F, 0x6A, 0x6C => .{ .text = try decimal(arena, bytes, one.scale) },
                else => .{ .text = try arena.dupe(u8, bytes) },
            };
        },
        // Length in two bytes, unless the column was declared as max - then the
        // value arrives in chunks and there is no length until the last one.
        0xA5, 0xAD, 0xA7, 0xAF, 0xE7, 0xEF, 0xF1, 0xF0 => {
            const wide = one.kind == 0xE7 or one.kind == 0xEF;
            const binary = one.kind == 0xA5 or one.kind == 0xAD or one.kind == 0xF0;
            if (one.size == 0xFFFF) {
                const bytes = (try chunks(arena, reader)) orelse return .{ .null = {} };
                if (binary) return .{ .blob = bytes };
                return .{ .text = if (wide) try fromUtf16(arena, bytes) else bytes };
            }
            const length = try reader.int(u16);
            if (length == 0xFFFF) {
                return .{ .null = {} };
            }
            const bytes = try reader.take(length);
            if (binary) return .{ .blob = try arena.dupe(u8, bytes) };
            return .{ .text = if (wide) try fromUtf16(arena, bytes) else try arena.dupe(u8, bytes) };
        },
        // The old large types, which put a pointer and a timestamp in front of
        // the bytes; an absent pointer is a null.
        0x22, 0x23, 0x63 => {
            const pointer = try reader.byte();
            if (pointer == 0) {
                return .{ .null = {} };
            }
            _ = try reader.take(pointer);
            _ = try reader.take(8); // when the row was last changed
            const length = try reader.int(u32);
            const bytes = try reader.take(length);
            return switch (one.kind) {
                0x22 => .{ .blob = try arena.dupe(u8, bytes) },
                0x63 => .{ .text = try fromUtf16(arena, bytes) },
                else => .{ .text = try arena.dupe(u8, bytes) },
            };
        },
        else => return error.Short,
    }
}

/// A value sent in pieces: a total that may be a lie, then lengths until zero.
fn chunks(arena: std.mem.Allocator, reader: *Reader) !?[]const u8 {
    const total = try reader.int(u64);
    if (total == 0xFFFFFFFFFFFFFFFF) {
        return null;
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    while (true) {
        const length = try reader.int(u32);
        if (length == 0) {
            return out.items;
        }
        try out.appendSlice(arena, try reader.take(length));
    }
}

fn signed(bytes: []const u8) i64 {
    return switch (bytes.len) {
        1 => bytes[0],
        2 => std.mem.readInt(i16, bytes[0..2], .little),
        4 => std.mem.readInt(i32, bytes[0..4], .little),
        8 => std.mem.readInt(i64, bytes[0..8], .little),
        else => 0,
    };
}

/// Money is an integer of ten-thousandths, and the two halves of it arrive the
/// wrong way round - the high four bytes first.
fn money(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const units: i64 = if (bytes.len == 4)
        std.mem.readInt(i32, bytes[0..4], .little)
    else
        (@as(i64, std.mem.readInt(i32, bytes[0..4], .little)) << 32) | std.mem.readInt(u32, bytes[4..8], .little);
    return scaled(arena, units, 4);
}

/// A decimal is a sign byte and then the digits as one long number, which is
/// why it cannot be a float: the point is where the column says it is.
fn decimal(arena: std.mem.Allocator, bytes: []const u8, scale: u8) ![]const u8 {
    if (bytes.len < 2) {
        return "";
    }
    var magnitude: u128 = 0;
    var i: usize = bytes.len;
    while (i > 1) {
        i -= 1;
        magnitude = (magnitude << 8) | bytes[i];
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    if (bytes[0] == 0 and magnitude != 0) {
        try out.append(arena, '-');
    }
    var digits: [40]u8 = undefined;
    const text = std.fmt.bufPrint(&digits, "{d}", .{magnitude}) catch "0";
    try point(arena, &out, text, scale);
    return out.items;
}

fn scaled(arena: std.mem.Allocator, units: i64, scale: u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    if (units < 0) {
        try out.append(arena, '-');
    }
    var digits: [24]u8 = undefined;
    const text = std.fmt.bufPrint(&digits, "{d}", .{@abs(units)}) catch "0";
    try point(arena, &out, text, scale);
    return out.items;
}

/// The digits with a point put `scale` places from the right, padded with the
/// zeros the number does not have.
fn point(arena: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), text: []const u8, scale: u8) !void {
    if (scale == 0) {
        try out.appendSlice(arena, text);
        return;
    }
    if (text.len <= scale) {
        try out.appendSlice(arena, "0.");
        try out.appendNTimes(arena, '0', scale - text.len);
        try out.appendSlice(arena, text);
        return;
    }
    try out.appendSlice(arena, text[0 .. text.len - scale]);
    try out.append(arena, '.');
    try out.appendSlice(arena, text[text.len - scale ..]);
}

fn guid(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    if (bytes.len != 16) {
        return "";
    }
    // The first three groups are numbers and travel little end first; the last
    // two are bytes and do not.
    return std.fmt.allocPrint(arena, "{X:0>8}-{X:0>4}-{X:0>4}-{X:0>2}{X:0>2}-{X:0>2}{X:0>2}{X:0>2}{X:0>2}{X:0>2}{X:0>2}", .{
        std.mem.readInt(u32, bytes[0..4], .little),
        std.mem.readInt(u16, bytes[4..6], .little),
        std.mem.readInt(u16, bytes[6..8], .little),
        bytes[8],  bytes[9],  bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15],
    });
}

fn days(bytes: []const u8) i64 {
    var out: i64 = 0;
    var i: usize = bytes.len;
    while (i > 0) {
        i -= 1;
        out = (out << 8) | bytes[i];
    }
    return out;
}

/// The old datetime: days from the start of 1900, and three hundredths of a
/// second since midnight. The short one counts whole minutes instead.
fn datetime(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const FROM_1900: i64 = 25567; // days from 1900-01-01 to 1970-01-01
    if (bytes.len == 4) {
        const day = std.mem.readInt(u16, bytes[0..2], .little);
        const minutes = std.mem.readInt(u16, bytes[2..4], .little);
        return std.fmt.allocPrint(arena, "{s} {d:0>2}:{d:0>2}:00", .{
            try dateText(arena, @as(i64, day) - FROM_1900),
            @as(u64, minutes / 60),
            @as(u64, minutes % 60),
        });
    }
    if (bytes.len != 8) {
        return "";
    }
    const day = std.mem.readInt(i32, bytes[0..4], .little);
    const ticks = std.mem.readInt(u32, bytes[4..8], .little);
    const millis = (@as(u64, ticks) * 10 + 1) / 3; // 1/300 of a second, rounded
    return std.fmt.allocPrint(arena, "{s} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{
        try dateText(arena, @as(i64, day) - FROM_1900),
        millis / 3_600_000,
        millis / 60_000 % 60,
        millis / 1000 % 60,
        millis % 1000,
    });
}

/// The newer time: a count of units, where the column says how small a unit is.
fn timeText(arena: std.mem.Allocator, count: i64, scale: u8) ![]const u8 {
    const divisor = tenTo(scale);
    const fraction = @mod(count, divisor);
    const units = @divFloor(count, divisor);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.print(arena, "{d:0>2}:{d:0>2}:{d:0>2}", .{
        @as(u64, @intCast(@divFloor(units, 3600))),
        @as(u64, @intCast(@mod(@divFloor(units, 60), 60))),
        @as(u64, @intCast(@mod(units, 60))),
    });
    if (scale == 0) {
        return out.items;
    }
    // The fraction is padded to as many places as the column has, which is a
    // width nobody knows until the row arrives - so it is written out.
    var digits: [24]u8 = undefined;
    const text = std.fmt.bufPrint(&digits, "{d}", .{@as(u64, @intCast(fraction))}) catch "0";
    try out.append(arena, '.');
    if (text.len < scale) {
        try out.appendNTimes(arena, '0', scale - text.len);
    }
    try out.appendSlice(arena, text);
    return out.items;
}

fn tenTo(scale: u8) i64 {
    var out: i64 = 1;
    for (0..scale) |_| {
        out *= 10;
    }
    return out;
}

/// datetime2 and datetimeoffset: the time first, then three bytes of date, and
/// for the offset a count of minutes from UTC after them.
///
/// The stored time is UTC and the offset is what to add to it, so a value
/// written as noon in Prague comes back as ten in the morning and a plus two.
/// Adding it back is the difference between showing what was written and
/// showing the same instant in a place nobody asked about - and it can cross
/// midnight, which is why the day moves with it.
fn stamp(arena: std.mem.Allocator, bytes: []const u8, scale: u8, offset: ?i16) ![]const u8 {
    if (bytes.len < 3) {
        return "";
    }
    const FROM_0001: i64 = 719162;
    const split = bytes.len - 3;
    var day = days(bytes[split..]) - FROM_0001;
    var count = days(bytes[0..split]);
    const minutes = offset orelse 0;
    if (minutes != 0) {
        const per_day = 86400 * tenTo(scale);
        count += @as(i64, minutes) * 60 * tenTo(scale);
        day += @divFloor(count, per_day);
        count = @mod(count, per_day);
    }
    const date = try dateText(arena, day);
    const time = try timeText(arena, count, scale);
    // A `datetime2` has no zone and gets none. A `datetimeoffset` gets one even
    // when it is `+00:00`, because carrying the zone is the whole difference
    // between the two types - and a column that dropped it where it happened to
    // be zero would read as the other type on some rows and not on others.
    if (offset == null) {
        return std.fmt.allocPrint(arena, "{s} {s}", .{ date, time });
    }
    const away: u16 = @intCast(@abs(minutes));
    return std.fmt.allocPrint(arena, "{s} {s} {c}{d:0>2}:{d:0>2}", .{
        date, time, @as(u8, if (minutes < 0) '-' else '+'), away / 60, away % 60,
    });
}

/// A date from a count of days either side of 1970, without a leap year rule
/// written out: the calendar repeats every four hundred years, so this counts
/// eras of that length and works the rest out inside one.
pub fn dateText(arena: std.mem.Allocator, from_epoch: i64) ![]const u8 {
    var day = from_epoch + 719468; // move the epoch to the start of an era
    const era = @divFloor(day, 146097);
    day -= era * 146097;
    const of_era = @divFloor(day - @divFloor(day, 1460) + @divFloor(day, 36524) - @divFloor(day, 146096), 365);
    const year = of_era + era * 400;
    const of_year = day - (365 * of_era + @divFloor(of_era, 4) - @divFloor(of_era, 100));
    const shifted = @divFloor(5 * of_year + 2, 153); // March is month zero
    const dayOfMonth = of_year - @divFloor(153 * shifted + 2, 5) + 1;
    const month = shifted + (if (shifted < 10) @as(i64, 3) else -9);
    return std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        @as(u64, @intCast(@max(0, year + @as(i64, if (month <= 2) 1 else 0)))),
        @as(u64, @intCast(month)),
        @as(u64, @intCast(dayOfMonth)),
    });
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

test "a packet header says how long it is, big end first" {
    const head = header(.batch, 8 + 5, true, 1);
    try testing.expectEqual(@as(u8, 0x01), head[0]);
    try testing.expectEqual(@as(u8, 0x01), head[1]);
    // 13 in two bytes, the high one first - the only big-endian thing in TDS.
    try testing.expectEqual(@as(u8, 0), head[2]);
    try testing.expectEqual(@as(u8, 13), head[3]);

    const said: Header = @bitCast(head);
    try testing.expectEqual(@as(u16, 13), said.length());
    try testing.expect(said.status & Header.LAST != 0);
}

test "the password is swapped and masked, which is all TDS does to it" {
    var scrambled: [8]u8 = undefined;
    const password = [_]u16{ 'a', 'b', 'c', 'd' };
    scramble(&scrambled, &password);
    // 'a' is 0x61: nibbles swapped is 0x16, xor 0xA5 is 0xB3.
    try testing.expectEqual(@as(u8, 0xB3), scrambled[0]);
    // The high byte of an ASCII character is zero, which comes out as 0xA5.
    try testing.expectEqual(@as(u8, 0xA5), scrambled[1]);

    // And it undoes itself, which is what makes it obfuscation rather than
    // anything to rely on.
    var back: [8]u8 = undefined;
    for (scrambled, 0..) |byte, i| {
        const undone = byte ^ 0xA5;
        back[i] = ((undone << 4) | (undone >> 4)) & 0xFF;
    }
    try testing.expectEqual(@as(u8, 'a'), back[0]);
}

// Against a real server, and only where one is offered: set `KRTEK_MSSQL` to
// `host:port:user:password` and this talks to it. Skipped otherwise, because a
// unit test that needs a server is a unit test that fails on a laptop.
test "every type this reads comes back as what was put in" {
    const said = @import("targets.zig").getenv("KRTEK_MSSQL") orelse return error.SkipZigTest;
    var parts = std.mem.splitScalar(u8, said, ':');
    const host = parts.next() orelse return error.SkipZigTest;
    const port = std.fmt.parseInt(u16, parts.next() orelse "1433", 10) catch 1433;
    const user = parts.next() orelse "sa";
    const password = parts.rest();

    var why: db.List = .empty;
    defer why.deinit(testing.allocator);
    const connection = Connection.open(testing.allocator, host, port, .{}, &why) catch {
        std.debug.print("nespojeno: {s}\n", .{why.items});
        return error.TestUnexpectedResult;
    };
    defer connection.close();

    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    _ = connection.login(arena, .{ .user = user, .password = password, .database = "master" }, &why) catch {
        std.debug.print("neprihlaseno: {s}\n", .{why.items});
        return error.TestUnexpectedResult;
    };

    // One row of every type worth reading, so that a change to the reader has
    // to keep all of them working rather than the one being looked at.
    const answer = try connection.batch(arena,
        \\select cast(1 as int) i, cast(-2 as bigint) b, cast(3 as smallint) s,
        \\  cast(4 as tinyint) t, cast(1 as bit) ano, cast(1.5 as float) f,
        \\  cast(12.34 as decimal(9,2)) d, cast(-0.5 as decimal(9,2)) zap,
        \\  cast(99.99 as money) m, cast(N'ahoj svete' as nvarchar(50)) n,
        \\  cast('ascii' as varchar(20)) v, cast(0x0102 as varbinary(10)) bin,
        \\  cast('2024-03-01' as date) dt, cast('12:34:56.789' as time(3)) tm,
        \\  cast('2024-03-01 12:34:56.789' as datetime2(3)) d2,
        \\  cast('1999-12-31 23:59:59.997' as datetime) d1,
        \\  cast('2024-03-01 00:34:56 +02:00' as datetimeoffset(0)) dz,
        \\  cast('2024-03-01 12:34:56 +00:00' as datetimeoffset(0)) dz0,
        \\  cast(null as int) nic, cast(N'dlouhy' as nvarchar(max)) mx
    , &why);
    var trouble: db.List = .empty;
    defer trouble.deinit(testing.allocator);
    const reply = try read(arena, answer, &trouble, testing.allocator);
    try testing.expectEqual(@as(usize, 1), reply.rows.len);

    const want = [_]struct { name: []const u8, text: []const u8 }{
        .{ .name = "i", .text = "1" },
        .{ .name = "b", .text = "-2" },
        .{ .name = "s", .text = "3" },
        .{ .name = "t", .text = "4" },
        .{ .name = "ano", .text = "1" },
        .{ .name = "f", .text = "1.5" },
        .{ .name = "d", .text = "12.34" },
        .{ .name = "zap", .text = "-0.50" },
        .{ .name = "m", .text = "99.9900" },
        .{ .name = "n", .text = "ahoj svete" },
        .{ .name = "v", .text = "ascii" },
        .{ .name = "dt", .text = "2024-03-01" },
        .{ .name = "tm", .text = "12:34:56.789" },
        .{ .name = "d2", .text = "2024-03-01 12:34:56.789" },
        // The old datetime keeps three hundredths of a second, so what goes in
        // as .997 is the nearest it can hold and comes back unchanged.
        .{ .name = "d1", .text = "1999-12-31 23:59:59.997" },
        // Stored as UTC with the offset beside it: the day moves back when the
        // offset is added again.
        .{ .name = "dz", .text = "2024-03-01 00:34:56 +02:00" },
        // And a zone of zero is still a zone: this is what tells the column
        // apart from a `datetime2`, which never carries one.
        .{ .name = "dz0", .text = "2024-03-01 12:34:56 +00:00" },
        .{ .name = "nic", .text = "NULL" },
        .{ .name = "mx", .text = "dlouhy" },
    };
    for (want) |one| {
        const at = for (reply.columns, 0..) |column_, i| {
            if (std.mem.eql(u8, column_.name, one.name)) break i;
        } else {
            std.debug.print("chybi sloupec {s}\n", .{one.name});
            return error.TestUnexpectedResult;
        };
        const text = switch (reply.rows[0][at]) {
            .null => "NULL",
            .int => |n| try std.fmt.allocPrint(arena, "{d}", .{n}),
            .float => |n| try std.fmt.allocPrint(arena, "{d}", .{n}),
            .text, .blob => |t| t,
        };
        testing.expectEqualStrings(one.text, text) catch |e| {
            std.debug.print("  ve sloupci {s}\n", .{one.name});
            return e;
        };
    }
    // The binary one is not text and is checked as bytes.
    for (reply.columns, 0..) |column_, i| {
        if (std.mem.eql(u8, column_.name, "bin")) {
            try testing.expectEqualSlices(u8, &.{ 1, 2 }, reply.rows[0][i].blob);
        }
    }
}

test "a login says who is asking, in the shape the server reads it" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const body = try Connection.loginBody(scratch.allocator(), .{
        .user = "sa",
        .password = "Krtek-heslo-1",
        .database = "master",
    });
    // The fixed part is 94 bytes and the strings follow it, so the whole thing
    // is that plus two bytes for every character of every field.
    try testing.expectEqual(@as(usize, 176), body.len);
    // Its own length, first thing, so the server knows where it ends.
    try testing.expectEqual(@as(u32, 176), std.mem.readInt(u32, body[0..4], .little));
    try testing.expectEqual(@as(u32, 0x74000004), std.mem.readInt(u32, body[4..8], .little));
    // fUseDB and fSetLang: change both without warning about having done so.
    try testing.expectEqual(@as(u8, 0x03), body[25]);
    try testing.expectEqual(@as(u32, 1033), std.mem.readInt(u32, body[32..36], .little));
    // The first pair, at 36, is the host: five characters starting at 94.
    try testing.expectEqual(@as(u16, 94), std.mem.readInt(u16, body[36..38], .little));
    try testing.expectEqual(@as(u16, 5), std.mem.readInt(u16, body[38..40], .little));
    // The password is at the third pair, and is masked rather than sent.
    const at = std.mem.readInt(u16, body[44..46], .little);
    try testing.expectEqual(@as(u16, 13), std.mem.readInt(u16, body[46..48], .little));
    try testing.expect(std.mem.indexOf(u8, body[at..], "K") == null);
}

test "a date is worked out from a count of days, either side of the epoch" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    try testing.expectEqualStrings("1970-01-01", try dateText(arena, 0));
    try testing.expectEqualStrings("1969-12-31", try dateText(arena, -1));
    // 2000 is a leap year and 1900 is not, which is the rule that catches out
    // every calendar written in a hurry.
    try testing.expectEqualStrings("2000-02-29", try dateText(arena, 11016));
    try testing.expectEqualStrings("1900-02-28", try dateText(arena, -25509));
    try testing.expectEqualStrings("2024-03-01", try dateText(arena, 19783));
}

test "a decimal keeps its digits, which a float would not" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    // Sign byte first, then the number as one integer, little end first.
    try testing.expectEqualStrings("12.34", try decimal(arena, &.{ 1, 0xD2, 4, 0, 0 }, 2));
    try testing.expectEqualStrings("-12.34", try decimal(arena, &.{ 0, 0xD2, 4, 0, 0 }, 2));
    // Fewer digits than places means the zeros have to be put back.
    try testing.expectEqualStrings("0.05", try decimal(arena, &.{ 1, 5, 0, 0, 0 }, 2));
    try testing.expectEqualStrings("1234", try decimal(arena, &.{ 1, 0xD2, 4, 0, 0 }, 0));
}

test "money is an integer of ten-thousandths, sent high half first" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    // 99.99 is 999900, which fits in the low half alone.
    try testing.expectEqualStrings("99.9900", try money(arena, &.{ 0, 0, 0, 0, 0xDC, 0x41, 0x0F, 0 }));
    // Minus ten thousand: the high half is all ones and comes first.
    try testing.expectEqualStrings("-1.0000", try money(arena, &.{ 0xFF, 0xFF, 0xFF, 0xFF, 0xF0, 0xD8, 0xFF, 0xFF }));
    try testing.expectEqualStrings("0.5000", try money(arena, &.{ 0x88, 0x13, 0, 0 }));
}

test "the first three groups of a guid are numbers and the last two are not" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const bytes = [_]u8{ 0x78, 0x56, 0x34, 0x12, 0x34, 0x12, 0x78, 0x56, 0x9A, 0xBC, 1, 2, 3, 4, 5, 6 };
    try testing.expectEqualStrings(
        "12345678-1234-5678-9ABC-010203040506",
        try guid(scratch.allocator(), &bytes),
    );
}

test "a character outside the basic plane arrives in two halves" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    try testing.expectEqualStrings("ahoj", try fromUtf16(arena, &.{ 'a', 0, 'h', 0, 'o', 0, 'j', 0 }));
    // U+1F400, as the pair the wire carries.
    try testing.expectEqualStrings("\u{1F400}", try fromUtf16(arena, &.{ 0x3D, 0xD8, 0x00, 0xDC }));
    // A half on its own is not a character; it becomes the replacement rather
    // than failing a query over one bad cell.
    try testing.expectEqualStrings("\u{FFFD}", try fromUtf16(arena, &.{ 0x3D, 0xD8 }));
}

test "an error token is the reason, and the ones after it are the server explaining" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var stream: std.ArrayListUnmanaged(u8) = .empty;
    for ([_][]const u8{ "spatne", "a jeste neco" }) |text| {
        const wide = try utf16(arena, text);
        try stream.append(arena, 0xAA);
        try stream.appendSlice(arena, &std.mem.toBytes(@as(u16, @intCast(14 + wide.len * 2))));
        try stream.appendSlice(arena, &std.mem.toBytes(@as(u32, 208))); // number
        try stream.append(arena, 1); // state
        try stream.append(arena, 16); // severity
        try stream.appendSlice(arena, &std.mem.toBytes(@as(u16, @intCast(text.len))));
        try stream.appendSlice(arena, std.mem.sliceAsBytes(wide));
        try stream.appendSlice(arena, &.{ 0, 0, 0, 0, 0, 0 }); // server, procedure, line
    }
    var why: db.List = .empty;
    defer why.deinit(testing.allocator);
    try testing.expectError(error.Driver, read(arena, stream.items, &why, testing.allocator));
    try testing.expectEqualStrings("spatne", why.items);
}

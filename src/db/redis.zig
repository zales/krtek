//! The Redis driver: RESP spoken directly over a socket.
//!
//! No client library. Redis's wire protocol is a handful of prefixes - `+` a
//! line, `-` an error, `:` a number, `$` a string with its length, `*` an array
//! of those - so the whole client is the hundred lines below, with no dependency
//! and no licence to think about.
//!
//! **Redis is not relational, and this driver does not pretend otherwise.** It is
//! fitted to the interface rather than the other way round: one table called
//! `data` whose columns are `key`, `type`, `ttl` and `value`, rows found
//! with `SCAN`, and the numbered databases as schemas, so `#` switches between
//! them. There is no DDL, no index beyond the key itself, and no foreign key.
//!
//! **No SQL is involved.** The interface asks with `ask.Select` and changes rows
//! with `ask.Change`, so this driver reads what it wants out of a structure -
//! which table, which key, which value - and answers with `SCAN`, `SET`,
//! `EXPIRE`, `RENAME` or `DEL`. It used to recognise the SQL the interface
//! printed, which worked and was the wrong way round; `speaks_sql = false` is
//! what replaced it.
//!
//! What the user types in the editor is still passed to Redis as a command line,
//! which is what makes it a Redis console: `KEYS user:*`, `HGETALL cart:7`,
//! `INFO memory`.
//!
//! **`rediss://` is TLS**, the spelling redis-cli has for it, and the socket is
//! `net.Stream` so that it is one branch here rather than a second reader. The
//! scheme used to be taken off and thrown away: the target said encrypted, the
//! connection was not, and the password went out in the clear to a server that
//! then hung up on it.
//!
//! **A connection that is lost is made again**, when something is next asked
//! for: the server restarted, or it was idle longer than something between here
//! and there allows. It used to stay lost. Every count came back as nothing and
//! every listing as empty, the screen said `reloaded` over a table of no rows,
//! and the only way back was to start the program again. See `exchange`.

const std = @import("std");
const clock = @import("clock.zig");
const db = @import("db.zig");
const net = @import("net.zig");
const typed = @import("typed.zig");

const List = std.ArrayList(u8);

/// How many keys one page of the grid fetches at most, so a database with
/// millions of them still answers.
const PAGE = 1000;

/// How long one read waits before asking whether to carry on, and how long it
/// waits in total before calling the server gone. The first is what makes ctrl+c
/// work while Redis is busy.
const READ_TIMEOUT_MS: i64 = 400;
const READ_PATIENCE_MS: i64 = 60 * 1000;

/// What a read says when the other end is no longer there.
const CLOSED = "redis closed the connection";

/// When making a lost connection again has failed, how long before it is tried
/// once more - counted from the failure, so that a try which waited out a host
/// that answers nothing has not used the time up by itself. One key is several
/// questions, the count for the sidebar and the one for the header and the rows,
/// and a server that is still away is no nearer for each of them finding that
/// out in turn. Short, because nothing here asks unless somebody does.
const REVIVE_EVERY_MS: f64 = 2000;

pub const Db = struct {
    allocator: std.mem.Allocator,
    /// The socket, with TLS on it when the target was `rediss://`. No descriptor
    /// in it is no connection: one that was lost, until it is made again.
    stream: net.Stream,
    /// Whether the target asked for TLS, which is asked for again with it.
    tls: bool = false,
    /// Whether the certificate was looked at, for what `settings` says about it
    /// and for looking at the next one the same way.
    verified: bool = true,
    /// What the server was told to be let in, and is told again.
    password: List = .empty,
    /// Why there is no connection, when there is none.
    lost: List = .empty,
    /// When making it again last failed. Zero when it has not.
    failed_at: f64 = 0,
    /// Everything received but not yet consumed.
    buffer: List = .empty,
    at: usize = 0,
    label: List = .empty,
    version_text: List = .empty,
    last_error: List = .empty,
    /// Where this connection points, kept so the header can be written again after
    /// the database changes.
    host: List = .empty,
    port: u16 = 6379,
    /// The database index in use, which this driver reports as the schema.
    index: u8 = 0,
    count: u8 = 16,
    progress: ?db.Progress = null,
    /// Replies live here until the next statement.
    replies: std.heap.ArenaAllocator,

    pub fn open(allocator: std.mem.Allocator, target: []const u8, report: *List) !*Db {
        const parts = try parse(allocator, target);
        defer parts.deinit(allocator);

        var stream = net.connect(allocator, parts.host, parts.port) catch {
            try report.print(allocator, "cannot reach redis at {s}:{d}", .{ parts.host, parts.port });
            return error.Driver;
        };
        // Before the handshake and not after it: a port that is not TLS says
        // nothing back to one, and without this that is a wait with no end.
        stream.setTimeout(READ_TIMEOUT_MS);
        if (parts.tls) {
            net.startTls(allocator, &stream, parts.host, .{ .verify = parts.verify }, report) catch {
                if (report.items.len == 0) {
                    try report.print(allocator, "TLS to {s}:{d} could not be set up", .{ parts.host, parts.port });
                }
                stream.close();
                return error.Driver;
            };
            // Whatever OpenSSL noted on the way here is not about what comes
            // next, and `unanswered` reads what it says as the reason.
            while (net.ssl.ERR_get_error() != 0) {}
        }

        const self = allocator.create(Db) catch |err| {
            stream.close();
            return err;
        };
        self.* = .{
            .allocator = allocator,
            .stream = stream,
            .tls = parts.tls,
            .verified = parts.verify,
            .port = parts.port,
            .index = parts.index,
            .replies = std.heap.ArenaAllocator.init(allocator),
        };
        errdefer self.close();
        // All that a connection is made of, before anything is asked on this
        // one: whatever is asked may find it gone and have to make another.
        try self.host.appendSlice(allocator, parts.host);
        try self.password.appendSlice(allocator, parts.password);

        // The first two things are said once and on this connection only. One
        // that goes away under them is a server that will not have this client,
        // and making another to be turned away the same is not an answer.
        db.tell("waiting for {s} to answer", .{parts.host});
        if (parts.password.len != 0) {
            const reply = self.first(&[_][]const u8{ "AUTH", parts.password }) catch {
                try self.unanswered(report, parts);
                return error.Driver;
            };
            if (reply == .failure) {
                try report.appendSlice(allocator, reply.failure);
                return error.Driver;
            }
        }
        // PING first: a wrong password or a protected server says so here rather
        // than halfway through the first screen.
        const ping = self.first(&[_][]const u8{"PING"}) catch {
            try self.unanswered(report, parts);
            return error.Driver;
        };
        if (ping == .failure) {
            try report.appendSlice(allocator, ping.failure);
            return error.Driver;
        }
        if (parts.index != 0) {
            try self.useIndex(parts.index);
        }
        self.count = self.databaseCount();
        self.relabel();
        try self.version_text.print(allocator, "Redis {s}", .{self.fact("redis_version") orelse "?"});
        return self;
    }

    /// Why the first thing said got no answer. A server that only takes TLS hangs
    /// up on one that does not speak it, which from this end is a connection
    /// closed and nothing else - so the one thing worth trying is said with it.
    ///
    /// Through TLS the server can say why before it goes, and the one that does
    /// is the one most likely to be met: Redis wants a certificate from the
    /// client unless it is told not to, lets the handshake finish without one,
    /// and then refuses with an alert. That alert is the whole of the reason.
    fn unanswered(self: *Db, report: *List, parts: Parts) !void {
        try report.appendSlice(self.allocator, self.message());
        if (!std.mem.eql(u8, self.message(), CLOSED)) {
            return;
        }
        if (!parts.tls) {
            try report.appendSlice(self.allocator, " - if it wants TLS, that is rediss://");
            return;
        }
        var buffer: [256]u8 = undefined;
        const said = net.ssl.lastError(&buffer);
        if (said.len != 0) {
            try report.print(self.allocator, ": {s}", .{said});
        }
    }

    /// `host:port/index`, as the header shows it.
    fn relabel(self: *Db) void {
        self.label.clearRetainingCapacity();
        self.label.print(self.allocator, "{s}:{d}/{d}", .{ self.host.items, self.port, self.index }) catch {};
    }

    pub fn close(self: *Db) void {
        if (self.stream.fd >= 0) {
            self.stream.close();
        }
        self.host.deinit(self.allocator);
        self.password.deinit(self.allocator);
        self.lost.deinit(self.allocator);
        self.buffer.deinit(self.allocator);
        self.label.deinit(self.allocator);
        self.version_text.deinit(self.allocator);
        self.last_error.deinit(self.allocator);
        self.replies.deinit();
        self.allocator.destroy(self);
    }

    pub fn watch(self: *Db, progress: ?db.Progress) void {
        self.progress = progress;
    }

    fn starting(self: *Db) void {
        if (self.progress) |progress| {
            progress.starting();
        }
    }

    pub fn caps(_: *Db) db.Caps {
        return .{
            // The numbered databases, which is the only namespace Redis has.
            .schemas = true,
            .hidden_row_id = false,
            .rebuild_to_alter = false,
            .databases = true,
            .label = "Redis",
            // The numbered database is what `#` switches, and what a row is here
            // is a key - the screen said "schema" and "row", which are the words
            // for something else.
            .schema_noun = "database",
            .row_noun = "key",
            .text_cast = "TEXT",
            // Redis is asked with a structure; only the console takes a command.
            .speaks_sql = false,
            .no_ddl = "Redis has one table and it holds every key - there is nothing here to create, alter or drop",
        };
    }

    pub fn version(self: *Db) []const u8 {
        return self.version_text.items;
    }

    pub fn describe(self: *Db) []const u8 {
        return self.label.items;
    }

    pub fn message(self: *Db) []const u8 {
        return self.last_error.items;
    }

    fn remember(self: *Db, text: []const u8) void {
        self.last_error.clearRetainingCapacity();
        self.last_error.appendSlice(self.allocator, text) catch {};
    }

    fn complain(self: *Db, comptime fmt: []const u8, args: anytype) void {
        self.last_error.clearRetainingCapacity();
        self.last_error.print(self.allocator, fmt, args) catch {};
    }

    // ------------------------------------------------------------------ RESP

    /// What can go wrong on the way to a reply: what the interface is told, and
    /// the connection being gone, which is the one there is something to do about.
    const Failure = db.Error || error{Gone};

    /// Whether what is asked is asked a second time when the connection goes
    /// away under it.
    const Asking = enum { again, once };

    /// Send one command and read its reply. The reply is owned by `replies` and
    /// lives until the next statement clears it.
    ///
    /// For nearly everything this driver asks on its own account, which leaves
    /// the same behind asked twice as asked once: it reads, it sets a key or
    /// how long one lives, it deletes one. So it is asked again on a new
    /// connection when the one it was asked on goes.
    fn command(self: *Db, args: []const []const u8) db.Error!Value {
        return self.single(args, .again);
    }

    /// The same for what is not the same done twice, which is sent once: a line
    /// somebody typed, which may be an `INCR` or an `RPUSH`, and a rename,
    /// which the second time finds nothing to rename. A connection that goes
    /// before the answer comes does not say whether the server got as far as
    /// doing it.
    fn commandOnce(self: *Db, args: []const []const u8) db.Error!Value {
        return self.single(args, .once);
    }

    fn single(self: *Db, args: []const []const u8, asking: Asking) db.Error!Value {
        var out: List = .empty;
        defer out.deinit(self.allocator);
        append(&out, self.allocator, args) catch return error.OutOfMemory;
        var reply: [1]Value = undefined;
        try self.exchange(self.replies.allocator(), out.items, &reply, asking);
        return reply[0];
    }

    /// One command on the connection as it stands, with nothing done about a
    /// connection that is not there: for the first things said on one, by
    /// whoever is making it.
    fn first(self: *Db, args: []const []const u8) Failure!Value {
        var out: List = .empty;
        defer out.deinit(self.allocator);
        append(&out, self.allocator, args) catch return error.OutOfMemory;
        var reply: [1]Value = undefined;
        try self.converse(self.replies.allocator(), out.items, &reply);
        return reply[0];
    }

    /// One command, in the shape the wire wants it.
    fn append(out: *List, allocator: std.mem.Allocator, args: []const []const u8) !void {
        try out.print(allocator, "*{d}\r\n", .{args.len});
        for (args) |arg| {
            try out.print(allocator, "${d}\r\n", .{arg.len});
            try out.appendSlice(allocator, arg);
            try out.appendSlice(allocator, "\r\n");
        }
    }

    /// Several commands in one go, and their answers in the order they were
    /// asked. This is the whole of what makes a remote server usable: a screen of
    /// a hundred keys is four hundred commands, and asked one at a time on a link
    /// with twenty-five milliseconds of latency that is half a minute of waiting.
    /// Sent together it is one wait.
    ///
    /// Redis answers a pipeline in order and keeps no state between the commands,
    /// so this is nothing more than writing them all and reading that many
    /// replies back.
    fn pipeline(self: *Db, arena: std.mem.Allocator, commands: []const []const []const u8) db.Error![]Value {
        if (commands.len == 0) {
            return &[_]Value{};
        }
        var out: List = .empty;
        defer out.deinit(self.allocator);
        for (commands) |args| {
            append(&out, self.allocator, args) catch return error.OutOfMemory;
        }
        const replies = try arena.alloc(Value, commands.len);
        // What is asked in bulk is what a page of keys is and holds: all reads.
        try self.exchange(arena, out.items, replies, .again);
        return replies;
    }

    /// Ask, and be answered, on a connection that is there.
    ///
    /// A server that restarts, or anything on the way that drops a connection
    /// nobody has used for a while, leaves this end holding a socket with nobody
    /// on the other end of it. That used to be the end of the session: every
    /// request after it failed, most of them into a count of nothing or an empty
    /// list, and nothing ever dialled again.
    ///
    /// So the connection is looked at before anything is written, which is where
    /// nearly every lost one is found - the server said it was going, and nothing
    /// here was listening - and made again there, before the request can be in
    /// doubt. One that goes later, between the question and the answer, is made
    /// again as well, and the question asked once more: once, and not where
    /// twice is not the same as once, because whether it was carried out before
    /// the connection went is something this end cannot know.
    fn exchange(self: *Db, arena: std.mem.Allocator, bytes: []const u8, into: []Value, asking: Asking) db.Error!void {
        // Asked before anything is sent, which is where giving up costs
        // nothing: no answer is owed yet, and the connection is as it was.
        if (self.progress) |progress| {
            if (!progress.call()) {
                self.remember("given up on");
                return error.Driver;
            }
        }
        try self.ready();
        self.attempt(arena, bytes, into) catch |err| switch (err) {
            error.Gone => {
                if (asking == .once) {
                    self.complain("{s}, and the command is not sent a second time: it may have been carried out", .{self.lost.items});
                    return error.Driver;
                }
                try self.revive();
                return self.attempt(arena, bytes, into) catch |again| switch (again) {
                    error.Gone => error.Driver,
                    else => |other| other,
                };
            },
            else => |other| return other,
        };
    }

    /// A connection to ask on, or the reason there is none.
    fn ready(self: *Db) db.Error!void {
        if (self.stream.fd >= 0) {
            if (!self.hungUp()) {
                return;
            }
            self.drop(CLOSED);
        }
        return self.revive();
    }

    /// Whether the server hung up while nothing was being asked. An end is
    /// something to read, so a connection that has one waiting on it is readable
    /// and one that is only idle is not: asking costs one call that does not
    /// wait, and reading - which is what tells an end from anything else, and
    /// through TLS from the server's saying goodbye - is only done where there
    /// is something there.
    fn hungUp(self: *Db) bool {
        var fds = [1]std.c.pollfd{.{ .fd = self.stream.fd, .events = std.c.POLL.IN, .revents = 0 }};
        if (std.c.poll(&fds, 1, 0) <= 0) {
            return false;
        }
        var chunk: [4096]u8 = undefined;
        const got = self.stream.readNow(&chunk) catch return true;
        // Bytes nobody asked for. Not this function's to make sense of: they are
        // where the next read looks first, as they were before this looked.
        self.buffer.appendSlice(self.allocator, chunk[0..got]) catch return true;
        return false;
    }

    /// One try at it.
    ///
    /// Whatever goes wrong once something has been written leaves a connection
    /// that is out of step: a reply still on its way, which nobody is going to
    /// read, would be taken for the answer to whatever is asked next, and so
    /// would every one after it. That is what giving up on a command did - the
    /// answer it did not wait for was read as the next command's. So such a
    /// connection is let go of, and what is asked next gets a new one.
    fn attempt(self: *Db, arena: std.mem.Allocator, bytes: []const u8, into: []Value) Failure!void {
        self.converse(arena, bytes, into) catch |err| {
            self.drop(self.last_error.items);
            return err;
        };
    }

    /// Write what is asked and read as many replies as it has commands.
    fn converse(self: *Db, arena: std.mem.Allocator, bytes: []const u8, into: []Value) Failure!void {
        try self.writeAll(bytes);
        for (into) |*reply| {
            reply.* = try self.read(arena);
        }
    }

    /// Let go of a connection that is no use any more, and keep why.
    fn drop(self: *Db, why: []const u8) void {
        if (self.stream.fd >= 0) {
            self.stream.close();
        }
        self.buffer.clearRetainingCapacity();
        self.at = 0;
        self.lost.clearRetainingCapacity();
        self.lost.appendSlice(self.allocator, if (why.len != 0) why else CLOSED) catch {};
    }

    /// Make the connection again, or say why not.
    fn revive(self: *Db) db.Error!void {
        if (self.failed_at != 0 and clock.steadyMs() - self.failed_at < REVIVE_EVERY_MS) {
            // Said again and not tried again: `lost` is what the last try said.
            self.remember(self.lost.items);
            return error.Driver;
        }
        self.dial() catch |err| {
            self.failed_at = clock.steadyMs();
            self.lost.clearRetainingCapacity();
            self.lost.appendSlice(self.allocator, self.last_error.items) catch {};
            return err;
        };
        self.failed_at = 0;
        self.lost.clearRetainingCapacity();
        // What the old connection said on its way out is not about this one.
        self.last_error.clearRetainingCapacity();
    }

    /// A new connection, put back the way the old one was: at the name the
    /// target gave, which is looked up again because a server that came back may
    /// have come back somewhere else; through TLS where the target asked for it,
    /// checking what was checked the first time; let in with the same password;
    /// and in the database that was in use, which a new connection is not.
    fn dial(self: *Db) db.Error!void {
        var stream = net.connect(self.allocator, self.host.items, self.port) catch {
            self.complain("the connection to redis at {s}:{d} was lost, and it cannot be reached again", .{ self.host.items, self.port });
            return error.Driver;
        };
        stream.setTimeout(READ_TIMEOUT_MS);
        if (self.tls) {
            var why: List = .empty;
            defer why.deinit(self.allocator);
            net.startTls(self.allocator, &stream, self.host.items, .{ .verify = self.verified }, &why) catch {
                self.complain("the connection to redis at {s}:{d} was lost, and TLS could not be set up again{s}{s}", .{
                    self.host.items,                      self.port,
                    if (why.items.len != 0) ": " else "", why.items,
                });
                stream.close();
                return error.Driver;
            };
            while (net.ssl.ERR_get_error() != 0) {}
        }
        self.stream = stream;
        self.buffer.clearRetainingCapacity();
        self.at = 0;
        self.greet() catch |err| {
            self.stream.close();
            switch (err) {
                error.Gone => {
                    self.complain("the connection to redis at {s}:{d} was lost, and the server hangs up on a new one", .{ self.host.items, self.port });
                    return error.Driver;
                },
                else => |other| return other,
            }
        };
    }

    /// What a new connection is told before it stands in for the old one. A
    /// server that has changed its mind since - another password, fewer
    /// databases - says so here, and that is the reason given: carrying on in
    /// database 0 because 3 would not open is how a key gets written to the
    /// wrong place.
    fn greet(self: *Db) Failure!void {
        if (self.password.items.len != 0) {
            const reply = try self.first(&[_][]const u8{ "AUTH", self.password.items });
            if (reply == .failure) {
                self.complain("the connection to redis at {s}:{d} was lost, and the password is not taken again: {s}", .{
                    self.host.items, self.port, reply.failure,
                });
                return error.Driver;
            }
        }
        if (self.index != 0) {
            var buf: [8]u8 = undefined;
            const reply = try self.first(&[_][]const u8{
                "SELECT", std.mem.print(&buf, "{d}", .{self.index}) catch "0",
            });
            if (reply == .failure) {
                self.complain("the connection to redis at {s}:{d} was lost, and database {d} does not open again: {s}", .{
                    self.host.items, self.port, self.index, reply.failure,
                });
                return error.Driver;
            }
        }
    }

    fn writeAll(self: *Db, bytes: []const u8) Failure!void {
        self.stream.write(bytes) catch {
            self.remember("the connection to redis is gone");
            return error.Gone;
        };
    }

    /// One reply, reading more from the socket whenever the buffer runs out.
    fn read(self: *Db, arena: std.mem.Allocator) Failure!Value {
        // Asked here rather than only where a read stalls. A hundred replies that
        // each arrive in twenty milliseconds never stall once, so nothing was ever
        // asked and nothing was ever drawn - the screen sat still for half a minute
        // with no spinner and no way to stop it. What makes an operation long is
        // how many replies it waits for, not how long any one of them took.
        //
        // Asked for the drawing, and the answer left alone: the place to give up
        // is before a question is sent or while its answer is not coming, and
        // between two replies that are arriving is neither.
        if (self.progress) |progress| {
            _ = progress.call();
        }
        while (true) {
            // Where this reply begins. A parse that runs out of bytes has already
            // walked the cursor past everything it did manage to read, so the next
            // attempt has to be put back to the start - otherwise it resumes in the
            // middle of a key and reads a letter of it as a type byte.
            //
            // Only a reply that arrives in more than one piece can do this, which
            // is why it never happened on localhost: there the whole answer is in
            // the first recv. Over a network a SCAN of a hundred keys is several
            // kilobytes and several packets, and the first one to arrive split took
            // the connection out for good - every command after it read from an
            // offset that meant nothing.
            const start = self.at;
            if (self.parseValue(arena)) |value| {
                // Everything before the cursor has been consumed; drop it so a long
                // session does not grow the buffer forever.
                if (self.at != 0) {
                    self.buffer.replaceRangeAssumeCapacity(0, self.at, "");
                    self.at = 0;
                }
                return value;
            } else |err| switch (err) {
                error.Incomplete => {
                    self.at = start;
                    try self.fill();
                },
                error.OutOfMemory => return error.OutOfMemory,
                error.Malformed => {
                    self.remember("redis answered with something that is not a reply");
                    return error.Driver;
                },
            }
        }
    }

    /// More bytes from the socket. The socket has a short receive timeout, so a
    /// reply that is slow to arrive gets to ask whether the user is still waiting -
    /// without it, a server that stopped answering held the whole program and
    /// ctrl+c could do nothing about it.
    fn fill(self: *Db) Failure!void {
        var chunk: [16 * 1024]u8 = undefined;
        var waiting: i64 = 0;
        while (true) {
            // Nothing is the timeout running out, which is not a failure; an end
            // or a broken connection is an error, in the clear or through TLS.
            const got = self.stream.readNow(&chunk) catch {
                self.remember(CLOSED);
                return error.Gone;
            };
            if (got != 0) {
                try self.buffer.appendSlice(self.allocator, chunk[0..got]);
                return;
            }
            if (self.progress) |progress| {
                if (!progress.call()) {
                    self.remember("given up on");
                    return error.Driver;
                }
            }
            waiting += READ_TIMEOUT_MS;
            if (waiting >= READ_PATIENCE_MS) {
                self.remember("redis stopped answering");
                return error.Driver;
            }
        }
    }

    const ParseError = error{ Incomplete, Malformed, OutOfMemory };

    fn parseValue(self: *Db, arena: std.mem.Allocator) ParseError!Value {
        const head = try self.line();
        if (head.len == 0) {
            return error.Malformed;
        }
        const body = head[1..];
        switch (head[0]) {
            '+' => return .{ .text = try arena.dupe(u8, body) },
            '-' => return .{ .failure = try arena.dupe(u8, body) },
            ':' => return .{ .number = std.fmt.parseInt(i64, body, 10) catch 0 },
            // RESP3 adds a few of its own; treated as what they resemble.
            ',' => return .{ .text = try arena.dupe(u8, body) },
            '#' => return .{ .text = try arena.dupe(u8, body) },
            '_' => return .{ .nil = {} },
            '$', '=' => {
                const length = std.fmt.parseInt(i64, body, 10) catch return error.Malformed;
                if (length < 0) {
                    return .{ .nil = {} };
                }
                const wanted: usize = @intCast(length);
                if (self.buffer.items.len < self.at + wanted + 2) {
                    return error.Incomplete;
                }
                const bytes = self.buffer.items[self.at .. self.at + wanted];
                self.at += wanted + 2;
                return .{ .text = try arena.dupe(u8, bytes) };
            },
            '*', '~', '>' => {
                const length = std.fmt.parseInt(i64, body, 10) catch return error.Malformed;
                if (length < 0) {
                    return .{ .nil = {} };
                }
                var items: std.ArrayList(Value) = .empty;
                var left: usize = @intCast(@max(0, length));
                while (left > 0) : (left -= 1) {
                    try items.append(arena, try self.parseValue(arena));
                }
                return .{ .list = items.items };
            },
            '%' => {
                // A map: read twice as many values and keep them flat.
                const pairs = std.fmt.parseInt(i64, body, 10) catch return error.Malformed;
                var items: std.ArrayList(Value) = .empty;
                var left: usize = @as(usize, @intCast(@max(0, pairs))) * 2;
                while (left > 0) : (left -= 1) {
                    try items.append(arena, try self.parseValue(arena));
                }
                return .{ .list = items.items };
            },
            else => return error.Malformed,
        }
    }

    /// The next CRLF terminated line, leaving the cursor after it.
    fn line(self: *Db) ParseError![]const u8 {
        const end = std.mem.findPos(u8, self.buffer.items, self.at, "\r\n") orelse return error.Incomplete;
        const text = self.buffer.items[self.at..end];
        self.at = end + 2;
        return text;
    }

    // --------------------------------------------------------- the interface

    pub fn exec(self: *Db, sql: []const u8) db.Error!void {
        var rows = (try self.query(sql, null)) orelse return;
        rows.close();
    }

    /// A Redis command line, as typed in the editor.
    pub fn query(self: *Db, sql: []const u8, rest: ?*[]const u8) db.Error!?db.Rows {
        if (rest) |out| {
            out.* = sql[sql.len..];
        }
        const trimmed = std.mem.trim(u8, sql, " \t\r\n;");
        if (trimmed.len == 0) {
            return null;
        }
        self.begin();
        return .{ .redis = try self.console(trimmed) };
    }

    /// Rows for a request from the interface. There is one table and its rows are
    /// keys, so a request is a `SCAN` with the pattern the filter on the key
    /// implies - an equality is that key, a LIKE is the same pattern with Redis's
    /// wildcards, and no filter at all is everything.
    pub fn select(self: *Db, request: db.ask.Select) db.Error!?db.Rows {
        self.begin();
        if (!std.mem.eql(u8, request.table.name, TABLE)) {
            self.remember("redis has one table, called data");
            return error.Driver;
        }
        if (request.where_text.len != 0) {
            self.remember("a raw WHERE is SQL - filter the key with = or LIKE, or use KEYS in the console");
            return error.Driver;
        }
        const pattern = try self.match(request.where);
        if (request.count) {
            // Without a pattern Redis knows the answer; with one it has to be counted,
            // and one page of keys is as far as that goes.
            if (pattern.len == 1 and pattern[0] == '*') {
                return .{ .redis = try self.oneNumber("keys", self.dbSize() orelse 0) };
            }
            var rows = try self.scan(pattern, 0, PAGE);
            const found: i64 = @intCast(rows.rows.items.len);
            rows.close();
            return .{ .redis = try self.oneNumber("keys", found) };
        }
        return .{ .redis = try self.scan(pattern, request.offset, if (request.limit != 0) request.limit else PAGE) };
    }

    /// Insert, update or delete one key.
    pub fn apply(self: *Db, change: db.ask.Change) db.Error!void {
        self.begin();
        if (!std.mem.eql(u8, change.table.name, TABLE)) {
            self.remember("redis has one table, called data");
            return error.Driver;
        }
        const named = db.ask.only(change.where, KEY);
        switch (change.kind) {
            .delete => {
                const key = named orelse {
                    self.remember("which key? redis addresses a row by its key");
                    return error.Driver;
                };
                _ = try self.deleteKey(key);
            },
            .insert => {
                const key = flat(db.ask.valueOf(change.cells, KEY)) orelse "";
                if (key.len == 0) {
                    self.remember("a redis row needs a key");
                    return error.Driver;
                }
                _ = try self.setValue(.{
                    .key = key,
                    .value = flat(db.ask.valueOf(change.cells, VALUE)) orelse "",
                    .ttl = flat(db.ask.valueOf(change.cells, TTL)),
                });
            },
            .update => {
                const key = named orelse {
                    self.remember("which key? redis addresses a row by its key");
                    return error.Driver;
                };
                // The columns that were set decide the command, and a row form sets
                // all of them at once: the value first, then the ttl, and a changed
                // key last because it moves what the others were about.
                var did_something = false;
                if (flat(db.ask.valueOf(change.cells, VALUE))) |value| {
                    _ = try self.setValue(.{ .key = key, .value = value });
                    did_something = true;
                }
                if (flat(db.ask.valueOf(change.cells, TTL))) |ttl| {
                    _ = try self.setTtl(.{ .key = key, .value = ttl });
                    did_something = true;
                }
                if (flat(db.ask.valueOf(change.cells, KEY))) |renamed| {
                    if (!std.mem.eql(u8, renamed, key)) {
                        _ = try self.rename(key, renamed);
                        did_something = true;
                    }
                }
                if (!did_something) {
                    self.remember("nothing to change: a redis row is its value, its ttl and its key");
                    return error.Driver;
                }
            },
        }
    }

    /// What a request comes to as a command line, for the history and the report.
    pub fn wording(self: *Db, allocator: std.mem.Allocator, request: db.Request) db.Error![]u8 {
        var out: List = .empty;
        errdefer out.deinit(allocator);
        switch (request) {
            .select => |value| {
                const pattern = try self.match(value.where);
                if (value.count) {
                    try out.appendSlice(allocator, "DBSIZE");
                } else {
                    try out.print(allocator, "SCAN 0 MATCH {s} COUNT {d}", .{ pattern, PAGE });
                }
            },
            .change => |value| {
                const key = db.ask.only(value.where, KEY) orelse
                    flat(db.ask.valueOf(value.cells, KEY)) orelse "?";
                switch (value.kind) {
                    .delete => try out.print(allocator, "DEL {s}", .{key}),
                    .insert, .update => {
                        // A value this driver shows for anything but a string is a
                        // flattening of it - the elements of a list, the fields of a hash -
                        // and SET would put that text where the structure was. Better to
                        // say so than to write a command that quietly destroys it.
                        const kind = flat(db.ask.valueOf(value.cells, TYPE));
                        if (kind != null and !std.mem.eql(u8, kind.?, "string")) {
                            try out.print(allocator, "-- {s} is a {s}; krtek shows its value as text and cannot put one back", .{ key, kind.? });
                            return out.toOwnedSlice(allocator);
                        }
                        if (flat(db.ask.valueOf(value.cells, VALUE))) |text| {
                            try out.print(allocator, "SET {s} {s}", .{ key, text });
                        }
                        if (flat(db.ask.valueOf(value.cells, TTL))) |ttl| {
                            // A newline, not a semicolon: a value may contain one of those,
                            // so the splitter cuts on lines alone - and two commands on one
                            // line reached Redis as a single command with five arguments,
                            // which is how a dump came back refusing every row of itself.
                            if (out.items.len != 0) {
                                try out.append(allocator, '\n');
                            }
                            // A ttl of -1 in the grid means "no expiry", and EXPIRE with -1
                            // deletes the key - which is what this used to write for every
                            // row of a dump.
                            const seconds = std.fmt.parseInt(i64, ttl, 10) catch -1;
                            if (seconds < 0) {
                                try out.print(allocator, "PERSIST {s}", .{key});
                            } else {
                                try out.print(allocator, "EXPIRE {s} {d}", .{ key, seconds });
                            }
                        }
                        if (out.items.len == 0) {
                            try out.print(allocator, "SET {s} ''", .{key});
                        }
                    },
                }
            },
        }
        return out.toOwnedSlice(allocator);
    }

    fn match(self: *Db, where: []const db.ask.Filter) db.Error![]const u8 {
        return matchOf(self.replies.allocator(), where);
    }

    /// A key renamed, which is what changing the key of a row means.
    fn rename(self: *Db, from: []const u8, to: []const u8) db.Error!void {
        const reply = try self.commandOnce(&[_][]const u8{ "RENAME", from, to });
        if (reply == .failure) {
            self.remember(reply.failure);
            return error.Driver;
        }
    }

    /// A statement is starting: the spinner is told, and the last reply is let go.
    fn begin(self: *Db) void {
        self.starting();
        self.last_error.clearRetainingCapacity();
        _ = self.replies.reset(.retain_capacity);
    }

    /// A command typed in the editor, with its reply laid out as rows.
    fn console(self: *Db, text: []const u8) db.Error!Rows {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const args = try typed.split(arena.allocator(), text);
        if (args.len == 0) {
            return self.oneText("reply", "");
        }
        // SELECT would move the connection out from under the interface, which
        // asks for its objects by schema and would switch it straight back. `#` is
        // the way to change database, and it goes through the same command.
        if (std.ascii.eqlIgnoreCase(args[0], "SELECT")) {
            return self.oneText("reply", "use # to switch database, so the interface follows");
        }
        const reply = try self.commandOnce(args);
        if (reply == .failure) {
            self.remember(reply.failure);
            return error.Driver;
        }
        var rows = Rows{ .owner = self, .table = TABLE, .names = &[_][]const u8{"reply"} };
        switch (reply) {
            .list => |maybe| {
                // A flat reply is one row per element; guessing more structure than
                // that would be worse than showing it as it came.
                for (maybe orelse &[_]Value{}) |item| {
                    try rows.add(&[_]Value{item});
                }
            },
            else => try rows.add(&[_]Value{reply}),
        }
        return rows;
    }

    fn oneText(self: *Db, name: []const u8, text: []const u8) db.Error!Rows {
        var rows = Rows{ .owner = self, .table = TABLE, .names = &[_][]const u8{name} };
        try rows.add(&[_]Value{.{ .text = try self.replies.allocator().dupe(u8, text) }});
        return rows;
    }

    fn oneNumber(self: *Db, name: []const u8, number: i64) db.Error!Rows {
        var rows = Rows{ .owner = self, .table = TABLE, .names = &[_][]const u8{name} };
        try rows.add(&[_]Value{.{ .number = number }});
        return rows;
    }

    /// The rows of the pseudo table: key, type, ttl and value.
    /// The keys a pattern matches, from `skip` onwards and at most `take` of them.
    ///
    /// SCAN has no way to start part way in, so a later page is reached by walking
    /// past the earlier ones - which is what the grid's page numbers mean, and the
    /// price a keyspace with no index charges for them. Before this, `skip` and
    /// `take` were ignored altogether and every page showed the same keys.
    fn scan(self: *Db, pattern: []const u8, skip: usize, take: usize) db.Error!Rows {
        const arena = self.replies.allocator();
        var rows = Rows{ .owner = self, .table = TABLE, .names = &[_][]const u8{ "key", "type", "ttl", "value" } };
        var cursor: []const u8 = "0";
        var found: usize = 0;
        var passed: usize = 0;
        const ceiling = @min(take, PAGE);
        while (found < ceiling) {
            var buf: [32]u8 = undefined;
            const reply = try self.command(&[_][]const u8{
                "SCAN",  cursor,
                "MATCH", if (pattern.len != 0) pattern else "*",
                "COUNT", std.mem.print(&buf, "{d}", .{PAGE}) catch "100",
            });
            if (reply == .failure) {
                self.remember(reply.failure);
                return error.Driver;
            }
            const pair = listOf(reply) orelse break;
            if (pair.len < 2) {
                break;
            }
            cursor = textOf(pair[0]) orelse "0";
            const keys = listOf(pair[1]) orelse &[_]Value{};

            // Which of this page's keys are going to be shown. Only those are
            // asked about: the rest of the page is skipped without a word to the
            // server.
            var wanted: std.ArrayList([]const u8) = .empty;
            for (keys) |item| {
                const key = textOf(item) orelse continue;
                if (passed < skip) {
                    passed += 1;
                    continue;
                }
                if (found + wanted.items.len >= ceiling) {
                    break;
                }
                try wanted.append(arena, key);
            }
            if (wanted.items.len != 0) {
                // The type and the age of every one of them, in one exchange. Asked
                // key by key this was two round trips each, and a screen of a hundred
                // keys on a link with any latency at all took half a minute.
                var asking: std.ArrayList([]const []const u8) = .empty;
                for (wanted.items) |key| {
                    try asking.append(arena, try arena.dupe([]const u8, &[_][]const u8{ "TYPE", key }));
                    try asking.append(arena, try arena.dupe([]const u8, &[_][]const u8{ "TTL", key }));
                }
                const said = try self.pipeline(arena, asking.items);
                const kinds = try arena.alloc([]const u8, wanted.items.len);
                const ages = try arena.alloc(i64, wanted.items.len);
                for (wanted.items, 0..) |_, i| {
                    kinds[i] = textOf(said[i * 2]) orelse "?";
                    ages[i] = switch (said[i * 2 + 1]) {
                        .number => |value| value,
                        else => -1,
                    };
                }
                // And then what each one holds, which needs the types to know what to
                // ask - so it is a second exchange rather than part of the first.
                const values = try self.previews(arena, wanted.items, kinds);
                for (wanted.items, 0..) |key, i| {
                    try rows.add(&[_]Value{
                        .{ .text = try arena.dupe(u8, key) },
                        .{ .text = try arena.dupe(u8, kinds[i]) },
                        .{ .number = ages[i] },
                        .{ .text = values[i] },
                    });
                    found += 1;
                }
            }
            // Asked between pages, because a big keyspace takes many of them.
            if (self.progress) |progress| {
                if (!progress.call()) {
                    break;
                }
            }
            if (std.mem.eql(u8, cursor, "0")) {
                break;
            }
        }
        return rows;
    }

    /// What to ask for a key of this type. A preview is one grid cell, so a long
    /// collection is cut off at the server rather than fetched and thrown away.
    fn valueCommand(arena: std.mem.Allocator, key: []const u8, kind: []const u8) ![]const []const u8 {
        var buf: [16]u8 = undefined;
        const stop = try arena.dupe(u8, std.mem.print(&buf, "{d}", .{PREVIEW - 1}) catch "49");
        if (std.mem.eql(u8, kind, "string")) {
            return arena.dupe([]const u8, &[_][]const u8{ "GET", key });
        }
        if (std.mem.eql(u8, kind, "list")) {
            return arena.dupe([]const u8, &[_][]const u8{ "LRANGE", key, "0", stop });
        }
        if (std.mem.eql(u8, kind, "set")) {
            return arena.dupe([]const u8, &[_][]const u8{ "SMEMBERS", key });
        }
        if (std.mem.eql(u8, kind, "zset")) {
            return arena.dupe([]const u8, &[_][]const u8{ "ZRANGE", key, "0", stop });
        }
        if (std.mem.eql(u8, kind, "hash")) {
            return arena.dupe([]const u8, &[_][]const u8{ "HGETALL", key });
        }
        // A type nothing here reads - a stream, a module's own - is shown as
        // nothing rather than asked about in a way that might not answer.
        return arena.dupe([]const u8, &[_][]const u8{ "TYPE", key });
    }

    /// What a key holds, in the shape its type allows: a string as it is, a
    /// collection as its elements, and a hash as `field=value` pairs.
    fn renderValue(arena: std.mem.Allocator, kind: []const u8, reply: Value) db.Error![]const u8 {
        if (!known(kind)) {
            return "";
        }
        switch (reply) {
            .text => |text| return text orelse "",
            .number => |number| return arena.print("{d}", .{number}) catch "",
            .nil => return "",
            .failure => |text| return text,
            .list => |maybe| {
                const items = maybe orelse &[_]Value{};
                var out: List = .empty;
                const pairs = std.mem.eql(u8, kind, "hash");
                for (items, 0..) |item, i| {
                    if (i != 0) {
                        try out.appendSlice(arena, if (pairs and i % 2 == 1) "=" else ", ");
                    }
                    try out.appendSlice(arena, switch (item) {
                        .text => |text| text orelse "",
                        .number => |number| try arena.print("{d}", .{number}),
                        .nil => "",
                        .failure => |text| text,
                        // One level is what a cell has room for.
                        .list => "…",
                    });
                }
                if (items.len >= PREVIEW) {
                    try out.appendSlice(arena, " …");
                }
                return out.items;
            },
        }
    }

    fn known(kind: []const u8) bool {
        for ([_][]const u8{ "string", "list", "set", "zset", "hash" }) |one| {
            if (std.mem.eql(u8, kind, one)) {
                return true;
            }
        }
        return false;
    }

    /// What every key on this page holds, in one exchange. The types have to be
    /// known first - they decide which command each key takes - which is why this
    /// is a second pipeline and not part of the first.
    fn previews(self: *Db, arena: std.mem.Allocator, keys: []const []const u8, kinds: []const []const u8) db.Error![][]const u8 {
        var asking: std.ArrayList([]const []const u8) = .empty;
        for (keys, kinds) |key, kind| {
            try asking.append(arena, valueCommand(arena, key, kind) catch return error.OutOfMemory);
        }
        const said = try self.pipeline(arena, asking.items);
        const out = try arena.alloc([]const u8, keys.len);
        for (out, 0..) |*into, i| {
            into.* = try renderValue(arena, kinds[i], said[i]);
        }
        return out;
    }

    fn setValue(self: *Db, pair: Pair) db.Error!?db.Rows {
        const reply = try self.command(&[_][]const u8{ "SET", pair.key, pair.value });
        if (reply == .failure) {
            self.remember(reply.failure);
            return error.Driver;
        }
        // A new row may bring a ttl with it, which is a second command.
        if (pair.ttl) |seconds| {
            if (seconds.len != 0) {
                _ = try self.setTtl(.{ .key = pair.key, .value = seconds });
            }
        }
        return .{ .redis = .{ .owner = self, .changed = 1 } };
    }

    fn setTtl(self: *Db, pair: Pair) db.Error!?db.Rows {
        // A ttl of -1 in the grid means "no expiry", which is PERSIST.
        const seconds = std.fmt.parseInt(i64, pair.value, 10) catch -1;
        const reply = if (seconds < 0)
            try self.command(&[_][]const u8{ "PERSIST", pair.key })
        else blk: {
            var buf: [24]u8 = undefined;
            break :blk try self.command(&[_][]const u8{
                "EXPIRE", pair.key, std.mem.print(&buf, "{d}", .{seconds}) catch "0",
            });
        };
        if (reply == .failure) {
            self.remember(reply.failure);
            return error.Driver;
        }
        return .{ .redis = .{ .owner = self, .changed = 1 } };
    }

    fn deleteKey(self: *Db, key: []const u8) db.Error!?db.Rows {
        const reply = try self.command(&[_][]const u8{ "DEL", key });
        if (reply == .failure) {
            self.remember(reply.failure);
            return error.Driver;
        }
        return .{ .redis = .{ .owner = self, .changed = switch (reply) {
            .number => |value| value,
            else => 0,
        } } };
    }

    pub fn inTransaction(_: *Db) bool {
        // MULTI is not used here, and a console command that starts one is the
        // user's business.
        return false;
    }

    pub fn schemas(self: *Db, arena: std.mem.Allocator) db.Error![][]const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        var index: u8 = 0;
        while (index < self.count) : (index += 1) {
            try list.append(arena, try arena.print("{d}", .{index}));
        }
        // The one in use first, as the other drivers order theirs.
        if (self.index < list.items.len and self.index != 0) {
            const current = list.items[self.index];
            _ = list.orderedRemove(self.index);
            try list.insert(arena, 0, current);
        }
        return list.items;
    }

    pub fn objects(self: *Db, arena: std.mem.Allocator, schema: []const u8) db.Error![]db.Object {
        // Switching schema means SELECTing that database index.
        if (schema.len != 0) {
            if (std.fmt.parseInt(u8, schema, 10)) |wanted| {
                if (wanted != self.index) {
                    try self.useIndex(wanted);
                }
            } else |_| {}
        }
        var list: std.ArrayList(db.Object) = .empty;
        try list.append(arena, .{
            .schema = try arena.print("{d}", .{self.index}),
            .name = "data",
            .kind = .table,
            .rows = self.dbSize(),
        });
        return list.items;
    }

    fn useIndex(self: *Db, wanted: u8) db.Error!void {
        var buf: [8]u8 = undefined;
        const reply = try self.command(&[_][]const u8{
            "SELECT", std.mem.print(&buf, "{d}", .{wanted}) catch "0",
        });
        if (reply == .failure) {
            self.remember(reply.failure);
            return error.Driver;
        }
        self.index = wanted;
        self.relabel();
    }

    pub fn columns(_: *Db, arena: std.mem.Allocator, _: db.Table) db.Error![]db.Column {
        var list: std.ArrayList(db.Column) = .empty;
        try list.append(arena, .{ .name = "key", .type = "string", .notnull = true, .pk = true, .original = "key" });
        try list.append(arena, .{ .name = "type", .type = "string", .original = "type" });
        try list.append(arena, .{ .name = "ttl", .type = "integer", .original = "ttl" });
        try list.append(arena, .{ .name = "value", .type = "string", .original = "value" });
        return list.items;
    }

    pub fn indexes(_: *Db, arena: std.mem.Allocator, _: db.Table) db.Error![]db.Index {
        var list: std.ArrayList(db.Index) = .empty;
        try list.append(arena, .{ .name = "key", .kind = "PRIMARY", .columns = "key" });
        return list.items;
    }

    pub fn foreignKeys(_: *Db, _: std.mem.Allocator, _: db.Table) db.Error![]db.ForeignKey {
        return &[_]db.ForeignKey{};
    }

    pub fn definition(_: *Db, _: std.mem.Allocator, _: db.Table) db.Error!?[]const u8 {
        return null;
    }

    pub fn rowCount(self: *Db, _: db.Table) ?i64 {
        return self.dbSize();
    }

    /// The key is the key, which is what makes a row editable.
    pub fn rowKey(_: *Db, arena: std.mem.Allocator, _: db.Table) db.Error!db.RowKey {
        var list: std.ArrayList([]const u8) = .empty;
        try list.append(arena, "key");
        return .{ .columns = list.items };
    }

    pub fn alterContext(_: *Db, _: std.mem.Allocator, _: db.Table, _: []const db.Column) db.Error!db.AlterContext {
        return .{};
    }

    pub fn settings(self: *Db, arena: std.mem.Allocator) db.Error![]db.Setting {
        var list: std.ArrayList(db.Setting) = .empty;
        // Made again here if it can be, so that what follows is about a server.
        // Where it cannot, that is the one thing there is to say: every line
        // below would be a guess, and "encryption: none" a wrong one.
        self.ready() catch {
            try list.append(arena, .{ .label = "connection", .value = try arena.print("lost: {s}", .{self.lost.items}) });
            return list.items;
        };
        const FACTS = [_][2][]const u8{
            .{ "version", "redis_version" },
            .{ "mode", "redis_mode" },
            .{ "role", "role" },
            .{ "memory", "used_memory_human" },
            .{ "peak memory", "used_memory_peak_human" },
            .{ "clients", "connected_clients" },
            .{ "uptime (days)", "uptime_in_days" },
            .{ "keyspace hits", "keyspace_hits" },
            .{ "keyspace misses", "keyspace_misses" },
            .{ "persistence", "rdb_last_bgsave_status" },
        };
        for (FACTS) |entry| {
            const value = self.fact(entry[1]) orelse continue;
            try list.append(arena, .{ .label = entry[0], .value = try arena.dupe(u8, value) });
        }
        // Said either way, because the answer that matters is the one nobody
        // would think to look for: that it is not.
        try list.append(arena, .{
            .label = "encryption",
            .value = if (self.stream.ssl) |session|
                try arena.print("{s}{s}", .{
                    std.mem.span(net.ssl.SSL_get_version(session)),
                    if (self.verified) "" else ", certificate not checked",
                })
            else
                "none",
        });
        try list.append(arena, .{
            .label = "keys in this database",
            .value = try arena.print("{d}", .{self.dbSize() orelse 0}),
        });
        try list.append(arena, .{
            .label = "databases",
            .value = try arena.print("{d}", .{self.count}),
        });
        return list.items;
    }

    /// One line out of INFO, by its name.
    fn fact(self: *Db, name: []const u8) ?[]const u8 {
        const reply = self.command(&[_][]const u8{"INFO"}) catch return null;
        const text = textOf(reply) orelse return null;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const trimmed = std.mem.trim(u8, raw, " \r");
            const colon = std.mem.findScalar(u8, trimmed, ':') orelse continue;
            if (std.mem.eql(u8, trimmed[0..colon], name)) {
                return trimmed[colon + 1 ..];
            }
        }
        return null;
    }

    fn dbSize(self: *Db) ?i64 {
        const reply = self.command(&[_][]const u8{"DBSIZE"}) catch return null;
        return switch (reply) {
            .number => |value| value,
            else => null,
        };
    }

    /// How many numbered databases this server has.
    fn databaseCount(self: *Db) u8 {
        const reply = self.command(&[_][]const u8{ "CONFIG", "GET", "databases" }) catch return 16;
        const items = listOf(reply) orelse return 16;
        if (items.len < 2) {
            return 16;
        }
        return std.fmt.parseInt(u8, textOf(items[1]) orelse "16", 10) catch 16;
    }

    /// Redis has no batch: the console runs one command per line.
    pub fn split(_: *Db, arena: std.mem.Allocator, sql: []const u8) db.Error![]db.Statement {
        var list: std.ArrayList(db.Statement) = .empty;
        var lines = std.mem.splitScalar(u8, sql, '\n');
        while (lines.next()) |raw| {
            const line_text = std.mem.trim(u8, raw, " \t\r");
            // A comment is not a command; the refusals this driver writes for DDL
            // are comments, and Redis would only complain about them.
            if (line_text.len != 0 and !std.mem.startsWith(u8, line_text, "--") and !std.mem.startsWith(u8, line_text, "#")) {
                try list.append(arena, .{ .sql = line_text });
            }
        }
        return list.items;
    }

    pub fn ddl(_: *Db) db.Ddl {
        return .{ .redis = .{} };
    }
};

/// How many elements of a collection the value column shows.
const PREVIEW: usize = 50;

// ------------------------------------------------------------------- values

/// Parse one RESP reply out of a buffer, with no connection behind it. Here for
/// the fuzzer and for tests: the protocol reader is the part that takes bytes
/// straight off a socket and believes their length fields.
pub fn parseReply(allocator: std.mem.Allocator, arena: std.mem.Allocator, bytes: []const u8) !Value {
    var self = Db{
        .allocator = allocator,
        .stream = .{ .fd = -1 },
        .replies = std.heap.ArenaAllocator.init(allocator),
    };
    defer {
        self.replies.deinit();
        self.buffer.deinit(allocator);
        self.label.deinit(allocator);
        self.version_text.deinit(allocator);
        self.last_error.deinit(allocator);
        self.host.deinit(allocator);
    }
    try self.buffer.appendSlice(allocator, bytes);
    return self.parseValue(arena);
}

pub const Value = union(enum) {
    nil: void,
    text: ?[]const u8,
    number: i64,
    failure: []const u8,
    list: ?[]const Value,

    /// What this means to the grid. The one thing a driver's own value type
    /// has to say for itself; the walking and holding is db.Built's.
    pub fn asValue(self: @This()) db.Value {
        return switch (self) {
            .nil => .{ .null = {} },
            .number => |number| .{ .int = number },
            .failure => |text| .{ .text = text },
            // A key that is not there and a key holding nothing are different
            // things, and only one of them is null.
            .text => |text| if (text) |bytes| .{ .text = bytes } else .{ .null = {} },
            // A list is shown as a mark rather than flattened: what is in it is
            // what opening the row is for.
            .list => .{ .text = "…" },
        };
    }
};

/// The text of a reply that is text, and nothing for one that is anything
/// else. A field of `Value` read by its name is only there when the reply is
/// of that kind, and which kind it is is the server's to say: asked for a list
/// it may answer with an error, because the command was renamed away or is not
/// among what this user may run. Read as the list anyway, that was a panic
/// where such things are checked and somebody else's bytes where they are not.
/// So wherever the kind has not been looked at, it is looked at here.
fn textOf(value: Value) ?[]const u8 {
    return switch (value) {
        .text => |text| text,
        else => null,
    };
}

/// The same for a list.
fn listOf(value: Value) ?[]const Value {
    return switch (value) {
        .list => |items| items,
        else => null,
    };
}

// ------------------------------------------------------------------- cursor

/// Every reply is small enough to hold, so the cursor is a list of rows rather
/// than something that streams.
pub const Rows = db.Built(Db, Value);

// ---------------------------------------------------------------------- DDL

/// Redis has no schema to define, so every one of these says so rather than
/// writing SQL that could not work.
pub const Ddl = struct {
    pub fn types(_: Ddl) []const []const u8 {
        return &[_][]const u8{ "string", "list", "set", "zset", "hash" };
    }

    /// Written as `ECHO`, not as a comment: it runs, it costs nothing, and the
    /// reason ends up on screen as the result instead of the app reporting that
    /// something was created when nothing was.
    fn refuse(out: *List, a: std.mem.Allocator, what: []const u8) !void {
        try out.appendSlice(a, "ECHO \"redis has no ");
        try out.appendSlice(a, what);
        try out.appendSlice(a, ", so nothing was done - use a command instead\"\n");
    }

    pub fn createTable(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table, _: []const db.Column, _: []const db.ForeignKey) !void {
        try refuse(out, a, "tables");
    }

    pub fn alterTable(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table, _: []const u8, _: []const db.Column, _: db.AlterContext) !void {
        try refuse(out, a, "tables to alter");
    }

    pub fn addForeignKey(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table, _: db.ForeignKey, _: db.AlterContext) !void {
        try refuse(out, a, "foreign keys");
    }

    pub fn createIndex(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table, _: []const u8, _: []const []const u8, _: bool, _: []const u8) !void {
        try refuse(out, a, "indexes");
    }

    pub fn createView(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table, _: []const u8) !void {
        try refuse(out, a, "views");
    }

    pub fn createTrigger(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table, _: []const u8, _: []const u8, _: []const u8, _: []const u8, _: []const u8) !void {
        try refuse(out, a, "triggers");
    }

    pub fn renameTable(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table, _: []const u8) !void {
        try refuse(out, a, "tables to rename");
    }

    pub fn copyTable(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table, _: []const u8, _: bool) !void {
        try refuse(out, a, "tables to copy");
    }

    /// Emptying the database is the one thing that does have a command.
    pub fn dropObject(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Kind, _: db.Table) !void {
        try out.appendSlice(a, "FLUSHDB\n");
    }

    pub fn truncate(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table) !void {
        try out.appendSlice(a, "FLUSHDB\n");
    }
};

// ---------------------------------------------------------------- patterns

pub const TABLE = "data";
pub const KEY = "key";
pub const TYPE = "type";
pub const VALUE = "value";
pub const TTL = "ttl";

/// What one key is set to, and for how long.
pub const Pair = struct { key: []const u8, value: []const u8, ttl: ?[]const u8 = null };

/// `%a_b%` as Redis spells it: `*a?b*`.
pub fn glob(arena: std.mem.Allocator, like: []const u8) ![]const u8 {
    var out: List = .empty;
    for (like) |char| {
        try out.append(arena, switch (char) {
            '%' => '*',
            '_' => '?',
            else => char,
        });
    }
    return out.items;
}

/// The MATCH pattern a filter on the key comes to: the key itself for an
/// equality, the same pattern with Redis's wildcards for a LIKE, and everything
/// for anything else - Redis can only match a glob, so a `<` on a key is not a
/// filter it can push down.
pub fn matchOf(arena: std.mem.Allocator, where: []const db.ask.Filter) ![]const u8 {
    for (where) |filter| {
        if (!std.mem.eql(u8, filter.column, KEY)) {
            continue;
        }
        return switch (filter.op) {
            .eq => filter.value,
            .like => try glob(arena, filter.value),
            else => "*",
        };
    }
    return "*";
}

/// A cell of a change that was actually given a value: a change may set a column
/// to NULL, and for Redis that is the same as not setting it.
fn flat(value: ??[]const u8) ?[]const u8 {
    const inner = value orelse return null;
    const text = inner orelse return null;
    return text;
}

// ------------------------------------------------------------------ the target

const Parts = struct {
    host: [:0]const u8,
    password: []const u8,
    port: u16,
    index: u8,
    tls: bool = false,
    /// Whether the certificate is checked. Only `?insecure=1` turns it off: a
    /// server under a certificate of its own making is common enough to need a
    /// way in, and not so common that it should be the way in for everybody.
    verify: bool = true,

    fn deinit(self: Parts, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
        allocator.free(self.password);
    }
};

/// `redis://[:password@]host[:port][/index]`, the URL redis-cli takes, and
/// `rediss://` for the same over TLS. The port is 6379 either way: there is no
/// other one that TLS is by custom found on, and redis-cli assumes none.
fn parse(allocator: std.mem.Allocator, target: []const u8) !Parts {
    var rest = target;
    var tls = false;
    if (std.ascii.startsWithIgnoreCase(rest, "rediss://")) {
        rest = rest["rediss://".len..];
        tls = true;
    } else if (std.ascii.startsWithIgnoreCase(rest, "redis://")) {
        rest = rest["redis://".len..];
    }
    var password: []const u8 = "";
    if (std.mem.findScalarLast(u8, rest, '@')) |at| {
        const credentials = rest[0..at];
        rest = rest[at + 1 ..];
        // `user:password` or just `:password`; Redis before 6 has no user.
        password = if (std.mem.findScalar(u8, credentials, ':')) |colon|
            credentials[colon + 1 ..]
        else
            credentials;
    }
    // The query first, and whatever else the target has or has not got. It used
    // to be read only from inside the part after the `/`, so a target with no
    // database on it - `redis://host`, which is what somebody types - kept its
    // `?password=…` as part of the host name, and the app said it could not reach
    // `host?password=hunter2:6379`. Which also put the password on the screen.
    var verify = true;
    if (std.mem.findScalar(u8, rest, '?')) |question| {
        var parameters = std.mem.tokenizeAny(u8, rest[question + 1 ..], "&");
        while (parameters.next()) |parameter| {
            if (std.ascii.startsWithIgnoreCase(parameter, "password=")) {
                password = parameter["password=".len..];
            } else if (std.ascii.startsWithIgnoreCase(parameter, "insecure=")) {
                // The word every other engine here has for it.
                verify = std.mem.eql(u8, parameter["insecure=".len..], "0");
            }
        }
        rest = rest[0..question];
    }
    var index: u8 = 0;
    if (std.mem.findScalar(u8, rest, '/')) |slash| {
        index = std.fmt.parseInt(u8, rest[slash + 1 ..], 10) catch 0;
        rest = rest[0..slash];
    }
    var host: []const u8 = if (rest.len != 0) rest else "127.0.0.1";
    var port: u16 = 6379;
    if (std.mem.findScalarLast(u8, host, ':')) |colon| {
        port = std.fmt.parseInt(u16, host[colon + 1 ..], 10) catch port;
        host = host[0..colon];
    }
    return .{
        .host = try allocator.dupeSentinel(u8, host, 0),
        .password = try unescape(allocator, password),
        .port = port,
        .index = index,
        .tls = tls,
        .verify = verify,
    };
}

fn unescape(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: List = .empty;
    defer out.deinit(allocator);
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '%' and i + 2 < text.len) {
            if (std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16)) |byte| {
                try out.append(allocator, byte);
                i += 2;
                continue;
            } else |_| {}
        }
        try out.append(allocator, text[i]);
    }
    return allocator.dupe(u8, out.items);
}

pub fn owns(target: []const u8) bool {
    for ([_][]const u8{ "redis://", "rediss://" }) |prefix| {
        if (std.ascii.startsWithIgnoreCase(target, prefix)) {
            return true;
        }
    }
    return false;
}

test "a redis target is taken apart" {
    const a = std.testing.allocator;
    {
        const parts = try parse(a, "redis://:hunter2@cache.example:6380/3");
        defer parts.deinit(a);
        try std.testing.expectEqualStrings("cache.example", parts.host);
        try std.testing.expectEqualStrings("hunter2", parts.password);
        try std.testing.expectEqual(@as(u16, 6380), parts.port);
        try std.testing.expectEqual(@as(u8, 3), parts.index);
    }
    {
        const parts = try parse(a, "redis://127.0.0.1");
        defer parts.deinit(a);
        try std.testing.expectEqualStrings("127.0.0.1", parts.host);
        try std.testing.expectEqual(@as(u16, 6379), parts.port);
        try std.testing.expectEqual(@as(u8, 0), parts.index);
    }
    {
        // The password as a query parameter, which is how the app passes one on.
        const parts = try parse(a, "redis://127.0.0.1:6379/1?password=pa%20ss");
        defer parts.deinit(a);
        try std.testing.expectEqualStrings("pa ss", parts.password);
        try std.testing.expectEqual(@as(u8, 1), parts.index);
    }
    {
        // And a query on a target with no database on it, which is what `redis://host`
        // becomes once the app has added the password somebody typed. The query used
        // to be looked for only inside the part after the `/`, so with no `/` there
        // it stayed in the host: the app then said it could not reach
        // `host?password=hunter2:6379`, with the password on the screen.
        const parts = try parse(a, "redis://cache.example?password=hunter2");
        defer parts.deinit(a);
        try std.testing.expectEqualStrings("cache.example", parts.host);
        try std.testing.expectEqualStrings("hunter2", parts.password);
        try std.testing.expectEqual(@as(u16, 6379), parts.port);
    }
    {
        // The same with a port and no database.
        const parts = try parse(a, "redis://cache.example:6380?password=hunter2");
        defer parts.deinit(a);
        try std.testing.expectEqualStrings("cache.example", parts.host);
        try std.testing.expectEqualStrings("hunter2", parts.password);
        try std.testing.expectEqual(@as(u16, 6380), parts.port);
    }
    {
        // Nothing asked for, nothing assumed.
        const parts = try parse(a, "redis://cache.example");
        defer parts.deinit(a);
        try std.testing.expect(!parts.tls);
    }
    {
        // The second s is TLS, and it used to be read as a spelling of the first:
        // taken off with the rest of the scheme, and the connection made in the
        // clear. The certificate is checked unless the target says otherwise.
        const parts = try parse(a, "rediss://:hunter2@cache.example:6380/2");
        defer parts.deinit(a);
        try std.testing.expect(parts.tls);
        try std.testing.expect(parts.verify);
        try std.testing.expectEqualStrings("cache.example", parts.host);
        try std.testing.expectEqualStrings("hunter2", parts.password);
        try std.testing.expectEqual(@as(u16, 6380), parts.port);
        try std.testing.expectEqual(@as(u8, 2), parts.index);
    }
    {
        // The port does not follow the scheme, and neither does a capital letter.
        const parts = try parse(a, "REDISS://cache.example");
        defer parts.deinit(a);
        try std.testing.expect(parts.tls);
        try std.testing.expectEqualStrings("cache.example", parts.host);
        try std.testing.expectEqual(@as(u16, 6379), parts.port);
    }
    {
        // Not checking is asked for, beside the password the app adds.
        const parts = try parse(a, "rediss://cache.example?insecure=1&password=hunter2");
        defer parts.deinit(a);
        try std.testing.expect(parts.tls);
        try std.testing.expect(!parts.verify);
        try std.testing.expectEqualStrings("hunter2", parts.password);
    }
    {
        const parts = try parse(a, "rediss://cache.example/1?insecure=0");
        defer parts.deinit(a);
        try std.testing.expect(parts.verify);
        try std.testing.expectEqual(@as(u8, 1), parts.index);
    }
    try std.testing.expect(owns("redis://localhost"));
    try std.testing.expect(owns("rediss://localhost"));
    try std.testing.expect(!owns("mysql://localhost/demo"));
}

test "many commands go out together and their answers come back in order" {
    // The whole point of the pipeline: a screen of a hundred keys used to be four
    // hundred round trips, which on a link with any latency is half a minute of
    // nothing. What it relies on is that Redis answers in the order it was asked,
    // so the replies can be matched to the commands by position alone.
    var pair: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &pair) != 0) {
        return error.SkipZigTest;
    }
    defer _ = std.c.close(pair[0]);
    defer _ = std.c.close(pair[1]);
    var stream = net.Stream{ .fd = pair[0] };
    stream.setTimeout(50);

    var self = Db{
        .allocator = std.testing.allocator,
        .stream = stream,
        .replies = std.heap.ArenaAllocator.init(std.testing.allocator),
    };
    defer self.buffer.deinit(std.testing.allocator);
    defer self.replies.deinit();

    // Three answers, waiting before the questions are asked - which is what a
    // pipeline looks like from this end.
    const answers = "+string\r\n:-1\r\n$4\r\nahoj\r\n";
    _ = std.c.send(pair[1], answers.ptr, answers.len, 0);

    const arena = self.replies.allocator();
    const said = try self.pipeline(arena, &[_][]const []const u8{
        &[_][]const u8{ "TYPE", "k" },
        &[_][]const u8{ "TTL", "k" },
        &[_][]const u8{ "GET", "k" },
    });
    try std.testing.expectEqual(@as(usize, 3), said.len);
    try std.testing.expectEqualStrings("string", said[0].text.?);
    try std.testing.expectEqual(@as(i64, -1), said[1].number);
    try std.testing.expectEqualStrings("ahoj", said[2].text.?);
    // And nothing is left over, so the next exchange starts clean.
    try std.testing.expectEqual(@as(usize, 0), self.buffer.items.len);

    // What went out is three commands in one write, in the order given.
    var sent: [256]u8 = undefined;
    const got = std.c.recv(pair[1], &sent, sent.len, 0);
    try std.testing.expect(got > 0);
    const wire = sent[0..@intCast(got)];
    try std.testing.expect(std.mem.find(u8, wire, "TYPE").? < std.mem.find(u8, wire, "TTL").?);
    try std.testing.expect(std.mem.find(u8, wire, "TTL").? < std.mem.find(u8, wire, "GET").?);
}

test "what a failed connection says never carries the password" {
    // The host is what goes into `cannot reach redis at …`, so a query left
    // stuck to it puts the password on the screen - which is how this was
    // noticed. The rule is the host is a host: no query, no credentials.
    const a = std.testing.allocator;
    for ([_][]const u8{
        "redis://cache.example?password=hunter2",
        "redis://cache.example:6380?password=hunter2",
        "redis://cache.example:6380/2?password=hunter2",
        "redis://:hunter2@cache.example:6380/2",
    }) |target| {
        const parts = try parse(a, target);
        defer parts.deinit(a);
        try std.testing.expectEqualStrings("cache.example", parts.host);
        try std.testing.expectEqualStrings("hunter2", parts.password);
    }
}

test "a filter on the key becomes a MATCH pattern" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectEqualStrings("*", try matchOf(a, &.{}));
    try std.testing.expectEqualStrings("user:7", try matchOf(a, &.{.{ .column = KEY, .value = "user:7" }}));
    try std.testing.expectEqualStrings("*user*", try matchOf(a, &.{
        .{ .column = KEY, .op = .like, .value = "%user%" },
    }));
    try std.testing.expectEqualStrings("user:?", try matchOf(a, &.{
        .{ .column = KEY, .op = .like, .value = "user:_" },
    }));
    // Redis matches a glob and nothing else, so anything it cannot push down
    // scans everything rather than quietly dropping rows.
    try std.testing.expectEqualStrings("*", try matchOf(a, &.{
        .{ .column = KEY, .op = .gt, .value = "user:1" },
    }));
    // A filter on another column is not a key pattern.
    try std.testing.expectEqualStrings("*", try matchOf(a, &.{
        .{ .column = VALUE, .value = "hello" },
    }));
}

test "a change says which columns it sets, and NULL is not one of them" {
    const cells = [_]db.ask.Cell{
        .{ .column = KEY, .value = "greeting" },
        .{ .column = VALUE, .value = "hello" },
        .{ .column = TTL, .value = null },
    };
    try std.testing.expectEqualStrings("greeting", flat(db.ask.valueOf(&cells, KEY)).?);
    try std.testing.expectEqualStrings("hello", flat(db.ask.valueOf(&cells, VALUE)).?);
    // Set to NULL, which for Redis is nothing to do.
    try std.testing.expect(flat(db.ask.valueOf(&cells, TTL)) == null);
    // Not in the change at all.
    try std.testing.expect(flat(db.ask.valueOf(&cells, "type")) == null);
}

test "a command line is split with quotes honoured" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const args = try typed.split(arena.allocator(), "SET greeting \"hello world\"");
    try std.testing.expectEqual(@as(usize, 3), args.len);
    try std.testing.expectEqualStrings("SET", args[0]);
    try std.testing.expectEqualStrings("greeting", args[1]);
    try std.testing.expectEqualStrings("hello world", args[2]);
}

test "a reply that arrives in pieces is read from its start" {
    // The bug this is here for: a parse that ran out of bytes left the cursor
    // wherever it had got to, so the retry after more arrived began in the middle
    // of a key and read a letter of it as a type byte. Every command after that
    // read from an offset that meant nothing, and the connection was finished.
    //
    // It needs the reply to arrive in more than one piece, which on localhost it
    // never does - so the two pieces are written by hand, with the second one
    // after the reader is already waiting for it.
    var pair: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &pair) != 0) {
        return error.SkipZigTest;
    }
    defer _ = std.c.close(pair[0]);
    defer _ = std.c.close(pair[1]);
    var stream = net.Stream{ .fd = pair[0] };
    stream.setTimeout(50);

    var self = Db{
        .allocator = std.testing.allocator,
        .stream = stream,
        .replies = std.heap.ArenaAllocator.init(std.testing.allocator),
    };
    defer self.buffer.deinit(std.testing.allocator);
    defer self.replies.deinit();

    // What a SCAN answers with: a cursor and the keys, split where a real one
    // splits - in the middle of a key rather than between two of them.
    const whole = "*2\r\n$1\r\n7\r\n*2\r\n$19\r\nCACHE:FINANCE:RATES\r\n$5\r\nSHORT\r\n";
    // Two bytes into the first key, which is where a real one is cut: between
    // packets rather than between values.
    const cut = 22;
    const rest = struct {
        fn send(fd: std.c.fd_t, bytes: []const u8) void {
            @import("clock.zig").sleep(30);
            _ = std.c.send(fd, bytes.ptr, bytes.len, 0);
        }
    }.send;

    _ = std.c.send(pair[1], whole.ptr, cut, 0);
    const helper = try std.Thread.spawn(.{}, rest, .{ pair[1], whole[cut..] });
    defer helper.join();

    const value = try self.read(self.replies.allocator());
    const list = value.list orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualStrings("7", list[0].text.?);
    const keys = list[1].list orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), keys.len);
    try std.testing.expectEqualStrings("CACHE:FINANCE:RATES", keys[0].text.?);
    try std.testing.expectEqualStrings("SHORT", keys[1].text.?);
    // And the buffer is left with nothing owing, so the next reply starts clean.
    try std.testing.expectEqual(@as(usize, 0), self.at);
}

// ------------------------------------------------- a server for the tests

/// A server for the tests, on a port of its own. It answers the few commands
/// they send, writes down what it heard and on which connection, and hangs up
/// when it is told to - which is what a socket pair cannot stand in for: an end
/// that goes away, and somewhere to dial afterwards.
const Stand = struct {
    listener: std.c.fd_t,
    port: u16,
    thread: ?std.Thread = null,
    mutex: std.c.pthread_mutex_t = .{},
    done: bool = false,
    /// Whoever is connected now, and how many have been.
    client: std.c.fd_t = -1,
    connections: usize = 0,
    /// A line for each command: the connection it came on, and its words.
    heard: List = .empty,
    /// The command to hang up on in place of answering, once.
    hang_up_on: []const u8 = "",
    /// What AUTH is answered with.
    password_is: []const u8 = "hunter2",
    /// What a command is answered with in place of what `answer` has for it,
    /// as the wire has it: a server that will not carry the command out, or
    /// one whose answer is not in the shape that was asked for.
    instead: []const [2][]const u8 = &.{},

    const a = std.testing.allocator;

    fn start() !*Stand {
        return startAt(0);
    }

    /// On a port of the caller's choosing: the one another of these has just
    /// left, for a server that comes back where it was.
    fn startAt(port: u16) !*Stand {
        const listener = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
        if (listener < 0) {
            return error.SkipZigTest;
        }
        errdefer _ = std.c.close(listener);
        // Or a port that was in use a moment ago is refused for a while.
        const yes: c_int = 1;
        _ = std.c.setsockopt(listener, std.c.SOL.SOCKET, std.c.SO.REUSEADDR, &yes, @sizeOf(c_int));
        // Port 0 is whichever one is free, and the system says which it was.
        var address = std.c.sockaddr.in{ .port = std.mem.nativeToBig(u16, port), .addr = @bitCast([4]u8{ 127, 0, 0, 1 }) };
        var size: std.c.socklen_t = @sizeOf(std.c.sockaddr.in);
        if (std.c.bind(listener, @ptrCast(&address), size) != 0 or
            std.c.listen(listener, 8) != 0 or
            std.c.getsockname(listener, @ptrCast(&address), &size) != 0)
        {
            return error.SkipZigTest;
        }
        const self = try a.create(Stand);
        self.* = .{ .listener = listener, .port = std.mem.bigToNative(u16, address.port) };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    fn stop(self: *Stand) void {
        self.hold();
        self.done = true;
        self.release();
        if (self.thread) |thread| {
            thread.join();
        }
        _ = std.c.close(self.listener);
        self.heard.deinit(a);
        a.destroy(self);
    }

    fn hold(self: *Stand) void {
        _ = std.c.pthread_mutex_lock(&self.mutex);
    }

    fn release(self: *Stand) void {
        _ = std.c.pthread_mutex_unlock(&self.mutex);
    }

    fn finished(self: *Stand) bool {
        self.hold();
        defer self.release();
        return self.done;
    }

    /// Something to read on this descriptor before the test is over, or not.
    fn waitFor(self: *Stand, fd: std.c.fd_t) bool {
        while (!self.finished()) {
            var fds = [1]std.c.pollfd{.{ .fd = fd, .events = std.c.POLL.IN, .revents = 0 }};
            if (std.c.poll(&fds, 1, 10) > 0) {
                return true;
            }
        }
        return false;
    }

    fn run(self: *Stand) void {
        while (self.waitFor(self.listener)) {
            const client = std.c.accept(self.listener, null, null);
            if (client < 0) {
                continue;
            }
            self.hold();
            self.client = client;
            self.connections += 1;
            const number = self.connections;
            self.release();
            self.serve(client, number);
            self.hold();
            self.client = -1;
            self.release();
            _ = std.c.close(client);
        }
    }

    /// Hang up on whoever is connected, the way a server that restarts does.
    fn hangUp(self: *Stand) void {
        self.hold();
        defer self.release();
        if (self.client >= 0) {
            _ = std.c.shutdown(self.client, 2);
        }
    }

    fn serve(self: *Stand, client: std.c.fd_t, number: usize) void {
        var bytes: [4096]u8 = undefined;
        while (self.waitFor(client)) {
            const got = std.c.recv(client, &bytes, bytes.len, 0);
            if (got <= 0) {
                return;
            }
            // Every command the tests send is short and arrives whole, and no
            // word of one has a line break in it: a count, and then a length
            // and a word for each.
            var lines = std.mem.splitSequence(u8, bytes[0..@intCast(got)], "\r\n");
            while (lines.next()) |head| {
                if (head.len < 2 or head[0] != '*') {
                    continue;
                }
                const count = std.fmt.parseInt(usize, head[1..], 10) catch return;
                var words: [8][]const u8 = undefined;
                for (0..@min(count, words.len)) |i| {
                    _ = lines.next();
                    words[i] = lines.next() orelse return;
                }
                if (!self.answer(client, number, words[0..@min(count, words.len)])) {
                    return;
                }
            }
        }
    }

    /// Answer one command. False is hanging up.
    fn answer(self: *Stand, client: std.c.fd_t, number: usize, words: []const []const u8) bool {
        const name = words[0];
        self.hold();
        self.heard.print(a, "{d}", .{number}) catch {};
        for (words) |word| {
            self.heard.print(a, " {s}", .{word}) catch {};
        }
        self.heard.append(a, '\n') catch {};
        const hang_up = self.hang_up_on.len != 0 and std.ascii.eqlIgnoreCase(name, self.hang_up_on);
        if (hang_up) {
            self.hang_up_on = "";
        }
        const password = self.password_is;
        var instead: ?[]const u8 = null;
        for (self.instead) |one| {
            if (std.ascii.eqlIgnoreCase(name, one[0])) {
                instead = one[1];
                break;
            }
        }
        self.release();
        if (hang_up) {
            return false;
        }

        const is = std.ascii.eqlIgnoreCase;
        const reply: []const u8 = instead orelse if (is(name, "AUTH"))
            (if (std.mem.eql(u8, words[words.len - 1], password)) "+OK\r\n" else "-WRONGPASS invalid username-password pair\r\n")
        else if (is(name, "PING"))
            "+PONG\r\n"
        else if (is(name, "SELECT"))
            (if (std.mem.eql(u8, words[1], "99")) "-ERR DB index is out of range\r\n" else "+OK\r\n")
        else if (is(name, "CONFIG"))
            "*2\r\n$9\r\ndatabases\r\n$2\r\n16\r\n"
        else if (is(name, "INFO"))
            "$21\r\nredis_version:7.0.0\r\n\r\n"
        else if (is(name, "DBSIZE"))
            ":2\r\n"
        else if (is(name, "INCR"))
            ":1\r\n"
        else if (is(name, "GET"))
            "$5\r\nfresh\r\n"
        else if (is(name, "BLPOP")) late: {
            // Answered after whoever asked has stopped waiting.
            clock.sleep(250);
            break :late "$5\r\nstale\r\n";
        } else "+OK\r\n";
        _ = std.c.send(client, reply.ptr, reply.len, 0);
        return true;
    }

    /// What was heard so far, as the caller's to free.
    fn said(self: *Stand) ![]u8 {
        self.hold();
        defer self.release();
        return a.dupe(u8, self.heard.items);
    }

    fn connected(self: *Stand) usize {
        self.hold();
        defer self.release();
        return self.connections;
    }

    /// Open the driver on this server. `rest` is what follows the port.
    fn open(self: *Stand, comptime rest: []const u8) !*Db {
        var report: List = .empty;
        defer report.deinit(a);
        var target: [96]u8 = undefined;
        return Db.open(a, try std.mem.print(&target, "redis://:hunter2@127.0.0.1:{d}" ++ rest, .{self.port}), &report);
    }

    /// Wait until the driver's end has been told that the other one is gone.
    fn untilHungUp(conn: *Db) void {
        var waited: usize = 0;
        while (waited < 200) : (waited += 1) {
            var fds = [1]std.c.pollfd{.{ .fd = conn.stream.fd, .events = std.c.POLL.IN, .revents = 0 }};
            if (std.c.poll(&fds, 1, 5) > 0) {
                return;
            }
        }
    }
};

test "a connection the server hung up on is made again, and put back as it was" {
    // What a restart looks like from here: the server says it is going while
    // nothing is being asked, and the next thing asked finds a socket with
    // nobody on the other end. It used to fail, and so did everything after it.
    const stand = try Stand.start();
    defer stand.stop();
    const conn = try stand.open("/3");
    defer conn.close();
    try std.testing.expectEqual(@as(usize, 1), stand.connected());

    stand.hangUp();
    Stand.untilHungUp(conn);

    // Found gone before anything was written, so even what somebody typed -
    // which is never sent twice - goes out on the new connection, once.
    var rows = (try conn.query("INCR n", null)).?;
    rows.close();
    try std.testing.expectEqual(@as(usize, 2), stand.connected());

    const heard = try stand.said();
    defer std.testing.allocator.free(heard);
    // The password first, then the database that was in use, and only then
    // the question: a new connection is in database 0 and has said nothing.
    try std.testing.expect(std.mem.find(u8, heard, "2 AUTH hunter2\n2 SELECT 3\n2 INCR n\n") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, heard, "INCR n"));
    try std.testing.expectEqualStrings("", conn.message());
    try std.testing.expectEqual(@as(usize, 0), conn.lost.items.len);
}

test "what the driver asks for itself is asked again when the connection goes under it" {
    // Not found gone beforehand: the server hangs up with the question in its
    // hand. A read comes to the same asked twice, so it is.
    const stand = try Stand.start();
    defer stand.stop();
    const conn = try stand.open("");
    defer conn.close();

    stand.hold();
    stand.hang_up_on = "DBSIZE";
    stand.release();
    try std.testing.expectEqual(@as(?i64, 2), conn.rowCount(.{ .name = TABLE }));

    const heard = try stand.said();
    defer std.testing.allocator.free(heard);
    try std.testing.expect(std.mem.find(u8, heard, "1 DBSIZE\n2 AUTH hunter2\n2 DBSIZE\n") != null);
}

test "what somebody typed is not sent twice" {
    // The same, with a command that is not the same done twice. Whether the
    // server carried it out before it went is not known here, so it is said
    // and not repeated - and the next thing asked has a connection again.
    const stand = try Stand.start();
    defer stand.stop();
    const conn = try stand.open("");
    defer conn.close();

    stand.hold();
    stand.hang_up_on = "INCR";
    stand.release();
    try std.testing.expectError(error.Driver, conn.query("INCR n", null));
    try std.testing.expect(std.mem.find(u8, conn.message(), CLOSED) != null);
    try std.testing.expect(std.mem.find(u8, conn.message(), "not sent a second time") != null);

    var rows = (try conn.query("GET k", null)).?;
    defer rows.close();
    try std.testing.expect(try rows.next());
    try std.testing.expectEqualStrings("fresh", rows.value(0).text);

    const heard = try stand.said();
    defer std.testing.allocator.free(heard);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, heard, "INCR n"));
    try std.testing.expect(std.mem.find(u8, heard, "2 GET k\n") != null);
}

test "an answer that was given up on is not read as the next one" {
    // Giving up on a command left its answer on the way, and whatever was
    // asked next read that one for its own - and so on, one behind, for as
    // long as the program ran. The connection is let go of with the wait.
    const stand = try Stand.start();
    defer stand.stop();
    const conn = try stand.open("");
    defer conn.close();

    const Patience = struct {
        var asked: usize = 0;
        fn keepGoing(_: *anyopaque) bool {
            asked += 1;
            // Before it is sent, before its reply is read, and then - nothing
            // having come - the one that counts.
            return asked < 3;
        }
        fn begin(_: *anyopaque) void {
            asked = 0;
        }
    };
    var nothing: u8 = 0;
    conn.stream.setTimeout(40);
    conn.watch(.{ .context = &nothing, .keep_going = Patience.keepGoing, .begin = Patience.begin });
    try std.testing.expectError(error.Driver, conn.query("BLPOP fronta 8", null));
    try std.testing.expectEqualStrings("given up on", conn.message());

    conn.watch(null);
    var rows = (try conn.query("GET k", null)).?;
    defer rows.close();
    try std.testing.expect(try rows.next());
    try std.testing.expectEqualStrings("fresh", rows.value(0).text);
    try std.testing.expectEqual(@as(usize, 2), stand.connected());
}

test "a server that stays away is said, once for all that one key asks" {
    const stand = try Stand.start();
    const port = stand.port;
    const conn = stand.open("/3") catch |err| {
        stand.stop();
        return err;
    };
    defer conn.close();
    // Gone, and nothing listening where it was.
    stand.stop();
    Stand.untilHungUp(conn);

    // The counts say nothing, as they do for a server that will not count...
    try std.testing.expectEqual(@as(?i64, null), conn.rowCount(.{ .name = TABLE }));
    const failed_at = conn.failed_at;
    try std.testing.expect(failed_at != 0);
    // ...and the rows say why, without having dialled again to find out.
    try std.testing.expectError(error.Driver, conn.select(.{ .table = .{ .name = TABLE } }));
    try std.testing.expect(std.mem.find(u8, conn.message(), "was lost, and it cannot be reached again") != null);
    try std.testing.expectEqual(failed_at, conn.failed_at);

    // The info screen has one thing to say, and it is not "encryption: none".
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const settings = try conn.settings(arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), settings.len);
    try std.testing.expectEqualStrings("connection", settings[0].label);
    try std.testing.expect(std.mem.startsWith(u8, settings[0].value, "lost: "));

    // And it comes back. Asked at once, the answer is still the last one:
    // nothing has looked. Asked after the wait, it is found, and the
    // connection is the old one in everything but the socket.
    const back = Stand.startAt(port) catch return error.SkipZigTest;
    defer back.stop();
    try std.testing.expectEqual(@as(?i64, null), conn.rowCount(.{ .name = TABLE }));
    try std.testing.expectEqual(@as(usize, 0), back.connected());
    conn.failed_at -= REVIVE_EVERY_MS;
    try std.testing.expectEqual(@as(?i64, 2), conn.rowCount(.{ .name = TABLE }));
    try std.testing.expectEqual(@as(f64, 0), conn.failed_at);
    const heard = try back.said();
    defer std.testing.allocator.free(heard);
    try std.testing.expectEqualStrings("1 AUTH hunter2\n1 SELECT 3\n1 DBSIZE\n", heard);
}

test "a server that will not have the new connection says why" {
    // The password changed while the server was away. What is asked next is
    // not asked in a session nobody was let into, and not in database 0.
    const stand = try Stand.start();
    defer stand.stop();
    const conn = try stand.open("/3");
    defer conn.close();

    stand.hold();
    stand.password_is = "jine";
    stand.release();
    stand.hangUp();
    Stand.untilHungUp(conn);

    try std.testing.expectError(error.Driver, conn.select(.{ .table = .{ .name = TABLE } }));
    try std.testing.expect(std.mem.find(u8, conn.message(), "the password is not taken again: WRONGPASS") != null);
    const heard = try stand.said();
    defer std.testing.allocator.free(heard);
    try std.testing.expect(std.mem.find(u8, heard, "2 AUTH hunter2\n") != null);
    try std.testing.expect(std.mem.find(u8, heard, "2 SCAN") == null);
}

test "a server that will not say how many databases it has, or what it is, still opens" {
    // What a hosted Redis is like: CONFIG renamed away, and INFO not among
    // what the user may run. Both are answered with an error, and the error
    // was read as the list and the text that had been asked for - a panic
    // where that is checked, and whatever those bytes are where it is not.
    // It was the third thing said on a new connection, so none of them opened.
    const stand = try Stand.start();
    defer stand.stop();
    stand.hold();
    stand.instead = &.{
        .{ "CONFIG", "-ERR unknown command 'CONFIG', with args beginning with: 'GET' 'databases' \r\n" },
        .{ "INFO", "-NOPERM User default has no permissions to run the 'info' command\r\n" },
    };
    stand.release();

    const conn = try stand.open("");
    defer conn.close();
    // Sixteen is what Redis has unless it is told otherwise, and a version
    // nobody would say is one nobody knows.
    try std.testing.expectEqual(@as(u8, 16), conn.count);
    try std.testing.expectEqualStrings("Redis ?", conn.version());
    // Being refused the two is not something wrong with the connection.
    try std.testing.expectEqualStrings("", conn.message());

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(usize, 16), (try conn.schemas(arena.allocator())).len);
    // The info screen leaves out what INFO would have said, and has the rest.
    const settings = try conn.settings(arena.allocator());
    try std.testing.expectEqual(@as(usize, 3), settings.len);
    try std.testing.expectEqualStrings("encryption", settings[0].label);
    try std.testing.expectEqualStrings("databases", settings[2].label);
    try std.testing.expectEqualStrings("16", settings[2].value);
}

test "how many databases is only believed where it is said as CONFIG says it" {
    // An answer, and not the one asked for: the name with no value after it,
    // a value that is a number of its own, a line of text.
    for ([_][]const u8{
        "*1\r\n$9\r\ndatabases\r\n",
        "*2\r\n$9\r\ndatabases\r\n*0\r\n",
        "*2\r\n$9\r\ndatabases\r\n$-1\r\n",
        "+OK\r\n",
        ":4\r\n",
        "$-1\r\n",
    }) |answer| {
        const stand = try Stand.start();
        defer stand.stop();
        stand.hold();
        stand.instead = &.{.{ "CONFIG", answer }};
        stand.release();
        const conn = try stand.open("");
        defer conn.close();
        try std.testing.expectEqual(@as(u8, 16), conn.count);
        try std.testing.expectEqualStrings("Redis 7.0.0", conn.version());
    }
    // And where it is, it is.
    const stand = try Stand.start();
    defer stand.stop();
    stand.hold();
    stand.instead = &.{.{ "CONFIG", "*2\r\n$9\r\ndatabases\r\n$1\r\n4\r\n" }};
    stand.release();
    const conn = try stand.open("");
    defer conn.close();
    try std.testing.expectEqual(@as(u8, 4), conn.count);
}

test "a listing of keys that is not in the shape of one is read as far as it goes" {
    const stand = try Stand.start();
    defer stand.stop();
    const conn = try stand.open("");
    defer conn.close();

    // Not a list at all, and then a list of the right length with the wrong
    // things in it: a cursor that is a number, and a word where the keys go.
    // No keys either way, and no reading of one thing as another.
    for ([_][]const u8{ "+OK\r\n", ":0\r\n", "$-1\r\n", "*2\r\n:0\r\n+OK\r\n" }) |answer| {
        stand.hold();
        stand.instead = &.{.{ "SCAN", answer }};
        stand.release();
        var none = (try conn.select(.{ .table = .{ .name = TABLE } })).?;
        defer none.close();
        try std.testing.expect(!try none.next());
    }

    // A page with something in it that is not a key, and a server that will
    // not say what kind of key the other one is. The key is still a row.
    stand.hold();
    stand.instead = &.{
        .{ "SCAN", "*2\r\n$1\r\n0\r\n*3\r\n:7\r\n*0\r\n$6\r\nuser:1\r\n" },
        .{ "TYPE", "-NOPERM User default has no permissions to run the 'type' command\r\n" },
        .{ "TTL", ":-1\r\n" },
    };
    stand.release();
    var rows = (try conn.select(.{ .table = .{ .name = TABLE } })).?;
    defer rows.close();
    try std.testing.expect(try rows.next());
    try std.testing.expectEqualStrings("user:1", rows.value(0).text);
    try std.testing.expectEqualStrings("?", rows.value(1).text);
    try std.testing.expectEqual(@as(i64, -1), rows.value(2).int);
    try std.testing.expectEqualStrings("", rows.value(3).text);
    try std.testing.expect(!try rows.next());
}

test "what a collection holds is shown element by element, whatever the elements are" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // As Redis answers: every element a string.
    try std.testing.expectEqualStrings("a, b, c", try Db.renderValue(a, "list", .{ .list = &.{
        .{ .text = "a" }, .{ .text = "b" }, .{ .text = "c" },
    } }));
    try std.testing.expectEqualStrings("apples=3, pears=2", try Db.renderValue(a, "hash", .{ .list = &.{
        .{ .text = "apples" }, .{ .text = "3" }, .{ .text = "pears" }, .{ .text = "2" },
    } }));
    try std.testing.expectEqualStrings("", try Db.renderValue(a, "set", .{ .list = null }));
    // And as it does not: a number, nothing, an error, and a list inside the
    // list, each of which was read as a string because the others are.
    try std.testing.expectEqualStrings("a, 7, , ERR no, …", try Db.renderValue(a, "zset", .{ .list = &.{
        .{ .text = "a" },                  .{ .number = 7 },
        .{ .nil = {} },                    .{ .failure = "ERR no" },
        .{ .list = &.{.{ .text = "b" }} },
    } }));
}

test "a request for one column of a key gets that column, and not the key" {
    const stand = try Stand.start();
    defer stand.stop();
    const conn = try stand.open("");
    defer conn.close();
    stand.hold();
    stand.instead = &.{
        .{ "SCAN", "*2\r\n$1\r\n0\r\n*1\r\n$6\r\nuser:1\r\n" },
        .{ "TYPE", "+string\r\n" },
        .{ "TTL", ":-1\r\n" },
        .{ "GET", "$3\r\nada\r\n" },
    };
    stand.release();

    // As the whole-value view asks, and through the door it asks at: the
    // columns are seen to there, for every driver that builds its rows. This
    // one is asked directly first, to show what it builds - the whole row.
    const request = db.ask.Select{
        .table = .{ .name = TABLE },
        .columns = &.{VALUE},
        .where = &.{.{ .column = KEY, .value = "user:1" }},
        .limit = 1,
    };
    var built = (try conn.select(request)).?;
    try std.testing.expectEqual(@as(usize, 4), built.columnCount());
    built.close();

    const asked_at = db.Db{ .redis = conn };
    var rows = (try asked_at.select(request)).?;
    defer rows.close();
    try std.testing.expectEqual(@as(usize, 1), rows.columnCount());
    try std.testing.expectEqualStrings(VALUE, rows.name(0));
    try std.testing.expect(try rows.next());
    try std.testing.expectEqualStrings("ada", rows.value(0).text);
    try std.testing.expect(!try rows.next());

    // A count is one number, whatever columns the request it was made from
    // had named.
    try std.testing.expectEqual(@as(?i64, 1), asked_at.count(request));
}

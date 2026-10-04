//! The MQTT driver: 3.1.1 spoken directly over a socket.
//!
//! No client library. The protocol is fourteen kinds of packet and this needs
//! ten of them, written out in `mqtt/wire.zig`.
//!
//! **A broker holds nothing to list, and this driver does not pretend it
//! does.** There is no "show me the topics" in MQTT: a topic exists while
//! somebody publishes to it, and the only way to learn of one is to be
//! subscribed when a message for it goes by. So that is what this does - it
//! subscribes, to everything unless the target names a filter, and what the
//! interface shows is what has arrived since:
//!
//! * `topics` - every topic heard from, with the last thing said on it. The
//!   retained messages arrive first, so a moment after connecting this is what
//!   the broker holds. Changing a payload publishes; deleting a row clears the
//!   retained message.
//! * `messages` - each message in the order it came, the newest last. A log:
//!   nothing in it can be changed, and a new row is a new message.
//! * `subscriptions` - the filters this connection is listening on. A new row
//!   subscribes and a deleted one unsubscribes.
//! * `$SYS` - what the broker says about itself, where it does.
//!
//! **Something has to keep listening**, which is the one way this driver is
//! unlike the others. A database answers when asked; a broker sends when it
//! has something, expects an answer to some of it, and takes a client that has
//! been silent too long for gone. So the connection belongs to a thread of its
//! own: it reads what arrives into the tables above, acknowledges what wants
//! acknowledging, and says it is still here twice in every keep-alive. What the
//! interface asks for is answered out of memory, under a lock, and what it
//! wants sent is left in a queue for that thread to send.
//!
//! What is kept is bounded: the last fifty thousand messages or sixty-four
//! megabytes of them, whichever is less. The oldest go first, and the info
//! screen says how many have.
//!
//! Nothing here parses SQL (`speaks_sql = false`). What the user types in the
//! editor is a line for this driver: `PUBLISH home/lamp on`, `SUBSCRIBE
//! sensors/#`, `TOPICS home/+/temperature`.

const std = @import("std");
const db = @import("db.zig");
const clock = @import("clock.zig");
const net = @import("net.zig");
const typed = @import("typed.zig");
const random = @import("random.zig");
const kafka = @import("kafka.zig");

/// What a packet is made of and what a target says: two files that know
/// nothing of a connection.
pub const wire = @import("mqtt/wire.zig");
pub const address = @import("mqtt/target.zig");

comptime {
    _ = wire;
    _ = address;
}

pub const owns = address.owns;
pub const Parts = address.Parts;

const List = db.List;
const Stream = net.Stream;

pub const TOPICS = "topics";
pub const MESSAGES = "messages";
pub const SUBSCRIPTIONS = "subscriptions";
pub const SYS = "$SYS";

/// How long the thread that owns the connection waits for something to arrive
/// before looking at what it has been asked to send. Short, because that wait
/// is the longest a publish sits in the queue.
const TICK_MS: i64 = 15;
/// How much is kept. A broker with a busy `#` will fill any memory given time.
const MAX_MESSAGES = 50_000;
const MAX_BYTES = 64 << 20;
const MAX_TOPICS = 100_000;
/// The largest packet taken. The protocol allows 256 MB; nothing that is looked
/// at on a terminal is that.
const MAX_PACKET = 32 << 20;
/// How long a broker has to say yes to a connection, and to acknowledge a
/// subscription or a message that asked to be acknowledged.
const GREETING_MS: f64 = 10_000;
const ACK_PATIENCE_MS: f64 = 10_000;
/// A connection that was lost is made again when something is next asked for,
/// but not more often than this, and not waited for longer than that.
const REVIVE_EVERY_MS: f64 = 3000;
const REVIVE_AT_MOST_MS: f64 = 30_000;
const REDIAL_MS: c_int = 2000;
/// How long a write may sit unfinished before the connection is taken for gone.
const SEND_PATIENCE_S = 10;
/// The quality of service asked for when subscribing: all of it, so that a
/// message is shown with the one it was published with rather than with zero.
const LISTEN_QOS: u2 = 2;

// ------------------------------------------------------------------- tables

/// What a column holds, which decides how it is compared and how it is drawn.
const Shape = enum { text, number, time, flag };

const Field = struct {
    name: []const u8,
    type: []const u8,
    shape: Shape = .text,
    key: bool = false,
    /// What the form says is filled in for whoever leaves it empty.
    default: ?[]const u8 = null,
};

const Table = enum {
    topics,
    messages,
    subscriptions,
    sys,

    fn of(wanted: []const u8) ?Table {
        inline for (comptime std.enums.values(Table)) |table| {
            if (std.ascii.eqlIgnoreCase(wanted, table.name())) {
                return table;
            }
        }
        return null;
    }

    fn name(self: Table) []const u8 {
        return switch (self) {
            .topics => TOPICS,
            .messages => MESSAGES,
            .subscriptions => SUBSCRIPTIONS,
            .sys => SYS,
        };
    }

    fn fields(self: Table) []const Field {
        return switch (self) {
            .topics => &[_]Field{
                .{ .name = "topic", .type = "text", .key = true },
                .{ .name = "payload", .type = "bytes" },
                .{ .name = "retained", .type = "bool", .shape = .flag, .default = "no" },
                .{ .name = "qos", .type = "int", .shape = .number, .default = "0" },
                .{ .name = "messages", .type = "bigint", .shape = .number, .default = "counted" },
                .{ .name = "time", .type = "timestamp", .shape = .time, .default = "now" },
            },
            .messages => &[_]Field{
                .{ .name = "n", .type = "bigint", .shape = .number, .key = true, .default = "next" },
                .{ .name = "time", .type = "timestamp", .shape = .time, .default = "now" },
                .{ .name = "topic", .type = "text" },
                .{ .name = "payload", .type = "bytes" },
                .{ .name = "qos", .type = "int", .shape = .number, .default = "0" },
                .{ .name = "retained", .type = "bool", .shape = .flag, .default = "no" },
            },
            .subscriptions => &[_]Field{
                .{ .name = "filter", .type = "text", .key = true },
                .{ .name = "qos", .type = "int", .shape = .number, .default = "2" },
                .{ .name = "state", .type = "text", .default = "asked" },
            },
            .sys => &[_]Field{
                .{ .name = "topic", .type = "text", .key = true },
                .{ .name = "value", .type = "text" },
                .{ .name = "time", .type = "timestamp", .shape = .time, .default = "now" },
            },
        };
    }

    fn fieldAt(self: Table, wanted: []const u8) ?usize {
        for (self.fields(), 0..) |field, at| {
            if (std.ascii.eqlIgnoreCase(field.name, wanted)) {
                return at;
            }
        }
        return null;
    }
};

pub const Value = union(enum) {
    nil: void,
    text: []const u8,
    number: i64,

    pub fn asValue(self: @This()) db.Value {
        return switch (self) {
            .nil => .{ .null = {} },
            .number => |number| .{ .int = number },
            .text => |text| .{ .text = text },
        };
    }
};

pub const Rows = db.Built(Db, Value);

// --------------------------------------------------------------- what is kept

/// One message as it arrived. The topic and the payload are one allocation, the
/// topic first, because there are fifty thousand of these.
const Message = struct {
    n: i64,
    at: i64,
    bytes: []u8,
    topic_len: usize,
    qos: u2,
    retained: bool,

    fn topic(self: Message) []const u8 {
        return self.bytes[0..self.topic_len];
    }

    fn payload(self: Message) []const u8 {
        return self.bytes[self.topic_len..];
    }
};

/// The last thing said on a topic. The topic itself is the key it is kept under.
const Heard = struct {
    payload: []u8,
    at: i64,
    count: i64 = 0,
    qos: u2 = 0,
    /// The broker was holding this when the subscription was made, or was given
    /// it by this connection to hold. A broker does not say so for a message it
    /// is passing on as it happens, so this is what is known and no more.
    retained: bool = false,
};

const Subscription = struct {
    filter: []u8,
    qos: u2,
    state: State = .asked,
    /// The packet the answer will name, while one is awaited.
    id: u16 = 0,

    const State = enum { asked, listening, refused };
};

/// The one acknowledgement this side is waiting for at a time: there is one
/// interface and it does one thing at a time.
const Wait = struct {
    id: u16 = 0,
    state: enum { idle, waiting, done, refused } = .idle,
};

const Heardmap = std.StringHashMapUnmanaged(Heard);

// ------------------------------------------------------------------ the driver

pub const Db = struct {
    allocator: std.mem.Allocator,
    stream: Stream,
    /// The thread the connection belongs to once it is up. See the top of the
    /// file for why there is one.
    thread: ?std.Thread = null,
    stop: std.atomic.Value(bool) = .init(false),
    mutex: std.c.pthread_mutex_t = .{},

    // --- shared with that thread, and touched only with the mutex held ---

    /// What the interface wants sent, in the order it asked.
    outbox: List = .empty,
    /// The log, oldest first. `first` is where it starts: dropping the oldest
    /// moves that along rather than everything else down.
    messages: std.ArrayList(Message) = .empty,
    first: usize = 0,
    held_bytes: usize = 0,
    next_n: i64 = 1,
    topics: Heardmap = .empty,
    sys: Heardmap = .empty,
    subscriptions: std.ArrayList(Subscription) = .empty,
    wait: Wait = .{},
    /// Topics this connection has just cleared. The broker passes the clearing
    /// on to every subscriber, this one included, and that echo is not news.
    cleared: std.StringHashMapUnmanaged(void) = .empty,
    /// Why the connection is gone, when it is. Empty while it is up.
    lost: List = .empty,
    received: u64 = 0,
    dropped: u64 = 0,
    untracked: u64 = 0,
    /// How much of the log is kept. Fields rather than the constants they start
    /// as, so a test can fill a log of a hundred instead of fifty thousand.
    most_messages: usize = MAX_MESSAGES,
    most_bytes: usize = MAX_BYTES,

    // --- the thread's own ---

    /// Bytes read and not yet a whole packet.
    inbox: List = .empty,
    /// Messages of quality two that have arrived and not been released: one
    /// that is sent again before then is the same message.
    arriving: std.AutoHashMapUnmanaged(u16, void) = .empty,

    // --- the interface's own ---

    /// What a statement was answered with, until the next one.
    replies: std.heap.ArenaAllocator,
    last_error: List = .empty,
    label: List = .empty,
    version_text: List = .empty,
    host: List = .empty,
    port: u16 = 1883,
    user: List = .empty,
    password: List = .empty,
    client: List = .empty,
    keepalive: u16 = 60,
    tls: bool = false,
    verify: bool = true,
    /// Where the broker was found, so that finding it again does not ask the
    /// resolver - which cannot be given a time limit, and this is done on the
    /// thread that draws the screen.
    peer: std.c.sockaddr.storage = undefined,
    peer_len: std.c.socklen_t = 0,
    packet_id: u16 = 0,
    revived_at: f64 = 0,
    /// How long to leave it before trying again: longer after each failure,
    /// because each try is a wait on the thread that draws the screen.
    revive_after: f64 = REVIVE_EVERY_MS,
    progress: ?db.Progress = null,

    pub fn open(allocator: std.mem.Allocator, target: []const u8, report: *List) !*Db {
        const parts = try address.parse(allocator, target);
        defer parts.deinit(allocator);
        if (parts.filter.len != 0) {
            if (wire.filterFault(parts.filter)) |why| {
                try report.print(allocator, "{s} is not something to subscribe to: {s}", .{ parts.filter, why });
                return error.Driver;
            }
        }
        var stream = net.connect(allocator, parts.host, parts.port) catch {
            try report.print(allocator, "cannot reach an MQTT broker at {s}:{d}", .{ parts.host, parts.port });
            return error.Driver;
        };
        if (parts.tls) {
            net.startTls(allocator, &stream, parts.host, .{ .verify = parts.verify }, report) catch {
                if (report.items.len == 0) {
                    try report.print(allocator, "TLS to {s}:{d} could not be set up", .{ parts.host, parts.port });
                }
                stream.close();
                return error.Driver;
            };
        }
        return attach(allocator, stream, parts, report);
    }

    /// Everything after the socket: say who is asking, start listening, and
    /// subscribe. Apart from `open` so that a test can hand it one end of a pair.
    fn attach(allocator: std.mem.Allocator, stream: Stream, parts: Parts, report: *List) !*Db {
        const self = allocator.create(Db) catch |err| {
            var mine = stream;
            mine.close();
            return err;
        };
        self.* = .{
            .allocator = allocator,
            .stream = stream,
            .replies = std.heap.ArenaAllocator.init(allocator),
        };
        errdefer self.close();
        try self.host.appendSlice(allocator, parts.host);
        self.port = parts.port;
        try self.user.appendSlice(allocator, parts.user);
        try self.password.appendSlice(allocator, parts.password);
        self.keepalive = parts.keepalive;
        self.tls = parts.tls;
        self.verify = parts.verify;
        if (parts.client.len != 0) {
            try self.client.appendSlice(allocator, parts.client);
        } else {
            // A name of its own: two connections with the same one take turns
            // throwing each other off the broker.
            var noise: [4]u8 = undefined;
            random.bytes(&noise) catch {
                noise = @bitCast(@as(u32, @truncate(@as(u64, @bitCast(clock.steadyNanos())))));
            };
            try self.client.print(allocator, "krtek-{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ noise[0], noise[1], noise[2], noise[3] });
        }
        self.peer_len = @sizeOf(std.c.sockaddr.storage);
        if (std.c.getpeername(self.stream.fd, @ptrCast(&self.peer), &self.peer_len) != 0) {
            self.peer_len = 0;
        }
        try self.label.print(allocator, "{s}:{d}", .{ parts.host, parts.port });

        db.tell("waiting for {s} to answer", .{parts.host});
        self.greet() catch {
            try report.appendSlice(allocator, self.last_error.items);
            return error.Driver;
        };
        try self.start();

        // What to listen to: what the target named, or everything - and beside
        // everything, what the broker says about itself, which `#` leaves out.
        db.tell("subscribing", .{});
        const everything = parts.filter.len == 0;
        self.subscribe(if (everything) "#" else parts.filter, LISTEN_QOS) catch {
            try report.appendSlice(allocator, self.last_error.items);
            return error.Driver;
        };
        if (everything) {
            // A broker that has none, or will not show them, is still a broker.
            self.subscribe("$SYS/#", 0) catch {};
            self.last_error.clearRetainingCapacity();
        }
        db.tell("listening for what the broker holds", .{});
        self.linger(600);
        return self;
    }

    /// CONNECT, and what the broker says to it. On the calling thread, before
    /// there is another one.
    fn greet(self: *Db) db.Error!void {
        // Each of these travels with its length in two bytes.
        for ([_][]const u8{ self.client.items, self.user.items, self.password.items }) |text| {
            if (text.len > 65535) {
                self.complain("a client id, a user and a password are each at most 65535 bytes, and one of these is {d}", .{text.len});
                return error.Driver;
            }
        }
        var packet: List = .empty;
        defer packet.deinit(self.allocator);
        wire.connect(&packet, self.allocator, .{
            .client = self.client.items,
            .user = self.user.items,
            .password = self.password.items,
            .keepalive = self.keepalive,
        }) catch return error.OutOfMemory;
        self.stream.setTimeout(TICK_MS);
        // And a limit on sending, which nothing else here needs: a broker that
        // stops reading would hold the thread in a write for ever, and closing
        // the connection waits for that thread.
        const patience = std.c.timeval{ .sec = SEND_PATIENCE_S, .usec = 0 };
        _ = std.c.setsockopt(self.stream.fd, std.c.SOL.SOCKET, std.c.SO.SNDTIMEO, &patience, @sizeOf(std.c.timeval));
        self.stream.write(packet.items) catch {
            self.complain("{s} closed the connection before it was greeted", .{self.label.items});
            return error.Driver;
        };
        self.inbox.clearRetainingCapacity();
        const started = clock.steadyMs();
        var chunk: [256]u8 = undefined;
        while (true) {
            const got = self.stream.readNow(&chunk) catch {
                self.complain("{s} closed the connection instead of answering as an MQTT broker", .{self.label.items});
                return error.Driver;
            };
            try self.inbox.appendSlice(self.allocator, chunk[0..got]);
            // The first thing a broker says is CONNACK and nothing else. Asked
            // of the first byte rather than of a whole packet: `HTTP/1.1 400`
            // read as MQTT is a packet eighty-four bytes long that never
            // finishes arriving, and waiting for it is waiting for nothing.
            if (self.inbox.items.len != 0 and self.inbox.items[0] != 0x20) {
                self.complain("{s} did not answer as an MQTT broker", .{self.label.items});
                return error.Driver;
            }
            const reply = wire.take(self.inbox.items) catch {
                self.complain("{s} did not answer as an MQTT broker", .{self.label.items});
                return error.Driver;
            };
            if (reply) |connack| {
                const code = wire.readConnack(connack) catch {
                    self.complain("{s} did not answer as an MQTT broker", .{self.label.items});
                    return error.Driver;
                };
                // Whatever came with it is the first of what the thread reads.
                self.inbox.replaceRangeAssumeCapacity(0, connack.size, "");
                if (code == 0) {
                    return;
                }
                if (code == 4 or code == 5) {
                    // Worded for whoever reads it and for the interface, which
                    // asks for a password when a refusal mentions one - and
                    // asking for one is no use where there is no user to send
                    // it with.
                    if (self.user.items.len != 0) {
                        self.complain("the broker wants a password for {s}", .{self.user.items});
                    } else {
                        self.complain("the broker did not authorise this connection: it wants a user, as mqtt://user@{s}", .{self.label.items});
                    }
                } else {
                    self.complain("{s}", .{wire.refusal(code)});
                }
                return error.Driver;
            }
            if (clock.steadyMs() - started > GREETING_MS) {
                self.complain("{s} accepted the connection and then said nothing", .{self.label.items});
                return error.Driver;
            }
            if (self.progress) |progress| {
                if (!progress.call()) {
                    self.complain("given up", .{});
                    return error.Driver;
                }
            }
        }
    }

    fn start(self: *Db) db.Error!void {
        self.stop.store(false, .release);
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch {
            self.complain("there is no thread to listen to the broker with", .{});
            return error.Driver;
        };
    }

    pub fn close(self: *Db) void {
        self.stop.store(true, .release);
        if (self.thread) |thread| {
            thread.join();
        }
        // Said rather than hung up on, so the broker does not take it for a
        // client that died. Best effort: it may be gone already.
        if (self.stream.fd >= 0 and self.lost.items.len == 0) {
            self.stream.write(&wire.DISCONNECT) catch {};
        }
        if (self.stream.fd >= 0) {
            self.stream.close();
        }
        self.forget();
        self.messages.deinit(self.allocator);
        self.topics.deinit(self.allocator);
        self.sys.deinit(self.allocator);
        for (self.subscriptions.items) |subscription| {
            self.allocator.free(subscription.filter);
        }
        self.subscriptions.deinit(self.allocator);
        var cleared = self.cleared.keyIterator();
        while (cleared.next()) |key| {
            self.allocator.free(key.*);
        }
        self.cleared.deinit(self.allocator);
        self.arriving.deinit(self.allocator);
        self.outbox.deinit(self.allocator);
        self.inbox.deinit(self.allocator);
        self.lost.deinit(self.allocator);
        self.replies.deinit();
        self.last_error.deinit(self.allocator);
        self.label.deinit(self.allocator);
        self.version_text.deinit(self.allocator);
        self.host.deinit(self.allocator);
        self.user.deinit(self.allocator);
        self.password.deinit(self.allocator);
        self.client.deinit(self.allocator);
        _ = std.c.pthread_mutex_destroy(&self.mutex);
        self.allocator.destroy(self);
    }

    /// Let go of everything that was heard. The caller holds the mutex, or is
    /// the only one left.
    fn forget(self: *Db) void {
        for (self.messages.items[self.first..]) |kept| {
            self.allocator.free(kept.bytes);
        }
        self.messages.clearRetainingCapacity();
        self.first = 0;
        self.held_bytes = 0;
        inline for (.{ &self.topics, &self.sys }) |map| {
            var walk = map.iterator();
            while (walk.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.payload);
            }
            map.clearRetainingCapacity();
        }
    }

    pub fn watch(self: *Db, progress: ?db.Progress) void {
        self.progress = progress;
    }

    pub fn caps(_: *Db) db.Caps {
        return .{
            .schemas = false,
            .hidden_row_id = false,
            .rebuild_to_alter = false,
            .databases = false,
            .label = "MQTT",
            .text_cast = "TEXT",
            // Asked with a structure; the editor is a line for this driver.
            .speaks_sql = false,
            // Clearing a retained message and dropping a subscription are both
            // done once they are done.
            .final_deletes = true,
            .no_ddl = "a broker has no tables to make: a topic is there while somebody publishes to it, and i publishes",
        };
    }

    pub fn version(self: *Db) []const u8 {
        // What the broker calls itself, where it says: it arrives a moment after
        // the subscription, so this is read when asked rather than once.
        self.version_text.clearRetainingCapacity();
        self.hold();
        defer self.release();
        const said = if (self.sys.get("$SYS/broker/version")) |heard| heard.payload else "";
        if (self.lost.items.len != 0) {
            self.version_text.print(self.allocator, "MQTT 3.1.1 - not connected: {s}", .{self.lost.items}) catch {};
        } else if (said.len != 0 and typed.readable(said)) {
            self.version_text.print(self.allocator, "MQTT 3.1.1, {s}", .{said}) catch {};
        } else {
            self.version_text.appendSlice(self.allocator, "MQTT 3.1.1") catch {};
        }
        return self.version_text.items;
    }

    pub fn describe(self: *Db) []const u8 {
        return self.label.items;
    }

    pub fn message(self: *Db) []const u8 {
        return self.last_error.items;
    }

    fn complain(self: *Db, comptime fmt: []const u8, args: anytype) void {
        self.last_error.clearRetainingCapacity();
        self.last_error.print(self.allocator, fmt, args) catch {};
    }

    fn hold(self: *Db) void {
        _ = std.c.pthread_mutex_lock(&self.mutex);
    }

    fn release(self: *Db) void {
        _ = std.c.pthread_mutex_unlock(&self.mutex);
    }

    // --------------------------------------------------- the listening thread

    /// The connection, for as long as it lasts: send what was asked, read what
    /// arrives, say this end is alive. Returns when told to stop or when the
    /// connection is lost, having said why.
    fn run(self: *Db) void {
        var chunk: [32 * 1024]u8 = undefined;
        var sending: List = .empty;
        defer sending.deinit(self.allocator);
        const patience: f64 = @as(f64, @floatFromInt(self.keepalive)) * 1000;
        var last_sent = clock.steadyMs();
        var last_heard = last_sent;

        // The greeting may have had the first packets behind it.
        self.digest() catch |err| return self.lose(err);
        while (!self.stop.load(.acquire)) {
            self.hold();
            std.mem.swap(List, &sending, &self.outbox);
            self.release();
            if (sending.items.len != 0) {
                self.stream.write(sending.items) catch return self.lose(error.Gone);
                sending.clearRetainingCapacity();
                last_sent = clock.steadyMs();
            }

            const got = self.stream.readNow(&chunk) catch return self.lose(error.Gone);
            const now = clock.steadyMs();
            if (got != 0) {
                last_heard = now;
                self.inbox.appendSlice(self.allocator, chunk[0..got]) catch return self.lose(error.OutOfMemory);
                self.digest() catch |err| return self.lose(err);
            }
            if (self.keepalive != 0) {
                // Twice in every keep-alive, so one that is lost on the way is
                // not the end of the connection.
                if (now - last_sent >= patience / 2) {
                    self.stream.write(&wire.PINGREQ) catch return self.lose(error.Gone);
                    last_sent = now;
                }
                if (now - last_heard >= patience * 2) {
                    return self.lose(error.Silent);
                }
            }
        }
    }

    /// The connection is gone: say why, where the interface will read it.
    fn lose(self: *Db, why: anyerror) void {
        self.hold();
        defer self.release();
        self.lost.clearRetainingCapacity();
        self.lost.appendSlice(self.allocator, switch (why) {
            error.Gone => "the broker closed the connection",
            error.Silent => "the broker stopped answering",
            error.Malformed => "what the broker sent was not MQTT",
            error.TooLarge => "the broker sent a message larger than is taken here",
            else => "there was no memory to hold what the broker sent",
        }) catch {};
        // Nobody will answer what was being waited for.
        if (self.wait.state == .waiting) {
            self.wait.state = .refused;
        }
    }

    /// Every whole packet that has been read, in order.
    fn digest(self: *Db) !void {
        var at: usize = 0;
        while (true) {
            const packet = (try wire.take(self.inbox.items[at..])) orelse break;
            try self.handle(packet);
            at += packet.size;
        }
        if (at != 0) {
            self.inbox.replaceRangeAssumeCapacity(0, at, "");
        }
        // What is left is the start of a packet. One that will never fit is
        // better refused now than read for a minute first.
        if (try wire.sizeOf(self.inbox.items)) |size| {
            if (size > MAX_PACKET) {
                return error.TooLarge;
            }
        }
    }

    fn handle(self: *Db, packet: wire.Packet) !void {
        switch (packet.kind) {
            .publish => {
                const arrived = try wire.readPublish(packet);
                var fresh = true;
                if (arrived.qos == 2) {
                    // Sent again until it is received: the second one is the first.
                    const seen = try self.arriving.getOrPut(self.allocator, arrived.id);
                    fresh = !seen.found_existing;
                }
                if (fresh) {
                    try self.keep(arrived);
                }
                if (arrived.qos != 0) {
                    try self.answer(if (arrived.qos == 1) .puback else .pubrec, arrived.id);
                }
            },
            .pubrel => {
                const id = try wire.readId(packet);
                _ = self.arriving.remove(id);
                try self.answer(.pubcomp, id);
            },
            // Half way through a message of quality two that this end sent.
            .pubrec => try self.answer(.pubrel, try wire.readId(packet)),
            .puback, .pubcomp, .unsuback => {
                const id = try wire.readId(packet);
                self.hold();
                defer self.release();
                if (self.wait.state == .waiting and self.wait.id == id) {
                    self.wait.state = .done;
                }
            },
            .suback => {
                const id = try wire.readId(packet);
                const granted = try wire.readSuback(packet);
                self.hold();
                defer self.release();
                for (self.subscriptions.items) |*subscription| {
                    if (subscription.id == id and subscription.state == .asked) {
                        subscription.id = 0;
                        if (granted) |qos| {
                            subscription.qos = qos;
                            subscription.state = .listening;
                        } else {
                            subscription.state = .refused;
                        }
                    }
                }
                if (self.wait.state == .waiting and self.wait.id == id) {
                    self.wait.state = if (granted != null) .done else .refused;
                }
            },
            // PINGRESP, and anything a broker has no business sending a client:
            // having arrived at all is what mattered.
            else => {},
        }
    }

    fn answer(self: *Db, kind: wire.Kind, id: u16) !void {
        self.stream.write(&wire.acknowledgement(kind, id)) catch return error.Gone;
    }

    /// One message, into the log and into what is known of its topic.
    fn keep(self: *Db, arrived: wire.Publish) !void {
        const now = clock.wallMs();
        self.hold();
        defer self.release();
        self.received += 1;
        if (std.mem.startsWith(u8, arrived.topic, "$SYS/")) {
            return self.note(&self.sys, arrived, now);
        }
        // The echo of a clearing this connection asked for.
        if (arrived.payload.len == 0) {
            if (self.cleared.fetchRemove(arrived.topic)) |entry| {
                self.allocator.free(entry.key);
                return;
            }
        }
        const bytes = try self.allocator.alloc(u8, arrived.topic.len + arrived.payload.len);
        errdefer self.allocator.free(bytes);
        @memcpy(bytes[0..arrived.topic.len], arrived.topic);
        @memcpy(bytes[arrived.topic.len..], arrived.payload);
        try self.messages.append(self.allocator, .{
            .n = self.next_n,
            .at = now,
            .bytes = bytes,
            .topic_len = arrived.topic.len,
            .qos = arrived.qos,
            .retained = arrived.retain,
        });
        self.next_n += 1;
        self.held_bytes += bytes.len;
        self.trim();
        try self.note(&self.topics, arrived, now);
    }

    /// The last thing said on a topic, replacing what was said before.
    fn note(self: *Db, map: *Heardmap, arrived: wire.Publish, now: i64) !void {
        const heard = map.getPtr(arrived.topic) orelse fresh: {
            if (map.count() >= MAX_TOPICS) {
                self.untracked += 1;
                return;
            }
            const key = try self.allocator.dupe(u8, arrived.topic);
            errdefer self.allocator.free(key);
            try map.put(self.allocator, key, .{ .payload = &.{}, .at = now });
            break :fresh map.getPtr(arrived.topic).?;
        };
        const payload = try self.allocator.dupe(u8, arrived.payload);
        self.allocator.free(heard.payload);
        heard.payload = payload;
        heard.at = now;
        heard.count += 1;
        heard.qos = arrived.qos;
        heard.retained = heard.retained or arrived.retain;
    }

    /// Keep the log within what it is allowed, the oldest going first.
    fn trim(self: *Db) void {
        while (self.messages.items.len - self.first > self.most_messages or self.held_bytes > self.most_bytes) {
            if (self.first >= self.messages.items.len) {
                break;
            }
            const oldest = self.messages.items[self.first];
            self.held_bytes -= oldest.bytes.len;
            self.allocator.free(oldest.bytes);
            self.first += 1;
            self.dropped += 1;
        }
        // The gap at the front is closed when it is most of the list.
        if (self.first >= 256 and self.first * 2 > self.messages.items.len) {
            self.messages.replaceRangeAssumeCapacity(0, self.first, &.{});
            self.first = 0;
        }
    }

    // ---------------------------------------------------- asking the broker

    /// A statement is starting.
    fn begin(self: *Db) void {
        if (self.progress) |progress| {
            progress.starting();
        }
        self.last_error.clearRetainingCapacity();
        _ = self.replies.reset(.retain_capacity);
        // A connection that was lost is made again here, quietly: what was
        // already heard can be looked at either way, and a failure to reconnect
        // is the business of whoever next wants something sent.
        if (self.isLost()) {
            self.revive() catch {};
            self.last_error.clearRetainingCapacity();
        }
    }

    fn isLost(self: *Db) bool {
        self.hold();
        defer self.release();
        return self.lost.items.len != 0;
    }

    /// For what cannot be done without a broker: connected, or an error that
    /// says why not.
    fn connected(self: *Db) db.Error!void {
        if (!self.isLost()) {
            return;
        }
        self.revive() catch {
            if (self.last_error.items.len == 0) {
                self.hold();
                defer self.release();
                self.complain("not connected: {s}", .{self.lost.items});
            }
            return error.Driver;
        };
    }

    /// Make the connection again, and ask for everything it was listening to.
    fn revive(self: *Db) db.Error!void {
        const now = clock.steadyMs();
        if (self.revived_at != 0 and now - self.revived_at < self.revive_after) {
            return error.Driver;
        }
        self.revived_at = now;
        // Twice as long before the next try, unless this one works: a broker
        // that is back is found within seconds, and one that is not costs a
        // wait every half a minute rather than every three seconds.
        const waited = self.revive_after;
        self.revive_after = @min(waited * 2, REVIVE_AT_MOST_MS);
        // The thread said why and left; this is only picking it up.
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        if (self.stream.fd >= 0) {
            self.stream.close();
        }
        const fd = redial(&self.peer, self.peer_len) catch {
            self.complain("the connection to {s} was lost and it cannot be reached again", .{self.label.items});
            return error.Driver;
        };
        self.stream = .{ .fd = fd };
        if (self.tls) {
            var why: List = .empty;
            defer why.deinit(self.allocator);
            net.startTls(self.allocator, &self.stream, self.host.items, .{ .verify = self.verify }, &why) catch {
                self.complain("the connection to {s} was lost, and TLS could not be set up again", .{self.label.items});
                self.stream.close();
                return error.Driver;
            };
        }
        self.greet() catch |err| {
            self.stream.close();
            return err;
        };

        // What belonged to the old connection is gone with it; what was being
        // listened to is asked for again.
        var packets: List = .empty;
        defer packets.deinit(self.allocator);
        self.hold();
        self.outbox.clearRetainingCapacity();
        self.arriving.clearRetainingCapacity();
        self.wait = .{};
        var at: usize = 0;
        while (at < self.subscriptions.items.len) {
            const subscription = &self.subscriptions.items[at];
            if (subscription.state != .listening) {
                self.allocator.free(subscription.filter);
                _ = self.subscriptions.orderedRemove(at);
                continue;
            }
            subscription.state = .asked;
            subscription.id = self.nextId();
            // At the quality it had: what was asked for, or what the broker
            // granted in its place.
            wire.subscribe(&packets, self.allocator, subscription.id, subscription.filter, subscription.qos) catch {};
            at += 1;
        }
        self.outbox.appendSlice(self.allocator, packets.items) catch {};
        self.lost.clearRetainingCapacity();
        self.release();
        self.start() catch |err| {
            // Connected, and nobody to read it: that is not a connection.
            self.hold();
            self.lost.appendSlice(self.allocator, "there was no thread to listen to the broker with") catch {};
            self.release();
            return err;
        };
        self.revive_after = REVIVE_EVERY_MS;
        self.linger(400);
    }

    fn nextId(self: *Db) u16 {
        self.packet_id +%= 1;
        if (self.packet_id == 0) {
            self.packet_id = 1;
        }
        return self.packet_id;
    }

    /// Wait for the broker to acknowledge the packet that was just queued.
    /// False when it answered and the answer was no.
    fn settle(self: *Db, what: []const u8) db.Error!bool {
        const started = clock.steadyMs();
        while (true) {
            self.hold();
            const state = self.wait.state;
            const gone = self.lost.items.len != 0;
            if (state != .waiting) {
                self.wait = .{};
            }
            self.release();
            switch (state) {
                .done => return true,
                .refused => if (!gone) return false,
                else => {},
            }
            if (gone) {
                self.hold();
                defer self.release();
                self.complain("{s} before {s} was acknowledged", .{ self.lost.items, what });
                return error.Driver;
            }
            const given_up = if (self.progress) |progress| !progress.call() else false;
            if (given_up or clock.steadyMs() - started > ACK_PATIENCE_MS) {
                self.hold();
                self.wait = .{};
                self.release();
                if (given_up) {
                    self.complain("given up before {s} was acknowledged", .{what});
                } else {
                    self.complain("the broker did not acknowledge {s}", .{what});
                }
                return error.Driver;
            }
            clock.sleep(3);
        }
    }

    /// Wait a moment for what is on its way: the retained messages after a
    /// subscription, the echo of a message just sent. Until nothing new has
    /// come for a little while, and never longer than `most` milliseconds - a
    /// broker with a busy `#` never goes quiet.
    fn linger(self: *Db, most: f64) void {
        const started = clock.steadyMs();
        var seen = self.count();
        var quiet_since = started;
        while (true) {
            clock.sleep(15);
            const now = clock.steadyMs();
            const count_now = self.count();
            if (count_now != seen) {
                seen = count_now;
                quiet_since = now;
            }
            if (now - started >= most or now - quiet_since >= 120) {
                return;
            }
        }
    }

    fn count(self: *Db) u64 {
        self.hold();
        defer self.release();
        return self.received;
    }

    /// Whether a message to this topic will come back, because this connection
    /// is listening to it.
    fn hears(self: *Db, topic: []const u8) bool {
        self.hold();
        defer self.release();
        for (self.subscriptions.items) |subscription| {
            if (subscription.state == .listening and wire.matches(subscription.filter, topic)) {
                return true;
            }
        }
        return false;
    }

    fn publish(self: *Db, topic: []const u8, payload: []const u8, qos: u2, retain: bool) db.Error!void {
        if (wire.topicFault(topic)) |why| {
            self.complain("{s}", .{why});
            return error.Driver;
        }
        if (payload.len > MAX_PACKET) {
            self.complain("{d} bytes is more than one message is sent with here", .{payload.len});
            return error.Driver;
        }
        try self.connected();
        var packet: List = .empty;
        defer packet.deinit(self.allocator);
        const id: u16 = if (qos != 0) self.nextId() else 0;
        try wire.publish(&packet, self.allocator, .{
            .topic = topic,
            .payload = payload,
            .qos = qos,
            .retain = retain,
            .id = id,
        });
        const before = self.count();
        self.hold();
        if (qos != 0) {
            self.wait = .{ .id = id, .state = .waiting };
        }
        self.outbox.appendSlice(self.allocator, packet.items) catch {
            self.wait = .{};
            self.release();
            return error.OutOfMemory;
        };
        if (retain) {
            // Told to hold it, so it is held - which the broker will not say
            // when it passes this very message back.
            if (self.topics.getPtr(topic)) |heard| {
                heard.retained = payload.len != 0;
            }
        }
        self.release();
        if (qos != 0) {
            _ = try self.settle("the message");
        }
        // And a moment for it to come back, so that the grid drawn after this
        // has the row somebody just wrote.
        if (self.hears(topic)) {
            const started = clock.steadyMs();
            while (self.count() == before and clock.steadyMs() - started < 400) {
                clock.sleep(5);
            }
        }
        if (retain) {
            // Again, for a topic that was first heard of by that echo.
            self.hold();
            defer self.release();
            if (self.topics.getPtr(topic)) |heard| {
                heard.retained = payload.len != 0;
            }
        }
    }

    /// Clear what the broker holds for a topic: a retained message with nothing
    /// in it, which is how the protocol says so.
    fn clear(self: *Db, topic: []const u8) db.Error!void {
        if (wire.topicFault(topic)) |why| {
            self.complain("{s}", .{why});
            return error.Driver;
        }
        try self.connected();
        // The clearing comes back like any message to whoever is listening, and
        // is not one. Where this connection is not, there is nothing to expect -
        // and expecting it anyway would swallow the next empty message for real.
        if (self.hears(topic)) {
            self.hold();
            defer self.release();
            if (!self.cleared.contains(topic)) {
                const key = try self.allocator.dupe(u8, topic);
                self.cleared.put(self.allocator, key, {}) catch {
                    self.allocator.free(key);
                    return error.OutOfMemory;
                };
            }
        }
        self.publish(topic, "", 1, true) catch |err| {
            // Not sent, so not coming back: the next message with nothing in
            // it on this topic is somebody's, and is kept.
            self.hold();
            defer self.release();
            if (self.cleared.fetchRemove(topic)) |entry| {
                self.allocator.free(entry.key);
            }
            return err;
        };
        self.hold();
        defer self.release();
        if (self.topics.fetchRemove(topic)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value.payload);
        }
    }

    fn subscribe(self: *Db, filter: []const u8, qos: u2) db.Error!void {
        if (wire.filterFault(filter)) |why| {
            self.complain("{s}", .{why});
            return error.Driver;
        }
        try self.connected();
        var packet: List = .empty;
        defer packet.deinit(self.allocator);
        const id = self.nextId();
        try wire.subscribe(&packet, self.allocator, id, filter, qos);
        // What it was before, where it was there before: asking again for one
        // that is listening is how its quality is changed, and an answer of no
        // - or none - leaves the broker with the one it had.
        var was: ?u2 = null;
        {
            self.hold();
            defer self.release();
            const at = self.subscriptionAt(filter) orelse added: {
                const copy = try self.allocator.dupe(u8, filter);
                self.subscriptions.append(self.allocator, .{ .filter = copy, .qos = qos }) catch {
                    self.allocator.free(copy);
                    return error.OutOfMemory;
                };
                break :added self.subscriptions.items.len - 1;
            };
            const subscription = &self.subscriptions.items[at];
            if (subscription.state == .listening) {
                was = subscription.qos;
            }
            subscription.state = .asked;
            subscription.id = id;
            self.wait = .{ .id = id, .state = .waiting };
            try self.outbox.appendSlice(self.allocator, packet.items);
        }
        const granted = self.settle("the subscription") catch |err| {
            self.unask(filter, was);
            return err;
        };
        if (!granted) {
            self.unask(filter, was);
            self.complain("the broker refused the subscription to {s}", .{filter});
            return error.Driver;
        }
    }

    /// A subscription that was asked for and not granted: back to what it was,
    /// or gone where it was not there before.
    fn unask(self: *Db, filter: []const u8, was: ?u2) void {
        const qos = was orelse return self.dropSubscription(filter);
        self.hold();
        defer self.release();
        if (self.subscriptionAt(filter)) |at| {
            self.subscriptions.items[at] = .{ .filter = self.subscriptions.items[at].filter, .qos = qos, .state = .listening };
        }
    }

    fn unsubscribe(self: *Db, filter: []const u8) db.Error!void {
        try self.connected();
        var packet: List = .empty;
        defer packet.deinit(self.allocator);
        const id = self.nextId();
        try wire.unsubscribe(&packet, self.allocator, id, filter);
        {
            self.hold();
            defer self.release();
            if (self.subscriptionAt(filter) == null) {
                self.complain("this connection is not subscribed to {s}", .{filter});
                return error.Driver;
            }
            self.wait = .{ .id = id, .state = .waiting };
            try self.outbox.appendSlice(self.allocator, packet.items);
        }
        _ = try self.settle("the unsubscription");
        self.dropSubscription(filter);
    }

    /// With the mutex held.
    fn subscriptionAt(self: *Db, filter: []const u8) ?usize {
        for (self.subscriptions.items, 0..) |subscription, at| {
            if (std.mem.eql(u8, subscription.filter, filter)) {
                return at;
            }
        }
        return null;
    }

    fn dropSubscription(self: *Db, filter: []const u8) void {
        self.hold();
        defer self.release();
        if (self.subscriptionAt(filter)) |at| {
            self.allocator.free(self.subscriptions.items[at].filter);
            _ = self.subscriptions.orderedRemove(at);
        }
    }

    // ------------------------------------------------- what the interface asks

    pub fn select(self: *Db, request: db.ask.Select) db.Error!?db.Rows {
        self.begin();
        const table = Table.of(request.table.name) orelse {
            self.complain("there is no {s} here - topics, messages, subscriptions and $SYS are what a broker is shown as", .{request.table.name});
            return error.Driver;
        };
        return .{ .mqtt = try self.view(table, request) };
    }

    /// A page of one of the tables, out of what has been heard.
    fn view(self: *Db, table: Table, request: db.ask.Select) db.Error!Rows {
        const arena = self.replies.allocator();
        const fields = table.fields();
        const names = try arena.alloc([]const u8, fields.len);
        const numeric = try arena.alloc(bool, fields.len);
        for (fields, 0..) |field, at| {
            names[at] = field.name;
            numeric[at] = field.shape == .number;
        }
        var rows = Rows{ .owner = self, .names = names, .numeric = numeric, .table = table.name() };

        self.hold();
        defer self.release();
        const source = try Source.of(self, arena, table);
        var kept: std.ArrayList(u32) = .empty;
        for (0..source.len()) |at| {
            if (passes(source, at, request)) {
                try kept.append(arena, @intCast(at));
            }
        }
        if (request.count) {
            const one = try arena.alloc([]const u8, 1);
            one[0] = "rows";
            var counted = Rows{ .owner = self, .names = one, .numeric = &[_]bool{true} };
            try counted.add(&[_]Value{.{ .number = @intCast(kept.items.len) }});
            return counted;
        }
        if (request.order.len != 0) {
            if (table.fieldAt(request.order)) |column| {
                std.mem.sort(u32, kept.items, Order{ .source = source, .column = column }, Order.before);
            }
        }
        if (request.descending) {
            std.mem.reverse(u32, kept.items);
        }
        const from = @min(request.offset, kept.items.len);
        const upto = if (request.limit != 0) @min(from + request.limit, kept.items.len) else kept.items.len;
        const values = try arena.alloc(Value, fields.len);
        for (kept.items[from..upto]) |at| {
            for (fields, 0..) |field, column| {
                values[column] = try shown(arena, source.cell(at, column), field.shape);
            }
            try rows.add(values);
        }
        return rows;
    }

    /// What is done to a row. A broker has four things it can be told - publish,
    /// clear, subscribe, unsubscribe - and each table makes its own of them.
    pub fn apply(self: *Db, change: db.ask.Change) db.Error!void {
        self.begin();
        const table = Table.of(change.table.name) orelse {
            self.complain("there is no {s} here", .{change.table.name});
            return error.Driver;
        };
        switch (table) {
            .sys => {
                self.complain("what the broker says about itself is the broker's to say", .{});
                return error.Driver;
            },
            .subscriptions => switch (change.kind) {
                .insert, .update => {
                    const filter = flat(db.ask.valueOf(change.cells, "filter")) orelse
                        db.ask.only(change.where, "filter") orelse "";
                    if (change.kind == .update and !std.mem.eql(u8, filter, db.ask.only(change.where, "filter") orelse filter)) {
                        self.complain("a subscription is its filter: subscribe to the other one with i, and delete this one", .{});
                        return error.Driver;
                    }
                    // The quality is the one thing about a subscription that can
                    // be changed. Anything else in an edit is not a reason to
                    // ask the broker for it again.
                    if (change.kind == .update and db.ask.valueOf(change.cells, "qos") == null) {
                        self.complain("the state is what the broker said: the quality of service is what can be changed", .{});
                        return error.Driver;
                    }
                    const qos = try self.qosOf(flat(db.ask.valueOf(change.cells, "qos")), LISTEN_QOS);
                    try self.subscribe(filter, qos);
                    self.linger(400);
                },
                .delete => try self.unsubscribe(db.ask.only(change.where, "filter") orelse ""),
            },
            .messages => switch (change.kind) {
                .insert => try self.publishCells(change.cells, .{}),
                .update => {
                    self.complain("a message that was sent is sent - i publishes another", .{});
                    return error.Driver;
                },
                .delete => {
                    self.complain("what was received stays in the log - FORGET in the editor empties it", .{});
                    return error.Driver;
                },
            },
            .topics => switch (change.kind) {
                .insert => try self.publishCells(change.cells, .{}),
                .update => {
                    const topic = db.ask.only(change.where, "topic") orelse "";
                    if (flat(db.ask.valueOf(change.cells, "topic"))) |renamed| {
                        if (!std.mem.eql(u8, renamed, topic)) {
                            self.complain("a topic is its name: publish to {s} with i, and delete this one", .{renamed});
                            return error.Driver;
                        }
                    }
                    // An edit here is a message sent, so an edit of what is only
                    // counted here must not be one: a changed `messages` would
                    // otherwise publish the payload again, to everybody.
                    for ([_][]const u8{ "messages", "time" }) |counted| {
                        if (db.ask.valueOf(change.cells, counted) != null) {
                            self.complain("{s} is counted here, not set: the payload, retained and qos are what a change publishes", .{counted});
                            return error.Driver;
                        }
                    }
                    // What the row says now, with what was changed on top of it.
                    var payload: []const u8 = "";
                    var retained = false;
                    {
                        self.hold();
                        defer self.release();
                        const heard = self.topics.get(topic) orelse {
                            self.complain("nothing has been heard on {s}", .{topic});
                            return error.Driver;
                        };
                        payload = try self.replies.allocator().dupe(u8, heard.payload);
                        retained = heard.retained;
                    }
                    try self.publishCells(change.cells, .{ .topic = topic, .payload = payload, .retained = retained });
                },
                .delete => {
                    const topic = db.ask.only(change.where, "topic") orelse "";
                    var retained = false;
                    {
                        self.hold();
                        defer self.release();
                        if (self.topics.get(topic)) |heard| {
                            retained = heard.retained;
                        }
                    }
                    if (retained) {
                        return self.clear(topic);
                    }
                    // Nothing is held for it, so there is nothing to clear - and
                    // clearing anyway would send every subscriber an empty
                    // message. It is only forgotten here.
                    self.hold();
                    defer self.release();
                    if (self.topics.fetchRemove(topic)) |entry| {
                        self.allocator.free(entry.key);
                        self.allocator.free(entry.value.payload);
                    }
                },
            },
        }
    }

    /// Publish what a form's cells say, over what the row said before.
    fn publishCells(self: *Db, cells: []const db.ask.Cell, was: Draft) db.Error!void {
        var draft = was;
        if (flat(db.ask.valueOf(cells, "topic"))) |topic| {
            draft.topic = topic;
        }
        if (db.ask.valueOf(cells, "payload")) |payload| {
            // Set to nothing is a message with nothing in it, which is one.
            draft.payload = payload orelse "";
        }
        if (flat(db.ask.valueOf(cells, "retained"))) |text| {
            draft.retained = truthy(text) orelse {
                self.complain("retained is yes or no, and {s} is neither", .{text});
                return error.Driver;
            };
        }
        draft.qos = try self.qosOf(flat(db.ask.valueOf(cells, "qos")), was.qos);
        try self.publish(draft.topic, draft.payload, draft.qos, draft.retained);
    }

    fn qosOf(self: *Db, text: ?[]const u8, otherwise: u2) db.Error!u2 {
        const said = std.mem.trim(u8, text orelse return otherwise, " \t");
        if (said.len == 0) {
            return otherwise;
        }
        if (said.len == 1 and said[0] >= '0' and said[0] <= '2') {
            return @intCast(said[0] - '0');
        }
        self.complain("the quality of service is 0, 1 or 2, and {s} is none of them", .{said});
        return error.Driver;
    }

    /// The request in this driver's own words, for the history, the report and
    /// a dump - which is a file of these, and has to come back as what it was.
    pub fn wording(self: *Db, allocator: std.mem.Allocator, request: db.Request) db.Error![]u8 {
        var out: List = .empty;
        errdefer out.deinit(allocator);
        switch (request) {
            .select => |value| {
                const table = Table.of(value.table.name) orelse .messages;
                try out.appendSlice(allocator, switch (table) {
                    .topics => "TOPICS",
                    .messages => "MESSAGES",
                    .subscriptions => "SUBSCRIPTIONS",
                    .sys => "SYS",
                });
                if (value.where_text.len != 0) {
                    try out.append(allocator, ' ');
                    try typed.word(&out, allocator, value.where_text);
                }
            },
            .change => |value| {
                const table = Table.of(value.table.name) orelse .messages;
                switch (table) {
                    .sys => try out.appendSlice(allocator, "-- what the broker says about itself is the broker's to say"),
                    .subscriptions => {
                        const filter = flat(db.ask.valueOf(value.cells, "filter")) orelse
                            db.ask.only(value.where, "filter") orelse "";
                        if (value.kind == .delete) {
                            try out.appendSlice(allocator, "UNSUBSCRIBE ");
                            try typed.word(&out, allocator, filter);
                        } else {
                            try out.appendSlice(allocator, "SUBSCRIBE ");
                            try typed.word(&out, allocator, filter);
                            if (flat(db.ask.valueOf(value.cells, "qos"))) |qos| {
                                try out.print(allocator, " {s}", .{qos});
                            }
                        }
                    },
                    .topics, .messages => {
                        if (value.kind == .delete) {
                            if (table == .messages) {
                                try out.appendSlice(allocator, "-- what was received stays in the log");
                            } else {
                                try out.appendSlice(allocator, "CLEAR ");
                                try typed.word(&out, allocator, db.ask.only(value.where, "topic") orelse "");
                            }
                            return out.toOwnedSlice(allocator);
                        }
                        var draft = Draft{ .topic = db.ask.only(value.where, "topic") orelse "" };
                        if (value.kind == .update) {
                            // What the row holds now is what goes out again with
                            // the change on top, so that is what is written.
                            self.hold();
                            defer self.release();
                            if (self.topics.get(draft.topic)) |heard| {
                                draft.retained = heard.retained;
                                if (db.ask.valueOf(value.cells, "payload") == null) {
                                    try writePublish(&out, allocator, .{
                                        .topic = draft.topic,
                                        .payload = heard.payload,
                                        .retained = if (flat(db.ask.valueOf(value.cells, "retained"))) |text|
                                            truthy(text) orelse heard.retained
                                        else
                                            heard.retained,
                                        .qos = digit(flat(db.ask.valueOf(value.cells, "qos"))),
                                    });
                                    return out.toOwnedSlice(allocator);
                                }
                            }
                        }
                        if (flat(db.ask.valueOf(value.cells, "topic"))) |topic| {
                            draft.topic = topic;
                        }
                        draft.payload = flat(db.ask.valueOf(value.cells, "payload")) orelse "";
                        if (flat(db.ask.valueOf(value.cells, "retained"))) |text| {
                            draft.retained = truthy(text) orelse draft.retained;
                        }
                        draft.qos = digit(flat(db.ask.valueOf(value.cells, "qos")));
                        try writePublish(&out, allocator, draft);
                    },
                }
            },
        }
        return out.toOwnedSlice(allocator);
    }

    // ------------------------------------------------------------ the console

    pub fn exec(self: *Db, sql: []const u8) db.Error!void {
        var rows = (try self.query(sql, null)) orelse return;
        rows.close();
    }

    /// A line for this driver, as typed in the editor:
    ///
    ///     TOPICS [filter]              what has been heard, by topic
    ///     MESSAGES [filter]            the last thousand messages, oldest first
    ///     SUBSCRIPTIONS                what this connection listens to
    ///     SYS [filter]                 what the broker says about itself
    ///     STATUS                       the connection, and the counts
    ///     PUBLISH [-r] [-q 0|1|2] [-b] <topic> [payload]
    ///     RETAIN <topic> [payload]     the same as PUBLISH -r
    ///     CLEAR <topic>                clear the retained message
    ///     SUBSCRIBE <filter> [qos]
    ///     UNSUBSCRIBE <filter>
    ///     FORGET                       empty the log and the topics kept here
    ///
    /// The payload is the rest of the line as it stands: quotes, braces and
    /// spaces are the payload's. `-b` says it is base64, which is how one with
    /// a line break in it gets onto a line.
    pub fn query(self: *Db, sql: []const u8, rest: ?*[]const u8) db.Error!?db.Rows {
        if (rest) |out| {
            out.* = sql[sql.len..];
        }
        const line = std.mem.trim(u8, sql, " \t\r\n");
        if (line.len == 0) {
            return null;
        }
        self.begin();
        var words = std.mem.tokenizeAny(u8, line, " \t");
        const verb = words.next() orelse return null;
        const argument = std.mem.trim(u8, words.rest(), " \t");

        if (eq(verb, "TOPICS") or eq(verb, "SYS") or eq(verb, "SUBSCRIPTIONS")) {
            const table: Table = if (eq(verb, "TOPICS")) .topics else if (eq(verb, "SYS")) .sys else .subscriptions;
            return .{ .mqtt = try self.listing(table, argument, 0) };
        }
        if (eq(verb, "MESSAGES")) {
            return .{ .mqtt = try self.listing(.messages, argument, 1000) };
        }
        if (eq(verb, "STATUS")) {
            return .{ .mqtt = try self.status() };
        }
        if (eq(verb, "PUBLISH") or eq(verb, "PUB") or eq(verb, "RETAIN")) {
            var draft = self.parsePublish(argument) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.Driver,
            };
            if (eq(verb, "RETAIN")) {
                draft.retained = true;
            }
            try self.publish(draft.topic, draft.payload, draft.qos, draft.retained);
            return .{ .mqtt = try self.did("published", draft.topic) };
        }
        if (eq(verb, "CLEAR")) {
            const topic = unquoted(argument);
            try self.clear(topic);
            return .{ .mqtt = try self.did("cleared", topic) };
        }
        if (eq(verb, "SUBSCRIBE") or eq(verb, "SUB")) {
            const arena = self.replies.allocator();
            const parts = try typed.split(arena, argument);
            if (parts.len == 0) {
                self.complain("SUBSCRIBE <filter> [qos] - # is everything, a/+/b one level, a/# all of them below a", .{});
                return error.Driver;
            }
            const qos = try self.qosOf(if (parts.len > 1) parts[1] else null, LISTEN_QOS);
            const filter = try arena.dupe(u8, parts[0]);
            try self.subscribe(filter, qos);
            self.linger(400);
            return .{ .mqtt = try self.did("subscribed", filter) };
        }
        if (eq(verb, "UNSUBSCRIBE") or eq(verb, "UNSUB")) {
            const filter = unquoted(argument);
            try self.unsubscribe(filter);
            return .{ .mqtt = try self.did("unsubscribed", filter) };
        }
        if (eq(verb, "FORGET")) {
            self.hold();
            const had: i64 = @intCast(self.messages.items.len - self.first);
            self.forget();
            self.release();
            var rows = try self.did("forgotten", "the log and the topics kept here - the broker keeps what it keeps");
            rows.changed = had;
            return .{ .mqtt = rows };
        }
        self.complain("{s} is not a command krtek knows - try TOPICS, MESSAGES, SUBSCRIPTIONS, SYS, STATUS, PUBLISH, RETAIN, CLEAR, SUBSCRIBE, UNSUBSCRIBE or FORGET", .{verb});
        return error.Driver;
    }

    /// One of the tables, as the console lists it: everything that matches, or
    /// the last `most` of it where there is a most.
    fn listing(self: *Db, table: Table, filter: []const u8, most: usize) db.Error!Rows {
        var rows = try self.view(table, .{
            .table = .{ .name = table.name() },
            .where_text = unquoted(filter),
            .descending = most != 0,
            .limit = most,
        });
        if (most != 0) {
            std.mem.reverse([]const Value, rows.rows.items);
        }
        // Rows somebody typed a command for are an answer, not a table: there is
        // no editing them from here.
        rows.table = "";
        return rows;
    }

    fn did(self: *Db, what: []const u8, to: []const u8) db.Error!Rows {
        const arena = self.replies.allocator();
        const names = try arena.alloc([]const u8, 1);
        names[0] = try arena.dupe(u8, what);
        var rows = Rows{ .owner = self, .names = names, .changed = 1 };
        try rows.add(&[_]Value{.{ .text = try arena.dupe(u8, to) }});
        return rows;
    }

    fn status(self: *Db) db.Error!Rows {
        const arena = self.replies.allocator();
        const names = try arena.alloc([]const u8, 2);
        names[0] = "what";
        names[1] = "value";
        var rows = Rows{ .owner = self, .names = names };
        for (try self.settings(arena)) |setting| {
            try rows.add(&[_]Value{ .{ .text = setting.label }, .{ .text = setting.value } });
        }
        return rows;
    }

    /// `[-r] [-q n] [-b] <topic> [payload]`, as a message.
    fn parsePublish(self: *Db, argument: []const u8) !Draft {
        var draft = Draft{};
        var encoded = false;
        var rest = argument;
        while (true) {
            rest = std.mem.trimStart(u8, rest, " \t");
            if (rest.len < 2 or rest[0] != '-' or (rest.len > 2 and rest[2] != ' ' and rest[2] != '\t')) {
                break;
            }
            switch (rest[1]) {
                'r' => draft.retained = true,
                'b' => encoded = true,
                'q' => {
                    var words = std.mem.tokenizeAny(u8, rest[2..], " \t");
                    const level = words.next() orelse "";
                    draft.qos = try self.qosOf(level, 0);
                    rest = words.rest();
                    continue;
                },
                else => break,
            }
            rest = rest[2..];
        }
        if (rest.len == 0) {
            self.complain("PUBLISH [-r] [-q 0|1|2] [-b] <topic> [payload] - the payload is the rest of the line", .{});
            return error.Driver;
        }
        // The topic: one word, or whatever is in quotes where it has a space.
        var end: usize = 0;
        if (rest[0] == '"' or rest[0] == '\'') {
            end = std.mem.findScalarPos(u8, rest, 1, rest[0]) orelse rest.len;
            draft.topic = rest[1..end];
            end = @min(end + 1, rest.len);
        } else {
            end = std.mem.findAny(u8, rest, " \t") orelse rest.len;
            draft.topic = rest[0..end];
        }
        draft.payload = std.mem.trim(u8, rest[end..], " \t");
        if (encoded) {
            const decoder = std.base64.standard.Decoder;
            const size = decoder.calcSizeForSlice(draft.payload) catch {
                self.complain("-b says the payload is base64, and this is not", .{});
                return error.Driver;
            };
            const bytes = try self.replies.allocator().alloc(u8, size);
            decoder.decode(bytes, draft.payload) catch {
                self.complain("-b says the payload is base64, and this is not", .{});
                return error.Driver;
            };
            draft.payload = bytes;
        }
        return draft;
    }

    // ------------------------------------------------------------ what there is

    pub fn objects(self: *Db, arena: std.mem.Allocator, _: []const u8) db.Error![]db.Object {
        self.begin();
        self.hold();
        defer self.release();
        const list = try arena.alloc(db.Object, 4);
        list[0] = .{ .name = TOPICS, .rows = @intCast(self.topics.count()) };
        // The log and the broker's own figures are shown and not dumped: a dump
        // is what the broker holds, and replaying one should not send every
        // message that ever went by a second time.
        list[1] = .{ .name = MESSAGES, .rows = @intCast(self.messages.items.len - self.first), .internal = true };
        list[2] = .{ .name = SUBSCRIPTIONS, .rows = @intCast(self.subscriptions.items.len) };
        list[3] = .{ .name = SYS, .rows = @intCast(self.sys.count()), .internal = true };
        return list;
    }

    pub fn schemas(_: *Db, arena: std.mem.Allocator) db.Error![][]const u8 {
        return arena.alloc([]const u8, 0);
    }

    pub fn columns(_: *Db, arena: std.mem.Allocator, wanted: db.Table) db.Error![]db.Column {
        const table = Table.of(wanted.name) orelse return arena.alloc(db.Column, 0);
        const fields = table.fields();
        const list = try arena.alloc(db.Column, fields.len);
        for (fields, 0..) |field, at| {
            list[at] = .{
                .name = field.name,
                .type = field.type,
                .notnull = field.key,
                .pk = field.key,
                .dflt = field.default,
            };
        }
        return list;
    }

    pub fn indexes(_: *Db, arena: std.mem.Allocator, _: db.Table) db.Error![]db.Index {
        return arena.alloc(db.Index, 0);
    }

    pub fn foreignKeys(_: *Db, arena: std.mem.Allocator, _: db.Table) db.Error![]db.ForeignKey {
        return arena.alloc(db.ForeignKey, 0);
    }

    pub fn definition(_: *Db, _: std.mem.Allocator, _: db.Table) db.Error!?[]const u8 {
        return null;
    }

    pub fn rowCount(self: *Db, wanted: db.Table) ?i64 {
        const table = Table.of(wanted.name) orelse return null;
        self.hold();
        defer self.release();
        return @intCast(switch (table) {
            .topics => self.topics.count(),
            .messages => self.messages.items.len - self.first,
            .subscriptions => self.subscriptions.items.len,
            .sys => self.sys.count(),
        });
    }

    pub fn rowKey(_: *Db, arena: std.mem.Allocator, wanted: db.Table) db.Error!db.RowKey {
        const table = Table.of(wanted.name) orelse return .{};
        const list = try arena.alloc([]const u8, 1);
        for (table.fields()) |field| {
            if (field.key) {
                list[0] = field.name;
            }
        }
        return .{ .columns = list };
    }

    pub fn alterContext(_: *Db, _: std.mem.Allocator, _: db.Table, _: []const db.Column) db.Error!db.AlterContext {
        return .{};
    }

    pub fn settings(self: *Db, arena: std.mem.Allocator) db.Error![]db.Setting {
        var list: std.ArrayList(db.Setting) = .empty;
        try list.append(arena, .{ .label = "broker", .value = try arena.dupe(u8, self.label.items) });
        try list.append(arena, .{ .label = "protocol", .value = if (self.tls) "MQTT 3.1.1 over TLS" else "MQTT 3.1.1" });
        try list.append(arena, .{ .label = "client id", .value = try arena.dupe(u8, self.client.items) });
        if (self.user.items.len != 0) {
            try list.append(arena, .{ .label = "user", .value = try arena.dupe(u8, self.user.items) });
        }
        try list.append(arena, .{ .label = "keep alive", .value = try arena.print("{d} s", .{self.keepalive}) });

        self.hold();
        defer self.release();
        try list.append(arena, .{
            .label = "connection",
            .value = if (self.lost.items.len != 0) try arena.print("lost: {s}", .{self.lost.items}) else "up",
        });
        for (self.subscriptions.items) |subscription| {
            try list.append(arena, .{
                .label = "listening to",
                .value = try arena.print("{s}  (qos {d}{s})", .{
                    subscription.filter,
                    subscription.qos,
                    if (subscription.state == .listening) "" else ", not answered yet",
                }),
            });
        }
        try list.append(arena, .{ .label = "received", .value = try arena.print("{d} message(s)", .{self.received}) });
        try list.append(arena, .{ .label = "kept", .value = try arena.print("{d} message(s), {d} bytes", .{
            self.messages.items.len - self.first,
            self.held_bytes,
        }) });
        // Said only when it is true: a log that is whole needs no remark.
        if (self.dropped != 0) {
            try list.append(arena, .{ .label = "dropped", .value = try arena.print("{d} of the oldest, to stay within {d} messages and {d} MB", .{
                self.dropped,
                self.most_messages,
                self.most_bytes >> 20,
            }) });
        }
        try list.append(arena, .{ .label = "topics", .value = try arena.print("{d}", .{self.topics.count()}) });
        if (self.untracked != 0) {
            try list.append(arena, .{ .label = "topics not kept", .value = try arena.print("{d} message(s) on topics past the first {d}", .{ self.untracked, MAX_TOPICS }) });
        }
        // And the handful of its own figures a broker is usually asked for.
        for ([_][2][]const u8{
            .{ "broker version", "$SYS/broker/version" },
            .{ "broker uptime", "$SYS/broker/uptime" },
            .{ "clients connected", "$SYS/broker/clients/connected" },
            .{ "subscriptions held", "$SYS/broker/subscriptions/count" },
            .{ "retained held", "$SYS/broker/retained messages/count" },
        }) |fact| {
            if (self.sys.get(fact[1])) |heard| {
                if (typed.readable(heard.payload)) {
                    try list.append(arena, .{ .label = fact[0], .value = try arena.dupe(u8, heard.payload) });
                }
            }
        }
        return list.items;
    }

    /// One command per line, as the console takes them. Lines and not
    /// semicolons: a payload is the rest of its line and may well hold one.
    pub fn split(_: *Db, arena: std.mem.Allocator, sql: []const u8) db.Error![]db.Statement {
        var list: std.ArrayList(db.Statement) = .empty;
        var lines = std.mem.splitScalar(u8, sql, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len != 0 and !std.mem.startsWith(u8, line, "--")) {
                try list.append(arena, .{ .sql = try arena.dupe(u8, line) });
            }
        }
        return list.items;
    }

    /// The verbs that only look, which are the ones a grid may be filled from
    /// again on a clock.
    pub fn repeatable(_: *Db, statement: []const u8) bool {
        var words = std.mem.tokenizeAny(u8, statement, " \t\r\n");
        const verb = words.next() orelse return false;
        for ([_][]const u8{ "TOPICS", "MESSAGES", "SUBSCRIPTIONS", "SYS", "STATUS" }) |reading| {
            if (eq(verb, reading)) {
                return true;
            }
        }
        return false;
    }

    pub fn ddl(_: *Db) db.Ddl {
        return .{ .mqtt = .{} };
    }

    pub fn inTransaction(_: *Db) bool {
        return false;
    }
};

// ---------------------------------------------------------------- the tables

/// One value as it is kept: a time and a yes-or-no are numbers until they are
/// drawn, because that is what they are compared as.
const Cell = union(enum) {
    nil: void,
    text: []const u8,
    number: i64,
};

/// One of the tables, as something that can be asked for a cell. Made and read
/// with the mutex held: what it hands out points into what the thread writes.
const Source = struct {
    owner: *Db,
    table: Table,
    /// For the two tables that are kept under a name: the names, in order.
    entries: []const Heardmap.Entry = &.{},

    fn of(owner: *Db, arena: std.mem.Allocator, table: Table) !Source {
        var self = Source{ .owner = owner, .table = table };
        if (table == .topics or table == .sys) {
            const map = if (table == .topics) &owner.topics else &owner.sys;
            const list = try arena.alloc(Heardmap.Entry, map.count());
            var walk = map.iterator();
            var at: usize = 0;
            while (walk.next()) |entry| : (at += 1) {
                list[at] = entry;
            }
            std.mem.sort(Heardmap.Entry, list, {}, byName);
            self.entries = list;
        }
        return self;
    }

    fn byName(_: void, left: Heardmap.Entry, right: Heardmap.Entry) bool {
        return std.mem.lessThan(u8, left.key_ptr.*, right.key_ptr.*);
    }

    fn len(self: Source) usize {
        return switch (self.table) {
            .topics, .sys => self.entries.len,
            .messages => self.owner.messages.items.len - self.owner.first,
            .subscriptions => self.owner.subscriptions.items.len,
        };
    }

    fn cell(self: Source, row: usize, column: usize) Cell {
        switch (self.table) {
            .topics => {
                const entry = self.entries[row];
                return switch (column) {
                    0 => .{ .text = entry.key_ptr.* },
                    1 => .{ .text = entry.value_ptr.payload },
                    2 => .{ .number = @intFromBool(entry.value_ptr.retained) },
                    3 => .{ .number = entry.value_ptr.qos },
                    4 => .{ .number = entry.value_ptr.count },
                    else => .{ .number = entry.value_ptr.at },
                };
            },
            .sys => {
                const entry = self.entries[row];
                return switch (column) {
                    0 => .{ .text = entry.key_ptr.* },
                    1 => .{ .text = entry.value_ptr.payload },
                    else => .{ .number = entry.value_ptr.at },
                };
            },
            .messages => {
                const kept = self.owner.messages.items[self.owner.first + row];
                return switch (column) {
                    0 => .{ .number = kept.n },
                    1 => .{ .number = kept.at },
                    2 => .{ .text = kept.topic() },
                    3 => .{ .text = kept.payload() },
                    4 => .{ .number = kept.qos },
                    else => .{ .number = @intFromBool(kept.retained) },
                };
            },
            .subscriptions => {
                const subscription = self.owner.subscriptions.items[row];
                return switch (column) {
                    0 => .{ .text = subscription.filter },
                    1 => .{ .number = subscription.qos },
                    else => .{ .text = switch (subscription.state) {
                        .asked => "asked",
                        .listening => "listening",
                        .refused => "refused",
                    } },
                };
            },
        }
    }
};

/// Sorting by one column: numbers as numbers, text as bytes, nothing first.
const Order = struct {
    source: Source,
    column: usize,

    fn before(self: Order, left_row: u32, right_row: u32) bool {
        const left = self.source.cell(left_row, self.column);
        const right = self.source.cell(right_row, self.column);
        return switch (left) {
            .nil => right != .nil,
            .number => |a| switch (right) {
                .number => |b| a < b,
                .nil => false,
                .text => true,
            },
            .text => |a| switch (right) {
                .text => |b| std.mem.lessThan(u8, a, b),
                else => false,
            },
        };
    }
};

/// Whether a row is one the request asks for.
fn passes(source: Source, row: usize, request: db.ask.Select) bool {
    if (request.where_text.len != 0 and !found(source, row, request.where_text)) {
        return false;
    }
    if (request.where.len == 0) {
        return true;
    }
    const fields = source.table.fields();
    for (request.where) |filter| {
        const ok = if (source.table.fieldAt(filter.column)) |column|
            holds(filter, source.cell(row, column), fields[column])
        else
            false;
        if (request.any) {
            if (ok) {
                return true;
            }
        } else if (!ok) {
            return false;
        }
    }
    return !request.any;
}

/// What somebody typed into the filter row, which on a database is SQL and
/// here is one of two things: a topic filter where it has a `+` or a `#` in
/// it, and otherwise a word to look for in every text of the row.
fn found(source: Source, row: usize, wanted: []const u8) bool {
    const fields = source.table.fields();
    if (std.mem.findAny(u8, wanted, "+#") != null and wire.filterFault(wanted) == null) {
        for (fields, 0..) |field, column| {
            if (field.key or std.mem.eql(u8, field.name, "topic")) {
                switch (source.cell(row, column)) {
                    .text => |text| if (wire.matches(wanted, text)) return true,
                    else => {},
                }
            }
        }
        return false;
    }
    for (fields, 0..) |field, column| {
        if (field.shape != .text) {
            continue;
        }
        switch (source.cell(row, column)) {
            .text => |text| if (std.ascii.findIgnoreCase(text, wanted) != null) return true,
            else => {},
        }
    }
    return false;
}

fn holds(filter: db.ask.Filter, cell: Cell, field: Field) bool {
    var buffer: [40]u8 = undefined;
    const text = written(&buffer, cell, field.shape);
    switch (filter.op) {
        .is_null => return cell == .nil,
        .not_null => return cell != .nil,
        .eq => return same(filter.value, cell, text, field),
        .ne => return !same(filter.value, cell, text, field),
        .like => return kafka.likeMatch(filter.value, text),
        .lt, .le, .gt, .ge => {
            const order = switch (cell) {
                .number => |number| if (field.shape == .number)
                    std.math.order(number, std.fmt.parseInt(i64, std.mem.trim(u8, filter.value, " "), 10) catch return false)
                else
                    std.mem.order(u8, text, filter.value),
                else => std.mem.order(u8, text, filter.value),
            };
            return switch (filter.op) {
                .lt => order == .lt,
                .le => order != .gt,
                .gt => order == .gt,
                else => order != .lt,
            };
        },
    }
}

fn same(wanted: []const u8, cell: Cell, text: []const u8, field: Field) bool {
    switch (cell) {
        .number => |number| switch (field.shape) {
            .flag => return (truthy(wanted) orelse return false) == (number != 0),
            .number => return (std.fmt.parseInt(i64, std.mem.trim(u8, wanted, " "), 10) catch return false) == number,
            else => {},
        },
        else => {},
    }
    // A topic may be asked for the way a subscription asks for one.
    if (std.mem.eql(u8, field.name, "topic") and std.mem.findAny(u8, wanted, "+#") != null and wire.filterFault(wanted) == null) {
        return wire.matches(wanted, text);
    }
    return std.mem.eql(u8, text, wanted);
}

/// A cell as text, for comparing: a number as its digits, a time as it is drawn.
fn written(buffer: *[40]u8, cell: Cell, shape: Shape) []const u8 {
    return switch (cell) {
        .nil => "",
        .text => |text| text,
        .number => |number| switch (shape) {
            .flag => if (number != 0) "yes" else "no",
            .time => stamp(buffer, number),
            else => std.mem.print(buffer, "{d}", .{number}) catch "",
        },
    };
}

/// A cell as the grid gets it, copied out of what the thread may change next.
fn shown(arena: std.mem.Allocator, cell: Cell, shape: Shape) !Value {
    var buffer: [40]u8 = undefined;
    return switch (cell) {
        .nil => .{ .nil = {} },
        .text => |text| .{ .text = try arena.dupe(u8, text) },
        .number => |number| switch (shape) {
            .number, .text => .{ .number = number },
            else => .{ .text = try arena.dupe(u8, written(&buffer, cell, shape)) },
        },
    };
}

/// When a message arrived, in UTC and to the millisecond - the way a Kafka
/// record's timestamp is drawn, so the two read alike.
fn stamp(buffer: *[40]u8, millis: i64) []const u8 {
    if (millis <= 0) {
        return "";
    }
    const seconds: u64 = @intCast(@divFloor(millis, 1000));
    const epoch = std.time.epoch.EpochSeconds{ .secs = seconds };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const time = epoch.getDaySeconds();
    return std.mem.print(buffer, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        time.getHoursIntoDay(),
        time.getMinutesIntoHour(),
        time.getSecondsIntoMinute(),
        @as(u64, @intCast(@mod(millis, 1000))),
    }) catch "";
}

// ------------------------------------------------------------------- the words

/// A message as a form or a line describes it.
const Draft = struct {
    topic: []const u8 = "",
    payload: []const u8 = "",
    retained: bool = false,
    qos: u2 = 0,
};

/// `PUBLISH`, written so that the console reads it back as the same message. A
/// payload that would not survive being the rest of a line - a line break in
/// it, a space at either end, bytes that are not text - goes as base64.
fn writePublish(out: *List, allocator: std.mem.Allocator, draft: Draft) !void {
    try out.appendSlice(allocator, "PUBLISH ");
    if (draft.retained) {
        try out.appendSlice(allocator, "-r ");
    }
    if (draft.qos != 0) {
        try out.print(allocator, "-q {d} ", .{draft.qos});
    }
    const payload = draft.payload;
    const plain = typed.readable(payload) and
        std.mem.findAny(u8, payload, "\r\n") == null and
        std.mem.trim(u8, payload, " \t").len == payload.len;
    if (!plain) {
        try out.appendSlice(allocator, "-b ");
    }
    if (draft.topic.len != 0 and draft.topic[0] == '-' and std.mem.findAny(u8, draft.topic, " \t'") == null) {
        // In quotes, or it would be read back as one of the options above.
        try out.print(allocator, "'{s}'", .{draft.topic});
    } else {
        try typed.word(out, allocator, draft.topic);
    }
    if (payload.len == 0) {
        return;
    }
    try out.append(allocator, ' ');
    if (plain) {
        try out.appendSlice(allocator, payload);
    } else {
        const encoder = std.base64.standard.Encoder;
        const start = out.items.len;
        try out.resize(allocator, start + encoder.calcSize(payload.len));
        _ = encoder.encode(out.items[start..], payload);
    }
}

fn truthy(text: []const u8) ?bool {
    const said = std.mem.trim(u8, text, " \t");
    for ([_][]const u8{ "yes", "1", "true", "y", "t", "on" }) |word| {
        if (std.ascii.eqlIgnoreCase(said, word)) {
            return true;
        }
    }
    for ([_][]const u8{ "no", "0", "false", "n", "f", "off", "" }) |word| {
        if (std.ascii.eqlIgnoreCase(said, word)) {
            return false;
        }
    }
    return null;
}

/// A quality of service for the words of a request, where a wrong one is
/// already somebody else's complaint.
fn digit(text: ?[]const u8) u2 {
    const said = std.mem.trim(u8, text orelse return 0, " \t");
    return if (said.len == 1 and said[0] >= '0' and said[0] <= '2') @intCast(said[0] - '0') else 0;
}

/// An argument out of its quotes, where it came in some.
fn unquoted(text: []const u8) []const u8 {
    if (text.len >= 2 and (text[0] == '"' or text[0] == '\'') and text[text.len - 1] == text[0]) {
        return text[1 .. text.len - 1];
    }
    return text;
}

fn eq(left: []const u8, right: []const u8) bool {
    return std.ascii.eqlIgnoreCase(left, right);
}

fn flat(value: ??[]const u8) ?[]const u8 {
    const inner = value orelse return null;
    return inner orelse null;
}

/// Reach the broker again at the address it was last at, and give up after
/// `REDIAL_MS` rather than when the system does: this runs on the thread that
/// draws, and a host that has gone silent takes the system over a minute.
fn redial(peer: *const std.c.sockaddr.storage, len: std.c.socklen_t) !std.c.fd_t {
    if (len == 0) {
        return error.Refused;
    }
    const fd = std.c.socket(@intCast(peer.family), std.c.SOCK.STREAM, 0);
    if (fd < 0) {
        return error.Refused;
    }
    errdefer _ = std.c.close(fd);
    const flags = std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0));
    const nonblocking: c_int = @bitCast(@as(u32, @bitCast(std.c.O{ .NONBLOCK = true })));
    _ = std.c.fcntl(fd, std.c.F.SETFL, flags | nonblocking);
    if (std.c.connect(fd, @ptrCast(peer), len) != 0) {
        if (std.c._errno().* != @backingInt(std.c.E.INPROGRESS)) {
            return error.Refused;
        }
        var fds = [1]std.c.pollfd{.{ .fd = fd, .events = std.c.POLL.OUT, .revents = 0 }};
        if (std.c.poll(&fds, 1, REDIAL_MS) <= 0) {
            return error.Refused;
        }
        var failed: c_int = 0;
        var size: std.c.socklen_t = @sizeOf(c_int);
        if (std.c.getsockopt(fd, std.c.SOL.SOCKET, std.c.SO.ERROR, &failed, &size) != 0 or failed != 0) {
            return error.Refused;
        }
    }
    _ = std.c.fcntl(fd, std.c.F.SETFL, flags);
    return fd;
}

// -------------------------------------------------------------------------- DDL

/// A broker has no schema to change, so every one of these is a comment saying
/// so - the arrangement Redis has, for the same reason.
pub const Ddl = struct {
    pub fn types(_: Ddl) []const []const u8 {
        return &[_][]const u8{ "text", "bytes", "int", "bool", "timestamp" };
    }

    fn refuse(out: *List, a: std.mem.Allocator, what: []const u8) !void {
        try out.print(a, "-- a broker has no {s}\n", .{what});
    }

    pub fn createTable(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table, _: []const db.Column, _: []const db.ForeignKey) !void {
        try refuse(out, a, "tables to create: a topic is there while somebody publishes to it");
    }

    pub fn alterTable(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table, _: []const u8, _: []const db.Column, _: db.AlterContext) !void {
        try refuse(out, a, "columns to alter");
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

    pub fn dropObject(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Kind, _: db.Table) !void {
        try refuse(out, a, "tables to drop");
    }

    pub fn truncate(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table) !void {
        try refuse(out, a, "tables to empty - FORGET empties what is kept here");
    }
};

// -------------------------------------------------------------------- tests
//
// Against a broker that is forty lines of this file: the other end of a socket
// pair, answering the way the standard says a broker answers. Enough of one
// that the driver is tested whole - connect, subscribe, the retained messages,
// a message out and its echo back, all three qualities of service - without a
// container, on every machine the unit tests run on.

const testing = std.testing;

const Broker = struct {
    fd: std.c.fd_t,
    thread: ?std.Thread = null,
    /// What it holds for whoever subscribes: topic, payload.
    held: std.ArrayList([2][]u8) = .empty,
    filters: std.ArrayList(Listening) = .empty,
    /// What it says to CONNECT, and the one filter it will not grant.
    connack: u8 = 0,
    denies: []const u8 = "",
    most_qos: u2 = 2,
    next_id: u16 = 100,
    /// What CONNECT said, for the tests that ask.
    greeted_with_password: bool = false,

    const Listening = struct { filter: []u8, qos: u2 };
    /// Its own memory, apart from the allocator that counts the driver's leaks.
    const a = std.heap.c_allocator;

    fn hold(self: *Broker, topic: []const u8, payload: []const u8) !void {
        try self.held.append(a, .{ try a.dupe(u8, topic), try a.dupe(u8, payload) });
    }

    fn holds(self: *Broker, topic: []const u8) ?[]const u8 {
        for (self.held.items) |pair| {
            if (std.mem.eql(u8, pair[0], topic)) {
                return pair[1];
            }
        }
        return null;
    }

    fn run(self: *Broker) void {
        var inbox: List = .empty;
        defer inbox.deinit(a);
        var chunk: [4096]u8 = undefined;
        while (true) {
            const got = std.c.recv(self.fd, &chunk, chunk.len, 0);
            if (got <= 0) {
                return;
            }
            inbox.appendSlice(a, chunk[0..@intCast(got)]) catch return;
            var at: usize = 0;
            while (wire.take(inbox.items[at..]) catch return) |packet| {
                self.handle(packet) catch return;
                at += packet.size;
            }
            inbox.replaceRangeAssumeCapacity(0, at, "");
        }
    }

    fn send(self: *Broker, bytes: []const u8) void {
        _ = std.c.send(self.fd, bytes.ptr, bytes.len, 0);
    }

    fn deliver(self: *Broker, topic: []const u8, payload: []const u8, qos: u2, retain: bool) !void {
        var out: List = .empty;
        defer out.deinit(a);
        self.next_id += 1;
        try wire.publish(&out, a, .{ .topic = topic, .payload = payload, .qos = qos, .retain = retain, .id = self.next_id });
        self.send(out.items);
    }

    fn handle(self: *Broker, packet: wire.Packet) !void {
        switch (packet.kind) {
            .connect => {
                self.greeted_with_password = packet.body[7] & 0x40 != 0;
                self.send(&.{ 0x20, 2, 0, self.connack });
            },
            .subscribe => {
                const id = try wire.readId(packet);
                const length = (@as(usize, packet.body[2]) << 8) | packet.body[3];
                const filter = packet.body[4 .. 4 + length];
                const asked: u2 = @intCast(packet.body[4 + length]);
                if (self.denies.len != 0 and std.mem.eql(u8, filter, self.denies)) {
                    self.send(&.{ 0x90, 3, @intCast(id >> 8), @truncate(id), 0x80 });
                    return;
                }
                const granted = @min(asked, self.most_qos);
                for (self.filters.items, 0..) |listening, at| {
                    if (std.mem.eql(u8, listening.filter, filter)) {
                        _ = self.filters.orderedRemove(at);
                        break;
                    }
                }
                try self.filters.append(a, .{ .filter = try a.dupe(u8, filter), .qos = granted });
                self.send(&.{ 0x90, 3, @intCast(id >> 8), @truncate(id), granted });
                for (self.held.items) |pair| {
                    if (wire.matches(filter, pair[0])) {
                        try self.deliver(pair[0], pair[1], 0, true);
                    }
                }
            },
            .unsubscribe => {
                const id = try wire.readId(packet);
                const length = (@as(usize, packet.body[2]) << 8) | packet.body[3];
                const filter = packet.body[4 .. 4 + length];
                for (self.filters.items, 0..) |listening, at| {
                    if (std.mem.eql(u8, listening.filter, filter)) {
                        _ = self.filters.orderedRemove(at);
                        break;
                    }
                }
                self.send(&.{ 0xb0, 2, @intCast(id >> 8), @truncate(id) });
            },
            .publish => {
                const arrived = try wire.readPublish(packet);
                var out: List = .empty;
                defer out.deinit(a);
                if (arrived.qos == 1) {
                    try wire.acknowledge(&out, a, .puback, arrived.id);
                } else if (arrived.qos == 2) {
                    try wire.acknowledge(&out, a, .pubrec, arrived.id);
                }
                self.send(out.items);
                if (arrived.retain) {
                    for (self.held.items, 0..) |pair, at| {
                        if (std.mem.eql(u8, pair[0], arrived.topic)) {
                            _ = self.held.orderedRemove(at);
                            break;
                        }
                    }
                    if (arrived.payload.len != 0) {
                        try self.hold(arrived.topic, arrived.payload);
                    }
                }
                // To every subscriber, which is the one there is - and not marked
                // retained, which is what a broker does with a message as it
                // passes it on.
                for (self.filters.items) |listening| {
                    if (wire.matches(listening.filter, arrived.topic)) {
                        try self.deliver(arrived.topic, arrived.payload, @min(arrived.qos, listening.qos), false);
                        break;
                    }
                }
            },
            .pubrel, .pubrec => {
                var out: List = .empty;
                defer out.deinit(a);
                try wire.acknowledge(&out, a, if (packet.kind == .pubrel) .pubcomp else .pubrel, try wire.readId(packet));
                self.send(out.items);
            },
            .pingreq => self.send(&.{ 0xd0, 0 }),
            .disconnect => return error.Done,
            else => {},
        }
    }
};

/// A broker on one end of a pair and the driver on the other.
const Bench = struct {
    broker: *Broker,
    client: std.c.fd_t,
    conn: ?*Db = null,
    report: List = .empty,
    arena: std.heap.ArenaAllocator,

    fn init() !Bench {
        var pair: [2]std.c.fd_t = undefined;
        try testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &pair));
        const broker = try Broker.a.create(Broker);
        broker.* = .{ .fd = pair[1] };
        return .{ .broker = broker, .client = pair[0], .arena = .init(testing.allocator) };
    }

    /// Connect, with the broker listening from here on.
    fn connect(self: *Bench, parts: Parts) !*Db {
        self.broker.thread = try std.Thread.spawn(.{}, Broker.run, .{self.broker});
        self.conn = Db.attach(testing.allocator, .{ .fd = self.client }, parts, &self.report) catch |err| {
            self.client = -1;
            return err;
        };
        self.client = -1;
        return self.conn.?;
    }

    fn deinit(self: *Bench) void {
        if (self.conn) |conn| {
            conn.close();
        }
        if (self.client >= 0) {
            _ = std.c.close(self.client);
        }
        if (self.broker.thread) |thread| {
            thread.join();
        }
        _ = std.c.close(self.broker.fd);
        self.report.deinit(testing.allocator);
        self.arena.deinit();
    }

    /// Every row a request comes to, each cell as text.
    fn grid(self: *Bench, request: db.ask.Select) ![]const []const []const u8 {
        const arena = self.arena.allocator();
        var rows = (try self.conn.?.select(request)).?;
        defer rows.close();
        var out: std.ArrayList([]const []const u8) = .empty;
        while (try rows.next()) {
            const cells = try arena.alloc([]const u8, rows.columnCount());
            for (cells, 0..) |*cell, at| {
                cell.* = switch (rows.value(at)) {
                    .null => "NULL",
                    .text, .blob => |bytes| try arena.dupe(u8, bytes),
                    .int => |number| try arena.print("{d}", .{number}),
                    .float => |number| try arena.print("{d}", .{number}),
                };
            }
            try out.append(arena, cells);
        }
        return out.items;
    }

    fn table(self: *Bench, name: []const u8) ![]const []const []const u8 {
        return self.grid(.{ .table = .{ .name = name } });
    }

    /// What a console line answers with, as its first cell.
    fn run(self: *Bench, line: []const u8) ![]const u8 {
        var rows = (try self.conn.?.query(line, null)).?;
        defer rows.close();
        try testing.expect(try rows.next());
        return switch (rows.value(0)) {
            .text => |text| try self.arena.allocator().dupe(u8, text),
            else => "",
        };
    }
};

const EVERYTHING = Parts{ .host = "broker.test", .client = "test" };

test "what the broker holds is in the tables a moment after connecting" {
    var bench = try Bench.init();
    defer bench.deinit();
    try bench.broker.hold("dum/kuchyn/teplota", "21.5");
    try bench.broker.hold("dum/lampa", "on");
    try bench.broker.hold("$SYS/broker/version", "the one in the tests");
    const conn = try bench.connect(EVERYTHING);

    const topics = try bench.table(TOPICS);
    try testing.expectEqual(@as(usize, 2), topics.len);
    // In the order of their names, each with what was last said and that the
    // broker was holding it.
    try testing.expectEqualStrings("dum/kuchyn/teplota", topics[0][0]);
    try testing.expectEqualStrings("21.5", topics[0][1]);
    try testing.expectEqualStrings("yes", topics[0][2]);
    try testing.expectEqualStrings("1", topics[0][4]);
    try testing.expectEqualStrings("dum/lampa", topics[1][0]);

    const messages = try bench.table(MESSAGES);
    try testing.expectEqual(@as(usize, 2), messages.len);
    try testing.expectEqualStrings("1", messages[0][0]);
    try testing.expectEqualStrings("yes", messages[0][5]);
    // A time, and this century's.
    try testing.expect(std.mem.startsWith(u8, messages[0][1], "20"));
    try testing.expectEqual(@as(usize, 23), messages[0][1].len);

    // What the broker says about itself is apart from what goes through it.
    const sys = try bench.table(SYS);
    try testing.expectEqual(@as(usize, 1), sys.len);
    try testing.expectEqualStrings("the one in the tests", sys[0][1]);
    try testing.expectEqualStrings("MQTT 3.1.1, the one in the tests", conn.version());

    const subscriptions = try bench.table(SUBSCRIPTIONS);
    try testing.expectEqual(@as(usize, 2), subscriptions.len);
    try testing.expectEqualStrings("#", subscriptions[0][0]);
    try testing.expectEqualStrings("2", subscriptions[0][1]);
    try testing.expectEqualStrings("listening", subscriptions[0][2]);
    try testing.expectEqualStrings("$SYS/#", subscriptions[1][0]);

    try testing.expectEqual(@as(?i64, 2), conn.rowCount(.{ .name = TOPICS }));
    try testing.expectEqual(@as(?i64, null), conn.rowCount(.{ .name = "orders" }));
    try testing.expectError(error.Driver, conn.select(.{ .table = .{ .name = "orders" } }));
}

test "a target that names a filter listens to that and nothing else" {
    var bench = try Bench.init();
    defer bench.deinit();
    try bench.broker.hold("dum/kuchyn/teplota", "21.5");
    try bench.broker.hold("garaz/vrata", "closed");
    try bench.broker.hold("$SYS/broker/version", "not asked for");
    _ = try bench.connect(.{ .host = "broker.test", .client = "test", .filter = "dum/#" });
    try testing.expectEqual(@as(usize, 1), (try bench.table(TOPICS)).len);
    try testing.expectEqual(@as(usize, 1), (try bench.table(SUBSCRIPTIONS)).len);
    try testing.expectEqual(@as(usize, 0), (try bench.table(SYS)).len);
}

test "a new row is a message, at each quality of service, and it comes back" {
    var bench = try Bench.init();
    defer bench.deinit();
    const conn = try bench.connect(EVERYTHING);
    try conn.apply(.{ .kind = .insert, .table = .{ .name = MESSAGES }, .cells = &.{
        .{ .column = "topic", .value = "dum/lampa" },
        .{ .column = "payload", .value = "on" },
    } });
    try conn.apply(.{ .kind = .insert, .table = .{ .name = TOPICS }, .cells = &.{
        .{ .column = "topic", .value = "dum/lampa" },
        .{ .column = "payload", .value = "off" },
        .{ .column = "qos", .value = "1" },
    } });
    try conn.apply(.{ .kind = .insert, .table = .{ .name = MESSAGES }, .cells = &.{
        .{ .column = "topic", .value = "dum/zvonek" },
        .{ .column = "payload", .value = null },
        .{ .column = "qos", .value = "2" },
        .{ .column = "retained", .value = "yes" },
    } });

    const messages = try bench.table(MESSAGES);
    try testing.expectEqual(@as(usize, 3), messages.len);
    try testing.expectEqualStrings("on", messages[0][3]);
    try testing.expectEqualStrings("0", messages[0][4]);
    try testing.expectEqualStrings("off", messages[1][3]);
    try testing.expectEqualStrings("1", messages[1][4]);
    // Nothing is a payload, and the quality it was sent with is the one shown.
    try testing.expectEqualStrings("dum/zvonek", messages[2][2]);
    try testing.expectEqualStrings("", messages[2][3]);
    try testing.expectEqualStrings("2", messages[2][4]);

    const topics = try bench.table(TOPICS);
    try testing.expectEqual(@as(usize, 2), topics.len);
    try testing.expectEqualStrings("off", topics[0][1]);
    try testing.expectEqualStrings("2", topics[0][4]);

    // What cannot be a message says why, before anything is sent.
    try testing.expectError(error.Driver, conn.apply(.{ .kind = .insert, .table = .{ .name = MESSAGES }, .cells = &.{
        .{ .column = "topic", .value = "dum/+" },
    } }));
    try testing.expect(std.mem.find(u8, conn.message(), "subscribing") != null);
    try testing.expectError(error.Driver, conn.apply(.{ .kind = .insert, .table = .{ .name = MESSAGES }, .cells = &.{
        .{ .column = "topic", .value = "a" },
        .{ .column = "qos", .value = "3" },
    } }));
    try testing.expectError(error.Driver, conn.apply(.{ .kind = .insert, .table = .{ .name = MESSAGES }, .cells = &.{
        .{ .column = "topic", .value = "a" },
        .{ .column = "retained", .value = "maybe" },
    } }));
    try testing.expectEqual(@as(usize, 3), (try bench.table(MESSAGES)).len);
}

test "changing a topic's payload publishes it, and deleting the row clears what the broker holds" {
    var bench = try Bench.init();
    defer bench.deinit();
    try bench.broker.hold("dum/termostat", "20");
    const conn = try bench.connect(EVERYTHING);

    // Held by the broker, so the new value is given to it to hold as well.
    try conn.apply(.{
        .kind = .update,
        .table = .{ .name = TOPICS },
        .cells = &.{.{ .column = "payload", .value = "22" }},
        .where = &.{.{ .column = "topic", .value = "dum/termostat" }},
    });
    try testing.expectEqualStrings("22", bench.broker.holds("dum/termostat").?);
    const topics = try bench.table(TOPICS);
    try testing.expectEqualStrings("22", topics[0][1]);
    try testing.expectEqualStrings("yes", topics[0][2]);

    // What goes out is what the words say: held, because the row was.
    const a = bench.arena.allocator();
    try testing.expectEqualStrings("PUBLISH -r -q 1 dum/termostat 22", try conn.wording(a, .{ .change = .{
        .kind = .update,
        .table = .{ .name = TOPICS },
        .cells = &.{.{ .column = "qos", .value = "1" }},
        .where = &.{.{ .column = "topic", .value = "dum/termostat" }},
    } }));
    try testing.expectEqualStrings("PUBLISH -r dum/termostat 23", try conn.wording(a, .{ .change = .{
        .kind = .update,
        .table = .{ .name = TOPICS },
        .cells = &.{.{ .column = "payload", .value = "23" }},
        .where = &.{.{ .column = "topic", .value = "dum/termostat" }},
    } }));
    try testing.expectEqualStrings("PUBLISH dum/termostat 22", try conn.wording(a, .{ .change = .{
        .kind = .update,
        .table = .{ .name = TOPICS },
        .cells = &.{.{ .column = "retained", .value = "no" }},
        .where = &.{.{ .column = "topic", .value = "dum/termostat" }},
    } }));

    // An edit is a message, so an edit of what is only counted here is refused
    // rather than taken as a reason to send the payload again.
    const heard = (try bench.table(MESSAGES)).len;
    for ([_][]const u8{ "messages", "time" }) |counted| {
        try testing.expectError(error.Driver, conn.apply(.{
            .kind = .update,
            .table = .{ .name = TOPICS },
            .cells = &.{.{ .column = counted, .value = "5" }},
            .where = &.{.{ .column = "topic", .value = "dum/termostat" }},
        }));
        try testing.expect(std.mem.find(u8, conn.message(), "is counted here, not set") != null);
    }
    clock.sleep(60);
    try testing.expectEqual(heard, (try bench.table(MESSAGES)).len);

    // A topic is its name, and a message that was sent is sent.
    try testing.expectError(error.Driver, conn.apply(.{
        .kind = .update,
        .table = .{ .name = TOPICS },
        .cells = &.{.{ .column = "topic", .value = "dum/jiny" }},
        .where = &.{.{ .column = "topic", .value = "dum/termostat" }},
    }));
    try testing.expectError(error.Driver, conn.apply(.{
        .kind = .update,
        .table = .{ .name = MESSAGES },
        .cells = &.{.{ .column = "payload", .value = "x" }},
        .where = &.{.{ .column = "n", .value = "1" }},
    }));
    try testing.expectError(error.Driver, conn.apply(.{
        .kind = .delete,
        .table = .{ .name = MESSAGES },
        .where = &.{.{ .column = "n", .value = "1" }},
    }));

    const before = (try bench.table(MESSAGES)).len;
    try conn.apply(.{
        .kind = .delete,
        .table = .{ .name = TOPICS },
        .where = &.{.{ .column = "topic", .value = "dum/termostat" }},
    });
    try testing.expect(bench.broker.holds("dum/termostat") == null);
    try testing.expectEqual(@as(usize, 0), (try bench.table(TOPICS)).len);
    // The clearing comes back from the broker like any message, and is not one.
    clock.sleep(80);
    try testing.expectEqual(before, (try bench.table(MESSAGES)).len);
    try testing.expectEqual(@as(usize, 0), (try bench.table(TOPICS)).len);

    // A topic the broker holds nothing for is only forgotten: clearing it would
    // send every subscriber a message with nothing in it.
    try conn.apply(.{ .kind = .insert, .table = .{ .name = MESSAGES }, .cells = &.{
        .{ .column = "topic", .value = "dum/zvonek" },
        .{ .column = "payload", .value = "ding" },
    } });
    const sent = (try bench.table(MESSAGES)).len;
    try conn.apply(.{
        .kind = .delete,
        .table = .{ .name = TOPICS },
        .where = &.{.{ .column = "topic", .value = "dum/zvonek" }},
    });
    clock.sleep(80);
    try testing.expectEqual(@as(usize, 0), (try bench.table(TOPICS)).len);
    try testing.expectEqual(sent, (try bench.table(MESSAGES)).len);
}

test "a subscription is a row: added, changed, refused and removed" {
    var bench = try Bench.init();
    defer bench.deinit();
    bench.broker.denies = "tajne/#";
    try bench.broker.hold("dum/lampa", "on");
    try bench.broker.hold("garaz/vrata", "closed");
    const conn = try bench.connect(.{ .host = "broker.test", .client = "test", .filter = "dum/#" });
    try testing.expectEqual(@as(usize, 1), (try bench.table(TOPICS)).len);

    try conn.apply(.{ .kind = .insert, .table = .{ .name = SUBSCRIPTIONS }, .cells = &.{
        .{ .column = "filter", .value = "garaz/#" },
        .{ .column = "qos", .value = "1" },
    } });
    // And what the broker held for it has arrived by the time that returns.
    try testing.expectEqual(@as(usize, 2), (try bench.table(TOPICS)).len);
    var subscriptions = try bench.table(SUBSCRIPTIONS);
    try testing.expectEqual(@as(usize, 2), subscriptions.len);
    try testing.expectEqualStrings("garaz/#", subscriptions[1][0]);
    try testing.expectEqualStrings("1", subscriptions[1][1]);

    // Asked for again with another quality, it is the same subscription.
    try conn.apply(.{
        .kind = .update,
        .table = .{ .name = SUBSCRIPTIONS },
        .cells = &.{.{ .column = "qos", .value = "0" }},
        .where = &.{.{ .column = "filter", .value = "garaz/#" }},
    });
    subscriptions = try bench.table(SUBSCRIPTIONS);
    try testing.expectEqual(@as(usize, 2), subscriptions.len);
    try testing.expectEqualStrings("0", subscriptions[1][1]);

    // The state is the broker's to say, and editing it asks for nothing.
    try testing.expectError(error.Driver, conn.apply(.{
        .kind = .update,
        .table = .{ .name = SUBSCRIPTIONS },
        .cells = &.{.{ .column = "state", .value = "refused" }},
        .where = &.{.{ .column = "filter", .value = "garaz/#" }},
    }));
    try testing.expectEqualStrings("0", (try bench.table(SUBSCRIPTIONS))[1][1]);

    try testing.expectError(error.Driver, conn.apply(.{ .kind = .insert, .table = .{ .name = SUBSCRIPTIONS }, .cells = &.{
        .{ .column = "filter", .value = "tajne/#" },
    } }));
    try testing.expect(std.mem.find(u8, conn.message(), "refused the subscription to tajne/#") != null);

    // One that is listening, asked for again and refused this time, is still
    // the one it was: the broker has not let go of it.
    bench.broker.denies = "garaz/#";
    try testing.expectError(error.Driver, conn.apply(.{
        .kind = .update,
        .table = .{ .name = SUBSCRIPTIONS },
        .cells = &.{.{ .column = "qos", .value = "2" }},
        .where = &.{.{ .column = "filter", .value = "garaz/#" }},
    }));
    bench.broker.denies = "tajne/#";
    subscriptions = try bench.table(SUBSCRIPTIONS);
    try testing.expectEqual(@as(usize, 2), subscriptions.len);
    try testing.expectEqualStrings("0", subscriptions[1][1]);
    try testing.expectEqualStrings("listening", subscriptions[1][2]);
    try testing.expectError(error.Driver, conn.apply(.{ .kind = .insert, .table = .{ .name = SUBSCRIPTIONS }, .cells = &.{
        .{ .column = "filter", .value = "a/#/b" },
    } }));
    try testing.expectEqual(@as(usize, 2), (try bench.table(SUBSCRIPTIONS)).len);

    try conn.apply(.{
        .kind = .delete,
        .table = .{ .name = SUBSCRIPTIONS },
        .where = &.{.{ .column = "filter", .value = "garaz/#" }},
    });
    try testing.expectEqual(@as(usize, 1), (try bench.table(SUBSCRIPTIONS)).len);
    // No longer listened to, so a message there does not come back.
    try conn.apply(.{ .kind = .insert, .table = .{ .name = MESSAGES }, .cells = &.{
        .{ .column = "topic", .value = "garaz/vrata" },
        .{ .column = "payload", .value = "open" },
    } });
    clock.sleep(80);
    const garage = try bench.grid(.{ .table = .{ .name = TOPICS }, .where = &.{.{ .column = "topic", .value = "garaz/vrata" }} });
    try testing.expectEqualStrings("closed", garage[0][1]);
    try testing.expectError(error.Driver, conn.apply(.{
        .kind = .delete,
        .table = .{ .name = SUBSCRIPTIONS },
        .where = &.{.{ .column = "filter", .value = "garaz/#" }},
    }));
}

test "rows are filtered, sorted, counted and paged out of what was heard" {
    var bench = try Bench.init();
    defer bench.deinit();
    try bench.broker.hold("dum/kuchyn/teplota", "21");
    try bench.broker.hold("dum/loznice/teplota", "18");
    try bench.broker.hold("dum/loznice/svetlo", "off");
    try bench.broker.hold("garaz/vrata", "Closed");
    _ = try bench.connect(EVERYTHING);
    const all = db.Table{ .name = TOPICS };

    // The way a subscription asks, in a condition and typed into the filter row.
    try testing.expectEqual(@as(usize, 2), (try bench.grid(.{ .table = all, .where = &.{.{ .column = "topic", .value = "dum/+/teplota" }} })).len);
    try testing.expectEqual(@as(usize, 3), (try bench.grid(.{ .table = all, .where_text = "dum/#" })).len);
    // A word typed there is looked for in the topic and in the payload, in any case.
    try testing.expectEqual(@as(usize, 2), (try bench.grid(.{ .table = all, .where_text = "loznice" })).len);
    try testing.expectEqual(@as(usize, 1), (try bench.grid(.{ .table = all, .where_text = "closed" })).len);

    try testing.expectEqual(@as(usize, 1), (try bench.grid(.{ .table = all, .where = &.{.{ .column = "payload", .value = "18" }} })).len);
    try testing.expectEqual(@as(usize, 3), (try bench.grid(.{ .table = all, .where = &.{.{ .column = "payload", .op = .ne, .value = "18" }} })).len);
    try testing.expectEqual(@as(usize, 2), (try bench.grid(.{ .table = all, .where = &.{.{ .column = "topic", .op = .like, .value = "%teplota" }} })).len);
    try testing.expectEqual(@as(usize, 4), (try bench.grid(.{ .table = all, .where = &.{.{ .column = "retained", .value = "yes" }} })).len);
    try testing.expectEqual(@as(usize, 0), (try bench.grid(.{ .table = all, .where = &.{.{ .column = "retained", .value = "0" }} })).len);
    try testing.expectEqual(@as(usize, 4), (try bench.grid(.{ .table = all, .where = &.{.{ .column = "messages", .op = .ge, .value = "1" }} })).len);
    try testing.expectEqual(@as(usize, 0), (try bench.grid(.{ .table = all, .where = &.{.{ .column = "messages", .op = .gt, .value = "1" }} })).len);
    try testing.expectEqual(@as(usize, 0), (try bench.grid(.{ .table = all, .where = &.{.{ .column = "payload", .op = .is_null }} })).len);
    try testing.expectEqual(@as(usize, 0), (try bench.grid(.{ .table = all, .where = &.{.{ .column = "nothing", .value = "x" }} })).len);
    // Either of two, which is what the search across every column asks.
    try testing.expectEqual(@as(usize, 2), (try bench.grid(.{ .table = all, .any = true, .where = &.{
        .{ .column = "payload", .value = "21" },
        .{ .column = "topic", .value = "garaz/vrata" },
    } })).len);

    const counted = try bench.grid(.{ .table = all, .count = true, .where_text = "dum/#" });
    try testing.expectEqualStrings("3", counted[0][0]);

    // By a column, both ways; and a page is a window over that order.
    const by_payload = try bench.grid(.{ .table = all, .order = "payload" });
    try testing.expectEqualStrings("18", by_payload[0][1]);
    try testing.expectEqualStrings("off", by_payload[3][1]);
    const last_first = try bench.grid(.{ .table = all, .order = "topic", .descending = true, .limit = 2, .offset = 1 });
    try testing.expectEqual(@as(usize, 2), last_first.len);
    try testing.expectEqualStrings("dum/loznice/teplota", last_first[0][0]);
    try testing.expectEqualStrings("dum/loznice/svetlo", last_first[1][0]);
    try testing.expectEqual(@as(usize, 0), (try bench.grid(.{ .table = all, .offset = 9, .limit = 2 })).len);

    // The log, by its number: the newest page of it is the end.
    const newest = try bench.grid(.{ .table = .{ .name = MESSAGES }, .where = &.{.{ .column = "n", .op = .gt, .value = "2" }} });
    try testing.expectEqual(@as(usize, 2), newest.len);
    try testing.expectEqualStrings("3", newest[0][0]);
}

test "the console says the same things in words, and a dump of them comes back as it was" {
    var bench = try Bench.init();
    defer bench.deinit();
    const conn = try bench.connect(EVERYTHING);

    try testing.expectEqualStrings("dum/lampa", try bench.run("PUBLISH dum/lampa {\"stav\": \"on\", \"jas\": 80}"));
    try testing.expectEqualStrings("dum/termostat", try bench.run("publish -r -q 1 dum/termostat 22"));
    try testing.expectEqualStrings("dum/rezim", try bench.run("RETAIN dum/rezim  noc "));
    try testing.expectEqualStrings("dum/s mezerou", try bench.run("PUBLISH 'dum/s mezerou' ano"));
    // Base64, for what a line cannot carry: this is "prvni\ndruhy".
    try testing.expectEqualStrings("dum/text", try bench.run("PUBLISH -b dum/text cHJ2bmkKZHJ1aHk="));
    try testing.expectEqualStrings("dum/zvonek", try bench.run("PUB dum/zvonek"));
    try testing.expectEqualStrings("22", bench.broker.holds("dum/termostat").?);
    try testing.expectEqualStrings("noc", bench.broker.holds("dum/rezim").?);

    const topics = try bench.table(TOPICS);
    try testing.expectEqual(@as(usize, 6), topics.len);
    try testing.expectEqualStrings("{\"stav\": \"on\", \"jas\": 80}", topics[0][1]);
    try testing.expectEqualStrings("yes", topics[1][2]);
    try testing.expectEqualStrings("prvni\ndruhy", topics[4][1]);
    try testing.expectEqualStrings("", topics[5][1]);

    // Listings, and one of them narrowed.
    var rows = (try conn.query("TOPICS dum/+", null)).?;
    try testing.expectEqual(@as(usize, 6), rows.mqtt.rows.items.len);
    // An answer, not a table: nothing in it is edited from here.
    try testing.expectEqualStrings("", rows.sourceTable(0));
    rows.close();
    rows = (try conn.query("MESSAGES termostat", null)).?;
    try testing.expectEqual(@as(usize, 1), rows.mqtt.rows.items.len);
    rows.close();
    rows = (try conn.query("STATUS", null)).?;
    try testing.expect(rows.mqtt.rows.items.len >= 6);
    rows.close();

    try testing.expectEqualStrings("dum/termostat", try bench.run("CLEAR dum/termostat"));
    try testing.expect(bench.broker.holds("dum/termostat") == null);
    try testing.expectEqualStrings("senzory/#", try bench.run("SUBSCRIBE senzory/# 1"));
    try testing.expectEqualStrings("senzory/#", try bench.run("UNSUBSCRIBE senzory/#"));
    try testing.expectError(error.Driver, conn.query("PUBLISH", null));
    try testing.expectError(error.Driver, conn.query("PUBLISH -b t not base64!", null));
    try testing.expectError(error.Driver, conn.query("PUBLISH -q 7 t x", null));
    try testing.expectError(error.Driver, conn.query("SELECT 1", null));
    try testing.expect(std.mem.find(u8, conn.message(), "SELECT is not a command") != null);
    try testing.expect((try conn.query("   ", null)) == null);

    // Which of them only look, and may be run again on a clock.
    try testing.expect(conn.repeatable("TOPICS dum/#"));
    try testing.expect(conn.repeatable("messages"));
    try testing.expect(!conn.repeatable("PUBLISH a b"));
    try testing.expect(!conn.repeatable("FORGET"));

    // A row as the line that makes it again, and the line as the same row.
    const a = bench.arena.allocator();
    for ([_]Draft{
        .{ .topic = "a/b", .payload = "plain" },
        .{ .topic = "a/b", .payload = "{\"k\": \"v w\"}", .retained = true },
        .{ .topic = "a b/c", .payload = "x", .qos = 2 },
        .{ .topic = "a/b", .payload = "two\nlines", .retained = true, .qos = 1 },
        .{ .topic = "a/b", .payload = " padded " },
        .{ .topic = "a/b", .payload = "\x00\xff\x01" },
        .{ .topic = "a/b", .payload = "" },
        .{ .topic = "a/b", .payload = "-r not an option" },
        // A topic may be called anything, an option included.
        .{ .topic = "-r", .payload = "x" },
        .{ .topic = "-q", .payload = "1 x", .retained = true },
    }) |draft| {
        const line = try conn.wording(a, .{ .change = .{
            .kind = .insert,
            .table = .{ .name = TOPICS },
            .cells = &.{
                .{ .column = "topic", .value = draft.topic },
                .{ .column = "payload", .value = draft.payload },
                .{ .column = "retained", .value = if (draft.retained) "yes" else "no" },
                .{ .column = "qos", .value = try a.print("{d}", .{draft.qos}) },
                .{ .column = "messages", .value = "3" },
                .{ .column = "time", .value = "2026-10-04 20:00:00.000" },
            },
        } });
        try testing.expect(std.mem.startsWith(u8, line, "PUBLISH "));
        try testing.expect(std.mem.findAny(u8, line, "\r\n") == null);
        const back = try conn.parsePublish(line["PUBLISH ".len..]);
        try testing.expectEqualStrings(draft.topic, back.topic);
        try testing.expectEqualStrings(draft.payload, back.payload);
        try testing.expectEqual(draft.retained, back.retained);
        try testing.expectEqual(draft.qos, back.qos);
    }
    try testing.expectEqualStrings("SUBSCRIBE dum/# 1", try conn.wording(a, .{ .change = .{
        .kind = .insert,
        .table = .{ .name = SUBSCRIPTIONS },
        .cells = &.{ .{ .column = "filter", .value = "dum/#" }, .{ .column = "qos", .value = "1" }, .{ .column = "state", .value = "listening" } },
    } }));
    try testing.expectEqualStrings("CLEAR dum/lampa", try conn.wording(a, .{ .change = .{
        .kind = .delete,
        .table = .{ .name = TOPICS },
        .where = &.{.{ .column = "topic", .value = "dum/lampa" }},
    } }));
    try testing.expectEqualStrings("TOPICS dum/#", try conn.wording(a, .{ .select = .{ .table = .{ .name = TOPICS }, .where_text = "dum/#" } }));

    // Lines, and not semicolons: a payload may hold one.
    const lines = try conn.split(a, "PUBLISH a x;y\n-- a comment\n\n  TOPICS  \n");
    try testing.expectEqual(@as(usize, 2), lines.len);
    try testing.expectEqualStrings("PUBLISH a x;y", lines[0].sql);

    // FORGET empties what is kept here, and only here.
    _ = try bench.run("FORGET");
    try testing.expectEqual(@as(usize, 0), (try bench.table(MESSAGES)).len);
    try testing.expectEqual(@as(usize, 0), (try bench.table(TOPICS)).len);
    try testing.expectEqualStrings("noc", bench.broker.holds("dum/rezim").?);
}

test "a broker that says no says why, and a password is asked for only where one would help" {
    {
        var bench = try Bench.init();
        defer bench.deinit();
        bench.broker.connack = 5;
        try testing.expectError(error.Driver, bench.connect(.{ .host = "broker.test", .client = "test", .user = "ada" }));
        // The word the interface asks for a password on.
        try testing.expectEqualStrings("the broker wants a password for ada", bench.report.items);
        try testing.expect(!bench.broker.greeted_with_password);
    }
    {
        var bench = try Bench.init();
        defer bench.deinit();
        bench.broker.connack = 4;
        try testing.expectError(error.Driver, bench.connect(.{ .host = "broker.test", .client = "test", .user = "ada", .password = "wrong" }));
        try testing.expect(std.mem.find(u8, bench.report.items, "password") != null);
        try testing.expect(bench.broker.greeted_with_password);
    }
    {
        // Nobody to send a password as, so asking for one would go round for ever.
        var bench = try Bench.init();
        defer bench.deinit();
        bench.broker.connack = 5;
        try testing.expectError(error.Driver, bench.connect(EVERYTHING));
        try testing.expect(std.mem.find(u8, bench.report.items, "password") == null);
        try testing.expect(std.mem.find(u8, bench.report.items, "mqtt://user@") != null);
    }
    {
        var bench = try Bench.init();
        defer bench.deinit();
        bench.broker.connack = 3;
        try testing.expectError(error.Driver, bench.connect(EVERYTHING));
        try testing.expectEqualStrings("the broker is not taking connections", bench.report.items);
    }
    {
        // The one filter the target asked for, refused: that is not a connection.
        var bench = try Bench.init();
        defer bench.deinit();
        bench.broker.denies = "tajne/#";
        try testing.expectError(error.Driver, bench.connect(.{ .host = "broker.test", .client = "test", .filter = "tajne/#" }));
        try testing.expect(std.mem.find(u8, bench.report.items, "refused the subscription to tajne/#") != null);
    }
    {
        // And everything refused its own figures: still a broker, without them.
        var bench = try Bench.init();
        defer bench.deinit();
        bench.broker.denies = "$SYS/#";
        _ = try bench.connect(EVERYTHING);
        try testing.expectEqual(@as(usize, 1), (try bench.table(SUBSCRIPTIONS)).len);
    }
}

test "a name too long for its two bytes of length is refused, not sent" {
    var pair: [2]std.c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &pair));
    defer _ = std.c.close(pair[1]);
    const long = try testing.allocator.alloc(u8, 70_000);
    defer testing.allocator.free(long);
    @memset(long, 'k');
    var report: List = .empty;
    defer report.deinit(testing.allocator);
    try testing.expectError(error.Driver, Db.attach(testing.allocator, .{ .fd = pair[0] }, .{ .host = "broker.test", .client = long }, &report));
    try testing.expect(std.mem.find(u8, report.items, "at most 65535 bytes, and one of these is 70000") != null);
}

test "what answers and is not a broker is said to be so" {
    var pair: [2]std.c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &pair));
    defer _ = std.c.close(pair[1]);
    const said = "HTTP/1.1 400 Bad Request\r\n\r\n";
    _ = std.c.send(pair[1], said.ptr, said.len, 0);
    var report: List = .empty;
    defer report.deinit(testing.allocator);
    try testing.expectError(error.Driver, Db.attach(testing.allocator, .{ .fd = pair[0] }, EVERYTHING, &report));
    try testing.expectEqualStrings("broker.test:1883 did not answer as an MQTT broker", report.items);
}

test "a connection that is lost says so, and what was heard is still there" {
    var bench = try Bench.init();
    defer bench.deinit();
    try bench.broker.hold("dum/lampa", "on");
    const conn = try bench.connect(EVERYTHING);
    try testing.expectEqual(@as(usize, 1), (try bench.table(TOPICS)).len);

    // The broker goes away.
    _ = std.c.shutdown(bench.broker.fd, 2);
    var waited: usize = 0;
    while (!conn.isLost() and waited < 200) : (waited += 1) {
        clock.sleep(5);
    }
    try testing.expect(conn.isLost());
    try testing.expect(std.mem.find(u8, conn.version(), "not connected: the broker closed the connection") != null);
    // Looking still works, out of memory; sending needs a broker and says so.
    try testing.expectEqual(@as(usize, 1), (try bench.table(TOPICS)).len);
    try testing.expectError(error.Driver, conn.apply(.{ .kind = .insert, .table = .{ .name = MESSAGES }, .cells = &.{
        .{ .column = "topic", .value = "dum/lampa" },
        .{ .column = "payload", .value = "off" },
    } }));
    try testing.expect(conn.message().len != 0);
}

test "the log is bounded, and the oldest go first" {
    const conn = try testing.allocator.create(Db);
    conn.* = .{
        .allocator = testing.allocator,
        .stream = .{ .fd = -1 },
        .replies = std.heap.ArenaAllocator.init(testing.allocator),
        .most_messages = 100,
        .most_bytes = 2000,
    };
    defer conn.close();
    // Past the limit by enough that the gap at the front is closed on the way.
    const total = 1000;
    for (0..total) |at| {
        try conn.keep(.{ .topic = if (at % 2 == 0) "even" else "odd", .payload = "x" });
    }
    try testing.expectEqual(@as(usize, 100), conn.messages.items.len - conn.first);
    try testing.expectEqual(@as(u64, total - 100), conn.dropped);
    try testing.expect(conn.first < 256);
    // The numbers go on from where they were: a row keeps the one it had.
    try testing.expectEqual(@as(i64, total - 100 + 1), conn.messages.items[conn.first].n);
    try testing.expectEqual(@as(i64, total), conn.messages.items[conn.messages.items.len - 1].n);
    // Half of them `even` and an x, half `odd` and an x.
    try testing.expectEqual(@as(usize, 50 * 5 + 50 * 4), conn.held_bytes);
    // And what is known of a topic is not the log: both are still there.
    try testing.expectEqual(@as(u32, 2), conn.topics.count());
    try testing.expectEqual(@as(i64, total / 2), conn.topics.get("odd").?.count);

    // Bytes are a limit of their own: forty messages of fifty-one is past it.
    const fifty: [50]u8 = @splat('x');
    for (0..40) |_| {
        try conn.keep(.{ .topic = "t", .payload = &fifty });
    }
    try testing.expect(conn.held_bytes <= 2000);
    try testing.expectEqual(@as(usize, 39), conn.messages.items.len - conn.first);
    // And one message larger than everything that may be kept takes the rest
    // with it, itself included: the limit is the limit.
    const big: [2000]u8 = @splat('x');
    try conn.keep(.{ .topic = "big", .payload = &big });
    try testing.expectEqual(@as(usize, 0), conn.messages.items.len - conn.first);
    try testing.expectEqual(@as(usize, 0), conn.held_bytes);
    try testing.expectEqualStrings(&big, conn.topics.get("big").?.payload);
}

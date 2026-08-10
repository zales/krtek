//! The Kafka driver: the protocol spoken directly over a socket.
//!
//! No client library. Kafka's wire protocol is length-prefixed requests with a
//! version per API, so the handful this needs - ApiVersions, Metadata,
//! ListOffsets, Fetch, Produce, CreateTopics, DeleteTopics, DeleteRecords,
//! DescribeConfigs, ListGroups - is written out below. The versions chosen are
//! deliberately the newest ones that are *not* flexible: from Kafka 2.4 onwards
//! every API grew compact strings and tagged fields, and none of that is needed
//! to read a topic. Brokers still answer the older ones, so this speaks to
//! anything from 2.1 to 4.x with one encoding instead of two.
//!
//! **Kafka is a log, not a table, and this driver does not pretend otherwise.**
//! A topic is a table whose columns are `partition`, `offset`, `timestamp`, `key`,
//! `value` and `headers`. That mapping is better than it sounds: an offset is a
//! natural page number, so `1-50 of 12043` is exact and free, and `(partition,
//! offset)` addresses a record precisely. What it cannot do is change one: the log
//! is append-only, so an edit is refused with the reason, and the only deletion
//! Kafka has throws away everything before an offset - which is `TRUNCATE`, not a
//! row.
//!
//! **Records are read from the leader of their partition.** Metadata says which
//! broker that is, and a connection to it is opened when it is first needed, so a
//! real cluster works and not only a single-broker one on a laptop.
//!
//! Nothing here parses SQL: the interface asks with `ask.Select` and `ask.Change`
//! (`speaks_sql = false`), and what the user types in the editor is a Kafka
//! command line - `TOPICS`, `DESCRIBE orders`, `PRODUCE orders k v`.

const std = @import("std");
const db = @import("db.zig");

const List = db.List;

/// The pseudo-columns of every topic.
pub const PARTITION = "partition";
pub const OFFSET = "offset";
pub const TIMESTAMP = "timestamp";
pub const KEY = "key";
pub const VALUE = "value";
pub const HEADERS = "headers";

const COLUMNS = [_][]const u8{ PARTITION, OFFSET, TIMESTAMP, KEY, VALUE, HEADERS };

/// How long a Fetch may wait for records before answering, in milliseconds. Short
/// on purpose: an empty topic should not hold the interface, and a long wait is
/// what makes ctrl+c feel broken.
const WAIT_MS: i32 = 400;
/// How much one Fetch may bring back, per partition and in total.
const PARTITION_BYTES: i32 = 1 << 20;
const FETCH_BYTES: i32 = 8 << 20;

// ------------------------------------------------------------------ the APIs

const Api = enum(i16) {
	produce = 0,
	fetch = 1,
	list_offsets = 2,
	metadata = 3,
	api_versions = 18,
	create_topics = 19,
	delete_topics = 20,
	delete_records = 21,
	describe_configs = 32,
	list_groups = 16,
	sasl_handshake = 17,
	sasl_authenticate = 36,
};

/// The version this driver speaks for each API: the last one before that API
/// became flexible, so there are no compact strings or tagged fields anywhere.
fn versionOf(api: Api) i16 {
	return switch (api) {
		.produce => 8,
		.fetch => 11,
		.list_offsets => 5,
		.metadata => 7,
		.api_versions => 0,
		.create_topics => 3,
		.delete_topics => 3,
		.delete_records => 1,
		.describe_configs => 2,
		.list_groups => 2,
		.sasl_handshake => 1,
		.sasl_authenticate => 1,
	};
}

pub const Error = db.Error;

// -------------------------------------------------------------- the transport

/// A socket, with a TLS session on top of it when the target asked for one.
/// Everything reads and writes through here, so encryption is one branch rather
/// than a second copy of the protocol.
pub const Stream = struct {
	fd: std.c.fd_t,
	ssl: ?*anyopaque = null,

	pub fn write(self: *Stream, bytes: []const u8) !void {
		var sent: usize = 0;
		while (sent < bytes.len) {
			const wrote = if (self.ssl) |session|
				ssl.SSL_write(session, bytes[sent..].ptr, @intCast(bytes.len - sent))
			else
				@as(c_int, @intCast(std.c.send(self.fd, bytes[sent..].ptr, bytes.len - sent, 0)));
			if (wrote <= 0) {
				return error.Gone;
			}
			sent += @intCast(wrote);
		}
	}

	/// Exactly `into.len` bytes, or an error. Kafka frames everything by length,
	/// so a short read is never the end of a message.
	pub fn readExactly(self: *Stream, into: []u8) !void {
		var got: usize = 0;
		while (got < into.len) {
			const read = if (self.ssl) |session|
				ssl.SSL_read(session, into[got..].ptr, @intCast(into.len - got))
			else
				@as(c_int, @intCast(std.c.recv(self.fd, into[got..].ptr, into.len - got, 0)));
			if (read <= 0) {
				return error.Gone;
			}
			got += @intCast(read);
		}
	}

	pub fn close(self: *Stream) void {
		if (self.ssl) |session| {
			_ = ssl.SSL_shutdown(session);
			ssl.SSL_free(session);
			self.ssl = null;
		}
		_ = std.c.close(self.fd);
		self.fd = -1;
	}
};

/// The little of OpenSSL this needs, declared rather than included: a client
/// context, a session on a socket, and the two calls that move bytes. OpenSSL is
/// already linked in - libpq and the MariaDB connector both want it - so this
/// costs nothing but these declarations.
pub const ssl = struct {
	pub extern fn OPENSSL_init_ssl(opts: u64, settings: ?*anyopaque) c_int;
	pub extern fn TLS_client_method() ?*anyopaque;
	pub extern fn SSL_CTX_new(method: ?*anyopaque) ?*anyopaque;
	pub extern fn SSL_CTX_free(ctx: ?*anyopaque) void;
	pub extern fn SSL_CTX_set_default_verify_paths(ctx: ?*anyopaque) c_int;
	pub extern fn SSL_CTX_set_verify(ctx: ?*anyopaque, mode: c_int, callback: ?*anyopaque) void;
	pub extern fn SSL_new(ctx: ?*anyopaque) ?*anyopaque;
	pub extern fn SSL_free(session: ?*anyopaque) void;
	pub extern fn SSL_set_fd(session: ?*anyopaque, fd: c_int) c_int;
	pub extern fn SSL_connect(session: ?*anyopaque) c_int;
	pub extern fn SSL_read(session: ?*anyopaque, buffer: [*]u8, count: c_int) c_int;
	pub extern fn SSL_write(session: ?*anyopaque, buffer: [*]const u8, count: c_int) c_int;
	pub extern fn SSL_shutdown(session: ?*anyopaque) c_int;
	pub extern fn SSL_ctrl(session: ?*anyopaque, cmd: c_int, larg: c_long, parg: ?*anyopaque) c_long;
	pub extern fn SSL_set1_host(session: ?*anyopaque, host: [*:0]const u8) c_int;
	pub extern fn SSL_get_verify_result(session: ?*const anyopaque) c_long;
	pub extern fn ERR_get_error() c_ulong;
	pub extern fn ERR_error_string_n(code: c_ulong, buffer: [*]u8, length: usize) void;

	pub const VERIFY_PEER: c_int = 1;
	pub const VERIFY_NONE: c_int = 0;
	/// SSL_set_tlsext_host_name, which is a macro over SSL_ctrl.
	pub const CTRL_SET_TLSEXT_HOSTNAME: c_int = 55;
	pub const TLSEXT_NAMETYPE_host_name: c_long = 0;

	/// What OpenSSL last complained about, into a buffer of the caller's.
	pub fn lastError(buffer: []u8) []const u8 {
		const code = ERR_get_error();
		if (code == 0) {
			return "";
		}
		ERR_error_string_n(code, buffer.ptr, buffer.len);
		return std.mem.sliceTo(buffer, 0);
	}
};

/// Wrap a connected socket in TLS. `host` is verified against the certificate
/// unless the target said not to bother.
fn startTls(allocator: std.mem.Allocator, stream: *Stream, host: []const u8, verify: bool, why: *List) !void {
	_ = ssl.OPENSSL_init_ssl(0, null);
	const ctx = ssl.SSL_CTX_new(ssl.TLS_client_method()) orelse return error.Tls;
	// The context is freed as soon as the session is made: the session holds a
	// reference of its own.
	defer ssl.SSL_CTX_free(ctx);
	if (verify) {
		if (ssl.SSL_CTX_set_default_verify_paths(ctx) != 1) {
			try why.appendSlice(allocator, "no trusted certificates on this machine to verify the broker against");
			return error.Tls;
		}
		ssl.SSL_CTX_set_verify(ctx, ssl.VERIFY_PEER, null);
	} else {
		ssl.SSL_CTX_set_verify(ctx, ssl.VERIFY_NONE, null);
	}
	const session = ssl.SSL_new(ctx) orelse return error.Tls;
	errdefer ssl.SSL_free(session);
	if (ssl.SSL_set_fd(session, stream.fd) != 1) {
		return error.Tls;
	}
	const zero_host = try allocator.dupeZ(u8, host);
	defer allocator.free(zero_host);
	// The name to ask for, and - when verifying - the name to insist on.
	_ = ssl.SSL_ctrl(session, ssl.CTRL_SET_TLSEXT_HOSTNAME, ssl.TLSEXT_NAMETYPE_host_name, @ptrCast(@constCast(zero_host.ptr)));
	if (verify) {
		_ = ssl.SSL_set1_host(session, zero_host.ptr);
	}
	if (ssl.SSL_connect(session) != 1) {
		var buffer: [256]u8 = undefined;
		const text = ssl.lastError(&buffer);
		try why.print(allocator, "the TLS handshake failed{s}{s}", .{
			if (text.len != 0) ": " else "",
			text,
		});
		return error.Tls;
	}
	stream.ssl = session;
}

fn connect(allocator: std.mem.Allocator, host: []const u8, port: u16) !Stream {
	const zero = try allocator.dupeZ(u8, host);
	defer allocator.free(zero);
	var hints = std.mem.zeroes(std.c.addrinfo);
	hints.family = std.c.AF.UNSPEC;
	hints.socktype = std.c.SOCK.STREAM;
	var service: [8]u8 = undefined;
	const service_text = std.fmt.bufPrintZ(&service, "{d}", .{port}) catch return error.BadPort;
	var found: ?*std.c.addrinfo = null;
	if (std.c.getaddrinfo(zero.ptr, service_text.ptr, &hints, &found) != @as(std.c.EAI, @enumFromInt(0))) {
		return error.NoSuchHost;
	}
	defer if (found) |list| std.c.freeaddrinfo(list);
	var candidate = found;
	while (candidate) |info| : (candidate = info.next) {
		const fd = std.c.socket(@intCast(info.family), @intCast(info.socktype), @intCast(info.protocol));
		if (fd < 0) {
			continue;
		}
		if (std.c.connect(fd, info.addr.?, info.addrlen) == 0) {
			return .{ .fd = fd };
		}
		_ = std.c.close(fd);
	}
	return error.Refused;
}

// --------------------------------------------------------------- encode/decode

/// Big-endian, which is the only endianness Kafka has.
const Encoder = struct {
	out: *List,
	a: std.mem.Allocator,

	fn int8(self: Encoder, value: i8) !void {
		try self.out.append(self.a, @bitCast(value));
	}

	fn int16(self: Encoder, value: i16) !void {
		var buf: [2]u8 = undefined;
		std.mem.writeInt(i16, &buf, value, .big);
		try self.out.appendSlice(self.a, &buf);
	}

	fn int32(self: Encoder, value: i32) !void {
		var buf: [4]u8 = undefined;
		std.mem.writeInt(i32, &buf, value, .big);
		try self.out.appendSlice(self.a, &buf);
	}

	fn int64(self: Encoder, value: i64) !void {
		var buf: [8]u8 = undefined;
		std.mem.writeInt(i64, &buf, value, .big);
		try self.out.appendSlice(self.a, &buf);
	}

	fn boolean(self: Encoder, value: bool) !void {
		try self.int8(if (value) 1 else 0);
	}

	fn string(self: Encoder, text: []const u8) !void {
		try self.int16(@intCast(text.len));
		try self.out.appendSlice(self.a, text);
	}

	/// A string that may be absent, which is a length of -1.
	fn nullableString(self: Encoder, text: ?[]const u8) !void {
		if (text) |bytes| {
			try self.string(bytes);
		} else {
			try self.int16(-1);
		}
	}

	fn byteArray(self: Encoder, value: ?[]const u8) !void {
		if (value) |slice| {
			try self.int32(@intCast(slice.len));
			try self.out.appendSlice(self.a, slice);
		} else {
			try self.int32(-1);
		}
	}

	fn array(self: Encoder, count: usize) !void {
		try self.int32(@intCast(count));
	}

	fn varint(self: Encoder, value: i32) !void {
		try self.varlong(value);
	}

	/// Zig-zag, as the record format uses it.
	fn varlong(self: Encoder, value: i64) !void {
		var rest: u64 = @bitCast((value << 1) ^ (value >> 63));
		while (true) {
			const byte: u8 = @intCast(rest & 0x7f);
			rest >>= 7;
			if (rest == 0) {
				try self.out.append(self.a, byte);
				return;
			}
			try self.out.append(self.a, byte | 0x80);
		}
	}
};

const DecodeError = error{ Malformed, OutOfMemory };

const Decoder = struct {
	bytes: []const u8,
	at: usize = 0,

	fn take(self: *Decoder, count: usize) DecodeError![]const u8 {
		if (self.at + count > self.bytes.len) {
			return error.Malformed;
		}
		defer self.at += count;
		return self.bytes[self.at .. self.at + count];
	}

	fn int8(self: *Decoder) DecodeError!i8 {
		const slice = try self.take(1);
		return @bitCast(slice[0]);
	}

	fn int16(self: *Decoder) DecodeError!i16 {
		return std.mem.readInt(i16, (try self.take(2))[0..2], .big);
	}

	fn int32(self: *Decoder) DecodeError!i32 {
		return std.mem.readInt(i32, (try self.take(4))[0..4], .big);
	}

	fn int64(self: *Decoder) DecodeError!i64 {
		return std.mem.readInt(i64, (try self.take(8))[0..8], .big);
	}

	fn uint32(self: *Decoder) DecodeError!u32 {
		return std.mem.readInt(u32, (try self.take(4))[0..4], .big);
	}

	fn string(self: *Decoder) DecodeError![]const u8 {
		const length = try self.int16();
		if (length < 0) {
			return "";
		}
		return self.take(@intCast(length));
	}

	fn nullableBytes(self: *Decoder) DecodeError!?[]const u8 {
		const length = try self.int32();
		if (length < 0) {
			return null;
		}
		return try self.take(@intCast(length));
	}

	fn boolean(self: *Decoder) DecodeError!bool {
		return (try self.int8()) != 0;
	}

	fn arrayLength(self: *Decoder) DecodeError!usize {
		const count = try self.int32();
		if (count < 0) {
			return 0;
		}
		return @intCast(count);
	}

	fn varint(self: *Decoder) DecodeError!i32 {
		const value = try self.varlong();
		return @intCast(value);
	}

	fn varlong(self: *Decoder) DecodeError!i64 {
		var shift: u6 = 0;
		var raw: u64 = 0;
		while (true) {
			const byte = (try self.take(1))[0];
			raw |= @as(u64, byte & 0x7f) << shift;
			if (byte & 0x80 == 0) {
				break;
			}
			if (shift >= 63) {
				return error.Malformed;
			}
			shift += 7;
		}
		// Zig-zag back to a signed number.
		const half: i64 = @bitCast(raw >> 1);
		return if (raw & 1 == 1) -(half + 1) else half;
	}

	fn rest(self: *Decoder) []const u8 {
		defer self.at = self.bytes.len;
		return self.bytes[self.at..];
	}
};

// ------------------------------------------------------------------ the cluster

const Broker = struct {
	node: i32,
	host: []const u8,
	port: u16,
};

const Partition = struct {
	id: i32,
	leader: i32,
	replicas: usize = 0,
	in_sync: usize = 0,
	earliest: i64 = 0,
	latest: i64 = 0,

	pub fn count(self: Partition) i64 {
		return if (self.latest > self.earliest) self.latest - self.earliest else 0;
	}
};

const Topic = struct {
	name: []const u8,
	internal: bool = false,
	partitions: []Partition = &.{},
};

pub const Value = union(enum) {
	nil: void,
	text: []const u8,
	number: i64,
};

pub const Rows = struct {
	owner: *Db,
	names: []const []const u8 = &.{},
	rows: std.ArrayListUnmanaged([]const Value) = .empty,
	numeric: []const bool = &.{},
	table: []const u8 = "",
	at: usize = 0,
	started: bool = false,
	changed: i64 = 0,

	fn add(self: *Rows, values: []const Value) db.Error!void {
		const arena = self.owner.replies.allocator();
		try self.rows.append(arena, try arena.dupe(Value, values));
	}

	pub fn next(self: *Rows) db.Error!bool {
		if (!self.started) {
			self.started = true;
		} else {
			self.at += 1;
		}
		return self.at < self.rows.items.len;
	}

	pub fn close(self: *Rows) void {
		self.at = 0;
		self.rows.clearRetainingCapacity();
	}

	pub fn columnCount(self: *Rows) usize {
		return self.names.len;
	}

	pub fn name(self: *Rows, at: usize) []const u8 {
		return if (at < self.names.len) self.names[at] else "";
	}

	pub fn value(self: *Rows, at: usize) db.Value {
		if (self.at >= self.rows.items.len) {
			return .{ .null = {} };
		}
		const row = self.rows.items[self.at];
		if (at >= row.len) {
			return .{ .null = {} };
		}
		return switch (row[at]) {
			.nil => .{ .null = {} },
			.number => |number| .{ .int = number },
			.text => |text| .{ .text = text },
		};
	}

	pub fn sourceTable(self: *Rows, _: usize) []const u8 {
		return self.table;
	}

	pub fn sourceColumn(self: *Rows, at: usize) []const u8 {
		return self.name(at);
	}

	pub fn isNumeric(self: *Rows, at: usize) bool {
		return at < self.numeric.len and self.numeric[at];
	}

	pub fn affected(self: *Rows) i64 {
		return self.changed;
	}
};

// ------------------------------------------------------------------ the driver

pub const Db = struct {
	allocator: std.mem.Allocator,
	/// The connection to the broker the target names, which answers metadata.
	stream: Stream,
	/// One connection per broker, opened when a partition it leads is read from.
	leaders: std.AutoHashMapUnmanaged(i32, Stream) = .empty,
	brokers: std.ArrayListUnmanaged(Broker) = .empty,
	/// Everything the brokers said, until the next statement.
	replies: std.heap.ArenaAllocator,
	/// The cluster as it was last described, in `replies`.
	topics: []Topic = &.{},
	host: List = .empty,
	port: u16 = 9092,
	label: List = .empty,
	version_text: List = .empty,
	last_error: List = .empty,
	cluster_id: List = .empty,
	correlation: i32 = 0,
	progress: ?db.Progress = null,
	/// How to reach a broker: every connection to every one of them is made the
	/// same way, so this is kept rather than the target it came from.
	tls: bool = false,
	verify: bool = true,
	user: List = .empty,
	password: List = .empty,
	mechanism: Mechanism = .none,

	pub fn open(allocator: std.mem.Allocator, target: []const u8, report: *List) !*Db {
		const parts = try parse(allocator, target);
		defer parts.deinit(allocator);

		// A user with no password is worth asking about rather than failing at the
		// handshake, and the interface knows what to do with the word "password".
		if (parts.mechanism != .none and parts.password.len == 0) {
			try report.print(allocator, "kafka wants a password for {s}", .{parts.user});
			return error.Driver;
		}

		var stream = connect(allocator, parts.host, parts.port) catch {
			try report.print(allocator, "cannot reach kafka at {s}:{d}", .{ parts.host, parts.port });
			return error.Driver;
		};

		const self = try allocator.create(Db);
		self.* = .{
			.allocator = allocator,
			.stream = stream,
			.replies = std.heap.ArenaAllocator.init(allocator),
		};
		errdefer {
			stream.close();
			self.replies.deinit();
			allocator.destroy(self);
		}
		try self.host.appendSlice(allocator, parts.host);
		self.port = parts.port;
		self.tls = parts.tls;
		self.verify = parts.verify;
		try self.user.appendSlice(allocator, parts.user);
		try self.password.appendSlice(allocator, parts.password);
		self.mechanism = parts.mechanism;
		self.relabel();

		// Encryption first, then who is asking: everything after this, metadata
		// included, goes through both.
		if (self.tls) {
			startTls(allocator, &self.stream, parts.host, parts.verify, report) catch {
				if (report.items.len == 0) {
					try report.print(allocator, "TLS to {s}:{d} could not be set up", .{ parts.host, parts.port });
				}
				return error.Driver;
			};
		}
		self.authenticate(&self.stream) catch {
			try report.appendSlice(allocator, if (self.last_error.items.len != 0)
				self.last_error.items
			else
				"kafka refused the authentication");
			return error.Driver;
		};

		// What the broker can do, which is also the check that this is Kafka at all.
		self.readVersions() catch {
			try report.print(allocator, "{s}:{d} did not answer as kafka", .{ parts.host, parts.port });
			return error.Driver;
		};
		// And what is in it, so the object list has something to show.
		self.describeCluster() catch {
			try report.appendSlice(allocator, if (self.last_error.items.len != 0)
				self.last_error.items
			else
				"kafka answered, but not with its metadata");
			return error.Driver;
		};
		return self;
	}

	pub fn close(self: *Db) void {
		var walk = self.leaders.valueIterator();
		while (walk.next()) |stream| {
			stream.close();
		}
		self.leaders.deinit(self.allocator);
		self.brokers.deinit(self.allocator);
		self.stream.close();
		self.replies.deinit();
		self.host.deinit(self.allocator);
		self.user.deinit(self.allocator);
		self.password.deinit(self.allocator);
		self.label.deinit(self.allocator);
		self.version_text.deinit(self.allocator);
		self.last_error.deinit(self.allocator);
		self.cluster_id.deinit(self.allocator);
		self.allocator.destroy(self);
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
			.label = "Kafka",
			.text_cast = "TEXT",
			// Asked with a structure; the editor is a Kafka command line.
			.speaks_sql = false,
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

	fn relabel(self: *Db) void {
		self.label.clearRetainingCapacity();
		self.label.print(self.allocator, "{s}:{d}", .{ self.host.items, self.port }) catch {};
	}

	fn remember(self: *Db, text: []const u8) void {
		self.last_error.clearRetainingCapacity();
		self.last_error.appendSlice(self.allocator, text) catch {};
	}

	fn complain(self: *Db, comptime fmt: []const u8, args: anytype) void {
		self.last_error.clearRetainingCapacity();
		self.last_error.print(self.allocator, fmt, args) catch {};
	}

	/// A statement is starting: tell the spinner, and let the last reply go.
	fn begin(self: *Db) void {
		if (self.progress) |progress| {
			progress.starting();
		}
		self.last_error.clearRetainingCapacity();
		_ = self.replies.reset(.retain_capacity);
		self.topics = &.{};
	}

	fn keepGoing(self: *Db) bool {
		if (self.progress) |progress| {
			return progress.call();
		}
		return true;
	}

	// --- one request, one reply ---

	/// Send a request to a broker and hand back its response body. The body lives
	/// in `replies`.
	fn call(self: *Db, stream: *Stream, api: Api, body: []const u8) db.Error![]const u8 {
		const arena = self.replies.allocator();
		self.correlation += 1;

		var head: List = .empty;
		defer head.deinit(self.allocator);
		const write = Encoder{ .out = &head, .a = self.allocator };
		try write.int16(@intFromEnum(api));
		try write.int16(versionOf(api));
		try write.int32(self.correlation);
		try write.string("krtek");

		var framed: List = .empty;
		defer framed.deinit(self.allocator);
		const frame = Encoder{ .out = &framed, .a = self.allocator };
		try frame.int32(@intCast(head.items.len + body.len));
		try framed.appendSlice(self.allocator, head.items);
		try framed.appendSlice(self.allocator, body);

		stream.write(framed.items) catch {
			self.remember("the connection to kafka is gone");
			return error.Driver;
		};

		var size_bytes: [4]u8 = undefined;
		stream.readExactly(&size_bytes) catch {
			self.remember("kafka closed the connection");
			return error.Driver;
		};
		const size = std.mem.readInt(i32, &size_bytes, .big);
		if (size < 4 or size > 256 * 1024 * 1024) {
			self.remember("kafka sent a reply of an impossible size");
			return error.Driver;
		}
		const reply = try arena.alloc(u8, @intCast(size));
		stream.readExactly(reply) catch {
			self.remember("kafka stopped halfway through a reply");
			return error.Driver;
		};
		// The response header of a non-flexible API is the correlation id alone.
		return reply[4..];
	}

	/// The same, to the broker the target named.
	fn ask(self: *Db, api: Api, body: []const u8) db.Error![]const u8 {
		return self.call(&self.stream, api, body);
	}

	/// The connection to a particular broker, opened if this is the first time.
	fn leader(self: *Db, node: i32) db.Error!*Stream {
		if (self.leaders.getPtr(node)) |existing| {
			return existing;
		}
		for (self.brokers.items) |broker| {
			if (broker.node != node) {
				continue;
			}
			var stream = connect(self.allocator, broker.host, broker.port) catch {
				self.complain("cannot reach the broker at {s}:{d}, which leads that partition", .{ broker.host, broker.port });
				return error.Driver;
			};
			errdefer stream.close();
			if (self.tls) {
				var why: List = .empty;
				defer why.deinit(self.allocator);
				startTls(self.allocator, &stream, broker.host, self.verify, &why) catch {
					self.complain("TLS to the broker at {s}:{d} failed: {s}", .{
						broker.host, broker.port,
						if (why.items.len != 0) why.items else "no reason given",
					});
					return error.Driver;
				};
			}
			try self.authenticate(&stream);
			try self.leaders.put(self.allocator, node, stream);
			return self.leaders.getPtr(node).?;
		}
		self.complain("no broker {d} in the cluster, so its partitions cannot be read", .{node});
		return error.Driver;
	}

	// --- who is asking ---

	/// SaslHandshake names the mechanism, then SaslAuthenticate carries whatever
	/// that mechanism has to say. Nothing at all when the target named no user:
	/// a broker on a private network usually wants none.
	fn authenticate(self: *Db, stream: *Stream) db.Error!void {
		if (self.mechanism == .none) {
			return;
		}
		var body: List = .empty;
		defer body.deinit(self.allocator);
		const write = Encoder{ .out = &body, .a = self.allocator };
		try write.string(self.mechanism.name());
		const reply = try self.call(stream, .sasl_handshake, body.items);
		var read = Decoder{ .bytes = reply };
		const code = read.int16() catch {
			self.remember("kafka answered the handshake with something unexpected");
			return error.Driver;
		};
		if (code != 0) {
			// The broker lists what it does take, which is the one thing worth
			// saying when a mechanism is refused.
			var offered: List = .empty;
			defer offered.deinit(self.allocator);
			var count = read.arrayLength() catch 0;
			while (count > 0) : (count -= 1) {
				const name = read.string() catch break;
				if (offered.items.len != 0) {
					try offered.appendSlice(self.allocator, ", ");
				}
				try offered.appendSlice(self.allocator, name);
			}
			self.complain("kafka does not take {s}{s}{s}", .{
				self.mechanism.name(),
				if (offered.items.len != 0) " - it offers " else "",
				offered.items,
			});
			return error.Driver;
		}
		switch (self.mechanism) {
			.none => unreachable,
			.plain => {
				// The whole of PLAIN: an empty authorisation identity, the user, the
				// password, separated by NULs.
				var token: List = .empty;
				defer token.deinit(self.allocator);
				try token.append(self.allocator, 0);
				try token.appendSlice(self.allocator, self.user.items);
				try token.append(self.allocator, 0);
				try token.appendSlice(self.allocator, self.password.items);
				_ = try self.saslToken(stream, token.items);
			},
			.scram_sha_256 => try self.scram(stream, std.crypto.hash.sha2.Sha256, std.crypto.auth.hmac.sha2.HmacSha256),
			.scram_sha_512 => try self.scram(stream, std.crypto.hash.sha2.Sha512, std.crypto.auth.hmac.sha2.HmacSha512),
		}
	}

	/// One SaslAuthenticate exchange. The reply's bytes belong to `replies`.
	fn saslToken(self: *Db, stream: *Stream, token: []const u8) db.Error![]const u8 {
		var body: List = .empty;
		defer body.deinit(self.allocator);
		const write = Encoder{ .out = &body, .a = self.allocator };
		try write.byteArray(token);
		const reply = try self.call(stream, .sasl_authenticate, body.items);
		var read = Decoder{ .bytes = reply };
		const code = read.int16() catch {
			self.remember("kafka answered the authentication with something unexpected");
			return error.Driver;
		};
		const why = read.string() catch "";
		const answer = read.nullableBytes() catch null;
		if (code != 0) {
			if (why.len != 0) {
				self.complain("kafka refused the authentication: {s}", .{why});
			} else {
				self.complain("kafka refused the authentication: {s}", .{errorText(code)});
			}
			return error.Driver;
		}
		return answer orelse "";
	}

	/// SCRAM, in three messages: what the client is, what the server salts with,
	/// and the proof that the client knows the password without sending it. The
	/// server's own signature is checked too - that is the half of SCRAM that
	/// proves the broker is not an impostor.
	fn scram(self: *Db, stream: *Stream, comptime Hash: type, comptime Hmac: type) db.Error!void {
		const arena = self.replies.allocator();
		const base64 = std.base64.standard;

		var raw_nonce: [24]u8 = undefined;
		randomBytes(&raw_nonce) catch {
			self.remember("no source of randomness on this machine for a SCRAM nonce");
			return error.Driver;
		};
		var nonce_buffer: [base64.Encoder.calcSize(24)]u8 = undefined;
		const nonce = base64.Encoder.encode(&nonce_buffer, &raw_nonce);

		const user = try escapeName(arena, self.user.items);
		const bare = try std.fmt.allocPrint(arena, "n={s},r={s}", .{ user, nonce });
		const first = try std.fmt.allocPrint(arena, "n,,{s}", .{bare});
		const server_first = try arena.dupe(u8, try self.saslToken(stream, first));

		const salt_text = fieldOf(server_first, 's') orelse {
			self.remember("the broker's SCRAM reply had no salt in it");
			return error.Driver;
		};
		const combined = fieldOf(server_first, 'r') orelse {
			self.remember("the broker's SCRAM reply had no nonce in it");
			return error.Driver;
		};
		const iterations = std.fmt.parseInt(u32, fieldOf(server_first, 'i') orelse "4096", 10) catch 4096;
		if (!std.mem.startsWith(u8, combined, nonce)) {
			self.remember("the broker's SCRAM nonce does not start with the one it was sent");
			return error.Driver;
		}
		const salt = try arena.alloc(u8, base64.Decoder.calcSizeForSlice(salt_text) catch {
			self.remember("the broker's SCRAM salt is not base64");
			return error.Driver;
		});
		base64.Decoder.decode(salt, salt_text) catch {
			self.remember("the broker's SCRAM salt is not base64");
			return error.Driver;
		};

		var salted: [Hmac.mac_length]u8 = undefined;
		std.crypto.pwhash.pbkdf2(&salted, self.password.items, salt, iterations, Hmac) catch {
			self.remember("the SCRAM key could not be derived");
			return error.Driver;
		};
		var client_key: [Hmac.mac_length]u8 = undefined;
		Hmac.create(&client_key, "Client Key", &salted);
		var stored_key: [Hash.digest_length]u8 = undefined;
		Hash.hash(&client_key, &stored_key, .{});

		const without_proof = try std.fmt.allocPrint(arena, "c=biws,r={s}", .{combined});
		const auth_message = try std.fmt.allocPrint(arena, "{s},{s},{s}", .{ bare, server_first, without_proof });

		var client_signature: [Hmac.mac_length]u8 = undefined;
		Hmac.create(&client_signature, auth_message, &stored_key);
		var proof: [Hmac.mac_length]u8 = undefined;
		for (client_key, client_signature, 0..) |key_byte, signature_byte, i| {
			proof[i] = key_byte ^ signature_byte;
		}
		var proof_buffer: [base64.Encoder.calcSize(Hmac.mac_length)]u8 = undefined;
		const final = try std.fmt.allocPrint(arena, "{s},p={s}", .{
			without_proof,
			base64.Encoder.encode(&proof_buffer, &proof),
		});
		const server_final = try self.saslToken(stream, final);

		// And the other half: the broker proves it knew the password too.
		var server_key: [Hmac.mac_length]u8 = undefined;
		Hmac.create(&server_key, "Server Key", &salted);
		var expected: [Hmac.mac_length]u8 = undefined;
		Hmac.create(&expected, auth_message, &server_key);
		var expected_buffer: [base64.Encoder.calcSize(Hmac.mac_length)]u8 = undefined;
		const want = base64.Encoder.encode(&expected_buffer, &expected);
		const got = fieldOf(server_final, 'v') orelse {
			if (fieldOf(server_final, 'e')) |why| {
				self.complain("kafka refused the SCRAM proof: {s}", .{why});
			} else {
				self.remember("the broker sent no signature of its own, so it cannot be trusted");
			}
			return error.Driver;
		};
		if (!std.mem.eql(u8, want, got)) {
			self.remember("the broker's SCRAM signature is wrong - it does not know the password it should");
			return error.Driver;
		}
	}

	// --- what the cluster is ---

	/// ApiVersions, which every broker answers before anything else. Its highest
	/// Metadata version is a good enough stand-in for the broker's release, which
	/// the protocol does not otherwise report.
	fn readVersions(self: *Db) !void {
		const reply = try self.ask(.api_versions, "");
		var read = Decoder{ .bytes = reply };
		const code = try read.int16();
		if (code != 0) {
			return error.Driver;
		}
		var highest_metadata: i16 = 0;
		var count = try read.arrayLength();
		while (count > 0) : (count -= 1) {
			const key = try read.int16();
			_ = try read.int16(); // lowest
			const max = try read.int16();
			if (key == @intFromEnum(Api.metadata)) {
				highest_metadata = max;
			}
		}
		self.version_text.clearRetainingCapacity();
		try self.version_text.print(self.allocator, "Kafka (metadata v{d})", .{highest_metadata});
	}

	/// Metadata: the brokers, and every topic with its partitions and leaders.
	/// Kept in `replies`, so it is refreshed with every statement.
	fn describeCluster(self: *Db) !void {
		const arena = self.replies.allocator();
		var body: List = .empty;
		defer body.deinit(self.allocator);
		const write = Encoder{ .out = &body, .a = self.allocator };
		try write.int32(-1); // every topic
		try write.boolean(true); // allow auto topic creation: no, but the field is v4+
		try write.boolean(false);
		try write.boolean(false);

		const reply = try self.ask(.metadata, body.items);
		var read = Decoder{ .bytes = reply };
		_ = try read.int32(); // throttle
		self.brokers.clearRetainingCapacity();
		var brokers = try read.arrayLength();
		while (brokers > 0) : (brokers -= 1) {
			const node = try read.int32();
			const host = try read.string();
			const port = try read.int32();
			_ = try read.string(); // rack
			try self.brokers.append(self.allocator, .{
				.node = node,
				.host = try arena.dupe(u8, host),
				.port = @intCast(port),
			});
		}
		const cluster = try read.string();
		self.cluster_id.clearRetainingCapacity();
		try self.cluster_id.appendSlice(self.allocator, cluster);
		_ = try read.int32(); // controller

		var topics: std.ArrayListUnmanaged(Topic) = .empty;
		var count = try read.arrayLength();
		while (count > 0) : (count -= 1) {
			const code = try read.int16();
			const name = try arena.dupe(u8, try read.string());
			const internal = (try read.int8()) != 0;
			var partitions: std.ArrayListUnmanaged(Partition) = .empty;
			var parts = try read.arrayLength();
			while (parts > 0) : (parts -= 1) {
				const part_code = try read.int16();
				const id = try read.int32();
				const node = try read.int32();
				_ = try read.int32(); // leader epoch
				const replicas = try read.arrayLength();
				var skip = replicas;
				while (skip > 0) : (skip -= 1) {
					_ = try read.int32();
				}
				const in_sync = try read.arrayLength();
				skip = in_sync;
				while (skip > 0) : (skip -= 1) {
					_ = try read.int32();
				}
				const offline = try read.arrayLength();
				skip = offline;
				while (skip > 0) : (skip -= 1) {
					_ = try read.int32();
				}
				if (part_code != 0) {
					continue; // a partition with no leader yet is not readable
				}
				try partitions.append(arena, .{
					.id = id,
					.leader = node,
					.replicas = replicas,
					.in_sync = in_sync,
				});
			}
			if (code != 0) {
				continue;
			}
			// By id, and not because it looks tidier: a page is a window over the
			// partitions in the order they are walked, so that order has to be the
			// same every time it is asked for. Metadata hands them over in whatever
			// order it likes, which made page 2 and page 3 overlap.
			std.mem.sort(Partition, partitions.items, {}, byPartitionId);
			try topics.append(arena, .{
				.name = name,
				.internal = internal,
				.partitions = partitions.items,
			});
		}
		self.topics = topics.items;
	}

	fn byPartitionId(_: void, a: Partition, b: Partition) bool {
		return a.id < b.id;
	}

	/// The topic by that name out of the metadata just read.
	fn topicOf(self: *Db, name: []const u8) ?*Topic {
		for (self.topics) |*topic| {
			if (std.mem.eql(u8, topic.name, name)) {
				return topic;
			}
		}
		return null;
	}

	/// ListOffsets for every partition of one topic, which is what a row count and
	/// a page number are made of. -2 is the earliest offset Kafka still has, -1 the
	/// next one to be written.
	fn readOffsets(self: *Db, topic: *Topic) db.Error!void {
		for (topic.partitions) |*partition| {
			partition.earliest = try self.oneOffset(topic.name, partition, -2);
			partition.latest = try self.oneOffset(topic.name, partition, -1);
		}
	}

	fn oneOffset(self: *Db, topic: []const u8, partition: *Partition, at_time: i64) db.Error!i64 {
		var body: List = .empty;
		defer body.deinit(self.allocator);
		const write = Encoder{ .out = &body, .a = self.allocator };
		try write.int32(-1); // replica id: a client, not a broker
		try write.int8(1); // isolation level: read committed
		try write.array(1);
		try write.string(topic);
		try write.array(1);
		try write.int32(partition.id);
		try write.int32(-1); // current leader epoch
		try write.int64(at_time);

		const stream = try self.leader(partition.leader);
		const reply = try self.call(stream, .list_offsets, body.items);
		var read = Decoder{ .bytes = reply };
		return self.readOneOffset(&read) catch {
			self.remember("kafka answered the offset request with something unexpected");
			return error.Driver;
		};
	}

	fn readOneOffset(self: *Db, read: *Decoder) !i64 {
		_ = try read.int32(); // throttle
		var topics = try read.arrayLength();
		var answer: i64 = 0;
		while (topics > 0) : (topics -= 1) {
			_ = try read.string();
			var parts = try read.arrayLength();
			while (parts > 0) : (parts -= 1) {
				_ = try read.int32(); // partition
				const code = try read.int16();
				_ = try read.int64(); // timestamp
				const offset = try read.int64();
				_ = try read.int32(); // leader epoch
				if (code != 0) {
					self.complain("kafka refused the offset request: {s}", .{errorText(code)});
					return error.Malformed;
				}
				answer = offset;
			}
		}
		return answer;
	}

	// --- reading records ---

	/// One Fetch from one partition, starting at `from`. The records it brings back
	/// are added to `rows` until there are `wanted` of them or the partition ends.
	/// Returns the offset reading stopped at.
	fn fetchInto(
		self: *Db,
		rows: *Rows,
		topic: *Topic,
		partition: *Partition,
		from: i64,
		wanted: usize,
		filter: Match,
	) db.Error!i64 {
		var at = from;
		while (rows.rows.items.len < wanted and at < partition.latest) {
			if (!self.keepGoing()) {
				self.remember("given up on");
				return error.Driver;
			}
			var body: List = .empty;
			defer body.deinit(self.allocator);
			const write = Encoder{ .out = &body, .a = self.allocator };
			try write.int32(-1); // replica id
			try write.int32(WAIT_MS);
			try write.int32(1); // min bytes: answer as soon as there is anything
			try write.int32(FETCH_BYTES);
			try write.int8(1); // read committed
			try write.int32(0); // session id
			try write.int32(-1); // session epoch: no session
			try write.array(1);
			try write.string(topic.name);
			try write.array(1);
			try write.int32(partition.id);
			try write.int32(-1); // current leader epoch
			try write.int64(at);
			try write.int64(-1); // log start offset, for a follower
			try write.int32(PARTITION_BYTES);
			try write.array(0); // forgotten topics
			try write.string(""); // rack id

			const stream = try self.leader(partition.leader);
			const reply = try self.call(stream, .fetch, body.items);
			var read = Decoder{ .bytes = reply };
			const before = rows.rows.items.len;
			const stopped = self.readFetch(&read, rows, topic.name, partition.id, wanted, filter, at) catch |err| {
				if (err == error.OutOfMemory) {
					return error.OutOfMemory;
				}
				if (self.last_error.items.len == 0) {
					self.remember("kafka answered the fetch with something unexpected");
				}
				return error.Driver;
			};
			// No progress at all means the partition has nothing more to give: either
			// it ended, or everything in the window was filtered out and the offset
			// moved on, which `stopped` reports.
			if (stopped <= at and rows.rows.items.len == before) {
				break;
			}
			at = stopped;
		}
		return at;
	}

	/// `floor` is the offset the fetch asked to start at. It matters: a fetch
	/// answers with whole record batches, so the batch holding that offset arrives
	/// from its own beginning and everything before the offset has to be dropped -
	/// otherwise every page begins at the start of a batch instead of where it was
	/// asked to begin.
	fn readFetch(
		self: *Db,
		read: *Decoder,
		rows: *Rows,
		topic: []const u8,
		partition: i32,
		wanted: usize,
		filter: Match,
		floor: i64,
	) !i64 {
		_ = try read.int32(); // throttle
		const code = try read.int16();
		if (code != 0) {
			self.complain("kafka refused the fetch: {s}", .{errorText(code)});
			return error.Malformed;
		}
		_ = try read.int32(); // session id
		var stopped: i64 = -1;
		var topics = try read.arrayLength();
		while (topics > 0) : (topics -= 1) {
			_ = try read.string();
			var parts = try read.arrayLength();
			while (parts > 0) : (parts -= 1) {
				_ = try read.int32(); // partition
				const part_code = try read.int16();
				const high_water = try read.int64();
				_ = try read.int64(); // last stable offset
				_ = try read.int64(); // log start offset
				var aborted = try read.arrayLength();
				while (aborted > 0) : (aborted -= 1) {
					_ = try read.int64(); // producer id
					_ = try read.int64(); // first offset
				}
				_ = try read.int32(); // preferred read replica
				const records = try read.nullableBytes();
				if (part_code != 0) {
					self.complain("kafka refused the fetch: {s}", .{errorText(part_code)});
					return error.Malformed;
				}
				stopped = high_water;
				if (records) |bytes| {
					stopped = try self.readBatches(bytes, rows, topic, partition, wanted, filter, floor);
				}
			}
		}
		return stopped;
	}

	/// Every record batch in one partition's worth of a fetch reply. A reply may
	/// end mid-batch - the byte limit is not aligned to anything - and that is not
	/// an error: whatever is complete is kept and the rest comes next time.
	fn readBatches(
		self: *Db,
		bytes: []const u8,
		rows: *Rows,
		topic: []const u8,
		partition: i32,
		wanted: usize,
		filter: Match,
		floor: i64,
	) !i64 {
		var at: usize = 0;
		var stopped: i64 = -1;
		while (at + 61 <= bytes.len) {
			var head = Decoder{ .bytes = bytes[at..] };
			const base_offset = try head.int64();
			const length = try head.int32();
			if (length < 0) {
				break;
			}
			const total = 12 + @as(usize, @intCast(length));
			if (at + total > bytes.len) {
				break; // truncated by the byte limit
			}
			const batch = bytes[at .. at + total];
			at += total;
			stopped = try self.readBatch(batch, base_offset, rows, topic, partition, wanted, filter, floor);
			if (rows.rows.items.len >= wanted) {
				break;
			}
		}
		return stopped;
	}

	fn readBatch(
		self: *Db,
		batch: []const u8,
		base_offset: i64,
		rows: *Rows,
		topic: []const u8,
		partition: i32,
		wanted: usize,
		filter: Match,
		floor: i64,
	) !i64 {
		const arena = self.replies.allocator();
		var read = Decoder{ .bytes = batch };
		_ = try read.int64(); // base offset, already had
		_ = try read.int32(); // length
		_ = try read.int32(); // partition leader epoch
		const magic = try read.int8();
		if (magic != 2) {
			self.complain("this topic holds the old message format (magic {d}), which krtek does not read", .{magic});
			return error.Malformed;
		}
		_ = try read.uint32(); // crc, which the broker has already checked
		const attributes = try read.int16();
		const last_delta = try read.int32();
		const base_time = try read.int64();
		_ = try read.int64(); // max timestamp
		_ = try read.int64(); // producer id
		_ = try read.int16(); // producer epoch
		_ = try read.int32(); // base sequence
		const count = try read.int32();

		const codec: Codec = @enumFromInt(@as(u3, @truncate(@as(u16, @bitCast(attributes)) & 0x7)));
		const control = (attributes & 0x20) != 0;
		const packed_records = read.rest();
		if (control) {
			// A transaction marker: not a record anybody wrote.
			return base_offset + @as(i64, last_delta) + 1;
		}
		const plain = decompress(arena, codec, packed_records) catch |err| switch (err) {
			error.OutOfMemory => return error.OutOfMemory,
			error.Unsupported => {
				self.complain("these records are compressed with {s}, which krtek cannot unpack", .{@tagName(codec)});
				return error.Malformed;
			},
			else => {
				self.complain("these records are compressed with {s} and did not unpack", .{@tagName(codec)});
				return error.Malformed;
			},
		};

		var body = Decoder{ .bytes = plain };
		var left = count;
		while (left > 0) : (left -= 1) {
			if (rows.rows.items.len >= wanted) {
				break;
			}
			const size = body.varint() catch break;
			if (size <= 0) {
				break;
			}
			const record = body.take(@intCast(size)) catch break;
			var one = Decoder{ .bytes = record };
			_ = try one.int8(); // attributes, unused per record
			const time_delta = try one.varlong();
			const offset_delta = try one.varint();
			const key = try takeVarBytes(&one);
			const value = try takeVarBytes(&one);
			const headers = try readHeaders(arena, &one);

			const offset = base_offset + @as(i64, offset_delta);
			// Before where this fetch was told to start: part of the batch, not part
			// of the answer.
			if (offset < floor) {
				continue;
			}
			if (!filter.keeps(key, value, offset)) {
				continue;
			}
			try rows.add(&[_]Value{
				.{ .number = partition },
				.{ .number = offset },
				.{ .text = try stamp(arena, base_time + time_delta) },
				if (key) |bytes| .{ .text = try arena.dupe(u8, bytes) } else .{ .nil = {} },
				if (value) |bytes| .{ .text = try arena.dupe(u8, bytes) } else .{ .nil = {} },
				if (headers.len != 0) .{ .text = headers } else .{ .nil = {} },
			});
		}
		_ = topic;
		return base_offset + @as(i64, last_delta) + 1;
	}

	// --- what the interface asks ---

	/// Rows of a topic. Offsets are the paging: a page is a window of offsets, so
	/// `1-50 of 12043` is exact, and reading backwards is a tail of the log.
	pub fn select(self: *Db, request: db.ask.Select) db.Error!?db.Rows {
		self.begin();
		try self.refresh();
		const topic = self.topicOf(request.table.name) orelse {
			self.complain("no topic called {s}", .{request.table.name});
			return error.Driver;
		};
		if (request.where_text.len != 0) {
			self.remember("a raw WHERE is SQL - filter partition, offset, key or value in the form");
			return error.Driver;
		}
		try self.readOffsets(topic);

		const filter = Match.of(request.where);
		const total = filter.countAcross(topic.partitions);
		if (request.count) {
			// A filter on the partition or the offset is exact and costs nothing - it
			// is arithmetic on what ListOffsets already said. One on a key or a value
			// cannot be answered without reading the log, so the count stays the
			// number of records those bounds cover: what will be looked through.
			return .{ .kafka = try self.oneNumber("records", total) };
		}

		var rows = Rows{
			.owner = self,
			.names = &COLUMNS,
			.numeric = &[_]bool{ true, true, false, false, false, false },
			.table = topic.name,
		};
		const wanted = if (request.limit != 0) request.limit else 50;

		// A page is a window over the topic's records, taken partition by partition
		// in the order the partitions come in - which is the same order the count
		// above adds them up in, so page 2 begins exactly where page 1 stopped and
		// no record is shown twice. Reading each partition from its own offset
		// instead, which is what this did at first, skips `limit` records in every
		// partition and makes the pages overlap.
		//
		// Records have no order across partitions, only within one, so this is the
		// only arrangement in which paging means anything at all.
		var skip: i64 = @intCast(request.offset);
		if (request.descending) {
			// The same window, counted from the end: the last page first.
			const from_end = total - @as(i64, @intCast(request.offset + wanted));
			skip = @max(0, from_end);
		}
		for (topic.partitions) |*partition| {
			if (rows.rows.items.len >= wanted) {
				break;
			}
			if (!filter.wantsPartition(partition.id)) {
				continue;
			}
			const available = filter.countIn(partition);
			if (skip >= available) {
				skip -= available;
				continue;
			}
			const start = filter.lowerBound(partition) + skip;
			skip = 0;
			_ = self.fetchInto(&rows, topic, partition, start, wanted, filter) catch |err| {
				rows.close();
				return err;
			};
		}
		if (request.descending) {
			std.mem.reverse([]const Value, rows.rows.items);
		}
		return .{ .kafka = rows };
	}

	/// A record cannot be changed or removed one at a time: the log is append-only
	/// and the only deletion Kafka has throws away a prefix of a partition. So an
	/// insert is a Produce and the other two say what to do instead.
	pub fn apply(self: *Db, change: db.ask.Change) db.Error!void {
		self.begin();
		try self.refresh();
		const topic = self.topicOf(change.table.name) orelse {
			self.complain("no topic called {s}", .{change.table.name});
			return error.Driver;
		};
		switch (change.kind) {
			.insert => {
				const key = flat(db.ask.valueOf(change.cells, KEY));
				const value = flat(db.ask.valueOf(change.cells, VALUE)) orelse "";
				// A partition may be asked for; without one Kafka is left to choose,
				// which for a record with a key means the hash of the key.
				const wanted = flat(db.ask.valueOf(change.cells, PARTITION));
				const chosen = if (wanted) |text| std.fmt.parseInt(i32, text, 10) catch -1 else -1;
				try self.produce(topic, chosen, key, value);
			},
			.update => {
				self.remember("a kafka record cannot be changed - the log is append-only. Write a new one with i, or PRODUCE in the editor");
				return error.Driver;
			},
			.delete => {
				const offset = db.ask.only(change.where, OFFSET) orelse "";
				self.complain(
					"kafka deletes a prefix of a partition, not one record - TRUNCATE {s} throws away everything up to the end, or DELETE RECORDS {s} {s} {s} up to an offset",
					.{ topic.name, topic.name, db.ask.only(change.where, PARTITION) orelse "0", offset },
				);
				return error.Driver;
			},
		}
	}

	/// What a request comes to, for the history and the report.
	pub fn wording(self: *Db, allocator: std.mem.Allocator, request: db.Request) db.Error![]u8 {
		var out: List = .empty;
		errdefer out.deinit(allocator);
		switch (request) {
			.select => |value| {
				if (value.count) {
					try out.print(allocator, "OFFSETS {s}", .{value.table.name});
				} else {
					const filter = Match.of(value.where);
					try out.print(allocator, "FETCH {s}", .{value.table.name});
					if (filter.partition) |id| {
						try out.print(allocator, " PARTITION {d}", .{id});
					}
					if (filter.from) |from| {
						try out.print(allocator, " FROM {d}", .{from});
					}
					try out.print(allocator, " LIMIT {d}", .{if (value.limit != 0) value.limit else 50});
				}
			},
			.change => |value| switch (value.kind) {
				.insert => try out.print(allocator, "PRODUCE {s} {s} {s}", .{
					value.table.name,
					flat(db.ask.valueOf(value.cells, KEY)) orelse "",
					flat(db.ask.valueOf(value.cells, VALUE)) orelse "",
				}),
				.update => try out.print(allocator, "-- a kafka record cannot be changed", .{}),
				.delete => try out.print(allocator, "TRUNCATE {s}", .{value.table.name}),
			},
		}
		_ = self;
		return out.toOwnedSlice(allocator);
	}

	/// The metadata again, because a statement clears the arena it lives in.
	fn refresh(self: *Db) db.Error!void {
		self.describeCluster() catch {
			if (self.last_error.items.len == 0) {
				self.remember("kafka stopped answering for its metadata");
			}
			return error.Driver;
		};
	}

	fn oneNumber(self: *Db, name: []const u8, number: i64) db.Error!Rows {
		const arena = self.replies.allocator();
		const names = try arena.alloc([]const u8, 1);
		names[0] = try arena.dupe(u8, name);
		var rows = Rows{ .owner = self, .names = names, .numeric = &[_]bool{true} };
		try rows.add(&[_]Value{.{ .number = number }});
		return rows;
	}

	fn oneText(self: *Db, name: []const u8, text: []const u8) db.Error!Rows {
		const arena = self.replies.allocator();
		const names = try arena.alloc([]const u8, 1);
		names[0] = try arena.dupe(u8, name);
		var rows = Rows{ .owner = self, .names = names };
		try rows.add(&[_]Value{.{ .text = try arena.dupe(u8, text) }});
		return rows;
	}

	// --- writing ---

	/// One record into one topic. The batch is built by hand, CRC included, because
	/// Produce takes exactly what a Fetch hands back.
	fn produce(self: *Db, topic: *Topic, wanted: i32, key: ?[]const u8, value: []const u8) db.Error!void {
		if (topic.partitions.len == 0) {
			self.complain("{s} has no partition with a leader", .{topic.name});
			return error.Driver;
		}
		var target: *Partition = &topic.partitions[0];
		if (wanted >= 0) {
			var found = false;
			for (topic.partitions) |*partition| {
				if (partition.id == wanted) {
					target = partition;
					found = true;
					break;
				}
			}
			if (!found) {
				self.complain("{s} has no partition {d}", .{ topic.name, wanted });
				return error.Driver;
			}
		} else if (key) |bytes| {
			// The same choice Kafka's own clients make, so a key keeps landing in the
			// same partition: murmur2 of the key, masked positive.
			const hash = murmur2(bytes) & 0x7fffffff;
			target = &topic.partitions[@intCast(@mod(hash, @as(i32, @intCast(topic.partitions.len))))];
		}

		const batch = try self.buildBatch(key, value);
		var body: List = .empty;
		defer body.deinit(self.allocator);
		const write = Encoder{ .out = &body, .a = self.allocator };
		try write.nullableString(null); // transactional id
		try write.int16(1); // acks: the leader
		try write.int32(15000); // timeout
		try write.array(1);
		try write.string(topic.name);
		try write.array(1);
		try write.int32(target.id);
		try write.byteArray(batch);

		const stream = try self.leader(target.leader);
		const reply = try self.call(stream, .produce, body.items);
		var read = Decoder{ .bytes = reply };
		self.readProduce(&read) catch {
			if (self.last_error.items.len == 0) {
				self.remember("kafka did not accept the record");
			}
			return error.Driver;
		};
	}

	fn readProduce(self: *Db, read: *Decoder) !void {
		var topics = try read.arrayLength();
		while (topics > 0) : (topics -= 1) {
			_ = try read.string();
			var parts = try read.arrayLength();
			while (parts > 0) : (parts -= 1) {
				_ = try read.int32(); // partition
				const code = try read.int16();
				_ = try read.int64(); // base offset
				_ = try read.int64(); // log append time
				_ = try read.int64(); // log start offset
				var errors = try read.arrayLength();
				while (errors > 0) : (errors -= 1) {
					_ = try read.int32();
					_ = try read.string();
				}
				_ = try read.string(); // error message
				if (code != 0) {
					self.complain("kafka refused the record: {s}", .{errorText(code)});
					return error.Malformed;
				}
			}
		}
		_ = try read.int32(); // throttle
	}

	/// One record in a batch of its own, uncompressed. Written into `replies`.
	fn buildBatch(self: *Db, key: ?[]const u8, value: []const u8) db.Error![]const u8 {
		const arena = self.replies.allocator();
		const now = wallMs();

		var record: List = .empty;
		const rec = Encoder{ .out = &record, .a = arena };
		try rec.int8(0); // attributes
		try rec.varlong(0); // timestamp delta
		try rec.varint(0); // offset delta
		if (key) |bytes| {
			try rec.varint(@intCast(bytes.len));
			try record.appendSlice(arena, bytes);
		} else {
			try rec.varint(-1);
		}
		try rec.varint(@intCast(value.len));
		try record.appendSlice(arena, value);
		try rec.varint(0); // no headers

		var sized: List = .empty;
		const outer = Encoder{ .out = &sized, .a = arena };
		try outer.varint(@intCast(record.items.len));
		try sized.appendSlice(arena, record.items);

		// From the attributes to the end is what the CRC covers.
		var after: List = .empty;
		const rest_of = Encoder{ .out = &after, .a = arena };
		try rest_of.int16(0); // attributes: no compression, create time
		try rest_of.int32(0); // last offset delta
		try rest_of.int64(now); // base timestamp
		try rest_of.int64(now); // max timestamp
		try rest_of.int64(-1); // producer id
		try rest_of.int16(-1); // producer epoch
		try rest_of.int32(-1); // base sequence
		try rest_of.int32(1); // one record
		try after.appendSlice(arena, sized.items);

		var batch: List = .empty;
		const head = Encoder{ .out = &batch, .a = arena };
		try head.int64(0); // base offset, which the broker assigns
		try head.int32(@intCast(4 + 1 + 4 + after.items.len)); // length after this field
		try head.int32(0); // partition leader epoch
		try head.int8(2); // magic
		try head.int32(@bitCast(crc32c(after.items)));
		try batch.appendSlice(arena, after.items);
		return batch.items;
	}

	// --- the schema, such as it is ---

	pub fn objects(self: *Db, arena: std.mem.Allocator, _: []const u8) db.Error![]db.Object {
		self.begin();
		try self.refresh();
		var list: std.ArrayListUnmanaged(db.Object) = .empty;
		for (self.topics) |*topic| {
			try self.readOffsets(topic);
			var total: i64 = 0;
			for (topic.partitions) |partition| {
				total += partition.count();
			}
			try list.append(arena, .{
				.name = try arena.dupe(u8, topic.name),
				.kind = .table,
				.rows = total,
			});
		}
		std.mem.sort(db.Object, list.items, {}, byName);
		return list.items;
	}

	fn byName(_: void, a: db.Object, b: db.Object) bool {
		return std.mem.lessThan(u8, a.name, b.name);
	}

	pub fn schemas(_: *Db, arena: std.mem.Allocator) db.Error![][]const u8 {
		return arena.alloc([]const u8, 0);
	}

	pub fn columns(_: *Db, arena: std.mem.Allocator, _: db.Table) db.Error![]db.Column {
		const list = try arena.alloc(db.Column, COLUMNS.len);
		list[0] = .{ .name = PARTITION, .type = "int", .notnull = true, .pk = true };
		list[1] = .{ .name = OFFSET, .type = "bigint", .notnull = true, .pk = true };
		list[2] = .{ .name = TIMESTAMP, .type = "timestamp", .notnull = true };
		list[3] = .{ .name = KEY, .type = "bytes" };
		list[4] = .{ .name = VALUE, .type = "bytes" };
		list[5] = .{ .name = HEADERS, .type = "text" };
		return list;
	}

	/// The partitions, which is the only structure a topic has: what an index is to
	/// a table, a partition is to a log.
	pub fn indexes(self: *Db, arena: std.mem.Allocator, table: db.Table) db.Error![]db.Index {
		self.begin();
		try self.refresh();
		const topic = self.topicOf(table.name) orelse return arena.alloc(db.Index, 0);
		try self.readOffsets(topic);
		var list: std.ArrayListUnmanaged(db.Index) = .empty;
		for (topic.partitions) |partition| {
			try list.append(arena, .{
				.name = try std.fmt.allocPrint(arena, "partition {d}", .{partition.id}),
				.kind = if (partition.id == 0) "PRIMARY" else "INDEX",
				.columns = try std.fmt.allocPrint(arena, "leader {d}, replicas {d}, in sync {d}, offsets {d}..{d}, {d} record(s)", .{
					partition.leader,
					partition.replicas,
					partition.in_sync,
					partition.earliest,
					partition.latest,
					partition.count(),
				}),
			});
		}
		return list.items;
	}

	pub fn foreignKeys(_: *Db, arena: std.mem.Allocator, _: db.Table) db.Error![]db.ForeignKey {
		return arena.alloc(db.ForeignKey, 0);
	}

	/// What DescribeConfigs says about the topic, which is as close as Kafka comes
	/// to a CREATE statement.
	pub fn definition(self: *Db, arena: std.mem.Allocator, table: db.Table) db.Error!?[]const u8 {
		self.begin();
		var body: List = .empty;
		defer body.deinit(self.allocator);
		const write = Encoder{ .out = &body, .a = self.allocator };
		try write.array(1);
		try write.int8(2); // a topic
		try write.string(table.name);
		try write.int32(-1); // every configuration entry
		try write.boolean(false); // include synonyms
		try write.boolean(false); // include documentation

		const reply = self.ask(.describe_configs, body.items) catch return null;
		var read = Decoder{ .bytes = reply };
		var out: List = .empty;
		self.readConfigs(&read, &out, arena, table.name) catch return null;
		return out.items;
	}

	fn readConfigs(self: *Db, read: *Decoder, out: *List, arena: std.mem.Allocator, name: []const u8) !void {
		_ = try read.int32(); // throttle
		var results = try read.arrayLength();
		try out.print(arena, "-- topic {s}\n", .{name});
		while (results > 0) : (results -= 1) {
			const code = try read.int16();
			const why = try read.string();
			_ = try read.int8(); // resource type
			_ = try read.string(); // resource name
			var entries = try read.arrayLength();
			if (code != 0) {
				try out.print(arena, "-- {s}\n", .{if (why.len != 0) why else errorText(code)});
			}
			while (entries > 0) : (entries -= 1) {
				const key = try read.string();
				const value = try read.string();
				_ = try read.boolean(); // read only
				const source = try read.int8();
				_ = try read.boolean(); // sensitive
				var synonyms = try read.arrayLength();
				while (synonyms > 0) : (synonyms -= 1) {
					_ = try read.string();
					_ = try read.string();
					_ = try read.int8();
				}
				// Source 5 is the broker default; showing all of those would bury the
				// handful that were actually set on this topic.
				const inherited = source == 5 or source == 4;
				try out.print(arena, "{s}{s} = {s}\n", .{ if (inherited) "-- " else "", key, value });
			}
		}
		_ = self;
	}

	pub fn rowCount(self: *Db, table: db.Table) ?i64 {
		self.begin();
		self.refresh() catch return null;
		const topic = self.topicOf(table.name) orelse return null;
		self.readOffsets(topic) catch return null;
		var total: i64 = 0;
		for (topic.partitions) |partition| {
			total += partition.count();
		}
		return total;
	}

	/// A record is addressed by its partition and its offset, exactly and always -
	/// which is why the grid can show what it is looking at even though nothing can
	/// be edited.
	pub fn rowKey(_: *Db, arena: std.mem.Allocator, _: db.Table) db.Error!db.RowKey {
		const list = try arena.alloc([]const u8, 2);
		list[0] = PARTITION;
		list[1] = OFFSET;
		return .{ .columns = list };
	}

	pub fn alterContext(_: *Db, _: std.mem.Allocator, _: db.Table, _: []const db.Column) db.Error!db.AlterContext {
		return .{};
	}

	pub fn settings(self: *Db, arena: std.mem.Allocator) db.Error![]db.Setting {
		self.begin();
		try self.refresh();
		var list: std.ArrayListUnmanaged(db.Setting) = .empty;
		try list.append(arena, .{ .label = "cluster", .value = try arena.dupe(u8, self.cluster_id.items) });
		try list.append(arena, .{ .label = "brokers", .value = try std.fmt.allocPrint(arena, "{d}", .{self.brokers.items.len}) });
		for (self.brokers.items) |broker| {
			try list.append(arena, .{
				.label = try std.fmt.allocPrint(arena, "broker {d}", .{broker.node}),
				.value = try std.fmt.allocPrint(arena, "{s}:{d}", .{ broker.host, broker.port }),
			});
		}
		var partitions: usize = 0;
		for (self.topics) |topic| {
			partitions += topic.partitions.len;
		}
		try list.append(arena, .{ .label = "topics", .value = try std.fmt.allocPrint(arena, "{d}", .{self.topics.len}) });
		try list.append(arena, .{ .label = "partitions", .value = try std.fmt.allocPrint(arena, "{d}", .{partitions}) });
		return list.items;
	}

	/// One command per line, as the console takes them.
	pub fn split(_: *Db, arena: std.mem.Allocator, sql: []const u8) db.Error![]db.Statement {
		var list: std.ArrayListUnmanaged(db.Statement) = .empty;
		var lines = std.mem.tokenizeAny(u8, sql, "\n;");
		while (lines.next()) |line| {
			const trimmed = std.mem.trim(u8, line, " \t\r");
			if (trimmed.len != 0) {
				try list.append(arena, .{ .sql = try arena.dupe(u8, trimmed) });
			}
		}
		return list.items;
	}

	pub fn ddl(_: *Db) db.Ddl {
		return .{ .kafka = .{} };
	}

	// --- the console ---

	pub fn exec(self: *Db, sql: []const u8) db.Error!void {
		var rows = (try self.query(sql, null)) orelse return;
		rows.close();
	}

	/// A Kafka command line, as typed in the editor:
	///
	///     TOPICS                       every topic, with its partitions
	///     BROKERS                      the cluster
	///     GROUPS                       the consumer groups
	///     OFFSETS <topic>              the earliest and latest offset of each partition
	///     DESCRIBE <topic>             what DescribeConfigs says
	///     CREATE <topic> [parts] [rep] a new topic
	///     DROP <topic>                 and away
	///     TRUNCATE <topic>             throw away every record, keeping the topic
	///     PRODUCE <topic> [key] <value>
	pub fn query(self: *Db, sql: []const u8, rest: ?*[]const u8) db.Error!?db.Rows {
		if (rest) |out| {
			out.* = sql[sql.len..];
		}
		const line = std.mem.trim(u8, sql, " \t\r\n;");
		if (line.len == 0) {
			return null;
		}
		self.begin();
		var words = std.mem.tokenizeAny(u8, line, " \t");
		const verb = words.next() orelse return null;
		const argument = std.mem.trim(u8, words.rest(), " \t");

		if (eq(verb, "TOPICS")) {
			return .{ .kafka = try self.listTopics() };
		}
		if (eq(verb, "BROKERS")) {
			return .{ .kafka = try self.listBrokers() };
		}
		if (eq(verb, "GROUPS")) {
			return .{ .kafka = try self.listGroups() };
		}
		if (eq(verb, "OFFSETS")) {
			return .{ .kafka = try self.listOffsets(argument) };
		}
		if (eq(verb, "DESCRIBE")) {
			var arena = std.heap.ArenaAllocator.init(self.allocator);
			defer arena.deinit();
			const text = (try self.definition(arena.allocator(), .{ .name = argument })) orelse "";
			return .{ .kafka = try self.oneText("configuration", text) };
		}
		if (eq(verb, "CREATE")) {
			return .{ .kafka = try self.createTopic(argument) };
		}
		if (eq(verb, "DROP") or eq(verb, "DELETE")) {
			return .{ .kafka = try self.dropTopic(argument) };
		}
		if (eq(verb, "TRUNCATE")) {
			return .{ .kafka = try self.truncateTopic(argument) };
		}
		if (eq(verb, "PRODUCE")) {
			return .{ .kafka = try self.produceLine(argument) };
		}
		self.complain("{s} is not a command krtek knows - try TOPICS, OFFSETS, DESCRIBE, CREATE, DROP, TRUNCATE, PRODUCE, BROKERS or GROUPS", .{verb});
		return error.Driver;
	}

	fn listTopics(self: *Db) db.Error!Rows {
		const arena = self.replies.allocator();
		try self.refresh();
		const names = try arena.alloc([]const u8, 4);
		names[0] = "topic";
		names[1] = "partitions";
		names[2] = "records";
		names[3] = "internal";
		var rows = Rows{ .owner = self, .names = names, .numeric = &[_]bool{ false, true, true, false } };
		for (self.topics) |*topic| {
			try self.readOffsets(topic);
			var total: i64 = 0;
			for (topic.partitions) |partition| {
				total += partition.count();
			}
			try rows.add(&[_]Value{
				.{ .text = topic.name },
				.{ .number = @intCast(topic.partitions.len) },
				.{ .number = total },
				.{ .text = if (topic.internal) "yes" else "no" },
			});
		}
		return rows;
	}

	fn listBrokers(self: *Db) db.Error!Rows {
		const arena = self.replies.allocator();
		try self.refresh();
		const names = try arena.alloc([]const u8, 3);
		names[0] = "broker";
		names[1] = "host";
		names[2] = "port";
		var rows = Rows{ .owner = self, .names = names, .numeric = &[_]bool{ true, false, true } };
		for (self.brokers.items) |broker| {
			try rows.add(&[_]Value{
				.{ .number = broker.node },
				.{ .text = broker.host },
				.{ .number = broker.port },
			});
		}
		return rows;
	}

	fn listGroups(self: *Db) db.Error!Rows {
		const arena = self.replies.allocator();
		const names = try arena.alloc([]const u8, 2);
		names[0] = "group";
		names[1] = "protocol";
		var rows = Rows{ .owner = self, .names = names };
		const reply = try self.ask(.list_groups, "");
		var read = Decoder{ .bytes = reply };
		self.readGroups(&read, &rows) catch {
			if (self.last_error.items.len == 0) {
				self.remember("kafka did not list its groups");
			}
			return error.Driver;
		};
		return rows;
	}

	fn readGroups(self: *Db, read: *Decoder, rows: *Rows) !void {
		_ = try read.int32(); // throttle
		const code = try read.int16();
		if (code != 0) {
			self.complain("kafka refused to list groups: {s}", .{errorText(code)});
			return error.Malformed;
		}
		var count = try read.arrayLength();
		while (count > 0) : (count -= 1) {
			const id = try read.string();
			const protocol = try read.string();
			try rows.add(&[_]Value{ .{ .text = id }, .{ .text = protocol } });
		}
	}

	fn listOffsets(self: *Db, name: []const u8) db.Error!Rows {
		const arena = self.replies.allocator();
		try self.refresh();
		const topic = self.topicOf(name) orelse {
			self.complain("no topic called {s}", .{name});
			return error.Driver;
		};
		try self.readOffsets(topic);
		const names = try arena.alloc([]const u8, 5);
		names[0] = "partition";
		names[1] = "leader";
		names[2] = "earliest";
		names[3] = "latest";
		names[4] = "records";
		var rows = Rows{ .owner = self, .names = names, .numeric = &[_]bool{ true, true, true, true, true } };
		for (topic.partitions) |partition| {
			try rows.add(&[_]Value{
				.{ .number = partition.id },
				.{ .number = partition.leader },
				.{ .number = partition.earliest },
				.{ .number = partition.latest },
				.{ .number = partition.count() },
			});
		}
		return rows;
	}

	/// `CREATE <topic> [partitions] [replication]`, with one partition and one
	/// replica unless told otherwise.
	fn createTopic(self: *Db, argument: []const u8) db.Error!Rows {
		var words = std.mem.tokenizeAny(u8, argument, " \t");
		const name = words.next() orelse {
			self.remember("CREATE needs a name: CREATE orders 3 1");
			return error.Driver;
		};
		const partitions = std.fmt.parseInt(i32, words.next() orelse "1", 10) catch 1;
		const replication = std.fmt.parseInt(i16, words.next() orelse "1", 10) catch 1;

		var body: List = .empty;
		defer body.deinit(self.allocator);
		const write = Encoder{ .out = &body, .a = self.allocator };
		try write.array(1);
		try write.string(name);
		try write.int32(partitions);
		try write.int16(replication);
		try write.array(0); // no assignments of our own
		try write.array(0); // no configuration of our own
		try write.int32(15000); // timeout
		try write.boolean(false); // validate only

		const reply = try self.ask(.create_topics, body.items);
		var read = Decoder{ .bytes = reply };
		try self.readTopicResults(&read, true);
		return self.oneText("created", name);
	}

	fn dropTopic(self: *Db, name: []const u8) db.Error!Rows {
		if (name.len == 0) {
			self.remember("DROP needs a name");
			return error.Driver;
		}
		var body: List = .empty;
		defer body.deinit(self.allocator);
		const write = Encoder{ .out = &body, .a = self.allocator };
		try write.array(1);
		try write.string(name);
		try write.int32(15000);

		const reply = try self.ask(.delete_topics, body.items);
		var read = Decoder{ .bytes = reply };
		try self.readTopicResults(&read, false);
		return self.oneText("dropped", name);
	}

	fn readTopicResults(self: *Db, read: *Decoder, created: bool) db.Error!void {
		self.readTopicResultsInner(read, created) catch {
			if (self.last_error.items.len == 0) {
				self.remember("kafka answered with something unexpected");
			}
			return error.Driver;
		};
	}

	fn readTopicResultsInner(self: *Db, read: *Decoder, created: bool) !void {
		_ = try read.int32(); // throttle
		var count = try read.arrayLength();
		while (count > 0) : (count -= 1) {
			_ = try read.string(); // name
			const code = try read.int16();
			if (created) {
				_ = try read.string(); // error message, v1+
			}
			if (code != 0) {
				self.complain("kafka refused: {s}", .{errorText(code)});
				return error.Malformed;
			}
		}
	}

	/// Every record of a topic thrown away, which for Kafka means deleting up to
	/// the latest offset of every partition. The topic itself stays.
	fn truncateTopic(self: *Db, name: []const u8) db.Error!Rows {
		try self.refresh();
		const topic = self.topicOf(name) orelse {
			self.complain("no topic called {s}", .{name});
			return error.Driver;
		};
		try self.readOffsets(topic);
		var thrown: i64 = 0;
		for (topic.partitions) |partition| {
			thrown += try self.deleteRecords(topic, partition.id, partition.latest);
		}
		return self.oneNumber("records thrown away", thrown);
	}

	/// DeleteRecords up to an offset, on one partition. Kafka answers with the new
	/// earliest offset, so the difference is what went.
	fn deleteRecords(self: *Db, topic: *Topic, partition: i32, upto: i64) db.Error!i64 {
		var was: i64 = 0;
		var node: i32 = -1;
		for (topic.partitions) |one| {
			if (one.id == partition) {
				was = one.earliest;
				node = one.leader;
			}
		}
		if (node < 0) {
			self.complain("{s} has no partition {d}", .{ topic.name, partition });
			return error.Driver;
		}
		var body: List = .empty;
		defer body.deinit(self.allocator);
		const write = Encoder{ .out = &body, .a = self.allocator };
		try write.array(1);
		try write.string(topic.name);
		try write.array(1);
		try write.int32(partition);
		try write.int64(upto);
		try write.int32(15000);

		const stream = try self.leader(node);
		const reply = try self.call(stream, .delete_records, body.items);
		var read = Decoder{ .bytes = reply };
		const now = self.readDeleteRecords(&read) catch {
			if (self.last_error.items.len == 0) {
				self.remember("kafka did not delete the records");
			}
			return error.Driver;
		};
		return if (now > was) now - was else 0;
	}

	fn readDeleteRecords(self: *Db, read: *Decoder) !i64 {
		_ = try read.int32(); // throttle
		var topics = try read.arrayLength();
		var low: i64 = 0;
		while (topics > 0) : (topics -= 1) {
			_ = try read.string();
			var parts = try read.arrayLength();
			while (parts > 0) : (parts -= 1) {
				_ = try read.int32();
				const offset = try read.int64();
				const code = try read.int16();
				if (code != 0) {
					self.complain("kafka refused to delete records: {s}", .{errorText(code)});
					return error.Malformed;
				}
				low = offset;
			}
		}
		return low;
	}

	/// `PRODUCE <topic> <value>` or `PRODUCE <topic> <key> <value>`, the value
	/// being the rest of the line so it may hold spaces.
	fn produceLine(self: *Db, argument: []const u8) db.Error!Rows {
		var words = std.mem.tokenizeAny(u8, argument, " \t");
		const name = words.next() orelse {
			self.remember("PRODUCE needs a topic: PRODUCE orders k {\"id\":1}");
			return error.Driver;
		};
		const rest_of_line = std.mem.trim(u8, words.rest(), " \t");
		if (rest_of_line.len == 0) {
			self.remember("PRODUCE needs something to send");
			return error.Driver;
		}
		// One word then the rest is a key and a value; a single word is a value.
		var key: ?[]const u8 = null;
		var value = rest_of_line;
		if (std.mem.indexOfAny(u8, rest_of_line, " \t")) |space| {
			key = rest_of_line[0..space];
			value = std.mem.trim(u8, rest_of_line[space..], " \t");
		}
		try self.refresh();
		const topic = self.topicOf(name) orelse {
			self.complain("no topic called {s}", .{name});
			return error.Driver;
		};
		try self.produce(topic, -1, key, value);
		return self.oneText("sent to", name);
	}

	pub fn inTransaction(_: *Db) bool {
		// Kafka has transactions, but this driver produces with none: a record is
		// sent or it is not.
		return false;
	}
};

fn eq(a: []const u8, b: []const u8) bool {
	return std.ascii.eqlIgnoreCase(a, b);
}

// ------------------------------------------------------------------- filtering

/// What a request's conditions come to. Only `partition` and `offset` can be
/// pushed into the fetch itself; a key or a value is compared as the records
/// arrive, which is what a log allows.
pub const Match = struct {
	partition: ?i32 = null,
	from: ?i64 = null,
	upto: ?i64 = null,
	key: ?[]const u8 = null,
	key_like: ?[]const u8 = null,
	value: ?[]const u8 = null,
	value_like: ?[]const u8 = null,

	pub fn of(where: []const db.ask.Filter) Match {
		var self = Match{};
		for (where) |filter| {
			if (std.mem.eql(u8, filter.column, PARTITION)) {
				if (filter.op == .eq) {
					self.partition = std.fmt.parseInt(i32, filter.value, 10) catch null;
				}
			} else if (std.mem.eql(u8, filter.column, OFFSET)) {
				const number = std.fmt.parseInt(i64, filter.value, 10) catch continue;
				switch (filter.op) {
					.eq => {
						self.from = number;
						self.upto = number;
					},
					.ge => self.from = number,
					.gt => self.from = number + 1,
					.le => self.upto = number,
					.lt => self.upto = number - 1,
					else => {},
				}
			} else if (std.mem.eql(u8, filter.column, KEY)) {
				switch (filter.op) {
					.eq => self.key = filter.value,
					.like => self.key_like = filter.value,
					else => {},
				}
			} else if (std.mem.eql(u8, filter.column, VALUE)) {
				switch (filter.op) {
					.eq => self.value = filter.value,
					.like => self.value_like = filter.value,
					else => {},
				}
			}
		}
		return self;
	}

	pub fn wantsPartition(self: Match, id: i32) bool {
		return if (self.partition) |only| only == id else true;
	}

	/// How many records of one partition are inside the offset bounds.
	pub fn countIn(self: Match, partition: *const Partition) i64 {
		var first = partition.earliest;
		var last = partition.latest; // one past the end
		if (self.from) |from| {
			first = @max(first, from);
		}
		if (self.upto) |upto| {
			last = @min(last, upto + 1);
		}
		return if (last > first) last - first else 0;
	}

	/// The first offset of a partition this request could want: what is still there,
	/// or what was asked for, whichever is later.
	pub fn lowerBound(self: Match, partition: *const Partition) i64 {
		if (self.from) |from| {
			return @max(from, partition.earliest);
		}
		return partition.earliest;
	}

	/// How many records the whole topic offers this request, which is what the page
	/// numbers are counted against.
	pub fn countAcross(self: Match, partitions: []const Partition) i64 {
		var total: i64 = 0;
		for (partitions) |*partition| {
			if (!self.wantsPartition(partition.id)) {
				continue;
			}
			total += self.countIn(partition);
		}
		return total;
	}

	pub fn keeps(self: Match, key: ?[]const u8, value: ?[]const u8, offset: i64) bool {
		if (self.upto) |upto| {
			if (offset > upto) {
				return false;
			}
		}
		if (self.from) |from| {
			if (offset < from) {
				return false;
			}
		}
		if (self.key) |wanted| {
			if (key == null or !std.mem.eql(u8, key.?, wanted)) {
				return false;
			}
		}
		if (self.key_like) |pattern| {
			if (!likeMatch(pattern, key orelse "")) {
				return false;
			}
		}
		if (self.value) |wanted| {
			if (value == null or !std.mem.eql(u8, value.?, wanted)) {
				return false;
			}
		}
		if (self.value_like) |pattern| {
			if (!likeMatch(pattern, value orelse "")) {
				return false;
			}
		}
		return true;
	}
};

/// SQL's LIKE, as far as a log needs it: `%` any run, `_` one byte, case
/// insensitive because a key is usually typed from memory.
pub fn likeMatch(pattern: []const u8, text: []const u8) bool {
	if (pattern.len == 0) {
		return text.len == 0;
	}
	if (pattern[0] == '%') {
		if (pattern.len == 1) {
			return true;
		}
		var at: usize = 0;
		while (at <= text.len) : (at += 1) {
			if (likeMatch(pattern[1..], text[at..])) {
				return true;
			}
		}
		return false;
	}
	if (text.len == 0) {
		return false;
	}
	if (pattern[0] == '_' or std.ascii.toLower(pattern[0]) == std.ascii.toLower(text[0])) {
		return likeMatch(pattern[1..], text[1..]);
	}
	return false;
}

// ------------------------------------------------------------------ the target

pub fn owns(target: []const u8) bool {
	for ([_][]const u8{ "kafka://", "kafka+ssl://", "kafka+tls://", "kafkas://" }) |prefix| {
		if (std.mem.startsWith(u8, target, prefix)) {
			return true;
		}
	}
	return false;
}

/// Which SASL mechanism, in the names the protocol uses.
pub const Mechanism = enum {
	none,
	plain,
	scram_sha_256,
	scram_sha_512,

	pub fn name(self: Mechanism) []const u8 {
		return switch (self) {
			.none => "",
			.plain => "PLAIN",
			.scram_sha_256 => "SCRAM-SHA-256",
			.scram_sha_512 => "SCRAM-SHA-512",
		};
	}

	pub fn of(text: []const u8) ?Mechanism {
		if (std.ascii.eqlIgnoreCase(text, "PLAIN")) {
			return .plain;
		}
		if (std.ascii.eqlIgnoreCase(text, "SCRAM-SHA-256")) {
			return .scram_sha_256;
		}
		if (std.ascii.eqlIgnoreCase(text, "SCRAM-SHA-512")) {
			return .scram_sha_512;
		}
		return null;
	}
};

pub const Parts = struct {
	host: []const u8,
	port: u16 = 9092,
	user: []const u8 = "",
	password: []const u8 = "",
	mechanism: Mechanism = .none,
	tls: bool = false,
	/// Whether the broker's certificate has to check out. Off is for a cluster
	/// with a certificate of its own making, and has to be asked for.
	verify: bool = true,

	pub fn deinit(self: Parts, allocator: std.mem.Allocator) void {
		allocator.free(self.host);
		allocator.free(self.user);
		allocator.free(self.password);
	}
};

/// `kafka://user:password@host:port?tls=1&mechanism=SCRAM-SHA-256`, with
/// `kafka+ssl://` as a shorter way of asking for TLS and the port defaulting to
/// 9092. A mechanism is only used when there is a user; with a user and no
/// mechanism it is PLAIN, which is what most brokers are set up for.
pub fn parse(allocator: std.mem.Allocator, target: []const u8) !Parts {
	var rest = target;
	var tls = false;
	for ([_][]const u8{ "kafka+ssl://", "kafka+tls://", "kafkas://" }) |prefix| {
		if (std.mem.startsWith(u8, rest, prefix)) {
			rest = rest[prefix.len..];
			tls = true;
		}
	}
	if (std.mem.startsWith(u8, rest, "kafka://")) {
		rest = rest["kafka://".len..];
	}

	// The query first, so a password with an @ or a : in it cannot be mistaken for
	// part of the address.
	var user: []const u8 = "";
	var password: []const u8 = "";
	var mechanism: ?Mechanism = null;
	var verify = true;
	if (std.mem.indexOfScalar(u8, rest, '?')) |mark| {
		var options = std.mem.tokenizeScalar(u8, rest[mark + 1 ..], '&');
		rest = rest[0..mark];
		while (options.next()) |option| {
			const equals = std.mem.indexOfScalar(u8, option, '=') orelse continue;
			const key = option[0..equals];
			const value = option[equals + 1 ..];
			if (std.mem.eql(u8, key, "password")) {
				password = value;
			} else if (std.mem.eql(u8, key, "user") or std.mem.eql(u8, key, "username")) {
				user = value;
			} else if (std.mem.eql(u8, key, "mechanism") or std.mem.eql(u8, key, "sasl")) {
				mechanism = Mechanism.of(value);
			} else if (std.mem.eql(u8, key, "tls") or std.mem.eql(u8, key, "ssl")) {
				tls = !std.mem.eql(u8, value, "0");
			} else if (std.mem.eql(u8, key, "insecure")) {
				verify = std.mem.eql(u8, value, "0");
			}
		}
	}
	// A path is not part of the address: Kafka has no database to name.
	if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
		rest = rest[0..slash];
	}
	if (std.mem.lastIndexOfScalar(u8, rest, '@')) |at| {
		const userinfo = rest[0..at];
		rest = rest[at + 1 ..];
		if (std.mem.indexOfScalar(u8, userinfo, ':')) |colon| {
			user = userinfo[0..colon];
			password = userinfo[colon + 1 ..];
		} else {
			user = userinfo;
		}
	}

	var host = rest;
	var port: u16 = if (tls) 9093 else 9092;
	if (std.mem.lastIndexOfScalar(u8, rest, ':')) |colon| {
		host = rest[0..colon];
		port = std.fmt.parseInt(u16, rest[colon + 1 ..], 10) catch port;
	}
	if (host.len == 0) {
		host = "127.0.0.1";
	}
	return .{
		.host = try allocator.dupe(u8, host),
		.port = port,
		.user = try unescape(allocator, user),
		.password = try unescape(allocator, password),
		.mechanism = if (user.len == 0) .none else (mechanism orelse .plain),
		.tls = tls,
		.verify = verify,
	};
}

/// %20 and the like, as a URL carries them.
fn unescape(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
	var out: List = .empty;
	errdefer out.deinit(allocator);
	var at: usize = 0;
	while (at < text.len) {
		if (text[at] == '%' and at + 2 < text.len) {
			const high = std.fmt.charToDigit(text[at + 1], 16) catch {
				try out.append(allocator, text[at]);
				at += 1;
				continue;
			};
			const low = std.fmt.charToDigit(text[at + 2], 16) catch {
				try out.append(allocator, text[at]);
				at += 1;
				continue;
			};
			try out.append(allocator, high * 16 + low);
			at += 3;
			continue;
		}
		try out.append(allocator, text[at]);
		at += 1;
	}
	return out.toOwnedSlice(allocator);
}

// ----------------------------------------------------------------- compression
//
// Kafka compresses a whole batch of records, and which codec is in the batch's
// attributes. gzip and zstd come out of the standard library; snappy and lz4 are
// written out here, because they are small formats and a driver that cannot read
// half the topics in the world is not much of a driver.

pub const Codec = enum(u3) {
	none = 0,
	gzip = 1,
	snappy = 2,
	lz4 = 3,
	zstd = 4,
	_,
};

pub const CompressError = error{ Malformed, Unsupported, OutOfMemory };

pub fn decompress(arena: std.mem.Allocator, codec: Codec, bytes: []const u8) CompressError![]const u8 {
	return switch (codec) {
		.none => bytes,
		.gzip => unzip(arena, bytes),
		.snappy => unsnap(arena, bytes),
		.lz4 => unlz4(arena, bytes),
		.zstd => unzstd(arena, bytes),
		_ => error.Unsupported,
	};
}

fn unzip(arena: std.mem.Allocator, bytes: []const u8) CompressError![]const u8 {
	var input = std.Io.Reader.fixed(bytes);
	var window: [std.compress.flate.max_window_len]u8 = undefined;
	var stream = std.compress.flate.Decompress.init(&input, .gzip, &window);
	return stream.reader.allocRemaining(arena, .unlimited) catch return error.Malformed;
}

fn unzstd(arena: std.mem.Allocator, bytes: []const u8) CompressError![]const u8 {
	var input = std.Io.Reader.fixed(bytes);
	const window = try arena.alloc(u8, std.compress.zstd.default_window_len + std.compress.zstd.block_size_max);
	var stream = std.compress.zstd.Decompress.init(&input, window, .{});
	return stream.reader.allocRemaining(arena, .unlimited) catch return error.Malformed;
}

/// Snappy, as Kafka writes it: the raw format, not the framed one. A varint
/// length, then a run of elements which either copy literal bytes or repeat what
/// has already been written.
pub fn unsnap(arena: std.mem.Allocator, bytes: []const u8) CompressError![]const u8 {
	// Kafka's own producers write "xerial" framing when the java client is used:
	// a magic header, then length-prefixed snappy blocks. Both shapes appear in
	// the wild, so the header decides.
	const xerial = [_]u8{ 0x82, 'S', 'N', 'A', 'P', 'P', 'Y', 0 };
	if (bytes.len > 16 and std.mem.eql(u8, bytes[0..8], &xerial)) {
		var out: List = .empty;
		var at: usize = 16; // magic, version, minimum compatible version
		while (at + 4 <= bytes.len) {
			const size = std.mem.readInt(u32, bytes[at..][0..4], .big);
			at += 4;
			if (at + size > bytes.len) {
				return error.Malformed;
			}
			const piece = try snappyBlock(arena, bytes[at .. at + size]);
			try out.appendSlice(arena, piece);
			at += size;
		}
		return out.items;
	}
	return snappyBlock(arena, bytes);
}

fn snappyBlock(arena: std.mem.Allocator, bytes: []const u8) CompressError![]const u8 {
	var at: usize = 0;
	// The uncompressed length, as a plain varint - not zig-zagged.
	var length: usize = 0;
	var shift: u6 = 0;
	while (true) {
		if (at >= bytes.len) {
			return error.Malformed;
		}
		const byte = bytes[at];
		at += 1;
		length |= @as(usize, byte & 0x7f) << shift;
		if (byte & 0x80 == 0) {
			break;
		}
		if (shift >= 28) {
			return error.Malformed;
		}
		shift += 7;
	}
	var out = try std.ArrayListUnmanaged(u8).initCapacity(arena, length);
	while (at < bytes.len) {
		const tag = bytes[at];
		at += 1;
		switch (tag & 0x3) {
			0 => {
				// A literal: its length is in the tag, or in the bytes after it.
				var count: usize = (tag >> 2) + 1;
				if (tag >> 2 >= 60) {
					const extra: usize = (tag >> 2) - 59;
					if (at + extra > bytes.len) {
						return error.Malformed;
					}
					count = 0;
					for (0..extra) |i| {
						count |= @as(usize, bytes[at + i]) << @intCast(8 * i);
					}
					count += 1;
					at += extra;
				}
				if (at + count > bytes.len) {
					return error.Malformed;
				}
				try out.appendSlice(arena, bytes[at .. at + count]);
				at += count;
			},
			1, 2, 3 => {
				var count: usize = 0;
				var distance: usize = 0;
				switch (tag & 0x3) {
					1 => {
						if (at + 1 > bytes.len) {
							return error.Malformed;
						}
						count = 4 + ((tag >> 2) & 0x7);
						distance = (@as(usize, (tag >> 5) & 0x7) << 8) | bytes[at];
						at += 1;
					},
					2 => {
						if (at + 2 > bytes.len) {
							return error.Malformed;
						}
						count = (tag >> 2) + 1;
						distance = std.mem.readInt(u16, bytes[at..][0..2], .little);
						at += 2;
					},
					else => {
						if (at + 4 > bytes.len) {
							return error.Malformed;
						}
						count = (tag >> 2) + 1;
						distance = std.mem.readInt(u32, bytes[at..][0..4], .little);
						at += 4;
					},
				}
				if (distance == 0 or distance > out.items.len) {
					return error.Malformed;
				}
				// Byte by byte on purpose: a copy may overlap itself, which is how a
				// run of the same bytes is encoded.
				var left = count;
				while (left > 0) : (left -= 1) {
					try out.append(arena, out.items[out.items.len - distance]);
				}
			},
			else => unreachable,
		}
	}
	return out.items;
}

/// LZ4, in the frame format Kafka uses. Only the parts a broker's payload can
/// contain: no dictionaries, no legacy frames.
pub fn unlz4(arena: std.mem.Allocator, bytes: []const u8) CompressError![]const u8 {
	if (bytes.len < 7 or std.mem.readInt(u32, bytes[0..4], .little) != 0x184D2204) {
		return error.Malformed;
	}
	const flags = bytes[4];
	// Block independence is not read: dependent blocks may copy from the block
	// before them, and since every block is appended to one buffer here and a copy
	// looks that far back regardless, both kinds come out the same.
	const has_content_size = (flags & 0x08) != 0;
	const has_dictionary = (flags & 0x01) != 0;
	if (has_dictionary) {
		return error.Unsupported;
	}
	// magic(4) FLG(1) BD(1) [content size(8)] HC(1), and no dictionary id because
	// a dictionary was refused above.
	var at: usize = 4 + 1 + 1;
	if (has_content_size) {
		at += 8;
	}
	at += 1; // the header checksum, which the broker has already honoured
	var out: List = .empty;
	while (at + 4 <= bytes.len) {
		const word = std.mem.readInt(u32, bytes[at..][0..4], .little);
		at += 4;
		if (word == 0) {
			break; // the end mark
		}
		const stored = (word & 0x80000000) != 0;
		const size: usize = word & 0x7fffffff;
		if (at + size > bytes.len) {
			return error.Malformed;
		}
		const block = bytes[at .. at + size];
		at += size;
		if (stored) {
			try out.appendSlice(arena, block);
		} else {
			try lz4Block(arena, block, &out);
		}
		if ((flags & 0x10) != 0) {
			at += 4; // a checksum per block
		}
	}
	return out.items;
}

fn lz4Block(arena: std.mem.Allocator, block: []const u8, out: *List) CompressError!void {
	var at: usize = 0;
	while (at < block.len) {
		const token = block[at];
		at += 1;
		var literals: usize = token >> 4;
		if (literals == 15) {
			while (at < block.len) {
				const byte = block[at];
				at += 1;
				literals += byte;
				if (byte != 255) {
					break;
				}
			}
		}
		if (at + literals > block.len) {
			return error.Malformed;
		}
		try out.appendSlice(arena, block[at .. at + literals]);
		at += literals;
		if (at >= block.len) {
			return; // the last sequence has no match
		}
		if (at + 2 > block.len) {
			return error.Malformed;
		}
		const distance: usize = std.mem.readInt(u16, block[at..][0..2], .little);
		at += 2;
		var length: usize = token & 0xf;
		if (length == 15) {
			while (at < block.len) {
				const byte = block[at];
				at += 1;
				length += byte;
				if (byte != 255) {
					break;
				}
			}
		}
		length += 4; // the minimum match
		if (distance == 0 or distance > out.items.len) {
			return error.Malformed;
		}
		var left = length;
		while (left > 0) : (left -= 1) {
			try out.append(arena, out.items[out.items.len - distance]);
		}
	}
}

// ---------------------------------------------------------------------- pieces

/// A length-prefixed field inside a record: a varint length, -1 for absent.
fn takeVarBytes(read: *Decoder) DecodeError!?[]const u8 {
	const length = try read.varint();
	if (length < 0) {
		return null;
	}
	return try read.take(@intCast(length));
}

/// The headers of one record, as `name=value` separated by commas - one line,
/// because that is what a grid cell is.
fn readHeaders(arena: std.mem.Allocator, read: *Decoder) DecodeError![]const u8 {
	const count = read.varint() catch return "";
	if (count <= 0) {
		return "";
	}
	var out: List = .empty;
	var left = count;
	while (left > 0) : (left -= 1) {
		const name = (try takeVarBytes(read)) orelse "";
		const value = (try takeVarBytes(read)) orelse "";
		if (out.items.len != 0) {
			try out.appendSlice(arena, ", ");
		}
		try out.appendSlice(arena, name);
		try out.append(arena, '=');
		try out.appendSlice(arena, value);
	}
	return out.items;
}

/// Milliseconds since the epoch. std.time.milliTimestamp is gone in this Zig, so
/// the clock is read the way the rest of the program reads the monotonic one.
pub fn wallMs() i64 {
	var now: std.c.timespec = undefined;
	if (std.c.clock_gettime(.REALTIME, &now) != 0) {
		return 0;
	}
	return @as(i64, @intCast(now.sec)) * 1000 + @divFloor(@as(i64, @intCast(now.nsec)), 1_000_000);
}

/// A Kafka timestamp - milliseconds since the epoch - as something readable. UTC,
/// because a broker's records are not in anybody's local time.
pub fn stamp(arena: std.mem.Allocator, millis: i64) ![]const u8 {
	if (millis <= 0) {
		return arena.dupe(u8, "");
	}
	const seconds: u64 = @intCast(@divFloor(millis, 1000));
	const ms: u64 = @intCast(@mod(millis, 1000));
	const epoch = std.time.epoch.EpochSeconds{ .secs = seconds };
	const day = epoch.getEpochDay();
	const year_day = day.calculateYearDay();
	const month_day = year_day.calculateMonthDay();
	const time = epoch.getDaySeconds();
	return std.fmt.allocPrint(arena, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{
		year_day.year,
		month_day.month.numeric(),
		month_day.day_index + 1,
		time.getHoursIntoDay(),
		time.getMinutesIntoHour(),
		time.getSecondsIntoMinute(),
		ms,
	});
}

/// Bytes nobody can guess, for a SCRAM nonce. std.crypto.random is gone in this
/// Zig and arc4random is not on musl, so this is the source both systems have.
pub fn randomBytes(into: []u8) !void {
	const fd = std.c.open("/dev/urandom", .{ .ACCMODE = .RDONLY });
	if (fd < 0) {
		return error.NoRandom;
	}
	defer _ = std.c.close(fd);
	var got: usize = 0;
	while (got < into.len) {
		const read = std.c.read(fd, into[got..].ptr, into.len - got);
		if (read <= 0) {
			return error.NoRandom;
		}
		got += @intCast(read);
	}
}

/// A SCRAM message is a comma-separated list of `k=value`, and this is one of
/// them - the first with that letter, which is all SCRAM has.
pub fn fieldOf(message: []const u8, key: u8) ?[]const u8 {
	var parts = std.mem.tokenizeScalar(u8, message, ',');
	while (parts.next()) |part| {
		if (part.len >= 2 and part[0] == key and part[1] == '=') {
			return part[2..];
		}
	}
	return null;
}

/// A user name inside a SCRAM message, where a comma and an equals sign have to
/// be spelled out or they would end the field.
pub fn escapeName(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
	var out: List = .empty;
	for (name) |char| {
		switch (char) {
			'=' => try out.appendSlice(arena, "=3D"),
			',' => try out.appendSlice(arena, "=2C"),
			else => try out.append(arena, char),
		}
	}
	return out.items;
}

/// A cell of a change that was given a value: a change may set a column to NULL,
/// and for a record that is not a value.
fn flat(value: ??[]const u8) ?[]const u8 {
	const inner = value orelse return null;
	return inner orelse null;
}

/// CRC-32C, which is what a record batch carries. Table built at compile time.
pub fn crc32c(bytes: []const u8) u32 {
	const table = comptime blk: {
		@setEvalBranchQuota(20000);
		var built: [256]u32 = undefined;
		for (0..256) |i| {
			var value: u32 = @intCast(i);
			for (0..8) |_| {
				value = if (value & 1 != 0) (value >> 1) ^ 0x82f63b78 else value >> 1;
			}
			built[i] = value;
		}
		break :blk built;
	};
	var crc: u32 = 0xffffffff;
	for (bytes) |byte| {
		crc = table[(crc ^ byte) & 0xff] ^ (crc >> 8);
	}
	return crc ^ 0xffffffff;
}

/// The hash Kafka's own clients use to choose a partition for a key, so a key
/// written from here lands where it would have landed from anywhere else.
pub fn murmur2(bytes: []const u8) i32 {
	const seed: u32 = 0x9747b28c;
	const m: u32 = 0x5bd1e995;
	const r: u5 = 24;
	var h: u32 = seed ^ @as(u32, @intCast(bytes.len));
	var at: usize = 0;
	while (at + 4 <= bytes.len) : (at += 4) {
		var k: u32 = std.mem.readInt(u32, bytes[at..][0..4], .little);
		k *%= m;
		k ^= k >> r;
		k *%= m;
		h *%= m;
		h ^= k;
	}
	const left = bytes.len - at;
	if (left == 3) {
		h ^= @as(u32, bytes[at + 2]) << 16;
	}
	if (left >= 2) {
		h ^= @as(u32, bytes[at + 1]) << 8;
	}
	if (left >= 1) {
		h ^= @as(u32, bytes[at]);
		h *%= m;
	}
	h ^= h >> 13;
	h *%= m;
	h ^= h >> 15;
	return @bitCast(h);
}

/// The error codes a broker sends back, in the words the protocol gives them.
pub fn errorText(code: i16) []const u8 {
	return switch (code) {
		0 => "none",
		1 => "the offset is out of range",
		2 => "the record is corrupt",
		3 => "no such topic or partition",
		5 => "the leader is not available yet",
		6 => "this broker is not the leader for that partition",
		7 => "the request timed out",
		8 => "the broker is not available",
		9 => "the replica is not available",
		10 => "the message is larger than the broker allows",
		13 => "the network failed mid-request",
		15 => "the coordinator is not available",
		17 => "the topic is being reassigned",
		19 => "not enough replicas to accept the write",
		20 => "not enough replicas after appending",
		21 => "the requested acks are invalid",
		29, 30, 31 => "not authorised for that",
		36 => "the topic already exists",
		37 => "the number of partitions is invalid",
		38 => "the replication factor is invalid",
		39 => "the replica assignment is invalid",
		40 => "the configuration is invalid",
		41 => "this broker is not the controller",
		58 => "the request is not allowed on that resource",
		87 => "the records are not in order",
		else => "an error the broker did not name",
	};
}

// -------------------------------------------------------------------------- DDL

/// Kafka's schema changes, as command lines the console understands - the same
/// arrangement Redis has, because neither engine has SQL to generate.
pub const Ddl = struct {
	pub fn createTable(_: Ddl, out: *List, a: std.mem.Allocator, table: db.Table, cols: []const db.Column, _: []const db.ForeignKey) !void {
		// Columns are fixed for every topic, so the form's are ignored: what a new
		// topic needs is a number of partitions.
		_ = cols;
		try out.print(a, "CREATE {s} 1 1\n", .{table.name});
	}

	pub fn alterTable(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table, _: []const u8, _: []const db.Column, _: db.AlterContext) !void {
		try refuse(out, a, "columns to change - every topic has the same six");
	}

	pub fn addForeignKey(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table, _: db.ForeignKey, _: db.AlterContext) !void {
		try refuse(out, a, "foreign keys");
	}

	pub fn createIndex(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table, _: []const u8, _: []const []const u8, _: bool, _: []const u8) !void {
		try refuse(out, a, "indexes - a partition is the only one there is");
	}

	pub fn createView(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table, _: []const u8) !void {
		try refuse(out, a, "views");
	}

	pub fn createTrigger(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table, _: []const u8, _: []const u8, _: []const u8, _: []const u8, _: []const u8) !void {
		try refuse(out, a, "triggers");
	}

	pub fn renameTable(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table, _: []const u8) !void {
		try refuse(out, a, "renaming a topic");
	}

	pub fn copyTable(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table, _: []const u8, _: bool) !void {
		try refuse(out, a, "copying a topic");
	}

	pub fn dropObject(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Kind, table: db.Table) !void {
		try out.print(a, "DROP {s}\n", .{table.name});
	}

	pub fn truncate(_: Ddl, out: *List, a: std.mem.Allocator, table: db.Table) !void {
		try out.print(a, "TRUNCATE {s}\n", .{table.name});
	}

	pub fn insertRow(_: Ddl, out: *List, a: std.mem.Allocator, table: db.Table, cols: []const []const u8, values: []const []const u8) !void {
		var key: []const u8 = "";
		var value: []const u8 = "";
		for (cols, 0..) |name, i| {
			if (i >= values.len) {
				break;
			}
			if (std.mem.eql(u8, name, KEY)) {
				key = values[i];
			} else if (std.mem.eql(u8, name, VALUE)) {
				value = values[i];
			}
		}
		try out.print(a, "PRODUCE {s} {s} {s}\n", .{ table.name, key, value });
	}

	pub fn types(_: Ddl) []const []const u8 {
		return &[_][]const u8{ "int", "bigint", "timestamp", "bytes", "text" };
	}
};

fn refuse(out: *List, a: std.mem.Allocator, what: []const u8) !void {
	try out.print(a, "-- kafka has no {s}\n", .{what});
}

// -------------------------------------------------------------------- tests

const testing = std.testing;

test "a varint survives the round trip, sign and all" {
	var out: List = .empty;
	defer out.deinit(testing.allocator);
	const write = Encoder{ .out = &out, .a = testing.allocator };
	const numbers = [_]i64{ 0, 1, -1, 63, 64, -64, -65, 127, 128, 300, -300, 1 << 20, -(1 << 20), std.math.maxInt(i32), std.math.minInt(i32) };
	for (numbers) |number| {
		try write.varlong(number);
	}
	var read = Decoder{ .bytes = out.items };
	for (numbers) |number| {
		try testing.expectEqual(number, try read.varlong());
	}
	try testing.expectEqual(out.items.len, read.at);
}

test "the fixed width numbers are big endian, as the protocol says" {
	var out: List = .empty;
	defer out.deinit(testing.allocator);
	const write = Encoder{ .out = &out, .a = testing.allocator };
	try write.int16(1);
	try write.int32(-2);
	try write.int64(258);
	try testing.expectEqualSlices(u8, &[_]u8{
		0, 1,
		0xff, 0xff, 0xff, 0xfe,
		0, 0, 0, 0, 0, 0, 1, 2,
	}, out.items);

	var read = Decoder{ .bytes = out.items };
	try testing.expectEqual(@as(i16, 1), try read.int16());
	try testing.expectEqual(@as(i32, -2), try read.int32());
	try testing.expectEqual(@as(i64, 258), try read.int64());
}

test "a string and a byte array carry their own length, and absence is -1" {
	var out: List = .empty;
	defer out.deinit(testing.allocator);
	const write = Encoder{ .out = &out, .a = testing.allocator };
	try write.string("orders");
	try write.nullableString(null);
	try write.byteArray(null);
	try write.byteArray("ab");

	var read = Decoder{ .bytes = out.items };
	try testing.expectEqualStrings("orders", try read.string());
	try testing.expectEqualStrings("", try read.string());
	try testing.expect((try read.nullableBytes()) == null);
	try testing.expectEqualStrings("ab", (try read.nullableBytes()).?);
}

test "CRC-32C is the one a record batch carries" {
	// The check value every CRC-32C implementation is measured by.
	try testing.expectEqual(@as(u32, 0xe3069283), crc32c("123456789"));
	try testing.expectEqual(@as(u32, 0), crc32c(""));
}

test "murmur2 puts a key where kafka's own client would put it" {
	// Nine keys were written to a three-partition topic by kafka-console-producer,
	// which chooses the partition with murmur2 of the key. This is where its Java
	// implementation put them, so it is where this one has to put them too.
	const expected = [_]struct { key: []const u8, partition: i32 }{
		.{ .key = "key1", .partition = 2 },
		.{ .key = "key2", .partition = 2 },
		.{ .key = "key3", .partition = 1 },
		.{ .key = "key4", .partition = 0 },
		.{ .key = "key5", .partition = 1 },
		.{ .key = "key6", .partition = 0 },
		.{ .key = "key7", .partition = 0 },
		.{ .key = "key8", .partition = 1 },
		.{ .key = "key9", .partition = 2 },
	};
	for (expected) |one| {
		const hash = murmur2(one.key) & 0x7fffffff;
		try testing.expectEqual(one.partition, @mod(hash, 3));
	}
}

test "snappy: a literal, and a copy that overlaps itself" {
	var arena = std.heap.ArenaAllocator.init(testing.allocator);
	defer arena.deinit();
	const a = arena.allocator();

	// Length 3, then one literal element of three bytes.
	try testing.expectEqualStrings("abc", try unsnap(a, &[_]u8{ 0x03, 0x08, 'a', 'b', 'c' }));
	// Length 9: the same literal, then six bytes copied from three back - which
	// runs into what it is writing, and that is how a repeat is spelled.
	try testing.expectEqualStrings("abcabcabc", try unsnap(a, &[_]u8{
		0x09, 0x08, 'a', 'b', 'c', 0x09, 0x03,
	}));
}

test "lz4: a stored block and a compressed one" {
	var arena = std.heap.ArenaAllocator.init(testing.allocator);
	defer arena.deinit();
	const a = arena.allocator();

	const stored = [_]u8{
		0x04, 0x22, 0x4d, 0x18, // magic
		0x40, 0x70, 0x00, // flags, block descriptor, header checksum
		0x03, 0x00, 0x00, 0x80, // one stored block of three bytes
		'a',  'b',  'c',
		0x00, 0x00, 0x00, 0x00, // the end mark
	};
	try testing.expectEqualStrings("abc", try unlz4(a, &stored));

	const packed_block = [_]u8{ 0x32, 'a', 'b', 'c', 0x03, 0x00 };
	var frame: List = .empty;
	try frame.appendSlice(a, &[_]u8{ 0x04, 0x22, 0x4d, 0x18, 0x40, 0x70, 0x00 });
	try frame.appendSlice(a, &[_]u8{ @intCast(packed_block.len), 0x00, 0x00, 0x00 });
	try frame.appendSlice(a, &packed_block);
	try frame.appendSlice(a, &[_]u8{ 0x00, 0x00, 0x00, 0x00 });
	try testing.expectEqualStrings("abcabcabc", try unlz4(a, frame.items));
}

test "gzip comes out of the standard library, and is checked here anyway" {
	var arena = std.heap.ArenaAllocator.init(testing.allocator);
	defer arena.deinit();
	// "abc" as gzip, from gzip -9n, so this is a real member and not a fixture of
	// this program's own making.
	const packed_bytes = [_]u8{
		0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x03,
		0x4b, 0x4c, 0x4a, 0x06, 0x00,
		0xc2, 0x41, 0x24, 0x35, 0x03, 0x00, 0x00, 0x00,
	};
	try testing.expectEqualStrings("abc", try decompress(arena.allocator(), .gzip, &packed_bytes));
}

test "a codec krtek does not know says so rather than returning rubbish" {
	var arena = std.heap.ArenaAllocator.init(testing.allocator);
	defer arena.deinit();
	const made_up: Codec = @enumFromInt(6);
	try testing.expectError(error.Unsupported, decompress(arena.allocator(), made_up, "anything"));
	// And no compression is the bytes themselves.
	try testing.expectEqualStrings("plain", try decompress(arena.allocator(), .none, "plain"));
}

test "LIKE, as far as a log needs it" {
	try testing.expect(likeMatch("%user%", "my-user-7"));
	try testing.expect(likeMatch("user%", "user:7"));
	try testing.expect(!likeMatch("user%", "the-user"));
	try testing.expect(likeMatch("key_", "key5"));
	try testing.expect(!likeMatch("key_", "key55"));
	try testing.expect(likeMatch("%", ""));
	try testing.expect(likeMatch("KEY5", "key5")); // typed from memory
	try testing.expect(!likeMatch("", "something"));
}

test "conditions become the fetch's bounds, and the rest is compared as records arrive" {
	const filter = Match.of(&.{
		.{ .column = PARTITION, .value = "2" },
		.{ .column = OFFSET, .op = .ge, .value = "100" },
		.{ .column = OFFSET, .op = .lt, .value = "110" },
		.{ .column = KEY, .op = .like, .value = "user%" },
	});
	try testing.expectEqual(@as(i32, 2), filter.partition.?);
	try testing.expectEqual(@as(i64, 100), filter.from.?);
	try testing.expectEqual(@as(i64, 109), filter.upto.?);
	try testing.expect(filter.wantsPartition(2));
	try testing.expect(!filter.wantsPartition(0));
	try testing.expect(filter.keeps("user:1", "x", 105));
	try testing.expect(!filter.keeps("cart:1", "x", 105)); // the key does not match
	try testing.expect(!filter.keeps("user:1", "x", 99)); // before the window
	try testing.expect(!filter.keeps("user:1", "x", 110)); // after it

	const partition = Partition{ .id = 2, .leader = 1, .earliest = 50, .latest = 500 };
	// The window the bounds describe, which is what the count reports.
	try testing.expectEqual(@as(i64, 10), filter.countIn(&partition));
	// Reading starts at the offset that was asked for, not at what is still there.
	try testing.expectEqual(@as(i64, 100), filter.lowerBound(&partition));

	const nothing = Match{};
	try testing.expectEqual(@as(i64, 450), nothing.countIn(&partition));
	try testing.expectEqual(@as(i64, 50), nothing.lowerBound(&partition));
}

test "an equality on the value is an equality, not a substring" {
	const exact = Match.of(&.{.{ .column = VALUE, .value = "done" }});
	try testing.expect(exact.keeps("k", "done", 1));
	try testing.expect(!exact.keeps("k", "done and dusted", 1));
	try testing.expect(!exact.keeps("k", null, 1));

	const loose = Match.of(&.{.{ .column = VALUE, .op = .like, .value = "%done%" }});
	try testing.expect(loose.keeps("k", "done", 1));
	try testing.expect(loose.keeps("k", "done and dusted", 1));
	try testing.expect(!loose.keeps("k", "nothing here", 1));
}

test "a page is a window over the topic, so pages do not overlap" {
	// Three partitions with three records each: nine altogether, which is what the
	// count says and therefore what the page numbers are counted against.
	const partitions = [_]Partition{
		.{ .id = 0, .leader = 1, .earliest = 0, .latest = 3 },
		.{ .id = 1, .leader = 1, .earliest = 100, .latest = 103 },
		.{ .id = 2, .leader = 1, .earliest = 50, .latest = 53 },
	};
	const filter = Match{};
	try testing.expectEqual(@as(i64, 9), filter.countAcross(&partitions));

	// Walking a page of four the way select() does: which partition it starts in
	// and at which offset. Page two has to begin where page one stopped - that is
	// the whole point, and applying the page to every partition instead was the bug
	// this test was written for.
	const Step = struct { partition: i32, offset: i64 };
	const walk = struct {
		fn of(list: []const Partition, match: Match, skip_in: i64, wanted: usize, out: *std.ArrayListUnmanaged(Step), a: std.mem.Allocator) !void {
			var skip = skip_in;
			var taken: usize = 0;
			for (list) |*partition| {
				if (taken >= wanted) {
					break;
				}
				const available = match.countIn(partition);
				if (skip >= available) {
					skip -= available;
					continue;
				}
				const start = match.lowerBound(partition) + skip;
				skip = 0;
				var at = start;
				while (at < partition.latest and taken < wanted) : (at += 1) {
					try out.append(a, .{ .partition = partition.id, .offset = at });
					taken += 1;
				}
			}
		}
	}.of;

	var arena = std.heap.ArenaAllocator.init(testing.allocator);
	defer arena.deinit();
	const a = arena.allocator();

	var first: std.ArrayListUnmanaged(Step) = .empty;
	try walk(&partitions, filter, 0, 4, &first, a);
	var second: std.ArrayListUnmanaged(Step) = .empty;
	try walk(&partitions, filter, 4, 4, &second, a);
	var third: std.ArrayListUnmanaged(Step) = .empty;
	try walk(&partitions, filter, 8, 4, &third, a);

	try testing.expectEqualSlices(Step, &[_]Step{
		.{ .partition = 0, .offset = 0 },
		.{ .partition = 0, .offset = 1 },
		.{ .partition = 0, .offset = 2 },
		.{ .partition = 1, .offset = 100 },
	}, first.items);
	try testing.expectEqualSlices(Step, &[_]Step{
		.{ .partition = 1, .offset = 101 },
		.{ .partition = 1, .offset = 102 },
		.{ .partition = 2, .offset = 50 },
		.{ .partition = 2, .offset = 51 },
	}, second.items);
	// The last page is short, and stops rather than wrapping.
	try testing.expectEqualSlices(Step, &[_]Step{.{ .partition = 2, .offset = 52 }}, third.items);

	// Every record exactly once across the three pages.
	try testing.expectEqual(@as(usize, 9), first.items.len + second.items.len + third.items.len);
}

test "a partition filter narrows what the pages are counted against" {
	const partitions = [_]Partition{
		.{ .id = 0, .leader = 1, .earliest = 0, .latest = 3 },
		.{ .id = 1, .leader = 1, .earliest = 0, .latest = 5 },
	};
	const only_one = Match.of(&.{.{ .column = PARTITION, .value = "1" }});
	try testing.expectEqual(@as(i64, 5), only_one.countAcross(&partitions));
}

test "a timestamp is readable, and zero is nothing" {
	var arena = std.heap.ArenaAllocator.init(testing.allocator);
	defer arena.deinit();
	const a = arena.allocator();
	try testing.expectEqualStrings("2026-08-10 19:37:36.777", try stamp(a, 1786390656777));
	try testing.expectEqualStrings("1970-01-01 00:00:01.000", try stamp(a, 1000));
	try testing.expectEqualStrings("", try stamp(a, 0));
}

test "a kafka target is taken apart" {
	const a = testing.allocator;
	{
		const parts = try parse(a, "kafka://broker.example:9095");
		defer parts.deinit(a);
		try testing.expectEqualStrings("broker.example", parts.host);
		try testing.expectEqual(@as(u16, 9095), parts.port);
	}
	{
		const parts = try parse(a, "kafka://127.0.0.1");
		defer parts.deinit(a);
		try testing.expectEqualStrings("127.0.0.1", parts.host);
		try testing.expectEqual(@as(u16, 9092), parts.port);
	}
	{
		// A path is not part of the address; Kafka has no database to name.
		const parts = try parse(a, "kafka://127.0.0.1:9093/whatever");
		defer parts.deinit(a);
		try testing.expectEqualStrings("127.0.0.1", parts.host);
		try testing.expectEqual(@as(u16, 9093), parts.port);
	}
	try testing.expect(owns("kafka://localhost"));
	try testing.expect(!owns("redis://localhost"));
	try testing.expect(!owns("postgres://localhost"));
}

test "every API this driver speaks is one the broker still answers without flexible encoding" {
	// The point of these versions: none of them uses compact strings or tagged
	// fields, so there is one encoding in this file instead of two.
	try testing.expectEqual(@as(i16, 11), versionOf(.fetch));
	try testing.expectEqual(@as(i16, 7), versionOf(.metadata));
	try testing.expectEqual(@as(i16, 0), versionOf(.api_versions));
	inline for (std.meta.fields(Api)) |field| {
		const api: Api = @enumFromInt(field.value);
		try testing.expect(versionOf(api) >= 0);
	}
}

test "a target carries what it takes to reach the cluster" {
	const a = testing.allocator;
	{
		// TLS by scheme, and a port that follows from it.
		const parts = try parse(a, "kafka+ssl://broker.example");
		defer parts.deinit(a);
		try testing.expect(parts.tls);
		try testing.expectEqual(@as(u16, 9093), parts.port);
		try testing.expectEqual(Mechanism.none, parts.mechanism);
	}
	{
		// A user with no mechanism named is PLAIN, which is what brokers are set up
		// for; the password may be escaped, and an @ inside it is not the host.
		const parts = try parse(a, "kafka://alice@broker:9095?password=p%40ss%20word");
		defer parts.deinit(a);
		try testing.expectEqualStrings("broker", parts.host);
		try testing.expectEqual(@as(u16, 9095), parts.port);
		try testing.expectEqualStrings("alice", parts.user);
		try testing.expectEqualStrings("p@ss word", parts.password);
		try testing.expectEqual(Mechanism.plain, parts.mechanism);
		try testing.expect(!parts.tls);
	}
	{
		const parts = try parse(a, "kafka://bob:hunter2@broker:9093?tls=1&mechanism=SCRAM-SHA-512&insecure=1");
		defer parts.deinit(a);
		try testing.expectEqualStrings("bob", parts.user);
		try testing.expectEqualStrings("hunter2", parts.password);
		try testing.expectEqual(Mechanism.scram_sha_512, parts.mechanism);
		try testing.expect(parts.tls);
		try testing.expect(!parts.verify); // asked for, not assumed
	}
	{
		// No user at all: no authentication, and the certificate still verified.
		const parts = try parse(a, "kafka://127.0.0.1:9093");
		defer parts.deinit(a);
		try testing.expectEqual(Mechanism.none, parts.mechanism);
		try testing.expect(parts.verify);
	}
	try testing.expect(owns("kafka+ssl://x"));
	try testing.expectEqualStrings("SCRAM-SHA-256", Mechanism.scram_sha_256.name());
	try testing.expectEqual(Mechanism.plain, Mechanism.of("plain").?);
	try testing.expect(Mechanism.of("GSSAPI") == null);
}

test "SCRAM's messages are read and written the way the standard spells them" {
	var arena = std.heap.ArenaAllocator.init(testing.allocator);
	defer arena.deinit();
	const a = arena.allocator();

	const server_first = "r=abcdefXYZ,s=QSXCR+Q6sek8bf92,i=4096";
	try testing.expectEqualStrings("abcdefXYZ", fieldOf(server_first, 'r').?);
	try testing.expectEqualStrings("QSXCR+Q6sek8bf92", fieldOf(server_first, 's').?);
	try testing.expectEqualStrings("4096", fieldOf(server_first, 'i').?);
	try testing.expect(fieldOf(server_first, 'v') == null);
	try testing.expectEqualStrings("rmF9pqV8S7suAoZWja4dJRkFsKQ=", fieldOf("v=rmF9pqV8S7suAoZWja4dJRkFsKQ=", 'v').?);
	try testing.expectEqualStrings("invalid-proof", fieldOf("e=invalid-proof", 'e').?);

	// A comma or an equals sign in a user name would end the field, so they are
	// spelled out.
	try testing.expectEqualStrings("a=2Cb=3Dc", try escapeName(a, "a,b=c"));
	try testing.expectEqualStrings("plain", try escapeName(a, "plain"));
}

test "the proof is the client key against its signature, as RFC 5802 has it" {
	// The example from the RFC: user "user", password "pencil", and the salt and
	// nonces it gives. If this matches, the derivation and the exclusive-or are
	// right, which is the part a broker checks.
	const Hmac = std.crypto.auth.hmac.HmacSha1;
	const Hash = std.crypto.hash.Sha1;
	const base64 = std.base64.standard;
	// Twelve bytes, not sixteen: the length has to come from the base64 itself, and
	// getting that wrong is exactly the bug this test caught when it was written.
	const salt_text = "QSXCR+Q6sek8bf92";
	var salt: [try base64.Decoder.calcSizeForSlice(salt_text)]u8 = undefined;
	try base64.Decoder.decode(&salt, salt_text);

	var salted: [Hmac.mac_length]u8 = undefined;
	try std.crypto.pwhash.pbkdf2(&salted, "pencil", &salt, 4096, Hmac);
	var client_key: [Hmac.mac_length]u8 = undefined;
	Hmac.create(&client_key, "Client Key", &salted);
	var stored_key: [Hash.digest_length]u8 = undefined;
	Hash.hash(&client_key, &stored_key, .{});

	const auth_message = "n=user,r=fyko+d2lbbFgONRv9qkxdawL," ++
		"r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j,s=QSXCR+Q6sek8bf92,i=4096," ++
		"c=biws,r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j";
	var signature: [Hmac.mac_length]u8 = undefined;
	Hmac.create(&signature, auth_message, &stored_key);
	var proof: [Hmac.mac_length]u8 = undefined;
	for (client_key, signature, 0..) |key_byte, signature_byte, i| {
		proof[i] = key_byte ^ signature_byte;
	}
	var buffer: [base64.Encoder.calcSize(Hmac.mac_length)]u8 = undefined;
	try testing.expectEqualStrings("v0X8v3Bz2T0CJGbJQyF0X+HI4Ts=", base64.Encoder.encode(&buffer, &proof));

	// And the server's half, which this driver checks so that a broker cannot
	// merely claim the password was right.
	var server_key: [Hmac.mac_length]u8 = undefined;
	Hmac.create(&server_key, "Server Key", &salted);
	var server_signature: [Hmac.mac_length]u8 = undefined;
	Hmac.create(&server_signature, auth_message, &server_key);
	try testing.expectEqualStrings("rmF9pqV8S7suAoZWja4dJRkFsKQ=", base64.Encoder.encode(&buffer, &server_signature));
}

test "randomness is available, and different every time" {
	var first: [24]u8 = undefined;
	var second: [24]u8 = undefined;
	try randomBytes(&first);
	try randomBytes(&second);
	try testing.expect(!std.mem.eql(u8, &first, &second));
	// And not simply left as it was.
	try testing.expect(!std.mem.allEqual(u8, &first, 0));
}

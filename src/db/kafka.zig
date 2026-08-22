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
//!
//! **What is in this file is the connection.** The parts that are not - what a
//! request is made of, how a batch is unpacked, what a target says, how a SCRAM
//! message is written - are files of their own under `kafka/`, because they take
//! bytes and give bytes back and can be read, tested and fuzzed without a broker
//! anywhere near them:
//!
//! * `kafka/wire.zig` - the APIs and their versions, the encoder and the decoder,
//!   CRC-32C, murmur2, and what a broker's error codes mean.
//! * `kafka/compress.zig` - gzip, snappy, lz4 and zstd, two of them written out.
//! * `kafka/target.zig` - what `kafka+ssl://user@host:9093?mechanism=…` means.
//! * `kafka/scram.zig` - the text half of SCRAM, against the RFC's own example.

const std = @import("std");
const db = @import("db.zig");
const clock = @import("clock.zig");
const net = @import("net.zig");

/// The formats a batch can be packed with, and what a request is made of: two
/// files that know nothing of a connection.
pub const compress = @import("kafka/compress.zig");
pub const wire = @import("kafka/wire.zig");
pub const address = @import("kafka/target.zig");
pub const scram = @import("kafka/scram.zig");

const List = db.List;

pub const Codec = compress.Codec;
pub const decompress = compress.decompress;
pub const MAX_UNPACKED = compress.MAX_UNPACKED;
const codecName = compress.codecName;

const Api = wire.Api;
const versionOf = wire.versionOf;
const Encoder = wire.Encoder;
const Decoder = wire.Decoder;
const DecodeError = wire.DecodeError;
const crc32c = wire.crc32c;
const murmur2 = wire.murmur2;
const movedOn = wire.movedOn;
const errorText = wire.errorText;

pub const Mechanism = address.Mechanism;
pub const Parts = address.Parts;
pub const parse = address.parse;
pub const owns = address.owns;

// The files this driver is made of, named so that `zig build test` collects the
// tests in them: analysis is lazy, and a file whose declarations are all reached
// through an alias contributes none. Learned the same way twice.
comptime {
	_ = compress;
	_ = wire;
	_ = address;
	_ = scram;
}

const fieldOf = scram.fieldOf;
const escapeName = scram.escapeName;
const random = @import("random.zig");

/// The pseudo-columns of every topic.
pub const PARTITION = "partition";
pub const OFFSET = "offset";
pub const TIMESTAMP = "timestamp";
pub const KEY = "key";
pub const VALUE = "value";
pub const HEADERS = "headers";

const COLUMNS = [_][]const u8{ PARTITION, OFFSET, TIMESTAMP, KEY, VALUE, HEADERS };

/// How long a description of the cluster is worth keeping. Long enough that one
/// screen is drawn from one set of answers, short enough that a topic somebody else
/// created shows up without being asked for.
const META_MS: i64 = 2000;

/// The end of the year 9999, in milliseconds. Past this a Kafka timestamp is not
/// a time at all, whatever it says.
const LAST_DATE_MS: i64 = 253402300799999;

/// The largest offset this driver will believe. Kafka's own are bounded by how
/// much has ever been written to a partition; this is far above any of that and far
/// below where adding a delta to it could overflow.
const OFFSET_CEILING: i64 = 1 << 56;

/// How long a Fetch may wait for records before answering, in milliseconds. Short
/// on purpose: an empty topic should not hold the interface, and a long wait is
/// what makes ctrl+c feel broken.
const WAIT_MS: i32 = 400;
/// How much one Fetch may bring back, per partition and in total.
const PARTITION_BYTES: i32 = 1 << 20;
const FETCH_BYTES: i32 = 8 << 20;

// -------------------------------------------------------------- the transport
//
// A socket that may be wrapped in TLS is not a Kafka idea, so it lives in
// `net.zig` and the HTTP client uses the same one. What is Kafka's - the framing,
// the timeouts being what makes ctrl+c work mid-Fetch - is still here.

pub const Stream = net.Stream;
pub const ssl = net.ssl;
const startTls = net.startTls;
const connect = net.connect;
const READ_TIMEOUT_MS = net.READ_TIMEOUT_MS;

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
	/// Whether the offsets below have been asked for since this description of the
	/// cluster was made.
	offsets_read: bool = false,
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
	/// Everything the brokers said about this statement, until the next one.
	replies: std.heap.ArenaAllocator,
	/// And what they said about the cluster, which outlives a statement: the
	/// topics and their partitions are asked about by everything the interface
	/// draws, and asking the broker again for each of them is a round trip per
	/// question rather than per change.
	meta: std.heap.ArenaAllocator,
	/// When that was, on the wall clock, and when the offsets in it were read.
	/// Zero means "ask".
	meta_at: i64 = 0,
	offsets_at: i64 = 0,
	/// The cluster as it was last described, in `meta`.
	topics: []Topic = &.{},
	host: List = .empty,
	port: u16 = 9092,
	label: List = .empty,
	version_text: List = .empty,
	last_error: List = .empty,
	cluster_id: List = .empty,
	correlation: i32 = 0,
	/// How many requests have gone to the cluster on this connection. Reported by
	/// the info view and by tests/dbcheck.zig, because "it asks too often" is a
	/// claim and this is a number.
	requests: usize = 0,
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
			.meta = std.heap.ArenaAllocator.init(allocator),
		};
		errdefer {
			stream.close();
			self.replies.deinit();
			allocator.destroy(self);
		}
		try self.host.appendSlice(allocator, parts.host);
		self.stream.setTimeout(READ_TIMEOUT_MS);
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
			startTls(allocator, &self.stream, parts.host, .{ .verify = parts.verify }, report) catch {
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
		self.meta.deinit();
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
		// Every socket, including the ones already open: a read that is waiting has
		// to be able to ask whether the user is still interested.
		self.arm(&self.stream);
		var walk = self.leaders.valueIterator();
		while (walk.next()) |stream| {
			self.arm(stream);
		}
	}

	/// Give a stream its timeout and a way to ask whether to keep waiting.
	fn arm(self: *Db, stream: *Stream) void {
		stream.setTimeout(READ_TIMEOUT_MS);
		if (self.progress) |progress| {
			stream.keep_waiting = progress.keep_going;
			stream.context = progress.context;
		} else {
			stream.keep_waiting = null;
			stream.context = null;
		}
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
			// The log is append-only, and both of these say so before a form is
			// filled in rather than after.
			.no_update = "a kafka record cannot be changed - the log is append-only. Write a new one with i, or PRODUCE in the editor",
			.no_delete = "kafka deletes a prefix of a partition, not one record - X empties the topic, or DELETE RECORDS in the editor",
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
	}

	/// Throw the description of the cluster away, so the next question asks the
	/// broker. Everything that changes what is there calls this: a topic created or
	/// dropped, records produced or deleted, a leader that moved.
	fn forget(self: *Db) void {
		self.meta_at = 0;
		self.offsets_at = 0;
	}

	fn keepGoing(self: *Db) bool {
		if (self.progress) |progress| {
			return progress.call();
		}
		return true;
	}

	// --- one request, one reply ---

	/// A request that failed because the connection did, rather than because the
	/// broker refused it: the difference decides whether trying again is worth
	/// anything. A broker that restarts, or that reaps an idle connection, lands
	/// here - and used to need krtek restarting with it.
	pub const CallError = db.Error || error{Gone};

	/// Send a request to a broker and hand back its response body. The body lives
	/// in `replies`.
	fn call(self: *Db, stream: *Stream, api: Api, body: []const u8) CallError![]const u8 {
		const arena = self.replies.allocator();
		self.correlation += 1;
		self.requests += 1;

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
			return error.Gone;
		};

		var size_bytes: [4]u8 = undefined;
		stream.readExactly(&size_bytes) catch |err| {
			if (err == error.GivenUp) {
				self.remember("given up on");
				return error.Driver;
			}
			self.remember("kafka closed the connection");
			return error.Gone;
		};
		const size = std.mem.readInt(i32, &size_bytes, .big);
		if (size < 4 or size > 256 * 1024 * 1024) {
			self.remember("kafka sent a reply of an impossible size");
			return error.Driver;
		}
		const reply = try arena.alloc(u8, @intCast(size));
		stream.readExactly(reply) catch |err| {
			if (err == error.GivenUp) {
				self.remember("given up on");
				return error.Driver;
			}
			self.remember("kafka stopped halfway through a reply");
			return error.Gone;
		};
		// The response header of a non-flexible API is the correlation id alone.
		return reply[4..];
	}

	/// The same, to the broker the target named. Metadata goes through this one, so
	/// a broker that restarts takes it with it - and then it is opened again, TLS
	/// and authentication and all, and the request asked once more. Without that,
	/// every later request failed and went on failing until krtek was restarted.
	fn ask(self: *Db, api: Api, body: []const u8) db.Error![]const u8 {
		if (self.call(&self.stream, api, body)) |reply| {
			return reply;
		} else |err| {
			if (err == error.OutOfMemory) {
				return error.OutOfMemory;
			}
			if (err != error.Gone) {
				return error.Driver;
			}
		}
		self.reconnect() catch return error.Driver;
		return self.call(&self.stream, api, body) catch |err| switch (err) {
			error.OutOfMemory => error.OutOfMemory,
			else => error.Driver,
		};
	}

	/// Open the connection the target named again, and put it back the way it was.
	fn reconnect(self: *Db) db.Error!void {
		self.stream.close();
		var stream = connect(self.allocator, self.host.items, self.port) catch {
			self.complain("kafka at {s}:{d} is not answering any more", .{ self.host.items, self.port });
			return error.Driver;
		};
		errdefer stream.close();
		if (self.tls) {
			var why: List = .empty;
			defer why.deinit(self.allocator);
			startTls(self.allocator, &stream, self.host.items, .{ .verify = self.verify }, &why) catch {
				self.complain("TLS to {s}:{d} failed on reconnecting: {s}", .{
					self.host.items, self.port,
					if (why.items.len != 0) why.items else "no reason given",
				});
				return error.Driver;
			};
		}
		self.stream = stream;
		self.arm(&self.stream);
		self.forget();
		try self.authenticate(&self.stream);
		self.last_error.clearRetainingCapacity();
	}

	/// The cluster has moved: every cached connection is dropped and metadata asked
	/// for again, so the next attempt goes to whoever leads the partition now.
	///
	/// **Anything held from the old description dies here.** The topics, their
	/// partitions and their names live in the arena this refills, so a caller that
	/// means to look something up afterwards has to hold its name in memory of its
	/// own first - `held` is for that. Getting this wrong loses a record and reports
	/// a topic that is being created as gone, which is exactly what it did.
	fn clusterMoved(self: *Db) db.Error!void {
		var walk = self.leaders.valueIterator();
		while (walk.next()) |stream| {
			stream.close();
		}
		self.leaders.clearRetainingCapacity();
		self.forget();
		// The complaint that got us here is replaced by whatever happens next; if the
		// retry works, the user should see no complaint at all.
		const was = try self.allocator.dupe(u8, self.last_error.items);
		defer self.allocator.free(was);
		self.describeCluster() catch {
			self.remember(was);
			return error.Driver;
		};
		self.last_error.clearRetainingCapacity();
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
				startTls(self.allocator, &stream, broker.host, .{ .verify = self.verify }, &why) catch {
					self.complain("TLS to the broker at {s}:{d} failed: {s}", .{
						broker.host, broker.port,
						if (why.items.len != 0) why.items else "no reason given",
					});
					return error.Driver;
				};
			}
			self.arm(&stream);
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
		const reply = self.call(stream, .sasl_handshake, body.items) catch return error.Driver;
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
		const reply = self.call(stream, .sasl_authenticate, body.items) catch return error.Driver;
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
		random.bytes(&raw_nonce) catch {
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
		// Its own arena, reset here: this outlives the statement that asked for it.
		_ = self.meta.reset(.retain_capacity);
		self.topics = &.{};
		const arena = self.meta.allocator();
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
	/// The first and last offset of every partition of one topic. Two requests per
	/// partition, so the answer is kept for as long as the metadata is: the object
	/// list asks for every topic and then the grid asks again for the one being
	/// opened.
	fn readOffsets(self: *Db, topic: *Topic) db.Error!void {
		const one = [_]*Topic{topic};
		return self.readOffsetsOf(&one);
	}

	/// The first and last offset of every partition of these topics.
	///
	/// One request per broker and per end, and not one per partition: ListOffsets
	/// takes a list, and asking it one partition at a time is how drawing the object
	/// list on this laptop cost 124 requests - a hundred of them for
	/// __consumer_offsets, which has fifty partitions nobody was looking at. Two per
	/// broker now, whatever the cluster's size.
	fn readOffsetsOf(self: *Db, topics: []const *Topic) db.Error!void {
		const now = wallMs();
		var wanted: std.ArrayListUnmanaged(*Topic) = .empty;
		defer wanted.deinit(self.allocator);
		for (topics) |topic| {
			const fresh = self.offsets_at != 0 and now - self.offsets_at < META_MS and topic.offsets_read;
			if (!fresh and topic.partitions.len != 0) {
				try wanted.append(self.allocator, topic);
			}
		}
		if (wanted.items.len == 0) {
			return;
		}

		// Which brokers lead any of it.
		var brokers: std.ArrayListUnmanaged(i32) = .empty;
		defer brokers.deinit(self.allocator);
		for (wanted.items) |topic| {
			for (topic.partitions) |partition| {
				if (std.mem.indexOfScalar(i32, brokers.items, partition.leader) == null) {
					try brokers.append(self.allocator, partition.leader);
				}
			}
		}

		for (brokers.items) |node| {
			// -2 is the earliest offset still there, -1 the next one to be written.
			try self.askOffsets(node, wanted.items, -2);
			try self.askOffsets(node, wanted.items, -1);
		}
		for (wanted.items) |topic| {
			topic.offsets_read = true;
		}
		if (self.offsets_at == 0) {
			self.offsets_at = now;
		}
	}

	/// One ListOffsets to one broker, for every partition it leads out of these
	/// topics, at one end of the log.
	fn askOffsets(self: *Db, node: i32, topics: []const *Topic, at_time: i64) db.Error!void {
		var body: List = .empty;
		defer body.deinit(self.allocator);
		const write = Encoder{ .out = &body, .a = self.allocator };
		try write.int32(-1); // replica id: a client, not a broker
		try write.int8(1); // isolation level: read committed

		// Only the topics that have a partition this broker leads.
		var mine: std.ArrayListUnmanaged(*Topic) = .empty;
		defer mine.deinit(self.allocator);
		for (topics) |topic| {
			for (topic.partitions) |partition| {
				if (partition.leader == node) {
					try mine.append(self.allocator, topic);
					break;
				}
			}
		}
		if (mine.items.len == 0) {
			return;
		}
		try write.array(mine.items.len);
		for (mine.items) |topic| {
			try write.string(topic.name);
			var count: usize = 0;
			for (topic.partitions) |partition| {
				if (partition.leader == node) {
					count += 1;
				}
			}
			try write.array(count);
			for (topic.partitions) |partition| {
				if (partition.leader != node) {
					continue;
				}
				try write.int32(partition.id);
				try write.int32(-1); // current leader epoch
				try write.int64(at_time);
			}
		}

		const stream = try self.leader(node);
		const reply = self.call(stream, .list_offsets, body.items) catch |err| {
			if (err == error.OutOfMemory) {
				return error.OutOfMemory;
			}
			if (err == error.Gone) {
				try self.clusterMoved();
				self.remember("the broker holding those offsets went away; try again");
			}
			return error.Driver;
		};
		var read = Decoder{ .bytes = reply };
		self.readOffsetReply(&read, at_time) catch |err| {
			if (err == error.MovedOn) {
				clock.sleep(SETTLE_MS);
				try self.clusterMoved();
				return error.Driver;
			}
			if (self.last_error.items.len == 0) {
				self.remember("kafka answered the offset request with something unexpected");
			}
			return error.Driver;
		};
	}

	/// Put a ListOffsets reply where it belongs: each answer names its topic and
	/// partition, so it is looked up rather than assumed.
	fn readOffsetReply(self: *Db, read: *Decoder, at_time: i64) !void {
		_ = try read.int32(); // throttle
		var topics = try read.arrayLength();
		while (topics > 0) : (topics -= 1) {
			const name = try read.string();
			var parts = try read.arrayLength();
			while (parts > 0) : (parts -= 1) {
				const id = try read.int32();
				const code = try read.int16();
				_ = try read.int64(); // timestamp
				const offset = try read.int64();
				_ = try read.int32(); // leader epoch
				if (code != 0) {
					self.complain("kafka refused the offset request: {s}", .{errorText(code)});
					return if (movedOn(code)) error.MovedOn else error.Malformed;
				}
				const partition = self.partitionOf(name, id) orelse continue;
				if (at_time == -2) {
					partition.earliest = offset;
				} else {
					partition.latest = offset;
				}
			}
		}
	}

	fn oneOffset(self: *Db, topic: []const u8, partition: *Partition, at_time: i64) db.Error!i64 {
		return self.oneOffsetTrying(topic, partition, at_time, 0);
	}

	fn oneOffsetTrying(self: *Db, topic: []const u8, partition: *Partition, at_time: i64, attempt: usize) db.Error!i64 {
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
		const reply = self.call(stream, .list_offsets, body.items) catch |err| {
			return self.afterLoss(err, attempt, topic, partition.id, at_time);
		};
		var read = Decoder{ .bytes = reply };
		return self.readOneOffset(&read) catch |err| {
			if (err == error.MovedOn and attempt + 1 < ATTEMPTS) {
				clock.sleep(SETTLE_MS);
				const name = try self.held(topic);
				try self.clusterMoved();
				// The partition is a pointer into the metadata that was just replaced,
				// so it is looked up again rather than reused - and so is its name.
				if (self.partitionOf(name, partition.id)) |fresh| {
					return self.oneOffsetTrying(name, fresh, at_time, attempt + 1);
				}
				self.complain("partition {d} of {s} is gone", .{ partition.id, topic });
				return error.Driver;
			}
			if (self.last_error.items.len == 0) {
				self.remember("kafka answered the offset request with something unexpected");
			}
			return error.Driver;
		};
	}

	/// A lost connection while asking for offsets: find who leads it now and ask
	/// once more, or give up with the reason.
	fn afterLoss(self: *Db, err: CallError, attempt: usize, topic: []const u8, id: i32, at_time: i64) db.Error!i64 {
		if (err == error.OutOfMemory) {
			return error.OutOfMemory;
		}
		if (err == error.Gone and attempt + 1 < ATTEMPTS) {
			const name = try self.held(topic);
			try self.clusterMoved();
			if (self.partitionOf(name, id)) |fresh| {
				return self.oneOffsetTrying(name, fresh, at_time, attempt + 1);
			}
			self.complain("partition {d} of {s} is gone", .{ id, topic });
		}
		return error.Driver;
	}

	/// Wait for a topic to be ready to take a record, and hand it back when it is.
	///
	/// A create is not finished when the broker answers it: the topic appears in the
	/// metadata before its partitions have leaders, and until then this driver sees a
	/// topic with no partitions at all - or, for a moment, no topic. Both are worth
	/// waiting through, and both used to be reported as failures: "is gone", of a
	/// topic that was in the middle of being made.
	fn settled(self: *Db, name_in: []const u8, attempt: usize) db.Error!?*Topic {
		// Its own copy, because it refreshes the metadata more than once: see the note
		// on clusterMoved for what that does to anything held from the old one.
		const name = try self.held(name_in);
		var left = ATTEMPTS - attempt;
		while (left > 0) : (left -= 1) {
			clock.sleep(SETTLE_MS);
			self.forget();
			self.refresh() catch continue;
			if (self.topicOf(name)) |topic| {
				if (topic.partitions.len != 0) {
					return topic;
				}
			}
		}
		self.complain("kafka has not finished making {s}", .{name});
		return null;
	}

	/// A copy of a name that outlives the next refresh of the metadata, in memory
	/// that only the next statement clears.
	fn held(self: *Db, name: []const u8) db.Error![]const u8 {
		return self.replies.allocator().dupe(u8, name);
	}

	/// The partition of that id as the metadata now describes it.
	fn partitionOf(self: *Db, topic: []const u8, id: i32) ?*Partition {
		const found = self.topicOf(topic) orelse return null;
		for (found.partitions) |*partition| {
			if (partition.id == id) {
				return partition;
			}
		}
		return null;
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
					return if (movedOn(code)) error.MovedOn else error.Malformed;
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
		// One recovery per fetch: a cluster that keeps moving is a cluster to
		// complain about, not to spin against.
		var moved = false;
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
			const reply = self.call(stream, .fetch, body.items) catch |err| {
				if (err == error.Gone and !moved) {
					moved = true;
					const name = try self.held(topic.name);
					try self.clusterMoved();
					const fresh = self.partitionOf(name, partition.id) orelse return error.Driver;
					partition.leader = fresh.leader;
					partition.latest = fresh.latest;
					continue;
				}
				return if (err == error.OutOfMemory) error.OutOfMemory else error.Driver;
			};
			var read = Decoder{ .bytes = reply };
			const before = rows.rows.items.len;
			const stopped = self.readFetch(&read, rows, topic.name, partition.id, wanted, filter, at) catch |err| {
				if (err == error.OutOfMemory) {
					return error.OutOfMemory;
				}
				// A leader election in the middle of a read: ask who leads it now and
				// carry on from the offset already reached, so the rows already
				// gathered are kept and none is read twice.
				if (err == error.MovedOn and !moved) {
					moved = true;
					const name = try self.held(topic.name);
					try self.clusterMoved();
					const fresh = self.partitionOf(name, partition.id) orelse {
						self.complain("partition {d} of {s} is gone", .{ partition.id, name });
						return error.Driver;
					};
					partition.leader = fresh.leader;
					partition.latest = fresh.latest;
					continue;
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
					return if (movedOn(part_code)) error.MovedOn else error.Malformed;
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
		// An offset is a count from the beginning of a partition: never negative, and
		// nowhere near where adding to it could overflow. Kafka would never send
		// anything else; a corrupted batch would, and then every offset computed from
		// it is arithmetic on a wire value.
		if (base_offset < 0 or base_offset > OFFSET_CEILING or last_delta < 0) {
			self.remember("this batch claims an offset that cannot be one");
			return error.Malformed;
		}
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
				self.complain("these records are compressed with {s}, which krtek cannot unpack", .{codecName(codec)});
				return error.Malformed;
			},
			else => {
				self.complain("these records are compressed with {s} and did not unpack", .{codecName(codec)});
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

			if (offset_delta < 0) {
				break; // a record before the batch it is in
			}
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
				// Saturating: a timestamp is shown, not counted with, and two wire
				// values added together are not to be trusted with a plain +.
				.{ .text = try stamp(arena, base_time +| time_delta) },
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

	/// What is in the cluster, from the broker or from the last few moments of
	/// memory. Drawing one screen asks this a dozen times - the object list, the row
	/// count, the structure, the grid - and the answer does not change between them.
	fn refresh(self: *Db) db.Error!void {
		const now = wallMs();
		if (self.meta_at != 0 and now - self.meta_at < META_MS and self.topics.len != 0) {
			return;
		}
		self.describeCluster() catch {
			if (self.last_error.items.len == 0) {
				self.remember("kafka stopped answering for its metadata");
			}
			return error.Driver;
		};
		self.meta_at = now;
		// The partitions are new objects, so whatever was known about their offsets
		// is not about these.
		self.offsets_at = 0;
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
		return self.produceTrying(topic, wanted, key, value, 0);
	}

	fn produceTrying(self: *Db, topic: *Topic, wanted: i32, key: ?[]const u8, value: []const u8, attempt: usize) db.Error!void {
		if (topic.partitions.len == 0) {
			// A topic exists before any of its partitions has a leader, and this driver
			// keeps only the ones that do - so a topic that was just made looks like a
			// topic with nowhere to write.
			if (attempt + 1 < ATTEMPTS) {
				if (try self.settled(topic.name, attempt)) |fresh| {
					return self.produceTrying(fresh, wanted, key, value, attempt + 1);
				}
			}
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

		// The offsets are about to be wrong, whether or not this succeeds.
		self.forget();
		const stream = try self.leader(target.leader);
		const reply = self.call(stream, .produce, body.items) catch |err| {
			// A connection that died before the request went out means the record was
			// not written, so sending it again writes it once.
			if (err == error.Gone and attempt + 1 < ATTEMPTS) {
				const name = try self.held(topic.name);
				try self.clusterMoved();
				if (try self.settled(name, attempt)) |fresh| {
					return self.produceTrying(fresh, wanted, key, value, attempt + 1);
				}
				return error.Driver;
			}
			return if (err == error.OutOfMemory) error.OutOfMemory else error.Driver;
		};
		var read = Decoder{ .bytes = reply };
		self.readProduce(&read) catch |err| {
			if (err == error.MovedOn and attempt + 1 < ATTEMPTS) {
				// A topic that has just been created has no leader for a moment, and the
				// first record sent to it is the one that finds out. Waiting is what a
				// client is supposed to do; asking again at once gets the same answer,
				// and that is how replaying a dump lost its first record every time.
				if (try self.settled(topic.name, attempt)) |fresh| {
					// The record has not been written, so sending it again writes it once.
					return self.produceTrying(fresh, wanted, key, value, attempt + 1);
				}
				return error.Driver;
			}
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
					return if (movedOn(code)) error.MovedOn else error.Malformed;
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
		// Every topic in one go: two requests per broker rather than two per
		// partition.
		var all: std.ArrayListUnmanaged(*Topic) = .empty;
		defer all.deinit(self.allocator);
		for (self.topics) |*topic| {
			try all.append(self.allocator, topic);
		}
		try self.readOffsetsOf(all.items);
		for (self.topics) |*topic| {
			var total: i64 = 0;
			for (topic.partitions) |partition| {
				total += partition.count();
			}
			try list.append(arena, .{
				.name = try arena.dupe(u8, topic.name),
				.kind = .table,
				.rows = total,
				.internal = topic.internal,
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

	/// What makes this topic again, and then what DescribeConfigs says about it. The
	/// first line is a command - the same one the console takes, with the partition
	/// count and replication this topic actually has - so a dump of it can be
	/// replayed; the settings after it are comments, because they are a description
	/// and not something to run.
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

		var out: List = .empty;
		// The shape first, from the metadata, because that is the part that can be
		// put back.
		self.refresh() catch {};
		if (self.topicOf(table.name)) |topic| {
			var replication: usize = 1;
			for (topic.partitions) |partition| {
				replication = @max(replication, partition.replicas);
			}
			try out.print(arena, "CREATE {s} {d} {d}\n", .{
				table.name,
				@max(1, topic.partitions.len),
				replication,
			});
		}
		const reply = self.ask(.describe_configs, body.items) catch return out.items;
		var read = Decoder{ .bytes = reply };
		self.readConfigs(&read, &out, arena, table.name) catch return out.items;
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
				// All of them are comments: a setting is a description, and a line that
				// is neither a command nor a comment makes a dump unreplayable. Source 5
				// is the broker's default, and those are marked as such so the handful
				// that were set on this topic stand out.
				const inherited = source == 5 or source == 4;
				try out.print(arena, "-- {s}{s} = {s}\n", .{ if (inherited) "default: " else "", key, value });
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
		try list.append(arena, .{ .label = "requests", .value = try std.fmt.allocPrint(arena, "{d}", .{self.requests}) });
		try list.append(arena, .{ .label = "partitions", .value = try std.fmt.allocPrint(arena, "{d}", .{partitions}) });
		return list.items;
	}

	/// One command per line, as the console takes them.
	///
	/// Lines only, and not semicolons: what a PRODUCE sends is the rest of the line
	/// and may well contain one - `PRODUCE orders k a;b` is one record, not two
	/// commands. A comment is not a command either, which is what makes a dump this
	/// driver wrote replayable.
	pub fn split(_: *Db, arena: std.mem.Allocator, sql: []const u8) db.Error![]db.Statement {
		var list: std.ArrayListUnmanaged(db.Statement) = .empty;
		var lines = std.mem.splitScalar(u8, sql, '\n');
		while (lines.next()) |raw| {
			const line = std.mem.trim(u8, raw, " \t\r;");
			if (line.len != 0 and !std.mem.startsWith(u8, line, "--") and !std.mem.startsWith(u8, line, "#")) {
				try list.append(arena, .{ .sql = try arena.dupe(u8, line) });
			}
		}
		return list.items;
	}

	/// The console verbs that only look. `PRODUCE`, `CREATE`, `DROP` and
	/// `TRUNCATE` change the cluster and are left out, so a grid of theirs is not
	/// repeated on a clock.
	pub fn repeatable(_: *Db, statement: []const u8) bool {
		var words = std.mem.tokenizeAny(u8, statement, " \t\r\n;");
		const verb = words.next() orelse return false;
		for ([_][]const u8{ "TOPICS", "BROKERS", "GROUPS", "OFFSETS", "DESCRIBE" }) |reading| {
			if (std.ascii.eqlIgnoreCase(verb, reading)) {
				return true;
			}
		}
		return false;
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

		self.forget();
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

		self.forget();
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

		self.forget();
		const stream = try self.leader(node);
		const reply = self.call(stream, .delete_records, body.items) catch {
			return error.Driver;
		};
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

/// How long to wait before asking a cluster that was moving, and how many times.
const SETTLE_MS: i64 = 300;
const ATTEMPTS: usize = 3;

/// Milliseconds since the epoch, which is how a record carries the time.
pub fn wallMs() i64 {
	return clock.wallMs();
}

/// A Kafka timestamp - milliseconds since the epoch - as something readable. UTC,
/// because a broker's records are not in anybody's local time.
pub fn stamp(arena: std.mem.Allocator, millis: i64) ![]const u8 {
	if (millis <= 0) {
		return arena.dupe(u8, "");
	}
	// Beyond what a date can be, the number is shown as it stands: the calendar
	// arithmetic below counts years one at a time from 1970 and overflows long
	// before it arrives. A record whose timestamp says the year 291 million is
	// corrupt, and saying so beats both a wrong date and a crash.
	if (millis > LAST_DATE_MS) {
		return std.fmt.allocPrint(arena, "{d} (not a date)", .{millis});
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




/// A cell of a change that was given a value: a change may set a column to NULL,
/// and for a record that is not a value.
fn flat(value: ??[]const u8) ?[]const u8 {
	const inner = value orelse return null;
	return inner orelse null;
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








// -------------------------------------------------------------------- fuzzing
//
// These four take bytes straight off a socket, and three of them - the snappy and
// lz4 unpackers and the record walker - were written here by hand. A malformed
// input has to come back as an error, never as a panic: an overflow, a slice out
// of bounds or an allocation of whatever a length field happened to say.
//
//     zig build test --fuzz          # until it finds something
//
// Without --fuzz these run over the corpus below, so the inputs that once broke
// something stay checked on every ordinary test run.

/// Anything the unpackers are handed must come back as bytes or as an error.
fn fuzzOneCodec(codec: Codec, input: []const u8) anyerror!void {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();
	const out = decompress(arena.allocator(), codec, input) catch return;
	// A successful unpacking has to be readable memory of the length it claims.
	var sum: usize = 0;
	for (out) |byte| {
		sum += byte;
	}
	std.mem.doNotOptimizeAway(sum);
}

test "fuzz: snappy" {
	try std.testing.fuzz({}, struct {
		fn one(_: void, smith: *std.testing.Smith) anyerror!void {
			var buffer: [4096]u8 = undefined;
			const length = smith.slice(&buffer);
			try fuzzOneCodec(.snappy, buffer[0..length]);
		}
	}.one, .{ .corpus = &.{
		// A literal, and a copy that overlaps itself.
		&.{ 0x03, 0x08, 'a', 'b', 'c' },
		&.{ 0x09, 0x08, 'a', 'b', 'c', 0x09, 0x03 },
		// A copy that reaches further back than anything written: must not read
		// before the buffer.
		&.{ 0x09, 0x08, 'a', 'b', 'c', 0x09, 0xff },
		// A length that promises far more than the input holds.
		&.{ 0xff, 0xff, 0xff, 0x7f, 0x08, 'a' },
		// The xerial framing kafka's java producer writes, with a block length
		// running off the end.
		&.{ 0x82, 'S', 'N', 'A', 'P', 'P', 'Y', 0, 0, 0, 0, 1, 0, 0, 0, 1, 0xff, 0xff, 0xff, 0xff },
		"",
	} });
}

test "fuzz: lz4" {
	try std.testing.fuzz({}, struct {
		fn one(_: void, smith: *std.testing.Smith) anyerror!void {
			var buffer: [4096]u8 = undefined;
			const length = smith.slice(&buffer);
			try fuzzOneCodec(.lz4, buffer[0..length]);
		}
	}.one, .{ .corpus = &.{
		// A stored block, and a compressed one.
		&.{ 0x04, 0x22, 0x4d, 0x18, 0x40, 0x70, 0x00, 0x03, 0x00, 0x00, 0x80, 'a', 'b', 'c', 0, 0, 0, 0 },
		&.{ 0x04, 0x22, 0x4d, 0x18, 0x40, 0x70, 0x00, 0x06, 0x00, 0x00, 0x00, 0x32, 'a', 'b', 'c', 0x03, 0x00, 0, 0, 0, 0 },
		// A match offset with nothing behind it, and a token promising more
		// literals than the block has.
		&.{ 0x04, 0x22, 0x4d, 0x18, 0x40, 0x70, 0x00, 0x06, 0x00, 0x00, 0x00, 0x32, 'a', 'b', 'c', 0xff, 0xff, 0, 0, 0, 0 },
		&.{ 0x04, 0x22, 0x4d, 0x18, 0x40, 0x70, 0x00, 0x02, 0x00, 0x00, 0x00, 0xf0, 0xff, 0, 0, 0, 0 },
		// A frame that says it carries a dictionary, and a block length of 2 GB.
		&.{ 0x04, 0x22, 0x4d, 0x18, 0x41, 0x70, 0x00, 0, 0, 0, 0 },
		&.{ 0x04, 0x22, 0x4d, 0x18, 0x40, 0x70, 0x00, 0xff, 0xff, 0xff, 0x7f, 'a' },
		&.{ 0x04, 0x22, 0x4d, 0x18 },
		"",
	} });
}

test "fuzz: gzip and zstd, which are the standard library's" {
	try std.testing.fuzz({}, struct {
		fn one(_: void, smith: *std.testing.Smith) anyerror!void {
			var buffer: [4096]u8 = undefined;
			const length = smith.slice(&buffer);
			try fuzzOneCodec(.gzip, buffer[0..length]);
			try fuzzOneCodec(.zstd, buffer[0..length]);
		}
	}.one, .{ .corpus = &.{
		&.{ 0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x03, 0x4b, 0x4c, 0x4a, 0x06, 0x00, 0xc2, 0x41, 0x24, 0x35, 0x03, 0x00, 0x00, 0x00 },
		&.{ 0x1f, 0x8b, 0x08, 0x00 },
		&.{ 0x28, 0xb5, 0x2f, 0xfd },
		"",
	} });
}

/// The record walker with no socket behind it, for the fuzzer in tests/fuzz.zig.
pub fn fuzzBatches(allocator: std.mem.Allocator, input: []const u8) anyerror!void {
	var self = Db{
		.allocator = allocator,
		.stream = .{ .fd = -1 },
		.replies = std.heap.ArenaAllocator.init(allocator),
		.meta = std.heap.ArenaAllocator.init(allocator),
	};
	defer {
		self.replies.deinit();
		self.meta.deinit();
		self.host.deinit(self.allocator);
		self.label.deinit(self.allocator);
		self.version_text.deinit(self.allocator);
		self.last_error.deinit(self.allocator);
		self.cluster_id.deinit(self.allocator);
		self.brokers.deinit(self.allocator);
		self.leaders.deinit(self.allocator);
	}
	var rows = Rows{ .owner = &self, .names = &COLUMNS };
	_ = try self.readBatches(input, &rows, "topic", 0, 50, .{}, 0);
	while (try rows.next()) {
		for (0..rows.columnCount()) |i| {
			switch (rows.value(i)) {
				.text => |text| std.mem.doNotOptimizeAway(text.len),
				.int => |number| std.mem.doNotOptimizeAway(number),
				else => {},
			}
		}
	}
}

/// The record walker, which is the one that reads lengths out of the bytes and
/// then trusts them. Driven without a socket: a Db is needed for the arena and the
/// row list, and nothing here touches the connection.
fn fuzzOneBatch(input: []const u8) anyerror!void {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();
	var self = Db{
		.allocator = std.testing.allocator,
		.stream = .{ .fd = -1 },
		.replies = std.heap.ArenaAllocator.init(std.testing.allocator),
		.meta = std.heap.ArenaAllocator.init(std.testing.allocator),
	};
	defer {
		self.replies.deinit();
		self.meta.deinit();
		self.host.deinit(self.allocator);
		self.label.deinit(self.allocator);
		self.version_text.deinit(self.allocator);
		self.last_error.deinit(self.allocator);
		self.cluster_id.deinit(self.allocator);
		self.brokers.deinit(self.allocator);
		self.leaders.deinit(self.allocator);
	}
	var rows = Rows{ .owner = &self, .names = &COLUMNS };
	_ = self.readBatches(input, &rows, "topic", 0, 50, .{}, 0) catch return;
	// Whatever came out has to be a row of six readable values.
	while (rows.next() catch return) {
		for (0..rows.columnCount()) |i| {
			switch (rows.value(i)) {
				.text => |text| std.mem.doNotOptimizeAway(text.len),
				.int => |number| std.mem.doNotOptimizeAway(number),
				.null => {},
				else => {},
			}
		}
	}
}

test "fuzz: record batches" {
	try std.testing.fuzz({}, struct {
		fn one(_: void, smith: *std.testing.Smith) anyerror!void {
			var buffer: [8192]u8 = undefined;
			const length = smith.slice(&buffer);
			try fuzzOneBatch(buffer[0..length]);
		}
	}.one, .{ .corpus = &.{
		// One record, uncompressed: base offset, length, epoch, magic 2, crc,
		// attributes, deltas, producer fields, one record with a key and a value.
		&.{
			0,    0,    0,    0,    0,    0,    0,    0, // base offset
			0,    0,    0,    59, // length
			0,    0,    0,    0, // leader epoch
			2, // magic
			0,    0,    0,    0, // crc
			0,    0, // attributes
			0,    0,    0,    0, // last offset delta
			0,    0,    0,    0,    0,    0,    0,    0, // base timestamp
			0,    0,    0,    0,    0,    0,    0,    0, // max timestamp
            0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, // producer id
            0xff, 0xff, // producer epoch
            0xff, 0xff, 0xff, 0xff, // base sequence
            0,    0,    0,    1, // one record
            14,   0,    0,    0,    2,    'k',  'v',  4,
            'v',  'a',  'l',  'u',  0,
		},
		// A batch that says magic 1, which is the old format.
		&([_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 49, 0, 0, 0, 0, 1 } ++ [_]u8{0} ** 48),
		// A batch whose length runs past the buffer, and one that claims a record
		// count of two billion.
		&([_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0x7f, 0xff, 0xff, 0xff, 0, 0, 0, 0, 2 } ++ [_]u8{0} ** 44),
		&.{
			0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 49, 0, 0, 0, 0, 2,
			0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
			0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
			0x7f, 0xff, 0xff, 0xff,
		},
		// A batch that says it is compressed with snappy but holds nothing of the
		// kind, and a control batch, which carries no records anybody wrote.
		&([_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 49, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 2 } ++ [_]u8{0} ** 41),
		&([_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 49, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0x20 } ++ [_]u8{0} ** 41),
		"",
	} });
}

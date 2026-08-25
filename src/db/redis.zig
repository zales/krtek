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

const std = @import("std");
const db = @import("db.zig");
const typed = @import("typed.zig");

const List = std.ArrayListUnmanaged(u8);

/// How many keys one page of the grid fetches at most, so a database with
/// millions of them still answers.
const PAGE = 1000;

/// How long one read waits before asking whether to carry on, and how long it
/// waits in total before calling the server gone. The first is what makes ctrl+c
/// work while Redis is busy.
const READ_TIMEOUT_MS: i64 = 400;
const READ_PATIENCE_MS: i64 = 60 * 1000;

/// Wait this long for something to arrive, then come back either way.
fn setTimeout(socket: std.c.fd_t, ms: i64) void {
	const timeout = std.c.timeval{
		.sec = @intCast(@divFloor(ms, 1000)),
		.usec = @intCast(@mod(ms, 1000) * 1000),
	};
	_ = std.c.setsockopt(socket, std.c.SOL.SOCKET, std.c.SO.RCVTIMEO, &timeout, @sizeOf(std.c.timeval));
}

pub const Db = struct {
	allocator: std.mem.Allocator,
	socket: std.c.fd_t,
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

		const socket = db.net.dial(allocator, parts.host, parts.port) catch {
			try report.print(allocator, "cannot reach redis at {s}:{d}", .{ parts.host, parts.port });
			return error.Driver;
		};

		const self = try allocator.create(Db);
		self.* = .{
			.allocator = allocator,
			.socket = socket,
			.index = parts.index,
			.replies = std.heap.ArenaAllocator.init(allocator),
		};
		errdefer self.close();
		setTimeout(socket, READ_TIMEOUT_MS);

		if (parts.password.len != 0) {
			const reply = self.command(&[_][]const u8{ "AUTH", parts.password }) catch {
				try report.appendSlice(allocator, self.message());
				return error.Driver;
			};
			if (reply == .failure) {
				try report.appendSlice(allocator, reply.failure);
				return error.Driver;
			}
		}
		// PING first: a wrong password or a protected server says so here rather
		// than halfway through the first screen.
		const ping = self.command(&[_][]const u8{"PING"}) catch {
			try report.appendSlice(allocator, self.message());
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
		try self.host.appendSlice(allocator, parts.host);
		self.port = parts.port;
		self.relabel();
		try self.version_text.print(allocator, "Redis {s}", .{self.fact("redis_version") orelse "?"});
		return self;
	}

	/// `host:port/index`, as the header shows it.
	fn relabel(self: *Db) void {
		self.label.clearRetainingCapacity();
		self.label.print(self.allocator, "{s}:{d}/{d}", .{ self.host.items, self.port, self.index }) catch {};
	}

	pub fn close(self: *Db) void {
		_ = std.c.close(self.socket);
		self.host.deinit(self.allocator);
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
			.text_cast = "TEXT",
			// Redis is asked with a structure; only the console takes a command.
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

	fn remember(self: *Db, text: []const u8) void {
		self.last_error.clearRetainingCapacity();
		self.last_error.appendSlice(self.allocator, text) catch {};
	}

	// ------------------------------------------------------------------ RESP

	/// Send one command and read its reply. The reply is owned by `replies` and
	/// lives until the next statement clears it.
	fn command(self: *Db, args: []const []const u8) db.Error!Value {
		var out: List = .empty;
		defer out.deinit(self.allocator);
		try out.print(self.allocator, "*{d}\r\n", .{args.len});
		for (args) |arg| {
			try out.print(self.allocator, "${d}\r\n", .{arg.len});
			try out.appendSlice(self.allocator, arg);
			try out.appendSlice(self.allocator, "\r\n");
		}
		try self.writeAll(out.items);
		return self.read(self.replies.allocator());
	}

	fn writeAll(self: *Db, bytes: []const u8) db.Error!void {
		var sent: usize = 0;
		while (sent < bytes.len) {
			const wrote = std.c.send(self.socket, bytes[sent..].ptr, bytes.len - sent, 0);
			if (wrote <= 0) {
				self.remember("the connection to redis is gone");
				return error.Driver;
			}
			sent += @intCast(wrote);
		}
	}

	/// One reply, reading more from the socket whenever the buffer runs out.
	fn read(self: *Db, arena: std.mem.Allocator) db.Error!Value {
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
				else => return error.Driver,
			}
		}
	}

	/// More bytes from the socket. The socket has a short receive timeout, so a
	/// reply that is slow to arrive gets to ask whether the user is still waiting -
	/// without it, a server that stopped answering held the whole program and
	/// ctrl+c could do nothing about it.
	fn fill(self: *Db) db.Error!void {
		var chunk: [16 * 1024]u8 = undefined;
		var waiting: i64 = 0;
		while (true) {
			const got = std.c.recv(self.socket, &chunk, chunk.len, 0);
			if (got > 0) {
				try self.buffer.appendSlice(self.allocator, chunk[0..@intCast(got)]);
				return;
			}
			if (got == 0) {
				self.remember("redis closed the connection");
				return error.Driver;
			}
			const code = std.c._errno().*;
			const timed_out = code == @intFromEnum(std.c.E.AGAIN) or code == @intFromEnum(std.c.E.INTR);
			if (!timed_out) {
				self.remember("redis closed the connection");
				return error.Driver;
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
				var items: std.ArrayListUnmanaged(Value) = .empty;
				var left: usize = @intCast(@max(0, length));
				while (left > 0) : (left -= 1) {
					try items.append(arena, try self.parseValue(arena));
				}
				return .{ .list = items.items };
			},
			'%' => {
				// A map: read twice as many values and keep them flat.
				const pairs = std.fmt.parseInt(i64, body, 10) catch return error.Malformed;
				var items: std.ArrayListUnmanaged(Value) = .empty;
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
		const end = std.mem.indexOfPos(u8, self.buffer.items, self.at, "\r\n") orelse return error.Incomplete;
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
		const reply = try self.command(&[_][]const u8{ "RENAME", from, to });
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
		const reply = try self.command(args);
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
				"SCAN",                                     cursor,
				"MATCH",                                    if (pattern.len != 0) pattern else "*",
				"COUNT",                                    std.fmt.bufPrint(&buf, "{d}", .{PAGE}) catch "100",
			});
			if (reply == .failure) {
				self.remember(reply.failure);
				return error.Driver;
			}
			const pair = reply.list orelse break;
			if (pair.len < 2) {
				break;
			}
			cursor = pair[0].text orelse "0";
			const keys = pair[1].list orelse &[_]Value{};
			for (keys) |item| {
				const key = item.text orelse continue;
				if (passed < skip) {
					passed += 1;
					continue;
				}
				if (found >= ceiling) {
					break;
				}
				// The type, the ttl and the value are three more commands per key, so
				// they are only asked for once a key is going to be shown.
				try rows.add(&[_]Value{
					.{ .text = try arena.dupe(u8, key) },
					.{ .text = try arena.dupe(u8, try self.keyType(key)) },
					.{ .number = try self.keyTtl(key) },
					.{ .text = try arena.dupe(u8, try self.keyValue(key)) },
				});
				found += 1;
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

	fn keyType(self: *Db, key: []const u8) db.Error![]const u8 {
		const reply = try self.command(&[_][]const u8{ "TYPE", key });
		return reply.text orelse "?";
	}

	fn keyTtl(self: *Db, key: []const u8) db.Error!i64 {
		const reply = try self.command(&[_][]const u8{ "TTL", key });
		return switch (reply) {
			.number => |value| value,
			else => -1,
		};
	}

	/// What a key holds, in the shape its type allows: a string as it is, a
	/// collection as its elements, and a hash as `field=value` pairs. Long
	/// collections are cut off, because this is a preview in one grid cell.
	fn keyValue(self: *Db, key: []const u8) db.Error![]const u8 {
		const arena = self.replies.allocator();
		const kind = try self.keyType(key);
		var buf: [16]u8 = undefined;
		const stop = std.fmt.bufPrint(&buf, "{d}", .{PREVIEW - 1}) catch "49";
		const reply = if (std.mem.eql(u8, kind, "string"))
			try self.command(&[_][]const u8{ "GET", key })
		else if (std.mem.eql(u8, kind, "list"))
			try self.command(&[_][]const u8{ "LRANGE", key, "0", stop })
		else if (std.mem.eql(u8, kind, "set"))
			try self.command(&[_][]const u8{ "SMEMBERS", key })
		else if (std.mem.eql(u8, kind, "zset"))
			try self.command(&[_][]const u8{ "ZRANGE", key, "0", stop })
		else if (std.mem.eql(u8, kind, "hash"))
			try self.command(&[_][]const u8{ "HGETALL", key })
		else
			Value{ .text = "" };

		switch (reply) {
			.text => |text| return text orelse "",
			.number => |number| return std.fmt.allocPrint(arena, "{d}", .{number}) catch "",
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
					try out.appendSlice(arena, item.text orelse "");
				}
				if (items.len >= PREVIEW) {
					try out.appendSlice(arena, " …");
				}
				return out.items;
			},
		}
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
				"EXPIRE", pair.key, std.fmt.bufPrint(&buf, "{d}", .{seconds}) catch "0",
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
		var list: std.ArrayListUnmanaged([]const u8) = .empty;
		var index: u8 = 0;
		while (index < self.count) : (index += 1) {
			try list.append(arena, try std.fmt.allocPrint(arena, "{d}", .{index}));
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
		var list: std.ArrayListUnmanaged(db.Object) = .empty;
		try list.append(arena, .{
			.schema = try std.fmt.allocPrint(arena, "{d}", .{self.index}),
			.name = "data",
			.kind = .table,
			.rows = self.dbSize(),
		});
		return list.items;
	}

	fn useIndex(self: *Db, wanted: u8) db.Error!void {
		var buf: [8]u8 = undefined;
		const reply = try self.command(&[_][]const u8{
			"SELECT", std.fmt.bufPrint(&buf, "{d}", .{wanted}) catch "0",
		});
		if (reply == .failure) {
			self.remember(reply.failure);
			return error.Driver;
		}
		self.index = wanted;
		self.relabel();
	}

	pub fn columns(_: *Db, arena: std.mem.Allocator, _: db.Table) db.Error![]db.Column {
		var list: std.ArrayListUnmanaged(db.Column) = .empty;
		try list.append(arena, .{ .name = "key", .type = "string", .notnull = true, .pk = true, .original = "key" });
		try list.append(arena, .{ .name = "type", .type = "string", .original = "type" });
		try list.append(arena, .{ .name = "ttl", .type = "integer", .original = "ttl" });
		try list.append(arena, .{ .name = "value", .type = "string", .original = "value" });
		return list.items;
	}

	pub fn indexes(_: *Db, arena: std.mem.Allocator, _: db.Table) db.Error![]db.Index {
		var list: std.ArrayListUnmanaged(db.Index) = .empty;
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
		var list: std.ArrayListUnmanaged([]const u8) = .empty;
		try list.append(arena, "key");
		return .{ .columns = list.items };
	}

	pub fn alterContext(_: *Db, _: std.mem.Allocator, _: db.Table, _: []const db.Column) db.Error!db.AlterContext {
		return .{};
	}

	pub fn settings(self: *Db, arena: std.mem.Allocator) db.Error![]db.Setting {
		var list: std.ArrayListUnmanaged(db.Setting) = .empty;
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
		try list.append(arena, .{
			.label = "keys in this database",
			.value = try std.fmt.allocPrint(arena, "{d}", .{self.dbSize() orelse 0}),
		});
		try list.append(arena, .{
			.label = "databases",
			.value = try std.fmt.allocPrint(arena, "{d}", .{self.count}),
		});
		return list.items;
	}

	/// One line out of INFO, by its name.
	fn fact(self: *Db, name: []const u8) ?[]const u8 {
		const reply = self.command(&[_][]const u8{"INFO"}) catch return null;
		const text = reply.text orelse return null;
		var lines = std.mem.splitScalar(u8, text, '\n');
		while (lines.next()) |raw| {
			const trimmed = std.mem.trim(u8, raw, " \r");
			const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
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
		const items = reply.list orelse return 16;
		if (items.len < 2) {
			return 16;
		}
		return std.fmt.parseInt(u8, items[1].text orelse "16", 10) catch 16;
	}

	/// Redis has no batch: the console runs one command per line.
	pub fn split(_: *Db, arena: std.mem.Allocator, sql: []const u8) db.Error![]db.Statement {
		var list: std.ArrayListUnmanaged(db.Statement) = .empty;
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
		.socket = -1,
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

	fn deinit(self: Parts, allocator: std.mem.Allocator) void {
		allocator.free(self.host);
		allocator.free(self.password);
	}
};

/// `redis://[:password@]host[:port][/index]`, the URL redis-cli takes.
fn parse(allocator: std.mem.Allocator, target: []const u8) !Parts {
	var rest = target;
	for ([_][]const u8{ "redis://", "rediss://" }) |prefix| {
		if (std.ascii.startsWithIgnoreCase(rest, prefix)) {
			rest = rest[prefix.len..];
			break;
		}
	}
	var password: []const u8 = "";
	if (std.mem.lastIndexOfScalar(u8, rest, '@')) |at| {
		const credentials = rest[0..at];
		rest = rest[at + 1 ..];
		// `user:password` or just `:password`; Redis before 6 has no user.
		password = if (std.mem.indexOfScalar(u8, credentials, ':')) |colon|
			credentials[colon + 1 ..]
		else
			credentials;
	}
	// The query first, and whatever else the target has or has not got. It used
	// to be read only from inside the part after the `/`, so a target with no
	// database on it - `redis://host`, which is what somebody types - kept its
	// `?password=…` as part of the host name, and the app said it could not reach
	// `host?password=hunter2:6379`. Which also put the password on the screen.
	if (std.mem.indexOfScalar(u8, rest, '?')) |question| {
		var parameters = std.mem.tokenizeAny(u8, rest[question + 1 ..], "&");
		while (parameters.next()) |parameter| {
			if (std.ascii.startsWithIgnoreCase(parameter, "password=")) {
				password = parameter["password=".len..];
			}
		}
		rest = rest[0..question];
	}
	var index: u8 = 0;
	if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
		index = std.fmt.parseInt(u8, rest[slash + 1 ..], 10) catch 0;
		rest = rest[0..slash];
	}
	var host: []const u8 = if (rest.len != 0) rest else "127.0.0.1";
	var port: u16 = 6379;
	if (std.mem.lastIndexOfScalar(u8, host, ':')) |colon| {
		port = std.fmt.parseInt(u16, host[colon + 1 ..], 10) catch port;
		host = host[0..colon];
	}
	return .{
		.host = try allocator.dupeZ(u8, host),
		.password = try unescape(allocator, password),
		.port = port,
		.index = index,
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
	try std.testing.expect(owns("redis://localhost"));
	try std.testing.expect(!owns("mysql://localhost/demo"));
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
	setTimeout(pair[0], 50);

	var self = Db{
		.allocator = std.testing.allocator,
		.socket = pair[0],
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

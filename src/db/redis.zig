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
//! **The SQL the app generates is recognised, not parsed.** The interface asks
//! for rows with `SELECT * FROM "data" …` and changes them with UPDATE, INSERT
//! and DELETE, so those four shapes - and only those, in the form this app itself
//! writes them - are turned into `SCAN`, `SET`, `EXPIRE` and `DEL`. Anything else
//! is passed to Redis as a command line, which is what makes the SQL editor a
//! Redis console: `KEYS user:*`, `HGETALL cart:7`, `INFO memory`. If a third
//! engine like this one ever appears, the interface should grow a non-SQL path
//! instead of every such driver growing a recogniser.

const std = @import("std");
const db = @import("db.zig");

const List = std.ArrayListUnmanaged(u8);

/// How many keys one page of the grid fetches at most, so a database with
/// millions of them still answers.
const PAGE = 1000;

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

		const socket = connect(parts.host, parts.port) catch {
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
		self.rename();
		try self.version_text.print(allocator, "Redis {s}", .{self.fact("redis_version") orelse "?"});
		return self;
	}

	/// `host:port/index`, as the header shows it.
	fn rename(self: *Db) void {
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
			if (self.parseValue(arena)) |value| {
				// Everything before the cursor has been consumed; drop it so a long
				// session does not grow the buffer forever.
				if (self.at != 0) {
					self.buffer.replaceRangeAssumeCapacity(0, self.at, "");
					self.at = 0;
				}
				return value;
			} else |err| switch (err) {
				error.Incomplete => try self.fill(),
				else => return error.Driver,
			}
		}
	}

	fn fill(self: *Db) db.Error!void {
		var chunk: [16 * 1024]u8 = undefined;
		const got = std.c.recv(self.socket, &chunk, chunk.len, 0);
		if (got <= 0) {
			self.remember("redis closed the connection");
			return error.Driver;
		}
		try self.buffer.appendSlice(self.allocator, chunk[0..@intCast(got)]);
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

	/// Either one of the shapes this app writes, or a Redis command line.
	pub fn query(self: *Db, sql: []const u8, rest: ?*[]const u8) db.Error!?db.Rows {
		if (rest) |out| {
			out.* = sql[sql.len..];
		}
		const trimmed = std.mem.trim(u8, sql, " \t\r\n;");
		if (trimmed.len == 0) {
			return null;
		}
		self.starting();
		self.last_error.clearRetainingCapacity();
		_ = self.replies.reset(.retain_capacity);

		if (Request.recognise(trimmed)) |request| {
			return switch (request) {
				.refuse => |why| {
					self.remember(why);
					return error.Driver;
				},
				.scan => |like| .{ .redis = try self.scan(try Request.glob(self.replies.allocator(), like)) },
				.set => |pair| try self.setValue(pair),
				.expire => |pair| try self.setTtl(pair),
				.delete => |key| try self.deleteKey(key),
				.count => .{ .redis = try self.oneNumber("keys", self.dbSize() orelse 0) },
			};
		}
		return .{ .redis = try self.console(trimmed) };
	}

	/// A command typed in the editor, with its reply laid out as rows.
	fn console(self: *Db, text: []const u8) db.Error!Rows {
		var arena = std.heap.ArenaAllocator.init(self.allocator);
		defer arena.deinit();
		const args = try splitCommand(arena.allocator(), text);
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
		var rows = Rows{ .owner = self, .names = &[_][]const u8{"reply"} };
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
		var rows = Rows{ .owner = self, .names = &[_][]const u8{name} };
		try rows.add(&[_]Value{.{ .text = try self.replies.allocator().dupe(u8, text) }});
		return rows;
	}

	fn oneNumber(self: *Db, name: []const u8, number: i64) db.Error!Rows {
		var rows = Rows{ .owner = self, .names = &[_][]const u8{name} };
		try rows.add(&[_]Value{.{ .number = number }});
		return rows;
	}

	/// The rows of the pseudo table: key, type, ttl and value.
	fn scan(self: *Db, pattern: []const u8) db.Error!Rows {
		const arena = self.replies.allocator();
		var rows = Rows{ .owner = self, .names = &[_][]const u8{ "key", "type", "ttl", "value" } };
		var cursor: []const u8 = "0";
		var found: usize = 0;
		while (found < PAGE) {
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

	fn setValue(self: *Db, pair: Request.Pair) db.Error!?db.Rows {
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

	fn setTtl(self: *Db, pair: Request.Pair) db.Error!?db.Rows {
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
		self.rename();
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

pub const Value = union(enum) {
	nil: void,
	text: ?[]const u8,
	number: i64,
	failure: []const u8,
	list: ?[]const Value,
};

// ------------------------------------------------------------------- cursor

/// Every reply is small enough to hold, so the cursor is a list of rows rather
/// than something that streams.
pub const Rows = struct {
	owner: *Db,
	names: []const []const u8 = &[_][]const u8{},
	rows: std.ArrayListUnmanaged([]const Value) = .empty,
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
			.failure => |text| .{ .text = text },
			.text => |text| if (text) |bytes| .{ .text = bytes } else .{ .null = {} },
			.list => .{ .text = "…" },
		};
	}

	pub fn sourceTable(_: *Rows, _: usize) []const u8 {
		return "data";
	}

	pub fn sourceColumn(self: *Rows, at: usize) []const u8 {
		return self.name(at);
	}

	pub fn isNumeric(self: *Rows, at: usize) bool {
		return std.mem.eql(u8, self.name(at), "ttl");
	}

	pub fn affected(self: *Rows) i64 {
		return self.changed;
	}
};

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

// ------------------------------------------------------- reading the app's SQL

/// The four shapes this app writes, recognised well enough to answer them. Not a
/// SQL parser: it knows the text `app.zig` generates and nothing else.
pub const Request = union(enum) {
	pub const Pair = struct { key: []const u8, value: []const u8, ttl: ?[]const u8 = null };

	/// `SELECT * FROM "data" …` - with a MATCH pattern taken from a WHERE on the
	/// key, if there is one.
	scan: []const u8,
	set: Pair,
	expire: Pair,
	delete: []const u8,
	count: void,
	/// Something the interface can build but Redis cannot answer.
	refuse: []const u8,

	pub fn recognise(sql: []const u8) ?Request {
		// The search screen builds one SELECT per column of every table and unions
		// them; there is nothing to map that onto.
		if (std.mem.indexOf(u8, sql, "UNION ALL") != null or std.mem.indexOf(u8, sql, "AS \"table\"") != null) {
			return .{ .refuse = "searching every table is not a redis idea - filter the key with W, or use KEYS in the console" };
		}
		if (std.ascii.startsWithIgnoreCase(sql, "SELECT count(*)")) {
			return .{ .count = {} };
		}
		if (std.ascii.startsWithIgnoreCase(sql, "SELECT ")) {
			// Only a select over the pseudo table; anything else is a command.
			if (std.mem.indexOf(u8, sql, "\"data\"") == null) {
				return null;
			}
			return .{ .scan = pattern(sql) };
		}
		if (std.ascii.startsWithIgnoreCase(sql, "UPDATE ")) {
			const key = valueOf(sql, "\"key\" = ") orelse return null;
			if (valueOf(sql, "\"value\" = ")) |text| {
				return .{ .set = .{ .key = key, .value = text } };
			}
			if (valueOf(sql, "\"ttl\" = ")) |text| {
				return .{ .expire = .{ .key = key, .value = text } };
			}
			return null;
		}
		if (std.ascii.startsWithIgnoreCase(sql, "INSERT INTO ")) {
			// `INSERT INTO "data" ("key", "value") VALUES ('a', 'b')` - matched by
			// column name rather than by position, because the form may leave any of
			// them out.
			const open = std.mem.indexOf(u8, sql, "VALUES") orelse return null;
			// From the bracket on, so the table - which may be `"0"."data"` - is not
			// mistaken for the first column.
			const bracket = std.mem.indexOfScalar(u8, sql[0..open], '(') orelse return null;
			var names = identifiers(sql[bracket..open]);
			var cells = Cells{ .rest = sql[open..] };
			var key: ?[]const u8 = null;
			var text: []const u8 = "";
			var ttl: ?[]const u8 = null;
			while (names.next()) |name| {
				// Every column is in the statement, NULL included, so the two lists
				// have to be walked together rather than by counting quotes.
				const cell = cells.next() orelse break;
				const value = switch (cell) {
					.nul => continue,
					.text => |bytes| bytes,
				};
				if (std.mem.eql(u8, name, "key")) {
					key = value;
				} else if (std.mem.eql(u8, name, "value")) {
					text = value;
				} else if (std.mem.eql(u8, name, "ttl")) {
					ttl = value;
				}
			}
			if (key == null or key.?.len == 0) {
				return .{ .refuse = "a redis row needs a key" };
			}
			return .{ .set = .{ .key = key.?, .value = text, .ttl = ttl } };
		}
		if (std.ascii.startsWithIgnoreCase(sql, "DELETE FROM ")) {
			const key = valueOf(sql, "\"key\" = ") orelse return null;
			return .{ .delete = key };
		}
		return null;
	}

	/// The `MATCH` pattern for SCAN, out of a WHERE on the key: an equality is the
	/// key itself, and a LIKE is translated - `%` is Redis's `*` and `_` its `?`.
	/// Anything else scans everything.
	fn pattern(sql: []const u8) []const u8 {
		if (valueOf(sql, "\"key\" = ")) |key| {
			return key;
		}
		if (valueOf(sql, "\"key\" LIKE ")) |like| {
			return like;
		}
		return "*";
	}

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

	/// The single quoted literal that follows `needle`.
	fn valueOf(sql: []const u8, needle: []const u8) ?[]const u8 {
		const at = std.mem.indexOf(u8, sql, needle) orelse return null;
		var values = literals(sql[at + needle.len ..]);
		return values.next();
	}

	/// The double quoted identifiers of a statement, in order.
	const Identifiers = struct {
		rest: []const u8,

		fn next(self: *Identifiers) ?[]const u8 {
			const open = std.mem.indexOfScalar(u8, self.rest, '"') orelse return null;
			const close = std.mem.indexOfScalarPos(u8, self.rest, open + 1, '"') orelse return null;
			const text = self.rest[open + 1 .. close];
			self.rest = self.rest[close + 1 ..];
			return text;
		}
	};

	fn identifiers(sql: []const u8) Identifiers {
		return .{ .rest = sql };
	}

	/// One value out of a `VALUES (…)` list: either a literal or SQL NULL.
	const Cell = union(enum) { nul: void, text: []const u8 };

	/// Walks a `VALUES (…)` list, keeping NULLs in place so the values stay lined
	/// up with the column names.
	const Cells = struct {
		rest: []const u8,
		started: bool = false,

		fn next(self: *Cells) ?Cell {
			if (!self.started) {
				const open = std.mem.indexOfScalar(u8, self.rest, '(') orelse return null;
				self.rest = self.rest[open + 1 ..];
				self.started = true;
			}
			// Skip to the value itself.
			var at: usize = 0;
			while (at < self.rest.len and (self.rest[at] == ' ' or self.rest[at] == ',')) : (at += 1) {}
			if (at >= self.rest.len or self.rest[at] == ')') {
				return null;
			}
			if (self.rest[at] != '\'') {
				const stop = std.mem.indexOfAnyPos(u8, self.rest, at, ",)") orelse self.rest.len;
				const word = std.mem.trim(u8, self.rest[at..stop], " ");
				self.rest = self.rest[stop..];
				return if (std.ascii.eqlIgnoreCase(word, "NULL")) .{ .nul = {} } else .{ .text = word };
			}
			const open = at;
			at += 1;
			while (at < self.rest.len) : (at += 1) {
				if (self.rest[at] != '\'') {
					continue;
				}
				if (at + 1 < self.rest.len and self.rest[at + 1] == '\'') {
					at += 1;
					continue;
				}
				const text = self.rest[open + 1 .. at];
				self.rest = self.rest[at + 1 ..];
				return .{ .text = text };
			}
			return null;
		}
	};

	const Literals = struct {
		rest: []const u8,

		fn next(self: *Literals) ?[]const u8 {
			const open = std.mem.indexOfScalar(u8, self.rest, '\'') orelse return null;
			var at = open + 1;
			while (at < self.rest.len) : (at += 1) {
				if (self.rest[at] != '\'') {
					continue;
				}
				// A doubled quote is one inside the string.
				if (at + 1 < self.rest.len and self.rest[at + 1] == '\'') {
					at += 1;
					continue;
				}
				const text = self.rest[open + 1 .. at];
				self.rest = self.rest[at + 1 ..];
				return text;
			}
			return null;
		}
	};

	fn literals(sql: []const u8) Literals {
		return .{ .rest = sql };
	}
};

/// A command line as a list of arguments, with quotes honoured so a value may
/// contain spaces.
fn splitCommand(arena: std.mem.Allocator, text: []const u8) ![]const []const u8 {
	var list: std.ArrayListUnmanaged([]const u8) = .empty;
	var at: usize = 0;
	while (at < text.len) {
		while (at < text.len and (text[at] == ' ' or text[at] == '\t')) : (at += 1) {}
		if (at >= text.len) {
			break;
		}
		if (text[at] == '"' or text[at] == '\'') {
			const quote = text[at];
			at += 1;
			const from = at;
			while (at < text.len and text[at] != quote) : (at += 1) {}
			try list.append(arena, text[from..at]);
			at = @min(text.len, at + 1);
			continue;
		}
		const from = at;
		while (at < text.len and text[at] != ' ' and text[at] != '\t') : (at += 1) {}
		try list.append(arena, text[from..at]);
	}
	return list.items;
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
	var index: u8 = 0;
	if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
		var tail = rest[slash + 1 ..];
		if (std.mem.indexOfScalar(u8, tail, '?')) |question| {
			var parameters = std.mem.tokenizeAny(u8, tail[question + 1 ..], "&");
			while (parameters.next()) |parameter| {
				if (std.ascii.startsWithIgnoreCase(parameter, "password=")) {
					password = parameter["password=".len..];
				}
			}
			tail = tail[0..question];
		}
		index = std.fmt.parseInt(u8, tail, 10) catch 0;
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

/// A plain blocking TCP connection, through libc as the rest of this app does.
fn connect(host: [:0]const u8, port: u16) !std.c.fd_t {
	var hints = std.mem.zeroes(std.c.addrinfo);
	hints.family = std.c.AF.UNSPEC;
	hints.socktype = std.c.SOCK.STREAM;
	var service: [8]u8 = undefined;
	const service_text = std.fmt.bufPrintZ(&service, "{d}", .{port}) catch return error.BadPort;
	var found: ?*std.c.addrinfo = null;
	if (std.c.getaddrinfo(host.ptr, service_text.ptr, &hints, &found) != @as(std.c.EAI, @enumFromInt(0))) {
		return error.NoSuchHost;
	}
	defer if (found) |list| std.c.freeaddrinfo(list);
	var candidate = found;
	while (candidate) |info| : (candidate = info.next) {
		const socket = std.c.socket(@intCast(info.family), @intCast(info.socktype), @intCast(info.protocol));
		if (socket < 0) {
			continue;
		}
		if (std.c.connect(socket, info.addr.?, info.addrlen) == 0) {
			return socket;
		}
		_ = std.c.close(socket);
	}
	return error.Refused;
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
	try std.testing.expect(owns("redis://localhost"));
	try std.testing.expect(!owns("mysql://localhost/demo"));
}

test "the app's own SQL is recognised" {
	const scan = Request.recognise("SELECT * FROM \"0\".\"data\" LIMIT 200").?;
	try std.testing.expectEqualStrings("*", scan.scan);

	const one = Request.recognise("SELECT * FROM \"data\" WHERE \"key\" = 'user:7'").?;
	try std.testing.expectEqualStrings("user:7", one.scan);

	const set = Request.recognise("UPDATE \"data\" SET \"value\" = 'hello' WHERE \"key\" = 'greeting'").?;
	try std.testing.expectEqualStrings("greeting", set.set.key);
	try std.testing.expectEqualStrings("hello", set.set.value);

	const ttl = Request.recognise("UPDATE \"data\" SET \"ttl\" = '60' WHERE \"key\" = 'greeting'").?;
	try std.testing.expectEqualStrings("60", ttl.expire.value);

	const gone = Request.recognise("DELETE FROM \"data\" WHERE \"key\" = 'greeting'").?;
	try std.testing.expectEqualStrings("greeting", gone.delete);

	const added = Request.recognise("INSERT INTO \"data\" (\"key\", \"value\") VALUES ('a', 'b')").?;
	try std.testing.expectEqualStrings("a", added.set.key);
	try std.testing.expectEqualStrings("b", added.set.value);

	// A NULL keeps its place, so the columns after it still line up.
	const sparse = Request.recognise("INSERT INTO \"0\".\"data\" (\"key\", \"type\", \"ttl\", \"value\") VALUES ('k', NULL, NULL, 'v')").?;
	try std.testing.expectEqualStrings("k", sparse.set.key);
	try std.testing.expectEqualStrings("v", sparse.set.value);
	try std.testing.expect(sparse.set.ttl == null);

	// The table may be schema qualified, which is not a column.
	const qualified = Request.recognise("INSERT INTO \"0\".\"data\" (\"key\", \"value\") VALUES ('k', 'v')").?;
	try std.testing.expectEqualStrings("k", qualified.set.key);
	try std.testing.expectEqualStrings("v", qualified.set.value);

	// The columns are matched by name, so a form that leaves one out still works.
	const with_ttl = Request.recognise("INSERT INTO \"data\" (\"key\", \"ttl\") VALUES ('a', '60')").?;
	try std.testing.expectEqualStrings("a", with_ttl.set.key);
	try std.testing.expectEqualStrings("", with_ttl.set.value);
	try std.testing.expectEqualStrings("60", with_ttl.set.ttl.?);

	// A row with no key is refused rather than writing an empty one.
	try std.testing.expect(Request.recognise("INSERT INTO \"data\" (\"value\") VALUES ('b')").? == .refuse);

	// A command is not SQL and is left alone.
	try std.testing.expect(Request.recognise("HGETALL cart:7") == null);
	try std.testing.expect(Request.recognise("SELECT 2") == null);
}

test "a command line is split with quotes honoured" {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();
	const args = try splitCommand(arena.allocator(), "SET greeting \"hello world\"");
	try std.testing.expectEqual(@as(usize, 3), args.len);
	try std.testing.expectEqualStrings("SET", args[0]);
	try std.testing.expectEqualStrings("greeting", args[1]);
	try std.testing.expectEqualStrings("hello world", args[2]);
}

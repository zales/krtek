//! The RabbitMQ driver: the management API, and deliberately not AMQP.
//!
//! **Reading a queue over AMQP is destructive.** `basic.get` takes the message
//! off; putting it back with `nack requeue=true` changes the order and marks it
//! redelivered. There is no peek, because a queue is not a table - it is a line
//! of people waiting, and looking at somebody in a queue means pulling them out
//! of it. A driver that browsed messages the way it browses rows would quietly
//! reorder a production queue every time the screen was drawn, and no amount of
//! care in the client can fix that: the protocol has no other move.
//!
//! So what is a table here is the *topology*, which can be read as often as
//! anybody likes: queues, exchanges, bindings, consumers, connections, channels
//! and nodes, each of them a list endpoint of the management API. Those endpoints
//! page, count and sort on the server, so `1-50 of 812` is exact and costs one
//! request, and sorting by the number of messages is the broker's own work rather
//! than this program's.
//!
//! Messages are still reachable - `PEEK orders` in the editor, which is a console
//! for the broker - and what that does is said out loud rather than hidden: it
//! takes messages and puts them back, so their order changes and they come back
//! marked redelivered. `DRAIN` is the one that keeps them off. Neither happens
//! while browsing.
//!
//! The parts with no connection in them are files of their own:
//!
//! * `rabbit/api.zig` - the tables, where each column lives in the JSON, and the
//!   two shapes a list endpoint answers in.
//! * `rabbit/target.zig` - what `rabbit://user@host:15672/vhost` means, and why an
//!   `amqp://` port is not connected to.

const std = @import("std");
const db = @import("db.zig");
const http = @import("http.zig");

pub const api = @import("rabbit/api.zig");
pub const address = @import("rabbit/target.zig");

const List = db.List;
const Json = std.json.Value;

comptime {
	_ = api;
	_ = address;
}

pub const owns = address.owns;
pub const parse = address.parse;
pub const Parts = address.Parts;

/// How many rows one page asks for when nobody said.
const PAGE: usize = 100;
/// How many messages `PEEK` looks at unless told otherwise. Small on purpose:
/// every one of them is taken off the queue and put back.
const PEEK: usize = 10;
/// How much of a message body the broker is asked to send.
const TRUNCATE: usize = 50_000;

pub const Db = struct {
	allocator: std.mem.Allocator,
	/// Owns the strings in `parts` and the authorization header.
	home: std.heap.ArenaAllocator,
	parts: Parts = .{},
	/// The vhost in use, which the interface calls the schema.
	vhost: []const u8 = "/",
	authorization: []const u8 = "",
	client: ?http.Client = null,
	label: List = .empty,
	version_text: List = .empty,
	last_error: List = .empty,
	progress: ?db.Progress = null,
	requests: usize = 0,
	/// Rows and everything they point at, until the next statement.
	replies: std.heap.ArenaAllocator,

	pub fn open(allocator: std.mem.Allocator, target: []const u8, report: *List) !*Db {
		const self = try allocator.create(Db);
		self.* = .{
			.allocator = allocator,
			.home = std.heap.ArenaAllocator.init(allocator),
			.replies = std.heap.ArenaAllocator.init(allocator),
		};
		errdefer self.close();

		const home = self.home.allocator();
		self.parts = address.parse(home, target) catch {
			try report.appendSlice(allocator, "that is not a rabbitmq target");
			return error.Driver;
		};
		self.vhost = self.parts.vhost;
		self.authorization = try basic(home, self.parts.user, self.parts.password);
		self.client = http.Client.init(
			allocator,
			self.parts.host,
			self.parts.port,
			self.parts.tls,
			self.parts.verify,
		) catch {
			try report.appendSlice(allocator, "out of memory");
			return error.Driver;
		};
		self.relabel();

		var scratch = std.heap.ArenaAllocator.init(allocator);
		defer scratch.deinit();
		const arena = scratch.allocator();

		const response = self.call(arena, .{ .path = "/api/overview" }) catch {
			try report.appendSlice(allocator, self.message());
			return error.Driver;
		};
		if (!response.ok()) {
			const why = self.fail(response);
			try report.appendSlice(allocator, self.message());
			return why;
		}
		const overview = std.json.parseFromSliceLeaky(Json, arena, response.body, .{}) catch {
			try report.appendSlice(allocator, "that is not RabbitMQ's management API");
			return error.Driver;
		};
		try self.version_text.print(allocator, "{s} {s}", .{
			text(api.pick(overview, "product_name")) orelse "RabbitMQ",
			text(api.pick(overview, "rabbitmq_version")) orelse
				text(api.pick(overview, "product_version")) orelse "?",
		});

		// The overview answers whatever the vhost is, so a vhost that is not there -
		// or that this user may not see - would only show up as an empty screen.
		const vhost = try self.call(arena, .{
			.path = try std.fmt.allocPrint(arena, "/api/vhosts/{s}", .{try address.escaped(arena, self.vhost)}),
		});
		if (!vhost.ok()) {
			try report.print(allocator, "there is no vhost called {s} that {s} can see", .{ self.vhost, self.parts.user });
			return error.Driver;
		}
		return self;
	}

	pub fn close(self: *Db) void {
		if (self.client) |*client| {
			client.deinit();
		}
		self.label.deinit(self.allocator);
		self.version_text.deinit(self.allocator);
		self.last_error.deinit(self.allocator);
		self.replies.deinit();
		self.home.deinit();
		self.allocator.destroy(self);
	}

	pub fn watch(self: *Db, progress: ?db.Progress) void {
		self.progress = progress;
		if (self.client) |*client| {
			client.watch(progress);
		}
	}

	pub fn caps(_: *Db) db.Caps {
		return .{
			// Vhosts, which is what a schema is here.
			.schemas = true,
			.databases = true,
			.label = "RabbitMQ",
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
		// The default vhost is a slash of its own; every other one needs one in
		// front of it.
		const separator: []const u8 = if (std.mem.startsWith(u8, self.vhost, "/")) "" else "/";
		self.label.print(self.allocator, "{s}:{d}{s}{s}", .{
			self.parts.host,
			self.parts.port,
			separator,
			self.vhost,
		}) catch {};
	}

	fn remember(self: *Db, why: []const u8) void {
		self.last_error.clearRetainingCapacity();
		self.last_error.appendSlice(self.allocator, why) catch {};
	}

	fn complain(self: *Db, comptime format: []const u8, args: anytype) void {
		self.last_error.clearRetainingCapacity();
		self.last_error.print(self.allocator, format, args) catch {};
	}

	fn begin(self: *Db) void {
		if (self.progress) |progress| {
			progress.starting();
		}
		self.last_error.clearRetainingCapacity();
		_ = self.replies.reset(.retain_capacity);
	}

	// ------------------------------------------------------------- requests

	const Call = struct {
		method: []const u8 = "GET",
		/// Under the host, `{vhost}` already filled in by whoever built it.
		path: []const u8,
		query: []const u8 = "",
		body: []const u8 = "",
	};

	fn call(self: *Db, arena: std.mem.Allocator, request: Call) db.Error!http.Response {
		const client = &(self.client orelse return error.Driver);
		var headers: std.ArrayListUnmanaged(http.Header) = .empty;
		try headers.append(arena, .{ .name = "Authorization", .value = self.authorization });
		// Anything at all: asking for JSON makes the endpoints that answer with no
		// content at all - purging a queue is one - refuse with a 406.
		try headers.append(arena, .{ .name = "Accept", .value = "*/*" });
		if (request.body.len != 0) {
			try headers.append(arena, .{ .name = "Content-Type", .value = "application/json" });
		}
		const target = try std.fmt.allocPrint(arena, "{s}{s}{s}{s}", .{
			self.parts.prefix,
			request.path,
			if (request.query.len != 0) "?" else "",
			request.query,
		});
		self.requests += 1;
		return client.send(arena, .{
			.method = request.method,
			.target = target,
			.headers = headers.items,
			.body = request.body,
		}) catch |err| {
			switch (err) {
				error.GivenUp => self.remember("given up on"),
				error.Malformed => self.complain("{s}:{d} answered something that is not HTTP - is that the management port?", .{ self.parts.host, self.parts.port }),
				else => {
					const why = client.message();
					if (why.len != 0) {
						self.remember(why);
					} else {
						self.complain("the connection to {s}:{d} is gone", .{ self.parts.host, self.parts.port });
					}
					if (self.parts.moved_port) {
						self.last_error.appendSlice(self.allocator, " - that is the management port, not the one the amqp:// url named") catch {};
					}
				},
			}
			return error.Driver;
		};
	}

	/// A reply that is not a success, as the message the interface shows. The
	/// management API puts an error and a reason in the body; a 401 is worth
	/// saying plainly, because it is what makes the interface offer the password.
	fn fail(self: *Db, response: http.Response) db.Error {
		if (response.status == 401) {
			self.complain("the password for {s} was not accepted", .{self.parts.user});
			return error.Driver;
		}
		if (response.status == 404) {
			self.remember("there is nothing there - a wrong name, or a vhost this user cannot see");
			return error.Driver;
		}
		var scratch = std.heap.ArenaAllocator.init(self.allocator);
		defer scratch.deinit();
		if (std.json.parseFromSliceLeaky(Json, scratch.allocator(), response.body, .{})) |body| {
			const what = text(api.pick(body, "error"));
			const why = text(api.pick(body, "reason"));
			if (what != null or why != null) {
				self.complain("{s}{s}{s}", .{
					what orelse "",
					if (what != null and why != null) ": " else "",
					why orelse "",
				});
				return error.Driver;
			}
		} else |_| {}
		self.complain("the broker answered {d} {s}", .{ response.status, response.reason });
		return error.Driver;
	}

	/// The path of a table's endpoint, with the vhost escaped into it.
	fn pathOf(self: *Db, arena: std.mem.Allocator, table: api.Table) db.Error![]const u8 {
		const mark = "{vhost}";
		const at = std.mem.indexOf(u8, table.path, mark) orelse return table.path;
		return std.fmt.allocPrint(arena, "{s}{s}{s}", .{
			table.path[0..at],
			try address.escaped(arena, self.vhost),
			table.path[at + mark.len ..],
		});
	}

	/// `/api/queues/%2F/orders`, and the same for anything else addressed by name.
	fn itemPath(self: *Db, arena: std.mem.Allocator, kind: []const u8, name: []const u8) db.Error![]const u8 {
		return std.fmt.allocPrint(arena, "/api/{s}/{s}/{s}", .{
			kind,
			try address.escaped(arena, self.vhost),
			try address.escaped(arena, name),
		});
	}

	// -------------------------------------------------------------- reading

	pub fn exec(self: *Db, sql: []const u8) db.Error!void {
		var rows = (try self.query(sql, null)) orelse return;
		rows.close();
	}

	/// A line typed in the editor, which for RabbitMQ is a console.
	pub fn query(self: *Db, sql: []const u8, rest: ?*[]const u8) db.Error!?db.Rows {
		if (rest) |out| {
			out.* = sql[sql.len..];
		}
		const trimmed = std.mem.trim(u8, sql, " \t\r\n;");
		if (trimmed.len == 0) {
			return null;
		}
		self.begin();
		return .{ .rabbit = try self.console(trimmed) };
	}

	pub fn select(self: *Db, request: db.ask.Select) db.Error!?db.Rows {
		self.begin();
		const table = api.find(request.table.name) orelse {
			self.complain("{s} is not one of this broker's tables", .{request.table.name});
			return error.Driver;
		};
		if (request.where_text.len != 0) {
			self.remember("a raw WHERE is SQL - filter the name with = or LIKE instead");
			return error.Driver;
		}
		const arena = self.replies.allocator();
		const wanted = try self.whereOf(arena, table, request.where);

		var query_text: List = .empty;
		const limit = if (request.limit != 0) request.limit else PAGE;
		if (table.paged) {
			// The broker pages, counts and sorts; doing any of it here would mean
			// fetching everything first, which is the thing to avoid on a broker with
			// ten thousand queues.
			try query_text.print(arena, "page={d}&page_size={d}", .{
				if (request.count) 1 else request.offset / limit + 1,
				if (request.count) 1 else limit,
			});
			if (wanted.name.len != 0) {
				try query_text.appendSlice(arena, "&name=");
				try address.escape(&query_text, arena, wanted.name);
			}
			if (request.order.len != 0) {
				const sort = columnFrom(table, request.order) orelse request.order;
				try query_text.print(arena, "&sort={s}", .{sort});
				if (request.descending) {
					try query_text.appendSlice(arena, "&sort_reverse=true");
				}
			}
		}
		const response = try self.call(arena, .{
			.path = try self.pathOf(arena, table),
			.query = query_text.items,
		});
		if (!response.ok()) {
			return self.fail(response);
		}
		const answer = api.page(arena, response.body) catch {
			self.remember("the broker answered something that is not a list");
			return error.Driver;
		};

		if (request.count) {
			// An exact count from the broker, or - on an endpoint that does not page -
			// however many it sent.
			return .{ .rabbit = try self.oneNumber("count", answer.total orelse @as(i64, @intCast(answer.items.len))) };
		}

		var rows = self.newRows(table);
		var seen: usize = 0;
		var skipped: usize = 0;
		for (answer.items) |item| {
			// An exact name is the API's substring match narrowed here: it filters by
			// what a name contains, which is not the same question.
			if (wanted.exact) |name| {
				const found = text(api.pick(item, "name")) orelse "";
				if (!std.mem.eql(u8, found, name)) {
					continue;
				}
			}
			// An endpoint that does not page is paged here, over what it sent.
			if (!table.paged) {
				if (skipped < request.offset) {
					skipped += 1;
					continue;
				}
				if (seen >= limit) {
					break;
				}
			}
			seen += 1;
			try rows.addJson(table, item);
		}
		return .{ .rabbit = rows };
	}

	const Where = struct {
		/// What the broker is asked to filter on, which it treats as "contains".
		name: []const u8 = "",
		/// And what has to match exactly, which it cannot do.
		exact: ?[]const u8 = null,
	};

	fn whereOf(self: *Db, arena: std.mem.Allocator, table: api.Table, where: []const db.ask.Filter) db.Error!Where {
		var out = Where{};
		for (where) |filter| {
			if (!std.mem.eql(u8, filter.column, "name")) {
				self.complain("the broker filters a listing by name; {s} is not something it can be asked about", .{filter.column});
				return error.Driver;
			}
			if (!table.paged) {
				self.complain("{s} is not a listing the broker filters", .{table.name});
				return error.Driver;
			}
			switch (filter.op) {
				.eq => {
					out.name = try arena.dupe(u8, filter.value);
					out.exact = out.name;
				},
				.like => {
					// The API matches on what a name contains, so the wildcards around a
					// pattern are what it does anyway; one in the middle is not.
					const body = std.mem.trim(u8, filter.value, "%");
					if (std.mem.indexOfAny(u8, body, "%_") != null) {
						self.remember("the broker matches what a name contains: LIKE '%orders%' works, a pattern inside one does not");
						return error.Driver;
					}
					out.name = try arena.dupe(u8, body);
				},
				else => {
					self.remember("a name can be compared with = or LIKE, and nothing else");
					return error.Driver;
				},
			}
		}
		return out;
	}

	// -------------------------------------------------------------- writing

	pub fn apply(self: *Db, change: db.ask.Change) db.Error!void {
		self.begin();
		const table = api.find(change.table.name) orelse {
			self.complain("{s} is not one of this broker's tables", .{change.table.name});
			return error.Driver;
		};
		var scratch = std.heap.ArenaAllocator.init(self.allocator);
		defer scratch.deinit();
		const arena = scratch.allocator();

		switch (change.kind) {
			.update => {
				// True of every one of them: a queue's durability and a binding's key
				// are settled when it is declared.
				self.complain("a {s} is declared, not altered - delete it and declare it again", .{table.singular});
				return error.Driver;
			},
			.insert => {
				if (!table.insert) {
					self.complain("a {s} is not something this program creates", .{table.singular});
					return error.Driver;
				}
				const name = flat(db.ask.valueOf(change.cells, "name")) orelse "";
				if (std.mem.eql(u8, table.name, "queues")) {
					if (name.len == 0) {
						self.remember("a queue needs a name");
						return error.Driver;
					}
					try self.declareQueue(arena, name, .{
						.durable = truthy(flat(db.ask.valueOf(change.cells, "durable")), true),
						.kind = flat(db.ask.valueOf(change.cells, "type")) orelse "classic",
					});
					return;
				}
				if (std.mem.eql(u8, table.name, "exchanges")) {
					if (name.len == 0) {
						self.remember("an exchange needs a name");
						return error.Driver;
					}
					try self.declareExchange(arena, name, .{
						.kind = flat(db.ask.valueOf(change.cells, "type")) orelse "direct",
						.durable = truthy(flat(db.ask.valueOf(change.cells, "durable")), true),
					});
					return;
				}
				const source = flat(db.ask.valueOf(change.cells, "source")) orelse "";
				const destination = flat(db.ask.valueOf(change.cells, "destination")) orelse "";
				if (source.len == 0 or destination.len == 0) {
					self.remember("a binding needs a source and a destination");
					return error.Driver;
				}
				try self.bind(
					arena,
					source,
					destination,
					flat(db.ask.valueOf(change.cells, "destination_type")) orelse "queue",
					flat(db.ask.valueOf(change.cells, "routing_key")) orelse "",
				);
			},
			.delete => {
				if (!table.remove) {
					self.complain("a {s} is not something this program removes", .{table.singular});
					return error.Driver;
				}
				if (std.mem.eql(u8, table.name, "bindings")) {
					return self.unbind(arena, change.where);
				}
				const name = db.ask.only(change.where, "name") orelse {
					self.complain("which {s}? it is addressed by its name", .{table.singular});
					return error.Driver;
				};
				const path = if (std.mem.eql(u8, table.name, "connections"))
					// A connection belongs to the broker, not to a vhost.
					try std.fmt.allocPrint(arena, "/api/connections/{s}", .{try address.escaped(arena, name)})
				else
					try self.itemPath(arena, table.name, name);
				const response = try self.call(arena, .{ .method = "DELETE", .path = path });
				if (!response.ok()) {
					return self.fail(response);
				}
			},
		}
	}

	const Queue = struct { durable: bool = true, kind: []const u8 = "classic" };

	fn declareQueue(self: *Db, arena: std.mem.Allocator, name: []const u8, what: Queue) db.Error!void {
		var body: List = .empty;
		try body.print(arena, "{{\"durable\":{s},\"auto_delete\":false,\"arguments\":{{\"x-queue-type\":\"{s}\"}}}}", .{
			if (what.durable) "true" else "false",
			what.kind,
		});
		const response = try self.call(arena, .{
			.method = "PUT",
			.path = try self.itemPath(arena, "queues", name),
			.body = body.items,
		});
		if (!response.ok()) {
			return self.fail(response);
		}
	}

	const Exchange = struct { kind: []const u8 = "direct", durable: bool = true };

	fn declareExchange(self: *Db, arena: std.mem.Allocator, name: []const u8, what: Exchange) db.Error!void {
		var body: List = .empty;
		try body.print(arena, "{{\"type\":\"{s}\",\"durable\":{s},\"auto_delete\":false,\"internal\":false,\"arguments\":{{}}}}", .{
			what.kind,
			if (what.durable) "true" else "false",
		});
		const response = try self.call(arena, .{
			.method = "PUT",
			.path = try self.itemPath(arena, "exchanges", name),
			.body = body.items,
		});
		if (!response.ok()) {
			return self.fail(response);
		}
	}

	fn bind(
		self: *Db,
		arena: std.mem.Allocator,
		source: []const u8,
		destination: []const u8,
		kind: []const u8,
		routing_key: []const u8,
	) db.Error!void {
		var body: List = .empty;
		try body.appendSlice(arena, "{\"routing_key\":");
		try quote(&body, arena, routing_key);
		try body.appendSlice(arena, ",\"arguments\":{}}");
		const path = try std.fmt.allocPrint(arena, "/api/bindings/{s}/e/{s}/{s}/{s}", .{
			try address.escaped(arena, self.vhost),
			try address.escaped(arena, source),
			if (std.mem.startsWith(u8, kind, "e")) "e" else "q",
			try address.escaped(arena, destination),
		});
		const response = try self.call(arena, .{ .method = "POST", .path = path, .body = body.items });
		if (!response.ok()) {
			return self.fail(response);
		}
	}

	/// A binding is addressed by where it comes from, where it goes and the key
	/// the API made for it - which is why `properties` is one of the columns.
	fn unbind(self: *Db, arena: std.mem.Allocator, where: []const db.ask.Filter) db.Error!void {
		const source = db.ask.only(where, "source") orelse "";
		const destination = db.ask.only(where, "destination") orelse "";
		const properties = db.ask.only(where, "properties") orelse "";
		if (source.len == 0 or destination.len == 0 or properties.len == 0) {
			self.remember("which binding? it takes the source, the destination and the properties column");
			return error.Driver;
		}
		const kind = db.ask.only(where, "destination_type") orelse "queue";
		const path = try std.fmt.allocPrint(arena, "/api/bindings/{s}/e/{s}/{s}/{s}/{s}", .{
			try address.escaped(arena, self.vhost),
			try address.escaped(arena, source),
			if (std.mem.startsWith(u8, kind, "e")) "e" else "q",
			try address.escaped(arena, destination),
			try address.escaped(arena, properties),
		});
		const response = try self.call(arena, .{ .method = "DELETE", .path = path });
		if (!response.ok()) {
			return self.fail(response);
		}
	}

	/// What a request comes to as a console line, which is also what a dump is
	/// made of - so what comes out of a dump goes back in.
	pub fn wording(self: *Db, allocator: std.mem.Allocator, request: db.Request) db.Error![]u8 {
		var out: List = .empty;
		errdefer out.deinit(allocator);
		switch (request) {
			.select => |value| {
				const table = api.find(value.table.name) orelse {
					try out.print(allocator, "GET /api/{s}", .{value.table.name});
					return out.toOwnedSlice(allocator);
				};
				var scratch = std.heap.ArenaAllocator.init(allocator);
				defer scratch.deinit();
				try out.print(allocator, "GET {s}", .{try self.pathOf(scratch.allocator(), table)});
				if (table.paged and !value.count) {
					const limit = if (value.limit != 0) value.limit else PAGE;
					try out.print(allocator, "?page={d}&page_size={d}", .{ value.offset / limit + 1, limit });
				}
			},
			.change => |value| {
				const name = db.ask.only(value.where, "name") orelse
					flat(db.ask.valueOf(value.cells, "name")) orelse "";
				const kind = if (std.mem.eql(u8, value.table.name, "queues"))
					"QUEUE"
				else if (std.mem.eql(u8, value.table.name, "exchanges"))
					"EXCHANGE"
				else
					"";
				switch (value.kind) {
					.delete => {
						if (std.mem.eql(u8, value.table.name, "bindings")) {
							try out.print(allocator, "UNBIND {s} {s} {s}", .{
								db.ask.only(value.where, "source") orelse "?",
								db.ask.only(value.where, "destination") orelse "?",
								db.ask.only(value.where, "properties") orelse "?",
							});
						} else if (std.mem.eql(u8, value.table.name, "connections")) {
							try out.print(allocator, "CLOSE {s}", .{name});
						} else {
							try out.print(allocator, "DELETE {s} {s}", .{ kind, name });
						}
					},
					.update => try out.appendSlice(allocator, "-- a queue is declared, not altered"),
					.insert => {
						if (std.mem.eql(u8, value.table.name, "bindings")) {
							const source = flat(db.ask.valueOf(value.cells, "source")) orelse "";
							if (source.len == 0) {
								// Every queue is bound to the default exchange by its own name,
								// by the broker and not by anybody who could write it down.
								try out.print(allocator, "-- {s} is bound to the default exchange by the broker", .{
									flat(db.ask.valueOf(value.cells, "destination")) orelse "?",
								});
							} else {
								try out.print(allocator, "BIND {s} {s} {s}", .{
									source,
									flat(db.ask.valueOf(value.cells, "destination")) orelse "?",
									flat(db.ask.valueOf(value.cells, "routing_key")) orelse "",
								});
							}
						} else if (kind.len == 0) {
							try out.print(allocator, "-- {s} are the broker's own, and are not declared", .{value.table.name});
						} else {
							try out.print(allocator, "DECLARE {s} {s} {s}", .{
								kind,
								name,
								flat(db.ask.valueOf(value.cells, "type")) orelse
									if (std.mem.eql(u8, kind, "QUEUE")) "classic" else "direct",
							});
							if (!truthy(flat(db.ask.valueOf(value.cells, "durable")), true)) {
								try out.appendSlice(allocator, " transient");
							}
						}
					},
				}
			},
		}
		return out.toOwnedSlice(allocator);
	}

	// --------------------------------------------------------------- schema

	pub fn inTransaction(_: *Db) bool {
		return false;
	}

	/// The vhosts, the one in use first.
	pub fn schemas(self: *Db, arena: std.mem.Allocator) db.Error![][]const u8 {
		var out: std.ArrayListUnmanaged([]const u8) = .empty;
		const response = try self.call(arena, .{ .path = "/api/vhosts" });
		if (!response.ok()) {
			// A user who may see one vhost and not the list still has that one.
			try out.append(arena, try arena.dupe(u8, self.vhost));
			return out.items;
		}
		const answer = api.page(arena, response.body) catch {
			try out.append(arena, try arena.dupe(u8, self.vhost));
			return out.items;
		};
		for (answer.items) |item| {
			const name = text(api.pick(item, "name")) orelse continue;
			if (std.mem.eql(u8, name, self.vhost)) {
				continue;
			}
			try out.append(arena, try arena.dupe(u8, name));
		}
		try out.insert(arena, 0, try arena.dupe(u8, self.vhost));
		return out.items;
	}

	pub fn objects(self: *Db, arena: std.mem.Allocator, schema: []const u8) db.Error![]db.Object {
		if (schema.len != 0 and !std.mem.eql(u8, schema, self.vhost)) {
			self.vhost = try self.home.allocator().dupe(u8, schema);
			self.relabel();
		}
		var out: std.ArrayListUnmanaged(db.Object) = .empty;
		for (api.TABLES) |table| {
			try out.append(arena, .{
				.schema = self.vhost,
				.name = table.name,
				.kind = .table,
				.internal = table.internal,
			});
		}
		return out.items;
	}

	pub fn columns(_: *Db, arena: std.mem.Allocator, table: db.Table) db.Error![]db.Column {
		var out: std.ArrayListUnmanaged(db.Column) = .empty;
		const found = api.find(table.name) orelse return out.items;
		for (found.columns) |column| {
			var key = false;
			for (found.key) |name| {
				key = key or std.mem.eql(u8, name, column.name);
			}
			try out.append(arena, .{
				.name = column.name,
				.type = if (column.numeric) "number" else "text",
				.pk = key,
				.original = column.name,
			});
		}
		return out.items;
	}

	pub fn indexes(_: *Db, arena: std.mem.Allocator, table: db.Table) db.Error![]db.Index {
		var out: std.ArrayListUnmanaged(db.Index) = .empty;
		const found = api.find(table.name) orelse return out.items;
		var columns_text: List = .empty;
		for (found.key, 0..) |name, i| {
			if (i != 0) {
				try columns_text.appendSlice(arena, ", ");
			}
			try columns_text.appendSlice(arena, name);
		}
		try out.append(arena, .{ .name = "identity", .kind = "PRIMARY", .columns = columns_text.items });
		return out.items;
	}

	pub fn foreignKeys(_: *Db, _: std.mem.Allocator, _: db.Table) db.Error![]db.ForeignKey {
		return &[_]db.ForeignKey{};
	}

	pub fn definition(_: *Db, _: std.mem.Allocator, _: db.Table) db.Error!?[]const u8 {
		return null;
	}

	/// One request, because the broker counts for us.
	pub fn rowCount(self: *Db, table: db.Table) ?i64 {
		const found = api.find(table.name) orelse return null;
		if (!found.paged) {
			return null;
		}
		var scratch = std.heap.ArenaAllocator.init(self.allocator);
		defer scratch.deinit();
		const arena = scratch.allocator();
		const response = self.call(arena, .{
			.path = self.pathOf(arena, found) catch return null,
			.query = "page=1&page_size=1",
		}) catch return null;
		if (!response.ok()) {
			return null;
		}
		const answer = api.page(arena, response.body) catch return null;
		return answer.total;
	}

	pub fn rowKey(_: *Db, arena: std.mem.Allocator, table: db.Table) db.Error!db.RowKey {
		const found = api.find(table.name) orelse return .{};
		var out: std.ArrayListUnmanaged([]const u8) = .empty;
		for (found.key) |name| {
			try out.append(arena, name);
		}
		return .{ .columns = out.items };
	}

	pub fn alterContext(_: *Db, _: std.mem.Allocator, _: db.Table, _: []const db.Column) db.Error!db.AlterContext {
		return .{};
	}

	pub fn settings(self: *Db, arena: std.mem.Allocator) db.Error![]db.Setting {
		var out: std.ArrayListUnmanaged(db.Setting) = .empty;
		const response = self.call(arena, .{ .path = "/api/overview" }) catch null;
		if (response) |answer| {
			if (answer.ok()) {
				if (std.json.parseFromSliceLeaky(Json, arena, answer.body, .{})) |body| {
					const FACTS = [_][2][]const u8{
						.{ "product", "product_name" },
						.{ "version", "rabbitmq_version" },
						.{ "erlang", "erlang_version" },
						.{ "cluster", "cluster_name" },
						.{ "node", "node" },
						.{ "management", "management_version" },
					};
					for (FACTS) |fact| {
						const value = text(api.pick(body, fact[1])) orelse continue;
						try out.append(arena, .{ .label = fact[0], .value = value });
					}
					const COUNTS = [_][2][]const u8{
						.{ "queues", "object_totals.queues" },
						.{ "exchanges", "object_totals.exchanges" },
						.{ "connections", "object_totals.connections" },
						.{ "consumers", "object_totals.consumers" },
						.{ "messages", "queue_totals.messages" },
					};
					for (COUNTS) |count| {
						const value = api.pick(body, count[1]) orelse continue;
						try out.append(arena, .{ .label = count[0], .value = try api.flatten(arena, value) });
					}
				} else |_| {}
			}
		}
		try out.append(arena, .{ .label = "vhost", .value = self.vhost });
		try out.append(arena, .{ .label = "user", .value = self.parts.user });
		try out.append(arena, .{
			.label = "management API",
			.value = try std.fmt.allocPrint(arena, "{s}://{s}:{d}{s}", .{
				if (self.parts.tls) "https" else "http",
				self.parts.host,
				self.parts.port,
				self.parts.prefix,
			}),
		});
		if (self.parts.moved_port) {
			try out.append(arena, .{
				.label = "port",
				.value = "the target named an amqp port; this is the management one",
			});
		}
		try out.append(arena, .{
			.label = "requests made",
			.value = try std.fmt.allocPrint(arena, "{d}", .{self.requests}),
		});
		return out.items;
	}

	pub fn split(_: *Db, arena: std.mem.Allocator, sql: []const u8) db.Error![]db.Statement {
		var out: std.ArrayListUnmanaged(db.Statement) = .empty;
		var lines = std.mem.splitScalar(u8, sql, '\n');
		while (lines.next()) |raw| {
			const line = std.mem.trim(u8, raw, " \t\r");
			if (line.len != 0 and !std.mem.startsWith(u8, line, "--") and !std.mem.startsWith(u8, line, "#")) {
				try out.append(arena, .{ .sql = line });
			}
		}
		return out.items;
	}

	pub fn ddl(_: *Db) db.Ddl {
		return .{ .rabbit = .{} };
	}

	// -------------------------------------------------------------- console

	fn console(self: *Db, line: []const u8) db.Error!Rows {
		var scratch = std.heap.ArenaAllocator.init(self.allocator);
		defer scratch.deinit();
		const arena = scratch.allocator();
		const args = try splitCommand(arena, line);
		if (args.len == 0) {
			return self.oneText("rabbitmq", "");
		}
		const command = args[0];

		if (eql(command, "HELP") or eql(command, "?")) {
			return self.help();
		}
		if (eql(command, "VHOSTS")) {
			var rows = self.newNamed(&.{"vhost"}, &.{false});
			for (try self.schemas(self.replies.allocator())) |name| {
				try rows.add(&.{.{ .text = name }});
			}
			return rows;
		}
		// The listings, by the name of the table they are.
		if (api.find(lower(arena, command) catch command)) |table| {
			var request = db.ask.Select{ .table = .{ .name = table.name }, .limit = PAGE };
			if (args.len > 1) {
				request.where = try arena.dupe(db.ask.Filter, &.{.{ .column = "name", .op = .like, .value = args[1] }});
			}
			const rows = (try self.select(request)) orelse return self.oneText("rabbitmq", "");
			return rows.rabbit;
		}
		if (eql(command, "OVERVIEW")) {
			return self.facts();
		}
		if (eql(command, "DEFINITIONS")) {
			const response = try self.call(self.replies.allocator(), .{
				.path = try std.fmt.allocPrint(arena, "/api/definitions/{s}", .{try address.escaped(arena, self.vhost)}),
			});
			if (!response.ok()) {
				return self.fail(response);
			}
			return self.oneText("definitions", response.body);
		}

		if (args.len < 2) {
			self.complain("{s} needs something to work on - try HELP", .{command});
			return error.Driver;
		}

		if (eql(command, "PEEK") or eql(command, "DRAIN")) {
			const count = if (args.len > 2) std.fmt.parseInt(usize, args[2], 10) catch PEEK else PEEK;
			return self.messages(arena, args[1], count, eql(command, "DRAIN"));
		}
		if (eql(command, "PURGE")) {
			const path = try std.fmt.allocPrint(arena, "{s}/contents", .{try self.itemPath(arena, "queues", args[1])});
			const response = try self.call(arena, .{ .method = "DELETE", .path = path });
			if (!response.ok()) {
				return self.fail(response);
			}
			return self.oneText("purged", args[1]);
		}
		if (eql(command, "PUBLISH")) {
			if (args.len < 4) {
				self.remember("PUBLISH exchange routing_key \"the message\" - an empty exchange is the default one");
				return error.Driver;
			}
			return self.publish(arena, args[1], args[2], args[3]);
		}
		if (eql(command, "DECLARE")) {
			if (args.len < 3) {
				self.remember("DECLARE QUEUE name [classic|quorum] [transient], or DECLARE EXCHANGE name [direct|topic|fanout|headers]");
				return error.Driver;
			}
			// The words after the name are a kind and whether it survives a restart,
			// in whichever order they were written.
			var durable = true;
			var kind: []const u8 = "";
			for (args[3..]) |word| {
				if (eql(word, "transient")) {
					durable = false;
				} else if (eql(word, "durable")) {
					durable = true;
				} else {
					kind = word;
				}
			}
			if (eql(args[1], "QUEUE")) {
				try self.declareQueue(arena, args[2], .{
					.durable = durable,
					.kind = if (kind.len != 0) kind else "classic",
				});
				return self.oneText("declared", args[2]);
			}
			if (eql(args[1], "EXCHANGE")) {
				try self.declareExchange(arena, args[2], .{
					.kind = if (kind.len != 0) kind else "direct",
					.durable = durable,
				});
				return self.oneText("declared", args[2]);
			}
			self.remember("DECLARE what? a QUEUE or an EXCHANGE");
			return error.Driver;
		}
		if (eql(command, "BIND")) {
			if (args.len < 3) {
				self.remember("BIND exchange queue [routing_key]");
				return error.Driver;
			}
			try self.bind(arena, args[1], args[2], "queue", if (args.len > 3) args[3] else "");
			return self.oneText("bound", args[2]);
		}
		if (eql(command, "UNBIND")) {
			if (args.len < 4) {
				self.remember("UNBIND exchange queue properties - the properties column of the binding");
				return error.Driver;
			}
			try self.unbind(arena, &.{
				.{ .column = "source", .value = args[1] },
				.{ .column = "destination", .value = args[2] },
				.{ .column = "properties", .value = args[3] },
			});
			return self.oneText("unbound", args[2]);
		}
		if (eql(command, "DELETE")) {
			if (args.len < 3) {
				self.remember("DELETE QUEUE name, or DELETE EXCHANGE name");
				return error.Driver;
			}
			const kind = if (eql(args[1], "QUEUE")) "queues" else if (eql(args[1], "EXCHANGE")) "exchanges" else {
				self.remember("DELETE what? a QUEUE or an EXCHANGE");
				return error.Driver;
			};
			const response = try self.call(arena, .{
				.method = "DELETE",
				.path = try self.itemPath(arena, kind, args[2]),
			});
			if (!response.ok()) {
				return self.fail(response);
			}
			return self.oneText("deleted", args[2]);
		}
		if (eql(command, "CLOSE")) {
			const response = try self.call(arena, .{
				.method = "DELETE",
				.path = try std.fmt.allocPrint(arena, "/api/connections/{s}", .{try address.escaped(arena, args[1])}),
			});
			if (!response.ok()) {
				return self.fail(response);
			}
			return self.oneText("closed", args[1]);
		}
		self.complain("no such command: {s} - try HELP", .{command});
		return error.Driver;
	}

	/// Messages off a queue. Both ways round are destructive in their own way and
	/// the columns say which happened: `PEEK` puts them back, which reorders the
	/// queue and marks them redelivered, and `DRAIN` does not put them back at all.
	fn messages(self: *Db, arena: std.mem.Allocator, queue: []const u8, count: usize, drain: bool) db.Error!Rows {
		var body: List = .empty;
		try body.print(arena, "{{\"count\":{d},\"ackmode\":\"{s}\",\"encoding\":\"auto\",\"truncate\":{d}}}", .{
			count,
			if (drain) "ack_requeue_false" else "reject_requeue_true",
			TRUNCATE,
		});
		const path = try std.fmt.allocPrint(arena, "{s}/get", .{try self.itemPath(arena, "queues", queue)});
		const replies = self.replies.allocator();
		const response = try self.call(replies, .{ .method = "POST", .path = path, .body = body.items });
		if (!response.ok()) {
			return self.fail(response);
		}
		const answer = api.page(replies, response.body) catch {
			self.remember("the broker answered something that is not a list of messages");
			return error.Driver;
		};
		var rows = self.newNamed(
			&.{ "routing_key", "size", "redelivered", "properties", "payload" },
			&.{ false, true, false, false, false },
		);
		for (answer.items) |item| {
			const what = try api.payload(replies, item);
			try rows.add(&.{
				.{ .text = text(api.pick(item, "routing_key")) orelse "" },
				.{ .number = @intCast(what.bytes.len) },
				.{ .text = if (drain) "taken" else "put back, redelivered" },
				.{ .text = try api.flatten(replies, api.pick(item, "properties") orelse Json{ .null = {} }) },
				if (what.binary) .{ .blob = what.bytes } else .{ .text = what.bytes },
			});
		}
		return rows;
	}

	fn publish(self: *Db, arena: std.mem.Allocator, exchange: []const u8, routing_key: []const u8, payload: []const u8) db.Error!Rows {
		var body: List = .empty;
		try body.appendSlice(arena, "{\"properties\":{},\"routing_key\":");
		try quote(&body, arena, routing_key);
		try body.appendSlice(arena, ",\"payload\":");
		try quote(&body, arena, payload);
		try body.appendSlice(arena, ",\"payload_encoding\":\"string\"}");
		// The default exchange has no name, and routes by the queue's own name.
		const named = if (std.mem.eql(u8, exchange, "\"\"") or std.mem.eql(u8, exchange, "-")) "" else exchange;
		const path = try std.fmt.allocPrint(arena, "{s}/publish", .{try self.itemPath(arena, "exchanges", named)});
		const response = try self.call(arena, .{ .method = "POST", .path = path, .body = body.items });
		if (!response.ok()) {
			return self.fail(response);
		}
		// The broker says whether anything was listening, which is the difference
		// between a message queued and a message dropped on the floor.
		var routed = false;
		if (std.json.parseFromSliceLeaky(Json, arena, response.body, .{})) |answer| {
			routed = switch (api.pick(answer, "routed") orelse Json{ .null = {} }) {
				.bool => |flag| flag,
				else => false,
			};
		} else |_| {}
		var rows = self.newNamed(&.{ "published", "routed" }, &.{ false, false });
		try rows.add(&.{
			.{ .text = try self.replies.allocator().dupe(u8, routing_key) },
			.{ .text = if (routed) "yes" else "no - nothing is bound for that key" },
		});
		return rows;
	}

	fn facts(self: *Db) db.Error!Rows {
		var rows = self.newNamed(&.{ "fact", "value" }, &.{ false, false });
		for (try self.settings(self.replies.allocator())) |setting| {
			try rows.add(&.{ .{ .text = setting.label }, .{ .text = setting.value } });
		}
		return rows;
	}

	fn help(self: *Db) db.Error!Rows {
		var rows = self.newNamed(&.{ "command", "what it does" }, &.{ false, false });
		const LINES = [_][2][]const u8{
			.{ "QUEUES [name]", "the queues, filtered by what a name contains" },
			.{ "EXCHANGES, BINDINGS, CONSUMERS", "the rest of the topology" },
			.{ "CONNECTIONS, CHANNELS, NODES", "what the broker is doing" },
			.{ "VHOSTS", "the vhosts this user can see" },
			.{ "OVERVIEW", "what the broker says about itself" },
			.{ "DEFINITIONS", "the whole vhost as the broker exports it" },
			.{ "PEEK queue [n]", "messages, put back afterwards - order changes, redelivered is set" },
			.{ "DRAIN queue [n]", "messages, kept off the queue for good" },
			.{ "PUBLISH exchange key \"text\"", "send one; - as the exchange is the default one" },
			.{ "PURGE queue", "throw away everything in it" },
			.{ "DECLARE QUEUE name [classic|quorum] [transient]", "" },
			.{ "DECLARE EXCHANGE name [direct|topic|fanout]", "" },
			.{ "BIND exchange queue [key]", "and UNBIND exchange queue properties" },
			.{ "DELETE QUEUE|EXCHANGE name", "" },
			.{ "CLOSE connection", "hang up on a client" },
		};
		for (LINES) |line| {
			try rows.add(&.{ .{ .text = line[0] }, .{ .text = line[1] } });
		}
		return rows;
	}

	// ----------------------------------------------------------------- rows

	fn newRows(self: *Db, table: api.Table) Rows {
		var names: std.ArrayListUnmanaged([]const u8) = .empty;
		var numeric: std.ArrayListUnmanaged(bool) = .empty;
		const arena = self.replies.allocator();
		for (table.columns) |column| {
			names.append(arena, column.name) catch {};
			numeric.append(arena, column.numeric) catch {};
		}
		return .{
			.owner = self,
			.names = names.items,
			.numeric = numeric.items,
			.table = table.name,
		};
	}

	fn newNamed(self: *Db, names: []const []const u8, numeric: []const bool) Rows {
		return .{ .owner = self, .names = names, .numeric = numeric };
	}

	fn oneColumn(self: *Db, name: []const u8, numeric: bool) db.Error!Rows {
		const arena = self.replies.allocator();
		return .{
			.owner = self,
			.names = try arena.dupe([]const u8, &.{try arena.dupe(u8, name)}),
			.numeric = try arena.dupe(bool, &.{numeric}),
		};
	}

	fn oneText(self: *Db, name: []const u8, value: []const u8) db.Error!Rows {
		var rows = try self.oneColumn(name, false);
		try rows.add(&.{.{ .text = try self.replies.allocator().dupe(u8, value) }});
		return rows;
	}

	fn oneNumber(self: *Db, name: []const u8, number: i64) db.Error!Rows {
		var rows = try self.oneColumn(name, true);
		try rows.add(&.{.{ .number = number }});
		return rows;
	}
};

// ------------------------------------------------------------------ helpers

/// `Basic dXNlcjpwYXNz`, which is all the authentication the management API has.
fn basic(arena: std.mem.Allocator, user: []const u8, password: []const u8) ![]const u8 {
	const pair = try std.fmt.allocPrint(arena, "{s}:{s}", .{ user, password });
	const encoder = std.base64.standard.Encoder;
	const room = try arena.alloc(u8, encoder.calcSize(pair.len));
	return std.fmt.allocPrint(arena, "Basic {s}", .{encoder.encode(room, pair)});
}

/// A JSON string, escaped as JSON wants it.
fn quote(out: *List, arena: std.mem.Allocator, value: []const u8) !void {
	try out.append(arena, '"');
	for (value) |byte| {
		switch (byte) {
			'"' => try out.appendSlice(arena, "\\\""),
			'\\' => try out.appendSlice(arena, "\\\\"),
			'\n' => try out.appendSlice(arena, "\\n"),
			'\r' => try out.appendSlice(arena, "\\r"),
			'\t' => try out.appendSlice(arena, "\\t"),
			else => {
				if (byte < 0x20) {
					try out.print(arena, "\\u{x:0>4}", .{byte});
				} else {
					try out.append(arena, byte);
				}
			},
		}
	}
	try out.append(arena, '"');
}

fn text(value: ?Json) ?[]const u8 {
	const found = value orelse return null;
	return switch (found) {
		.string => |string| string,
		else => null,
	};
}

/// Where a column's value lives in the JSON, for the broker's own `sort`.
fn columnFrom(table: api.Table, name: []const u8) ?[]const u8 {
	for (table.columns) |column| {
		if (std.mem.eql(u8, column.name, name)) {
			return column.from;
		}
	}
	return null;
}

fn eql(left: []const u8, right: []const u8) bool {
	return std.ascii.eqlIgnoreCase(left, right);
}

fn lower(arena: std.mem.Allocator, value: []const u8) ![]const u8 {
	const room = try arena.alloc(u8, value.len);
	return std.ascii.lowerString(room, value);
}

fn truthy(value: ?[]const u8, unset: bool) bool {
	const given = value orelse return unset;
	if (given.len == 0) {
		return unset;
	}
	return eql(given, "true") or eql(given, "yes") or eql(given, "1") or eql(given, "durable");
}

fn flat(value: ??[]const u8) ?[]const u8 {
	const inner = value orelse return null;
	return inner orelse null;
}

/// A command line as a list of arguments, with quotes honoured so a message may
/// contain spaces.
fn splitCommand(arena: std.mem.Allocator, line: []const u8) ![]const []const u8 {
	var out: std.ArrayListUnmanaged([]const u8) = .empty;
	var at: usize = 0;
	while (at < line.len) {
		while (at < line.len and (line[at] == ' ' or line[at] == '\t')) : (at += 1) {}
		if (at >= line.len) {
			break;
		}
		if (line[at] == '"' or line[at] == '\'') {
			const quote_char = line[at];
			at += 1;
			const start = at;
			while (at < line.len and line[at] != quote_char) : (at += 1) {}
			try out.append(arena, line[start..at]);
			if (at < line.len) {
				at += 1;
			}
			continue;
		}
		const start = at;
		while (at < line.len and line[at] != ' ' and line[at] != '\t') : (at += 1) {}
		try out.append(arena, line[start..at]);
	}
	return out.items;
}

// ------------------------------------------------------------------- cursor

pub const Value = union(enum) {
	nil: void,
	text: []const u8,
	blob: []const u8,
	number: i64,
};

pub const Rows = struct {
	owner: *Db,
	names: []const []const u8 = &.{},
	numeric: []const bool = &.{},
	rows: std.ArrayListUnmanaged([]const Value) = .empty,
	table: []const u8 = "",
	at: usize = 0,
	started: bool = false,

	fn add(self: *Rows, values: []const Value) db.Error!void {
		const arena = self.owner.replies.allocator();
		try self.rows.append(arena, try arena.dupe(Value, values));
	}

	/// One row out of one JSON object, by the table's columns.
	fn addJson(self: *Rows, table: api.Table, item: Json) db.Error!void {
		const arena = self.owner.replies.allocator();
		var values: std.ArrayListUnmanaged(Value) = .empty;
		for (table.columns) |column| {
			const found = api.pick(item, column.from) orelse {
				try values.append(arena, .{ .nil = {} });
				continue;
			};
			try values.append(arena, switch (found) {
				.integer => |number| .{ .number = number },
				else => .{ .text = try api.flatten(arena, found) },
			});
		}
		try self.add(values.items);
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
			.text => |value_text| .{ .text = value_text },
			.blob => |bytes| .{ .blob = bytes },
		};
	}

	pub fn sourceTable(self: *Rows, _: usize) []const u8 {
		return self.table;
	}

	pub fn sourceColumn(self: *Rows, at: usize) []const u8 {
		return if (self.table.len != 0) self.name(at) else "";
	}

	pub fn isNumeric(self: *Rows, at: usize) bool {
		return at < self.numeric.len and self.numeric[at];
	}

	pub fn affected(_: *Rows) i64 {
		return 0;
	}
};

// ---------------------------------------------------------------------- DDL

/// A broker has no schema to define: what there is - a queue, an exchange, a
/// binding - is declared, and the console does that.
pub const Ddl = struct {
	pub fn types(_: Ddl) []const []const u8 {
		return &[_][]const u8{ "classic", "quorum", "stream", "direct", "topic", "fanout", "headers" };
	}

	fn refuse(out: *List, a: std.mem.Allocator, what: []const u8) !void {
		try out.appendSlice(a, "-- a broker has no ");
		try out.appendSlice(a, what);
		try out.appendSlice(a, ", so nothing was done\n");
	}

	pub fn createTable(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table, _: []const db.Column, _: []const db.ForeignKey) !void {
		try refuse(out, a, "tables to create - the tables are fixed; declare a queue with DECLARE QUEUE");
	}

	pub fn alterTable(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table, _: []const u8, _: []const db.Column, _: db.AlterContext) !void {
		try refuse(out, a, "columns to alter");
	}

	pub fn addForeignKey(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table, _: db.ForeignKey, _: db.AlterContext) !void {
		try refuse(out, a, "foreign keys - a binding is the nearest thing, and BIND makes one");
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
		try refuse(out, a, "table to drop - DELETE QUEUE removes one queue, which is what dropping would mean");
	}

	pub fn truncate(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table) !void {
		try refuse(out, a, "way to empty a listing - PURGE empties one queue");
	}
};

// ------------------------------------------------------------------- tests

const testing = std.testing;

test "a command line comes apart the way a shell would do it" {
	var scratch = std.heap.ArenaAllocator.init(testing.allocator);
	defer scratch.deinit();
	const arena = scratch.allocator();

	const args = try splitCommand(arena, "PUBLISH orders new.order \"ahoj, svete\"");
	try testing.expectEqual(@as(usize, 4), args.len);
	try testing.expectEqualStrings("PUBLISH", args[0]);
	try testing.expectEqualStrings("ahoj, svete", args[3]);
	try testing.expectEqual(@as(usize, 0), (try splitCommand(arena, "  \t ")).len);
}

test "the authorization header is the one the API wants" {
	var scratch = std.heap.ArenaAllocator.init(testing.allocator);
	defer scratch.deinit();
	// RFC 7617's own example, so this is checked against something other than
	// itself.
	try testing.expectEqualStrings(
		"Basic QWxhZGRpbjpvcGVuIHNlc2FtZQ==",
		try basic(scratch.allocator(), "Aladdin", "open sesame"),
	);
	try testing.expectEqualStrings("Basic Z3Vlc3Q6Z3Vlc3Q=", try basic(scratch.allocator(), "guest", "guest"));
}

test "a message body travels as JSON, whatever is in it" {
	var scratch = std.heap.ArenaAllocator.init(testing.allocator);
	defer scratch.deinit();
	const arena = scratch.allocator();

	var out: List = .empty;
	try quote(&out, arena, "a \"quoted\" \\ line\nand another\t");
	try testing.expectEqualStrings("\"a \\\"quoted\\\" \\\\ line\\nand another\\t\"", out.items);

	var control: List = .empty;
	try quote(&control, arena, &.{ 'a', 0x01, 'b' });
	try testing.expectEqualStrings("\"a\\u0001b\"", control.items);
}

test "durability is what was asked for, or true when nobody asked" {
	try testing.expect(truthy(null, true));
	try testing.expect(!truthy(null, false));
	try testing.expect(truthy("true", false));
	try testing.expect(truthy("yes", false));
	try testing.expect(!truthy("false", true));
	try testing.expect(!truthy("transient", true));
	// An empty cell is not an answer: it means the form was left alone.
	try testing.expect(truthy("", true));
}

test "a column's name and the JSON field behind it are not always the same" {
	const queues = api.find("queues").?;
	try testing.expectEqualStrings("messages_ready", columnFrom(queues, "ready").?);
	try testing.expectEqualStrings("name", columnFrom(queues, "name").?);
	try testing.expect(columnFrom(queues, "nothing") == null);
}

//! The Azure Blob driver: containers as tables, blobs as rows.
//!
//! The same shape as the S3 driver, because the service has the same shape: a
//! flat namespace of names with bytes behind them, listed a page at a time and
//! addressed exactly. What differs is the signature, the names of the elements in
//! the XML, and where the account goes - in the host on Azure itself, in the path
//! on the emulator and behind most proxies. Everything else - the HTTP client,
//! the XML reader, the grid, the console - is shared.
//!
//! **A container is a table and a blob is a row**, with `name`, `size`,
//! `modified`, `etag`, `type` and `tier` for columns. Names come back sorted, a
//! `WHERE name LIKE 'a/b%'` is the listing's own prefix, and paging is by marker,
//! which only goes forwards - so the markers are kept and going back a page costs
//! nothing.
//!
//! **The body of a blob is not in the grid**, for the reason it is not in the S3
//! one: a listing that fetched every blob to draw a screen would download the
//! container. `GET` in the editor brings one back as a value.
//!
//! The parts with no connection in them are files of their own:
//!
//! * `azure/sign.zig` - Shared Key, against signatures computed elsewhere.
//! * `azure/target.zig` - the three ways to write a target, the connection string
//!   the portal hands out included.

const std = @import("std");
const db = @import("db.zig");
const typed = @import("typed.zig");
const http = @import("http.zig");

pub const xml = @import("xml.zig");
pub const sign = @import("azure/sign.zig");
pub const address = @import("azure/target.zig");

const List = db.List;

comptime {
	_ = sign;
	_ = address;
}

pub const owns = address.owns;
pub const parse = address.parse;
pub const Parts = address.Parts;

pub const NAME = "name";
pub const SIZE = "size";
pub const MODIFIED = "modified";
pub const ETAG = "etag";
pub const TYPE = "type";
pub const TIER = "tier";

const COLUMNS = [_][]const u8{ NAME, SIZE, MODIFIED, ETAG, TYPE, TIER };
const NUMERIC = [_]bool{ false, true, false, false, false, false };

/// How many blobs one page of the grid asks for when nobody said.
const PAGE: usize = 200;
/// How many pages counting will walk before answering "who knows".
const COUNT_PAGES: usize = 20;
/// How much of a blob the console will bring back in one go.
const GET_LIMIT: usize = 32 << 20;
/// How much of a blob one range asks for while it is being copied.
const RANGE: usize = 8 << 20;
/// How large a blob this will send. One request carries the whole thing, so
/// this is a real ceiling until block uploads are written - and it says so
/// rather than failing halfway.
const UPLOAD_LIMIT: usize = 256 << 20;

pub const Db = struct {
	allocator: std.mem.Allocator,
	home: std.heap.ArenaAllocator,
	parts: Parts = .{},
	client: ?http.Client = null,
	label: List = .empty,
	version_text: List = .empty,
	last_error: List = .empty,
	progress: ?db.Progress = null,
	requests: usize = 0,
	replies: std.heap.ArenaAllocator,
	pages: Pages,

	pub fn open(allocator: std.mem.Allocator, target: []const u8, report: *List) !*Db {
		const self = try allocator.create(Db);
		self.* = .{
			.allocator = allocator,
			.home = std.heap.ArenaAllocator.init(allocator),
			.replies = std.heap.ArenaAllocator.init(allocator),
			.pages = .{ .arena = std.heap.ArenaAllocator.init(allocator) },
		};
		errdefer self.close();

		const home = self.home.allocator();
		self.parts = address.parse(home, target) catch {
			try report.appendSlice(allocator, "that is not an azure blob target");
			return error.Driver;
		};
		address.resolve(home, &self.parts) catch {};
		if (self.parts.account.len == 0) {
			try report.appendSlice(allocator, "which account? a target says azure://account:key@container");
			return error.Driver;
		}
		if (self.parts.key.len != 0 and self.parts.sas.len != 0) {
			self.parts.sas = "";
		}
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

		// One request before anything else, so a wrong key says so here.
		const response = (if (self.parts.container.len != 0)
			self.call(arena, .{
				.container = self.parts.container,
				.query = &.{
					.{ .name = "restype", .value = "container" },
					.{ .name = "comp", .value = "list" },
					.{ .name = "maxresults", .value = "1" },
				},
			})
		else
			self.call(arena, .{ .query = &.{.{ .name = "comp", .value = "list" }} })) catch {
			try report.appendSlice(allocator, self.message());
			return error.Driver;
		};
		if (!response.ok()) {
			const why = self.fail(response);
			try report.appendSlice(allocator, self.message());
			return why;
		}
		try self.version_text.appendSlice(allocator, serverName(response.get("server")));
		return self;
	}

	pub fn close(self: *Db) void {
		if (self.client) |*client| {
			client.deinit();
		}
		self.label.deinit(self.allocator);
		self.version_text.deinit(self.allocator);
		self.last_error.deinit(self.allocator);
		self.pages.arena.deinit();
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
			.schemas = false,
			.databases = false,
			.label = "Azure",
			.speaks_sql = false,
			// The same as S3: a list of names without their bytes is not a dump.
			.dumps_rows = false,
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
		if (self.parts.container.len != 0) {
			self.label.print(self.allocator, "{s}/{s}", .{ self.parts.account, self.parts.container }) catch {};
		} else {
			self.label.appendSlice(self.allocator, self.parts.account) catch {};
		}
	}

	fn remember(self: *Db, text: []const u8) void {
		self.last_error.clearRetainingCapacity();
		self.last_error.appendSlice(self.allocator, text) catch {};
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
		container: []const u8 = "",
		blob: []const u8 = "",
		query: []const sign.Param = &.{},
		headers: []const sign.Header = &.{},
		body: []const u8 = "",
		limit: usize = http.BODY_LIMIT,
	};

	fn call(self: *Db, arena: std.mem.Allocator, request: Call) db.Error!http.Response {
		const client = &(self.client orelse return error.Driver);
		const path = try self.pathOf(arena, request.container, request.blob);

		// A body of nothing is signed as an *empty* slot rather than as a zero - and
		// the header still has to be there. Signing "0" is a 403 and leaving the
		// header out is a 400; the server was asked which it wanted.
		const length = if (request.body.len != 0)
			try std.fmt.allocPrint(arena, "{d}", .{request.body.len})
		else
			"";

		var headers: std.ArrayListUnmanaged(http.Header) = .empty;
		if (request.body.len == 0 and std.mem.eql(u8, request.method, "PUT")) {
			try headers.append(arena, .{ .name = "Content-Length", .value = "0" });
		}
		var params: List = .empty;
		for (request.query, 0..) |param, i| {
			try params.print(arena, "{s}{s}={s}", .{ if (i == 0) "" else "&", param.name, param.value });
		}

		if (self.parts.sas.len != 0) {
			// A shared access signature is the whole of the authentication and
			// travels in the query, so nothing here is signed.
			try params.print(arena, "{s}{s}", .{ if (params.items.len == 0) "" else "&", self.parts.sas });
			try headers.append(arena, .{ .name = "x-ms-version", .value = sign.VERSION });
		} else if (self.parts.key.len != 0) {
			const stamp = sign.now();
			const signed = sign.sign(arena, self.parts.account, self.parts.key, .{
				.method = request.method,
				.path = path,
				.query = request.query,
				.headers = request.headers,
				.length = length,
				.content_type = contentTypeOf(request.headers),
			}, stamp) catch {
				self.remember("the request could not be signed - is the account key the base64 one from the portal?");
				return error.Driver;
			};
			try headers.append(arena, .{ .name = "x-ms-date", .value = try arena.dupe(u8, stamp.text()) });
			try headers.append(arena, .{ .name = "x-ms-version", .value = sign.VERSION });
			try headers.append(arena, .{ .name = "Authorization", .value = signed.authorization });
		} else {
			try headers.append(arena, .{ .name = "x-ms-version", .value = sign.VERSION });
		}
		for (request.headers) |header| {
			try headers.append(arena, .{ .name = header.name, .value = header.value });
		}

		const target = if (params.items.len != 0)
			try std.fmt.allocPrint(arena, "{s}?{s}", .{ path, params.items })
		else
			path;

		self.requests += 1;
		return client.send(arena, .{
			.method = request.method,
			.target = target,
			.headers = headers.items,
			.body = request.body,
			.limit = request.limit,
		}) catch |err| {
			switch (err) {
				error.GivenUp => self.remember("given up on"),
				error.TooLarge => self.complain("that blob is larger than the {d} MB this will hold", .{request.limit >> 20}),
				error.Malformed => self.complain("{s} answered something that is not HTTP", .{self.parts.host}),
				else => {
					const why = client.message();
					if (why.len != 0) {
						self.remember(why);
					} else {
						self.complain("the connection to {s} is gone", .{self.parts.host});
					}
				},
			}
			return error.Driver;
		};
	}

	/// `/account/container/blob` where the account lives in the path, and
	/// `/container/blob` where it lives in the host.
	fn pathOf(self: *Db, arena: std.mem.Allocator, container: []const u8, blob: []const u8) db.Error![]const u8 {
		var out: List = .empty;
		if (self.parts.path_style) {
			try out.print(arena, "/{s}", .{self.parts.account});
		}
		if (container.len != 0) {
			try out.print(arena, "/{s}", .{container});
			if (blob.len != 0) {
				try out.print(arena, "/{s}", .{try sign.escapePath(arena, blob)});
			}
		}
		if (out.items.len == 0) {
			try out.append(arena, '/');
		}
		return out.items;
	}

	/// The URL of a blob on this account, which a copy names in a header.
	fn urlOf(self: *Db, arena: std.mem.Allocator, container: []const u8, blob: []const u8) db.Error![]const u8 {
		const host = if (self.parts.port == http.defaultPort(self.parts.tls))
			try arena.dupe(u8, self.parts.host)
		else
			try std.fmt.allocPrint(arena, "{s}:{d}", .{ self.parts.host, self.parts.port });
		return std.fmt.allocPrint(arena, "{s}://{s}{s}", .{
			if (self.parts.tls) "https" else "http",
			host,
			try self.pathOf(arena, container, blob),
		});
	}

	fn fail(self: *Db, response: http.Response) db.Error {
		const code = response.get("x-ms-error-code") orelse xml.find(response.body, "Code");
		const detail = xml.find(response.body, "Message");
		if (code) |name| {
			// Azure's Message carries the request id on a line of its own, which is
			// for a support ticket and not for a status bar.
			const first = detail orelse "";
			const cut = std.mem.indexOfScalar(u8, first, '\n') orelse first.len;
			self.complain("{s}{s}{s}", .{
				name,
				if (cut != 0) ": " else "",
				first[0..cut],
			});
		} else if (response.status == 404) {
			self.remember("there is nothing there");
		} else if (response.status == 403) {
			self.remember("the account key was not accepted");
		} else {
			self.complain("the server answered {d} {s}", .{ response.status, response.reason });
		}
		return error.Driver;
	}

	// -------------------------------------------------------------- listing

	const Entry = struct {
		name: []const u8 = "",
		size: i64 = 0,
		modified: []const u8 = "",
		etag: []const u8 = "",
		kind: []const u8 = "",
		tier: []const u8 = "",
	};

	const Listing = struct {
		entries: []const Entry = &.{},
		/// The prefixes one level down, which is what a container has instead of
		/// directories. Only filled in when the listing asked for a delimiter.
		folders: []const []const u8 = &.{},
		/// What to ask for to get the next page, or null when this was the last.
		next: ?[]const u8 = null,
	};

	fn list(
		self: *Db,
		arena: std.mem.Allocator,
		container: []const u8,
		prefix: []const u8,
		marker: []const u8,
		limit: usize,
	) db.Error!Listing {
		return self.listPage(arena, container, prefix, marker, limit, false);
	}

	/// `folded` asks Azure to stop at each slash and report what is below as a
	/// prefix. The grid wants every blob, because a container is one flat table
	/// there; the file manager wants one level, which is what a directory is.
	fn listPage(
		self: *Db,
		arena: std.mem.Allocator,
		container: []const u8,
		prefix: []const u8,
		marker: []const u8,
		limit: usize,
		folded: bool,
	) db.Error!Listing {
		var params: std.ArrayListUnmanaged(sign.Param) = .empty;
		try params.append(arena, .{ .name = "restype", .value = "container" });
		try params.append(arena, .{ .name = "comp", .value = "list" });
		try params.append(arena, .{
			.name = "maxresults",
			.value = try std.fmt.allocPrint(arena, "{d}", .{limit}),
		});
		if (prefix.len != 0) {
			try params.append(arena, .{ .name = "prefix", .value = prefix });
		}
		if (marker.len != 0) {
			try params.append(arena, .{ .name = "marker", .value = marker });
		}
		if (folded) {
			// A slash, not `%2F`. What goes in the query is what gets signed, and
			// the server signs what it decoded - so a value escaped here is signed
			// escaped and checked unescaped, and every folded listing came back
			// saying the signature was wrong. A slash is legal in a query as it is.
			try params.append(arena, .{ .name = "delimiter", .value = "/" });
		}
		const response = try self.call(arena, .{ .container = container, .query = params.items });
		if (!response.ok()) {
			return self.fail(response);
		}
		return parseListing(arena, response.body);
	}

	/// Where a page starts, for a listing that only goes forwards.
	fn markerFor(
		self: *Db,
		container: []const u8,
		prefix: []const u8,
		size: usize,
		page: usize,
	) db.Error!?[]const u8 {
		if (!self.pages.matches(container, prefix, size)) {
			try self.pages.restart(container, prefix, size);
		}
		while (self.pages.markers.items.len <= page) {
			if (self.pages.ended) {
				return null;
			}
			var scratch = std.heap.ArenaAllocator.init(self.allocator);
			defer scratch.deinit();
			const last = self.pages.markers.items[self.pages.markers.items.len - 1];
			const walked = try self.list(scratch.allocator(), container, prefix, last, size);
			const next = walked.next orelse {
				self.pages.ended = true;
				return null;
			};
			const kept = self.pages.arena.allocator();
			try self.pages.markers.append(kept, try kept.dupe(u8, next));
		}
		return self.pages.markers.items[page];
	}

	// ------------------------------------------------------- the interface

	pub fn exec(self: *Db, sql: []const u8) db.Error!void {
		var rows = (try self.query(sql, null)) orelse return;
		rows.close();
	}

	pub fn query(self: *Db, sql: []const u8, rest: ?*[]const u8) db.Error!?db.Rows {
		if (rest) |out| {
			out.* = sql[sql.len..];
		}
		const trimmed = std.mem.trim(u8, sql, " \t\r\n;");
		if (trimmed.len == 0) {
			return null;
		}
		self.begin();
		return .{ .azure = try self.console(trimmed) };
	}

	pub fn select(self: *Db, request: db.ask.Select) db.Error!?db.Rows {
		self.begin();
		const container = if (request.table.name.len != 0) request.table.name else self.parts.container;
		if (container.len == 0) {
			self.remember("which container? name one in the target, or pick one from the list");
			return error.Driver;
		}
		if (request.where_text.len != 0) {
			self.remember("a raw WHERE is SQL - Azure filters by name prefix only, with name LIKE 'a/b%'");
			return error.Driver;
		}
		if (request.order.len != 0 and !std.mem.eql(u8, request.order, NAME)) {
			self.complain("Azure gives back names in order and cannot sort by {s}", .{request.order});
			return error.Driver;
		}
		if (request.descending) {
			self.remember("Azure lists names in order and cannot reverse them");
			return error.Driver;
		}

		const arena = self.replies.allocator();
		const wanted = try self.whereOf(arena, request.where);

		if (wanted.exact) |name| {
			var rows = self.newRows(container);
			const response = try self.call(arena, .{ .method = "HEAD", .container = container, .blob = name });
			if (response.status == 404) {
				return .{ .azure = if (request.count) try self.oneNumber("blobs", 0) else rows };
			}
			if (!response.ok()) {
				return self.fail(response);
			}
			if (request.count) {
				return .{ .azure = try self.oneNumber("blobs", 1) };
			}
			try rows.add(&.{
				.{ .text = name },
				.{ .number = std.fmt.parseInt(i64, response.get("content-length") orelse "0", 10) catch 0 },
				.{ .text = response.get("last-modified") orelse "" },
				.{ .text = trimQuotes(response.get("etag") orelse "") },
				.{ .text = response.get("x-ms-blob-type") orelse "" },
				.{ .text = response.get("x-ms-access-tier") orelse "" },
			});
			return .{ .azure = rows };
		}

		const limit = if (request.limit != 0) request.limit else PAGE;
		if (request.count) {
			return .{ .azure = try self.counting(container, wanted.prefix) };
		}

		const page = request.offset / limit;
		const marker = (try self.markerFor(container, wanted.prefix, limit, page)) orelse
			return .{ .azure = self.newRows(container) };
		const listing = try self.list(arena, container, wanted.prefix, marker, limit);
		var rows = self.newRows(container);
		for (listing.entries) |entry| {
			try rows.add(&.{
				.{ .text = entry.name },
				.{ .number = entry.size },
				.{ .text = entry.modified },
				.{ .text = entry.etag },
				.{ .text = entry.kind },
				.{ .text = entry.tier },
			});
		}
		return .{ .azure = rows };
	}

	fn counting(self: *Db, container: []const u8, prefix: []const u8) db.Error!Rows {
		var scratch = std.heap.ArenaAllocator.init(self.allocator);
		defer scratch.deinit();
		const arena = scratch.allocator();
		var total: i64 = 0;
		var marker: []const u8 = "";
		var page: usize = 0;
		while (page < COUNT_PAGES) : (page += 1) {
			const listing = try self.list(arena, container, prefix, marker, 1000);
			total += @intCast(listing.entries.len);
			marker = listing.next orelse return self.oneNumber("blobs", total);
		}
		return self.oneNil("blobs");
	}

	pub fn apply(self: *Db, change: db.ask.Change) db.Error!void {
		self.begin();
		const container = if (change.table.name.len != 0) change.table.name else self.parts.container;
		if (container.len == 0) {
			self.remember("which container?");
			return error.Driver;
		}
		var scratch = std.heap.ArenaAllocator.init(self.allocator);
		defer scratch.deinit();
		const arena = scratch.allocator();

		switch (change.kind) {
			.delete => {
				const name = db.ask.only(change.where, NAME) orelse {
					self.remember("which blob? Azure addresses a row by its name");
					return error.Driver;
				};
				const response = try self.call(arena, .{ .method = "DELETE", .container = container, .blob = name });
				if (!response.ok() and response.status != 404) {
					return self.fail(response);
				}
				self.pages.forget();
			},
			.insert => {
				const name = flat(db.ask.valueOf(change.cells, NAME)) orelse "";
				if (name.len == 0) {
					self.remember("a blob needs a name");
					return error.Driver;
				}
				const response = try self.call(arena, .{
					.method = "PUT",
					.container = container,
					.blob = name,
					.headers = &.{.{ .name = "x-ms-blob-type", .value = "BlockBlob" }},
				});
				if (!response.ok()) {
					return self.fail(response);
				}
				self.pages.forget();
			},
			.update => {
				const name = db.ask.only(change.where, NAME) orelse {
					self.remember("which blob? Azure addresses a row by its name");
					return error.Driver;
				};
				for ([_][]const u8{ SIZE, MODIFIED, ETAG, TYPE }) |column| {
					if (db.ask.valueOf(change.cells, column) != null) {
						self.complain("{s} is the server's to say, not ours", .{column});
						return error.Driver;
					}
				}
				const renamed = flat(db.ask.valueOf(change.cells, NAME)) orelse "";
				if (renamed.len == 0 or std.mem.eql(u8, renamed, name)) {
					self.remember("nothing to change: a blob's name is what can be");
					return error.Driver;
				}
				// Azure has no rename either: a copy, and then a delete.
				try self.copy(arena, container, name, renamed);
				const gone = try self.call(arena, .{ .method = "DELETE", .container = container, .blob = name });
				if (!gone.ok()) {
					return self.fail(gone);
				}
				self.pages.forget();
			},
		}
	}

	fn copy(self: *Db, arena: std.mem.Allocator, container: []const u8, from: []const u8, to: []const u8) db.Error!void {
		const source = try self.urlOf(arena, container, from);
		const response = try self.call(arena, .{
			.method = "PUT",
			.container = container,
			.blob = to,
			.headers = &.{.{ .name = "x-ms-copy-source", .value = source }},
		});
		if (!response.ok()) {
			return self.fail(response);
		}
		// A copy inside one account finishes before the answer comes back; one
		// that is still going says so, and pretending otherwise would delete the
		// original from under it.
		if (response.get("x-ms-copy-status")) |status| {
			if (!std.mem.eql(u8, status, "success")) {
				self.complain("the copy is still going ({s}) - the original was left alone", .{status});
				return error.Driver;
			}
		}
	}

	pub fn wording(self: *Db, allocator: std.mem.Allocator, request: db.Request) db.Error![]u8 {
		var out: List = .empty;
		errdefer out.deinit(allocator);
		switch (request) {
			.select => |value| {
				const container = if (value.table.name.len != 0) value.table.name else self.parts.container;
				var scratch = std.heap.ArenaAllocator.init(allocator);
				defer scratch.deinit();
				const wanted = self.whereOf(scratch.allocator(), value.where) catch Where{};
				if (wanted.exact) |name| {
					try out.print(allocator, "HEAD /{s}/{s}", .{ container, name });
				} else {
					try out.print(allocator, "GET /{s}?restype=container&comp=list", .{container});
					if (wanted.prefix.len != 0) {
						try out.print(allocator, "&prefix={s}", .{wanted.prefix});
					}
					try out.print(allocator, "&maxresults={d}", .{if (value.limit != 0) value.limit else PAGE});
					if (value.offset != 0) {
						try out.print(allocator, " (page {d})", .{value.offset / @max(1, value.limit) + 1});
					}
				}
			},
			.change => |value| {
				const container = if (value.table.name.len != 0) value.table.name else self.parts.container;
				const name = db.ask.only(value.where, NAME) orelse
					flat(db.ask.valueOf(value.cells, NAME)) orelse "?";
				switch (value.kind) {
					.delete => try out.print(allocator, "DELETE /{s}/{s}", .{ container, name }),
					.insert => try out.print(allocator, "PUT /{s}/{s}", .{ container, name }),
					.update => {
						const renamed = flat(db.ask.valueOf(value.cells, NAME)) orelse name;
						try out.print(allocator, "PUT /{s}/{s} (x-ms-copy-source: {s}) then DELETE /{s}/{s}", .{
							container, renamed, name, container, name,
						});
					},
				}
			},
		}
		return out.toOwnedSlice(allocator);
	}

	const Where = struct {
		prefix: []const u8 = "",
		exact: ?[]const u8 = null,
	};

	fn whereOf(self: *Db, arena: std.mem.Allocator, where: []const db.ask.Filter) db.Error!Where {
		var out = Where{};
		for (where) |filter| {
			if (!std.mem.eql(u8, filter.column, NAME)) {
				self.complain("Azure can only filter on the name; {s} is not something a listing knows", .{filter.column});
				return error.Driver;
			}
			switch (filter.op) {
				.eq => out.exact = try arena.dupe(u8, filter.value),
				.like => {
					const body = std.mem.trimEnd(u8, filter.value, "%");
					if (std.mem.indexOfAny(u8, body, "%_") != null) {
						self.remember("Azure matches a prefix, not a pattern: name LIKE 'a/b%' is all it can do");
						return error.Driver;
					}
					out.prefix = try arena.dupe(u8, body);
				},
				else => {
					self.remember("Azure can compare a name with = or LIKE 'prefix%', and nothing else");
					return error.Driver;
				},
			}
		}
		return out;
	}

	pub fn inTransaction(_: *Db) bool {
		return false;
	}

	pub fn schemas(_: *Db, arena: std.mem.Allocator) db.Error![][]const u8 {
		var out: std.ArrayListUnmanaged([]const u8) = .empty;
		return out.toOwnedSlice(arena);
	}

	pub fn objects(self: *Db, arena: std.mem.Allocator, _: []const u8) db.Error![]db.Object {
		if (self.parts.container.len != 0) {
			var out: std.ArrayListUnmanaged(db.Object) = .empty;
			try out.append(arena, .{ .name = try arena.dupe(u8, self.parts.container), .kind = .table });
			return out.items;
		}
		return self.containers(arena);
	}

	fn containers(self: *Db, arena: std.mem.Allocator) db.Error![]db.Object {
		var out: std.ArrayListUnmanaged(db.Object) = .empty;
		const response = try self.call(arena, .{ .query = &.{.{ .name = "comp", .value = "list" }} });
		if (!response.ok()) {
			return self.fail(response);
		}
		var reader = xml.Reader{ .text = response.body };
		var current: []const u8 = "";
		var inside = false;
		while (reader.next()) |event| {
			switch (event) {
				.open => |tag| {
					current = tag;
					if (std.mem.eql(u8, tag, "Container")) {
						inside = true;
					}
				},
				.close => |tag| {
					if (std.mem.eql(u8, tag, "Container")) {
						inside = false;
					}
					current = "";
				},
				.text => |text| {
					if (inside and std.mem.eql(u8, current, "Name")) {
						try out.append(arena, .{ .name = try xml.unescape(arena, text), .kind = .table });
					}
				},
			}
		}
		return out.items;
	}

	pub fn columns(_: *Db, arena: std.mem.Allocator, _: db.Table) db.Error![]db.Column {
		var out: std.ArrayListUnmanaged(db.Column) = .empty;
		try out.append(arena, .{ .name = NAME, .type = "string", .notnull = true, .pk = true, .original = NAME });
		try out.append(arena, .{ .name = SIZE, .type = "integer", .original = SIZE });
		try out.append(arena, .{ .name = MODIFIED, .type = "timestamp", .original = MODIFIED });
		try out.append(arena, .{ .name = ETAG, .type = "string", .original = ETAG });
		try out.append(arena, .{ .name = TYPE, .type = "string", .original = TYPE });
		try out.append(arena, .{ .name = TIER, .type = "string", .original = TIER });
		return out.items;
	}

	pub fn indexes(_: *Db, arena: std.mem.Allocator, _: db.Table) db.Error![]db.Index {
		var out: std.ArrayListUnmanaged(db.Index) = .empty;
		try out.append(arena, .{ .name = NAME, .kind = "PRIMARY", .columns = NAME });
		return out.items;
	}

	pub fn foreignKeys(_: *Db, _: std.mem.Allocator, _: db.Table) db.Error![]db.ForeignKey {
		return &[_]db.ForeignKey{};
	}

	pub fn definition(_: *Db, _: std.mem.Allocator, _: db.Table) db.Error!?[]const u8 {
		return null;
	}

	/// One listing: exact for a container that fits in it, unknown for one that
	/// does not.
	pub fn rowCount(self: *Db, table: db.Table) ?i64 {
		const container = if (table.name.len != 0) table.name else self.parts.container;
		if (container.len == 0) {
			return null;
		}
		var scratch = std.heap.ArenaAllocator.init(self.allocator);
		defer scratch.deinit();
		const listing = self.list(scratch.allocator(), container, "", "", 1000) catch return null;
		if (listing.next != null) {
			return null;
		}
		return @intCast(listing.entries.len);
	}

	pub fn rowKey(_: *Db, arena: std.mem.Allocator, _: db.Table) db.Error!db.RowKey {
		var out: std.ArrayListUnmanaged([]const u8) = .empty;
		try out.append(arena, NAME);
		return .{ .columns = out.items };
	}

	pub fn alterContext(_: *Db, _: std.mem.Allocator, _: db.Table, _: []const db.Column) db.Error!db.AlterContext {
		return .{};
	}

	pub fn settings(self: *Db, arena: std.mem.Allocator) db.Error![]db.Setting {
		var out: std.ArrayListUnmanaged(db.Setting) = .empty;
		try out.append(arena, .{ .label = "account", .value = self.parts.account });
		try out.append(arena, .{
			.label = "endpoint",
			.value = try std.fmt.allocPrint(arena, "{s}:{d}", .{ self.parts.host, self.parts.port }),
		});
		try out.append(arena, .{ .label = "addressing", .value = if (self.parts.path_style) "account in the path" else "account in the host" });
		try out.append(arena, .{ .label = "encrypted", .value = if (self.parts.tls) "yes, TLS" else "no" });
		try out.append(arena, .{
			.label = "authentication",
			.value = if (self.parts.sas.len != 0) "a shared access signature" else if (self.parts.key.len != 0) "the account key" else "none",
		});
		try out.append(arena, .{ .label = "credentials", .value = self.parts.source });
		if (self.parts.container.len != 0) {
			try out.append(arena, .{ .label = "container", .value = self.parts.container });
		}
		try out.append(arena, .{ .label = "api version", .value = sign.VERSION });
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
		return .{ .azure = .{} };
	}

	// -------------------------------------------------------------- console

	fn console(self: *Db, text: []const u8) db.Error!Rows {
		var scratch = std.heap.ArenaAllocator.init(self.allocator);
		defer scratch.deinit();
		const arena = scratch.allocator();
		const args = try typed.split(arena, text);
		if (args.len == 0) {
			return self.oneText("azure", "");
		}
		const command = args[0];
		const container = self.parts.container;

		if (eql(command, "HELP") or eql(command, "?")) {
			return self.help();
		}
		if (eql(command, "CONTAINERS")) {
			var rows = self.newNamed(&.{"container"}, &.{false});
			for (try self.containers(self.replies.allocator())) |object| {
				try rows.add(&.{.{ .text = object.name }});
			}
			return rows;
		}
		if (eql(command, "LS") or eql(command, "LIST")) {
			const which = if (args.len > 1 and looksLikeContainer(args[1])) args[1] else container;
			const prefix = if (args.len > 1 and !looksLikeContainer(args[1])) args[1] else if (args.len > 2) args[2] else "";
			if (which.len == 0) {
				self.remember("which container? try CONTAINERS, or name one: LS photos");
				return error.Driver;
			}
			const listing = try self.list(self.replies.allocator(), which, prefix, "", PAGE);
			var rows = self.newRows(which);
			for (listing.entries) |entry| {
				try rows.add(&.{
					.{ .text = entry.name },
					.{ .number = entry.size },
					.{ .text = entry.modified },
					.{ .text = entry.etag },
					.{ .text = entry.kind },
					.{ .text = entry.tier },
				});
			}
			return rows;
		}
		if (args.len < 2) {
			self.complain("{s} needs a name - try HELP", .{command});
			return error.Driver;
		}
		const name = args[1];
		if (container.len == 0) {
			self.remember("no container in this connection: name one in the target to use the console");
			return error.Driver;
		}

		if (eql(command, "GET") or eql(command, "CAT")) {
			const response = try self.call(self.replies.allocator(), .{
				.container = container,
				.blob = name,
				.limit = GET_LIMIT,
			});
			if (!response.ok()) {
				return self.fail(response);
			}
			var rows = self.newNamed(&.{ NAME, SIZE, "type", "value" }, &.{ false, true, false, false });
			try rows.add(&.{
				.{ .text = name },
				.{ .number = @intCast(response.body.len) },
				.{ .text = response.get("content-type") orelse "" },
				if (typed.readable(response.body)) .{ .text = response.body } else .{ .blob = response.body },
			});
			return rows;
		}
		if (eql(command, "HEAD") or eql(command, "STAT")) {
			const response = try self.call(arena, .{ .method = "HEAD", .container = container, .blob = name });
			if (!response.ok()) {
				return self.fail(response);
			}
			var rows = self.newNamed(&.{ "header", "value" }, &.{ false, false });
			const replies = self.replies.allocator();
			for (response.headers) |header| {
				try rows.add(&.{
					.{ .text = try replies.dupe(u8, header.name) },
					.{ .text = try replies.dupe(u8, header.value) },
				});
			}
			return rows;
		}
		if (eql(command, "PUT")) {
			const body = if (args.len > 2) args[2] else "";
			const response = try self.call(arena, .{
				.method = "PUT",
				.container = container,
				.blob = name,
				.headers = &.{
					.{ .name = "x-ms-blob-type", .value = "BlockBlob" },
					.{ .name = "Content-Type", .value = "text/plain; charset=utf-8" },
				},
				.body = body,
			});
			if (!response.ok()) {
				return self.fail(response);
			}
			self.pages.forget();
			return self.oneText("put", name);
		}
		if (eql(command, "DEL") or eql(command, "RM") or eql(command, "DELETE")) {
			const response = try self.call(arena, .{ .method = "DELETE", .container = container, .blob = name });
			if (!response.ok()) {
				return self.fail(response);
			}
			self.pages.forget();
			return self.oneText("deleted", name);
		}
		self.complain("no such command: {s} - try HELP", .{command});
		return error.Driver;
	}

	// ------------------------------------------------- as a place holding files

	/// The same connection seen as somewhere files can be copied to and from.
	pub fn files(self: *Db) db.store.Store {
		return .{ .azure = .{ .owner = self } };
	}

	/// A container has no directories, only blob names with slashes in them, so
	/// a listing that stops at each slash is what makes it look like one. A path
	/// here is `/container/some/prefix/`, and `/` is the list of containers.
	pub const Files = struct {
		owner: *Db,

		pub fn label(self: Files) []const u8 {
			return self.owner.parts.account;
		}

		pub fn message(self: Files) []const u8 {
			return self.owner.last_error.items;
		}

		pub fn start(self: Files, arena: std.mem.Allocator) db.store.Error![]const u8 {
			if (self.owner.parts.container.len == 0) {
				return "/";
			}
			return std.fmt.allocPrint(arena, "/{s}", .{self.owner.parts.container}) catch error.OutOfMemory;
		}

		const Split = struct {
			container: []const u8 = "",
			blob: []const u8 = "",
		};

		fn partsOf(path: []const u8) Split {
			const trimmed = std.mem.trimStart(u8, path, "/");
			const slash = std.mem.indexOfScalar(u8, trimmed, '/') orelse return .{ .container = trimmed };
			return .{ .container = trimmed[0..slash], .blob = trimmed[slash + 1 ..] };
		}

		fn asFolder(arena: std.mem.Allocator, name: []const u8) db.store.Error![]const u8 {
			if (name.len == 0 or std.mem.endsWith(u8, name, "/")) {
				return name;
			}
			return std.fmt.allocPrint(arena, "{s}/", .{name}) catch error.OutOfMemory;
		}

		fn blame(self: Files, response: http.Response) db.store.Error {
			_ = self.owner.fail(response) catch {};
			return error.Store;
		}

		pub fn list(self: Files, arena: std.mem.Allocator, path: []const u8) db.store.Error![]db.store.Entry {
			var out: std.ArrayListUnmanaged(db.store.Entry) = .empty;
			const where = partsOf(path);
			if (where.container.len == 0) {
				const found = self.owner.containers(arena) catch return error.Store;
				for (found) |one| {
					out.append(arena, .{ .name = one.name, .kind = .dir }) catch return error.OutOfMemory;
				}
				return out.items;
			}

			const prefix = try asFolder(arena, where.blob);
			var marker: []const u8 = "";
			while (true) {
				const page = self.owner.listPage(arena, where.container, prefix, marker, 1000, true) catch return error.Store;
				for (page.folders) |one| {
					const name = std.mem.trimEnd(u8, one[@min(prefix.len, one.len)..], "/");
					if (name.len != 0) {
						out.append(arena, .{ .name = name, .kind = .dir }) catch return error.OutOfMemory;
					}
				}
				for (page.entries) |entry| {
					const name = entry.name[@min(prefix.len, entry.name.len)..];
					if (name.len == 0) {
						continue;
					}
					out.append(arena, .{
						.name = name,
						.kind = .file,
						.size = @intCast(@max(entry.size, 0)),
					}) catch return error.OutOfMemory;
				}
				marker = page.next orelse break;
			}
			return out.items;
		}

		pub fn stat(self: Files, arena: std.mem.Allocator, path: []const u8) db.store.Error!db.store.Entry {
			const where = partsOf(path);
			if (where.container.len == 0 or where.blob.len == 0) {
				return .{ .name = db.store.basename(path), .kind = .dir };
			}
			const response = self.owner.call(arena, .{
				.method = "HEAD",
				.container = where.container,
				.blob = where.blob,
			}) catch return error.Store;
			if (response.ok()) {
				return .{
					.name = db.store.basename(path),
					.kind = .file,
					.size = std.fmt.parseInt(u64, response.get("content-length") orelse "0", 10) catch 0,
				};
			}
			const prefix = try asFolder(arena, where.blob);
			const page = self.owner.listPage(arena, where.container, prefix, "", 1, true) catch return error.Store;
			if (page.entries.len != 0 or page.folders.len != 0) {
				return .{ .name = db.store.basename(path), .kind = .dir };
			}
			self.owner.complain("{s} is not there", .{path});
			return error.Store;
		}

		pub fn openRead(self: Files, arena: std.mem.Allocator, path: []const u8) db.store.Error!Ranged {
			const where = partsOf(path);
			const what = try self.stat(arena, path);
			return .{
				.owner = self.owner,
				.container = self.owner.allocator.dupe(u8, where.container) catch return error.OutOfMemory,
				.blob = self.owner.allocator.dupe(u8, where.blob) catch return error.OutOfMemory,
				.size = what.size,
			};
		}

		pub fn openWrite(self: Files, _: std.mem.Allocator, path: []const u8, size: u64) db.store.Error!Upload {
			if (size > UPLOAD_LIMIT) {
				self.owner.complain(
					"{s} is {d} MB, and a blob goes up in one request here - the ceiling is {d} MB",
					.{ path, size >> 20, UPLOAD_LIMIT >> 20 },
				);
				return error.Store;
			}
			const where = partsOf(path);
			return .{
				.owner = self.owner,
				.container = self.owner.allocator.dupe(u8, where.container) catch return error.OutOfMemory,
				.blob = self.owner.allocator.dupe(u8, where.blob) catch return error.OutOfMemory,
			};
		}

		pub fn makeDir(self: Files, arena: std.mem.Allocator, path: []const u8) db.store.Error!void {
			const where = partsOf(path);
			if (where.blob.len == 0) {
				return;
			}
			const response = self.owner.call(arena, .{
				.method = "PUT",
				.container = where.container,
				.blob = try asFolder(arena, where.blob),
				.headers = &.{.{ .name = "x-ms-blob-type", .value = "BlockBlob" }},
			}) catch return error.Store;
			if (!response.ok()) {
				return self.blame(response);
			}
			self.owner.pages.forget();
		}

		pub fn remove(self: Files, arena: std.mem.Allocator, path: []const u8, kind: db.store.Kind) db.store.Error!void {
			const where = partsOf(path);
			const name = if (kind == .dir) try asFolder(arena, where.blob) else where.blob;
			const response = self.owner.call(arena, .{
				.method = "DELETE",
				.container = where.container,
				.blob = name,
			}) catch return error.Store;
			if (!response.ok() and !(kind == .dir and response.status == 404)) {
				return self.blame(response);
			}
			self.owner.pages.forget();
		}

		/// Azure has no rename either, so this is a copy and a delete. The copy is
		/// the server's own, which is why it takes a URL and not the bytes.
		pub fn rename(self: Files, arena: std.mem.Allocator, from: []const u8, to: []const u8) db.store.Error!void {
			const source = partsOf(from);
			const target = partsOf(to);
			const url = self.owner.urlOf(arena, source.container, source.blob) catch return error.Store;
			const response = self.owner.call(arena, .{
				.method = "PUT",
				.container = target.container,
				.blob = target.blob,
				.headers = &.{.{ .name = "x-ms-copy-source", .value = url }},
			}) catch return error.Store;
			if (!response.ok()) {
				return self.blame(response);
			}
			try self.remove(arena, from, .file);
		}
	};

	/// A blob read in pieces, for the same reason S3 objects are.
	pub const Ranged = struct {
		owner: *Db,
		container: []const u8,
		blob: []const u8,
		size: u64 = 0,
		at: u64 = 0,
		held: []const u8 = &.{},
		taken: usize = 0,
		scratch: ?std.heap.ArenaAllocator = null,

		pub fn read(self: *Ranged, into: []u8) db.store.Error!usize {
			if (self.taken == self.held.len) {
				if (self.at >= self.size) {
					return 0;
				}
				try self.fetch();
			}
			const count = @min(into.len, self.held.len - self.taken);
			@memcpy(into[0..count], self.held[self.taken .. self.taken + count]);
			self.taken += count;
			return count;
		}

		fn fetch(self: *Ranged) db.store.Error!void {
			if (self.scratch) |*old| {
				old.deinit();
			}
			self.scratch = std.heap.ArenaAllocator.init(self.owner.allocator);
			const arena = self.scratch.?.allocator();

			const last = @min(self.at + RANGE, self.size) - 1;
			const range = std.fmt.allocPrint(arena, "bytes={d}-{d}", .{ self.at, last }) catch return error.OutOfMemory;
			const response = self.owner.call(arena, .{
				.container = self.container,
				.blob = self.blob,
				.headers = &.{.{ .name = "x-ms-range", .value = range }},
				.limit = RANGE + (1 << 20),
			}) catch return error.Store;
			if (!response.ok()) {
				_ = self.owner.fail(response) catch {};
				return error.Store;
			}
			self.held = response.body;
			self.taken = 0;
			self.at += response.body.len;
			if (response.body.len == 0) {
				self.at = self.size;
			}
		}

		pub fn close(self: *Ranged) void {
			if (self.scratch) |*old| {
				old.deinit();
			}
			self.scratch = null;
			self.owner.allocator.free(self.container);
			self.owner.allocator.free(self.blob);
		}
	};

	/// A blob written in one go, held until the end because the request has to
	/// say how long it is and be signed over that.
	pub const Upload = struct {
		owner: *Db,
		container: []const u8,
		blob: []const u8,
		held: List = .empty,

		pub fn write(self: *Upload, bytes: []const u8) db.store.Error!void {
			self.held.appendSlice(self.owner.allocator, bytes) catch return error.OutOfMemory;
			if (self.held.items.len > UPLOAD_LIMIT) {
				return error.Store;
			}
		}

		pub fn finish(self: *Upload) db.store.Error!void {
			defer self.release();
			var scratch = std.heap.ArenaAllocator.init(self.owner.allocator);
			defer scratch.deinit();
			const response = self.owner.call(scratch.allocator(), .{
				.method = "PUT",
				.container = self.container,
				.blob = self.blob,
				.headers = &.{.{ .name = "x-ms-blob-type", .value = "BlockBlob" }},
				.body = self.held.items,
			}) catch return error.Store;
			if (!response.ok()) {
				_ = self.owner.fail(response) catch {};
				return error.Store;
			}
			self.owner.pages.forget();
		}

		pub fn abandon(self: *Upload) void {
			self.release();
		}

		fn release(self: *Upload) void {
			self.held.deinit(self.owner.allocator);
			self.owner.allocator.free(self.container);
			self.owner.allocator.free(self.blob);
		}
	};

	fn help(self: *Db) db.Error!Rows {
		var rows = self.newNamed(&.{ "command", "what it does" }, &.{ false, false });
		const LINES = [_][2][]const u8{
			.{ "CONTAINERS", "every container this account can see" },
			.{ "LS [container] [prefix]", "one page of names" },
			.{ "GET name", "the blob itself, shown as a value" },
			.{ "HEAD name", "what the server says about it" },
			.{ "PUT name [text]", "write a block blob" },
			.{ "DEL name", "remove one" },
		};
		for (LINES) |line| {
			try rows.add(&.{ .{ .text = line[0] }, .{ .text = line[1] } });
		}
		return rows;
	}

	// ---------------------------------------------------------------- rows

	fn newRows(self: *Db, container: []const u8) Rows {
		return .{
			.owner = self,
			.names = &COLUMNS,
			.numeric = &NUMERIC,
			.table = container,
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

	fn oneNil(self: *Db, name: []const u8) db.Error!Rows {
		var rows = try self.oneColumn(name, true);
		try rows.add(&.{.{ .nil = {} }});
		return rows;
	}
};

/// The markers that start each page of one listing.
const Pages = struct {
	arena: std.heap.ArenaAllocator,
	container: []const u8 = "",
	prefix: []const u8 = "",
	size: usize = 0,
	markers: std.ArrayListUnmanaged([]const u8) = .empty,
	ended: bool = false,

	fn matches(self: *Pages, container: []const u8, prefix: []const u8, size: usize) bool {
		return self.size == size and
			std.mem.eql(u8, self.container, container) and
			std.mem.eql(u8, self.prefix, prefix);
	}

	fn restart(self: *Pages, container: []const u8, prefix: []const u8, size: usize) !void {
		_ = self.arena.reset(.retain_capacity);
		const kept = self.arena.allocator();
		self.markers = .empty;
		self.container = try kept.dupe(u8, container);
		self.prefix = try kept.dupe(u8, prefix);
		self.size = size;
		self.ended = false;
		try self.markers.append(kept, "");
	}

	fn forget(self: *Pages) void {
		self.size = 0;
		self.ended = false;
	}
};

// ------------------------------------------------------------------ replies

/// One listing. The blob's name is an element of its own and everything else
/// hangs under `Properties`, which is the whole of the difference from S3.
pub fn parseListing(arena: std.mem.Allocator, body: []const u8) !Db.Listing {
	var entries: std.ArrayListUnmanaged(Db.Entry) = .empty;
	var folders: std.ArrayListUnmanaged([]const u8) = .empty;
	var next: ?[]const u8 = null;

	var reader = xml.Reader{ .text = body };
	var current: []const u8 = "";
	var inside = false;
	var folding = false;
	var entry = Db.Entry{};
	while (reader.next()) |event| {
		switch (event) {
			.open => |name| {
				current = name;
				if (std.mem.eql(u8, name, "Blob")) {
					entry = .{};
					inside = true;
				} else if (std.mem.eql(u8, name, "BlobPrefix")) {
					folding = true;
				}
			},
			.close => |name| {
				if (std.mem.eql(u8, name, "Blob")) {
					try entries.append(arena, entry);
					inside = false;
				} else if (std.mem.eql(u8, name, "BlobPrefix")) {
					folding = false;
				}
				current = "";
			},
			.text => |text| {
				if (folding) {
					if (std.mem.eql(u8, current, "Name")) {
						try folders.append(arena, try xml.unescape(arena, text));
					}
				} else if (inside) {
					if (std.mem.eql(u8, current, "Name")) {
						entry.name = try xml.unescape(arena, text);
					} else if (std.mem.eql(u8, current, "Content-Length")) {
						entry.size = std.fmt.parseInt(i64, std.mem.trim(u8, text, " \t\r\n"), 10) catch 0;
					} else if (std.mem.eql(u8, current, "Last-Modified")) {
						entry.modified = try xml.unescape(arena, text);
					} else if (std.mem.eql(u8, current, "Etag") or std.mem.eql(u8, current, "ETag")) {
						entry.etag = trimQuotes(try xml.unescape(arena, text));
					} else if (std.mem.eql(u8, current, "BlobType")) {
						entry.kind = try xml.unescape(arena, text);
					} else if (std.mem.eql(u8, current, "AccessTier")) {
						entry.tier = try xml.unescape(arena, text);
					}
				} else if (std.mem.eql(u8, current, "NextMarker")) {
					next = try xml.unescape(arena, text);
				}
			},
		}
	}
	return .{
		.entries = entries.items,
		.folders = folders.items,
		// An empty `<NextMarker/>` is the end, and it is written that way rather
		// than left out - so an empty one is not a next page.
		.next = if (next != null and next.?.len != 0) next else null,
	};
}

fn contentTypeOf(headers: []const sign.Header) []const u8 {
	for (headers) |header| {
		if (std.ascii.eqlIgnoreCase(header.name, "content-type")) {
			return header.value;
		}
	}
	return "";
}


fn trimQuotes(text: []const u8) []const u8 {
	return std.mem.trim(u8, text, "\"");
}

fn serverName(header: ?[]const u8) []const u8 {
	const text = header orelse return "Azure Blob";
	if (std.ascii.indexOfIgnoreCase(text, "azurite") != null) {
		return "Azurite";
	}
	return "Azure Blob";
}

fn eql(left: []const u8, right: []const u8) bool {
	return std.ascii.eqlIgnoreCase(left, right);
}

/// A container name has no slash in it; a prefix nearly always does.
fn looksLikeContainer(word: []const u8) bool {
	return std.mem.indexOfScalar(u8, word, '/') == null and !std.mem.endsWith(u8, word, "%");
}

fn flat(value: ??[]const u8) ?[]const u8 {
	const inner = value orelse return null;
	return inner orelse null;
}


// ------------------------------------------------------------------- cursor

pub const Value = union(enum) {
	nil: void,
	text: []const u8,
	blob: []const u8,
	number: i64,

	/// What this means to the grid. The one thing a driver's own value type
	/// has to say for itself; the walking and holding is db.Built's.
	pub fn asValue(self: @This()) db.Value {
		return switch (self) {
			.nil => .{ .null = {} },
			.number => |number| .{ .int = number },
			.text => |text| .{ .text = text },
			.blob => |bytes| .{ .blob = bytes },
		};
	}
};

pub const Rows = db.Built(Db, Value);

// ---------------------------------------------------------------------- DDL

/// Azure has no schema to define either.
pub const Ddl = struct {
	pub fn types(_: Ddl) []const []const u8 {
		return &[_][]const u8{ "string", "integer", "timestamp" };
	}

	fn refuse(out: *List, a: std.mem.Allocator, what: []const u8) !void {
		try out.appendSlice(a, "-- Azure Blob has no ");
		try out.appendSlice(a, what);
		try out.appendSlice(a, ", so nothing was done\n");
	}

	pub fn createTable(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table, _: []const db.Column, _: []const db.ForeignKey) !void {
		try refuse(out, a, "tables to create - a container is made where it is billed");
	}

	pub fn alterTable(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table, _: []const u8, _: []const db.Column, _: db.AlterContext) !void {
		try refuse(out, a, "columns to alter: a blob is a name and its bytes");
	}

	pub fn addForeignKey(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table, _: db.ForeignKey, _: db.AlterContext) !void {
		try refuse(out, a, "foreign keys");
	}

	pub fn createIndex(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table, _: []const u8, _: []const []const u8, _: bool, _: []const u8) !void {
		try refuse(out, a, "indexes: the name is the index");
	}

	pub fn createView(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table, _: []const u8) !void {
		try refuse(out, a, "views");
	}

	pub fn createTrigger(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table, _: []const u8, _: []const u8, _: []const u8, _: []const u8, _: []const u8) !void {
		try refuse(out, a, "triggers");
	}

	pub fn renameTable(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table, _: []const u8) !void {
		try refuse(out, a, "containers to rename");
	}

	pub fn copyTable(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table, _: []const u8, _: bool) !void {
		try refuse(out, a, "containers to copy in one go");
	}

	pub fn dropObject(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Kind, _: db.Table) !void {
		try refuse(out, a, "a drop that would not delete somebody's data by accident");
	}

	pub fn truncate(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table) !void {
		try refuse(out, a, "a way to empty a container in one request");
	}
};

// ------------------------------------------------------------------- tests

const testing = std.testing;

test "a listing is read the way Azure sends one" {
	var scratch = std.heap.ArenaAllocator.init(testing.allocator);
	defer scratch.deinit();
	const arena = scratch.allocator();

	// Cut down from what the emulator actually answers.
	const listing = try parseListing(arena,
		\\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
		\\<EnumerationResults ServiceEndpoint="http://127.0.0.1:10000/devstoreaccount1" ContainerName="photos">
		\\<Prefix/><Marker/><MaxResults>2</MaxResults><Blobs>
		\\<Blob><Name>2015/august trip.txt</Name><Properties>
		\\<Creation-Time>Wed, 12 Aug 2026 17:16:36 GMT</Creation-Time>
		\\<Last-Modified>Wed, 12 Aug 2026 17:16:36 GMT</Last-Modified>
		\\<Etag>0x24C87BB722B4660</Etag><Content-Length>9</Content-Length>
		\\<Content-Type>text/plain</Content-Type><Content-MD5>hpcEvo3X5atzPLYK19+K4A==</Content-MD5>
		\\<BlobType>BlockBlob</BlobType><LeaseStatus>unlocked</LeaseStatus>
		\\<AccessTier>Hot</AccessTier><AccessTierInferred>true</AccessTierInferred>
		\\</Properties></Blob>
		\\<Blob><Name>notes.txt</Name><Properties>
		\\<Last-Modified>Wed, 12 Aug 2026 17:16:37 GMT</Last-Modified>
		\\<Etag>0x26C7E89ECF1E4C0</Etag><Content-Length>0</Content-Length>
		\\<BlobType>AppendBlob</BlobType><AccessTier>Cool</AccessTier>
		\\</Properties></Blob>
		\\</Blobs><NextMarker>2!76!MDAwMDA5</NextMarker></EnumerationResults>
	);
	try testing.expectEqual(@as(usize, 2), listing.entries.len);
	// The name is an element of its own; everything else is under Properties, and
	// Content-Length is the size whatever S3 calls it.
	try testing.expectEqualStrings("2015/august trip.txt", listing.entries[0].name);
	try testing.expectEqual(@as(i64, 9), listing.entries[0].size);
	try testing.expectEqualStrings("Wed, 12 Aug 2026 17:16:36 GMT", listing.entries[0].modified);
	try testing.expectEqualStrings("0x24C87BB722B4660", listing.entries[0].etag);
	try testing.expectEqualStrings("BlockBlob", listing.entries[0].kind);
	try testing.expectEqualStrings("Hot", listing.entries[0].tier);
	try testing.expectEqualStrings("notes.txt", listing.entries[1].name);
	try testing.expectEqualStrings("AppendBlob", listing.entries[1].kind);
	try testing.expectEqual(@as(i64, 0), listing.entries[1].size);
	try testing.expectEqualStrings("2!76!MDAwMDA5", listing.next.?);
}

test "an empty marker is the end, not a next page" {
	var scratch = std.heap.ArenaAllocator.init(testing.allocator);
	defer scratch.deinit();
	const arena = scratch.allocator();

	const listing = try parseListing(arena,
		\\<EnumerationResults ContainerName="photos"><Blobs>
		\\<Blob><Name>only.txt</Name><Properties><Content-Length>3</Content-Length></Properties></Blob>
		\\</Blobs><NextMarker/></EnumerationResults>
	);
	try testing.expectEqual(@as(usize, 1), listing.entries.len);
	try testing.expect(listing.next == null);

	const empty = try parseListing(arena, "<EnumerationResults><Blobs/><NextMarker/></EnumerationResults>");
	try testing.expectEqual(@as(usize, 0), empty.entries.len);
	try testing.expect(empty.next == null);
}

test "a container and a prefix tell themselves apart" {
	try testing.expect(looksLikeContainer("photos"));
	try testing.expect(!looksLikeContainer("2015/august"));
}

test "text is shown as text and everything else as bytes" {
	try testing.expect(typed.readable("ahoj, světe\n"));
	try testing.expect(!typed.readable(&.{ 0x89, 'P', 'N', 'G' }));
	try testing.expect(!typed.readable(&.{ 'a', 0x00 }));
}

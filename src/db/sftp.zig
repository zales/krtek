//! The SFTP driver: a directory is a table and a file is a row.
//!
//! This is the first engine here that is a *filesystem* rather than a store of
//! keys, and it shows in three places. A directory is a real place, so the schema
//! is the path and `#` walks between them. A rename is a real rename rather than
//! a copy and a delete. And a listing arrives whole - SFTP has no pagination -
//! so the sorting, the counting and the paging are this program's and are exact,
//! which is the one thing S3 and Azure cannot manage.
//!
//! Columns are `name`, `size`, `kind`, `modified`, `mode` and `owner`. Editing
//! the name renames; editing the mode chmods, in either `644` or `rw-r--r--`.
//! Adding a row makes an empty file, or a directory when `kind` says so.
//!
//! **The transport is libssh2 and not this program.** Everything else here is
//! written out - Redis, Kafka, HTTP, two request signatures - and SSH is where
//! that stops: a mistake in a key exchange is a vulnerability rather than a wrong
//! row. What that costs is written down in `ssh.zig`: the session is blocking, so
//! a transfer cannot be given up on halfway, and nothing hangs forever instead.
//!
//! The host key is checked against `~/.ssh/known_hosts` like any other ssh
//! client, and a host nobody has met is refused with its fingerprint rather than
//! trusted quietly. `?insecure=1` is the way to say otherwise, and it has to be
//! said.

const std = @import("std");
const db = @import("db.zig");
const ssh = @import("ssh.zig");

pub const address = @import("sftp/target.zig");

const List = db.List;

comptime {
	_ = address;
}

pub const owns = address.owns;
pub const parse = address.parse;
pub const Parts = address.Parts;

pub const NAME = "name";
pub const SIZE = "size";
pub const KIND = "kind";
pub const MODIFIED = "modified";
pub const MODE = "mode";
pub const OWNER = "owner";

const COLUMNS = [_][]const u8{ NAME, SIZE, KIND, MODIFIED, MODE, OWNER };
const NUMERIC = [_]bool{ false, true, false, false, false, false };

/// How many rows one page holds when nobody said.
const PAGE: usize = 200;
/// How many entries one directory may have before this stops reading it. A
/// directory with more is a directory nobody browses.
const ENTRIES: usize = 100_000;
/// How much of a file the console will bring back in one go.
const GET_LIMIT: usize = 32 << 20;

pub const Db = struct {
	allocator: std.mem.Allocator,
	home: std.heap.ArenaAllocator,
	parts: Parts = .{},
	conn: ?*ssh.Connection = null,
	/// Where we are. Everything without a leading slash is relative to it.
	cwd: []const u8 = "/",
	label: List = .empty,
	version_text: List = .empty,
	last_error: List = .empty,
	progress: ?db.Progress = null,
	requests: usize = 0,
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
			try report.appendSlice(allocator, "that is not an sftp target");
			return error.Driver;
		};
		self.conn = ssh.connect(allocator, .{
			.host = self.parts.host,
			.port = self.parts.port,
			.user = self.parts.user,
			.password = self.parts.password,
			.key = self.parts.key,
			.passphrase = self.parts.passphrase,
			.verify = self.parts.verify,
		}, report) catch return error.Driver;

		// Where we start: what the target said, or wherever the server puts us.
		const start = if (self.parts.path.len != 0) self.parts.path else ".";
		self.cwd = ssh.realpath(self.conn.?, home, start) catch {
			try report.print(allocator, "cannot look at {s}", .{start});
			return error.Driver;
		};
		// And it has to be a directory, or every screen after this is empty.
		const what = ssh.stat(self.conn.?, self.cwd) catch {
			try report.appendSlice(allocator, self.conn.?.message());
			return error.Driver;
		};
		if (!what.isDir()) {
			try report.print(allocator, "{s} is a file, not a directory", .{self.cwd});
			return error.Driver;
		}
		self.relabel();
		try self.version_text.print(allocator, "SFTP (libssh2 {s})", .{ssh.version.text()});
		return self;
	}

	pub fn close(self: *Db) void {
		if (self.conn) |conn| {
			conn.close();
			self.allocator.destroy(conn);
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
	}

	pub fn caps(_: *Db) db.Caps {
		return .{
			// A directory is what a schema is here, so `#` walks the tree.
			.schemas = true,
			.databases = true,
			.label = "SFTP",
			.speaks_sql = false,
			// The names without the files are a list, not a dump.
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
		self.label.print(self.allocator, "{s}@{s}:{s}", .{
			self.parts.user,
			self.parts.host,
			self.cwd,
		}) catch {};
	}

	fn remember(self: *Db, text: []const u8) void {
		self.last_error.clearRetainingCapacity();
		self.last_error.appendSlice(self.allocator, text) catch {};
	}

	fn complain(self: *Db, comptime format: []const u8, args: anytype) void {
		self.last_error.clearRetainingCapacity();
		self.last_error.print(self.allocator, format, args) catch {};
	}

	/// Whatever libssh2 said last, which is nearly always better than anything
	/// this file could make up.
	fn fromServer(self: *Db) db.Error {
		if (self.conn) |conn| {
			self.remember(conn.message());
		}
		return error.Driver;
	}

	fn begin(self: *Db) void {
		if (self.progress) |progress| {
			progress.starting();
		}
		self.last_error.clearRetainingCapacity();
		_ = self.replies.reset(.retain_capacity);
	}

	fn at(self: *Db, arena: std.mem.Allocator, path: []const u8) db.Error![]const u8 {
		return address.join(arena, self.cwd, path) catch error.OutOfMemory;
	}

	// ------------------------------------------------- as a place holding files

	/// The same connection seen as somewhere files can be copied to and from.
	pub fn files(self: *Db) db.store.Store {
		return .{ .sftp = .{ .owner = self } };
	}

	/// The driver answers questions about rows; this answers the handful the file
	/// manager asks, in the words every other place uses. It is a value rather
	/// than a pointer because it is only a connection wearing a different hat.
	pub const Files = struct {
		owner: *Db,

		pub fn label(self: Files) []const u8 {
			return self.owner.parts.host;
		}

		pub fn message(self: Files) []const u8 {
			if (self.owner.conn) |conn| {
				return conn.message();
			}
			return self.owner.last_error.items;
		}

		pub fn start(self: Files, _: std.mem.Allocator) db.store.Error![]const u8 {
			return self.owner.cwd;
		}

		fn connection(self: Files) db.store.Error!*ssh.Connection {
			return self.owner.conn orelse error.Store;
		}

		pub fn list(self: Files, arena: std.mem.Allocator, path: []const u8) db.store.Error![]db.store.Entry {
			const conn = try self.connection();
			const found = ssh.readDir(conn, arena, path, ENTRIES) catch return error.Store;
			const out = arena.alloc(db.store.Entry, found.len) catch return error.OutOfMemory;
			for (found, 0..) |entry, index| {
				out[index] = .{
					.name = entry.name,
					.kind = if (entry.attributes.isDir()) .dir else .file,
					.size = entry.attributes.filesize,
					.modified = @intCast(entry.attributes.mtime),
				};
			}
			return out;
		}

		pub fn stat(self: Files, _: std.mem.Allocator, path: []const u8) db.store.Error!db.store.Entry {
			const conn = try self.connection();
			const what = ssh.stat(conn, path) catch return error.Store;
			return .{
				.name = address.basename(path),
				.kind = if (what.isDir()) .dir else .file,
				.size = what.filesize,
				.modified = @intCast(what.mtime),
			};
		}

		pub fn openRead(self: Files, _: std.mem.Allocator, path: []const u8) db.store.Error!db.store.Remote {
			const conn = try self.connection();
			return .{ .file = ssh.openRead(conn, path) catch return error.Store };
		}

		pub fn openWrite(self: Files, _: std.mem.Allocator, path: []const u8, _: u64) db.store.Error!db.store.Remote {
			const conn = try self.connection();
			return .{ .file = ssh.openWrite(conn, path) catch return error.Store };
		}

		pub fn makeDir(self: Files, _: std.mem.Allocator, path: []const u8) db.store.Error!void {
			const conn = try self.connection();
			// A directory that is already there is what was wanted. SFTP answers
			// every failure with the same code, so the only way to tell is to look.
			if (ssh.stat(conn, path)) |what| {
				return if (what.isDir()) {} else error.Store;
			} else |_| {}
			ssh.makeDir(conn, path, 0o755) catch return error.Store;
		}

		pub fn remove(self: Files, _: std.mem.Allocator, path: []const u8, kind: db.store.Kind) db.store.Error!void {
			const conn = try self.connection();
			ssh.remove(conn, path, kind == .dir) catch return error.Store;
		}

		pub fn rename(self: Files, _: std.mem.Allocator, from: []const u8, to: []const u8) db.store.Error!void {
			const conn = try self.connection();
			ssh.rename(conn, from, to) catch return error.Store;
		}
	};

	/// The directory a request is about: the schema when there is one, and where
	/// we are otherwise.
	fn directoryOf(self: *Db, table: db.Table) []const u8 {
		return if (table.schema.len != 0) table.schema else self.cwd;
	}

	// -------------------------------------------------------------- reading

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
		return .{ .sftp = try self.console(trimmed) };
	}

	pub fn select(self: *Db, request: db.ask.Select) db.Error!?db.Rows {
		self.begin();
		if (request.where_text.len != 0) {
			self.remember("a raw WHERE is SQL - filter the name with = or LIKE instead");
			return error.Driver;
		}
		const arena = self.replies.allocator();
		const where = self.directoryOf(request.table);
		const entries = try self.listing(arena, where, request);

		if (request.count) {
			return .{ .sftp = try self.oneNumber("files", @intCast(entries.len)) };
		}

		const limit = if (request.limit != 0) request.limit else PAGE;
		const from = @min(request.offset, entries.len);
		const to = @min(from + limit, entries.len);

		var rows = self.newRows(request.table);
		var buffer: [10]u8 = undefined;
		for (entries[from..to]) |entry| {
			const attributes = entry.attributes;
			try rows.add(&.{
				.{ .text = entry.name },
				.{ .number = @intCast(attributes.filesize) },
				.{ .text = kindOf(attributes) },
				.{ .text = try address.stamp(arena, attributes.mtime) },
				.{ .text = try arena.dupe(u8, address.mode(&buffer, attributes.permissions)) },
				.{ .text = try std.fmt.allocPrint(arena, "{d}:{d}", .{ attributes.uid, attributes.gid }) },
			});
		}
		return .{ .sftp = rows };
	}

	/// One directory, filtered and sorted. All of it is in memory, which is why
	/// this driver can do what the object stores cannot: sort by size, count
	/// exactly, and match a pattern in the middle of a name.
	fn listing(self: *Db, arena: std.mem.Allocator, where: []const u8, request: db.ask.Select) db.Error![]ssh.Entry {
		const conn = self.conn orelse return error.Driver;
		self.requests += 1;
		const all = ssh.readDir(conn, arena, where, ENTRIES) catch return self.fromServer();

		var kept: std.ArrayListUnmanaged(ssh.Entry) = .empty;
		for (all) |entry| {
			if (try self.keep(entry, request.where)) {
				try kept.append(arena, entry);
			}
		}
		const order = if (request.order.len != 0) request.order else NAME;
		const by: Order = if (std.mem.eql(u8, order, SIZE))
			.size
		else if (std.mem.eql(u8, order, MODIFIED))
			.modified
		else if (std.mem.eql(u8, order, NAME))
			.name
		else {
			self.complain("nothing here sorts by {s}", .{order});
			return error.Driver;
		};
		std.mem.sort(ssh.Entry, kept.items, Sorting{ .by = by, .descending = request.descending }, lessThan);
		return kept.items;
	}

	fn keep(self: *Db, entry: ssh.Entry, filters: []const db.ask.Filter) db.Error!bool {
		for (filters) |filter| {
			const ok = if (std.mem.eql(u8, filter.column, NAME))
				switch (filter.op) {
					.eq => std.mem.eql(u8, entry.name, filter.value),
					.ne => !std.mem.eql(u8, entry.name, filter.value),
					.like => like(filter.value, entry.name),
					else => {
						self.remember("a name is compared with =, <> or LIKE");
						return error.Driver;
					},
				}
			else if (std.mem.eql(u8, filter.column, SIZE)) blk: {
				const wanted = std.fmt.parseInt(u64, std.mem.trim(u8, filter.value, " "), 10) catch {
					self.complain("{s} is not a size", .{filter.value});
					return error.Driver;
				};
				const size = entry.attributes.filesize;
				break :blk switch (filter.op) {
					.eq => size == wanted,
					.ne => size != wanted,
					.lt => size < wanted,
					.le => size <= wanted,
					.gt => size > wanted,
					.ge => size >= wanted,
					else => {
						self.remember("a size is compared with a number");
						return error.Driver;
					},
				};
			} else if (std.mem.eql(u8, filter.column, KIND))
				std.ascii.eqlIgnoreCase(kindOf(entry.attributes), filter.value)
			else {
				self.complain("a listing knows the name, the size and the kind; {s} is not one of them", .{filter.column});
				return error.Driver;
			};
			if (!ok) {
				return false;
			}
		}
		return true;
	}

	// -------------------------------------------------------------- writing

	pub fn apply(self: *Db, change: db.ask.Change) db.Error!void {
		self.begin();
		const conn = self.conn orelse return error.Driver;
		var scratch = std.heap.ArenaAllocator.init(self.allocator);
		defer scratch.deinit();
		const arena = scratch.allocator();
		const where = self.directoryOf(change.table);

		switch (change.kind) {
			.insert => {
				const name = flat(db.ask.valueOf(change.cells, NAME)) orelse "";
				if (name.len == 0) {
					self.remember("it needs a name");
					return error.Driver;
				}
				const path = address.join(arena, where, name) catch return error.OutOfMemory;
				const wanted = flat(db.ask.valueOf(change.cells, KIND)) orelse "file";
				if (std.ascii.startsWithIgnoreCase(wanted, "dir")) {
					ssh.makeDir(conn, path, 0o755) catch return self.fromServer();
					return;
				}
				ssh.writeFile(conn, path, "") catch return self.fromServer();
				if (flat(db.ask.valueOf(change.cells, MODE))) |text| {
					if (address.parseMode(text)) |bits| {
						ssh.chmod(conn, path, bits) catch return self.fromServer();
					}
				}
			},
			.update => {
				const name = db.ask.only(change.where, NAME) orelse {
					self.remember("which one? a row here is addressed by its name");
					return error.Driver;
				};
				const path = address.join(arena, where, name) catch return error.OutOfMemory;
				for ([_][]const u8{ SIZE, MODIFIED, OWNER, KIND }) |column| {
					if (db.ask.valueOf(change.cells, column) != null) {
						self.complain("{s} is not something this changes", .{column});
						return error.Driver;
					}
				}
				var did = false;
				// The mode first: a rename moves what the mode is about.
				if (flat(db.ask.valueOf(change.cells, MODE))) |text| {
					const bits = address.parseMode(text) orelse {
						self.complain("{s} is not a mode - try 644 or rw-r--r--", .{text});
						return error.Driver;
					};
					ssh.chmod(conn, path, bits) catch return self.fromServer();
					did = true;
				}
				if (flat(db.ask.valueOf(change.cells, NAME))) |renamed| {
					if (!std.mem.eql(u8, renamed, name)) {
						// A real rename, which is the whole difference from an object
						// store: nothing is copied and nothing is deleted.
						const to = address.join(arena, where, renamed) catch return error.OutOfMemory;
						ssh.rename(conn, path, to) catch return self.fromServer();
						did = true;
					}
				}
				if (!did) {
					self.remember("nothing to change: the name and the mode are what can be");
					return error.Driver;
				}
			},
			.delete => {
				const name = db.ask.only(change.where, NAME) orelse {
					self.remember("which one? a row here is addressed by its name");
					return error.Driver;
				};
				const path = address.join(arena, where, name) catch return error.OutOfMemory;
				const what = ssh.stat(conn, path) catch return self.fromServer();
				ssh.remove(conn, path, what.isDir()) catch return self.fromServer();
			},
		}
	}

	/// A request in the words a shell would use, which is this engine's own
	/// language.
	pub fn wording(self: *Db, allocator: std.mem.Allocator, request: db.Request) db.Error![]u8 {
		var out: List = .empty;
		errdefer out.deinit(allocator);
		switch (request) {
			.select => |value| {
				try out.print(allocator, "ls {s}", .{self.directoryOf(value.table)});
				for (value.where) |filter| {
					try out.print(allocator, " | {s} {s} {s}", .{ filter.column, @tagName(filter.op), filter.value });
				}
			},
			.change => |value| {
				const where = self.directoryOf(value.table);
				const name = db.ask.only(value.where, NAME) orelse
					flat(db.ask.valueOf(value.cells, NAME)) orelse "?";
				switch (value.kind) {
					.delete => try out.print(allocator, "rm {s}/{s}", .{ where, name }),
					.insert => {
						const wanted = flat(db.ask.valueOf(value.cells, KIND)) orelse "file";
						if (std.ascii.startsWithIgnoreCase(wanted, "dir")) {
							try out.print(allocator, "mkdir {s}/{s}", .{ where, name });
						} else {
							try out.print(allocator, "touch {s}/{s}", .{ where, name });
						}
					},
					.update => {
						if (flat(db.ask.valueOf(value.cells, MODE))) |text| {
							try out.print(allocator, "chmod {s} {s}/{s}", .{ text, where, name });
						}
						if (flat(db.ask.valueOf(value.cells, NAME))) |renamed| {
							if (!std.mem.eql(u8, renamed, name)) {
								if (out.items.len != 0) {
									try out.appendSlice(allocator, " && ");
								}
								try out.print(allocator, "mv {s}/{s} {s}/{s}", .{ where, name, where, renamed });
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

	/// Where we are, where we came from, and where we can go: a directory is what
	/// a schema is here, so `#` walks the tree.
	pub fn schemas(self: *Db, arena: std.mem.Allocator) db.Error![][]const u8 {
		const conn = self.conn orelse return error.Driver;
		var out: std.ArrayListUnmanaged([]const u8) = .empty;
		try out.append(arena, try arena.dupe(u8, self.cwd));
		const above = address.parent(self.cwd);
		if (!std.mem.eql(u8, above, self.cwd)) {
			try out.append(arena, try arena.dupe(u8, above));
		}
		const entries = ssh.readDir(conn, arena, self.cwd, ENTRIES) catch return out.items;
		for (entries) |entry| {
			if (entry.attributes.isDir()) {
				try out.append(arena, address.join(arena, self.cwd, entry.name) catch continue);
			}
		}
		return out.items;
	}

	pub fn objects(self: *Db, arena: std.mem.Allocator, schema: []const u8) db.Error![]db.Object {
		if (schema.len != 0 and !std.mem.eql(u8, schema, self.cwd)) {
			const conn = self.conn orelse return error.Driver;
			const where = ssh.realpath(conn, self.home.allocator(), schema) catch schema;
			const what = ssh.stat(conn, where) catch return self.fromServer();
			if (!what.isDir()) {
				self.complain("{s} is a file, not a directory", .{where});
				return error.Driver;
			}
			self.cwd = where;
			self.relabel();
		}
		var out: std.ArrayListUnmanaged(db.Object) = .empty;
		try out.append(arena, .{
			.schema = try arena.dupe(u8, self.cwd),
			.name = try arena.dupe(u8, address.basename(self.cwd)),
			.kind = .table,
		});
		return out.items;
	}

	pub fn columns(_: *Db, arena: std.mem.Allocator, _: db.Table) db.Error![]db.Column {
		var out: std.ArrayListUnmanaged(db.Column) = .empty;
		try out.append(arena, .{ .name = NAME, .type = "string", .notnull = true, .pk = true, .original = NAME });
		try out.append(arena, .{ .name = SIZE, .type = "integer", .original = SIZE });
		try out.append(arena, .{ .name = KIND, .type = "string", .original = KIND });
		try out.append(arena, .{ .name = MODIFIED, .type = "timestamp", .original = MODIFIED });
		try out.append(arena, .{ .name = MODE, .type = "string", .original = MODE });
		try out.append(arena, .{ .name = OWNER, .type = "string", .original = OWNER });
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

	/// Exact, because the whole directory is here.
	pub fn rowCount(self: *Db, table: db.Table) ?i64 {
		const conn = self.conn orelse return null;
		var scratch = std.heap.ArenaAllocator.init(self.allocator);
		defer scratch.deinit();
		const entries = ssh.readDir(conn, scratch.allocator(), self.directoryOf(table), ENTRIES) catch return null;
		return @intCast(entries.len);
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
		try out.append(arena, .{ .label = "host", .value = try std.fmt.allocPrint(arena, "{s}:{d}", .{ self.parts.host, self.parts.port }) });
		try out.append(arena, .{ .label = "user", .value = self.parts.user });
		try out.append(arena, .{ .label = "directory", .value = self.cwd });
		try out.append(arena, .{ .label = "host key", .value = if (self.parts.verify) "checked against ~/.ssh/known_hosts" else "not checked - insecure=1" });
		try out.append(arena, .{ .label = "transport", .value = try std.fmt.allocPrint(arena, "libssh2 {s}", .{ssh.version.text()}) });
		try out.append(arena, .{ .label = "listings read", .value = try std.fmt.allocPrint(arena, "{d}", .{self.requests}) });
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
		return .{ .sftp = .{} };
	}

	// -------------------------------------------------------------- console

	fn console(self: *Db, line: []const u8) db.Error!Rows {
		const conn = self.conn orelse return error.Driver;
		var scratch = std.heap.ArenaAllocator.init(self.allocator);
		defer scratch.deinit();
		const arena = scratch.allocator();
		const args = try splitCommand(arena, line);
		if (args.len == 0) {
			return self.oneText("sftp", "");
		}
		const command = args[0];

		if (eql(command, "HELP") or eql(command, "?")) {
			return self.help();
		}
		if (eql(command, "PWD")) {
			return self.oneText("directory", self.cwd);
		}
		if (eql(command, "CD")) {
			const wanted = if (args.len > 1) args[1] else "~";
			const path = if (std.mem.eql(u8, wanted, "~"))
				"."
			else
				try self.at(arena, wanted);
			const where = ssh.realpath(conn, self.home.allocator(), path) catch return self.fromServer();
			const what = ssh.stat(conn, where) catch return self.fromServer();
			if (!what.isDir()) {
				self.complain("{s} is a file, not a directory", .{where});
				return error.Driver;
			}
			self.cwd = where;
			self.relabel();
			return self.oneText("directory", self.cwd);
		}
		if (eql(command, "LS") or eql(command, "LIST") or eql(command, "DIR")) {
			const where = if (args.len > 1) try self.at(arena, args[1]) else self.cwd;
			const replies = self.replies.allocator();
			self.requests += 1;
			const entries = ssh.readDir(conn, replies, where, ENTRIES) catch return self.fromServer();
			std.mem.sort(ssh.Entry, entries, Sorting{ .by = .name, .descending = false }, lessThan);
			var rows = self.newRows(.{ .schema = where, .name = address.basename(where) });
			var buffer: [10]u8 = undefined;
			for (entries) |entry| {
				try rows.add(&.{
					.{ .text = entry.name },
					.{ .number = @intCast(entry.attributes.filesize) },
					.{ .text = kindOf(entry.attributes) },
					.{ .text = try address.stamp(replies, entry.attributes.mtime) },
					.{ .text = try replies.dupe(u8, address.mode(&buffer, entry.attributes.permissions)) },
					.{ .text = try std.fmt.allocPrint(replies, "{d}:{d}", .{ entry.attributes.uid, entry.attributes.gid }) },
				});
			}
			return rows;
		}

		if (args.len < 2) {
			self.complain("{s} needs something to work on - try HELP", .{command});
			return error.Driver;
		}
		const path = try self.at(arena, args[1]);

		if (eql(command, "GET") or eql(command, "CAT")) {
			const replies = self.replies.allocator();
			const bytes = ssh.readFile(conn, replies, path, GET_LIMIT) catch return self.fromServer();
			var rows = self.newNamed(&.{ NAME, SIZE, "value" }, &.{ false, true, false });
			try rows.add(&.{
				.{ .text = try replies.dupe(u8, args[1]) },
				.{ .number = @intCast(bytes.len) },
				if (readable(bytes)) .{ .text = bytes } else .{ .blob = bytes },
			});
			return rows;
		}
		if (eql(command, "PUT")) {
			ssh.writeFile(conn, path, if (args.len > 2) args[2] else "") catch return self.fromServer();
			return self.oneText("written", path);
		}
		if (eql(command, "RM") or eql(command, "DEL")) {
			const what = ssh.stat(conn, path) catch return self.fromServer();
			ssh.remove(conn, path, what.isDir()) catch return self.fromServer();
			return self.oneText("removed", path);
		}
		if (eql(command, "MKDIR")) {
			ssh.makeDir(conn, path, 0o755) catch return self.fromServer();
			return self.oneText("created", path);
		}
		if (eql(command, "MV") or eql(command, "RENAME")) {
			if (args.len < 3) {
				self.remember("MV takes what to move and where to");
				return error.Driver;
			}
			const to = try self.at(arena, args[2]);
			ssh.rename(conn, path, to) catch return self.fromServer();
			return self.oneText("moved", to);
		}
		if (eql(command, "CHMOD")) {
			if (args.len < 3) {
				self.remember("CHMOD takes a mode and a name: CHMOD 644 notes.txt");
				return error.Driver;
			}
			const bits = address.parseMode(args[1]) orelse {
				self.complain("{s} is not a mode - try 644 or rw-r--r--", .{args[1]});
				return error.Driver;
			};
			const which = try self.at(arena, args[2]);
			ssh.chmod(conn, which, bits) catch return self.fromServer();
			return self.oneText("mode changed", which);
		}
		if (eql(command, "STAT")) {
			const what = ssh.stat(conn, path) catch return self.fromServer();
			var rows = self.newNamed(&.{ "fact", "value" }, &.{ false, false });
			const replies = self.replies.allocator();
			var buffer: [10]u8 = undefined;
			try rows.add(&.{ .{ .text = "path" }, .{ .text = try replies.dupe(u8, path) } });
			try rows.add(&.{ .{ .text = "kind" }, .{ .text = kindOf(what) } });
			try rows.add(&.{ .{ .text = "size" }, .{ .number = @intCast(what.filesize) } });
			try rows.add(&.{ .{ .text = "mode" }, .{ .text = try replies.dupe(u8, address.mode(&buffer, what.permissions)) } });
			try rows.add(&.{ .{ .text = "owner" }, .{ .text = try std.fmt.allocPrint(replies, "{d}:{d}", .{ what.uid, what.gid }) } });
			try rows.add(&.{ .{ .text = "modified" }, .{ .text = try address.stamp(replies, what.mtime) } });
			return rows;
		}
		self.complain("no such command: {s} - try HELP", .{command});
		return error.Driver;
	}

	fn help(self: *Db) db.Error!Rows {
		var rows = self.newNamed(&.{ "command", "what it does" }, &.{ false, false });
		const LINES = [_][2][]const u8{
			.{ "LS [path]", "a directory" },
			.{ "CD path", "go there; PWD says where that is" },
			.{ "GET path", "the file itself, shown as a value" },
			.{ "PUT path [text]", "write a file" },
			.{ "RM path", "remove a file or an empty directory" },
			.{ "MKDIR path", "" },
			.{ "MV from to", "a real rename, not a copy" },
			.{ "CHMOD 644 path", "or CHMOD rw-r--r-- path" },
			.{ "STAT path", "what the server says about it" },
		};
		for (LINES) |line| {
			try rows.add(&.{ .{ .text = line[0] }, .{ .text = line[1] } });
		}
		return rows;
	}

	// ----------------------------------------------------------------- rows

	fn newRows(self: *Db, table: db.Table) Rows {
		return .{
			.owner = self,
			.names = &COLUMNS,
			.numeric = &NUMERIC,
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

// ------------------------------------------------------------------ sorting

const Order = enum { name, size, modified };

const Sorting = struct {
	by: Order,
	descending: bool,
};

fn lessThan(sorting: Sorting, left: ssh.Entry, right: ssh.Entry) bool {
	const first = switch (sorting.by) {
		.name => std.mem.order(u8, left.name, right.name) == .lt,
		.size => left.attributes.filesize < right.attributes.filesize,
		.modified => left.attributes.mtime < right.attributes.mtime,
	};
	if (sorting.by != .name) {
		const same = switch (sorting.by) {
			.size => left.attributes.filesize == right.attributes.filesize,
			.modified => left.attributes.mtime == right.attributes.mtime,
			else => false,
		};
		// A directory full of files of the same size is otherwise in whatever
		// order the server felt like, which changes between screens.
		if (same) {
			return std.mem.order(u8, left.name, right.name) == .lt;
		}
	}
	return if (sorting.descending) !first else first;
}

/// `%` and `_` as SQL means them, anywhere in the pattern - which this driver can
/// honour because the whole listing is here, and an object store cannot.
///
/// A run of `%` is one `%`: without that, `%%%%%%%%%%x` typed into the filter
/// row backtracks for a very long time over a name that does not match.
pub fn like(pattern: []const u8, text: []const u8) bool {
	if (pattern.len == 0) {
		return text.len == 0;
	}
	switch (pattern[0]) {
		'%' => {
			var rest = pattern[1..];
			while (rest.len != 0 and rest[0] == '%') {
				rest = rest[1..];
			}
			if (rest.len == 0) {
				return true;
			}
			var at: usize = 0;
			while (at <= text.len) : (at += 1) {
				if (like(rest, text[at..])) {
					return true;
				}
			}
			return false;
		},
		'_' => return text.len != 0 and like(pattern[1..], text[1..]),
		else => return text.len != 0 and text[0] == pattern[0] and like(pattern[1..], text[1..]),
	}
}

fn kindOf(attributes: ssh.Attributes) []const u8 {
	if (attributes.isDir()) {
		return "dir";
	}
	if (attributes.isLink()) {
		return "link";
	}
	return "file";
}

fn readable(bytes: []const u8) bool {
	if (bytes.len == 0) {
		return true;
	}
	if (!std.unicode.utf8ValidateSlice(bytes)) {
		return false;
	}
	for (bytes) |byte| {
		if (byte < 0x20 and byte != '\t' and byte != '\n' and byte != '\r') {
			return false;
		}
	}
	return true;
}

fn eql(left: []const u8, right: []const u8) bool {
	return std.ascii.eqlIgnoreCase(left, right);
}

fn flat(value: ??[]const u8) ?[]const u8 {
	const inner = value orelse return null;
	return inner orelse null;
}

fn splitCommand(arena: std.mem.Allocator, text: []const u8) ![]const []const u8 {
	var out: std.ArrayListUnmanaged([]const u8) = .empty;
	var at: usize = 0;
	while (at < text.len) {
		while (at < text.len and (text[at] == ' ' or text[at] == '\t')) : (at += 1) {}
		if (at >= text.len) {
			break;
		}
		if (text[at] == '"' or text[at] == '\'') {
			const quote = text[at];
			at += 1;
			const start = at;
			while (at < text.len and text[at] != quote) : (at += 1) {}
			try out.append(arena, text[start..at]);
			if (at < text.len) {
				at += 1;
			}
			continue;
		}
		const start = at;
		while (at < text.len and text[at] != ' ' and text[at] != '\t') : (at += 1) {}
		try out.append(arena, text[start..at]);
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

/// A filesystem has no schema to define. What it has - a directory - is made
/// with MKDIR, and the rest say so.
pub const Ddl = struct {
	pub fn types(_: Ddl) []const []const u8 {
		return &[_][]const u8{ "file", "dir" };
	}

	fn refuse(out: *List, a: std.mem.Allocator, what: []const u8) !void {
		try out.appendSlice(a, "-- a filesystem has no ");
		try out.appendSlice(a, what);
		try out.appendSlice(a, ", so nothing was done\n");
	}

	pub fn createTable(_: Ddl, out: *List, a: std.mem.Allocator, table: db.Table, _: []const db.Column, _: []const db.ForeignKey) !void {
		// The one that does mean something: a table here is a directory.
		try out.print(a, "MKDIR {s}\n", .{table.name});
	}

	pub fn alterTable(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table, _: []const u8, _: []const db.Column, _: db.AlterContext) !void {
		try refuse(out, a, "columns to alter: a file is a name and its bytes");
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

	pub fn renameTable(_: Ddl, out: *List, a: std.mem.Allocator, table: db.Table, to: []const u8) !void {
		try out.print(a, "MV {s} {s}\n", .{ table.name, to });
	}

	pub fn copyTable(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table, _: []const u8, _: bool) !void {
		try refuse(out, a, "way to copy a directory in one request");
	}

	pub fn dropObject(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Kind, table: db.Table) !void {
		try out.print(a, "RM {s}\n", .{table.name});
	}

	pub fn truncate(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table) !void {
		try refuse(out, a, "way to empty a directory in one request");
	}
};

// ------------------------------------------------------------------- tests

const testing = std.testing;

test "LIKE means what SQL means by it, in the middle as well" {
	try testing.expect(like("%.txt", "notes.txt"));
	try testing.expect(like("notes%", "notes.txt"));
	// The one an object store cannot do, which is why it is here.
	try testing.expect(like("%trip%", "august trip.jpg"));
	try testing.expect(like("_otes.txt", "notes.txt"));
	try testing.expect(like("%", "anything"));
	try testing.expect(like("", ""));
	try testing.expect(!like("%.txt", "notes.md"));
	try testing.expect(!like("_otes.txt", "quotes.txt"));
	try testing.expect(!like("", "something"));
	// A row of wildcards is one wildcard. Without that this takes longer than
	// anybody will wait, on a name that does not match.
	try testing.expect(like("%%%%%%%%%%%%%%%%%%%%", "a name with no match in it"));
	try testing.expect(!like("%%%%%%%%%%%%%%%%%%%%z", "a name with no match in it"));
	try testing.expect(like("%%trip%%", "august trip.jpg"));
}

test "a listing sorts by what was asked for, and by name to break a tie" {
	var entries = [_]ssh.Entry{
		.{ .name = "b.txt", .attributes = .{ .filesize = 10, .mtime = 200 } },
		.{ .name = "a.txt", .attributes = .{ .filesize = 10, .mtime = 100 } },
		.{ .name = "c.txt", .attributes = .{ .filesize = 5, .mtime = 300 } },
	};
	std.mem.sort(ssh.Entry, &entries, Sorting{ .by = .size, .descending = false }, lessThan);
	try testing.expectEqualStrings("c.txt", entries[0].name);
	// Same size, so the name decides - and the order does not change between one
	// screen and the next.
	try testing.expectEqualStrings("a.txt", entries[1].name);
	try testing.expectEqualStrings("b.txt", entries[2].name);

	std.mem.sort(ssh.Entry, &entries, Sorting{ .by = .name, .descending = true }, lessThan);
	try testing.expectEqualStrings("c.txt", entries[0].name);
	try testing.expectEqualStrings("a.txt", entries[2].name);

	std.mem.sort(ssh.Entry, &entries, Sorting{ .by = .modified, .descending = true }, lessThan);
	try testing.expectEqualStrings("c.txt", entries[0].name);
	try testing.expectEqualStrings("a.txt", entries[2].name);
}

test "what a row is called by its permission bits" {
	try testing.expectEqualStrings("dir", kindOf(.{ .permissions = ssh.S_IFDIR | 0o755 }));
	try testing.expectEqualStrings("file", kindOf(.{ .permissions = ssh.S_IFREG | 0o644 }));
	try testing.expectEqualStrings("link", kindOf(.{ .permissions = ssh.S_IFLNK }));
	try testing.expectEqualStrings("file", kindOf(.{}));
}

test "a command line comes apart the way a shell would do it" {
	var scratch = std.heap.ArenaAllocator.init(testing.allocator);
	defer scratch.deinit();
	const args = try splitCommand(scratch.allocator(), "PUT \"august trip.txt\" 'ahoj, svete'");
	try testing.expectEqual(@as(usize, 3), args.len);
	try testing.expectEqualStrings("august trip.txt", args[1]);
	try testing.expectEqualStrings("ahoj, svete", args[2]);
}

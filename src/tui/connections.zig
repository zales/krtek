//! Saved connections.
//!
//! A tab separated file under the user's config directory, one connection per
//! line, most recently used first:
//!
//!     name<TAB>target[<TAB>password=secret | <TAB>keychain]
//!
//! Plain text on purpose - it is meant to be readable and editable by hand.
//!
//! **Where a password is kept is chosen per connection**, and by default it is
//! kept nowhere: there is no third field and the password is asked for on
//! connecting. `password=…` means it is in this file, *in plain text*, with the
//! file written mode 0600 - that is the whole protection, so anything running as
//! this user can read it. `keychain` means it is in the macOS keychain and this
//! file holds nothing but the word; see [keychain.zig](keychain.zig). Where an
//! engine has its own password store - `~/.pgpass` for libpq, `~/.my.cnf` for
//! MySQL - that is better still, and it keeps working either way.
//!
//! Whatever happens, a password never ends up in the *target*: `withoutPassword`
//! strips it out of the URL before the line is written, so the readable half of
//! the file stays readable.

const std = @import("std");

/// Where a connection's password lives.
pub const Keeps = enum {
	/// Nowhere: the app asks when the server does.
	ask,
	/// In this file, in plain text.
	file,
	/// In the macOS keychain, under the target as the account.
	keychain,

	pub fn label(self: Keeps) []const u8 {
		return switch (self) {
			.ask => "",
			.file => "in file",
			.keychain => "keychain",
		};
	}
};

pub const Connection = struct {
	name: []const u8,
	target: []const u8,
	keeps: Keeps = .ask,
	/// The password, for `.file` only - the keychain holds its own.
	secret: []const u8 = "",

	/// Does this connection keep its password somewhere?
	pub fn remembers(self: Connection) bool {
		return self.keeps != .ask;
	}

	/// What kind of thing this points at, for the listing.
	pub fn engine(self: Connection) []const u8 {
		if (std.ascii.startsWithIgnoreCase(self.target, "redis://") or
			std.ascii.startsWithIgnoreCase(self.target, "rediss://"))
		{
			return "Redis";
		}
		for ([_][]const u8{ "kafka://", "kafka+ssl://", "kafka+tls://", "kafkas://" }) |prefix| {
			if (std.ascii.startsWithIgnoreCase(self.target, prefix)) {
				return "Kafka";
			}
		}
		if (std.ascii.startsWithIgnoreCase(self.target, "mysql://") or
			std.ascii.startsWithIgnoreCase(self.target, "mariadb://"))
		{
			return "MySQL";
		}
		if (std.ascii.startsWithIgnoreCase(self.target, "postgres://") or
			std.ascii.startsWithIgnoreCase(self.target, "postgresql://") or
			std.mem.indexOf(u8, self.target, "dbname=") != null or
			std.mem.indexOf(u8, self.target, "host=") != null)
		{
			return "PostgreSQL";
		}
		return "SQLite";
	}
};

pub const List = struct {
	allocator: std.mem.Allocator,
	arena: std.heap.ArenaAllocator,
	items: std.ArrayListUnmanaged(Connection) = .empty,
	/// Set when the last save had to drop a password.
	stripped: bool = false,

	pub fn init(allocator: std.mem.Allocator) List {
		return .{ .allocator = allocator, .arena = std.heap.ArenaAllocator.init(allocator) };
	}

	pub fn deinit(self: *List) void {
		self.items.deinit(self.allocator);
		self.arena.deinit();
	}

	/// Put a connection at the front. `keeps` null means "whatever the entry being
	/// replaced said", which is what a plain reconnect wants.
	pub fn add(self: *List, name: []const u8, target: []const u8, keeps: ?Keeps, secret: []const u8) !void {
		const a = self.arena.allocator();
		// Either the name or the target identifies an entry, so renaming a
		// connection or pointing an existing name somewhere else replaces it
		// instead of leaving the list with two rows for one database.
		var how: ?Keeps = keeps;
		var kept: []const u8 = secret;
		var i = self.items.items.len;
		while (i > 0) {
			i -= 1;
			const item = self.items.items[i];
			if (std.mem.eql(u8, item.name, name) or std.mem.eql(u8, item.target, target)) {
				// Replacing an entry keeps what it already had, unless the caller
				// brought something; otherwise every reconnect would forget it.
				if (how == null) {
					how = item.keeps;
					kept = item.secret;
				}
				_ = self.items.orderedRemove(i);
			}
		}
		try self.items.insert(self.allocator, 0, .{
			.name = try a.dupe(u8, name),
			.target = try a.dupe(u8, target),
			.keeps = how orelse .ask,
			.secret = try a.dupe(u8, kept),
		});
	}

	/// Say where the connection at `index` keeps its password, and what it is.
	pub fn keep(self: *List, index: usize, keeps: Keeps, secret: []const u8) !void {
		if (index >= self.items.items.len) {
			return;
		}
		self.items.items[index].keeps = keeps;
		self.items.items[index].secret = try self.arena.allocator().dupe(u8, secret);
	}

	pub fn remove(self: *List, index: usize) void {
		if (index < self.items.len()) {
			_ = self.items.orderedRemove(index);
		}
	}

	/// Move a connection to the front, so the list stays in most-recent order.
	pub fn touch(self: *List, index: usize) void {
		if (index == 0 or index >= self.items.items.len) {
			return;
		}
		const item = self.items.orderedRemove(index);
		self.items.insert(self.allocator, 0, item) catch {};
	}

	pub fn find(self: *List, target: []const u8) ?usize {
		for (self.items.items, 0..) |item, i| {
			if (std.mem.eql(u8, item.target, target)) {
				return i;
			}
		}
		return null;
	}
};

/// `$XDG_CONFIG_HOME/krtek/connections` or `~/.config/…`, into `buffer`.
pub fn path(buffer: []u8, env: *std.process.Environ.Map) ?[]const u8 {
	const dir = env.get("XDG_CONFIG_HOME") orelse blk: {
		const home = env.get("HOME") orelse return null;
		break :blk std.fmt.bufPrint(buffer, "{s}/.config", .{home}) catch return null;
	};
	// The directory may be the same buffer, so the join is written elsewhere.
	var tail: [std.fs.max_path_bytes]u8 = undefined;
	const joined = std.fmt.bufPrint(&tail, "{s}/krtek/connections", .{dir}) catch return null;
	if (joined.len >= buffer.len) {
		return null;
	}
	@memcpy(buffer[0..joined.len], joined);
	return buffer[0..joined.len];
}

/// Read the file; a missing one is simply an empty list.
pub fn load(list: *List, file_path: []const u8) !void {
	list.items.clearRetainingCapacity();
	const text = read(list.arena.allocator(), file_path) catch return;
	var lines = std.mem.splitScalar(u8, text, '\n');
	const a = list.arena.allocator();
	while (lines.next()) |raw| {
		const line = std.mem.trim(u8, raw, " \t\r");
		if (line.len == 0 or line[0] == '#') {
			continue;
		}
		const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
		const name = std.mem.trim(u8, line[0..tab], " \t");
		var rest = line[tab + 1 ..];
		// The third field, if it is there, says where this connection's password is.
		var keeps: Keeps = .ask;
		var secret: []const u8 = "";
		if (std.mem.indexOfScalar(u8, rest, '\t')) |second| {
			const extra = std.mem.trim(u8, rest[second + 1 ..], " \t");
			rest = rest[0..second];
			if (std.mem.startsWith(u8, extra, "password=")) {
				keeps = .file;
				secret = extra["password=".len..];
			} else if (std.mem.eql(u8, extra, "keychain")) {
				keeps = .keychain;
			}
		}
		const target = std.mem.trim(u8, rest, " \t");
		if (name.len == 0 or target.len == 0) {
			continue;
		}
		try list.items.append(list.allocator, .{
			.name = try a.dupe(u8, name),
			.target = try a.dupe(u8, target),
			.keeps = keeps,
			.secret = try a.dupe(u8, secret),
		});
	}
}

/// Write the file, without any password.
pub fn save(list: *List, file_path: []const u8) !void {
	var out: std.ArrayListUnmanaged(u8) = .empty;
	defer out.deinit(list.allocator);
	try out.appendSlice(list.allocator,
		"# krtek connections: name<TAB>target[<TAB>password=secret|<TAB>keychain],\n" ++
		"# most recent first. `password=` is plain text in this file, which is mode\n" ++
		"# 0600; `keychain` means the macOS keychain holds it instead.\n");
	list.stripped = false;
	for (list.items.items) |item| {
		var scratch = std.heap.ArenaAllocator.init(list.allocator);
		defer scratch.deinit();
		const safe = try withoutPassword(scratch.allocator(), item.target);
		if (safe.len != item.target.len) {
			list.stripped = true;
		}
		try out.print(list.allocator, "{s}\t{s}", .{ item.name, safe });
		switch (item.keeps) {
			.ask => {},
			.file => try out.print(list.allocator, "\tpassword={s}", .{item.secret}),
			.keychain => try out.appendSlice(list.allocator, "\tkeychain"),
		}
		try out.append(list.allocator, '\n');
	}
	try mkdirParents(file_path);
	try write(file_path, out.items);
	// Whether or not there is a password in it today, this file says where the
	// databases are; nobody else needs to read it.
	try onlyOwner(file_path);
}

/// Remove the password from a target, whichever way it was written.
pub fn withoutPassword(arena: std.mem.Allocator, target: []const u8) ![]const u8 {
	// A URL: scheme://user:password@host/…?password=…
	if (std.mem.indexOf(u8, target, "://")) |scheme_end| {
		var out: std.ArrayListUnmanaged(u8) = .empty;
		try out.appendSlice(arena, target[0 .. scheme_end + 3]);
		var rest = target[scheme_end + 3 ..];
		// The password in the userinfo, if it is there.
		if (std.mem.indexOfScalar(u8, rest, '@')) |at| {
			const credentials = rest[0..at];
			if (std.mem.indexOfScalar(u8, credentials, ':')) |colon| {
				try out.appendSlice(arena, credentials[0..colon]);
			} else {
				try out.appendSlice(arena, credentials);
			}
			try out.append(arena, '@');
			rest = rest[at + 1 ..];
		}
		// And the one in the query string, which is how this app passes it.
		const query_at = std.mem.indexOfScalar(u8, rest, '?') orelse {
			try out.appendSlice(arena, rest);
			return out.items;
		};
		try out.appendSlice(arena, rest[0..query_at]);
		var kept: usize = 0;
		var parameters = std.mem.tokenizeAny(u8, rest[query_at + 1 ..], "&");
		while (parameters.next()) |parameter| {
			if (std.ascii.startsWithIgnoreCase(parameter, "password=")) {
				continue;
			}
			try out.append(arena, if (kept == 0) '?' else '&');
			try out.appendSlice(arena, parameter);
			kept += 1;
		}
		return out.items;
	}
	// A keyword string: host=… password=… dbname=…
	if (std.mem.indexOf(u8, target, "password=") == null) {
		return target;
	}
	var out: std.ArrayListUnmanaged(u8) = .empty;
	var parts = std.mem.tokenizeAny(u8, target, " \t");
	while (parts.next()) |part| {
		if (std.ascii.startsWithIgnoreCase(part, "password=")) {
			continue;
		}
		if (out.items.len != 0) {
			try out.append(arena, ' ');
		}
		try out.appendSlice(arena, part);
	}
	return out.items;
}

/// Put a password back for one connection attempt, without storing it.
///
/// libpq takes either a URI or a keyword string, never a mixture of the two, so
/// the password goes in the form the target already uses: a URI gets it as a
/// query parameter, which libpq reads as a keyword, and a keyword string gets
/// one more keyword.
pub fn withPassword(arena: std.mem.Allocator, target: []const u8, password: []const u8) ![]const u8 {
	if (password.len == 0) {
		return target;
	}
	var out: std.ArrayListUnmanaged(u8) = .empty;
	try out.appendSlice(arena, target);
	if (std.mem.indexOf(u8, target, "://") != null) {
		try out.appendSlice(arena, if (std.mem.indexOfScalar(u8, target, '?') == null) "?password=" else "&password=");
		for (password) |char| {
			if (std.ascii.isAlphanumeric(char) or char == '-' or char == '.' or char == '_' or char == '~') {
				try out.append(arena, char);
			} else {
				try out.print(arena, "%{X:0>2}", .{char});
			}
		}
		return out.items;
	}
	try out.appendSlice(arena, " password=");
	// Quote it, because a password may contain spaces.
	try out.append(arena, '\'');
	for (password) |char| {
		if (char == '\'' or char == '\\') {
			try out.append(arena, '\\');
		}
		try out.append(arena, char);
	}
	try out.append(arena, '\'');
	return out.items;
}

/// A name suggestion, so adding a connection does not start empty.
pub fn suggestName(arena: std.mem.Allocator, target: []const u8) ![]const u8 {
	if (std.mem.lastIndexOfScalar(u8, target, '/')) |slash| {
		const tail = target[slash + 1 ..];
		if (tail.len != 0) {
			return arena.dupe(u8, tail);
		}
	}
	return arena.dupe(u8, target);
}

// --- file helpers, through libc as elsewhere in this app ---

fn read(arena: std.mem.Allocator, file_path: []const u8) ![]u8 {
	var zero: [std.fs.max_path_bytes]u8 = undefined;
	if (file_path.len >= zero.len) {
		return error.NameTooLong;
	}
	@memcpy(zero[0..file_path.len], file_path);
	zero[file_path.len] = 0;
	const file = std.c.fopen(@ptrCast(&zero), "rb") orelse return error.CannotOpen;
	defer _ = std.c.fclose(file);
	var out: std.ArrayListUnmanaged(u8) = .empty;
	var chunk: [4096]u8 = undefined;
	while (true) {
		const got = std.c.fread(&chunk, 1, chunk.len, file);
		if (got == 0) {
			break;
		}
		try out.appendSlice(arena, chunk[0..got]);
	}
	return out.items;
}

fn write(file_path: []const u8, bytes: []const u8) !void {
	var zero: [std.fs.max_path_bytes]u8 = undefined;
	if (file_path.len >= zero.len) {
		return error.NameTooLong;
	}
	@memcpy(zero[0..file_path.len], file_path);
	zero[file_path.len] = 0;
	const file = std.c.fopen(@ptrCast(&zero), "wb") orelse return error.CannotCreate;
	defer _ = std.c.fclose(file);
	if (bytes.len != 0 and std.c.fwrite(bytes.ptr, 1, bytes.len, file) != bytes.len) {
		return error.WriteFailed;
	}
}

/// `chmod 0600`, so a remembered password is at least not world readable.
fn onlyOwner(file_path: []const u8) !void {
	var zero: [std.fs.max_path_bytes]u8 = undefined;
	if (file_path.len >= zero.len) {
		return error.NameTooLong;
	}
	@memcpy(zero[0..file_path.len], file_path);
	zero[file_path.len] = 0;
	_ = std.c.chmod(@ptrCast(&zero), 0o600);
}

/// Create the directories above `file_path`, ignoring the ones that exist.
fn mkdirParents(file_path: []const u8) !void {
	var zero: [std.fs.max_path_bytes]u8 = undefined;
	var at: usize = 1;
	while (std.mem.indexOfScalarPos(u8, file_path, at, '/')) |slash| {
		at = slash + 1;
		if (slash >= zero.len) {
			return error.NameTooLong;
		}
		@memcpy(zero[0..slash], file_path[0..slash]);
		zero[slash] = 0;
		_ = std.c.mkdir(@ptrCast(&zero), 0o755);
	}
}

test "the file round trips, and the target never carries the password" {
	const file = "/tmp/krtek-connections-test";
	var list = List.init(std.testing.allocator);
	defer list.deinit();
	// One that keeps its password, one that does not, and one that gave its
	// password in the URL - which is stripped either way.
	try list.add("kept", "mysql://root@h:3307/demo", .file, "hunter2");
	try list.add("asks", "postgres://u@h/d", .ask, "");
	try list.add("in the url", "postgres://u:leaked@h2/d", .file, "hunter3");
	try list.add("by macos", "redis://h/0", .keychain, "");
	try save(&list, file);

	const written = try read(list.arena.allocator(), file);
	try std.testing.expect(std.mem.indexOf(u8, written, "leaked") == null);
	try std.testing.expect(std.mem.indexOf(u8, written, "password=hunter2") != null);
	try std.testing.expect(std.mem.indexOf(u8, written, "asks\tpostgres://u@h/d\n") != null);

	try std.testing.expect(std.mem.indexOf(u8, written, "by macos\tredis://h/0\tkeychain\n") != null);

	var again = List.init(std.testing.allocator);
	defer again.deinit();
	try load(&again, file);
	try std.testing.expectEqual(@as(usize, 4), again.items.items.len);
	for (again.items.items) |item| {
		try std.testing.expect(std.mem.indexOf(u8, item.target, "leaked") == null);
		if (std.mem.eql(u8, item.name, "kept")) {
			try std.testing.expectEqualStrings("hunter2", item.secret);
		}
		if (std.mem.eql(u8, item.name, "asks")) {
			try std.testing.expect(!item.remembers());
		}
		if (std.mem.eql(u8, item.name, "by macos")) {
			try std.testing.expectEqual(Keeps.keychain, item.keeps);
			// The keychain holds it, so the file holds nothing.
			try std.testing.expectEqualStrings("", item.secret);
		}
	}
	_ = std.c.unlink(file);
}

test "a password is never written out" {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();
	const a = arena.allocator();

	try std.testing.expectEqualStrings(
		"postgres://user@host:5432/db",
		try withoutPassword(a, "postgres://user:secret@host:5432/db"),
	);
	try std.testing.expectEqualStrings(
		"postgres://user@host/db",
		try withoutPassword(a, "postgres://user@host/db"),
	);
	try std.testing.expectEqualStrings(
		"host=h dbname=d user=u",
		try withoutPassword(a, "host=h password=secret dbname=d user=u"),
	);
	try std.testing.expectEqualStrings(
		"postgres://u@h/d",
		try withoutPassword(a, "postgres://u@h/d?password=secret"),
	);
	try std.testing.expectEqualStrings(
		"postgres://u@h/d?sslmode=require",
		try withoutPassword(a, "postgres://u@h/d?password=secret&sslmode=require"),
	);
	// A file path is left exactly as it is.
	try std.testing.expectEqualStrings("/tmp/my.db", try withoutPassword(a, "/tmp/my.db"));
}

test "a password is added quoted, for one attempt" {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();
	const a = arena.allocator();
	// A URI takes it as a query parameter, escaped.
	try std.testing.expectEqualStrings(
		"postgres://u@h/d?password=pa%20ss",
		try withPassword(a, "postgres://u@h/d", "pa ss"),
	);
	try std.testing.expectEqualStrings(
		"postgres://u@h/d?sslmode=require&password=it%27s",
		try withPassword(a, "postgres://u@h/d?sslmode=require", "it's"),
	);
	// A keyword string takes one more keyword, quoted.
	try std.testing.expectEqualStrings(
		"host=h dbname=d password='pa ss'",
		try withPassword(a, "host=h dbname=d", "pa ss"),
	);
	try std.testing.expectEqualStrings("x", try withPassword(a, "x", ""));
}

test "the engine is told from the target" {
	try std.testing.expectEqualStrings("Redis", (Connection{ .name = "a", .target = "redis://h/0" }).engine());
	try std.testing.expectEqualStrings("Kafka", (Connection{ .name = "a", .target = "kafka://h:9092" }).engine());
	try std.testing.expectEqualStrings("Kafka", (Connection{ .name = "a", .target = "kafka+ssl://h:9093" }).engine());
	try std.testing.expectEqualStrings("MySQL", (Connection{ .name = "a", .target = "mysql://h/d" }).engine());
	try std.testing.expectEqualStrings("MySQL", (Connection{ .name = "a", .target = "mariadb://h/d" }).engine());
	try std.testing.expectEqualStrings("PostgreSQL", (Connection{ .name = "a", .target = "postgres://h/d" }).engine());
	try std.testing.expectEqualStrings("PostgreSQL", (Connection{ .name = "a", .target = "host=h dbname=d" }).engine());
	try std.testing.expectEqualStrings("SQLite", (Connection{ .name = "a", .target = "notes.db" }).engine());
}

test "a password is kept only when the connection asks for one" {
	var list = List.init(std.testing.allocator);
	defer list.deinit();
	try list.add("plain", "postgres://u@h/d", .ask, "");
	try list.add("kept", "postgres://u@h2/d", .file, "hunter2");
	try std.testing.expect(!list.items.items[1].remembers());
	try std.testing.expect(list.items.items[0].remembers());
	try std.testing.expectEqualStrings("hunter2", list.items.items[0].secret);

	// Reconnecting replaces the entry, and what it kept survives that.
	try list.add("kept", "postgres://u@h2/d", null, "");
	try std.testing.expectEqualStrings("hunter2", list.items.items[0].secret);
	try std.testing.expectEqual(Keeps.file, list.items.items[0].keeps);

	// And it can be taken away again.
	try list.keep(0, .ask, "");
	try std.testing.expect(!list.items.items[0].remembers());
}

test "the list keeps the most recent first and replaces by name" {
	var list = List.init(std.testing.allocator);
	defer list.deinit();
	try list.add("one", "a.db", .ask, "");
	try list.add("two", "b.db", .ask, "");
	try std.testing.expectEqualStrings("two", list.items.items[0].name);
	try list.add("one", "c.db", .ask, ""); // same name, new target, back to the front
	try std.testing.expectEqual(@as(usize, 2), list.items.items.len);
	try std.testing.expectEqualStrings("one", list.items.items[0].name);
	try std.testing.expectEqualStrings("c.db", list.items.items[0].target);
	list.touch(1);
	try std.testing.expectEqualStrings("two", list.items.items[0].name);
}

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
	/// Not from this file: found somewhere else that already describes it, which
	/// today means a context in a kubeconfig. It is offered like any other
	/// connection and is nobody's to save or remove from here - the file it came
	/// from is where it lives, and writing a copy into this one would leave two
	/// places to change a cluster's name.
	found: bool = false,

	/// Does this connection keep its password somewhere?
	pub fn remembers(self: Connection) bool {
		return self.keeps != .ask;
	}

	/// What kind of thing this points at, for the listing.
	pub fn engine(self: Connection) []const u8 {
		return engineOf(self.target).label();
	}
};

// ------------------------------------------------ what a target is made of
//
// Nobody should have to remember a URL to add a connection. The form asks which
// engine first and then for the parts that engine has - a host, a database, a
// bucket - and puts the target together itself.
//
// The rule that makes that safe: a target is only taken apart when putting it
// back together gives *exactly* what came in. Anything else - a query nobody
// modelled, a libpq keyword string, an `amqp://` url - is left as the one field
// it always was, so editing a connection can never quietly rewrite it.

pub const Engine = enum {
	sqlite,
	postgres,
	mysql,
	mssql,
	redis,
	kafka,
	s3,
	azure,
	rabbit,
	sftp,
	k8s,
	/// Whatever this does not model: the target as it stands.
	other,

	pub fn label(self: Engine) []const u8 {
		return switch (self) {
			.sqlite => "SQLite",
			.postgres => "PostgreSQL",
			.mysql => "MySQL",
			.mssql => "SQL Server",
			.redis => "Redis",
			.kafka => "Kafka",
			.s3 => "S3",
			.azure => "Azure",
			.rabbit => "RabbitMQ",
			.sftp => "SFTP",
			.k8s => "Kubernetes",
			.other => "target",
		};
	}

	pub fn of(name: []const u8) Engine {
		inline for (@typeInfo(Engine).@"enum".fields) |item| {
			const value: Engine = @enumFromInt(item.value);
			if (std.ascii.eqlIgnoreCase(value.label(), name)) {
				return value;
			}
		}
		return .other;
	}
};

/// In the order the form offers them, most used first.
pub const ENGINES = [_][]const u8{
	"SQLite", "PostgreSQL", "MySQL",      "SQL Server", "Redis",  "Kafka",
	"S3",     "Azure",      "RabbitMQ",   "SFTP",       "Kubernetes",
	"target",
};

test "the engine list offers every engine there is" {
	// A member added to `Engine` and forgotten here is one nobody can pick in the
	// connection form, which is a thing that has happened.
	inline for (@typeInfo(Engine).@"enum".fields) |item| {
		const engine: Engine = @enumFromInt(item.value);
		var found = false;
		for (ENGINES) |name| {
			if (std.mem.eql(u8, name, engine.label())) {
				found = true;
			}
		}
		if (!found) {
			std.debug.print("the connection form cannot pick {s}\n", .{engine.label()});
			return error.TestUnexpectedResult;
		}
	}
	try std.testing.expectEqual(@typeInfo(Engine).@"enum".fields.len, ENGINES.len);
}

pub fn engineOf(target: []const u8) Engine {
	if (std.ascii.startsWithIgnoreCase(target, "redis://") or
		std.ascii.startsWithIgnoreCase(target, "rediss://"))
	{
		return .redis;
	}
	for ([_][]const u8{ "kafka://", "kafka+ssl://", "kafka+tls://", "kafkas://" }) |prefix| {
		if (std.ascii.startsWithIgnoreCase(target, prefix)) {
			return .kafka;
		}
	}
	for ([_][]const u8{ "s3://", "s3+http://", "s3+https://", "s3s://" }) |prefix| {
		if (std.ascii.startsWithIgnoreCase(target, prefix)) {
			return .s3;
		}
	}
	for ([_][]const u8{ "azure://", "azure+http://", "azure+https://", "blob://" }) |prefix| {
		if (std.ascii.startsWithIgnoreCase(target, prefix)) {
			return .azure;
		}
	}
	// The connection string the Azure portal hands out, which is a target too.
	if (std.mem.indexOf(u8, target, "AccountName=") != null and
		std.mem.indexOf(u8, target, "AccountKey=") != null)
	{
		return .azure;
	}
	for ([_][]const u8{ "rabbit://", "rabbitmq://", "rabbit+tls://", "rabbits://", "rabbitmq+tls://", "amqp://", "amqps://" }) |prefix| {
		if (std.ascii.startsWithIgnoreCase(target, prefix)) {
			return .rabbit;
		}
	}
	for ([_][]const u8{ "sftp://", "ssh://", "scp://" }) |prefix| {
		if (std.ascii.startsWithIgnoreCase(target, prefix)) {
			return .sftp;
		}
	}
	for ([_][]const u8{ "k8s://", "kubernetes://", "kube://" }) |prefix| {
		if (std.ascii.startsWithIgnoreCase(target, prefix)) {
			return .k8s;
		}
	}
	if (std.ascii.startsWithIgnoreCase(target, "mysql://") or
		std.ascii.startsWithIgnoreCase(target, "mariadb://"))
	{
		return .mysql;
	}
	if (std.ascii.startsWithIgnoreCase(target, "mssql://") or
		std.ascii.startsWithIgnoreCase(target, "sqlserver://"))
	{
		return .mssql;
	}
	if (std.ascii.startsWithIgnoreCase(target, "postgres://") or
		std.ascii.startsWithIgnoreCase(target, "postgresql://") or
		std.mem.indexOf(u8, target, "dbname=") != null or
		std.mem.indexOf(u8, target, "host=") != null)
	{
		return .postgres;
	}
	return .sqlite;
}

/// The parts of a target, as the form asks for them. One field per idea rather
/// than one per engine: what follows the host is a database on PostgreSQL, an
/// index on Redis, a vhost on RabbitMQ and a bucket on S3, and the form only has
/// to call it the right thing.
pub const Shape = struct {
	engine: Engine = .sqlite,
	/// A user, or S3's access key.
	user: []const u8 = "",
	host: []const u8 = "",
	port: []const u8 = "",
	name: []const u8 = "",
	/// A file path for SQLite, and the whole target for `other`.
	path: []const u8 = "",
	/// S3 only.
	region: []const u8 = "",
	/// Kafka only.
	mechanism: []const u8 = "",
	/// SFTP's private key file, and whether the host key is checked at all.
	key: []const u8 = "",
	insecure: bool = false,
	tls: bool = false,
};

/// The target these parts make.
pub fn compose(arena: std.mem.Allocator, shape: Shape) ![]const u8 {
	switch (shape.engine) {
		.sqlite, .other => return shape.path,
		else => {},
	}
	var out: std.ArrayListUnmanaged(u8) = .empty;
	try out.appendSlice(arena, switch (shape.engine) {
		.postgres => "postgres://",
		.mysql => "mysql://",
		.mssql => "mssql://",
		.redis => "redis://",
		.kafka => if (shape.tls) "kafka+ssl://" else "kafka://",
		// S3 and Azure are TLS unless somebody says otherwise, which is the other
		// way round from the rest: a bucket on the open internet is the usual case.
		.s3 => if (shape.tls) "s3://" else "s3+http://",
		.azure => if (shape.tls) "azure://" else "azure+http://",
		.rabbit => if (shape.tls) "rabbits://" else "rabbit://",
		.sftp => "sftp://",
		.k8s => "k8s://",
		else => "",
	});
	if (shape.user.len != 0) {
		try out.print(arena, "{s}@", .{shape.user});
	}
	// On S3 and Azure the host is the server, and without one the bucket or the
	// container takes its place: `s3://photos` is a bucket on Amazon.
	const host = if ((shape.engine == .s3 or shape.engine == .azure) and shape.host.len == 0)
		shape.name
	else
		shape.host;
	try out.appendSlice(arena, host);
	if (shape.port.len != 0) {
		try out.print(arena, ":{s}", .{shape.port});
	}
	if (shape.name.len != 0 and host.ptr != shape.name.ptr) {
		try out.print(arena, "/{s}", .{shape.name});
	}
	if (shape.engine == .s3 and shape.region.len != 0) {
		try out.print(arena, "?region={s}", .{shape.region});
	}
	if (shape.engine == .kafka and shape.mechanism.len != 0) {
		try out.print(arena, "?mechanism={s}", .{shape.mechanism});
	}
	if (shape.engine == .k8s) {
		// Everything else about a cluster is in the kubeconfig; a target that
		// repeated any of it would be a second place for it to be wrong.
		out.clearRetainingCapacity();
		try out.appendSlice(arena, "k8s://");
		try out.appendSlice(arena, shape.host);
		if (shape.name.len != 0) {
			try out.print(arena, "/{s}", .{shape.name});
		}
		var first = true;
		if (shape.key.len != 0) {
			try out.print(arena, "?kubeconfig={s}", .{shape.key});
			first = false;
		}
		if (shape.insecure) {
			try out.print(arena, "{s}insecure=1", .{if (first) "?" else "&"});
		}
		return out.items;
	}
	if (shape.engine == .sftp) {
		var first = true;
		if (shape.key.len != 0) {
			try out.print(arena, "?key={s}", .{shape.key});
			first = false;
		}
		if (shape.insecure) {
			try out.print(arena, "{s}insecure=1", .{if (first) "?" else "&"});
		}
	}
	return out.items;
}

/// The parts of this target, or null when taking it apart and putting it back
/// together would not give the same string. The caller then leaves it alone.
pub fn decompose(arena: std.mem.Allocator, target: []const u8) ?Shape {
	const engine = engineOf(target);
	var shape = Shape{ .engine = engine };
	switch (engine) {
		.sqlite => shape.path = target,
		.other => return null,
		else => {
			const url = split(target);
			shape.user = url.user;
			shape.host = url.host;
			shape.port = url.port;
			shape.name = url.path;
			shape.tls = switch (engine) {
				.kafka, .rabbit => !std.mem.eql(u8, url.scheme, "kafka") and !std.mem.eql(u8, url.scheme, "rabbit"),
				.s3 => !std.mem.eql(u8, url.scheme, "s3+http"),
				.azure => !std.mem.eql(u8, url.scheme, "azure+http"),
				else => false,
			};
			if (url.query.len != 0) {
				var options = std.mem.splitScalar(u8, url.query, '&');
				while (options.next()) |option| {
					const equals = std.mem.indexOfScalar(u8, option, '=') orelse return null;
					const key = option[0..equals];
					const value = option[equals + 1 ..];
					if (engine == .s3 and std.mem.eql(u8, key, "region")) {
						shape.region = value;
					} else if (engine == .kafka and std.mem.eql(u8, key, "mechanism")) {
						shape.mechanism = value;
					} else if (engine == .sftp and std.mem.eql(u8, key, "key")) {
						shape.key = value;
					} else if (engine == .k8s and std.mem.eql(u8, key, "kubeconfig")) {
						shape.key = value;
					} else if (engine == .k8s and std.mem.eql(u8, key, "insecure")) {
						shape.insecure = !std.mem.eql(u8, value, "0");
					} else if (engine == .sftp and std.mem.eql(u8, key, "insecure")) {
						shape.insecure = std.mem.eql(u8, value, "1");
					} else {
						return null;
					}
				}
			}
			// A bucket or a container with no server of its own arrives as the host.
			if ((engine == .s3 or engine == .azure) and shape.name.len == 0) {
				shape.name = shape.host;
				shape.host = "";
			}
		},
	}
	const again = compose(arena, shape) catch return null;
	return if (std.mem.eql(u8, again, target)) shape else null;
}

const Url = struct {
	scheme: []const u8 = "",
	user: []const u8 = "",
	host: []const u8 = "",
	port: []const u8 = "",
	path: []const u8 = "",
	query: []const u8 = "",
};

fn split(target: []const u8) Url {
	var out = Url{};
	var rest = target;
	if (std.mem.indexOf(u8, rest, "://")) |at| {
		out.scheme = rest[0..at];
		rest = rest[at + 3 ..];
	}
	if (std.mem.indexOfScalar(u8, rest, '?')) |at| {
		out.query = rest[at + 1 ..];
		rest = rest[0..at];
	}
	var authority = rest;
	if (std.mem.indexOfScalar(u8, rest, '/')) |at| {
		authority = rest[0..at];
		out.path = rest[at + 1 ..];
	}
	if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| {
		out.user = authority[0..at];
		authority = authority[at + 1 ..];
	}
	out.host = authority;
	if (std.mem.lastIndexOfScalar(u8, authority, ':')) |at| {
		const digits = authority[at + 1 ..];
		if (digits.len != 0 and onlyDigits(digits)) {
			out.host = authority[0..at];
			out.port = digits;
		}
	}
	return out;
}

fn onlyDigits(text: []const u8) bool {
	for (text) |byte| {
		if (!std.ascii.isDigit(byte)) {
			return false;
		}
	}
	return true;
}

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
	/// Offer a connection this program found rather than one somebody saved. It
	/// goes after the saved ones, because the list is theirs first, and a target
	/// already in the list is left alone: somebody who saved a context under their
	/// own name meant that name.
	pub fn offer(self: *List, name: []const u8, target: []const u8) !void {
		for (self.items.items) |item| {
			if (std.mem.eql(u8, item.target, target)) {
				return;
			}
		}
		const a = self.arena.allocator();
		try self.items.append(self.allocator, .{
			.name = try a.dupe(u8, name),
			.target = try a.dupe(u8, target),
			.found = true,
		});
	}

	/// How many of these are the user's own, which is what "nothing saved yet"
	/// has to count.
	pub fn savedCount(self: *List) usize {
		var total: usize = 0;
		for (self.items.items) |item| {
			total += @intFromBool(!item.found);
		}
		return total;
	}

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
		// What another file already describes stays described there.
		if (item.found) {
			continue;
		}
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
///
/// Always a copy in the arena, even where there was nothing to take out. A
/// function that sometimes hands back what it was given is a function whose
/// result has two different lifetimes, and the caller cannot see which it got:
/// clearing the buffer the argument came from then quietly rewrites the answer.
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
		return arena.dupe(u8, target);
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
/// Put a password into a target. Always a copy in the arena - see the note on
/// `withoutPassword` for why nothing here hands back its own argument.
pub fn withPassword(arena: std.mem.Allocator, target: []const u8, password: []const u8) ![]const u8 {
	if (password.len == 0) {
		return arena.dupe(u8, target);
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

test "neither password function ever hands back what it was given" {
	var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer scratch.deinit();
	const arena = scratch.allocator();

	// The case that bit: an empty password had nothing to add, and the answer was
	// the argument itself. The caller then cleared the buffer that argument lived
	// in - which `clearRetainingCapacity` fills with undefined - and connected to
	// forty-three bytes of 0xAA.
	//
	// So what is checked is not the text but the address: whatever comes back is
	// the arena's, and clearing anything the caller owns cannot reach it.
	var held: std.ArrayListUnmanaged(u8) = .empty;
	defer held.deinit(std.testing.allocator);
	try held.appendSlice(std.testing.allocator, "sftp://foo@127.0.0.1:2222/upload?insecure=1");

	const kept = try withPassword(arena, held.items, "");
	try std.testing.expect(kept.ptr != held.items.ptr);
	const bare = try withoutPassword(arena, held.items);
	try std.testing.expect(bare.ptr != held.items.ptr);
	// And a keyword string with no password in it, which took the other way out.
	const keywords = try withoutPassword(arena, "host=localhost dbname=demo");
	try std.testing.expectEqualStrings("host=localhost dbname=demo", keywords);

	// The text still says what it said.
	const before = try std.testing.allocator.dupe(u8, kept);
	defer std.testing.allocator.free(before);
	held.clearRetainingCapacity();
	try std.testing.expectEqualStrings(before, kept);
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
	try std.testing.expectEqualStrings("S3", (Connection{ .name = "a", .target = "s3://photos" }).engine());
	try std.testing.expectEqualStrings("S3", (Connection{ .name = "a", .target = "s3+http://localhost:9000/photos" }).engine());
	try std.testing.expectEqualStrings("RabbitMQ", (Connection{ .name = "a", .target = "rabbit://h:15672/" }).engine());
	try std.testing.expectEqualStrings("RabbitMQ", (Connection{ .name = "a", .target = "amqp://guest@h:5672/%2F" }).engine());
	try std.testing.expectEqualStrings("MySQL", (Connection{ .name = "a", .target = "mysql://h/d" }).engine());
	try std.testing.expectEqualStrings("MySQL", (Connection{ .name = "a", .target = "mariadb://h/d" }).engine());
	try std.testing.expectEqualStrings("PostgreSQL", (Connection{ .name = "a", .target = "postgres://h/d" }).engine());
	try std.testing.expectEqualStrings("PostgreSQL", (Connection{ .name = "a", .target = "host=h dbname=d" }).engine());
	try std.testing.expectEqualStrings("SQLite", (Connection{ .name = "a", .target = "notes.db" }).engine());
}

test "a target comes apart into the fields a form asks for" {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();
	const a = arena.allocator();

	{
		const shape = decompose(a, "postgres://postgres@127.0.0.1:5432/shop").?;
		try std.testing.expectEqual(Engine.postgres, shape.engine);
		try std.testing.expectEqualStrings("postgres", shape.user);
		try std.testing.expectEqualStrings("127.0.0.1", shape.host);
		try std.testing.expectEqualStrings("5432", shape.port);
		try std.testing.expectEqualStrings("shop", shape.name);
	}
	{
		// A bucket on Amazon has no host of its own: the name stands where one
		// would be, and has to come back out as the bucket.
		const shape = decompose(a, "s3://photos?region=eu-central-1").?;
		try std.testing.expectEqual(Engine.s3, shape.engine);
		try std.testing.expectEqualStrings("photos", shape.name);
		try std.testing.expectEqualStrings("", shape.host);
		try std.testing.expectEqualStrings("eu-central-1", shape.region);
		try std.testing.expect(shape.tls);
	}
	{
		const shape = decompose(a, "s3+http://minioadmin@localhost:9000/photos").?;
		try std.testing.expectEqualStrings("minioadmin", shape.user);
		try std.testing.expectEqualStrings("localhost", shape.host);
		try std.testing.expectEqualStrings("9000", shape.port);
		try std.testing.expectEqualStrings("photos", shape.name);
		try std.testing.expect(!shape.tls);
	}
	{
		const shape = decompose(a, "kafka+ssl://alice@broker.example:9093?mechanism=SCRAM-SHA-256").?;
		try std.testing.expectEqual(Engine.kafka, shape.engine);
		try std.testing.expectEqualStrings("alice", shape.user);
		try std.testing.expectEqualStrings("SCRAM-SHA-256", shape.mechanism);
		try std.testing.expect(shape.tls);
	}
	{
		const shape = decompose(a, "rabbit://guest@127.0.0.1:15672/%2F").?;
		try std.testing.expectEqual(Engine.rabbit, shape.engine);
		try std.testing.expectEqualStrings("%2F", shape.name);
	}
	{
		const shape = decompose(a, "azure://mystorage@photos").?;
		try std.testing.expectEqual(Engine.azure, shape.engine);
		try std.testing.expectEqualStrings("mystorage", shape.user);
		try std.testing.expectEqualStrings("photos", shape.name);
		try std.testing.expectEqualStrings("", shape.host);
		try std.testing.expect(shape.tls);
	}
	{
		const shape = decompose(a, "azure+http://devstoreaccount1@127.0.0.1:10000/photos").?;
		try std.testing.expectEqualStrings("devstoreaccount1", shape.user);
		try std.testing.expectEqualStrings("127.0.0.1", shape.host);
		try std.testing.expectEqualStrings("10000", shape.port);
		try std.testing.expectEqualStrings("photos", shape.name);
		try std.testing.expect(!shape.tls);
	}
	{
		const shape = decompose(a, "sftp://foo@backup:2222/srv/data").?;
		try std.testing.expectEqual(Engine.sftp, shape.engine);
		try std.testing.expectEqualStrings("foo", shape.user);
		try std.testing.expectEqualStrings("backup", shape.host);
		try std.testing.expectEqualStrings("2222", shape.port);
		try std.testing.expectEqualStrings("srv/data", shape.name);
	}
	{
		const shape = decompose(a, "sftp://foo@backup?key=/tmp/id_ed25519&insecure=1").?;
		try std.testing.expectEqualStrings("/tmp/id_ed25519", shape.key);
		try std.testing.expect(shape.insecure);
	}
	{
		const shape = decompose(a, "/tmp/books.db").?;
		try std.testing.expectEqual(Engine.sqlite, shape.engine);
		try std.testing.expectEqualStrings("/tmp/books.db", shape.path);
	}
}

test "what it cannot put back together again, it does not take apart" {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();
	const a = arena.allocator();

	// A query nobody modelled, a keyword string, and a scheme with a spelling of
	// its own: every one of them stays the single field it was, because a form
	// that rewrote them would be worse than a form that does not offer them.
	// A connection string is a target and its engine is known, but it is not
	// something a form takes apart.
	try std.testing.expectEqual(
		Engine.azure,
		engineOf("DefaultEndpointsProtocol=https;AccountName=a;AccountKey=k;EndpointSuffix=x"),
	);
	try std.testing.expect(decompose(a, "DefaultEndpointsProtocol=https;AccountName=a;AccountKey=k;EndpointSuffix=x") == null);
	try std.testing.expect(decompose(a, "postgres://u@h/d?sslmode=require") == null);
	try std.testing.expect(decompose(a, "host=h dbname=d user=u") == null);
	try std.testing.expect(decompose(a, "amqp://guest@h:5672/%2F") == null);
	try std.testing.expect(decompose(a, "postgresql://u@h/d") == null);
	try std.testing.expect(decompose(a, "mariadb://h/d") == null);
}

test "the parts make the target back" {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();
	const a = arena.allocator();

	try std.testing.expectEqualStrings("mysql://root@127.0.0.1:3306/orders", try compose(a, .{
		.engine = .mysql,
		.user = "root",
		.host = "127.0.0.1",
		.port = "3306",
		.name = "orders",
	}));
	// Nothing but a host is a target too: the engine's own defaults do the rest.
	try std.testing.expectEqualStrings("redis://cache", try compose(a, .{ .engine = .redis, .host = "cache" }));
	try std.testing.expectEqualStrings("s3://photos", try compose(a, .{ .engine = .s3, .name = "photos", .tls = true }));
	try std.testing.expectEqualStrings("rabbits://admin@broker/prod", try compose(a, .{
		.engine = .rabbit,
		.user = "admin",
		.host = "broker",
		.name = "prod",
		.tls = true,
	}));
	try std.testing.expectEqualStrings("sftp://foo@backup/srv/data", try compose(a, .{
		.engine = .sftp,
		.user = "foo",
		.host = "backup",
		.name = "srv/data",
	}));
	// SQLite is a path and nothing else, and `target` is whatever was typed.
	try std.testing.expectEqualStrings("notes.db", try compose(a, .{ .engine = .sqlite, .path = "notes.db" }));
	try std.testing.expectEqualStrings("host=h dbname=d", try compose(a, .{ .engine = .other, .path = "host=h dbname=d" }));
}

test "a SQL Server target survives being taken apart and put back" {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();
	const a = arena.allocator();
	// The rule the form depends on: what comes back has to be what went in, or
	// editing a connection quietly rewrites it.
	const target = "mssql://sa@sql.example:1433/objednavky";
	const shape = decompose(a, target).?;
	try std.testing.expectEqual(Engine.mssql, shape.engine);
	try std.testing.expectEqualStrings("sa", shape.user);
	try std.testing.expectEqualStrings("objednavky", shape.name);
	try std.testing.expectEqualStrings(target, try compose(a, shape));
	try std.testing.expectEqualStrings("SQL Server", (Connection{ .name = "a", .target = target }).engine());
}

test "every engine the form offers is one it knows" {
	for (ENGINES) |name| {
		const engine = Engine.of(name);
		try std.testing.expectEqualStrings(name, engine.label());
	}
	try std.testing.expectEqual(Engine.other, Engine.of("nonsense"));
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

test "a cluster is a context and a namespace, and nothing else" {
	var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer scratch.deinit();
	const a = scratch.allocator();

	try std.testing.expectEqual(Engine.k8s, engineOf("k8s://prod"));
	try std.testing.expectEqual(Engine.k8s, engineOf("kubernetes://prod"));

	{
		const shape = decompose(a, "k8s://prod/payments").?;
		try std.testing.expectEqual(Engine.k8s, shape.engine);
		try std.testing.expectEqualStrings("prod", shape.host);
		try std.testing.expectEqualStrings("payments", shape.name);
	}
	{
		const shape = decompose(a, "k8s://prod?kubeconfig=/tmp/kc&insecure=1").?;
		try std.testing.expectEqualStrings("/tmp/kc", shape.key);
		try std.testing.expect(shape.insecure);
	}
	// And back again, unchanged - which is what lets the form edit one in place.
	try std.testing.expectEqualStrings("k8s://prod/payments", try compose(a, .{
		.engine = .k8s,
		.host = "prod",
		.name = "payments",
	}));
	try std.testing.expectEqualStrings("k8s://", try compose(a, .{ .engine = .k8s }));
	try std.testing.expectEqualStrings("k8s://prod?kubeconfig=/tmp/kc&insecure=1", try compose(a, .{
		.engine = .k8s,
		.host = "prod",
		.key = "/tmp/kc",
		.insecure = true,
	}));
}

test "a found connection is offered but never written to the file" {
	var list = List.init(std.testing.allocator);
	defer list.deinit();
	try list.add("books", "/tmp/books.db", null, "");
	try list.offer("work", "k8s://work");
	try list.offer("staging", "k8s://staging");

	// Saved first, found after: the list is the user's before it is anybody's.
	try std.testing.expectEqual(@as(usize, 3), list.items.items.len);
	try std.testing.expectEqualStrings("books", list.items.items[0].name);
	try std.testing.expect(!list.items.items[0].found);
	try std.testing.expect(list.items.items[1].found);
	try std.testing.expectEqual(@as(usize, 1), list.savedCount());

	// Offering the same target twice does not put it in twice.
	try list.offer("work", "k8s://work");
	try std.testing.expectEqual(@as(usize, 3), list.items.items.len);

	// And one the user saved themselves is left alone: their name wins.
	var mine = List.init(std.testing.allocator);
	defer mine.deinit();
	try mine.add("the live one", "k8s://work", null, "");
	try mine.offer("work", "k8s://work");
	try std.testing.expectEqual(@as(usize, 1), mine.items.items.len);
	try std.testing.expectEqualStrings("the live one", mine.items.items[0].name);
	try std.testing.expect(!mine.items.items[0].found);
}

test "saving writes the saved ones and leaves the found ones where they came from" {
	var list = List.init(std.testing.allocator);
	defer list.deinit();
	try list.add("books", "/tmp/books.db", null, "");
	try list.offer("work", "k8s://work");

	var buffer: [std.fs.max_path_bytes]u8 = undefined;
	const file = try std.fmt.bufPrint(&buffer, "/tmp/krtek-found-test-{d}", .{std.c.getpid()});
	try save(&list, file);

	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();
	const text = try read(arena.allocator(), file);
	try std.testing.expect(std.mem.indexOf(u8, text, "books") != null);
	try std.testing.expect(std.mem.indexOf(u8, text, "k8s://work") == null);
}

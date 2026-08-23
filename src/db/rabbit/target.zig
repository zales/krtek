//! What a RabbitMQ target says.
//!
//! `rabbit://user:password@host:15672/vhost`, and `rabbits://` for HTTPS. The
//! port is the *management* one, because that is what this driver speaks - see
//! the driver for why it is not AMQP. An `amqp://` URL is taken as well, since
//! that is the one people have to hand, and its port is replaced with the
//! management port rather than being connected to, which would only time out.
//!
//! The default vhost is `/`, which is a character that has to travel escaped in
//! every path this driver builds - the single most common way to get a 404 out
//! of the management API.
//!
//! Text in, a structure out; no connection anywhere near it.

const std = @import("std");
const targets = @import("../targets.zig");
const db = @import("../db.zig");

const List = db.List;

const SCHEMES = [_][]const u8{
	"rabbit://",
	"rabbitmq://",
	"rabbit+tls://",
	"rabbits://",
	"rabbitmq+tls://",
	"amqp://",
	"amqps://",
};

/// Ports the management API is not on. An AMQP URL names one of these, and
/// connecting to it would hang rather than fail.
const AMQP_PORTS = [_]u16{ 5672, 5671 };

pub const MANAGEMENT_PORT: u16 = 15672;
pub const MANAGEMENT_TLS_PORT: u16 = 15671;

pub fn owns(target: []const u8) bool {
	for (SCHEMES) |scheme| {
		if (std.ascii.startsWithIgnoreCase(target, scheme)) {
			return true;
		}
	}
	return false;
}

pub const Parts = struct {
	host: []const u8 = "127.0.0.1",
	port: u16 = MANAGEMENT_PORT,
	/// RabbitMQ's own default, which only works from the machine it runs on -
	/// which is exactly where somebody types a target with no user in it.
	user: []const u8 = "guest",
	password: []const u8 = "",
	/// `/` unless the target said otherwise. Not escaped here: escaping is the
	/// business of whoever builds a path out of it.
	vhost: []const u8 = "/",
	tls: bool = false,
	verify: bool = true,
	/// Where the API lives when RabbitMQ is behind a reverse proxy that gave it a
	/// path of its own. Empty for the usual case.
	prefix: []const u8 = "",
	/// Whether the port came from an AMQP URL and was replaced, which the info
	/// view says out loud so nobody wonders where 5672 went.
	moved_port: bool = false,
};

pub fn parse(arena: std.mem.Allocator, target: []const u8) !Parts {
	var self = Parts{};
	var rest = target;
	var scheme_tls: ?bool = null;
	var was_amqp = false;
	for (SCHEMES) |scheme| {
		if (std.ascii.startsWithIgnoreCase(rest, scheme)) {
			rest = rest[scheme.len..];
			if (std.mem.eql(u8, scheme, "rabbits://") or
				std.mem.eql(u8, scheme, "rabbit+tls://") or
				std.mem.eql(u8, scheme, "rabbitmq+tls://") or
				std.mem.eql(u8, scheme, "amqps://"))
			{
				scheme_tls = true;
			}
			was_amqp = std.mem.startsWith(u8, scheme, "amqp");
			break;
		}
	}

	// The query first: a password may hold an @ or a /.
	if (std.mem.indexOfScalar(u8, rest, '?')) |mark| {
		var options = std.mem.tokenizeScalar(u8, rest[mark + 1 ..], '&');
		rest = rest[0..mark];
		while (options.next()) |option| {
			const equals = std.mem.indexOfScalar(u8, option, '=') orelse continue;
			const name = option[0..equals];
			const value = try targets.unescape(arena, option[equals + 1 ..]);
			if (eql(name, "password")) {
				self.password = value;
			} else if (eql(name, "user") or eql(name, "username")) {
				self.user = value;
			} else if (eql(name, "vhost")) {
				self.vhost = value;
			} else if (eql(name, "prefix") or eql(name, "path")) {
				self.prefix = std.mem.trimEnd(u8, value, "/");
			} else if (eql(name, "tls") or eql(name, "ssl")) {
				scheme_tls = !eql(value, "0");
			} else if (eql(name, "insecure")) {
				self.verify = eql(value, "0");
			} else if (eql(name, "port")) {
				self.port = std.fmt.parseInt(u16, value, 10) catch self.port;
			}
		}
	}

	var authority = rest;
	var path: []const u8 = "";
	if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
		authority = rest[0..slash];
		path = rest[slash + 1 ..];
	}
	if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| {
		const userinfo = authority[0..at];
		authority = authority[at + 1 ..];
		if (std.mem.indexOfScalar(u8, userinfo, ':')) |colon| {
			self.user = try targets.unescape(arena, userinfo[0..colon]);
			self.password = try targets.unescape(arena, userinfo[colon + 1 ..]);
		} else if (userinfo.len != 0) {
			self.user = try targets.unescape(arena, userinfo);
		}
	}

	self.tls = scheme_tls orelse false;
	var port: ?u16 = null;
	var host = authority;
	if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
		if (std.fmt.parseInt(u16, authority[colon + 1 ..], 10)) |value| {
			host = authority[0..colon];
			port = value;
		} else |_| {}
	}
	if (host.len != 0) {
		self.host = try arena.dupe(u8, host);
	}
	// An AMQP port belongs to a protocol this driver does not speak; keeping it
	// would mean a connection that hangs instead of a driver that works.
	if (port) |given| {
		for (AMQP_PORTS) |amqp| {
			if (given == amqp) {
				self.moved_port = true;
			}
		}
		if (!self.moved_port) {
			self.port = given;
		}
	}
	if (port == null or self.moved_port) {
		self.port = if (self.tls) MANAGEMENT_TLS_PORT else MANAGEMENT_PORT;
	}
	// A path with nothing in it is the default vhost, which is a slash and not
	// the empty string.
	const named = try targets.unescape(arena, path);
	if (named.len != 0) {
		self.vhost = named;
	}
	return self;
}

fn eql(left: []const u8, right: []const u8) bool {
	return std.ascii.eqlIgnoreCase(left, right);
}


/// A path segment as the management API wants it: everything but the unreserved
/// characters escaped, so the default vhost `/` becomes `%2F` and a queue called
/// `a/b` does not turn into two segments.
pub fn escape(out: *List, arena: std.mem.Allocator, text: []const u8) !void {
	for (text) |byte| {
		if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
			try out.append(arena, byte);
		} else {
			try out.print(arena, "%{X:0>2}", .{byte});
		}
	}
}

pub fn escaped(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
	var out: List = .empty;
	try escape(&out, arena, text);
	return out.items;
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

test "a target says where the management API is" {
	var scratch = std.heap.ArenaAllocator.init(testing.allocator);
	defer scratch.deinit();
	const arena = scratch.allocator();

	{
		const parts = try parse(arena, "rabbit://localhost");
		try testing.expectEqualStrings("localhost", parts.host);
		try testing.expectEqual(MANAGEMENT_PORT, parts.port);
		try testing.expectEqualStrings("guest", parts.user);
		try testing.expectEqualStrings("/", parts.vhost);
		try testing.expect(!parts.tls);
	}
	{
		const parts = try parse(arena, "rabbits://admin:hunter2@rabbit.example/production");
		try testing.expect(parts.tls);
		try testing.expectEqual(MANAGEMENT_TLS_PORT, parts.port);
		try testing.expectEqualStrings("admin", parts.user);
		try testing.expectEqualStrings("hunter2", parts.password);
		try testing.expectEqualStrings("production", parts.vhost);
	}
	{
		// The default vhost is written %2F as often as it is written /.
		const parts = try parse(arena, "rabbit://guest@127.0.0.1:15673/%2F");
		try testing.expectEqual(@as(u16, 15673), parts.port);
		try testing.expectEqualStrings("/", parts.vhost);
	}
	{
		const parts = try parse(arena, "rabbit://host?user=alice&password=p%40ss&vhost=staging&insecure=1&prefix=/rabbitmq/");
		try testing.expectEqualStrings("alice", parts.user);
		try testing.expectEqualStrings("p@ss", parts.password);
		try testing.expectEqualStrings("staging", parts.vhost);
		try testing.expectEqualStrings("/rabbitmq", parts.prefix);
		try testing.expect(!parts.verify);
	}
}

test "an amqp URL is taken, and its port is not" {
	var scratch = std.heap.ArenaAllocator.init(testing.allocator);
	defer scratch.deinit();
	const arena = scratch.allocator();

	// 5672 is the broker's port, which does not answer HTTP: connecting to it
	// would hang rather than say anything useful.
	const parts = try parse(arena, "amqp://guest:guest@localhost:5672/%2F");
	try testing.expectEqual(MANAGEMENT_PORT, parts.port);
	try testing.expect(parts.moved_port);
	try testing.expectEqualStrings("/", parts.vhost);

	const secure = try parse(arena, "amqps://guest@broker:5671/prod");
	try testing.expectEqual(MANAGEMENT_TLS_PORT, secure.port);
	try testing.expect(secure.tls);
	try testing.expectEqualStrings("prod", secure.vhost);

	// A port that is not AMQP's is left alone.
	const kept = try parse(arena, "rabbit://broker:8080");
	try testing.expectEqual(@as(u16, 8080), kept.port);
	try testing.expect(!kept.moved_port);
}

test "the scheme is recognised and nothing else is" {
	try testing.expect(owns("rabbit://localhost"));
	try testing.expect(owns("rabbitmq://localhost"));
	try testing.expect(owns("amqp://localhost"));
	try testing.expect(!owns("redis://localhost"));
	try testing.expect(!owns("s3://bucket"));
	try testing.expect(!owns("/tmp/x.db"));
}

test "a path segment travels escaped" {
	var scratch = std.heap.ArenaAllocator.init(testing.allocator);
	defer scratch.deinit();
	const arena = scratch.allocator();

	try testing.expectEqualStrings("%2F", try escaped(arena, "/"));
	try testing.expectEqualStrings("a%2Fb", try escaped(arena, "a/b"));
	try testing.expectEqualStrings("orders.new", try escaped(arena, "orders.new"));
	try testing.expectEqualStrings("a%20b", try escaped(arena, "a b"));
}

//! What a target says about how to reach a cluster.
//!
//! `kafka://user:password@host:port?tls=1&mechanism=SCRAM-SHA-256`, with
//! `kafka+ssl://` as a shorter way of asking for encryption. A mechanism is only
//! used when there is a user; with a user and no mechanism it is PLAIN, which is
//! what most brokers are set up for.
//!
//! Text in, a structure out, and no connection anywhere near it.

const std = @import("std");
const db = @import("../db.zig");

const List = db.List;

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

// ------------------------------------------------------------------- tests

const testing = std.testing;

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

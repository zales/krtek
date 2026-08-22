//! Signature Version 4: what proves to S3 that a request is yours.
//!
//! The secret key never goes on the wire. What goes is a signature over a
//! *canonical* form of the request - the method, the path, the query sorted, the
//! headers that were signed, and a hash of the body - made with a key derived
//! from the secret, the date, the region and the service. The server builds the
//! same canonical form from what it received and signs it the same way; if the
//! two do not match, something was changed on the way.
//!
//! Which is why almost every SigV4 bug is a *canonicalisation* bug and not a
//! cryptography one: a query in the wrong order, a `+` encoded as a space, a
//! header value not trimmed. So the canonical request and the string to sign are
//! functions of their own here rather than steps buried inside a signer, and the
//! tests below check them against Amazon's own worked examples - the same
//! request, byte for byte, down to the signature.
//!
//! Text in, text out: nothing in this file opens a socket.

const std = @import("std");
const clock = @import("../clock.zig");
const db = @import("../db.zig");

const List = db.List;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;

pub const ALGORITHM = "AWS4-HMAC-SHA256";
/// The hash of no bytes at all, which is what a GET or a DELETE carries.
pub const EMPTY_SHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
/// Stands in for the body hash when the body is too big to hash first. Only
/// allowed over TLS, because without it nothing binds the body to the signature.
pub const UNSIGNED = "UNSIGNED-PAYLOAD";

pub const Credentials = struct {
	key: []const u8,
	secret: []const u8,
	/// From STS or an instance role: sent as `x-amz-security-token` and signed
	/// with everything else.
	token: []const u8 = "",
};

pub const Header = struct {
	name: []const u8,
	value: []const u8,
};

/// One query parameter, unescaped. The signer escapes and sorts, because the
/// order and the escaping are part of what is signed.
pub const Param = struct {
	name: []const u8,
	value: []const u8 = "",
};

pub const Request = struct {
	method: []const u8 = "GET",
	/// The path with each segment already escaped, starting with a slash. S3
	/// signs the path as it is sent - it is not escaped a second time - so this is
	/// what goes on the wire and what is signed.
	path: []const u8 = "/",
	query: []const Param = &.{},
	/// Every header to sign. `host` has to be among them; `x-amz-date` and
	/// `x-amz-content-sha256` are added by `sign`.
	headers: []const Header = &.{},
	/// The body's SHA-256 in hex, or `UNSIGNED`.
	payload: []const u8 = EMPTY_SHA256,
};

/// What `sign` produces: the headers to send, the query to put in the URL, and
/// the `Authorization` value. All of it lives in the arena passed to it.
pub const Signed = struct {
	headers: []const Header,
	query: []const u8,
	authorization: []const u8,
	/// Kept because the tests check them, and because a driver that gets a 403
	/// can show what it signed - which is the only way to find a canonicalisation
	/// bug from the outside.
	canonical: []const u8,
	string_to_sign: []const u8,
	signature: []const u8,
};

/// Sign it. `when` is the timestamp in the form AWS wants, which `stamp` makes.
pub fn sign(
	arena: std.mem.Allocator,
	credentials: Credentials,
	request: Request,
	region: []const u8,
	service: []const u8,
	when: Stamp,
) !Signed {
	var headers: std.ArrayListUnmanaged(Header) = .empty;
	try headers.appendSlice(arena, request.headers);
	try headers.append(arena, .{ .name = "x-amz-date", .value = try arena.dupe(u8, when.full()) });
	try headers.append(arena, .{ .name = "x-amz-content-sha256", .value = request.payload });
	if (credentials.token.len != 0) {
		try headers.append(arena, .{ .name = "x-amz-security-token", .value = credentials.token });
	}

	const sorted = try canonicalHeaders(arena, headers.items);
	const query = try renderQuery(arena, request.query);

	var canonical: List = .empty;
	try canonical.print(arena, "{s}\n{s}\n{s}\n{s}\n{s}\n{s}", .{
		request.method,
		request.path,
		query,
		sorted.block,
		sorted.names,
		request.payload,
	});

	const scope = try std.fmt.allocPrint(arena, "{s}/{s}/{s}/aws4_request", .{ when.date(), region, service });
	var hashed: [64]u8 = undefined;
	hashHex(&hashed, canonical.items);
	const to_sign = try std.fmt.allocPrint(arena, "{s}\n{s}\n{s}\n{s}", .{
		ALGORITHM,
		when.full(),
		scope,
		&hashed,
	});

	const key = try signingKey(credentials.secret, when.date(), region, service);
	var mac: [Hmac.mac_length]u8 = undefined;
	Hmac.create(&mac, to_sign, &key);
	const signature = try arena.alloc(u8, mac.len * 2);
	hex(signature, &mac);

	return .{
		.headers = headers.items,
		.query = query,
		.authorization = try std.fmt.allocPrint(
			arena,
			"{s} Credential={s}/{s}, SignedHeaders={s}, Signature={s}",
			.{ ALGORITHM, credentials.key, scope, sorted.names, signature },
		),
		.canonical = canonical.items,
		.string_to_sign = to_sign,
		.signature = signature,
	};
}

/// A URL that carries its own signature, for handing an object to somebody who
/// has no key: everything that would have been a header goes in the query
/// instead, and it stops working when `seconds` have passed.
///
/// The body is signed as `UNSIGNED-PAYLOAD`, which is what a link has to do - the
/// bytes are not known when the link is made.
pub fn presign(
	arena: std.mem.Allocator,
	credentials: Credentials,
	request: Request,
	region: []const u8,
	service: []const u8,
	when: Stamp,
	seconds: u32,
) ![]const u8 {
	const scope = try std.fmt.allocPrint(arena, "{s}/{s}/{s}/aws4_request", .{ when.date(), region, service });
	const sorted = try canonicalHeaders(arena, request.headers);

	var params: std.ArrayListUnmanaged(Param) = .empty;
	try params.appendSlice(arena, request.query);
	try params.append(arena, .{ .name = "X-Amz-Algorithm", .value = ALGORITHM });
	try params.append(arena, .{
		.name = "X-Amz-Credential",
		.value = try std.fmt.allocPrint(arena, "{s}/{s}", .{ credentials.key, scope }),
	});
	try params.append(arena, .{ .name = "X-Amz-Date", .value = try arena.dupe(u8, when.full()) });
	try params.append(arena, .{
		.name = "X-Amz-Expires",
		.value = try std.fmt.allocPrint(arena, "{d}", .{seconds}),
	});
	try params.append(arena, .{ .name = "X-Amz-SignedHeaders", .value = sorted.names });
	if (credentials.token.len != 0) {
		try params.append(arena, .{ .name = "X-Amz-Security-Token", .value = credentials.token });
	}
	const query = try renderQuery(arena, params.items);

	var canonical: List = .empty;
	try canonical.print(arena, "{s}\n{s}\n{s}\n{s}\n{s}\n{s}", .{
		request.method,
		request.path,
		query,
		sorted.block,
		sorted.names,
		UNSIGNED,
	});
	var hashed: [64]u8 = undefined;
	hashHex(&hashed, canonical.items);
	const to_sign = try std.fmt.allocPrint(arena, "{s}\n{s}\n{s}\n{s}", .{ ALGORITHM, when.full(), scope, &hashed });

	const key = try signingKey(credentials.secret, when.date(), region, service);
	var mac: [Hmac.mac_length]u8 = undefined;
	Hmac.create(&mac, to_sign, &key);
	var signature: [Hmac.mac_length * 2]u8 = undefined;
	hex(&signature, &mac);
	return std.fmt.allocPrint(arena, "{s}&X-Amz-Signature={s}", .{ query, &signature });
}

/// The key the signature is made with: the secret beaten through the date, the
/// region and the service, so a signature stolen from one request is no use for
/// another day, another region or another service.
fn signingKey(secret: []const u8, date: []const u8, region: []const u8, service: []const u8) ![Hmac.mac_length]u8 {
	var first: [4 + 128]u8 = undefined;
	const seed = std.fmt.bufPrint(&first, "AWS4{s}", .{secret}) catch return error.SecretTooLong;
	var key: [Hmac.mac_length]u8 = undefined;
	Hmac.create(&key, date, seed);
	Hmac.create(&key, region, &key);
	Hmac.create(&key, service, &key);
	Hmac.create(&key, "aws4_request", &key);
	return key;
}

const Canonical = struct {
	/// `name:value\n` for each header, in order, and a blank line after them.
	block: []const u8,
	/// The names, lowercase, separated by semicolons.
	names: []const u8,
};

fn lessThan(_: void, left: Header, right: Header) bool {
	return std.mem.order(u8, left.name, right.name) == .lt;
}

fn canonicalHeaders(arena: std.mem.Allocator, headers: []const Header) !Canonical {
	const sorted = try arena.alloc(Header, headers.len);
	for (headers, 0..) |header, i| {
		const lower = try arena.alloc(u8, header.name.len);
		sorted[i] = .{
			.name = std.ascii.lowerString(lower, header.name),
			.value = std.mem.trim(u8, header.value, " \t"),
		};
	}
	std.mem.sort(Header, sorted, {}, lessThan);

	var block: List = .empty;
	var names: List = .empty;
	for (sorted, 0..) |header, i| {
		try block.print(arena, "{s}:{s}\n", .{ header.name, header.value });
		if (i != 0) {
			try names.append(arena, ';');
		}
		try names.appendSlice(arena, header.name);
	}
	// Every header line ends in a newline of its own, and the canonical request
	// puts another one after the block - which is the blank line before the names.
	return .{ .block = block.items, .names = names.items };
}

fn paramLessThan(_: void, left: Param, right: Param) bool {
	return switch (std.mem.order(u8, left.name, right.name)) {
		.lt => true,
		.gt => false,
		.eq => std.mem.order(u8, left.value, right.value) == .lt,
	};
}

/// The query string as it is both sent and signed: every name and value escaped,
/// sorted by name and then by value, and every name given an `=` even when it has
/// no value - `?acl` is signed as `acl=`.
pub fn renderQuery(arena: std.mem.Allocator, params: []const Param) ![]const u8 {
	if (params.len == 0) {
		return "";
	}
	const sorted = try arena.dupe(Param, params);
	std.mem.sort(Param, sorted, {}, paramLessThan);
	var out: List = .empty;
	for (sorted, 0..) |param, i| {
		if (i != 0) {
			try out.append(arena, '&');
		}
		try escape(&out, arena, param.name, false);
		try out.append(arena, '=');
		try escape(&out, arena, param.value, false);
	}
	return out.items;
}

/// Percent-encoding as AWS defines it: everything but the unreserved characters,
/// in uppercase hex. A slash is left alone in a path and escaped everywhere else,
/// which is the difference between a key with a slash in it and a folder.
pub fn escape(out: *List, arena: std.mem.Allocator, text: []const u8, keep_slash: bool) !void {
	for (text) |byte| {
		const plain = std.ascii.isAlphanumeric(byte) or
			byte == '-' or byte == '_' or byte == '.' or byte == '~' or
			(keep_slash and byte == '/');
		if (plain) {
			try out.append(arena, byte);
		} else {
			try out.print(arena, "%{X:0>2}", .{byte});
		}
	}
}

/// A key as it goes into a path: escaped, with the slashes left standing.
pub fn escapePath(arena: std.mem.Allocator, key: []const u8) ![]const u8 {
	var out: List = .empty;
	try out.append(arena, '/');
	try escape(&out, arena, key, true);
	return out.items;
}

// ------------------------------------------------------------------ hashing

pub fn hex(out: []u8, bytes: []const u8) void {
	const digits = "0123456789abcdef";
	for (bytes, 0..) |byte, i| {
		out[i * 2] = digits[byte >> 4];
		out[i * 2 + 1] = digits[byte & 15];
	}
}

/// The SHA-256 of these bytes, in the lowercase hex AWS asks for.
pub fn hashHex(out: *[64]u8, bytes: []const u8) void {
	var digest: [Sha256.digest_length]u8 = undefined;
	Sha256.hash(bytes, &digest, .{});
	hex(out, &digest);
}

// ---------------------------------------------------------------- the clock

/// `20150830T123600Z`, and the `20150830` inside it. Both are signed, and they
/// have to agree - a signature whose date line and whose scope disagree is
/// rejected with the same unhelpful message as a wrong key.
pub const Stamp = struct {
	text: [16]u8,

	pub fn full(self: *const Stamp) []const u8 {
		return &self.text;
	}

	pub fn date(self: *const Stamp) []const u8 {
		return self.text[0..8];
	}
};

/// From a unix time in seconds, which is what makes this testable.
pub fn stamp(seconds: i64) Stamp {
	const moment = std.time.epoch.EpochSeconds{ .secs = @intCast(seconds) };
	const day = moment.getEpochDay().calculateYearDay();
	const month_day = day.calculateMonthDay();
	const time_of_day = moment.getDaySeconds();
	var out: Stamp = .{ .text = undefined };
	_ = std.fmt.bufPrint(&out.text, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
		day.year,
		month_day.month.numeric(),
		month_day.day_index + 1,
		time_of_day.getHoursIntoDay(),
		time_of_day.getMinutesIntoHour(),
		time_of_day.getSecondsIntoMinute(),
	}) catch unreachable;
	return out;
}

/// Now, from the wall clock: a signature says when it was made.
pub fn now() Stamp {
	return stamp(clock.wallSeconds());
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

test "the timestamp is the one AWS signs" {
	// 2015-08-30T12:36:00Z, the moment Amazon's own test suite is fixed at.
	const at = stamp(1440938160);
	try testing.expectEqualStrings("20150830T123600Z", at.full());
	try testing.expectEqualStrings("20150830", at.date());
	// A leap day, because the month arithmetic is where a hand-rolled clock goes
	// wrong: 2016-02-29T23:59:59Z.
	try testing.expectEqualStrings("20160229T235959Z", stamp(1456790399).full());
	try testing.expectEqualStrings("19700101T000000Z", stamp(0).full());
}

test "escaping is AWS's, not the URL's" {
	var scratch = std.heap.ArenaAllocator.init(testing.allocator);
	defer scratch.deinit();
	const arena = scratch.allocator();

	var out: List = .empty;
	try escape(&out, arena, "a b/c+d~e", false);
	// A space is %20 and never a +, and the slash goes too when it is not a path.
	try testing.expectEqualStrings("a%20b%2Fc%2Bd~e", out.items);

	try testing.expectEqualStrings("/photos/2015/august%20trip.jpg", try escapePath(arena, "photos/2015/august trip.jpg"));

	// Sorted by name, then by value, and a parameter with no value still gets its
	// equals sign.
	try testing.expectEqualStrings(
		"acl=&max-keys=2&prefix=a%2Fb",
		try renderQuery(arena, &.{
			.{ .name = "prefix", .value = "a/b" },
			.{ .name = "acl" },
			.{ .name = "max-keys", .value = "2" },
		}),
	);
	try testing.expectEqualStrings("", try renderQuery(arena, &.{}));
}

test "the empty payload hash is the one every GET carries" {
	var out: [64]u8 = undefined;
	hashHex(&out, "");
	try testing.expectEqualStrings(EMPTY_SHA256, &out);
	hashHex(&out, "Welcome to Amazon S3.");
	try testing.expectEqualStrings("44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072", &out);
}

test "Amazon's own worked example, byte for byte" {
	// From "Examples: Signature Calculations for the Authorization Header",
	// example 1: GET an object with a Range header. Everything below - the
	// canonical request, the string to sign and the signature - is what the
	// document says it should be, which is the only way to know this is right
	// without a bucket to try it against.
	var scratch = std.heap.ArenaAllocator.init(testing.allocator);
	defer scratch.deinit();
	const arena = scratch.allocator();

	const signed = try sign(
		arena,
		.{ .key = "AKIAIOSFODNN7EXAMPLE", .secret = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY" },
		.{
			.method = "GET",
			.path = "/test.txt",
			.headers = &.{
				.{ .name = "Host", .value = "examplebucket.s3.amazonaws.com" },
				.{ .name = "Range", .value = "bytes=0-9" },
			},
		},
		"us-east-1",
		"s3",
		stamp(1369353600), // 2013-05-24T00:00:00Z
	);

	try testing.expectEqualStrings(
		"GET\n" ++
			"/test.txt\n" ++
			"\n" ++
			"host:examplebucket.s3.amazonaws.com\n" ++
			"range:bytes=0-9\n" ++
			"x-amz-content-sha256:" ++ EMPTY_SHA256 ++ "\n" ++
			"x-amz-date:20130524T000000Z\n" ++
			"\n" ++
			"host;range;x-amz-content-sha256;x-amz-date\n" ++
			EMPTY_SHA256,
		signed.canonical,
	);
	try testing.expectEqualStrings(
		"AWS4-HMAC-SHA256\n" ++
			"20130524T000000Z\n" ++
			"20130524/us-east-1/s3/aws4_request\n" ++
			"7344ae5b7ee6c3e7e6b0fe0640412a37625d1fbfff95c48bbb2dc43964946972",
		signed.string_to_sign,
	);
	try testing.expectEqualStrings(
		"f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41",
		signed.signature,
	);
	try testing.expectEqualStrings(
		"AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, " ++
			"SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, " ++
			"Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41",
		signed.authorization,
	);
}

test "a query is signed sorted, whatever order it was written in" {
	// The same document, example 4: listing a bucket with max-keys and prefix.
	var scratch = std.heap.ArenaAllocator.init(testing.allocator);
	defer scratch.deinit();
	const arena = scratch.allocator();

	const signed = try sign(
		arena,
		.{ .key = "AKIAIOSFODNN7EXAMPLE", .secret = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY" },
		.{
			.method = "GET",
			.path = "/",
			// Deliberately out of order: what is signed is the sorted form.
			.query = &.{
				.{ .name = "prefix", .value = "J" },
				.{ .name = "max-keys", .value = "2" },
			},
			.headers = &.{.{ .name = "host", .value = "examplebucket.s3.amazonaws.com" }},
		},
		"us-east-1",
		"s3",
		stamp(1369353600),
	);
	try testing.expectEqualStrings("max-keys=2&prefix=J", signed.query);
	try testing.expectEqualStrings(
		"34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7",
		signed.signature,
	);
}

test "a PUT signs the body it is about to send" {
	// Example 2: putting an object, where the payload hash is the body's and not
	// the empty one - the thing that binds the bytes to the signature.
	var scratch = std.heap.ArenaAllocator.init(testing.allocator);
	defer scratch.deinit();
	const arena = scratch.allocator();

	var body: [64]u8 = undefined;
	hashHex(&body, "Welcome to Amazon S3.");

	const signed = try sign(
		arena,
		.{ .key = "AKIAIOSFODNN7EXAMPLE", .secret = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY" },
		.{
			.method = "PUT",
			.path = "/test%24file.text",
			.headers = &.{
				.{ .name = "host", .value = "examplebucket.s3.amazonaws.com" },
				.{ .name = "date", .value = "Fri, 24 May 2013 00:00:00 GMT" },
				.{ .name = "x-amz-storage-class", .value = "REDUCED_REDUNDANCY" },
			},
			.payload = &body,
		},
		"us-east-1",
		"s3",
		stamp(1369353600),
	);
	try testing.expectEqualStrings(
		"98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd",
		signed.signature,
	);
}

test "a link carries its own signature" {
	// "Authenticating Requests: Using Query Parameters", the worked example: a
	// link to test.txt that works for a day and needs no key at the other end.
	var scratch = std.heap.ArenaAllocator.init(testing.allocator);
	defer scratch.deinit();
	const arena = scratch.allocator();

	const query = try presign(
		arena,
		.{ .key = "AKIAIOSFODNN7EXAMPLE", .secret = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY" },
		.{
			.method = "GET",
			.path = "/test.txt",
			.headers = &.{.{ .name = "host", .value = "examplebucket.s3.amazonaws.com" }},
		},
		"us-east-1",
		"s3",
		stamp(1369353600),
		86400,
	);
	try testing.expectEqualStrings(
		"X-Amz-Algorithm=AWS4-HMAC-SHA256" ++
			"&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request" ++
			"&X-Amz-Date=20130524T000000Z" ++
			"&X-Amz-Expires=86400" ++
			"&X-Amz-SignedHeaders=host" ++
			"&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404",
		query,
	);
}

test "a session token is signed along with everything else" {	var scratch = std.heap.ArenaAllocator.init(testing.allocator);
	defer scratch.deinit();
	const arena = scratch.allocator();

	const signed = try sign(
		arena,
		.{ .key = "AKID", .secret = "secret", .token = "FQoDYXdzE" },
		.{ .headers = &.{.{ .name = "host", .value = "bucket.s3.amazonaws.com" }} },
		"eu-central-1",
		"s3",
		stamp(1369353600),
	);
	// It is in the signed headers, so a proxy that drops it breaks the signature
	// instead of quietly sending an unauthenticated request.
	try testing.expect(std.mem.indexOf(u8, signed.authorization, "x-amz-security-token") != null);
	var found = false;
	for (signed.headers) |header| {
		if (std.mem.eql(u8, header.name, "x-amz-security-token")) {
			found = true;
			try testing.expectEqualStrings("FQoDYXdzE", header.value);
		}
	}
	try testing.expect(found);
}

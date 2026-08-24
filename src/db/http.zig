//! HTTP/1.1 over `net.Stream`: what the drivers that talk to an API need, and
//! nothing else.
//!
//! Zig's own client would do, but this one is a few hundred lines, reuses the
//! socket every other driver uses - so a request can be given up on with `ctrl+c`
//! exactly like a query - and keeps the connection open between requests, which
//! matters when listing a bucket is a hundred round trips.
//!
//! What it does: one request at a time, `Content-Length` or `chunked` bodies,
//! keep-alive with one silent reconnect when the server has dropped an idle
//! connection, and a ceiling on how much it will read into memory. What it does
//! not do: redirects (the callers want to see a 301 and its `Location` header
//! themselves - S3 answers a wrong region with one), compression, cookies,
//! proxies, HTTP/2.
//!
//! The response parser takes bytes from a `Source` rather than from a socket, so
//! everything below the transport is tested against canned responses with no
//! server anywhere near it.

const std = @import("std");
const db = @import("db.zig");
const net = @import("net.zig");

const List = db.List;

/// How much of a response will be held in memory. A driver that wants more of an
/// object than this asks for it in ranges.
pub const BODY_LIMIT: usize = 64 << 20;
/// A header block larger than this is a server that has lost the plot.
const HEAD_LIMIT: usize = 256 << 10;
/// How much is asked of the socket at once.
const CHUNK: usize = 32 << 10;

pub const Header = struct {
	name: []const u8,
	value: []const u8,
};

pub const Request = struct {
	method: []const u8 = "GET",
	/// The path and query as they go on the wire: already escaped, starting with
	/// a slash. Whoever signs the request has to see exactly this.
	target: []const u8,
	headers: []const Header = &.{},
	body: []const u8 = "",
	/// How much of the response body to accept before calling it too much.
	limit: usize = BODY_LIMIT,
};

pub const Response = struct {
	status: u16,
	reason: []const u8 = "",
	headers: []const Header = &.{},
	body: []const u8 = "",

	/// The header by that name, matched without regard to case as HTTP requires.
	pub fn get(self: Response, name: []const u8) ?[]const u8 {
		for (self.headers) |header| {
			if (std.ascii.eqlIgnoreCase(header.name, name)) {
				return header.value;
			}
		}
		return null;
	}

	pub fn ok(self: Response) bool {
		return self.status >= 200 and self.status < 300;
	}
};

// ------------------------------------------------------------------ the client

/// Where to send requests, and the connection currently open to it.
pub const Client = struct {
	allocator: std.mem.Allocator,
	host: []const u8,
	port: u16,
	tls: bool,
	/// Whether the certificate has to check out. Off is for MinIO with a
	/// certificate of its own making, and has to be asked for.
	verify: bool = true,
	/// The certificate authority to trust instead of the machine's, and a client
	/// certificate to offer - both PEM, both borrowed for as long as the client
	/// lives. A Kubernetes cluster wants one or both; nothing else here does.
	ca_pem: []const u8 = "",
	cert_pem: []const u8 = "",
	key_pem: []const u8 = "",
	stream: ?net.Stream = null,
	progress: ?db.Progress = null,
	/// What went wrong with the last request, for a driver to show.
	trouble: List = .empty,

	pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16, tls: bool, verify: bool) !Client {
		return .{
			.allocator = allocator,
			.host = try allocator.dupe(u8, host),
			.port = port,
			.tls = tls,
			.verify = verify,
		};
	}

	pub fn deinit(self: *Client) void {
		self.disconnect();
		self.allocator.free(self.host);
		self.trouble.deinit(self.allocator);
	}

	pub fn watch(self: *Client, progress: ?db.Progress) void {
		self.progress = progress;
		self.arm();
	}

	pub fn message(self: *Client) []const u8 {
		return self.trouble.items;
	}

	fn arm(self: *Client) void {
		if (self.stream) |*stream| {
			stream.setTimeout(net.READ_TIMEOUT_MS);
			if (self.progress) |progress| {
				stream.keep_waiting = progress.keep_going;
				stream.context = progress.context;
			} else {
				stream.keep_waiting = null;
				stream.context = null;
			}
		}
	}

	pub fn disconnect(self: *Client) void {
		if (self.stream) |*stream| {
			stream.close();
		}
		self.stream = null;
	}

	fn open(self: *Client) !void {
		if (self.stream != null) {
			return;
		}
		var stream = net.connect(self.allocator, self.host, self.port) catch |err| {
			self.trouble.clearRetainingCapacity();
			try self.trouble.print(self.allocator, "cannot reach {s}:{d}{s}", .{
				self.host,
				self.port,
				switch (err) {
					error.NoSuchHost => " - no such host",
					error.Refused => " - the connection was refused",
					else => "",
				},
			});
			return error.Gone;
		};
		errdefer stream.close();
		stream.setTimeout(net.READ_TIMEOUT_MS);
		if (self.tls) {
			self.trouble.clearRetainingCapacity();
			net.startTls(self.allocator, &stream, self.host, .{
				.verify = self.verify,
				.ca_pem = self.ca_pem,
				.cert_pem = self.cert_pem,
				.key_pem = self.key_pem,
			}, &self.trouble) catch {
				return error.Gone;
			};
		}
		self.stream = stream;
		self.arm();
	}

	/// Send it and read the answer, which is allocated in `arena` and lives as
	/// long as it does.
	///
	/// A connection kept from the last request may have been closed by the server
	/// in the meantime, and there is no way to know until writing to it fails - so
	/// a request that fails on a reused connection before any of the answer has
	/// arrived is sent again on a fresh one. Once a byte of the response has been
	/// read the failure is real and is reported.
	pub fn send(self: *Client, arena: std.mem.Allocator, request: Request) !Response {
		const reused = self.stream != null;
		var answered = false;
		if (self.attempt(arena, request, &answered)) |response| {
			return response;
		} else |err| {
			if (!reused or answered or err == error.GivenUp) {
				return err;
			}
		}
		self.disconnect();
		return self.attempt(arena, request, &answered);
	}

	fn attempt(self: *Client, arena: std.mem.Allocator, request: Request, answered: *bool) !Response {
		try self.open();
		const stream = &self.stream.?;

		var head: List = .empty;
		defer head.deinit(self.allocator);
		try self.write(&head, request);
		stream.write(head.items) catch |err| {
			self.disconnect();
			return err;
		};
		if (request.body.len != 0) {
			stream.write(request.body) catch |err| {
				self.disconnect();
				return err;
			};
		}

		var source = StreamSource{ .stream = stream, .answered = answered };
		const response = readResponse(arena, source.source(), request.method, request.limit) catch |err| {
			self.disconnect();
			return err;
		};
		// A server that says it is done with the connection is taken at its word,
		// rather than found out on the next request.
		if (response.get("connection")) |value| {
			if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, " \t"), "close")) {
				self.disconnect();
			}
		}
		return response;
	}

	fn write(self: *Client, out: *List, request: Request) !void {
		const a = self.allocator;
		try out.print(a, "{s} {s} HTTP/1.1\r\n", .{ request.method, request.target });
		var host_given = false;
		var length_given = false;
		for (request.headers) |header| {
			if (std.ascii.eqlIgnoreCase(header.name, "host")) {
				host_given = true;
			}
			if (std.ascii.eqlIgnoreCase(header.name, "content-length")) {
				length_given = true;
			}
			try out.print(a, "{s}: {s}\r\n", .{ header.name, header.value });
		}
		if (!host_given) {
			try out.print(a, "Host: {s}\r\n", .{self.host});
		}
		if (!length_given and request.body.len != 0) {
			try out.print(a, "Content-Length: {d}\r\n", .{request.body.len});
		}
		try out.appendSlice(a, "\r\n");
	}
};

/// The default port for a scheme, which is also what a `Host` header leaves out.
pub fn defaultPort(tls: bool) u16 {
	return if (tls) 443 else 80;
}

// ------------------------------------------------------------- reading a reply

/// Where the bytes of a response come from. A socket in the program, a string in
/// the tests.
pub const Source = struct {
	context: *anyopaque,
	fill: *const fn (context: *anyopaque, into: []u8) anyerror!usize,

	fn read(self: Source, into: []u8) !usize {
		return self.fill(self.context, into);
	}
};

const StreamSource = struct {
	stream: *net.Stream,
	/// Set as soon as anything of the answer arrives: a request that failed after
	/// that must not be sent a second time, whatever it was.
	answered: ?*bool = null,

	fn source(self: *StreamSource) Source {
		return .{ .context = self, .fill = fill };
	}

	fn fill(context: *anyopaque, into: []u8) anyerror!usize {
		const self: *StreamSource = @ptrCast(@alignCast(context));
		const got = try self.stream.readSome(into);
		if (got != 0) {
			if (self.answered) |flag| {
				flag.* = true;
			}
			// Every chunk, not only every timeout. A reply arriving steadily over
			// a second never waits long enough to time out, so nothing was ever
			// asked and no spinner was ever drawn - which is exactly the case
			// somebody wants one for.
			if (!self.stream.asked()) {
				return error.GivenUp;
			}
		}
		return got;
	}
};

/// Bytes that are already in memory, as a source: what the tests and the fuzzer
/// read a response out of. `step` is how much it hands over at a time, so the
/// parser can be made to deal with a body that arrives in fragments - which is
/// the case it gets wrong if it gets anything wrong.
pub const Slice = struct {
	text: []const u8,
	at: usize = 0,
	step: usize = std.math.maxInt(usize),

	pub fn source(self: *Slice) Source {
		return .{ .context = self, .fill = fill };
	}

	fn fill(context: *anyopaque, into: []u8) anyerror!usize {
		const self: *Slice = @ptrCast(@alignCast(context));
		const left = self.text.len - self.at;
		if (left == 0) {
			return 0;
		}
		const count = @min(@min(left, self.step), into.len);
		@memcpy(into[0..count], self.text[self.at .. self.at + count]);
		self.at += count;
		return count;
	}
};

/// Everything read but not yet handed out. Slices into it are never given away -
/// the buffer moves when it grows - so a line or a chunk is copied into the arena
/// first, which is where the response lives anyway.
const Incoming = struct {
	arena: std.mem.Allocator,
	source: Source,
	buffer: List = .empty,
	at: usize = 0,

	fn more(self: *Incoming) !void {
		const room = try self.buffer.addManyAsSlice(self.arena, CHUNK);
		const got = self.source.read(room) catch |err| {
			self.buffer.shrinkRetainingCapacity(self.buffer.items.len - CHUNK);
			return err;
		};
		self.buffer.shrinkRetainingCapacity(self.buffer.items.len - CHUNK + got);
		if (got == 0) {
			return error.Gone;
		}
	}

	fn pending(self: *Incoming) []const u8 {
		return self.buffer.items[self.at..];
	}

	/// One line without its CRLF, copied out. A bare LF is accepted: some servers
	/// send them and refusing would help nobody.
	fn line(self: *Incoming, limit: usize) ![]const u8 {
		while (true) {
			if (std.mem.indexOfScalar(u8, self.pending(), '\n')) |end| {
				const raw = self.pending()[0..end];
				self.at += end + 1;
				return self.arena.dupe(u8, std.mem.trimEnd(u8, raw, "\r"));
			}
			if (self.pending().len > limit) {
				return error.Malformed;
			}
			try self.more();
		}
	}

	/// Exactly `count` bytes, copied out.
	fn take(self: *Incoming, count: usize) ![]const u8 {
		while (self.pending().len < count) {
			try self.more();
		}
		const out = try self.arena.dupe(u8, self.pending()[0..count]);
		self.at += count;
		return out;
	}

	/// Everything until the other end closes, which is how a response with no
	/// length and no chunking ends.
	fn rest(self: *Incoming, limit: usize) ![]const u8 {
		while (true) {
			if (self.pending().len > limit) {
				return error.TooLarge;
			}
			self.more() catch |err| switch (err) {
				error.Gone => break,
				else => return err,
			};
		}
		const out = try self.arena.dupe(u8, self.pending());
		self.at = self.buffer.items.len;
		return out;
	}
};

pub fn readResponse(arena: std.mem.Allocator, source: Source, method: []const u8, limit: usize) !Response {
	var incoming = Incoming{ .arena = arena, .source = source };

	const status_line = try incoming.line(HEAD_LIMIT);
	var response = try parseStatus(status_line);

	var headers: std.ArrayListUnmanaged(Header) = .empty;
	while (true) {
		const text = try incoming.line(HEAD_LIMIT);
		if (text.len == 0) {
			break;
		}
		const colon = std.mem.indexOfScalar(u8, text, ':') orelse return error.Malformed;
		try headers.append(arena, .{
			.name = text[0..colon],
			.value = std.mem.trim(u8, text[colon + 1 ..], " \t"),
		});
	}
	response.headers = headers.items;

	// A 1xx, a 204 or a 304 has no body whatever the headers say, and neither has
	// the answer to a HEAD - where Content-Length describes the body a GET would
	// have got, and reading that many bytes would hang until the connection died.
	if (response.status < 200 or response.status == 204 or response.status == 304 or
		std.ascii.eqlIgnoreCase(method, "HEAD"))
	{
		return response;
	}

	const chunked = if (response.get("transfer-encoding")) |value|
		std.ascii.indexOfIgnoreCase(value, "chunked") != null
	else
		false;

	if (chunked) {
		response.body = try readChunked(arena, &incoming, limit);
		return response;
	}
	if (response.get("content-length")) |value| {
		const length = std.fmt.parseInt(usize, std.mem.trim(u8, value, " \t"), 10) catch return error.Malformed;
		if (length > limit) {
			return error.TooLarge;
		}
		response.body = try incoming.take(length);
		return response;
	}
	response.body = try incoming.rest(limit);
	return response;
}

fn parseStatus(line: []const u8) !Response {
	if (!std.mem.startsWith(u8, line, "HTTP/")) {
		return error.Malformed;
	}
	const space = std.mem.indexOfScalar(u8, line, ' ') orelse return error.Malformed;
	const rest = line[space + 1 ..];
	if (rest.len < 3) {
		return error.Malformed;
	}
	const status = std.fmt.parseInt(u16, rest[0..3], 10) catch return error.Malformed;
	return .{
		.status = status,
		.reason = if (rest.len > 4) std.mem.trim(u8, rest[4..], " \t") else "",
	};
}

fn readChunked(arena: std.mem.Allocator, incoming: *Incoming, limit: usize) ![]const u8 {
	var body: List = .empty;
	while (true) {
		const header = try incoming.line(HEAD_LIMIT);
		// A chunk size may carry extensions after a semicolon, which nothing here
		// wants; the size is what comes before it, in hex.
		const digits = std.mem.trim(u8, header[0 .. std.mem.indexOfScalar(u8, header, ';') orelse header.len], " \t");
		const size = std.fmt.parseInt(usize, digits, 16) catch return error.Malformed;
		if (size == 0) {
			break;
		}
		if (body.items.len + size > limit) {
			return error.TooLarge;
		}
		try body.appendSlice(arena, try incoming.take(size));
		if ((try incoming.line(HEAD_LIMIT)).len != 0) {
			return error.Malformed; // a chunk has to end on its own line
		}
	}
	// Trailing headers, which nothing here reads, up to the blank line that ends
	// the message.
	while ((try incoming.line(HEAD_LIMIT)).len != 0) {}
	return body.items;
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

fn read(arena: std.mem.Allocator, text: []const u8, method: []const u8) !Response {
	// Seven bytes at a time: the fragments are where the bugs are.
	var canned = Slice{ .text = text, .step = 7 };
	return readResponse(arena, canned.source(), method, BODY_LIMIT);
}

test "a response with a length is read whole, however it arrives" {
	var scratch = std.heap.ArenaAllocator.init(testing.allocator);
	defer scratch.deinit();
	const arena = scratch.allocator();

	const response = try read(arena,
		"HTTP/1.1 200 OK\r\n" ++
			"Content-Type: application/xml\r\n" ++
			"Content-Length: 11\r\n" ++
			"\r\n" ++
			"hello there", "GET");
	try testing.expectEqual(@as(u16, 200), response.status);
	try testing.expectEqualStrings("OK", response.reason);
	try testing.expectEqualStrings("hello there", response.body);
	try testing.expect(response.ok());
	// Header names are matched without regard to case, as HTTP has it.
	try testing.expectEqualStrings("application/xml", response.get("content-type").?);
	try testing.expectEqualStrings("application/xml", response.get("Content-Type").?);
	try testing.expect(response.get("etag") == null);
}

test "a chunked response is put back together" {
	var scratch = std.heap.ArenaAllocator.init(testing.allocator);
	defer scratch.deinit();
	const arena = scratch.allocator();

	const response = try read(arena,
		"HTTP/1.1 200 OK\r\n" ++
			"Transfer-Encoding: chunked\r\n" ++
			"\r\n" ++
			"5\r\nhello\r\n" ++
			"7;ext=1\r\n, there\r\n" ++ // an extension on the size is not part of it
			"0\r\n" ++
			"\r\n", "GET");
	try testing.expectEqualStrings("hello, there", response.body);
}

test "a reply that cannot have a body does not wait for one" {
	var scratch = std.heap.ArenaAllocator.init(testing.allocator);
	defer scratch.deinit();
	const arena = scratch.allocator();

	// HEAD: the length describes the object, not what follows. Reading it would
	// hang until the connection died.
	const head = try read(arena, "HTTP/1.1 200 OK\r\nContent-Length: 4096\r\n\r\n", "HEAD");
	try testing.expectEqual(@as(usize, 0), head.body.len);
	try testing.expectEqualStrings("4096", head.get("content-length").?);

	const empty = try read(arena, "HTTP/1.1 204 No Content\r\n\r\n", "DELETE");
	try testing.expectEqual(@as(u16, 204), empty.status);
	try testing.expectEqual(@as(usize, 0), empty.body.len);
}

test "a body with no length at all ends when the connection does" {
	var scratch = std.heap.ArenaAllocator.init(testing.allocator);
	defer scratch.deinit();
	const arena = scratch.allocator();

	const response = try read(arena, "HTTP/1.1 500 Internal Server Error\r\n\r\nit broke", "GET");
	try testing.expectEqual(@as(u16, 500), response.status);
	try testing.expectEqualStrings("Internal Server Error", response.reason);
	try testing.expectEqualStrings("it broke", response.body);
	try testing.expect(!response.ok());
}

test "nonsense is refused rather than guessed at" {
	var scratch = std.heap.ArenaAllocator.init(testing.allocator);
	defer scratch.deinit();
	const arena = scratch.allocator();

	try testing.expectError(error.Malformed, read(arena, "GARBAGE\r\n\r\n", "GET"));
	try testing.expectError(error.Malformed, read(arena, "HTTP/1.1 200 OK\r\nno colon here\r\n\r\n", "GET"));
	// Cut off in the middle of the body it promised.
	try testing.expectError(error.Gone, read(arena, "HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nshort", "GET"));
}

test "a status line without a reason is still a status" {
	var scratch = std.heap.ArenaAllocator.init(testing.allocator);
	defer scratch.deinit();
	const arena = scratch.allocator();

	const response = try read(arena, "HTTP/1.1 404\r\nContent-Length: 0\r\n\r\n", "GET");
	try testing.expectEqual(@as(u16, 404), response.status);
	try testing.expectEqualStrings("", response.reason);
}

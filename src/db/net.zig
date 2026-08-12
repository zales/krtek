//! A socket that may have TLS on it, shared by every driver that speaks its own
//! protocol.
//!
//! This began inside the Kafka driver and moved out when a second caller
//! appeared: HTTP wants the same connect, the same handshake and - above all -
//! the same read loop, the one whose short timeout is what lets `ctrl+c`
//! interrupt a server that is thinking.
//!
//! OpenSSL is declared here rather than included: libpq and the MariaDB
//! connector both link it already, so these declarations cost nothing.

const std = @import("std");
const db = @import("db.zig");

const List = db.List;

/// How long one read may sit there with nothing arriving before whoever asked is
/// consulted about carrying on. Not a deadline: a slow query is allowed to be
/// slow. It is what makes ctrl+c work while a server thinks, and what stops a
/// server that has stopped thinking from holding the program forever.
pub const READ_TIMEOUT_MS: i64 = 400;
/// And how long in total, with nothing at all arriving, before the read is a
/// failure rather than a wait.
pub const READ_PATIENCE_MS: i64 = 60 * 1000;

/// A socket, with a TLS session on top of it when the target asked for one.
/// Everything reads and writes through here, so encryption is one branch rather
/// than a second copy of the protocol.
pub const Stream = struct {
	fd: std.c.fd_t,
	ssl: ?*anyopaque = null,
	/// Asked between waits: false means give up on this read.
	keep_waiting: ?*const fn (context: *anyopaque) bool = null,
	context: ?*anyopaque = null,

	/// Wait this long for something to arrive, then come back either way. Set on
	/// every socket, so no read can block without end.
	pub fn setTimeout(self: *Stream, ms: i64) void {
		const timeout = std.c.timeval{
			.sec = @intCast(@divFloor(ms, 1000)),
			.usec = @intCast(@mod(ms, 1000) * 1000),
		};
		_ = std.c.setsockopt(self.fd, std.c.SOL.SOCKET, std.c.SO.RCVTIMEO, &timeout, @sizeOf(std.c.timeval));
	}

	fn waited(self: *Stream) bool {
		if (self.keep_waiting) |ask| {
			if (self.context) |context| {
				return ask(context);
			}
		}
		return true;
	}

	pub fn write(self: *Stream, bytes: []const u8) !void {
		var sent: usize = 0;
		while (sent < bytes.len) {
			const wrote = if (self.ssl) |session|
				ssl.SSL_write(session, bytes[sent..].ptr, @intCast(bytes.len - sent))
			else
				@as(c_int, @intCast(std.c.send(self.fd, bytes[sent..].ptr, bytes.len - sent, 0)));
			if (wrote <= 0) {
				return error.Gone;
			}
			sent += @intCast(wrote);
		}
	}

	/// Exactly `into.len` bytes, or an error. Kafka frames everything by length, so
	/// a short read is never the end of a message.
	///
	/// A read that times out is not a failure: the socket has a short timeout so
	/// that this loop gets to ask whether to keep waiting - which is what lets
	/// ctrl+c interrupt a server that is thinking, and what turns a server that has
	/// stopped answering into an error instead of a hang.
	pub fn readExactly(self: *Stream, into: []u8) !void {
		var got: usize = 0;
		while (got < into.len) {
			const read = try self.readSome(into[got..]);
			got += read;
		}
	}

	/// Whatever has arrived, at least one byte. What a protocol without a length
	/// in front of every message needs: HTTP is read until the body is complete,
	/// not until a counter runs out.
	pub fn readSome(self: *Stream, into: []u8) !usize {
		var waiting: i64 = 0;
		while (true) {
			const read = if (self.ssl) |session|
				ssl.SSL_read(session, into.ptr, @intCast(into.len))
			else
				@as(c_int, @intCast(std.c.recv(self.fd, into.ptr, into.len, 0)));
			if (read > 0) {
				return @intCast(read);
			}
			if (read == 0) {
				return error.Gone; // the other end closed it
			}
			if (!self.timedOut()) {
				return error.Gone;
			}
			if (!self.waited()) {
				return error.GivenUp;
			}
			waiting += READ_TIMEOUT_MS;
			if (waiting >= READ_PATIENCE_MS) {
				return error.Gone;
			}
		}
	}

	/// Whether the last read came back empty-handed because the timeout ran out,
	/// rather than because the connection is broken.
	fn timedOut(self: *Stream) bool {
		if (self.ssl != null) {
			// SSL_ERROR_WANT_READ, which is what a timeout looks like through OpenSSL.
			return ssl.SSL_get_error(self.ssl, -1) == ssl.ERROR_WANT_READ;
		}
		// EAGAIN is what a receive timeout reports, and EWOULDBLOCK is the same
		// number everywhere this runs; a signal that interrupted the wait is also
		// worth waiting again after.
		const code = std.c._errno().*;
		return code == @intFromEnum(std.c.E.AGAIN) or code == @intFromEnum(std.c.E.INTR);
	}

	pub fn close(self: *Stream) void {
		if (self.ssl) |session| {
			_ = ssl.SSL_shutdown(session);
			ssl.SSL_free(session);
			self.ssl = null;
		}
		_ = std.c.close(self.fd);
		self.fd = -1;
	}
};

/// The little of OpenSSL this needs, declared rather than included: a client
/// context, a session on a socket, and the two calls that move bytes. OpenSSL is
/// already linked in - libpq and the MariaDB connector both want it - so this
/// costs nothing but these declarations.
pub const ssl = struct {
	pub extern fn OPENSSL_init_ssl(opts: u64, settings: ?*anyopaque) c_int;
	pub extern fn TLS_client_method() ?*anyopaque;
	pub extern fn SSL_CTX_new(method: ?*anyopaque) ?*anyopaque;
	pub extern fn SSL_CTX_free(ctx: ?*anyopaque) void;
	pub extern fn SSL_CTX_set_default_verify_paths(ctx: ?*anyopaque) c_int;
	pub extern fn SSL_CTX_set_verify(ctx: ?*anyopaque, mode: c_int, callback: ?*anyopaque) void;
	pub extern fn SSL_new(ctx: ?*anyopaque) ?*anyopaque;
	pub extern fn SSL_free(session: ?*anyopaque) void;
	pub extern fn SSL_set_fd(session: ?*anyopaque, fd: c_int) c_int;
	pub extern fn SSL_connect(session: ?*anyopaque) c_int;
	pub extern fn SSL_read(session: ?*anyopaque, buffer: [*]u8, count: c_int) c_int;
	pub extern fn SSL_write(session: ?*anyopaque, buffer: [*]const u8, count: c_int) c_int;
	pub extern fn SSL_shutdown(session: ?*anyopaque) c_int;
	pub extern fn SSL_ctrl(session: ?*anyopaque, cmd: c_int, larg: c_long, parg: ?*anyopaque) c_long;
	pub extern fn SSL_set1_host(session: ?*anyopaque, host: [*:0]const u8) c_int;
	pub extern fn SSL_get_verify_result(session: ?*const anyopaque) c_long;
	pub extern fn SSL_get_error(session: ?*const anyopaque, ret: c_int) c_int;
	pub extern fn ERR_get_error() c_ulong;
	pub extern fn ERR_error_string_n(code: c_ulong, buffer: [*]u8, length: usize) void;

	pub const ERROR_WANT_READ: c_int = 2;
	pub const VERIFY_PEER: c_int = 1;
	pub const VERIFY_NONE: c_int = 0;
	/// SSL_set_tlsext_host_name, which is a macro over SSL_ctrl.
	pub const CTRL_SET_TLSEXT_HOSTNAME: c_int = 55;
	pub const TLSEXT_NAMETYPE_host_name: c_long = 0;

	/// What OpenSSL last complained about, into a buffer of the caller's.
	pub fn lastError(buffer: []u8) []const u8 {
		const code = ERR_get_error();
		if (code == 0) {
			return "";
		}
		ERR_error_string_n(code, buffer.ptr, buffer.len);
		return std.mem.sliceTo(buffer, 0);
	}
};

/// Wrap a connected socket in TLS. `host` is verified against the certificate
/// unless the target said not to bother.
pub fn startTls(allocator: std.mem.Allocator, stream: *Stream, host: []const u8, verify: bool, why: *List) !void {
	_ = ssl.OPENSSL_init_ssl(0, null);
	const ctx = ssl.SSL_CTX_new(ssl.TLS_client_method()) orelse return error.Tls;
	// The context is freed as soon as the session is made: the session holds a
	// reference of its own.
	defer ssl.SSL_CTX_free(ctx);
	if (verify) {
		if (ssl.SSL_CTX_set_default_verify_paths(ctx) != 1) {
			try why.appendSlice(allocator, "no trusted certificates on this machine to verify the server against");
			return error.Tls;
		}
		ssl.SSL_CTX_set_verify(ctx, ssl.VERIFY_PEER, null);
	} else {
		ssl.SSL_CTX_set_verify(ctx, ssl.VERIFY_NONE, null);
	}
	const session = ssl.SSL_new(ctx) orelse return error.Tls;
	errdefer ssl.SSL_free(session);
	if (ssl.SSL_set_fd(session, stream.fd) != 1) {
		return error.Tls;
	}
	const zero_host = try allocator.dupeZ(u8, host);
	defer allocator.free(zero_host);
	// The name to ask for, and - when verifying - the name to insist on.
	_ = ssl.SSL_ctrl(session, ssl.CTRL_SET_TLSEXT_HOSTNAME, ssl.TLSEXT_NAMETYPE_host_name, @ptrCast(@constCast(zero_host.ptr)));
	if (verify) {
		_ = ssl.SSL_set1_host(session, zero_host.ptr);
	}
	if (ssl.SSL_connect(session) != 1) {
		var buffer: [256]u8 = undefined;
		const text = ssl.lastError(&buffer);
		try why.print(allocator, "the TLS handshake failed{s}{s}", .{
			if (text.len != 0) ": " else "",
			text,
		});
		return error.Tls;
	}
	stream.ssl = session;
}

pub fn connect(allocator: std.mem.Allocator, host: []const u8, port: u16) !Stream {
	const zero = try allocator.dupeZ(u8, host);
	defer allocator.free(zero);
	var hints = std.mem.zeroes(std.c.addrinfo);
	hints.family = std.c.AF.UNSPEC;
	hints.socktype = std.c.SOCK.STREAM;
	var service: [8]u8 = undefined;
	const service_text = std.fmt.bufPrintZ(&service, "{d}", .{port}) catch return error.BadPort;
	var found: ?*std.c.addrinfo = null;
	if (std.c.getaddrinfo(zero.ptr, service_text.ptr, &hints, &found) != @as(std.c.EAI, @enumFromInt(0))) {
		return error.NoSuchHost;
	}
	defer if (found) |list| std.c.freeaddrinfo(list);
	var candidate = found;
	while (candidate) |info| : (candidate = info.next) {
		const fd = std.c.socket(@intCast(info.family), @intCast(info.socktype), @intCast(info.protocol));
		if (fd < 0) {
			continue;
		}
		if (std.c.connect(fd, info.addr.?, info.addrlen) == 0) {
			return .{ .fd = fd };
		}
		_ = std.c.close(fd);
	}
	return error.Refused;
}

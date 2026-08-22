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

	/// Whatever has arrived by now, and nothing if nothing has. For a session
	/// waiting on two things at once - a terminal and a socket - where sitting on
	/// either one is the same as ignoring the other.
	pub fn readNow(self: *Stream, into: []u8) !usize {
		const read = if (self.ssl) |session|
			ssl.SSL_read(session, into.ptr, @intCast(into.len))
		else
			@as(c_int, @intCast(std.c.recv(self.fd, into.ptr, into.len, 0)));
		if (read > 0) {
			return @intCast(read);
		}
		if (read == 0) {
			return error.Gone;
		}
		return if (self.timedOut()) 0 else error.Gone;
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
	// PEM in memory rather than on disk: a kubeconfig carries its certificate
	// authority and its client certificate inside itself, base64 of the PEM, and
	// writing them out to temporary files to hand OpenSSL a path would put a
	// private key on somebody's disk for as long as the program ran.
	pub extern fn BIO_new_mem_buf(buffer: [*]const u8, length: c_int) ?*anyopaque;
	pub extern fn BIO_free(bio: ?*anyopaque) c_int;
	pub extern fn PEM_read_bio_X509(bio: ?*anyopaque, out: ?*anyopaque, callback: ?*anyopaque, user: ?*anyopaque) ?*anyopaque;
	pub extern fn PEM_read_bio_PrivateKey(bio: ?*anyopaque, out: ?*anyopaque, callback: ?*anyopaque, user: ?*anyopaque) ?*anyopaque;
	pub extern fn X509_free(cert: ?*anyopaque) void;
	pub extern fn EVP_PKEY_free(key: ?*anyopaque) void;
	pub extern fn SSL_CTX_get_cert_store(ctx: ?*const anyopaque) ?*anyopaque;
	pub extern fn X509_STORE_add_cert(store: ?*anyopaque, cert: ?*anyopaque) c_int;
	pub extern fn SSL_CTX_use_certificate(ctx: ?*anyopaque, cert: ?*anyopaque) c_int;
	pub extern fn SSL_CTX_use_PrivateKey(ctx: ?*anyopaque, key: ?*anyopaque) c_int;
	pub extern fn SSL_CTX_check_private_key(ctx: ?*const anyopaque) c_int;
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

/// What a TLS session is to be made of, beyond the socket and the name.
pub const Tls = struct {
	/// Check the server's certificate at all.
	verify: bool = true,
	/// The certificate authority to trust, as PEM, *instead of* the machine's -
	/// which is what kubectl does with the one a kubeconfig names, and the only
	/// thing that makes sense: a cluster signed by a CA of its own making is not
	/// made more trustworthy by also trusting the public web.
	ca_pem: []const u8 = "",
	/// A client certificate and its key, as PEM: how a kubeconfig with
	/// `client-certificate-data` proves who it is. Both or neither.
	cert_pem: []const u8 = "",
	key_pem: []const u8 = "",
};

/// Wrap a connected socket in TLS. `host` is verified against the certificate
/// unless the target said not to bother.
pub fn startTls(allocator: std.mem.Allocator, stream: *Stream, host: []const u8, options: Tls, why: *List) !void {
	_ = ssl.OPENSSL_init_ssl(0, null);
	const ctx = ssl.SSL_CTX_new(ssl.TLS_client_method()) orelse return error.Tls;
	// The context is freed as soon as the session is made: the session holds a
	// reference of its own.
	defer ssl.SSL_CTX_free(ctx);
	if (options.verify) {
		if (options.ca_pem.len != 0) {
			const added = try trustPem(allocator, ctx, options.ca_pem, why);
			if (added == 0) {
				return error.Tls;
			}
		} else if (ssl.SSL_CTX_set_default_verify_paths(ctx) != 1) {
			try why.appendSlice(allocator, "no trusted certificates on this machine to verify the server against");
			return error.Tls;
		}
		ssl.SSL_CTX_set_verify(ctx, ssl.VERIFY_PEER, null);
	} else {
		ssl.SSL_CTX_set_verify(ctx, ssl.VERIFY_NONE, null);
	}
	if (options.cert_pem.len != 0) {
		try useClientCertificate(allocator, ctx, options.cert_pem, options.key_pem, why);
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
	if (options.verify) {
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

/// Every certificate in a PEM bundle into the context's own store, and how many
/// there were. A bundle may hold several and all of them count: an intermediate
/// left out is a chain that does not reach the root.
fn trustPem(allocator: std.mem.Allocator, ctx: ?*anyopaque, pem: []const u8, why: *List) !usize {
	const bio = ssl.BIO_new_mem_buf(pem.ptr, @intCast(pem.len)) orelse return error.Tls;
	defer _ = ssl.BIO_free(bio);
	const store = ssl.SSL_CTX_get_cert_store(ctx) orelse return error.Tls;
	var count: usize = 0;
	while (ssl.PEM_read_bio_X509(bio, null, null, null)) |cert| {
		defer ssl.X509_free(cert);
		if (ssl.X509_STORE_add_cert(store, cert) != 1) {
			break;
		}
		count += 1;
	}
	if (count == 0) {
		var buffer: [256]u8 = undefined;
		const text = ssl.lastError(&buffer);
		try why.print(allocator, "the certificate authority is not a certificate{s}{s}", .{
			if (text.len != 0) ": " else "",
			text,
		});
	}
	return count;
}

/// The client certificate and the key that goes with it, both PEM in memory. The
/// pair is checked here rather than at the handshake, where OpenSSL reports a
/// mismatched key as an unhelpfully generic failure on the far side of a network
/// round trip.
fn useClientCertificate(allocator: std.mem.Allocator, ctx: ?*anyopaque, cert_pem: []const u8, key_pem: []const u8, why: *List) !void {
	if (key_pem.len == 0) {
		try why.appendSlice(allocator, "a client certificate was given without its key");
		return error.Tls;
	}
	const cert_bio = ssl.BIO_new_mem_buf(cert_pem.ptr, @intCast(cert_pem.len)) orelse return error.Tls;
	defer _ = ssl.BIO_free(cert_bio);
	const cert = ssl.PEM_read_bio_X509(cert_bio, null, null, null) orelse {
		try why.appendSlice(allocator, "the client certificate is not a certificate");
		return error.Tls;
	};
	defer ssl.X509_free(cert);
	if (ssl.SSL_CTX_use_certificate(ctx, cert) != 1) {
		try why.appendSlice(allocator, "the client certificate was refused");
		return error.Tls;
	}

	const key_bio = ssl.BIO_new_mem_buf(key_pem.ptr, @intCast(key_pem.len)) orelse return error.Tls;
	defer _ = ssl.BIO_free(key_bio);
	const key = ssl.PEM_read_bio_PrivateKey(key_bio, null, null, null) orelse {
		var buffer: [256]u8 = undefined;
		const text = ssl.lastError(&buffer);
		try why.print(allocator, "the client key is not a key{s}{s}", .{
			if (text.len != 0) ": " else "",
			text,
		});
		return error.Tls;
	};
	defer ssl.EVP_PKEY_free(key);
	if (ssl.SSL_CTX_use_PrivateKey(ctx, key) != 1 or ssl.SSL_CTX_check_private_key(ctx) != 1) {
		try why.appendSlice(allocator, "the client key does not go with the client certificate");
		return error.Tls;
	}
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

// ------------------------------------------------------------------- tests

const testing = std.testing;

// A throwaway authority, a client certificate it signed, that certificate's key,
// and a key belonging to nothing - enough to check that PEM in memory is read,
// that a bundle counts, and that a mismatched pair is caught here rather than at
// the far end of a handshake. Test material: none of it guards anything.
const CA_PEM =
	\\-----BEGIN CERTIFICATE-----
	\\MIIBhzCCAS2gAwIBAgIUO3JprpIG9tLOz1a+HhuDxtjv06AwCgYIKoZIzj0EAwIw
	\\GDEWMBQGA1UEAwwNa3J0ZWsgdGVzdCBDQTAgFw0yNjA4MjIxNDAwMDlaGA8yMTI2
	\\MDcyOTE0MDAwOVowGDEWMBQGA1UEAwwNa3J0ZWsgdGVzdCBDQTBZMBMGByqGSM49
	\\AgEGCCqGSM49AwEHA0IABGAspCAhMpImIjIk4rqEnNkdGvuECuwhMW+ByR+PGqrw
	\\kXLFA4wdQH4Y33EQ7bv/pX3pEce5nzB+VMsNDoCq2RmjUzBRMB0GA1UdDgQWBBRr
	\\NONp6lPpgsM139jHqVqHDyfs9DAfBgNVHSMEGDAWgBRrNONp6lPpgsM139jHqVqH
	\\Dyfs9DAPBgNVHRMBAf8EBTADAQH/MAoGCCqGSM49BAMCA0gAMEUCIQDmjM5Fhz2X
	\\mk+Xq5JXaOvZjIrTM1iuXzU8pK1+ERfXmgIgEVnvo7ayK55tQXU9GZaOwSzPc1EU
	\\yMa/YYorVu7JbGo=
	\\-----END CERTIFICATE-----
	;

const CLIENT_PEM =
	\\-----BEGIN CERTIFICATE-----
	\\MIIBezCCASCgAwIBAgIUBv5hohX2X7uVGHM8+RsPskZ8RZ0wCgYIKoZIzj0EAwIw
	\\GDEWMBQGA1UEAwwNa3J0ZWsgdGVzdCBDQTAgFw0yNjA4MjIxNDAwMDlaGA8yMTI2
	\\MDcyOTE0MDAwOVowHDEaMBgGA1UEAwwRa3J0ZWsgdGVzdCBjbGllbnQwWTATBgcq
	\\hkjOPQIBBggqhkjOPQMBBwNCAASbUyTBpINJPwtBlc16v88mvC7MKy/6lI99WeHI
	\\o/hJC07WYFZKj9FRdAX3JqoqP5Kc1ktL0Df9OXLYaQuEgQmko0IwQDAdBgNVHQ4E
	\\FgQUkx0cyMbqjA57fT+AhFOnX/DRXwswHwYDVR0jBBgwFoAUazTjaepT6YLDNd/Y
	\\x6lahw8n7PQwCgYIKoZIzj0EAwIDSQAwRgIhAJg0fNc5hXvMlXS1+uXxsp1R+dkQ
	\\b9rsObg+RlYV2LyeAiEA/F34juGvzC9QLEqey4gdjL+LxJeAaTuyUSLjWJFs/Mg=
	\\-----END CERTIFICATE-----
	;

const CLIENT_KEY =
	\\-----BEGIN PRIVATE KEY-----
	\\MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgKFdUcyu3tHzntOOB
	\\4c/VitOwbehLMp08SHqY+sgQj86hRANCAASbUyTBpINJPwtBlc16v88mvC7MKy/6
	\\lI99WeHIo/hJC07WYFZKj9FRdAX3JqoqP5Kc1ktL0Df9OXLYaQuEgQmk
	\\-----END PRIVATE KEY-----
	;

const OTHER_KEY =
	\\-----BEGIN EC PRIVATE KEY-----
	\\MHcCAQEEIEu4HMdB9Uwve4Zz5tpRqPGIYfTtQbomsCiPORYTIAUJoAoGCCqGSM49
	\\AwEHoUQDQgAEHDlHTje5w+WVQOyx9aZmaVZyYUEx+bCfceV9tOPMXaLPjYQPgiu2
	\\I4SlAXEHlZzdlmthVYeXXJipSSu80blCkQ==
	\\-----END EC PRIVATE KEY-----
	;

test "a certificate authority is read out of memory, and rubbish is not" {
	_ = ssl.OPENSSL_init_ssl(0, null);
	const ctx = ssl.SSL_CTX_new(ssl.TLS_client_method()) orelse return error.SkipZigTest;
	defer ssl.SSL_CTX_free(ctx);
	var why: List = .empty;
	defer why.deinit(testing.allocator);

	try testing.expectEqual(@as(usize, 1), try trustPem(testing.allocator, ctx, CA_PEM, &why));
	// Two of them in one bundle, which is what an intermediate makes.
	const bundle = CA_PEM ++ "\n" ++ CA_PEM;
	try testing.expectEqual(@as(usize, 2), try trustPem(testing.allocator, ctx, bundle, &why));
	try testing.expectEqualStrings("", why.items);

	try testing.expectEqual(@as(usize, 0), try trustPem(testing.allocator, ctx, "not a certificate at all", &why));
	try testing.expect(std.mem.indexOf(u8, why.items, "not a certificate") != null);
}

test "a client certificate and its key go in together, or the pair is refused" {
	_ = ssl.OPENSSL_init_ssl(0, null);
	var why: List = .empty;
	defer why.deinit(testing.allocator);

	{
		const ctx = ssl.SSL_CTX_new(ssl.TLS_client_method()) orelse return error.SkipZigTest;
		defer ssl.SSL_CTX_free(ctx);
		try useClientCertificate(testing.allocator, ctx, CLIENT_PEM, CLIENT_KEY, &why);
		try testing.expectEqualStrings("", why.items);
	}
	// A key that belongs to another certificate is caught here, not three layers
	// away in a handshake that says only that the server hung up.
	{
		const ctx = ssl.SSL_CTX_new(ssl.TLS_client_method()) orelse return error.SkipZigTest;
		defer ssl.SSL_CTX_free(ctx);
		try testing.expectError(error.Tls, useClientCertificate(testing.allocator, ctx, CLIENT_PEM, OTHER_KEY, &why));
		try testing.expect(std.mem.indexOf(u8, why.items, "does not go with") != null);
	}
	// And a certificate with no key at all is a sentence rather than a crash.
	{
		const ctx = ssl.SSL_CTX_new(ssl.TLS_client_method()) orelse return error.SkipZigTest;
		defer ssl.SSL_CTX_free(ctx);
		why.clearRetainingCapacity();
		try testing.expectError(error.Tls, useClientCertificate(testing.allocator, ctx, CLIENT_PEM, "", &why));
		try testing.expect(std.mem.indexOf(u8, why.items, "without its key") != null);
	}
	{
		const ctx = ssl.SSL_CTX_new(ssl.TLS_client_method()) orelse return error.SkipZigTest;
		defer ssl.SSL_CTX_free(ctx);
		why.clearRetainingCapacity();
		try testing.expectError(error.Tls, useClientCertificate(testing.allocator, ctx, "nonsense", CLIENT_KEY, &why));
		try testing.expect(std.mem.indexOf(u8, why.items, "not a certificate") != null);
	}
}

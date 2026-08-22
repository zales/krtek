//! Bytes nobody can guess.
//!
//! A SCRAM nonce, a WebSocket mask and the marker that ends a shell command all
//! need the same thing and for the same reason: something the other end cannot
//! have predicted. This began inside the Kafka driver, where SCRAM needed it
//! first, and two other files had taken to importing `kafka/scram.zig` under the
//! name `random` to reach it - which is a file asking to exist.
//!
//! `std.crypto.random` is gone in this Zig and `arc4random` is not on musl, so
//! the system is asked directly. Never a pseudo-random fallback: a nonce that
//! can be guessed is worse than an error, because it fails quietly.

const std = @import("std");

pub fn bytes(into: []u8) !void {
	const fd = std.c.open("/dev/urandom", .{ .ACCMODE = .RDONLY });
	if (fd < 0) {
		return error.NoRandom;
	}
	defer _ = std.c.close(fd);
	var got: usize = 0;
	while (got < into.len) {
		const read = std.c.read(fd, into[got..].ptr, into.len - got);
		if (read <= 0) {
			return error.NoRandom;
		}
		got += @intCast(read);
	}
}

// ------------------------------------------------------------------- tests

test "randomness is available, and different every time" {
	var first: [24]u8 = undefined;
	var second: [24]u8 = undefined;
	try bytes(&first);
	try bytes(&second);
	try std.testing.expect(!std.mem.eql(u8, &first, &second));
	// And not simply left as it was.
	try std.testing.expect(!std.mem.allEqual(u8, &first, 0));

	// A buffer of no length is not an error, and does not touch anything.
	var none: [0]u8 = undefined;
	try bytes(&none);
}

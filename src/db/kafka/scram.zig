//! The parts of SCRAM that are text rather than conversation.
//!
//! SCRAM proves that a client knows a password without sending it, and that the
//! server knew it too. The exchange belongs with the connection; reading and
//! writing its messages, and the randomness a nonce needs, belong here - where they
//! can be checked against the example in RFC 5802 without a broker.

const std = @import("std");
const db = @import("../db.zig");
const random = @import("../random.zig");

const List = db.List;

/// A SCRAM message is a comma-separated list of `k=value`, and this is one of
/// them - the first with that letter, which is all SCRAM has.
pub fn fieldOf(message: []const u8, key: u8) ?[]const u8 {
	var parts = std.mem.tokenizeScalar(u8, message, ',');
	while (parts.next()) |part| {
		if (part.len >= 2 and part[0] == key and part[1] == '=') {
			return part[2..];
		}
	}
	return null;
}

/// A user name inside a SCRAM message, where a comma and an equals sign have to
/// be spelled out or they would end the field.
pub fn escapeName(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
	var out: List = .empty;
	for (name) |char| {
		switch (char) {
			'=' => try out.appendSlice(arena, "=3D"),
			',' => try out.appendSlice(arena, "=2C"),
			else => try out.append(arena, char),
		}
	}
	return out.items;
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

test "SCRAM's messages are read and written the way the standard spells them" {
	var arena = std.heap.ArenaAllocator.init(testing.allocator);
	defer arena.deinit();
	const a = arena.allocator();

	const server_first = "r=abcdefXYZ,s=QSXCR+Q6sek8bf92,i=4096";
	try testing.expectEqualStrings("abcdefXYZ", fieldOf(server_first, 'r').?);
	try testing.expectEqualStrings("QSXCR+Q6sek8bf92", fieldOf(server_first, 's').?);
	try testing.expectEqualStrings("4096", fieldOf(server_first, 'i').?);
	try testing.expect(fieldOf(server_first, 'v') == null);
	try testing.expectEqualStrings("rmF9pqV8S7suAoZWja4dJRkFsKQ=", fieldOf("v=rmF9pqV8S7suAoZWja4dJRkFsKQ=", 'v').?);
	try testing.expectEqualStrings("invalid-proof", fieldOf("e=invalid-proof", 'e').?);

	// A comma or an equals sign in a user name would end the field, so they are
	// spelled out.
	try testing.expectEqualStrings("a=2Cb=3Dc", try escapeName(a, "a,b=c"));
	try testing.expectEqualStrings("plain", try escapeName(a, "plain"));
}

test "the proof is the client key against its signature, as RFC 5802 has it" {
	// The example from the RFC: user "user", password "pencil", and the salt and
	// nonces it gives. If this matches, the derivation and the exclusive-or are
	// right, which is the part a broker checks.
	const Hmac = std.crypto.auth.hmac.HmacSha1;
	const Hash = std.crypto.hash.Sha1;
	const base64 = std.base64.standard;
	// Twelve bytes, not sixteen: the length has to come from the base64 itself, and
	// getting that wrong is exactly the bug this test caught when it was written.
	const salt_text = "QSXCR+Q6sek8bf92";
	var salt: [try base64.Decoder.calcSizeForSlice(salt_text)]u8 = undefined;
	try base64.Decoder.decode(&salt, salt_text);

	var salted: [Hmac.mac_length]u8 = undefined;
	try std.crypto.pwhash.pbkdf2(&salted, "pencil", &salt, 4096, Hmac);
	var client_key: [Hmac.mac_length]u8 = undefined;
	Hmac.create(&client_key, "Client Key", &salted);
	var stored_key: [Hash.digest_length]u8 = undefined;
	Hash.hash(&client_key, &stored_key, .{});

	const auth_message = "n=user,r=fyko+d2lbbFgONRv9qkxdawL," ++
		"r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j,s=QSXCR+Q6sek8bf92,i=4096," ++
		"c=biws,r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j";
	var signature: [Hmac.mac_length]u8 = undefined;
	Hmac.create(&signature, auth_message, &stored_key);
	var proof: [Hmac.mac_length]u8 = undefined;
	for (client_key, signature, 0..) |key_byte, signature_byte, i| {
		proof[i] = key_byte ^ signature_byte;
	}
	var buffer: [base64.Encoder.calcSize(Hmac.mac_length)]u8 = undefined;
	try testing.expectEqualStrings("v0X8v3Bz2T0CJGbJQyF0X+HI4Ts=", base64.Encoder.encode(&buffer, &proof));

	// And the server's half, which this driver checks so that a broker cannot
	// merely claim the password was right.
	var server_key: [Hmac.mac_length]u8 = undefined;
	Hmac.create(&server_key, "Server Key", &salted);
	var server_signature: [Hmac.mac_length]u8 = undefined;
	Hmac.create(&server_signature, auth_message, &server_key);
	try testing.expectEqualStrings("rmF9pqV8S7suAoZWja4dJRkFsKQ=", base64.Encoder.encode(&buffer, &server_signature));
}

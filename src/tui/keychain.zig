//! The macOS keychain, for connections that keep a password without putting it in
//! a file.
//!
//! A generic password item under the service `krtek`, with the connection's
//! target as the account - so `mysql://root@127.0.0.1:3307/demo` is one item and
//! renaming the connection does not lose it. The password never touches
//! `~/.config/krtek/connections`; that file only says `keychain`.
//!
//! Security.framework is called directly rather than through `/usr/bin/security`,
//! because the command line tool takes the password as an argument, and an
//! argument is visible to anyone running `ps` for as long as the process lives.
//!
//! **The keychain asks before it hands anything over.** An item remembers which
//! binary created it, and a binary rebuilt from changed source is a different one,
//! so macOS puts up its own dialog - "krtek wants to use your confidential
//! information" - and the answer is the user's, not this program's. Nothing here
//! tries to work around that; `fetch` simply returns null if it is refused, and
//! the app then asks for the password the way it always did.

const std = @import("std");
const builtin = @import("builtin");

/// Only macOS has this; everywhere else the option is not offered.
pub const available = builtin.os.tag == .macos;

const SERVICE = "krtek";

/// Put `password` in the keychain for `account`, replacing what was there.
pub fn store(account: []const u8, password: []const u8) !void {
	if (!available) {
		return error.Unsupported;
	}
	const service_key = try string(SERVICE);
	defer release(service_key);
	const account_key = try string(account);
	defer release(account_key);
	const secret = CFDataCreate(null, password.ptr, @intCast(password.len)) orelse return error.OutOfMemory;
	defer release(secret);

	// Update first: adding a second item for the same account would fail.
	{
		const query = try dictionary(&.{
			.{ kSecClass, kSecClassGenericPassword },
			.{ kSecAttrService, service_key },
			.{ kSecAttrAccount, account_key },
		});
		defer release(query);
		const changes = try dictionary(&.{.{ kSecValueData, secret }});
		defer release(changes);
		if (SecItemUpdate(query, changes) == 0) {
			return;
		}
	}
	const item = try dictionary(&.{
		.{ kSecClass, kSecClassGenericPassword },
		.{ kSecAttrService, service_key },
		.{ kSecAttrAccount, account_key },
		.{ kSecValueData, secret },
	});
	defer release(item);
	if (SecItemAdd(item, null) != 0) {
		return error.Refused;
	}
}

/// The password for `account`, or null when there is none or the keychain says
/// no. The caller owns what comes back.
pub fn fetch(allocator: std.mem.Allocator, account: []const u8) !?[]u8 {
	if (!available) {
		return null;
	}
	const service_key = try string(SERVICE);
	defer release(service_key);
	const account_key = try string(account);
	defer release(account_key);
	const query = try dictionary(&.{
		.{ kSecClass, kSecClassGenericPassword },
		.{ kSecAttrService, service_key },
		.{ kSecAttrAccount, account_key },
		.{ kSecReturnData, kCFBooleanTrue },
		.{ kSecMatchLimit, kSecMatchLimitOne },
	});
	defer release(query);

	var found: ?*const anyopaque = null;
	if (SecItemCopyMatching(query, &found) != 0) {
		return null;
	}
	const data = found orelse return null;
	defer release(data);
	const bytes = CFDataGetBytePtr(data) orelse return null;
	const length: usize = @intCast(CFDataGetLength(data));
	return try allocator.dupe(u8, bytes[0..length]);
}

/// Forget the password for `account`. A missing item is not an error.
pub fn remove(account: []const u8) void {
	if (!available) {
		return;
	}
	const service_key = string(SERVICE) catch return;
	defer release(service_key);
	const account_key = string(account) catch return;
	defer release(account_key);
	const query = dictionary(&.{
		.{ kSecClass, kSecClassGenericPassword },
		.{ kSecAttrService, service_key },
		.{ kSecAttrAccount, account_key },
	}) catch return;
	defer release(query);
	_ = SecItemDelete(query);
}

// ------------------------------------------------- Core Foundation, minimally

const CFRef = *const anyopaque;

fn string(text: []const u8) !CFRef {
	return CFStringCreateWithBytes(null, text.ptr, @intCast(text.len), kCFStringEncodingUTF8, 0) orelse
		error.OutOfMemory;
}

/// A CFDictionary out of key/value pairs, which is how every Security call takes
/// its arguments.
fn dictionary(pairs: []const [2]CFRef) !CFRef {
	var keys: [8]CFRef = undefined;
	var values: [8]CFRef = undefined;
	if (pairs.len > keys.len) {
		return error.TooMany;
	}
	for (pairs, 0..) |pair, i| {
		keys[i] = pair[0];
		values[i] = pair[1];
	}
	return CFDictionaryCreate(
		null,
		&keys,
		&values,
		@intCast(pairs.len),
		&kCFTypeDictionaryKeyCallBacks,
		&kCFTypeDictionaryValueCallBacks,
	) orelse error.OutOfMemory;
}

fn release(ref: CFRef) void {
	CFRelease(ref);
}

const kCFStringEncodingUTF8: u32 = 0x08000100;

extern "c" fn CFStringCreateWithBytes(
	allocator: ?CFRef,
	bytes: [*]const u8,
	length: isize,
	encoding: u32,
	external: u8,
) ?CFRef;
extern "c" fn CFDataCreate(allocator: ?CFRef, bytes: [*]const u8, length: isize) ?CFRef;
extern "c" fn CFDataGetBytePtr(data: CFRef) ?[*]const u8;
extern "c" fn CFDataGetLength(data: CFRef) isize;
extern "c" fn CFDictionaryCreate(
	allocator: ?CFRef,
	keys: [*]const CFRef,
	values: [*]const CFRef,
	count: isize,
	key_callbacks: ?*const anyopaque,
	value_callbacks: ?*const anyopaque,
) ?CFRef;
extern "c" fn CFRelease(ref: CFRef) void;

extern "c" const kCFTypeDictionaryKeyCallBacks: anyopaque;
extern "c" const kCFTypeDictionaryValueCallBacks: anyopaque;
extern "c" const kCFBooleanTrue: CFRef;

extern "c" fn SecItemAdd(attributes: CFRef, result: ?*?CFRef) i32;
extern "c" fn SecItemCopyMatching(query: CFRef, result: *?*const anyopaque) i32;
extern "c" fn SecItemUpdate(query: CFRef, changes: CFRef) i32;
extern "c" fn SecItemDelete(query: CFRef) i32;

extern "c" const kSecClass: CFRef;
extern "c" const kSecClassGenericPassword: CFRef;
extern "c" const kSecAttrService: CFRef;
extern "c" const kSecAttrAccount: CFRef;
extern "c" const kSecValueData: CFRef;
extern "c" const kSecReturnData: CFRef;
extern "c" const kSecMatchLimit: CFRef;
extern "c" const kSecMatchLimitOne: CFRef;

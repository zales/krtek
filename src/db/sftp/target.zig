//! What an SFTP target says, and the path arithmetic that goes with it.
//!
//!     sftp://user@host:22/path
//!     sftp://user@host?key=~/.ssh/id_ed25519
//!
//! A path in the target is where the connection starts; without one it starts
//! wherever the server puts you. The rest of this file is the small amount of
//! arithmetic a filesystem needs and an object store does not: joining, going up
//! a level, and the `drwxr-xr-x` that everybody can read at a glance.
//!
//! Text in, a structure out; no connection anywhere near it.

const std = @import("std");
const db = @import("../db.zig");
const ssh = @import("../ssh.zig");

const List = db.List;

const SCHEMES = [_][]const u8{ "sftp://", "ssh://", "scp://" };

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
	port: u16 = 22,
	user: []const u8 = "",
	password: []const u8 = "",
	/// A private key file named in the target. Empty means the usual ones are
	/// tried, and the agent before them.
	key: []const u8 = "",
	/// A passphrase for that key, which is not the login password.
	passphrase: []const u8 = "",
	/// Where to start. Empty means wherever the server puts us.
	path: []const u8 = "",
	/// Whether the host key has to be in known_hosts. Off is for a machine that
	/// has not been met before, and has to be asked for.
	verify: bool = true,
};

pub fn parse(arena: std.mem.Allocator, target: []const u8) !Parts {
	var self = Parts{};
	var rest = target;
	for (SCHEMES) |scheme| {
		if (std.ascii.startsWithIgnoreCase(rest, scheme)) {
			rest = rest[scheme.len..];
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
			const value = try unescape(arena, option[equals + 1 ..]);
			if (eql(name, "password")) {
				self.password = value;
			} else if (eql(name, "user") or eql(name, "username")) {
				self.user = value;
			} else if (eql(name, "key") or eql(name, "identity") or eql(name, "keyfile")) {
				self.key = value;
			} else if (eql(name, "passphrase")) {
				self.passphrase = value;
			} else if (eql(name, "path")) {
				self.path = value;
			} else if (eql(name, "insecure")) {
				self.verify = eql(value, "0");
			}
		}
	}

	var authority = rest;
	if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
		authority = rest[0..slash];
		// The path is what follows the host, and it is absolute: `sftp://h/etc`
		// means /etc, as scp and every other tool has it.
		self.path = try unescape(arena, rest[slash..]);
	}
	if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| {
		const userinfo = authority[0..at];
		authority = authority[at + 1 ..];
		if (std.mem.indexOfScalar(u8, userinfo, ':')) |colon| {
			self.user = try unescape(arena, userinfo[0..colon]);
			self.password = try unescape(arena, userinfo[colon + 1 ..]);
		} else {
			self.user = try unescape(arena, userinfo);
		}
	}

	var host = authority;
	if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
		if (std.fmt.parseInt(u16, authority[colon + 1 ..], 10)) |value| {
			host = authority[0..colon];
			self.port = value;
		} else |_| {}
	}
	if (host.len != 0) {
		self.host = try arena.dupe(u8, host);
	}
	// No user named is this machine's user, which is what ssh does.
	if (self.user.len == 0) {
		self.user = getenv("USER") orelse getenv("LOGNAME") orelse "root";
	}
	if (self.key.len != 0) {
		self.key = try expand(arena, self.key);
	}
	return self;
}

/// `~/…` as the shell would have it, because a key is written that way or not
/// at all.
pub fn expand(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
	if (!std.mem.startsWith(u8, path, "~/")) {
		return path;
	}
	const home = getenv("HOME") orelse return path;
	return std.fmt.allocPrint(arena, "{s}{s}", .{ home, path[1..] });
}

// ------------------------------------------------------------------- paths

/// One path from two, without the doubled slash and without the missing one.
pub fn join(arena: std.mem.Allocator, base: []const u8, name: []const u8) ![]const u8 {
	if (name.len != 0 and name[0] == '/') {
		return name;
	}
	if (base.len == 0) {
		return std.fmt.allocPrint(arena, "/{s}", .{name});
	}
	const trimmed = if (base.len > 1) std.mem.trimEnd(u8, base, "/") else base;
	if (name.len == 0) {
		return trimmed;
	}
	if (std.mem.eql(u8, trimmed, "/")) {
		return std.fmt.allocPrint(arena, "/{s}", .{name});
	}
	return std.fmt.allocPrint(arena, "{s}/{s}", .{ trimmed, name });
}

/// The directory above this one. The root is its own parent, which is what stops
/// `..` from walking off the top.
pub fn parent(path: []const u8) []const u8 {
	const trimmed = if (path.len > 1) std.mem.trimEnd(u8, path, "/") else path;
	const slash = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return "/";
	if (slash == 0) {
		return "/";
	}
	return trimmed[0..slash];
}

/// The last part of a path, which is what a directory is called.
pub fn basename(path: []const u8) []const u8 {
	const trimmed = if (path.len > 1) std.mem.trimEnd(u8, path, "/") else path;
	if (std.mem.eql(u8, trimmed, "/") or trimmed.len == 0) {
		return "/";
	}
	const slash = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return trimmed;
	return trimmed[slash + 1 ..];
}

/// `drwxr-xr-x`, as every listing since 1971 has shown it.
pub fn mode(into: *[10]u8, permissions: c_ulong) []const u8 {
	into[0] = switch (permissions & ssh.S_IFMT) {
		ssh.S_IFDIR => 'd',
		ssh.S_IFLNK => 'l',
		else => '-',
	};
	const bits = "rwxrwxrwx";
	var at: usize = 0;
	while (at < 9) : (at += 1) {
		const flag = @as(c_ulong, 1) << @intCast(8 - at);
		into[at + 1] = if (permissions & flag != 0) bits[at] else '-';
	}
	return into[0..];
}

/// A `chmod 644` back into the bits, taking either the numbers or the letters.
pub fn parseMode(text: []const u8) ?c_ulong {
	const trimmed = std.mem.trim(u8, text, " \t");
	if (trimmed.len == 0) {
		return null;
	}
	if (std.fmt.parseInt(c_ulong, trimmed, 8)) |value| {
		return value & 0o7777;
	} else |_| {}
	// The other way it is written: rwxr-xr-x, with or without the type in front.
	const letters = if (trimmed.len == 10) trimmed[1..] else trimmed;
	if (letters.len != 9) {
		return null;
	}
	var value: c_ulong = 0;
	for (letters, 0..) |letter, at| {
		if (letter != '-') {
			value |= @as(c_ulong, 1) << @intCast(8 - at);
		}
	}
	return value;
}

/// A unix time as something readable, in UTC - a server's clock is not in
/// anybody's local time either.
pub fn stamp(arena: std.mem.Allocator, seconds: c_ulong) ![]const u8 {
	if (seconds == 0) {
		return "";
	}
	const moment = std.time.epoch.EpochSeconds{ .secs = @intCast(seconds) };
	const day = moment.getEpochDay().calculateYearDay();
	const month_day = day.calculateMonthDay();
	const clock = moment.getDaySeconds();
	return std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
		day.year,
		month_day.month.numeric(),
		month_day.day_index + 1,
		clock.getHoursIntoDay(),
		clock.getMinutesIntoHour(),
		clock.getSecondsIntoMinute(),
	});
}

fn eql(left: []const u8, right: []const u8) bool {
	return std.ascii.eqlIgnoreCase(left, right);
}

fn getenv(name: [:0]const u8) ?[]const u8 {
	const value = std.c.getenv(name.ptr) orelse return null;
	const text = std.mem.sliceTo(value, 0);
	return if (text.len == 0) null else text;
}

fn unescape(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
	if (std.mem.indexOfScalar(u8, text, '%') == null) {
		return text;
	}
	var out: List = .empty;
	var at: usize = 0;
	while (at < text.len) {
		if (text[at] == '%' and at + 2 < text.len) {
			const high = std.fmt.charToDigit(text[at + 1], 16) catch {
				try out.append(arena, text[at]);
				at += 1;
				continue;
			};
			const low = std.fmt.charToDigit(text[at + 2], 16) catch {
				try out.append(arena, text[at]);
				at += 1;
				continue;
			};
			try out.append(arena, high * 16 + low);
			at += 3;
			continue;
		}
		try out.append(arena, text[at]);
		at += 1;
	}
	return out.items;
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

test "a target says where and as whom" {
	var scratch = std.heap.ArenaAllocator.init(testing.allocator);
	defer scratch.deinit();
	const arena = scratch.allocator();

	{
		const parts = try parse(arena, "sftp://foo@example.com:2222/srv/data");
		try testing.expectEqualStrings("example.com", parts.host);
		try testing.expectEqual(@as(u16, 2222), parts.port);
		try testing.expectEqualStrings("foo", parts.user);
		// The path is absolute, as scp has it.
		try testing.expectEqualStrings("/srv/data", parts.path);
		try testing.expect(parts.verify);
	}
	{
		const parts = try parse(arena, "sftp://alice:hunter2@backup");
		try testing.expectEqualStrings("alice", parts.user);
		try testing.expectEqualStrings("hunter2", parts.password);
		try testing.expectEqualStrings("backup", parts.host);
		try testing.expectEqual(@as(u16, 22), parts.port);
		// Nothing said is wherever the server puts us.
		try testing.expectEqualStrings("", parts.path);
	}
	{
		const parts = try parse(arena, "sftp://h?user=bob&password=p%40ss&key=/tmp/id_ed25519&insecure=1");
		try testing.expectEqualStrings("bob", parts.user);
		try testing.expectEqualStrings("p@ss", parts.password);
		try testing.expectEqualStrings("/tmp/id_ed25519", parts.key);
		try testing.expect(!parts.verify);
	}
	try testing.expect(owns("sftp://h/x"));
	try testing.expect(owns("ssh://h"));
	try testing.expect(!owns("s3://bucket"));
	try testing.expect(!owns("/tmp/x.db"));
}

test "paths are joined, and the root is its own parent" {
	var scratch = std.heap.ArenaAllocator.init(testing.allocator);
	defer scratch.deinit();
	const arena = scratch.allocator();

	try testing.expectEqualStrings("/srv/data/a.txt", try join(arena, "/srv/data", "a.txt"));
	try testing.expectEqualStrings("/srv/data/a.txt", try join(arena, "/srv/data/", "a.txt"));
	try testing.expectEqualStrings("/a.txt", try join(arena, "/", "a.txt"));
	// An absolute name is where it says, whatever it was joined to.
	try testing.expectEqualStrings("/etc/hosts", try join(arena, "/srv", "/etc/hosts"));

	try testing.expectEqualStrings("/srv", parent("/srv/data"));
	try testing.expectEqualStrings("/srv", parent("/srv/data/"));
	try testing.expectEqualStrings("/", parent("/srv"));
	// Walking up from the top stays at the top rather than falling off it.
	try testing.expectEqualStrings("/", parent("/"));

	try testing.expectEqualStrings("data", basename("/srv/data"));
	try testing.expectEqualStrings("data", basename("/srv/data/"));
	try testing.expectEqualStrings("/", basename("/"));
}

test "the mode is read and written the way ls and chmod do" {
	var buffer: [10]u8 = undefined;
	try testing.expectEqualStrings("drwxr-xr-x", mode(&buffer, ssh.S_IFDIR | 0o755));
	try testing.expectEqualStrings("-rw-r--r--", mode(&buffer, ssh.S_IFREG | 0o644));
	try testing.expectEqualStrings("lrwxrwxrwx", mode(&buffer, ssh.S_IFLNK | 0o777));
	try testing.expectEqualStrings("----------", mode(&buffer, 0));

	try testing.expectEqual(@as(c_ulong, 0o644), parseMode("644").?);
	try testing.expectEqual(@as(c_ulong, 0o755), parseMode(" 0755 ").?);
	// The letters back into the bits, with or without the type in front.
	try testing.expectEqual(@as(c_ulong, 0o644), parseMode("-rw-r--r--").?);
	try testing.expectEqual(@as(c_ulong, 0o755), parseMode("rwxr-xr-x").?);
	try testing.expect(parseMode("") == null);
	try testing.expect(parseMode("nonsense") == null);
}

test "a timestamp is readable and in UTC" {
	var scratch = std.heap.ArenaAllocator.init(testing.allocator);
	defer scratch.deinit();
	try testing.expectEqualStrings("2026-08-12 17:16:08", try stamp(scratch.allocator(), 1786554968));
	// Nothing said is nothing shown, rather than 1970.
	try testing.expectEqualStrings("", try stamp(scratch.allocator(), 0));
}

//! A place that holds files, whichever kind of place it is.
//!
//! SFTP, S3 and Azure each grew their own vocabulary for the same six or seven
//! operations, and the local disk had none at all - which is why nothing could
//! be copied from one to the other. This file is the one vocabulary: list a
//! directory, open a file for reading, create one for writing, make a directory,
//! remove something, rename it. A `Store` is a tagged union over the places that
//! can do those, and `copy` moves bytes between any two of them without knowing
//! which they are.
//!
//! The local disk is a `Store` like the others rather than a special case. That
//! is the whole trick: upload and download stop being two features and become
//! one, and copying from one bucket to another - or from a NAS into S3 - costs
//! nothing extra.
//!
//! Everything streams. A file is read a block at a time and written a block at a
//! time, so the size of what is copied has nothing to do with the memory it
//! takes. The object stores cannot stream a body out of a socket without
//! rewriting the HTTP client, so they ask for ranges instead: the effect is the
//! same and a failed range can be asked for again.

const std = @import("std");
const clock = @import("clock.zig");
const builtin = @import("builtin");
const db = @import("db.zig");

const List = db.List;

/// How much moves at once. Large enough that a local copy is not a syscall per
/// mouthful, small enough to stay out of the way on a machine doing other work.
pub const BLOCK: usize = 256 << 10;

pub const Error = error{ Store, OutOfMemory };

pub const Kind = enum { file, dir };

/// One thing in a directory. `modified` is unix seconds and zero where the place
/// does not say - S3 gives a time for an object and nothing for a prefix.
pub const Entry = struct {
	name: []const u8,
	kind: Kind = .file,
	size: u64 = 0,
	modified: i64 = 0,
};

// -------------------------------------------------------------------- paths

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

/// Whether `inner` is `outer` or sits underneath it. Copying a directory into
/// itself is the one mistake a file manager can make that eats the disk, so it
/// is asked about before anything is written.
pub fn within(outer: []const u8, inner: []const u8) bool {
	// A `..` anywhere means the text says one thing and the filesystem will do
	// another, and this comparison is text. Rather than resolve it - which needs to
	// know about symlinks to be right - a path with one in it is simply not inside
	// anything.
	if (climbs(inner)) {
		return false;
	}
	const top = std.mem.trimEnd(u8, outer, "/");
	if (top.len == 0) {
		return true;
	}
	if (!std.mem.startsWith(u8, inner, top)) {
		return false;
	}
	return inner.len == top.len or inner[top.len] == '/';
}

/// Whether a path has a `..` as one of its parts. `a..b` and `..hidden` are
/// ordinary names and do not count.
pub fn climbs(path: []const u8) bool {
	var parts = std.mem.splitScalar(u8, path, '/');
	while (parts.next()) |part| {
		if (std.mem.eql(u8, part, "..")) {
			return true;
		}
	}
	return false;
}

/// Whether a name out of a listing may be joined onto a path.
///
/// A listing comes from the other end of a connection, and an S3 key is any string
/// somebody was allowed to write. A name with a slash in it, or one that is `..`,
/// moves the write somewhere the user did not choose: downloading a tree from a
/// server that is not yours could then land a file in /etc. Nothing checked this,
/// and `within` - which exists for exactly that - was called by nothing but its own
/// tests.
pub fn plainName(name: []const u8) bool {
	if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) {
		return false;
	}
	// A slash and a NUL, and nothing else: a backslash is an ordinary character in a
	// name on the systems this runs on, and refusing it would turn a legitimate
	// download into a refusal.
	for (name) |char| {
		if (char == '/' or char == 0) {
			return false;
		}
	}
	return true;
}

/// `~` back to the home directory, because a path typed by a person has one in
/// it and no system call understands it.
pub fn expand(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
	if (!std.mem.eql(u8, path, "~") and !std.mem.startsWith(u8, path, "~/")) {
		return path;
	}
	const home = std.c.getenv("HOME") orelse return path;
	return std.fmt.allocPrint(arena, "{s}{s}", .{ std.mem.sliceTo(home, 0), path[1..] });
}

// ------------------------------------------------------------- the local disk

/// The machine this is running on, as a place that holds files.
pub const Local = struct {
	trouble: List = .empty,
	allocator: std.mem.Allocator,

	pub fn init(allocator: std.mem.Allocator) Local {
		return .{ .allocator = allocator };
	}

	pub fn deinit(self: *Local) void {
		self.trouble.deinit(self.allocator);
	}

	pub fn label(_: *Local) []const u8 {
		return "local";
	}

	pub fn message(self: *Local) []const u8 {
		return self.trouble.items;
	}

	fn blame(self: *Local, comptime fmt: []const u8, args: anytype) Error {
		self.trouble.clearRetainingCapacity();
		self.trouble.print(self.allocator, fmt, args) catch {};
		self.trouble.print(self.allocator, " - {s}", .{describe()}) catch {};
		return error.Store;
	}

	/// Where a person starts: their own home, not wherever the program was run.
	pub fn start(self: *Local, arena: std.mem.Allocator) Error![]const u8 {
		_ = self;
		return expand(arena, "~") catch return error.OutOfMemory;
	}

	pub fn list(self: *Local, arena: std.mem.Allocator, path: []const u8) Error![]Entry {
		const zero = zeroed(arena, path) catch return error.OutOfMemory;
		const dir = std.c.opendir(zero) orelse return self.blame("cannot open {s}", .{path});
		defer _ = std.c.closedir(dir);

		var out: std.ArrayListUnmanaged(Entry) = .empty;
		while (std.c.readdir(dir)) |found| {
			const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&found.name)), 0);
			if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) {
				continue;
			}
			const full = join(arena, path, name) catch return error.OutOfMemory;
			// The type in the directory entry is enough to draw a listing, but a
			// symlink has to be followed to say what it points at, and only stat
			// knows the size and the time. A listing that cannot be stat'd - a
			// dangling link, a directory being emptied underneath us - is still
			// shown, because leaving it out is how a file manager lies.
			var entry = Entry{
				.name = arena.dupe(u8, name) catch return error.OutOfMemory,
				.kind = if (found.type == std.c.DT.DIR) .dir else .file,
			};
			const zero_full = zeroed(arena, full) catch return error.OutOfMemory;
			if (look(zero_full)) |facts| {
				entry.kind = facts.kind;
				entry.size = facts.size;
				entry.modified = facts.modified;
			}
			out.append(arena, entry) catch return error.OutOfMemory;
		}
		return out.items;
	}

	pub fn stat(self: *Local, arena: std.mem.Allocator, path: []const u8) Error!Entry {
		const zero = zeroed(arena, path) catch return error.OutOfMemory;
		var facts = look(zero) orelse return self.blame("cannot look at {s}", .{path});
		facts.name = basename(path);
		return facts;
	}

	pub fn openRead(self: *Local, arena: std.mem.Allocator, path: []const u8) Error!Reading {
		const zero = zeroed(arena, path) catch return error.OutOfMemory;
		const file = std.c.fopen(zero, "rb") orelse return self.blame("cannot read {s}", .{path});
		return .{ .file = file };
	}

	pub fn openWrite(self: *Local, arena: std.mem.Allocator, path: []const u8, _: u64) Error!Writing {
		const zero = zeroed(arena, path) catch return error.OutOfMemory;
		const file = std.c.fopen(zero, "wb") orelse return self.blame("cannot write {s}", .{path});
		return .{ .file = file, .owner = self };
	}

	pub fn makeDir(self: *Local, arena: std.mem.Allocator, path: []const u8) Error!void {
		const zero = zeroed(arena, path) catch return error.OutOfMemory;
		if (std.c.mkdir(zero, 0o755) != 0) {
			// Already being there is what was wanted, not a failure.
			if (std.c._errno().* == @intFromEnum(std.c.E.EXIST)) {
				return;
			}
			return self.blame("cannot create {s}", .{path});
		}
	}

	pub fn remove(self: *Local, arena: std.mem.Allocator, path: []const u8, kind: Kind) Error!void {
		const zero = zeroed(arena, path) catch return error.OutOfMemory;
		const failed = if (kind == .dir) std.c.rmdir(zero) != 0 else std.c.unlink(zero) != 0;
		if (failed) {
			return self.blame("cannot remove {s}", .{path});
		}
	}

	pub fn rename(self: *Local, arena: std.mem.Allocator, from: []const u8, to: []const u8) Error!void {
		const from_zero = zeroed(arena, from) catch return error.OutOfMemory;
		const to_zero = zeroed(arena, to) catch return error.OutOfMemory;
		if (std.c.rename(from_zero, to_zero) != 0) {
			return self.blame("cannot rename {s}", .{from});
		}
	}

	/// A file being read. Through stdio rather than raw descriptors because that
	/// is what the rest of this program does, and because it buffers.
	pub const Reading = struct {
		file: *std.c.FILE,

		pub fn read(self: *Reading, into: []u8) Error!usize {
			const got = std.c.fread(into.ptr, 1, into.len, self.file);
			// Short is not the same as broken: a read stops at the end of the file
			// as well, and only ferror tells the two apart.
			if (got == 0 and ferror(self.file) != 0) {
				return error.Store;
			}
			return got;
		}

		pub fn close(self: *Reading) void {
			_ = std.c.fclose(self.file);
		}
	};

	pub const Writing = struct {
		file: *std.c.FILE,
		owner: *Local,

		pub fn write(self: *Writing, bytes: []const u8) Error!void {
			if (bytes.len == 0) {
				return;
			}
			if (std.c.fwrite(bytes.ptr, 1, bytes.len, self.file) != bytes.len) {
				return self.owner.blame("cannot write to the file", .{});
			}
		}

		/// Says whether the bytes actually landed. Closing a file is the last
		/// chance the system has to report a full disk, and a copy that ignores it
		/// reports success for a truncated file.
		pub fn finish(self: *Writing) Error!void {
			if (std.c.fclose(self.file) != 0) {
				return self.owner.blame("cannot finish writing the file", .{});
			}
		}

		pub fn abandon(self: *Writing) void {
			_ = std.c.fclose(self.file);
		}
	};
};

/// What the system knows about a path. The one place where the platforms part
/// company: this Zig routes Linux to `statx` and leaves `fstatat` undefined
/// there, so asking the same question takes two different calls. Null where the
/// path cannot be looked at, which a listing survives - a dangling link or a
/// directory being emptied underneath is still worth showing.
fn look(path: [*:0]const u8) ?Entry {
	if (builtin.os.tag == .linux) {
		const linux = std.os.linux;
		var facts: linux.Statx = undefined;
		// The syscall rather than the libc wrapper: musl grew one late and a static
		// build should not depend on which.
		const rc = linux.statx(linux.AT.FDCWD, path, 0, .{
			.TYPE = true,
			.SIZE = true,
			.MTIME = true,
		}, &facts);
		// A syscall says it failed by coming back negative; there is no errno here.
		if (@as(isize, @bitCast(rc)) < 0) {
			return null;
		}
		return .{
			.name = "",
			.kind = if (facts.mode & linux.S.IFMT == linux.S.IFDIR) .dir else .file,
			.size = facts.size,
			.modified = facts.mtime.sec,
		};
	}
	var facts: std.c.Stat = undefined;
	if (std.c.fstatat(std.c.AT.FDCWD, path, &facts, 0) != 0) {
		return null;
	}
	return .{
		.name = "",
		.kind = if (facts.mode & std.c.S.IFMT == std.c.S.IFDIR) .dir else .file,
		.size = @intCast(@max(facts.size, 0)),
		.modified = facts.mtime().sec,
	};
}

fn zeroed(arena: std.mem.Allocator, path: []const u8) ![:0]const u8 {
	return arena.dupeZ(u8, path);
}

/// What the system last complained about, in its own words. Declared here
/// because this Zig's `std.c` carries `gai_strerror` and not the plain one.
extern fn strerror(code: c_int) [*:0]const u8;
extern fn ferror(file: *std.c.FILE) c_int;

fn describe() []const u8 {
	return std.mem.sliceTo(strerror(std.c._errno().*), 0);
}

/// An open file on the other end of an SSH connection. A thin coat over
/// `ssh.File` and nothing more: a driver speaks its own errors and this speaks
/// the ones every place here speaks.
pub const Remote = struct {
	file: db.ssh.File,

	pub fn read(self: *Remote, into: []u8) Error!usize {
		return self.file.read(into) catch |err| translate(err);
	}

	pub fn write(self: *Remote, bytes: []const u8) Error!void {
		return self.file.write(bytes) catch |err| translate(err);
	}

	pub fn finish(self: *Remote) Error!void {
		return self.file.done() catch |err| translate(err);
	}

	pub fn close(self: *Remote) void {
		self.file.close();
	}

	pub fn abandon(self: *Remote) void {
		self.file.close();
	}
};

fn translate(err: anyerror) Error {
	return switch (err) {
		error.OutOfMemory => error.OutOfMemory,
		else => error.Store,
	};
}

// -------------------------------------------------------------- the union

/// Somewhere that holds files: the local disk, or a connection wearing the hat.
pub const Store = union(enum) {
	local: *Local,
	sftp: db.sftp.Db.Files,
	s3: db.s3.Db.Files,
	azure: db.azure.Db.Files,

	pub fn label(self: Store) []const u8 {
		switch (self) {
			inline else => |place| return place.label(),
		}
	}

	pub fn message(self: Store) []const u8 {
		switch (self) {
			inline else => |place| return place.message(),
		}
	}

	/// Where to open on, when nobody said where.
	pub fn start(self: Store, arena: std.mem.Allocator) Error![]const u8 {
		switch (self) {
			inline else => |place| return place.start(arena),
		}
	}

	pub fn list(self: Store, arena: std.mem.Allocator, path: []const u8) Error![]Entry {
		switch (self) {
			inline else => |place| return place.list(arena, path),
		}
	}

	pub fn stat(self: Store, arena: std.mem.Allocator, path: []const u8) Error!Entry {
		switch (self) {
			inline else => |place| return place.stat(arena, path),
		}
	}

	pub fn openRead(self: Store, arena: std.mem.Allocator, path: []const u8) Error!Reader {
		switch (self) {
			inline else => |place, tag| return @unionInit(
				Reader,
				@tagName(tag),
				try place.openRead(arena, path),
			),
		}
	}

	pub fn openWrite(self: Store, arena: std.mem.Allocator, path: []const u8, size: u64) Error!Writer {
		switch (self) {
			inline else => |place, tag| return @unionInit(
				Writer,
				@tagName(tag),
				try place.openWrite(arena, path, size),
			),
		}
	}

	pub fn makeDir(self: Store, arena: std.mem.Allocator, path: []const u8) Error!void {
		switch (self) {
			inline else => |place| return place.makeDir(arena, path),
		}
	}

	pub fn remove(self: Store, arena: std.mem.Allocator, path: []const u8, kind: Kind) Error!void {
		switch (self) {
			inline else => |place| return place.remove(arena, path, kind),
		}
	}

	pub fn rename(self: Store, arena: std.mem.Allocator, from: []const u8, to: []const u8) Error!void {
		switch (self) {
			inline else => |place| return place.rename(arena, from, to),
		}
	}
};

pub const Reader = union(enum) {
	local: Local.Reading,
	sftp: Remote,
	s3: db.s3.Db.Ranged,
	azure: db.azure.Db.Ranged,

	pub fn read(self: *Reader, into: []u8) Error!usize {
		switch (self.*) {
			inline else => |*one| return one.read(into),
		}
	}

	pub fn close(self: *Reader) void {
		switch (self.*) {
			inline else => |*one| one.close(),
		}
	}
};

pub const Writer = union(enum) {
	local: Local.Writing,
	sftp: Remote,
	s3: db.s3.Db.Upload,
	azure: db.azure.Db.Upload,

	pub fn write(self: *Writer, bytes: []const u8) Error!void {
		switch (self.*) {
			inline else => |*one| return one.write(bytes),
		}
	}

	pub fn finish(self: *Writer) Error!void {
		switch (self.*) {
			inline else => |*one| return one.finish(),
		}
	}

	pub fn abandon(self: *Writer) void {
		switch (self.*) {
			inline else => |*one| one.abandon(),
		}
	}
};

// -------------------------------------------------------------- copying

/// Called as bytes move. Returning false gives up on the copy, which is how
/// `ctrl+c` gets out of one.
pub const Watcher = struct {
	context: *anyopaque,
	step: *const fn (context: *anyopaque, name: []const u8, done: u64, total: u64) bool,

	fn call(self: Watcher, name: []const u8, done: u64, total: u64) bool {
		return self.step(self.context, name, done, total);
	}
};

pub const Tally = struct {
	files: usize = 0,
	dirs: usize = 0,
	bytes: u64 = 0,
	/// Entries whose names were not safe to write, left where they were. Counted
	/// rather than fatal: one strange name in a listing should not stop a transfer
	/// of ten thousand files, but it must not pass unmentioned either.
	refused: usize = 0,
};

pub const Trouble = struct {
	/// Whose message to show: the side that failed.
	text: []const u8 = "",
};

/// Copy one file. The target is a path, not a directory: whoever calls decides
/// what it is to be called at the other end.
pub fn copyFile(
	arena: std.mem.Allocator,
	from: Store,
	from_path: []const u8,
	to: Store,
	to_path: []const u8,
	size: u64,
	watcher: ?Watcher,
	tally: *Tally,
) Error!void {
	var source = try from.openRead(arena, from_path);
	defer source.close();
	var target = try to.openWrite(arena, to_path, size);
	// A copy given up on halfway leaves a part of a file behind, and the one
	// thing worse than no copy is half a copy that looks whole.
	errdefer target.abandon();

	const buffer = arena.alloc(u8, BLOCK) catch return error.OutOfMemory;
	var done: u64 = 0;
	while (true) {
		const got = try source.read(buffer);
		if (got == 0) {
			break;
		}
		try target.write(buffer[0..got]);
		done += got;
		tally.bytes += got;
		if (watcher) |eye| {
			if (!eye.call(from_path, done, size)) {
				return error.Store;
			}
		}
	}
	try target.finish();
	tally.files += 1;
}

/// Copy a file or a whole tree. `to_path` is the name the thing gets at the
/// other end, so copying `/a/b` to `/c/b` is what a file manager does when a
/// directory is highlighted and the other pane is `/c`.
pub fn copy(
	arena: std.mem.Allocator,
	from: Store,
	from_path: []const u8,
	to: Store,
	to_path: []const u8,
	watcher: ?Watcher,
) Error!Tally {
	var tally = Tally{};
	const what = try from.stat(arena, from_path);
	if (what.kind == .file) {
		try copyFile(arena, from, from_path, to, to_path, what.size, watcher, &tally);
		return tally;
	}
	try walk(arena, from, from_path, to, to_path, watcher, &tally, 0);
	return tally;
}

/// How deep a tree may go before this decides it is being walked in a circle.
/// Symlinks make that possible on a real filesystem and nobody nests a hundred
/// directories on purpose.
const DEPTH: usize = 100;

fn walk(
	arena: std.mem.Allocator,
	from: Store,
	from_path: []const u8,
	to: Store,
	to_path: []const u8,
	watcher: ?Watcher,
	tally: *Tally,
	depth: usize,
) Error!void {
	if (depth > DEPTH) {
		return error.Store;
	}
	try to.makeDir(arena, to_path);
	tally.dirs += 1;

	// Each directory gets its own memory: a tree of any size is then a matter of
	// how deep it goes and not of how many files it holds altogether.
	var scratch = std.heap.ArenaAllocator.init(arena);
	defer scratch.deinit();
	const here = scratch.allocator();

	const entries = try from.list(here, from_path);
	for (entries) |entry| {
		// The name came from the other end. Everything after this point writes to
		// this machine, so it is checked before it is joined onto anything - and the
		// result is checked again, which costs nothing and catches a `join` that
		// learns a new trick.
		if (!plainName(entry.name)) {
			tally.refused += 1;
			continue;
		}
		const source = join(here, from_path, entry.name) catch return error.OutOfMemory;
		const target = join(here, to_path, entry.name) catch return error.OutOfMemory;
		if (!within(to_path, target)) {
			tally.refused += 1;
			continue;
		}
		if (entry.kind == .dir) {
			try walk(arena, from, source, to, target, watcher, tally, depth + 1);
		} else {
			try copyFile(here, from, source, to, target, entry.size, watcher, tally);
		}
		if (watcher) |eye| {
			if (!eye.call(source, entry.size, entry.size)) {
				return error.Store;
			}
		}
	}
}

/// Remove a file, or a directory and everything under it.
pub fn removeAll(arena: std.mem.Allocator, place: Store, path: []const u8, depth: usize) Error!void {
	if (depth > DEPTH) {
		return error.Store;
	}
	const what = try place.stat(arena, path);
	if (what.kind == .file) {
		return place.remove(arena, path, .file);
	}
	var scratch = std.heap.ArenaAllocator.init(arena);
	defer scratch.deinit();
	const here = scratch.allocator();
	const entries = try place.list(here, path);
	for (entries) |entry| {
		const under = join(here, path, entry.name) catch return error.OutOfMemory;
		try removeAll(here, place, under, depth + 1);
	}
	try place.remove(arena, path, .dir);
}

// --------------------------------------------------------------------- tests

const testing = std.testing;

test "a path is joined without a doubled slash and without a missing one" {
	const arena = testing.allocator;
	{
		const got = try join(arena, "/a", "b");
		defer arena.free(got);
		try testing.expectEqualStrings("/a/b", got);
	}
	{
		const got = try join(arena, "/a/", "b");
		defer arena.free(got);
		try testing.expectEqualStrings("/a/b", got);
	}
	{
		const got = try join(arena, "/", "b");
		defer arena.free(got);
		try testing.expectEqualStrings("/b", got);
	}
	// An absolute name ignores the base, the way every shell has it.
	try testing.expectEqualStrings("/b", try join(arena, "/a", "/b"));
}

test "the root is its own parent, which is what stops .. at the top" {
	try testing.expectEqualStrings("/a", parent("/a/b"));
	try testing.expectEqualStrings("/", parent("/a"));
	try testing.expectEqualStrings("/", parent("/"));
	try testing.expectEqualStrings("/a", parent("/a/b/"));
}

test "a name is the last part of a path" {
	try testing.expectEqualStrings("b", basename("/a/b"));
	try testing.expectEqualStrings("b", basename("/a/b/"));
	try testing.expectEqualStrings("/", basename("/"));
	try testing.expectEqualStrings("a", basename("a"));
}

test "a name out of a listing is not trusted with where it lands" {
	// What an ordinary listing holds, dots and all.
	try testing.expect(plainName("notes.txt"));
	try testing.expect(plainName("..hidden"));
	try testing.expect(plainName("a..b"));
	try testing.expect(plainName("what a name"));
	// And what it must never be allowed to be: a path rather than a name.
	try testing.expect(!plainName(".."));
	try testing.expect(!plainName("."));
	try testing.expect(!plainName(""));
	try testing.expect(!plainName("../escaped"));
	try testing.expect(!plainName("/etc/cron.d/escaped"));
	try testing.expect(!plainName("sub/dir"));
	// A backslash is a character, not a separator, on a Mac and on Linux.
	try testing.expect(plainName("back\\slash"));
	try testing.expect(!plainName("nul\x00byte"));
}

test "containment sees through a climb, because the filesystem will" {
	try testing.expect(within("/a", "/a/b/c"));
	try testing.expect(within("/a", "/a"));
	try testing.expect(!within("/a", "/b"));
	// The three that used to pass: the text starts with /a and the write does not
	// end up there.
	try testing.expect(!within("/a", "/a/../b"));
	try testing.expect(!within("/a", "/a/b/../../c"));
	try testing.expect(!within("/a", "/a/.."));
	// A name that merely contains dots is not a climb.
	try testing.expect(within("/a", "/a/..hidden"));
	try testing.expect(within("/a", "/a/x..y"));
	try testing.expect(climbs("/a/../b"));
	try testing.expect(!climbs("/a/..b"));
}

test "a directory is not copied into itself" {
	try testing.expect(within("/a", "/a"));
	try testing.expect(within("/a", "/a/b"));
	try testing.expect(within("/a/", "/a/b"));
	try testing.expect(!within("/a", "/ab"));
	try testing.expect(!within("/a/b", "/a"));
	// Everything is under the root, including the root.
	try testing.expect(within("/", "/anything"));
}

test "a tree is copied whole, and then removed whole" {
	var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
	defer arena_state.deinit();
	const arena = arena_state.allocator();

	var disk = Local.init(testing.allocator);
	defer disk.deinit();
	const place = Store{ .local = &disk };

	// Somewhere of this test's own, so a machine running it twice at once does
	// not have the two of them treading on each other.
	const root = try std.fmt.allocPrint(arena, "/tmp/krtek-store-test-{d}", .{clock.steadyNanos()});
	removeAll(arena, place, root, 0) catch {};
	try place.makeDir(arena, root);
	defer removeAll(arena, place, root, 0) catch {};

	const source = try join(arena, root, "from");
	try place.makeDir(arena, source);
	try place.makeDir(arena, try join(arena, source, "deeper"));

	{
		var out = try place.openWrite(arena, try join(arena, source, "one.txt"), 0);
		try out.write("ahoj");
		try out.finish();
	}
	{
		var out = try place.openWrite(arena, try join(arena, source, "deeper/two.txt"), 0);
		try out.write("nazdar");
		try out.finish();
	}

	const target = try join(arena, root, "to");
	const tally = try copy(arena, place, source, place, target, null);
	try testing.expectEqual(@as(usize, 2), tally.files);
	try testing.expectEqual(@as(usize, 2), tally.dirs);
	try testing.expectEqual(@as(u64, 10), tally.bytes);

	{
		var in = try place.openRead(arena, try join(arena, target, "deeper/two.txt"));
		defer in.close();
		var buffer: [32]u8 = undefined;
		const got = try in.read(&buffer);
		try testing.expectEqualStrings("nazdar", buffer[0..got]);
	}

	// And a listing sees what was written, with the sizes.
	const entries = try place.list(arena, target);
	try testing.expectEqual(@as(usize, 2), entries.len);
	for (entries) |entry| {
		if (std.mem.eql(u8, entry.name, "one.txt")) {
			try testing.expectEqual(Kind.file, entry.kind);
			try testing.expectEqual(@as(u64, 4), entry.size);
		} else {
			try testing.expectEqualStrings("deeper", entry.name);
			try testing.expectEqual(Kind.dir, entry.kind);
		}
	}

	try removeAll(arena, place, target, 0);
	try testing.expectError(error.Store, place.stat(arena, target));
}

test "a file that is not there says which one" {
	var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
	defer arena_state.deinit();
	const arena = arena_state.allocator();

	var disk = Local.init(testing.allocator);
	defer disk.deinit();
	const place = Store{ .local = &disk };

	try testing.expectError(error.Store, place.list(arena, "/tmp/krtek-nothing-here-at-all"));
	try testing.expect(std.mem.indexOf(u8, place.message(), "krtek-nothing-here-at-all") != null);
	// And in the system's own words, so the reason is there too.
	try testing.expect(std.mem.indexOf(u8, place.message(), " - ") != null);
}

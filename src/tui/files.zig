//! Two panes, each showing a place that holds files, and copying between them.
//!
//! The panes are the same kind of thing: a `Store` and a path inside it. The
//! local disk is not the left one and the connection is not the right one -
//! either pane can be either, so the same three keys copy up, copy down, or copy
//! from one bucket to another, and none of them is a separate feature.
//!
//! What is here is the state and the moving around. The copying itself is in
//! `db/store.zig`, and the drawing and the keys are where all the other drawing
//! and keys are; this file knows nothing about a terminal.

const std = @import("std");
const database = @import("db");
const store = database.store;

const List = std.ArrayListUnmanaged(u8);

/// The name of the entry that means "the directory above". It is not something
/// the places report - it is put in front of every listing that has somewhere
/// to go back to, because that is what a person expects to see.
pub const UP = "..";

pub const Side = enum { left, right };

pub const Pane = struct {
	place: store.Store,
	/// Where this pane is looking, owned by the pane.
	path: List = .empty,
	/// The listing, in `held`. Both go together and are thrown away together.
	entries: []store.Entry = &.{},
	held: std.heap.ArenaAllocator,
	selected: usize = 0,
	scroll: usize = 0,
	/// Which entries are marked, by index into `entries`. Cleared whenever the
	/// listing is read again, because an index into a listing that has changed
	/// underneath is a way to delete the wrong file.
	marked: std.ArrayListUnmanaged(usize) = .empty,
	/// Why the last listing failed, or empty.
	trouble: List = .empty,

	pub fn init(allocator: std.mem.Allocator, place: store.Store) Pane {
		return .{ .place = place, .held = std.heap.ArenaAllocator.init(allocator) };
	}

	pub fn deinit(self: *Pane, allocator: std.mem.Allocator) void {
		self.path.deinit(allocator);
		self.marked.deinit(allocator);
		self.trouble.deinit(allocator);
		self.held.deinit();
	}

	pub fn where(self: *Pane) []const u8 {
		return if (self.path.items.len == 0) "/" else self.path.items;
	}

	pub fn goTo(self: *Pane, allocator: std.mem.Allocator, path: []const u8) !void {
		// Copied first: `path` is often a slice of the listing this is about to
		// throw away, and reading it afterwards would be reading freed memory.
		var next: List = .empty;
		try next.appendSlice(allocator, path);
		self.path.deinit(allocator);
		self.path = next;
		self.selected = 0;
		self.scroll = 0;
	}

	/// Read the directory again. A pane that cannot be read keeps its path and
	/// shows why, rather than jumping somewhere that does work.
	pub fn reload(self: *Pane, allocator: std.mem.Allocator) void {
		self.marked.clearRetainingCapacity();
		self.trouble.clearRetainingCapacity();
		_ = self.held.reset(.retain_capacity);
		const arena = self.held.allocator();

		const here = self.place.list(arena, self.where()) catch {
			self.entries = &.{};
			self.trouble.appendSlice(allocator, self.place.message()) catch {};
			return;
		};
		std.mem.sort(store.Entry, here, {}, before);

		const top = !std.mem.eql(u8, self.where(), "/");
		if (!top) {
			self.entries = here;
		} else {
			var all = arena.alloc(store.Entry, here.len + 1) catch {
				self.entries = here;
				return;
			};
			all[0] = .{ .name = UP, .kind = .dir };
			@memcpy(all[1..], here);
			self.entries = all;
		}
		if (self.selected >= self.entries.len) {
			self.selected = if (self.entries.len == 0) 0 else self.entries.len - 1;
		}
	}

	pub fn current(self: *Pane) ?store.Entry {
		if (self.selected >= self.entries.len) {
			return null;
		}
		return self.entries[self.selected];
	}

	pub fn isMarked(self: *Pane, at: usize) bool {
		return std.mem.indexOfScalar(usize, self.marked.items, at) != null;
	}

	pub fn toggleMark(self: *Pane, allocator: std.mem.Allocator, at: usize) !void {
		if (at >= self.entries.len or std.mem.eql(u8, self.entries[at].name, UP)) {
			return;
		}
		if (std.mem.indexOfScalar(usize, self.marked.items, at)) |found| {
			_ = self.marked.orderedRemove(found);
		} else {
			try self.marked.append(allocator, at);
		}
	}

	/// What an action applies to: everything marked, or the one under the cursor
	/// when nothing is. The `..` entry is never one of them.
	pub fn chosen(self: *Pane, arena: std.mem.Allocator) ![]store.Entry {
		if (self.marked.items.len != 0) {
			var out = try arena.alloc(store.Entry, self.marked.items.len);
			for (self.marked.items, 0..) |at, index| {
				out[index] = self.entries[at];
			}
			return out;
		}
		const one = self.current() orelse return &.{};
		if (std.mem.eql(u8, one.name, UP)) {
			return &.{};
		}
		const out = try arena.alloc(store.Entry, 1);
		out[0] = one;
		return out;
	}

	pub fn move(self: *Pane, by: isize) void {
		if (self.entries.len == 0) {
			self.selected = 0;
			return;
		}
		const last: isize = @intCast(self.entries.len - 1);
		var next: isize = @as(isize, @intCast(self.selected)) + by;
		if (next < 0) {
			next = 0;
		}
		if (next > last) {
			next = last;
		}
		self.selected = @intCast(next);
	}

	/// Keep the cursor on screen, given how many rows the pane has to draw in.
	pub fn follow(self: *Pane, rows: usize) void {
		if (rows == 0) {
			return;
		}
		if (self.selected < self.scroll) {
			self.scroll = self.selected;
		} else if (self.selected >= self.scroll + rows) {
			self.scroll = self.selected + 1 - rows;
		}
	}
};

/// Directories first and then by name, which is the order every file manager
/// has shown and the only one that makes a deep tree navigable.
fn before(_: void, left: store.Entry, right: store.Entry) bool {
	// `..` is not sorted with the rest; it is always the way out.
	const left_up = std.mem.eql(u8, left.name, UP);
	const right_up = std.mem.eql(u8, right.name, UP);
	if (left_up != right_up) {
		return left_up;
	}
	if ((left.kind == .dir) != (right.kind == .dir)) {
		return left.kind == .dir;
	}
	return std.ascii.lessThanIgnoreCase(left.name, right.name);
}

pub const Manager = struct {
	allocator: std.mem.Allocator,
	left: Pane,
	right: Pane,
	active: Side = .left,
	/// The local disk, which one of the panes points at. Owned here because a
	/// `Store` is a pointer to it and has to outlive both panes.
	disk: store.Local,

	pub fn init(allocator: std.mem.Allocator, far: ?store.Store) !*Manager {
		const self = try allocator.create(Manager);
		self.* = .{
			.allocator = allocator,
			.disk = store.Local.init(allocator),
			.left = undefined,
			.right = undefined,
		};
		const mine = store.Store{ .local = &self.disk };
		self.left = Pane.init(allocator, mine);
		self.right = Pane.init(allocator, far orelse mine);
		return self;
	}

	pub fn deinit(self: *Manager) void {
		self.left.deinit(self.allocator);
		self.right.deinit(self.allocator);
		self.disk.deinit();
		self.allocator.destroy(self);
	}

	/// Put each pane where it should start and read both listings.
	pub fn open(self: *Manager) !void {
		var scratch = std.heap.ArenaAllocator.init(self.allocator);
		defer scratch.deinit();
		const arena = scratch.allocator();
		inline for (.{ "left", "right" }) |name| {
			const pane = &@field(self, name);
			const start = pane.place.start(arena) catch "/";
			try pane.goTo(self.allocator, start);
			pane.reload(self.allocator);
		}
	}

	pub fn here(self: *Manager) *Pane {
		return if (self.active == .left) &self.left else &self.right;
	}

	pub fn there(self: *Manager) *Pane {
		return if (self.active == .left) &self.right else &self.left;
	}

	pub fn swap(self: *Manager) void {
		self.active = if (self.active == .left) .right else .left;
	}

	/// Walk into what the cursor is on, or back out of the directory when it is
	/// on `..`. Returns false when the cursor is on a file, which is not
	/// somewhere to go.
	pub fn enter(self: *Manager) !bool {
		const pane = self.here();
		const one = pane.current() orelse return false;
		if (std.mem.eql(u8, one.name, UP)) {
			try self.up();
			return true;
		}
		if (one.kind != .dir) {
			return false;
		}
		var scratch = std.heap.ArenaAllocator.init(self.allocator);
		defer scratch.deinit();
		const into = try store.join(scratch.allocator(), pane.where(), one.name);
		try pane.goTo(self.allocator, into);
		pane.reload(self.allocator);
		return true;
	}

	pub fn up(self: *Manager) !void {
		const pane = self.here();
		const was = pane.where();
		if (std.mem.eql(u8, was, "/")) {
			return;
		}
		var scratch = std.heap.ArenaAllocator.init(self.allocator);
		defer scratch.deinit();
		const leaving = try scratch.allocator().dupe(u8, store.basename(was));
		try pane.goTo(self.allocator, store.parent(was));
		pane.reload(self.allocator);
		// Land on the directory just left, the way every file manager does, so
		// walking out of a tree does not lose your place in it.
		for (pane.entries, 0..) |entry, at| {
			if (std.mem.eql(u8, entry.name, leaving)) {
				pane.selected = at;
				break;
			}
		}
	}

	pub fn reload(self: *Manager) void {
		self.left.reload(self.allocator);
		self.right.reload(self.allocator);
	}
};

// ------------------------------------------------------------------ showing

/// A size a person reads rather than counts. Kept to four characters where it
/// can be, because two panes on an eighty column terminal have no room to spare.
pub fn size(into: *[16]u8, bytes: u64) []const u8 {
	const units = [_][]const u8{ "B", "K", "M", "G", "T", "P" };
	var value: f64 = @floatFromInt(bytes);
	var unit: usize = 0;
	while (value >= 1024 and unit + 1 < units.len) : (unit += 1) {
		value /= 1024;
	}
	if (unit == 0) {
		return std.fmt.bufPrint(into, "{d}", .{bytes}) catch "?";
	}
	// One decimal only while it buys something: 1.5G says more than 1G, and
	// 234.0M says nothing that 234M does not.
	if (value < 10) {
		return std.fmt.bufPrint(into, "{d:.1}{s}", .{ value, units[unit] }) catch "?";
	}
	return std.fmt.bufPrint(into, "{d:.0}{s}", .{ value, units[unit] }) catch "?";
}

/// A name cut to fit, with an ellipsis where the rest was. Cutting bytes would
/// split a letter that takes more than one, so the cut lands on a boundary.
pub fn trim(name: []const u8, room: usize) []const u8 {
	if (name.len <= room or room < 2) {
		return name;
	}
	var at = room - 1;
	while (at > 0 and name[at] & 0xC0 == 0x80) : (at -= 1) {}
	return name[0..at];
}

/// A moment as a listing shows one. Unix seconds, and nothing at all for the
/// places that do not say - an epoch date pretending to be a modification time
/// is worse than a blank.
pub fn when(into: *[20]u8, seconds: i64) []const u8 {
	if (seconds <= 0) {
		return "";
	}
	const days_since = @divFloor(seconds, 86400);
	const in_day = seconds - days_since * 86400;
	const civil = fromDays(days_since);
	// Unsigned, or the padding puts a sign where a zero belongs: `+1970-+1-+1`.
	return std.fmt.bufPrint(into, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
		@as(u64, @intCast(@max(civil.year, 0))),
		@as(u64, @intCast(civil.month)),
		@as(u64, @intCast(civil.day)),
		@as(u64, @intCast(@divTrunc(in_day, 3600))),
		@as(u64, @intCast(@divTrunc(@mod(in_day, 3600), 60))),
	}) catch "";
}

const Civil = struct { year: i64, month: i64, day: i64 };

/// Days since 1970 back into a date. The inverse of the arithmetic every C
/// library hides inside gmtime, which is not portable enough to call here.
fn fromDays(count: i64) Civil {
	const shifted = count + 719468;
	const era = @divFloor(shifted, 146097);
	const of_era = shifted - era * 146097;
	const year_of_era = @divTrunc(of_era - @divTrunc(of_era, 1460) + @divTrunc(of_era, 36524) - @divTrunc(of_era, 146096), 365);
	const year = year_of_era + era * 400;
	const of_year = of_era - (365 * year_of_era + @divTrunc(year_of_era, 4) - @divTrunc(year_of_era, 100));
	const month_part = @divTrunc(5 * of_year + 2, 153);
	const day = of_year - @divTrunc(153 * month_part + 2, 5) + 1;
	const month = month_part + (if (month_part < 10) @as(i64, 3) else -9);
	return .{ .year = year + @intFromBool(month <= 2), .month = month, .day = day };
}

// -------------------------------------------------------------------- tests

const testing = std.testing;

test "directories come first, and the way out comes before them" {
	var entries = [_]store.Entry{
		.{ .name = "zebra.txt", .kind = .file },
		.{ .name = "Alpha", .kind = .dir },
		.{ .name = "apple.txt", .kind = .file },
		.{ .name = UP, .kind = .dir },
		.{ .name = "beta", .kind = .dir },
	};
	std.mem.sort(store.Entry, &entries, {}, before);
	try testing.expectEqualStrings(UP, entries[0].name);
	// Case is not a category: Alpha and beta belong next to each other.
	try testing.expectEqualStrings("Alpha", entries[1].name);
	try testing.expectEqualStrings("beta", entries[2].name);
	try testing.expectEqualStrings("apple.txt", entries[3].name);
	try testing.expectEqualStrings("zebra.txt", entries[4].name);
}

test "a size is read rather than counted" {
	var buffer: [16]u8 = undefined;
	try testing.expectEqualStrings("0", size(&buffer, 0));
	try testing.expectEqualStrings("512", size(&buffer, 512));
	try testing.expectEqualStrings("1.0K", size(&buffer, 1024));
	try testing.expectEqualStrings("1.5K", size(&buffer, 1536));
	// Past ten the decimal buys nothing and the width matters more.
	try testing.expectEqualStrings("234M", size(&buffer, 234 * 1024 * 1024));
	try testing.expectEqualStrings("1.0G", size(&buffer, 1024 * 1024 * 1024));
	// And it never runs out of units.
	try testing.expectEqualStrings("4.0P", size(&buffer, 4 * (1 << 50)));
}

test "a time with nothing behind it is left blank" {
	var buffer: [20]u8 = undefined;
	try testing.expectEqualStrings("", when(&buffer, 0));
	try testing.expectEqualStrings("", when(&buffer, -1));
	try testing.expectEqualStrings("1970-01-01 00:00", when(&buffer, 1));
	try testing.expectEqualStrings("2015-08-30 12:36", when(&buffer, 1440938160));
	// A leap day, which is where the arithmetic would go wrong if it did.
	try testing.expectEqualStrings("2024-02-29 12:00", when(&buffer, 1709208000));
}

test "the panes walk a real tree and come back out where they went in" {
	var scratch = std.heap.ArenaAllocator.init(testing.allocator);
	defer scratch.deinit();
	const arena = scratch.allocator();

	var moment: std.c.timespec = undefined;
	_ = std.c.clock_gettime(.REALTIME, &moment);
	const root = try std.fmt.allocPrint(arena, "/tmp/krtek-files-test-{d}", .{moment.nsec});

	var disk = store.Local.init(testing.allocator);
	defer disk.deinit();
	const place = store.Store{ .local = &disk };
	store.removeAll(arena, place, root, 0) catch {};
	try place.makeDir(arena, root);
	defer store.removeAll(arena, place, root, 0) catch {};
	try place.makeDir(arena, try store.join(arena, root, "inner"));
	{
		var out = try place.openWrite(arena, try store.join(arena, root, "a.txt"), 0);
		try out.write("x");
		try out.finish();
	}

	const files = try Manager.init(testing.allocator, null);
	defer files.deinit();
	try files.left.goTo(testing.allocator, root);
	files.left.reload(testing.allocator);

	// A directory first, then the file, and no `..` missing.
	try testing.expectEqual(@as(usize, 3), files.left.entries.len);
	try testing.expectEqualStrings(UP, files.left.entries[0].name);
	try testing.expectEqualStrings("inner", files.left.entries[1].name);
	try testing.expectEqualStrings("a.txt", files.left.entries[2].name);

	files.left.selected = 1;
	try testing.expect(try files.enter());
	try testing.expectEqualStrings(try store.join(arena, root, "inner"), files.left.where());

	// And back out, landing on the directory just left rather than at the top.
	try files.up();
	try testing.expectEqualStrings(root, files.left.where());
	try testing.expectEqualStrings("inner", files.left.current().?.name);

	// A file is not somewhere to go.
	files.left.selected = 2;
	try testing.expect(!try files.enter());

	// What an action applies to: the cursor when nothing is marked, and the
	// marks when there are any.
	{
		const one = try files.left.chosen(arena);
		try testing.expectEqual(@as(usize, 1), one.len);
		try testing.expectEqualStrings("a.txt", one[0].name);
	}
	try files.left.toggleMark(testing.allocator, 1);
	{
		const some = try files.left.chosen(arena);
		try testing.expectEqual(@as(usize, 1), some.len);
		try testing.expectEqualStrings("inner", some[0].name);
	}
	// The way out cannot be marked, whatever is asked.
	try files.left.toggleMark(testing.allocator, 0);
	try testing.expectEqual(@as(usize, 1), files.left.marked.items.len);
}

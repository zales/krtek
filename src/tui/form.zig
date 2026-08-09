//! A small form widget: a list of labelled fields the user walks with the
//! arrows and submits with Ctrl+S. Everything that needs more than one value -
//! editing a row, creating a table, an index, a foreign key, an export - is
//! built out of it, so there is one set of key bindings to learn.

const std = @import("std");
const term = @import("term.zig");

pub const Kind = union(enum) {
	text,
	toggle,
	/// A fixed set of values cycled with the left and right arrows.
	choice: []const []const u8,
	/// Not editable, just a line of text (a hint or a separator).
	label,
};

pub const Field = struct {
	label: []const u8,
	kind: Kind,
	text: std.ArrayListUnmanaged(u8) = .empty,
	on: bool = false,
	pick: usize = 0,
	/// Drawn on the same line as the field before it.
	inline_with_previous: bool = false,
	/// 0 for the fixed part of a form, 1..n for repeatable rows.
	group: usize = 0,
	width: usize = 24,
	/// For a column row: the name this column had before the form opened, so a
	/// rebuild knows where to copy the data from. Empty for a new column.
	original: []const u8 = "",
	/// Drawn as dots. What is typed still goes into `text`; only the screen is
	/// spared.
	masked: bool = false,

	pub fn value(self: Field) []const u8 {
		return switch (self.kind) {
			.choice => |options| options[@min(self.pick, options.len - 1)],
			else => self.text.items,
		};
	}

	pub fn editable(self: Field) bool {
		return switch (self.kind) {
			.label => false,
			else => true,
		};
	}
};

pub const Purpose = enum {
	row,
	create_table,
	alter_table,
	index,
	foreign_key,
	view,
	trigger,
	import_data,
	export_data,
	search_all,
	filter,
	columns,
	open_file,
	schema,
	connection,
	rename_table,
	copy_table,
};

pub const Action = enum { none, submit, cancel, add_row, remove_row };

pub const Form = struct {
	arena: std.heap.ArenaAllocator,
	purpose: Purpose,
	title: []const u8,
	hint: []const u8 = "",
	fields: std.ArrayListUnmanaged(Field) = .empty,
	cursor: usize = 0,
	scroll: usize = 0,
	/// How many fields make up one repeatable row, 0 when the form is fixed.
	row_size: usize = 0,
	/// Context for the submit handler.
	table: []const u8 = "",
	where: ?[]const u8 = null,
	extra: []const u8 = "",

	pub fn init(allocator: std.mem.Allocator, purpose: Purpose, title: []const u8) Form {
		return .{
			.arena = std.heap.ArenaAllocator.init(allocator),
			.purpose = purpose,
			.title = title,
		};
	}

	pub fn deinit(self: *Form) void {
		self.arena.deinit();
	}

	fn gpa(self: *Form) std.mem.Allocator {
		return self.arena.allocator();
	}

	pub fn text(self: *Form, label: []const u8, initial: []const u8, width: usize) !void {
		var entry = Field{ .label = try self.gpa().dupe(u8, label), .kind = .text, .width = width };
		try entry.text.appendSlice(self.gpa(), initial);
		try self.fields.append(self.gpa(), entry);
	}

	/// A text field whose content is drawn as dots.
	pub fn secret(self: *Form, label: []const u8, initial: []const u8, width: usize) !void {
		var entry = Field{ .label = try self.gpa().dupe(u8, label), .kind = .text, .width = width, .masked = true };
		try entry.text.appendSlice(self.gpa(), initial);
		try self.fields.append(self.gpa(), entry);
	}

	pub fn toggle(self: *Form, label: []const u8, on: bool) !void {
		try self.fields.append(self.gpa(), .{ .label = try self.gpa().dupe(u8, label), .kind = .toggle, .on = on });
	}

	pub fn choice(self: *Form, label: []const u8, options: []const []const u8, pick: usize) !void {
		try self.fields.append(self.gpa(), .{
			.label = try self.gpa().dupe(u8, label),
			.kind = .{ .choice = options },
			.pick = pick,
			.width = 8,
		});
	}

	pub fn note(self: *Form, line: []const u8) !void {
		try self.fields.append(self.gpa(), .{ .label = try self.gpa().dupe(u8, line), .kind = .label });
	}

	/// Mark the last added field as continuing the previous line.
	pub fn sameLine(self: *Form) void {
		if (self.fields.items.len > 0) {
			self.fields.items[self.fields.items.len - 1].inline_with_previous = true;
		}
	}

	/// Remember what the last added field was called before editing.
	pub fn wasNamed(self: *Form, original: []const u8) !void {
		if (self.fields.items.len > 0) {
			self.fields.items[self.fields.items.len - 1].original = try self.gpa().dupe(u8, original);
		}
	}

	/// Tag the last added field as belonging to repeatable row `group`.
	pub fn inGroup(self: *Form, group: usize) void {
		if (self.fields.items.len > 0) {
			self.fields.items[self.fields.items.len - 1].group = group;
		}
	}

	pub fn field(self: *Form, index: usize) ?*Field {
		return if (index < self.fields.items.len) &self.fields.items[index] else null;
	}

	pub fn valueOf(self: *Form, index: usize) []const u8 {
		return if (self.field(index)) |f| f.value() else "";
	}

	pub fn isOn(self: *Form, index: usize) bool {
		return if (self.field(index)) |f| f.on else false;
	}

	/// Index of the first field of the row the cursor is in, and its size.
	pub fn currentRow(self: *Form) ?struct { start: usize, group: usize } {
		if (self.row_size == 0) {
			return null;
		}
		const current = self.field(self.cursor) orelse return null;
		if (current.group == 0) {
			return null;
		}
		var start = self.cursor;
		while (start > 0 and self.fields.items[start - 1].group == current.group) {
			start -= 1;
		}
		return .{ .start = start, .group = current.group };
	}

	fn nextEditable(self: *Form, from: usize, delta: i32) usize {
		var at: isize = @intCast(from);
		const count: isize = @intCast(self.fields.items.len);
		while (true) {
			at += delta;
			if (at < 0 or at >= count) {
				return from;
			}
			if (self.fields.items[@intCast(at)].editable()) {
				return @intCast(at);
			}
		}
	}

	/// Typing a value means the cell is no longer NULL, which is what the null
	/// checkbox next to it says.
	fn clearNullBeside(self: *Form, index: usize) void {
		const next = self.field(index + 1) orelse return;
		if (next.kind == .toggle and std.mem.eql(u8, next.label, "null")) {
			next.on = false;
		}
	}

	pub fn handle(self: *Form, key: term.Key) Action {
		switch (key) {
			.escape => return .cancel,
			.ctrl => |code| switch (code) {
				's' => return .submit,
				'c' => return .cancel,
				'n' => return .add_row,
				'k' => return .remove_row,
				'u' => {
					if (self.field(self.cursor)) |f| {
						if (f.kind == .text) {
							f.text.clearRetainingCapacity();
						}
					}
				},
				else => {},
			},
			.up => self.cursor = self.nextEditable(self.cursor, -1),
			.down, .tab => self.cursor = self.nextEditable(self.cursor, 1),
			.enter => self.cursor = self.nextEditable(self.cursor, 1),
			.left, .right => {
				if (self.field(self.cursor)) |f| {
					switch (f.kind) {
						.choice => |options| {
							const delta: usize = if (key == .right) 1 else options.len - 1;
							f.pick = (f.pick + delta) % options.len;
						},
						.toggle => f.on = !f.on,
						else => {},
					}
				}
			},
			.backspace => {
				if (self.field(self.cursor)) |f| {
					if (f.kind == .text and f.text.items.len > 0) {
						var cut = f.text.items.len - 1;
						while (cut > 0 and f.text.items[cut] & 0xc0 == 0x80) {
							cut -= 1;
						}
						f.text.shrinkRetainingCapacity(cut);
					}
				}
			},
			.char => |point| {
				if (self.field(self.cursor)) |f| {
					switch (f.kind) {
						.toggle => if (point == ' ') {
							f.on = !f.on;
						},
						.text => {
							var buf: [4]u8 = undefined;
							const len = std.unicode.utf8Encode(point, &buf) catch return .none;
							f.text.appendSlice(self.gpa(), buf[0..len]) catch {};
							self.clearNullBeside(self.cursor);
						},
						else => {},
					}
				}
			},
			else => {},
		}
		return .none;
	}
};

/// The fallback list, for a form built before a connection exists. Each driver
/// offers its own through `Ddl.types()`.
pub const TYPES = [_][]const u8{ "TEXT", "INTEGER", "REAL", "BLOB", "NUMERIC", "" };
pub const ACTIONS = [_][]const u8{ "NO ACTION", "CASCADE", "SET NULL", "SET DEFAULT", "RESTRICT" };

/// Index of `needle` in `haystack`, 0 when missing.
pub fn indexOf(haystack: []const []const u8, needle: []const u8) usize {
	for (haystack, 0..) |item, i| {
		if (std.ascii.eqlIgnoreCase(item, needle)) {
			return i;
		}
	}
	return 0;
}

//! SQL generation for the schema changes.
//!
//! SQLite can only add, rename and drop a column; anything else - a type, a
//! default, a primary key, a foreign key - means building a new table, copying
//! the rows over and putting the old name back. That is what `rebuild` writes,
//! following the procedure from https://sqlite.org/lang_altertable.html, and it
//! is also how Adminer alters a SQLite table.

const std = @import("std");
const sq = @import("sqlite");

const List = std.ArrayListUnmanaged(u8);

pub const Column = struct {
	name: []const u8,
	type: []const u8 = "",
	notnull: bool = false,
	dflt: ?[]const u8 = null,
	pk: bool = false,
	unique: bool = false,
	/// The column this one is copied from; empty for a new column.
	original: []const u8 = "",
};

pub const ForeignKey = struct {
	column: []const u8,
	target_table: []const u8,
	target_column: []const u8,
	on_update: []const u8 = "NO ACTION",
	on_delete: []const u8 = "NO ACTION",
};

fn name(out: *List, a: std.mem.Allocator, text: []const u8) !void {
	try sq.quoteName(out, a, text);
}

fn literal(out: *List, a: std.mem.Allocator, text: []const u8) !void {
	try sq.quote(out, a, text);
}

/// The body of a CREATE TABLE, from the opening bracket to the closing one.
fn body(out: *List, a: std.mem.Allocator, columns: []const Column, keys: []const ForeignKey) !void {
	var primary: usize = 0;
	for (columns) |column| {
		primary += @intFromBool(column.pk);
	}
	try out.appendSlice(a, " (\n");
	for (columns, 0..) |column, i| {
		if (i != 0) {
			try out.appendSlice(a, ",\n");
		}
		try out.appendSlice(a, "\t");
		try name(out, a, column.name);
		if (column.type.len != 0) {
			try out.append(a, ' ');
			try out.appendSlice(a, column.type);
		}
		// A single INTEGER primary key has to be inline to become the rowid.
		if (column.pk and primary == 1) {
			try out.appendSlice(a, " PRIMARY KEY");
		}
		if (column.notnull) {
			try out.appendSlice(a, " NOT NULL");
		}
		if (column.unique) {
			try out.appendSlice(a, " UNIQUE");
		}
		if (column.dflt) |value| {
			if (value.len != 0) {
				try out.appendSlice(a, " DEFAULT ");
				try out.appendSlice(a, value);
			}
		}
	}
	if (primary > 1) {
		try out.appendSlice(a, ",\n\tPRIMARY KEY (");
		var written: usize = 0;
		for (columns) |column| {
			if (!column.pk) {
				continue;
			}
			if (written != 0) {
				try out.appendSlice(a, ", ");
			}
			try name(out, a, column.name);
			written += 1;
		}
		try out.append(a, ')');
	}
	for (keys) |key| {
		try out.appendSlice(a, ",\n\tFOREIGN KEY (");
		try name(out, a, key.column);
		try out.appendSlice(a, ") REFERENCES ");
		try name(out, a, key.target_table);
		if (key.target_column.len != 0) {
			try out.append(a, '(');
			try name(out, a, key.target_column);
			try out.append(a, ')');
		}
		if (!std.mem.eql(u8, key.on_update, "NO ACTION")) {
			try out.appendSlice(a, " ON UPDATE ");
			try out.appendSlice(a, key.on_update);
		}
		if (!std.mem.eql(u8, key.on_delete, "NO ACTION")) {
			try out.appendSlice(a, " ON DELETE ");
			try out.appendSlice(a, key.on_delete);
		}
	}
	try out.appendSlice(a, "\n)");
}

pub fn createTable(out: *List, a: std.mem.Allocator, table: []const u8, columns: []const Column, keys: []const ForeignKey) !void {
	try out.appendSlice(a, "CREATE TABLE ");
	try name(out, a, table);
	try body(out, a, columns, keys);
	try out.appendSlice(a, ";\n");
}

/// Rewrite `table` with a new column list, keys and possibly a new name. The
/// indexes and triggers go away with the old table, so their definitions are
/// replayed afterwards.
pub fn rebuild(
	out: *List,
	a: std.mem.Allocator,
	table: []const u8,
	new_name: []const u8,
	columns: []const Column,
	keys: []const ForeignKey,
	replay: []const []const u8,
) !void {
	const temporary = "krtek_rebuild";
	try out.appendSlice(a, "PRAGMA foreign_keys = off;\nBEGIN;\n");
	try out.appendSlice(a, "CREATE TABLE ");
	try name(out, a, temporary);
	try body(out, a, columns, keys);
	try out.appendSlice(a, ";\n");

	// Copy the columns that existed before, in the new order.
	var copied: usize = 0;
	for (columns) |column| {
		copied += @intFromBool(column.original.len != 0);
	}
	if (copied != 0) {
		try out.appendSlice(a, "INSERT INTO ");
		try name(out, a, temporary);
		try out.appendSlice(a, " (");
		var written: usize = 0;
		for (columns) |column| {
			if (column.original.len == 0) {
				continue;
			}
			if (written != 0) {
				try out.appendSlice(a, ", ");
			}
			try name(out, a, column.name);
			written += 1;
		}
		try out.appendSlice(a, ")\n  SELECT ");
		written = 0;
		for (columns) |column| {
			if (column.original.len == 0) {
				continue;
			}
			if (written != 0) {
				try out.appendSlice(a, ", ");
			}
			try name(out, a, column.original);
			written += 1;
		}
		try out.appendSlice(a, " FROM ");
		try name(out, a, table);
		try out.appendSlice(a, ";\n");
	}

	try out.appendSlice(a, "DROP TABLE ");
	try name(out, a, table);
	try out.appendSlice(a, ";\nALTER TABLE ");
	try name(out, a, temporary);
	try out.appendSlice(a, " RENAME TO ");
	try name(out, a, if (new_name.len != 0) new_name else table);
	try out.appendSlice(a, ";\n");

	for (replay) |statement| {
		try out.appendSlice(a, statement);
		try out.appendSlice(a, ";\n");
	}
	try out.appendSlice(a, "COMMIT;\nPRAGMA foreign_keys = on;\n");
}

pub fn addColumn(out: *List, a: std.mem.Allocator, table: []const u8, column: Column) !void {
	try out.appendSlice(a, "ALTER TABLE ");
	try name(out, a, table);
	try out.appendSlice(a, " ADD COLUMN ");
	try name(out, a, column.name);
	if (column.type.len != 0) {
		try out.append(a, ' ');
		try out.appendSlice(a, column.type);
	}
	if (column.notnull) {
		try out.appendSlice(a, " NOT NULL");
	}
	if (column.dflt) |value| {
		if (value.len != 0) {
			try out.appendSlice(a, " DEFAULT ");
			try out.appendSlice(a, value);
		}
	}
	try out.appendSlice(a, ";\n");
}

pub fn renameTable(out: *List, a: std.mem.Allocator, table: []const u8, to: []const u8) !void {
	try out.appendSlice(a, "ALTER TABLE ");
	try name(out, a, table);
	try out.appendSlice(a, " RENAME TO ");
	try name(out, a, to);
	try out.appendSlice(a, ";\n");
}

pub fn dropObject(out: *List, a: std.mem.Allocator, kind: []const u8, object: []const u8) !void {
	try out.appendSlice(a, "DROP ");
	try out.appendSlice(a, kind);
	try out.appendSlice(a, " ");
	try name(out, a, object);
	try out.appendSlice(a, ";\n");
}

pub fn truncate(out: *List, a: std.mem.Allocator, table: []const u8) !void {
	try out.appendSlice(a, "DELETE FROM ");
	try name(out, a, table);
	try out.appendSlice(a, ";\n");
}

/// A copy of the table, with or without its rows.
pub fn copyTable(out: *List, a: std.mem.Allocator, table: []const u8, to: []const u8, with_data: bool) !void {
	try out.appendSlice(a, "CREATE TABLE ");
	try name(out, a, to);
	try out.appendSlice(a, " AS SELECT * FROM ");
	try name(out, a, table);
	if (!with_data) {
		try out.appendSlice(a, " WHERE 0");
	}
	try out.appendSlice(a, ";\n");
}

pub fn createIndex(
	out: *List,
	a: std.mem.Allocator,
	index: []const u8,
	table: []const u8,
	columns: []const []const u8,
	unique: bool,
	partial: []const u8,
) !void {
	try out.appendSlice(a, if (unique) "CREATE UNIQUE INDEX " else "CREATE INDEX ");
	try name(out, a, index);
	try out.appendSlice(a, " ON ");
	try name(out, a, table);
	try out.appendSlice(a, " (");
	for (columns, 0..) |column, i| {
		if (i != 0) {
			try out.appendSlice(a, ", ");
		}
		try name(out, a, column);
	}
	try out.append(a, ')');
	if (partial.len != 0) {
		try out.appendSlice(a, " WHERE ");
		try out.appendSlice(a, partial);
	}
	try out.appendSlice(a, ";\n");
}

pub fn createView(out: *List, a: std.mem.Allocator, view: []const u8, select: []const u8) !void {
	try out.appendSlice(a, "CREATE VIEW ");
	try name(out, a, view);
	try out.appendSlice(a, " AS ");
	try out.appendSlice(a, select);
	try out.appendSlice(a, ";\n");
}

/// INSERT with the values already quoted by the caller.
pub fn insertRow(out: *List, a: std.mem.Allocator, table: []const u8, columns: []const []const u8, values: []const []const u8) !void {
	try out.appendSlice(a, "INSERT INTO ");
	try name(out, a, table);
	if (columns.len == 0) {
		try out.appendSlice(a, " DEFAULT VALUES;\n");
		return;
	}
	try out.appendSlice(a, " (");
	for (columns, 0..) |column, i| {
		if (i != 0) {
			try out.appendSlice(a, ", ");
		}
		try name(out, a, column);
	}
	try out.appendSlice(a, ") VALUES (");
	for (values, 0..) |value, i| {
		if (i != 0) {
			try out.appendSlice(a, ", ");
		}
		try out.appendSlice(a, value);
	}
	try out.appendSlice(a, ");\n");
}

test "create table with one integer primary key keeps it inline" {
	const a = std.testing.allocator;
	var out: List = .empty;
	defer out.deinit(a);
	try createTable(&out, a, "t", &.{
		.{ .name = "id", .type = "INTEGER", .pk = true },
		.{ .name = "name", .type = "TEXT", .notnull = true },
		.{ .name = "note", .type = "TEXT", .dflt = "'x'" },
	}, &.{});
	try std.testing.expectEqualStrings(
		"CREATE TABLE \"t\" (\n" ++
			"\t\"id\" INTEGER PRIMARY KEY,\n" ++
			"\t\"name\" TEXT NOT NULL,\n" ++
			"\t\"note\" TEXT DEFAULT 'x'\n" ++
			");\n", out.items);
}

test "two primary key columns become a table constraint" {
	const a = std.testing.allocator;
	var out: List = .empty;
	defer out.deinit(a);
	try createTable(&out, a, "t", &.{
		.{ .name = "a", .pk = true },
		.{ .name = "b", .pk = true },
	}, &.{});
	try std.testing.expect(std.mem.indexOf(u8, out.items, "PRIMARY KEY (\"a\", \"b\")") != null);
	try std.testing.expect(std.mem.indexOf(u8, out.items, "\"a\" PRIMARY KEY") == null);
}

test "foreign keys are emitted with their actions" {
	const a = std.testing.allocator;
	var out: List = .empty;
	defer out.deinit(a);
	try createTable(&out, a, "t", &.{.{ .name = "x" }}, &.{
		.{ .column = "x", .target_table = "other", .target_column = "id", .on_delete = "CASCADE" },
	});
	try std.testing.expect(std.mem.indexOf(u8, out.items, "FOREIGN KEY (\"x\") REFERENCES \"other\"(\"id\") ON DELETE CASCADE") != null);
}

test "rebuild copies only the columns that existed" {
	const a = std.testing.allocator;
	var out: List = .empty;
	defer out.deinit(a);
	try rebuild(&out, a, "t", "", &.{
		.{ .name = "id", .type = "INTEGER", .pk = true, .original = "id" },
		.{ .name = "renamed", .type = "TEXT", .original = "old_name" },
		.{ .name = "fresh", .type = "TEXT" },
	}, &.{}, &.{"CREATE INDEX i ON t (id)"});
	try std.testing.expect(std.mem.indexOf(u8, out.items, "INSERT INTO \"krtek_rebuild\" (\"id\", \"renamed\")") != null);
	try std.testing.expect(std.mem.indexOf(u8, out.items, "SELECT \"id\", \"old_name\" FROM \"t\"") != null);
	try std.testing.expect(std.mem.indexOf(u8, out.items, "\"fresh\"") != null);
	try std.testing.expect(std.mem.indexOf(u8, out.items, "DROP TABLE \"t\"") != null);
	try std.testing.expect(std.mem.indexOf(u8, out.items, "RENAME TO \"t\"") != null);
	try std.testing.expect(std.mem.indexOf(u8, out.items, "CREATE INDEX i ON t (id);") != null);
	try std.testing.expect(std.mem.startsWith(u8, out.items, "PRAGMA foreign_keys = off;"));
}

test "quoting survives a hostile name" {
	const a = std.testing.allocator;
	var out: List = .empty;
	defer out.deinit(a);
	try createTable(&out, a, "we\"ird", &.{.{ .name = "a\"b" }}, &.{});
	try std.testing.expect(std.mem.indexOf(u8, out.items, "\"we\"\"ird\"") != null);
	try std.testing.expect(std.mem.indexOf(u8, out.items, "\"a\"\"b\"") != null);
}

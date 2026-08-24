//! What the interface asks for, as a structure rather than as SQL.
//!
//! The relational drivers used to be asked in SQL because the interface wrote
//! SQL: `SELECT * FROM "books" WHERE … LIMIT 50 OFFSET 100`. Redis then had to
//! *recognise* those strings and turn them back into `SCAN`, which worked and was
//! plainly the wrong way round - the interface knows perfectly well what it wants
//! and had thrown that knowledge away by printing it.
//!
//! So it asks with `Select` and `Change` instead. The three SQL engines share one
//! renderer, below, which puts the SQL back together; Redis and Kafka read the
//! structure directly and no longer guess. A driver still gets raw SQL when the
//! user types it into the editor - that is a different path, and for Redis and
//! Kafka it is a console.
//!
//! `Select.where_text` is the exception the shape cannot avoid: the filter row
//! takes whatever the user types, which on a SQL engine may be any expression.
//! It is passed through to SQL untouched, and a driver that does not speak SQL
//! reports that it cannot honour it rather than pretending.

const std = @import("std");
const db = @import("db.zig");

const List = db.List;

pub const Op = enum {
	eq,
	ne,
	lt,
	le,
	gt,
	ge,
	like,
	is_null,
	not_null,

	pub fn sql(self: Op) []const u8 {
		return switch (self) {
			.eq => " = ",
			.ne => " <> ",
			.lt => " < ",
			.le => " <= ",
			.gt => " > ",
			.ge => " >= ",
			.like => " LIKE ",
			.is_null => " IS NULL",
			.not_null => " IS NOT NULL",
		};
	}

	pub fn takesValue(self: Op) bool {
		return self != .is_null and self != .not_null;
	}
};

/// One condition. `value` is the value itself, never quoted or escaped: what
/// that takes is the renderer's business, or the driver's.
pub const Filter = struct {
	column: []const u8,
	op: Op = .eq,
	value: []const u8 = "",
	/// Compare as text, for the search that looks in every column whatever its
	/// type. The renderer casts; a driver where everything is text ignores it.
	as_text: bool = false,
};

pub const Select = struct {
	table: db.Table,
	/// Columns to fetch, or empty for all of them.
	columns: []const []const u8 = &.{},
	/// An expression to fetch beside them under the name `as`, which is how a
	/// hidden row id - SQLite's `rowid` - is brought back into the grid.
	extra: []const u8 = "",
	extra_as: []const u8 = "",
	where: []const Filter = &.{},
	/// What the user typed into the filter row, when it is not a `Filter`.
	where_text: []const u8 = "",
	/// Conditions joined with OR rather than AND, which is what the search across
	/// every column of a table needs.
	any: bool = false,
	order: []const u8 = "",
	descending: bool = false,
	/// 0 means no limit.
	limit: usize = 0,
	offset: usize = 0,
	/// Count the rows that match instead of fetching them.
	count: bool = false,
};

pub const Kind = enum { insert, update, delete };

pub const Change = struct {
	kind: Kind,
	table: db.Table,
	/// For insert and update. A null value is NULL; a value that is `raw` is
	/// written into the statement as it stands, which is how a function call or a
	/// DEFAULT reaches the engine.
	cells: []const Cell = &.{},
	/// Which row: the identity the grid holds for it.
	where: []const Filter = &.{},
};

pub const Cell = struct {
	column: []const u8,
	value: ?[]const u8 = null,
	/// The value is an expression, not a literal - it is not quoted.
	raw: bool = false,
};

// ------------------------------------------------------------------ to SQL
//
// One implementation for the three engines that speak SQL. It writes what the
// interface used to write by hand, which is why the statement the report shows
// still looks like something a person would type.

pub fn renderSelect(out: *List, a: std.mem.Allocator, select: Select, caps: db.Caps) !void {
	try out.appendSlice(a, "SELECT ");
	if (select.count) {
		try out.appendSlice(a, "count(*)");
	} else {
		if (select.extra.len != 0) {
			try out.appendSlice(a, select.extra);
			try out.appendSlice(a, " AS ");
			try db.quoteName(out, a, select.extra_as);
			try out.appendSlice(a, ", ");
		}
		if (select.columns.len == 0) {
			try out.append(a, '*');
		} else {
			for (select.columns, 0..) |column, i| {
				if (i != 0) {
					try out.appendSlice(a, ", ");
				}
				try db.quoteName(out, a, column);
			}
		}
	}
	try out.appendSlice(a, " FROM ");
	try db.quoteTable(out, a, select.table);
	try renderWhere(out, a, select.where, select.where_text, select.any, caps);
	if (!select.count) {
		if (select.order.len != 0) {
			try out.appendSlice(a, " ORDER BY ");
			try db.quoteName(out, a, select.order);
			if (select.descending) {
				try out.appendSlice(a, " DESC");
			}
		}
		if (select.limit != 0) {
			switch (caps.paging) {
				.limit_offset => try out.print(a, " LIMIT {d} OFFSET {d}", .{ select.limit, select.offset }),
				.offset_fetch => {
					// A page is defined as the rows after the first n *in order*,
					// and without an order the engine refuses to guess. Where the
					// grid has nothing to sort by, an order that sorts by nothing
					// is what says so.
					if (select.order.len == 0) {
						try out.appendSlice(a, " ORDER BY (SELECT NULL)");
					}
					try out.print(a, " OFFSET {d} ROWS FETCH NEXT {d} ROWS ONLY", .{ select.offset, select.limit });
				},
			}
		}
	}
}

pub fn renderChange(out: *List, a: std.mem.Allocator, change: Change, caps: db.Caps) !void {
	switch (change.kind) {
		.insert => {
			try out.appendSlice(a, "INSERT INTO ");
			try db.quoteTable(out, a, change.table);
			if (change.cells.len == 0) {
				try out.appendSlice(a, " DEFAULT VALUES");
				return;
			}
			try out.appendSlice(a, " (");
			for (change.cells, 0..) |cell, i| {
				if (i != 0) {
					try out.appendSlice(a, ", ");
				}
				try db.quoteName(out, a, cell.column);
			}
			try out.appendSlice(a, ") VALUES (");
			for (change.cells, 0..) |cell, i| {
				if (i != 0) {
					try out.appendSlice(a, ", ");
				}
				try renderValue(out, a, cell, caps);
			}
			try out.append(a, ')');
		},
		.update => {
			try out.appendSlice(a, "UPDATE ");
			try db.quoteTable(out, a, change.table);
			try out.appendSlice(a, " SET ");
			for (change.cells, 0..) |cell, i| {
				if (i != 0) {
					try out.appendSlice(a, ", ");
				}
				try db.quoteName(out, a, cell.column);
				try out.appendSlice(a, " = ");
				try renderValue(out, a, cell, caps);
			}
			try renderWhere(out, a, change.where, "", false, caps);
		},
		.delete => {
			try out.appendSlice(a, "DELETE FROM ");
			try db.quoteTable(out, a, change.table);
			try renderWhere(out, a, change.where, "", false, caps);
		},
	}
}

fn renderValue(out: *List, a: std.mem.Allocator, item: Cell, caps: db.Caps) !void {
	const value = item.value orelse {
		try out.appendSlice(a, "NULL");
		return;
	};
	if (item.raw) {
		try out.appendSlice(a, value);
	} else {
		try out.appendSlice(a, caps.text_prefix);
		try db.quote(out, a, value);
	}
}

fn renderWhere(out: *List, a: std.mem.Allocator, where: []const Filter, text: []const u8, any: bool, caps: db.Caps) !void {
	if (where.len == 0 and text.len == 0) {
		return;
	}
	try out.appendSlice(a, " WHERE ");
	const joiner = if (any) " OR " else " AND ";
	for (where, 0..) |filter, i| {
		if (i != 0) {
			try out.appendSlice(a, joiner);
		}
		if (filter.as_text) {
			try out.appendSlice(a, "CAST(");
			try db.quoteName(out, a, filter.column);
			try out.appendSlice(a, " AS ");
			try out.appendSlice(a, caps.text_cast);
			try out.append(a, ')');
		} else {
			try db.quoteName(out, a, filter.column);
		}
		try out.appendSlice(a, filter.op.sql());
		if (filter.op.takesValue()) {
			try out.appendSlice(a, caps.text_prefix);
			try db.quote(out, a, filter.value);
		}
	}
	if (text.len != 0) {
		if (where.len != 0) {
			try out.appendSlice(a, joiner);
		}
		try out.append(a, '(');
		try out.appendSlice(a, text);
		try out.append(a, ')');
	}
}

/// The one value a `Filter` names, for a driver that wants to answer a request
/// about a single row without looking at operators it does not have.
pub fn only(where: []const Filter, column: []const u8) ?[]const u8 {
	for (where) |filter| {
		if (filter.op == .eq and std.mem.eql(u8, filter.column, column)) {
			return filter.value;
		}
	}
	return null;
}

/// The value a change sets for one column: null when the column is not in the
/// change at all, and a null inside it when the value itself is NULL.
pub fn valueOf(cells: []const Cell, column: []const u8) ??[]const u8 {
	for (cells) |item| {
		if (std.mem.eql(u8, item.column, column)) {
			return item.value;
		}
	}
	return null;
}

// -------------------------------------------------------------------- tests

const testing = std.testing;

fn rendered(select: Select) ![]u8 {
	var out: List = .empty;
	try renderSelect(&out, testing.allocator, select, .{});
	return out.toOwnedSlice(testing.allocator);
}

fn renderedAs(select: Select, caps: db.Caps) ![]u8 {
	var out: List = .empty;
	try renderSelect(&out, testing.allocator, select, caps);
	return out.toOwnedSlice(testing.allocator);
}

test "a page of a table" {
	const sql = try rendered(.{ .table = .{ .name = "books" }, .limit = 50, .offset = 100 });
	defer testing.allocator.free(sql);
	try testing.expectEqualStrings("SELECT * FROM \"books\" LIMIT 50 OFFSET 100", sql);
}

test "the hidden key comes back as a column of its own" {
	const sql = try rendered(.{
		.table = .{ .name = "notes" },
		.extra = "rowid",
		.extra_as = "__key",
	});
	defer testing.allocator.free(sql);
	try testing.expectEqualStrings("SELECT rowid AS \"__key\", * FROM \"notes\"", sql);
}

test "filters, sorting and a schema" {
	const sql = try rendered(.{
		.table = .{ .schema = "public", .name = "books" },
		.where = &.{
			.{ .column = "year", .op = .ge, .value = "1950" },
			.{ .column = "title", .op = .like, .value = "%mlok%" },
		},
		.order = "year",
		.descending = true,
	});
	defer testing.allocator.free(sql);
	try testing.expectEqualStrings(
		"SELECT * FROM \"public\".\"books\" WHERE \"year\" >= '1950' AND \"title\" LIKE '%mlok%' ORDER BY \"year\" DESC",
		sql,
	);
}

test "what the user typed is joined to the filters, in brackets of its own" {
	const sql = try rendered(.{
		.table = .{ .name = "books" },
		.where = &.{.{ .column = "id", .value = "7" }},
		.where_text = "price > 100 OR price IS NULL",
	});
	defer testing.allocator.free(sql);
	try testing.expectEqualStrings(
		"SELECT * FROM \"books\" WHERE \"id\" = '7' AND (price > 100 OR price IS NULL)",
		sql,
	);
}

test "a search across columns is one OR, cast to text the way the engine spells it" {
	var out: List = .empty;
	defer out.deinit(testing.allocator);
	try renderSelect(&out, testing.allocator, .{
		.table = .{ .name = "books" },
		.where = &.{
			.{ .column = "title", .op = .like, .value = "%a%", .as_text = true },
			.{ .column = "year", .op = .like, .value = "%a%", .as_text = true },
		},
		.any = true,
		.limit = 1,
	}, .{ .text_cast = "CHAR" });
	try testing.expectEqualStrings(
		"SELECT * FROM \"books\" WHERE CAST(\"title\" AS CHAR) LIKE '%a%' OR CAST(\"year\" AS CHAR) LIKE '%a%' LIMIT 1 OFFSET 0",
		out.items,
	);
}

test "counting ignores the order and the page" {
	const sql = try rendered(.{
		.table = .{ .name = "books" },
		.count = true,
		.order = "year",
		.limit = 50,
		.where = &.{.{ .column = "year", .value = "1936" }},
	});
	defer testing.allocator.free(sql);
	try testing.expectEqualStrings("SELECT count(*) FROM \"books\" WHERE \"year\" = '1936'", sql);
}

test "quotes inside a name and inside a value" {
	const sql = try rendered(.{
		.table = .{ .name = "wei\"rd" },
		.where = &.{.{ .column = "it's", .value = "o'clock" }},
	});
	defer testing.allocator.free(sql);
	try testing.expectEqualStrings("SELECT * FROM \"wei\"\"rd\" WHERE \"it's\" = 'o''clock'", sql);
}

fn changed(change: Change) ![]u8 {
	var out: List = .empty;
	try renderChange(&out, testing.allocator, change, .{});
	return out.toOwnedSlice(testing.allocator);
}

test "insert, with a NULL and an expression" {
	const sql = try changed(.{
		.kind = .insert,
		.table = .{ .name = "books" },
		.cells = &.{
			.{ .column = "title", .value = "RUR" },
			.{ .column = "note", .value = null },
			.{ .column = "added", .value = "now()", .raw = true },
		},
	});
	defer testing.allocator.free(sql);
	try testing.expectEqualStrings(
		"INSERT INTO \"books\" (\"title\", \"note\", \"added\") VALUES ('RUR', NULL, now())",
		sql,
	);
}

test "insert with nothing to say" {
	const sql = try changed(.{ .kind = .insert, .table = .{ .name = "books" } });
	defer testing.allocator.free(sql);
	try testing.expectEqualStrings("INSERT INTO \"books\" DEFAULT VALUES", sql);
}

test "update and delete address the row by its identity" {
	const update = try changed(.{
		.kind = .update,
		.table = .{ .name = "books" },
		.cells = &.{.{ .column = "year", .value = "1936" }},
		.where = &.{.{ .column = "id", .value = "1" }},
	});
	defer testing.allocator.free(update);
	try testing.expectEqualStrings("UPDATE \"books\" SET \"year\" = '1936' WHERE \"id\" = '1'", update);

	const delete = try changed(.{
		.kind = .delete,
		.table = .{ .name = "books" },
		.where = &.{ .{ .column = "id", .value = "1" }, .{ .column = "part", .op = .is_null } },
	});
	defer testing.allocator.free(delete);
	try testing.expectEqualStrings("DELETE FROM \"books\" WHERE \"id\" = '1' AND \"part\" IS NULL", delete);
}

test "picking one value out of an identity" {
	const where = [_]Filter{
		.{ .column = "partition", .value = "2" },
		.{ .column = "offset", .op = .ge, .value = "100" },
	};
	try testing.expectEqualStrings("2", only(&where, "partition").?);
	try testing.expect(only(&where, "offset") == null); // not an equality
	try testing.expect(only(&where, "nothing") == null);
}

test "a page is asked for the way the engine spells it" {
	const select = Select{ .table = .{ .name = "books" }, .order = "year", .limit = 50, .offset = 100 };
	const standard = try renderedAs(select, .{ .paging = .offset_fetch });
	defer testing.allocator.free(standard);
	try testing.expectEqualStrings(
		"SELECT * FROM \"books\" ORDER BY \"year\" OFFSET 100 ROWS FETCH NEXT 50 ROWS ONLY",
		standard,
	);
	// Nothing to sort by, and the standard spelling will not have that - so an
	// order that sorts by nothing is written in.
	const unordered = try renderedAs(.{ .table = .{ .name = "books" }, .limit = 10 }, .{ .paging = .offset_fetch });
	defer testing.allocator.free(unordered);
	try testing.expectEqualStrings(
		"SELECT * FROM \"books\" ORDER BY (SELECT NULL) OFFSET 0 ROWS FETCH NEXT 10 ROWS ONLY",
		unordered,
	);
}

test "text carries the prefix that says which encoding it is in" {
	// Without the N a value written into an nvarchar column goes through the
	// database's single-byte codepage on the way, and `ř` does not survive it.
	const sql = try renderedAs(.{
		.table = .{ .name = "zbozi" },
		.where = &.{.{ .column = "nazev", .op = .like, .value = "%vrtačka%" }},
	}, .{ .text_prefix = "N" });
	defer testing.allocator.free(sql);
	try testing.expectEqualStrings(
		"SELECT * FROM \"zbozi\" WHERE \"nazev\" LIKE N'%vrtačka%'",
		sql,
	);

	var out: List = .empty;
	defer out.deinit(testing.allocator);
	try renderChange(&out, testing.allocator, .{
		.kind = .update,
		.table = .{ .name = "zbozi" },
		.cells = &.{
			.{ .column = "nazev", .value = "příklep" },
			.{ .column = "zalozeno", .value = "SYSUTCDATETIME()", .raw = true },
		},
		.where = &.{.{ .column = "id", .value = "2" }},
	}, .{ .text_prefix = "N" });
	// The written-out expression is not a string and does not take the prefix.
	try testing.expectEqualStrings(
		"UPDATE \"zbozi\" SET \"nazev\" = N'příklep', \"zalozeno\" = SYSUTCDATETIME() WHERE \"id\" = N'2'",
		out.items,
	);
}

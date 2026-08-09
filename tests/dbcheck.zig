//! Talk to a real server through the driver interface, without the interface on
//! top: connect, list the objects, and describe one table. The quickest way to
//! see whether a driver works at all, and the only test that needs a server.
//!
//!     zig build dbcheck -- mysql://root:secret@127.0.0.1:3306/demo
//!     zig build dbcheck -- postgres://postgres@127.0.0.1:5432/demo
const std = @import("std");
const db = @import("db");

pub fn main(init: std.process.Init) !void {
	const a = std.heap.c_allocator;
	const args = try init.minimal.args.toSlice(init.arena.allocator());
	const target = if (args.len > 1) args[1] else {
		std.debug.print("usage: zig build dbcheck -- <target>\n", .{});
		return;
	};

	var report: std.ArrayListUnmanaged(u8) = .empty;
	const conn = db.Db.open(a, target, &report) catch {
		std.debug.print("open failed: {s}\n", .{report.items});
		return;
	};
	defer conn.close();
	std.debug.print("connected: {s} / {s}\n", .{ conn.describe(), conn.version() });

	var arena = std.heap.ArenaAllocator.init(a);
	defer arena.deinit();

	// Whatever this engine calls the current namespace, if it has one at all.
	var schema: []const u8 = "";
	if (conn.caps().schemas) {
		const list = try conn.schemas(arena.allocator());
		if (list.len != 0) {
			schema = list[0];
		}
	}
	for (try conn.schemas(arena.allocator())) |name| {
		std.debug.print("schema {s}\n", .{name});
	}
	// The first table this server has, so the tool works on any database rather
	// than only on the demo one.
	var first: ?db.Table = null;
	for (try conn.objects(arena.allocator(), schema)) |object| {
		std.debug.print("  {s} {s}.{s} rows~{?d} exact={?d}\n", .{
			@tagName(object.kind), object.schema, object.name, object.rows,
			conn.rowCount(.{ .schema = object.schema, .name = object.name }),
		});
		if (first == null and object.kind == .table) {
			first = .{ .schema = object.schema, .name = object.name };
		}
	}
	const books = first orelse {
		std.debug.print("no table to describe\n", .{});
		return;
	};
	std.debug.print("describing {s}\n", .{books.name});
	for (try conn.columns(arena.allocator(), books)) |column| {
		std.debug.print("  column {s} {s}{s}{s} default={?s}\n", .{
			column.name, column.type,
			if (column.notnull) " NOT NULL" else "",
			if (column.pk) " PK" else "", column.dflt,
		});
	}
	for (try conn.indexes(arena.allocator(), books)) |index| {
		std.debug.print("  index {s} {s} ({s})\n", .{ index.name, index.kind, index.columns });
	}
	for (try conn.foreignKeys(arena.allocator(), books)) |key| {
		std.debug.print("  fk {s} -> {s}.{s} on delete {s}\n", .{ key.column, key.target_table, key.target_column, key.on_delete });
	}
	const key = try conn.rowKey(arena.allocator(), books);
	std.debug.print("  row key: {s} (usable={})\n", .{ if (key.columns.len > 0) key.columns[0] else "-", key.usable() });


	// stream a few rows, whatever columns this server's `books` happens to have
	var select: std.ArrayListUnmanaged(u8) = .empty;
	try select.appendSlice(arena.allocator(), "SELECT * FROM ");
	try db.quoteTable(&select, arena.allocator(), books);
	try select.appendSlice(arena.allocator(), " LIMIT 3");
	var rows = (try conn.query(select.items, null)).?;
	defer rows.close();
	var seen: usize = 0;
	while (try rows.next()) : (seen += 1) {
		var line: std.ArrayListUnmanaged(u8) = .empty;
		for (0..rows.columnCount()) |i| {
			try line.print(arena.allocator(), "{s}=", .{rows.name(i)});
			switch (rows.value(i)) {
				.null => try line.appendSlice(arena.allocator(), "NULL"),
				.int => |v| try line.print(arena.allocator(), "{d}", .{v}),
				.float => |v| try line.print(arena.allocator(), "{d}", .{v}),
				.text => |t| try line.print(arena.allocator(), "{s}", .{t}),
				.blob => |bytes| try line.print(arena.allocator(), "<{d} B>", .{bytes.len / 2}),
			}
			try line.appendSlice(arena.allocator(), "  ");
		}
		std.debug.print("  row {s}\n", .{line.items});
	}
	std.debug.print("  streamed {d} rows, source of column 0 = {s}\n", .{ seen, rows.sourceTable(0) });

	// a batch is split and each statement reported on its own
	const batch = "SELECT 1; SELECT 'a;b' AS text; NOTASTATEMENT; SELECT 2";
	for (try conn.split(arena.allocator(), batch), 0..) |statement, i| {
		std.debug.print("  statement {d}: {s}\n", .{ i + 1, statement.sql });
	}
	std.debug.print("settings:\n", .{});
	for (try conn.settings(arena.allocator())) |setting| {
		std.debug.print("  {s} = {s}\n", .{ setting.label, setting.value });
	}
	const definition = try conn.definition(arena.allocator(), books);
	std.debug.print("definition:\n{s}\n", .{definition orelse "(none)"});
}

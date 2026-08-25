//! Talk to a real server through the driver interface, without the interface on
//! top: connect, list the objects, and describe one table. The quickest way to
//! see whether a driver works at all, and the only test that needs a server.
//!
//!     zig build dbcheck -- mysql://root:secret@127.0.0.1:3306/demo
//!     zig build dbcheck -- postgres://postgres@127.0.0.1:5432/demo
//!     zig build dbcheck -- kafka://127.0.0.1:9093 pages   # a table of its own
const std = @import("std");
const db = @import("db");

pub fn main(init: std.process.Init) !void {
    const a = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const target = if (args.len > 1) args[1] else {
        std.debug.print("usage: zig build dbcheck -- <target> [table]\n", .{});
        return;
    };
    // Which table to describe, for a server where the first one is not the
    // interesting one.
    const wanted_table: ?[]const u8 = if (args.len > 2) args[2] else null;

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
            @tagName(object.kind),                                            object.schema, object.name, object.rows,
            conn.rowCount(.{ .schema = object.schema, .name = object.name }),
        });
        const chosen = if (wanted_table) |name|
            std.mem.eql(u8, name, object.name)
        else
            first == null and object.kind == .table;
        if (chosen) {
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
            column.name,                             column.type,
            if (column.notnull) " NOT NULL" else "", if (column.pk) " PK" else "",
            column.dflt,
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

    // A few rows, asked for the way the interface asks: through the structure, so
    // this works on an engine that has no SQL at all. It used to write a SELECT,
    // which on Redis and Kafka went to their console and failed.
    // In a block of its own, so the cursor is closed before anything else is asked:
    // PostgreSQL streams a result and refuses another query while one is open, and
    // this used to hold it open for the rest of the program.
    {
        var rows = (try conn.select(.{ .table = books, .limit = 3 })).?;
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
    }

    // a batch is split and each statement reported on its own
    const batch = "SELECT 1; SELECT 'a;b' AS text; NOTASTATEMENT; SELECT 2";
    for (try conn.split(arena.allocator(), batch), 0..) |statement, i| {
        std.debug.print("  statement {d}: {s}\n", .{ i + 1, statement.sql });
    }
    // What everything above took: the objects, the columns, the indexes, the keys,
    // the definition and a few rows - which is what drawing one screen asks for. The
    // walk below is not part of that, because its cost is the number of pages and
    // that grows with the data.
    std.debug.print("one screen took {?d} requests\n", .{conn.requests()});

    // Page by page to the end, collecting what addresses each row: a page must
    // begin where the last one stopped, so every record has to appear exactly once.
    // On Kafka this is arithmetic across partitions and it was wrong twice, which is
    // why it is checked here rather than by eye.
    {
        const limit: usize = 4;
        const key_columns = key.columns;
        var seen_keys: std.ArrayListUnmanaged([]const u8) = .empty;
        var page: usize = 0;
        while (page < 50) : (page += 1) {
            var cursor = (try conn.select(.{
                .table = books,
                .limit = limit,
                .offset = page * limit,
            })) orelse break;
            defer cursor.close();
            var on_page: usize = 0;
            while (try cursor.next()) {
                on_page += 1;
                var identity: std.ArrayListUnmanaged(u8) = .empty;
                for (0..cursor.columnCount()) |i| {
                    // A hidden key - SQLite's rowid - is not among the columns, so the
                    // whole row stands in for it.
                    var wanted_column = key_columns.len == 0 or key.hidden;
                    for (key_columns) |column| {
                        wanted_column = wanted_column or std.mem.eql(u8, column, cursor.name(i));
                    }
                    if (!wanted_column) {
                        continue;
                    }
                    switch (cursor.value(i)) {
                        .int => |v| try identity.print(arena.allocator(), "{d}/", .{v}),
                        .text => |t| try identity.print(arena.allocator(), "{s}/", .{t}),
                        else => try identity.appendSlice(arena.allocator(), "-/"),
                    }
                }
                try seen_keys.append(arena.allocator(), identity.items);
            }
            if (on_page < limit) {
                break;
            }
        }
        var distinct: usize = 0;
        for (seen_keys.items, 0..) |one, i| {
            var earlier = false;
            for (seen_keys.items[0..i]) |before| {
                earlier = earlier or std.mem.eql(u8, before, one);
            }
            if (!earlier) {
                distinct += 1;
            }
        }
        std.debug.print("paged: {d} records, {d} distinct\n", .{ seen_keys.items.len, distinct });
    }

    // How much talking all of the above took, where the driver counts it.
    std.debug.print("settings:\n", .{});
    for (try conn.settings(arena.allocator())) |setting| {
        std.debug.print("  {s} = {s}\n", .{ setting.label, setting.value });
    }
    const definition = try conn.definition(arena.allocator(), books);
    std.debug.print("definition:\n{s}\n", .{definition orelse "(none)"});
}

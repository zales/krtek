//! Getting rows out of `krtek` and back into it: a dump, a CSV, the clipboard.
//!
//! Lifted out of `app.zig`, which had grown to four and a half thousand lines
//! with this as one of the few parts of it that has nothing to do with the rest
//! - it does not draw, does not read keys and does not hold state. Free
//! functions taking the app rather than methods on it, because Zig has no way to
//! write half a struct in another file and a forwarding method per function
//! would be a layer that exists only to be passed through.

const std = @import("std");
const database = @import("db");
const csv = @import("csv.zig");
const Form = @import("form.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const formatCell = app_mod.formatCell;

pub fn dump(app: *App, path: []const u8) !void {
    try dumpTo(app, path, null, true, true);
}

/// Write an SQL dump: the whole database or one table, structure and/or data.
/// Built from the interface, so it comes out for either engine.
pub fn dumpTo(app: *App, path: []const u8, only: ?[]const u8, structure: bool, data: bool) !void {
    if (path.len == 0) {
        app.complain("usage: :dump <file>", .{});
        return;
    }
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(app.allocator);
    try out.print(app.allocator, "-- krtek dump of {s}, {s}\n", .{ app.conn.describe(), app.conn.version() });
    try app.conn.ddl().prologue(&out, app.allocator);

    var written: usize = 0;
    for (try app.conn.objects(scratch, app.grid.schema.items)) |object| {
        if (only) |wanted| {
            if (!std.mem.eql(u8, object.name, wanted)) {
                continue;
            }
        }
        // An engine's own housekeeping is not the user's data, and dumping it
        // writes thousands of lines nobody asked for - Kafka's
        // __consumer_offsets among them.
        if (object.internal) {
            continue;
        }
        const table = database.Table{ .schema = object.schema, .name = object.name };
        written += 1;
        if (structure) {
            if (try app.conn.definition(scratch, table)) |text| {
                // The semicolon is SQL's; an engine whose statements are lines does
                // not want one, and its splitter would hand it to the engine.
                const body = std.mem.trimEnd(u8, text, ";\n");
                if (body.len != 0) {
                    if (app.caps().speaks_sql) {
                        try out.print(app.allocator, "\n{s};\n", .{body});
                    } else {
                        try out.print(app.allocator, "\n{s}\n", .{body});
                    }
                }
            }
            // The indexes are written from their metadata, so the dump does
            // not depend on the engine keeping DDL text around.
            for (try app.conn.indexes(scratch, table)) |index| {
                if (std.mem.eql(u8, index.kind, "PRIMARY") or index.partial) {
                    continue; // part of the table, or not reconstructable
                }
                var members: std.ArrayListUnmanaged([]const u8) = .empty;
                var parts = std.mem.tokenizeSequence(u8, index.columns, ", ");
                while (parts.next()) |part| {
                    try members.append(scratch, part);
                }
                if (members.items.len == 0) {
                    continue;
                }
                try app.conn.ddl().createIndex(&out, app.allocator, table, index.name, members.items, std.mem.eql(u8, index.kind, "UNIQUE"), "");
            }
        }
        if (data and object.kind == .table) {
            try dumpRows(app, &out, table);
        }
    }
    app_mod.writeFile(path, out.items) catch |err| {
        app.complain("cannot write {s}: {s}", .{ path, @errorName(err) });
        return;
    };
    app.say("{d} object(s), {d} bytes written to {s}", .{ written, out.items.len, path });
}

pub fn dumpRows(app: *App, out: *std.ArrayListUnmanaged(u8), table: database.Table) !void {
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const names = try app.columnsOf(arena.allocator(), table.name);
    if (names.len == 0) {
        return;
    }
    // Where a row only names bytes kept elsewhere, a file of commands that put
    // the names back would put empty things where the data was.
    if (!app.caps().dumps_rows) {
        try out.print(app.allocator, "-- {s} keeps the bytes, not this file: {s} was listed, not dumped\n", .{
            app.caps().label,
            table.name,
        });
        return;
    }
    if (!app.caps().speaks_sql) {
        return dumpCommands(app, out, table, names);
    }
    const allowed = app.caps();
    // What this table needs said before its rows, and afterwards. Asked for
    // with the columns in hand, because whether anything is needed depends on
    // them - a column that numbers itself is the case.
    const defs = app.columnDefs(arena.allocator(), table.name) catch &[_]database.Column{};

    var rows = (try app.conn.select(.{ .table = table })) orelse return;
    defer rows.close();

    var first = true;
    var values: std.ArrayListUnmanaged([]const u8) = .empty;
    while (try rows.next()) {
        if (first) {
            first = false;
        } else {
            try out.appendSlice(app.allocator, ",\n");
        }
        values.clearRetainingCapacity();
        var line: std.ArrayListUnmanaged(u8) = .empty;
        for (0..rows.columnCount()) |i| {
            if (i != 0) {
                try line.appendSlice(app.allocator, ", ");
            }
            switch (rows.value(i)) {
                .null => try line.appendSlice(app.allocator, "NULL"),
                .int => |v| try line.print(app.allocator, "{d}", .{v}),
                .float => |v| try line.print(app.allocator, "{d}", .{v}),
                // Written the way this engine reads it back: without the
                // prefix, a dump replayed into SQL Server loses every character
                // its codepage does not have.
                .text => |t| try allowed.literal.writeText(&line, app.allocator, t),
                .blob => |b| try allowed.literal.writeBlob(&line, app.allocator, b),
            }
        }
        if (out.items.len == 0 or std.mem.endsWith(u8, out.items, ";\n") or std.mem.endsWith(u8, out.items, "\n\n")) {}
        if (first == false and std.mem.endsWith(u8, out.items, "\n") and !std.mem.endsWith(u8, out.items, ",\n")) {
            try out.append(app.allocator, '\n');
            try app.conn.ddl().beforeRows(out, app.allocator, table, defs);
            try out.appendSlice(app.allocator, "INSERT INTO ");
            try database.quoteTable(out, app.allocator, table);
            try out.appendSlice(app.allocator, " (");
            for (names, 0..) |name, i| {
                if (i != 0) {
                    try out.appendSlice(app.allocator, ", ");
                }
                try database.quoteName(out, app.allocator, name);
            }
            try out.appendSlice(app.allocator, ") VALUES\n");
        }
        try out.append(app.allocator, '(');
        try out.appendSlice(app.allocator, line.items);
        try out.append(app.allocator, ')');
        line.deinit(app.allocator);
    }
    if (!first) {
        try out.appendSlice(app.allocator, ";\n");
        try app.conn.ddl().afterRows(out, app.allocator, table, defs);
    }
}

/// A dump for an engine that has no SQL: every row as the command that would put
/// it back, in the engine's own language and asked of the engine itapp. A file of
/// INSERT statements - which is what this wrote for every engine before - is not
/// something Redis or Kafka can read, so the dump was unusable exactly where it
/// was most needed.
///
/// What comes out goes back in: the lines are what the editor takes, so importing
/// the file as a script replays them.
pub fn dumpCommands(
    app: *App,
    out: *std.ArrayListUnmanaged(u8),
    table: database.Table,
    names: []const []const u8,
) !void {
    var rows = (try app.conn.select(.{ .table = table })) orelse return;
    defer rows.close();
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    var written: usize = 0;
    while (try rows.next()) {
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        var cells: std.ArrayListUnmanaged(database.ask.Cell) = .empty;
        for (0..rows.columnCount()) |i| {
            const name = if (i < names.len) names[i] else rows.name(i);
            const value: ?[]const u8 = switch (rows.value(i)) {
                .null => null,
                .int => |number| try std.fmt.allocPrint(a, "{d}", .{number}),
                .float => |number| try std.fmt.allocPrint(a, "{d}", .{number}),
                .text, .blob => |bytes| try a.dupe(u8, bytes),
            };
            try cells.append(a, .{ .column = try a.dupe(u8, name), .value = value });
        }
        const line = app.conn.wording(a, .{ .change = .{
            .kind = .insert,
            .table = table,
            .cells = cells.items,
        } }) catch continue;
        try out.appendSlice(app.allocator, line);
        try out.append(app.allocator, '\n');
        written += 1;
    }
    if (written == 0) {
        try out.appendSlice(app.allocator, "-- nothing in it\n");
    }
}

/// What the copy keys put in the clipboard. The value under the cursor is
/// fetched whole, the way the detail view does it, so a copied BLOB or a long
/// text is not the flattened one line from the grid.
pub fn copyCell(app: *App) !void {
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const text = (try app.cellDetail(arena.allocator())) orelse {
        app.complain("there is no value under the cursor", .{});
        return;
    };
    try app.screen.copy(text);
    app.say("{d} byte(s) copied", .{text.len});
}

/// The row under the cursor, as tab separated text, which is what a
/// spreadsheet and every editor understand.
pub fn copyRow(app: *App) !void {
    if (app.cursor.row >= app.grid.rows.items.len) {
        app.complain("there is no row under the cursor", .{});
        return;
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(app.allocator);
    for (app.grid.rows.items[app.cursor.row].cells, 0..) |cell, i| {
        if (app.isHidden(i)) {
            continue;
        }
        if (out.items.len != 0) {
            try out.append(app.allocator, '\t');
        }
        // Flattened here and nowhere else: this is one line of tab separated
        // fields, and a newline inside one would make it two lines that nothing
        // can tell apart again. The CSV copy beside it keeps the value whole,
        // because CSV has quotes to carry it in.
        try out.appendSlice(app.allocator, cell.text);
    }
    try app.screen.copy(out.items);
    app.say("the row is in the clipboard", .{});
}

/// The whole page, header included, as CSV.
pub fn copyPage(app: *App) !void {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(app.allocator);
    var written: usize = 0;
    for (app.grid.cols.items, 0..) |name, i| {
        if (app.isHidden(i)) {
            continue;
        }
        if (written != 0) {
            try out.append(app.allocator, ',');
        }
        try csv.writeField(&out, app.allocator, name, ',');
        written += 1;
    }
    try out.append(app.allocator, '\n');
    for (app.grid.rows.items) |row| {
        written = 0;
        for (row.cells, 0..) |cell, i| {
            if (app.isHidden(i)) {
                continue;
            }
            if (written != 0) {
                try out.append(app.allocator, ',');
            }
            try csv.writeField(&out, app.allocator, cell.whole(), ',');
            written += 1;
        }
        try out.append(app.allocator, '\n');
    }
    try app.screen.copy(out.items);
    app.say("{d} row(s) copied as CSV", .{app.grid.rows.items.len});
}

pub fn openExportForm(app: *App) !void {
    const form = try app.newForm(.export_data, "export", "");
    try form.choice("what", &[_][]const u8{ "whole database", "this table", "the grid" }, if (!app.hasTable()) 2 else 1);
    try form.choice("format", &[_][]const u8{ "sql", "csv", "tsv" }, 0);
    try form.toggle("structure", true);
    try form.toggle("data", true);
    try form.text("file", "dump.sql", 40);
}

pub fn openImportForm(app: *App) !void {
    // Importing is inserting, so an engine that takes no new rows takes no
    // file of them either.
    const refused = app.caps().no_insert;
    if (refused.len != 0) {
        app.complain("{s}", .{refused});
        return;
    }
    const form = try app.newForm(.import_data, "import", "");
    try form.choice("kind", &[_][]const u8{ "sql script", "csv into a table" }, 0);
    try form.text("file", "", 40);
    try form.text("into table", app.grid.name orelse "", 30);
    try form.toggle("first line is a header", true);
    try form.choice("separator", &[_][]const u8{ ",", ";", "tab" }, 0);
}

pub fn runExport(app: *App, form: *Form.Form) !void {
    const what = form.valueOf(0);
    const format = form.valueOf(1);
    const path = form.valueOf(4);
    if (path.len == 0) {
        app.complain("give the export a file name", .{});
        return;
    }
    if (std.mem.eql(u8, format, "sql")) {
        if (std.mem.eql(u8, what, "the grid")) {
            app.complain("a grid can only go out as csv or tsv", .{});
            return;
        }
        const only = if (std.mem.eql(u8, what, "this table")) app.grid.name else null;
        try dumpTo(app, path, only, form.isOn(2), form.isOn(3));
        return;
    }
    const separator: u8 = if (std.mem.eql(u8, format, "tsv")) '\t' else ',';
    if (std.mem.eql(u8, what, "the grid")) {
        try app.writeGrid(path, separator);
        return;
    }
    const table = if (std.mem.eql(u8, what, "this table")) (app.grid.name orelse "") else "";
    if (table.len == 0) {
        app.complain("csv exports one table at a time", .{});
        return;
    }
    try app.writeQuery(path, table, separator);
}

pub fn runImport(app: *App, form: *Form.Form) !void {
    const path = form.valueOf(1);
    if (path.len == 0) {
        app.complain("give the import a file name", .{});
        return;
    }
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const body = csv.readFile(arena.allocator(), path) catch |err| {
        app.complain("cannot read {s}: {s}", .{ path, @errorName(err) });
        return;
    };
    if (std.mem.eql(u8, form.valueOf(0), "sql script")) {
        const script = try app.allocator.dupe(u8, body);
        defer app.allocator.free(script);
        app.closeForm();
        try app.runBatch(script);
        return;
    }
    const table = form.valueOf(2);
    if (table.len == 0) {
        app.complain("say which table to import into", .{});
        return;
    }
    const separator: u8 = switch (form.field(4).?.pick) {
        1 => ';',
        2 => '\t',
        else => ',',
    };
    try app.importCsv(arena.allocator(), table, body, separator, form.isOn(3));
}

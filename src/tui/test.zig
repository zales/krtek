// Unit tests of the pieces that do not need a terminal: zig build test
const std = @import("std");
const term = @import("term.zig");
const app = @import("app.zig");
const fuzzy = @import("fuzzy.zig");
const db = @import("db");

// the DDL generator brings its own tests
comptime {
    _ = @import("app.zig");
    _ = @import("draw.zig");
    _ = @import("ddl.zig");
    _ = @import("connections.zig");
    _ = @import("editor.zig");
    _ = @import("files.zig");
    _ = @import("fuzzy.zig");
    _ = @import("input.zig");
    _ = @import("term.zig");
}

test "display width counts columns, not bytes" {
    try std.testing.expectEqual(@as(usize, 3), term.width("abc"));
    try std.testing.expectEqual(@as(usize, 5), term.width("Čapek"));
    try std.testing.expectEqual(@as(usize, 4), term.width("日本"));
    try std.testing.expectEqual(@as(usize, 0), term.width(""));
}

test "fit never exceeds the given number of columns" {
    for ([_][]const u8{ "abcdef", "Příliš žluťoučký", "日本語テキスト", "" }) |text| {
        var max: usize = 0;
        while (max <= 12) : (max += 1) {
            const piece = term.fit(text, max);
            try std.testing.expect(piece.cols <= max);
            try std.testing.expectEqual(piece.cols, term.width(piece.text));
            try std.testing.expect(std.mem.startsWith(u8, text, piece.text));
        }
    }
}

test "cells are flattened to one line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const flat = try app.flatten(arena.allocator(), "a\nb\tc\rd");
    try std.testing.expectEqualStrings("a b c d", flat);
}

test "delimited output quotes only when it has to" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try app.writeDelimited(&out, std.testing.allocator, "plain", ',');
    try out.append(std.testing.allocator, '|');
    try app.writeDelimited(&out, std.testing.allocator, "has,comma", ',');
    try out.append(std.testing.allocator, '|');
    try app.writeDelimited(&out, std.testing.allocator, "say \"hi\"", ',');
    try out.append(std.testing.allocator, '|');
    try app.writeDelimited(&out, std.testing.allocator, "has\ttab", ',');
    try std.testing.expectEqualStrings("plain|\"has,comma\"|\"say \"\"hi\"\"\"|has\ttab", out.items);
}

test "object filter is case insensitive" {
    // The object filter matches fuzzily now; the cases it used to take still pass.
    try std.testing.expect(fuzzy.match("Authors", "auth", null) != null);
    try std.testing.expect(fuzzy.match("book_list", "LIST", null) != null);
    try std.testing.expect(fuzzy.match("order_items", "ordit", null) != null);
    try std.testing.expect(fuzzy.match("books", "xyz", null) == null);
    try std.testing.expect(fuzzy.match("books", "", null) != null);
}

test "page count rounds up" {
    try std.testing.expectEqual(@as(usize, 3), app.divCeil(101, 50));
    try std.testing.expectEqual(@as(usize, 2), app.divCeil(100, 50));
    try std.testing.expectEqual(@as(usize, 0), app.divCeil(0, 50));
}

// --- the structured path: what the interface asks the drivers for ---

test "the filter form's operators are the interface's own" {
    try std.testing.expectEqual(db.ask.Op.eq, app.operatorOf("="));
    try std.testing.expectEqual(db.ask.Op.ne, app.operatorOf("!="));
    try std.testing.expectEqual(db.ask.Op.lt, app.operatorOf("<"));
    try std.testing.expectEqual(db.ask.Op.le, app.operatorOf("<="));
    try std.testing.expectEqual(db.ask.Op.gt, app.operatorOf(">"));
    try std.testing.expectEqual(db.ask.Op.ge, app.operatorOf(">="));
    try std.testing.expectEqual(db.ask.Op.like, app.operatorOf("LIKE"));
    // `contains` is LIKE; the wildcards are put around the value, not here.
    try std.testing.expectEqual(db.ask.Op.like, app.operatorOf("contains"));
    try std.testing.expectEqual(db.ask.Op.is_null, app.operatorOf("IS NULL"));
    try std.testing.expectEqual(db.ask.Op.not_null, app.operatorOf("IS NOT NULL"));
    // Every operator the form offers is one the interface can express, so a new
    // one cannot be added to the list and silently mean equality.
    for (app.OPERATORS) |name| {
        const op = app.operatorOf(name);
        const unary = std.mem.startsWith(u8, name, "IS ");
        try std.testing.expectEqual(!unary, op.takesValue());
    }
    // And anything else is an equality rather than a crash.
    try std.testing.expectEqual(db.ask.Op.eq, app.operatorOf("nonsense"));
}

test "a row is addressed by its key columns, and a NULL by IS NULL" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // id=7, title='RUR', part=NULL - with the key over id and part.
    const cells = [_]app.Cell{
        .{ .text = "7", .kind = .int },
        .{ .text = "RUR", .kind = .text },
        .{ .text = "NULL", .kind = .nul },
    };
    const keys = [_]app.Position{
        .{ .name = "id", .at = 0 },
        .{ .name = "part", .at = 2 },
    };
    const identity = try app.App.identityOf(a, &keys, &cells, "");
    try std.testing.expectEqual(@as(usize, 2), identity.len);
    try std.testing.expectEqualStrings("id", identity[0].column);
    try std.testing.expectEqualStrings("7", identity[0].value);
    try std.testing.expectEqual(db.ask.Op.eq, identity[0].op);
    // = NULL matches nothing, which would make the row unaddressable.
    try std.testing.expectEqualStrings("part", identity[1].column);
    try std.testing.expectEqual(db.ask.Op.is_null, identity[1].op);

    // And it renders into the WHERE the engines used to be handed directly.
    var sql: db.List = .empty;
    defer sql.deinit(a);
    try db.ask.renderChange(&sql, a, .{
        .kind = .delete,
        .table = .{ .name = "books" },
        .where = identity,
    }, .{});
    try std.testing.expectEqualStrings(
        "DELETE FROM \"books\" WHERE \"id\" = '7' AND \"part\" IS NULL",
        sql.items,
    );
}

test "a hidden key stands in for the first column, under the engine's own name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cells = [_]app.Cell{
        .{ .text = "42", .kind = .int },
        .{ .text = "x", .kind = .text },
    };
    const keys = [_]app.Position{.{ .name = "__key", .at = 0 }};
    const identity = try app.App.identityOf(a, &keys, &cells, "rowid");
    try std.testing.expectEqual(@as(usize, 1), identity.len);
    try std.testing.expectEqualStrings("rowid", identity[0].column);
    try std.testing.expectEqualStrings("42", identity[0].value);
}

test "a key that points past the row is left out rather than read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cells = [_]app.Cell{.{ .text = "1", .kind = .int }};
    const keys = [_]app.Position{
        .{ .name = "id", .at = 0 },
        .{ .name = "gone", .at = 9 },
    };
    const identity = try app.App.identityOf(arena.allocator(), &keys, &cells, "");
    try std.testing.expectEqual(@as(usize, 1), identity.len);
}

// the driver layer brings its own tests
comptime {
    _ = @import("db");
    _ = @import("biometry.zig");
    _ = @import("keychain.zig");
}

/// What a SQLite database may be asked. Not `caps(undefined)` like the others:
/// this driver is two things, a database and a CSV file read into one, and has
/// to look at itself to say which.
fn sqliteCaps() db.Caps {
    var plain = db.sqlite.Db{ .allocator = std.testing.allocator, .handle = null };
    return plain.caps();
}

test "the connection list and the driver agree on which file is a CSV" {
    // The rule is written twice - the list of connections reads no driver, and
    // the driver no list - so this is what keeps the two from drifting: a name
    // one of them took for a CSV and the other for a database would be opened
    // as one and labelled as the other.
    const conns = @import("connections.zig");
    for ([_][]const u8{
        "people.csv", "PEOPLE.CSV", "towns.tsv", "Towns.Tsv",      "/srv/data/a.b.csv",
        "people.db",  "csv",        ".csv",      "people.csv.bak", "notes.txt",
        "data.tab",   "",           "tsv",
    }) |name| {
        try std.testing.expectEqual(db.sheet.claims(name), conns.isSheet(name));
    }
}

test "an engine that refuses a change says so in one place" {
    // The three texts are the flag and the reason at once, so a driver cannot
    // half-declare one: a refusal with no reason would reach the screen as a
    // blank complaint, and a reason nobody checks would never be shown at all.
    const drivers = [_]db.Caps{
        db.k8s.Db.caps(undefined),
        db.kafka.Db.caps(undefined),
        db.rabbit.Db.caps(undefined),
        sqliteCaps(),
        db.redis.Db.caps(undefined),
        db.s3.Db.caps(undefined),
        db.azure.Db.caps(undefined),
        db.sftp.Db.caps(undefined),
    };
    for (drivers) |caps| {
        for ([_][]const u8{ caps.no_insert, caps.no_update, caps.no_delete, caps.no_ddl, caps.no_relations, caps.no_tables }) |why| {
            // Either it is allowed, or it is refused with something worth reading.
            try std.testing.expect(why.len == 0 or why.len > 20);
        }
    }
    // And the ones this review was about, named rather than assumed.
    try std.testing.expect(db.k8s.Db.caps(undefined).no_insert.len != 0);
    try std.testing.expect(db.k8s.Db.caps(undefined).no_update.len != 0);
    try std.testing.expect(db.k8s.Db.caps(undefined).no_ddl.len != 0);
    try std.testing.expect(db.k8s.Db.caps(undefined).no_delete.len == 0);
    try std.testing.expect(db.kafka.Db.caps(undefined).no_update.len != 0);
    try std.testing.expect(db.kafka.Db.caps(undefined).no_delete.len != 0);
    try std.testing.expect(db.kafka.Db.caps(undefined).no_insert.len == 0);
    try std.testing.expect(db.kafka.Db.caps(undefined).no_ddl.len == 0);
    try std.testing.expect(db.rabbit.Db.caps(undefined).no_update.len != 0);
    // A database does all four, and nothing above should have changed that.
    const sqlite = sqliteCaps();
    try std.testing.expect(sqlite.no_insert.len == 0 and sqlite.no_update.len == 0);
    try std.testing.expect(sqlite.no_delete.len == 0 and sqlite.no_ddl.len == 0);
}

test "an engine is not offered what it cannot do" {
    // The palette used to hold every command whatever was open, so Redis - which
    // has one table holding every key, and no SQL - was offered "write and run
    // SQL", "create a view" and "add a foreign key". The keys themselves refused,
    // which means the list was telling somebody about things that were not there.
    const input = @import("input.zig");
    for ([_]db.Caps{
        db.redis.Db.caps(undefined),
        db.s3.Db.caps(undefined),
        db.azure.Db.caps(undefined),
        db.sftp.Db.caps(undefined),
    }) |caps| {
        // None of these has a schema statement of any kind, and each says why.
        try std.testing.expect(caps.no_ddl.len > 20);
        for (input.actions) |action| {
            if (action.wants == .ddl or action.wants == .tables or action.wants == .relations) {
                try std.testing.expect(!input.offered(action, caps, false));
            }
        }
    }

    // Kafka is the one that has the object without the things that hang off it:
    // a topic is really created and really dropped, and it has no indexes.
    const kafka = db.kafka.Db.caps(undefined);
    try std.testing.expect(kafka.no_ddl.len == 0);
    try std.testing.expect(kafka.no_relations.len > 20);
    for (input.actions) |action| {
        if (action.wants == .ddl or action.wants == .tables) {
            try std.testing.expect(input.offered(action, kafka, false));
        }
        if (action.wants == .relations) {
            try std.testing.expect(!input.offered(action, kafka, false));
        }
    }

    // A CSV file is the other way round from everything else: one table that
    // is altered and emptied like any other, and no room for a second one or
    // for anything that hangs off it. SQLite itself, the same driver over a
    // database, is offered all of it.
    var memory = db.sqlite.Db{ .allocator = std.testing.allocator, .handle = null };
    var held: db.sheet.Sheet = .{ .allocator = std.testing.allocator, .arena = .init(std.testing.allocator) };
    memory.sheet = &held;
    const csv = memory.caps();
    try std.testing.expectEqualStrings("CSV", csv.label);
    try std.testing.expect(csv.no_ddl.len == 0 and csv.no_insert.len == 0);
    try std.testing.expect(csv.no_tables.len > 20 and csv.no_relations.len > 20);
    for (input.actions) |action| {
        switch (action.wants) {
            .ddl => try std.testing.expect(input.offered(action, csv, false)),
            .tables, .relations => try std.testing.expect(!input.offered(action, csv, false)),
            else => {},
        }
        if (action.wants == .tables or action.wants == .relations) {
            try std.testing.expect(input.offered(action, sqliteCaps(), false));
        }
    }

    // A full SQL engine is offered all of it, and nothing above may have changed
    // that. PostgreSQL rather than SQLite, because SQLite has no schemas and so
    // correctly does not get the one that switches them. Files pretended present,
    // since whether a connection has any is not a property of the engine.
    const postgres = db.postgres.Db.caps(undefined);
    for (input.actions) |action| {
        try std.testing.expect(input.offered(action, postgres, true));
    }
}

test "the editor is called what the engine would call it" {
    const input = @import("input.zig");
    const editor = input.actionThat(.editor);
    // The same key and the same panel everywhere - what it takes is that engine's
    // own commands - so it is offered everywhere, under the right name.
    try std.testing.expect(input.offered(editor, db.redis.Db.caps(undefined), false));
    try std.testing.expectEqualStrings("write and run SQL", input.labelFor(editor, sqliteCaps()));
    try std.testing.expectEqualStrings("write and run a command", input.labelFor(editor, db.redis.Db.caps(undefined)));
    // And with nothing open, the plain name is not guessed at.
    try std.testing.expectEqualStrings("write and run SQL", input.labelFor(editor, null));
}

test "alias extraction handles multiple syntax forms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ed = @import("editor.zig");

    const sql1 = "SELECT a.name, b.title FROM authors a JOIN books b ON a.id = b.author_id";
    const res1 = try ed.extractAliases(a, sql1);
    try std.testing.expectEqual(@as(usize, 2), res1.len);
    try std.testing.expectEqualStrings("a", res1[0].alias);
    try std.testing.expectEqualStrings("authors", res1[0].table);
    try std.testing.expectEqualStrings("b", res1[1].alias);
    try std.testing.expectEqualStrings("books", res1[1].table);

    const sql2 = "SELECT 1 FROM `orders` AS o, \"customers\" c WHERE o.cust_id = c.id";
    const res2 = try ed.extractAliases(a, sql2);
    try std.testing.expectEqual(@as(usize, 2), res2.len);
    try std.testing.expectEqualStrings("o", res2[0].alias);
    try std.testing.expectEqualStrings("orders", res2[0].table);
    try std.testing.expectEqualStrings("c", res2[1].alias);
    try std.testing.expectEqualStrings("customers", res2[1].table);
}

test "a tab gives back everything it holds" {
    // Closing a tab used to be written out twice, and once more for quitting,
    // and the three had stopped agreeing: one freed the file panes twice, one
    // left the names in the object list behind, and none of them freed what a
    // row filter was made of. There is one of it now, and the allocator this
    // test runs on fails it for anything left behind or given back twice.
    const a = std.testing.allocator;
    var tab = app.Tab.init(a);

    try tab.sidebar.objects.append(a, .{
        .name = try a.dupe(u8, "authors"),
        .group = try a.dupe(u8, "tables"),
        .kind = try a.dupe(u8, "table"),
        .rows = 5,
    });
    try tab.sidebar.filter.appendSlice(a, "auth");
    tab.grid.name = try a.dupe(u8, "authors");
    tab.grid.order = try a.dupe(u8, "name");
    try tab.grid.schema.appendSlice(a, "public");
    try tab.grid.title.appendSlice(a, "authors");
    try tab.grid.where_text.appendSlice(a, "born > 1900");
    try tab.grid.conditions.append(a, .{
        .column = try a.dupe(u8, "born"),
        .value = try a.dupe(u8, "1900"),
    });
    try tab.cursor.marked.append(a, try app.ownFilters(a, &.{.{ .column = "id", .value = "3" }}));
    try tab.cursor.hidden.append(a, 1);
    tab.marks[0] = .{ .table = try a.dupe(u8, "authors"), .row = 2 };
    tab.marks[25] = .{ .table = null, .row = 7 };
    try tab.follow.statement.appendSlice(a, "select 1");
    try tab.typing.pending.appendSlice(a, "drop table authors");
    try tab.typing.draft.appendSlice(a, "select * from authors");
    tab.typing.prompt = .{ .kind = .command, .label = " :" };
    try tab.typing.prompt.?.buffer.appendSlice(a, "limit 10");
    tab.typing.editor = @import("editor.zig").Editor.init(a);
    try tab.typing.editor.?.insert("select 1");
    try tab.report.status.appendSlice(a, "5 rows");
    _ = try tab.arena.allocator().dupe(u8, "a page of rows");
    _ = try tab.object.arena.allocator().dupe(u8, "what an opened row said");
    tab.owned_path = try a.dupe(u8, "tests/sample.db");
    tab.path = tab.owned_path;
    // The two panes free themselves, which is what was done to them twice.
    tab.files = try @import("files.zig").Manager.init(a, null);

    tab.deinit(a);
}

test "every action has one line, one key and one way of being asked for" {
    const input = @import("input.zig");
    for (std.enums.values(input.Does)) |does| {
        var lines: usize = 0;
        for (input.actions) |action| {
            lines += @intFromBool(action.does == does);
        }
        try std.testing.expectEqual(@as(usize, 1), lines);
    }
    for (input.actions, 0..) |action, i| {
        try std.testing.expect(action.keys.len != 0);
        for (input.actions[i + 1 ..]) |other| {
            // One key, one thing - except where it is the same thing in each
            // pane: `/` looks for a name in the list and for text in the rows.
            const one_per_pane = action.needs != null and other.needs != null and action.needs.? != other.needs.?;
            try std.testing.expect(one_per_pane or !std.mem.eql(u8, action.keys, other.keys));
        }
        // A key that moves the cursor is not also one that does something: the
        // table is asked first, so the action would win and the movement would
        // quietly stop working.
        if (action.keys.len == 1) {
            try std.testing.expect(std.mem.findScalar(u8, input.MOVING, action.keys[0]) == null);
        }
    }
}

test "what a key did before vi took it is behind g and that key" {
    // `m` opened the messages, `v` the whole value, and so on for nine of
    // them. Each of those letters means what it means in vi now, and each of
    // those things is still one rule away.
    const input = @import("input.zig");
    const moved = [_]struct { does: input.Does, keys: []const u8 }{
        .{ .does = .whole_value, .keys = "gv" },
        .{ .does = .view, .keys = "gV" },
        .{ .does = .columns, .keys = "gw" },
        .{ .does = .info, .keys = "gb" },
        .{ .does = .messages, .keys = "gm" },
        .{ .does = .clone, .keys = "gy" },
        .{ .does = .import, .keys = "gM" },
        .{ .does = .relations, .keys = "gL" },
        .{ .does = .rename, .keys = "gN" },
    };
    for (moved) |one| {
        try std.testing.expectEqualStrings(one.keys, input.actionThat(one.does).keys);
    }
    // And the second key of `g` is not one `g` already has a use for.
    for (input.actions) |action| {
        if (action.keys.len == 2 and action.keys[0] == 'g') {
            try std.testing.expect(std.mem.findScalar(u8, "gtTnp123456789", action.keys[1]) == null);
        }
    }
}

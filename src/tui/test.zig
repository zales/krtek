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
	_ = @import("csv.zig");
	_ = @import("connections.zig");
	_ = @import("editor.zig");
	_ = @import("files.zig");
	_ = @import("fuzzy.zig");
	_ = @import("input.zig");
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
	var out: std.ArrayListUnmanaged(u8) = .empty;
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
}

test "an engine that refuses a change says so in one place" {
	// The three texts are the flag and the reason at once, so a driver cannot
	// half-declare one: a refusal with no reason would reach the screen as a
	// blank complaint, and a reason nobody checks would never be shown at all.
	const drivers = [_]db.Caps{
		db.k8s.Db.caps(undefined),
		db.kafka.Db.caps(undefined),
		db.rabbit.Db.caps(undefined),
		db.sqlite.Db.caps(undefined),
		db.redis.Db.caps(undefined),
		db.s3.Db.caps(undefined),
		db.azure.Db.caps(undefined),
		db.sftp.Db.caps(undefined),
	};
	for (drivers) |caps| {
		for ([_][]const u8{ caps.no_insert, caps.no_update, caps.no_delete, caps.no_ddl, caps.no_relations }) |why| {
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
	const sqlite = db.sqlite.Db.caps(undefined);
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
			if (action.wants == .ddl or action.wants == .relations) {
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
		if (action.wants == .ddl) {
			try std.testing.expect(input.offered(action, kafka, false));
		}
		if (action.wants == .relations) {
			try std.testing.expect(!input.offered(action, kafka, false));
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
	const editor = for (input.actions) |action| {
		if (action.key == 's') break action;
    } else unreachable;
	// The same key and the same panel everywhere - what it takes is that engine's
	// own commands - so it is offered everywhere, under the right name.
	try std.testing.expect(input.offered(editor, db.redis.Db.caps(undefined), false));
	try std.testing.expectEqualStrings("write and run SQL", input.labelFor(editor, db.sqlite.Db.caps(undefined)));
	try std.testing.expectEqualStrings("write and run a command", input.labelFor(editor, db.redis.Db.caps(undefined)));
	// And with nothing open, the plain name is not guessed at.
	try std.testing.expectEqualStrings("write and run SQL", input.labelFor(editor, null));
}

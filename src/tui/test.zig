// Unit tests of the pieces that do not need a terminal: zig build test
const std = @import("std");
const term = @import("term.zig");
const app = @import("app.zig");
const fuzzy = @import("fuzzy.zig");

// the DDL generator brings its own tests
comptime {
	_ = @import("ddl.zig");
	_ = @import("csv.zig");
	_ = @import("connections.zig");
	_ = @import("editor.zig");
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

// the driver layer brings its own tests
comptime {
	_ = @import("db");
}

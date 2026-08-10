//! Reading and writing delimited files: what a spreadsheet and every other
//! database client will read.

const std = @import("std");

const List = std.ArrayListUnmanaged(u8);

/// Split one CSV line into fields, honouring quotes and doubled quotes. Returns
/// null when the line ends inside a quoted field, so the caller can join it
/// with the next one.
pub fn splitLine(arena: std.mem.Allocator, line: []const u8, separator: u8) !?[][]const u8 {
	var fields: std.ArrayListUnmanaged([]const u8) = .empty;
	var current: List = .empty;
	var quoted = false;
	var i: usize = 0;
	while (i < line.len) : (i += 1) {
		const char = line[i];
		if (quoted) {
			if (char == '"') {
				if (i + 1 < line.len and line[i + 1] == '"') {
					try current.append(arena, '"');
					i += 1;
				} else {
					quoted = false;
				}
			} else {
				try current.append(arena, char);
			}
			continue;
		}
		if (char == '"' and current.items.len == 0) {
			quoted = true;
		} else if (char == separator) {
			try fields.append(arena, current.items);
			current = .empty;
		} else {
			try current.append(arena, char);
		}
	}
	if (quoted) {
		return null; // a newline inside a quoted value
	}
	try fields.append(arena, current.items);
	return fields.items;
}

/// Write one value, quoting it only when it has to be quoted.
pub fn writeField(out: *List, allocator: std.mem.Allocator, text: []const u8, separator: u8) !void {
	if (std.mem.indexOfAny(u8, text, &[_]u8{ '"', '\n', '\r', separator }) == null) {
		try out.appendSlice(allocator, text);
		return;
	}
	try out.append(allocator, '"');
	for (text) |char| {
		if (char == '"') {
			try out.append(allocator, '"');
		}
		try out.append(allocator, char);
	}
	try out.append(allocator, '"');
}

/// Read a whole file through libc, since std.fs is mid-rework in this Zig.
pub fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
	var buffer: [std.fs.max_path_bytes]u8 = undefined;
	if (path.len >= buffer.len) {
		return error.NameTooLong;
	}
	@memcpy(buffer[0..path.len], path);
	buffer[path.len] = 0;
	const file = std.c.fopen(@ptrCast(&buffer), "rb") orelse return error.CannotOpen;
	defer _ = std.c.fclose(file);
	var out: List = .empty;
	var chunk: [65536]u8 = undefined;
	while (true) {
		const got = std.c.fread(&chunk, 1, chunk.len, file);
		if (got == 0) {
			break;
		}
		try out.appendSlice(allocator, chunk[0..got]);
	}
	return out.items;
}

test "quotes and separators inside a field" {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();
	const a = arena.allocator();
	const fields = (try splitLine(a, "one,\"two, still two\",\"say \"\"hi\"\"\",", ',')).?;
	try std.testing.expectEqual(@as(usize, 4), fields.len);
	try std.testing.expectEqualStrings("one", fields[0]);
	try std.testing.expectEqualStrings("two, still two", fields[1]);
	try std.testing.expectEqualStrings("say \"hi\"", fields[2]);
	try std.testing.expectEqualStrings("", fields[3]);
}

test "an unterminated quote asks for the next line" {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();
	try std.testing.expect((try splitLine(arena.allocator(), "a,\"unfinished", ',')) == null);
}

test "tab separated" {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();
	const fields = (try splitLine(arena.allocator(), "a\tb\tc", '\t')).?;
	try std.testing.expectEqual(@as(usize, 3), fields.len);
	try std.testing.expectEqualStrings("b", fields[1]);
}

test "round trip through writeField" {
	const a = std.testing.allocator;
	var out: List = .empty;
	defer out.deinit(a);
	try writeField(&out, a, "plain", ',');
	try out.append(a, ',');
	try writeField(&out, a, "with,comma", ',');
	try std.testing.expectEqualStrings("plain,\"with,comma\"", out.items);

	var arena = std.heap.ArenaAllocator.init(a);
	defer arena.deinit();
	const fields = (try splitLine(arena.allocator(), out.items, ',')).?;
	try std.testing.expectEqualStrings("with,comma", fields[1]);
}

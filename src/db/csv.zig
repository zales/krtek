//! Reading and writing delimited files: what a spreadsheet and every other
//! database client will read.
//!
//! Beside the drivers rather than beside the interface, because one of them
//! reads these too: a CSV file opened as a database is `sheet.zig`.

const std = @import("std");

const List = std.ArrayList(u8);

/// One field of a record, and whether it stood in quotes. That is the only way
/// a delimited file has of telling an empty text from no value at all: `""` is
/// the first and nothing between two separators is the second, which is how
/// PostgreSQL's COPY reads them too.
pub const Field = struct {
    text: []const u8,
    quoted: bool = false,

    /// Nothing at all, rather than a text with nothing in it.
    pub fn absent(self: Field) bool {
        return !self.quoted and self.text.len == 0;
    }
};

/// A whole file, one record at a time. A record is a line, except that a
/// quoted field may run over several of them - which is why this walks the
/// file rather than its lines.
///
/// The same reading as `splitLine`: a quote opens a quoted field only where the
/// field starts, a doubled quote inside one is a quote, and whatever follows the
/// closing quote belongs to the field as it stands. A quote nothing closes runs
/// to the end of the file - better the rest of it in one field than none of it.
pub const Reader = struct {
    body: []const u8,
    separator: u8,
    at: usize = 0,
    /// How the first line ended, which is how the file ends its lines: `\n`,
    /// `\r\n` or a `\r` on its own. Empty until a line has ended.
    ending: []const u8 = "",

    /// The next record into `fields`, or false at the end. A field with nothing
    /// to undo is a slice of the file; one with a doubled quote in it is built
    /// in `arena`.
    pub fn next(self: *Reader, arena: std.mem.Allocator, fields: *std.ArrayList(Field)) !bool {
        fields.clearRetainingCapacity();
        const body = self.body;
        if (self.at >= body.len) {
            return false;
        }
        var i = self.at;
        while (true) {
            var end = i;
            var quoted = false;
            // Whether the field is the bytes between its quotes and nothing else.
            var plain = true;
            if (end < body.len and body[end] == '"') {
                quoted = true;
                end += 1;
                while (end < body.len) : (end += 1) {
                    if (body[end] != '"') {
                        continue;
                    }
                    if (end + 1 < body.len and body[end + 1] == '"') {
                        plain = false;
                        end += 1;
                        continue;
                    }
                    break;
                }
                if (end < body.len) {
                    end += 1; // the closing quote
                } else {
                    plain = false;
                }
            }
            const closed = end;
            while (end < body.len and body[end] != self.separator and body[end] != '\n' and body[end] != '\r') {
                end += 1;
            }
            if (!quoted) {
                try fields.append(arena, .{ .text = body[i..end] });
            } else if (plain and end == closed) {
                try fields.append(arena, .{ .text = body[i + 1 .. end - 1], .quoted = true });
            } else {
                try fields.append(arena, .{ .text = try unquote(arena, body[i + 1 .. end]), .quoted = true });
            }
            if (end < body.len and body[end] == self.separator) {
                i = end + 1;
                continue;
            }
            // The end of the record, or of the file.
            var after = end;
            if (end < body.len) {
                after = if (body[end] == '\r' and end + 1 < body.len and body[end + 1] == '\n') end + 2 else end + 1;
                if (self.ending.len == 0) {
                    self.ending = body[end..after];
                }
            }
            self.at = after;
            return true;
        }
    }

    /// What a quoted field holds, given everything after its opening quote.
    fn unquote(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
        var out: List = .empty;
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] != '"') {
                try out.append(arena, text[i]);
                continue;
            }
            if (i + 1 < text.len and text[i + 1] == '"') {
                try out.append(arena, '"');
                i += 1;
                continue;
            }
            // The closing quote: the rest is outside it and is taken as it is.
            try out.appendSlice(arena, text[i + 1 ..]);
            break;
        }
        return out.items;
    }
};

/// Which character separates the fields, read off the first line: the one of
/// `,` `;` tab and `|` there is most of outside quotes, and a comma where there
/// is none of them. A semicolon is what a spreadsheet writes wherever the comma
/// is the decimal mark, so guessing a comma is wrong for half of Europe.
pub fn sniff(body: []const u8) u8 {
    const candidates = [_]u8{ ',', ';', '\t', '|' };
    var counts: [candidates.len]usize = @splat(0);
    var quoted = false;
    for (body) |char| {
        if (char == '"') {
            quoted = !quoted;
            continue;
        }
        if (quoted) {
            continue;
        }
        if (char == '\n' or char == '\r') {
            break;
        }
        for (candidates, 0..) |candidate, at| {
            counts[at] += @intFromBool(char == candidate);
        }
    }
    var best: usize = 0;
    for (counts, 0..) |count, at| {
        if (count > counts[best]) {
            best = at;
        }
    }
    return candidates[best];
}

/// Split one CSV line into fields, honouring quotes and doubled quotes. Returns
/// null when the line ends inside a quoted field, so the caller can join it
/// with the next one.
pub fn splitLine(arena: std.mem.Allocator, line: []const u8, separator: u8) !?[][]const u8 {
    var fields: std.ArrayList([]const u8) = .empty;
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
    if (std.mem.findAny(u8, text, &[_]u8{ '"', '\n', '\r', separator }) == null) {
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
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
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

fn expectRecord(reader: *Reader, arena: std.mem.Allocator, expected: []const []const u8) !void {
    var fields: std.ArrayList(Field) = .empty;
    try std.testing.expect(try reader.next(arena, &fields));
    try std.testing.expectEqual(expected.len, fields.items.len);
    for (expected, fields.items) |want, got| {
        try std.testing.expectEqualStrings(want, got.text);
    }
}

test "a file is read a record at a time, whatever its lines end in" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fields: std.ArrayList(Field) = .empty;

    var unix = Reader{ .body = "a,b\n1,2\n", .separator = ',' };
    try expectRecord(&unix, a, &.{ "a", "b" });
    try expectRecord(&unix, a, &.{ "1", "2" });
    // The newline that ends the file ends the last record; it does not start one.
    try std.testing.expect(!try unix.next(a, &fields));
    try std.testing.expectEqualStrings("\n", unix.ending);

    var dos = Reader{ .body = "a,b\r\n1,2", .separator = ',' };
    try expectRecord(&dos, a, &.{ "a", "b" });
    // And a last line with nothing after it is still a record.
    try expectRecord(&dos, a, &.{ "1", "2" });
    try std.testing.expect(!try dos.next(a, &fields));
    try std.testing.expectEqualStrings("\r\n", dos.ending);

    var old = Reader{ .body = "a\rb\r", .separator = ',' };
    try expectRecord(&old, a, &.{"a"});
    try expectRecord(&old, a, &.{"b"});
    try std.testing.expect(!try old.next(a, &fields));
    try std.testing.expectEqualStrings("\r", old.ending);

    var nothing = Reader{ .body = "", .separator = ',' };
    try std.testing.expect(!try nothing.next(a, &fields));
}

test "a quoted field keeps its separators, its quotes and its line breaks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fields: std.ArrayList(Field) = .empty;

    var reader = Reader{
        .body = "one,\"two, still two\",\"say \"\"hi\"\"\",\n\"over\r\ntwo lines\",x\n",
        .separator = ',',
    };
    try expectRecord(&reader, a, &.{ "one", "two, still two", "say \"hi\"", "" });
    try expectRecord(&reader, a, &.{ "over\r\ntwo lines", "x" });
    try std.testing.expect(!try reader.next(a, &fields));
    // The line break inside the quotes was not the one the file ends lines with.
    try std.testing.expectEqualStrings("\n", reader.ending);

    // What follows a closing quote is the field's, and a quote nothing closes
    // takes the rest of the file rather than losing it.
    var loose = Reader{ .body = "\"a\"b,c\n\"open,\nend", .separator = ',' };
    try expectRecord(&loose, a, &.{ "ab", "c" });
    try expectRecord(&loose, a, &.{"open,\nend"});
    try std.testing.expect(!try loose.next(a, &fields));
}

test "an empty field is no value, and an empty pair of quotes is an empty text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fields: std.ArrayList(Field) = .empty;
    var reader = Reader{ .body = ",\"\",x", .separator = ',' };
    try std.testing.expect(try reader.next(arena.allocator(), &fields));
    try std.testing.expectEqual(@as(usize, 3), fields.items.len);
    try std.testing.expect(fields.items[0].absent());
    try std.testing.expect(!fields.items[1].absent());
    try std.testing.expectEqualStrings("", fields.items[1].text);
    try std.testing.expect(!fields.items[2].absent());
}

test "the separator is read off the first line" {
    try std.testing.expectEqual(@as(u8, ','), sniff("a,b,c\n1;2;3;4;5\n"));
    try std.testing.expectEqual(@as(u8, ';'), sniff("jmeno;prijmeni;plat\n"));
    try std.testing.expectEqual(@as(u8, '\t'), sniff("a\tb\tc\n"));
    try std.testing.expectEqual(@as(u8, '|'), sniff("a|b|c"));
    // One inside quotes separates nothing.
    try std.testing.expectEqual(@as(u8, ';'), sniff("\"a,b,c\";d\n"));
    // And a single column has no separator to find: a comma, then.
    try std.testing.expectEqual(@as(u8, ','), sniff("name\nvalue\n"));
    try std.testing.expectEqual(@as(u8, ','), sniff(""));
}

//! A small multi-line text editor, and the SQL tokenizer that colours it.
//!
//! Enough of an editor for writing a statement: several lines, a cursor that
//! moves the way a cursor moves, and completion of the names the database
//! already has. It is not a general text editor - no selection, no undo - and
//! deliberately so: everything here is what a query needs and nothing else.

const std = @import("std");

pub const Editor = struct {
    allocator: std.mem.Allocator,
    text: std.ArrayListUnmanaged(u8) = .empty,
    /// A byte offset into `text`, always on a character boundary.
    cursor: usize = 0,
    /// First line on screen, so a long statement can be scrolled.
    scroll: usize = 0,
    /// Where the history was last taken from, so ctrl+p walks back through it.
    history_at: ?usize = null,
    /// The open completion list: candidates, which one is picked, and the word
    /// they would replace.
    candidates: std.ArrayListUnmanaged([]const u8) = .empty,
    candidate_at: usize = 0,
    word_from: usize = 0,
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) Editor {
        return .{ .allocator = allocator, .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *Editor) void {
        self.text.deinit(self.allocator);
        self.candidates.deinit(self.allocator);
        self.arena.deinit();
    }

    pub fn setText(self: *Editor, sql: []const u8) !void {
        self.text.clearRetainingCapacity();
        try self.text.appendSlice(self.allocator, sql);
        self.cursor = self.text.items.len;
        self.closeCompletion();
    }

    // --- editing ---

    pub fn insert(self: *Editor, bytes: []const u8) !void {
        try self.text.insertSlice(self.allocator, self.cursor, bytes);
        self.cursor += bytes.len;
        self.closeCompletion();
    }

    pub fn backspace(self: *Editor) void {
        if (self.cursor == 0) {
            return;
        }
        const from = self.previous(self.cursor);
        self.text.replaceRangeAssumeCapacity(from, self.cursor - from, "");
        self.cursor = from;
        self.closeCompletion();
    }

    pub fn delete(self: *Editor) void {
        if (self.cursor >= self.text.items.len) {
            return;
        }
        const to = self.next(self.cursor);
        self.text.replaceRangeAssumeCapacity(self.cursor, to - self.cursor, "");
        self.closeCompletion();
    }

    /// Remove the word before the cursor, which is what ctrl+w does everywhere.
    pub fn deleteWord(self: *Editor) void {
        var at = self.cursor;
        while (at > 0 and isSpace(self.text.items[at - 1])) : (at -= 1) {}
        while (at > 0 and !isSpace(self.text.items[at - 1])) : (at -= 1) {}
        self.text.replaceRangeAssumeCapacity(at, self.cursor - at, "");
        self.cursor = at;
        self.closeCompletion();
    }

    pub fn clear(self: *Editor) void {
        self.text.clearRetainingCapacity();
        self.cursor = 0;
        self.closeCompletion();
    }

    // --- moving ---

    pub fn left(self: *Editor) void {
        self.cursor = self.previous(self.cursor);
    }

    pub fn right(self: *Editor) void {
        self.cursor = self.next(self.cursor);
    }

    pub fn home(self: *Editor) void {
        self.cursor = self.lineStart(self.cursor);
    }

    pub fn end(self: *Editor) void {
        self.cursor = self.lineEnd(self.cursor);
    }

    /// Up and down keep the column, the way an editor does.
    pub fn up(self: *Editor) void {
        const start = self.lineStart(self.cursor);
        if (start == 0) {
            self.cursor = 0;
            return;
        }
        const column = self.cursor - start;
        const above = self.lineStart(start - 1);
        self.cursor = @min(above + column, start - 1);
    }

    pub fn down(self: *Editor) void {
        const start = self.lineStart(self.cursor);
        const stop = self.lineEnd(self.cursor);
        if (stop >= self.text.items.len) {
            self.cursor = self.text.items.len;
            return;
        }
        const column = self.cursor - start;
        const below = stop + 1;
        self.cursor = @min(below + column, self.lineEnd(below));
    }

    fn previous(self: *Editor, at: usize) usize {
        if (at == 0) {
            return 0;
        }
        var back = at - 1;
        while (back > 0 and self.text.items[back] & 0xc0 == 0x80) : (back -= 1) {}
        return back;
    }

    fn next(self: *Editor, at: usize) usize {
        if (at >= self.text.items.len) {
            return self.text.items.len;
        }
        const len = std.unicode.utf8ByteSequenceLength(self.text.items[at]) catch 1;
        return @min(self.text.items.len, at + len);
    }

    pub fn lineStart(self: *Editor, at: usize) usize {
        if (std.mem.lastIndexOfScalar(u8, self.text.items[0..at], '\n')) |newline| {
            return newline + 1;
        }
        return 0;
    }

    pub fn lineEnd(self: *Editor, at: usize) usize {
        if (std.mem.indexOfScalarPos(u8, self.text.items, at, '\n')) |newline| {
            return newline;
        }
        return self.text.items.len;
    }

    pub fn lineCount(self: *Editor) usize {
        return std.mem.count(u8, self.text.items, "\n") + 1;
    }

    /// The line the cursor is on, and how many bytes into it, for the drawing
    /// code and for scrolling.
    pub fn position(self: *Editor) struct { line: usize, column: usize } {
        const start = self.lineStart(self.cursor);
        return .{
            .line = std.mem.count(u8, self.text.items[0..start], "\n"),
            .column = self.cursor - start,
        };
    }

    pub fn lineAt(self: *Editor, wanted: usize) []const u8 {
        var lines = std.mem.splitScalar(u8, self.text.items, '\n');
        var n: usize = 0;
        while (lines.next()) |line| : (n += 1) {
            if (n == wanted) {
                return line;
            }
        }
        return "";
    }

    // --- completion ---

    pub fn completing(self: *Editor) bool {
        return self.candidates.items.len != 0;
    }

    pub fn closeCompletion(self: *Editor) void {
        self.candidates.clearRetainingCapacity();
        self.candidate_at = 0;
    }

    /// The word being typed, which is what completion works from.
    pub fn word(self: *Editor) []const u8 {
        var at = self.cursor;
        while (at > 0 and isWord(self.text.items[at - 1])) : (at -= 1) {}
        return self.text.items[at..self.cursor];
    }

    /// Offer `names` that carry on the word before the cursor. One candidate is
    /// inserted straight away; several open the list.
    pub fn complete(self: *Editor, names: []const []const u8) !void {
        const prefix = self.word();
        self.word_from = self.cursor - prefix.len;
        self.candidates.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
        const scratch = self.arena.allocator();
        for (names) |name| {
            if (prefix.len != 0 and !std.ascii.startsWithIgnoreCase(name, prefix)) {
                continue;
            }
            if (prefix.len == name.len) {
                continue; // already written in full
            }
            try self.candidates.append(self.allocator, try scratch.dupe(u8, name));
        }
        self.candidate_at = 0;
        if (self.candidates.items.len == 1) {
            try self.take(0);
        }
    }

    /// Put candidate `which` in place of the word being typed.
    pub fn take(self: *Editor, which: usize) !void {
        if (which >= self.candidates.items.len) {
            return;
        }
        const name = self.candidates.items[which];
        const replaced = self.cursor - self.word_from;
        try self.text.replaceRange(self.allocator, self.word_from, replaced, name);
        self.cursor = self.word_from + name.len;
        self.closeCompletion();
    }

    pub fn nextCandidate(self: *Editor, delta: isize) void {
        const count = self.candidates.items.len;
        if (count == 0) {
            return;
        }
        if (delta > 0) {
            self.candidate_at = (self.candidate_at + 1) % count;
        } else {
            self.candidate_at = if (self.candidate_at == 0) count - 1 else self.candidate_at - 1;
        }
    }
};

fn isWord(char: u8) bool {
    return std.ascii.isAlphanumeric(char) or char == '_' or char == '.' or char == '"';
}

fn isSpace(char: u8) bool {
    return char == ' ' or char == '\t' or char == '\n' or char == '\r';
}

// ------------------------------------------------------------- highlighting

pub const Kind = enum { plain, keyword, string, number, comment, punct };

pub const Token = struct {
    kind: Kind,
    from: usize,
    to: usize,
};

/// The words coloured as keywords. Both engines' own words are in here: a
/// keyword that one of them does not know is still a keyword to the reader.
const KEYWORDS = [_][]const u8{
    "ADD",               "ALL",          "ALTER",     "ANALYZE",   "AND",        "AS",           "ASC",
    "AUTOINCREMENT",     "BEGIN",        "BETWEEN",   "BIGINT",    "BLOB",       "BOOLEAN",      "BY",
    "CASCADE",           "CASE",         "CAST",      "CHECK",     "COLLATE",    "COLUMN",       "COMMIT",
    "CONFLICT",          "CONSTRAINT",   "COPY",      "CREATE",    "CROSS",      "CURRENT_DATE", "CURRENT_TIME",
    "CURRENT_TIMESTAMP", "DATABASE",     "DATE",      "DEFAULT",   "DEFERRABLE", "DELETE",       "DESC",
    "DISTINCT",          "DO",           "DOUBLE",    "DROP",      "ELSE",       "END",          "ESCAPE",
    "EXCEPT",            "EXISTS",       "EXPLAIN",   "FALSE",     "FLOAT",      "FOR",          "FOREIGN",
    "FROM",              "FULL",         "GENERATED", "GRANT",     "GROUP",      "HAVING",       "IF",
    "IN",                "INDEX",        "INNER",     "INSERT",    "INT",        "INTEGER",      "INTERSECT",
    "INTERVAL",          "INTO",         "IS",        "JOIN",      "KEY",        "LEFT",         "LIKE",
    "LIMIT",             "MATERIALIZED", "NATURAL",   "NOT",       "NOTHING",    "NOTNULL",      "NULL",
    "NULLS",             "NUMERIC",      "OFFSET",    "ON",        "OR",         "ORDER",        "OUTER",
    "OVER",              "PARTITION",    "PRAGMA",    "PRIMARY",   "REAL",       "REFERENCES",   "REINDEX",
    "RENAME",            "REPLACE",      "RESTRICT",  "RETURNING", "RIGHT",      "ROLLBACK",     "ROW",
    "SAVEPOINT",         "SELECT",       "SEQUENCE",  "SERIAL",    "SET",        "SMALLINT",     "TABLE",
    "TEMPORARY",         "TEXT",         "THEN",      "TIMESTAMP", "TO",         "TRANSACTION",  "TRIGGER",
    "TRUE",              "TRUNCATE",     "UNION",     "UNIQUE",    "UPDATE",     "USING",        "VACUUM",
    "VALUES",            "VARCHAR",      "VIEW",      "WHEN",      "WHERE",      "WINDOW",       "WITH",
    "WITHOUT",
};

pub fn isKeyword(candidate: []const u8) bool {
    for (KEYWORDS) |keyword| {
        if (std.ascii.eqlIgnoreCase(keyword, candidate)) {
            return true;
        }
    }
    return false;
}

/// Every keyword, for completion.
pub fn keywords() []const []const u8 {
    return &KEYWORDS;
}

/// Walks a statement and says what each piece is. Not a parser: it knows
/// strings, comments, numbers, words and punctuation, which is all colouring
/// needs, and it never fails - unterminated anything simply runs to the end.
pub const Tokens = struct {
    sql: []const u8,
    at: usize = 0,

    pub fn next(self: *Tokens) ?Token {
        if (self.at >= self.sql.len) {
            return null;
        }
        const from = self.at;
        const char = self.sql[from];

        // A comment to the end of the line, or a bracketed one.
        if (char == '-' and self.peek(1) == '-') {
            self.at = std.mem.indexOfScalarPos(u8, self.sql, from, '\n') orelse self.sql.len;
            return .{ .kind = .comment, .from = from, .to = self.at };
        }
        if (char == '/' and self.peek(1) == '*') {
            self.at = if (std.mem.indexOfPos(u8, self.sql, from + 2, "*/")) |stop| stop + 2 else self.sql.len;
            return .{ .kind = .comment, .from = from, .to = self.at };
        }
        // A string, with '' for a quote inside it.
        if (char == '\'') {
            self.at = from + 1;
            while (self.at < self.sql.len) : (self.at += 1) {
                if (self.sql[self.at] != '\'') {
                    continue;
                }
                if (self.peek(1) == '\'') {
                    self.at += 1;
                    continue;
                }
                self.at += 1;
                break;
            }
            return .{ .kind = .string, .from = from, .to = self.at };
        }
        // A quoted identifier reads as a name, not as a string.
        if (char == '"' or char == '`') {
            self.at = from + 1;
            while (self.at < self.sql.len and self.sql[self.at] != char) : (self.at += 1) {}
            self.at = @min(self.sql.len, self.at + 1);
            return .{ .kind = .plain, .from = from, .to = self.at };
        }
        if (std.ascii.isDigit(char)) {
            self.at = from;
            while (self.at < self.sql.len and (std.ascii.isDigit(self.sql[self.at]) or self.sql[self.at] == '.')) : (self.at += 1) {}
            return .{ .kind = .number, .from = from, .to = self.at };
        }
        if (std.ascii.isAlphabetic(char) or char == '_') {
            self.at = from;
            while (self.at < self.sql.len and (std.ascii.isAlphanumeric(self.sql[self.at]) or self.sql[self.at] == '_')) : (self.at += 1) {}
            const text = self.sql[from..self.at];
            return .{ .kind = if (isKeyword(text)) .keyword else .plain, .from = from, .to = self.at };
        }
        if (char == ' ' or char == '\t' or char == '\n' or char == '\r') {
            self.at = from;
            while (self.at < self.sql.len and isSpace(self.sql[self.at])) : (self.at += 1) {}
            return .{ .kind = .plain, .from = from, .to = self.at };
        }
        // Anything else - an operator, a comma, a bracket - one piece at a time.
        self.at = from + 1;
        return .{ .kind = .punct, .from = from, .to = self.at };
    }

    fn peek(self: *Tokens, ahead: usize) u8 {
        return if (self.at + ahead < self.sql.len) self.sql[self.at + ahead] else 0;
    }
};

/// What kind each byte of `sql` belongs to, so a line can be drawn a run at a
/// time. `out` must be as long as `sql`.
pub fn kinds(sql: []const u8, out: []Kind) void {
    @memset(out[0..@min(out.len, sql.len)], .plain);
    var tokens = Tokens{ .sql = sql };
    while (tokens.next()) |token| {
        var at = token.from;
        while (at < token.to and at < out.len) : (at += 1) {
            out[at] = token.kind;
        }
    }
}

test "the tokenizer tells the pieces of a statement apart" {
    var tokens = Tokens{ .sql = "SELECT 'it''s', 42 -- why\nFROM t" };
    const wanted = [_]Kind{ .keyword, .plain, .string, .punct, .plain, .number, .plain, .comment, .plain, .keyword, .plain, .plain };
    var seen: usize = 0;
    while (tokens.next()) |token| : (seen += 1) {
        try std.testing.expectEqual(wanted[seen], token.kind);
    }
    try std.testing.expectEqual(wanted.len, seen);
}

test "a string that is never closed does not run away" {
    var tokens = Tokens{ .sql = "select 'open" };
    _ = tokens.next();
    _ = tokens.next();
    const last = tokens.next().?;
    try std.testing.expectEqual(Kind.string, last.kind);
    try std.testing.expectEqual(@as(usize, 12), last.to);
    try std.testing.expect(tokens.next() == null);
}

test "the cursor moves through lines and keeps its column" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.setText("select 1\nfrom t\nwhere x");
    try std.testing.expectEqual(@as(usize, 3), editor.lineCount());

    editor.home();
    try std.testing.expectEqual(@as(usize, 2), editor.position().line);
    editor.right();
    editor.right();
    try std.testing.expectEqual(@as(usize, 2), editor.position().column);
    editor.up();
    try std.testing.expectEqual(@as(usize, 1), editor.position().line);
    try std.testing.expectEqual(@as(usize, 2), editor.position().column);
    // The line above is shorter than the column asked for, so it stops at its end.
    editor.up();
    try std.testing.expectEqual(@as(usize, 0), editor.position().line);
    editor.end();
    try std.testing.expectEqualStrings("select 1", editor.lineAt(0));
}

test "one candidate is taken, several are offered" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.setText("select * from auth");
    try editor.complete(&[_][]const u8{ "authors", "books" });
    try std.testing.expectEqualStrings("select * from authors", editor.text.items);
    try std.testing.expect(!editor.completing());

    try editor.setText("select * from b");
    try editor.complete(&[_][]const u8{ "books", "book_list", "authors" });
    try std.testing.expect(editor.completing());
    try std.testing.expectEqual(@as(usize, 2), editor.candidates.items.len);
    editor.nextCandidate(1);
    try editor.take(editor.candidate_at);
    try std.testing.expectEqualStrings("select * from book_list", editor.text.items);
}

test "deleting a word stops at the space before it" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.setText("select count(*) from books");
    editor.deleteWord();
    try std.testing.expectEqualStrings("select count(*) from ", editor.text.items);
}

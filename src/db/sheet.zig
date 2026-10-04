//! A delimited file, opened as a database.
//!
//! A CSV holds one table and nothing that can be asked a question, so it is read
//! into a SQLite database in memory - one table, named after the file - and from
//! there on it is the SQLite driver's. SQL, the filter, sorting, the row form and
//! the alter form all work, because nothing above the driver can tell the
//! difference.
//!
//! What is here is the two ends of that: reading the file in and writing it
//! back. Both are held to one rule, which is that **a file nobody changed is a
//! file nobody wrote**:
//!
//! - A column is a number only when every value in it reads as one and writes
//!   back as the same bytes. `007` and `1e5` are text, and stay what the file
//!   said. A column of prices - `1.50`, `10.00`, always two digits - is a
//!   `DECIMAL(15,2)`, and that type is what remembers to write the two digits.
//! - The file is written when what the table would write is not what it wrote
//!   last. Looking, a statement that was rolled back, an index and an update
//!   that changed nothing leave it alone.
//! - It is written in the dialect it was read in: the separator, the line
//!   ending, the byte order mark, whether the last line ends, and the header as
//!   it stood. The one thing not kept is quoting nobody needed - a field is
//!   quoted when it has to be.
//! - It is written beside itself and renamed into place, so a write that fails
//!   half way leaves the file as it was, and it is not written at all over one
//!   that changed on disk since it was read.

const std = @import("std");
const builtin = @import("builtin");
const db = @import("db.zig");
const csv = @import("csv.zig");
const c = @import("sqlite");

const List = db.List;

const BOM = "\xEF\xBB\xBF";

/// Whether a target is one of these. Said by the name and nothing else: a
/// SQLite file is whatever nobody claims, so there is no asking the file.
pub fn claims(target: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(target, ".csv") or tabbed(target);
}

fn tabbed(target: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(target, ".tsv");
}

/// A column as the file named it and as the table does. They differ where the
/// file's name could not be a column's: no name at all, one a column before it
/// already has, or spaces round it. Kept so that a header nobody renamed goes
/// back as it came.
const Header = struct {
    name: []const u8,
    wrote: []const u8,
};

/// What is known about a file without reading it.
const Facts = struct {
    size: u64,
    seconds: i64,
    nanos: i64,
    mode: u32,
    dir: bool,

    fn same(self: Facts, other: Facts) bool {
        return self.size == other.size and self.seconds == other.seconds and self.nanos == other.nanos;
    }
};

pub const Sheet = struct {
    allocator: std.mem.Allocator,
    /// What lives as long as the file is open: its path, the table's name, the
    /// header as it was written.
    arena: std.heap.ArenaAllocator,
    /// The file itself, with any link on the way to it followed: what is renamed
    /// into place must land on the file and not on a link to it.
    path: [:0]const u8 = "",
    table: []const u8 = "",
    separator: u8 = ',',
    /// What stands before the fraction of a number: a point, or the comma that
    /// a file separated by semicolons is separated by semicolons to make room
    /// for.
    mark: u8 = '.',
    ending: []const u8 = "\n",
    bom: bool = false,
    /// Whether the last line ends, which a file is free not to do.
    final_newline: bool = true,
    headers: []const Header = &.{},
    /// What the table wrote as when it and the file last agreed.
    written: u64 = 0,
    /// Where the connection's count of changed rows and the schema's version
    /// stood when that was last looked at. Both unmoved means nothing can have
    /// changed, which is what makes looking cheap enough to do after every
    /// statement.
    changes: c_int = 0,
    cookie: i64 = 0,
    /// The file as it was when last read or written, to tell when somebody else
    /// has written it since.
    seen: ?Facts = null,
    /// The table says something the file does not, because the last attempt to
    /// write it failed. Closing tries once more.
    behind: bool = false,

    /// Read the file into `handle`, which is an empty database. What went wrong
    /// is in `report` when it fails.
    pub fn open(allocator: std.mem.Allocator, handle: ?*c.Db, target: []const u8, report: *List) !*Sheet {
        const self = try allocator.create(Sheet);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .arena = .init(allocator) };
        errdefer self.arena.deinit();
        const keep = self.arena.allocator();

        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        const a = scratch.allocator();

        self.path = try resolve(keep, target);
        const found = facts(self.path) orelse {
            try report.print(allocator, "{s}: {s}", .{ target, describe() });
            return error.Driver;
        };
        if (found.dir) {
            try report.print(allocator, "{s} is a directory", .{target});
            return error.Driver;
        }
        var body: []const u8 = csv.readFile(a, self.path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try report.print(allocator, "cannot read {s}: {s}", .{ target, describe() });
                return error.Driver;
            },
        };
        if (std.mem.startsWith(u8, body, BOM)) {
            self.bom = true;
            body = body[BOM.len..];
        } else if (std.mem.startsWith(u8, body, "\xFF\xFE") or std.mem.startsWith(u8, body, "\xFE\xFF")) {
            // What a spreadsheet calls "Unicode text". Read as bytes it is a NUL
            // after every letter, and a table of those helps nobody.
            try report.print(allocator, "{s} is UTF-16, which is not read here: save it as UTF-8", .{target});
            return error.Driver;
        }
        self.final_newline = body.len != 0 and (body[body.len - 1] == '\n' or body[body.len - 1] == '\r');
        self.separator = if (tabbed(target)) '\t' else csv.sniff(body);
        self.table = try keep.dupe(u8, tableName(target));

        // Twice through the file: once to find out what each column holds, and
        // once to put the rows in. A column's type has to be known before its
        // first row is written, and holding every row in between would be the
        // file in memory a second time.
        var reader = csv.Reader{ .body = body, .separator = self.separator };
        var fields: std.ArrayList(csv.Field) = .empty;
        var wrote: std.ArrayList([]const u8) = .empty;
        while (try reader.next(a, &fields)) {
            if (blank(fields.items)) {
                continue;
            }
            for (fields.items) |field| {
                try wrote.append(a, try keep.dupe(u8, field.text));
            }
            break;
        }
        if (wrote.items.len == 0) {
            try report.print(allocator, "{s} is empty: its first line has to name the columns", .{target});
            return error.Driver;
        }
        if (reader.ending.len != 0) {
            // A slice of the file, which is about to go; one of three it can be.
            self.ending = if (reader.ending.len == 2) "\r\n" else if (reader.ending[0] == '\r') "\r" else "\n";
        }
        const rows_from = reader.at;

        var seen: std.ArrayList(Seen) = .empty;
        try seen.appendNTimes(a, .{}, wrote.items.len);
        while (try reader.next(a, &fields)) {
            if (blank(fields.items)) {
                continue;
            }
            // A row longer than the header has columns the header did not name.
            // They are columns all the same: dropping what a file holds because
            // its first line is short would be this deciding what matters in it.
            if (fields.items.len > seen.items.len) {
                try seen.appendNTimes(a, .{}, fields.items.len - seen.items.len);
            }
            for (fields.items, 0..) |field, at| {
                seen.items[at].see(field.text);
            }
        }
        self.headers = try named(keep, wrote.items, seen.items.len);
        // One decimal mark for the whole file. A comma only where every column
        // with a fraction in it has one, and only where the comma is not what
        // separates the fields: a file that mixes the two is read the plain way
        // and its comma columns stay the text they are.
        var points = false;
        var commas = false;
        for (seen.items) |column| {
            points = points or column.fraction(0);
            commas = commas or column.fraction(1);
        }
        self.mark = if (commas and !points and self.separator != ',') ',' else '.';
        const reading: usize = @intFromBool(self.mark == ',');

        var sql: List = .empty;
        try sql.appendSlice(a, "CREATE TABLE ");
        try db.quoteName(&sql, a, self.table);
        try sql.appendSlice(a, " (");
        for (self.headers, seen.items, 0..) |header, column, at| {
            if (at != 0) {
                try sql.appendSlice(a, ", ");
            }
            try db.quoteName(&sql, a, header.name);
            try sql.append(a, ' ');
            try column.declare(&sql, a, reading);
        }
        try sql.appendSlice(a, ");\nBEGIN");
        try run(handle, allocator, sql.items, target, report);

        sql.clearRetainingCapacity();
        try sql.appendSlice(a, "INSERT INTO ");
        try db.quoteName(&sql, a, self.table);
        try sql.appendSlice(a, " VALUES (");
        for (0..self.headers.len) |at| {
            try sql.appendSlice(a, if (at == 0) "?" else ",?");
        }
        try sql.append(a, ')');
        var insert: ?*c.Stmt = null;
        var tail: ?[*]const u8 = null;
        if (c.sqlite3_prepare_v2(handle, sql.items.ptr, @intCast(sql.items.len), &insert, &tail) != c.OK) {
            try report.print(allocator, "{s}: {s}", .{ target, std.mem.span(c.sqlite3_errmsg(handle)) });
            return error.Driver;
        }
        defer _ = c.sqlite3_finalize(insert);

        reader.at = rows_from;
        while (try reader.next(a, &fields)) {
            if (blank(fields.items)) {
                continue;
            }
            for (seen.items, 0..) |column, at| {
                const slot: c_int = @intCast(at + 1);
                if (at >= fields.items.len or fields.items[at].absent()) {
                    _ = c.sqlite3_bind_null(insert, slot);
                    continue;
                }
                const text = fields.items[at].text;
                // The number this already proved to write back as itself, so
                // what goes in is what Zig read and not what SQLite would make
                // of the same digits.
                if (column.values != 0 and column.whole) {
                    if (whole(text)) |value| {
                        _ = c.sqlite3_bind_int64(insert, slot, value);
                        continue;
                    }
                } else if (column.fraction(reading)) {
                    if (number(text, self.mark, column.digitsFor(reading))) |value| {
                        _ = c.sqlite3_bind_double(insert, slot, value);
                        continue;
                    }
                }
                // Read by the step below and not after it, so nothing is copied.
                // An empty slice has no address worth passing, and passing none
                // binds NULL - which an empty text is not.
                const bytes: [*]const u8 = if (text.len != 0) text.ptr else "";
                _ = c.sqlite3_bind_text(insert, slot, bytes, @intCast(text.len), null);
            }
            if (c.sqlite3_step(insert) != c.DONE) {
                try report.print(allocator, "{s}: {s}", .{ target, std.mem.span(c.sqlite3_errmsg(handle)) });
                return error.Driver;
            }
            _ = c.sqlite3_reset(insert);
        }
        try run(handle, allocator, "COMMIT", target, report);

        // Where things stand now is what "unchanged" means from here on.
        self.changes = c.sqlite3_total_changes(handle);
        self.cookie = cookieOf(handle);
        var out: List = .empty;
        defer out.deinit(allocator);
        self.render(handle, &out) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try report.print(allocator, "{s}: {s}", .{ target, std.mem.span(c.sqlite3_errmsg(handle)) });
                return error.Driver;
            },
        };
        self.written = std.hash.Wyhash.hash(0, out.items);
        self.seen = found;
        return self;
    }

    pub fn close(self: *Sheet) void {
        const allocator = self.allocator;
        self.arena.deinit();
        allocator.destroy(self);
    }

    /// Write the file if the table no longer says what the file does. Called by
    /// the driver after every statement; `failure` gets the reason when the file
    /// could not be written, which is an error of the statement that changed it
    /// - the row is changed in memory and nowhere else, and saying nothing would
    /// be saying it was saved. `closing` is the last call there will be.
    pub fn settle(self: *Sheet, handle: ?*c.Db, failure: *List, closing: bool) db.Error!void {
        // A transaction is written when it is committed, and one that is rolled
        // back was never the file's business.
        if (c.sqlite3_get_autocommit(handle) == 0) {
            return;
        }
        const changes = c.sqlite3_total_changes(handle);
        const cookie = cookieOf(handle);
        if (changes == self.changes and cookie == self.cookie and !(closing and self.behind)) {
            return;
        }
        // Moved on whether or not the write below works: a file that cannot be
        // written is complained about by the statement that changed it, not by
        // every statement after it. The next change tries again, and so does
        // closing the file - whatever stood in the way may be gone by then.
        self.changes = changes;
        self.cookie = cookie;
        self.behind = true;

        var out: List = .empty;
        defer out.deinit(self.allocator);
        self.render(handle, &out) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Gone => return blame(failure, self.allocator, "{s} is written from the table {s}, and there is none now: the file is as it was", .{ self.path, self.table }),
            error.Driver => return blame(failure, self.allocator, "cannot read {s} back to write it: {s}", .{ self.table, std.mem.span(c.sqlite3_errmsg(handle)) }),
        };
        const hash = std.hash.Wyhash.hash(0, out.items);
        if (hash == self.written) {
            self.behind = false;
            return;
        }
        const now = facts(self.path);
        if (now != null and self.seen != null and !now.?.same(self.seen.?)) {
            return blame(failure, self.allocator, "{s} has changed on disk since it was read, so it is not written over: open it again", .{self.path});
        }
        const code = self.write(out.items, now);
        if (code != 0) {
            return blame(failure, self.allocator, "cannot write {s}: {s}", .{ self.path, std.mem.sliceTo(strerror(code), 0) });
        }
        self.written = hash;
        self.seen = facts(self.path);
        self.behind = false;
    }

    /// The table as the file it came from: the header, then every row in the
    /// order of the file.
    fn render(self: *Sheet, handle: ?*c.Db, out: *List) error{ OutOfMemory, Gone, Driver }!void {
        const a = self.allocator;
        var sql: List = .empty;
        defer sql.deinit(a);
        try sql.appendSlice(a, "SELECT * FROM ");
        try db.quoteName(&sql, a, self.table);
        const unordered = sql.items.len;
        // The rowid is the order the rows went in, and a new one goes on the end.
        try sql.appendSlice(a, " ORDER BY rowid");
        var stmt: ?*c.Stmt = null;
        var tail: ?[*]const u8 = null;
        if (c.sqlite3_prepare_v2(handle, sql.items.ptr, @intCast(sql.items.len), &stmt, &tail) != c.OK) {
            // A table somebody rebuilt WITHOUT ROWID has no such column, and is
            // already kept in the order of its key.
            if (c.sqlite3_prepare_v2(handle, sql.items.ptr, @intCast(unordered), &stmt, &tail) != c.OK) {
                return error.Gone;
            }
        }
        defer _ = c.sqlite3_finalize(stmt);

        if (self.bom) {
            try out.appendSlice(a, BOM);
        }
        const columns: usize = @intCast(c.sqlite3_column_count(stmt));
        // How many digits each column writes after the mark, where its type
        // says: the type is the one thing about a column that a rename and a
        // rebuild both carry along.
        const scales = try a.alloc(?usize, columns);
        defer a.free(scales);
        for (0..columns) |at| {
            if (at != 0) {
                try out.append(a, self.separator);
            }
            const name = std.mem.span(c.sqlite3_column_name(stmt, @intCast(at)) orelse "");
            const wrote = self.wroteAs(name);
            if (columns == 1 and wrote.len == 0) {
                // The one header that cannot go back as nothing, for the reason
                // a row of one column cannot: a blank line is not a line.
                try out.appendSlice(a, "\"\"");
            } else {
                try csv.writeField(out, a, wrote, self.separator);
            }
            scales[at] = scaleOf(std.mem.span(c.sqlite3_column_decltype(stmt, @intCast(at)) orelse ""));
        }
        var spelled: [NUMBER_SIZE]u8 = undefined;
        while (true) {
            switch (c.sqlite3_step(stmt)) {
                c.ROW => {},
                c.DONE => break,
                else => return error.Driver,
            }
            try out.appendSlice(a, self.ending);
            for (0..columns) |at| {
                if (at != 0) {
                    try out.append(a, self.separator);
                }
                const index: c_int = @intCast(at);
                switch (c.sqlite3_column_type(stmt, index)) {
                    // Nothing, which is what read as no value on the way in. The
                    // one place that cannot be written is a table of a single
                    // column: a line with nothing on it is a blank line, and a
                    // blank line is not a row.
                    c.NULL => if (columns == 1) {
                        try out.appendSlice(a, "\"\"");
                    },
                    c.INTEGER => {
                        try out.print(a, "{d}", .{c.sqlite3_column_int64(stmt, index)});
                        // A whole number among prices is kept as one, and is
                        // still written the way the column writes them.
                        if (scales[at]) |digits| {
                            try out.append(a, self.mark);
                            try out.appendNTimes(a, '0', digits);
                        }
                    },
                    c.FLOAT => try out.appendSlice(a, written(&spelled, c.sqlite3_column_double(stmt, index), self.mark, scales[at])),
                    else => |kind| {
                        const start = if (kind == c.BLOB) c.sqlite3_column_blob(stmt, index) else c.sqlite3_column_text(stmt, index);
                        const len: usize = @intCast(c.sqlite3_column_bytes(stmt, index));
                        if (len == 0 or start == null) {
                            // An empty text, told apart from no value at all.
                            try out.appendSlice(a, "\"\"");
                        } else {
                            try csv.writeField(out, a, start.?[0..len], self.separator);
                        }
                    },
                }
            }
        }
        if (self.final_newline) {
            try out.appendSlice(a, self.ending);
        }
    }

    /// What the file called this column, where the table's name for it is one
    /// this made up; the name itself everywhere else, which is what a column
    /// somebody renamed or added goes out as.
    fn wroteAs(self: *Sheet, name: []const u8) []const u8 {
        for (self.headers) |header| {
            if (std.mem.eql(u8, header.name, name)) {
                return header.wrote;
            }
        }
        return name;
    }

    /// The bytes, into the file. Zero, or what the system said was wrong.
    fn write(self: *Sheet, bytes: []const u8, there: ?Facts) c_int {
        // Renaming over a file takes the right to write in its directory and
        // none to write the file - so a file marked read-only would be replaced
        // without anybody having been allowed to. Asked first, then.
        if (there != null and std.c.access(self.path, std.c.W_OK) != 0) {
            return std.c._errno().*;
        }
        var buffer: [std.Io.Dir.max_path_bytes + 16]u8 = undefined;
        const beside = std.mem.printSentinel(&buffer, "{s}.krtek-tmp", .{self.path}, 0) catch return @backingInt(std.c.E.NAMETOOLONG);
        const file = std.c.fopen(beside, "wb") orelse {
            // No room beside it - a directory that may not be written in, with a
            // file in it that may. Over the top of the file, then, which is how
            // everything else here writes one.
            const over = std.c.fopen(self.path, "wb") orelse return std.c._errno().*;
            return put(over, bytes);
        };
        var code = put(file, bytes);
        if (code == 0) {
            // A new file gets what the umask allows, and the one it replaces may
            // have been somebody's private one.
            if (there) |old| {
                _ = std.c.chmod(beside, @intCast(old.mode & 0o7777));
            }
            if (std.c.rename(beside, self.path) != 0) {
                code = std.c._errno().*;
            }
        }
        if (code != 0) {
            _ = std.c.unlink(beside);
        }
        return code;
    }

    /// What the info screen says about the file, in place of the pragmas of a
    /// database that is only there to hold it.
    pub fn settings(self: *Sheet, arena: std.mem.Allocator) db.Error![]db.Setting {
        var list: std.ArrayList(db.Setting) = .empty;
        try list.append(arena, .{ .label = "file", .value = self.path });
        if (facts(self.path)) |now| {
            try list.append(arena, .{ .label = "size", .value = try arena.print("{d} bytes", .{now.size}) });
        }
        try list.append(arena, .{ .label = "table", .value = self.table });
        try list.append(arena, .{ .label = "separator", .value = switch (self.separator) {
            ',' => "comma",
            ';' => "semicolon",
            '\t' => "tab",
            else => "|",
        } });
        try list.append(arena, .{ .label = "decimal mark", .value = if (self.mark == ',') "comma" else "point" });
        try list.append(arena, .{ .label = "line ending", .value = if (self.ending.len == 2) "CRLF" else if (self.ending[0] == '\r') "CR" else "LF" });
        try list.append(arena, .{ .label = "byte order mark", .value = if (self.bom) "yes" else "no" });
        try list.append(arena, .{ .label = "written", .value = "when a row or a column changes" });
        return list.items;
    }
};

/// The two ways a fraction is written, and what index each has below.
const MARKS = [_]u8{ '.', ',' };

/// Room for any number a double can be, written out in full.
const NUMBER_SIZE = std.fmt.float.bufferSize(.decimal, f64);

/// The most digits after the mark a column is taken to always have. Far more
/// than a double holds; what matters is that reading a file and writing it
/// agree on the number, or a column typed on the way in is not on the way out.
const MAX_DIGITS = 30;

/// What one column held, read off every row before the table is made.
const Seen = struct {
    values: usize = 0,
    whole: bool = true,
    /// For each decimal mark, whether every value is a number written the
    /// shortest way it can be: `0.5`, `3.14`, `-2`.
    shortest: [2]bool = .{ true, true },
    /// And whether every value has the same count of digits after the mark,
    /// the way prices do: `1.50`, `10.00`.
    fixed: [2]bool = .{ true, true },
    digits: [2]usize = .{ 0, 0 },

    fn see(self: *Seen, text: []const u8) void {
        if (text.len == 0) {
            return;
        }
        self.values += 1;
        if (self.whole and whole(text) == null) {
            self.whole = false;
        }
        for (MARKS, 0..) |mark, reading| {
            if (self.shortest[reading] and number(text, mark, null) == null) {
                self.shortest[reading] = false;
            }
            if (!self.fixed[reading]) {
                continue;
            }
            const after = if (std.mem.findScalar(u8, text, mark)) |at| text.len - at - 1 else 0;
            if (self.values == 1) {
                self.digits[reading] = after;
            }
            if (after == 0 or after > MAX_DIGITS or after != self.digits[reading] or number(text, mark, after) == null) {
                self.fixed[reading] = false;
            }
        }
    }

    /// Whether this is a column of numbers with fractions, read with that mark.
    fn fraction(self: Seen, reading: usize) bool {
        return self.values != 0 and !self.whole and (self.shortest[reading] or self.fixed[reading]);
    }

    /// How many digits its numbers have after the mark, or null where each has
    /// as many as it needs.
    fn digitsFor(self: Seen, reading: usize) ?usize {
        return if (self.shortest[reading]) null else self.digits[reading];
    }

    /// The type the column is made with. A column with nothing in it is text:
    /// there is nothing to say otherwise.
    fn declare(self: Seen, out: *List, a: std.mem.Allocator, reading: usize) !void {
        if (self.values != 0 and self.whole) {
            try out.appendSlice(a, "INTEGER");
        } else if (!self.fraction(reading)) {
            try out.appendSlice(a, "TEXT");
        } else if (self.digitsFor(reading)) |digits| {
            // Fifteen digits is what a double holds exactly; the second number
            // is the one that matters, and is read back by `scaleOf`.
            try out.print(a, "DECIMAL(15,{d})", .{digits});
        } else {
            try out.appendSlice(a, "REAL");
        }
    }
};

/// The whole number this is, if writing it down again gives these bytes.
/// `007`, `+7` and `1_000` all read as numbers and none of them comes back.
fn whole(text: []const u8) ?i64 {
    if (text.len > 20) {
        return null;
    }
    const value = std.fmt.parseInt(i64, text, 10) catch return null;
    var buffer: [24]u8 = undefined;
    const again = std.mem.print(&buffer, "{d}", .{value}) catch return null;
    return if (std.mem.eql(u8, again, text)) value else null;
}

/// The same for a number with a fraction, written with `mark` and with
/// `digits` after it - or, with none given, as many as it takes. `3.14` is one
/// either way round; `1.50` is one with two digits and not without; `1e5`,
/// `.5` and `1.` are text, because nothing here would write them back.
fn number(text: []const u8, mark: u8, digits: ?usize) ?f64 {
    var plain: [40]u8 = undefined;
    if (text.len == 0 or text.len > plain.len) {
        return null;
    }
    for (text, 0..) |char, at| {
        plain[at] = switch (char) {
            // Digits and what goes between them. Without this `nan`, `inf` and
            // `0x1p3` all read as numbers too.
            '0'...'9', '-' => char,
            else => if (char == mark) '.' else return null,
        };
    }
    const value = std.fmt.parseFloat(f64, plain[0..text.len]) catch return null;
    var buffer: [NUMBER_SIZE]u8 = undefined;
    const again = spell(&buffer, value, mark, digits) orelse return null;
    return if (std.mem.eql(u8, again, text)) value else null;
}

/// A number the way this file writes one, or null where it does not fit.
fn spell(buffer: []u8, value: f64, mark: u8, digits: ?usize) ?[]const u8 {
    const text = std.fmt.float.render(buffer, value, .{ .mode = .decimal, .precision = digits }) catch return null;
    if (mark != '.') {
        if (std.mem.findScalar(u8, text, '.')) |at| {
            @constCast(text)[at] = mark;
        }
    }
    return text;
}

/// A number on its way back to the file: with the column's count of digits
/// where that says exactly this number, and in full where it would not. `1.5`
/// in a column of prices is `1.50`; `1.234` there is `1.234`, because rounding
/// what somebody typed is not something writing a file gets to do.
fn written(buffer: []u8, value: f64, mark: u8, digits: ?usize) []const u8 {
    if (digits) |count| {
        if (spell(buffer, value, '.', count)) |text| {
            const back = std.fmt.parseFloat(f64, text) catch std.math.nan(f64);
            if (back == value) {
                return spell(buffer, value, mark, count) orelse text;
            }
        }
    }
    return spell(buffer, value, mark, null) orelse "";
}

/// The count of digits a declared type asks for after the mark: the `2` of
/// `DECIMAL(15,2)`, however the type before the bracket is spelled. Null where
/// the type says nothing of the kind, or says something no number is written
/// with.
fn scaleOf(declared: []const u8) ?usize {
    const open = std.mem.findScalar(u8, declared, '(') orelse return null;
    const close = std.mem.findScalarLast(u8, declared, ')') orelse return null;
    if (close < open) {
        return null;
    }
    const inside = declared[open + 1 .. close];
    const comma = std.mem.findScalar(u8, inside, ',') orelse return null;
    const digits = std.fmt.parseInt(usize, std.mem.trim(u8, inside[comma + 1 ..], " "), 10) catch return null;
    return if (digits == 0 or digits > MAX_DIGITS) null else digits;
}

/// A line with nothing on it, which every reader of these files skips.
fn blank(fields: []const csv.Field) bool {
    return fields.len == 1 and fields[0].absent();
}

/// A name for every column: the header's where it gave one that can be used,
/// and one that says where the column is where it did not.
fn named(keep: std.mem.Allocator, wrote: []const []const u8, count: usize) ![]const Header {
    const headers = try keep.alloc(Header, count);
    for (headers, 0..) |*header, at| {
        const text = if (at < wrote.len) wrote[at] else "";
        var name = std.mem.trim(u8, text, " \t");
        if (name.len == 0) {
            name = try keep.print("column_{d}", .{at + 1});
        }
        // SQLite does not tell `Name` from `name`, so neither can this. And a
        // column called `rowid` would take that name away from the thing it
        // stands for: the row's own number, which is what a row is edited by
        // and what keeps the rows in the order of the file.
        var suffix: usize = 2;
        const base = name;
        while (taken(headers[0..at], name) or hidesRowId(name)) : (suffix += 1) {
            name = try keep.print("{s}_{d}", .{ base, suffix });
        }
        header.* = .{ .name = name, .wrote = text };
    }
    return headers;
}

/// The three names SQLite answers to for a row's own number. A column with
/// one of them is that name from then on, and the number is out of reach.
fn hidesRowId(name: []const u8) bool {
    for ([_][]const u8{ "rowid", "_rowid_", "oid" }) |reserved| {
        if (std.ascii.eqlIgnoreCase(name, reserved)) {
            return true;
        }
    }
    return false;
}

fn taken(headers: []const Header, name: []const u8) bool {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) {
            return true;
        }
    }
    return false;
}

/// What the table is called: the file's name without the directory in front
/// and the extension behind.
fn tableName(target: []const u8) []const u8 {
    const slash = std.mem.findScalarLast(u8, target, '/');
    const file = if (slash) |at| target[at + 1 ..] else target;
    // Four off the end is the extension, which is what made this a sheet.
    const stem = file[0..file.len -| 4];
    // SQLite keeps names that start like this for itself, and a file may be
    // called anything.
    if (stem.len == 0 or std.ascii.startsWithIgnoreCase(stem, "sqlite_")) {
        return "csv";
    }
    return stem;
}

/// The schema's version, which SQLite moves on every time the schema changes:
/// a column renamed or dropped changes no row, and is a change to the file.
fn cookieOf(handle: ?*c.Db) i64 {
    const sql = "PRAGMA schema_version";
    var stmt: ?*c.Stmt = null;
    var tail: ?[*]const u8 = null;
    if (c.sqlite3_prepare_v2(handle, sql, sql.len, &stmt, &tail) != c.OK) {
        return 0;
    }
    defer _ = c.sqlite3_finalize(stmt);
    return if (c.sqlite3_step(stmt) == c.ROW) c.sqlite3_column_int64(stmt, 0) else 0;
}

fn run(handle: ?*c.Db, allocator: std.mem.Allocator, sql: []const u8, target: []const u8, report: *List) !void {
    const zero = try allocator.dupeSentinel(u8, sql, 0);
    defer allocator.free(zero);
    if (c.sqlite3_exec(handle, zero.ptr, null, null, null) != c.OK) {
        try report.print(allocator, "{s}: {s}", .{ target, std.mem.span(c.sqlite3_errmsg(handle)) });
        return error.Driver;
    }
}

/// Say why, and fail: the two always go together here.
fn blame(failure: *List, allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) db.Error {
    failure.clearRetainingCapacity();
    failure.print(allocator, fmt, args) catch return error.OutOfMemory;
    return error.Driver;
}

/// The path with every link in it followed, or as it came where it cannot be
/// - the file is not there, and saying so is the next thing that happens.
fn resolve(keep: std.mem.Allocator, target: []const u8) ![:0]const u8 {
    const given = try keep.dupeSentinel(u8, target, 0);
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const real_path = std.c.realpath(given.ptr, &buffer) orelse return given;
    return keep.dupeSentinel(u8, std.mem.span(real_path), 0);
}

/// All of it, and on the disk before this says so: what is renamed over the
/// file has to be whole. Zero, or what the system said.
fn put(file: *std.c.FILE, bytes: []const u8) c_int {
    var code: c_int = 0;
    if (bytes.len != 0 and std.c.fwrite(bytes.ptr, 1, bytes.len, file) != bytes.len) {
        code = std.c._errno().*;
    }
    if (code == 0 and fflush(file) != 0) {
        code = std.c._errno().*;
    }
    // Asked for and not insisted on: a filesystem that cannot do it - some
    // network mounts, some FUSE ones - says so with an error, and the bytes are
    // written all the same.
    if (code == 0) {
        _ = std.c.fsync(fileno(file));
    }
    if (std.c.fclose(file) != 0 and code == 0) {
        code = std.c._errno().*;
    }
    return code;
}

/// The same question `store.zig` asks, and the same two ways of asking it: this
/// Zig routes Linux to `statx` and leaves `fstatat` undefined there.
fn facts(path: [*:0]const u8) ?Facts {
    if (builtin.target.os.tag == .linux) {
        const linux = std.os.linux;
        var found: linux.Statx = undefined;
        const rc = linux.statx(linux.AT.FDCWD, path, 0, .{
            .TYPE = true,
            .MODE = true,
            .SIZE = true,
            .MTIME = true,
        }, &found);
        if (@as(isize, @bitCast(rc)) < 0) {
            return null;
        }
        return .{
            .size = found.size,
            .seconds = found.mtime.sec,
            .nanos = found.mtime.nsec,
            .mode = found.mode,
            .dir = found.mode & linux.S.IFMT == linux.S.IFDIR,
        };
    }
    var found: std.c.Stat = undefined;
    if (std.c.fstatat(std.c.AT.FDCWD, path, &found, 0) != 0) {
        return null;
    }
    return .{
        .size = @intCast(@max(found.size, 0)),
        .seconds = found.mtime().sec,
        .nanos = found.mtime().nsec,
        .mode = found.mode,
        .dir = found.mode & std.c.S.IFMT == std.c.S.IFDIR,
    };
}

extern fn strerror(code: c_int) [*:0]const u8;
extern fn fflush(file: *std.c.FILE) c_int;
extern fn fileno(file: *std.c.FILE) c_int;

fn describe() []const u8 {
    return std.mem.sliceTo(strerror(std.c._errno().*), 0);
}

// ------------------------------------------------------------------- tests
//
// Through the driver, because that is the only way any of this is reached: a
// file is opened, statements are run, and what matters is what is in the file
// afterwards.

const testing = std.testing;
const sqlite = @import("sqlite.zig");

/// A directory of its own to put files in, and the driver over one of them.
const Bench = struct {
    arena: std.heap.ArenaAllocator,
    dir: [:0]const u8 = "",
    report: List = .empty,

    fn init() !Bench {
        var self = Bench{ .arena = .init(testing.allocator) };
        self.dir = try self.arena.allocator().printSentinel("/tmp/krtek-sheet-test-{d}", .{db.clock.steadyNanos()}, 0);
        try testing.expectEqual(@as(c_int, 0), std.c.mkdir(self.dir, 0o755));
        return self;
    }

    fn deinit(self: *Bench) void {
        // Whatever a test left in there. A directory inside it is not expected.
        var buffer: [512]u8 = undefined;
        const command = std.mem.printSentinel(&buffer, "rm -rf '{s}'", .{self.dir}, 0) catch unreachable;
        _ = system(command);
        self.report.deinit(testing.allocator);
        self.arena.deinit();
    }

    fn path(self: *Bench, name: []const u8) ![:0]const u8 {
        return self.arena.allocator().printSentinel("{s}/{s}", .{ self.dir, name }, 0);
    }

    /// A file with these bytes in it, and where it is.
    fn file(self: *Bench, name: []const u8, bytes: []const u8) ![:0]const u8 {
        const where = try self.path(name);
        const out = std.c.fopen(where, "wb") orelse return error.CannotCreate;
        try testing.expectEqual(@as(c_int, 0), put(out, bytes));
        return where;
    }

    fn read(self: *Bench, where: []const u8) ![]const u8 {
        return csv.readFile(self.arena.allocator(), where);
    }

    fn open(self: *Bench, where: []const u8) !*sqlite.Db {
        self.report.clearRetainingCapacity();
        return sqlite.Db.open(testing.allocator, where, &self.report);
    }

    /// The one value a statement answers with, as text.
    fn one(self: *Bench, conn: *sqlite.Db, sql: []const u8) ![]const u8 {
        var rows = (try conn.query(sql, null)).?;
        defer rows.close();
        try testing.expect(try rows.next());
        const a = self.arena.allocator();
        return switch (rows.value(0)) {
            .null => "NULL",
            .text, .blob => |bytes| try a.dupe(u8, bytes),
            .int => |value| try a.print("{d}", .{value}),
            .float => |value| try a.print("{d}", .{value}),
        };
    }
};

extern fn system(command: [*:0]const u8) c_int;

test "a file that is only looked at is not written" {
    var bench = try Bench.init();
    defer bench.deinit();
    // Quotes nobody needed, which a write would tidy away: if these bytes are
    // still here afterwards, nothing wrote the file.
    const before = "\"id\",\"name\"\r\n\"1\",\"Ada\"\r\n\"2\",\"Grace\"\r\n";
    const where = try bench.file("people.csv", before);
    const conn = try bench.open(where);
    try testing.expectEqualStrings("2", try bench.one(conn, "SELECT count(*) FROM people"));
    try testing.expectEqualStrings("Grace", try bench.one(conn, "SELECT name FROM people WHERE id = 2"));
    // An update that changes nothing, a change that is taken back, and things
    // made beside the table: none of them is a change to what the file says.
    try conn.exec("UPDATE people SET name = name");
    try conn.exec("BEGIN");
    try conn.exec("DELETE FROM people");
    try conn.exec("ROLLBACK");
    try conn.exec("CREATE INDEX by_name ON people (name)");
    try conn.exec("CREATE TABLE scratch AS SELECT * FROM people");
    try conn.exec("INSERT INTO scratch VALUES (3, 'Edsger')");
    conn.close();
    try testing.expectEqualStrings(before, try bench.read(where));
}

test "a change is written in the dialect the file came in" {
    var bench = try Bench.init();
    defer bench.deinit();
    // A semicolon, CRLF, a byte order mark and no newline at the end: what a
    // spreadsheet in half of Europe writes.
    const where = try bench.file("platy.csv", BOM ++ "jmeno;plat\r\nAda;100\r\nGrace;200");
    const conn = try bench.open(where);
    defer conn.close();
    try conn.exec("UPDATE platy SET plat = 250 WHERE jmeno = 'Grace'");
    try testing.expectEqualStrings(BOM ++ "jmeno;plat\r\nAda;100\r\nGrace;250", try bench.read(where));
    // A new row goes on the end, and what needs quoting in this dialect gets it.
    try conn.exec("INSERT INTO platy VALUES ('Hopper; Grace', 300)");
    try testing.expectEqualStrings(
        BOM ++ "jmeno;plat\r\nAda;100\r\nGrace;250\r\n\"Hopper; Grace\";300",
        try bench.read(where),
    );
    try conn.exec("DELETE FROM platy WHERE plat < 300");
    try testing.expectEqualStrings(BOM ++ "jmeno;plat\r\n\"Hopper; Grace\";300", try bench.read(where));
}

test "a tab separated file is read by its name, whatever is in it" {
    var bench = try Bench.init();
    defer bench.deinit();
    const where = try bench.file("towns.tsv", "name\tnote\nBrno\ta,b,c,d\n");
    const conn = try bench.open(where);
    defer conn.close();
    try testing.expectEqualStrings("a,b,c,d", try bench.one(conn, "SELECT note FROM towns"));
    try conn.exec("UPDATE towns SET name = 'Praha'");
    try testing.expectEqualStrings("name\tnote\nPraha\ta,b,c,d\n", try bench.read(where));
}

test "a column is a number only when every value in it writes back as itself" {
    var bench = try Bench.init();
    defer bench.deinit();
    const before =
        \\id,ratio,price,code,big,empty,mixed
        \\1,0.5,1.50,007,9007199254740993,,1
        \\2,3.14,2.25,42,2,,x
        \\10,-2,10.00,7,,,3
        \\
    ;
    const where = try bench.file("numbers.csv", before);
    const conn = try bench.open(where);
    defer conn.close();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const columns = try conn.columns(arena.allocator(), .{ .name = "numbers" });
    const expected = [_][]const u8{ "INTEGER", "REAL", "DECIMAL(15,2)", "TEXT", "INTEGER", "TEXT", "TEXT" };
    try testing.expectEqual(expected.len, columns.len);
    for (expected, columns) |want, column| {
        try testing.expectEqualStrings(want, column.type);
    }
    // Which is what makes them sort as numbers: 10 after 2, not before it.
    try testing.expectEqualStrings("10", try bench.one(conn, "SELECT id FROM numbers ORDER BY id DESC"));
    try testing.expectEqualStrings("3.14", try bench.one(conn, "SELECT max(ratio) FROM numbers"));
    try testing.expectEqualStrings("10", try bench.one(conn, "SELECT id FROM numbers ORDER BY price DESC"));
    try testing.expectEqualStrings("integer", try bench.one(conn, "SELECT typeof(big) FROM numbers WHERE id = 1"));
    // And every value nobody touched is in the file as it was: the trailing
    // zeros, the leading ones, and the integer a float cannot hold.
    try conn.exec("UPDATE numbers SET mixed = 'y' WHERE id = 2");
    const after =
        \\id,ratio,price,code,big,empty,mixed
        \\1,0.5,1.50,007,9007199254740993,,1
        \\2,3.14,2.25,42,2,,y
        \\10,-2,10.00,7,,,3
        \\
    ;
    try testing.expectEqualStrings(after, try bench.read(where));
}

test "what reads as a number and would not come back is text" {
    for ([_][]const u8{ "0", "7", "-7", "9223372036854775807", "-9223372036854775808" }) |text| {
        try testing.expect(whole(text) != null);
    }
    for ([_][]const u8{ "", "007", "+7", "1_000", " 7", "7 ", "-0", "9223372036854775808", "0x10", "1.0" }) |text| {
        try testing.expect(whole(text) == null);
    }
    for ([_][]const u8{ "0", "7", "-0", "0.5", "-3.14", "100000", "1.5", "0.000001" }) |text| {
        try testing.expect(number(text, '.', null) != null);
    }
    for ([_][]const u8{ "", "1.50", ".5", "1.", "1e5", "1E5", "nan", "inf", "-inf", "0x1p3", "1,5", "1_0.5", "9007199254740993", "--1", "1.2.3", "-" }) |text| {
        try testing.expect(number(text, '.', null) == null);
    }
    // With a count of digits it is the other way round: the zeros have to be there.
    try testing.expectEqual(@as(?f64, 1.5), number("1.50", '.', 2));
    try testing.expectEqual(@as(?f64, 10), number("10.00", '.', 2));
    try testing.expectEqual(@as(?f64, -0.25), number("-0.250", '.', 3));
    try testing.expect(number("1.5", '.', 2) == null);
    try testing.expect(number("1.505", '.', 2) == null);
    try testing.expect(number("10", '.', 2) == null);
    // And with a comma, a point is not a number's.
    try testing.expectEqual(@as(?f64, 1.5), number("1,5", ',', null));
    try testing.expectEqual(@as(?f64, 1234.5), number("1234,50", ',', 2));
    try testing.expect(number("1.5", ',', null) == null);
    try testing.expect(number("1,234,5", ',', null) == null);
}

test "a number goes back with its column's digits, unless that would round it" {
    var buffer: [NUMBER_SIZE]u8 = undefined;
    try testing.expectEqualStrings("1.50", written(&buffer, 1.5, '.', 2));
    try testing.expectEqualStrings("1,50", written(&buffer, 1.5, ',', 2));
    try testing.expectEqualStrings("-0.10", written(&buffer, -0.1, '.', 2));
    // Typed into a column of prices, and not a price: all of it, then.
    try testing.expectEqualStrings("1.234", written(&buffer, 1.234, '.', 2));
    try testing.expectEqualStrings("1,234", written(&buffer, 1.234, ',', 2));
    try testing.expectEqualStrings("0.1", written(&buffer, 0.1, '.', null));
    try testing.expectEqualStrings("3,14", written(&buffer, 3.14, ',', null));
    try testing.expectEqualStrings("100000000000000000000", written(&buffer, 1e20, '.', null));
    try testing.expectEqual(@as(?usize, 2), scaleOf("DECIMAL(15,2)"));
    try testing.expectEqual(@as(?usize, 4), scaleOf("numeric(10, 4)"));
    try testing.expectEqual(@as(?usize, null), scaleOf("DECIMAL(15,0)"));
    try testing.expectEqual(@as(?usize, null), scaleOf("VARCHAR(20)"));
    try testing.expectEqual(@as(?usize, null), scaleOf("REAL"));
    try testing.expectEqual(@as(?usize, null), scaleOf("DECIMAL(15,900)"));
}

test "a column of prices is numbers, and keeps its two digits" {
    var bench = try Bench.init();
    defer bench.deinit();
    const where = try bench.file("prices.csv", "item,price\ntea,1.50\ncake,10.00\nmilk,0.95\n");
    const conn = try bench.open(where);
    defer conn.close();
    // Compared as numbers: as text, 10.00 would be the smallest of the three.
    try testing.expectEqualStrings("cake", try bench.one(conn, "SELECT item FROM prices ORDER BY price DESC"));
    try testing.expectEqualStrings("12.45", try bench.one(conn, "SELECT sum(price) FROM prices"));
    try testing.expectEqualStrings("2", try bench.one(conn, "SELECT count(*) FROM prices WHERE price > 1"));
    // A new price and a changed one are written like the others; one that is
    // not a price is written as what it is.
    try conn.exec("UPDATE prices SET price = 2 WHERE item = 'tea'");
    try conn.exec("INSERT INTO prices VALUES ('jam', 3.5)");
    try conn.exec("INSERT INTO prices VALUES ('salt', 0.125)");
    try testing.expectEqualStrings(
        "item,price\ntea,2.00\ncake,10.00\nmilk,0.95\njam,3.50\nsalt,0.125\n",
        try bench.read(where),
    );
    // The type carries the digits, so they survive the column being renamed
    // and the table being written again - which is what the alter form does.
    try conn.exec(
        \\BEGIN;
        \\CREATE TABLE krtek_rebuild (item TEXT, cost DECIMAL(15,2));
        \\INSERT INTO krtek_rebuild (item, cost) SELECT item, price FROM prices;
        \\DROP TABLE prices;
        \\ALTER TABLE krtek_rebuild RENAME TO prices;
        \\COMMIT;
    );
    try testing.expectEqualStrings(
        "item,cost\ntea,2.00\ncake,10.00\nmilk,0.95\njam,3.50\nsalt,0.125\n",
        try bench.read(where),
    );
}

test "a decimal comma is a number where the comma does not separate the fields" {
    var bench = try Bench.init();
    defer bench.deinit();
    const before = "jmeno;plat;podil\r\nAda;100,50;0,5\r\nGrace;1200,00;0,25\r\nEdsger;99,90;1\r\n";
    const where = try bench.file("platy.csv", before);
    const conn = try bench.open(where);
    defer conn.close();
    try testing.expectEqualStrings("Grace", try bench.one(conn, "SELECT jmeno FROM platy ORDER BY plat DESC"));
    try testing.expectEqualStrings("1400.4", try bench.one(conn, "SELECT sum(plat) FROM platy"));
    try testing.expectEqualStrings("0.25", try bench.one(conn, "SELECT min(podil) FROM platy"));
    try conn.exec("UPDATE platy SET plat = plat + 0.5, podil = 0.75 WHERE jmeno = 'Ada'");
    try testing.expectEqualStrings(
        "jmeno;plat;podil\r\nAda;101,00;0,75\r\nGrace;1200,00;0,25\r\nEdsger;99,90;1\r\n",
        try bench.read(where),
    );

    // Where the comma separates the fields it cannot also be in a number that
    // is not quoted, and a file that writes numbers both ways is read the plain
    // way: its comma column is the text it always was.
    const mixed = try bench.file("mixed.csv", "a;b\n1,5;2.5\n2,5;3.5\n");
    const other = try bench.open(mixed);
    defer other.close();
    try testing.expectEqualStrings("text", try bench.one(other, "SELECT typeof(a) FROM mixed"));
    try testing.expectEqualStrings("real", try bench.one(other, "SELECT typeof(b) FROM mixed"));
    try other.exec("UPDATE mixed SET b = 4.5 WHERE a = '1,5'");
    try testing.expectEqualStrings("a;b\n1,5;4.5\n2,5;3.5\n", try bench.read(mixed));
}

test "no value and an empty text are told apart, both ways" {
    var bench = try Bench.init();
    defer bench.deinit();
    const where = try bench.file("gaps.csv", "a,b,c\n,\"\",x\n");
    const conn = try bench.open(where);
    defer conn.close();
    try testing.expectEqualStrings("null", try bench.one(conn, "SELECT typeof(a) FROM gaps"));
    try testing.expectEqualStrings("text", try bench.one(conn, "SELECT typeof(b) FROM gaps"));
    try conn.exec("UPDATE gaps SET c = 'y'");
    try testing.expectEqualStrings("a,b,c\n,\"\",y\n", try bench.read(where));
    try conn.exec("UPDATE gaps SET a = '', b = NULL");
    try testing.expectEqualStrings("a,b,c\n\"\",,y\n", try bench.read(where));
}

test "a table of one column cannot write no value as nothing" {
    var bench = try Bench.init();
    defer bench.deinit();
    const where = try bench.file("one.csv", "name\nAda\n");
    const conn = try bench.open(where);
    try conn.exec("INSERT INTO one VALUES (NULL)");
    try conn.exec("INSERT INTO one VALUES ('Grace')");
    conn.close();
    // A line with nothing on it would be a blank line, and gone on the way in.
    try testing.expectEqualStrings("name\nAda\n\"\"\nGrace\n", try bench.read(where));
    const again = try bench.open(where);
    defer again.close();
    try testing.expectEqualStrings("3", try bench.one(again, "SELECT count(*) FROM one"));
}

test "a header that could not name a column goes back as it came" {
    var bench = try Bench.init();
    defer bench.deinit();
    const where = try bench.file("odd.csv", "id,,ID, name \n1,2,3,4\n");
    const conn = try bench.open(where);
    defer conn.close();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const columns = try conn.columns(arena.allocator(), .{ .name = "odd" });
    const expected = [_][]const u8{ "id", "column_2", "ID_2", "name" };
    try testing.expectEqual(expected.len, columns.len);
    for (expected, columns) |want, column| {
        try testing.expectEqualStrings(want, column.name);
    }
    try conn.exec("UPDATE odd SET name = 5");
    try testing.expectEqualStrings("id,,ID, name \n1,2,3,5\n", try bench.read(where));
    // A column somebody renamed is written under its new name, and the ones
    // beside it still under what the file called them.
    try conn.exec("ALTER TABLE odd RENAME COLUMN column_2 TO second");
    try testing.expectEqualStrings("id,second,ID, name \n1,2,3,5\n", try bench.read(where));
}

test "a row longer than the header has columns of its own, and a shorter one has gaps" {
    var bench = try Bench.init();
    defer bench.deinit();
    const where = try bench.file("ragged.csv", "a,b\n1\n\n1,2,3\n");
    const conn = try bench.open(where);
    defer conn.close();
    try testing.expectEqualStrings("2", try bench.one(conn, "SELECT count(*) FROM ragged"));
    try testing.expectEqualStrings("3", try bench.one(conn, "SELECT column_3 FROM ragged WHERE b = 2"));
    try conn.exec("UPDATE ragged SET a = 9 WHERE b IS NULL");
    // Squared up, and the blank line gone: the one thing a write does that
    // nobody asked for, and only to a file that was not square.
    try testing.expectEqualStrings("a,b,\n9,,\n1,2,3\n", try bench.read(where));
}

test "a column added, renamed or dropped changes the file though it changes no row" {
    var bench = try Bench.init();
    defer bench.deinit();
    // No rows at all, so the count of changed rows never moves: this is the
    // schema's version doing the telling.
    const where = try bench.file("empty.csv", "a,b\n");
    const conn = try bench.open(where);
    defer conn.close();
    try conn.exec("ALTER TABLE empty ADD COLUMN c TEXT");
    try testing.expectEqualStrings("a,b,c\n", try bench.read(where));
    try conn.exec("ALTER TABLE empty RENAME COLUMN a TO first");
    try testing.expectEqualStrings("first,b,c\n", try bench.read(where));
    try conn.exec("ALTER TABLE empty DROP COLUMN b");
    try testing.expectEqualStrings("first,c\n", try bench.read(where));
    // The rebuild the alter form writes: a new table under the old name.
    try conn.exec(
        \\BEGIN;
        \\CREATE TABLE krtek_rebuild (c TEXT, first TEXT);
        \\INSERT INTO krtek_rebuild (c, first) SELECT c, first FROM empty;
        \\DROP TABLE empty;
        \\ALTER TABLE krtek_rebuild RENAME TO empty;
        \\COMMIT;
    );
    try testing.expectEqualStrings("c,first\n", try bench.read(where));
}

test "a transaction is written when it is committed and not before" {
    var bench = try Bench.init();
    defer bench.deinit();
    const where = try bench.file("log.csv", "n\n1\n");
    const conn = try bench.open(where);
    defer conn.close();
    try conn.exec("BEGIN");
    try conn.exec("INSERT INTO log VALUES (2)");
    try testing.expectEqualStrings("n\n1\n", try bench.read(where));
    // Through a cursor, the way the interface runs what somebody typed.
    var rows = (try conn.query("COMMIT", null)).?;
    try testing.expect(!try rows.next());
    rows.close();
    try testing.expectEqualStrings("n\n1\n2\n", try bench.read(where));
}

test "quotes, separators and line breaks inside a value survive the round trip" {
    var bench = try Bench.init();
    defer bench.deinit();
    const before = "id,note\n1,\"two\nlines, and a \"\"quote\"\"\"\n2,plain\n";
    const where = try bench.file("notes.csv", before);
    const conn = try bench.open(where);
    defer conn.close();
    try testing.expectEqualStrings("two\nlines, and a \"quote\"", try bench.one(conn, "SELECT note FROM notes WHERE id = 1"));
    try conn.exec("UPDATE notes SET note = 'still plain' WHERE id = 2");
    try testing.expectEqualStrings(
        "id,note\n1,\"two\nlines, and a \"\"quote\"\"\"\n2,still plain\n",
        try bench.read(where),
    );
}

test "a file that changed on disk is not written over" {
    var bench = try Bench.init();
    defer bench.deinit();
    const where = try bench.file("shared.csv", "n\n1\n");
    const conn = try bench.open(where);
    defer conn.close();
    // Somebody else, meanwhile.
    _ = try bench.file("shared.csv", "n\n1\n2\n3\n");
    try testing.expectError(error.Driver, conn.exec("UPDATE shared SET n = 100"));
    try testing.expect(std.mem.find(u8, conn.message(), "changed on disk") != null);
    try testing.expectEqualStrings("n\n1\n2\n3\n", try bench.read(where));
    // And it is said once, by the statement that could not be saved - not by
    // everything that is asked afterwards.
    try testing.expectEqualStrings("100", try bench.one(conn, "SELECT n FROM shared"));
}

test "a file that may not be written is not replaced by one that may" {
    // Nothing is read-only to root, which is who runs these in a container.
    if (std.c.geteuid() == 0) {
        return error.SkipZigTest;
    }
    var bench = try Bench.init();
    defer bench.deinit();
    const where = try bench.file("locked.csv", "n\n1\n");
    try testing.expectEqual(@as(c_int, 0), std.c.chmod(where, 0o444));
    const conn = try bench.open(where);
    defer conn.close();
    // The directory can be written in, so a rename would have gone through.
    try testing.expectError(error.Driver, conn.exec("UPDATE locked SET n = 2"));
    try testing.expect(std.mem.find(u8, conn.message(), "cannot write") != null);
    try testing.expectEqualStrings("n\n1\n", try bench.read(where));
}

test "what is written keeps the file's permissions, and a link stays a link" {
    var bench = try Bench.init();
    defer bench.deinit();
    const where = try bench.file("private.csv", "n\n1\n");
    try testing.expectEqual(@as(c_int, 0), std.c.chmod(where, 0o600));
    const link = try bench.path("link.csv");
    try testing.expectEqual(@as(c_int, 0), std.c.symlink(where, link));
    const conn = try bench.open(link);
    defer conn.close();
    // Named after the link, which is what was opened.
    try conn.exec("UPDATE link SET n = 2");
    try testing.expectEqualStrings("n\n2\n", try bench.read(where));
    try testing.expectEqual(@as(u32, 0o600), facts(where).?.mode & 0o7777);
    var buffer: [256]u8 = undefined;
    const length = std.c.readlink(link, &buffer, buffer.len);
    try testing.expect(length > 0);
    try testing.expectEqualStrings(where, buffer[0..@intCast(length)]);
    // Nothing left lying beside it.
    try testing.expect(facts(try bench.path("private.csv.krtek-tmp")) == null);
}

test "the table gone is said, and the file is left as it was" {
    var bench = try Bench.init();
    defer bench.deinit();
    const where = try bench.file("gone.csv", "n\n1\n");
    const conn = try bench.open(where);
    defer conn.close();
    try testing.expectError(error.Driver, conn.exec("ALTER TABLE gone RENAME TO elsewhere"));
    try testing.expect(std.mem.find(u8, conn.message(), "there is none now") != null);
    try testing.expectEqualStrings("n\n1\n", try bench.read(where));
    // Back under its name, it is the file's again.
    try conn.exec("ALTER TABLE elsewhere RENAME TO gone");
    try conn.exec("INSERT INTO gone VALUES (2)");
    try testing.expectEqualStrings("n\n1\n2\n", try bench.read(where));
}

test "what SQLite said is still there to read after the file was looked at" {
    var bench = try Bench.init();
    defer bench.deinit();
    const where = try bench.file("said.csv", "n\n1\n");
    const conn = try bench.open(where);
    defer conn.close();
    try testing.expectError(error.Driver, conn.exec("UPDATE nowhere SET n = 2"));
    try testing.expect(std.mem.find(u8, conn.message(), "no such table: nowhere") != null);
    var rows = (try conn.query("SELECT abs(-9223372036854775808) FROM said", null)).?;
    try testing.expectError(error.Driver, rows.next());
    rows.close();
    try testing.expect(std.mem.find(u8, conn.message(), "integer overflow") != null);
}

test "a file that cannot be a table says why" {
    var bench = try Bench.init();
    defer bench.deinit();
    try testing.expectError(error.Driver, bench.open(try bench.path("missing.csv")));
    try testing.expect(std.mem.find(u8, bench.report.items, "missing.csv") != null);
    try testing.expectError(error.Driver, bench.open(try bench.file("nothing.csv", "")));
    try testing.expect(std.mem.find(u8, bench.report.items, "is empty") != null);
    try testing.expectError(error.Driver, bench.open(try bench.file("blank.csv", "\n\n")));
    try testing.expect(std.mem.find(u8, bench.report.items, "is empty") != null);
    try testing.expectError(error.Driver, bench.open(try bench.file("wide.csv", "\xFF\xFEa\x00,\x00b\x00")));
    try testing.expect(std.mem.find(u8, bench.report.items, "UTF-16") != null);
    const dir = try bench.path("dir.csv");
    try testing.expectEqual(@as(c_int, 0), std.c.mkdir(dir, 0o755));
    try testing.expectError(error.Driver, bench.open(dir));
    try testing.expect(std.mem.find(u8, bench.report.items, "is a directory") != null);
}

test "a table is named after its file, and a sheet is known by its name" {
    try testing.expect(claims("people.csv"));
    try testing.expect(claims("/srv/data/PEOPLE.CSV"));
    try testing.expect(claims("towns.tsv"));
    try testing.expect(!claims("people.db"));
    try testing.expect(!claims("csv"));
    try testing.expect(!claims("postgres://host/csv"));
    try testing.expectEqualStrings("people", tableName("/srv/data/people.csv"));
    try testing.expectEqualStrings("my file (1)", tableName("my file (1).tsv"));
    // Names SQLite keeps for itself, and no name at all.
    try testing.expectEqualStrings("csv", tableName("sqlite_stat.csv"));
    try testing.expectEqualStrings("csv", tableName("/tmp/.csv"));
}

test "a header alone is a table with no rows, and takes its first" {
    var bench = try Bench.init();
    defer bench.deinit();
    // No newline after the header, so none is added after the row either.
    const where = try bench.file("fresh.csv", "name,age");
    const conn = try bench.open(where);
    defer conn.close();
    try testing.expectEqualStrings("0", try bench.one(conn, "SELECT count(*) FROM fresh"));
    try conn.exec("INSERT INTO fresh VALUES ('Ada', 36)");
    try testing.expectEqualStrings("name,age\nAda,36", try bench.read(where));
}

test "a write that was refused is tried again when the file is closed" {
    if (std.c.geteuid() == 0) {
        return error.SkipZigTest;
    }
    var bench = try Bench.init();
    defer bench.deinit();
    const where = try bench.file("later.csv", "n\n1\n");
    try testing.expectEqual(@as(c_int, 0), std.c.chmod(where, 0o444));
    const conn = try bench.open(where);
    try testing.expectError(error.Driver, conn.exec("UPDATE later SET n = 2"));
    // Nothing else changes, so no statement would try again - and whatever was
    // in the way is gone by the time the file is closed.
    try testing.expectEqualStrings("2", try bench.one(conn, "SELECT n FROM later"));
    try testing.expectEqualStrings("n\n1\n", try bench.read(where));
    try testing.expectEqual(@as(c_int, 0), std.c.chmod(where, 0o644));
    conn.close();
    try testing.expectEqualStrings("n\n2\n", try bench.read(where));
}

test "a column called rowid does not take the name from the row's own number" {
    var bench = try Bench.init();
    defer bench.deinit();
    // Not in order and not unique: as the row's number it would move the rows
    // about on the way out, and one edit would land on two of them.
    const where = try bench.file("ids.csv", "rowid,OID,name\n5,x,a\n5,y,b\n1,z,c\n");
    const conn = try bench.open(where);
    defer conn.close();
    try testing.expectEqualStrings("1", try bench.one(conn, "SELECT rowid FROM ids WHERE name = 'a'"));
    try testing.expectEqualStrings("5", try bench.one(conn, "SELECT rowid_2 FROM ids WHERE name = 'a'"));
    try testing.expectEqualStrings("3", try bench.one(conn, "SELECT count(DISTINCT rowid) FROM ids"));
    try conn.exec("UPDATE ids SET name = 'A' WHERE rowid = 1");
    // One row changed, the rows where they were, and the header as it came.
    try testing.expectEqualStrings("rowid,OID,name\n5,x,A\n5,y,b\n1,z,c\n", try bench.read(where));
}

test "a header of one column that named nothing does not go back as a blank line" {
    var bench = try Bench.init();
    defer bench.deinit();
    const where = try bench.file("nameless.csv", "\"\"\nAda\nGrace\n");
    const conn = try bench.open(where);
    try testing.expectEqualStrings("2", try bench.one(conn, "SELECT count(*) FROM nameless"));
    try conn.exec("UPDATE nameless SET column_1 = 'Hopper' WHERE column_1 = 'Grace'");
    conn.close();
    try testing.expectEqualStrings("\"\"\nAda\nHopper\n", try bench.read(where));
    const again = try bench.open(where);
    defer again.close();
    try testing.expectEqualStrings("2", try bench.one(again, "SELECT count(*) FROM nameless"));
}

test "more digits than a column is taken to have is text, and stays as it was" {
    var bench = try Bench.init();
    defer bench.deinit();
    const long = "0.50000000000000000000000000000000000";
    const where = try bench.file("long.csv", "a,b\n" ++ long ++ ",x\n" ++ long ++ ",y\n");
    const conn = try bench.open(where);
    defer conn.close();
    try testing.expectEqualStrings("text", try bench.one(conn, "SELECT typeof(a) FROM long"));
    try conn.exec("UPDATE long SET b = 'z' WHERE b = 'y'");
    try testing.expectEqualStrings("a,b\n" ++ long ++ ",x\n" ++ long ++ ",z\n", try bench.read(where));
}

test "a database is a database whatever its file is called" {
    var bench = try Bench.init();
    defer bench.deinit();
    const made = try bench.path("real.db");
    {
        const conn = try bench.open(made);
        defer conn.close();
        try conn.exec("CREATE TABLE notes (body TEXT); INSERT INTO notes VALUES ('kept')");
    }
    // Under a name that says CSV. Read as one it would be a column of bytes,
    // and the first edit would write a text file over the database.
    const where = try bench.path("export.csv");
    try testing.expectEqual(@as(c_int, 0), std.c.rename(made, where));
    const conn = try bench.open(where);
    defer conn.close();
    try testing.expect(conn.sheet == null);
    try testing.expectEqualStrings("SQLite", conn.caps().label);
    try testing.expectEqualStrings("kept", try bench.one(conn, "SELECT body FROM notes"));
    try conn.exec("INSERT INTO notes VALUES ('more')");
    try testing.expect(std.mem.startsWith(u8, try bench.read(where), "SQLite format 3"));
}

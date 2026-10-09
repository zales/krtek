//! SQLite behind the shared interface.
//!
//! The C declarations live in `src/sqlite.zig`; this file is the driver: the
//! pragmas that answer the interface's questions, and the table rebuild SQLite
//! needs for anything ALTER TABLE cannot do.
//!
//! It is also what a CSV file is opened through: the file is read into a
//! database in memory, and written back when a statement has changed what it
//! would say. Everything about the file itself is in `sheet.zig`; what is here
//! is where a statement ends, which is when that question gets asked.

const std = @import("std");
const db = @import("db.zig");
const sheet = @import("sheet.zig");
const c = @import("sqlite");

const List = db.List;

pub const Db = struct {
    allocator: std.mem.Allocator,
    handle: ?*c.Db,
    path: std.ArrayList(u8) = .empty,
    version_text: std.ArrayList(u8) = .empty,
    /// Asked every so often whether the statement running now should go on.
    progress: ?db.Progress = null,
    /// The delimited file this database was read from and is written back to,
    /// where it is one. Null for a database that is its own file.
    sheet: ?*sheet.Sheet = null,
    /// What last went wrong, for a sheet. SQLite keeps its own last complaint
    /// and that is what `message` gives for a database - but a sheet is looked
    /// at after every statement, which asks SQLite other things and leaves it
    /// with nothing to complain about, and writing a file fails in ways SQLite
    /// never hears of.
    failure: std.ArrayList(u8) = .empty,

    pub fn open(allocator: std.mem.Allocator, target: []const u8, report: *std.ArrayList(u8)) !*Db {
        // A name that says CSV on a file that is a database: it is the
        // database. Before a CSV could be opened every file was one, and one
        // called `export.csv` read as text would be written back as text.
        if (sheet.claims(target) and !isDatabase(allocator, target)) {
            return openSheet(allocator, target, report);
        }
        const zero = try allocator.dupeSentinel(u8, target, 0);
        defer allocator.free(zero);
        var handle: ?*c.Db = null;
        if (c.sqlite3_open_v2(zero.ptr, &handle, c.OPEN_READWRITE | c.OPEN_CREATE, null) != c.OK) {
            try report.print(allocator, "cannot open {s}", .{target});
            _ = c.sqlite3_close_v2(handle);
            return error.Driver;
        }
        _ = c.sqlite3_busy_timeout(handle, 2000);
        _ = c.sqlite3_exec(handle, "PRAGMA foreign_keys=1", null, null, null);
        // Catch a file that is not a database before the screen is taken over.
        if (c.sqlite3_exec(handle, "PRAGMA schema_version", null, null, null) != c.OK) {
            try report.print(allocator, "{s}: {s}", .{ target, std.mem.span(c.sqlite3_errmsg(handle)) });
            _ = c.sqlite3_close_v2(handle);
            return error.Driver;
        }
        const self = try allocator.create(Db);
        self.* = .{ .allocator = allocator, .handle = handle };
        try self.path.appendSlice(allocator, target);
        try self.version_text.print(allocator, "SQLite {s}", .{std.mem.span(c.sqlite3_libversion())});
        return self;
    }

    /// Whether the file starts the way every SQLite database does.
    fn isDatabase(allocator: std.mem.Allocator, target: []const u8) bool {
        const magic = "SQLite format 3\x00";
        const zero = allocator.dupeSentinel(u8, target, 0) catch return false;
        defer allocator.free(zero);
        const file = std.c.fopen(zero.ptr, "rb") orelse return false;
        defer _ = std.c.fclose(file);
        var head: [magic.len]u8 = undefined;
        return std.c.fread(&head, 1, head.len, file) == head.len and std.mem.eql(u8, &head, magic);
    }

    /// A CSV file: a database in memory with the file read into it.
    fn openSheet(allocator: std.mem.Allocator, target: []const u8, report: *std.ArrayList(u8)) !*Db {
        var handle: ?*c.Db = null;
        if (c.sqlite3_open_v2(":memory:", &handle, c.OPEN_READWRITE | c.OPEN_CREATE, null) != c.OK) {
            try report.print(allocator, "cannot open {s}", .{target});
            _ = c.sqlite3_close_v2(handle);
            return error.Driver;
        }
        errdefer _ = c.sqlite3_close_v2(handle);
        const file = try sheet.Sheet.open(allocator, handle, target, report);
        errdefer file.close();
        const self = try allocator.create(Db);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .handle = handle, .sheet = file };
        errdefer self.path.deinit(allocator);
        try self.path.appendSlice(allocator, target);
        try self.version_text.print(allocator, "CSV, through SQLite {s}", .{std.mem.span(c.sqlite3_libversion())});
        return self;
    }

    /// SQLite calls a handler every so many steps of its virtual machine, and a
    /// non-zero answer aborts the statement with SQLITE_INTERRUPT, so this needs
    /// no plumbing through the query path at all.
    pub fn watch(self: *Db, progress: ?db.Progress) void {
        self.progress = progress;
        self.listen();
    }

    fn listen(self: *Db) void {
        if (self.progress == null) {
            c.sqlite3_progress_handler(self.handle, 0, null, null);
            return;
        }
        // Roughly every few milliseconds of work on current hardware: often
        // enough to feel responsive, rarely enough not to matter.
        c.sqlite3_progress_handler(self.handle, 20_000, onProgress, self);
    }

    /// A statement has ended: if this is a sheet, the file is brought up to
    /// date with what the statement did. An error here is the file not having
    /// been written, and `message` says why.
    fn settled(self: *Db) db.Error!void {
        const file = self.sheet orelse return;
        // Reading the table back is a statement like any other, and the one
        // statement nobody should be able to give up on half way: esc while a
        // file is being written must not leave it unwritten.
        c.sqlite3_progress_handler(self.handle, 0, null, null);
        defer self.listen();
        return file.settle(self.handle, &self.failure, false);
    }

    /// SQLite said no. For a sheet what it said is kept, because the look at
    /// the file that follows every statement leaves SQLite with nothing to say.
    fn refused(self: *Db) db.Error {
        if (self.sheet != null) {
            self.failure.clearRetainingCapacity();
            self.failure.appendSlice(self.allocator, std.mem.span(c.sqlite3_errmsg(self.handle))) catch {};
        }
        return error.Driver;
    }

    /// Tell the caller a statement is beginning, so its timer starts here.
    fn starting(self: *Db) void {
        if (self.progress) |progress| {
            progress.starting();
        }
    }

    fn onProgress(context: ?*anyopaque) callconv(.c) c_int {
        const self: *Db = @ptrCast(@alignCast(context orelse return 0));
        const progress = self.progress orelse return 0;
        return if (progress.call()) 0 else 1;
    }

    pub fn close(self: *Db) void {
        c.sqlite3_progress_handler(self.handle, 0, null, null);
        if (self.sheet) |file| {
            // The last chance for anything a statement left unwritten: a batch
            // that failed half way, a write that was refused the first time.
            file.settle(self.handle, &self.failure, true) catch {};
            file.close();
        }
        _ = c.sqlite3_close_v2(self.handle);
        self.path.deinit(self.allocator);
        self.version_text.deinit(self.allocator);
        self.failure.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn caps(self: *Db) db.Caps {
        return .{
            .schemas = false,
            .hidden_row_id = true, // rowid addresses a row without a key
            .rebuild_to_alter = true,
            .databases = false,
            .label = if (self.sheet != null) "CSV" else "SQLite",
            // Every one of these would work, for as long as the file is open,
            // and none of them is anything a CSV file can hold.
            .no_relations = if (self.sheet != null)
                "a CSV file holds rows and nothing else: an index, a view, a trigger or a key would be gone when it is closed"
            else
                "",
            .no_tables = if (self.sheet != null)
                "a CSV file is one table, named after the file: another one would be gone when it is closed"
            else
                "",
        };
    }

    pub fn version(self: *Db) []const u8 {
        return self.version_text.items;
    }

    pub fn describe(self: *Db) []const u8 {
        return self.path.items;
    }

    pub fn message(self: *Db) []const u8 {
        if (self.failure.items.len != 0) {
            return self.failure.items;
        }
        return std.mem.span(c.sqlite3_errmsg(self.handle));
    }

    pub fn exec(self: *Db, sql: []const u8) db.Error!void {
        self.starting();
        self.failure.clearRetainingCapacity();
        const zero = try self.allocator.dupeSentinel(u8, sql, 0);
        defer self.allocator.free(zero);
        if (c.sqlite3_exec(self.handle, zero.ptr, null, null, null) != c.OK) {
            // What ran before the one that failed still ran, and is written
            // with whatever changes next - or when the file is closed.
            return self.refused();
        }
        try self.settled();
    }

    pub fn query(self: *Db, sql: []const u8, rest: ?*[]const u8) db.Error!?db.Rows {
        self.starting();
        self.failure.clearRetainingCapacity();
        var stmt: ?*c.Stmt = null;
        var tail: ?[*]const u8 = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, @intCast(sql.len), &stmt, &tail) != c.OK) {
            return self.refused();
        }
        if (rest) |out| {
            const used = if (tail) |t| @intFromPtr(t) - @intFromPtr(sql.ptr) else sql.len;
            out.* = sql[used..];
        }
        if (stmt == null) {
            return null; // a comment or an empty statement
        }
        return .{ .sqlite = .{ .owner = self, .stmt = stmt } };
    }

    pub fn inTransaction(self: *Db) bool {
        return c.sqlite3_get_autocommit(self.handle) == 0;
    }

    // ---------------------------------------------------------- introspection

    /// Open a cursor over an internal query.
    fn ask(self: *Db, sql: []const u8) db.Error!?Rows {
        var stmt: ?*c.Stmt = null;
        var tail: ?[*]const u8 = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, @intCast(sql.len), &stmt, &tail) != c.OK) {
            return self.refused();
        }
        if (stmt == null) {
            return null;
        }
        return Rows{ .owner = self, .stmt = stmt };
    }

    fn text(arena: std.mem.Allocator, value: db.Value) ![]const u8 {
        return switch (value) {
            .null => "",
            .text, .blob => |bytes| try arena.dupe(u8, bytes),
            .int => |v| try arena.print("{d}", .{v}),
            .float => |v| try arena.print("{d}", .{v}),
        };
    }

    pub fn schemas(_: *Db, _: std.mem.Allocator) db.Error![][]const u8 {
        return &.{}; // one database, no schemas
    }

    pub fn objects(self: *Db, arena: std.mem.Allocator, _: []const u8) db.Error![]db.Object {
        var list: std.ArrayList(db.Object) = .empty;
        var rows = (try self.ask(
            "SELECT name, type FROM sqlite_master WHERE type IN ('table', 'view')" ++
                " AND name NOT LIKE 'sqlite~_%' ESCAPE '~' ORDER BY name COLLATE NOCASE",
        )) orelse return &.{};
        defer rows.close();
        while (try rows.next()) {
            const kind = try text(arena, rows.value(1));
            try list.append(arena, .{
                .name = try text(arena, rows.value(0)),
                .kind = if (std.mem.eql(u8, kind, "view")) .view else .table,
                .rows = null, // counted on demand, SQLite has no estimate
            });
        }
        return list.items;
    }

    pub fn columns(self: *Db, arena: std.mem.Allocator, table: db.Table) db.Error![]db.Column {
        var sql: List = .empty;
        try sql.appendSlice(arena, "SELECT name, type, \"notnull\", dflt_value, pk FROM pragma_table_info(");
        try db.quote(&sql, arena, table.name);
        try sql.append(arena, ')');
        var list: std.ArrayList(db.Column) = .empty;
        {
            var rows = (try self.ask(sql.items)) orelse return &.{};
            defer rows.close();
            while (try rows.next()) {
                const name = try text(arena, rows.value(0));
                try list.append(arena, .{
                    .name = name,
                    .type = try text(arena, rows.value(1)),
                    .notnull = switch (rows.value(2)) {
                        .int => |v| v != 0,
                        else => false,
                    },
                    .dflt = switch (rows.value(3)) {
                        .null => null,
                        else => try text(arena, rows.value(3)),
                    },
                    .pk = switch (rows.value(4)) {
                        .int => |v| v > 0,
                        else => false,
                    },
                    .original = name,
                });
            }
        }
        // A column level UNIQUE is only an index, and would be lost on a rebuild.
        var unique: List = .empty;
        try unique.appendSlice(arena, "SELECT (SELECT c.name FROM pragma_index_info(i.name) c LIMIT 1) FROM pragma_index_list(");
        try db.quote(&unique, arena, table.name);
        try unique.appendSlice(arena, ") i WHERE i.origin = 'u' AND (SELECT count(*) FROM pragma_index_info(i.name)) = 1");
        var extra = (try self.ask(unique.items)) orelse return list.items;
        defer extra.close();
        while (try extra.step_or_null()) |value| {
            const name = try text(arena, value);
            for (list.items) |*column| {
                if (std.mem.eql(u8, column.name, name)) {
                    column.unique = true;
                }
            }
        }
        return list.items;
    }

    pub fn indexes(self: *Db, arena: std.mem.Allocator, table: db.Table) db.Error![]db.Index {
        var sql: List = .empty;
        try sql.appendSlice(arena,
            \\SELECT i.name, CASE i.origin WHEN 'pk' THEN 'PRIMARY' WHEN 'u' THEN 'UNIQUE' ELSE
            \\  CASE WHEN i."unique" THEN 'UNIQUE' ELSE 'INDEX' END END,
            \\  (SELECT group_concat(c.name, ', ') FROM pragma_index_info(i.name) c), i.partial
            \\ FROM pragma_index_list(
        );
        try db.quote(&sql, arena, table.name);
        try sql.appendSlice(arena, ") i");
        var list: std.ArrayList(db.Index) = .empty;
        var rows = (try self.ask(sql.items)) orelse return &.{};
        defer rows.close();
        while (try rows.next()) {
            const members = try text(arena, rows.value(2));
            try list.append(arena, .{
                .name = try text(arena, rows.value(0)),
                .kind = try text(arena, rows.value(1)),
                .columns = if (members.len != 0) members else "(expression)",
                .partial = switch (rows.value(3)) {
                    .int => |v| v != 0,
                    else => false,
                },
            });
        }
        return list.items;
    }

    pub fn foreignKeys(self: *Db, arena: std.mem.Allocator, table: db.Table) db.Error![]db.ForeignKey {
        var sql: List = .empty;
        try sql.appendSlice(arena, "SELECT \"from\", \"table\", \"to\", on_update, on_delete FROM pragma_foreign_key_list(");
        try db.quote(&sql, arena, table.name);
        try sql.appendSlice(arena, ") ORDER BY id, seq");
        var list: std.ArrayList(db.ForeignKey) = .empty;
        var rows = (try self.ask(sql.items)) orelse return &.{};
        defer rows.close();
        while (try rows.next()) {
            try list.append(arena, .{
                .column = try text(arena, rows.value(0)),
                .target_table = try text(arena, rows.value(1)),
                .target_column = try text(arena, rows.value(2)),
                .on_update = try text(arena, rows.value(3)),
                .on_delete = try text(arena, rows.value(4)),
            });
        }
        return list.items;
    }

    pub fn definition(self: *Db, arena: std.mem.Allocator, table: db.Table) db.Error!?[]const u8 {
        var sql: List = .empty;
        try sql.appendSlice(arena, "SELECT sql FROM sqlite_master WHERE name = ");
        try db.quote(&sql, arena, table.name);
        var rows = (try self.ask(sql.items)) orelse return null;
        defer rows.close();
        if (!try rows.next()) {
            return null;
        }
        return switch (rows.value(0)) {
            .null => null,
            else => try text(arena, rows.value(0)),
        };
    }

    pub fn rowCount(self: *Db, table: db.Table) ?i64 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var sql: List = .empty;
        sql.appendSlice(a, "SELECT count(*) FROM ") catch return null;
        db.quoteName(&sql, a, table.name) catch return null;
        var rows = (self.ask(sql.items) catch return null) orelse return null;
        defer rows.close();
        if (!(rows.next() catch return null)) {
            return null;
        }
        return switch (rows.value(0)) {
            .int => |v| v,
            else => null,
        };
    }

    /// The rowid where there is one, otherwise the primary key.
    pub fn rowKey(self: *Db, arena: std.mem.Allocator, table: db.Table) db.Error!db.RowKey {
        var probe: List = .empty;
        try probe.appendSlice(arena, "SELECT rowid FROM ");
        try db.quoteName(&probe, arena, table.name);
        try probe.appendSlice(arena, " LIMIT 0");
        if (self.ask(probe.items)) |maybe| {
            if (maybe) |cursor| {
                var probe_rows = cursor;
                probe_rows.close();
                var list: std.ArrayList([]const u8) = .empty;
                try list.append(arena, "rowid");
                return .{ .columns = list.items, .hidden = true, .expression = "rowid" };
            }
        } else |_| {}

        var sql: List = .empty;
        try sql.appendSlice(arena, "SELECT name FROM pragma_table_info(");
        try db.quote(&sql, arena, table.name);
        try sql.appendSlice(arena, ") WHERE pk > 0 ORDER BY pk");
        var list: std.ArrayList([]const u8) = .empty;
        var rows = (try self.ask(sql.items)) orelse return .{};
        defer rows.close();
        while (try rows.next()) {
            try list.append(arena, try text(arena, rows.value(0)));
        }
        return .{ .columns = list.items, .hidden = false };
    }

    /// A rebuild drops the indexes and triggers with the table, so they have to
    /// be put back. A plain index is regenerated from its metadata with the
    /// column renames applied, so renaming a column does not break it; a partial
    /// index, an index on an expression and a trigger carry SQL that cannot be
    /// rewritten safely, so their text is replayed as it is.
    pub fn alterContext(self: *Db, arena: std.mem.Allocator, table: db.Table, cols: []const db.Column) db.Error!db.AlterContext {
        var replay: std.ArrayList([]const u8) = .empty;
        const renamed = struct {
            fn map(all: []const db.Column, old: []const u8) []const u8 {
                for (all) |column| {
                    if (column.original.len != 0 and std.mem.eql(u8, column.original, old)) {
                        return column.name;
                    }
                }
                return old;
            }
        }.map;

        var listing: List = .empty;
        try listing.appendSlice(arena, "SELECT i.name, i.\"unique\", i.partial FROM pragma_index_list(");
        try db.quote(&listing, arena, table.name);
        try listing.appendSlice(arena, ") i WHERE i.origin = 'c'");
        const Found = struct { name: []const u8, unique: bool, partial: bool };
        var found: std.ArrayList(Found) = .empty;
        {
            var rows = (try self.ask(listing.items)) orelse return .{ .columns = cols };
            defer rows.close();
            while (try rows.next()) {
                try found.append(arena, .{
                    .name = try text(arena, rows.value(0)),
                    .unique = switch (rows.value(1)) {
                        .int => |v| v != 0,
                        else => false,
                    },
                    .partial = switch (rows.value(2)) {
                        .int => |v| v != 0,
                        else => false,
                    },
                });
            }
        }
        for (found.items) |index| {
            var members: std.ArrayList([]const u8) = .empty;
            var expression = false;
            if (!index.partial) {
                var info: List = .empty;
                try info.appendSlice(arena, "SELECT name FROM pragma_index_info(");
                try db.quote(&info, arena, index.name);
                try info.appendSlice(arena, ") ORDER BY seqno");
                var walk = (try self.ask(info.items)) orelse continue;
                defer walk.close();
                while (try walk.next()) {
                    switch (walk.value(0)) {
                        .text => |column| try members.append(arena, renamed(cols, try arena.dupe(u8, column))),
                        else => expression = true,
                    }
                }
            }
            if (index.partial or expression or members.items.len == 0) {
                if (try self.objectSql(arena, index.name)) |sql| {
                    try replay.append(arena, sql);
                }
                continue;
            }
            var statement: List = .empty;
            const generator = Ddl{};
            try generator.createIndex(&statement, arena, table, index.name, members.items, index.unique, "");
            try replay.append(arena, std.mem.trimEnd(u8, statement.items, ";\n"));
        }

        var triggers: List = .empty;
        try triggers.appendSlice(arena, "SELECT sql FROM sqlite_master WHERE type = 'trigger' AND sql IS NOT NULL AND tbl_name = ");
        try db.quote(&triggers, arena, table.name);
        {
            var rows = (try self.ask(triggers.items)) orelse return .{
                .columns = cols,
                .keys = try self.foreignKeys(arena, table),
                .replay = replay.items,
            };
            defer rows.close();
            while (try rows.next()) {
                switch (rows.value(0)) {
                    .text => |sql| try replay.append(arena, try arena.dupe(u8, sql)),
                    else => {},
                }
            }
        }
        return .{
            .columns = cols,
            .keys = try self.foreignKeys(arena, table),
            .replay = replay.items,
        };
    }

    fn objectSql(self: *Db, arena: std.mem.Allocator, object: []const u8) db.Error!?[]const u8 {
        var sql: List = .empty;
        try sql.appendSlice(arena, "SELECT sql FROM sqlite_master WHERE name = ");
        try db.quote(&sql, arena, object);
        var rows = (try self.ask(sql.items)) orelse return null;
        defer rows.close();
        if (!try rows.next()) {
            return null;
        }
        return switch (rows.value(0)) {
            .null => null,
            else => try text(arena, rows.value(0)),
        };
    }

    const PRAGMAS = [_][]const u8{
        "page_size",      "page_count",     "freelist_count", "encoding",
        "journal_mode",   "auto_vacuum",    "foreign_keys",   "user_version",
        "application_id", "schema_version", "cache_size",     "temp_store",
    };

    pub fn settings(self: *Db, arena: std.mem.Allocator) db.Error![]db.Setting {
        // The pragmas of a database that exists to hold a file say nothing
        // about the file, which is what somebody looking here is asking about.
        if (self.sheet) |file| {
            return file.settings(arena);
        }
        var list: std.ArrayList(db.Setting) = .empty;
        try list.append(arena, .{ .label = "file", .value = self.path.items });
        {
            const size = self.oneNumber("PRAGMA page_size") orelse 0;
            const count = self.oneNumber("PRAGMA page_count") orelse 0;
            try list.append(arena, .{
                .label = "size",
                .value = try arena.print("{d} bytes ({d} pages)", .{ size * count, count }),
            });
        }
        for (PRAGMAS) |pragma| {
            var sql: List = .empty;
            try sql.print(arena, "PRAGMA {s}", .{pragma});
            var rows = (try self.ask(sql.items)) orelse continue;
            defer rows.close();
            if (!try rows.next()) {
                continue;
            }
            try list.append(arena, .{ .label = pragma, .value = try text(arena, rows.value(0)) });
        }
        {
            var rows = (try self.ask("PRAGMA quick_check(1)")) orelse return list.items;
            defer rows.close();
            if (try rows.next()) {
                try list.append(arena, .{ .label = "integrity", .value = try text(arena, rows.value(0)) });
            }
        }
        return list.items;
    }

    fn oneNumber(self: *Db, sql: []const u8) ?i64 {
        var rows = (self.ask(sql) catch return null) orelse return null;
        defer rows.close();
        if (!(rows.next() catch return null)) {
            return null;
        }
        return switch (rows.value(0)) {
            .int => |v| v,
            else => null,
        };
    }

    /// Textual, not through the tokenizer: a batch may create a table and then
    /// use it, and a statement cannot be prepared before the one before it ran.
    pub fn split(_: *Db, arena: std.mem.Allocator, sql: []const u8) db.Error![]db.Statement {
        return db.splitStatements(arena, sql, .{ .brackets = true, .backticks = true, .whole = whole });
    }

    /// Whether a statement ends at the semicolon this text ends with.
    ///
    /// It does, except inside the body of a trigger, which is statements of its
    /// own between BEGIN and END. Cut at the first of those, `CREATE TRIGGER`
    /// was `incomplete input` and its `END` a statement by itself - typed into
    /// the editor, written by the trigger form, and replayed by the rebuild of
    /// any table that had one, which is how a table with a trigger came to be a
    /// table that could not be altered.
    ///
    /// SQLite has the answer and gives it without needing the tables to exist.
    /// It wants the text as a C string, so only a statement that names a
    /// trigger is copied to be asked about: a script of a million inserts is
    /// not held a second time for the sake of the one statement that needs it.
    fn whole(arena: std.mem.Allocator, so_far: []const u8) bool {
        if (std.ascii.findIgnoreCase(so_far, "TRIGGER") == null) {
            return true;
        }
        const zero = arena.dupeSentinel(u8, so_far, 0) catch return true;
        return c.sqlite3_complete(zero.ptr) != 0;
    }

    pub fn ddl(_: *Db) db.Ddl {
        return .{ .sqlite = .{} };
    }
};

pub const Rows = struct {
    owner: *Db,
    stmt: ?*c.Stmt,
    changed_before: ?i64 = null,
    changed: i64 = 0,
    /// Walked to its end, which is where a sheet is looked at.
    done: bool = false,

    pub fn next(self: *Rows) db.Error!bool {
        if (self.changed_before == null) {
            self.changed_before = c.sqlite3_total_changes(self.owner.handle);
        }
        return switch (c.sqlite3_step(self.stmt)) {
            c.ROW => true,
            c.DONE => blk: {
                self.changed = c.sqlite3_total_changes(self.owner.handle) - (self.changed_before orelse 0);
                self.done = true;
                try self.owner.settled();
                break :blk false;
            },
            else => self.owner.refused(),
        };
    }

    /// The single value of the next row, for one-column internal queries.
    fn step_or_null(self: *Rows) db.Error!?db.Value {
        return if (try self.next()) self.value(0) else null;
    }

    pub fn close(self: *Rows) void {
        _ = c.sqlite3_finalize(self.stmt);
        self.stmt = null;
        // A statement that was not walked to its end is ended by this, and what
        // it changed by then is changed. There is nobody here to tell if the
        // file cannot be written; the next change says so.
        if (!self.done) {
            self.done = true;
            self.owner.settled() catch {};
        }
    }

    pub fn columnCount(self: *Rows) usize {
        return @intCast(c.sqlite3_column_count(self.stmt));
    }

    pub fn name(self: *Rows, at: usize) []const u8 {
        const ptr = c.sqlite3_column_name(self.stmt, @intCast(at)) orelse return "";
        return std.mem.span(ptr);
    }

    pub fn value(self: *Rows, at: usize) db.Value {
        const index: c_int = @intCast(at);
        const len: usize = @intCast(c.sqlite3_column_bytes(self.stmt, index));
        return switch (c.sqlite3_column_type(self.stmt, index)) {
            c.INTEGER => .{ .int = c.sqlite3_column_int64(self.stmt, index) },
            c.FLOAT => .{ .float = c.sqlite3_column_double(self.stmt, index) },
            c.BLOB => .{ .blob = if (c.sqlite3_column_blob(self.stmt, index)) |p| p[0..len] else "" },
            c.NULL => .null,
            else => .{ .text = if (c.sqlite3_column_text(self.stmt, index)) |p| p[0..len] else "" },
        };
    }

    /// SQLite decides alignment per value, so the column is numeric when its
    /// declared type says so.
    pub fn isNumeric(self: *Rows, at: usize) bool {
        const declared = c.sqlite3_column_decltype(self.stmt, @intCast(at)) orelse return false;
        const text_type = std.mem.span(declared);
        for ([_][]const u8{ "INT", "REAL", "FLOA", "DOUB", "NUM", "DEC" }) |needle| {
            if (std.ascii.findIgnoreCase(text_type, needle) != null) {
                return true;
            }
        }
        return false;
    }

    pub fn sourceTable(self: *Rows, at: usize) []const u8 {
        const ptr = c.sqlite3_column_table_name(self.stmt, @intCast(at)) orelse return "";
        return std.mem.span(ptr);
    }

    pub fn sourceColumn(self: *Rows, at: usize) []const u8 {
        const ptr = c.sqlite3_column_origin_name(self.stmt, @intCast(at)) orelse return "";
        return std.mem.span(ptr);
    }

    pub fn affected(self: *Rows) i64 {
        return self.changed;
    }
};

// ---------------------------------------------------------------------- DDL

pub const Ddl = struct {
    const TEMPORARY = "krtek_rebuild";

    pub fn types(_: Ddl) []const []const u8 {
        return &[_][]const u8{ "TEXT", "INTEGER", "REAL", "BLOB", "NUMERIC", "" };
    }

    /// The body of a CREATE TABLE, brackets included.
    fn body(out: *List, a: std.mem.Allocator, cols: []const db.Column, keys: []const db.ForeignKey) !void {
        var primary: usize = 0;
        for (cols) |column| {
            primary += @intFromBool(column.pk);
        }
        try out.appendSlice(a, " (\n");
        for (cols, 0..) |column, i| {
            if (i != 0) {
                try out.appendSlice(a, ",\n");
            }
            try out.appendSlice(a, "\t");
            try db.quoteName(out, a, column.name);
            if (column.type.len != 0) {
                try out.append(a, ' ');
                try out.appendSlice(a, column.type);
            }
            // A single INTEGER primary key has to be inline to become the rowid.
            if (column.pk and primary == 1) {
                try out.appendSlice(a, " PRIMARY KEY");
            }
            if (column.notnull) {
                try out.appendSlice(a, " NOT NULL");
            }
            if (column.unique) {
                try out.appendSlice(a, " UNIQUE");
            }
            if (column.dflt) |value| {
                if (value.len != 0) {
                    try out.appendSlice(a, " DEFAULT ");
                    try out.appendSlice(a, value);
                }
            }
        }
        if (primary > 1) {
            try out.appendSlice(a, ",\n\tPRIMARY KEY (");
            var written: usize = 0;
            for (cols) |column| {
                if (!column.pk) {
                    continue;
                }
                if (written != 0) {
                    try out.appendSlice(a, ", ");
                }
                try db.quoteName(out, a, column.name);
                written += 1;
            }
            try out.append(a, ')');
        }
        for (keys) |key| {
            try out.appendSlice(a, ",\n\tFOREIGN KEY (");
            try db.quoteName(out, a, key.column);
            try out.appendSlice(a, ") REFERENCES ");
            try db.quoteName(out, a, key.target_table);
            if (key.target_column.len != 0) {
                try out.append(a, '(');
                try db.quoteName(out, a, key.target_column);
                try out.append(a, ')');
            }
            if (!std.mem.eql(u8, key.on_update, "NO ACTION")) {
                try out.appendSlice(a, " ON UPDATE ");
                try out.appendSlice(a, key.on_update);
            }
            if (!std.mem.eql(u8, key.on_delete, "NO ACTION")) {
                try out.appendSlice(a, " ON DELETE ");
                try out.appendSlice(a, key.on_delete);
            }
        }
        try out.appendSlice(a, "\n)");
    }

    pub fn createTable(_: Ddl, out: *List, a: std.mem.Allocator, table: db.Table, cols: []const db.Column, keys: []const db.ForeignKey) !void {
        try out.appendSlice(a, "CREATE TABLE ");
        try db.quoteName(out, a, table.name);
        try body(out, a, cols, keys);
        try out.appendSlice(a, ";\n");
    }

    /// How a rebuild begins, and how it ends. Foreign keys have to be off while
    /// the table is dropped - with them on, dropping it deletes its rows first,
    /// and every row elsewhere that cascades from one of them - and the setting
    /// cannot be changed inside a transaction, so it is outside the one the
    /// rebuild runs in and is not taken back with it.
    const KEYS_OFF = "PRAGMA foreign_keys = off";
    const KEYS_ON = "PRAGMA foreign_keys = on";

    /// A rebuild that stopped half way never reached the line that turns the
    /// keys back on. The rollback put the table back and left the session with
    /// nothing enforced: a row could then be given a parent that does not
    /// exist, and a parent deleted from under its rows, with no word about
    /// either until the program was started again.
    pub fn afterFailure(_: Ddl, script: []const u8) []const u8 {
        return if (std.mem.startsWith(u8, script, KEYS_OFF)) KEYS_ON else "";
    }

    /// SQLite cannot change a column, so the table is written again and the rows
    /// copied over. See https://sqlite.org/lang_altertable.html.
    pub fn alterTable(_: Ddl, out: *List, a: std.mem.Allocator, table: db.Table, new_name: []const u8, cols: []const db.Column, context: db.AlterContext) !void {
        try out.appendSlice(a, KEYS_OFF ++ ";\nBEGIN;\nCREATE TABLE ");
        try db.quoteName(out, a, TEMPORARY);
        try body(out, a, cols, context.keys);
        try out.appendSlice(a, ";\n");

        var copied: usize = 0;
        for (cols) |column| {
            copied += @intFromBool(column.original.len != 0);
        }
        if (copied != 0) {
            try out.appendSlice(a, "INSERT INTO ");
            try db.quoteName(out, a, TEMPORARY);
            try out.appendSlice(a, " (");
            var written: usize = 0;
            for (cols) |column| {
                if (column.original.len == 0) {
                    continue;
                }
                if (written != 0) {
                    try out.appendSlice(a, ", ");
                }
                try db.quoteName(out, a, column.name);
                written += 1;
            }
            try out.appendSlice(a, ")\n  SELECT ");
            written = 0;
            for (cols) |column| {
                if (column.original.len == 0) {
                    continue;
                }
                if (written != 0) {
                    try out.appendSlice(a, ", ");
                }
                try db.quoteName(out, a, column.original);
                written += 1;
            }
            try out.appendSlice(a, " FROM ");
            try db.quoteName(out, a, table.name);
            try out.appendSlice(a, ";\n");
        }
        try out.appendSlice(a, "DROP TABLE ");
        try db.quoteName(out, a, table.name);
        try out.appendSlice(a, ";\nALTER TABLE ");
        try db.quoteName(out, a, TEMPORARY);
        try out.appendSlice(a, " RENAME TO ");
        try db.quoteName(out, a, if (new_name.len != 0) new_name else table.name);
        try out.appendSlice(a, ";\n");
        for (context.replay) |statement| {
            try out.appendSlice(a, statement);
            try out.appendSlice(a, ";\n");
        }
        try out.appendSlice(a, "COMMIT;\n" ++ KEYS_ON ++ ";\n");
    }

    /// Adding a key means the same rebuild, with the key in the new definition.
    pub fn addForeignKey(self: Ddl, out: *List, a: std.mem.Allocator, table: db.Table, key: db.ForeignKey, context: db.AlterContext) !void {
        var keys: std.ArrayList(db.ForeignKey) = .empty;
        try keys.appendSlice(a, context.keys);
        try keys.append(a, key);
        try self.alterTable(out, a, table, "", context.columns, .{
            .keys = keys.items,
            .replay = context.replay,
        });
    }

    pub fn createIndex(_: Ddl, out: *List, a: std.mem.Allocator, table: db.Table, name: []const u8, cols: []const []const u8, unique: bool, where: []const u8) !void {
        try out.appendSlice(a, if (unique) "CREATE UNIQUE INDEX " else "CREATE INDEX ");
        try db.quoteName(out, a, name);
        try out.appendSlice(a, " ON ");
        try db.quoteName(out, a, table.name);
        try out.appendSlice(a, " (");
        for (cols, 0..) |column, i| {
            if (i != 0) {
                try out.appendSlice(a, ", ");
            }
            try db.quoteName(out, a, column);
        }
        try out.append(a, ')');
        if (where.len != 0) {
            try out.appendSlice(a, " WHERE ");
            try out.appendSlice(a, where);
        }
        try out.appendSlice(a, ";\n");
    }

    pub fn createView(_: Ddl, out: *List, a: std.mem.Allocator, table: db.Table, select: []const u8) !void {
        try out.appendSlice(a, "CREATE VIEW ");
        try db.quoteName(out, a, table.name);
        try out.appendSlice(a, " AS ");
        try out.appendSlice(a, select);
        try out.appendSlice(a, ";\n");
    }

    pub fn createTrigger(_: Ddl, out: *List, a: std.mem.Allocator, table: db.Table, name: []const u8, when: []const u8, event: []const u8, condition: []const u8, action: []const u8) !void {
        try out.appendSlice(a, "CREATE TRIGGER ");
        try db.quoteName(out, a, name);
        try out.print(a, " {s} {s} ON ", .{ when, event });
        try db.quoteName(out, a, table.name);
        if (condition.len != 0) {
            try out.appendSlice(a, " WHEN ");
            try out.appendSlice(a, condition);
        }
        try out.appendSlice(a, " BEGIN ");
        try out.appendSlice(a, if (action.len != 0) action else "SELECT 1");
        try out.appendSlice(a, "; END;\n");
    }

    pub fn renameTable(_: Ddl, out: *List, a: std.mem.Allocator, table: db.Table, to: []const u8) !void {
        try out.appendSlice(a, "ALTER TABLE ");
        try db.quoteName(out, a, table.name);
        try out.appendSlice(a, " RENAME TO ");
        try db.quoteName(out, a, to);
        try out.appendSlice(a, ";\n");
    }

    pub fn copyTable(_: Ddl, out: *List, a: std.mem.Allocator, table: db.Table, to: []const u8, with_rows: bool) !void {
        try out.appendSlice(a, "CREATE TABLE ");
        try db.quoteName(out, a, to);
        try out.appendSlice(a, " AS SELECT * FROM ");
        try db.quoteName(out, a, table.name);
        if (!with_rows) {
            try out.appendSlice(a, " WHERE 0");
        }
        try out.appendSlice(a, ";\n");
    }

    pub fn dropObject(_: Ddl, out: *List, a: std.mem.Allocator, kind: db.Kind, table: db.Table) !void {
        try out.appendSlice(a, if (kind == .view) "DROP VIEW " else "DROP TABLE ");
        try db.quoteName(out, a, table.name);
        try out.appendSlice(a, ";\n");
    }

    pub fn truncate(_: Ddl, out: *List, a: std.mem.Allocator, table: db.Table) !void {
        try out.appendSlice(a, "DELETE FROM ");
        try db.quoteName(out, a, table.name);
        try out.appendSlice(a, ";\n");
    }
};

// ------------------------------------------------------------------- tests
//
// Against the engine itself, in memory. Most of what is here is a question put
// to SQLite's pragmas, and only SQLite can say whether it was the right
// question: what the statements look like is tested where they are written,
// and that tells nothing about what comes back.

const testing = std.testing;

/// A database in memory with these statements run in it, and somewhere to keep
/// what it is asked until the test is over.
const Bench = struct {
    arena: std.heap.ArenaAllocator,
    conn: *Db,

    fn init(sql: []const u8) !Bench {
        var report: List = .empty;
        defer report.deinit(testing.allocator);
        const conn = try Db.open(testing.allocator, ":memory:", &report);
        errdefer conn.close();
        try conn.exec(sql);
        return .{ .arena = .init(testing.allocator), .conn = conn };
    }

    fn deinit(self: *Bench) void {
        self.conn.close();
        self.arena.deinit();
    }

    fn a(self: *Bench) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// The first column of every row, joined with a space - which is short
    /// enough to read in an expectation and says what order they came in.
    fn column(self: *Bench, sql: []const u8) ![]const u8 {
        var out: List = .empty;
        var rows = (try self.conn.ask(sql)) orelse return "";
        defer rows.close();
        while (try rows.next()) {
            if (out.items.len != 0) {
                try out.append(self.a(), ' ');
            }
            try out.appendSlice(self.a(), try Db.text(self.a(), rows.value(0)));
        }
        return out.items;
    }
};

test "the list is the tables and the views by name, without SQLite's own" {
    // AUTOINCREMENT makes `sqlite_sequence`, which is SQLite's and is left out.
    // `sqlitedata` only starts the same way: the underscore in the pattern is
    // an underscore, not LIKE's any-one-character.
    var bench = try Bench.init(
        \\CREATE TABLE b (id INTEGER PRIMARY KEY AUTOINCREMENT);
        \\CREATE TABLE "A" (x);
        \\CREATE TABLE sqlitedata (x);
        \\CREATE VIEW c AS SELECT x FROM "A";
    );
    defer bench.deinit();
    const found = try bench.conn.objects(bench.a(), "");
    try testing.expectEqual(@as(usize, 4), found.len);
    try testing.expectEqualStrings("A", found[0].name);
    try testing.expectEqualStrings("b", found[1].name);
    try testing.expectEqualStrings("c", found[2].name);
    try testing.expectEqualStrings("sqlitedata", found[3].name);
    try testing.expectEqual(db.Kind.table, found[0].kind);
    try testing.expectEqual(db.Kind.view, found[2].kind);
    // Never an estimate: SQLite has none, and a wrong one is worse than none.
    try testing.expectEqual(@as(?i64, null), found[0].rows);
}

test "a column says its type, whether it may be empty, its default and its key" {
    var bench = try Bench.init(
        \\CREATE TABLE books (
        \\  id INTEGER PRIMARY KEY,
        \\  title TEXT NOT NULL,
        \\  isbn TEXT UNIQUE,
        \\  year INTEGER DEFAULT 1900,
        \\  note,
        \\  shelf TEXT, room TEXT,
        \\  UNIQUE (shelf, room)
        \\);
    );
    defer bench.deinit();
    const cols = try bench.conn.columns(bench.a(), .{ .name = "books" });
    try testing.expectEqual(@as(usize, 7), cols.len);

    try testing.expectEqualStrings("id", cols[0].name);
    try testing.expectEqualStrings("INTEGER", cols[0].type);
    try testing.expect(cols[0].pk);
    try testing.expect(!cols[0].unique);

    try testing.expect(cols[1].notnull);
    try testing.expect(!cols[1].pk);
    try testing.expectEqual(@as(?[]const u8, null), cols[1].dflt);

    // A column's own UNIQUE is an index SQLite made, and the only place it is
    // written down - a rebuild that did not carry it would lose it.
    try testing.expect(cols[2].unique);
    try testing.expectEqualStrings("1900", cols[3].dflt.?);
    // A column with no type has none, rather than one made up for it.
    try testing.expectEqualStrings("", cols[4].type);
    // Two columns unique together are neither of them unique alone.
    try testing.expect(!cols[5].unique);
    try testing.expect(!cols[6].unique);
    // What a column was called before a form touched it is what it is called.
    try testing.expectEqualStrings("title", cols[1].original);
}

test "an index says what made it and what it is on" {
    var bench = try Bench.init(
        \\CREATE TABLE t (code TEXT PRIMARY KEY, a, b UNIQUE, c);
        \\CREATE INDEX plain ON t (a, c);
        \\CREATE UNIQUE INDEX one ON t (c);
        \\CREATE INDEX some ON t (a) WHERE a > 0;
        \\CREATE INDEX folded ON t (lower(a));
    );
    defer bench.deinit();
    const found = try bench.conn.indexes(bench.a(), .{ .name = "t" });
    try testing.expectEqual(@as(usize, 6), found.len);
    var seen: usize = 0;
    for (found) |index| {
        if (std.mem.eql(u8, index.name, "plain")) {
            try testing.expectEqualStrings("INDEX", index.kind);
            try testing.expectEqualStrings("a, c", index.columns);
            try testing.expect(!index.partial);
            seen += 1;
        } else if (std.mem.eql(u8, index.name, "one")) {
            try testing.expectEqualStrings("UNIQUE", index.kind);
            seen += 1;
        } else if (std.mem.eql(u8, index.name, "some")) {
            try testing.expect(index.partial);
            seen += 1;
        } else if (std.mem.eql(u8, index.name, "folded")) {
            // No column to name: it is on what an expression comes to.
            try testing.expectEqualStrings("(expression)", index.columns);
            seen += 1;
        } else if (std.mem.eql(u8, index.columns, "code")) {
            // The two SQLite made for itself have names nobody chose.
            try testing.expectEqualStrings("PRIMARY", index.kind);
            seen += 1;
        } else if (std.mem.eql(u8, index.columns, "b")) {
            try testing.expectEqualStrings("UNIQUE", index.kind);
            seen += 1;
        }
    }
    try testing.expectEqual(@as(usize, 6), seen);
}

test "a foreign key says where it points and what it does when that changes" {
    var bench = try Bench.init(
        \\CREATE TABLE authors (id INTEGER PRIMARY KEY);
        \\CREATE TABLE shelves (id INTEGER PRIMARY KEY);
        \\CREATE TABLE books (
        \\  id INTEGER PRIMARY KEY,
        \\  author INTEGER REFERENCES authors(id) ON DELETE CASCADE ON UPDATE SET NULL,
        \\  shelf INTEGER REFERENCES shelves(id)
        \\);
    );
    defer bench.deinit();
    const keys = try bench.conn.foreignKeys(bench.a(), .{ .name = "books" });
    try testing.expectEqual(@as(usize, 2), keys.len);
    for (keys) |key| {
        if (std.mem.eql(u8, key.column, "author")) {
            try testing.expectEqualStrings("authors", key.target_table);
            try testing.expectEqualStrings("id", key.target_column);
            try testing.expectEqualStrings("CASCADE", key.on_delete);
            try testing.expectEqualStrings("SET NULL", key.on_update);
        } else {
            try testing.expectEqualStrings("shelf", key.column);
            try testing.expectEqualStrings("shelves", key.target_table);
            // Said in the words the generator leaves out, so one that was not
            // written does not come back written.
            try testing.expectEqualStrings("NO ACTION", key.on_delete);
            try testing.expectEqualStrings("NO ACTION", key.on_update);
        }
    }
    // And a table with none has none, rather than an error.
    try testing.expectEqual(@as(usize, 0), (try bench.conn.foreignKeys(bench.a(), .{ .name = "authors" })).len);
}

test "a row is addressed by its rowid, by its key where it has none, and not at all in a view" {
    var bench = try Bench.init(
        \\CREATE TABLE plain (name TEXT);
        \\CREATE TABLE keyed (b TEXT, a TEXT, x, PRIMARY KEY (a, b)) WITHOUT ROWID;
        \\CREATE VIEW seen AS SELECT name FROM plain;
    );
    defer bench.deinit();

    const hidden = try bench.conn.rowKey(bench.a(), .{ .name = "plain" });
    try testing.expect(hidden.usable());
    try testing.expect(hidden.hidden);
    try testing.expectEqualStrings("rowid", hidden.expression);

    // In the order of the key, which is not the order of the columns.
    const keyed = try bench.conn.rowKey(bench.a(), .{ .name = "keyed" });
    try testing.expect(!keyed.hidden);
    try testing.expectEqual(@as(usize, 2), keyed.columns.len);
    try testing.expectEqualStrings("a", keyed.columns[0]);
    try testing.expectEqualStrings("b", keyed.columns[1]);

    // Nothing addresses a row of a view, so nothing offers to change one.
    const view = try bench.conn.rowKey(bench.a(), .{ .name = "seen" });
    try testing.expect(!view.usable());
}

test "a value comes back as what SQLite holds, and a column says where it is from" {
    var bench = try Bench.init(
        \\CREATE TABLE t (n INTEGER, f REAL, s TEXT, b BLOB, e, price DECIMAL(10,2));
        \\INSERT INTO t VALUES (42, 1.5, 'žluť', x'00ff', NULL, '12.50');
    );
    defer bench.deinit();
    var rows = (try bench.conn.query("SELECT n, f, s, b, e, price, n + 1 AS more, s AS label FROM t", null)).?;
    defer rows.close();
    try testing.expect(try rows.next());
    try testing.expectEqual(@as(usize, 8), rows.columnCount());
    try testing.expectEqual(@as(i64, 42), rows.value(0).int);
    try testing.expectEqual(@as(f64, 1.5), rows.value(1).float);
    try testing.expectEqualStrings("žluť", rows.value(2).text);
    // Bytes, a zero among them: by length, not up to the first zero.
    try testing.expectEqualSlices(u8, &.{ 0x00, 0xff }, rows.value(3).blob);
    try testing.expect(rows.value(4) == .null);

    // By the declared type, because SQLite decides per value: a DECIMAL
    // column holding text is still a column of numbers.
    try testing.expect(rows.isNumeric(0));
    try testing.expect(rows.isNumeric(1));
    try testing.expect(!rows.isNumeric(2));
    try testing.expect(rows.isNumeric(5));
    try testing.expect(!rows.isNumeric(6));

    // A column of a table says which, under its own name whatever it was
    // called here; something worked out belongs to no table, and that is
    // what keeps it from being offered for editing.
    try testing.expectEqualStrings("t", rows.sourceTable(0));
    try testing.expectEqualStrings("more", rows.name(6));
    try testing.expectEqualStrings("", rows.sourceTable(6));
    try testing.expectEqualStrings("label", rows.name(7));
    try testing.expectEqualStrings("s", rows.sourceColumn(7));

    try testing.expect(!try rows.next());
}

test "a batch is walked a statement at a time, and each says what it changed" {
    var bench = try Bench.init("CREATE TABLE t (n INTEGER);");
    defer bench.deinit();
    const batch = "INSERT INTO t VALUES (1), (2), (3); -- three of them\nSELECT count(*) FROM t;  ";
    var rest: []const u8 = batch;

    var first = (try bench.conn.query(rest, &rest)).?;
    try testing.expect(!try first.next());
    try testing.expectEqual(@as(i64, 3), first.affected());
    first.close();
    try testing.expect(std.mem.startsWith(u8, rest, " -- three of them"));

    var second = (try bench.conn.query(rest, &rest)).?;
    try testing.expect(try second.next());
    try testing.expectEqual(@as(i64, 3), second.value(0).int);
    try testing.expect(!try second.next());
    // A statement that only read changed nothing, whatever the one before did.
    try testing.expectEqual(@as(i64, 0), second.affected());
    second.close();

    // What is left is space, which is not a statement and not an error.
    try testing.expectEqual(@as(?db.Rows, null), try bench.conn.query(rest, &rest));
    try testing.expectEqual(@as(usize, 0), rest.len);
}

test "what SQLite refuses is what the message says" {
    var bench = try Bench.init("CREATE TABLE t (n INTEGER NOT NULL);");
    defer bench.deinit();
    try testing.expectError(error.Driver, bench.conn.exec("SELECT * FROM missing"));
    try testing.expect(std.mem.find(u8, bench.conn.message(), "no such table: missing") != null);
    try testing.expectError(error.Driver, bench.conn.query("SELEC 1", null));
    try testing.expect(std.mem.find(u8, bench.conn.message(), "syntax error") != null);
    // Refused while running rather than while being read: the cursor says so.
    var rows = (try bench.conn.query("INSERT INTO t VALUES (NULL)", null)).?;
    defer rows.close();
    try testing.expectError(error.Driver, rows.next());
    try testing.expect(std.mem.find(u8, bench.conn.message(), "NOT NULL") != null);
}

test "a statement that will not end can be given up on, and the connection is still good" {
    var bench = try Bench.init("CREATE TABLE t (n INTEGER);");
    defer bench.deinit();
    const Watcher = struct {
        begun: usize = 0,
        asked: usize = 0,

        fn keepGoing(context: *anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.asked += 1;
            return false;
        }

        fn begin(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.begun += 1;
        }
    };
    var watcher = Watcher{};
    bench.conn.watch(.{ .context = &watcher, .keep_going = Watcher.keepGoing, .begin = Watcher.begin });

    var rows = (try bench.conn.query(
        "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n) SELECT count(*) FROM n",
        null,
    )).?;
    try testing.expectError(error.Driver, rows.next());
    rows.close();
    try testing.expect(std.mem.find(u8, bench.conn.message(), "interrupted") != null);
    // Told once that a statement began, and asked at least once whether to go on.
    try testing.expectEqual(@as(usize, 1), watcher.begun);
    try testing.expect(watcher.asked >= 1);

    // Nobody watching: the next one runs to its end.
    bench.conn.watch(null);
    try bench.conn.exec("INSERT INTO t VALUES (1)");
    try testing.expectEqual(@as(?i64, 1), bench.conn.rowCount(.{ .name = "t" }));
}

test "a transaction is open from BEGIN until it is ended" {
    var bench = try Bench.init("CREATE TABLE t (n INTEGER);");
    defer bench.deinit();
    try testing.expect(!bench.conn.inTransaction());
    try bench.conn.exec("BEGIN");
    try bench.conn.exec("INSERT INTO t VALUES (1)");
    try testing.expect(bench.conn.inTransaction());
    try bench.conn.exec("ROLLBACK");
    try testing.expect(!bench.conn.inTransaction());
    try testing.expectEqual(@as(?i64, 0), bench.conn.rowCount(.{ .name = "t" }));
    // A table that is not there has no count, which is not a count of none.
    try testing.expectEqual(@as(?i64, null), bench.conn.rowCount(.{ .name = "missing" }));
}

test "the definition is the statement as it was written" {
    var bench = try Bench.init(
        \\CREATE TABLE t (n INTEGER);
        \\CREATE VIEW v AS SELECT n FROM t WHERE n > 0;
    );
    defer bench.deinit();
    try testing.expectEqualStrings("CREATE TABLE t (n INTEGER)", (try bench.conn.definition(bench.a(), .{ .name = "t" })).?);
    try testing.expectEqualStrings("CREATE VIEW v AS SELECT n FROM t WHERE n > 0", (try bench.conn.definition(bench.a(), .{ .name = "v" })).?);
    try testing.expectEqual(@as(?[]const u8, null), try bench.conn.definition(bench.a(), .{ .name = "missing" }));
}

test "a rebuild keeps the rows, the indexes, the trigger and the keys, and a renamed column takes its index with it" {
    var bench = try Bench.init(
        \\CREATE TABLE authors (id INTEGER PRIMARY KEY);
        \\INSERT INTO authors VALUES (1);
        \\CREATE TABLE log (what TEXT);
        \\CREATE TABLE books (
        \\  id INTEGER PRIMARY KEY,
        \\  title TEXT NOT NULL,
        \\  isbn TEXT UNIQUE,
        \\  year INTEGER,
        \\  author INTEGER REFERENCES authors(id) ON DELETE CASCADE
        \\);
        \\CREATE INDEX by_title ON books (title);
        \\CREATE INDEX recent ON books (year) WHERE year > 1950;
        \\CREATE TRIGGER noted AFTER INSERT ON books BEGIN INSERT INTO log VALUES ('added'); END;
        \\INSERT INTO books VALUES (1, 'RUR', 'x-1', 1920, 1), (2, 'Žert', 'x-2', 1967, 1);
        \\DELETE FROM log;
    );
    defer bench.deinit();
    const table = db.Table{ .name = "books" };

    // What the alter form does: the columns as they are, one of them renamed
    // and one that was not there before.
    const before = try bench.conn.columns(bench.a(), table);
    var cols: std.ArrayList(db.Column) = .empty;
    try cols.appendSlice(bench.a(), before);
    cols.items[1].name = "name";
    try cols.append(bench.a(), .{ .name = "pages", .type = "INTEGER", .dflt = "0" });

    const context = try bench.conn.alterContext(bench.a(), table, cols.items);
    var script: List = .empty;
    try (Ddl{}).alterTable(&script, bench.a(), table, "", cols.items, context);
    try bench.conn.exec(script.items);

    // Every row, under the new name, with the default in the new column.
    try testing.expectEqualStrings("RUR Žert", try bench.column("SELECT name FROM books ORDER BY id"));
    try testing.expectEqualStrings("0 0", try bench.column("SELECT pages FROM books ORDER BY id"));
    try testing.expectEqualStrings("", try bench.column("SELECT name FROM sqlite_master WHERE name = 'krtek_rebuild'"));

    // The plain index was written again for the column's new name; the
    // partial one and the trigger were put back as they were written.
    const after = try bench.conn.indexes(bench.a(), table);
    var named: usize = 0;
    for (after) |index| {
        if (std.mem.eql(u8, index.name, "by_title")) {
            try testing.expectEqualStrings("name", index.columns);
            named += 1;
        } else if (std.mem.eql(u8, index.name, "recent")) {
            try testing.expect(index.partial);
            named += 1;
        }
    }
    try testing.expectEqual(@as(usize, 2), named);
    try bench.conn.exec("INSERT INTO books (name, isbn, author) VALUES ('Krakatit', 'x-3', 1)");
    try testing.expectEqualStrings("added", try bench.column("SELECT what FROM log"));

    // The column's own UNIQUE and NOT NULL, which live nowhere but in the
    // table that was dropped, are in the one that replaced it.
    try testing.expectError(error.Driver, bench.conn.exec("INSERT INTO books (name, isbn) VALUES ('again', 'x-1')"));
    try testing.expectError(error.Driver, bench.conn.exec("INSERT INTO books (isbn) VALUES ('x-9')"));

    // The key is still a key and keys are being enforced again: the script
    // turns them off to move the rows, and has to turn them back on.
    const keys = try bench.conn.foreignKeys(bench.a(), table);
    try testing.expectEqual(@as(usize, 1), keys.len);
    try testing.expectEqualStrings("CASCADE", keys[0].on_delete);
    try testing.expectEqualStrings("1", try bench.column("PRAGMA foreign_keys"));
    try testing.expectError(error.Driver, bench.conn.exec("INSERT INTO books (name, author) VALUES ('orphan', 99)"));
    try bench.conn.exec("DELETE FROM authors");
    try testing.expectEqualStrings("0", try bench.column("SELECT count(*) FROM books"));
}

test "adding a key is the same rebuild with the key in it" {
    var bench = try Bench.init(
        \\CREATE TABLE authors (id INTEGER PRIMARY KEY);
        \\INSERT INTO authors VALUES (1);
        \\CREATE TABLE books (id INTEGER PRIMARY KEY, author INTEGER);
        \\INSERT INTO books VALUES (1, 1);
    );
    defer bench.deinit();
    const table = db.Table{ .name = "books" };
    const cols = try bench.conn.columns(bench.a(), table);
    const context = try bench.conn.alterContext(bench.a(), table, cols);
    var script: List = .empty;
    try (Ddl{}).addForeignKey(&script, bench.a(), table, .{
        .column = "author",
        .target_table = "authors",
        .target_column = "id",
        .on_delete = "SET NULL",
    }, context);
    try bench.conn.exec(script.items);

    try testing.expectEqualStrings("1", try bench.column("SELECT author FROM books"));
    try bench.conn.exec("DELETE FROM authors");
    try testing.expectEqualStrings("", try bench.column("SELECT author FROM books"));
}

test "a page that is asked for is the page that comes back, and a change lands on its row" {
    // The whole of the structured path, as the grid uses it: the request is
    // put into SQL by the shared renderer and what comes back is SQLite's.
    var bench = try Bench.init(
        \\CREATE TABLE books (title TEXT, year INTEGER);
        \\INSERT INTO books VALUES ('RUR', 1920), ('Žert', 1967), ('Krakatit', 1924), ('Saturnin', 1942);
    );
    defer bench.deinit();
    const conn = db.Db{ .sqlite = bench.conn };
    const table = db.Table{ .name = "books" };

    var rows = (try conn.select(.{
        .table = table,
        .extra = "rowid",
        .extra_as = "rowid",
        .where = &.{.{ .column = "year", .op = .lt, .value = "1950" }},
        .order = "year",
        .descending = true,
        .limit = 2,
        .offset = 1,
    })).?;
    try testing.expect(try rows.next());
    // The hidden key first, then the row: Krakatit is the third that was put in.
    try testing.expectEqual(@as(i64, 3), rows.value(0).int);
    try testing.expectEqualStrings("Krakatit", rows.value(1).text);
    try testing.expect(try rows.next());
    try testing.expectEqualStrings("RUR", rows.value(1).text);
    try testing.expect(!try rows.next());
    rows.close();

    try testing.expectEqual(@as(?i64, 3), conn.count(.{
        .table = table,
        .where = &.{.{ .column = "year", .op = .lt, .value = "1950" }},
        // Counting is of what matches, not of the page it would be shown on.
        .limit = 2,
        .offset = 1,
    }));

    try conn.apply(.{
        .kind = .update,
        .table = table,
        .cells = &.{.{ .column = "year", .value = "1921" }},
        .where = &.{.{ .column = "rowid", .value = "1" }},
    });
    try conn.apply(.{ .kind = .delete, .table = table, .where = &.{.{ .column = "rowid", .value = "2" }} });
    try conn.apply(.{
        .kind = .insert,
        .table = table,
        .cells = &.{ .{ .column = "title", .value = "it's" }, .{ .column = "year", .value = null } },
    });
    try testing.expectEqualStrings("RUR Krakatit Saturnin it's", try bench.column("SELECT title FROM books ORDER BY rowid"));
    try testing.expectEqualStrings("1921", try bench.column("SELECT year FROM books WHERE title = 'RUR'"));
    try testing.expectEqualStrings("1", try bench.column("SELECT count(*) FROM books WHERE year IS NULL"));
}

test "the settings say where the file is and that it is whole" {
    var bench = try Bench.init("CREATE TABLE t (n INTEGER);");
    defer bench.deinit();
    const found = try bench.conn.settings(bench.a());
    try testing.expectEqualStrings("file", found[0].label);
    try testing.expectEqualStrings(":memory:", found[0].value);
    try testing.expectEqualStrings("integrity", found[found.len - 1].label);
    try testing.expectEqualStrings("ok", found[found.len - 1].value);
    var keys_on = false;
    for (found) |setting| {
        if (std.mem.eql(u8, setting.label, "foreign_keys")) {
            // Turned on when the file is opened, which SQLite does not do itself.
            keys_on = std.mem.eql(u8, setting.value, "1");
        }
    }
    try testing.expect(keys_on);
}

test "a file that is not a database is refused when it is opened, with the reason" {
    var name: [64]u8 = undefined;
    const path = try std.mem.printSentinel(&name, "/tmp/krtek-sqlite-test-{d}", .{std.c.getpid()}, 0);
    const file = std.c.fopen(path, "wb") orelse return error.CannotCreate;
    _ = std.c.fwrite("this is a letter, not a database", 1, 32, file);
    _ = std.c.fclose(file);
    defer _ = std.c.unlink(path);

    var report: List = .empty;
    defer report.deinit(testing.allocator);
    try testing.expectError(error.Driver, Db.open(testing.allocator, path, &report));
    try testing.expect(std.mem.find(u8, report.items, "not a database") != null);
    try testing.expect(std.mem.find(u8, report.items, "krtek-sqlite-test") != null);
}

test "a trigger is one statement, with the semicolons its body has" {
    var bench = try Bench.init(
        \\CREATE TABLE books (id INTEGER PRIMARY KEY, title TEXT, state TEXT);
        \\CREATE TABLE log (what TEXT);
    );
    defer bench.deinit();
    const batch =
        \\CREATE TRIGGER noted AFTER INSERT ON books BEGIN
        \\  INSERT INTO log VALUES ('added');
        \\  UPDATE books SET state = CASE WHEN NEW.title = '' THEN 'empty' ELSE 'ok' END WHERE id = NEW.id;
        \\END;
        \\INSERT INTO books (title) VALUES ('RUR'); -- which sets it off
        \\SELECT 'a trigger; in a string' AS said
    ;
    const parts = try bench.conn.split(bench.a(), batch);
    try testing.expectEqual(@as(usize, 3), parts.len);
    // Up to its own END and no further: the END of a CASE is not it.
    try testing.expect(std.mem.startsWith(u8, parts[0].sql, "CREATE TRIGGER noted"));
    try testing.expect(std.mem.endsWith(u8, parts[0].sql, "WHERE id = NEW.id;\nEND"));
    try testing.expectEqualStrings("INSERT INTO books (title) VALUES ('RUR')", parts[1].sql);
    try testing.expect(std.mem.endsWith(u8, parts[2].sql, "AS said"));

    // And each of them is a statement SQLite takes, in that order.
    for (parts) |part| {
        try bench.conn.exec(part.sql);
    }
    try testing.expectEqualStrings("added", try bench.column("SELECT what FROM log"));
    try testing.expectEqualStrings("ok", try bench.column("SELECT state FROM books"));

    // With no semicolon after its END, which is how the last statement of a
    // batch is usually left.
    const last = try bench.conn.split(bench.a(), "DROP TRIGGER noted; CREATE TRIGGER t AFTER DELETE ON books BEGIN DELETE FROM log; END");
    try testing.expectEqual(@as(usize, 2), last.len);
    try testing.expect(std.mem.endsWith(u8, last[1].sql, "DELETE FROM log; END"));

    // A transaction's BEGIN and END are statements of their own, as they were.
    const plain = try bench.conn.split(bench.a(), "BEGIN; DELETE FROM log; END;");
    try testing.expectEqual(@as(usize, 3), plain.len);
}

test "the script a rebuild writes is run a statement at a time, trigger and all" {
    // What the interface does with it: split by the driver, each piece run as
    // a statement of its own. Handed to SQLite whole it always worked, which is
    // why the test that did that said nothing was wrong.
    var bench = try Bench.init(
        \\CREATE TABLE log (what TEXT);
        \\CREATE TABLE books (id INTEGER PRIMARY KEY, title TEXT);
        \\CREATE TRIGGER noted AFTER INSERT ON books BEGIN INSERT INTO log VALUES ('added'); END;
        \\INSERT INTO books (title) VALUES ('RUR');
        \\DELETE FROM log;
    );
    defer bench.deinit();
    const table = db.Table{ .name = "books" };
    const cols = try bench.conn.columns(bench.a(), table);
    var script: List = .empty;
    try (Ddl{}).alterTable(&script, bench.a(), table, "", cols, try bench.conn.alterContext(bench.a(), table, cols));
    for (try bench.conn.split(bench.a(), script.items)) |part| {
        try bench.conn.exec(part.sql);
    }
    try testing.expect(!bench.conn.inTransaction());
    try testing.expectEqualStrings("RUR", try bench.column("SELECT title FROM books"));
    try bench.conn.exec("INSERT INTO books (title) VALUES ('Krakatit')");
    try testing.expectEqualStrings("added", try bench.column("SELECT what FROM log"));
}

test "a rebuild that stops half way leaves the keys enforced" {
    var bench = try Bench.init(
        \\CREATE TABLE authors (id INTEGER PRIMARY KEY);
        \\INSERT INTO authors VALUES (1);
        \\CREATE TABLE books (id INTEGER PRIMARY KEY, title TEXT, author INTEGER REFERENCES authors(id));
        \\INSERT INTO books VALUES (1, NULL, 1);
    );
    defer bench.deinit();
    const table = db.Table{ .name = "books" };
    // A column made NOT NULL over a row that has nothing in it: the copy into
    // the new table is refused, which is the fifth statement of eight.
    const cols = try bench.conn.columns(bench.a(), table);
    cols[1].notnull = true;
    var script: List = .empty;
    try (Ddl{}).alterTable(&script, bench.a(), table, "", cols, try bench.conn.alterContext(bench.a(), table, cols));

    // The way the interface runs it: a statement at a time, stopping at the
    // first that fails, and rolling back whatever transaction is left open.
    var failed = false;
    for (try bench.conn.split(bench.a(), script.items)) |part| {
        bench.conn.exec(part.sql) catch {
            failed = true;
            break;
        };
    }
    try testing.expect(failed);
    try testing.expect(bench.conn.inTransaction());
    try bench.conn.exec("ROLLBACK");
    // The table is as it was, and the setting is not: this is what was left.
    try testing.expectEqualStrings("1", try bench.column("SELECT count(*) FROM books"));
    try testing.expectEqualStrings("0", try bench.column("PRAGMA foreign_keys"));

    const mend = (Ddl{}).afterFailure(script.items);
    try testing.expectEqualStrings("PRAGMA foreign_keys = on", mend);
    try bench.conn.exec(mend);
    try testing.expectEqualStrings("1", try bench.column("PRAGMA foreign_keys"));
    try testing.expectError(error.Driver, bench.conn.exec("INSERT INTO books VALUES (2, 'orphan', 99)"));

    // A script that set nothing has nothing to put back.
    try testing.expectEqualStrings("", (Ddl{}).afterFailure("CREATE INDEX i ON books (title);\n"));
    // And an engine that has no word for it says nothing, through the union.
    try testing.expectEqualStrings("", (db.Ddl{ .postgres = .{} }).afterFailure(script.items));
    try testing.expectEqualStrings(mend, (db.Ddl{ .sqlite = .{} }).afterFailure(script.items));
}

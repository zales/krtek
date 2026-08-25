//! SQLite behind the shared interface.
//!
//! The C declarations live in `src/sqlite.zig`; this file is the driver: the
//! pragmas that answer the interface's questions, and the table rebuild SQLite
//! needs for anything ALTER TABLE cannot do.

const std = @import("std");
const db = @import("db.zig");
const c = @import("sqlite");

const List = db.List;

pub const Db = struct {
    allocator: std.mem.Allocator,
    handle: ?*c.Db,
    path: std.ArrayListUnmanaged(u8) = .empty,
    version_text: std.ArrayListUnmanaged(u8) = .empty,
    /// Asked every so often whether the statement running now should go on.
    progress: ?db.Progress = null,

    pub fn open(allocator: std.mem.Allocator, target: []const u8, report: *std.ArrayListUnmanaged(u8)) !*Db {
        const zero = try allocator.dupeZ(u8, target);
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

    /// SQLite calls a handler every so many steps of its virtual machine, and a
    /// non-zero answer aborts the statement with SQLITE_INTERRUPT, so this needs
    /// no plumbing through the query path at all.
    pub fn watch(self: *Db, progress: ?db.Progress) void {
        self.progress = progress;
        if (progress == null) {
            c.sqlite3_progress_handler(self.handle, 0, null, null);
            return;
        }
        // Roughly every few milliseconds of work on current hardware: often
        // enough to feel responsive, rarely enough not to matter.
        c.sqlite3_progress_handler(self.handle, 20_000, onProgress, self);
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
        _ = c.sqlite3_close_v2(self.handle);
        self.path.deinit(self.allocator);
        self.version_text.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn caps(_: *Db) db.Caps {
        return .{
            .schemas = false,
            .hidden_row_id = true, // rowid addresses a row without a key
            .rebuild_to_alter = true,
            .databases = false,
            .label = "SQLite",
        };
    }

    pub fn version(self: *Db) []const u8 {
        return self.version_text.items;
    }

    pub fn describe(self: *Db) []const u8 {
        return self.path.items;
    }

    pub fn message(self: *Db) []const u8 {
        return std.mem.span(c.sqlite3_errmsg(self.handle));
    }

    pub fn exec(self: *Db, sql: []const u8) db.Error!void {
        self.starting();
        const zero = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(zero);
        if (c.sqlite3_exec(self.handle, zero.ptr, null, null, null) != c.OK) {
            return error.Driver;
        }
    }

    pub fn query(self: *Db, sql: []const u8, rest: ?*[]const u8) db.Error!?db.Rows {
        self.starting();
        var stmt: ?*c.Stmt = null;
        var tail: ?[*]const u8 = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, @intCast(sql.len), &stmt, &tail) != c.OK) {
            return error.Driver;
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
            return error.Driver;
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
            .int => |v| try std.fmt.allocPrint(arena, "{d}", .{v}),
            .float => |v| try std.fmt.allocPrint(arena, "{d}", .{v}),
        };
    }

    pub fn schemas(_: *Db, _: std.mem.Allocator) db.Error![][]const u8 {
        return &.{}; // one database, no schemas
    }

    pub fn objects(self: *Db, arena: std.mem.Allocator, _: []const u8) db.Error![]db.Object {
        var list: std.ArrayListUnmanaged(db.Object) = .empty;
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
        var list: std.ArrayListUnmanaged(db.Column) = .empty;
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
        var list: std.ArrayListUnmanaged(db.Index) = .empty;
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
        var list: std.ArrayListUnmanaged(db.ForeignKey) = .empty;
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
                var list: std.ArrayListUnmanaged([]const u8) = .empty;
                try list.append(arena, "rowid");
                return .{ .columns = list.items, .hidden = true, .expression = "rowid" };
            }
        } else |_| {}

        var sql: List = .empty;
        try sql.appendSlice(arena, "SELECT name FROM pragma_table_info(");
        try db.quote(&sql, arena, table.name);
        try sql.appendSlice(arena, ") WHERE pk > 0 ORDER BY pk");
        var list: std.ArrayListUnmanaged([]const u8) = .empty;
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
        var replay: std.ArrayListUnmanaged([]const u8) = .empty;
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
        var found: std.ArrayListUnmanaged(Found) = .empty;
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
            var members: std.ArrayListUnmanaged([]const u8) = .empty;
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
        var list: std.ArrayListUnmanaged(db.Setting) = .empty;
        try list.append(arena, .{ .label = "file", .value = self.path.items });
        {
            const size = self.oneNumber("PRAGMA page_size") orelse 0;
            const count = self.oneNumber("PRAGMA page_count") orelse 0;
            try list.append(arena, .{
                .label = "size",
                .value = try std.fmt.allocPrint(arena, "{d} bytes ({d} pages)", .{ size * count, count }),
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
        return db.splitStatements(arena, sql, .{ .brackets = true, .backticks = true });
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

    pub fn next(self: *Rows) db.Error!bool {
        if (self.changed_before == null) {
            self.changed_before = c.sqlite3_total_changes(self.owner.handle);
        }
        return switch (c.sqlite3_step(self.stmt)) {
            c.ROW => true,
            c.DONE => blk: {
                self.changed = c.sqlite3_total_changes(self.owner.handle) - (self.changed_before orelse 0);
                break :blk false;
            },
            else => error.Driver,
        };
    }

    /// The single value of the next row, for one-column internal queries.
    fn step_or_null(self: *Rows) db.Error!?db.Value {
        return if (try self.next()) self.value(0) else null;
    }

    pub fn close(self: *Rows) void {
        _ = c.sqlite3_finalize(self.stmt);
        self.stmt = null;
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
            if (std.ascii.indexOfIgnoreCase(text_type, needle) != null) {
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

    /// SQLite cannot change a column, so the table is written again and the rows
    /// copied over. See https://sqlite.org/lang_altertable.html.
    pub fn alterTable(_: Ddl, out: *List, a: std.mem.Allocator, table: db.Table, new_name: []const u8, cols: []const db.Column, context: db.AlterContext) !void {
        try out.appendSlice(a, "PRAGMA foreign_keys = off;\nBEGIN;\nCREATE TABLE ");
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
        try out.appendSlice(a, "COMMIT;\nPRAGMA foreign_keys = on;\n");
    }

    /// Adding a key means the same rebuild, with the key in the new definition.
    pub fn addForeignKey(self: Ddl, out: *List, a: std.mem.Allocator, table: db.Table, key: db.ForeignKey, context: db.AlterContext) !void {
        var keys: std.ArrayListUnmanaged(db.ForeignKey) = .empty;
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

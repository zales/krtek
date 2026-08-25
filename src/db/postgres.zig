//! PostgreSQL through libpq.
//!
//! Results are read in single-row mode, so a `SELECT` over a huge table costs
//! one row of memory at a time instead of the whole set - the interface hands
//! rows out one by one anyway.
//!
//! Introspection goes through the catalogs (`pg_class`, `pg_attribute`,
//! `pg_constraint`), not `information_schema`, because the catalogs answer the
//! questions this interface asks in one query each.

const std = @import("std");
const db = @import("db.zig");

const List = db.List;

pub const Db = struct {
    allocator: std.mem.Allocator,
    conn: *PGconn,
    label: std.ArrayListUnmanaged(u8) = .empty,
    version_text: std.ArrayListUnmanaged(u8) = .empty,
    last_error: std.ArrayListUnmanaged(u8) = .empty,
    /// Table oid to name, so a cursor can say where a column came from without
    /// sending a query while results are still pending.
    tables: std.AutoHashMapUnmanaged(c_uint, []const u8) = .empty,
    table_names: std.heap.ArenaAllocator,
    /// Asked every so often whether the statement running now should go on.
    progress: ?db.Progress = null,

    /// `target` is a URL or a libpq keyword string. The password is never kept:
    /// libpq holds the connection, and nothing here writes it down.
    pub fn open(allocator: std.mem.Allocator, target: []const u8, report: *std.ArrayListUnmanaged(u8)) !*Db {
        const zero = try allocator.dupeZ(u8, target);
        defer allocator.free(zero);
        const conn = PQconnectdb(zero.ptr) orelse {
            try report.appendSlice(allocator, "cannot reach the server");
            return error.Driver;
        };
        if (PQstatus(conn) != CONNECTION_OK) {
            try report.appendSlice(allocator, std.mem.trimEnd(u8, span(PQerrorMessage(conn)), "\n"));
            // libpq knows the difference between a server that wants a password and
            // one that refused the password it got, and will say which. Asked here
            // rather than read out of the message afterwards, because "no password
            // supplied" and "password authentication failed" are both sentences
            // with the word in them and they mean opposite things.
            const wants = PQconnectionNeedsPassword(conn) != 0;
            PQfinish(conn);
            return if (wants) error.NeedPassword else error.Driver;
        }
        const self = try allocator.create(Db);
        self.* = .{
            .allocator = allocator,
            .conn = conn,
            .table_names = std.heap.ArenaAllocator.init(allocator),
        };
        // Keep the notices out of the terminal, where they would scribble over
        // the interface.
        _ = PQsetErrorVerbosity(conn, 1);
        try self.label.print(allocator, "{s}@{s}:{s}/{s}", .{
            span(PQuser(conn)),
            span(PQhost(conn)),
            span(PQport(conn)),
            span(PQdb(conn)),
        });
        const raw = PQserverVersion(conn);
        try self.version_text.print(allocator, "PostgreSQL {d}.{d}", .{ @divTrunc(raw, 10000), @mod(@divTrunc(raw, 100), 100) });
        return self;
    }

    pub fn watch(self: *Db, progress: ?db.Progress) void {
        self.progress = progress;
    }

    /// Tell the caller a statement is beginning, so its timer starts here.
    fn starting(self: *Db) void {
        if (self.progress) |progress| {
            progress.starting();
        }
    }

    /// Wait until the server has something to say, asking the caller every 80 ms
    /// whether to keep waiting. libpq would block in PQgetResult, so the waiting
    /// happens here instead, on the connection's own socket.
    fn waitReady(self: *Db) void {
        const progress = self.progress orelse return;
        const socket = PQsocket(self.conn);
        if (socket < 0) {
            return;
        }
        while (PQisBusy(self.conn) != 0) {
            var fds = [1]std.c.pollfd{.{ .fd = socket, .events = std.c.POLL.IN, .revents = 0 }};
            const ready = std.c.poll(&fds, 1, 80);
            if (ready > 0) {
                if (PQconsumeInput(self.conn) == 0) {
                    return;
                }
                continue;
            }
            if (ready < 0) {
                return;
            }
            if (!progress.call()) {
                self.cancel();
                // Keep draining: the server still owes an answer, and it arrives
                // as an error result, which is what the report should say.
                return;
            }
        }
    }

    /// Ask the server to stop what it is doing. This is the documented way and
    /// is safe to call while a query is in flight.
    fn cancel(self: *Db) void {
        const handle = PQgetCancel(self.conn) orelse return;
        defer PQfreeCancel(handle);
        var problem: [256]u8 = undefined;
        _ = PQcancel(handle, &problem, problem.len);
    }

    pub fn close(self: *Db) void {
        PQfinish(self.conn);
        self.label.deinit(self.allocator);
        self.version_text.deinit(self.allocator);
        self.last_error.deinit(self.allocator);
        self.tables.deinit(self.allocator);
        self.table_names.deinit();
        self.allocator.destroy(self);
    }

    pub fn caps(_: *Db) db.Caps {
        return .{
            .schemas = true,
            .hidden_row_id = false, // ctid moves on UPDATE, so it is no key
            .rebuild_to_alter = false,
            .databases = true,
            .label = "PostgreSQL",
        };
    }

    pub fn version(self: *Db) []const u8 {
        return self.version_text.items;
    }

    pub fn describe(self: *Db) []const u8 {
        return self.label.items;
    }

    pub fn message(self: *Db) []const u8 {
        if (self.last_error.items.len != 0) {
            return self.last_error.items;
        }
        return std.mem.trimEnd(u8, span(PQerrorMessage(self.conn)), "\n");
    }

    fn remember(self: *Db, text: []const u8) void {
        self.last_error.clearRetainingCapacity();
        self.last_error.appendSlice(self.allocator, std.mem.trimEnd(u8, text, "\n")) catch {};
    }

    pub fn exec(self: *Db, sql: []const u8) db.Error!void {
        self.starting();
        const zero = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(zero);
        const result = PQexec(self.conn, zero.ptr) orelse return error.Driver;
        defer PQclear(result);
        switch (PQresultStatus(result)) {
            PGRES_COMMAND_OK, PGRES_TUPLES_OK, PGRES_EMPTY_QUERY => {},
            else => {
                self.remember(span(PQresultErrorMessage(result)));
                return error.Driver;
            },
        }
    }

    /// Start one statement. The batch was already split, so `rest` is emptied.
    pub fn query(self: *Db, sql: []const u8, rest: ?*[]const u8) db.Error!?db.Rows {
        if (rest) |out| {
            out.* = sql[sql.len..];
        }
        const trimmed = std.mem.trim(u8, sql, " \t\r\n;");
        if (trimmed.len == 0) {
            return null;
        }
        self.starting();
        const zero = try self.allocator.dupeZ(u8, trimmed);
        defer self.allocator.free(zero);
        if (PQsendQuery(self.conn, zero.ptr) != 1) {
            self.remember(span(PQerrorMessage(self.conn)));
            return error.Driver;
        }
        // One row at a time, so a huge result cannot fill the process.
        _ = PQsetSingleRowMode(self.conn);
        var rows = Rows{ .owner = self };
        // The first result says whether this statement has columns at all.
        try rows.pull();
        return .{ .postgres = rows };
    }

    pub fn inTransaction(self: *Db) bool {
        const state = PQtransactionStatus(self.conn);
        return state == PQTRANS_INTRANS or state == PQTRANS_INERROR;
    }

    // ---------------------------------------------------------- introspection

    /// Run an internal query and hand back the whole result.
    fn ask(self: *Db, sql: []const u8) db.Error!*PGresult {
        const zero = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(zero);
        const result = PQexec(self.conn, zero.ptr) orelse return error.Driver;
        if (PQresultStatus(result) != PGRES_TUPLES_OK) {
            self.remember(span(PQresultErrorMessage(result)));
            PQclear(result);
            return error.Driver;
        }
        return result;
    }

    fn cell(result: *PGresult, row: c_int, column: c_int) []const u8 {
        if (PQgetisnull(result, row, column) != 0) {
            return "";
        }
        const length: usize = @intCast(PQgetlength(result, row, column));
        const bytes = PQgetvalue(result, row, column) orelse return "";
        return bytes[0..length];
    }

    pub fn schemas(self: *Db, arena: std.mem.Allocator) db.Error![][]const u8 {
        const result = try self.ask(
            "SELECT nspname FROM pg_namespace" ++
                " WHERE nspname NOT LIKE 'pg\\_%' AND nspname <> 'information_schema'" ++
                " ORDER BY nspname = current_schema() DESC, nspname",
        );
        defer PQclear(result);
        var list: std.ArrayListUnmanaged([]const u8) = .empty;
        var row: c_int = 0;
        while (row < PQntuples(result)) : (row += 1) {
            try list.append(arena, try arena.dupe(u8, cell(result, row, 0)));
        }
        return list.items;
    }

    pub fn objects(self: *Db, arena: std.mem.Allocator, schema: []const u8) db.Error![]db.Object {
        var sql: List = .empty;
        try sql.appendSlice(arena,
            \\SELECT n.nspname, c.relname, c.relkind,
            \\  CASE WHEN c.relkind = 'r' THEN c.reltuples::bigint ELSE NULL END, c.oid
            \\ FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            \\ WHERE c.relkind IN ('r', 'p', 'v', 'm') AND n.nspname =
        );
        try db.quote(&sql, arena, if (schema.len != 0) schema else "public");
        try sql.appendSlice(arena, " ORDER BY c.relname");
        const result = try self.ask(sql.items);
        defer PQclear(result);

        var list: std.ArrayListUnmanaged(db.Object) = .empty;
        var row: c_int = 0;
        while (row < PQntuples(result)) : (row += 1) {
            const kind = cell(result, row, 2);
            const estimate = cell(result, row, 3);
            // Remember the oid, so a later result can name its source table.
            if (std.fmt.parseInt(c_uint, cell(result, row, 4), 10)) |oid| {
                const kept = self.table_names.allocator().dupe(u8, cell(result, row, 1)) catch "";
                self.tables.put(self.allocator, oid, kept) catch {};
            } else |_| {}
            try list.append(arena, .{
                .schema = try arena.dupe(u8, cell(result, row, 0)),
                .name = try arena.dupe(u8, cell(result, row, 1)),
                .kind = if (kind.len != 0 and (kind[0] == 'v' or kind[0] == 'm')) .view else .table,
                // reltuples is the planner's estimate and is -1 before the first
                // ANALYZE; the exact count is asked for per table when shown.
                .rows = if (estimate.len == 0) null else std.fmt.parseInt(i64, estimate, 10) catch null,
            });
        }
        return list.items;
    }

    pub fn columns(self: *Db, arena: std.mem.Allocator, table: db.Table) db.Error![]db.Column {
        var sql: List = .empty;
        try sql.appendSlice(arena,
            \\SELECT a.attname, format_type(a.atttypid, a.atttypmod), a.attnotnull,
            \\  pg_get_expr(d.adbin, d.adrelid),
            \\  COALESCE((SELECT true FROM pg_constraint k WHERE k.conrelid = a.attrelid
            \\    AND k.contype = 'p' AND a.attnum = ANY (k.conkey)), false),
            \\  COALESCE((SELECT true FROM pg_constraint k WHERE k.conrelid = a.attrelid
            \\    AND k.contype = 'u' AND k.conkey = ARRAY[a.attnum]), false)
            \\ FROM pg_attribute a
            \\ LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
            \\ WHERE a.attrelid =
        );
        try self.appendRegclass(&sql, arena, table);
        try sql.appendSlice(arena, " AND a.attnum > 0 AND NOT a.attisdropped ORDER BY a.attnum");
        const result = try self.ask(sql.items);
        defer PQclear(result);

        var list: std.ArrayListUnmanaged(db.Column) = .empty;
        var row: c_int = 0;
        while (row < PQntuples(result)) : (row += 1) {
            const name = try arena.dupe(u8, cell(result, row, 0));
            const dflt = cell(result, row, 3);
            try list.append(arena, .{
                .name = name,
                .type = try arena.dupe(u8, cell(result, row, 1)),
                .notnull = isTrue(cell(result, row, 2)),
                .dflt = if (dflt.len == 0) null else try arena.dupe(u8, dflt),
                .pk = isTrue(cell(result, row, 4)),
                .unique = isTrue(cell(result, row, 5)),
                .original = name,
            });
        }
        return list.items;
    }

    pub fn indexes(self: *Db, arena: std.mem.Allocator, table: db.Table) db.Error![]db.Index {
        var sql: List = .empty;
        try sql.appendSlice(arena,
            \\SELECT c.relname,
            \\  CASE WHEN i.indisprimary THEN 'PRIMARY' WHEN i.indisunique THEN 'UNIQUE' ELSE 'INDEX' END,
            \\  pg_get_expr(i.indexprs, i.indrelid) IS NOT NULL AS has_expression,
            \\  i.indpred IS NOT NULL,
            \\  (SELECT string_agg(a.attname, ', ' ORDER BY k.ord)
            \\     FROM unnest(i.indkey) WITH ORDINALITY AS k(attnum, ord)
            \\     JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum)
            \\ FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
            \\ WHERE i.indrelid =
        );
        try self.appendRegclass(&sql, arena, table);
        try sql.appendSlice(arena, " ORDER BY i.indisprimary DESC, c.relname");
        const result = try self.ask(sql.items);
        defer PQclear(result);

        var list: std.ArrayListUnmanaged(db.Index) = .empty;
        var row: c_int = 0;
        while (row < PQntuples(result)) : (row += 1) {
            const members = cell(result, row, 4);
            try list.append(arena, .{
                .name = try arena.dupe(u8, cell(result, row, 0)),
                .kind = try arena.dupe(u8, cell(result, row, 1)),
                .columns = try arena.dupe(u8, if (members.len != 0) members else "(expression)"),
                .partial = isTrue(cell(result, row, 3)),
            });
        }
        return list.items;
    }

    pub fn foreignKeys(self: *Db, arena: std.mem.Allocator, table: db.Table) db.Error![]db.ForeignKey {
        var sql: List = .empty;
        try sql.appendSlice(arena,
            \\SELECT a.attname, t.relname, f.attname,
            \\  CASE k.confupdtype WHEN 'a' THEN 'NO ACTION' WHEN 'c' THEN 'CASCADE'
            \\    WHEN 'n' THEN 'SET NULL' WHEN 'd' THEN 'SET DEFAULT' ELSE 'RESTRICT' END,
            \\  CASE k.confdeltype WHEN 'a' THEN 'NO ACTION' WHEN 'c' THEN 'CASCADE'
            \\    WHEN 'n' THEN 'SET NULL' WHEN 'd' THEN 'SET DEFAULT' ELSE 'RESTRICT' END
            \\ FROM pg_constraint k
            \\ JOIN unnest(k.conkey) WITH ORDINALITY AS o(attnum, ord) ON true
            \\ JOIN pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = o.attnum
            \\ JOIN pg_class t ON t.oid = k.confrelid
            \\ JOIN unnest(k.confkey) WITH ORDINALITY AS r(attnum, ord) ON r.ord = o.ord
            \\ JOIN pg_attribute f ON f.attrelid = k.confrelid AND f.attnum = r.attnum
            \\ WHERE k.contype = 'f' AND k.conrelid =
        );
        try self.appendRegclass(&sql, arena, table);
        try sql.appendSlice(arena, " ORDER BY k.conname, o.ord");
        const result = try self.ask(sql.items);
        defer PQclear(result);

        var list: std.ArrayListUnmanaged(db.ForeignKey) = .empty;
        var row: c_int = 0;
        while (row < PQntuples(result)) : (row += 1) {
            try list.append(arena, .{
                .column = try arena.dupe(u8, cell(result, row, 0)),
                .target_table = try arena.dupe(u8, cell(result, row, 1)),
                .target_column = try arena.dupe(u8, cell(result, row, 2)),
                .on_update = try arena.dupe(u8, cell(result, row, 3)),
                .on_delete = try arena.dupe(u8, cell(result, row, 4)),
            });
        }
        return list.items;
    }

    /// PostgreSQL keeps no DDL text, so a table's definition is written out of
    /// the catalog; a view has `pg_get_viewdef`.
    pub fn definition(self: *Db, arena: std.mem.Allocator, table: db.Table) db.Error!?[]const u8 {
        var view: List = .empty;
        try view.appendSlice(arena, "SELECT pg_get_viewdef(");
        try self.appendRegclass(&view, arena, table);
        try view.appendSlice(arena, ", true) WHERE (SELECT relkind FROM pg_class WHERE oid = ");
        try self.appendRegclass(&view, arena, table);
        try view.appendSlice(arena, ") IN ('v', 'm')");
        {
            const result = try self.ask(view.items);
            defer PQclear(result);
            if (PQntuples(result) > 0) {
                var out: List = .empty;
                try out.appendSlice(arena, "CREATE VIEW ");
                try db.quoteTable(&out, arena, table);
                try out.appendSlice(arena, " AS\n");
                try out.appendSlice(arena, cell(result, 0, 0));
                return out.items;
            }
        }

        const cols = try self.columns(arena, table);
        const keys = try self.foreignKeys(arena, table);
        var out: List = .empty;
        try Ddl.body(&out, arena, table, cols, keys, "CREATE TABLE ");
        return out.items;
    }

    pub fn rowCount(self: *Db, table: db.Table) ?i64 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var sql: List = .empty;
        sql.appendSlice(a, "SELECT count(*) FROM ") catch return null;
        db.quoteTable(&sql, a, table) catch return null;
        const result = self.ask(sql.items) catch return null;
        defer PQclear(result);
        if (PQntuples(result) == 0) {
            return null;
        }
        return std.fmt.parseInt(i64, cell(result, 0, 0), 10) catch null;
    }

    /// The primary key, or a unique index over columns that are all NOT NULL.
    pub fn rowKey(self: *Db, arena: std.mem.Allocator, table: db.Table) db.Error!db.RowKey {
        var sql: List = .empty;
        try sql.appendSlice(arena,
            \\SELECT (SELECT string_agg(a.attname, ',' ORDER BY k.ord)
            \\   FROM unnest(i.indkey) WITH ORDINALITY AS k(attnum, ord)
            \\   JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
            \\   WHERE a.attnotnull)
            \\ FROM pg_index i WHERE i.indisunique AND i.indpred IS NULL
            \\   AND i.indexprs IS NULL AND i.indrelid =
        );
        try self.appendRegclass(&sql, arena, table);
        try sql.appendSlice(arena, " ORDER BY i.indisprimary DESC LIMIT 1");
        const result = self.ask(sql.items) catch return .{};
        defer PQclear(result);
        if (PQntuples(result) == 0) {
            return .{};
        }
        const joined = cell(result, 0, 0);
        if (joined.len == 0) {
            return .{};
        }
        var list: std.ArrayListUnmanaged([]const u8) = .empty;
        var parts = std.mem.tokenizeScalar(u8, joined, ',');
        while (parts.next()) |part| {
            try list.append(arena, try arena.dupe(u8, part));
        }
        return .{ .columns = list.items, .hidden = false };
    }

    /// Asked one at a time on purpose: a parameter that a given server version
    /// does not know would otherwise take the whole listing down with it.
    const FACTS = [_][2][]const u8{
        .{ "server", "SELECT version()" },
        .{ "database", "SELECT current_database()" },
        .{ "user", "SELECT current_user" },
        .{ "schema", "SELECT current_schema()" },
        .{ "search_path", "SELECT current_setting('search_path')" },
        .{ "encoding", "SELECT current_setting('server_encoding')" },
        .{ "collation", "SELECT datcollate FROM pg_database WHERE datname = current_database()" },
        .{ "timezone", "SELECT current_setting('TimeZone')" },
        .{ "size", "SELECT pg_size_pretty(pg_database_size(current_database()))" },
        .{ "tables", "SELECT count(*)::text FROM pg_class WHERE relkind = 'r'" },
        .{ "connections", "SELECT count(*)::text FROM pg_stat_activity" },
        .{ "max_connections", "SELECT current_setting('max_connections')" },
        .{ "role", "SELECT CASE WHEN pg_is_in_recovery() THEN 'replica' ELSE 'primary' END" },
    };

    pub fn settings(self: *Db, arena: std.mem.Allocator) db.Error![]db.Setting {
        var list: std.ArrayListUnmanaged(db.Setting) = .empty;
        for (FACTS) |fact| {
            const result = self.ask(fact[1]) catch continue;
            defer PQclear(result);
            if (PQntuples(result) == 0) {
                continue;
            }
            try list.append(arena, .{
                .label = fact[0],
                .value = try arena.dupe(u8, cell(result, 0, 0)),
            });
        }
        return list.items;
    }

    /// PostgreSQL alters in place, so an alter has nothing to carry over.
    pub fn alterContext(_: *Db, _: std.mem.Allocator, _: db.Table, cols: []const db.Column) db.Error!db.AlterContext {
        return .{ .columns = cols };
    }

    /// `'schema.name'::regclass`, which every catalog query keys off.
    fn appendRegclass(_: *Db, out: *List, a: std.mem.Allocator, table: db.Table) !void {
        var name: List = .empty;
        try db.quoteTable(&name, a, table);
        try db.quote(out, a, name.items);
        try out.appendSlice(a, "::regclass");
    }

    /// PostgreSQL runs a whole batch in one implicit transaction and reports
    /// only the last result, so the statements are split here first.
    pub fn split(_: *Db, arena: std.mem.Allocator, sql: []const u8) db.Error![]db.Statement {
        return db.splitStatements(arena, sql, .{ .dollar_quotes = true, .nested_comments = true });
    }

    pub fn ddl(_: *Db) db.Ddl {
        return .{ .postgres = .{} };
    }
};

fn isTrue(text: []const u8) bool {
    return text.len != 0 and (text[0] == 't' or text[0] == 'T' or text[0] == '1');
}

fn span(text: ?[*:0]const u8) []const u8 {
    return if (text) |ptr| std.mem.span(ptr) else "";
}

// ------------------------------------------------------------------- cursor

pub const Rows = struct {
    owner: *Db,
    result: ?*PGresult = null,
    /// In single row mode every PQgetResult is either one row or the end, so the
    /// row fetched to learn the column count is held until the first next().
    state: enum { held, shown, done } = .done,
    count: usize = 0,
    changed: i64 = 0,

    fn pull(self: *Rows) db.Error!void {
        if (self.result) |old| {
            PQclear(old);
            self.result = null;
        }
        self.owner.waitReady();
        const next_result = PQgetResult(self.owner.conn) orelse {
            self.state = .done;
            return;
        };
        self.result = next_result;
        if (self.count == 0) {
            self.count = @intCast(PQnfields(next_result));
        }
        switch (PQresultStatus(next_result)) {
            PGRES_SINGLE_TUPLE => self.state = .held,
            PGRES_TUPLES_OK, PGRES_COMMAND_OK, PGRES_EMPTY_QUERY => {
                self.changed = std.fmt.parseInt(i64, span(PQcmdTuples(next_result)), 10) catch 0;
                self.state = .done;
            },
            else => {
                self.owner.remember(span(PQresultErrorMessage(next_result)));
                self.state = .done;
                return error.Driver;
            },
        }
    }

    pub fn next(self: *Rows) db.Error!bool {
        switch (self.state) {
            .held => {
                self.state = .shown;
                return true;
            },
            .shown => {
                try self.pull();
                if (self.state == .held) {
                    self.state = .shown;
                    return true;
                }
                return false;
            },
            .done => return false,
        }
    }

    pub fn close(self: *Rows) void {
        // Drain, or the connection refuses the next statement.
        if (self.result) |last| {
            PQclear(last);
            self.result = null;
        }
        while (PQgetResult(self.owner.conn)) |extra| {
            PQclear(extra);
        }
        self.state = .done;
    }

    pub fn columnCount(self: *Rows) usize {
        return self.count;
    }

    pub fn name(self: *Rows, at: usize) []const u8 {
        const result = self.result orelse return "";
        return span(PQfname(result, @intCast(at)));
    }

    pub fn value(self: *Rows, at: usize) db.Value {
        const result = self.result orelse return .null;
        const column: c_int = @intCast(at);
        if (PQgetisnull(result, 0, column) != 0) {
            return .null;
        }
        const length: usize = @intCast(PQgetlength(result, 0, column));
        const bytes = (PQgetvalue(result, 0, column) orelse return .null)[0..length];
        return switch (PQftype(result, column)) {
            OID_INT2, OID_INT4, OID_INT8 => .{ .int = std.fmt.parseInt(i64, bytes, 10) catch return .{ .text = bytes } },
            OID_FLOAT4, OID_FLOAT8 => .{ .float = std.fmt.parseFloat(f64, bytes) catch return .{ .text = bytes } },
            // bytea arrives as \x hex in text mode; show it as the blob it is.
            OID_BYTEA => .{ .blob = if (bytes.len >= 2 and bytes[0] == '\\' and bytes[1] == 'x') bytes[2..] else bytes },
            // numeric keeps arbitrary precision, so it stays text and is only
            // right aligned through isNumeric().
            else => .{ .text = bytes },
        };
    }

    /// Whether the column should be right aligned in the grid.
    pub fn isNumeric(self: *Rows, at: usize) bool {
        const result = self.result orelse return false;
        return switch (PQftype(result, @intCast(at))) {
            OID_INT2, OID_INT4, OID_INT8, OID_FLOAT4, OID_FLOAT8, OID_NUMERIC, OID_OID => true,
            else => false,
        };
    }

    /// Resolved from the map the object listing filled in. A query here would
    /// break the protocol, because results are still pending on the connection.
    pub fn sourceTable(self: *Rows, at: usize) []const u8 {
        const result = self.result orelse return "";
        const oid = PQftable(result, @intCast(at));
        if (oid == 0) {
            return "";
        }
        return self.owner.tables.get(oid) orelse "";
    }

    pub fn sourceColumn(self: *Rows, at: usize) []const u8 {
        // PQftablecol gives a number, and the name the caller wants equals the
        // result column name unless the query aliased it.
        return self.name(at);
    }

    pub fn affected(self: *Rows) i64 {
        return self.changed;
    }
};

// ---------------------------------------------------------------------- DDL

pub const Ddl = struct {
    pub fn types(_: Ddl) []const []const u8 {
        return &[_][]const u8{
            "text",        "integer", "bigint", "boolean", "numeric",
            "timestamptz", "date",    "jsonb",  "bytea",   "uuid",
            "real",        "serial",
        };
    }

    /// The shared body of CREATE TABLE.
    pub fn body(out: *List, a: std.mem.Allocator, table: db.Table, cols: []const db.Column, keys: []const db.ForeignKey, prefix: []const u8) !void {
        try out.appendSlice(a, prefix);
        try db.quoteTable(out, a, table);
        try out.appendSlice(a, " (\n");
        var primary: usize = 0;
        for (cols) |column| {
            primary += @intFromBool(column.pk);
        }
        for (cols, 0..) |column, i| {
            if (i != 0) {
                try out.appendSlice(a, ",\n");
            }
            try out.appendSlice(a, "\t");
            try db.quoteName(out, a, column.name);
            try out.append(a, ' ');
            try out.appendSlice(a, if (column.type.len != 0) column.type else "text");
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
        if (primary != 0) {
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
            try appendAction(out, a, " ON UPDATE ", key.on_update);
            try appendAction(out, a, " ON DELETE ", key.on_delete);
        }
        try out.appendSlice(a, "\n)");
    }

    fn appendAction(out: *List, a: std.mem.Allocator, clause: []const u8, action: []const u8) !void {
        if (action.len == 0 or std.mem.eql(u8, action, "NO ACTION")) {
            return;
        }
        try out.appendSlice(a, clause);
        try out.appendSlice(a, action);
    }

    pub fn createTable(_: Ddl, out: *List, a: std.mem.Allocator, table: db.Table, cols: []const db.Column, keys: []const db.ForeignKey) !void {
        try body(out, a, table, cols, keys, "CREATE TABLE ");
        try out.appendSlice(a, ";\n");
    }

    /// PostgreSQL alters in place: one statement per difference, no rebuild.
    pub fn alterTable(_: Ddl, out: *List, a: std.mem.Allocator, table: db.Table, new_name: []const u8, cols: []const db.Column, context: db.AlterContext) !void {
        _ = context;
        var current = table;
        for (cols) |column| {
            if (column.original.len == 0) {
                try out.appendSlice(a, "ALTER TABLE ");
                try db.quoteTable(out, a, current);
                try out.appendSlice(a, " ADD COLUMN ");
                try db.quoteName(out, a, column.name);
                try out.append(a, ' ');
                try out.appendSlice(a, if (column.type.len != 0) column.type else "text");
                if (column.notnull) {
                    try out.appendSlice(a, " NOT NULL");
                }
                if (column.dflt) |value| {
                    if (value.len != 0) {
                        try out.appendSlice(a, " DEFAULT ");
                        try out.appendSlice(a, value);
                    }
                }
                try out.appendSlice(a, ";\n");
                continue;
            }
            if (!std.mem.eql(u8, column.original, column.name)) {
                try out.appendSlice(a, "ALTER TABLE ");
                try db.quoteTable(out, a, current);
                try out.appendSlice(a, " RENAME COLUMN ");
                try db.quoteName(out, a, column.original);
                try out.appendSlice(a, " TO ");
                try db.quoteName(out, a, column.name);
                try out.appendSlice(a, ";\n");
            }
            if (column.type.len != 0) {
                try out.appendSlice(a, "ALTER TABLE ");
                try db.quoteTable(out, a, current);
                try out.appendSlice(a, " ALTER COLUMN ");
                try db.quoteName(out, a, column.name);
                try out.appendSlice(a, " TYPE ");
                try out.appendSlice(a, column.type);
                try out.appendSlice(a, " USING ");
                try db.quoteName(out, a, column.name);
                try out.appendSlice(a, "::");
                try out.appendSlice(a, column.type);
                try out.appendSlice(a, ";\n");
            }
            try out.appendSlice(a, "ALTER TABLE ");
            try db.quoteTable(out, a, current);
            try out.appendSlice(a, " ALTER COLUMN ");
            try db.quoteName(out, a, column.name);
            try out.appendSlice(a, if (column.notnull) " SET NOT NULL;\n" else " DROP NOT NULL;\n");
            try out.appendSlice(a, "ALTER TABLE ");
            try db.quoteTable(out, a, current);
            try out.appendSlice(a, " ALTER COLUMN ");
            try db.quoteName(out, a, column.name);
            if (column.dflt) |value| {
                if (value.len != 0) {
                    try out.appendSlice(a, " SET DEFAULT ");
                    try out.appendSlice(a, value);
                    try out.appendSlice(a, ";\n");
                } else {
                    try out.appendSlice(a, " DROP DEFAULT;\n");
                }
            } else {
                try out.appendSlice(a, " DROP DEFAULT;\n");
            }
        }
        if (new_name.len != 0 and !std.mem.eql(u8, new_name, table.name)) {
            try out.appendSlice(a, "ALTER TABLE ");
            try db.quoteTable(out, a, current);
            try out.appendSlice(a, " RENAME TO ");
            try db.quoteName(out, a, new_name);
            try out.appendSlice(a, ";\n");
            current.name = new_name;
        }
    }

    pub fn addForeignKey(_: Ddl, out: *List, a: std.mem.Allocator, table: db.Table, key: db.ForeignKey, context: db.AlterContext) !void {
        _ = context;
        try out.appendSlice(a, "ALTER TABLE ");
        try db.quoteTable(out, a, table);
        try out.appendSlice(a, " ADD FOREIGN KEY (");
        try db.quoteName(out, a, key.column);
        try out.appendSlice(a, ") REFERENCES ");
        try db.quoteName(out, a, key.target_table);
        if (key.target_column.len != 0) {
            try out.append(a, '(');
            try db.quoteName(out, a, key.target_column);
            try out.append(a, ')');
        }
        try appendAction(out, a, " ON UPDATE ", key.on_update);
        try appendAction(out, a, " ON DELETE ", key.on_delete);
        try out.appendSlice(a, ";\n");
    }

    pub fn createIndex(_: Ddl, out: *List, a: std.mem.Allocator, table: db.Table, name: []const u8, cols: []const []const u8, unique: bool, where: []const u8) !void {
        try out.appendSlice(a, if (unique) "CREATE UNIQUE INDEX " else "CREATE INDEX ");
        try db.quoteName(out, a, name);
        try out.appendSlice(a, " ON ");
        try db.quoteTable(out, a, table);
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
        try db.quoteTable(out, a, table);
        try out.appendSlice(a, " AS ");
        try out.appendSlice(a, select);
        try out.appendSlice(a, ";\n");
    }

    /// A trigger needs a function in PostgreSQL, so one is written alongside it.
    pub fn createTrigger(_: Ddl, out: *List, a: std.mem.Allocator, table: db.Table, name: []const u8, when: []const u8, event: []const u8, condition: []const u8, action: []const u8) !void {
        try out.appendSlice(a, "CREATE FUNCTION ");
        try db.quoteName(out, a, name);
        try out.appendSlice(a, "_fn() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN\n\t");
        try out.appendSlice(a, if (action.len != 0) action else "RETURN NEW");
        try out.appendSlice(a, ";\n\tRETURN NEW;\nEND $$;\nCREATE TRIGGER ");
        try db.quoteName(out, a, name);
        try out.print(a, " {s} {s} ON ", .{ when, event });
        try db.quoteTable(out, a, table);
        try out.appendSlice(a, " FOR EACH ROW");
        if (condition.len != 0) {
            try out.appendSlice(a, " WHEN (");
            try out.appendSlice(a, condition);
            try out.append(a, ')');
        }
        try out.appendSlice(a, " EXECUTE FUNCTION ");
        try db.quoteName(out, a, name);
        try out.appendSlice(a, "_fn();\n");
    }

    pub fn renameTable(_: Ddl, out: *List, a: std.mem.Allocator, table: db.Table, to: []const u8) !void {
        try out.appendSlice(a, "ALTER TABLE ");
        try db.quoteTable(out, a, table);
        try out.appendSlice(a, " RENAME TO ");
        try db.quoteName(out, a, to);
        try out.appendSlice(a, ";\n");
    }

    pub fn copyTable(_: Ddl, out: *List, a: std.mem.Allocator, table: db.Table, to: []const u8, with_rows: bool) !void {
        try out.appendSlice(a, "CREATE TABLE ");
        try db.quoteName(out, a, to);
        try out.appendSlice(a, " AS SELECT * FROM ");
        try db.quoteTable(out, a, table);
        if (!with_rows) {
            try out.appendSlice(a, " WITH NO DATA");
        }
        try out.appendSlice(a, ";\n");
    }

    pub fn dropObject(_: Ddl, out: *List, a: std.mem.Allocator, kind: db.Kind, table: db.Table) !void {
        try out.appendSlice(a, if (kind == .view) "DROP VIEW " else "DROP TABLE ");
        try db.quoteTable(out, a, table);
        try out.appendSlice(a, ";\n");
    }

    pub fn truncate(_: Ddl, out: *List, a: std.mem.Allocator, table: db.Table) !void {
        try out.appendSlice(a, "TRUNCATE ");
        try db.quoteTable(out, a, table);
        try out.appendSlice(a, ";\n");
    }
};

// ------------------------------------------------------------ libpq bindings

const PGconn = opaque {};
const PGresult = opaque {};
const PGcancel = opaque {};

const CONNECTION_OK: c_int = 0;

const PGRES_EMPTY_QUERY: c_int = 0;
const PGRES_COMMAND_OK: c_int = 1;
const PGRES_TUPLES_OK: c_int = 2;
const PGRES_SINGLE_TUPLE: c_int = 9;

const PQTRANS_INTRANS: c_int = 2;
const PQTRANS_INERROR: c_int = 3;

const OID_BOOL = 16;
const OID_BYTEA = 17;
const OID_INT8 = 20;
const OID_INT2 = 21;
const OID_INT4 = 23;
const OID_OID = 26;
const OID_FLOAT4 = 700;
const OID_FLOAT8 = 701;
const OID_NUMERIC = 1700;

extern fn PQconnectdb(conninfo: [*:0]const u8) ?*PGconn;
extern fn PQstatus(conn: *PGconn) c_int;
extern fn PQconnectionNeedsPassword(conn: *PGconn) c_int;
extern fn PQfinish(conn: *PGconn) void;
extern fn PQerrorMessage(conn: *PGconn) ?[*:0]const u8;
extern fn PQsetErrorVerbosity(conn: *PGconn, verbosity: c_int) c_int;
extern fn PQdb(conn: *PGconn) ?[*:0]const u8;
extern fn PQuser(conn: *PGconn) ?[*:0]const u8;
extern fn PQhost(conn: *PGconn) ?[*:0]const u8;
extern fn PQport(conn: *PGconn) ?[*:0]const u8;
extern fn PQserverVersion(conn: *PGconn) c_int;
extern fn PQtransactionStatus(conn: *PGconn) c_int;
extern fn PQexec(conn: *PGconn, sql: [*:0]const u8) ?*PGresult;
extern fn PQsendQuery(conn: *PGconn, sql: [*:0]const u8) c_int;
extern fn PQsetSingleRowMode(conn: *PGconn) c_int;
extern fn PQgetResult(conn: *PGconn) ?*PGresult;
extern fn PQsocket(conn: *PGconn) c_int;
extern fn PQconsumeInput(conn: *PGconn) c_int;
extern fn PQisBusy(conn: *PGconn) c_int;
extern fn PQgetCancel(conn: *PGconn) ?*PGcancel;
extern fn PQcancel(cancel: *PGcancel, errbuf: [*]u8, errbufsize: c_int) c_int;
extern fn PQfreeCancel(cancel: *PGcancel) void;
extern fn PQresultStatus(result: *PGresult) c_int;
extern fn PQresultErrorMessage(result: *PGresult) ?[*:0]const u8;
extern fn PQclear(result: *PGresult) void;
extern fn PQntuples(result: *PGresult) c_int;
extern fn PQnfields(result: *PGresult) c_int;
extern fn PQfname(result: *PGresult, column: c_int) ?[*:0]const u8;
extern fn PQftype(result: *PGresult, column: c_int) c_uint;
extern fn PQftable(result: *PGresult, column: c_int) c_uint;
extern fn PQgetvalue(result: *PGresult, row: c_int, column: c_int) ?[*]const u8;
extern fn PQgetisnull(result: *PGresult, row: c_int, column: c_int) c_int;
extern fn PQgetlength(result: *PGresult, row: c_int, column: c_int) c_int;
extern fn PQcmdTuples(result: *PGresult) ?[*:0]const u8;

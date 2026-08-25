//! The MySQL and MariaDB driver, over the MariaDB connector.
//!
//! Linked against `mariadb-connector-c` rather than Oracle's `libmysqlclient`:
//! it speaks to both servers, and its licence (LGPL) lets a non-GPL program link
//! it, which the GPL client library would not.
//!
//! Three things are worth knowing before reading on.
//!
//! **Quoting.** MySQL writes identifiers in backticks and treats a backslash as
//! an escape inside strings, so the interface's shared quoting - double quotes,
//! and a doubled single quote - would be wrong. Rather than give every driver its
//! own quoting, the connection is put into `ANSI_QUOTES,NO_BACKSLASH_ESCAPES` on
//! open, which is exactly the dialect that shared quoting generates. A statement
//! the *user* writes is affected too: a double quoted string becomes an
//! identifier, which is the standard reading of it.
//!
//! **A schema is a database.** MySQL has one namespace level, and `USE` switches
//! it, so `schemas()` lists databases and switching schema switches database.
//! That is also how the table names come out qualified - `"demo"."books"` - which
//! MySQL accepts.
//!
//! **Rows come one at a time** through `mysql_use_result`, so a huge result never
//! has to fit in memory; a statement is given up on by sending `KILL QUERY` down a
//! second connection, which is the only way MySQL offers.
//!
//! **Every call that touches the network is the connector's non-blocking one.**
//! `mysql_real_query` would sit inside libmariadb until the server answers, and a
//! statement that thinks for a minute before its first row could not be given up
//! on at all. The `_start`/`_cont` pair instead says which events it is waiting
//! for; `waitFor` polls the socket for them and, every 80 ms of quiet, asks the
//! caller whether to carry on - which is where the spinner is drawn and ctrl+c is
//! noticed. The whole connection has to be in this mode, `MYSQL_OPT_NONBLOCK` set
//! before connecting, so the connect, the fetches and the close all go the same
//! way.

const std = @import("std");
const db = @import("db.zig");

const List = std.ArrayListUnmanaged(u8);

pub const Db = struct {
    allocator: std.mem.Allocator,
    conn: *MYSQL,
    label: List = .empty,
    version_text: List = .empty,
    last_error: List = .empty,
    /// What was passed on the command line, to open the second connection that
    /// cancels a statement.
    target: List = .empty,
    progress: ?db.Progress = null,
    /// Set once the server has been asked to stop the statement in flight, so it
    /// is asked once however many rows are still on their way.
    cancelled: bool = false,

    pub fn open(allocator: std.mem.Allocator, target: []const u8, report: *List) !*Db {
        const parts = try parse(allocator, target);
        defer parts.deinit(allocator);

        const conn = mysql_init(null) orelse {
            try report.appendSlice(allocator, "cannot start the MySQL client");
            return error.Driver;
        };
        // Without this a dropped connection looks like an empty result.
        var reconnect: u8 = 0;
        _ = mysql_options(conn, MYSQL_OPT_RECONNECT, &reconnect);
        // Non-blocking from here on, which is what makes a long statement
        // interruptible; it also means every network call below is a `_start`.
        _ = mysql_options(conn, MYSQL_OPT_NONBLOCK, null);
        // The client defaults to latin1, which turns every UTF-8 name on the way
        // back into mojibake. Set before connecting, so it holds from the first
        // byte of the handshake.
        _ = mysql_options(conn, MYSQL_SET_CHARSET_NAME, "utf8mb4");
        const self = try allocator.create(Db);
        self.* = .{ .allocator = allocator, .conn = conn };

        var connected: ?*MYSQL = null;
        var status = mysql_real_connect_start(
            &connected,
            conn,
            parts.host.ptr,
            parts.user.ptr,
            if (parts.password.len == 0) null else parts.password.ptr,
            if (parts.database.len == 0) null else parts.database.ptr,
            parts.port,
            null,
            CLIENT_MULTI_RESULTS,
        );
        while (status != 0) {
            status = mysql_real_connect_cont(&connected, conn, self.waitFor(status));
        }
        if (connected == null) {
            try report.appendSlice(allocator, span(mysql_error(conn)));
            // Access denied and nothing was offered: the server wants a password
            // and there was none to give. The connector has no `needsPassword` to
            // ask, but this side knows what it sent, which answers the same
            // question - and answers it without reading the server's prose, where
            // "using password: NO" and "using password: YES" differ by one letter.
            const wants = mysql_errno(conn) == ACCESS_DENIED and parts.password.len == 0;
            mysql_close(conn);
            allocator.destroy(self);
            return if (wants) error.NeedPassword else error.Driver;
        }
        errdefer self.close();
        try self.target.appendSlice(allocator, target);
        // The dialect the shared quoting is written for; see the note above.
        self.exec("SET sql_mode = CONCAT(@@sql_mode, ',ANSI_QUOTES,NO_BACKSLASH_ESCAPES')") catch {};
        try self.label.print(allocator, "{s}@{s}:{d}/{s}", .{
            span(parts.user.ptr),
            span(parts.host.ptr),
            parts.port,
            span(parts.database.ptr),
        });
        const server = span(mysql_get_server_info(conn));
        try self.version_text.print(allocator, "{s} {s}", .{
            if (std.mem.indexOf(u8, server, "MariaDB") != null) "MariaDB" else "MySQL",
            server,
        });
        return self;
    }

    pub fn close(self: *Db) void {
        var status = mysql_close_start(self.conn);
        while (status != 0) {
            status = mysql_close_cont(self.conn, self.waitFor(status));
        }
        self.label.deinit(self.allocator);
        self.version_text.deinit(self.allocator);
        self.last_error.deinit(self.allocator);
        self.target.deinit(self.allocator);
        self.allocator.destroy(self);
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

    /// Ask the server to stop, once per statement however many rows are still on
    /// their way.
    fn stop(self: *Db) void {
        if (self.cancelled) {
            return;
        }
        self.cancelled = true;
        self.cancel();
    }

    /// Ask the server to stop the statement running on this connection. MySQL has
    /// no cancel on the connection itself: it takes a second one, which is opened
    /// here and closed again straight away.
    fn cancel(self: *Db) void {
        const id = mysql_thread_id(self.conn);
        var report: List = .empty;
        defer report.deinit(self.allocator);
        const other = Db.open(self.allocator, self.target.items, &report) catch return;
        defer other.close();
        var sql: [64]u8 = undefined;
        const text = std.fmt.bufPrintZ(&sql, "KILL QUERY {d}", .{id}) catch return;
        other.run(text) catch {};
    }

    pub fn caps(_: *Db) db.Caps {
        return .{
            // A MySQL schema *is* a database, so switching one switches the other.
            .schemas = true,
            .hidden_row_id = false,
            .rebuild_to_alter = false,
            .databases = true,
            .label = "MySQL",
            .schema_noun = "database",
            .text_cast = "CHAR",
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
        return span(mysql_error(self.conn));
    }

    fn remember(self: *Db, text: []const u8) void {
        self.last_error.clearRetainingCapacity();
        self.last_error.appendSlice(self.allocator, std.mem.trimEnd(u8, text, "\n")) catch {};
    }

    /// Run a statement and throw the result away.
    pub fn exec(self: *Db, sql: []const u8) db.Error!void {
        self.starting();
        self.last_error.clearRetainingCapacity();
        try self.run(sql);
        // A statement may leave a result behind even when nobody wants it.
        drain(self);
    }

    /// Send a statement and wait for the server, asking the caller every 80 ms
    /// whether to keep waiting.
    ///
    /// The connector's non-blocking calls are used rather than `mysql_real_query`,
    /// which would sit inside libmariadb until the first row arrives - and a
    /// statement that thinks for a minute before its first row could not be given
    /// up on at all. `_start` returns the events it wants to wait for, or 0 when it
    /// is done; `_cont` carries on from what the wait reported.
    fn run(self: *Db, sql: []const u8) db.Error!void {
        var answer: c_int = 0;
        var status = mysql_real_query_start(&answer, self.conn, sql.ptr, @intCast(sql.len));
        while (status != 0) {
            status = mysql_real_query_cont(&answer, self.conn, self.waitFor(status));
        }
        if (answer != 0) {
            self.remember(span(mysql_error(self.conn)));
            return error.Driver;
        }
    }

    /// The whole result, for the small internal queries.
    fn storeResult(self: *Db) ?*MYSQL_RES {
        var result: ?*MYSQL_RES = null;
        var status = mysql_store_result_start(&result, self.conn);
        while (status != 0) {
            status = mysql_store_result_cont(&result, self.conn, self.waitFor(status));
        }
        return result;
    }

    /// One row, or null at the end.
    fn fetchRow(self: *Db, result: *MYSQL_RES) ?MYSQL_ROW {
        var row: ?MYSQL_ROW = null;
        var status = mysql_fetch_row_start(&row, result);
        while (status != 0) {
            status = mysql_fetch_row_cont(&row, result, self.waitFor(status));
        }
        return row;
    }

    fn freeResult(self: *Db, result: *MYSQL_RES) void {
        var status = mysql_free_result_start(result);
        while (status != 0) {
            status = mysql_free_result_cont(result, self.waitFor(status));
        }
    }

    fn nextResult(self: *Db) c_int {
        var answer: c_int = 0;
        var status = mysql_next_result_start(&answer, self.conn);
        while (status != 0) {
            status = mysql_next_result_cont(&answer, self.conn, self.waitFor(status));
        }
        return answer;
    }

    /// Wait for what the connector asked for, and let the caller draw and decide.
    /// Returns the events that actually happened, which is what `_cont` wants.
    fn waitFor(self: *Db, wanted: c_int) c_int {
        const socket = mysql_get_socket(self.conn);
        if (socket < 0) {
            return wanted;
        }
        while (true) {
            var events: c_short = 0;
            if (wanted & MYSQL_WAIT_READ != 0) {
                events |= std.c.POLL.IN;
            }
            if (wanted & MYSQL_WAIT_WRITE != 0) {
                events |= std.c.POLL.OUT;
            }
            var fds = [1]std.c.pollfd{.{ .fd = socket, .events = events, .revents = 0 }};
            const ready = std.c.poll(&fds, 1, 80);
            if (ready < 0) {
                return wanted;
            }
            if (ready > 0) {
                var happened: c_int = 0;
                if (fds[0].revents & std.c.POLL.IN != 0) {
                    happened |= MYSQL_WAIT_READ;
                }
                if (fds[0].revents & std.c.POLL.OUT != 0) {
                    happened |= MYSQL_WAIT_WRITE;
                }
                if (fds[0].revents & (std.c.POLL.ERR | std.c.POLL.HUP) != 0) {
                    happened |= MYSQL_WAIT_EXCEPT;
                }
                return if (happened != 0) happened else wanted;
            }
            // Nothing yet: this is where the spinner is drawn and ctrl+c is seen.
            if (self.progress) |progress| {
                if (!progress.call() and !self.cancelled) {
                    self.cancelled = true;
                    self.cancel();
                }
            }
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
        self.last_error.clearRetainingCapacity();
        self.cancelled = false;
        try self.run(trimmed);
        // One row at a time: the server keeps the result, not this process.
        const result = mysql_use_result(self.conn);
        if (result == null) {
            // No columns - an INSERT, an UPDATE, a DDL statement.
            if (mysql_errno(self.conn) != 0) {
                self.remember(span(mysql_error(self.conn)));
                return error.Driver;
            }
            return .{ .mysql = .{ .owner = self, .changed = mysql_affected_rows(self.conn) } };
        }
        return .{ .mysql = .{
            .owner = self,
            .result = result,
            .count = mysql_num_fields(result.?),
        } };
    }

    /// Throw away whatever the connection is still holding, so the next statement
    /// is not refused.
    fn drain(self: *Db) void {
        while (true) {
            if (mysql_use_result(self.conn)) |extra| {
                while (self.fetchRow(extra) != null) {}
                self.freeResult(extra);
            }
            if (self.nextResult() != 0) {
                return;
            }
        }
    }

    /// Whether a transaction is open, asked of the connector rather than guessed
    /// from the statements that went past: `mysql_server_status` is not exported,
    /// but the connector will hand over the status flags it last received.
    pub fn inTransaction(self: *Db) bool {
        var status: c_uint = 0;
        if (mariadb_get_info(self.conn, MARIADB_CONNECTION_SERVER_STATUS, &status) != 0) {
            return false;
        }
        return (status & SERVER_STATUS_IN_TRANS) != 0;
    }

    // ---------------------------------------------------------- introspection

    /// Run an internal query and hand back the whole result, which is small.
    fn ask(self: *Db, sql: []const u8) db.Error!*MYSQL_RES {
        self.last_error.clearRetainingCapacity();
        if (mysql_real_query(self.conn, sql.ptr, @intCast(sql.len)) != 0) {
            self.remember(span(mysql_error(self.conn)));
            return error.Driver;
        }
        const result = self.storeResult() orelse {
            self.remember(span(mysql_error(self.conn)));
            return error.Driver;
        };
        return result;
    }

    /// The current database, which this driver also calls the schema.
    fn currentSchema(self: *Db, arena: std.mem.Allocator) []const u8 {
        const result = self.ask("SELECT DATABASE()") catch return "";
        defer self.freeResult(result);
        const row = mysql_fetch_row(result) orelse return "";
        return arena.dupe(u8, cell(result, row, 0)) catch "";
    }

    pub fn schemas(self: *Db, arena: std.mem.Allocator) db.Error![][]const u8 {
        const current = self.currentSchema(arena);
        const result = try self.ask(
            "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA" ++
                " WHERE SCHEMA_NAME NOT IN ('information_schema', 'performance_schema', 'mysql', 'sys')" ++
                " ORDER BY SCHEMA_NAME",
        );
        defer self.freeResult(result);
        var list: std.ArrayListUnmanaged([]const u8) = .empty;
        // The one in use first, the way the other drivers order theirs.
        if (current.len != 0) {
            try list.append(arena, current);
        }
        while (self.fetchRow(result)) |row| {
            const name = cell(result, row, 0);
            if (std.mem.eql(u8, name, current)) {
                continue;
            }
            try list.append(arena, try arena.dupe(u8, name));
        }
        return list.items;
    }

    pub fn objects(self: *Db, arena: std.mem.Allocator, schema: []const u8) db.Error![]db.Object {
        var sql: List = .empty;
        try sql.appendSlice(
            arena,
            "SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE, TABLE_ROWS" ++
                " FROM information_schema.TABLES WHERE TABLE_SCHEMA = ",
        );
        if (schema.len != 0) {
            try db.quote(&sql, arena, schema);
        } else {
            try sql.appendSlice(arena, "DATABASE()");
        }
        try sql.appendSlice(arena, " ORDER BY TABLE_NAME");
        const result = try self.ask(sql.items);
        defer self.freeResult(result);

        var list: std.ArrayListUnmanaged(db.Object) = .empty;
        while (self.fetchRow(result)) |row| {
            const kind = cell(result, row, 2);
            const estimate = cell(result, row, 3);
            const view = std.mem.indexOf(u8, kind, "VIEW") != null;
            try list.append(arena, .{
                .schema = try arena.dupe(u8, cell(result, row, 0)),
                .name = try arena.dupe(u8, cell(result, row, 1)),
                .kind = if (view) .view else .table,
                // TABLE_ROWS is InnoDB's estimate, and null for a view; the exact
                // count is asked for per table when it is shown.
                .rows = if (view or estimate.len == 0) null else std.fmt.parseInt(i64, estimate, 10) catch null,
            });
        }
        return list.items;
    }

    pub fn columns(self: *Db, arena: std.mem.Allocator, table: db.Table) db.Error![]db.Column {
        var sql: List = .empty;
        try sql.appendSlice(
            arena,
            "SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT, COLUMN_KEY, EXTRA" ++
                " FROM information_schema.COLUMNS WHERE ",
        );
        try self.appendWhere(&sql, arena, table, "");
        try sql.appendSlice(arena, " ORDER BY ORDINAL_POSITION");
        const result = try self.ask(sql.items);
        defer self.freeResult(result);

        var list: std.ArrayListUnmanaged(db.Column) = .empty;
        while (self.fetchRow(result)) |row| {
            const name = try arena.dupe(u8, cell(result, row, 0));
            const key = cell(result, row, 4);
            const extra = cell(result, row, 5);
            const dflt = if (isNull(result, row, 3)) "" else cell(result, row, 3);
            var kept: ?[]const u8 = null;
            if (dflt.len != 0) {
                // A default is stored unquoted; put it back in the form SQL takes.
                var text: List = .empty;
                if (isExpression(dflt) or std.ascii.eqlIgnoreCase(cell(result, row, 1), "json")) {
                    try text.appendSlice(arena, dflt);
                } else {
                    try db.quote(&text, arena, dflt);
                }
                kept = text.items;
            } else if (std.mem.indexOf(u8, extra, "auto_increment") != null) {
                kept = "AUTO_INCREMENT";
            }
            try list.append(arena, .{
                .name = name,
                .type = try arena.dupe(u8, cell(result, row, 1)),
                .notnull = std.ascii.eqlIgnoreCase(cell(result, row, 2), "NO"),
                .dflt = kept,
                .pk = std.mem.eql(u8, key, "PRI"),
                .unique = std.mem.eql(u8, key, "UNI"),
                .original = name,
            });
        }
        return list.items;
    }

    pub fn indexes(self: *Db, arena: std.mem.Allocator, table: db.Table) db.Error![]db.Index {
        var sql: List = .empty;
        try sql.appendSlice(
            arena,
            "SELECT INDEX_NAME, NON_UNIQUE, GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX)" ++
                " FROM information_schema.STATISTICS WHERE ",
        );
        try self.appendWhere(&sql, arena, table, "");
        try sql.appendSlice(arena, " GROUP BY INDEX_NAME, NON_UNIQUE ORDER BY INDEX_NAME <> 'PRIMARY', INDEX_NAME");
        const result = try self.ask(sql.items);
        defer self.freeResult(result);

        var list: std.ArrayListUnmanaged(db.Index) = .empty;
        while (self.fetchRow(result)) |row| {
            const name = cell(result, row, 0);
            const unique = std.mem.eql(u8, cell(result, row, 1), "0");
            try list.append(arena, .{
                .name = try arena.dupe(u8, name),
                .kind = if (std.mem.eql(u8, name, "PRIMARY")) "PRIMARY" else if (unique) "UNIQUE" else "INDEX",
                .columns = try arena.dupe(u8, cell(result, row, 2)),
            });
        }
        return list.items;
    }

    pub fn foreignKeys(self: *Db, arena: std.mem.Allocator, table: db.Table) db.Error![]db.ForeignKey {
        var sql: List = .empty;
        try sql.appendSlice(
            arena,
            "SELECT k.COLUMN_NAME, k.REFERENCED_TABLE_NAME, k.REFERENCED_COLUMN_NAME," ++
                " r.UPDATE_RULE, r.DELETE_RULE" ++
                " FROM information_schema.KEY_COLUMN_USAGE k" ++
                " JOIN information_schema.REFERENTIAL_CONSTRAINTS r" ++
                "  ON r.CONSTRAINT_SCHEMA = k.CONSTRAINT_SCHEMA AND r.CONSTRAINT_NAME = k.CONSTRAINT_NAME" ++
                " WHERE k.REFERENCED_TABLE_NAME IS NOT NULL AND ",
        );
        try self.appendWhere(&sql, arena, table, "k.");
        try sql.appendSlice(arena, " ORDER BY k.CONSTRAINT_NAME, k.ORDINAL_POSITION");
        const result = try self.ask(sql.items);
        defer self.freeResult(result);

        var list: std.ArrayListUnmanaged(db.ForeignKey) = .empty;
        while (self.fetchRow(result)) |row| {
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

    pub fn definition(self: *Db, arena: std.mem.Allocator, table: db.Table) db.Error!?[]const u8 {
        var sql: List = .empty;
        try sql.appendSlice(arena, "SHOW CREATE TABLE ");
        try db.quoteTable(&sql, arena, table);
        const result = self.ask(sql.items) catch {
            // A view answers SHOW CREATE VIEW instead.
            var other: List = .empty;
            try other.appendSlice(arena, "SHOW CREATE VIEW ");
            try db.quoteTable(&other, arena, table);
            const view = self.ask(other.items) catch return null;
            defer mysql_free_result(view);
            const row = mysql_fetch_row(view) orelse return null;
            return try arena.dupe(u8, cell(view, row, 1));
        };
        defer self.freeResult(result);
        const row = mysql_fetch_row(result) orelse return null;
        // Column 1 for a table, and for a view as well.
        return try arena.dupe(u8, cell(result, row, 1));
    }

    pub fn rowCount(self: *Db, table: db.Table) ?i64 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var sql: List = .empty;
        sql.appendSlice(a, "SELECT COUNT(*) FROM ") catch return null;
        db.quoteTable(&sql, a, table) catch return null;
        const result = self.ask(sql.items) catch return null;
        defer self.freeResult(result);
        const row = mysql_fetch_row(result) orelse return null;
        return std.fmt.parseInt(i64, cell(result, row, 0), 10) catch null;
    }

    /// The primary key, or a unique index over columns that are all NOT NULL.
    pub fn rowKey(self: *Db, arena: std.mem.Allocator, table: db.Table) db.Error!db.RowKey {
        const cols = try self.columns(arena, table);
        var list: std.ArrayListUnmanaged([]const u8) = .empty;
        for (cols) |column| {
            if (column.pk) {
                try list.append(arena, column.name);
            }
        }
        if (list.items.len != 0) {
            return .{ .columns = list.items };
        }
        for (try self.indexes(arena, table)) |index| {
            if (!std.mem.eql(u8, index.kind, "UNIQUE")) {
                continue;
            }
            var usable = true;
            var members: std.ArrayListUnmanaged([]const u8) = .empty;
            var names = std.mem.splitScalar(u8, index.columns, ',');
            while (names.next()) |name| {
                const trimmed = std.mem.trim(u8, name, " ");
                var found = false;
                for (cols) |column| {
                    if (std.mem.eql(u8, column.name, trimmed)) {
                        found = true;
                        usable = usable and column.notnull;
                    }
                }
                usable = usable and found;
                try members.append(arena, try arena.dupe(u8, trimmed));
            }
            if (usable and members.items.len != 0) {
                return .{ .columns = members.items };
            }
        }
        return .{};
    }

    /// MySQL alters in place, so nothing has to be carried across.
    pub fn alterContext(_: *Db, _: std.mem.Allocator, _: db.Table, _: []const db.Column) db.Error!db.AlterContext {
        return .{};
    }

    pub fn settings(self: *Db, arena: std.mem.Allocator) db.Error![]db.Setting {
        // The connection and the version are already at the top of the page.
        var list: std.ArrayListUnmanaged(db.Setting) = .empty;
        // One query each, and a fact the server does not know about is left out
        // rather than taking the whole page down with it.
        const FACTS = [_][2][]const u8{
            .{ "database", "SELECT DATABASE()" },
            .{ "size", "SELECT CONCAT(ROUND(SUM(data_length + index_length) / 1048576, 1), ' MB')" ++
                " FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE()" },
            .{ "tables", "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE()" },
            .{ "charset", "SELECT @@character_set_database" },
            .{ "collation", "SELECT @@collation_database" },
            .{ "engine", "SELECT @@default_storage_engine" },
            .{ "sql_mode", "SELECT @@sql_mode" },
            .{ "time zone", "SELECT @@time_zone" },
            .{ "uptime", "SELECT CONCAT(ROUND(VARIABLE_VALUE / 3600, 1), ' h') FROM performance_schema.global_status" ++
                " WHERE VARIABLE_NAME = 'Uptime'" },
            .{ "connections", "SELECT @@max_connections" },
        };
        for (FACTS) |fact| {
            const result = self.ask(fact[1]) catch continue;
            defer self.freeResult(result);
            const row = mysql_fetch_row(result) orelse continue;
            try list.append(arena, .{
                .label = fact[0],
                .value = try arena.dupe(u8, cell(result, row, 0)),
            });
        }
        return list.items;
    }

    pub fn split(_: *Db, arena: std.mem.Allocator, sql: []const u8) db.Error![]db.Statement {
        return db.splitStatements(arena, sql, .{ .backticks = true });
    }

    pub fn ddl(_: *Db) db.Ddl {
        return .{ .mysql = .{} };
    }

    /// `TABLE_SCHEMA = '…' AND TABLE_NAME = '…'`, which every information_schema
    /// query here needs. `prefix` is the alias to qualify the columns with, and is
    /// not optional where a query joins two of those views: both have a TABLE_NAME
    /// and MySQL would call it ambiguous.
    fn appendWhere(_: *Db, out: *List, arena: std.mem.Allocator, table: db.Table, prefix: []const u8) !void {
        try out.appendSlice(arena, prefix);
        try out.appendSlice(arena, "TABLE_SCHEMA = ");
        if (table.schema.len != 0) {
            try db.quote(out, arena, table.schema);
        } else {
            try out.appendSlice(arena, "DATABASE()");
        }
        try out.appendSlice(arena, " AND ");
        try out.appendSlice(arena, prefix);
        try out.appendSlice(arena, "TABLE_NAME = ");
        try db.quote(out, arena, table.name);
    }
};

// ------------------------------------------------------------------- cursor

pub const Rows = struct {
    owner: *Db,
    result: ?*MYSQL_RES = null,
    row: ?MYSQL_ROW = null,
    lengths: ?[*]c_ulong = null,
    count: c_uint = 0,
    changed: c_ulonglong = 0,

    pub fn next(self: *Rows) db.Error!bool {
        const result = self.result orelse return false;
        // Between rows is where a long result can be given up on: the server is
        // still sending, and this is the only place the driver gets control.
        if (self.owner.progress) |progress| {
            if (!progress.call()) {
                self.owner.stop();
                self.owner.remember("stopped");
                return false;
            }
        }
        self.row = self.owner.fetchRow(result);
        if (self.row == null) {
            if (mysql_errno(self.owner.conn) != 0) {
                self.owner.remember(span(mysql_error(self.owner.conn)));
                return error.Driver;
            }
            return false;
        }
        self.lengths = mysql_fetch_lengths(result);
        return true;
    }

    pub fn close(self: *Rows) void {
        if (self.result) |result| {
            // Read what is left, or the connection refuses the next statement - and
            // keep asking whether to bother, because "what is left" can be millions
            // of rows the caller has already lost interest in.
            // Asked on every row: the hook itself decides how often that means
            // drawing anything, and a row can take a second to arrive.
            while (self.owner.fetchRow(result) != null) {
                if (self.owner.progress) |progress| {
                    if (!progress.call()) {
                        self.owner.stop();
                    }
                }
            }
            self.owner.freeResult(result);
            self.result = null;
        }
        self.owner.drain();
    }

    pub fn columnCount(self: *Rows) usize {
        return self.count;
    }

    pub fn name(self: *Rows, at: usize) []const u8 {
        const info = self.fieldAt(at) orelse return "";
        return span(info.name);
    }

    pub fn value(self: *Rows, at: usize) db.Value {
        const row = self.row orelse return .{ .null = {} };
        if (at >= self.count) {
            return .{ .null = {} };
        }
        const bytes = row[at] orelse return .{ .null = {} };
        const length: usize = if (self.lengths) |all| all[at] else std.mem.len(bytes);
        const text = bytes[0..length];
        const info = self.fieldAt(at) orelse return .{ .text = text };
        // Everything arrives as text; what it means is in the field's type.
        return switch (info.type) {
            MYSQL_TYPE_TINY, MYSQL_TYPE_SHORT, MYSQL_TYPE_LONG, MYSQL_TYPE_LONGLONG, MYSQL_TYPE_INT24, MYSQL_TYPE_YEAR => .{
                .int = std.fmt.parseInt(i64, text, 10) catch return .{ .text = text },
            },
            MYSQL_TYPE_FLOAT, MYSQL_TYPE_DOUBLE => .{
                .float = std.fmt.parseFloat(f64, text) catch return .{ .text = text },
            },
            // A DECIMAL is not a float and does not survive being one: the server
            // sends `2499.50` and a round trip through f64 hands back `2499.5`,
            // which is a different number to anybody reading a column of money.
            // It stays as the text it arrived as - the same answer PostgreSQL's
            // numeric gets - and `isNumeric` still says it is a number, so the
            // grid puts it on the right.
            MYSQL_TYPE_DECIMAL, MYSQL_TYPE_NEWDECIMAL => .{ .text = text },
            // (`keepsItsDigits` is the same question, asked where a test can
            // reach it.)
            // A BLOB and a TEXT are the same type on the wire; the character set
            // tells them apart, and 63 is `binary`.
            MYSQL_TYPE_TINY_BLOB, MYSQL_TYPE_MEDIUM_BLOB, MYSQL_TYPE_LONG_BLOB, MYSQL_TYPE_BLOB, MYSQL_TYPE_GEOMETRY => if (info.charsetnr == 63)
                .{ .blob = text }
            else
                .{ .text = text },
            else => .{ .text = text },
        };
    }

    pub fn sourceTable(self: *Rows, at: usize) []const u8 {
        const info = self.fieldAt(at) orelse return "";
        return span(info.org_table);
    }

    pub fn sourceColumn(self: *Rows, at: usize) []const u8 {
        const info = self.fieldAt(at) orelse return "";
        return span(info.org_name);
    }

    pub fn isNumeric(self: *Rows, at: usize) bool {
        const info = self.fieldAt(at) orelse return false;
        return (info.flags & NUM_FLAG) != 0;
    }

    pub fn affected(self: *Rows) i64 {
        return @intCast(self.changed);
    }

    fn fieldAt(self: *Rows, at: usize) ?*MYSQL_FIELD {
        const result = self.result orelse return null;
        if (at >= self.count) {
            return null;
        }
        return mysql_fetch_field_direct(result, @intCast(at));
    }
};

// ---------------------------------------------------------------------- DDL

pub const Ddl = struct {
    pub fn types(_: Ddl) []const []const u8 {
        return &[_][]const u8{
            "int",      "bigint",    "varchar(255)", "text", "decimal(10,2)",
            "datetime", "date",      "json",         "blob", "tinyint(1)",
            "double",   "timestamp",
        };
    }

    /// The shared body of CREATE TABLE. `AUTO_INCREMENT` is a column attribute in
    /// MySQL rather than a type, so a primary key asked for that way is written
    /// out here.
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
            try columnSpec(out, a, column);
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

    /// `"name" type NOT NULL DEFAULT …`, as both CREATE and ALTER need it.
    fn columnSpec(out: *List, a: std.mem.Allocator, column: db.Column) !void {
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
            if (value.len == 0) {
                return;
            }
            // AUTO_INCREMENT sits where a default would, because that is where the
            // form asks for it.
            if (std.ascii.eqlIgnoreCase(value, "AUTO_INCREMENT")) {
                try out.appendSlice(a, " AUTO_INCREMENT");
            } else {
                try out.appendSlice(a, " DEFAULT ");
                try out.appendSlice(a, value);
            }
        }
    }

    fn appendAction(out: *List, a: std.mem.Allocator, clause: []const u8, action: []const u8) !void {
        if (action.len == 0 or std.mem.eql(u8, action, "NO ACTION") or std.mem.eql(u8, action, "RESTRICT")) {
            return;
        }
        try out.appendSlice(a, clause);
        try out.appendSlice(a, action);
    }

    pub fn createTable(_: Ddl, out: *List, a: std.mem.Allocator, table: db.Table, cols: []const db.Column, keys: []const db.ForeignKey) !void {
        try body(out, a, table, cols, keys, "CREATE TABLE ");
        try out.appendSlice(a, ";\n");
    }

    /// MySQL alters in place. A changed column is written with CHANGE, which
    /// takes the whole new definition and can rename at the same time.
    pub fn alterTable(_: Ddl, out: *List, a: std.mem.Allocator, table: db.Table, new_name: []const u8, cols: []const db.Column, context: db.AlterContext) !void {
        _ = context;
        for (cols) |column| {
            try out.appendSlice(a, "ALTER TABLE ");
            try db.quoteTable(out, a, table);
            if (column.original.len == 0) {
                try out.appendSlice(a, " ADD COLUMN ");
                try columnSpec(out, a, column);
            } else {
                try out.appendSlice(a, " CHANGE COLUMN ");
                try db.quoteName(out, a, column.original);
                try out.append(a, ' ');
                try columnSpec(out, a, column);
            }
            try out.appendSlice(a, ";\n");
        }
        if (new_name.len != 0 and !std.mem.eql(u8, new_name, table.name)) {
            try out.appendSlice(a, "RENAME TABLE ");
            try db.quoteTable(out, a, table);
            try out.appendSlice(a, " TO ");
            try db.quoteName(out, a, new_name);
            try out.appendSlice(a, ";\n");
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

    /// MySQL has no partial index, so a WHERE is refused rather than dropped
    /// quietly.
    pub fn createIndex(_: Ddl, out: *List, a: std.mem.Allocator, table: db.Table, name: []const u8, cols: []const []const u8, unique: bool, where: []const u8) !void {
        if (where.len != 0) {
            try out.appendSlice(a, "-- MySQL has no partial index; the condition was left out\n");
        }
        try out.appendSlice(a, if (unique) "CREATE UNIQUE INDEX " else "CREATE INDEX ");
        try db.quoteName(out, a, name);
        try out.appendSlice(a, " ON ");
        try db.quoteTable(out, a, table);
        try out.appendSlice(a, " (");
        for (cols, 0..) |column, i| {
            if (i != 0) {
                try out.appendSlice(a, ", ");
            }
            // `name(20)` is a prefix length, which MySQL insists on for a TEXT or
            // BLOB column, so the number stays outside the quoting.
            if (prefixLength(column)) |split| {
                try db.quoteName(out, a, column[0..split]);
                try out.appendSlice(a, column[split..]);
            } else {
                try db.quoteName(out, a, column);
            }
        }
        try out.appendSlice(a, ");\n");
    }

    /// Where the name ends in `name(20)`, or null when there is no such suffix.
    fn prefixLength(column: []const u8) ?usize {
        if (column.len < 4 or column[column.len - 1] != ')') {
            return null;
        }
        const open = std.mem.lastIndexOfScalar(u8, column, '(') orelse return null;
        if (open == 0) {
            return null;
        }
        for (column[open + 1 .. column.len - 1]) |char| {
            if (!std.ascii.isDigit(char)) {
                return null;
            }
        }
        return open;
    }

    pub fn createView(_: Ddl, out: *List, a: std.mem.Allocator, table: db.Table, select: []const u8) !void {
        try out.appendSlice(a, "CREATE VIEW ");
        try db.quoteTable(out, a, table);
        try out.appendSlice(a, " AS ");
        try out.appendSlice(a, select);
        try out.appendSlice(a, ";\n");
    }

    pub fn createTrigger(_: Ddl, out: *List, a: std.mem.Allocator, table: db.Table, name: []const u8, when: []const u8, event: []const u8, condition: []const u8, body_text: []const u8) !void {
        _ = condition; // MySQL has no WHEN clause; the body has to test for itself
        try out.appendSlice(a, "CREATE TRIGGER ");
        try db.quoteName(out, a, name);
        try out.append(a, ' ');
        try out.appendSlice(a, when);
        try out.append(a, ' ');
        try out.appendSlice(a, event);
        try out.appendSlice(a, " ON ");
        try db.quoteTable(out, a, table);
        try out.appendSlice(a, " FOR EACH ROW ");
        try out.appendSlice(a, body_text);
        try out.appendSlice(a, ";\n");
    }

    pub fn renameTable(_: Ddl, out: *List, a: std.mem.Allocator, table: db.Table, to: []const u8) !void {
        try out.appendSlice(a, "RENAME TABLE ");
        try db.quoteTable(out, a, table);
        try out.appendSlice(a, " TO ");
        try db.quoteName(out, a, to);
        try out.appendSlice(a, ";\n");
    }

    pub fn copyTable(_: Ddl, out: *List, a: std.mem.Allocator, table: db.Table, to: []const u8, with_rows: bool) !void {
        // CREATE TABLE LIKE keeps the indexes, which AS SELECT would lose.
        try out.appendSlice(a, "CREATE TABLE ");
        try db.quoteName(out, a, to);
        try out.appendSlice(a, " LIKE ");
        try db.quoteTable(out, a, table);
        try out.appendSlice(a, ";\n");
        if (with_rows) {
            try out.appendSlice(a, "INSERT INTO ");
            try db.quoteName(out, a, to);
            try out.appendSlice(a, " SELECT * FROM ");
            try db.quoteTable(out, a, table);
            try out.appendSlice(a, ";\n");
        }
    }

    pub fn dropObject(_: Ddl, out: *List, a: std.mem.Allocator, kind: db.Kind, table: db.Table) !void {
        try out.appendSlice(a, if (kind == .view) "DROP VIEW " else "DROP TABLE ");
        try db.quoteTable(out, a, table);
        try out.appendSlice(a, ";\n");
    }

    pub fn truncate(_: Ddl, out: *List, a: std.mem.Allocator, table: db.Table) !void {
        try out.appendSlice(a, "TRUNCATE TABLE ");
        try db.quoteTable(out, a, table);
        try out.appendSlice(a, ";\n");
    }
};

// ------------------------------------------------------------------ helpers

/// What a MySQL target looks like, taken apart for `mysql_real_connect`.
const Parts = struct {
    host: [:0]const u8,
    user: [:0]const u8,
    password: [:0]const u8,
    database: [:0]const u8,
    port: c_uint,

    fn deinit(self: Parts, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
        allocator.free(self.user);
        allocator.free(self.password);
        allocator.free(self.database);
    }
};

/// `mysql://user:password@host:port/database`, and the same with `mariadb://`.
/// Anything left out falls back to what a MySQL client would use anyway.
fn parse(allocator: std.mem.Allocator, target: []const u8) !Parts {
    var rest = target;
    for ([_][]const u8{ "mysql://", "mariadb://" }) |prefix| {
        if (std.ascii.startsWithIgnoreCase(rest, prefix)) {
            rest = rest[prefix.len..];
            break;
        }
    }
    var user: []const u8 = "root";
    var password: []const u8 = "";
    if (std.mem.lastIndexOfScalar(u8, rest, '@')) |at| {
        const credentials = rest[0..at];
        rest = rest[at + 1 ..];
        if (std.mem.indexOfScalar(u8, credentials, ':')) |colon| {
            user = credentials[0..colon];
            password = credentials[colon + 1 ..];
        } else if (credentials.len != 0) {
            user = credentials;
        }
    }
    var database: []const u8 = "";
    if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
        database = rest[slash + 1 ..];
        rest = rest[0..slash];
    }
    // A query string is where a password may also arrive, the way the app hands
    // one over for a single attempt.
    if (std.mem.indexOfScalar(u8, database, '?')) |question| {
        var parameters = std.mem.tokenizeAny(u8, database[question + 1 ..], "&");
        while (parameters.next()) |parameter| {
            if (std.ascii.startsWithIgnoreCase(parameter, "password=")) {
                password = parameter["password=".len..];
            }
        }
        database = database[0..question];
    }
    var host: []const u8 = if (rest.len != 0) rest else "127.0.0.1";
    var port: c_uint = 3306;
    if (std.mem.lastIndexOfScalar(u8, host, ':')) |colon| {
        port = std.fmt.parseInt(c_uint, host[colon + 1 ..], 10) catch port;
        host = host[0..colon];
    }
    return .{
        .host = try allocator.dupeZ(u8, host),
        .user = try allocator.dupeZ(u8, user),
        .password = try unescape(allocator, password),
        .database = try allocator.dupeZ(u8, database),
        .port = port,
    };
}

/// Percent decoding, because a password in a URL arrives escaped.
fn unescape(allocator: std.mem.Allocator, text: []const u8) ![:0]const u8 {
    var out: List = .empty;
    defer out.deinit(allocator);
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '%' and i + 2 < text.len) {
            if (std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16)) |byte| {
                try out.append(allocator, byte);
                i += 2;
                continue;
            } else |_| {}
        }
        try out.append(allocator, text[i]);
    }
    return allocator.dupeZ(u8, out.items);
}

/// Is this target for this driver?
pub fn owns(target: []const u8) bool {
    for ([_][]const u8{ "mysql://", "mariadb://" }) |prefix| {
        if (std.ascii.startsWithIgnoreCase(target, prefix)) {
            return true;
        }
    }
    return false;
}

fn span(text: ?[*:0]const u8) []const u8 {
    return if (text) |ptr| std.mem.span(ptr) else "";
}

fn cell(result: *MYSQL_RES, row: MYSQL_ROW, at: usize) []const u8 {
    const bytes = row[at] orelse return "";
    const lengths = mysql_fetch_lengths(result) orelse return std.mem.span(bytes);
    return bytes[0..lengths[at]];
}

fn isNull(_: *MYSQL_RES, row: MYSQL_ROW, at: usize) bool {
    return row[at] == null;
}

/// A default that is an expression rather than a value: MySQL stores
/// `CURRENT_TIMESTAMP` and `(json_array())` unquoted, and a literal unquoted too,
/// so this is the only way to tell them apart.
fn isExpression(text: []const u8) bool {
    if (text.len == 0) {
        return false;
    }
    if (text[0] == '(') {
        return true;
    }
    for ([_][]const u8{ "CURRENT_TIMESTAMP", "CURRENT_DATE", "CURRENT_TIME", "NOW(", "UUID(", "NULL" }) |word| {
        if (std.ascii.startsWithIgnoreCase(text, word)) {
            return true;
        }
    }
    return false;
}

test "a target is taken apart the way a MySQL client would" {
    const a = std.testing.allocator;
    {
        const parts = try parse(a, "mysql://bob:secret@db.example:3307/shop");
        defer parts.deinit(a);
        try std.testing.expectEqualStrings("db.example", parts.host);
        try std.testing.expectEqualStrings("bob", parts.user);
        try std.testing.expectEqualStrings("secret", parts.password);
        try std.testing.expectEqualStrings("shop", parts.database);
        try std.testing.expectEqual(@as(c_uint, 3307), parts.port);
    }
    {
        // Only a host: root, the default port, no database.
        const parts = try parse(a, "mysql://127.0.0.1");
        defer parts.deinit(a);
        try std.testing.expectEqualStrings("127.0.0.1", parts.host);
        try std.testing.expectEqualStrings("root", parts.user);
        try std.testing.expectEqualStrings("", parts.database);
        try std.testing.expectEqual(@as(c_uint, 3306), parts.port);
    }
    {
        // The password as a query parameter, escaped, which is how the app passes
        // one it has just been given.
        const parts = try parse(a, "mysql://root@127.0.0.1:3307/demo?password=pa%20ss");
        defer parts.deinit(a);
        try std.testing.expectEqualStrings("pa ss", parts.password);
        try std.testing.expectEqualStrings("demo", parts.database);
    }
}

test "a mysql target is told apart from the others" {
    try std.testing.expect(owns("mysql://localhost/demo"));
    try std.testing.expect(owns("mariadb://localhost/demo"));
    try std.testing.expect(!owns("postgres://localhost/demo"));
    try std.testing.expect(!owns("/tmp/notes.db"));
}

test "an index column may carry a prefix length" {
    try std.testing.expectEqual(@as(?usize, 5), Ddl.prefixLength("label(20)"));
    try std.testing.expectEqual(@as(?usize, null), Ddl.prefixLength("label"));
    try std.testing.expectEqual(@as(?usize, null), Ddl.prefixLength("label(x)"));
    try std.testing.expectEqual(@as(?usize, null), Ddl.prefixLength("(20)"));
}

test "a default is quoted unless it is an expression" {
    try std.testing.expect(isExpression("CURRENT_TIMESTAMP"));
    try std.testing.expect(isExpression("(json_array())"));
    try std.testing.expect(!isExpression("0"));
    try std.testing.expect(!isExpression("hello"));
}

// ------------------------------------------------- the C declarations we use

const MYSQL = opaque {};
const MYSQL_RES = opaque {};
/// A row is an array of C strings, any of which may be null for SQL NULL.
const MYSQL_ROW = [*]?[*:0]u8;

/// Only the fields up to the ones this driver reads, in the order the header
/// declares them.
const MYSQL_FIELD = extern struct {
    name: ?[*:0]const u8,
    org_name: ?[*:0]const u8,
    table: ?[*:0]const u8,
    org_table: ?[*:0]const u8,
    db: ?[*:0]const u8,
    catalog: ?[*:0]const u8,
    def: ?[*:0]const u8,
    length: c_ulong,
    max_length: c_ulong,
    name_length: c_uint,
    org_name_length: c_uint,
    table_length: c_uint,
    org_table_length: c_uint,
    db_length: c_uint,
    catalog_length: c_uint,
    def_length: c_uint,
    flags: c_uint,
    decimals: c_uint,
    charsetnr: c_uint,
    type: c_uint,
    extension: ?*anyopaque,
};

const NUM_FLAG: c_uint = 32768;
const SERVER_STATUS_IN_TRANS: c_uint = 1;
/// ER_ACCESS_DENIED_ERROR, which is what a refused login is whether or not a
/// password was part of it.
const ACCESS_DENIED: c_uint = 1045;
const CLIENT_MULTI_RESULTS: c_ulong = 131072;
const MYSQL_OPT_RECONNECT: c_uint = 21;
const MYSQL_SET_CHARSET_NAME: c_uint = 7;
const MYSQL_OPT_NONBLOCK: c_uint = 6000;
const MYSQL_WAIT_READ: c_int = 1;
const MYSQL_WAIT_WRITE: c_int = 2;
const MYSQL_WAIT_EXCEPT: c_int = 4;
/// `MARIADB_CONNECTION_SERVER_STATUS` out of the connector's own enum.
const MARIADB_CONNECTION_SERVER_STATUS: c_uint = 30;

/// Whether this type must not be handed through a float on the way to the
/// screen. Named rather than written out twice, so a test can ask the same
/// question the value reader asks.
fn keepsItsDigits(kind: c_uint) bool {
    return kind == MYSQL_TYPE_DECIMAL or kind == MYSQL_TYPE_NEWDECIMAL;
}

const MYSQL_TYPE_DECIMAL: c_uint = 0;
const MYSQL_TYPE_TINY: c_uint = 1;
const MYSQL_TYPE_SHORT: c_uint = 2;
const MYSQL_TYPE_LONG: c_uint = 3;
const MYSQL_TYPE_FLOAT: c_uint = 4;
const MYSQL_TYPE_DOUBLE: c_uint = 5;
const MYSQL_TYPE_LONGLONG: c_uint = 8;
const MYSQL_TYPE_INT24: c_uint = 9;
const MYSQL_TYPE_YEAR: c_uint = 13;
const MYSQL_TYPE_NEWDECIMAL: c_uint = 246;
const MYSQL_TYPE_TINY_BLOB: c_uint = 249;
const MYSQL_TYPE_MEDIUM_BLOB: c_uint = 250;
const MYSQL_TYPE_LONG_BLOB: c_uint = 251;
const MYSQL_TYPE_BLOB: c_uint = 252;
const MYSQL_TYPE_GEOMETRY: c_uint = 255;

extern fn mysql_init(handle: ?*MYSQL) ?*MYSQL;
extern fn mysql_options(handle: *MYSQL, option: c_uint, value: ?*const anyopaque) c_int;
extern fn mysql_real_connect(
    handle: *MYSQL,
    host: ?[*:0]const u8,
    user: ?[*:0]const u8,
    password: ?[*:0]const u8,
    database: ?[*:0]const u8,
    port: c_uint,
    socket: ?[*:0]const u8,
    flags: c_ulong,
) ?*MYSQL;
extern fn mysql_close(handle: *MYSQL) void;
extern fn mysql_error(handle: *MYSQL) ?[*:0]const u8;
extern fn mysql_errno(handle: *MYSQL) c_uint;
extern fn mysql_get_server_info(handle: *MYSQL) ?[*:0]const u8;
extern fn mysql_thread_id(handle: *MYSQL) c_ulong;
extern fn mysql_real_query(handle: *MYSQL, sql: [*]const u8, length: c_ulong) c_int;
extern fn mysql_real_query_start(answer: *c_int, handle: *MYSQL, sql: [*]const u8, length: c_ulong) c_int;
extern fn mysql_real_query_cont(answer: *c_int, handle: *MYSQL, status: c_int) c_int;
extern fn mysql_get_socket(handle: *MYSQL) c_int;
extern fn mysql_real_connect_start(
    answer: *?*MYSQL,
    handle: *MYSQL,
    host: ?[*:0]const u8,
    user: ?[*:0]const u8,
    password: ?[*:0]const u8,
    database: ?[*:0]const u8,
    port: c_uint,
    socket: ?[*:0]const u8,
    flags: c_ulong,
) c_int;
extern fn mysql_real_connect_cont(answer: *?*MYSQL, handle: *MYSQL, status: c_int) c_int;
extern fn mysql_store_result_start(answer: *?*MYSQL_RES, handle: *MYSQL) c_int;
extern fn mysql_store_result_cont(answer: *?*MYSQL_RES, handle: *MYSQL, status: c_int) c_int;
extern fn mysql_fetch_row_start(answer: *?MYSQL_ROW, result: *MYSQL_RES) c_int;
extern fn mysql_fetch_row_cont(answer: *?MYSQL_ROW, result: *MYSQL_RES, status: c_int) c_int;
extern fn mysql_free_result_start(result: *MYSQL_RES) c_int;
extern fn mysql_free_result_cont(result: *MYSQL_RES, status: c_int) c_int;
extern fn mysql_next_result_start(answer: *c_int, handle: *MYSQL) c_int;
extern fn mysql_next_result_cont(answer: *c_int, handle: *MYSQL, status: c_int) c_int;
extern fn mysql_close_start(handle: *MYSQL) c_int;
extern fn mysql_close_cont(handle: *MYSQL, status: c_int) c_int;
extern fn mysql_use_result(handle: *MYSQL) ?*MYSQL_RES;
extern fn mysql_store_result(handle: *MYSQL) ?*MYSQL_RES;
extern fn mysql_free_result(result: *MYSQL_RES) void;
extern fn mysql_fetch_row(result: *MYSQL_RES) ?MYSQL_ROW;
extern fn mysql_fetch_lengths(result: *MYSQL_RES) ?[*]c_ulong;
extern fn mysql_num_fields(result: *MYSQL_RES) c_uint;
extern fn mysql_fetch_field_direct(result: *MYSQL_RES, at: c_uint) ?*MYSQL_FIELD;
extern fn mysql_affected_rows(handle: *MYSQL) c_ulonglong;
extern fn mysql_next_result(handle: *MYSQL) c_int;
/// The connector's own accessor for things libmysqlclient never exposed.
extern fn mariadb_get_info(handle: *MYSQL, value: c_uint, out: *anyopaque) u8;

test "a decimal is not a float and is not turned into one" {
    // The server sends `2499.50`; a round trip through f64 hands back `2499.5`,
    // which is a different number to anybody reading a column of money. This is
    // the rule, tested where the rule lives rather than only against a server:
    // the two decimal types stay as the text they arrived as, and the two float
    // types do not.
    for ([_]c_uint{ MYSQL_TYPE_DECIMAL, MYSQL_TYPE_NEWDECIMAL }) |kind| {
        try std.testing.expect(keepsItsDigits(kind));
    }
    for ([_]c_uint{ MYSQL_TYPE_FLOAT, MYSQL_TYPE_DOUBLE }) |kind| {
        try std.testing.expect(!keepsItsDigits(kind));
    }
}

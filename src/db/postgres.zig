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
    label: std.ArrayList(u8) = .empty,
    version_text: std.ArrayList(u8) = .empty,
    last_error: std.ArrayList(u8) = .empty,
    /// Table oid to name, so a cursor can say where a column came from without
    /// sending a query while results are still pending.
    tables: std.AutoHashMapUnmanaged(c_uint, []const u8) = .empty,
    table_names: std.heap.ArenaAllocator,
    /// Asked every so often whether the statement running now should go on.
    progress: ?db.Progress = null,

    /// `target` is a URL or a libpq keyword string. The password is never kept:
    /// libpq holds the connection, and nothing here writes it down.
    pub fn open(allocator: std.mem.Allocator, target: []const u8, report: *std.ArrayList(u8)) !*Db {
        const zero = try allocator.dupeSentinel(u8, target, 0);
        defer allocator.free(zero);
        const conn = connect(zero.ptr) orelse {
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

    /// `PQconnectdb`, taken apart so that each step of it can be named to
    /// whoever is waiting: libpq makes a connection in one call that says
    /// nothing until it is over, and the same call made in pieces says which
    /// state it is in between them. It is the loop libpq runs itself, minus the
    /// one thing that cannot be done from outside it.
    ///
    /// That thing is `connect_timeout`. When the time runs out libpq moves on to
    /// the next address of the host, or the next host of several, by setting a
    /// field nobody else can reach - so a target that carries a limit, from the
    /// URL, from `PGCONNECT_TIMEOUT` or from a service file, is left to
    /// `PQconnectdb` whole, and gets one sentence instead of five.
    fn connect(conninfo: [*:0]const u8) ?*PGconn {
        const plan = Plan.of(conninfo);
        if (plan.limited) {
            db.tell("connecting to {s}", .{plan.host()});
            return PQconnectdb(conninfo);
        }
        // The name is looked up inside `PQconnectStart`, which is the one part
        // of this that still cannot be watched.
        db.tell("looking up {s}", .{plan.host()});
        const conn = PQconnectStart(conninfo) orelse return null;
        var wanted: c_int = POLLING_WRITING;
        while (PQstatus(conn) != CONNECTION_BAD and (wanted == POLLING_READING or wanted == POLLING_WRITING)) {
            narrate(conn);
            // Asked for again every time round: it is a different socket for
            // every address tried.
            const socket = PQsocket(conn);
            if (socket < 0) {
                break;
            }
            var fds = [1]std.c.pollfd{.{
                .fd = socket,
                .events = if (wanted == POLLING_READING) std.c.POLL.IN else std.c.POLL.OUT,
                .revents = 0,
            }};
            if (std.c.poll(&fds, 1, -1) < 0) {
                if (std.c._errno().* == @backingInt(std.c.E.INTR)) {
                    continue;
                }
                break;
            }
            wanted = PQconnectPoll(conn);
        }
        return conn;
    }

    /// The state a connection in the making is in, as a sentence.
    fn narrate(conn: *PGconn) void {
        const host = span(PQhost(conn));
        switch (PQstatus(conn)) {
            CONNECTION_STARTED => {
                const address = span(PQhostaddr(conn));
                if (address.len == 0 or std.mem.eql(u8, address, host)) {
                    db.tell("connecting to {s}:{s}", .{ host, span(PQport(conn)) });
                } else {
                    db.tell("connecting to {s}:{s} at {s}", .{ host, span(PQport(conn)), address });
                }
            },
            CONNECTION_SSL_STARTUP => db.tell("TLS handshake with {s}", .{host}),
            CONNECTION_GSS_STARTUP => db.tell("GSSAPI handshake with {s}", .{host}),
            // The startup packet has gone and what comes back is the server
            // asking who this is: the password, or the rounds of SCRAM.
            CONNECTION_MADE, CONNECTION_AWAITING_RESPONSE, CONNECTION_AUTHENTICATING => db.tell("logging in as {s}", .{span(PQuser(conn))}),
            CONNECTION_AUTH_OK => db.tell("logged in, waiting for the session to start", .{}),
            CONNECTION_CHECK_WRITABLE, CONNECTION_CHECK_STANDBY, CONNECTION_CHECK_TARGET, CONNECTION_CONSUME => db.tell("asking {s} what kind of server it is", .{host}),
            else => {},
        }
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
        const zero = try self.allocator.dupeSentinel(u8, sql, 0);
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
        const zero = try self.allocator.dupeSentinel(u8, trimmed, 0);
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
        const zero = try self.allocator.dupeSentinel(u8, sql, 0);
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
        var list: std.ArrayList([]const u8) = .empty;
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

        var list: std.ArrayList(db.Object) = .empty;
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

        var list: std.ArrayList(db.Column) = .empty;
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

        var list: std.ArrayList(db.Index) = .empty;
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

        var list: std.ArrayList(db.ForeignKey) = .empty;
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
        var list: std.ArrayList([]const u8) = .empty;
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
        var list: std.ArrayList(db.Setting) = .empty;
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

    /// PostgreSQL alters in place, so an alter has nothing to carry over - but
    /// it does have to know what the table is like now, to say only what is
    /// different. See `Ddl.alterTable`.
    pub fn alterContext(self: *Db, arena: std.mem.Allocator, table: db.Table, cols: []const db.Column) db.Error!db.AlterContext {
        return .{ .columns = cols, .before = try self.columns(arena, table) };
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
    ///
    /// Per difference, which it was not: every column that already existed had
    /// its type set, its NOT NULL set or dropped and its default set or dropped,
    /// changed or not. For most columns that is three statements that do
    /// nothing. For a column that numbers itself - `GENERATED … AS IDENTITY`,
    /// which is how PostgreSQL has said `serial` since version 10 - `DROP
    /// DEFAULT` is refused, and for one worked out from the others so is the
    /// type: so a table with either could not be altered at all, whichever
    /// column the change was to. And `SET NOT NULL` reads the whole table to
    /// make sure, once for every column that was already not null.
    ///
    /// `context.before` is the table as it is now. With nothing there - a caller
    /// that did not ask the server - everything is said, as it was.
    ///
    /// `context.removed` is the columns to drop, and nothing was written for
    /// them: a column taken out of the form was simply not in `cols`, and what
    /// is not there is not looked at. They go last, after everything that might
    /// be refused, except one whose name is wanted again - that one has to be
    /// out of the way first. No CASCADE: a view that reads the column is a
    /// reason to be told, not something to lose along with it.
    pub fn alterTable(_: Ddl, out: *List, a: std.mem.Allocator, table: db.Table, new_name: []const u8, cols: []const db.Column, context: db.AlterContext) !void {
        var current = table;
        for (context.removed) |name| {
            if (db.AlterContext.takenAgain(cols, name)) {
                try dropColumn(out, a, current, name);
            }
        }
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
            // The column as it is now, by the name it had before this form.
            const was: ?db.Column = for (context.before) |known| {
                if (std.mem.eql(u8, known.name, column.original)) {
                    break known;
                }
            } else null;
            const same_type = if (was) |known| std.mem.eql(u8, known.type, column.type) else false;
            if (column.type.len != 0 and !same_type) {
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
            if (was == null or was.?.notnull != column.notnull) {
                try out.appendSlice(a, "ALTER TABLE ");
                try db.quoteTable(out, a, current);
                try out.appendSlice(a, " ALTER COLUMN ");
                try db.quoteName(out, a, column.name);
                try out.appendSlice(a, if (column.notnull) " SET NOT NULL;\n" else " DROP NOT NULL;\n");
            }
            // No default and an empty one are the same thing said twice: the
            // form hands back an empty field for a column that never had one.
            const wanted = column.dflt orelse "";
            if (was == null or !std.mem.eql(u8, was.?.dflt orelse "", wanted)) {
                try out.appendSlice(a, "ALTER TABLE ");
                try db.quoteTable(out, a, current);
                try out.appendSlice(a, " ALTER COLUMN ");
                try db.quoteName(out, a, column.name);
                if (wanted.len != 0) {
                    try out.appendSlice(a, " SET DEFAULT ");
                    try out.appendSlice(a, wanted);
                    try out.appendSlice(a, ";\n");
                } else {
                    try out.appendSlice(a, " DROP DEFAULT;\n");
                }
            }
        }
        for (context.removed) |name| {
            if (!db.AlterContext.takenAgain(cols, name)) {
                try dropColumn(out, a, current, name);
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

    fn dropColumn(out: *List, a: std.mem.Allocator, table: db.Table, name: []const u8) !void {
        try out.appendSlice(a, "ALTER TABLE ");
        try db.quoteTable(out, a, table);
        try out.appendSlice(a, " DROP COLUMN ");
        try db.quoteName(out, a, name);
        try out.appendSlice(a, ";\n");
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
        // The function is named after the trigger, and the name is quoted as
        // one name. It was the trigger's name quoted and `_fn` after it -
        // `"audit"_fn`, which is two words to PostgreSQL: a syntax error at
        // `_fn`, for every trigger the form ever wrote.
        const function = try std.fmt.allocPrint(a, "{s}_fn", .{name});
        defer a.free(function);
        try out.appendSlice(a, "CREATE FUNCTION ");
        try db.quoteName(out, a, function);
        try out.appendSlice(a, "() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN\n\t");
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
        try db.quoteName(out, a, function);
        try out.appendSlice(a, "();\n");
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
const CONNECTION_BAD: c_int = 1;
// The states of a connection that is still being made, as `ConnStatusType`
// numbers them. The last two are newer than some of the libpq this is built
// against, which simply never reports them.
const CONNECTION_STARTED: c_int = 2;
const CONNECTION_MADE: c_int = 3;
const CONNECTION_AWAITING_RESPONSE: c_int = 4;
const CONNECTION_AUTH_OK: c_int = 5;
const CONNECTION_SSL_STARTUP: c_int = 7;
const CONNECTION_CHECK_WRITABLE: c_int = 9;
const CONNECTION_CONSUME: c_int = 10;
const CONNECTION_GSS_STARTUP: c_int = 11;
const CONNECTION_CHECK_TARGET: c_int = 12;
const CONNECTION_CHECK_STANDBY: c_int = 13;
const CONNECTION_AUTHENTICATING: c_int = 15;
/// What `PQconnectPoll` wants waited for before it is called again.
const POLLING_READING: c_int = 1;
const POLLING_WRITING: c_int = 2;

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

/// What libpq makes of a target before anything is sent: whether it has been
/// given a limit on how long connecting may take, and which host it means.
const Plan = struct {
    limited: bool = false,
    name: [96]u8 = undefined,
    len: usize = 0,

    fn of(conninfo: [*:0]const u8) Plan {
        var plan = Plan{};
        // What the environment says first, then what the target says outright,
        // so the second wins, as it does for libpq.
        const lists = [_]?[*]PQconninfoOption{ PQconndefaults(), PQconninfoParse(conninfo, null) };
        defer for (lists) |list| {
            if (list) |options| {
                PQconninfoFree(options);
            }
        };
        // Not a target libpq can read at all. It has a sentence of its own
        // about that, and the way to hear it is to let it try.
        if (lists[1] == null) {
            plan.limited = true;
        }
        var service = false;
        var timeout = false;
        for (lists) |list| {
            var option = list orelse continue;
            while (option[0].keyword) |keyword| : (option += 1) {
                const value = span(option[0].val);
                if (value.len == 0) {
                    continue;
                }
                const name = std.mem.span(keyword);
                if (std.mem.eql(u8, name, "connect_timeout")) {
                    // Anything that is not a number is libpq's to complain about.
                    timeout = (std.fmt.parseInt(i64, std.mem.trim(u8, value, " "), 10) catch 1) > 0;
                } else if (std.mem.eql(u8, name, "service")) {
                    // A service file may set a limit of its own, and it is read
                    // only once the connection is being made.
                    service = true;
                } else if (std.mem.eql(u8, name, "host")) {
                    plan.len = @min(value.len, plan.name.len);
                    @memcpy(plan.name[0..plan.len], value[0..plan.len]);
                }
            }
        }
        plan.limited = plan.limited or service or timeout;
        return plan;
    }

    fn host(self: *const Plan) []const u8 {
        return if (self.len != 0) self.name[0..self.len] else "the server";
    }
};

/// `PQconninfoOption`, of which only the first two fields are read.
const PQconninfoOption = extern struct {
    keyword: ?[*:0]const u8,
    envvar: ?[*:0]const u8,
    compiled: ?[*:0]const u8,
    val: ?[*:0]const u8,
    label: ?[*:0]const u8,
    dispchar: ?[*:0]const u8,
    dispsize: c_int,
};

extern fn PQconnectdb(conninfo: [*:0]const u8) ?*PGconn;
extern fn PQconnectStart(conninfo: [*:0]const u8) ?*PGconn;
extern fn PQconnectPoll(conn: *PGconn) c_int;
extern fn PQhostaddr(conn: *PGconn) ?[*:0]const u8;
extern fn PQconndefaults() ?[*]PQconninfoOption;
extern fn PQconninfoParse(conninfo: [*:0]const u8, errmsg: ?*?[*:0]u8) ?[*]PQconninfoOption;
extern fn PQconninfoFree(options: [*]PQconninfoOption) void;
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

// ------------------------------------------------------------------- tests

test "a target with a time limit of its own is left to libpq whole" {
    const plain = Plan.of("postgres://app@db.example:5432/shop");
    try std.testing.expect(!plain.limited);
    try std.testing.expectEqualStrings("db.example", plain.host());

    try std.testing.expect(Plan.of("postgres://app@db.example/shop?connect_timeout=5").limited);
    try std.testing.expect(Plan.of("host=db.example dbname=shop connect_timeout=3").limited);
    // Nought is libpq's word for no limit at all.
    try std.testing.expect(!Plan.of("postgres://app@db.example/shop?connect_timeout=0").limited);
    // A service file is read only when the connection is made, and may hold one.
    try std.testing.expect(Plan.of("service=shop").limited);
    // And what libpq cannot read is libpq's to refuse, in its own words.
    try std.testing.expect(Plan.of("postgres://app@db.example/shop?no_such_option=1").limited);
    try std.testing.expectEqualStrings("db.example", Plan.of("host=db.example dbname=shop").host());
}

test "a truth is a t, however PostgreSQL spells it" {
    try std.testing.expect(isTrue("t"));
    try std.testing.expect(isTrue("true"));
    try std.testing.expect(isTrue("1"));
    try std.testing.expect(!isTrue("f"));
    try std.testing.expect(!isTrue("0"));
    // No answer at all, which is what an outer join leaves, is not a yes.
    try std.testing.expect(!isTrue(""));
}

test "a server that is not there is refused in libpq's words, and nothing is kept" {
    // Nothing listens on port 1 of this machine, so this is refused at once -
    // and the allocator the test runs on fails it for anything left behind on
    // the way out, which is the half of `open` no server suite walks.
    var report: List = .empty;
    defer report.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.Driver,
        Db.open(std.testing.allocator, "postgres://nobody@127.0.0.1:1/nothing?connect_timeout=2", &report),
    );
    try std.testing.expect(report.items.len != 0);
    try std.testing.expect(report.items[report.items.len - 1] != '\n');
    // And a target libpq cannot read is libpq's to explain.
    report.clearRetainingCapacity();
    try std.testing.expectError(
        error.Driver,
        Db.open(std.testing.allocator, "postgres://nobody@127.0.0.1:1/nothing?no_such_option=1", &report),
    );
    try std.testing.expect(std.mem.find(u8, report.items, "no_such_option") != null);
}

/// What the generator writes for one call, for a test to read.
const Written = struct {
    text: List = .empty,

    fn deinit(self: *Written) void {
        self.text.deinit(std.testing.allocator);
    }

    fn has(self: *Written, wanted: []const u8) !void {
        if (std.mem.find(u8, self.text.items, wanted) == null) {
            std.debug.print("\n--- wanted\n{s}\n--- in\n{s}\n", .{ wanted, self.text.items });
            return error.TestExpectedEqual;
        }
    }

    fn lacks(self: *Written, unwanted: []const u8) !void {
        if (std.mem.find(u8, self.text.items, unwanted) != null) {
            std.debug.print("\n--- not wanted\n{s}\n--- in\n{s}\n", .{ unwanted, self.text.items });
            return error.TestExpectedEqual;
        }
    }

    /// Where one piece comes before another, which is half of what a script
    /// of several statements has to get right.
    fn before(self: *Written, first: []const u8, second: []const u8) !void {
        const one = std.mem.find(u8, self.text.items, first) orelse return self.has(first);
        const other = std.mem.find(u8, self.text.items, second) orelse return self.has(second);
        try std.testing.expect(one < other);
    }
};

test "a table is created in its schema, with its key as a constraint and a type for every column" {
    const a = std.testing.allocator;
    var out = Written{};
    defer out.deinit();
    try (Ddl{}).createTable(&out.text, a, .{ .schema = "shop", .name = "orders" }, &.{
        .{ .name = "id", .type = "serial", .pk = true },
        .{ .name = "code", .type = "text", .notnull = true, .unique = true },
        .{ .name = "placed", .type = "timestamptz", .dflt = "now()" },
        .{ .name = "note" },
        .{ .name = "customer", .type = "integer" },
    }, &.{
        .{ .column = "customer", .target_table = "customers", .target_column = "id", .on_delete = "CASCADE" },
    });
    try std.testing.expectEqualStrings("CREATE TABLE \"shop\".\"orders\" (\n" ++
        "\t\"id\" serial,\n" ++
        "\t\"code\" text NOT NULL UNIQUE,\n" ++
        "\t\"placed\" timestamptz DEFAULT now(),\n" ++
        // PostgreSQL has no column without a type, so one is given.
        "\t\"note\" text,\n" ++
        "\t\"customer\" integer,\n" ++
        "\tPRIMARY KEY (\"id\"),\n" ++
        // What a key does by default is not written out.
        "\tFOREIGN KEY (\"customer\") REFERENCES \"customers\"(\"id\") ON DELETE CASCADE\n" ++
        ");\n", out.text.items);
}

test "a key of two columns is one constraint, in the order of the columns" {
    var out = Written{};
    defer out.deinit();
    try (Ddl{}).createTable(&out.text, std.testing.allocator, .{ .name = "t" }, &.{
        .{ .name = "a", .type = "integer", .pk = true },
        .{ .name = "x", .type = "text" },
        .{ .name = "b", .type = "integer", .pk = true },
    }, &.{});
    try out.has("PRIMARY KEY (\"a\", \"b\")");
    // A public table is not written with a schema it was not given.
    try out.has("CREATE TABLE \"t\" (");
}

test "an alter adds what is new, and renames a column before it says anything else about it" {
    var out = Written{};
    defer out.deinit();
    const table = db.Table{ .schema = "shop", .name = "orders" };
    try (Ddl{}).alterTable(&out.text, std.testing.allocator, table, "", &.{
        .{ .name = "label", .type = "text", .notnull = true, .dflt = "'none'", .original = "code" },
        .{ .name = "weight", .type = "numeric", .notnull = true, .dflt = "0" },
        .{ .name = "anything" },
    }, .{});
    // A column that was not there is added whole, in one statement.
    try out.has("ALTER TABLE \"shop\".\"orders\" ADD COLUMN \"weight\" numeric NOT NULL DEFAULT 0;\n");
    try out.has("ADD COLUMN \"anything\" text;\n");
    // One that was is renamed first: every statement after that has to call
    // it by the name it has by then.
    try out.has("RENAME COLUMN \"code\" TO \"label\";\n");
    try out.before("RENAME COLUMN \"code\" TO \"label\"", "ALTER COLUMN \"label\"");
    try out.lacks("ALTER COLUMN \"code\"");
    try out.has("ALTER COLUMN \"label\" TYPE text USING \"label\"::text;\n");
    try out.has("ALTER COLUMN \"label\" SET NOT NULL;\n");
    try out.has("ALTER COLUMN \"label\" SET DEFAULT 'none';\n");
    // Nothing about the table's own name, which was not changed.
    try out.lacks("RENAME TO");
}

test "an alter renames the table last, and leaves it in its schema" {
    var out = Written{};
    defer out.deinit();
    const table = db.Table{ .schema = "shop", .name = "orders" };
    try (Ddl{}).alterTable(&out.text, std.testing.allocator, table, "sales", &.{
        .{ .name = "weight", .type = "numeric" },
    }, .{});
    // The column is added to the table under the name it still has.
    try out.before("ALTER TABLE \"shop\".\"orders\" ADD COLUMN", "RENAME TO");
    // RENAME TO takes a name, not a path: the schema is where the table is.
    try out.has("ALTER TABLE \"shop\".\"orders\" RENAME TO \"sales\";\n");

    // The same name is not a rename.
    var same = Written{};
    defer same.deinit();
    try (Ddl{}).alterTable(&same.text, std.testing.allocator, table, "orders", &.{}, .{});
    try std.testing.expectEqualStrings("", same.text.items);
}

test "a foreign key is added in place, with what it does and nothing it does not" {
    var out = Written{};
    defer out.deinit();
    try (Ddl{}).addForeignKey(&out.text, std.testing.allocator, .{ .schema = "shop", .name = "orders" }, .{
        .column = "customer",
        .target_table = "customers",
        .target_column = "id",
        .on_update = "NO ACTION",
        .on_delete = "SET NULL",
    }, .{});
    try std.testing.expectEqualStrings(
        "ALTER TABLE \"shop\".\"orders\" ADD FOREIGN KEY (\"customer\") REFERENCES \"customers\"(\"id\") ON DELETE SET NULL;\n",
        out.text.items,
    );
}

test "an index names its columns, and its condition where it has one" {
    const a = std.testing.allocator;
    var out = Written{};
    defer out.deinit();
    const table = db.Table{ .schema = "shop", .name = "orders" };
    try (Ddl{}).createIndex(&out.text, a, table, "open orders", &.{ "customer", "placed" }, true, "closed IS NULL");
    try std.testing.expectEqualStrings(
        "CREATE UNIQUE INDEX \"open orders\" ON \"shop\".\"orders\" (\"customer\", \"placed\") WHERE closed IS NULL;\n",
        out.text.items,
    );
    out.text.clearRetainingCapacity();
    try (Ddl{}).createIndex(&out.text, a, .{ .name = "t" }, "i", &.{"x"}, false, "");
    try std.testing.expectEqualStrings("CREATE INDEX \"i\" ON \"t\" (\"x\");\n", out.text.items);
}

test "a trigger's function has one name, quoted whole" {
    var out = Written{};
    defer out.deinit();
    try (Ddl{}).createTrigger(
        &out.text,
        std.testing.allocator,
        .{ .schema = "shop", .name = "orders" },
        "audit",
        "AFTER",
        "INSERT",
        "NEW.total > 0",
        "INSERT INTO log VALUES (NEW.id)",
    );
    try std.testing.expectEqualStrings("CREATE FUNCTION \"audit_fn\"() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN\n" ++
        "\tINSERT INTO log VALUES (NEW.id);\n" ++
        "\tRETURN NEW;\n" ++
        "END $$;\n" ++
        "CREATE TRIGGER \"audit\" AFTER INSERT ON \"shop\".\"orders\" FOR EACH ROW" ++
        " WHEN (NEW.total > 0) EXECUTE FUNCTION \"audit_fn\"();\n", out.text.items);
    // `"audit"_fn` is the trigger's name and then a second word: PostgreSQL
    // stops there with a syntax error, which every trigger this wrote did.
    try out.lacks("\"_fn");

    // A quote in the name is doubled inside the one pair, not closed early.
    var odd = Written{};
    defer odd.deinit();
    try (Ddl{}).createTrigger(&odd.text, std.testing.allocator, .{ .name = "t" }, "a\"b", "BEFORE", "UPDATE", "", "");
    try odd.has("CREATE FUNCTION \"a\"\"b_fn\"()");
    try odd.has("EXECUTE FUNCTION \"a\"\"b_fn\"();");
    // With nothing to do it still has to be a function PostgreSQL will take.
    try odd.has("BEGIN\n\tRETURN NEW;\n\tRETURN NEW;\nEND $$;");
    try odd.lacks("WHEN (");
}

test "a table is renamed, copied, emptied and dropped by its full name" {
    const a = std.testing.allocator;
    const table = db.Table{ .schema = "shop", .name = "orders" };
    var out = Written{};
    defer out.deinit();

    try (Ddl{}).renameTable(&out.text, a, table, "sales");
    try std.testing.expectEqualStrings("ALTER TABLE \"shop\".\"orders\" RENAME TO \"sales\";\n", out.text.items);

    out.text.clearRetainingCapacity();
    try (Ddl{}).copyTable(&out.text, a, table, "orders copy", true);
    try std.testing.expectEqualStrings("CREATE TABLE \"orders copy\" AS SELECT * FROM \"shop\".\"orders\";\n", out.text.items);

    // Without its rows: PostgreSQL has words for that, where SQLite has to
    // ask for the rows that match nothing.
    out.text.clearRetainingCapacity();
    try (Ddl{}).copyTable(&out.text, a, table, "empty", false);
    try std.testing.expectEqualStrings("CREATE TABLE \"empty\" AS SELECT * FROM \"shop\".\"orders\" WITH NO DATA;\n", out.text.items);

    out.text.clearRetainingCapacity();
    try (Ddl{}).truncate(&out.text, a, table);
    try std.testing.expectEqualStrings("TRUNCATE \"shop\".\"orders\";\n", out.text.items);

    out.text.clearRetainingCapacity();
    try (Ddl{}).dropObject(&out.text, a, .table, table);
    try (Ddl{}).dropObject(&out.text, a, .view, .{ .name = "seen" });
    try std.testing.expectEqualStrings("DROP TABLE \"shop\".\"orders\";\nDROP VIEW \"seen\";\n", out.text.items);
}

test "a view is its select, under its name" {
    var out = Written{};
    defer out.deinit();
    try (Ddl{}).createView(&out.text, std.testing.allocator, .{ .schema = "shop", .name = "open" }, "SELECT * FROM orders WHERE closed IS NULL");
    try std.testing.expectEqualStrings(
        "CREATE VIEW \"shop\".\"open\" AS SELECT * FROM orders WHERE closed IS NULL;\n",
        out.text.items,
    );
}

test "an alter says only what is different from the table as it is" {
    var out = Written{};
    defer out.deinit();
    const table = db.Table{ .name = "orders" };
    const now = [_]db.Column{
        // A column that numbers itself: its default is not one, and PostgreSQL
        // refuses to have it dropped.
        .{ .name = "id", .type = "integer", .notnull = true, .pk = true },
        .{ .name = "code", .type = "text", .notnull = true },
        .{ .name = "total", .type = "numeric(12,2)", .dflt = "0" },
        .{ .name = "note", .type = "text" },
    };
    try (Ddl{}).alterTable(&out.text, std.testing.allocator, table, "", &.{
        // Left alone: nothing is said about it at all.
        .{ .name = "id", .type = "integer", .notnull = true, .pk = true, .original = "id" },
        // Only renamed.
        .{ .name = "label", .type = "text", .notnull = true, .original = "code" },
        // A wider type, and nothing else about it.
        .{ .name = "total", .type = "numeric(14,2)", .dflt = "0", .original = "total" },
        // Made not null, and given a default it did not have.
        .{ .name = "note", .type = "text", .notnull = true, .dflt = "''", .original = "note" },
    }, .{ .before = &now });
    try std.testing.expectEqualStrings("ALTER TABLE \"orders\" RENAME COLUMN \"code\" TO \"label\";\n" ++
        "ALTER TABLE \"orders\" ALTER COLUMN \"total\" TYPE numeric(14,2) USING \"total\"::numeric(14,2);\n" ++
        "ALTER TABLE \"orders\" ALTER COLUMN \"note\" SET NOT NULL;\n" ++
        "ALTER TABLE \"orders\" ALTER COLUMN \"note\" SET DEFAULT '';\n", out.text.items);
}

test "a default taken away is dropped, and one that was never there is not" {
    var out = Written{};
    defer out.deinit();
    const now = [_]db.Column{
        .{ .name = "total", .type = "numeric", .dflt = "0" },
        .{ .name = "note", .type = "text" },
        .{ .name = "open", .type = "boolean", .notnull = true },
    };
    try (Ddl{}).alterTable(&out.text, std.testing.allocator, .{ .name = "t" }, "", &.{
        // The form hands back an empty field where the default was deleted...
        .{ .name = "total", .type = "numeric", .dflt = "", .original = "total" },
        // ...and an empty field where there never was one, which is no change.
        .{ .name = "note", .type = "text", .dflt = "", .original = "note" },
        .{ .name = "open", .type = "boolean", .original = "open" },
    }, .{ .before = &now });
    try std.testing.expectEqualStrings("ALTER TABLE \"t\" ALTER COLUMN \"total\" DROP DEFAULT;\n" ++
        "ALTER TABLE \"t\" ALTER COLUMN \"open\" DROP NOT NULL;\n", out.text.items);
}

test "a column taken out of the form is dropped, and last unless its name is wanted again" {
    var out = Written{};
    defer out.deinit();
    const table = db.Table{ .schema = "shop", .name = "orders" };
    const now = [_]db.Column{
        .{ .name = "id", .type = "integer", .notnull = true, .pk = true },
        .{ .name = "note", .type = "text" },
        .{ .name = "total", .type = "numeric" },
        // Added by somebody else while the form was open: on the server, and
        // in neither list the form has.
        .{ .name = "theirs", .type = "integer" },
    };
    try (Ddl{}).alterTable(&out.text, std.testing.allocator, table, "sales", &.{
        .{ .name = "id", .type = "integer", .notnull = true, .pk = true, .original = "id" },
        // A new column under the name of one that was removed.
        .{ .name = "total", .type = "text" },
        .{ .name = "weight", .type = "numeric" },
    }, .{ .before = &now, .removed = &.{ "note", "total" } });
    // The one in the way goes first, and the other after everything the server
    // might refuse - but while the table still has the name they know it by.
    try std.testing.expectEqualStrings("ALTER TABLE \"shop\".\"orders\" DROP COLUMN \"total\";\n" ++
        "ALTER TABLE \"shop\".\"orders\" ADD COLUMN \"total\" text;\n" ++
        "ALTER TABLE \"shop\".\"orders\" ADD COLUMN \"weight\" numeric;\n" ++
        "ALTER TABLE \"shop\".\"orders\" DROP COLUMN \"note\";\n" ++
        "ALTER TABLE \"shop\".\"orders\" RENAME TO \"sales\";\n", out.text.items);
    // What the form never showed is not the form's to drop.
    try out.lacks("theirs");

    // A column that is on the server and not in the list is not thereby
    // removed: only one that is said to be.
    var quiet = Written{};
    defer quiet.deinit();
    try (Ddl{}).alterTable(&quiet.text, std.testing.allocator, table, "", &.{
        .{ .name = "id", .type = "integer", .notnull = true, .pk = true, .original = "id" },
    }, .{ .before = &now });
    try std.testing.expectEqualStrings("", quiet.text.items);
}

// Against a real server, and only where one is offered: `KRTEK_POSTGRES` holds
// a target, and tests/postgres.sh is what offers it - with
// `zig build test -Dagainst=KRTEK_POSTGRES=…`, which is what makes the tests
// run again rather than be answered from the last time. Everything happens in
// a schema of its own, which is dropped before and after.
test "every schema statement this writes is one the server takes" {
    const target = @import("targets.zig").getenv("KRTEK_POSTGRES") orelse return error.SkipZigTest;
    const testing = std.testing;
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    var report: List = .empty;
    defer report.deinit(testing.allocator);
    const self = Db.open(testing.allocator, target, &report) catch {
        std.debug.print("not connected: {s}\n", .{report.items});
        return error.TestUnexpectedResult;
    };
    defer self.close();

    // Each statement below is written by this file and then run as written: a
    // statement only ever compared to a string this same file wrote proves
    // nothing about whether the server would take it - which is how a trigger
    // came to be a syntax error with a unit test's worth of confidence in it.
    const check = struct {
        fn run(owner: *Db, a: std.mem.Allocator, what: []const u8, sql: []const u8) !void {
            for (try owner.split(a, sql)) |statement| {
                owner.exec(statement.sql) catch {
                    std.debug.print("{s} refused: {s}\n  {s}\n", .{ what, owner.message(), statement.sql });
                    return error.TestUnexpectedResult;
                };
            }
        }
    }.run;

    // What the server remarks on in passing goes to stderr, and a test that
    // writes there is reported as one that had something to say.
    try check(self, arena, "quiet", "SET client_min_messages TO warning");
    try check(self, arena, "the schema", "DROP SCHEMA IF EXISTS krtek_ddl CASCADE; CREATE SCHEMA krtek_ddl");
    defer self.exec("DROP SCHEMA IF EXISTS krtek_ddl CASCADE") catch {};
    const dialect = Ddl{};
    const table = db.Table{ .schema = "krtek_ddl", .name = "orders" };
    const customers = db.Table{ .schema = "krtek_ddl", .name = "customers" };
    var out: List = .empty;

    try dialect.createTable(&out, arena, customers, &.{
        .{ .name = "id", .type = "serial", .pk = true },
        .{ .name = "name", .type = "text", .notnull = true },
    }, &.{});
    try check(self, arena, "create table", out.items);

    // The columns the generator knows nothing special about are the ones that
    // made every alter of their table fail: one that numbers itself, and one
    // worked out from another. Made by hand, because the form cannot.
    try check(self, arena, "a table with an identity and a generated column",
        \\CREATE TABLE krtek_ddl.orders (
        \\  id integer GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
        \\  code text NOT NULL,
        \\  shouted text GENERATED ALWAYS AS (upper(code)) STORED,
        \\  total numeric(12,2) DEFAULT 0,
        \\  customer integer
        \\);
        \\INSERT INTO krtek_ddl.orders (code, total) VALUES ('a-1', 10)
    );

    // What the alter form does: the columns as the server reports them, with
    // one renamed, one widened and one added - and the two awkward ones left
    // exactly as they came.
    const before = try self.columns(arena, table);
    var cols: std.ArrayList(db.Column) = .empty;
    try cols.appendSlice(arena, before);
    for (cols.items) |*column| {
        if (std.mem.eql(u8, column.name, "code")) {
            column.name = "label";
        } else if (std.mem.eql(u8, column.name, "total")) {
            column.type = "numeric(14,2)";
        }
    }
    try cols.append(arena, .{ .name = "note", .type = "text", .notnull = true, .dflt = "''" });
    out.clearRetainingCapacity();
    try dialect.alterTable(&out, arena, table, "", cols.items, try self.alterContext(arena, table, cols.items));
    try check(self, arena, "alter", out.items);

    const after = try self.columns(arena, table);
    var seen: usize = 0;
    for (after) |column| {
        if (std.mem.eql(u8, column.name, "label")) {
            try testing.expect(column.notnull);
            seen += 1;
        } else if (std.mem.eql(u8, column.name, "total")) {
            try testing.expectEqualStrings("numeric(14,2)", column.type);
            try testing.expectEqualStrings("0", column.dflt.?);
            seen += 1;
        } else if (std.mem.eql(u8, column.name, "note")) {
            try testing.expect(column.notnull);
            seen += 1;
        }
    }
    try testing.expectEqual(@as(usize, 3), seen);
    // Nothing changed is nothing written, which is the whole of the fix.
    out.clearRetainingCapacity();
    try dialect.alterTable(&out, arena, table, "", after, try self.alterContext(arena, table, after));
    try testing.expectEqualStrings("", out.items);

    // A column taken out of the form, which nothing was written for: the form
    // closed and the column was still there. Two of them here - one simply
    // removed, and one removed with a new column put in under its name, which
    // only works with the old one dropped first.
    try check(self, arena, "two columns to remove", "ALTER TABLE krtek_ddl.orders ADD COLUMN spare text DEFAULT 'x', ADD COLUMN swap text");
    const shown = try self.columns(arena, table);
    // And one that arrives while the form is open. It is in the catalog at the
    // moment of saving and in nothing the form has, and it has to survive.
    try check(self, arena, "a column from somebody else", "ALTER TABLE krtek_ddl.orders ADD COLUMN theirs integer");
    var names: std.ArrayList([]const u8) = .empty;
    var left: std.ArrayList(db.Column) = .empty;
    for (shown) |column| {
        try names.append(arena, column.original);
        if (!std.mem.eql(u8, column.name, "spare") and !std.mem.eql(u8, column.name, "swap")) {
            try left.append(arena, column);
        }
    }
    try left.append(arena, .{ .name = "swap", .type = "integer" });
    var removing = try self.alterContext(arena, table, left.items);
    removing.removed = try db.removedColumns(arena, names.items, left.items);
    try testing.expectEqual(@as(usize, 2), removing.removed.len);
    out.clearRetainingCapacity();
    try dialect.alterTable(&out, arena, table, "", left.items, removing);
    try check(self, arena, "an alter that removes", out.items);
    var swapped = false;
    var has_theirs = false;
    for (try self.columns(arena, table)) |column| {
        try testing.expect(!std.mem.eql(u8, column.name, "spare"));
        if (std.mem.eql(u8, column.name, "swap")) {
            swapped = true;
            try testing.expectEqualStrings("integer", column.type);
        }
        has_theirs = has_theirs or std.mem.eql(u8, column.name, "theirs");
    }
    try testing.expect(swapped);
    try testing.expect(has_theirs);
    try check(self, arena, "and theirs goes back", "ALTER TABLE krtek_ddl.orders DROP COLUMN theirs, DROP COLUMN swap");

    out.clearRetainingCapacity();
    try dialect.addForeignKey(&out, arena, table, .{
        .column = "customer",
        .target_table = "customers",
        .target_column = "id",
        .on_delete = "SET NULL",
    }, .{});
    // The key names its table without a schema, so it is looked for where
    // the session looks.
    try check(self, arena, "the search path", "SET search_path TO krtek_ddl, public");
    try check(self, arena, "foreign key", out.items);
    const keys = try self.foreignKeys(arena, table);
    try testing.expectEqual(@as(usize, 1), keys.len);
    try testing.expectEqualStrings("customers", keys[0].target_table);
    try testing.expectEqualStrings("SET NULL", keys[0].on_delete);

    out.clearRetainingCapacity();
    try dialect.createIndex(&out, arena, table, "by label", &.{ "label", "customer" }, true, "");
    try dialect.createIndex(&out, arena, table, "big", &.{"total"}, false, "total > 100");
    try check(self, arena, "index", out.items);
    var partial = false;
    for (try self.indexes(arena, table)) |index| {
        if (std.mem.eql(u8, index.name, "big")) {
            partial = index.partial;
        }
    }
    try testing.expect(partial);

    out.clearRetainingCapacity();
    try dialect.createView(&out, arena, .{ .schema = "krtek_ddl", .name = "open" }, "SELECT id, label FROM krtek_ddl.orders");
    try check(self, arena, "view", out.items);
    const body = (try self.definition(arena, .{ .schema = "krtek_ddl", .name = "open" })).?;
    try testing.expect(std.mem.find(u8, body, "label") != null);

    // The statement that was a syntax error: a function, and a trigger that
    // calls it. It has to be taken, and then it has to fire.
    try check(self, arena, "a log", "CREATE TABLE krtek_ddl.log (what text)");
    out.clearRetainingCapacity();
    try dialect.createTrigger(&out, arena, table, "audit", "AFTER", "INSERT", "NEW.total > 0", "INSERT INTO krtek_ddl.log VALUES (NEW.label)");
    try check(self, arena, "trigger", out.items);
    try check(self, arena, "two rows, one of them worth logging", "INSERT INTO krtek_ddl.orders (label, total) VALUES ('b-2', 5), ('c-3', 0)");
    {
        var rows = (try self.query("SELECT string_agg(what, ',') FROM krtek_ddl.log", null)).?;
        defer rows.close();
        try testing.expect(try rows.next());
        try testing.expectEqualStrings("b-2", rows.value(0).text);
    }

    out.clearRetainingCapacity();
    try dialect.copyTable(&out, arena, table, "orders empty", false);
    try dialect.copyTable(&out, arena, table, "orders full", true);
    try check(self, arena, "copy", out.items);
    try testing.expectEqual(@as(?i64, 0), exact(self, "SELECT count(*) FROM \"orders empty\""));
    try testing.expectEqual(@as(?i64, 3), exact(self, "SELECT count(*) FROM \"orders full\""));

    out.clearRetainingCapacity();
    try dialect.truncate(&out, arena, .{ .schema = "krtek_ddl", .name = "orders full" });
    try check(self, arena, "truncate", out.items);
    try testing.expectEqual(@as(?i64, 0), exact(self, "SELECT count(*) FROM \"orders full\""));

    // And a rename, last, because everything above named the table.
    out.clearRetainingCapacity();
    try dialect.renameTable(&out, arena, table, "sales");
    try dialect.dropObject(&out, arena, .view, .{ .schema = "krtek_ddl", .name = "open" });
    try dialect.dropObject(&out, arena, .table, .{ .schema = "krtek_ddl", .name = "sales" });
    try check(self, arena, "rename and drop", out.items);
}

/// One number out of the server, for the test above.
fn exact(self: *Db, sql: []const u8) ?i64 {
    var rows = (self.query(sql, null) catch return null) orelse return null;
    defer rows.close();
    if (!(rows.next() catch return null)) {
        return null;
    }
    return switch (rows.value(0)) {
        .int => |value| value,
        .text => |text| std.fmt.parseInt(i64, text, 10) catch null,
        else => null,
    };
}

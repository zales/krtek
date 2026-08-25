//! Microsoft SQL Server, over the protocol written out in `tds.zig`.
//!
//! Unlike PostgreSQL and MySQL there is no library to link: see the note at the
//! top of `tds.zig` for why. What that costs is the protocol; what it buys is
//! that `krtek` still builds anywhere with a C compiler and OpenSSL, and that
//! the binary keeps its licence.
//!
//! Introspection goes through `sys.*` rather than `INFORMATION_SCHEMA`. The
//! standard views are there, but they answer a smaller set of questions - they
//! do not know a filtered index from a whole one, and they cannot say which
//! index is the primary key - and every question here needs one query.

const std = @import("std");
const db = @import("db.zig");
const tds = @import("tds.zig");
const targets = @import("targets.zig");

const List = db.List;

pub fn owns(target: []const u8) bool {
    for ([_][]const u8{ "mssql://", "sqlserver://" }) |prefix| {
        if (std.ascii.startsWithIgnoreCase(target, prefix)) {
            return true;
        }
    }
    return false;
}

pub const Parts = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 1433,
    user: []const u8 = "",
    password: []const u8 = "",
    database: []const u8 = "",
    /// Whether the server's certificate has to check out. Off unless asked,
    /// because SQL Server makes its own on first start and nothing signs it -
    /// so on by default would mean nothing connects.
    verify: bool = false,
};

/// `mssql://user:password@host:port/database?trust=no`
pub fn parse(arena: std.mem.Allocator, target: []const u8) !Parts {
    var rest = target;
    for ([_][]const u8{ "mssql://", "sqlserver://" }) |prefix| {
        if (std.ascii.startsWithIgnoreCase(rest, prefix)) {
            rest = rest[prefix.len..];
            break;
        }
    }
    var out = Parts{};
    if (std.mem.indexOfScalar(u8, rest, '?')) |question| {
        var parameters = std.mem.tokenizeScalar(u8, rest[question + 1 ..], '&');
        while (parameters.next()) |parameter| {
            const equals = std.mem.indexOfScalar(u8, parameter, '=') orelse continue;
            const name = parameter[0..equals];
            const value = parameter[equals + 1 ..];
            if (std.ascii.eqlIgnoreCase(name, "database") or std.ascii.eqlIgnoreCase(name, "db")) {
                out.database = try targets.unescape(arena, value);
            } else if (std.ascii.eqlIgnoreCase(name, "verify") or std.ascii.eqlIgnoreCase(name, "encrypt")) {
                out.verify = !std.ascii.eqlIgnoreCase(value, "no") and !std.ascii.eqlIgnoreCase(value, "false") and !std.mem.eql(u8, value, "0");
            } else if (std.ascii.eqlIgnoreCase(name, "user")) {
                out.user = try targets.unescape(arena, value);
            } else if (std.ascii.eqlIgnoreCase(name, "password")) {
                out.password = try targets.unescape(arena, value);
            }
        }
        rest = rest[0..question];
    }
    // The last `@` divides them: a password may hold one, a host may not.
    if (std.mem.lastIndexOfScalar(u8, rest, '@')) |at| {
        const credentials = rest[0..at];
        rest = rest[at + 1 ..];
        if (std.mem.indexOfScalar(u8, credentials, ':')) |colon| {
            out.user = try targets.unescape(arena, credentials[0..colon]);
            out.password = try targets.unescape(arena, credentials[colon + 1 ..]);
        } else {
            out.user = try targets.unescape(arena, credentials);
        }
    }
    if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
        if (rest.len > slash + 1) {
            out.database = try targets.unescape(arena, rest[slash + 1 ..]);
        }
        rest = rest[0..slash];
    }
    if (rest.len != 0) {
        out.host = rest;
    }
    if (std.mem.lastIndexOfScalar(u8, out.host, ':')) |colon| {
        out.port = std.fmt.parseInt(u16, out.host[colon + 1 ..], 10) catch out.port;
        out.host = out.host[0..colon];
    }
    return out;
}

pub const Db = struct {
    allocator: std.mem.Allocator,
    connection: *tds.Connection,
    /// Where the rows of the answer being looked at live. Reset when the next
    /// one is asked for, which is what makes a cursor's memory bounded.
    replies: std.heap.ArenaAllocator,
    label: List = .empty,
    version_text: List = .empty,
    last_error: List = .empty,
    notes: List = .empty,
    database: List = .empty,
    /// How many transactions are open. The server says so as it goes, in the
    /// tokens that report a change of environment, so nothing has to ask.
    depth: usize = 0,
    progress: ?db.Progress = null,
    requests: usize = 0,

    pub fn open(allocator: std.mem.Allocator, target: []const u8, report: *List) !*Db {
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        const parts = try parse(scratch.allocator(), target);
        if (parts.password.len == 0) {
            // Said before connecting rather than after being refused: SQL Server
            // answers a missing password and a wrong one with the same sentence.
            return error.NeedPassword;
        }

        const connection = try tds.Connection.open(allocator, parts.host, parts.port, .{
            .verify = parts.verify,
        }, report);
        errdefer connection.close();

        const self = try allocator.create(Db);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .connection = connection,
            .replies = std.heap.ArenaAllocator.init(allocator),
        };
        errdefer self.replies.deinit();

        const welcome = connection.login(self.replies.allocator(), .{
            .user = parts.user,
            .password = parts.password,
            .database = parts.database,
        }, report) catch |e| {
            // A refused login is a wrong password, and asking for it again is
            // the useful answer.
            if (report.items.len != 0 and std.mem.indexOf(u8, report.items, "Login failed") != null) {
                return error.NeedPassword;
            }
            return e;
        };
        var trouble: List = .empty;
        defer trouble.deinit(allocator);
        // A wrong password is not an error from `login` - the login goes out and
        // the server answers with an error token - so this is where it turns up.
        // The errdefers above undo everything; calling `close` here as well is
        // what freed the connection twice.
        const reply = tds.read(self.replies.allocator(), welcome, &trouble, allocator) catch {
            try report.appendSlice(allocator, if (trouble.items.len != 0) trouble.items else "the server would not let this connection in");
            return if (std.mem.indexOf(u8, report.items, "Login failed") != null)
                error.NeedPassword
            else
                error.Driver;
        };
        try self.database.appendSlice(allocator, if (reply.database.len != 0) reply.database else parts.database);
        try self.label.print(allocator, "{s}@{s}:{d}/{s}", .{
            parts.user, parts.host, parts.port, self.database.items,
        });
        // Quoted identifiers, so `"name"` means a name here as it does
        // everywhere else in this program, and no implicit transactions.
        self.exec("SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON; SET IMPLICIT_TRANSACTIONS OFF") catch {};
        self.readVersion();
        return self;
    }

    fn readVersion(self: *Db) void {
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const arena = scratch.allocator();
        const reply = self.ask(arena, "SELECT CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(64)), CAST(SERVERPROPERTY('Edition') AS NVARCHAR(128))") catch return;
        if (reply.rows.len == 0) {
            return;
        }
        const product = text(reply.rows[0], 0);
        const edition = text(reply.rows[0], 1);
        // "Developer Edition (64-bit)" is the interesting half of what the
        // server calls itself; the header has no room for the rest.
        const short = if (std.mem.indexOfScalar(u8, edition, ' ')) |space| edition[0..space] else edition;
        self.version_text.print(self.allocator, "SQL Server {s}{s}{s}", .{
            product,
            if (short.len != 0) " " else "",
            short,
        }) catch {};
    }

    pub fn watch(self: *Db, progress: ?db.Progress) void {
        self.progress = progress;
        // What the socket asks between waits, so a statement that is taking too
        // long can be called off. Without it a `SELECT` over a big table holds
        // the whole interface until the server is finished with it.
        if (progress) |watcher| {
            self.connection.stream.keep_waiting = watcher.keep_going;
            self.connection.stream.context = watcher.context;
        } else {
            self.connection.stream.keep_waiting = null;
            self.connection.stream.context = null;
        }
    }

    pub fn close(self: *Db) void {
        self.connection.close();
        self.replies.deinit();
        self.label.deinit(self.allocator);
        self.version_text.deinit(self.allocator);
        self.last_error.deinit(self.allocator);
        self.notes.deinit(self.allocator);
        self.database.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn caps(_: *Db) db.Caps {
        return .{
            .schemas = true,
            // Not `databases`, even though a SQL Server has many and `USE` moves
            // between them. That flag means what it means on MySQL, where a
            // database *is* a schema and one switcher does for both. Here they
            // are two different things - a database holds schemas, and a name is
            // `database.schema.object` - and the one switcher is spent on the
            // schema. Another database is another connection, which is what its
            // URL already says.
            .label = "SQL Server",
            .text_cast = "NVARCHAR(MAX)",
            .text_prefix = "N",
            // Bytes are written bare and unquoted here: `0xDEADBEEF`, where
            // SQLite and MySQL take `x'DEADBEEF'`.
            .blob_prefix = "0x",
            .blob_suffix = "",
            .paging = .offset_fetch,
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
        return self.notes.items;
    }

    // ------------------------------------------------------------- statements

    /// One statement, there and back. Everything else in this file goes through
    /// here, which is the only place that touches the socket.
    fn talk(self: *Db, arena: std.mem.Allocator, sql: []const u8) db.Error!tds.Reply {
        self.last_error.clearRetainingCapacity();
        self.requests += 1;
        var trouble: List = .empty;
        defer trouble.deinit(self.allocator);
        const answer = self.connection.batch(arena, sql, &trouble) catch {
            self.remember(if (trouble.items.len != 0) trouble.items else "the connection to the server is gone");
            return error.Driver;
        };
        const reply = tds.read(arena, answer, &trouble, self.allocator) catch {
            self.remember(if (trouble.items.len != 0) trouble.items else "the server sent an answer this does not read");
            return error.Driver;
        };
        // The server reports each begin and each end as it happens, so the count
        // is kept from what it said rather than from what was asked for - which
        // is the only way to be right about a rollback inside a procedure.
        self.depth += reply.began;
        self.depth -|= reply.ended;
        if (reply.transaction) |which| {
            self.connection.transaction = which;
        }
        if (reply.database.len != 0) {
            self.database.clearRetainingCapacity();
            self.database.appendSlice(self.allocator, reply.database) catch {};
        }
        self.notes.clearRetainingCapacity();
        self.notes.appendSlice(self.allocator, reply.notes) catch {};
        return reply;
    }

    /// A statement of this file's own, into the caller's memory - so that asking
    /// the catalog a question does not throw away the rows on the screen.
    fn ask(self: *Db, arena: std.mem.Allocator, sql: []const u8) db.Error!tds.Reply {
        return self.talk(arena, sql);
    }

    fn remember(self: *Db, why: []const u8) void {
        self.last_error.clearRetainingCapacity();
        self.last_error.appendSlice(self.allocator, why) catch {};
    }

    fn starting(self: *Db) void {
        if (self.progress) |progress| {
            progress.starting();
        }
    }

    pub fn exec(self: *Db, sql: []const u8) db.Error!void {
        self.starting();
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        _ = try self.talk(scratch.allocator(), sql);
    }

    /// The batch was split before it got here, so `rest` is emptied.
    pub fn query(self: *Db, sql: []const u8, rest: ?*[]const u8) db.Error!?db.Rows {
        if (rest) |out| {
            out.* = sql[sql.len..];
        }
        const trimmed = std.mem.trim(u8, sql, " \t\r\n;");
        if (trimmed.len == 0) {
            return null;
        }
        self.starting();
        _ = self.replies.reset(.retain_capacity);
        const arena = self.replies.allocator();
        const reply = try self.talk(arena, trimmed);
        // No source table: TDS names one only for the old large types, so a
        // result read here cannot say which table its columns came from, and a
        // guess would decide whether a row can be edited. Browsing a table is
        // unaffected - the interface knows which table it opened and says so -
        // and what this costs is editing the result of a hand-written SELECT.
        return .{ .mssql = try self.rowsOf(arena, reply, "") };
    }

    fn rowsOf(self: *Db, arena: std.mem.Allocator, reply: tds.Reply, table: []const u8) db.Error!Rows {
        var names = try arena.alloc([]const u8, reply.columns.len);
        const numeric = try arena.alloc(bool, reply.columns.len);
        for (reply.columns, 0..) |column, i| {
            // A column with no name is an expression nobody labelled; the grid
            // needs something to put at the top of it.
            names[i] = if (column.name.len != 0)
                column.name
            else
                try std.fmt.allocPrint(arena, "column{d}", .{i + 1});
            numeric[i] = column.numeric();
        }
        var out = Rows{ .owner = self, .names = names, .numeric = numeric, .table = table, .changed = reply.affected };
        for (reply.rows) |row| {
            try out.add(row);
        }
        return out;
    }

    pub fn inTransaction(self: *Db) bool {
        return self.depth != 0;
    }

    // ---------------------------------------------------------- introspection

    fn text(row: []const db.Value, at: usize) []const u8 {
        if (at >= row.len) {
            return "";
        }
        return switch (row[at]) {
            .text => |value| value,
            .blob => |value| value,
            else => "",
        };
    }

    fn number(row: []const db.Value, at: usize) ?i64 {
        if (at >= row.len) {
            return null;
        }
        return switch (row[at]) {
            .int => |value| value,
            .float => |value| @intFromFloat(value),
            .text => |value| std.fmt.parseInt(i64, value, 10) catch null,
            else => null,
        };
    }

    fn yes(row: []const db.Value, at: usize) bool {
        return (number(row, at) orelse 0) != 0;
    }

    pub fn schemas(self: *Db, arena: std.mem.Allocator) db.Error![][]const u8 {
        // The fixed database roles each own a schema of the same name, and none
        // of them ever holds a table anybody made.
        const reply = try self.ask(arena,
            \\SELECT s.name FROM sys.schemas s
            \\ WHERE s.name NOT IN ('sys', 'INFORMATION_SCHEMA', 'guest')
            \\   AND s.name NOT LIKE 'db[_]%'
            \\ ORDER BY s.name
        );
        var list: std.ArrayListUnmanaged([]const u8) = .empty;
        for (reply.rows) |row| {
            try list.append(arena, text(row, 0));
        }
        return list.items;
    }

    pub fn objects(self: *Db, arena: std.mem.Allocator, schema: []const u8) db.Error![]db.Object {
        var sql: List = .empty;
        // The row count is the partition statistics, which is what the server
        // itself uses and costs nothing; an exact count is asked for per table
        // when one is shown.
        try sql.appendSlice(arena,
            \\SELECT o.name, o.type,
            \\  (SELECT SUM(p.rows) FROM sys.partitions p
            \\     WHERE p.object_id = o.object_id AND p.index_id IN (0, 1))
            \\ FROM sys.objects o JOIN sys.schemas s ON s.schema_id = o.schema_id
            \\ WHERE o.type IN ('U', 'V') AND s.name =
        );
        try db.quote(&sql, arena, if (schema.len != 0) schema else "dbo");
        try sql.appendSlice(arena, " ORDER BY o.name");
        const reply = try self.ask(arena, sql.items);

        var list: std.ArrayListUnmanaged(db.Object) = .empty;
        for (reply.rows) |row| {
            const kind = text(row, 1);
            try list.append(arena, .{
                .schema = if (schema.len != 0) schema else "dbo",
                .name = text(row, 0),
                .kind = if (kind.len != 0 and kind[0] == 'V') .view else .table,
                .rows = number(row, 2),
            });
        }
        return list.items;
    }

    pub fn columns(self: *Db, arena: std.mem.Allocator, table: db.Table) db.Error![]db.Column {
        var sql: List = .empty;
        // The type is written out the way it was declared: a length that means
        // "as long as you like" is stored as -1, and a character type counts
        // bytes where the column counts characters.
        try sql.appendSlice(arena,
            \\SELECT c.name,
            \\  t.name + CASE
            \\    WHEN t.name IN ('decimal','numeric') THEN '(' + CAST(c.precision AS VARCHAR(4)) + ',' + CAST(c.scale AS VARCHAR(4)) + ')'
            \\    WHEN t.name IN ('datetime2','time','datetimeoffset') AND c.scale <> 7 THEN '(' + CAST(c.scale AS VARCHAR(4)) + ')'
            \\    WHEN t.name IN ('varchar','char','varbinary','binary') THEN '(' + CASE WHEN c.max_length = -1 THEN 'max' ELSE CAST(c.max_length AS VARCHAR(8)) END + ')'
            \\    WHEN t.name IN ('nvarchar','nchar') THEN '(' + CASE WHEN c.max_length = -1 THEN 'max' ELSE CAST(c.max_length / 2 AS VARCHAR(8)) END + ')'
            \\    ELSE '' END,
            \\  c.is_nullable, d.definition, c.is_identity,
            \\  CASE WHEN EXISTS (SELECT 1 FROM sys.index_columns ic
            \\      JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
            \\      WHERE ic.object_id = c.object_id AND ic.column_id = c.column_id AND i.is_primary_key = 1)
            \\    THEN 1 ELSE 0 END,
            \\  CASE WHEN EXISTS (SELECT 1 FROM sys.index_columns ic
            \\      JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
            \\      WHERE ic.object_id = c.object_id AND ic.column_id = c.column_id AND i.is_unique = 1
            \\        AND i.is_primary_key = 0
            \\        AND (SELECT COUNT(*) FROM sys.index_columns k WHERE k.object_id = i.object_id AND k.index_id = i.index_id) = 1)
            \\    THEN 1 ELSE 0 END
            \\ FROM sys.columns c
            \\ JOIN sys.types t ON t.user_type_id = c.user_type_id
            \\ LEFT JOIN sys.default_constraints d ON d.object_id = c.default_object_id
            \\ WHERE c.object_id =
        );
        try appendObjectId(&sql, arena, table);
        try sql.appendSlice(arena, " ORDER BY c.column_id");
        const reply = try self.ask(arena, sql.items);

        var list: std.ArrayListUnmanaged(db.Column) = .empty;
        for (reply.rows) |row| {
            const name = text(row, 0);
            const dflt = text(row, 3);
            try list.append(arena, .{
                .name = name,
                .type = text(row, 1),
                .notnull = !yes(row, 2),
                // An identity column has no default in the catalog, but that is
                // where the form asks for one - and it is what somebody writing
                // a key wants to see.
                .dflt = if (yes(row, 4))
                    "IDENTITY(1,1)"
                else if (dflt.len == 0)
                    null
                else
                    stripBrackets(dflt),
                .pk = yes(row, 5),
                .unique = yes(row, 6),
                .original = name,
            });
        }
        return list.items;
    }

    pub fn indexes(self: *Db, arena: std.mem.Allocator, table: db.Table) db.Error![]db.Index {
        var sql: List = .empty;
        try sql.appendSlice(arena,
            \\SELECT i.name,
            \\  CASE WHEN i.is_primary_key = 1 THEN 'PRIMARY' WHEN i.is_unique = 1 THEN 'UNIQUE' ELSE 'INDEX' END,
            \\  STUFF((SELECT ', ' + c.name FROM sys.index_columns ic
            \\      JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
            \\      WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
            \\      ORDER BY ic.key_ordinal FOR XML PATH('')), 1, 2, ''),
            \\  i.has_filter
            \\ FROM sys.indexes i
            \\ WHERE i.index_id <> 0 AND i.object_id =
        );
        try appendObjectId(&sql, arena, table);
        try sql.appendSlice(arena, " ORDER BY i.is_primary_key DESC, i.name");
        const reply = try self.ask(arena, sql.items);

        var list: std.ArrayListUnmanaged(db.Index) = .empty;
        for (reply.rows) |row| {
            try list.append(arena, .{
                .name = text(row, 0),
                .kind = text(row, 1),
                .columns = text(row, 2),
                .partial = yes(row, 3),
            });
        }
        return list.items;
    }

    pub fn foreignKeys(self: *Db, arena: std.mem.Allocator, table: db.Table) db.Error![]db.ForeignKey {
        var sql: List = .empty;
        try sql.appendSlice(arena,
            \\SELECT c.name, rt.name, rc.name,
            \\  REPLACE(f.update_referential_action_desc, '_', ' '),
            \\  REPLACE(f.delete_referential_action_desc, '_', ' ')
            \\ FROM sys.foreign_keys f
            \\ JOIN sys.foreign_key_columns k ON k.constraint_object_id = f.object_id
            \\ JOIN sys.columns c ON c.object_id = k.parent_object_id AND c.column_id = k.parent_column_id
            \\ JOIN sys.objects rt ON rt.object_id = k.referenced_object_id
            \\ JOIN sys.columns rc ON rc.object_id = k.referenced_object_id AND rc.column_id = k.referenced_column_id
            \\ WHERE f.parent_object_id =
        );
        try appendObjectId(&sql, arena, table);
        try sql.appendSlice(arena, " ORDER BY f.name, k.constraint_column_id");
        const reply = try self.ask(arena, sql.items);

        var list: std.ArrayListUnmanaged(db.ForeignKey) = .empty;
        for (reply.rows) |row| {
            try list.append(arena, .{
                .column = text(row, 0),
                .target_table = text(row, 1),
                .target_column = text(row, 2),
                .on_update = text(row, 3),
                .on_delete = text(row, 4),
            });
        }
        return list.items;
    }

    /// What it would take to make this object again.
    ///
    /// The server kept the text of a view, so that is what a view gives back. It
    /// kept nothing of a table - a table is not written down anywhere as a
    /// statement - so a table is written out of the catalog instead. Returning
    /// nothing here is what left `CREATE TABLE` out of a dump.
    pub fn definition(self: *Db, arena: std.mem.Allocator, table: db.Table) db.Error!?[]const u8 {
        var sql: List = .empty;
        try sql.appendSlice(arena, "SELECT OBJECT_DEFINITION(");
        try appendObjectId(&sql, arena, table);
        try sql.appendSlice(arena, ")");
        if (self.ask(arena, sql.items)) |reply| {
            if (reply.rows.len != 0) {
                const body = text(reply.rows[0], 0);
                if (body.len != 0) {
                    return body;
                }
            }
        } else |_| {}

        const cols = self.columns(arena, table) catch return null;
        if (cols.len == 0) {
            return null;
        }
        const keys = self.foreignKeys(arena, table) catch &[_]db.ForeignKey{};
        var out: List = .empty;
        try (Ddl{}).createTable(&out, arena, table, cols, keys);
        return out.items;
    }

    pub fn rowCount(self: *Db, table: db.Table) ?i64 {
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const arena = scratch.allocator();
        var sql: List = .empty;
        sql.appendSlice(arena, "SELECT COUNT_BIG(*) FROM ") catch return null;
        db.quoteTable(&sql, arena, table) catch return null;
        const reply = self.ask(arena, sql.items) catch return null;
        if (reply.rows.len == 0) {
            return null;
        }
        return number(reply.rows[0], 0);
    }

    /// The primary key, or a unique index over columns that are all NOT NULL.
    pub fn rowKey(self: *Db, arena: std.mem.Allocator, table: db.Table) db.Error!db.RowKey {
        var sql: List = .empty;
        try sql.appendSlice(arena,
            \\SELECT TOP 1 STUFF((SELECT ',' + c.name FROM sys.index_columns ic
            \\    JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
            \\    WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
            \\    ORDER BY ic.key_ordinal FOR XML PATH('')), 1, 1, '')
            \\ FROM sys.indexes i
            \\ WHERE i.is_unique = 1 AND i.has_filter = 0 AND i.index_id <> 0
            \\   AND NOT EXISTS (SELECT 1 FROM sys.index_columns ic
            \\     JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
            \\     WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND c.is_nullable = 1)
            \\   AND i.object_id =
        );
        try appendObjectId(&sql, arena, table);
        try sql.appendSlice(arena, " ORDER BY i.is_primary_key DESC, i.index_id");
        const reply = self.ask(arena, sql.items) catch return .{};
        if (reply.rows.len == 0) {
            return .{};
        }
        const joined = text(reply.rows[0], 0);
        if (joined.len == 0) {
            return .{};
        }
        var list: std.ArrayListUnmanaged([]const u8) = .empty;
        var parts = std.mem.tokenizeScalar(u8, joined, ',');
        while (parts.next()) |part| {
            try list.append(arena, part);
        }
        return .{ .columns = list.items, .hidden = false };
    }

    /// Asked one at a time, so that a fact a given version does not have cannot
    /// take the whole listing down with it.
    const FACTS = [_][2][]const u8{
        .{ "server", "SELECT @@VERSION" },
        .{ "database", "SELECT DB_NAME()" },
        .{ "user", "SELECT SUSER_NAME()" },
        .{ "schema", "SELECT SCHEMA_NAME()" },
        .{ "collation", "SELECT CAST(DATABASEPROPERTYEX(DB_NAME(), 'Collation') AS NVARCHAR(128))" },
        .{ "recovery", "SELECT CAST(DATABASEPROPERTYEX(DB_NAME(), 'Recovery') AS NVARCHAR(64))" },
        .{ "size", "SELECT CAST(CAST(SUM(size) * 8.0 / 1024 AS DECIMAL(12,1)) AS NVARCHAR(32)) + ' MB' FROM sys.database_files" },
        .{ "tables", "SELECT CAST(COUNT(*) AS NVARCHAR(16)) FROM sys.objects WHERE type = 'U'" },
        .{ "connections", "SELECT CAST(COUNT(*) AS NVARCHAR(16)) FROM sys.dm_exec_sessions WHERE is_user_process = 1" },
        .{ "started", "SELECT CONVERT(NVARCHAR(19), sqlserver_start_time, 120) FROM sys.dm_os_sys_info" },
        .{ "role", "SELECT CASE WHEN DATABASEPROPERTYEX(DB_NAME(), 'Updateability') = 'READ_ONLY' THEN 'replica' ELSE 'primary' END" },
    };

    pub fn settings(self: *Db, arena: std.mem.Allocator) db.Error![]db.Setting {
        var list: std.ArrayListUnmanaged(db.Setting) = .empty;
        for (FACTS) |fact| {
            const reply = self.ask(arena, fact[1]) catch continue;
            if (reply.rows.len == 0) {
                continue;
            }
            var value = text(reply.rows[0], 0);
            // @@VERSION is four lines of copyright with the useful part first.
            if (std.mem.indexOfAny(u8, value, "\r\n")) |end| {
                value = value[0..end];
            }
            try list.append(arena, .{ .label = fact[0], .value = value });
        }
        return list.items;
    }

    /// SQL Server alters in place, so an alter has nothing to carry over.
    pub fn alterContext(_: *Db, _: std.mem.Allocator, _: db.Table, cols: []const db.Column) db.Error!db.AlterContext {
        return .{ .columns = cols };
    }

    /// `OBJECT_ID('"schema"."name"')`, which every catalog query keys off.
    fn appendObjectId(out: *List, a: std.mem.Allocator, table: db.Table) !void {
        var name: List = .empty;
        try db.quoteTable(&name, a, table);
        try out.appendSlice(a, "OBJECT_ID(");
        try db.quote(out, a, name.items);
        try out.append(a, ')');
    }

    /// `GO` is not a statement - it is where a client is told to stop and send
    /// what it has - so it is cut on here before the statements are, and it is
    /// the reason a `CREATE VIEW` in a script works at all.
    pub fn split(_: *Db, arena: std.mem.Allocator, sql: []const u8) db.Error![]db.Statement {
        var list: std.ArrayListUnmanaged(db.Statement) = .empty;
        var start: usize = 0;
        var at: usize = 0;
        while (at <= sql.len) {
            const end = std.mem.indexOfScalarPos(u8, sql, at, '\n') orelse sql.len;
            if (isGo(sql[at..end])) {
                for (try db.splitStatements(arena, sql[start..at], .{ .brackets = true })) |one| {
                    try list.append(arena, one);
                }
                start = @min(end + 1, sql.len);
            }
            if (end == sql.len) {
                break;
            }
            at = end + 1;
        }
        for (try db.splitStatements(arena, sql[start..], .{ .brackets = true })) |one| {
            try list.append(arena, one);
        }
        return list.items;
    }

    fn isGo(line: []const u8) bool {
        return std.ascii.eqlIgnoreCase(std.mem.trim(u8, line, " \t\r"), "GO");
    }

    pub fn ddl(_: *Db) db.Ddl {
        return .{ .mssql = .{} };
    }
};

/// The catalog keeps a default wrapped in as many brackets as it took to parse
/// it: `((0))` for zero. One layer is the constraint's own and the rest is the
/// expression's, and none of them mean anything to read.
fn stripBrackets(text: []const u8) []const u8 {
    var out = text;
    while (out.len >= 2 and out[0] == '(' and out[out.len - 1] == ')') {
        // Only when the first bracket really closes at the end - `(a)+(b)` is
        // not a wrapped expression and must not lose its brackets.
        var depth: usize = 0;
        for (out, 0..) |char, i| {
            if (char == '(') {
                depth += 1;
            } else if (char == ')') {
                depth -= 1;
                if (depth == 0 and i != out.len - 1) {
                    return out;
                }
            }
        }
        out = out[1 .. out.len - 1];
    }
    return out;
}

// ---------------------------------------------------------------------- DDL

pub const Ddl = struct {
    pub fn types(_: Ddl) []const []const u8 {
        return &[_][]const u8{
            "int",              "bigint",         "nvarchar(255)", "nvarchar(max)",
            "decimal(10,2)",    "datetime2",      "date",          "bit",
            "uniqueidentifier", "varbinary(max)", "float",         "money",
        };
    }

    /// `"name" type NOT NULL DEFAULT …`, as both CREATE and ALTER need it.
    fn columnSpec(out: *List, a: std.mem.Allocator, column: db.Column, with_default: bool) !void {
        // A key column cannot be empty, and SQL Server says so rather than
        // deciding for itself the way the other engines here do - so a form that
        // ticked "primary key" and left "not null" alone means both.
        const notnull = column.notnull or column.pk;
        try db.quoteName(out, a, column.name);
        try out.append(a, ' ');
        try out.appendSlice(a, if (column.type.len != 0) column.type else "nvarchar(255)");
        // IDENTITY is where a column says it numbers itself, and it goes before
        // the nullability rather than where a default would.
        const identity = column.dflt != null and std.ascii.startsWithIgnoreCase(column.dflt.?, "IDENTITY");
        if (identity) {
            try out.append(a, ' ');
            try out.appendSlice(a, column.dflt.?);
        }
        try out.appendSlice(a, if (notnull) " NOT NULL" else " NULL");
        if (column.unique) {
            try out.appendSlice(a, " UNIQUE");
        }
        if (with_default and !identity) {
            if (column.dflt) |value| {
                if (value.len != 0) {
                    try out.appendSlice(a, " DEFAULT ");
                    try out.appendSlice(a, value);
                }
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
        try out.appendSlice(a, "CREATE TABLE ");
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
            try columnSpec(out, a, column, true);
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
        try out.appendSlice(a, "\n);\n");
    }

    /// SQL Server alters in place, but a change and an addition are different
    /// statements, and a rename is not a statement at all - it is a procedure.
    ///
    /// A default is a constraint of its own here rather than part of the column,
    /// so ALTER COLUMN cannot carry one: changing a column's type leaves its
    /// default alone, which is why none is written.
    pub fn alterTable(_: Ddl, out: *List, a: std.mem.Allocator, table: db.Table, new_name: []const u8, cols: []const db.Column, context: db.AlterContext) !void {
        _ = context;
        for (cols) |column| {
            if (column.original.len != 0 and !std.mem.eql(u8, column.original, column.name)) {
                try out.appendSlice(a, "EXEC sp_rename ");
                var full: List = .empty;
                try db.quoteTable(&full, a, table);
                try full.append(a, '.');
                try db.quoteName(&full, a, column.original);
                try db.quote(out, a, full.items);
                try out.appendSlice(a, ", ");
                try db.quote(out, a, column.name);
                try out.appendSlice(a, ", 'COLUMN';\n");
            }
            try out.appendSlice(a, "ALTER TABLE ");
            try db.quoteTable(out, a, table);
            if (column.original.len == 0) {
                try out.appendSlice(a, " ADD ");
                try columnSpec(out, a, column, true);
            } else {
                try out.appendSlice(a, " ALTER COLUMN ");
                try columnSpec(out, a, column, false);
            }
            try out.appendSlice(a, ";\n");
        }
        if (new_name.len != 0 and !std.mem.eql(u8, new_name, table.name)) {
            try renameTable(.{}, out, a, table, new_name);
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

    /// A filtered index is SQL Server's partial index, and takes the same WHERE.
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

    /// A view has to be the only statement in its batch, which is what the `GO`
    /// after it is for.
    pub fn createView(_: Ddl, out: *List, a: std.mem.Allocator, table: db.Table, select: []const u8) !void {
        try out.appendSlice(a, "CREATE VIEW ");
        try db.quoteTable(out, a, table);
        try out.appendSlice(a, " AS\n");
        try out.appendSlice(a, select);
        try out.appendSlice(a, ";\nGO\n");
    }

    /// A trigger here fires once for a statement and is handed the rows in the
    /// `inserted` and `deleted` tables, rather than once per row with the row in
    /// hand - so the body somebody writes is not the same body as elsewhere.
    pub fn createTrigger(_: Ddl, out: *List, a: std.mem.Allocator, table: db.Table, name: []const u8, when: []const u8, event: []const u8, condition: []const u8, action: []const u8) !void {
        try out.appendSlice(a, "CREATE TRIGGER ");
        try db.quoteName(out, a, name);
        try out.appendSlice(a, " ON ");
        try db.quoteTable(out, a, table);
        // BEFORE has no equivalent: the nearest is INSTEAD OF, which replaces
        // the statement rather than running ahead of it, and saying so is
        // better than writing something that does not compile.
        if (std.ascii.eqlIgnoreCase(when, "BEFORE")) {
            try out.appendSlice(a, " INSTEAD OF ");
        } else if (std.ascii.eqlIgnoreCase(when, "INSTEAD OF")) {
            try out.appendSlice(a, " INSTEAD OF ");
        } else {
            try out.appendSlice(a, " AFTER ");
        }
        try out.appendSlice(a, event);
        try out.appendSlice(a, "\nAS\nBEGIN\n");
        if (condition.len != 0) {
            try out.appendSlice(a, "\tIF ");
            try out.appendSlice(a, condition);
            try out.appendSlice(a, "\n");
        }
        try out.appendSlice(a, "\t");
        try out.appendSlice(a, action);
        try out.appendSlice(a, "\nEND;\nGO\n");
    }

    /// A rename is a stored procedure, and it takes the new name without a
    /// schema on it - the table does not move.
    pub fn renameTable(_: Ddl, out: *List, a: std.mem.Allocator, table: db.Table, to: []const u8) !void {
        try out.appendSlice(a, "EXEC sp_rename ");
        var full: List = .empty;
        try db.quoteTable(&full, a, table);
        try db.quote(out, a, full.items);
        try out.appendSlice(a, ", ");
        try db.quote(out, a, to);
        try out.appendSlice(a, ";\n");
    }

    /// `SELECT INTO` makes the table and fills it in one statement; a condition
    /// that no row meets makes the table and leaves it empty.
    pub fn copyTable(_: Ddl, out: *List, a: std.mem.Allocator, table: db.Table, to: []const u8, with_rows: bool) !void {
        try out.appendSlice(a, "SELECT * INTO ");
        try db.quoteTable(out, a, .{ .schema = table.schema, .name = to });
        try out.appendSlice(a, " FROM ");
        try db.quoteTable(out, a, table);
        if (!with_rows) {
            try out.appendSlice(a, " WHERE 1 = 0");
        }
        try out.appendSlice(a, ";\n");
    }

    pub fn dropObject(_: Ddl, out: *List, a: std.mem.Allocator, kind: db.Kind, table: db.Table) !void {
        try out.appendSlice(a, if (kind == .view) "DROP VIEW " else "DROP TABLE ");
        try db.quoteTable(out, a, table);
        try out.appendSlice(a, ";\n");
    }

    /// `"name"` means a name only where the session says so, and that is not
    /// the default everywhere - `sqlcmd` still starts with it off, and a file
    /// full of quoted identifiers is a file it refuses to parse. So the dump
    /// says what it needs rather than depending on where it lands. It takes
    /// effect for the batches after it, which is what the `GO` is for.
    pub fn prologue(_: Ddl, out: *List, a: std.mem.Allocator) !void {
        try out.appendSlice(a, "SET QUOTED_IDENTIFIER ON;\nGO\n");
    }

    /// A column that numbers itself refuses a value - so a dump of a table with
    /// one has to say, table by table, that this time the values are wanted.
    /// Without it the commonest shape of table here dumps to a file that will
    /// not go back in.
    pub fn beforeRows(_: Ddl, out: *List, a: std.mem.Allocator, table: db.Table, cols: []const db.Column) !void {
        if (!numbersItself(cols)) {
            return;
        }
        try identityInsert(out, a, table, "ON");
    }

    pub fn afterRows(_: Ddl, out: *List, a: std.mem.Allocator, table: db.Table, cols: []const db.Column) !void {
        if (!numbersItself(cols)) {
            return;
        }
        try identityInsert(out, a, table, "OFF");
    }

    fn numbersItself(cols: []const db.Column) bool {
        for (cols) |column| {
            if (column.dflt) |value| {
                if (std.ascii.startsWithIgnoreCase(value, "IDENTITY")) {
                    return true;
                }
            }
        }
        return false;
    }

    fn identityInsert(out: *List, a: std.mem.Allocator, table: db.Table, state: []const u8) !void {
        try out.appendSlice(a, "SET IDENTITY_INSERT ");
        try db.quoteTable(out, a, table);
        try out.append(a, ' ');
        try out.appendSlice(a, state);
        try out.appendSlice(a, ";\n");
    }

    pub fn truncate(_: Ddl, out: *List, a: std.mem.Allocator, table: db.Table) !void {
        try out.appendSlice(a, "TRUNCATE TABLE ");
        try db.quoteTable(out, a, table);
        try out.appendSlice(a, ";\n");
    }
};

// ------------------------------------------------------------------- cursor

/// Rows the driver read whole, because a TDS answer arrives whole: the server
/// sends every row of a result before it says the statement is over. There is
/// nothing to stream, so there is no cursor to write.
pub const Rows = db.Built(Db, db.Value);

// ------------------------------------------------------------------- tests

const testing = std.testing;

test "a target is taken apart the way a SQL Server client would" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    {
        const parts = try parse(arena, "mssql://sa:hunter2@db.example:1444/objednavky");
        try testing.expectEqualStrings("db.example", parts.host);
        try testing.expectEqual(@as(u16, 1444), parts.port);
        try testing.expectEqualStrings("sa", parts.user);
        try testing.expectEqualStrings("hunter2", parts.password);
        try testing.expectEqualStrings("objednavky", parts.database);
        try testing.expect(!parts.verify);
    }
    {
        // No port and no database: the usual port and whatever the login lands in.
        const parts = try parse(arena, "sqlserver://sa@127.0.0.1");
        try testing.expectEqual(@as(u16, 1433), parts.port);
        try testing.expectEqualStrings("", parts.database);
    }
    {
        // A password with an `@` in it: the last one divides, not the first.
        const parts = try parse(arena, "mssql://sa:a@b@localhost/master");
        try testing.expectEqualStrings("a@b", parts.password);
        try testing.expectEqualStrings("localhost", parts.host);
    }
    {
        // Escaped, because a password with a slash in it cannot be written plainly.
        const parts = try parse(arena, "mssql://sa:he%2Fslo@h/d?verify=yes");
        try testing.expectEqualStrings("he/slo", parts.password);
        try testing.expect(parts.verify);
    }
}

test "a SQL Server target is told apart from the others" {
    try testing.expect(owns("mssql://sa@h/d"));
    try testing.expect(owns("SQLSERVER://sa@h/d"));
    try testing.expect(!owns("mysql://root@h/d"));
    try testing.expect(!owns("postgres://p@h/d"));
}

test "a default keeps its meaning and loses its brackets" {
    // The catalog wraps a default in as many brackets as it took to parse.
    try testing.expectEqualStrings("0", stripBrackets("((0))"));
    try testing.expectEqualStrings("getdate()", stripBrackets("(getdate())"));
    try testing.expectEqualStrings("N'-'", stripBrackets("(N'-')"));
    // Not a wrapped expression: the first bracket closes before the end, and
    // taking the outer pair off would change what it means.
    try testing.expectEqualStrings("(a)+(b)", stripBrackets("(a)+(b)"));
}

test "GO ends a batch, and is not a statement" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var nothing: Db = undefined;
    const parts = try nothing.split(arena,
        \\create view v as select 1 as a
        \\GO
        \\select * from v;
        \\select 2
    );
    try testing.expectEqual(@as(usize, 3), parts.len);
    try testing.expectEqualStrings("create view v as select 1 as a", std.mem.trim(u8, parts[0].sql, " \t\r\n;"));
    try testing.expectEqualStrings("select * from v", std.mem.trim(u8, parts[1].sql, " \t\r\n;"));
    try testing.expectEqualStrings("select 2", std.mem.trim(u8, parts[2].sql, " \t\r\n;"));
    // A word that merely starts with those letters is not a separator.
    const gone = try nothing.split(arena, "select 'GOING'");
    try testing.expectEqual(@as(usize, 1), gone.len);
}

test "an identity column says so where the form asks for it" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var out: List = .empty;
    try (Ddl{}).createTable(&out, arena, .{ .schema = "dbo", .name = "t" }, &.{
        .{ .name = "id", .type = "int", .notnull = true, .pk = true, .dflt = "IDENTITY(1,1)" },
        .{ .name = "nazev", .type = "nvarchar(80)", .notnull = true },
        .{ .name = "cena", .type = "decimal(10,2)", .dflt = "0" },
    }, &.{});
    // IDENTITY goes with the type and not where a default would, and a column
    // that numbers itself has no default besides.
    try testing.expect(std.mem.indexOf(u8, out.items, "\"id\" int IDENTITY(1,1) NOT NULL") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "DEFAULT IDENTITY") == null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"cena\" decimal(10,2) NULL DEFAULT 0") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "PRIMARY KEY (\"id\")") != null);
}

test "a key column is not nullable, whether or not the form said so" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    var out: List = .empty;
    // What the create-table form hands over with nothing but a name typed in:
    // the key is ticked and the nullability is not. SQLite and MySQL take that
    // and decide for themselves; SQL Server refuses the table outright.
    try (Ddl{}).createTable(&out, scratch.allocator(), .{ .schema = "dbo", .name = "t" }, &.{
        .{ .name = "id", .type = "int", .pk = true },
        .{ .name = "column", .type = "int" },
    }, &.{});
    try testing.expect(std.mem.indexOf(u8, out.items, "\"id\" int NOT NULL") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"column\" int NULL") != null);
}

test "a renamed column is a procedure call, and the rest is an alter" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var out: List = .empty;
    try (Ddl{}).alterTable(&out, arena, .{ .schema = "dbo", .name = "t" }, "u", &.{
        .{ .name = "novy", .original = "stary", .type = "int", .notnull = true },
        .{ .name = "pridany", .original = "", .type = "bit" },
    }, .{});
    try testing.expect(std.mem.indexOf(u8, out.items, "EXEC sp_rename '\"dbo\".\"t\".\"stary\"', 'novy', 'COLUMN';") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "ALTER COLUMN \"novy\" int NOT NULL") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "ADD \"pridany\" bit NULL") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "EXEC sp_rename '\"dbo\".\"t\"', 'u';") != null);
}

// Against a real server, and only where one is offered: `KRTEK_MSSQL` holds
// `host:port:user:password`. Everything here happens in `tempdb`, which is what
// SQL Server keeps for exactly this and empties when it restarts.
test "every schema statement this writes is one the server takes" {
    const said = @import("targets.zig").getenv("KRTEK_MSSQL") orelse return error.SkipZigTest;
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    var parts = std.mem.splitScalar(u8, said, ':');
    const host = parts.next() orelse return error.SkipZigTest;
    const port = parts.next() orelse "1433";
    const user = parts.next() orelse "sa";
    const password = parts.rest();
    const target = try std.fmt.allocPrint(arena, "mssql://{s}:{s}@{s}:{s}/tempdb", .{ user, password, host, port });

    var report: List = .empty;
    defer report.deinit(testing.allocator);
    const self = Db.open(testing.allocator, target, &report) catch {
        std.debug.print("nespojeno: {s}\n", .{report.items});
        return error.TestUnexpectedResult;
    };
    defer self.close();

    const table = db.Table{ .schema = "dbo", .name = "krtek_ddl" };
    self.exec("IF OBJECT_ID('dbo.krtek_ddl') IS NOT NULL DROP TABLE dbo.krtek_ddl") catch {};
    self.exec("IF OBJECT_ID('dbo.krtek_ddl_2') IS NOT NULL DROP TABLE dbo.krtek_ddl_2") catch {};
    self.exec("IF OBJECT_ID('dbo.krtek_kopie') IS NOT NULL DROP TABLE dbo.krtek_kopie") catch {};
    self.exec("IF OBJECT_ID('dbo.krtek_pohled') IS NOT NULL DROP VIEW dbo.krtek_pohled") catch {};

    // Each statement below is written by this file and then run as written: a
    // statement only ever compared to a string this same file wrote proves
    // nothing about whether the server would take it.
    const dialect = Ddl{};
    var out: List = .empty;
    const check = struct {
        fn run(owner: *Db, what: []const u8, sql: []const u8) !void {
            for (try owner.split(std.heap.page_allocator, sql)) |statement| {
                const trimmed = std.mem.trim(u8, statement.sql, " \t\r\n;");
                if (trimmed.len == 0) {
                    continue;
                }
                owner.exec(trimmed) catch {
                    std.debug.print("{s} odmitnuto: {s}\n  {s}\n", .{ what, owner.message(), trimmed });
                    return error.TestUnexpectedResult;
                };
            }
        }
    }.run;

    try dialect.createTable(&out, arena, table, &.{
        .{ .name = "id", .type = "int", .notnull = true, .pk = true, .dflt = "IDENTITY(1,1)" },
        .{ .name = "nazev", .type = "nvarchar(80)", .notnull = true },
        .{ .name = "cena", .type = "decimal(10,2)", .dflt = "0" },
    }, &.{});
    try check(self, "create table", out.items);

    // A second table, so a foreign key has somewhere to point.
    out.clearRetainingCapacity();
    try dialect.createTable(&out, arena, .{ .schema = "dbo", .name = "krtek_ddl_2" }, &.{
        .{ .name = "id", .type = "int", .notnull = true, .pk = true },
        .{ .name = "krtek_ddl_id", .type = "int" },
    }, &.{});
    try check(self, "create table s klicem", out.items);

    out.clearRetainingCapacity();
    try dialect.addForeignKey(&out, arena, .{ .schema = "dbo", .name = "krtek_ddl_2" }, .{
        .column = "krtek_ddl_id",
        .target_table = "krtek_ddl",
        .target_column = "id",
        .on_delete = "CASCADE",
    }, .{});
    try check(self, "foreign key", out.items);

    out.clearRetainingCapacity();
    try dialect.createIndex(&out, arena, table, "ix_krtek_nazev", &.{"nazev"}, false, "");
    try check(self, "index", out.items);

    out.clearRetainingCapacity();
    try dialect.createIndex(&out, arena, table, "ix_krtek_cena", &.{"cena"}, false, "\"cena\" > 0");
    try check(self, "filtrovany index", out.items);

    out.clearRetainingCapacity();
    try dialect.alterTable(&out, arena, table, "", &.{
        .{ .name = "popis", .original = "", .type = "nvarchar(200)" },
        .{ .name = "jmeno", .original = "nazev", .type = "nvarchar(120)", .notnull = true },
    }, .{});
    try check(self, "alter", out.items);

    out.clearRetainingCapacity();
    try dialect.createView(&out, arena, .{ .schema = "dbo", .name = "krtek_pohled" }, "SELECT \"id\", \"jmeno\" FROM \"dbo\".\"krtek_ddl\"");
    try check(self, "view", out.items);

    out.clearRetainingCapacity();
    try dialect.copyTable(&out, arena, table, "krtek_kopie", false);
    try check(self, "copy", out.items);

    out.clearRetainingCapacity();
    try dialect.truncate(&out, arena, .{ .schema = "dbo", .name = "krtek_kopie" });
    try check(self, "truncate", out.items);

    // What the alter did is what the catalog now says, which is the other half
    // of a schema change working: it has to be readable afterwards.
    const cols = try self.columns(arena, table);
    var found_renamed = false;
    var found_added = false;
    for (cols) |one| {
        if (std.mem.eql(u8, one.name, "jmeno")) {
            found_renamed = true;
            try testing.expectEqualStrings("nvarchar(120)", one.type);
            try testing.expect(one.notnull);
        }
        if (std.mem.eql(u8, one.name, "popis")) {
            found_added = true;
        }
    }
    try testing.expect(found_renamed);
    try testing.expect(found_added);

    const keys = try self.foreignKeys(arena, .{ .schema = "dbo", .name = "krtek_ddl_2" });
    try testing.expectEqual(@as(usize, 1), keys.len);
    try testing.expectEqualStrings("krtek_ddl", keys[0].target_table);
    try testing.expectEqualStrings("CASCADE", keys[0].on_delete);

    const list = try self.indexes(arena, table);
    var filtered = false;
    for (list) |one| {
        if (std.mem.eql(u8, one.name, "ix_krtek_cena")) {
            filtered = one.partial;
        }
    }
    try testing.expect(filtered);

    const body = try self.definition(arena, .{ .schema = "dbo", .name = "krtek_pohled" });
    try testing.expect(body != null);
    try testing.expect(std.mem.indexOf(u8, body.?, "jmeno") != null);

    // And a rename, last, because everything above named the table.
    out.clearRetainingCapacity();
    try dialect.renameTable(&out, arena, table, "krtek_prejmenovana");
    try check(self, "rename", out.items);

    out.clearRetainingCapacity();
    try dialect.dropObject(&out, arena, .view, .{ .schema = "dbo", .name = "krtek_pohled" });
    try check(self, "drop view", out.items);
    for ([_][]const u8{ "krtek_ddl_2", "krtek_prejmenovana", "krtek_kopie" }) |name| {
        out.clearRetainingCapacity();
        try dialect.dropObject(&out, arena, .table, .{ .schema = "dbo", .name = name });
        try check(self, "drop table", out.items);
    }
}

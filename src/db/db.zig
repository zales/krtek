//! The database interface every engine implements.
//!
//! Zig has no interfaces, so `Db` is a tagged union dispatched with `inline
//! else`: each method forwards to the driver of the active tag. Adding an
//! engine means adding one union member and a struct with the same method
//! names - the compiler then names anything that is missing. No vtables to
//! wire up and no dynamic dispatch.
//!
//! The rule for the drivers: everything engine specific lives behind this file.
//! The user interface may not know what a PRAGMA or a pg_catalog is.

const std = @import("std");

pub const sqlite = @import("sqlite.zig");
pub const postgres = @import("postgres.zig");
const mysql = @import("mysql.zig");
pub const redis = @import("redis.zig");
pub const kafka = @import("kafka.zig");
pub const s3 = @import("s3.zig");
pub const azure = @import("azure.zig");
pub const rabbit = @import("rabbit.zig");
pub const sftp = @import("sftp.zig");
pub const k8s = @import("k8s.zig");
pub const k8s_yaml = @import("k8s/yaml.zig");
pub const k8s_exec = @import("k8s/exec.zig");
pub const k8s_config = @import("k8s/config.zig");
pub const k8s_api = @import("k8s/api.zig");
pub const k8s_target = @import("k8s/target.zig");

/// A socket that may have TLS on it, and HTTP over it: what the drivers that
/// speak their own protocol share.
/// libssh2, and the SFTP driver over it: the one protocol here that is a
/// library rather than written out.
pub const ssh = @import("ssh.zig");
pub const net = @import("net.zig");
pub const http = @import("http.zig");
pub const sigv4 = @import("s3/sigv4.zig");

/// What the interface asks for, as a structure: see the file for why.
pub const ask = @import("ask.zig");

/// Places that hold files, and copying between them.
pub const store = @import("store.zig");

// Every driver brings its own tests. A plain import is not enough to run them -
// analysis is lazy, so a file nothing reaches into contributes no tests - which
// is why they are named here.
comptime {
	_ = ask;
	_ = store;
	_ = sqlite;
	_ = postgres;
	_ = mysql;
	_ = redis;
	_ = kafka;
	_ = s3;
	_ = azure;
	_ = rabbit;
	_ = sftp;
	_ = k8s;
	_ = k8s_yaml;
	_ = k8s_exec;
	_ = k8s_config;
	_ = k8s_api;
	_ = k8s_target;
	_ = net;
	_ = http;
	_ = ssh;
	_ = sigv4;
}

pub const Error = error{ Driver, OutOfMemory };

/// Called by a driver every so often while a statement is running. Returning
/// false abandons it: SQLite stops its virtual machine, PostgreSQL sends a
/// cancel request to the server. What the callback does meanwhile - draw a
/// spinner, look at the keyboard - is none of the interface's business.
pub const Progress = struct {
	context: *anyopaque,
	keep_going: *const fn (context: *anyopaque) bool,
	/// Called by a driver when it starts a statement. Without it the caller would
	/// have to guess where one statement ends and the next begins, and guessing
	/// from the gap between calls is wrong exactly when it matters: a query whose
	/// rows arrive seconds apart looks like a new statement every time.
	begin: *const fn (context: *anyopaque) void,

	pub fn call(self: Progress) bool {
		return self.keep_going(self.context);
	}

	pub fn starting(self: Progress) void {
		self.begin(self.context);
	}
};

/// One cell. Text and blob point into the driver's memory and stay valid until
/// the cursor moves on.
pub const Value = union(enum) {
	null: void,
	int: i64,
	float: f64,
	text: []const u8,
	blob: []const u8,
};

pub const Kind = enum { table, view };

pub const Object = struct {
	/// Empty on an engine without schemas.
	schema: []const u8 = "",
	name: []const u8,
	kind: Kind = .table,
	rows: ?i64 = null,
	/// The engine's own housekeeping rather than the user's data - Kafka's
	/// __consumer_offsets. Still shown, because looking at it is sometimes the
	/// point, but left out of a dump.
	internal: bool = false,
};

pub const Column = struct {
	name: []const u8,
	type: []const u8 = "",
	notnull: bool = false,
	dflt: ?[]const u8 = null,
	pk: bool = false,
	unique: bool = false,
	/// What this column was called before an alter form touched it.
	original: []const u8 = "",
};

pub const Index = struct {
	name: []const u8,
	/// PRIMARY, UNIQUE or INDEX.
	kind: []const u8,
	columns: []const u8,
	partial: bool = false,
};

pub const ForeignKey = struct {
	column: []const u8,
	target_table: []const u8,
	target_column: []const u8,
	on_update: []const u8 = "NO ACTION",
	on_delete: []const u8 = "NO ACTION",
};

pub const Setting = struct {
	label: []const u8,
	value: []const u8,
};

/// What the interface may ask of this engine.
pub const Caps = struct {
	/// Tables live in schemas the user can switch between.
	schemas: bool = false,
	/// A row can be addressed without a key, through a hidden column.
	hidden_row_id: bool = false,
	/// Changing a column means writing a new table and copying the rows.
	rebuild_to_alter: bool = false,
	/// Several databases are reachable from one connection.
	databases: bool = false,
	/// The name shown in the interface.
	label: []const u8 = "",
	/// What to cast a value to in order to compare it as text. Every engine
	/// spells it differently and MySQL does not know `TEXT` as a cast target.
	text_cast: []const u8 = "TEXT",
	/// The engine takes SQL. When it does not, the interface asks for rows only
	/// through `ask.Select` and changes them only through `ask.Change`, and what
	/// the user writes in the editor is passed to the engine as its own kind of
	/// command - which turns the editor into a console for it.
	speaks_sql: bool = true,
	/// A dump can hold this engine's rows. False where a row only *names* bytes
	/// kept elsewhere: an S3 listing without the objects is a list, and replaying
	/// it would put empty objects where the data was.
	dumps_rows: bool = true,
	/// A deleted row does not come back. A database has a transaction to take one
	/// out of and a cluster has nothing of the kind, so `x` asks first - the same
	/// way it does where a row is a file.
	final_deletes: bool = false,
	/// What one row is called, where "row" is the wrong word for it.
	row_noun: []const u8 = "row",
	/// A row can be added. False where the rows are things this program can read
	/// and remove but has no business making: a Kubernetes object is a document
	/// with a controller behind it, and an empty grid there must not offer `i`.
	inserts_rows: bool = true,
};

/// One statement out of a batch, with the text the user wrote.
pub const Statement = struct {
	sql: []const u8,
};

// ------------------------------------------------------------------ cursors

pub const Rows = union(enum) {
	sqlite: sqlite.Rows,
	postgres: postgres.Rows,
	mysql: mysql.Rows,
	redis: redis.Rows,
	kafka: kafka.Rows,
	s3: s3.Rows,
	azure: azure.Rows,
	rabbit: rabbit.Rows,
	sftp: sftp.Rows,
	k8s: k8s.Rows,

	pub fn next(self: *Rows) Error!bool {
		switch (self.*) {
			inline else => |*rows| return rows.next(),
		}
	}

	pub fn close(self: *Rows) void {
		switch (self.*) {
			inline else => |*rows| rows.close(),
		}
	}

	pub fn columnCount(self: *Rows) usize {
		switch (self.*) {
			inline else => |*rows| return rows.columnCount(),
		}
	}

	pub fn name(self: *Rows, at: usize) []const u8 {
		switch (self.*) {
			inline else => |*rows| return rows.name(at),
		}
	}

	pub fn value(self: *Rows, at: usize) Value {
		switch (self.*) {
			inline else => |*rows| return rows.value(at),
		}
	}

	/// The table a column comes from, empty when it is an expression. Used to
	/// decide whether a query result can be edited.
	pub fn sourceTable(self: *Rows, at: usize) []const u8 {
		switch (self.*) {
			inline else => |*rows| return rows.sourceTable(at),
		}
	}

	pub fn sourceColumn(self: *Rows, at: usize) []const u8 {
		switch (self.*) {
			inline else => |*rows| return rows.sourceColumn(at),
		}
	}

	/// Whether the column holds numbers, so the grid can align it right even
	/// when the engine hands the value over as text.
	pub fn isNumeric(self: *Rows, at: usize) bool {
		switch (self.*) {
			inline else => |*rows| return rows.isNumeric(at),
		}
	}

	/// Rows changed by this statement, once it has been walked to the end.
	pub fn affected(self: *Rows) i64 {
		switch (self.*) {
			inline else => |*rows| return rows.affected(),
		}
	}
};

// --------------------------------------------------------------- connection

pub const Db = union(enum) {
	sqlite: *sqlite.Db,
	postgres: *postgres.Db,
	mysql: *mysql.Db,
	redis: *redis.Db,
	kafka: *kafka.Db,
	s3: *s3.Db,
	azure: *azure.Db,
	rabbit: *rabbit.Db,
	sftp: *sftp.Db,
	k8s: *k8s.Db,

	/// Open whatever the target describes: a file path, or a URL like
	/// postgres://user:password@host:port/database.
	pub fn open(allocator: std.mem.Allocator, target: []const u8, report: *std.ArrayListUnmanaged(u8)) !Db {
		if (kafka.owns(target)) {
			return .{ .kafka = try kafka.Db.open(allocator, target, report) };
		}
		if (s3.owns(target)) {
			return .{ .s3 = try s3.Db.open(allocator, target, report) };
		}
		if (azure.owns(target)) {
			return .{ .azure = try azure.Db.open(allocator, target, report) };
		}
		if (rabbit.owns(target)) {
			return .{ .rabbit = try rabbit.Db.open(allocator, target, report) };
		}
		if (sftp.owns(target)) {
			return .{ .sftp = try sftp.Db.open(allocator, target, report) };
		}
		if (k8s.owns(target)) {
			return .{ .k8s = try k8s.Db.open(allocator, target, report) };
		}
		if (redis.owns(target)) {
			return .{ .redis = try redis.Db.open(allocator, target, report) };
		}
		if (mysql.owns(target)) {
			return .{ .mysql = try mysql.Db.open(allocator, target, report) };
		}
		if (isPostgresUrl(target)) {
			return .{ .postgres = try postgres.Db.open(allocator, target, report) };
		}
		return .{ .sqlite = try sqlite.Db.open(allocator, target, report) };
	}

	pub fn close(self: Db) void {
		switch (self) {
			inline else => |driver| driver.close(),
		}
	}

	/// Watch every statement from now on, or stop watching with null.
	pub fn watch(self: Db, progress: ?Progress) void {
		switch (self) {
			inline else => |driver| driver.watch(progress),
		}
	}

	pub fn caps(self: Db) Caps {
		switch (self) {
			inline else => |driver| return driver.caps(),
		}
	}

	/// This connection seen as somewhere files live, where it is one at all. A
	/// database is not: a table is not a directory and pretending otherwise
	/// would put a file manager in front of things that hold rows.
	pub fn files(self: Db) ?store.Store {
		return switch (self) {
			.sftp => |driver| driver.files(),
			.s3 => |driver| driver.files(),
			.azure => |driver| driver.files(),
			else => null,
		};
	}

	/// How many requests this connection has made, where the driver counts them at
	/// all. Null where it does not: an engine reached through a library does its own
	/// talking and there is nothing here to count.
	pub fn requests(self: Db) ?usize {
		switch (self) {
			inline else => |driver| {
				if (@hasField(@TypeOf(driver.*), "requests")) {
					return driver.requests;
				}
				return null;
			},
		}
	}

	/// The engine's version, for the header.
	pub fn version(self: Db) []const u8 {
		switch (self) {
			inline else => |driver| return driver.version(),
		}
	}

	/// What the connection calls itself: a file path or host/database.
	pub fn describe(self: Db) []const u8 {
		switch (self) {
			inline else => |driver| return driver.describe(),
		}
	}

	pub fn message(self: Db) []const u8 {
		switch (self) {
			inline else => |driver| return driver.message(),
		}
	}

	/// Run a statement, ignoring any rows.
	pub fn exec(self: Db, sql: []const u8) Error!void {
		switch (self) {
			inline else => |driver| return driver.exec(sql),
		}
	}

	/// Start one statement. `rest` receives what was left of the batch.
	pub fn query(self: Db, sql: []const u8, rest: ?*[]const u8) Error!?Rows {
		switch (self) {
			inline else => |driver| return driver.query(sql, rest),
		}
	}

	// --- rows, asked for rather than written ---
	//
	// A driver that declares `select`, `apply` or `wording` answers the request
	// itself; the rest are SQL engines and the request is rendered for them here,
	// once, rather than in three drivers or in the interface.

	/// Ask for rows.
	pub fn select(self: Db, request: ask.Select) Error!?Rows {
		switch (self) {
			inline else => |driver| {
				if (@hasDecl(@TypeOf(driver.*), "select")) {
					return driver.select(request);
				}
				const sql = try self.wording(driver.allocator, .{ .select = request });
				defer driver.allocator.free(sql);
				return driver.query(sql, null);
			},
		}
	}

	/// How many rows match. Null when the engine cannot say, which is not the
	/// same as none.
	pub fn count(self: Db, request: ask.Select) ?i64 {
		var counting = request;
		counting.count = true;
		var rows = (self.select(counting) catch return null) orelse return null;
		defer rows.close();
		if (!(rows.next() catch return null)) {
			return null;
		}
		return switch (rows.value(0)) {
			.int => |value| value,
			.float => |value| @intFromFloat(value),
			.text => |text| std.fmt.parseInt(i64, text, 10) catch null,
			else => null,
		};
	}

	/// Insert, update or delete one row.
	pub fn apply(self: Db, change: ask.Change) Error!void {
		switch (self) {
			inline else => |driver| {
				if (@hasDecl(@TypeOf(driver.*), "apply")) {
					return driver.apply(change);
				}
				const sql = try self.wording(driver.allocator, .{ .change = change });
				defer driver.allocator.free(sql);
				return driver.exec(sql);
			},
		}
	}

	/// The request in the engine's own words, for the history, the report and the
	/// clipboard: SQL where there is SQL, and `SCAN user:*` or `FETCH orders 0`
	/// where there is not. Owned by the caller.
	pub fn wording(self: Db, allocator: std.mem.Allocator, request: Request) Error![]u8 {
		switch (self) {
			inline else => |driver| {
				if (@hasDecl(@TypeOf(driver.*), "wording")) {
					return driver.wording(allocator, request);
				}
				var out: List = .empty;
				errdefer out.deinit(allocator);
				switch (request) {
					.select => |value| try ask.renderSelect(&out, allocator, value, driver.caps()),
					.change => |value| try ask.renderChange(&out, allocator, value, driver.caps()),
				}
				return out.toOwnedSlice(allocator);
			},
		}
	}

	pub fn inTransaction(self: Db) bool {
		switch (self) {
			inline else => |driver| return driver.inTransaction(),
		}
	}

	// --- schema ---

	pub fn objects(self: Db, arena: std.mem.Allocator, schema: []const u8) Error![]Object {
		switch (self) {
			inline else => |driver| return driver.objects(arena, schema),
		}
	}

	pub fn schemas(self: Db, arena: std.mem.Allocator) Error![][]const u8 {
		switch (self) {
			inline else => |driver| return driver.schemas(arena),
		}
	}

	pub fn columns(self: Db, arena: std.mem.Allocator, table: Table) Error![]Column {
		switch (self) {
			inline else => |driver| return driver.columns(arena, table),
		}
	}

	pub fn indexes(self: Db, arena: std.mem.Allocator, table: Table) Error![]Index {
		switch (self) {
			inline else => |driver| return driver.indexes(arena, table),
		}
	}

	pub fn foreignKeys(self: Db, arena: std.mem.Allocator, table: Table) Error![]ForeignKey {
		switch (self) {
			inline else => |driver| return driver.foreignKeys(arena, table),
		}
	}

	/// The CREATE statement, or something close enough to show.
	pub fn definition(self: Db, arena: std.mem.Allocator, table: Table) Error!?[]const u8 {
		switch (self) {
			inline else => |driver| return driver.definition(arena, table),
		}
	}

	pub fn rowCount(self: Db, table: Table) ?i64 {
		switch (self) {
			inline else => |driver| return driver.rowCount(table),
		}
	}

	/// Columns that address one row, and whether they have to be selected
	/// separately because they are not part of `*`.
	pub fn rowKey(self: Db, arena: std.mem.Allocator, table: Table) Error!RowKey {
		switch (self) {
			inline else => |driver| return driver.rowKey(arena, table),
		}
	}

	/// What an alter has to preserve on this engine. SQLite has to write the
	/// table again and put its indexes and triggers back; PostgreSQL alters in
	/// place and needs nothing.
	pub fn alterContext(self: Db, arena: std.mem.Allocator, table: Table, cols: []const Column) Error!AlterContext {
		switch (self) {
			inline else => |driver| return driver.alterContext(arena, table, cols),
		}
	}

	/// Engine facts for the info view.
	pub fn settings(self: Db, arena: std.mem.Allocator) Error![]Setting {
		switch (self) {
			inline else => |driver| return driver.settings(arena),
		}
	}

	/// Split a batch the way this engine parses it.
	pub fn split(self: Db, arena: std.mem.Allocator, sql: []const u8) Error![]Statement {
		switch (self) {
			inline else => |driver| return driver.split(arena, sql),
		}
	}

	// --- schema changes, as SQL the caller then runs ---

	pub fn ddl(self: Db) Ddl {
		switch (self) {
			inline else => |driver| return driver.ddl(),
		}
	}
};

/// One request, for the sake of putting it into words.
pub const Request = union(enum) {
	select: ask.Select,
	change: ask.Change,
};

/// A table, with the schema it lives in on the engines that have them.
pub const Table = struct {
	schema: []const u8 = "",
	name: []const u8,

	pub fn eql(self: Table, other: Table) bool {
		return std.mem.eql(u8, self.name, other.name) and std.mem.eql(u8, self.schema, other.schema);
	}
};

pub const RowKey = struct {
	columns: []const []const u8 = &.{},
	/// The key is not part of `SELECT *` and has to be asked for; `expression`
	/// is what to select for it (SQLite's `rowid`).
	hidden: bool = false,
	expression: []const u8 = "",

	pub fn usable(self: RowKey) bool {
		return self.columns.len != 0;
	}
};

/// SQL generation for schema changes; each driver brings its own.
pub const Ddl = union(enum) {
	sqlite: sqlite.Ddl,
	postgres: postgres.Ddl,
	mysql: mysql.Ddl,
	redis: redis.Ddl,
	kafka: kafka.Ddl,
	s3: s3.Ddl,
	azure: azure.Ddl,
	rabbit: rabbit.Ddl,
	sftp: sftp.Ddl,
	k8s: k8s.Ddl,

	pub fn createTable(self: Ddl, out: *List, a: std.mem.Allocator, table: Table, cols: []const Column, keys: []const ForeignKey) !void {
		switch (self) {
			inline else => |driver| return driver.createTable(out, a, table, cols, keys),
		}
	}

	/// Apply a new column list to an existing table, renames included.
	pub fn alterTable(self: Ddl, out: *List, a: std.mem.Allocator, table: Table, new_name: []const u8, cols: []const Column, context: AlterContext) !void {
		switch (self) {
			inline else => |driver| return driver.alterTable(out, a, table, new_name, cols, context),
		}
	}

	pub fn addForeignKey(self: Ddl, out: *List, a: std.mem.Allocator, table: Table, key: ForeignKey, context: AlterContext) !void {
		switch (self) {
			inline else => |driver| return driver.addForeignKey(out, a, table, key, context),
		}
	}

	pub fn createIndex(self: Ddl, out: *List, a: std.mem.Allocator, table: Table, name: []const u8, cols: []const []const u8, unique: bool, where: []const u8) !void {
		switch (self) {
			inline else => |driver| return driver.createIndex(out, a, table, name, cols, unique, where),
		}
	}

	pub fn createView(self: Ddl, out: *List, a: std.mem.Allocator, table: Table, select: []const u8) !void {
		switch (self) {
			inline else => |driver| return driver.createView(out, a, table, select),
		}
	}

	pub fn createTrigger(self: Ddl, out: *List, a: std.mem.Allocator, table: Table, name: []const u8, when: []const u8, event: []const u8, condition: []const u8, body: []const u8) !void {
		switch (self) {
			inline else => |driver| return driver.createTrigger(out, a, table, name, when, event, condition, body),
		}
	}

	pub fn renameTable(self: Ddl, out: *List, a: std.mem.Allocator, table: Table, to: []const u8) !void {
		switch (self) {
			inline else => |driver| return driver.renameTable(out, a, table, to),
		}
	}

	pub fn copyTable(self: Ddl, out: *List, a: std.mem.Allocator, table: Table, to: []const u8, with_rows: bool) !void {
		switch (self) {
			inline else => |driver| return driver.copyTable(out, a, table, to, with_rows),
		}
	}

	pub fn dropObject(self: Ddl, out: *List, a: std.mem.Allocator, kind: Kind, table: Table) !void {
		switch (self) {
			inline else => |driver| return driver.dropObject(out, a, kind, table),
		}
	}

	pub fn truncate(self: Ddl, out: *List, a: std.mem.Allocator, table: Table) !void {
		switch (self) {
			inline else => |driver| return driver.truncate(out, a, table),
		}
	}

	/// INSERT with values the caller has already quoted.
	pub fn insertRow(self: Ddl, out: *List, a: std.mem.Allocator, table: Table, cols: []const []const u8, values: []const []const u8) !void {
		_ = self;
		try out.appendSlice(a, "INSERT INTO ");
		try quoteTable(out, a, table);
		if (cols.len == 0) {
			try out.appendSlice(a, " DEFAULT VALUES;\n");
			return;
		}
		try out.appendSlice(a, " (");
		for (cols, 0..) |column, i| {
			if (i != 0) {
				try out.appendSlice(a, ", ");
			}
			try quoteName(out, a, column);
		}
		try out.appendSlice(a, ") VALUES (");
		for (values, 0..) |value, i| {
			if (i != 0) {
				try out.appendSlice(a, ", ");
			}
			try out.appendSlice(a, value);
		}
		try out.appendSlice(a, ");\n");
	}

	/// Types offered in the column form.
	pub fn types(self: Ddl) []const []const u8 {
		switch (self) {
			inline else => |driver| return driver.types(),
		}
	}
};

/// What an alter needs to know beyond the new columns: SQLite rebuilds the
/// table and has to put these back, PostgreSQL ignores them.
pub const AlterContext = struct {
	/// The new column list; a rebuild needs it to write the table again.
	columns: []const Column = &.{},
	keys: []const ForeignKey = &.{},
	replay: []const []const u8 = &.{},
};

pub const List = std.ArrayListUnmanaged(u8);

// ---------------------------------------------------------------- quoting

/// Both engines quote identifiers with double quotes and strings with single
/// ones, doubling the quote inside. A driver that differs overrides these.
pub fn quoteName(out: *List, a: std.mem.Allocator, name: []const u8) !void {
	try out.append(a, '"');
	for (name) |char| {
		if (char == '"') {
			try out.append(a, '"');
		}
		try out.append(a, char);
	}
	try out.append(a, '"');
}

pub fn quote(out: *List, a: std.mem.Allocator, text: []const u8) !void {
	try out.append(a, '\'');
	for (text) |char| {
		if (char == '\'') {
			try out.append(a, '\'');
		}
		try out.append(a, char);
	}
	try out.append(a, '\'');
}

/// `schema.name`, or just the name where there are no schemas.
pub fn quoteTable(out: *List, a: std.mem.Allocator, table: Table) !void {
	if (table.schema.len != 0) {
		try quoteName(out, a, table.schema);
		try out.append(a, '.');
	}
	try quoteName(out, a, table.name);
}

/// How this engine's parser sees a batch.
pub const SplitOptions = struct {
	/// $tag$ ... $tag$ bodies, as PostgreSQL uses for functions.
	dollar_quotes: bool = false,
	/// Block comments nest.
	nested_comments: bool = false,
	/// [identifier]
	brackets: bool = false,
	/// `identifier`
	backticks: bool = false,
};

/// Split a batch on the semicolons that are not inside a string, an identifier,
/// a comment or a quoted body.
///
/// The statements are split as text rather than through an engine's parser
/// because a batch may create something and then use it, and such a statement
/// cannot be parsed before the one before it has run.
pub fn splitStatements(arena: std.mem.Allocator, sql: []const u8, options: SplitOptions) Error![]Statement {
	var list: std.ArrayListUnmanaged(Statement) = .empty;
	var start: usize = 0;
	var i: usize = 0;
	while (i < sql.len) {
		const char = sql[i];
		switch (char) {
			'\'', '"' => i = closing(sql, i, char),
			'`' => i = if (options.backticks) closing(sql, i, '`') else i + 1,
			'[' => i = if (options.brackets) (std.mem.indexOfScalarPos(u8, sql, i, ']') orelse sql.len -| 1) + 1 else i + 1,
			'-' => {
				if (i + 1 < sql.len and sql[i + 1] == '-') {
					i = std.mem.indexOfScalarPos(u8, sql, i, '\n') orelse sql.len;
				} else {
					i += 1;
				}
			},
			'/' => {
				if (i + 1 < sql.len and sql[i + 1] == '*') {
					var depth: usize = 1;
					i += 2;
					while (i + 1 < sql.len and depth != 0) {
						if (options.nested_comments and sql[i] == '/' and sql[i + 1] == '*') {
							depth += 1;
							i += 2;
						} else if (sql[i] == '*' and sql[i + 1] == '/') {
							depth -= 1;
							i += 2;
						} else {
							i += 1;
						}
					}
				} else {
					i += 1;
				}
			},
			'$' => {
				if (!options.dollar_quotes) {
					i += 1;
					continue;
				}
				var at = i + 1;
				while (at < sql.len and (std.ascii.isAlphanumeric(sql[at]) or sql[at] == '_')) : (at += 1) {}
				if (at < sql.len and sql[at] == '$') {
					const tag = sql[i .. at + 1];
					const close = std.mem.indexOfPos(u8, sql, at + 1, tag);
					i = if (close) |found| found + tag.len else sql.len;
				} else {
					i += 1;
				}
			},
			';' => {
				const text = std.mem.trim(u8, sql[start..i], " \t\r\n;");
				if (text.len != 0) {
					try list.append(arena, .{ .sql = text });
				}
				i += 1;
				start = i;
			},
			else => i += 1,
		}
	}
	const tail = std.mem.trim(u8, sql[start..], " \t\r\n;");
	if (tail.len != 0) {
		try list.append(arena, .{ .sql = tail });
	}
	return list.items;
}

/// Past a quoted run, doubled quotes included.
fn closing(sql: []const u8, at: usize, quote_char: u8) usize {
	var i = at + 1;
	while (i < sql.len) : (i += 1) {
		if (sql[i] != quote_char) {
			continue;
		}
		if (i + 1 < sql.len and sql[i + 1] == quote_char) {
			i += 1;
			continue;
		}
		return i + 1;
	}
	return sql.len;
}

fn isPostgresUrl(target: []const u8) bool {
	for ([_][]const u8{ "postgres://", "postgresql://" }) |prefix| {
		if (std.ascii.startsWithIgnoreCase(target, prefix)) {
			return true;
		}
	}
	// A bare keyword string, the way psql accepts it.
	return std.mem.indexOf(u8, target, "host=") != null or std.mem.indexOf(u8, target, "dbname=") != null;
}

test "a postgres target is told apart from a file" {
	try std.testing.expect(isPostgresUrl("postgres://localhost/demo"));
	try std.testing.expect(isPostgresUrl("postgresql://u:p@h:5433/demo"));
	try std.testing.expect(isPostgresUrl("host=127.0.0.1 dbname=demo"));
	try std.testing.expect(!isPostgresUrl("demo.db"));
	try std.testing.expect(!isPostgresUrl("/var/lib/postgres_backup.sqlite"));
}

test "quoting doubles the quote character" {
	const a = std.testing.allocator;
	var out: List = .empty;
	defer out.deinit(a);
	try quoteName(&out, a, "we\"ird");
	try quote(&out, a, "it's");
	try quoteTable(&out, a, .{ .schema = "shop", .name = "orders" });
	try std.testing.expectEqualStrings("\"we\"\"ird\"'it''s'\"shop\".\"orders\"", out.items);
}

test "the splitter leaves semicolons inside strings, bodies and comments alone" {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();
	const a = arena.allocator();
	const pg: SplitOptions = .{ .dollar_quotes = true, .nested_comments = true };

	const strings = try splitStatements(a, "SELECT 'a;b'; SELECT 2", pg);
	try std.testing.expectEqual(@as(usize, 2), strings.len);
	try std.testing.expectEqualStrings("SELECT 'a;b'", strings[0].sql);
	try std.testing.expectEqualStrings("SELECT 2", strings[1].sql);

	const dollar = try splitStatements(a,
		"CREATE FUNCTION f() RETURNS int AS $$ BEGIN; RETURN 1; END $$ LANGUAGE plpgsql; SELECT f()", pg);
	try std.testing.expectEqual(@as(usize, 2), dollar.len);
	try std.testing.expect(std.mem.indexOf(u8, dollar[0].sql, "RETURN 1") != null);

	const comments = try splitStatements(a, "SELECT 1; -- ; not one\nSELECT 2; /* a ; /* nested */ */ SELECT 3", pg);
	try std.testing.expectEqual(@as(usize, 3), comments.len);

	const quoted = try splitStatements(a, "SELECT \"we;ird\" FROM t", pg);
	try std.testing.expectEqual(@as(usize, 1), quoted.len);

	try std.testing.expectEqual(@as(usize, 0), (try splitStatements(a, "  ;; \n", pg)).len);

	// a dollar sign is just a character for SQLite
	const sqlite_options: SplitOptions = .{ .brackets = true, .backticks = true };
	const brackets = try splitStatements(a, "SELECT [we;ird], `also;this` FROM t; SELECT 2", sqlite_options);
	try std.testing.expectEqual(@as(usize, 2), brackets.len);
}

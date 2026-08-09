//! SQLite bindings shared by the WASM module and the native terminal app.
//!
//! The raw C declarations are at the bottom; on top of them sit `Conn` and
//! `Cursor`, which is what the terminal app uses. The WASM module writes JSON
//! straight from the C API, so it only needs the declarations.

const std = @import("std");

pub const Db = opaque {};
pub const Stmt = opaque {};

pub const OK = 0;
pub const ROW = 100;
pub const DONE = 101;

pub const OPEN_READONLY = 0x00000001;
pub const OPEN_READWRITE = 0x00000002;
pub const OPEN_CREATE = 0x00000004;


pub const INTEGER = 1;
pub const FLOAT = 2;
pub const TEXT = 3;
pub const BLOB = 4;
pub const NULL = 5;

/// One cell of a result row. Text and blob point into SQLite's own memory and
/// are only valid until the next step() on the same cursor.
pub const Value = union(enum) {
	null: void,
	int: i64,
	float: f64,
	text: []const u8,
	blob: []const u8,
};

pub const Error = error{Sqlite};

/// A database connection. There is exactly one per process in both frontends.
pub const Conn = struct {
	handle: ?*Db = null,

	/// Open a file, creating it when `create` is set.
	pub fn openFile(path: [:0]const u8, create: bool) Error!Conn {
		var conn = Conn{};
		const flags: c_int = OPEN_READWRITE | @as(c_int, if (create) OPEN_CREATE else 0);
		if (sqlite3_open_v2(path.ptr, &conn.handle, flags, null) != OK) {
			return error.Sqlite;
		}
		_ = sqlite3_busy_timeout(conn.handle, 2000);
		_ = sqlite3_exec(conn.handle, "PRAGMA foreign_keys=1", null, null, null);
		return conn;
	}

	pub fn close(self: *Conn) void {
		_ = sqlite3_close_v2(self.handle);
		self.handle = null;
	}

	pub fn message(self: Conn) []const u8 {
		return std.mem.span(sqlite3_errmsg(self.handle));
	}

	pub fn filename(self: Conn) []const u8 {
		const name = sqlite3_db_filename(self.handle, "main") orelse return "";
		return std.mem.span(name);
	}

	/// Run statements that return nothing.
	pub fn exec(self: Conn, sql: [:0]const u8) Error!void {
		if (sqlite3_exec(self.handle, sql.ptr, null, null, null) != OK) {
			return error.Sqlite;
		}
	}

	/// Prepare the first statement of `sql`. `rest` receives what is left, so a
	/// batch is walked by feeding it back in - the split is SQLite's own.
	pub fn prepare(self: Conn, sql: []const u8, rest: ?*[]const u8) Error!?Cursor {
		var stmt: ?*Stmt = null;
		var tail: ?[*]const u8 = null;
		if (sqlite3_prepare_v2(self.handle, sql.ptr, @intCast(sql.len), &stmt, &tail) != OK) {
			return error.Sqlite;
		}
		if (rest) |out| {
			const used = if (tail) |t| @intFromPtr(t) - @intFromPtr(sql.ptr) else sql.len;
			out.* = sql[used..];
		}
		if (stmt == null) {
			return null; // only a comment or whitespace
		}
		return Cursor{ .stmt = stmt, .conn = self };
	}

	pub fn changes(self: Conn) i64 {
		return @intCast(sqlite3_total_changes(self.handle));
	}

	pub fn inTransaction(self: Conn) bool {
		return sqlite3_get_autocommit(self.handle) == 0;
	}

	/// Single text value of the first row, or null. The result is copied.
	pub fn oneText(self: Conn, allocator: std.mem.Allocator, sql: []const u8) !?[]u8 {
		var cursor = (try self.prepare(sql, null)) orelse return null;
		defer cursor.finish();
		if (!try cursor.step()) {
			return null;
		}
		return switch (cursor.value(0)) {
			.null => null,
			.text, .blob => |bytes| try allocator.dupe(u8, bytes),
			.int => |v| try std.fmt.allocPrint(allocator, "{d}", .{v}),
			.float => |v| try std.fmt.allocPrint(allocator, "{d}", .{v}),
		};
	}

	/// Single integer value of the first row.
	pub fn oneInt(self: Conn, sql: []const u8) Error!?i64 {
		var cursor = (try self.prepare(sql, null)) orelse return null;
		defer cursor.finish();
		if (!try cursor.step()) {
			return null;
		}
		return switch (cursor.value(0)) {
			.int => |v| v,
			.float => |v| @intFromFloat(v),
			else => null,
		};
	}
};

pub const Cursor = struct {
	stmt: ?*Stmt,
	conn: Conn,

	pub fn finish(self: *Cursor) void {
		_ = sqlite3_finalize(self.stmt);
		self.stmt = null;
	}

	/// True when a row is available, false at the end.
	pub fn step(self: Cursor) Error!bool {
		return switch (sqlite3_step(self.stmt)) {
			ROW => true,
			DONE => false,
			else => error.Sqlite,
		};
	}

	pub fn columns(self: Cursor) usize {
		return @intCast(sqlite3_column_count(self.stmt));
	}

	pub fn name(self: Cursor, i: usize) []const u8 {
		const text = sqlite3_column_name(self.stmt, @intCast(i)) orelse return "";
		return std.mem.span(text);
	}

	pub fn declared(self: Cursor, i: usize) []const u8 {
		const text = sqlite3_column_decltype(self.stmt, @intCast(i)) orelse return "";
		return std.mem.span(text);
	}

	pub fn sourceTable(self: Cursor, i: usize) []const u8 {
		const text = sqlite3_column_table_name(self.stmt, @intCast(i)) orelse return "";
		return std.mem.span(text);
	}

	pub fn sourceColumn(self: Cursor, i: usize) []const u8 {
		const text = sqlite3_column_origin_name(self.stmt, @intCast(i)) orelse return "";
		return std.mem.span(text);
	}

	pub fn value(self: Cursor, i: usize) Value {
		const index: c_int = @intCast(i);
		const len: usize = @intCast(sqlite3_column_bytes(self.stmt, index));
		return switch (sqlite3_column_type(self.stmt, index)) {
			INTEGER => .{ .int = sqlite3_column_int64(self.stmt, index) },
			FLOAT => .{ .float = sqlite3_column_double(self.stmt, index) },
			BLOB => .{ .blob = if (sqlite3_column_blob(self.stmt, index)) |p| p[0..len] else "" },
			NULL => .null,
			else => .{ .text = if (sqlite3_column_text(self.stmt, index)) |p| p[0..len] else "" },
		};
	}
};

pub fn version() []const u8 {
	return std.mem.span(sqlite3_libversion());
}

/// Quote an SQL string literal into `out`.
pub fn quote(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, text: []const u8) !void {
	try out.append(allocator, '\'');
	for (text) |char| {
		if (char == '\'') {
			try out.append(allocator, '\'');
		}
		try out.append(allocator, char);
	}
	try out.append(allocator, '\'');
}

/// Quote an SQL identifier into `out`.
pub fn quoteName(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, name: []const u8) !void {
	try out.append(allocator, '"');
	for (name) |char| {
		if (char == '"') {
			try out.append(allocator, '"');
		}
		try out.append(allocator, char);
	}
	try out.append(allocator, '"');
}

// --- the C API ---

pub extern fn sqlite3_open_v2(filename: [*:0]const u8, ppDb: *?*Db, flags: c_int, zVfs: ?[*:0]const u8) c_int;
pub extern fn sqlite3_close_v2(db: ?*Db) c_int;
pub extern fn sqlite3_errmsg(db: ?*Db) [*:0]const u8;
pub extern fn sqlite3_db_filename(db: ?*Db, name: [*:0]const u8) ?[*:0]const u8;
pub extern fn sqlite3_busy_timeout(db: ?*Db, ms: c_int) c_int;
pub extern fn sqlite3_exec(db: ?*Db, sql: [*:0]const u8, cb: ?*anyopaque, arg: ?*anyopaque, err: ?*?[*:0]u8) c_int;
pub extern fn sqlite3_prepare_v2(db: ?*Db, sql: [*]const u8, nByte: c_int, ppStmt: *?*Stmt, pzTail: *?[*]const u8) c_int;
pub extern fn sqlite3_step(stmt: ?*Stmt) c_int;
pub extern fn sqlite3_finalize(stmt: ?*Stmt) c_int;
pub extern fn sqlite3_column_count(stmt: ?*Stmt) c_int;
pub extern fn sqlite3_column_name(stmt: ?*Stmt, i: c_int) ?[*:0]const u8;
pub extern fn sqlite3_column_decltype(stmt: ?*Stmt, i: c_int) ?[*:0]const u8;
pub extern fn sqlite3_column_table_name(stmt: ?*Stmt, i: c_int) ?[*:0]const u8;
pub extern fn sqlite3_column_origin_name(stmt: ?*Stmt, i: c_int) ?[*:0]const u8;
pub extern fn sqlite3_column_type(stmt: ?*Stmt, i: c_int) c_int;
pub extern fn sqlite3_column_int64(stmt: ?*Stmt, i: c_int) i64;
pub extern fn sqlite3_column_double(stmt: ?*Stmt, i: c_int) f64;
pub extern fn sqlite3_column_text(stmt: ?*Stmt, i: c_int) ?[*]const u8;
pub extern fn sqlite3_column_blob(stmt: ?*Stmt, i: c_int) ?[*]const u8;
pub extern fn sqlite3_column_bytes(stmt: ?*Stmt, i: c_int) c_int;
pub extern fn sqlite3_total_changes(db: ?*Db) c_int;
pub extern fn sqlite3_last_insert_rowid(db: ?*Db) i64;
pub extern fn sqlite3_get_autocommit(db: ?*Db) c_int;
pub extern fn sqlite3_free(p: ?*anyopaque) void;
pub extern fn sqlite3_progress_handler(db: ?*Db, n: c_int, cb: ?*const fn (?*anyopaque) callconv(.c) c_int, ctx: ?*anyopaque) void;
pub extern fn sqlite3_libversion() [*:0]const u8;

//! State and behaviour of the terminal app: the schema, the loaded page of
//! rows, and everything that runs SQL. Drawing and input live next door and
//! only read from here, which keeps the imports a straight line.

const std = @import("std");
const database = @import("db");
const term = @import("term.zig");
const Form = @import("form.zig");
const csv = @import("csv.zig");
const Editor = @import("editor.zig").Editor;
const sql_syntax = @import("editor.zig");
const fuzzy = @import("fuzzy.zig");
const conns = @import("connections.zig");
const keychain = @import("keychain.zig");
const Files = @import("files.zig");

pub const Term = term.Term;

/// 256-colour palette, close to the web UI's tokens.
pub const C = struct {
	pub const accent = 111;
	pub const text = 252;
	pub const dim = 245;
	pub const faint = 240;
	pub const number = 74;
	pub const blob = 176;
	pub const nul = 242;
	pub const danger = 203;
	pub const ok = 114;
	pub const warn = 179;
	pub const bar = 236;
	pub const selected = 238;
};

pub const SIDEBAR: usize = 26;

pub const OPERATORS = [_][]const u8{ "=", "!=", "<", "<=", ">", ">=", "LIKE", "contains", "IS NULL", "IS NOT NULL" };

/// What the filter form's operator means. `contains` is LIKE with the wildcards
/// added for the user, which is done where the value is.
pub fn operatorOf(text: []const u8) database.ask.Op {
	const table = [_]struct { name: []const u8, op: database.ask.Op }{
		.{ .name = "=", .op = .eq },
		.{ .name = "!=", .op = .ne },
		.{ .name = "<", .op = .lt },
		.{ .name = "<=", .op = .le },
		.{ .name = ">", .op = .gt },
		.{ .name = ">=", .op = .ge },
		.{ .name = "LIKE", .op = .like },
		.{ .name = "contains", .op = .like },
		.{ .name = "IS NULL", .op = .is_null },
		.{ .name = "IS NOT NULL", .op = .not_null },
	};
	for (table) |entry| {
		if (std.mem.eql(u8, entry.name, text)) {
			return entry.op;
		}
	}
	return .eq;
}

pub const Kind = enum { nul, int, float, text, blob };

pub const Cell = struct {
	text: []const u8, // flattened to a single line
	kind: Kind,

	pub fn colour(self: Cell) u8 {
		return switch (self.kind) {
			.nul => C.nul,
			.int, .float => C.number,
			.blob => C.blob,
			.text => C.text,
		};
	}
};

/// A key column, and which cell of the row holds it.
pub const Position = struct { name: []const u8, at: usize };

pub const Row = struct {
	cells: []Cell,
	/// What addresses this row, when it can be addressed at all. Conditions
	/// rather than a WHERE clause, so an engine that has no SQL can read the
	/// values out of it instead of parsing them back out of a string.
	key: ?[]const database.ask.Filter,
};

pub const Object = struct {
	name: []const u8,
	kind: []const u8,
	rows: ?i64,
};

pub const View = enum { grid, structure, messages, help, info, relations, connections, files };
pub const Focus = enum { sidebar, main };
/// A place on screen, in cells.
pub const Spot = struct { row: usize, col: usize };

/// Where a connection can keep its password, in the order the form offers them.
const PLACES = [_][]const u8{ "ask", "file", "keychain" };
/// What the Kafka form offers. The empty one is no SASL at all, which is what a
/// broker on a private network wants.
const MECHANISMS = [_][]const u8{ "", "PLAIN", "SCRAM-SHA-256", "SCRAM-SHA-512" };

/// The command palette: what is typed, and which match is under the cursor.
/// Its entries live in `input.zig`, next to the keys they stand for.
pub const Palette = struct {
	query: std.ArrayListUnmanaged(u8) = .empty,
	at: usize = 0,
};

pub const PromptKind = enum { command, filter, edit, confirm, password, new_dir, rename_file, remove_files, go_to, remove_rows };

pub const Prompt = struct {
	kind: PromptKind,
	label: []const u8,
	buffer: std.ArrayListUnmanaged(u8) = .empty,
	history_at: ?usize = null,
};

pub const Report = struct {
	sql: []const u8,
	ms: f64,
	changes: i64,
	rows: i64,
	/// A statement with result columns is not stepped here - it is run again to
	/// fill the grid - so its row count and timing would be meaningless.
	result_set: bool,
	failure: ?[]const u8,
};

pub const App = struct {
	allocator: std.mem.Allocator,
	arena: std.heap.ArenaAllocator, // the loaded page of rows
	reports_arena: std.heap.ArenaAllocator,
	/// What the connection form is holding: it is built again whenever the engine
	/// changes, so what was typed has to outlive the form it was typed into.
	form_arena: std.heap.ArenaAllocator,
	screen: *Term,
	conn: database.Db,
	/// False while the connection list is on screen and nothing is open.
	connected: bool = false,
	path: []const u8,
	owned_path: []u8,

	objects: std.ArrayListUnmanaged(Object) = .empty,
	filter: std.ArrayListUnmanaged(u8) = .empty,
	selected: usize = 0,
	scroll: usize = 0, // first visible object

	view: View = .grid,
	focus: Focus = .sidebar,
	detail: bool = false,

	/// null while a query result is shown. Owned by the app.
	table_name: ?[]const u8 = null,
	schema: std.ArrayListUnmanaged(u8) = .empty,
	title: std.ArrayListUnmanaged(u8) = .empty,
	cols: std.ArrayListUnmanaged([]const u8) = .empty,
	widths: std.ArrayListUnmanaged(usize) = .empty,
	rows: std.ArrayListUnmanaged(Row) = .empty,
	total: i64 = 0,
	/// Whether `total` is a number at all. An engine that cannot count without
	/// reading everything - a bucket of a million keys - says so, and `of ?` is
	/// the honest thing to draw; `of 0` was a lie.
	counted: bool = true,
	editable: bool = false,

	page: usize = 0,
	limit: usize = 200,
	order: ?[]const u8 = null,
	descending: bool = false,

	cursor_row: usize = 0,
	cursor_col: usize = 0,
	row_scroll: usize = 0,
	col_scroll: usize = 0,

	prompt: ?Prompt = null,
	form: ?Form.Form = null,
	/// A statement waiting for a yes at the confirmation prompt.
	pending: std.ArrayListUnmanaged(u8) = .empty,
	marked: std.ArrayListUnmanaged(usize) = .empty, // row indexes ticked with space
	hidden: std.ArrayListUnmanaged(usize) = .empty, // column indexes hidden from the grid
	/// What the filter form put together: conditions an engine of any kind can
	/// honour. The strings are owned.
	conditions: std.ArrayListUnmanaged(database.ask.Filter) = .empty,
	/// The raw box of the filter form, which only an engine with SQL can use.
	where_text: std.ArrayListUnmanaged(u8) = .empty,
	/// The last reload could not be answered, and has said why. Whoever asked for
	/// it must not then report a count as though it had worked.
	grid_failed: bool = false,
	text_limit: usize = 44, // widest column in the grid
	history: std.ArrayListUnmanaged([]const u8) = .empty,
	reports: std.ArrayListUnmanaged(Report) = .empty,

	status: std.ArrayListUnmanaged(u8) = .empty,
	status_error: bool = false,
	quit: bool = false,

	/// Saved connections and where they live.
	saved: conns.List,
	saved_path: std.ArrayListUnmanaged(u8) = .empty,
	saved_at: usize = 0, // cursor in the connection list
	/// The connection a password is being asked for.
	pending_target: std.ArrayListUnmanaged(u8) = .empty,
	/// Which saved connection the open form is editing, so changing both its name
	/// and its target replaces that entry instead of adding a second one.
	editing_saved: ?usize = null,
	/// Which engine the open connection form was built for: when the choice at the
	/// top of it changes, the fields under it are somebody else's.
	built_engine: conns.Engine = .sqlite,
	palette: ?Palette = null,
	/// The two panes, while the file manager is on screen. Null the rest of the
	/// time: a connection that holds rows has no business keeping one open.
	files: ?*Files.Manager = null,
	/// The SQL editor, when it is open. This is where statements are written;
	/// the one-line prompt only takes the short `:` commands now.
	editor: ?Editor = null,
	/// A key that is waiting for the one after it - `C` for the copy keys. The
	/// footer lists what the next key can be, so a prefix is not something to
	/// remember either.
	prefix: ?u21 = null,
	/// Where the text cursor should sit. Worked out while drawing, because only
	/// the drawing code knows where a field ended up, and read at the end of the
	/// frame to put the terminal's own cursor there.
	type_cursor: ?Spot = null,
	/// While a statement is running: when it started, when the spinner was last
	/// drawn, which frame it is on, and whether the user has asked to stop.
	run_started: f64 = 0,
	/// The same clock for a copy, which is a different kind of long wait.
	copy_started: f64 = 0,
	copy_ticked: f64 = 0,	run_ticked: f64 = 0,
	run_frame: usize = 0,
	cancelled: bool = false,
	/// Set once the App sits at its final address. `init` connects while the
	/// struct is still being built and returned by value, so the pointer handed
	/// to the driver then would dangle - the watch is armed from `main` instead,
	/// after init, and re-armed by every later connect.
	watch_armed: bool = false,
	env: *std.process.Environ.Map,

	// ----------------------------------------------------------- lifecycle

	/// Start with a connection, or with the list of saved ones when the target is
	/// empty. Nothing is opened before the screen exists, so a failure to connect
	/// lands on the list instead of quitting.
	pub fn init(allocator: std.mem.Allocator, target: []const u8, io: std.Io, env: *std.process.Environ.Map) !App {
		var self = App{
			.allocator = allocator,
			.arena = std.heap.ArenaAllocator.init(allocator),
			.reports_arena = std.heap.ArenaAllocator.init(allocator),
			.form_arena = std.heap.ArenaAllocator.init(allocator),
			.screen = try Term.init(allocator, io, env),
			.conn = undefined,
			.connected = false,
			.path = "",
			.owned_path = try allocator.alloc(u8, 0),
			.saved = conns.List.init(allocator),
			.env = env,
		};
		var buffer: [std.fs.max_path_bytes]u8 = undefined;
		if (conns.path(&buffer, env)) |file| {
			try self.saved_path.appendSlice(allocator, file);
			conns.load(&self.saved, file) catch {};
		}
		self.view = .connections;
		if (target.len != 0) {
			self.connect(target, true) catch {};
		} else if (self.saved.items.items.len == 0) {
			self.say("no saved connections yet - press a to add one", .{});
		} else {
			self.say("{d} saved connection(s) - enter connects, a adds, d removes", .{self.saved.items.items.len});
		}
		return self;
	}

	/// Open a target and take it as the current connection. `remember` puts it in
	/// the saved list, without its password.
	pub fn connect(self: *App, target: []const u8, keep: bool) !void {
		var report: std.ArrayListUnmanaged(u8) = .empty;
		defer report.deinit(self.allocator);
		const opened = database.Db.open(self.allocator, target, &report) catch {
			// A missing password is worth asking for rather than just failing.
			if (needsPassword(report.items)) {
				self.pending_target.clearRetainingCapacity();
				try self.pending_target.appendSlice(self.allocator, target);
				self.prompt = .{ .kind = .password, .label = " password: " };
				self.say("the server wants a password", .{});
				return;
			}
			self.complain("{s}", .{if (report.items.len != 0) report.items else "cannot open it"});
			self.view = .connections;
			return;
		};
		if (self.connected) {
			self.conn.close();
		}
		self.conn = opened;
		self.connected = true;
		if (self.watch_armed) {
			self.watchStatements();
		}

		self.allocator.free(self.owned_path);
		// Without the password: this is what gets shown, and what the open form
		// starts from.
		var scratch = std.heap.ArenaAllocator.init(self.allocator);
		defer scratch.deinit();
		self.owned_path = try self.allocator.dupe(u8, try conns.withoutPassword(scratch.allocator(), target));
		self.path = self.owned_path;
		try self.setTable(null);
		self.schema.clearRetainingCapacity();
		try self.firstSchema();
		self.clearConditions();
		self.where_text.clearRetainingCapacity();
		self.hidden.clearRetainingCapacity();
		self.marked.clearRetainingCapacity();
		self.selected = 0;
		self.page = 0;
		self.view = .grid;
		try self.loadObjects();
		if (self.current()) |object| {
			try self.openTable(object.name);
		}
		if (keep) {
			try self.rememberConnection(target);
		}
		self.say("{s} - {s}", .{ self.conn.describe(), self.conn.version() });
		// A place that holds files opens on the files. The grid can show a
		// directory as a table and that is worth having, but it is not what
		// anybody connecting to a NAS came for, and nothing on that screen said
		// the two panes were a key away.
		if (self.conn.files() != null) {
			self.openFiles() catch {};
		}
	}

	// --- the SQL editor ---

	pub fn openEditor(self: *App) !void {
		if (self.editor != null) {
			return;
		}
		self.editor = Editor.init(self.allocator);
		self.say("ctrl+s runs it, tab completes a name, ctrl+p brings back the last one", .{});
	}

	pub fn closeEditor(self: *App) void {
		if (self.editor) |*open| {
			open.deinit();
		}
		self.editor = null;
	}

	/// Run what is in the editor and close it, so the result is what is on
	/// screen. The text goes into the history either way.
	pub fn runEditor(self: *App) !void {
		const editor = &(self.editor orelse return);
		const sql = std.mem.trim(u8, editor.text.items, " \t\r\n");
		if (sql.len == 0) {
			self.complain("nothing to run", .{});
			return;
		}
		const owned = try self.allocator.dupe(u8, sql);
		defer self.allocator.free(owned);
		self.closeEditor();
		try self.remember(owned);
		try self.runBatch(owned);
	}

	/// Put an earlier statement in the editor; `delta` walks the history.
	pub fn editorHistory(self: *App, delta: isize) !void {
		const editor = &(self.editor orelse return);
		if (self.history.items.len == 0) {
			return;
		}
		const last = self.history.items.len - 1;
		const at = switch (delta < 0) {
			true => if (editor.history_at) |value| (if (value == 0) 0 else value - 1) else last,
			false => if (editor.history_at) |value| (if (value >= last) last else value + 1) else last,
		};
		editor.history_at = at;
		try editor.setText(self.history.items[at]);
	}

	/// What tab offers: the names in this database, the columns of the table on
	/// screen, and SQL's own words.
	pub fn completeInEditor(self: *App) !void {
		const editor = &(self.editor orelse return);
		var arena = std.heap.ArenaAllocator.init(self.allocator);
		defer arena.deinit();
		const scratch = arena.allocator();
		var names: std.ArrayListUnmanaged([]const u8) = .empty;
		for (self.objects.items) |object| {
			try names.append(scratch, object.name);
		}
		for (self.cols.items) |column| {
			try names.append(scratch, column);
		}
		try names.appendSlice(scratch, sql_syntax.keywords());
		try editor.complete(names.items);
	}

	/// Watch every statement, so a slow one can be given up on. The hook stays
	/// installed for the life of the connection: it costs a call every few
	/// thousand steps of SQLite's virtual machine, or one poll per 80 ms of
	/// waiting on PostgreSQL, and it means nothing has to be wrapped.
	pub fn watchStatements(self: *App) void {
		self.watch_armed = true;
		if (self.connected) {
			self.conn.watch(.{ .context = self, .keep_going = keepGoing, .begin = beginStatement });
		}
	}

	/// A statement is starting: the clock for the spinner starts with it.
	fn beginStatement(context: *anyopaque) void {
		const self: *App = @ptrCast(@alignCast(context));
		self.run_started = monotonicMs();
		// Far enough back that the first tick is not held off by the rate limit.
		self.run_ticked = self.run_started - 1000;
		self.run_frame = 0;
		self.cancelled = false;
	}

	/// Asked by the driver, every so often, whether to carry on. Draws the
	/// spinner and looks for ctrl+c - and works out on its own where one
	/// statement ends and the next begins, from the gap between calls.
	fn keepGoing(context: *anyopaque) bool {
		const self: *App = @ptrCast(@alignCast(context));
		const now = monotonicMs();
		if (now - self.run_ticked < 90) {
			return !self.cancelled;
		}
		self.run_ticked = now;
		if (self.screen.interrupted()) {
			self.cancelled = true;
			self.say("stopping...", .{});
		}
		// Anything under a third of a second should not flash a spinner at all.
		if (now - self.run_started > 300) {
			self.drawSpinner(now - self.run_started);
		}
		return !self.cancelled;
	}

	/// One line at the bottom, over the frame that is already on screen: vaxis
	/// writes only the cells that changed, so nothing else is touched.
	fn drawSpinner(self: *App, elapsed: f64) void {
		const frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
		self.run_frame = (self.run_frame + 1) % frames.len;
		const size = self.screen.size();
		var line: [160]u8 = undefined;
		const text = std.fmt.bufPrint(&line, " {s} running {d:.1}s   ctrl+c stops it", .{
			frames[self.run_frame],
			elapsed / 1000.0,
		}) catch return;
		self.screen.moveTo(size.rows - 2, 0);
		self.screen.style(.{ .bg = C.bar, .fg = if (self.cancelled) C.warn else C.accent, .bold = true });
		self.screen.put(text);
		self.screen.clearToEol();
		self.screen.reset();
		self.screen.flush() catch {};
	}

	/// Keep a connection in the list, under a name derived from the target.
	fn rememberConnection(self: *App, target: []const u8) !void {
		if (self.saved_path.items.len == 0) {
			return;
		}
		var scratch = std.heap.ArenaAllocator.init(self.allocator);
		defer scratch.deinit();
		const clean = try conns.withoutPassword(scratch.allocator(), target);
		if (self.saved.find(clean)) |at| {
			self.saved.touch(at);
		} else {
			try self.saved.add(try conns.suggestName(scratch.allocator(), clean), clean, null, "");
		}
		conns.save(&self.saved, self.saved_path.items) catch {};
	}

	/// Connect to the entry the cursor is on.
	pub fn connectSaved(self: *App) !void {
		if (self.saved_at >= self.saved.items.items.len) {
			return;
		}
		const entry = self.saved.items.items[self.saved_at];
		var scratch = std.heap.ArenaAllocator.init(self.allocator);
		defer scratch.deinit();
		// A connection that keeps its password connects with it and never asks. The
		// keychain may put up its own dialog here; that answer is the user's.
		const secret: ?[]const u8 = switch (entry.keeps) {
			.ask => null,
			.file => entry.secret,
			.keychain => keychain.fetch(scratch.allocator(), entry.target) catch null,
		};
		const with = if (secret) |value|
			try conns.withPassword(scratch.allocator(), entry.target, value)
		else
			entry.target;
		const target = try self.allocator.dupe(u8, with);
		defer self.allocator.free(target);
		self.saved.touch(self.saved_at);
		self.saved_at = 0;
		conns.save(&self.saved, self.saved_path.items) catch {};
		try self.connect(target, false);
	}

	/// Try again with the password that was just typed. It is used once and is
	/// not written anywhere.
	pub fn connectWithPassword(self: *App, password: []const u8) !void {
		if (self.pending_target.items.len == 0) {
			return;
		}
		var scratch = std.heap.ArenaAllocator.init(self.allocator);
		defer scratch.deinit();
		const target = try conns.withPassword(scratch.allocator(), self.pending_target.items, password);
		const clean = try self.allocator.dupe(u8, self.pending_target.items);
		defer self.allocator.free(clean);
		self.pending_target.clearRetainingCapacity();
		try self.connect(target, false);
		if (!self.connected) {
			return;
		}
		try self.rememberConnection(clean);
		// The entry is at the front after rememberConnection; if it keeps its
		// password somewhere, this is the password to put there.
		if (self.saved.items.items.len == 0) {
			return;
		}
		switch (self.saved.items.items[0].keeps) {
			.ask => {},
			.file => {
				try self.saved.keep(0, .file, password);
				conns.save(&self.saved, self.saved_path.items) catch {};
				self.say("connected, and the password is now in {s}", .{self.saved_path.items});
			},
			.keychain => {
				const target_now = self.saved.items.items[0].target;
				if (keychain.store(target_now, password)) |_| {
					self.say("connected, and the password is now in the keychain", .{});
				} else |_| {
					self.complain("connected, but the keychain would not take the password", .{});
				}
			},
		}
	}

	pub fn forgetSaved(self: *App) !void {
		if (self.saved_at >= self.saved.items.items.len) {
			return;
		}
		var name: [128]u8 = undefined;
		const label = std.fmt.bufPrint(&name, "{s}", .{self.saved.items.items[self.saved_at].name}) catch "it";
		const going = self.saved.items.items[self.saved_at];
		if (going.keeps == .keychain) {
			keychain.remove(going.target);
		}
		_ = self.saved.items.orderedRemove(self.saved_at);
		if (self.saved_at >= self.saved.items.items.len and self.saved_at > 0) {
			self.saved_at -= 1;
		}
		conns.save(&self.saved, self.saved_path.items) catch {};
		self.say("{s} removed from the list", .{label});
	}

	/// The form for adding or editing a connection.
	pub fn openConnectionForm(self: *App, edit: bool) !void {
		self.editing_saved = null;
		_ = self.form_arena.reset(.retain_capacity);
		var name: []const u8 = "";
		var target: []const u8 = "";
		var secret: []const u8 = "";
		var keeps: conns.Keeps = .ask;
		if (edit) {
			if (self.saved_at >= self.saved.items.items.len) {
				self.complain("there is nothing to edit yet - press a to add one", .{});
				return;
			}
			const entry = self.saved.items.items[self.saved_at];
			name = entry.name;
			target = entry.target;
			keeps = entry.keeps;
			secret = entry.secret;
			self.editing_saved = self.saved_at;
		}
		// A target that cannot be taken apart and put back together identically is
		// left as the one field it always was.
		const shape = conns.decompose(self.formArena(), target) orelse conns.Shape{
			.engine = if (target.len == 0) .sqlite else .other,
			.path = target,
		};
		try self.showConnectionForm(shape, name, keeps, secret);
	}

	/// An arena that outlives the form: the connection form is built again every
	/// time the engine changes, and what was typed has to survive that.
	fn formArena(self: *App) std.mem.Allocator {
		return self.form_arena.allocator();
	}

	fn showConnectionForm(self: *App, shape: conns.Shape, name: []const u8, keeps: conns.Keeps, secret: []const u8) !void {
		const form = try self.newForm(
			.connection,
			if (self.editing_saved != null) "edit connection" else "add connection",
			"pick the engine, fill in what it needs - ctrl+s saves and connects",
		);
		self.built_engine = shape.engine;
		try form.text("name", name, 24);
		try form.choice("engine", &conns.ENGINES, Form.indexOf(&conns.ENGINES, shape.engine.label()));

		switch (shape.engine) {
			.sqlite => {
				try form.text("file", shape.path, 52);
				try form.note("a path to a database file; it is made if it is not there");
			},
			.other => {
				try form.text("target", shape.path, 52);
				try form.note("anything the engines take, as it stands - a libpq keyword string,");
				try form.note("a scheme with a spelling of its own, a query this form does not know");
			},
			.postgres, .mysql => {
				try form.text("host", shape.host, 24);
				try form.text("port", shape.port, 6);
				form.sameLine();
				try form.text("database", shape.name, 24);
				try form.text("user", shape.user, 24);
				try form.note("leave the port empty for the usual one, and the user for your own name");
			},
			.redis => {
				try form.text("host", shape.host, 24);
				try form.text("port", shape.port, 6);
				form.sameLine();
				try form.text("database", shape.name, 6);
				try form.note("the database is Redis's numbered one: 0 unless you know otherwise");
			},
			.kafka => {
				try form.text("host", shape.host, 24);
				try form.text("port", shape.port, 6);
				form.sameLine();
				try form.text("user", shape.user, 24);
				try form.choice("mechanism", &MECHANISMS, Form.indexOf(&MECHANISMS, shape.mechanism));
				form.sameLine();
				try form.toggle("TLS", shape.tls);
				try form.note("a user with no mechanism named is PLAIN, which is what brokers are set up for");
			},
			.s3 => {
				try form.text("bucket", shape.name, 24);
				try form.text("region", shape.region, 16);
				form.sameLine();
				try form.text("endpoint", shape.host, 24);
				try form.text("port", shape.port, 6);
				form.sameLine();
				try form.text("access key", shape.user, 24);
				try form.toggle("TLS", shape.tls);
				form.sameLine();
				try form.note("no endpoint means Amazon; one means MinIO, Ceph, R2 - and the bucket");
				try form.note("goes in the path there. The secret key is the password below, and an");
				try form.note("empty access key means ~/.aws and AWS_ACCESS_KEY_ID are looked at.");
			},
			.azure => {
				try form.text("account", shape.user, 24);
				try form.text("container", shape.name, 24);
				try form.text("endpoint", shape.host, 24);
				try form.text("port", shape.port, 6);
				form.sameLine();
				try form.toggle("TLS", shape.tls);
				form.sameLine();
				try form.note("no endpoint means Azure itself; one means Azurite or a proxy, and");
				try form.note("the account goes in the path there. The account key is the password");
				try form.note("below - the long base64 one from the portal, not the connection string.");
			},
			.sftp => {
				try form.text("host", shape.host, 24);
				try form.text("port", shape.port, 6);
				form.sameLine();
				try form.text("user", shape.user, 24);
				try form.text("directory", shape.name, 32);
				try form.text("key file", shape.key, 32);
				try form.toggle("check the host key", !shape.insecure);
				try form.note("the key file is a private key; empty tries the agent and ~/.ssh/id_*,");
				try form.note("and the password below is used when neither works. The host key is");
				try form.note("checked against ~/.ssh/known_hosts unless that is turned off here.");
			},
			.rabbit => {
				try form.text("host", shape.host, 24);
				try form.text("port", shape.port, 6);
				form.sameLine();
				try form.text("vhost", shape.name, 24);
				try form.text("user", shape.user, 24);
				try form.toggle("TLS", shape.tls);
				form.sameLine();
				try form.note("the port is the management one, 15672, and not the broker's 5672;");
				try form.note("the default vhost is written %2F");
			},
		}

		// Only offer what this machine has: the keychain is macOS's.
		const places = if (keychain.available) &PLACES else PLACES[0..2];
		try form.choice("keep the password", places, Form.indexOf(places, @tagName(keeps)));
		try form.secret("password", secret, 24);
		form.sameLine();
		try form.note("file: plain text in ~/.config/krtek/connections, which only you can read");
		if (keychain.available) {
			try form.note("keychain: in the macOS keychain, which asks you before handing it over");
		}
		try form.note("ask: nothing is kept - as with ~/.pgpass, ~/.my.cnf or PGPASSWORD");
	}

	/// The connection form is the one whose fields depend on an answer inside it,
	/// so changing the engine builds the rest of it again - keeping whatever was
	/// typed that the new engine also asks for.
	pub fn afterFormKey(self: *App) !void {
		const form = &(self.form orelse return);
		if (form.purpose != .connection) {
			return;
		}
		const picked = conns.Engine.of(form.valueNamed("engine"));
		if (picked == self.built_engine) {
			return;
		}
		var shape = self.shapeOf(form);
		shape.engine = picked;
		// Encryption is the new engine's default, not whatever the last one had:
		// off on a broker inside a network, on for a bucket on the internet.
		shape.tls = picked == .s3;
		const name = try self.formArena().dupe(u8, form.valueNamed("name"));
		const secret = try self.formArena().dupe(u8, form.valueNamed("password"));
		const keeps = std.meta.stringToEnum(conns.Keeps, form.valueNamed("keep the password")) orelse .ask;
		try self.showConnectionForm(shape, name, keeps, secret);
		// Back on the engine, so it can be cycled again without walking up to it.
		self.form.?.cursor = 1;
	}

	/// What the fields of the connection form say, whichever engine they are for.
	fn shapeOf(self: *App, form: *Form.Form) conns.Shape {
		const arena = self.formArena();
		var shape = conns.Shape{ .engine = conns.Engine.of(form.valueNamed("engine")) };
		const Pairs = struct { label: []const u8, into: *[]const u8 };
		for ([_]Pairs{
			.{ .label = "file", .into = &shape.path },
			.{ .label = "target", .into = &shape.path },
			.{ .label = "host", .into = &shape.host },
			.{ .label = "endpoint", .into = &shape.host },
			.{ .label = "port", .into = &shape.port },
			.{ .label = "database", .into = &shape.name },
			.{ .label = "bucket", .into = &shape.name },
			.{ .label = "vhost", .into = &shape.name },
			.{ .label = "user", .into = &shape.user },
			.{ .label = "access key", .into = &shape.user },
			.{ .label = "region", .into = &shape.region },
			.{ .label = "mechanism", .into = &shape.mechanism },
			.{ .label = "key file", .into = &shape.key },
			.{ .label = "directory", .into = &shape.name },
		}) |pair| {
			const value = form.valueNamed(pair.label);
			if (value.len != 0) {
				pair.into.* = arena.dupe(u8, value) catch value;
			}
		}
		shape.tls = if (form.fieldNamed("TLS")) |field| field.on else shape.engine == .s3;
		// The one toggle that reads the other way round: it says to check, and the
		// target says not to.
		shape.insecure = if (form.fieldNamed("check the host key")) |field| !field.on else false;
		return shape;
	}

	pub fn deinitConnection(self: *App) void {
		if (self.connected) {
			self.conn.close();
			self.connected = false;
		}
	}

	pub fn deinit(self: *App) void {
		self.screen.deinit();
		if (self.files) |open| {
			open.deinit();
			self.files = null;
		}
		self.deinitConnection();
		self.freeObjects();
		self.objects.deinit(self.allocator);
		self.filter.deinit(self.allocator);
		self.cols.deinit(self.allocator);
		self.widths.deinit(self.allocator);
		self.rows.deinit(self.allocator);
		self.title.deinit(self.allocator);
		self.status.deinit(self.allocator);
		self.reports.deinit(self.allocator);
		self.marked.deinit(self.allocator);
		self.pending.deinit(self.allocator);
		self.saved.deinit();
		self.saved_path.deinit(self.allocator);
		self.pending_target.deinit(self.allocator);
		if (self.palette) |*open| {
			open.query.deinit(self.allocator);
		}
		self.closeEditor();
		self.hidden.deinit(self.allocator);
		self.clearConditions();
		self.conditions.deinit(self.allocator);
		self.where_text.deinit(self.allocator);
		self.closeForm();
		for (self.history.items) |entry| {
			self.allocator.free(entry);
		}
		self.history.deinit(self.allocator);
		if (self.order) |value| {
			self.allocator.free(value);
		}
		if (self.table_name) |value| {
			self.allocator.free(value);
		}
		self.schema.deinit(self.allocator);
		if (self.prompt) |*prompt| {
			prompt.buffer.deinit(self.allocator);
		}
		self.allocator.free(self.owned_path);
		self.arena.deinit();
		self.reports_arena.deinit();
		self.form_arena.deinit();
	}

	/// The table on screen, with the schema it lives in.
	pub fn currentTable(self: *App) ?database.Table {
		return .{ .schema = self.schema.items, .name = self.table_name orelse return null };
	}

	pub fn hasTable(self: *App) bool {
		return self.table_name != null;
	}

	fn setTable(self: *App, name: ?[]const u8) !void {
		if (self.table_name) |old| {
			self.allocator.free(old);
		}
		self.table_name = if (name) |value| try self.allocator.dupe(u8, value) else null;
	}

	pub fn say(self: *App, comptime fmt: []const u8, args: anytype) void {
		self.status.clearRetainingCapacity();
		self.status.print(self.allocator, fmt, args) catch {};
		self.status_error = false;
	}

	pub fn complain(self: *App, comptime fmt: []const u8, args: anytype) void {
		self.say(fmt, args);
		self.status_error = true;
	}

	fn setTitle(self: *App, comptime fmt: []const u8, args: anytype) void {
		self.title.clearRetainingCapacity();
		self.title.print(self.allocator, fmt, args) catch {};
	}

	// -------------------------------------------------------------- schema

	fn freeObjects(self: *App) void {
		for (self.objects.items) |object| {
			self.allocator.free(object.name);
			self.allocator.free(object.kind);
		}
		self.objects.clearRetainingCapacity();
	}

	pub fn loadObjects(self: *App) !void {
		self.freeObjects();
		var arena = std.heap.ArenaAllocator.init(self.allocator);
		defer arena.deinit();
		for (try self.conn.objects(arena.allocator(), self.schema.items)) |object| {
			try self.objects.append(self.allocator, .{
				.name = try self.allocator.dupe(u8, object.name),
				.kind = try self.allocator.dupe(u8, if (object.kind == .view) "view" else "table"),
				.rows = object.rows,
			});
		}
		// An engine that only estimates gets an exact count, which is what the
		// sidebar promises.
		for (self.objects.items) |*object| {
			if (object.rows == null or object.rows.? < 0) {
				object.rows = self.conn.rowCount(.{ .schema = self.schema.items, .name = object.name });
			}
		}
	}

	pub fn matches(self: *App, index: usize) bool {
		// The same fuzzy match as the command palette: `usr` finds `users`, and
		// `ordit` finds `order_items`.
		return self.filter.items.len == 0 or
			fuzzy.match(self.objects.items[index].name, self.filter.items, null) != null;
	}

	/// Which letters of an object's name the filter matched, for the sidebar.
	pub fn filterHit(self: *App, name: []const u8) fuzzy.Hit {
		var hit = fuzzy.Hit{};
		if (self.filter.items.len != 0) {
			_ = fuzzy.match(name, self.filter.items, &hit);
		}
		return hit;
	}

	pub fn visibleCount(self: *App) usize {
		var count: usize = 0;
		for (0..self.objects.items.len) |i| {
			count += @intFromBool(self.matches(i));
		}
		return count;
	}

	/// The object shown at visible position `n`.
	pub fn visibleAt(self: *App, n: usize) ?Object {
		var seen: usize = 0;
		for (0..self.objects.items.len) |i| {
			if (!self.matches(i)) {
				continue;
			}
			if (seen == n) {
				return self.objects.items[i];
			}
			seen += 1;
		}
		return null;
	}

	pub fn current(self: *App) ?Object {
		return self.visibleAt(self.selected);
	}

	/// The first value of the first row as text; null when there is none.
	pub fn scalarText(self: *App, arena: std.mem.Allocator, sql: []const u8) !?[]const u8 {
		var rows = (self.conn.query(sql, null) catch return null) orelse return null;
		defer rows.close();
		if (!(rows.next() catch return null)) {
			return null;
		}
		return switch (rows.value(0)) {
			.null => null,
			.text, .blob => |bytes| try arena.dupe(u8, bytes),
			.int => |v| try std.fmt.allocPrint(arena, "{d}", .{v}),
			.float => |v| try std.fmt.allocPrint(arena, "{d}", .{v}),
		};
	}

	/// Column names of a table, in declared order.
	/// Column names in order, for the forms and the dumps.
	pub fn columnsOf(self: *App, arena: std.mem.Allocator, name: []const u8) ![]const []const u8 {
		var list: std.ArrayListUnmanaged([]const u8) = .empty;
		for (try self.conn.columns(arena, .{ .schema = self.schema.items, .name = name })) |column| {
			try list.append(arena, column.name);
		}
		return list.items;
	}

	pub fn columnDefs(self: *App, arena: std.mem.Allocator, name: []const u8) ![]database.Column {
		return self.conn.columns(arena, .{ .schema = self.schema.items, .name = name });
	}

	pub fn foreignKeyDefs(self: *App, arena: std.mem.Allocator, name: []const u8) ![]database.ForeignKey {
		return self.conn.foreignKeys(arena, .{ .schema = self.schema.items, .name = name });
	}

	// ----------------------------------------------------------- data load

	pub fn openTable(self: *App, name: []const u8) !void {
		try self.setTable(name);
		self.page = 0;
		self.cursor_row = 0;
		self.cursor_col = 0;
		self.row_scroll = 0;
		self.col_scroll = 0;
		if (self.order) |value| {
			self.allocator.free(value);
			self.order = null;
		}
		self.descending = false;
		self.marked.clearRetainingCapacity();
		self.hidden.clearRetainingCapacity();
		self.clearConditions();
		self.where_text.clearRetainingCapacity();
		self.view = .grid;
		try self.reload();
	}

	pub fn reload(self: *App) !void {
		const table = self.currentTable() orelse return;
		const counted = if (!self.isFiltered())
			self.conn.rowCount(table)
		else
			self.conn.count(self.filtered(table));
		self.counted = counted != null;
		self.total = counted orelse 0;

		const page_count = self.pages();
		if (self.page >= page_count) {
			self.page = page_count - 1;
		}

		// A key that is not part of the row has to be asked for by name; that is
		// what lets a table whose primary key is invisible still be edited.
		var key_arena = std.heap.ArenaAllocator.init(self.allocator);
		defer key_arena.deinit();
		const key = self.conn.rowKey(key_arena.allocator(), table) catch database.RowKey{};
		const hidden_key = key.hidden and key.expression.len != 0;
		var request = self.filtered(table);
		if (hidden_key) {
			request.extra = key.expression;
			request.extra_as = "__key";
		}
		if (self.order) |column| {
			request.order = column;
			request.descending = self.descending;
		}
		request.limit = self.limit;
		request.offset = self.page * self.limit;

		self.grid_failed = false;
		self.loadSelect(request, table, hidden_key) catch {
			self.cols.clearRetainingCapacity();
			self.rows.clearRetainingCapacity();
			self.widths.clearRetainingCapacity();
			self.total = 0;
			self.grid_failed = true;
			self.complain("{s}", .{self.conn.message()});
			return;
		};
		self.setTitle("{s}", .{table.name});
	}

	/// The table as the grid is looking at it: whatever the filter row says, and
	/// nothing else. The page, the order and the hidden key are added by whoever
	/// needs them, because a count wants none of the three.
	fn filtered(self: *App, table: database.Table) database.ask.Select {
		return .{
			.table = table,
			.where = self.conditions.items,
			.where_text = self.where_text.items,
		};
	}

	/// Whether the grid is showing part of a table rather than all of it.
	pub fn isFiltered(self: *App) bool {
		return self.conditions.items.len != 0 or self.where_text.items.len != 0;
	}

	fn clearConditions(self: *App) void {
		for (self.conditions.items) |condition| {
			self.allocator.free(condition.column);
			self.allocator.free(condition.value);
		}
		self.conditions.clearRetainingCapacity();
	}

	pub fn isHidden(self: *App, column: usize) bool {
		return std.mem.indexOfScalar(usize, self.hidden.items, column) != null;
	}

	pub fn isMarked(self: *App, row: usize) bool {
		return std.mem.indexOfScalar(usize, self.marked.items, row) != null;
	}

	pub fn toggleMark(self: *App) !void {
		if (self.cursor_row >= self.rows.items.len) {
			return;
		}
		if (std.mem.indexOfScalar(usize, self.marked.items, self.cursor_row)) |at| {
			_ = self.marked.orderedRemove(at);
		} else {
			try self.marked.append(self.allocator, self.cursor_row);
		}
	}

	/// Delete the marked rows, or the one under the cursor when none are marked.
	/// Say why the row under the cursor cannot be changed, and whether that is so.
	/// An empty result and a result without a key are two different things, and
	/// saying "read-only" for both sent someone looking for a bug that was not
	/// there.
	fn noRowHere(self: *App) bool {
		if (self.rows.items.len == 0) {
			self.complain("there is no row here", .{});
			return true;
		}
		if (!self.editable) {
			self.complain("these rows cannot be addressed, so they are read-only", .{});
			return true;
		}
		if (self.cursor_row >= self.rows.items.len) {
			self.complain("move onto a row first", .{});
			return true;
		}
		return false;
	}

	pub fn deleteRows(self: *App) !void {
		if (self.rows.items.len != 0 and !self.editable) {
			self.complain("these rows cannot be addressed, so they are read-only", .{});
			return;
		}
		if (self.rows.items.len == 0) {
			self.complain("there is no row here", .{});
			return;
		}
		// Where a row is a file, deleting one is deleting a file, and there is no
		// transaction to take it back. A database row goes as it always has.
		if (self.conn.files() != null) {
			const count = if (self.marked.items.len != 0) self.marked.items.len else @as(usize, 1);
			if (self.prompt) |*old| {
				old.buffer.deinit(self.allocator);
			}
			self.prompt = .{ .kind = .remove_rows, .label = " type y to delete: " };
			self.say("delete {d} file{s}?", .{ count, if (count == 1) "" else "s" });
			return;
		}
		try self.deleteRowsNow();
	}

	pub fn deleteRowsNow(self: *App) !void {
		const table = self.currentTable() orelse return;
		var targets: std.ArrayListUnmanaged(usize) = .empty;
		defer targets.deinit(self.allocator);
		if (self.marked.items.len != 0) {
			try targets.appendSlice(self.allocator, self.marked.items);
		} else if (self.cursor_row < self.rows.items.len) {
			try targets.append(self.allocator, self.cursor_row);
		} else {
			return;
		}
		var deleted: usize = 0;
		for (targets.items) |index| {
			if (index >= self.rows.items.len) {
				continue;
			}
			const key = self.rows.items[index].key orelse continue;
			try self.change(.{ .kind = .delete, .table = table, .where = key }) orelse return;
			deleted += 1;
		}
		self.marked.clearRetainingCapacity();
		try self.loadObjects();
		try self.reload();
		self.say("{d} row(s) deleted", .{deleted});
	}

	/// Put a cursor's rows on the grid. With `hidden_key` the first column
	/// addresses the row and is not displayed.
	///
	/// The rows are read first and only then asked about: an engine that streams
	/// results - PostgreSQL does - refuses another query while one is still open,
	/// so the key lookup has to wait until the cursor is closed.
	/// Rows for SQL the user wrote.
	pub fn load(self: *App, sql: []const u8, source: ?database.Table, hidden_key: bool) !void {
		_ = self.arena.reset(.retain_capacity);
		var cursor = (try self.conn.query(sql, null)) orelse return;
		return self.fill(&cursor, source, hidden_key);
	}

	/// Rows for a request the interface put together itself, which is how the grid
	/// asks: no SQL is written, so an engine without SQL can answer it too.
	pub fn loadSelect(self: *App, request: database.ask.Select, source: ?database.Table, hidden_key: bool) !void {
		_ = self.arena.reset(.retain_capacity);
		var cursor = (try self.conn.select(request)) orelse return;
		return self.fill(&cursor, source, hidden_key);
	}

	fn fill(self: *App, cursor_in: *database.Rows, source: ?database.Table, hidden_key: bool) !void {
		const arena = self.arena.allocator();
		self.cols.clearRetainingCapacity();
		self.widths.clearRetainingCapacity();
		self.rows.clearRetainingCapacity();
		self.editable = false;

		var raw: std.ArrayListUnmanaged([]Cell) = .empty;
		var origins: std.ArrayListUnmanaged([]const u8) = .empty;
		var from: ?database.Table = source;
		var count: usize = 0;
		{
			var cursor = cursor_in.*;
			defer cursor.close();
			count = cursor.columnCount();
			const skip: usize = if (hidden_key and count > 0) 1 else 0;
			for (skip..count) |i| {
				const name = try arena.dupe(u8, cursor.name(i));
				try self.cols.append(self.allocator, name);
				try self.widths.append(self.allocator, term.width(name));
				try origins.append(arena, try arena.dupe(u8, cursor.sourceColumn(i)));
			}
			if (from == null) {
				// Only the metadata already in hand, no query.
				var single: ?[]const u8 = null;
				for (0..count) |i| {
					const owner = cursor.sourceTable(i);
					if (owner.len == 0) {
						continue;
					}
					if (single) |existing| {
						if (!std.mem.eql(u8, existing, owner)) {
							single = null;
							break;
						}
					} else {
						single = try arena.dupe(u8, owner);
					}
				}
				if (single) |name| {
					from = .{ .schema = self.schema.items, .name = name };
				}
			}
			var loaded: usize = 0;
			while (try cursor.next()) {
				if (loaded >= self.limit) {
					break;
				}
				loaded += 1;
				const cells = try arena.alloc(Cell, count);
				for (0..count) |i| {
					cells[i] = try formatCell(arena, cursor.value(i), cursor.isNumeric(i));
				}
				for (cells[skip..], 0..) |cell, i| {
					self.widths.items[i] = @max(self.widths.items[i], term.width(cell.text));
				}
				try raw.append(arena, cells);
			}
		}

		// The cursor is closed, so the engine can be asked things again.
		const skip: usize = if (hidden_key and count > 0) 1 else 0;
		var keys: std.ArrayListUnmanaged(Position) = .empty;
		if (hidden_key) {
			try keys.append(arena, .{ .name = "__key", .at = 0 });
			self.editable = true;
		} else if (from) |table| {
			const key = self.conn.rowKey(arena, table) catch database.RowKey{};
			var complete = key.usable() and !key.hidden;
			for (key.columns) |column| {
				var found: ?usize = null;
				for (origins.items, 0..) |origin, i| {
					if (std.mem.eql(u8, origin, column) or std.mem.eql(u8, self.cols.items[i], column)) {
						found = i + skip;
						break;
					}
				}
				if (found) |at| {
					try keys.append(arena, .{ .name = column, .at = at });
				} else {
					complete = false;
				}
			}
			self.editable = complete;
		}

		// The engine's own name for a hidden key, asked for once rather than per row.
		var hidden_name: []const u8 = "";
		if (hidden_key) {
			const found = self.conn.rowKey(arena, from orelse .{ .name = "" }) catch database.RowKey{};
			hidden_name = found.expression;
		}
		for (raw.items) |cells| {
			const identity: ?[]const database.ask.Filter = if (self.editable)
				try identityOf(arena, keys.items, cells, hidden_name)
			else
				null;
			try self.rows.append(self.allocator, .{ .cells = cells[skip..], .key = identity });
		}
		self.clampCursor();
	}

	/// The single table a result comes from, if there is exactly one.
	fn sourceOf(cursor: *database.Rows, arena: std.mem.Allocator, given: ?database.Table) ?database.Table {
		if (given) |table| {
			return table;
		}
		var found: ?[]const u8 = null;
		for (0..cursor.columnCount()) |i| {
			const name = cursor.sourceTable(i);
			if (name.len == 0) {
				continue;
			}
			if (found) |existing| {
				if (!std.mem.eql(u8, existing, name)) {
					return null; // a join cannot be edited
				}
			} else {
				found = arena.dupe(u8, name) catch return null;
			}
		}
		return .{ .name = found orelse return null };
	}

	pub fn clampCursor(self: *App) void {
		if (self.cursor_row >= self.rows.items.len) {
			self.cursor_row = if (self.rows.items.len == 0) 0 else self.rows.items.len - 1;
		}
		if (self.cursor_col >= self.cols.items.len) {
			self.cursor_col = if (self.cols.items.len == 0) 0 else self.cols.items.len - 1;
		}
	}

	pub fn pages(self: *App) usize {
		// Without a count there is no last page: there is this one, and another one
		// if this one filled up.
		if (!self.counted) {
			return self.page + 1 + @intFromBool(self.rows.items.len >= self.limit);
		}
		return @max(1, divCeil(@intCast(@max(0, self.total)), self.limit));
	}

	// ------------------------------------------------------------ commands

	/// Run a batch: every statement is reported, the last result set becomes the
	/// grid, and a transaction left open is rolled back.
	pub fn runBatch(self: *App, sql: []const u8) !void {
		try self.runBatchStopping(sql, false);
	}

	/// With `stop_on_error` the batch ends at the first failure, which is what a
	/// generated script needs: its own COMMIT would otherwise make a half
	/// finished rebuild permanent.
	pub fn runBatchStopping(self: *App, sql: []const u8, stop_on_error: bool) !void {
		_ = self.reports_arena.reset(.retain_capacity);
		const arena = self.reports_arena.allocator();
		self.reports.clearRetainingCapacity();

		var shown = false;
		var failures: usize = 0;
		// The engine's own parser decides where one statement ends.
		const statements = self.conn.split(arena, sql) catch &[_]database.Statement{};
		for (statements) |statement| {
			const started = monotonicMs();
			var produced: i64 = 0;
			var failure: ?[]const u8 = null;
			var result_set = false;
			var changed: i64 = 0;

			if (self.conn.query(statement.sql, null)) |maybe| {
				if (maybe) |cursor| {
					var rows = cursor;
					result_set = rows.columnCount() > 0;
					if (result_set) {
						// The grid is filled from this cursor rather than by running the
						// statement a second time. It used to run it again, which is
						// harmless for a SELECT and not at all harmless for an engine
						// whose console has PRODUCE and SET in it: those happened twice.
						self.fill(&rows, null, false) catch {
							failure = try arena.dupe(u8, self.conn.message());
						};
						produced = @intCast(self.rows.items.len);
						shown = failure == null;
					} else {
						while (true) {
							const more = rows.next() catch {
								failure = try arena.dupe(u8, self.conn.message());
								break;
							};
							if (!more) {
								break;
							}
							produced += 1;
						}
						changed = rows.affected();
						rows.close();
					}
				}
			} else |_| {
				failure = try arena.dupe(u8, self.conn.message());
			}

			if (failure != null) {
				failures += 1;
			}
			try self.reports.append(self.allocator, .{
				// Copied: the splitter points into the caller's buffer, which is
				// gone by the time the report is drawn.
				.sql = try arena.dupe(u8, statement.sql),
				.ms = monotonicMs() - started,
				.changes = changed,
				.rows = produced,
				.result_set = result_set,
				.failure = failure,
			});
			if (failure != null and stop_on_error) {
				break;
			}
			// A statement the user gave up on ends the batch: carrying on with the
			// rest of it is never what stopping meant.
			if (self.cancelled) {
				break;
			}
		}

		var rolled_back = false;
		if (self.conn.inTransaction()) {
			self.conn.exec("ROLLBACK") catch {};
			rolled_back = true;
		}

		// A statement that was given up on is not run a second time to fill the
		// grid, which is what showing a result normally takes.
		if (self.cancelled) {
			self.cancelled = false;
			try self.loadObjects();
			self.complain("stopped{s}", .{if (rolled_back) ", rolled back" else ""});
			return;
		}

		if (shown) {
			// The rows are already on the grid; what is left is to look at them.
			try self.setTable(null);
			self.page = 0;
			self.cursor_row = 0;
			self.cursor_col = 0;
			self.row_scroll = 0;
			self.col_scroll = 0;
			self.clampCursor();
			self.total = @intCast(self.rows.items.len);
			self.setTitle("query result", .{});
			self.view = .grid;
			self.focus = .main;
		}
		try self.loadObjects();

		var affected: i64 = 0;
		for (self.reports.items) |report| {
			affected += report.changes;
		}
		if (failures > 0) {
			self.complain("{d} of {d} statement(s) failed, press m for details{s}", .{
				failures, self.reports.items.len, if (rolled_back) ", rolled back" else "",
			});
		} else {
			self.say("{d} statement(s), {d} row(s) affected{s}", .{
				self.reports.items.len, affected, if (rolled_back) ", rolled back" else "",
			});
		}
	}

	pub fn remember(self: *App, sql: []const u8) !void {
		if (sql.len == 0) {
			return;
		}
		if (self.history.items.len > 0 and std.mem.eql(u8, self.history.items[self.history.items.len - 1], sql)) {
			return;
		}
		try self.history.append(self.allocator, try self.allocator.dupe(u8, sql));
	}

	/// Ask before running something destructive.
	pub fn confirm(self: *App, statement: []const u8, verb: []const u8) !void {
		self.pending.clearRetainingCapacity();
		try self.pending.appendSlice(self.allocator, statement);
		self.prompt = .{ .kind = .confirm, .label = " type y to " };
		try self.prompt.?.buffer.appendSlice(self.allocator, "");
		self.say("{s}: {s}", .{ verb, statement });
	}

	// ------------------------------------------------------- the file manager

	/// Open the two panes: this machine on the left, and the connection on the
	/// right when it is somewhere files live. A database is not, and says so.
	pub fn openFiles(self: *App) !void {
		if (self.files != null) {
			self.view = .files;
			return;
		}
		const far = if (self.connected) self.conn.files() else null;
		if (far == null) {
			self.complain("{s} holds rows, not files - this is for SFTP, S3 and Azure", .{self.conn.caps().label});
			return;
		}
		self.files = try Files.Manager.init(self.allocator, far);
		try self.files.?.open();
		self.view = .files;
		self.say("tab switches panes, c copies, ? shows the rest", .{});
	}

	pub fn closeFiles(self: *App) void {
		if (self.files) |open| {
			open.deinit();
		}
		self.files = null;
		self.view = .grid;
	}

	/// Copy what is chosen in this pane to where the other one is looking.
	pub fn copyFiles(self: *App) !void {
		const manager = self.files orelse return;
		const from = manager.here();
		const to = manager.there();

		var scratch = std.heap.ArenaAllocator.init(self.allocator);
		defer scratch.deinit();
		const arena = scratch.allocator();

		const chosen = try from.chosen(arena);
		if (chosen.len == 0) {
			self.complain("nothing to copy", .{});
			return;
		}

		self.copy_started = monotonicMs();
		self.copy_ticked = self.copy_started - 1000;
		self.cancelled = false;
		var total = database.store.Tally{};
		for (chosen) |entry| {
			const source = try database.store.join(arena, from.where(), entry.name);
			const target = try database.store.join(arena, to.where(), entry.name);
			// Into itself is the one mistake here that eats a disk, and it can only
			// happen when both panes are the same place.
			if (std.meta.activeTag(from.place) == std.meta.activeTag(to.place) and
				entry.kind == .dir and database.store.within(source, target))
			{
				self.complain("{s} is inside itself - that would not end", .{entry.name});
				return;
			}
			const tally = database.store.copy(arena, from.place, source, to.place, target, .{
				.context = self,
				.step = copyStep,
			}) catch {
				const why = to.place.message();
				const from_why = from.place.message();
				self.complain("{s}: {s}", .{
					entry.name,
					if (self.cancelled) "stopped" else if (why.len != 0) why else from_why,
				});
				to.reload(self.allocator);
				return;
			};
			total.files += tally.files;
			total.dirs += tally.dirs;
			total.bytes += tally.bytes;
		}
		to.reload(self.allocator);
		from.marked.clearRetainingCapacity();
		var room: [16]u8 = undefined;
		self.say("copied {d} file{s} - {s}", .{
			total.files,
			if (total.files == 1) "" else "s",
			Files.size(&room, total.bytes),
		});
	}

	/// Asked as the bytes move: draws a line and looks for ctrl+c, exactly as a
	/// long query does.
	fn copyStep(context: *anyopaque, name: []const u8, done: u64, whole: u64) bool {
		const self: *App = @ptrCast(@alignCast(context));
		const now = monotonicMs();
		if (now - self.copy_ticked < 90) {
			return !self.cancelled;
		}
		self.copy_ticked = now;
		if (self.screen.interrupted()) {
			self.cancelled = true;
		}
		self.drawCopying(name, done, whole);
		return !self.cancelled;
	}

	fn drawCopying(self: *App, name: []const u8, done: u64, whole: u64) void {
		const size = self.screen.size();
		var moved: [16]u8 = undefined;
		var all: [16]u8 = undefined;
		var line: [256]u8 = undefined;
		const text = std.fmt.bufPrint(&line, " copying {s} - {s} of {s}   ctrl+c stops it", .{
			Files.trim(database.store.basename(name), 40),
			Files.size(&moved, done),
			Files.size(&all, whole),
		}) catch return;
		self.screen.moveTo(size.rows - 2, 0);
		self.screen.style(.{ .bg = C.bar, .fg = if (self.cancelled) C.warn else C.accent, .bold = true });
		self.screen.put(text);
		self.screen.clearToEol();
		self.screen.reset();
		self.screen.flush() catch {};
	}

	/// Remove what is chosen, once it has been asked about. A directory takes
	/// everything under it, which is why it is asked about at all.
	pub fn deleteFiles(self: *App) !void {
		const manager = self.files orelse return;
		const pane = manager.here();
		var scratch = std.heap.ArenaAllocator.init(self.allocator);
		defer scratch.deinit();
		const arena = scratch.allocator();
		const chosen = try pane.chosen(arena);
		if (chosen.len == 0) {
			self.complain("nothing to remove", .{});
			return;
		}
		var gone: usize = 0;
		for (chosen) |entry| {
			const path = try database.store.join(arena, pane.where(), entry.name);
			database.store.removeAll(arena, pane.place, path, 0) catch {
				self.complain("{s}: {s}", .{ entry.name, pane.place.message() });
				pane.reload(self.allocator);
				return;
			};
			gone += 1;
		}
		pane.reload(self.allocator);
		self.say("removed {d}", .{gone});
	}

	pub fn makeFileDir(self: *App, name: []const u8) !void {
		const manager = self.files orelse return;
		const pane = manager.here();
		var scratch = std.heap.ArenaAllocator.init(self.allocator);
		defer scratch.deinit();
		const arena = scratch.allocator();
		const path = try database.store.join(arena, pane.where(), name);
		pane.place.makeDir(arena, path) catch {
			self.complain("{s}", .{pane.place.message()});
			return;
		};
		pane.reload(self.allocator);
		self.say("created {s}", .{name});
	}

	/// Walking to a path is fine until it is twelve directories deep, so it can
	/// be typed as well. `~` is expanded, because a person types one.
	pub fn goToPath(self: *App, path: []const u8) !void {
		const manager = self.files orelse return;
		const pane = manager.here();
		var scratch = std.heap.ArenaAllocator.init(self.allocator);
		defer scratch.deinit();
		const arena = scratch.allocator();
		const wanted = try database.store.expand(arena, std.mem.trim(u8, path, " \t"));
		const full = if (wanted.len != 0 and wanted[0] == '/')
			wanted
		else
			try database.store.join(arena, pane.where(), wanted);
		const what = pane.place.stat(arena, full) catch {
			self.complain("{s}", .{pane.place.message()});
			return;
		};
		if (what.kind != .dir) {
			self.complain("{s} is a file", .{full});
			return;
		}
		try pane.goTo(self.allocator, full);
		pane.reload(self.allocator);
	}

	pub fn renameFile(self: *App, name: []const u8) !void {
		const manager = self.files orelse return;
		const pane = manager.here();
		const one = pane.current() orelse return;
		var scratch = std.heap.ArenaAllocator.init(self.allocator);
		defer scratch.deinit();
		const arena = scratch.allocator();
		const from = try database.store.join(arena, pane.where(), one.name);
		const to = try database.store.join(arena, pane.where(), name);
		pane.place.rename(arena, from, to) catch {
			self.complain("{s}", .{pane.place.message()});
			return;
		};
		pane.reload(self.allocator);
		self.say("renamed to {s}", .{name});
	}

	pub fn clearPending(self: *App) void {
		self.pending.clearRetainingCapacity();
	}

	pub fn runPending(self: *App) !void {
		if (self.pending.items.len == 0) {
			return;
		}
		const statement = try self.allocator.dupe(u8, self.pending.items);
		defer self.allocator.free(statement);
		self.pending.clearRetainingCapacity();
		try self.runBatch(statement);
		try self.loadObjects();
		if (self.table_name) |name| {
			// The table may be gone now.
			var still_there = false;
			for (self.objects.items) |object| {
				still_there = still_there or std.mem.eql(u8, object.name, name);
			}
			if (still_there) {
				try self.reload();
			} else {
				try self.setTable(null);
				self.cols.clearRetainingCapacity();
				self.rows.clearRetainingCapacity();
				self.setTitle("", .{});
				if (self.current()) |object| {
					try self.openTable(object.name);
				}
			}
		}
	}

	pub fn command(self: *App, line: []const u8) !void {
		var parts = std.mem.tokenizeAny(u8, line, " \t");
		const verb = parts.next() orelse return;
		const argument = std.mem.trim(u8, parts.rest(), " \t");

		if (std.mem.eql(u8, verb, "q") or std.mem.eql(u8, verb, "quit")) {
			self.quit = true;
		} else if (std.mem.eql(u8, verb, "limit")) {
			const value = std.fmt.parseInt(usize, argument, 10) catch {
				self.complain(":limit needs a number", .{});
				return;
			};
			self.limit = @max(1, @min(100000, value));
			self.reload() catch {};
			self.say("{d} rows per page", .{self.limit});
		} else if (std.mem.eql(u8, verb, "export")) {
			try self.exportRows(argument);
		} else if (std.mem.eql(u8, verb, "dump")) {
			try self.dump(argument);
		} else if (std.mem.eql(u8, verb, "text")) {
			const value = std.fmt.parseInt(usize, argument, 10) catch {
				self.complain(":text needs a number", .{});
				return;
			};
			self.text_limit = @max(4, @min(200, value));
			self.say("columns clipped at {d} characters", .{self.text_limit});
		} else if (std.mem.eql(u8, verb, "analyze")) {
			self.conn.exec("ANALYZE") catch {
				self.complain("{s}", .{self.conn.message()});
				return;
			};
			self.say("statistics collected", .{});
		} else if (std.mem.eql(u8, verb, "check")) {
			var arena = std.heap.ArenaAllocator.init(self.allocator);
			defer arena.deinit();
			// Whatever the engine reports as its own health check.
			var found = false;
			for (self.conn.settings(arena.allocator()) catch &[_]database.Setting{}) |setting| {
				if (std.mem.eql(u8, setting.label, "integrity") or std.mem.eql(u8, setting.label, "role")) {
					found = true;
					if (std.mem.eql(u8, setting.value, "ok") or std.mem.eql(u8, setting.value, "primary")) {
						self.say("{s}: {s}", .{ setting.label, setting.value });
					} else {
						self.complain("{s}: {s}", .{ setting.label, setting.value });
					}
				}
			}
			if (!found) {
				self.complain("this engine reports no health check", .{});
			}
		} else if (std.mem.eql(u8, verb, "open")) {
			try self.reopen(argument);
		} else if (std.mem.eql(u8, verb, "vacuum")) {
			self.conn.exec("VACUUM") catch {
				self.complain("{s}", .{self.conn.message()});
				return;
			};
			self.say("database vacuumed", .{});
		} else {
			self.complain("unknown :{s} - try :export, :dump, :limit, :text, :open, :check, :analyze, :vacuum, :q", .{verb});
		}
	}

	/// Write the loaded rows as a delimited file: "csv <path>" or "tsv <path>".
	fn exportRows(self: *App, argument: []const u8) !void {
		var parts = std.mem.tokenizeAny(u8, argument, " \t");
		const format = parts.next() orelse "";
		const path = std.mem.trim(u8, parts.rest(), " \t");
		if (path.len == 0 or (!std.mem.eql(u8, format, "csv") and !std.mem.eql(u8, format, "tsv"))) {
			self.complain("usage: :export csv|tsv <file>", .{});
			return;
		}
		try self.writeGrid(path, if (std.mem.eql(u8, format, "tsv")) '\t' else ',');
	}

	/// The rows currently in the grid.
	pub fn writeGrid(self: *App, path: []const u8, separator: u8) !void {
		var out: std.ArrayListUnmanaged(u8) = .empty;
		defer out.deinit(self.allocator);
		for (self.cols.items, 0..) |name, i| {
			if (self.isHidden(i)) {
				continue;
			}
			if (out.items.len != 0) {
				try out.append(self.allocator, separator);
			}
			try csv.writeField(&out, self.allocator, name, separator);
		}
		try out.appendSlice(self.allocator, "\r\n");
		for (self.rows.items) |row| {
			var written: usize = 0;
			for (row.cells, 0..) |cell, i| {
				if (self.isHidden(i)) {
					continue;
				}
				if (written != 0) {
					try out.append(self.allocator, separator);
				}
				written += 1;
				if (cell.kind != .nul) {
					try csv.writeField(&out, self.allocator, cell.text, separator);
				}
			}
			try out.appendSlice(self.allocator, "\r\n");
		}
		writeFile(path, out.items) catch |err| {
			self.complain("cannot write {s}: {s}", .{ path, @errorName(err) });
			return;
		};
		self.say("{d} row(s) written to {s}", .{ self.rows.items.len, path });
	}

	/// A whole table, not just the page on screen.
	pub fn writeQuery(self: *App, path: []const u8, name: []const u8, separator: u8) !void {
		const table = database.Table{ .schema = self.schema.items, .name = name };
		var out: std.ArrayListUnmanaged(u8) = .empty;
		defer out.deinit(self.allocator);
		var cursor = (try self.conn.select(self.filtered(table))) orelse return;
		defer cursor.close();
		for (0..cursor.columnCount()) |i| {
			if (i != 0) {
				try out.append(self.allocator, separator);
			}
			try csv.writeField(&out, self.allocator, cursor.name(i), separator);
		}
		try out.appendSlice(self.allocator, "\r\n");
		var arena = std.heap.ArenaAllocator.init(self.allocator);
		defer arena.deinit();
		var rows: usize = 0;
		while (try cursor.next()) {
			rows += 1;
			_ = arena.reset(.retain_capacity);
			for (0..cursor.columnCount()) |i| {
				if (i != 0) {
					try out.append(self.allocator, separator);
				}
				const cell = try formatCell(arena.allocator(), cursor.value(i), cursor.isNumeric(i));
				if (cell.kind != .nul) {
					try csv.writeField(&out, self.allocator, cell.text, separator);
				}
			}
			try out.appendSlice(self.allocator, "\r\n");
		}
		writeFile(path, out.items) catch |err| {
			self.complain("cannot write {s}: {s}", .{ path, @errorName(err) });
			return;
		};
		self.say("{d} row(s) of {s} written to {s}", .{ rows, table.name, path });
	}

	pub fn dump(self: *App, path: []const u8) !void {
		try self.dumpTo(path, null, true, true);
	}

	/// Write an SQL dump: the whole database or one table, structure and/or data.
	/// Built from the interface, so it comes out for either engine.
	pub fn dumpTo(self: *App, path: []const u8, only: ?[]const u8, structure: bool, data: bool) !void {
		if (path.len == 0) {
			self.complain("usage: :dump <file>", .{});
			return;
		}
		var arena = std.heap.ArenaAllocator.init(self.allocator);
		defer arena.deinit();
		const scratch = arena.allocator();
		var out: std.ArrayListUnmanaged(u8) = .empty;
		defer out.deinit(self.allocator);
		try out.print(self.allocator, "-- krtek dump of {s}, {s}\n", .{ self.conn.describe(), self.conn.version() });

		var written: usize = 0;
		for (try self.conn.objects(scratch, self.schema.items)) |object| {
			if (only) |wanted| {
				if (!std.mem.eql(u8, object.name, wanted)) {
					continue;
				}
			}
			// An engine's own housekeeping is not the user's data, and dumping it
			// writes thousands of lines nobody asked for - Kafka's
			// __consumer_offsets among them.
			if (object.internal) {
				continue;
			}
			const table = database.Table{ .schema = object.schema, .name = object.name };
			written += 1;
			if (structure) {
				if (try self.conn.definition(scratch, table)) |text| {
					// The semicolon is SQL's; an engine whose statements are lines does
					// not want one, and its splitter would hand it to the engine.
					const body = std.mem.trimEnd(u8, text, ";\n");
					if (body.len != 0) {
						if (self.conn.caps().speaks_sql) {
							try out.print(self.allocator, "\n{s};\n", .{body});
						} else {
							try out.print(self.allocator, "\n{s}\n", .{body});
						}
					}
				}
				// The indexes are written from their metadata, so the dump does
				// not depend on the engine keeping DDL text around.
				for (try self.conn.indexes(scratch, table)) |index| {
					if (std.mem.eql(u8, index.kind, "PRIMARY") or index.partial) {
						continue; // part of the table, or not reconstructable
					}
					var members: std.ArrayListUnmanaged([]const u8) = .empty;
					var parts = std.mem.tokenizeSequence(u8, index.columns, ", ");
					while (parts.next()) |part| {
						try members.append(scratch, part);
					}
					if (members.items.len == 0) {
						continue;
					}
					try self.conn.ddl().createIndex(&out, self.allocator, table, index.name, members.items, std.mem.eql(u8, index.kind, "UNIQUE"), "");
				}
			}
			if (data and object.kind == .table) {
				try self.dumpRows(&out, table);
			}
		}
		writeFile(path, out.items) catch |err| {
			self.complain("cannot write {s}: {s}", .{ path, @errorName(err) });
			return;
		};
		self.say("{d} object(s), {d} bytes written to {s}", .{ written, out.items.len, path });
	}

	fn dumpRows(self: *App, out: *std.ArrayListUnmanaged(u8), table: database.Table) !void {
		var arena = std.heap.ArenaAllocator.init(self.allocator);
		defer arena.deinit();
		const names = try self.columnsOf(arena.allocator(), table.name);
		if (names.len == 0) {
			return;
		}
		// Where a row only names bytes kept elsewhere, a file of commands that put
		// the names back would put empty things where the data was.
		if (!self.conn.caps().dumps_rows) {
			try out.print(self.allocator, "-- {s} keeps the bytes, not this file: {s} was listed, not dumped\n", .{
				self.conn.caps().label,
				table.name,
			});
			return;
		}
		if (!self.conn.caps().speaks_sql) {
			return self.dumpCommands(out, table, names);
		}
		var rows = (try self.conn.select(.{ .table = table })) orelse return;
		defer rows.close();

		var first = true;
		var values: std.ArrayListUnmanaged([]const u8) = .empty;
		while (try rows.next()) {
			if (first) {
				first = false;
			} else {
				try out.appendSlice(self.allocator, ",\n");
			}
			values.clearRetainingCapacity();
			var line: std.ArrayListUnmanaged(u8) = .empty;
			for (0..rows.columnCount()) |i| {
				if (i != 0) {
					try line.appendSlice(self.allocator, ", ");
				}
				switch (rows.value(i)) {
					.null => try line.appendSlice(self.allocator, "NULL"),
					.int => |v| try line.print(self.allocator, "{d}", .{v}),
					.float => |v| try line.print(self.allocator, "{d}", .{v}),
					.text => |t| try database.quote(&line, self.allocator, t),
					.blob => |b| {
						try line.appendSlice(self.allocator, "x'");
						for (b) |byte| {
							try line.print(self.allocator, "{x:0>2}", .{byte});
						}
						try line.append(self.allocator, '\'');
					},
				}
			}
			if (out.items.len == 0 or std.mem.endsWith(u8, out.items, ";\n") or std.mem.endsWith(u8, out.items, "\n\n")) {}
			if (first == false and std.mem.endsWith(u8, out.items, "\n") and !std.mem.endsWith(u8, out.items, ",\n")) {
				try out.appendSlice(self.allocator, "\nINSERT INTO ");
				try database.quoteTable(out, self.allocator, table);
				try out.appendSlice(self.allocator, " (");
				for (names, 0..) |name, i| {
					if (i != 0) {
						try out.appendSlice(self.allocator, ", ");
					}
					try database.quoteName(out, self.allocator, name);
				}
				try out.appendSlice(self.allocator, ") VALUES\n");
			}
			try out.append(self.allocator, '(');
			try out.appendSlice(self.allocator, line.items);
			try out.append(self.allocator, ')');
			line.deinit(self.allocator);
		}
		if (!first) {
			try out.appendSlice(self.allocator, ";\n");
		}
	}

	/// A dump for an engine that has no SQL: every row as the command that would put
	/// it back, in the engine's own language and asked of the engine itself. A file of
	/// INSERT statements - which is what this wrote for every engine before - is not
	/// something Redis or Kafka can read, so the dump was unusable exactly where it
	/// was most needed.
	///
	/// What comes out goes back in: the lines are what the editor takes, so importing
	/// the file as a script replays them.
	fn dumpCommands(
		self: *App,
		out: *std.ArrayListUnmanaged(u8),
		table: database.Table,
		names: []const []const u8,
	) !void {
		var rows = (try self.conn.select(.{ .table = table })) orelse return;
		defer rows.close();
		var arena = std.heap.ArenaAllocator.init(self.allocator);
		defer arena.deinit();
		var written: usize = 0;
		while (try rows.next()) {
			_ = arena.reset(.retain_capacity);
			const a = arena.allocator();
			var cells: std.ArrayListUnmanaged(database.ask.Cell) = .empty;
			for (0..rows.columnCount()) |i| {
				const name = if (i < names.len) names[i] else rows.name(i);
				const value: ?[]const u8 = switch (rows.value(i)) {
					.null => null,
					.int => |number| try std.fmt.allocPrint(a, "{d}", .{number}),
					.float => |number| try std.fmt.allocPrint(a, "{d}", .{number}),
					.text, .blob => |bytes| try a.dupe(u8, bytes),
				};
				try cells.append(a, .{ .column = try a.dupe(u8, name), .value = value });
			}
			const line = self.conn.wording(a, .{ .change = .{
				.kind = .insert,
				.table = table,
				.cells = cells.items,
			} }) catch continue;
			try out.appendSlice(self.allocator, line);
			try out.append(self.allocator, '\n');
			written += 1;
		}
		if (written == 0) {
			try out.appendSlice(self.allocator, "-- nothing in it\n");
		}
	}

	/// The full, unflattened value under the cursor, for the detail view.
	pub fn cellDetail(self: *App, arena: std.mem.Allocator) !?[]const u8 {
		if (self.cursor_row >= self.rows.items.len or self.cursor_col >= self.cols.items.len) {
			return null;
		}
		const row = self.rows.items[self.cursor_row];
		const table = self.currentTable() orelse return try arena.dupe(u8, row.cells[self.cursor_col].text);
		const key = row.key orelse return try arena.dupe(u8, row.cells[self.cursor_col].text);
		const column = self.cols.items[self.cursor_col];
		var cursor = (try self.conn.select(.{
			.table = table,
			.columns = &.{column},
			.where = key,
			.limit = 1,
		})) orelse return null;
		defer cursor.close();
		if (!(try cursor.next())) {
			return null;
		}
		return switch (cursor.value(0)) {
			.null => null,
			.int => |value| try std.fmt.allocPrint(arena, "{d}", .{value}),
			.float => |value| try std.fmt.allocPrint(arena, "{d}", .{value}),
			.text, .blob => |bytes| try arena.dupe(u8, bytes),
		};
	}

	/// What the copy keys put in the clipboard. The value under the cursor is
	/// fetched whole, the way the detail view does it, so a copied BLOB or a long
	/// text is not the flattened one line from the grid.
	pub fn copyCell(self: *App) !void {
		var arena = std.heap.ArenaAllocator.init(self.allocator);
		defer arena.deinit();
		const text = (try self.cellDetail(arena.allocator())) orelse {
			self.complain("there is no value under the cursor", .{});
			return;
		};
		try self.screen.copy(text);
		self.say("{d} byte(s) copied", .{text.len});
	}

	/// The row under the cursor, as tab separated text, which is what a
	/// spreadsheet and every editor understand.
	pub fn copyRow(self: *App) !void {
		if (self.cursor_row >= self.rows.items.len) {
			self.complain("there is no row under the cursor", .{});
			return;
		}
		var out: std.ArrayListUnmanaged(u8) = .empty;
		defer out.deinit(self.allocator);
		for (self.rows.items[self.cursor_row].cells, 0..) |cell, i| {
			if (self.isHidden(i)) {
				continue;
			}
			if (out.items.len != 0) {
				try out.append(self.allocator, '\t');
			}
			try out.appendSlice(self.allocator, cell.text);
		}
		try self.screen.copy(out.items);
		self.say("the row is in the clipboard", .{});
	}

	/// The whole page, header included, as CSV.
	pub fn copyPage(self: *App) !void {
		var out: std.ArrayListUnmanaged(u8) = .empty;
		defer out.deinit(self.allocator);
		var written: usize = 0;
		for (self.cols.items, 0..) |name, i| {
			if (self.isHidden(i)) {
				continue;
			}
			if (written != 0) {
				try out.append(self.allocator, ',');
			}
			try csv.writeField(&out, self.allocator, name, ',');
			written += 1;
		}
		try out.append(self.allocator, '\n');
		for (self.rows.items) |row| {
			written = 0;
			for (row.cells, 0..) |cell, i| {
				if (self.isHidden(i)) {
					continue;
				}
				if (written != 0) {
					try out.append(self.allocator, ',');
				}
				try csv.writeField(&out, self.allocator, cell.text, ',');
				written += 1;
			}
			try out.append(self.allocator, '\n');
		}
		try self.screen.copy(out.items);
		self.say("{d} row(s) copied as CSV", .{self.rows.items.len});
	}

	/// The last statement that was run, so a query built in the app can be
	/// pasted into a migration.
	pub fn copyLastSql(self: *App) !void {
		if (self.history.items.len == 0) {
			self.complain("nothing has been run yet", .{});
			return;
		}
		const sql = self.history.items[self.history.items.len - 1];
		try self.screen.copy(sql);
		self.say("the last statement is in the clipboard", .{});
	}

	/// Apply an edited cell. The literal word NULL clears the cell.
	pub fn saveCell(self: *App, text: []const u8) !void {
		const table = self.currentTable() orelse {
			self.complain("a query result cannot be edited - open the table itself", .{});
			return;
		};
		if (self.noRowHere()) {
			return;
		}
		const key = self.rows.items[self.cursor_row].key orelse return;
		const column = self.cols.items[self.cursor_col];
		try self.change(.{
			.kind = .update,
			.table = table,
			.cells = &.{.{
				.column = column,
				.value = if (std.mem.eql(u8, text, "NULL")) null else text,
			}},
			.where = key,
		}) orelse return;
		try self.reload();
		self.say("{s} updated", .{column});
	}

	/// What addresses one row: each key column and the value this row has in it.
	///
	/// A NULL is `IS NULL` rather than `= NULL`, which matches nothing. The first
	/// key column takes `hidden` as its name when there is one - the engine's own
	/// expression for a row it can address without a real key, which is a column as
	/// far as a condition is concerned: SQLite answers to "rowid" just as it answers
	/// to a column of its own.
	pub fn identityOf(
		a: std.mem.Allocator,
		keys: []const Position,
		cells: []const Cell,
		hidden: []const u8,
	) ![]const database.ask.Filter {
		var conditions: std.ArrayListUnmanaged(database.ask.Filter) = .empty;
		for (keys, 0..) |key, n| {
			const column = if (n == 0 and hidden.len != 0) hidden else key.name;
			if (key.at >= cells.len) {
				continue;
			}
			const cell = cells[key.at];
			try conditions.append(a, if (cell.kind == .nul)
				.{ .column = column, .op = .is_null }
			else
				.{ .column = column, .value = cell.text });
		}
		return conditions.items;
	}

	/// A copy of an identity that outlives the grid it came from: a form holds one
	/// while the rows underneath are reloaded.
	fn copyFilters(a: std.mem.Allocator, filters: []const database.ask.Filter) ![]const database.ask.Filter {
		const out = try a.alloc(database.ask.Filter, filters.len);
		for (filters, out) |filter, *copy| {
			copy.* = .{
				.column = try a.dupe(u8, filter.column),
				.op = filter.op,
				.value = try a.dupe(u8, filter.value),
				.as_text = filter.as_text,
			};
		}
		return out;
	}

	/// Make one change and remember what it took, so ctrl+p in the editor brings
	/// it back - as SQL where there is SQL, and as the engine's own command
	/// otherwise. Null when the engine refused, with the reason already on screen.
	fn change(self: *App, request: database.ask.Change) !?void {
		self.conn.apply(request) catch {
			self.complain("{s}", .{self.conn.message()});
			return null;
		};
		if (self.conn.wording(self.allocator, .{ .change = request })) |words| {
			self.history.append(self.allocator, words) catch self.allocator.free(words);
		} else |_| {}
	}

	pub fn deleteRow(self: *App) !void {
		const table = self.currentTable() orelse return;
		if (self.noRowHere()) {
			return;
		}
		const key = self.rows.items[self.cursor_row].key orelse return;
		try self.change(.{ .kind = .delete, .table = table, .where = key }) orelse return;
		try self.loadObjects();
		try self.reload();
		self.say("row deleted", .{});
	}

	/// Point the app at another database, a file or a server.
	fn reopen(self: *App, target: []const u8) !void {
		if (target.len == 0) {
			return;
		}
		var report: std.ArrayListUnmanaged(u8) = .empty;
		defer report.deinit(self.allocator);
		const opened = database.Db.open(self.allocator, target, &report) catch {
			self.complain("{s}", .{if (report.items.len != 0) report.items else "cannot open it"});
			return;
		};
		self.conn.close();
		self.conn = opened;
		self.allocator.free(self.owned_path);
		// Without the password: this is what gets shown, and what the open form
		// starts from.
		var scratch = std.heap.ArenaAllocator.init(self.allocator);
		defer scratch.deinit();
		self.owned_path = try self.allocator.dupe(u8, try conns.withoutPassword(scratch.allocator(), target));
		self.path = self.owned_path;
		try self.setTable(null);
		self.schema.clearRetainingCapacity();
		try self.firstSchema();
		self.clearConditions();
		self.where_text.clearRetainingCapacity();
		self.hidden.clearRetainingCapacity();
		self.marked.clearRetainingCapacity();
		self.selected = 0;
		self.page = 0;
		try self.loadObjects();
		if (self.current()) |object| {
			try self.openTable(object.name);
		}
		self.say("{s} opened", .{self.conn.describe()});
	}

	/// Start in the schema the engine puts first, if it has schemas at all.
	pub fn firstSchema(self: *App) !void {
		var arena = std.heap.ArenaAllocator.init(self.allocator);
		defer arena.deinit();
		const list = self.conn.schemas(arena.allocator()) catch return;
		if (list.len != 0) {
			self.schema.clearRetainingCapacity();
			try self.schema.appendSlice(self.allocator, list[0]);
		}
	}

	/// Switch to another schema.
	pub fn useSchema(self: *App, name: []const u8) !void {
		self.schema.clearRetainingCapacity();
		try self.schema.appendSlice(self.allocator, name);
		try self.setTable(null);
		self.selected = 0;
		self.clearConditions();
		self.where_text.clearRetainingCapacity();
		try self.loadObjects();
		if (self.current()) |object| {
			try self.openTable(object.name);
		}
		self.say("schema {s}", .{name});
	}

	/// An INSERT skeleton for the current table, to be edited in the SQL prompt.
	pub fn insertTemplate(self: *App, allocator: std.mem.Allocator) ![]const u8 {
		const table = self.currentTable() orelse return "";
		var arena = std.heap.ArenaAllocator.init(self.allocator);
		defer arena.deinit();
		const names = try self.columnsOf(arena.allocator(), table.name);
		var out: std.ArrayListUnmanaged(u8) = .empty;
		try out.appendSlice(allocator, "INSERT INTO ");
		try database.quoteName(&out, allocator, table);
		try out.appendSlice(allocator, " (");
		for (names, 0..) |name, i| {
			if (i != 0) {
				try out.appendSlice(allocator, ", ");
			}
			try database.quoteName(&out, allocator, name);
		}
		try out.appendSlice(allocator, ") VALUES (");
		for (names, 0..) |_, i| {
			if (i != 0) {
				try out.appendSlice(allocator, ", ");
			}
			try out.appendSlice(allocator, "NULL");
		}
		try out.append(allocator, ')');
		return out.items;
	}

	// ------------------------------------------------------- schema readers

	/// Column definitions as the DDL generator wants them, including the
	/// single-column UNIQUE constraints, which only exist as indexes.
	fn tableNames(self: *App, arena: std.mem.Allocator, last: []const u8) ![]const []const u8 {
		var list: std.ArrayListUnmanaged([]const u8) = .empty;
		for (self.objects.items) |object| {
			if (std.mem.eql(u8, object.kind, "table") and !std.mem.eql(u8, object.name, last)) {
				try list.append(arena, try arena.dupe(u8, object.name));
			}
		}
		if (last.len != 0) {
			try list.append(arena, try arena.dupe(u8, last));
		}
		if (list.items.len == 0) {
			try list.append(arena, "");
		}
		return list.items;
	}

	// --------------------------------------------------------------- forms

	pub fn closeForm(self: *App) void {
		if (self.form) |*open| {
			open.deinit();
		}
		self.form = null;
	}

	fn newForm(self: *App, purpose: Form.Purpose, title: []const u8, hint: []const u8) !*Form.Form {
		self.closeForm();
		self.form = Form.Form.init(self.allocator, purpose, title);
		self.form.?.hint = hint;
		return &self.form.?;
	}

	/// Insert, edit or clone a row of the current table.
	pub fn openRowForm(self: *App, mode: enum { insert, edit, clone }) !void {
		const table = self.currentTable() orelse {
			self.complain("open a table first", .{});
			return;
		};
		if (mode != .insert and self.noRowHere()) {
			return;
		}
		const form = try self.newForm(.row, switch (mode) {
			.insert => "new row",
			.edit => "edit row",
			.clone => "clone row",
		}, "ctrl+s saves, esc cancels, an empty value with a DEFAULT is left to the engine");
		form.table = try form.arena.allocator().dupe(u8, table.name);
		if (mode == .edit) {
			form.key = if (self.rows.items[self.cursor_row].key) |key|
				try copyFilters(form.arena.allocator(), key)
			else
				null;
		}
		const columns = try self.columnDefs(form.arena.allocator(), table.name);
		for (columns) |column| {
			var initial: []const u8 = "";
			var is_null = mode == .insert and column.dflt == null and !column.notnull;
			if (mode != .insert) {
				for (self.cols.items, 0..) |name, i| {
					if (!std.mem.eql(u8, name, column.name)) {
						continue;
					}
					const cell = self.rows.items[self.cursor_row].cells[i];
					is_null = cell.kind == .nul;
					initial = if (is_null) "" else cell.text;
				}
			}
			var label: std.ArrayListUnmanaged(u8) = .empty;
			try label.appendSlice(form.arena.allocator(), column.name);
			try label.appendSlice(form.arena.allocator(), " ");
			try label.appendSlice(form.arena.allocator(), column.type);
			if (column.notnull) {
				try label.appendSlice(form.arena.allocator(), " NOT NULL");
			}
			if (column.dflt) |value| {
				try label.print(form.arena.allocator(), " = {s}", .{value});
			}
			try form.text(label.items, initial, 46);
			try form.wasNamed(column.name);
			try form.toggle("null", is_null);
			form.sameLine();
			try form.wasNamed(column.name);
		}
		if (mode == .clone) {
			// A cloned row cannot keep the key of the row it came from.
			for (columns, 0..) |column, i| {
				if (column.pk) {
					if (form.field(i * 2)) |f| {
						f.text.clearRetainingCapacity();
					}
				}
			}
		}
	}

	/// Create or alter a table: one repeatable row per column.
	pub fn openTableForm(self: *App, alter: bool) !void {
		if (alter and !self.hasTable()) {
			self.complain("open a table first", .{});
			return;
		}
		const table_label = if (alter) (self.table_name orelse "") else "";
		const form = try self.newForm(
			if (alter) .alter_table else .create_table,
			if (alter) "alter table" else "create table",
			"ctrl+n adds a column, ctrl+k removes one, ctrl+s saves",
		);
		form.row_size = 5;
		form.table = try form.arena.allocator().dupe(u8, table_label);
		try form.text("table name", table_label, 30);
		// Only an engine that has to rebuild loses anything by altering; MySQL and
		// PostgreSQL change the table in place.
		if (alter and self.conn.caps().rebuild_to_alter) {
			try form.note("altering rebuilds the table; CHECK constraints and generated columns are lost");
		}
		const columns = if (alter) try self.columnDefs(form.arena.allocator(), table_label) else &[_]database.Column{};
		if (columns.len == 0) {
			// The engine's first type, which is the integer-ish one in every list.
			const first = self.conn.ddl().types();
			try self.addColumnRow(form, 1, .{
				.name = "id",
				.type = if (first.len != 0) first[0] else "INTEGER",
				.pk = true,
			});
			try self.addColumnRow(form, 2, .{ .name = "", .type = "TEXT" });
		} else {
			for (columns, 0..) |column, i| {
				try self.addColumnRow(form, i + 1, column);
			}
		}
	}

	fn addColumnRow(self: *App, form: *Form.Form, group: usize, column: database.Column) !void {
		try form.text("column", column.name, 16);
		form.inGroup(group);
		try form.wasNamed(column.original);
		// The engine's own types, not a list that happens to suit SQLite: MySQL
		// offers `varchar(255)`, PostgreSQL `timestamptz`.
		const types = self.conn.ddl().types();
		try form.choice("type", types, Form.indexOf(types, column.type));
		form.sameLine();
		form.inGroup(group);
		try form.toggle("not null", column.notnull);
		form.sameLine();
		form.inGroup(group);
		try form.text("default", column.dflt orelse "", 10);
		form.sameLine();
		form.inGroup(group);
		try form.toggle("pk", column.pk);
		form.sameLine();
		form.inGroup(group);
	}

	/// Append another column row to an open create/alter form.
	pub fn addFormRow(self: *App) !void {
		const form = &(self.form orelse return);
		if (form.purpose != .create_table and form.purpose != .alter_table) {
			return;
		}
		var highest: usize = 0;
		for (form.fields.items) |field| {
			highest = @max(highest, field.group);
		}
		try self.addColumnRow(form, highest + 1, .{ .name = "", .type = "TEXT" });
		form.cursor = form.fields.items.len - 5;
	}

	/// Drop the column row the cursor is in.
	pub fn removeFormRow(self: *App) !void {
		const form = &(self.form orelse return);
		const row = form.currentRow() orelse return;
		var remaining: usize = 0;
		for (form.fields.items) |field| {
			if (field.group != 0) {
				remaining += 1;
			}
		}
		if (remaining <= form.row_size) {
			self.complain("a table needs at least one column", .{});
			return;
		}
		var count: usize = 0;
		while (count < form.row_size and row.start < form.fields.items.len) : (count += 1) {
			_ = form.fields.orderedRemove(row.start);
		}
		form.cursor = @min(form.cursor, form.fields.items.len - 1);
	}

	pub fn openIndexForm(self: *App) !void {
		const table = self.currentTable() orelse {
			self.complain("open a table first", .{});
			return;
		};
		const form = try self.newForm(.index, "create index", "columns are comma separated; ctrl+s creates");
		form.table = try form.arena.allocator().dupe(u8, table.name);
		var suggested: std.ArrayListUnmanaged(u8) = .empty;
		try suggested.print(form.arena.allocator(), "{s}_idx", .{table.name});
		try form.text("index name", suggested.items, 30);
		try form.text("columns", if (self.cols.items.len > 0) self.cols.items[self.cursor_col] else "", 40);
		try form.toggle("unique", false);
		try form.text("partial WHERE", "", 40);
	}

	pub fn openForeignKeyForm(self: *App) !void {
		const table = self.currentTable() orelse {
			self.complain("open a table first", .{});
			return;
		};
		const form = try self.newForm(.foreign_key, "add foreign key", "the table is rebuilt; ctrl+s applies");
		form.table = try form.arena.allocator().dupe(u8, table.name);
		const targets = try self.tableNames(form.arena.allocator(), table.name);
		try form.text("column", if (self.cols.items.len > 0) self.cols.items[self.cursor_col] else "", 24);
		try form.choice("references", targets, 0);
		try form.text("target column", "", 24);
		try form.choice("on update", &Form.ACTIONS, 0);
		try form.choice("on delete", &Form.ACTIONS, 0);
	}

	pub fn openViewForm(self: *App) !void {
		const form = try self.newForm(.view, "create view", "ctrl+s creates the view");
		try form.text("view name", "", 30);
		try form.text("select", "SELECT ", 60);
	}

	pub fn openTriggerForm(self: *App) !void {
		const table_label = self.table_name orelse "";
		const form = try self.newForm(.trigger, "create trigger", "ctrl+s creates the trigger");
		form.table = try form.arena.allocator().dupe(u8, table_label);
		try form.text("trigger name", "", 30);
		try form.choice("when", &[_][]const u8{ "BEFORE", "AFTER", "INSTEAD OF" }, 1);
		try form.choice("event", &[_][]const u8{ "INSERT", "UPDATE", "DELETE" }, 0);
		try form.text("on table", table_label, 30);
		try form.text("when condition", "", 40);
		try form.text("body", "", 60);
	}

	pub fn openRenameForm(self: *App) !void {
		const table = self.currentTable() orelse {
			self.complain("open a table first", .{});
			return;
		};
		const form = try self.newForm(.rename_table, "rename table", "ctrl+s renames");
		form.table = try form.arena.allocator().dupe(u8, table.name);
		try form.text("new name", table.name, 30);
	}

	pub fn openCopyForm(self: *App) !void {
		const table = self.currentTable() orelse {
			self.complain("open a table first", .{});
			return;
		};
		const form = try self.newForm(.copy_table, "copy table", "ctrl+s copies");
		form.table = try form.arena.allocator().dupe(u8, table.name);
		var suggested: std.ArrayListUnmanaged(u8) = .empty;
		try suggested.print(form.arena.allocator(), "{s}_copy", .{table.name});
		try form.text("new name", suggested.items, 30);
		try form.toggle("with the rows", true);
	}

	pub fn openSearchForm(self: *App) !void {
		const form = try self.newForm(.search_all, "search every table", "ctrl+s searches all text columns");
		try form.text("contains", "", 40);
	}

	pub fn openFilterForm(self: *App) !void {
		const table = self.currentTable() orelse {
			self.complain("open a table first", .{});
			return;
		};
		const form = try self.newForm(.filter, "filter rows", "empty values are ignored; ctrl+s applies");
		form.table = try form.arena.allocator().dupe(u8, table.name);
		const columns = try self.columnDefs(form.arena.allocator(), table.name);
		var names: std.ArrayListUnmanaged([]const u8) = .empty;
		for (columns) |column| {
			try names.append(form.arena.allocator(), column.name);
		}
		if (names.items.len == 0) {
			try names.append(form.arena.allocator(), "");
		}
		var i: usize = 0;
		while (i < 3) : (i += 1) {
			try form.choice("column", names.items, 0);
			try form.choice("op", &OPERATORS, 0);
			form.sameLine();
			try form.text("value", "", 22);
			form.sameLine();
		}
		try form.text("raw WHERE", self.where_text.items, 50);
	}

	pub fn openColumnForm(self: *App) !void {
		if (self.cols.items.len == 0) {
			return;
		}
		const form = try self.newForm(.columns, "visible columns", "space toggles, ctrl+s applies");
		for (self.cols.items, 0..) |name, i| {
			try form.toggle(name, !self.isHidden(i));
		}
	}

	pub fn openExportForm(self: *App) !void {
		const form = try self.newForm(.export_data, "export", "ctrl+s writes the file");
		try form.choice("what", &[_][]const u8{ "whole database", "this table", "the grid" }, if (!self.hasTable()) 2 else 1);
		try form.choice("format", &[_][]const u8{ "sql", "csv", "tsv" }, 0);
		try form.toggle("structure", true);
		try form.toggle("data", true);
		try form.text("file", "dump.sql", 40);
	}

	pub fn openImportForm(self: *App) !void {
		const form = try self.newForm(.import_data, "import", "ctrl+s runs the import");
		try form.choice("kind", &[_][]const u8{ "sql script", "csv into a table" }, 0);
		try form.text("file", "", 40);
		try form.text("into table", self.table_name orelse "", 30);
		try form.toggle("first line is a header", true);
		try form.choice("separator", &[_][]const u8{ ",", ";", "tab" }, 0);
	}

	/// Pick a schema on an engine that has them.
	pub fn openSchemaForm(self: *App) !void {
		if (!self.conn.caps().schemas) {
			self.complain("{s} has no schemas", .{self.conn.caps().label});
			return;
		}
		const form = try self.newForm(.schema, "schema", "ctrl+s switches");
		const list = try self.conn.schemas(form.arena.allocator());
		if (list.len == 0) {
			self.complain("no schema to switch to", .{});
			return;
		}
		var at: usize = 0;
		for (list, 0..) |name, i| {
			if (std.mem.eql(u8, name, self.schema.items)) {
				at = i;
			}
		}
		try form.choice("use", list, at);
	}

	pub fn openOpenForm(self: *App) !void {
		const form = try self.newForm(.open_file, "open a database", "ctrl+s opens the file");
		try form.text("path", self.path, 60);
	}

	// ------------------------------------------------------- form submission

	/// Turn the open form into SQL and run it. Everything goes through
	/// `runBatch`, so a failure is reported the same way a typed query is.
	pub fn submitForm(self: *App) !void {
		const form = &(self.form orelse return);
		var arena = std.heap.ArenaAllocator.init(self.allocator);
		defer arena.deinit();
		const a = arena.allocator();
		var sql: std.ArrayListUnmanaged(u8) = .empty;

		if (form.purpose == .row) {
			const request = try self.rowChange(a, form);
			const inserted = request.kind == .insert;
			self.closeForm();
			try self.change(request) orelse return;
			try self.loadObjects();
			try self.reload();
			if (inserted) {
				self.say("row inserted", .{});
			} else {
				self.say("row updated", .{});
			}
			return;
		}

		switch (form.purpose) {
			// Handled above, before the form was closed.
			.row => unreachable,
			.create_table, .alter_table => try self.buildTable(&sql, a, form),
			.index => {
				var columns: std.ArrayListUnmanaged([]const u8) = .empty;
				var parts = std.mem.tokenizeAny(u8, form.valueOf(1), ",");
				while (parts.next()) |part| {
					try columns.append(a, std.mem.trim(u8, part, " \t"));
				}
				if (columns.items.len == 0) {
					self.complain("name at least one column", .{});
					return;
				}
				try self.conn.ddl().createIndex(&sql, a, .{ .schema = self.schema.items, .name = form.table }, form.valueOf(0), columns.items, form.isOn(2), form.valueOf(3));
			},
			.foreign_key => {
				const columns = try self.columnDefs(a, form.table);
				var known = false;
				for (columns) |column| {
					known = known or std.mem.eql(u8, column.name, form.valueOf(0));
				}
				if (!known) {
					self.complain("{s} has no column {s}", .{ form.table, form.valueOf(0) });
					return;
				}
				var keys = std.ArrayListUnmanaged(database.ForeignKey).empty;
				for (try self.foreignKeyDefs(a, form.table)) |existing| {
					try keys.append(a, existing);
				}
				try keys.append(a, .{
					.column = form.valueOf(0),
					.target_table = form.valueOf(1),
					.target_column = form.valueOf(2),
					.on_update = form.valueOf(3),
					.on_delete = form.valueOf(4),
				});
				const target = database.Table{ .schema = self.schema.items, .name = form.table };
				const context = try self.conn.alterContext(a, target, columns);
				try self.conn.ddl().addForeignKey(&sql, a, target, .{
					.column = form.valueOf(0),
					.target_table = form.valueOf(1),
					.target_column = form.valueOf(2),
					.on_update = form.valueOf(3),
					.on_delete = form.valueOf(4),
				}, context);
			},
			.view => try self.conn.ddl().createView(&sql, a, .{ .schema = self.schema.items, .name = form.valueOf(0) }, form.valueOf(1)),
			.trigger => {
				try sql.appendSlice(a, "CREATE TRIGGER ");
				try database.quoteName(&sql, a, form.valueOf(0));
				try sql.print(a, " {s} {s} ON ", .{ form.valueOf(1), form.valueOf(2) });
				try database.quoteName(&sql, a, form.valueOf(3));
				if (form.valueOf(4).len != 0) {
					try sql.print(a, " WHEN {s}", .{form.valueOf(4)});
				}
				try sql.print(a, " BEGIN {s}; END", .{form.valueOf(5)});
			},
			.rename_table => try self.conn.ddl().renameTable(&sql, a, .{ .schema = self.schema.items, .name = form.table }, form.valueOf(0)),
			.copy_table => try self.conn.ddl().copyTable(&sql, a, .{ .schema = self.schema.items, .name = form.table }, form.valueOf(0), form.isOn(1)),
			.filter => {
				try self.applyFilter(form);
				self.closeForm();
				return;
			},
			.columns => {
				self.hidden.clearRetainingCapacity();
				for (form.fields.items, 0..) |field, i| {
					if (!field.on) {
						try self.hidden.append(self.allocator, i);
					}
				}
				self.closeForm();
				self.say("{d} column(s) hidden", .{self.hidden.items.len});
				return;
			},
			.search_all => {
				const needle = form.valueOf(0);
				if (needle.len == 0) {
					self.complain("nothing to search for", .{});
					return;
				}
				try self.searchEverything(needle);
				self.closeForm();
				return;
			},
			.export_data => {
				try self.runExport(form);
				self.closeForm();
				return;
			},
			.import_data => {
				try self.runImport(form);
				self.closeForm();
				return;
			},
			.open_file => {
				const target = try self.allocator.dupe(u8, form.valueOf(0));
				defer self.allocator.free(target);
				self.closeForm();
				try self.reopen(target);
				return;
			},
			.connection => {
				const name = try self.allocator.dupe(u8, form.valueNamed("name"));
				defer self.allocator.free(name);
				// The fields are that engine's; the target is what they come to.
				const shape = self.shapeOf(form);
				const target = conns.compose(self.formArena(), shape) catch "";
				const keeps = std.meta.stringToEnum(conns.Keeps, form.valueNamed("keep the password")) orelse .ask;
				const typed = try self.allocator.dupe(u8, form.valueNamed("password"));
				defer self.allocator.free(typed);
				const editing = self.editing_saved;
				self.editing_saved = null;
				self.closeForm();
				if (target.len == 0) {
					self.complain("a connection needs something to point at", .{});
					return;
				}
				if (editing) |at| {
					if (at < self.saved.items.items.len) {
						// A connection that stops using the keychain, or moves to
						// another target, leaves nothing behind in it.
						const was = self.saved.items.items[at];
						if (was.keeps == .keychain and (keeps != .keychain or !std.mem.eql(u8, was.target, target))) {
							keychain.remove(was.target);
						}
						_ = self.saved.items.orderedRemove(at);
					}
				}
				var scratch = std.heap.ArenaAllocator.init(self.allocator);
				defer scratch.deinit();
				const clean = try conns.withoutPassword(scratch.allocator(), target);
				try self.saved.add(
					if (name.len != 0) name else try conns.suggestName(scratch.allocator(), clean),
					clean,
					keeps,
					// The file keeps the password itself; the keychain keeps its own,
					// and an empty one here means "keep the one I am about to be
					// asked for".
					if (keeps == .file) typed else "",
				);
				if (keeps == .keychain and typed.len != 0) {
					keychain.store(clean, typed) catch {
						self.complain("the keychain would not take the password", .{});
					};
				}
				conns.save(&self.saved, self.saved_path.items) catch {};
				self.saved_at = 0;
				// Connect with whatever was typed here, whether or not it is kept.
				const attempt = if (typed.len != 0)
					try conns.withPassword(scratch.allocator(), clean, typed)
				else
					target;
				try self.connect(attempt, false);
				return;
			},
			.schema => {
				const name = try self.allocator.dupe(u8, form.valueOf(0));
				defer self.allocator.free(name);
				self.closeForm();
				try self.useSchema(name);
				return;
			},
		}

		if (sql.items.len == 0) {
			self.closeForm();
			return;
		}
		const script = try self.allocator.dupe(u8, sql.items);
		defer self.allocator.free(script);
		const purpose = form.purpose;
		const table = try self.allocator.dupe(u8, form.table);
		defer self.allocator.free(table);
		const renamed = if (purpose == .rename_table) try self.allocator.dupe(u8, form.valueOf(0)) else null;
		defer if (renamed) |value| self.allocator.free(value);
		self.closeForm();

		try self.runBatchStopping(script, true);
		try self.loadObjects();
		if (self.reports.items.len != 0 and self.reports.items[self.reports.items.len - 1].failure != null) {
			// The rollback in runBatch has already undone the half done work.
			self.reload() catch {};
			return;
		}
		switch (purpose) {
			.rename_table => if (renamed) |value| try self.openTable(value),
			.create_table, .copy_table, .view => self.say("created", .{}),
			.alter_table, .foreign_key, .index => try self.reload(),
			else => {},
		}
	}

	/// The row form as a change: which columns it sets, to what, and which row it
	/// is about. A number goes in as it stands so the engine sees a number, and a
	/// value left empty where the column has a default is left out altogether -
	/// which is how a new row gets its own id.
	///
	/// Everything is copied into `a`, because the form is closed before the change
	/// is made and its own memory goes with it.
	fn rowChange(self: *App, a: std.mem.Allocator, form: *Form.Form) !database.ask.Change {
		const columns = try self.columnDefs(a, form.table);
		var cells: std.ArrayListUnmanaged(database.ask.Cell) = .empty;
		for (columns, 0..) |column, i| {
			const value_field = form.field(i * 2) orelse continue;
			const null_field = form.field(i * 2 + 1) orelse continue;
			const text = value_field.text.items;
			if (null_field.on) {
				try cells.append(a, .{ .column = column.name, .value = null });
				continue;
			}
			if (text.len == 0 and form.key == null and
				(column.dflt != null or (column.pk and std.ascii.indexOfIgnoreCase(column.type, "INT") != null)))
			{
				continue; // leave it to the engine: a default, or the next id
			}
			// A number is written as it stands rather than quoted, so a column with
			// a numeric type is given a number - unless what was typed is not one,
			// and then it is quoted and the engine may complain about it.
			const numeric = isNumeric(column.type) and text.len != 0 and looksNumeric(text);
			try cells.append(a, .{
				.column = try a.dupe(u8, column.name),
				.value = try a.dupe(u8, text),
				.raw = numeric,
			});
		}
		return .{
			.kind = if (form.key == null) .insert else .update,
			.table = .{
				.schema = try a.dupe(u8, self.schema.items),
				.name = try a.dupe(u8, form.table),
			},
			.cells = cells.items,
			.where = if (form.key) |key| try copyFilters(a, key) else &.{},
		};
	}

	/// CREATE TABLE, or a rebuild when altering.
	fn buildTable(self: *App, sql: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, form: *Form.Form) !void {
		const name = form.valueOf(0);
		if (name.len == 0) {
			self.complain("the table needs a name", .{});
			return;
		}
		var columns: std.ArrayListUnmanaged(database.Column) = .empty;
		var i: usize = 0;
		while (i < form.fields.items.len) : (i += 1) {
			const field = form.fields.items[i];
			if (field.group == 0 or !std.mem.eql(u8, field.label, "column")) {
				continue;
			}
			if (field.text.items.len == 0) {
				continue; // an empty row is simply not a column
			}
			try columns.append(a, .{
				.name = try a.dupe(u8, field.text.items),
				.type = form.valueOf(i + 1),
				.notnull = form.isOn(i + 2),
				.dflt = form.valueOf(i + 3),
				.pk = form.isOn(i + 4),
				.original = field.original,
			});
		}
		if (columns.items.len == 0) {
			self.complain("a table needs at least one column", .{});
			return;
		}
		if (form.purpose == .create_table) {
			try self.conn.ddl().createTable(sql, a, .{ .schema = self.schema.items, .name = name }, columns.items, &.{});
			return;
		}
		// Whatever this engine has to preserve across an alter - on SQLite the
		// foreign keys and the indexes, with the renames applied.
		const target = database.Table{ .schema = self.schema.items, .name = form.table };
		const context = try self.conn.alterContext(a, target, columns.items);
		try self.conn.ddl().alterTable(sql, a, target, name, columns.items, context);
	}

	fn applyFilter(self: *App, form: *Form.Form) !void {
		self.clearConditions();
		self.where_text.clearRetainingCapacity();
		var i: usize = 0;
		while (i < 9) : (i += 3) {
			const column = form.valueOf(i);
			const operator = form.valueOf(i + 1);
			const value = form.valueOf(i + 2);
			const op = operatorOf(operator);
			if (column.len == 0 or (value.len == 0 and op.takesValue())) {
				continue;
			}
			// `contains` is LIKE with the wildcards put in for the user.
			const wrapped = std.mem.eql(u8, operator, "contains");
			const text = if (wrapped)
				try std.fmt.allocPrint(self.allocator, "%{s}%", .{value})
			else
				try self.allocator.dupe(u8, value);
			errdefer self.allocator.free(text);
			try self.conditions.append(self.allocator, .{
				.column = try self.allocator.dupe(u8, column),
				.op = op,
				.value = text,
			});
		}
		const raw = form.valueOf(9);
		if (raw.len != 0) {
			try self.where_text.appendSlice(self.allocator, raw);
		}
		self.page = 0;
		self.cursor_row = 0;
		self.reload() catch |err| {
			self.complain("{s}", .{@errorName(err)});
			return;
		};
		if (self.grid_failed) {
			return; // the reason is already on screen
		}
		if (!self.isFiltered()) {
			self.say("filter cleared", .{});
		} else if (self.counted) {
			self.say("{d} row(s) match", .{self.total});
		} else {
			self.say("{d} row(s) on this page; {s} cannot count the rest without reading it", .{
				self.rows.items.len,
				self.conn.caps().label,
			});
		}
	}

	/// Look for a string in every text-ish column of every table.
	fn searchEverything(self: *App, needle: []const u8) !void {
		// One SELECT per column of every table, unioned - which is SQL, and there is
		// no honest way to put it to an engine that has none. Filtering one table
		// works there, and says so.
		if (!self.conn.caps().speaks_sql) {
			self.complain("searching every table needs SQL - filter one table with W instead", .{});
			return;
		}
		var arena = std.heap.ArenaAllocator.init(self.allocator);
		defer arena.deinit();
		const a = arena.allocator();
		var sql: std.ArrayListUnmanaged(u8) = .empty;
		var pattern: std.ArrayListUnmanaged(u8) = .empty;
		try pattern.append(a, '%');
		try pattern.appendSlice(a, needle);
		try pattern.append(a, '%');

		var parts: usize = 0;
		for (self.objects.items) |object| {
			if (!std.mem.eql(u8, object.kind, "table")) {
				continue;
			}
			const columns = try self.columnDefs(a, object.name);
			for (columns) |column| {
				if (std.ascii.indexOfIgnoreCase(column.type, "BLOB") != null) {
					continue;
				}
				if (parts != 0) {
					try sql.appendSlice(a, "\nUNION ALL ");
				}
				parts += 1;
				try sql.appendSlice(a, "SELECT ");
				try database.quote(&sql, a, object.name);
				try sql.appendSlice(a, " AS \"table\", ");
				try database.quote(&sql, a, column.name);
				try sql.appendSlice(a, " AS \"column\", CAST(");
				try database.quoteName(&sql, a, column.name);
				try sql.appendSlice(a, " AS ");
				try sql.appendSlice(a, self.conn.caps().text_cast);
				try sql.appendSlice(a, ") AS \"value\" FROM ");
				try database.quoteName(&sql, a, object.name);
				try sql.appendSlice(a, " WHERE CAST(");
				try database.quoteName(&sql, a, column.name);
				try sql.appendSlice(a, " AS ");
				try sql.appendSlice(a, self.conn.caps().text_cast);
				try sql.appendSlice(a, ") LIKE ");
				try database.quote(&sql, a, pattern.items);
			}
		}
		if (parts == 0) {
			self.complain("nothing to search in", .{});
			return;
		}
		try sql.print(a, "\nLIMIT {d}", .{self.limit});
		try self.setTable(null);
		self.clearConditions();
		self.where_text.clearRetainingCapacity();
		self.hidden.clearRetainingCapacity();
		self.page = 0;
		self.cursor_row = 0;
		self.cursor_col = 0;
		self.load(sql.items, null, false) catch {
			self.complain("{s}", .{self.conn.message()});
			return;
		};
		self.total = @intCast(self.rows.items.len);
		self.setTitle("search: {s}", .{needle});
		self.view = .grid;
		self.focus = .main;
		self.say("{d} hit(s) in {d} column(s)", .{ self.rows.items.len, parts });
	}

	fn runExport(self: *App, form: *Form.Form) !void {
		const what = form.valueOf(0);
		const format = form.valueOf(1);
		const path = form.valueOf(4);
		if (path.len == 0) {
			self.complain("give the export a file name", .{});
			return;
		}
		if (std.mem.eql(u8, format, "sql")) {
			if (std.mem.eql(u8, what, "the grid")) {
				self.complain("a grid can only go out as csv or tsv", .{});
				return;
			}
			const only = if (std.mem.eql(u8, what, "this table")) self.table_name else null;
			try self.dumpTo(path, only, form.isOn(2), form.isOn(3));
			return;
		}
		const separator: u8 = if (std.mem.eql(u8, format, "tsv")) '\t' else ',';
		if (std.mem.eql(u8, what, "the grid")) {
			try self.writeGrid(path, separator);
			return;
		}
		const table = if (std.mem.eql(u8, what, "this table")) (self.table_name orelse "") else "";
		if (table.len == 0) {
			self.complain("csv exports one table at a time", .{});
			return;
		}
		try self.writeQuery(path, table, separator);
	}

	fn runImport(self: *App, form: *Form.Form) !void {
		const path = form.valueOf(1);
		if (path.len == 0) {
			self.complain("give the import a file name", .{});
			return;
		}
		var arena = std.heap.ArenaAllocator.init(self.allocator);
		defer arena.deinit();
		const body = csv.readFile(arena.allocator(), path) catch |err| {
			self.complain("cannot read {s}: {s}", .{ path, @errorName(err) });
			return;
		};
		if (std.mem.eql(u8, form.valueOf(0), "sql script")) {
			const script = try self.allocator.dupe(u8, body);
			defer self.allocator.free(script);
			self.closeForm();
			try self.runBatch(script);
			return;
		}
		const table = form.valueOf(2);
		if (table.len == 0) {
			self.complain("say which table to import into", .{});
			return;
		}
		const separator: u8 = switch (form.field(4).?.pick) {
			1 => ';',
			2 => '\t',
			else => ',',
		};
		try self.importCsv(arena.allocator(), table, body, separator, form.isOn(3));
	}

	fn importCsv(
		self: *App,
		a: std.mem.Allocator,
		wanted: []const u8,
		body: []const u8,
		separator: u8,
		header: bool,
	) !void {
		// The name lives in the form's memory, which is freed before the report.
		const table = database.Table{
			.schema = self.schema.items,
			.name = try a.dupe(u8, wanted),
		};
		const columns = try self.columnDefs(a, table.name);
		if (columns.len == 0) {
			self.complain("{s} does not exist", .{table.name});
			return;
		}
		// A file goes in one of two ways. An engine with SQL gets a script in one
		// transaction, which is what makes a half-finished import undo itself and what
		// puts every statement in the report. An engine without SQL gets one change
		// per row through the same path the row form uses - it used to get the script
		// too, and a script of INSERTs is not something Redis or Kafka can read: the
		// import said "2 rows imported" and wrote nothing at all.
		const scripted = self.conn.caps().speaks_sql;
		var names: std.ArrayListUnmanaged([]const u8) = .empty;
		var script: std.ArrayListUnmanaged(u8) = .empty;
		if (scripted) {
			try script.appendSlice(a, "BEGIN;\n");
		}
		var failed: usize = 0;

		var lines = std.mem.splitAny(u8, body, "\n");
		var pending: std.ArrayListUnmanaged(u8) = .empty;
		var first = true;
		var rows: usize = 0;
		while (lines.next()) |raw| {
			const line = std.mem.trimEnd(u8, raw, "\r");
			if (pending.items.len != 0) {
				try pending.append(a, '\n');
			}
			try pending.appendSlice(a, line);
			const fields = (try csv.splitLine(a, pending.items, separator)) orelse continue;
			pending = .empty;
			if (fields.len == 1 and fields[0].len == 0) {
				continue; // a blank line
			}
			if (first) {
				first = false;
				if (header) {
					for (fields) |field| {
						try names.append(a, std.mem.trim(u8, field, " \t"));
					}
					continue;
				}
				for (columns) |column| {
					try names.append(a, column.name);
				}
			}
			if (scripted) {
				var values: std.ArrayListUnmanaged([]const u8) = .empty;
				for (fields, 0..) |field, i| {
					if (i >= names.items.len) {
						break;
					}
					var literal: std.ArrayListUnmanaged(u8) = .empty;
					if (field.len == 0) {
						try literal.appendSlice(a, "NULL");
					} else {
						try database.quote(&literal, a, field);
					}
					try values.append(a, literal.items);
				}
				try self.conn.ddl().insertRow(&script, a, table, names.items[0..values.items.len], values.items);
				rows += 1;
				continue;
			}
			// The values as values: an empty field is NULL, everything else is what
			// the file said, without a layer of quoting for a language this engine
			// does not speak.
			var cells: std.ArrayListUnmanaged(database.ask.Cell) = .empty;
			for (fields, 0..) |field, i| {
				if (i >= names.items.len) {
					break;
				}
				try cells.append(a, .{
					.column = names.items[i],
					.value = if (field.len == 0) null else field,
				});
			}
			self.conn.apply(.{ .kind = .insert, .table = table, .cells = cells.items }) catch {
				failed += 1;
				continue;
			};
			rows += 1;
		}
		if (scripted) {
			try script.appendSlice(a, "COMMIT;\n");
		}
		if (rows == 0 and failed == 0) {
			self.complain("no rows found in the file", .{});
			return;
		}
		if (!scripted) {
			// Why the last row was refused, read before anything else asks the engine
			// a question: the reload below would clear it.
			const why = try a.dupe(u8, self.conn.message());
			self.closeForm();
			try self.loadObjects();
			try self.reload();
			if (failed != 0) {
				self.complain("{d} row(s) imported into {s}, {d} refused{s}{s}", .{
					rows, table.name, failed,
					if (why.len != 0) ": " else "",
					why,
				});
			} else {
				self.say("{d} row(s) imported into {s}", .{ rows, table.name });
			}
			return;
		}
		const owned = try self.allocator.dupe(u8, script.items);
		defer self.allocator.free(owned);
		self.closeForm();
		try self.runBatch(owned);
		try self.reload();
		self.say("{d} row(s) imported into {s}", .{ rows, table.name });
	}

};

// --------------------------------------------------------------- helpers

/// A value as owned text; an empty string for NULL.
fn textOf(arena: std.mem.Allocator, value: database.Value) ![]const u8 {
	return switch (value) {
		.null => "",
		.text, .blob => |bytes| try arena.dupe(u8, bytes),
		.int => |v| try std.fmt.allocPrint(arena, "{d}", .{v}),
		.float => |v| try std.fmt.allocPrint(arena, "{d}", .{v}),
	};
}


/// `numeric` comes from the column's type, so a value the engine hands over as
/// text - PostgreSQL's numeric, which must not lose precision - still lines up
/// on the right.
pub fn formatCell(arena: std.mem.Allocator, value: database.Value, numeric: bool) !Cell {
	return switch (value) {
		.null => .{ .text = "NULL", .kind = .nul },
		.int => |v| .{ .text = try std.fmt.allocPrint(arena, "{d}", .{v}), .kind = .int },
		.float => |v| .{ .text = try std.fmt.allocPrint(arena, "{d}", .{v}), .kind = .float },
		.blob => |b| .{ .text = try std.fmt.allocPrint(arena, "<{d} B>", .{b.len}), .kind = .blob },
		.text => |t| .{ .text = try flatten(arena, t), .kind = if (numeric) .float else .text },
	};
}

/// One line per cell: a newline inside a value would tear the grid apart.
pub fn flatten(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
	const copy = try arena.dupe(u8, text);
	for (copy) |*char| {
		if (char.* == '\n' or char.* == '\r' or char.* == '\t') {
			char.* = ' ';
		}
	}
	return copy;
}

pub fn writeDelimited(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, text: []const u8, separator: u8) !void {
	if (std.mem.indexOfAny(u8, text, &[_]u8{ '"', '\n', '\r', separator }) == null) {
		try out.appendSlice(allocator, text);
		return;
	}
	try out.append(allocator, '"');
	for (text) |char| {
		if (char == '"') {
			try out.append(allocator, '"');
		}
		try out.append(allocator, char);
	}
	try out.append(allocator, '"');
}

/// std.fs is mid-rework in this Zig version and libc is linked anyway.
fn writeFile(path: []const u8, bytes: []const u8) !void {
	var buffer: [std.fs.max_path_bytes]u8 = undefined;
	if (path.len >= buffer.len) {
		return error.NameTooLong;
	}
	@memcpy(buffer[0..path.len], path);
	buffer[path.len] = 0;
	const file = std.c.fopen(@ptrCast(&buffer), "wb") orelse return error.CannotCreate;
	defer _ = std.c.fclose(file);
	if (bytes.len != 0 and std.c.fwrite(bytes.ptr, 1, bytes.len, file) != bytes.len) {
		return error.WriteFailed;
	}
}


/// Milliseconds from the monotonic clock; std.time.Timer is gone in this Zig.
pub fn monotonicMs() f64 {
	var now: std.c.timespec = undefined;
	if (std.c.clock_gettime(.MONOTONIC, &now) != 0) {
		return 0;
	}
	return @as(f64, @floatFromInt(now.sec)) * 1000.0 + @as(f64, @floatFromInt(now.nsec)) / 1_000_000.0;
}

/// Whether a declared type has numeric affinity.
pub fn isNumeric(declared: []const u8) bool {
	for ([_][]const u8{ "INT", "REAL", "FLOA", "DOUB", "NUM", "DEC" }) |needle| {
		if (std.ascii.indexOfIgnoreCase(declared, needle) != null) {
			return true;
		}
	}
	return false;
}

/// Whether the text would be read back as a number rather than a string.
pub fn looksNumeric(text: []const u8) bool {
	if (text.len == 0) {
		return false;
	}
	var digits: usize = 0;
	for (text, 0..) |char, i| {
		switch (char) {
			'0'...'9' => digits += 1,
			'.', 'e', 'E' => {},
			'-', '+' => if (i != 0 and text[i - 1] != 'e' and text[i - 1] != 'E') {
				return false;
			},
			else => return false,
		}
	}
	return digits != 0;
}

/// Whether the driver's complaint is about a missing password - or a missing
/// secret key, which is what S3 calls one.
fn needsPassword(message: []const u8) bool {
	for ([_][]const u8{ "password", "authentication", "secret key" }) |needle| {
		if (std.ascii.indexOfIgnoreCase(message, needle) != null) {
			return true;
		}
	}
	return false;
}

pub fn divCeil(a: usize, b: usize) usize {
	return if (b == 0) 1 else (a + b - 1) / b;
}

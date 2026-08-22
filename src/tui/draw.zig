//! Rendering. Every frame is drawn in full into vaxis's cell buffer, which then
//! writes out only what changed, so there is no flicker and nothing here has to
//! track what the screen already shows.

const std = @import("std");
const app_mod = @import("app.zig");
const database = @import("db");
const term = @import("term.zig");
const input = @import("input.zig");
const sql_syntax = @import("editor.zig");
const fuzzy = @import("fuzzy.zig");
const Files = @import("files.zig");

const App = app_mod.App;
const C = app_mod.C;
const SIDEBAR = app_mod.SIDEBAR;
const Size = term.Size;

// The widest a single column may get; :text changes it.

pub fn frame(app: *App, size: Size) !void {
	const screen = app.screen;
	screen.begin();
	// Set again by whatever is being typed into, if anything is.
	app.type_cursor = null;

	const body_rows = if (size.rows > 3) size.rows - 3 else 1;
	// The file manager takes the whole width: two panes and a sidebar on eighty
	// columns would leave neither pane a name to show.
	const side = if (size.cols > SIDEBAR + 20 and app.view != .connections and app.view != .files) SIDEBAR else 0;

	header(app, size);
	if (app.view == .connections) {
		connections(app, size, body_rows);
		if (app.form != null) {
			try formPanel(app, size, 0, body_rows);
		}
		if (app.palette != null) {
			palettePanel(app, size, body_rows);
		}
		status(app, size);
		promptLine(app, size);
		try cursorAndFlush(app, size);
		return;
	}
	if (side > 0) {
		sidebar(app, side, body_rows);
	}
	switch (app.view) {
		.grid => grid(app, size, side, body_rows),
		.structure => structure(app, size, side, body_rows),
		.messages => messages(app, size, side, body_rows),
		.help => help(app, size, side, body_rows),
		.info => info(app, size, side, body_rows),
		.relations => relations(app, size, side, body_rows),
		.files => files(app, size, body_rows),
		.connections => {},
	}
	if (app.form != null) {
		try formPanel(app, size, side, body_rows);
	}
	if (app.editor != null) {
		editorPanel(app, size, side, body_rows);
	}
	if (app.detail) {
		try detail(app, size, side, body_rows);
	}
	if (app.palette != null) {
		palettePanel(app, size, body_rows);
	}
	status(app, size);
	promptLine(app, size);

	try cursorAndFlush(app, size);
}

/// Park the cursor where the user is typing, then put the frame on screen.
fn cursorAndFlush(app: *App, size: Size) !void {
	const screen = app.screen;
	if (app.prompt) |prompt| {
		// A password shows dots, so the cursor goes after the last one.
		const typed = if (prompt.kind == .password)
			std.unicode.utf8CountCodepoints(prompt.buffer.items) catch prompt.buffer.items.len
		else
			term.width(prompt.buffer.items);
		screen.cursorAt(size.rows - 1, term.width(prompt.label) + typed);
	} else if (app.editor) |*editor| {
		// In the editor the cursor is where the typing happens, inside the panel.
		const at = editor.position();
		const side: usize = if (size.cols > SIDEBAR + 20) SIDEBAR else 0;
		screen.cursorAt(2 + (at.line - editor.scroll), side + 2 + 5 + at.column);
	} else if (app.type_cursor) |spot| {
		screen.cursorAt(spot.row, spot.col);
	} else {
		screen.cursorOff();
	}
	screen.reset();
	try screen.flush();
}

/// The welcome screen: what is saved, and what the keys do. Shown at start and
/// whenever there is nothing open.
fn connections(app: *App, size: Size, rows: usize) void {
	const screen = app.screen;
	// A usize, spelled out: `@min` with a literal narrows the result to a type
	// that only fits the literal, and arithmetic on that overflows at once.
	const width: usize = @min(size.cols, 74);
	const left = if (size.cols > width) (size.cols - width) / 2 else 0;
	const top: usize = 2;
	var line: usize = top + 1;

	if (app.saved.items.items.len == 0) {
		screen.moveTo(line, left);
		screen.style(.{ .fg = C.dim });
		_ = write(app, "  Nothing saved yet.", width);
		line += 2;
	} else {
		for (app.saved.items.items, 0..) |item, i| {
			if (line + 3 > rows) {
				break;
			}
			const on = i == app.saved_at;
			screen.moveTo(line, left);
			screen.style(.{ .bg = if (on) C.selected else null, .fg = if (on) C.accent else C.text, .bold = on });
			_ = write(app, if (on) "  > " else "    ", width);
			pad(app, item.name, 22, false);
			screen.style(.{ .bg = if (on) C.selected else null, .fg = C.faint });
			pad(app, item.engine(), 11, false);
			// Where the password is kept says itself, rather than the file being the
			// only place to find that out.
			screen.style(.{ .bg = if (on) C.selected else null, .fg = if (item.keeps == .file) C.warn else C.ok });
			pad(app, item.keeps.label(), 9, false);
			screen.style(.{ .bg = if (on) C.selected else null, .fg = C.dim });
			// 4 for the marker, 22 name, 11 engine, 9 for where the password is.
			const room = if (width > 48) width - 48 else 0;
			const shown = write(app, item.target, room);
			// Filled to the panel's edge rather than the screen's: the row of the one
			// selected is a band of colour, and clearing to the end of the line would
			// take it out through the frame.
			screen.style(.{ .bg = if (on) C.selected else null });
			if (room > shown) {
				fill(app, ' ', room - shown);
			}
			line += 1;
		}
		line += 1;
	}

	const hints = [_][2][]const u8{
		.{ "enter", "connect to the one selected" },
		.{ "a", "add a connection" },
		.{ "e / d", "edit, remove" },
		.{ "up down", "move in the list" },
		.{ "q", "quit" },
	};
	for (hints) |entry| {
		if (line > rows) {
			break;
		}
		screen.moveTo(line, left);
		screen.style(.{ .fg = C.accent });
		_ = write(app, "    ", width);
		pad(app, entry[0], 10, false);
		screen.style(.{ .fg = C.dim });
		_ = write(app, entry[1], if (width > 16) width - 16 else 0);
		screen.clearToEol();
		line += 1;
	}
	if (line + 1 <= rows) {
		line += 1;
		screen.moveTo(line, left);
		screen.style(.{ .fg = C.faint });
		_ = write(app, "    A file path opens SQLite; postgres://, mysql://, redis://, kafka://, s3://, azure://, rabbit:// and sftp:// the rest.", width);
		line += 1;
		screen.moveTo(line, left);
		screen.style(.{ .fg = C.faint });
		_ = write(app, "    in file: the password is in plain text below; keychain: macOS keeps it.", width);
		line += 1;
	}
	if (line <= rows and app.saved_path.items.len != 0) {
		screen.moveTo(line, left);
		screen.style(.{ .fg = C.faint });
		_ = write(app, "    saved in ", width);
		_ = write(app, app.saved_path.items, if (width > 17) width - 17 else 0);
		line += 1;
	}
	screen.reset();
	box(app, top, left, width, line + 1 - top, "connect to a database", "", C.accent);
}

fn header(app: *App, size: Size) void {
	const screen = app.screen;
	screen.moveTo(0, 0);
	screen.style(.{ .bg = C.bar, .fg = C.text, .bold = true });
	var used: usize = 0;
	used += write(app, " krtek ", size.cols);
	screen.style(.{ .bg = C.bar, .fg = C.accent });
	used += write(app, if (app.connected) app.conn.describe() else "", size.cols - used);
	screen.style(.{ .bg = C.bar, .fg = C.dim });
	var buf: [96]u8 = undefined;
	const right = if (app.connected)
		std.fmt.bufPrint(&buf, "{s}  {d} objects ", .{ app.conn.version(), app.objects.items.len }) catch ""
	else
		"no connection ";
	const right_width = term.width(right);
	if (size.cols > used + right_width) {
		fill(app, ' ', size.cols - used - right_width);
		_ = write(app, right, right_width);
	} else {
		fill(app, ' ', if (size.cols > used) size.cols - used else 0);
	}
	screen.reset();
}

fn sidebar(app: *App, width: usize, rows: usize) void {
	const screen = app.screen;
	const visible = app.visibleCount();
	// Keep the selection on screen.
	const list_rows = if (rows > 1) rows - 1 else 1;
	if (app.selected < app.scroll) {
		app.scroll = app.selected;
	}
	if (app.selected >= app.scroll + list_rows) {
		app.scroll = app.selected - list_rows + 1;
	}

	screen.moveTo(1, 0);
	screen.style(.{ .fg = C.dim });
	if (app.prompt != null and app.prompt.?.kind == .filter) {
		_ = write(app, " filter: ", width);
		screen.style(.{ .fg = C.accent });
		_ = write(app, app.prompt.?.buffer.items, width - 9);
	} else if (app.filter.items.len > 0) {
		_ = write(app, " /", width);
		screen.style(.{ .fg = C.accent });
		_ = write(app, app.filter.items, width - 2);
	} else if (app.schema.items.len != 0) {
		_ = write(app, " SCHEMA ", width);
		screen.style(.{ .fg = C.accent });
		_ = write(app, app.schema.items, width - 8);
	} else {
		_ = write(app, " TABLES & VIEWS", width);
	}
	screen.clearToEol();

	if (visible == 0) {
		screen.moveTo(2, 1);
		screen.style(.{ .fg = C.faint, .italic = true });
		_ = write(app, if (app.filter.items.len > 0) "nothing matches" else "no tables yet", width - 1);
		if (app.filter.items.len == 0) {
			screen.moveTo(3, 1);
			_ = write(app, "c creates one", width - 1);
		}
		screen.reset();
	}
	var line: usize = 2;
	var n = app.scroll;
	while (line < rows + 1 and n < visible) : ({
		line += 1;
		n += 1;
	}) {
		const object = app.visibleAt(n) orelse break;
		const selected = n == app.selected;
		screen.moveTo(line, 0);
		if (selected) {
			screen.style(.{ .bg = C.selected, .fg = if (app.focus == .sidebar) C.accent else C.text, .bold = app.focus == .sidebar });
		} else {
			screen.style(.{ .fg = C.text });
		}
		const base: term.Style = if (selected)
			.{ .bg = C.selected, .fg = if (app.focus == .sidebar) C.accent else C.text, .bold = app.focus == .sidebar }
		else
			.{ .fg = C.text };
		var used: usize = 0;
		used += write(app, if (std.mem.eql(u8, object.kind, "view")) " ~ " else " ▪ ", width);
		// The filter matches fuzzily, so mark what earned the name its place.
		used += writeMatched(app, object.name, app.filterHit(object.name), width - used - 8, base);
		var buf: [24]u8 = undefined;
		const count = if (object.rows) |value|
			std.fmt.bufPrint(&buf, "{d} ", .{value}) catch " "
		else
			"? ";
		const count_width = term.width(count);
		if (width > used + count_width) {
			fill(app, ' ', width - used - count_width);
			screen.style(.{ .bg = if (selected) C.selected else null, .fg = C.faint });
			_ = write(app, count, count_width);
		}
		screen.reset();
		screen.clearToEol();
	}
	// Blank the rest of the sidebar.
	while (line < rows + 1) : (line += 1) {
		screen.moveTo(line, 0);
		screen.clearToEol();
	}
	// The rule between the panes, in the accent colour on the side that has the
	// keyboard - the cheapest way to show focus without a frame around each pane.
	var i: usize = 1;
	while (i < rows + 1) : (i += 1) {
		screen.moveTo(i, width - 1);
		screen.style(.{ .fg = if (app.focus == .sidebar) C.accent else C.faint });
		screen.put(if (app.focus == .sidebar) "┃" else "│");
	}
	screen.reset();
}

/// Which columns the grid shows on this frame, and how wide each one is.
const Layout = struct {
	columns: []const usize, // indexes into app.cols
	widths: []const usize,
};

fn layout(app: *App, available: usize, columns: []usize, widths: []usize) Layout {
	// Hidden columns take no part in the layout at all.
	var shown: usize = 0;
	for (0..app.cols.items.len) |i| {
		if (!app.isHidden(i) and shown < columns.len) {
			columns[shown] = i;
			shown += 1;
		}
	}
	if (shown == 0 or available == 0) {
		return .{ .columns = columns[0..0], .widths = widths[0..0] };
	}
	// The cursor's position among the visible columns drives the scrolling.
	var at: usize = 0;
	for (columns[0..shown], 0..) |index, n| {
		if (index == app.cursor_col) {
			at = n;
		}
	}
	if (at < app.col_scroll) {
		app.col_scroll = at;
	}
	while (true) {
		var used: usize = 0;
		var last = app.col_scroll;
		while (last < shown) {
			const w = @min(@max(app.widths.items[columns[last]], 3), app.text_limit);
			if (used + w + 1 > available and last > app.col_scroll) {
				break;
			}
			used += w + 1;
			last += 1;
		}
		if (at < last or app.col_scroll + 1 >= shown) {
			var n: usize = 0;
			var i = app.col_scroll;
			while (i < last and n < widths.len) : ({
				i += 1;
				n += 1;
			}) {
				columns[n] = columns[i];
				widths[n] = @min(@max(app.widths.items[columns[i]], 3), app.text_limit);
			}
			return .{ .columns = columns[0..n], .widths = widths[0..n] };
		}
		app.col_scroll += 1;
	}
}

fn grid(app: *App, size: Size, side: usize, rows: usize) void {
	const screen = app.screen;
	const left = side;
	const width = size.cols - left;

	// Title line: table, paging, sort.
	screen.moveTo(1, left);
	screen.style(.{ .fg = C.accent, .bold = true });
	var used: usize = write(app, " ", width) + write(app, app.title.items, width - 2);
	screen.style(.{ .fg = C.dim });
	var buf: [160]u8 = undefined;
	const first: usize = if (app.rows.items.len == 0) 0 else app.firstRow();
	var counted: [24]u8 = undefined;
	const total = if (app.counted)
		std.fmt.bufPrint(&counted, "{d}", .{app.total}) catch "?"
	else
		"?";
	const summary = std.fmt.bufPrint(&buf, "  {d}-{d} of {s}   page {d}/{d}{s}{s}{s}", .{
		first,
		app.firstRow() - 1 + app.rows.items.len,
		total,
		app.page + 1,
		app.pages(),
		if (app.order != null) "   order " else "",
		if (app.order) |column| column else "",
		if (app.order != null and app.descending) " desc" else "",
	}) catch "";
	used += write(app, summary, width - used);
	if (app.follow_ms != 0) {
		// In green, the colour of something going well: this is the one thing on
		// the line that is still happening, and it should be seen without being
		// read.
		screen.style(.{ .fg = C.ok, .bold = true });
		var every: [24]u8 = undefined;
		const text = std.fmt.bufPrint(&every, "   following {d:.1}s", .{
			@as(f64, @floatFromInt(app.follow_ms)) / 1000.0,
		}) catch "   following";
		used += write(app, text, width - used);
		screen.style(.{ .fg = C.dim });
	}
	if (!app.editable and app.rows.items.len > 0) {
		screen.style(.{ .fg = C.faint });
		used += write(app, "   read-only", width - used);
	}
	screen.clearToEol();

	var indexes: [128]usize = undefined;
	var widths: [128]usize = undefined;
	const plan = layout(app, width - 1, &indexes, &widths);

	// Header row.
	screen.moveTo(2, left);
	screen.style(.{ .bg = C.bar, .fg = C.dim, .bold = true });
	var x: usize = 0;
	for (plan.widths, 0..) |w, n| {
		const index = plan.columns[n];
		const sorted = app.order != null and std.mem.eql(u8, app.order.?, app.cols.items[index]);
		screen.style(.{ .bg = C.bar, .fg = if (sorted) C.accent else C.dim, .bold = true });
		screen.put(" ");
		pad(app, app.cols.items[index], w, false);
		x += w + 1;
	}
	screen.style(.{ .bg = C.bar });
	if (width > x) {
		fill(app, ' ', width - x);
	}
	screen.reset();

	// Rows.
	const list_rows = if (rows > 2) rows - 2 else 1;
	if (app.cursor_row < app.row_scroll) {
		app.row_scroll = app.cursor_row;
	}
	if (app.cursor_row >= app.row_scroll + list_rows) {
		app.row_scroll = app.cursor_row - list_rows + 1;
	}
	var line: usize = 3;
	var r = app.row_scroll;
	while (line < rows + 1) : (line += 1) {
		screen.moveTo(line, left);
		if (r >= app.rows.items.len) {
			screen.reset();
			screen.clearToEol();
			continue;
		}
		const row = app.rows.items[r];
		const on_row = r == app.cursor_row and app.focus == .main;
		for (plan.widths, 0..) |w, n| {
			const index = plan.columns[n];
			if (index >= row.cells.len) {
				break;
			}
			const cell = row.cells[index];
			const on_cell = on_row and index == app.cursor_col;
			screen.style(.{
				.bg = if (on_cell) C.accent else if (on_row) C.selected else null,
				.fg = if (on_cell) 16 else cell.colour(),
				.italic = cell.kind == .nul,
			});
			screen.put(" ");
			pad(app, cell.text, w, cell.kind == .int or cell.kind == .float);
		}
		screen.reset();
		screen.clearToEol();
		r += 1;
	}
	if (app.rows.items.len == 0) {
		screen.moveTo(4, left + 2);
		screen.style(.{ .fg = C.faint });
		// An empty table and a filter that matches nothing look the same on
		// screen, so say which one it is and what undoes it.
		const filtered = app.isFiltered();
		_ = write(app, if (filtered)
			"nothing matches the filter - W changes it, esc clears it"
		else if (app.editable)
			"no rows yet - i inserts one"
		else
			"no rows", width);
		screen.reset();
	}
}

fn structure(app: *App, size: Size, side: usize, rows: usize) void {
	const screen = app.screen;
	const left = side;
	const width = size.cols - left;
	const table = app.currentTable() orelse {
		note(app, left, width, "no table selected");
		return;
	};

	var arena = std.heap.ArenaAllocator.init(app.allocator);
	defer arena.deinit();
	const scratch = arena.allocator();

	screen.moveTo(1, left);
	screen.style(.{ .fg = C.accent, .bold = true });
	_ = write(app, " structure of ", width);
	_ = write(app, table.name, width);
	screen.clearToEol();

	var line: usize = 2;
	line = section(app, left, width, line, rows, "COLUMNS");
	for (app.conn.columns(scratch, table) catch &[_]database.Column{}) |column| {
		if (line > rows) {
			break;
		}
		screen.moveTo(line, left);
		var used: usize = 0;
		screen.style(.{ .fg = C.text });
		used += write(app, "  ", width);
		pad(app, column.name, 22, false);
		used += 22;
		screen.style(.{ .fg = C.dim });
		pad(app, column.type, 22, false);
		used += 22;
		if (column.notnull) {
			screen.style(.{ .fg = C.warn });
			used += write(app, "NOT NULL ", width - used);
		} else {
			screen.style(.{ .fg = C.nul, .italic = true });
			used += write(app, "null ", width - used);
		}
		if (column.pk) {
			screen.style(.{ .fg = C.accent });
			used += write(app, "PRIMARY ", width - used);
		}
		if (column.unique) {
			screen.style(.{ .fg = C.accent });
			used += write(app, "UNIQUE ", width - used);
		}
		if (column.dflt) |value| {
			screen.style(.{ .fg = C.faint });
			used += write(app, "default ", width - used);
			used += write(app, value, if (width > used) width - used else 0);
		}
		screen.reset();
		screen.clearToEol();
		line += 1;
	}

	line = section(app, left, width, line, rows, "INDEXES");
	for (app.conn.indexes(scratch, table) catch &[_]database.Index{}) |index| {
		if (line > rows) {
			break;
		}
		screen.moveTo(line, left);
		var used: usize = 0;
		screen.style(.{ .fg = C.accent });
		used += write(app, "  ", width);
		pad(app, index.kind, 9, false);
		used += 9;
		screen.style(.{ .fg = C.text });
		pad(app, index.columns, 30, false);
		used += 30;
		screen.style(.{ .fg = C.faint });
		used += write(app, " ", width - used);
		used += write(app, index.name, if (width > used) width - used else 0);
		if (index.partial) {
			used += write(app, " partial", if (width > used) width - used else 0);
		}
		screen.reset();
		screen.clearToEol();
		line += 1;
	}

	line = section(app, left, width, line, rows, "FOREIGN KEYS");
	for (app.conn.foreignKeys(scratch, table) catch &[_]database.ForeignKey{}) |key| {
		if (line > rows) {
			break;
		}
		screen.moveTo(line, left);
		var used: usize = 0;
		screen.style(.{ .fg = C.text });
		used += write(app, "  ", width);
		pad(app, key.column, 22, false);
		used += 22;
		screen.style(.{ .fg = C.faint });
		used += write(app, "-> ", width - used);
		screen.style(.{ .fg = C.accent });
		used += write(app, key.target_table, width - used);
		screen.style(.{ .fg = C.dim });
		used += write(app, ".", width - used);
		used += write(app, key.target_column, width - used);
		screen.style(.{ .fg = C.faint });
		used += write(app, "   on update ", width - used);
		used += write(app, key.on_update, width - used);
		used += write(app, ", on delete ", width - used);
		used += write(app, key.on_delete, if (width > used) width - used else 0);
		screen.reset();
		screen.clearToEol();
		line += 1;
	}

	line = section(app, left, width, line, rows, "DEFINITION");
	{
		const definition = (app.conn.definition(scratch, table) catch null) orelse "";
		var it = std.mem.splitScalar(u8, definition, '\n');
		while (it.next()) |part| {
			if (line > rows) {
				break;
			}
			screen.moveTo(line, left);
			screen.style(.{ .fg = C.dim });
			_ = write(app, "  ", width);
			// A tab would land on the terminal's own stop and break the column.
			const expanded = expandTabs(scratch, part) catch part;
			_ = write(app, expanded, width - 2);
			screen.clearToEol();
			line += 1;
		}
	}
	while (line <= rows) : (line += 1) {
		screen.moveTo(line, left);
		screen.reset();
		screen.clearToEol();
	}
}

fn section(app: *App, left: usize, width: usize, line: usize, rows: usize, title: []const u8) usize {
	if (line > rows) {
		return line;
	}
	const screen = app.screen;
	screen.moveTo(line, left);
	screen.style(.{ .fg = C.faint, .bold = true });
	_ = write(app, " ", width);
	_ = write(app, title, width - 1);
	screen.clearToEol();
	return line + 1;
}

/// Print the rows of a query as plain columns; used by the structure view.
fn rowsOf(app: *App, left: usize, width: usize, start: usize, rows: usize, sql: []const u8, columns: usize) usize {
	const screen = app.screen;
	var line = start;
	var cursor = (app.conn.prepare(sql, null) catch return line) orelse return line;
	defer cursor.finish();
	var arena = std.heap.ArenaAllocator.init(app.allocator);
	defer arena.deinit();
	while (cursor.step() catch false) {
		if (line > rows) {
			break;
		}
		screen.moveTo(line, left);
		screen.style(.{ .fg = C.text });
		var used: usize = write(app, "  ", width);
		for (0..@min(columns, cursor.columns())) |i| {
			const cell = app_mod.formatCell(arena.allocator(), cursor.value(i)) catch continue;
			if (i != 0) {
				screen.style(.{ .fg = C.faint });
				used += write(app, " · ", width - used);
			}
			screen.style(.{ .fg = if (i == 0) C.text else cell.colour(), .italic = cell.kind == .nul });
			used += write(app, cell.text, if (width > used) width - used else 0);
		}
		screen.reset();
		screen.clearToEol();
		line += 1;
	}
	return line;
}

/// Two panes side by side, each one a place and a path in it. Which pane the
/// keys go to is shown the same way the grid shows focus, because it is the
/// same idea: there is exactly one cursor and it is somewhere.
fn files(app: *App, size: Size, rows: usize) void {
	const screen = app.screen;
	const manager = app.files orelse return;
	// One column between them, and the odd column goes to the left pane.
	const gap: usize = 1;
	const right_width = if (size.cols > gap + 4) (size.cols - gap) / 2 else 2;
	const left_width = size.cols - gap - right_width;

	pane(app, &manager.left, 0, left_width, rows, manager.active == .left);
	pane(app, &manager.right, left_width + gap, right_width, rows, manager.active == .right);

	// The gap, cleared down the whole height so nothing shows through it.
	var line: usize = 1;
	while (line <= rows) : (line += 1) {
		screen.moveTo(line, left_width);
		screen.reset();
		_ = write(app, " ", gap);
	}
	screen.reset();
}

fn pane(app: *App, one: *Files.Pane, left: usize, width: usize, rows: usize, active: bool) void {
	const screen = app.screen;
	if (width < 4) {
		return;
	}

	// The heading: which place, and where in it. The path matters more than the
	// name of the place, so it is the end of it that survives a narrow pane.
	screen.moveTo(1, left);
	screen.style(.{ .bg = if (active) C.accent else C.bar, .fg = if (active) C.bar else C.dim, .bold = true });
	var head: [512]u8 = undefined;
	const title = std.fmt.bufPrint(&head, " {s}:{s}", .{
		one.place.label(),
		one.where(),
	}) catch " ";
	pad(app, endOf(title, width), width, false);

	const body = if (rows > 2) rows - 2 else 1;
	one.follow(body);

	var line: usize = 2;
	var at = one.scroll;
	while (line < 2 + body) : (line += 1) {
		screen.moveTo(line, left);
		if (at >= one.entries.len) {
			screen.reset();
			pad(app, "", width, false);
			at += 1;
			continue;
		}
		const entry = one.entries[at];
		const on = at == one.selected and active;
		const marked = one.isMarked(at);
		screen.style(.{
			.bg = if (on) C.selected else null,
			.fg = if (marked) C.warn else if (entry.kind == .dir) C.accent else C.text,
			.bold = entry.kind == .dir,
		});

		// The size and the time are fixed width on the right; the name takes what
		// is left, because the name is what is being looked for.
		var room: [16]u8 = undefined;
		var clock: [20]u8 = undefined;
		const shown_size = if (entry.kind == .dir) "<dir>" else Files.size(&room, entry.size);
		const shown_when = Files.when(&clock, entry.modified);
		const right_room = 6 + 1 + @as(usize, if (width > 46) 16 else 0);
		const name_room = if (width > right_room + 2) width - right_room - 1 else width - 1;

		_ = write(app, if (marked) "*" else " ", 1);
		pad(app, entry.name, name_room, false);
		if (width > right_room + 2) {
			pad(app, shown_size, 6, true);
			if (width > 46) {
				_ = write(app, " ", 1);
				pad(app, shown_when, 16, true);
			}
		}
		at += 1;
	}

	// The last line of the pane says what is in it, or why it is empty.
	screen.moveTo(1 + rows - 1, left);
	screen.style(.{ .bg = C.bar, .fg = if (one.trouble.items.len != 0) C.danger else C.faint });
	var foot: [256]u8 = undefined;
	const summary = if (one.trouble.items.len != 0)
		std.fmt.bufPrint(&foot, " {s}", .{one.trouble.items}) catch " "
	else if (one.marked.items.len != 0)
		std.fmt.bufPrint(&foot, " {d} marked of {d}", .{ one.marked.items.len, one.entries.len }) catch " "
	else
		std.fmt.bufPrint(&foot, " {d} items", .{one.entries.len}) catch " ";
	pad(app, endOf(summary, width), width, false);
	screen.reset();
}

/// The end of a path rather than the start of it, for when it does not fit:
/// `/home/zales/very/deep` says more as `very/deep` than as `/home/zal`.
fn endOf(text: []const u8, width: usize) []const u8 {
	if (term.width(text) <= width or width < 2) {
		return text;
	}
	var at = text.len -| (width - 1);
	while (at < text.len and text[at] & 0xC0 == 0x80) : (at += 1) {}
	return text[at..];
}

fn messages(app: *App, size: Size, side: usize, rows: usize) void {
	const screen = app.screen;
	const left = side;
	const width = size.cols - left;
	screen.moveTo(1, left);
	screen.style(.{ .fg = C.accent, .bold = true });
	_ = write(app, " last batch", width);
	screen.clearToEol();

	var line: usize = 2;
	for (app.reports.items, 0..) |report, n| {
		if (line + 1 > rows) {
			break;
		}
		screen.moveTo(line, left);
		screen.style(.{ .fg = if (report.failure != null) C.danger else C.dim });
		var buf: [32]u8 = undefined;
		var used: usize = write(app, std.fmt.bufPrint(&buf, " {d} ", .{n + 1}) catch " ", width);
		screen.style(.{ .fg = C.text });
		used += write(app, report.sql, width - used - 22);
		screen.style(.{ .fg = C.faint });
		var right: [48]u8 = undefined;
		const stats = if (report.result_set)
			"  result set, shown in the grid"
		else
			std.fmt.bufPrint(&right, "  {d} rows, {d} chg, {d:.1} ms", .{ report.rows, report.changes, report.ms }) catch "";
		used += write(app, stats, if (width > used) width - used else 0);
		screen.clearToEol();
		line += 1;
		if (report.failure) |message| {
			if (line > rows) {
				break;
			}
			screen.moveTo(line, left);
			screen.style(.{ .fg = C.danger });
			_ = write(app, "   ", width);
			_ = write(app, message, width - 3);
			screen.clearToEol();
			line += 1;
		}
	}
	if (app.reports.items.len == 0) {
		note(app, left, width, "nothing has been run yet");
		line = 3;
	}
	while (line <= rows) : (line += 1) {
		screen.moveTo(line, left);
		screen.reset();
		screen.clearToEol();
	}
}

const HELP = [_][2][]const u8{
	.{ "", "EVERYTHING" },
	.{ "ctrl+k ctrl+p", "command palette: search every action" },
	.{ "", "MOVING" },
	.{ "arrows hjkl", "list and grid" },
	.{ "tab", "sidebar / grid" },
	.{ "g G", "first, last row" },
	.{ "n p", "next, previous page" },
	.{ "/", "filter the object list" },
	.{ "d t", "data of the selected table" },
	.{ "S", "structure" },
	.{ "b L", "database info, relations" },
	.{ "m", "report of the last batch" },
	.{ "r", "reload" },
	.{ "R", "follow: reload every couple of seconds, staying at the end" },
	.{ "q ctrl+c", "quit" },
	.{ "", "ROWS" },
	.{ "enter", "edit the row in a form" },
	.{ "v", "show the whole value" },
	.{ "e", "edit the cell, NULL clears it" },
	.{ "i y", "insert, clone a row" },
	.{ "space", "mark a row" },
	.{ "x", "delete the marked rows" },
	.{ "o", "order by this column" },
	.{ "w W", "visible columns, filter" },
	.{ "", "SCHEMA" },
	.{ "c a", "create, alter a table" },
	.{ "I K", "index, foreign key" },
	.{ "V T", "view, trigger" },
	.{ "N Y", "rename, copy a table" },
	.{ "D X", "drop, empty" },
	.{ "", "DATA" },
	.{ "s", "SQL editor: colours, tab completes a name, ctrl+s runs" },
	.{ "F", "search every table" },
	.{ "E M", "export, import" },
	.{ "C c r p s", "copy the value, the row, the page, the last SQL" },
	.{ "O #", "connections, schema" },
	.{ ":", "export dump limit text follow open check analyze vacuum q" },
	.{ "", "FILES: SFTP, S3, AZURE" },
	.{ "f", "the two panes: this machine on one side, the connection on the other" },
	.{ "tab", "the other pane, which is where a copy goes" },
	.{ "enter h l", "into a directory, out of it" },
	.{ "/", "go to a path" },
	.{ "space", "mark, and unmark" },
	.{ "c", "copy to the other pane, directories and all" },
	.{ "n r x", "new directory, rename, remove" },
	.{ "", "IN THE SQL EDITOR" },
	.{ "ctrl+s", "run it" },
	.{ "tab", "complete a name" },
	.{ "ctrl+p ctrl+n", "earlier, later statement" },
	.{ "ctrl+w ctrl+u", "take back a word, everything" },
	.{ "", "IN A FORM" },
	.{ "ctrl+s", "save" },
	.{ "ctrl+n ctrl+k", "add, remove a column row" },
	.{ "left right", "toggle or cycle a value" },
	.{ "ctrl+u", "clear the field" },
	.{ "esc", "cancel" },
};

fn help(app: *App, size: Size, side: usize, rows: usize) void {
	const screen = app.screen;
	const left = side;
	const width = size.cols - left;
	screen.moveTo(1, left);
	screen.style(.{ .fg = C.accent, .bold = true });
	_ = write(app, " keys", width);
	screen.clearToEol();
	// Two columns: the list is longer than a terminal is tall.
	const half = (HELP.len + 1) / 2;
	const column_width = width / 2;
	var line: usize = 2;
	var i: usize = 0;
	while (i < half and line <= rows) : ({
		i += 1;
		line += 1;
	}) {
		screen.moveTo(line, left);
		screen.clearToEol();
		for ([_]usize{ i, i + half }) |at| {
			if (at >= HELP.len) {
				break;
			}
			const entry = HELP[at];
			screen.moveTo(line, left + (if (at == i) @as(usize, 0) else column_width));
			if (entry[0].len == 0) {
				screen.style(.{ .fg = C.faint, .bold = true });
				_ = write(app, "  ", column_width);
				_ = write(app, entry[1], column_width - 2);
				continue;
			}
			screen.style(.{ .fg = C.accent });
			_ = write(app, "  ", column_width);
			pad(app, entry[0], 15, false);
			screen.style(.{ .fg = C.text });
			_ = write(app, entry[1], if (column_width > 19) column_width - 19 else 0);
		}
	}
	if (line <= rows) {
		screen.moveTo(line, left);
		screen.style(.{ .fg = C.faint });
		_ = write(app, "  writes go straight to the file - there is nothing to save", width);
		screen.clearToEol();
		line += 1;
	}
	while (line <= rows) : (line += 1) {
		screen.moveTo(line, left);
		screen.reset();
		screen.clearToEol();
	}
}

/// The full value under the cursor, in a box over the grid.
/// A quick look at the first bytes: is this one of the formats the terminal's
/// decoder knows? Cheap enough to do on every frame, and wrong only in ways the
/// decoder itself catches - a BLOB that starts like a PNG but is not simply
/// falls back to being shown as bytes.
fn looksLikeImage(app: *App, bytes: []const u8) bool {
	if (bytes.len < 12) {
		return false;
	}
	// Only a cell the database itself called a BLOB is worth trying.
	if (!isBlobCell(app)) {
		return false;
	}
	const magic = [_][]const u8{
		"\x89PNG",
		"\xff\xd8\xff", // JPEG
		"GIF8",
		"BM", // BMP
		"qoif",
	};
	for (magic) |prefix| {
		if (std.mem.startsWith(u8, bytes, prefix)) {
			return true;
		}
	}
	// WebP, which is a RIFF container.
	return std.mem.startsWith(u8, bytes, "RIFF") and std.mem.indexOf(u8, bytes[0..12], "WEBP") != null;
}

/// Did the database call the cell under the cursor a BLOB?
fn isBlobCell(app: *App) bool {
	if (app.cursor_row >= app.rows.items.len) {
		return false;
	}
	const row = app.rows.items[app.cursor_row];
	return app.cursor_col < row.cells.len and row.cells[app.cursor_col].kind == .blob;
}

fn detail(app: *App, size: Size, side: usize, rows: usize) !void {
	var arena = std.heap.ArenaAllocator.init(app.allocator);
	defer arena.deinit();
	const text = (try app.cellDetail(arena.allocator())) orelse "NULL";
	const screen = app.screen;
	const left = side + 2;
	const width = if (size.cols > left + 4) size.cols - left - 3 else 10;
	const top: usize = 3;
	// Only as tall as the value needs, so a short cell does not open a big hole.
	var lines: usize = 1;
	var counter = std.mem.splitScalar(u8, text, '\n');
	while (counter.next()) |part| {
		lines += @max(1, app_mod.divCeil(term.width(part), @max(1, width - 2)));
	}
	// One row for each of the frame's edges, on top of the value itself.
	const height: usize = @max(4, @min(@min(rows - 2, 15), lines + 1));

	const column = if (app.cursor_col < app.cols.items.len) app.cols.items[app.cursor_col] else "";

	// A picture is shown as a picture, where the terminal can do that. The bytes
	// come back from the database as they are, so this is the real BLOB, not a
	// rendering of its hex.
	if (looksLikeImage(app, text) and screen.canDrawImages()) {
		const tall: usize = @min(rows -| 2, 18);
		var picture_line = top + 1;
		while (picture_line < top + tall - 1) : (picture_line += 1) {
			screen.moveTo(picture_line, left + 1);
			screen.style(.{ .bg = C.selected });
			fill(app, ' ', width -| 2);
		}
		if (screen.image(text, top + 1, left + 1, @intCast(tall -| 2), @intCast(width -| 2))) |_| {
			screen.reset();
			var label: [64]u8 = undefined;
			box(app, top, left, width, tall, column, std.fmt.bufPrint(&label, "{d} bytes, enter/esc closes", .{text.len}) catch "", C.accent);
			return;
		} else |_| {
			// Not a picture after all: fall through to the bytes.
			screen.forgetImage();
		}
	}

	// Bytes are shown as hex with their printable characters beside them. Putting
	// a BLOB on the terminal as it is would send control characters through it.
	if (isBlobCell(app)) {
		const per_line: usize = 16;
		const lines_needed = app_mod.divCeil(text.len, per_line);
		const tall: usize = @min(@max(4, lines_needed + 2), @min(rows -| 2, 20));
		var at: usize = 0;
		var hex_line = top + 1;
		while (hex_line + 1 < top + tall) : (hex_line += 1) {
			screen.moveTo(hex_line, left + 1);
			screen.style(.{ .bg = C.selected, .fg = C.text });
			var used: usize = write(app, " ", width -| 2);
			if (at < text.len) {
				const chunk = text[at..@min(text.len, at + per_line)];
				var buf: [8]u8 = undefined;
				screen.style(.{ .bg = C.selected, .fg = C.faint });
				used += write(app, std.fmt.bufPrint(&buf, "{x:0>6}  ", .{at}) catch "", width -| 2 -| used);
				screen.style(.{ .bg = C.selected, .fg = C.number });
				for (chunk) |byte| {
					used += write(app, std.fmt.bufPrint(&buf, "{x:0>2} ", .{byte}) catch "", width -| 2 -| used);
				}
				// Line the printable part up even on a short last line.
				var missing = per_line - chunk.len;
				while (missing > 0) : (missing -= 1) {
					used += write(app, "   ", width -| 2 -| used);
				}
				screen.style(.{ .bg = C.selected, .fg = C.dim });
				used += write(app, " ", width -| 2 -| used);
				for (chunk) |byte| {
					used += write(app, if (std.ascii.isPrint(byte)) &[_]u8{byte} else ".", width -| 2 -| used);
				}
				at += chunk.len;
			}
			screen.style(.{ .bg = C.selected });
			if (width > used + 2) {
				fill(app, ' ', width - used - 2);
			}
		}
		screen.reset();
		var label: [64]u8 = undefined;
		box(app, top, left, width, tall, column, std.fmt.bufPrint(&label, "{d} bytes, enter/esc closes", .{text.len}) catch "", C.accent);
		return;
	}

	var line = top + 1;

	var rest = text;
	while (line + 1 < top + height) : (line += 1) {
		screen.moveTo(line, left + 1);
		screen.style(.{ .bg = C.selected, .fg = C.text });
		screen.put(" ");
		if (rest.len == 0) {
			fill(app, ' ', width - 3);
			continue;
		}
		const newline = std.mem.indexOfScalar(u8, rest, '\n');
		const chunk = if (newline) |at| rest[0..at] else rest;
		const piece = term.fit(chunk, width - 4);
		screen.put(piece.text);
		fill(app, ' ', width - 3 - piece.cols);
		if (piece.text.len < chunk.len) {
			rest = rest[piece.text.len..];
		} else {
			rest = if (newline) |at| rest[at + 1 ..] else "";
		}
	}
	screen.reset();
	box(app, top, left, width, height, column, "enter/esc closes", C.accent);
}

fn note(app: *App, left: usize, width: usize, text: []const u8) void {
	const screen = app.screen;
	screen.moveTo(3, left + 2);
	screen.style(.{ .fg = C.faint });
	_ = write(app, text, width);
	screen.reset();
	screen.clearToEol();
}

/// The command palette, over whatever is behind it: a query line and the
/// matches, each with the key that runs it, so using it teaches the key map.
fn palettePanel(app: *App, size: Size, rows: usize) void {
	const palette = &app.palette.?;
	const screen = app.screen;
	const width: usize = @min(size.cols -| 4, 66);
	const left = (size.cols -| width) / 2;
	var found: [input.actions.len]usize = undefined;
	const count = input.paletteMatches(palette.query.items, &found);
	const room: usize = if (rows > 6) @min(rows - 4, 12) else 3;
	const shown: usize = @min(count, room);
	// Keep the cursor in view when the list is longer than the panel.
	var from: usize = 0;
	if (palette.at >= shown and shown != 0) {
		from = palette.at + 1 - shown;
	}

	var line: usize = 2;
	screen.moveTo(line, left + 1);
	screen.style(.{ .bg = C.bar, .fg = C.accent, .bold = true });
	var used: usize = write(app, " › ", width - 2);
	screen.style(.{ .bg = C.bar, .fg = C.text });
	used += write(app, palette.query.items, width -| used -| 2);
	app.type_cursor = .{ .row = line, .col = left + 1 + used };
	screen.style(.{ .bg = C.bar, .fg = C.faint });
	if (palette.query.items.len == 0) {
		used += write(app, "what do you want to do?", width -| used -| 2);
	}
	if (width > used + 2) {
		fill(app, ' ', width - used - 2);
	}

	var at: usize = from;
	while (at < from + shown) : (at += 1) {
		line += 1;
		const action = input.actions[found[at]];
		const here = at == palette.at;
		screen.moveTo(line, left + 1);
		screen.style(.{ .bg = if (here) C.selected else C.bar, .fg = if (here) C.accent else C.text });
		var span: usize = write(app, if (here) " ❯ " else "   ", width - 2);
		span += writeMatched(app, action.label, input.paletteHit(found[at], palette.query.items), width -| span -| 2, .{
			.bg = if (here) C.selected else C.bar,
			.fg = if (here) C.accent else C.text,
		});
		screen.style(.{ .bg = if (here) C.selected else C.bar, .fg = C.faint });
		// The key, right where the eye ends up, so it is learned in passing.
		var shortcut: [16]u8 = undefined;
		const name = keyName(&shortcut, action.key);
		const gap = width -| span -| term.width(name) -| 4;
		fill(app, ' ', gap);
		span += gap;
		span += write(app, name, width -| span -| 2);
		if (width > span + 2) {
			fill(app, ' ', width - span - 2);
		}
	}
	if (count == 0) {
		line += 1;
		screen.moveTo(line, left + 1);
		screen.style(.{ .bg = C.bar, .fg = C.dim, .italic = true });
		const span: usize = write(app, "   nothing matches", width - 2);
		if (width > span + 2) {
			fill(app, ' ', width - span - 2);
		}
	}
	line += 1;
	screen.moveTo(line, left + 1);
	screen.style(.{ .bg = C.bar, .fg = C.faint });
	var footer: usize = write(app, "   up down choose   enter run   esc close", width - 2);
	if (count > shown) {
		var buf: [32]u8 = undefined;
		footer += write(app, std.fmt.bufPrint(&buf, "   {d} more", .{count - shown}) catch "", width -| footer -| 2);
	}
	if (width > footer + 2) {
		fill(app, ' ', width - footer - 2);
	}
	screen.reset();
	box(app, 1, left, width, line + 1, "commands", "", C.accent);
}

/// Write `text`, marking the letters a fuzzy match landed on, so it is visible
/// why this line is in the list at all.
fn writeMatched(app: *App, text: []const u8, hit: fuzzy.Hit, max: usize, base: term.Style) usize {
	const screen = app.screen;
	var used: usize = 0;
	var marked = base;
	marked.fg = C.accent;
	marked.bold = true;
	marked.underline = true;
	// Byte positions, which is what the matcher works in; a multi-byte character
	// is written as one piece with the style of its first byte.
	var at: usize = 0;
	while (at < text.len and used < max) {
		const len = std.unicode.utf8ByteSequenceLength(text[at]) catch 1;
		const end = @min(text.len, at + len);
		screen.style(if (hit.has(at)) marked else base);
		used += write(app, text[at..end], max - used);
		at = end;
	}
	screen.style(base);
	return used;
}

/// How a key is written in the palette.
fn keyName(buffer: []u8, key: u21) []const u8 {
	if (key == ' ') {
		return "space";
	}
	var encoded: [4]u8 = undefined;
	const len = std.unicode.utf8Encode(key, &encoded) catch return "";
	return std.fmt.bufPrint(buffer, "{s}", .{encoded[0..len]}) catch "";
}

fn status(app: *App, size: Size) void {
	const screen = app.screen;
	screen.moveTo(size.rows - 2, 0);
	screen.style(.{ .bg = C.bar, .fg = if (app.status_error) C.danger else C.ok });
	var used: usize = write(app, " ", size.cols);
	used += write(app, app.status.items, size.cols - 1);
	screen.style(.{ .bg = C.bar });
	if (size.cols > used) {
		fill(app, ' ', size.cols - used);
	}
	screen.reset();
}

fn promptLine(app: *App, size: Size) void {
	const screen = app.screen;
	screen.moveTo(size.rows - 1, 0);
	screen.reset();
	if (app.prompt) |prompt| {
		screen.style(.{ .fg = C.accent, .bold = true });
		var used: usize = write(app, prompt.label, size.cols);
		screen.style(.{ .fg = C.text });
		if (prompt.kind == .password) {
			// Never echo a password, not even to the screen it was typed on.
			var dots: usize = 0;
			while (dots < term.width(prompt.buffer.items) and used < size.cols) : (dots += 1) {
				used += write(app, "•", size.cols - used);
			}
		} else {
			used += write(app, prompt.buffer.items, if (size.cols > used) size.cols - used else 0);
		}
		screen.clearToEol();
		return;
	}
	screen.style(.{ .fg = C.faint });
	_ = write(app, footerHints(app), size.cols);
	screen.clearToEol();
}

/// What is worth pressing where the user actually is. `ctrl+k` is on every one
/// of them, because it is the way to everything else.
fn footerHints(app: *App) []const u8 {
	if (app.prefix) |pending| {
		return switch (pending) {
			'C' => " c the value   r the row   p the page as CSV   s the last SQL   esc nothing",
			else => " esc cancels",
		};
	}
	if (app.detail) {
		return " esc closes the value   ctrl+k commands";
	}
	if (app.editor != null) {
		return " ctrl+s runs   tab completes   ctrl+p earlier   ctrl+w word back   esc closes";
	}
	if (app.form != null) {
		// Not the palette here: in a form ctrl+k removes a row.
		return " tab moves   ctrl+s saves   ctrl+u clears the field   esc cancels";
	}
	if (app.follow_ms != 0 and app.view == .grid) {
		// The one key worth knowing while the grid moves on its own.
		return " R stops following   ctrl+k commands   q quit";
	}
	return switch (app.view) {
		.connections => " enter connect   a add   e edit   d remove   ctrl+k commands   q quit",
		.structure => " a alter   I index   K key   N rename   S data   ctrl+k commands",
		.messages => " m back   s sql   r reload   ctrl+k commands",
		.help => " ? back   ctrl+k commands",
		.info => " b back   ctrl+k commands",
		.relations => " L back   d browse   ctrl+k commands",
		.files => " tab other pane   enter opens   c copy   space mark   n mkdir   r rename   x remove   q back",
		.grid => if (app.focus == .sidebar)
			" enter opens   / filter   c create table   E export   ctrl+k commands   q quit"
		else if (app.files != null)
			" f the two panes   i insert   e edit   x delete   o sort   v whole value   space mark"
		else
			" i insert   e edit   x delete   o sort   v whole value   space mark   ctrl+k commands",
	};
}

/// The SQL editor: line numbers, the statement in colour, and the completion
/// list where the word being typed is.
fn editorPanel(app: *App, size: Size, side: usize, rows: usize) void {
	const editor = &app.editor.?;
	const screen = app.screen;
	const outer_left = side + 1;
	const outer_width = if (size.cols > outer_left + 4) size.cols - outer_left - 1 else 20;
	const left = outer_left + 1;
	const width = outer_width -| 2;
	const top: usize = 1;
	// The gutter holds the line number, right aligned, and a space.
	const gutter: usize = 5;

	// Tall enough that a completion list has room inside the panel.
	const height: usize = @min(rows, @max(10, editor.lineCount() + 4));
	const shown = height -| 3;
	const at = editor.position();
	// Keep the line the cursor is on inside the panel.
	if (at.line < editor.scroll) {
		editor.scroll = at.line;
	}
	if (shown != 0 and at.line >= editor.scroll + shown) {
		editor.scroll = at.line - shown + 1;
	}

	var kinds: [1024]sql_syntax.Kind = undefined;
	var line: usize = 0;
	while (line < shown) : (line += 1) {
		const number = editor.scroll + line;
		const row = top + 1 + line;
		screen.moveTo(row, left);
		screen.style(.{ .bg = C.selected });
		fill(app, ' ', width);
		screen.moveTo(row, left);
		if (number >= editor.lineCount()) {
			continue;
		}
		var label: [8]u8 = undefined;
		screen.style(.{ .bg = C.selected, .fg = if (number == at.line) C.accent else C.faint });
		pad(app, std.fmt.bufPrint(&label, "{d}", .{number + 1}) catch "", gutter - 1, true);
		_ = write(app, " ", width);

		const text = editor.lineAt(number);
		sql_syntax.kinds(text, kinds[0..@min(kinds.len, text.len)]);
		var used: usize = gutter;
		var byte: usize = 0;
		while (byte < text.len and used < width) {
			const kind = if (byte < kinds.len) kinds[byte] else .plain;
			// One run per kind, so a keyword is written in one go.
			var stop = byte;
			while (stop < text.len and stop < kinds.len and kinds[stop] == kind) : (stop += 1) {}
			screen.style(.{ .bg = C.selected, .fg = switch (kind) {
				.keyword => C.accent,
				.string => C.ok,
				.number => C.number,
				.comment => C.faint,
				.punct => C.dim,
				.plain => C.text,
			}, .bold = kind == .keyword, .italic = kind == .comment });
			used += write(app, text[byte..stop], width - used);
			byte = stop;
		}
	}

	// The line under the panel says what the keys do; the frame carries the rest.
	screen.moveTo(top + height - 2, left);
	screen.style(.{ .bg = C.bar, .fg = C.faint });
	const hint: usize = write(app, "  ctrl+s runs   tab completes   ctrl+p earlier   ctrl+u clears   esc closes", width);
	if (width > hint) {
		fill(app, ' ', width - hint);
	}
	screen.reset();
	// An engine without SQL gets its own name on the panel, because what is typed
	// there is its command line and calling that SQL would be a lie.
	const caps = app.conn.caps();
	const title = if (caps.speaks_sql) "SQL" else if (caps.label.len != 0) caps.label else "command";
	box(app, top, outer_left, outer_width, height, title, "", C.accent);

	// The completion list, hanging under the word being completed.
	if (editor.completing()) {
		const count: usize = @min(editor.candidates.items.len, 7);
		const list_top: usize = @min(top + 2 + (at.line - editor.scroll), rows -| count -| 1);
		var widest: usize = 8;
		for (editor.candidates.items[0..count]) |name| {
			widest = @max(widest, term.width(name) + 4);
		}
		const list_left: usize = @min(left + gutter + at.column, size.cols -| widest -| 2);
		var n: usize = 0;
		while (n < count) : (n += 1) {
			const name = editor.candidates.items[n];
			const here = n == editor.candidate_at;
			screen.moveTo(list_top + 1 + n, list_left + 1);
			screen.style(.{ .bg = if (here) C.accent else C.bar, .fg = if (here) 16 else C.text, .bold = here });
			var used: usize = write(app, " ", widest);
			used += write(app, name, widest -| used -| 1);
			if (widest > used) {
				fill(app, ' ', widest - used);
			}
		}
		var more: [24]u8 = undefined;
		const label = if (editor.candidates.items.len > count)
			std.fmt.bufPrint(&more, "{d} more", .{editor.candidates.items.len - count}) catch ""
		else
			"";
		const list_width: usize = @min(widest + 2, size.cols -| list_left);
		const list_height: usize = @min(count + 2, rows -| list_top);
		box(app, list_top, list_left, list_width, list_height, "", label, C.accent);
	}
}

/// A rounded frame, with the title written into its top edge - the way panels
/// are drawn in current terminal interfaces, and cheaper to read than a bar,
/// because the eye gets the panel's extent for free.
///
/// The edges are drawn last, over whatever the panel put there, so a panel only
/// has to keep its content one column inside.
fn box(app: *App, top: usize, left: usize, width: usize, height: usize, title: []const u8, hint: []const u8, accent: u8) void {
	if (width < 4 or height < 2) {
		return;
	}
	const screen = app.screen;
	const bottom = top + height - 1;
	screen.style(.{ .fg = accent });
	screen.moveTo(top, left);
	var used: usize = write(app, "╭─", width);
	if (title.len != 0) {
		screen.style(.{ .fg = accent, .bold = true });
		used += write(app, " ", width - used);
		used += write(app, title, width -| used -| 2);
		used += write(app, " ", width -| used -| 1);
		screen.style(.{ .fg = accent });
	}
	if (hint.len != 0 and width > used + 8) {
		used += write(app, "─ ", width - used);
		screen.style(.{ .fg = C.faint });
		used += write(app, hint, width -| used -| 2);
		used += write(app, " ", width -| used -| 1);
		screen.style(.{ .fg = accent });
	}
	while (used < width - 1) : (used += 1) {
		_ = write(app, "─", 1);
	}
	_ = write(app, "╮", 1);

	var line = top + 1;
	while (line < bottom) : (line += 1) {
		screen.moveTo(line, left);
		_ = write(app, "│", 1);
		screen.moveTo(line, left + width - 1);
		_ = write(app, "│", 1);
	}
	screen.moveTo(bottom, left);
	used = write(app, "╰", width);
	while (used < width - 1) : (used += 1) {
		_ = write(app, "─", 1);
	}
	_ = write(app, "╯", 1);
	screen.reset();
}

// --- primitives ---

/// Write `text` clipped to `max` columns; returns the columns used.
fn write(app: *App, text: []const u8, max: usize) usize {
	if (max == 0) {
		return 0;
	}
	const piece = term.fit(text, max);
	app.screen.put(piece.text);
	return piece.cols;
}

/// Write `text` in a field of exactly `width` columns.
fn pad(app: *App, text: []const u8, width: usize, right_align: bool) void {
	const piece = term.fit(text, width);
	const space = width - piece.cols;
	if (right_align) {
		fill(app, ' ', space);
		app.screen.put(piece.text);
	} else {
		app.screen.put(piece.text);
		fill(app, ' ', space);
	}
}

fn fill(app: *App, char: u8, count: usize) void {
	var i: usize = 0;
	while (i < count) : (i += 1) {
		app.screen.put(&[_]u8{char});
	}
}

// --- the form overlay, the database info and the relation list -------------

/// A form is drawn over the main area, one field per line unless a field says
/// it continues the previous one.
fn formPanel(app: *App, size: Size, side: usize, rows: usize) !void {
	const form = &app.form.?;
	const screen = app.screen;
	const outer_left = side + 1;
	const outer_width = if (size.cols > outer_left + 2) size.cols - outer_left - 1 else 20;
	// The frame takes the outermost column on each side; everything below works
	// inside it, and the frame itself is drawn last.
	const left = outer_left + 1;
	const width = outer_width -| 2;

	// Walk the fields, packing the inline ones onto the same line.
	var line: usize = 2;
	var index: usize = 0;
	// Keep the field under the cursor visible.
	var cursor_line: usize = 2;
	{
		var probe: usize = 2;
		for (form.fields.items, 0..) |field, i| {
			if (i != 0 and !field.inline_with_previous) {
				probe += 1;
			}
			if (i == form.cursor) {
				cursor_line = probe;
				break;
			}
		}
	}
	const visible = if (rows > 3) rows - 2 else 1;
	if (cursor_line - 2 >= form.scroll + visible) {
		form.scroll = cursor_line - 2 - visible + 1;
	}
	if (cursor_line - 2 < form.scroll) {
		form.scroll = cursor_line - 2;
	}

	// Room left on the current line; a wide field must not underflow it.
	const room = struct {
		fn left_over(total: usize, at: usize, start: usize) usize {
			return if (at >= start + total) 0 else total - (at - start);
		}
	}.left_over;

	var row_on_screen: usize = 0;
	screen.moveTo(line, left);
	screen.style(.{ .bg = C.selected });
	fill(app, ' ', width);
	var column: usize = left + 1;
	while (index < form.fields.items.len) : (index += 1) {
		const field = &form.fields.items[index];
		if (index != 0 and !field.inline_with_previous) {
			row_on_screen += 1;
			if (row_on_screen < form.scroll) {
				continue;
			}
			line += 1;
			if (line >= rows) {
				break;
			}
			column = left + 1;
			screen.moveTo(line, left);
			screen.style(.{ .bg = C.selected });
			fill(app, ' ', width);
			screen.moveTo(line, column);
		} else if (row_on_screen < form.scroll) {
			continue;
		} else {
			screen.moveTo(line, column);
		}
		const focused = index == form.cursor;
		switch (field.kind) {
			.label => {
				screen.style(.{ .bg = C.selected, .fg = C.faint, .italic = true });
				column += write(app, field.label, room(width, column, left));
			},
			.toggle => {
				screen.style(.{ .bg = C.selected, .fg = if (focused) C.accent else C.dim, .bold = focused });
				column += write(app, if (field.on) "[x] " else "[ ] ", room(width, column, left));
				column += write(app, field.label, room(width, column, left));
				column += write(app, "  ", room(width, column, left));
			},
			.choice => {
				screen.style(.{ .bg = C.selected, .fg = C.dim });
				const label_width: usize = if (field.inline_with_previous) 5 else 28;
				pad(app, field.label, label_width, false);
				column += label_width;
				column += write(app, " ", width);
				screen.style(.{
					.bg = if (focused) C.accent else C.bar,
					.fg = if (focused) 16 else C.text,
				});
				column += write(app, "<", room(width, column, left));
				pad(app, field.value(), field.width, false);
				column += field.width;
				column += write(app, ">", room(width, column, left));
				screen.style(.{ .bg = C.selected });
				column += write(app, "  ", room(width, column, left));
			},
			.text => {
				screen.style(.{ .bg = C.selected, .fg = if (focused) C.accent else C.dim, .bold = focused });
				// A fixed label column keeps the values lined up; a repeatable row
				// is tighter, because five fields share the line.
				const label_width: usize = if (field.inline_with_previous) 8 else if (field.group != 0) 8 else 28;
				pad(app, field.label, label_width, false);
				column += label_width;
				column += write(app, " ", room(width, column, left));
				screen.style(.{ .bg = if (focused) C.bar else C.selected, .fg = C.text });
				// Show the tail of a long value, which is what is being typed - or
				// dots, where the value is a password.
				var dots: [64]u8 = undefined;
				const shown = if (field.masked)
					mask(&dots, field.text.items, field.width)
				else
					tail(field.text.items, field.width);
				if (focused) {
					// After the last character, where the next one will go.
					app.type_cursor = .{ .row = line, .col = column + @min(term.width(shown), field.width -| 1) };
				}
				pad(app, shown, field.width, false);
				column += field.width;
				screen.style(.{ .bg = C.selected });
				column += write(app, "  ", room(width, column, left));
			},
		}
	}
	while (line + 1 < rows) : (line += 1) {
		screen.moveTo(line + 1, left);
		screen.style(.{ .bg = C.selected });
		fill(app, ' ', width);
	}
	screen.reset();
	box(app, 1, outer_left, outer_width, rows, form.title, form.hint, C.accent);
}

/// A password as dots, one per character, up to what the field can show.
fn mask(buffer: []u8, text: []const u8, width: usize) []const u8 {
	const count = @min(std.unicode.utf8CountCodepoints(text) catch text.len, @min(width, buffer.len / 3));
	var at: usize = 0;
	var written: usize = 0;
	while (written < count) : (written += 1) {
		@memcpy(buffer[at .. at + 3], "•");
		at += 3;
	}
	return buffer[0..at];
}

/// The last `max` columns of a value.
fn tail(text: []const u8, max: usize) []const u8 {
	if (term.width(text) <= max) {
		return text;
	}
	var start = text.len;
	var used: usize = 0;
	while (start > 0) {
		var at = start - 1;
		while (at > 0 and text[at] & 0xc0 == 0x80) {
			at -= 1;
		}
		const point = std.unicode.utf8Decode(text[at..start]) catch 0xfffd;
		const w = term.charWidth(point);
		if (used + w > max) {
			break;
		}
		used += w;
		start = at;
	}
	return text[start..];
}

fn info(app: *App, size: Size, side: usize, rows: usize) void {
	const screen = app.screen;
	const left = side;
	const width = size.cols - left;
	var arena = std.heap.ArenaAllocator.init(app.allocator);
	defer arena.deinit();

	screen.moveTo(1, left);
	screen.style(.{ .fg = C.accent, .bold = true });
	_ = write(app, " ", width);
	_ = write(app, app.conn.caps().label, width);
	screen.clearToEol();

	var line: usize = 2;
	line = labelled(app, left, width, line, rows, "connection", app.conn.describe());
	line = labelled(app, left, width, line, rows, "version", app.conn.version());
	line = section(app, left, width, line, rows, "SETTINGS");
	for (app.conn.settings(arena.allocator()) catch &[_]database.Setting{}) |setting| {
		if (line > rows) {
			break;
		}
		const bad = std.mem.eql(u8, setting.label, "integrity") and !std.mem.eql(u8, setting.value, "ok");
		if (bad) {
			screen.moveTo(line, left);
			screen.style(.{ .fg = C.danger });
			_ = write(app, "  ", width);
			pad(app, setting.label, 18, false);
			_ = write(app, setting.value, if (width > 22) width - 22 else 0);
			screen.clearToEol();
			line += 1;
			continue;
		}
		line = labelled(app, left, width, line, rows, setting.label, setting.value);
	}
	while (line <= rows) : (line += 1) {
		screen.moveTo(line, left);
		screen.reset();
		screen.clearToEol();
	}
}

/// Replace tabs with two spaces so indentation survives inside a panel.
fn expandTabs(scratch: std.mem.Allocator, line: []const u8) ![]const u8 {
	var out: std.ArrayListUnmanaged(u8) = .empty;
	for (line) |char| {
		if (char == '\t') {
			try out.appendSlice(scratch, "  ");
		} else {
			try out.append(scratch, char);
		}
	}
	return out.items;
}

fn labelled(app: *App, left: usize, width: usize, line: usize, rows: usize, label: []const u8, value: []const u8) usize {
	if (line > rows) {
		return line;
	}
	const screen = app.screen;
	screen.moveTo(line, left);
	screen.style(.{ .fg = C.dim });
	_ = write(app, "  ", width);
	pad(app, label, 18, false);
	screen.style(.{ .fg = C.text });
	_ = write(app, value, if (width > 22) width - 22 else 0);
	screen.clearToEol();
	return line + 1;
}

/// Every foreign key in the database, as one overview of how it hangs together.
fn relations(app: *App, size: Size, side: usize, rows: usize) void {
	const screen = app.screen;
	const left = side;
	const width = size.cols - left;
	screen.moveTo(1, left);
	screen.style(.{ .fg = C.accent, .bold = true });
	_ = write(app, " relations", width);
	screen.clearToEol();

	var arena = std.heap.ArenaAllocator.init(app.allocator);
	defer arena.deinit();
	var line: usize = 2;
	var found: usize = 0;
	for (app.objects.items) |object| {
		if (!std.mem.eql(u8, object.kind, "table")) {
			continue;
		}
		const keys = app.foreignKeyDefs(arena.allocator(), object.name) catch continue;
		for (keys) |key| {
			if (line > rows) {
				break;
			}
			found += 1;
			screen.moveTo(line, left);
			screen.style(.{ .fg = C.text });
			var used: usize = write(app, "  ", width);
			pad(app, object.name, 20, false);
			used += 20;
			screen.style(.{ .fg = C.dim });
			pad(app, key.column, 18, false);
			used += 18;
			screen.style(.{ .fg = C.faint });
			used += write(app, "-> ", width - used);
			screen.style(.{ .fg = C.accent });
			used += write(app, key.target_table, width - used);
			screen.style(.{ .fg = C.dim });
			used += write(app, ".", width - used);
			used += write(app, key.target_column, width - used);
			screen.style(.{ .fg = C.faint });
			used += write(app, "   ", width - used);
			used += write(app, key.on_delete, if (width > used) width - used else 0);
			screen.clearToEol();
			line += 1;
		}
	}
	if (found == 0) {
		note(app, left, width, "no foreign keys in this database");
		line = 3;
	}
	while (line <= rows) : (line += 1) {
		screen.moveTo(line, left);
		screen.reset();
		screen.clearToEol();
	}
}

//! Key handling. A prompt swallows everything while it is open; otherwise the
//! keys act on whichever pane has focus.

const std = @import("std");
const app_mod = @import("app.zig");
const fuzzy = @import("fuzzy.zig");
const term = @import("term.zig");

const App = app_mod.App;
const Key = term.Key;
const Prompt = app_mod.Prompt;
const PromptKind = app_mod.PromptKind;

pub fn handle(app: *App, key: Key, size: term.Size) !void {
	if (app.prompt != null) {
		try typing(app, key);
		return;
	}
	if (app.form != null) {
		switch (app.form.?.handle(key)) {
			.none => try app.afterFormKey(),
			.cancel => app.closeForm(),
			.submit => try app.submitForm(),
			.add_row => try app.addFormRow(),
			.remove_row => try app.removeFormRow(),
		}
		return;
	}
	if (app.palette != null) {
		try onPalette(app, key, size);
		return;
	}
	if (app.editor != null) {
		try onEditor(app, key);
		return;
	}
	if (app.prefix) |pending| {
		app.prefix = null;
		try afterPrefix(app, pending, key);
		return;
	}
	if (app.view == .connections) {
		try onConnections(app, key);
		return;
	}
	if (app.view == .files) {
		try onFiles(app, key);
		return;
	}
	if (app.detail) {
		// The detail box only closes; navigation would be confusing under it.
		switch (key) {
			.escape, .enter, .char => app.detail = false,
			.ctrl => |code| if (code == 'c') {
				app.quit = true;
			},
			else => {},
		}
		return;
	}

	switch (key) {
		.ctrl => |code| switch (code) {
			'c' => app.quit = true,
			'd' => try movePage(app, 1),
			'u' => try movePage(app, -1),
			'k', 'p' => try openPalette(app),
			else => {},
		},
		.mouse => |mouse| try click(app, mouse, size),
		.tab, .back_tab => app.focus = if (app.focus == .sidebar) .main else .sidebar,
		.escape => {
			if (app.view != .grid) {
				app.view = .grid;
			} else if (app.filter.items.len > 0) {
				app.filter.clearRetainingCapacity();
				app.selected = 0;
			}
		},
		.up => try move(app, -1),
		.down => try move(app, 1),
		.left => moveColumn(app, -1),
		.right => moveColumn(app, 1),
		.page_up => try movePage(app, -1),
		.page_down => try movePage(app, 1),
		.home => {
			if (app.focus == .sidebar) {
				app.selected = 0;
			} else {
				app.cursor_row = 0;
			}
		},
		.end => {
			if (app.focus == .sidebar) {
				const count = app.visibleCount();
				app.selected = if (count == 0) 0 else count - 1;
			} else {
				app.cursor_row = if (app.rows.items.len == 0) 0 else app.rows.items.len - 1;
			}
		},
		.enter => try open(app),
		.char => |point| try letter(app, point, size),
		else => {},
	}
}

/// The mouse: the wheel scrolls whichever pane it is over, a click puts the
/// cursor where it landed. The layout has to be recomputed here, because the
/// drawing code is the only other place that knows it.
/// The welcome screen: a short list of keys, and the mouse works too.
/// Everything the app can do, with the key that does it. A key map has to be
/// remembered; this can be searched, so nothing is only discoverable by reading
/// the help. `needs` is the pane an action belongs to, and the palette moves
/// there before running it, so choosing "insert a row" from the object list does
/// what it says.
pub const Action = struct {
	key: u21,
	label: []const u8,
	/// Words to match on besides the label.
	also: []const u8 = "",
	needs: ?app_mod.Focus = null,
};

pub const actions = [_]Action{
	.{ .key = 'd', .label = "browse the selected table", .also = "data rows open select", .needs = .sidebar },
	.{ .key = 'S', .label = "structure of the table", .also = "columns indexes keys schema create" },
	.{ .key = 's', .label = "write and run SQL", .also = "query editor statement" },
	.{ .key = 'F', .label = "search every table", .also = "find text grep" },
	.{ .key = '/', .label = "filter the object list", .also = "search find tables" },
	.{ .key = 'W', .label = "filter the rows", .also = "where condition" },
	.{ .key = 'w', .label = "choose visible columns", .also = "hide show" },
	.{ .key = 'o', .label = "sort by this column", .also = "order asc desc" },
	.{ .key = 'r', .label = "reload", .also = "refresh again" },
	.{ .key = 'i', .label = "insert a row", .also = "new add", .needs = .main },
	.{ .key = 'e', .label = "edit the row", .also = "change update", .needs = .main },
	.{ .key = 'y', .label = "clone the row", .also = "copy duplicate", .needs = .main },
	.{ .key = 'x', .label = "delete the marked rows", .also = "remove", .needs = .main },
	.{ .key = ' ', .label = "mark the row", .also = "select tick", .needs = .main },
	.{ .key = 'v', .label = "show the whole value", .also = "detail full text", .needs = .main },
	.{ .key = 'c', .label = "create a table", .also = "new" },
	.{ .key = 'a', .label = "alter the table", .also = "change columns modify" },
	.{ .key = 'I', .label = "add an index", .also = "unique primary key" },
	.{ .key = 'K', .label = "add a foreign key", .also = "reference relation" },
	.{ .key = 'V', .label = "create a view", .also = "new" },
	.{ .key = 'T', .label = "create a trigger", .also = "new" },
	.{ .key = 'N', .label = "rename the table", .also = "move" },
	.{ .key = 'Y', .label = "copy the table", .also = "duplicate" },
	.{ .key = 'X', .label = "empty the table", .also = "truncate delete all" },
	.{ .key = 'D', .label = "drop the table", .also = "delete remove" },
	.{ .key = 'E', .label = "export", .also = "dump sql csv save" },
	.{ .key = 'C', .label = "copy to the clipboard", .also = "yank value row page csv sql" },
	.{ .key = 'M', .label = "import", .also = "load sql csv file" },
	.{ .key = 'b', .label = "database information", .also = "settings pragmas size version" },
	.{ .key = 'L', .label = "list every relation", .also = "objects tables views indexes" },
	.{ .key = '#', .label = "switch schema", .also = "namespace search path" },
	.{ .key = 'O', .label = "connections", .also = "open connect database server saved" },
	.{ .key = 'f', .label = "browse the files", .also = "copy upload download transfer sftp s3 azure manager" },
	.{ .key = 'm', .label = "messages", .also = "log reports errors" },
	.{ .key = '?', .label = "help: the whole key map", .also = "keys shortcuts" },
	.{ .key = ':', .label = "a command", .also = "limit text vacuum analyze check" },
	.{ .key = 'q', .label = "quit", .also = "exit close" },
};

/// How well `action` answers what has been typed, or null if it does not. Every
/// word has to be found somewhere - in the label or in the extra words - and a
/// match in the label itself is worth far more, so "inse" is "insert a row"
/// rather than something whose keywords happen to contain those letters.
fn score(action: Action, query: []const u8, hit: ?*fuzzy.Hit) ?u16 {
	if (hit) |out| {
		out.* = .{};
	}
	if (query.len == 0) {
		return 1;
	}
	var total: u16 = 0;
	var words = std.mem.tokenizeAny(u8, query, " ");
	while (words.next()) |word| {
		if (fuzzy.match(action.label, word, hit)) |got| {
			total += got * 4;
			// Typed as one piece, in the label: as good as it gets.
			if (std.ascii.indexOfIgnoreCase(action.label, word) != null) {
				total += 40;
			}
			continue;
		}
		total += fuzzy.match(action.also, word, null) orelse return null;
	}
	return total;
}

/// The matches, in order, into `out`; returns how many there are.
pub fn paletteMatches(query: []const u8, out: *[actions.len]usize) usize {
	var scores: [actions.len]u16 = undefined;
	var count: usize = 0;
	for (actions, 0..) |action, i| {
		const got = score(action, query, null) orelse continue;
		out[count] = i;
		scores[count] = got;
		count += 1;
	}
	// Best first; equal scores keep the order they are declared in, which groups
	// browsing, rows and schema the way the help does. An insertion sort, over a
	// list this size, on a keystroke.
	var i: usize = 1;
	while (i < count) : (i += 1) {
		var j = i;
		while (j > 0 and scores[j] > scores[j - 1]) : (j -= 1) {
			std.mem.swap(u16, &scores[j], &scores[j - 1]);
			std.mem.swap(usize, &out[j], &out[j - 1]);
		}
	}
	return count;
}

/// Which letters of an action's label the query matched, for the drawing code.
pub fn paletteHit(index: usize, query: []const u8) fuzzy.Hit {
	var hit = fuzzy.Hit{};
	_ = score(actions[index], query, &hit);
	return hit;
}

test "the palette finds an action by a few letters of it" {
	var found: [actions.len]usize = undefined;
	try std.testing.expect(paletteMatches("", &found) == actions.len);

	// Words, in any order, matched as text rather than scattered letters.
	var count = paletteMatches("dro tab", &found);
	try std.testing.expect(count >= 1);
	try std.testing.expectEqualStrings("drop the table", actions[found[0]].label);

	// The label wins over the extra words: "insert" is one, not "structure".
	count = paletteMatches("inse", &found);
	try std.testing.expect(count >= 1);
	try std.testing.expectEqualStrings("insert a row", actions[found[0]].label);

	// A word only in the extra words still finds it.
	count = paletteMatches("vacuum", &found);
	try std.testing.expect(count == 1);
	try std.testing.expectEqualStrings("a command", actions[found[0]].label);

	try std.testing.expect(paletteMatches("zzz", &found) == 0);
}

/// Keys while the SQL editor is open. Everything that is not a command inserts
/// itself, which is what makes it an editor rather than a prompt.
fn onEditor(app: *App, key: Key) !void {
	const editor = &app.editor.?;
	switch (key) {
		.ctrl => |code| switch (code) {
			's' => try app.runEditor(),
			'c' => app.closeEditor(),
			'u' => editor.clear(),
			'w' => editor.deleteWord(),
			'p' => try app.editorHistory(-1),
			'n' => try app.editorHistory(1),
			'a' => editor.home(),
			'e' => editor.end(),
			else => {},
		},
		.escape => {
			// The completion list is what escape closes first, if it is open.
			if (editor.completing()) {
				editor.closeCompletion();
			} else {
				app.closeEditor();
			}
		},
		.tab => {
			if (editor.completing()) {
				editor.nextCandidate(1);
			} else {
				try app.completeInEditor();
			}
		},
		.back_tab => editor.nextCandidate(-1),
		.enter => {
			if (editor.completing()) {
				try editor.take(editor.candidate_at);
			} else {
				try editor.insert("\n");
			}
		},
		.backspace => editor.backspace(),
		.delete => editor.delete(),
		.left => editor.left(),
		.right => editor.right(),
		.up => if (editor.completing()) editor.nextCandidate(-1) else editor.up(),
		.down => if (editor.completing()) editor.nextCandidate(1) else editor.down(),
		.home => editor.home(),
		.end => editor.end(),
		.page_up, .page_down => {},
		.char => |point| {
			var buf: [4]u8 = undefined;
			const len = std.unicode.utf8Encode(point, &buf) catch return;
			try editor.insert(buf[0..len]);
		},
		else => {},
	}
}

/// The second key of a two-key sequence. Only `C` has one so far.
fn afterPrefix(app: *App, pending: u21, key: Key) !void {
	if (pending != 'C') {
		return;
	}
	switch (key) {
		.char => |point| switch (point) {
			'c' => try app.copyCell(),
			'r' => try app.copyRow(),
			'p' => try app.copyPage(),
			's' => try app.copyLastSql(),
			else => app.say("nothing copied", .{}),
		},
		// Anything else abandons the sequence, which is what escape is for.
		else => app.say("nothing copied", .{}),
	}
}

/// Keys while the palette is open.
fn onPalette(app: *App, key: Key, size: term.Size) !void {
	const palette = &app.palette.?;
	var found: [actions.len]usize = undefined;
	const count = paletteMatches(palette.query.items, &found);
	switch (key) {
		.escape => closePalette(app),
		.ctrl => |code| switch (code) {
			'c', 'k' => closePalette(app),
			'u' => {
				palette.query.clearRetainingCapacity();
				palette.at = 0;
			},
			'n' => if (count != 0 and palette.at + 1 < count) {
				palette.at += 1;
			},
			'p' => if (palette.at > 0) {
				palette.at -= 1;
			},
			else => {},
		},
		.down => if (count != 0 and palette.at + 1 < count) {
			palette.at += 1;
		},
		.up => if (palette.at > 0) {
			palette.at -= 1;
		},
		.backspace => {
			if (palette.query.items.len > 0) {
				var cut = palette.query.items.len - 1;
				while (cut > 0 and palette.query.items[cut] & 0xc0 == 0x80) {
					cut -= 1;
				}
				palette.query.shrinkRetainingCapacity(cut);
				palette.at = 0;
			}
		},
		.enter => {
			if (palette.at >= count) {
				closePalette(app);
				return;
			}
			const action = actions[found[palette.at]];
			closePalette(app);
			// An action that belongs to a pane is run in that pane.
			if (action.needs) |pane| {
				if (pane == .main and app.view != .grid) {
					app.view = .grid;
				}
				app.focus = pane;
			}
			try letter(app, action.key, size);
		},
		.char => |point| {
			var buf: [4]u8 = undefined;
			const len = std.unicode.utf8Encode(point, &buf) catch return;
			try palette.query.appendSlice(app.allocator, buf[0..len]);
			palette.at = 0;
		},
		else => {},
	}
}

fn openPalette(app: *App) !void {
	closePalette(app);
	app.palette = .{};
	app.say("type what you want to do - enter runs it, esc closes", .{});
}

fn closePalette(app: *App) void {
	if (app.palette) |*palette| {
		palette.query.deinit(app.allocator);
	}
	app.palette = null;
}

/// The welcome screen: a short list of keys, and the mouse works too.
fn onConnections(app: *App, key: Key) !void {
	const count = app.saved.items.items.len;
	switch (key) {
		.ctrl => |code| if (code == 'c') {
			app.quit = true;
		},
		.char => |point| switch (point) {
			'q' => app.quit = true,
			'a' => try app.openConnectionForm(false),
			'e' => try app.openConnectionForm(true),
			'd' => try app.forgetSaved(),
			'j' => if (count != 0 and app.saved_at + 1 < count) {
				app.saved_at += 1;
			},
			'k' => if (app.saved_at > 0) {
				app.saved_at -= 1;
			},
			'?' => app.view = .help,
			else => {},
		},
		.down => if (count != 0 and app.saved_at + 1 < count) {
			app.saved_at += 1;
		},
		.up => if (app.saved_at > 0) {
			app.saved_at -= 1;
		},
		.enter => try app.connectSaved(),
		.escape => if (app.connected) {
			app.view = .grid;
		},
		.mouse => |mouse| {
			// The list starts on the fifth row of the panel.
			if (mouse.button == .left and mouse.row >= 4 and mouse.row - 4 < count) {
				app.saved_at = mouse.row - 4;
				try app.connectSaved();
			}
		},
		else => {},
	}
}

fn click(app: *App, mouse: term.Mouse, size: term.Size) !void {
	const side: usize = if (size.cols > app_mod.SIDEBAR + 20) app_mod.SIDEBAR else 0;
	const in_sidebar = side != 0 and mouse.col < side;

	switch (mouse.button) {
		.wheel_up, .wheel_down => {
			const delta: i32 = if (mouse.button == .wheel_down) 1 else -1;
			const was = app.focus;
			app.focus = if (in_sidebar) .sidebar else .main;
			var steps: usize = 0;
			while (steps < 3) : (steps += 1) {
				try move(app, delta);
			}
			if (in_sidebar) {
				app.focus = was;
			}
			return;
		},
		.left => {},
		else => return,
	}

	if (in_sidebar) {
		// The list starts on the third row of the sidebar.
		if (mouse.row < 2) {
			return;
		}
		const at = app.scroll + (mouse.row - 2);
		if (at < app.visibleCount()) {
			app.selected = at;
			app.focus = .sidebar;
			if (app.current()) |object| {
				try app.openTable(object.name);
				app.focus = .main;
			}
		}
		return;
	}
	if (app.view != .grid or mouse.row < 3) {
		return;
	}
	app.focus = .main;
	const row = app.row_scroll + (mouse.row - 3);
	if (row < app.rows.items.len) {
		app.cursor_row = row;
	}
	// Walk the visible columns to find which one the click landed in.
	var x: usize = side;
	var index = app.col_scroll;
	var seen: usize = 0;
	while (index < app.cols.items.len) : (index += 1) {
		if (app.isHidden(index)) {
			continue;
		}
		const w = @min(@max(app.widths.items[index], 3), app.text_limit) + 1;
		if (mouse.col >= x and mouse.col < x + w) {
			app.cursor_col = index;
			break;
		}
		x += w;
		seen += 1;
		if (x > size.cols) {
			break;
		}
	}
}

fn letter(app: *App, point: u21, size: term.Size) !void {
	_ = size;
	switch (point) {
		'q' => app.quit = true,
		'?' => app.view = if (app.view == .help)
			// Back to wherever the question was asked from, which is the file
			// manager when that is what is open.
			(if (app.files != null) .files else .grid)
		else
			.help,
		'j' => try move(app, 1),
		'k' => try move(app, -1),
		'h' => moveColumn(app, -1),
		'l' => moveColumn(app, 1),
		'g' => {
			if (app.focus == .sidebar) {
				app.selected = 0;
			} else {
				app.cursor_row = 0;
			}
		},
		'G' => {
			if (app.focus == .sidebar) {
				const count = app.visibleCount();
				app.selected = if (count == 0) 0 else count - 1;
			} else {
				app.cursor_row = if (app.rows.items.len == 0) 0 else app.rows.items.len - 1;
			}
		},
		'n' => try movePage(app, 1),
		'p' => try movePage(app, -1),
		'/' => try ask(app, .filter, " /"),
		's' => try app.openEditor(),
		':' => try ask(app, .command, " :"),
		'd', 't' => {
			app.view = .grid;
			if (app.current()) |object| {
				try app.openTable(object.name);
				app.focus = .main;
			}
		},
		'S' => {
			if (!app.hasTable()) {
				if (app.current()) |object| {
					try app.openTable(object.name);
				}
			}
			app.view = .structure;
		},
		'm' => app.view = if (app.view == .messages) .grid else .messages,
		'r' => {
			try app.loadObjects();
			try app.reload();
			app.say("reloaded", .{});
		},
		'o' => try sort(app),
		'e' => try edit(app),
		'v' => {
			if (app.focus == .main and app.rows.items.len > 0) {
				app.detail = true;
			}
		},
		'x' => try app.deleteRows(),
		' ' => try app.toggleMark(),
		'i' => try app.openRowForm(.insert),
		'y' => try app.openRowForm(.clone),
		'w' => try app.openColumnForm(),
		'W' => try app.openFilterForm(),
		'c' => try app.openTableForm(false),
		'a' => try app.openTableForm(true),
		'I' => try app.openIndexForm(),
		'K' => try app.openForeignKeyForm(),
		'V' => try app.openViewForm(),
		'T' => try app.openTriggerForm(),
		'N' => try app.openRenameForm(),
		'Y' => try app.openCopyForm(),
		'F' => try app.openSearchForm(),
		'E' => try app.openExportForm(),
		'M' => try app.openImportForm(),
		'O' => app.view = .connections,
		'f' => try app.openFiles(),
		'#' => try app.openSchemaForm(),
		'b' => app.view = if (app.view == .info) .grid else .info,
		'L' => app.view = if (app.view == .relations) .grid else .relations,
		'D' => try drop(app),
		'X' => try truncate(app),
		'C' => {
			app.prefix = 'C';
			app.say("copy: c value   r row   p page as CSV   s last SQL", .{});
		},
		else => {},
	}
}

fn move(app: *App, delta: i32) !void {
	if (app.focus == .sidebar) {
		const count = app.visibleCount();
		if (count == 0) {
			return;
		}
		app.selected = step(app.selected, delta, count);
		return;
	}
	if (app.rows.items.len == 0) {
		return;
	}
	// Stepping past the end of a page turns to the next one.
	if (delta > 0 and app.cursor_row + 1 >= app.rows.items.len and app.page + 1 < app.pages()) {
		app.cursor_row = 0;
		app.row_scroll = 0;
		try movePage(app, 1);
		return;
	}
	if (delta < 0 and app.cursor_row == 0 and app.page > 0) {
		try movePage(app, -1);
		app.cursor_row = if (app.rows.items.len == 0) 0 else app.rows.items.len - 1;
		return;
	}
	app.cursor_row = step(app.cursor_row, delta, app.rows.items.len);
}

fn moveColumn(app: *App, delta: i32) void {
	if (app.focus == .sidebar) {
		app.focus = if (delta > 0) .main else .sidebar;
		return;
	}
	if (app.cols.items.len == 0) {
		return;
	}
	if (delta < 0 and app.cursor_col == 0) {
		app.focus = .sidebar;
		return;
	}
	// Step over the columns the user hid.
	var next = app.cursor_col;
	while (true) {
		const moved = step(next, delta, app.cols.items.len);
		if (moved == next) {
			break;
		}
		next = moved;
		if (!app.isHidden(next)) {
			break;
		}
	}
	app.cursor_col = next;
}

fn movePage(app: *App, delta: i32) !void {
	if (!app.hasTable()) {
		return;
	}
	const pages = app.pages();
	if (delta > 0 and app.page + 1 < pages) {
		app.page += 1;
	} else if (delta < 0 and app.page > 0) {
		app.page -= 1;
	} else {
		return;
	}
	try app.reload();
}

fn step(value: usize, delta: i32, count: usize) usize {
	if (count == 0) {
		return 0;
	}
	if (delta < 0) {
		return if (value == 0) 0 else value - 1;
	}
	return if (value + 1 >= count) count - 1 else value + 1;
}

fn open(app: *App) !void {
	if (app.focus == .sidebar) {
		if (app.current()) |object| {
			try app.openTable(object.name);
			app.focus = .main;
		}
		return;
	}
	if (app.rows.items.len > 0) {
		try app.openRowForm(.edit);
	}
}

/// Drop the selected object, whatever it is, through the engine's own DDL.
fn drop(app: *App) !void {
	const object = app.current() orelse return;
	var sql: std.ArrayListUnmanaged(u8) = .empty;
	defer sql.deinit(app.allocator);
	try app.conn.ddl().dropObject(
		&sql,
		app.allocator,
		if (std.mem.eql(u8, object.kind, "view")) .view else .table,
		.{ .schema = app.schema.items, .name = object.name },
	);
	try app.confirm(std.mem.trimEnd(u8, sql.items, ";\n"), "drop");
}

fn truncate(app: *App) !void {
	const table = app.currentTable() orelse return;
	var sql: std.ArrayListUnmanaged(u8) = .empty;
	defer sql.deinit(app.allocator);
	try app.conn.ddl().truncate(&sql, app.allocator, table);
	try app.confirm(std.mem.trimEnd(u8, sql.items, ";\n"), "empty");
}

fn sort(app: *App) !void {
	if (!app.hasTable() or app.cursor_col >= app.cols.items.len) {
		return;
	}
	const column = app.cols.items[app.cursor_col];
	if (app.order) |current| {
		if (std.mem.eql(u8, current, column)) {
			if (!app.descending) {
				app.descending = true;
			} else {
				app.allocator.free(current);
				app.order = null;
				app.descending = false;
			}
			try app.reload();
			return;
		}
		app.allocator.free(current);
	}
	app.order = try app.allocator.dupe(u8, column);
	app.descending = false;
	app.page = 0;
	try app.reload();
}

fn edit(app: *App) !void {
	if (app.focus != .main or app.cursor_row >= app.rows.items.len or app.cols.items.len == 0) {
		return;
	}
	if (!app.hasTable()) {
		app.complain("a query result cannot be edited - open the table itself", .{});
		return;
	}
	if (!app.editable) {
		app.complain("these rows cannot be addressed, so they are read-only", .{});
		return;
	}
	try ask(app, .edit, " value: ");
	const cell = app.rows.items[app.cursor_row].cells[app.cursor_col];
	if (cell.kind != .nul) {
		try app.prompt.?.buffer.appendSlice(app.allocator, cell.text);
	}
}

/// The two panes. Everything here acts on the pane the cursor is in, and `tab`
/// is what moves the cursor to the other one - which is the whole of what makes
/// copying between two places one keystroke.
fn onFiles(app: *App, key: Key) !void {
	const manager = app.files orelse {
		app.view = .grid;
		return;
	};
	const pane = manager.here();
	switch (key) {
		.ctrl => |code| switch (code) {
			'c' => app.quit = true,
			'd' => pane.move(10),
			'u' => pane.move(-10),
			else => {},
		},
		.tab, .back_tab => manager.swap(),
		.up => pane.move(-1),
		.down => pane.move(1),
		.page_up => pane.move(-20),
		.page_down => pane.move(20),
		.home => pane.selected = 0,
		.end => pane.selected = pane.entries.len -| 1,
		.enter, .right => _ = try manager.enter(),
		.backspace, .left => try manager.up(),
		.escape => app.closeFiles(),
		.char => |point| switch (point) {
			'q' => app.closeFiles(),
			'j' => pane.move(1),
			'k' => pane.move(-1),
			'l' => _ = try manager.enter(),
			'h' => try manager.up(),
			'g' => pane.selected = 0,
			'G' => pane.selected = pane.entries.len -| 1,
			' ' => {
				try pane.toggleMark(app.allocator, pane.selected);
				pane.move(1);
			},
			'c' => try app.copyFiles(),
			'x' => try askRemove(app),
			'n' => try ask(app, .new_dir, " new directory: "),
			'/' => try ask(app, .go_to, " go to: "),
			'r' => try askRename(app),
			'R' => {
				manager.reload();
				app.say("reloaded", .{});
			},
			'?' => app.view = .help,
			else => {},
		},
		else => {},
	}
}

/// Removing a tree is the one thing here that cannot be undone, so it says how
/// much is going before it asks.
fn askRemove(app: *App) !void {
	const manager = app.files orelse return;
	const pane = manager.here();
	const count = if (pane.marked.items.len != 0) pane.marked.items.len else @as(usize, 1);
	const one = pane.current() orelse return;
	if (pane.marked.items.len == 0 and std.mem.eql(u8, one.name, "..")) {
		return;
	}
	try ask(app, .remove_files, " type y to remove: ");
	if (pane.marked.items.len == 0) {
		app.say("remove {s}{s}?", .{ one.name, if (one.kind == .dir) " and everything in it" else "" });
	} else {
		app.say("remove {d} marked?", .{count});
	}
}

fn askRename(app: *App) !void {
	const manager = app.files orelse return;
	const one = manager.here().current() orelse return;
	if (std.mem.eql(u8, one.name, "..")) {
		return;
	}
	try ask(app, .rename_file, " rename to: ");
	try app.prompt.?.buffer.appendSlice(app.allocator, one.name);
}

fn ask(app: *App, kind: PromptKind, label: []const u8) !void {
	if (app.prompt) |*old| {
		old.buffer.deinit(app.allocator);
	}
	app.prompt = .{ .kind = kind, .label = label };
	if (kind == .filter and app.filter.items.len > 0) {
		try app.prompt.?.buffer.appendSlice(app.allocator, app.filter.items);
	}
}

fn close(app: *App) void {
	if (app.prompt) |*prompt| {
		prompt.buffer.deinit(app.allocator);
	}
	app.prompt = null;
}

fn typing(app: *App, key: Key) !void {
	const prompt = &app.prompt.?;
	switch (key) {
		.escape => {
			if (prompt.kind == .filter) {
				app.filter.clearRetainingCapacity();
				app.selected = 0;
			}
			close(app);
		},
		.enter => {
			const kind = prompt.kind;
			// The buffer is owned by the prompt, so copy before closing.
			const line = try app.allocator.dupe(u8, prompt.buffer.items);
			defer app.allocator.free(line);
			close(app);
			switch (kind) {
				.filter => {},
				.password => try app.connectWithPassword(line),
				.confirm => {
					if (line.len != 0 and (line[0] == 'y' or line[0] == 'Y')) {
						try app.runPending();
					} else {
						app.say("left alone", .{});
						app.clearPending();
					}
				},
				.command => try app.command(line),
				.edit => try app.saveCell(line),
				.new_dir => if (line.len != 0) try app.makeFileDir(line),
				.go_to => if (line.len != 0) try app.goToPath(line),
				.rename_file => if (line.len != 0) try app.renameFile(line),
				.remove_files => {
					if (line.len != 0 and (line[0] == 'y' or line[0] == 'Y')) {
						try app.deleteFiles();
					} else {
						app.say("left alone", .{});
					}
				},
				.remove_rows => {
					if (line.len != 0 and (line[0] == 'y' or line[0] == 'Y')) {
						try app.deleteRowsNow();
					} else {
						app.say("left alone", .{});
					}
				},
			}
		},
		.backspace => {
			if (prompt.buffer.items.len > 0) {
				// Remove a whole codepoint, not a byte.
				var cut = prompt.buffer.items.len - 1;
				while (cut > 0 and prompt.buffer.items[cut] & 0xc0 == 0x80) {
					cut -= 1;
				}
				prompt.buffer.shrinkRetainingCapacity(cut);
				try refilter(app);
			}
		},
		.ctrl => |name| switch (name) {
			'c' => close(app),
			'u' => {
				prompt.buffer.clearRetainingCapacity();
				try refilter(app);
			},
			else => {},
		},
		.up, .down => {
			if (app.history.items.len == 0) {
				return;
			}
			const last = app.history.items.len - 1;
			const at = switch (key) {
				.up => if (prompt.history_at) |value| (if (value == 0) 0 else value - 1) else last,
				else => if (prompt.history_at) |value| (if (value >= last) last else value + 1) else last,
			};
			prompt.history_at = at;
			prompt.buffer.clearRetainingCapacity();
			try prompt.buffer.appendSlice(app.allocator, app.history.items[at]);
		},
		.char => |point| {
			var buf: [4]u8 = undefined;
			const len = std.unicode.utf8Encode(point, &buf) catch return;
			try prompt.buffer.appendSlice(app.allocator, buf[0..len]);
			try refilter(app);
		},
		.tab => {
			if (prompt.kind == .edit) {
				try prompt.buffer.append(app.allocator, ' ');
			}
		},
		else => {},
	}
}

/// The object filter applies as it is typed.
fn refilter(app: *App) !void {
	const prompt = app.prompt orelse return;
	if (prompt.kind != .filter) {
		return;
	}
	app.filter.clearRetainingCapacity();
	try app.filter.appendSlice(app.allocator, prompt.buffer.items);
	app.selected = 0;
	app.scroll = 0;
}

test "a match says which letters it landed on" {
	const hit = paletteHit(blk: {
		var found: [actions.len]usize = undefined;
		_ = paletteMatches("expo", &found);
		break :blk found[0];
	}, "expo");
	try std.testing.expectEqualStrings("export", actions[blk: {
		var found: [actions.len]usize = undefined;
		_ = paletteMatches("expo", &found);
		break :blk found[0];
	}].label);
	try std.testing.expect(hit.len == 4);
	try std.testing.expect(hit.has(0) and hit.has(1) and hit.has(2) and hit.has(3));
}

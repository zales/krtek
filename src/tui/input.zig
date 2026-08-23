//! Key handling. A prompt swallows everything while it is open; otherwise the
//! keys act on whichever pane has focus.

const std = @import("std");
const app_mod = @import("app.zig");
const fuzzy = @import("fuzzy.zig");
const term = @import("term.zig");
const database = @import("db");
const draw = @import("draw.zig");

const App = app_mod.App;
const Key = term.Key;
const Prompt = app_mod.Prompt;
const PromptKind = app_mod.PromptKind;

pub fn handle(app: *App, key: Key, size: term.Size) !void {
	// Not a key press at all: the follow timer. It is never input, so it is taken
	// before everything below that swallows keys - a prefix waiting for its second
	// key must not be spent on it, and neither must a form field.
	if (key == .tick) {
		app.followTick();
		return;
	}
	if (app.typing.prompt != null) {
		try typing(app, key);
		return;
	}
	if (app.typing.form != null) {
		switch (app.typing.form.?.handle(key)) {
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
	if (app.typing.editor != null) {
		try onEditor(app, key);
		return;
	}
	if (app.typing.prefix) |pending| {
		app.typing.prefix = null;
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
	if (app.view == .object) {
		try onObject(app, key);
		return;
	}
	if (app.view == .help and scrollHelp(app, key)) {
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
			} else if (app.sidebar.filter.items.len > 0) {
				app.sidebar.filter.clearRetainingCapacity();
				app.sidebar.selected = 0;
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
				app.sidebar.selected = 0;
			} else {
				app.cursor.row = 0;
			}
		},
		.end => {
			if (app.focus == .sidebar) {
				const count = app.visibleCount();
				app.sidebar.selected = if (count == 0) 0 else count - 1;
			} else {
				app.cursor.row = if (app.grid.rows.items.len == 0) 0 else app.grid.rows.items.len - 1;
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
	.{ .key = 'R', .label = "follow the table", .also = "auto reload refresh tail watch live new rows messages kafka" },
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

	// And one whose whole point is a word nobody would guess the key for.
	count = paletteMatches("tail", &found);
	try std.testing.expect(count >= 1);
	try std.testing.expectEqualStrings("follow the table", actions[found[0]].label);

	try std.testing.expect(paletteMatches("zzz", &found) == 0);
}

/// Keys while the SQL editor is open. Everything that is not a command inserts
/// itself, which is what makes it an editor rather than a prompt.
fn onEditor(app: *App, key: Key) !void {
	const editor = &app.typing.editor.?;
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
	const count = app.saved.list.items.items.len;
	switch (key) {
		.ctrl => |code| if (code == 'c') {
			app.quit = true;
		},
		.char => |point| switch (point) {
			'q' => app.quit = true,
			'a' => try app.openConnectionForm(false),
			'e' => try app.openConnectionForm(true),
			'd' => try app.forgetSaved(),
			'j' => if (count != 0 and app.saved.at + 1 < count) {
				app.saved.at += 1;
			},
			'k' => if (app.saved.at > 0) {
				app.saved.at -= 1;
			},
			'?' => openHelp(app),
			else => {},
		},
		.down => if (count != 0 and app.saved.at + 1 < count) {
			app.saved.at += 1;
		},
		.up => if (app.saved.at > 0) {
			app.saved.at -= 1;
		},
		.enter => try app.connectSaved(),
		.escape => if (app.connected) {
			app.view = .grid;
		},
		.mouse => |mouse| {
			// The list starts on the fifth row of the panel.
			if (mouse.button == .left and mouse.row >= 4 and mouse.row - 4 < count) {
				app.saved.at = mouse.row - 4;
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
		const at = app.sidebar.scroll + (mouse.row - 2);
		if (at < app.visibleCount()) {
			app.sidebar.selected = at;
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
	const row = app.cursor.row_scroll + (mouse.row - 3);
	if (row < app.grid.rows.items.len) {
		app.cursor.row = row;
	}
	// Walk the visible columns to find which one the click landed in.
	var x: usize = side;
	var index = app.cursor.col_scroll;
	var seen: usize = 0;
	while (index < app.grid.cols.items.len) : (index += 1) {
		if (app.isHidden(index)) {
			continue;
		}
		const w = @min(@max(app.grid.widths.items[index], 3), app.grid.text_limit) + 1;
		if (mouse.col >= x and mouse.col < x + w) {
			app.cursor.col = index;
			break;
		}
		x += w;
		seen += 1;
		if (x > size.cols) {
			break;
		}
	}
}

/// Open the key map at the top. It is scrolled, so coming back to it halfway
/// down where it was left would be a puzzle rather than a memory.
fn openHelp(app: *App) void {
	app.view = .help;
	app.help.scroll = 0;
}

/// Moving about the key map. It is longer than a terminal is tall, and what did
/// not fit simply was not drawn before this - so these keys take precedence over
/// what they do elsewhere, and everything else falls through to where it always
/// went: ? still closes the map and ctrl+k still opens the palette.
///
/// The scroll is only ever moved here; it is clamped where it is drawn, which is
/// the one place that knows how many lines there were.
fn scrollHelp(app: *App, key: Key) bool {
	const page: i32 = @intCast(@max(1, app.help.page));
	const whole: i32 = @intCast(draw.HELP.len);
	const by: i32 = switch (key) {
		.char => |point| switch (point) {
			'j' => 1,
			'k' => -1,
			'n' => page,
			'p' => -page,
			'g' => -whole,
			'G' => whole,
			' ' => page,
			else => return false,
		},
		.down => 1,
		.up => -1,
		.page_down => page,
		.page_up => -page,
		.ctrl => |code| switch (code) {
			'd' => page,
			'u' => -page,
			else => return false,
		},
		.mouse => |mouse| switch (mouse.button) {
			.wheel_down => 3,
			.wheel_up => -3,
			else => return false,
		},
		else => return false,
	};
	if (by < 0) {
		app.help.scroll -|= @intCast(-by);
	} else {
		app.help.scroll +|= @intCast(by);
	}
	return true;
}

/// The keys that write a schema statement. They are refused together, because an
/// engine that has no schema anybody writes has none of them - and each of these
/// otherwise opens a form to be filled in before the engine says no.
const SCHEMA_KEYS = [_]u21{ 'c', 'a', 'I', 'K', 'V', 'T', 'N', 'Y', 'X', 'D' };

fn letter(app: *App, point: u21, size: term.Size) !void {
	_ = size;
	if (std.mem.indexOfScalar(u21, &SCHEMA_KEYS, point) != null) {
		const refused = app.conn.caps().no_ddl;
		if (refused.len != 0) {
			app.complain("{s}", .{refused});
			return;
		}
	}
	switch (point) {
		'q' => app.quit = true,
		'?' => if (app.view == .help) {
			// Back to wherever the question was asked from, which is the file
			// manager when that is what is open.
			app.view = if (app.files != null) .files else .grid;
		} else {
			openHelp(app);
		},
		'j' => try move(app, 1),
		'k' => try move(app, -1),
		'h' => moveColumn(app, -1),
		'l' => moveColumn(app, 1),
		'g' => {
			if (app.focus == .sidebar) {
				app.sidebar.selected = 0;
			} else {
				app.cursor.row = 0;
			}
		},
		'G' => {
			if (app.focus == .sidebar) {
				const count = app.visibleCount();
				app.sidebar.selected = if (count == 0) 0 else count - 1;
			} else {
				app.cursor.row = if (app.grid.rows.items.len == 0) 0 else app.grid.rows.items.len - 1;
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
		'R' => try toggleFollow(app),
		'o' => try sort(app),
		'e' => try edit(app),
		'v' => {
			if (app.focus == .main and app.grid.rows.items.len > 0) {
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
			app.typing.prefix = 'C';
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
		app.sidebar.selected = step(app.sidebar.selected, delta, count);
		return;
	}
	if (app.grid.rows.items.len == 0) {
		return;
	}
	// Stepping past the end of a page turns to the next one.
	if (delta > 0 and app.cursor.row + 1 >= app.grid.rows.items.len and app.grid.page + 1 < app.pages()) {
		app.cursor.row = 0;
		app.cursor.row_scroll = 0;
		try movePage(app, 1);
		return;
	}
	if (delta < 0 and app.cursor.row == 0 and app.grid.page > 0) {
		try movePage(app, -1);
		app.cursor.row = if (app.grid.rows.items.len == 0) 0 else app.grid.rows.items.len - 1;
		return;
	}
	app.cursor.row = step(app.cursor.row, delta, app.grid.rows.items.len);
}

fn moveColumn(app: *App, delta: i32) void {
	if (app.focus == .sidebar) {
		app.focus = if (delta > 0) .main else .sidebar;
		return;
	}
	if (app.grid.cols.items.len == 0) {
		return;
	}
	if (delta < 0 and app.cursor.col == 0) {
		app.focus = .sidebar;
		return;
	}
	// Step over the columns the user hid.
	var next = app.cursor.col;
	while (true) {
		const moved = step(next, delta, app.grid.cols.items.len);
		if (moved == next) {
			break;
		}
		next = moved;
		if (!app.isHidden(next)) {
			break;
		}
	}
	app.cursor.col = next;
}

/// `r` reads the table once; this keeps reading it. The view stays at the end,
/// which is where an append lands, so a Kafka topic can be watched filling up
/// instead of being asked about again and again.
fn toggleFollow(app: *App) !void {
	if (app.follow.ms != 0) {
		app.setFollow(0);
		app.say("no longer following", .{});
		return;
	}
	try app.startFollowing();
}

fn movePage(app: *App, delta: i32) !void {
	if (!app.hasTable()) {
		return;
	}
	const pages = app.pages();
	if (delta > 0 and app.grid.page + 1 < pages) {
		app.grid.page += 1;
	} else if (delta < 0 and app.grid.page > 0) {
		app.grid.page -= 1;
	} else {
		return;
	}
	// Having turned a page, the user is asking to look somewhere other than the
	// end, and the next tick would drag the view straight back: the following
	// stops instead.
	if (app.follow.ms != 0) {
		app.setFollow(0);
		app.say("no longer following", .{});
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
	if (app.grid.rows.items.len == 0) {
		return;
	}
	// A row the engine has more to say about opens on what it has to say. Where
	// it has nothing, opening a row is editing it, which is what enter has always
	// done here.
	if (try app.openRow()) {
		return;
	}
	try app.openRowForm(.edit);
}

/// The object screen: what the engine said can be done, and moving about what it
/// said. Its keys are the engine's, so they are matched before anything else -
/// and everything unmatched does nothing rather than something surprising.
fn onObject(app: *App, key: Key) !void {
	switch (key) {
		.escape => {
			app.closeObject();
			return;
		},
		.char => |point| {
			if (point == 'q') {
				app.quit = true;
				return;
			}
			for (app.object.actions) |action| {
				if (action.key != point) {
					continue;
				}
				if (action.confirm) {
					try askAction(app, action);
				} else {
					try app.runObjectAction(action);
				}
				return;
			}
			switch (point) {
				'j' => app.object.scroll += 1,
				'k' => app.object.scroll -|= 1,
				'g' => app.object.scroll = 0,
				'G' => app.object.scroll = app.object.facts.len,
				'r' => _ = try app.openRow(),
				else => {},
			}
		},
		.down => app.object.scroll += 1,
		.up => app.object.scroll -|= 1,
		.page_down => app.object.scroll += 10,
		.page_up => app.object.scroll -|= 10,
		.mouse => |mouse| switch (mouse.button) {
			.wheel_down => app.object.scroll += 3,
			.wheel_up => app.object.scroll -|= 3,
			else => {},
		},
		.ctrl => |code| switch (code) {
			'c' => app.quit = true,
			'k', 'p' => try openPalette(app),
			else => {},
		},
		else => {},
	}
}

/// An action nothing takes back asks first, in the words the engine gave it.
fn askAction(app: *App, action: database.Action) !void {
	if (app.typing.prompt) |*old| {
		old.buffer.deinit(app.allocator);
	}
	app.typing.pending.clearRetainingCapacity();
	try app.typing.pending.appendSlice(app.allocator, action.statement);
	app.typing.prompt = .{ .kind = .confirm, .label = " type y to " };
	app.say("{s}?", .{action.label});
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
		.{ .schema = app.grid.schema.items, .name = object.name },
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
	if (!app.hasTable() or app.cursor.col >= app.grid.cols.items.len) {
		return;
	}
	const column = app.grid.cols.items[app.cursor.col];
	if (app.grid.order) |current| {
		if (std.mem.eql(u8, current, column)) {
			if (!app.grid.descending) {
				app.grid.descending = true;
			} else {
				app.allocator.free(current);
				app.grid.order = null;
				app.grid.descending = false;
			}
			try app.reload();
			return;
		}
		app.allocator.free(current);
	}
	app.grid.order = try app.allocator.dupe(u8, column);
	app.grid.descending = false;
	app.grid.page = 0;
	try app.reload();
}

fn edit(app: *App) !void {
	if (app.focus != .main or app.cursor.row >= app.grid.rows.items.len or app.grid.cols.items.len == 0) {
		return;
	}
	if (!app.hasTable()) {
		app.complain("a query result cannot be edited - open the table itself", .{});
		return;
	}
	if (!app.grid.editable) {
		app.complain("these rows cannot be addressed, so they are read-only", .{});
		return;
	}
	// Before the value is typed rather than after: on an engine that cannot
	// change a row, typing one in is time spent on an answer that was already no.
	const refused = app.conn.caps().no_update;
	if (refused.len != 0) {
		app.complain("{s}", .{refused});
		return;
	}
	try ask(app, .edit, " value: ");
	const cell = app.grid.rows.items[app.cursor.row].cells[app.cursor.col];
	if (cell.kind != .nul) {
		try app.typing.prompt.?.buffer.appendSlice(app.allocator, cell.text);
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
			'?' => openHelp(app),
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
	try app.typing.prompt.?.buffer.appendSlice(app.allocator, one.name);
}

fn ask(app: *App, kind: PromptKind, label: []const u8) !void {
	if (app.typing.prompt) |*old| {
		old.buffer.deinit(app.allocator);
	}
	app.typing.prompt = .{ .kind = kind, .label = label };
	if (kind == .filter and app.sidebar.filter.items.len > 0) {
		try app.typing.prompt.?.buffer.appendSlice(app.allocator, app.sidebar.filter.items);
	}
}

fn close(app: *App) void {
	if (app.typing.prompt) |*prompt| {
		prompt.buffer.deinit(app.allocator);
	}
	app.typing.prompt = null;
}

fn typing(app: *App, key: Key) !void {
	const prompt = &app.typing.prompt.?;
	switch (key) {
		.escape => {
			if (prompt.kind == .filter) {
				app.sidebar.filter.clearRetainingCapacity();
				app.sidebar.selected = 0;
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
	const prompt = app.typing.prompt orelse return;
	if (prompt.kind != .filter) {
		return;
	}
	app.sidebar.filter.clearRetainingCapacity();
	try app.sidebar.filter.appendSlice(app.allocator, prompt.buffer.items);
	app.sidebar.selected = 0;
	app.sidebar.scroll = 0;
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

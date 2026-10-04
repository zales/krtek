//! Key handling. A prompt swallows everything while it is open; otherwise the
//! keys act on whichever pane has focus.

const std = @import("std");
const app_mod = @import("app.zig");
const fuzzy = @import("fuzzy.zig");
const term = @import("term.zig");
const database = @import("db");
const dump_mod = @import("dump.zig");
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
        try onPalette(app, key);
        return;
    }
    if (app.typing.editor != null) {
        try onEditor(app, key);
        return;
    }
    // The tabs are above every screen, so the keys and the clicks that change
    // them are taken before any one screen gets to mean something else by them.
    if (try aboutTabs(app, key, size)) {
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
    // Nothing is open, and this is not the list of what could be: it is the key
    // map, which is the one other screen there is to be on. Everything further
    // down asks the connection something, so none of it is reached from here.
    if (!app.connected) {
        if (app.view == .help and scrollHelp(app, key)) {
            return;
        }
        switch (key) {
            .ctrl => |code| if (code == 'c') {
                app.quit = true;
            },
            .escape => app.view = .connections,
            .char => |point| switch (point) {
                'q' => app.quit = true,
                '?' => app.view = .connections,
                ':' => try ask(app, .command, " :"),
                else => {},
            },
            else => {},
        }
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
        // The keys that move inside the value, and everything else closes it.
        // Nothing under the box moves while it is open, so these mean the value
        // and nothing else.
        const last = app.detail_lines -| app.detail_page;
        switch (key) {
            .down => app.detail_at = @min(app.detail_at + 1, last),
            .up => app.detail_at -|= 1,
            .page_down => app.detail_at = @min(app.detail_at + app.detail_page, last),
            .page_up => app.detail_at -|= app.detail_page,
            .home => app.detail_at = 0,
            .end => app.detail_at = last,
            .char => |point| switch (point) {
                'j' => app.detail_at = @min(app.detail_at + 1, last),
                'k' => app.detail_at -|= 1,
                'n' => app.detail_at = @min(app.detail_at + app.detail_page, last),
                'p' => app.detail_at -|= app.detail_page,
                'g' => app.detail_at = 0,
                'G' => app.detail_at = last,
                else => app.detail = false,
            },
            .escape, .enter => app.detail = false,
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
            't' => try app.newTab(null),
            'w' => app.typing.prefix = WINDOW,
            'd', 'f' => try movePage(app, 1),
            'u', 'b' => try movePage(app, -1),
            'k', 'p' => try openPalette(app),
            'r' => try app.reload(),
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
        .char => |point| try letter(app, point),
        else => {},
    }
}

/// `ctrl+w`, waiting for the key after it: the prefix vi uses for windows.
const WINDOW: u21 = 0x17;

/// The keys and the clicks that are about the tabs themselves, whatever screen
/// is under them. True when the key was one of them.
fn aboutTabs(app: *App, key: Key, size: term.Size) !bool {
    switch (key) {
        .alt => |code| switch (code) {
            '1'...'9' => app.selectTab(code - '1'),
            't' => try app.newTab(null),
            'w' => if (app.tabCount() > 1) {
                app.closeTab(app.active_tab);
            },
            else => return false,
        },
        .mouse => |mouse| {
            if (mouse.row != 0 or mouse.button != .left or app.tabCount() < 2) {
                return false;
            }
            // Where each tab is, is the drawing's to say: this walks the same
            // strip it drew, so a click lands on what was under it.
            var strip = draw.TabStrip.init(app, size.cols);
            while (strip.next()) |piece| {
                if (mouse.col < piece.from or mouse.col >= piece.from + piece.width) {
                    continue;
                }
                if (piece.tab) |index| {
                    app.selectTab(index);
                } else {
                    try app.newTab(null);
                }
                break;
            }
        },
        else => return false,
    }
    return true;
}

/// What can be done, apart from moving about. A key does one of these and so
/// does a line of the palette, and both of them say which by naming it here -
/// the palette used to press the action's key instead, so giving a key a new
/// meaning quietly gave every action on that key the new meaning too.
pub const Does = enum {
    browse,
    structure,
    editor,
    search,
    filter_objects,
    filter_rows,
    columns,
    sort,
    reload,
    follow,
    insert,
    edit,
    clone,
    delete,
    mark,
    whole_value,
    create_table,
    alter_table,
    index,
    foreign_key,
    view,
    trigger,
    rename,
    copy_table,
    truncate,
    drop,
    export_rows,
    yank,
    import,
    info,
    relations,
    schema,
    connections,
    new_tab,
    next_tab,
    prev_tab,
    files,
    messages,
    help,
    command,
    quit,
};

/// Everything the app can do, with the key that does it. A key map has to be
/// remembered; this can be searched, so nothing is only discoverable by reading
/// the help. `needs` is the pane an action belongs to, and the palette moves
/// there before running it, so choosing "insert a row" from the object list does
/// what it says.
pub const Action = struct {
    /// How it is typed, written the way the palette shows it: one key, `g` and a
    /// second one, or a name like `space` and `ctrl+t` for the keys that have no
    /// letter. A key pressed in the grid is looked up here, so what the palette
    /// says and what the key does are the same line.
    keys: []const u8,
    does: Does,
    label: []const u8,
    /// Words to match on besides the label.
    also: []const u8 = "",
    needs: ?app_mod.Focus = null,
    /// What the engine has to be able to do for this to be worth offering. The
    /// palette used to offer all of it to all of them, so Redis - which has one
    /// table holding every key, and no SQL - was told it could write SQL, create
    /// a view and add a foreign key. The keys themselves refuse, but being
    /// refused after choosing something from a list of what you can do is a list
    /// that was lying.
    wants: Wants = .anything,
    /// What to call this where the engine has no SQL. The editor is the same key
    /// and the same panel on Redis, Kafka or a cluster - what it takes is that
    /// engine's own commands - so hiding it there would take away the console,
    /// and calling it "write and run SQL" was telling somebody to type something
    /// the engine has never heard of. Empty means the label is right either way.
    plain: []const u8 = "",

    pub const Wants = enum {
        anything,
        /// The editor and the search across tables, which are written as SQL.
        sql,
        /// Creating, altering, renaming, copying, emptying or dropping the object.
        ddl,
        /// An index, a view, a trigger or a foreign key.
        relations,
        inserting,
        editing,
        deleting,
        schemas,
        files,
    };
};

/// What this is called on this connection.
pub fn labelFor(action: Action, caps: ?database.Caps) []const u8 {
    if (caps) |allowed| {
        if (!allowed.speaks_sql and action.plain.len != 0) {
            return action.plain;
        }
    }
    return action.label;
}

/// Whether this is worth offering on this connection.
pub fn offered(action: Action, caps: database.Caps, has_files: bool) bool {
    return switch (action.wants) {
        .anything => true,
        .sql => caps.speaks_sql,
        .ddl => caps.no_ddl.len == 0,
        .relations => caps.no_ddl.len == 0 and caps.no_relations.len == 0,
        .inserting => caps.no_insert.len == 0,
        .editing => caps.no_update.len == 0,
        .deleting => caps.no_delete.len == 0,
        .schemas => caps.schemas or caps.databases,
        .files => has_files,
    };
}

/// The single letters are vi's wherever vi has one for the thing: `y` yanks,
/// `m` marks, `w` and `b` move by a column, `H` `M` `L` go to the top, middle
/// and bottom of the screen. What those letters did here before is on `g` and
/// the letter it used to be - `gm` for the messages `m` opened, `gv` for the
/// value `v` showed - which is one rule to remember rather than eight new keys.
pub const actions = [_]Action{
    .{ .keys = "d", .does = .browse, .label = "browse the selected table", .also = "data rows open select", .needs = .sidebar },
    .{ .keys = "S", .does = .structure, .label = "structure of the table", .also = "columns indexes keys schema create" },
    .{ .keys = "s", .does = .editor, .label = "write and run SQL", .plain = "write and run a command", .also = "query editor statement console" },
    .{ .keys = "F", .does = .search, .label = "search every table", .also = "find text grep", .wants = .sql },
    .{ .keys = "/", .does = .filter_objects, .label = "filter the object list", .also = "search find tables" },
    .{ .keys = "W", .does = .filter_rows, .label = "filter the rows", .also = "where condition" },
    .{ .keys = "gw", .does = .columns, .label = "choose visible columns", .also = "hide show" },
    .{ .keys = "o", .does = .sort, .label = "sort by this column", .also = "order asc desc" },
    .{ .keys = "r", .does = .reload, .label = "reload", .also = "refresh again" },
    .{ .keys = "R", .does = .follow, .label = "follow the table", .also = "auto reload refresh tail watch live new rows messages kafka" },
    .{ .keys = "i", .does = .insert, .label = "insert a row", .also = "new add", .needs = .main, .wants = .inserting },
    .{ .keys = "e", .does = .edit, .label = "edit the row", .also = "change update", .needs = .main, .wants = .editing },
    .{ .keys = "gy", .does = .clone, .label = "clone the row", .also = "copy duplicate", .needs = .main, .wants = .inserting },
    .{ .keys = "x", .does = .delete, .label = "delete the marked rows", .also = "remove", .needs = .main, .wants = .deleting },
    .{ .keys = "space", .does = .mark, .label = "mark the row", .also = "select tick visual v", .needs = .main },
    .{ .keys = "gv", .does = .whole_value, .label = "show the whole value", .also = "detail full text", .needs = .main },
    .{ .keys = "c", .does = .create_table, .label = "create a table", .also = "new", .wants = .ddl },
    .{ .keys = "a", .does = .alter_table, .label = "alter the table", .also = "change columns modify", .wants = .ddl },
    .{ .keys = "I", .does = .index, .label = "add an index", .also = "unique primary key", .wants = .relations },
    .{ .keys = "K", .does = .foreign_key, .label = "add a foreign key", .also = "reference relation", .wants = .relations },
    .{ .keys = "gV", .does = .view, .label = "create a view", .also = "new", .wants = .relations },
    .{ .keys = "T", .does = .trigger, .label = "create a trigger", .also = "new", .wants = .relations },
    .{ .keys = "N", .does = .rename, .label = "rename the table", .also = "move", .wants = .ddl },
    .{ .keys = "Y", .does = .copy_table, .label = "copy the table", .also = "duplicate", .wants = .ddl },
    .{ .keys = "X", .does = .truncate, .label = "empty the table", .also = "truncate delete all", .wants = .ddl },
    .{ .keys = "D", .does = .drop, .label = "drop the table", .also = "delete remove", .wants = .ddl },
    .{ .keys = "E", .does = .export_rows, .label = "export", .also = "dump sql csv save" },
    .{ .keys = "y", .does = .yank, .label = "copy to the clipboard", .also = "yank value row page csv sql" },
    .{ .keys = "gM", .does = .import, .label = "import", .also = "load sql csv file", .wants = .inserting },
    .{ .keys = "gb", .does = .info, .label = "database information", .also = "settings pragmas size version" },
    .{ .keys = "gL", .does = .relations, .label = "list every relation", .also = "objects tables views indexes" },
    .{ .keys = "#", .does = .schema, .label = "switch schema", .also = "namespace search path", .wants = .schemas },
    .{ .keys = "O", .does = .connections, .label = "connections", .also = "open connect database server saved" },
    .{ .keys = "ctrl+t", .does = .new_tab, .label = "new tab", .also = "create open workspace tabnew" },
    .{ .keys = "]", .does = .next_tab, .label = "next tab", .also = "switch forward gt tabnext" },
    .{ .keys = "[", .does = .prev_tab, .label = "previous tab", .also = "switch back gT tabprev" },
    .{ .keys = "f", .does = .files, .label = "browse the files", .also = "copy upload download transfer sftp s3 azure manager", .wants = .files },
    .{ .keys = "gm", .does = .messages, .label = "messages", .also = "log reports errors" },
    .{ .keys = "?", .does = .help, .label = "help: the whole key map", .also = "keys shortcuts" },
    .{ .keys = ":", .does = .command, .label = "a command", .also = "limit text vacuum analyze check" },
    .{ .keys = "q", .does = .quit, .label = "quit", .also = "exit close" },
};

/// The action a key, or two, belongs to.
fn actionTyped(keys: []const u8) ?Action {
    for (actions) |action| {
        if (std.mem.eql(u8, action.keys, keys)) {
            return action;
        }
    }
    return null;
}

/// The action that does this. There is exactly one, which a test holds it to.
pub fn actionThat(does: Does) Action {
    for (actions) |action| {
        if (action.does == does) {
            return action;
        }
    }
    unreachable;
}

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
            if (std.ascii.findIgnoreCase(action.label, word) != null) {
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
    return paletteFor(query, null, false, out);
}

/// The same, on a connection: what the engine cannot do is not offered. `null`
/// caps means every action, which is what the tests want and what the palette
/// shows before anything is open.
pub fn paletteFor(query: []const u8, caps: ?database.Caps, has_files: bool, out: *[actions.len]usize) usize {
    var scores: [actions.len]u16 = undefined;
    var count: usize = 0;
    for (actions, 0..) |action, i| {
        if (caps) |allowed| {
            if (!offered(action, allowed, has_files)) {
                continue;
            }
        }
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

    // What a key used to do is still found by saying what it is.
    for ([_][]const u8{ "whole value", "visible columns", "clone", "import", "messages", "database info", "create a view", "every relation" }) |wanted| {
        try std.testing.expect(paletteMatches(wanted, &found) >= 1);
    }

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

/// Keys while the editor is open. It has vi's two modes: in insert mode a key
/// is the character on it, which is what makes this an editor rather than a
/// prompt, and in normal mode it is a command.
fn onEditor(app: *App, key: Key) !void {
    switch (key) {
        // Escape and a key, arriving together. A terminal that does not speak
        // the kitty protocol - and tmux in front of any terminal - sends alt+j as
        // escape followed by j, so escape followed quickly by j is read as alt+j.
        // In an editor with modes that pair is typed all day, so it is taken
        // apart again: dropping it loses both keys, and the mode with them.
        .alt => |code| switch (code) {
            // Except with a digit. A digit means nothing after escape here - no
            // command takes a count - so the two together can only have been alt,
            // and alt and a digit is the tab with that number: the editor stays
            // as it is, in the tab it is in, and the other one comes forward.
            '1'...'9' => app.selectTab(code - '1'),
            else => {
                try editorKey(app, .escape);
                if (app.typing.editor != null) {
                    try editorKey(app, .{ .char = code });
                }
            },
        },
        else => try editorKey(app, key),
    }
}

fn editorKey(app: *App, key: Key) !void {
    const editor = &app.typing.editor.?;

    // The completion list, while it is open, takes the keys that move in it. Any
    // other key closes it and then means what it always means.
    if (editor.completing()) {
        switch (key) {
            .tab, .down => return editor.nextCandidate(1),
            .back_tab, .up => return editor.nextCandidate(-1),
            .enter => return editor.take(editor.candidate_at),
            .escape => return editor.closeCompletion(),
            else => editor.closeCompletion(),
        }
    }

    if (editor.mode == .insert) {
        switch (key) {
            .escape => editor.leaveInsert(),
            .ctrl => |code| switch (code) {
                's' => try app.runEditor(),
                'c' => editor.leaveInsert(),
                'u' => editor.clear(),
                'w' => editor.deleteWord(),
                'p' => try app.editorHistory(-1),
                'n' => try app.editorHistory(1),
                'a' => editor.home(),
                'e' => editor.end(),
                else => {},
            },
            .tab => try app.completeInEditor(),
            .enter => try editor.insert("\n"),
            .backspace => editor.backspace(),
            .delete => editor.delete(),
            .left => editor.left(),
            .right => editor.right(),
            .up => editor.up(),
            .down => editor.down(),
            .home => editor.home(),
            .end => editor.end(),
            .char => |point| {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(point, &buf) catch return;
                try editor.insert(buf[0..len]);
            },
            else => {},
        }
        return;
    }

    // Normal mode. A command half typed - a `d` waiting to hear what to delete -
    // is abandoned by anything that is not its second key, rather than left to
    // take the next letter typed after an arrow key or a page of scrolling.
    if (key != .char and key != .escape) {
        editor.pending_op = null;
    }
    switch (key) {
        .ctrl => |code| switch (code) {
            's' => try app.runEditor(),
            'c' => app.closeEditor(),
            'd' => {
                var steps: usize = 0;
                while (steps < 10) : (steps += 1) editor.down();
            },
            'u' => {
                var steps: usize = 0;
                while (steps < 10) : (steps += 1) editor.up();
            },
            'r' => editor.redo(),
            else => {},
        },
        .escape => {
            // A command half typed is what escape abandons first. With none, it
            // puts the editor away - and what was in it is kept for the next time
            // it opens, because escape twice is how anybody makes sure of being in
            // normal mode and that cannot be what loses a statement.
            if (editor.pending_op != null) {
                editor.pending_op = null;
            } else {
                app.closeEditor();
            }
        },
        .enter => try app.runEditor(),
        .char => |point| {
            if (editor.pending_op) |op| {
                editor.pending_op = null;
                switch (op) {
                    'd' => switch (point) {
                        'd' => editor.deleteLine(),
                        'w' => editor.deleteWordForward(),
                        '$' => editor.deleteToEndOfLine(),
                        else => {},
                    },
                    'y' => switch (point) {
                        'y' => editor.yankLine(),
                        else => {},
                    },
                    'c' => switch (point) {
                        'c' => editor.changeLine(),
                        'w' => editor.changeWord(),
                        '$' => editor.changeToEndOfLine(),
                        else => {},
                    },
                    'g' => switch (point) {
                        'g' => editor.top(),
                        else => {},
                    },
                    else => {},
                }
                return;
            }

            switch (point) {
                'i' => editor.enterInsert(),
                'a' => editor.append(),
                'I' => {
                    editor.firstNonBlank();
                    editor.enterInsert();
                },
                'A' => {
                    editor.end();
                    editor.enterInsert();
                },
                'o' => editor.openBelow(),
                'O' => editor.openAbove(),
                'x' => editor.deleteChar(),
                'D' => editor.deleteToEndOfLine(),
                'C' => editor.changeToEndOfLine(),
                's' => editor.substitute(),
                'h' => editor.leftOnLine(),
                'l' => editor.rightOnLine(),
                'j' => editor.down(),
                'k' => editor.up(),
                'w' => editor.wordForward(),
                'b' => editor.wordBackward(),
                'e' => editor.wordEnd(),
                '0' => editor.home(),
                '^' => editor.firstNonBlank(),
                '$' => editor.end(),
                'G' => editor.bottom(),
                'u' => editor.undo(),
                'p' => editor.pasteBelow(),
                'P' => editor.pasteAbove(),
                'd', 'y', 'c', 'g' => editor.pending_op = @intCast(point),
                ':' => try ask(app, .command, " :"),
                else => {},
            }
        },
        .left => editor.left(),
        .right => editor.right(),
        .up => editor.up(),
        .down => editor.down(),
        .home => editor.home(),
        .end => editor.end(),
        else => {},
    }
}

/// The second key of a two-key sequence. The footer lists what it can be, and
/// anything that is not on the list abandons the sequence - which is what
/// escape is for.
fn afterPrefix(app: *App, pending: u21, key: Key) !void {
    const point: u21 = switch (key) {
        .char => |typed| typed,
        // `z` and enter is vi's own spelling of `zt`.
        .enter => if (pending == 'z') 't' else return,
        .left => if (pending == WINDOW) 'h' else return,
        .right => if (pending == WINDOW) 'l' else return,
        .ctrl => |code| if (pending == WINDOW and code == 'w') 'w' else return,
        else => {
            if (pending == 'y') {
                app.say("nothing copied", .{});
            }
            return;
        },
    };
    switch (pending) {
        'y' => switch (point) {
            'c' => try dump_mod.copyCell(app),
            'r', 'y' => try dump_mod.copyRow(app),
            'p' => try dump_mod.copyPage(app),
            's' => try app.copyLastSql(),
            else => app.say("nothing copied", .{}),
        },
        'g' => switch (point) {
            'g' => {
                if (app.focus == .sidebar) {
                    app.sidebar.selected = 0;
                } else {
                    app.cursor.row = 0;
                }
            },
            't' => app.nextTab(),
            'T' => app.prevTab(),
            '1'...'9' => app.selectTab(point - '1'),
            // And what the letters did before vi's meanings took them: `gm` is
            // the messages `m` used to open. They are in the table of actions
            // like everything else that can be done.
            else => {
                var typed: [5]u8 = undefined;
                typed[0] = 'g';
                const len = std.unicode.utf8Encode(point, typed[1..]) catch return;
                if (actionTyped(typed[0 .. 1 + len])) |action| {
                    try perform(app, action.does);
                }
            },
        },
        'z' => {
            // Where on the screen the row under the cursor should be. The page
            // is the grid's own count of its rows, not the terminal's: those
            // differ by the lines above and below it.
            const page = @max(1, app.cursor.page);
            switch (point) {
                't' => app.cursor.row_scroll = app.cursor.row,
                'z', '.' => app.cursor.row_scroll = app.cursor.row -| (page / 2),
                'b', '-' => app.cursor.row_scroll = app.cursor.row -| (page - 1),
                else => {},
            }
        },
        'm' => if (point >= 'a' and point <= 'z') {
            app.setMark(@intCast(point));
        },
        '\'' => if (point >= 'a' and point <= 'z') {
            try app.jumpMark(@intCast(point));
        },
        WINDOW => switch (point) {
            'h' => app.focus = .sidebar,
            'l' => app.focus = .main,
            'w' => app.focus = if (app.focus == .sidebar) .main else .sidebar,
            'q', 'c' => {
                if (app.tabCount() > 1) {
                    app.closeTab(app.active_tab);
                } else if (app.view != .grid and app.connected) {
                    app.view = .grid;
                }
            },
            'o' => {
                app.closeOtherTabs();
                app.say("the other tabs are closed", .{});
            },
            't' => try app.newTab(null),
            ']', 'n' => app.nextTab(),
            '[', 'p' => app.prevTab(),
            else => {},
        },
        else => {},
    }
}

/// Keys while the palette is open.
fn onPalette(app: *App, key: Key) !void {
    const palette = &app.palette.?;
    var found: [actions.len]usize = undefined;
    const count = paletteFor(palette.query.items, if (app.connected) app.caps() else null, app.connected and app.conn.files() != null, &found);
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
            try perform(app, action.does);
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
    // What is on screen, which is not what is saved once a filter is on.
    const count = app.savedCount();
    switch (key) {
        .ctrl => |code| switch (code) {
            'c' => app.quit = true,
            't' => try app.newTab(null),
            'w' => app.typing.prefix = WINDOW,
            'd', 'f' => app.saved.at = @min(app.saved.at + app.saved.page(), count -| 1),
            'u', 'b' => app.saved.at -|= app.saved.page(),
            else => {},
        },
        .char => |point| switch (point) {
            'q' => app.quit = true,
            't' => try app.connectSavedInNewTab(),
            'a' => try app.openConnectionForm(false),
            'e' => try app.openConnectionForm(true),
            'r' => try app.toggleReadOnly(),
            '/' => try ask(app, .filter, " /"),
            ':' => try ask(app, .command, " :"),
            ']' => app.nextTab(),
            '[' => app.prevTab(),
            'd' => try app.forgetSaved(),
            'j' => if (count != 0 and app.saved.at + 1 < count) {
                app.saved.at += 1;
            },
            'k' => if (app.saved.at > 0) {
                app.saved.at -= 1;
            },
            'g' => app.saved.at = 0,
            'G' => app.saved.at = count -| 1,
            'H', '0', '^' => app.saved.at = 0,
            'M' => app.saved.at = count / 2,
            'L', '$' => app.saved.at = count -| 1,
            '?' => openHelp(app),
            else => {},
        },
        .down => if (count != 0 and app.saved.at + 1 < count) {
            app.saved.at += 1;
        },
        .up => if (app.saved.at > 0) {
            app.saved.at -= 1;
        },
        // A page is what is on screen, which the drawing worked out and left
        // behind - thirty connections are a lot of arrow keys otherwise.
        .page_down => app.saved.at = @min(app.saved.at + app.saved.page(), count -| 1),
        .page_up => app.saved.at -|= app.saved.page(),
        .home => app.saved.at = 0,
        .end => app.saved.at = count -| 1,
        .enter => try app.connectSaved(),
        .escape => {
            // The filter first, because the frame says `esc clears it` and a key
            // that leaves the screen instead would be answering a different
            // question from the one on the screen.
            if (app.saved.filter.items.len > 0) {
                app.saved.filter.clearRetainingCapacity();
                app.saved.at = 0;
                app.saved.scroll = 0;
            } else if (app.connected) {
                app.view = .grid;
            }
        },
        .mouse => |mouse| {
            // What is drawn on a row is the entry at that row *in view*, which stops
            // being the entry at that index in the list as soon as it scrolls.
            if (mouse.button == .left and mouse.row >= app_mod.CONNECTIONS_FIRST) {
                const at = app.saved.scroll + (mouse.row - app_mod.CONNECTIONS_FIRST);
                if (at < count) {
                    app.saved.at = at;
                    try app.connectSaved();
                }
            }
        },
        else => {},
    }
}

/// The mouse: the wheel scrolls whichever pane it is over, a click puts the
/// cursor where it landed. The layout has to be recomputed here, because the
/// drawing code is the only other place that knows it.
fn click(app: *App, mouse: term.Mouse, size: term.Size) !void {
    const side: usize = app_mod.sidebarWidth(size.cols);
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

/// Do one of the things in the table of actions, whichever way it was asked
/// for: by its key, or by its line in the palette.
fn perform(app: *App, does: Does) !void {
    // The ones that write a schema statement are refused together, because an
    // engine that has no schema anybody writes has none of them - and each of
    // these otherwise opens a form to be filled in before the engine says no.
    // The ones that write what hangs off an object are apart, because an engine
    // can have the first without the second: a Kafka topic is created and
    // dropped and has no indexes.
    const allowed = app.caps();
    const refused = switch (actionThat(does).wants) {
        .ddl => allowed.no_ddl,
        .relations => if (allowed.no_ddl.len != 0) allowed.no_ddl else allowed.no_relations,
        else => "",
    };
    if (refused.len != 0) {
        app.complain("{s}", .{refused});
        return;
    }
    switch (does) {
        .quit => app.quit = true,
        .help => if (app.view == .help) {
            // Back to wherever the question was asked from, which is the file
            // manager when that is what is open.
            app.view = if (app.files != null) .files else app.home();
        } else {
            openHelp(app);
        },
        .browse => {
            app.view = .grid;
            if (app.current()) |object| {
                try app.openTable(object.name);
                app.focus = .main;
            }
        },
        .structure => {
            if (!app.hasTable()) {
                if (app.current()) |object| {
                    try app.openTable(object.name);
                }
            }
            app.view = .structure;
        },
        .messages => app.view = if (app.view == .messages) .grid else .messages,
        .info => app.view = if (app.view == .info) .grid else .info,
        .relations => app.view = if (app.view == .relations) .grid else .relations,
        .connections => app.view = .connections,
        .reload => {
            try app.loadObjects();
            try app.reload();
            app.say("reloaded", .{});
        },
        .follow => try toggleFollow(app),
        .sort => try sort(app),
        .edit => try edit(app),
        .whole_value => {
            if (app.focus == .main and app.grid.rows.items.len > 0) {
                app.detail = true;
                // At the top of the value, not wherever the last one was left.
                app.detail_at = 0;
            }
        },
        .delete => try app.deleteRows(),
        .mark => try app.toggleMark(),
        .insert => try app.openRowForm(.insert),
        .clone => try app.openRowForm(.clone),
        .columns => try app.openColumnForm(),
        .filter_rows => try app.openFilterForm(),
        .filter_objects => try ask(app, .filter, " /"),
        .editor => try app.openEditor(),
        .command => try ask(app, .command, " :"),
        .create_table => try app.openTableForm(false),
        .alter_table => try app.openTableForm(true),
        .index => try app.openIndexForm(),
        .foreign_key => try app.openForeignKeyForm(),
        .view => try app.openViewForm(),
        .trigger => try app.openTriggerForm(),
        .rename => try app.openRenameForm(),
        .copy_table => try app.openCopyForm(),
        .search => try app.openSearchForm(),
        .export_rows => try dump_mod.openExportForm(
            app,
        ),
        .import => try dump_mod.openImportForm(
            app,
        ),
        .files => try app.openFiles(),
        .schema => try app.openSchemaForm(),
        .drop => try drop(app),
        .truncate => try truncate(app),
        .yank => {
            app.typing.prefix = 'y';
            app.say("copy: y the row   c the value   p the page as CSV   s the last SQL", .{});
        },
        .new_tab => try app.newTab(null),
        .next_tab => app.nextTab(),
        .prev_tab => app.prevTab(),
    }
}

/// The keys that move about rather than do something, which is why they are
/// not in the table of actions. A test holds the table to not taking one.
pub const MOVING = "jkhlwbgGHML0^$npz'`mtvVC";

/// A key in the grid or the object list. What it does is in the table of
/// actions if it does anything; what is left moves the cursor, or waits for a
/// second key.
fn letter(app: *App, point: u21) !void {
    var typed: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(point, &typed) catch return;
    if (actionTyped(typed[0..len])) |action| {
        return perform(app, action.does);
    }
    switch (point) {
        // The same thing under a second key.
        't' => try perform(app, .browse),
        ' ', 'v', 'V' => try perform(app, .mark),
        'C' => try perform(app, .yank),

        'j' => try move(app, 1),
        'k' => try move(app, -1),
        'h', 'b' => moveColumn(app, -1),
        'l', 'w' => moveColumn(app, 1),
        'G' => {
            if (app.focus == .sidebar) {
                const count = app.visibleCount();
                app.sidebar.selected = if (count == 0) 0 else count - 1;
            } else {
                app.cursor.row = if (app.grid.rows.items.len == 0) 0 else app.grid.rows.items.len - 1;
            }
        },
        // The top, the middle and the bottom of what is on screen. How much that
        // is, is what the drawing left behind: the grid's own rows, and however
        // many objects the list had room for between its headings.
        'H', 'M', 'L' => {
            if (app.focus == .sidebar) {
                const shown = @min(app.sidebar.shown, app.visibleCount() -| app.sidebar.scroll);
                app.sidebar.selected = app.sidebar.scroll + onScreen(point, shown);
            } else {
                const shown = @min(app.cursor.page, app.grid.rows.items.len -| app.cursor.row_scroll);
                app.cursor.row = app.cursor.row_scroll + onScreen(point, shown);
            }
        },
        // The first and the last column, of the ones that are shown.
        '0', '^' => if (app.focus == .main) {
            var at: usize = 0;
            while (at < app.grid.cols.items.len and app.isHidden(at)) : (at += 1) {}
            if (at < app.grid.cols.items.len) {
                app.cursor.col = at;
                app.cursor.col_scroll = 0;
            }
        },
        '$' => if (app.focus == .main) {
            var at = app.grid.cols.items.len;
            while (at > 0 and app.isHidden(at - 1)) : (at -= 1) {}
            if (at > 0) {
                app.cursor.col = at - 1;
            }
        },
        'n' => try movePage(app, 1),
        'p' => try movePage(app, -1),
        // And the keys that wait for another. The footer lists what it can be.
        'g', 'z', 'm' => app.typing.prefix = point,
        '\'', '`' => app.typing.prefix = '\'',
        else => {},
    }
}

/// How far down the screen `H`, `M` and `L` go, of `shown` lines.
fn onScreen(key: u21, shown: usize) usize {
    return switch (key) {
        'M' => shown / 2,
        'L' => shown -| 1,
        else => 0,
    };
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
    var sql: std.ArrayList(u8) = .empty;
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
    var sql: std.ArrayList(u8) = .empty;
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
    const refused = app.caps().no_update;
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
    // Before the question rather than after the answer: asking "remove this?" and
    // then refusing the yes is a worse way of saying no than saying it now.
    if (!app.mayWriteTo(pane.place)) {
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
    if (kind == .filter) {
        const was = if (app.view == .connections) app.saved.filter.items else app.sidebar.filter.items;
        if (was.len > 0) {
            try app.typing.prompt.?.buffer.appendSlice(app.allocator, was);
        }
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
                if (app.view == .connections) {
                    app.saved.filter.clearRetainingCapacity();
                    app.saved.at = 0;
                    app.saved.scroll = 0;
                } else {
                    app.sidebar.filter.clearRetainingCapacity();
                    app.sidebar.selected = 0;
                }
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
                .overwrite => {
                    if (line.len != 0 and (line[0] == 'y' or line[0] == 'Y')) {
                        try app.copyChosen();
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

/// The filter applies as it is typed - the object list on one screen, the
/// connection list on the other, since `/` means the same thing on both.
fn refilter(app: *App) !void {
    const prompt = app.typing.prompt orelse return;
    if (prompt.kind != .filter) {
        return;
    }
    if (app.view == .connections) {
        app.saved.filter.clearRetainingCapacity();
        try app.saved.filter.appendSlice(app.allocator, prompt.buffer.items);
        app.saved.at = 0;
        app.saved.scroll = 0;
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
    try std.testing.expectEqualStrings("export", actions[
        blk: {
            var found: [actions.len]usize = undefined;
            _ = paletteMatches("expo", &found);
            break :blk found[0];
        }
    ].label);
    try std.testing.expect(hit.len == 4);
    try std.testing.expect(hit.has(0) and hit.has(1) and hit.has(2) and hit.has(3));
}

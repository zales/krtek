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
const line_mod = @import("line.zig");
const Files = @import("files.zig");
const picker_mod = @import("picker.zig");

const App = app_mod.App;
const C = app_mod.C;
const SIDEBAR = app_mod.SIDEBAR;
/// How many key hints the connection list draws under itself.
const HINTS: usize = 9;
const Size = term.Size;

// The widest a single column may get; :text changes it.

pub fn frame(app: *App, size: Size) !void {
    const screen = app.screen;
    screen.begin();
    // Set again by whatever is being typed into, if anything is.
    app.typing.cursor = null;

    const body_rows = if (size.rows > 3) size.rows - 3 else 1;
    // The file manager takes the whole width: two panes and a sidebar on eighty
    // columns would leave neither pane a name to show.
    // The key map is a reference, not a place to be while browsing: it gets the
    // whole width, the way the connection list and the two panes do, because a
    // sidebar there costs a quarter of every description.
    const side = if (app.view != .connections and app.view != .files and app.view != .help)
        app_mod.sidebarWidth(size.cols)
    else
        0;

    header(app, size);
    if (app.view == .connections) {
        connections(app, size, body_rows);
        if (app.typing.form != null) {
            try formPanel(app, size, 0, body_rows);
        }
        if (app.palette != null) {
            palettePanel(app, size, body_rows);
        }
        if (app.picker != null) {
            pickerPanel(app, size, body_rows);
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
        .object => objectScreen(app, size, side, body_rows),
        .files => files(app, size, body_rows),
        .connections => {},
    }
    if (app.typing.form != null) {
        try formPanel(app, size, side, body_rows);
    }
    if (app.typing.editor != null and (!app.typing.docked or app.view == .grid)) {
        editorPanel(app, size, side, body_rows);
    }
    if (app.detail) {
        try detail(app, size, side, body_rows);
    }
    if (app.palette != null) {
        palettePanel(app, size, body_rows);
    }
    if (app.picker != null) {
        pickerPanel(app, size, body_rows);
    }
    status(app, size);
    promptLine(app, size);

    try cursorAndFlush(app, size);
}

/// Park the cursor where the user is typing, then put the frame on screen.
fn cursorAndFlush(app: *App, size: Size) !void {
    const screen = app.screen;
    _ = size;
    if (app.typing.cursor) |spot| {
        // A form's field, the palette's query, the editor's text or the prompt
        // along the bottom: whichever of them drew itself last said where the
        // typing is, and the prompt is drawn last of all.
        screen.cursorAt(spot.row, spot.col, spot.block);
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
    // The read-only column is only there when something is marked, and when it is,
    // the panel grows by its width rather than taking it from the targets - which
    // are what people read this list for.
    var marked: usize = 0;
    for (app.saved.list.items.items, 0..) |item, i| {
        marked += @intFromBool(item.read_only and app.savedMatches(i));
    }
    const guard: usize = if (marked != 0) 10 else 0;
    // Two columns narrower than the screen, so that a form drawn over this one -
    // which insets itself by one on each side - lands on exactly the same columns
    // instead of one inside them, which drew both frames side by side.
    const width: usize = @min(size.cols -| 2, 74 + guard);
    const left = if (size.cols > width) (size.cols - width) / 2 else 0;
    const top: usize = app_mod.CONNECTIONS_FIRST - 1;
    // Whether there is room for the keys as well as a list worth looking at.
    const roomy = rows > app_mod.CONNECTIONS_FIRST + HINTS + 5;
    // Declared here rather than beside where they are drawn, because how much room
    // the list gets is worked out from how many of these there are.
    const hints = [_][2][]const u8{
        .{ "enter", "connect to the one selected" },
        .{ "a", "add a connection" },
        .{ "e / x", "edit, remove" },
        .{ "r", "read-only: nothing is written through it" },
        .{ "/", "narrow the list by name, host or port" },
        .{ "up down", "move in the list" },
        .{ "pgup pgdn", "a page at a time; home end for the ends" },
        .{ "q", "quit" },
    };

    var line: usize = top + 1;

    if (app.savedCount() == 0) {
        screen.moveTo(line, left);
        screen.style(.{ .fg = C.dim });
        _ = write(app, if (app.saved.filter.items.len != 0)
            "  Nothing matches."
        else
            "  Nothing saved yet.", width);
        line += 2;
    } else {
        const count = app.savedCount();
        // What the list has to leave room for is the line saying where in it this
        // is, the keys, and the frame's own last row. Not the notes under them:
        // those are read once and the list is the work, so on a window too short
        // for both it is the notes that give way - they draw only if there is
        // still room, which on a window with a short list there is.
        //
        // And on a window too short even for the keys, the keys give way as well.
        // Eight lines of them on a sixteen-row terminal left two rows for the list
        // itself, which is the wrong way round on the screen whose whole purpose
        // is the list - and the strip along the bottom of the terminal names every
        // one of those keys anyway.
        const below = 1 + (if (roomy) hints.len else 0) + 1;
        const page = if (rows > top + below) rows - top - below else 1;
        // Follow the cursor, by the least that brings it back into view - so a step
        // down scrolls by one and does not jump the list under somebody's eyes.
        var scroll = @min(app.saved.scroll, count -| 1);
        if (app.saved.at < scroll) {
            scroll = app.saved.at;
        } else if (app.saved.at >= scroll + page) {
            scroll = app.saved.at - page + 1;
        }
        app.saved.scroll = scroll;
        app.saved.shown = page;

        for (scroll..count) |i| {
            if (line >= top + 1 + page) {
                break;
            }
            const item = app.saved.list.items.items[app.savedIndex(i) orelse break];
            const on = i == app.saved.at;
            screen.moveTo(line, left);
            screen.style(.{ .bg = if (on) C.selected else null, .fg = if (on) C.accent else C.text, .bold = on });
            _ = write(app, if (on) "  > " else "    ", width);
            // One column narrower than the space it sits in, so a name long enough
            // to be clipped still has air between it and the next column.
            pad(app, item.name, 21, false);
            _ = write(app, " ", 1);
            screen.style(.{ .bg = if (on) C.selected else null, .fg = if (on) C.dim else C.faint });
            pad(app, item.engine(), 11, false);
            // Where the password is kept says itself, rather than the file being the
            // only place to find that out - and a connection that came from
            // somewhere else says that in the same column, because both answer
            // "where does this live".
            screen.style(.{
                .bg = if (on) C.selected else null,
                .fg = if (item.found) (if (on) C.dim else C.faint) else if (item.keeps == .file) C.warn else C.ok,
            });
            pad(app, if (item.found) "kubeconfig" else item.keeps.label(), 11, false);
            // The row where this is not empty is the one somebody needs to see
            // before pressing enter: a production database in a list of local ones.
            if (guard != 0) {
                screen.style(.{
                    .bg = if (on) C.selected else null,
                    .fg = if (item.read_only) C.warn else (if (on) C.dim else C.faint),
                });
                pad(app, if (item.read_only) "read-only" else "", guard, false);
            }
            screen.style(.{ .bg = if (on) C.selected else null, .fg = if (on) C.text else C.dim });
            // 4 for the marker, 22 name, 11 engine, 11 for where the thing lives,
            // and the guard column when the list has anything to put in it.
            const room = if (width > 50 + guard) width - 50 - guard else 0;
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
        // What is above and below, because a list that scrolls without saying so
        // looks like a list that has ended.
        if (count > page) {
            screen.moveTo(line, left);
            screen.style(.{ .fg = C.faint });
            var strip: [64]u8 = undefined;
            const text = std.mem.print(&strip, "    {d}-{d} of {d}", .{
                scroll + 1,
                @min(scroll + page, count),
                count,
            }) catch "";
            _ = write(app, text, width);
            screen.clearToEol();
        }
        line += 1;
    }

    for (hints) |entry| {
        if (!roomy or line > rows) {
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
        // Inside the frame, not up to it: these ran into the right-hand border and
        // lost their last few words to it.
        _ = write(app, "    a file opens SQLite, or a .csv as a table; a URL opens its engine", width -| 2);
        line += 1;
        screen.moveTo(line, left);
        screen.style(.{ .fg = C.faint });
        _ = write(app, "    file keeps the password in plain text; keychain lets macOS guard it", width -| 2);
        line += 1;
    }
    if (line <= rows and app.saved.path.items.len != 0) {
        screen.moveTo(line, left);
        // Where the list is kept - or, while something in it has not reached
        // the file, that it is not. The status line says so once and is then
        // written over by whatever happens next; this is still here when
        // somebody comes back to the list to find out why a connection is gone.
        const lead = if (app.saved.unwritten) "    not written to " else "    saved in ";
        screen.style(.{ .fg = if (app.saved.unwritten) C.danger else C.faint });
        _ = write(app, lead, width -| 2);
        _ = write(app, app.saved.path.items, width -| (lead.len + 6));
        line += 1;
    }
    screen.reset();
    // Never past the last row there is. The list is sized to leave room for
    // everything below it, but on a window too short to hold even that, what has
    // to give is the bottom of the list rather than the frame around it: a panel
    // whose last line is off the screen reads as one that goes on forever.
    const bottom = @min(line, rows);
    // The filter goes in the frame, because once it is typed and the prompt has
    // closed nothing else on the screen says why two thirds of the list is gone.
    var narrowed: [64]u8 = undefined;
    const hint = if (app.saved.filter.items.len != 0)
        std.mem.print(&narrowed, "/{s}   esc clears it", .{app.saved.filter.items}) catch ""
    else
        "";
    box(app, top, left, width, bottom + 1 - top, "connect to a database", hint, C.accent);
}

fn header(app: *App, size: Size) void {
    const screen = app.screen;
    screen.moveTo(0, 0);
    screen.style(.{ .bg = C.bar, .fg = C.text, .bold = true });
    var used: usize = 0;
    used += write(app, " krtek ", size.cols);

    if (app.tabCount() > 1) {
        var strip = TabStrip.init(app, size.cols);
        while (strip.next()) |piece| {
            const front = if (piece.tab) |index| index == app.active_tab else false;
            screen.style(.{
                .bg = if (front) C.selected else C.bar,
                .fg = if (front) C.accent else if (piece.tab == null) C.faint else C.dim,
                .bold = front,
            });
            used += write(app, piece.text, size.cols -| used);
        }
    }
    var buf: [96]u8 = undefined;
    const right = if (app.connected)
        std.mem.print(&buf, "{s}  {d} objects ", .{ app.conn.version(), app.sidebar.objects.items.len }) catch ""
    else
        "no connection ";
    const right_width = term.width(right);
    if (app.tabCount() <= 1) {
        // What is open, and its end where all of it does not fit: a path is
        // told from the next one by the file it ends in and a server by its
        // database, and the line used to keep the beginning - `/private/tmp/…`
        // for every file under there, with the name of none of them.
        screen.style(.{ .bg = C.bar, .fg = C.accent });
        const what = if (app.connected) app.conn.describe() else "";
        const marked: usize = if (app.connected and app.read_only) 11 else 0;
        const room = size.cols -| used -| right_width -| marked -| 2;
        if (term.width(what) <= room or room < 8) {
            used += write(app, what, size.cols -| used);
        } else {
            used += write(app, "…", 1);
            used += write(app, endOf(what, room - 1), room - 1);
        }
    }

    // Beside the name of the connection, because that is what it is about - and
    // in the colour that means "mind this", since the rest of the screen says so
    // only by the keys it stops offering.
    if (app.connected and app.read_only) {
        screen.style(.{ .bg = C.bar, .fg = C.warn, .bold = true });
        used += write(app, "  read-only", size.cols -| used);
    }
    screen.style(.{ .bg = C.bar, .fg = C.dim });
    if (size.cols > used + right_width) {
        fill(app, ' ', size.cols -| used -| right_width);
        _ = write(app, right, right_width);
    } else {
        fill(app, ' ', if (size.cols > used) size.cols - used else 0);
    }
    screen.reset();
}

/// The tabs along the top line: which of them there is room for, what each one
/// says and where it is.
///
/// Here rather than written out twice, because the drawing and the mouse have
/// to agree about it - the same reason the connection list's first row is a
/// constant. Both walk this, so a click lands on the tab that was drawn there
/// however many there are and however narrow the window is.
pub const TabStrip = struct {
    app: *App,
    /// How much of its title a tab shows. They all get the same, and less each
    /// as there are more of them.
    room: usize,
    index: usize,
    /// One past the last tab there is room for.
    last: usize,
    x: usize = NAME.len,
    added: bool = false,
    text: [128]u8 = undefined,

    const NAME = " krtek ";
    const PLUS = " [+] ";
    /// The widest a title gets, and the narrowest before tabs are left out.
    const WIDEST = 20;
    const NARROWEST = 4;

    pub const Piece = struct {
        /// Which tab this is, or null for the `[+]` that opens another.
        tab: ?usize,
        text: []const u8,
        from: usize,
        width: usize,
    };

    pub fn init(app: *App, cols: usize) TabStrip {
        const count = app.tabCount();
        // What is to the right of the tabs - the version and the count of
        // objects - keeps its place, as it did when there was only a name here.
        const span = cols -| 24 -| NAME.len -| PLUS.len;
        // A space, the number, a colon and a space in front of the title and a
        // space after it.
        const around: usize = if (count > 9) 6 else 5;
        var room: usize = WIDEST;
        while (room > NARROWEST and count * (around + room) > span) {
            room -= 1;
        }
        // Still too many: as many as fit, and the one in front is one of them.
        const fit = @max(1, span / (around + room));
        const first = if (app.active_tab >= fit) app.active_tab + 1 - fit else 0;
        return .{ .app = app, .room = room, .index = first, .last = @min(count, first + fit) };
    }

    pub fn next(self: *TabStrip) ?Piece {
        if (self.index < self.last) {
            const title = term.fit(self.app.tabTitle(self.index), self.room).text;
            const text = std.mem.print(&self.text, " {d}: {s} ", .{ self.index + 1, title }) catch " ? ";
            const piece = Piece{ .tab = self.index, .text = text, .from = self.x, .width = term.width(text) };
            self.index += 1;
            self.x += piece.width;
            return piece;
        }
        if (self.added) {
            return null;
        }
        self.added = true;
        return .{ .tab = null, .text = PLUS, .from = self.x, .width = PLUS.len };
    }
};

/// Whether the object at `n` is the first of its group among what is visible.
/// The filter can hide the one that used to start a group, so this is asked of
/// the list as it is now rather than of the engine's own order.
fn startsGroup(app: *App, n: usize) bool {
    const object = app.visibleAt(n) orelse return false;
    if (n == 0) {
        return true;
    }
    const before = app.visibleAt(n - 1) orelse return true;
    return !std.mem.eql(u8, before.group, object.group);
}

/// How many heading lines fall between two objects, which is how much less room
/// there is for the objects themselves.
fn headingsBetween(app: *App, from: usize, to: usize) usize {
    var count: usize = 0;
    var n = from;
    while (n <= to) : (n += 1) {
        if (startsGroup(app, n)) {
            count += 1;
        }
    }
    return count;
}

fn sidebar(app: *App, width: usize, rows: usize) void {
    const screen = app.screen;
    const visible = app.visibleCount();
    // Keep the selection on screen. Scrolling counts objects, not lines - a
    // heading is drawn where the group changes and takes a line of its own, so
    // the room for objects is what is left after those.
    const list_rows = if (rows > 1) rows - 1 else 1;
    if (app.sidebar.selected < app.sidebar.scroll) {
        app.sidebar.scroll = app.sidebar.selected;
    }
    const headings = headingsBetween(app, app.sidebar.scroll, app.sidebar.selected);
    const room = if (list_rows > headings) list_rows - headings else 1;
    if (app.sidebar.selected >= app.sidebar.scroll + room) {
        app.sidebar.scroll = app.sidebar.selected - room + 1;
    }

    screen.moveTo(1, 0);
    screen.style(.{ .fg = C.dim });
    if (app.typing.prompt != null and app.typing.prompt.?.kind == .filter) {
        _ = write(app, " filter: ", width);
        screen.style(.{ .fg = C.accent });
        _ = write(app, app.typing.prompt.?.buffer.items, width -| 9);
    } else if (app.sidebar.filter.items.len > 0) {
        _ = write(app, " /", width);
        screen.style(.{ .fg = C.accent });
        _ = write(app, app.sidebar.filter.items, width -| 2);
    } else if (app.grid.schema.items.len != 0) {
        // The engine's own word for it, and the key that changes it out at the
        // right - the same way the filter header shows the `/` that made it, and
        // the palette puts a key beside every action it lists. A header that says
        // what it is and not how to change it is where the key goes to be missed.
        // Upper case, because the other two headings this line can carry are.
        var shouted: [24]u8 = undefined;
        const noun = app.caps().schema_noun;
        const heading = std.ascii.upperString(&shouted, noun[0..@min(noun.len, shouted.len)]);
        var used: usize = write(app, " ", width);
        screen.style(.{ .fg = C.dim });
        used += write(app, heading, width -| used -| 3);
        used += write(app, " ", width -| used -| 2);
        screen.style(.{ .fg = C.accent });
        used += write(app, app.grid.schema.items, width -| used -| 2);
        if (width > used + 1) {
            screen.style(.{ .fg = C.faint });
            fill(app, ' ', width -| used -| 2);
            _ = write(app, "#", 1);
        }
    } else {
        _ = write(app, " TABLES & VIEWS", width);
    }
    screen.clearToEol();

    if (visible == 0) {
        screen.moveTo(2, 1);
        screen.style(.{ .fg = C.faint, .italic = true });
        _ = write(app, if (app.sidebar.filter.items.len > 0) "nothing matches" else "no tables yet", width - 1);
        if (app.sidebar.filter.items.len == 0) {
            screen.moveTo(3, 1);
            _ = write(app, "c creates one", width -| 1);
        }
        screen.reset();
    }
    // Below what was just said, where nothing is listed: the lines under the
    // list are blanked further down, and these two were among them - so a
    // database with nothing in it had an empty list and no word about `c`.
    var line: usize = if (visible != 0) 2 else if (app.sidebar.filter.items.len > 0) 3 else 4;
    var n = app.sidebar.scroll;
    while (line < rows + 1 and n < visible) : ({
        line += 1;
        n += 1;
    }) {
        const object = app.visibleAt(n) orelse break;
        // A heading where the group changes, and none at all for an engine that
        // does not sort its objects into any.
        if (object.group.len != 0 and startsGroup(app, n)) {
            if (line + 1 >= rows + 1) {
                break;
            }
            screen.moveTo(line, 0);
            screen.style(.{ .fg = C.faint });
            _ = write(app, " ", 1);
            _ = write(app, object.group, width -| 1);
            screen.clearToEol();
            line += 1;
        }
        const selected = n == app.sidebar.selected;
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
        used += writeMatched(app, object.name, app.filterHit(object.name), width -| used -| 8, base);
        var buf: [24]u8 = undefined;
        const count = if (object.rows) |value|
            std.mem.print(&buf, "{d} ", .{value}) catch " "
        else
            "? ";
        const count_width = term.width(count);
        if (width > used + count_width) {
            fill(app, ' ', width -| used -| count_width);
            screen.style(.{ .bg = if (selected) C.selected else null, .fg = if (selected) C.dim else C.faint });
            _ = write(app, count, count_width);
        }
        screen.reset();
        screen.clearToEol();
    }
    // How many there was room for, which the keys that go to the middle and the
    // bottom of the screen cannot work out without the headings.
    app.sidebar.shown = n - app.sidebar.scroll;
    // Blank the rest of the sidebar.
    while (line < rows + 1) : (line += 1) {
        screen.moveTo(line, 0);
        screen.clearToEol();
    }
    // The rule between the panes, in the accent colour on the side that has the
    // keyboard - the cheapest way to show focus without a frame around each pane.
    var i: usize = 1;
    while (i < rows + 1) : (i += 1) {
        screen.moveTo(i, width -| 1);
        screen.style(.{ .fg = if (app.focus == .sidebar) C.accent else C.faint });
        screen.put(if (app.focus == .sidebar) "┃" else "│");
    }
    screen.reset();
}

/// Which columns the grid shows on this frame, and how wide each one is.
pub const Layout = struct {
    columns: []const usize, // indexes into app.grid.cols
    widths: []const usize,
    /// The first of them is held where it is while the others scroll under it.
    pinned: bool = false,
    /// How many columns there are to show, and which of them the ones that
    /// scroll are: from `first`, up to but not including `last`.
    shown: usize = 0,
    first: usize = 0,
    last: usize = 0,
};

/// How wide a column is drawn, before whatever is left over is handed out.
fn columnWidth(app: *App, index: usize) usize {
    return @min(@max(app.grid.widths.items[index], 3), app.grid.text_limit);
}

pub fn layout(app: *App, available: usize, columns: []usize, widths: []usize) Layout {
    // Hidden columns take no part in the layout at all.
    var shown: usize = 0;
    for (0..app.grid.cols.items.len) |i| {
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
        if (index == app.cursor.col) {
            at = n;
        }
    }
    if (at < app.cursor.col_scroll) {
        app.cursor.col_scroll = at;
    }
    while (true) {
        // The first column stays where it is once the others have scrolled: it
        // is the key far more often than not, and a row of values with nothing
        // to say whose they are is a row to scroll back from. Not where it
        // would take more than a third of the room - a first column that wide
        // is the text, and holding it leaves nowhere for the rest.
        const first_width = columnWidth(app, columns[0]);
        const pinned = app.cursor.col_scroll > 0 and (first_width + 1) * 3 <= available;
        const room = if (pinned) available - (first_width + 1) else available;
        var used: usize = 0;
        var last = app.cursor.col_scroll;
        while (last < shown) {
            const w = columnWidth(app, columns[last]);
            if (used + w + 1 > room and last > app.cursor.col_scroll) {
                break;
            }
            used += w + 1;
            last += 1;
        }
        if (at < last or app.cursor.col_scroll + 1 >= shown) {
            var n: usize = 0;
            if (pinned) {
                widths[0] = first_width;
                n = 1;
            }
            var i = app.cursor.col_scroll;
            while (i < last and n < widths.len) : ({
                i += 1;
                n += 1;
            }) {
                columns[n] = columns[i];
                widths[n] = columnWidth(app, columns[i]);
            }
            // Whatever is left over goes to the last column, up to what it would
            // have taken without a clip. `text_limit` is there to stop one wide
            // column pushing the others off the screen - it has nothing to say
            // about room nobody else wants, and a pod's log in a 44-column strip
            // with half a screen of nothing beside it is what that came to.
            if (n != 0) {
                var used_now: usize = 0;
                for (widths[0..n]) |w| {
                    used_now += w + 1;
                }
                if (used_now < available) {
                    const natural = @max(app.grid.widths.items[columns[n - 1]], 3);
                    const spare = available - used_now;
                    widths[n - 1] += @min(spare, natural -| widths[n - 1]);
                }
            }
            return .{
                .columns = columns[0..n],
                .widths = widths[0..n],
                .pinned = pinned,
                .shown = shown,
                .first = app.cursor.col_scroll,
                .last = last,
            };
        }
        app.cursor.col_scroll += 1;
    }
}

/// Which column of the grid is drawn at this place across the screen, if one
/// is. The mouse asks, and is answered from the layout the drawing used - the
/// two were worked out apart before, and stopped agreeing as soon as the last
/// column was given the room nobody else wanted.
pub fn columnAt(app: *App, size: Size, x: usize) ?usize {
    const side = app_mod.sidebarWidth(size.cols);
    if (x < side or size.cols <= side + 1) {
        return null;
    }
    var indexes: [128]usize = undefined;
    var widths: [128]usize = undefined;
    const plan = layout(app, size.cols - side - 1, &indexes, &widths);
    var from: usize = side;
    for (plan.widths, 0..) |w, n| {
        if (x >= from and x < from + w + 1) {
            return plan.columns[n];
        }
        from += w + 1;
    }
    return null;
}

/// How many rows at the top of the grid the editor takes while it sits over its
/// own result: the statement, up to five lines of it, in its frame. None where
/// that would leave fewer than five rows of the result - on a window that short
/// the result is what was asked for, and `s` still goes back to the statement.
pub fn dockedRows(app: *App, rows: usize) usize {
    if (!app.typing.docked or app.view != .grid) {
        return 0;
    }
    const editor = &(app.typing.editor orelse return 0);
    // A usize, spelled out: `@min` with a literal gives back a type that only
    // holds the literal, and the sum after it does not fit.
    const lines: usize = @min(editor.lineCount(), 5);
    const height = lines + 2;
    // The grid's own two lines, and five rows of what was asked for.
    return if (rows < height + 7) 0 else height;
}

fn grid(app: *App, size: Size, side: usize, rows: usize) void {
    const screen = app.screen;
    const left = side;
    const width = size.cols -| left;
    // Lower by as much as the statement above it takes, when one is there.
    const down = dockedRows(app, rows);

    // Title line: table, paging, sort.
    screen.moveTo(1 + down, left);
    screen.style(.{ .fg = C.accent, .bold = true });
    var used: usize = write(app, " ", width) + write(app, app.grid.title.items, width -| 2);
    screen.style(.{ .fg = C.dim });
    var buf: [160]u8 = undefined;
    const first: usize = if (app.grid.rows.items.len == 0) 0 else app.firstRow();
    var counted: [24]u8 = undefined;
    const total = if (app.grid.counted)
        std.mem.print(&counted, "{d}", .{app.grid.total}) catch "?"
    else
        "?";
    const summary = std.mem.print(&buf, "  {d}-{d} of {s}   page {d}/{d}{s}{s}{s}", .{
        first,
        app.firstRow() - 1 + app.grid.rows.items.len,
        total,
        app.grid.page + 1,
        app.pages(),
        if (app.grid.order != null) "   order " else "",
        if (app.grid.order) |column| column else "",
        if (app.grid.order != null and app.grid.descending) " desc" else "",
    }) catch "";
    used += write(app, summary, width -| used);
    if (app.follow.ms != 0) {
        // In green, the colour of something going well: this is the one thing on
        // the line that is still happening, and it should be seen without being
        // read.
        screen.style(.{ .fg = C.ok, .bold = true });
        var every: [24]u8 = undefined;
        const text = std.mem.print(&every, "   following {d:.1}s", .{
            @as(f64, @floatFromInt(app.follow.ms)) / 1000.0,
        }) catch "   following";
        used += write(app, text, width -| used);
        screen.style(.{ .fg = C.dim });
    }
    if (!app.grid.editable and app.grid.rows.items.len > 0) {
        screen.style(.{ .fg = C.faint });
        used += write(app, "   read-only", width -| used);
    }
    if (app.cursor.marked.items.len != 0) {
        // However many of them are on this page. A ticked row on another page
        // is still ticked, and `x` still means it: the count is what says so
        // when none of them is in sight.
        screen.style(.{ .fg = C.warn, .bold = true });
        var ticked: [32]u8 = undefined;
        const text = std.mem.print(&ticked, "   {d} marked", .{app.cursor.marked.items.len}) catch "   marked";
        used += write(app, text, width -| used);
    }
    screen.clearToEol();

    var indexes: [128]usize = undefined;
    var widths: [128]usize = undefined;
    const plan = layout(app, width -| 1, &indexes, &widths);

    // Which columns these are, where they are not all of them: at the right of
    // the title line, with an arrow on the side there are more. A table of
    // thirty columns looked like a table of five until `l` was held down.
    if (plan.first > 0 or plan.last < plan.shown) {
        var which: [48]u8 = undefined;
        const text = std.mem.print(&which, "columns {d}-{d} of {d}", .{ plan.first + 1, plan.last, plan.shown }) catch "";
        const w = term.width(text) + 5;
        if (text.len != 0 and width > used + w + 2) {
            screen.moveTo(1 + down, left + width - w);
            screen.style(.{ .fg = C.accent, .bold = true });
            _ = write(app, if (plan.first > 0) "‹ " else "  ", 2);
            screen.style(.{ .fg = C.dim });
            _ = write(app, text, w);
            screen.style(.{ .fg = C.accent, .bold = true });
            _ = write(app, if (plan.last < plan.shown) " › " else "   ", 3);
        }
    }

    // Header row.
    screen.moveTo(2 + down, left);
    screen.style(.{ .bg = C.bar, .fg = C.dim, .bold = true });
    var x: usize = 0;
    for (plan.widths, 0..) |w, n| {
        const index = plan.columns[n];
        const sorted = app.grid.order != null and std.mem.eql(u8, app.grid.order.?, app.grid.cols.items[index]);
        if (plan.pinned and n == 1) {
            screen.style(.{ .bg = C.bar, .fg = C.faint });
            screen.put("│");
        } else {
            screen.put(" ");
        }
        screen.style(.{ .bg = C.bar, .fg = if (sorted) C.accent else C.dim, .bold = true });
        pad(app, app.grid.cols.items[index], w, false);
        x += w + 1;
    }
    screen.style(.{ .bg = C.bar });
    if (width > x) {
        fill(app, ' ', width -| x);
    }
    screen.reset();

    // Rows.
    const list_rows = if (rows > 2 + down) rows - 2 - down else 1;
    app.cursor.page = list_rows;
    if (app.cursor.row < app.cursor.row_scroll) {
        app.cursor.row_scroll = app.cursor.row;
    }
    if (app.cursor.row >= app.cursor.row_scroll + list_rows) {
        app.cursor.row_scroll = app.cursor.row - list_rows + 1;
    }
    var line: usize = 3 + down;
    var r = app.cursor.row_scroll;
    while (line < rows + 1) : (line += 1) {
        screen.moveTo(line, left);
        if (r >= app.grid.rows.items.len) {
            screen.reset();
            screen.clearToEol();
            continue;
        }
        const row = app.grid.rows.items[r];
        const on_row = r == app.cursor.row and app.focus == .main;
        // A ticked row is in the colour that means "mind this" from end to end,
        // with the sign the file panes put on theirs in front of it: a tick that
        // could not be seen was a row waiting to be deleted by surprise.
        const marked = app.isMarked(r);
        for (plan.widths, 0..) |w, n| {
            const index = plan.columns[n];
            if (index >= row.cells.len) {
                break;
            }
            const cell = row.cells[index];
            const on_cell = on_row and index == app.cursor.col;
            // What `/` is looking for, underlined wherever it is on screen.
            const hit = app.hasFound(r, index);
            const style: term.Style = .{
                .bg = if (on_cell) C.accent else if (on_row) C.selected else null,
                .fg = if (on_cell) 16 else if (marked) C.warn else cell.colour(),
                .italic = cell.kind == .nul,
                .bold = (marked or hit) and !on_cell,
                .underline = hit,
                .underline_colour = if (hit and !on_cell) C.warn else null,
            };
            if (plan.pinned and n == 1) {
                // The rule between the column that stays and the ones that move.
                screen.style(.{ .bg = if (on_row) C.selected else null, .fg = C.faint });
                screen.put("│");
                screen.style(style);
            } else {
                var lead = style;
                lead.underline = false;
                screen.style(lead);
                screen.put(if (marked and n == 0) "*" else " ");
                screen.style(style);
            }
            if (cell.marks.len != 0) {
                const bg: ?u8 = if (on_cell) C.accent else if (on_row) C.selected else null;
                marks(app, cell.marks, w, bg, on_cell);
            } else {
                pad(app, cell.text, w, cell.kind == .int or cell.kind == .float);
            }
        }
        screen.reset();
        screen.clearToEol();
        r += 1;
    }
    if (app.grid.rows.items.len == 0) {
        screen.moveTo(4 + down, left + 2);
        screen.style(.{ .fg = C.faint });
        // An empty table and a filter that matches nothing look the same on
        // screen, so say which one it is and what undoes it.
        const filtered = app.isFiltered();
        // And a table that could not be read is neither: the status line has
        // the reason, and an invitation to insert a row is not what goes here.
        // With a filter on it the filter may be the reason, so that is still
        // what is offered.
        _ = write(app, if (app.grid.failed and filtered)
            "could not be read - W changes the filter, esc clears it"
        else if (app.grid.failed)
            "could not be read - r tries again"
        else if (filtered)
            "nothing matches the filter - W changes it, esc clears it"
        else if (app.grid.editable and app.caps().no_insert.len == 0)
            "no rows yet - i inserts one"
        else
            "no rows", width);
        screen.reset();
    }
}

/// The lines of a screen that may be longer than the window: which of them is
/// on screen, and where.
///
/// The structure of a table, the last batch, the database information and the
/// relations were each drawn from the top until the room ran out, and that was
/// the end of them - thirty columns into a table, its indexes, its foreign keys
/// and its definition were simply not there. Each line is asked for through
/// this now, drawn or passed over, and all of them are counted, so the keys
/// know how far there is to go.
const Lines = struct {
    app: *App,
    left: usize,
    /// The last row of the screen there is to draw on; the first is the third.
    last: usize,
    skip: usize,
    count: usize = 0,

    fn begin(app: *App, left: usize, rows: usize) Lines {
        // Another screen starts at its top, whatever the last one was left at.
        if (app.pager.view != app.view) {
            app.pager = .{ .view = app.view };
        }
        const page = @max(1, rows -| 1);
        return .{ .app = app, .left = left, .last = rows, .skip = @min(app.pager.scroll, app.pager.lines -| page) };
    }

    /// The next line: true with the cursor at its start, false when it is
    /// above or below what is on screen.
    fn next(self: *Lines) bool {
        const n = self.count;
        self.count += 1;
        if (n < self.skip) {
            return false;
        }
        const row = 2 + (n - self.skip);
        if (row > self.last) {
            return false;
        }
        self.app.screen.moveTo(row, self.left);
        return true;
    }

    /// Blank what the lines did not reach, and leave behind how many there
    /// were. On the title line, at the right: which of them these are.
    fn end(self: *Lines, width: usize) void {
        const screen = self.app.screen;
        var row = 2 + (self.count -| self.skip);
        while (row <= self.last) : (row += 1) {
            screen.moveTo(row, self.left);
            screen.reset();
            screen.clearToEol();
        }
        const page = @max(1, self.last -| 1);
        self.app.pager.page = page;
        self.app.pager.lines = self.count;
        self.app.pager.scroll = @min(self.skip, self.count -| page);
        if (self.count <= page) {
            return;
        }
        var buf: [64]u8 = undefined;
        const where = std.mem.print(&buf, "lines {d}-{d} of {d}   j k scroll ", .{
            self.skip + 1,
            @min(self.skip + page, self.count),
            self.count,
        }) catch return;
        const w = term.width(where);
        if (width > w + 24) {
            screen.moveTo(1, self.left + width - w);
            screen.style(.{ .fg = C.faint });
            _ = write(self.app, where, w);
            screen.reset();
        }
    }
};

fn structure(app: *App, size: Size, side: usize, rows: usize) void {
    const screen = app.screen;
    const left = side;
    const width = size.cols -| left;
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

    var lines = Lines.begin(app, left, rows);
    section(&lines, width, "COLUMNS");
    for (app.conn.columns(scratch, table) catch &[_]database.Column{}) |column| {
        if (!lines.next()) {
            continue;
        }
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
            used += write(app, "NOT NULL ", width -| used);
        } else {
            screen.style(.{ .fg = C.nul, .italic = true });
            used += write(app, "null ", width -| used);
        }
        if (column.pk) {
            screen.style(.{ .fg = C.accent });
            used += write(app, "PRIMARY ", width -| used);
        }
        if (column.unique) {
            screen.style(.{ .fg = C.accent });
            used += write(app, "UNIQUE ", width -| used);
        }
        if (column.dflt) |value| {
            screen.style(.{ .fg = C.faint });
            used += write(app, "default ", width -| used);
            used += write(app, value, width -| used);
        }
        screen.reset();
        screen.clearToEol();
    }

    section(&lines, width, "INDEXES");
    for (app.conn.indexes(scratch, table) catch &[_]database.Index{}) |index| {
        if (!lines.next()) {
            continue;
        }
        var used: usize = 0;
        screen.style(.{ .fg = C.accent });
        used += write(app, "  ", width);
        pad(app, index.kind, 9, false);
        used += 9;
        screen.style(.{ .fg = C.text });
        pad(app, index.columns, 30, false);
        used += 30;
        screen.style(.{ .fg = C.faint });
        used += write(app, " ", width -| used);
        used += write(app, index.name, width -| used);
        if (index.partial) {
            used += write(app, " partial", width -| used);
        }
        screen.reset();
        screen.clearToEol();
    }

    section(&lines, width, "FOREIGN KEYS");
    for (app.conn.foreignKeys(scratch, table) catch &[_]database.ForeignKey{}) |key| {
        if (!lines.next()) {
            continue;
        }
        var used: usize = 0;
        screen.style(.{ .fg = C.text });
        used += write(app, "  ", width);
        pad(app, key.column, 22, false);
        used += 22;
        screen.style(.{ .fg = C.faint });
        used += write(app, "-> ", width -| used);
        screen.style(.{ .fg = C.accent });
        used += write(app, key.target_table, width -| used);
        screen.style(.{ .fg = C.dim });
        used += write(app, ".", width -| used);
        used += write(app, key.target_column, width -| used);
        screen.style(.{ .fg = C.faint });
        used += write(app, "   on update ", width -| used);
        used += write(app, key.on_update, width -| used);
        used += write(app, ", on delete ", width -| used);
        used += write(app, key.on_delete, width -| used);
        screen.reset();
        screen.clearToEol();
    }

    section(&lines, width, "DEFINITION");
    {
        const definition = (app.conn.definition(scratch, table) catch null) orelse "";
        var it = std.mem.splitScalar(u8, definition, '\n');
        while (it.next()) |part| {
            if (!lines.next()) {
                continue;
            }
            screen.style(.{ .fg = C.dim });
            _ = write(app, "  ", width);
            // A tab would land on the terminal's own stop and break the column.
            const expanded = expandTabs(scratch, part) catch part;
            _ = write(app, expanded, width -| 2);
            screen.clearToEol();
        }
    }
    lines.end(width);
}

fn section(lines: *Lines, width: usize, title: []const u8) void {
    if (!lines.next()) {
        return;
    }
    const screen = lines.app.screen;
    screen.style(.{ .fg = C.faint, .bold = true });
    _ = write(lines.app, " ", width);
    _ = write(lines.app, title, width -| 1);
    screen.clearToEol();
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
    const left_width = size.cols -| gap -| right_width;

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
    const title = std.mem.print(&head, " {s}:{s}", .{
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
            // Bold on the row the cursor is on as well as under it: here the band
            // is the only thing saying where the cursor is - there is no bright
            // cell on the row the way there is in the grid - and a second cue
            // costs no contrast at all.
            .bold = on or entry.kind == .dir,
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
        std.mem.print(&foot, " {s}", .{one.trouble.items}) catch " "
    else if (one.marked.items.len != 0)
        std.mem.print(&foot, " {d} marked of {d}", .{ one.marked.items.len, one.entries.len }) catch " "
    else
        std.mem.print(&foot, " {d} items", .{one.entries.len}) catch " ";
    pad(app, endOf(summary, width), width, false);
    screen.reset();
}

/// The end of a path rather than the start of it, for when it does not fit:
/// `/home/zales/very/deep` says more as `very/deep` than as `/home/zal`.
fn endOf(text: []const u8, width: usize) []const u8 {
    if (term.width(text) <= width or width < 2) {
        return text;
    }
    var at = text.len -| (width -| 1);
    while (at < text.len and text[at] & 0xC0 == 0x80) : (at += 1) {}
    return text[at..];
}

fn messages(app: *App, size: Size, side: usize, rows: usize) void {
    const screen = app.screen;
    const left = side;
    const width = size.cols -| left;
    screen.moveTo(1, left);
    screen.style(.{ .fg = C.accent, .bold = true });
    _ = write(app, " last batch", width);
    screen.clearToEol();

    if (app.report.list.items.len == 0) {
        note(app, left, width, "nothing has been run yet");
        var blank: usize = 3;
        while (blank <= rows) : (blank += 1) {
            screen.moveTo(blank, left);
            screen.reset();
            screen.clearToEol();
        }
        return;
    }
    var lines = Lines.begin(app, left, rows);
    for (app.report.list.items, 0..) |report, n| {
        if (lines.next()) {
            screen.style(.{ .fg = if (report.failure != null) C.danger else C.dim });
            var buf: [32]u8 = undefined;
            var used: usize = write(app, std.mem.print(&buf, " {d} ", .{n + 1}) catch " ", width);
            screen.style(.{ .fg = C.text });
            used += write(app, report.sql, width -| used -| 22);
            screen.style(.{ .fg = C.faint });
            var right: [48]u8 = undefined;
            const stats = if (report.result_set)
                "  result set, shown in the grid"
            else
                std.mem.print(&right, "  {d} rows, {d} chg, {d:.1} ms", .{ report.rows, report.changes, report.ms }) catch "";
            used += write(app, stats, width -| used);
            screen.clearToEol();
        }
        // All of what the engine said, on as many lines as it takes. It was
        // one line cut at the edge of the window, and the half that was cut -
        // the name of the column, the place in the statement - is the half
        // somebody opened this screen for.
        if (report.failure) |message| {
            var rest: []const u8 = message;
            while (rest.len != 0) {
                const piece = wrapRow(&rest, width -| 4);
                if (!lines.next()) {
                    continue;
                }
                screen.style(.{ .fg = C.danger });
                _ = write(app, "   ", width);
                _ = write(app, piece.text, width -| 3);
                screen.clearToEol();
            }
        }
    }
    lines.end(width);
}

pub const HELP = [_][2][]const u8{
    .{ "", "EVERYTHING" },
    .{ "ctrl+k ctrl+p", "command palette: search every action" },
    .{ "", "MOVING" },
    .{ "arrows hjkl", "list and grid" },
    .{ "w b 0 $", "next, previous, first, last column" },
    .{ "tab", "sidebar / grid" },
    .{ "gg G", "first, last row" },
    .{ "ctrl+d ctrl+u", "down, up half a screen" },
    .{ "ctrl+f ctrl+b", "down, up a screen; pgdn pgup too" },
    .{ "H M L", "top, middle, bottom of the screen" },
    .{ "zt zz zb", "this row to the top, middle, bottom" },
    .{ "gn gp", "next, previous page of rows" },
    .{ ":12 :$", "row 12 of the page, the last one" },
    .{ "ma 'a", "leave a mark here, go back to it" },
    .{ "/", "in the list: filter it, enter opens the first" },
    .{ "/", "in the rows: find text; n N next, previous" },
    .{ "d", "data of the selected table" },
    .{ "S", "structure, and back; j k scroll it" },
    .{ "gb gL", "database info, relations" },
    .{ "gm", "report of the last batch" },
    .{ "r", "reload" },
    .{ "R", "follow: read it again, staying at the end" },
    .{ "q", "out of what is in front, then the tab, then the program" },
    .{ "ctrl+c ctrl+c", "quit, whatever is open" },
    .{ "", "TABS" },
    .{ "ctrl+t", "a new tab; t on a saved connection opens it in one" },
    .{ "] [ gt gT", "next, previous tab" },
    .{ "alt+1..9 g1..9", "a tab by its number" },
    .{ "alt+w ctrl+w q", "close this tab" },
    .{ "ctrl+w o", "close the others" },
    .{ "", "ROWS" },
    .{ "enter", "open the row: a form, or a screen about it" },
    .{ "gv", "show the whole value; arrows scroll a long one, y copies it" },
    .{ "e", "edit the cell, NULL clears it" },
    .{ "i gy", "insert, clone a row" },
    .{ "space", "mark a row, and unmark it" },
    .{ "V", "mark a run: V, move, V again" },
    .{ "x", "delete the marked rows, asked first; x x the row here" },
    .{ "o", "order by this column" },
    .{ "gw W", "visible columns, filter" },
    .{ "", "SCHEMA" },
    .{ "c a", "create, alter a table" },
    .{ "I K", "index, foreign key" },
    .{ "gV T", "view, trigger" },
    .{ "gN Y", "rename, copy a table" },
    .{ "D X", "drop, empty" },
    .{ "", "DATA" },
    .{ "s", "the editor: SQL where there is SQL, the engine's own commands where there is not" },
    .{ "F", "search every table" },
    .{ "E gM", "export, import" },
    .{ "y  y c p s", "copy the row, value, page, last SQL" },
    .{ "O #", "connections, schema or namespace" },
    .{ ":", "export dump limit text follow open check w e set tabnew q qa" },
    .{ "", "FILES: SFTP, S3, AZURE" },
    .{ "f", "the two panes: here and the connection" },
    .{ "tab", "the other pane: where a copy goes" },
    .{ "enter h l", "into a directory, out of it" },
    .{ "/", "go to a path" },
    .{ "space", "mark, and unmark" },
    .{ "c", "copy over, directories and all" },
    .{ "n N x", "new directory, rename, remove" },
    .{ "r", "read both panes again" },
    .{ "", "IN THE EDITOR" },
    .{ "esc", "normal mode; once more puts the editor away, keeping what is in it" },
    .{ "i a o O", "type again: here, after, on a new line below, above" },
    .{ "hjkl w b e", "by a character, a line, a word" },
    .{ "0 ^ $ gg G", "the ends of the line, and of the text" },
    .{ "x dd dw D", "cut a character, the line, a word, the rest of the line" },
    .{ "s cc cw C", "the same, and type in its place" },
    .{ "yy p P", "yank the line, put it below, above" },
    .{ "u ctrl+r", "take a change back, put it back" },
    .{ "ctrl+s :w", "run it - and enter does, in normal mode" },
    .{ "s", "over rows a statement brought back: into that statement again" },
    .{ "tab", "complete a name; after `o.` the columns of what o is" },
    .{ "ctrl+p ctrl+n", "earlier, later statement" },
    .{ "ctrl+w ctrl+u", "take back a word, everything" },
    .{ "", "IN A FORM" },
    .{ "ctrl+s", "save" },
    .{ "tab shift+tab", "the next field, the one before; arrows go to everything" },
    .{ "left right", "in the text; or toggle, cycle a value" },
    .{ "enter space", "on a choice: the list of what it can be, to pick from" },
    .{ "home end", "the ends of the text - ctrl+a ctrl+e too" },
    .{ "ctrl+w ctrl+u", "take back a word, clear the field" },
    .{ "ctrl+n ctrl+x", "add, remove a column row" },
    .{ "esc", "cancel" },
};

fn help(app: *App, size: Size, side: usize, rows: usize) void {
    const screen = app.screen;
    const left = side;
    const width = size.cols -| left;
    screen.moveTo(1, left);
    screen.style(.{ .fg = C.accent, .bold = true });
    _ = write(app, " keys", width);
    screen.clearToEol();
    // Two columns, because the list is longer than a terminal is tall - but only
    // where two of them still have room for what they say. An entry is two spaces,
    // a key padded to fifteen and then its description, so a column under about
    // forty-four columns starts cutting the descriptions, and a key map with
    // "add, remove a column…" in it is a key map that has stopped explaining. One
    // column and a scroll is the better half of that trade: it scrolls anyway on a
    // short terminal, and everything can still be read.
    const columns: usize = if (width >= 88) 2 else 1;
    const half = if (columns == 2) (HELP.len + 1) / 2 else HELP.len;
    const column_width = width / columns;
    // The last body line is the strip that says where in the map this is; the
    // entries have the rest.
    const page = if (rows > 3) rows - 2 else 1;
    app.help.page = page;
    const scroll = @min(app.help.scroll, half -| page);
    app.help.scroll = scroll;

    var line: usize = 2;
    var i: usize = scroll;
    while (i < half and line < rows) : ({
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
                _ = write(app, entry[1], column_width -| 2);
                continue;
            }
            screen.style(.{ .fg = C.accent });
            _ = write(app, "  ", column_width);
            pad(app, entry[0], 15, false);
            screen.style(.{ .fg = C.text });
            _ = write(app, entry[1], if (column_width > 19) column_width - 19 else 0);
        }
    }
    while (line < rows) : (line += 1) {
        screen.moveTo(line, left);
        screen.reset();
        screen.clearToEol();
    }

    // What is left of the map, or - when all of it is on screen - the one thing
    // about this program that is worth saying on the way past.
    screen.moveTo(rows, left);
    screen.style(.{ .fg = C.faint });
    if (half <= page) {
        _ = write(app, "  writes go straight to the file - there is nothing to save", width);
    } else {
        var strip: [96]u8 = undefined;
        const shown = @min(page, half - scroll);
        const text = std.mem.print(&strip, "  lines {d}-{d} of {d}   j k scroll, n p page, g G ends", .{
            scroll + 1,
            scroll + shown,
            half,
        }) catch "  j k scroll";
        _ = write(app, text, width);
    }
    screen.clearToEol();
}

/// One object, opened: what is known about it, and what can be done to it.
///
/// Drawn as facts rather than as a grid, because that is what it is - a label and
/// a value to a line, the way the database information screen already reads. A
/// blank label is a blank line, which is how the engine separates one part of it
/// from the next without this having to know what the parts are.
fn objectScreen(app: *App, size: Size, side: usize, rows: usize) void {
    const screen = app.screen;
    const left = side;
    const width = size.cols -| left;

    screen.moveTo(1, left);
    screen.style(.{ .fg = C.accent, .bold = true });
    var used: usize = write(app, " ", width);
    used += write(app, app.object.title, width -| used);
    screen.style(.{ .fg = C.dim });
    if (app.currentTable()) |table| {
        used += write(app, "   ", width -| used);
        used += write(app, table.name, width -| used);
    }
    screen.clearToEol();

    // The widest label there is, so the values line up without a magic number.
    var label_width: usize = 8;
    for (app.object.facts) |fact| {
        label_width = @max(label_width, term.width(fact.label));
    }
    label_width = @min(label_width, @max(12, width / 3));

    const room = if (rows > 2) rows - 1 else 1;
    if (app.object.scroll + room > app.object.facts.len) {
        app.object.scroll = app.object.facts.len -| room;
    }
    var line: usize = 2;
    var at = app.object.scroll;
    while (at < app.object.facts.len and line <= rows) : (at += 1) {
        const fact = app.object.facts[at];
        screen.moveTo(line, left);
        screen.clearToEol();
        line += 1;
        if (fact.label.len == 0 and fact.value.len == 0) {
            continue;
        }
        screen.style(.{ .fg = C.dim });
        _ = write(app, " ", width);
        pad(app, fact.label, label_width, true);
        screen.style(.{ .fg = C.text });
        _ = write(app, "  ", width);
        _ = write(app, fact.value, width -| label_width -| 4);
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
    return std.mem.startsWith(u8, bytes, "RIFF") and std.mem.find(u8, bytes[0..12], "WEBP") != null;
}

/// Did the database call the cell under the cursor a BLOB?
fn isBlobCell(app: *App) bool {
    if (app.cursor.row >= app.grid.rows.items.len) {
        return false;
    }
    const row = app.grid.rows.items[app.cursor.row];
    return app.cursor.col < row.cells.len and row.cells[app.cursor.col].kind == .blob;
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
    // Counted in the rows it is drawn in, by the same cut. It was counted a
    // line's width over two columns fewer than a row holds, and a value of long
    // lines came out shorter than it is drawn: its end could not be scrolled to,
    // and nothing said there was more.
    var rows_needed: usize = 0;
    var counting = text;
    while (counting.len != 0) : (rows_needed += 1) {
        _ = wrapRow(&counting, width -| 4);
    }
    const lines: usize = 1 + @max(1, rows_needed);
    // One row for each of the frame's edges, on top of the value itself.
    const height: usize = @max(4, @min(@min(rows - 2, 15), lines + 1));
    // What the keys move through, left where they can read it.
    const page = height -| 2;
    app.detail_page = @max(1, page);
    app.detail_lines = lines -| 1;
    if (app.detail_at + page > lines -| 1) {
        app.detail_at = (lines -| 1) -| page;
    }

    const column = if (app.cursor.col < app.grid.cols.items.len) app.grid.cols.items[app.cursor.col] else "";

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
            box(app, top, left, width, tall, column, std.mem.print(&label, "{d} bytes, enter/esc closes", .{text.len}) catch "", C.accent);
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
                used += write(app, std.mem.print(&buf, "{x:0>6}  ", .{at}) catch "", width -| 2 -| used);
                screen.style(.{ .bg = C.selected, .fg = C.number });
                for (chunk) |byte| {
                    used += write(app, std.mem.print(&buf, "{x:0>2} ", .{byte}) catch "", width -| 2 -| used);
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
                fill(app, ' ', width -| used -| 2);
            }
        }
        screen.reset();
        var label: [64]u8 = undefined;
        box(app, top, left, width, tall, column, std.mem.print(&label, "{d} bytes, enter/esc closes", .{text.len}) catch "", C.accent);
        return;
    }

    var line = top + 1;

    var rest = text;
    // Past what has been scrolled by, consuming it exactly as the drawing below
    // does - a line longer than the box wraps, and a scroll that counted stored
    // lines would jump over the wrapped part of one.
    var skipped: usize = 0;
    while (skipped < app.detail_at and rest.len != 0) : (skipped += 1) {
        _ = wrapRow(&rest, width -| 4);
    }
    while (line + 1 < top + height) : (line += 1) {
        screen.moveTo(line, left + 1);
        screen.style(.{ .bg = C.selected, .fg = C.text });
        screen.put(" ");
        if (rest.len == 0) {
            fill(app, ' ', width -| 3);
            continue;
        }
        const piece = wrapRow(&rest, width -| 4);
        screen.put(piece.text);
        fill(app, ' ', width - 3 - piece.cols);
    }
    screen.reset();
    // Where in the value this is, when there is more of it than fits.
    var strip: [64]u8 = undefined;
    const hint = if (app.detail_lines > page)
        std.mem.print(&strip, "{d}-{d} of {d}   up down scroll   esc closes", .{
            app.detail_at + 1,
            @min(app.detail_at + page, app.detail_lines),
            app.detail_lines,
        }) catch "enter/esc closes"
    else
        "enter/esc closes";
    box(app, top, left, width, height, column, hint, C.accent);
}

/// One row of a value wrapped to `cols` columns: what of `rest` goes on it, with
/// `rest` moved past it - and past the line break too, where the row is the end
/// of a line. The whole-value view counts, scrolls and draws its rows with this,
/// so the rows the scroll is limited to are the rows there are.
fn wrapRow(rest: *[]const u8, cols: usize) term.Fit {
    const newline = std.mem.findScalar(u8, rest.*, '\n');
    const line = if (newline) |at| rest.*[0..at] else rest.*;
    const piece = term.fit(line, cols);
    // Nothing that fits is the rest of the line not fitting at all; it is left
    // out rather than tried again on every row after.
    if (piece.text.len < line.len and piece.text.len != 0) {
        rest.* = rest.*[piece.text.len..];
    } else {
        rest.* = if (newline) |at| rest.*[at + 1 ..] else "";
    }
    return piece;
}

fn note(app: *App, left: usize, width: usize, text: []const u8) void {
    const screen = app.screen;
    screen.moveTo(3, left + 2);
    screen.style(.{ .fg = C.faint });
    _ = write(app, text, width);
    screen.reset();
    screen.clearToEol();
}

/// One line of a list in a box: what it is called, which of its letters what
/// was typed landed on, and what is said at the right of it.
const ListRow = struct {
    label: []const u8,
    hit: fuzzy.Hit = .{},
    hint: []const u8 = "",
};

/// A list in a box over whatever is behind it: a line that is typed into, the
/// matches under it with the cursor on one, and a line that says the keys.
///
/// The command palette and the list a schema or a choice is picked from are
/// the same panel. `list` is whichever of them it is, and says what is in it:
/// `title`, `query`, `caret`, `placeholder`, `verb` - what enter does, in a
/// word - `count`, `at`, and `row(n)` for the nth match.
fn listPanel(app: *App, size: Size, rows: usize, list: anytype) void {
    const screen = app.screen;
    const width: usize = @min(size.cols -| 4, 66);
    const left = (size.cols -| width) / 2;
    const count: usize = list.count;
    const room: usize = if (rows > 6) @min(rows - 4, 12) else 3;
    const shown: usize = @min(count, room);
    // Keep the cursor in view when the list is longer than the panel.
    var from: usize = 0;
    if (list.at >= shown and shown != 0) {
        from = list.at + 1 - shown;
    }

    var line: usize = 2;
    screen.moveTo(line, left + 1);
    screen.style(.{ .bg = C.bar, .fg = C.accent, .bold = true });
    var used: usize = write(app, " › ", width -| 2);
    screen.style(.{ .bg = C.bar, .fg = C.text });
    const part = line_mod.window(list.query, list.caret, width -| used -| 2);
    app.typing.cursor = .{ .row = line, .col = left + 1 + used + part.cursor };
    used += write(app, part.text, width -| used -| 2);
    screen.style(.{ .bg = C.bar, .fg = C.faint });
    if (list.query.len == 0) {
        used += write(app, list.placeholder, width -| used -| 2);
    }
    if (width > used + 2) {
        fill(app, ' ', width -| used -| 2);
    }

    var at: usize = from;
    while (at < from + shown) : (at += 1) {
        line += 1;
        const row: ListRow = list.row(at);
        const here = at == list.at;
        screen.moveTo(line, left + 1);
        screen.style(.{ .bg = if (here) C.selected else C.bar, .fg = if (here) C.accent else C.text });
        var span: usize = write(app, if (here) " ❯ " else "   ", width -| 2);
        span += writeMatched(app, row.label, row.hit, width -| span -| 2, .{
            .bg = if (here) C.selected else C.bar,
            .fg = if (here) C.accent else C.text,
        });
        screen.style(.{ .bg = if (here) C.selected else C.bar, .fg = C.faint });
        // What is said beside it, right where the eye ends up: the key that
        // does the same, so it is learned in passing.
        const gap = width -| span -| term.width(row.hint) -| 4;
        fill(app, ' ', gap);
        span += gap;
        span += write(app, row.hint, width -| span -| 2);
        if (width > span + 2) {
            fill(app, ' ', width - span - 2);
        }
    }
    if (count == 0) {
        line += 1;
        screen.moveTo(line, left + 1);
        screen.style(.{ .bg = C.bar, .fg = C.dim, .italic = true });
        const span: usize = write(app, "   nothing matches", width -| 2);
        if (width > span + 2) {
            fill(app, ' ', width - span - 2);
        }
    }
    line += 1;
    screen.moveTo(line, left + 1);
    screen.style(.{ .bg = C.bar, .fg = C.faint });
    var footer: usize = write(app, "   up down choose   enter ", width -| 2);
    footer += write(app, list.verb, width -| footer -| 2);
    footer += write(app, "   esc close", width -| footer -| 2);
    if (count > shown) {
        var buf: [32]u8 = undefined;
        footer += write(app, std.mem.print(&buf, "   {d} more", .{count - shown}) catch "", width -| footer -| 2);
    }
    if (width > footer + 2) {
        fill(app, ' ', width - footer - 2);
    }
    screen.reset();
    box(app, 1, left, width, line + 1, list.title, "", C.accent);
}

/// The command palette, over whatever is behind it: a query line and the
/// matches, each with the key that runs it, so using it teaches the key map.
fn palettePanel(app: *App, size: Size, rows: usize) void {
    const palette = &app.palette.?;
    const Actions = struct {
        app: *App,
        title: []const u8 = "commands",
        query: []const u8,
        caret: usize,
        placeholder: []const u8 = "what do you want to do?",
        verb: []const u8 = "run",
        found: [input.actions.len]usize = undefined,
        count: usize = 0,
        at: usize,

        fn row(self: *const @This(), n: usize) ListRow {
            const action = input.actions[self.found[n]];
            return .{
                .label = input.labelFor(action, if (self.app.connected) self.app.caps() else null),
                .hit = input.paletteHit(self.found[n], self.query),
                .hint = action.keys,
            };
        }
    };
    var list = Actions{ .app = app, .query = palette.query.items, .caret = palette.caret, .at = palette.at };
    list.count = input.paletteFor(
        palette.query.items,
        if (app.connected) app.caps() else null,
        app.connected and app.conn.files() != null,
        &list.found,
    );
    listPanel(app, size, rows, &list);
}

/// The list one thing is picked out of - a schema, or what a choice in a form
/// can be - in the palette's own panel. The one in force says so.
fn pickerPanel(app: *App, size: Size, rows: usize) void {
    const picker = &app.picker.?;
    const Names = struct {
        picker: *const picker_mod.Picker,
        title: []const u8,
        query: []const u8,
        caret: usize,
        placeholder: []const u8 = "type to narrow it",
        verb: []const u8 = "takes it",
        count: usize,
        at: usize,

        fn row(self: *const @This(), n: usize) ListRow {
            const option = self.picker.found[n];
            const name = self.picker.options[option];
            const now = if (self.picker.current) |current| current == option else false;
            return .{
                // A choice may be of nothing - no mechanism, no type - and a
                // line with nothing on it is not something to put a cursor on.
                .label = if (name.len != 0) name else "(none)",
                .hit = if (name.len != 0) self.picker.hit(option) else .{},
                .hint = if (now) "now" else "",
            };
        }
    };
    const list = Names{
        .picker = picker,
        .title = picker.title,
        .query = picker.query.items,
        .caret = picker.caret,
        .count = picker.count,
        .at = picker.at,
    };
    listPanel(app, size, rows, &list);
}

/// The panel in the middle of the screen while a connection is being opened:
/// what is being opened, what is being waited for, and for how long.
///
/// Drawn over the frame that is already there, the way the spinner is - vaxis
/// writes only the cells that changed - because whoever drew that frame is in
/// the middle of a call and has nothing new to draw. The next whole frame takes
/// it away again.
pub fn connecting(app: *App) void {
    if (app.connecting == null) {
        return;
    }
    const state = &app.connecting.?;
    const given_up = state.given_up.load(.acquire);
    var sentence: [database.Stage.SIZE]u8 = undefined;
    const doing = if (given_up) "giving up" else state.stage.read(&sentence);
    const screen = app.screen;
    const size = screen.size();
    const width: usize = @min(size.cols -| 4, 64);
    const height: usize = 6;
    if (size.rows < height) {
        return;
    }
    const left = (size.cols -| width) / 2;
    const top = (size.rows - height) / 2;
    const inner = width - 2;

    var line = top + 1;
    while (line < top + height - 1) : (line += 1) {
        screen.moveTo(line, left + 1);
        screen.style(.{ .bg = C.bar });
        fill(app, ' ', inner);
    }

    screen.moveTo(top + 2, left + 1);
    screen.style(.{ .bg = C.bar, .fg = if (given_up) C.warn else C.accent, .bold = true });
    var used = write(app, "  ", inner);
    used += write(app, app_mod.SPINNER[state.frame % app_mod.SPINNER.len], inner -| used);
    used += write(app, " ", inner -| used);
    screen.style(.{ .bg = C.bar, .fg = C.text });
    _ = write(app, state.what, inner -| used -| 2);

    // The step on the left and the clock on the right. The clock keeps its
    // place whatever the sentence does, so the eye finds it where it left it.
    var buffer: [16]u8 = undefined;
    const clock = std.mem.print(&buffer, "{d:.1}s", .{(app_mod.monotonicMs() - state.started) / 1000.0}) catch "";
    screen.moveTo(top + 3, left + 1);
    screen.style(.{ .bg = C.bar, .fg = if (given_up) C.warn else C.dim });
    used = write(app, "    ", inner);
    const room = inner -| used -| term.width(clock) -| 4;
    const said = write(app, doing, room);
    fill(app, ' ', room - said + 2);
    screen.style(.{ .bg = C.bar, .fg = C.faint });
    _ = write(app, clock, inner -| used -| room -| 2);

    screen.reset();
    box(app, top, left, width, height, "connecting", "esc gives up", C.accent);
    screen.cursorOff();
    screen.flush() catch {};
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

fn status(app: *App, size: Size) void {
    const screen = app.screen;
    screen.moveTo(size.rows - 2, 0);
    screen.style(.{ .bg = C.bar, .fg = if (app.report.status_error) C.danger else C.ok });
    var used: usize = write(app, " ", size.cols);
    used += write(app, app.report.status.items, size.cols -| 1);
    screen.style(.{ .bg = C.bar });
    if (size.cols > used) {
        fill(app, ' ', size.cols -| used);
    }
    screen.reset();
}

fn promptLine(app: *App, size: Size) void {
    const screen = app.screen;
    screen.moveTo(size.rows - 1, 0);
    screen.reset();
    if (app.typing.prompt) |prompt| {
        screen.style(.{ .fg = C.accent, .bold = true });
        const used: usize = write(app, prompt.label, size.cols);
        screen.style(.{ .fg = C.text });
        const room = size.cols -| used;
        const text = prompt.buffer.items;
        if (prompt.kind == .password) {
            // Never echo a password, not even to the screen it was typed on. A
            // dot a character, and the cursor after as many of them as there are
            // characters before it: counted in columns, the dots said how wide
            // the characters were and the cursor sat in the middle of them.
            const all = std.unicode.utf8CountCodepoints(text) catch text.len;
            const before = text[0..line_mod.where(text, prompt.at)];
            var dots: usize = 0;
            while (dots < all and dots + 1 < room) : (dots += 1) {
                _ = write(app, "•", 1);
            }
            const in = std.unicode.utf8CountCodepoints(before) catch before.len;
            app.typing.cursor = .{ .row = size.rows - 1, .col = used + @min(in, room -| 1) };
        } else {
            // The part of it the cursor is in, where it is longer than the line.
            const part = line_mod.window(text, prompt.at, room);
            _ = write(app, part.text, room);
            app.typing.cursor = .{ .row = size.rows - 1, .col = used + part.cursor };
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
    if (app.typing.prefix) |pending| {
        return switch (pending) {
            'y' => " y the row   c the value   p the page as CSV   s the last SQL   esc nothing",
            // What `g` goes to, and what the letters after it did on their own
            // before they were given to vi. Ten things do not fit in eighty
            // columns, and the two that go are the two vi already taught.
            'g' => fitted(app, &.{
                " g top   n p page   t T tabs   v value   w columns   y clone   m messages   b info   L relations   M import   V view   N rename",
                " g top   n p page   v value   w columns   y clone   m messages   b info   L relations   M import   V view   N rename",
                " n p page  v value  w columns  y clone  m messages  b info  L relations  M import  V view  N rename",
                " n p page  v value  w columns  y clone  m messages  b info  L relations",
            }),
            'z' => " t this row to the top   z the middle   b the bottom   esc nothing",
            'x' => " x deletes this row   esc nothing",
            'm' => " a-z leaves that mark on this row   esc nothing",
            '\'' => " a-z goes back to that mark   esc nothing",
            0x17 => " h list   l grid   w the other   q close tab   o close others   t new tab",
            else => " esc nothing",
        };
    }
    if (app.detail) {
        return if (app.detail_lines > app.detail_page)
            " up down scroll   pgup pgdn a page   home end the ends   y copies it   esc closes"
        else
            " y copies the value   esc closes it";
    }
    if (app.typingInEditor()) {
        return switch (app.typing.editor.?.mode) {
            .normal => " -- NORMAL --  i insert  o line  dd cut line  u undo  enter runs  esc closes",
            .insert => " -- INSERT --  esc normal mode  tab completes  ctrl+s runs  ctrl+p earlier",
        };
    }
    if (app.picker != null) {
        return " type to narrow it   up down choose   enter takes it   esc leaves it as it is";
    }
    if (app.typing.form) |form| {
        // On a choice, what there is to say is how to choose: the arrows for
        // the one beside it, and the list for the one that is twenty away.
        if (form.fields.items.len > form.cursor and form.fields.items[form.cursor].kind == .choice) {
            return " left right the one beside it   enter the list of them   tab next   ctrl+s saves   esc cancels";
        }
        // Not the palette here: a form takes what is typed, and a key that
        // opened something over it would take the typing away from it.
        return if (form.row_size != 0)
            " tab next   ctrl+s saves   ctrl+n adds a row   ctrl+x removes it   esc cancels"
        else
            " tab next   shift+tab back   ctrl+s saves   ctrl+u clears the field   esc cancels";
    }
    if (app.follow.ms != 0 and app.view == .grid) {
        // The one key worth knowing while the grid moves on its own.
        return " R stops following   ctrl+k commands   q quit";
    }
    // The sidebar's hints depend on the engine: a cluster has namespaces rather
    // than schemas and no tables anybody creates, and offering either of those in
    // the wrong words is how a key goes unfound.
    // On an object screen the keys are the engine's own, so the footer is built
    // from what it said can be done rather than from anything known here.
    if (app.view == .object) {
        var out: std.ArrayList(u8) = .empty;
        const arena = app.screen.frame.allocator();
        for (app.object.actions) |action| {
            var key: [8]u8 = undefined;
            const len = std.unicode.utf8Encode(action.key, &key) catch continue;
            out.appendSlice(arena, if (out.items.len == 0) " " else "   ") catch break;
            out.appendSlice(arena, key[0..len]) catch break;
            out.append(arena, ' ') catch break;
            out.appendSlice(arena, action.label) catch break;
        }
        out.appendSlice(arena, if (out.items.len == 0) " esc back" else "   esc back") catch {};
        return out.items;
    }
    if (app.view == .grid and app.focus == .sidebar) {
        const caps = app.caps();
        var out: std.ArrayList(u8) = .empty;
        const arena = app.screen.frame.allocator();
        out.appendSlice(arena, " enter opens   / filter") catch return " enter opens   / filter";
        if (caps.schemas or caps.databases) {
            out.print(arena, "   # {s}", .{caps.schema_noun}) catch {};
        }
        if (caps.no_ddl.len == 0 and caps.no_tables.len == 0) {
            out.appendSlice(arena, "   c create table") catch {};
        }
        out.appendSlice(arena, "   E export   ctrl+k commands   q quit") catch {};
        return out.items;
    }
    return switch (app.view) {
        .connections => fitted(app, &.{
            " enter connect   t in a new tab   / filter   a add   e edit   x remove   r read-only   q quit",
            " enter connect   t new tab   / filter   a add   e edit   x remove   r read-only",
        }),
        // Only what the engine will do: a key in this line that answers with a
        // refusal is a line that was wrong.
        .structure => if (app.caps().no_ddl.len != 0)
            " S data   ctrl+k commands"
        else if (app.caps().no_tables.len != 0)
            " a alter   S data   ctrl+k commands"
        else if (app.caps().no_relations.len != 0)
            " a alter   gN rename   S data   ctrl+k commands"
        else
            " a alter   I index   K key   gN rename   S data   ctrl+k commands",

        .messages => " gm back   s sql   r reload   ctrl+k commands",
        // Handled above, from what the engine said can be done.
        .object => " esc back",
        .help => " ? back   ctrl+k commands",
        .info => " gb back   ctrl+k commands",
        .relations => " gL back   d browse   ctrl+k commands",
        .files => " tab other pane   enter opens   c copy   space mark   n mkdir   N rename   x remove   q back",
        .grid => rowHints(app),
    };
}

/// The longest way of saying it that the terminal has room for, of however
/// many ways there are, longest first. A hint that is cut off is worse than
/// one that says less: what goes missing is whatever was at the end, and that
/// is where quitting and the palette are.
fn fitted(app: *App, ways: []const []const u8) []const u8 {
    for (ways) |way| {
        if (term.width(way) <= app.screen.size().cols) {
            return way;
        }
    }
    return ways[ways.len - 1];
}

/// What to press on a row, less whatever this engine will not do. A hint for
/// something that cannot happen is worse than no hint, because it is the first
/// thing somebody tries: a Kafka grid used to offer `e` for a record that cannot
/// be changed and `x` for one that cannot be removed, and a cluster offered `i`
/// for an object nothing here makes.
fn rowHints(app: *App) []const u8 {
    const caps = app.caps();
    if (caps.no_insert.len == 0 and caps.no_update.len == 0 and caps.no_delete.len == 0 and app.files == null) {
        return " i insert   e edit   x delete   o sort   gv value   space mark   ctrl+k commands";
    }
    var out: std.ArrayList(u8) = .empty;
    const arena = app.screen.frame.allocator();
    const fallback = " o sort   gv value   space mark   ctrl+k commands";
    // One space in front, three between, however many of them there turn out to be.
    if (app.files != null) {
        addHint(arena, &out, "f the two panes");
    }
    if (caps.no_insert.len == 0) {
        addHint(arena, &out, "i insert");
    }
    if (caps.no_update.len == 0) {
        addHint(arena, &out, "e edit");
    }
    if (caps.no_delete.len == 0) {
        addHint(arena, &out, "x delete");
    }
    addHint(arena, &out, "o sort");
    addHint(arena, &out, "gv value");
    addHint(arena, &out, "space mark");
    addHint(arena, &out, "ctrl+k commands");
    return if (out.items.len == 0) fallback else out.items;
}

fn addHint(arena: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) void {
    out.appendSlice(arena, if (out.items.len == 0) " " else "   ") catch return;
    out.appendSlice(arena, text) catch {};
}

/// The SQL editor: line numbers, the statement in colour, and the completion
/// list where the word being typed is.
fn editorPanel(app: *App, size: Size, side: usize, rows: usize) void {
    const editor = &app.typing.editor.?;
    const screen = app.screen;
    const outer_left = side + 1;
    const outer_width = if (size.cols > outer_left + 4) size.cols - outer_left - 1 else 20;
    const left = outer_left + 1;
    const width = outer_width -| 2;
    // The gutter holds the line number, right aligned, and a space.
    const gutter: usize = 5;
    const talking = app.conn.sessionIn().len != 0;

    // Over its own result it is a strip: the statement from its first line, as
    // tall as that is and no taller, in a frame that is quiet because the keys
    // are not here. Its top edge says how to get them back.
    if (app.typing.docked) {
        const tall = dockedRows(app, rows);
        if (tall < 3) {
            return;
        }
        var colours: [1024]sql_syntax.Kind = undefined;
        var n: usize = 0;
        while (n < tall - 2) : (n += 1) {
            screen.moveTo(1 + 1 + n, left);
            screen.style(.{ .bg = C.bar });
            fill(app, ' ', width);
            screen.moveTo(1 + 1 + n, left);
            if (n >= editor.lineCount()) {
                continue;
            }
            const text = editor.lineAt(n);
            sql_syntax.kinds(text, colours[0..@min(colours.len, text.len)]);
            var used: usize = write(app, " ", width);
            var byte: usize = 0;
            while (byte < text.len and used < width) {
                const kind = if (byte < colours.len) colours[byte] else .plain;
                var stop = byte;
                while (stop < text.len and stop < colours.len and colours[stop] == kind) : (stop += 1) {}
                if (stop == byte) {
                    stop = text.len;
                }
                screen.style(.{ .bg = C.bar, .fg = switch (kind) {
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
        screen.reset();
        var more: [48]u8 = undefined;
        const hint = if (editor.lineCount() > tall - 2)
            std.mem.print(&more, "{d} lines   s edits it again   esc puts it away", .{editor.lineCount()}) catch "s edits it again"
        else
            "s edits it again   esc puts it away";
        box(app, 1, outer_left, outer_width, tall, if (app.caps().speaks_sql) "SQL" else "command", hint, C.faint);
        return;
    }

    // Tall enough that a completion list has room inside the panel, and one line
    // taller than what is written, so there is visibly somewhere to keep typing.
    //
    // Except with a shell open in a container, where it is as small as it can be:
    // a shell is one line typed at a time and what matters is the output under
    // it, which a panel nine rows tall would be sitting on.
    const floor: usize = if (talking) 4 else 9;
    // What the engine said about the last run, where it would not take it: the
    // last lines of the panel are that, as many as it needs up to six. A line of
    // it is kept whole where it fits - PostgreSQL points at the place with a
    // caret on a line of its own, and a caret that has been wrapped points at
    // nothing.
    const failure = if (talking) "" else app.typing.failure.items;
    var said: usize = 0;
    if (failure.len != 0) {
        var rest: []const u8 = failure;
        while (rest.len != 0 and said < 6) : (said += 1) {
            _ = wrapRow(&rest, width -| 4);
        }
    }
    const height: usize = @min(rows, @max(floor, editor.lineCount() + 3 + said));
    // A statement is written above its result and a shell is typed below it: what
    // came back is what you are looking at while you write the next line, which
    // is the shape every terminal has.
    const top: usize = if (talking) (if (rows > height) rows - height + 1 else 1) else 1;
    // Never all of the panel: there is always a line of the statement in it.
    said = @min(said, height -| 3);
    const shown = height -| 2 -| said;
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
        pad(app, std.mem.print(&label, "{d}", .{number + 1}) catch "", gutter - 1, true);
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
            used += write(app, text[byte..stop], width -| used);
            byte = stop;
        }
    }

    if (said != 0) {
        var rest: []const u8 = failure;
        var n: usize = 0;
        while (n < said) : (n += 1) {
            const piece = wrapRow(&rest, width -| 4);
            screen.moveTo(top + 1 + shown + n, left);
            screen.style(.{ .bg = C.selected, .fg = C.danger });
            fill(app, ' ', width);
            screen.moveTo(top + 1 + shown + n, left);
            _ = write(app, "  ", width);
            _ = write(app, piece.text, width -| 4);
        }
    }

    // No key list inside the panel: the footer already carries one, and the same
    // sentence written twice on one screen teaches nobody anything the second time.
    screen.reset();
    // An engine without SQL gets its own name on the panel, because what is typed
    // there is its command line and calling that SQL would be a lie. And where a
    // shell is open in a container, the panel says which one: what is typed is
    // going somewhere else entirely, and nothing else on the screen says so.
    const caps = app.caps();
    var named: [64]u8 = undefined;
    const container = app.conn.sessionIn();
    const mode_label = switch (editor.mode) {
        .normal => " [NORMAL]",
        .insert => " [INSERT]",
    };
    const title = if (container.len != 0)
        (std.mem.print(&named, "sh in {s} - EXIT closes it", .{container}) catch "sh")
    else if (caps.speaks_sql)
        (std.mem.print(&named, "SQL{s}", .{mode_label}) catch "SQL")
    else if (caps.label.len != 0)
        (std.mem.print(&named, "{s}{s}", .{ caps.label, mode_label }) catch caps.label)
    else
        (std.mem.print(&named, "command{s}", .{mode_label}) catch "command");
    box(app, top, outer_left, outer_width, height, title, "", C.accent);

    // The cursor is where the typing happens, inside the panel - wherever the
    // panel is, which under a shell is the bottom of the screen and not the top.
    // In columns as drawn: the editor counts bytes, and a letter with an accent is
    // two of those and one column.
    const cursor_column = term.width(editor.lineAt(at.line)[0..at.column]);
    app.typing.cursor = .{
        .row = top + 1 + (at.line - editor.scroll),
        .col = left + gutter + cursor_column,
        .block = editor.mode == .normal,
    };

    // The completion list, hanging under the word being completed.
    if (editor.completing()) {
        const count: usize = @min(editor.candidates.items.len, 7);
        const list_top: usize = @min(top + 2 + (at.line - editor.scroll), rows -| count -| 1);
        var widest: usize = 8;
        for (editor.candidates.items[0..count]) |name| {
            widest = @max(widest, term.width(name) + 4);
        }
        const list_left: usize = @min(left + gutter + cursor_column, size.cols -| widest -| 2);
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
            std.mem.print(&more, "{d} more", .{editor.candidates.items.len - count}) catch ""
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
        used += write(app, " ", width -| used);
        used += write(app, title, width -| used -| 2);
        used += write(app, " ", width -| used -| 1);
        screen.style(.{ .fg = accent });
    }
    if (hint.len != 0 and width > used + 8) {
        used += write(app, "─ ", width -| used);
        screen.style(.{ .fg = C.faint });
        used += write(app, hint, width -| used -| 2);
        used += write(app, " ", width -| used -| 1);
        screen.style(.{ .fg = accent });
    }
    while (used < width -| 1) : (used += 1) {
        _ = write(app, "─", 1);
    }
    _ = write(app, "╮", 1);

    var line = top + 1;
    while (line < bottom) : (line += 1) {
        screen.moveTo(line, left);
        _ = write(app, "│", 1);
        screen.moveTo(line, left + width -| 1);
        _ = write(app, "│", 1);
    }
    screen.moveTo(bottom, left);
    used = write(app, "╰", width);
    while (used < width -| 1) : (used += 1) {
        _ = write(app, "─", 1);
    }
    _ = write(app, "╯", 1);
    screen.reset();
}

// --- primitives ---

/// Write as much of `text` as fits in `max` columns, and say so with an ellipsis
/// where it did not all fit. A sentence that stops mid-word without a mark is
/// worse than no sentence: the reader cannot tell whether something was lost.
fn write(app: *App, text: []const u8, max: usize) usize {
    if (max == 0) {
        return 0;
    }
    const piece = term.fit(text, max);
    if (piece.text.len == text.len) {
        app.screen.put(piece.text);
        return piece.cols;
    }
    // One column for the ellipsis, taken off the end of what is shown.
    const room = term.fit(text, max -| 1);
    app.screen.put(room.text);
    app.screen.put("…");
    return room.cols + 1;
}

/// What one mark is drawn as. Filled for the one that is up and hollow for
/// every other, so that a row of them says how many are up to somebody who
/// cannot tell the colours apart - and the colour says which kind of not up.
fn markGlyph(mark: database.Mark) []const u8 {
    return if (mark == .ok) "▪" else "▫";
}

fn markColour(mark: database.Mark) u8 {
    return switch (mark) {
        .ok => C.ok,
        .waiting => C.warn,
        .failed => C.danger,
        .done => C.dim,
    };
}

/// A cell that counts things, as a square for each of them, in a field of
/// exactly `width` columns. Under the cursor they are all the one colour the
/// cursor's text is: its background is a colour of its own, and a red square
/// on it is a square nobody can see.
fn marks(app: *App, all: []const database.Mark, width: usize, bg: ?u8, plain: bool) void {
    if (width == 0) {
        return;
    }
    // One column goes to the ellipsis when there are more than there is room for.
    const shown = if (all.len > width) width - 1 else all.len;
    for (all[0..shown]) |mark| {
        app.screen.style(.{ .bg = bg, .fg = if (plain) 16 else markColour(mark) });
        app.screen.put(markGlyph(mark));
    }
    app.screen.style(.{ .bg = bg, .fg = if (plain) 16 else C.dim });
    if (shown != all.len) {
        app.screen.put("…");
    }
    fill(app, ' ', width - shown - @intFromBool(shown != all.len));
}

/// Write `text` in a field of exactly `width` columns.
fn pad(app: *App, text: []const u8, width: usize, right_align: bool) void {
    if (width == 0) {
        return;
    }
    const cut = term.fit(text, width);
    // One column of the field goes to the ellipsis when the text did not all fit.
    const ellipsis = cut.text.len != text.len;
    const piece = if (ellipsis) term.fit(text, width -| 1) else cut;
    const space = width - piece.cols - @intFromBool(ellipsis);
    if (right_align) {
        fill(app, ' ', space);
        app.screen.put(piece.text);
        if (ellipsis) {
            app.screen.put("…");
        }
    } else {
        app.screen.put(piece.text);
        if (ellipsis) {
            app.screen.put("…");
        }
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
/// The form: a column of labels, a column of controls, and a frame drawn around
/// what is in it rather than around the pane.
///
/// Three things were wrong with the old one and all three were geometry. The
/// label sat left-aligned in a fixed column of 28, so `id` was two dozen spaces
/// away from the field it named and the eye had nothing to join them with; the
/// labels are right-aligned against their controls now, and the column is as wide
/// as the labels really are, so a form of short names is tight and one of long
/// names still lines up. A text field was drawn in a background one step from the
/// panel's - 1.1:1, which is no step at all - so an empty field was not on the
/// screen; it is underlined for its whole width now, which is the one affordance
/// a terminal can draw that does not depend on having colours to spare. And the
/// frame was the height of the pane, which made every form nine tenths empty box.
fn formPanel(app: *App, size: Size, side: usize, rows: usize) !void {
    const form = &app.typing.form.?;
    const screen = app.screen;
    const outer_left = side + 1;
    const outer_width = if (size.cols > outer_left + 2) size.cols - outer_left - 1 else 20;
    // The frame takes the outermost column on each side; everything below works
    // inside it, and the frame itself is drawn last.
    const left = outer_left + 1;
    const width = outer_width -| 2;

    // How many lines the fields need, and which of them the cursor is on. Inline
    // fields share the line of the field before them.
    var lines: usize = 1;
    var cursor_line: usize = 0;
    for (form.fields.items, 0..) |field, i| {
        if (i != 0 and !field.inline_with_previous) {
            lines += 1;
        }
        if (i == form.cursor) {
            cursor_line = lines - 1;
        }
    }
    const room_for_lines = if (rows > 2) rows - 2 else 1;
    const visible = @min(lines, room_for_lines);
    if (cursor_line >= form.scroll + visible) {
        form.scroll = cursor_line + 1 - visible;
    }
    if (cursor_line < form.scroll) {
        form.scroll = cursor_line;
    }

    // The label column is as wide as the labels are. A repeatable row is a table,
    // not a list of labelled fields, so its own narrow labels stay out of this.
    var label_width: usize = 0;
    for (form.fields.items) |field| {
        if (field.inline_with_previous or field.group != 0) {
            continue;
        }
        if (field.kind == .label or field.kind == .toggle) {
            continue;
        }
        label_width = @max(label_width, term.width(field.label));
    }
    // Nothing to line up against means no column at all: a form of nothing but
    // checkboxes is a list, and a list does not start a third of the way in.
    if (label_width != 0) {
        label_width = @min(label_width, @max(10, width / 3));
    }
    const gutter: usize = 2;
    // A column of air inside the frame on each side: a label hard against the
    // border reads as part of it.
    const indent = left + 1;
    const inner = width -| 2;
    const value_left = indent + label_width + gutter;
    // A repeatable row carries a label on each of its fields, which is what makes
    // it readable - but five labelled fields need more line than a pane has, and
    // the old form answered that by running off the right-hand edge. So the labels
    // are there when they fit and gone when they do not: the fields of a row are
    // a name, a type, two checkboxes that say what they are, and a default, and a
    // row that fits is worth more than a row that explains itself and is cut in
    // half.
    const packed_label: usize = label: {
        const slot: usize = 8;
        var needed: usize = 0;
        var widest: usize = 0;
        for (form.fields.items) |field| {
            if (field.group == 0) {
                continue;
            }
            if (!field.inline_with_previous) {
                widest = @max(widest, needed);
                needed = 0;
            }
            needed += switch (field.kind) {
                .toggle => term.width(field.label) + 6,
                .choice => slot + 1 + field.width + 4,
                else => slot + 1 + field.width + 2,
            };
        }
        widest = @max(widest, needed);
        break :label if (widest <= width -| 2) slot else 0;
    };

    // Room left on the current line; a wide field must not underflow it.
    const room = struct {
        fn left_over(total: usize, at: usize, start: usize) usize {
            return if (at >= start + total) 0 else total - (at - start);
        }
    }.left_over;

    var line: usize = 2;
    var row_on_screen: usize = 0;
    var at: usize = indent;
    var index: usize = 0;
    screen.moveTo(line, left);
    screen.style(.{ .bg = C.selected });
    fill(app, ' ', width);
    while (index < form.fields.items.len) : (index += 1) {
        const field = &form.fields.items[index];
        if (index != 0 and !field.inline_with_previous) {
            row_on_screen += 1;
            if (row_on_screen < form.scroll) {
                continue;
            }
            line += 1;
            if (line >= 2 + visible) {
                break;
            }
            screen.moveTo(line, left);
            screen.style(.{ .bg = C.selected });
            fill(app, ' ', width);
            at = indent;
        } else if (row_on_screen < form.scroll) {
            continue;
        }
        const focused = index == form.cursor;
        const packed_row = field.inline_with_previous or field.group != 0;

        // The label, and where its control begins. A note and a toggle have no
        // label column of their own: a note explains the field above it and a
        // checkbox says what it is next to its own box, so both start where the
        // values start.
        if (!field.inline_with_previous) {
            at = indent;
            switch (field.kind) {
                // A note is prose about the field above it, so it starts at the
                // margin and has the whole line; a checkbox says what it is beside
                // its own box, so it starts where the values do.
                .label => screen.moveTo(line, at),
                .toggle => {
                    screen.moveTo(line, at);
                    screen.style(.{ .bg = C.selected });
                    fill(app, ' ', @min(label_width + gutter, room(inner, at, indent)));
                    at = @min(value_left, indent + inner);
                },
                else => {
                    screen.moveTo(line, at);
                    screen.style(.{ .bg = C.selected, .fg = if (focused) C.accent else C.dim, .bold = focused });
                    if (packed_row) {
                        pad(app, field.label, packed_label, false);
                        at += packed_label;
                    } else {
                        pad(app, field.label, label_width, true);
                        at += label_width;
                    }
                    screen.style(.{ .bg = C.selected });
                    fill(app, ' ', gutter);
                    at += gutter;
                },
            }
        } else if (field.kind != .toggle) {
            // Packed onto the line already in progress, with its own short label.
            screen.moveTo(line, at);
            screen.style(.{ .bg = C.selected, .fg = if (focused) C.accent else C.dim, .bold = focused });
            const slot = @min(packed_label, room(inner, at, indent));
            pad(app, field.label, slot, false);
            at += slot;
            screen.style(.{ .bg = C.selected });
            at += write(app, " ", room(inner, at, indent));
        } else {
            screen.moveTo(line, at);
        }

        switch (field.kind) {
            .label => {
                screen.style(.{ .bg = C.selected, .fg = C.faint, .italic = true });
                at += write(app, field.label, room(inner, at, indent));
            },
            .toggle => {
                screen.style(.{
                    .bg = C.selected,
                    .fg = if (focused) C.accent else if (field.on) C.text else C.faint,
                    .bold = focused,
                    .underline = focused,
                    .underline_colour = C.accent,
                });
                at += write(app, if (field.on) "[x] " else "[ ] ", room(inner, at, indent));
                screen.style(.{
                    .bg = C.selected,
                    .fg = if (focused) C.accent else C.text,
                    .bold = focused,
                    .underline = focused,
                    .underline_colour = C.accent,
                });
                at += write(app, field.label, room(inner, at, indent));
                screen.style(.{ .bg = C.selected });
                at += write(app, "  ", room(inner, at, indent));
            },
            .choice => {
                const span = @min(field.width + 2, room(inner, at, indent));
                screen.style(.{
                    .bg = C.selected,
                    .fg = if (focused) C.accent else C.text,
                    .bold = focused,
                    .underline = focused,
                    .underline_colour = C.accent,
                });
                if (span > 2) {
                    at += write(app, "‹", room(inner, at, indent));
                    pad(app, field.value(), span - 2, false);
                    at += span - 2;
                    at += write(app, "›", room(inner, at, indent));
                }
                screen.style(.{ .bg = C.selected });
                at += write(app, "  ", room(inner, at, indent));
            },
            .text => {
                // Underlined for the whole width of the field, so an empty one is
                // still somewhere to type: on this panel no background is far enough
                // from the panel to be seen.
                const span = @min(field.width, room(inner, at, indent));
                screen.style(.{
                    .bg = C.selected,
                    .fg = C.text,
                    .underline = true,
                    .underline_colour = if (focused) C.accent else C.faint,
                });
                // The part of a long value the cursor is in - its tail, while the
                // cursor is where the typing is - or dots, where the value is a
                // password. A dot is a character, so the cursor is as many of them
                // in as there are characters before it.
                var dots: [64]u8 = undefined;
                var cursor_col: usize = 0;
                const shown = if (field.masked) dotted: {
                    const before = field.text.items[0..line_mod.where(field.text.items, field.at)];
                    cursor_col = @min(std.unicode.utf8CountCodepoints(before) catch before.len, span -| 1);
                    break :dotted mask(&dots, field.text.items, span);
                } else plain: {
                    const part = line_mod.window(field.text.items, field.at, span);
                    cursor_col = part.cursor;
                    break :plain part.text;
                };
                if (focused) {
                    app.typing.cursor = .{ .row = line, .col = at + cursor_col };
                }
                // A row too narrow for its labels puts the label inside the empty
                // field instead of dropping it: five fields in a line still say what
                // they are, and the moment one is filled in it speaks for itself.
                if (shown.len == 0 and packed_row and packed_label == 0) {
                    screen.style(.{
                        .bg = C.selected,
                        .fg = C.faint,
                        .italic = true,
                        .underline = true,
                        .underline_colour = if (focused) C.accent else C.faint,
                    });
                    pad(app, field.label, span, false);
                } else {
                    pad(app, shown, span, false);
                }
                at += span;
                screen.style(.{ .bg = C.selected });
                at += write(app, "  ", room(inner, at, indent));
            },
        }
        // What the value is, rather than what it is called: a column's type belongs
        // beside the field and not inside the name of it.
        if (field.after.len != 0) {
            screen.style(.{ .bg = C.selected, .fg = C.faint });
            at += write(app, field.after, room(inner, at, indent));
            screen.style(.{ .bg = C.selected });
            at += write(app, "  ", room(inner, at, indent));
        }
    }
    while (line + 1 < 2 + visible) : (line += 1) {
        screen.moveTo(line + 1, left);
        screen.style(.{ .bg = C.selected });
        fill(app, ' ', width);
    }
    screen.reset();
    box(app, 1, outer_left, outer_width, visible + 2, form.title, form.hint, C.accent);
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

/// The last `max` columns of a value - which is whatever a column held, so not
/// always UTF-8.
fn tail(text: []const u8, max: usize) []const u8 {
    if (term.width(text) <= max) {
        return text;
    }
    var start = text.len;
    var used: usize = 0;
    while (start > 0) {
        const char = term.decodeLast(text[0..start]);
        const w = term.charWidth(char.point);
        if (used + w > max) {
            break;
        }
        used += w;
        start -= char.len;
    }
    return text[start..];
}

fn info(app: *App, size: Size, side: usize, rows: usize) void {
    const screen = app.screen;
    const left = side;
    const width = size.cols -| left;
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();

    screen.moveTo(1, left);
    screen.style(.{ .fg = C.accent, .bold = true });
    _ = write(app, " ", width);
    _ = write(app, app.caps().label, width);
    screen.clearToEol();

    var lines = Lines.begin(app, left, rows);
    labelled(&lines, width, "connection", app.conn.describe());
    labelled(&lines, width, "version", app.conn.version());
    section(&lines, width, "SETTINGS");
    for (app.conn.settings(arena.allocator()) catch &[_]database.Setting{}) |setting| {
        const bad = std.mem.eql(u8, setting.label, "integrity") and !std.mem.eql(u8, setting.value, "ok");
        if (bad) {
            if (!lines.next()) {
                continue;
            }
            screen.style(.{ .fg = C.danger });
            _ = write(app, "  ", width);
            pad(app, setting.label, 18, false);
            _ = write(app, setting.value, width -| 22);
            screen.clearToEol();
            continue;
        }
        labelled(&lines, width, setting.label, setting.value);
    }
    lines.end(width);
}

/// Replace tabs with two spaces so indentation survives inside a panel.
fn expandTabs(scratch: std.mem.Allocator, line: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (line) |char| {
        if (char == '\t') {
            try out.appendSlice(scratch, "  ");
        } else {
            try out.append(scratch, char);
        }
    }
    return out.items;
}

fn labelled(lines: *Lines, width: usize, label: []const u8, value: []const u8) void {
    if (!lines.next()) {
        return;
    }
    const screen = lines.app.screen;
    screen.style(.{ .fg = C.dim });
    _ = write(lines.app, "  ", width);
    pad(lines.app, label, 18, false);
    screen.style(.{ .fg = C.text });
    _ = write(lines.app, value, width -| 22);
    screen.clearToEol();
}

/// Every foreign key in the database, as one overview of how it hangs together.
fn relations(app: *App, size: Size, side: usize, rows: usize) void {
    const screen = app.screen;
    const left = side;
    const width = size.cols -| left;
    screen.moveTo(1, left);
    screen.style(.{ .fg = C.accent, .bold = true });
    _ = write(app, " relations", width);
    screen.clearToEol();

    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    var lines = Lines.begin(app, left, rows);
    for (app.sidebar.objects.items) |object| {
        if (!std.mem.eql(u8, object.kind, "table")) {
            continue;
        }
        const keys = app.foreignKeyDefs(arena.allocator(), object.name) catch continue;
        for (keys) |key| {
            if (!lines.next()) {
                continue;
            }
            screen.style(.{ .fg = C.text });
            var used: usize = write(app, "  ", width);
            pad(app, object.name, 20, false);
            used += 20;
            screen.style(.{ .fg = C.dim });
            pad(app, key.column, 18, false);
            used += 18;
            screen.style(.{ .fg = C.faint });
            used += write(app, "-> ", width -| used);
            screen.style(.{ .fg = C.accent });
            used += write(app, key.target_table, width -| used);
            screen.style(.{ .fg = C.dim });
            used += write(app, ".", width -| used);
            used += write(app, key.target_column, width -| used);
            screen.style(.{ .fg = C.faint });
            used += write(app, "   ", width -| used);
            used += write(app, key.on_delete, width -| used);
            screen.clearToEol();
        }
    }
    const found = lines.count;
    lines.end(width);
    if (found == 0) {
        note(app, left, width, "no foreign keys in this database");
    }
}

// ------------------------------------------------------------------- tests
//
// The measuring, not the drawing: where text is cut when it does not fit, and
// what a password looks like when it is shown. Neither needs a terminal, and
// both are places a mistake is silent - a value cut in the middle of a character
// draws a replacement mark, and a mask that is one dot short of the truth says
// how long somebody's password is.

const testing = std.testing;

test "a path that does not fit keeps its end, and never breaks a character" {
    try testing.expectEqualStrings("/home/z", endOf("/home/z", 20));
    // `/home/zales/deep` says more as `deep` than as `/home`.
    try testing.expectEqualStrings("s/deep", endOf("/home/zales/deep", 7));
    // Too narrow to say anything: the whole thing back rather than one letter.
    try testing.expectEqualStrings("/home/zales", endOf("/home/zales", 1));
    // The cut lands on a character boundary, so what comes out is still text.
    const czech = endOf("/doma/žluťoučký", 6);
    try testing.expect(std.unicode.utf8ValidateSlice(czech));
    try testing.expect(term.width(czech) <= 6);
}

test "the last columns of a value are whole characters" {
    try testing.expectEqualStrings("ahoj", tail("ahoj", 10));
    try testing.expectEqualStrings("hoj", tail("ahoj", 3));
    try testing.expectEqualStrings("", tail("ahoj", 0));
    const wide = tail("žluťoučký kůň", 5);
    try testing.expect(std.unicode.utf8ValidateSlice(wide));
    try testing.expect(term.width(wide) <= 5);
}

test "the last columns of a value that is not UTF-8 are still the end of it" {
    // A column holds whatever bytes were put in it. A run of more continuation
    // bytes than any character has, a character cut short, a byte no character
    // starts with: each is one column of U+FFFD, and what comes back is the end
    // of the value rather than a read past either end of it.
    try testing.expectEqualStrings("\x80\x80", tail("\x80\x80\x80\x80\x80\x80", 2));
    try testing.expectEqualStrings("\xbe\xbe", tail("\xc5\xbe\xbe\xbe", 2));
    try testing.expectEqualStrings("ž\xbe", tail("ab\xc5\xbe\xbe", 2));
    for ([_][]const u8{ "\x80\x80\x80\x80\x80\x80", "abc\xbf\xbf\xbf\xbf\xbf", "\xe2\x82", "xyz\xe2\x82", "\xf0\x9f\x98", "\xff\xfe", "\xed\xa0\x80" }) |text| {
        var max: usize = 0;
        while (max <= 8) : (max += 1) {
            try testing.expect(std.mem.endsWith(u8, text, tail(text, max)));
            // And no wider than asked, measured the way it is drawn: `tail`
            // counted a column a broken byte while the drawing did not.
            try testing.expect(term.width(tail(text, max)) <= max);
        }
    }
}

test "a value is counted in the rows it is drawn in" {
    // Every line one column longer than a row: two rows each, where the count
    // used to say one, and the end of the value could not be scrolled to.
    const value = "aaaaaaaaaaa\nbbbbbbbbbbb\nccccccccccc\nEND";
    try testing.expectEqual(@as(usize, 7), rowsOf(value, 10));
    // A wide character is not cut in two, so a row of them holds one column less.
    try testing.expectEqual(@as(usize, 3), rowsOf("日本語日本語", 5));
    // Empty lines are rows; the end of the value after a last line break is not.
    try testing.expectEqual(@as(usize, 3), rowsOf("a\n\nb", 10));
    try testing.expectEqual(@as(usize, 1), rowsOf("a\n", 10));
    try testing.expectEqual(@as(usize, 0), rowsOf("", 10));
    // And the rows hold all of it, in order.
    var rest: []const u8 = value;
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(testing.allocator);
    while (rest.len != 0) {
        const piece = wrapRow(&rest, 10);
        try testing.expect(piece.cols <= 10);
        try joined.appendSlice(testing.allocator, piece.text);
    }
    try testing.expectEqualStrings("aaaaaaaaaaabbbbbbbbbbbcccccccccccEND", joined.items);
}

fn rowsOf(value: []const u8, cols: usize) usize {
    var rows: usize = 0;
    var rest = value;
    while (rest.len != 0) : (rows += 1) {
        _ = wrapRow(&rest, cols);
    }
    return rows;
}

test "a password is dots, and as many of them as it has characters" {
    var buffer: [64]u8 = undefined;
    // One dot per character, not per byte: `hěslo` is five, not six.
    try testing.expectEqual(@as(usize, 5), std.unicode.utf8CountCodepoints(mask(&buffer, "hěslo", 20)) catch 0);
    try testing.expectEqual(@as(usize, 0), mask(&buffer, "", 20).len);
    // Never more than the field can show, and never more than the buffer holds -
    // a long password in a narrow field is what would run past the end of both.
    try testing.expectEqual(@as(usize, 3), std.unicode.utf8CountCodepoints(mask(&buffer, "velmi dlouhe heslo", 3)) catch 0);
    var tiny: [6]u8 = undefined;
    try testing.expect(mask(&tiny, "velmi dlouhe heslo", 40).len <= tiny.len);
    // And nothing of the password itself comes back.
    try testing.expect(std.mem.find(u8, mask(&buffer, "hunter2", 20), "hunter2") == null);
}

// --------------------------------------------------------------- the frame
//
// On the bench - see bench.zig: a frame drawn into cells with no terminal
// behind them, and read back. tests/sizes.sh asks the same of a real terminal
// and takes ten minutes to; what is here is the part of that which is about
// the drawing and not about the terminal.

const Bench = @import("bench.zig").Bench;
const BOOKS = @import("bench.zig").BOOKS;

/// The column a piece of text starts in on a line of the screen, counted the
/// way the screen counts.
fn columnOf(line: []const u8, text: []const u8) ?usize {
    const at = std.mem.find(u8, line, text) orelse return null;
    return term.width(line[0..at]);
}

test "the header says what is open, and the line at the bottom what happened and what can be pressed" {
    var bench = try Bench.open(BOOKS);
    defer bench.close();
    try testing.expect(std.mem.startsWith(u8, try bench.line(0), " krtek /tmp/"));
    try testing.expect(std.mem.endsWith(u8, try bench.line(0), "2 objects"));
    // The last two lines: what was said, and the keys that mean something here.
    try testing.expect(std.mem.endsWith(u8, try bench.line(22), "bench.db - SQLite 3.50.4") or
        std.mem.find(u8, try bench.line(22), "bench.db - SQLite") != null);
    try testing.expect(std.mem.startsWith(u8, try bench.line(23), " enter opens"));
    // In the rows, the keys are the rows'.
    try bench.keys("{enter}");
    try testing.expect(std.mem.startsWith(u8, try bench.line(23), " i insert"));
}

test "a number is at the right of its column, text at the left, and NULL says so" {
    var bench = try Bench.open(
        \\CREATE TABLE t (n INTEGER, name TEXT, note TEXT);
        \\INSERT INTO t VALUES (7, 'seven', NULL), (1234, 'many', 'x');
    );
    defer bench.close();
    const first = try testing.allocator.dupe(u8, try bench.line(3));
    defer testing.allocator.free(first);
    const second = try bench.line(4);
    // The 7 ends where the 1234 ends.
    try testing.expectEqual(columnOf(second, "1234").? + 3, columnOf(first, "7").?);
    // The names start together.
    try testing.expectEqual(columnOf(first, "seven").?, columnOf(second, "many").?);
    try testing.expect(std.mem.find(u8, first, "NULL") != null);
}

test "a character two columns wide takes two, and the column after it starts where it does on every row" {
    var bench = try Bench.open(
        \\CREATE TABLE t (name TEXT, n INTEGER);
        \\INSERT INTO t VALUES ('ab', 11), ('日本', 22), ('ěščř', 33);
    );
    defer bench.close();
    var columns: [3]usize = undefined;
    for (0..3) |row| {
        const line = try bench.line(3 + row);
        const wanted = [_][]const u8{ "11", "22", "33" };
        columns[row] = columnOf(line, wanted[row]) orelse return error.TestExpectedEqual;
    }
    try testing.expectEqual(columns[0], columns[1]);
    try testing.expectEqual(columns[0], columns[2]);
}

test "a value longer than the room it has is cut, and says it was" {
    var bench = try Bench.open(
        \\CREATE TABLE t (body TEXT, n INTEGER);
        \\INSERT INTO t VALUES ('a very long value that goes on and on and on, well past what a column of a grid is ever given, and then some', 5);
    );
    defer bench.close();
    const line = try bench.line(3);
    try testing.expect(std.mem.find(u8, line, "a very long value") != null);
    try testing.expect(std.mem.find(u8, line, "and then some") == null);
    try testing.expect(std.mem.find(u8, line, "…") != null);
    // And what comes after it is still on the line.
    try testing.expect(std.mem.endsWith(u8, line, "5"));
}

test "the list of tables is as wide as the window allows, and gone where there is no room for it" {
    {
        var bench = try Bench.openWith(BOOKS, .{ .size = .{ .rows = 20, .cols = 100 } });
        defer bench.close();
        try bench.sees("TABLES & VIEWS");
        // Twenty-six columns of list, then the line between it and the rows.
        try testing.expectEqual(@as(?usize, 25), columnOf(try bench.line(1), "┃"));
    }
    {
        // A third of the width where that is less.
        var bench = try Bench.openWith(BOOKS, .{ .size = .{ .rows = 20, .cols = 60 } });
        defer bench.close();
        try bench.sees("TABLES & VIEWS");
        try testing.expectEqual(@as(?usize, 19), columnOf(try bench.line(1), "┃"));
    }
    {
        var bench = try Bench.openWith(BOOKS, .{ .size = .{ .rows = 20, .cols = 44 } });
        defer bench.close();
        try bench.lacks("TABLES & VIEWS");
        // The rows have the whole width, and are still the rows.
        try bench.sees("Karel Čapek");
    }
}

test "every screen is drawn inside the window, whatever size the window is" {
    // What tests/sizes.sh asks of a terminal, of the drawing: nothing may be
    // put past the right edge or below the bottom, and nothing may fall over,
    // on a window too small to be of any use as on one with room to spare.
    const sizes = [_]term.Size{
        .{ .rows = 6, .cols = 24 },   .{ .rows = 8, .cols = 30 },
        .{ .rows = 10, .cols = 44 },  .{ .rows = 12, .cols = 47 },
        .{ .rows = 14, .cols = 60 },  .{ .rows = 24, .cols = 80 },
        .{ .rows = 30, .cols = 118 }, .{ .rows = 50, .cols = 200 },
    };
    // A key that opens something, and the keys that put it away again.
    const screens = [_][2][]const u8{
        .{ "", "" },                            .{ "{enter}", "" },
        .{ "S", "{esc}" },                      .{ "?", "?" },
        .{ "gb", "gb" },                        .{ "gL", "gL" },
        .{ "gm", "gm" },                        .{ "{enter}gv", "{esc}" },
        .{ "{enter}i", "{esc}" },               .{ "a", "{esc}" },
        .{ "c", "{esc}" },                      .{ "W", "{esc}" },
        .{ "I", "{esc}" },                      .{ "K", "{esc}" },
        .{ "T", "{esc}" },                      .{ "E", "{esc}" },
        .{ "gM", "{esc}" },                     .{ "s", "{esc}{esc}" },
        .{ "{ctrl-k}", "{esc}" },               .{ ":", "{esc}" },
        .{ "y", "{esc}" },                      .{ "O", "{esc}" },
        .{ "Oa", "{esc}{esc}" },                .{ "Oe", "{esc}{esc}" },
        .{ "{ctrl-t}", "[" },
        // The list a choice is picked from, over the form that opened it.
                          .{ "K{down}{enter}", "{esc}{esc}" },
        .{ "K{down}{enter}zzz", "{esc}{esc}" },
    };
    for (sizes) |size| {
        var bench = try Bench.openWith(BOOKS, .{ .size = size });
        defer bench.close();
        for (screens) |entry| {
            try bench.keys(entry[0]);
            const text = try bench.screen();
            var lines = std.mem.splitScalar(u8, text, '\n');
            var count: usize = 0;
            while (lines.next()) |line| {
                if (term.width(line) > size.cols) {
                    std.debug.print("\n{d}x{d} after {s}: a line of {d} columns\n{s}\n", .{ size.cols, size.rows, entry[0], term.width(line), text });
                    return error.TestExpectedEqual;
                }
                count += 1;
            }
            // A line for every row and the empty one after the last.
            try testing.expectEqual(@as(usize, size.rows) + 1, count);
            try bench.keys(entry[1]);
        }
    }
}

test "a password is a dot for each character, with the cursor after the last" {
    var bench = try Bench.open(BOOKS);
    defer bench.close();
    bench.app.typing.prompt = .{ .kind = .password, .label = " password: " };
    // Two characters of two columns each, and one made of two code points.
    try bench.keys("日本x");
    const line = try bench.line(23);
    try testing.expectEqualStrings(" password: •••", line);
    try testing.expect(std.mem.find(u8, try bench.screen(), "日") == null);
    const cursor = bench.app.screen.vx.screen.cursor;
    try testing.expectEqual(@as(u16, 23), cursor.row);
    try testing.expectEqual(@as(u16, " password: ".len + 3), cursor.col);
}

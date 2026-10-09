//! State and behaviour of the terminal app: the schema, the loaded page of
//! rows, and everything that runs SQL. Drawing and input live next door and
//! only read from here, which keeps the imports a straight line.
//!
//! Not all of the behaviour is in this file. It was, and the file was five
//! thousand lines with a hundred and sixty-six methods on one struct. Four
//! parts of it that have little to do with one another are files of their own:
//! the forms (`forms.zig`), the one form that builds itself again as it is
//! filled in (`connection_form.zig`), opening a connection where it can be
//! watched and given up on (`dialing.zig`), and what the two file panes do
//! (`file_actions.zig`). They are still methods of the `App` - a key calls
//! `app.openRowForm()` as it always did - by the aliases at the top of the
//! struct, which is also the list of what is where.

const std = @import("std");
const database = @import("db");
const term = @import("term.zig");
const Form = @import("form.zig");
const csv = database.csv;
const dump_mod = @import("dump.zig");
const Editor = @import("editor.zig").Editor;
const sql_syntax = @import("editor.zig");
const fuzzy = @import("fuzzy.zig");
const conns = @import("connections.zig");
const keychain = @import("keychain.zig");
const biometry = @import("biometry.zig");
const Files = @import("files.zig");
const draw = @import("draw.zig");
const connection_form = @import("connection_form.zig");
const dialing = @import("dialing.zig");
const file_actions = @import("file_actions.zig");
const forms = @import("forms.zig");

pub const Term = term.Term;
pub const Connecting = dialing.Connecting;
pub const SPINNER = dialing.SPINNER;
const Attendant = dialing.Attendant;

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

/// The screen row the connection list's first entry is drawn on: the header, a
/// blank line and the panel's own top line come before it. Here rather than
/// written out twice, because the drawing and the mouse have to agree about it
/// and did not - a click selected the connection above the one clicked, and the
/// first could not be clicked at all.
pub const CONNECTIONS_FIRST: usize = 3;

/// How wide the list of objects is on a terminal this wide.
///
/// It used to be twenty-six columns or nothing: on a sixty-column window that
/// spent nearly half the screen on names, and one column narrower it took the
/// list away altogether. A third of the width, up to those twenty-six, shrinks
/// with the window instead. Below the point where a third is too narrow to read
/// a name in, there is still no list - a stripe of clipped words helps nobody,
/// and `tab` is not much use when there is nothing legible to move to.
pub fn sidebarWidth(cols: usize) usize {
    if (cols <= SIDEBAR + 20) {
        return 0;
    }
    return @min(SIDEBAR, cols / 3);
}

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
    /// The value as it came, where flattening changed it - and empty where it
    /// did not, so nothing is kept twice for the cells that are one line anyway.
    ///
    /// The whole-value view re-reads a value from the engine where there is a
    /// table and a key to re-read it by. A query result has neither: a Redis
    /// `INFO` is one cell of eighty lines, and what the view had to show was the
    /// grid's copy, with every newline already turned into a space.
    original: []const u8 = "",
    kind: Kind,

    /// The value as it was, for anything that is not the grid.
    pub fn whole(self: Cell) []const u8 {
        return if (self.original.len != 0) self.original else self.text;
    }

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
    /// What this one is among the others, where the engine sorts them: see
    /// `database.Object`. Empty means the list has no divisions.
    group: []const u8 = "",
    kind: []const u8,
    rows: ?i64,
};

pub const View = enum { grid, structure, messages, help, info, relations, connections, files, object };
pub const Focus = enum { sidebar, main };
/// A place on screen, in cells - and whether the cursor there is on a character
/// rather than between two, which is what the editor's normal mode is.
pub const Spot = struct { row: usize, col: usize, block: bool = false };

/// The command palette: what is typed, and which match is under the cursor.
/// Its entries live in `input.zig`, next to the keys they stand for.
pub const Palette = struct {
    query: std.ArrayList(u8) = .empty,
    at: usize = 0,
};

pub const PromptKind = enum { command, filter, edit, confirm, password, new_dir, rename_file, remove_files, overwrite, go_to, remove_rows };

pub const Prompt = struct {
    kind: PromptKind,
    label: []const u8,
    buffer: std.ArrayList(u8) = .empty,
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

/// Waiting on a terminal and a socket at once, with `select` rather than `poll`.
///
/// `poll` is the obvious call and on macOS it does not work here: given a
/// descriptor for `/dev/tty` it answers POLLNVAL - the descriptor is perfectly
/// good, and `read` on it returns what was typed - so a shell built on `poll`
/// there simply never sees a keystroke. `select` answers properly on both
/// systems, and its bitmap is one line to build.
const Waiter = struct {
    /// A thousand and twenty-four bits, which is what `fd_set` is on both
    /// systems. Little-endian words of any width put bit n in the same place, so
    /// counting in 32s is right on a 64-bit `fd_set` too.
    bits: [32]u32 = @splat(0),
    highest: c_int = 0,

    extern "c" fn select(nfds: c_int, r: ?*anyopaque, w: ?*anyopaque, e: ?*anyopaque, timeout: ?*std.c.timeval) c_int;

    fn watch(self: *Waiter, fd: std.c.fd_t) void {
        if (fd < 0 or fd >= 1024) {
            return;
        }
        self.bits[@intCast(@divTrunc(fd, 32))] |= @as(u32, 1) << @intCast(@mod(fd, 32));
        self.highest = @max(self.highest, fd + 1);
    }

    fn ready(self: *Waiter, fd: std.c.fd_t) bool {
        if (fd < 0 or fd >= 1024) {
            return false;
        }
        return (self.bits[@intCast(@divTrunc(fd, 32))] & (@as(u32, 1) << @intCast(@mod(fd, 32)))) != 0;
    }

    /// Wait for one of them, or for the time to run out. `select` clears the
    /// bits of whatever is not ready, so the set is built again each time.
    fn wait(self: *Waiter, ms: i64) void {
        var timeout = std.c.timeval{
            .sec = @intCast(@divFloor(ms, 1000)),
            .usec = @intCast(@mod(ms, 1000) * 1000),
        };
        _ = select(self.highest, &self.bits, null, null, &timeout);
    }
};

/// The object screen: what is known about the row that was opened, what can be
/// done to it, and which row it was.
///
/// An arena of its own, because all three are the engine's strings and they last
/// exactly as long as the screen does.
const Opened = struct {
    arena: std.heap.ArenaAllocator,
    title: []const u8 = "",
    facts: []const database.Setting = &.{},
    actions: []const database.Action = &.{},
    scroll: usize = 0,

    fn deinit(self: *Opened) void {
        self.arena.deinit();
    }
};

/// Reading a table again on a clock.
///
/// Following is what makes a log readable: the page stays on the end of the
/// table and records appear under the cursor as they are written, which for
/// Kafka is the difference between a topic and a transcript of one.
const Follow = struct {
    /// How often, in milliseconds, or 0 when the grid is not following at all.
    ms: u64 = 0,
    /// The interval the follow key turns on, and what `:follow` changes.
    every: u64 = 2000,
    /// While following, the window is counted from the end of the table instead
    /// of from a page boundary: the newest `limit` rows, always that many of them.
    /// Paged, the row that fills a page up would appear alone at the top of the
    /// next one - everything it followed pushed off the screen at exactly the
    /// moment somebody watching wants the context. Worked out by every reload, so
    /// it is never left over from an older one.
    tail_from: ?usize = null,
    /// The statement whose rows are on the grid, where a statement put them there
    /// rather than a table. Kept so the grid can be filled again - by `r`, and by
    /// the follow key on a clock - and only ever re-run where the engine says
    /// running it twice is the same as running it once.
    statement: std.ArrayList(u8) = .empty,

    fn deinit(self: *Follow, allocator: std.mem.Allocator) void {
        self.statement.deinit(allocator);
    }
};

/// Where the key map is scrolled to, and how many of its lines a screen holds.
///
/// The map is longer than a terminal is tall, and what did not fit used simply
/// not to be drawn - no mark, no mention, just an end that was not the end. The
/// page size is worked out while drawing, because only the drawing code knows
/// how many lines it had.
const Help = struct {
    scroll: usize = 0,
    page: usize = 10,
};

/// While something long is happening: when it started, when the spinner was last
/// drawn, which frame it is on, and whether the user has asked to stop.
///
/// A copy keeps its own clock. It is a different kind of long wait - one with an
/// end that can be estimated - and sharing the statement's would have the two
/// interrupt each other's spinners.
const Running = struct {
    started: f64 = 0,
    ticked: f64 = 0,
    frame: usize = 0,
    cancelled: bool = false,
    copy_started: f64 = 0,
    copy_ticked: f64 = 0,
};

/// What the program has told whoever is watching, and what it would say if
/// asked for more.
///
/// The line along the bottom is one sentence at a time; the reports behind it
/// are every statement of the last run, which `gm` opens. They share an arena
/// because they are made and thrown away together, once per run.
const Reporting = struct {
    arena: std.heap.ArenaAllocator,
    list: std.ArrayList(Report) = .empty,
    /// The line itself, and whether it is a complaint - which is the difference
    /// between a colour somebody reads past and one they stop at.
    status: std.ArrayList(u8) = .empty,
    status_error: bool = false,

    fn deinit(self: *Reporting, allocator: std.mem.Allocator) void {
        self.status.deinit(allocator);
        self.list.deinit(allocator);
        self.arena.deinit();
    }
};

/// Saved connections, where they live, and which of them is being worked on.
const Saved = struct {
    list: conns.List,
    path: std.ArrayList(u8) = .empty,
    /// The cursor in the connection list, and the first row drawn. A list of
    /// thirty is longer than most windows are tall, and before this it simply
    /// stopped drawing where the room ran out - so the cursor walked off the
    /// bottom and everything past it was unreachable.
    at: usize = 0,
    scroll: usize = 0,
    /// What was typed to narrow the list. The same fuzzy match the sidebar and
    /// the command palette use, on the name and on the target both - thirty-odd
    /// connections is more than anybody scrolls through, and half of them are
    /// told apart by their host rather than by the name somebody gave them.
    filter: std.ArrayList(u8) = .empty,
    /// How many entries were on screen last time it was drawn, so a page key can
    /// move by a page. The drawing is what knows this - it is the one that has the
    /// window and the hints to fit around.
    shown: usize = 0,
    /// The connection a password is being asked for.
    pending: std.ArrayList(u8) = .empty,
    /// Which saved connection the open form is editing, so changing both its name
    /// and its target replaces that entry instead of adding a second one.
    editing: ?usize = null,
    /// Something somebody asked for is in the list and not in its file, because
    /// the file could not be written when it was put there. Kept rather than said
    /// once: most of what changes the list goes on to open a connection, and what
    /// that has to say is written over the line a moment later. So it stays until
    /// the file has been written, and is said again wherever there is room to.
    unwritten: bool = false,

    /// A page, and never zero: a page key that moves by nothing looks broken.
    pub fn page(self: Saved) usize {
        return @max(1, self.shown);
    }
};

/// What is being typed, and what is waiting on the answer.
///
/// One prompt, one form, one editor - never two at once, which is why they sit
/// together rather than each keeping its own corner. The arena is the form's:
/// it is built again whenever the engine at the top of it changes, so what was
/// typed has to outlive the form it was typed into.
const Typing = struct {
    prompt: ?Prompt = null,
    form: ?Form.Form = null,
    arena: std.heap.ArenaAllocator,
    /// A statement waiting for a yes at the confirmation prompt.
    pending: std.ArrayList(u8) = .empty,
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
    cursor: ?Spot = null,
    /// Which engine the open connection form was built for: when the choice at the
    /// top of it changes, the fields under it are somebody else's.
    built_for: conns.Engine = .sqlite,
    /// What was in the editor when it was last put away without being run. Escape
    /// closes the editor, and in an editor with modes escape is also the key
    /// pressed twice to be sure of being in normal mode - so closing it cannot be
    /// what throws a statement away. The next time it opens, this is in it.
    draft: std.ArrayList(u8) = .empty,

    fn deinit(self: *Typing, allocator: std.mem.Allocator) void {
        if (self.prompt) |*prompt| {
            prompt.buffer.deinit(allocator);
        }
        if (self.form) |*form| {
            form.deinit();
        }
        if (self.editor) |*editor| {
            editor.deinit();
        }
        self.pending.deinit(allocator);
        self.draft.deinit(allocator);
        self.arena.deinit();
    }
};

/// The list down the left: every table and view the connection has, what has
/// been typed to narrow it, which one the cursor is on and where it is scrolled
/// to.
const Sidebar = struct {
    objects: std.ArrayList(Object) = .empty,
    filter: std.ArrayList(u8) = .empty,
    selected: usize = 0,
    /// The first one visible, which is what scrolling a list means.
    scroll: usize = 0,
    /// How many of them were on screen last time it was drawn. The drawing is
    /// what knows - a heading takes a line where a group starts - and the keys
    /// that go to the middle and the bottom of the screen need to be told.
    shown: usize = 0,

    /// Forget the objects. Their names are the list's own copies.
    fn clear(self: *Sidebar, allocator: std.mem.Allocator) void {
        for (self.objects.items) |object| {
            allocator.free(object.name);
            allocator.free(object.group);
            allocator.free(object.kind);
        }
        self.objects.clearRetainingCapacity();
    }

    fn deinit(self: *Sidebar, allocator: std.mem.Allocator) void {
        self.clear(allocator);
        self.objects.deinit(allocator);
        self.filter.deinit(allocator);
    }
};

/// Where the cursor is in the grid, what is scrolled off either edge of it, and
/// what has been picked out by hand.
///
/// A row can be ticked with space and a column can be put away, and both are
/// about this view of the table rather than about the table: they are forgotten
/// the moment a different one is opened.
const Cursor = struct {
    row: usize = 0,
    col: usize = 0,
    row_scroll: usize = 0,
    col_scroll: usize = 0,
    /// Row indexes ticked with space.
    marked: std.ArrayList(usize) = .empty,
    /// Column indexes put away, by index into the grid's own columns.
    hidden: std.ArrayList(usize) = .empty,
    /// How many rows the grid has room for, as last drawn: what "the middle of
    /// the screen" and "the bottom of it" are measured in.
    page: usize = 1,

    fn deinit(self: *Cursor, allocator: std.mem.Allocator) void {
        self.marked.deinit(allocator);
        self.hidden.deinit(allocator);
    }
};

/// The table on the screen: which one it is, what its columns are, the page
/// of rows in hand and how that page was asked for.
///
/// Everything here is about one view of one table. Opening another replaces
/// all of it, which is why it is one struct rather than seventeen fields that
/// have to be cleared in the right order.
const Grid = struct {
    /// null while a query result is shown. Owned by the app.
    name: ?[]const u8 = null,
    schema: std.ArrayList(u8) = .empty,
    title: std.ArrayList(u8) = .empty,
    cols: std.ArrayList([]const u8) = .empty,
    widths: std.ArrayList(usize) = .empty,
    rows: std.ArrayList(Row) = .empty,
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
    /// What the filter form put together: conditions an engine of any kind can
    /// honour. The strings are owned.
    conditions: std.ArrayList(database.ask.Filter) = .empty,
    /// The raw box of the filter form, which only an engine with SQL can use.
    where_text: std.ArrayList(u8) = .empty,
    /// The last reload could not be answered, and has said why. Whoever asked for
    /// it must not then report a count as though it had worked.
    failed: bool = false,
    text_limit: usize = 44, // widest column in the grid

    fn clearConditions(self: *Grid, allocator: std.mem.Allocator) void {
        for (self.conditions.items) |condition| {
            allocator.free(condition.column);
            allocator.free(condition.value);
        }
        self.conditions.clearRetainingCapacity();
    }

    /// The rows and the column names are not here: they are in the arena the
    /// page was read into, and go with it.
    fn deinit(self: *Grid, allocator: std.mem.Allocator) void {
        if (self.name) |value| {
            allocator.free(value);
        }
        if (self.order) |value| {
            allocator.free(value);
        }
        self.clearConditions(allocator);
        self.conditions.deinit(allocator);
        self.where_text.deinit(allocator);
        self.schema.deinit(allocator);
        self.title.deinit(allocator);
        self.cols.deinit(allocator);
        self.widths.deinit(allocator);
        self.rows.deinit(allocator);
    }
};

/// A place in a table worth coming back to: `m` and a letter leaves one, `'`
/// and the letter returns to it.
pub const Mark = struct {
    /// The table it was left in, or null where the grid held a statement's rows.
    /// Owned.
    table: ?[]const u8 = null,
    page: usize = 0,
    row: usize = 0,
    col: usize = 0,
};

/// One connection and everything about how it is being looked at: a tab.
///
/// The tab in front does not live here. Its state is in the App's own fields of
/// the same names, which is where every line of this program already reads it
/// from, and it is copied out to here when another tab comes forward and back
/// when this one does. That makes this struct the one list of what belongs to a
/// tab: the copying is written over its fields rather than by hand, and `deinit`
/// is the one place a tab is taken apart - there used to be three of those, and
/// they had already stopped agreeing.
pub const Tab = struct {
    arena: std.heap.ArenaAllocator, // the loaded page of rows
    conn: database.Db = undefined,
    connected: bool = false,
    path: []const u8 = "",
    owned_path: []u8 = &.{},
    /// Whether this connection was marked as one nothing may be written through.
    /// Read when it is opened and kept, rather than asked of the list every time,
    /// because the list can be edited while a connection is open and what is in
    /// force is what was in force when it was opened.
    read_only: bool = false,

    sidebar: Sidebar = .{},
    grid: Grid = .{},

    view: View = .connections,
    focus: Focus = .sidebar,
    detail: bool = false,
    detail_at: usize = 0,
    detail_page: usize = 1,
    detail_lines: usize = 1,

    object: Opened,
    follow: Follow = .{},
    cursor: Cursor = .{},
    /// Marks are places in this connection's tables, so they are this tab's.
    marks: [26]?Mark = @splat(null),
    typing: Typing,
    help: Help = .{},
    report: Reporting,
    files: ?*Files.Manager = null,
    running: Running = .{},

    /// A tab with nothing open in it.
    pub fn init(allocator: std.mem.Allocator) Tab {
        return .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .object = .{ .arena = std.heap.ArenaAllocator.init(allocator) },
            .typing = .{ .arena = std.heap.ArenaAllocator.init(allocator) },
            .report = .{ .arena = std.heap.ArenaAllocator.init(allocator) },
        };
    }

    /// Close the connection and give back everything the tab holds.
    pub fn deinit(self: *Tab, allocator: std.mem.Allocator) void {
        // The panes first: the far one reads through the connection. The manager
        // frees itself, which is why there is nothing here to destroy after it.
        if (self.files) |open| {
            open.deinit();
        }
        if (self.connected) {
            self.conn.close();
        }
        for (&self.marks) |*mark| {
            forget(allocator, mark);
        }
        self.sidebar.deinit(allocator);
        self.grid.deinit(allocator);
        self.cursor.deinit(allocator);
        self.follow.deinit(allocator);
        self.typing.deinit(allocator);
        self.report.deinit(allocator);
        self.object.deinit();
        allocator.free(self.owned_path);
        self.arena.deinit();
        self.* = undefined;
    }

    fn forget(allocator: std.mem.Allocator, mark: *?Mark) void {
        if (mark.*) |old| {
            if (old.table) |name| {
                allocator.free(name);
            }
        }
        mark.* = null;
    }
};

pub const App = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator, // the loaded page of rows
    screen: *Term,
    conn: database.Db,
    /// False while the connection list is on screen and nothing is open.
    connected: bool = false,
    path: []const u8,
    owned_path: []u8,

    /// Every tab, and which one is in front. The slot of the one in front is
    /// stale while it is there - see `Tab` - so anything that reads a slot calls
    /// `saveActiveTab` first.
    tabs: std.ArrayList(Tab) = .empty,
    active_tab: usize = 0,

    read_only: bool = false,
    marks: [26]?Mark = @splat(null),

    sidebar: Sidebar = .{},
    grid: Grid = .{},

    view: View = .grid,
    focus: Focus = .sidebar,
    detail: bool = false,
    /// The first line of the value shown in the detail box, and how many of them
    /// fit. A Redis `INFO` is a hundred lines and the box holds fifteen, so
    /// without these the other eighty-five could not be reached. Counted in lines
    /// as drawn rather than as stored: a long line wraps, and what somebody
    /// scrolls past is what is on the screen.
    detail_at: usize = 0,
    detail_page: usize = 1,
    detail_lines: usize = 1,

    object: Opened,
    follow: Follow = .{},

    cursor: Cursor = .{},

    typing: Typing,
    help: Help = .{},
    history: std.ArrayList([]const u8) = .empty,
    report: Reporting,

    quit: bool = false,

    saved: Saved,
    palette: ?Palette = null,
    /// The two panes, while the file manager is on screen. Null the rest of the
    /// time: a connection that holds rows has no business keeping one open.
    files: ?*Files.Manager = null,
    running: Running = .{},
    /// While a connection is being opened and until there is something of it
    /// to show. The program's rather than a tab's: it is on the screen for the
    /// length of one call and gone before any other tab could come forward.
    connecting: ?Connecting = null,
    /// Set once the App sits at its final address. `init` connects while the
    /// struct is still being built and returned by value, so the pointer handed
    /// to the driver then would dangle - the watch is armed from `main` instead,
    /// after init, and re-armed by every later connect.
    watch_armed: bool = false,
    env: *std.process.Environ.Map,

    // -------------------------------------------- what lives in other files
    //
    // Functions that take the App first, under the names they are called by.
    // Only the ones something outside their own file calls: what a file keeps
    // to itself is not here.

    // The two panes: file_actions.zig.
    pub const openFiles = file_actions.openFiles;
    pub const closeFiles = file_actions.closeFiles;
    pub const mayWriteTo = file_actions.mayWriteTo;
    pub const copyFiles = file_actions.copyFiles;
    pub const copyChosen = file_actions.copyChosen;
    pub const deleteFiles = file_actions.deleteFiles;
    pub const makeFileDir = file_actions.makeFileDir;
    pub const goToPath = file_actions.goToPath;
    pub const renameFile = file_actions.renameFile;

    // A connection being opened, watched and given up on: dialing.zig.
    pub const attend = dialing.attend;
    pub const dial = dialing.dial;
    pub const nowConnecting = dialing.nowConnecting;
    pub const gaveUp = dialing.gaveUp;

    // The form a connection is added or edited in: connection_form.zig.
    pub const openConnectionForm = connection_form.openConnectionForm;
    pub const afterFormKey = connection_form.afterFormKey;
    pub const saveConnection = connection_form.saveConnection;

    // Every other form, and what is done with one: forms.zig.
    pub const closeForm = forms.closeForm;
    pub const newForm = forms.newForm;
    pub const openRowForm = forms.openRowForm;
    pub const openTableForm = forms.openTableForm;
    pub const addFormRow = forms.addFormRow;
    pub const removeFormRow = forms.removeFormRow;
    pub const openIndexForm = forms.openIndexForm;
    pub const openForeignKeyForm = forms.openForeignKeyForm;
    pub const openViewForm = forms.openViewForm;
    pub const openTriggerForm = forms.openTriggerForm;
    pub const openRenameForm = forms.openRenameForm;
    pub const openCopyForm = forms.openCopyForm;
    pub const openSearchForm = forms.openSearchForm;
    pub const openFilterForm = forms.openFilterForm;
    pub const openColumnForm = forms.openColumnForm;
    pub const openSchemaForm = forms.openSchemaForm;
    pub const submitForm = forms.submitForm;

    // ----------------------------------------------------------- lifecycle

    /// Start with a connection, or with the list of saved ones when the target is
    /// empty. Nothing is opened before the screen exists, so a failure to connect
    /// lands on the list instead of quitting.
    pub fn init(allocator: std.mem.Allocator, target: []const u8, io: std.Io, env: *std.process.Environ.Map) !App {
        const screen = try Term.init(allocator, io, env);
        // A terminal taken over and then not given back is worse than whatever
        // went wrong after it.
        errdefer screen.deinit();
        return initOn(allocator, screen, target, env);
    }

    /// The same, on a screen that is already there - which is how a test gets
    /// one with no terminal behind it. The screen is the App's from here on.
    pub fn initOn(allocator: std.mem.Allocator, screen: *Term, target: []const u8, env: *std.process.Environ.Map) !App {
        var self = App{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .report = .{ .arena = std.heap.ArenaAllocator.init(allocator) },
            .object = .{ .arena = std.heap.ArenaAllocator.init(allocator) },
            .typing = .{ .arena = std.heap.ArenaAllocator.init(allocator) },
            .screen = screen,
            .conn = undefined,
            .connected = false,
            .path = "",
            .owned_path = try allocator.alloc(u8, 0),
            .saved = .{ .list = conns.List.init(allocator) },
            .env = env,
        };
        // The first tab. What is in it is what was just set up above.
        try self.tabs.append(allocator, undefined);
        self.saveActiveTab();
        var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        if (conns.path(&buffer, env)) |file| {
            try self.saved.path.appendSlice(allocator, file);
            conns.load(&self.saved.list, file) catch {};
        }
        self.offerFound();
        self.view = .connections;
        if (target.len != 0) {
            // Watched for the length of this one call, at the address the App
            // has for now, so that the first screen of a connection named on
            // the command line can be waited for - and given up on - like any
            // other. Taken off again straight after: the address is about to
            // change, and `main` arms it for good where the App ends up.
            self.watchStatements();
            self.connect(target, true) catch {};
            self.watch_armed = false;
            if (self.connected) {
                self.conn.watch(null);
            }
        } else if (self.saved.list.items.items.len == 0) {
            self.say("no saved connections yet - press a to add one", .{});
        } else {
            const found = self.saved.list.items.items.len - self.saved.list.savedCount();
            if (found != 0) {
                self.say("{d} saved, {d} from the kubeconfig - enter connects, a adds, d removes", .{
                    self.saved.list.savedCount(),
                    found,
                });
            } else {
                self.say("{d} saved connection(s) - enter connects, a adds, d removes", .{self.saved.list.items.items.len});
            }
        }
        return self;
    }

    /// Open a target and take it as the current connection. `remember` puts it in
    /// the saved list, without its password.
    pub fn connect(self: *App, target: []const u8, keep: bool) !void {
        var report: std.ArrayList(u8) = .empty;
        defer report.deinit(self.allocator);
        var naming = std.heap.ArenaAllocator.init(self.allocator);
        defer naming.deinit();
        // Nothing at all rather than the target as it came, where the password
        // cannot be taken out of it: this goes on the screen.
        const what = conns.withoutPassword(naming.allocator(), target) catch "";
        var attendant = self.attend(target, what);
        defer self.connecting = null;
        defer attendant.stop();
        const opened = self.dial(target, &report) catch |err| {
            attendant.stop();
            if (err == error.GivenUp) {
                self.say("gave up on {s}", .{what});
                self.view = .connections;
                return;
            }
            // A missing password is worth asking for rather than just failing.
            // `NeedPassword` is a driver saying so; `needsPassword` is this reading
            // the sentence it wrote, which is what everything did before any of them
            // could say it and is still all some of them offer.
            if (err == error.NeedPassword or needsPassword(report.items)) {
                var scratch = std.heap.ArenaAllocator.init(self.allocator);
                defer scratch.deinit();
                // What is asked again is the target without a password, not the one
                // that was just refused: `withPassword` adds one rather than
                // replacing it, so asking twice built `password=first&password=second`
                // and every attempt after that made the target longer.
                const bare = conns.withoutPassword(scratch.allocator(), target) catch target;
                const sent = !std.mem.eql(u8, bare, target);
                self.saved.pending.clearRetainingCapacity();
                try self.saved.pending.appendSlice(self.allocator, bare);
                self.typing.prompt = .{ .kind = .password, .label = " password: " };
                // A server with no password and a server with the wrong one both say
                // `password`, and there is no telling those apart by their words.
                // What can be told is whether one was sent - and answering somebody
                // who has just typed a password with "the server wants a password" is
                // indistinguishable from a form that does not work, which is what it
                // was taken for.
                if (sent) {
                    self.complain("{s}", .{report.items});
                } else {
                    self.say("the server wants a password", .{});
                }
                return;
            }
            self.complain("{s}", .{if (report.items.len != 0) report.items else "cannot open it"});
            self.view = .connections;
            return;
        };
        const entered = self.enter(opened, target, keep);
        attendant.stop();
        if (self.gaveUp()) {
            return;
        }
        try entered;
    }

    /// What `connect` does with a connection once it has one.
    fn enter(self: *App, opened: database.Db, target: []const u8, keep: bool) !void {
        try self.take(opened, target);
        if (keep) {
            try self.rememberConnection(target);
        }
        self.say("{s} - {s}", .{ self.conn.describe(), self.conn.version() });
        // Every way of changing the list that goes on to connect ends here, so
        // this is where a list that did not reach its file is said - after the
        // line above, which would otherwise be written over it.
        self.admitUnwritten();
        // A place that holds files opens on the files. The grid can show a
        // directory as a table and that is worth having, but it is not what
        // anybody connecting to a NAS came for, and nothing on that screen said
        // the two panes were a key away.
        if (self.conn.files() != null) {
            self.openFiles() catch {};
        }
    }

    /// Make a connection that has just been opened the one this tab is on, and
    /// read enough of it to have something to show: its first schema, what is in
    /// that, and the first of those.
    fn take(self: *App, opened: database.Db, target: []const u8) !void {
        if (self.connected) {
            self.conn.close();
        }
        // Whatever was being followed belongs to the connection being replaced,
        // and so do the places that were marked in it.
        self.setFollow(0);
        self.clearMarks();
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
        // Whether this one is marked read-only, looked up by what it points at
        // rather than by how it was reached: a target typed on the command line is
        // the same database as the saved entry with that target, and marking it in
        // the list would be worth nothing if a name on the command line went round
        // it. Read once, here, so editing the list under an open connection cannot
        // change what is in force in the middle of it.
        self.read_only = self.markedReadOnly();
        // The server has answered and the panel is still up: what it is waiting
        // for now is the first screen, which on a slow line is most of the wait.
        self.nowConnecting("connected, reading what is in it", .{});
        try self.setTable(null);
        self.grid.schema.clearRetainingCapacity();
        try self.firstSchema();
        self.clearConditions();
        self.grid.where_text.clearRetainingCapacity();
        self.cursor.hidden.clearRetainingCapacity();
        self.cursor.marked.clearRetainingCapacity();
        self.sidebar.selected = 0;
        self.grid.page = 0;
        self.view = .grid;
        try self.loadObjects();
        if (self.current()) |object| {
            self.nowConnecting("connected, opening {s}", .{object.name});
            try self.openTable(object.name);
        }
    }

    // --- the SQL editor ---

    pub fn openEditor(self: *App) !void {
        if (self.typing.editor != null) {
            return;
        }
        self.typing.editor = Editor.init(self.allocator);
        // Whatever was left in it the last time, which is what makes closing it
        // by accident a key to press again rather than a statement to write again.
        if (self.typing.draft.items.len != 0) {
            try self.typing.editor.?.setText(self.typing.draft.items);
            self.say("what was left here is back - ctrl+u empties it", .{});
            return;
        }
        // Not a list of keys: the footer has one, and saying it twice on one screen
        // teaches nobody anything the second time. What is worth saying here is what
        // this panel *is*, which is not the same thing on every engine.
        const allowed = self.caps();
        if (allowed.speaks_sql) {
            self.say("several statements at once - each one is reported on its own", .{});
        } else {
            self.say("{s} commands here, not SQL", .{if (allowed.label.len != 0) allowed.label else "engine"});
        }
    }

    /// Put the editor away, keeping what was in it for the next time it opens.
    pub fn closeEditor(self: *App) void {
        if (self.typing.editor) |*open| {
            self.typing.draft.clearRetainingCapacity();
            if (std.mem.trim(u8, open.text.items, " \t\r\n").len != 0) {
                self.typing.draft.appendSlice(self.allocator, open.text.items) catch {};
            }
            open.deinit();
        }
        self.typing.editor = null;
    }

    /// Run what is in the editor and close it, so the result is what is on
    /// screen. The text goes into the history either way.
    ///
    /// Except while a shell is open in a container, where it stays open and
    /// empties instead. A shell is a conversation - type, look, type again - and
    /// reaching for the key that opens the editor between every command turns
    /// three keystrokes into six.
    pub fn runEditor(self: *App) !void {
        const editor = &(self.typing.editor orelse return);
        const sql = std.mem.trim(u8, editor.text.items, " \t\r\n");
        if (sql.len == 0) {
            self.complain("nothing to run", .{});
            return;
        }
        const owned = try self.allocator.dupe(u8, sql);
        defer self.allocator.free(owned);
        // From here it is in the history, which is where a statement that was run
        // - or asked about and refused - is looked for again. It is not also kept
        // as what the editor reopens with.
        try self.remember(owned);
        // Something that makes or overwrites is asked about here, where a person
        // just typed it, rather than anywhere further in - and only here, so that
        // saying yes runs it rather than asking again.
        if (self.conn.confirming(sql)) |what| {
            self.closeEditor();
            self.typing.draft.clearRetainingCapacity();
            try self.confirm(owned, what);
            return;
        }
        const talking = self.conn.sessionIn().len != 0;
        if (talking) {
            editor.clear();
            editor.settle();
        } else {
            self.closeEditor();
            self.typing.draft.clearRetainingCapacity();
        }
        try self.runBatch(owned);
        // Opening one, or leaving it, changes which of the two this is.
        if (self.conn.sessionIn().len == 0 and self.typing.editor != null and talking) {
            self.closeEditor();
        } else {
            try self.followShell();
        }
    }

    /// Put an earlier statement in the editor; `delta` walks the history.
    pub fn editorHistory(self: *App, delta: isize) !void {
        const editor = &(self.typing.editor orelse return);
        if (self.history.items.len == 0) {
            return;
        }
        const last = self.history.items.len - 1;
        const at = switch (delta < 0) {
            true => if (editor.history_at) |value| (if (value == 0) 0 else value - 1) else last,
            false => if (editor.history_at) |value| (if (value >= last) last else value + 1) else last,
        };
        editor.history_at = at;
        // A statement from the history replaces what was typed, so what was typed
        // has to be something `u` brings back.
        editor.changing();
        try editor.setText(self.history.items[at]);
    }

    /// What tab offers: the names in this database, the columns of the table on
    /// screen, the tables the statement names and what it calls them, and SQL's
    /// own words. After a dot it is the columns of whatever is in front of the
    /// dot, and after JOIN the tables a foreign key leads to come first.
    pub fn completeInEditor(self: *App) !void {
        const editor = &(self.typing.editor orelse return);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        var names: std.ArrayList([]const u8) = .empty;

        const prefix = editor.word();
        // Only where what is being written is SQL: on an engine whose editor is a
        // console for its own commands there are no FROMs to read, no columns to
        // ask it for, and a dot in a word is part of a key or a file name.
        const sql = self.caps().speaks_sql;
        const aliases: []const sql_syntax.Alias = if (sql)
            sql_syntax.extractAliases(scratch, editor.text.items) catch &.{}
        else
            &.{};

        // `u.na`, `orders.` or `sales.orders.to`: the columns of what the dot
        // follows, written with it in front so the whole word is what is replaced.
        if (sql) {
            if (std.mem.findScalarLast(u8, prefix, '.')) |dot| {
                const qualifier = prefix[0..dot];
                if (self.tableCalled(aliases, qualifier)) |table| {
                    for (self.columnsFor(scratch, table)) |column| {
                        try names.append(scratch, try scratch.print("{s}.{s}", .{ qualifier, column }));
                    }
                    if (names.items.len > 0) {
                        try editor.complete(names.items);
                        return;
                    }
                }
            }
        }

        // After JOIN, what the tables already named point at.
        const before_word = std.mem.trimEnd(u8, editor.text.items[0 .. editor.cursor - prefix.len], " \t\r\n");
        if (aliases.len != 0 and endsWithWord(before_word, "JOIN")) {
            for (aliases) |named| {
                if (named.table.len == 0) {
                    continue;
                }
                const keys = self.conn.foreignKeys(scratch, self.inSchema(named.schema, named.table)) catch continue;
                for (keys) |key| {
                    try names.append(scratch, key.target_table);
                }
            }
        }

        for (aliases) |named| {
            try names.append(scratch, named.alias);
        }
        for (self.sidebar.objects.items) |object| {
            try names.append(scratch, object.name);
        }
        for (self.grid.cols.items) |column| {
            try names.append(scratch, column);
        }
        try names.appendSlice(scratch, sql_syntax.keywords());
        try editor.complete(names.items);
    }

    /// The table a qualifier stands for: an alias the statement gave, a table it
    /// named, a `schema.table`, or one of the tables in the list. Null where it
    /// is none of them, or is something with no columns to ask for.
    fn tableCalled(self: *App, aliases: []const sql_syntax.Alias, qualifier: []const u8) ?database.Table {
        for (aliases) |named| {
            if (std.ascii.eqlIgnoreCase(named.alias, qualifier)) {
                return if (named.table.len != 0) self.inSchema(named.schema, named.table) else null;
            }
        }
        if (std.mem.findScalarLast(u8, qualifier, '.')) |dot| {
            return .{ .schema = qualifier[0..dot], .name = qualifier[dot + 1 ..] };
        }
        for (self.sidebar.objects.items) |object| {
            if (std.ascii.eqlIgnoreCase(object.name, qualifier)) {
                return self.inSchema("", object.name);
            }
        }
        return null;
    }

    /// A table in the schema it was written with, or in the one being browsed
    /// where it was written with none - which is how every other question here
    /// is asked, and what this one left out.
    fn inSchema(self: *App, schema: []const u8, name: []const u8) database.Table {
        return .{ .schema = if (schema.len != 0) schema else self.grid.schema.items, .name = name };
    }

    /// The columns of a table: the grid's own where that is the table it is
    /// showing, and the engine's otherwise. Nothing at all rather than an error -
    /// this is asked on a tab key, half way through a word.
    fn columnsFor(self: *App, arena: std.mem.Allocator, table: database.Table) []const []const u8 {
        const on_screen = if (self.currentTable()) |open|
            std.ascii.eqlIgnoreCase(open.name, table.name) and std.ascii.eqlIgnoreCase(open.schema, table.schema)
        else
            false;
        if (on_screen and self.grid.cols.items.len != 0) {
            return self.grid.cols.items;
        }
        var out: std.ArrayList([]const u8) = .empty;
        for (self.conn.columns(arena, table) catch return &.{}) |column| {
            out.append(arena, column.name) catch return &.{};
        }
        return out.items;
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
        self.running.started = monotonicMs();
        // Far enough back that the first tick is not held off by the rate limit.
        self.running.ticked = self.running.started - 1000;
        self.running.frame = 0;
        self.running.cancelled = false;
    }

    /// Asked by the driver, every so often, whether to carry on. Draws the
    /// spinner and looks for ctrl+c - and works out on its own where one
    /// statement ends and the next begins, from the gap between calls.
    fn keepGoing(context: *anyopaque) bool {
        const self: *App = @ptrCast(@alignCast(context));
        if (self.connecting) |*state| {
            // The statements that follow a connection are part of opening it as
            // far as anybody watching can tell, so they keep its panel and its
            // key. Both are the attendant's for now - the screen is not this
            // thread's to draw on - and all there is to do here is pass on what
            // it heard. Giving up on one statement gives up on the rest, each
            // of which starts with `cancelled` cleared.
            self.running.cancelled = state.given_up.load(.acquire);
            return !self.running.cancelled;
        }
        const now = monotonicMs();
        if (now - self.running.ticked < 90) {
            return !self.running.cancelled;
        }
        self.running.ticked = now;
        if (self.screen.interrupted()) {
            self.running.cancelled = true;
            self.say("stopping...", .{});
        }
        // Anything under a third of a second should not flash a spinner at all.
        if (now - self.running.started > 300) {
            self.drawSpinner(now - self.running.started);
        }
        return !self.running.cancelled;
    }

    /// One line at the bottom, over the frame that is already on screen: vaxis
    /// writes only the cells that changed, so nothing else is touched.
    fn drawSpinner(self: *App, elapsed: f64) void {
        self.running.frame = (self.running.frame + 1) % SPINNER.len;
        const size = self.screen.size();
        var line: [160]u8 = undefined;
        const text = std.mem.print(&line, " {s} running {d:.1}s   ctrl+c stops it", .{
            SPINNER[self.running.frame],
            elapsed / 1000.0,
        }) catch return;
        self.screen.moveTo(size.rows - 2, 0);
        self.screen.style(.{ .bg = C.bar, .fg = if (self.running.cancelled) C.warn else C.accent, .bold = true });
        self.screen.put(text);
        self.screen.clearToEol();
        self.screen.reset();
        self.screen.flush() catch {};
    }

    /// Connections this program can find rather than ones somebody saved. A
    /// kubeconfig already says what a cluster is called and how to reach it, so
    /// asking for that a second time is asking for a place for it to be wrong.
    /// They go on the end of the list, marked, and are never written to the file.
    fn offerFound(self: *App) void {
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        for (database.k8s.contexts(scratch.allocator())) |context| {
            self.saved.list.offer(context.name, context.target) catch return;
        }
    }

    /// Keep a connection in the list, under a name derived from the target.
    fn rememberConnection(self: *App, target: []const u8) !void {
        if (self.saved.path.items.len == 0) {
            return;
        }
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const clean = try conns.withoutPassword(scratch.allocator(), target);
        if (self.saved.list.find(clean)) |at| {
            self.saved.list.touch(at);
            _ = self.writeList(.order);
        } else {
            try self.saved.list.add(try conns.suggestName(scratch.allocator(), clean), clean, null, "");
            _ = self.writeList(.asked);
        }
        self.admitUnwritten();
    }

    /// Write the list to its file, and know whether it got there.
    ///
    /// Five places wrote it and looked away: a connection saved from the form,
    /// one removed, a password said to be "now in" a file that had not been
    /// written - each was on the screen as done and gone the next time the
    /// program started, with nothing between the two to say why.
    ///
    /// What was changed says how much a failure matters. Opening a connection
    /// moves it to the front, which nobody asked for and nobody misses: a list
    /// somebody keeps read-only on purpose is still a list, and is not complained
    /// about every time it is used. Anything else is somebody's own change, and
    /// stays owed until a write goes through - which writes all of it, so one
    /// that does clears whatever the ones before it left.
    pub fn writeList(self: *App, changed: enum { asked, order }) bool {
        conns.save(&self.saved.list, self.saved.path.items) catch {
            if (changed == .asked) {
                self.saved.unwritten = true;
            }
            return false;
        };
        self.saved.unwritten = false;
        return true;
    }

    /// Say that the list is not in its file, where it is not - over whatever the
    /// line says now, which is why this comes last wherever it is called.
    fn admitUnwritten(self: *App) void {
        if (!self.saved.unwritten) {
            return;
        }
        if (self.saved.path.items.len == 0) {
            self.complain("the connection list has nowhere to be kept: neither XDG_CONFIG_HOME nor HOME is set", .{});
            return;
        }
        self.complain("the connection list could not be written, so it is as it was the next time this starts: {s}", .{self.saved.path.items});
    }

    /// Connect to the entry the cursor is on.
    pub fn connectSaved(self: *App) !void {
        const chosen = self.chosenSaved() orelse return;
        const entry = self.saved.list.items.items[chosen];
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        // A connection that keeps its password connects with it and never asks. The
        // keychain may put up its own dialog here; that answer is the user's.
        const secret: ?[]const u8 = switch (entry.keeps) {
            .ask => null,
            .file => entry.secret,
            .keychain => keychain.fetch(scratch.allocator(), entry.target) catch null,
            .touchid => blk: {
                // The keychain first, and the fingerprint after. Two reasons, and
                // neither is about what a fingerprint guards - this program's own
                // promise is that it will not *use* a saved password until somebody
                // at the keyboard says so, and that holds whichever order they come
                // in. What changes is what somebody is asked for nothing: a finger
                // before finding out that nothing has ever been kept for this
                // connection, or before macOS puts its own dialog up and is told no.
                const held = keychain.fetch(scratch.allocator(), entry.target) catch |err| {
                    if (err == error.Refused) {
                        // macOS asked and was refused, which is a different thing
                        // from nothing being there - and the difference matters,
                        // because the next thing on screen is a password prompt and
                        // somebody has to know which of the two it is answering.
                        self.complain("the keychain would not release the password for {s}", .{entry.name});
                    }
                    break :blk null;
                };
                const value = held orelse break :blk null;
                // Put it back the way this option needs it kept. An item made
                // before `touchid` existed - or made by `keychain` and switched
                // over afterwards - still carries the access it was given then,
                // which is the one that asks macOS's own question on every new
                // build. Storing what was just read costs nothing and means that
                // question is asked once rather than for ever.
                keychain.store(entry.target, value, .anyone) catch {};
                var reason: [160]u8 = undefined;
                const words = std.mem.print(&reason, "unlock the password for {s}", .{entry.name}) catch "unlock a saved password";
                // A refusal is not a failure to connect: it falls back to asking for
                // the password, which is what somebody who cannot use the reader
                // needs to be able to do.
                break :blk if (biometry.ask(words)) value else null;
            },
        };
        const with = if (secret) |value|
            try conns.withPassword(scratch.allocator(), entry.target, value)
        else
            entry.target;
        const target = try self.allocator.dupe(u8, with);
        defer self.allocator.free(target);
        // A found connection has no place in the file to be moved to the front of,
        // and touching it would only shuffle it among the ones that do.
        if (!entry.found) {
            self.saved.list.touch(chosen);
            self.saved.at = 0;
            _ = self.writeList(.order);
        }
        try self.connect(target, false);
    }

    /// Try again with the password that was just typed. It is used once and is
    /// not written anywhere.
    pub fn connectWithPassword(self: *App, password: []const u8) !void {
        if (self.saved.pending.items.len == 0) {
            return;
        }
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const target = try conns.withPassword(scratch.allocator(), self.saved.pending.items, password);
        const clean = try self.allocator.dupe(u8, self.saved.pending.items);
        defer self.allocator.free(clean);
        self.saved.pending.clearRetainingCapacity();
        try self.connect(target, false);
        if (!self.connected) {
            return;
        }
        try self.rememberConnection(clean);
        // The entry is at the front after rememberConnection; if it keeps its
        // password somewhere, this is the password to put there.
        if (self.saved.list.items.items.len == 0) {
            return;
        }
        switch (self.saved.list.items.items[0].keeps) {
            .ask => {},
            .file => {
                try self.saved.list.keep(0, .file, password);
                if (self.writeList(.asked)) {
                    self.say("connected, and the password is now in {s}", .{self.saved.path.items});
                }
            },
            .keychain, .touchid => {
                const target_now = self.saved.list.items.items[0].target;
                if (keychain.store(target_now, password, if (self.saved.list.items.items[0].keeps == .touchid) .anyone else .keychain)) |_| {
                    self.say("connected, and the password is now in the keychain", .{});
                } else |_| {
                    self.complain("connected, but the keychain would not take the password", .{});
                }
            },
        }
        self.admitUnwritten();
    }

    pub fn forgetSaved(self: *App) !void {
        const chosen = self.chosenSaved() orelse return;
        const going = self.saved.list.items.items[chosen];
        // Nothing here put it in the list, so nothing here takes it out: the file
        // it came from is where it lives.
        if (going.found) {
            self.complain("{s} comes from the kubeconfig - remove the context there", .{going.name});
            return;
        }
        var name: [128]u8 = undefined;
        const label = std.mem.print(&name, "{s}", .{going.name}) catch "it";
        if (going.keeps.inKeychain()) {
            keychain.remove(going.target);
        }
        _ = self.saved.list.items.orderedRemove(chosen);
        // The cursor counts what is on screen, and one fewer is showing now.
        if (self.saved.at >= self.savedCount() and self.saved.at > 0) {
            self.saved.at -= 1;
        }
        _ = self.writeList(.asked);
        self.say("{s} removed from the list", .{label});
        self.admitUnwritten();
    }

    /// The form for adding or editing a connection.
    /// Mark the connection under the cursor as one nothing may be written
    /// through, or unmark it.
    pub fn toggleReadOnly(self: *App) !void {
        const chosen = self.chosenSaved() orelse {
            self.complain("there is nothing to mark yet - press a to add a connection", .{});
            return;
        };
        const item = self.saved.list.items.items[chosen];
        const now = !item.read_only;
        if (item.found) {
            // A cluster from the kubeconfig has nowhere of its own to keep a mark,
            // and the kubeconfig is not this program's to write in - so marking one
            // saves a connection of this program's own with the same name and the
            // same target. The name is kept deliberately: what the form refuses is
            // renaming a found connection, because that leaves two answers to what a
            // cluster is called, and this leaves one.
            const name = try self.allocator.dupe(u8, item.name);
            defer self.allocator.free(name);
            const target = try self.allocator.dupe(u8, item.target);
            defer self.allocator.free(target);
            try self.saved.list.addWith(name, target, .ask, "", now);
            self.saved.at = 0;
        } else {
            self.saved.list.mark(chosen, now);
        }
        if (!self.writeList(.asked)) {
            self.admitUnwritten();
            return;
        }
        // What is in force for a connection already open was read when it opened,
        // so say what this did and did not change rather than leaving somebody to
        // find out by trying to write.
        const same = self.connected and std.mem.eql(u8, self.path, item.target);
        if (now) {
            self.say("{s} is read-only{s}", .{
                item.name,
                if (same) " from the next time it is opened" else "",
            });
        } else {
            self.say("{s} may be written to{s}", .{
                item.name,
                if (same) " from the next time it is opened" else "",
            });
        }
    }

    /// Say no to a batch with anything in it that is not a read, and name the
    /// statement that stopped it - "read-only" on its own leaves somebody looking
    /// for which of five statements it meant.
    fn refuseWrites(self: *App, sql: []const u8) bool {
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const statements = self.conn.split(scratch.allocator(), sql) catch {
            self.complain("this connection is read-only", .{});
            return true;
        };
        for (statements) |statement| {
            const text = std.mem.trim(u8, statement.sql, " \t\r\n;");
            if (text.len == 0 or database.readsOnly(text)) {
                continue;
            }
            // The first few words are enough to recognise it by, and the whole of a
            // long statement would push everything else off the line.
            const shown = if (text.len > 40) text[0..40] else text;
            self.complain("this connection is read-only: {s}{s}", .{
                shown,
                if (text.len > 40) "..." else "",
            });
            return true;
        }
        return false;
    }

    /// What this engine can do, and what this *connection* is allowed to do.
    ///
    /// A read-only connection is not a claim about the server - the account may
    /// have every privilege there is - so it cannot come from the driver. It is
    /// laid over the driver's answer here, in the one place everything asks, so
    /// that every key, every form and every footer hint follows from it without
    /// any of them knowing about it. The four texts are the reason and the flag
    /// at once, which is why saying it once is enough.
    pub fn caps(self: *App) database.Caps {
        // With nothing open there is no driver to ask, and the answer that asks
        // nothing of it is the plain one.
        if (!self.connected) {
            return .{};
        }
        var out = self.conn.caps();
        if (!self.read_only) {
            return out;
        }
        const why = "this connection is marked read-only; edit it with e in the connection list to change that";
        if (out.no_insert.len == 0) {
            out.no_insert = why;
        }
        if (out.no_update.len == 0) {
            out.no_update = why;
        }
        if (out.no_delete.len == 0) {
            out.no_delete = why;
        }
        if (out.no_ddl.len == 0) {
            out.no_ddl = why;
        }
        return out;
    }

    pub fn deinit(self: *App) void {
        self.screen.deinit();
        // Every tab the same way, the one in front included.
        self.saveActiveTab();
        for (self.tabs.items) |*tab| {
            tab.deinit(self.allocator);
        }
        self.tabs.deinit(self.allocator);
        // And what belongs to the program rather than to any of them.
        self.saved.filter.deinit(self.allocator);
        self.saved.list.deinit();
        self.saved.path.deinit(self.allocator);
        self.saved.pending.deinit(self.allocator);
        if (self.palette) |*open| {
            open.query.deinit(self.allocator);
        }
        for (self.history.items) |entry| {
            self.allocator.free(entry);
        }
        self.history.deinit(self.allocator);
    }

    /// The screen to fall back to: the grid of whatever is open, or the list of
    /// connections when nothing is. Every "back" goes through this, because a
    /// grid with no connection behind it is a screen whose every key asks a
    /// driver that is not there.
    pub fn home(self: *App) View {
        return if (self.connected) .grid else .connections;
    }

    /// Whether the connection now open is one the list marks read-only. Looked
    /// up by what it points at rather than by how it was reached: a target typed
    /// on the command line, or after `:open`, is the same database as the saved
    /// entry with that target, and marking it in the list would be worth nothing
    /// if a name typed somewhere else went round it.
    fn markedReadOnly(self: *App) bool {
        const at = self.saved.list.find(self.owned_path) orelse return false;
        return self.saved.list.items.items[at].read_only;
    }

    // --- marks ---

    /// Leave a mark on the row under the cursor.
    pub fn setMark(self: *App, letter: u8) void {
        if (letter < 'a' or letter > 'z') {
            return;
        }
        const table: ?[]const u8 = if (self.grid.name) |name|
            (self.allocator.dupe(u8, name) catch return)
        else
            null;
        const mark = &self.marks[letter - 'a'];
        Tab.forget(self.allocator, mark);
        mark.* = .{
            .table = table,
            .page = self.grid.page,
            .row = self.cursor.row,
            .col = self.cursor.col,
        };
        self.say("mark {c} is row {d}", .{ letter, self.firstRow() + self.cursor.row });
    }

    /// Go back to a mark: the table it was left in, the page, and the row.
    pub fn jumpMark(self: *App, letter: u8) !void {
        if (letter < 'a' or letter > 'z') {
            return;
        }
        const mark = self.marks[letter - 'a'] orelse {
            self.complain("there is no mark {c} - m{c} leaves one", .{ letter, letter });
            return;
        };
        if (mark.table) |name| {
            const here = if (self.grid.name) |open| std.mem.eql(u8, open, name) else false;
            if (!here) {
                // Only a table that is still in the list. A mark outlives a schema
                // being switched or a table being dropped, and opening a name the
                // engine no longer has puts an empty grid up under a title that
                // says it is that table.
                var known = false;
                for (self.sidebar.objects.items) |object| {
                    known = known or std.mem.eql(u8, object.name, name);
                }
                if (!known) {
                    self.complain("mark {c} was left in {s}, which is not here now", .{ letter, name });
                    return;
                }
                try self.openTable(name);
            }
            if (self.grid.failed) {
                return; // and the reload has said why
            }
            if (self.grid.page != mark.page and mark.page < self.pages()) {
                self.grid.page = mark.page;
                try self.reload();
            }
        }
        self.cursor.row = @min(mark.row, self.grid.rows.items.len -| 1);
        self.cursor.col = @min(mark.col, self.grid.cols.items.len -| 1);
        self.focus = .main;
        self.say("mark {c}", .{letter});
    }

    fn clearMarks(self: *App) void {
        for (&self.marks) |*mark| {
            Tab.forget(self.allocator, mark);
        }
    }

    // --- tabs ---

    pub fn tabCount(self: *App) usize {
        return self.tabs.items.len;
    }

    /// What a tab is called: the name its connection was saved under, or what
    /// the driver calls it where it was never saved.
    ///
    /// Not the table that happens to be open in it. Two tabs are usually two
    /// databases, the same table is in both far more often than not, and a strip
    /// that reads `authors` twice is the one thing a strip of tabs must not do:
    /// not say which of them is production.
    pub fn tabTitle(self: *App, index: usize) []const u8 {
        const front = index == self.active_tab;
        const tab = &self.tabs.items[index];
        if (!(if (front) self.connected else tab.connected)) {
            return "new";
        }
        if (self.saved.list.find(if (front) self.owned_path else tab.owned_path)) |at| {
            const name = self.saved.list.items.items[at].name;
            if (name.len != 0) {
                return name;
            }
        }
        const described = (if (front) self.conn else tab.conn).describe();
        return if (described.len != 0) described else "connection";
    }

    /// Put what is on screen away in its slot. See `Tab` for why it is not there
    /// already.
    pub fn saveActiveTab(self: *App) void {
        // A key that was waiting for its second one is not waiting any more: it
        // was pressed for the tab that is about to stop being the one in front,
        // and coming back to find the next key eaten by it is a puzzle.
        self.typing.prefix = null;
        const tab = &self.tabs.items[self.active_tab];
        inline for (@typeInfo(Tab).@"struct".field_names) |name| {
            @field(tab, name) = @field(self, name);
        }
    }

    /// And bring the tab now in front out of its slot.
    pub fn loadActiveTab(self: *App) void {
        const tab = &self.tabs.items[self.active_tab];
        inline for (@typeInfo(Tab).@"struct".field_names) |name| {
            @field(self, name) = @field(tab, name);
        }
        // The timer is the screen's and there is one of it, so it is set to
        // whatever this tab was doing: following starts again where it was on,
        // and stops where it was not. Left alone it kept the last tab's answer,
        // and a grid that says "following" over rows that are not being read is
        // worse than one that says nothing.
        self.screen.follow(self.follow.ms);
        if (self.follow.ms != 0 and !self.screen.following()) {
            self.follow.ms = 0;
        }
    }

    /// A new tab, in front, with nothing open in it - or with `target` opened.
    pub fn newTab(self: *App, target: ?[]const u8) !void {
        self.saveActiveTab();
        try self.tabs.append(self.allocator, Tab.init(self.allocator));
        self.active_tab = self.tabs.items.len - 1;
        self.loadActiveTab();
        if (target) |name| {
            if (name.len != 0) {
                try self.connect(name, true);
            }
        }
    }

    pub fn selectTab(self: *App, index: usize) void {
        if (index >= self.tabs.items.len or index == self.active_tab) {
            return;
        }
        self.saveActiveTab();
        self.active_tab = index;
        self.loadActiveTab();
    }

    pub fn nextTab(self: *App) void {
        self.selectTab((self.active_tab + 1) % self.tabs.items.len);
    }

    pub fn prevTab(self: *App) void {
        self.selectTab(if (self.active_tab == 0) self.tabs.items.len - 1 else self.active_tab - 1);
    }

    /// Open the connection under the cursor in a tab of its own - or in this
    /// one, where this one has nothing in it yet and a second empty tab would be
    /// one to close again.
    pub fn connectSavedInNewTab(self: *App) !void {
        if (self.chosenSaved() == null) {
            return;
        }
        if (self.connected) {
            try self.newTab(null);
        }
        try self.connectSaved();
    }

    /// Close a tab and what is open in it. The last one is emptied rather than
    /// removed: there is always a tab, and with nothing in it it is the list of
    /// connections.
    pub fn closeTab(self: *App, index: usize) void {
        if (index >= self.tabs.items.len) {
            return;
        }
        self.saveActiveTab();
        self.tabs.items[index].deinit(self.allocator);
        if (self.tabs.items.len == 1) {
            self.tabs.items[0] = Tab.init(self.allocator);
        } else {
            _ = self.tabs.orderedRemove(index);
            // The one in front stays in front. Where it was the one that closed,
            // the next takes its place - or the one before, at the end of the row.
            if (index < self.active_tab or self.active_tab == self.tabs.items.len) {
                self.active_tab -= 1;
            }
        }
        self.loadActiveTab();
    }

    /// Close every tab but the one in front.
    pub fn closeOtherTabs(self: *App) void {
        while (self.tabs.items.len > 1) {
            self.closeTab(if (self.active_tab == 0) 1 else 0);
        }
    }

    /// The table on screen, with the schema it lives in.
    pub fn currentTable(self: *App) ?database.Table {
        return .{ .schema = self.grid.schema.items, .name = self.grid.name orelse return null };
    }

    pub fn hasTable(self: *App) bool {
        return self.grid.name != null;
    }

    pub fn setTable(self: *App, name: ?[]const u8) !void {
        if (self.grid.name) |old| {
            self.allocator.free(old);
        }
        self.grid.name = if (name) |value| try self.allocator.dupe(u8, value) else null;
        // A table on the grid is not a statement's rows any more, so nothing is
        // left behind for `r` to run instead of reading the table.
        if (name != null) {
            self.follow.statement.clearRetainingCapacity();
        }
    }

    pub fn say(self: *App, comptime fmt: []const u8, args: anytype) void {
        self.report.status.clearRetainingCapacity();
        self.report.status.print(self.allocator, fmt, args) catch {};
        self.report.status_error = false;
    }

    pub fn complain(self: *App, comptime fmt: []const u8, args: anytype) void {
        self.say(fmt, args);
        self.report.status_error = true;
    }

    pub fn setTitle(self: *App, comptime fmt: []const u8, args: anytype) void {
        self.grid.title.clearRetainingCapacity();
        self.grid.title.print(self.allocator, fmt, args) catch {};
    }

    // -------------------------------------------------------------- schema

    fn freeObjects(self: *App) void {
        self.sidebar.clear(self.allocator);
    }

    pub fn loadObjects(self: *App) !void {
        self.freeObjects();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        for (try self.conn.objects(arena.allocator(), self.grid.schema.items)) |object| {
            try self.sidebar.objects.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, object.name),
                .group = try self.allocator.dupe(u8, object.group),
                .kind = try self.allocator.dupe(u8, if (object.kind == .view) "view" else "table"),
                .rows = object.rows,
            });
        }
        // An engine that only estimates gets an exact count, which is what the
        // sidebar promises.
        for (self.sidebar.objects.items) |*object| {
            if (object.rows == null or object.rows.? < 0) {
                object.rows = self.conn.rowCount(.{ .schema = self.grid.schema.items, .name = object.name });
            }
        }
        // The cursor stays on the list. Where the last object in it has just
        // gone - dropped, with the cursor on it - the cursor was past the end
        // and on nothing: no table was opened in its place, and the grid kept
        // the count of the one that was gone over an invitation to insert a
        // row into it.
        const count = self.visibleCount();
        if (self.sidebar.selected >= count) {
            self.sidebar.selected = count -| 1;
        }
    }

    pub fn matches(self: *App, index: usize) bool {
        // The same fuzzy match as the command palette: `usr` finds `users`, and
        // `ordit` finds `order_items`.
        return self.sidebar.filter.items.len == 0 or
            fuzzy.match(self.sidebar.objects.items[index].name, self.sidebar.filter.items, null) != null;
    }

    /// Which letters of an object's name the filter matched, for the sidebar.
    pub fn filterHit(self: *App, name: []const u8) fuzzy.Hit {
        var hit = fuzzy.Hit{};
        if (self.sidebar.filter.items.len != 0) {
            _ = fuzzy.match(name, self.sidebar.filter.items, &hit);
        }
        return hit;
    }

    /// Whether the connection at `index` in the whole list is one the filter
    /// leaves showing.
    pub fn savedMatches(self: *App, index: usize) bool {
        const item = self.saved.list.items.items[index];
        return connectionMatches(item.name, item.target, self.saved.filter.items);
    }

    /// Which letters of a name the filter landed on, for the drawing.
    pub fn savedHit(self: *App, text: []const u8) fuzzy.Hit {
        var hit = fuzzy.Hit{};
        if (self.saved.filter.items.len != 0) {
            _ = fuzzy.match(text, self.saved.filter.items, &hit);
        }
        return hit;
    }

    pub fn savedCount(self: *App) usize {
        if (self.saved.filter.items.len == 0) {
            return self.saved.list.items.items.len;
        }
        var count: usize = 0;
        for (0..self.saved.list.items.items.len) |i| {
            count += @intFromBool(self.savedMatches(i));
        }
        return count;
    }

    /// Where in the whole list the entry shown at position `n` is. The cursor
    /// counts what is on screen, the way the sidebar's does, so everything that
    /// wants the entry itself comes through here.
    pub fn savedIndex(self: *App, n: usize) ?usize {
        if (self.saved.filter.items.len == 0) {
            return if (n < self.saved.list.items.items.len) n else null;
        }
        var seen: usize = 0;
        for (0..self.saved.list.items.items.len) |i| {
            if (!self.savedMatches(i)) {
                continue;
            }
            if (seen == n) {
                return i;
            }
            seen += 1;
        }
        return null;
    }

    /// The entry the cursor is on, in the whole list.
    pub fn chosenSaved(self: *App) ?usize {
        return self.savedIndex(self.saved.at);
    }

    pub fn visibleCount(self: *App) usize {
        var count: usize = 0;
        for (0..self.sidebar.objects.items.len) |i| {
            count += @intFromBool(self.matches(i));
        }
        return count;
    }

    /// The object shown at visible position `n`.
    pub fn visibleAt(self: *App, n: usize) ?Object {
        var seen: usize = 0;
        for (0..self.sidebar.objects.items.len) |i| {
            if (!self.matches(i)) {
                continue;
            }
            if (seen == n) {
                return self.sidebar.objects.items[i];
            }
            seen += 1;
        }
        return null;
    }

    pub fn current(self: *App) ?Object {
        return self.visibleAt(self.sidebar.selected);
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
            .int => |v| try arena.print("{d}", .{v}),
            .float => |v| try arena.print("{d}", .{v}),
        };
    }

    /// Column names of a table, in declared order.
    /// Column names in order, for the forms and the dumps.
    pub fn columnsOf(self: *App, arena: std.mem.Allocator, name: []const u8) ![]const []const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        for (try self.conn.columns(arena, .{ .schema = self.grid.schema.items, .name = name })) |column| {
            try list.append(arena, column.name);
        }
        return list.items;
    }

    pub fn columnDefs(self: *App, arena: std.mem.Allocator, name: []const u8) ![]database.Column {
        return self.conn.columns(arena, .{ .schema = self.grid.schema.items, .name = name });
    }

    pub fn foreignKeyDefs(self: *App, arena: std.mem.Allocator, name: []const u8) ![]database.ForeignKey {
        return self.conn.foreignKeys(arena, .{ .schema = self.grid.schema.items, .name = name });
    }

    // ----------------------------------------------------------- data load

    pub fn openTable(self: *App, name: []const u8) !void {
        try self.setTable(name);
        self.grid.page = 0;
        self.cursor.row = 0;
        self.cursor.col = 0;
        self.cursor.row_scroll = 0;
        self.cursor.col_scroll = 0;
        if (self.grid.order) |value| {
            self.allocator.free(value);
            self.grid.order = null;
        }
        self.grid.descending = false;
        self.cursor.marked.clearRetainingCapacity();
        self.cursor.hidden.clearRetainingCapacity();
        self.clearConditions();
        self.grid.where_text.clearRetainingCapacity();
        self.view = .grid;
        try self.reload();
    }

    pub fn reload(self: *App) !void {
        // Before either way of reading again: `failed` is about the last one,
        // and what a statement left on the grid is not a table that failed.
        self.grid.failed = false;
        const table = self.currentTable() orelse return self.reloadStatement();
        const counted = if (!self.isFiltered())
            self.conn.rowCount(table)
        else
            self.conn.count(self.filtered(table));
        self.grid.counted = counted != null;
        self.grid.total = counted orelse 0;

        const page_count = self.pages();
        // Following means staying where new rows land, and that moves as the table
        // grows: the end of it, or the beginning when the order is reversed and the
        // end is drawn at the top. An engine that cannot count has no end to go to,
        // so its view is left where it is.
        self.follow.tail_from = null;
        if (self.follow.ms != 0 and self.grid.counted) {
            self.grid.page = if (self.grid.descending) 0 else page_count - 1;
            if (!self.grid.descending) {
                self.follow.tail_from = @intCast(@max(0, self.grid.total - @as(i64, @intCast(self.grid.limit))));
            }
        } else if (self.grid.page >= page_count) {
            self.grid.page = page_count - 1;
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
        if (self.grid.order) |column| {
            request.order = column;
            request.descending = self.grid.descending;
        }
        request.limit = self.grid.limit;
        request.offset = self.firstRow() - 1;

        self.loadSelect(request, table, hidden_key) catch {
            self.grid.cols.clearRetainingCapacity();
            self.grid.rows.clearRetainingCapacity();
            self.grid.widths.clearRetainingCapacity();
            self.grid.total = 0;
            self.grid.failed = true;
            self.complain("{s}", .{self.conn.message()});
            return;
        };
        if (self.follow.ms != 0) {
            // On the newest row, so the grid scrolls to it and the record just
            // written is the one under the cursor.
            self.cursor.row = if (self.grid.descending) 0 else self.grid.rows.items.len -| 1;
        }
        self.setTitle("{s}", .{table.name});
    }

    /// Open the row the cursor is on: a screen about that one thing, with what can
    /// be done to it along the bottom.
    ///
    /// Whether there is such a screen is the engine's to say. A database row is
    /// already all of itself and opening one means editing it, which is what
    /// `enter` has always done; a Kubernetes object is a document with a
    /// controller behind it, and what somebody wants from it is its state, its
    /// events, its logs and a shell - none of which is in the row.
    pub fn openRow(self: *App) !bool {
        const table = self.currentTable() orelse return false;
        if (self.cursor.row >= self.grid.rows.items.len) {
            return false;
        }
        const name = self.rowName() orelse return false;
        _ = self.object.arena.reset(.retain_capacity);
        const arena = self.object.arena.allocator();
        const facts = (self.conn.rowDetail(arena, table, name) catch null) orelse return false;
        self.object.facts = facts;
        self.object.actions = self.conn.rowActions(arena, table, name) catch &.{};
        self.object.title = try arena.print("{s}", .{name});
        self.object.scroll = 0;
        self.view = .object;
        return true;
    }

    /// What the row the cursor is on is called, by the key the engine gave it.
    fn rowName(self: *App) ?[]const u8 {
        const row = self.grid.rows.items[self.cursor.row];
        if (row.key) |key| {
            if (database.ask.only(key, "name")) |name| {
                return name;
            }
            if (key.len != 0) {
                return key[0].value;
            }
        }
        for (self.grid.cols.items, 0..) |column, i| {
            if (std.mem.eql(u8, column, "name") and i < row.cells.len) {
                return row.cells[i].text;
            }
        }
        return null;
    }

    /// Run what an action on the object screen says. It is the engine's own
    /// console line, so this neither knows nor cares what it does.
    pub fn runObjectAction(self: *App, action: database.Action) !void {
        const owned = try self.allocator.dupe(u8, action.statement);
        defer self.allocator.free(owned);
        self.view = .grid;
        try self.runBatch(owned);
        try self.followShell();
    }

    /// A shell that has just been opened needs somewhere to be typed into, and one
    /// that has just closed leaves an editor with nothing to say. Called wherever
    /// a statement may have opened or closed one.
    fn followShell(self: *App) !void {
        const talking = self.conn.sessionIn().len != 0;
        if (talking and self.typing.editor == null) {
            try self.openEditor();
        } else if (!talking and self.typing.editor != null and self.typing.editor.?.text.items.len == 0) {
            self.closeEditor();
        }
    }

    pub fn closeObject(self: *App) void {
        self.object.facts = &.{};
        self.object.actions = &.{};
        self.object.title = "";
        self.view = .grid;
    }

    /// Hand the terminal to a shell in a container until it ends.
    ///
    /// Two things are being waited on and neither may be sat upon: what is typed
    /// has to reach the container without the screen having to change, and what
    /// the container says has to arrive without a key having to be pressed. So
    /// both the terminal and the socket are polled together, with a tick short
    /// enough that a shell feels like a shell.
    pub fn runShell(self: *App, statement: []const u8) !void {
        const session = (self.conn.shell(statement) catch {
            self.complain("{s}", .{self.conn.message()});
            return;
        }) orelse return;
        defer session.deinit();

        self.screen.release();
        defer {
            self.screen.reclaim();
            self.screen.reset();
        }
        const size = self.screen.size();
        session.resize(size.cols, size.rows);
        self.screen.writeRaw("\r\n");

        var out: database.List = .empty;
        defer out.deinit(self.allocator);
        var last = size;
        const terminal = self.screen.handle();
        const socket = session.handle();
        var typed: [4096]u8 = undefined;
        while (true) {
            var waiting = Waiter{};
            waiting.watch(terminal);
            waiting.watch(socket);
            // Short enough that the window being resized is noticed while somebody
            // is still dragging the corner.
            waiting.wait(50);
            if (waiting.ready(terminal)) {
                const got = self.screen.readRaw(&typed);
                if (got != 0) {
                    session.write(typed[0..got]) catch break;
                }
            }
            out.clearRetainingCapacity();
            const alive = session.read(&out) catch false;
            if (out.items.len != 0) {
                self.screen.writeRaw(out.items);
            }
            if (!alive) {
                break;
            }
            // The window may have changed while somebody else had the screen, and
            // a shell that thinks it is eighty columns wide when it is not draws
            // everything in the wrong place.
            const now = self.screen.size();
            if (now.cols != last.cols or now.rows != last.rows) {
                session.resize(now.cols, now.rows);
                last = now;
            }
        }

        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const said = session.why(scratch.allocator());
        if (said.len != 0) {
            self.complain("{s}", .{said});
        } else {
            self.say("the shell ended", .{});
        }
    }

    /// Fill the grid again from the statement that filled it, where a statement
    /// did. Only where the engine says running it twice is the same as running it
    /// once: a console with `PRODUCE` and `SCALE` in it has statements that must
    /// happen exactly as often as they were typed.
    fn reloadStatement(self: *App) !void {
        if (self.follow.statement.items.len == 0) {
            return;
        }
        if (!self.conn.repeatable(self.follow.statement.items)) {
            if (self.follow.ms != 0) {
                self.setFollow(0);
            }
            self.complain("that is not something to run again on its own", .{});
            return;
        }
        // Whether the newest line is the one being looked at. A log that is being
        // followed should show its end - that is the whole reason for watching one
        // - but only while whoever is watching is already there. Scrolling up to
        // read something is not an invitation to be dragged back two seconds later.
        const at_end = self.grid.rows.items.len == 0 or
            self.cursor.row + 1 >= self.grid.rows.items.len;

        // Its own copy: running it fills the grid, and filling the grid is what
        // owns the memory this was read from.
        const again = try self.allocator.dupe(u8, self.follow.statement.items);
        defer self.allocator.free(again);
        try self.runBatchStopping(again, true);

        if (self.follow.ms != 0 and at_end and self.grid.rows.items.len != 0) {
            self.cursor.row = self.grid.rows.items.len - 1;
        }
    }

    /// Whether there is anything for `r` and the follow key to read again.
    pub fn hasRows(self: *App) bool {
        return self.hasTable() or
            (self.follow.statement.items.len != 0 and self.conn.repeatable(self.follow.statement.items));
    }

    /// Read the open table every `ms` milliseconds, or stop with 0. The timer
    /// itself lives in the screen, because waking the key loop is the one thing
    /// only the screen can do.
    pub fn setFollow(self: *App, ms: u64) void {
        self.follow.ms = ms;
        self.screen.follow(ms);
        if (ms != 0 and !self.screen.following()) {
            self.follow.ms = 0;
            self.complain("there is no timer to follow with", .{});
            return;
        }
        // Following means "show me what arrives", so it starts by showing what has
        // arrived already. A log opened at line one and followed from there would
        // grow at the end nobody is looking at - which is what it did.
        //
        // A table needs no help here: it is asked for its last page instead, which
        // is what `tail_from` is. This is for the rows a statement put on the grid,
        // where the whole of it is already in hand.
        if (ms != 0 and !self.hasTable() and self.grid.rows.items.len != 0) {
            self.cursor.row = self.grid.rows.items.len - 1;
        }
    }

    /// A tick from that timer: read the table again and stay at the end of it.
    /// Nothing is said on the status line - a message every two seconds would bury
    /// whatever is already there - and anything modal is left alone, because a
    /// grid that reloads under a half-typed form is worse than one that waits.
    pub fn followTick(self: *App) void {
        if (self.follow.ms == 0 or self.view != .grid or !self.hasRows()) {
            return;
        }
        if (self.typing.prompt != null or self.typing.form != null or self.typing.editor != null or self.files != null or self.detail) {
            return;
        }
        self.reload() catch {};
        // A table that cannot be read now will not read any better in two seconds,
        // and reload has already said why: stop rather than say it again forever.
        if (self.grid.failed) {
            self.setFollow(0);
        }
    }

    /// The table as the grid is looking at it: whatever the filter row says, and
    /// nothing else. The page, the order and the hidden key are added by whoever
    /// needs them, because a count wants none of the three.
    fn filtered(self: *App, table: database.Table) database.ask.Select {
        return .{
            .table = table,
            .where = self.grid.conditions.items,
            .where_text = self.grid.where_text.items,
        };
    }

    /// Whether the grid is showing part of a table rather than all of it.
    pub fn isFiltered(self: *App) bool {
        return self.grid.conditions.items.len != 0 or self.grid.where_text.items.len != 0;
    }

    pub fn clearConditions(self: *App) void {
        self.grid.clearConditions(self.allocator);
    }

    pub fn isHidden(self: *App, column: usize) bool {
        return std.mem.findScalar(usize, self.cursor.hidden.items, column) != null;
    }

    pub fn isMarked(self: *App, row: usize) bool {
        return std.mem.findScalar(usize, self.cursor.marked.items, row) != null;
    }

    pub fn toggleMark(self: *App) !void {
        if (self.cursor.row >= self.grid.rows.items.len) {
            return;
        }
        if (std.mem.findScalar(usize, self.cursor.marked.items, self.cursor.row)) |at| {
            _ = self.cursor.marked.orderedRemove(at);
        } else {
            try self.cursor.marked.append(self.allocator, self.cursor.row);
        }
    }

    /// Delete the marked rows, or the one under the cursor when none are marked.
    /// Say why the row under the cursor cannot be changed, and whether that is so.
    /// An empty result and a result without a key are two different things, and
    /// saying "read-only" for both sent someone looking for a bug that was not
    /// there.
    pub fn noRowHere(self: *App) bool {
        if (self.grid.rows.items.len == 0) {
            self.complain("there is no row here", .{});
            return true;
        }
        if (!self.grid.editable) {
            self.complain("these rows cannot be addressed, so they are read-only", .{});
            return true;
        }
        if (self.cursor.row >= self.grid.rows.items.len) {
            self.complain("move onto a row first", .{});
            return true;
        }
        return false;
    }

    pub fn deleteRows(self: *App) !void {
        // Asked first, and asked here rather than of the key: the mark on a
        // connection is laid over what the engine can do, and inserting and
        // editing both ask before they start. Deleting did not, so the footer
        // stopped offering `x` on a read-only connection and `x` went on
        // deleting.
        const refused = self.caps().no_delete;
        if (refused.len != 0) {
            self.complain("{s}", .{refused});
            return;
        }
        if (self.grid.rows.items.len != 0 and !self.grid.editable) {
            self.complain("these rows cannot be addressed, so they are read-only", .{});
            return;
        }
        if (self.grid.rows.items.len == 0) {
            self.complain("there is no row here", .{});
            return;
        }
        // Where nothing takes a delete back - a row that is a file, a row that is a
        // Kubernetes object - it is asked about first. A database row goes as it
        // always has, because a transaction is there to take it out of.
        const allowed = self.caps();
        if (self.conn.files() != null or allowed.final_deletes) {
            const count = if (self.cursor.marked.items.len != 0) self.cursor.marked.items.len else @as(usize, 1);
            const noun = if (self.conn.files() != null) "file" else allowed.row_noun;
            if (self.typing.prompt) |*old| {
                old.buffer.deinit(self.allocator);
            }
            self.typing.prompt = .{ .kind = .remove_rows, .label = " type y to delete: " };
            self.say("delete {d} {s}{s}?", .{ count, noun, if (count == 1) "" else "s" });
            return;
        }
        try self.deleteRowsNow();
    }

    pub fn deleteRowsNow(self: *App) !void {
        const table = self.currentTable() orelse return;
        // Again here, because this is also where the answer to "delete it?" ends
        // up, and nothing may reach the engine by having been asked about nicely.
        if (self.caps().no_delete.len != 0) {
            self.complain("{s}", .{self.caps().no_delete});
            return;
        }
        var targets: std.ArrayList(usize) = .empty;
        defer targets.deinit(self.allocator);
        if (self.cursor.marked.items.len != 0) {
            try targets.appendSlice(self.allocator, self.cursor.marked.items);
        } else if (self.cursor.row < self.grid.rows.items.len) {
            try targets.append(self.allocator, self.cursor.row);
        } else {
            return;
        }
        var deleted: usize = 0;
        for (targets.items) |index| {
            if (index >= self.grid.rows.items.len) {
                continue;
            }
            const key = self.grid.rows.items[index].key orelse continue;
            try self.change(.{ .kind = .delete, .table = table, .where = key }) orelse return;
            deleted += 1;
        }
        self.cursor.marked.clearRetainingCapacity();
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
        self.grid.cols.clearRetainingCapacity();
        self.grid.widths.clearRetainingCapacity();
        self.grid.rows.clearRetainingCapacity();
        self.grid.editable = false;
        // Whatever is on the grid from here on is something that was answered.
        self.grid.failed = false;

        var raw: std.ArrayList([]Cell) = .empty;
        var origins: std.ArrayList([]const u8) = .empty;
        var from: ?database.Table = source;
        var count: usize = 0;
        {
            var cursor = cursor_in.*;
            defer cursor.close();
            count = cursor.columnCount();
            const skip: usize = if (hidden_key and count > 0) 1 else 0;
            for (skip..count) |i| {
                const name = try arena.dupe(u8, cursor.name(i));
                try self.grid.cols.append(self.allocator, name);
                try self.grid.widths.append(self.allocator, term.width(name));
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
                    from = .{ .schema = self.grid.schema.items, .name = name };
                }
            }
            var loaded: usize = 0;
            while (try cursor.next()) {
                if (loaded >= self.grid.limit) {
                    break;
                }
                loaded += 1;
                const cells = try arena.alloc(Cell, count);
                for (0..count) |i| {
                    cells[i] = try formatCell(arena, cursor.value(i), cursor.isNumeric(i));
                }
                for (cells[skip..], 0..) |cell, i| {
                    self.grid.widths.items[i] = @max(self.grid.widths.items[i], term.width(cell.text));
                }
                try raw.append(arena, cells);
            }
        }

        // The cursor is closed, so the engine can be asked things again.
        const skip: usize = if (hidden_key and count > 0) 1 else 0;
        var keys: std.ArrayList(Position) = .empty;
        if (hidden_key) {
            try keys.append(arena, .{ .name = "__key", .at = 0 });
            self.grid.editable = true;
        } else if (from) |table| {
            const key = self.conn.rowKey(arena, table) catch database.RowKey{};
            var complete = key.usable() and !key.hidden;
            for (key.columns) |column| {
                var found: ?usize = null;
                for (origins.items, 0..) |origin, i| {
                    if (std.mem.eql(u8, origin, column) or std.mem.eql(u8, self.grid.cols.items[i], column)) {
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
            self.grid.editable = complete;
        }

        // The engine's own name for a hidden key, asked for once rather than per row.
        var hidden_name: []const u8 = "";
        if (hidden_key) {
            const found = self.conn.rowKey(arena, from orelse .{ .name = "" }) catch database.RowKey{};
            hidden_name = found.expression;
        }
        for (raw.items) |cells| {
            const identity: ?[]const database.ask.Filter = if (self.grid.editable)
                try identityOf(arena, keys.items, cells, hidden_name)
            else
                null;
            try self.grid.rows.append(self.allocator, .{ .cells = cells[skip..], .key = identity });
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
        if (self.cursor.row >= self.grid.rows.items.len) {
            self.cursor.row = if (self.grid.rows.items.len == 0) 0 else self.grid.rows.items.len - 1;
        }
        if (self.cursor.col >= self.grid.cols.items.len) {
            self.cursor.col = if (self.grid.cols.items.len == 0) 0 else self.grid.cols.items.len - 1;
        }
    }

    /// Which row of the table the grid starts at, counting from 1. Normally the
    /// top of the page; the tail of it while following.
    pub fn firstRow(self: *App) usize {
        return (self.follow.tail_from orelse self.grid.page * self.grid.limit) + 1;
    }

    pub fn pages(self: *App) usize {
        // Without a count there is no last page: there is this one, and another one
        // if this one filled up.
        if (!self.grid.counted) {
            return self.grid.page + 1 + @intFromBool(self.grid.rows.items.len >= self.grid.limit);
        }
        return @max(1, divCeil(@intCast(@max(0, self.grid.total)), self.grid.limit));
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
        // A statement that wants the terminal is not a statement the grid can
        // hold, and it is never one of a batch: it owns the screen until it ends.
        if (self.conn.wantsTerminal(std.mem.trim(u8, sql, " \t\r\n;"))) {
            return self.runShell(std.mem.trim(u8, sql, " \t\r\n;"));
        }
        // The forms and the keys already refuse through the capabilities, but this
        // is where somebody types their own, and nothing above has read it. The
        // test is the conservative one: a first word not on the reading list is
        // taken to write, so a statement this cannot recognise is refused rather
        // than run.
        if (self.read_only) {
            if (self.refuseWrites(sql)) {
                return;
            }
        }
        _ = self.report.arena.reset(.retain_capacity);
        const arena = self.report.arena.allocator();
        self.report.list.clearRetainingCapacity();

        var shown = false;
        var last_shown: []const u8 = "";
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
                        produced = @intCast(self.grid.rows.items.len);
                        shown = failure == null;
                        if (shown) {
                            last_shown = statement.sql;
                        }
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
            try self.report.list.append(self.allocator, .{
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
            if (self.running.cancelled) {
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
        if (self.running.cancelled) {
            self.running.cancelled = false;
            try self.loadObjects();
            self.complain("stopped{s}", .{if (rolled_back) ", rolled back" else ""});
            return;
        }

        if (shown) {
            // The rows are already on the grid; what is left is to look at them.
            try self.setTable(null);
            self.grid.page = 0;
            self.cursor.row = 0;
            self.cursor.col = 0;
            self.cursor.row_scroll = 0;
            self.cursor.col_scroll = 0;
            self.clampCursor();
            self.grid.total = @intCast(self.grid.rows.items.len);
            // The last statement of the batch is the one that filled the grid.
            self.follow.statement.clearRetainingCapacity();
            self.follow.statement.appendSlice(self.allocator, last_shown) catch {};
            self.setTitle("query result", .{});
            self.view = .grid;
            self.focus = .main;
        }
        try self.loadObjects();

        var affected: i64 = 0;
        for (self.report.list.items) |report| {
            affected += report.changes;
        }
        if (failures > 0) {
            self.complain("{d} of {d} statement(s) failed, press gm for details{s}", .{
                failures, self.report.list.items.len, if (rolled_back) ", rolled back" else "",
            });
        } else {
            self.say("{d} statement(s), {d} row(s) affected{s}", .{
                self.report.list.items.len, affected, if (rolled_back) ", rolled back" else "",
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
        self.typing.pending.clearRetainingCapacity();
        try self.typing.pending.appendSlice(self.allocator, statement);
        self.typing.prompt = .{ .kind = .confirm, .label = " type y to " };
        try self.typing.prompt.?.buffer.appendSlice(self.allocator, "");
        self.say("{s}: {s}", .{ verb, statement });
    }

    // ------------------------------------------- the : line, and one cell

    pub fn clearPending(self: *App) void {
        self.typing.pending.clearRetainingCapacity();
    }

    pub fn runPending(self: *App) !void {
        if (self.typing.pending.items.len == 0) {
            return;
        }
        // Whatever was being looked at may not survive this, and the answer goes
        // on the grid either way.
        if (self.view == .object) {
            self.closeObject();
        }
        const statement = try self.allocator.dupe(u8, self.typing.pending.items);
        defer self.allocator.free(statement);
        self.typing.pending.clearRetainingCapacity();
        try self.runBatch(statement);
        try self.loadObjects();
        if (self.grid.name) |name| {
            // The table may be gone now.
            var still_there = false;
            for (self.sidebar.objects.items) |object| {
                still_there = still_there or std.mem.eql(u8, object.name, name);
            }
            if (still_there) {
                try self.reload();
            } else {
                try self.setTable(null);
                self.grid.cols.clearRetainingCapacity();
                self.grid.rows.clearRetainingCapacity();
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

        // The ones about the program itself, which need nothing to be open: the
        // prompt is on the list of connections and in an empty tab too.
        if (is(verb, &.{ "q", "quit", "q!", "quit!" })) {
            self.leave();
            return;
        } else if (is(verb, &.{ "tabnew", "tabe", "tabedit" })) {
            try self.newTab(if (argument.len != 0) argument else null);
            return;
        } else if (is(verb, &.{ "tabn", "tabnext" })) {
            self.nextTab();
            return;
        } else if (is(verb, &.{ "tabp", "tabprev", "tabprevious" })) {
            self.prevTab();
            return;
        } else if (is(verb, &.{ "tabc", "tabclose", "close" })) {
            self.closeTab(self.active_tab);
            return;
        } else if (is(verb, &.{ "tabo", "tabonly" })) {
            self.closeOtherTabs();
            self.say("the other tabs are closed", .{});
            return;
        } else if (is(verb, &.{"open"})) {
            try self.reopen(argument);
            return;
        }
        // Everything else is about what is open, and asks the driver. With
        // nothing open there is no driver - the field holds whatever was last in
        // it - so this is where that stops, once, instead of in each of them.
        if (!self.connected) {
            self.complain("nothing is open - enter connects, :open <target> opens something by name", .{});
            return;
        }

        // A number is a row of this page, and `$` is the last of them.
        if (std.fmt.parseInt(usize, verb, 10)) |number| {
            self.goToRow(number -| 1);
            return;
        } else |_| {}
        if (is(verb, &.{"$"})) {
            self.goToRow(self.grid.rows.items.len -| 1);
            return;
        }

        if (is(verb, &.{ "w", "write" })) {
            // In the editor, writing is running: that is what a statement is for.
            if (self.typing.editor != null) {
                try self.runEditor();
            } else if (argument.len != 0) {
                try dump_mod.dump(self, argument);
            } else {
                self.say("usage: :w <file.csv|file.sql>", .{});
            }
        } else if (is(verb, &.{ "wq", "x" })) {
            // The same, and then what `:q` would do - which in the editor is
            // nothing more, because running a statement already puts the editor
            // away. Quitting the program there took the result with it.
            if (self.typing.editor != null) {
                try self.runEditor();
            } else {
                if (argument.len != 0) {
                    try dump_mod.dump(self, argument);
                }
                self.leave();
            }
        } else if (is(verb, &.{ "e", "edit" })) {
            if (argument.len == 0) {
                try self.openEditor();
                return;
            }
            for (self.sidebar.objects.items) |object| {
                if (std.ascii.eqlIgnoreCase(object.name, argument)) {
                    try self.openTable(object.name);
                    return;
                }
            }
            self.complain("there is no table called {s} - :e on its own opens the editor", .{argument});
        } else if (is(verb, &.{ "noh", "nohlsearch" })) {
            // What `/` narrowed, and only that. The filter on the rows is a
            // different thing, made in a form and shown above the grid, and it is
            // taken off where it was put on.
            self.sidebar.filter.clearRetainingCapacity();
            self.sidebar.selected = 0;
            self.sidebar.scroll = 0;
            self.say("the list is whole again", .{});
        } else if (is(verb, &.{"set"})) {
            if (is(argument, &.{ "ro", "readonly" })) {
                self.read_only = true;
                self.say("nothing is written through this connection until it is opened again", .{});
            } else if (is(argument, &.{ "noro", "noreadonly" })) {
                // One way only. The mark is what stands between a slip of the
                // hand and a production database, and it is lifted where it was
                // put - in the list, for the next time the connection is opened.
                self.complain("read-only is lifted in the connection list: r there, and open it again", .{});
            } else if (std.mem.startsWith(u8, argument, "limit=")) {
                try self.setLimit(argument["limit=".len..]);
            } else {
                self.say("options: :set ro, :set limit=50", .{});
            }
        } else if (std.mem.eql(u8, verb, "limit")) {
            try self.setLimit(argument);
        } else if (std.mem.eql(u8, verb, "follow")) {
            try self.followCommand(argument);
        } else if (std.mem.eql(u8, verb, "export")) {
            try self.exportRows(argument);
        } else if (std.mem.eql(u8, verb, "dump")) {
            try dump_mod.dump(self, argument);
        } else if (std.mem.eql(u8, verb, "text")) {
            const value = std.fmt.parseInt(usize, argument, 10) catch {
                self.complain(":text needs a number", .{});
                return;
            };
            self.grid.text_limit = @max(4, @min(200, value));
            self.say("columns clipped at {d} characters", .{self.grid.text_limit});
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
        } else if (std.mem.eql(u8, verb, "vacuum")) {
            self.conn.exec("VACUUM") catch {
                self.complain("{s}", .{self.conn.message()});
                return;
            };
            self.say("database vacuumed", .{});
        } else {
            self.complain("unknown :{s} - try :export, :dump, :limit, :text, :follow, :open, :check, :w, :e, :set, :tabnew, :q", .{verb});
        }
    }

    /// Whether `word` is one of `names`.
    fn is(word: []const u8, names: []const []const u8) bool {
        for (names) |name| {
            if (std.mem.eql(u8, word, name)) {
                return true;
            }
        }
        return false;
    }

    /// `:q`, from the inside out: the editor if it is open, then this tab if
    /// there are others, then whatever screen is over the grid, and the program
    /// only when there is nothing left to leave.
    fn leave(self: *App) void {
        if (self.typing.editor != null) {
            self.closeEditor();
        } else if (self.tabs.items.len > 1) {
            self.closeTab(self.active_tab);
        } else if (self.connected and self.view != .grid) {
            self.view = .grid;
        } else {
            self.quit = true;
        }
    }

    fn goToRow(self: *App, row: usize) void {
        if (self.grid.rows.items.len == 0) {
            return;
        }
        self.cursor.row = @min(row, self.grid.rows.items.len - 1);
        self.focus = .main;
        self.say("row {d} of {d}", .{ self.cursor.row + 1, self.grid.rows.items.len });
    }

    fn setLimit(self: *App, text: []const u8) !void {
        const value = std.fmt.parseInt(usize, text, 10) catch {
            self.complain(":limit needs a number", .{});
            return;
        };
        self.grid.limit = @max(1, @min(100000, value));
        self.reload() catch {};
        self.say("{d} rows per page", .{self.grid.limit});
    }

    /// `:follow 0.5`, `:follow 5`, `:follow off`. The number is seconds, because
    /// that is how anybody watching a topic thinks about it, and it is kept when
    /// the following is switched off so the key turns it back on the same way.
    fn followCommand(self: *App, argument: []const u8) !void {
        if (argument.len == 0 or std.mem.eql(u8, argument, "off")) {
            self.setFollow(0);
            self.say("no longer following", .{});
            return;
        }
        const seconds = std.fmt.parseFloat(f64, argument) catch {
            self.complain(":follow takes seconds - :follow 2, :follow 0.5, :follow off", .{});
            return;
        };
        if (!(seconds > 0)) {
            self.setFollow(0);
            self.say("no longer following", .{});
            return;
        }
        self.follow.every = @intFromFloat(@max(200, @min(3_600_000, seconds * 1000)));
        try self.startFollowing();
    }

    /// Turn the following on at the interval last asked for, and jump to the end
    /// of the table straight away rather than after the first tick.
    pub fn startFollowing(self: *App) !void {
        if (!self.hasRows()) {
            self.complain("open a table, or run something worth watching, to follow it", .{});
            return;
        }
        self.setFollow(self.follow.every);
        if (self.follow.ms == 0) {
            return;
        }
        try self.reload();
        self.say("following {s}, every {d:.1}s", .{
            if (self.hasTable()) self.grid.title.items else "it",
            @as(f64, @floatFromInt(self.follow.every)) / 1000.0,
        });
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
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);
        for (self.grid.cols.items, 0..) |name, i| {
            if (self.isHidden(i)) {
                continue;
            }
            if (out.items.len != 0) {
                try out.append(self.allocator, separator);
            }
            try csv.writeField(&out, self.allocator, name, separator);
        }
        try out.appendSlice(self.allocator, "\r\n");
        for (self.grid.rows.items) |row| {
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
                    // The value, not the grid's one-line copy of it: a CSV field
                    // carries a newline perfectly well inside quotes, and an export
                    // that quietly flattens is an export that loses.
                    try csv.writeField(&out, self.allocator, cell.whole(), separator);
                }
            }
            try out.appendSlice(self.allocator, "\r\n");
        }
        writeFile(path, out.items) catch |err| {
            self.complain("cannot write {s}: {s}", .{ path, @errorName(err) });
            return;
        };
        self.say("{d} row(s) written to {s}", .{ self.grid.rows.items.len, path });
    }

    /// A whole table, not just the page on screen.
    pub fn writeQuery(self: *App, path: []const u8, name: []const u8, separator: u8) !void {
        const table = database.Table{ .schema = self.grid.schema.items, .name = name };
        var out: std.ArrayList(u8) = .empty;
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
                    try csv.writeField(&out, self.allocator, cell.whole(), separator);
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

    /// The full, unflattened value under the cursor, for the detail view.
    pub fn cellDetail(self: *App, arena: std.mem.Allocator) !?[]const u8 {
        if (self.cursor.row >= self.grid.rows.items.len or self.cursor.col >= self.grid.cols.items.len) {
            return null;
        }
        const row = self.grid.rows.items[self.cursor.row];
        const table = self.currentTable() orelse return try arena.dupe(u8, row.cells[self.cursor.col].whole());
        const key = row.key orelse return try arena.dupe(u8, row.cells[self.cursor.col].whole());
        const column = self.grid.cols.items[self.cursor.col];
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
            .int => |value| try arena.print("{d}", .{value}),
            .float => |value| try arena.print("{d}", .{value}),
            .text, .blob => |bytes| try arena.dupe(u8, bytes),
        };
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
        const key = self.grid.rows.items[self.cursor.row].key orelse return;
        const column = self.grid.cols.items[self.cursor.col];
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
        var conditions: std.ArrayList(database.ask.Filter) = .empty;
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
    pub fn copyFilters(a: std.mem.Allocator, filters: []const database.ask.Filter) ![]const database.ask.Filter {
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
    pub fn change(self: *App, request: database.ask.Change) !?void {
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
        if (self.caps().no_delete.len != 0) {
            self.complain("{s}", .{self.caps().no_delete});
            return;
        }
        const key = self.grid.rows.items[self.cursor.row].key orelse return;
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
        var report: std.ArrayList(u8) = .empty;
        defer report.deinit(self.allocator);
        var naming = std.heap.ArenaAllocator.init(self.allocator);
        defer naming.deinit();
        const what = conns.withoutPassword(naming.allocator(), target) catch "";
        var attendant = self.attend(target, what);
        defer self.connecting = null;
        defer attendant.stop();
        const opened = self.dial(target, &report) catch |err| {
            attendant.stop();
            if (err == error.GivenUp) {
                self.say("gave up on {s}", .{what});
                return;
            }
            self.complain("{s}", .{if (report.items.len != 0) report.items else "cannot open it"});
            return;
        };
        // What was open, if anything was, is closed on the way: this is also how
        // something is opened by name from the list of connections, where
        // nothing is.
        const taken = self.take(opened, target);
        attendant.stop();
        if (self.gaveUp()) {
            return;
        }
        try taken;
        self.say("{s} opened", .{self.conn.describe()});
    }

    /// Start in the schema the engine puts first, if it has schemas at all.
    pub fn firstSchema(self: *App) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const list = self.conn.schemas(arena.allocator()) catch return;
        if (list.len != 0) {
            self.grid.schema.clearRetainingCapacity();
            try self.grid.schema.appendSlice(self.allocator, list[0]);
        }
    }

    /// Switch to another schema.
    pub fn useSchema(self: *App, name: []const u8) !void {
        self.grid.schema.clearRetainingCapacity();
        try self.grid.schema.appendSlice(self.allocator, name);
        try self.setTable(null);
        self.sidebar.selected = 0;
        self.clearConditions();
        self.grid.where_text.clearRetainingCapacity();
        try self.loadObjects();
        if (self.current()) |object| {
            try self.openTable(object.name);
        }
        self.say("schema {s}", .{name});
    }

    // -------------------------------------------------------------- import

    pub fn importCsv(
        self: *App,
        a: std.mem.Allocator,
        wanted: []const u8,
        body: []const u8,
        separator: u8,
        header: bool,
    ) !void {
        // The name lives in the form's memory, which is freed before the report.
        const table = database.Table{
            .schema = self.grid.schema.items,
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
        const scripted = self.caps().speaks_sql;
        var names: std.ArrayList([]const u8) = .empty;
        var script: std.ArrayList(u8) = .empty;
        if (scripted) {
            try script.appendSlice(a, "BEGIN;\n");
        }
        var failed: usize = 0;

        var lines = std.mem.splitAny(u8, body, "\n");
        var pending: std.ArrayList(u8) = .empty;
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
                var values: std.ArrayList([]const u8) = .empty;
                for (fields, 0..) |field, i| {
                    if (i >= names.items.len) {
                        break;
                    }
                    var literal: std.ArrayList(u8) = .empty;
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
            var cells: std.ArrayList(database.ask.Cell) = .empty;
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
                    rows,                           table.name, failed,
                    if (why.len != 0) ": " else "", why,
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
/// Whether `text` ends in `word`, in either case and as a word of its own -
/// `adjoin` does not end in JOIN.
fn endsWithWord(text: []const u8, word: []const u8) bool {
    if (!std.ascii.endsWithIgnoreCase(text, word)) {
        return false;
    }
    if (text.len == word.len) {
        return true;
    }
    const before = text[text.len - word.len - 1];
    return !(std.ascii.isAlphanumeric(before) or before == '_');
}

fn textOf(arena: std.mem.Allocator, value: database.Value) ![]const u8 {
    return switch (value) {
        .null => "",
        .text, .blob => |bytes| try arena.dupe(u8, bytes),
        .int => |v| try arena.print("{d}", .{v}),
        .float => |v| try arena.print("{d}", .{v}),
    };
}

/// `numeric` comes from the column's type, so a value the engine hands over as
/// text - PostgreSQL's numeric, which must not lose precision - still lines up
/// on the right.
pub fn formatCell(arena: std.mem.Allocator, value: database.Value, numeric: bool) !Cell {
    return switch (value) {
        .null => .{ .text = "NULL", .kind = .nul },
        .int => |v| .{ .text = try arena.print("{d}", .{v}), .kind = .int },
        .float => |v| .{ .text = try arena.print("{d}", .{v}), .kind = .float },
        .blob => |b| .{ .text = try arena.print("<{d} B>", .{b.len}), .kind = .blob },
        .text => |t| .{
            .text = try flatten(arena, t),
            .original = if (std.mem.findAny(u8, t, "\n\r\t") != null) try arena.dupe(u8, t) else "",
            .kind = if (numeric) .float else .text,
        },
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

pub fn writeDelimited(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8, separator: u8) !void {
    if (std.mem.findAny(u8, text, &[_]u8{ '"', '\n', '\r', separator }) == null) {
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
pub fn writeFile(path: []const u8, bytes: []const u8) !void {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
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

/// Milliseconds on the clock that only goes forwards. Kept as a name of its own
/// because this file reads it in six places, and the short name is what makes
/// those lines say what they are about.
pub fn monotonicMs() f64 {
    return database.clock.steadyMs();
}

/// Whether a declared type has numeric affinity.
pub fn isNumeric(declared: []const u8) bool {
    for ([_][]const u8{ "INT", "REAL", "FLOA", "DOUB", "NUM", "DEC" }) |needle| {
        if (std.ascii.findIgnoreCase(declared, needle) != null) {
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
/// Whether a driver that could not say what it wanted was, by the sound of it,
/// after a password.
///
/// A guess, and a poor one - it cannot tell a server asking for a password from
/// one refusing the password it got, because both sentences have the word in
/// them. Whoever is being asked to type one cares about that difference more than
/// anything else on the screen, which is why `error.NeedPassword` exists and why
/// this is the fallback for the drivers that do not return it yet.
fn needsPassword(message: []const u8) bool {
    for ([_][]const u8{ "password", "authentication", "secret key" }) |needle| {
        if (std.ascii.findIgnoreCase(message, needle) != null) {
            return true;
        }
    }
    return false;
}

/// Whether a saved connection is one this filter leaves showing.
///
/// Fuzzy on the name, the way the sidebar and the command palette are - but
/// plainly on the target, and that difference is the whole of it. Every target
/// begins `postgres://` or `mssql://` and runs to forty characters, so a fuzzy
/// match against one says yes to nearly everything: `prod` found a connection
/// called `localni` through `postgres://u@localni.example:5432/d`, and the
/// filter narrowed six connections to five. A host or a port is worth searching
/// for, so the target is searched - as the substring somebody actually typed.
pub fn connectionMatches(name: []const u8, target: []const u8, needle: []const u8) bool {
    if (needle.len == 0) {
        return true;
    }
    return fuzzy.match(name, needle, null) != null or
        std.ascii.findIgnoreCase(target, needle) != null;
}

pub fn divCeil(a: usize, b: usize) usize {
    return if (b == 0) 1 else (a + b - 1) / b;
}

// ------------------------------------------------------------------- tests
//
// What can be asked without a terminal, a connection or a screen: the small
// decisions the grid is built out of. This file had none, which is a strange
// thing for the largest one here.

const testing = std.testing;

test "the filter form's operators mean what they say, and an unknown one is equality" {
    try testing.expectEqual(database.ask.Op.eq, operatorOf("="));
    try testing.expectEqual(database.ask.Op.ne, operatorOf("!="));
    try testing.expectEqual(database.ask.Op.le, operatorOf("<="));
    try testing.expectEqual(database.ask.Op.not_null, operatorOf("IS NOT NULL"));
    // `contains` is LIKE with the wildcards put on for the user.
    try testing.expectEqual(database.ask.Op.like, operatorOf("contains"));
    try testing.expectEqual(database.ask.Op.like, operatorOf("LIKE"));
    // Anything else is equality rather than an error: the form only offers the
    // list above, so this is what a value out of step with it falls back to.
    try testing.expectEqual(database.ask.Op.eq, operatorOf("what"));
    try testing.expectEqual(database.ask.Op.eq, operatorOf(""));
}

test "a declared type has numeric affinity by the same rule SQLite uses" {
    try testing.expect(isNumeric("INTEGER"));
    try testing.expect(isNumeric("bigint"));
    try testing.expect(isNumeric("NUMERIC(10,2)"));
    try testing.expect(isNumeric("double precision"));
    try testing.expect(!isNumeric("TEXT"));
    try testing.expect(!isNumeric("timestamptz"));
    try testing.expect(!isNumeric(""));
    // And by that rule a column called `point` is a number, because "INT" is in
    // it. SQLite says the same about the same word; a grid that right-aligns one
    // geometry column is a smaller wrong than a rule of our own invention.
    try testing.expect(isNumeric("point"));
}

test "a value looks like a number, or is text that happens to have digits in it" {
    try testing.expect(looksNumeric("42"));
    try testing.expect(looksNumeric("-1"));
    try testing.expect(looksNumeric("3.14"));
    try testing.expect(looksNumeric("1e-9"));
    try testing.expect(!looksNumeric(""));
    try testing.expect(!looksNumeric("."));
    try testing.expect(!looksNumeric("-"));
    // A sign that is not at the front and not after an exponent is not a number,
    // which is what keeps a date out of the right-hand column.
    try testing.expect(!looksNumeric("2026-08-23"));
    try testing.expect(!looksNumeric("12a"));
    try testing.expect(!looksNumeric("ahoj"));
}

test "a cell is one line, whatever was in it" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    // A newline inside a value would tear the grid apart, so every kind of one
    // becomes a space and the value keeps its length.
    try testing.expectEqualStrings("a b c d", try flatten(arena, "a\nb\rc\td"));
    try testing.expectEqualStrings("nic", try flatten(arena, "nic"));
    try testing.expectEqualStrings("", try flatten(arena, ""));
}

test "the grid gets one line and everything else gets the value" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    // A Redis INFO is one cell of eighty lines. Flattened it is what the grid
    // needs and what the whole-value view and a CSV export must not be given -
    // the view showed one unbroken paragraph, and the export lost the newlines
    // for good, in a format whose quotes exist to carry them.
    const many = try formatCell(arena, .{ .text = "prvni\ndruhy" }, false);
    try testing.expectEqualStrings("prvni druhy", many.text);
    try testing.expectEqualStrings("prvni\ndruhy", many.whole());

    // And nothing is kept twice for a value that was one line to begin with.
    const one = try formatCell(arena, .{ .text = "ahoj" }, false);
    try testing.expectEqualStrings("ahoj", one.text);
    try testing.expectEqualStrings("ahoj", one.whole());
    try testing.expectEqual(@as(usize, 0), one.original.len);

    // A number has no second form to keep.
    const number = try formatCell(arena, .{ .int = 42 }, true);
    try testing.expectEqualStrings("42", number.whole());
}

test "counting pages never divides by nothing" {
    try testing.expectEqual(@as(usize, 3), divCeil(21, 10));
    try testing.expectEqual(@as(usize, 2), divCeil(20, 10));
    try testing.expectEqual(@as(usize, 0), divCeil(0, 10));
    // A limit of nothing is one page, not a crash: `1/0` on the screen is worse
    // than a wrong number and a divide by zero is worse than both.
    try testing.expectEqual(@as(usize, 1), divCeil(50, 0));
}

test "a driver that cannot say what it wants is guessed at, and the guess is not clever" {
    try testing.expect(needsPassword("fe_sendauth: no password supplied"));
    try testing.expect(needsPassword("foo needs a password, or a key the agent does not have"));
    try testing.expect(needsPassword("Authentication failed"));
    try testing.expect(!needsPassword("there is no table called books"));
    try testing.expect(!needsPassword(""));
    // And here is what it cannot do, written down rather than found out again: a
    // refused password says the same word as a missing one. `error.NeedPassword`
    // is why this is only a fallback.
    try testing.expect(needsPassword("the password for foo was not accepted"));
}

test "the connection filter is fuzzy about the name and literal about the target" {
    const target = "postgres://u@localni.example:5432/d";
    // Nothing typed shows everything.
    try testing.expect(connectionMatches("localni", target, ""));
    // Fuzzy on the name: `pdb` finds `produkce-db`, which is the point of it.
    try testing.expect(connectionMatches("produkce-db", "postgres://u@p.example/d", "pdb"));
    // And not fuzzy on the target, which is what this rule is for: every letter
    // of `prod` is somewhere in that URL, in that order, so a fuzzy match there
    // says yes to a connection that has nothing to do with production.
    try testing.expect(!connectionMatches("localni", target, "prod"));
    // A host or a port is searched for as itself.
    try testing.expect(connectionMatches("cokoliv", target, "5432"));
    try testing.expect(connectionMatches("cokoliv", target, "localni.example"));
    // Case is not the point of a search either.
    try testing.expect(connectionMatches("cokoliv", target, "LOCALNI"));
}

// ------------------------------------------------------------ on the bench
//
// The program with no terminal under it - see bench.zig: a key at a time, the
// screen read back, and the database asked what became of it. The forms have
// theirs in forms.zig, the keys in input.zig and the frame in draw.zig; what
// is here is what belongs to none of those.

const Bench = @import("bench.zig").Bench;
const BOOKS = @import("bench.zig").BOOKS;

test "a connection marked read-only writes nothing, by key or by statement" {
    var bench = try Bench.openWith(BOOKS, .{ .connections = "library\t{dir}/bench.db\tread-only\n" });
    defer bench.close();
    try testing.expect(bench.app.read_only);
    try bench.keys("j{enter}x");
    try testing.expect(bench.app.report.status_error);
    try bench.says("read-only");
    try bench.keys("e");
    try testing.expect(bench.app.typing.prompt == null);
    try bench.keys("i");
    try testing.expect(bench.app.typing.form == null);

    // What is typed is read before it is run: a write is refused, a read runs.
    try bench.keys("s");
    try bench.typed("delete from books");
    try bench.keys("{ctrl-s}");
    try bench.says("read-only");
    try bench.keys("{esc}{esc}s{ctrl-u}");
    try bench.typed("select count(*) from books");
    try bench.keys("{ctrl-s}");
    try testing.expectEqualStrings("4", bench.app.grid.rows.items[0].cells[0].text);
}

test "the whole value opens over the grid, and anything else closes it" {
    var bench = try Bench.open("CREATE TABLE notes (body TEXT); INSERT INTO notes VALUES ('first line' || char(10) || 'second line');");
    defer bench.close();
    try bench.keys("{enter}");
    // One line in the grid, whatever was in it.
    try bench.sees("first line second line");
    try bench.keys("gv");
    try testing.expect(bench.app.detail);
    // And the value as it is in the box.
    try bench.sees("│ first line");
    try bench.sees("│ second line");
    try bench.keys("{esc}");
    try testing.expect(!bench.app.detail);
}

test "following reads the table again on the clock, and stays on its end" {
    var bench = try Bench.open(BOOKS);
    defer bench.close();
    try bench.keys("j{enter}R");
    try testing.expect(bench.app.follow.ms != 0);
    try bench.app.conn.exec("INSERT INTO books (title, year) VALUES ('Hordubal', 1933)");
    try bench.lacks("Hordubal");
    try bench.keys("{tick}");
    try bench.sees("Hordubal");
    // Off again with the same key, and a tick that is still on its way does
    // nothing.
    try bench.keys("R");
    try testing.expectEqual(@as(u64, 0), bench.app.follow.ms);
    try bench.app.conn.exec("DELETE FROM books WHERE title = 'Hordubal'");
    try bench.keys("{tick}");
    try bench.sees("Hordubal");
}

test "a connection is chosen from the list, and the one opened moves to the front" {
    var bench = try Bench.openWith(BOOKS, .{
        .on_list = true,
        .connections = "nowhere\t{dir}/nothing/there.db\nlibrary\t{dir}/bench.db\n",
    });
    defer bench.close();
    try testing.expectEqual(View.connections, bench.app.view);
    try bench.sees("nowhere");
    try bench.sees("library");
    try bench.says("2 saved connection(s)");

    try bench.keys("j{enter}");
    try testing.expect(bench.app.connected);
    try bench.sees("authors  1-3 of 3");
    try testing.expectEqualStrings("library", bench.app.saved.list.items.items[0].name);

    // One that cannot be opened says why, and the list is still there.
    try bench.keys("Oj{enter}");
    try testing.expect(bench.app.report.status_error);
    try bench.says("cannot open");
    try testing.expectEqual(View.connections, bench.app.view);
}

test "a list that cannot be written says so when something asked of it is lost" {
    if (std.c.geteuid() == 0) {
        return error.SkipZigTest; // nothing refuses root a file
    }
    var bench = try Bench.openWith(BOOKS, .{
        .on_list = true,
        .connections = "library\t{dir}/bench.db\nother\t{dir}/other.db\n",
    });
    defer bench.close();
    const list = try testing.allocator.dupeSentinel(u8, bench.app.saved.path.items, 0);
    defer testing.allocator.free(list);
    try testing.expectEqual(@as(c_int, 0), std.c.chmod(list, 0o444));
    defer _ = std.c.chmod(list, 0o644);

    // Opening one only moves it to the front: nobody asked for that, and a
    // list kept read-only on purpose is not complained about for it.
    try bench.keys("{enter}");
    try testing.expect(bench.app.connected);
    try testing.expect(!bench.app.saved.unwritten);
    try testing.expect(!bench.app.report.status_error);

    // Removing one is somebody's own change, and it did not reach the file.
    try bench.keys("Ojd");
    try testing.expect(bench.app.saved.unwritten);
    try bench.says("could not be written");
    try bench.sees("not written to");

    // It goes on being said, after the line has been written over by a
    // connection that opened...
    try bench.keys("{enter}");
    try bench.says("could not be written");
    // ...and stops when a write has gone through, which writes all of it.
    try testing.expectEqual(@as(c_int, 0), std.c.chmod(list, 0o644));
    try bench.keys("Or");
    try testing.expect(!bench.app.saved.unwritten);
    try bench.keys("O");
    try bench.sees("saved in");
    try bench.lacks("not written to");
}

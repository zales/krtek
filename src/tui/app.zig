//! State and behaviour of the terminal app: the schema, the loaded page of
//! rows, and everything that runs SQL. Drawing and input live next door and
//! only read from here, which keeps the imports a straight line.

const std = @import("std");
const database = @import("db");
const term = @import("term.zig");
const Form = @import("form.zig");
const csv = @import("csv.zig");
const dump_mod = @import("dump.zig");
const Editor = @import("editor.zig").Editor;
const sql_syntax = @import("editor.zig");
const fuzzy = @import("fuzzy.zig");
const conns = @import("connections.zig");
const keychain = @import("keychain.zig");
const biometry = @import("biometry.zig");
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
/// A place on screen, in cells.
pub const Spot = struct { row: usize, col: usize };

/// Where a connection can keep its password, in the order the form offers them.
const PLACES = [_][]const u8{ "ask", "file", "keychain", "touchid" };
/// What the Kafka form offers. The empty one is no SASL at all, which is what a
/// broker on a private network wants.
const MECHANISMS = [_][]const u8{ "", "PLAIN", "SCRAM-SHA-256", "SCRAM-SHA-512" };

/// The command palette: what is typed, and which match is under the cursor.
/// Its entries live in `input.zig`, next to the keys they stand for.
pub const Palette = struct {
    query: std.ArrayListUnmanaged(u8) = .empty,
    at: usize = 0,
};

pub const PromptKind = enum { command, filter, edit, confirm, password, new_dir, rename_file, remove_files, overwrite, go_to, remove_rows };

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
    bits: [32]u32 = [_]u32{0} ** 32,
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
    statement: std.ArrayListUnmanaged(u8) = .empty,
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
/// are every statement of the last run, which `m` opens. They share an arena
/// because they are made and thrown away together, once per run.
const Reporting = struct {
    arena: std.heap.ArenaAllocator,
    list: std.ArrayListUnmanaged(Report) = .empty,
    /// The line itself, and whether it is a complaint - which is the difference
    /// between a colour somebody reads past and one they stop at.
    status: std.ArrayListUnmanaged(u8) = .empty,
    status_error: bool = false,
};

/// Saved connections, where they live, and which of them is being worked on.
const Saved = struct {
    list: conns.List,
    path: std.ArrayListUnmanaged(u8) = .empty,
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
    filter: std.ArrayListUnmanaged(u8) = .empty,
    /// How many entries were on screen last time it was drawn, so a page key can
    /// move by a page. The drawing is what knows this - it is the one that has the
    /// window and the hints to fit around.
    shown: usize = 0,
    /// The connection a password is being asked for.
    pending: std.ArrayListUnmanaged(u8) = .empty,
    /// Which saved connection the open form is editing, so changing both its name
    /// and its target replaces that entry instead of adding a second one.
    editing: ?usize = null,
    /// Whether the connection now open was marked as one nothing may be written
    /// through. Kept here rather than asked of the list every time, because the
    /// list can be edited while a connection is open and what is in force is what
    /// was in force when it was opened.
    read_only: bool = false,

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
    pending: std.ArrayListUnmanaged(u8) = .empty,
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
};

/// The list down the left: every table and view the connection has, what has
/// been typed to narrow it, which one the cursor is on and where it is scrolled
/// to.
const Sidebar = struct {
    objects: std.ArrayListUnmanaged(Object) = .empty,
    filter: std.ArrayListUnmanaged(u8) = .empty,
    selected: usize = 0,
    /// The first one visible, which is what scrolling a list means.
    scroll: usize = 0,
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
    marked: std.ArrayListUnmanaged(usize) = .empty,
    /// Column indexes put away, by index into the grid's own columns.
    hidden: std.ArrayListUnmanaged(usize) = .empty,
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
    /// What the filter form put together: conditions an engine of any kind can
    /// honour. The strings are owned.
    conditions: std.ArrayListUnmanaged(database.ask.Filter) = .empty,
    /// The raw box of the filter form, which only an engine with SQL can use.
    where_text: std.ArrayListUnmanaged(u8) = .empty,
    /// The last reload could not be answered, and has said why. Whoever asked for
    /// it must not then report a count as though it had worked.
    failed: bool = false,
    text_limit: usize = 44, // widest column in the grid
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
    history: std.ArrayListUnmanaged([]const u8) = .empty,
    report: Reporting,

    quit: bool = false,

    saved: Saved,
    palette: ?Palette = null,
    /// The two panes, while the file manager is on screen. Null the rest of the
    /// time: a connection that holds rows has no business keeping one open.
    files: ?*Files.Manager = null,
    running: Running = .{},
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
            .report = .{ .arena = std.heap.ArenaAllocator.init(allocator) },
            .object = .{ .arena = std.heap.ArenaAllocator.init(allocator) },
            .typing = .{ .arena = std.heap.ArenaAllocator.init(allocator) },
            .screen = try Term.init(allocator, io, env),
            .conn = undefined,
            .connected = false,
            .path = "",
            .owned_path = try allocator.alloc(u8, 0),
            .saved = .{ .list = conns.List.init(allocator) },
            .env = env,
        };
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        if (conns.path(&buffer, env)) |file| {
            try self.saved.path.appendSlice(allocator, file);
            conns.load(&self.saved.list, file) catch {};
        }
        self.offerFound();
        self.view = .connections;
        if (target.len != 0) {
            self.connect(target, true) catch {};
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
        var report: std.ArrayListUnmanaged(u8) = .empty;
        defer report.deinit(self.allocator);
        const opened = database.Db.open(self.allocator, target, &report) catch |err| {
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
        if (self.connected) {
            self.conn.close();
        }
        // Whatever was being followed belongs to the connection being replaced.
        self.setFollow(0);
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
        self.saved.read_only = false;
        if (self.saved.list.find(self.owned_path)) |at| {
            self.saved.read_only = self.saved.list.items.items[at].read_only;
        }
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
        if (self.typing.editor != null) {
            return;
        }
        self.typing.editor = Editor.init(self.allocator);
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

    pub fn closeEditor(self: *App) void {
        if (self.typing.editor) |*open| {
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
        // Something that makes or overwrites is asked about here, where a person
        // just typed it, rather than anywhere further in - and only here, so that
        // saying yes runs it rather than asking again.
        if (self.conn.confirming(sql)) |what| {
            self.closeEditor();
            try self.confirm(owned, what);
            return;
        }
        const talking = self.conn.sessionIn().len != 0;
        if (talking) {
            editor.clear();
        } else {
            self.closeEditor();
        }
        try self.remember(owned);
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
        try editor.setText(self.history.items[at]);
    }

    /// What tab offers: the names in this database, the columns of the table on
    /// screen, and SQL's own words.
    pub fn completeInEditor(self: *App) !void {
        const editor = &(self.typing.editor orelse return);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        for (self.sidebar.objects.items) |object| {
            try names.append(scratch, object.name);
        }
        for (self.grid.cols.items) |column| {
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
        const frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
        self.running.frame = (self.running.frame + 1) % frames.len;
        const size = self.screen.size();
        var line: [160]u8 = undefined;
        const text = std.fmt.bufPrint(&line, " {s} running {d:.1}s   ctrl+c stops it", .{
            frames[self.running.frame],
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
        } else {
            try self.saved.list.add(try conns.suggestName(scratch.allocator(), clean), clean, null, "");
        }
        conns.save(&self.saved.list, self.saved.path.items) catch {};
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
                var reason: [160]u8 = undefined;
                const words = std.fmt.bufPrint(&reason, "unlock the password for {s}", .{entry.name}) catch "unlock a saved password";
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
            conns.save(&self.saved.list, self.saved.path.items) catch {};
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
                conns.save(&self.saved.list, self.saved.path.items) catch {};
                self.say("connected, and the password is now in {s}", .{self.saved.path.items});
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
        const label = std.fmt.bufPrint(&name, "{s}", .{going.name}) catch "it";
        if (going.keeps.inKeychain()) {
            keychain.remove(going.target);
        }
        _ = self.saved.list.items.orderedRemove(chosen);
        // The cursor counts what is on screen, and one fewer is showing now.
        if (self.saved.at >= self.savedCount() and self.saved.at > 0) {
            self.saved.at -= 1;
        }
        conns.save(&self.saved.list, self.saved.path.items) catch {};
        self.say("{s} removed from the list", .{label});
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
        conns.save(&self.saved.list, self.saved.path.items) catch {
            self.complain("the connection list could not be written", .{});
            return;
        };
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

    pub fn openConnectionForm(self: *App, edit: bool) !void {
        // Editing one would have to write it somewhere, and the only place it
        // could go is this program's own file - which would leave two answers to
        // what that cluster is called. `a` is how to make one of your own.
        const chosen = self.chosenSaved();
        if (edit) {
            if (chosen) |at| {
                if (self.saved.list.items.items[at].found) {
                    self.complain("{s} comes from the kubeconfig - a adds one of your own, with its own name", .{
                        self.saved.list.items.items[at].name,
                    });
                    return;
                }
            }
        }
        self.saved.editing = null;
        _ = self.typing.arena.reset(.retain_capacity);
        var name: []const u8 = "";
        var target: []const u8 = "";
        var secret: []const u8 = "";
        var keeps: conns.Keeps = .ask;
        var read_only = false;
        if (edit) {
            const at = chosen orelse {
                self.complain("there is nothing to edit yet - press a to add one", .{});
                return;
            };
            const entry = self.saved.list.items.items[at];
            name = entry.name;
            target = entry.target;
            keeps = entry.keeps;
            secret = entry.secret;
            read_only = entry.read_only;
            self.saved.editing = at;
        }
        // A target that cannot be taken apart and put back together identically is
        // left as the one field it always was.
        const shape = conns.decompose(self.formArena(), target) orelse conns.Shape{
            .engine = if (target.len == 0) .sqlite else .other,
            .path = target,
        };
        try self.showConnectionForm(shape, name, keeps, secret, read_only);
    }

    /// Whether this pane may be written into. A read-only connection is about the
    /// place it opened, not about the machine krtek runs on: copying a file *down*
    /// from a read-only bucket is a read, and there is no reason to refuse it.
    pub fn mayWriteTo(self: *App, place: database.store.Store) bool {
        if (!self.saved.read_only or place == .local) {
            return true;
        }
        self.complain("this connection is read-only: {s} is not written to", .{place.label()});
        return false;
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
        var out = self.conn.caps();
        if (!self.saved.read_only) {
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

    /// An arena that outlives the form: the connection form is built again every
    /// time the engine changes, and what was typed has to survive that.
    fn formArena(self: *App) std.mem.Allocator {
        return self.typing.arena.allocator();
    }

    fn showConnectionForm(self: *App, shape: conns.Shape, name: []const u8, keeps: conns.Keeps, secret: []const u8, read_only: bool) !void {
        const form = try self.newForm(
            .connection,
            if (self.saved.editing != null) "edit connection" else "add connection",
            "pick the engine, fill in what it needs",
        );
        self.typing.built_for = shape.engine;
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
            .postgres, .mysql, .mssql => {
                try form.text("host", shape.host, 24);
                try form.text("port", shape.port, 6);
                form.sameLine();
                try form.text("database", shape.name, 24);
                try form.text("user", shape.user, 24);
                // PostgreSQL and MySQL fall back to the name you are logged in as.
                // SQL Server has no such idea - an empty user is a login it
                // refuses, with `Login failed for user ''`, which reads like a bug
                // rather than a field somebody left blank.
                try form.note(if (shape.engine == .mssql)
                    "leave the port empty for the usual one; the user is not optional here"
                else
                    "leave the port empty for the usual one, and the user for your own name");
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
            .k8s => {
                try form.text("context", shape.host, 32);
                try form.text("namespace", shape.name, 24);
                try form.text("kubeconfig", shape.key, 32);
                try form.toggle("check the certificate", !shape.insecure);
                try form.note("everything else is in the kubeconfig: empty means its current context,");
                try form.note("and an empty file means $KUBECONFIG and then ~/.kube/config. There is");
                try form.note("no password here - a cluster is reached the way kubectl reaches it.");
            },
        }

        // Above the password and before the engines that have none, because this is
        // the one thing on this form that is true of every engine - and truest of
        // the one that has no password at all, since a kubeconfig usually holds
        // every cluster somebody has, production among them.
        try form.toggle("read-only", read_only);
        try form.note("nothing is written through a read-only connection: no insert, no update,");
        try form.note("no delete and no schema statement. The account may still be allowed to;");
        try form.note("this is about what this program will do with it.");

        // A cluster has no password to keep anywhere: it is reached with what the
        // kubeconfig carries, and offering a place to put one would be offering to
        // keep something nothing will ever ask for.
        if (shape.engine == .k8s) {
            return;
        }
        // Only offer what this machine has: the keychain is macOS's.
        // Only what this machine has: the keychain is macOS's, and the reader is
        // not on every Mac.
        const places = if (!keychain.available)
            PLACES[0..2]
        else if (biometry.available) &PLACES else PLACES[0..3];
        try form.choice("keep the password", places, Form.indexOf(places, @tagName(keeps)));
        try form.secret("password", secret, 24);
        form.sameLine();
        try form.note("file: plain text in ~/.config/krtek/connections, which only you can read");
        if (keychain.available) {
            try form.note("keychain: in the macOS keychain, which asks you before handing it over");
            if (biometry.available) {
                try form.note("touchid: the same place, and a fingerprint each time instead of typing -");
                try form.note("  the keychain hands this one over without asking, so the finger is the guard");
            }
        }
        try form.note("ask: nothing is kept - as with ~/.pgpass, ~/.my.cnf or PGPASSWORD");
    }

    /// The connection form is the one whose fields depend on an answer inside it,
    /// so changing the engine builds the rest of it again - keeping whatever was
    /// typed that the new engine also asks for.
    pub fn afterFormKey(self: *App) !void {
        const form = &(self.typing.form orelse return);
        if (form.purpose != .connection) {
            return;
        }
        const picked = conns.Engine.of(form.valueNamed("engine"));
        if (picked == self.typing.built_for) {
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
        const read_only = form.isOnNamed("read-only");
        try self.showConnectionForm(shape, name, keeps, secret, read_only);
        // Back on the engine, so it can be cycled again without walking up to it.
        self.typing.form.?.cursor = 1;
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
            .{ .label = "context", .into = &shape.host },
            .{ .label = "namespace", .into = &shape.name },
            .{ .label = "kubeconfig", .into = &shape.key },
        }) |pair| {
            const value = form.valueNamed(pair.label);
            if (value.len != 0) {
                pair.into.* = arena.dupe(u8, value) catch value;
            }
        }
        shape.tls = if (form.fieldNamed("TLS")) |field| field.on else shape.engine == .s3;
        // The one toggle that reads the other way round: it says to check, and the
        // target says not to.
        shape.insecure = if (form.fieldNamed("check the host key")) |field|
            !field.on
        else if (form.fieldNamed("check the certificate")) |field|
            !field.on
        else
            false;
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
        self.sidebar.objects.deinit(self.allocator);
        self.sidebar.filter.deinit(self.allocator);
        self.saved.filter.deinit(self.allocator);
        self.grid.cols.deinit(self.allocator);
        self.grid.widths.deinit(self.allocator);
        self.grid.rows.deinit(self.allocator);
        self.grid.title.deinit(self.allocator);
        self.report.status.deinit(self.allocator);
        self.follow.statement.deinit(self.allocator);
        self.report.list.deinit(self.allocator);
        self.cursor.marked.deinit(self.allocator);
        self.typing.pending.deinit(self.allocator);
        self.saved.list.deinit();
        self.saved.path.deinit(self.allocator);
        self.saved.pending.deinit(self.allocator);
        if (self.palette) |*open| {
            open.query.deinit(self.allocator);
        }
        self.closeEditor();
        self.cursor.hidden.deinit(self.allocator);
        self.clearConditions();
        self.grid.conditions.deinit(self.allocator);
        self.grid.where_text.deinit(self.allocator);
        self.closeForm();
        for (self.history.items) |entry| {
            self.allocator.free(entry);
        }
        self.history.deinit(self.allocator);
        if (self.grid.order) |value| {
            self.allocator.free(value);
        }
        if (self.grid.name) |value| {
            self.allocator.free(value);
        }
        self.grid.schema.deinit(self.allocator);
        if (self.typing.prompt) |*prompt| {
            prompt.buffer.deinit(self.allocator);
        }
        self.allocator.free(self.owned_path);
        self.arena.deinit();
        self.report.arena.deinit();
        self.object.arena.deinit();
        self.typing.arena.deinit();
    }

    /// The table on screen, with the schema it lives in.
    pub fn currentTable(self: *App) ?database.Table {
        return .{ .schema = self.grid.schema.items, .name = self.grid.name orelse return null };
    }

    pub fn hasTable(self: *App) bool {
        return self.grid.name != null;
    }

    fn setTable(self: *App, name: ?[]const u8) !void {
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

    fn setTitle(self: *App, comptime fmt: []const u8, args: anytype) void {
        self.grid.title.clearRetainingCapacity();
        self.grid.title.print(self.allocator, fmt, args) catch {};
    }

    // -------------------------------------------------------------- schema

    fn freeObjects(self: *App) void {
        for (self.sidebar.objects.items) |object| {
            self.allocator.free(object.name);
            self.allocator.free(object.group);
            self.allocator.free(object.kind);
        }
        self.sidebar.objects.clearRetainingCapacity();
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
            .int => |v| try std.fmt.allocPrint(arena, "{d}", .{v}),
            .float => |v| try std.fmt.allocPrint(arena, "{d}", .{v}),
        };
    }

    /// Column names of a table, in declared order.
    /// Column names in order, for the forms and the dumps.
    pub fn columnsOf(self: *App, arena: std.mem.Allocator, name: []const u8) ![]const []const u8 {
        var list: std.ArrayListUnmanaged([]const u8) = .empty;
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

        self.grid.failed = false;
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
        self.object.title = try std.fmt.allocPrint(arena, "{s}", .{name});
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

    fn clearConditions(self: *App) void {
        for (self.grid.conditions.items) |condition| {
            self.allocator.free(condition.column);
            self.allocator.free(condition.value);
        }
        self.grid.conditions.clearRetainingCapacity();
    }

    pub fn isHidden(self: *App, column: usize) bool {
        return std.mem.indexOfScalar(usize, self.cursor.hidden.items, column) != null;
    }

    pub fn isMarked(self: *App, row: usize) bool {
        return std.mem.indexOfScalar(usize, self.cursor.marked.items, row) != null;
    }

    pub fn toggleMark(self: *App) !void {
        if (self.cursor.row >= self.grid.rows.items.len) {
            return;
        }
        if (std.mem.indexOfScalar(usize, self.cursor.marked.items, self.cursor.row)) |at| {
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
    fn noRowHere(self: *App) bool {
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
        var targets: std.ArrayListUnmanaged(usize) = .empty;
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
        var keys: std.ArrayListUnmanaged(Position) = .empty;
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
        if (self.saved.read_only) {
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
            self.complain("{d} of {d} statement(s) failed, press m for details{s}", .{
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
            self.complain("{s} holds rows, not files - this is for SFTP, S3 and Azure", .{self.caps().label});
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
    /// Copy what is chosen to the other pane, asking first where that would write
    /// over something.
    ///
    /// A copy is the one thing here that destroys without saying so: the name is
    /// the same on both sides, so the file that was there is simply gone and there
    /// is nothing to undo it with. Removing already asks; this is the same
    /// question about the same loss.
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

        // What is already there, by name. Asked of the far side, which for a bucket
        // or a server is a request each - so only for what is actually being
        // copied, and only once.
        //
        // A file written over a file, and nothing else. An object store answers
        // "directory" for any name it has not got, because a prefix is not a thing
        // it keeps; and a directory copied onto a directory is a merge, where what
        // would be lost is a file inside it and not the name being asked about.
        var over: usize = 0;
        var first: []const u8 = "";
        for (chosen) |entry| {
            if (entry.kind != .file) {
                continue;
            }
            const target = try database.store.join(arena, to.where(), entry.name);
            const there = to.place.stat(arena, target) catch continue;
            if (there.kind != .file) {
                continue;
            }
            if (over == 0) {
                first = entry.name;
            }
            over += 1;
        }
        if (over != 0) {
            try self.askOverwrite(over, first);
            return;
        }
        try self.copyChosen();
    }

    fn askOverwrite(self: *App, over: usize, first: []const u8) !void {
        if (self.typing.prompt) |*old| {
            old.buffer.deinit(self.allocator);
        }
        self.typing.prompt = .{ .kind = .overwrite, .label = " type y to overwrite: " };
        if (over == 1) {
            self.complain("{s} is already there - write over it?", .{first});
        } else {
            self.complain("{d} of them are already there - write over them?", .{over});
        }
    }

    /// The copy itself, once there is nothing left to ask.
    pub fn copyChosen(self: *App) !void {
        const manager = self.files orelse return;
        const from = manager.here();
        const to = manager.there();
        if (!self.mayWriteTo(to.place)) {
            return;
        }

        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const arena = scratch.allocator();

        const chosen = try from.chosen(arena);
        if (chosen.len == 0) {
            self.complain("nothing to copy", .{});
            return;
        }

        self.running.copy_started = monotonicMs();
        self.running.copy_ticked = self.running.copy_started - 1000;
        self.running.cancelled = false;
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
                    if (self.running.cancelled) "stopped" else if (why.len != 0) why else from_why,
                });
                to.reload(self.allocator);
                return;
            };
            total.files += tally.files;
            total.dirs += tally.dirs;
            total.bytes += tally.bytes;
            total.refused += tally.refused;
        }
        to.reload(self.allocator);
        from.marked.clearRetainingCapacity();
        var room: [16]u8 = undefined;
        if (total.refused != 0) {
            // A name that could have been written somewhere else is worth saying out
            // loud, not counting quietly: it means the other end sent something it had
            // no business sending.
            self.complain("copied {d} file(s) - {s}, and left {d} with a name that would not stay put", .{
                total.files,
                Files.size(&room, total.bytes),
                total.refused,
            });
            return;
        }
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
        if (now - self.running.copy_ticked < 90) {
            return !self.running.cancelled;
        }
        self.running.copy_ticked = now;
        if (self.screen.interrupted()) {
            self.running.cancelled = true;
        }
        self.drawCopying(name, done, whole);
        return !self.running.cancelled;
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
        self.screen.style(.{ .bg = C.bar, .fg = if (self.running.cancelled) C.warn else C.accent, .bold = true });
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
        if (!self.mayWriteTo(pane.place)) {
            return;
        }
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
        if (!self.mayWriteTo(pane.place)) {
            return;
        }
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
        if (!self.mayWriteTo(pane.place)) {
            return;
        }
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

        if (std.mem.eql(u8, verb, "q") or std.mem.eql(u8, verb, "quit")) {
            self.quit = true;
        } else if (std.mem.eql(u8, verb, "limit")) {
            const value = std.fmt.parseInt(usize, argument, 10) catch {
                self.complain(":limit needs a number", .{});
                return;
            };
            self.grid.limit = @max(1, @min(100000, value));
            self.reload() catch {};
            self.say("{d} rows per page", .{self.grid.limit});
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
        } else if (std.mem.eql(u8, verb, "open")) {
            try self.reopen(argument);
        } else if (std.mem.eql(u8, verb, "vacuum")) {
            self.conn.exec("VACUUM") catch {
                self.complain("{s}", .{self.conn.message()});
                return;
            };
            self.say("database vacuumed", .{});
        } else {
            self.complain("unknown :{s} - try :export, :dump, :limit, :text, :follow, :open, :check, :analyze, :vacuum, :q", .{verb});
        }
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
        var out: std.ArrayListUnmanaged(u8) = .empty;
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
            .int => |value| try std.fmt.allocPrint(arena, "{d}", .{value}),
            .float => |value| try std.fmt.allocPrint(arena, "{d}", .{value}),
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
        self.grid.schema.clearRetainingCapacity();
        try self.firstSchema();
        self.clearConditions();
        self.grid.where_text.clearRetainingCapacity();
        self.cursor.hidden.clearRetainingCapacity();
        self.cursor.marked.clearRetainingCapacity();
        self.sidebar.selected = 0;
        self.grid.page = 0;
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
        for (self.sidebar.objects.items) |object| {
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
        if (self.typing.form) |*open| {
            open.deinit();
        }
        self.typing.form = null;
    }

    pub fn newForm(self: *App, purpose: Form.Purpose, title: []const u8, hint: []const u8) !*Form.Form {
        self.closeForm();
        self.typing.form = Form.Form.init(self.allocator, purpose, title);
        self.typing.form.?.hint = hint;
        return &self.typing.form.?;
    }

    /// Insert, edit or clone a row of the current table.
    pub fn openRowForm(self: *App, mode: enum { insert, edit, clone }) !void {
        const table = self.currentTable() orelse {
            self.complain("open a table first", .{});
            return;
        };
        // An engine that will not take this is asked before the form is drawn, not
        // after it has been filled in. Which of the two it is matters: a Kafka
        // record can be written and not changed, and a Kubernetes object neither.
        const allowed = self.caps();
        const refused = if (mode == .edit) allowed.no_update else allowed.no_insert;
        if (refused.len != 0) {
            self.complain("{s}", .{refused});
            return;
        }
        if (mode != .insert and self.noRowHere()) {
            return;
        }
        const form = try self.newForm(.row, switch (mode) {
            .insert => "new row",
            .edit => "edit row",
            .clone => "clone row",
        }, "an empty value with a DEFAULT is left to the engine");
        form.table = try form.arena.allocator().dupe(u8, table.name);
        if (mode == .edit) {
            form.key = if (self.grid.rows.items[self.cursor.row].key) |key|
                try copyFilters(form.arena.allocator(), key)
            else
                null;
        }
        const columns = try self.columnDefs(form.arena.allocator(), table.name);
        for (columns) |column| {
            var initial: []const u8 = "";
            var is_null = mode == .insert and column.dflt == null and !column.notnull;
            if (mode != .insert) {
                for (self.grid.cols.items, 0..) |name, i| {
                    if (!std.mem.eql(u8, name, column.name)) {
                        continue;
                    }
                    const cell = self.grid.rows.items[self.cursor.row].cells[i];
                    is_null = cell.kind == .nul;
                    initial = if (is_null) "" else cell.text;
                }
            }
            // The label is what the column is *called*; what it is - the type, the
            // NOT NULL, the default - goes after the field, where it reads as a note
            // about the value rather than as part of the name.
            var about: std.ArrayListUnmanaged(u8) = .empty;
            try about.appendSlice(form.arena.allocator(), column.type);
            if (column.notnull) {
                try about.appendSlice(form.arena.allocator(), " NOT NULL");
            }
            if (column.dflt) |value| {
                try about.print(form.arena.allocator(), " = {s}", .{value});
            }
            try form.text(column.name, initial, 34);
            try form.wasNamed(column.name);
            try form.toggle("null", is_null);
            form.sameLine();
            try form.wasNamed(column.name);
            try form.describe(about.items);
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
        const table_label = if (alter) (self.grid.name orelse "") else "";
        const form = try self.newForm(
            if (alter) .alter_table else .create_table,
            if (alter) "alter table" else "create table",
            "ctrl+n adds a column, ctrl+k removes one",
        );
        form.row_size = 5;
        form.table = try form.arena.allocator().dupe(u8, table_label);
        try form.text("table name", table_label, 30);
        // Only an engine that has to rebuild loses anything by altering; MySQL and
        // PostgreSQL change the table in place.
        if (alter and self.caps().rebuild_to_alter) {
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
        const form = &(self.typing.form orelse return);
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
        const form = &(self.typing.form orelse return);
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
        const form = try self.newForm(.index, "create index", "columns are comma separated");
        form.table = try form.arena.allocator().dupe(u8, table.name);
        var suggested: std.ArrayListUnmanaged(u8) = .empty;
        try suggested.print(form.arena.allocator(), "{s}_idx", .{table.name});
        try form.text("index name", suggested.items, 30);
        try form.text("columns", if (self.grid.cols.items.len > 0) self.grid.cols.items[self.cursor.col] else "", 40);
        try form.toggle("unique", false);
        try form.text("partial WHERE", "", 40);
    }

    pub fn openForeignKeyForm(self: *App) !void {
        const table = self.currentTable() orelse {
            self.complain("open a table first", .{});
            return;
        };
        const form = try self.newForm(.foreign_key, "add foreign key", "the table is rebuilt");
        form.table = try form.arena.allocator().dupe(u8, table.name);
        const targets = try self.tableNames(form.arena.allocator(), table.name);
        try form.text("column", if (self.grid.cols.items.len > 0) self.grid.cols.items[self.cursor.col] else "", 24);
        try form.choice("references", targets, 0);
        try form.text("target column", "", 24);
        try form.choice("on update", &Form.ACTIONS, 0);
        try form.choice("on delete", &Form.ACTIONS, 0);
    }

    pub fn openViewForm(self: *App) !void {
        const form = try self.newForm(.view, "create view", "");
        try form.text("view name", "", 30);
        try form.text("select", "SELECT ", 60);
    }

    pub fn openTriggerForm(self: *App) !void {
        const table_label = self.grid.name orelse "";
        const form = try self.newForm(.trigger, "create trigger", "");
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
        const form = try self.newForm(.rename_table, "rename table", "");
        form.table = try form.arena.allocator().dupe(u8, table.name);
        try form.text("new name", table.name, 30);
    }

    pub fn openCopyForm(self: *App) !void {
        const table = self.currentTable() orelse {
            self.complain("open a table first", .{});
            return;
        };
        const form = try self.newForm(.copy_table, "copy table", "");
        form.table = try form.arena.allocator().dupe(u8, table.name);
        var suggested: std.ArrayListUnmanaged(u8) = .empty;
        try suggested.print(form.arena.allocator(), "{s}_copy", .{table.name});
        try form.text("new name", suggested.items, 30);
        try form.toggle("with the rows", true);
    }

    pub fn openSearchForm(self: *App) !void {
        const form = try self.newForm(.search_all, "search every table", "every text column of every table");
        try form.text("contains", "", 40);
    }

    pub fn openFilterForm(self: *App) !void {
        const table = self.currentTable() orelse {
            self.complain("open a table first", .{});
            return;
        };
        const form = try self.newForm(.filter, "filter rows", "empty values are ignored");
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
        try form.text("raw WHERE", self.grid.where_text.items, 50);
    }

    pub fn openColumnForm(self: *App) !void {
        if (self.grid.cols.items.len == 0) {
            return;
        }
        const form = try self.newForm(.columns, "visible columns", "space toggles one, ctrl+s applies them");
        for (self.grid.cols.items, 0..) |name, i| {
            try form.toggle(name, !self.isHidden(i));
        }
    }

    /// Pick a schema on an engine that has them.
    pub fn openSchemaForm(self: *App) !void {
        if (!self.caps().schemas) {
            self.complain("{s} has no schemas", .{self.caps().label});
            return;
        }
        const form = try self.newForm(.schema, "schema", "");
        const list = try self.conn.schemas(form.arena.allocator());
        if (list.len == 0) {
            self.complain("no schema to switch to", .{});
            return;
        }
        var at: usize = 0;
        for (list, 0..) |name, i| {
            if (std.mem.eql(u8, name, self.grid.schema.items)) {
                at = i;
            }
        }
        try form.choice("use", list, at);
    }

    pub fn openOpenForm(self: *App) !void {
        const form = try self.newForm(.open_file, "open a database", "");
        try form.text("path", self.path, 60);
    }

    // ------------------------------------------------------- form submission

    /// Turn the open form into SQL and run it. Everything goes through
    /// `runBatch`, so a failure is reported the same way a typed query is.
    pub fn submitForm(self: *App) !void {
        const form = &(self.typing.form orelse return);
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
                try self.conn.ddl().createIndex(&sql, a, .{ .schema = self.grid.schema.items, .name = form.table }, form.valueOf(0), columns.items, form.isOn(2), form.valueOf(3));
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
                const target = database.Table{ .schema = self.grid.schema.items, .name = form.table };
                const context = try self.conn.alterContext(a, target, columns);
                try self.conn.ddl().addForeignKey(&sql, a, target, .{
                    .column = form.valueOf(0),
                    .target_table = form.valueOf(1),
                    .target_column = form.valueOf(2),
                    .on_update = form.valueOf(3),
                    .on_delete = form.valueOf(4),
                }, context);
            },
            .view => try self.conn.ddl().createView(&sql, a, .{ .schema = self.grid.schema.items, .name = form.valueOf(0) }, form.valueOf(1)),
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
            .rename_table => try self.conn.ddl().renameTable(&sql, a, .{ .schema = self.grid.schema.items, .name = form.table }, form.valueOf(0)),
            .copy_table => try self.conn.ddl().copyTable(&sql, a, .{ .schema = self.grid.schema.items, .name = form.table }, form.valueOf(0), form.isOn(1)),
            .filter => {
                try self.applyFilter(form);
                self.closeForm();
                return;
            },
            .columns => {
                self.cursor.hidden.clearRetainingCapacity();
                for (form.fields.items, 0..) |field, i| {
                    if (!field.on) {
                        try self.cursor.hidden.append(self.allocator, i);
                    }
                }
                self.closeForm();
                self.say("{d} column(s) hidden", .{self.cursor.hidden.items.len});
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
                try dump_mod.runExport(self, form);
                self.closeForm();
                return;
            },
            .import_data => {
                try dump_mod.runImport(self, form);
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
                const read_only = form.isOnNamed("read-only");
                const typed = try self.allocator.dupe(u8, form.valueNamed("password"));
                defer self.allocator.free(typed);
                const editing = self.saved.editing;
                self.saved.editing = null;
                self.closeForm();
                if (target.len == 0) {
                    self.complain("a connection needs something to point at", .{});
                    return;
                }
                if (editing) |at| {
                    if (at < self.saved.list.items.items.len) {
                        // A connection that stops using the keychain, or moves to
                        // another target, leaves nothing behind in it.
                        const was = self.saved.list.items.items[at];
                        if (was.keeps.inKeychain() and (!keeps.inKeychain() or !std.mem.eql(u8, was.target, target))) {
                            keychain.remove(was.target);
                        }
                        _ = self.saved.list.items.orderedRemove(at);
                    }
                }
                var scratch = std.heap.ArenaAllocator.init(self.allocator);
                defer scratch.deinit();
                const clean = try conns.withoutPassword(scratch.allocator(), target);
                try self.saved.list.addWith(
                    if (name.len != 0) name else try conns.suggestName(scratch.allocator(), clean),
                    clean,
                    keeps,
                    // The file keeps the password itself; the keychain keeps its own,
                    // and an empty one here means "keep the one I am about to be
                    // asked for".
                    if (keeps == .file) typed else "",
                    read_only,
                );
                if (keeps.inKeychain() and typed.len != 0) {
                    keychain.store(clean, typed, if (keeps == .touchid) .anyone else .keychain) catch {
                        self.complain("the keychain would not take the password", .{});
                    };
                }
                conns.save(&self.saved.list, self.saved.path.items) catch {};
                self.saved.at = 0;
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
        if (self.report.list.items.len != 0 and self.report.list.items[self.report.list.items.len - 1].failure != null) {
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
                .schema = try a.dupe(u8, self.grid.schema.items),
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
            try self.conn.ddl().createTable(sql, a, .{ .schema = self.grid.schema.items, .name = name }, columns.items, &.{});
            return;
        }
        // Whatever this engine has to preserve across an alter - on SQLite the
        // foreign keys and the indexes, with the renames applied.
        const target = database.Table{ .schema = self.grid.schema.items, .name = form.table };
        const context = try self.conn.alterContext(a, target, columns.items);
        try self.conn.ddl().alterTable(sql, a, target, name, columns.items, context);
    }

    fn applyFilter(self: *App, form: *Form.Form) !void {
        self.clearConditions();
        self.grid.where_text.clearRetainingCapacity();
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
            try self.grid.conditions.append(self.allocator, .{
                .column = try self.allocator.dupe(u8, column),
                .op = op,
                .value = text,
            });
        }
        const raw = form.valueOf(9);
        if (raw.len != 0) {
            try self.grid.where_text.appendSlice(self.allocator, raw);
        }
        self.grid.page = 0;
        self.cursor.row = 0;
        self.reload() catch |err| {
            self.complain("{s}", .{@errorName(err)});
            return;
        };
        if (self.grid.failed) {
            return; // the reason is already on screen
        }
        if (!self.isFiltered()) {
            self.say("filter cleared", .{});
        } else if (self.grid.counted) {
            self.say("{d} row(s) match", .{self.grid.total});
        } else {
            self.say("{d} row(s) on this page; {s} cannot count the rest without reading it", .{
                self.grid.rows.items.len,
                self.caps().label,
            });
        }
    }

    /// Look for a string in every text-ish column of every table.
    fn searchEverything(self: *App, needle: []const u8) !void {
        // One SELECT per column of every table, unioned - which is SQL, and there is
        // no honest way to put it to an engine that has none. Filtering one table
        // works there, and says so.
        if (!self.caps().speaks_sql) {
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
        for (self.sidebar.objects.items) |object| {
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
                try sql.appendSlice(a, self.caps().text_cast);
                try sql.appendSlice(a, ") AS \"value\" FROM ");
                try database.quoteName(&sql, a, object.name);
                try sql.appendSlice(a, " WHERE CAST(");
                try database.quoteName(&sql, a, column.name);
                try sql.appendSlice(a, " AS ");
                try sql.appendSlice(a, self.caps().text_cast);
                try sql.appendSlice(a, ") LIKE ");
                try database.quote(&sql, a, pattern.items);
            }
        }
        if (parts == 0) {
            self.complain("nothing to search in", .{});
            return;
        }
        try sql.print(a, "\nLIMIT {d}", .{self.grid.limit});
        try self.setTable(null);
        self.clearConditions();
        self.grid.where_text.clearRetainingCapacity();
        self.cursor.hidden.clearRetainingCapacity();
        self.grid.page = 0;
        self.cursor.row = 0;
        self.cursor.col = 0;
        self.load(sql.items, null, false) catch {
            self.complain("{s}", .{self.conn.message()});
            return;
        };
        self.grid.total = @intCast(self.grid.rows.items.len);
        self.setTitle("search: {s}", .{needle});
        self.view = .grid;
        self.focus = .main;
        self.say("{d} hit(s) in {d} column(s)", .{ self.grid.rows.items.len, parts });
    }

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
        .text => |t| .{
            .text = try flatten(arena, t),
            .original = if (std.mem.indexOfAny(u8, t, "\n\r\t") != null) try arena.dupe(u8, t) else "",
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
pub fn writeFile(path: []const u8, bytes: []const u8) !void {
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

/// Milliseconds on the clock that only goes forwards. Kept as a name of its own
/// because this file reads it in six places, and the short name is what makes
/// those lines say what they are about.
pub fn monotonicMs() f64 {
    return database.clock.steadyMs();
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
        if (std.ascii.indexOfIgnoreCase(message, needle) != null) {
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
        std.ascii.indexOfIgnoreCase(target, needle) != null;
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

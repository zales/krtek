//! The program with no terminal under it, for the tests.
//!
//! What a key does and what is then drawn used to be reachable only through a
//! pseudo terminal: a script types, waits a third of a second for the answer
//! and reads the escape sequences back. That is the right test of a terminal
//! and a slow, timing-bound one of everything above it - so most of what is
//! above it had no test at all. This is the same loop `main` runs, a key and
//! then a frame, on a screen that is only cells: a SQLite file in a directory
//! of its own, the keys given as a script, and the screen read back as text.
//!
//!     var bench = try Bench.open("CREATE TABLE t (n); INSERT INTO t VALUES (1);");
//!     defer bench.close();
//!     try bench.keys("{enter}x");
//!     try bench.sees("delete 1 row?");
//!
//! The scripts are spelled the way tests/screen.py spells them.

const std = @import("std");
const database = @import("db");
const app_mod = @import("app.zig");
const draw = @import("draw.zig");
const input = @import("input.zig");
const term = @import("term.zig");

const testing = std.testing;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn system(command: [*:0]const u8) c_int;

/// How many have been made, so each has a directory of its own.
var made: usize = 0;

pub const Bench = struct {
    env: std.process.Environ.Map,
    /// Everything this one leaves on disk: the database, and the configuration
    /// the program keeps its list of connections in.
    dir: [:0]u8,
    /// The database, where there is one.
    file: []u8,
    app: app_mod.App,
    size: term.Size,
    /// The screen as it was last read.
    last: []u8 = &.{},

    pub const Options = struct {
        size: term.Size = .{ .rows = 24, .cols = 100 },
        /// What the list of saved connections holds before the program starts,
        /// as the file has it. `{dir}` is this bench's own directory.
        connections: []const u8 = "",
        /// Start on the list of connections rather than in the database.
        on_list: bool = false,
    };

    /// A database with these statements run in it, opened the way a file
    /// named on the command line is.
    pub fn open(sql: []const u8) !*Bench {
        return openWith(sql, .{});
    }

    pub fn openWith(sql: []const u8, options: Options) !*Bench {
        const a = testing.allocator;
        const self = try a.create(Bench);
        errdefer a.destroy(self);
        made += 1;
        const dir = try a.printSentinel("/tmp/krtek-bench-{d}-{d}", .{ std.c.getpid(), made }, 0);
        errdefer a.free(dir);
        try testing.expectEqual(@as(c_int, 0), std.c.mkdir(dir, 0o755));
        const file = try a.print("{s}/bench.db", .{dir});
        errdefer a.free(file);

        {
            var report: std.ArrayList(u8) = .empty;
            defer report.deinit(a);
            const made_db = try database.sqlite.Db.open(a, file, &report);
            defer made_db.close();
            made_db.exec(sql) catch {
                std.debug.print("the bench's own statements were refused: {s}\n", .{made_db.message()});
                return error.TestUnexpectedResult;
            };
        }

        // A configuration of its own, and no kubeconfig: the list of
        // connections offers every context it finds, and a test that reads the
        // list on a machine that has clusters would read somebody's clusters.
        const config = try a.printSentinel("{s}/config/krtek", .{dir}, 0);
        defer a.free(config);
        const parent = try a.printSentinel("{s}/config", .{dir}, 0);
        defer a.free(parent);
        _ = std.c.mkdir(parent, 0o755);
        _ = std.c.mkdir(config, 0o755);
        const kube = try a.printSentinel("{s}/kubeconfig", .{dir}, 0);
        defer a.free(kube);
        try write(kube, "apiVersion: v1\nkind: Config\nclusters: []\ncontexts: []\nusers: []\n");
        _ = setenv("KUBECONFIG", kube, 1);
        if (options.connections.len != 0) {
            const list = try a.printSentinel("{s}/connections", .{config}, 0);
            defer a.free(list);
            const text = try std.mem.replaceOwned(u8, a, options.connections, "{dir}", dir);
            defer a.free(text);
            try write(list, text);
        }

        self.* = .{
            .env = .init(a),
            .dir = dir,
            .file = file,
            .app = undefined,
            .size = options.size,
        };
        errdefer self.env.deinit();
        try self.env.put("XDG_CONFIG_HOME", parent);
        // Dark, said outright: with no terminal there is nobody to ask.
        try self.env.put("KRTEK_THEME", "dark");

        const cells = try term.Term.headless(a, testing.io, &self.env, options.size);
        self.app = try app_mod.App.initOn(a, cells, if (options.on_list) "" else file, &self.env);
        // At its final address now, which is when `main` arms this too.
        self.app.watchStatements();
        return self;
    }

    pub fn close(self: *Bench) void {
        const a = testing.allocator;
        self.app.deinit();
        self.env.deinit();
        a.free(self.last);
        var buffer: [256]u8 = undefined;
        if (std.mem.printSentinel(&buffer, "rm -rf '{s}'", .{self.dir}, 0)) |command| {
            _ = system(command);
        } else |_| {}
        a.free(self.file);
        a.free(self.dir);
        a.destroy(self);
    }

    /// One key, and what `main` does with an error from it.
    pub fn press(self: *Bench, key: term.Key) !void {
        input.handle(&self.app, key, self.size) catch |err| {
            const said = if (self.app.connected) self.app.conn.message() else "";
            if (said.len != 0) {
                self.app.complain("{s}", .{said});
            } else {
                self.app.complain("{s}", .{@errorName(err)});
            }
        };
        // A frame after every key, as there is in the program: the drawing is
        // what works out where things are, and some keys depend on it.
        try draw.frame(&self.app, self.size);
    }

    /// A script of keys: text as it is typed, and names in braces -
    /// `{enter} {tab} {esc} {up} {down} {left} {right} {home} {end} {pgup}
    /// {pgdn} {bs} {del} {backtab} {space} {ctrl-s} {alt-1} {tick}`.
    pub fn keys(self: *Bench, script: []const u8) !void {
        var at: usize = 0;
        while (at < script.len) {
            if (script[at] == '{') {
                const end = std.mem.findScalarPos(u8, script, at, '}') orelse return error.UnclosedKey;
                try self.press(try named(script[at + 1 .. end]));
                at = end + 1;
                continue;
            }
            const len = std.unicode.utf8ByteSequenceLength(script[at]) catch 1;
            const point = std.unicode.utf8Decode(script[at .. at + len]) catch script[at];
            try self.press(.{ .char = point });
            at += len;
        }
    }

    /// The same script so many times over, for a form with many fields to
    /// cross.
    pub fn repeat(self: *Bench, script: []const u8, count: usize) !void {
        for (0..count) |_| {
            try self.keys(script);
        }
    }

    /// Text typed as it stands, braces and all - a statement with a `{` in it.
    pub fn typed(self: *Bench, text: []const u8) !void {
        var view = std.unicode.Utf8View.initUnchecked(text).iterator();
        while (view.nextCodepoint()) |point| {
            try self.press(.{ .char = point });
        }
    }

    fn named(name: []const u8) !term.Key {
        const table = [_]struct { []const u8, term.Key }{
            .{ "enter", .enter },           .{ "tab", .tab },        .{ "backtab", .back_tab },
            .{ "esc", .escape },            .{ "bs", .backspace },   .{ "del", .delete },
            .{ "up", .up },                 .{ "down", .down },      .{ "left", .left },
            .{ "right", .right },           .{ "home", .home },      .{ "end", .end },
            .{ "pgup", .page_up },          .{ "pgdn", .page_down }, .{ "tick", .tick },
            .{ "space", .{ .char = ' ' } },
        };
        for (table) |entry| {
            if (std.mem.eql(u8, entry[0], name)) {
                return entry[1];
            }
        }
        if (std.mem.startsWith(u8, name, "ctrl-") and name.len == 6) {
            return .{ .ctrl = name[5] };
        }
        if (std.mem.startsWith(u8, name, "alt-") and name.len == 5) {
            return .{ .alt = name[4] };
        }
        return error.UnknownKey;
    }

    /// The screen as it is now, drawn again and read.
    pub fn screen(self: *Bench) ![]const u8 {
        try draw.frame(&self.app, self.size);
        testing.allocator.free(self.last);
        self.last = &.{};
        self.last = try self.app.screen.shown(testing.allocator);
        return self.last;
    }

    /// One line of it, counted from the top.
    pub fn line(self: *Bench, row: usize) ![]const u8 {
        var lines = std.mem.splitScalar(u8, try self.screen(), '\n');
        var at: usize = 0;
        while (lines.next()) |text| : (at += 1) {
            if (at == row) {
                return text;
            }
        }
        return "";
    }

    /// The line along the bottom but one, which is where the program says
    /// what it did.
    pub fn status(self: *Bench) []const u8 {
        return self.app.report.status.items;
    }

    pub fn sees(self: *Bench, wanted: []const u8) !void {
        const text = try self.screen();
        if (std.mem.find(u8, text, wanted) == null) {
            std.debug.print("\n--- wanted on the screen: {s}\n--- the screen:\n{s}\n", .{ wanted, text });
            return error.TestExpectedEqual;
        }
    }

    pub fn lacks(self: *Bench, unwanted: []const u8) !void {
        const text = try self.screen();
        if (std.mem.find(u8, text, unwanted) != null) {
            std.debug.print("\n--- not wanted on the screen: {s}\n--- the screen:\n{s}\n", .{ unwanted, text });
            return error.TestExpectedEqual;
        }
    }

    pub fn says(self: *Bench, wanted: []const u8) !void {
        if (std.mem.find(u8, self.status(), wanted) == null) {
            std.debug.print("\n--- wanted on the status line: {s}\n--- it says: {s}\n", .{ wanted, self.status() });
            return error.TestExpectedEqual;
        }
    }

    /// What the database itself says, asked on the program's own connection:
    /// the first column of every row, joined with a space. Whatever a key did,
    /// this is where it has to have ended up.
    pub fn asked(self: *Bench, sql: []const u8) ![]const u8 {
        const a = testing.allocator;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);
        var rows = (try self.app.conn.query(sql, null)) orelse return error.TestUnexpectedResult;
        defer rows.close();
        while (try rows.next()) {
            if (out.items.len != 0) {
                try out.append(a, ' ');
            }
            switch (rows.value(0)) {
                .null => try out.appendSlice(a, "NULL"),
                .int => |value| try out.print(a, "{d}", .{value}),
                .float => |value| try out.print(a, "{d}", .{value}),
                .text, .blob => |bytes| try out.appendSlice(a, bytes),
            }
        }
        a.free(self.last);
        self.last = try out.toOwnedSlice(a);
        return self.last;
    }

    pub fn expectAsked(self: *Bench, sql: []const u8, wanted: []const u8) !void {
        try testing.expectEqualStrings(wanted, try self.asked(sql));
    }

    fn write(path: [:0]const u8, bytes: []const u8) !void {
        const file = std.c.fopen(path, "wb") orelse return error.CannotCreate;
        const taken = bytes.len == 0 or std.c.fwrite(bytes.ptr, 1, bytes.len, file) == bytes.len;
        if (std.c.fclose(file) != 0 or !taken) {
            return error.WriteFailed;
        }
    }
};

/// A small library, which is what most of the tests want to look at.
pub const BOOKS =
    \\CREATE TABLE authors (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
    \\CREATE TABLE books (
    \\  id INTEGER PRIMARY KEY,
    \\  title TEXT NOT NULL,
    \\  year INTEGER,
    \\  author INTEGER REFERENCES authors(id) ON DELETE CASCADE
    \\);
    \\INSERT INTO authors VALUES (1, 'Karel Čapek'), (2, 'Milan Kundera'), (3, 'Zdeněk Jirotka');
    \\INSERT INTO books VALUES
    \\  (1, 'RUR', 1920, 1), (2, 'Krakatit', 1924, 1), (3, 'Žert', 1967, 2), (4, 'Saturnin', 1942, 3);
;

test "the bench opens a database and draws what the program would" {
    var bench = try Bench.open(BOOKS);
    defer bench.close();
    // The first table of the list is open, and the list is beside it.
    try bench.sees("authors");
    try bench.sees("books");
    try bench.sees("Karel Čapek");
    try bench.says("SQLite");
}

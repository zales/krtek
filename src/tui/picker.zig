//! A list to pick one thing out of: what is typed narrows it, the arrows move
//! in it, enter takes what the cursor is on and esc takes nothing.
//!
//! One thing out of several was chosen in two ways, neither of them this. A
//! schema - a namespace, a database, a vhost - was a form with one field in
//! it, turned with the left and right arrows one name at a time and sent with
//! ctrl+s: thirty namespaces were up to twenty-nine presses to reach one whose
//! name was known all along. And a choice inside a form was the same field,
//! with the same arrows: the table a foreign key points at, out of however
//! many tables there are.
//!
//! The command palette had the answer and kept it to itself. This is the
//! palette's list for anything that is a list of names: `#` opens it on the
//! schemas, and enter on a choice in a form opens it on what that choice can
//! be. The arrows in a form still turn a choice, for the ones with three
//! values in them.
//!
//! The list and how it is narrowed are here. The keys are in `input.zig` and
//! the drawing in `draw.zig`, beside the palette's, and they share its panel.

const std = @import("std");
const app_mod = @import("app.zig");
const fuzzy = @import("fuzzy.zig");
const line_mod = @import("line.zig");

const App = app_mod.App;

pub const Picker = struct {
    /// The names, copied: what they were read from - a reply of the engine's,
    /// a form's own memory - may be gone before one of them is chosen.
    arena: std.heap.ArenaAllocator,
    /// What is being chosen, which is what the box is called.
    title: []const u8,
    options: []const []const u8,
    /// The options that match what is typed, best first, as places in
    /// `options`; the first `count` of them are meant.
    found: []usize,
    count: usize = 0,
    query: std.ArrayList(u8) = .empty,
    /// Where in the query the typing is.
    caret: usize = line_mod.END,
    /// Which of the matches the cursor is on.
    at: usize = 0,
    /// The one that is in force now, where one is: the list opens on it, so
    /// that enter straight away changes nothing, and it is marked.
    current: ?usize,
    purpose: Purpose,

    /// What the choice is for, which is what is done with it.
    pub const Purpose = union(enum) {
        /// The schema the list of objects is read from.
        schema,
        /// A choice in the open form, by where that field is in it.
        field: usize,
    };

    pub fn init(gpa: std.mem.Allocator, title: []const u8, options: []const []const u8, current: ?usize, purpose: Purpose) !Picker {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const copies = try a.alloc([]const u8, options.len);
        for (options, copies) |option, *copy| {
            copy.* = try a.dupe(u8, option);
        }
        const called = try a.dupe(u8, title);
        const found = try a.alloc(usize, options.len);
        // The arena last, once everything that is going to be in it is: it is
        // copied into the struct here, and a copy taken any earlier would not
        // know about what was allocated after it - and would not free it.
        var self = Picker{
            .arena = arena,
            .title = called,
            .options = copies,
            .found = found,
            .current = if (current) |at| (if (at < options.len) at else null) else null,
            .purpose = purpose,
        };
        self.narrow();
        return self;
    }

    pub fn deinit(self: *Picker, gpa: std.mem.Allocator) void {
        self.query.deinit(gpa);
        self.arena.deinit();
    }

    /// Work out again which options match, after the query has changed.
    ///
    /// With nothing typed that is all of them in the order they came, and the
    /// cursor on the one in force. With something typed the best match is
    /// first and the cursor is on it, so that a few letters and enter is the
    /// whole of choosing.
    pub fn narrow(self: *Picker) void {
        var scores: [SCORED]u16 = undefined;
        self.count = 0;
        self.at = 0;
        for (self.options, 0..) |option, i| {
            const got = score(option, self.query.items) orelse continue;
            // Best first; equal scores keep the order they came in, which for
            // a list of names is the order somebody already knows them in. An
            // insertion sort, on a keystroke: a list past `SCORED` long is
            // narrowed and left in its own order, which is still a list.
            var at = self.count;
            if (self.count < SCORED) {
                while (at > 0 and got > scores[at - 1]) : (at -= 1) {
                    scores[at] = scores[at - 1];
                    self.found[at] = self.found[at - 1];
                }
                scores[at] = got;
            }
            self.found[at] = i;
            self.count += 1;
        }
        if (self.query.items.len == 0) {
            if (self.current) |now| {
                self.at = now;
            }
        }
    }

    /// How many matches are ranked. More than any list of schemas or tables
    /// is likely to be, and a bound on what one keystroke costs.
    const SCORED = 2048;

    /// The option the cursor is on, as a place in `options`.
    pub fn chosen(self: *const Picker) ?usize {
        return if (self.at < self.count) self.found[self.at] else null;
    }

    pub fn down(self: *Picker, by: usize) void {
        if (self.count != 0) {
            self.at = @min(self.at + by, self.count - 1);
        }
    }

    pub fn up(self: *Picker, by: usize) void {
        self.at -|= by;
    }

    /// Which letters of an option the query matched, for the drawing.
    pub fn hit(self: *const Picker, option: usize) fuzzy.Hit {
        var out: fuzzy.Hit = .{};
        var words = std.mem.tokenizeAny(u8, self.query.items, " ");
        if (words.next()) |word| {
            _ = fuzzy.match(self.options[option], word, &out);
        }
        return out;
    }
};

/// How well a name matches what was typed, or null where it does not: every
/// word of the query has to be in it, scattered or not, and a word that is in
/// it as one piece counts for more - the way the palette ranks its actions.
fn score(option: []const u8, query: []const u8) ?u16 {
    if (query.len == 0) {
        return 1;
    }
    var total: u16 = 0;
    var words = std.mem.tokenizeAny(u8, query, " ");
    while (words.next()) |word| {
        const got = fuzzy.match(option, word, null) orelse return null;
        total +|= got *| 4;
        if (std.ascii.findIgnoreCase(option, word) != null) {
            total +|= 40;
            // And at the very start of it for more again: `pay` is `payments`
            // before it is `prepay`.
            if (std.ascii.startsWithIgnoreCase(option, word)) {
                total +|= 20;
            }
        }
    }
    return total;
}

// ----------------------------------------------------- what the App does with one
//
// Methods of the App by name, through the aliases at the top of its struct.

/// `#`: the schemas of this connection, to move to one of them.
pub fn openSchemaPicker(self: *App) !void {
    const allowed = self.caps();
    if (!allowed.schemas and !allowed.databases) {
        self.complain("{s} has no schemas", .{allowed.label});
        return;
    }
    var scratch = std.heap.ArenaAllocator.init(self.allocator);
    defer scratch.deinit();
    const list = try self.conn.schemas(scratch.allocator());
    if (list.len == 0) {
        self.complain("no {s} to switch to", .{allowed.schema_noun});
        return;
    }
    var now: ?usize = null;
    for (list, 0..) |name, i| {
        if (std.mem.eql(u8, name, self.grid.schema.items)) {
            now = i;
        }
    }
    try open(self, allowed.schema_noun, list, now, .schema);
}

/// Enter on a choice in a form: everything that choice can be.
pub fn openFieldPicker(self: *App) !void {
    const form = &(self.typing.form orelse return);
    const field = form.field(form.cursor) orelse return;
    const options = switch (field.kind) {
        .choice => |all| all,
        else => return,
    };
    try open(self, field.label, options, field.pick, .{ .field = form.cursor });
}

fn open(self: *App, title: []const u8, options: []const []const u8, current: ?usize, purpose: Picker.Purpose) !void {
    closePicker(self);
    self.picker = try Picker.init(self.allocator, title, options, current, purpose);
    self.say("type to narrow the list - enter takes it, esc leaves it as it is", .{});
}

pub fn closePicker(self: *App) void {
    if (self.picker) |*picker| {
        picker.deinit(self.allocator);
    }
    self.picker = null;
}

/// Enter: take the one the cursor is on, and do what it was chosen for.
pub fn takePicked(self: *App) !void {
    const picker = &(self.picker orelse return);
    const option = picker.chosen() orelse {
        // Nothing matches what was typed, so there is nothing to take; the
        // list stays, for the typing to be put right.
        return;
    };
    switch (picker.purpose) {
        .schema => {
            // Copied out: the list is closed before the schema is read, and
            // the name is the list's.
            const name = try self.allocator.dupe(u8, picker.options[option]);
            defer self.allocator.free(name);
            const same = if (picker.current) |now| now == option else false;
            closePicker(self);
            if (same) {
                self.say("still in {s}", .{name});
                return;
            }
            try self.useSchema(name);
        },
        .field => |at| {
            closePicker(self);
            const form = &(self.typing.form orelse return);
            const field = form.field(at) orelse return;
            switch (field.kind) {
                .choice => |all| if (option < all.len) {
                    field.pick = option;
                },
                else => return,
            }
            // The connection form builds itself again when its engine is
            // another, as it does when the arrows turn it.
            try self.afterFormKey();
        },
    }
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

fn names(picker: *const Picker, buffer: []u8) []const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    for (picker.found[0..picker.count], 0..) |option, i| {
        if (i != 0) {
            writer.writeAll(" ") catch break;
        }
        writer.writeAll(picker.options[option]) catch break;
    }
    return writer.buffered();
}

test "with nothing typed the list is as it came, and the cursor is on the one in force" {
    const all = [_][]const u8{ "default", "kube-system", "payments", "payments-staging", "prepay" };
    var picker = try Picker.init(testing.allocator, "namespace", &all, 2, .schema);
    defer picker.deinit(testing.allocator);
    var buffer: [128]u8 = undefined;
    try testing.expectEqualStrings("default kube-system payments payments-staging prepay", names(&picker, &buffer));
    try testing.expectEqual(@as(?usize, 2), picker.chosen());
    try testing.expectEqualStrings("payments", picker.options[picker.chosen().?]);

    // The arrows stop at the ends.
    picker.down(1);
    try testing.expectEqualStrings("payments-staging", picker.options[picker.chosen().?]);
    picker.down(10);
    try testing.expectEqualStrings("prepay", picker.options[picker.chosen().?]);
    picker.up(99);
    try testing.expectEqualStrings("default", picker.options[picker.chosen().?]);
}

test "what is typed narrows the list, and the best match is first and under the cursor" {
    const all = [_][]const u8{ "default", "kube-system", "prepay", "payments-staging", "payments" };
    var picker = try Picker.init(testing.allocator, "namespace", &all, 0, .schema);
    defer picker.deinit(testing.allocator);
    var buffer: [128]u8 = undefined;

    try picker.query.appendSlice(testing.allocator, "pay");
    picker.narrow();
    // The two that start with it - the one that is little else first - and
    // then the one that only has it inside.
    try testing.expectEqualStrings("payments payments-staging prepay", names(&picker, &buffer));
    try testing.expectEqualStrings("payments", picker.options[picker.chosen().?]);

    // Letters that are in a name without being together still find it, after
    // the names that have them together.
    picker.query.clearRetainingCapacity();
    try picker.query.appendSlice(testing.allocator, "ks");
    picker.narrow();
    try testing.expectEqualStrings("kube-system", picker.options[picker.chosen().?]);

    // Two words are both wanted.
    picker.query.clearRetainingCapacity();
    try picker.query.appendSlice(testing.allocator, "pay stag");
    picker.narrow();
    try testing.expectEqualStrings("payments-staging", names(&picker, &buffer));

    // Whatever its case.
    picker.query.clearRetainingCapacity();
    try picker.query.appendSlice(testing.allocator, "DEF");
    picker.narrow();
    try testing.expectEqualStrings("default", names(&picker, &buffer));

    // And what matches nothing leaves nothing to take.
    picker.query.clearRetainingCapacity();
    try picker.query.appendSlice(testing.allocator, "zzz");
    picker.narrow();
    try testing.expectEqual(@as(usize, 0), picker.count);
    try testing.expectEqual(@as(?usize, null), picker.chosen());

    // Emptied again, it is all of them and the cursor is back on the one in
    // force.
    picker.query.clearRetainingCapacity();
    picker.narrow();
    try testing.expectEqual(@as(usize, 5), picker.count);
    try testing.expectEqualStrings("default", picker.options[picker.chosen().?]);
}

test "the names are the list's own, whatever becomes of where they were read from" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    const read = try scratch.allocator().alloc([]const u8, 2);
    read[0] = try scratch.allocator().dupe(u8, "public");
    read[1] = try scratch.allocator().dupe(u8, "sklad");
    var picker = try Picker.init(testing.allocator, "schema", read, null, .schema);
    defer picker.deinit(testing.allocator);
    scratch.deinit();
    try testing.expectEqualStrings("public", picker.options[0]);
    try testing.expectEqualStrings("sklad", picker.options[1]);
    // Nothing in force, so the cursor is on the first.
    try testing.expectEqual(@as(?usize, 0), picker.chosen());
    // And one that says it is in force past the end of the list is not believed.
    var odd = try Picker.init(testing.allocator, "schema", &.{}, 5, .schema);
    defer odd.deinit(testing.allocator);
    try testing.expectEqual(@as(?usize, null), odd.current);
    try testing.expectEqual(@as(?usize, null), odd.chosen());
}

// On the bench - see bench.zig: the list opened by the keys that open it.

const Bench = @import("bench.zig").Bench;
const BOOKS = @import("bench.zig").BOOKS;

test "enter on a choice in a form opens the list of what it can be, and enter there takes one" {
    var bench = try Bench.open(BOOKS ++ "CREATE TABLE shelves (id INTEGER PRIMARY KEY);");
    defer bench.close();
    // The foreign key form: the column, and under it the table it points at,
    // which is a choice of every table there is.
    try bench.keys("j{enter}K{down}");
    const form = &bench.app.typing.form.?;
    try testing.expectEqualStrings("references", form.fields.items[form.cursor].label);
    try testing.expectEqualStrings("authors", form.valueNamed("references"));
    try bench.says("");
    try testing.expect(std.mem.find(u8, try bench.line(23), "enter the list of them") != null);

    try bench.keys("{enter}");
    try testing.expect(bench.app.picker != null);
    try bench.sees("─ references ─");
    try bench.sees("shelves");
    // The one it is now says so, and the cursor is on it.
    try testing.expectEqualStrings("authors", bench.app.picker.?.options[bench.app.picker.?.chosen().?]);
    try bench.sees("now");

    // A few letters and enter is the whole of it.
    try bench.keys("she");
    try testing.expectEqual(@as(usize, 1), bench.app.picker.?.count);
    try bench.sees("❯ shelves");
    try bench.keys("{enter}");
    try testing.expect(bench.app.picker == null);
    try testing.expect(bench.app.typing.form != null);
    try testing.expectEqualStrings("shelves", bench.app.typing.form.?.valueNamed("references"));

    // Esc puts the list away and leaves the choice as it was. Space opens it
    // as enter does, and the arrows move in it.
    try bench.keys("{space}{up}{up}{esc}");
    try testing.expect(bench.app.picker == null);
    try testing.expectEqualStrings("shelves", bench.app.typing.form.?.valueNamed("references"));
    // The table the key is in comes last in that list, after the others.
    try bench.keys("{space}{down}{enter}");
    try testing.expectEqualStrings("books", bench.app.typing.form.?.valueNamed("references"));
    // And the arrows in the form still turn it one at a time.
    try bench.keys("{left}");
    try testing.expectEqualStrings("shelves", bench.app.typing.form.?.valueNamed("references"));

    // What matches nothing leaves nothing to take: enter does nothing, and
    // the list is still there for the typing to be put right.
    try bench.keys("{enter}zzz");
    try bench.sees("nothing matches");
    try bench.keys("{enter}");
    try testing.expect(bench.app.picker != null);
    try bench.keys("{ctrl-u}boo{enter}");
    try testing.expectEqualStrings("books", bench.app.typing.form.?.valueNamed("references"));
}

test "the engine of a connection is picked from the list, and the form is built for it" {
    var bench = try Bench.openWith(BOOKS, .{ .on_list = true });
    defer bench.close();
    try bench.keys("ashop{down}{enter}");
    try testing.expect(bench.app.picker != null);
    try bench.sees("─ engine ─");
    try bench.keys("postg{enter}");
    try testing.expect(bench.app.picker == null);
    const form = &bench.app.typing.form.?;
    try testing.expectEqualStrings("PostgreSQL", form.valueNamed("engine"));
    // The fields under it are that engine's, and what was typed is kept.
    try testing.expect(form.fieldNamed("host") != null);
    try testing.expect(form.fieldNamed("file") == null);
    try testing.expectEqualStrings("shop", form.valueNamed("name"));
    // Still on the engine, to be chosen again.
    try testing.expectEqual(@as(usize, 1), form.cursor);
    try bench.keys("{enter}kub{enter}");
    try testing.expectEqualStrings("Kubernetes", bench.app.typing.form.?.valueNamed("engine"));
    try testing.expect(bench.app.typing.form.?.fieldNamed("namespace") != null);
}

test "a schema taken from the list is the one that is read, and the one in force changes nothing" {
    var bench = try Bench.open(BOOKS);
    defer bench.close();
    // SQLite has one schema and says so; nothing opens.
    try bench.keys("#");
    try testing.expect(bench.app.picker == null);
    try bench.says("has no schemas");

    // The list itself, as an engine that has several would open it.
    try bench.app.grid.schema.appendSlice(bench.app.allocator, "main");
    bench.app.picker = try Picker.init(bench.app.allocator, "schema", &.{ "main", "archive", "staging" }, 0, .schema);
    try bench.sees("─ schema ─");
    try bench.keys("{enter}");
    try testing.expect(bench.app.picker == null);
    try bench.says("still in main");
    try testing.expectEqualStrings("main", bench.app.grid.schema.items);

    bench.app.picker = try Picker.init(bench.app.allocator, "schema", &.{ "main", "archive", "staging" }, 0, .schema);
    try bench.keys("sta{enter}");
    try testing.expect(bench.app.picker == null);
    try testing.expectEqualStrings("staging", bench.app.grid.schema.items);
    try bench.says("schema staging");
}

test "a list longer than its panel keeps the cursor in sight and says how many more there are" {
    var bench = try Bench.openWith(BOOKS, .{ .size = .{ .rows = 16, .cols = 80 } });
    defer bench.close();
    var all: [40][]const u8 = undefined;
    var text: [40][8]u8 = undefined;
    for (&all, &text, 0..) |*name, *buffer, n| {
        name.* = std.mem.print(buffer, "ns-{d:0>2}", .{n}) catch unreachable;
    }
    bench.app.picker = try Picker.init(bench.app.allocator, "namespace", &all, 0, .schema);
    try bench.sees("ns-00");
    try bench.lacks("ns-39");
    try bench.sees("more");
    try bench.keys("{pgdn}{pgdn}{pgdn}{pgdn}");
    try bench.sees("ns-39");
    try bench.lacks("ns-00");
    try testing.expectEqualStrings("ns-39", bench.app.picker.?.options[bench.app.picker.?.chosen().?]);
    try bench.keys("{esc}");
    try testing.expect(bench.app.picker == null);
}

//! The forms: what each of them asks, and what is done with the answers.
//!
//! A form is opened by a key, filled in, and submitted with ctrl+s. Most of
//! them come to a statement - a table made or altered, an index, a key, a
//! view, a trigger - which the engine writes and `runBatch` runs, so a failure
//! is reported the way a typed statement's is. The rest change what is on the
//! screen: a row, a filter, which columns show, which schema is open.
//!
//! The widget itself - fields, focus, what a key does inside one - is
//! `form.zig`, and the connection form has a file of its own. These are
//! methods of the App by name; see the aliases there.

const std = @import("std");
const database = @import("db");
const app_mod = @import("app.zig");
const Form = @import("form.zig");
const dump_mod = @import("dump.zig");

const App = app_mod.App;
const OPERATORS = app_mod.OPERATORS;
const isNumeric = app_mod.isNumeric;
const looksNumeric = app_mod.looksNumeric;
const operatorOf = app_mod.operatorOf;
const plural = app_mod.plural;

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
            try App.copyFilters(form.arena.allocator(), key)
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
        var about: std.ArrayList(u8) = .empty;
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
        "ctrl+n adds a column, ctrl+x removes one",
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
    // What the table had when the form opened, which is what a row removed
    // from it is later told by.
    const shown = try form.arena.allocator().alloc([]const u8, columns.len);
    for (columns, shown) |column, *name| {
        name.* = column.original;
    }
    form.shown = shown;
    if (columns.len == 0) {
        // The engine's first type, which is the integer-ish one in every list.
        const first = self.conn.ddl().types();
        try addColumnRow(self, form, 1, .{
            .name = "id",
            .type = if (first.len != 0) first[0] else "INTEGER",
            .pk = true,
        });
        try addColumnRow(self, form, 2, .{ .name = "", .type = "TEXT" });
    } else {
        for (columns, 0..) |column, i| {
            try addColumnRow(self, form, i + 1, column);
        }
    }
}

pub fn addColumnRow(self: *App, form: *Form.Form, group: usize, column: database.Column) !void {
    try form.text("column", column.name, 16);
    form.inGroup(group);
    try form.wasNamed(column.original);
    // The engine's own types, not a list that happens to suit SQLite: MySQL
    // offers `varchar(255)`, PostgreSQL `timestamptz`.
    const types = try withOwnType(form.arena.allocator(), self.conn.ddl().types(), column.type);
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

/// The types a column's row offers: the engine's list, and the column's own
/// type on the end of it where the list does not have that. A list is a
/// handful of the usual ones and a table is whatever somebody declared -
/// `DECIMAL(15,2)`, `varchar(40)` - and a type the form could not show was
/// shown as the first one in the list, and then saved as it: opening the
/// alter form and adding a column changed the type of every column like that.
pub fn withOwnType(arena: std.mem.Allocator, types: []const []const u8, own: []const u8) ![]const []const u8 {
    for (types) |known| {
        if (std.ascii.eqlIgnoreCase(known, own)) {
            return types;
        }
    }
    const offered = try arena.alloc([]const u8, types.len + 1);
    @memcpy(offered[0..types.len], types);
    offered[types.len] = try arena.dupe(u8, own);
    return offered;
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
    try addColumnRow(self, form, highest + 1, .{ .name = "", .type = "TEXT" });
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
    var suggested: std.ArrayList(u8) = .empty;
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
    const targets = try tableNames(self, form.arena.allocator(), table.name);
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
    var suggested: std.ArrayList(u8) = .empty;
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
    var names: std.ArrayList([]const u8) = .empty;
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

/// Column definitions as the DDL generator wants them, including the
/// single-column UNIQUE constraints, which only exist as indexes.
pub fn tableNames(self: *App, arena: std.mem.Allocator, last: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
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

/// Turn the open form into SQL and run it. Everything goes through
/// `runBatch`, so a failure is reported the same way a typed query is.
///
/// Most forms come to a statement, written into `sql` by the engine and run at
/// the end. The ones that come to something else do it and return.
pub fn submitForm(self: *App) !void {
    const form = &(self.typing.form orelse return);
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sql: std.ArrayList(u8) = .empty;
    const schema = self.grid.schema.items;
    // The engine is asked for its words inside the arms that want them and not
    // up here: the connection form is filled in with nothing open, and there
    // is no engine then to ask.

    switch (form.purpose) {
        .row => return submitRow(self, a, form),
        .filter => {
            try applyFilter(self, form);
            self.closeForm();
            return;
        },
        .columns => return hideColumns(self, form),
        .search_all => return submitSearch(self, form),
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
        .connection => try self.saveConnection(form),

        .create_table, .alter_table => try buildTable(self, &sql, a, form),
        // These two say what is wrong with the form and leave it open.
        .index => if (!try indexStatement(self, &sql, a, form)) return,
        .foreign_key => if (!try foreignKeyStatement(self, &sql, a, form)) return,
        .view => try self.conn.ddl().createView(&sql, a, .{ .schema = schema, .name = form.valueOf(0) }, form.valueOf(1)),
        // Written by the engine, like every other statement here. This one
        // was written out in this file instead, the way SQLite takes it - so
        // on SQLite it worked, and PostgreSQL, MySQL and SQL Server were each
        // sent a statement in a dialect that is not theirs, while what they
        // would have written for themselves sat in their drivers unused.
        .trigger => try self.conn.ddl().createTrigger(
            &sql,
            a,
            .{ .schema = schema, .name = form.valueOf(3) },
            form.valueOf(0),
            form.valueOf(1),
            form.valueOf(2),
            form.valueOf(4),
            form.valueOf(5),
        ),
        .rename_table => try self.conn.ddl().renameTable(&sql, a, .{ .schema = schema, .name = form.table }, form.valueOf(0)),
        .copy_table => try self.conn.ddl().copyTable(&sql, a, .{ .schema = schema, .name = form.table }, form.valueOf(0), form.isOn(1)),
    }

    if (sql.items.len == 0) {
        self.closeForm();
        return;
    }
    try runScript(self, form, sql.items);
}

/// The row form: one row put in, or one changed.
fn submitRow(self: *App, a: std.mem.Allocator, form: *Form.Form) !void {
    const request = try rowChange(self, a, form);
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
}

/// The columns form: every box that is not ticked is a column not shown.
fn hideColumns(self: *App, form: *Form.Form) !void {
    self.cursor.hidden.clearRetainingCapacity();
    for (form.fields.items, 0..) |field, i| {
        if (!field.on) {
            try self.cursor.hidden.append(self.allocator, i);
        }
    }
    self.closeForm();
    self.say("{d} column{s} hidden", .{ self.cursor.hidden.items.len, plural(self.cursor.hidden.items.len) });
}

fn submitSearch(self: *App, form: *Form.Form) !void {
    const needle = form.valueOf(0);
    if (needle.len == 0) {
        self.complain("nothing to search for", .{});
        return;
    }
    try searchEverything(self, needle);
    self.closeForm();
}

/// The index form as a statement. False where the form has nothing to make an
/// index of, which has been said.
fn indexStatement(self: *App, sql: *std.ArrayList(u8), a: std.mem.Allocator, form: *Form.Form) !bool {
    var columns: std.ArrayList([]const u8) = .empty;
    var parts = std.mem.tokenizeAny(u8, form.valueOf(1), ",");
    while (parts.next()) |part| {
        try columns.append(a, std.mem.trim(u8, part, " \t"));
    }
    if (columns.items.len == 0) {
        self.complain("name at least one column", .{});
        return false;
    }
    try self.conn.ddl().createIndex(
        sql,
        a,
        .{ .schema = self.grid.schema.items, .name = form.table },
        form.valueOf(0),
        columns.items,
        form.isOn(2),
        form.valueOf(3),
    );
    return true;
}

/// The foreign key form as a statement. False where it names a column the
/// table does not have, which has been said.
fn foreignKeyStatement(self: *App, sql: *std.ArrayList(u8), a: std.mem.Allocator, form: *Form.Form) !bool {
    const columns = try self.columnDefs(a, form.table);
    var known = false;
    for (columns) |column| {
        known = known or std.mem.eql(u8, column.name, form.valueOf(0));
    }
    if (!known) {
        self.complain("{s} has no column {s}", .{ form.table, form.valueOf(0) });
        return false;
    }
    const target = database.Table{ .schema = self.grid.schema.items, .name = form.table };
    // What the engine has to carry across the change: on SQLite the table is
    // written again, and the keys it already has go with it.
    const context = try self.conn.alterContext(a, target, columns);
    try self.conn.ddl().addForeignKey(sql, a, target, .{
        .column = form.valueOf(0),
        .target_table = form.valueOf(1),
        .target_column = form.valueOf(2),
        .on_update = form.valueOf(3),
        .on_delete = form.valueOf(4),
    }, context);
    return true;
}

/// Run the statement a form came to, and then show what it left: the table
/// under its new name, the grid read again, or the reason it failed.
fn runScript(self: *App, form: *Form.Form, sql: []const u8) !void {
    // Everything of the form that is still wanted, copied: it is closed before
    // the statement runs, and its memory goes with it.
    const script = try self.allocator.dupe(u8, sql);
    defer self.allocator.free(script);
    const purpose = form.purpose;
    // What the form says the table is to be called. The name is a field of
    // the alter form as well, so that is the other way to rename - and a
    // rename only where it is not the name the table had.
    const renamed = switch (purpose) {
        .rename_table => try self.allocator.dupe(u8, form.valueOf(0)),
        .alter_table => if (std.mem.eql(u8, form.valueOf(0), form.table))
            null
        else
            try self.allocator.dupe(u8, form.valueOf(0)),
        else => null,
    };
    defer if (renamed) |value| self.allocator.free(value);
    self.closeForm();

    try self.runBatchStopping(script, true);
    try self.loadObjects();
    if (self.report.list.items.len != 0 and self.report.list.items[self.report.list.items.len - 1].failure != null) {
        // The rollback in runBatch has already undone the half done work -
        // inside the transaction. What the script changed before it began
        // one, and never got as far as putting back, is the engine's to say.
        const mend = self.conn.ddl().afterFailure(script);
        if (mend.len != 0) {
            self.conn.exec(mend) catch {
                self.complain("the script failed, and what it had set could not be put back: {s}", .{self.conn.message()});
            };
        }
        // Under the name it had, whatever the form asked for: a rebuild is
        // rolled back whole, and everywhere else the rename is the last
        // statement of the script, so one that stopped never got to it or
        // was refused there.
        self.reload() catch {};
        return;
    }
    // A script that came to no statement renamed nothing, whatever the form
    // said: Kafka takes these two forms and answers each with a comment that
    // says a topic has no such thing, and the name that was typed is then the
    // name of nothing.
    const moved = if (self.report.list.items.len != 0) renamed else null;
    switch (purpose) {
        .rename_table => if (moved) |value| try openRenamed(self, value),
        .create_table, .copy_table, .view => self.say("created", .{}),
        // A table the alter form renamed is opened by its new name, as one
        // renamed under `N` is. Reading it again asked for the old one: the
        // rename had worked, the list said so, and the grid beside it was a
        // table that could not be read.
        .alter_table => if (moved) |value| try openRenamed(self, value) else try self.reload(),
        .foreign_key, .index => try self.reload(),
        else => {},
    }
}

/// Open a table under the name it has just been given, with the cursor in the
/// list on it. The list is in order of name and has been read again, so the
/// place the cursor kept is whatever sorts there now: another table than the
/// one in the grid, and the one enter would open.
fn openRenamed(self: *App, name: []const u8) !void {
    self.selectObject(name);
    try self.openTable(name);
}

/// The row form as a change: which columns it sets, to what, and which row it
/// is about. A number goes in as it stands so the engine sees a number, and a
/// value left empty where the column has a default is left out altogether -
/// which is how a new row gets its own id.
///
/// Everything is copied into `a`, because the form is closed before the change
/// is made and its own memory goes with it.
pub fn rowChange(self: *App, a: std.mem.Allocator, form: *Form.Form) !database.ask.Change {
    const columns = try self.columnDefs(a, form.table);
    var cells: std.ArrayList(database.ask.Cell) = .empty;
    for (columns, 0..) |column, i| {
        const value_field = form.field(i * 2) orelse continue;
        const null_field = form.field(i * 2 + 1) orelse continue;
        const text = value_field.text.items;
        if (null_field.on) {
            try cells.append(a, .{ .column = column.name, .value = null });
            continue;
        }
        if (text.len == 0 and form.key == null and
            (column.dflt != null or (column.pk and std.ascii.findIgnoreCase(column.type, "INT") != null)))
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
        .where = if (form.key) |key| try App.copyFilters(a, key) else &.{},
    };
}

/// CREATE TABLE, or a rebuild when altering.
pub fn buildTable(self: *App, sql: *std.ArrayList(u8), a: std.mem.Allocator, form: *Form.Form) !void {
    const name = form.valueOf(0);
    if (name.len == 0) {
        self.complain("the table needs a name", .{});
        return;
    }
    var columns: std.ArrayList(database.Column) = .empty;
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
    // The name is a field of this form, so altering is also a way to rename
    // - which the connection that is one table refuses under `N`, and has to
    // refuse here for the same reason.
    if (self.caps().no_tables.len != 0 and !std.mem.eql(u8, name, form.table)) {
        self.complain("{s}", .{self.caps().no_tables});
        return;
    }
    // Whatever this engine has to preserve across an alter - on SQLite the
    // foreign keys and the indexes, with the renames applied.
    const target = database.Table{ .schema = self.grid.schema.items, .name = form.table };
    var context = try self.conn.alterContext(a, target, columns.items);
    // A column taken out of the form is one to drop. Only SQLite acted on
    // it, by writing the table again without it; PostgreSQL, MySQL and SQL
    // Server were handed the columns that were left and nothing about the
    // one that was not, so the form closed, said nothing, and the column
    // stayed.
    context.removed = try database.removedColumns(a, form.shown, columns.items);
    try self.conn.ddl().alterTable(sql, a, target, name, columns.items, context);
}

pub fn applyFilter(self: *App, form: *Form.Form) !void {
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
            try self.allocator.print("%{s}%", .{value})
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
        self.say("{d} row{s}", .{ self.grid.total, if (self.grid.total == 1) " matches" else "s match" });
    } else {
        self.say("{d} row{s} on this page; {s} cannot count the rest without reading it", .{
            self.grid.rows.items.len,
            plural(self.grid.rows.items.len),
            self.caps().label,
        });
    }
}

/// Look for a string in every text-ish column of every table.
pub fn searchEverything(self: *App, needle: []const u8) !void {
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
    var sql: std.ArrayList(u8) = .empty;
    var pattern: std.ArrayList(u8) = .empty;
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
            if (std.ascii.findIgnoreCase(column.type, "BLOB") != null) {
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
    self.say("{d} hit{s} in {d} column{s}", .{ self.grid.rows.items.len, plural(self.grid.rows.items.len), parts, plural(parts) });
}

// ------------------------------------------------------------------- tests
//
// On the bench - see bench.zig. Each of these is a form filled in the way a
// person fills it, and then the database asked what became of it: the
// statement a form writes was only ever compared with a statement, and whether
// the engine took it was found out by whoever tried.

const Bench = @import("bench.zig").Bench;
const BOOKS = @import("bench.zig").BOOKS;
const testing = std.testing;

test "a table is made from the form, with the columns it was given" {
    var bench = try Bench.open(BOOKS);
    defer bench.close();
    // The name, then the two columns the form starts with: the first is
    // renamed and left as the key, the second gets a name and NOT NULL.
    try bench.keys("cshelves{tab}{ctrl-u}code{tab}{tab}{tab}{tab}{tab}{ctrl-u}room{tab}{tab}{space}{ctrl-s}");
    try bench.says("created");
    try bench.expectAsked(
        "SELECT name || ':' || type || ':' || \"notnull\" || ':' || pk FROM pragma_table_info('shelves')",
        "code:TEXT:0:1 room:TEXT:1:0",
    );
    // And it is in the list beside the others.
    try bench.sees("shelves");
    try testing.expectEqual(@as(usize, 3), bench.app.sidebar.objects.items.len);
}

test "an alter adds a column and keeps every row" {
    var bench = try Bench.open(BOOKS);
    defer bench.close();
    try bench.keys("j{enter}a{ctrl-n}");
    try bench.keys("pages{ctrl-s}");
    try testing.expect(bench.app.typing.form == null);
    try bench.expectAsked("SELECT name FROM pragma_table_info('books')", "id title year author pages");
    try bench.expectAsked("SELECT title FROM books ORDER BY id", "RUR Krakatit Žert Saturnin");
    // The key it had is the key it has, and it is enforced.
    try bench.expectAsked("SELECT \"table\" || ':' || on_delete FROM pragma_foreign_key_list('books')", "authors:CASCADE");
    try bench.expectAsked("PRAGMA foreign_keys", "1");
    // The grid is the table as it is now.
    try bench.sees("pages");
}

test "a table that has a trigger is altered, and the trigger still fires" {
    var bench = try Bench.open(BOOKS ++
        \\CREATE TABLE log (what TEXT);
        \\CREATE TRIGGER noted AFTER INSERT ON books BEGIN INSERT INTO log VALUES (NEW.title); END;
    );
    defer bench.close();
    try bench.keys("j{enter}a{ctrl-n}pages{ctrl-s}");
    try bench.lacks("failed");
    try bench.expectAsked("SELECT name FROM pragma_table_info('books')", "id title year author pages");
    try bench.app.conn.exec("INSERT INTO books (title) VALUES ('Povětroň')");
    try bench.expectAsked("SELECT what FROM log", "Povětroň");
}

test "an alter that fails takes nothing with it, and leaves the keys enforced" {
    var bench = try Bench.open(BOOKS ++ "INSERT INTO books (id, title, year, author) VALUES (9, 'undated', NULL, 1);");
    defer bench.close();
    // NOT NULL on a column one row has nothing in: the thirteenth field.
    try bench.keys("j{enter}a");
    try bench.repeat("{tab}", 13);
    try bench.keys("{space}{ctrl-s}");
    try bench.says("failed");
    try bench.says("rolled back");
    try bench.expectAsked("SELECT count(*) FROM books", "5");
    try bench.expectAsked("SELECT \"notnull\" FROM pragma_table_info('books') WHERE name = 'year'", "0");
    try bench.expectAsked("SELECT count(*) FROM sqlite_master WHERE name = 'krtek_rebuild'", "0");
    // The script turned them off at its first line and never reached its last.
    try bench.expectAsked("PRAGMA foreign_keys", "1");
    try testing.expectError(error.Driver, bench.app.conn.exec("INSERT INTO books (title, author) VALUES ('orphan', 99)"));
    // What failed, and why, is a key away.
    try bench.keys("gm");
    try bench.sees("NOT NULL constraint failed");
}

test "a table renamed in the alter form is read by its new name" {
    var bench = try Bench.open(BOOKS);
    defer bench.close();
    // The name is the form's first field, and the cursor starts in it. The grid
    // went on asking for the old one: the rename worked, the list said so, and
    // beside it was `no such table: books` over a table that could not be read.
    try bench.keys("j{enter}a{ctrl-u}novels{ctrl-s}");
    try testing.expect(bench.app.typing.form == null);
    try bench.expectAsked("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name", "authors novels");
    try bench.sees("novels  1-4 of 4");
    try bench.sees("Saturnin");
    try bench.lacks("could not be read");
    try testing.expect(!bench.app.report.status_error);
    // And it is that table from here on, which is what `r` reads again.
    try bench.keys("r");
    try bench.sees("novels  1-4 of 4");

    // A name that is taken is refused, with the rebuild rolled back - so the
    // table is still where it was, and that is where the grid looks.
    try bench.keys("a{ctrl-u}authors{ctrl-s}");
    try bench.says("failed");
    try bench.expectAsked("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name", "authors novels");
    try bench.sees("novels  1-4 of 4");
    try bench.lacks("could not be read");

    // Altered under the name it has, it is read again where it was.
    try bench.keys("jj");
    try bench.keys("a{ctrl-n}pages{ctrl-s}");
    try bench.lacks("failed");
    try bench.sees("novels  1-4 of 4");
    try bench.sees("pages");
    try testing.expectEqual(@as(usize, 2), bench.app.cursor.row);
}

test "the cursor in the list follows a table to where its new name sorts" {
    // The list is read again after a rename, sorted by name, and the cursor
    // kept the place it had: `books` renamed to sort above `authors` left it
    // on `authors`, beside a grid of the other table, and enter opened that.
    for ([_][]const u8{ "a", "gN" }) |key| {
        var bench = try Bench.open(BOOKS);
        defer bench.close();
        try bench.keys("j{enter}");
        try bench.keys(key);
        try bench.keys("{ctrl-u}aaa{ctrl-s}");
        try bench.sees("aaa  1-4 of 4");
        try testing.expectEqual(@as(usize, 0), bench.app.sidebar.selected);
        try testing.expectEqualStrings("aaa", bench.app.current().?.name);
        // And down the list as well as up it.
        try bench.keys(key);
        try bench.keys("{ctrl-u}zzz{ctrl-s}");
        try bench.sees("zzz  1-4 of 4");
        try testing.expectEqual(@as(usize, 1), bench.app.sidebar.selected);
        try testing.expectEqualStrings("zzz", bench.app.current().?.name);
        // So enter in the list, a step left of the grid's first column, opens
        // the table that was already open.
        try bench.keys("h{enter}");
        try testing.expect(bench.app.typing.form == null);
        try bench.sees("zzz  1-4 of 4");

        // A rename that is refused moved nothing, and neither does the cursor.
        try bench.keys(key);
        try bench.keys("{ctrl-u}authors{ctrl-s}");
        try bench.says("already another table");
        try testing.expectEqualStrings("zzz", bench.app.current().?.name);
    }
}

test "the cursor follows a renamed table among what the filter leaves showing" {
    for ([_][]const u8{ "a", "gN" }) |key| {
        var bench = try Bench.open(BOOKS ++ "CREATE TABLE boxes (id INTEGER PRIMARY KEY);");
        defer bench.close();
        // `authors` is out of the list and still in front of the other two, so
        // a place in what is showing is not a place in the whole of it. Enter
        // on what was typed after `/` opens the first of what is left.
        try bench.keys("/bo{enter}");
        try bench.sees("books  1-4 of 4");
        try testing.expectEqual(@as(usize, 2), bench.app.visibleCount());
        try bench.keys(key);
        try bench.keys("{ctrl-u}bozo{ctrl-s}");
        try bench.sees("bozo  1-4 of 4");
        try testing.expectEqual(@as(usize, 1), bench.app.sidebar.selected);
        try testing.expectEqualStrings("bozo", bench.app.current().?.name);

        // Renamed to what the filter hides, it is in the list no longer. The
        // cursor stays on what is, as it does when a table is dropped.
        try bench.keys(key);
        try bench.keys("{ctrl-u}zzz{ctrl-s}");
        try bench.sees("zzz  1-4 of 4");
        try testing.expectEqual(@as(usize, 1), bench.app.visibleCount());
        try testing.expectEqual(@as(usize, 0), bench.app.sidebar.selected);
        try testing.expectEqualStrings("boxes", bench.app.current().?.name);
    }
}

test "the list scrolls to a renamed table that sorts off the screen" {
    // Forty tables in a list with room for a dozen.
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(testing.allocator);
    for (0..40) |n| {
        try sql.print(testing.allocator, "CREATE TABLE t{d:0>2} (id INTEGER PRIMARY KEY);", .{n});
    }
    for ([_][]const u8{ "a", "gN" }) |key| {
        var bench = try Bench.openWith(sql.items, .{ .size = .{ .rows = 16, .cols = 100 } });
        defer bench.close();
        try bench.lacks("t39");
        try bench.keys("{enter}");
        try bench.keys(key);
        try bench.keys("{ctrl-u}zebra{ctrl-s}");
        try testing.expectEqual(@as(usize, 39), bench.app.sidebar.selected);
        try testing.expectEqualStrings("zebra", bench.app.current().?.name);
        try testing.expect(bench.app.sidebar.scroll != 0);
        try testing.expect(bench.app.sidebar.selected < bench.app.sidebar.scroll + bench.app.sidebar.shown);
        try bench.sees("t39");
        try bench.lacks("t00");
        // And back to the top of it.
        try bench.keys(key);
        try bench.keys("{ctrl-u}aardvark{ctrl-s}");
        try testing.expectEqual(@as(usize, 0), bench.app.sidebar.selected);
        try testing.expectEqual(@as(usize, 0), bench.app.sidebar.scroll);
        try bench.sees("t01");
        try bench.lacks("t39");
    }
}

test "the trigger form makes a trigger, and it fires" {
    var bench = try Bench.open(BOOKS ++ "CREATE TABLE log (what TEXT);");
    defer bench.close();
    // Name, when, event, table, condition, body: the table is the one that is
    // open, and the two choices are left at AFTER and INSERT.
    try bench.keys("j{enter}Tnoted{tab}{tab}{tab}{tab}NEW.year > 1900{tab}");
    try bench.typed("INSERT INTO log VALUES (NEW.title); INSERT INTO log VALUES ('twice')");
    try bench.keys("{ctrl-s}");
    try bench.says("1 statement, 0 rows affected");
    try bench.app.conn.exec("INSERT INTO books (title, year) VALUES ('new', 2000), ('old', 1800)");
    try bench.expectAsked("SELECT what FROM log", "new twice");
}

test "an index is made from the form, on the column the cursor was in" {
    var bench = try Bench.open(BOOKS);
    defer bench.close();
    try bench.keys("j{enter}llI");
    try bench.sees("create index");
    // Named after the table and offered on the column under the cursor.
    try bench.keys("{ctrl-s}");
    try bench.expectAsked("SELECT name FROM pragma_index_list('books')", "books_idx");
    try bench.expectAsked("SELECT name FROM pragma_index_info('books_idx')", "year");
}

test "the filter form narrows the rows to what was asked for, and W again shows what" {
    var bench = try Bench.open(BOOKS);
    defer bench.close();
    // The raw condition is the tenth field, after three of column, operator
    // and value.
    try bench.keys("j{enter}W");
    try bench.repeat("{tab}", 9);
    try bench.typed("year < 1930");
    try bench.keys("{ctrl-s}");
    try testing.expectEqual(@as(usize, 2), bench.app.grid.rows.items.len);
    try bench.sees("1-2 of 2");
    try bench.lacks("Saturnin");
    // Counting is of what matches, and sorting keeps the filter.
    try bench.keys("llo");
    try testing.expectEqual(@as(usize, 2), bench.app.grid.rows.items.len);
    try testing.expectEqualStrings("RUR", bench.app.grid.rows.items[0].cells[1].text);
}

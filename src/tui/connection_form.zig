//! The form a connection is added or edited in, and what it comes to.
//!
//! It is the one form whose fields depend on an answer inside it: the engine
//! at its top decides what is asked under it, so choosing another builds the
//! rest again and keeps whatever was typed that the new one also asks for.
//! What it comes to is a target put together from those fields, an entry in
//! the list, the password kept wherever the form said - and then a connection
//! made with it.
//!
//! The list itself, and where a password lives, are `connections.zig`. These
//! are methods of the App by name; see the aliases there.

const std = @import("std");
const database = @import("db");
const app_mod = @import("app.zig");
const Form = @import("form.zig");
const conns = @import("connections.zig");
const keychain = @import("keychain.zig");
const biometry = @import("biometry.zig");

const App = app_mod.App;

/// Where a connection can keep its password, in the order the form offers them.
pub const PLACES = [_][]const u8{ "ask", "file", "keychain", "touchid" };

/// What the Kafka form offers. The empty one is no SASL at all, which is what a
/// broker on a private network wants.
pub const MECHANISMS = [_][]const u8{ "", "PLAIN", "SCRAM-SHA-256", "SCRAM-SHA-512" };

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
    const shape = conns.decompose(formArena(self), target) orelse conns.Shape{
        .engine = if (target.len == 0) .sqlite else .other,
        .path = target,
    };
    try showConnectionForm(self, shape, name, keeps, secret, read_only);
}

/// An arena that outlives the form: the connection form is built again every
/// time the engine changes, and what was typed has to survive that.
pub fn formArena(self: *App) std.mem.Allocator {
    return self.typing.arena.allocator();
}

/// Build the form for one engine: its name and the engine at the top, what
/// that engine needs to be reached under them, and then what is asked of every
/// connection - whether it may be written through, and where its password is
/// kept.
pub fn showConnectionForm(self: *App, shape: conns.Shape, name: []const u8, keeps: conns.Keeps, secret: []const u8, read_only: bool) !void {
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
        .csv => {
            try form.text("file", shape.path, 52);
            try form.note("a path to a .csv or .tsv file whose first line names the columns;");
            try form.note("it is opened as one table, and written when a row or a column changes");
        },
        .other => {
            try form.text("target", shape.path, 52);
            try form.note("anything the engines take, as it stands - a libpq keyword string,");
            try form.note("a scheme with a spelling of its own, a query this form does not know");
        },
        .postgres, .mysql, .mssql => try serverFields(form, shape),
        .redis => try redisFields(form, shape),
        .kafka => try kafkaFields(form, shape),
        .s3 => try s3Fields(form, shape),
        .azure => try azureFields(form, shape),
        .sftp => try sftpFields(form, shape),
        .rabbit => try rabbitFields(form, shape),
        .mqtt => try mqttFields(form, shape),
        .k8s => try clusterFields(form, shape),
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
    // keep something nothing will ever ask for. Nor has a file of rows.
    if (shape.engine == .k8s or shape.engine == .csv) {
        return;
    }
    try passwordFields(form, keeps, secret);
}

// What each engine needs to be reached. One function an engine rather than
// one switch of a hundred and twenty lines: the order of the fields is the
// order they are drawn in and tabbed through, and it is easier to see that it
// is right twelve lines at a time.

fn serverFields(form: *Form.Form, shape: conns.Shape) !void {
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
}

fn redisFields(form: *Form.Form, shape: conns.Shape) !void {
    try form.text("host", shape.host, 24);
    try form.text("port", shape.port, 6);
    form.sameLine();
    try form.text("database", shape.name, 6);
    try form.toggle("TLS", shape.tls);
    form.sameLine();
    try form.note("the database is Redis's numbered one: 0 unless you know otherwise");
}

fn kafkaFields(form: *Form.Form, shape: conns.Shape) !void {
    try form.text("host", shape.host, 24);
    try form.text("port", shape.port, 6);
    form.sameLine();
    try form.text("user", shape.user, 24);
    try form.choice("mechanism", &MECHANISMS, Form.indexOf(&MECHANISMS, shape.mechanism));
    form.sameLine();
    try form.toggle("TLS", shape.tls);
    try form.note("a user with no mechanism named is PLAIN, which is what brokers are set up for");
}

fn s3Fields(form: *Form.Form, shape: conns.Shape) !void {
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
}

fn azureFields(form: *Form.Form, shape: conns.Shape) !void {
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
}

fn sftpFields(form: *Form.Form, shape: conns.Shape) !void {
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
}

fn rabbitFields(form: *Form.Form, shape: conns.Shape) !void {
    try form.text("host", shape.host, 24);
    try form.text("port", shape.port, 6);
    form.sameLine();
    try form.text("vhost", shape.name, 24);
    try form.text("user", shape.user, 24);
    try form.toggle("TLS", shape.tls);
    form.sameLine();
    try form.note("the port is the management one, 15672, and not the broker's 5672;");
    try form.note("the default vhost is written %2F");
}

fn mqttFields(form: *Form.Form, shape: conns.Shape) !void {
    try form.text("host", shape.host, 24);
    try form.text("port", shape.port, 6);
    form.sameLine();
    try form.text("user", shape.user, 24);
    try form.text("filter", shape.name, 32);
    try form.toggle("TLS", shape.tls);
    form.sameLine();
    try form.note("the filter is what to listen to: empty is everything, dum/# all of");
    try form.note("one branch, dum/+/teplota one level of any name. A broker with a");
    try form.note("great deal going through it is better looked at a branch at a time.");
}

fn clusterFields(form: *Form.Form, shape: conns.Shape) !void {
    try form.text("context", shape.host, 32);
    try form.text("namespace", shape.name, 24);
    try form.text("kubeconfig", shape.key, 32);
    try form.toggle("check the certificate", !shape.insecure);
    try form.note("everything else is in the kubeconfig: empty means its current context,");
    try form.note("and an empty file means $KUBECONFIG and then ~/.kube/config. There is");
    try form.note("no password here - a cluster is reached the way kubectl reaches it.");
}

/// Where the password is kept, and the password. Only what this machine has
/// is offered: the keychain is macOS's, and the reader is not on every Mac.
fn passwordFields(form: *Form.Form, keeps: conns.Keeps, secret: []const u8) !void {
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
    var shape = shapeOf(self, form);
    shape.engine = picked;
    // Encryption is the new engine's default, not whatever the last one had:
    // off on a broker inside a network, on for a bucket on the internet.
    shape.tls = picked == .s3;
    const name = try formArena(self).dupe(u8, form.valueNamed("name"));
    const secret = try formArena(self).dupe(u8, form.valueNamed("password"));
    const keeps = std.meta.stringToEnum(conns.Keeps, form.valueNamed("keep the password")) orelse .ask;
    const read_only = form.isOnNamed("read-only");
    try showConnectionForm(self, shape, name, keeps, secret, read_only);
    // Back on the engine, so it can be cycled again without walking up to it.
    self.typing.form.?.cursor = 1;
}

/// What the fields of the connection form say, whichever engine they are for.
pub fn shapeOf(self: *App, form: *Form.Form) conns.Shape {
    const arena = formArena(self);
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
        .{ .label = "filter", .into = &shape.name },
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

/// What the connection form came to: a target built out of its fields, an
/// entry in the list, the password put wherever it said, and then a
/// connection made with it.
///
/// Its own function because it was a third of `submitForm` on its own, and
/// the only arm of that switch doing anything but writing a statement.
pub fn saveConnection(self: *App, form: *Form.Form) !void {
    const name = try self.allocator.dupe(u8, form.valueNamed("name"));
    defer self.allocator.free(name);
    // The fields are that engine's; the target is what they come to.
    const shape = shapeOf(self, form);
    const target = conns.compose(formArena(self), shape) catch "";
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
    // Which of the two kinds of file a path is, is read off its name - so a
    // CSV saved under another one would be opened as a database, and fail
    // as one, with nothing to say why.
    if (shape.engine == .csv and !conns.isSheet(target)) {
        self.complain("a CSV file is known by its name: {s} has to end in .csv or .tsv", .{target});
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
    // Said by `enter` once there is a connection, and by the list itself
    // where there is not: either of them comes after this and is what is on
    // the screen by the time anybody reads it.
    _ = self.writeList(.asked);
    self.saved.at = 0;
    // Connect with whatever was typed here, whether or not it is kept.
    const attempt = if (typed.len != 0)
        try conns.withPassword(scratch.allocator(), clean, typed)
    else
        target;
    try self.connect(attempt, false);
    return;
}

// ------------------------------------------------------------------- tests
//
// On the bench - see bench.zig. Never with a password kept anywhere but
// nowhere: `keychain` on this form is the real keychain.

const Bench = @import("bench.zig").Bench;
const BOOKS = @import("bench.zig").BOOKS;
const testing = std.testing;

/// The labels of everything on the form that can be typed into or switched, in
/// the order tab goes through them, joined with a comma.
fn asked(form: *Form.Form, buffer: []u8) []const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    for (form.fields.items) |field| {
        if (!field.editable()) {
            continue;
        }
        if (writer.buffered().len != 0) {
            writer.writeAll(",") catch break;
        }
        writer.writeAll(field.label) catch break;
    }
    return writer.buffered();
}

test "each engine is asked for what it needs, in the order it is tabbed through" {
    var bench = try Bench.openWith(BOOKS, .{ .on_list = true });
    defer bench.close();
    const wanted = [_]struct { conns.Engine, []const u8 }{
        .{ .sqlite, "name,engine,file,read-only" },
        .{ .csv, "name,engine,file,read-only" },
        .{ .other, "name,engine,target,read-only" },
        .{ .postgres, "name,engine,host,port,database,user,read-only" },
        .{ .mysql, "name,engine,host,port,database,user,read-only" },
        .{ .mssql, "name,engine,host,port,database,user,read-only" },
        .{ .redis, "name,engine,host,port,database,TLS,read-only" },
        .{ .kafka, "name,engine,host,port,user,mechanism,TLS,read-only" },
        .{ .s3, "name,engine,bucket,region,endpoint,port,access key,TLS,read-only" },
        .{ .azure, "name,engine,account,container,endpoint,port,TLS,read-only" },
        .{ .sftp, "name,engine,host,port,user,directory,key file,check the host key,read-only" },
        .{ .rabbit, "name,engine,host,port,vhost,user,TLS,read-only" },
        .{ .mqtt, "name,engine,host,port,user,filter,TLS,read-only" },
        .{ .k8s, "name,engine,context,namespace,kubeconfig,check the certificate,read-only" },
    };
    for (wanted) |entry| {
        try showConnectionForm(&bench.app, .{ .engine = entry[0] }, "", .ask, "", false);
        var buffer: [256]u8 = undefined;
        const fields = asked(&bench.app.typing.form.?, &buffer);
        // A cluster and a file of rows have no password to keep: everything
        // else ends with where to keep one, and the password.
        const no_password = entry[0] == .k8s or entry[0] == .csv;
        var whole: [256]u8 = undefined;
        const expected = if (no_password)
            entry[1]
        else
            try std.fmt.bufPrint(&whole, "{s},keep the password,password", .{entry[1]});
        try testing.expectEqualStrings(expected, fields);
        // The engine the form says it is for is the one it was built for.
        try testing.expectEqualStrings(entry[0].label(), bench.app.typing.form.?.valueNamed("engine"));
    }
}

test "a saved connection is taken apart into its fields, and choosing another engine keeps what both ask" {
    var bench = try Bench.openWith(BOOKS, .{
        .on_list = true,
        .connections = "shop\tpostgres://app@db.example:5433/orders\tread-only\n",
    });
    defer bench.close();
    try bench.keys("e");
    const form = &bench.app.typing.form.?;
    try bench.sees("edit connection");
    try testing.expectEqualStrings("shop", form.valueNamed("name"));
    try testing.expectEqualStrings("PostgreSQL", form.valueNamed("engine"));
    try testing.expectEqualStrings("db.example", form.valueNamed("host"));
    try testing.expectEqualStrings("5433", form.valueNamed("port"));
    try testing.expectEqualStrings("orders", form.valueNamed("database"));
    try testing.expectEqualStrings("app", form.valueNamed("user"));
    try testing.expect(form.isOnNamed("read-only"));

    // On to the engine and one to the right: MySQL asks for the same four
    // things, and has them without anybody typing them again.
    try bench.keys("{tab}{right}");
    const rebuilt = &bench.app.typing.form.?;
    try testing.expectEqualStrings("MySQL", rebuilt.valueNamed("engine"));
    try testing.expectEqualStrings("db.example", rebuilt.valueNamed("host"));
    try testing.expectEqualStrings("orders", rebuilt.valueNamed("database"));
    try testing.expectEqualStrings("shop", rebuilt.valueNamed("name"));
    try testing.expect(rebuilt.isOnNamed("read-only"));
    // And the cursor is still on the engine, to be turned again.
    try testing.expectEqual(@as(usize, 1), rebuilt.cursor);

    // Escape changes nothing in the list.
    try bench.keys("{esc}");
    try testing.expectEqualStrings("postgres://app@db.example:5433/orders", bench.app.saved.list.items.items[0].target);
}

test "a connection added in the form is in the list and its file, and is the one that opens" {
    var bench = try Bench.openWith(BOOKS, .{ .on_list = true });
    defer bench.close();
    try bench.says("no saved connections yet");
    try bench.keys("alibrary{tab}{tab}");
    try bench.typed(bench.file);
    try bench.keys("{ctrl-s}");

    try testing.expect(bench.app.connected);
    try bench.sees("authors  1-3 of 3");
    try testing.expectEqualStrings("library", bench.app.saved.list.items.items[0].name);
    try testing.expect(!bench.app.saved.unwritten);

    // The file says so too: the name, a tab, the target, and no password.
    const path = try testing.allocator.dupeSentinel(u8, bench.app.saved.path.items, 0);
    defer testing.allocator.free(path);
    const file = std.c.fopen(path, "rb") orelse return error.TestUnexpectedResult;
    defer _ = std.c.fclose(file);
    var text: [2048]u8 = undefined;
    const read = text[0..std.c.fread(&text, 1, text.len, file)];
    var line: [512]u8 = undefined;
    const entry = try std.fmt.bufPrint(&line, "library\t{s}\n", .{bench.file});
    try testing.expect(std.mem.endsWith(u8, read, entry));

    // A form with nothing to point at says so, and saves nothing.
    try bench.keys("Oanowhere{ctrl-s}");
    try testing.expect(bench.app.report.status_error);
    try bench.says("needs something to point at");
    try testing.expectEqual(@as(usize, 1), bench.app.saved.list.items.items.len);
}

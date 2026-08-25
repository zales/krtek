//! krtek - a database manager for the terminal.
//!
//! A SQLite file is opened through SQLite's own unix VFS: edits are written
//! straight to disk, the database is never held in memory, and so there is no
//! size ceiling and nothing to save. PostgreSQL goes through libpq.

const std = @import("std");
const build = @import("build");
const vaxis = @import("vaxis");
const term = @import("term.zig");
const app_mod = @import("app.zig");
const draw = @import("draw.zig");
const input = @import("input.zig");
const biometry = @import("biometry.zig");

/// Put the terminal back before saying anything.
///
/// A panic does not unwind, so nothing that was deferred runs - and this program
/// spends its life on the alternate screen with the keyboard in a mode of its own
/// and mouse reporting on. Without this a panic leaves the terminal in that state
/// and writes its message underneath a drawing nobody can scroll away from, which
/// is the same as not saying anything at all.
///
/// libvaxis carries a handler of its own, but its signature is one Zig ago -
/// three parameters where 0.16 passes two - so what is used here is the part of
/// it that matters, which is the sequence that puts the terminal back.
pub const panic = std.debug.FullPanic(atPanic);

fn atPanic(message: []const u8, first_trace_address: ?usize) noreturn {
    vaxis.recover();
    std.debug.defaultPanic(message, first_trace_address);
}

const usage =
    \\krtek - a database manager for the terminal
    \\
    \\usage: krtek [database.db]
    \\       krtek postgres://user@host:port/database
    \\       krtek mysql://user@host:port/database
    \\       krtek mssql://user@host:port/database
    \\       krtek redis://host:port/index
    \\       krtek kafka://host:port
    \\       krtek kafka+ssl://user@host:port?mechanism=SCRAM-SHA-256
    \\       krtek s3://bucket
    \\       krtek s3+http://key:secret@localhost:9000/bucket
    \\       krtek azure://account:key@container
    \\       krtek rabbit://guest@host:15672/vhost
    \\       krtek sftp://user@host/srv/data
    \\       krtek k8s://                  the current kubeconfig context
    \\       krtek k8s://prod/payments     a context, and a namespace in it
    \\       krtek "host=... dbname=... user=..."
    \\
    \\With no argument it opens the list of saved connections.
    \\A SQLite file is opened in place and edits go straight to it.
    \\A password is asked for when the server wants one, and kept only where the
    \\connection says: nowhere, the config file, or the macOS keychain. An engine's
    \\own store - PGPASSWORD, ~/.pgpass, ~/.my.cnf - works as it always did.
    \\Press ? inside the app for the key map.
    \\
    \\-v, --version   what this build calls itself
    \\
;

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 1 and (std.mem.eql(u8, args[1], "-v") or std.mem.eql(u8, args[1], "--version"))) {
        var line: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&line, "krtek {s}\n", .{build.version}) catch "krtek\n";
        std.Io.File.stdout().writeStreamingAll(init.io, text) catch {};
        return;
    }
    if (args.len > 1 and (std.mem.eql(u8, args[1], "-h") or std.mem.eql(u8, args[1], "--help"))) {
        // Asked-for output goes to stdout, so `krtek --help | grep` works and so
        // does anything that reads it - the Homebrew formula's test, for one.
        std.Io.File.stdout().writeStreamingAll(init.io, usage) catch {};
        return;
    }
    // Asked once, before anything is drawn: whether this machine has a reader
    // with a finger on it cannot change while the program runs, and the answer
    // decides whether the connection form offers to use one.
    biometry.detect();

    // No argument is not an error: the app opens its list of connections.
    const target = if (args.len > 1) args[1] else "";

    // init already explained itself on stderr; a stack trace would only be noise.
    var app = app_mod.App.init(allocator, target, init.io, init.environ_map) catch std.process.exit(1);
    defer app.deinit();
    // Now that the App is at its final address, let the drivers call back into it
    // while a statement runs.
    app.watchStatements();

    var keys: std.ArrayListUnmanaged(term.Key) = .empty;
    defer keys.deinit(allocator);

    try draw.frame(&app, app.screen.size());
    while (!app.quit) {
        // Blocks until something happens; a resize arrives as an event, so
        // there is no polling and no signal handler.
        try app.screen.keys(&keys);
        const size = app.screen.size();
        for (keys.items) |key| {
            input.handle(&app, key, size) catch |err| {
                // What the engine said, if it said anything: "Driver" on the status
                // line tells nobody anything.
                const said = app.conn.message();
                if (said.len != 0) {
                    app.complain("{s}", .{said});
                } else {
                    app.complain("{s}", .{@errorName(err)});
                }
            };
        }
        try draw.frame(&app, size);
    }
}

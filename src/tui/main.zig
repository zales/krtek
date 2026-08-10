//! krtek - a database manager for the terminal.
//!
//! A SQLite file is opened through SQLite's own unix VFS: edits are written
//! straight to disk, the database is never held in memory, and so there is no
//! size ceiling and nothing to save. PostgreSQL goes through libpq.

const std = @import("std");
const term = @import("term.zig");
const app_mod = @import("app.zig");
const draw = @import("draw.zig");
const input = @import("input.zig");

const usage =
	\\krtek - a database manager for the terminal
	\\
	\\usage: krtek [database.db]
	\\       krtek postgres://user@host:port/database
	\\       krtek mysql://user@host:port/database
	\\       krtek redis://host:port/index
	\\       krtek kafka://host:port
	\\       krtek kafka+ssl://user@host:port?mechanism=SCRAM-SHA-256
	\\       krtek "host=... dbname=... user=..."
	\\
	\\With no argument it opens the list of saved connections.
	\\A SQLite file is opened in place and edits go straight to it.
	\\A password is asked for when the server wants one, and kept only where the
	\\connection says: nowhere, the config file, or the macOS keychain. An engine's
	\\own store - PGPASSWORD, ~/.pgpass, ~/.my.cnf - works as it always did.
	\\Press ? inside the app for the key map.
	\\
;

pub fn main(init: std.process.Init) !void {
	const allocator = std.heap.c_allocator;
	const args = try init.minimal.args.toSlice(init.arena.allocator());
	if (args.len > 1 and (std.mem.eql(u8, args[1], "-h") or std.mem.eql(u8, args[1], "--help"))) {
		// Asked-for output goes to stdout, so `krtek --help | grep` works and so
		// does anything that reads it - the Homebrew formula's test, for one.
		std.Io.File.stdout().writeStreamingAll(init.io, usage) catch {};
		return;
	}
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

//! What the program does with the two panes: opening them, copying between
//! them, and the three things that change the place a pane is looking at.
//!
//! The panes themselves - what is listed, what is chosen, where each is - are
//! `files.zig`. This is the part that needs the rest of the program: the
//! connection the far pane belongs to, whether it may be written through, the
//! prompt that asks before something is written over, and the line that says
//! what happened. They are methods of the App by name; see the aliases there.

const std = @import("std");
const database = @import("db");
const app_mod = @import("app.zig");
const Files = @import("files.zig");

const App = app_mod.App;
const C = app_mod.C;
const monotonicMs = app_mod.monotonicMs;

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

/// Whether this pane may be written into. A read-only connection is about the
/// place it opened, not about the machine krtek runs on: copying a file *down*
/// from a read-only bucket is a read, and there is no reason to refuse it.
pub fn mayWriteTo(self: *App, place: database.store.Store) bool {
    if (!self.read_only or place == .local) {
        return true;
    }
    self.complain("this connection is read-only: {s} is not written to", .{place.label()});
    return false;
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
        try askOverwrite(self, over, first);
        return;
    }
    try self.copyChosen();
}

pub fn askOverwrite(self: *App, over: usize, first: []const u8) !void {
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
pub fn copyStep(context: *anyopaque, name: []const u8, done: u64, whole: u64) bool {
    const self: *App = @ptrCast(@alignCast(context));
    const now = monotonicMs();
    if (now - self.running.copy_ticked < 90) {
        return !self.running.cancelled;
    }
    self.running.copy_ticked = now;
    if (self.screen.interrupted()) {
        self.running.cancelled = true;
    }
    drawCopying(self, name, done, whole);
    return !self.running.cancelled;
}

pub fn drawCopying(self: *App, name: []const u8, done: u64, whole: u64) void {
    const size = self.screen.size();
    var moved: [16]u8 = undefined;
    var all: [16]u8 = undefined;
    var line: [256]u8 = undefined;
    const text = std.mem.print(&line, " copying {s} - {s} of {s}   ctrl+c stops it", .{
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

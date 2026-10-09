//! Opening a connection in a way that can be watched and given up on.
//!
//! A connection used to be opened on the thread that runs the program, which
//! meant a minute of a screen that said nothing whenever an address did not
//! answer. So the call is made on a thread of its own (`Attempt`), a second
//! one keeps a panel on the screen meanwhile and listens for esc
//! (`Attendant`), and what the two say to each other is the sentence on that
//! panel and whether anybody is still waiting (`Connecting`).
//!
//! What a connection is once it is open - reading what is in it, becoming the
//! tab's own - is the App's, in `app.zig`. The functions here are methods of
//! the App by name; see the aliases there.

const std = @import("std");
const database = @import("db");
const app_mod = @import("app.zig");
const draw = @import("draw.zig");

const App = app_mod.App;
const Tab = app_mod.Tab;
const monotonicMs = app_mod.monotonicMs;
const testing = std.testing;

/// The spinner, one frame per tick.
pub const SPINNER = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

/// A connection being opened, for as long as somebody is waiting for it: what
/// the panel in the middle of the screen says.
pub const Connecting = struct {
    started: f64,
    /// The target without its password.
    what: []const u8,
    /// What is being done about it right now. Said by the thread doing it and
    /// read by the one drawing, which are never the same thread.
    stage: database.Stage = .{},
    frame: usize = 0,
    /// Esc, or ctrl+c: nothing that is still to come is wanted any more. Kept
    /// here rather than with the statement's own flag, because what follows a
    /// connection is several statements and each of them starts that one clean.
    given_up: std.atomic.Value(bool) = .init(false),
};

/// The thread that stays with the screen while a connection is being opened: it
/// draws the panel, moves its spinner, and listens for esc.
///
/// The thread that usually does those things is the one doing the opening, and
/// not all of that can be interrupted to draw. The call that connects has a
/// thread of its own for that reason - see `Attempt` - but what comes after it,
/// reading what the connection holds, works on the App itself and has to stay
/// where the App is used; and the SQL drivers read their catalogs with calls
/// that do not come back until the server has answered. So the screen is lent
/// out instead: from `start` to `stop` nothing else draws or reads a key, and
/// all that passes between the two threads is the sentence on the panel and
/// whether esc was pressed.
pub const Attendant = struct {
    thread: ?std.Thread = null,
    /// Written to when it is time to stop, so that stopping does not have to
    /// wait out a tick.
    wake: [2]std.c.fd_t = .{ -1, -1 },

    /// A panel that cannot be had is not worth failing a connection over: with
    /// no thread there is simply nothing drawn, as there never used to be.
    pub fn start(app: *App) Attendant {
        var self = Attendant{};
        if (std.c.pipe(&self.wake) != 0) {
            return .{};
        }
        self.thread = std.Thread.spawn(.{}, run, .{ app, self.wake[0] }) catch {
            self.close();
            return .{};
        };
        return self;
    }

    fn run(app: *App, wake: std.c.fd_t) void {
        if (app.connecting == null) {
            return;
        }
        // The one in the App, not a copy of it: the flag and the sentence are
        // what the two threads share.
        const state = &app.connecting.?;
        while (true) {
            var fds = [1]std.c.pollfd{.{ .fd = wake, .events = std.c.POLL.IN, .revents = 0 }};
            const ready = std.c.poll(&fds, 1, 80);
            if (ready < 0 and std.c._errno().* == @backingInt(std.c.E.INTR)) {
                continue;
            }
            if (ready != 0) {
                return;
            }
            if (!state.given_up.load(.acquire) and app.screen.dismissed()) {
                state.given_up.store(true, .release);
            }
            showConnecting(app);
        }
    }

    /// Give the screen back. Safe to call twice: every way out of a connect
    /// stops it, and some of them have already done so.
    pub fn stop(self: *Attendant) void {
        const thread = self.thread orelse return;
        _ = std.c.write(self.wake[1], "!", 1);
        thread.join();
        self.thread = null;
        self.close();
    }

    fn close(self: *Attendant) void {
        for (self.wake) |end| {
            _ = std.c.close(end);
        }
    }
};

/// One attempt at opening a connection, made on a thread of its own.
///
/// `Db.open` cannot be asked whether to carry on. A name being looked up and an
/// address that does not answer are each one call into the system, which comes
/// back when it comes back - and for an address that goes nowhere that is more
/// than a minute. Made on the thread that runs the program, it was a minute of
/// a screen that said nothing and keys that did nothing. So it is made over
/// here, where it can be walked away from when somebody presses esc.
///
/// To stop waiting, not to stop it: the call cannot be interrupted from outside
/// either. An attempt nobody is waiting for runs to its end unwatched, closes
/// what it opened if it opened anything, and frees itself. `state` says which
/// side it belongs to, and only that side touches it.
pub const Attempt = struct {
    allocator: std.mem.Allocator,
    target: []u8,
    report: std.ArrayList(u8) = .empty,
    stage: database.Stage = .{},
    outcome: anyerror!database.Db = error.Driver,
    /// A pipe the thread writes one byte into when it has finished, which is
    /// what the wait wakes up on: a connection that takes four milliseconds
    /// should not take until the next tick to be noticed.
    done: [2]std.c.fd_t,
    state: std.atomic.Value(State) = .init(.running),

    const State = enum(u8) { running, finished, abandoned };

    fn start(allocator: std.mem.Allocator, target: []const u8) !*Attempt {
        const self = try allocator.create(Attempt);
        errdefer allocator.destroy(self);
        const copy = try allocator.dupe(u8, target);
        errdefer allocator.free(copy);
        var ends: [2]std.c.fd_t = undefined;
        if (std.c.pipe(&ends) != 0) {
            return error.NoPipe;
        }
        errdefer for (ends) |end| {
            _ = std.c.close(end);
        };
        self.* = .{ .allocator = allocator, .target = copy, .done = ends };
        const thread = try std.Thread.spawn(.{}, run, .{self});
        thread.detach();
        return self;
    }

    fn run(self: *Attempt) void {
        database.listening = &self.stage;
        self.outcome = database.Db.open(self.allocator, self.target, &self.report);
        if (self.state.cmpxchgStrong(.running, .finished, .acq_rel, .acquire) == null) {
            // Somebody is still waiting, and from this byte on it is theirs.
            _ = std.c.write(self.done[1], "!", 1);
            return;
        }
        if (self.outcome) |opened| {
            opened.close();
        } else |_| {}
        self.destroy();
    }

    /// Stop waiting for it. False when it finished first, in which case it is
    /// still the caller's and its answer is about to arrive.
    fn abandon(self: *Attempt) bool {
        return self.state.cmpxchgStrong(.running, .abandoned, .acq_rel, .acquire) == null;
    }

    fn destroy(self: *Attempt) void {
        for (self.done) |end| {
            _ = std.c.close(end);
        }
        self.report.deinit(self.allocator);
        self.allocator.free(self.target);
        self.allocator.destroy(self);
    }
};

/// Put the panel up for a connection that is about to be opened, and hand
/// the screen to the thread that keeps it moving. The caller stops it.
pub fn attend(self: *App, target: []const u8, what: []const u8) Attendant {
    // A file on this machine is open before a panel could say so.
    if (database.Db.engine(target) == .sqlite) {
        return .{};
    }
    self.connecting = .{ .started = monotonicMs(), .what = what };
    return Attendant.start(self);
}

/// Open a target in a way that can be given up on: the attempt is made on
/// a thread of its own, and this one waits for it or for esc, whichever
/// comes first. See `Attempt`.
pub fn dial(self: *App, target: []const u8, report: *std.ArrayList(u8)) !database.Db {
    // A file is opened here. There is nothing in it to wait for, and it is
    // the one driver that has to stay on this thread: SQLite is built without
    // its mutexes, because until now nothing here ran beside anything else.
    if (self.connecting == null) {
        return database.Db.open(self.allocator, target, report);
    }
    const state = &self.connecting.?;
    const attempt = Attempt.start(self.allocator, target) catch {
        // No thread to be had. Made here then, the way it always was, with
        // nothing to watch.
        return database.Db.open(self.allocator, target, report);
    };
    while (true) {
        var fds = [1]std.c.pollfd{.{ .fd = attempt.done[0], .events = std.c.POLL.IN, .revents = 0 }};
        const ready = std.c.poll(&fds, 1, 80);
        if (ready > 0) {
            break;
        }
        if (ready < 0 and std.c._errno().* != @backingInt(std.c.E.INTR)) {
            // A pipe that cannot be waited on: wait for the byte itself,
            // below, which is the old way of waiting with a thread in it.
            break;
        }
        if (state.given_up.load(.acquire) and attempt.abandon()) {
            return error.GivenUp;
        }
        // What the attempt says it is doing, passed on to the panel. Not
        // read by the panel where it is said: an attempt that was given up
        // on outlives the panel, and goes on talking.
        var text: [database.Stage.SIZE]u8 = undefined;
        state.stage.set("{s}", .{attempt.stage.read(&text)});
    }
    // The byte is taken before anything is freed. It is the last thing the
    // thread does with the attempt, so having it is knowing the thread has
    // let go - `finished` alone is set a moment before that.
    var byte: [1]u8 = undefined;
    while (std.c.read(attempt.done[0], &byte, 1) < 0 and std.c._errno().* == @backingInt(std.c.E.INTR)) {}
    defer attempt.destroy();
    report.appendSlice(self.allocator, attempt.report.items) catch {};
    return attempt.outcome;
}

/// Say what a connection being opened is busy with now, for the panel.
pub fn nowConnecting(self: *App, comptime fmt: []const u8, args: anytype) void {
    if (self.connecting) |*state| {
        state.stage.set(fmt, args);
    }
}

/// The panel, drawn again: the next frame of its spinner and whatever the
/// sentence has become. The attendant's, and nobody else's while it runs.
pub fn showConnecting(self: *App) void {
    if (self.connecting == null) {
        return;
    }
    const state = &self.connecting.?;
    // Anything under a third of a second should not flash a panel at all.
    if (monotonicMs() - state.started < 300) {
        return;
    }
    state.frame = (state.frame + 1) % SPINNER.len;
    draw.connecting(self);
}

/// Whether somebody stopped waiting after the connection was made and
/// before there was anything of it to show - and if so, the tab is put back
/// to having nothing in it. A connection whose first screen was given up on
/// is not one to be left standing in: its list is half read or not read at
/// all, and esc on a panel that says "gives up" means back to where the
/// connection was chosen.
pub fn gaveUp(self: *App) bool {
    if (self.connecting == null) {
        return false;
    }
    const state = &self.connecting.?;
    if (!state.given_up.load(.acquire)) {
        return false;
    }
    self.saveActiveTab();
    self.tabs.items[self.active_tab].deinit(self.allocator);
    self.tabs.items[self.active_tab] = Tab.init(self.allocator);
    self.loadActiveTab();
    self.say("gave up on {s}", .{state.what});
    return true;
}

test "an attempt is made on a thread of its own and says what became of it" {
    // Nothing listens on port 1, and being refused is an answer that needs no
    // server to give it.
    const attempt = try Attempt.start(testing.allocator, "redis://127.0.0.1:1/0");
    var byte: [1]u8 = undefined;
    try testing.expectEqual(@as(isize, 1), std.c.read(attempt.done[0], &byte, 1));
    defer attempt.destroy();
    try testing.expectEqual(Attempt.State.finished, attempt.state.load(.acquire));
    try testing.expectError(error.Driver, attempt.outcome);
    try testing.expectEqualStrings("cannot reach redis at 127.0.0.1:1", attempt.report.items);
    // What it was doing when it stopped is still there to be read.
    var text: [database.Stage.SIZE]u8 = undefined;
    try testing.expectEqualStrings("connecting to 127.0.0.1:1", attempt.stage.read(&text));
    // It is over, so there is nothing left to walk away from.
    try testing.expect(!attempt.abandon());
}

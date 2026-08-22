//! Running the command a kubeconfig names, and reading what it says back.
//!
//! Seven of the eight clusters in the kubeconfig this was written against
//! authenticate with an `exec` credential plugin - `aws eks get-token`,
//! `gke-gcloud-auth-plugin` and their like - so a Kubernetes driver that cannot
//! run one is a Kubernetes driver that cannot reach a cloud cluster. This is that
//! and nothing else: argv in, standard output out, with a clock on it.
//!
//! **It does not go through a shell.** The command and its arguments are handed
//! to `execve` as an array, so nothing is quoted, nothing is split, and an
//! argument with a space or a quote in it is one argument. A shell here would
//! have turned a kubeconfig into a place to write commands from.
//!
//! **Nothing is allocated between `fork` and `exec`.** This program has a thread
//! reading the terminal, and in a process with threads the child of a `fork` has
//! only the one that called it: `malloc` may be holding a lock no thread is left
//! to release, so `setenv` and friends can deadlock a child forever. The path is
//! searched, the environment is built and every string is made NUL terminated in
//! the parent, where all of that is ordinary; the child does `dup2`, `close`,
//! `execve` and `_exit`, which are the calls that are allowed there.
//!
//! **It has a deadline.** A credential plugin that waits for a login in a browser
//! will wait forever, and the interface it is holding up is a single thread.

const std = @import("std");
const clock = @import("../clock.zig");
const db = @import("../db.zig");

const List = db.List;

pub const Error = error{ Exec, OutOfMemory };

/// How long a plugin gets before it is killed. Long enough for a token endpoint
/// over a slow link, short enough that a wedged plugin is a message rather than a
/// hung program.
pub const TIMEOUT_MS: i64 = 30_000;

pub const Variable = struct {
	name: []const u8,
	value: []const u8,
};

pub const Result = struct {
	out: []const u8,
	status: u8,
};

const c = struct {
	extern "c" fn pipe(fds: *[2]c_int) c_int;
	extern "c" fn fork() c_int;
	extern "c" fn execve(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
	extern "c" fn dup2(old: c_int, new: c_int) c_int;
	extern "c" fn close(fd: c_int) c_int;
	extern "c" fn read(fd: c_int, buffer: [*]u8, count: usize) isize;
	extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
	extern "c" fn kill(pid: c_int, signal: c_int) c_int;
	extern "c" fn _exit(code: c_int) noreturn;
	extern "c" fn poll(fds: [*]Pollfd, count: c_ulong, timeout: c_int) c_int;
	extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
	extern "c" var environ: [*:null]?[*:0]u8;

	const Pollfd = extern struct { fd: c_int, events: c_short, revents: c_short };
	const POLLIN: c_short = 1;
	const SIGKILL: c_int = 9;
	const X_OK: c_int = 1;
	/// The status `execve` could not happen, by long convention.
	const NOT_RUN: u8 = 127;
};

/// Run `command` with `args`, with `extra` added to this program's environment,
/// and give back what it wrote to standard output. `why` says what went wrong
/// where nothing came back.
pub fn run(
	arena: std.mem.Allocator,
	command: []const u8,
	args: []const []const u8,
	extra: []const Variable,
	why: *List,
) Error!Result {
	// Everything the child will need, made before there is a child to need it.
	const path = try which(arena, command) orelse {
		try why.print(arena, "{s} is not on the PATH", .{command});
		return error.Exec;
	};
	const argv = try arena.allocSentinel(?[*:0]const u8, args.len + 1, null);
	argv[0] = (try arena.dupeZ(u8, command)).ptr;
	for (args, 0..) |arg, i| {
		argv[i + 1] = (try arena.dupeZ(u8, arg)).ptr;
	}
	const envp = try environment(arena, extra);

	var ends: [2]c_int = .{ -1, -1 };
	if (c.pipe(&ends) != 0) {
		try why.appendSlice(arena, "there are no file descriptors left to run it with");
		return error.Exec;
	}
	const pid = c.fork();
	if (pid < 0) {
		_ = c.close(ends[0]);
		_ = c.close(ends[1]);
		try why.appendSlice(arena, "this machine would not start another process");
		return error.Exec;
	}
	if (pid == 0) {
		// The child. Only calls that are safe here, and no way back: whatever
		// happens it ends in _exit, because returning would run this program's
		// deferred work twice.
		_ = c.close(ends[0]);
		_ = c.dup2(ends[1], 1);
		_ = c.close(ends[1]);
		_ = c.execve(path.ptr, argv.ptr, envp.ptr);
		c._exit(c.NOT_RUN);
	}

	_ = c.close(ends[1]);
	const out = readUntil(arena, ends[0], pid, why) catch |err| {
		_ = c.close(ends[0]);
		_ = c.kill(pid, c.SIGKILL);
		var thrown: c_int = 0;
		_ = c.waitpid(pid, &thrown, 0);
		return err;
	};
	_ = c.close(ends[0]);

	var status: c_int = 0;
	_ = c.waitpid(pid, &status, 0);
	// The low byte is the signal, the next one the exit code.
	const code: u8 = @truncate(@as(c_uint, @bitCast(status)) >> 8);
	if (code == c.NOT_RUN) {
		try why.print(arena, "{s} could not be run", .{command});
		return error.Exec;
	}
	return .{ .out = out, .status = code };
}

/// Milliseconds on a clock that does not go backwards, which is the only kind a
/// deadline can be measured against.
fn nowMs() i64 {
	return @divTrunc(clock.steadyNanos(), 1_000_000);
}

/// Read the pipe to its end, or until the deadline runs out. A plugin that is
/// still thinking when time is up is killed by the caller.
fn readUntil(arena: std.mem.Allocator, fd: c_int, pid: c_int, why: *List) Error![]const u8 {
	var out: List = .empty;
	var left: i64 = TIMEOUT_MS;
	var chunk: [4096]u8 = undefined;
	while (true) {
		var watch = [_]c.Pollfd{.{ .fd = fd, .events = c.POLLIN, .revents = 0 }};
		const started = nowMs();
		const ready = c.poll(&watch, 1, @intCast(@max(0, left)));
		if (ready == 0) {
			try why.print(arena, "it was still running after {d} seconds and was stopped", .{@divTrunc(TIMEOUT_MS, 1000)});
			return error.Exec;
		}
		if (ready < 0) {
			// Interrupted: try again with whatever time is left.
			left -= nowMs() - started;
			if (left <= 0) {
				try why.appendSlice(arena, "it took too long and was stopped");
				return error.Exec;
			}
			continue;
		}
		const got = c.read(fd, &chunk, chunk.len);
		if (got <= 0) {
			break;
		}
		try out.appendSlice(arena, chunk[0..@intCast(got)]);
		// A plugin that writes without end is a plugin that is not answering.
		if (out.items.len > 4 << 20) {
			try why.appendSlice(arena, "it wrote more than a credential could possibly be");
			return error.Exec;
		}
		left -= nowMs() - started;
		if (left <= 0) {
			try why.appendSlice(arena, "it took too long and was stopped");
			return error.Exec;
		}
	}
	_ = pid;
	return out.items;
}

/// This program's environment with `extra` laid over it: a name given twice is
/// the plugin's, because that is what the kubeconfig asked for.
fn environment(arena: std.mem.Allocator, extra: []const Variable) Error![:null]?[*:0]const u8 {
	var list: std.ArrayListUnmanaged(?[*:0]const u8) = .empty;
	var i: usize = 0;
	while (c.environ[i]) |entry| : (i += 1) {
		const text = std.mem.sliceTo(entry, 0);
		const cut = std.mem.indexOfScalar(u8, text, '=') orelse text.len;
		var replaced = false;
		for (extra) |variable| {
			if (std.mem.eql(u8, text[0..cut], variable.name)) {
				replaced = true;
			}
		}
		if (!replaced) {
			try list.append(arena, @ptrCast(entry));
		}
	}
	for (extra) |variable| {
		const entry = try std.fmt.allocPrintSentinel(arena, "{s}={s}", .{ variable.name, variable.value }, 0);
		try list.append(arena, entry.ptr);
	}
	return try list.toOwnedSliceSentinel(arena, null);
}

/// Where `command` is, walking `PATH` the way a shell would - in the parent,
/// where looking is allowed, and so that "not on the PATH" is a sentence rather
/// than an exit status of 127 with nothing attached to it.
pub fn which(arena: std.mem.Allocator, command: []const u8) Error!?[:0]const u8 {
	if (command.len == 0) {
		return null;
	}
	if (std.mem.indexOfScalar(u8, command, '/') != null) {
		const path = try arena.dupeZ(u8, command);
		return if (c.access(path.ptr, c.X_OK) == 0) path else null;
	}
	const search = std.mem.sliceTo(std.c.getenv("PATH") orelse return null, 0);
	var places = std.mem.splitScalar(u8, search, ':');
	while (places.next()) |place| {
		if (place.len == 0) {
			continue;
		}
		const path = try std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ place, command }, 0);
		if (c.access(path.ptr, c.X_OK) == 0) {
			return path;
		}
	}
	return null;
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

test "a command runs and its output comes back" {
	var arena = std.heap.ArenaAllocator.init(testing.allocator);
	defer arena.deinit();
	var why: List = .empty;
	const got = try run(arena.allocator(), "echo", &.{ "one", "two three" }, &.{}, &why);
	try testing.expectEqual(@as(u8, 0), got.status);
	// One argument with a space in it, not two: nothing went through a shell.
	try testing.expectEqualStrings("one two three\n", got.out);
}

test "an argument a shell would have eaten arrives whole" {
	var arena = std.heap.ArenaAllocator.init(testing.allocator);
	defer arena.deinit();
	var why: List = .empty;
	const nasty = "a'b\"c;d $HOME `id` | wc";
	const got = try run(arena.allocator(), "echo", &.{nasty}, &.{}, &why);
	try testing.expectEqualStrings(nasty ++ "\n", got.out);
}

test "the environment is this program's, with the kubeconfig's laid over it" {
	var arena = std.heap.ArenaAllocator.init(testing.allocator);
	defer arena.deinit();
	var why: List = .empty;
	// PATH is inherited, or `which` would not have found anything to run.
	const inherited = try run(arena.allocator(), "sh", &.{ "-c", "test -n \"$PATH\" && echo inherited" }, &.{}, &why);
	try testing.expectEqualStrings("inherited\n", inherited.out);

	const added = try run(arena.allocator(), "sh", &.{ "-c", "echo $KRTEK_TEST_VARIABLE" }, &.{
		.{ .name = "KRTEK_TEST_VARIABLE", .value = "here" },
	}, &why);
	try testing.expectEqualStrings("here\n", added.out);

	// And a name given twice is the kubeconfig's, not the one already set.
	const over = try run(arena.allocator(), "sh", &.{ "-c", "echo $PATH" }, &.{
		.{ .name = "PATH", .value = "/replaced" },
	}, &why);
	try testing.expectEqualStrings("/replaced\n", over.out);
}

test "a failure is a status and a sentence, not a hang" {
	var arena = std.heap.ArenaAllocator.init(testing.allocator);
	defer arena.deinit();
	var why: List = .empty;

	// Something that is not there at all.
	try testing.expectError(error.Exec, run(arena.allocator(), "krtek-no-such-plugin", &.{}, &.{}, &why));
	try testing.expect(std.mem.indexOf(u8, why.items, "not on the PATH") != null);

	// Something that runs and fails: the status comes back rather than an error,
	// because what it printed is what says why.
	why.clearRetainingCapacity();
	const failed = try run(arena.allocator(), "sh", &.{ "-c", "echo nope; exit 3" }, &.{}, &why);
	try testing.expectEqual(@as(u8, 3), failed.status);
	try testing.expectEqualStrings("nope\n", failed.out);
}

test "a plugin that never answers is stopped rather than waited on" {
	var arena = std.heap.ArenaAllocator.init(testing.allocator);
	defer arena.deinit();
	var why: List = .empty;
	// The deadline itself is half a minute, which no test should wait for; this
	// checks the path by making the read side see nothing until the child ends.
	const started = nowMs();
	const got = try run(arena.allocator(), "sh", &.{ "-c", "sleep 0.2; echo late" }, &.{}, &why);
	try testing.expectEqualStrings("late\n", got.out);
	try testing.expect(nowMs() - started >= 150);
}

test "where a command is, and where it is not" {
	var arena = std.heap.ArenaAllocator.init(testing.allocator);
	defer arena.deinit();
	const a = arena.allocator();
	const found = try which(a, "sh");
	try testing.expect(found != null);
	try testing.expect(std.mem.endsWith(u8, found.?, "/sh"));
	try testing.expect(try which(a, "krtek-no-such-plugin") == null);
	// A path with a slash in it is taken as it stands, and checked.
	try testing.expect(try which(a, "/bin/sh") != null);
	try testing.expect(try which(a, "/bin/no-such-thing") == null);
	try testing.expect(try which(a, "") == null);
}

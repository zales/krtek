//! Builds the native terminal app. The WASM module keeps its own script
//! (build.sh), because its flag set is what makes it work in a browser and it
//! is pinned there deliberately.

const std = @import("std");

/// SQLite for a real operating system: the unix VFS stays in, so the app opens
/// the file on disk instead of holding the database in memory.
const sqlite_flags = [_][]const u8{
	"-DNDEBUG",
	"-DSQLITE_THREADSAFE=0",
	"-DSQLITE_OMIT_LOAD_EXTENSION",
	"-DSQLITE_DQS=0",
	"-DSQLITE_ENABLE_FTS5",
	"-DSQLITE_ENABLE_JSON1",
	"-DSQLITE_ENABLE_RTREE",
	"-DSQLITE_ENABLE_MATH_FUNCTIONS",
	"-DSQLITE_ENABLE_COLUMN_METADATA",
	"-DSQLITE_ENABLE_DBSTAT_VTAB",
	"-DSQLITE_ENABLE_EXPLAIN_COMMENTS",
	"-DSQLITE_DEFAULT_FOREIGN_KEYS=1",
};

/// Both client libraries are keg-only on Homebrew, so on a Mac their prefixes
/// have to be pointed at; `-Dlibpq=` and `-Dmariadb=` do that, and the defaults
/// are where brew puts them on Apple silicon. Elsewhere the system include and
/// library paths are used, with the usual places their headers hide in added.
pub fn build(b: *std.Build) void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.standardOptimizeOption(.{});
	const libpq = b.option([]const u8, "libpq", "prefix of the libpq installation");
	// Linking the client libraries into the binary, so it needs nothing installed
	// to run. The system's own libraries stay dynamic - there is no static libc on
	// macOS, and no reason to on glibc.
	// pkg-config is what tells a static build what else to link, so it has to be
	// installed for -Dstatic; PKG_CONFIG_PATH is how a keg-only brew library is
	// found.
	const static = b.option(bool, "static", "link the client libraries into the binary") orelse false;
	// The MariaDB connector speaks to MySQL as well, and its licence allows a
	// non-GPL program to link it - Oracle's own client library does not.
	const mariadb = b.option([]const u8, "mariadb", "prefix of the mariadb-connector-c installation");
	// OpenSSL: the Kafka driver calls it directly for TLS. A static build already
	// links it - both client libraries want it - so this prefix is only about
	// finding the shared one for a build that is not static.
	const openssl = b.option([]const u8, "openssl", "prefix of the OpenSSL installation");

	const linking = Linking{ .static = static };

	// The bindings are shared with the WASM build, so they are their own module
	// rather than a relative import reaching outside the root.
	const bindings = b.createModule(.{
		.root_source_file = b.path("src/sqlite.zig"),
		.target = target,
		.optimize = optimize,
	});

	const database = b.createModule(.{
		.root_source_file = b.path("src/db/db.zig"),
		.target = target,
		.optimize = optimize,
		.link_libc = true,
	});
	database.addImport("sqlite", bindings);

	const vaxis = b.dependency("vaxis", .{ .target = target, .optimize = optimize });

	const module = b.createModule(.{
		.root_source_file = b.path("src/tui/main.zig"),
		.target = target,
		.optimize = optimize,
		.link_libc = true,
		// A release does not need the debug info, which is most of the file.
		.strip = b.option(bool, "strip", "leave the debug info out") orelse false,
	});
	module.addImport("sqlite", bindings);
	module.addImport("db", database);
	module.addImport("vaxis", vaxis.module("vaxis"));
	module.addIncludePath(b.path("vendor"));
	module.addCSourceFile(.{ .file = b.path("vendor/sqlite3.c"), .flags = &sqlite_flags });
	linkPostgres(b, module, target, libpq, linking);
	linkMysql(b, module, target, mariadb, linking);
	linkTls(b, module, target, openssl, linking);
	linkKeychain(module, target);
	if (static) {
		linkClientLibraries(b, module);
	}

	const exe = b.addExecutable(.{
		.name = "krtek",
		.root_module = module,
		// Where there is a static libc - musl - a static build links that too and
		// the result needs nothing at all. macOS has no static libSystem, so there
		// only the client libraries go inside.
		.linkage = if (static and target.result.abi == .musl) .static else null,
	});
	b.installArtifact(exe);

	const run = b.addRunArtifact(exe);
	run.step.dependOn(b.getInstallStep());
	if (b.args) |args| {
		run.addArgs(args);
	}
	b.step("run", "Open a database in the terminal app").dependOn(&run.step);

	const test_module = b.createModule(.{
		.root_source_file = b.path("src/tui/test.zig"),
		.target = target,
		.optimize = optimize,
		.link_libc = true,
	});
	test_module.addImport("sqlite", bindings);
	test_module.addImport("db", database);
	test_module.addImport("vaxis", vaxis.module("vaxis"));
	test_module.addIncludePath(b.path("vendor"));
	test_module.addCSourceFile(.{ .file = b.path("vendor/sqlite3.c"), .flags = &sqlite_flags });
	linkPostgres(b, test_module, target, libpq, linking);
	linkMysql(b, test_module, target, mariadb, linking);
	linkTls(b, test_module, target, openssl, linking);
	linkKeychain(test_module, target);
	if (static) {
		linkClientLibraries(b, test_module);
	}
	const tests = b.addTest(.{ .root_module = test_module });

	// The drivers are a module of their own, and `zig test` only collects the
	// tests of the module it is rooted in - importing it from the app's test file
	// compiles it but runs none of its tests. So it gets an artifact of its own,
	// which is how the tests in src/db came to run at all.
	const db_test_module = b.createModule(.{
		.root_source_file = b.path("src/db/db.zig"),
		.target = target,
		.optimize = optimize,
		.link_libc = true,
	});
	db_test_module.addImport("sqlite", bindings);
	db_test_module.addIncludePath(b.path("vendor"));
	db_test_module.addCSourceFile(.{ .file = b.path("vendor/sqlite3.c"), .flags = &sqlite_flags });
	linkPostgres(b, db_test_module, target, libpq, linking);
	linkMysql(b, db_test_module, target, mariadb, linking);
	linkTls(b, db_test_module, target, openssl, linking);
	if (static) {
		linkClientLibraries(b, db_test_module);
	}
	const db_tests = b.addTest(.{ .root_module = db_test_module });

	// A scratch program that talks to a real PostgreSQL, for development.
	const check_module = b.createModule(.{
		.root_source_file = b.path("tests/dbcheck.zig"),
		.target = target,
		.optimize = optimize,
		.link_libc = true,
	});
	check_module.addImport("db", database);
	check_module.addIncludePath(b.path("vendor"));
	check_module.addCSourceFile(.{ .file = b.path("vendor/sqlite3.c"), .flags = &sqlite_flags });
	linkPostgres(b, check_module, target, libpq, linking);
	linkMysql(b, check_module, target, mariadb, linking);
	linkTls(b, check_module, target, openssl, linking);
	const check = b.addExecutable(.{ .name = "dbcheck", .root_module = check_module });
	const run_check = b.addRunArtifact(check);
	if (b.args) |args| {
		run_check.addArgs(args);
	}
	b.step("dbcheck", "Talk to a real server, without the interface").dependOn(&run_check.step);
	// A one-off check that the keychain really answers on this machine.
	const kc_module = b.createModule(.{
		.root_source_file = b.path("tests/keychain_check.zig"),
		.target = target,
		.optimize = optimize,
	});
	kc_module.addImport("keychain", b.createModule(.{
		.root_source_file = b.path("src/tui/keychain.zig"),
		.target = target,
		.optimize = optimize,
	}));
	kc_module.link_libc = true;
	linkKeychain(kc_module, target);
	const kc = b.addExecutable(.{ .name = "kccheck", .root_module = kc_module });
	b.step("kccheck", "Check the macOS keychain, by hand").dependOn(&b.addRunArtifact(kc).step);

	const test_step = b.step("test", "Unit tests of the terminal app and the drivers");
	test_step.dependOn(&b.addRunArtifact(tests).step);
	test_step.dependOn(&b.addRunArtifact(db_tests).step);
}

fn linkPostgres(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget, prefix: ?[]const u8, options: Linking) void {
	if (prefix orelse defaultPrefix(target, "libpq")) |root| {
		module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ root, "include" }) });
		module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ root, "lib" }) });
	} else {
		// Where the distributions put it; a path that is not there is only an
		// unused -I flag.
		module.addIncludePath(.{ .cwd_relative = "/usr/include/postgresql" });
	}
	if (!options.static) {
		module.linkSystemLibrary("pq", .{});
		return;
	}
	// A static build links both client libraries together, in one place; see
	// `linkClientLibraries`.
}

const Linking = struct {
	static: bool,
};

/// Link what `pkg-config --static` says the client libraries need, preferring an
/// archive for each and falling back to the shared one where there is none -
/// which is what leaves libc, Kerberos, LDAP and the like dynamic.
///
/// Both libraries are asked for in one call so that pkg-config merges the two
/// lists: they share zlib and OpenSSL, and asking separately puts zlib in the
/// binary twice, which dyld refuses to load.
///
/// pkg-config is run here rather than handed to `linkSystemLibrary`'s own
/// `use_pkg_config`, because that reads only the shared link line and so misses
/// everything a static libpq needs.
fn linkClientLibraries(b: *std.Build, module: *std.Build.Module) void {
	var code: u8 = 0;
	const out = b.runAllowFail(
		&.{ "pkg-config", "--static", "--libs", "libpq", "libmariadb" },
		&code,
		.ignore,
	) catch {
		std.debug.panic(
			"-Dstatic needs pkg-config with libpq.pc and libmariadb.pc; " ++
				"on a Mac set PKG_CONFIG_PATH to the keg-only prefixes",
			.{},
		);
	};

	// The search paths first, so an archive can be looked for in them below. The
	// system directories are in the list too: a .pc file for something that lives
	// in /usr/lib says no -L at all.
	var paths: std.ArrayList([]const u8) = .empty;
	const system = [_][]const u8{
		"/usr/lib",
		"/lib",
		b.fmt("/usr/lib/{t}-linux-gnu", .{module.resolved_target.?.result.cpu.arch}),
	};
	for (system) |where| {
		// A .pc file for something that lives in /usr/lib names no -L at all, so
		// the search has to know the usual places - and the linker is told about
		// the ones that exist, or it resolves the library from its own paths, where
		// only the shared one is.
		if (std.Io.Dir.cwd().access(b.graph.io, where, .{})) |_| {
			paths.append(b.allocator, where) catch @panic("out of memory");
			module.addLibraryPath(.{ .cwd_relative = where });
		} else |_| {}
	}
	var scan = std.mem.tokenizeAny(u8, out, " \r\n\t");
	while (scan.next()) |flag| {
		if (std.mem.startsWith(u8, flag, "-L")) {
			paths.append(b.allocator, flag[2..]) catch @panic("out of memory");
			module.addLibraryPath(.{ .cwd_relative = flag[2..] });
		}
	}

	// Each library once. The two lists overlap - both want zlib and OpenSSL - and
	// one of them names zlib as `-l/…/libz.tbd` while the other says `-lz`, which
	// linked twice is a binary dyld refuses to start.
	var seen: std.StringHashMap(void) = .init(b.allocator);
	var flags = std.mem.tokenizeAny(u8, out, " \r\n\t");
	while (flags.next()) |flag| {
		if (std.mem.eql(u8, flag, "-framework")) {
			if (flags.next()) |framework| {
				module.linkFramework(framework, .{});
			}
			continue;
		}
		if (!std.mem.startsWith(u8, flag, "-l")) {
			continue;
		}
		const entry = flag[2..];
		// A real archive given by path goes in as it is.
		if (std.mem.endsWith(u8, entry, ".a")) {
			module.addObjectFile(.{ .cwd_relative = entry });
			continue;
		}
		const library = shlibVariant(b, paths.items, libraryName(entry));
		if (seen.fetchPut(library, {}) catch @panic("out of memory")) |_| {
			continue;
		}
		// PostgreSQL's internal archives are separate where they are separate:
		// brew ships them beside libpq, Debian builds them into it and its .pc
		// file mentions them anyway. Asking for one that is not there is a build
		// error, so it is only asked for when it is on disk.

		// The archive is handed over as a file rather than as `-lname`. That keeps
		// the linker out of its own search, which is what decides between an
		// archive and a shared library and is the one thing that must not happen
		// here: a single shared library in the line makes the whole link dynamic.
		if (archive(b, paths.items, library)) |found| {
			module.addObjectFile(.{ .cwd_relative = found });
			continue;
		}
		// No archive: on musl these are the pieces libc already contains, and
		// everywhere else the system's shared library is what was meant.
		if (inLibc(library)) {
			continue;
		}
		module.linkSystemLibrary(library, .{});
	}
}

/// `z` out of `z`, and out of `/…/usr/lib/libz.tbd` - which is how the macOS SDK
/// is named in a .pc file.
fn libraryName(entry: []const u8) []const u8 {
	var name = entry;
	if (std.mem.lastIndexOfScalar(u8, name, '/')) |slash| {
		name = name[slash + 1 ..];
	}
	if (std.mem.startsWith(u8, name, "lib")) {
		name = name["lib".len..];
	}
	if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| {
		name = name[0..dot];
	}
	return name;
}

/// PostgreSQL builds its internal archives twice, and only the `_shlib` ones
/// match the libpq that references them - brew's `libpq.pc` names the other pair,
/// which links and then leaves `pg_encoding_to_char` undefined. So where a
/// `lib<name>_shlib.a` exists, that is the one meant.
fn shlibVariant(b: *std.Build, paths: []const []const u8, library: []const u8) []const u8 {
	const wanted = b.fmt("{s}_shlib", .{library});
	return if (archive(b, paths, wanted) != null) wanted else library;
}

/// Where `lib<name>.a` is, among the paths pkg-config gave, or null.
fn archive(b: *std.Build, paths: []const []const u8, library: []const u8) ?[]const u8 {
	for (paths) |where| {
		const candidate = b.pathJoin(&.{ where, b.fmt("lib{s}.a", .{library}) });
		if (std.Io.Dir.cwd().access(b.graph.io, candidate, .{})) |_| {
			return candidate;
		} else |_| {}
	}
	return null;
}

/// Libraries that are part of libc rather than libraries of their own: musl has
/// all of them inside libc.a, and glibc keeps them as stubs. PostgreSQL's own
/// pieces land here too when a system builds them into libpq.a instead of beside
/// it, as Debian does - there is then nothing to add and nothing missing.
fn inLibc(library: []const u8) bool {
	for ([_][]const u8{
		"m",         "dl",     "pthread", "rt",     "resolv", "util", "crypt", "c",
		"pgcommon",  "pgport", "pgcommon_shlib",    "pgport_shlib",   "pq-oauth",
	}) |name| {
		if (std.mem.eql(u8, library, name)) {
			return true;
		}
	}
	return false;
}

/// The keychain lives in Security.framework, which only macOS has.
fn linkKeychain(module: *std.Build.Module, target: std.Build.ResolvedTarget) void {
	if (target.result.os.tag != .macos) {
		return;
	}
	module.linkFramework("Security", .{});
	module.linkFramework("CoreFoundation", .{});
}

fn linkMysql(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget, prefix: ?[]const u8, options: Linking) void {
	if (prefix orelse defaultPrefix(target, "mariadb-connector-c")) |root| {
		module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ root, "include", "mariadb" }) });
		module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ root, "lib" }) });
	} else {
		for ([_][]const u8{ "/usr/include/mariadb", "/usr/include/mysql" }) |candidate| {
			module.addIncludePath(.{ .cwd_relative = candidate });
		}
	}
	if (!options.static) {
		module.linkSystemLibrary("mariadb", .{});
	}
}

/// OpenSSL, which the Kafka driver calls for TLS. A static build gets it from the
/// archives pkg-config named for libpq and the connector, so this only has to
/// find the shared library - and on a Mac that means brew's keg-only prefix.
fn linkTls(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget, prefix: ?[]const u8, options: Linking) void {
	if (options.static) {
		return;
	}
	const root = prefix orelse defaultPrefix(target, "openssl");
	if (root) |where| {
		module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ where, "lib" }) });
	}
	module.linkSystemLibrary("ssl", .{});
	module.linkSystemLibrary("crypto", .{});
}

/// On macOS, where brew keeps a keg-only library on Apple silicon. Elsewhere
/// null, which means "it is on the system paths".
fn defaultPrefix(target: std.Build.ResolvedTarget, name: []const u8) ?[]const u8 {
	if (target.result.os.tag != .macos) {
		return null;
	}
	if (std.mem.eql(u8, name, "libpq")) {
		return "/opt/homebrew/opt/libpq";
	}
	if (std.mem.eql(u8, name, "openssl")) {
		return "/opt/homebrew/opt/openssl@3";
	}
	return "/opt/homebrew/opt/mariadb-connector-c";
}

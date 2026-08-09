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
	const static = b.option(bool, "static", "link the client libraries into the binary") orelse false;
	const openssl = b.option([]const u8, "openssl", "prefix of the OpenSSL installation");
	// The MariaDB connector speaks to MySQL as well, and its licence allows a
	// non-GPL program to link it - Oracle's own client library does not.
	const mariadb = b.option([]const u8, "mariadb", "prefix of the mariadb-connector-c installation");

	const linking = Linking{ .static = static, .openssl = openssl };

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
	});
	module.addImport("sqlite", bindings);
	module.addImport("db", database);
	module.addImport("vaxis", vaxis.module("vaxis"));
	module.addIncludePath(b.path("vendor"));
	module.addCSourceFile(.{ .file = b.path("vendor/sqlite3.c"), .flags = &sqlite_flags });
	linkPostgres(b, module, target, libpq, linking);
	linkMysql(b, module, target, mariadb, linking);
	linkKeychain(module, target);

	const exe = b.addExecutable(.{ .name = "krtek", .root_module = module });
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
	linkKeychain(test_module, target);
	const tests = b.addTest(.{ .root_module = test_module });

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

	b.step("test", "Unit tests of the terminal app").dependOn(&b.addRunArtifact(tests).step);
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
	// A static libpq is split into three archives and wants a fourth for OAuth,
	// then the things it talks to: TLS, Kerberos, LDAP, HTTP, zlib. All of those
	// except OpenSSL are part of the system on both platforms.
	// `libpq.a` is only half of it: the rest of PostgreSQL's own code is in
	// `libpgcommon_shlib.a` and `libpgport_shlib.a` - the plain `libpgcommon.a`
	// looks like it would do and does not, because it is built differently from
	// the libpq that references it - and the OAuth flow is in `libpq-oauth.a`.
	for ([_][]const u8{ "pq", "pq-oauth", "pgcommon_shlib", "pgport_shlib" }) |name| {
		module.linkSystemLibrary(name, .{ .preferred_link_mode = .static, .weak = true });
	}
	linkOpenSsl(b, module, options.openssl, target);
	const system = if (target.result.os.tag == .macos)
		&[_][]const u8{ "gssapi_krb5", "curl", "ldap", "z", "m" }
	else
		&[_][]const u8{ "gssapi_krb5", "ldap", "lber", "z", "m" };
	for (system) |name| {
		module.linkSystemLibrary(name, .{ .weak = true });
	}
}

const Linking = struct {
	static: bool,
	openssl: ?[]const u8,
};

/// OpenSSL is the one dependency neither platform has where the linker looks, so
/// its prefix is asked for: `-Dopenssl=$(brew --prefix openssl@3)` on a Mac,
/// nothing needed on a distribution that puts it in /usr/lib.
fn linkOpenSsl(b: *std.Build, module: *std.Build.Module, prefix: ?[]const u8, target: std.Build.ResolvedTarget) void {
	const root: ?[]const u8 = prefix orelse
		if (target.result.os.tag == .macos) "/opt/homebrew/opt/openssl@3" else null;
	if (root) |where| {
		module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ where, "lib" }) });
	}
	for ([_][]const u8{ "ssl", "crypto" }) |name| {
		module.linkSystemLibrary(name, .{ .preferred_link_mode = .static });
	}
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
	module.linkSystemLibrary("mariadb", .{
		.preferred_link_mode = if (options.static) .static else .dynamic,
	});
	if (options.static) {
		// The connector wants TLS and zlib; libpq brought the same OpenSSL along.
		linkOpenSsl(b, module, options.openssl, target);
		module.linkSystemLibrary("z", .{ .weak = true });
	}
}

/// On macOS, where brew keeps a keg-only library on Apple silicon. Elsewhere
/// null, which means "it is on the system paths".
fn defaultPrefix(target: std.Build.ResolvedTarget, name: []const u8) ?[]const u8 {
	if (target.result.os.tag != .macos) {
		return null;
	}
	return if (std.mem.eql(u8, name, "libpq"))
		"/opt/homebrew/opt/libpq"
	else
		"/opt/homebrew/opt/mariadb-connector-c";
}

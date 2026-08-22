//! The Kubernetes driver: the API server over HTTPS, and the kubeconfig in front
//! of it.
//!
//! **A resource kind is a table and a namespace is a schema.** That is the whole
//! mapping and it is a close one: `#` switches namespace the way it switches
//! schema on PostgreSQL, the object list on the left is pods, deployments,
//! services and the rest, and a row is one object with the columns kubectl would
//! have printed. What a cluster is short of, compared with a database, is a
//! `WHERE` the server will honour and a `COUNT` that costs nothing - so both are
//! done here, over the whole list, which is said out loud below.
//!
//! **Everything about reaching the cluster is in the kubeconfig**, so the target
//! names a context and at most a namespace and nothing else: a second place for
//! the same fact to be wrong is worse than a longer command line. The pieces that
//! read it are files of their own, because they take text and give structures back
//! and can be tested with no cluster anywhere near them:
//!
//! * `k8s/yaml.zig` - just enough YAML, refusing by name what it does not know.
//! * `k8s/config.zig` - choosing a context, and then decoding, reading and running
//!   what it points at.
//! * `k8s/exec.zig` - the credential plugin, without a shell and with a deadline.
//! * `k8s/target.zig` - what `k8s://context/namespace` means.
//! * `k8s/api.zig` - which kinds are tables and where each column lives in the JSON.
//!
//! **A list is fetched whole and paged here.** Kubernetes pages with a `continue`
//! token, which walks forwards only: it cannot answer "the rows from 400", which
//! is what a grid with page numbers asks. Fetching the list and slicing it gives
//! an exact count and pages that mean something, at the cost of holding one
//! namespace's objects in memory - which is a few hundred kilobytes for the
//! namespaces people look at, and is capped rather than trusted.
//!
//! **Rows are read, deleted and scaled, and not edited.** An object is a document
//! with a controller acting on it; writing one back from a grid of flattened cells
//! would be a way to lose a field nobody displayed. Deleting is exact and asks
//! first, scaling is one number, and both are what somebody at a terminal reaches
//! for. Editing says what it is instead of pretending.

const std = @import("std");
const db = @import("db.zig");
const http = @import("http.zig");

pub const yaml = @import("k8s/yaml.zig");
pub const config = @import("k8s/config.zig");
pub const exec = @import("k8s/exec.zig");
pub const api = @import("k8s/api.zig");
pub const address = @import("k8s/target.zig");

const List = db.List;
const Json = std.json.Value;

comptime {
	_ = yaml;
	_ = config;
	_ = exec;
	_ = api;
	_ = address;
}

pub const owns = address.owns;
pub const Parts = address.Parts;

/// How much of a list this driver will hold. A namespace with more objects than
/// this in it is one nobody browses; the message says what happened rather than
/// the grid quietly ending early.
const LIST_LIMIT: usize = 32 << 20;
/// How many lines of a pod's log `LOGS` asks for when nobody said.
const LOG_LINES: usize = 200;

pub const Value = union(enum) {
	nil,
	number: i64,
	text: []const u8,
};

pub const Db = struct {
	allocator: std.mem.Allocator,
	/// Owns the connection: the parts, the certificates, the token.
	home: std.heap.ArenaAllocator,
	ready: config.Ready = .{},
	parts: Parts = .{},
	namespace: []const u8 = "default",
	authorization: []const u8 = "",
	client: ?http.Client = null,
	label: List = .empty,
	version_text: List = .empty,
	last_error: List = .empty,
	progress: ?db.Progress = null,
	requests: usize = 0,
	/// How many objects of a kind were in a namespace when it was last read, by
	/// `namespace/kind`. See `rowCount` for why this is a memory and not a call.
	counts: std.StringHashMapUnmanaged(i64) = .empty,
	/// Rows and everything they point at, until the next statement.
	replies: std.heap.ArenaAllocator,

	pub fn open(allocator: std.mem.Allocator, target: []const u8, report: *List) !*Db {
		const self = try allocator.create(Db);
		self.* = .{
			.allocator = allocator,
			.home = std.heap.ArenaAllocator.init(allocator),
			.replies = std.heap.ArenaAllocator.init(allocator),
		};
		errdefer self.close();
		const home = self.home.allocator();

		self.parts = address.parse(home, target) catch {
			try report.appendSlice(allocator, "that is not a kubernetes target");
			return error.Driver;
		};

		const path = (config.find(home, self.parts.kubeconfig) catch null) orelse {
			try report.appendSlice(allocator, "there is no kubeconfig: no $KUBECONFIG, and no home directory to look in");
			return error.Driver;
		};
		const text = config.readFile(home, path) catch {
			try report.print(allocator, "{s} cannot be read", .{path});
			return error.Driver;
		};
		var why: List = .empty;
		const doc = yaml.parse(home, text, &why) catch {
			try report.print(allocator, "{s} is not a kubeconfig this can read - {s}", .{ path, why.items });
			return error.Driver;
		};
		const chosen = config.pick(home, doc, self.parts.context, &why) catch {
			try report.appendSlice(allocator, why.items);
			return error.Driver;
		};
		self.ready = config.resolve(home, chosen, &why) catch {
			try report.appendSlice(allocator, why.items);
			return error.Driver;
		};
		if (self.parts.insecure) {
			self.ready.insecure = true;
		}
		if (self.parts.namespace.len != 0) {
			self.ready.namespace = self.parts.namespace;
		}
		self.namespace = self.ready.namespace;

		const server = splitServer(self.ready.server) orelse {
			try report.print(allocator, "the cluster's address is {s}, which is not a URL", .{self.ready.server});
			return error.Driver;
		};
		self.client = http.Client.init(home, server.host, server.port, server.tls, !self.ready.insecure) catch {
			try report.appendSlice(allocator, "out of memory");
			return error.Driver;
		};
		self.client.?.ca_pem = self.ready.ca_pem;
		self.client.?.cert_pem = self.ready.cert_pem;
		self.client.?.key_pem = self.ready.key_pem;
		if (self.ready.token.len != 0) {
			self.authorization = try std.fmt.allocPrint(home, "Bearer {s}", .{self.ready.token});
		}

		var scratch = std.heap.ArenaAllocator.init(allocator);
		defer scratch.deinit();
		const arena = scratch.allocator();
		const response = self.call(arena, "GET", "/version", "") catch {
			try report.appendSlice(allocator, self.message());
			return error.Driver;
		};
		if (!response.ok()) {
			self.fail(response, "the cluster") catch {};
			try report.appendSlice(allocator, self.message());
			return error.Driver;
		}
		const about = std.json.parseFromSliceLeaky(Json, arena, response.body, .{}) catch {
			try report.appendSlice(allocator, "that address answers, but not as a Kubernetes API server");
			return error.Driver;
		};
		try self.version_text.print(allocator, "Kubernetes {s}", .{
			if (api.at(about, "gitVersion")) |value| (if (value == .string) value.string else "?") else "?",
		});
		self.relabel();
		return self;
	}

	pub fn close(self: *Db) void {
		if (self.client) |*client| {
			client.deinit();
		}
		self.label.deinit(self.allocator);
		self.version_text.deinit(self.allocator);
		self.last_error.deinit(self.allocator);
		self.replies.deinit();
		self.home.deinit();
		self.allocator.destroy(self);
	}

	pub fn watch(self: *Db, progress: ?db.Progress) void {
		self.progress = progress;
		if (self.client) |*client| {
			client.watch(progress);
		}
	}

	pub fn caps(_: *Db) db.Caps {
		return .{
			// Namespaces, which is what a schema is here.
			.schemas = true,
			.label = "Kubernetes",
			.speaks_sql = false,
			// A dump of objects would be a dump without their controllers, and
			// replaying it would make things nobody asked for.
			.dumps_rows = false,
			// Nothing takes a deleted object back, so x asks.
			.final_deletes = true,
			.row_noun = "object",
			.schema_noun = "namespace",
			// The kinds are what the cluster's API groups say they are.
			.creates_tables = false,
			// kubectl apply makes an object; nothing here does.
			.inserts_rows = false,
		};
	}

	pub fn version(self: *Db) []const u8 {
		return self.version_text.items;
	}

	pub fn describe(self: *Db) []const u8 {
		return self.label.items;
	}

	pub fn message(self: *Db) []const u8 {
		return self.last_error.items;
	}

	fn relabel(self: *Db) void {
		self.label.clearRetainingCapacity();
		self.label.print(self.allocator, "{s}", .{
			if (self.ready.context.len != 0) self.ready.context else self.ready.server,
		}) catch {};
	}

	fn begin(self: *Db) void {
		self.last_error.clearRetainingCapacity();
		_ = self.replies.reset(.retain_capacity);
	}

	fn remember(self: *Db, what: []const u8) void {
		self.last_error.clearRetainingCapacity();
		self.last_error.appendSlice(self.allocator, what) catch {};
	}

	fn complain(self: *Db, comptime fmt: []const u8, args: anytype) void {
		self.last_error.clearRetainingCapacity();
		self.last_error.print(self.allocator, fmt, args) catch {};
	}

	// --------------------------------------------------------------- the wire

	fn call(self: *Db, arena: std.mem.Allocator, method: []const u8, path: []const u8, body: []const u8) !http.Response {
		var headers: std.ArrayListUnmanaged(http.Header) = .empty;
		try headers.append(arena, .{ .name = "Accept", .value = "application/json" });
		if (self.authorization.len != 0) {
			try headers.append(arena, .{ .name = "Authorization", .value = self.authorization });
		}
		if (body.len != 0) {
			try headers.append(arena, .{ .name = "Content-Type", .value = "application/merge-patch+json" });
		}
		self.requests += 1;
		const client = &(self.client orelse return error.Driver);
		return client.send(arena, .{
			.method = method,
			.target = path,
			.headers = headers.items,
			.body = body,
			.limit = LIST_LIMIT,
		}) catch {
			self.remember(client.message());
			if (self.last_error.items.len == 0) {
				self.remember("the cluster could not be reached");
			}
			return error.Driver;
		};
	}

	/// What the API server said went wrong. Its errors are JSON with a `message`
	/// in them, which is a sentence somebody wrote; the status code alone is not.
	fn fail(self: *Db, response: http.Response, what: []const u8) db.Error {
		var scratch = std.heap.ArenaAllocator.init(self.allocator);
		defer scratch.deinit();
		const said = said: {
			const parsed = std.json.parseFromSliceLeaky(Json, scratch.allocator(), response.body, .{}) catch break :said "";
			const value = api.at(parsed, "message") orelse break :said "";
			break :said if (value == .string) value.string else "";
		};
		if (said.len != 0) {
			self.complain("{s}: {s}", .{ what, said });
		} else if (response.status == 401) {
			self.complain("{s} did not accept these credentials", .{what});
		} else if (response.status == 403) {
			self.complain("{s}: this account may not do that", .{what});
		} else {
			self.complain("{s}: the cluster answered {d}", .{ what, response.status });
		}
		return error.Driver;
	}

	/// The path of a resource's list, in the namespace in use.
	fn listPath(self: *Db, arena: std.mem.Allocator, resource: api.Resource, schema: []const u8) ![]const u8 {
		const namespace = if (schema.len != 0) schema else self.namespace;
		if (!resource.namespaced or namespace.len == 0 or std.mem.eql(u8, namespace, "*")) {
			return std.fmt.allocPrint(arena, "{s}/{s}", .{ resource.root, resource.name });
		}
		return std.fmt.allocPrint(arena, "{s}/namespaces/{s}/{s}", .{ resource.root, namespace, resource.name });
	}

	fn objectPath(self: *Db, arena: std.mem.Allocator, resource: api.Resource, schema: []const u8, name: []const u8) ![]const u8 {
		return std.fmt.allocPrint(arena, "{s}/{s}", .{ try self.listPath(arena, resource, schema), name });
	}

	/// Fetch a list and hand back its `items`.
	fn fetch(self: *Db, arena: std.mem.Allocator, path: []const u8, what: []const u8) db.Error![]Json {
		const response = self.call(arena, "GET", path, "") catch return error.Driver;
		if (!response.ok()) {
			return self.fail(response, what);
		}
		const parsed = std.json.parseFromSliceLeaky(Json, arena, response.body, .{}) catch {
			self.complain("{s}: the cluster answered with something that is not JSON", .{what});
			return error.Driver;
		};
		const items = api.at(parsed, "items") orelse {
			self.complain("{s}: the cluster answered without a list in it", .{what});
			return error.Driver;
		};
		if (items != .array) {
			self.complain("{s}: the cluster answered without a list in it", .{what});
			return error.Driver;
		}
		return items.array.items;
	}

	// ------------------------------------------------------------- the schema

	/// The namespaces, with the one in use first - the interface opens on the
	/// first of these, and the one the kubeconfig's context chose is the one
	/// somebody asked for.
	pub fn schemas(self: *Db, arena: std.mem.Allocator) db.Error![][]const u8 {
		self.begin();
		var out: std.ArrayListUnmanaged([]const u8) = .empty;
		try out.append(arena, try arena.dupe(u8, self.namespace));
		const items = self.fetch(arena, "/api/v1/namespaces", "the namespaces") catch {
			// A user who may not list namespaces can still work in their own, and
			// that is a common way for a cluster to be set up.
			return out.items;
		};
		for (items) |item| {
			const name = api.at(item, "metadata.name") orelse continue;
			if (name == .string and !std.mem.eql(u8, name.string, self.namespace)) {
				try out.append(arena, try arena.dupe(u8, name.string));
			}
		}
		return out.items;
	}

	pub fn objects(self: *Db, arena: std.mem.Allocator, schema: []const u8) db.Error![]db.Object {
		self.begin();
		if (schema.len != 0) {
			self.namespace = try self.home.allocator().dupe(u8, schema);
		}
		var out: std.ArrayListUnmanaged(db.Object) = .empty;
		for (api.RESOURCES) |resource| {
			try out.append(arena, .{
				.name = try arena.dupe(u8, resource.name),
				.kind = .table,
				// A count would be a request each, for every kind, on every redraw.
				.rows = null,
			});
		}
		return out.items;
	}

	pub fn columns(self: *Db, arena: std.mem.Allocator, table: db.Table) db.Error![]db.Column {
		self.begin();
		const resource = api.find(table.name) orelse {
			self.complain("there is no resource called {s}", .{table.name});
			return error.Driver;
		};
		var out: std.ArrayListUnmanaged(db.Column) = .empty;
		for (resource.columns) |column| {
			try out.append(arena, .{
				.name = try arena.dupe(u8, column.name),
				.type = if (column.numeric) "integer" else "string",
				.notnull = false,
				.pk = std.mem.eql(u8, column.name, "name"),
			});
		}
		return out.items;
	}

	pub fn indexes(_: *Db, _: std.mem.Allocator, _: db.Table) db.Error![]db.Index {
		return &.{};
	}

	pub fn foreignKeys(_: *Db, _: std.mem.Allocator, _: db.Table) db.Error![]db.ForeignKey {
		return &.{};
	}

	/// The structure view: one object of this kind, whole, as the cluster holds
	/// it. There is no CREATE statement for a resource kind; what somebody wants
	/// to see there is the shape of the thing.
	pub fn definition(self: *Db, arena: std.mem.Allocator, table: db.Table) db.Error!?[]const u8 {
		self.begin();
		const resource = api.find(table.name) orelse return null;
		const items = self.fetch(arena, try self.listPath(arena, resource, table.schema), table.name) catch return null;
		if (items.len == 0) {
			return null;
		}
		var out: List = .empty;
		try out.print(arena, "# one {s}, as the cluster holds it\n", .{resource.singular});
		var writer = std.Io.Writer.Allocating.initOwnedSlice(arena, out.items);
		std.json.Stringify.value(items[0], .{ .whitespace = .indent_tab }, &writer.writer) catch return null;
		return writer.written();
	}

	/// How many there are, but only where that is already known.
	///
	/// The object list asks this for every kind it shows, and answering it
	/// honestly would be eighteen list requests to draw a sidebar - on a real
	/// cluster that means fetching every secret and every event in the namespace
	/// before the first frame. A cluster has no cheap count: `?` is the true
	/// answer until something has actually been read. So every select leaves its
	/// count here and this hands back what it finds, which costs nothing and is
	/// right for whatever has been looked at.
	pub fn rowCount(self: *Db, table: db.Table) ?i64 {
		const key = self.countKey(self.allocator, table) catch return null;
		defer self.allocator.free(key);
		return self.counts.get(key);
	}

	fn countKey(self: *Db, allocator: std.mem.Allocator, table: db.Table) ![]u8 {
		const namespace = if (table.schema.len != 0) table.schema else self.namespace;
		return std.fmt.allocPrint(allocator, "{s}/{s}", .{ namespace, table.name });
	}

	fn forgetCount(self: *Db, table: db.Table) void {
		const key = self.countKey(self.allocator, table) catch return;
		defer self.allocator.free(key);
		_ = self.counts.remove(key);
	}

	fn rememberCount(self: *Db, table: db.Table, howMany: usize) void {
		const key = self.countKey(self.home.allocator(), table) catch return;
		self.counts.put(self.home.allocator(), key, @intCast(howMany)) catch {};
	}

	/// A row is addressed by its name, which is what a name is for in Kubernetes:
	/// unique within a kind and a namespace, and never reused while it exists.
	pub fn rowKey(_: *Db, _: std.mem.Allocator, table: db.Table) db.Error!db.RowKey {
		const resource = api.find(table.name) orelse return .{};
		for (resource.columns) |column| {
			if (std.mem.eql(u8, column.name, "name")) {
				return .{ .columns = &[_][]const u8{"name"} };
			}
		}
		return .{};
	}

	pub fn alterContext(_: *Db, _: std.mem.Allocator, _: db.Table, _: []const db.Column) db.Error!db.AlterContext {
		return .{};
	}

	pub fn settings(self: *Db, arena: std.mem.Allocator) db.Error![]db.Setting {
		self.begin();
		var out: std.ArrayListUnmanaged(db.Setting) = .empty;
		try out.append(arena, .{ .label = "context", .value = try arena.dupe(u8, self.ready.context) });
		try out.append(arena, .{ .label = "server", .value = try arena.dupe(u8, self.ready.server) });
		try out.append(arena, .{ .label = "namespace", .value = try arena.dupe(u8, self.namespace) });
		try out.append(arena, .{ .label = "version", .value = try arena.dupe(u8, self.version_text.items) });
		try out.append(arena, .{
			.label = "authentication",
			.value = if (self.ready.cert_pem.len != 0) "client certificate" else if (self.authorization.len != 0) "bearer token" else "none",
		});
		try out.append(arena, .{
			.label = "certificate",
			.value = if (self.ready.insecure) "not checked" else if (self.ready.ca_pem.len != 0) "the cluster's own authority" else "this machine's authorities",
		});
		const response = self.call(arena, "GET", "/livez", "") catch return out.items;
		try out.append(arena, .{
			.label = "health",
			.value = if (response.ok()) "ok" else try arena.dupe(u8, std.mem.trim(u8, response.body, " \r\n")),
		});
		return out.items;
	}

	pub fn inTransaction(_: *Db) bool {
		return false;
	}

	pub fn split(_: *Db, arena: std.mem.Allocator, sql: []const u8) db.Error![]db.Statement {
		var out: std.ArrayListUnmanaged(db.Statement) = .empty;
		var walk = std.mem.splitScalar(u8, sql, '\n');
		while (walk.next()) |raw| {
			const line = std.mem.trim(u8, raw, " \t\r;");
			if (line.len == 0 or std.mem.startsWith(u8, line, "#")) {
				continue;
			}
			try out.append(arena, .{ .sql = line });
		}
		return out.items;
	}

	pub fn ddl(_: *Db) db.Ddl {
		return .{ .k8s = Ddl{} };
	}

	// ---------------------------------------------------------------- the rows

	pub fn select(self: *Db, request: db.ask.Select) db.Error!?db.Rows {
		self.begin();
		const resource = api.find(request.table.name) orelse {
			self.complain("there is no resource called {s}", .{request.table.name});
			return error.Driver;
		};
		if (request.where_text.len != 0) {
			self.remember("a raw WHERE is SQL - filter on a column in the form instead");
			return error.Driver;
		}
		const arena = self.replies.allocator();
		const items = try self.fetch(arena, try self.listPath(arena, resource, request.table.schema), request.table.name);

		// Every cell of every object, then the filtering and the paging over what
		// came out. The cluster will not filter for us on anything but a field
		// selector, and a filter that worked on some columns and not others would
		// be worse than one that plainly works on all of them.
		const now = nowSeconds();
		var kept: std.ArrayListUnmanaged([]const Value) = .empty;
		for (items) |item| {
			const cells = try arena.alloc(Value, resource.columns.len);
			for (resource.columns, 0..) |column, i| {
				const written = api.cell(arena, item, column, now) catch "";
				cells[i] = if (written.len == 0) .nil else .{ .text = written };
			}
			if (!keeps(resource, cells, request)) {
				continue;
			}
			try kept.append(arena, cells);
		}
		self.rememberCount(request.table, kept.items.len);
		if (request.order.len != 0) {
			sortRows(resource, kept.items, request.order, request.descending);
		}
		if (request.count) {
			return .{ .k8s = try self.oneNumber("objects", @intCast(kept.items.len)) };
		}

		var rows = Rows{
			.owner = self,
			.names = try names(arena, resource),
			.numeric = try numerics(arena, resource),
			.table = resource.name,
		};
		const from = @min(request.offset, kept.items.len);
		const wanted = if (request.limit != 0) request.limit else kept.items.len;
		const to = @min(from + wanted, kept.items.len);
		for (kept.items[from..to]) |row| {
			try rows.rows.append(arena, row);
		}
		return .{ .k8s = rows };
	}

	pub fn count(self: *Db, request: db.ask.Select) db.Error!?db.Rows {
		var asked = request;
		asked.count = true;
		return self.select(asked);
	}

	fn oneNumber(self: *Db, label: []const u8, value: i64) db.Error!Rows {
		const arena = self.replies.allocator();
		var rows = Rows{ .owner = self, .table = "" };
		const heading = try arena.alloc([]const u8, 1);
		heading[0] = label;
		rows.names = heading;
		const flags = try arena.alloc(bool, 1);
		flags[0] = true;
		rows.numeric = flags;
		const cells = try arena.alloc(Value, 1);
		cells[0] = .{ .number = value };
		try rows.rows.append(arena, cells);
		return rows;
	}

	/// A resource is deleted, a workload is scaled, and nothing else is written.
	pub fn apply(self: *Db, change: db.ask.Change) db.Error!void {
		self.begin();
		const resource = api.find(change.table.name) orelse {
			self.complain("there is no resource called {s}", .{change.table.name});
			return error.Driver;
		};
		switch (change.kind) {
			.delete => {
				if (!resource.remove) {
					self.complain("a {s} is not something to delete", .{resource.singular});
					return error.Driver;
				}
                const name = db.ask.only(change.where, "name") orelse {
					self.remember("which one is not clear from the row");
					return error.Driver;
				};
				var scratch = std.heap.ArenaAllocator.init(self.allocator);
				defer scratch.deinit();
				const arena = scratch.allocator();
				const response = self.call(arena, "DELETE", try self.objectPath(arena, resource, change.table.schema, name), "") catch return error.Driver;
				if (!response.ok()) {
					return self.fail(response, name);
				}
				// What was counted a moment ago is now wrong by one, and `?` is a
				// better answer than a number that is off.
				self.forgetCount(change.table);
			},
			.insert => {
				self.complain(
					"an object is a document with a controller acting on it, not a row - kubectl apply is what makes one",
					.{},
				);
				return error.Driver;
			},
			.update => {
				// Only offer what this kind can actually be told to do.
				if (resource.scalable) {
					self.complain(
						"editing an object from a grid would drop every field the grid does not show - SCALE {s} <name> <n> and RESTART {s} <name> are what this does",
						.{ resource.name, resource.name },
					);
				} else {
					self.complain(
						"editing an object from a grid would drop every field the grid does not show - kubectl edit is what changes one",
						.{},
					);
				}
				return error.Driver;
			},
		}
	}

	// ------------------------------------------------------------- the console

	pub fn exec(self: *Db, line: []const u8) db.Error!void {
		var rows = try self.query(line, null);
		if (rows) |*produced| {
			produced.close();
		}
	}

	/// What the editor is on a cluster: not SQL, and it says so.
	pub fn query(self: *Db, line: []const u8, rest: ?*[]const u8) db.Error!?db.Rows {
		if (rest) |tail| {
			tail.* = "";
		}
		self.begin();
		const arena = self.replies.allocator();
		var words = std.mem.tokenizeAny(u8, line, " \t\r\n;");
		const verb = words.next() orelse return null;
		const first = words.next() orelse "";
		const second = words.next() orelse "";
		const third = words.next() orelse "";

		if (eq(verb, "CONTEXTS")) {
			return .{ .k8s = try self.listContexts(arena) };
		}
		if (eq(verb, "NAMESPACES") or eq(verb, "NS")) {
			return self.select(.{ .table = .{ .name = "namespaces" } });
		}
		if (eq(verb, "USE")) {
			if (first.len == 0) {
				self.remember("USE <namespace>");
				return error.Driver;
			}
			self.namespace = try self.home.allocator().dupe(u8, first);
			return null;
		}
		if (eq(verb, "VERSION")) {
			return .{ .k8s = try self.oneText("version", self.version_text.items) };
		}
		if (eq(verb, "GET")) {
			if (api.find(first) == null) {
				self.complain("there is nothing here called {s}", .{first});
				return error.Driver;
			}
			return self.select(.{ .table = .{ .name = first } });
		}
		if (eq(verb, "DESCRIBE")) {
			return .{ .k8s = try self.describeOne(arena, first, second) };
		}
		if (eq(verb, "LOGS")) {
			return .{ .k8s = try self.logs(arena, first, second) };
		}
		if (eq(verb, "SCALE")) {
			try self.scale(arena, first, second, third);
			return null;
		}
		if (eq(verb, "RESTART")) {
			try self.restart(arena, first, second);
			return null;
		}
		self.complain(
			"this is a cluster, not SQL - GET pods, DESCRIBE pod <name>, LOGS <pod>, SCALE deployments <name> <n>, RESTART deployments <name>, USE <namespace>, CONTEXTS, VERSION",
			.{},
		);
		return error.Driver;
	}

	fn listContexts(self: *Db, arena: std.mem.Allocator) db.Error!Rows {
		var rows = Rows{ .owner = self, .table = "" };
		const heading = try arena.alloc([]const u8, 2);
		heading[0] = "context";
		heading[1] = "in use";
		rows.names = heading;
		rows.numeric = try arena.alloc(bool, 2);
		@memset(@constCast(rows.numeric), false);

		const path = (config.find(arena, self.parts.kubeconfig) catch null) orelse return rows;
		const text = config.readFile(arena, path) catch return rows;
		var why: List = .empty;
		const doc = yaml.parse(arena, text, &why) catch return rows;
		for (config.contexts(arena, doc) catch &.{}) |name| {
			const cells = try arena.alloc(Value, 2);
			cells[0] = .{ .text = name };
			cells[1] = if (std.mem.eql(u8, name, self.ready.context)) .{ .text = "yes" } else .nil;
			try rows.rows.append(arena, cells);
		}
		return rows;
	}

	fn oneText(self: *Db, label: []const u8, value: []const u8) db.Error!Rows {
		const arena = self.replies.allocator();
		var rows = Rows{ .owner = self, .table = "" };
		const heading = try arena.alloc([]const u8, 1);
		heading[0] = label;
		rows.names = heading;
		rows.numeric = try arena.alloc(bool, 1);
		@memset(@constCast(rows.numeric), false);
		const cells = try arena.alloc(Value, 1);
		cells[0] = .{ .text = try arena.dupe(u8, value) };
		try rows.rows.append(arena, cells);
		return rows;
	}

	/// One object, whole, as JSON - which is what `describe` is for when the
	/// alternative is a screenful of fields somebody chose for you.
	fn describeOne(self: *Db, arena: std.mem.Allocator, kind: []const u8, name: []const u8) db.Error!Rows {
		const resource = api.find(kind) orelse api.find(plural(kind)) orelse {
			self.complain("there is nothing here called {s}", .{kind});
			return error.Driver;
		};
		if (name.len == 0) {
			self.complain("DESCRIBE {s} <name>", .{resource.name});
			return error.Driver;
		}
		const response = self.call(arena, "GET", try self.objectPath(arena, resource, "", name), "") catch return error.Driver;
		if (!response.ok()) {
			return self.fail(response, name);
		}
		const parsed = std.json.parseFromSliceLeaky(Json, arena, response.body, .{}) catch {
			self.remember("the cluster answered with something that is not JSON");
			return error.Driver;
		};
		var writer = std.Io.Writer.Allocating.init(arena);
		std.json.Stringify.value(parsed, .{ .whitespace = .indent_tab }, &writer.writer) catch {
			self.remember("that object cannot be written out");
			return error.Driver;
		};
		return self.lines(arena, resource.singular, writer.written());
	}

	fn logs(self: *Db, arena: std.mem.Allocator, name: []const u8, howMany: []const u8) db.Error!Rows {
		if (name.len == 0) {
			self.remember("LOGS <pod> [lines]");
			return error.Driver;
		}
		const wanted = if (howMany.len != 0) std.fmt.parseInt(usize, howMany, 10) catch LOG_LINES else LOG_LINES;
		const resource = api.find("pods").?;
		const path = try std.fmt.allocPrint(arena, "{s}/log?tailLines={d}", .{
			try self.objectPath(arena, resource, "", name),
			wanted,
		});
		const response = self.call(arena, "GET", path, "") catch return error.Driver;
		if (!response.ok()) {
			return self.fail(response, name);
		}
		return self.lines(arena, "line", response.body);
	}

	/// Text as one column of rows, so the grid can hold it and the detail box can
	/// show any line of it whole.
	fn lines(self: *Db, arena: std.mem.Allocator, label: []const u8, text: []const u8) db.Error!Rows {
		var rows = Rows{ .owner = self, .table = "" };
		const heading = try arena.alloc([]const u8, 1);
		heading[0] = label;
		rows.names = heading;
		rows.numeric = try arena.alloc(bool, 1);
		@memset(@constCast(rows.numeric), false);
		var walk = std.mem.splitScalar(u8, text, '\n');
		while (walk.next()) |one| {
			const cells = try arena.alloc(Value, 1);
			cells[0] = .{ .text = std.mem.trimEnd(u8, one, "\r") };
			try rows.rows.append(arena, cells);
		}
		return rows;
	}

	fn scale(self: *Db, arena: std.mem.Allocator, kind: []const u8, name: []const u8, howMany: []const u8) db.Error!void {
		const resource = api.find(kind) orelse api.find(plural(kind)) orelse {
			self.complain("there is nothing here called {s}", .{kind});
			return error.Driver;
		};
		if (!resource.scalable) {
			self.complain("a {s} has no replicas to change", .{resource.singular});
			return error.Driver;
		}
		if (name.len == 0 or howMany.len == 0) {
			self.complain("SCALE {s} <name> <n>", .{resource.name});
			return error.Driver;
		}
		const wanted = std.fmt.parseInt(u32, howMany, 10) catch {
			self.complain("{s} is not a number of replicas", .{howMany});
			return error.Driver;
		};
		const body = try std.fmt.allocPrint(arena, "{{\"spec\":{{\"replicas\":{d}}}}}", .{wanted});
		const response = self.call(arena, "PATCH", try self.objectPath(arena, resource, "", name), body) catch return error.Driver;
		if (!response.ok()) {
			return self.fail(response, name);
		}
	}

	/// A rolling restart is what kubectl does: an annotation with the time in it,
	/// which the controller notices and rolls the pods for. There is no restart
	/// verb in the API and there never was.
	fn restart(self: *Db, arena: std.mem.Allocator, kind: []const u8, name: []const u8) db.Error!void {
		const resource = api.find(kind) orelse api.find(plural(kind)) orelse {
			self.complain("there is nothing here called {s}", .{kind});
			return error.Driver;
		};
		if (!resource.scalable and !std.mem.eql(u8, resource.name, "daemonsets")) {
			self.complain("a {s} is not something with pods to roll", .{resource.singular});
			return error.Driver;
		}
		if (name.len == 0) {
			self.complain("RESTART {s} <name>", .{resource.name});
			return error.Driver;
		}
		const body = try std.fmt.allocPrint(
			arena,
			"{{\"spec\":{{\"template\":{{\"metadata\":{{\"annotations\":{{\"krtek.restartedAt\":\"{d}\"}}}}}}}}}}",
			.{nowSeconds()},
		);
		const response = self.call(arena, "PATCH", try self.objectPath(arena, resource, "", name), body) catch return error.Driver;
		if (!response.ok()) {
			return self.fail(response, name);
		}
	}
};

fn eq(word: []const u8, name: []const u8) bool {
	return std.ascii.eqlIgnoreCase(word, name);
}

/// `pod` for `pods`: the console takes either, because everybody types both.
fn plural(word: []const u8) []const u8 {
	var buffer: [64]u8 = undefined;
	if (word.len == 0 or word.len + 1 >= buffer.len) {
		return word;
	}
	// Only the shape kubectl's own singulars have; nothing here is irregular.
	@memcpy(buffer[0..word.len], word);
	buffer[word.len] = 's';
	const guess = buffer[0 .. word.len + 1];
	for (api.RESOURCES) |resource| {
		if (std.mem.eql(u8, resource.name, guess)) {
			return resource.name;
		}
	}
	return word;
}

fn names(arena: std.mem.Allocator, resource: api.Resource) ![]const []const u8 {
	const out = try arena.alloc([]const u8, resource.columns.len);
	for (resource.columns, 0..) |column, i| {
		out[i] = column.name;
	}
	return out;
}

fn numerics(arena: std.mem.Allocator, resource: api.Resource) ![]const bool {
	const out = try arena.alloc(bool, resource.columns.len);
	for (resource.columns, 0..) |column, i| {
		out[i] = column.numeric;
	}
	return out;
}

fn textOf(cell: Value) []const u8 {
	return switch (cell) {
		.text => |value| value,
		else => "",
	};
}

/// Whether a row survives the filter the form put together. Everything is
/// compared as the text the grid shows, which is the only thing that is true of
/// every column here - `2/3` is not a number and neither is `4d2h`.
fn keeps(resource: api.Resource, cells: []const Value, request: db.ask.Select) bool {
	if (request.where.len == 0) {
		return true;
	}
	var any = false;
	for (request.where) |filter| {
		var index: ?usize = null;
		for (resource.columns, 0..) |column, i| {
			if (std.mem.eql(u8, column.name, filter.column)) {
				index = i;
			}
		}
		const value = if (index) |i| textOf(cells[i]) else "";
        const matched = switch (filter.op) {
			.eq => std.mem.eql(u8, value, filter.value),
			.ne => !std.mem.eql(u8, value, filter.value),
			.lt => std.mem.order(u8, value, filter.value) == .lt,
			.le => std.mem.order(u8, value, filter.value) != .gt,
			.gt => std.mem.order(u8, value, filter.value) == .gt,
			.ge => std.mem.order(u8, value, filter.value) != .lt,
			.like => std.ascii.indexOfIgnoreCase(value, std.mem.trim(u8, filter.value, "%")) != null,
			.is_null => value.len == 0,
			.not_null => value.len != 0,
		};
		if (request.any) {
			any = any or matched;
		} else if (!matched) {
			return false;
		}
	}
	return if (request.any) any else true;
}

fn sortRows(resource: api.Resource, rows: [][]const Value, order: []const u8, descending: bool) void {
	var index: ?usize = null;
	for (resource.columns, 0..) |column, i| {
		if (std.mem.eql(u8, column.name, order)) {
			index = i;
		}
	}
	const at = index orelse return;
	const Context = struct {
		at: usize,
		descending: bool,
		fn less(self: @This(), a: []const Value, b: []const Value) bool {
			const left = if (self.at < a.len) textOf(a[self.at]) else "";
			const right = if (self.at < b.len) textOf(b[self.at]) else "";
			// Numbers where both sides are numbers, so 9 comes before 10.
			const first = std.fmt.parseInt(i64, left, 10) catch null;
			const other = std.fmt.parseInt(i64, right, 10) catch null;
			const order_of = if (first != null and other != null)
				std.math.order(first.?, other.?)
			else
				std.mem.order(u8, left, right);
			return if (self.descending) order_of == .gt else order_of == .lt;
		}
	};
	std.mem.sort([]const Value, rows, Context{ .at = at, .descending = descending }, Context.less);
}

fn nowSeconds() i64 {
	var moment: std.c.timespec = undefined;
	if (std.c.clock_gettime(.REALTIME, &moment) != 0) {
		return 0;
	}
	return @intCast(moment.sec);
}

pub const Rows = struct {
	owner: *Db,
	names: []const []const u8 = &.{},
	rows: std.ArrayListUnmanaged([]const Value) = .empty,
	numeric: []const bool = &.{},
	table: []const u8 = "",
	at: usize = 0,
	started: bool = false,

	pub fn next(self: *Rows) db.Error!bool {
		if (!self.started) {
			self.started = true;
		} else {
			self.at += 1;
		}
		return self.at < self.rows.items.len;
	}

	pub fn close(self: *Rows) void {
		self.at = 0;
		self.rows.clearRetainingCapacity();
	}

	pub fn columnCount(self: *Rows) usize {
		return self.names.len;
	}

	pub fn name(self: *Rows, at: usize) []const u8 {
		return if (at < self.names.len) self.names[at] else "";
	}

	pub fn value(self: *Rows, at: usize) db.Value {
		if (self.at >= self.rows.items.len) {
			return .{ .null = {} };
		}
		const row = self.rows.items[self.at];
		if (at >= row.len) {
			return .{ .null = {} };
		}
		return switch (row[at]) {
			.nil => .{ .null = {} },
			.number => |number| .{ .int = number },
			.text => |text| .{ .text = text },
		};
	}

	pub fn sourceTable(self: *Rows, _: usize) []const u8 {
		return self.table;
	}

	pub fn sourceColumn(self: *Rows, at: usize) []const u8 {
		return self.name(at);
	}

	pub fn isNumeric(self: *Rows, at: usize) bool {
		return at < self.numeric.len and self.numeric[at];
	}

	pub fn affected(_: *Rows) i64 {
		return 0;
	}
};

/// There is no DDL on a cluster: a resource kind is not something anybody creates
/// from here, and every one of these says so rather than writing a statement
/// nothing would run.
pub const Ddl = struct {
	pub fn types(_: Ddl) []const []const u8 {
		return &[_][]const u8{"string"};
	}

	pub fn createTable(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table, _: []const db.Column, _: []const db.ForeignKey) !void {
		try refuse(out, a, "resource kinds to create - what a cluster has is what its API groups say it has, and a CRD is applied with kubectl");
	}

	pub fn alterTable(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table, _: []const u8, _: []const db.Column, _: db.AlterContext) !void {
		try refuse(out, a, "columns to alter - the columns of a kind are what this program chose to show of it");
	}

	pub fn addForeignKey(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table, _: db.ForeignKey, _: db.AlterContext) !void {
		try refuse(out, a, "foreign keys - what points at what here is an owner reference, and the cluster keeps those itself");
	}

	pub fn createIndex(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table, _: []const u8, _: []const []const u8, _: bool, _: []const u8) !void {
		try refuse(out, a, "indexes - the API server has its own and they are not anybody else's to make");
	}

	pub fn createView(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table, _: []const u8) !void {
		try refuse(out, a, "views");
	}

	pub fn createTrigger(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table, _: []const u8, _: []const u8, _: []const u8, _: []const u8, _: []const u8) !void {
		try refuse(out, a, "triggers - a controller is the cluster's own version of one");
	}

	pub fn renameTable(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table, _: []const u8) !void {
		try refuse(out, a, "renaming - a name is how an object is addressed and Kubernetes will not change one");
	}

	pub fn copyTable(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table, _: []const u8, _: bool) !void {
		try refuse(out, a, "copying a kind");
	}

	pub fn dropObject(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Kind, _: db.Table) !void {
		try refuse(out, a, "dropping a kind - x deletes one object, which is the thing that can be deleted");
	}

	pub fn truncate(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table) !void {
		try refuse(out, a, "emptying a kind - deleting every object of one is not something to do by accident");
	}

	pub fn insertRow(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table, _: []const []const u8, _: []const []const u8) !void {
		try refuse(out, a, "making an object from a row - an object is a document, and kubectl apply is what writes one");
	}

	fn refuse(out: *List, a: std.mem.Allocator, what: []const u8) !void {
		try out.print(a, "a cluster has no {s}", .{what});
	}
};

const Server = struct { host: []const u8, port: u16, tls: bool };

/// `https://host:6443` taken apart. A kubeconfig always writes a scheme.
fn splitServer(url: []const u8) ?Server {
	var rest = url;
	var tls = true;
	if (std.ascii.startsWithIgnoreCase(rest, "https://")) {
		rest = rest[8..];
	} else if (std.ascii.startsWithIgnoreCase(rest, "http://")) {
		rest = rest[7..];
		tls = false;
	} else {
		return null;
	}
	if (std.mem.indexOfScalar(u8, rest, '/')) |mark| {
		rest = rest[0..mark];
	}
	if (rest.len == 0) {
		return null;
	}
	// A bracketed IPv6 literal keeps its colons.
	if (rest[0] == '[') {
		const end = std.mem.indexOfScalar(u8, rest, ']') orelse return null;
		const host = rest[1..end];
		const after = rest[end + 1 ..];
		const port = if (after.len > 1 and after[0] == ':')
			std.fmt.parseInt(u16, after[1..], 10) catch return null
		else if (tls) @as(u16, 443) else 80;
		return .{ .host = host, .port = port, .tls = tls };
	}
	if (std.mem.lastIndexOfScalar(u8, rest, ':')) |mark| {
		const port = std.fmt.parseInt(u16, rest[mark + 1 ..], 10) catch return null;
		return .{ .host = rest[0..mark], .port = port, .tls = tls };
	}
	return .{ .host = rest, .port = if (tls) 443 else 80, .tls = tls };
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

test "a cluster's address comes apart into a host and a port" {
	const cases = [_]struct { url: []const u8, host: []const u8, port: u16, tls: bool }{
		.{ .url = "https://10.0.0.1:6443", .host = "10.0.0.1", .port = 6443, .tls = true },
		.{ .url = "https://api.example.com", .host = "api.example.com", .port = 443, .tls = true },
		.{ .url = "http://127.0.0.1:8001", .host = "127.0.0.1", .port = 8001, .tls = false },
		.{ .url = "http://localhost", .host = "localhost", .port = 80, .tls = false },
		.{ .url = "https://[::1]:6443", .host = "::1", .port = 6443, .tls = true },
		.{ .url = "https://[fd00::1]", .host = "fd00::1", .port = 443, .tls = true },
		.{ .url = "https://host:6443/prefix", .host = "host", .port = 6443, .tls = true },
	};
	for (cases) |case| {
		const got = splitServer(case.url).?;
		try testing.expectEqualStrings(case.host, got.host);
		try testing.expectEqual(case.port, got.port);
		try testing.expectEqual(case.tls, got.tls);
	}
	// A scheme it does not know, or none at all, is not an address.
	try testing.expect(splitServer("10.0.0.1:6443") == null);
	try testing.expect(splitServer("ftp://host") == null);
	try testing.expect(splitServer("https://") == null);
	try testing.expect(splitServer("https://host:not-a-port") == null);
}

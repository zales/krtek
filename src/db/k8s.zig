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
const targets = @import("targets.zig");
const clock = @import("clock.zig");
const http = @import("http.zig");
const ws = @import("ws.zig");
const random = @import("random.zig");

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

/// What one context of the kubeconfig on this machine is called, and the target
/// that opens it.
pub const Context = struct {
	name: []const u8,
	target: []const u8,
	current: bool,
};

/// The contexts of the kubeconfig on this machine, for a program that wants to
/// offer them without being asked to. Nothing is connected to and no credential
/// plugin is run: this reads one file and gives back names.
///
/// It never fails. A machine with no kubeconfig, or one this reader cannot make
/// sense of, has no contexts to offer - which is not an error on a screen that
/// was showing a list of databases.
pub fn contexts(arena: std.mem.Allocator) []const Context {
	const path = (config.find(arena, "") catch null) orelse return &.{};
	const text = targets.readFile(arena, path) catch return &.{};
	var why: List = .empty;
	const doc = yaml.parse(arena, text, &why) catch return &.{};
	const current = (doc.get("current-context") orelse yaml.Value{ .scalar = "" }).text();
	var out: std.ArrayListUnmanaged(Context) = .empty;
	for (config.contexts(arena, doc) catch &.{}) |name| {
		// A context name may hold a slash - an EKS one is an ARN and always does -
		// and the last slash in a target is where the namespace begins. Escaped
		// here, so what comes back out the other side is the name that went in.
		const target = escapedTarget(arena, name) catch continue;
		out.append(arena, .{
			.name = name,
			.target = target,
			.current = std.mem.eql(u8, name, current),
		}) catch continue;
	}
	return out.items;
}

fn escapedTarget(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
	var out: List = .empty;
	try out.appendSlice(arena, "k8s://");
	for (name) |char| {
		switch (char) {
			'/' => try out.appendSlice(arena, "%2F"),
			'?', '%', '#' => try out.print(arena, "%{X:0>2}", .{char}),
			else => try out.append(arena, char),
		}
	}
	return out.items;
}

/// How much of a list this driver will hold. A namespace with more objects than
/// this in it is one nobody browses; the message says what happened rather than
/// the grid quietly ending early.
const LIST_LIMIT: usize = 32 << 20;
/// How many lines of a pod's log `LOGS` asks for when nobody said.
/// Where metrics-server answers, when a cluster has one.
const METRICS = "/apis/metrics.k8s.io/v1beta1";

const LOG_LINES: usize = 200;

/// Why an object is not made or changed from a grid. Said by `caps` before
/// anything is typed and by `apply` if anything asks anyway, from one text.
const NO_INSERT = "an object is a document with a controller acting on it, not a row - kubectl apply is what makes one";
const NO_UPDATE = "editing an object from a grid would drop every field the grid does not show - SCALE and RESTART are what this does";

pub const Value = union(enum) {
	nil,
	number: i64,
	text: []const u8,

	/// What this means to the grid. The one thing a driver's own value type
	/// has to say for itself; the walking and holding is db.Built's.
	pub fn asValue(self: @This()) db.Value {
		return switch (self) {
			.nil => .{ .null = {} },
			.number => |number| .{ .int = number },
			.text => |text| .{ .text = text },
		};
	}
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
	/// The shell open in a container, if one is. One at a time and it stays open,
	/// so `cd /var/log` and then `ls` mean what they say - which is the whole
	/// difference between a shell and a way of running one command.
	session: ?*Shell = null,
	session_pod: []const u8 = "",
	/// What the shell is asked to print when a command is done. Random per
	/// session, because a command whose own output contained the marker would
	/// otherwise look like a command that had finished.
	session_marker: [24]u8 = undefined,
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
		const text = targets.readFile(home, path) catch {
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
		self.closeSession();
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
			.no_ddl = "a cluster's kinds are what its API groups say they are - none of them is made, altered or dropped from here",
			.no_insert = NO_INSERT,
			.no_update = NO_UPDATE,
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
		return self.callAs(arena, method, path, body, "application/merge-patch+json");
	}

	fn callAs(self: *Db, arena: std.mem.Allocator, method: []const u8, path: []const u8, body: []const u8, content_type: []const u8) !http.Response {
		var headers: std.ArrayListUnmanaged(http.Header) = .empty;
		try headers.append(arena, .{ .name = "Accept", .value = "application/json" });
		if (self.authorization.len != 0) {
			try headers.append(arena, .{ .name = "Authorization", .value = self.authorization });
		}
		if (body.len != 0) {
			try headers.append(arena, .{ .name = "Content-Type", .value = content_type });
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
				.group = resource.group,
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

	// ------------------------------------------------------- one object, opened

	/// What is worth knowing about one object: the columns the grid was showing,
	/// then what its containers are doing and what the last one died of, then
	/// what the cluster has said about it lately. Which is `WHY`, laid out as
	/// facts rather than as rows, and for every kind rather than only for a pod.
	pub fn rowDetail(self: *Db, arena: std.mem.Allocator, table: db.Table, name: []const u8) db.Error!?[]db.Setting {
		const resource = api.find(table.name) orelse return null;
		if (name.len == 0) {
			return null;
		}
		const response = self.call(arena, "GET", try self.objectPath(arena, resource, table.schema, name), "") catch return null;
		if (!response.ok()) {
			return null;
		}
		const object = std.json.parseFromSliceLeaky(Json, arena, response.body, .{}) catch return null;

		var out: std.ArrayListUnmanaged(db.Setting) = .empty;
		const now = nowSeconds();
		for (resource.columns) |column| {
			const said = api.cell(arena, object, column, now) catch "";
			if (said.len != 0) {
				try out.append(arena, .{ .label = column.name, .value = said });
			}
		}
		const namespace = textAt(object, "metadata.namespace");
		if (namespace.len != 0) {
			try out.append(arena, .{ .label = "namespace", .value = namespace });
		}
		const labels = api.cell(arena, object, .{ .name = "labels", .from = .labels }, now) catch "";
		if (labels.len != 0) {
			try out.append(arena, .{ .label = "labels", .value = labels });
		}

		// What each container is doing, and what the one before it died of - the
		// part a count of restarts cannot tell anybody.
		if (api.at(object, "status.containerStatuses")) |statuses| {
			if (statuses == .array) {
				for (statuses.array.items) |one| {
					try out.append(arena, .{ .label = "", .value = "" });
					try out.append(arena, .{ .label = "container", .value = textAt(one, "name") });
					try out.append(arena, .{ .label = "  image", .value = textAt(one, "image") });
					try out.append(arena, .{ .label = "  state", .value = try state(arena, api.at(one, "state")) });
					const restarts = api.at(one, "restartCount");
					const total: i64 = if (restarts) |value| (if (value == .integer) value.integer else 0) else 0;
					if (total != 0) {
						try out.append(arena, .{
							.label = "  restarts",
							.value = try std.fmt.allocPrint(arena, "{d}", .{total}),
						});
						try out.append(arena, .{ .label = "  last exit", .value = try state(arena, api.at(one, "lastState")) });
					}
				}
			}
		}

		const path = try std.fmt.allocPrint(arena, "/api/v1/namespaces/{s}/events?fieldSelector=involvedObject.name%3D{s}", .{
			if (namespace.len != 0) namespace else self.namespace,
			name,
		});
		const events = self.fetch(arena, path, "the events") catch &[_]Json{};
		if (events.len != 0) {
			try out.append(arena, .{ .label = "", .value = "" });
		}
		for (events) |event| {
			try out.append(arena, .{
				.label = try std.fmt.allocPrint(arena, "{s}", .{textAt(event, "reason")}),
				.value = textAt(event, "message"),
			});
		}
		return out.items;
	}

	/// What can be done to it. Every one of these is a line of this driver's own
	/// console, so the interface runs what it is given and knows nothing about
	/// what a log or a shell is.
	pub fn rowActions(self: *Db, arena: std.mem.Allocator, table: db.Table, name: []const u8) db.Error![]db.Action {
		_ = self;
		const resource = api.find(table.name) orelse return &.{};
		if (name.len == 0) {
			return &.{};
		}
		var out: std.ArrayListUnmanaged(db.Action) = .empty;
		if (resource.loggable) {
			try out.append(arena, .{
				.key = 'l',
				.label = "logs",
				.statement = try std.fmt.allocPrint(arena, "LOGS {s} 500", .{name}),
			});
			try out.append(arena, .{
				.key = 's',
				.label = "shell",
				.statement = try std.fmt.allocPrint(arena, "EXEC {s}", .{name}),
			});
			try out.append(arena, .{
				.key = 't',
				.label = "terminal",
				.statement = try std.fmt.allocPrint(arena, "EXEC -t {s}", .{name}),
				.terminal = true,
			});
		}
		if (resource.scalable or std.mem.eql(u8, resource.name, "daemonsets")) {
			try out.append(arena, .{
				.key = 'R',
				.label = "restart",
				.statement = try std.fmt.allocPrint(arena, "RESTART {s} {s}", .{ resource.name, name }),
				.confirm = true,
			});
		}
		try out.append(arena, .{
			.key = 'y',
			.label = "as JSON",
			.statement = try std.fmt.allocPrint(arena, "DESCRIBE {s} {s}", .{ resource.name, name }),
		});
		if (resource.remove) {
			try out.append(arena, .{
				.key = 'x',
				.label = try std.fmt.allocPrint(arena, "delete this {s}", .{resource.singular}),
				.statement = try std.fmt.allocPrint(arena, "DELETE {s} {s}", .{ resource.name, name }),
				.confirm = true,
			});
		}
		return out.items;
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

	/// One command to a line - except `APPLY`, which takes everything under it.
	/// A manifest is lines, and lines here are commands, so the two would eat each
	/// other: `kind: Pod` is not a command and never was one.
	pub fn split(_: *Db, arena: std.mem.Allocator, sql: []const u8) db.Error![]db.Statement {
		var out: std.ArrayListUnmanaged(db.Statement) = .empty;
		if (isApply(sql)) {
			try out.append(arena, .{ .sql = sql });
			return out.items;
		}
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

	/// Whether running this needs asking about first, and what to call it. A
	/// manifest can make and overwrite anything in it, which is not something to
	/// find out about afterwards.
	pub fn confirming(self: *Db, statement: []const u8) ?[]const u8 {
		if (self.session != null or !isApply(statement)) {
			return null;
		}
		return "apply this manifest";
	}

	/// The console verbs that only look. `SCALE`, `RESTART` and `USE` change
	/// something and are left out, so a grid of theirs is not repeated on a clock.
	pub fn repeatable(_: *Db, statement: []const u8) bool {
		var words = std.mem.tokenizeAny(u8, statement, " \t\r\n;");
		const verb = words.next() orelse return false;
		for ([_][]const u8{ "GET", "DESCRIBE", "LOGS", "WHY", "CONTEXTS", "NAMESPACES", "NS", "VERSION", "CLUSTER", "TOP" }) |reading| {
			if (eq(verb, reading)) {
				return true;
			}
		}
		return false;
	}

	/// Whether this statement wants the terminal rather than the grid. Only the
	/// one that asks for it in so many words: an ordinary `EXEC` keeps a shell
	/// open here and shows what it says in the grid, which is where everything
	/// else in this program shows what it has to say.
	pub fn wantsTerminal(self: *Db, statement: []const u8) bool {
		// Not while a shell is open: everything typed then is for that shell, and
		// a line that quietly meant something else instead would be the one thing
		// a shell must never do.
		if (self.session != null) {
			return false;
		}
		var words = std.mem.tokenizeAny(u8, statement, " \t\r\n;");
		const verb = words.next() orelse return false;
		if (!eq(verb, "EXEC")) {
			return false;
		}
		const next = words.next() orelse return false;
		return std.mem.eql(u8, next, "-t");
	}

	// ---------------------------------------------------------- the one shell

	/// Open a shell in a container and keep it. The session is the point: a
	/// command runs where the last one left it, so `cd` and an exported variable
	/// last as long as the shell does.
	///
	/// No tty on this one, unlike the handover. A pty would echo everything back
	/// and wrap it at whatever width it was told, and what is wanted here is what
	/// the command printed and nothing else.
	fn openSession(self: *Db, pod: []const u8) db.Error!void {
		self.closeSession();
		var scratch = std.heap.ArenaAllocator.init(self.allocator);
		defer scratch.deinit();
		const arena = scratch.allocator();

		const target = try std.fmt.allocPrint(
			arena,
			"/api/v1/namespaces/{s}/pods/{s}/exec?stdin=true&stdout=true&stderr=true&tty=false&command=sh",
			.{ self.namespace, pod },
		);
		const opened = try self.dial(arena, target, pod);
		self.session = opened;
		self.session_pod = try self.home.allocator().dupe(u8, pod);

		// A marker nothing is going to print by accident.
		var nonce: [9]u8 = undefined;
		random.bytes(&nonce) catch {
			@memset(&nonce, 7);
		};
		var hex: [18]u8 = undefined;
		for (nonce, 0..) |byte, i| {
			_ = std.fmt.bufPrint(hex[i * 2 ..][0..2], "{x:0>2}", .{byte}) catch {};
		}
		// Zeroed first: what is written is read back with `sliceTo`, and an
		// unwritten tail of an undefined array is whatever was on the stack.
		@memset(&self.session_marker, 0);
		_ = std.fmt.bufPrint(&self.session_marker, "@@{s}@@", .{hex}) catch {};
	}

	pub fn closeSession(self: *Db) void {
		if (self.session) |running| {
			running.deinit();
			self.allocator.destroy(running);
		}
		self.session = null;
		self.session_pod = "";
	}

	/// Whether a shell is open, and in which container - for an interface that
	/// has to say where what is typed is going.
	pub fn sessionIn(self: *Db) []const u8 {
		return if (self.session != null) self.session_pod else "";
	}

	/// Run one command in the open shell and give back what it said.
	///
	/// The shell is asked to print a marker and the exit status after every
	/// command, which is how a session that never ends says a command has ended.
	/// Without it there is no such thing: a shell's output stops when it stops,
	/// and a reader can only guess whether more is coming.
	fn runInSession(self: *Db, line: []const u8) db.Error!Rows {
		const running = self.session orelse return error.Driver;
		const arena = self.replies.allocator();
		const marker = std.mem.sliceTo(&self.session_marker, 0);
		const sent = try std.fmt.allocPrint(arena, "{s}\nprintf '\\n%s %d\\n' '{s}' \"$?\"\n", .{ line, marker });
		running.write(sent) catch {
			self.remember("the shell has gone");
			self.closeSession();
			return error.Driver;
		};

		var out: List = .empty;
		const started = nowSeconds();
		var status: []const u8 = "";
		var ended = false;
        while (!ended) {
			if (!(running.read(&out) catch false)) {
				// The shell itself ended - `exit` typed into it, or the container
				// went away. What it managed to say still counts.
				self.closeSession();
				break;
			}
			if (findMarker(out.items, marker)) |found| {
				status = try arena.dupe(u8, found.status);
				out.shrinkRetainingCapacity(found.at);
				ended = true;
				break;
			}
			if (nowSeconds() - started > SESSION_SECONDS) {
				self.complain(
					"it is still running after {d} seconds - the shell is still open, and EXEC -t {s} gives it the terminal",
					.{ SESSION_SECONDS, self.session_pod },
				);
				return error.Driver;
			}
			if (self.progress) |watching| {
				if (!watching.call()) {
					self.remember("stopped waiting; the command is still running in the container");
					return error.Driver;
				}
			}
		}
		// Into the arena the rows live in before the buffer goes: `lines` points at
		// what it is given rather than copying it, and what it was given here is
		// about to be freed.
		// A status that is not zero is said in the output, where somebody is
		// already looking, and in brackets so it reads as this program's voice
		// rather than the command's. The interface's own status line is taken by
		// the batch that ran, and a command that failed with output is not a
		// failure to report there: the output is the point.
		if (status.len != 0 and !std.mem.eql(u8, status, "0")) {
			try out.print(self.allocator, "\n[exit {s}]", .{status});
		}
		const said = try arena.dupe(u8, std.mem.trimEnd(u8, out.items, "\n"));
		out.deinit(self.allocator);
		return try self.lines(arena, "output", std.mem.trimStart(u8, said, "\n"));
	}

	/// Open a shell in a container: `EXEC <pod> [command...]`, and `sh` where no
	/// command was named, because that is what anybody means.
	pub fn shell(self: *Db, statement: []const u8) db.Error!?db.Shell {
		self.begin();
		var scratch = std.heap.ArenaAllocator.init(self.allocator);
		defer scratch.deinit();
		const arena = scratch.allocator();

		var words = std.mem.tokenizeAny(u8, statement, " \t\r\n;");
		_ = words.next();
		_ = words.next(); // -t, which is what brought this here
		const pod = words.next() orelse {
			self.remember("EXEC -t <pod> [command] - the terminal, for something full screen");
			return error.Driver;
		};

		var target: List = .empty;
		try target.print(arena, "/api/v1/namespaces/{s}/pods/{s}/exec?stdin=true&stdout=true&stderr=true&tty=true", .{
			self.namespace,
			pod,
		});
		var commands: usize = 0;
		while (words.next()) |word| {
			try target.print(arena, "&command={s}", .{try escapedQuery(arena, word)});
			commands += 1;
		}
		if (commands == 0) {
			// Not bash: a great many images have only the one shell, and asking
			// for the one that is not there is a session that ends at once.
			try target.appendSlice(arena, "&command=sh");
		}

		return .{ .k8s = try self.dial(arena, target.items, pod) };
	}

	/// Open a WebSocket to an exec endpoint, however it was addressed.
	fn dial(self: *Db, arena: std.mem.Allocator, target: []const u8, pod: []const u8) db.Error!*Shell {
		const server = splitServer(self.ready.server) orelse return error.Driver;
		var headers: std.ArrayListUnmanaged([2][]const u8) = .empty;
		if (self.authorization.len != 0) {
			try headers.append(arena, .{ "Authorization", self.authorization });
		}
		var why: List = .empty;
		const socket = ws.connect(self.allocator, .{
			.host = server.host,
			.port = server.port,
			.use_tls = server.tls,
			.tls = .{
				.verify = !self.ready.insecure,
				.ca_pem = self.ready.ca_pem,
				.cert_pem = self.ready.cert_pem,
				.key_pem = self.ready.key_pem,
			},
			.target = target,
			// The framing kubectl has used since 1.10, and the one every cluster
			// that speaks WebSocket at all speaks.
			.protocol = "v4.channel.k8s.io",
			.headers = headers.items,
			// A shell waits on the person at the keyboard, so the socket must not
			// sit on a read: this is the tick of the loop that pumps it.
			.timeout_ms = 50,
		}, &why) catch {
			self.complain("{s}: {s}", .{ pod, if (why.items.len != 0) why.items else "the cluster would not open a shell" });
			return error.Driver;
		};
		const opened = try self.allocator.create(Shell);
		opened.* = .{ .allocator = self.allocator, .socket = socket };
		return opened;
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
				self.remember(NO_INSERT);
				return error.Driver;
			},
			.update => {
				// Only name what this kind can actually be told to do.
				if (resource.scalable) {
					self.complain(
						"{s}: SCALE {s} <name> <n>, RESTART {s} <name>",
						.{ NO_UPDATE, resource.name, resource.name },
					);
				} else {
					self.remember(NO_UPDATE);
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
		// While a shell is open, what is typed is for it. Only the word that
		// closes it is read here, because a shell nobody can leave is a trap.
		if (self.session != null) {
			if (eq(verb, "EXIT") or eq(verb, "QUIT")) {
				const was = try arena.dupe(u8, self.session_pod);
				self.closeSession();
				return .{ .k8s = try self.oneText("shell", try std.fmt.allocPrint(arena, "the shell in {s} is closed", .{was})) };
			}
			return .{ .k8s = try self.runInSession(std.mem.trim(u8, line, " \t\r\n;")) };
		}
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
		if (eq(verb, "CLUSTER")) {
			return .{ .k8s = try self.cluster(arena) };
		}
		if (eq(verb, "TOP")) {
			return .{ .k8s = try self.top(arena, first) };
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
		if (eq(verb, "WHY")) {
			return .{ .k8s = try self.whyPod(arena, first) };
		}
		if (eq(verb, "EXEC")) {
			if (first.len == 0) {
				self.remember("EXEC <pod> - opens a shell there and keeps it; EXIT closes it");
				return error.Driver;
			}
			try self.openSession(first);
			return .{ .k8s = try self.oneText("shell", try std.fmt.allocPrint(
				arena,
				"a shell is open in {s} - what you type goes there until EXIT",
				.{first},
			)) };
		}
		if (eq(verb, "APPLY")) {
			return .{ .k8s = try self.applyManifest(arena, line) };
		}
		if (eq(verb, "DELETE")) {
			const resource = api.find(first) orelse api.find(plural(first)) orelse {
				self.complain("there is nothing here called {s}", .{first});
				return error.Driver;
			};
			if (second.len == 0) {
				self.complain("DELETE {s} <name>", .{resource.name});
				return error.Driver;
			}
			try self.apply(.{
				.kind = .delete,
				.table = .{ .name = resource.name },
				.where = &[_]db.ask.Filter{.{ .column = "name", .value = second }},
			});
			return .{ .k8s = try self.oneText("gone", try std.fmt.allocPrint(arena, "{s} {s} is deleted", .{ resource.singular, second })) };
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
			"this is a cluster, not SQL - GET pods, WHY <pod>, LOGS <pod>, EXEC <pod>, DESCRIBE pod <name>, SCALE deployments <name> <n>, RESTART deployments <name>, USE <namespace>, CLUSTER, TOP nodes, CONTEXTS, VERSION",
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
		const text = targets.readFile(arena, path) catch return rows;
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

	/// Why a pod is unhappy, in the order somebody asks it: what it is doing, what
	/// each of its containers is doing, what the last one to die died of, and what
	/// the cluster has said about it lately.
	///
	/// The restart reason is the part that is nowhere else. A count of seven
	/// restarts does not say whether it ran out of memory or exited 1, and that is
	/// in `lastState.terminated` - the state before the one it is in now, which is
	/// the only record of a container that no longer exists.
	fn whyPod(self: *Db, arena: std.mem.Allocator, name: []const u8) db.Error!Rows {
		if (name.len == 0) {
			self.remember("WHY <pod>");
			return error.Driver;
		}
		const resource = api.find("pods").?;
		const response = self.call(arena, "GET", try self.objectPath(arena, resource, "", name), "") catch return error.Driver;
		if (!response.ok()) {
			return self.fail(response, name);
		}
		const pod = std.json.parseFromSliceLeaky(Json, arena, response.body, .{}) catch {
			self.remember("the cluster answered with something that is not JSON");
			return error.Driver;
		};

		var rows = Rows{ .owner = self, .table = "" };
		const heading = try arena.alloc([]const u8, 2);
		heading[0] = "what";
		heading[1] = "said";
		rows.names = heading;
		rows.numeric = try arena.alloc(bool, 2);
		@memset(@constCast(rows.numeric), false);

		try self.pair(arena, &rows, "status", try api.cell(arena, pod, .{ .name = "s", .from = .pod_status }, nowSeconds()));
		try self.pair(arena, &rows, "phase", textAt(pod, "status.phase"));
		try self.pair(arena, &rows, "node", textAt(pod, "spec.nodeName"));
		try self.pair(arena, &rows, "started", textAt(pod, "status.startTime"));
		if (textAt(pod, "status.message").len != 0) {
			try self.pair(arena, &rows, "message", textAt(pod, "status.message"));
		}

		// What each container is doing, and what the one before it died of.
		if (api.at(pod, "status.containerStatuses")) |statuses| {
			if (statuses == .array) {
				for (statuses.array.items) |one| {
					const container = textAt(one, "name");
					try self.pair(arena, &rows, "container", container);
					try self.pair(arena, &rows, "  state", try state(arena, api.at(one, "state")));
					const restarts = api.at(one, "restartCount");
					const total: i64 = if (restarts) |value| (if (value == .integer) value.integer else 0) else 0;
					if (total != 0) {
						try self.pair(arena, &rows, "  restarts", try std.fmt.allocPrint(arena, "{d}", .{total}));
						try self.pair(arena, &rows, "  last exit", try state(arena, api.at(one, "lastState")));
						const said = textAt(api.at(one, "lastState") orelse Json{ .null = {} }, "terminated.message");
						if (said.len != 0) {
							try self.pair(arena, &rows, "  last said", said);
						}
					}
				}
			}
		}

		// And what the cluster has been saying about it, which is where a pull
		// failure or a failed mount is written down and nowhere else.
		const namespace = textAt(pod, "metadata.namespace");
		const path = try std.fmt.allocPrint(arena, "/api/v1/namespaces/{s}/events?fieldSelector=involvedObject.name%3D{s}", .{
			if (namespace.len != 0) namespace else self.namespace,
			name,
		});
		const events = self.fetch(arena, path, "the events") catch &[_]Json{};
        for (events) |event| {
			const reason = textAt(event, "reason");
			try self.pair(arena, &rows, try std.fmt.allocPrint(arena, "event {s}", .{reason}), textAt(event, "message"));
		}
		if (events.len == 0) {
			try self.pair(arena, &rows, "events", "none the cluster still has");
		}
		return rows;
	}

	// ------------------------------------------------------------ applying YAML

	/// `APPLY`, and the manifest written under it.
	///
	/// The document goes to the cluster as it stands. Kubernetes takes YAML for a
	/// server-side apply - `application/apply-patch+yaml` - and does the merging
	/// itself, which is both less code here and better behaved than a read, a
	/// change and a write from this end: two people applying different fields of
	/// the same object do not overwrite each other, and the server keeps track of
	/// which of them owns what.
	///
	/// So what is read here is only enough to know where to send it: the
	/// apiVersion, the kind and the name. Everything else is the server's to
	/// understand, including every part of YAML this program's own reader does
	/// not - a manifest is not a kubeconfig and there is no reason for it to be
	/// limited to what one needs.
	fn applyManifest(self: *Db, arena: std.mem.Allocator, line: []const u8) db.Error!Rows {
		const body = afterVerb(line);
		if (std.mem.trim(u8, body, " \t\r\n").len == 0) {
			self.remember("APPLY, and the manifest under it - several documents separated by --- are all applied");
			return error.Driver;
		}

		var rows = Rows{ .owner = self, .table = "" };
		const heading = try arena.alloc([]const u8, 2);
		heading[0] = "object";
		heading[1] = "what happened";
		rows.names = heading;
		rows.numeric = try arena.alloc(bool, 2);
		@memset(@constCast(rows.numeric), false);

		var failures: usize = 0;
		var documents = splitDocuments(body);
		while (documents.next()) |document| {
			if (std.mem.trim(u8, document, " \t\r\n-").len == 0) {
				continue;
			}
			const said = self.applyOne(arena, document, &rows) catch {
				failures += 1;
				continue;
			};
			_ = said;
		}
		// A batch where nothing at all landed is a failure, not a report of one.
		if (rows.rows.items.len == 0) {
			if (self.last_error.items.len == 0) {
				self.remember("there is no object in that - a manifest needs apiVersion, kind and metadata.name");
			}
			return error.Driver;
		}
		return rows;
	}

	fn applyOne(self: *Db, arena: std.mem.Allocator, document: []const u8, rows: *Rows) db.Error!void {
		var why: List = .empty;
		const parsed = yaml.parse(arena, document, &why) catch {
			try self.note(arena, rows, "?", try std.fmt.allocPrint(arena, "not read: {s}", .{why.items}));
			return error.Driver;
		};
		const api_version = (parsed.get("apiVersion") orelse yaml.Value{ .scalar = "" }).text();
		const kind = (parsed.get("kind") orelse yaml.Value{ .scalar = "" }).text();
		const name = (parsed.at("metadata.name") orelse yaml.Value{ .scalar = "" }).text();
		if (api_version.len == 0 or kind.len == 0 or name.len == 0) {
			try self.note(arena, rows, "?", "a document needs apiVersion, kind and metadata.name");
			return error.Driver;
		}
		const label = try std.fmt.allocPrint(arena, "{s}/{s}", .{ kind, name });

		// Where it lives: the table where this program knows the kind, and the
		// ordinary pluralisation where it does not - a custom resource, mostly.
		const known = api.findKind(kind);
		const root = if (known) |resource| resource.root else try api.rootOf(arena, api_version);
		const in_path = if (known) |resource| resource.name else try api.guessPlural(arena, kind);
		const namespaced = if (known) |resource| resource.namespaced else true;
		const namespace = blk: {
			const said = (parsed.at("metadata.namespace") orelse yaml.Value{ .scalar = "" }).text();
			break :blk if (said.len != 0) said else self.namespace;
		};

		const path = if (namespaced)
			try std.fmt.allocPrint(arena, "{s}/namespaces/{s}/{s}/{s}?fieldManager=krtek&force=true", .{ root, namespace, in_path, name })
		else
			try std.fmt.allocPrint(arena, "{s}/{s}/{s}?fieldManager=krtek&force=true", .{ root, in_path, name });

		const response = self.callAs(arena, "PATCH", path, document, "application/apply-patch+yaml") catch {
			try self.note(arena, rows, label, self.message());
			return error.Driver;
		};
		if (!response.ok()) {
			self.fail(response, label) catch {};
			// A kind this program does not know was sent to a path guessed from
			// its name, so a 404 is as likely to be the guess as the cluster.
			if (response.status == 404 and known == null) {
				try self.note(arena, rows, label, try std.fmt.allocPrint(
					arena,
					"{s} - nothing is served at {s}/{s}, so either the kind is not installed or it is not called that",
					.{ self.message(), root, in_path },
				));
			} else {
				try self.note(arena, rows, label, self.message());
			}
			return error.Driver;
		}
		// The server says 201 where it made one and 200 where it did not.
		try self.note(arena, rows, label, if (response.status == 201) "created" else "configured");
		self.forgetCount(.{ .name = in_path, .schema = namespace });
	}

	fn note(self: *Db, arena: std.mem.Allocator, rows: *Rows, what: []const u8, said: []const u8) db.Error!void {
		_ = self;
		const cells = try arena.alloc(Value, 2);
		cells[0] = .{ .text = what };
		cells[1] = .{ .text = try arena.dupe(u8, said) };
		try rows.rows.append(arena, cells);
	}

	fn pair(self: *Db, arena: std.mem.Allocator, rows: *Rows, what: []const u8, said: []const u8) db.Error!void {
		_ = self;
		const cells = try arena.alloc(Value, 2);
		cells[0] = .{ .text = what };
		cells[1] = if (said.len == 0) .nil else .{ .text = said };
		try rows.rows.append(arena, cells);
	}

	/// What the cluster is and what it has: the version, how many nodes are ready
	/// out of how many there are, what they have between them, and how much of
	/// that the pods on them have asked for.
	///
	/// Asked for rather than used: what a pod requests is what the scheduler
	/// placed it by and what it is guaranteed, and it is in the API for nothing
	/// extra. What is actually being burned needs metrics-server, which a cluster
	/// may not have - `TOP` is that question, and says so where it cannot answer.
	fn cluster(self: *Db, arena: std.mem.Allocator) db.Error!Rows {
		var rows = Rows{ .owner = self, .table = "" };
		const heading = try arena.alloc([]const u8, 2);
		heading[0] = "what";
		heading[1] = "value";
		rows.names = heading;
		rows.numeric = try arena.alloc(bool, 2);
		@memset(@constCast(rows.numeric), false);

		try self.pair(arena, &rows, "version", self.version_text.items);
		try self.pair(arena, &rows, "context", self.parts.context);

		const nodes = api.find("nodes").?;
		const found = try self.fetch(arena, try self.listPath(arena, nodes, ""), "nodes");
		var ready: usize = 0;
		var cpu: i64 = 0;
		var memory: i64 = 0;
		var room: i64 = 0;
		for (found) |node| {
			if (isReady(node)) {
				ready += 1;
			}
			cpu += quantityAt(node, "status.allocatable.cpu");
			memory += quantityAt(node, "status.allocatable.memory");
			room += quantityAt(node, "status.allocatable.pods");
		}
		try self.pair(arena, &rows, "nodes", try std.fmt.allocPrint(arena, "{d} ready of {d}", .{ ready, found.len }));
		try self.pair(arena, &rows, "cpu", try api.coresText(arena, cpu));
		try self.pair(arena, &rows, "memory", try api.bytesText(arena, memory));

		// Every namespace, because a cluster's load is not the load in whichever
		// namespace somebody happens to be looking at.
		const pods = api.find("pods").?;
		const all = try self.fetch(arena, try std.fmt.allocPrint(arena, "{s}/{s}", .{ pods.root, pods.name }), "pods");
		var running: usize = 0;
		var wanted_cpu: i64 = 0;
		var wanted_memory: i64 = 0;
		for (all) |pod| {
			if (eq(textAt(pod, "status.phase"), "Running")) {
				running += 1;
			}
			wanted_cpu += askedTotal(pod, "cpu");
			wanted_memory += askedTotal(pod, "memory");
		}
		try self.pair(arena, &rows, "pods", try std.fmt.allocPrint(arena, "{d} running of {d}, room for {d}", .{
			running,
			all.len,
			@divTrunc(room, 1000),
		}));
		try self.pair(arena, &rows, "cpu requested", try shareText(arena, wanted_cpu, cpu, .cores));
		try self.pair(arena, &rows, "memory requested", try shareText(arena, wanted_memory, memory, .bytes));
		return rows;
	}

	/// What is actually being used, as against what was asked for.
	///
	/// This is the one thing here that a cluster may simply not know. The numbers
	/// come from metrics-server, which is an add-on: it is on every managed
	/// cluster and on hardly any local one, and where it is missing the API says
	/// so with a 404 rather than with an empty answer. That is worth passing on in
	/// those words, because "0 cores" and "nobody is measuring" look alike on a
	/// screen and mean opposite things.
	fn top(self: *Db, arena: std.mem.Allocator, what: []const u8) db.Error!Rows {
		const pods = what.len != 0 and (eq(what, "pods") or eq(what, "pod"));
		if (what.len != 0 and !pods and !eq(what, "nodes") and !eq(what, "node")) {
			self.remember("TOP nodes, or TOP pods");
			return error.Driver;
		}
		const path = if (pods)
			if (self.namespace.len == 0 or eq(self.namespace, "*"))
				try std.fmt.allocPrint(arena, "{s}/pods", .{METRICS})
			else
				try std.fmt.allocPrint(arena, "{s}/namespaces/{s}/pods", .{ METRICS, self.namespace })
		else
			try std.fmt.allocPrint(arena, "{s}/nodes", .{METRICS});

		const response = self.call(arena, "GET", path, "") catch return error.Driver;
		if (response.status == 404) {
			self.remember("this cluster has no metrics-server, so nothing is measuring what is being used");
			return error.Driver;
		}
		if (!response.ok()) {
			return self.fail(response, if (pods) "pods" else "nodes");
		}
		const parsed = std.json.parseFromSliceLeaky(Json, arena, response.body, .{}) catch {
			self.remember("the cluster answered with something that is not JSON");
			return error.Driver;
		};
		const items = switch (api.at(parsed, "items") orelse Json{ .null = {} }) {
			.array => |list| list.items,
			else => &[_]Json{},
		};

		var rows = Rows{ .owner = self, .table = "" };
		const heading = try arena.alloc([]const u8, if (pods) 5 else 3);
		heading[0] = "name";
		heading[1] = "cpu";
		heading[2] = "memory";
		if (pods) {
			heading[3] = "cpu asked";
			heading[4] = "memory asked";
		}
		rows.names = heading;
		rows.numeric = try arena.alloc(bool, heading.len);
		@memset(@constCast(rows.numeric), false);

		// The spec of a pod is in a different call from its usage, so what it
		// asked for is looked up once for the whole page rather than per row.
		const specs = if (pods)
			self.fetch(arena, try self.listPath(arena, api.find("pods").?, ""), "pods") catch &[_]Json{}
		else
			&[_]Json{};

		for (items) |item| {
			const name = textAt(item, "metadata.name");
			var cpu: i64 = 0;
			var memory: i64 = 0;
			if (pods) {
				// A pod's usage is per container here too, and what somebody wants
				// is the pod.
				const containers = api.at(item, "containers") orelse Json{ .null = {} };
				if (containers == .array) {
					for (containers.array.items) |one| {
						cpu += quantityAt(one, "usage.cpu");
						memory += quantityAt(one, "usage.memory");
					}
				}
			} else {
				cpu = quantityAt(item, "usage.cpu");
				memory = quantityAt(item, "usage.memory");
			}

			const cells = try arena.alloc(Value, heading.len);
			cells[0] = .{ .text = name };
			cells[1] = .{ .text = try api.coresText(arena, cpu) };
			cells[2] = .{ .text = try api.bytesText(arena, memory) };
			if (pods) {
				cells[3] = .nil;
				cells[4] = .nil;
				for (specs) |spec| {
					if (!eq(textAt(spec, "metadata.name"), name)) {
						continue;
					}
					const asked_cpu = askedTotal(spec, "cpu");
					const asked_memory = askedTotal(spec, "memory");
					if (asked_cpu != 0) {
						cells[3] = .{ .text = try api.coresText(arena, asked_cpu) };
					}
					if (asked_memory != 0) {
						cells[4] = .{ .text = try api.bytesText(arena, asked_memory) };
					}
					break;
				}
			}
			try rows.rows.append(arena, cells);
		}
		return rows;
	}

	fn isReady(node: Json) bool {
		const conditions = api.at(node, "status.conditions") orelse return false;
		if (conditions != .array) {
			return false;
		}
		for (conditions.array.items) |one| {
			if (eq(textAt(one, "type"), "Ready")) {
				return eq(textAt(one, "status"), "True");
			}
		}
		return false;
	}

	fn quantityAt(object: Json, path: []const u8) i64 {
		const found = api.at(object, path) orelse return 0;
		return switch (found) {
			.string => |text| api.quantityOf(text) orelse 0,
			.integer => |n| n * 1000,
			else => 0,
		};
	}

	/// What one pod asked for, over all its containers.
	fn askedTotal(pod: Json, what: []const u8) i64 {
		const containers = api.at(pod, "spec.containers") orelse return 0;
		if (containers != .array) {
			return 0;
		}
		var total: i64 = 0;
		for (containers.array.items) |one| {
			const requests = api.at(one, "resources.requests") orelse continue;
			const value = api.at(requests, what) orelse continue;
			if (value == .string) {
				total += api.quantityOf(value.string) orelse 0;
			}
		}
		return total;
	}

	/// `3500m of 14 (25%)`. The share is what somebody is actually after: a
	/// number on its own says nothing about whether there is room left.
	fn shareText(arena: std.mem.Allocator, part: i64, whole: i64, kind: enum { cores, bytes }) db.Error![]const u8 {
		const one = switch (kind) {
			.cores => try api.coresText(arena, part),
			.bytes => try api.bytesText(arena, part),
		};
		if (whole == 0) {
			return one;
		}
		const other = switch (kind) {
			.cores => try api.coresText(arena, whole),
			.bytes => try api.bytesText(arena, whole),
		};
		return std.fmt.allocPrint(arena, "{s} of {s} ({d}%)", .{ one, other, @divTrunc(part * 100, whole) });
	}

	fn logs(self: *Db, arena: std.mem.Allocator, name: []const u8, howMany: []const u8) db.Error!Rows {
		if (name.len == 0) {
			self.remember("LOGS <pod> [lines]");
			return error.Driver;
		}
		const wanted = if (howMany.len != 0) std.fmt.parseInt(usize, howMany, 10) catch LOG_LINES else LOG_LINES;
		const resource = api.find("pods").?;
		// With the times the kubelet wrote down. They come at the front of every
		// line, and go into a column of their own here rather than staying there:
		// the grid has columns, and a stamp in front of the text is a stamp the
		// text has to be read around.
		const path = try std.fmt.allocPrint(arena, "{s}/log?tailLines={d}&timestamps=true", .{
			try self.objectPath(arena, resource, "", name),
			wanted,
		});
		const response = self.call(arena, "GET", path, "") catch return error.Driver;
		if (!response.ok()) {
			return self.fail(response, name);
		}
		return self.stampedLines(arena, response.body);
	}

	/// A log as two columns: when the line was written, and what it said.
	///
	/// The kubelet writes the time as a full RFC 3339 stamp - thirty characters of
	/// which the first eleven are the same on every line anybody is looking at.
	/// What is shown is the time of day, because that is what a log is read
	/// against; a line from another day is not marked as such, which is the price.
	fn stampedLines(self: *Db, arena: std.mem.Allocator, text: []const u8) db.Error!Rows {
		var rows = Rows{ .owner = self, .table = "" };
		const heading = try arena.alloc([]const u8, 2);
		heading[0] = "time";
		heading[1] = "line";
		rows.names = heading;
		rows.numeric = try arena.alloc(bool, 2);
		@memset(@constCast(rows.numeric), false);

		var walk = std.mem.splitScalar(u8, text, '\n');
		while (walk.next()) |one| {
			const line = std.mem.trimEnd(u8, one, "\r");
			const cells = try arena.alloc(Value, 2);
			const apart = timeOf(line);
			cells[0] = .{ .text = apart.when };
			cells[1] = .{ .text = apart.what };
			try rows.rows.append(arena, cells);
		}
		return rows;
	}

	/// The stamp at the front of a log line, as a time of day, and the rest.
	///
	/// A line without one is not an error: `timestamps=true` is asked for, but a
	/// log is whatever the container wrote and this has to hold it either way. Such
	/// a line keeps all of itself and has no time beside it.
	fn timeOf(line: []const u8) struct { when: []const u8, what: []const u8 } {
		const space = std.mem.indexOfScalar(u8, line, ' ') orelse return .{ .when = "", .what = line };
		const stamp = line[0..space];
		// 2026-08-21T15:55:33.775431123Z, and nothing shorter than the seconds.
		if (stamp.len < 20 or stamp[10] != 'T' or stamp[stamp.len - 1] != 'Z') {
			return .{ .when = "", .what = line };
		}
		var end: usize = 19;
		if (stamp.len > 23 and stamp[19] == '.') {
			end = 23; // and the milliseconds, which is what a request is timed in
		}
		return .{ .when = stamp[11..end], .what = line[space + 1 ..] };
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

/// How long one command in the open shell is waited for. A shell is not a query
/// and something may genuinely take a while, but the interface it is holding up
/// is one thread, and `EXEC -t` is there for a command that means to run all day.
const SESSION_SECONDS: i64 = 60;

const Ending = struct {
	/// Where the command's own output stopped.
	at: usize,
	status: []const u8,
};

/// Find the marker the shell was asked to print when a command ended, and say
/// where the output before it stopped. The marker is written on a line of its own
/// with the exit status after it.
fn findMarker(text: []const u8, marker: []const u8) ?Ending {
	const at = std.mem.lastIndexOf(u8, text, marker) orelse return null;
	// Everything the marker's own line holds after it is the status.
	const rest = text[at + marker.len ..];
	const line_end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
	// And the line the marker is on does not belong to the output.
	var stop = at;
	while (stop > 0 and text[stop - 1] != '\n') {
		stop -= 1;
	}
	return .{ .at = stop, .status = std.mem.trim(u8, rest[0..line_end], " \r\n") };
}

/// A word as it can go in a query string. A command may hold anything.
fn escapedQuery(arena: std.mem.Allocator, word: []const u8) ![]const u8 {
	var out: List = .empty;
	for (word) |char| {
		if (std.ascii.isAlphanumeric(char) or char == '-' or char == '_' or char == '.' or char == '~' or char == '/') {
			try out.append(arena, char);
		} else {
			try out.print(arena, "%{X:0>2}", .{char});
		}
	}
	return out.items;
}

/// Whether this is an `APPLY` and its manifest rather than a line of commands.
fn isApply(text: []const u8) bool {
	var words = std.mem.tokenizeAny(u8, text, " \t\r\n;");
	const verb = words.next() orelse return false;
	return eq(verb, "APPLY");
}

/// Everything after the first word, which for `APPLY` is the manifest.
fn afterVerb(line: []const u8) []const u8 {
	const text = std.mem.trimStart(u8, line, " \t\r\n");
    const space = std.mem.indexOfAny(u8, text, " \t\r\n") orelse return "";
	return text[space..];
}

/// The documents of a manifest. YAML separates them with a line that is exactly
/// `---`, and this program's own reader stops at the second one on purpose - a
/// kubeconfig is one document and half of two would be worse than none - so a
/// manifest is cut up here and each piece read on its own.
pub fn splitDocuments(text: []const u8) DocumentIterator {
	return .{ .text = text };
}

pub const DocumentIterator = struct {
	text: []const u8,
	at: usize = 0,

	pub fn next(self: *DocumentIterator) ?[]const u8 {
		if (self.at >= self.text.len) {
			return null;
		}
		const start = self.at;
		var walk = self.at;
		while (walk < self.text.len) {
			const end = std.mem.indexOfScalarPos(u8, self.text, walk, '\n') orelse self.text.len;
			const line = std.mem.trim(u8, self.text[walk..end], " \t\r");
			// A separator, and only one: `---` inside a block scalar is indented,
			// and a line of dashes that is longer is not a separator at all.
			if (std.mem.eql(u8, line, "---") and self.text[walk..end].len == line.len) {
				self.at = @min(end + 1, self.text.len);
				return self.text[start..walk];
			}
			walk = @min(end + 1, self.text.len);
			if (end >= self.text.len) {
				break;
			}
		}
		self.at = self.text.len;
		return self.text[start..];
	}
};

fn textAt(object: Json, path: []const u8) []const u8 {
	const found = api.at(object, path) orelse return "";
	return if (found == .string) found.string else "";
}

/// A container state as one line: `running since …`, `waiting: ImagePullBackOff`,
/// `terminated: OOMKilled (137) at …`. The exit code matters as much as the
/// reason - `Error (1)` and `Error (137)` are different afternoons.
fn state(arena: std.mem.Allocator, value: ?Json) ![]const u8 {
	const found = value orelse return "";
	if (found != .object) {
		return "";
	}
	if (api.at(found, "running")) |running| {
		return std.fmt.allocPrint(arena, "running since {s}", .{textAt(running, "startedAt")});
	}
	if (api.at(found, "waiting")) |waiting| {
		const reason = textAt(waiting, "reason");
		const said = textAt(waiting, "message");
		return if (said.len != 0)
			std.fmt.allocPrint(arena, "waiting: {s} - {s}", .{ reason, said })
		else
			std.fmt.allocPrint(arena, "waiting: {s}", .{reason});
	}
	if (api.at(found, "terminated")) |ended| {
		const code = api.at(ended, "exitCode");
		const signal = api.at(ended, "signal");
		var out: List = .empty;
		try out.print(arena, "terminated: {s}", .{textAt(ended, "reason")});
		if (code) |value_of| {
			if (value_of == .integer) {
				try out.print(arena, " ({d})", .{value_of.integer});
			}
		}
		if (signal) |value_of| {
			if (value_of == .integer and value_of.integer != 0) {
				try out.print(arena, " on signal {d}", .{value_of.integer});
			}
		}
		const at_time = textAt(ended, "finishedAt");
		if (at_time.len != 0) {
			try out.print(arena, " at {s}", .{at_time});
		}
		return out.items;
	}
	return "";
}

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
	const By = struct {
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
	std.mem.sort([]const Value, rows, By{ .at = at, .descending = descending }, By.less);
}

fn nowSeconds() i64 {
	return clock.wallSeconds();
}

/// A shell in a container, over the same WebSocket kubectl uses.
///
/// Kubernetes multiplexes the streams onto one socket by putting a channel
/// number in front of every message: 0 is what is typed, 1 and 2 are what comes
/// back, 3 is how the far end says why it stopped, and 4 is the window size. So
/// this is a thin thing - the protocol is a first byte - and everything hard
/// about it is on the other side, in a terminal that has to be handed over and
/// handed back.
pub const Shell = struct {
	allocator: std.mem.Allocator,
	socket: ws.Socket,
	/// What channel 3 said, which is how a non-zero exit arrives.
	status: List = .empty,
	finished: bool = false,

	const STDIN: u8 = 0;
	const STDOUT: u8 = 1;
	const STDERR: u8 = 2;
	const ERROR: u8 = 3;
	const RESIZE: u8 = 4;

	pub fn deinit(self: *Shell) void {
		self.status.deinit(self.allocator);
		self.socket.deinit();
	}

	/// The socket, so a caller can wait on this and a terminal together.
	pub fn handle(self: *Shell) std.c.fd_t {
		return self.socket.handle();
	}

	/// What was typed, on its way to the container.
	pub fn write(self: *Shell, bytes: []const u8) db.Error!void {
		if (bytes.len == 0) {
			return;
		}
		var framed = try self.allocator.alloc(u8, bytes.len + 1);
		defer self.allocator.free(framed);
		framed[0] = STDIN;
		@memcpy(framed[1..], bytes);
		self.socket.send(.binary, framed) catch return error.Driver;
	}

	/// Tell the far end how big the window is. A shell that thinks it is on
	/// eighty columns when it is not draws everything in the wrong place.
	pub fn resize(self: *Shell, cols: u16, rows: u16) void {
		var buffer: [64]u8 = undefined;
		const message = std.fmt.bufPrint(&buffer, "{c}{{\"Width\":{d},\"Height\":{d}}}", .{ RESIZE, cols, rows }) catch return;
		self.socket.send(.binary, message) catch {};
	}

	/// Whatever the container has said by now, appended to `out`. False when the
	/// session is over.
	pub fn read(self: *Shell, out: *List) db.Error!bool {
		if (self.finished) {
			return false;
		}
		if (!(self.socket.drain() catch false)) {
			self.finished = true;
			return false;
		}
		while (true) {
			const frame = (self.socket.next() catch {
				self.finished = true;
				return false;
			}) orelse break;
			defer self.socket.done();
			if (frame.payload.len == 0) {
				continue;
			}
			switch (frame.payload[0]) {
				STDOUT, STDERR => try out.appendSlice(self.allocator, frame.payload[1..]),
				ERROR => {
					// A JSON status, and `Success` is the boring one.
					self.status.clearRetainingCapacity();
					try self.status.appendSlice(self.allocator, frame.payload[1..]);
					self.finished = true;
					return false;
				},
				else => {},
			}
		}
		return !self.socket.closed;
	}

	/// Why it ended, where that is worth saying. An ordinary exit says nothing.
	pub fn why(self: *Shell, arena: std.mem.Allocator) []const u8 {
		if (self.status.items.len == 0) {
			return "";
		}
		const parsed = std.json.parseFromSliceLeaky(Json, arena, self.status.items, .{}) catch return "";
		const said = api.at(parsed, "status") orelse return "";
		if (said == .string and std.mem.eql(u8, said.string, "Success")) {
			return "";
		}
		const message = api.at(parsed, "message") orelse return "";
		return if (message == .string) message.string else "";
	}
};

pub const Rows = db.Built(Db, Value);

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

test "a context offered from the kubeconfig survives the round trip into a target" {
	var arena = std.heap.ArenaAllocator.init(testing.allocator);
	defer arena.deinit();
	const a = arena.allocator();
	// An EKS context is an ARN and always has a slash in it, and the last slash
	// in a target is where the namespace begins - so a name that went out
	// unescaped would come back as a different context and a namespace nobody
	// asked for.
	const every = [_][]const u8{
		"work",
		"arn:aws:eks:eu-west-1:1234:cluster/live",
		"gke_project_europe-west1_cluster",
		"one/two/three",
		"odd?name",
		"100%done",
		"has#hash",
	};
	for (every) |name| {
		const target = try escapedTarget(a, name);
		try testing.expect(std.mem.startsWith(u8, target, "k8s://"));
		const parts = try address.parse(a, target);
		try testing.expectEqualStrings(name, parts.context);
		// And nothing was read as a namespace, because none was asked for.
		try testing.expectEqualStrings("", parts.namespace);
	}
}

test "a machine with no kubeconfig has no contexts to offer, and does not mind" {
	var arena = std.heap.ArenaAllocator.init(testing.allocator);
	defer arena.deinit();
	// `contexts` reads whatever this machine has; what is being checked is that
	// it answers at all rather than failing, which is what a list of databases
	// needs from it.
	_ = contexts(arena.allocator());
}

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

test "a log line comes apart into when it was written and what it said" {
	// What the kubelet actually sends with timestamps=true.
	const one = Db.timeOf("2026-08-21T15:55:33.775431123Z info: request finished");
	try testing.expectEqualStrings("15:55:33.775", one.when);
	try testing.expectEqualStrings("info: request finished", one.what);

	// Whole seconds, which is all some clocks offer.
	const plain = Db.timeOf("2026-08-21T15:55:33Z hello");
	try testing.expectEqualStrings("15:55:33", plain.when);
	try testing.expectEqualStrings("hello", plain.what);

	// A line that is only a stamp is a line with nothing in it, not a line that
	// is a stamp.
	const bare = Db.timeOf("2026-08-21T15:55:33.775431123Z ");
	try testing.expectEqualStrings("15:55:33.775", bare.when);
	try testing.expectEqualStrings("", bare.what);

	// And a line with no stamp keeps all of itself rather than losing its first
	// word to a column it does not belong in. `timestamps=true` is asked for, but
	// a log is whatever the container wrote.
	for ([_][]const u8{
		"info: something without a stamp",
		"nospaces",
		"",
		"2026-08-21 15:55:33 not rfc3339",
		"short Z",
	}) |line| {
		const none = Db.timeOf(line);
		try testing.expectEqualStrings("", none.when);
		try testing.expectEqualStrings(line, none.what);
	}
}

test "only the console verbs that look are worth repeating" {
	// A grid the follow key refreshes on a clock must not be one that changes
	// the cluster every time it ticks.
	var db_stub: Db = undefined;
	for ([_][]const u8{ "GET pods", "get pods", "LOGS api-7c9", "WHY api-7c9", "DESCRIBE pod x", "CONTEXTS", "VERSION", "NAMESPACES", "CLUSTER", "TOP nodes", "TOP pods" }) |reading| {
		if (!Db.repeatable(&db_stub, reading)) {
			std.debug.print("should repeat: {s}\n", .{reading});
			return error.TestUnexpectedResult;
		}
	}
	for ([_][]const u8{ "SCALE deployments api 5", "RESTART deployments api", "USE kube-system", "", "nonsense" }) |writing| {
		if (Db.repeatable(&db_stub, writing)) {
			std.debug.print("should not repeat: {s}\n", .{writing});
			return error.TestUnexpectedResult;
		}
	}
}

test "a manifest comes apart at its document separators" {
	const text =
		\\apiVersion: v1
		\\kind: ConfigMap
		\\---
		\\apiVersion: apps/v1
		\\kind: Deployment
		\\---
		\\apiVersion: v1
		\\kind: Service
	;
	var found: usize = 0;
	var walk = splitDocuments(text);
	while (walk.next()) |document| : (found += 1) {
		try testing.expect(std.mem.indexOf(u8, document, "apiVersion") != null);
		// A separator belongs to neither side of it.
		try testing.expect(std.mem.indexOf(u8, document, "---") == null);
	}
	try testing.expectEqual(@as(usize, 3), found);

	// A document is not cut at a `---` that is indented - inside a block scalar,
	// where it is content - nor at a longer row of dashes, which is not one.
	const tricky =
		\\kind: ConfigMap
		\\data:
		\\  note: |
		\\    ---
		\\    still the same document
		\\  line: ----
	;
	var one = splitDocuments(tricky);
	const whole = one.next().?;
    try testing.expect(std.mem.indexOf(u8, whole, "still the same document") != null);
	try testing.expect(one.next() == null);

	// One document with no separator at all is one document.
	var plain = splitDocuments("kind: Pod\n");
	try testing.expect(plain.next() != null);
	try testing.expect(plain.next() == null);
}

test "APPLY takes the manifest under it, and nothing else does" {
	try testing.expect(isApply("APPLY\nkind: Pod\n"));
	try testing.expect(isApply("  apply\nkind: Pod\n"));
	try testing.expect(!isApply("GET pods"));
	try testing.expect(!isApply(""));
	// And what it takes is everything after the word.
	try testing.expectEqualStrings("\nkind: Pod\n", afterVerb("APPLY\nkind: Pod\n"));
	try testing.expectEqualStrings("", afterVerb("APPLY"));
}

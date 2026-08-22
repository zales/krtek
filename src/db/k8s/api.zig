//! What a Kubernetes cluster answers, and what this driver makes a table of.
//!
//! Every list endpoint gives back the same shape - `{items: [...]}` of objects
//! that all carry `metadata`, `spec` and `status` - so a table here is a path, a
//! kind and a list of columns saying where in each object its value is. Adding
//! `cronjobs` later is a few lines in `RESOURCES` and nothing else.
//!
//! Four columns cannot be read straight out of the JSON and are worked out
//! instead: how old an object is, how many of a pod's containers are ready, how
//! many times they have restarted, and how many of a deployment's replicas are
//! up. Those four are what makes a list of pods worth looking at rather than a
//! list of names, and each is one line of arithmetic over fields that are there.
//!
//! JSON in, cells out, and no connection anywhere near it.

const std = @import("std");
const db = @import("../db.zig");

const List = db.List;
const Json = std.json.Value;

/// Where a column's value comes from.
pub const From = union(enum) {
	/// Dotted, into the object: `metadata.name`, `status.podIP`.
	at: []const u8,
	/// How long ago `metadata.creationTimestamp` was, as kubectl writes it.
	age,
	/// `2/3`: containers ready out of containers there.
	ready,
	/// How many times this pod's containers have been restarted, added up.
	restarts,
	/// `3/3` over a workload's replicas: ready out of wanted.
	replicas,
	/// The labels, as `k=v,k=v`.
	labels,
};

pub const Column = struct {
	name: []const u8,
	from: From,
	numeric: bool = false,
};

pub const Resource = struct {
	/// What the table is called, which is what the API calls it.
	name: []const u8,
	/// The API root it lives under: `/api/v1` for the core group, `/apis/<group>/<version>`
	/// for everything else.
	root: []const u8,
	/// What one of them is called, for a message about a single object.
	singular: []const u8,
	/// Whether it lives in a namespace. A node does not.
	namespaced: bool = true,
	/// Whether a row can be deleted.
	remove: bool = true,
	/// Whether `SCALE` means anything to it.
	scalable: bool = false,
	/// Whether `LOGS` means anything to it.
	loggable: bool = false,
	columns: []const Column,
};

const NAME: Column = .{ .name = "name", .from = .{ .at = "metadata.name" } };
const AGE: Column = .{ .name = "age", .from = .age };

pub const RESOURCES = [_]Resource{
	.{
		.name = "pods",
		.root = "/api/v1",
		.singular = "pod",
		.loggable = true,
		.columns = &.{
			NAME,
			.{ .name = "ready", .from = .ready },
			.{ .name = "status", .from = .{ .at = "status.phase" } },
			.{ .name = "restarts", .from = .restarts, .numeric = true },
			AGE,
			.{ .name = "ip", .from = .{ .at = "status.podIP" } },
			.{ .name = "node", .from = .{ .at = "spec.nodeName" } },
		},
	},
	.{
		.name = "deployments",
		.root = "/apis/apps/v1",
		.singular = "deployment",
		.scalable = true,
		.columns = &.{
			NAME,
			.{ .name = "ready", .from = .replicas },
			.{ .name = "wanted", .from = .{ .at = "spec.replicas" }, .numeric = true },
			.{ .name = "up-to-date", .from = .{ .at = "status.updatedReplicas" }, .numeric = true },
			.{ .name = "available", .from = .{ .at = "status.availableReplicas" }, .numeric = true },
			AGE,
		},
	},
	.{
		.name = "statefulsets",
		.root = "/apis/apps/v1",
		.singular = "statefulset",
		.scalable = true,
		.columns = &.{
			NAME,
			.{ .name = "ready", .from = .replicas },
			.{ .name = "wanted", .from = .{ .at = "spec.replicas" }, .numeric = true },
			AGE,
		},
	},
	.{
		.name = "daemonsets",
		.root = "/apis/apps/v1",
		.singular = "daemonset",
		.columns = &.{
			NAME,
			.{ .name = "desired", .from = .{ .at = "status.desiredNumberScheduled" }, .numeric = true },
			.{ .name = "ready", .from = .{ .at = "status.numberReady" }, .numeric = true },
			.{ .name = "available", .from = .{ .at = "status.numberAvailable" }, .numeric = true },
			AGE,
		},
	},
	.{
		.name = "replicasets",
		.root = "/apis/apps/v1",
		.singular = "replicaset",
		.scalable = true,
		.columns = &.{
			NAME,
			.{ .name = "ready", .from = .replicas },
			.{ .name = "wanted", .from = .{ .at = "spec.replicas" }, .numeric = true },
			AGE,
		},
	},
	.{
		.name = "jobs",
		.root = "/apis/batch/v1",
		.singular = "job",
		.columns = &.{
			NAME,
			.{ .name = "succeeded", .from = .{ .at = "status.succeeded" }, .numeric = true },
			.{ .name = "failed", .from = .{ .at = "status.failed" }, .numeric = true },
			.{ .name = "active", .from = .{ .at = "status.active" }, .numeric = true },
			AGE,
		},
	},
	.{
		.name = "cronjobs",
		.root = "/apis/batch/v1",
		.singular = "cronjob",
		.columns = &.{
			NAME,
			.{ .name = "schedule", .from = .{ .at = "spec.schedule" } },
			.{ .name = "suspended", .from = .{ .at = "spec.suspend" } },
			.{ .name = "last run", .from = .{ .at = "status.lastScheduleTime" } },
			AGE,
		},
	},
	.{
		.name = "services",
		.root = "/api/v1",
		.singular = "service",
		.columns = &.{
			NAME,
			.{ .name = "type", .from = .{ .at = "spec.type" } },
			.{ .name = "cluster-ip", .from = .{ .at = "spec.clusterIP" } },
			AGE,
		},
	},
	.{
		.name = "ingresses",
		.root = "/apis/networking.k8s.io/v1",
		.singular = "ingress",
		.columns = &.{
			NAME,
			.{ .name = "class", .from = .{ .at = "spec.ingressClassName" } },
			AGE,
		},
	},
	.{
		.name = "configmaps",
		.root = "/api/v1",
		.singular = "configmap",
		.columns = &.{ NAME, AGE, .{ .name = "labels", .from = .labels } },
	},
	.{
		.name = "secrets",
		.root = "/api/v1",
		.singular = "secret",
		.columns = &.{
			NAME,
			.{ .name = "type", .from = .{ .at = "type" } },
			AGE,
		},
	},
	.{
		.name = "persistentvolumeclaims",
		.root = "/api/v1",
		.singular = "claim",
		.columns = &.{
			NAME,
			.{ .name = "status", .from = .{ .at = "status.phase" } },
			.{ .name = "volume", .from = .{ .at = "spec.volumeName" } },
			.{ .name = "class", .from = .{ .at = "spec.storageClassName" } },
			AGE,
		},
	},
	.{
		.name = "serviceaccounts",
		.root = "/api/v1",
		.singular = "service account",
		.columns = &.{ NAME, AGE },
	},
	.{
		.name = "events",
		.root = "/api/v1",
		.singular = "event",
		.remove = false,
		.columns = &.{
			.{ .name = "last seen", .from = .{ .at = "lastTimestamp" } },
			.{ .name = "type", .from = .{ .at = "type" } },
			.{ .name = "reason", .from = .{ .at = "reason" } },
			.{ .name = "object", .from = .{ .at = "involvedObject.name" } },
			.{ .name = "message", .from = .{ .at = "message" } },
		},
	},
	.{
		.name = "nodes",
		.root = "/api/v1",
		.singular = "node",
		.namespaced = false,
		.remove = false,
		.columns = &.{
			NAME,
			.{ .name = "version", .from = .{ .at = "status.nodeInfo.kubeletVersion" } },
			.{ .name = "os", .from = .{ .at = "status.nodeInfo.operatingSystem" } },
			.{ .name = "arch", .from = .{ .at = "status.nodeInfo.architecture" } },
			AGE,
		},
	},
	.{
		.name = "namespaces",
		.root = "/api/v1",
		.singular = "namespace",
		.namespaced = false,
		.columns = &.{
			NAME,
			.{ .name = "status", .from = .{ .at = "status.phase" } },
			AGE,
		},
	},
	.{
		.name = "persistentvolumes",
		.root = "/api/v1",
		.singular = "volume",
		.namespaced = false,
		.columns = &.{
			NAME,
			.{ .name = "status", .from = .{ .at = "status.phase" } },
			.{ .name = "claim", .from = .{ .at = "spec.claimRef.name" } },
			AGE,
		},
	},
	.{
		.name = "storageclasses",
		.root = "/apis/storage.k8s.io/v1",
		.singular = "storage class",
		.namespaced = false,
		.columns = &.{
			NAME,
			.{ .name = "provisioner", .from = .{ .at = "provisioner" } },
			AGE,
		},
	},
};

pub fn find(name: []const u8) ?Resource {
	for (RESOURCES) |resource| {
		if (std.mem.eql(u8, resource.name, name)) {
			return resource;
		}
	}
	return null;
}

/// The value at a dotted path, or null where any step of it is missing.
pub fn at(object: Json, path: []const u8) ?Json {
	var here = object;
	var parts = std.mem.splitScalar(u8, path, '.');
	while (parts.next()) |part| {
		if (here != .object) {
			return null;
		}
		here = here.object.get(part) orelse return null;
	}
	return here;
}

/// One cell as text. `now` is the moment the age is measured against, in seconds
/// since the epoch, so a whole page is aged from one reading of the clock.
pub fn cell(arena: std.mem.Allocator, object: Json, column: Column, now: i64) ![]const u8 {
	return switch (column.from) {
		.at => |path| try flatten(arena, at(object, path)),
		.age => try age(arena, object, now),
		.ready => try readyContainers(arena, object),
		.restarts => try restarts(arena, object),
		.replicas => try replicaCount(arena, object),
		.labels => try labels(arena, object),
	};
}

/// A JSON value as the one line a grid cell is. An object or an array is said to
/// be one rather than spilled into the row: what is in it belongs in the detail
/// box, which shows the object whole.
fn flatten(arena: std.mem.Allocator, value: ?Json) ![]const u8 {
	const found = value orelse return "";
	return switch (found) {
		.string => |text| text,
		.integer => |number| try std.fmt.allocPrint(arena, "{d}", .{number}),
		.float => |number| try std.fmt.allocPrint(arena, "{d}", .{number}),
		.bool => |yes| if (yes) "true" else "false",
		.null => "",
		.number_string => |text| text,
		.array => |items| try std.fmt.allocPrint(arena, "[{d}]", .{items.items.len}),
		.object => "{…}",
	};
}

/// How long since `metadata.creationTimestamp`, written the way kubectl writes
/// it: the largest unit that says something, and never more than two of them.
fn age(arena: std.mem.Allocator, object: Json, now: i64) ![]const u8 {
	const stamp = at(object, "metadata.creationTimestamp") orelse return "";
	if (stamp != .string) {
		return "";
	}
	const then = epochOf(stamp.string) orelse return "";
	var left = now - then;
	if (left < 0) {
		left = 0;
	}
	const days = @divTrunc(left, 86400);
	const hours = @divTrunc(@mod(left, 86400), 3600);
	const minutes = @divTrunc(@mod(left, 3600), 60);
	const seconds = @mod(left, 60);
	if (days >= 365) {
		return std.fmt.allocPrint(arena, "{d}y{d}d", .{ @divTrunc(days, 365), @mod(days, 365) });
	}
	if (days > 0) {
		return if (days >= 8)
			std.fmt.allocPrint(arena, "{d}d", .{days})
		else
			std.fmt.allocPrint(arena, "{d}d{d}h", .{ days, hours });
	}
	if (hours > 0) {
		return std.fmt.allocPrint(arena, "{d}h{d}m", .{ hours, minutes });
	}
	if (minutes > 0) {
		return std.fmt.allocPrint(arena, "{d}m", .{minutes});
	}
	return std.fmt.allocPrint(arena, "{d}s", .{seconds});
}

/// RFC 3339 as Kubernetes writes it, which is always `2006-01-02T15:04:05Z`.
/// Anything else gives nothing rather than a wrong number.
pub fn epochOf(text: []const u8) ?i64 {
	if (text.len < 20 or text[4] != '-' or text[7] != '-' or text[10] != 'T') {
		return null;
	}
	const year = std.fmt.parseInt(i64, text[0..4], 10) catch return null;
	const month = std.fmt.parseInt(i64, text[5..7], 10) catch return null;
	const day = std.fmt.parseInt(i64, text[8..10], 10) catch return null;
	const hour = std.fmt.parseInt(i64, text[11..13], 10) catch return null;
	const minute = std.fmt.parseInt(i64, text[14..16], 10) catch return null;
	const second = std.fmt.parseInt(i64, text[17..19], 10) catch return null;
	if (month < 1 or month > 12 or day < 1 or day > 31) {
		return null;
	}
	// Days since the epoch, by the civil-from-days algorithm: no table, no
	// library, and right across leap years and centuries.
	const y = year - @intFromBool(month <= 2);
	const era = @divFloor(y, 400);
	const year_of_era = y - era * 400;
	const day_of_year = @divTrunc(153 * (month + (if (month > 2) @as(i64, -3) else 9)) + 2, 5) + day - 1;
	const day_of_era = year_of_era * 365 + @divTrunc(year_of_era, 4) - @divTrunc(year_of_era, 100) + day_of_year;
	const days = era * 146097 + day_of_era - 719468;
	return days * 86400 + hour * 3600 + minute * 60 + second;
}

fn readyContainers(arena: std.mem.Allocator, object: Json) ![]const u8 {
	const statuses = at(object, "status.containerStatuses") orelse return "";
	if (statuses != .array) {
		return "";
	}
	var ready: usize = 0;
	for (statuses.array.items) |one| {
		const flag = at(one, "ready") orelse continue;
		if (flag == .bool and flag.bool) {
			ready += 1;
		}
	}
	return std.fmt.allocPrint(arena, "{d}/{d}", .{ ready, statuses.array.items.len });
}

fn restarts(arena: std.mem.Allocator, object: Json) ![]const u8 {
	const statuses = at(object, "status.containerStatuses") orelse return "";
	if (statuses != .array) {
		return "";
	}
	var total: i64 = 0;
	for (statuses.array.items) |one| {
		const count = at(one, "restartCount") orelse continue;
		if (count == .integer) {
			total += count.integer;
		}
	}
	return std.fmt.allocPrint(arena, "{d}", .{total});
}

/// `2/3`: replicas ready out of replicas wanted. A workload that has never been
/// scaled reports no `readyReplicas` at all, which is zero and not unknown.
fn replicaCount(arena: std.mem.Allocator, object: Json) ![]const u8 {
	const wanted = at(object, "spec.replicas");
	const ready = at(object, "status.readyReplicas");
	if (wanted == null) {
		return "";
	}
	return std.fmt.allocPrint(arena, "{d}/{d}", .{
		if (ready) |value| (if (value == .integer) value.integer else 0) else 0,
		if (wanted.?  == .integer) wanted.?.integer else 0,
	});
}

fn labels(arena: std.mem.Allocator, object: Json) ![]const u8 {
	const found = at(object, "metadata.labels") orelse return "";
	if (found != .object) {
		return "";
	}
	var out: List = .empty;
	var walk = found.object.iterator();
	while (walk.next()) |entry| {
		if (out.items.len != 0) {
			try out.append(arena, ',');
		}
		try out.appendSlice(arena, entry.key_ptr.*);
		try out.append(arena, '=');
		try out.appendSlice(arena, try flatten(arena, entry.value_ptr.*));
	}
	return out.items;
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

fn parsed(arena: std.mem.Allocator, text: []const u8) !Json {
	return (try std.json.parseFromSlice(Json, arena, text, .{})).value;
}

test "a pod's row is read and worked out from what the API answers" {
	var arena = std.heap.ArenaAllocator.init(testing.allocator);
	defer arena.deinit();
	const a = arena.allocator();
	const pod = try parsed(a,
		\\{"metadata": {"name": "api-7c9", "creationTimestamp": "2026-08-20T10:00:00Z",
		\\              "labels": {"app": "api"}},
		\\ "spec": {"nodeName": "node-1"},
		\\ "status": {"phase": "Running", "podIP": "10.1.2.3",
		\\            "containerStatuses": [{"ready": true, "restartCount": 2},
		\\                                  {"ready": false, "restartCount": 5}]}}
	);
	const now = epochOf("2026-08-22T14:30:00Z").?;
	const resource = find("pods").?;
	var cells: [8][]const u8 = undefined;
	for (resource.columns, 0..) |column, i| {
		cells[i] = try cell(a, pod, column, now);
	}
	try testing.expectEqualStrings("api-7c9", cells[0]);
	try testing.expectEqualStrings("1/2", cells[1]);
	try testing.expectEqualStrings("Running", cells[2]);
	try testing.expectEqualStrings("7", cells[3]);
	try testing.expectEqualStrings("2d4h", cells[4]);
	try testing.expectEqualStrings("10.1.2.3", cells[5]);
	try testing.expectEqualStrings("node-1", cells[6]);
}

test "an object missing half of itself gives empty cells, not wrong ones" {
	var arena = std.heap.ArenaAllocator.init(testing.allocator);
	defer arena.deinit();
	const a = arena.allocator();
	const bare = try parsed(a, "{\"metadata\": {\"name\": \"pending\"}}");
	const now = epochOf("2026-08-22T14:30:00Z").?;
	for (find("pods").?.columns) |column| {
		const text = try cell(a, bare, column, now);
		if (std.mem.eql(u8, column.name, "name")) {
			try testing.expectEqualStrings("pending", text);
		} else {
			try testing.expectEqualStrings("", text);
		}
	}
}

test "how old a thing is, the way kubectl says it" {
	var arena = std.heap.ArenaAllocator.init(testing.allocator);
	defer arena.deinit();
	const a = arena.allocator();
	const now = epochOf("2026-08-22T12:00:00Z").?;
	const cases = [_]struct { made: []const u8, says: []const u8 }{
		.{ .made = "2026-08-22T11:59:50Z", .says = "10s" },
		.{ .made = "2026-08-22T11:30:00Z", .says = "30m" },
		.{ .made = "2026-08-22T08:15:00Z", .says = "3h45m" },
		.{ .made = "2026-08-20T06:00:00Z", .says = "2d6h" },
		.{ .made = "2026-07-01T12:00:00Z", .says = "52d" },
		.{ .made = "2024-08-22T12:00:00Z", .says = "2y0d" },
		// Something created in the future is not aged negatively.
		.{ .made = "2027-01-01T00:00:00Z", .says = "0s" },
	};
	for (cases) |case| {
		const made = try parsed(a, try std.fmt.allocPrint(a,
			"{{\"metadata\": {{\"creationTimestamp\": \"{s}\"}}}}", .{case.made}));
		try testing.expectEqualStrings(case.says, try cell(a, made, .{ .name = "age", .from = .age }, now));
	}
	// A timestamp that is not one gives nothing rather than a wrong age.
	const odd = try parsed(a, "{\"metadata\": {\"creationTimestamp\": \"whenever\"}}");
	try testing.expectEqualStrings("", try cell(a, odd, .{ .name = "age", .from = .age }, now));
}

test "the epoch of a timestamp, across leap years and centuries" {
	try testing.expectEqual(@as(i64, 0), epochOf("1970-01-01T00:00:00Z").?);
	try testing.expectEqual(@as(i64, 951825600), epochOf("2000-02-29T12:00:00Z").?);
	try testing.expectEqual(@as(i64, 1709208000), epochOf("2024-02-29T12:00:00Z").?);
	try testing.expectEqual(@as(i64, 1767225600), epochOf("2026-01-01T00:00:00Z").?);
	try testing.expect(epochOf("2026-13-01T00:00:00Z") == null);
	try testing.expect(epochOf("nonsense") == null);
	try testing.expect(epochOf("") == null);
}

test "a deployment counts its replicas, and one never scaled counts zero" {
	var arena = std.heap.ArenaAllocator.init(testing.allocator);
	defer arena.deinit();
	const a = arena.allocator();
	const column: Column = .{ .name = "ready", .from = .replicas };
	const up = try parsed(a, "{\"spec\": {\"replicas\": 3}, \"status\": {\"readyReplicas\": 2}}");
	try testing.expectEqualStrings("2/3", try cell(a, up, column, 0));
	const none = try parsed(a, "{\"spec\": {\"replicas\": 3}, \"status\": {}}");
	try testing.expectEqualStrings("0/3", try cell(a, none, column, 0));
	// Something with no replicas at all is not a workload and says nothing.
	const other = try parsed(a, "{\"spec\": {}}");
	try testing.expectEqualStrings("", try cell(a, other, column, 0));
}

test "a nested value is not spilled into the row" {
	var arena = std.heap.ArenaAllocator.init(testing.allocator);
	defer arena.deinit();
	const a = arena.allocator();
	const thing = try parsed(a, "{\"spec\": {\"ports\": [1, 2, 3], \"selector\": {\"app\": \"x\"}, \"n\": 7, \"on\": true}}");
	try testing.expectEqualStrings("[3]", try cell(a, thing, .{ .name = "p", .from = .{ .at = "spec.ports" } }, 0));
	try testing.expectEqualStrings("{…}", try cell(a, thing, .{ .name = "s", .from = .{ .at = "spec.selector" } }, 0));
	try testing.expectEqualStrings("7", try cell(a, thing, .{ .name = "n", .from = .{ .at = "spec.n" } }, 0));
	try testing.expectEqualStrings("true", try cell(a, thing, .{ .name = "o", .from = .{ .at = "spec.on" } }, 0));
	try testing.expectEqualStrings("", try cell(a, thing, .{ .name = "x", .from = .{ .at = "spec.missing.deeper" } }, 0));
}

test "every resource is namespaced or not, and none of them is nameless" {
	for (RESOURCES) |resource| {
		try testing.expect(resource.name.len != 0);
		try testing.expect(resource.singular.len != 0);
		try testing.expect(resource.columns.len != 0);
		try testing.expect(std.mem.startsWith(u8, resource.root, "/api"));
		try testing.expect(find(resource.name) != null);
	}
	try testing.expect(find("widgets") == null);
	// The one that is not in a namespace really is not.
	try testing.expect(!find("nodes").?.namespaced);
	try testing.expect(find("pods").?.namespaced);
}

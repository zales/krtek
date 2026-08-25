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
    /// `2/3`: containers ready out of containers the pod asked for.
    ready,
    /// What kubectl puts in a pod's STATUS, which is not `status.phase`: a pod
    /// crash-looping is phase Running, and a pod that has finished is phase
    /// Succeeded where kubectl says Completed.
    pod_status,
    /// How many times this pod's containers have been restarted, added up.
    restarts,
    /// `3/3` over a workload's replicas: ready out of wanted.
    replicas,
    /// The labels, as `k=v,k=v`.
    labels,
    /// A service's ports, as `80/TCP,443/TCP`.
    ports,
    /// A quantity out of the object, written the way somebody reads it rather
    /// than the way the API stores it: `8143396Ki` is `7.8Gi`.
    quantity: []const u8,
    /// What a pod asked for, added up over its containers. The API keeps these
    /// per container, and what somebody wants to know about a pod is its whole
    /// appetite - which is also what the scheduler placed it by.
    asked: Asked,
};

pub const Asked = struct {
    /// `requests` or `limits`.
    which: []const u8,
    /// `cpu` or `memory`.
    what: []const u8,
};

pub const Column = struct {
    name: []const u8,
    from: From,
    numeric: bool = false,
    /// A counter the API leaves out when it is zero: `availableReplicas` is
    /// absent on a deployment that has none, and an empty cell there would read as
    /// "unknown" where kubectl says 0. Only for fields that really do count
    /// something - a `spec.replicas` that is missing is not set, which is not the
    /// same as none.
    zero_when_missing: bool = false,
};

pub const Resource = struct {
    /// What the table is called, which is what the API calls it - except where a
    /// kind is a reading of something else, and then `path` says what to ask for.
    name: []const u8,
    /// The path segment to list, where it is not the name. Helm's releases are
    /// secrets of a particular type, and `secrets` is what the API answers to.
    path: []const u8 = "",
    /// Narrowing the API does for us, as a query string. A field selector costs
    /// nothing and saves reading every secret in a cluster to find four.
    query: []const u8 = "",
    /// What a manifest calls it. The `kind:` of a YAML document names this and
    /// nothing else, so applying one has to come back the other way.
    kind: []const u8,
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
    /// Which part of a cluster this belongs to, for the list down the side.
    group: []const u8 = "",
    columns: []const Column,
};

const NAME: Column = .{ .name = "name", .from = .{ .at = "metadata.name" } };
const AGE: Column = .{ .name = "age", .from = .age };

pub const RESOURCES = [_]Resource{
    .{
        .name = "pods",
        .kind = "Pod",
        .root = "/api/v1",
        .singular = "pod",
        .loggable = true,
        .group = "workloads",
        .columns = &.{
            NAME,
            .{ .name = "ready", .from = .ready },
            .{ .name = "status", .from = .pod_status },
            .{ .name = "restarts", .from = .restarts, .numeric = true },
            // What the pod asked for, which is what it was placed by. Empty where
            // it asked for nothing, because that is a choice with consequences and
            // a zero would read as having asked.
            .{ .name = "cpu", .from = .{ .asked = .{ .which = "requests", .what = "cpu" } } },
            .{ .name = "memory", .from = .{ .asked = .{ .which = "requests", .what = "memory" } } },
            AGE,
            .{ .name = "ip", .from = .{ .at = "status.podIP" } },
            .{ .name = "node", .from = .{ .at = "spec.nodeName" } },
        },
    },
    .{
        .name = "deployments",
        .kind = "Deployment",
        .root = "/apis/apps/v1",
        .singular = "deployment",
        .scalable = true,
        .group = "workloads",
        .columns = &.{
            NAME,
            .{ .name = "ready", .from = .replicas },
            .{ .name = "wanted", .from = .{ .at = "spec.replicas" }, .numeric = true },
            .{ .name = "up-to-date", .from = .{ .at = "status.updatedReplicas" }, .numeric = true, .zero_when_missing = true },
            .{ .name = "available", .from = .{ .at = "status.availableReplicas" }, .numeric = true, .zero_when_missing = true },
            AGE,
        },
    },
    .{
        .name = "statefulsets",
        .kind = "StatefulSet",
        .root = "/apis/apps/v1",
        .singular = "statefulset",
        .scalable = true,
        .group = "workloads",
        .columns = &.{
            NAME,
            .{ .name = "ready", .from = .replicas },
            .{ .name = "wanted", .from = .{ .at = "spec.replicas" }, .numeric = true },
            AGE,
        },
    },
    .{
        .name = "daemonsets",
        .kind = "DaemonSet",
        .root = "/apis/apps/v1",
        .singular = "daemonset",
        .group = "workloads",
        .columns = &.{
            NAME,
            .{ .name = "desired", .from = .{ .at = "status.desiredNumberScheduled" }, .numeric = true, .zero_when_missing = true },
            .{ .name = "ready", .from = .{ .at = "status.numberReady" }, .numeric = true, .zero_when_missing = true },
            .{ .name = "available", .from = .{ .at = "status.numberAvailable" }, .numeric = true, .zero_when_missing = true },
            AGE,
        },
    },
    .{
        .name = "replicasets",
        .kind = "ReplicaSet",
        .root = "/apis/apps/v1",
        .singular = "replicaset",
        .scalable = true,
        .group = "workloads",
        .columns = &.{
            NAME,
            .{ .name = "ready", .from = .replicas },
            .{ .name = "wanted", .from = .{ .at = "spec.replicas" }, .numeric = true },
            AGE,
        },
    },
    .{
        .name = "jobs",
        .kind = "Job",
        .root = "/apis/batch/v1",
        .singular = "job",
        .group = "workloads",
        .columns = &.{
            NAME,
            .{ .name = "succeeded", .from = .{ .at = "status.succeeded" }, .numeric = true, .zero_when_missing = true },
            .{ .name = "failed", .from = .{ .at = "status.failed" }, .numeric = true, .zero_when_missing = true },
            .{ .name = "active", .from = .{ .at = "status.active" }, .numeric = true, .zero_when_missing = true },
            AGE,
        },
    },
    .{
        .name = "cronjobs",
        .kind = "CronJob",
        .root = "/apis/batch/v1",
        .singular = "cronjob",
        .group = "workloads",
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
        .kind = "Service",
        .root = "/api/v1",
        .singular = "service",
        .group = "network",
        .columns = &.{
            NAME,
            .{ .name = "type", .from = .{ .at = "spec.type" } },
            .{ .name = "cluster-ip", .from = .{ .at = "spec.clusterIP" } },
            .{ .name = "ports", .from = .ports },
            AGE,
        },
    },
    .{
        .name = "ingresses",
        .kind = "Ingress",
        .root = "/apis/networking.k8s.io/v1",
        .singular = "ingress",
        .group = "network",
        .columns = &.{
            NAME,
            .{ .name = "class", .from = .{ .at = "spec.ingressClassName" } },
            AGE,
        },
    },
    .{
        .name = "configmaps",
        .kind = "ConfigMap",
        .root = "/api/v1",
        .singular = "configmap",
        .group = "config",
        .columns = &.{ NAME, AGE, .{ .name = "labels", .from = .labels } },
    },
    .{
        .name = "secrets",
        .kind = "Secret",
        .root = "/api/v1",
        .singular = "secret",
        .group = "config",
        .columns = &.{
            NAME,
            .{ .name = "type", .from = .{ .at = "type" } },
            AGE,
        },
    },
    .{
        .name = "persistentvolumeclaims",
        .kind = "PersistentVolumeClaim",
        .root = "/api/v1",
        .singular = "claim",
        .group = "storage",
        .columns = &.{
            NAME,
            .{ .name = "status", .from = .{ .at = "status.phase" } },
            .{ .name = "volume", .from = .{ .at = "spec.volumeName" } },
            .{ .name = "class", .from = .{ .at = "spec.storageClassName" } },
            AGE,
        },
    },
    .{
        .name = "persistentvolumes",
        .kind = "PersistentVolume",
        .root = "/api/v1",
        .singular = "volume",
        .namespaced = false,
        .group = "storage",
        .columns = &.{
            NAME,
            .{ .name = "status", .from = .{ .at = "status.phase" } },
            .{ .name = "claim", .from = .{ .at = "spec.claimRef.name" } },
            AGE,
        },
    },
    .{
        .name = "storageclasses",
        .kind = "StorageClass",
        .root = "/apis/storage.k8s.io/v1",
        .singular = "storage class",
        .namespaced = false,
        .group = "storage",
        .columns = &.{
            NAME,
            .{ .name = "provisioner", .from = .{ .at = "provisioner" } },
            AGE,
        },
    },
    .{
        .name = "roles",
        .kind = "Role",
        .root = "/apis/rbac.authorization.k8s.io/v1",
        .singular = "role",
        .group = "access",
        .columns = &.{ NAME, AGE },
    },
    .{
        .name = "rolebindings",
        .kind = "RoleBinding",
        .root = "/apis/rbac.authorization.k8s.io/v1",
        .singular = "role binding",
        .group = "access",
        .columns = &.{
            NAME,
            .{ .name = "role", .from = .{ .at = "roleRef.name" } },
            AGE,
        },
    },
    .{
        .name = "clusterroles",
        .kind = "ClusterRole",
        .root = "/apis/rbac.authorization.k8s.io/v1",
        .singular = "cluster role",
        .namespaced = false,
        .group = "access",
        .columns = &.{ NAME, AGE },
    },
    .{
        .name = "clusterrolebindings",
        .kind = "ClusterRoleBinding",
        .root = "/apis/rbac.authorization.k8s.io/v1",
        .singular = "cluster role binding",
        .namespaced = false,
        .group = "access",
        .columns = &.{
            NAME,
            .{ .name = "role", .from = .{ .at = "roleRef.name" } },
            AGE,
        },
    },
    .{
        .name = "serviceaccounts",
        .kind = "ServiceAccount",
        .root = "/api/v1",
        .singular = "service account",
        .group = "access",
        .columns = &.{ NAME, AGE },
    },
    .{
        // Helm keeps a release as a secret of its own type, one per revision, and
        // puts everything a listing needs in its labels - so this is a reading of
        // secrets rather than a kind of its own, and needs nothing unzipped.
        .name = "releases",
        .kind = "Release",
        .root = "/api/v1",
        .path = "secrets",
        .query = "fieldSelector=type%3Dhelm.sh%2Frelease.v1",
        .singular = "release",
        .remove = false,
        .group = "helm",
        .columns = &.{
            .{ .name = "name", .from = .{ .at = "metadata.labels.name" } },
            // Every revision is a row, and the one that is not superseded is the
            // one installed. That is Helm's own history, which is more than a list
            // of what is installed and answers the question after it.
            .{ .name = "revision", .from = .{ .at = "metadata.labels.version" }, .numeric = true },
            .{ .name = "status", .from = .{ .at = "metadata.labels.status" } },
            .{ .name = "namespace", .from = .{ .at = "metadata.namespace" } },
            AGE,
        },
    },
    .{
        .name = "events",
        .kind = "Event",
        .root = "/api/v1",
        .singular = "event",
        .remove = false,
        .group = "cluster",
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
        .kind = "Node",
        .root = "/api/v1",
        .singular = "node",
        .namespaced = false,
        .remove = false,
        .group = "cluster",
        .columns = &.{
            NAME,
            .{ .name = "version", .from = .{ .at = "status.nodeInfo.kubeletVersion" } },
            // What is left for pods to be placed in, rather than what the machine
            // has: the kubelet and the system keep a share back, and a node with
            // eight gigabytes never had eight to give.
            .{ .name = "cpu", .from = .{ .quantity = "status.allocatable.cpu" } },
            .{ .name = "memory", .from = .{ .quantity = "status.allocatable.memory" } },
            .{ .name = "pods", .from = .{ .at = "status.allocatable.pods" }, .numeric = true },
            .{ .name = "os", .from = .{ .at = "status.nodeInfo.operatingSystem" } },
            .{ .name = "arch", .from = .{ .at = "status.nodeInfo.architecture" } },
            AGE,
        },
    },
    .{
        .name = "namespaces",
        .kind = "Namespace",
        .root = "/api/v1",
        .singular = "namespace",
        .namespaced = false,
        .group = "cluster",
        .columns = &.{
            NAME,
            .{ .name = "status", .from = .{ .at = "status.phase" } },
            AGE,
        },
    },
};

/// The resource a manifest's `kind:` names, where this program knows it.
pub fn findKind(kind: []const u8) ?Resource {
    for (RESOURCES) |resource| {
        if (std.mem.eql(u8, resource.kind, kind)) {
            return resource;
        }
    }
    return null;
}

/// What a kind is called in a path, for one this program does not know - a custom
/// resource, mostly. Kubernetes lower-cases the kind and pluralises it by the
/// ordinary English rules, which is a guess and is treated as one: a path built
/// from it that the cluster does not have comes back as a 404 that says so.
pub fn guessPlural(arena: std.mem.Allocator, kind: []const u8) ![]const u8 {
    var lower = try arena.alloc(u8, kind.len);
    for (kind, 0..) |char, i| {
        lower[i] = std.ascii.toLower(char);
    }
    if (lower.len == 0) {
        return lower;
    }
    const last = lower[lower.len - 1];
    // ...y after a consonant becomes ...ies: NetworkPolicy, Gateway is not one.
    if (last == 'y' and lower.len > 1 and !isVowel(lower[lower.len - 2])) {
        return std.fmt.allocPrint(arena, "{s}ies", .{lower[0 .. lower.len - 1]});
    }
    // ...s, ...x, ...ch and ...sh take es: Ingress becomes ingresses.
    if (last == 's' or last == 'x' or
        (lower.len > 1 and (std.mem.endsWith(u8, lower, "ch") or std.mem.endsWith(u8, lower, "sh"))))
    {
        return std.fmt.allocPrint(arena, "{s}es", .{lower});
    }
    return std.fmt.allocPrint(arena, "{s}s", .{lower});
}

fn isVowel(char: u8) bool {
    return char == 'a' or char == 'e' or char == 'i' or char == 'o' or char == 'u';
}

/// Where an `apiVersion:` lives. The core group is `v1` and is under `/api`;
/// everything else is `group/version` and is under `/apis`.
pub fn rootOf(arena: std.mem.Allocator, api_version: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, api_version, '/') == null) {
        return std.fmt.allocPrint(arena, "/api/{s}", .{api_version});
    }
    return std.fmt.allocPrint(arena, "/apis/{s}", .{api_version});
}

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
/// A Kubernetes quantity as a number of the smallest thing it counts: millicores
/// for a CPU, bytes for memory.
///
/// The API writes these as a number and a suffix - `100m`, `4`, `2Gi`, `8143396Ki`
/// - and there are two families of suffix that look alike and are not. `Ki`, `Mi`
/// and `Gi` are powers of two; `K`, `M` and `G` are powers of ten. Reading one as
/// the other is a memory figure out by seven per cent and a CPU figure out by a
/// factor of a thousand, and neither would look wrong on a screen.
///
/// Null where it cannot be read, because a made-up number here is worse than a
/// blank: somebody sizing a cluster would believe it.
pub fn quantityOf(text: []const u8) ?i64 {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) {
        return null;
    }
    var digits: usize = 0;
    while (digits < trimmed.len and (std.ascii.isDigit(trimmed[digits]) or trimmed[digits] == '.')) : (digits += 1) {}
    const number = std.fmt.parseFloat(f64, trimmed[0..digits]) catch return null;
    const suffix = trimmed[digits..];

    // The three a CPU is written in, all of them thousandths of each other.
    // metrics-server answers in nanocores - `48209274n` is 48 millicores - and
    // reading that as anything else is a busy node that looks idle.
    if (std.mem.eql(u8, suffix, "m")) {
        return @intFromFloat(number);
    }
    if (std.mem.eql(u8, suffix, "u")) {
        return @intFromFloat(number / 1000);
    }
    if (std.mem.eql(u8, suffix, "n")) {
        return @intFromFloat(number / 1_000_000);
    }
    const scale: f64 = if (suffix.len == 0)
        1000 // a bare CPU count, in millicores
    else if (std.mem.eql(u8, suffix, "Ki"))
        1024
    else if (std.mem.eql(u8, suffix, "Mi"))
        1024 * 1024
    else if (std.mem.eql(u8, suffix, "Gi"))
        1024 * 1024 * 1024
    else if (std.mem.eql(u8, suffix, "Ti"))
        1024 * 1024 * 1024 * 1024
    else if (std.mem.eql(u8, suffix, "K") or std.mem.eql(u8, suffix, "k"))
        1000
    else if (std.mem.eql(u8, suffix, "M"))
        1000 * 1000
    else if (std.mem.eql(u8, suffix, "G"))
        1000 * 1000 * 1000
    else if (std.mem.eql(u8, suffix, "T"))
        1000 * 1000 * 1000 * 1000
    else
        return null;
    return @intFromFloat(number * scale);
}

/// Bytes as somebody reads them. Powers of two, as Kubernetes writes them, so
/// that what comes out can be compared with what a manifest asked for.
pub fn bytesText(arena: std.mem.Allocator, bytes: i64) ![]const u8 {
    const units = [_][]const u8{ "B", "Ki", "Mi", "Gi", "Ti" };
    var value: f64 = @floatFromInt(bytes);
    var unit: usize = 0;
    while (value >= 1024 and unit + 1 < units.len) : (unit += 1) {
        value /= 1024;
    }
    if (unit == 0) {
        return std.fmt.allocPrint(arena, "{d}B", .{bytes});
    }
    return std.fmt.allocPrint(arena, "{d:.1}{s}", .{ value, units[unit] });
}

/// Millicores as somebody reads them: whole cores where it divides, and the
/// thousandths kubectl uses where it does not.
pub fn coresText(arena: std.mem.Allocator, milli: i64) ![]const u8 {
    if (milli != 0 and @rem(milli, 1000) == 0) {
        return std.fmt.allocPrint(arena, "{d}", .{@divExact(milli, 1000)});
    }
    return std.fmt.allocPrint(arena, "{d}m", .{milli});
}

/// One of the two, told apart by what the number counts. A path that names a
/// CPU is read as cores; anything else is bytes.
fn readable(arena: std.mem.Allocator, found: ?Json) ![]const u8 {
    const value = found orelse return "";
    const text = switch (value) {
        .string => |t| t,
        .integer => |n| return std.fmt.allocPrint(arena, "{d}", .{n}),
        else => return "",
    };
    const amount = quantityOf(text) orelse return arena.dupe(u8, text);
    // A CPU is the only thing written in thousandths, and `m` is how it says so;
    // a memory figure never carries that suffix.
    if (std.mem.endsWith(u8, text, "m") or std.mem.indexOfAny(u8, text, "KMGTi") == null) {
        return coresText(arena, amount);
    }
    return bytesText(arena, amount);
}

/// What every container in a pod asked for, added up. A pod with nothing asked
/// for shows nothing rather than a zero: not asking is a choice with
/// consequences, and `0` reads as having asked for none.
fn askedFor(arena: std.mem.Allocator, object: Json, which: Asked) ![]const u8 {
    const containers = at(object, "spec.containers") orelse return "";
    if (containers != .array) {
        return "";
    }
    var total: i64 = 0;
    var any = false;
    for (containers.array.items) |one| {
        const found = at(one, "resources") orelse continue;
        const group = at(found, which.which) orelse continue;
        const value = at(group, which.what) orelse continue;
        if (value != .string) {
            continue;
        }
        total += quantityOf(value.string) orelse continue;
        any = true;
    }
    if (!any) {
        return "";
    }
    return if (std.mem.eql(u8, which.what, "cpu"))
        coresText(arena, total)
    else
        bytesText(arena, total);
}

/// since the epoch, so a whole page is aged from one reading of the clock.
pub fn cell(arena: std.mem.Allocator, object: Json, column: Column, now: i64) ![]const u8 {
    return switch (column.from) {
        .at => |path| {
            const found = at(object, path);
            if (column.zero_when_missing and (found == null or found.? == .null)) {
                return "0";
            }
            return try flatten(arena, found);
        },
        .age => try age(arena, object, now),
        .ready => try readyContainers(arena, object),
        .pod_status => try podStatus(arena, object),
        .restarts => try restarts(arena, object),
        .replicas => try replicaCount(arena, object),
        .labels => try labels(arena, object),
        .ports => try ports(arena, object),
        .quantity => |path| try readable(arena, at(object, path)),
        .asked => |which| try askedFor(arena, object, which),
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

/// Ready out of asked for. The denominator is `spec.containers`, not the
/// statuses: a pod that has not been scheduled has containers and no statuses at
/// all, and kubectl calls that `0/1` rather than nothing.
fn readyContainers(arena: std.mem.Allocator, object: Json) ![]const u8 {
    const wanted = at(object, "spec.containers");
    if (wanted == null or wanted.? != .array) {
        return "";
    }
    var ready: usize = 0;
    if (at(object, "status.containerStatuses")) |statuses| {
        if (statuses == .array) {
            for (statuses.array.items) |one| {
                const flag = at(one, "ready") orelse continue;
                if (flag == .bool and flag.bool) {
                    ready += 1;
                }
            }
        }
    }
    return std.fmt.allocPrint(arena, "{d}/{d}", .{ ready, wanted.?.array.items.len });
}

/// What kubectl prints under STATUS, which is not the phase.
///
/// A pod whose container keeps dying is phase `Running` with a container waiting
/// on `CrashLoopBackOff`, and a pod that has finished is phase `Succeeded` where
/// kubectl says `Completed` - so a column that showed the phase would call the
/// one broken pod in a namespace healthy, which is the single thing anybody scans
/// a pod list for. The rule is kubectl's: the phase, then whatever a container is
/// waiting on or died of, then `Terminating` over everything if the object is on
/// its way out. Containers are walked backwards so the first one wins, as there.
fn podStatus(arena: std.mem.Allocator, object: Json) ![]const u8 {
    _ = arena;
    var reason: []const u8 = "";
    if (at(object, "status.phase")) |phase| {
        if (phase == .string) {
            reason = phase.string;
        }
    }
    if (at(object, "status.reason")) |said| {
        if (said == .string and said.string.len != 0) {
            reason = said.string;
        }
    }
    if (at(object, "status.containerStatuses")) |statuses| {
        if (statuses == .array) {
            var i = statuses.array.items.len;
            while (i > 0) {
                i -= 1;
                const one = statuses.array.items[i];
                if (at(one, "state.waiting.reason")) |waiting| {
                    if (waiting == .string and waiting.string.len != 0) {
                        reason = waiting.string;
                        continue;
                    }
                }
                if (at(one, "state.terminated.reason")) |ended| {
                    if (ended == .string and ended.string.len != 0) {
                        reason = ended.string;
                    }
                }
            }
        }
    }
    // An object with a deletion timestamp is going, whatever it is doing.
    if (at(object, "metadata.deletionTimestamp")) |going| {
        if (going == .string and going.string.len != 0) {
            reason = "Terminating";
        }
    }
    return reason;
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
        if (wanted.? == .integer) wanted.?.integer else 0,
    });
}

fn ports(arena: std.mem.Allocator, object: Json) ![]const u8 {
    const found = at(object, "spec.ports") orelse return "";
    if (found != .array) {
        return "";
    }
    var out: List = .empty;
    for (found.array.items) |one| {
        if (out.items.len != 0) {
            try out.append(arena, ',');
        }
        const number = at(one, "port") orelse continue;
        const protocol = at(one, "protocol");
        try out.print(arena, "{s}/{s}", .{
            try flatten(arena, number),
            if (protocol) |value| (if (value == .string) value.string else "TCP") else "TCP",
        });
        // A node port is the one somebody outside the cluster would dial.
        if (at(one, "nodePort")) |node| {
            if (node != .null) {
                try out.print(arena, ":{s}", .{try flatten(arena, node)});
            }
        }
    }
    return out.items;
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

/// One row's cells by column name, so a test says what it means rather than
/// counting columns - and does not have to be rewritten every time one is added.
fn cellNamed(a: std.mem.Allocator, object: Json, resource: Resource, want: []const u8, now: i64) ![]const u8 {
    for (resource.columns) |column| {
        if (std.mem.eql(u8, column.name, want)) {
            return cell(a, object, column, now);
        }
    }
    return error.NoSuchColumn;
}

test "a pod's row is read and worked out from what the API answers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pod = try parsed(a,
        \\{"metadata": {"name": "api-7c9", "creationTimestamp": "2026-08-20T10:00:00Z",
        \\              "labels": {"app": "api"}},
        \\ "spec": {"nodeName": "node-1", "containers": [
        \\     {"name": "api", "resources": {"requests": {"cpu": "100m", "memory": "64Mi"}}},
        \\     {"name": "sidecar", "resources": {"requests": {"cpu": "250m", "memory": "192Mi"}}}]},
        \\ "status": {"phase": "Running", "podIP": "10.1.2.3",
        \\            "containerStatuses": [{"ready": true, "restartCount": 2},
        \\                                  {"ready": false, "restartCount": 5}]}}
    );
    const now = epochOf("2026-08-22T14:30:00Z").?;
    const resource = find("pods").?;

    try testing.expectEqualStrings("api-7c9", try cellNamed(a, pod, resource, "name", now));
    try testing.expectEqualStrings("1/2", try cellNamed(a, pod, resource, "ready", now));
    try testing.expectEqualStrings("Running", try cellNamed(a, pod, resource, "status", now));
    try testing.expectEqualStrings("7", try cellNamed(a, pod, resource, "restarts", now));
    try testing.expectEqualStrings("2d4h", try cellNamed(a, pod, resource, "age", now));
    try testing.expectEqualStrings("10.1.2.3", try cellNamed(a, pod, resource, "ip", now));
    try testing.expectEqualStrings("node-1", try cellNamed(a, pod, resource, "node", now));

    // What the pod asked for is the whole pod's appetite, not the first
    // container's: 100m and 250m is 350m, and 64Mi and 192Mi is 256Mi.
    try testing.expectEqualStrings("350m", try cellNamed(a, pod, resource, "cpu", now));
    try testing.expectEqualStrings("256.0Mi", try cellNamed(a, pod, resource, "memory", now));
}

test "a pod that asked for nothing says nothing, rather than asking for none" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pod = try parsed(a,
        \\{"metadata": {"name": "bez"}, "spec": {"containers": [{"name": "one"}]}}
    );
    const resource = find("pods").?;
    // Empty, not "0": not asking is a choice the scheduler treats differently
    // from asking for none, and a zero here would read as the second.
    try testing.expectEqualStrings("", try cellNamed(a, pod, resource, "cpu", 0));
    try testing.expectEqualStrings("", try cellNamed(a, pod, resource, "memory", 0));
}

test "a node says what is left to place pods in, in units somebody reads" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const node = try parsed(a,
        \\{"metadata": {"name": "node-1"},
        \\ "status": {"allocatable": {"cpu": "14", "memory": "8143396Ki", "pods": "110"},
        \\            "capacity": {"cpu": "16", "memory": "8388608Ki"},
        \\            "nodeInfo": {"kubeletVersion": "v1.31.5", "operatingSystem": "linux",
        \\                         "architecture": "arm64"}}}
    );
    const resource = find("nodes").?;
    try testing.expectEqualStrings("14", try cellNamed(a, node, resource, "cpu", 0));
    try testing.expectEqualStrings("7.8Gi", try cellNamed(a, node, resource, "memory", 0));
    try testing.expectEqualStrings("110", try cellNamed(a, node, resource, "pods", 0));
    // Allocatable and not capacity: the kubelet and the system keep a share back,
    // and a node with sixteen cores never had sixteen to give.
    try testing.expectEqualStrings("v1.31.5", try cellNamed(a, node, resource, "version", 0));
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
    // A pod that has containers and no statuses yet - one waiting to be
    // scheduled - is 0 of however many it asked for, the way kubectl counts it.
    const waiting = try parsed(a, "{\"spec\": {\"containers\": [{\"name\": \"a\"}]}, \"status\": {\"phase\": \"Pending\"}}");
    try testing.expectEqualStrings("0/1", try cell(a, waiting, .{ .name = "ready", .from = .ready }, now));
    try testing.expectEqualStrings("Pending", try cell(a, waiting, .{ .name = "s", .from = .pod_status }, now));
}

test "a pod's status is what kubectl prints, which is not its phase" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const column: Column = .{ .name = "status", .from = .pod_status };
    const cases = [_]struct { object: []const u8, says: []const u8 }{
        // The one that matters: a pod stuck in a crash loop is phase Running.
        .{
            .object =
            \\{"status": {"phase": "Running", "containerStatuses":
            \\  [{"state": {"waiting": {"reason": "CrashLoopBackOff"}}}]}}
            ,
            .says = "CrashLoopBackOff",
        },
        // And one that has finished is phase Succeeded, which kubectl calls done.
        .{
            .object =
            \\{"status": {"phase": "Succeeded", "containerStatuses":
            \\  [{"state": {"terminated": {"reason": "Completed"}}}]}}
            ,
            .says = "Completed",
        },
        .{
            .object =
            \\{"status": {"phase": "Pending", "containerStatuses":
            \\  [{"state": {"waiting": {"reason": "ImagePullBackOff"}}}]}}
            ,
            .says = "ImagePullBackOff",
        },
        // On its way out, whatever it was doing.
        .{
            .object =
            \\{"metadata": {"deletionTimestamp": "2026-08-22T12:00:00Z"},
            \\ "status": {"phase": "Running", "containerStatuses": [{"state": {"running": {}}}]}}
            ,
            .says = "Terminating",
        },
        // A pod the node evicted says why in status.reason.
        .{
            .object = "{\"status\": {\"phase\": \"Failed\", \"reason\": \"Evicted\"}}",
            .says = "Evicted",
        },
        // Nothing interesting anywhere: the phase, as before.
        .{
            .object = "{\"status\": {\"phase\": \"Running\", \"containerStatuses\": [{\"state\": {\"running\": {}}}]}}",
            .says = "Running",
        },
        .{ .object = "{}", .says = "" },
    };
    for (cases) |case| {
        try testing.expectEqualStrings(case.says, try cell(a, try parsed(a, case.object), column, 0));
    }
}

test "a counter the API leaves out at zero reads as zero, not as unknown" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const column: Column = .{ .name = "available", .from = .{ .at = "status.availableReplicas" }, .numeric = true, .zero_when_missing = true };
    const none = try parsed(a, "{\"status\": {}}");
    try testing.expectEqualStrings("0", try cell(a, none, column, 0));
    const some = try parsed(a, "{\"status\": {\"availableReplicas\": 3}}");
    try testing.expectEqualStrings("3", try cell(a, some, column, 0));
    // Without the flag it is still empty, because a missing spec.replicas means
    // nobody set one rather than none.
    const plain: Column = .{ .name = "wanted", .from = .{ .at = "spec.replicas" }, .numeric = true };
    try testing.expectEqualStrings("", try cell(a, none, plain, 0));
}

test "a service says its ports the way kubectl does" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const column: Column = .{ .name = "ports", .from = .ports };
    const one = try parsed(a, "{\"spec\": {\"ports\": [{\"port\": 80, \"protocol\": \"TCP\"}]}}");
    try testing.expectEqualStrings("80/TCP", try cell(a, one, column, 0));
    const many = try parsed(a, "{\"spec\": {\"ports\": [{\"port\": 80}, {\"port\": 443, \"protocol\": \"TCP\", \"nodePort\": 30443}]}}");
    try testing.expectEqualStrings("80/TCP,443/TCP:30443", try cell(a, many, column, 0));
    try testing.expectEqualStrings("", try cell(a, try parsed(a, "{\"spec\": {}}"), column, 0));
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
        const made = try parsed(a, try std.fmt.allocPrint(a, "{{\"metadata\": {{\"creationTimestamp\": \"{s}\"}}}}", .{case.made}));
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

test "a quantity is read in the units it was written in, not the ones it looks like" {
    // CPU, counted in thousandths whichever way it is written.
    try testing.expectEqual(@as(?i64, 100), quantityOf("100m"));
    try testing.expectEqual(@as(?i64, 4000), quantityOf("4"));
    try testing.expectEqual(@as(?i64, 1500), quantityOf("1.5"));
    // What metrics-server answers in. A node using 48 millicores writes it as
    // forty-eight million nanocores, and reading that as millicores is a busy
    // machine that looks asleep - which is what it looked like the first time.
    try testing.expectEqual(@as(?i64, 48), quantityOf("48209274n"));
    try testing.expectEqual(@as(?i64, 1000), quantityOf("1000000000n"));
    try testing.expectEqual(@as(?i64, 5), quantityOf("5000u"));

    // Memory. `Ki` is a thousand and twenty-four and `K` is a thousand, which is
    // the pair this exists to keep apart.
    try testing.expectEqual(@as(?i64, 1024), quantityOf("1Ki"));
    try testing.expectEqual(@as(?i64, 1000), quantityOf("1K"));
    try testing.expectEqual(@as(?i64, 2 * 1024 * 1024 * 1024), quantityOf("2Gi"));
    try testing.expectEqual(@as(?i64, 8143396 * 1024), quantityOf("8143396Ki"));

    // Nothing invented out of what cannot be read: a made-up number here is
    // worse than a blank, because somebody sizing a cluster would believe it.
    try testing.expectEqual(@as(?i64, null), quantityOf(""));
    try testing.expectEqual(@as(?i64, null), quantityOf("plenty"));
    try testing.expectEqual(@as(?i64, null), quantityOf("12Zi"));
}

test "and is written back the way somebody reads it" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    try testing.expectEqualStrings("4", try coresText(arena, 4000));
    try testing.expectEqualStrings("100m", try coresText(arena, 100));
    try testing.expectEqualStrings("1500m", try coresText(arena, 1500));
    try testing.expectEqualStrings("0m", try coresText(arena, 0));

    try testing.expectEqualStrings("2.0Gi", try bytesText(arena, 2 * 1024 * 1024 * 1024));
    try testing.expectEqualStrings("7.8Gi", try bytesText(arena, 8143396 * 1024));
    try testing.expectEqualStrings("512B", try bytesText(arena, 512));
    try testing.expectEqualStrings("0B", try bytesText(arena, 0));

    // The round trip is what matters: what a manifest asked for comes back
    // saying the same thing.
    try testing.expectEqualStrings("2.0Gi", try bytesText(arena, quantityOf("2Gi").?));
    try testing.expectEqualStrings("100m", try coresText(arena, quantityOf("100m").?));
}

test "a manifest's kind comes back as the path it lives under" {
    try testing.expectEqualStrings("deployments", findKind("Deployment").?.name);
    try testing.expectEqualStrings("/apis/apps/v1", findKind("Deployment").?.root);
    try testing.expectEqualStrings("pods", findKind("Pod").?.name);
    try testing.expectEqualStrings("ingresses", findKind("Ingress").?.name);
    // Case matters in a manifest and it matters here.
    try testing.expect(findKind("deployment") == null);
    try testing.expect(findKind("Widget") == null);
}

test "a kind nobody knows is pluralised the way Kubernetes does it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][2][]const u8{
        .{ "Widget", "widgets" },
        .{ "Certificate", "certificates" },
        // ...y after a consonant is ...ies, and after a vowel is not.
        .{ "NetworkPolicy", "networkpolicies" },
        .{ "Gateway", "gateways" },
        // ...s, ...x, ...ch and ...sh take es.
        .{ "Ingress", "ingresses" },
        .{ "Netbox", "netboxes" },
        .{ "Switch", "switches" },
        .{ "Brush", "brushes" },
        .{ "", "" },
    };
    for (cases) |case| {
        try testing.expectEqualStrings(case[1], try guessPlural(a, case[0]));
    }
    // And the ones this program does know come from the table, not the guess:
    // the guess would have said "endpointses" for a few of them.
    for (RESOURCES) |resource| {
        try testing.expectEqualStrings(resource.name, findKind(resource.kind).?.name);
    }
}

test "an apiVersion says which root it is under" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The core group is the one without a slash, and it is /api rather than /apis.
    try testing.expectEqualStrings("/api/v1", try rootOf(a, "v1"));
    try testing.expectEqualStrings("/apis/apps/v1", try rootOf(a, "apps/v1"));
    try testing.expectEqualStrings("/apis/batch/v1", try rootOf(a, "batch/v1"));
    try testing.expectEqualStrings("/apis/networking.k8s.io/v1", try rootOf(a, "networking.k8s.io/v1"));
}

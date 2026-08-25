//! What `k8s://…` means.
//!
//! Almost nothing, on purpose: everything about how to reach a cluster is already
//! in the kubeconfig, and a target that repeated any of it would be a second place
//! for the same fact to be wrong. So a target names a context and, if it likes, a
//! namespace to open on - which is exactly what somebody at a terminal chooses
//! between, and nothing else.
//!
//!     k8s://                     the current context of the default kubeconfig
//!     k8s://prod                 the context called prod
//!     k8s://prod/payments        that context, opened on that namespace
//!     k8s://?kubeconfig=/path    a file other than $KUBECONFIG or ~/.kube/config
//!     k8s://prod?insecure=1      do not check the cluster's certificate
//!
//! Text in, a structure out: this reads no file and no environment.

const std = @import("std");
const db = @import("../db.zig");

pub const Parts = struct {
    /// Empty means the file's own current context.
    context: []const u8 = "",
    /// Empty means whatever the context says, and failing that `default`.
    namespace: []const u8 = "",
    /// Empty means `$KUBECONFIG`, then `~/.kube/config`.
    kubeconfig: []const u8 = "",
    /// Said in the target, over whatever the kubeconfig says.
    insecure: bool = false,
};

const SCHEMES = [_][]const u8{ "k8s://", "kubernetes://", "kube://" };

pub fn owns(target: []const u8) bool {
    for (SCHEMES) |scheme| {
        if (std.ascii.startsWithIgnoreCase(target, scheme)) {
            return true;
        }
    }
    return false;
}

pub fn parse(arena: std.mem.Allocator, target: []const u8) !Parts {
    var rest: []const u8 = target;
    for (SCHEMES) |scheme| {
        if (std.ascii.startsWithIgnoreCase(rest, scheme)) {
            rest = rest[scheme.len..];
            break;
        }
    } else {
        return error.NotK8s;
    }

    var parts = Parts{};
    if (std.mem.indexOfScalar(u8, rest, '?')) |mark| {
        try options(arena, &parts, rest[mark + 1 ..]);
        rest = rest[0..mark];
    }
    // A context name may have a slash in it - a kubeconfig written by hand often
    // does - so the namespace is what follows the *last* one, and only when the
    // target has two parts to begin with.
    if (std.mem.lastIndexOfScalar(u8, rest, '/')) |mark| {
        parts.namespace = try unescape(arena, rest[mark + 1 ..]);
        rest = rest[0..mark];
    }
    parts.context = try unescape(arena, rest);
    return parts;
}

fn options(arena: std.mem.Allocator, parts: *Parts, query: []const u8) !void {
    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        if (pair.len == 0) {
            continue;
        }
        const cut = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const name = pair[0..cut];
        const value = if (cut < pair.len) try unescape(arena, pair[cut + 1 ..]) else "";
        if (std.ascii.eqlIgnoreCase(name, "kubeconfig")) {
            parts.kubeconfig = value;
        } else if (std.ascii.eqlIgnoreCase(name, "namespace") or std.ascii.eqlIgnoreCase(name, "ns")) {
            parts.namespace = value;
        } else if (std.ascii.eqlIgnoreCase(name, "context")) {
            parts.context = value;
        } else if (std.ascii.eqlIgnoreCase(name, "insecure")) {
            parts.insecure = value.len == 0 or std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true");
        }
    }
}

/// Percent decoding, because a context name may hold a slash or a colon and
/// somebody who escaped one meant it.
fn unescape(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '%') == null) {
        return text;
    }
    var out: db.List = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '%' and i + 2 < text.len) {
            const byte = std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16) catch {
                try out.append(arena, text[i]);
                continue;
            };
            try out.append(arena, byte);
            i += 2;
            continue;
        }
        try out.append(arena, text[i]);
    }
    return out.items;
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

test "a target names a context, a namespace, or neither" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const bare = try parse(a, "k8s://");
    try testing.expectEqualStrings("", bare.context);
    try testing.expectEqualStrings("", bare.namespace);

    const named = try parse(a, "k8s://prod");
    try testing.expectEqualStrings("prod", named.context);
    try testing.expectEqualStrings("", named.namespace);

    const both = try parse(a, "k8s://prod/payments");
    try testing.expectEqualStrings("prod", both.context);
    try testing.expectEqualStrings("payments", both.namespace);

    // A context name with slashes in it, which an ARN-shaped one has plenty of.
    const arn = try parse(a, "k8s://arn:aws:eks:eu-west-1:1234:cluster/live/payments");
    try testing.expectEqualStrings("arn:aws:eks:eu-west-1:1234:cluster/live", arn.context);
    try testing.expectEqualStrings("payments", arn.namespace);
}

test "the options, and the schemes that mean the same thing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const full = try parse(a, "k8s://prod?kubeconfig=/tmp/other.yaml&insecure=1&ns=kube-system");
    try testing.expectEqualStrings("prod", full.context);
    try testing.expectEqualStrings("/tmp/other.yaml", full.kubeconfig);
    try testing.expectEqualStrings("kube-system", full.namespace);
    try testing.expect(full.insecure);

    // `insecure` on its own is still yes, and anything else is no.
    try testing.expect((try parse(a, "k8s://?insecure")).insecure);
    try testing.expect((try parse(a, "k8s://?insecure=true")).insecure);
    try testing.expect(!(try parse(a, "k8s://?insecure=0")).insecure);
    try testing.expect(!(try parse(a, "k8s://")).insecure);

    for ([_][]const u8{ "k8s://x", "kubernetes://x", "kube://x", "K8S://x" }) |target| {
        try testing.expect(owns(target));
        try testing.expectEqualStrings("x", (try parse(a, target)).context);
    }
    try testing.expect(!owns("postgres://host/db"));
    try testing.expect(!owns("k8s"));
    try testing.expectError(error.NotK8s, parse(a, "redis://host"));
}

test "a name that was escaped comes back as it was written" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const escaped = try parse(a, "k8s://one%2Ftwo/three");
    try testing.expectEqualStrings("one/two", escaped.context);
    try testing.expectEqualStrings("three", escaped.namespace);
    // A stray percent is a percent, not a failure.
    try testing.expectEqualStrings("100%done", (try parse(a, "k8s://100%done")).context);
}

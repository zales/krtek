//! A kubeconfig: which cluster, which user, and how to prove who you are.
//!
//! Two halves, and the split is the point. `pick` is text in and a structure out
//! - it chooses a context and hands back what the file said, `-data` fields still
//! base64 and `-file` fields still paths - so the whole of the choosing is
//! testable against a document in a string, with no home directory anywhere near
//! it. `resolve` is the half that touches the world: it decodes, reads the files
//! the file points at, and runs the credential plugin.
//!
//! What is deliberately not here is a merge of several kubeconfigs. `KUBECONFIG`
//! may name a list and kubectl merges them, first mention winning; that is done,
//! because a list is common enough, but the merge is over whole named entries
//! rather than field by field, which is the part of kubectl's rules nobody relies
//! on and every reimplementation gets differently.

const std = @import("std");
const targets = @import("../targets.zig");
const db = @import("../db.zig");
const yaml = @import("yaml.zig");
const exec = @import("exec.zig");

const List = db.List;

pub const Error = error{ Config, OutOfMemory };

/// One context of a kubeconfig, exactly as the file wrote it.
pub const Chosen = struct {
    context: []const u8 = "",
    cluster: []const u8 = "",
    user: []const u8 = "",
    server: []const u8 = "",
    namespace: []const u8 = "",
    insecure: bool = false,
    ca_data: []const u8 = "",
    ca_file: []const u8 = "",
    cert_data: []const u8 = "",
    cert_file: []const u8 = "",
    key_data: []const u8 = "",
    key_file: []const u8 = "",
    token: []const u8 = "",
    token_file: []const u8 = "",
    /// The credential plugin, where the user is one.
    command: []const u8 = "",
    args: []const []const u8 = &.{},
    env: []const exec.Variable = &.{},
};

/// The same, with everything the driver needs already in hand.
pub const Ready = struct {
    context: []const u8 = "",
    server: []const u8 = "",
    namespace: []const u8 = "default",
    insecure: bool = false,
    ca_pem: []const u8 = "",
    cert_pem: []const u8 = "",
    key_pem: []const u8 = "",
    token: []const u8 = "",
};

/// The names of every context in the file, in the order they are written - what
/// to offer when the one asked for is not there.
pub fn contexts(arena: std.mem.Allocator, doc: yaml.Value) Error![][]const u8 {
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    for ((doc.get("contexts") orelse return &.{}).items()) |entry| {
        const name = (entry.get("name") orelse continue).text();
        if (name.len != 0) {
            try names.append(arena, name);
        }
    }
    return names.items;
}

/// The context `want` names, or the current one when `want` is empty. `why` says
/// what was missing when the answer is null.
pub fn pick(arena: std.mem.Allocator, doc: yaml.Value, want: []const u8, why: *List) Error!Chosen {
    const wanted = if (want.len != 0) want else (doc.get("current-context") orelse yaml.Value{ .scalar = "" }).text();
    if (wanted.len == 0) {
        try why.appendSlice(arena, "the kubeconfig names no current context, and none was asked for");
        return error.Config;
    }
    const context = byName(doc.get("contexts"), wanted) orelse {
        const known = try contexts(arena, doc);
        try why.print(arena, "there is no context called {s}", .{wanted});
        if (known.len != 0) {
            try why.appendSlice(arena, " - there is ");
            for (known, 0..) |name, i| {
                if (i != 0) {
                    try why.appendSlice(arena, if (i + 1 == known.len) " and " else ", ");
                }
                try why.appendSlice(arena, name);
            }
        }
        return error.Config;
    };

    var chosen = Chosen{ .context = wanted };
    const body = context.get("context") orelse yaml.Value{ .map = &.{} };
    chosen.cluster = (body.get("cluster") orelse yaml.Value{ .scalar = "" }).text();
    chosen.user = (body.get("user") orelse yaml.Value{ .scalar = "" }).text();
    chosen.namespace = (body.get("namespace") orelse yaml.Value{ .scalar = "" }).text();

    const cluster = byName(doc.get("clusters"), chosen.cluster) orelse {
        try why.print(arena, "the context {s} names a cluster called {s}, which is not in the file", .{ wanted, chosen.cluster });
        return error.Config;
    };
    const details = cluster.get("cluster") orelse yaml.Value{ .map = &.{} };
    chosen.server = (details.get("server") orelse yaml.Value{ .scalar = "" }).text();
    if (chosen.server.len == 0) {
        try why.print(arena, "the cluster {s} has no server address", .{chosen.cluster});
        return error.Config;
    }
    chosen.ca_data = (details.get("certificate-authority-data") orelse yaml.Value{ .scalar = "" }).text();
    chosen.ca_file = (details.get("certificate-authority") orelse yaml.Value{ .scalar = "" }).text();
    chosen.insecure = std.mem.eql(u8, (details.get("insecure-skip-tls-verify") orelse yaml.Value{ .scalar = "" }).text(), "true");

    // A context with no user is legitimate: an unauthenticated cluster, or a
    // proxy in front of one that adds the credentials itself.
    if (byName(doc.get("users"), chosen.user)) |user| {
        const account = user.get("user") orelse yaml.Value{ .map = &.{} };
        chosen.cert_data = (account.get("client-certificate-data") orelse yaml.Value{ .scalar = "" }).text();
        chosen.cert_file = (account.get("client-certificate") orelse yaml.Value{ .scalar = "" }).text();
        chosen.key_data = (account.get("client-key-data") orelse yaml.Value{ .scalar = "" }).text();
        chosen.key_file = (account.get("client-key") orelse yaml.Value{ .scalar = "" }).text();
        chosen.token = (account.get("token") orelse yaml.Value{ .scalar = "" }).text();
        chosen.token_file = (account.get("tokenFile") orelse yaml.Value{ .scalar = "" }).text();
        if (account.get("exec")) |credential_plugin| {
            chosen.command = (credential_plugin.get("command") orelse yaml.Value{ .scalar = "" }).text();
            var args: std.ArrayListUnmanaged([]const u8) = .empty;
            for ((credential_plugin.get("args") orelse yaml.Value{ .list = &.{} }).items()) |arg| {
                try args.append(arena, arg.text());
            }
            chosen.args = args.items;
            var env: std.ArrayListUnmanaged(exec.Variable) = .empty;
            for ((credential_plugin.get("env") orelse yaml.Value{ .list = &.{} }).items()) |entry| {
                const name = (entry.get("name") orelse continue).text();
                if (name.len != 0) {
                    try env.append(arena, .{
                        .name = name,
                        .value = (entry.get("value") orelse yaml.Value{ .scalar = "" }).text(),
                    });
                }
            }
            chosen.env = env.items;
        }
        // An `auth-provider` is the old shape of the same idea, retired in 1.26
        // and removed from kubectl. Saying so beats a cluster that answers 401.
        if (account.get("auth-provider") != null and chosen.command.len == 0 and chosen.token.len == 0) {
            try why.print(arena, "the user {s} uses auth-provider, which Kubernetes retired - kubectl will rewrite it to exec", .{chosen.user});
            return error.Config;
        }
    }
    return chosen;
}

fn byName(list: ?yaml.Value, want: []const u8) ?yaml.Value {
    for ((list orelse return null).items()) |entry| {
        const name = (entry.get("name") orelse continue).text();
        if (std.mem.eql(u8, name, want)) {
            return entry;
        }
    }
    return null;
}

/// Everything the driver needs to open a connection: certificates decoded, files
/// read, and the credential plugin run if there is one.
pub fn resolve(arena: std.mem.Allocator, chosen: Chosen, why: *List) Error!Ready {
    var ready = Ready{
        .context = chosen.context,
        .server = chosen.server,
        .insecure = chosen.insecure,
    };
    if (chosen.namespace.len != 0) {
        ready.namespace = chosen.namespace;
    }
    ready.ca_pem = try material(arena, chosen.ca_data, chosen.ca_file, "certificate authority", why);
    ready.cert_pem = try material(arena, chosen.cert_data, chosen.cert_file, "client certificate", why);
    ready.key_pem = try material(arena, chosen.key_data, chosen.key_file, "client key", why);
    ready.token = std.mem.trim(u8, try material(arena, "", chosen.token_file, "token file", why), " \r\n\t");
    if (ready.token.len == 0) {
        ready.token = chosen.token;
    }
    if (chosen.command.len != 0) {
        const credential = try plugin(arena, chosen, why);
        if (credential.token.len != 0) {
            ready.token = credential.token;
        }
        if (credential.cert_pem.len != 0) {
            ready.cert_pem = credential.cert_pem;
            ready.key_pem = credential.key_pem;
        }
    }
    return ready;
}

/// A `-data` field, base64, or the file a `-file` field points at. Both may be
/// empty and that is not an error: most of them are optional most of the time.
fn material(arena: std.mem.Allocator, data: []const u8, path: []const u8, what: []const u8, why: *List) Error![]const u8 {
    if (data.len != 0) {
        const decoder = std.base64.standard.Decoder;
        const size = decoder.calcSizeForSlice(data) catch {
            try why.print(arena, "the {s} in the kubeconfig is not base64", .{what});
            return error.Config;
        };
        const out = try arena.alloc(u8, size);
        decoder.decode(out, data) catch {
            try why.print(arena, "the {s} in the kubeconfig is not base64", .{what});
            return error.Config;
        };
        return out;
    }
    if (path.len == 0) {
        return "";
    }
    return targets.readFile(arena, path) catch {
        try why.print(arena, "the {s} is at {s}, which cannot be read", .{ what, path });
        return error.Config;
    };
}

const Credential = struct {
    token: []const u8 = "",
    cert_pem: []const u8 = "",
    key_pem: []const u8 = "",
};

/// Run the credential plugin and read the ExecCredential it prints. Its shape has
/// been the same across every apiVersion of it: what matters is under `status`.
fn plugin(arena: std.mem.Allocator, chosen: Chosen, why: *List) Error!Credential {
    var trouble: List = .empty;
    const got = exec.run(arena, chosen.command, chosen.args, chosen.env, &trouble) catch {
        try why.print(arena, "the credential plugin {s} did not run: {s}", .{ chosen.command, trouble.items });
        return error.Config;
    };
    if (got.status != 0) {
        try why.print(arena, "the credential plugin {s} failed", .{chosen.command});
        // What it printed is what says why, and it is usually one line.
        const said = std.mem.trim(u8, got.out, " \r\n\t");
        if (said.len != 0) {
            try why.print(arena, ": {s}", .{firstLine(said)});
        }
        return error.Config;
    }
    const parsed = std.json.parseFromSlice(std.json.Value, arena, got.out, .{}) catch {
        try why.print(arena, "the credential plugin {s} printed something that is not JSON", .{chosen.command});
        return error.Config;
    };
    const status = switch (parsed.value) {
        .object => |root| root.get("status") orelse {
            try why.print(arena, "the credential plugin {s} printed no status", .{chosen.command});
            return error.Config;
        },
        else => {
            try why.print(arena, "the credential plugin {s} printed no status", .{chosen.command});
            return error.Config;
        },
    };
    var credential = Credential{};
    if (status == .object) {
        if (status.object.get("token")) |value| {
            if (value == .string) {
                credential.token = value.string;
            }
        }
        if (status.object.get("clientCertificateData")) |value| {
            if (value == .string) {
                credential.cert_pem = value.string;
            }
        }
        if (status.object.get("clientKeyData")) |value| {
            if (value == .string) {
                credential.key_pem = value.string;
            }
        }
    }
    if (credential.token.len == 0 and credential.cert_pem.len == 0) {
        try why.print(arena, "the credential plugin {s} gave back neither a token nor a certificate", .{chosen.command});
        return error.Config;
    }
    return credential;
}

fn firstLine(text: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    return text[0..end];
}

/// Where the kubeconfig is: what was asked for, then `KUBECONFIG`, then
/// `~/.kube/config`. A `KUBECONFIG` naming several files is read as the first one
/// that is there.
pub fn find(arena: std.mem.Allocator, named: []const u8) Error!?[]const u8 {
    if (named.len != 0) {
        return try arena.dupe(u8, named);
    }
    if (std.c.getenv("KUBECONFIG")) |value| {
        var places = std.mem.splitScalar(u8, std.mem.sliceTo(value, 0), ':');
        while (places.next()) |place| {
            if (place.len == 0) {
                continue;
            }
            _ = targets.readFile(arena, place) catch continue;
            return try arena.dupe(u8, place);
        }
    }
    const home = std.c.getenv("HOME") orelse return null;
    return try std.fmt.allocPrint(arena, "{s}/.kube/config", .{std.mem.sliceTo(home, 0)});
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

const SAMPLE =
    \\apiVersion: v1
    \\kind: Config
    \\current-context: work
    \\clusters:
    \\- cluster:
    \\    certificate-authority-data: aGVsbG8=
    \\    server: https://10.0.0.1:6443
    \\  name: work
    \\- cluster:
    \\    server: http://127.0.0.1:8001
    \\    insecure-skip-tls-verify: true
    \\  name: proxy
    \\contexts:
    \\- context:
    \\    cluster: work
    \\    namespace: payments
    \\    user: alice
    \\  name: work
    \\- context:
    \\    cluster: proxy
    \\    user: nobody
    \\  name: proxy
    \\users:
    \\- name: alice
    \\  user:
    \\    exec:
    \\      apiVersion: client.authentication.k8s.io/v1beta1
    \\      command: aws
    \\      args:
    \\      - eks
    \\      - get-token
    \\      env:
    \\      - name: AWS_PROFILE
    \\        value: work
    \\- name: nobody
    \\  user: {}
;

fn document(arena: std.mem.Allocator, text: []const u8) !yaml.Value {
    var why: List = .empty;
    return yaml.parse(arena, text, &why);
}

test "the current context, and everything it points at" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var why: List = .empty;
    const chosen = try pick(a, try document(a, SAMPLE), "", &why);
    try testing.expectEqualStrings("work", chosen.context);
    try testing.expectEqualStrings("https://10.0.0.1:6443", chosen.server);
    try testing.expectEqualStrings("payments", chosen.namespace);
    try testing.expectEqualStrings("aGVsbG8=", chosen.ca_data);
    try testing.expect(!chosen.insecure);
    try testing.expectEqualStrings("aws", chosen.command);
    try testing.expectEqual(@as(usize, 2), chosen.args.len);
    try testing.expectEqualStrings("get-token", chosen.args[1]);
    try testing.expectEqualStrings("AWS_PROFILE", chosen.env[0].name);
    try testing.expectEqualStrings("work", chosen.env[0].value);
}

test "a context asked for by name, and one that is not there" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var why: List = .empty;
    const chosen = try pick(a, try document(a, SAMPLE), "proxy", &why);
    try testing.expectEqualStrings("http://127.0.0.1:8001", chosen.server);
    try testing.expect(chosen.insecure);
    // A user with nothing in it is a cluster nobody has to prove anything to.
    try testing.expectEqualStrings("", chosen.token);
    try testing.expectEqualStrings("", chosen.command);
    // And no namespace named means the default one, which resolve fills in.
    try testing.expectEqualStrings("", chosen.namespace);

    why.clearRetainingCapacity();
    try testing.expectError(error.Config, pick(a, try document(a, SAMPLE), "staging", &why));
    // It says what there is instead, because a typo is the usual reason.
    try testing.expect(std.mem.indexOf(u8, why.items, "no context called staging") != null);
    try testing.expect(std.mem.indexOf(u8, why.items, "work and proxy") != null);
}

test "what is missing is named, rather than left to fail later" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { text: []const u8, says: []const u8 }{
        .{ .text = "clusters: []\ncontexts: []\nusers: []\n", .says = "no current context" },
        .{
            .text = "current-context: x\ncontexts:\n- context:\n    cluster: gone\n  name: x\nclusters: []\n",
            .says = "not in the file",
        },
        .{
            .text = "current-context: x\ncontexts:\n- context:\n    cluster: c\n  name: x\nclusters:\n- cluster: {}\n  name: c\n",
            .says = "no server address",
        },
        .{
            .text = "current-context: x\ncontexts:\n- context:\n    cluster: c\n    user: u\n  name: x\n" ++
                "clusters:\n- cluster:\n    server: https://h\n  name: c\n" ++
                "users:\n- name: u\n  user:\n    auth-provider:\n      name: gcp\n",
            .says = "auth-provider",
        },
    };
    for (cases) |case| {
        var why: List = .empty;
        try testing.expectError(error.Config, pick(a, try document(a, case.text), "", &why));
        try testing.expect(std.mem.indexOf(u8, why.items, case.says) != null);
    }
}

test "resolving decodes what the file carries and fills in the default namespace" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var why: List = .empty;

    // "hello" in base64, which is what the sample's authority is.
    const ready = try resolve(a, .{
        .context = "work",
        .server = "https://10.0.0.1:6443",
        .ca_data = "aGVsbG8=",
        .token = "abc",
    }, &why);
    try testing.expectEqualStrings("hello", ready.ca_pem);
    try testing.expectEqualStrings("abc", ready.token);
    try testing.expectEqualStrings("default", ready.namespace);

    // Base64 that is not base64 says so, rather than handing over rubbish that
    // OpenSSL would later call a certificate problem.
    why.clearRetainingCapacity();
    try testing.expectError(error.Config, resolve(a, .{ .ca_data = "not base64!!" }, &why));
    try testing.expect(std.mem.indexOf(u8, why.items, "not base64") != null);

    // A file that is not there is named.
    why.clearRetainingCapacity();
    try testing.expectError(error.Config, resolve(a, .{ .ca_file = "/no/such/authority.pem" }, &why));
    try testing.expect(std.mem.indexOf(u8, why.items, "/no/such/authority.pem") != null);
}

test "the credential plugin's answer, and every way it can fail to be one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var why: List = .empty;

    const good = try resolve(a, .{
        .command = "sh",
        .args = &.{ "-c", "echo '{\"kind\":\"ExecCredential\",\"status\":{\"token\":\"from-the-plugin\"}}'" },
    }, &why);
    try testing.expectEqualStrings("from-the-plugin", good.token);

    // A plugin may hand back a certificate instead of a token.
    const paired = try resolve(a, .{
        .command = "sh",
        .args = &.{ "-c", "echo '{\"status\":{\"clientCertificateData\":\"CERT\",\"clientKeyData\":\"KEY\"}}'" },
    }, &why);
    try testing.expectEqualStrings("CERT", paired.cert_pem);
    try testing.expectEqualStrings("KEY", paired.key_pem);

    const cases = [_]struct { script: []const u8, says: []const u8 }{
        .{ .script = "echo 'could not find profile' >&2; exit 1", .says = "failed" },
        .{ .script = "echo not json at all", .says = "not JSON" },
        .{ .script = "echo '{\"kind\":\"ExecCredential\"}'", .says = "no status" },
        .{ .script = "echo '{\"status\":{}}'", .says = "neither a token nor a certificate" },
    };
    for (cases) |case| {
        why.clearRetainingCapacity();
        try testing.expectError(error.Config, resolve(a, .{
            .command = "sh",
            .args = &.{ "-c", case.script },
        }, &why));
        try testing.expect(std.mem.indexOf(u8, why.items, case.says) != null);
    }

    // A plugin that fails says what it printed, because that is the reason.
    why.clearRetainingCapacity();
    try testing.expectError(error.Config, resolve(a, .{
        .command = "sh",
        .args = &.{ "-c", "echo 'the profile expired'; exit 1" },
    }, &why));
    try testing.expect(std.mem.indexOf(u8, why.items, "the profile expired") != null);
}

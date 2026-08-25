//! What an Azure Blob target says, and where the account key comes from.
//!
//! Three ways to write one, because there are three things people have to hand:
//!
//!     azure://account:key@container            the account's own endpoint
//!     azure+http://account:key@host:10000/container    Azurite, or a proxy
//!     AccountName=…;AccountKey=…;BlobEndpoint=…        pasted from the portal
//!
//! The third is the one the portal and Azurite both print, so it is taken as a
//! target on its own rather than made into somebody's homework. A container is
//! named with `;Container=` in it, or left out - and then every container the key
//! can see is a table.
//!
//! A key is looked for in `AZURE_STORAGE_KEY` and
//! `AZURE_STORAGE_CONNECTION_STRING` when the target carries none, which is where
//! the `az` command and every SDK look.
//!
//! Text in, a structure out. `parse` reads no environment; `resolve` is the one
//! that does.

const std = @import("std");
const targets = @import("../targets.zig");
const db = @import("../db.zig");

const List = db.List;

const SCHEMES = [_][]const u8{ "azure://", "azure+http://", "azure+https://", "blob://" };

/// Where Azure's own blob endpoints live.
pub const SUFFIX = "blob.core.windows.net";
/// What a connection string calls the same thing, with the service left out of
/// it: a blob endpoint is `{account}.blob.{suffix}`.
pub const ENDPOINT_SUFFIX = "core.windows.net";

pub fn owns(target: []const u8) bool {
    for (SCHEMES) |scheme| {
        if (std.ascii.startsWithIgnoreCase(target, scheme)) {
            return true;
        }
    }
    // The connection string, which is what the portal hands out.
    return std.mem.indexOf(u8, target, "AccountName=") != null and
        (std.mem.indexOf(u8, target, "AccountKey=") != null or
            std.mem.indexOf(u8, target, "SharedAccessSignature=") != null or
            std.mem.indexOf(u8, target, "BlobEndpoint=") != null);
}

pub const Parts = struct {
    account: []const u8 = "",
    key: []const u8 = "",
    /// A shared access signature: a query string that stands in for a key, and is
    /// all somebody handed a link has. Signing is skipped when there is one.
    sas: []const u8 = "",
    /// Empty means every container the key can see.
    container: []const u8 = "",
    /// The host to talk to, without a scheme.
    host: []const u8 = "",
    port: u16 = 443,
    tls: bool = true,
    verify: bool = true,
    /// Whether the account name is the first segment of the path rather than the
    /// first label of the host. Azurite and most proxies want it there; Azure
    /// itself does not.
    path_style: bool = false,
    /// Where the key came from, for the info view.
    source: []const u8 = "nowhere",

    pub fn anonymous(self: Parts) bool {
        return self.key.len == 0 and self.sas.len == 0;
    }
};

pub fn parse(arena: std.mem.Allocator, target: []const u8) !Parts {
    if (std.mem.indexOf(u8, target, "AccountName=") != null) {
        return fromConnectionString(arena, target);
    }
    var self = Parts{};
    var rest = target;
    var tls = true;
    for (SCHEMES) |scheme| {
        if (std.ascii.startsWithIgnoreCase(rest, scheme)) {
            rest = rest[scheme.len..];
            if (std.mem.eql(u8, scheme, "azure+http://")) {
                tls = false;
            }
            break;
        }
    }

    // The query first: an account key is base64 and ends in `==` often enough,
    // and a SAS is a query string of its own.
    var endpoint_given: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, rest, '?')) |mark| {
        var options = std.mem.tokenizeScalar(u8, rest[mark + 1 ..], '&');
        rest = rest[0..mark];
        while (options.next()) |option| {
            const equals = std.mem.indexOfScalar(u8, option, '=') orelse continue;
            const name = option[0..equals];
            const value = try targets.unescape(arena, option[equals + 1 ..]);
            if (targets.eql(name, "key") or targets.eql(name, "account_key") or targets.eql(name, "password")) {
                self.key = value;
            } else if (targets.eql(name, "sas") or targets.eql(name, "token")) {
                self.sas = std.mem.trimStart(u8, value, "?");
            } else if (targets.eql(name, "account")) {
                self.account = value;
            } else if (targets.eql(name, "container")) {
                self.container = value;
            } else if (targets.eql(name, "endpoint") or targets.eql(name, "host")) {
                endpoint_given = value;
            } else if (targets.eql(name, "tls") or targets.eql(name, "ssl")) {
                tls = !targets.eql(value, "0");
            } else if (targets.eql(name, "insecure")) {
                self.verify = targets.eql(value, "0");
            } else if (targets.eql(name, "path") or targets.eql(name, "path_style")) {
                self.path_style = !targets.eql(value, "0");
            }
        }
    }

    var authority = rest;
    var path: []const u8 = "";
    // The credentials end at the *last* at sign, not at the first slash: an account
    // key is base64 and holds slashes, and no container name may hold an at sign.
    if (std.mem.lastIndexOfScalar(u8, rest, '@')) |at| {
        const userinfo = rest[0..at];
        authority = rest[at + 1 ..];
        if (std.mem.indexOfScalar(u8, userinfo, ':')) |colon| {
            self.account = try targets.unescape(arena, userinfo[0..colon]);
            self.key = try targets.unescape(arena, userinfo[colon + 1 ..]);
        } else {
            self.account = try targets.unescape(arena, userinfo);
        }
        if (self.key.len != 0) {
            self.source = "the target";
        }
    }
    if (std.mem.indexOfScalar(u8, authority, '/')) |slash| {
        path = std.mem.trim(u8, authority[slash + 1 ..], "/");
        authority = authority[0..slash];
    }

    var host = authority;
    var port: ?u16 = null;
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
        if (std.fmt.parseInt(u16, authority[colon + 1 ..], 10)) |value| {
            host = authority[0..colon];
            port = value;
        } else |_| {}
    }

    // With a path, what came before it is the server and the account is already
    // known; without one, the name is the container on the account's own endpoint.
    if (path.len != 0 or port != null or std.mem.endsWith(u8, host, SUFFIX)) {
        self.host = try arena.dupe(u8, host);
        self.container = try targets.unescape(arena, targets.firstSegment(path));
        // Azurite puts the account in the path, so what looks like the container
        // there is the account and the container is the segment after it.
        if (std.mem.eql(u8, self.container, self.account)) {
            self.path_style = true;
            self.container = try targets.unescape(arena, secondSegment(path));
        }
    } else if (host.len != 0) {
        self.container = try targets.unescape(arena, host);
    }
    if (endpoint_given) |given| {
        self.host = given;
        if (std.mem.lastIndexOfScalar(u8, given, ':')) |colon| {
            if (std.fmt.parseInt(u16, given[colon + 1 ..], 10)) |value| {
                self.host = given[0..colon];
                port = value;
            } else |_| {}
        }
    }

    self.tls = tls;
    self.port = port orelse (if (tls) @as(u16, 443) else 80);
    if (self.host.len == 0 and self.account.len != 0) {
        self.host = try std.fmt.allocPrint(arena, "{s}.{s}", .{ self.account, SUFFIX });
    }
    self.path_style = self.path_style or !inHost(self.host, self.account);
    return self;
}

/// Whether the account is the first label of the host, which is how Azure itself
/// and every sovereign cloud address one. Everything else - the emulator, a proxy
/// - keeps it in the path.
fn inHost(host: []const u8, account: []const u8) bool {
    if (account.len == 0 or host.len <= account.len) {
        return false;
    }
    return std.ascii.startsWithIgnoreCase(host, account) and
        std.mem.startsWith(u8, host[account.len..], ".blob.");
}

/// `DefaultEndpointsProtocol=https;AccountName=…;AccountKey=…;EndpointSuffix=…`,
/// which is what the portal shows and what Azurite prints on startup. The
/// container is not part of it, so `;Container=` is understood as well.
pub fn fromConnectionString(arena: std.mem.Allocator, text: []const u8) !Parts {
    var self = Parts{ .source = "the target" };
    var suffix: []const u8 = ENDPOINT_SUFFIX;
    var endpoint: []const u8 = "";
    var protocol: []const u8 = "https";
    var parts = std.mem.tokenizeScalar(u8, text, ';');
    while (parts.next()) |item| {
        const equals = std.mem.indexOfScalar(u8, item, '=') orelse continue;
        const name = std.mem.trim(u8, item[0..equals], " ");
        // A key is base64 and ends in `=`, so only the first one separates.
        const value = item[equals + 1 ..];
        if (targets.eql(name, "AccountName")) {
            self.account = value;
        } else if (targets.eql(name, "AccountKey")) {
            self.key = value;
        } else if (targets.eql(name, "SharedAccessSignature")) {
            self.sas = std.mem.trimStart(u8, value, "?");
        } else if (targets.eql(name, "EndpointSuffix")) {
            suffix = value;
        } else if (targets.eql(name, "BlobEndpoint")) {
            endpoint = value;
        } else if (targets.eql(name, "DefaultEndpointsProtocol")) {
            protocol = value;
        } else if (targets.eql(name, "Container")) {
            self.container = value;
        }
    }
    if (endpoint.len != 0) {
        var rest = endpoint;
        self.tls = !std.mem.startsWith(u8, rest, "http://");
        for ([_][]const u8{ "https://", "http://" }) |scheme| {
            if (std.mem.startsWith(u8, rest, scheme)) {
                rest = rest[scheme.len..];
            }
        }
        var authority = rest;
        if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
            authority = rest[0..slash];
            // The path of a blob endpoint is the account, which is how Azurite
            // writes it - and which says the account belongs in the path.
            self.path_style = true;
        }
        self.host = authority;
        if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
            if (std.fmt.parseInt(u16, authority[colon + 1 ..], 10)) |value| {
                self.host = authority[0..colon];
                self.port = value;
            } else |_| {}
        } else {
            self.port = if (self.tls) 443 else 80;
        }
    } else {
        self.tls = !targets.eql(protocol, "http");
        self.host = try std.fmt.allocPrint(arena, "{s}.blob.{s}", .{ self.account, suffix });
        self.port = if (self.tls) 443 else 80;
    }
    self.path_style = self.path_style or !inHost(self.host, self.account);
    return self;
}

/// Fill in what the target left out, from where the az command keeps it.
pub fn resolve(arena: std.mem.Allocator, self: *Parts) !void {
    if (!self.anonymous()) {
        return;
    }
    if (targets.getenv("AZURE_STORAGE_KEY")) |key| {
        self.key = key;
        self.source = "the environment";
        if (self.account.len == 0) {
            if (targets.getenv("AZURE_STORAGE_ACCOUNT")) |account| {
                self.account = account;
            }
        }
        return;
    }
    if (targets.getenv("AZURE_STORAGE_CONNECTION_STRING")) |text| {
        const found = fromConnectionString(arena, text) catch return;
        if (found.key.len != 0 or found.sas.len != 0) {
            const container = self.container;
            self.* = found;
            self.source = "the environment";
            if (container.len != 0) {
                self.container = container;
            }
        }
    }
}

fn secondSegment(path: []const u8) []const u8 {
    const slash = std.mem.indexOfScalar(u8, path, '/') orelse return "";
    return targets.firstSegment(path[slash + 1 ..]);
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

test "a container on an account of its own" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    const parts = try parse(arena, "azure://mystorage:c2VjcmV0@photos");
    try testing.expectEqualStrings("mystorage", parts.account);
    try testing.expectEqualStrings("c2VjcmV0", parts.key);
    try testing.expectEqualStrings("photos", parts.container);
    try testing.expectEqualStrings("mystorage.blob.core.windows.net", parts.host);
    try testing.expectEqual(@as(u16, 443), parts.port);
    try testing.expect(parts.tls);
    // Azure takes the account in the host, so the path is the container alone.
    try testing.expect(!parts.path_style);
    try testing.expectEqualStrings("the target", parts.source);

    // No container at all: every one the key can see.
    const all = try parse(arena, "azure://mystorage:k@");
    try testing.expectEqualStrings("", all.container);
    try testing.expectEqualStrings("mystorage.blob.core.windows.net", all.host);
}

test "the emulator, whose account is in the path" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    const parts = try parse(arena, "azure+http://devstoreaccount1:key@127.0.0.1:10000/devstoreaccount1/photos");
    try testing.expectEqualStrings("devstoreaccount1", parts.account);
    try testing.expectEqualStrings("photos", parts.container);
    try testing.expectEqualStrings("127.0.0.1", parts.host);
    try testing.expectEqual(@as(u16, 10000), parts.port);
    try testing.expect(!parts.tls);
    try testing.expect(parts.path_style);

    // The same server without the account repeated: the path is the container.
    const short = try parse(arena, "azure+http://devstoreaccount1:key@127.0.0.1:10000/photos");
    try testing.expectEqualStrings("photos", short.container);
    try testing.expect(short.path_style);
}

test "the connection string the portal hands out" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    // Azurite's own, which is the one people paste. The key ends in `==`, so only
    // the first equals separates the name from the value.
    const parts = try parse(arena, "DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;" ++
        "AccountKey=Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==;" ++
        "BlobEndpoint=http://127.0.0.1:10000/devstoreaccount1;Container=photos");
    try testing.expectEqualStrings("devstoreaccount1", parts.account);
    try testing.expectEqualStrings(
        "Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==",
        parts.key,
    );
    try testing.expectEqualStrings("127.0.0.1", parts.host);
    try testing.expectEqual(@as(u16, 10000), parts.port);
    try testing.expectEqualStrings("photos", parts.container);
    try testing.expect(!parts.tls);
    try testing.expect(parts.path_style);

    // And the shape the portal shows for a real account.
    const azure = try parse(arena, "DefaultEndpointsProtocol=https;AccountName=mystorage;AccountKey=abc==;EndpointSuffix=core.windows.net");
    try testing.expectEqualStrings("mystorage.blob.core.windows.net", azure.host);
    try testing.expectEqual(@as(u16, 443), azure.port);
    try testing.expect(azure.tls);
    try testing.expect(!azure.path_style);
    try testing.expectEqualStrings("abc==", azure.key);
}

test "a shared access signature stands in for a key" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    const parts = try parse(arena, "azure://mystorage@photos?sas=sv%3D2021-08-06%26sig%3Dabc");
    try testing.expectEqualStrings("sv=2021-08-06&sig=abc", parts.sas);
    try testing.expect(!parts.anonymous());
    try testing.expectEqualStrings("", parts.key);

    const nothing = try parse(arena, "azure://mystorage@photos");
    try testing.expect(nothing.anonymous());
}

test "the scheme is recognised and nothing else is" {
    try testing.expect(owns("azure://account:key@container"));
    try testing.expect(owns("azure+http://a:k@127.0.0.1:10000/c"));
    try testing.expect(owns("DefaultEndpointsProtocol=https;AccountName=a;AccountKey=k;EndpointSuffix=x"));
    try testing.expect(!owns("s3://bucket"));
    try testing.expect(!owns("postgres://host/db"));
    // A libpq keyword string is not a connection string, whatever it looks like.
    try testing.expect(!owns("host=h dbname=d"));
}

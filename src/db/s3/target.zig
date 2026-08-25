//! What an S3 target says, and where the credentials come from.
//!
//! `s3://bucket`, `s3://key:secret@bucket?region=eu-central-1`, and for anything
//! that is not Amazon - MinIO, Ceph, Garage, R2 - `s3://key:secret@host:9000/bucket`.
//! The rule for telling the two apart is the path: with one, what comes before it
//! is the server and what comes after is the bucket; without one, the name is the
//! bucket and the server follows from the region. A name that ends in
//! `amazonaws.com` or carries a port is a server either way, because no bucket
//! looks like that.
//!
//! Credentials are looked for where the AWS tools look, in the order they look:
//! the target itself, then the environment, then `~/.aws/credentials` and
//! `~/.aws/config` for the profile in use. So a machine already set up for the
//! `aws` command needs nothing said here at all - and a key that would otherwise
//! sit in the connections file in the clear stays where it was.
//!
//! Text in, a structure out. `parse` never reads a file or an environment
//! variable; `resolve` is the one that does, so what a target means can be tested
//! without a machine that happens to be set up right.

const std = @import("std");
const targets = @import("../targets.zig");
const db = @import("../db.zig");

const List = db.List;

pub fn owns(target: []const u8) bool {
    for (SCHEMES) |scheme| {
        if (std.mem.startsWith(u8, target, scheme)) {
            return true;
        }
    }
    return false;
}

const SCHEMES = [_][]const u8{ "s3://", "s3+http://", "s3+https://", "s3s://" };

pub const Parts = struct {
    /// The host to connect to, without a scheme.
    endpoint: []const u8 = "",
    port: u16 = 443,
    /// Empty means every bucket the key can see.
    bucket: []const u8 = "",
    /// Empty until `resolve` has had its say: the environment and the profile get
    /// to name one before us-east-1 is assumed.
    region: []const u8 = "",
    key: []const u8 = "",
    secret: []const u8 = "",
    token: []const u8 = "",
    profile: []const u8 = "default",
    tls: bool = true,
    /// Whether the certificate has to check out. Off is for a server with a
    /// certificate of its own making, and has to be asked for.
    verify: bool = true,
    /// `https://host/bucket/key` rather than `https://bucket.host/key`. What
    /// everything that is not Amazon wants, and what Amazon still accepts.
    path_style: bool = false,
    /// Where the key came from, for the info view: nobody should have to guess
    /// which of four places was the one that answered.
    source: []const u8 = "nowhere",

    pub fn anonymous(self: Parts) bool {
        return self.key.len == 0 or self.secret.len == 0;
    }
};

pub fn parse(arena: std.mem.Allocator, target: []const u8) !Parts {
    var self = Parts{};
    var rest = target;
    var scheme_said_tls: ?bool = null;
    for (SCHEMES) |scheme| {
        if (std.mem.startsWith(u8, rest, scheme)) {
            rest = rest[scheme.len..];
            if (std.mem.eql(u8, scheme, "s3+http://")) {
                scheme_said_tls = false;
            }
            break;
        }
    }

    // The query first, so a secret with an @ or a / in it cannot be mistaken for
    // part of the address. A secret key routinely has both.
    var endpoint_given: ?[]const u8 = null;
    var style_given: ?bool = null;
    if (std.mem.indexOfScalar(u8, rest, '?')) |mark| {
        var options = std.mem.tokenizeScalar(u8, rest[mark + 1 ..], '&');
        rest = rest[0..mark];
        while (options.next()) |option| {
            const equals = std.mem.indexOfScalar(u8, option, '=') orelse continue;
            const name = option[0..equals];
            const value = try targets.unescape(arena, option[equals + 1 ..]);
            if (targets.eql(name, "region")) {
                self.region = value;
            } else if (targets.eql(name, "endpoint") or targets.eql(name, "host")) {
                endpoint_given = value;
            } else if (targets.eql(name, "key") or targets.eql(name, "access_key") or targets.eql(name, "access-key")) {
                self.key = value;
            } else if (targets.eql(name, "secret") or targets.eql(name, "secret_key") or targets.eql(name, "password")) {
                self.secret = value;
            } else if (targets.eql(name, "token") or targets.eql(name, "session_token")) {
                self.token = value;
            } else if (targets.eql(name, "profile")) {
                self.profile = value;
            } else if (targets.eql(name, "path") or targets.eql(name, "path_style") or targets.eql(name, "path-style")) {
                style_given = !targets.eql(value, "0");
            } else if (targets.eql(name, "tls") or targets.eql(name, "ssl")) {
                scheme_said_tls = !targets.eql(value, "0");
            } else if (targets.eql(name, "insecure")) {
                self.verify = targets.eql(value, "0");
            }
        }
    }

    // The credentials end at the *last* at sign rather than at the first slash: a
    // secret key is base64 and holds slashes, and no bucket name may hold an at
    // sign.
    if (std.mem.lastIndexOfScalar(u8, rest, '@')) |at| {
        const userinfo = rest[0..at];
        rest = rest[at + 1 ..];
        if (std.mem.indexOfScalar(u8, userinfo, ':')) |colon| {
            self.key = try targets.unescape(arena, userinfo[0..colon]);
            self.secret = try targets.unescape(arena, userinfo[colon + 1 ..]);
        } else {
            self.key = try targets.unescape(arena, userinfo);
        }
        if (self.key.len != 0) {
            self.source = "the target";
        }
    }

    var authority = rest;
    var path: []const u8 = "";
    if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
        authority = rest[0..slash];
        path = std.mem.trim(u8, rest[slash + 1 ..], "/");
    }

    var host = authority;
    var port: ?u16 = null;
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
        if (std.fmt.parseInt(u16, authority[colon + 1 ..], 10)) |value| {
            host = authority[0..colon];
            port = value;
        } else |_| {}
    }

    // With a path, what came before it is the server. Without one, a name that
    // looks like a server is a server and anything else is a bucket - which is
    // what makes `s3://photos` and `s3://minio:9000/photos` both work.
    const looks_like_server = port != null or
        std.mem.endsWith(u8, host, "amazonaws.com") or
        std.mem.eql(u8, host, "localhost");
    if (path.len != 0 or looks_like_server) {
        self.endpoint = try arena.dupe(u8, host);
        self.bucket = try targets.unescape(arena, targets.firstSegment(path));
    } else {
        self.bucket = try targets.unescape(arena, host);
    }
    if (endpoint_given) |given| {
        // An explicit endpoint wins, and what was taken for one is the bucket after
        // all: `s3://photos?endpoint=minio:9000`.
        if (self.bucket.len == 0 and self.endpoint.len != 0) {
            self.bucket = self.endpoint;
        }
        self.endpoint = given;
        if (std.mem.lastIndexOfScalar(u8, given, ':')) |colon| {
            if (std.fmt.parseInt(u16, given[colon + 1 ..], 10)) |value| {
                self.endpoint = given[0..colon];
                port = value;
            } else |_| {}
        }
    }

    self.tls = scheme_said_tls orelse true;
    self.port = port orelse (if (self.tls) @as(u16, 443) else 80);
    // Amazon takes both; everything else wants the path. Guessing this wrong is
    // the classic MinIO afternoon, so the guess follows from who is answering.
    self.path_style = style_given orelse !isAmazon(self.endpoint);
    return self;
}

pub fn isAmazon(endpoint: []const u8) bool {
    return endpoint.len == 0 or std.mem.endsWith(u8, endpoint, "amazonaws.com");
}

/// Where a bucket lives when nobody said: Amazon's own name for the region.
pub fn amazonEndpoint(arena: std.mem.Allocator, region: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "s3.{s}.amazonaws.com", .{region});
}

// ------------------------------------------------------- finding the secrets

/// What the environment and the files can supply. Every field empty means they
/// had nothing to say.
pub const Found = struct {
    key: []const u8 = "",
    secret: []const u8 = "",
    token: []const u8 = "",
    region: []const u8 = "",
};

/// Fill in what the target left out, from the places the AWS tools use. A target
/// that named a key of its own is left alone - even when it named no secret,
/// because that is somebody who wants to be asked for one rather than to have
/// another key used behind their back.
pub fn resolve(arena: std.mem.Allocator, self: *Parts) !void {
    if (self.key.len == 0) {
        take(self, fromEnvironment(), "the environment");
    }
    if (self.key.len == 0 or self.region.len == 0) {
        const home = targets.getenv("HOME") orelse "";
        if (home.len != 0) {
            for ([_][]const u8{ "credentials", "config" }) |name| {
                const path = try std.fmt.allocPrint(arena, "{s}/.aws/{s}", .{ home, name });
                const text = targets.readFile(arena, path) catch continue;
                take(self, fromIni(arena, text, self.profile), "~/.aws");
            }
        }
    }
    if (self.region.len == 0) {
        self.region = "us-east-1";
    }
    if (self.endpoint.len == 0) {
        self.endpoint = try amazonEndpoint(arena, self.region);
    }
}

fn take(self: *Parts, found: Found, source: []const u8) void {
    if (self.region.len == 0 and found.region.len != 0) {
        self.region = found.region;
    }
    if (self.key.len != 0) {
        return;
    }
    if (found.key.len == 0 or found.secret.len == 0) {
        return;
    }
    self.key = found.key;
    self.secret = found.secret;
    self.token = found.token;
    self.source = source;
}

pub fn fromEnvironment() Found {
    return .{
        .key = targets.getenv("AWS_ACCESS_KEY_ID") orelse "",
        .secret = targets.getenv("AWS_SECRET_ACCESS_KEY") orelse "",
        .token = targets.getenv("AWS_SESSION_TOKEN") orelse "",
        .region = targets.getenv("AWS_REGION") orelse targets.getenv("AWS_DEFAULT_REGION") orelse "",
    };
}

/// One profile out of `~/.aws/credentials` or `~/.aws/config`. The config file
/// spells its sections `[profile name]` and the credentials file `[name]`; both
/// are accepted from either, because telling a user their brackets are in the
/// wrong file helps nobody.
pub fn fromIni(arena: std.mem.Allocator, text: []const u8, profile: []const u8) Found {
    var found = Found{};
    var inside = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') {
            continue;
        }
        if (line[0] == '[') {
            const name = std.mem.trim(u8, line[1 .. std.mem.indexOfScalar(u8, line, ']') orelse line.len], " \t");
            const bare = if (std.mem.startsWith(u8, name, "profile "))
                std.mem.trim(u8, name["profile ".len..], " \t")
            else
                name;
            inside = std.mem.eql(u8, bare, profile);
            continue;
        }
        if (!inside) {
            continue;
        }
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const name = std.mem.trim(u8, line[0..equals], " \t");
        const value = arena.dupe(u8, std.mem.trim(u8, line[equals + 1 ..], " \t")) catch continue;
        if (targets.eql(name, "aws_access_key_id")) {
            found.key = value;
        } else if (targets.eql(name, "aws_secret_access_key")) {
            found.secret = value;
        } else if (targets.eql(name, "aws_session_token")) {
            found.token = value;
        } else if (targets.eql(name, "region")) {
            found.region = value;
        }
    }
    return found;
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

test "a bucket on Amazon needs nothing but its name" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    const parts = try parse(arena, "s3://photos");
    try testing.expectEqualStrings("photos", parts.bucket);
    try testing.expectEqualStrings("", parts.endpoint); // filled in by resolve
    try testing.expect(parts.tls);
    try testing.expectEqual(@as(u16, 443), parts.port);
    try testing.expect(!parts.path_style); // Amazon takes the bucket in the host

    const region = try parse(arena, "s3://photos?region=eu-central-1");
    try testing.expectEqualStrings("eu-central-1", region.region);
    try testing.expectEqualStrings("s3.eu-central-1.amazonaws.com", try amazonEndpoint(arena, region.region));

    // Every bucket the key can see, which is a target with nothing in it.
    const all = try parse(arena, "s3://s3.eu-west-1.amazonaws.com");
    try testing.expectEqualStrings("", all.bucket);
    try testing.expectEqualStrings("s3.eu-west-1.amazonaws.com", all.endpoint);
}

test "anything that is not Amazon is a host with a bucket after it" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    const minio = try parse(arena, "s3+http://minioadmin:minioadmin@localhost:9000/photos");
    try testing.expectEqualStrings("localhost", minio.endpoint);
    try testing.expectEqual(@as(u16, 9000), minio.port);
    try testing.expectEqualStrings("photos", minio.bucket);
    try testing.expectEqualStrings("minioadmin", minio.key);
    try testing.expectEqualStrings("minioadmin", minio.secret);
    try testing.expectEqualStrings("the target", minio.source);
    try testing.expect(!minio.tls);
    // Not Amazon, so the bucket goes in the path: the MinIO afternoon, avoided.
    try testing.expect(minio.path_style);

    // A key can hold a slash and a plus, and a bucket name can hold a dot.
    const escaped = try parse(arena, "s3://AKIA:a%2Fb%2Bc@my.bucket.example/?endpoint=ceph.example");
    try testing.expectEqualStrings("a/b+c", escaped.secret);
    try testing.expectEqualStrings("ceph.example", escaped.endpoint);
    try testing.expectEqualStrings("my.bucket.example", escaped.bucket);

    const insecure = try parse(arena, "s3://k:s@ceph.example:8443/data?insecure=1&path=1");
    try testing.expect(!insecure.verify);
    try testing.expect(insecure.path_style);
    try testing.expectEqual(@as(u16, 8443), insecure.port);
    try testing.expect(insecure.tls);
}

test "the scheme is recognised and nothing else is" {
    try testing.expect(owns("s3://bucket"));
    try testing.expect(owns("s3+http://localhost:9000/bucket"));
    try testing.expect(!owns("postgres://host/db"));
    try testing.expect(!owns("redis://host"));
    try testing.expect(!owns("/tmp/database.db"));
}

test "a profile is read the way the aws tools write one" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    const text =
        \\[default]
        \\aws_access_key_id = AKIADEFAULT
        \\aws_secret_access_key = defaultsecret
        \\
        \\; a comment, and a section for somebody else
        \\[profile work]
        \\aws_access_key_id=AKIAWORK
        \\aws_secret_access_key=worksecret
        \\aws_session_token=FQoD
        \\region = eu-central-1
    ;
    const default = fromIni(arena, text, "default");
    try testing.expectEqualStrings("AKIADEFAULT", default.key);
    try testing.expectEqualStrings("defaultsecret", default.secret);
    try testing.expectEqualStrings("", default.token);

    // `[profile work]` in the config file and `[work]` in the credentials file
    // are the same profile.
    const work = fromIni(arena, text, "work");
    try testing.expectEqualStrings("AKIAWORK", work.key);
    try testing.expectEqualStrings("FQoD", work.token);
    try testing.expectEqualStrings("eu-central-1", work.region);

    const missing = fromIni(arena, text, "nobody");
    try testing.expectEqualStrings("", missing.key);
}

test "a target with a key of its own does not go looking" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    var parts = try parse(arena, "s3://AKIA:secret@photos?region=eu-west-1");
    try resolve(arena, &parts);
    try testing.expectEqualStrings("AKIA", parts.key);
    try testing.expectEqualStrings("secret", parts.secret);
    try testing.expectEqualStrings("the target", parts.source);
    // The endpoint follows from the region once nobody has named one.
    try testing.expectEqualStrings("s3.eu-west-1.amazonaws.com", parts.endpoint);

    // A key with no secret stays that way: it is somebody who means to be asked
    // for one, not somebody who wants whatever key the machine happens to have.
    var half = try parse(arena, "s3://AKIA@photos");
    try resolve(arena, &half);
    try testing.expectEqualStrings("AKIA", half.key);
    try testing.expectEqualStrings("", half.secret);
    try testing.expect(half.anonymous());
}

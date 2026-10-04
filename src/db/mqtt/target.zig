//! What a target says about how to reach a broker.
//!
//! `mqtt://user:password@host:1883/sensors/%23?client=id&keepalive=30`, with
//! `mqtts://` as the way of asking for TLS. What follows the host is not a
//! database - a broker has none - but the filter to subscribe to: everything
//! when there is none, which is what looking at a broker usually means, and a
//! part of it for a broker too busy to look at whole.
//!
//! Text in, a structure out, and no connection anywhere near it.

const std = @import("std");
const db = @import("../db.zig");

const PLAIN = [_][]const u8{"mqtt://"};
const SECURE = [_][]const u8{ "mqtts://", "mqtt+tls://", "mqtt+ssl://" };

pub fn owns(target: []const u8) bool {
    for (PLAIN ++ SECURE) |prefix| {
        if (std.ascii.startsWithIgnoreCase(target, prefix)) {
            return true;
        }
    }
    return false;
}

pub const Parts = struct {
    host: []const u8,
    port: u16 = 1883,
    user: []const u8 = "",
    password: []const u8 = "",
    tls: bool = false,
    /// Whether the broker's certificate has to check out.
    verify: bool = true,
    /// What to subscribe to. Empty means everything, and the broker's own
    /// `$SYS` topics beside it.
    filter: []const u8 = "",
    /// The name this connection gives itself, or empty to have one made up: two
    /// connections with the same one throw each other off the broker in turn.
    client: []const u8 = "",
    keepalive: u16 = 60,

    pub fn deinit(self: Parts, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
        allocator.free(self.user);
        allocator.free(self.password);
        allocator.free(self.filter);
        allocator.free(self.client);
    }
};

pub fn parse(allocator: std.mem.Allocator, target: []const u8) !Parts {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    var rest = target;
    var tls = false;
    for (SECURE) |prefix| {
        if (std.ascii.startsWithIgnoreCase(rest, prefix)) {
            rest = rest[prefix.len..];
            tls = true;
        }
    }
    for (PLAIN) |prefix| {
        if (std.ascii.startsWithIgnoreCase(rest, prefix)) {
            rest = rest[prefix.len..];
        }
    }

    // The query first, so a password with an @ or a : in it cannot be mistaken
    // for part of the address.
    var user: []const u8 = "";
    var password: []const u8 = "";
    var client: []const u8 = "";
    var keepalive: u16 = 60;
    var verify = true;
    if (std.mem.findScalar(u8, rest, '?')) |mark| {
        var options = std.mem.tokenizeScalar(u8, rest[mark + 1 ..], '&');
        rest = rest[0..mark];
        while (options.next()) |option| {
            const equals = std.mem.findScalar(u8, option, '=') orelse continue;
            const key = option[0..equals];
            const value = try db.targets.unescape(arena, option[equals + 1 ..]);
            if (std.mem.eql(u8, key, "password")) {
                password = value;
            } else if (std.mem.eql(u8, key, "user") or std.mem.eql(u8, key, "username")) {
                user = value;
            } else if (std.mem.eql(u8, key, "client") or std.mem.eql(u8, key, "clientid")) {
                client = value;
            } else if (std.mem.eql(u8, key, "keepalive")) {
                keepalive = std.fmt.parseInt(u16, value, 10) catch keepalive;
            } else if (std.mem.eql(u8, key, "tls") or std.mem.eql(u8, key, "ssl")) {
                tls = !std.mem.eql(u8, value, "0");
            } else if (std.mem.eql(u8, key, "insecure")) {
                verify = std.mem.eql(u8, value, "0");
            }
        }
    }
    // Then who, which ends at the last @ before the first slash: a filter may
    // have an @ in it, and so may a password.
    const path_at = std.mem.findScalar(u8, rest, '/') orelse rest.len;
    if (std.mem.findScalarLast(u8, rest[0..path_at], '@')) |at| {
        const userinfo = rest[0..at];
        rest = rest[at + 1 ..];
        if (std.mem.findScalar(u8, userinfo, ':')) |colon| {
            user = try db.targets.unescape(arena, userinfo[0..colon]);
            password = try db.targets.unescape(arena, userinfo[colon + 1 ..]);
        } else {
            user = try db.targets.unescape(arena, userinfo);
        }
    }
    // And what follows the address is the filter, as it stands: its slashes are
    // its own.
    var filter: []const u8 = "";
    if (std.mem.findScalar(u8, rest, '/')) |slash| {
        filter = try db.targets.unescape(arena, rest[slash + 1 ..]);
        rest = rest[0..slash];
    }

    var host = rest;
    var port: u16 = if (tls) 8883 else 1883;
    if (std.mem.findScalarLast(u8, rest, ':')) |colon| {
        // Not the colons of a bare IPv6 address, which has more than one.
        if (std.mem.findScalar(u8, rest, ':') == colon or (colon != 0 and rest[colon - 1] == ']')) {
            host = rest[0..colon];
            port = std.fmt.parseInt(u16, rest[colon + 1 ..], 10) catch port;
        }
    }
    host = std.mem.trim(u8, host, "[]");
    if (host.len == 0) {
        host = "127.0.0.1";
    }

    const out_host = try allocator.dupe(u8, host);
    errdefer allocator.free(out_host);
    const out_user = try allocator.dupe(u8, user);
    errdefer allocator.free(out_user);
    const out_password = try allocator.dupe(u8, password);
    errdefer allocator.free(out_password);
    const out_filter = try allocator.dupe(u8, filter);
    errdefer allocator.free(out_filter);
    return .{
        .host = out_host,
        .port = port,
        .user = out_user,
        .password = out_password,
        .tls = tls,
        .verify = verify,
        .filter = out_filter,
        .client = try allocator.dupe(u8, client),
        .keepalive = keepalive,
    };
}

// -------------------------------------------------------------------- tests

const testing = std.testing;

test "a target says where the broker is and what to listen to" {
    const a = testing.allocator;
    {
        const parts = try parse(a, "mqtt://broker.example");
        defer parts.deinit(a);
        try testing.expectEqualStrings("broker.example", parts.host);
        try testing.expectEqual(@as(u16, 1883), parts.port);
        try testing.expect(!parts.tls);
        try testing.expectEqualStrings("", parts.filter);
        try testing.expectEqual(@as(u16, 60), parts.keepalive);
    }
    {
        const parts = try parse(a, "mqtts://ada:s%40c:ret@broker.example:8884/dum/+/teplota?client=kuchyn&keepalive=15&insecure=1");
        defer parts.deinit(a);
        try testing.expectEqualStrings("broker.example", parts.host);
        try testing.expectEqual(@as(u16, 8884), parts.port);
        try testing.expect(parts.tls);
        try testing.expect(!parts.verify);
        try testing.expectEqualStrings("ada", parts.user);
        try testing.expectEqualStrings("s@c:ret", parts.password);
        try testing.expectEqualStrings("dum/+/teplota", parts.filter);
        try testing.expectEqualStrings("kuchyn", parts.client);
        try testing.expectEqual(@as(u16, 15), parts.keepalive);
    }
    {
        // TLS moves the port, a # may be written as it is or escaped, and the
        // password the interface adds after asking for one arrives in the query.
        const parts = try parse(a, "mqtt+tls://ada@broker.example/sensors/%23?password=p%26w");
        defer parts.deinit(a);
        try testing.expectEqual(@as(u16, 8883), parts.port);
        try testing.expectEqualStrings("sensors/#", parts.filter);
        try testing.expectEqualStrings("ada", parts.user);
        try testing.expectEqualStrings("p&w", parts.password);
    }
    {
        const parts = try parse(a, "mqtt://127.0.0.1:1884/#");
        defer parts.deinit(a);
        try testing.expectEqualStrings("127.0.0.1", parts.host);
        try testing.expectEqual(@as(u16, 1884), parts.port);
        try testing.expectEqualStrings("#", parts.filter);
    }
    {
        // An @ after the first slash is the filter's, and no host is this machine.
        const parts = try parse(a, "mqtt:///users/a@b");
        defer parts.deinit(a);
        try testing.expectEqualStrings("127.0.0.1", parts.host);
        try testing.expectEqualStrings("", parts.user);
        try testing.expectEqualStrings("users/a@b", parts.filter);
    }
    {
        const parts = try parse(a, "mqtt://[::1]:1884");
        defer parts.deinit(a);
        try testing.expectEqualStrings("::1", parts.host);
        try testing.expectEqual(@as(u16, 1884), parts.port);
    }
}

test "only an MQTT target is one" {
    try testing.expect(owns("mqtt://host"));
    try testing.expect(owns("MQTTS://host:8883"));
    try testing.expect(owns("mqtt+tls://host"));
    try testing.expect(!owns("amqp://host"));
    try testing.expect(!owns("mqtt.db"));
    try testing.expect(!owns("kafka://mqtt"));
}

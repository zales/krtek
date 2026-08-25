//! Shared Key: what proves to Azure Blob that a request is yours.
//!
//! Simpler than S3's signature and wrong in the same places. The string to sign
//! is a fixed list of thirteen header slots - most of them empty on most requests
//! - then every `x-ms-` header sorted, then the resource: the account name, the
//! path, and the query sorted one per line. It is signed with the account key,
//! which is base64 and has to be *decoded* before it is used as an HMAC key: the
//! single most common way to get a 403 out of a signature that looks right.
//!
//! The emulator is where the resource line surprises people. It is
//! `/{account}` followed by the request path, and the emulator's path already
//! begins with the account - so the account appears twice, and it has to.
//!
//! Text in, text out; nothing here opens a socket. The tests check it against
//! signatures computed elsewhere, so they say something this file does not.

const std = @import("std");
const clock = @import("../clock.zig");
const db = @import("../db.zig");

const List = db.List;
const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;

/// The REST version this driver speaks. Old enough that every service and every
/// emulator answers it, new enough for the tier a listing reports.
pub const VERSION = "2021-08-06";

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Param = struct {
    name: []const u8,
    value: []const u8 = "",
};

pub const Request = struct {
    method: []const u8 = "GET",
    /// The path as it goes on the wire, escaped, starting with a slash and
    /// including the account where the account lives in the path.
    path: []const u8 = "/",
    query: []const Param = &.{},
    /// Only the `x-ms-` ones are signed; the rest of what is sent does not matter
    /// to the signature unless it is one of the thirteen named below.
    headers: []const Header = &.{},
    /// Empty rather than zero for a request with no body: a `0` there is a
    /// different string, and Azure answers a 403 and says nothing more helpful.
    /// The `Content-Length: 0` header still has to be sent.
    length: []const u8 = "",
    content_type: []const u8 = "",
};

pub const Signed = struct {
    authorization: []const u8,
    string_to_sign: []const u8,
    signature: []const u8,
};

pub fn sign(
    arena: std.mem.Allocator,
    account: []const u8,
    key: []const u8,
    request: Request,
    when: Stamp,
) !Signed {
    var headers: std.ArrayListUnmanaged(Header) = .empty;
    try headers.append(arena, .{ .name = "x-ms-date", .value = try arena.dupe(u8, when.text()) });
    try headers.append(arena, .{ .name = "x-ms-version", .value = VERSION });
    for (request.headers) |header| {
        if (std.ascii.startsWithIgnoreCase(header.name, "x-ms-")) {
            try headers.append(arena, header);
        }
    }
    const sorted = try canonicalHeaders(arena, headers.items);

    var resource: List = .empty;
    try resource.print(arena, "/{s}{s}", .{ account, request.path });
    const params = try arena.dupe(Param, request.query);
    std.mem.sort(Param, params, {}, lessThan);
    for (params) |param| {
        try resource.print(arena, "\n{s}:{s}", .{ param.name, param.value });
    }

    var to_sign: List = .empty;
    // The thirteen slots, in the order Azure reads them. Everything this driver
    // sends that is not one of them lives in the x-ms- block instead.
    try to_sign.print(arena, "{s}\n{s}\n{s}\n{s}\n{s}\n{s}\n{s}\n{s}\n{s}\n{s}\n{s}\n{s}\n{s}{s}", .{
        request.method,
        "", // Content-Encoding
        "", // Content-Language
        request.length,
        "", // Content-MD5
        request.content_type,
        "", // Date, which x-ms-date replaces
        "", // If-Modified-Since
        "", // If-Match
        "", // If-None-Match
        "", // If-Unmodified-Since
        "", // Range
        sorted,
        resource.items,
    });

    // The key is base64 and is the *bytes* it stands for, not the text of it.
    const raw = try arena.alloc(u8, std.base64.standard.Decoder.calcSizeForSlice(key) catch return error.BadKey);
    std.base64.standard.Decoder.decode(raw, key) catch return error.BadKey;

    var mac: [Hmac.mac_length]u8 = undefined;
    Hmac.create(&mac, to_sign.items, raw);
    const signature = try arena.alloc(u8, std.base64.standard.Encoder.calcSize(mac.len));
    _ = std.base64.standard.Encoder.encode(signature, &mac);

    return .{
        .authorization = try std.fmt.allocPrint(arena, "SharedKey {s}:{s}", .{ account, signature }),
        .string_to_sign = to_sign.items,
        .signature = signature,
    };
}

fn lessThan(_: void, left: Param, right: Param) bool {
    return std.mem.order(u8, left.name, right.name) == .lt;
}

fn headerLessThan(_: void, left: Header, right: Header) bool {
    return std.mem.order(u8, left.name, right.name) == .lt;
}

/// `name:value\n` for every x-ms- header, lowercase and sorted.
fn canonicalHeaders(arena: std.mem.Allocator, headers: []const Header) ![]const u8 {
    const sorted = try arena.alloc(Header, headers.len);
    for (headers, 0..) |header, i| {
        const lower = try arena.alloc(u8, header.name.len);
        sorted[i] = .{
            .name = std.ascii.lowerString(lower, header.name),
            .value = std.mem.trim(u8, header.value, " \t"),
        };
    }
    std.mem.sort(Header, sorted, {}, headerLessThan);
    var out: List = .empty;
    for (sorted) |header| {
        try out.print(arena, "{s}:{s}\n", .{ header.name, header.value });
    }
    return out.items;
}

/// Percent-encoding for a path segment: a blob name may hold anything, and a
/// slash in it is a folder to look at and a segment to the server either way, so
/// it stays.
pub fn escapePath(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    var out: List = .empty;
    for (name) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~' or byte == '/') {
            try out.append(arena, byte);
        } else {
            try out.print(arena, "%{X:0>2}", .{byte});
        }
    }
    return out.items;
}

// ---------------------------------------------------------------- the clock

/// `Wed, 12 Aug 2026 17:16:08 GMT` - the only date format Azure takes, and it
/// insists on GMT whatever the machine thinks the time zone is.
pub const Stamp = struct {
    buffer: [29]u8,
    length: usize,

    pub fn text(self: *const Stamp) []const u8 {
        return self.buffer[0..self.length];
    }
};

const DAYS = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const MONTHS = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

pub fn stamp(seconds: i64) Stamp {
    const moment = std.time.epoch.EpochSeconds{ .secs = @intCast(seconds) };
    const day = moment.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const time_of_day = moment.getDaySeconds();
    // The epoch was a Thursday, which is where the day of the week comes from.
    const weekday = (day.day + 4) % 7;
    var out = Stamp{ .buffer = undefined, .length = 0 };
    const written = std.fmt.bufPrint(&out.buffer, "{s}, {d:0>2} {s} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        DAYS[@intCast(weekday)],
        month_day.day_index + 1,
        MONTHS[month_day.month.numeric() - 1],
        year_day.year,
        time_of_day.getHoursIntoDay(),
        time_of_day.getMinutesIntoHour(),
        time_of_day.getSecondsIntoMinute(),
    }) catch out.buffer[0..0];
    out.length = written.len;
    return out;
}

pub fn now() Stamp {
    return stamp(clock.wallSeconds());
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

/// The emulator's own account, which is public knowledge and the same on every
/// machine - which is what makes the signatures below checkable by anybody.
const ACCOUNT = "devstoreaccount1";
const KEY = "Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==";
const WHEN: i64 = 1786554968; // Wed, 12 Aug 2026 17:16:08 GMT

test "the date is the one Azure insists on" {
    try testing.expectEqualStrings("Wed, 12 Aug 2026 17:16:08 GMT", stamp(WHEN).text());
    try testing.expectEqualStrings("Thu, 01 Jan 1970 00:00:00 GMT", stamp(0).text());
    // A leap day, and a Monday: the day of the week is arithmetic, not a lookup.
    try testing.expectEqualStrings("Mon, 29 Feb 2016 23:59:59 GMT", stamp(1456790399).text());
}

test "a listing is signed the way the emulator wants it" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    const signed = try sign(arena, ACCOUNT, KEY, .{
        .method = "GET",
        // The emulator keeps the account in the path, so it is in the resource
        // twice - once because Azure puts it there, once because the path has it.
        .path = "/devstoreaccount1/photos",
        .query = &.{ .{ .name = "restype", .value = "container" }, .{ .name = "comp", .value = "list" } },
    }, stamp(WHEN));

    try testing.expectEqualStrings(
        "GET\n\n\n\n\n\n\n\n\n\n\n\n" ++
            "x-ms-date:Wed, 12 Aug 2026 17:16:08 GMT\n" ++
            "x-ms-version:2021-08-06\n" ++
            "/devstoreaccount1/devstoreaccount1/photos\ncomp:list\nrestype:container",
        signed.string_to_sign,
    );
    // Computed elsewhere, from the same key and the same string.
    try testing.expectEqualStrings("U4xEJ6UMPTYUbr+ETQL0ChekeOV8bmwueNq48b+QccI=", signed.signature);
    try testing.expectEqualStrings(
        "SharedKey devstoreaccount1:U4xEJ6UMPTYUbr+ETQL0ChekeOV8bmwueNq48b+QccI=",
        signed.authorization,
    );
}

test "a put signs its length, its type and the headers that are Azure's own" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    const signed = try sign(arena, ACCOUNT, KEY, .{
        .method = "PUT",
        .path = "/devstoreaccount1/photos/a%20b.txt",
        .headers = &.{
            .{ .name = "x-ms-blob-type", .value = "BlockBlob" },
            // Not an x-ms- header: it belongs in a slot of its own and not in the
            // block, and putting it in both would be a different string.
            .{ .name = "Content-Type", .value = "text/plain" },
        },
        .length = "5",
        .content_type = "text/plain",
    }, stamp(WHEN));

    try testing.expectEqualStrings(
        "PUT\n\n\n5\n\ntext/plain\n\n\n\n\n\n\n" ++
            "x-ms-blob-type:BlockBlob\n" ++
            "x-ms-date:Wed, 12 Aug 2026 17:16:08 GMT\n" ++
            "x-ms-version:2021-08-06\n" ++
            "/devstoreaccount1/devstoreaccount1/photos/a%20b.txt",
        signed.string_to_sign,
    );
    try testing.expectEqualStrings("5hHZZ3o5Y6Cc/YNM+hpt9RY+5nn72Oxnnv2/29QsIrQ=", signed.signature);
}

test "a key that is not base64 is refused rather than signed with" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    try testing.expectError(error.BadKey, sign(scratch.allocator(), ACCOUNT, "not base64!", .{}, stamp(WHEN)));
}

test "a blob name travels escaped, with its slashes left standing" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    try testing.expectEqualStrings("2015/august%20trip.jpg", try escapePath(arena, "2015/august trip.jpg"));
    try testing.expectEqualStrings("a%2Bb.txt", try escapePath(arena, "a+b.txt"));
    try testing.expectEqualStrings("plain.txt", try escapePath(arena, "plain.txt"));
}

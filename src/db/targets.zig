//! The parts every target parser needed, and had each written out for itself.
//!
//! Ten drivers read a target - a URL, a connection string, a path - and the
//! reading has the same handful of questions underneath it whichever one it is:
//! what a percent escape stands for, whether two names are the same when one
//! shouts, what the environment says where the target is quiet, and what is in
//! the file the target or the environment named.
//!
//! Four copies of `unescape`, three of `getenv`, two of `firstSegment` and two of
//! `readFile` is what that had become - identical down to the byte, which is what
//! made them worth one home rather than eight.

const std = @import("std");

const List = std.ArrayListUnmanaged(u8);

/// %20 and the like, as a URL carries them. A secret key is base64 and can hold
/// a `+` and a `/`, which is why the escaped form has to work.
pub fn unescape(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '%') == null) {
        return text;
    }
    var out: List = .empty;
    var at: usize = 0;
    while (at < text.len) {
        if (text[at] == '%' and at + 2 < text.len) {
            const high = std.fmt.charToDigit(text[at + 1], 16) catch {
                try out.append(arena, text[at]);
                at += 1;
                continue;
            };
            const low = std.fmt.charToDigit(text[at + 2], 16) catch {
                try out.append(arena, text[at]);
                at += 1;
                continue;
            };
            try out.append(arena, high * 16 + low);
            at += 3;
            continue;
        }
        try out.append(arena, text[at]);
        at += 1;
    }
    return out.items;
}

/// Names in a target are compared the way the systems behind them compare
/// theirs: a scheme, a host and a setting do not care which case they are in.
pub fn eql(left: []const u8, right: []const u8) bool {
    return std.ascii.eqlIgnoreCase(left, right);
}

/// The environment, with an empty value read as absence - which is what an
/// unset variable and one set to nothing both mean to somebody configuring this.
pub fn getenv(name: [:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name.ptr) orelse return null;
    const text = std.mem.sliceTo(value, 0);
    return if (text.len == 0) null else text;
}

/// The first name in a path, which is the bucket, the container or the namespace
/// depending on who is asking.
pub fn firstSegment(path: []const u8) []const u8 {
    const trimmed = std.mem.trimStart(u8, path, "/");
    const end = std.mem.indexOfScalar(u8, trimmed, '/') orelse trimmed.len;
    return trimmed[0..end];
}

/// Through libc, as everywhere else in this program. For the small files a
/// target names and the ones the environment names for it: a credentials file, a
/// kubeconfig, a certificate.
pub fn readFile(arena: std.mem.Allocator, path: []const u8) ![]u8 {
    var zero: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= zero.len) {
        return error.NameTooLong;
    }
    @memcpy(zero[0..path.len], path);
    zero[path.len] = 0;
    const file = std.c.fopen(@ptrCast(&zero), "rb") orelse return error.CannotOpen;
    defer _ = std.c.fclose(file);
    var out: List = .empty;
    var chunk: [4096]u8 = undefined;
    while (true) {
        const got = std.c.fread(&chunk, 1, chunk.len, file);
        if (got == 0) {
            break;
        }
        try out.appendSlice(arena, chunk[0..got]);
    }
    return out.items;
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

test "an escape stands for the byte it names, and a stray percent stands for itself" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    // Nothing to do, and the same slice back rather than a copy.
    try testing.expectEqualStrings("plain", try unescape(arena, "plain"));
    try testing.expectEqualStrings("a b", try unescape(arena, "a%20b"));
    // The two a base64 secret key needs.
    try testing.expectEqualStrings("a+b/c=", try unescape(arena, "a%2Bb%2Fc%3D"));
    // A percent that is not an escape is a percent: better a wrong-looking
    // password than a target this refuses to read at all.
    try testing.expectEqualStrings("100%", try unescape(arena, "100%"));
    try testing.expectEqualStrings("%zz", try unescape(arena, "%zz"));
}

test "the first segment is the first name, however many slashes are around it" {
    try testing.expectEqualStrings("photos", firstSegment("/photos/2015/a.jpg"));
    try testing.expectEqualStrings("photos", firstSegment("photos"));
    try testing.expectEqualStrings("", firstSegment("/"));
    try testing.expectEqualStrings("", firstSegment(""));
}

test "names compare without shouting, and the environment reads empty as absent" {
    try testing.expect(eql("HTTPS", "https"));
    try testing.expect(!eql("http", "https"));
    // Nothing sets this, so it is absent whichever way it is asked.
    try testing.expectEqual(@as(?[]const u8, null), getenv("KRTEK_NOT_SET_BY_ANYBODY"));
}

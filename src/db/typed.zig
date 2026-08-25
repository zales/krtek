//! What somebody typed at a console, and what came back from it.
//!
//! An engine with no tables to select from still has things to be asked - `GET`,
//! `PRODUCE`, `SCALE` - and they arrive as a line somebody typed. Two questions
//! come with that and are the same for every engine: what the line comes apart
//! into, and whether what came back can be put on a screen as text or has to be
//! offered as its size instead.
//!
//! Five drivers had written the first out and three the second, identically. The
//! file is named for the two questions rather than for the console, because
//! `console` is what those drivers call the method that asks them.

const std = @import("std");

/// A typed line, as arguments. Quotes group, so a value with a space in it is
/// one argument; nothing else is interpreted, because a console line is not a
/// shell and pretending otherwise is how a key with a `$` in it goes missing.
pub fn split(arena: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var at: usize = 0;
    while (at < text.len) {
        while (at < text.len and (text[at] == ' ' or text[at] == '\t')) : (at += 1) {}
        if (at >= text.len) {
            break;
        }
        if (text[at] == '"' or text[at] == '\'') {
            const quote = text[at];
            at += 1;
            const start = at;
            while (at < text.len and text[at] != quote) : (at += 1) {}
            try out.append(arena, text[start..at]);
            if (at < text.len) {
                at += 1;
            }
            continue;
        }
        const start = at;
        while (at < text.len and text[at] != ' ' and text[at] != '\t') : (at += 1) {}
        try out.append(arena, text[start..at]);
    }
    return out.items;
}

/// Whether these bytes can be put on a screen. What a blob, a message or a file
/// holds is nobody's promise, and a terminal handed a JPEG stops being a
/// terminal - so what cannot be read as text is offered as its size instead.
pub fn readable(bytes: []const u8) bool {
    if (bytes.len == 0) {
        return true;
    }
    if (!std.unicode.utf8ValidateSlice(bytes)) {
        return false;
    }
    for (bytes) |byte| {
        if (byte < 0x20 and byte != '\t' and byte != '\n' and byte != '\r') {
            return false;
        }
    }
    return true;
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

test "a typed line comes apart the way somebody typing it would expect" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    const plain = try split(arena, "GET photos/a.jpg");
    try testing.expectEqual(@as(usize, 2), plain.len);
    try testing.expectEqualStrings("GET", plain[0]);

    // Quotes group, and both kinds do.
    const quoted = try split(arena, "PUT \"a name with spaces\" 'and another'");
    try testing.expectEqual(@as(usize, 3), quoted.len);
    try testing.expectEqualStrings("a name with spaces", quoted[1]);
    try testing.expectEqualStrings("and another", quoted[2]);

    // Nothing else is interpreted: a console line is not a shell.
    const literal = try split(arena, "SET key $HOME*");
    try testing.expectEqualStrings("$HOME*", literal[2]);

    // Runs of space, and a line of nothing but space.
    try testing.expectEqual(@as(usize, 2), (try split(arena, "  A   B  ")).len);
    try testing.expectEqual(@as(usize, 0), (try split(arena, "   ")).len);

    // A quote nobody closed takes the rest of the line rather than an error: what
    // was typed is what was meant, as far as anything here can tell.
    const open = try split(arena, "GET \"unclosed");
    try testing.expectEqualStrings("unclosed", open[1]);
}

test "text is shown and bytes are not pretended to be text" {
    try testing.expect(readable(""));
    try testing.expect(readable("ahoj, světe\n\ts tabulátorem"));
    // A NUL and an escape are what a terminal must not be handed.
    try testing.expect(!readable("a\x00b"));
    try testing.expect(!readable("\x1b[2J"));
    // Not UTF-8 at all.
    try testing.expect(!readable("\xff\xfe\x00\x00"));
}

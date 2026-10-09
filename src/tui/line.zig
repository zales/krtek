//! One line of text with a cursor in it: what a field of a form is, and the
//! prompt along the bottom, and what is typed into the palette.
//!
//! There were three of these and none had a cursor. Each could add to the end of
//! its text and take from the end of it, and the arrow keys did nothing - so a
//! wrong letter at the start of a forty character value was forty backspaces and
//! the value typed again. This is the one line editor the three now share, which
//! is also what makes a key mean the same thing in all of them.

const std = @import("std");
const term = @import("term.zig");

/// A cursor that is wherever the end of the text is. What a line starts with:
/// the text is put in first and the cursor belongs after it, without whoever put
/// it there having to say so.
pub const END = std.math.maxInt(usize);

/// What a key did to the line: nothing to do with it, moved about in it, or
/// changed what it says.
pub const Did = enum { nothing, moved, changed };

/// Where the cursor is: an offset that is inside the text and at the start of a
/// character, whatever was asked for.
pub fn where(text: []const u8, at: usize) usize {
    var i = @min(at, text.len);
    while (i > 0 and i < text.len and text[i] & 0xc0 == 0x80) {
        i -= 1;
    }
    return i;
}

/// The start of the character before this place.
fn back(text: []const u8, at: usize) usize {
    var i = where(text, at);
    if (i == 0) {
        return 0;
    }
    i -= 1;
    while (i > 0 and text[i] & 0xc0 == 0x80) {
        i -= 1;
    }
    return i;
}

/// The start of the character after this place.
fn forth(text: []const u8, at: usize) usize {
    var i = where(text, at);
    if (i >= text.len) {
        return text.len;
    }
    i += 1;
    while (i < text.len and text[i] & 0xc0 == 0x80) {
        i += 1;
    }
    return i;
}

/// A letter, a digit, an underscore, or anything outside ASCII: what a word is
/// made of. A connection string is not one word - `ctrl+w` in it takes the
/// database off the end, not the whole of it.
fn inWord(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte >= 0x80;
}

/// The start of the word the cursor is in or after.
fn wordBack(text: []const u8, at: usize) usize {
    var i = where(text, at);
    while (i > 0 and !inWord(text[i - 1])) {
        i -= 1;
    }
    while (i > 0 and inWord(text[i - 1])) {
        i -= 1;
    }
    return i;
}

/// The end of the word the cursor is in or before.
fn wordForth(text: []const u8, at: usize) usize {
    var i = where(text, at);
    while (i < text.len and !inWord(text[i])) {
        i += 1;
    }
    while (i < text.len and inWord(text[i])) {
        i += 1;
    }
    return i;
}

/// Put text in where the cursor is, and the cursor after it.
pub fn insert(allocator: std.mem.Allocator, text: *std.ArrayList(u8), at: *usize, added: []const u8) !void {
    const here = where(text.items, at.*);
    try text.insertSlice(allocator, here, added);
    at.* = here + added.len;
}

/// What a key does to a line of text. `at` is the cursor, and comes back where
/// the key left it.
///
/// The keys are the ones a shell's line has: the arrows, `home` and `end` or
/// `ctrl+a` and `ctrl+e`, `alt+b` and `alt+f` by a word, `backspace` and
/// `delete`, `ctrl+w` for the word before the cursor and `ctrl+u` for all of it.
/// Anything else is not this line's, and whoever asked decides what it is.
pub fn key(allocator: std.mem.Allocator, text: *std.ArrayList(u8), at: *usize, pressed: term.Key) !Did {
    const here = where(text.items, at.*);
    switch (pressed) {
        .char => |point| {
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(point, &buf) catch return .nothing;
            try insert(allocator, text, at, buf[0..len]);
            return .changed;
        },
        .backspace => {
            const from = back(text.items, here);
            if (from == here) {
                at.* = here;
                return .nothing;
            }
            text.replaceRangeAssumeCapacity(from, here - from, "");
            at.* = from;
            return .changed;
        },
        .delete => {
            const to = forth(text.items, here);
            at.* = here;
            if (to == here) {
                return .nothing;
            }
            text.replaceRangeAssumeCapacity(here, to - here, "");
            return .changed;
        },
        .left => at.* = back(text.items, here),
        .right => at.* = forth(text.items, here),
        .home => at.* = 0,
        .end => at.* = text.items.len,
        .ctrl => |code| switch (code) {
            'a' => at.* = 0,
            'e' => at.* = text.items.len,
            'w' => {
                const from = wordBack(text.items, here);
                at.* = from;
                if (from == here) {
                    return .nothing;
                }
                text.replaceRangeAssumeCapacity(from, here - from, "");
                return .changed;
            },
            'u' => {
                at.* = 0;
                if (text.items.len == 0) {
                    return .nothing;
                }
                text.clearRetainingCapacity();
                return .changed;
            },
            else => return .nothing,
        },
        .alt => |code| switch (code) {
            'b' => at.* = wordBack(text.items, here),
            'f' => at.* = wordForth(text.items, here),
            else => return .nothing,
        },
        else => return .nothing,
    }
    return .moved;
}

/// What of a line a field `span` columns wide shows, and how far into the field
/// the cursor is.
pub const Window = struct { text: []const u8, cursor: usize };

/// The part of the text to draw, with the cursor in it. From the start where
/// the cursor is near enough to it; otherwise scrolled just far enough that the
/// cursor is the last column, which with the cursor at the end is the tail of
/// the value - what a field has always shown of one too long for it.
pub fn window(text: []const u8, at: usize, span: usize) Window {
    const here = where(text, at);
    if (span == 0) {
        return .{ .text = "", .cursor = 0 };
    }
    var start: usize = 0;
    if (term.width(text[0..here]) >= span) {
        // As much of what is before the cursor as leaves it a column.
        var used: usize = 0;
        start = here;
        while (start > 0) {
            const from = back(text, start);
            const w = term.width(text[from..start]);
            if (used + w > span - 1) {
                break;
            }
            used += w;
            start = from;
        }
    }
    const shown = term.fit(text[start..], span).text;
    return .{ .text = shown, .cursor = @min(term.width(text[start..here]), span - 1) };
}

const testing = std.testing;

fn typed(text: *std.ArrayList(u8), at: *usize, keys: []const term.Key) !void {
    for (keys) |one| {
        _ = try key(testing.allocator, text, at, one);
    }
}

test "a line is typed into where its cursor is" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try text.appendSlice(testing.allocator, "Karel Capek");
    var at: usize = END;

    // The cursor starts after the text, wherever that is.
    try testing.expectEqual(@as(usize, 11), where(text.items, at));

    // Back five, take the plain C out and put the right one in.
    try typed(&text, &at, &.{ .left, .left, .left, .left, .backspace, .{ .char = 'Č' } });
    try testing.expectEqualStrings("Karel Čapek", text.items);
    try testing.expectEqual(@as(usize, 8), at);

    // The arrows go by a character, not by a byte of one.
    try typed(&text, &at, &.{.left});
    try testing.expectEqual(@as(usize, 6), at);
    try typed(&text, &at, &.{.right});
    try testing.expectEqual(@as(usize, 8), at);

    try typed(&text, &at, &.{ .home, .delete });
    try testing.expectEqualStrings("arel Čapek", text.items);
    try typed(&text, &at, &.{ .end, .{ .char = '!' } });
    try testing.expectEqualStrings("arel Čapek!", text.items);
    // And neither end is somewhere to fall off.
    try typed(&text, &at, &.{ .right, .delete, .home, .left, .backspace });
    try testing.expectEqualStrings("arel Čapek!", text.items);
    try testing.expectEqual(@as(usize, 0), at);
}

test "a word is what ctrl+w takes, and a connection string is several" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try text.appendSlice(testing.allocator, "postgres://reader@ledger.example:5432/ledger");
    var at: usize = END;

    try typed(&text, &at, &.{.{ .ctrl = 'w' }});
    try testing.expectEqualStrings("postgres://reader@ledger.example:5432/", text.items);
    try typed(&text, &at, &.{.{ .ctrl = 'w' }});
    try testing.expectEqualStrings("postgres://reader@ledger.example:", text.items);

    try typed(&text, &at, &.{ .{ .ctrl = 'a' }, .{ .alt = 'f' } });
    try testing.expectEqual(@as(usize, 8), at);
    try typed(&text, &at, &.{ .{ .alt = 'f' }, .{ .alt = 'b' } });
    try testing.expectEqual(@as(usize, 11), at);

    try typed(&text, &at, &.{.{ .ctrl = 'u' }});
    try testing.expectEqualStrings("", text.items);
    try testing.expectEqual(@as(usize, 0), at);
    // Nothing left to take is nothing changed.
    try testing.expectEqual(Did.nothing, try key(testing.allocator, &text, &at, .{ .ctrl = 'w' }));
    try testing.expectEqual(Did.nothing, try key(testing.allocator, &text, &at, .backspace));
    // And a key that is not a line's is said to be nobody's here.
    try testing.expectEqual(Did.nothing, try key(testing.allocator, &text, &at, .enter));
    try testing.expectEqual(Did.nothing, try key(testing.allocator, &text, &at, .{ .ctrl = 's' }));
}

test "a field shows the part of its text the cursor is in" {
    // All of it where it fits, with the cursor where it is.
    var shown = window("short", END, 10);
    try testing.expectEqualStrings("short", shown.text);
    try testing.expectEqual(@as(usize, 5), shown.cursor);

    // The tail of a long one while the cursor is at its end, a column kept for
    // the cursor itself.
    shown = window("0123456789abcdef", END, 8);
    try testing.expectEqualStrings("9abcdef", shown.text);
    try testing.expectEqual(@as(usize, 7), shown.cursor);

    // And from the start once the cursor is back near it.
    shown = window("0123456789abcdef", 3, 8);
    try testing.expectEqualStrings("01234567", shown.text);
    try testing.expectEqual(@as(usize, 3), shown.cursor);

    // In between, the cursor is the last column and what is before it fills
    // the rest.
    shown = window("0123456789abcdef", 10, 8);
    try testing.expectEqualStrings("3456789a", shown.text);
    try testing.expectEqual(@as(usize, 7), shown.cursor);

    // A wide character is two columns, and is never cut in half to fit.
    shown = window("日本語のテキスト", END, 7);
    try testing.expectEqualStrings("キスト", shown.text);
    try testing.expectEqual(@as(usize, 6), shown.cursor);

    // An offset in the middle of a character is the start of that character.
    try testing.expectEqual(@as(usize, 1), where("aČb", 2));
    shown = window("anything", END, 0);
    try testing.expectEqualStrings("", shown.text);
}

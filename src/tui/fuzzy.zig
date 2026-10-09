//! Fuzzy matching, the way a fuzzy finder does it: the letters have to appear in
//! order but not next to each other, and the score rewards what a reader would
//! call the obvious match. Used by the command palette and by the object filter,
//! which is why it lives on its own rather than in either of them.

const std = @import("std");

/// Where a query matched a label, so the letters that earned the match can be
/// picked out on screen. 64 positions is far more than any label here has.
pub const Hit = struct {
    at: [64]u8 = undefined,
    len: usize = 0,
    /// How good a match it is: contiguous beats scattered, a word start beats
    /// the middle of a word, and the label beats the extra words.
    rank: u16 = 0,

    fn mark(self: *Hit, position: usize) void {
        if (self.len < self.at.len and position < 256) {
            self.at[self.len] = @intCast(position);
            self.len += 1;
        }
    }

    pub fn has(self: Hit, position: usize) bool {
        for (self.at[0..self.len]) |marked| {
            if (marked == position) {
                return true;
            }
        }
        return false;
    }
};

/// Fuzzy match `needle` in `haystack`, the way a fuzzy finder does: the letters
/// have to appear in order but not next to each other, and the score rewards
/// what a reader would call the obvious match - letters together, and letters at
/// the start of a word. Returns null when a letter is missing.
///
/// Every possible starting point is tried and the best result wins, because a
/// single greedy pass gives a silly answer whenever an earlier letter steals the
/// match: scanning "insert a row" for "row" would take the r of "insert" and
/// then have to reach across the string, when the word "row" is sitting there.
pub fn match(haystack: []const u8, needle: []const u8, hit: ?*Hit) ?u16 {
    if (hit) |out| {
        out.* = .{};
    }
    if (needle.len == 0) {
        return 1;
    }
    var best: ?u16 = null;
    var from: usize = 0;
    while (from < haystack.len) : (from += 1) {
        if (std.ascii.toLower(haystack[from]) != std.ascii.toLower(needle[0])) {
            continue;
        }
        var attempt = Hit{};
        const got = greedy(haystack, needle, from, &attempt) orelse continue;
        if (best == null or got > best.?) {
            best = got;
            if (hit) |out| {
                out.* = attempt;
            }
        }
    }
    return best;
}

/// One pass, taking each letter as soon as it appears from `from` on.
fn greedy(haystack: []const u8, needle: []const u8, from: usize, hit: *Hit) ?u16 {
    var points: u16 = 0;
    var run: u16 = 0;
    var at: usize = 0;
    var i = from;
    while (i < haystack.len and at < needle.len) : (i += 1) {
        if (std.ascii.toLower(haystack[i]) != std.ascii.toLower(needle[at])) {
            run = 0;
            continue;
        }
        at += 1;
        run += 1;
        // Letters in a row, and the first letter of a word, are what makes a
        // match look right to a human.
        points += 1 + run * 2;
        if (i == 0 or haystack[i - 1] == ' ' or haystack[i - 1] == '_') {
            points += 6;
        }
        hit.mark(i);
    }
    if (at < needle.len) {
        return null;
    }
    // A short label that matched is more likely the one meant than a long one.
    return points + @as(u16, @intCast(@min(20, 40 / (haystack.len + 1))));
}

/// One code point, and how many bytes it took. A byte that is not the start of
/// a well formed one is taken as itself, so text that is not UTF-8 can still be
/// searched: it is compared byte for byte, which is all there is to compare.
fn pointAt(text: []const u8, at: usize) struct { point: u21, len: usize } {
    const len = std.unicode.utf8ByteSequenceLength(text[at]) catch return .{ .point = text[at], .len = 1 };
    if (at + len > text.len) {
        return .{ .point = text[at], .len = 1 };
    }
    const point = std.unicode.utf8Decode(text[at .. at + len]) catch return .{ .point = text[at], .len = 1 };
    return .{ .point = point, .len = len };
}

/// A letter without its case, for the alphabets this is likely to meet: ASCII,
/// Latin-1 and Latin Extended-A, which is where `Č` and `ř` and `ő` live. Not
/// the whole of Unicode - a table of that is larger than this program's other
/// tables together - and what it does not know it leaves alone, so a letter
/// from anywhere else still matches itself.
pub fn fold(point: u21) u21 {
    return switch (point) {
        'A'...'Z' => point + 0x20,
        0xc0...0xd6, 0xd8...0xde => point + 0x20,
        // Pairs, the capital first: Ā ā, Ă ă ... Ķ ķ. Not the two Turkish i's
        // in the middle of them, whose other halves are in ASCII.
        0x100...0x12f, 0x132...0x137 => point | 1,
        // And the other way round from here: ĸ stands alone, then Ĺ ĺ ... Ň ň.
        0x139...0x148 => if (point & 1 == 1) point + 1 else point,
        0x14a...0x177 => point | 1,
        0x178 => 0xff,
        0x179...0x17e => if (point & 1 == 1) point + 1 else point,
        else => point,
    };
}

/// Where `needle` is in `haystack` whatever the case of either, or null.
/// Empty is found nowhere: nothing typed is nothing looked for.
pub fn find(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len * 4) {
        return null;
    }
    var from: usize = 0;
    while (from < haystack.len) {
        var i = from;
        var j: usize = 0;
        while (j < needle.len and i < haystack.len) {
            const here = pointAt(haystack, i);
            const wanted = pointAt(needle, j);
            if (fold(here.point) != fold(wanted.point)) {
                break;
            }
            i += here.len;
            j += wanted.len;
        }
        if (j >= needle.len) {
            return from;
        }
        from += pointAt(haystack, from).len;
    }
    return null;
}

test "text is found whatever its case, in the alphabets people here write in" {
    try std.testing.expectEqual(@as(?usize, 6), find("Karel Čapek", "čap"));
    try std.testing.expectEqual(@as(?usize, 6), find("karel čapek", "ČAP"));
    try std.testing.expectEqual(@as(?usize, 0), find("ŽLUŤOUČKÝ KŮŇ", "žluťoučký kůň"));
    try std.testing.expectEqual(@as(?usize, 0), find("Řehoř", "řEHOŘ"));
    try std.testing.expect(find("Hrabal", "hrabe") == null);
    try std.testing.expect(find("anything", "") == null);
    try std.testing.expect(find("ab", "abc") == null);
    // Not UTF-8 at all: compared as the bytes it is, and never read past the end.
    try std.testing.expectEqual(@as(?usize, 1), find("a\xffb", "\xffB"));
    try std.testing.expect(find("\xc5", "\xc5\x99") == null);
    // What has no other case is itself.
    try std.testing.expectEqual(@as(?usize, 6), find("東京都", "都"));
}

test "letters have to appear in order, and the score prefers the obvious match" {
    try std.testing.expect(match("drop the table", "dropt", null) != null);
    try std.testing.expect(match("drop the table", "zz", null) == null);
    // Everything matches an empty query.
    try std.testing.expect(match("anything", "", null) != null);

    // Together beats scattered: both contain r, o and w in order.
    const together = match("insert a row", "row", null).?;
    const scattered = match("reorder now", "row", null).?;
    try std.testing.expect(together > scattered);

    // A word start beats the middle of a word.
    try std.testing.expect(match("copy the table", "t", null).? > match("structure", "t", null).?);
}

test "the positions come back so they can be marked on screen" {
    var hit = Hit{};
    _ = match("export", "xpt", &hit).?;
    try std.testing.expect(hit.len == 3);
    try std.testing.expect(hit.has(1) and hit.has(2) and hit.has(5));
    try std.testing.expect(!hit.has(0));
}

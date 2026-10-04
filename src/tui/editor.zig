//! A small multi-line text editor, and the SQL tokenizer that colours it.
//!
//! Enough of an editor for writing a statement: several lines, a cursor that
//! moves the way a cursor moves, and completion of the names the database
//! already has. It is not a general text editor - no selection, no files - and
//! deliberately so: everything here is what a query needs and nothing else.
//!
//! It has two modes, the way vi has, because the people who write SQL in a
//! terminal mostly have those keys in their hands already: insert, where a key
//! is the character on it, and normal, where it is a command. What a command
//! or a stretch of typing did can be taken back, and put back again.

const std = @import("std");

pub const Mode = enum {
    normal,
    insert,
};

/// How many changes can be taken back. A statement is a screenful at most, so
/// keeping every one of these is a few kilobytes.
const UNDO_LIMIT = 64;

/// The text as it was before a change, and where the cursor stood in it. The
/// two go together: an offset that was a character boundary in one text is the
/// middle of a character in another, and a cursor left there splits the next
/// thing typed into bytes no server will take.
const Snapshot = struct {
    text: []u8,
    cursor: usize,
};

const Snapshots = std.ArrayListUnmanaged(Snapshot);

pub const Editor = struct {
    allocator: std.mem.Allocator,
    text: std.ArrayListUnmanaged(u8) = .empty,
    /// A byte offset into `text`, always on a character boundary.
    cursor: usize = 0,
    /// First line on screen, so a long statement can be scrolled.
    scroll: usize = 0,
    /// Where the history was last taken from, so ctrl+p walks back through it.
    history_at: ?usize = null,
    /// The open completion list: candidates, which one is picked, and the word
    /// they would replace.
    candidates: std.ArrayListUnmanaged([]const u8) = .empty,
    candidate_at: usize = 0,
    word_from: usize = 0,
    arena: std.heap.ArenaAllocator,

    mode: Mode = .insert,
    /// The first key of a two-key command in normal mode: `d`, `y`, `c` or `g`.
    pending_op: ?u8 = null,
    /// What was last cut or yanked, and whether it was whole lines. Lines go
    /// back as lines; anything else goes back where the cursor is.
    yank_buffer: std.ArrayListUnmanaged(u8) = .empty,
    yank_lines: bool = false,
    undo_stack: Snapshots = .empty,
    redo_stack: Snapshots = .empty,
    /// Whether the change under way has been recorded. A stretch of typing is
    /// one change and so is a command, so the text is copied once when either
    /// starts rather than at every key - which used to fill the whole history
    /// with one held backspace.
    recorded: bool = false,

    pub fn init(allocator: std.mem.Allocator) Editor {
        return .{ .allocator = allocator, .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *Editor) void {
        self.text.deinit(self.allocator);
        self.candidates.deinit(self.allocator);
        self.yank_buffer.deinit(self.allocator);
        self.drop(&self.undo_stack);
        self.undo_stack.deinit(self.allocator);
        self.drop(&self.redo_stack);
        self.redo_stack.deinit(self.allocator);
        self.arena.deinit();
    }

    pub fn setText(self: *Editor, sql: []const u8) !void {
        self.text.clearRetainingCapacity();
        try self.text.appendSlice(self.allocator, sql);
        self.cursor = self.text.items.len;
        self.closeCompletion();
    }

    // --- taking a change back ---

    /// Called before the text changes. The first change of a stretch records
    /// what there was; the rest of the stretch is part of the same change.
    pub fn changing(self: *Editor) void {
        if (self.recorded) {
            return;
        }
        self.recorded = true;
        const taken = self.snapshot() orelse return;
        self.push(&self.undo_stack, taken);
        // Something new has been done, so what was undone is not "next" any more.
        self.drop(&self.redo_stack);
    }

    /// The change under way is finished, and the next one is recorded on its own.
    pub fn settle(self: *Editor) void {
        self.recorded = false;
    }

    pub fn undo(self: *Editor) void {
        self.step(&self.undo_stack, &self.redo_stack);
    }

    pub fn redo(self: *Editor) void {
        self.step(&self.redo_stack, &self.undo_stack);
    }

    /// Take the newest state off one pile and leave the present one on the other.
    fn step(self: *Editor, from: *Snapshots, onto: *Snapshots) void {
        if (from.items.len == 0) {
            return;
        }
        // Everything that can fail comes first, so running out of memory leaves
        // the text as it is instead of half way between two versions of itself.
        self.text.ensureTotalCapacity(self.allocator, from.items[from.items.len - 1].text.len) catch return;
        const now = self.snapshot() orelse return;
        const then = from.pop().?;
        defer self.allocator.free(then.text);
        self.push(onto, now);
        self.text.clearRetainingCapacity();
        self.text.appendSliceAssumeCapacity(then.text);
        self.cursor = @min(then.cursor, self.text.items.len);
        self.recorded = false;
        self.closeCompletion();
    }

    fn snapshot(self: *Editor) ?Snapshot {
        return .{
            .text = self.allocator.dupe(u8, self.text.items) catch return null,
            .cursor = self.cursor,
        };
    }

    fn push(self: *Editor, pile: *Snapshots, taken: Snapshot) void {
        pile.append(self.allocator, taken) catch {
            self.allocator.free(taken.text);
            return;
        };
        if (pile.items.len > UNDO_LIMIT) {
            self.allocator.free(pile.orderedRemove(0).text);
        }
    }

    fn drop(self: *Editor, pile: *Snapshots) void {
        for (pile.items) |taken| {
            self.allocator.free(taken.text);
        }
        pile.clearRetainingCapacity();
    }

    // --- editing ---

    pub fn insert(self: *Editor, bytes: []const u8) !void {
        self.changing();
        try self.text.insertSlice(self.allocator, self.cursor, bytes);
        self.cursor += bytes.len;
        self.closeCompletion();
    }

    pub fn backspace(self: *Editor) void {
        if (self.cursor == 0) {
            return;
        }
        self.changing();
        const from = self.previous(self.cursor);
        self.text.replaceRangeAssumeCapacity(from, self.cursor - from, "");
        self.cursor = from;
        self.closeCompletion();
    }

    pub fn delete(self: *Editor) void {
        if (self.cursor >= self.text.items.len) {
            return;
        }
        self.changing();
        const to = self.next(self.cursor);
        self.text.replaceRangeAssumeCapacity(self.cursor, to - self.cursor, "");
        self.closeCompletion();
    }

    /// Remove the word before the cursor, which is what ctrl+w does everywhere.
    pub fn deleteWord(self: *Editor) void {
        self.changing();
        var at = self.cursor;
        while (at > 0 and isSpace(self.text.items[at - 1])) : (at -= 1) {}
        while (at > 0 and !isSpace(self.text.items[at - 1])) : (at -= 1) {}
        self.text.replaceRangeAssumeCapacity(at, self.cursor - at, "");
        self.cursor = at;
        self.closeCompletion();
    }

    pub fn clear(self: *Editor) void {
        self.changing();
        self.text.clearRetainingCapacity();
        self.cursor = 0;
        self.closeCompletion();
    }

    // --- the modes ---

    /// Into insert mode. What is typed from here is one change of its own.
    pub fn enterInsert(self: *Editor) void {
        self.mode = .insert;
        self.settle();
    }

    /// `a`: insert after the character the cursor is on, which at the end of a
    /// line is where the cursor already is.
    pub fn append(self: *Editor) void {
        self.rightOnLine();
        self.enterInsert();
    }

    /// Out of insert mode. The cursor steps back onto the last character typed,
    /// the way vi's does - but never off the front of the line, which is what
    /// stepping back blindly did: escape on a line just opened landed on the
    /// one above it.
    pub fn leaveInsert(self: *Editor) void {
        self.mode = .normal;
        self.settle();
        self.leftOnLine();
        self.closeCompletion();
    }

    // --- commands, which are what normal mode is for ---

    /// A command is a change of its own: taken back in one go, and apart from
    /// whatever was typed before it. One that goes on into insert mode leaves the
    /// change open, so what is typed next belongs to it - `cw` and the word that
    /// replaces the old one are a single undo, as they are in vi.
    fn begin(self: *Editor) void {
        self.recorded = false;
        self.changing();
    }

    fn yank(self: *Editor, bytes: []const u8, lines: bool) void {
        self.yank_buffer.clearRetainingCapacity();
        self.yank_buffer.appendSlice(self.allocator, bytes) catch {};
        self.yank_lines = lines;
    }

    /// Whether there is anything to put back. An empty line that was yanked is
    /// something: putting it back makes an empty line.
    fn hasYank(self: *Editor) bool {
        return self.yank_lines or self.yank_buffer.items.len != 0;
    }

    /// Cut from the cursor up to `stop`, keeping what went.
    fn cut(self: *Editor, stop: usize) void {
        if (stop <= self.cursor) {
            return;
        }
        self.yank(self.text.items[self.cursor..stop], false);
        self.text.replaceRangeAssumeCapacity(self.cursor, stop - self.cursor, "");
        self.closeCompletion();
    }

    /// `dd`: the line goes, and the newline that made it one.
    pub fn deleteLine(self: *Editor) void {
        self.begin();
        const start = self.lineStart(self.cursor);
        const stop = self.lineEnd(self.cursor);
        self.yank(self.text.items[start..stop], true);
        if (stop < self.text.items.len) {
            // Its own newline goes with it, and the line below moves up.
            self.text.replaceRangeAssumeCapacity(start, stop + 1 - start, "");
            self.cursor = start;
        } else if (start > 0) {
            // The last line: the newline in front of it is what made it a line.
            self.text.replaceRangeAssumeCapacity(start - 1, stop + 1 - start, "");
            self.cursor = self.lineStart(start - 1);
        } else {
            self.text.clearRetainingCapacity();
            self.cursor = 0;
        }
        self.firstNonBlank();
        self.closeCompletion();
    }

    /// `cc`: the line is emptied and typed again. It stays a line and stays
    /// where it was - deleting it and opening a new one above is not the same
    /// thing on the last line, where "above" is above the line before.
    pub fn changeLine(self: *Editor) void {
        self.begin();
        const start = self.lineStart(self.cursor);
        const stop = self.lineEnd(self.cursor);
        self.yank(self.text.items[start..stop], true);
        self.text.replaceRangeAssumeCapacity(start, stop - start, "");
        self.cursor = start;
        self.mode = .insert;
        self.closeCompletion();
    }

    /// `D` and `d$`.
    pub fn deleteToEndOfLine(self: *Editor) void {
        const stop = self.lineEnd(self.cursor);
        if (stop == self.cursor) {
            return;
        }
        self.begin();
        self.cut(stop);
    }

    /// `C` and `c$`.
    pub fn changeToEndOfLine(self: *Editor) void {
        self.begin();
        self.cut(self.lineEnd(self.cursor));
        self.mode = .insert;
    }

    /// Where the word under the cursor ends, with or without the blanks after
    /// it. Never past the end of the line: a command about a word is not one
    /// about the line break after it.
    fn wordSpan(self: *Editor, trailing: bool) usize {
        const text = self.text.items;
        const limit = self.lineEnd(self.cursor);
        var at = self.cursor;
        if (at < limit and classOf(text[at]) != .blank) {
            const kind = classOf(text[at]);
            while (at < limit and classOf(text[at]) == kind) : (at += 1) {}
            if (!trailing) {
                return at;
            }
        }
        while (at < limit and classOf(text[at]) == .blank) : (at += 1) {}
        return at;
    }

    /// `dw`: the word, and the blanks that separated it from the next.
    pub fn deleteWordForward(self: *Editor) void {
        const stop = self.wordSpan(true);
        if (stop == self.cursor) {
            return;
        }
        self.begin();
        self.cut(stop);
    }

    /// `cw`: the word and not the blank after it, or what is typed in its place
    /// runs into the next word.
    pub fn changeWord(self: *Editor) void {
        self.begin();
        self.cut(self.wordSpan(false));
        self.mode = .insert;
    }

    /// `x`: the character under the cursor, and never the end of the line.
    pub fn deleteChar(self: *Editor) void {
        if (self.cursor >= self.lineEnd(self.cursor)) {
            return;
        }
        self.begin();
        self.cut(self.next(self.cursor));
    }

    /// `s`: that character, and then whatever is typed instead of it.
    pub fn substitute(self: *Editor) void {
        self.begin();
        if (self.cursor < self.lineEnd(self.cursor)) {
            self.cut(self.next(self.cursor));
        }
        self.mode = .insert;
    }

    /// `yy`.
    pub fn yankLine(self: *Editor) void {
        self.yank(self.text.items[self.lineStart(self.cursor)..self.lineEnd(self.cursor)], true);
    }

    /// `p`: lines go under this one, anything else after the character the
    /// cursor is on.
    pub fn pasteBelow(self: *Editor) void {
        if (!self.hasYank()) {
            return;
        }
        const yanked = self.yank_buffer.items;
        self.text.ensureUnusedCapacity(self.allocator, yanked.len + 1) catch return;
        self.begin();
        if (self.yank_lines) {
            const stop = self.lineEnd(self.cursor);
            self.text.replaceRangeAssumeCapacity(stop, 0, "\n");
            self.text.replaceRangeAssumeCapacity(stop + 1, 0, yanked);
            self.cursor = stop + 1;
        } else {
            const at = if (self.cursor < self.lineEnd(self.cursor)) self.next(self.cursor) else self.cursor;
            self.text.replaceRangeAssumeCapacity(at, 0, yanked);
            self.cursor = self.previous(at + yanked.len);
        }
        self.closeCompletion();
    }

    /// `P`: lines go above this one, anything else in front of the cursor.
    pub fn pasteAbove(self: *Editor) void {
        if (!self.hasYank()) {
            return;
        }
        const yanked = self.yank_buffer.items;
        self.text.ensureUnusedCapacity(self.allocator, yanked.len + 1) catch return;
        self.begin();
        if (self.yank_lines) {
            const start = self.lineStart(self.cursor);
            self.text.replaceRangeAssumeCapacity(start, 0, yanked);
            self.text.replaceRangeAssumeCapacity(start + yanked.len, 0, "\n");
            self.cursor = start;
        } else {
            self.text.replaceRangeAssumeCapacity(self.cursor, 0, yanked);
            self.cursor = self.previous(self.cursor + yanked.len);
        }
        self.closeCompletion();
    }

    /// `o`: a new line under this one, and into insert mode on it.
    pub fn openBelow(self: *Editor) void {
        self.text.ensureUnusedCapacity(self.allocator, 1) catch return;
        self.begin();
        const stop = self.lineEnd(self.cursor);
        self.text.replaceRangeAssumeCapacity(stop, 0, "\n");
        self.cursor = stop + 1;
        self.mode = .insert;
        self.closeCompletion();
    }

    /// `O`: the same, above.
    pub fn openAbove(self: *Editor) void {
        self.text.ensureUnusedCapacity(self.allocator, 1) catch return;
        self.begin();
        const start = self.lineStart(self.cursor);
        self.text.replaceRangeAssumeCapacity(start, 0, "\n");
        self.cursor = start;
        self.mode = .insert;
        self.closeCompletion();
    }

    // --- moving by words ---

    /// `w`: to the start of the next word, where punctuation is a word too.
    pub fn wordForward(self: *Editor) void {
        const text = self.text.items;
        var at = self.cursor;
        if (at < text.len and classOf(text[at]) != .blank) {
            const kind = classOf(text[at]);
            while (at < text.len and classOf(text[at]) == kind) : (at += 1) {}
        }
        while (at < text.len and classOf(text[at]) == .blank) : (at += 1) {}
        self.cursor = at;
    }

    /// `b`: back to the start of this word, or of the one before.
    pub fn wordBackward(self: *Editor) void {
        const text = self.text.items;
        var at = self.cursor;
        while (at > 0 and classOf(text[at - 1]) == .blank) : (at -= 1) {}
        if (at > 0) {
            const kind = classOf(text[at - 1]);
            while (at > 0 and classOf(text[at - 1]) == kind) : (at -= 1) {}
        }
        self.cursor = at;
    }

    /// `e`: onto the last character of this word, or of the next.
    pub fn wordEnd(self: *Editor) void {
        const text = self.text.items;
        var at = self.next(self.cursor);
        while (at < text.len and classOf(text[at]) == .blank) : (at += 1) {}
        if (at >= text.len) {
            return;
        }
        const kind = classOf(text[at]);
        while (at < text.len and classOf(text[at]) == kind) : (at += 1) {}
        // The last character, not the last byte: one step back from past the end
        // of the word is the start of whatever that character is made of.
        self.cursor = self.previous(at);
    }

    pub fn firstNonBlank(self: *Editor) void {
        const stop = self.lineEnd(self.cursor);
        var at = self.lineStart(self.cursor);
        while (at < stop and (self.text.items[at] == ' ' or self.text.items[at] == '\t')) : (at += 1) {}
        self.cursor = at;
    }

    pub fn top(self: *Editor) void {
        self.cursor = 0;
    }

    pub fn bottom(self: *Editor) void {
        self.cursor = self.lineStart(self.text.items.len);
    }

    /// `h` and `l` stay on the line, which the arrow keys do not have to.
    pub fn leftOnLine(self: *Editor) void {
        if (self.cursor > self.lineStart(self.cursor)) {
            self.left();
        }
    }

    pub fn rightOnLine(self: *Editor) void {
        if (self.cursor < self.lineEnd(self.cursor)) {
            self.right();
        }
    }

    // --- moving ---

    pub fn left(self: *Editor) void {
        self.cursor = self.previous(self.cursor);
    }

    pub fn right(self: *Editor) void {
        self.cursor = self.next(self.cursor);
    }

    pub fn home(self: *Editor) void {
        self.cursor = self.lineStart(self.cursor);
    }

    pub fn end(self: *Editor) void {
        self.cursor = self.lineEnd(self.cursor);
    }

    /// Up and down keep the column, the way an editor does - counted in
    /// characters. Counted in bytes it was a column on a line of plain letters
    /// and the middle of a letter on a line with an accent in it, and the next
    /// key typed there split the letter in two.
    pub fn up(self: *Editor) void {
        const start = self.lineStart(self.cursor);
        if (start == 0) {
            self.cursor = 0;
            return;
        }
        const column = self.charsBetween(start, self.cursor);
        self.cursor = self.charsOn(self.lineStart(start - 1), column);
    }

    pub fn down(self: *Editor) void {
        const start = self.lineStart(self.cursor);
        const stop = self.lineEnd(self.cursor);
        if (stop >= self.text.items.len) {
            self.cursor = self.text.items.len;
            return;
        }
        const column = self.charsBetween(start, self.cursor);
        self.cursor = self.charsOn(stop + 1, column);
    }

    /// How many characters there are from `from` up to `to`.
    fn charsBetween(self: *Editor, from: usize, to: usize) usize {
        var count: usize = 0;
        for (self.text.items[from..to]) |byte| {
            count += @intFromBool(byte & 0xc0 != 0x80);
        }
        return count;
    }

    /// Where `count` characters on from `at` is, or the end of that line where
    /// the line is shorter than that.
    fn charsOn(self: *Editor, at: usize, count: usize) usize {
        const limit = self.lineEnd(at);
        var here = at;
        var left_to_go = count;
        while (left_to_go > 0 and here < limit) : (left_to_go -= 1) {
            here = self.next(here);
        }
        return @min(here, limit);
    }

    fn previous(self: *Editor, at: usize) usize {
        if (at == 0) {
            return 0;
        }
        var back = at - 1;
        while (back > 0 and self.text.items[back] & 0xc0 == 0x80) : (back -= 1) {}
        return back;
    }

    fn next(self: *Editor, at: usize) usize {
        if (at >= self.text.items.len) {
            return self.text.items.len;
        }
        const len = std.unicode.utf8ByteSequenceLength(self.text.items[at]) catch 1;
        return @min(self.text.items.len, at + len);
    }

    pub fn lineStart(self: *Editor, at: usize) usize {
        if (std.mem.lastIndexOfScalar(u8, self.text.items[0..at], '\n')) |newline| {
            return newline + 1;
        }
        return 0;
    }

    pub fn lineEnd(self: *Editor, at: usize) usize {
        if (std.mem.indexOfScalarPos(u8, self.text.items, at, '\n')) |newline| {
            return newline;
        }
        return self.text.items.len;
    }

    pub fn lineCount(self: *Editor) usize {
        return std.mem.count(u8, self.text.items, "\n") + 1;
    }

    /// The line the cursor is on, and how many bytes into it, for the drawing
    /// code and for scrolling.
    pub fn position(self: *Editor) struct { line: usize, column: usize } {
        const start = self.lineStart(self.cursor);
        return .{
            .line = std.mem.count(u8, self.text.items[0..start], "\n"),
            .column = self.cursor - start,
        };
    }

    pub fn lineAt(self: *Editor, wanted: usize) []const u8 {
        var lines = std.mem.splitScalar(u8, self.text.items, '\n');
        var n: usize = 0;
        while (lines.next()) |line| : (n += 1) {
            if (n == wanted) {
                return line;
            }
        }
        return "";
    }

    // --- completion ---

    pub fn completing(self: *Editor) bool {
        return self.candidates.items.len != 0;
    }

    pub fn closeCompletion(self: *Editor) void {
        self.candidates.clearRetainingCapacity();
        self.candidate_at = 0;
    }

    /// The word being typed, which is what completion works from.
    pub fn word(self: *Editor) []const u8 {
        var at = self.cursor;
        while (at > 0 and isWord(self.text.items[at - 1])) : (at -= 1) {}
        return self.text.items[at..self.cursor];
    }

    /// Offer `names` that carry on the word before the cursor. One candidate is
    /// inserted straight away; several open the list.
    pub fn complete(self: *Editor, names: []const []const u8) !void {
        const prefix = self.word();
        self.word_from = self.cursor - prefix.len;
        self.candidates.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
        const scratch = self.arena.allocator();
        for (names) |name| {
            if (prefix.len != 0 and !std.ascii.startsWithIgnoreCase(name, prefix)) {
                continue;
            }
            if (prefix.len == name.len) {
                continue; // already written in full
            }
            // Once, however many lists it came from: a table is a name in the
            // sidebar and can be the far end of a foreign key as well, and two
            // of one thing is a list to choose from where there was nothing to
            // choose.
            var offered = false;
            for (self.candidates.items) |candidate| {
                offered = offered or std.mem.eql(u8, candidate, name);
            }
            if (offered) {
                continue;
            }
            try self.candidates.append(self.allocator, try scratch.dupe(u8, name));
        }
        self.candidate_at = 0;
        if (self.candidates.items.len == 1) {
            try self.take(0);
        }
    }

    /// Put candidate `which` in place of the word being typed.
    pub fn take(self: *Editor, which: usize) !void {
        if (which >= self.candidates.items.len) {
            return;
        }
        // The list is about the word the cursor was at the end of when it opened.
        // If the cursor has since gone back past where that word starts, there is
        // nothing left for a candidate to replace - and the subtraction below
        // would be of a larger number from a smaller one.
        if (self.cursor < self.word_from) {
            self.closeCompletion();
            return;
        }
        self.changing();
        const name = self.candidates.items[which];
        const replaced = self.cursor - self.word_from;
        try self.text.replaceRange(self.allocator, self.word_from, replaced, name);
        self.cursor = self.word_from + name.len;
        self.closeCompletion();
    }

    pub fn nextCandidate(self: *Editor, delta: isize) void {
        const count = self.candidates.items.len;
        if (count == 0) {
            return;
        }
        if (delta > 0) {
            self.candidate_at = (self.candidate_at + 1) % count;
        } else {
            self.candidate_at = if (self.candidate_at == 0) count - 1 else self.candidate_at - 1;
        }
    }
};

/// Part of a name. Everything outside ASCII counts as a letter: nearly all of it
/// is one, a table can be called `zákazníci`, and it keeps every byte of a
/// character on the same side of the question - so nothing that stops where the
/// answer changes can stop in the middle of a character.
fn isWord(char: u8) bool {
    return std.ascii.isAlphanumeric(char) or char == '_' or char == '.' or char == '"' or char >= 0x80;
}

fn isSpace(char: u8) bool {
    return char == ' ' or char == '\t' or char == '\n' or char == '\r';
}

/// What a byte is to the word motions: part of a name, a blank, or anything
/// else - and a run of anything else is a word to them as well.
const Class = enum { blank, word, other };

fn classOf(char: u8) Class {
    if (isSpace(char)) {
        return .blank;
    }
    return if (isWord(char)) .word else .other;
}

// ------------------------------------------------------------- highlighting

pub const Kind = enum { plain, keyword, string, number, comment, punct };

pub const Token = struct {
    kind: Kind,
    from: usize,
    to: usize,
};

/// The words coloured as keywords. Both engines' own words are in here: a
/// keyword that one of them does not know is still a keyword to the reader.
const KEYWORDS = [_][]const u8{
    "ADD",               "ALL",          "ALTER",     "ANALYZE",   "AND",        "AS",           "ASC",
    "AUTOINCREMENT",     "BEGIN",        "BETWEEN",   "BIGINT",    "BLOB",       "BOOLEAN",      "BY",
    "CASCADE",           "CASE",         "CAST",      "CHECK",     "COLLATE",    "COLUMN",       "COMMIT",
    "CONFLICT",          "CONSTRAINT",   "COPY",      "CREATE",    "CROSS",      "CURRENT_DATE", "CURRENT_TIME",
    "CURRENT_TIMESTAMP", "DATABASE",     "DATE",      "DEFAULT",   "DEFERRABLE", "DELETE",       "DESC",
    "DISTINCT",          "DO",           "DOUBLE",    "DROP",      "ELSE",       "END",          "ESCAPE",
    "EXCEPT",            "EXISTS",       "EXPLAIN",   "FALSE",     "FLOAT",      "FOR",          "FOREIGN",
    "FROM",              "FULL",         "GENERATED", "GRANT",     "GROUP",      "HAVING",       "IF",
    "IN",                "INDEX",        "INNER",     "INSERT",    "INT",        "INTEGER",      "INTERSECT",
    "INTERVAL",          "INTO",         "IS",        "JOIN",      "KEY",        "LEFT",         "LIKE",
    "LIMIT",             "MATERIALIZED", "NATURAL",   "NOT",       "NOTHING",    "NOTNULL",      "NULL",
    "NULLS",             "NUMERIC",      "OFFSET",    "ON",        "OR",         "ORDER",        "OUTER",
    "OVER",              "PARTITION",    "PRAGMA",    "PRIMARY",   "REAL",       "REFERENCES",   "REINDEX",
    "RENAME",            "REPLACE",      "RESTRICT",  "RETURNING", "RIGHT",      "ROLLBACK",     "ROW",
    "SAVEPOINT",         "SELECT",       "SEQUENCE",  "SERIAL",    "SET",        "SMALLINT",     "TABLE",
    "TEMPORARY",         "TEXT",         "THEN",      "TIMESTAMP", "TO",         "TRANSACTION",  "TRIGGER",
    "TRUE",              "TRUNCATE",     "UNION",     "UNIQUE",    "UPDATE",     "USING",        "VACUUM",
    "VALUES",            "VARCHAR",      "VIEW",      "WHEN",      "WHERE",      "WINDOW",       "WITH",
    "WITHOUT",
};

pub fn isKeyword(candidate: []const u8) bool {
    for (KEYWORDS) |keyword| {
        if (std.ascii.eqlIgnoreCase(keyword, candidate)) {
            return true;
        }
    }
    return false;
}

/// A table a statement reads or writes, and what the rest of the statement
/// calls it.
pub const Alias = struct {
    /// The name it goes by: its alias, or its own name where it was given none.
    alias: []const u8,
    /// Empty where what goes by that name is not a table - a subquery, or a
    /// function that returns rows.
    table: []const u8,
    /// The schema it was written with, or empty for whichever is in use.
    schema: []const u8 = "",
};

/// The words a table's name comes after.
fn namesTables(word_text: []const u8) bool {
    for ([_][]const u8{ "FROM", "JOIN", "UPDATE", "INTO" }) |word_before| {
        if (std.ascii.eqlIgnoreCase(word_text, word_before)) {
            return true;
        }
    }
    return false;
}

/// Words that end a table/alias declaration in a FROM/JOIN clause.
fn isClauseEnd(word_text: []const u8) bool {
    const ends = [_][]const u8{
        "WHERE",   "ON",            "JOIN",   "INNER",     "LEFT",   "RIGHT",     "FULL",   "CROSS",
        "NATURAL", "STRAIGHT_JOIN", "GROUP",  "ORDER",     "HAVING", "LIMIT",     "OFFSET", "SET",
        "WINDOW",  "UNION",         "EXCEPT", "INTERSECT", "VALUES", "RETURNING", "USING",  "FETCH",
        "FOR",     "AS",
    };
    for (ends) |end| {
        if (std.ascii.eqlIgnoreCase(word_text, end)) {
            return true;
        }
    }
    return false;
}

fn stripQuotes(name: []const u8) []const u8 {
    if (name.len >= 2) {
        if ((name[0] == '"' and name[name.len - 1] == '"') or
            (name[0] == '`' and name[name.len - 1] == '`') or
            (name[0] == '[' and name[name.len - 1] == ']'))
        {
            return name[1 .. name.len - 1];
        }
    }
    return name;
}

/// Reads table references out of the tokens of a statement, with the blanks
/// and the comments already taken out.
const References = struct {
    sql: []const u8,
    tokens: []const Token,
    at: usize = 0,

    fn atPunct(self: *References, char: u8) bool {
        if (self.at >= self.tokens.len) {
            return false;
        }
        const token = self.tokens[self.at];
        return token.kind == .punct and self.sql[token.from] == char;
    }

    fn atKeyword(self: *References, word_text: []const u8) bool {
        if (self.at >= self.tokens.len) {
            return false;
        }
        const token = self.tokens[self.at];
        return token.kind == .keyword and std.ascii.eqlIgnoreCase(self.sql[token.from..token.to], word_text);
    }

    /// A name, and past it: a bare word that is not one of SQL's own, or
    /// anything in quotes, backticks or SQL Server's brackets.
    fn name(self: *References) ?[]const u8 {
        if (self.at >= self.tokens.len) {
            return null;
        }
        const token = self.tokens[self.at];
        const text = self.sql[token.from..token.to];
        if (token.kind == .plain and !isClauseEnd(text)) {
            self.at += 1;
            return stripQuotes(text);
        }
        // The tokenizer hands brackets over a piece at a time, because to it
        // they are punctuation. What is between them is the name, spaces and all.
        if (self.atPunct('[')) {
            var close = self.at + 1;
            while (close < self.tokens.len) : (close += 1) {
                const candidate = self.tokens[close];
                if (candidate.kind == .punct and self.sql[candidate.from] == ']') {
                    break;
                }
            }
            if (close >= self.tokens.len) {
                return null;
            }
            const inside = self.sql[token.to..self.tokens[close].from];
            self.at = close + 1;
            return inside;
        }
        return null;
    }

    /// Over an opening bracket and everything up to the one that closes it.
    fn skipBrackets(self: *References) void {
        var depth: usize = 0;
        while (self.at < self.tokens.len) {
            const token = self.tokens[self.at];
            self.at += 1;
            if (token.kind != .punct) {
                continue;
            }
            if (self.sql[token.from] == '(') {
                depth += 1;
            } else if (self.sql[token.from] == ')') {
                depth -|= 1;
                if (depth == 0) {
                    return;
                }
            }
        }
    }

    /// One reference: a table, or something in brackets, and the alias after it
    /// if there is one. Null where nothing here goes by a name.
    fn one(self: *References) ?Alias {
        var table: []const u8 = "";
        var schema: []const u8 = "";
        if (self.atPunct('(')) {
            self.skipBrackets();
        } else {
            table = self.name() orelse return null;
            // `schema.table`, or `database.schema.table`: the last of them is the
            // table and the one before it is where it lives.
            while (self.atPunct('.')) {
                const dot = self.at;
                self.at += 1;
                const next_part = self.name() orelse {
                    self.at = dot;
                    break;
                };
                schema = table;
                table = next_part;
            }
            // Written like a table and followed by brackets: a function that
            // returns rows, or the column list of an INSERT. Neither has columns
            // anybody can look up by that name.
            if (self.atPunct('(')) {
                self.skipBrackets();
                table = "";
                schema = "";
            }
        }
        const before = self.at;
        if (self.atKeyword("AS")) {
            self.at += 1;
        }
        const alias = self.name() orelse blk: {
            self.at = before;
            break :blk table;
        };
        if (alias.len == 0) {
            return null;
        }
        return .{ .alias = alias, .table = table, .schema = schema };
    }
};

/// Every table a statement names after FROM, JOIN, UPDATE or INTO, with what it
/// goes by: `FROM orders o`, `JOIN sales.users AS u`, `FROM [Order Details] od`.
///
/// Not a parser, and it does not have to be one: this is for completing `o.`
/// into the columns of `orders`, where being wrong offers a name that is not
/// there and being absent offers nothing at all.
pub fn extractAliases(arena: std.mem.Allocator, sql: []const u8) ![]Alias {
    var words: std.ArrayListUnmanaged(Token) = .empty;
    var all = Tokens{ .sql = sql };
    while (all.next()) |token| {
        if (token.kind == .comment or std.mem.trim(u8, sql[token.from..token.to], " \t\r\n").len == 0) {
            continue;
        }
        try words.append(arena, token);
    }

    var found: std.ArrayListUnmanaged(Alias) = .empty;
    var references = References{ .sql = sql, .tokens = words.items };
    // Every such word is looked at, wherever the last reference ended: a FROM
    // inside a subquery is inside the brackets the outer one stepped over.
    for (words.items, 0..) |token, index| {
        if (token.kind != .keyword or !namesTables(sql[token.from..token.to])) {
            continue;
        }
        references.at = index + 1;
        // One table, or several with commas between them.
        while (true) {
            const before = references.at;
            if (references.one()) |reference| {
                try found.append(arena, .{
                    .alias = try arena.dupe(u8, reference.alias),
                    .table = try arena.dupe(u8, reference.table),
                    .schema = try arena.dupe(u8, reference.schema),
                });
            }
            if (references.at == before or !references.atPunct(',')) {
                break;
            }
            references.at += 1;
        }
    }
    return found.items;
}

/// Every keyword, for completion.
pub fn keywords() []const []const u8 {
    return &KEYWORDS;
}

/// Walks a statement and says what each piece is. Not a parser: it knows
/// strings, comments, numbers, words and punctuation, which is all colouring
/// needs, and it never fails - unterminated anything simply runs to the end.
pub const Tokens = struct {
    sql: []const u8,
    at: usize = 0,

    pub fn next(self: *Tokens) ?Token {
        if (self.at >= self.sql.len) {
            return null;
        }
        const from = self.at;
        const char = self.sql[from];

        // A comment to the end of the line, or a bracketed one.
        if (char == '-' and self.peek(1) == '-') {
            self.at = std.mem.indexOfScalarPos(u8, self.sql, from, '\n') orelse self.sql.len;
            return .{ .kind = .comment, .from = from, .to = self.at };
        }
        if (char == '/' and self.peek(1) == '*') {
            self.at = if (std.mem.indexOfPos(u8, self.sql, from + 2, "*/")) |stop| stop + 2 else self.sql.len;
            return .{ .kind = .comment, .from = from, .to = self.at };
        }
        // A string, with '' for a quote inside it.
        if (char == '\'') {
            self.at = from + 1;
            while (self.at < self.sql.len) : (self.at += 1) {
                if (self.sql[self.at] != '\'') {
                    continue;
                }
                if (self.peek(1) == '\'') {
                    self.at += 1;
                    continue;
                }
                self.at += 1;
                break;
            }
            return .{ .kind = .string, .from = from, .to = self.at };
        }
        // A quoted identifier reads as a name, not as a string.
        if (char == '"' or char == '`') {
            self.at = from + 1;
            while (self.at < self.sql.len and self.sql[self.at] != char) : (self.at += 1) {}
            self.at = @min(self.sql.len, self.at + 1);
            return .{ .kind = .plain, .from = from, .to = self.at };
        }
        if (std.ascii.isDigit(char)) {
            self.at = from;
            while (self.at < self.sql.len and (std.ascii.isDigit(self.sql[self.at]) or self.sql[self.at] == '.')) : (self.at += 1) {}
            return .{ .kind = .number, .from = from, .to = self.at };
        }
        // A word. A letter with an accent is a letter here too: without that
        // `zákazníci` came out as a `z` and eight pieces of punctuation, coloured
        // as such and useless to anything that wanted the name.
        if (std.ascii.isAlphabetic(char) or char == '_' or char >= 0x80) {
            self.at = from;
            while (self.at < self.sql.len and (std.ascii.isAlphanumeric(self.sql[self.at]) or self.sql[self.at] == '_' or self.sql[self.at] >= 0x80)) : (self.at += 1) {}
            const text = self.sql[from..self.at];
            return .{ .kind = if (isKeyword(text)) .keyword else .plain, .from = from, .to = self.at };
        }
        if (char == ' ' or char == '\t' or char == '\n' or char == '\r') {
            self.at = from;
            while (self.at < self.sql.len and isSpace(self.sql[self.at])) : (self.at += 1) {}
            return .{ .kind = .plain, .from = from, .to = self.at };
        }
        // Anything else - an operator, a comma, a bracket - one piece at a time.
        self.at = from + 1;
        return .{ .kind = .punct, .from = from, .to = self.at };
    }

    fn peek(self: *Tokens, ahead: usize) u8 {
        return if (self.at + ahead < self.sql.len) self.sql[self.at + ahead] else 0;
    }
};

/// What kind each byte of `sql` belongs to, so a line can be drawn a run at a
/// time. `out` must be as long as `sql`.
pub fn kinds(sql: []const u8, out: []Kind) void {
    @memset(out[0..@min(out.len, sql.len)], .plain);
    var tokens = Tokens{ .sql = sql };
    while (tokens.next()) |token| {
        var at = token.from;
        while (at < token.to and at < out.len) : (at += 1) {
            out[at] = token.kind;
        }
    }
}

test "the tokenizer tells the pieces of a statement apart" {
    var tokens = Tokens{ .sql = "SELECT 'it''s', 42 -- why\nFROM t" };
    const wanted = [_]Kind{ .keyword, .plain, .string, .punct, .plain, .number, .plain, .comment, .plain, .keyword, .plain, .plain };
    var seen: usize = 0;
    while (tokens.next()) |token| : (seen += 1) {
        try std.testing.expectEqual(wanted[seen], token.kind);
    }
    try std.testing.expectEqual(wanted.len, seen);
}

test "a string that is never closed does not run away" {
    var tokens = Tokens{ .sql = "select 'open" };
    _ = tokens.next();
    _ = tokens.next();
    const last = tokens.next().?;
    try std.testing.expectEqual(Kind.string, last.kind);
    try std.testing.expectEqual(@as(usize, 12), last.to);
    try std.testing.expect(tokens.next() == null);
}

test "the cursor moves through lines and keeps its column" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.setText("select 1\nfrom t\nwhere x");
    try std.testing.expectEqual(@as(usize, 3), editor.lineCount());

    editor.home();
    try std.testing.expectEqual(@as(usize, 2), editor.position().line);
    editor.right();
    editor.right();
    try std.testing.expectEqual(@as(usize, 2), editor.position().column);
    editor.up();
    try std.testing.expectEqual(@as(usize, 1), editor.position().line);
    try std.testing.expectEqual(@as(usize, 2), editor.position().column);
    // The line above is shorter than the column asked for, so it stops at its end.
    editor.up();
    try std.testing.expectEqual(@as(usize, 0), editor.position().line);
    editor.end();
    try std.testing.expectEqualStrings("select 1", editor.lineAt(0));
}

test "one candidate is taken, several are offered" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.setText("select * from auth");
    try editor.complete(&[_][]const u8{ "authors", "books" });
    try std.testing.expectEqualStrings("select * from authors", editor.text.items);
    try std.testing.expect(!editor.completing());

    try editor.setText("select * from b");
    try editor.complete(&[_][]const u8{ "books", "book_list", "authors" });
    try std.testing.expect(editor.completing());
    try std.testing.expectEqual(@as(usize, 2), editor.candidates.items.len);
    editor.nextCandidate(1);
    try editor.take(editor.candidate_at);
    try std.testing.expectEqualStrings("select * from book_list", editor.text.items);
}

test "deleting a word stops at the space before it" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.setText("select count(*) from books");
    editor.deleteWord();
    try std.testing.expectEqualStrings("select count(*) from ", editor.text.items);
}

test "a table goes by its alias" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sql = "SELECT o.id, u.name FROM orders o JOIN users AS u ON o.user_id = u.id WHERE o.total > 100";
    const aliases = try extractAliases(a, sql);
    try std.testing.expectEqual(@as(usize, 2), aliases.len);
    try std.testing.expectEqualStrings("o", aliases[0].alias);
    try std.testing.expectEqualStrings("orders", aliases[0].table);
    try std.testing.expectEqualStrings("u", aliases[1].alias);
    try std.testing.expectEqualStrings("users", aliases[1].table);
}

test "an alias is found however the table was written" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // With a schema in front, which is how nearly every table is written on
    // PostgreSQL and SQL Server - and which used to find no alias at all.
    var got = try extractAliases(a, "select * from dbo.users u join sales.orders as o on o.uid = u.id");
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("u", got[0].alias);
    try std.testing.expectEqualStrings("users", got[0].table);
    try std.testing.expectEqualStrings("dbo", got[0].schema);
    try std.testing.expectEqualStrings("o", got[1].alias);
    try std.testing.expectEqualStrings("orders", got[1].table);
    try std.testing.expectEqualStrings("sales", got[1].schema);

    // In brackets, with a space in it.
    got = try extractAliases(a, "select * from [dbo].[Order Details] od");
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqualStrings("od", got[0].alias);
    try std.testing.expectEqualStrings("Order Details", got[0].table);
    try std.testing.expectEqualStrings("dbo", got[0].schema);

    // A subquery has a name and no table behind it to ask for columns.
    got = try extractAliases(a, "select * from (select 1 as x) sub where sub.x = 1");
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqualStrings("sub", got[0].alias);
    try std.testing.expectEqualStrings("", got[0].table);

    // The SELECT of an INSERT is not what the table is called.
    got = try extractAliases(a, "insert into orders select * from staging");
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("orders", got[0].alias);
    try std.testing.expectEqualStrings("staging", got[1].alias);

    // Without an alias a table goes by its own name, and several can share a FROM.
    got = try extractAliases(a, "SELECT 1 FROM `orders` AS o, \"customers\" c, tags WHERE o.cust_id = c.id");
    try std.testing.expectEqual(@as(usize, 3), got.len);
    try std.testing.expectEqualStrings("customers", got[1].table);
    try std.testing.expectEqualStrings("c", got[1].alias);
    try std.testing.expectEqualStrings("tags", got[2].alias);
    try std.testing.expectEqualStrings("tags", got[2].table);

    // And none of it is looked for in a comment or in a string.
    got = try extractAliases(a, "select 'from a b' -- from c d\n");
    try std.testing.expectEqual(@as(usize, 0), got.len);
}

test "a name with a dot in it is completed as a whole" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.setText("select u.na");
    try editor.complete(&[_][]const u8{ "u.name", "u.nation" });
    try std.testing.expect(editor.completing());
    try std.testing.expectEqual(@as(usize, 2), editor.candidates.items.len);
    try editor.take(0);
    try std.testing.expectEqualStrings("select u.name", editor.text.items);
}

test "a name is offered once" {
    // A table is in the sidebar and can be the far end of a foreign key too. Two
    // of it made a list of what was one answer, and one answer is taken as typed.
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.setText("select * from a join ord");
    try editor.complete(&[_][]const u8{ "orders", "o", "orders", "users" });
    try std.testing.expect(!editor.completing());
    try std.testing.expectEqualStrings("select * from a join orders", editor.text.items);
}

test "a deleted line is yanked, put back and taken back" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.setText("line one\nline two\nline three");
    editor.cursor = 10; // on "line two"
    editor.deleteLine();
    try std.testing.expectEqualStrings("line one\nline three", editor.text.items);
    try std.testing.expectEqualStrings("line two", editor.yank_buffer.items);

    editor.cursor = 0; // on "line one"
    editor.pasteBelow();
    try std.testing.expectEqualStrings("line one\nline two\nline three", editor.text.items);

    // Each command is a change of its own.
    editor.undo();
    try std.testing.expectEqualStrings("line one\nline three", editor.text.items);
    editor.undo();
    try std.testing.expectEqualStrings("line one\nline two\nline three", editor.text.items);
    editor.redo();
    editor.redo();
    try std.testing.expectEqualStrings("line one\nline two\nline three", editor.text.items);
    try std.testing.expectEqual(@as(usize, 9), editor.cursor);
}

test "the word motions stop where vi's do" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.setText("select name, email from users");
    editor.cursor = 0;
    editor.wordForward();
    try std.testing.expectEqual(@as(usize, 7), editor.cursor); // at "name"
    editor.wordForward();
    try std.testing.expectEqual(@as(usize, 11), editor.cursor); // at ","
    editor.wordForward();
    try std.testing.expectEqual(@as(usize, 13), editor.cursor); // at "email"
    editor.wordBackward();
    try std.testing.expectEqual(@as(usize, 11), editor.cursor); // back at ","
    editor.wordBackward();
    try std.testing.expectEqual(@as(usize, 7), editor.cursor); // back at "name"
    editor.wordEnd();
    try std.testing.expectEqual(@as(usize, 10), editor.cursor); // the "e" of "name"

    editor.openBelow();
    try std.testing.expectEqual(Mode.insert, editor.mode);
    try std.testing.expectEqualStrings("select name, email from users\n", editor.text.items);
}

test "a name with an accent in it is a name" {
    var tokens = Tokens{ .sql = "select příjmení from zákazníci z" };
    const wanted = [_]Kind{ .keyword, .plain, .plain, .plain, .keyword, .plain, .plain, .plain, .plain };
    var seen: usize = 0;
    while (tokens.next()) |token| : (seen += 1) {
        try std.testing.expectEqual(wanted[seen], token.kind);
    }
    try std.testing.expectEqual(wanted.len, seen);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const got = try extractAliases(arena.allocator(), "select z.příjmení from zákazníci z");
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqualStrings("z", got[0].alias);
    try std.testing.expectEqualStrings("zákazníci", got[0].table);

    // And completing one replaces the whole of what was typed of it, not the
    // letters after its last accent.
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.setText("select * from zák");
    try std.testing.expectEqualStrings("zák", editor.word());
    try editor.complete(&[_][]const u8{ "zákazníci", "zboží" });
    try std.testing.expectEqualStrings("select * from zákazníci", editor.text.items);
}

test "up and down keep the column in characters" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.setText("abc\nčůž\nxyz");
    editor.cursor = 2; // after "ab"
    editor.down();
    try std.testing.expectEqual(@as(usize, 8), editor.cursor); // after "čů", four bytes in
    try std.testing.expect(onBoundary(&editor));
    editor.down();
    try std.testing.expectEqual(@as(usize, 13), editor.cursor); // after "xy"
    editor.up();
    editor.up();
    try std.testing.expectEqual(@as(usize, 2), editor.cursor);
}

/// Whether the cursor is where a character starts.
fn onBoundary(editor: *Editor) bool {
    return editor.cursor >= editor.text.items.len or editor.text.items[editor.cursor] & 0xc0 != 0x80;
}

test "a motion never stops inside a character" {
    // `e` went one byte on and stayed there, which in "čč" is the second half of
    // the first letter - and the next key typed, or the next `x`, made bytes that
    // are not text any more.
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.setText("čč žluťoučký, kůň");
    editor.cursor = 0;
    var steps: usize = 0;
    while (steps < 8) : (steps += 1) {
        editor.wordEnd();
        try std.testing.expect(onBoundary(&editor));
    }
    while (steps > 0) : (steps -= 1) {
        editor.wordBackward();
        try std.testing.expect(onBoundary(&editor));
    }
    try std.testing.expectEqual(@as(usize, 0), editor.cursor);
    editor.wordForward();
    try std.testing.expectEqual(@as(usize, 5), editor.cursor); // past "čč " - two bytes a letter
    editor.deleteChar();
    try std.testing.expect(std.unicode.utf8ValidateSlice(editor.text.items));
    try std.testing.expectEqualStrings("čč luťoučký, kůň", editor.text.items);
}

test "taking a change back puts the cursor back too" {
    // The cursor used to stay at the offset it had, which belongs to the other
    // text: after `x`, `l` and `u` on "éa" that is the middle of the é.
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.setText("éa");
    editor.cursor = 0;
    editor.deleteChar();
    editor.right();
    editor.undo();
    try std.testing.expectEqualStrings("éa", editor.text.items);
    try std.testing.expectEqual(@as(usize, 0), editor.cursor);
    try editor.insert("Z");
    try std.testing.expect(std.unicode.utf8ValidateSlice(editor.text.items));
}

test "what was typed is one change, however long it took" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.setText("select 1");
    editor.enterInsert();
    try editor.insert(" from t");
    // Forty backspaces used to be forty changes, and the thirty-third pushed the
    // first out of reach.
    var n: usize = 0;
    while (n < 40) : (n += 1) {
        editor.backspace();
    }
    try std.testing.expectEqualStrings("", editor.text.items);
    try editor.insert("x");
    editor.leaveInsert();
    editor.undo();
    try std.testing.expectEqualStrings("select 1", editor.text.items);
    editor.redo();
    try std.testing.expectEqualStrings("x", editor.text.items);

    // And a command that goes on into insert mode is one change with what was
    // typed after it.
    try editor.setText("select name from t");
    editor.cursor = 7;
    editor.changeWord();
    try editor.insert("id");
    editor.leaveInsert();
    // The blank after the word stays, or the new one runs into "from".
    try std.testing.expectEqualStrings("select id from t", editor.text.items);
    editor.undo();
    try std.testing.expectEqualStrings("select name from t", editor.text.items);
}

test "changing a line leaves it where it was" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    // On the last line, where deleting it and opening one above put the new
    // line above the line before.
    try editor.setText("a\nb");
    editor.cursor = 2;
    editor.changeLine();
    try std.testing.expectEqualStrings("a\n", editor.text.items);
    try std.testing.expectEqual(@as(usize, 2), editor.cursor);
    try std.testing.expectEqual(Mode.insert, editor.mode);
    try std.testing.expectEqualStrings("b", editor.yank_buffer.items);

    // And on the only one, which is left empty rather than with a line under it.
    try editor.setText("abc");
    editor.cursor = 1;
    editor.changeLine();
    try std.testing.expectEqualStrings("", editor.text.items);
}

test "leaving insert mode, and appending, stay on the line" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.setText("select 1");
    editor.cursor = 3;
    editor.openBelow();
    editor.leaveInsert();
    // Still on the line that was just opened.
    try std.testing.expectEqual(@as(usize, 1), editor.position().line);

    try editor.setText("ab\ncd");
    editor.cursor = 0;
    editor.end();
    editor.append();
    try std.testing.expectEqual(@as(usize, 0), editor.position().line);
    try std.testing.expectEqual(@as(usize, 2), editor.cursor);
}

test "what was cut out of a line goes back into a line" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.setText("one two\nthree");
    editor.cursor = 4;
    editor.deleteToEndOfLine();
    try std.testing.expectEqualStrings("one \nthree", editor.text.items);
    editor.cursor = 0;
    editor.pasteBelow();
    // After the "o" it was on, not on a line of its own.
    try std.testing.expectEqualStrings("otwone \nthree", editor.text.items);

    // A word and the blanks after it, and punctuation is a word as well.
    try editor.setText("a, b");
    editor.cursor = 1;
    editor.deleteWordForward();
    try std.testing.expectEqualStrings("ab", editor.text.items);

    // An empty line that was yanked is put back as an empty line.
    try editor.setText("x\n\ny");
    editor.cursor = 2;
    editor.yankLine();
    editor.cursor = 0;
    editor.pasteBelow();
    try std.testing.expectEqualStrings("x\n\n\ny", editor.text.items);
}

test "no sequence of keys leaves the editor somewhere it cannot be" {
    // Every command and every key, in whatever order a random number puts them,
    // over text with characters of one, two, three and four bytes in it. After
    // each of them the cursor is inside the text and on a character, the text is
    // still text, and nothing has walked off the end of anything - the allocator
    // this runs on, and the safety checks, are what say so about the rest.
    //
    // A fixed seed, so a failure is the same failure every time it is run.
    var prng = std.Random.DefaultPrng.init(0x6b72_7465_6b);
    const random = prng.random();
    const pieces = [_][]const u8{
        "a",  "Z",    "9",      "_",    " ",      "  ",  "\n",    "\t",     ",",       ".",   "(", ")", ";", "'", "\"",
        "č",
        "ž",
        "ů",
        "日",
        "🙂",
        "o.", "from", "select", "\n\n", "orders", " o ", "join ", "-- x\n", "/* y */", "`q`",
    };
    const names = [_][]const u8{ "orders", "o.id", "o.total", "authors", "čaj", "select", "from" };

    var round: usize = 0;
    while (round < 300) : (round += 1) {
        var editor = Editor.init(std.testing.allocator);
        defer editor.deinit();
        var step: usize = 0;
        while (step < 200) : (step += 1) {
            const key = random.uintLessThan(u8, 44);
            // Which one it was, where it is not obvious from what is left.
            errdefer std.debug.print("round {d}, step {d}, key {d}: cursor {d} of {d} in \"{f}\"\n", .{
                round, step, key, editor.cursor, editor.text.items.len, std.zig.fmtString(editor.text.items),
            });
            switch (key) {
                0...7 => try editor.insert(pieces[random.uintLessThan(usize, pieces.len)]),
                8 => editor.backspace(),
                9 => editor.delete(),
                10 => editor.deleteWord(),
                11 => if (random.uintLessThan(u8, 8) == 0) editor.clear(),
                12 => editor.enterInsert(),
                13 => editor.append(),
                14 => editor.leaveInsert(),
                15 => editor.deleteLine(),
                16 => editor.changeLine(),
                17 => editor.deleteToEndOfLine(),
                18 => editor.changeToEndOfLine(),
                19 => editor.deleteWordForward(),
                20 => editor.changeWord(),
                21 => editor.deleteChar(),
                22 => editor.substitute(),
                23 => editor.yankLine(),
                24 => editor.pasteBelow(),
                25 => editor.pasteAbove(),
                26 => editor.openBelow(),
                27 => editor.openAbove(),
                28 => editor.wordForward(),
                29 => editor.wordBackward(),
                30 => editor.wordEnd(),
                31 => editor.firstNonBlank(),
                32 => if (random.boolean()) editor.top() else editor.bottom(),
                33 => if (random.boolean()) editor.leftOnLine() else editor.rightOnLine(),
                34 => if (random.boolean()) editor.left() else editor.right(),
                35 => if (random.boolean()) editor.home() else editor.end(),
                36 => editor.up(),
                37 => editor.down(),
                38 => editor.undo(),
                39 => editor.redo(),
                40 => editor.settle(),
                41 => try editor.complete(&names),
                42 => {
                    editor.nextCandidate(if (random.boolean()) 1 else -1);
                    try editor.take(editor.candidate_at);
                },
                else => _ = editor.position(),
            }
            try std.testing.expect(editor.cursor <= editor.text.items.len);
            try std.testing.expect(onBoundary(&editor));
            try std.testing.expect(std.unicode.utf8ValidateSlice(editor.text.items));
            try std.testing.expect(editor.undo_stack.items.len <= UNDO_LIMIT);
            try std.testing.expect(editor.redo_stack.items.len <= UNDO_LIMIT);
            // And what reads the text for the screen and for completion does not
            // mind what it finds there.
            _ = editor.word();
            _ = editor.lineAt(editor.position().line);
            var tokens = Tokens{ .sql = editor.text.items };
            var last: usize = 0;
            while (tokens.next()) |token| {
                try std.testing.expect(token.to > last or token.to == editor.text.items.len);
                last = token.to;
            }
        }
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        _ = try extractAliases(arena.allocator(), editor.text.items);
    }
}

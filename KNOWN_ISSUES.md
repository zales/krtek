# Known issues

Bugs that are known and not fixed yet. Each says how to see it, where it comes
from and what the fix would be. Delete an entry in the commit that fixes it.

The one below was found on 2026-10-04 while fixing the UTF-8 panics in
`printableText` and `tail` (commits "Text that is not UTF-8 is read as U+FFFD,
not read past" and "A character cut in two by a read of the terminal is put
back together"). It was there before those commits.

## A value that is not UTF-8 pushes the rest of its line sideways

**What it looks like.** A row whose text holds bytes that are not UTF-8 is
drawn a column or more off: in the grid the next column starts too early or
too late, and in the row form and the whole-value view (`gv`) the right
border of the box is missing on that line.

**How to see it.**

```sh
sqlite3 /tmp/bad.db "CREATE TABLE t(id INTEGER PRIMARY KEY, s TEXT, note TEXT);
INSERT INTO t VALUES (4, CAST(X'C5BEC5BEC5BEBEBEBEBEFFFEC0AFEDA080F4908080' AS TEXT), 'mixed garbage');
INSERT INTO t VALUES (6, CAST(X'787878787878787878787878787878787878787878787878787878787878C5BEC5BEBEBEBEBEFFFEC0AFEDA080F4908080F09F98E282' AS TEXT), 'x then mixed');"
krtek /tmp/bad.db
```

The `note` column of row 4 is out of line with the other rows. Enter on row 6
opens the form, and its `s` line has no right border. (Seen at 118 columns
through the screen of `tests/screen.py`, which decodes the way most terminals
do; how far off it is depends on the terminal.)

**Why.** `Term.put` (`src/tui/term.zig`) hands the bytes to vaxis as they are.
Vaxis measures them with uucode, which reads a broken sequence its own way -
a byte that starts a character but is not followed by the rest of it takes the
next byte into its U+FFFD with it. The terminal then gets the same raw bytes and
draws its own number of U+FFFD for them, usually one per maximal broken
sequence. `tail` counts a column per broken byte. Three different counts of
the same bytes, and whatever comes after them on the line moves by the
difference.

**The fix.** Draw U+FFFD instead of the broken bytes: in `Term.put`, when
`std.unicode.utf8ValidateSlice` says no, copy the text into the frame arena
with every byte `decode` does not accept replaced by U+FFFD (a byte at a time,
as `Chars` walks), and make `term.width` count the same way, so the width a
column is laid out with is the width drawn. Do it where the text is drawn and
not where a value is read: the row form edits the value it shows, and a value
cleaned when it was read would go back into the table with U+FFFD in place of
the original bytes. About 30-45 minutes with a test and a pty check of the rows
above.
